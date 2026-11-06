/* A minimal CoreFoundation for building husk-tl-codesign.c on Linux (tools/codesign-test.c). Objects are tagged boxes. */
#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
typedef const void *CFTypeRef;
typedef long CFIndex;
typedef int32_t OSStatus;
typedef const struct cf_obj *CFDataRef, *CFArrayRef, *CFStringRef, *CFDictionaryRef, *CFNumberRef, *CFErrorRef, *CFAllocatorRef;
typedef struct cf_obj *CFMutableArrayRef;
typedef struct { CFIndex location, length; } CFRange;
typedef uint32_t CFStringEncoding;
enum { kCFStringEncodingUTF8 = 0x08000100, kCFStringEncodingISOLatin1 = 0x0201 };
enum { kCFNumberIntType = 9 };
typedef struct { int v; } CFDictionaryKeyCallBacks, CFDictionaryValueCallBacks, CFArrayCallBacks;
extern const CFDictionaryKeyCallBacks kCFTypeDictionaryKeyCallBacks;
extern const CFDictionaryValueCallBacks kCFTypeDictionaryValueCallBacks;
extern const CFArrayCallBacks kCFTypeArrayCallBacks;
extern CFAllocatorRef kCFAllocatorDefault, kCFAllocatorNull;
extern CFTypeRef kCFNull;
CFTypeRef CFRetain(CFTypeRef);
void CFRelease(CFTypeRef);
CFDataRef CFDataCreate(CFAllocatorRef, const uint8_t *, CFIndex);
CFDataRef CFDataCreateWithBytesNoCopy(CFAllocatorRef, const uint8_t *, CFIndex, CFAllocatorRef);
const uint8_t *CFDataGetBytePtr(CFDataRef);
CFIndex CFDataGetLength(CFDataRef);
CFIndex CFArrayGetCount(CFArrayRef);
const void *CFArrayGetValueAtIndex(CFArrayRef, CFIndex);
CFMutableArrayRef CFArrayCreateMutable(CFAllocatorRef, CFIndex, const CFArrayCallBacks *);
void CFArrayAppendValue(CFMutableArrayRef, const void *);
void CFArrayAppendArray(CFMutableArrayRef, CFArrayRef, CFRange);
static inline CFRange CFRangeMake(CFIndex a, CFIndex b) { CFRange r = { a, b }; return r; }
CFStringRef CFStringCreateWithCString(CFAllocatorRef, const char *, CFStringEncoding);
CFStringRef cf_const_string(const char *);
#define CFSTR(s) cf_const_string(s)
CFNumberRef CFNumberCreate(CFAllocatorRef, int, const void *);
CFDictionaryRef CFDictionaryCreate(CFAllocatorRef, const void **, const void **, CFIndex, const CFDictionaryKeyCallBacks *, const CFDictionaryValueCallBacks *);
const void *CFDictionaryGetValue(CFDictionaryRef, const void *);
CFIndex CFErrorGetCode(CFErrorRef);
