#include "decoder.h"
#include <media/NdkMediaFormat.h>
#include <sys/resource.h>
#include <sys/system_properties.h>
#include <cstdlib>
#include <unistd.h>

namespace {

// Experiment knobs: `adb shell setprop debug.tabdisplay.<name> <int>` (-1 = unset).
int prop(const char* name) {
    char key[PROP_NAME_MAX], v[PROP_VALUE_MAX] = {};
    snprintf(key, sizeof key, "debug.tabdisplay.%s", name);
    return __system_property_get(key, v) > 0 ? atoi(v) : -1;
}

// Returns the byte offset where the leading parameter-set NAL units (VPS/SPS/PPS or SPS/PPS) end.
size_t paramSetPrefix(const uint8_t* p, size_t n, bool hevc) {
    size_t i = 0, end = 0;
    bool inParams = false;
    while (i + 3 <= n) {
        size_t sc = 0;
        if (p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1) sc = 3;
        else if (i + 4 <= n && p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 0 && p[i + 3] == 1) sc = 4;
        if (!sc) { i++; continue; }
        if (inParams) end = i;                       // previous param-set NAL ends here
        if (i + sc >= n) break;
        uint8_t h = p[i + sc];
        int type = hevc ? (h >> 1) & 0x3f : h & 0x1f;
        inParams = hevc ? (type >= 32 && type <= 34) : (type == 7 || type == 8);
        if (!inParams) return end;
        i += sc;
    }
    return inParams ? n : end;
}

}  // namespace

bool Decoder::configure(ANativeWindow* window, const std::string& codecName, bool hevc, int width, int height, bool fullRange, Callbacks cb) {
    release();
    hevc_ = hevc;
    cb_ = std::move(cb);
    const char* mime = hevc ? "video/hevc" : "video/avc";
    codec_ = (hevc && !codecName.empty()) ? AMediaCodec_createCodecByName(codecName.c_str()) : nullptr;
    if (!codec_) codec_ = AMediaCodec_createDecoderByType(mime);
    if (!codec_) { LOGE("no decoder for %s", mime); return false; }
    char* name = nullptr;
    if (AMediaCodec_getName(codec_, &name) == AMEDIA_OK) { LOGI("decoder: %s %dx%d", name, width, height); AMediaCodec_releaseName(codec_, name); }

    for (int attempt = 0; attempt < 2; attempt++) {
        AMediaFormat* f = AMediaFormat_new();
        AMediaFormat_setString(f, AMEDIAFORMAT_KEY_MIME, mime);
        AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_WIDTH, width);
        AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_HEIGHT, height);
        AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_LOW_LATENCY, 1);
        AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_PRIORITY, 0);
        // Qualcomm scales video-core clocks from the declared rate; tell it we decode at 120+ fps.
        AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_FRAME_RATE, 120);
        if (prop("nocolor") != 1) {
            int range = prop("range");
            AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_COLOR_RANGE, range >= 0 ? range : (fullRange ? 1 : 2));  // 1 full, 2 limited
            AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_COLOR_STANDARD, 1);  // BT.709
            int transfer = prop("transfer");
            AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_COLOR_TRANSFER, transfer >= 0 ? transfer : 3);  // 3 SDR video
        }
        if (attempt == 0) {
            // Best effort: Qualcomm vendor extensions (same keys Moonlight uses on Snapdragon).
            AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_OPERATING_RATE, 32767);  // Short.MAX_VALUE: max clocks (as Moonlight does)
            AMediaFormat_setInt32(f, "vendor.qti-ext-dec-low-latency.enable", 1);
            AMediaFormat_setInt32(f, "vendor.qti-ext-dec-frame-rate.value", 120);
            if (int v = prop("eop"); v >= 0) AMediaFormat_setInt32(f, "vendor.qti-ext-dec-end-of-picture.value", v);
            if (int v = prop("rate"); v >= 0) AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_OPERATING_RATE, v);
            if (int v = prop("ll"); v >= 0) AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_LOW_LATENCY, v);
            if (int v = prop("nonubwc"); v >= 0) AMediaFormat_setInt32(f, "vendor.qti-ext-dec-forceNonUBWC.value", v);
            AMediaFormat_setInt32(f, "vendor.qti-ext-dec-picture-order.enable", 1);
        }
        media_status_t st = AMediaCodec_configure(codec_, f, window, nullptr, 0);
        AMediaFormat_delete(f);
        if (st == AMEDIA_OK) {
            LOGI("decoder configured (%s)", attempt == 0 ? "with vendor keys" : "without vendor keys");
            break;
        }
        LOGW("decoder configure failed (%d), attempt %d", st, attempt);
        if (attempt == 1) { AMediaCodec_delete(codec_); codec_ = nullptr; return false; }
        AMediaCodec_delete(codec_);
        codec_ = AMediaCodec_createDecoderByType(mime);
        if (!codec_) return false;
    }
    if (AMediaCodec_start(codec_) != AMEDIA_OK) { LOGE("decoder start failed"); AMediaCodec_delete(codec_); codec_ = nullptr; return false; }

    AMediaFormat* in = AMediaCodec_getInputFormat(codec_);
    if (in) { LOGI("decoder input format: %s", AMediaFormat_toString(in)); AMediaFormat_delete(in); }

    needConfig_ = true;
    running_ = true;
    out_ = std::thread([this] { outputLoop(); });
    return true;
}

void Decoder::release() {
    running_ = false;
    if (out_.joinable()) out_.join();
    if (codec_) {
        AMediaCodec_stop(codec_);
        AMediaCodec_delete(codec_);
        codec_ = nullptr;
    }
}

void Decoder::flush() {
    if (!codec_) return;
    AMediaCodec_flush(codec_);
    needConfig_ = true;
}

bool Decoder::queue(const uint8_t* p, size_t n, uint32_t flags, int64_t ptsUs, int64_t timeoutUs) {
    ssize_t idx = AMediaCodec_dequeueInputBuffer(codec_, 0);
    if (idx < 0) idx = AMediaCodec_dequeueInputBuffer(codec_, timeoutUs);
    if (idx < 0) { LOGW("no decoder input buffer (%zd)", idx); return false; }
    size_t cap = 0;
    uint8_t* buf = AMediaCodec_getInputBuffer(codec_, idx, &cap);
    if (!buf || n > cap) {
        LOGE("input buffer too small: %zu > %zu", n, cap);
        AMediaCodec_queueInputBuffer(codec_, idx, 0, 0, ptsUs, 0);
        return false;
    }
    memcpy(buf, p, n);
    return AMediaCodec_queueInputBuffer(codec_, idx, 0, n, ptsUs, flags) == AMEDIA_OK;
}

bool Decoder::submit(const uint8_t* au, size_t n, bool keyframe, uint32_t seq) {
    if (!codec_) return false;
    if (needConfig_) {
        if (!keyframe) return false;
        size_t cfg = paramSetPrefix(au, n, hevc_);
        if (cfg == 0) { LOGW("keyframe without parameter sets"); return false; }
        if (!queue(au, cfg, AMEDIACODEC_BUFFER_FLAG_CODEC_CONFIG, 0, 10000)) return false;
        au += cfg;
        n -= cfg;
        needConfig_ = false;
    }
    return queue(au, n, 0, int64_t(seq), 4000);
}

void Decoder::outputLoop() {
    setpriority(PRIO_PROCESS, gettid(), -19);
    while (running_) {
        AMediaCodecBufferInfo info;
        ssize_t idx = AMediaCodec_dequeueOutputBuffer(codec_, &info, 20000);
        if (idx >= 0) {
            int64_t t = now_ns();
            // Several frames ready: present only the newest.
            for (;;) {
                AMediaCodecBufferInfo next;
                ssize_t j = AMediaCodec_dequeueOutputBuffer(codec_, &next, 0);
                if (j < 0) break;
                AMediaCodec_releaseOutputBuffer(codec_, idx, false);
                if (cb_.onOutput) cb_.onOutput(uint32_t(info.presentationTimeUs), t, false);
                idx = j;
                info = next;
            }
            AMediaCodec_releaseOutputBuffer(codec_, idx, true);
            if (cb_.onOutput) cb_.onOutput(uint32_t(info.presentationTimeUs), t, true);
        } else if (idx == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
            AMediaFormat* f = AMediaCodec_getOutputFormat(codec_);
            LOGI("decoder output format: %s", AMediaFormat_toString(f));
            AMediaFormat_delete(f);
        } else if (idx == AMEDIACODEC_INFO_TRY_AGAIN_LATER || idx == AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED) {
            continue;
        } else {
            LOGE("dequeueOutputBuffer error %zd", idx);
            if (cb_.onError) cb_.onError();
            usleep(5000);
        }
    }
}
