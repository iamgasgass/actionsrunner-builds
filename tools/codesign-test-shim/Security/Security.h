/* A minimal Security.framework over OpenSSL, for building husk-tl-codesign.c on Linux (tools/codesign-test.c). */
#pragma once
#include <CoreFoundation/CoreFoundation.h>
typedef const struct cf_obj *SecKeyRef, *SecCertificateRef, *SecIdentityRef, *SecKeyAlgorithm;
enum { errSecSuccess = 0, errSecParam = -50, errSecItemNotFound = -25300 };
extern CFStringRef kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA256, kSecKeyAlgorithmECDSASignatureDigestX962SHA256;
extern CFStringRef kSecAttrKeyType, kSecAttrKeyClass, kSecAttrKeySizeInBits, kSecAttrKeyTypeRSA, kSecAttrKeyTypeECSECPrimeRandom,
                   kSecAttrKeyClassPrivate, kSecImportItemIdentity, kSecImportItemCertChain, kSecImportExportPassphrase;
SecKeyRef SecKeyCreateWithData(CFDataRef, CFDictionaryRef, CFErrorRef *);
CFDataRef SecKeyCreateSignature(SecKeyRef, CFStringRef, CFDataRef, CFErrorRef *);
bool SecKeyVerifySignature(SecKeyRef, CFStringRef, CFDataRef, CFDataRef, CFErrorRef *);
SecKeyRef SecCertificateCopyKey(SecCertificateRef);
SecCertificateRef SecCertificateCreateWithData(CFAllocatorRef, CFDataRef);
CFDataRef SecCertificateCopyData(SecCertificateRef);
OSStatus SecPKCS12Import(CFDataRef, CFDictionaryRef, CFArrayRef *);
OSStatus SecIdentityCopyCertificate(SecIdentityRef, SecCertificateRef *);
OSStatus SecIdentityCopyPrivateKey(SecIdentityRef, SecKeyRef *);
