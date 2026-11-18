// SPDX-License-Identifier: GPL-2.0-or-later

import AndariumCore
import UIKit

/// The release notes and the stored record of the preview's What's New
/// screens. The notes of builds 12, 11 and 9 are the beta track's bundled
/// ones; those of builds 5 and 4 are made up, to stand in for releases a person
/// skipped (the application bundles notes from build 9 on). A device keeps the
/// record in its defaults.
enum WhatsNewPreview {
    /// The build the preview's What's New screens run.
    static let currentBuild = 12
    static let appVersion = "1.0 (12)"

    static let releases: [WhatsNewRelease] = WhatsNewCatalog.load(.beta) + [
        WhatsNewRelease(build: 5, version: "1.0 (5)", date: "2026-11-09", entries: [
            WhatsNewEntry(
                id: "stats-vram", title: "Graphics memory in Stats",
                text: "Stats shows how much graphics memory Android is using, beside CPU and memory.",
                symbol: "chart.bar.fill", place: .sessionSettings
            ),
            WhatsNewEntry(
                id: "audio-delay", title: "Shorter sound delay",
                text: "Sound from Android apps plays sooner after they make it.",
                symbol: "speaker.wave.2.fill"
            ),
            WhatsNewEntry(
                id: "session-end", title: "Why Android stopped",
                text: "When Android stops without shutting down, Home says why.",
                symbol: "exclamationmark.bubble.fill"
            ),
        ]),
        WhatsNewRelease(build: 4, version: "1.0 (4)", date: "2026-11-08", entries: [
            WhatsNewEntry(
                id: "low-space-pause", title: "Pause when storage is full",
                text: "When the device runs out of space, Android pauses instead of failing, and resumes when there is room again.",
                symbol: "externaldrive.fill"
            ),
        ]),
    ]

    /// The screens of the design, and what each one stands for.
    static let screens: Set<String> = [
        "whatsnew",                // first launch after the update to build 12
        "whatsnew-open",           // its notes, opened from the ribbon
        "whatsnew-skipped",        // first launch after skipping builds 4 to 11
        "whatsnew-skipped-open",   // the notes of all five
        "whatsnew-update",         // the update also carries a new Android release
        "whatsnew-limited",        // a device that offers no more than 4 GiB
        "whatsnew-dismissed",      // the ribbon put away: Home as always
        "whatsnew-fresh",          // a new install: no guest, nothing announced
        "whatsnew-info",           // Info, with What's New
        "whatsnew-history",        // Info's What's New page
        "whatsnew-nofeedback",         // the first screen, in a build without Send feedback
        "whatsnew-history-nofeedback", // Info's What's New page, in a build without it
    ]

    /// The record a screen's launch finds, and whether the install has a
    /// guest: a record of build 11 is the update to 12, of build 5 the update
    /// from the first public release, of build 3 an update that skipped
    /// three releases.
    private static func stored(for screen: String) -> WhatsNewRecord? {
        switch screen {
        case "whatsnew-skipped", "whatsnew-skipped-open": WhatsNewRecord(seenBuild: 3)
        case "whatsnew-limited": WhatsNewRecord(seenBuild: 5)
        case "whatsnew-dismissed", "whatsnew-info", "whatsnew-history", "whatsnew-history-nofeedback":
            WhatsNewRecord(seenBuild: currentBuild)
        case "whatsnew-fresh": nil
        default: WhatsNewRecord(seenBuild: 11)
        }
    }

    /// A device that offers a guest more than 4 GiB, so the memory entry is
    /// announced: an iPad of 16 GB or an iPhone of 12 GB, with made-up
    /// bounds, and the idiom's haptics: an iPhone has them, an iPad does not.
    /// "whatsnew-limited" keeps the idiom's usual mock, which stops at 4 GiB.
    static func host(for screen: String) -> HostDevice? {
        guard screens.contains(screen), screen != "whatsnew-limited" else { return nil }
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let limitMiB = pad ? 10_240 : 6_144
        let count = pad ? 8 : 6
        return HostDevice(
            name: pad ? "iPad" : "iPhone", processorCount: count,
            memory: MemoryPolicy(
                maximumsMiB: Array(repeating: pad ? 7_168 : 4_608, count: count),
                defaultsMiB: Array(repeating: pad ? 4_096 : 3_072, count: count),
                graphicsMiB: { memory, _ in max(limitMiB - 900 - memory, 352) }
            ),
            freeStorageBytes: UInt64((pad ? 118.3 : 41.6) * Double(Limits.bytesPerGiB)),
            idiom: pad ? .pad : .phone, hasHaptics: !pad, hasCompass: true, hasCamera: true
        )
    }

    /// Decides the screen's ribbon from its record, as a launch does.
    static func apply(screen: String, to model: AppModel) {
        guard screens.contains(screen) else { return }
        model.system.appVersion = appVersion
        if screen == "whatsnew-fresh" { model.guest = nil }
        if screen == "whatsnew-update" {
            model.plan = .update(from: PreviewData.previousSystemRelease, to: PreviewData.systemRelease)
        }
        #if FEEDBACK_MAIL
        // Send feedback is there when the preview is built with a receiver, as
        // a build is; these screens are the build that was made without one.
        if screen.hasSuffix("-nofeedback") { model.feedbackServices.address = { nil } }
        #endif
        let host = model.host
        let vCPUs = model.guest?.cores ?? host.processorCount
        let features = model.buildFeatures
        model.whatsNew.launch(
            releases: WhatsNewCatalog.available(releases, features: features), record: stored(for: screen),
            currentBuild: currentBuild, hasGuest: model.guest != nil,
            offers: { $0.requirement?.isMet(by: host, vCPUs: vCPUs, features: features) ?? true }
        )
    }
}
