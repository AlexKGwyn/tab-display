#include "presenter.h"
#include <EGL/eglext.h>
#include <GLES2/gl2ext.h>
#include <android/hardware_buffer.h>
#include <sys/resource.h>
#include <unistd.h>

namespace {

PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC pGetNativeClientBuffer;
PFNEGLCREATEIMAGEKHRPROC pCreateImage;
PFNEGLDESTROYIMAGEKHRPROC pDestroyImage;
PFNGLEGLIMAGETARGETTEXTURE2DOESPROC pImageTargetTexture;
PFNEGLCREATESYNCKHRPROC pCreateSync;
PFNEGLCLIENTWAITSYNCKHRPROC pClientWaitSync;
PFNEGLDESTROYSYNCKHRPROC pDestroySync;

const char* kVs = R"(#version 300 es
out vec2 uv;
void main() {
    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    uv = vec2(p.x, 1.0 - p.y);  // image row 0 at the top of the screen
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
})";

const char* kFs = R"(#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision mediump float;
uniform samplerExternalOES tex;
in vec2 uv;
out vec4 color;
void main() { color = vec4(texture(tex, uv).rgb, 1.0); })";

GLuint compile(GLenum type, const char* src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, nullptr);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[512];
        glGetShaderInfoLog(s, sizeof log, nullptr, log);
        LOGE("shader: %s", log);
    }
    return s;
}

}  // namespace

bool Presenter::init(ANativeWindow* window, int width, int height, PresentedFn onPresented) {
    release();
    window_ = window;
    ANativeWindow_acquire(window_);
    w_ = width;
    h_ = height;
    onPresented_ = std::move(onPresented);
    if (AImageReader_newWithUsage(width, height, AIMAGE_FORMAT_PRIVATE, AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE, 4, &reader_) != AMEDIA_OK) {
        LOGW("presenter: AImageReader unavailable");
        release();
        return false;
    }
    AImageReader_ImageListener l{this, &Presenter::onImageAvailable};
    AImageReader_setImageListener(reader_, &l);
    AImageReader_getWindow(reader_, &readerWindow_);

    running_ = true;
    thread_ = std::thread([this] { renderLoop(); });
    std::unique_lock<std::mutex> lk(m_);
    cv_.wait(lk, [this] { return ready_; });
    if (!ok_) {
        lk.unlock();
        release();
        return false;
    }
    return true;
}

void Presenter::release() {
    if (running_.exchange(false)) {
        cv_.notify_all();
        if (thread_.joinable()) thread_.join();
    }
    if (reader_) {
        AImageReader_delete(reader_);  // also invalidates readerWindow_
        reader_ = nullptr;
        readerWindow_ = nullptr;
    }
    if (window_) {
        ANativeWindow_release(window_);
        window_ = nullptr;
    }
    ready_ = ok_ = false;
    pending_ = 0;
}

void Presenter::onImageAvailable(void* ctx, AImageReader*) {
    auto* self = static_cast<Presenter*>(ctx);
    {
        std::lock_guard<std::mutex> l(self->m_);
        self->pending_++;
    }
    self->cv_.notify_one();
}

bool Presenter::setupGl() {
    pGetNativeClientBuffer = (PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC)eglGetProcAddress("eglGetNativeClientBufferANDROID");
    pCreateImage = (PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");
    pDestroyImage = (PFNEGLDESTROYIMAGEKHRPROC)eglGetProcAddress("eglDestroyImageKHR");
    pImageTargetTexture = (PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)eglGetProcAddress("glEGLImageTargetTexture2DOES");
    pCreateSync = (PFNEGLCREATESYNCKHRPROC)eglGetProcAddress("eglCreateSyncKHR");
    pClientWaitSync = (PFNEGLCLIENTWAITSYNCKHRPROC)eglGetProcAddress("eglClientWaitSyncKHR");
    pDestroySync = (PFNEGLDESTROYSYNCKHRPROC)eglGetProcAddress("eglDestroySyncKHR");
    if (!pGetNativeClientBuffer || !pCreateImage || !pImageTargetTexture || !pCreateSync) { LOGW("presenter: EGL extensions missing"); return false; }

    dpy_ = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    eglInitialize(dpy_, nullptr, nullptr);
    const char* ext = eglQueryString(dpy_, EGL_EXTENSIONS);
    if (!strstr(ext, "EGL_KHR_mutable_render_buffer") || !strstr(ext, "EGL_ANDROID_front_buffer_auto_refresh")) {
        LOGW("presenter: single-buffer auto-refresh not supported");
        return false;
    }
    const EGLint cfgAttrs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR,
                               EGL_SURFACE_TYPE, EGL_WINDOW_BIT | EGL_MUTABLE_RENDER_BUFFER_BIT_KHR,
                               EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
    EGLConfig cfg;
    EGLint n = 0;
    if (!eglChooseConfig(dpy_, cfgAttrs, &cfg, 1, &n) || n == 0) { LOGW("presenter: no mutable-render-buffer config"); return false; }
    const EGLint ctxAttrs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_CONTEXT_PRIORITY_LEVEL_IMG, EGL_CONTEXT_PRIORITY_HIGH_IMG, EGL_NONE};
    ctx_ = eglCreateContext(dpy_, cfg, EGL_NO_CONTEXT, ctxAttrs);
    if (ctx_ == EGL_NO_CONTEXT) { LOGW("presenter: eglCreateContext failed 0x%x", eglGetError()); return false; }
    surf_ = eglCreateWindowSurface(dpy_, cfg, window_, nullptr);
    if (surf_ == EGL_NO_SURFACE) { LOGW("presenter: eglCreateWindowSurface failed 0x%x", eglGetError()); return false; }
    eglMakeCurrent(dpy_, surf_, surf_, ctx_);

    // Switch to single-buffer + auto-refresh; it takes effect at the next swap.
    eglSurfaceAttrib(dpy_, surf_, EGL_RENDER_BUFFER, EGL_SINGLE_BUFFER);
    eglSurfaceAttrib(dpy_, surf_, EGL_FRONT_BUFFER_AUTO_REFRESH_ANDROID, EGL_TRUE);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    eglSwapBuffers(dpy_, surf_);
    EGLint rb = 0;
    eglQueryContext(dpy_, ctx_, EGL_RENDER_BUFFER, &rb);
    if (rb != EGL_SINGLE_BUFFER) { LOGW("presenter: surface did not enter single-buffer mode (0x%x)", rb); return false; }

    GLuint vs = compile(GL_VERTEX_SHADER, kVs), fs = compile(GL_FRAGMENT_SHADER, kFs);
    prog_ = glCreateProgram();
    glAttachShader(prog_, vs);
    glAttachShader(prog_, fs);
    glLinkProgram(prog_);
    GLint linked = 0;
    glGetProgramiv(prog_, GL_LINK_STATUS, &linked);
    if (!linked) { LOGE("presenter: program link failed"); return false; }
    glGenVertexArrays(1, &vao_);

    glViewport(0, 0, w_, h_);
    LOGI("presenter: single-buffered auto-refresh surface ready (%dx%d)", w_, h_);
    return true;
}

GLuint Presenter::textureFor(AHardwareBuffer* hb) {
    auto it = images_.find(hb);
    if (it != images_.end()) return it->second.second;
    EGLClientBuffer cb = pGetNativeClientBuffer(hb);
    const EGLint attrs[] = {EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE};
    EGLImageKHR img = pCreateImage(dpy_, EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID, cb, attrs);
    GLuint tex;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, tex);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_NEAREST);  // 1:1, no filtering
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    pImageTargetTexture(GL_TEXTURE_EXTERNAL_OES, (GLeglImageOES)img);
    images_[hb] = {img, tex};
    return tex;
}

void Presenter::draw(AImage* img) {
    AHardwareBuffer* hb = nullptr;
    if (AImage_getHardwareBuffer(img, &hb) != AMEDIA_OK || !hb) return;
    glUseProgram(prog_);
    glBindVertexArray(vao_);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, textureFor(hb));
    glDrawArrays(GL_TRIANGLES, 0, 3);
    EGLSyncKHR sync = pCreateSync(dpy_, EGL_SYNC_FENCE_KHR, nullptr);
    glFlush();
    pClientWaitSync(dpy_, sync, EGL_SYNC_FLUSH_COMMANDS_BIT_KHR, EGL_FOREVER_KHR);
    pDestroySync(dpy_, sync);
}

void Presenter::renderLoop() {
    setpriority(PRIO_PROCESS, gettid(), -19);
    bool ok = setupGl();
    {
        std::lock_guard<std::mutex> l(m_);
        ready_ = true;
        ok_ = ok;
    }
    cv_.notify_all();
    while (ok && running_) {
        {
            std::unique_lock<std::mutex> l(m_);
            cv_.wait(l, [this] { return pending_ > 0 || !running_; });
            if (!running_) break;
            pending_ = 0;
        }
        AImage* img = nullptr;
        if (AImageReader_acquireLatestImage(reader_, &img) != AMEDIA_OK || !img) continue;
        int64_t ptsNs = 0;
        AImage_getTimestamp(img, &ptsNs);
        draw(img);
        int64_t t = now_ns();
        AImage_delete(img);  // GPU is done with it (fence waited)
        if (onPresented_) onPresented_(uint32_t(ptsNs / 1000), t);
    }
    if (dpy_ != EGL_NO_DISPLAY) {
        for (auto& [hb, e] : images_) {
            glDeleteTextures(1, &e.second);
            pDestroyImage(dpy_, e.first);
        }
        images_.clear();
        eglMakeCurrent(dpy_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (surf_ != EGL_NO_SURFACE) eglDestroySurface(dpy_, surf_);
        if (ctx_ != EGL_NO_CONTEXT) eglDestroyContext(dpy_, ctx_);
        eglTerminate(dpy_);
    }
    dpy_ = EGL_NO_DISPLAY;
    ctx_ = EGL_NO_CONTEXT;
    surf_ = EGL_NO_SURFACE;
}
