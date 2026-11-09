/* Just enough of AudioToolbox for husk-tl-audio.c on Linux: the queue's callback is driven by the test. */
#pragma once
#include <stdint.h>
typedef int32_t OSStatus; typedef uint32_t UInt32; enum { noErr = 0 };
enum { kAudioFormatLinearPCM = 1, kLinearPCMFormatFlagIsSignedInteger = 4, kLinearPCMFormatFlagIsPacked = 8 };
typedef struct { double mSampleRate; UInt32 mFormatID, mFormatFlags, mBytesPerPacket, mFramesPerPacket, mBytesPerFrame, mChannelsPerFrame, mBitsPerChannel; } AudioStreamBasicDescription;
typedef struct AudioQueueBuffer { void *mAudioData; UInt32 mAudioDataByteSize; } *AudioQueueBufferRef;
typedef struct AudioQueue *AudioQueueRef;
typedef void (*AudioQueueOutputCallback)(void *, AudioQueueRef, AudioQueueBufferRef);
OSStatus AudioQueueNewOutput(const AudioStreamBasicDescription *, AudioQueueOutputCallback, void *, void *, void *, UInt32, AudioQueueRef *);
OSStatus AudioQueueAllocateBuffer(AudioQueueRef, UInt32, AudioQueueBufferRef *);
OSStatus AudioQueueEnqueueBuffer(AudioQueueRef, AudioQueueBufferRef, UInt32, void *);
OSStatus AudioQueueStart(AudioQueueRef, void *);
OSStatus AudioQueuePause(AudioQueueRef);
OSStatus AudioQueueDispose(AudioQueueRef, int);
