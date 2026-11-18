// SPDX-License-Identifier: GPL-2.0-or-later

#include "microphone_capture_source.hpp"

#include "apple_microphone_tap.hpp"
#include "audio_session.hpp"
#include "protocol.hpp"

#import <AVFAudio/AVFAudio.h>
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>

#include <chrono>
#include <memory>
#include <mutex>

namespace uml::audio {
namespace {

// A tap delivers between 100 and 400 ms of audio at a time. Converted to
// 48 kHz, 400 ms is 19200 frames; this leaves room over.
constexpr AVAudioFrameCount maximumConvertedFrames = 24000;
// The shortest delivery the tap supports, which is also its lowest latency.
constexpr double tapSeconds = 0.1;
// How soon a microphone that lost its engine tries to open it again.
constexpr auto reviveInterval = std::chrono::seconds(1);

/* The microphone's engine. Nothing here exists until start() is called, and
 * start() is called only for a guest that records while the user's setting is
 * on and permitted, so no AVAudioEngine input node is touched otherwise. */
struct Capture final : std::enable_shared_from_this<Capture> {
    ~Capture() { stop(); }

    [[nodiscard]] bool start(std::uint8_t channelCount, CaptureRing& target) noexcept
    {
        const std::lock_guard guard(lock);
        channels = channelCount;
        ring = &target;
        wanted = true;
        interrupted = false;
        return open();
    }

    void stop() noexcept
    {
        const std::lock_guard guard(lock);
        wanted = false;
        close();
    }

    /* The route changed under a running engine (a headset connected or left,
     * the input's format changed): build the engine again. The session stays
     * taken, so its category does not change under the route. Releasing it
     * would return the category to playback, which moves a Bluetooth headset
     * from the hands-free profile to A2DP and back, and every such switch is
     * a route change of its own. Taking it again is idempotent, and activates
     * a session the system has deactivated meanwhile. */
    void rebuild() noexcept
    {
        const std::lock_guard guard(lock);
        if (!wanted)
            return;
        closeEngine();
        (void)open();
    }

    /* Another app took the session: the engine stops and the session is
     * released, so the system's recording indicator goes out. */
    void interrupt() noexcept
    {
        const std::lock_guard guard(lock);
        if (!wanted)
            return;
        interrupted = true;
        close();
    }

    /* The system recommends resuming after an interruption. The microphone
     * starts again if the guest still records. Starting it takes the session,
     * and the microphone must never take the session from an app that is
     * playing or recording, such as a call: the system's advice to resume
     * settles that, and without the advice another app that plays keeps it. A
     * microphone left closed then starts again with the next recommendation
     * or the guest's next recording, and one whose reopen failed after the
     * advice is opened again by revive(). */
    void resume(bool recommended) noexcept
    {
        const std::lock_guard guard(lock);
        if (!wanted || engine != nil)
            return;
        if (!recommended && session::otherAudioPlaying())
            return;
        // The interruption is over whether or not the engine opens now: if it
        // does not (the route is not back yet), revive() asks again.
        interrupted = false;
        (void)open();
    }

    /* A rebuild that could not take the session back (the system had not
     * given the route back yet) leaves the microphone wanted and without an
     * engine, and nothing else would build one before the guest records
     * again. The capture source calls this while the guest records: it opens
     * the engine again, at most once a second. A microphone that another app
     * interrupted waits for the system's advice instead. */
    void revive() noexcept
    {
        const std::lock_guard guard(lock);
        if (!wanted || interrupted || engine != nil ||
            std::chrono::steady_clock::now() - lastAttempt < reviveInterval)
            return;
        (void)open();
    }

    std::mutex lock;
    bool wanted {};
    std::uint8_t channels {};
    CaptureRing* ring {};
    AVAudioEngine* __strong engine {};
    id __strong routeObserver {};
    bool sessionHeld {};
    bool interrupted {};

private:
    [[nodiscard]] bool open() noexcept
    {
        if (engine != nil)
            return true;
        lastAttempt = std::chrono::steady_clock::now();
        @try {
            if (!session::acquire(session::Client::capture)) {
                closeSession();
                return false;
            }
            sessionHeld = true;
            AVAudioEngine* created = [[AVAudioEngine alloc] init];
            AVAudioInputNode* input = created.inputNode;
            AVAudioFormat* inputFormat = [input outputFormatForBus:0];
            if (inputFormat == nil || inputFormat.sampleRate <= 0 ||
                inputFormat.channelCount == 0) {
                closeSession();
                return false;
            }
            AVAudioFormat* outputFormat = [[AVAudioFormat alloc]
                initWithCommonFormat:AVAudioPCMFormatInt16
                          sampleRate:protocol::sampleRate
                            channels:channels
                         interleaved:YES];
            AVAudioConverter* converter = [[AVAudioConverter alloc]
                initFromFormat:inputFormat
                      toFormat:outputFormat];
            AVAudioPCMBuffer* converted = [[AVAudioPCMBuffer alloc]
                initWithPCMFormat:outputFormat
                    frameCapacity:maximumConvertedFrames];
            if (outputFormat == nil || converter == nil || converted == nil) {
                closeSession();
                return false;
            }
            const std::weak_ptr<Capture> weak = weak_from_this();
            const auto tap = std::make_shared<MicrophoneTap>(converter, converted, *ring, channels,
                                                             protocol::sampleRate);
            NSError* tapError = nil;
            const BOOL tapped = [input
                installTapOnBus:0
                     bufferSize:static_cast<AVAudioFrameCount>(
                                    inputFormat.sampleRate * tapSeconds)
                         format:inputFormat
                          error:&tapError
                          block:^(AVAudioPCMBuffer* buffer, AVAudioTime* when) {
                              tap->receive(buffer, when);
                          }];
            if (!tapped) {
                closeSession();
                return false;
            }
            [created prepare];
            NSError* startError = nil;
            if (![created startAndReturnError:&startError]) {
                [input removeTapOnBus:0];
                closeSession();
                return false;
            }
            engine = created;
            // A route change stops the engine; the observer builds it again.
            routeObserver = [NSNotificationCenter.defaultCenter
                addObserverForName:AVAudioEngineConfigurationChangeNotification
                            object:created
                             queue:nil
                        usingBlock:^(NSNotification*) {
                          if (const auto capture = weak.lock())
                              capture->rebuild();
                        }];
            return true;
        } @catch (NSException*) {
            engine = nil;
            closeSession();
            return false;
        }
    }

    void close() noexcept
    {
        closeEngine();
        closeSession();
    }

    void closeEngine() noexcept
    {
        if (routeObserver != nil) {
            [NSNotificationCenter.defaultCenter removeObserver:routeObserver];
            routeObserver = nil;
        }
        @try {
            if (engine != nil) {
                [engine stop];
                [engine.inputNode removeTapOnBus:0];
            }
        } @catch (NSException*) {
        }
        engine = nil;
    }

    void closeSession() noexcept
    {
        if (sessionHeld) {
            session::release(session::Client::capture);
            sessionHeld = false;
        }
    }

    std::chrono::steady_clock::time_point lastAttempt {};
};

class AppleMicrophoneInput final : public MicrophoneInput {
public:
    AppleMicrophoneInput()
        : capture_(std::make_shared<Capture>())
    {
#if TARGET_OS_IPHONE
        const std::weak_ptr<Capture> weak = capture_;
        /* iOS 27 replaces the interruption notification with two, which the
         * playback sink observes too: the session becoming inactive, which
         * also reports the app's own deactivations (its release of the
         * session when the microphone stops), and the system's resumption
         * recommendation. An interruption is a deactivation that carries an
         * interruption context. */
        deactivationObserver_ = [NSNotificationCenter.defaultCenter
            addObserverForName:AVAudioSessionDidBecomeInactiveNotification
                        object:[AVAudioSession sharedInstance]
                         queue:nil
                    usingBlock:^(NSNotification* notification) {
                      const auto capture = weak.lock();
                      if (!capture)
                          return;
                      const AVAudioSessionDeactivationContext* context =
                          notification.userInfo
                              [AVAudioSessionDeactivationContextKey];
                      if (context.interruptionContext != nil)
                          capture->interrupt();
                    }];
        resumptionObserver_ = [NSNotificationCenter.defaultCenter
            addObserverForName:AVAudioSessionResumptionRecommendationNotification
                        object:[AVAudioSession sharedInstance]
                         queue:nil
                    usingBlock:^(NSNotification* notification) {
                      const auto capture = weak.lock();
                      if (!capture)
                          return;
                      const AVAudioSessionResumptionContext* context =
                          notification.userInfo
                              [AVAudioSessionResumptionContextKey];
                      capture->resume(context.recommendation ==
                          AVAudioSessionResumptionRecommendationShouldResume);
                    }];
#endif
    }

    ~AppleMicrophoneInput() override
    {
#if TARGET_OS_IPHONE
        [NSNotificationCenter.defaultCenter removeObserver:deactivationObserver_];
        [NSNotificationCenter.defaultCenter removeObserver:resumptionObserver_];
#endif
        capture_->stop();
    }

    [[nodiscard]] bool start(
        std::uint8_t channels,
        CaptureRing& ring) noexcept override
    {
        return capture_->start(channels, ring);
    }

    void stop() noexcept override { capture_->stop(); }

    void revive() noexcept override { capture_->revive(); }

private:
    std::shared_ptr<Capture> capture_;
#if TARGET_OS_IPHONE
    id __strong deactivationObserver_;
    id __strong resumptionObserver_;
#endif
};

} // namespace

std::unique_ptr<MicrophoneInput> makeAppleMicrophoneInput()
{
    return std::make_unique<AppleMicrophoneInput>();
}

} // namespace uml::audio
