/* SPDX-License-Identifier: GPL-2.0-or-later */
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^WinIOSStateCallback)(void);

@interface WinIOSBridge : NSObject

@property (class, nonatomic, readonly) WinIOSBridge *shared;

@property (nonatomic, readonly) BOOL isJITLive;
@property (nonatomic, readonly) BOOL isDebuggerAttached;
@property (nonatomic, readonly) BOOL isVMRunning;
@property (nonatomic, readonly) BOOL isUnpacking;
@property (nonatomic, readonly) double unpackProgress;
@property (nonatomic, readonly) NSString *jitStatusText;
@property (nonatomic, readonly) NSString *vmStatusText;
@property (nonatomic, readonly) uint32_t framebufferWidth;
@property (nonatomic, readonly) uint32_t framebufferHeight;
@property (nonatomic, readonly) uint64_t presentedFrames;
@property (nonatomic, readonly) uint64_t availableMemoryMB;
@property (nonatomic, readonly) BOOL usbKeyboardReady;
@property (nonatomic, readonly) BOOL usbTabletReady;
@property (nonatomic, readonly) uint64_t usbEventsDelivered;
@property (nonatomic, assign) BOOL useSafariForGuestLinks;
@property (nonatomic, copy, nullable) WinIOSStateCallback onStateChanged;

/* WindowsiOS Universal: host device profile (see winios_device.h). */
@property (nonatomic, readonly) BOOL isChipTooOld;
@property (nonatomic, readonly) NSString *chipTooOldText;
@property (nonatomic, readonly) NSString *deviceModelIdentifier;
@property (nonatomic, readonly) uint64_t physicalMemoryMB;
@property (nonatomic, readonly) uint64_t recommendedRamMB;
@property (nonatomic, readonly) uint64_t maxRamMB;
@property (nonatomic, readonly) NSInteger recommendedCPUs;
@property (nonatomic, readonly) NSInteger hostCPUs;
@property (nonatomic, readonly) uint64_t effectiveRamMB;
@property (nonatomic, readonly) NSInteger effectiveCPUs;
@property (nonatomic, readonly) uint64_t jitRegionMB;
/* 0 = automatic. Takes effect at the next launch (guest RAM is reserved while JIT is enabled). */
- (void)setRamOverrideMB:(uint64_t)ramMB cpus:(NSInteger)cpus;

/* WindowsiOS Universal: on-device install, as Henge installs macOS (host/win_installer.c). */
/* When set, the VM gets this installer disk as its second NVMe disk. */
@property (nonatomic, copy, nullable) NSString *installerDiskPath;
/* Called on the main queue when the VM stops (reason as in vmStatusText). */
@property (nonatomic, copy, nullable) void (^onVMExit)(NSString *reason);
/* Documents/Machines/Win11 */
@property (nonatomic, readonly) NSString *machinePath;
- (nullable NSDictionary<NSString *, id> *)inspectWindowsImage:(NSString *)esdPath error:(NSString * _Nullable * _Nullable)error
    NS_SWIFT_NAME(inspectWindowsImage(_:error:));
/* Blocking (minutes): call it off the main thread. progress is called on that thread. */
- (BOOL)buildInstallerDiskFromImage:(NSString *)esdPath
                            startnet:(NSString *)startnetPath
                             payload:(nullable NSString *)payloadDir
                              output:(NSString *)outputPath
                             workDir:(NSString *)workDir
                           deleteESD:(BOOL)deleteESD
                            progress:(void (^)(double fraction, NSString *stage))progress
                               error:(NSString * _Nullable * _Nullable)error
    NS_SWIFT_NAME(buildInstallerDisk(image:startnet:payload:output:workDir:deleteESD:progress:error:));
- (BOOL)buildDataDiskFrom:(NSString *)sourceDir output:(NSString *)outputPath label:(NSString *)label error:(NSString * _Nullable * _Nullable)error
    NS_SWIFT_NAME(buildDataDisk(source:output:label:error:));
- (BOOL)createSystemDiskAt:(NSString *)path gigabytes:(NSInteger)gigabytes error:(NSString * _Nullable * _Nullable)error
    NS_SWIFT_NAME(createSystemDisk(path:gigabytes:error:));

- (nullable NSString *)takeGuestOpenURL;
- (BOOL)takeGuestOAuthDone;

- (void)installTrapGuard;
- (BOOL)tryAcquireJIT:(BOOL)detachAfter;

- (BOOL)hasProvisionedMachine;
- (BOOL)needsSparseUnpack;
- (void)prepareAndStartWithLayer:(nullable CAMetalLayer *)layer;
- (void)bindMetalLayer:(nullable CAMetalLayer *)layer;

- (void)updateScreenSize:(CGSize)size scale:(CGFloat)scale;
- (void)updateHingeStatus:(NSInteger)status angleDegrees:(double)angleDegrees;

- (void)sendTabletNormalizedX:(double)x y:(double)y buttons:(uint8_t)buttons wheel:(int8_t)wheel;
- (void)sendKeyHid:(uint8_t)usage down:(BOOL)down;
- (void)tapKeyHid:(uint8_t)usage;
- (void)sendKeyComboWithModifiers:(NSArray<NSNumber *> *)modifiers key:(uint8_t)usage;
- (void)sendWindowsKey;
- (void)sendCtrlAltDel;
- (void)sendAltTab;
- (void)sendEscape;
- (void)pressPowerButton;
- (void)flushDisks;
- (void)stopVM;

@end

NS_ASSUME_NONNULL_END
