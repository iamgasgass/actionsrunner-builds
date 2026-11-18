// SPDX-License-Identifier: GPL-2.0-or-later

import Testing

@testable import AndariumCore

struct CapabilitiesTests {
    @Test func theDeviceOffersWhatTheRuntimeDoes() {
        let device = Capabilities.device
        #expect(device.bugReport && device.apkInstall && device.adbOverNetwork && device.guestFiles)
        // The statistics are the runtime's own readings.
        #expect(device.statistics)
        // TalkBack goes through the same adb channel.
        #expect(device.screenReader)
    }

    /// Held until an accepted release image carries the service: the device
    /// offers no text message, and the preview, which has no device to ship
    /// to, shows it.
    @Test func textMessagesAreHeldBackOnTheDevice() {
        #expect(!Capabilities.device.textMessages)
        #expect(Capabilities.preview.textMessages)
    }

    @Test func installApkIsOfferedInANormalSessionOfARuntimeThatInstalls() {
        let installs = Capabilities.device
        #expect(installs.offersApkInstall(in: .normal))
        // Recovery runs no adb.
        #expect(!installs.offersApkInstall(in: .recovery))
        var without = installs
        without.apkInstall = false
        #expect(!without.offersApkInstall(in: .normal) && !without.offersApkInstall(in: .recovery))
    }

    @Test func thePreviewPretendsToDoEverything() {
        let preview = Capabilities.preview
        #expect(preview.bugReport && preview.apkInstall && preview.adbOverNetwork && preview.guestFiles && preview.textMessages)
        #expect(preview.statistics)
        #expect(preview.screenReader)
    }
}
