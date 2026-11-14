/* Host test of husk-tl-audio.c's converter: rates, channel counts, continuity across writes. */
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <AudioToolbox/AudioToolbox.h>
void tl_log_line(const char *fmt, ...) { (void)fmt; }
void (*tl_cocos_audio_hook)(const int16_t *, int, int, int);
void tl_audio_install(void);
struct AudioQueue { AudioQueueOutputCallback cb; AudioStreamBasicDescription f; };
static struct AudioQueue g_q; static struct AudioQueueBuffer g_b; static int16_t g_mem[1 << 16];
static double g_rate; static int g_ch;
OSStatus AudioQueueNewOutput(const AudioStreamBasicDescription *f, AudioQueueOutputCallback cb, void *u, void *a, void *b, UInt32 fl, AudioQueueRef *q)
{ (void)u; (void)a; (void)b; (void)fl; g_q.cb = cb; g_q.f = *f; g_rate = f->mSampleRate; g_ch = (int)f->mChannelsPerFrame; *q = &g_q; return 0; }
OSStatus AudioQueueAllocateBuffer(AudioQueueRef q, UInt32 n, AudioQueueBufferRef *b) { (void)q; (void)n; g_b.mAudioData = g_mem; *b = &g_b; return 0; }
OSStatus AudioQueueEnqueueBuffer(AudioQueueRef q, AudioQueueBufferRef b, UInt32 n, void *d) { (void)q; (void)b; (void)n; (void)d; return 0; }
static int g_starts;
OSStatus AudioQueueStart(AudioQueueRef q, void *t) { (void)q; (void)t; g_starts++; return 0; }
OSStatus AudioQueuePause(AudioQueueRef q) { (void)q; return 0; }
OSStatus AudioQueueDispose(AudioQueueRef q, int i) { (void)q; (void)i; return 0; }

static int fails;
static void check(int ok, const char *what) { printf("%s %s\n", ok ? "PASS" : "FAIL", what); if (!ok) fails++; }
static int16_t *out; static size_t nout;
static void drain_n(int bufs) { for (int k = 0; k < bufs; k++) { g_q.cb(NULL, &g_q, &g_b); size_t n = g_b.mAudioDataByteSize / 4; out = realloc(out, (nout + n) * 4); memcpy(out + nout * 2, g_mem, n * 4); nout += n; } }
static void drain(void) { drain_n(16); }

int main(void)
{
    tl_audio_install();
    /* 22050 Hz mono sine in uneven writes: comes out stereo at 48 kHz, at the same pitch, with no jumps between writes */
    const double hz = 441.0; int total = 22050 / 4, at = 0, sizes[] = { 441, 100, 1, 999, 441, 7 };
    int16_t *in = malloc((size_t)total * 2);
    for (int i = 0; i < total; i++) in[i] = (int16_t)(12000 * sin(2 * M_PI * hz * i / 22050.0));
    /* the ring holds 8192 frames: fill most of it, take 7 whole buffers out (never more than is there, so no silence in between), go on */
    for (int k = 0; at < total; k++) {
        int n = sizes[k % 6]; if (at + n > total) n = total - at;
        if (at < 3600 && at + n >= 3600) { tl_cocos_audio_hook(in + at, 3600 - at, 1, 22050); n -= 3600 - at; at = 3600; drain_n(7); }
        if (n) tl_cocos_audio_hook(in + at, n, 1, 22050);
        at += n;
    }
    drain();
    check(g_rate == 48000 && g_ch == 2, "a 22050 Hz writer opens the queue at 48 kHz stereo");
    size_t made = nout; while (made > 0 && !out[(made - 1) * 2] && !out[(made - 1) * 2 + 1]) made--;   /* to the last sound */
    double expect = total * 48000.0 / 22050.0;
    check(fabs((double)made - expect) < 4, "22050 -> 48000: the right number of frames");
    int maxjump = 0, lr = 1; double cross = 0;
    for (size_t i = 1; i < made; i++) {
        int d = abs(out[i * 2] - out[(i - 1) * 2]); if (d > maxjump) maxjump = d;
        if (out[i * 2] != out[i * 2 + 1]) lr = 0;
        if (out[(i - 1) * 2] < 0 && out[i * 2] >= 0) cross++;
    }
    /* a 441 Hz sine at amplitude 12000 sampled at 48 kHz changes by at most 2*pi*441*12000/48000 = 693 per frame */
    check(maxjump < 760, "no discontinuity across writes of 1..999 frames");
    check(lr, "mono goes to both channels");
    check(fabs(cross / (made / 48000.0) - hz) < 3, "pitch kept (441 Hz in, 441 Hz out)");
    /* the same rate later: and a 44.1 kHz stereo writer is resampled to the open 48 kHz queue rather than played fast */
    nout = 0;
    int16_t st[2 * 4410]; for (int i = 0; i < 4410; i++) { st[2 * i] = 1000; st[2 * i + 1] = -1000; }
    tl_cocos_audio_hook(st, 4410, 2, 44100); drain();
    size_t m = nout; while (m > 0 && !out[(m - 1) * 2] && !out[(m - 1) * 2 + 1]) m--;
    check(fabs((double)m - 4800) < 4, "44100 Hz into the 48 kHz queue: 0.1 s stays 0.1 s");
    check(out[100] == 1000 && out[101] == -1000, "left and right kept apart");
    nout = 0;
    int16_t six[6 * 480]; for (int i = 0; i < 480; i++) for (int c = 0; c < 6; c++) six[6 * i + c] = (int16_t)(c == 0 ? 500 : c == 1 ? -500 : 9999);
    tl_cocos_audio_hook(six, 480, 6, 48000); drain();
    check(out[0] == 500 && out[1] == -500 && out[200] == 500, "5.1 at 48 kHz: front left and right, untouched");
    /* the output stops taking samples (iOS stopped the queue for a call): a writer must not wait for ever */
    {
        static int16_t big[2 * 48000];
        int before = g_starts;
        struct timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
        tl_cocos_audio_hook(big, 24000, 2, 48000);         /* more than the ring holds, nothing draining it */
        clock_gettime(CLOCK_MONOTONIC, &t1);
        double s = (double)(t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
        check(s < 5.0 && g_starts > before, "a stopped output is restarted and the writer goes on (no hang)");
    }
    printf(fails ? "FAILED\n" : "ALL PASSED\n");
    return fails != 0;
}
