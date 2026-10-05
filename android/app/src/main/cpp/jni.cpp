#include <android/native_window_jni.h>
#include <jni.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>
#include <memory>
#include "session.h"

namespace {

JavaVM* g_vm = nullptr;
jclass g_bridge = nullptr;
jmethodID g_onState = nullptr;

std::mutex g_m;
std::shared_ptr<Session> g_session;
uint64_t g_sessionId = 0;
std::vector<std::shared_ptr<Session>> g_retired;  // stopped, waiting for their threads to exit
ANativeWindow* g_window = nullptr;
DeviceInfo g_dev;

void notifyState(uint64_t id, bool connected, const std::string& peer) {
    {
        std::lock_guard<std::mutex> l(g_m);
        if (g_sessionId != id) return;  // a replaced session reporting its own shutdown
    }
    JNIEnv* env = nullptr;
    bool attached = false;
    if (g_vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
        g_vm->AttachCurrentThread(&env, nullptr);
        attached = true;
    }
    jstring s = env->NewStringUTF(peer.c_str());
    env->CallStaticVoidMethod(g_bridge, g_onState, jboolean(connected), s);
    env->DeleteLocalRef(s);
    if (attached) g_vm->DetachCurrentThread();
}

// Must hold g_m.
void reapLocked() {
    std::erase_if(g_retired, [](auto& s) { return s->finished(); });
}

void startSession(int fd, bool usb) {
    std::shared_ptr<Session> old;
    std::shared_ptr<Session> s;
    {
        std::lock_guard<std::mutex> l(g_m);
        old = g_session;
        uint64_t id = ++g_sessionId;
        s = std::make_shared<Session>(fd, usb, g_dev, [id](bool c, const std::string& p) { notifyState(id, c, p); });
        g_session = s;
    }
    if (old) {
        old->stop();
        std::lock_guard<std::mutex> l(g_m);
        g_retired.push_back(old);
        reapLocked();
    }
    s->setWindow(g_window);
    s->start();
}

void tcpServer(int port) {
    int ls = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons(uint16_t(port));
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(ls, reinterpret_cast<sockaddr*>(&a), sizeof a) < 0 || listen(ls, 1) < 0) {
        LOGE("tcp listen on %d failed (errno %d)", port, errno);
        close(ls);
        return;
    }
    LOGI("tcp dev transport listening on 127.0.0.1:%d", port);
    for (;;) {
        int c = accept(ls, nullptr, nullptr);
        if (c < 0) { if (errno == EINTR) continue; break; }
        setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        int sz = 4 << 20;
        setsockopt(c, SOL_SOCKET, SO_RCVBUF, &sz, sizeof sz);
        LOGI("tcp client connected");
        startSession(c, false);
    }
    close(ls);
}

std::string jstr(JNIEnv* env, jstring s) {
    if (!s) return {};
    const char* c = env->GetStringUTFChars(s, nullptr);
    std::string r(c);
    env->ReleaseStringUTFChars(s, c);
    return r;
}

}  // namespace

extern "C" {

JNIEXPORT jint JNI_OnLoad(JavaVM* vm, void*) {
    g_vm = vm;
    JNIEnv* env;
    vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6);
    jclass c = env->FindClass("com/alexgwyn/tabdisplay/NativeBridge");
    g_bridge = static_cast<jclass>(env->NewGlobalRef(c));
    g_onState = env->GetStaticMethodID(g_bridge, "onSessionState", "(ZLjava/lang/String;)V");
    return JNI_VERSION_1_6;
}

JNIEXPORT void JNICALL Java_com_alexgwyn_tabdisplay_NativeBridge_init(JNIEnv* env, jclass, jstring decoder, jboolean lowLatency,
                                                             jint w, jint h, jfloat refresh, jstring name, jint tcpPort, jboolean frontBuffer,
                                                             jint codecMask, jint widthMm, jint heightMm, jstring appVersion) {
    static bool started = false;
    g_dev.decoderName = jstr(env, decoder);
    g_dev.lowLatencyDecoder = lowLatency;
    g_dev.panelW = w;
    g_dev.panelH = h;
    g_dev.refresh = refresh;
    g_dev.name = jstr(env, name);
    g_dev.frontBuffer = frontBuffer;
    g_dev.codecMask = uint32_t(codecMask);
    g_dev.appVersion = jstr(env, appVersion);
    g_dev.widthMm = uint32_t(widthMm);
    g_dev.heightMm = uint32_t(heightMm);
    if (!started && tcpPort > 0) {
        started = true;
        std::thread(tcpServer, int(tcpPort)).detach();
    }
}

JNIEXPORT void JNICALL Java_com_alexgwyn_tabdisplay_NativeBridge_setSurface(JNIEnv* env, jclass, jobject surface) {
    ANativeWindow* w = surface ? ANativeWindow_fromSurface(env, surface) : nullptr;
    std::shared_ptr<Session> s;
    {
        std::lock_guard<std::mutex> l(g_m);
        if (g_window) ANativeWindow_release(g_window);
        g_window = w;
        s = g_session;
    }
    if (s) s->setWindow(w);
}

// Takes ownership of fd.
JNIEXPORT void JNICALL Java_com_alexgwyn_tabdisplay_NativeBridge_startUsb(JNIEnv*, jclass, jint fd) {
    LOGI("starting USB accessory session on fd %d", fd);
    startSession(fd, true);
}

JNIEXPORT void JNICALL Java_com_alexgwyn_tabdisplay_NativeBridge_stopUsb(JNIEnv*, jclass) {
    std::lock_guard<std::mutex> l(g_m);
    if (g_session && g_session->usb()) {
        g_session->stop();
        g_retired.push_back(g_session);
        g_session.reset();
    }
}

JNIEXPORT jboolean JNICALL Java_com_alexgwyn_tabdisplay_NativeBridge_hasUsbSession(JNIEnv*, jclass) {
    std::lock_guard<std::mutex> l(g_m);
    return g_session && g_session->usb() && !g_session->finished();
}

JNIEXPORT void JNICALL Java_com_alexgwyn_tabdisplay_NativeBridge_sendInput(JNIEnv* env, jclass, jint type, jbyteArray data, jint len, jlong ts) {
    std::shared_ptr<Session> s;
    {
        std::lock_guard<std::mutex> l(g_m);
        s = g_session;
    }
    if (!s) return;
    jbyte* b = env->GetByteArrayElements(data, nullptr);
    s->send(uint8_t(type), 0, reinterpret_cast<uint8_t*>(b), size_t(len), int64_t(ts));
    env->ReleaseByteArrayElements(data, b, JNI_ABORT);
}

JNIEXPORT void JNICALL Java_com_alexgwyn_tabdisplay_NativeBridge_setDisplaySize(JNIEnv*, jclass, jint w, jint h, jint widthMm, jint heightMm) {
    std::shared_ptr<Session> s;
    {
        std::lock_guard<std::mutex> l(g_m);
        g_dev.panelW = w;
        g_dev.panelH = h;
        g_dev.widthMm = uint32_t(widthMm);
        g_dev.heightMm = uint32_t(heightMm);
        s = g_session;
    }
    if (s) s->setDisplaySize(w, h, uint32_t(widthMm), uint32_t(heightMm));
}

JNIEXPORT jboolean JNICALL Java_com_alexgwyn_tabdisplay_NativeBridge_isConnected(JNIEnv*, jclass) {
    std::lock_guard<std::mutex> l(g_m);
    return g_session && g_session->peerConnected();
}

JNIEXPORT jstring JNICALL Java_com_alexgwyn_tabdisplay_NativeBridge_macVersion(JNIEnv* env, jclass) {
    std::shared_ptr<Session> s;
    {
        std::lock_guard<std::mutex> l(g_m);
        s = g_session;
    }
    return env->NewStringUTF(s ? s->peerVersion().c_str() : "");
}

JNIEXPORT jstring JNICALL Java_com_alexgwyn_tabdisplay_NativeBridge_hudText(JNIEnv* env, jclass) {
    std::shared_ptr<Session> s;
    {
        std::lock_guard<std::mutex> l(g_m);
        s = g_session;
        reapLocked();
    }
    return env->NewStringUTF(s ? s->hud().c_str() : "no session");
}

}  // extern "C"
