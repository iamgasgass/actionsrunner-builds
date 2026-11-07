/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef HUSK_TL_CODESIGN_H
#define HUSK_TL_CODESIGN_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Reads Apple Developer certificate metadata from a PKCS#12 (.p12) bundle.
 *
 * Parameters:
 *   p12              - Pointer to .p12 bundle file contents in memory.
 *   p12_len          - Length of p12 data in bytes.
 *   password         - Passphrase for the .p12 bundle (may be empty string "" if none).
 *   team_id          - Output buffer for the 10-character Apple Developer Team ID
 *                      (extracted from Subject Organizational Unit 'OU', or Subject CN).
 *   team_id_len      - Size of team_id output buffer in bytes (at least 32 recommended).
 *   not_after_epoch  - Output pointer receiving certificate expiration date in seconds
 *                      since Unix epoch (UTC).
 *   err              - Output buffer for human-readable error description on failure.
 *   errlen           - Size of err buffer in bytes.
 *
 * Returns true on success, false on failure (with error in err).
 */
bool husk_p12_info(const uint8_t *p12, size_t p12_len, const char *password,
                   char *team_id, size_t team_id_len,
                   double *not_after_epoch,
                   char *err, size_t errlen);

/*
 * What husk_p12_check found. The .p12 is read by Husk's own PKCS#12 reader first (legacy 3DES/RC2 files, OpenSSL 3's
 * AES-256 + SHA-256 MAC files, files with no password or no MAC), then by SecPKCS12Import.
 */
enum {
    HUSK_P12_OK = 0,
    HUSK_P12_BAD_PASSWORD = 1,  /* no form of the password opens it (as given, "", none) */
    HUSK_P12_NOT_P12 = 2,       /* not a PKCS#12 file, or a damaged one */
    HUSK_P12_UNSUPPORTED = 3,   /* an encryption or key type that cannot be used here (err says which) */
    HUSK_P12_NO_KEY = 4,        /* the certificate without its private key */
    HUSK_P12_NO_CERT = 5,       /* a private key without its certificate */
    HUSK_P12_NOT_APPLE = 7,     /* opens, but the certificate names no Apple team */
};

/* husk_p12_info with the reason: one of HUSK_P12_*, err a sentence for the person. */
int husk_p12_check(const uint8_t *p12, size_t p12_len, const char *password,
                   char *team_id, size_t team_id_len, double *not_after_epoch, char *err, size_t errlen);

/*
 * Signs an arm64 Mach-O dylib in-place on-device using Apple Security.framework and CommonCrypto.
 *
 * Works on iOS 15.5+ and macOS. No OpenSSL or AGPL dependencies.
 *
 * If p12 is non-NULL and p12_len > 0:
 *   Signs with the developer certificate and private key from the .p12 bundle.
 *   Generates a fully conformant Apple Embedded Signature SuperBlob containing:
 *     1. CodeDirectory v=0x20400 (SHA-256 code slots per 16 KiB page, Team ID, execSeg limits).
 *     2. Requirements blob (matching the dylib identifier).
 *     3. CMS SignedData (BlobWrapper 0xfade0b01) containing leaf + CA certificates,
 *        signedAttrs (contentType, signingTime, messageDigest, and Apple cdhashes plist),
 *        and cryptographic signature generated via SecKeyCreateSignature().
 *   The resulting dylib satisfies Apple's Library Validation on iOS 15 through iOS 26+
 *   when dlopen()ed by an app signed with the same Team ID.
 *
 * If p12 is NULL or p12_len is 0:
 *   Signs with a valid ad-hoc signature (CodeDirectory with CS_ADHOC flag set and Requirements).
 *   Useful for local developer testing on macOS.
 *
 * Parameters:
 *   path             - Path to the Mach-O dylib file to sign in-place.
 *   p12              - Pointer to .p12 bundle data (or NULL for ad-hoc).
 *   p12_len          - Length of .p12 bundle data (or 0 for ad-hoc).
 *   password         - Passphrase for the .p12 bundle.
 *   ident            - CodeDirectory identifier and designated-requirement ident. On iOS this must be the running app's
 *                      bundle ID (SideStore/AltStore rewrite it, TrollStore/enterprise may not). NULL uses the dylib's
 *                      install-name basename (Mac tests). LC_ID_DYLIB is left unique for dyld.
 *   err              - Output buffer for error description on failure.
 *   errlen           - Size of err buffer in bytes.
 *
 * Returns true on success, false on failure (with error in err).
 */
/* Bumped whenever what husk_codesign_dylib writes changes in a way that matters to iOS: dylibs stamped with another are signed again. */
#define HUSK_CODESIGN_FORMAT "cs4-sha1+sha256-4k-storecerts"

bool husk_codesign_dylib(const char *path, const uint8_t *p12, size_t p12_len, const char *password,
                         const char *ident, char *err, size_t errlen);

/*
 * Take the certificates from the code signature of the executable at `path` (the app itself: its installer signed it with the
 * developer certificate and the chain above it) and carry them in every signature made after this, beside the developer
 * certificate, so iOS can trust it when the .p12 holds the developer certificate alone. Returns how many were found.
 */
int husk_codesign_chain_from_executable(const char *path);

/*
 * The signing identifier in the code signature of the executable at `exe` (the app itself, as its store signed it). Under a
 * container such as LiveContainer this is the host's identifier (e.g. com.kdt.livecontainer.TEAMID), which differs from
 * Bundle.main.bundleIdentifier, and iOS's library validation wants the libraries Husk signs to carry it. 1 on success (out set).
 */
int husk_codesign_executable_identifier(const char *exe, char *out, int outlen);

/*
 * Whether the .p12's developer certificate is the one in the code signature of the executable at exe_path (the app itself, as its
 * store installed it): iOS trusts only that one, so libraries signed with another are refused. 1 the same, 0 another, -1 not known
 * (the app's signature names no developer certificate, or the .p12 does not open).
 */
/*
 * Play without JIT, checked on the device: loads Frameworks/HuskSignTest.dylib (signed by the store) where it is (T0), copied into
 * work_dir as it is (T1), and copied and signed by Husk with its own identifier (T2) and with app_ident (T3), and says in the log
 * which step iOS refuses. Returns the bits of the tests that loaded (1 << n), or -1 when the build has no test library.
 */
int husk_codesign_selftest(const char *bundle_dylib, const char *work_dir, const uint8_t *p12, size_t p12_len,
                           const char *password, const char *app_ident);

int husk_p12_matches_app(const uint8_t *p12, size_t p12_len, const char *password, const char *exe_path);

#ifdef __cplusplus
}
#endif

#endif /* HUSK_TL_CODESIGN_H */
