/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Decoders for Java apps' android.media.MediaCodec (husk.MediaCodecNative's natives): H.264 and HEVC through VideoToolbox, AAC and
 * MP3 through AudioToolbox -- the same frameworks on iOS and macOS.
 *
 * Video: MediaCodec takes Annex-B access units (start codes, parameter sets in band or as csd-0/csd-1); VideoToolbox takes
 * length-prefixed NAL units under a format description built from the parameter sets. Each queued access unit is submitted to
 * VideoToolbox asynchronously. A bounded in-flight counter and a short Java-side wait prevent compressed packets from outrunning
 * frame callbacks; decoded frames (32BGRA pixel buffers) are sorted by presentation time and handed to MediaCodec in display order.
 * The Java side draws each frame into a Bitmap and the app's Surface.
 *
 * Audio: one compressed packet per queued buffer (as MediaCodec is fed), decoded to interleaved 16-bit PCM. AAC, MP3, and -- for TV
 * and IPTV streams, where they are the usual sound -- AC-3 and E-AC-3 (Dolby Digital / Plus, E-AC-3 JOC through its E-AC-3 core) and
 * MPEG-1 Layer I/II (DVB's audio); each only where this iOS has the decoder (audio_available asks AudioToolbox). Husk's AudioTrack
 * plays mono or stereo, so a 5.1 or 7.1 stream is mixed down to stereo here, by the channel layout the decoder reports.
 */
#define _DARWIN_C_SOURCE
#include <Accelerate/Accelerate.h>
#include <AudioToolbox/AudioToolbox.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <time.h>
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "husk-tl-dvm-internal.h"

void tl_log_line(const char *fmt, ...);
typedef struct { uint32_t width, height, stride; int32_t format; uint32_t flags; } tl_abitmap_info;
int tl_AndroidBitmap_getInfo(void *env, void *bitmap, tl_abitmap_info *info);
int tl_AndroidBitmap_lockPixels(void *env, void *bitmap, void **addr);
int tl_AndroidBitmap_unlockPixels(void *env, void *bitmap);

#define NAT(fn) static bool fn(jobj *self, const jvalue *a, jvalue *ret)
static jvalue I(int32_t v) { jvalue r; r.j = (uint32_t)v; return r; }
static jvalue J(int64_t v) { jvalue r; r.j = v; return r; }
static jvalue Z(bool v) { jvalue r; r.j = v; return r; }
static jvalue L(void *p) { jvalue r; r.j = 0; r.l = p; return r; }

enum { K_AVC = 1, K_HEVC, K_AAC, K_MP3, K_AC3, K_EAC3, K_MP2, K_MP1 };
#define MAX_DEC_CH 16                               /* channels a decoder may hand out before the mixdown */
enum { FLAG_KEY_FRAME = 1, FLAG_EOS = 4 };
#define REORDER 4                                   /* frames held to put decode order into display order */

typedef struct frame { CVPixelBufferRef pb; int64_t pts; struct frame *next; } frame;
typedef struct pcm { uint8_t *data; int len; int64_t pts; struct pcm *next; } pcm;
typedef struct { uint8_t *d; size_t n; } blob;

typedef struct codec {
    int kind;
    pthread_mutex_t lock;
    pthread_cond_t frame_cond;
    int video_inflight;
    bool trace;
    /* video */
    /* Parameter sets by id, as a decoder keeps them: a stream may carry several PPS (and SPS) at once and switch between them
       picture by picture. Holding only the last one made each new PPS look like a format change, so the session was recreated
       -- and every picture dropped while it waited for the next IDR -- over and over (IPTV: black video). */
    blob vps[16], sps[32], pps[256];
    int16_t pps_sps[256];                           /* the SPS a PPS refers to (H.264); -1 when unknown */
    bool params_changed, seq_changed;               /* seq: an SPS or VPS, not only a PPS */
    bool waiting_for_random_access;
    unsigned waiting_log_count, non_vcl_log_count, waiting_dropped;
    bool recovery_seen;                             /* a recovery-point SEI came (perhaps in a buffer of its own) while waiting */
    /* Audio PTS continuity diagnostics (no timestamp rewriting). */
    bool audio_pts_valid;
    int64_t audio_next_pts;
    unsigned audio_timing_log_count;
    CMVideoFormatDescriptionRef fmt;
    VTDecompressionSessionRef vt;
    frame *sorted; int nsorted;                     /* decoded, by presentation time */
    frame *ready, **ready_tail;                     /* in display order, for the Java side */
    int width, height;
    long decoded, failed;
    /* audio */
    AudioConverterRef conv;
    AudioStreamBasicDescription in, out;
    const uint8_t *packet; UInt32 packet_len; AudioStreamPacketDescription desc;
    pcm *pcms, **pcm_tail;
    jobj *pcm_array;                                 /* one reusable Java byte[] scratch for nextPcm */
    uint32_t pcm_array_capacity;
    int rate, channels;                             /* what the Java side is given (channels: 1 or 2) */
    int in_channels;                                /* the stream's own, which the decoder hands out */
    float gl[MAX_DEC_CH], gr[MAX_DEC_CH];           /* in_channels > 2: each decoded channel's share of left and right */
} codec;

static bool trace_on(void) { static int t = -1; if (t < 0) t = getenv("TL_MEDIA_TRACE") != NULL; return t; }

/* ---- video ---- */

static void blob_set(blob *b, const uint8_t *d, size_t n, bool *changed)
{
    if (!b || !d || n == 0) return;
    if (b->n == n && b->d && !memcmp(b->d, d, n)) return;
    uint8_t *copy = malloc(n);
    if (!copy) return;
    memcpy(copy, d, n);
    free(b->d); b->d = copy; b->n = n;
    *changed = true;
}

/* ---- parameter-set ids: the first fields of the RBSP, read past emulation-prevention bytes ---- */
typedef struct { uint8_t b[64]; size_t n, bit; } rbsp;
static void rbsp_init(rbsp *r, const uint8_t *nal, size_t n, size_t skip)
{
    r->n = 0; r->bit = 0;
    int zeros = 0;
    for (size_t i = skip; i < n && r->n < sizeof(r->b); i++) {
        if (zeros >= 2 && nal[i] == 3) { zeros = 0; continue; }
        zeros = nal[i] == 0 ? zeros + 1 : 0;
        r->b[r->n++] = nal[i];
    }
}
static bool rbsp_bits(rbsp *r, unsigned k, uint32_t *v)
{
    uint32_t x = 0;
    for (unsigned i = 0; i < k; i++) {
        if (r->bit >= r->n * 8) return false;
        x = x << 1 | ((r->b[r->bit >> 3] >> (7 - (r->bit & 7))) & 1);
        r->bit++;
    }
    *v = x;
    return true;
}
static bool rbsp_ue(rbsp *r, uint32_t *v)
{
    unsigned lz = 0; uint32_t bit;
    for (;;) { if (!rbsp_bits(r, 1, &bit)) return false; if (bit) break; if (++lz > 31) return false; }
    uint32_t rest = 0;
    if (lz && !rbsp_bits(r, lz, &rest)) return false;
    *v = ((1u << lz) - 1) + rest;
    return true;
}
/* H.264 SPS: profile, constraint flags and level, then seq_parameter_set_id */
static int avc_sps_id(const uint8_t *nal, size_t n)
{
    rbsp r; rbsp_init(&r, nal, n, 1); uint32_t skip, id;
    if (!rbsp_bits(&r, 24, &skip) || !rbsp_ue(&r, &id) || id > 31) return -1;
    return (int)id;
}
/* H.264 PPS: pic_parameter_set_id, then the SPS it uses */
static int avc_pps_id(const uint8_t *nal, size_t n, int *sps_id)
{
    rbsp r; rbsp_init(&r, nal, n, 1); uint32_t id, sid;
    if (!rbsp_ue(&r, &id) || id > 255) return -1;
    *sps_id = rbsp_ue(&r, &sid) && sid <= 31 ? (int)sid : -1;
    return (int)id;
}
static int hevc_vps_id(const uint8_t *nal, size_t n) { return n > 2 ? nal[2] >> 4 : -1; }
/* HEVC SPS: vps id, sub-layer count, profile_tier_level, then sps_seq_parameter_set_id */
static int hevc_sps_id(const uint8_t *nal, size_t n)
{
    rbsp r; rbsp_init(&r, nal, n, 2); uint32_t v, msl, id;
    if (!rbsp_bits(&r, 4, &v) || !rbsp_bits(&r, 3, &msl) || !rbsp_bits(&r, 1, &v)) return -1;
    if (!rbsp_bits(&r, 32, &v) || !rbsp_bits(&r, 32, &v) || !rbsp_bits(&r, 32, &v)) return -1;   /* general profile/tier/level: 96 bits */
    uint32_t prof[8] = {0}, lev[8] = {0};
    for (uint32_t i = 0; i < msl; i++) { if (!rbsp_bits(&r, 1, &prof[i]) || !rbsp_bits(&r, 1, &lev[i])) return -1; }
    if (msl > 0) for (uint32_t i = msl; i < 8; i++) if (!rbsp_bits(&r, 2, &v)) return -1;
    for (uint32_t i = 0; i < msl; i++) {
        if (prof[i] && (!rbsp_bits(&r, 32, &v) || !rbsp_bits(&r, 32, &v) || !rbsp_bits(&r, 24, &v))) return -1;   /* 88 bits */
        if (lev[i] && !rbsp_bits(&r, 8, &v)) return -1;
    }
    if (!rbsp_ue(&r, &id) || id > 15) return -1;
    return (int)id;
}
static int hevc_pps_id(const uint8_t *nal, size_t n)
{
    rbsp r; rbsp_init(&r, nal, n, 2); uint32_t id;
    return rbsp_ue(&r, &id) && id < 64 ? (int)id : -1;
}
/* An H.264 slice that starts a picture coded without reference to others (I or SI): a place a stream without IDRs can be joined. */
static bool avc_intra_slice(const uint8_t *nal, size_t n)
{
    rbsp r; rbsp_init(&r, nal, n, 1); uint32_t first_mb, type;
    if (!rbsp_ue(&r, &first_mb) || !rbsp_ue(&r, &type)) return false;
    return first_mb == 0 && (type % 5 == 2 || type % 5 == 4);
}
/* An SEI message list holding a recovery point (payload type 6): the encoder says decoding may start here. */
static bool sei_recovery_point(const uint8_t *nal, size_t n, size_t header)
{
    size_t i = header;
    while (i + 2 <= n) {
        uint32_t type = 0, size = 0;
        while (i < n && nal[i] == 0xFF) { type += 255; i++; }
        if (i >= n) return false;
        type += nal[i++];
        while (i < n && nal[i] == 0xFF) { size += 255; i++; }
        if (i >= n) return false;
        size += nal[i++];
        if (type == 6) return true;
        if (i + size >= n) return false;                    /* the last message (the rest is rbsp_trailing_bits) */
        i += size;
        if (nal[i] == 0x80 && i + 1 == n) return false;
    }
    return false;
}

static void ready_push(codec *c, frame *f) { f->next = NULL; *c->ready_tail = f; c->ready_tail = &f->next; }
/* the earliest sorted frame moves to the ready queue */
static void release_sorted(codec *c, int keep)
{
    while (c->nsorted > keep) {
        frame *f = c->sorted; c->sorted = f->next; c->nsorted--;
        ready_push(c, f);
    }
}

/* VideoToolbox calls this when an asynchronous decode completes. Every
   accepted frame (including failures) releases one in-flight slot. */
static void vt_out(void *ref, void *src, OSStatus st, VTDecodeInfoFlags fl,
                   CVImageBufferRef img, CMTime pts, CMTime dur)
{
    (void)src; (void)fl; (void)dur;
    codec *c = ref;
    if (st != noErr || !img) {
        pthread_mutex_lock(&c->lock);
        if (c->video_inflight > 0) c->video_inflight--;
        c->failed++;
        int failed = (int)c->failed;
        pthread_cond_broadcast(&c->frame_cond);
        pthread_mutex_unlock(&c->lock);
        if (c->trace || failed < 4)
            tl_log_line("media: frame not decoded (%d)", (int)st);
        return;
    }

    frame *f = calloc(1, sizeof(*f));
    if (!f) {
        pthread_mutex_lock(&c->lock);
        if (c->video_inflight > 0) c->video_inflight--;
        c->failed++;
        pthread_cond_broadcast(&c->frame_cond);
        pthread_mutex_unlock(&c->lock);
        return;
    }
    f->pb = CVPixelBufferRetain(img);
    f->pts = CMTIME_IS_VALID(pts)
        ? CMTimeConvertScale(pts, 1000000, kCMTimeRoundingMethod_Default).value
        : 0;

    pthread_mutex_lock(&c->lock);
    if (c->video_inflight > 0) c->video_inflight--;
    frame **p = &c->sorted;
    while (*p && (*p)->pts <= f->pts) p = &(*p)->next;
    f->next = *p; *p = f; c->nsorted++;
    release_sorted(c, REORDER);
    c->decoded++;
    long decoded_count = c->decoded;
    int64_t frame_pts = f->pts;
    size_t frame_w = (size_t)CVPixelBufferGetWidth(img), frame_h = (size_t)CVPixelBufferGetHeight(img);
    OSType frame_format = CVPixelBufferGetPixelFormatType(img);
    int sorted_count = c->nsorted, ready_count = 0;
    for (frame *q = c->ready; q; q = q->next) ready_count++;
    pthread_cond_broadcast(&c->frame_cond);
    pthread_mutex_unlock(&c->lock);
    if (c->trace || decoded_count <= 5) {
        tl_log_line("media: VideoToolbox callback frame #%ld pts=%lld size=%zux%zu pixel-format=0x%08x sorted=%d ready=%d",
                    decoded_count, (long long)frame_pts, frame_w, frame_h, (unsigned)frame_format,
                    sorted_count, ready_count);
    }
}

static void session_drop(codec *c)
{
    if (c->vt) {
        VTDecompressionSessionWaitForAsynchronousFrames(c->vt);
        VTDecompressionSessionInvalidate(c->vt);
        CFRelease(c->vt);
        c->vt = NULL;
    }
    c->waiting_for_random_access = true;
    c->waiting_log_count = 0;
    c->waiting_dropped = 0;
    c->recovery_seen = false;
    pthread_mutex_lock(&c->lock);
    c->video_inflight = 0;
    pthread_cond_broadcast(&c->frame_cond);
    pthread_mutex_unlock(&c->lock);
}

static bool session_make(codec *c)
{
    if (c->fmt) { CFRelease(c->fmt); c->fmt = NULL; }

    OSStatus st;
    /* every known set, SPS (and VPS) first: a picture may use any PPS the stream has sent */
    enum { MAXSETS = 16 + 32 + 256 };
    const uint8_t *ps[MAXSETS]; size_t sz[MAXSETS]; size_t np = 0, nv = 0, ns = 0, npp = 0;
    if (c->kind == K_HEVC) for (int i = 0; i < 16; i++) if (c->vps[i].n) { ps[np] = c->vps[i].d; sz[np++] = c->vps[i].n; nv++; }
    for (int i = 0; i < 32; i++) if (c->sps[i].n) { ps[np] = c->sps[i].d; sz[np++] = c->sps[i].n; ns++; }
    for (int i = 0; i < 256; i++) {
        if (!c->pps[i].n) continue;
        /* a PPS naming an SPS this stream has not sent would make the whole description invalid */
        if (c->kind == K_AVC && c->pps_sps[i] >= 0 && !c->sps[c->pps_sps[i]].n) continue;
        ps[np] = c->pps[i].d; sz[np++] = c->pps[i].n; npp++;
    }
    if (c->kind == K_AVC) {
        if (!ns || !npp) return false;
        st = CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, np, ps, sz, 4, &c->fmt);
    } else {
        if (!nv || !ns || !npp) return false;
        st = CMVideoFormatDescriptionCreateFromHEVCParameterSets(NULL, np, ps, sz, 4, NULL, &c->fmt);
    }
    if (st != noErr || !c->fmt) {
        tl_log_line("media: the stream's parameter sets were refused (%d)", (int)st);
        c->fmt = NULL;
        return false;
    }

    CGSize dims = CMVideoFormatDescriptionGetPresentationDimensions(c->fmt, true, false);
    c->width = (int)dims.width;
    c->height = (int)dims.height;
    if (c->vt && VTDecompressionSessionCanAcceptFormatDescription(c->vt, c->fmt)) {
        if (c->trace) tl_log_line("media: reusing active %s decoder for updated parameter sets",
                                  c->kind == K_AVC ? "H.264" : "HEVC");
        return true;
    }

    if (c->vt) {
        tl_log_line("media: active %s decoder cannot accept the updated parameter sets (%zu VPS, %zu SPS, %zu PPS); recreating session",
                    c->kind == K_AVC ? "H.264" : "HEVC", nv, ns, npp);
        session_drop(c);
    }
    int pixel_format = kCVPixelFormatType_32BGRA;
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &pixel_format);
    if (!number) {
        tl_log_line("media: could not allocate the VideoToolbox pixel-format value");
        return false;
    }
    const void *keys[] = { kCVPixelBufferPixelFormatTypeKey };
    const void *values[] = { number };
    CFDictionaryRef destination = CFDictionaryCreate(
        NULL, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(number);
    if (!destination) {
        tl_log_line("media: could not create the VideoToolbox destination attributes");
        return false;
    }

    VTDecompressionOutputCallbackRecord callback = { vt_out, c };
    st = VTDecompressionSessionCreate(
        NULL, c->fmt, NULL, destination, &callback, &c->vt);
    CFRelease(destination);
    if (st != noErr || !c->vt) {
        tl_log_line("media: no decoder session (%d)", (int)st);
        c->vt = NULL;
        return false;
    }
    tl_log_line("media: %s decoder for %dx%d",
                c->kind == K_AVC ? "H.264" : "HEVC", c->width, c->height);
    return true;
}

static int nal_type(const codec *c, const uint8_t *nal)
{
    return c->kind == K_AVC ? (nal[0] & 0x1f) : ((nal[0] >> 1) & 0x3f);
}

/* Accept elementary-stream NALs only. In particular, do not feed an AVCC/hvcC
   configuration record to VideoToolbox as though it were a video access unit. */
static bool nal_header_valid(const codec *c, const uint8_t *nal, size_t n)
{
    if (!nal || n < (c->kind == K_HEVC ? 2u : 1u) || (nal[0] & 0x80)) return false;
    if (c->kind == K_HEVC) return (nal[1] & 0x07) != 0;
    int type = nal[0] & 0x1f;
    return type > 0 && type < 24;
}

/* Return the next 3- or 4-byte Annex-B delimiter. */
static size_t find_start_code(const uint8_t *d, size_t n, size_t from, size_t *code_len)
{
    if (!d || !code_len || n < 3) return SIZE_MAX;
    for (size_t i = from; i + 3 <= n; i++) {
        if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1) {
            *code_len = 3; return i;
        }
        if (i + 4 <= n && d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 0 && d[i + 3] == 1) {
            *code_len = 4; return i;
        }
    }
    return SIZE_MAX;
}

typedef struct {
    codec *c; uint8_t *out; size_t len, cap;
    unsigned nals, vcl_nals, first_type, first_vcl_type, random_access_type;
    size_t largest_nal;
    bool random_access, allocation_failed;
    bool intra_slice;                               /* an I picture: where a stream without IDR/IRAP pictures can be joined */
} nal_walk;

static void take_nal(void *arg, const uint8_t *nal, size_t n)
{
    nal_walk *w = arg; codec *c = w->c;
    if (!nal_header_valid(c, nal, n)) return;
    int t = nal_type(c, nal);
    if (!w->nals) w->first_type = (unsigned)t;
    w->nals++;
    if (n > w->largest_nal) w->largest_nal = n;
    if (c->kind == K_AVC) {
        if (t >= 1 && t <= 5) {
            if (w->vcl_nals == 0) w->first_vcl_type = t;
            w->vcl_nals++;
        }
        if (t == 5) { w->random_access = true; w->random_access_type = t; }
        if (t == 1 && c->waiting_for_random_access && avc_intra_slice(nal, n)) w->intra_slice = true;
        if (t == 6 && c->waiting_for_random_access && sei_recovery_point(nal, n, 1)) c->recovery_seen = true;
        if (t == 7) { int id = avc_sps_id(nal, n); bool ch = false; blob_set(&c->sps[id < 0 ? 0 : id], nal, n, &ch); if (ch) c->params_changed = c->seq_changed = true; return; }
        if (t == 8) {
            int sid = -1, id = avc_pps_id(nal, n, &sid);
            if (id < 0) id = 0;
            c->pps_sps[id] = (int16_t)sid;
            blob_set(&c->pps[id], nal, n, &c->params_changed);
            return;
        }
        if (t == 9) return;                                         /* access unit delimiter */
    } else {
        if (t <= 31) {
            if (w->vcl_nals == 0) w->first_vcl_type = t;
            w->vcl_nals++;
        }
        if (t >= 16 && t <= 21) { w->random_access = true; w->random_access_type = t; }
        if (t == 39 && c->waiting_for_random_access && sei_recovery_point(nal, n, 2)) c->recovery_seen = true;
        if (t == 32) { int id = hevc_vps_id(nal, n); bool ch = false; blob_set(&c->vps[id < 0 ? 0 : id], nal, n, &ch); if (ch) c->params_changed = c->seq_changed = true; return; }
        if (t == 33) { int id = hevc_sps_id(nal, n); bool ch = false; blob_set(&c->sps[id < 0 ? 0 : id], nal, n, &ch); if (ch) c->params_changed = c->seq_changed = true; return; }
        if (t == 34) { int id = hevc_pps_id(nal, n); blob_set(&c->pps[id < 0 ? 0 : id], nal, n, &c->params_changed); return; }
        if (t == 35) return;
    }
    if (n > UINT32_MAX || w->len > SIZE_MAX - n - 4) { w->allocation_failed = true; return; }
    size_t needed = w->len + n + 4;
    if (needed > w->cap) {
        size_t cap = w->cap ? w->cap : 4096;
        while (cap < needed && cap <= SIZE_MAX / 2) cap *= 2;
        if (cap < needed) cap = needed;
        uint8_t *grown = realloc(w->out, cap);
        if (!grown) { w->allocation_failed = true; return; }
        w->out = grown; w->cap = cap;
    }
    w->out[w->len++] = (uint8_t)(n >> 24); w->out[w->len++] = (uint8_t)(n >> 16); w->out[w->len++] = (uint8_t)(n >> 8); w->out[w->len++] = (uint8_t)n;
    memcpy(w->out + w->len, nal, n); w->len += n;
}

/* Validate a length-prefixed access unit without mutating codec state. MP4/AVCC
   streams can use 1-, 2-, 3- or 4-byte NAL lengths; HLS/TS normally uses Annex-B. */
static bool length_prefixed_valid(const codec *c, const uint8_t *d, size_t n, unsigned length_bytes)
{
    size_t pos = 0; unsigned count = 0;
    if (!d || !n || length_bytes < 1 || length_bytes > 4) return false;
    while (pos < n) {
        if (n - pos < length_bytes) return false;
        uint32_t len = 0;
        for (unsigned j = 0; j < length_bytes; j++) len = (len << 8) | d[pos++];
        if (!len || (size_t)len > n - pos || !nal_header_valid(c, d + pos, len)) return false;
        pos += len; count++;
    }
    return count > 0 && pos == n;
}

static bool each_nal(const codec *c, const uint8_t *d, size_t n,
                     void (*fn)(void *, const uint8_t *, size_t), void *arg)
{
    if (!d || !n) return false;
    size_t code_len = 0;
    size_t first = find_start_code(d, n, 0, &code_len);
    if (first != SIZE_MAX) {
        size_t cursor = first;
        unsigned count = 0;
        while (cursor != SIZE_MAX) {
            size_t this_len = 0;
            size_t at = find_start_code(d, n, cursor, &this_len);
            if (at == SIZE_MAX) break;
            size_t begin = at + this_len, next_len = 0;
            size_t next = find_start_code(d, n, begin, &next_len);
            size_t end = next == SIZE_MAX ? n : next;
            while (end > begin && d[end - 1] == 0) end--; /* Annex-B trailing_zero_8bits */
            if (end > begin && nal_header_valid(c, d + begin, end - begin)) {
                fn(arg, d + begin, end - begin); count++;
            } else if (end > begin) {
                return false;
            }
            cursor = next;
        }
        return count > 0;
    }
    static const unsigned candidates[] = { 4, 2, 3, 1 };
    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        unsigned lb = candidates[i];
        if (!length_prefixed_valid(c, d, n, lb)) continue;
        size_t pos = 0;
        while (pos < n) {
            uint32_t len = 0;
            for (unsigned j = 0; j < lb; j++) len = (len << 8) | d[pos++];
            fn(arg, d + pos, len); pos += len;
        }
        return true;
    }
    return false;
}

/* AVCDecoderConfigurationRecord (avcC) stores the SPS/PPS behind 16-bit lengths,
   not Annex-B start codes. Parse it explicitly instead of silently losing CSD. */
static bool parse_avcc(codec *c, const uint8_t *d, size_t n, void (*fn)(void *, const uint8_t *, size_t), void *arg)
{
    if (!d || n < 7 || d[0] != 1) return false;
    size_t pos = 5; unsigned sps_count = d[pos++] & 0x1f, pps_count = 0, count = 0;
    for (unsigned i = 0; i < sps_count; i++) {
        if (n - pos < 2) return false;
        size_t len = ((size_t)d[pos] << 8) | d[pos + 1]; pos += 2;
        if (!len || len > n - pos || !nal_header_valid(c, d + pos, len) || (d[pos] & 0x1f) != 7) return false;
        fn(arg, d + pos, len); pos += len; count++;
    }
    if (pos >= n) return false;
    pps_count = d[pos++];
    for (unsigned i = 0; i < pps_count; i++) {
        if (n - pos < 2) return false;
        size_t len = ((size_t)d[pos] << 8) | d[pos + 1]; pos += 2;
        if (!len || len > n - pos || !nal_header_valid(c, d + pos, len) || (d[pos] & 0x1f) != 8) return false;
        fn(arg, d + pos, len); pos += len; count++;
    }
    return count > 0;
}

/* HEVCDecoderConfigurationRecord (hvcC): arrays contain VPS/SPS/PPS NALs. */
static bool parse_hvcc(codec *c, const uint8_t *d, size_t n, void (*fn)(void *, const uint8_t *, size_t), void *arg)
{
    if (!d || n < 23 || d[0] != 1) return false;
    size_t pos = 23; unsigned arrays = d[22], count = 0;
    for (unsigned a = 0; a < arrays; a++) {
        if (n - pos < 3) return false;
        pos++; /* array_completeness/reserved/NAL_unit_type */
        unsigned units = ((unsigned)d[pos] << 8) | d[pos + 1]; pos += 2;
        for (unsigned u = 0; u < units; u++) {
            if (n - pos < 2) return false;
            size_t len = ((size_t)d[pos] << 8) | d[pos + 1]; pos += 2;
            if (!len || len > n - pos || !nal_header_valid(c, d + pos, len)) return false;
            fn(arg, d + pos, len); pos += len; count++;
        }
    }
    return count > 0;
}

static bool parse_codec_config(codec *c, const uint8_t *d, size_t n,
                               void (*fn)(void *, const uint8_t *, size_t), void *arg)
{
    if (!d || !n) return false;
    if (c->kind == K_AVC && n >= 7 && d[0] == 1) return parse_avcc(c, d, n, fn, arg);
    if (c->kind == K_HEVC && n >= 23 && d[0] == 1) return parse_hvcc(c, d, n, fn, arg);
    return each_nal(c, d, n, fn, arg);
}

static void video_drain(codec *c)
{
    if (c->vt) { VTDecompressionSessionFinishDelayedFrames(c->vt); VTDecompressionSessionWaitForAsynchronousFrames(c->vt); }
    pthread_mutex_lock(&c->lock); release_sorted(c, 0); pthread_mutex_unlock(&c->lock);
}

static void video_decode(codec *c, const uint8_t *d, size_t n, int64_t pts, int flags)
{
    nal_walk w = { .c = c };
    bool parsed = each_nal(c, d, n, take_nal, &w);
    if (!parsed) {
        if (c->failed < 4 || c->trace) {
            char head[64] = {0}; size_t shown = n < 16 ? n : 16, at = 0;
            for (size_t i = 0; d && i < shown && at + 3 < sizeof(head); i++)
                at += (size_t)snprintf(head + at, sizeof(head) - at, "%02X%s", d[i], i + 1 < shown ? " " : "");
            tl_log_line("media: ignored unrecognized %s access unit (%zu bytes; prefix %s)", c->kind == K_AVC ? "H.264" : "HEVC", n, head);
        }
        free(w.out); w.out = NULL; w.len = 0;
    }
    if (w.allocation_failed) {
        if (c->failed < 4 || c->trace) tl_log_line("media: access-unit NAL allocation failed (%zu bytes)", n);
        free(w.out); return;
    }
    if (c->params_changed) {
        c->params_changed = false;
        /* Only a picture parameter set changed (the sequence is the same): a new session loses its reference pictures, but
           the stream goes on decoding -- VideoToolbox conceals until the next intra picture -- rather than being dropped
           until an IDR that some streams send rarely or never. */
        bool pps_only = !c->seq_changed && c->vt && !c->waiting_for_random_access;
        c->seq_changed = false;
        /* Drain delayed pictures, but do not invalidate the decoder pre-emptively.
           session_make() first asks VideoToolbox whether the live session can accept
           the updated format description; dropping it here would discard reference
           frames even when the format change is compatible. */
        if (c->vt) video_drain(c);
        if (!session_make(c)) {
            if (c->failed < 4 || c->trace) tl_log_line("media: waiting for valid %s VPS/SPS/PPS", c->kind == K_AVC ? "H.264" : "HEVC");
        } else if (pps_only) c->waiting_for_random_access = false;
    }

    bool submit = w.len && c->vt && c->fmt;
    /* MediaCodec may deliver AUD/SEI-only buffers. They carry no coded picture and
       must not be passed to VideoToolbox as one-picture CMSampleBuffers. */
    if (submit && w.vcl_nals == 0) {
        submit = false;
        if (c->trace || c->non_vcl_log_count++ < 3)
            tl_log_line("media: ignoring non-picture %s sample (first-type=%u, %zu bytes)",
                        c->kind == K_AVC ? "H.264" : "HEVC", w.first_type, w.len);
    }
    /* A newly-created VideoToolbox session has no reference-picture history. Wait
       for an IDR/IRAP (or MediaCodec's explicit sync-frame flag) before feeding it
       inter-predicted pictures; this also recovers cleanly after an incompatible
       SPS/PPS change. */
    if (submit && c->waiting_for_random_access) {
        /* An IDR/IRAP or MediaCodec's sync flag; else, for streams that never send one (intra refresh, open GOPs: common in
           IPTV), an intra picture or a recovery-point SEI; and as a last resort after ~4 s of pictures, any picture --
           VideoToolbox conceals the few broken frames that follow, where waiting on would leave the screen black for good. */
        bool join = w.random_access || (flags & FLAG_KEY_FRAME) || w.intra_slice || c->recovery_seen || c->waiting_dropped >= 120;
        if (join) {
            c->waiting_for_random_access = false;
            c->waiting_log_count = 0;
            tl_log_line("media: %s decoding starts (%s, first-vcl=%u, first-nal=%u, flags=0x%x, after %u dropped)",
                        c->kind == K_AVC ? "H.264" : "HEVC",
                        w.random_access ? "random-access NAL" : (flags & FLAG_KEY_FRAME) ? "sync flag" : w.intra_slice ? "intra slice"
                            : c->recovery_seen ? "recovery-point SEI" : "no random-access picture in the stream",
                        w.first_vcl_type, w.first_type, flags, c->waiting_dropped);
            c->waiting_dropped = 0;
            c->recovery_seen = false;
        } else {
            c->waiting_dropped++;
            submit = false;
            if (c->trace || c->waiting_log_count++ < 4)
                tl_log_line("media: waiting for %s random-access frame; dropping NAL type %u (flags=0x%x)",
                            c->kind == K_AVC ? "H.264" : "HEVC", w.first_type, flags);
        }
    }
    if (submit) {
        if (c->trace || c->decoded + c->failed < 3)
            tl_log_line("media: submitting %s access unit: %zu bytes, %u NALs, largest=%zu, first-type=%u, pts=%lld us",
                        c->kind == K_AVC ? "H.264" : "HEVC", w.len, w.nals, w.largest_nal,
                        w.first_type, (long long)pts);
        /* VideoToolbox is asynchronous. Do not let the app submit an unlimited number of access units
           while its decode callbacks are still pending. */
        pthread_mutex_lock(&c->lock);
        while (c->video_inflight >= 4) pthread_cond_wait(&c->frame_cond, &c->lock);
        c->video_inflight++;
        pthread_mutex_unlock(&c->lock);
        CMBlockBufferRef bb = NULL; CMSampleBufferRef sb = NULL;
        OSStatus st = CMBlockBufferCreateWithMemoryBlock(NULL, NULL, w.len, NULL, NULL, 0, w.len, kCMBlockBufferAssureMemoryNowFlag, &bb);
        if (st == noErr) st = CMBlockBufferReplaceDataBytes(w.out, bb, 0, w.len);
        CMSampleTimingInfo tm = { kCMTimeInvalid, CMTimeMake(pts, 1000000), kCMTimeInvalid };
        size_t ss = w.len;
        if (st == noErr) st = CMSampleBufferCreateReady(NULL, bb, c->fmt, 1, 1, &tm, 1, &ss, &sb);
        bool submitted = false;
        if (st == noErr) {
            VTDecodeInfoFlags info = 0;
            st = VTDecompressionSessionDecodeFrame(c->vt, sb, 0, NULL, &info);
            submitted = st == noErr;
        }
        if (!submitted) {
            pthread_mutex_lock(&c->lock);
            if (c->video_inflight > 0) c->video_inflight--;
            c->failed++;
            int failed = (int)c->failed;
            pthread_cond_broadcast(&c->frame_cond);
            pthread_mutex_unlock(&c->lock);
            if (failed < 4 || c->trace) tl_log_line("media: VideoToolbox refused access unit (%d)", (int)st);
            if (st == kVTInvalidSessionErr) { session_drop(c); session_make(c); }
        }
        if (sb) CFRelease(sb);
        if (bb) CFRelease(bb);
    }
    free(w.out);
    if (flags & FLAG_EOS) video_drain(c);
}

/* ---- audio ---- */

/* AudioToolbox wants AAC's AudioSpecificConfig inside an ES descriptor (the 'esds' magic cookie) */
static size_t esds_from_asc(const uint8_t *asc, size_t n, uint8_t *out)
{
    size_t i = 0;
    out[i++] = 0x03; out[i++] = (uint8_t)(23 + n); out[i++] = 0; out[i++] = 0; out[i++] = 0;     /* ES_Descriptor, ES_ID, flags */
    out[i++] = 0x04; out[i++] = (uint8_t)(15 + n); out[i++] = 0x40; out[i++] = 0x15;             /* DecoderConfigDescriptor: AAC, audio stream */
    out[i++] = 0; out[i++] = 0; out[i++] = 0;                                                     /* buffer size */
    for (int k = 0; k < 8; k++) out[i++] = 0;                                                     /* max and average bitrate */
    out[i++] = 0x05; out[i++] = (uint8_t)n; memcpy(out + i, asc, n); i += n;                      /* DecoderSpecificInfo */
    out[i++] = 0x06; out[i++] = 1; out[i++] = 2;                                                  /* SLConfigDescriptor */
    return i;
}

static const char *audio_name(int kind)
{
    switch (kind) {
    case K_AAC: return "AAC"; case K_MP3: return "MP3"; case K_AC3: return "AC-3"; case K_EAC3: return "E-AC-3";
    case K_MP2: return "MPEG Layer II"; case K_MP1: return "MPEG Layer I"; default: return "audio";
    }
}

/* The compressed format and samples per packet of each non-AAC kind (AAC's come from its AudioSpecificConfig). */
static void audio_format(int kind, UInt32 *id, UInt32 *frames)
{
    switch (kind) {
    case K_AC3:  *id = kAudioFormatAC3;         *frames = 1536; break;
    case K_EAC3: *id = kAudioFormatEnhancedAC3; *frames = 1536; break;
    case K_MP2:  *id = kAudioFormatMPEGLayer2;  *frames = 1152; break;
    case K_MP1:  *id = kAudioFormatMPEGLayer1;  *frames = 384;  break;
    case K_AAC:  *id = kAudioFormatMPEG4AAC;    *frames = 1024; break;
    default:     *id = kAudioFormatMPEGLayer3;  *frames = 1152; break;
    }
}

/* Whether this iOS decodes the kind: an AudioConverter to 16-bit PCM can be made for it. Asked once per kind. */
static bool audio_available(int kind)
{
    static int known[K_MP1 + 1];                    /* 0 not asked, 1 yes, -1 no */
    if (kind <= 0 || kind > K_MP1) return false;
    if (known[kind]) return known[kind] > 0;
    UInt32 id, frames; audio_format(kind, &id, &frames);
    AudioStreamBasicDescription in = { .mSampleRate = 48000, .mFormatID = id, .mFramesPerPacket = frames, .mChannelsPerFrame = 2 };
    AudioStreamBasicDescription out = { .mSampleRate = 48000, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked, .mBytesPerPacket = 4, .mFramesPerPacket = 1,
        .mBytesPerFrame = 4, .mChannelsPerFrame = 2, .mBitsPerChannel = 16 };
    AudioConverterRef conv = NULL;
    OSStatus st = AudioConverterNew(&in, &out, &conv);
    if (conv) AudioConverterDispose(conv);
    known[kind] = st == noErr ? 1 : -1;
    tl_log_line("media: %s decoder %s on this device", audio_name(kind), st == noErr ? "available" : "not available");
    return st == noErr;
}

/* Left and right gains for each decoded channel, from the decoder's channel layout (or the usual order for its channel count when
 * it gives none), normalised so a full-scale mix cannot clip. */
static void downmix_gains(codec *c)
{
    int n = c->in_channels > MAX_DEC_CH ? MAX_DEC_CH : c->in_channels;
    AudioChannelLabel label[MAX_DEC_CH];
    for (int i = 0; i < n; i++) label[i] = kAudioChannelLabel_Unknown;
    bool have = false;
    UInt32 sz = 0; Boolean writable;
    if (c->conv && AudioConverterGetPropertyInfo(c->conv, kAudioConverterOutputChannelLayout, &sz, &writable) == noErr && sz >= sizeof(AudioChannelLayout)) {
        AudioChannelLayout *lay = malloc(sz);
        if (lay && AudioConverterGetProperty(c->conv, kAudioConverterOutputChannelLayout, &sz, lay) == noErr) {
            AudioChannelLayout *use = lay, *expanded = NULL;
            if (lay->mChannelLayoutTag != kAudioChannelLayoutTag_UseChannelDescriptions) {
                UInt32 esz = 0;
                if (lay->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelBitmap
                        ? AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForBitmap, sizeof(UInt32), &lay->mChannelBitmap, &esz) == noErr
                        : AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag, sizeof(AudioChannelLayoutTag), &lay->mChannelLayoutTag, &esz) == noErr) {
                    expanded = malloc(esz);
                    OSStatus st = lay->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelBitmap
                        ? AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForBitmap, sizeof(UInt32), &lay->mChannelBitmap, &esz, expanded)
                        : AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag, sizeof(AudioChannelLayoutTag), &lay->mChannelLayoutTag, &esz, expanded);
                    use = st == noErr ? expanded : NULL;
                } else use = NULL;
            }
            if (use && (int)use->mNumberChannelDescriptions >= n) {
                for (int i = 0; i < n; i++) label[i] = use->mChannelDescriptions[i].mChannelLabel;
                have = true;
            }
            free(expanded);
        }
        free(lay);
    }
    if (!have) {
        /* CoreAudio's order for 5.1 and 7.1 (L R C LFE Ls Rs [Rls Rrs]); anything else: the first two are left and right */
        static const AudioChannelLabel order[8] = { kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
            kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
            kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight };
        for (int i = 0; i < n; i++) label[i] = (n == 6 || n == 8) ? order[i] : i == 0 ? kAudioChannelLabel_Left : i == 1 ? kAudioChannelLabel_Right : kAudioChannelLabel_Unknown;
    }
    const float h = 0.70710678f;                    /* -3 dB: centre and surrounds, as ITU-R BS.775 mixes them */
    float sl = 0, sr = 0;
    for (int i = 0; i < n; i++) {
        float l = 0, r = 0;
        switch (label[i]) {
        case kAudioChannelLabel_Left: case kAudioChannelLabel_LeftCenter: case kAudioChannelLabel_LeftWide: l = 1; break;
        case kAudioChannelLabel_Right: case kAudioChannelLabel_RightCenter: case kAudioChannelLabel_RightWide: r = 1; break;
        case kAudioChannelLabel_Center: case kAudioChannelLabel_Mono: l = r = h; break;
        case kAudioChannelLabel_LFEScreen: case kAudioChannelLabel_LFE2: break;            /* phone speakers: no sub */
        case kAudioChannelLabel_LeftSurround: case kAudioChannelLabel_LeftSurroundDirect: case kAudioChannelLabel_RearSurroundLeft: l = h; break;
        case kAudioChannelLabel_RightSurround: case kAudioChannelLabel_RightSurroundDirect: case kAudioChannelLabel_RearSurroundRight: r = h; break;
        case kAudioChannelLabel_CenterSurround: l = r = 0.5f; break;
        default: l = r = 0.5f; break;
        }
        c->gl[i] = l; c->gr[i] = r; sl += l; sr += r;
    }
    float norm = sl > sr ? sl : sr;
    if (norm > 1) for (int i = 0; i < n; i++) { c->gl[i] /= norm; c->gr[i] /= norm; }
}

static bool audio_open(codec *c, const uint8_t *asc, size_t asc_n, int rate, int channels)
{
    memset(&c->in, 0, sizeof(c->in));
    uint8_t esds[128]; size_t esds_n = 0;
    if (c->kind == K_AAC) {
        if (asc && asc_n && asc_n < 64) {
            esds_n = esds_from_asc(asc, asc_n, esds);
            UInt32 sz = sizeof(c->in);
            if (AudioFormatGetProperty(kAudioFormatProperty_ASBDFromESDS, (UInt32)esds_n, esds, &sz, &c->in) != noErr) memset(&c->in, 0, sizeof(c->in));
        }
        if (!c->in.mFormatID) {
            c->in.mFormatID = kAudioFormatMPEG4AAC; c->in.mSampleRate = rate > 0 ? rate : 44100;
            c->in.mChannelsPerFrame = channels > 0 ? (UInt32)channels : 2; c->in.mFramesPerPacket = 1024;
        }
    } else {
        UInt32 id, frames; audio_format(c->kind, &id, &frames);
        c->in.mFormatID = id; c->in.mSampleRate = rate > 0 ? rate : (c->kind == K_AC3 || c->kind == K_EAC3 ? 48000 : 44100);
        c->in.mChannelsPerFrame = channels > 0 ? (UInt32)channels : 2; c->in.mFramesPerPacket = frames;
    }
    if (c->in.mChannelsPerFrame > MAX_DEC_CH) c->in.mChannelsPerFrame = MAX_DEC_CH;
    c->rate = (int)c->in.mSampleRate; c->in_channels = (int)c->in.mChannelsPerFrame;
    /* decoded in the stream's own channels; more than two are mixed down after (audio_decode) */
    UInt32 dch = c->in.mChannelsPerFrame;
    c->out = (AudioStreamBasicDescription){ .mSampleRate = c->in.mSampleRate, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked, .mBytesPerPacket = 2 * dch,
        .mFramesPerPacket = 1, .mBytesPerFrame = 2 * dch, .mChannelsPerFrame = dch, .mBitsPerChannel = 16 };
    if (c->conv) { AudioConverterDispose(c->conv); c->conv = NULL; }
    c->audio_pts_valid = false;
    c->audio_timing_log_count = 0;
    OSStatus st = AudioConverterNew(&c->in, &c->out, &c->conv);
    if (st != noErr) { tl_log_line("media: no %s decoder (%d)", audio_name(c->kind), (int)st); c->conv = NULL; return false; }
    if (esds_n) AudioConverterSetProperty(c->conv, kAudioConverterDecompressionMagicCookie, (UInt32)esds_n, esds);
    c->channels = c->in_channels > 2 ? 2 : c->in_channels;
    if (c->in_channels > 2) downmix_gains(c);
    tl_log_line("media: %s decoder, %d Hz, %d channels%s", audio_name(c->kind), c->rate, c->in_channels, c->in_channels > 2 ? " (mixed down to stereo)" : "");
    return true;
}

static OSStatus audio_feed(AudioConverterRef conv, UInt32 *npk, AudioBufferList *bl, AudioStreamPacketDescription **desc, void *arg)
{
    (void)conv;
    codec *c = arg;
    if (!c->packet) { *npk = 0; return 1; }                         /* no more input for this call: AudioConverter returns what it has */
    bl->mNumberBuffers = 1;
    bl->mBuffers[0].mData = (void *)c->packet; bl->mBuffers[0].mDataByteSize = c->packet_len; bl->mBuffers[0].mNumberChannels = c->in.mChannelsPerFrame;
    c->desc = (AudioStreamPacketDescription){ 0, 0, c->packet_len };
    if (desc) *desc = &c->desc;
    *npk = 1; c->packet = NULL;
    return noErr;
}

static void audio_decode(codec *c, const uint8_t *d, size_t n, int64_t pts)
{
    if (!c->conv && !audio_open(c, NULL, 0, 0, 0)) return;
    if (!n) return;
    c->packet = d; c->packet_len = (UInt32)n;
    UInt32 frames = 6144, bytes = frames * c->out.mBytesPerFrame;    /* E-AC-3: up to 1536 frames a packet; MP3/AAC far fewer */
    uint8_t *buf = malloc(bytes);
    AudioBufferList bl = { 1, { { c->out.mChannelsPerFrame, bytes, buf } } };
    OSStatus st = AudioConverterFillComplexBuffer(c->conv, audio_feed, c, &frames, &bl, NULL);
    c->packet = NULL;
    if ((st != noErr && st != 1) || frames == 0) { free(buf); if (st != noErr && st != 1) { c->failed++; if (c->failed < 4) tl_log_line("media: audio packet not decoded (%d)", (int)st); } return; }
    if (c->in_channels > 2) {
        /* mixed down in place: each frame's stereo pair is written no further along than the frame it comes from */
        int n = c->in_channels;
        int16_t *s16 = (int16_t *)buf;
        for (UInt32 f = 0; f < frames; f++) {
            const int16_t *in = s16 + (size_t)f * n;
            float l = 0, r = 0;
            for (int ch = 0; ch < n; ch++) { l += in[ch] * c->gl[ch]; r += in[ch] * c->gr[ch]; }
            s16[2 * f] = (int16_t)(l > 32767 ? 32767 : l < -32768 ? -32768 : l);
            s16[2 * f + 1] = (int16_t)(r > 32767 ? 32767 : r < -32768 ? -32768 : r);
        }
    }
    int64_t duration_us = c->rate > 0
        ? ((int64_t)frames * 1000000LL + c->rate / 2) / c->rate : 0;
    int64_t expected_pts = c->audio_next_pts;
    int64_t delta_us = c->audio_pts_valid ? pts - expected_pts : 0;
    if (c->trace || c->audio_timing_log_count < 8 ||
            (c->audio_pts_valid && (delta_us > 50000 || delta_us < -50000))) {
        tl_log_line("media: %s PCM timing: input-pts=%lld us expected=%lld us delta=%lld us frames=%u rate=%d duration=%lld us packet=%zu bytes",
                    audio_name(c->kind), (long long)pts,
                    (long long)(c->audio_pts_valid ? expected_pts : pts),
                    (long long)delta_us, frames, c->rate,
                    (long long)duration_us, n);
    }
    c->audio_timing_log_count++;
    c->audio_next_pts = pts + duration_us;
    c->audio_pts_valid = true;

    pcm *p = calloc(1, sizeof(*p));
    if (!p) { free(buf); return; }
    p->data = buf; p->len = (int)(frames * 2 * (UInt32)c->channels); p->pts = pts;
    pthread_mutex_lock(&c->lock); *c->pcm_tail = p; c->pcm_tail = &p->next; c->decoded++; pthread_mutex_unlock(&c->lock);
}

/* ---- natives ---- */

static int kind_of(const char *mime)
{
    if (!mime) return 0;
    if (!strcasecmp(mime, "video/avc")) return K_AVC;
    if (!strcasecmp(mime, "video/hevc")) return K_HEVC;
    if (!strcasecmp(mime, "audio/mp4a-latm")) return K_AAC;
    if (!strcasecmp(mime, "audio/mpeg")) return K_MP3;
    if (!strcasecmp(mime, "audio/ac3")) return K_AC3;
    if (!strcasecmp(mime, "audio/eac3") || !strcasecmp(mime, "audio/eac3-joc")) return K_EAC3;    /* JOC: its E-AC-3 core */
    if (!strcasecmp(mime, "audio/mpeg-L2")) return K_MP2;
    if (!strcasecmp(mime, "audio/mpeg-L1")) return K_MP1;
    return 0;
}
#define C ((codec *)(uintptr_t)a[0].j)

NAT(M_supported)
{
    (void)self;
    int k = kind_of(tl_jni_string(a[0].l));
    bool ok = k == K_AVC || k == K_AAC || k == K_MP3 || (k >= K_AC3 && audio_available(k));
    if (k == K_HEVC) {
        if (__builtin_available(macOS 10.13, iOS 11.0, *)) ok = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC);
    }
    *ret = Z(ok);
    return true;
}
NAT(M_create)
{
    (void)self;
    int k = kind_of(tl_jni_string(a[0].l));
    if (!k) { *ret = J(0); return true; }
    codec *c = calloc(1, sizeof(*c));
    c->kind = k; c->trace = trace_on();
    c->waiting_for_random_access = (k == K_AVC || k == K_HEVC);
    for (int i = 0; i < 256; i++) c->pps_sps[i] = -1;
    pthread_mutex_init(&c->lock, NULL);
    pthread_cond_init(&c->frame_cond, NULL);
    c->ready_tail = &c->ready; c->pcm_tail = &c->pcms;
    *ret = J((int64_t)(uintptr_t)c);
    return true;
}
/* configure(h, width, height, rate, channels, csd0, csd1, csd2): codec-specific data as the format carries it */
NAT(M_configure)
{
    (void)self;
    codec *c = C;
    jobj *csd[3] = { a[5].l, a[6].l, a[7].l };
    if (c->kind == K_AVC || c->kind == K_HEVC) {
        c->width = a[1].i; c->height = a[2].i;
        for (int i = 0; i < 3; i++) if (csd[i] && csd[i]->arr.len) {
            nal_walk w = { .c = c };
            if (!parse_codec_config(c, csd[i]->arr.data, csd[i]->arr.len, take_nal, &w))
                tl_log_line("media: unrecognized %s codec config csd-%d (%u bytes)", c->kind == K_AVC ? "AVC" : "HEVC", i, csd[i]->arr.len);
            free(w.out);
        }
        if (c->params_changed) { c->params_changed = false; session_make(c); }
        *ret = Z(true);
    } else {
        *ret = Z(audio_open(c, csd[0] ? csd[0]->arr.data : NULL, csd[0] ? csd[0]->arr.len : 0, a[3].i, a[4].i));
    }
    return true;
}
/* decode(h, data, len, ptsUs, flags): one access unit or packet; csd (BUFFER_FLAG_CODEC_CONFIG) goes through here too */
NAT(M_decode)
{
    (void)self;
    codec *c = C;
    jobj *b = a[1].l;
    size_t n = b ? (size_t)a[2].i : 0;
    if (b && n > b->arr.len) n = b->arr.len;
    const uint8_t *d = b ? b->arr.data : NULL;
    if (c->kind == K_AVC || c->kind == K_HEVC) video_decode(c, d, n, a[3].j, a[4].i);
    else if (a[4].i & 2) audio_open(c, d, n, c->rate, c->in_channels ? c->in_channels : c->channels);   /* codec config: an AudioSpecificConfig */
    else audio_decode(c, d, n, a[3].j);
    *ret = I(0);
    return true;
}
/* waitForFrame(h, timeoutMs): wait briefly for VideoToolbox callbacks before MediaCodec asks ExoPlayer for more input. */
NAT(M_waitForFrame)
{
    (void)self;
    codec *c = C;
    int timeout = a[1].i;
    bool ready = false;
    if (timeout > 0) {
        struct timespec until;
        clock_gettime(CLOCK_REALTIME, &until);
        until.tv_sec += timeout / 1000;
        until.tv_nsec += (long)(timeout % 1000) * 1000000L;
        if (until.tv_nsec >= 1000000000L) { until.tv_sec++; until.tv_nsec -= 1000000000L; }
        pthread_mutex_lock(&c->lock);
        while (!c->ready && c->video_inflight > 0) {
            int rc = pthread_cond_timedwait(&c->frame_cond, &c->lock, &until);
            if (rc == ETIMEDOUT) break;
        }
        ready = c->ready != NULL || c->video_inflight == 0;
        pthread_mutex_unlock(&c->lock);
    } else {
        pthread_mutex_lock(&c->lock);
        ready = c->ready != NULL || c->video_inflight == 0;
        pthread_mutex_unlock(&c->lock);
    }
    *ret = Z(ready);
    return true;
}
/* Return the integer clean-aperture rectangle shared by nextFrame() and renderFrame().
   Bad/missing aperture metadata falls back to the full coded frame instead of
   producing mismatched Bitmap dimensions or an out-of-bounds pointer. */
static bool pixel_buffer_render_rect(CVPixelBufferRef pb, size_t *x0, size_t *y0, size_t *w, size_t *h)
{
    if (!pb || !x0 || !y0 || !w || !h) return false;
    size_t sw = CVPixelBufferGetWidth(pb), sh = CVPixelBufferGetHeight(pb);
    *x0 = *y0 = 0; *w = sw; *h = sh;
    if (!sw || !sh) return false;
    CGRect r = CVImageBufferGetCleanRect(pb);
    if (CGRectIsNull(r) || CGRectIsInfinite(r) || !isfinite(r.origin.x) || !isfinite(r.origin.y)
            || !isfinite(r.size.width) || !isfinite(r.size.height)
            || r.size.width <= 0 || r.size.height <= 0 || r.origin.x >= (double)sw || r.origin.y >= (double)sh)
        return false;
    double ox = r.origin.x < 0 ? 0 : r.origin.x;
    double oy = r.origin.y < 0 ? 0 : r.origin.y;
    size_t ix = (size_t)ox, iy = (size_t)oy;
    size_t iw = (size_t)r.size.width, ih = (size_t)r.size.height;
    if (iw > sw - ix) iw = sw - ix;
    if (ih > sh - iy) ih = sh - iy;
    if (!iw || !ih) return false;
    *x0 = ix; *y0 = iy; *w = iw; *h = ih;
    return true;
}

/* nextFrame(h, info) -> a frame handle (0: none yet); info = { ptsUs, width, height } */
NAT(M_nextFrame)
{
    (void)self;
    codec *c = C;
    pthread_mutex_lock(&c->lock);
    frame *f = c->ready;
    if (f) { c->ready = f->next; if (!c->ready) c->ready_tail = &c->ready; }
    pthread_mutex_unlock(&c->lock);
    if (!f) { *ret = J(0); return true; }
    int64_t *info = a[1].l ? (int64_t *)((jobj *)a[1].l)->arr.data : NULL;
    if (info) {
        size_t x0, y0, w, h;
        pixel_buffer_render_rect(f->pb, &x0, &y0, &w, &h);
        info[0] = f->pts; info[1] = (int64_t)w; info[2] = (int64_t)h;
    }
    *ret = J((int64_t)(uintptr_t)f);
    return true;
}
/* nextPcm(h, info) -> 16-bit PCM bytes (null: none yet); info = { ptsUs, rate, channels } */
NAT(M_nextPcm)
{
    (void)self;
    codec *c = C;
    pthread_mutex_lock(&c->lock);
    pcm *p = c->pcms;
    if (p) { c->pcms = p->next; if (!c->pcms) c->pcm_tail = &c->pcms; }
    pthread_mutex_unlock(&c->lock);
    if (!p) { *ret = L(NULL); return true; }
    int64_t *info = a[1].l ? (int64_t *)((jobj *)a[1].l)->arr.data : NULL;
    if (info) { info[0] = p->pts; info[1] = c->rate; info[2] = c->channels; }
    /* MediaCodec copies this array into its output buffer before asking for the next PCM packet. Reuse one array per
       decoder instead of allocating (and, in the current DVM, permanently retaining) a new Java byte[] for every AAC/AC-3 packet. */
    jobj *arr = c->pcm_array;
    if (!arr) {
        arr = tl_jni_new_prim_array('B', (uint32_t)p->len);
        if (!arr) { free(p->data); free(p); *ret = L(NULL); return true; }
        arr->refs = 1u << 30;
        c->pcm_array = arr;
        c->pcm_array_capacity = (uint32_t)p->len;
    } else if (c->pcm_array_capacity < (uint32_t)p->len) {
        uint8_t *data = realloc(arr->arr.data, (size_t)p->len);
        if (!data) { free(p->data); free(p); *ret = L(NULL); return true; }
        arr->arr.data = data;
        c->pcm_array_capacity = (uint32_t)p->len;
    }
    arr->arr.len = (uint32_t)p->len;
    memcpy(arr->arr.data, p->data, (size_t)p->len);
    free(p->data); free(p);
    *ret = L(arr);
    return true;
}
/* renderFrame(frame, bitmap): copy VideoToolbox output to the runtime's RGBA_8888 Bitmap. */
NAT(M_renderFrame)
{
    (void)self;
    static int render_calls, render_failures;
    frame *f = (frame *)(uintptr_t)a[0].j;
    void *px = NULL;
    tl_abitmap_info bi = {0};
    bool bitmap_locked = false, pixel_locked = false, ok = false;
    const char *stage = "validate frame/bitmap";
    CVReturn lock_status = kCVReturnError, unlock_status = kCVReturnSuccess;
    int bitmap_unlock_status = 0;
    OSType pixel_format = 0;
    size_t src_w = 0, src_h = 0, stride = 0, x0 = 0, y0 = 0, w = 0, h = 0;
    uint8_t *base = NULL;
    vImage_Error vstatus = kvImageNoError;

    int call_no = __atomic_add_fetch(&render_calls, 1, __ATOMIC_RELAXED);
    if (!f || !f->pb || !a[1].l) {
        goto done;
    }
    if (tl_AndroidBitmap_getInfo(NULL, a[1].l, &bi) != 0 || bi.format != 1 /* ANDROID_BITMAP_FORMAT_RGBA_8888 */
            || bi.width == 0 || bi.height == 0 || bi.stride < (size_t)bi.width * 4u) {
        goto done;
    }
    stage = "lock Android Bitmap pixels";
    if (tl_AndroidBitmap_lockPixels(NULL, a[1].l, &px) != 0 || !px) {
        goto done;
    }
    bitmap_locked = true;

    stage = "lock CVPixelBuffer base address";
    lock_status = CVPixelBufferLockBaseAddress(f->pb, kCVPixelBufferLock_ReadOnly);
    if (lock_status != kCVReturnSuccess) goto done;
    pixel_locked = true;
    stage = "inspect CVPixelBuffer layout";
    pixel_format = CVPixelBufferGetPixelFormatType(f->pb);
    src_w = CVPixelBufferGetWidth(f->pb);
    src_h = CVPixelBufferGetHeight(f->pb);
    stride = CVPixelBufferGetBytesPerRow(f->pb);
    base = CVPixelBufferGetBaseAddress(f->pb);

    /* VideoToolbox was configured for 32BGRA. Refuse to reinterpret another
       format as four-byte BGRA: planar 4:2:0 buffers can legitimately have a
       NULL base address and would otherwise produce a silent black frame. */
    if (pixel_format != kCVPixelFormatType_32BGRA || !base || src_w == 0 || src_h == 0
            || stride < src_w * 4u) goto done;

    stage = "validate clean aperture and dimensions";
    pixel_buffer_render_rect(f->pb, &x0, &y0, &w, &h);
    if (w != bi.width || h != bi.height || w == 0 || h == 0 || stride < (x0 + w) * 4u) goto done;

    stage = "convert BGRA pixels to Android RGBA Bitmap";
    vImage_Buffer src = { base + y0 * stride + x0 * 4u, h, w, stride };
    vImage_Buffer dst = { px, h, w, bi.stride };
    const uint8_t bgra_to_rgba[4] = { 2, 1, 0, 3 };
    vstatus = vImagePermuteChannels_ARGB8888(&src, &dst, bgra_to_rgba, kvImageNoFlags);
    ok = vstatus == kvImageNoError;

done:
    if (pixel_locked) unlock_status = CVPixelBufferUnlockBaseAddress(f->pb, kCVPixelBufferLock_ReadOnly);
    if (bitmap_locked) bitmap_unlock_status = tl_AndroidBitmap_unlockPixels(NULL, a[1].l);
    if (unlock_status != kCVReturnSuccess || bitmap_unlock_status != 0) ok = false;
    if (!ok) {
        int fail_no = __atomic_add_fetch(&render_failures, 1, __ATOMIC_RELAXED);
        if (fail_no <= 12 || trace_on()) {
            char fourcc[5] = { (char)(pixel_format >> 24), (char)(pixel_format >> 16),
                               (char)(pixel_format >> 8), (char)pixel_format, 0 };
            for (int i = 0; i < 4; i++) if (fourcc[i] < 32 || fourcc[i] > 126) fourcc[i] = '.';
            tl_log_line("media: renderFrame failed #%d call=%d stage=%s cvLock=%d cvUnlock=%d bitmapUnlock=%d bitmap=%ux%u stride=%u bitmap-format=%d pixel-format=%s/0x%08x source=%zux%zu stride=%zu planes=%zu base=%s vImage=%ld",
                        fail_no, call_no, stage, (int)lock_status, (int)unlock_status, bitmap_unlock_status,
                        bi.width, bi.height, bi.stride, bi.format, fourcc, (unsigned)pixel_format, src_w, src_h, stride,
                        f && f->pb ? CVPixelBufferGetPlaneCount(f->pb) : 0,
                        base ? "yes" : "null", (long)vstatus);
        }
    } else if (call_no <= 3 || trace_on()) {
        tl_log_line("media: renderFrame ok #%d pts=%lld size=%zux%zu pixel-format=BGRA",
                    call_no, (long long)f->pts, w, h);
    }
    *ret = Z(ok);
    return true;
}
NAT(M_freeFrame) { (void)self; (void)ret; frame *f = (frame *)(uintptr_t)a[0].j; if (f) { CVPixelBufferRelease(f->pb); free(f); } return true; }
static void drop_outputs(codec *c)
{
    pthread_mutex_lock(&c->lock);
    for (frame *f = c->sorted, *n; f; f = n) { n = f->next; CVPixelBufferRelease(f->pb); free(f); }
    for (frame *f = c->ready, *n; f; f = n) { n = f->next; CVPixelBufferRelease(f->pb); free(f); }
    c->sorted = NULL; c->nsorted = 0; c->ready = NULL; c->ready_tail = &c->ready;
    for (pcm *p = c->pcms, *n; p; p = n) { n = p->next; free(p->data); free(p); }
    c->pcms = NULL; c->pcm_tail = &c->pcms;
    pthread_mutex_unlock(&c->lock);
}
NAT(M_flush)
{
    (void)self; (void)ret;
    codec *c = C;
    if (c->vt) { VTDecompressionSessionFinishDelayedFrames(c->vt); VTDecompressionSessionWaitForAsynchronousFrames(c->vt); }
    if (c->conv) AudioConverterReset(c->conv);
    c->audio_pts_valid = false;
    c->audio_timing_log_count = 0;
    drop_outputs(c);
    return true;
}
NAT(M_destroy)
{
    (void)self; (void)ret;
    codec *c = C;
    if (!c) return true;
    session_drop(c);
    drop_outputs(c);
    if (c->fmt) CFRelease(c->fmt);
    if (c->conv) AudioConverterDispose(c->conv);
    for (int i = 0; i < 16; i++) free(c->vps[i].d);
    for (int i = 0; i < 32; i++) free(c->sps[i].d);
    for (int i = 0; i < 256; i++) free(c->pps[i].d);
    if (c->trace) tl_log_line("media: codec closed after %ld outputs, %ld failures", c->decoded, c->failed);
    pthread_cond_destroy(&c->frame_cond);
    pthread_mutex_destroy(&c->lock);
    free(c);
    return true;
}
NAT(M_size) { (void)self; codec *c = C; *ret = I(c->width << 16 | (c->height & 0xffff)); return true; }

static const struct { const char *name, *sig; dvm_native_fn fn; } k_media[] = {
    { "supported", "(Ljava/lang/String;)Z", M_supported },
    { "create", "(Ljava/lang/String;)J", M_create },
    { "configure", "(JIIII[B[B[B)Z", M_configure },
    { "decode", "(J[BIJI)I", M_decode },
    { "waitForFrame", "(JI)Z", M_waitForFrame },
    { "nextFrame", "(J[J)J", M_nextFrame },
    { "nextPcm", "(J[J)[B", M_nextPcm },
    { "renderFrame", "(JLandroid/graphics/Bitmap;)Z", M_renderFrame },
    { "freeFrame", "(J)V", M_freeFrame },
    { "flush", "(J)V", M_flush },
    { "destroy", "(J)V", M_destroy },
    { "size", "(J)I", M_size },
    { NULL, NULL, NULL },
};
dvm_native_fn tl_media_native(const char *name, const char *sig);
dvm_native_fn tl_media_native(const char *name, const char *sig)
{
    for (int i = 0; k_media[i].name; i++) if (!strcmp(k_media[i].name, name) && !strcmp(k_media[i].sig, sig)) return k_media[i].fn;
    return NULL;
}
