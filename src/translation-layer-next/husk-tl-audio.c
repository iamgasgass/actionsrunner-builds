/* SPDX-License-Identifier: GPL-2.0-or-later */
#define _DARWIN_C_SOURCE
#include "husk-tl-audio.h"

#include <AudioToolbox/AudioToolbox.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "husk-tl-bionic.h"
#include "husk-tl-cocos.h"

#define NBUF 3
#define FRAMES_PER_BUF 1024
#define RING_FRAMES 8192

static struct {
    pthread_mutex_t mu;
    pthread_cond_t cv;
    AudioQueueRef q;
    AudioQueueBufferRef bufs[NBUF];
    int rate, channels;
    int16_t *ring;
    size_t head, count;           /* frames */
    bool paused, failed;
} A = { .mu = PTHREAD_MUTEX_INITIALIZER, .cv = PTHREAD_COND_INITIALIZER };

/* The audio thread asks for samples; an empty ring is silence, never a wait. */
static void on_buffer(void *user, AudioQueueRef q, AudioQueueBufferRef b)
{
    (void)user;
    int16_t *out = b->mAudioData;
    size_t want = FRAMES_PER_BUF, ch = (size_t)A.channels;
    pthread_mutex_lock(&A.mu);
    size_t take = A.paused ? 0 : (A.count < want ? A.count : want);
    size_t first = RING_FRAMES - A.head < take ? RING_FRAMES - A.head : take;
    memcpy(out, &A.ring[A.head * ch], first * ch * sizeof(int16_t));
    if (take > first) memcpy(out + first * ch, &A.ring[0], (take - first) * ch * sizeof(int16_t));
    A.head = (A.head + take) % RING_FRAMES;
    A.count -= take;
    pthread_cond_broadcast(&A.cv);
    pthread_mutex_unlock(&A.mu);
    if (take < want) memset(out + take * ch, 0, (want - take) * ch * sizeof(int16_t));
    b->mAudioDataByteSize = (UInt32)(want * ch * sizeof(int16_t));
    AudioQueueEnqueueBuffer(q, b, 0, NULL);
}

static bool open_queue(int rate, int channels)
{
    AudioStreamBasicDescription f = { 0 };
    f.mSampleRate = rate; f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    f.mBitsPerChannel = 16; f.mChannelsPerFrame = (UInt32)channels; f.mFramesPerPacket = 1;
    f.mBytesPerFrame = f.mBytesPerPacket = (UInt32)(channels * 2);
    OSStatus st = AudioQueueNewOutput(&f, on_buffer, NULL, NULL, NULL, 0, &A.q);
    if (st != noErr) { tl_log_line("audio: AudioQueueNewOutput failed (%d)", (int)st); return false; }
    A.ring = calloc((size_t)RING_FRAMES * (size_t)channels, sizeof(int16_t));
    if (!A.ring) { AudioQueueDispose(A.q, true); A.q = NULL; return false; }
    A.rate = rate; A.channels = channels;
    for (int i = 0; i < NBUF; i++) {
        AudioQueueAllocateBuffer(A.q, FRAMES_PER_BUF * (UInt32)channels * 2, &A.bufs[i]);
        memset(A.bufs[i]->mAudioData, 0, FRAMES_PER_BUF * (size_t)channels * 2);
        A.bufs[i]->mAudioDataByteSize = FRAMES_PER_BUF * (UInt32)channels * 2;
        AudioQueueEnqueueBuffer(A.q, A.bufs[i], 0, NULL);
    }
    st = AudioQueueStart(A.q, NULL);
    if (st != noErr) { tl_log_line("audio: AudioQueueStart failed (%d)", (int)st); return false; }
    tl_log_line("audio: output running, %d Hz, %d channel(s)", rate, channels);
    return true;
}

static void sleep_for(int frames, int rate)
{
    struct timespec ts = { 0, (long)((double)frames * 1e9 / rate) };
    nanosleep(&ts, NULL);
}

static void ring_write(const int16_t *samples, int frames);

/*
 * The mixer's write: any rate and 1..8 channels in, the queue's own format out. The queue is opened once, in stereo, at the first
 * writer's rate when that is 44.1 or 48 kHz (bit-exact then: no resampling for the usual case) and at 48 kHz otherwise; every other
 * rate is resampled to it with a linear interpolator whose phase carries over from one write to the next.
 *
 * It used to be opened at whatever came first and kept: a later writer at another rate played at the wrong speed, and one with
 * another channel count was dropped (silence). GTA SA's OpenAL mixes at 22050 Hz, which the OpenSL player took for 48000 (it did not
 * read Android's PCM_EX format): a fast, crackling sound. The old 2x upsampler for 24 kHz games is covered by the general one.
 */
static struct {
    pthread_mutex_t mu;                     /* one writer at a time through the converter (its state is the stream's) */
    int in_rate;
    double pos;                             /* the read position, in input frames, relative to prev */
    int16_t prev[2];                        /* the last input frame of the previous write */
    bool have_prev;
    int16_t *buf; size_t cap;               /* frames */
} R = { .mu = PTHREAD_MUTEX_INITIALIZER };

static inline void frame_of(const int16_t *s, int channels, int f, int16_t out[2])
{
    const int16_t *p = s + (size_t)f * (size_t)channels;
    if (channels == 1) { out[0] = out[1] = p[0]; return; }
    out[0] = p[0]; out[1] = p[1];           /* more than two: front left and right (Android's channel order starts with them) */
}

static void host_write(const int16_t *samples, int frames, int channels, int rate)
{
    if (!samples || frames <= 0 || channels <= 0 || channels > 8 || rate < 1000 || rate > 384000) return;
    pthread_mutex_lock(&A.mu);
    if (!A.q && !A.failed) { if (!open_queue(rate == 44100 || rate == 48000 ? rate : 48000, 2)) A.failed = true; }
    bool failed = A.failed; int out_rate = A.rate;
    pthread_mutex_unlock(&A.mu);
    if (failed) { sleep_for(frames, rate); return; }

    pthread_mutex_lock(&R.mu);
    if (R.in_rate != rate) { R.in_rate = rate; R.pos = 0; R.have_prev = false; }
    if (rate == out_rate) {
        /* same rate: interleave to stereo only (a copy when the input is stereo already) */
        if (R.cap < (size_t)frames) { free(R.buf); R.cap = (size_t)frames; R.buf = malloc(R.cap * 2 * sizeof(int16_t)); }
        if (!R.buf) { R.cap = 0; pthread_mutex_unlock(&R.mu); return; }
        if (channels == 2) memcpy(R.buf, samples, (size_t)frames * 2 * sizeof(int16_t));
        else for (int f = 0; f < frames; f++) frame_of(samples, channels, f, &R.buf[(size_t)f * 2]);
        frame_of(samples, channels, frames - 1, R.prev); R.have_prev = true;
        ring_write(R.buf, frames);
        pthread_mutex_unlock(&R.mu);
        return;
    }
    /* Input frame i sits at i+1 on the timeline whose 0 is prev (the last frame of the previous write); the output steps through it
       by rate/out_rate and interpolates between the two frames around each step. */
    const double step = (double)rate / (double)out_rate;
    if (!R.have_prev) { frame_of(samples, channels, 0, R.prev); R.have_prev = true; R.pos = 1.0; }
    size_t most = (size_t)((double)frames / step) + 4;
    if (R.cap < most) { free(R.buf); R.cap = most; R.buf = malloc(R.cap * 2 * sizeof(int16_t)); }
    if (!R.buf) { R.cap = 0; pthread_mutex_unlock(&R.mu); return; }
    size_t n = 0;
    double pos = R.pos;
    while (n < most) {
        int i = (int)pos;                   /* the frame before pos on that timeline (0: prev) */
        if (i >= frames) break;             /* the frame after it is in the next write */
        double t = pos - i;
        int16_t a[2], b[2];
        if (i == 0) { a[0] = R.prev[0]; a[1] = R.prev[1]; } else frame_of(samples, channels, i - 1, a);
        frame_of(samples, channels, i, b);
        for (int c = 0; c < 2; c++) {
            double v = a[c] + (b[c] - a[c]) * t;
            R.buf[n * 2 + (size_t)c] = (int16_t)(v < -32768 ? -32768 : v > 32767 ? 32767 : v);
        }
        n++;
        pos += step;
    }
    R.pos = pos - frames;                   /* relative to the new prev: this write's last frame */
    frame_of(samples, channels, frames - 1, R.prev);
    if (n) ring_write(R.buf, (int)n);
    pthread_mutex_unlock(&R.mu);
}

/* Copy stereo frames into the ring, blocking while it is full (that is the pacing). */
static void ring_write(const int16_t *samples, int frames)
{
    pthread_mutex_lock(&A.mu);
    int done = 0;
    while (done < frames) {
        while ((A.count >= RING_FRAMES || A.paused) && !A.failed) pthread_cond_wait(&A.cv, &A.mu);
        if (A.failed) break;
        size_t room = RING_FRAMES - A.count, n = (size_t)(frames - done) < room ? (size_t)(frames - done) : room;
        size_t tail = (A.head + A.count) % RING_FRAMES;
        size_t first = RING_FRAMES - tail < n ? RING_FRAMES - tail : n;     /* up to the end of the ring, then from its start */
        memcpy(&A.ring[tail * 2], &samples[(size_t)done * 2], first * 2 * sizeof(int16_t));
        if (n > first) memcpy(&A.ring[0], &samples[((size_t)done + first) * 2], (n - first) * 2 * sizeof(int16_t));
        A.count += n;
        done += (int)n;
    }
    pthread_mutex_unlock(&A.mu);
}

/* TL_AUDIO_MUTE: pace like a device but make no sound (for test runs on a Mac). TL_AUDIO_STATS=1 also logs, about once a second,
 * how loud the game's output was, so a silent run still shows whether the game is making sound. */
static void muted_write(const int16_t *samples, int frames, int channels, int rate)
{
    static int stats = -1, seen, peak;
    static long loud, total;
    if (stats < 0) stats = getenv("TL_AUDIO_STATS") != NULL;
    if (stats) {
        for (int i = 0; i < frames * channels; i++) {
            int v = samples[i] < 0 ? -samples[i] : samples[i];
            if (v > peak) peak = v;
            if (v > 64) loud++;
        }
        total += frames * channels;
        if ((seen += frames) >= rate) {
            tl_log_line("audio: %d Hz x %d, peak %d, %.0f%% of samples audible", rate, channels, peak, 100.0 * loud / (total ? total : 1));
            seen = 0; peak = 0; loud = 0; total = 0;
        }
    }
    sleep_for(frames, rate);
}

void tl_audio_install(void) { tl_cocos_audio_hook = getenv("TL_AUDIO_MUTE") ? muted_write : host_write; }

void tl_audio_set_paused(bool paused)
{
    pthread_mutex_lock(&A.mu);
    A.paused = paused;
    if (A.q) { if (paused) AudioQueuePause(A.q); else AudioQueueStart(A.q, NULL); }
    pthread_cond_broadcast(&A.cv);
    pthread_mutex_unlock(&A.mu);
}
