// SPDX-License-Identifier: GPL-2.0-or-later
import AndariumCore
import Testing

@testable import Andarium

#if !APP_STORE

/// The environment names a harness launch uses are the application's, and an
/// App Store build has none (`Andarium/README.md#automation`).
struct LaunchEnvironmentTests {
    @Test func everySettingHasItsOwnName() {
        let names = LaunchOverrides.Setting.allCases.map { LaunchOverrides.environmentName($0) }
        #expect(Set(names).count == LaunchOverrides.Setting.allCases.count)
    }

    /// The device offers no text message until an accepted image has the
    /// service; the launch setting is the one way to see it, and it says "1".
    @Test func textMessagesAreOnlyOnForADevelopmentLaunchThatSaysSo() {
        #expect(TextMessagesLaunch.environmentName == "ANDARIUM_TEXT_MESSAGES")
        #expect(!TextMessagesLaunch.capabilities(in: [:]).textMessages)
        for value in ["", "0", "true", "yes", "2", " 1"] {
            #expect(!TextMessagesLaunch.capabilities(in: ["ANDARIUM_TEXT_MESSAGES": value]).textMessages, Comment(rawValue: value))
        }
        #expect(!TextMessagesLaunch.capabilities(in: ["KERNARIUM_TEXT_MESSAGES": "1"]).textMessages)
        let on = TextMessagesLaunch.capabilities(in: ["ANDARIUM_TEXT_MESSAGES": "1"])
        #expect(on.textMessages)
        // Nothing else of the device changes.
        var rest = on
        rest.textMessages = false
        #expect(rest == Capabilities.device)
    }

    @Test func readsTheNamesOfKernariumAndAndarium() {
        let overrides = LaunchOverrides(
            environment: [
                "KERNARIUM_VCPU_COUNT": "2",
                "KERNARIUM_GUEST_MEMORY_MIB": "1536",
                "KERNARIUM_ANDROID_DISK_SIZE_GIB": "32",
                "KERNARIUM_DISPLAY_SCALE": "1.5",
                "ANDARIUM_START": "recovery",
                "ANDARIUM_ERASE": "1",
                "ANDARIUM_STATS": "1",
                "ANDARIUM_GUEST_INSTANCE": "legacy-test",
            ],
            processorCount: 6
        )
        #expect(overrides.vCPUCount == 2)
        #expect(overrides.memoryMiB == 1536)
        #expect(overrides.capacityGiB == 32)
        #expect(overrides.displayScale == .factor(1.5))
        #expect(overrides.start == .recovery)
        #expect(overrides.erase)
        #expect(overrides.statistics == true)
        #expect(overrides.instance == "legacy-test")
    }

    @Test func theDisplayScaleIsStatedByNameOrByTheEarlierRetinaName() {
        func stated(_ environment: [String: String]) -> GuestDisplayScale? {
            LaunchOverrides(environment: environment, processorCount: 6).displayScale
        }
        #expect(stated(["KERNARIUM_DISPLAY_SCALE": "native"]) == .native)
        #expect(stated(["KERNARIUM_DISPLAY_SCALE": "1"]) == .points)
        // What harnesses stated before the scale: on is native, off is 1.0.
        #expect(stated(["KERNARIUM_RETINA_MODE": "1"]) == .native)
        #expect(stated(["KERNARIUM_RETINA_MODE": "0"]) == .points)
        #expect(stated(["KERNARIUM_DISPLAY_SCALE": "2", "KERNARIUM_RETINA_MODE": "1"]) == .factor(2))
        #expect(stated(["KERNARIUM_DISPLAY_SCALE": "sharpest"]) == nil)
    }

    @Test func isolatedGuestsHaveSeparateStorage() {
        let ordinary = AppEntry.guestDirectory()
        let isolated = AppEntry.guestDirectory(instance: "legacy-test")
        #expect(ordinary.lastPathComponent == "Guest")
        #expect(isolated.lastPathComponent == "legacy-test")
        #expect(isolated.deletingLastPathComponent().lastPathComponent == "TestGuests")
        #expect(isolated != ordinary)
    }

    @Test func theThermalStateIsStatedByNameAndAnythingElseIsNoSetting() {
        #expect(ThermalOverride.environmentName == "ANDARIUM_THERMAL_STATE")
        for (word, state) in [
            ("nominal", HostThermalState.nominal), ("fair", .fair), ("serious", .serious), ("critical", .critical),
            ("Serious", .serious),
        ] {
            #expect(ThermalOverride.stated(in: ["ANDARIUM_THERMAL_STATE": word]) == state, "\(word)")
        }
        for word in ["", "hot", "3", "emergency", "serious "] {
            #expect(ThermalOverride.stated(in: ["ANDARIUM_THERMAL_STATE": word]) == nil, "\(word)")
        }
        #expect(ThermalOverride.stated(in: [:]) == nil)
    }

    @Test func aLaunchThatStatesTheThermalStateIsAHarnesss() {
        let none = LaunchOverrides(environment: [:], processorCount: 4)
        #expect(AppEntry.isPersonsLaunch(overrides: none, environment: [:]))
        #expect(!AppEntry.isPersonsLaunch(overrides: none, environment: ["ANDARIUM_THERMAL_STATE": "serious"]))
    }

    @Test func theHapticsSettingSilencesALaunchOnlyWhenItIsZero() {
        #expect(HapticsLaunch.environmentName == "ANDARIUM_HAPTICS")
        #expect(HapticsLaunch.silences(in: ["ANDARIUM_HAPTICS": "0"]))
        // Anything else is no setting, and the person's switch decides.
        for word in ["", "1", "off", "false", "00", "0 "] {
            #expect(!HapticsLaunch.silences(in: ["ANDARIUM_HAPTICS": word]), "\(word)")
        }
        #expect(!HapticsLaunch.silences(in: [:]))
    }

    @Test func aLaunchThatOnlySilencesHapticsIsStillThePersonsLaunch() {
        // A silent phone makes no other difference to the launch: it stays one
        // that announces the release notes, and no setting `LaunchOverrides`
        // holds, so the pointer, statistics and JIT keep the person's choices.
        let environment = ["ANDARIUM_HAPTICS": "0"]
        let overrides = LaunchOverrides(environment: environment, processorCount: 4)
        #expect(overrides.isEmpty)
        #expect(AppEntry.isPersonsLaunch(overrides: overrides, environment: environment))
    }

    @MainActor
    @Test func theModelOfASilencedLaunchPlaysNoHapticsAndKeepsTheChoice() {
        let entry = AppEntry.fromArguments()
        let silenced = entry.makeModel(environment: ["ANDARIUM_HAPTICS": "0"])
        #expect(silenced.hapticsSilencedByLaunch)
        #expect(!silenced.hapticsPlays)
        // The switch is the person's and reads as stored.
        #expect(silenced.hapticsOn)
        for environment in [[:], ["ANDARIUM_HAPTICS": "1"]] as [[String: String]] {
            let model = entry.makeModel(environment: environment)
            #expect(!model.hapticsSilencedByLaunch)
            #expect(model.hapticsPlays == model.hapticsOn)
        }
    }

    /// A UI test's input-probe launch builds its model on a path of its own.
    /// It is an automated run too, and the side keys it opens must stay as
    /// silent as the ordinary launch's: both flags together.
    @MainActor
    @Test func anInputProbeLaunchAppliesTheSilentPhoneToo() {
        let entry = AppEntry.fromArguments()
        let both = entry.makeModel(environment: ["ANDARIUM_INPUT_PROBE": "1", "ANDARIUM_HAPTICS": "0"])
        #expect(both.inputProbe != nil, "the probe's model, not the ordinary launch's")
        #expect(both.hapticsSilencedByLaunch)
        #expect(!both.interfaceFeedbackPlays)
        #expect(both.hapticsOn)
        // The probe alone silences nothing.
        for environment in [["ANDARIUM_INPUT_PROBE": "1"], ["ANDARIUM_INPUT_PROBE": "1", "ANDARIUM_HAPTICS": "1"]] {
            let probe = entry.makeModel(environment: environment)
            #expect(probe.inputProbe != nil)
            #expect(!probe.hapticsSilencedByLaunch)
            #expect(probe.interfaceFeedbackPlays)
        }
        // And the silent phone alone is not the probe.
        #expect(entry.makeModel(environment: ["ANDARIUM_HAPTICS": "0"]).inputProbe == nil)
    }

    @Test func kernariumsBootModeAsksForARecoveryStartOnly() {
        #expect(LaunchOverrides(environment: ["KERNARIUM_ANDROID_BOOT_MODE": "recovery"], processorCount: 4).start == .recovery)
        #expect(LaunchOverrides(environment: ["KERNARIUM_ANDROID_BOOT_MODE": "normal"], processorCount: 4).start == nil)
        #expect(LaunchOverrides(environment: [:], processorCount: 4).isEmpty)
    }
}

#endif
