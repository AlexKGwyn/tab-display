#pragma once
#include <android/native_window.h>
#include <condition_variable>
#include <deque>
#include <functional>
#include <string>
#include <thread>
#include "decoder.h"
#include "util.h"

struct DeviceInfo {
    std::string decoderName;
    bool lowLatencyDecoder = false;
    int panelW = 0, panelH = 0;  // landscape pixels
    float refresh = 120;
    uint32_t codecMask = 1;      // hardware decoders (proto::CodecMask)
    uint32_t widthMm = 0, heightMm = 0;
    std::string appVersion;
    std::string name;
};

// One connection to the Mac over a byte-stream fd (AOA accessory fd or TCP socket).
// Reader thread: parse + decode input. Writer thread: input, control, pings.
class Session {
public:
    using StateFn = std::function<void(bool connected, const std::string& peer)>;
    Session(int fd, bool usb, const DeviceInfo& dev, StateFn onState);
    ~Session();
    void start();
    void stop();
    bool finished() const { return finished_; }
    bool usb() const { return usb_; }
    bool peerConnected() const { return peerUp_ && !finished_; }
    std::string peerVersion() { std::lock_guard<std::mutex> l(pm_); return peerVersion_; }

    void setWindow(ANativeWindow* w);  // may be null; session keeps its own reference
    // The video area changed (rotation, split screen, resize): tell the Mac.
    void setDisplaySize(int w, int h, uint32_t widthMm, uint32_t heightMm);
    void send(uint8_t type, uint8_t flags, const uint8_t* payload, size_t len, int64_t ts = now_ns());
    std::string hud();

private:
    void readerLoop();
    void writerLoop();
    void handle(uint8_t type, uint8_t flags, uint32_t seq, int64_t ts, const uint8_t* p, size_t n, int64_t recvNs);
    void onVideo(uint8_t flags, uint32_t seq, int64_t ts, const uint8_t* p, size_t n, int64_t recvNs);
    void configureDecoder();
    void releaseDecoder();
    void frameShown(uint32_t seq, int64_t shownNs);
    void requestKeyframe(uint32_t reason);
    void sendHello(bool reply = false);

    int fd_;
    bool usb_;
    std::mutex devm_;  // guards dev_ size fields
    DeviceInfo dev_;
    StateFn onState_;
    std::atomic<bool> running_{false}, finished_{false};
    std::thread reader_, writer_;

    std::mutex wm_;
    std::condition_variable wcv_;
    std::deque<std::vector<uint8_t>> wq_;
    uint32_t outSeq_ = 0;

    // Decoder state (reader thread, guarded by dm_ for surface changes).
    std::mutex dm_;
    ANativeWindow* window_ = nullptr;
    Decoder decoder_;
    bool haveConfig_ = false;
    uint32_t cfgCodec_ = 0, cfgW = 0, cfgH = 0;
    bool cfgFullRange_ = true;
    bool waitKeyframe_ = true;
    int64_t lastVideoSeq_ = -1;
    int64_t lastKfRequest_ = 0;
    bool resyncing_ = false;
    std::atomic<int> decoderErrors_{0};  // consecutive output errors; the reader rebuilds the decoder
    std::mutex pm_;
    std::string peer_;             // guarded by pm_
    std::string peerVersion_;      // guarded by pm_
    std::atomic<bool> peerUp_{false};
    std::atomic<int64_t> lastRecvNs_{0};  // for detecting a Mac that vanished without BYE

    // Per-frame timing, indexed by seq % 256 (all on the tablet clock except mac*).
    struct FrameRec { uint32_t seq; int64_t macDisplay, macCapture, macEncoded, recv, decoded; uint32_t bytes; };
    std::mutex fm_;
    std::array<FrameRec, 256> frames_{};
    ClockSync clock_;  // offset = mac - tablet
    Window wCapture_, wEncode_, wTransfer_, wDecode_, wPresent_, wTotal_;
    std::atomic<uint64_t> rendered_{0}, dropped_{0}, bytes_{0};
    uint64_t hudLastRendered_ = 0, hudLastBytes_ = 0;
    int64_t hudLastNs_ = 0;
    double hudFps_ = 0, hudMbps_ = 0;
};
