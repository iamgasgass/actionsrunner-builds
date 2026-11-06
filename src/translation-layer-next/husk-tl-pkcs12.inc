/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * husk-tl-pkcs12.inc: a PKCS#12 (.p12 / .pfx) reader of Husk's own, included by husk-tl-codesign.c.
 *
 * Why not SecPKCS12Import alone: Apple's importer only reads the legacy encodings (3DES / RC2-40 with a SHA-1 MAC). A .p12
 * exported by OpenSSL 3 (AES-256-CBC + PBKDF2 + HMAC-SHA-256 MAC, its default since 2021), by most signing services and by
 * some Windows tools fails there with errSecAuthFailed / errSecDecode / "MAC verification failed", which Husk reported as a
 * wrong password. Some .p12 files with no password fail too (an empty passphrase can mean "" or no passphrase at all, which
 * hash differently).
 *
 * This reads (RFC 7292, RFC 8018, RFC 9579):
 *   - the MAC: SHA-1/224/256/384/512 (PKCS#12 KDF) and PBMAC1 (PBKDF2 + HMAC), or no MAC at all;
 *   - legacy bags: pbeWithSHAAnd{3,2}-KeyTripleDES-CBC, pbeWithSHAAnd{128,40}BitRC2-CBC, pbeWithSHAAnd{128,40}BitRC4;
 *   - PBES2: PBKDF2 (HMAC-SHA-1/224/256/384/512) with AES-128/192/256-CBC or DES-EDE3-CBC;
 *   - unencrypted bags, nested SafeContents bags, BER indefinite lengths and constructed OCTET STRINGs;
 *   - the password as given, as "" (two zero bytes in BMPString) and as no password (no bytes).
 * Out: every certificate and private key (PKCS#8) with its localKeyId, the developer certificate paired with its key (by
 * localKeyId, else by public key), and the key as SecKeyCreateWithData wants it (PKCS#1 for RSA, 04|X|Y|D for EC).
 *
 * Self-contained apart from CommonCrypto (hashes, HMAC, AES/3DES): RC2 and RC4 are here, since CommonCrypto's RC2 is
 * deprecated. tools/p12-test.c builds this on Linux against a small CommonCrypto stand-in over OpenSSL.
 */

#include <CommonCrypto/CommonDigest.h>
#include <CommonCrypto/CommonHMAC.h>
#include <CommonCrypto/CommonCryptor.h>

enum {
    P12_OK = 0,
    P12_ERR_PASSWORD = 1,     /* the MAC (or the decryption) does not match any form of the password */
    P12_ERR_FORMAT = 2,       /* not a PKCS#12 file, or a damaged one */
    P12_ERR_UNSUPPORTED = 3,  /* an encryption or MAC this reader does not know (err names its OID) */
    P12_ERR_NOKEY = 4,        /* certificates only: the private key was not exported with them */
    P12_ERR_NOCERT = 5,       /* a key with no certificate */
    P12_ERR_MEMORY = 6,
};

#define P12_MAX_CERTS 16
#define P12_MAX_KEYS 4

typedef struct { uint8_t *der; size_t len; uint8_t kid[64]; size_t kid_len; } p12_item;

typedef struct {
    p12_item certs[P12_MAX_CERTS]; int ncerts;
    p12_item keys[P12_MAX_KEYS]; int nkeys;   /* PKCS#8 PrivateKeyInfo, decrypted */
    int leaf, key;                              /* the developer certificate and its key, or -1 */
    int password_form;                          /* 0 = as given, 1 = "", 2 = no password */
    bool had_mac;
} p12_contents;

/* ------------------------------------------------------------------ small growable buffer */

typedef struct { uint8_t *b; size_t n, cap; } p12_buf;

static bool p12_buf_put(p12_buf *b, const void *p, size_t n)
{
    if (!n) return true;
    if (b->n + n > b->cap) {
        size_t c = b->cap ? b->cap * 2 : 256;
        while (c < b->n + n) c *= 2;
        uint8_t *nb = (uint8_t *)realloc(b->b, c);
        if (!nb) return false;
        b->b = nb; b->cap = c;
    }
    memcpy(b->b + b->n, p, n);
    b->n += n;
    return true;
}

static void p12_buf_free(p12_buf *b) { if (b->b) { memset(b->b, 0, b->cap); free(b->b); } b->b = NULL; b->n = b->cap = 0; }

/* ------------------------------------------------------------------ BER reader */

typedef struct { uint8_t tag; const uint8_t *start, *val, *next; size_t len; } p12_el;

/* One element at p (not past end). Definite and indefinite lengths; single-byte tags only (all PKCS#12 needs). */
static bool p12_el_at(const uint8_t *p, const uint8_t *end, p12_el *e, int depth)
{
    if (depth > 40 || !p || p >= end || end - p < 2) return false;
    if ((p[0] & 0x1f) == 0x1f) return false;
    e->start = p; e->tag = p[0];
    size_t n = p[1], h = 2;
    if (n == 0x80) {
        if (!(p[0] & 0x20)) return false;                       /* indefinite is for constructed elements only */
        const uint8_t *c = p + 2;
        for (;;) {
            if (end - c < 2) return false;
            if (c[0] == 0 && c[1] == 0) break;
            p12_el k;
            if (!p12_el_at(c, end, &k, depth + 1)) return false;
            c = k.next;
        }
        e->val = p + 2; e->len = (size_t)(c - (p + 2)); e->next = c + 2;
        return true;
    }
    if (n & 0x80) {
        size_t k = n & 0x7f;
        if (k == 0 || k > 4 || (size_t)(end - p) < 2 + k) return false;
        n = 0;
        for (size_t i = 0; i < k; i++) n = (n << 8) | p[2 + i];
        h += k;
    }
    if ((size_t)(end - p) - h < n) return false;
    e->val = p + h; e->len = n; e->next = p + h + n;
    return true;
}

/* The index-th child of a constructed element. */
static bool p12_child(const p12_el *parent, int index, p12_el *out)
{
    const uint8_t *c = parent->val, *ce = parent->val + parent->len;
    for (int i = 0; c < ce; i++) {
        if (!p12_el_at(c, ce, out, 0)) return false;
        if (i == index) return true;
        c = out->next;
    }
    return false;
}

static bool p12_parse(const uint8_t *p, size_t n, p12_el *e) { return p12_el_at(p, p + n, e, 0); }

static bool p12_is_oid(const p12_el *e, const uint8_t *oid, size_t n) { return e->tag == 0x06 && e->len == n && !memcmp(e->val, oid, n); }

static bool p12_small_int(const p12_el *e, long *out)
{
    if (e->tag != 0x02 || e->len == 0 || e->len > 8 || (e->val[0] & 0x80)) return false;
    unsigned long v = 0;
    for (size_t i = 0; i < e->len; i++) v = (v << 8) | e->val[i];
    if (v > 0x7fffffffUL) return false;
    *out = (long)v;
    return true;
}

/* An OCTET STRING's bytes, primitive or constructed (BER), appended to out. */
static bool p12_octets(const p12_el *e, p12_buf *out, int depth)
{
    if (depth > 16) return false;
    if (!(e->tag & 0x20)) return p12_buf_put(out, e->val, e->len);
    const uint8_t *c = e->val, *ce = e->val + e->len;
    while (c < ce) {
        p12_el k;
        if (!p12_el_at(c, ce, &k, 0) || (k.tag & 0x1f) != 0x04) return false;
        if (!p12_octets(&k, out, depth + 1)) return false;
        c = k.next;
    }
    return true;
}

static void p12_oid_text(const p12_el *e, char *out, size_t n)
{
    if (!n) return;
    out[0] = 0;
    if (e->tag != 0x06 || !e->len) { snprintf(out, n, "?"); return; }
    size_t at = (size_t)snprintf(out, n, "%u.%u", e->val[0] / 40, e->val[0] % 40);
    unsigned long v = 0;
    for (size_t i = 1; i < e->len && at < n; i++) {
        v = (v << 7) | (e->val[i] & 0x7f);
        if (!(e->val[i] & 0x80)) { at += (size_t)snprintf(out + at, n - at, ".%lu", v); v = 0; }
    }
}

/* ------------------------------------------------------------------ OIDs */

static const uint8_t P12_OID_DATA[]       = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x01 };
static const uint8_t P12_OID_ENCDATA[]    = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x06 };
static const uint8_t P12_OID_ENVDATA[]    = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x03 };
static const uint8_t P12_OID_BAG[]        = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x0c, 0x0a, 0x01 }; /* + 1..6 */
static const uint8_t P12_OID_PBE[]        = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x0c, 0x01 };       /* + 1..6 */
static const uint8_t P12_OID_PBES2[]      = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0d };
static const uint8_t P12_OID_PBKDF2[]     = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0c };
static const uint8_t P12_OID_PBMAC1[]     = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0e };
static const uint8_t P12_OID_HMAC[]       = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x02 };                   /* + 7..11 */
static const uint8_t P12_OID_SHA1[]       = { 0x2b, 0x0e, 0x03, 0x02, 0x1a };
static const uint8_t P12_OID_SHA2[]       = { 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02 };             /* + 1..4 */
static const uint8_t P12_OID_AES[]        = { 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01 };             /* + 2, 22, 42 */
static const uint8_t P12_OID_DES3[]       = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x03, 0x07 };
static const uint8_t P12_OID_X509[]       = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x16, 0x01 };
static const uint8_t P12_OID_LOCALKEYID[] = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x15 };
static const uint8_t P12_OID_RSA[]        = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01 };
static const uint8_t P12_OID_EC[]         = { 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01 };
static const uint8_t P12_OID_P256[]       = { 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07 };
static const uint8_t P12_OID_P384[]       = { 0x2b, 0x81, 0x04, 0x00, 0x22 };
static const uint8_t P12_OID_P521[]       = { 0x2b, 0x81, 0x04, 0x00, 0x23 };

/* An OID that is prefix + one final byte: that byte, or -1. */
static int p12_oid_last(const p12_el *e, const uint8_t *prefix, size_t n)
{
    if (e->tag != 0x06 || e->len != n + 1 || memcmp(e->val, prefix, n)) return -1;
    return e->val[n];
}

/* ------------------------------------------------------------------ hashes */

enum { P12_SHA1, P12_SHA224, P12_SHA256, P12_SHA384, P12_SHA512 };

static size_t p12_hlen(int h) { static const size_t l[] = { 20, 28, 32, 48, 64 }; return l[h]; }
static size_t p12_hblock(int h) { return h >= P12_SHA384 ? 128 : 64; }

static void p12_digest(int h, const void *in, size_t n, uint8_t *out)
{
    switch (h) {
    case P12_SHA1:   CC_SHA1(in, (CC_LONG)n, out); break;
    case P12_SHA224: CC_SHA224(in, (CC_LONG)n, out); break;
    case P12_SHA256: CC_SHA256(in, (CC_LONG)n, out); break;
    case P12_SHA384: CC_SHA384(in, (CC_LONG)n, out); break;
    default:         CC_SHA512(in, (CC_LONG)n, out); break;
    }
}

static void p12_hmac(int h, const uint8_t *key, size_t klen, const uint8_t *data, size_t n, uint8_t *out)
{
    static const CCHmacAlgorithm alg[] = { kCCHmacAlgSHA1, kCCHmacAlgSHA224, kCCHmacAlgSHA256, kCCHmacAlgSHA384, kCCHmacAlgSHA512 };
    static const uint8_t none = 0;
    CCHmac(alg[h], klen ? key : &none, klen, n ? data : &none, n, out);
}

/* A digest OID (sha1, sha224..512) or an HMAC OID (hmacWithSHA1..512): the hash, or -1. */
static int p12_hash_of(const p12_el *oid)
{
    if (p12_is_oid(oid, P12_OID_SHA1, sizeof(P12_OID_SHA1))) return P12_SHA1;
    int s = p12_oid_last(oid, P12_OID_SHA2, sizeof(P12_OID_SHA2));
    if (s == 1) return P12_SHA256;
    if (s == 2) return P12_SHA384;
    if (s == 3) return P12_SHA512;
    if (s == 4) return P12_SHA224;
    int m = p12_oid_last(oid, P12_OID_HMAC, sizeof(P12_OID_HMAC));
    if (m == 7) return P12_SHA1;
    if (m == 8) return P12_SHA224;
    if (m == 9) return P12_SHA256;
    if (m == 10) return P12_SHA384;
    if (m == 11) return P12_SHA512;
    return -1;
}

/* RFC 7292 appendix B.2. id: 1 key, 2 IV, 3 MAC key. */
static bool p12_kdf(int h, const uint8_t *pw, size_t pwlen, const uint8_t *salt, size_t saltlen, uint8_t id, long iter,
                    uint8_t *out, size_t outlen)
{
    if (iter < 1 || iter > 10000000) return false;
    size_t u = p12_hlen(h), v = p12_hblock(h);
    size_t slen = saltlen ? v * ((saltlen + v - 1) / v) : 0, plen = pwlen ? v * ((pwlen + v - 1) / v) : 0, ilen = slen + plen;
    uint8_t *DI = (uint8_t *)malloc(v + ilen), A[64], T[64], B[128];
    if (!DI) return false;
    uint8_t *I = DI + v;
    memset(DI, id, v);
    for (size_t i = 0; i < slen; i++) I[i] = salt[i % saltlen];
    for (size_t i = 0; i < plen; i++) I[slen + i] = pw[i % pwlen];
    while (outlen) {
        p12_digest(h, DI, v + ilen, A);
        for (long j = 1; j < iter; j++) { p12_digest(h, A, u, T); memcpy(A, T, u); }
        size_t take = outlen < u ? outlen : u;
        memcpy(out, A, take);
        out += take; outlen -= take;
        if (!outlen) break;
        for (size_t i = 0; i < v; i++) B[i] = A[i % u];
        for (size_t j = 0; j < ilen; j += v) {
            unsigned c = 1;
            for (size_t k = v; k-- > 0; ) { c += (unsigned)I[j + k] + B[k]; I[j + k] = (uint8_t)c; c >>= 8; }
        }
    }
    memset(DI, 0, v + ilen);
    free(DI);
    return true;
}

/* RFC 8018 PBKDF2 on HMAC (here rather than CCKeyDerivationPBKDF, which refuses an empty password on some iOS versions). */
static bool p12_pbkdf2(int h, const uint8_t *pw, size_t pwlen, const uint8_t *salt, size_t saltlen, long iter,
                       uint8_t *out, size_t outlen)
{
    if (iter < 1 || iter > 10000000) return false;
    size_t u = p12_hlen(h);
    uint8_t *S = (uint8_t *)malloc(saltlen + 4), U[64], X[64], T[64];
    if (!S) return false;
    memcpy(S, salt, saltlen);
    for (uint32_t blk = 1; outlen; blk++) {
        S[saltlen] = (uint8_t)(blk >> 24); S[saltlen + 1] = (uint8_t)(blk >> 16);
        S[saltlen + 2] = (uint8_t)(blk >> 8); S[saltlen + 3] = (uint8_t)blk;
        p12_hmac(h, pw, pwlen, S, saltlen + 4, U);
        memcpy(T, U, u);
        for (long j = 1; j < iter; j++) {
            p12_hmac(h, pw, pwlen, U, u, X);
            memcpy(U, X, u);
            for (size_t k = 0; k < u; k++) T[k] ^= U[k];
        }
        size_t take = outlen < u ? outlen : u;
        memcpy(out, T, take);
        out += take; outlen -= take;
    }
    free(S);
    return true;
}

/* ------------------------------------------------------------------ RC2 (RFC 2268) and RC4 */

static const uint8_t p12_rc2_pi[256] = {
    0xd9, 0x78, 0xf9, 0xc4, 0x19, 0xdd, 0xb5, 0xed, 0x28, 0xe9, 0xfd, 0x79, 0x4a, 0xa0, 0xd8, 0x9d,
    0xc6, 0x7e, 0x37, 0x83, 0x2b, 0x76, 0x53, 0x8e, 0x62, 0x4c, 0x64, 0x88, 0x44, 0x8b, 0xfb, 0xa2,
    0x17, 0x9a, 0x59, 0xf5, 0x87, 0xb3, 0x4f, 0x13, 0x61, 0x45, 0x6d, 0x8d, 0x09, 0x81, 0x7d, 0x32,
    0xbd, 0x8f, 0x40, 0xeb, 0x86, 0xb7, 0x7b, 0x0b, 0xf0, 0x95, 0x21, 0x22, 0x5c, 0x6b, 0x4e, 0x82,
    0x54, 0xd6, 0x65, 0x93, 0xce, 0x60, 0xb2, 0x1c, 0x73, 0x56, 0xc0, 0x14, 0xa7, 0x8c, 0xf1, 0xdc,
    0x12, 0x75, 0xca, 0x1f, 0x3b, 0xbe, 0xe4, 0xd1, 0x42, 0x3d, 0xd4, 0x30, 0xa3, 0x3c, 0xb6, 0x26,
    0x6f, 0xbf, 0x0e, 0xda, 0x46, 0x69, 0x07, 0x57, 0x27, 0xf2, 0x1d, 0x9b, 0xbc, 0x94, 0x43, 0x03,
    0xf8, 0x11, 0xc7, 0xf6, 0x90, 0xef, 0x3e, 0xe7, 0x06, 0xc3, 0xd5, 0x2f, 0xc8, 0x66, 0x1e, 0xd7,
    0x08, 0xe8, 0xea, 0xde, 0x80, 0x52, 0xee, 0xf7, 0x84, 0xaa, 0x72, 0xac, 0x35, 0x4d, 0x6a, 0x2a,
    0x96, 0x1a, 0xd2, 0x71, 0x5a, 0x15, 0x49, 0x74, 0x4b, 0x9f, 0xd0, 0x5e, 0x04, 0x18, 0xa4, 0xec,
    0xc2, 0xe0, 0x41, 0x6e, 0x0f, 0x51, 0xcb, 0xcc, 0x24, 0x91, 0xaf, 0x50, 0xa1, 0xf4, 0x70, 0x39,
    0x99, 0x7c, 0x3a, 0x85, 0x23, 0xb8, 0xb4, 0x7a, 0xfc, 0x02, 0x36, 0x5b, 0x25, 0x55, 0x97, 0x31,
    0x2d, 0x5d, 0xfa, 0x98, 0xe3, 0x8a, 0x92, 0xae, 0x05, 0xdf, 0x29, 0x10, 0x67, 0x6c, 0xba, 0xc9,
    0xd3, 0x00, 0xe6, 0xcf, 0xe1, 0x9e, 0xa8, 0x2c, 0x63, 0x16, 0x01, 0x3f, 0x58, 0xe2, 0x89, 0xa9,
    0x0d, 0x38, 0x34, 0x1b, 0xab, 0x33, 0xff, 0xb0, 0xbb, 0x48, 0x0c, 0x5f, 0xb9, 0xb1, 0xcd, 0x2e,
    0xc5, 0xf3, 0xdb, 0x47, 0xe5, 0xa5, 0x9c, 0x77, 0x0a, 0xa6, 0x20, 0x68, 0xfe, 0x7f, 0xc1, 0xad,
};

static void p12_rc2_schedule(uint16_t K[64], const uint8_t *key, size_t T, unsigned bits)
{
    uint8_t L[128];
    if (T > 128) T = 128;
    memcpy(L, key, T);
    for (size_t i = T; i < 128; i++) L[i] = p12_rc2_pi[(L[i - 1] + L[i - T]) & 0xff];
    unsigned T8 = (bits + 7) / 8, TM = 0xffu >> (8 * T8 - bits);
    L[128 - T8] = p12_rc2_pi[L[128 - T8] & TM];
    for (int i = 127 - (int)T8; i >= 0; i--) L[i] = p12_rc2_pi[L[i + 1] ^ L[i + T8]];
    for (int i = 0; i < 64; i++) K[i] = (uint16_t)(L[2 * i] | (L[2 * i + 1] << 8));
    memset(L, 0, sizeof(L));
}

static void p12_rc2_decrypt_block(const uint16_t K[64], uint8_t b[8])
{
    uint16_t R[4];
    for (int i = 0; i < 4; i++) R[i] = (uint16_t)(b[2 * i] | (b[2 * i + 1] << 8));
    static const int s[4] = { 1, 2, 3, 5 };
    int j = 63;
    for (int round = 16; round-- > 0; ) {
        for (int i = 3; i >= 0; i--) {
            R[i] = (uint16_t)((R[i] >> s[i]) | (R[i] << (16 - s[i])));
            R[i] = (uint16_t)(R[i] - K[j--] - (R[(i + 3) & 3] & R[(i + 2) & 3]) - ((uint16_t)~R[(i + 3) & 3] & R[(i + 1) & 3]));
        }
        if (round == 5 || round == 11)
            for (int i = 3; i >= 0; i--) R[i] = (uint16_t)(R[i] - K[R[(i + 3) & 3] & 63]);
    }
    for (int i = 0; i < 4; i++) { b[2 * i] = (uint8_t)R[i]; b[2 * i + 1] = (uint8_t)(R[i] >> 8); }
}

static void p12_rc4(const uint8_t *key, size_t klen, uint8_t *data, size_t n)
{
    uint8_t S[256];
    for (int i = 0; i < 256; i++) S[i] = (uint8_t)i;
    for (unsigned i = 0, j = 0; i < 256; i++) { j = (j + S[i] + key[i % klen]) & 0xff; uint8_t t = S[i]; S[i] = S[j]; S[j] = t; }
    for (size_t k = 0, i = 0, j = 0; k < n; k++) {
        i = (i + 1) & 0xff; j = (j + S[i]) & 0xff;
        uint8_t t = S[i]; S[i] = S[j]; S[j] = t;
        data[k] ^= S[(S[i] + S[j]) & 0xff];
    }
    memset(S, 0, sizeof(S));
}

/* ------------------------------------------------------------------ block decryption */

enum { P12_AES, P12_3DES, P12_RC2 };

/* CBC decrypt of in into out (n bytes), then the PKCS#7 padding off. False: a key that does not fit (a wrong password). */
static bool p12_cbc(int alg, const uint8_t *key, size_t klen, unsigned rc2_bits, const uint8_t *iv,
                    const uint8_t *in, size_t n, p12_buf *out)
{
    size_t bs = alg == P12_AES ? 16 : 8;
    if (!n || n % bs) return false;
    uint8_t *plain = (uint8_t *)malloc(n);
    if (!plain) return false;
    bool ok = true;
    if (alg == P12_RC2) {
        uint16_t K[64];
        uint8_t prev[8], cur[8];
        p12_rc2_schedule(K, key, klen, rc2_bits);
        memcpy(prev, iv, 8);
        for (size_t at = 0; at < n; at += 8) {
            memcpy(cur, in + at, 8);
            memcpy(plain + at, cur, 8);
            p12_rc2_decrypt_block(K, plain + at);
            for (int i = 0; i < 8; i++) plain[at + i] ^= prev[i];
            memcpy(prev, cur, 8);
        }
        memset(K, 0, sizeof(K));
    } else {
        size_t moved = 0;
        uint8_t k3[24];
        if (alg == P12_3DES && klen == 16) { memcpy(k3, key, 16); memcpy(k3 + 16, key, 8); key = k3; klen = 24; }
        CCCryptorStatus st = CCCrypt(kCCDecrypt, alg == P12_AES ? kCCAlgorithmAES : kCCAlgorithm3DES, 0,
                                     key, klen, iv, in, n, plain, n, &moved);
        memset(k3, 0, sizeof(k3));
        ok = st == kCCSuccess && moved == n;
    }
    if (ok) {
        uint8_t pad = plain[n - 1];
        ok = pad >= 1 && pad <= bs;
        for (size_t i = 0; ok && i < pad; i++) ok = plain[n - 1 - i] == pad;
        if (ok) ok = p12_buf_put(out, plain, n - pad);
    }
    memset(plain, 0, n);
    free(plain);
    return ok;
}

/* ------------------------------------------------------------------ passwords */

typedef struct {
    const uint8_t *utf8; size_t utf8_len;   /* for PBES2 and PBMAC1 */
    uint8_t *bmp; size_t bmp_len;           /* for the PKCS#12 KDF: UTF-16BE and a 00 00 end, or nothing */
} p12_pw;

/* UTF-8 to BMPString with its two-zero-byte end (what OpenSSL hashes). Invalid UTF-8 is taken as Latin-1. */
static bool p12_pw_make(p12_pw *pw, const char *utf8, bool none)
{
    memset(pw, 0, sizeof(*pw));
    static const uint8_t empty = 0;
    pw->utf8 = utf8 ? (const uint8_t *)utf8 : &empty;
    pw->utf8_len = utf8 ? strlen(utf8) : 0;
    if (none) { pw->utf8_len = 0; return true; }
    p12_buf b = { 0 };
    const uint8_t *s = pw->utf8, *e = s + pw->utf8_len;
    bool valid = true;
    for (int pass = 0; pass < 2; pass++) {
        b.n = 0;
        for (const uint8_t *c = s; c < e; ) {
            uint32_t cp;
            if (!valid) cp = *c++;
            else if (c[0] < 0x80) cp = *c++;
            else if ((c[0] & 0xe0) == 0xc0 && e - c >= 2 && (c[1] & 0xc0) == 0x80) { cp = (uint32_t)(c[0] & 0x1f) << 6 | (c[1] & 0x3f); c += 2; }
            else if ((c[0] & 0xf0) == 0xe0 && e - c >= 3 && (c[1] & 0xc0) == 0x80 && (c[2] & 0xc0) == 0x80) {
                cp = (uint32_t)(c[0] & 0x0f) << 12 | (uint32_t)(c[1] & 0x3f) << 6 | (c[2] & 0x3f); c += 3;
            } else if ((c[0] & 0xf8) == 0xf0 && e - c >= 4 && (c[1] & 0xc0) == 0x80 && (c[2] & 0xc0) == 0x80 && (c[3] & 0xc0) == 0x80) {
                cp = (uint32_t)(c[0] & 0x07) << 18 | (uint32_t)(c[1] & 0x3f) << 12 | (uint32_t)(c[2] & 0x3f) << 6 | (c[3] & 0x3f); c += 4;
            } else { valid = false; break; }
            uint8_t u[4];
            if (cp >= 0x10000) {
                cp -= 0x10000;
                uint16_t hi = (uint16_t)(0xd800 | (cp >> 10)), lo = (uint16_t)(0xdc00 | (cp & 0x3ff));
                u[0] = (uint8_t)(hi >> 8); u[1] = (uint8_t)hi; u[2] = (uint8_t)(lo >> 8); u[3] = (uint8_t)lo;
                if (!p12_buf_put(&b, u, 4)) { p12_buf_free(&b); return false; }
            } else {
                u[0] = (uint8_t)(cp >> 8); u[1] = (uint8_t)cp;
                if (!p12_buf_put(&b, u, 2)) { p12_buf_free(&b); return false; }
            }
        }
        if (valid) break;
    }
    static const uint8_t z[2] = { 0, 0 };
    if (!p12_buf_put(&b, z, 2)) { p12_buf_free(&b); return false; }
    pw->bmp = b.b; pw->bmp_len = b.n;
    return true;
}

static void p12_pw_free(p12_pw *pw) { if (pw->bmp) { memset(pw->bmp, 0, pw->bmp_len); free(pw->bmp); } pw->bmp = NULL; }

/* ------------------------------------------------------------------ decrypting one thing */

/* Decrypts in (an EncryptedContentInfo's or EncryptedPrivateKeyInfo's content) by the algorithm alg (an AlgorithmIdentifier). */
static int p12_decrypt(const p12_el *alg, const uint8_t *in, size_t n, const p12_pw *pw, p12_buf *out, char *err, size_t errlen)
{
    p12_el oid, params;
    if (!p12_child(alg, 0, &oid) || oid.tag != 0x06) return P12_ERR_FORMAT;
    bool have_params = p12_child(alg, 1, &params);

    int legacy = p12_oid_last(&oid, P12_OID_PBE, sizeof(P12_OID_PBE));
    if (legacy >= 1 && legacy <= 6) {
        /* pkcs-12PbeParams ::= SEQUENCE { salt OCTET STRING, iterations INTEGER } */
        p12_el salt, it;
        long iter = 0;
        if (!have_params || params.tag != 0x30 || !p12_child(&params, 0, &salt) || salt.tag != 0x04 ||
            !p12_child(&params, 1, &it) || !p12_small_int(&it, &iter)) return P12_ERR_FORMAT;
        static const struct { int alg; size_t key; unsigned bits; } legacy_alg[7] = {
            { 0, 0, 0 }, { -1, 16, 128 }, { -1, 5, 40 }, { P12_3DES, 24, 0 }, { P12_3DES, 16, 0 }, { P12_RC2, 16, 128 }, { P12_RC2, 5, 40 },
        };
        uint8_t key[24], iv[8];
        size_t klen = legacy_alg[legacy].key;
        if (!p12_kdf(P12_SHA1, pw->bmp, pw->bmp_len, salt.val, salt.len, 1, iter, key, klen)) return P12_ERR_FORMAT;
        int rc = P12_OK;
        if (legacy_alg[legacy].alg < 0) {                         /* RC4: a stream, no padding to check */
            if (!p12_buf_put(out, in, n)) rc = P12_ERR_MEMORY;
            else p12_rc4(key, klen, out->b + out->n - n, n);
        } else {
            if (!p12_kdf(P12_SHA1, pw->bmp, pw->bmp_len, salt.val, salt.len, 2, iter, iv, 8)) return P12_ERR_FORMAT;
            if (!p12_cbc(legacy_alg[legacy].alg, key, klen, legacy_alg[legacy].bits, iv, in, n, out)) rc = P12_ERR_PASSWORD;
        }
        memset(key, 0, sizeof(key));
        return rc;
    }

    if (p12_is_oid(&oid, P12_OID_PBES2, sizeof(P12_OID_PBES2))) {
        /* PBES2-params ::= SEQUENCE { keyDerivationFunc AlgorithmIdentifier, encryptionScheme AlgorithmIdentifier } */
        p12_el kdf, kdf_oid, kdf_params, scheme, scheme_oid, iv;
        if (!have_params || params.tag != 0x30 || !p12_child(&params, 0, &kdf) || !p12_child(&params, 1, &scheme) ||
            !p12_child(&kdf, 0, &kdf_oid) || !p12_child(&scheme, 0, &scheme_oid)) return P12_ERR_FORMAT;
        if (!p12_is_oid(&kdf_oid, P12_OID_PBKDF2, sizeof(P12_OID_PBKDF2))) {
            char o[64]; p12_oid_text(&kdf_oid, o, sizeof(o));
            snprintf(err, errlen, "key derivation %s is not supported", o);
            return P12_ERR_UNSUPPORTED;
        }
        int cipher = -1;
        size_t klen = 0;
        int aes = p12_oid_last(&scheme_oid, P12_OID_AES, sizeof(P12_OID_AES));
        if (aes == 2) { cipher = P12_AES; klen = 16; }
        else if (aes == 22) { cipher = P12_AES; klen = 24; }
        else if (aes == 42) { cipher = P12_AES; klen = 32; }
        else if (p12_is_oid(&scheme_oid, P12_OID_DES3, sizeof(P12_OID_DES3))) { cipher = P12_3DES; klen = 24; }
        if (cipher < 0) {
            char o[64]; p12_oid_text(&scheme_oid, o, sizeof(o));
            snprintf(err, errlen, "encryption %s is not supported", o);
            return P12_ERR_UNSUPPORTED;
        }
        size_t ivlen = cipher == P12_AES ? 16 : 8;
        if (!p12_child(&scheme, 1, &iv) || iv.tag != 0x04 || iv.len != ivlen) return P12_ERR_FORMAT;
        /* PBKDF2-params ::= SEQUENCE { salt OCTET STRING, iterationCount INTEGER, keyLength INTEGER OPTIONAL, prf DEFAULT sha1 } */
        p12_el salt, it, f;
        long iter = 0;
        int prf = P12_SHA1;
        if (!p12_child(&kdf, 1, &kdf_params) || kdf_params.tag != 0x30 || !p12_child(&kdf_params, 0, &salt) || salt.tag != 0x04 ||
            !p12_child(&kdf_params, 1, &it) || !p12_small_int(&it, &iter)) return P12_ERR_FORMAT;
        for (int i = 2; p12_child(&kdf_params, i, &f); i++) {
            long kl;
            if (f.tag == 0x02 && p12_small_int(&f, &kl)) { if ((size_t)kl != klen) return P12_ERR_FORMAT; }
            else if (f.tag == 0x30) {
                p12_el po;
                if (!p12_child(&f, 0, &po) || (prf = p12_hash_of(&po)) < 0) {
                    char o[64]; p12_oid_text(&po, o, sizeof(o));
                    snprintf(err, errlen, "PBKDF2 hash %s is not supported", o);
                    return P12_ERR_UNSUPPORTED;
                }
            }
        }
        uint8_t key[32];
        if (!p12_pbkdf2(prf, pw->utf8, pw->utf8_len, salt.val, salt.len, iter, key, klen)) return P12_ERR_FORMAT;
        bool ok = p12_cbc(cipher, key, klen, 0, iv.val, in, n, out);
        memset(key, 0, sizeof(key));
        return ok ? P12_OK : P12_ERR_PASSWORD;
    }

    char o[64];
    p12_oid_text(&oid, o, sizeof(o));
    snprintf(err, errlen, "encryption %s is not supported", o);
    return P12_ERR_UNSUPPORTED;
}

/* ------------------------------------------------------------------ bags */

static bool p12_add(p12_item *list, int *count, int max, const uint8_t *der, size_t len, const uint8_t *kid, size_t kid_len)
{
    if (*count >= max) return true;                           /* more than any developer .p12 holds: the rest is ignored */
    for (int i = 0; i < *count; i++) if (list[i].len == len && !memcmp(list[i].der, der, len)) return true;
    p12_item *it = &list[*count];
    memset(it, 0, sizeof(*it));
    it->der = (uint8_t *)malloc(len ? len : 1);
    if (!it->der) return false;
    memcpy(it->der, der, len);
    it->len = len;
    if (kid && kid_len <= sizeof(it->kid)) { memcpy(it->kid, kid, kid_len); it->kid_len = kid_len; }
    (*count)++;
    return true;
}

static int p12_safe_contents(const uint8_t *der, size_t n, const p12_pw *pw, p12_contents *out, char *err, size_t errlen, int depth)
{
    if (depth > 4) return P12_ERR_FORMAT;
    p12_el seq;
    if (!p12_parse(der, n, &seq) || seq.tag != 0x30) return P12_ERR_FORMAT;
    p12_el bag;
    for (int i = 0; p12_child(&seq, i, &bag); i++) {
        /* SafeBag ::= SEQUENCE { bagId OID, bagValue [0] EXPLICIT, bagAttributes SET OF Attribute OPTIONAL } */
        p12_el id, wrap, value, attrs;
        if (bag.tag != 0x30 || !p12_child(&bag, 0, &id) || !p12_child(&bag, 1, &wrap) || wrap.tag != 0xa0 || !p12_child(&wrap, 0, &value))
            return P12_ERR_FORMAT;
        const uint8_t *kid = NULL;
        size_t kid_len = 0;
        if (p12_child(&bag, 2, &attrs) && attrs.tag == 0x31) {
            p12_el a, aoid, aset, av;
            for (int k = 0; p12_child(&attrs, k, &a); k++)
                if (a.tag == 0x30 && p12_child(&a, 0, &aoid) && p12_is_oid(&aoid, P12_OID_LOCALKEYID, sizeof(P12_OID_LOCALKEYID)) &&
                    p12_child(&a, 1, &aset) && p12_child(&aset, 0, &av) && av.tag == 0x04) { kid = av.val; kid_len = av.len; }
        }
        int kind = p12_oid_last(&id, P12_OID_BAG, sizeof(P12_OID_BAG));
        if (kind == 1) {                                          /* keyBag: PrivateKeyInfo in the clear */
            if (!p12_add(out->keys, &out->nkeys, P12_MAX_KEYS, value.start, (size_t)(value.next - value.start), kid, kid_len))
                return P12_ERR_MEMORY;
        } else if (kind == 2) {                                   /* pkcs8ShroudedKeyBag: EncryptedPrivateKeyInfo */
            p12_el alg, data;
            if (value.tag != 0x30 || !p12_child(&value, 0, &alg) || alg.tag != 0x30 || !p12_child(&value, 1, &data)) return P12_ERR_FORMAT;
            p12_buf enc = { 0 }, plain = { 0 };
            if (!p12_octets(&data, &enc, 0)) { p12_buf_free(&enc); return P12_ERR_FORMAT; }
            int rc = p12_decrypt(&alg, enc.b, enc.n, pw, &plain, err, errlen);
            p12_buf_free(&enc);
            p12_el pki;
            if (rc == P12_OK && (!p12_parse(plain.b, plain.n, &pki) || pki.tag != 0x30)) rc = P12_ERR_PASSWORD;
            if (rc == P12_OK && !p12_add(out->keys, &out->nkeys, P12_MAX_KEYS, plain.b, (size_t)(pki.next - plain.b), kid, kid_len))
                rc = P12_ERR_MEMORY;
            p12_buf_free(&plain);
            if (rc != P12_OK) return rc;
        } else if (kind == 3) {                                   /* certBag: { certId, certValue [0] EXPLICIT OCTET STRING } */
            p12_el ctype, cwrap, cval;
            if (value.tag != 0x30 || !p12_child(&value, 0, &ctype)) return P12_ERR_FORMAT;
            if (!p12_is_oid(&ctype, P12_OID_X509, sizeof(P12_OID_X509))) continue;   /* an SDSI certificate: not ours */
            if (!p12_child(&value, 1, &cwrap) || cwrap.tag != 0xa0 || !p12_child(&cwrap, 0, &cval)) return P12_ERR_FORMAT;
            p12_buf c = { 0 };
            p12_el ce;
            if (!p12_octets(&cval, &c, 0) || !p12_parse(c.b, c.n, &ce) || ce.tag != 0x30) { p12_buf_free(&c); return P12_ERR_FORMAT; }
            bool ok = p12_add(out->certs, &out->ncerts, P12_MAX_CERTS, c.b, (size_t)(ce.next - c.b), kid, kid_len);
            p12_buf_free(&c);
            if (!ok) return P12_ERR_MEMORY;
        } else if (kind == 6) {                                   /* safeContentsBag: SafeContents again */
            int rc = p12_safe_contents(value.start, (size_t)(value.next - value.start), pw, out, err, errlen, depth + 1);
            if (rc != P12_OK) return rc;
        }
        /* crlBag, secretBag: nothing Husk needs */
    }
    return P12_OK;
}

/* AuthenticatedSafe ::= SEQUENCE OF ContentInfo (data or encryptedData). */
static int p12_auth_safe(const uint8_t *der, size_t n, const p12_pw *pw, p12_contents *out, char *err, size_t errlen)
{
    p12_el seq, ci;
    if (!p12_parse(der, n, &seq) || seq.tag != 0x30) return P12_ERR_FORMAT;
    for (int i = 0; p12_child(&seq, i, &ci); i++) {
        p12_el type, wrap, content;
        if (ci.tag != 0x30 || !p12_child(&ci, 0, &type)) return P12_ERR_FORMAT;
        if (!p12_child(&ci, 1, &wrap)) continue;                  /* no content */
        if (wrap.tag != 0xa0 || !p12_child(&wrap, 0, &content)) return P12_ERR_FORMAT;
        p12_buf safe = { 0 };
        int rc = P12_OK;
        if (p12_is_oid(&type, P12_OID_DATA, sizeof(P12_OID_DATA))) {
            if (!p12_octets(&content, &safe, 0)) rc = P12_ERR_FORMAT;
        } else if (p12_is_oid(&type, P12_OID_ENCDATA, sizeof(P12_OID_ENCDATA))) {
            /* EncryptedData ::= SEQUENCE { version, EncryptedContentInfo { contentType, algorithm, [0] IMPLICIT OCTET STRING } } */
            p12_el eci, alg, enc;
            if (content.tag != 0x30 || !p12_child(&content, 1, &eci) || eci.tag != 0x30 || !p12_child(&eci, 1, &alg) || alg.tag != 0x30)
                rc = P12_ERR_FORMAT;
            else if (p12_child(&eci, 2, &enc)) {
                if ((enc.tag & 0xdf) != 0x80) rc = P12_ERR_FORMAT;
                else {
                    p12_buf e = { 0 };
                    if (!p12_octets(&enc, &e, 0)) rc = P12_ERR_FORMAT;
                    else rc = p12_decrypt(&alg, e.b, e.n, pw, &safe, err, errlen);
                    p12_buf_free(&e);
                }
            }
        } else if (p12_is_oid(&type, P12_OID_ENVDATA, sizeof(P12_OID_ENVDATA))) {
            snprintf(err, errlen, "this .p12 is encrypted to a public key (envelopedData), not with a password");
            rc = P12_ERR_UNSUPPORTED;
        } else {
            continue;
        }
        if (rc == P12_OK && safe.n) rc = p12_safe_contents(safe.b, safe.n, pw, out, err, errlen, 0);
        p12_buf_free(&safe);
        if (rc != P12_OK) return rc;
    }
    return P12_OK;
}

/* ------------------------------------------------------------------ MAC */

/* 1 = the MAC matches this password, 0 = it does not, -1 = a MAC this reader does not know. */
static int p12_mac_verify(const p12_el *mac_data, const uint8_t *auth, size_t auth_len, const p12_pw *pw)
{
    /* MacData ::= SEQUENCE { mac DigestInfo, macSalt OCTET STRING, iterations INTEGER DEFAULT 1 } */
    p12_el di, alg, oid, digest, salt, it;
    long iter = 1;
    if (!p12_child(mac_data, 0, &di) || di.tag != 0x30 || !p12_child(&di, 0, &alg) || alg.tag != 0x30 ||
        !p12_child(&alg, 0, &oid) || !p12_child(&di, 1, &digest) || digest.tag != 0x04 ||
        !p12_child(mac_data, 1, &salt) || salt.tag != 0x04) return -1;
    if (p12_child(mac_data, 2, &it) && !p12_small_int(&it, &iter)) return -1;
    uint8_t key[64], got[64];
    if (p12_is_oid(&oid, P12_OID_PBMAC1, sizeof(P12_OID_PBMAC1))) {
        /* RFC 9579: PBMAC1-params { keyDerivationFunc PBKDF2, messageAuthScheme HMAC } -- the PBKDF2 salt, not macSalt */
        p12_el params, kdf, kdf_oid, kp, ks, ki, kl, mas, mas_oid, f;
        long k_iter = 0, k_len = 0;
        int prf = P12_SHA1, h;
        if (!p12_child(&alg, 1, &params) || !p12_child(&params, 0, &kdf) || !p12_child(&kdf, 0, &kdf_oid) ||
            !p12_is_oid(&kdf_oid, P12_OID_PBKDF2, sizeof(P12_OID_PBKDF2)) || !p12_child(&kdf, 1, &kp) ||
            !p12_child(&kp, 0, &ks) || ks.tag != 0x04 || !p12_child(&kp, 1, &ki) || !p12_small_int(&ki, &k_iter) ||
            !p12_child(&kp, 2, &kl) || !p12_small_int(&kl, &k_len) || k_len < 1 || k_len > 64 ||
            !p12_child(&params, 1, &mas) || !p12_child(&mas, 0, &mas_oid) || (h = p12_hash_of(&mas_oid)) < 0) return -1;
        if (p12_child(&kp, 3, &f) && f.tag == 0x30) {
            p12_el po;
            if (!p12_child(&f, 0, &po) || (prf = p12_hash_of(&po)) < 0) return -1;
        }
        if (digest.len != p12_hlen(h)) return -1;
        if (!p12_pbkdf2(prf, pw->utf8, pw->utf8_len, ks.val, ks.len, k_iter, key, (size_t)k_len)) return -1;
        p12_hmac(h, key, (size_t)k_len, auth, auth_len, got);
        return memcmp(got, digest.val, digest.len) == 0;
    }
    int h = p12_hash_of(&oid);
    if (h < 0 || digest.len != p12_hlen(h)) return -1;
    if (!p12_kdf(h, pw->bmp, pw->bmp_len, salt.val, salt.len, 3, iter, key, p12_hlen(h))) return -1;
    p12_hmac(h, key, p12_hlen(h), auth, auth_len, got);
    return memcmp(got, digest.val, digest.len) == 0;
}

/* ------------------------------------------------------------------ keys and certificates */

/* The public key of a certificate: SubjectPublicKeyInfo's algorithm and its BIT STRING contents (unused-bits byte off). */
static bool p12_cert_spki(const uint8_t *der, size_t n, p12_el *alg, const uint8_t **key, size_t *key_len)
{
    p12_el cert, tbs, f, bits;
    if (!p12_parse(der, n, &cert) || !p12_child(&cert, 0, &tbs)) return false;
    int i = 0;
    if (p12_child(&tbs, 0, &f) && f.tag == 0xa0) i = 1;           /* [0] version */
    if (!p12_child(&tbs, i + 5, &f) || f.tag != 0x30 || !p12_child(&f, 0, alg) || !p12_child(&f, 1, &bits) ||
        bits.tag != 0x03 || bits.len < 2 || bits.val[0] != 0) return false;
    *key = bits.val + 1; *key_len = bits.len - 1;
    return true;
}

/* The certificate's issuer and subject Names (whole elements). */
static bool p12_cert_names(const uint8_t *der, size_t n, p12_el *issuer, p12_el *subject)
{
    p12_el cert, tbs, f;
    if (!p12_parse(der, n, &cert) || !p12_child(&cert, 0, &tbs)) return false;
    int i = 0;
    if (p12_child(&tbs, 0, &f) && f.tag == 0xa0) i = 1;
    return p12_child(&tbs, i + 2, issuer) && p12_child(&tbs, i + 4, subject);
}

static bool p12_same_int(const uint8_t *a, size_t an, const uint8_t *b, size_t bn)
{
    while (an && !*a) { a++; an--; }
    while (bn && !*b) { b++; bn--; }
    return an == bn && !memcmp(a, b, an);
}

/* PrivateKeyInfo ::= SEQUENCE { version, AlgorithmIdentifier, privateKey OCTET STRING, ... } */
static bool p12_pki(const p12_item *k, p12_el *alg_oid, p12_el *alg_param, bool *has_param, p12_el *inner)
{
    p12_el pki, alg, ver, pk;
    if (!p12_parse(k->der, k->len, &pki) || pki.tag != 0x30 || !p12_child(&pki, 0, &ver) || ver.tag != 0x02 ||
        !p12_child(&pki, 1, &alg) || alg.tag != 0x30 || !p12_child(&alg, 0, alg_oid) || !p12_child(&pki, 2, &pk) || pk.tag != 0x04)
        return false;
    *has_param = p12_child(&alg, 1, alg_param);
    return p12_parse(pk.val, pk.len, inner) && inner->tag == 0x30;
}

/* Does key k belong to certificate c? Compared by RSA modulus, or by EC public point when the key carries one. */
static bool p12_key_fits(const p12_item *k, const p12_item *c)
{
    p12_el koid, kparam, inner, calg, coid;
    bool has_param;
    const uint8_t *pub; size_t pub_len;
    if (!p12_pki(k, &koid, &kparam, &has_param, &inner) || !p12_cert_spki(c->der, c->len, &calg, &pub, &pub_len) ||
        !p12_child(&calg, 0, &coid)) return false;
    if (p12_is_oid(&koid, P12_OID_RSA, sizeof(P12_OID_RSA))) {
        p12_el kmod, cpub, cmod;
        if (!p12_is_oid(&coid, P12_OID_RSA, sizeof(P12_OID_RSA)) || !p12_child(&inner, 1, &kmod) ||
            !p12_parse(pub, pub_len, &cpub) || !p12_child(&cpub, 0, &cmod)) return false;
        return p12_same_int(kmod.val, kmod.len, cmod.val, cmod.len);
    }
    if (p12_is_oid(&koid, P12_OID_EC, sizeof(P12_OID_EC)) && p12_is_oid(&coid, P12_OID_EC, sizeof(P12_OID_EC))) {
        p12_el f;
        for (int i = 2; p12_child(&inner, i, &f); i++)
            if (f.tag == 0xa1) {
                p12_el bits;
                if (p12_child(&f, 0, &bits) && bits.tag == 0x03 && bits.len >= 2)
                    return bits.len - 1 == pub_len && !memcmp(bits.val + 1, pub, pub_len);
            }
        return false;                                           /* no point in the key: undecided */
    }
    return false;
}

/* The developer certificate and its key. */
static void p12_pair(p12_contents *c)
{
    c->leaf = c->key = -1;
    for (int k = 0; k < c->nkeys && c->leaf < 0; k++)              /* by localKeyId */
        for (int i = 0; i < c->ncerts; i++)
            if (c->keys[k].kid_len && c->keys[k].kid_len == c->certs[i].kid_len && !memcmp(c->keys[k].kid, c->certs[i].kid, c->certs[i].kid_len)
                && p12_key_fits(&c->keys[k], &c->certs[i])) { c->key = k; c->leaf = i; break; }
    for (int k = 0; k < c->nkeys && c->leaf < 0; k++)              /* by public key */
        for (int i = 0; i < c->ncerts; i++)
            if (p12_key_fits(&c->keys[k], &c->certs[i])) { c->key = k; c->leaf = i; break; }
    for (int k = 0; k < c->nkeys && c->leaf < 0; k++)              /* by localKeyId alone (a key this reader cannot compare) */
        for (int i = 0; i < c->ncerts; i++)
            if (c->keys[k].kid_len && c->keys[k].kid_len == c->certs[i].kid_len && !memcmp(c->keys[k].kid, c->certs[i].kid, c->certs[i].kid_len))
                { c->key = k; c->leaf = i; break; }
    if (c->leaf < 0 && c->nkeys && c->ncerts) {                     /* the one certificate that issued none of the others */
        c->key = 0;
        for (int i = 0; i < c->ncerts && c->leaf < 0; i++) {
            p12_el is, su;
            if (!p12_cert_names(c->certs[i].der, c->certs[i].len, &is, &su)) continue;
            bool issuer_of_other = false;
            for (int j = 0; j < c->ncerts; j++) {
                p12_el is2, su2;
                if (j != i && p12_cert_names(c->certs[j].der, c->certs[j].len, &is2, &su2) &&
                    is2.next - is2.start == su.next - su.start && !memcmp(is2.start, su.start, (size_t)(su.next - su.start))) issuer_of_other = true;
            }
            if (!issuer_of_other) c->leaf = i;
        }
        if (c->leaf < 0) c->leaf = 0;
    }
}

static void p12_free(p12_contents *c)
{
    for (int i = 0; i < c->ncerts; i++) free(c->certs[i].der);
    for (int i = 0; i < c->nkeys; i++) { memset(c->keys[i].der, 0, c->keys[i].len); free(c->keys[i].der); }
    c->ncerts = c->nkeys = 0;
    c->leaf = c->key = -1;
}

/*
 * The key as SecKeyCreateWithData takes it: an RSA key as PKCS#1 RSAPrivateKey; an EC key as 04 || X || Y || D (the public
 * point from the key, or from the certificate when the key leaves it out). bits: the key size.
 */
static int p12_key_raw(const p12_contents *c, bool *is_rsa, int *bits, p12_buf *raw)
{
    if (c->key < 0) return P12_ERR_NOKEY;
    p12_el koid, kparam, inner;
    bool has_param;
    if (!p12_pki(&c->keys[c->key], &koid, &kparam, &has_param, &inner)) return P12_ERR_FORMAT;
    if (p12_is_oid(&koid, P12_OID_RSA, sizeof(P12_OID_RSA))) {
        p12_el mod;
        if (!p12_child(&inner, 1, &mod) || mod.tag != 0x02) return P12_ERR_FORMAT;
        const uint8_t *m = mod.val; size_t mn = mod.len;
        while (mn && !*m) { m++; mn--; }
        int b = (int)mn * 8;
        for (uint8_t top = mn ? m[0] : 0; b > 0 && !(top & 0x80); top <<= 1) b--;
        *is_rsa = true; *bits = b;
        return p12_buf_put(raw, inner.start, (size_t)(inner.next - inner.start)) ? P12_OK : P12_ERR_MEMORY;
    }
    if (p12_is_oid(&koid, P12_OID_EC, sizeof(P12_OID_EC))) {
        /* ECPrivateKey ::= SEQUENCE { version 1, privateKey OCTET STRING, [0] parameters OPTIONAL, [1] publicKey OPTIONAL } */
        p12_el d, f, curve = { 0 };
        bool have_curve = has_param && kparam.tag == 0x06;
        if (have_curve) curve = kparam;
        if (!p12_child(&inner, 1, &d) || d.tag != 0x04) return P12_ERR_FORMAT;
        const uint8_t *pub = NULL; size_t pub_len = 0;
        for (int i = 2; p12_child(&inner, i, &f); i++) {
            p12_el x;
            if (f.tag == 0xa0 && p12_child(&f, 0, &x) && x.tag == 0x06) { curve = x; have_curve = true; }
            if (f.tag == 0xa1 && p12_child(&f, 0, &x) && x.tag == 0x03 && x.len >= 2) { pub = x.val + 1; pub_len = x.len - 1; }
        }
        if (!pub && c->leaf >= 0) {
            p12_el calg;
            if (!p12_cert_spki(c->certs[c->leaf].der, c->certs[c->leaf].len, &calg, &pub, &pub_len)) pub = NULL;
        }
        size_t field;
        if (have_curve && p12_is_oid(&curve, P12_OID_P256, sizeof(P12_OID_P256))) field = 32;
        else if (have_curve && p12_is_oid(&curve, P12_OID_P384, sizeof(P12_OID_P384))) field = 48;
        else if (have_curve && p12_is_oid(&curve, P12_OID_P521, sizeof(P12_OID_P521))) field = 66;
        else return P12_ERR_UNSUPPORTED;
        if (!pub || pub_len != 1 + 2 * field || pub[0] != 0x04) return P12_ERR_FORMAT;
        const uint8_t *dv = d.val; size_t dn = d.len;
        while (dn > field && !*dv) { dv++; dn--; }
        if (dn > field) return P12_ERR_FORMAT;
        uint8_t zeros[66] = { 0 };
        if (!p12_buf_put(raw, pub, pub_len) || !p12_buf_put(raw, zeros, field - dn) || !p12_buf_put(raw, dv, dn)) return P12_ERR_MEMORY;
        *is_rsa = false; *bits = field == 66 ? 521 : (int)field * 8;
        return P12_OK;
    }
    return P12_ERR_UNSUPPORTED;
}

/* ------------------------------------------------------------------ the whole file */

static int p12_decode_with(const uint8_t *auth, size_t auth_len, const p12_pw *pw, p12_contents *out, char *err, size_t errlen)
{
    p12_free(out);
    return p12_auth_safe(auth, auth_len, pw, out, err, errlen);
}

/*
 * Opens a .p12. password: what the person typed or the store sent (NULL or "" for none). Tries it as given, then as "", then
 * as no password -- with a MAC, the MAC says which one is right before anything is decrypted. err gets a sentence on failure.
 */
static int p12_decode(const uint8_t *der, size_t len, const char *password, p12_contents *out, char *err, size_t errlen)
{
    memset(out, 0, sizeof(*out));
    out->leaf = out->key = -1;
    if (err && errlen) err[0] = 0;
    char scratch[160];
    if (!err || !errlen) { err = scratch; errlen = sizeof(scratch); }

    /* PFX ::= SEQUENCE { version INTEGER (3), authSafe ContentInfo, macData MacData OPTIONAL } */
    p12_el pfx, ver, auth_ci, auth_type, auth_wrap, auth_content, mac;
    long version = 0;
    if (!der || len < 16 || !p12_parse(der, len, &pfx) || pfx.tag != 0x30 || !p12_child(&pfx, 0, &ver) ||
        !p12_small_int(&ver, &version) || !p12_child(&pfx, 1, &auth_ci) || auth_ci.tag != 0x30 ||
        !p12_child(&auth_ci, 0, &auth_type) || auth_type.tag != 0x06) {
        snprintf(err, errlen, "this file is not a .p12 certificate");
        return P12_ERR_FORMAT;
    }
    if (version != 3) { snprintf(err, errlen, "this .p12 is version %ld; only version 3 exists", version); return P12_ERR_FORMAT; }
    if (!p12_is_oid(&auth_type, P12_OID_DATA, sizeof(P12_OID_DATA))) {
        snprintf(err, errlen, "this .p12 is protected with a public key, not a password");
        return P12_ERR_UNSUPPORTED;
    }
    p12_buf auth = { 0 };
    if (!p12_child(&auth_ci, 1, &auth_wrap) || auth_wrap.tag != 0xa0 || !p12_child(&auth_wrap, 0, &auth_content) ||
        !p12_octets(&auth_content, &auth, 0)) {
        p12_buf_free(&auth);
        snprintf(err, errlen, "this .p12 is damaged (no contents)");
        return P12_ERR_FORMAT;
    }
    bool has_mac = p12_child(&pfx, 2, &mac) && mac.tag == 0x30;
    out->had_mac = has_mac;

    const char *given = password ? password : "";
    p12_pw forms[3];
    int nforms = 0;
    int form_id[3];
    if (given[0]) { if (!p12_pw_make(&forms[nforms], given, false)) goto oom; form_id[nforms++] = 0; }
    if (!p12_pw_make(&forms[nforms], "", false)) goto oom;
    form_id[nforms++] = 1;
    if (!p12_pw_make(&forms[nforms], "", true)) goto oom;
    form_id[nforms++] = 2;

    int rc = P12_ERR_PASSWORD, chosen = -1;
    bool mac_unknown = false;
    if (has_mac) {
        for (int i = 0; i < nforms && chosen < 0; i++) {
            int m = p12_mac_verify(&mac, auth.b, auth.n, &forms[i]);
            if (m == 1) chosen = i;
            else if (m < 0) { mac_unknown = true; break; }
        }
        if (chosen < 0 && !mac_unknown) {
            snprintf(err, errlen, given[0] ? "the password does not open this .p12" : "this .p12 needs a password");
            rc = P12_ERR_PASSWORD;
            goto done;
        }
    }
    if (chosen >= 0) {
        rc = p12_decode_with(auth.b, auth.n, &forms[chosen], out, err, errlen);
        /* The MAC and the contents normally share a password; when they do not, try the others for the contents. */
        for (int i = 0; rc == P12_ERR_PASSWORD && i < nforms; i++)
            if (i != chosen && (rc = p12_decode_with(auth.b, auth.n, &forms[i], out, err, errlen)) == P12_OK) chosen = i;
    } else {
        /* No MAC (or one this reader does not know): the password that decrypts is the right one. */
        for (int i = 0; i < nforms; i++) {
            rc = p12_decode_with(auth.b, auth.n, &forms[i], out, err, errlen);
            if (rc == P12_OK) { chosen = i; break; }
            if (rc != P12_ERR_PASSWORD) break;
        }
    }
    if (rc == P12_ERR_PASSWORD) snprintf(err, errlen, given[0] ? "the password does not open this .p12" : "this .p12 needs a password");
    if (rc != P12_OK) goto done;
    out->password_form = form_id[chosen];
    p12_pair(out);
    if (!out->nkeys) {
        rc = P12_ERR_NOKEY;
        snprintf(err, errlen, out->ncerts ? "this .p12 has the certificate but not its private key" : "this .p12 is empty");
    } else if (!out->ncerts) {
        rc = P12_ERR_NOCERT;
        snprintf(err, errlen, "this .p12 has a private key but no certificate");
    }

done:
    for (int i = 0; i < nforms; i++) p12_pw_free(&forms[i]);
    p12_buf_free(&auth);
    if (rc != P12_OK) p12_free(out);
    return rc;
oom:
    for (int i = 0; i < nforms; i++) p12_pw_free(&forms[i]);
    p12_buf_free(&auth);
    snprintf(err, errlen, "out of memory");
    return P12_ERR_MEMORY;
}
