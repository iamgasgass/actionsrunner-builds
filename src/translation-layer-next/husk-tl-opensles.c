// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * OpenSL ES, the way Unreal Engine plays through it: an engine, an output mix, and one player fed from an Android simple buffer queue.
 * The player's thread takes each queued buffer in turn, hands the samples to the host audio (tl_cocos_audio_hook, which blocks until the
 * speakers have room -- that is what paces the game's mixer) and then calls the game's callback so it can queue the next one.
 *
 * OpenSL's objects and interfaces are pointers to tables of functions, so each object here starts with the table pointer the guest
 * dereferences, and the interface the guest is given is the address of that pointer. Recording, effects and 3D audio are not offered.
 */
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <unistd.h>

#include "husk-tl-bionic.h"

extern void (*tl_cocos_audio_hook)(const int16_t *samples, int frames, int channels, int rate);

enum {
    SL_OK = 0, SL_PARAMETER_INVALID = 2, SL_FEATURE_UNSUPPORTED = 12, SL_BUFFER_INSUFFICIENT = 7,
    SL_PLAYING = 3, SL_PAUSED = 2, SL_STOPPED = 1,
    SL_OBJECT_UNREALIZED = 1, SL_OBJECT_REALIZED = 2,
    SL_DATAFORMAT_PCM = 2, SL_ANDROID_DATAFORMAT_PCM_EX = 4, SL_DATALOCATOR_BUFFERQUEUE = 6, SL_DATALOCATOR_ANDROIDSIMPLEBUFFERQUEUE = 0x800007BD,
    SL_BYTEORDER_BIGENDIAN = 1,
    SL_PCM_REPRESENTATION_SIGNED_INT = 1, SL_PCM_REPRESENTATION_UNSIGNED_INT = 2, SL_PCM_REPRESENTATION_FLOAT = 3,
    SL_PLAYEVENT_HEADATEND = 1,
};

/* The interface identifiers are compared by address; the guest imports them as variables holding a pointer to one of these. */
typedef struct { uint32_t time_low; uint16_t time_mid, time_hi, clock; uint8_t node[6]; } sl_iid;
static const sl_iid k_iid_engine   = { 0x8d97c260, 0xddd4, 0x11db, 0x958f, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid k_iid_play     = { 0xef0bd9c0, 0xddd7, 0x11db, 0xbf49, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid k_iid_volume   = { 0x09e8ede0, 0xddde, 0x11db, 0xb4f6, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid k_iid_bq       = { 0x2bc99cc0, 0xddd4, 0x11db, 0x8d99, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid k_iid_asbq     = { 0x198e4940, 0xc5d7, 0x11dd, 0xad8b, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid k_iid_androidcfg = { 0x89f6a7e0, 0xbeac, 0x11df, 0x8b5c, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid k_iid_record   = { 0xc5657aa0, 0xdddb, 0x11db, 0x82f7, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_ENGINE = &k_iid_engine, *const g_SL_IID_PLAY = &k_iid_play, *const g_SL_IID_VOLUME = &k_iid_volume,
                    *const g_SL_IID_BUFFERQUEUE = &k_iid_bq, *const g_SL_IID_ANDROIDSIMPLEBUFFERQUEUE = &k_iid_asbq,
                    *const g_SL_IID_ANDROIDCONFIGURATION = &k_iid_androidcfg, *const g_SL_IID_RECORD = &k_iid_record;

/* the rest of the standard interface identifiers: GetInterface answers SL_RESULT_FEATURE_UNSUPPORTED for them, but a guest that looks
 * them up (dlsym of the variable) must find one */
static const sl_iid k_iid_x_null = { 0xec7178ec, 0xe5e1, 0x4432, 0xa3f4, { 0x46, 0x57, 0xe6, 0x79, 0x52, 0x10 } };
static const sl_iid *const g_SL_IID_NULL = &k_iid_x_null;
static const sl_iid k_iid_x_object = { 0x79216360, 0xddd7, 0x11db, 0xac16, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_OBJECT = &k_iid_x_object;
static const sl_iid k_iid_x_enginecapabilities = { 0x8320d0a0, 0xddd5, 0x11db, 0xa1b1, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_ENGINECAPABILITIES = &k_iid_x_enginecapabilities;
static const sl_iid k_iid_x_audioiodevicecapabilities = { 0xb2564dc0, 0xddd3, 0x11db, 0xbd62, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_AUDIOIODEVICECAPABILITIES = &k_iid_x_audioiodevicecapabilities;
static const sl_iid k_iid_x_outputmix = { 0x97750f60, 0xddd7, 0x11db, 0x92b1, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_OUTPUTMIX = &k_iid_x_outputmix;
static const sl_iid k_iid_x_seek = { 0xd43135a0, 0xdddc, 0x11db, 0xb458, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_SEEK = &k_iid_x_seek;
static const sl_iid k_iid_x_prefetchstatus = { 0x2a41ee80, 0xddd8, 0x11db, 0x8a77, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_PREFETCHSTATUS = &k_iid_x_prefetchstatus;
static const sl_iid k_iid_x_playbackrate = { 0x2e3b2a40, 0xddda, 0x11db, 0xa349, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_PLAYBACKRATE = &k_iid_x_playbackrate;
static const sl_iid k_iid_x_effectsend = { 0x56e7d200, 0xddd4, 0x11db, 0xaefb, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_EFFECTSEND = &k_iid_x_effectsend;
static const sl_iid k_iid_x_metadataextraction = { 0xaa5b1f80, 0xddd6, 0x11db, 0xac8e, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_METADATAEXTRACTION = &k_iid_x_metadataextraction;
static const sl_iid k_iid_x_audiodecodercapabilities = { 0x3fe5a3a0, 0xfcc6, 0x11db, 0x94ac, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_AUDIODECODERCAPABILITIES = &k_iid_x_audiodecodercapabilities;
static const sl_iid k_iid_x_audioencodercapabilities = { 0xf52a340, 0xfcd1, 0x11db, 0xa993, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_AUDIOENCODERCAPABILITIES = &k_iid_x_audioencodercapabilities;
static const sl_iid k_iid_x_environmentalreverb = { 0xc2e5d5f0, 0x94bd, 0x4763, 0x9cac, { 0x4e, 0x23, 0x4d, 0x06, 0x83, 0x9e } };
static const sl_iid *const g_SL_IID_ENVIRONMENTALREVERB = &k_iid_x_environmentalreverb;
static const sl_iid k_iid_x_presetreverb = { 0x47382d60, 0xddd8, 0x11db, 0xbf3a, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_PRESETREVERB = &k_iid_x_presetreverb;
static const sl_iid k_iid_x_equalizer = { 0xbed4300, 0xddd6, 0x11db, 0x8f34, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_EQUALIZER = &k_iid_x_equalizer;
static const sl_iid k_iid_x_bassboost = { 0x634f220, 0xddd4, 0x11db, 0xa0fc, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_BASSBOOST = &k_iid_x_bassboost;
static const sl_iid k_iid_x_virtualizer = { 0x37cc2c00, 0xdddd, 0x11db, 0x8577, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_VIRTUALIZER = &k_iid_x_virtualizer;
static const sl_iid k_iid_x_mutesolo = { 0x5a28ebe0, 0xddd8, 0x11db, 0xab09, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_MUTESOLO = &k_iid_x_mutesolo;
static const sl_iid k_iid_x_metadatatraversal = { 0xc43662c0, 0xddd6, 0x11db, 0xa7ab, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_METADATATRAVERSAL = &k_iid_x_metadatatraversal;
static const sl_iid k_iid_x_dynamicsource = { 0xc55cc100, 0x38b, 0x11dc, 0xbb45, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_DYNAMICSOURCE = &k_iid_x_dynamicsource;
static const sl_iid k_iid_x_3dlocation = { 0x2b878020, 0xddd8, 0x11db, 0x8e9b, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_3DLOCATION = &k_iid_x_3dlocation;
static const sl_iid k_iid_x_led = { 0x2cc1cd80, 0xddd6, 0x11db, 0x807e, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_LED = &k_iid_x_led;
static const sl_iid k_iid_x_vibra = { 0x169a8d60, 0xdddd, 0x11db, 0x923d, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_VIBRA = &k_iid_x_vibra;
static const sl_iid k_iid_x_midimessage = { 0xddf4a820, 0xddd6, 0x11db, 0xb174, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_MIDIMESSAGE = &k_iid_x_midimessage;
static const sl_iid k_iid_x_androideffect = { 0xae12da60, 0x7ac0, 0x11df, 0xb3d5, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_ANDROIDEFFECT = &k_iid_x_androideffect;
static const sl_iid k_iid_x_androideffectsend = { 0x7be462c0, 0xbc43, 0x11df, 0x8670, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_ANDROIDEFFECTSEND = &k_iid_x_androideffectsend;
static const sl_iid k_iid_x_androideffectcapabilities = { 0x6a4f6d60, 0xb5e6, 0x11df, 0xbb3b, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_ANDROIDEFFECTCAPABILITIES = &k_iid_x_androideffectcapabilities;
static const sl_iid k_iid_x_androidbufferqueuesource = { 0x7fc1a460, 0xeec1, 0x11e0, 0xa4c9, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_ANDROIDBUFFERQUEUESOURCE = &k_iid_x_androidbufferqueuesource;
static const sl_iid k_iid_x_androidacousticechocancellation = { 0x7b491460, 0x8d4d, 0x11e0, 0xbd61, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_ANDROIDACOUSTICECHOCANCELLATION = &k_iid_x_androidacousticechocancellation;
static const sl_iid k_iid_x_androidautomaticgaincontrol = { 0xa8abfe0, 0x654c, 0x11e0, 0xba26, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_ANDROIDAUTOMATICGAINCONTROL = &k_iid_x_androidautomaticgaincontrol;
static const sl_iid k_iid_x_androidnoisesuppression = { 0x58b4b260, 0x8e06, 0x11e0, 0xaa8e, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_ANDROIDNOISESUPPRESSION = &k_iid_x_androidnoisesuppression;
static const sl_iid k_iid_x_androidacousticechocancellation2 = { 0x7b491461, 0x8d4d, 0x11e0, 0xbd61, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const sl_iid *const g_SL_IID_ANDROIDACOUSTICECHOCANCELLATION2 = &k_iid_x_androidacousticechocancellation2;

typedef struct { const void *const *vt; } sl_if;     /* an interface: the guest sees a pointer to the table pointer */

#define MAX_QUEUE 16
enum { K_ENGINE = 1, K_MIX, K_PLAYER };

typedef struct sl_object {
    const void *vt_object;                 /* must be first: SLObjectItf points here */
    int kind;
    int state;
    /* the interfaces an object can hand out */
    const void *vt_engine, *vt_play, *vt_volume, *vt_bq, *vt_config;
    /* a player's queue */
    pthread_mutex_t mu;
    struct { const void *data; uint32_t size; } q[MAX_QUEUE];
    int qhead, qcount;
    uint32_t qindex;
    void (*bq_cb)(void *caller, void *ctx);
    void *bq_ctx;
    int channels, rate;
    int bytes;                             /* per sample in the guest's buffers: 1, 2, 3 or 4 */
    int repr;                              /* SL_PCM_REPRESENTATION_*: 8-bit is unsigned, the rest signed, unless PCM_EX says */
    bool big_endian;
    int16_t *conv; size_t conv_cap;        /* the buffer in 16-bit, for the host */
    _Atomic int16_t millibel;              /* SLVolumeItf: 0 is full volume, negative is quieter */
    atomic_bool muted;
    _Atomic uint64_t played;               /* frames handed to the host since the player was made (SLPlayItf GetPosition) */
    atomic_int play_state;
    atomic_bool thread_run;
    pthread_t thread;
    bool thread_started;
} sl_object;

static sl_object *obj_of_object(const void *itf) { return (sl_object *)itf; }
#define OBJ_FROM(itf, field) ((sl_object *)((const char *)(itf) - offsetof(sl_object, field)))

/* ---- SLObjectItf */
static uint32_t o_Realize(const void *self, uint32_t async) { (void)async; sl_object *o = obj_of_object(self); o->state = SL_OBJECT_REALIZED; return SL_OK; }
static uint32_t o_Resume(const void *self, uint32_t async) { (void)self; (void)async; return SL_OK; }
static uint32_t o_GetState(const void *self, uint32_t *state) { if (state) *state = (uint32_t)obj_of_object(self)->state; return SL_OK; }
static uint32_t o_GetInterface(const void *self, const sl_iid *iid, const void **out)
{
    sl_object *o = obj_of_object(self);
    if (!out) return SL_PARAMETER_INVALID;
    if (iid == &k_iid_engine && o->kind == K_ENGINE) { *out = &o->vt_engine; return SL_OK; }
    if (iid == &k_iid_play && o->kind == K_PLAYER) { *out = &o->vt_play; return SL_OK; }
    if (iid == &k_iid_volume && (o->kind == K_PLAYER || o->kind == K_MIX)) { *out = &o->vt_volume; return SL_OK; }
    if ((iid == &k_iid_asbq || iid == &k_iid_bq) && o->kind == K_PLAYER) { *out = &o->vt_bq; return SL_OK; }
    if (iid == &k_iid_androidcfg && o->kind == K_PLAYER) { *out = &o->vt_config; return SL_OK; }
    *out = NULL;
    return SL_FEATURE_UNSUPPORTED;
}
static uint32_t o_RegisterCallback(const void *self, void *cb, void *ctx) { (void)self; (void)cb; (void)ctx; return SL_OK; }
static void o_AbortAsyncOperation(const void *self) { (void)self; }
static void player_stop_thread(sl_object *o);
static void o_Destroy(const void *self)
{
    sl_object *o = obj_of_object(self);
    if (o->kind == K_PLAYER) player_stop_thread(o);
    free(o->conv);
    free(o);
}
static uint32_t o_SetPriority(const void *self, int32_t p, uint32_t pre) { (void)self; (void)p; (void)pre; return SL_OK; }
static uint32_t o_GetPriority(const void *self, int32_t *p, uint32_t *pre) { (void)self; if (p) *p = 0; if (pre) *pre = 0; return SL_OK; }
static uint32_t o_SetLoss(const void *self, uint32_t n, const void *ids, uint32_t en) { (void)self; (void)n; (void)ids; (void)en; return SL_OK; }

static const void *const k_vt_object[] = { o_Realize, o_Resume, o_GetState, o_GetInterface, o_RegisterCallback, o_AbortAsyncOperation, o_Destroy, o_SetPriority, o_GetPriority, o_SetLoss };

static sl_object *new_object(int kind)
{
    sl_object *o = calloc(1, sizeof(*o));
    if (!o) return NULL;
    o->vt_object = k_vt_object;
    o->kind = kind; o->state = SL_OBJECT_UNREALIZED;
    pthread_mutex_init(&o->mu, NULL);
    return o;
}

/* ---- SLPlayItf and the player's thread */

/* The guest's samples, as 16-bit signed for the host, with the volume applied: 8-bit unsigned, 16-bit, packed 24-bit, 32-bit integer
 * and 32-bit float (Android's PCM_EX), in either byte order. 16-bit at full volume is handed over as it is. */
static const int16_t *to_s16(sl_object *o, const void *data, int n)
{
    int mb = atomic_load(&o->millibel);
    bool mute = atomic_load(&o->muted);
    if (o->bytes == 2 && o->repr != SL_PCM_REPRESENTATION_UNSIGNED_INT && !o->big_endian && mb >= 0 && !mute) return data;
    if (n <= 0) return NULL;
    if (o->conv_cap < (size_t)n) {
        int16_t *c = realloc(o->conv, (size_t)n * sizeof(int16_t));
        if (!c) return NULL;
        o->conv = c; o->conv_cap = (size_t)n;
    }
    float gain = mute ? 0.0f : mb >= 0 ? 1.0f : powf(10.0f, (float)mb / 2000.0f);
    const uint8_t *p = data;
    for (int i = 0; i < n; i++) {
        float v;                                       /* -1 .. 1 */
        switch (o->bytes) {
        case 1: v = o->repr == SL_PCM_REPRESENTATION_SIGNED_INT ? (int8_t)p[i] / 128.0f : ((int)p[i] - 128) / 128.0f; break;
        case 2: {
            uint16_t u = o->big_endian ? (uint16_t)(p[2 * i] << 8 | p[2 * i + 1]) : (uint16_t)(p[2 * i] | p[2 * i + 1] << 8);
            v = o->repr == SL_PCM_REPRESENTATION_UNSIGNED_INT ? ((int)u - 32768) / 32768.0f : (int16_t)u / 32768.0f;
            break;
        }
        case 3: {
            const uint8_t *s = p + 3 * (size_t)i;
            int32_t x = o->big_endian ? (s[0] << 16 | s[1] << 8 | s[2]) : (s[2] << 16 | s[1] << 8 | s[0]);
            if (o->repr == SL_PCM_REPRESENTATION_UNSIGNED_INT) x -= 1 << 23; else if (x & 0x800000) x -= 1 << 24;
            v = x / 8388608.0f;
            break;
        }
        default: {
            const uint8_t *s = p + 4 * (size_t)i;
            uint32_t u = o->big_endian ? ((uint32_t)s[0] << 24 | (uint32_t)s[1] << 16 | (uint32_t)s[2] << 8 | s[3])
                                       : ((uint32_t)s[3] << 24 | (uint32_t)s[2] << 16 | (uint32_t)s[1] << 8 | s[0]);
            if (o->repr == SL_PCM_REPRESENTATION_FLOAT) { float fv; memcpy(&fv, &u, 4); v = fv != fv ? 0.0f : fv; }
            else if (o->repr == SL_PCM_REPRESENTATION_UNSIGNED_INT) v = ((double)u - 2147483648.0) / 2147483648.0;
            else v = (int32_t)u / 2147483648.0f;
            break;
        }
        }
        v *= gain;
        int s = (int)lrintf(v * 32767.0f);
        o->conv[i] = (int16_t)(s < -32768 ? -32768 : s > 32767 ? 32767 : s);
    }
    return o->conv;
}

static void *player_pump(void *arg)
{
    sl_object *o = arg;
    pthread_setname_np("opensl-pump");
    while (atomic_load(&o->thread_run)) {
        if (atomic_load(&o->play_state) != SL_PLAYING) { usleep(2000); continue; }
        pthread_mutex_lock(&o->mu);
        const void *data = NULL; uint32_t size = 0;
        if (o->qcount > 0) { data = o->q[o->qhead].data; size = o->q[o->qhead].size; }
        pthread_mutex_unlock(&o->mu);
        if (!data) { usleep(1000); continue; }
        int ch = o->channels > 0 ? o->channels : 2, rate = o->rate > 0 ? o->rate : 48000;
        int frames = (int)(size / ((uint32_t)o->bytes * (uint32_t)ch));
        const int16_t *pcm = to_s16(o, data, frames * ch);
        if (pcm && frames > 0) {
            if (tl_cocos_audio_hook) tl_cocos_audio_hook(pcm, frames, ch, rate);
            else { struct timespec ts = { 0, (long)((double)frames * 1e9 / rate) }; nanosleep(&ts, NULL); }
            atomic_fetch_add(&o->played, (uint64_t)frames);
        }
        pthread_mutex_lock(&o->mu);
        if (o->qcount > 0) { o->qhead = (o->qhead + 1) % MAX_QUEUE; o->qcount--; o->qindex++; }
        pthread_mutex_unlock(&o->mu);
        if (o->bq_cb) o->bq_cb(&o->vt_bq, o->bq_ctx);
    }
    return NULL;
}
static void player_start_thread(sl_object *o)
{
    if (o->thread_started) return;
    atomic_store(&o->thread_run, true);
    pthread_attr_t a; pthread_attr_init(&a); pthread_attr_setstacksize(&a, 1u << 20);
    o->thread_started = pthread_create(&o->thread, &a, player_pump, o) == 0;
    pthread_attr_destroy(&a);
}
static void player_stop_thread(sl_object *o)
{
    if (!o->thread_started) return;
    atomic_store(&o->thread_run, false);
    pthread_join(o->thread, NULL);
    o->thread_started = false;
}

static uint32_t p_SetPlayState(const void *self, uint32_t state)
{
    sl_object *o = OBJ_FROM(self, vt_play);
    atomic_store(&o->play_state, (int)state);
    if (state == SL_PLAYING) player_start_thread(o);
    return SL_OK;
}
static uint32_t p_GetPlayState(const void *self, uint32_t *state) { sl_object *o = OBJ_FROM(self, vt_play); if (state) *state = (uint32_t)atomic_load(&o->play_state); return SL_OK; }
static uint32_t p_ok(void) { return SL_OK; }
static uint32_t p_GetDuration(const void *self, uint32_t *ms) { (void)self; if (ms) *ms = 0xFFFFFFFFu; return SL_OK; }  /* SL_TIME_UNKNOWN: a queue */
static uint32_t p_GetPosition(const void *self, uint32_t *ms)
{
    sl_object *o = OBJ_FROM(self, vt_play);
    if (ms) *ms = (uint32_t)(atomic_load(&o->played) * 1000u / (uint64_t)(o->rate > 0 ? o->rate : 48000));
    return SL_OK;
}
static uint32_t p_GetMask(const void *self, uint32_t *mask) { (void)self; if (mask) *mask = 0; return SL_OK; }
static uint32_t p_GetU32(const void *self, uint32_t *v) { (void)self; if (v) *v = 0; return SL_OK; }
/* SetPlayState, GetPlayState, GetDuration, GetPosition, RegisterCallback, SetCallbackEventsMask, GetCallbackEventsMask,
   SetMarkerPosition, ClearMarkerPosition, GetMarkerPosition, SetPositionUpdatePeriod, GetPositionUpdatePeriod */
static const void *const k_vt_play[] = { p_SetPlayState, p_GetPlayState, p_GetDuration, p_GetPosition, p_ok, p_ok, p_GetMask,
                                         p_ok, p_ok, p_GetU32, p_ok, p_GetU32 };

/* ---- SLAndroidSimpleBufferQueueItf */
static uint32_t q_Enqueue(const void *self, const void *buf, uint32_t size)
{
    sl_object *o = OBJ_FROM(self, vt_bq);
    pthread_mutex_lock(&o->mu);
    if (o->qcount >= MAX_QUEUE) { pthread_mutex_unlock(&o->mu); return SL_BUFFER_INSUFFICIENT; }
    int tail = (o->qhead + o->qcount) % MAX_QUEUE;
    o->q[tail].data = buf; o->q[tail].size = size;
    o->qcount++;
    pthread_mutex_unlock(&o->mu);
    return SL_OK;
}
static uint32_t q_Clear(const void *self)
{
    sl_object *o = OBJ_FROM(self, vt_bq);
    pthread_mutex_lock(&o->mu);
    o->qcount = 0;
    pthread_mutex_unlock(&o->mu);
    return SL_OK;
}
static uint32_t q_GetState(const void *self, uint32_t *state)       /* { count, index } */
{
    sl_object *o = OBJ_FROM(self, vt_bq);
    pthread_mutex_lock(&o->mu);
    if (state) { state[0] = (uint32_t)o->qcount; state[1] = o->qindex; }
    pthread_mutex_unlock(&o->mu);
    return SL_OK;
}
static uint32_t q_RegisterCallback(const void *self, void (*cb)(void *, void *), void *ctx)
{
    sl_object *o = OBJ_FROM(self, vt_bq);
    o->bq_cb = cb; o->bq_ctx = ctx;
    return SL_OK;
}
static const void *const k_vt_bq[] = { q_Enqueue, q_Clear, q_GetState, q_RegisterCallback };

/* ---- SLVolumeItf, SLAndroidConfigurationItf: accepted, and nothing done with them */
/* SetVolumeLevel, GetVolumeLevel, GetMaxVolumeLevel, SetMute, GetMute, EnableStereoPosition, IsEnabledStereoPosition,
   SetStereoPosition, GetStereoPosition: the level and the mute are applied to a player's samples; an output mix keeps them only */
static uint32_t v_SetLevel(const void *self, int16_t mb) { sl_object *o = OBJ_FROM(self, vt_volume); atomic_store(&o->millibel, mb > 0 ? 0 : mb); return SL_OK; }
static uint32_t v_GetLevel(const void *self, int16_t *mb) { sl_object *o = OBJ_FROM(self, vt_volume); if (mb) *mb = atomic_load(&o->millibel); return SL_OK; }
static uint32_t v_GetMax(const void *self, int16_t *mb) { (void)self; if (mb) *mb = 0; return SL_OK; }
static uint32_t v_SetMute(const void *self, uint32_t m) { sl_object *o = OBJ_FROM(self, vt_volume); atomic_store(&o->muted, m != 0); return SL_OK; }
static uint32_t v_GetMute(const void *self, uint32_t *m) { sl_object *o = OBJ_FROM(self, vt_volume); if (m) *m = atomic_load(&o->muted); return SL_OK; }
static uint32_t v_GetBool(const void *self, uint32_t *b) { (void)self; if (b) *b = 0; return SL_OK; }
static uint32_t v_GetPos(const void *self, int16_t *p) { (void)self; if (p) *p = 0; return SL_OK; }
static const void *const k_vt_volume[] = { v_SetLevel, v_GetLevel, v_GetMax, v_SetMute, v_GetMute, p_ok, v_GetBool, p_ok, v_GetPos };
static uint32_t c_Config(const void *self, const void *key, const void *value, uint32_t size) { (void)self; (void)key; (void)value; (void)size; return SL_OK; }
static const void *const k_vt_config[] = { c_Config, c_Config };

/* ---- SLEngineItf */
static uint32_t e_CreateMix(const void *self, const void **out, uint32_t n, const void *ids, const void *req)
{
    (void)self; (void)n; (void)ids; (void)req;
    sl_object *o = new_object(K_MIX);
    if (!o) return 3;
    o->vt_volume = k_vt_volume;
    *out = o;
    return SL_OK;
}
typedef struct { void *locator; void *format; } sl_data;
typedef struct { uint32_t type, channels, rate_mhz, bits, container, mask, endian; } sl_pcm;          /* SLDataFormat_PCM */
typedef struct { uint32_t type, channels, rate_mhz, bits, container, mask, endian, repr; } sl_pcm_ex; /* SLAndroidDataFormat_PCM_EX */
static uint32_t e_CreateAudioPlayer(const void *self, const void **out, const sl_data *src, const sl_data *snk, uint32_t n, const void *ids, const void *req)
{
    (void)self; (void)snk; (void)n; (void)ids; (void)req;
    sl_object *o = new_object(K_PLAYER);
    if (!o) return 3;
    o->vt_play = k_vt_play; o->vt_volume = k_vt_volume; o->vt_bq = k_vt_bq; o->vt_config = k_vt_config;
    o->channels = 2; o->rate = 48000; o->bytes = 2; o->repr = SL_PCM_REPRESENTATION_SIGNED_INT;
    const char *what = "default";
    if (src && src->format) {
        /* Both formats start alike; PCM_EX (what OpenAL Soft and AAudio-less engines on Android 5+ ask for) adds the representation,
           float among them. It used to be ignored, so its rate was taken for 48 kHz: GTA SA's 22050 Hz played fast and broken. */
        const sl_pcm_ex *f = src->format;
        if (f->type == SL_DATAFORMAT_PCM || f->type == SL_ANDROID_DATAFORMAT_PCM_EX) {
            if (f->channels >= 1 && f->channels <= 8) o->channels = (int)f->channels;
            uint32_t r = f->rate_mhz;
            if (r >= 1000000) r /= 1000;           /* milliHertz, as the standard says */
            if (r >= 4000 && r <= 384000) o->rate = (int)r;   /* some engines pass Hz: taken as they are */
            uint32_t bits = f->container >= f->bits && f->container ? f->container : f->bits;
            if (bits == 8 || bits == 16 || bits == 24 || bits == 32) o->bytes = (int)bits / 8;
            o->big_endian = f->endian == SL_BYTEORDER_BIGENDIAN;
            if (f->type == SL_ANDROID_DATAFORMAT_PCM_EX && f->repr >= SL_PCM_REPRESENTATION_SIGNED_INT && f->repr <= SL_PCM_REPRESENTATION_FLOAT)
                o->repr = (int)f->repr;
            else o->repr = o->bytes == 1 ? SL_PCM_REPRESENTATION_UNSIGNED_INT : SL_PCM_REPRESENTATION_SIGNED_INT;
            if (o->repr == SL_PCM_REPRESENTATION_FLOAT && o->bytes != 4) o->repr = SL_PCM_REPRESENTATION_SIGNED_INT;
            what = f->type == SL_DATAFORMAT_PCM ? "PCM" : "PCM_EX";
        }
    }
    atomic_store(&o->play_state, SL_STOPPED);
    tl_log_line("opensl: audio player (%d channels, %d Hz, %d-bit %s, %s)", o->channels, o->rate, o->bytes * 8,
                o->repr == SL_PCM_REPRESENTATION_FLOAT ? "float" : o->repr == SL_PCM_REPRESENTATION_UNSIGNED_INT ? "unsigned" : "signed", what);
    *out = o;
    return SL_OK;
}
static uint32_t e_Unsupported(void) { return SL_FEATURE_UNSUPPORTED; }
static const void *const k_vt_engine[] = {
    e_Unsupported, e_Unsupported, e_CreateAudioPlayer, e_Unsupported, e_Unsupported, e_Unsupported, e_Unsupported, e_CreateMix,
    e_Unsupported, e_Unsupported, e_Unsupported, e_Unsupported, e_Unsupported, e_Unsupported, e_Unsupported
};

static uint32_t b_slCreateEngine(const void **engine, uint32_t n, const void *opts, uint32_t nif, const void *ifs, const void *req)
{
    (void)n; (void)opts; (void)nif; (void)ifs; (void)req;
    sl_object *o = new_object(K_ENGINE);
    if (!o) return 3;
    o->vt_engine = k_vt_engine;
    *engine = o;
    return SL_OK;
}

#define SLID(name) TL_DATA(#name, &g_##name)
const tl_bionic_entry tl_tab_opensles[] = {
    TL_WRAP("slCreateEngine", b_slCreateEngine),
    SLID(SL_IID_ENGINE), SLID(SL_IID_PLAY), SLID(SL_IID_VOLUME), SLID(SL_IID_BUFFERQUEUE), SLID(SL_IID_ANDROIDSIMPLEBUFFERQUEUE),
    SLID(SL_IID_ANDROIDCONFIGURATION), SLID(SL_IID_RECORD),
    SLID(SL_IID_NULL),
    SLID(SL_IID_OBJECT),
    SLID(SL_IID_ENGINECAPABILITIES),
    SLID(SL_IID_AUDIOIODEVICECAPABILITIES),
    SLID(SL_IID_OUTPUTMIX),
    SLID(SL_IID_SEEK),
    SLID(SL_IID_PREFETCHSTATUS),
    SLID(SL_IID_PLAYBACKRATE),
    SLID(SL_IID_EFFECTSEND),
    SLID(SL_IID_METADATAEXTRACTION),
    SLID(SL_IID_AUDIODECODERCAPABILITIES),
    SLID(SL_IID_AUDIOENCODERCAPABILITIES),
    SLID(SL_IID_ENVIRONMENTALREVERB),
    SLID(SL_IID_PRESETREVERB),
    SLID(SL_IID_EQUALIZER),
    SLID(SL_IID_BASSBOOST),
    SLID(SL_IID_VIRTUALIZER),
    SLID(SL_IID_MUTESOLO),
    SLID(SL_IID_METADATATRAVERSAL),
    SLID(SL_IID_DYNAMICSOURCE),
    SLID(SL_IID_3DLOCATION),
    SLID(SL_IID_LED),
    SLID(SL_IID_VIBRA),
    SLID(SL_IID_MIDIMESSAGE),
    SLID(SL_IID_ANDROIDEFFECT),
    SLID(SL_IID_ANDROIDEFFECTSEND),
    SLID(SL_IID_ANDROIDEFFECTCAPABILITIES),
    SLID(SL_IID_ANDROIDBUFFERQUEUESOURCE),
    SLID(SL_IID_ANDROIDACOUSTICECHOCANCELLATION),
    SLID(SL_IID_ANDROIDAUTOMATICGAINCONTROL),
    SLID(SL_IID_ANDROIDNOISESUPPRESSION),
    SLID(SL_IID_ANDROIDACOUSTICECHOCANCELLATION2),
    TL_END
};
