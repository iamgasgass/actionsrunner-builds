// SPDX-License-Identifier: GPL-2.0-or-later

import AndariumCore
import AndariumCoreTestSupport
import CoreHaptics
import Foundation
import Testing
import UIKit
@testable import Andarium

/// A build made with Send feedback: what the tests' launches have unless they
/// say otherwise, whatever the build that runs them was made with.
private let withSendFeedback: Set<WhatsNewFeature> = [.sendFeedback]

private extension AppEntry {
    /// The launch's notes for a six-vCPU guest, in a build with `features`.
    @MainActor
    func announce(on model: AppModel, hasGuest: Bool, features: Set<WhatsNewFeature> = withSendFeedback) {
        announceWhatsNew(on: model, hasGuest: hasGuest, vCPUs: 6, features: features)
    }
}

/// The bundled release notes and how a launch announces them: the person's
/// own launch gets the ribbon and keeps its record, any other shows no
/// ribbon and keeps none. Each test keeps into a defaults database of its own.
@MainActor
struct WhatsNewTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "andarium-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    /// An iPhone with haptics and a camera, unless said otherwise.
    private func host(
        maximumMiB: Int, idiom: HostDevice.Idiom = .phone, hasHaptics: Bool = true, hasCamera: Bool = true
    ) -> HostDevice {
        HostDevice(
            name: idiom == .pad ? "iPad" : "iPhone", processorCount: 6,
            memory: MemoryPolicy(maximumsMiB: [maximumMiB]), freeStorageBytes: 40_000_000_000,
            idiom: idiom, hasHaptics: hasHaptics, hasCompass: false, hasCamera: hasCamera)
    }

    private func withDefaultsReturning<Result>(_ body: (UserDefaults) -> Result) -> Result {
        let name = "andarium-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        return body(defaults)
    }

    private func model(on host: HostDevice) -> AppModel {
        AppModel(
            guest: Guest.fresh(on: host), host: host,
            system: SystemInfo(
                version: "17", release: "test", kernel: "Linux", architecture: "arm64", appVersion: "1.0 (12)"),
            capabilities: .device, createRequirementBytes: 1)
    }

    private func entry(announces: Bool, build: Int? = 12, defaults: UserDefaults) -> AppEntry {
        var entry = AppEntry(overrides: LaunchOverrides())
        entry.announcesWhatsNew = announces
        entry.build = build
        entry.defaults = defaults
        return entry
    }

    // MARK: The bundled notes

    /// Build 12 as written.
    private static let buildTwelveIDs = ["old-app-compatibility", "fixes-and-improvements"]

    /// Build 11 as written, and as an iPhone with haptics and a camera and an
    /// iPad with a camera are told it.
    private static let buildElevenIDs = [
        "snapshots", "resolution", "ipad-rotation", "keyboard-mouse-controllers", "location", "camera", "haptics",
        "legacy-apk", "send-feedback", "more-fixes",
    ]
    private static let buildElevenIDsOnAnIPhone = buildElevenIDs.filter { $0 != "ipad-rotation" }
    private static let buildElevenIDsOnAnIPad = buildElevenIDs.filter { $0 != "haptics" }
    private static let buildNineIDs = ["file-browser", "more-memory", "stability-fixes"]

    /// The beta track is what Debug, Release and TestFlight builds bundle, and
    /// so what this test run has.
    @Test func theBetaTracksBundledNotesDecodeAndStartWithBuildTwelve() throws {
        let url = try #require(Bundle.main.url(forResource: WhatsNewTrack.beta.resource, withExtension: "json"))
        let releases = try WhatsNewCatalog.decode(Data(contentsOf: url))
        #expect(releases.map(\.build) == [12, 11, 9])
        #expect(releases.map(\.version) == ["1.0 (12)", "1.0 (11)", "1.0 (9)"])
        #expect(WhatsNewCatalog.load() == releases)
        let twelve = try #require(releases.first?.entries)
        #expect(twelve.map(\.id) == Self.buildTwelveIDs)
        #expect(twelve.first?.title == "Old app compatibility")
        // The old-app switch is found in Settings.
        #expect(twelve.first?.place == .sessionSettings && twelve.first?.requirement == nil)
        // The fixes are five points under a title, with no sentence of their own.
        let twelveFixes = try #require(twelve.last)
        #expect(
            twelveFixes.title == "Fixes and improvements" && twelveFixes.text == nil
                && twelveFixes.points.count == 5)
        #expect(twelveFixes.place == nil && twelveFixes.requirement == nil)
        // Build 11's notes are kept as they were.
        let eleven = try #require(releases.dropFirst().first?.entries)
        #expect(eleven.map(\.id) == Self.buildElevenIDs)
        #expect(eleven.first?.title == "Snapshots")
        let elevenFixes = try #require(eleven.last)
        #expect(elevenFixes.title == "More fixes" && elevenFixes.text == nil && elevenFixes.points.count == 6)
        #expect(elevenFixes.place == nil && elevenFixes.requirement == nil)
        // So are build 9's.
        let nine = try #require(releases.last?.entries)
        #expect(nine.map(\.id) == Self.buildNineIDs)
        #expect(nine.first?.title == "File browser")
        let nineFixes = try #require(nine.last)
        #expect(nineFixes.title == "Stability fixes" && nineFixes.text == nil && nineFixes.points.count == 6)
        #expect(nineFixes.place == nil && nineFixes.requirement == nil)
    }

    /// A build bundles its own track's file and none of the other's, and
    /// reads the one it bundles. The configuration decides (`WHATS_NEW_TRACK`),
    /// and this run's is not an AppStore one.
    @Test func aBuildBundlesAndReadsOnlyItsOwnTracksFile() {
        #if WHATS_NEW_TRACK_APP_STORE
        let own = WhatsNewTrack.appStore
        #else
        let own = WhatsNewTrack.beta
        #endif
        #expect(WhatsNewTrack.bundled == own)
        #expect(own == .beta, "the tests run in a configuration of the beta track")
        for track in WhatsNewTrack.allCases {
            let bundled = Bundle.main.url(forResource: track.resource, withExtension: "json") != nil
            #expect(bundled == (track == own), "\(track)")
        }
        #expect(Set(WhatsNewTrack.allCases.map(\.resource)).count == WhatsNewTrack.allCases.count)
    }

    /// Each track is read from its own file, whatever else the bundle holds.
    @Test func eachTrackIsReadFromItsOwnFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("andarium-whatsnew-tracks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = #"[{"build": 14, "version": "1.0 (14)", "entries": [{"id": "a", "title": "A", "text": "T", "symbol": "star"}]}]"#
        try Data(note.utf8).write(to: directory.appendingPathComponent("WhatsNewAppStore.json"))
        try Data("[]".utf8).write(to: directory.appendingPathComponent("WhatsNew.json"))
        let bundle = try #require(Bundle(url: directory))
        #expect(WhatsNewCatalog.load(.appStore, from: bundle).map(\.build) == [14])
        #expect(WhatsNewCatalog.load(.beta, from: bundle).isEmpty)
    }

    @Test func everyEntryHasWordsASymbolAndARequirementTheCodeKnows() {
        for release in WhatsNewCatalog.load() {
            #expect(!release.version.isEmpty)
            for entry in release.entries {
                #expect(!entry.title.isEmpty && (entry.text != nil || !entry.points.isEmpty), "\(entry.id)")
                #expect(UIImage(systemName: entry.symbol) != nil, "\(entry.id): \(entry.symbol)")
            }
        }
        // A requirement the code does not know fails to decode, so the notes
        // would not be here; these five entries are the ones that have any.
        let requirements = WhatsNewCatalog.load().flatMap(\.entries).compactMap { entry in
            entry.requirement.map { (entry.id, $0) }
        }
        #expect(Dictionary(uniqueKeysWithValues: requirements) == [
            "more-memory": WhatsNewRequirement(memoryAboveMiB: 4096),
            "ipad-rotation": WhatsNewRequirement(device: .pad),
            "camera": WhatsNewRequirement(camera: true),
            "haptics": WhatsNewRequirement(device: .haptics),
            "send-feedback": WhatsNewRequirement(feature: .sendFeedback),
        ])
    }

    @Test func theRibbonNamesTheBundledEntriesAndCountsTheRest() throws {
        let releases = WhatsNewCatalog.load()
        let twelveTitles = try #require(releases.first).entries.map(\.title)
        #expect(twelveTitles == ["Old app compatibility", "Fixes and improvements"])
        let titles = try #require(releases.first { $0.build == 11 }).entries.map(\.title)
        #expect(titles == [
            "Snapshots", "Resolution", "Rotation on iPad", "Keyboard, mouse and controllers", "Location", "Camera",
            "Haptics", "Install older Android apps", "Send feedback", "More fixes",
        ])
        // The dot keeps to the end of its line: a no-break space before it.
        let separator = "\u{00A0}\u{00B7} "
        #expect(WhatsNewRibbon.summary(titles, naming: 10, language: "en") == titles.joined(separator: separator))
        #expect(
            WhatsNewRibbon.summary(titles, naming: 2, language: "en")
                == "Snapshots\(separator)Resolution\(separator)8 more")
        #expect(WhatsNewRibbon.summary(titles, naming: 0) == "10 new features")
        #expect(WhatsNewRibbon.summary(twelveTitles, naming: 0) == "2 new features")
    }

    /// A language that breaks between any two characters gets plain spaces: a
    /// no-break space would pull the last character of a name onto the next
    /// line with its dot.
    @Test func theSeparatorIsNoBreakWhereALanguageBreaksAtSpaces() {
        #expect(WhatsNewRibbon.separator(inLanguage: "en") == "\u{00A0}\u{00B7} ")
        for language in ["zh-Hans", "zh-Hant", "ja", "zh-Hant-TW"] {
            #expect(WhatsNewRibbon.separator(inLanguage: language) == " \u{00B7} ", "\(language)")
        }
        #expect(WhatsNewRibbon.summary(["A", "B", "C"], naming: 1, language: "ja") == "A \u{00B7} 2 more")
    }

    /// The ribbon lists what the device is told, in the order written: eleven
    /// entries each (an update from build 9 carries builds 12 and 11), but not
    /// the same eleven.
    @Test func theRibbonNamesWhatAnIPhoneAndAnIPadAreTold() {
        func ribbon(on host: HostDevice, naming named: Int) -> String {
            withDefaultsReturning { defaults in
                WhatsNewStore(defaults: defaults).keep(WhatsNewRecord(seenBuild: 9))
                let model = model(on: host)
                entry(announces: true, defaults: defaults).announce(on: model, hasGuest: true)
                return WhatsNewRibbon.summary(model.whatsNew.pendingEntries.map(\.title), naming: named)
            }
        }
        let separator = "\u{00A0}\u{00B7} "
        let twelve = ["Old app compatibility", "Fixes and improvements"]
        #expect(ribbon(on: host(maximumMiB: 4096), naming: 5) == (twelve + [
            "Snapshots", "Resolution", "Keyboard, mouse and controllers", "6 more",
        ]).joined(separator: separator))
        #expect(ribbon(on: host(maximumMiB: 4096, idiom: .pad, hasHaptics: false), naming: 5) == (twelve + [
            "Snapshots", "Resolution", "Rotation on iPad", "6 more",
        ]).joined(separator: separator))
        #expect(ribbon(on: host(maximumMiB: 4096), naming: 0) == "11 new features")
        #expect(ribbon(on: host(maximumMiB: 4096, idiom: .pad, hasHaptics: false), naming: 0) == "11 new features")
    }

    @Test func eachKindOfDeviceIsToldItsOwnEntries() {
        func told(by host: HostDevice) -> [String] {
            withDefaultsReturning { defaults in
                WhatsNewStore(defaults: defaults).keep(WhatsNewRecord(seenBuild: 9))
                let model = model(on: host)
                entry(announces: true, defaults: defaults).announce(on: model, hasGuest: true)
                // Info lists the notes as written, whatever the device.
                #expect(model.whatsNew.releases.first?.entries.map(\.id) == Self.buildTwelveIDs)
                #expect(model.whatsNew.releases.dropFirst().first?.entries.map(\.id) == Self.buildElevenIDs)
                return model.whatsNew.pendingEntries.map(\.id)
            }
        }
        let withoutDeviceEntries = Self.buildElevenIDs.filter { $0 != "ipad-rotation" && $0 != "haptics" }
        let withoutACamera = { (ids: [String]) in ids.filter { $0 != "camera" } }
        #expect(told(by: host(maximumMiB: 4096)) == Self.buildTwelveIDs + Self.buildElevenIDsOnAnIPhone)
        #expect(
            told(by: host(maximumMiB: 4096, idiom: .pad, hasHaptics: false))
                == Self.buildTwelveIDs + Self.buildElevenIDsOnAnIPad)
        #expect(told(by: host(maximumMiB: 4096, hasHaptics: false)) == Self.buildTwelveIDs + withoutDeviceEntries)
        // A device with no camera (a Mac running the iPad app has none) is not
        // told about the Camera row, which would not be there.
        #expect(
            told(by: host(maximumMiB: 4096, hasCamera: false))
                == withoutACamera(Self.buildTwelveIDs + Self.buildElevenIDsOnAnIPhone))
        #expect(
            told(by: host(maximumMiB: 4096, idiom: .mac, hasHaptics: false, hasCamera: false))
                == withoutACamera(Self.buildTwelveIDs + withoutDeviceEntries))
        // The iPad app on a Vision Pro has none either, whatever it finds.
        let vision = CameraPlatform(isiOSAppOnMac: false, isiOSAppOnVision: true, hasFrontCamera: { true })
        #expect(
            told(by: host(maximumMiB: 4096, idiom: .pad, hasHaptics: false, hasCamera: vision.hasCamera))
                == withoutACamera(Self.buildTwelveIDs + Self.buildElevenIDsOnAnIPad))
    }

    /// A build without Send feedback (a sideload, a Debug build, an App Store
    /// build made with no receiver) neither announces the entry nor lists it,
    /// which a device that lacks a haptic engine or an iPad's turn does not do:
    /// Info keeps those as written.
    @Test func aBuildWithoutSendFeedbackLeavesItOutOfTheRibbonTheSheetAndInfo() {
        withDefaults { defaults in
            WhatsNewStore(defaults: defaults).keep(WhatsNewRecord(seenBuild: 9))
            let model = model(on: host(maximumMiB: 4096))
            entry(announces: true, defaults: defaults).announce(on: model, hasGuest: true, features: [])
            let withoutFeedback = Self.buildElevenIDs.filter { $0 != "send-feedback" }
            let toldWithoutFeedback = Self.buildElevenIDsOnAnIPhone.filter { $0 != "send-feedback" }
            #expect(model.whatsNew.pendingEntries.map(\.id) == Self.buildTwelveIDs + toldWithoutFeedback)
            #expect(model.whatsNew.pending.map(\.entries.count) == [2, 8])
            // Info: the device's entries as written (Rotation on iPad, here on an
            // iPhone), but not the feature the build lacks.
            #expect(model.whatsNew.releases.first?.entries.map(\.id) == Self.buildTwelveIDs)
            #expect(model.whatsNew.releases.dropFirst().first?.entries.map(\.id) == withoutFeedback)
            #expect(model.whatsNew.releases.map(\.build) == [12, 11, 9])
            #expect(WhatsNewRibbon.summary(model.whatsNew.pendingEntries.map(\.title), naming: 0) == "10 new features")
        }
    }

    @Test func aLaunchThatIsNotThePersonsListsOnlyWhatTheBuildHas() {
        withDefaults { defaults in
            let model = model(on: host(maximumMiB: 4096))
            entry(announces: false, defaults: defaults).announce(on: model, hasGuest: true, features: [])
            #expect(!model.whatsNew.showsRibbon)
            #expect(model.whatsNew.releases.flatMap(\.entries).map(\.id).contains("send-feedback") == false)
        }
    }

    /// A release whose entries are all about a feature the build lacks is in
    /// no screen.
    @Test func aReleaseThatTheMissingFeatureEmptiesIsDropped() {
        withDefaults { defaults in
            let only = WhatsNewRelease(
                build: 13, version: "1.0 (13)",
                entries: [WhatsNewEntry(
                    id: "only", title: "Only", text: "T", symbol: "star",
                    requirement: WhatsNewRequirement(feature: .sendFeedback))])
            let model = model(on: host(maximumMiB: 4096))
            let notes = WhatsNewCatalog.load() + [only]
            let launch = entry(announces: false, defaults: defaults)
            launch.announceWhatsNew(on: model, hasGuest: true, vCPUs: 6, features: [], notes: notes)
            #expect(model.whatsNew.releases.map(\.build) == [12, 11, 9])
            launch.announceWhatsNew(on: model, hasGuest: true, vCPUs: 6, features: [.sendFeedback], notes: notes)
            #expect(model.whatsNew.releases.map(\.build) == [13, 12, 11, 9])
        }
    }

    /// What the model says its build has is what Send feedback's own entrances
    /// use: a receiver, and `#if FEEDBACK_MAIL` is the build's own switch.
    @Test func theModelsBuildHasSendFeedbackExactlyWhenItHasAReceiver() {
        let model = model(on: host(maximumMiB: 4096))
        #if FEEDBACK_MAIL
        model.feedbackServices.address = { "feedback@example.com" }
        #expect(model.buildFeatures == [.sendFeedback])
        model.feedbackServices.address = { nil }
        #expect(model.buildFeatures.isEmpty)
        // A launch that is given none asks the model.
        withDefaults { defaults in
            WhatsNewStore(defaults: defaults).keep(WhatsNewRecord(seenBuild: 9))
            entry(announces: true, defaults: defaults).announceWhatsNew(on: model, hasGuest: true, vCPUs: 6)
            #expect(model.whatsNew.pendingEntries.map(\.id).contains("send-feedback") == false)
            model.feedbackServices.address = { "feedback@example.com" }
            entry(announces: false, defaults: defaults).announceWhatsNew(on: model, hasGuest: true, vCPUs: 6)
            #expect(model.whatsNew.releases.flatMap(\.entries).map(\.id).contains("send-feedback") == true)
        }
        #else
        #expect(model.buildFeatures.isEmpty)
        #endif
    }

    /// The host the application builds reports what the entries ask about, and
    /// not what a default would say: asked of the platform itself, so that an
    /// iPad Simulator (which is not an iPhone) tells a missing report from a
    /// right one. A Simulator has no Taptic Engine, so the haptics report is
    /// the platform's `false`; that it is read at all is a device check.
    @Test func theHostReportsItsKindAndWhetherItHasHaptics() {
        let host = AppEntry.hostDevice()
        let platform = UIDevice.current.userInterfaceIdiom
        if ProcessInfo.processInfo.isiOSAppOnMac {
            #expect(host.idiom == .mac && host.name == "Mac")
        } else if platform == .pad {
            #expect(host.idiom == .pad && host.name == "iPad")
        } else {
            #expect(platform == .phone && host.idiom == .phone && host.name == "iPhone")
        }
        #expect(host.hasHaptics == CHHapticEngine.capabilitiesForHardware().supportsHaptics)
        #expect(host.hasCamera == SystemCameraSource.hasCamera)
    }

    /// The camera a host reports follows the platform it is given: an iPad app
    /// on a Vision Pro has none, whatever cameras it finds, and a device that
    /// finds a front camera has one.
    @Test func aHostThatRunsTheIPadAppOnAVisionProHasNoCamera() {
        let vision = CameraPlatform(isiOSAppOnMac: false, isiOSAppOnVision: true, hasFrontCamera: { true })
        #expect(!AppEntry.hostDevice(camera: vision).hasCamera)
        let elsewhere = CameraPlatform(isiOSAppOnMac: false, isiOSAppOnVision: false, hasFrontCamera: { true })
        #expect(AppEntry.hostDevice(camera: elsewhere).hasCamera)
    }

    // MARK: The person's launch

    @Test func anUpdateFromBuildFiveAnnouncesTheNotesAndKeepsTheRecord() {
        withDefaults { defaults in
            WhatsNewStore(defaults: defaults).keep(WhatsNewRecord(seenBuild: 5))
            let host = host(maximumMiB: 6144)
            let model = model(on: host)
            entry(announces: true, defaults: defaults).announce(on: model, hasGuest: true)
            #expect(model.whatsNew.showsRibbon)
            // Build 12's notes first, then builds 11 and 9 the person skipped.
            #expect(model.whatsNew.pending.map(\.build) == [12, 11, 9])
            #expect(model.whatsNew.pendingEntries.map(\.id)
                == Self.buildTwelveIDs + Self.buildElevenIDsOnAnIPhone + Self.buildNineIDs)
            #expect(WhatsNewStore(defaults: defaults).record
                == WhatsNewRecord(seenBuild: 5, ribbonBuild: 12, ribbonLaunches: 1))
            #expect(model.whatsNew.releases.map(\.build) == [12, 11, 9])
        }
    }

    @Test func anUpdateFromBuildElevenAnnouncesOnlyBuildTwelvesNotes() {
        withDefaults { defaults in
            WhatsNewStore(defaults: defaults).keep(WhatsNewRecord(seenBuild: 11))
            let model = model(on: host(maximumMiB: 4096))
            entry(announces: true, defaults: defaults).announce(on: model, hasGuest: true)
            #expect(model.whatsNew.pending.map(\.build) == [12])
            #expect(model.whatsNew.pendingEntries.map(\.id) == Self.buildTwelveIDs)
            #expect(WhatsNewStore(defaults: defaults).record
                == WhatsNewRecord(seenBuild: 11, ribbonBuild: 12, ribbonLaunches: 1))
            // Info lists every release.
            #expect(model.whatsNew.releases.map(\.build) == [12, 11, 9])
        }
    }

    @Test func anUpdateFromBuildNineAnnouncesBuildsElevenAndTwelve() {
        withDefaults { defaults in
            WhatsNewStore(defaults: defaults).keep(WhatsNewRecord(seenBuild: 9))
            let model = model(on: host(maximumMiB: 4096))
            entry(announces: true, defaults: defaults).announce(on: model, hasGuest: true)
            #expect(model.whatsNew.pending.map(\.build) == [12, 11])
            #expect(model.whatsNew.pendingEntries.map(\.id) == Self.buildTwelveIDs + Self.buildElevenIDsOnAnIPhone)
            #expect(WhatsNewStore(defaults: defaults).record
                == WhatsNewRecord(seenBuild: 9, ribbonBuild: 12, ribbonLaunches: 1))
            #expect(model.whatsNew.releases.map(\.build) == [12, 11, 9])
        }
    }

    @Test func anInstallWithAGuestAndNoRecordIsAnUpdateFromBuildFive() {
        withDefaults { defaults in
            let model = model(on: host(maximumMiB: 6144))
            entry(announces: true, defaults: defaults).announce(on: model, hasGuest: true)
            #expect(model.whatsNew.showsRibbon)
        }
    }

    @Test func aDeviceThatOffersNoMoreThanFourGiBIsNotToldAboutMoreMemory() {
        withDefaults { defaults in
            let model = model(on: host(maximumMiB: 4096))
            entry(announces: true, defaults: defaults).announce(on: model, hasGuest: true)
            #expect(model.whatsNew.pendingEntries.map(\.id)
                == Self.buildTwelveIDs + Self.buildElevenIDsOnAnIPhone + ["file-browser", "stability-fixes"])
            // Info lists the notes as written.
            #expect(model.whatsNew.releases.map(\.entries.count) == [2, 10, 3])
        }
    }

    @Test func aNewInstallAnnouncesNothingAndRecordsThisBuild() {
        withDefaults { defaults in
            let model = model(on: host(maximumMiB: 6144))
            entry(announces: true, defaults: defaults).announce(on: model, hasGuest: false)
            #expect(!model.whatsNew.showsRibbon)
            #expect(WhatsNewStore(defaults: defaults).record == WhatsNewRecord(seenBuild: 12))
        }
    }

    /// The App Store track has no notes yet: an App Store build shows no
    /// ribbon and no history, and keeps no record, whatever the install had.
    /// (Info lists the history only when the model has releases.)
    @Test func aTrackWithNoNotesShowsNothingAndKeepsNoRecord() {
        let installs: [(record: WhatsNewRecord?, hasGuest: Bool)] = [
            (nil, false), (nil, true), (WhatsNewRecord(seenBuild: 5), true), (WhatsNewRecord(seenBuild: 11), true),
        ]
        for install in installs {
            withDefaults { defaults in
                install.record.map { WhatsNewStore(defaults: defaults).keep($0) }
                let model = model(on: host(maximumMiB: 6144))
                entry(announces: true, build: 12, defaults: defaults)
                    .announceWhatsNew(
                        on: model, hasGuest: install.hasGuest, vCPUs: 6, features: withSendFeedback, notes: [])
                #expect(!model.whatsNew.showsRibbon)
                #expect(model.whatsNew.pendingEntries.isEmpty)
                #expect(model.whatsNew.releases.isEmpty)
                #expect(WhatsNewStore(defaults: defaults).record == install.record)
                model.whatsNew.read()
                model.whatsNew.putAway()
                #expect(WhatsNewStore(defaults: defaults).record == install.record)
            }
        }
    }

    @Test func buildFiveAndEarlierAnnounceNothing() {
        withDefaults { defaults in
            WhatsNewStore(defaults: defaults).keep(WhatsNewRecord(seenBuild: 4))
            let model = model(on: host(maximumMiB: 6144))
            entry(announces: true, build: 5, defaults: defaults).announce(on: model, hasGuest: true)
            #expect(!model.whatsNew.showsRibbon)
        }
    }

    /// A build numbered 8 that bundles the notes written for builds 9, 11 and
    /// 12 offers none of them and records itself; build 9 then offers only its
    /// own, build 11 only its own after the person has read them, and build 12
    /// only its own after the person has read those.
    @Test func buildEightAnnouncesNothingThenBuildNineItsOwnThenBuildElevenThenTwelveItsOwn() {
        withDefaults { defaults in
            WhatsNewStore(defaults: defaults).keep(WhatsNewRecord(seenBuild: 5))
            let eight = model(on: host(maximumMiB: 6144))
            entry(announces: true, build: 8, defaults: defaults).announce(on: eight, hasGuest: true)
            #expect(!eight.whatsNew.showsRibbon)
            #expect(WhatsNewStore(defaults: defaults).record == WhatsNewRecord(seenBuild: 8))
            // Info lists the notes as bundled.
            #expect(eight.whatsNew.releases.map(\.build) == [12, 11, 9])

            let nine = model(on: host(maximumMiB: 6144))
            entry(announces: true, build: 9, defaults: defaults).announce(on: nine, hasGuest: true)
            #expect(nine.whatsNew.pending.map(\.build) == [9])
            #expect(nine.whatsNew.pendingEntries.map(\.id) == Self.buildNineIDs)
            #expect(WhatsNewStore(defaults: defaults).record
                == WhatsNewRecord(seenBuild: 8, ribbonBuild: 9, ribbonLaunches: 1))
            nine.whatsNew.read()
            #expect(WhatsNewStore(defaults: defaults).record == WhatsNewRecord(seenBuild: 9))

            let eleven = model(on: host(maximumMiB: 6144))
            entry(announces: true, build: 11, defaults: defaults).announce(on: eleven, hasGuest: true)
            #expect(eleven.whatsNew.pending.map(\.build) == [11])
            #expect(eleven.whatsNew.pendingEntries.map(\.id) == Self.buildElevenIDsOnAnIPhone)
            #expect(WhatsNewStore(defaults: defaults).record
                == WhatsNewRecord(seenBuild: 9, ribbonBuild: 11, ribbonLaunches: 1))
            eleven.whatsNew.read()
            #expect(WhatsNewStore(defaults: defaults).record == WhatsNewRecord(seenBuild: 11))

            let twelve = model(on: host(maximumMiB: 6144))
            entry(announces: true, defaults: defaults).announce(on: twelve, hasGuest: true)
            #expect(twelve.whatsNew.pending.map(\.build) == [12])
            #expect(twelve.whatsNew.pendingEntries.map(\.id) == Self.buildTwelveIDs)
            #expect(WhatsNewStore(defaults: defaults).record
                == WhatsNewRecord(seenBuild: 11, ribbonBuild: 12, ribbonLaunches: 1))
        }
    }

    @Test func aBuildWithoutANumberAnnouncesNothingAndKeepsNothing() {
        withDefaults { defaults in
            let model = model(on: host(maximumMiB: 6144))
            entry(announces: true, build: nil, defaults: defaults).announce(on: model, hasGuest: true)
            #expect(!model.whatsNew.showsRibbon)
            #expect(WhatsNewStore(defaults: defaults).record == nil)
        }
    }

    @Test func readingTheNotesAndPuttingTheRibbonAwayAreKept() {
        withDefaults { defaults in
            WhatsNewStore(defaults: defaults).keep(WhatsNewRecord(seenBuild: 5))
            let model = model(on: host(maximumMiB: 6144))
            entry(announces: true, defaults: defaults).announce(on: model, hasGuest: true)
            model.whatsNew.read()
            #expect(WhatsNewStore(defaults: defaults).record == WhatsNewRecord(seenBuild: 12))
            #expect(model.whatsNew.showsRibbon)
            model.whatsNew.putAway()
            #expect(!model.whatsNew.showsRibbon)
            #expect(WhatsNewStore(defaults: defaults).record == WhatsNewRecord(seenBuild: 12))

            // The next launch of the same build offers nothing.
            let next = self.model(on: host(maximumMiB: 6144))
            entry(announces: true, defaults: defaults).announce(on: next, hasGuest: true)
            #expect(!next.whatsNew.showsRibbon)
        }
    }

    // MARK: A harness's launch

    @Test func aLaunchThatIsNotThePersonsShowsNoRibbonAndKeepsNoRecord() {
        withDefaults { defaults in
            WhatsNewStore(defaults: defaults).keep(WhatsNewRecord(seenBuild: 5))
            let model = model(on: host(maximumMiB: 6144))
            let launch = entry(announces: false, defaults: defaults)
            launch.announce(on: model, hasGuest: true)
            #expect(!model.whatsNew.showsRibbon)
            #expect(WhatsNewStore(defaults: defaults).record == WhatsNewRecord(seenBuild: 5))
            model.whatsNew.read()
            model.whatsNew.putAway()
            #expect(WhatsNewStore(defaults: defaults).record == WhatsNewRecord(seenBuild: 5))
            // Info still lists the notes.
            #expect(model.whatsNew.releases.map(\.build) == [12, 11, 9])

            // The record of an install that has none stays none.
            withDefaults { fresh in
                let model = self.model(on: host(maximumMiB: 6144))
                self.entry(announces: false, defaults: fresh).announce(on: model, hasGuest: true)
                #expect(WhatsNewStore(defaults: fresh).record == nil)
            }
        }
    }

    #if !APP_STORE
    @Test func onlyALaunchWithNoSettingAndOutsideATestAnnounces() {
        func announces(_ environment: [String: String]) -> Bool {
            AppEntry.isPersonsLaunch(
                overrides: LaunchOverrides(environment: environment, processorCount: 6), environment: environment)
        }
        #expect(announces([:]))
        #expect(announces(["HOME": "/"]))
        #expect(!announces(["ANDARIUM_START": "normal"]))
        #expect(!announces(["ANDARIUM_GUEST_INSTANCE": "x"]))
        #expect(!announces(["KERNARIUM_VCPU_COUNT": "2"]))
        #expect(!announces(["ANDARIUM_STATS": "0"]))
        #expect(!announces(["ANDARIUM_JIT": "0"]))
        #expect(!announces(["XCTestConfigurationFilePath": "/tmp/x"]))
    }

    /// The process's own model is the real `makeModel`'s: Info lists the notes
    /// and the test run's launch announces none. (A test does not build a
    /// model of its own here: a `LiveRuntime` that is released takes Core
    /// Motion's device down with it, which crashes a Mac.)
    @Test func theTestRunsOwnLaunchIsAHarnessLaunch() {
        #expect(!AppEntry.fromArguments().announcesWhatsNew)
        let model = AndariumProcess.shared.model
        #expect(!model.whatsNew.showsRibbon)
        #expect(model.whatsNew.releases.map(\.build) == [12, 11, 9])
    }
    #endif
}
