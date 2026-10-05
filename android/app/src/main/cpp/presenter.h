#pragma once
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <android/native_window.h>
#include <media/NdkImageReader.h>
#include <atomic>
#include <condition_variable>
#include <functional>
#include <thread>
#include <unordered_map>
#include "util.h"

// Low-latency present path. The decoder outputs into an AImageReader; a render thread blits
// each newest image with the GPU into a *single-buffered*, auto-refreshing EGL surface on the
// SurfaceView (EGL_KHR_mutable_render_buffer + EGL_ANDROID_front_buffer_auto_refresh). The
// display controller re-sends that buffer to the (command-mode) panel every vsync, so a frame
// becomes visible at the next refresh instead of going through SurfaceFlinger's queue.
// Trade-off: tearing when a blit races the scan-out.
class Presenter {
public:
    // Called on the render thread after the GPU finished drawing frame `seq`.
    using PresentedFn = std::function<void(uint32_t seq, int64_t gpuDoneNs)>;

    ~Presenter() { release(); }
    // Returns false if single-buffer mode is unavailable (caller falls back to direct decode).
    bool init(ANativeWindow* window, int width, int height, PresentedFn onPresented);
    void release();
    ANativeWindow* decoderWindow() const { return readerWindow_; }

private:
    void renderLoop();
    bool setupGl();
    void draw(AImage* img);
    GLuint textureFor(AHardwareBuffer* hb);
    static void onImageAvailable(void* ctx, AImageReader*);

    ANativeWindow* window_ = nullptr;
    int w_ = 0, h_ = 0;
    PresentedFn onPresented_;
    AImageReader* reader_ = nullptr;
    ANativeWindow* readerWindow_ = nullptr;

    EGLDisplay dpy_ = EGL_NO_DISPLAY;
    EGLContext ctx_ = EGL_NO_CONTEXT;
    EGLSurface surf_ = EGL_NO_SURFACE;
    GLuint prog_ = 0, vao_ = 0;
    std::unordered_map<AHardwareBuffer*, std::pair<void*, GLuint>> images_;  // EGLImage, texture

    std::thread thread_;
    std::mutex m_;
    std::condition_variable cv_;
    int pending_ = 0;
    std::atomic<bool> running_{false};
    bool ready_ = false, ok_ = false;
};
