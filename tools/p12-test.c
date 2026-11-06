/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * p12-test: Husk's PKCS#12 reader (src/translation-layer-next/husk-tl-pkcs12.inc) on its own, for Linux or macOS.
 *
 *   p12-test --rc2                         RFC 2268 test vectors
 *   p12-test <file.p12> <password> [key.der] [cert.der]
 *       prints the status, what was found and which password form opened it; writes the key as SecKeyCreateWithData takes
 *       it (PKCS#1 for RSA, 04|X|Y|D for EC) and the developer certificate, for comparing with `openssl pkcs12` output.
 *
 * Linux: cc -I tools/p12-test-shim -o /tmp/p12-test tools/p12-test.c -lcrypto
 * macOS: cc -o /tmp/p12-test tools/p12-test.c
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../src/translation-layer-next/husk-tl-pkcs12.inc"

static int rc2_vectors(void)
{
    static const struct { uint8_t key[16]; size_t klen; unsigned bits; uint8_t pt[8], ct[8]; } v[] = {
        { { 0 }, 8, 63, { 0 }, { 0xeb, 0xb7, 0x73, 0xf9, 0x93, 0x27, 0x8e, 0xff } },
        { { 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, 8, 64, { 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff },
          { 0x27, 0x8b, 0x27, 0xe4, 0x2e, 0x2f, 0x0d, 0x49 } },
        { { 0x30 }, 8, 64, { 0x10, 0, 0, 0, 0, 0, 0, 0x01 }, { 0x30, 0x64, 0x9e, 0xdf, 0x9b, 0xe7, 0xd2, 0xc2 } },
        { { 0x88 }, 1, 64, { 0 }, { 0x61, 0xa8, 0xa2, 0x44, 0xad, 0xac, 0xcc, 0xf0 } },
        { { 0x88, 0xbc, 0xa9, 0x0e, 0x90, 0x87, 0x5a }, 7, 64, { 0 }, { 0x6c, 0xcf, 0x43, 0x08, 0x97, 0x4c, 0x26, 0x7f } },
        { { 0x88, 0xbc, 0xa9, 0x0e, 0x90, 0x87, 0x5a, 0x7f, 0x0f, 0x79, 0xc3, 0x84, 0x62, 0x7b, 0xaf, 0xb2 }, 16, 64, { 0 },
          { 0x1a, 0x80, 0x7d, 0x27, 0x2b, 0xbe, 0x5d, 0xb1 } },
        { { 0x88, 0xbc, 0xa9, 0x0e, 0x90, 0x87, 0x5a, 0x7f, 0x0f, 0x79, 0xc3, 0x84, 0x62, 0x7b, 0xaf, 0xb2 }, 16, 128, { 0 },
          { 0x22, 0x69, 0x55, 0x2a, 0xb0, 0xf8, 0x5c, 0xa6 } },
    };
    bool seen[256] = { false };
    for (int i = 0; i < 256; i++) {
        if (seen[p12_rc2_pi[i]]) { printf("rc2: PITABLE is not a permutation\n"); return 1; }
        seen[p12_rc2_pi[i]] = true;
    }
    int bad = 0;
    for (size_t i = 0; i < sizeof(v) / sizeof(v[0]); i++) {
        uint16_t K[64];
        uint8_t b[8];
        memcpy(b, v[i].ct, 8);
        p12_rc2_schedule(K, v[i].key, v[i].klen, v[i].bits);
        p12_rc2_decrypt_block(K, b);
        bool ok = !memcmp(b, v[i].pt, 8);
        printf("rc2 vector %zu: %s\n", i, ok ? "ok" : "WRONG");
        bad += !ok;
    }
    return bad != 0;
}

static void write_file(const char *path, const uint8_t *b, size_t n)
{
    FILE *f = fopen(path, "wb");
    if (!f) { perror(path); return; }
    fwrite(b, 1, n, f);
    fclose(f);
}

int main(int argc, char **argv)
{
    if (argc >= 2 && !strcmp(argv[1], "--rc2")) return rc2_vectors();
    if (argc < 3) { fprintf(stderr, "usage: %s --rc2 | <p12> <password> [key.der] [cert.der]\n", argv[0]); return 2; }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 2; }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *d = malloc((size_t)n + 1);
    if (!d || fread(d, 1, (size_t)n, f) != (size_t)n) { fclose(f); return 2; }
    fclose(f);

    p12_contents c;
    char err[200];
    int rc = p12_decode(d, (size_t)n, argv[2], &c, err, sizeof(err));
    printf("status %d", rc);
    if (rc != P12_OK) { printf(" (%s)\n", err); free(d); return 10 + rc; }
    if (getenv("P12_NO_KEYID")) {          /* pairing without localKeyId, with the developer certificate last */
        for (int i = 0; i < c.ncerts; i++) c.certs[i].kid_len = 0;
        for (int i = 0; i < c.nkeys; i++) c.keys[i].kid_len = 0;
        for (int i = 0, j = c.ncerts - 1; i < j; i++, j--) { p12_item t = c.certs[i]; c.certs[i] = c.certs[j]; c.certs[j] = t; }
        p12_pair(&c);
    }
    static const char *form[] = { "as given", "empty", "none" };
    printf(" certs %d keys %d leaf %d key %d password %s mac %s", c.ncerts, c.nkeys, c.leaf, c.key, form[c.password_form],
           c.had_mac ? "yes" : "no");
    bool rsa = false;
    int bits = 0;
    p12_buf raw = { 0 };
    int krc = p12_key_raw(&c, &rsa, &bits, &raw);
    printf(" keyraw %d %s %d\n", krc, rsa ? "rsa" : "ec", bits);
    if (argc > 3 && krc == P12_OK) write_file(argv[3], raw.b, raw.n);
    if (argc > 4 && c.leaf >= 0) write_file(argv[4], c.certs[c.leaf].der, c.certs[c.leaf].len);
    p12_buf_free(&raw);
    p12_free(&c);
    free(d);
    return krc == P12_OK ? 0 : 20 + krc;
}
