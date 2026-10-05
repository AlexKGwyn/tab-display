#include "session.h"
#include <android/performance_hint.h>
#include <errno.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <unistd.h>
#include "protocol_constants.h"
#include "vsync.h"

VsyncTracker& vsync() {
    static VsyncTracker* v = [] { auto* t = new VsyncTracker; t->start(); return t; }();
    return *v;
}

using namespace proto;

Session::Session(int fd, bool usb, const DeviceInfo& dev, StateFn onState)
    : fd_(fd), usb_(usb), dev_(dev), onState_(std::move(onState)) {}

Session::~Session() {
    stop();
    if (reader_.joinable()) reader_.join();
    if (writer_.joinable()) writer_.join();
    {
        std::lock_guard<std::mutex> l(dm_);
        releaseDecoder();
        if (window_) ANativeWindow_release(window_);
    }
    if (fd_ >= 0) close(fd_);
}

void Session::start() {
    running_ = true;
    sendHello();
    writer_ = std::thread([this] { writerLoop(); });
    reader_ = std::thread([this] { readerLoop(); });
}

void Session::stop() {
    if (!running_.exchange(false)) return;
    if (!usb_) shutdown(fd_, SHUT_RDWR);
    wcv_.notify_all();
}

void Session::setWindow(ANativeWindow* w) {
    std::lock_guard<std::mutex> l(dm_);
    if (w == window_) return;
    releaseDecoder();
    if (window_) ANativeWindow_release(window_);
    window_ = w;
    if (window_) ANativeWindow_acquire(window_);
    if (window_ && haveConfig_) configureDecoder();
}

void Session::send(uint8_t type, uint8_t flags, const uint8_t* payload, size_t len, int64_t ts) {
    if (!running_) return;
    std::vector<uint8_t> m;
    m.reserve(kHeaderSize + len);
    put<uint16_t>(m, kMagic);
    put<uint8_t>(m, type);
    put<uint8_t>(m, flags);
    {
        std::lock_guard<std::mutex> l(wm_);
        put<uint32_t>(m, outSeq_++);
        put<int64_t>(m, ts);
        put<uint32_t>(m, uint32_t(len));
        if (len) m.insert(m.end(), payload, payload + len);
        wq_.push_back(std::move(m));
    }
    wcv_.notify_one();
}

void Session::setDisplaySize(int w, int h, uint32_t widthMm, uint32_t heightMm) {
    {
        std::lock_guard<std::mutex> l(devm_);
        if (dev_.panelW == w && dev_.panelH == h) return;
        dev_.panelW = w;
        dev_.panelH = h;
        dev_.widthMm = widthMm;
        dev_.heightMm = heightMm;
    }
    LOGI("display size now %dx%d (%ux%u mm)", w, h, widthMm, heightMm);
    if (!peerUp_) return;
    uint32_t p[4] = {uint32_t(w), uint32_t(h), widthMm, heightMm};
    send(MsgType::DISPLAY_SIZE, 0, reinterpret_cast<uint8_t*>(p), sizeof p);
}

void Session::sendHello() {
    std::lock_guard<std::mutex> dl(devm_);
    std::vector<uint8_t> p;
    put<uint32_t>(p, kVersion);
    put<uint32_t>(p, dev_.panelW);
    put<uint32_t>(p, dev_.panelH);
    put<float>(p, dev_.refresh);
    put<uint32_t>(p, dev_.codecMask);
    put<uint32_t>(p, dev_.lowLatencyDecoder ? HelloFlag::LOW_LATENCY_DECODER : 0);
    put<uint16_t>(p, uint16_t(dev_.name.size()));
    p.insert(p.end(), dev_.name.begin(), dev_.name.end());
    put<uint32_t>(p, dev_.widthMm);
    put<uint32_t>(p, dev_.heightMm);
    put<uint16_t>(p, uint16_t(dev_.appVersion.size()));
    p.insert(p.end(), dev_.appVersion.begin(), dev_.appVersion.end());
    send(MsgType::HELLO, 0, p.data(), p.size());
}

void Session::requestKeyframe(uint32_t reason) {
    int64_t t = now_ns();
    if (t - lastKfRequest_ < 100'000'000) return;
    lastKfRequest_ = t;
    LOGI("requesting keyframe (reason %u)", reason);
    send(MsgType::KEYFRAME_REQUEST, 0, reinterpret_cast<uint8_t*>(&reason), 4);
}

// Called with dm_ held.
void Session::configureDecoder() {
    Decoder::Callbacks cb;
    cb.onOutput = [this](uint32_t seq, int64_t t, bool rendered) {
        FrameRec r;
        {
            std::lock_guard<std::mutex> l(fm_);
            FrameRec& f = frames_[seq % frames_.size()];
            if (f.seq != seq) return;
            f.decoded = t;
            r = f;
        }
        if (!rendered) {
            dropped_++;
            uint8_t p[28];
            int64_t zero = 0;
            memcpy(p, &seq, 4); memcpy(p + 4, &r.recv, 8); memcpy(p + 12, &r.decoded, 8); memcpy(p + 20, &zero, 8);
            send(MsgType::FRAME_STATS, 0, p, sizeof p);
        } else if (!presenterActive_) {
            frameShown(seq, vsync().estimatePresent(t));  // through SurfaceFlinger's queue
        }
    };
    cb.onError = [this] { LOGE("decoder error"); };
    ANativeWindow* out = window_;
    if (dev_.frontBuffer && presenter_.init(window_, int(cfgW), int(cfgH), [this](uint32_t seq, int64_t gpuDone) {
            // Single-buffered auto-refresh: visible when the scan-out next passes the pixel,
            // on average half a refresh period after the GPU finished.
            frameShown(seq, gpuDone + vsync().period() / 2);
        })) {
        out = presenter_.decoderWindow();
        presenterActive_ = true;
        LOGI("present path: single-buffered GPU blit");
    } else {
        presenterActive_ = false;
        LOGI("present path: SurfaceView queue");
    }
    bool ok = decoder_.configure(out, dev_.decoderName, cfgCodec_ == Codec::HEVC, cfgW, cfgH, cfgFullRange_, cb);
    waitKeyframe_ = true;
    lastKfRequest_ = 0;
    if (ok) requestKeyframe(KeyframeReason::STARTUP);
}

// Called with dm_ held.
void Session::releaseDecoder() {
    decoder_.release();
    presenter_.release();
    presenterActive_ = false;
}

void Session::frameShown(uint32_t seq, int64_t shownNs) {
    FrameRec r;
    {
        std::lock_guard<std::mutex> l(fm_);
        r = frames_[seq % frames_.size()];
    }
    if (r.seq != seq || !r.decoded) return;
    rendered_++;
    const double ms = 1e-6;
    wCapture_.add((r.macCapture - r.macDisplay) * ms);
    wEncode_.add((r.macEncoded - r.macCapture) * ms);
    wDecode_.add((r.decoded - r.recv) * ms);
    wPresent_.add((shownNs - r.decoded) * ms);
    if (clock_.valid()) {
        int64_t off = clock_.offset();  // mac - tablet
        wTransfer_.add((r.recv - (r.macEncoded - off)) * ms);
        wTotal_.add((shownNs - (r.macDisplay - off)) * ms);
    }
    uint8_t p[28];
    memcpy(p, &seq, 4); memcpy(p + 4, &r.recv, 8); memcpy(p + 12, &r.decoded, 8); memcpy(p + 20, &shownNs, 8);
    send(MsgType::FRAME_STATS, 0, p, sizeof p);
}

void Session::onVideo(uint8_t flags, uint32_t seq, int64_t ts, const uint8_t* p, size_t n, int64_t recvNs) {
    bytes_ += n;
    bool key = flags & VideoFlag::KEYFRAME;
    if (n < kVideoTrailerSize) return;
    size_t au = n - kVideoTrailerSize;
    {
        std::lock_guard<std::mutex> l(fm_);
        frames_[seq % frames_.size()] = {seq, ts, rd<int64_t>(p + au), rd<int64_t>(p + au + 8), recvNs, 0, uint32_t(n)};
    }
    std::lock_guard<std::mutex> l(dm_);
    bool gap = lastVideoSeq_ >= 0 && int64_t(seq) != lastVideoSeq_ + 1;
    lastVideoSeq_ = seq;
    if (!decoder_.configured()) return;
    if (gap && !key) {
        LOGW("video seq gap before %u", seq);
        waitKeyframe_ = true;
    }
    if (waitKeyframe_ && !key) { requestKeyframe(gap ? KeyframeReason::SEQ_GAP : KeyframeReason::STARTUP); return; }
    if (decoder_.submit(p, au, key, seq)) {
        waitKeyframe_ = false;
    } else {
        decoder_.flush();
        waitKeyframe_ = true;
        lastKfRequest_ = 0;
        requestKeyframe(KeyframeReason::DECODER_ERROR);
    }
}

void Session::handle(uint8_t type, uint8_t flags, uint32_t seq, int64_t ts, const uint8_t* p, size_t n, int64_t recvNs) {
    switch (type) {
    case MsgType::VIDEO:
        onVideo(flags, seq, ts, p, n, recvNs);
        break;
    case MsgType::HELLO: {
        std::string name, version;
        if (n >= 26) {
            uint16_t len = rd<uint16_t>(p + 24);
            size_t off = 26 + size_t(len);
            if (off <= n) name.assign(reinterpret_cast<const char*>(p + 26), len);
            off += 8;  // width_mm, height_mm
            if (off + 2 <= n) {
                uint16_t vlen = rd<uint16_t>(p + off);
                if (off + 2 + vlen <= n) version.assign(reinterpret_cast<const char*>(p + off + 2), vlen);
            }
        }
        LOGI("HELLO from Mac: %s (protocol %u, app %s)", name.c_str(), n >= 4 ? rd<uint32_t>(p) : 0, version.c_str());
        { std::lock_guard<std::mutex> pl(pm_); peerVersion_ = version; }
        {
            // Drop anything (stale input) queued while the Mac was away.
            std::lock_guard<std::mutex> l(wm_);
            wq_.clear();
        }
        { std::lock_guard<std::mutex> pl(pm_); peer_ = name; }
        peerUp_ = true;
        lastVideoSeq_ = -1;
        sendHello();
        if (onState_) onState_(true, name);
        break;
    }
    case MsgType::CONFIG: {
        if (n < 24) break;
        std::lock_guard<std::mutex> l(dm_);
        uint32_t codec = rd<uint32_t>(p), w = rd<uint32_t>(p + 4), h = rd<uint32_t>(p + 8);
        bool fullRange = rd<uint32_t>(p + 16) != 0;
        if (haveConfig_ && decoder_.configured() && codec == cfgCodec_ && w == cfgW && h == cfgH && fullRange == cfgFullRange_) {
            // Same stream parameters (e.g. HELLO/CONFIG crossing): keep the decoder, wait for the keyframe.
            waitKeyframe_ = true;
            lastVideoSeq_ = -1;
            break;
        }
        cfgCodec_ = codec;
        cfgFullRange_ = fullRange;
        cfgW = w;
        cfgH = h;
        LOGI("CONFIG codec=%u %ux%u fps=%u fullRange=%u", cfgCodec_, cfgW, cfgH, rd<uint32_t>(p + 12), rd<uint32_t>(p + 16));
        haveConfig_ = true;
        lastVideoSeq_ = -1;
        wCapture_.clear(); wEncode_.clear(); wTransfer_.clear(); wDecode_.clear(); wPresent_.clear(); wTotal_.clear();
        if (window_) configureDecoder();
        break;
    }
    case MsgType::PING: {
        if (n < 8) break;
        int64_t t[3] = {rd<int64_t>(p), recvNs, now_ns()};
        send(MsgType::PONG, 0, reinterpret_cast<uint8_t*>(t), sizeof t);
        break;
    }
    case MsgType::PONG:
        if (n >= 24) clock_.add(rd<int64_t>(p), rd<int64_t>(p + 8), rd<int64_t>(p + 16), recvNs);
        break;
    case MsgType::BYE: {
        LOGI("BYE from Mac");
        std::lock_guard<std::mutex> l(dm_);
        releaseDecoder();
        haveConfig_ = false;
        { std::lock_guard<std::mutex> pl(pm_); peer_.clear(); }
        peerUp_ = false;
        if (onState_) onState_(false, "");
        if (!usb_) stop();
        break;
    }
    default:
        break;
    }
}

void Session::readerLoop() {
    setpriority(PRIO_PROCESS, gettid(), -19);
    APerformanceHintSession* hint = nullptr;
    if (APerformanceHintManager* mgr = APerformanceHint_getManager()) {
        int32_t tid = gettid();
        hint = APerformanceHint_createSession(mgr, &tid, 1, 8'000'000);
    }
    std::vector<uint8_t> buf(4 << 20);
    size_t have = 0;
    while (running_) {
        if (buf.size() - have < 65536) buf.resize(buf.size() * 2);
        ssize_t r = read(fd_, buf.data() + have, buf.size() - have);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) {
            LOGI("transport read ended (%zd, errno %d)", r, r < 0 ? errno : 0);
            break;
        }
        int64_t t = now_ns();
        lastRecvNs_ = t;
        have += size_t(r);
        size_t off = 0;
        while (have - off >= kHeaderSize) {
            const uint8_t* h = buf.data() + off;
            if (rd<uint16_t>(h) != kMagic || h[2] > 63 || rd<uint32_t>(h + 16) > (64u << 20)) {
                // Joined mid-stream (e.g. the app restarted while the Mac kept sending): skip to
                // the next plausible header. Video waits for a keyframe; our HELLO asks for one.
                size_t skip = 1;
                while (off + skip + kHeaderSize <= have) {
                    const uint8_t* c = h + skip;
                    if (rd<uint16_t>(c) == kMagic && c[2] <= 63 && rd<uint32_t>(c + 16) <= (64u << 20)) break;
                    skip++;
                }
                if (!resyncing_) LOGW("stream out of sync, resynchronizing");
                resyncing_ = true;
                off += skip;
                lastVideoSeq_ = -1;
                continue;
            }
            if (resyncing_) { LOGI("stream resynchronized"); resyncing_ = false; }
            uint32_t len = rd<uint32_t>(h + 16);
            if (have - off - kHeaderSize < len) {
                if (buf.size() < kHeaderSize + len + 65536) buf.resize(kHeaderSize + len + 65536);
                break;
            }
            handle(h[2], h[3], rd<uint32_t>(h + 4), rd<int64_t>(h + 8), h + kHeaderSize, len, t);
            off += kHeaderSize + len;
        }
        if (off) {
            memmove(buf.data(), buf.data() + off, have - off);
            have -= off;
        }
        if (hint) APerformanceHint_reportActualWorkDuration(hint, now_ns() - t);
    }
    if (hint) APerformanceHint_closeSession(hint);
    {
        std::lock_guard<std::mutex> l(dm_);
        releaseDecoder();
    }
    running_ = false;
    wcv_.notify_all();
    // Close the fd right away: /dev/usb_accessory admits a single opener, and the system needs
    // it back to run the next AOA handshake (no ACCESSORY_DETACHED arrives on a function switch).
    if (writer_.joinable()) writer_.join();
    close(fd_);
    fd_ = -1;
    finished_ = true;
    if (onState_) onState_(false, "");
}

void Session::writerLoop() {
    setpriority(PRIO_PROCESS, gettid(), -19);
    int64_t nextPing = now_ns();
    int quickPings = 8;
    std::vector<uint8_t> out;
    while (running_) {
        std::deque<std::vector<uint8_t>> batch;
        {
            std::unique_lock<std::mutex> l(wm_);
            wcv_.wait_until(l, std::chrono::steady_clock::now() + std::chrono::nanoseconds(std::max<int64_t>(0, nextPing - now_ns())),
                            [&] { return !wq_.empty() || !running_; });
            if (!running_) break;
            batch.swap(wq_);
        }
        // The Mac pings every 2 s; silence for 5 s means it quit or crashed without saying BYE.
        if (peerUp_ && now_ns() - lastRecvNs_ > 5'000'000'000LL) {
            LOGI("Mac went silent; treating it as disconnected");
            peerUp_ = false;
            if (onState_) onState_(false, "");
        }
        if (peerUp_ && now_ns() >= nextPing) {
            int64_t t1 = now_ns();
            nextPing = t1 + (quickPings-- > 0 ? 100'000'000 : 2'000'000'000);
            send(MsgType::PING, 0, reinterpret_cast<uint8_t*>(&t1), 8, t1);
        } else if (!peerUp_) {
            nextPing = now_ns() + 100'000'000;
            quickPings = 8;
        }
        if (batch.empty()) continue;
        out.clear();
        for (auto& m : batch) out.insert(out.end(), m.begin(), m.end());
        if (out.size() % 512 == 0) {  // avoid a transfer without a terminating short packet
            uint8_t nop[kHeaderSize] = {};
            uint16_t magic = kMagic;
            memcpy(nop, &magic, 2);
            out.insert(out.end(), nop, nop + kHeaderSize);
        }
        size_t off = 0;
        while (off < out.size()) {
            ssize_t w = write(fd_, out.data() + off, out.size() - off);
            if (w < 0 && errno == EINTR) continue;
            if (w <= 0) { LOGW("transport write failed (errno %d)", errno); running_ = false; break; }
            off += size_t(w);
        }
    }
}

std::string Session::hud() {
    int64_t t = now_ns();
    uint64_t r = rendered_, b = bytes_;
    if (hudLastNs_ && t - hudLastNs_ > 200'000'000) {
        double dt = (t - hudLastNs_) * 1e-9;
        hudFps_ = (r - hudLastRendered_) / dt;
        hudMbps_ = (b - hudLastBytes_) * 8 / dt / 1e6;
    }
    if (!hudLastNs_ || t - hudLastNs_ > 200'000'000) { hudLastNs_ = t; hudLastRendered_ = r; hudLastBytes_ = b; }
    std::string peer;
    { std::lock_guard<std::mutex> pl(pm_); peer = peer_; }
    char s[1024];
    auto row = [](char* o, size_t n, const char* name, const Window& w) {
        return snprintf(o, n, "%-9s %6.2f %6.2f\n", name, w.pct(0.5), w.pct(0.95));
    };
    int k = snprintf(s, sizeof s, "%s  %ux%u %s  %s\n%.1f fps  %.1f Mbps  dropped %llu\n\nstage       p50    p95\n",
                     peer.empty() ? "(no host)" : peer.c_str(), cfgW, cfgH, cfgCodec_ == Codec::HEVC ? "HEVC" : "H.264",
                     usb_ ? "USB" : "TCP", hudFps_, hudMbps_, (unsigned long long)dropped_.load());
    k += row(s + k, sizeof s - k, "capture", wCapture_);
    k += row(s + k, sizeof s - k, "encode", wEncode_);
    k += row(s + k, sizeof s - k, "transfer", wTransfer_);
    k += row(s + k, sizeof s - k, "decode", wDecode_);
    k += row(s + k, sizeof s - k, presenterActive_ ? "present~fb" : "present~", wPresent_);
    k += row(s + k, sizeof s - k, "total", wTotal_);
    snprintf(s + k, sizeof s - k, "\nclock rtt %.2f ms", clock_.valid() ? clock_.rtt() * 1e-6 : 0.0);
    return s;
}
