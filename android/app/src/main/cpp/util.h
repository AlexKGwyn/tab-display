#pragma once
#include <android/log.h>
#include <time.h>
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <vector>

#define LOG_TAG "TabDisplay"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

inline int64_t now_ns() {
    timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return int64_t(ts.tv_sec) * 1000000000LL + ts.tv_nsec;
}

template <class T> inline T rd(const uint8_t* p) { T v; memcpy(&v, p, sizeof v); return v; }
template <class T> inline void put(std::vector<uint8_t>& b, T v) {
    size_t n = b.size();
    b.resize(n + sizeof v);
    memcpy(&b[n], &v, sizeof v);
}

// Fixed-size ring of recent samples with percentile queries. Thread-safe.
class Window {
public:
    void add(double v) {
        std::lock_guard<std::mutex> l(m_);
        v_[n_++ % v_.size()] = float(v);
    }
    double pct(double p) const {
        std::lock_guard<std::mutex> l(m_);
        size_t c = std::min(n_, v_.size());
        if (!c) return 0;
        std::array<float, 240> s;
        std::copy(v_.begin(), v_.begin() + c, s.begin());
        size_t k = std::min(c - 1, size_t(p * double(c)));
        std::nth_element(s.begin(), s.begin() + k, s.begin() + c);
        return s[k];
    }
    void clear() { std::lock_guard<std::mutex> l(m_); n_ = 0; }
private:
    mutable std::mutex m_;
    std::array<float, 240> v_{};
    size_t n_ = 0;
};

// NTP-style clock offset (remote - local), lowest-RTT sample of the last 8.
class ClockSync {
public:
    void add(int64_t t1, int64_t t2, int64_t t3, int64_t t4) {
        std::lock_guard<std::mutex> l(m_);
        s_[n_++ % 8] = {((t2 - t1) + (t3 - t4)) / 2, (t4 - t1) - (t3 - t2)};
    }
    bool valid() const { std::lock_guard<std::mutex> l(m_); return n_ > 0; }
    int64_t offset() const { return best().first; }
    int64_t rtt() const { return best().second; }
private:
    std::pair<int64_t, int64_t> best() const {
        std::lock_guard<std::mutex> l(m_);
        std::pair<int64_t, int64_t> b{0, INT64_MAX};
        for (size_t i = 0; i < std::min<size_t>(n_, 8); i++)
            if (s_[i].second < b.second) b = s_[i];
        return b;
    }
    mutable std::mutex m_;
    std::array<std::pair<int64_t, int64_t>, 8> s_{};
    size_t n_ = 0;
};
