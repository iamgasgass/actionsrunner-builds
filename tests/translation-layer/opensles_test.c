/* Host test of husk-tl-opensles.c as OpenAL Soft drives it: PCM_EX float at 22050 Hz, a buffer queue, the callback, the volume. */
#define _GNU_SOURCE
#include <pthread.h>
#define pthread_setname_np(n) pthread_setname_np(pthread_self(), n)
#include "husk-tl-opensles.c"
#include <stdio.h>
#include <stdarg.h>

void tl_log_line(const char *fmt, ...) { va_list a; va_start(a, fmt); vprintf(fmt, a); va_end(a); printf("\n"); }
void (*tl_cocos_audio_hook)(const int16_t *, int, int, int);
static int fails; static void check(int ok, const char *w) { printf("%s %s\n", ok ? "PASS" : "FAIL", w); if (!ok) fails++; }
static int g_frames, g_ch, g_rate; static int16_t g_first[4]; static atomic_int g_writes, g_cbs;
static void hook(const int16_t *s, int f, int c, int r) { if (!atomic_load(&g_writes)) memcpy(g_first, s, sizeof(g_first)); g_frames += f; g_ch = c; g_rate = r; atomic_fetch_add(&g_writes, 1); usleep(1000); }
static void on_done(void *bq, void *ctx) { (void)bq; (void)ctx; atomic_fetch_add(&g_cbs, 1); }
typedef uint32_t (*fn)();

int main(void)
{
    tl_cocos_audio_hook = hook;
    const void *eng; b_slCreateEngine(&eng, 0, NULL, 0, NULL, NULL);
    const void *const *obj = eng; ((uint32_t (*)(const void *, uint32_t))((const void *const *)*obj)[0])(eng, 0);
    const void *engi; ((uint32_t (*)(const void *, const sl_iid *, const void **))((const void *const *)*obj)[3])(eng, &k_iid_engine, &engi);
    sl_pcm_ex fmt = { SL_ANDROID_DATAFORMAT_PCM_EX, 2, 22050000, 32, 32, 3, 2, SL_PCM_REPRESENTATION_FLOAT };
    uint32_t loc[2] = { SL_DATALOCATOR_ANDROIDSIMPLEBUFFERQUEUE, 4 };
    sl_data src = { loc, &fmt };
    const void *pl;
    uint32_t r = ((uint32_t (*)(const void *, const void **, const sl_data *, const sl_data *, uint32_t, const void *, const void *))
                  (*(const void *const *const *)engi)[2])(engi, &pl, &src, NULL, 0, NULL, NULL);
    sl_object *o = (sl_object *)pl;
    check(r == SL_OK && o->rate == 22050 && o->channels == 2 && o->bytes == 4 && o->repr == SL_PCM_REPRESENTATION_FLOAT, "PCM_EX float 22050 Hz read as such (was taken for 16-bit 48 kHz)");
    const void *bq, *play, *vol;
    o_GetInterface(pl, &k_iid_asbq, &bq); o_GetInterface(pl, &k_iid_play, &play); o_GetInterface(pl, &k_iid_volume, &vol);
    q_RegisterCallback(bq, on_done, NULL);
    static float buf[2][441 * 2];
    for (int i = 0; i < 441 * 2; i++) buf[0][i] = buf[1][i] = i % 2 ? -0.5f : 0.5f;
    q_Enqueue(bq, buf[0], sizeof(buf[0])); q_Enqueue(bq, buf[1], sizeof(buf[1]));
    p_SetPlayState(play, SL_PLAYING);
    for (int i = 0; i < 200 && atomic_load(&g_cbs) < 2; i++) usleep(2000);
    check(atomic_load(&g_cbs) == 2 && g_frames == 882, "both buffers played (441 frames each) and the callback ran for each");
    check(g_rate == 22050 && g_ch == 2, "handed to the host at 22050 Hz stereo");
    check(g_first[0] == 16384 && g_first[1] == -16384, "float +-0.5 -> 16-bit +-16384");
    uint32_t ms; p_GetPosition(play, &ms); check(ms == 40, "GetPosition: 882 frames at 22050 Hz = 40 ms");
    v_SetLevel(vol, -600);                       /* -6 dB: about half */
    int16_t mb; v_GetLevel(vol, &mb); check(mb == -600, "volume level kept");
    atomic_store(&g_writes, 0);
    q_Enqueue(bq, buf[0], sizeof(buf[0]));
    for (int i = 0; i < 200 && atomic_load(&g_cbs) < 3; i++) usleep(2000);
    check(g_first[0] > 8100 && g_first[0] < 8300, "-6 dB applied to the samples");
    uint32_t st[2]; q_GetState(bq, st); check(st[0] == 0 && st[1] == 3, "queue state: empty, 3 buffers done");
    p_SetPlayState(play, SL_STOPPED); o_Destroy(pl);
    sl_pcm pcm8 = { SL_DATAFORMAT_PCM, 1, 11025000, 8, 8, 4, 2 };
    sl_data s8 = { loc, &pcm8 };
    ((uint32_t (*)(const void *, const void **, const sl_data *, const sl_data *, uint32_t, const void *, const void *))
     (*(const void *const *const *)engi)[2])(engi, &pl, &s8, NULL, 0, NULL, NULL);
    o = (sl_object *)pl; uint8_t u8[2] = { 255, 0 };
    const int16_t *c = to_s16(o, u8, 2);
    check(o->rate == 11025 && o->bytes == 1 && c[0] > 32000 && c[1] == -32767, "8-bit unsigned PCM converted");
    o_Destroy(pl);
    printf(fails ? "FAILED\n" : "ALL PASSED\n");
    return fails != 0;
}
