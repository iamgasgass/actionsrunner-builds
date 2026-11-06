/* SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once
#include <openssl/evp.h>
#include <stddef.h>
typedef int CCCryptorStatus;
enum { kCCSuccess = 0, kCCDecodeError = -4304 };
enum { kCCEncrypt = 0, kCCDecrypt = 1 };
enum { kCCAlgorithmAES = 0, kCCAlgorithmDES = 1, kCCAlgorithm3DES = 2 };
static inline CCCryptorStatus CCCrypt(int op, int alg, int options, const void *key, size_t klen, const void *iv,
                                      const void *in, size_t n, void *out, size_t outcap, size_t *moved)
{
    (void)options; (void)outcap;
    const EVP_CIPHER *c = alg == kCCAlgorithm3DES ? EVP_des_ede3_cbc()
                        : klen == 16 ? EVP_aes_128_cbc() : klen == 24 ? EVP_aes_192_cbc() : EVP_aes_256_cbc();
    EVP_CIPHER_CTX *x = EVP_CIPHER_CTX_new();
    int a = 0, b = 0, ok = EVP_CipherInit_ex(x, c, NULL, key, iv, op == kCCEncrypt);
    EVP_CIPHER_CTX_set_padding(x, 0);
    ok = ok && EVP_CipherUpdate(x, out, &a, in, (int)n) && EVP_CipherFinal_ex(x, (unsigned char *)out + a, &b);
    EVP_CIPHER_CTX_free(x);
    *moved = (size_t)(a + b);
    return ok ? kCCSuccess : kCCDecodeError;
}
