#pragma once
#include <media/NdkMediaCodec.h>
#include <android/native_window.h>
#include <atomic>
#include <functional>
#include <string>
#include <thread>
#include "util.h"

// Hardware decoder rendering straight to the SurfaceView. Input is queued from the
// transport reader thread; a dedicated output thread presents each frame the moment it
// is decoded (dropping all but the newest if several are ready).
class Decoder {
public:
    struct Callbacks {
        // Frame left the decoder (rendered=true) or was dropped in favor of a newer one.
        std::function<void(uint32_t seq, int64_t decodedNs, bool rendered)> onOutput;
        std::function<void()> onError;
    };

    ~Decoder() { release(); }
    bool configure(ANativeWindow* window, const std::string& codecName, bool hevc, int width, int height, bool fullRange, Callbacks cb);
    void release();
    bool configured() const { return codec_ != nullptr; }
    // Returns false if the access unit could not be queued (caller requests a keyframe).
    bool submit(const uint8_t* au, size_t n, bool keyframe, uint32_t seq);
    void flush();

private:
    bool queue(const uint8_t* p, size_t n, uint32_t flags, int64_t ptsUs, int64_t timeoutUs);
    void outputLoop();

    AMediaCodec* codec_ = nullptr;
    bool hevc_ = true;
    bool needConfig_ = true;
    std::atomic<bool> running_{false};
    std::thread out_;
    Callbacks cb_;
};
