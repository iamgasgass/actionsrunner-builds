/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * codesign-test: Husk's dylib signer (src/translation-layer-next/husk-tl-codesign.c) on Linux, over OpenSSL, so what it writes
 * can be checked with tools/codesign-verify.py (CodeDirectory, page hashes, the CMS signature against the certificate).
 *
 *   codesign-test <file.dylib> <file.p12> <password> [ident] [app-executable]
 *       signs the dylib in place, as Husk does on the device; an app-executable is read for its certificate chain first, and
 *       whether the .p12 holds the certificate it was signed with is printed (husk_p12_matches_app)
 *
 * cc -I tools/codesign-test-shim -o /tmp/codesign-test tools/codesign-test.c -lcrypto -lpthread
 */
#define _GNU_SOURCE
#include <stdarg.h>
#include <stdio.h>
#include <openssl/evp.h>
#include <openssl/rsa.h>
#include <openssl/ec.h>
#include <openssl/x509.h>
#include <openssl/obj_mac.h>
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"

void tl_log_line(const char *fmt, ...)
{
    va_list ap; va_start(ap, fmt); vfprintf(stderr, fmt, ap); va_end(ap); fputc('\n', stderr);
}

#include "../src/translation-layer-next/husk-tl-codesign.c"

/* ------------------------------------------------------------------ the CoreFoundation and Security the signer uses */
enum { T_DATA = 1, T_ARRAY, T_STRING, T_DICT, T_NUMBER, T_KEY, T_CERT, T_ERROR };
struct cf_obj { int type, refs; uint8_t *b; size_t n; const void **items; size_t count; const void **keys; EVP_PKEY *pkey; long code; };

static struct cf_obj *cf_new(int type) { struct cf_obj *o = calloc(1, sizeof(*o)); o->type = type; o->refs = 1; return o; }
const CFDictionaryKeyCallBacks kCFTypeDictionaryKeyCallBacks;
const CFDictionaryValueCallBacks kCFTypeDictionaryValueCallBacks;
const CFArrayCallBacks kCFTypeArrayCallBacks;
CFAllocatorRef kCFAllocatorDefault, kCFAllocatorNull;
CFTypeRef kCFNull;

CFTypeRef CFRetain(CFTypeRef t) { if (t) ((struct cf_obj *)t)->refs++; return t; }
void CFRelease(CFTypeRef t)
{
    struct cf_obj *o = (struct cf_obj *)t;
    if (!o || o->refs < 0 || --o->refs) return;
    if (o->type == T_ARRAY || o->type == T_DICT) for (size_t i = 0; i < o->count; i++) CFRelease(o->items[i]);
    if (o->pkey) EVP_PKEY_free(o->pkey);
    free(o->b); free(o->items); free(o->keys); free(o);
}
static struct cf_obj *data_new(const uint8_t *p, size_t n) { struct cf_obj *o = cf_new(T_DATA); o->b = malloc(n ? n : 1); memcpy(o->b, p, n); o->n = n; return o; }
CFDataRef CFDataCreate(CFAllocatorRef a, const uint8_t *p, CFIndex n) { (void)a; return data_new(p, (size_t)n); }
CFDataRef CFDataCreateWithBytesNoCopy(CFAllocatorRef a, const uint8_t *p, CFIndex n, CFAllocatorRef d) { (void)d; return CFDataCreate(a, p, n); }
const uint8_t *CFDataGetBytePtr(CFDataRef d) { return d->b; }
CFIndex CFDataGetLength(CFDataRef d) { return (CFIndex)d->n; }
CFIndex CFArrayGetCount(CFArrayRef a) { return (CFIndex)a->count; }
const void *CFArrayGetValueAtIndex(CFArrayRef a, CFIndex i) { return a->items[i]; }
CFMutableArrayRef CFArrayCreateMutable(CFAllocatorRef a, CFIndex c, const CFArrayCallBacks *cb) { (void)a; (void)c; (void)cb; return cf_new(T_ARRAY); }
void CFArrayAppendValue(CFMutableArrayRef a, const void *v)
{
    a->items = realloc(a->items, (a->count + 1) * sizeof(void *)); a->items[a->count++] = CFRetain(v);
}
void CFArrayAppendArray(CFMutableArrayRef a, CFArrayRef b, CFRange r) { for (CFIndex i = r.location; i < r.location + r.length; i++) CFArrayAppendValue(a, b->items[i]); }
CFStringRef CFStringCreateWithCString(CFAllocatorRef a, const char *s, CFStringEncoding e)
{
    (void)a; (void)e; struct cf_obj *o = data_new((const uint8_t *)s, strlen(s) + 1); o->type = T_STRING; return o;
}
CFStringRef cf_const_string(const char *s)
{
    static struct { const char *s; struct cf_obj *o; } tab[64]; static int n;
    for (int i = 0; i < n; i++) if (!strcmp(tab[i].s, s)) return tab[i].o;
    struct cf_obj *o = (struct cf_obj *)CFStringCreateWithCString(NULL, s, 0); o->refs = -1;
    tab[n].s = s; tab[n].o = o; n++;
    return o;
}
CFNumberRef CFNumberCreate(CFAllocatorRef a, int t, const void *v) { (void)a; (void)t; struct cf_obj *o = cf_new(T_NUMBER); o->code = *(const int *)v; return o; }
CFDictionaryRef CFDictionaryCreate(CFAllocatorRef a, const void **k, const void **v, CFIndex n, const CFDictionaryKeyCallBacks *kc,
                                   const CFDictionaryValueCallBacks *vc)
{
    (void)a; (void)kc; (void)vc;
    struct cf_obj *o = cf_new(T_DICT);
    o->keys = calloc((size_t)n + 1, sizeof(void *)); o->items = calloc((size_t)n + 1, sizeof(void *)); o->count = (size_t)n;
    for (CFIndex i = 0; i < n; i++) { o->keys[i] = k[i]; o->items[i] = CFRetain(v[i]); }
    return o;
}
const void *CFDictionaryGetValue(CFDictionaryRef d, const void *k) { for (size_t i = 0; i < d->count; i++) if (d->keys[i] == k) return d->items[i]; return NULL; }
CFIndex CFErrorGetCode(CFErrorRef e) { return e->code; }

#define KEYNAME(x) CFStringRef x;
KEYNAME(kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA256) KEYNAME(kSecKeyAlgorithmECDSASignatureDigestX962SHA256)
KEYNAME(kSecAttrKeyType) KEYNAME(kSecAttrKeyClass) KEYNAME(kSecAttrKeySizeInBits) KEYNAME(kSecAttrKeyTypeRSA)
KEYNAME(kSecAttrKeyTypeECSECPrimeRandom) KEYNAME(kSecAttrKeyClassPrivate) KEYNAME(kSecImportItemIdentity)
KEYNAME(kSecImportItemCertChain) KEYNAME(kSecImportExportPassphrase)
__attribute__((constructor)) static void sec_names(void)
{
#define SET(x) x = cf_const_string(#x);
    SET(kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA256) SET(kSecKeyAlgorithmECDSASignatureDigestX962SHA256)
    SET(kSecAttrKeyType) SET(kSecAttrKeyClass) SET(kSecAttrKeySizeInBits) SET(kSecAttrKeyTypeRSA)
    SET(kSecAttrKeyTypeECSECPrimeRandom) SET(kSecAttrKeyClassPrivate) SET(kSecImportItemIdentity)
    SET(kSecImportItemCertChain) SET(kSecImportExportPassphrase)
}

static CFErrorRef err_new(long code) { struct cf_obj *o = cf_new(T_ERROR); o->code = code; return o; }

SecKeyRef SecKeyCreateWithData(CFDataRef d, CFDictionaryRef attrs, CFErrorRef *e)
{
    EVP_PKEY *pk = NULL;
    if (CFDictionaryGetValue(attrs, kSecAttrKeyType) == kSecAttrKeyTypeRSA) {
        const uint8_t *p = d->b;
        RSA *r = d2i_RSAPrivateKey(NULL, &p, (long)d->n);
        if (r && p == d->b + d->n) { pk = EVP_PKEY_new(); EVP_PKEY_assign_RSA(pk, r); } else if (r) RSA_free(r);
    } else if (d->n == 97) {                                        /* P-256: 04 | X | Y | D, as iOS takes it */
        EC_KEY *k = EC_KEY_new_by_curve_name(NID_X9_62_prime256v1);
        BIGNUM *dn = BN_bin2bn(d->b + 65, 32, NULL);
        if (k && dn && EC_KEY_oct2key(k, d->b, 65, NULL) && EC_KEY_set_private_key(k, dn)) { pk = EVP_PKEY_new(); EVP_PKEY_assign_EC_KEY(pk, k); k = NULL; }
        if (k) EC_KEY_free(k);
        BN_free(dn);
    }
    if (!pk) { if (e) *e = err_new(-50); return NULL; }
    struct cf_obj *o = cf_new(T_KEY); o->pkey = pk; return o;
}
CFDataRef SecKeyCreateSignature(SecKeyRef k, CFStringRef alg, CFDataRef digest, CFErrorRef *e)
{
    EVP_PKEY_CTX *c = EVP_PKEY_CTX_new(k->pkey, NULL);
    size_t n = 0; uint8_t *sig = NULL; bool ok = c && EVP_PKEY_sign_init(c) > 0;
    if (ok && alg == kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA256)
        ok = EVP_PKEY_CTX_set_rsa_padding(c, RSA_PKCS1_PADDING) > 0 && EVP_PKEY_CTX_set_signature_md(c, EVP_sha256()) > 0;
    ok = ok && EVP_PKEY_sign(c, NULL, &n, digest->b, digest->n) > 0 && (sig = malloc(n)) && EVP_PKEY_sign(c, sig, &n, digest->b, digest->n) > 0;
    EVP_PKEY_CTX_free(c);
    if (!ok) { free(sig); if (e) *e = err_new(-1); return NULL; }
    CFDataRef r = CFDataCreate(NULL, sig, (CFIndex)n); free(sig); return r;
}
bool SecKeyVerifySignature(SecKeyRef k, CFStringRef alg, CFDataRef digest, CFDataRef sig, CFErrorRef *e)
{
    EVP_PKEY_CTX *c = EVP_PKEY_CTX_new(k->pkey, NULL);
    bool ok = c && EVP_PKEY_verify_init(c) > 0;
    if (ok && alg == kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA256)
        ok = EVP_PKEY_CTX_set_rsa_padding(c, RSA_PKCS1_PADDING) > 0 && EVP_PKEY_CTX_set_signature_md(c, EVP_sha256()) > 0;
    ok = ok && EVP_PKEY_verify(c, sig->b, sig->n, digest->b, digest->n) == 1;
    EVP_PKEY_CTX_free(c);
    if (!ok && e) *e = err_new(-67808);
    return ok;
}
SecCertificateRef SecCertificateCreateWithData(CFAllocatorRef a, CFDataRef d)
{
    (void)a; const uint8_t *p = d->b; X509 *x = d2i_X509(NULL, &p, (long)d->n);
    if (!x) return NULL;
    X509_free(x);
    struct cf_obj *o = data_new(d->b, d->n); o->type = T_CERT; return o;
}
CFDataRef SecCertificateCopyData(SecCertificateRef c) { return CFDataCreate(NULL, c->b, (CFIndex)c->n); }
SecKeyRef SecCertificateCopyKey(SecCertificateRef c)
{
    const uint8_t *p = c->b; X509 *x = d2i_X509(NULL, &p, (long)c->n);
    EVP_PKEY *pk = x ? X509_get_pubkey(x) : NULL;
    X509_free(x);
    if (!pk) return NULL;
    struct cf_obj *o = cf_new(T_KEY); o->pkey = pk; return o;
}
OSStatus SecPKCS12Import(CFDataRef d, CFDictionaryRef o, CFArrayRef *items) { (void)d; (void)o; *items = NULL; return -26275; }
OSStatus SecIdentityCopyCertificate(SecIdentityRef i, SecCertificateRef *c) { (void)i; *c = NULL; return -50; }
OSStatus SecIdentityCopyPrivateKey(SecIdentityRef i, SecKeyRef *k) { (void)i; *k = NULL; return -50; }

/* ------------------------------------------------------------------ */
int main(int argc, char **argv)
{
    if (argc < 4) { fprintf(stderr, "usage: %s <file.dylib> <file.p12> <password> [ident] [app-executable]\n", argv[0]); return 2; }
    FILE *f = fopen(argv[2], "rb");
    if (!f) { perror(argv[2]); return 2; }
    static uint8_t p12[1 << 20]; size_t n = fread(p12, 1, sizeof(p12), f); fclose(f);
    if (argc > 5) printf("same certificate as %s: %d\n", argv[5], husk_p12_matches_app(p12, n, argv[3], argv[5]));
    char err[300] = "";
    bool ok = husk_codesign_dylib(argv[1], p12, n, argv[3], argc > 4 && argv[4][0] ? argv[4] : NULL, err, sizeof(err));
    printf("%s%s%s\n", ok ? "signed" : "FAILED", err[0] ? ": " : "", err);
    return ok ? 0 : 1;
}
