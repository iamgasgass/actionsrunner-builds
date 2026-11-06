/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Linux stand-in for Apple's CommonCrypto, over OpenSSL: only what tools/p12-test.c needs. */
#pragma once
#include <openssl/sha.h>
typedef unsigned int CC_LONG;
#define CC_SHA1(d, n, o)   SHA1((const unsigned char *)(d), (n), (o))
#define CC_SHA224(d, n, o) SHA224((const unsigned char *)(d), (n), (o))
#define CC_SHA256(d, n, o) SHA256((const unsigned char *)(d), (n), (o))
#define CC_SHA384(d, n, o) SHA384((const unsigned char *)(d), (n), (o))
#define CC_SHA512(d, n, o) SHA512((const unsigned char *)(d), (n), (o))
