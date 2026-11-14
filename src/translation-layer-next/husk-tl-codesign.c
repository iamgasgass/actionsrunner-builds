/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * husk-tl-codesign.c: On-device Mach-O codesigner for Husk (iOS 15.5+ / macOS).
 *
 * Implements code signing in pure C using only Apple's Security.framework,
 * CommonCrypto, and CoreFoundation. Does NOT depend on OpenSSL, command-line
 * tools, or any AGPL code.
 *
 * Background & Apple Code Signing Architecture:
 * ---------------------------------------------
 * On modern iOS (iOS 15 through iOS 26+), dlopen() enforces Apple's Library
 * Validation (LV). For an in-process translation layer to dynamically load
 * Ahead-Of-Time (AOT) compiled arm64 dylibs without JIT entitlement or
 * debugger bypasses, the dylibs MUST be signed on-device with the same Apple
 * Developer certificate and Team ID that signed the host app (or signed
 * with an ad-hoc signature if library validation is relaxed, e.g. on macOS).
 *
 * Apple Mach-O Code Signature Structure:
 * 1. LC_CODE_SIGNATURE load command:
 *    Points to a file offset (dataoff) and byte count (datasize) within the
 *    __LINKEDIT segment.
 *
 * 2. Embedded Signature SuperBlob (magic 0xfade0cc0):
 *    A container holding multiple indexed blobs:
 *    - Slot 0 (CSSLOT_CODEDIRECTORY, magic 0xfade0c02):
 *        CodeDirectory version 0x20400 (supporting execSegBase/Limit/Flags).
 *        Contains SHA-256 hashes of every 16 KiB (2^14 bytes) page of the
 *        file up to the start of the signature (codeLimit).
 *        Preceding the code slot hashes are negative index slots:
 *          Slot -1: Info.plist SHA-256 (all zeroes for dylibs without plist).
 *          Slot -2: Requirements blob SHA-256.
 *        Also embeds the dylib identifier string and the Developer Team ID.
 *    - Slot 1 (CSSLOT_REQUIREMENTS, magic 0xfade0c01):
 *        Designated requirement vector enforcing identifier matching.
 *    - Slot 2 (CSSLOT_SIGNATURESLOT, magic 0xfade0b01):
 *        BlobWrapper containing a CMS (PKCS#7) SignedData DER structure.
 *        Signs the SHA-256 digest of the CodeDirectory (CDHash) using the
 *        developer's RSA or ECDSA private key.
 *        Contains Apple-specific signed attributes (1.2.840.113635.100.9.1
 *        and 1.2.840.113635.100.9.2) embedding the CDHashes.
 *
 * Uncertainties & Known Limits:
 * - Developer certificate chains must be valid X.509 DER. If intermediate CA
 *   certificates are included in the .p12 (kSecImportItemCertChain), they are
 *   automatically embedded into the CMS certificates set so iOS trust
 *   evaluation can verify back to Apple Worldwide Developer Relations CA.
 * - This implementation targets arm64 64-bit Mach-O dylibs (Mach-O magic
 *   MH_MAGIC_64), which covers all iOS 15+ devices and Apple Silicon Macs.
 */

#include "husk-tl-codesign.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <unistd.h>
#include <time.h>
#include <sys/stat.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <TargetConditionals.h>

#include <mach-o/loader.h>
#include <mach-o/fat.h>
#include <CommonCrypto/CommonDigest.h>
#include <CommonCrypto/CommonHMAC.h>
#include <Security/Security.h>
#include <CoreFoundation/CoreFoundation.h>

/* ------------------------------------------------------------------ Constants */

#define CSMAGIC_REQUIREMENT         0xfade0c00
#define CSMAGIC_REQUIREMENTS        0xfade0c01
#define CSMAGIC_CODEDIRECTORY       0xfade0c02
#define CSMAGIC_EMBEDDED_SIGNATURE  0xfade0cc0
#define CSMAGIC_BLOBWRAPPER         0xfade0b01

#define CSSLOT_CODEDIRECTORY        0
#define CSSLOT_REQUIREMENTS         2
#define CSSLOT_SIGNATURESLOT        0x10000

#define CS_HASHTYPE_SHA256          2
#define CS_SHA256_LEN               32
/* 4 KiB, as Apple's codesign, ldid (SideStore, AltStore) and zsign (LiveContainer) write it for code signed with a certificate.
 * 16 KiB pages are what ld64's ad-hoc (linker) signatures use; with a developer certificate on an iPhone with TXM (iOS 27,
 * iPhone 14 Pro) Husk's 16 KiB signatures were refused ("code signature invalid", errno 1) with everything else in order. */
#define CS_PAGE_SIZE_LOG2           12
#define CS_PAGE_SIZE                (1 << CS_PAGE_SIZE_LOG2)

#define CS_ADHOC                    0x2
#define CS_SUPPORTSEXECSEG          0x20400

/* ------------------------------------------------------------------ Dynamic Buffer */

typedef struct {
    uint8_t *b;
    size_t n, cap;
} cs_buf;

static void buf_init(cs_buf *b) {
    b->b = NULL;
    b->n = 0;
    b->cap = 0;
}

static void buf_free(cs_buf *b) {
    free(b->b);
    b->b = NULL;
    b->n = 0;
    b->cap = 0;
}

static bool buf_reserve(cs_buf *b, size_t extra) {
    if (b->n + extra > b->cap) {
        size_t ncap = b->cap ? b->cap * 2 : 512;
        while (ncap < b->n + extra) ncap *= 2;
        uint8_t *p = (uint8_t *)realloc(b->b, ncap);
        if (!p) return false;
        b->b = p;
        b->cap = ncap;
    }
    return true;
}

static void buf_put(cs_buf *b, const void *p, size_t len) {
    if (len == 0) return;
    if (buf_reserve(b, len)) {
        memcpy(b->b + b->n, p, len);
        b->n += len;
    }
}

static void buf_put_byte(cs_buf *b, uint8_t byte) {
    buf_put(b, &byte, 1);
}

static void buf_put_u32_be(cs_buf *b, uint32_t val) {
    uint8_t d[4] = {
        (uint8_t)(val >> 24),
        (uint8_t)(val >> 16),
        (uint8_t)(val >> 8),
        (uint8_t)val
    };
    buf_put(b, d, 4);
}

static void buf_put_u64_be(cs_buf *b, uint64_t val) {
    buf_put_u32_be(b, (uint32_t)(val >> 32));
    buf_put_u32_be(b, (uint32_t)val);
}

static void buf_set_u32_be(cs_buf *b, size_t pos, uint32_t val) {
    if (pos + 4 <= b->n) {
        b->b[pos]     = (uint8_t)(val >> 24);
        b->b[pos + 1] = (uint8_t)(val >> 16);
        b->b[pos + 2] = (uint8_t)(val >> 8);
        b->b[pos + 3] = (uint8_t)val;
    }
}

/* ------------------------------------------------------------------ ASN.1 DER Helpers */

/* Writes an ASN.1 definite length octet sequence */
static void der_put_length(cs_buf *b, size_t len) {
    if (len < 128) {
        buf_put_byte(b, (uint8_t)len);
    } else if (len < 256) {
        buf_put_byte(b, 0x81);
        buf_put_byte(b, (uint8_t)len);
    } else if (len < 65536) {
        buf_put_byte(b, 0x82);
        buf_put_byte(b, (uint8_t)(len >> 8));
        buf_put_byte(b, (uint8_t)len);
    } else {
        buf_put_byte(b, 0x83);
        buf_put_byte(b, (uint8_t)(len >> 16));
        buf_put_byte(b, (uint8_t)(len >> 8));
        buf_put_byte(b, (uint8_t)len);
    }
}

/* Writes Tag-Length-Value */
static void der_put_tlv(cs_buf *b, uint8_t tag, const uint8_t *val, size_t len) {
    buf_put_byte(b, tag);
    der_put_length(b, len);
    if (len) buf_put(b, val, len);
}

/* Wraps the buffer segment starting at content_start with an ASN.1 constructed tag */
static void der_wrap(cs_buf *b, uint8_t tag, size_t content_start) {
    size_t content_len = b->n - content_start;
    cs_buf tmp;
    buf_init(&tmp);
    buf_put_byte(&tmp, tag);
    der_put_length(&tmp, content_len);
    size_t header_len = tmp.n;
    if (buf_reserve(b, header_len)) {
        memmove(b->b + content_start + header_len, b->b + content_start, content_len);
        memcpy(b->b + content_start, tmp.b, header_len);
        b->n += header_len;
    }
    buf_free(&tmp);
}

/* Parses Tag-Length-Value header from raw buffer */
static bool parse_tlv(const uint8_t *p, size_t len, size_t *pos, uint8_t *tag, size_t *header_len, size_t *v_len) {
    if (*pos >= len) return false;
    *tag = p[*pos];
    if (*pos + 1 >= len) return false;
    uint8_t l1 = p[*pos + 1];
    if (!(l1 & 0x80)) {
        *header_len = 2;
        *v_len = l1;
    } else {
        size_t n = l1 & 0x7f;
        if (n == 0 || n > 4 || *pos + 2 + n > len) return false;
        size_t vl = 0;
        for (size_t i = 0; i < n; i++) vl = (vl << 8) | p[*pos + 2 + i];
        *header_len = 2 + n;
        *v_len = vl;
    }
    if (*pos + *header_len + *v_len > len) return false;
    return true;
}

/* ------------------------------------------------------------------ X.509 Certificate Parser */

typedef struct {
    const uint8_t *serial_ptr;
    size_t serial_len;
    const uint8_t *issuer_ptr;
    size_t issuer_len;
    const uint8_t *subject_ptr;
    size_t subject_len;
    char team_id[64];
    char common_name[256];
    int64_t not_after_epoch;
    bool is_rsa;
} cert_meta;

void tl_log_line(const char *fmt, ...);

/* Walk an X.509 Name (SEQUENCE of SET of SEQUENCE { OID, value }) for CN and a 10-character Team ID OU. */
static void name_fill_cn_ou(const uint8_t *der, size_t name_pos, size_t name_end, cert_meta *out)
{
    size_t pos = name_pos;
    uint8_t tag = 0;
    size_t hlen = 0, vlen = 0;
    if (!parse_tlv(der, name_end, &pos, &tag, &hlen, &vlen) || tag != 0x30) return;
    size_t end = pos + hlen + vlen;
    pos += hlen;
    while (pos < end) {
        size_t set_at = pos;
        if (!parse_tlv(der, end, &set_at, &tag, &hlen, &vlen) || tag != 0x31) break;
        size_t set_end = set_at + hlen + vlen;
        size_t at = set_at + hlen;
        while (at < set_end) {
            size_t seq_at = at;
            if (!parse_tlv(der, set_end, &seq_at, &tag, &hlen, &vlen) || tag != 0x30) break;
            size_t seq_end = seq_at + hlen + vlen;
            size_t oid_at = seq_at + hlen;
            uint8_t ot = 0;
            size_t oh = 0, ov = 0;
            if (!parse_tlv(der, seq_end, &oid_at, &ot, &oh, &ov) || ot != 0x06) {
                at = seq_end;
                continue;
            }
            const uint8_t *oid = der + oid_at + oh;
            size_t val_at = oid_at + oh + ov;
            uint8_t vt = 0;
            size_t vh = 0, vv = 0;
            if (!parse_tlv(der, seq_end, &val_at, &vt, &vh, &vv)) {
                at = seq_end;
                continue;
            }
            const uint8_t *val = der + val_at + vh;
            if (ov == 3 && oid[0] == 0x55 && oid[1] == 0x04 && oid[2] == 0x03 && !out->common_name[0] && vv > 0) {
                size_t n = vv < sizeof(out->common_name) - 1 ? vv : sizeof(out->common_name) - 1;
                memcpy(out->common_name, val, n);
                out->common_name[n] = '\0';
            }
            if (ov == 3 && oid[0] == 0x55 && oid[1] == 0x04 && oid[2] == 0x0b && vv == 10 && !out->team_id[0]) {
                memcpy(out->team_id, val, 10);
                out->team_id[10] = '\0';
            }
            at = seq_end;
        }
        pos = set_end;
    }
}

static bool parse_cert_der(const uint8_t *cert_der, size_t cert_len, cert_meta *out) {
    memset(out, 0, sizeof(*out));
    out->is_rsa = true;

    size_t pos = 0, hlen = 0, vlen = 0;
    uint8_t tag = 0;

    /* Outer Certificate SEQUENCE */
    if (!parse_tlv(cert_der, cert_len, &pos, &tag, &hlen, &vlen) || tag != 0x30) return false;
    pos += hlen;

    /* TBSCertificate SEQUENCE */
    if (!parse_tlv(cert_der, cert_len, &pos, &tag, &hlen, &vlen) || tag != 0x30) return false;
    size_t tbs_end = pos + hlen + vlen;
    pos += hlen;

    /* Optional Version [0] EXPLICIT */
    if (parse_tlv(cert_der, tbs_end, &pos, &tag, &hlen, &vlen) && tag == 0xa0) {
        pos += hlen + vlen;
    }

    /* Serial Number INTEGER */
    if (!parse_tlv(cert_der, tbs_end, &pos, &tag, &hlen, &vlen) || tag != 0x02) return false;
    out->serial_ptr = cert_der + pos;
    out->serial_len = hlen + vlen;
    pos += hlen + vlen;

    /* Signature Algorithm SEQUENCE */
    if (!parse_tlv(cert_der, tbs_end, &pos, &tag, &hlen, &vlen) || tag != 0x30) return false;
    pos += hlen + vlen;

    /* Issuer Name SEQUENCE */
    if (!parse_tlv(cert_der, tbs_end, &pos, &tag, &hlen, &vlen) || tag != 0x30) return false;
    out->issuer_ptr = cert_der + pos;
    out->issuer_len = hlen + vlen;
    pos += hlen + vlen;

    /* Validity SEQUENCE */
    if (!parse_tlv(cert_der, tbs_end, &pos, &tag, &hlen, &vlen) || tag != 0x30) return false;
    size_t val_end = pos + hlen + vlen;
    pos += hlen;
    /* notBefore (skip) */
    if (!parse_tlv(cert_der, val_end, &pos, &tag, &hlen, &vlen)) return false;
    pos += hlen + vlen;
    /* notAfter */
    if (!parse_tlv(cert_der, val_end, &pos, &tag, &hlen, &vlen)) return false;
    if (vlen >= 13) {
        const char *t_str = (const char *)(cert_der + pos + hlen);
        struct tm tm_val;
        memset(&tm_val, 0, sizeof(tm_val));
        if (tag == 0x17) { /* UTCTime YYMMDDHHMMSSZ */
            int yy = (t_str[0] - '0') * 10 + (t_str[1] - '0');
            tm_val.tm_year = (yy < 50 ? 2000 + yy : 1900 + yy) - 1900;
            tm_val.tm_mon  = (t_str[2] - '0') * 10 + (t_str[3] - '0') - 1;
            tm_val.tm_mday = (t_str[4] - '0') * 10 + (t_str[5] - '0');
            tm_val.tm_hour = (t_str[6] - '0') * 10 + (t_str[7] - '0');
            tm_val.tm_min  = (t_str[8] - '0') * 10 + (t_str[9] - '0');
            tm_val.tm_sec  = (t_str[10] - '0') * 10 + (t_str[11] - '0');
            out->not_after_epoch = timegm(&tm_val);
        } else if (tag == 0x18 && vlen >= 15) { /* GeneralizedTime YYYYMMDDHHMMSSZ */
            int yyyy = (t_str[0] - '0') * 1000 + (t_str[1] - '0') * 100 + (t_str[2] - '0') * 10 + (t_str[3] - '0');
            tm_val.tm_year = yyyy - 1900;
            tm_val.tm_mon  = (t_str[4] - '0') * 10 + (t_str[5] - '0') - 1;
            tm_val.tm_mday = (t_str[6] - '0') * 10 + (t_str[7] - '0');
            tm_val.tm_hour = (t_str[8] - '0') * 10 + (t_str[9] - '0');
            tm_val.tm_min  = (t_str[10] - '0') * 10 + (t_str[11] - '0');
            tm_val.tm_sec  = (t_str[12] - '0') * 10 + (t_str[13] - '0');
            out->not_after_epoch = timegm(&tm_val);
        }
    }
    pos = val_end;

    /* Subject Name SEQUENCE */
    if (!parse_tlv(cert_der, tbs_end, &pos, &tag, &hlen, &vlen) || tag != 0x30) return false;
    out->subject_ptr = cert_der + pos;
    out->subject_len = hlen + vlen;
    size_t subj_end = pos + hlen + vlen;
    name_fill_cn_ou(cert_der, pos, subj_end, out);
    pos = subj_end;

    /* SubjectPublicKeyInfo SEQUENCE */
    if (parse_tlv(cert_der, tbs_end, &pos, &tag, &hlen, &vlen) && tag == 0x30) {
        size_t spki_pos = pos + hlen;
        uint8_t alg_tag = 0; size_t alg_hlen = 0, alg_vlen = 0;
        if (parse_tlv(cert_der, tbs_end, &spki_pos, &alg_tag, &alg_hlen, &alg_vlen) && alg_tag == 0x30) {
            /* Check for id-ecPublicKey (1.2.840.10045.2.1: 06 07 2a 86 48 ce 3d 02 01) */
            static const uint8_t ec_oid[] = { 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01 };
            if (alg_vlen >= sizeof(ec_oid) &&
                memcmp(cert_der + spki_pos + alg_hlen, ec_oid, sizeof(ec_oid)) == 0) {
                out->is_rsa = false;
            }
        }
    }

    return true;
}

/* ------------------------------------------------------------------ Base64 Encoder */

static char *b64_encode(const uint8_t *data, size_t len) {
    static const char tbl[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t out_len = 4 * ((len + 2) / 3);
    char *out = (char *)malloc(out_len + 1);
    if (!out) return NULL;
    size_t i = 0, j = 0;
    while (i < len) {
        size_t rem = len - i;
        uint32_t a = data[i++];
        uint32_t b = (rem > 1) ? data[i++] : 0;
        uint32_t c = (rem > 2) ? data[i++] : 0;
        uint32_t triple = (a << 16) | (b << 8) | c;
        out[j++] = tbl[(triple >> 18) & 0x3F];
        out[j++] = tbl[(triple >> 12) & 0x3F];
        out[j++] = (rem > 1) ? tbl[(triple >> 6) & 0x3F] : '=';
        out[j++] = (rem > 2) ? tbl[triple & 0x3F] : '=';
    }
    out[j] = '\0';
    return out;
}

/* ------------------------------------------------------------------ CMS SignedData Generator */

static const uint8_t sha256_alg_null[] = {
    0x30, 0x0d,
      0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01,
      0x05, 0x00
};

/*
 * Issuer certificates to carry beside the developer certificate, for when the .p12 has none (a store's export holds only the
 * developer certificate and its key): set by husk_codesign_chain_from_executable from the certificates in the app's own signature,
 * which the store signed with this same certificate and its full chain.
 */
#define CHAIN_MAX 8
static struct { uint8_t *der; size_t len; } g_chain[CHAIN_MAX];
static int g_nchain;

static bool chain_has(const uint8_t *der, size_t len)
{
    for (int i = 0; i < g_nchain; i++) if (g_chain[i].len == len && !memcmp(g_chain[i].der, der, len)) return true;
    return false;
}

static bool cert_is_root(const uint8_t *der, size_t len)
{
    cert_meta m;
    if (!parse_cert_der(der, len, &m) || !m.issuer_ptr || !m.subject_ptr) return true;
    return m.issuer_len == m.subject_len && memcmp(m.issuer_ptr, m.subject_ptr, m.issuer_len) == 0;
}

/* Intermediates only: a self-signed root in the CMS bag makes iOS AMFI report
 * "code signature invalid" even when macOS codesign --verify accepts the same blob. */
static bool chain_add(const uint8_t *der, size_t len)
{
    if (!der || len < 64 || len > 8192 || der[0] != 0x30) return false;
    if (chain_has(der, len) || g_nchain >= CHAIN_MAX) return false;
    if (cert_is_root(der, len)) return false;
    uint8_t *copy = (uint8_t *)malloc(len);
    if (!copy) return false;
    memcpy(copy, der, len);
    g_chain[g_nchain].der = copy;
    g_chain[g_nchain].len = len;
    g_nchain++;
    return true;
}

/* SideStore/AltStore .p12 files hold only the leaf. Always embed Apple's public WWDR G3
 * so iOS can build a trust path (CSSMERR_TP_NOT_TRUSTED / errno=1 otherwise). */
#include "husk-tl-codesign-wwdr.inc"
static void ensure_wwdr_in_chain(void)
{
    chain_add(k_apple_wwdr_g3, sizeof(k_apple_wwdr_g3));
}

static void describe_signature(const uint8_t *sig, size_t len, const char *whose);

/* Whether the key signs for the certificate (checked on the first signature with an identity; reset when another opens). */
static bool g_sig_checked, g_sig_matches;

/* Every certificate of the app's own signature, in its order (root included) */
static struct { uint8_t *der; size_t len; } g_bag[8];
static int g_nbag;

/* The developer certificate in the app's own signature (husk_codesign_chain_from_executable), to tell the .p12's apart from it */
static uint8_t *g_app_leaf;
static size_t g_app_leaf_len;
static int g_app_leaf_logged;

/* md: SHA-256 of the slot-0 CodeDirectory (the CMS content); cdhash1, cdhash2: the SHA-1 and SHA-256 CDHashes */
static bool build_cms_signed_data(const uint8_t *md, const uint8_t *cdhash1, const uint8_t *cdhash2,
                                  const uint8_t *leaf_cert_der, size_t leaf_cert_len,
                                  const cert_meta *meta,
                                  CFArrayRef extra_certs,
                                  SecKeyRef privKey,
                                  cs_buf *out_cms)
{
    cs_buf attrs;
    buf_init(&attrs);

    /* 1. contentType (OID 1.2.840.113549.1.9.3 -> 1.2.840.113549.1.7.1 pkcs7-data) */
    static const uint8_t a0[] = {
        0x30, 0x18,
          0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x03,
          0x31, 0x0b,
            0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x01
    };
    buf_put(&attrs, a0, sizeof(a0));

    /* 2. signingTime (OID 1.2.840.113549.1.9.5 -> UTCTime YYMMDDhhmmssZ) */
    time_t now = time(NULL);
    struct tm tm_now;
    gmtime_r(&now, &tm_now);
    char time_str[16];
    snprintf(time_str, sizeof(time_str), "%02d%02d%02d%02d%02d%02dZ",
             tm_now.tm_year % 100, tm_now.tm_mon + 1, tm_now.tm_mday,
             tm_now.tm_hour, tm_now.tm_min, tm_now.tm_sec);
    buf_put_byte(&attrs, 0x30);
    der_put_length(&attrs, 28);
    static const uint8_t oid_st[] = { 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x05 };
    buf_put(&attrs, oid_st, sizeof(oid_st));
    buf_put_byte(&attrs, 0x31);
    der_put_length(&attrs, 15);
    der_put_tlv(&attrs, 0x17, (const uint8_t *)time_str, 13);

    /* 3. messageDigest (OID 1.2.840.113549.1.9.4 -> OCTET STRING CDHash 32 bytes) */
    buf_put_byte(&attrs, 0x30);
    der_put_length(&attrs, 47);
    static const uint8_t oid_md[] = { 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x04 };
    buf_put(&attrs, oid_md, sizeof(oid_md));
    buf_put_byte(&attrs, 0x31);
    der_put_length(&attrs, 34);
    der_put_tlv(&attrs, 0x04, md, 32);

    /* 4. Apple CDHash (OID 1.2.840.113635.100.9.2 -> SEQUENCE of { sha256, hash }) */
    static const uint8_t a3_hdr[] = {
        0x30, 0x3c,
          0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x09, 0x02,
          0x31, 0x2f,
            0x30, 0x2d,
              0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01,
              0x04, 0x20
    };
    buf_put(&attrs, a3_hdr, sizeof(a3_hdr));
    buf_put(&attrs, cdhash2, 32);      /* the SHA-256 CodeDirectory's, the one iOS picks */

    /* 5. Apple CDHashes plist (OID 1.2.840.113635.100.9.1 -> base64 20-byte truncated CDHash) */
    /* both CodeDirectories, in slot order, each CDHash cut to 20 bytes */
    char *b64 = b64_encode(cdhash1, 20), *b64b = b64_encode(cdhash2, 20);
    char plist[512];
    int plen = snprintf(plist, sizeof(plist),
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
        "<plist version=\"1.0\">\n"
        "<dict>\n"
        "\t<key>cdhashes</key>\n"
        "\t<array>\n"
        "\t\t<data>\n"
        "\t\t%s\n"
        "\t\t</data>\n"
        "\t\t<data>\n"
        "\t\t%s\n"
        "\t\t</data>\n"
        "\t</array>\n"
        "</dict>\n"
        "</plist>\n", b64 ? b64 : "", b64b ? b64b : "");
    free(b64);
    free(b64b);

    cs_buf a4_inner;
    buf_init(&a4_inner);
    der_put_tlv(&a4_inner, 0x04, (const uint8_t *)plist, (size_t)plen);
    der_wrap(&a4_inner, 0x31, 0); /* SET */
    static const uint8_t oid_apple_cdhashes[] = { 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x09, 0x01 };
    cs_buf a4;
    buf_init(&a4);
    buf_put(&a4, oid_apple_cdhashes, sizeof(oid_apple_cdhashes));
    buf_put(&a4, a4_inner.b, a4_inner.n);
    der_wrap(&a4, 0x30, 0); /* SEQUENCE */
    buf_put(&attrs, a4.b, a4.n);
    buf_free(&a4_inner);
    buf_free(&a4);

    /* RFC 5652: Compute digest over EXPLICIT SET OF tag (0x31) + length + attribute contents */
    cs_buf to_hash;
    buf_init(&to_hash);
    buf_put_byte(&to_hash, 0x31);
    der_put_length(&to_hash, attrs.n);
    buf_put(&to_hash, attrs.b, attrs.n);

    uint8_t attrs_digest[32];
    CC_SHA256(to_hash.b, (CC_LONG)to_hash.n, attrs_digest);
    buf_free(&to_hash);

    /* Sign attrs_digest with SecKeyCreateSignature */
    CFDataRef digestData = CFDataCreate(kCFAllocatorDefault, attrs_digest, sizeof(attrs_digest));
    CFErrorRef error = NULL;
    CFStringRef alg = meta->is_rsa ? kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA256
                                   : kSecKeyAlgorithmECDSASignatureDigestX962SHA256;
    CFDataRef sig = SecKeyCreateSignature(privKey, alg, digestData, &error);
    CFRelease(digestData);
    if (!sig) {
        if (error) CFRelease(error);
        buf_free(&attrs);
        return false;
    }

    /* Checked against the developer certificate's public key: a .p12 whose key is not the certificate's makes signatures iOS
     * refuses with nothing better than "code signature invalid", so say it here. */
    if (!g_sig_checked) {
        g_sig_checked = true;
        CFDataRef leaf = CFDataCreate(kCFAllocatorDefault, leaf_cert_der, (CFIndex)leaf_cert_len);
        SecCertificateRef lc = leaf ? SecCertificateCreateWithData(kCFAllocatorDefault, leaf) : NULL;
        SecKeyRef pub = lc ? SecCertificateCopyKey(lc) : NULL;
        CFDataRef dd = CFDataCreate(kCFAllocatorDefault, attrs_digest, sizeof(attrs_digest));
        CFErrorRef verr = NULL;
        g_sig_matches = pub && dd && SecKeyVerifySignature(pub, alg, dd, sig, &verr);
        if (verr) CFRelease(verr);
        if (dd) CFRelease(dd);
        if (pub) CFRelease(pub);
        if (lc) CFRelease(lc);
        if (leaf) CFRelease(leaf);
        tl_log_line(g_sig_matches ? "sign: the .p12's key signs for its certificate"
                                  : "sign: the .p12's private key does not belong to its certificate: iOS will refuse every signature");
    }
    if (!g_sig_matches) {
        CFRelease(sig);
        buf_free(&attrs);
        return false;
    }

    const uint8_t *sig_bytes = CFDataGetBytePtr(sig);
    size_t sig_len = CFDataGetLength(sig);

    /* Build SignerInfo */
    cs_buf sinfo;
    buf_init(&sinfo);

    /* version = 1 */
    static const uint8_t ver1[] = { 0x02, 0x01, 0x01 };
    buf_put(&sinfo, ver1, sizeof(ver1));

    /* sid: IssuerAndSerialNumber (SEQUENCE { issuer, serialNumber }) */
    size_t sid_start = sinfo.n;
    buf_put(&sinfo, meta->issuer_ptr, meta->issuer_len);
    buf_put(&sinfo, meta->serial_ptr, meta->serial_len);
    der_wrap(&sinfo, 0x30, sid_start);

    /* digestAlgorithm: sha256 */
    buf_put(&sinfo, sha256_alg_null, sizeof(sha256_alg_null));

    /* [0] IMPLICIT signedAttrs */
    buf_put_byte(&sinfo, 0xa0);
    der_put_length(&sinfo, attrs.n);
    buf_put(&sinfo, attrs.b, attrs.n);
    buf_free(&attrs);

    /* signatureAlgorithm: rsaEncryption (1.2.840.113549.1.1.1), the one Apple's codesign, ldid and zsign write -- the digest
     * algorithm above already says SHA-256; iOS's CoreTrust is far narrower than OpenSSL in what it takes here, and Husk's
     * signatures with sha256WithRSAEncryption (1.1.11) were refused ("code signature invalid", errno 1) -- or ecdsa-with-SHA256 */
    if (meta->is_rsa) {
        static const uint8_t rsa_alg_null[] = {
            0x30, 0x0d,
              0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01,
              0x05, 0x00
        };
        buf_put(&sinfo, rsa_alg_null, sizeof(rsa_alg_null));
    } else {
        static const uint8_t ec_alg[] = {
            0x30, 0x0a,
              0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02
        };
        buf_put(&sinfo, ec_alg, sizeof(ec_alg));
    }

    /* signature: OCTET STRING */
    der_put_tlv(&sinfo, 0x04, sig_bytes, sig_len);
    CFRelease(sig);
    der_wrap(&sinfo, 0x30, 0); /* SignerInfo SEQUENCE */
    der_wrap(&sinfo, 0x31, 0); /* signerInfos SET OF */

    /* Build SignedData */
    cs_buf sdata;
    buf_init(&sdata);
    buf_put(&sdata, ver1, sizeof(ver1));

    /* digestAlgorithms SET OF { sha256 } */
    cs_buf dalg;
    buf_init(&dalg);
    buf_put(&dalg, sha256_alg_null, sizeof(sha256_alg_null));
    der_wrap(&dalg, 0x31, 0);
    buf_put(&sdata, dalg.b, dalg.n);
    buf_free(&dalg);

    /* encapContentInfo: SEQUENCE { OID pkcs7-data } (detached content) */
    static const uint8_t encap[] = { 0x30, 0x0b, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x01 };
    buf_put(&sdata, encap, sizeof(encap));

    /* [0] IMPLICIT certificates — leaf first, then unique intermediates. Never a self-signed root. */
    size_t certs_start = sdata.n;
    int ncerts = 1;
    bool bag_has_leaf = false;
    for (int i = 0; i < g_nbag && !bag_has_leaf; i++)
        bag_has_leaf = g_bag[i].len == leaf_cert_len && !memcmp(g_bag[i].der, leaf_cert_der, leaf_cert_len);
    if (bag_has_leaf) {
        /* the certificates exactly as the store put them in Husk's own signature (its leaf is this one), root included: the set
         * iOS has accepted from this device's store */
        ncerts = 0;
        for (int i = 0; i < g_nbag; i++) { buf_put(&sdata, g_bag[i].der, g_bag[i].len); ncerts++; }
        der_wrap(&sdata, 0xa0, certs_start);
        tl_log_line("sign: CMS certificates %d (as in Husk's own signature)", ncerts);
        goto certs_done;
    }
    buf_put(&sdata, leaf_cert_der, leaf_cert_len);
    if (extra_certs) {
        CFIndex count = CFArrayGetCount(extra_certs);
        for (CFIndex i = 0; i < count; i++) {
            SecCertificateRef c = (SecCertificateRef)CFArrayGetValueAtIndex(extra_certs, i);
            CFDataRef cd = SecCertificateCopyData(c);
            if (cd) {
                const uint8_t *p = CFDataGetBytePtr(cd);
                size_t n = (size_t)CFDataGetLength(cd);
                if (n != leaf_cert_len || memcmp(p, leaf_cert_der, leaf_cert_len) != 0) {
                    if (!chain_has(p, n) && !cert_is_root(p, n)) {
                        buf_put(&sdata, p, n);
                        ncerts++;
                    }
                }
                CFRelease(cd);
            }
        }
    }
    for (int i = 0; i < g_nchain; i++)
        if (g_chain[i].len != leaf_cert_len || memcmp(g_chain[i].der, leaf_cert_der, leaf_cert_len) != 0) {
            buf_put(&sdata, g_chain[i].der, g_chain[i].len);
            ncerts++;
        }
    der_wrap(&sdata, 0xa0, certs_start);
    tl_log_line("sign: CMS certificates %d (leaf + intermediates, no root)", ncerts);
certs_done:

    /* Append signerInfos SET OF */
    buf_put(&sdata, sinfo.b, sinfo.n);
    buf_free(&sinfo);

    der_wrap(&sdata, 0x30, 0); /* SignedData SEQUENCE */

    /* Wrap in ContentInfo (pkcs7-signedData) */
    cs_buf cinfo;
    buf_init(&cinfo);
    static const uint8_t oid_signed_data[] = { 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02 };
    buf_put(&cinfo, oid_signed_data, sizeof(oid_signed_data));
    der_wrap(&sdata, 0xa0, 0); /* [0] EXPLICIT SignedData */
    buf_put(&cinfo, sdata.b, sdata.n);
    buf_free(&sdata);
    der_wrap(&cinfo, 0x30, 0); /* ContentInfo SEQUENCE */

    *out_cms = cinfo;
    return true;
}

/* ------------------------------------------------------------------ PKCS#12 Helper */

#if !TARGET_OS_IPHONE
/*
 * On macOS, SecPKCS12Import defaults to importing identities into the user's
 * login keychain, which prompts the user with a GUI dialog when signing.
 * To avoid prompts and keychain pollution during testing, we create an unlocked
 * temporary keychain, import into it, and delete the keychain when finished.
 */
static SecKeychainRef macos_create_temp_keychain(char *kc_path_out, size_t kc_path_len) {
    snprintf(kc_path_out, kc_path_len, "/tmp/.husk_cs_%d_%lu.keychain", getpid(), (unsigned long)time(NULL));
    unlink(kc_path_out);
    SecKeychainRef kc = NULL;
    OSStatus st = SecKeychainCreate(kc_path_out, 4, "temp", false, NULL, &kc);
    if (st != errSecSuccess) return NULL;
    SecKeychainUnlock(kc, 4, "temp", true);
    return kc;
}

static void macos_cleanup_temp_keychain(SecKeychainRef kc, const char *kc_path) {
    if (kc) {
        SecKeychainDelete(kc);
        CFRelease(kc);
    }
    if (kc_path && kc_path[0]) {
        unlink(kc_path);
    }
}
#endif

/*
 * Opening the .p12. Husk's own reader (husk-tl-pkcs12.inc) comes first: it reads what OpenSSL 3, Keychain Access, Windows,
 * SideStore/AltStore and the signing services write, tells a wrong password from a .p12 without its key, and needs no
 * keychain. SecPKCS12Import stays behind it, for anything that reader does not know.
 */
#include "husk-tl-pkcs12.inc"

#include <pthread.h>

static OSStatus pkcs12_import_once(CFDataRef data, CFStringRef passphrase, bool omit_pass,
#if !TARGET_OS_IPHONE
                                   SecKeychainRef kc,
#endif
                                   CFArrayRef *got)
{
    *got = NULL;
    const void *keys[2];
    const void *values[2];
    CFIndex n = 0;
    if (!omit_pass && passphrase) { keys[n] = kSecImportExportPassphrase; values[n] = passphrase; n++; }
#if !TARGET_OS_IPHONE
    if (kc) { keys[n] = kSecImportExportKeychain; values[n] = kc; n++; }
#endif
    CFDictionaryRef options = CFDictionaryCreate(kCFAllocatorDefault, keys, values, n,
                                                 &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    OSStatus st = SecPKCS12Import(data, options, got);
    CFRelease(options);
    return st;
}

/* SecPKCS12Import with the password as given, then "", then with no passphrase key at all (never kCFNull: iOS 27's importer
 * hands it to CFStringCreateExternalRepresentation, which raises "unrecognized selector" on NSNull and aborts the app). */
static OSStatus pkcs12_open(CFDataRef data, const char *password,
#if !TARGET_OS_IPHONE
                            SecKeychainRef kc,
#endif
                            CFArrayRef *items)
{
    *items = NULL;
    CFStringRef given = CFStringCreateWithCString(kCFAllocatorDefault, password ? password : "", kCFStringEncodingUTF8);
    if (!given) given = CFStringCreateWithCString(kCFAllocatorDefault, password ? password : "", kCFStringEncodingISOLatin1);
    if (!given) given = (CFStringRef)CFRetain(CFSTR(""));
    CFStringRef variants[3] = { given, CFSTR(""), given };
    bool omit[3] = { false, false, true };
    int first = (password && password[0]) ? 0 : 1;
    OSStatus st = errSecParam;
    for (int i = first; i < 3; i++) {
        CFArrayRef got = NULL;
        st = pkcs12_import_once(data, variants[i], omit[i],
#if !TARGET_OS_IPHONE
                                kc,
#endif
                                &got);
        if (st == errSecSuccess && got && CFArrayGetCount(got) > 0) { *items = got; break; }
        if (got) CFRelease(got);
        if (st == errSecSuccess) st = errSecItemNotFound;
    }
    CFRelease(given);
    return st;
}

/* An opened developer identity: the key, the developer certificate and the certificates beside it in the .p12. */
typedef struct {
    bool open;
    SecKeyRef key;
    CFDataRef cert_data;        /* the developer certificate (meta points into it) */
    CFMutableArrayRef extra;    /* SecCertificateRef: the .p12's other certificates */
    cert_meta meta;
    CFArrayRef items;           /* SecPKCS12Import's result, when it was the one that opened the .p12 */
    const char *how;            /* "Husk" or "Security" */
#if !TARGET_OS_IPHONE
    SecKeychainRef kc;
    char kc_path[256];
#endif
} husk_identity;

static void identity_close(husk_identity *id)
{
    if (!id->open) return;
    if (id->key) CFRelease(id->key);
    if (id->cert_data) CFRelease(id->cert_data);
    if (id->extra) CFRelease(id->extra);
    if (id->items) CFRelease(id->items);
#if !TARGET_OS_IPHONE
    if (id->kc) macos_cleanup_temp_keychain(id->kc, id->kc_path);
#endif
    memset(id, 0, sizeof(*id));
}

static void say(char *err, size_t errlen, const char *text)
{
    if (err && errlen) snprintf(err, errlen, "%s", text);
}

/* With Husk's reader. Returns a P12_ status; on P12_OK id is open. */
static int identity_open_native(const uint8_t *p12, size_t len, const char *password, husk_identity *id, char *err, size_t errlen)
{
    p12_contents c;
    int rc = p12_decode(p12, len, password, &c, err, errlen);
    if (rc != P12_OK) return rc;
    bool is_rsa = true;
    int bits = 0;
    p12_buf raw = { 0 };
    rc = p12_key_raw(&c, &is_rsa, &bits, &raw);
    if (rc != P12_OK) {
        say(err, errlen, rc == P12_ERR_UNSUPPORTED ? "the private key in this .p12 is of a kind iOS cannot sign with"
                                                   : "the private key in this .p12 is damaged");
        p12_buf_free(&raw);
        p12_free(&c);
        return rc;
    }
    CFDataRef key_data = CFDataCreate(kCFAllocatorDefault, raw.b, (CFIndex)raw.n);
    p12_buf_free(&raw);
    CFNumberRef size = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &bits);
    const void *keys[] = { kSecAttrKeyType, kSecAttrKeyClass, kSecAttrKeySizeInBits };
    const void *values[] = { is_rsa ? kSecAttrKeyTypeRSA : kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClassPrivate, size };
    CFDictionaryRef attrs = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFErrorRef cferr = NULL;
    SecKeyRef key = key_data ? SecKeyCreateWithData(key_data, attrs, &cferr) : NULL;
    CFRelease(attrs);
    CFRelease(size);
    if (key_data) CFRelease(key_data);
    if (!key) {
        long code = cferr ? (long)CFErrorGetCode(cferr) : 0;
        if (cferr) CFRelease(cferr);
        if (err && errlen) snprintf(err, errlen, "iOS did not take the private key in this .p12 (error %ld)", code);
        p12_free(&c);
        return P12_ERR_UNSUPPORTED;
    }

    memset(id, 0, sizeof(*id));
    id->open = true;
    id->how = "Husk";
    id->key = key;
    id->cert_data = CFDataCreate(kCFAllocatorDefault, c.certs[c.leaf].der, (CFIndex)c.certs[c.leaf].len);
    id->extra = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    for (int i = 0; i < c.ncerts; i++) {
        if (i == c.leaf) continue;
        CFDataRef d = CFDataCreate(kCFAllocatorDefault, c.certs[i].der, (CFIndex)c.certs[i].len);
        SecCertificateRef sc = d ? SecCertificateCreateWithData(kCFAllocatorDefault, d) : NULL;
        if (sc) { CFArrayAppendValue(id->extra, sc); CFRelease(sc); }
        if (d) CFRelease(d);
    }
    tl_log_line("sign: .p12 read by Husk: %d certificate(s), %d key(s), %s %d-bit key, password %s, MAC %s",
                c.ncerts, c.nkeys, is_rsa ? "RSA" : "EC", bits,
                c.password_form == 0 ? "as given" : c.password_form == 1 ? "empty" : "none", c.had_mac ? "yes" : "no");
    p12_free(&c);
    if (!id->cert_data || !parse_cert_der(CFDataGetBytePtr(id->cert_data), (size_t)CFDataGetLength(id->cert_data), &id->meta)) {
        identity_close(id);
        say(err, errlen, "the certificate in this .p12 is damaged");
        return P12_ERR_FORMAT;
    }
    return P12_OK;
}

/* With SecPKCS12Import. */
static bool identity_open_security(const uint8_t *p12, size_t len, const char *password, husk_identity *id)
{
    memset(id, 0, sizeof(*id));
    CFDataRef data = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, p12, (CFIndex)len, kCFAllocatorNull);
    CFArrayRef items = NULL;
#if !TARGET_OS_IPHONE
    id->kc = macos_create_temp_keychain(id->kc_path, sizeof(id->kc_path));
    OSStatus st = pkcs12_open(data, password, id->kc, &items);
#else
    OSStatus st = pkcs12_open(data, password, &items);
#endif
    CFRelease(data);
    id->open = true;
    id->how = "Security";
    id->items = items;
    if (st != errSecSuccess || !items) { tl_log_line("sign: SecPKCS12Import: status %d", (int)st); identity_close(id); return false; }
    /* The entry with an identity (not always the first). */
    SecIdentityRef identity = NULL;
    CFArrayRef chain = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(items) && !identity; i++) {
        CFDictionaryRef dict = (CFDictionaryRef)CFArrayGetValueAtIndex(items, i);
        identity = (SecIdentityRef)CFDictionaryGetValue(dict, kSecImportItemIdentity);
        chain = (CFArrayRef)CFDictionaryGetValue(dict, kSecImportItemCertChain);
    }
    SecCertificateRef cert = NULL;
    if (!identity || SecIdentityCopyCertificate(identity, &cert) != errSecSuccess || SecIdentityCopyPrivateKey(identity, &id->key) != errSecSuccess) {
        if (cert) CFRelease(cert);
        identity_close(id);
        return false;
    }
    id->cert_data = SecCertificateCopyData(cert);
    CFRelease(cert);
    id->extra = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    if (chain) CFArrayAppendArray(id->extra, chain, CFRangeMake(0, CFArrayGetCount(chain)));
    if (!id->cert_data || !parse_cert_der(CFDataGetBytePtr(id->cert_data), (size_t)CFDataGetLength(id->cert_data), &id->meta)) {
        identity_close(id);
        return false;
    }
    tl_log_line("sign: .p12 read by SecPKCS12Import");
    return true;
}

/* Husk's reader, then SecPKCS12Import. A .p12 that has no key, or no certificate, is not tried twice. */
static int identity_open(const uint8_t *p12, size_t len, const char *password, husk_identity *id, char *err, size_t errlen)
{
    if (err && errlen) err[0] = 0;
    if (!p12 || !len) { say(err, errlen, "the .p12 is empty"); return P12_ERR_FORMAT; }
    char why[200] = "";
    int rc = identity_open_native(p12, len, password, id, why, sizeof(why));
    if (rc == P12_OK) return P12_OK;
    tl_log_line("sign: Husk's .p12 reader: %s (%d)", why, rc);
    if (rc != P12_ERR_NOKEY && rc != P12_ERR_NOCERT && rc != P12_ERR_MEMORY && identity_open_security(p12, len, password, id)) return P12_OK;
    say(err, errlen, why[0] ? why : "the .p12 could not be opened");
    return rc;
}

/* The identity the signer works with, kept between libraries: a game's dozens of libraries open the .p12 once. */
static pthread_mutex_t g_ident_lock = PTHREAD_MUTEX_INITIALIZER;
static husk_identity g_ident;
static uint8_t g_ident_hash[32];

static const husk_identity *identity_cached(const uint8_t *p12, size_t len, const char *password, char *err, size_t errlen)
{
    uint8_t h[32];
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    CC_SHA256_Update(&ctx, p12, (CC_LONG)len);
    CC_SHA256_Update(&ctx, "\0", 1);
    if (password) CC_SHA256_Update(&ctx, password, (CC_LONG)strlen(password));
    CC_SHA256_Final(h, &ctx);
    if (g_ident.open && !memcmp(h, g_ident_hash, 32)) return &g_ident;
    identity_close(&g_ident);
    if (identity_open(p12, len, password, &g_ident, err, errlen) != P12_OK) return NULL;
    memcpy(g_ident_hash, h, 32);
    g_sig_checked = false;          /* a new identity: its key is checked against its certificate again */
    g_app_leaf_logged = 0;
    return &g_ident;
}

int husk_p12_matches_app(const uint8_t *p12, size_t p12_len, const char *password, const char *exe_path)
{
    pthread_mutex_lock(&g_ident_lock);
    static bool read_exe;
    if (!read_exe && exe_path && exe_path[0]) { read_exe = true; husk_codesign_chain_from_executable(exe_path); }
    int r = -1;
    husk_identity id;
    char err[200];
    if (g_app_leaf && identity_open(p12, p12_len, password, &id, err, sizeof(err)) == P12_OK) {
        size_t n = (size_t)CFDataGetLength(id.cert_data);
        r = n == g_app_leaf_len && !memcmp(CFDataGetBytePtr(id.cert_data), g_app_leaf, n);
        identity_close(&id);
    }
    pthread_mutex_unlock(&g_ident_lock);
    tl_log_line(r == 1 ? "sign: the .p12's certificate is the one Husk is installed with"
                : r == 0 ? "sign: WARNING: the .p12's certificate is not the one Husk is installed with: iOS will refuse the libraries it signs"
                : "sign: whether the .p12's certificate is the one Husk is installed with is not known");
    return r;
}

int husk_p12_check(const uint8_t *p12, size_t p12_len, const char *password,
                   char *team_id, size_t team_id_len, double *not_after_epoch, char *err, size_t errlen)
{
    if (team_id && team_id_len) team_id[0] = 0;
    husk_identity id;
    int rc = identity_open(p12, p12_len, password, &id, err, errlen);
    if (rc != P12_OK) return rc;
    if (team_id && team_id_len) snprintf(team_id, team_id_len, "%s", id.meta.team_id);
    if (not_after_epoch) *not_after_epoch = (double)id.meta.not_after_epoch;
    bool has_team = id.meta.team_id[0] != 0;
    tl_log_line("sign: certificate CN='%s' team='%s' (opened by %s)", id.meta.common_name, id.meta.team_id, id.how);
    identity_close(&id);
    if (!has_team) {
        say(err, errlen, "this is not an Apple developer certificate (it names no team)");
        return HUSK_P12_NOT_APPLE;
    }
    return HUSK_P12_OK;
}

bool husk_p12_info(const uint8_t *p12, size_t p12_len, const char *password,
                   char *team_id, size_t team_id_len,
                   double *not_after_epoch,
                   char *err, size_t errlen)
{
    return husk_p12_check(p12, p12_len, password, team_id, team_id_len, not_after_epoch, err, errlen) == HUSK_P12_OK;
}

/* ------------------------------------------------------------------ Mach-O Dylib Codesigner */

static bool codesign_dylib_locked(const char *path, const uint8_t *p12, size_t p12_len, const char *password,
                                  const char *ident, char *err, size_t errlen);

bool husk_codesign_dylib(const char *path, const uint8_t *p12, size_t p12_len, const char *password,
                         const char *ident, char *err, size_t errlen)
{
    pthread_mutex_lock(&g_ident_lock);
    bool ok = codesign_dylib_locked(path, p12, p12_len, password, ident, err, errlen);
    pthread_mutex_unlock(&g_ident_lock);
    return ok;
}

static bool codesign_dylib_locked(const char *path, const uint8_t *p12, size_t p12_len, const char *password,
                                  const char *ident, char *err, size_t errlen)
{
    if (err && errlen > 0) err[0] = '\0';
    if (!path || !path[0]) {
        if (err && errlen > 0) snprintf(err, errlen, "Invalid dylib path");
        return false;
    }

    bool has_identity = (p12 != NULL && p12_len > 0);
    cert_meta meta;
    memset(&meta, 0, sizeof(meta));

    SecKeyRef privKey = NULL;
    CFArrayRef chain = NULL;
    CFDataRef certData = NULL;

    if (has_identity) {
        const husk_identity *idn = identity_cached(p12, p12_len, password, err, errlen);
        if (!idn) return false;
        privKey = idn->key;
        chain = idn->extra;
        certData = idn->cert_data;
        meta = idn->meta;
        ensure_wwdr_in_chain();
        tl_log_line("sign: identity CN='%s' team='%s' rsa=%d chain=%d",
                    meta.common_name, meta.team_id, (int)meta.is_rsa, g_nchain);
        if (!g_app_leaf_logged) {
            g_app_leaf_logged = 1;
            const uint8_t *leaf = CFDataGetBytePtr(certData);
            size_t leaf_len = (size_t)CFDataGetLength(certData);
            /* iOS only trusts a developer certificate a provisioning profile on the device lists: the one the app was installed
             * with. A .p12 of another certificate (an older one, or one from another store) signs libraries iOS refuses. */
            if (!g_app_leaf)
                tl_log_line("sign: Husk's own signature has no developer certificate to compare the .p12's with");
            else if (g_app_leaf_len == leaf_len && !memcmp(g_app_leaf, leaf, leaf_len))
                tl_log_line("sign: the .p12's certificate is the one Husk is installed with");
            else {
                cert_meta am;
                bool parsed = parse_cert_der(g_app_leaf, g_app_leaf_len, &am);
                tl_log_line("sign: WARNING: the .p12's certificate is not the one Husk is installed with (%s%s%s): iOS will refuse "
                            "the libraries it signs. Import the .p12 of the certificate that signed Husk (re-export it from the "
                            "store after its last refresh).",
                            parsed ? "Husk's is '" : "", parsed ? am.common_name : "another", parsed ? "'" : "");
            }
            /* the issuer of the developer certificate has to be in the CMS for iOS to build the chain to Apple's root */
            bool issuer_there = false;
            for (int i = 0; i < g_nchain && !issuer_there; i++) {
                cert_meta cm;
                issuer_there = parse_cert_der(g_chain[i].der, g_chain[i].len, &cm) && cm.subject_len == meta.issuer_len
                            && !memcmp(cm.subject_ptr, meta.issuer_ptr, meta.issuer_len);
            }
            for (CFIndex i = 0; chain && i < CFArrayGetCount(chain) && !issuer_there; i++) {
                CFDataRef d = SecCertificateCopyData((SecCertificateRef)CFArrayGetValueAtIndex(chain, i));
                cert_meta cm;
                issuer_there = d && parse_cert_der(CFDataGetBytePtr(d), (size_t)CFDataGetLength(d), &cm)
                            && cm.subject_len == meta.issuer_len && !memcmp(cm.subject_ptr, meta.issuer_ptr, meta.issuer_len);
                if (d) CFRelease(d);
            }
            tl_log_line(issuer_there ? "sign: the certificate's issuer travels with every signature"
                                     : "sign: WARNING: the certificate's issuer is neither in the .p12 nor in Husk's own signature: "
                                       "iOS may not be able to trust the signature");
        }
    }
    /* Read Mach-O dylib */
    FILE *f = fopen(path, "r+b");
    if (!f) {
        if (err && errlen > 0) snprintf(err, errlen, "Cannot open dylib: %s", path);
        return false;
    }

    fseek(f, 0, SEEK_END);
    long file_size = ftell(f);
    fseek(f, 0, SEEK_SET);

    if (file_size < (long)sizeof(struct mach_header_64)) {
        fclose(f);
        if (err && errlen > 0) snprintf(err, errlen, "File too small to be a Mach-O");
        return false;
    }

    /* Allocate buffer with margin for load commands and signature */
    size_t alloc_sz = (size_t)file_size + 131072;
    uint8_t *file_bytes = (uint8_t *)calloc(1, alloc_sz);
    if (!file_bytes || fread(file_bytes, 1, (size_t)file_size, f) != (size_t)file_size) {
        fclose(f);
        free(file_bytes);
        if (err && errlen > 0) snprintf(err, errlen, "Failed to read dylib file");
        return false;
    }

    struct mach_header_64 *mh = (struct mach_header_64 *)file_bytes;
    if (mh->magic != MH_MAGIC_64) {
        if (err && errlen > 0) snprintf(err, errlen, "Not a 64-bit arm64 Mach-O (magic 0x%x)", mh->magic);
        fclose(f);
        free(file_bytes);
        return false;
    }

    uint8_t *cmd_ptr = file_bytes + sizeof(struct mach_header_64);
    struct segment_command_64 *seg_text = NULL;
    struct segment_command_64 *seg_link = NULL;
    struct linkedit_data_command *cmd_cs = NULL;
    const char *dylib_id = NULL;
    uint64_t exec_base = 0;
    uint64_t exec_limit = 0;
    bool has_exec = false;

    for (uint32_t i = 0; i < mh->ncmds; i++) {
        struct load_command *lc = (struct load_command *)cmd_ptr;
        if (lc->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *seg = (struct segment_command_64 *)lc;
            if (strcmp(seg->segname, "__TEXT") == 0) seg_text = seg;
            else if (strcmp(seg->segname, "__LINKEDIT") == 0) seg_link = seg;
            if (seg->initprot & VM_PROT_EXECUTE) {
                if (!has_exec || seg->fileoff < exec_base) exec_base = seg->fileoff;
                if (seg->fileoff + seg->filesize > exec_limit) exec_limit = seg->fileoff + seg->filesize;
                has_exec = true;
            }
        } else if (lc->cmd == LC_CODE_SIGNATURE) {
            cmd_cs = (struct linkedit_data_command *)lc;
        } else if (lc->cmd == LC_ID_DYLIB) {
            struct dylib_command *dc = (struct dylib_command *)lc;
            dylib_id = (const char *)lc + dc->dylib.name.offset;
            const char *slash = strrchr(dylib_id, '/');
            if (slash) dylib_id = slash + 1;
        }
        cmd_ptr += lc->cmdsize;
    }

    if (has_exec && exec_limit > exec_base) {
        cmd_ptr = file_bytes + sizeof(struct mach_header_64);
        for (uint32_t i = 0; i < mh->ncmds; i++) {
            struct load_command *lc = (struct load_command *)cmd_ptr;
            if (lc->cmd == LC_SEGMENT_64) {
                struct segment_command_64 *seg = (struct segment_command_64 *)lc;
                if ((seg->initprot & VM_PROT_WRITE) && seg->filesize) {
                    uint64_t lo = seg->fileoff, hi = seg->fileoff + seg->filesize;
                    if (lo < exec_limit && hi > exec_base) {
                        if (err && errlen > 0)
                            snprintf(err, errlen,
                                     "writable %.16s [0x%llx,0x%llx) overlaps execSeg [0x%llx,0x%llx); AMFI rejects this as an invalid signature",
                                     seg->segname,
                                     (unsigned long long)lo, (unsigned long long)hi,
                                     (unsigned long long)exec_base, (unsigned long long)exec_limit);
                        fclose(f);
                        free(file_bytes);
                        return false;
                    }
                }
            }
            cmd_ptr += lc->cmdsize;
        }
    }

    if (!seg_text || !seg_link) {
        fclose(f);
        free(file_bytes);
        if (err && errlen > 0) snprintf(err, errlen, "Mach-O missing __TEXT or __LINKEDIT segment");
        return false;
    }

    if (ident && ident[0]) dylib_id = ident;
    if (!dylib_id || !dylib_id[0]) {
        const char *slash = strrchr(path, '/');
        dylib_id = slash ? slash + 1 : path;
    }

    /* Position signature: reuse existing LC_CODE_SIGNATURE offset, or append after current file */
    size_t dataoff = 0;
    if (cmd_cs) {
        dataoff = cmd_cs->dataoff;
    } else {
        dataoff = ((size_t)file_size + 15) & ~15ul;
        /* Insert new LC_CODE_SIGNATURE command */
        cmd_cs = (struct linkedit_data_command *)cmd_ptr;
        cmd_cs->cmd = LC_CODE_SIGNATURE;
        cmd_cs->cmdsize = sizeof(struct linkedit_data_command);
        cmd_cs->dataoff = (uint32_t)dataoff;
        cmd_cs->datasize = 0;
        mh->ncmds += 1;
        mh->sizeofcmds += sizeof(struct linkedit_data_command);
    }

    /* Zero pad any gap before dataoff */
    if (dataoff > (size_t)file_size) {
        memset(file_bytes + file_size, 0, dataoff - (size_t)file_size);
        file_size = (long)dataoff;
    }

    /* 1. Build Requirements blob */
    cs_buf req_buf;
    buf_init(&req_buf);
    if (has_identity) {
        cs_buf req_expr;
        buf_init(&req_expr);
        buf_put_u32_be(&req_expr, CSMAGIC_REQUIREMENT);
        size_t inner_len_pos = req_expr.n;
        buf_put_u32_be(&req_expr, 0); /* inner length placeholder */
        buf_put_u32_be(&req_expr, 1); /* kind = 1 */

        size_t id_len = strlen(dylib_id);
        size_t id_pad = (4 - (id_len % 4)) % 4;

        if (meta.common_name[0]) {
            /* Full Apple designated requirement (right-associative tree, byte-identical to `codesign`):
             * and(ident, and(apple generic anchor, and(leaf subject.CN, cert1 WWDR OID exists)))
             */
            buf_put_u32_be(&req_expr, 6); /* opAnd */

            buf_put_u32_be(&req_expr, 2); /* opIdent */
            buf_put_u32_be(&req_expr, (uint32_t)id_len);
            buf_put(&req_expr, dylib_id, id_len);
            for (size_t p = 0; p < id_pad; p++) buf_put_byte(&req_expr, 0);

            buf_put_u32_be(&req_expr, 6); /* opAnd */
            buf_put_u32_be(&req_expr, 15); /* opAppleGenericAnchor */

            buf_put_u32_be(&req_expr, 6); /* opAnd */

            buf_put_u32_be(&req_expr, 11); /* opCertField */
            buf_put_u32_be(&req_expr, 0);  /* cert 0 (leaf) */
            static const char cn_field[] = "subject.CN";
            size_t fld_len = strlen(cn_field);
            size_t fld_pad = (4 - (fld_len % 4)) % 4;
            buf_put_u32_be(&req_expr, (uint32_t)fld_len);
            buf_put(&req_expr, cn_field, fld_len);
            for (size_t p = 0; p < fld_pad; p++) buf_put_byte(&req_expr, 0);
            buf_put_u32_be(&req_expr, 1);  /* matchEqual */
            size_t cn_len = strlen(meta.common_name);
            size_t cn_pad = (4 - (cn_len % 4)) % 4;
            buf_put_u32_be(&req_expr, (uint32_t)cn_len);
            buf_put(&req_expr, meta.common_name, cn_len);
            for (size_t p = 0; p < cn_pad; p++) buf_put_byte(&req_expr, 0);

            buf_put_u32_be(&req_expr, 14); /* opCertGeneric */
            buf_put_u32_be(&req_expr, 1);  /* cert 1 (intermediate) */
            static const uint8_t wwdr_oid[10] = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x06, 0x02, 0x01 };
            buf_put_u32_be(&req_expr, sizeof(wwdr_oid));
            buf_put(&req_expr, wwdr_oid, sizeof(wwdr_oid));
            for (size_t p = 0; p < (4 - (sizeof(wwdr_oid) % 4)) % 4; p++) buf_put_byte(&req_expr, 0);
            buf_put_u32_be(&req_expr, 0);  /* matchExists */
        } else {
            /* Fallback to simple identifier */
            buf_put_u32_be(&req_expr, 2); /* opIdent */
            buf_put_u32_be(&req_expr, (uint32_t)id_len);
            buf_put(&req_expr, dylib_id, id_len);
            for (size_t p = 0; p < id_pad; p++) buf_put_byte(&req_expr, 0);
        }

        uint32_t req_inner_len = (uint32_t)req_expr.n;
        buf_set_u32_be(&req_expr, inner_len_pos, req_inner_len);

        /* SuperBlob wrapper */
        buf_put_u32_be(&req_buf, CSMAGIC_REQUIREMENTS);
        buf_put_u32_be(&req_buf, 12 + 8 + req_inner_len);
        buf_put_u32_be(&req_buf, 1);  /* count = 1 */
        buf_put_u32_be(&req_buf, 3);  /* type = kSecDesignatedRequirementType */
        buf_put_u32_be(&req_buf, 20); /* offset = 20 */
        buf_put(&req_buf, req_expr.b, req_expr.n);
        buf_free(&req_expr);
    } else {
        /* Ad-hoc requirements vector */
        buf_put_u32_be(&req_buf, CSMAGIC_REQUIREMENTS);
        buf_put_u32_be(&req_buf, 12);
        buf_put_u32_be(&req_buf, 0);  /* count = 0 */
    }
    /*
     * Two CodeDirectories, as SideStore/AltStore's ldid, zsign and Apple's codesign write them for a certificate signature (and as
     * the store signed Husk itself, which iOS accepts): SHA-1 in slot 0, SHA-256 in slot 0x1000. The CMS signs the slot-0 one
     * (messageDigest is its SHA-256), and its 100.9.1/100.9.2 attributes name both CDHashes.
     */
    uint8_t req_sha1[20], req_sha256[32];
    CC_SHA1(req_buf.b, (CC_LONG)req_buf.n, req_sha1);
    CC_SHA256(req_buf.b, (CC_LONG)req_buf.n, req_sha256);

    size_t n_pages = (dataoff + CS_PAGE_SIZE - 1) / CS_PAGE_SIZE;
    size_t ident_len = strlen(dylib_id) + 1;
    size_t team_len = (has_identity && meta.team_id[0]) ? strlen(meta.team_id) + 1 : 0;
    size_t cd_pre_hashes = 88 + ident_len + team_len;
    size_t cd_pad = (4 - (cd_pre_hashes % 4)) % 4;
    size_t cd1_len = cd_pre_hashes + cd_pad + (2 + n_pages) * 20;     /* SHA-1 */
    size_t cd2_len = cd_pre_hashes + cd_pad + (2 + n_pages) * 32;     /* SHA-256 */

    size_t cms_len = 0;
    if (has_identity) {
        /* Probe CMS size to know exact final datasize */
        uint8_t z32[32] = {0}, z20[20] = {0};
        cs_buf cms_probe;
        if (!build_cms_signed_data(z32, z20, z32, CFDataGetBytePtr(certData),
                                  (size_t)CFDataGetLength(certData), &meta, chain, privKey, &cms_probe)) {
            fclose(f);
            free(file_bytes);
            buf_free(&req_buf);
            if (err && errlen > 0)
                snprintf(err, errlen, g_sig_checked && !g_sig_matches
                         ? "the private key in this .p12 does not belong to its certificate (export the .p12 again)"
                         : "Failed to generate CMS signature probe");
            return false;
        }
        cms_len = cms_probe.n;
        buf_free(&cms_probe);
    }

    /* slots: CD (SHA-1), requirements, CD (SHA-256), CMS -- each blob 4-byte aligned, as ldid lays them out */
    uint32_t slot_count = has_identity ? 4 : 3;
    uint32_t off_cd1 = 12 + slot_count * 8;
    uint32_t off_req = (off_cd1 + (uint32_t)cd1_len + 3) & ~3u;
    uint32_t off_cd2 = (off_req + (uint32_t)req_buf.n + 3) & ~3u;
    uint32_t off_cms = (off_cd2 + (uint32_t)cd2_len + 3) & ~3u;
    uint32_t sb_total_len = has_identity ? off_cms + 8 + (uint32_t)cms_len : off_cd2 + (uint32_t)cd2_len;

    /*
     * CRITICAL: Update Mach-O header and __LINKEDIT in file_bytes BEFORE computing
     * page hashes, so that page 0 hash includes the updated load commands!
     */
    cmd_cs->dataoff = (uint32_t)dataoff;
    cmd_cs->datasize = sb_total_len;
    seg_link->filesize = (dataoff + sb_total_len) - seg_link->fileoff;
    seg_link->vmsize = (seg_link->filesize + 16383) & ~16383ul;

    cs_buf cd1, cd2;
    for (int which = 0; which < 2; which++) {
        bool sha1 = which == 0;
        size_t hs = sha1 ? 20 : 32;
        cs_buf *cd = sha1 ? &cd1 : &cd2;
        buf_init(cd);
        buf_put_u32_be(cd, CSMAGIC_CODEDIRECTORY);
        size_t cd_len_pos = cd->n;
        buf_put_u32_be(cd, 0); /* length placeholder */
        buf_put_u32_be(cd, CS_SUPPORTSEXECSEG);
        buf_put_u32_be(cd, has_identity ? 0 : CS_ADHOC);
        size_t hash_off_pos = cd->n;
        buf_put_u32_be(cd, 0); /* hashOffset placeholder */
        size_t ident_off_pos = cd->n;
        buf_put_u32_be(cd, 0); /* identOffset placeholder */
        buf_put_u32_be(cd, 2); /* nSpecialSlots = 2 */
        buf_put_u32_be(cd, (uint32_t)n_pages);
        buf_put_u32_be(cd, (uint32_t)dataoff);
        buf_put_byte(cd, (uint8_t)hs);
        buf_put_byte(cd, sha1 ? 1 : CS_HASHTYPE_SHA256);
        buf_put_byte(cd, 0); /* platform */
        buf_put_byte(cd, CS_PAGE_SIZE_LOG2);
        buf_put_u32_be(cd, 0); /* spare2 */
        buf_put_u32_be(cd, 0); /* scatterOffset */
        size_t team_off_pos = cd->n;
        buf_put_u32_be(cd, 0); /* teamOffset placeholder */
        buf_put_u32_be(cd, 0); /* spare3 */
        buf_put_u64_be(cd, 0); /* codeLimit64 */
        buf_put_u64_be(cd, has_exec ? exec_base : seg_text->fileoff);
        buf_put_u64_be(cd, has_exec ? (exec_limit - exec_base) : seg_text->filesize);
        buf_put_u64_be(cd, 0); /* execSegFlags */
        uint32_t ident_off = (uint32_t)cd->n;
        buf_put(cd, dylib_id, strlen(dylib_id) + 1);
        uint32_t team_off = 0;
        if (has_identity && meta.team_id[0]) {
            team_off = (uint32_t)cd->n;
            buf_put(cd, meta.team_id, strlen(meta.team_id) + 1);
        }
        while (cd->n % 4 != 0) buf_put_byte(cd, 0);
        uint32_t hash_off = (uint32_t)(cd->n + 2 * hs);
        buf_put(cd, sha1 ? req_sha1 : req_sha256, hs);   /* slot -2: requirements */
        uint8_t zero_hash[32] = {0};
        buf_put(cd, zero_hash, hs);                        /* slot -1: Info.plist (none) */
        if (!buf_reserve(cd, n_pages * hs)) break;
        for (size_t i = 0; i < n_pages; i++) {
            size_t poff = i * CS_PAGE_SIZE;
            size_t plen = (poff + CS_PAGE_SIZE <= dataoff) ? CS_PAGE_SIZE : (dataoff - poff);
            uint8_t h[32];
            if (sha1) CC_SHA1(file_bytes + poff, (CC_LONG)plen, h); else CC_SHA256(file_bytes + poff, (CC_LONG)plen, h);
            buf_put(cd, h, hs);
        }
        buf_set_u32_be(cd, cd_len_pos, (uint32_t)cd->n);
        buf_set_u32_be(cd, hash_off_pos, hash_off);
        buf_set_u32_be(cd, ident_off_pos, ident_off);
        if (team_off) buf_set_u32_be(cd, team_off_pos, team_off);
    }
    if (cd1.n != cd1_len || cd2.n != cd2_len) {
        fclose(f);
        free(file_bytes);
        buf_free(&cd1); buf_free(&cd2); buf_free(&req_buf);
        if (err && errlen > 0) snprintf(err, errlen, "CodeDirectory layout mismatch (%zu/%zu vs %zu/%zu)", cd1.n, cd2.n, cd1_len, cd2_len);
        return false;
    }

    /* the CDHashes, and what the CMS's messageDigest holds: SHA-256 of the slot-0 (SHA-1) CodeDirectory */
    uint8_t cdhash1[20], cdhash2[32], md[32];
    CC_SHA1(cd1.b, (CC_LONG)cd1.n, cdhash1);
    CC_SHA256(cd2.b, (CC_LONG)cd2.n, cdhash2);
    CC_SHA256(cd1.b, (CC_LONG)cd1.n, md);

    cs_buf cms;
    buf_init(&cms);
    if (has_identity) {
        /* An ECDSA signature's DER length varies from one signature to the next (an RSA one does not): sign again until it is
         * the length the layout above was made for. */
        bool built = false;
        for (int attempt = 0; attempt < 32 && !built; attempt++) {
            buf_free(&cms);
            built = build_cms_signed_data(md, cdhash1, cdhash2, CFDataGetBytePtr(certData), (size_t)CFDataGetLength(certData),
                                          &meta, chain, privKey, &cms) && cms.n == cms_len;
            if (!built && (meta.is_rsa || !cms.b)) break;
        }
        if (!built) {
            size_t got = cms.n;
            fclose(f);
            free(file_bytes);
            buf_free(&cd1); buf_free(&cd2);
            buf_free(&req_buf);
            buf_free(&cms);
            if (err && errlen > 0) snprintf(err, errlen, "Failed to generate CMS signature (len %zu vs probe %zu)", got, cms_len);
            return false;
        }
    }

    cs_buf sb;
    buf_init(&sb);
    buf_put_u32_be(&sb, CSMAGIC_EMBEDDED_SIGNATURE);
    size_t sb_len_pos = sb.n;
    buf_put_u32_be(&sb, 0); /* length placeholder */
    buf_put_u32_be(&sb, slot_count);
    buf_put_u32_be(&sb, CSSLOT_CODEDIRECTORY); buf_put_u32_be(&sb, off_cd1);
    buf_put_u32_be(&sb, CSSLOT_REQUIREMENTS);  buf_put_u32_be(&sb, off_req);
    buf_put_u32_be(&sb, 0x1000);               buf_put_u32_be(&sb, off_cd2);   /* CSSLOT_ALTERNATE_CODEDIRECTORIES */
    if (has_identity) { buf_put_u32_be(&sb, CSSLOT_SIGNATURESLOT); buf_put_u32_be(&sb, off_cms); }
    buf_put(&sb, cd1.b, cd1.n);
    while (sb.n < off_req) buf_put_byte(&sb, 0);
    buf_put(&sb, req_buf.b, req_buf.n);
    while (sb.n < off_cd2) buf_put_byte(&sb, 0);
    buf_put(&sb, cd2.b, cd2.n);
    if (has_identity) {
        while (sb.n < off_cms) buf_put_byte(&sb, 0);
        buf_put_u32_be(&sb, CSMAGIC_BLOBWRAPPER);
        buf_put_u32_be(&sb, (uint32_t)(8 + cms.n));
        buf_put(&sb, cms.b, cms.n);
    }
    cs_buf cd;                     /* what the clean-up below frees */
    buf_init(&cd);
    buf_free(&cd1); buf_free(&cd2);

    uint32_t final_sb_len = (uint32_t)sb.n;
    uint32_t be_sb_len = htonl(final_sb_len);
    memcpy(sb.b + sb_len_pos, &be_sb_len, 4);

    /* Write updated dylib and signature back to disk */
    fseek(f, 0, SEEK_SET);
    fwrite(file_bytes, 1, dataoff, f);
    fwrite(sb.b, 1, sb.n, f);
    ftruncate(fileno(f), dataoff + sb.n);
    fclose(f);
    tl_log_line("sign: %s ident='%s' codeLimit=0x%zx pages=%zu page=%u KiB blob=%u team=%s",
                path, dylib_id, dataoff, n_pages, CS_PAGE_SIZE / 1024, (unsigned)sb.n,
                has_identity ? meta.team_id : "adhoc");
    static bool described;
    if (!described) { described = true; describe_signature(sb.b, sb.n, "Husk's (first library)"); }

    /* Clean up resources */
    buf_free(&cd);
    buf_free(&req_buf);
    buf_free(&cms);
    buf_free(&sb);
    free(file_bytes);


    return true;
}

/* ------------------------------------------------------------ the app's own chain */

static uint32_t rd_be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }

/* One BER element at p (within end): its tag, where its contents start and how long they are. Apple's signatures use indefinite
 * lengths (0x80 ... 00 00) for the outer structures, so an indefinite element's length is found by walking its children. */
static bool der_next(const uint8_t *p, const uint8_t *end, uint8_t *tag, const uint8_t **val, size_t *vlen)
{
    if (end - p < 2) return false;
    *tag = p[0];
    size_t n = p[1], h = 2;
    if (n == 0x80) {                                   /* indefinite: children until the 00 00 end marker */
        const uint8_t *c = p + 2;
        while (end - c >= 2 && !(c[0] == 0 && c[1] == 0)) {
            uint8_t t; const uint8_t *cv; size_t cn;
            if (!der_next(c, end, &t, &cv, &cn)) return false;
            c = cv + cn + (c[1] == 0x80 ? 2 : 0);     /* past the child (and its own end marker) */
        }
        if (end - c < 2) return false;
        *val = p + 2; *vlen = (size_t)(c - (p + 2));
        return true;
    }
    if (n & 0x80) {
        size_t k = n & 0x7f;
        if (k == 0 || k > 4 || (size_t)(end - p) < 2 + k) return false;
        n = 0;
        for (size_t i = 0; i < k; i++) n = n << 8 | p[2 + i];
        h += k;
    }
    if ((size_t)(end - p) < h + n) return false;
    *val = p + h; *vlen = n;
    return true;
}

/* The end of the element whose contents are v..v+n (an indefinite one also has its 00 00 marker) */
static const uint8_t *der_after(const uint8_t *elem, const uint8_t *v, size_t n) { return v + n + (elem[1] == 0x80 ? 2 : 0); }

static const char *oid_name(const uint8_t *v, size_t n)
{
    static const struct { const char *hex, *name; } k[] = {
        { "2a864886f70d010903", "contentType" }, { "2a864886f70d010905", "signingTime" }, { "2a864886f70d010904", "messageDigest" },
        { "2a864886f763640901", "100.9.1" }, { "2a864886f763640902", "100.9.2" }, { "2a864886f70d010101", "rsaEncryption" },
        { "2a864886f70d01010b", "sha256WithRSA" }, { "2a8648ce3d040302", "ecdsaSHA256" }, { "608648016503040201", "sha256" },
        { "2b0e03021a", "sha1" },
    };
    static char hex[64];
    size_t m = n > 30 ? 30 : n;
    for (size_t i = 0; i < m; i++) snprintf(hex + 2 * i, 3, "%02x", v[i]);
    hex[2 * m] = 0;
    for (size_t i = 0; i < sizeof(k) / sizeof(k[0]); i++) if (!strcmp(hex, k[i].hex)) return k[i].name;
    return hex;
}

/* One line on how a signature is made (its blobs, each CodeDirectory's version, flags, hash, page size, special slots; the CMS
 * signer's algorithms, signed attributes and certificate count), for setting Husk's beside the app's own, which iOS took. */
static void describe_signature(const uint8_t *sig, size_t len, const char *whose)
{
    if (len < 12 || rd_be32(sig) != 0xfade0cc0u) { tl_log_line("sign: format of %s: not an embedded signature", whose); return; }
    char line[1200]; size_t at = 0;
#define ADD(...) do { if (at < sizeof(line)) at += (size_t)snprintf(line + at, sizeof(line) - at, __VA_ARGS__); } while (0)
    uint32_t count = rd_be32(sig + 8);
    ADD("slots");
    for (uint32_t i = 0; i < count && 12 + 8 * (size_t)(i + 1) <= len; i++) {
        uint32_t type = rd_be32(sig + 12 + 8 * i), off = rd_be32(sig + 16 + 8 * i);
        if ((size_t)off + 8 > len) continue;
        uint32_t magic = rd_be32(sig + off), blen = rd_be32(sig + off + 4);
        ADD(" %x", type);
        if (magic == 0xfade0c02u && blen >= 44 && (size_t)off + blen <= len) {
            const uint8_t *cd = sig + off;
            ADD("[CD v%x flags %x hash %u page 2^%u special %u code %u", rd_be32(cd + 8), rd_be32(cd + 12), cd[37], cd[39],
                rd_be32(cd + 24), rd_be32(cd + 28));
            if (rd_be32(cd + 8) >= 0x20400 && blen >= 88)
                ADD(" execseg %llx+%llx f%llx", (unsigned long long)((uint64_t)rd_be32(cd + 64) << 32 | rd_be32(cd + 68)),
                    (unsigned long long)((uint64_t)rd_be32(cd + 72) << 32 | rd_be32(cd + 76)),
                    (unsigned long long)((uint64_t)rd_be32(cd + 80) << 32 | rd_be32(cd + 84)));
            ADD("]");
        } else if (magic == 0xfade0b01u && blen > 8 && (size_t)off + blen <= len) {
            /* ContentInfo { oid, [0] { SignedData { version, digestAlgs, encap, [0] certs, ..., signerInfos } } } */
            const uint8_t *p = sig + off + 8, *end = sig + off + blen, *v; size_t n; uint8_t tag;
            int ncerts = -1;
            char names[300] = "";
            if (der_next(p, end, &tag, &v, &n) && tag == 0x30) {
                const uint8_t *q = v, *qe = v + n;
                if (der_next(q, qe, &tag, &v, &n)) q = der_after(q, v, n);              /* contentType */
                if (q < qe && der_next(q, qe, &tag, &v, &n) && tag == 0xa0 && der_next(v, v + n, &tag, &v, &n) && tag == 0x30) {
                    const uint8_t *r = v, *re = v + n, *last = NULL, *lastv = NULL; size_t lastn = 0;
                    for (; r < re && der_next(r, re, &tag, &v, &n); r = der_after(r, v, n)) {
                        if (tag == 0xa0) {
                            ncerts = 0; names[0] = 0;
                            for (const uint8_t *c = v, *ce = v + n; c < ce; ) {
                                const uint8_t *cv; size_t cn; uint8_t t; cert_meta m;
                                if (!der_next(c, ce, &t, &cv, &cn)) break;
                                ncerts++;
                                size_t whole = (size_t)(der_after(c, cv, cn) - c), nl = strlen(names);
                                if (parse_cert_der(c, whole, &m))
                                    snprintf(names + nl, sizeof(names) - nl, "%s'%.40s'%s", nl ? ", " : "", m.common_name,
                                             cert_is_root(c, whole) ? " (root)" : "");
                                c = der_after(c, cv, cn);
                            }
                        }
                        last = r; lastv = v; lastn = n;
                    }
                    ADD("[CMS certs %d: %s;", ncerts, names);
                    /* signerInfos SET { SignerInfo SEQUENCE { version, sid, digestAlg, [0] attrs, sigAlg, sig } } */
                    if (last && last[0] == 0x31 && der_next(lastv, lastv + lastn, &tag, &v, &n) && tag == 0x30) {
                        const uint8_t *e = v, *ee = v + n; int field = 0;
                        for (; e < ee && der_next(e, ee, &tag, &v, &n); e = der_after(e, v, n), field++) {
                            const uint8_t *ov; size_t on; uint8_t ot;
                            if (tag == 0x30 && field != 1 && der_next(v, v + n, &ot, &ov, &on) && ot == 0x06)   /* digest and signature algorithms */
                                ADD(" %s", oid_name(ov, on));
                            if (tag == 0xa0) {
                                ADD(" attrs(");
                                for (const uint8_t *a = v, *ae = v + n; a < ae; ) {
                                    const uint8_t *av; size_t an; uint8_t at2;
                                    if (!der_next(a, ae, &at2, &av, &an)) break;
                                    if (der_next(av, av + an, &ot, &ov, &on) && ot == 0x06) ADD(" %s", oid_name(ov, on));
                                    a = der_after(a, av, an);
                                }
                                ADD(" )");
                            }
                        }
                    }
                    ADD("]");
                }
            }
        } else if (magic == 0xfade7171u) ADD("[entitlements %u]", blen);
        else if (magic == 0xfade7172u) ADD("[DER entitlements %u]", blen);
        else if (magic == 0xfade0c01u) ADD("[requirements %u]", blen);
    }
#undef ADD
    tl_log_line("sign: format of %s: %s", whose, line);
}

int husk_codesign_chain_from_executable(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    uint8_t hdr[32];
    int found = 0;
    uint32_t dataoff = 0, datasize = 0;
    if (fread(hdr, 1, sizeof(hdr), f) == sizeof(hdr) && *(uint32_t *)hdr == 0xfeedfacfu) {   /* a thin 64-bit Mach-O */
        uint32_t ncmds = *(uint32_t *)(hdr + 16), sizeofcmds = *(uint32_t *)(hdr + 20);
        uint8_t *cmds = malloc(sizeofcmds);
        if (cmds && fread(cmds, 1, sizeofcmds, f) == sizeofcmds) {
            for (uint32_t i = 0, at = 0; i < ncmds && at + 8 <= sizeofcmds; i++) {
                uint32_t cmd = *(uint32_t *)(cmds + at), size = *(uint32_t *)(cmds + at + 4);
                if (cmd == 0x1d && at + 16 <= sizeofcmds) { dataoff = *(uint32_t *)(cmds + at + 8); datasize = *(uint32_t *)(cmds + at + 12); }
                if (size < 8) break;
                at += size;
            }
        }
        free(cmds);
    }
    uint8_t *sig = datasize && datasize < (16u << 20) ? malloc(datasize) : NULL;
    if (sig && fseek(f, dataoff, SEEK_SET) == 0 && fread(sig, 1, datasize, f) == datasize && rd_be32(sig) == 0xfade0cc0u) {
        describe_signature(sig, datasize, "Husk's own executable (made by its store, which iOS accepted)");
        uint32_t count = rd_be32(sig + 8);
        for (uint32_t i = 0; i < count && 12 + 8 * (size_t)(i + 1) <= datasize; i++) {
            uint32_t type = rd_be32(sig + 12 + 8 * i), off = rd_be32(sig + 16 + 8 * i);
            if (type != 0x10000 || (size_t)off + 8 > datasize || rd_be32(sig + off) != 0xfade0b01u) continue;
            uint32_t blen = rd_be32(sig + off + 4);
            if (blen < 8 || (size_t)off + blen > datasize) continue;
            /* ContentInfo { contentType, [0] { SignedData { version, digestAlgorithms, encapContentInfo, [0] certificates ... } } } */
            const uint8_t *p = sig + off + 8, *end = sig + off + blen, *v; size_t n; uint8_t tag;
            if (!der_next(p, end, &tag, &v, &n) || tag != 0x30) continue;            /* ContentInfo */
            const uint8_t *q = v, *qe = v + n;
            if (!der_next(q, qe, &tag, &v, &n) || tag != 0x06) continue;             /* contentType */
            q = der_after(q, v, n);
            if (!der_next(q, qe, &tag, &v, &n) || tag != 0xa0) continue;             /* [0] */
            if (!der_next(v, v + n, &tag, &v, &n) || tag != 0x30) continue;          /* SignedData */
            q = v; qe = v + n;
            for (int field = 0; q < qe && der_next(q, qe, &tag, &v, &n); field++, q = der_after(q, v, n)) {
                if (tag != 0xa0 || field < 3) continue;                                 /* [0] certificates, after the first three */
                const uint8_t *bag[16]; size_t bag_len[16]; int nbag = 0;
                for (const uint8_t *c = v, *ce = v + n; c < ce; ) {
                    const uint8_t *cv; size_t cn;
                    if (!der_next(c, ce, &tag, &cv, &cn)) break;
                    size_t whole = (size_t)(der_after(c, cv, cn) - c);
                    if (tag == 0x30 && nbag < 16) { bag[nbag] = c; bag_len[nbag] = whole; nbag++; }
                    if (tag == 0x30 && g_nbag < 8 && (g_bag[g_nbag].der = malloc(whole))) {
                        bool dup = false;
                        for (int k = 0; k < g_nbag && !dup; k++) dup = g_bag[k].len == whole && !memcmp(g_bag[k].der, c, whole);
                        if (dup) free(g_bag[g_nbag].der);
                        else { memcpy(g_bag[g_nbag].der, c, whole); g_bag[g_nbag].len = whole; g_nbag++; }
                    }
                    if (tag == 0x30 && chain_add(c, whole)) found++;
                    c = der_after(c, cv, cn);
                }
                /* the developer certificate: one with a Team ID (Apple's intermediates have none) that issued none of the others */
                for (int a = 0; a < nbag && !g_app_leaf; a++) {
                    cert_meta ma;
                    if (!parse_cert_der(bag[a], bag_len[a], &ma) || !ma.team_id[0] || cert_is_root(bag[a], bag_len[a])) continue;
                    bool issuer = false;
                    for (int b = 0; b < nbag && !issuer; b++) {
                        cert_meta mb;
                        issuer = b != a && parse_cert_der(bag[b], bag_len[b], &mb) && mb.issuer_len == ma.subject_len
                              && !memcmp(mb.issuer_ptr, ma.subject_ptr, ma.subject_len);
                    }
                    if (!issuer && (g_app_leaf = malloc(bag_len[a]))) { memcpy(g_app_leaf, bag[a], bag_len[a]); g_app_leaf_len = bag_len[a]; }
                }
                break;
            }
        }
    }
    free(sig);
    fclose(f);
    ensure_wwdr_in_chain();
    return found;
}

/* ------------------------------------------------------------ the on-device self-test */

static bool copy_file(const char *from, const char *to)
{
    FILE *a = fopen(from, "rb"), *b = a ? fopen(to, "wb") : NULL;
    bool ok = a && b;
    char buf[65536]; size_t n;
    while (ok && (n = fread(buf, 1, sizeof(buf), a)) > 0) ok = fwrite(buf, 1, n, b) == n;
    if (a) fclose(a);
    if (b && fclose(b) != 0) ok = false;
    return ok;
}

/* dlopen, then the test function: 1 loaded and answered 42, 0 refused (why says how) */
static int try_load(const char *path, char *why, size_t whylen)
{
    void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        const char *e = dlerror();
        const char *cut = e ? strstr(e, "(code signature") : NULL;
        snprintf(why, whylen, "%.160s", cut ? cut : e ? e : "?");
        return 0;
    }
    int (*fn)(void) = (int (*)(void))dlsym(h, "husk_sign_test");
    int r = fn ? fn() : -1;
    snprintf(why, whylen, r == 42 ? "loaded" : "loaded, but its function did not answer");
    return r == 42;
}

/* The embedded-signature SuperBlob of a thin arm64 Mach-O (its LC_CODE_SIGNATURE data), malloc'd; NULL if there is none. */
static uint8_t *read_embedded_sig(const char *path, uint32_t *out_len)
{
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    uint8_t hdr[32];
    uint32_t dataoff = 0, datasize = 0;
    uint8_t *sig = NULL;
    if (fread(hdr, 1, sizeof(hdr), f) == sizeof(hdr) && *(uint32_t *)hdr == 0xfeedfacfu) {
        uint32_t ncmds = *(uint32_t *)(hdr + 16), sizeofcmds = *(uint32_t *)(hdr + 20);
        uint8_t *cmds = sizeofcmds < (1u << 20) ? malloc(sizeofcmds) : NULL;
        if (cmds && fread(cmds, 1, sizeofcmds, f) == sizeofcmds)
            for (uint32_t i = 0, at = 0; i < ncmds && at + 16 <= sizeofcmds; i++) {
                uint32_t cmd = *(uint32_t *)(cmds + at), size = *(uint32_t *)(cmds + at + 4);
                if (cmd == 0x1d) { dataoff = *(uint32_t *)(cmds + at + 8); datasize = *(uint32_t *)(cmds + at + 12); }
                if (size < 8) break;
                at += size;
            }
        free(cmds);
    }
    if (datasize >= 12 && datasize < (16u << 20) && (sig = malloc(datasize))
        && fseek(f, dataoff, SEEK_SET) == 0 && fread(sig, 1, datasize, f) == datasize && rd_be32(sig) == 0xfade0cc0u) {
        *out_len = datasize;
    } else { free(sig); sig = NULL; }
    fclose(f);
    return sig;
}

static const uint8_t *sb_slot(const uint8_t *sb, uint32_t len, uint32_t want, uint32_t *blob_len);

/* The signing identifier in a Mach-O's slot-0 CodeDirectory (what AMFI compares under library validation inside a container). */
int husk_codesign_executable_identifier(const char *exe, char *out, int outlen)
{
    if (out && outlen > 0) out[0] = 0;
    uint32_t len = 0;
    uint8_t *sig = read_embedded_sig(exe, &len);
    int ok = 0;
    if (sig) {
        uint32_t cdl = 0;
        const uint8_t *cd = sb_slot(sig, len, 0, &cdl);
        if (cd && cdl >= 24 && rd_be32(cd) == 0xfade0c02u) {
            uint32_t io = rd_be32(cd + 20);
            if (out && outlen > 0 && io && io < cdl) { snprintf(out, (size_t)outlen, "%.*s", outlen - 1, (const char *)cd + io); ok = out[0] != 0; }
        }
    }
    free(sig);
    return ok;
}

/* slot type -> (blob start, length) within a SuperBlob */
static const uint8_t *sb_slot(const uint8_t *sb, uint32_t len, uint32_t want, uint32_t *blob_len)
{
    uint32_t count = rd_be32(sb + 8);
    for (uint32_t i = 0; i < count && 12 + 8 * (size_t)(i + 1) <= len; i++) {
        uint32_t type = rd_be32(sb + 12 + 8 * i), off = rd_be32(sb + 16 + 8 * i);
        if (type == want && (size_t)off + 8 <= len) { *blob_len = rd_be32(sb + off + 4); return sb + off; }
    }
    return NULL;
}

/* Compare one CodeDirectory field by field; the two sign the SAME bytes, so every field that differs is reported, the page
 * hashes included (those must match for identical code). What the one-line summary leaves out shows up here. */
static void diff_code_directory(const uint8_t *a, uint32_t alen, const uint8_t *b, uint32_t blen, const char *tag)
{
#define FEW \
    F(8,  "version",       rd_be32) F(12, "flags",      rd_be32) F(16, "hashOffset",  rd_be32) \
    F(20, "identOffset",   rd_be32) F(24, "nSpecial",   rd_be32) F(28, "nCode",       rd_be32) \
    F(32, "codeLimit",     rd_be32) F(40, "spare2",     rd_be32) F(44, "scatterOff",  rd_be32) \
    F(48, "teamOffset",    rd_be32) F(52, "spare3",     rd_be32)
    char line[700]; size_t at = 0;
#define ADD(...) do { if (at < sizeof(line)) at += (size_t)snprintf(line + at, sizeof(line) - at, __VA_ARGS__); } while (0)
    if (alen < 44 || blen < 44) { tl_log_line("sign diff %s: a CodeDirectory is too short", tag); return; }
#define F(off, name, rd) if (rd(a + off) != rd(b + off)) ADD(" %s store=%u husk=%u", name, (unsigned)rd(a + off), (unsigned)rd(b + off));
    FEW
#undef F
    for (int off = 36; off < 40; off++) {                 /* hashSize, hashType, platform, pageSize: one byte each */
        static const char *bn[] = { "hashSize", "hashType", "platform", "pageSize" };
        if (a[off] != b[off]) ADD(" %s store=%u husk=%u", bn[off - 36], a[off], b[off]);
    }
    if (alen >= 88 && blen >= 88)
        for (int off = 56; off < 88; off += 8) {           /* codeLimit64, execSegBase/Limit/Flags: u64 each */
            static const char *qn[] = { "codeLimit64", "execSegBase", "execSegLimit", "execSegFlags" };
            uint64_t qa = (uint64_t)rd_be32(a + off) << 32 | rd_be32(a + off + 4);
            uint64_t qb = (uint64_t)rd_be32(b + off) << 32 | rd_be32(b + off + 4);
            if (qa != qb) ADD(" %s store=%llx husk=%llx", qn[(off - 56) / 8], (unsigned long long)qa, (unsigned long long)qb);
        }
    /* identifier and team strings */
    uint32_t ia = rd_be32(a + 20), ib = rd_be32(b + 20);
    if (ia < alen && ib < blen && strcmp((const char *)a + ia, (const char *)b + ib))
        ADD(" ident store='%.40s' husk='%.40s'", a + ia, b + ib);
    /* special-slot hashes (requirements at -2, Info.plist at -1) and the code/page hashes: all must match for the same bytes */
    uint32_t ha = rd_be32(a + 16), hb = rd_be32(b + 16), ns_a = rd_be32(a + 24), nc = rd_be32(a + 28);
    uint32_t hs = a[36];
    if (a[36] == b[36] && rd_be32(a + 28) == rd_be32(b + 28) && ns_a == rd_be32(b + 24)
        && ha + nc * hs <= alen && hb + nc * hs <= blen && (size_t)ns_a * hs <= ha && (size_t)ns_a * hs <= hb) {
        for (uint32_t k = 1; k <= ns_a; k++)
            if (memcmp(a + ha - k * hs, b + hb - k * hs, hs)) ADD(" special[-%u]differs", k);
        uint32_t first = nc, ndiff = 0;
        for (uint32_t i = 0; i < nc; i++)
            if (memcmp(a + ha + i * hs, b + hb + i * hs, hs)) { if (first == nc) first = i; ndiff++; }
        if (ndiff) ADD(" pageHashes differ: %u of %u (first page %u)", ndiff, nc, first);
    }
    tl_log_line("sign diff %s:%s", tag, at ? line : " identical");
#undef ADD
#undef FEW
}

/* A code-requirement expression, decoded to a compact string (as `csreq -r-` prints it), for comparing two DRs. Bounded. */
static uint32_t req_expr(const uint8_t *p, uint32_t len, uint32_t at, char *out, size_t *oat, size_t olen, int depth)
{
#define OUT(...) do { if (*oat < olen) *oat += (size_t)snprintf(out + *oat, olen - *oat, __VA_ARGS__); } while (0)
    if (depth > 12 || at + 4 > len) { OUT("?"); return len; }
    uint32_t op = rd_be32(p + at); at += 4;
    switch (op) {
        case 0: OUT("false"); break;
        case 1: OUT("true"); break;
        case 2: { if (at + 4 > len) break; uint32_t n = rd_be32(p + at); at += 4;
                  if (at + n <= len) OUT("ident \"%.*s\"", (int)n, p + at); at += (n + 3) & ~3u; break; }
        case 3: OUT("anchor apple"); break;
        case 14: OUT("anchor apple generic"); break;          /* opAppleGenericAnchor in this encoding */
        case 15: OUT("anchor apple generic"); break;
        case 6: OUT("("); at = req_expr(p, len, at, out, oat, olen, depth + 1); OUT(" and ");
                at = req_expr(p, len, at, out, oat, olen, depth + 1); OUT(")"); break;
        case 7: OUT("("); at = req_expr(p, len, at, out, oat, olen, depth + 1); OUT(" or ");
                at = req_expr(p, len, at, out, oat, olen, depth + 1); OUT(")"); break;
        case 10: case 11: {                                    /* certField: slot, "field", match */
            if (at + 4 > len) break; int slot = (int)rd_be32(p + at); at += 4;
            uint32_t n = at + 4 <= len ? rd_be32(p + at) : 0; at += 4;
            OUT("cert[%d][%.*s]", slot, (int)n, at + n <= len ? (const char *)p + at : ""); at += (n + 3) & ~3u;
            if (at + 4 <= len) { uint32_t m = rd_be32(p + at); at += 4;
                if (m == 0) OUT(" exists"); else if (m == 1) { uint32_t vn = at + 4 <= len ? rd_be32(p + at) : 0; at += 4;
                    OUT("=\"%.*s\"", (int)vn, at + vn <= len ? (const char *)p + at : ""); at += (vn + 3) & ~3u; } }
            break; }
        case 12: {                                             /* certGeneric: slot, OID, match */
            if (at + 4 > len) break; int slot = (int)rd_be32(p + at); at += 4;
            uint32_t n = at + 4 <= len ? rd_be32(p + at) : 0; at += 4 + ((n + 3) & ~3u);
            OUT("cert[%d][field.OID]", slot);
            if (at + 4 <= len) { uint32_t m = rd_be32(p + at); at += 4; if (m == 0) OUT(" exists"); }
            break; }
        default: OUT("op%u", op); break;
    }
    return at;
#undef OUT
}

static void decode_requirements(const uint8_t *rq, uint32_t len, char *out, size_t olen)
{
    size_t oat = 0; out[0] = 0;
    if (len < 12 || rd_be32(rq) != 0xfade0c01u) { snprintf(out, olen, "(not a requirement set, %u bytes)", len); return; }
    uint32_t count = rd_be32(rq + 8);
    for (uint32_t i = 0; i < count && 12 + 8 * (size_t)(i + 1) <= len; i++) {
        uint32_t type = rd_be32(rq + 12 + 8 * i), off = rd_be32(rq + 16 + 8 * i);
        if ((size_t)off + 12 > len || rd_be32(rq + off) != 0xfade0c00u) continue;
        if (oat < olen) oat += (size_t)snprintf(out + oat, olen - oat, "%s[type %u] ", oat ? " " : "", type);
        req_expr(rq, len, off + 12, out, &oat, olen, 0);     /* skip magic,length,kind */
    }
    if (!oat) snprintf(out, olen, "(empty, %u bytes)", len);
}

/* Set the store's signature (on the bundle dylib) beside Husk's (on the same bytes): the one difference iOS reacts to. */
static void diff_signatures_of(const char *store_path, const char *husk_path)
{
    uint32_t sa = 0, sb = 0;
    uint8_t *A = read_embedded_sig(store_path, &sa), *B = read_embedded_sig(husk_path, &sb);
    if (!A || !B) { tl_log_line("sign diff: could not read both signatures (store %s, husk %s)", A ? "ok" : "missing", B ? "ok" : "missing"); free(A); free(B); return; }
    /* slot sets */
    char la[120] = "", lb[120] = ""; size_t pa = 0, pb = 0;
    for (uint32_t i = 0; i < rd_be32(A + 8) && 12 + 8 * (size_t)(i + 1) <= sa; i++)
        pa += (size_t)snprintf(la + pa, sizeof(la) - pa, " %x", rd_be32(A + 12 + 8 * i));
    for (uint32_t i = 0; i < rd_be32(B + 8) && 12 + 8 * (size_t)(i + 1) <= sb; i++)
        pb += (size_t)snprintf(lb + pb, sizeof(lb) - pb, " %x", rd_be32(B + 12 + 8 * i));
    if (strcmp(la, lb)) tl_log_line("sign diff: slots store [%s ] husk [%s ]", la, lb);
    for (uint32_t slot = 0; slot <= 0x1000; slot += (slot ? 0x1000 : 0x1000)) {   /* 0 then 0x1000 */
        uint32_t al = 0, bl = 0;
        const uint8_t *ca = sb_slot(A, sa, slot, &al), *cb = sb_slot(B, sb, slot, &bl);
        if (ca && cb && rd_be32(ca) == 0xfade0c02u && rd_be32(cb) == 0xfade0c02u) {
            char t[16]; snprintf(t, sizeof(t), "CD %#x", slot);
            diff_code_directory(ca, al, cb, bl, t);
        } else if (!!ca != !!cb)
            tl_log_line("sign diff: CD %#x only in %s", slot, ca ? "store" : "husk");
        if (slot == 0x1000) break;
    }
    /* requirements (slot 2): expected to differ (identifier), report lengths; CMS (0x10000): algorithms and cert bag */
    uint32_t ra = 0, rb = 0;
    const uint8_t *rqa = sb_slot(A, sa, 2, &ra), *rqb = sb_slot(B, sb, 2, &rb);
    if (rqa && rqb && (ra != rb || memcmp(rqa, rqb, ra))) {
        char da[200], db[200];
        decode_requirements(rqa, ra, da, sizeof(da));
        decode_requirements(rqb, rb, db, sizeof(db));
        tl_log_line("sign diff: requirements differ -- store: %s", da);
        tl_log_line("sign diff: requirements differ -- husk:  %s", db);
    }
    describe_signature(A, sa, "the store's, on the test library");
    describe_signature(B, sb, "Husk's, on the same test library");
    free(A); free(B);
}

void husk_codesign_diff_test(const char *store_path, const char *husk_path) { diff_signatures_of(store_path, husk_path); }

int husk_codesign_selftest(const char *bundle_dylib, const char *work_dir, const uint8_t *p12, size_t p12_len,
                           const char *password, const char *app_ident)
{
    struct stat st;
    if (!bundle_dylib || stat(bundle_dylib, &st) != 0) {
        tl_log_line("sign test: no HuskSignTest.dylib in this build, skipped");
        return -1;
    }
    char why[200], path[1200];
    int result = 0;
    /* new names each launch: iOS remembers what it decided about a file */
    unsigned tag = (unsigned)time(NULL) ^ ((unsigned)getpid() << 8);

    int t0 = try_load(bundle_dylib, why, sizeof(why));
    tl_log_line("sign test T0 (in the app bundle, the store's signature): %s", why);
    result |= t0 << 0;

    snprintf(path, sizeof(path), "%s/signtest-%08x-store.dylib", work_dir, tag);
    int t1 = copy_file(bundle_dylib, path) ? try_load(path, why, sizeof(why)) : (snprintf(why, sizeof(why), "copy failed: %s", strerror(errno)), 0);
    tl_log_line("sign test T1 (copied beside the converted libraries, the store's signature untouched): %s", why);
    unlink(path);
    result |= t1 << 1;

    for (int k = 0; k < 2; k++) {
        const char *ident = k == 0 ? "HuskSignTest" : (app_ident && app_ident[0] ? app_ident : "com.husk.app");
        snprintf(path, sizeof(path), "%s/signtest-%08x-husk%d.dylib", work_dir, tag, k);
        char err[300] = "";
        int t = 0;
        if (!copy_file(bundle_dylib, path)) snprintf(why, sizeof(why), "copy failed: %s", strerror(errno));
        else if (!husk_codesign_dylib(path, p12, p12_len, password, ident, err, sizeof(err))) snprintf(why, sizeof(why), "signing failed: %s", err);
        else t = try_load(path, why, sizeof(why));
        tl_log_line("sign test T%d (signed by Husk, identifier '%s'): %s", 2 + k, ident, why);
        /* the store signed this same dylib in the bundle: set the two signatures side by side, field by field */
        if (k == 0 && err[0] == '\0') diff_signatures_of(bundle_dylib, path);
        unlink(path);
        result |= t << (2 + k);
    }

    /* T4: sign with the very identifier the store put on this library (its own CD), i.e. the host's. If this is the one that
     * loads, iOS (library validation inside the container) wants the host's identifier, not the library's own. */
    char host_id[128] = "";
    uint32_t sl = 0;
    uint8_t *store_sig = read_embedded_sig(bundle_dylib, &sl);
    if (store_sig) {
        uint32_t cdl = 0;
        const uint8_t *cd = sb_slot(store_sig, sl, 0, &cdl);
        uint32_t io = cd && cdl >= 24 ? rd_be32(cd + 20) : 0;
        if (cd && io && io < cdl) snprintf(host_id, sizeof(host_id), "%s", (const char *)cd + io);
        free(store_sig);
    }
    int t4 = 0;
    if (host_id[0]) {
        snprintf(path, sizeof(path), "%s/signtest-%08x-host.dylib", work_dir, tag);
        char err[300] = "";
        if (!copy_file(bundle_dylib, path)) snprintf(why, sizeof(why), "copy failed: %s", strerror(errno));
        else if (!husk_codesign_dylib(path, p12, p12_len, password, host_id, err, sizeof(err))) snprintf(why, sizeof(why), "signing failed: %s", err);
        else t4 = try_load(path, why, sizeof(why));
        tl_log_line("sign test T4 (signed by Husk with the host's identifier '%s'): %s", host_id, why);
        unlink(path);
    } else tl_log_line("sign test T4: could not read the host's identifier from the test library");
    result |= t4 << 4;
    const char *verdict =
        !t0 ? "the store's own signature on the test library is not accepted either: this install cannot load libraries"
        : !t1 ? "iOS will not load a library from Husk's data folder at all, whatever its signature (the place, not the signature)"
        : (result & 4) ? "Husk's signature works on an ordinary library: what iOS refuses is the layout of the converted libraries"
        : t4 ? "fixed by the identifier: iOS loads Husk's signature when it carries the host's identifier (now used for every library)"
        : "Husk's signature is refused even with the host's identifier: the difference is elsewhere in the signature";
    tl_log_line("sign test: %s (T0-T4 = %d%d%d%d%d)", verdict, t0, t1, (result >> 2) & 1, (result >> 3) & 1, t4);
    return result;
}
