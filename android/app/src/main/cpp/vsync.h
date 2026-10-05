#pragma once
#include <android/choreographer.h>
#include <android/looper.h>
#include <thread>
#include "util.h"

// Estimates when a buffer queued to the SurfaceView at time t reaches the panel, from
// Choreographer frame timelines (deadline → expected presentation time). Qualcomm's
// MediaCodec render callback does not report real display times, so this is the
// present-stage clock.
class VsyncTracker {
public:
    void start() {
        std::thread([this] {
            ALooper_prepare(0);
            AChoreographer* c = AChoreographer_getInstance();
            AChoreographer_postVsyncCallback(c, &VsyncTracker::cb, this);
            for (;;) ALooper_pollOnce(-1, nullptr, nullptr, nullptr);
        }).detach();
    }

    // Returns 0 until the first vsync has been observed.
    int64_t estimatePresent(int64_t t) const {
        std::lock_guard<std::mutex> l(m_);
        if (!period_) return 0;
        int64_t k = t > deadline_ ? (t - deadline_ + period_ - 1) / period_ : -((deadline_ - t) / period_);
        return present_ + k * period_;
    }

    int64_t period() const { std::lock_guard<std::mutex> l(m_); return period_ ? period_ : 8'333'333; }

private:
    static void cb(const AChoreographerFrameCallbackData* d, void* ud) {
        auto* self = static_cast<VsyncTracker*>(ud);
        size_t n = AChoreographerFrameCallbackData_getFrameTimelinesLength(d);
        if (n >= 1) {
            int64_t dl = AChoreographerFrameCallbackData_getFrameTimelineDeadlineNanos(d, 0);
            int64_t pr = AChoreographerFrameCallbackData_getFrameTimelineExpectedPresentationTimeNanos(d, 0);
            int64_t period = n >= 2 ? AChoreographerFrameCallbackData_getFrameTimelineExpectedPresentationTimeNanos(d, 1) - pr : 8'333'333;
            std::lock_guard<std::mutex> l(self->m_);
            self->deadline_ = dl;
            self->present_ = pr;
            self->period_ = period > 0 ? period : 8'333'333;
        }
        AChoreographer_postVsyncCallback(AChoreographer_getInstance(), &VsyncTracker::cb, self);
    }

    mutable std::mutex m_;
    int64_t deadline_ = 0, present_ = 0, period_ = 0;
};
