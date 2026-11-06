/* SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once
#include <openssl/hmac.h>
#include <openssl/evp.h>
typedef int CCHmacAlgorithm;
enum { kCCHmacAlgSHA1, kCCHmacAlgMD5, kCCHmacAlgSHA256, kCCHmacAlgSHA384, kCCHmacAlgSHA512, kCCHmacAlgSHA224 };
static inline void CCHmac(CCHmacAlgorithm a, const void *key, size_t klen, const void *d, size_t n, void *out)
{
    const EVP_MD *md = a == kCCHmacAlgSHA1 ? EVP_sha1() : a == kCCHmacAlgSHA224 ? EVP_sha224() : a == kCCHmacAlgSHA256 ? EVP_sha256()
                     : a == kCCHmacAlgSHA384 ? EVP_sha384() : EVP_sha512();
    unsigned int len = 0;
    HMAC(md, key, (int)klen, (const unsigned char *)d, n, (unsigned char *)out, &len);
}
