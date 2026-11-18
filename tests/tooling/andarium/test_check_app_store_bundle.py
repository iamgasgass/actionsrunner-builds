#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Check what the App Store bundle check refuses and what it accepts."""

from __future__ import annotations

__import__("sys").dont_write_bytecode = True

import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import NamedTuple

TIMEOUT_SECONDS = 120

CLEAN = "int fixture(int value) { return value + 1; }\n"
KNOB = (
    "#include <stdlib.h>\n"
    'const char *fixture(void) { return getenv("KERNARIUM_HOST_FORWARD"); }\n'
)
LAUNCH_KNOB = (
    "#include <stdlib.h>\n"
    'const char *fixture(void) { return getenv("ANDARIUM_START"); }\n'
)
# The thermal state a harness launch states in place of iOS's.
THERMAL_KNOB = (
    "#include <stdlib.h>\n"
    'const char *fixture(void) { return getenv("ANDARIUM_THERMAL_STATE"); }\n'
)
# The harness launch's silent phone, which keeps the device's haptics off.
HAPTICS_KNOB = (
    "#include <stdlib.h>\n"
    'const char *fixture(void) { return getenv("ANDARIUM_HAPTICS"); }\n'
)
# The UI tests' launch, which opens the session with no guest.
PROBE_KNOB = (
    "#include <stdlib.h>\n"
    'const char *fixture(void) { return getenv("ANDARIUM_INPUT_PROBE"); }\n'
)
# The probe session's scripted list of old apps.
OLD_APPS_PROBE_KNOB = (
    "#include <stdlib.h>\n"
    'const char *fixture(void) { return getenv("ANDARIUM_OLD_APPS_PROBE"); }\n'
)
# The harness's console lines (ConsoleReport), which the configuration
# compiles out: what the check reports for each, and a full line.
REPORT_LINES = (
    ("Andarium stats", "Andarium stats: cpu=1% fps=2 memory-used=3 memory=4 held=5 boot=6"),
    ("Andarium thermal state", "Andarium thermal state: phase=start state=nominal uptime=0.000"),
    ("Andarium: runtime returned", "Andarium: runtime returned 0"),
    ("Andarium: application", "Andarium: application active"),
)
HOME_PATH = (
    "const char *fixture(void) { return \"/Users/NAME/work/project/file.c\"; }\n"
)
# The debugging and automation support the App Store runtime and application
# leave out: the kind the check reports, and a library that holds a symbol or a
# string of it.
DEBUG_SUPPORT = (
    ("frame mirror", "int _ZN3uml3gpu11setFrameTapEPFvPvS1_ES1_(void) { return 1; }\n"),
    ("frame mirror", 'const char *fixture(void) { return "uml-frame-tap"; }\n'),
    ("frame mirror", "int kernarium_runtime_loader_set_frame_sink(void) { return 1; }\n"),
    ("console input", "int _ZN10kernarium7console13InputRegistry4sendEPKvm(void) { return 1; }\n"),
    ("console input", "int kernarium_runtime_loader_send_console_input(void) { return 1; }\n"),
    ("guest sampler", "int _ZN3uml3cpu11diagnostics12_GLOBAL__N_17Sampler3addEv(void) { return 1; }\n"),
    ("guest sampler", 'const char *fixture(void) { return "# guest code samples"; }\n'),
    ("footprint log", "int _ZN17FootprintReporterD1Ev(void) { return 1; }\n"),
    ("footprint log", 'const char *fixture(void) { return "Kernarium: footprint peak"; }\n'),
    ("virtual Jetsam", "int _ZN3uml7runtime13VirtualJetsam7observeEyy(void) { return 1; }\n"),
    ("virtual Jetsam", 'const char *fixture(void) { return "uml-virtual-jetsam"; }\n'),
    ("activity log", "int _ZN3uml3gpu18DisplayActivityLog6recordEPKcz(void) { return 1; }\n"),
    ("activity log", "int _ZN3uml5video11ActivityLog6openedEjPKcS3_(void) { return 1; }\n"),
    ("activity log", 'const char *fixture(void) { return "uml-video %.3f stream=%u"; }\n'),
    ("census and histogram", "int _ZN3uml3cpu6census4noteEv(void) { return 1; }\n"),
    ("automation", "int kernarium_runtime_automation_job_at_start(void) { return 1; }\n"),
    ("automation", 'const char *fixture(void) { return "removed the boot payload"; }\n'),
    ("test tooling", "int _rfbGetScreen(void) { return 1; }\n"),
    ("launch harness", "int _s8Andarium8AppEntryV13applyDeferred2toyyF(void) { return 1; }\n"),
    ("launch harness", "int _s8Andarium15ThermalOverrideO6stated2inAA010HostThermalE0OSgSDyS2SG_tFZ(void) { return 1; }\n"),
    # The Simulator preview's denied-network notice.
    ("network notice preview", "int _s8Andarium8AppModelC20previewNetworkNoticeyyAA0C6DenialOF(void) { return 1; }\n"),
    # The Simulator preview's play of the legacy install.
    ("legacy install preview", "int _s8Andarium8AppModelC21previewInstallAttemptySb_yAA10BusyUpdateVXEtYaKcSgvg(void) { return 1; }\n"),
    # The old apps the Simulator preview and a UI test's probe session play.
    ("old apps preview", "int _s8Andarium15ScriptedOldAppsC10listOldAppsAA0cD7ListingOyYaF(void) { return 1; }\n"),
    ("old apps preview", "int _s8Andarium8AppModelC15scriptedOldAppsAA0D4AppsSource_pSgvg(void) { return 1; }\n"),
    ("old apps preview", "int _s8Andarium18OldAppsProbeLaunchO6script2inAC6ScriptOSgSDyS2SG_tFZ(void) { return 1; }\n"),
    ("text messages launch", "int _s8Andarium18TextMessagesLaunchO9requested2inSbSDyS2SG_tFZ(void) { return 1; }\n"),
    # The Simulator preview's hooks into the Send feedback sheet.
    ("send feedback preview", "int _s8Andarium20SendFeedbackServicesV20previewOpensAtLaunchSbvg(void) { return 1; }\n"),
    ("send feedback preview", "int _s8Andarium20SendFeedbackServicesV14previewPrepareyyAA0aD5ModelCYaYbcvg(void) { return 1; }\n"),
    # The Simulator preview's hooks into the Buy me tokens sheet.
    ("tip jar preview", "int _s8Andarium14TipJarServicesV16previewOpensSheetSbvg(void) { return 1; }\n"),
    ("tip jar preview", "int _s8Andarium14TipJarServicesV12previewPlaysyyAA0aB5ModelCYaYbcvg(void) { return 1; }\n"),
    ("tip jar preview", "int _s8Andarium14TipJarServicesV17previewFullHeightSbvg(void) { return 1; }\n"),
    ("tip jar preview", "int _s8Andarium14TipJarServicesV8openLinkySo17OpenURLActionResult(void) { return 1; }\n"),
    ("tip jar preview", "int _s8Andarium19TipJarFullHeightKeyV12defaultValueSbvgZ(void) { return 1; }\n"),
    # A Debug build's own check of the rating prompt.
    ("rating prompt debug", "int _s8Andarium16ReviewAskTrackerV8debugSet13activeSeconds12clearHistoryySdSg_SbtF(void) { return 1; }\n"),
    ("rating prompt debug", "int _s8Andarium9ReviewAskC16applyDebugLaunch11environmentySDyS2SG_tF(void) { return 1; }\n"),
    # The UI tests' probe of the guest's keyboard and mouse: its log, its launch,
    # the recording runtime, and the identifiers of its two elements.
    ("input probe", "int _s8Andarium10InputProbeC6recordyySSF(void) { return 1; }\n"),
    ("input probe", "int _s8Andarium16InputProbeLaunchO9requested2inSbSDyS2SG_tFZ(void) { return 1; }\n"),
    ("input probe", "int _s8Andarium29RecordingHardwareInputRuntimeC6sendKey5usage7pressedys6UInt32V_SbtF(void) { return 1; }\n"),
    ("input probe", "int _s8Andarium10LiveRuntimeC15beginInputProbeyyF(void) { return 1; }\n"),
    ("input probe", "int _s8Andarium8AppModelC10inputProbeAA0cD0CSgvg(void) { return 1; }\n"),
    ("input probe", 'const char *fixture(void) { return "inputProbeLog"; }\n'),
    ("input probe", 'const char *fixture(void) { return "inputProbeField"; }\n'),
    # The UI tests' stand-in for the guest's thermal HAL, the harness's statement
    # of Settings' "When hot" and the probe's start of the thermal session.
    ("heat limit probe", "int _s8Andarium15ThermalProbeHalC10openStreams5Int32VyKF(void) { return 1; }\n"),
    ("heat limit probe", "int _s8Andarium15HeatLimitLaunchO6stated2inSbSgSDyS2SG_tFZ(void) { return 1; }\n"),
    ("heat limit probe", "int _s8Andarium10LiveRuntimeC17beginThermalProbeyyF(void) { return 1; }\n"),
    ("heat limit probe", 'const char *fixture(void) { return "heat told severe"; }\n'),
    # The development build's compass check: its class, its launch setting and its line.
    ("compass readout", "int _s8Andarium14CompassReadoutC4line3forSSSgSo14CMDeviceMotionC_tF(void) { return 1; }\n"),
    ("compass readout", "int _s8Andarium20CompassReadoutLaunchO9requested2inSbSDyS2SG_tFZ(void) { return 1; }\n"),
    ("compass readout", 'const char *fixture(void) { return "Andarium: compass-check: t=%s mount=%s"; }\n'),
    # The fold reader's test hook, which replaces the system's reading.
    ("fold reader stub", "int _s8Andarium15FoldSceneReaderC4stubSo9FoldReadingVSgyYbcSgvg(void) { return 1; }\n"),
    # The picked file's access a hosted test puts in place of the real one.
    ("picked file access stub", "int _s8Andarium8AppModelC20accessPickedFileStubyyc10Foundation3URLVcSgvg(void) { return 1; }\n"),
    # The synthetic camera: its class, its entries and its profiles' names.
    ("synthetic camera", "int _ZN3uml8platform15SyntheticCamera13sessionsOpenedEv(void) { return 1; }\n"),
    ("synthetic camera", "int _ZN3uml8platform19makeSyntheticCameraERKNS0_22SyntheticCameraOptionsE(void) { return 1; }\n"),
    ("synthetic camera", "int _ZN3uml8platform17decodeChartMarkerEPKhmjj(void) { return 1; }\n"),
    ("synthetic camera", 'const char *fixture(void) { return "SyntheticPhone1,1"; }\n'),
    ("synthetic camera", 'const char *fixture(void) { return "synthetic-back-wide"; }\n'),
    # The runtime's environment knob for it and the function that reads it.
    ("synthetic camera", 'const char *knob(void) { return "KERNARIUM_CAMERA_SOURCE"; }\n'),
    ("synthetic camera", "int _ZN9kernarium6camera11parseSourceEPKc(void) { return 1; }\n"),
    ("synthetic camera", "int _ZN9kernarium6camera12chooseSourceIPFvvEEENSt3__110shared_ptrIN3uml8platform6CameraEEERKNS0_12SourceChoiceEOT_(void) { return 1; }\n"),
    # The camera's development lines and the preview's camera and thermal notices.
    ("camera diagnostics", "int _ZN3uml6camera17printRotateAndCropEjjj(void) { return 1; }\n"),
    ("camera diagnostics", "int _ZN3uml6camera15printCheckpointENS0_16CameraCheckpointE(void) { return 1; }\n"),
    ("camera diagnostics", 'const char *fixture(void) { return "Camera: camera %u: ROTATE_AND_CROP %u"; }\n'),
    ("camera diagnostics", 'const char *fixture(void) { return "Camera: memory: %s, footprint"; }\n'),
    ("camera diagnostics", "int _s8Andarium8AppModelC19previewCameraNoticeyyF(void) { return 1; }\n"),
    ("camera diagnostics", "int _s8Andarium8AppModelC20previewThermalNoticeyyF(void) { return 1; }\n"),
    # The simulated controllers: the scripted input, the guest end of the wire
    # and the test-support module that holds them.
    ("synthetic controllers", "int _s12AndariumCore13GamepadScriptV8identityACvgZ(void) { return 1; }\n"),
    ("synthetic controllers", "int _s23AndariumCoreTestSupport13GamepadScriptV7controllerSayAA0A10ControllerVGvgZ(void) { return 1; }\n"),
    ("synthetic controllers", "int _s12AndariumCore22GamepadHostFrameReaderV4feedyAC6OutputVxSlRzs5UInt8V7ElementRtzlF(void) { return 1; }\n"),
    # The arm64 JIT: its owner of executable memory, its engine and its
    # entries, the runtime's and the loader's, the options that select it, and
    # the instruction that asks a debugger for JIT memory.
    ("JIT", "int _ZN3uml3cpu10jit_memory7releaseEPvm(void) { return 1; }\n"),
    ("JIT", "int _ZN3uml3cpu5arm6411JitExecutorC1Ev(void) { return 1; }\n"),
    ("JIT", "int _ZN3uml3cpu5arm643jit19JitCompilerFamilies13emit_bitfieldEj(void) { return 1; }\n"),
    ("JIT", "int uml_arm64_jit_sme_leave(void) { return 1; }\n"),
    ("JIT", "int darwin_uml_jit_enter_guest(void) { return 1; }\n"),
    ("JIT", "int kernarium_runtime_loader_prepare_jit(void) { return 1; }\n"),
    ("JIT", "int kernarium_runtime_loader_debugger_attached(void) { return 1; }\n"),
    ("JIT", 'const char *fixture(void) { return "--jit-cache-budget="; }\n'),
    ("JIT", 'const char *fixture(void) { return "Kernarium: running on gadgets, not the JIT: %s"; }\n'),
    ("JIT", 'void fixture(void) { __asm__ volatile(".inst 0xd43e01a0"); }\n'),
    ("JIT", "int _s8Andarium13JitPreferenceV5isOnSbvg(void) { return 1; }\n"),
    ("JIT", "int _s8Andarium11JitDebuggerO8attachedSbyFZ(void) { return 1; }\n"),
    ("JIT", 'const char *fixture(void) { return "To use JIT, open Andarium from StikDebug."; }\n'),
    ("JIT", 'const char *fixture(void) { return "Started without JIT: StikDebug is not connected."; }\n'),
)
# What an App Store runtime keeps so that the runtime API table's layout and
# version stay: its entries answer -ENOTSUP, and a virtual Jetsam that never
# starts. They are not the machinery.
STAND_INS = (
    "int runtimeSetFrameSink(void) { return -45; }\n"
    "int runtimeSendConsoleInput(void) { return -45; }\n"
    "int _ZN12_GLOBAL__N_118runtimeSetFrameSinkEPFvPvS1_Ejj(void) { return -45; }\n"
    "int _ZN12_GLOBAL__N_121runtimeSendConsoleInputEPKvm(void) { return -45; }\n"
    "int _ZN3uml7runtime24start_virtual_jetsam_watchEm(void) { return 0; }\n"
    "int _ZN3uml7runtime18VirtualJetsamWatchD1Ev(void) { return 0; }\n"
    # The runtime API's JIT entry, which answers "unsupported", and a word of
    # data that is the debugger request's encoding: only an instruction asks.
    "int _ZN12_GLOBAL__N_117runtimePrepareJitEijj(void) { return 1; }\n"
    "unsigned int fixture_data[] = { 0xd43e01a0u, 0xd43e01a0u };\n"
)
# Send feedback as a binary holds it: a type, the subject's prefix and the
# Info.plist key; the Mail framework is linked in by the build of the fixture.
FEEDBACK_FEATURE = (
    "extern void *MFMailComposeViewControllerFixture;\n"
    "const char *fixture(void) {\n"
    '  return "Andarium feedback: " "AndariumFeedbackAddress" "_$s8Andarium17SendFeedbackModelC";\n'
    "}\n"
    "int mail(void) { return MFMailComposeViewControllerFixture != 0; }\n"
    "void *MFMailComposeViewControllerFixture;\n"
)
# The same without the Mail framework: a build that lost part of the feature.
FEEDBACK_PARTIAL = (
    'const char *fixture(void) { return "Andarium feedback: AndariumFeedbackAddress"; }\n'
)
# Buy me tokens as a binary holds it: a type, the Info.plist key and the
# StoreKit framework, which the build of the fixture links in.
TIP_FEATURE = (
    "const char *fixture(void) {\n"
    '  return "AndariumTipProducts" "_$s8Andarium11TipJarModelC";\n'
    "}\n"
)
# The same without StoreKit: a build that lost part of the feature.
TIP_PARTIAL = 'const char *fixture(void) { return "AndariumTipProducts" "_$s8Andarium11TipJarModelC"; }\n'
# Review on the App Store: the code that builds the write-review address, and the key.
REVIEW_FEATURE = (
    "const char *fixture(void) {\n"
    '  return "AndariumReviewID" "_$s8Andarium10ReviewLinkV" "action=write-review" '
    '"_$s8Andarium16ReviewAskTrackerV" "_$s8StoreKit8AppStoreO13requestReview2inySo13UIWindowSceneC_tFZ";\n'
    "}\n"
)
# The same without the query that makes the address: a build that lost part of the feature.
REVIEW_PARTIAL = (
    'const char *fixture(void) { return "AndariumReviewID" "_$s8Andarium10ReviewLinkV" '
    '"_$s8Andarium16ReviewAskTrackerV" "_$s8StoreKit8AppStoreO13requestReview2inySo13UIWindowSceneC_tFZ"; }\n'
)
# The same without the rating prompt: the counter and the StoreKit request.
REVIEW_NO_ASK = (
    'const char *fixture(void) { return "AndariumReviewID" "_$s8Andarium10ReviewLinkV" "action=write-review"; }\n'
)
# Follow developer on X as a binary holds it: the Info.plist key, a line of
# the row's text, and its types (the row's and the profile address's builder it
# shares with the tip header). The partial one has lost the text and the types.
FOLLOW_X_FEATURE = (
    "const char *fixture(void) {\n"
    '  return "AndariumFollowXHandle" "Follow developer on %@" "_$s8Andarium11FollowXRowV" '
    '"_$s8Andarium14FollowXProfileO";\n'
    "}\n"
)
FOLLOW_X_PARTIAL = 'const char *fixture(void) { return "AndariumFollowXHandle"; }\n'
# The header's X button without the row: the profile address's builder, the logo
# and the tip's own code, and none of the row's.
FOLLOW_X_PROFILE_ONLY = (
    "const char *fixture(void) {\n"
    '  return "AndariumTipProducts" "_$s8Andarium11TipJarModelC" "_$s8Andarium14FollowXProfileO";\n'
    "}\n"
)
# The ICP filing number as a binary holds it: its types, the Info.plist key and the
# host of the filing site. The partial one has lost the types and the host.
ICP_FEATURE = (
    "const char *fixture(void) {\n"
    '  return "_$s8Andarium9ICPFilingO" "_$s8Andarium11ICPFootnoteV" "AndariumICPNumber" "beian.miit.gov.cn";\n'
    "}\n"
)
ICP_PARTIAL = 'const char *fixture(void) { return "AndariumICPNumber"; }\n'
# One detection of the two features at a time: the rating prompt (its counter's type and the StoreKit
# request) without the review link or key, and the storefront watch without the number or the key.
RATING_PROMPT_ONLY = (
    'const char *fixture(void) { return "_$s8Andarium16ReviewAskTrackerV'
    '_$s8StoreKit8AppStoreO13requestReview2inySo13UIWindowSceneC_tFZ"; }\n'
)
ICP_STOREFRONT_ONLY = 'const char *fixture(void) { return "_$s8Andarium18ICPStorefrontStateC"; }\n'
# Config/Info.plist as a fixture: the optional blocks are conditional, and a value
# names a build setting inside nested containers.
INFO_SOURCE = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
#ifdef FEEDBACK_MAIL
\t<key>AndariumFeedbackAddress</key>
\t<string>$(FEEDBACK_ADDRESS)</string>
#endif
#ifdef TIP_JAR
\t<key>AndariumTipProducts</key>
\t<dict>
\t\t<key>lite</key>
\t\t<string>$(TIP_LITE)</string>
\t\t<key>max</key>
\t\t<string>$(TIP_MAX)</string>
\t\t<key>pro</key>
\t\t<string>$(TIP_PRO)</string>
\t\t<key>ultra</key>
\t\t<string>$(TIP_ULTRA)</string>
\t</dict>
#endif
#ifdef APP_REVIEW
\t<key>AndariumReviewID</key>
\t<string>$(REVIEW_ID)</string>
#endif
#ifdef SHEET_NAME
\t<key>AndariumDeveloperName</key>
\t<string>$(SHEET_DEVELOPER_NAME)</string>
#endif
#ifdef SHEET_GITHUB
\t<key>AndariumDeveloperGitHub</key>
\t<string>$(SHEET_DEVELOPER_GITHUB)</string>
#endif
#ifdef SHEET_X
\t<key>AndariumDeveloperX</key>
\t<string>$(SHEET_DEVELOPER_X)</string>
#endif
#ifdef FOLLOW_X
\t<key>AndariumFollowXHandle</key>
\t<string>$(FOLLOW_X_HANDLE)</string>
#endif
#ifdef ICP_FILING
\t<key>AndariumICPNumber</key>
\t<string>$(ICP_NUMBER)</string>
#endif
\t<key>CFBundleName</key>
\t<string>Fixture</string>
\t<key>ITSAppUsesNonExemptEncryption</key>
\t<false/>
\t<key>UIApplicationSceneManifest</key>
\t<dict>
\t\t<key>UISceneConfigurations</key>
\t\t<dict>
\t\t\t<key>Role</key>
\t\t\t<array>
\t\t\t\t<dict>
\t\t\t\t\t<key>UISceneConfigurationName</key>
\t\t\t\t\t<string>Fixture</string>
\t\t\t\t\t<key>UISceneDelegateClassName</key>
\t\t\t\t\t<string>$(PRODUCT_MODULE_NAME).SceneDelegate</string>
\t\t\t\t</dict>
\t\t\t</array>
\t\t</dict>
\t</dict>
\t<key>UIRequiredDeviceCapabilities</key>
\t<array>
\t\t<string>arm64</string>
\t\t<string>metal</string>
\t</array>
</dict>
</plist>
"""
# What a dependency compiles in from the prefix it was built under: a locale
# directory on the volume that held the dependency prefixes, and a path in the
# per-user temporary directory that held a build.
VOLUME_PATH = (
    "const char *fixture(void) { return \"/Volumes/NAME/prefix/share/locale\"; }\n"
)
VOLUME_NAME_WITH_SPACE = (
    "const char *fixture(void) { return \"/Volumes/NAME 2/prefix/lib\"; }\n"
)
TEMPORARY_PATH = (
    "const char *fixture(void) {"
    ' return "/private" "/var/folders/NAME/T/source-build.abc123/stage"; }\n'
)
# Strings that are no path of a build: the volumes directory alone, a format
# for one, a different directory of a temporary tree, and the neutral
# directory the dependency builds compile in.
HARMLESS_PATHS = (
    "const char *const fixture[] = {\n"
    '  "/Volumes/", "/Volumes/%s", "/var/folders/", "/tmp/mesa_%s",\n'
    '  "/nonexistent/share/locale",\n'
    "};\n"
)
# The document pickers (Andarium/README.md#configurations). The App Store
# configuration refers to SwiftUI's fileImporter for one file and for several,
# which every product the checks accept holds (`build` appends it). The other
# configurations hold the copy-mode presenter: a type, the modifier that
# presents it and the files of a pick, each of which the App Store check refuses.
IN_PLACE_PICKERS = (
    "int _s7SwiftUI4ViewPAAE12fileImporter11isPresented19allowedContentTypes12onCompletionFixture(void) { return 1; }\n"
    "int _s7SwiftUI4ViewPAAE12fileImporter11isPresented19allowedContentTypes23allowsMultipleSelection"
    "12onCompletionFixture(void) { return 1; }\n"
)
ONE_FILE_IMPORTER = IN_PLACE_PICKERS.splitlines(keepends=True)[0]
SEVERAL_FILES_IMPORTER = IN_PLACE_PICKERS.splitlines(keepends=True)[1]
COPY_PICKERS = (
    ("a type", "int _s8Andarium18CopyDocumentPickerV4bodyyyF(void) { return 1; }\n"),
    ("the modifier", "int _s7SwiftUI4ViewP8Andarium18documentCopyPicker11isPresented5typesyyF(void) { return 1; }\n"),
    ("the files of a pick", "int _s8Andarium12PickedCopiesV4urlsSay10Foundation3URLVGvg(void) { return 1; }\n"),
)
MANIFEST = {
    "NSPrivacyTracking": False,
    "NSPrivacyTrackingDomains": [],
    "NSPrivacyCollectedDataTypes": [],
    "NSPrivacyAccessedAPITypes": [],
}


def encoded_forms(text: str) -> tuple[tuple[str, bytes], ...]:
    """A text as a binary stores it besides UTF-8: UTF-16 of either byte order, in capitals (the scan
    ignores the case of ASCII letters), and the string of a binary property list that also holds a
    non-ASCII character, which a property list stores as UTF-16."""
    return (
        ("utf16le", b"\0" + text.encode("utf-16-le") + b"\0"),
        ("utf16be", b"\0" + text.encode("utf-16-be") + b"\0"),
        ("utf16-capitals", text.upper().encode("utf-16-le")),
        ("plist-utf16", plistlib.dumps({"Note": "购买 " + text}, fmt=plistlib.FMT_BINARY)),
    )


def run(command: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        check=False,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=TIMEOUT_SECONDS,
    )


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class Outcome(NamedTuple):
    """How a run of a script ended: its status and its two streams."""
    returncode: int
    out: str
    err: str

    @property
    def stdout(self) -> str:
        """Both streams as one pipe holds them: a script's standard error is written as it goes and
        its standard output, block-buffered, at its end."""
        return self.err + self.out


class RunShim:
    """`subprocess` as a checker module sees it, with its `run` replaced."""

    def __init__(self, run) -> None:
        self.run = run

    def __getattr__(self, name: str):
        return getattr(subprocess, name)


def process_status(value) -> int:
    """The status of a process that ends with `sys.exit(value)`: none is success, an integer is its low eight
    bits (256 is success, -1 is 255), and any other object is printed to standard error and is status 1."""
    if value is None:
        return 0
    if isinstance(value, int):
        return value & 0xFF
    print(value, file=sys.stderr)
    return 1


class Checkers:
    """The bundle check and the privacy-manifest check it runs, loaded once and run in this process.
    Run as commands, each of the fixtures starts two interpreters and asks `xcrun nm` for the symbols of
    a binary the other fixtures hold a copy of; here the symbols of a binary are asked once per distinct
    content. `check_command_line` runs the real command for what only the command owns."""

    def __init__(self, checker: Path) -> None:
        self.script = checker
        self.module = load_module("check_app_store_bundle_under_test", checker)
        self.privacy_script = Path(self.module.CHECKER)
        self.privacy = load_module("check_privacy_manifests_under_test", self.privacy_script)
        self.symbols: dict[tuple, subprocess.CompletedProcess[str]] = {}
        self.module.subprocess = RunShim(self.run_privacy_checker)
        self.privacy.subprocess = RunShim(self.run_nm)

    def call(self, main, script: Path, arguments: list[str]) -> Outcome:
        """Runs `main` as the script's command would end: what it returns or what it raises as `SystemExit`
        is the exit value, and the process status is what `sys.exit` and the shell make of that value."""
        out, err = io.StringIO(), io.StringIO()
        saved = sys.argv
        sys.argv = [str(script), *arguments]
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                try:
                    value = main()
                except SystemExit as stop:
                    value = stop.code
                status = process_status(value)
        finally:
            sys.argv = saved
        return Outcome(status, out.getvalue(), err.getvalue())

    def run(self, arguments: list[str]) -> Outcome:
        # The checker remembers the icons of a catalog by its path, for the life of a process. A command
        # reads every catalog afresh, and a fixture's catalog changes under its path between two runs
        # (the same application under both configurations), so no run here starts with what another read.
        self.module.catalog_icons.cache_clear()
        return self.call(self.module.main, self.script, arguments)

    def run_privacy_checker(self, command: list[str], **options) -> subprocess.CompletedProcess[str]:
        if command[0] == sys.executable and command[1] == "-B" and Path(command[2]) == self.privacy_script:
            done = self.call(self.privacy.main, self.privacy_script, command[3:])
            return subprocess.CompletedProcess(command, done.returncode, done.out, done.err)
        return subprocess.run(command, **options)

    def run_nm(self, command: list[str], **options) -> subprocess.CompletedProcess[str]:
        if command[:2] != ["xcrun", "nm"]:
            return subprocess.run(command, **options)
        key = (tuple(command[:-1]), hashlib.sha256(Path(command[-1]).read_bytes()).digest())
        done = self.symbols.get(key)
        if done is None:
            done = subprocess.run(command, **options)
            # A failure names the path it was asked about, so it is asked again.
            if done.returncode == 0:
                self.symbols[key] = done
        return done


def run_command(checker: Path, arguments: list[str]) -> Outcome:
    """The real command, with its streams apart."""
    done = subprocess.run(
        [sys.executable, "-B", str(checker), *arguments],
        check=False, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, timeout=TIMEOUT_SECONDS)
    return Outcome(done.returncode, done.stdout, done.stderr)


def build(root: Path, name: str, source: str, extra: list[str] | None = None,
          pickers: str = IN_PLACE_PICKERS) -> Path:
    """A library of `source` and of the document pickers `pickers` (the App
    Store configuration's own by default)."""
    source_path = root / f"{name}.c"
    source_path.write_text(source + pickers, encoding="utf-8")
    output = root / f"lib{name}.dylib"
    # A framework's install name is @rpath-relative; the default one is the
    # output path, which is the temporary directory of this test.
    built = run([
        "xcrun", "--sdk", "iphoneos", "clang", "-target", "arm64-apple-ios27.0",
        "-dynamiclib", str(source_path), "-o", str(output),
        f"-Wl,-install_name,@rpath/{output.name}", *(extra or []),
    ])
    if built.returncode != 0:
        raise SystemExit(f"could not build {name}:\n{built.stdout}")
    return output


def build_with_debug_map(root: Path, name: str, directory: str | None = None, source: str = CLEAN) -> Path:
    """A library linked from an object compiled with -g: the linker keeps a
    debug map whose N_OSO entry names the object file. The object sits in a
    directory that looks like a mounted volume, so that the map names a
    build-host path of the kind the check refuses elsewhere. `directory` is
    the compilation directory the debug map's N_SO entries name, and `source`
    is the C the object is compiled from."""
    work = root / "Volumes" / "NAME"
    work.mkdir(parents=True, exist_ok=True)
    source_path = work / f"{name}.c"
    source_path.write_text(source + IN_PLACE_PICKERS, encoding="utf-8")
    objects = work / f"{name}.o"
    # A source named relative to the compilation directory is what puts that
    # directory in the debug map.
    compiled = run([
        "xcrun", "--sdk", "iphoneos", "clang", "-target", "arm64-apple-ios27.0",
        "-g", *([f"-fdebug-compilation-dir={directory}"] if directory else []),
        "-c", source_path.name if directory else str(source_path), "-o", str(objects),
    ], cwd=work)
    if compiled.returncode != 0:
        raise SystemExit(f"could not compile {name}:\n{compiled.stdout}")
    output = root / f"lib{name}.dylib"
    linked = run([
        "xcrun", "--sdk", "iphoneos", "clang", "-target", "arm64-apple-ios27.0",
        "-dynamiclib", str(objects), "-o", str(output),
        f"-Wl,-install_name,@rpath/{output.name}",
    ])
    if linked.returncode != 0:
        raise SystemExit(f"could not link {name}:\n{linked.stdout}")
    if b"/Volumes/NAME/" not in output.read_bytes():
        raise SystemExit(f"the debug map of {name} names no object under a volume")
    return output


def strip_debug_map(library: Path) -> Path:
    """The same library after `strip -S`, as the packaging leaves it."""
    stripped = library.with_name(f"{library.stem}-stripped.dylib")
    shutil.copyfile(library, stripped)
    done = run(["xcrun", "--sdk", "iphoneos", "strip", "-S", str(stripped)])
    if done.returncode != 0:
        raise SystemExit(f"could not strip {library.name}:\n{done.stdout}")
    return stripped


def icon_info(name: str) -> dict:
    """The icon blocks of an Info.plist whose primary icon, for the iPhone and the iPad, is `name`."""
    return {key: {"CFBundlePrimaryIcon": {"CFBundleIconFiles": [f"{name}60x60"], "CFBundleIconName": name}}
            for key in ("CFBundleIcons", "CFBundleIcons~ipad")}


def app_info(**overrides: object) -> dict:
    """An Info.plist as the AppStore configuration builds one, with its icon (DuskJade)."""
    keys: dict[str, object] = {
        "CFBundleIdentifier": "org.example.Fixture",
        "CFBundleExecutable": "Fixture",
        "CFBundleName": "Fixture",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "MinimumOSVersion": "27.0",
        "ITSAppUsesNonExemptEncryption": False,
        "UIRequiredDeviceCapabilities": ["arm64", "metal"],
        "UIDeviceFamily": [1, 2],
        "NSCameraUsageDescription": "Uses the camera only while Camera is on.",
        "NSMicrophoneUsageDescription": "Records only while Microphone is on.",
        "NSLocationWhenInUseUsageDescription": "Shares the location only while Location is on.",
        **icon_info("DuskJade"),
    }
    keys.update(overrides)
    return {key: value for key, value in keys.items() if value is not None}


# The notes' entry about Send feedback, which every product bundles and one
# without the feature hides, and the translations of its strings.
FEEDBACK_ENTRY = {
    "id": "send-feedback", "title": "Send feedback", "symbol": "envelope.fill",
    "text": "Email the developer from the Info menu on Home, with a bug report if you like.",
    "requirement": {"feature": "sendFeedback"},
}
FEEDBACK_POINTS_ENTRY = {
    "id": "feedback-points", "title": "More ways to reach us", "symbol": "envelope.fill",
    "points": ["Write to the developer from Settings", "Attach screenshots"],
    "requirement": {"feature": "sendFeedback"},
}
PLAIN_ENTRY = {
    "id": "snapshots", "title": "Snapshots", "symbol": "clock.arrow.circlepath",
    "text": "Save the virtual machine\u2019s data and restore it later, from Home.",
}
NOTES_STRINGS = {
    "Send feedback": "フィードバックを送信",
    FEEDBACK_ENTRY["text"]: "開発者にメールを送れます。",
    "Write to the developer from Settings": "設定から開発者に連絡できます",
    "Attach screenshots": "スクリーンショットを添付できます",
    "Snapshots": "スナップショット",
    PLAIN_ENTRY["text"]: "仮想マシンのデータを保存します。",
}


def write_feedback_tables(app: Path, languages: tuple[str, ...] = ("ja", "zh-Hans", "zh-Hant")) -> None:
    """The Feedback strings table the build compiles in with the feature, in each language."""
    for language in languages:
        lproj = app / f"{language}.lproj"
        lproj.mkdir(exist_ok=True)
        (lproj / "Feedback.strings").write_bytes(
            plistlib.dumps({"Send feedback": "Feedback fixture"}, fmt=plistlib.FMT_BINARY))


# The notes file of each track: the App Store configuration bundles the first, every other
# configuration the second.
APP_STORE_NOTES = "WhatsNewAppStore.json"
BETA_NOTES = "WhatsNew.json"


def write_notes(app: Path, entries: list[dict] | None, strings: dict[str, str],
                languages: tuple[str, ...] = ("ja", "zh-Hans"), track: str = APP_STORE_NOTES) -> None:
    """The What's New notes a build bundles (the file of `track`, none if `entries` is None)
    and the compiled table of their translations in each language, which both tracks share."""
    if entries is not None:
        (app / track).write_text(
            json.dumps([{"build": 12, "version": "1.0 (12)", "entries": entries}] if entries else []),
            encoding="utf-8")
    for language in languages:
        lproj = app / f"{language}.lproj"
        lproj.mkdir(exist_ok=True)
        (lproj / "WhatsNew.strings").write_bytes(plistlib.dumps(strings, fmt=plistlib.FMT_BINARY))


def write_follow_x_tables(app: Path, languages: tuple[str, ...] = ("ja", "zh-Hans", "zh-Hant")) -> None:
    """The FollowX strings table the build compiles in with the row, in each language."""
    for language in languages:
        lproj = app / f"{language}.lproj"
        lproj.mkdir(exist_ok=True)
        (lproj / "FollowX.strings").write_bytes(
            plistlib.dumps({"Follow developer on %@": "Row fixture %@"}, fmt=plistlib.FMT_BINARY))


# The assets the build compiles in with a value of the Info.plist: the logo of X with
# the row's handle or the header's, the avatar with the developer's name and the GitHub
# mark with its handle.
CATALOG_ASSETS = {
    "AndariumFollowXHandle": "XLogo", "AndariumDeveloperX": "XLogo",
    "AndariumDeveloperName": "DeveloperAvatar", "AndariumDeveloperGitHub": "GitHubLogo",
}


# The compiled asset catalogs the fixtures hold, by what they hold: an app icon (DuskJade or
# DuskEmber, alone), both of them, one of them with a second icon group (`aliased-<icon>`),
# and none ("plain"). They are compiled once per run with actool from the application's own icon
# documents, as the platform's reader (`assetutil`) the checker uses needs real catalogs.
CATALOGS: dict[str, Path] = {}

PLAIN_COLOR = {"colors": [{"color": {"color-space": "srgb", "components": {
    "alpha": "1.000", "blue": "0.500", "green": "0.500", "red": "0.500"}}, "idiom": "universal"}],
    "info": {"author": "xcode", "version": 1}}


def compile_catalogs(work: Path, icons: Path) -> None:
    """Compiles the fixtures' catalogs into `work` from the icon documents in `icons` (Shared)."""
    work.mkdir()
    jade, ember = icons / "DuskJade.icon", icons / "DuskEmber.icon"
    alias = work / "ArchiveArtwork.icon"
    shutil.copytree(ember, alias)
    plain = work / "Plain.xcassets"
    (plain / "AccentColor.colorset").mkdir(parents=True)
    (plain / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}), encoding="utf-8")
    (plain / "AccentColor.colorset" / "Contents.json").write_text(json.dumps(PLAIN_COLOR), encoding="utf-8")
    cases = {
        "DuskJade": ([jade], "DuskJade", False), "DuskEmber": ([ember], "DuskEmber", False),
        "plain": ([plain], None, False), "both": ([jade, ember], "DuskJade", True),
        "aliased-DuskJade": ([jade, alias], "DuskJade", True), "aliased-DuskEmber": ([ember, alias], "DuskEmber", True),
    }
    running = []
    for label, (sources, icon, everything) in cases.items():
        out = work / label
        out.mkdir()
        command = ["xcrun", "actool", *map(str, sources), "--compile", str(out), "--output-format",
                   "human-readable-text", "--output-partial-info-plist", str(out / "partial.plist"),
                   "--minimum-deployment-target", "27.0", "--platform", "iphoneos", "--target-device", "iphone",
                   "--target-device", "ipad", "--development-region", "en"]
        if icon:
            command += ["--app-icon", icon]
        if everything:
            command += ["--include-all-app-icons"]
        running.append((label, out, subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                                     stderr=subprocess.STDOUT, text=True)))
    for label, out, process in running:
        said = process.communicate(timeout=240)[0]
        if process.returncode != 0 or not (out / "Assets.car").is_file():
            raise SystemExit(f"actool could not compile the {label} catalog:\n{said}")
        CATALOGS[label] = out / "Assets.car"


def clone(source: Path, destination: Path) -> None:
    """A copy of a (large) catalog that shares its blocks where the volume can."""
    if subprocess.run(["cp", "-c", str(source), str(destination)], stdin=subprocess.DEVNULL,
                      capture_output=True).returncode != 0:
        shutil.copyfile(source, destination)


def make_app(
    root: Path, name: str, executable: Path, info: dict,
    framework: Path | None = None, manifest: bool = True, feedback_tables: bool | None = None,
    follow_x_tables: bool | None = None, follow_x_logo: bool | None = None,
    assets: dict[str, bool] | None = None,
) -> Path:
    """A fixture application. A product whose Info.plist names a receiver holds the
    Feedback strings table too (`feedback_tables` says otherwise), and one that
    names a handle of X holds the FollowX table (`follow_x_tables`). The asset catalog
    holds the assets the Info.plist's values bring (CATALOG_ASSETS); `assets` and
    `follow_x_logo` add or remove one by its name."""
    app = root / name / "Fixture.app"
    app.mkdir(parents=True)
    shutil.copyfile(executable, app / "Fixture")
    (app / "Info.plist").write_bytes(plistlib.dumps(info))
    if feedback_tables is None:
        feedback_tables = "AndariumFeedbackAddress" in info
    if feedback_tables:
        write_feedback_tables(app)
    named = "AndariumFollowXHandle" in info
    if follow_x_tables is None:
        follow_x_tables = named
    if follow_x_tables:
        write_follow_x_tables(app)
    wanted = {asset for key, asset in CATALOG_ASSETS.items() if key in info}
    primary = info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {}).get("CFBundleIconName")
    for asset, present in {**(assets or {}), **({} if follow_x_logo is None else {"XLogo": follow_x_logo})}.items():
        (wanted.add if present else wanted.discard)(asset)
    # The catalog is a compiled one with the application's icon in it (`assets` can leave it out), and
    # the names of the other assets after its end, where the checker's byte search finds them.
    icon = primary in CATALOGS and (assets or {}).get(primary, True)
    if wanted or icon:
        clone(CATALOGS[primary] if icon else CATALOGS["plain"], app / "Assets.car")
        with (app / "Assets.car").open("ab") as handle:
            handle.write(b"".join(b"\0" + item.encode() for item in sorted(wanted)) + b"\0")
    if manifest:
        (app / "PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps(MANIFEST))
    if framework is not None:
        bundle = app / "Frameworks" / "Runtime.framework"
        bundle.mkdir(parents=True)
        shutil.copyfile(framework, bundle / "Runtime")
        (bundle / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "org.example.Runtime",
            "CFBundleExecutable": "Runtime",
            "CFBundleName": "Runtime",
            "CFBundlePackageType": "FMWK",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "MinimumOSVersion": "27.0",
        }))
        (bundle / "PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps(MANIFEST))
    return app


def tip_app(root: Path, name: str, executable: Path, info: dict, *, table: bool = True,
            framework: Path | None = None, **options) -> Path:
    """An application with the String Catalog table of Buy me tokens, which the build compiles
    in with the feature, unless `table` is false."""
    app = make_app(root, name, executable, info, framework=framework, **options)
    if table:
        for language in ("en", "ja", "zh-Hans", "zh-Hant"):
            (app / f"{language}.lproj").mkdir(exist_ok=True)
            (app / f"{language}.lproj" / "TipJar.strings").write_bytes(
                plistlib.dumps({"Buy me tokens": "Buy me tokens"}, fmt=plistlib.FMT_BINARY))
    return app


def review_app(root: Path, name: str, executable: Path, info: dict, *, table: bool = True,
               framework: Path | None = None) -> Path:
    """An application with the String Catalog table of Review on the App Store, which the build
    compiles in with the feature, in each language, unless `table` is false."""
    app = make_app(root, name, executable, info, framework=framework)
    if table:
        for language in ("en", "ja", "zh-Hans", "zh-Hant"):
            (app / f"{language}.lproj").mkdir(exist_ok=True)
            (app / f"{language}.lproj" / "Review.strings").write_bytes(
                plistlib.dumps({"Review on the App Store": "Review on the App Store"}, fmt=plistlib.FMT_BINARY))
    return app


def check_tip_jar(root: Path, check, clean: Path, feedback_feature: Path, feedback_info: dict,
                  receiver: str, feedback_appstore: list[str], feedback_local: list[str],
                  feedback_arranged: list[str]) -> None:
    """Buy me tokens is compiled in only where the build names its four product identifiers, in
    either direction, alone and with Send feedback. The identifiers are made up."""
    ids = {tier: f"com.fixture.product.{tier}" for tier in ("lite", "pro", "max", "ultra")}
    named = ",".join(ids.values())
    named_args = ["--tip-products", named, "--tip-local-products", named]
    local_args = ["--tip-local-products", named]
    arranged_ids = {tier: f"com.example.andarium.tip.{tier}" for tier in ids}
    arranged = ",".join(arranged_ids.values())
    arranged_args = ["--tip-products", arranged]
    tip_info = app_info(AndariumTipProducts=ids)
    feature = build(root, "tip-feature", TIP_FEATURE, ["-framework", "StoreKit"])
    partial = build(root, "tip-partial", TIP_PARTIAL)

    # With the identifiers: the code, the key and the table, and the identifiers the build named.
    check(tip_app(root, "tip-built", feature, tip_info), passes=True,
          expect="Buy me tokens is compiled in", args=named_args)
    check(tip_app(root, "tip-absent", clean, app_info(), table=False), passes=True,
          expect="Buy me tokens is not compiled in")
    check(tip_app(root, "tip-no-key", feature, app_info()), passes=False,
          expect="AndariumTipProducts must be the four product identifiers", args=named_args)
    check(tip_app(root, "tip-other-key", feature, app_info(AndariumTipProducts={**ids, "pro": "com.fixture.other"})),
          passes=False, expect="must be the four product identifiers the build names", args=named_args)
    check(tip_app(root, "tip-short-key", feature, app_info(AndariumTipProducts={"lite": ids["lite"]})),
          passes=False, expect="must be the four product identifiers the build names", args=named_args)
    check(tip_app(root, "tip-empty-key", feature, app_info(AndariumTipProducts={**ids, "max": ""})),
          passes=False, expect="must be the four product identifiers the build names", args=named_args)
    check(tip_app(root, "tip-not-built", clean, tip_info), passes=False,
          expect="lacks Buy me tokens", args=named_args)
    check(tip_app(root, "tip-partial", partial, tip_info), passes=False,
          expect="StoreKit.framework", args=named_args)
    check(tip_app(root, "tip-no-table", feature, tip_info, table=False), passes=False,
          expect="lacks the TipJar strings table", args=named_args)
    no_japanese = tip_app(root, "tip-no-ja", feature, tip_info)
    (no_japanese / "ja.lproj" / "TipJar.strings").unlink()
    check(no_japanese, passes=False, expect="lacks the TipJar strings table in ja", args=named_args)

    # No identifiers, so nothing of it: not the code, the key, the table or its words.
    check(tip_app(root, "tip-code-without", feature, app_info(), table=False), passes=False,
          expect="carries Buy me tokens")
    check(tip_app(root, "tip-key-without", clean, tip_info, table=False), passes=False,
          expect="has AndariumTipProducts though the build names no product identifiers")
    check(tip_app(root, "tip-framework-without", clean, app_info(), table=False, framework=feature),
          passes=False, expect="Runtime.framework/Runtime: carries Buy me tokens")
    check(tip_app(root, "tip-table-without", clean, app_info()), passes=False,
          expect="is the TipJar strings table though the build names no product identifiers")
    words = make_app(root, "tip-words", clean, app_info())
    (words / "en.lproj").mkdir()
    (words / "en.lproj" / "Localizable.strings").write_bytes(
        plistlib.dumps({"Buy me tokens": "Buy me tokens"}, fmt=plistlib.FMT_BINARY))
    check(words, passes=False, expect="has Buy me tokens strings")
    # Another language's table of the feature is found by its name as well.
    other_language = tip_app(root, "tip-table-ja", clean, app_info(), table=False)
    (other_language / "ja.lproj").mkdir()
    (other_language / "ja.lproj" / "TipJar.strings").write_bytes(b'"Done" = "x";\n')
    check(other_language, passes=False, expect="ja.lproj/TipJar.strings: is the TipJar strings table")

    # The four identifiers are all there is, in the App Store configuration: not three, and four
    # that are well formed, distinct and no placeholder.
    for name, fields in (
            ("three", [ids["lite"], ids["pro"], "", ids["ultra"]]),
            ("one", [ids["lite"], "", "", ""]),
            ("last", ["", "", "", ids["ultra"]])):
        check(tip_app(root, f"tip-{name}", feature, tip_info), passes=False, expect="of the four product identifiers",
              args=["--tip-products", ",".join(fields)])
    shapes = ("has space", "-lead", ".lead", "quote\"d", "semi;colon", "a/b", "\u00e9.fixture", "x" * 101, "<a.b>")
    for index, shape in enumerate(shapes):
        fields = [ids["lite"], ids["pro"], ids["max"], shape]
        check(tip_app(root, f"tip-shape-{index}", feature, app_info(AndariumTipProducts={**ids, "ultra": shape})),
              passes=False, expect="the ultra identifier in the local configuration is not a product identifier",
              args=["--tip-products", ",".join(fields)])
    for index, prefix in enumerate(("com.example.", "org.example.", "net.example.", "example.")):
        placeholder = f"{prefix}pro"
        check(tip_app(root, f"tip-placeholder-{index}", feature, app_info(AndariumTipProducts={**ids, "pro": placeholder})),
              passes=False, expect="the pro identifier in the local configuration is a placeholder",
              args=["--tip-products", ",".join([ids["lite"], placeholder, ids["max"], ids["ultra"]])])
    same = [ids["lite"], ids["lite"], ids["max"], ids["ultra"]]
    check(tip_app(root, "tip-same", feature, app_info(AndariumTipProducts=dict(zip(ids, same)))), passes=False,
          expect="two tiers name the same product identifier", args=["--tip-products", ",".join(same)])
    for index, good in enumerate(("a", "a.b_c-d.1", "x" * 100)):
        fields = [good, ids["pro"], ids["max"], ids["ultra"]]
        check(tip_app(root, f"tip-shape-ok-{index}", feature,
                      app_info(AndariumTipProducts={**ids, "lite": good})),
              passes=True, expect="Buy me tokens is compiled in", args=["--tip-products", ",".join(fields)])

    # A build that names none still has the feature's file names in the linker's debug map of its
    # Debug or Release product; the symbols of a function the feature defines are searched, though.
    mapped = build_with_debug_map(root, "mapped-tip", "/Users/NAME/TipJarSheet")
    symbol_only = build_with_debug_map(
        root, "tip-symbol-only", "/Users/NAME/Project",
        "__attribute__((visibility(\"hidden\"))) int plain_first(void) { return 2; }\n"
        "__attribute__((visibility(\"hidden\"))) int _s8Andarium11TipJarModelC4openyyF(void) { return 1; }\n")
    other = ["--tip-jar", "--configuration"]
    for configuration in ("Debug", "Release"):
        check(tip_app(root, f"tip-{configuration}-debug-map", mapped, app_info(), table=False), passes=True,
              expect=f"Buy me tokens is not compiled in ({configuration})", args=[*other, configuration])
        check(tip_app(root, f"tip-{configuration}-symbol-only", symbol_only, app_info(), table=False), passes=False,
              expect="carries Buy me tokens (TipJar", args=[*other, configuration])
    check(tip_app(root, "tip-appstore-debug-map", mapped, app_info(), table=False), passes=True,
          expect="Buy me tokens is not compiled in")
    check(tip_app(root, "tip-appstore-symbol-only", symbol_only, app_info(), table=False), passes=False,
          expect="carries Buy me tokens (TipJar")
    debug = tip_app(root, "tip-debug-library", clean, app_info(), table=False)
    shutil.copyfile(feature, debug / "Fixture.debug.dylib")
    check(debug, passes=False, expect="Fixture.debug.dylib: carries Buy me tokens")

    # The other configurations: absent, or the arranged example identifiers, which Debug alone takes.
    arranged_info = app_info(AndariumTipProducts=arranged_ids)
    for configuration in ("Debug", "Release"):
        check(tip_app(root, f"tip-{configuration}-absent", clean, app_info(), table=False), passes=True,
              expect=f"Buy me tokens is not compiled in ({configuration})", args=[*other, configuration])
        # The local configuration's identifiers never reach them.
        check(tip_app(root, f"tip-{configuration}-ids", feature, tip_info), passes=False,
              expect="not the arranged example ones", args=[*other, configuration, *named_args])
        check(tip_app(root, f"tip-{configuration}-code", feature, app_info(), table=False), passes=False,
              expect="carries Buy me tokens", args=[*other, configuration])
        check(tip_app(root, f"tip-{configuration}-key", clean, tip_info, table=False), passes=False,
              expect="though the build names no product identifiers", args=[*other, configuration])
        check(tip_app(root, f"tip-{configuration}-three", feature, tip_info), passes=False,
              expect="not the arranged example ones",
              args=[*other, configuration, "--tip-products", f"{arranged_ids['lite']},,,"])
    check(tip_app(root, "tip-Debug-arranged", feature, arranged_info), passes=True,
          expect="Buy me tokens is compiled in (Debug)", args=[*other, "Debug", *arranged_args])
    check(tip_app(root, "tip-Release-arranged", feature, arranged_info), passes=False,
          expect="only Debug takes the arrangement", args=[*other, "Release", *arranged_args])
    check(tip_app(root, "tip-Release-arranged-absent", clean, app_info(), table=False), passes=False,
          expect="only Debug takes the arrangement", args=[*other, "Release", *arranged_args])
    check(tip_app(root, "tip-appstore-arranged", feature, arranged_info), passes=False,
          expect="is a placeholder", args=arranged_args)

    # The local configuration's identifiers are in no file of a bundle that does not name them, and
    # the check never prints one. Bytes anywhere count, in either case.
    secret = ids["pro"]
    leaky = build(root, "tip-leaky", f'const char *fixture(void) {{ return "{secret}"; }}\n')
    data_file = tip_app(root, "tip-leak-data", clean, app_info(), table=False)
    (data_file / "Data.bin").write_bytes(b"\0\1" + secret.upper().encode() + b"\2")
    nested = tip_app(root, "tip-leak-nested", clean, app_info(), table=False)
    (nested / "en.lproj").mkdir()
    (nested / "en.lproj" / "InfoPlist.strings").write_bytes(f'"CFBundleName" = "{secret}";\n'.encode())
    straddle = tip_app(root, "tip-leak-straddle", clean, app_info(), table=False)
    (straddle / "Big.bin").write_bytes(b"\0" * ((8 << 20) - 5) + secret.encode() + b"\0")
    # Only one of the four is there, which is as much of a leak.
    last = tip_app(root, "tip-leak-last", clean, app_info(), table=False)
    (last / "Data.bin").write_bytes(ids["ultra"].encode())
    leaks = (
        ("executable", tip_app(root, "tip-leak-executable", leaky, app_info(), table=False), "Fixture"),
        ("framework", tip_app(root, "tip-leak-framework", clean, app_info(), table=False, framework=leaky),
         "Frameworks/Runtime.framework/Runtime"),
        ("info-plist", tip_app(root, "tip-leak-info", clean, tip_info, table=False), "Info.plist"),
        ("data-file", data_file, "Data.bin"),
        ("nested-file", nested, "en.lproj/InfoPlist.strings"),
        ("straddle", straddle, "Big.bin"),
        ("last", last, "Data.bin"),
    )
    for name, app, path in leaks:
        for configuration in ("Debug", "Release"):
            for arguments in (local_args, [*local_args, *arranged_args]):
                check(app, passes=False, expect=f"{path}: holds a product identifier of the local configuration",
                      never=secret, args=[*other, configuration, *arguments])
        check(app, passes=False, expect=f"{path}: holds a product identifier of the local configuration",
              never=secret, args=local_args)
        check(app, passes=False, never=ids["ultra"], args=local_args)
    check(tip_app(root, "tip-leak-none", clean, app_info(), table=False, framework=clean), passes=True,
          expect="ready for the App Store", args=local_args)
    check(tip_app(root, "tip-leak-none-debug", clean, app_info(), table=False), passes=True,
          expect="Buy me tokens is not compiled in (Debug)", args=[*other, "Debug", *local_args])
    check(tip_app(root, "tip-leak-none-arranged", feature, arranged_info), passes=True,
          expect="Buy me tokens is compiled in (Debug)", args=[*other, "Debug", *local_args, *arranged_args])
    # An App Store build that names them holds them in Info.plist, and nowhere else.
    check(tip_app(root, "tip-leak-named", feature, tip_info), passes=True,
          expect="Buy me tokens is compiled in", args=named_args)
    named_leak = tip_app(root, "tip-leak-named-elsewhere", feature, tip_info)
    (named_leak / "Data.bin").write_bytes(secret.encode())
    check(named_leak, passes=True, expect="Buy me tokens is compiled in", args=named_args)

    # The identifiers as a binary stores a string besides UTF-8, in every file, the staged system image
    # included.
    for form, content in encoded_forms(secret):
        stray = tip_app(root, f"tip-leak-{form}", clean, app_info(), table=False)
        (stray / "Data.bin").write_bytes(content)
        for arguments in (local_args, [*other, "Debug", *local_args]):
            check(stray, passes=False, expect="Data.bin: holds a product identifier of the local configuration",
                  never=secret, args=arguments)
    large = tip_app(root, "tip-leak-large", clean, app_info(), table=False)
    with (large / "Data.bin").open("wb") as stream:
        stream.write(secret.encode("utf-16-le"))
        stream.truncate(129 << 20)
    check(large, passes=False, expect="Data.bin: holds a product identifier of the local configuration",
          never=secret, args=local_args)
    image = tip_app(root, "tip-leak-image", clean, app_info(), table=False)
    (image / "andarium-system" / "guest").mkdir(parents=True)
    for encoding in ("utf-8", "utf-16-le", "utf-16-be"):
        (image / "andarium-system" / "guest" / "system.img").write_bytes(b"\0" + secret.encode(encoding) + b"\0")
        check(image, passes=False,
              expect="andarium-system/guest/system.img: holds a product identifier of the local configuration",
              never=secret, args=local_args)
    (image / "andarium-system" / "guest" / "system.img").write_bytes(b"\0" + b"unrelated" + b"\0")
    check(image, passes=True, expect="ready for the App Store", args=local_args)
    # A neighbour of the same name prefix is searched as well.
    neighbour = tip_app(root, "tip-leak-neighbour", clean, app_info(), table=False)
    (neighbour / "andarium-system-copy").mkdir()
    (neighbour / "andarium-system-copy" / "system.img").write_bytes(b"\0" + secret.encode("utf-16-le") + b"\0")
    check(neighbour, passes=False, expect="andarium-system-copy/system.img: holds a product identifier",
          never=secret, args=local_args)

    # Both features, alone and together: each says its own line and neither disturbs the other.
    both_code = build(root, "both", FEEDBACK_FEATURE + TIP_FEATURE.replace("fixture", "tip_fixture"),
                      ["-framework", "MessageUI", "-framework", "StoreKit"])
    both_info = app_info(AndariumFeedbackAddress=receiver, AndariumTipProducts=ids)
    together = tip_app(root, "both-named", both_code, both_info)
    check(together, passes=True, expect="Buy me tokens is compiled in", args=[*feedback_appstore, *named_args])
    check(together, passes=True, expect="Send feedback is compiled in", args=[*feedback_appstore, *named_args])
    check(tip_app(root, "both-feedback-only", feedback_feature, app_info(AndariumFeedbackAddress=receiver),
                  table=False), passes=True, expect="Buy me tokens is not compiled in",
          args=[*feedback_appstore, *local_args])
    check(tip_app(root, "both-tip-only", feature, tip_info), passes=True, expect="Send feedback is not compiled in",
          args=[*feedback_local, *named_args])
    # The one that is not named cannot ride in the other's product.
    check(tip_app(root, "both-tip-in-feedback", both_code, app_info(AndariumFeedbackAddress=receiver),
                  table=False), passes=False, expect="carries Buy me tokens", args=feedback_appstore)
    check(tip_app(root, "both-feedback-in-tip", both_code, tip_info), passes=False,
          expect="carries Send feedback", args=named_args)
    check(tip_app(root, "both-none", clean, app_info(), table=False), passes=True, expect="ready for the App Store",
          args=[*feedback_local, *local_args])
    # Debug takes both arrangements together.
    check(tip_app(root, "both-Debug-arranged", both_code,
                  app_info(AndariumFeedbackAddress="feedback@example.com", AndariumTipProducts=arranged_ids)),
          passes=True, expect="Buy me tokens is compiled in (Debug)", args=[*other, "Debug", *arranged_args])


def check_review(root: Path, check, clean: Path, feedback_info: dict, tip_info: dict,
                 feedback_appstore: list[str], tip_named: list[str]) -> None:
    """Review on the App Store is compiled in only where the build names the application's App
    Store identifier, in either direction, alone and with the other two features. The identifier is
    made up."""
    identifier = "id1234567890"
    named_args = ["--review-id", identifier, "--review-local-id", identifier]
    local_args = ["--review-local-id", identifier]
    arranged = "id0000000000"
    arranged_args = ["--review-id", arranged]
    review_info = app_info(AndariumReviewID=identifier)
    feature = build(root, "review-feature", REVIEW_FEATURE)
    partial = build(root, "review-partial", REVIEW_PARTIAL)
    no_ask = build(root, "review-no-ask", REVIEW_NO_ASK)

    # With the identifier: the code, the key and the table in each language, and the identifier named.
    check(review_app(root, "review-built", feature, review_info), passes=True,
          expect="Review on the App Store is compiled in", args=named_args)
    check(review_app(root, "review-absent", clean, app_info(), table=False), passes=True,
          expect="Review on the App Store is not compiled in")
    check(review_app(root, "review-no-key", feature, app_info()), passes=False,
          expect="AndariumReviewID must be the App Store identifier", args=named_args)
    check(review_app(root, "review-other-key", feature, app_info(AndariumReviewID="id1234567891")),
          passes=False, expect="must be the App Store identifier the build names", args=named_args)
    check(review_app(root, "review-not-built", clean, review_info), passes=False,
          expect="lacks Review on the App Store", args=named_args)
    check(review_app(root, "review-partial", partial, review_info), passes=False,
          expect="action=write-review", args=named_args)
    # The rating prompt is part of it: the counter and the StoreKit request.
    check(review_app(root, "review-no-ask", no_ask, review_info), passes=False,
          expect="ReviewAskTracker, requestReview", args=named_args)
    # StoreKit is what the rating prompt links, so it says nothing about the tip sheet.
    storekit = build(root, "review-storekit", REVIEW_FEATURE, ["-framework", "StoreKit"])
    check(tip_app(root, "tip-absent-review-storekit", storekit, app_info(), table=False), passes=True,
          expect="Buy me tokens is not compiled in", args=["--tip-jar", "--configuration", "Debug"])
    check(review_app(root, "review-no-table", feature, review_info, table=False), passes=False,
          expect="lacks the Review strings table", args=named_args)
    no_chinese = review_app(root, "review-no-zh-hant", feature, review_info)
    (no_chinese / "zh-Hant.lproj" / "Review.strings").unlink()
    check(no_chinese, passes=False, expect="lacks the Review strings table in zh-Hant", args=named_args)

    # No identifier, so nothing of it: not the code, the key, the table or its words.
    check(review_app(root, "review-code-without", feature, app_info(), table=False), passes=False,
          expect="carries Review on the App Store")
    check(review_app(root, "review-key-without", clean, review_info, table=False), passes=False,
          expect="has AndariumReviewID though the build names no App Store identifier")
    check(review_app(root, "review-framework-without", clean, app_info(), table=False, framework=feature),
          passes=False, expect="Runtime.framework/Runtime: carries Review on the App Store")
    check(review_app(root, "review-table-without", clean, app_info()), passes=False,
          expect="is the Review strings table though the build names no App Store identifier")
    words = make_app(root, "review-words", clean, app_info())
    (words / "en.lproj").mkdir()
    (words / "en.lproj" / "Localizable.strings").write_bytes(
        plistlib.dumps({"Review on the App Store": "Review on the App Store"}, fmt=plistlib.FMT_BINARY))
    check(words, passes=False, expect="has Review on the App Store strings")

    # The identifier is well formed and no placeholder, in the App Store configuration.
    for index, shape in enumerate(("", "1234567890", "ID1234567890", "id1234", "id12345678901234567",
                                   "id12345a7890", "id123/456", "id 123456", "id123456?x=1")):
        if not shape:
            continue
        check(review_app(root, f"review-shape-{index}", feature, app_info(AndariumReviewID=shape)), passes=False,
              expect="is not an App Store identifier", args=["--review-id", shape])
    check(review_app(root, "review-placeholder", feature, app_info(AndariumReviewID=arranged)), passes=False,
          expect="is a placeholder", args=arranged_args)
    for index, good in enumerate(("id12345", "id100000", "id123456789012345")):
        check(review_app(root, f"review-shape-ok-{index}", feature, app_info(AndariumReviewID=good)),
              passes=True, expect="Review on the App Store is compiled in", args=["--review-id", good])

    # A Debug or Release product that names none has the feature's file names in the linker's debug
    # map; the symbols of a function the feature defines are searched, though.
    mapped = build_with_debug_map(root, "mapped-review", "/Users/NAME/ReviewServices")
    symbol_only = build_with_debug_map(
        root, "review-symbol-only", "/Users/NAME/Project",
        "__attribute__((visibility(\"hidden\"))) int plain_first(void) { return 2; }\n"
        "__attribute__((visibility(\"hidden\"))) int _s8Andarium10ReviewLinkV3urlyyF(void) { return 1; }\n")
    other = ["--review", "--configuration"]
    for configuration in ("Debug", "Release"):
        check(review_app(root, f"review-{configuration}-debug-map", mapped, app_info(), table=False), passes=True,
              expect=f"Review on the App Store is not compiled in ({configuration})", args=[*other, configuration])
        check(review_app(root, f"review-{configuration}-symbol-only", symbol_only, app_info(), table=False),
              passes=False, expect="carries Review on the App Store (ReviewLink", args=[*other, configuration])

    # The other configurations: absent, or the arranged placeholder, which Debug alone takes.
    arranged_info = app_info(AndariumReviewID=arranged)
    for configuration in ("Debug", "Release"):
        check(review_app(root, f"review-{configuration}-absent", clean, app_info(), table=False), passes=True,
              expect=f"Review on the App Store is not compiled in ({configuration})", args=[*other, configuration])
        # The local configuration's identifier never reaches them.
        check(review_app(root, f"review-{configuration}-id", feature, review_info), passes=False,
              expect="not the arranged placeholder", args=[*other, configuration, *named_args])
        check(review_app(root, f"review-{configuration}-code", feature, app_info(), table=False), passes=False,
              expect="carries Review on the App Store", args=[*other, configuration])
        check(review_app(root, f"review-{configuration}-key", clean, review_info, table=False), passes=False,
              expect="though the build names no App Store identifier", args=[*other, configuration])
    check(review_app(root, "review-Debug-arranged", feature, arranged_info), passes=True,
          expect="Review on the App Store is compiled in (Debug)", args=[*other, "Debug", *arranged_args])
    check(review_app(root, "review-Release-arranged", feature, arranged_info), passes=False,
          expect="only Debug takes the arrangement", args=[*other, "Release", *arranged_args])
    check(review_app(root, "review-Release-arranged-absent", clean, app_info(), table=False), passes=False,
          expect="only Debug takes the arrangement", args=[*other, "Release", *arranged_args])

    # The local identifier's digits are in no file of a bundle that does not name it, and the check
    # never prints them. Bytes anywhere count, with or without the leading "id".
    digits = identifier[2:]
    leaky = build(root, "review-leaky", f'const char *fixture(void) {{ return "{identifier}"; }}\n')
    leaky_digits = build(root, "review-leaky-digits", f'const char *fixture(void) {{ return "{digits}"; }}\n')
    data_file = review_app(root, "review-leak-data", clean, app_info(), table=False)
    (data_file / "Data.bin").write_bytes(b"\0\1" + digits.encode() + b"\2")
    nested = review_app(root, "review-leak-nested", clean, app_info(), table=False)
    (nested / "en.lproj").mkdir()
    (nested / "en.lproj" / "InfoPlist.strings").write_bytes(f'"CFBundleName" = "{identifier}";\n'.encode())
    straddle = review_app(root, "review-leak-straddle", clean, app_info(), table=False)
    (straddle / "Big.bin").write_bytes(b"\0" * ((8 << 20) - 5) + digits.encode() + b"\0")
    leaks = (
        ("executable", review_app(root, "review-leak-executable", leaky, app_info(), table=False), "Fixture"),
        ("digits", review_app(root, "review-leak-digits", leaky_digits, app_info(), table=False), "Fixture"),
        ("framework", review_app(root, "review-leak-framework", clean, app_info(), table=False, framework=leaky),
         "Frameworks/Runtime.framework/Runtime"),
        ("info-plist", review_app(root, "review-leak-info", clean, review_info, table=False), "Info.plist"),
        ("data-file", data_file, "Data.bin"),
        ("nested-file", nested, "en.lproj/InfoPlist.strings"),
        ("straddle", straddle, "Big.bin"),
    )
    for name, app, path in leaks:
        for configuration in ("Debug", "Release"):
            for arguments in (local_args, [*local_args, *arranged_args]):
                check(app, passes=False, expect=f"{path}: holds the App Store identifier of the local configuration",
                      never=digits, args=[*other, configuration, *arguments])
        check(app, passes=False, expect=f"{path}: holds the App Store identifier of the local configuration",
              never=digits, args=local_args)
    check(review_app(root, "review-leak-none", clean, app_info(), table=False, framework=clean), passes=True,
          expect="ready for the App Store", args=local_args)
    check(review_app(root, "review-leak-none-debug", clean, app_info(), table=False), passes=True,
          expect="Review on the App Store is not compiled in (Debug)", args=[*other, "Debug", *local_args])
    check(review_app(root, "review-leak-none-arranged", feature, arranged_info), passes=True,
          expect="Review on the App Store is compiled in (Debug)", args=[*other, "Debug", *local_args, *arranged_args])
    # An App Store build that names it holds it in Info.plist, and nowhere else.
    check(review_app(root, "review-leak-named", feature, review_info), passes=True,
          expect="Review on the App Store is compiled in", args=named_args)
    named_leak = review_app(root, "review-leak-named-elsewhere", feature, review_info)
    (named_leak / "Data.bin").write_bytes(digits.encode())
    check(named_leak, passes=True, expect="Review on the App Store is compiled in", args=named_args)

    # The digits as a binary stores a string besides UTF-8.
    for form, content in encoded_forms(digits):
        stray = review_app(root, f"review-leak-{form}", clean, app_info(), table=False)
        (stray / "Data.bin").write_bytes(content)
        for arguments in (local_args, [*other, "Debug", *local_args]):
            check(stray, passes=False, expect="Data.bin: holds the App Store identifier of the local configuration",
                  never=digits, args=arguments)

    # All three features, alone and together: each says its own line and none disturbs another.
    # The fixture sources are renamed so one binary can hold all three.
    all_code = build(
        root, "all-three",
        FEEDBACK_FEATURE + TIP_FEATURE.replace("fixture", "tip_fixture") + REVIEW_FEATURE.replace("fixture", "review_fixture"),
        ["-framework", "MessageUI", "-framework", "StoreKit"])
    all_info = app_info(**{**feedback_info, "AndariumTipProducts": tip_info["AndariumTipProducts"],
                           "AndariumReviewID": identifier})
    everything = review_app(root, "all-named", all_code, all_info)
    for language in ("en", "ja", "zh-Hans", "zh-Hant"):
        (everything / f"{language}.lproj" / "TipJar.strings").write_bytes(
            plistlib.dumps({"Buy me tokens": "x"}, fmt=plistlib.FMT_BINARY))
    for line in ("Send feedback is compiled in", "Buy me tokens is compiled in", "Review on the App Store is compiled in"):
        check(everything, passes=True, expect=line, args=[*feedback_appstore, *tip_named, *named_args])
    # The one that is not named cannot ride in another's product.
    check(review_app(root, "all-review-in-feedback", all_code, app_info(**feedback_info), table=False,
                     ), passes=False, expect="carries Review on the App Store", args=feedback_appstore)
    check(review_app(root, "all-review-in-tip", all_code, tip_info, table=False), passes=False,
          expect="carries Review on the App Store", args=tip_named)
    check(review_app(root, "all-tip-in-review", all_code, review_info), passes=False,
          expect="carries Buy me tokens", args=named_args)
    check(review_app(root, "all-feedback-in-review", all_code, review_info), passes=False,
          expect="carries Send feedback", args=named_args)
    check(review_app(root, "all-none", clean, app_info(), table=False), passes=True, expect="ready for the App Store",
          args=[*local_args])
    # Debug takes the three arrangements together.
    arranged_all = app_info(
        AndariumFeedbackAddress="feedback@example.com", AndariumReviewID=arranged,
        AndariumTipProducts={tier: f"com.example.andarium.tip.{tier}" for tier in ("lite", "pro", "max", "ultra")})
    check(review_app(root, "all-Debug-arranged", all_code, arranged_all), passes=True,
          expect="Review on the App Store is compiled in (Debug)", args=[*other, "Debug", *arranged_args])


def check_developer(root: Path, check, clean: Path) -> None:
    """The tip header's developer: its Info.plist keys and its assets are in the product exactly
    where the build names the value, and no artwork file or local profile address is in any
    other place. Every value and file here is made up."""
    ids = {tier: f"com.fixture.product.{tier}" for tier in ("lite", "pro", "max", "ultra")}
    named = ",".join(ids.values())
    tip = ["--tip-products", named, "--tip-local-products", named]
    handles = ["--developer-local-github", "fixturehub", "--developer-x-handle", "fixturex"]
    values = ["--developer-name", "Fixture Name", "--developer-github", "fixturehub", "--developer-x", "fixturex"]
    feature = build(root, "developer-feature", TIP_FEATURE, ["-framework", "StoreKit"])
    profile = build(root, "developer-profile", FOLLOW_X_PROFILE_ONLY, ["-framework", "StoreKit"])
    info = app_info(AndariumTipProducts=ids, AndariumDeveloperName="Fixture Name",
                    AndariumDeveloperGitHub="fixturehub", AndariumDeveloperX="fixturex")
    name_info = app_info(AndariumTipProducts=ids, AndariumDeveloperName="Fixture Name")
    # The tip's strings tables come with the feature, which the Info.plist key stands for here;
    # the header's X button brings the profile address's builder, and a product without a value
    # of X is the same code without it.

    def developer_app(name: str, info: dict, executable: Path = profile, **options) -> Path:
        return tip_app(root, name, executable, info, table="AndariumTipProducts" in info, **options)

    appstore = [*tip, *handles]
    check(developer_app("dev-built", info), passes=True,
          expect="Buy me tokens is compiled in", args=[*appstore, *values])
    # Each piece follows its value: no handle, no mark; no name, no avatar; no X, no logo.
    check(developer_app("dev-name-only", name_info, feature), passes=True,
          expect="Buy me tokens is compiled in", args=[*appstore, "--developer-name", "Fixture Name"])
    check(developer_app("dev-github-only", app_info(AndariumTipProducts=ids, AndariumDeveloperGitHub="fixturehub"),
                        feature), passes=True,
          expect="Buy me tokens is compiled in", args=[*appstore, "--developer-github", "fixturehub"])
    x_only = developer_app("dev-x-only", app_info(AndariumTipProducts=ids, AndariumDeveloperX="fixturex"))
    check(x_only, passes=True, expect="Follow developer on X is not compiled in",
          args=[*appstore, "--developer-x", "fixturex"])
    check(developer_app("dev-none-named", app_info(AndariumTipProducts=ids), feature), passes=True,
          expect="Buy me tokens is compiled in", args=appstore)
    # The header's X button is not the row: the handle of the row is not the header's.
    check(x_only, passes=False, expect="has AndariumDeveloperX though the build names no such developer value",
          args=[*appstore, "--follow-x-handle", "fixturex"])

    # A key, an asset or a piece of code that does not match the build.
    check(developer_app("dev-no-key", app_info(AndariumTipProducts=ids, AndariumDeveloperName="Fixture Name",
                                               AndariumDeveloperX="fixturex")),
          passes=False, expect="AndariumDeveloperGitHub must be the developer value", args=[*appstore, *values])
    check(developer_app("dev-other-key", app_info(**{**info, "AndariumDeveloperName": "Someone Else"})),
          passes=False, expect="AndariumDeveloperName must be the developer value", args=[*appstore, *values])
    check(developer_app("dev-unnamed-key", info), passes=False,
          expect="has AndariumDeveloperX though the build names no such developer value",
          args=[*appstore, "--developer-name", "Fixture Name", "--developer-github", "fixturehub"])
    check(developer_app("dev-no-avatar", info, assets={"DeveloperAvatar": False}), passes=False,
          expect="Assets.car: lacks DeveloperAvatar", args=[*appstore, *values])
    check(developer_app("dev-no-mark", info, assets={"GitHubLogo": False}), passes=False,
          expect="Assets.car: lacks GitHubLogo", args=[*appstore, *values])
    check(developer_app("dev-no-x-logo", info, assets={"XLogo": False}), passes=False,
          expect="Assets.car: lacks the logo of Follow developer on X", args=[*appstore, *values])
    check(developer_app("dev-no-profile", info, feature), passes=False,
          expect="lacks the profile address's builder", args=[*appstore, *values])
    check(developer_app("dev-avatar-unnamed", app_info(AndariumTipProducts=ids), feature,
                        assets={"DeveloperAvatar": True}), passes=False,
          expect="Assets.car: holds DeveloperAvatar though the build names no developer name", args=appstore)
    check(developer_app("dev-mark-unnamed", name_info, feature, assets={"GitHubLogo": True}), passes=False,
          expect="Assets.car: holds GitHubLogo though the build names no developer github",
          args=[*appstore, "--developer-name", "Fixture Name"])
    check(developer_app("dev-logo-unnamed", name_info, feature, assets={"XLogo": True}), passes=False,
          expect="Assets.car: holds the logo of Follow developer on X though the build names no handle",
          args=[*appstore, "--developer-name", "Fixture Name"])
    check(developer_app("dev-profile-unnamed", name_info, profile), passes=False,
          expect="carries the profile address's builder", args=[*appstore, "--developer-name", "Fixture Name"])
    # The row's code and key are for the row's handle, not the header's.
    row = build(root, "developer-row", FOLLOW_X_FEATURE + TIP_FEATURE.replace("const char *fixture(void)",
                                                                              "const char *tip_fixture(void)"),
                ["-framework", "StoreKit"])
    check(developer_app("dev-row-code", app_info(AndariumTipProducts=ids, AndariumDeveloperX="fixturex"), row),
          passes=False, expect="carries Follow developer on X", args=[*appstore, "--developer-x", "fixturex"])

    # The handles the local configuration names are handles of GitHub and X, and no placeholder.
    for kind, bad, said in (("github", "-bad-", "not a handle of GitHub"), ("x", "bad handle", "not a handle of X"),
                            ("x", "example_handle", "the placeholder handle")):
        piece = {"github": "AndariumDeveloperGitHub", "x": "AndariumDeveloperX"}[kind]
        check(developer_app(f"dev-bad-{kind}-{len(bad)}", app_info(AndariumTipProducts=ids, **{piece: bad}),
                            feature, assets={"GitHubLogo": kind == "github", "XLogo": False}),
              passes=False, expect=said, args=[*appstore, f"--developer-{kind}={bad}"])

    # No product identifiers: no developer at all, whatever the build says about it.
    check(developer_app("dev-values-no-tip", app_info(AndariumDeveloperName="Fixture Name"), clean),
          passes=False, expect="names developer values though it names no product identifiers", args=values)
    check(developer_app("dev-key-no-tip", app_info(AndariumDeveloperName="Fixture Name"), clean,
                        assets={"DeveloperAvatar": False}),
          passes=False, expect="has AndariumDeveloperName though the build names no such developer value")
    check(developer_app("dev-asset-no-tip", app_info(), clean, assets={"DeveloperAvatar": True}),
          passes=False, expect="Assets.car: holds DeveloperAvatar though the build names no developer name")
    check(developer_app("dev-clean", app_info(), clean), passes=True, expect="ready for the App Store",
          args=handles)

    # Artwork files lie in no bundle, named or not.
    for artwork in ("github-logo.svg", "developer-avatar.jpeg"):
        loose = developer_app(f"dev-loose-{artwork}", info)
        (loose / artwork).write_bytes(b"artwork")
        check(loose, passes=False, expect=f"{artwork}: is artwork of the tip header", args=[*appstore, *values])
        bare = developer_app(f"dev-loose-bare-{artwork}", app_info(), clean)
        (bare / "en.lproj").mkdir(exist_ok=True)
        (bare / "en.lproj" / artwork).write_bytes(b"artwork")
        check(bare, passes=False, expect=f"en.lproj/{artwork}: is artwork of the tip header")

    # The profile addresses of the local handles are in no file of any product.
    for kind, address in (("github", "https://github.com/fixturehub"), ("x", "https://x.com/FixtureX")):
        leaky = build(root, f"dev-address-{kind}", f'const char *fixture(void) {{ return "{address}"; }}\n')
        app = developer_app(f"dev-address-{kind}", app_info(), leaky)
        check(app, passes=False, expect="holds a profile address of the local configuration"
              if kind == "github" else "holds the handle of the local configuration",
              never=address.rpartition("/")[2], args=handles)
        check(app, passes=True, expect="ready for the App Store")
    # The same addresses as a binary stores a string besides UTF-8. An address that goes on (the project's own
    # repository under the account) is another address, in each encoding.
    github = "https://github.com/fixturehub"
    for kind, address, phrase in (("github", github, "holds a profile address of the local configuration"),
                                  ("x", "https://x.com/FixtureX", "holds the handle of the local configuration")):
        for form, content in encoded_forms(address):
            stray = developer_app(f"dev-address-{kind}-{form}", app_info(), clean)
            (stray / "Data.bin").write_bytes(content)
            check(stray, passes=False, expect=f"Data.bin: {phrase}", never=address.rpartition("/")[2], args=handles)
    for index, suffix in enumerate(("/repository", "hub", ".io")):
        for encoding in ("utf-8", "utf-16-le", "utf-16-be"):
            goes_on = developer_app(f"dev-address-goes-on-{encoding}-{index}", app_info(), clean)
            (goes_on / "Data.bin").write_bytes(b"\0" + (github + suffix).encode(encoding) + b"\0")
            check(goes_on, passes=True, expect="ready for the App Store", args=handles)
    # A local handle the build names is the build's to hold.
    check(developer_app("dev-address-named", info, build(
        root, "dev-address-named", 'const char *fixture(void) { return "https://x.com/fixturex"; }\n')),
          passes=False, expect="lacks the profile address's builder", args=[*appstore, *values])

    # The other configurations: nothing, or Debug's arrangement of `example` with the drawn artwork.
    other = ["--tip-jar", "--configuration"]
    arranged_ids = {tier: f"com.example.andarium.tip.{tier}" for tier in ids}
    arranged_tip = ["--tip-products", ",".join(arranged_ids.values())]
    arranged_values = ["--developer-name", "example", "--developer-github", "example", "--developer-x", "example_handle"]
    arranged_info = app_info(AndariumTipProducts=arranged_ids, AndariumDeveloperName="example",
                             AndariumDeveloperGitHub="example", AndariumDeveloperX="example_handle")
    check(developer_app("dev-Debug-arranged", arranged_info), passes=True,
          expect="Buy me tokens is compiled in (Debug)", args=[*other, "Debug", *arranged_tip, *arranged_values, *handles])
    check(developer_app("dev-Debug-tip-only", app_info(AndariumTipProducts=arranged_ids), feature), passes=True,
          expect="Buy me tokens is compiled in (Debug)", args=[*other, "Debug", *arranged_tip])
    check(developer_app("dev-Debug-tip-only-asset", app_info(AndariumTipProducts=arranged_ids), feature,
                        assets={"GitHubLogo": True}), passes=False,
          expect="Assets.car: holds GitHubLogo", args=[*other, "Debug", *arranged_tip])
    # Only Debug takes the arrangement at all, so Release names no usable identifiers either.
    for configuration, said in (("Debug", "not the arranged placeholders"),
                                ("Release", "names developer values though it names no product identifiers")):
        check(developer_app(f"dev-{configuration}-local-values", info), passes=False,
              expect=said, args=[*other, configuration, *arranged_tip, *values])
    for configuration in ("Debug", "Release"):
        check(developer_app(f"dev-{configuration}-absent", app_info(), clean), passes=True,
              expect="Buy me tokens is not compiled in", args=[*other, configuration, *handles])
        check(developer_app(f"dev-{configuration}-asset", app_info(), clean, assets={"GitHubLogo": True}),
              passes=False, expect="Assets.car: holds GitHubLogo", args=[*other, configuration])
        check(developer_app(f"dev-{configuration}-key", app_info(AndariumDeveloperX="example_handle"), clean,
                            assets={"XLogo": False}),
              passes=False, expect="has AndariumDeveloperX though the build names no such developer value",
              args=[*other, configuration])
    check(developer_app("dev-Release-arranged", arranged_info), passes=False,
          expect="only Debug takes the arrangement",
          args=[*other, "Release", *arranged_tip, *arranged_values])


def check_icp(root: Path, check, clean: Path) -> None:
    """The ICP filing number is in the product exactly where the build names it, in either
    direction and alone, and the local number is in no other file. Every number here is made up."""
    number = "示例ICP备12345678号-1"
    placeholder = "示例ICP备00000000号-0A"
    feature = build(root, "icp-feature", ICP_FEATURE)
    partial = build(root, "icp-partial", ICP_PARTIAL)
    named = ["--icp-number", number, "--icp-local-number", number]
    local = ["--icp-local-number", number]
    other = ["--icp", "--configuration"]
    info = app_info(AndariumICPNumber=number)

    # With the number: the code, the key and the filing site's host, and the number the build named.
    check(make_app(root, "icp-built", feature, info), passes=True,
          expect="ICP filing number is compiled in", args=named)
    check(make_app(root, "icp-absent", clean, app_info()), passes=True,
          expect="ICP filing number is not compiled in", args=local)
    check(make_app(root, "icp-no-key", feature, app_info()), passes=False,
          expect="AndariumICPNumber must be the number the build names", args=named)
    check(make_app(root, "icp-other-key", feature, app_info(AndariumICPNumber="示例ICP备99999999号-1")),
          passes=False, expect="must be the number the build names", never="99999999", args=named)
    check(make_app(root, "icp-not-built", clean, info), passes=False,
          expect="lacks the ICP filing number", args=named)
    check(make_app(root, "icp-partial", partial, info), passes=False,
          expect="lacks the ICP filing number (ICPFiling, beian.miit.gov.cn)", args=named)
    # The switch is its own: the other features are absent from a product with only the number.
    check(make_app(root, "icp-alone", feature, info), passes=True, expect="Buy me tokens is not compiled in",
          args=named)

    # No number, so nothing of it: not the code, not the key.
    check(make_app(root, "icp-code-without", feature, app_info()), passes=False,
          expect="carries the ICP filing number (", args=local)
    check(make_app(root, "icp-key-without", clean, info), passes=False,
          expect="has AndariumICPNumber though the build names no number")
    check(make_app(root, "icp-framework-without", clean, app_info(), framework=feature), passes=False,
          expect="Runtime.framework/Runtime: carries the ICP filing number")

    # The number is in Info.plist and in no other file; the local one is in no file of a product that
    # does not name it, however it is stored.
    elsewhere = make_app(root, "icp-elsewhere", feature, info)
    (elsewhere / "Data.bin").write_bytes(number.encode())
    check(elsewhere, passes=False, expect="Data.bin: holds the filing number outside Info.plist",
          never="12345678", args=named)
    in_plist = make_app(root, "icp-elsewhere-plist", feature, info)
    (in_plist / "Other.plist").write_bytes(plistlib.dumps({"Note": number}, fmt=plistlib.FMT_BINARY))
    check(in_plist, passes=False, expect="Other.plist: holds the filing number outside Info.plist",
          never="12345678", args=named)
    for form, content in (("utf8", number.encode()), ("utf16", number.encode("utf-16-le")),
                          ("plist", plistlib.dumps({"Note": number}, fmt=plistlib.FMT_BINARY)),
                          ("xml", plistlib.dumps({"Note": number}, fmt=plistlib.FMT_XML))):
        leak = make_app(root, f"icp-leak-{form}", clean, app_info())
        (leak / "Data.bin").write_bytes(b"\0" + content + b"\0")
        check(leak, passes=False, expect="Data.bin: holds the filing number of the local configuration",
              never="12345678", args=local)
        check(leak, passes=True, expect="ready for the App Store")
    check(make_app(root, "icp-leak-key", clean, info), passes=False,
          expect="Info.plist: holds the filing number of the local configuration", never="12345678", args=local)

    # The shape of the number in the local configuration.
    for index, bad in enumerate(("has a space", "a/b", "tab\there", "x" * 101, placeholder)):
        check(make_app(root, f"icp-shape-{index}", feature, app_info(AndariumICPNumber=bad)), passes=False,
              expect="ICP filing number: the number in the local configuration", args=["--icp-number", bad])
    check(make_app(root, "icp-shape-ok", feature, app_info(AndariumICPNumber="京ICP备12345678号")), passes=True,
          expect="ICP filing number is compiled in", args=["--icp-number", "京ICP备12345678号"])

    # The other configurations: absent, or the placeholder, which Debug alone takes.
    arranged = ["--icp-number", placeholder]
    arranged_info = app_info(AndariumICPNumber=placeholder)
    for configuration in ("Debug", "Release"):
        check(make_app(root, f"icp-{configuration}-absent", clean, app_info()), passes=True,
              expect=f"ICP filing number is not compiled in ({configuration})",
              args=[*other, configuration, *local])
        # The local configuration's number never reaches them.
        check(make_app(root, f"icp-{configuration}-number", feature, info), passes=False,
              expect="not the arranged placeholder", never="12345678", args=[*other, configuration, *named])
        check(make_app(root, f"icp-{configuration}-code", feature, app_info()), passes=False,
              expect="carries the ICP filing number", args=[*other, configuration])
        check(make_app(root, f"icp-{configuration}-key", clean, info), passes=False,
              expect="though the build names no number", args=[*other, configuration])
    check(make_app(root, "icp-Debug-arranged", feature, arranged_info), passes=True,
          expect="ICP filing number is compiled in (Debug)", args=[*other, "Debug", *arranged])
    # A development build's test bundle holds the placeholder in its tests.
    with_tests = make_app(root, "icp-Debug-arranged-tests", feature, arranged_info)
    (with_tests / "PlugIns").mkdir()
    (with_tests / "PlugIns" / "Tests").write_bytes(b"\0" + placeholder.encode() + b"\0")
    check(with_tests, passes=True, expect="ICP filing number is compiled in (Debug)",
          args=[*other, "Debug", *arranged])
    check(make_app(root, "icp-Release-arranged", feature, arranged_info), passes=False,
          expect="only Debug takes the arrangement", args=[*other, "Release", *arranged])
    check(make_app(root, "icp-Release-arranged-absent", clean, app_info()), passes=False,
          expect="only Debug takes the arrangement", args=[*other, "Release", *arranged])
    check(make_app(root, "icp-appstore-arranged", feature, arranged_info), passes=False,
          expect="is the placeholder", args=arranged)
    # The placeholder is in no product that does not arrange it, stored either way.
    for form, content in (("utf8", placeholder.encode()),
                          ("plist", plistlib.dumps({"Note": placeholder}, fmt=plistlib.FMT_BINARY))):
        stray = make_app(root, f"icp-placeholder-{form}", clean, app_info())
        (stray / "Data.bin").write_bytes(content)
        check(stray, passes=False, expect="Data.bin: holds the placeholder filing number of the arrangement")
        check(stray, passes=False, expect="Data.bin: holds the placeholder filing number of the arrangement",
              args=[*other, "Debug"])
    check(make_app(root, "icp-placeholder-key", clean, arranged_info), passes=False,
          expect="Info.plist: holds the placeholder filing number of the arrangement")

    # Config/Info.plist keeps every other value whichever way the number's block went.
    source = root / "Info.plist.icp-source"
    source.write_text(INFO_SOURCE, encoding="utf-8")
    base = {"UIApplicationSceneManifest": {"UISceneConfigurations": {"Role": [
        {"UISceneConfigurationName": "Fixture", "UISceneDelegateClassName": "Fixture.SceneDelegate"}]}}}
    check(make_app(root, "icp-source-Debug", feature, app_info(AndariumICPNumber=placeholder, **base)), passes=True,
          expect="ICP filing number is compiled in (Debug)",
          args=[*other, "Debug", *arranged, "--info-source", str(source)])
    check(make_app(root, "icp-source-appstore", feature, app_info(AndariumICPNumber=number, **base)), passes=True,
          expect="ready for the App Store", args=[*named, "--info-source", str(source)])
    check(make_app(root, "icp-source-absent", clean, app_info(**base)), passes=True,
          expect="ICP filing number is not compiled in (Release)",
          args=[*other, "Release", "--info-source", str(source)])


def check_testflight(root: Path, check, clean: Path, feedback_feature: Path, receiver: str) -> None:
    """The TestFlight configuration is held to the App Store's rules, and carries none of Buy me
    tokens, Review on the App Store (with its rating prompt) and the ICP filing number, in code,
    texts, keys, header pieces and artwork, whatever the local configuration holds; it has Send
    feedback and Follow developer on X as the App Store does. Every value here is made up."""
    flag = ["--configuration", "TestFlight"]
    ids = {tier: f"com.fixture.product.{tier}" for tier in ("lite", "pro", "max", "ultra")}
    tip_list = ",".join(ids.values())
    identifier = "id1234567890"
    number = "示例ICP备12345678号-1"
    handle = "someone_real"
    secret = ids["pro"]
    # What the phases pass for the local configuration's own values, which a build of the App Store
    # would name and a build of TestFlight leaves out.
    local = ["--tip-local-products", tip_list, "--review-local-id", identifier, "--icp-local-number", number,
             "--developer-local-github", "fixturehub"]
    tip_code = build(root, "tf-tip", TIP_FEATURE, ["-framework", "StoreKit"])
    review_code = build(root, "tf-review", REVIEW_FEATURE)
    icp_code = build(root, "tf-icp", ICP_FEATURE)
    profile = build(root, "tf-profile", FOLLOW_X_PROFILE_ONLY, ["-framework", "StoreKit"])
    both = build(root, "tf-both", FEEDBACK_FEATURE + FOLLOW_X_FEATURE.replace("fixture", "x_fixture"),
                 ["-framework", "MessageUI"])
    no_tip = "Buy me tokens"
    named = {"feedback": ["--feedback-address", receiver, "--feedback-receiver", receiver],
             "follow-x": ["--follow-x-handle", handle, "--developer-x-handle", handle]}

    # A product with none of the three passes, with the local values passed in or not; with Send
    # feedback and Follow developer on X it passes too, and says so.
    check(make_app(root, "tf-clean", clean, app_info()), passes=True, expect="ready for TestFlight", args=flag)
    check(make_app(root, "tf-clean-local", clean, app_info()), passes=True, expect="ready for TestFlight",
          args=[*flag, *local])
    for line in ("Buy me tokens is not compiled in", "Review on the App Store is not compiled in",
                 "ICP filing number is not compiled in", "document pickers open the files in place"):
        check(make_app(root, f"tf-clean-{line.split()[0]}", clean, app_info()), passes=True, expect=line,
              args=[*flag, *local])
    both_info = app_info(AndariumFeedbackAddress=receiver, AndariumFollowXHandle=handle)
    check(make_app(root, "tf-both-features", both, both_info), passes=True,
          expect="Send feedback is compiled in", args=[*flag, *named["feedback"], *named["follow-x"], *local])
    check(make_app(root, "tf-both-features-ready", both, both_info), passes=True,
          expect="Follow developer on X is compiled in",
          args=[*flag, *named["feedback"], *named["follow-x"], *local])
    # The receiver and the handle follow the App Store's rules: no placeholder, no other value.
    check(make_app(root, "tf-placeholder-receiver", feedback_feature, app_info(AndariumFeedbackAddress="a@example.com")),
          passes=False, expect="placeholder address", args=[*flag, "--feedback-address", "a@example.com"])
    check(make_app(root, "tf-placeholder-handle", both, app_info(AndariumFollowXHandle="example_handle")),
          passes=False, expect="the placeholder handle", args=[*flag, "--follow-x-handle", "example_handle"])
    # The rest of the App Store's rules apply as they do there.
    knob = build(root, "tf-knob", KNOB)
    check(make_app(root, "tf-knob", knob, app_info()), passes=False, expect="automation knob", args=flag)
    jit = make_app(root, "tf-jit", clean, app_info())
    (jit / "ja.lproj").mkdir()
    (jit / "ja.lproj" / "JIT.strings").write_bytes(plistlib.dumps({"Preparing JIT": "x"}, fmt=plistlib.FMT_BINARY))
    check(jit, passes=False, expect="the JIT strings table", args=flag)
    copying = build(root, "tf-copying", CLEAN, pickers="".join(source for _what, source in COPY_PICKERS))
    check(make_app(root, "tf-copy-pickers", copying, app_info()), passes=False,
          expect="the TestFlight configuration opens files in place", args=flag)
    check(make_app(root, "tf-no-manifest", clean, app_info(), manifest=False), passes=False,
          expect="PrivacyInfo.xcprivacy", args=flag)

    # Buy me tokens: not the code, the key, the strings table, a word of it, a header piece or its
    # artwork, and no identifier the build names.
    check(tip_app(root, "tf-tip-code", tip_code, app_info(), table=False), passes=False,
          expect=f"carries {no_tip} (", args=flag)
    check(tip_app(root, "tf-tip-code-reason", tip_code, app_info(), table=False), passes=False,
          expect=f"though TestFlight has no {no_tip}", args=flag)
    check(tip_app(root, "tf-tip-framework", clean, app_info(), table=False, framework=tip_code), passes=False,
          expect=f"Runtime.framework/Runtime: carries {no_tip}", args=flag)
    check(tip_app(root, "tf-tip-key", clean, app_info(AndariumTipProducts=ids), table=False), passes=False,
          expect=f"Info.plist: has AndariumTipProducts though TestFlight has no {no_tip}", never=secret, args=flag)
    check(tip_app(root, "tf-tip-table", clean, app_info()), passes=False,
          expect=f"is the TipJar strings table though TestFlight has no {no_tip}", args=flag)
    words = make_app(root, "tf-tip-words", clean, app_info())
    (words / "en.lproj").mkdir()
    (words / "en.lproj" / "Localizable.strings").write_bytes(
        plistlib.dumps({no_tip: no_tip}, fmt=plistlib.FMT_BINARY))
    check(words, passes=False, expect=f"has {no_tip} strings though TestFlight has no {no_tip}", args=flag)
    # The identifiers named for the build, with or without the product that goes with them.
    for name, app in (("complete", tip_app(root, "tf-tip-named-complete", tip_code, app_info(AndariumTipProducts=ids))),
                      ("empty", make_app(root, "tf-tip-named-empty", clean, app_info()))):
        check(app, passes=False, expect="TestFlight names product identifiers; only the AppStore configuration has "
              f"{no_tip}", never=secret, args=[*flag, "--tip-products", tip_list, "--tip-local-products", tip_list])
    # The header's developer: a value the build names, its Info.plist key, its assets, its artwork.
    check(make_app(root, "tf-header-named", clean, app_info()), passes=False,
          expect=f"names developer values though TestFlight has no {no_tip}",
          args=[*flag, "--developer-name", "Fixture Name"])
    for key, value, asset in (("AndariumDeveloperName", "Fixture Name", "DeveloperAvatar"),
                              ("AndariumDeveloperGitHub", "fixturehub", "GitHubLogo")):
        check(make_app(root, f"tf-header-key-{key}", clean, app_info(**{key: value}), assets={asset: False}),
              passes=False, expect=f"Info.plist: has {key} though TestFlight has no {no_tip}", args=flag)
        check(make_app(root, f"tf-header-asset-{asset}", clean, app_info(), assets={asset: True}), passes=False,
              expect=f"Assets.car: holds {asset} though TestFlight has no {no_tip}", args=flag)
    check(make_app(root, "tf-header-x", clean, app_info(AndariumDeveloperX="fixturex"), follow_x_logo=False),
          passes=False, expect=f"Info.plist: has AndariumDeveloperX though TestFlight has no {no_tip}", args=flag)
    # The header's X button without the row: the profile address's builder is the sheet's, not the row's.
    check(tip_app(root, "tf-header-profile", profile, app_info(), table=False), passes=False,
          expect="carries", args=flag)
    for artwork in ("github-logo.svg", "developer-avatar.jpeg"):
        loose = make_app(root, f"tf-header-file-{artwork}", clean, app_info())
        (loose / artwork).write_bytes(b"artwork")
        check(loose, passes=False, expect=f"{artwork}: is artwork of the tip header", args=flag)

    # Review on the App Store, with the rating prompt: not the code, the key, the table, its words,
    # and no identifier the build names.
    check(review_app(root, "tf-review-code", review_code, app_info(), table=False), passes=False,
          expect="carries Review on the App Store (", args=flag)
    check(review_app(root, "tf-review-code-reason", review_code, app_info(), table=False), passes=False,
          expect="though TestFlight has no Review on the App Store", args=flag)
    check(review_app(root, "tf-review-key", clean, app_info(AndariumReviewID=identifier), table=False), passes=False,
          expect="Info.plist: has AndariumReviewID though TestFlight has no Review on the App Store",
          never="1234567890", args=flag)
    check(review_app(root, "tf-review-table", clean, app_info()), passes=False,
          expect="is the Review strings table though TestFlight has no Review on the App Store", args=flag)
    words = make_app(root, "tf-review-words", clean, app_info())
    (words / "en.lproj").mkdir()
    (words / "en.lproj" / "Localizable.strings").write_bytes(
        plistlib.dumps({"Review on the App Store": "x"}, fmt=plistlib.FMT_BINARY))
    check(words, passes=False,
          expect="has Review on the App Store strings though TestFlight has no Review on the App Store", args=flag)
    for name, app in (("complete", review_app(root, "tf-review-named-complete", review_code,
                                              app_info(AndariumReviewID=identifier))),
                      ("empty", make_app(root, "tf-review-named-empty", clean, app_info()))):
        check(app, passes=False, expect="TestFlight names an identifier; only the AppStore configuration has "
              "Review on the App Store", never="1234567890",
              args=[*flag, "--review-id", identifier, "--review-local-id", identifier])

    # The rating prompt and the storefront watch are each a detection of their own: a product with
    # only one of them, none of the feature's link, key or number, is rejected.
    prompt_only = build(root, "tf-rating-prompt-only", RATING_PROMPT_ONLY)
    check(make_app(root, "tf-rating-prompt-only", prompt_only, app_info()), passes=False,
          expect="carries Review on the App Store (ReviewAsk, ReviewAskTracker, requestReview) though TestFlight has no Review",
          args=flag)
    storefront_only = build(root, "tf-icp-storefront-only", ICP_STOREFRONT_ONLY)
    check(make_app(root, "tf-icp-storefront-only", storefront_only, app_info()), passes=False,
          expect="carries the ICP filing number (ICPStorefront) though TestFlight has no ICP filing number",
          args=flag)

    # The ICP filing number: not the code, the key, and no number the build names.
    check(make_app(root, "tf-icp-code", icp_code, app_info()), passes=False,
          expect="carries the ICP filing number (", args=flag)
    check(make_app(root, "tf-icp-code-reason", icp_code, app_info()), passes=False,
          expect="though TestFlight has no ICP filing number", args=flag)
    check(make_app(root, "tf-icp-key", clean, app_info(AndariumICPNumber=number)), passes=False,
          expect="Info.plist: has AndariumICPNumber though TestFlight has no ICP filing number",
          never="12345678", args=flag)
    for name, app in (("complete", make_app(root, "tf-icp-named-complete", icp_code, app_info(AndariumICPNumber=number))),
                      ("empty", make_app(root, "tf-icp-named-empty", clean, app_info()))):
        check(app, passes=False, expect="TestFlight names a number; only the AppStore configuration has the "
              "ICP filing number", never="12345678", args=[*flag, "--icp-number", number, "--icp-local-number", number])

    # The local configuration's values are in no file of a TestFlight bundle, however stored, and
    # the check never prints one.
    leaky = build(root, "tf-leaky", f'const char *fixture(void) {{ return "{secret}"; }}\n')
    check(make_app(root, "tf-leak-tip-executable", leaky, app_info()), passes=False,
          expect="Fixture: holds a product identifier of the local configuration", never=secret, args=[*flag, *local])
    for form, content in encoded_forms(secret):
        stray = make_app(root, f"tf-leak-tip-{form}", clean, app_info())
        (stray / "Data.bin").write_bytes(content)
        check(stray, passes=False, expect="Data.bin: holds a product identifier of the local configuration",
              never=secret, args=[*flag, *local])
    in_plist = make_app(root, "tf-leak-tip-info", clean, app_info(Note=secret))
    check(in_plist, passes=False, expect="Info.plist: holds a product identifier of the local configuration",
          never=secret, args=[*flag, *local])
    one = make_app(root, "tf-leak-tip-last", clean, app_info())
    (one / "Data.bin").write_bytes(ids["ultra"].encode())
    check(one, passes=False, expect="Data.bin: holds a product identifier of the local configuration",
          never=ids["ultra"], args=[*flag, *local])
    for kind, content, phrase, never in (
            ("review", identifier[2:].encode(), "Data.bin: holds the App Store identifier of the local configuration",
             identifier[2:]),
            ("icp", number.encode(), "Data.bin: holds the filing number of the local configuration", "12345678"),
            ("icp-plist", plistlib.dumps({"Note": number}, fmt=plistlib.FMT_BINARY),
             "Data.bin: holds the filing number of the local configuration", "12345678"),
            ("github", b"https://github.com/fixturehub", "Data.bin: holds a profile address of the local configuration",
             "fixturehub")):
        stray = make_app(root, f"tf-leak-{kind}", clean, app_info())
        (stray / "Data.bin").write_bytes(b"\0" + content + b"\0")
        check(stray, passes=False, expect=phrase, never=never, args=[*flag, *local])
        # The same product without the value to look for is clean.
        check(stray, passes=True, expect="ready for TestFlight", args=flag)

    # The phases of the other configurations, run for TestFlight, judge the same.
    for mode, source, said in (("--tip-jar", tip_code, f"carries {no_tip}"),
                               ("--review", review_code, "carries Review on the App Store"),
                               ("--icp", icp_code, "carries the ICP filing number")):
        check(make_app(root, f"tf-mode-{mode[2:]}-clean", clean, app_info()), passes=True,
              expect="not compiled in (TestFlight)", args=[mode, *flag])
        check(make_app(root, f"tf-mode-{mode[2:]}-code", source, app_info()), passes=False, expect=said,
              args=[mode, *flag])


def check_whole_bundle(root: Path, check, clean: Path) -> None:
    """What a feature must not leave is looked for in the whole bundle: the supplied values in every
    file in either UTF-16 byte order, the staged system image included; the strings tables, property
    list keys and asset names in nested bundles, any property list and any asset catalog; and no
    line of the report spells a supplied value, not even a path. TestFlight is the strictest, the
    App Store holds the same for what it does not carry. Every value here is made up."""
    flag = ["--configuration", "TestFlight"]
    ids = {tier: f"com.fixture.product.{tier}" for tier in ("lite", "pro", "max", "ultra")}
    tip_list = ",".join(ids.values())
    identifier = "id1234567890"
    number = "示例ICP备12345678号-1"
    local = ["--tip-local-products", tip_list, "--review-local-id", identifier, "--icp-local-number", number,
             "--developer-local-github", "fixturehub"]
    values = (("tip", ids["pro"], "a product identifier of the local configuration"),
              ("review", identifier[2:], "the App Store identifier of the local configuration"),
              ("icp", number, "the filing number of the local configuration"))

    # The supplied values in both UTF-16 byte orders (and UTF-8), under the staged system image and
    # outside it, for TestFlight and the App Store (which carries none of them here).
    for configuration_args in (flag, []):
        label = "tf" if configuration_args else "as"
        for kind, value, said in values:
            for encoding in ("utf-8", "utf-16-le", "utf-16-be"):
                for place in ("andarium-system/guest/system.img", "andarium-system/metadata.bin", "Data.bin"):
                    app = make_app(root, f"whole-{label}-{kind}-{encoding}-{place.replace('/', '-')}", clean, app_info())
                    (app / place).parent.mkdir(parents=True, exist_ok=True)
                    (app / place).write_bytes(b"\0" + value.encode(encoding) + b"\0")
                    check(app, passes=False, expect=f"{place}: holds {said}", never=value,
                          args=[*configuration_args, *local])
    unrelated = make_app(root, "whole-image-unrelated", clean, app_info())
    (unrelated / "andarium-system").mkdir()
    (unrelated / "andarium-system" / "metadata.bin").write_bytes(b"\0" + "unrelated".encode("utf-16-le") + b"\0")
    check(unrelated, passes=True, expect="ready for TestFlight", args=[*flag, *local])

    # Resources of the three features in nested bundles, in any property list and in any asset
    # catalog, are as much a leak as the same at the root. The tables and keys are the features' own.
    for name, path, data, said in (
            ("tip-table", "Feature.bundle/ja.lproj/TipJar.strings", plistlib.dumps({"Done": "x"}),
             "Feature.bundle/ja.lproj/TipJar.strings: is the TipJar strings table though TestFlight has no Buy me tokens"),
            ("tip-words", "Feature.bundle/en.lproj/Localizable.strings",
             plistlib.dumps({"Buy me tokens": "Buy me tokens"}, fmt=plistlib.FMT_BINARY),
             "Feature.bundle/en.lproj/Localizable.strings: has Buy me tokens strings though TestFlight has no Buy me tokens"),
            ("review-table", "Feature.bundle/ja.lproj/Review.strings", plistlib.dumps({"Done": "x"}),
             "Feature.bundle/ja.lproj/Review.strings: is the Review strings table though TestFlight has no Review"),
            ("review-words", "Feature.bundle/en.lproj/Localizable.strings",
             plistlib.dumps({"Review on the App Store": "x"}, fmt=plistlib.FMT_BINARY),
             "Feature.bundle/en.lproj/Localizable.strings: has Review on the App Store strings though TestFlight has no Review"),
            ("tip-key", "Extra.plist", plistlib.dumps({"AndariumTipProducts": ids}),
             "Extra.plist: has AndariumTipProducts though TestFlight has no Buy me tokens"),
            ("review-key", "Feature.bundle/Info.plist", plistlib.dumps({"AndariumReviewID": identifier}),
             "Feature.bundle/Info.plist: has AndariumReviewID though TestFlight has no Review"),
            ("icp-key", "Plug.appex/Info.plist", plistlib.dumps({"AndariumICPNumber": number}),
             "Plug.appex/Info.plist: has AndariumICPNumber though TestFlight has no ICP filing number"),
            ("header-name-key", "Extra.plist", plistlib.dumps({"AndariumDeveloperName": "Fixture Name"}),
             "Extra.plist: has AndariumDeveloperName though TestFlight has no Buy me tokens"),
            ("header-github-key", "Feature.bundle/Extra.plist", plistlib.dumps({"AndariumDeveloperGitHub": "x"}),
             "Feature.bundle/Extra.plist: has AndariumDeveloperGitHub though TestFlight has no Buy me tokens"),
            ("header-x-key", "Extra.plist", plistlib.dumps({"AndariumDeveloperX": "x"}),
             "Extra.plist: has AndariumDeveloperX though TestFlight has no Buy me tokens"),
            ("avatar", "Feature.bundle/Assets.car", b"\0BOMStore\0DeveloperAvatar\0",
             "Feature.bundle/Assets.car: holds DeveloperAvatar though TestFlight has no Buy me tokens"),
            ("mark", "Frameworks/Resources.framework/Assets.car", b"\0BOMStore\0GitHubLogo\0",
             "Frameworks/Resources.framework/Assets.car: holds GitHubLogo though TestFlight has no Buy me tokens"),
    ):
        app = make_app(root, f"whole-nested-{name}", clean, app_info())
        (app / path).parent.mkdir(parents=True, exist_ok=True)
        (app / path).write_bytes(data)
        check(app, passes=False, expect=said, args=flag)
        # A build of the App Store that names none of the feature has the same leak.
        check(app, passes=False, expect=said.split(" though ")[0])
    # The logo of Follow developer on X in a nested catalog, where the build names no handle.
    logo = make_app(root, "whole-nested-x-logo", clean, app_info())
    (logo / "Feature.bundle").mkdir()
    (logo / "Feature.bundle" / "Assets.car").write_bytes(b"\0BOMStore\0XLogo\0")
    check(logo, passes=False,
          expect="Feature.bundle/Assets.car: holds the logo of Follow developer on X though the build names no handle",
          args=flag)
    # A nested bundle with resources of its own, that none of the features owns, passes.
    quiet = make_app(root, "whole-nested-clean", clean, app_info())
    (quiet / "Feature.bundle" / "en.lproj").mkdir(parents=True)
    (quiet / "Feature.bundle" / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "org.example.Feature"}))
    (quiet / "Feature.bundle" / "Assets.car").write_bytes(b"\0BOMStore\0AppIcon\0")
    (quiet / "Feature.bundle" / "en.lproj" / "Localizable.strings").write_bytes(
        plistlib.dumps({"Done": "Done"}, fmt=plistlib.FMT_BINARY))
    (quiet / "Feature.bundle" / "en.lproj" / "Other.strings").write_bytes(
        plistlib.dumps({"Review": "Review"}, fmt=plistlib.FMT_BINARY))
    check(quiet, passes=True, expect="ready for TestFlight", args=[*flag, *local])
    check(quiet, passes=True, expect="ready for the App Store", args=local)

    # A file whose name spells a supplied value is rejected, and neither output holds the value. The
    # files are named for the identifier, the digits of the App Store identifier and the number.
    for kind, value, said in values:
        for configuration_args in (flag, []):
            named = make_app(root, f"whole-name-{kind}-{'tf' if configuration_args else 'as'}", clean, app_info())
            (named / f"{value}.txt").write_bytes(b"\0" + value.encode() + b"\0")
            (named / "Folder").mkdir()
            (named / "Folder" / f"{value.upper()}.bin").write_bytes(b"\0" + value.encode("utf-16-le") + b"\0")
            check(named, passes=False, expect=f"<value>.txt: holds {said}", never=value,
                  args=[*configuration_args, *local])
            check(named, passes=False, expect=f"Folder/<value>.bin: holds {said}", never=value.upper(),
                  args=[*configuration_args, *local])


def check_one_walk(checkers: Checkers, root: Path, clean: Path, failures: list[str]) -> None:
    """A run asks every leak question in one walk over the bundle (a gigabyte with the staged system
    image), whichever phase of the build it is: the run of the App Store, and the phases of the other
    configurations. A question the plan lacks would walk again, which this test counts."""
    module, checker = checkers.module, checkers.script
    walk = module.scan_bundle
    app = make_app(root, "one-walk", clean, app_info())
    values = ["--feedback-receiver", "local@receiver.fixture",
              "--tip-local-products", "one.fixture,two.fixture,three.fixture,four.fixture",
              "--review-local-id", "id4815162342", "--developer-local-github", "fixturehub",
              "--developer-x-handle", "fixturex", "--icp-local-number", "示例ICP备12345678号-1",
              "--icp-number", "示例ICP备87654321号-1"]
    runs = (
        ("the App Store run", values),
        ("the TestFlight run", ["--configuration", "TestFlight", *values[:-2]]),
        ("the feedback, X and ICP phase", ["--configuration", "Debug", "--feedback", "--follow-x", "--icp", *values]),
        ("the tip phase", ["--configuration", "Debug", "--tip-jar", *values]),
        ("the review phase", ["--configuration", "Debug", "--review", *values]),
    )
    for label, arguments in runs:
        walks: list[int] = []

        def counted(path: Path, scans: set, walks: list[int] = walks) -> dict:
            walks.append(len(scans))
            return walk(path, scans)

        module.scan_bundle = counted
        stdout, stderr = io.StringIO(), io.StringIO()
        saved = sys.argv
        sys.argv = [str(checker), *arguments, str(app)]
        try:
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                module.main()
        finally:
            sys.argv = saved
            module.scan_bundle = walk
        if len(walks) != 1:
            failures.append(f"{label}: {len(walks)} walks over the bundle, expected one")
        elif not walks[0]:
            failures.append(f"{label}: the one walk asks nothing")
    # The checks of a framework ask no leak question, so its path is not walked for one.
    walks = []

    def idle(path: Path, scans: set) -> dict:
        walks.append(len(scans))
        return walk(path, scans)

    module.scan_bundle = idle
    sys.argv = [str(checker), "--runtime", *values, str(app)]
    try:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            module.main()
    finally:
        sys.argv = saved
        module.scan_bundle = walk
    if any(walks):
        failures.append("the check of a framework walks its path for a leak")


def check_command_line(checker: Path, checkers: Checkers, root: Path, clean: Path, knob: Path,
                       failures: list[str]) -> None:
    """What only the command owns: its exit status, which stream says what, and its arguments. Every
    other case of this test runs in this process, so each case here runs as the command and in this
    process, and the two must agree."""
    def application(name: str, executable: Path, **options) -> Path:
        fixture = make_app(root, name, executable, app_info(), **options)
        (fixture / APP_STORE_NOTES).write_text("[]", encoding="utf-8")
        return fixture

    ready = application("command-ready", clean, framework=clean)
    refused = application("command-refused", knob)
    # What the case is, its arguments, the status, and a text each of the two streams holds.
    cases = (
        ("a ready application", [str(ready)], 0, "ready for the App Store", ""),
        ("a refused application", [str(refused)], 1, "", "KERNARIUM_HOST_FORWARD"),
        ("a framework alone", ["--runtime", str(ready / "Frameworks" / "Runtime.framework")], 0, "", ""),
        ("a missing application", [str(root / "absent.app")], 1, "", ""),
        ("an unknown option", ["--no-such-option", str(ready)], 2, "", "usage:"),
        ("no application", [], 2, "", "usage:"),
    )
    for what, arguments, status, said, complained in cases:
        command = run_command(checker, arguments)
        if command.returncode != status:
            failures.append(f"the command on {what}: status {command.returncode}, expected {status}:\n"
                            f"{command.err}")
        elif said not in command.out or complained not in command.err:
            failures.append(f"the command on {what}: lacks {said!r} on standard output or "
                            f"{complained!r} on standard error:\n{command.out}{command.err}")
        elif (status == 0) != (not command.err):
            failures.append(f"the command on {what}: standard error is {'empty' if status else 'not empty'} "
                            "where it should not be")
        # The streams of a refusal: the report's lines are on standard output only where it says ready.
        if status == 1 and "ready for" in command.out:
            failures.append(f"the command on {what}: reports it ready and fails")
        here = checkers.run(arguments)
        if here != command:
            failures.append(f"the command on {what} differs from the run in this process:\n"
                            f"command: {command}\nhere: {here}")


def check_exit_values(checkers: Checkers, failures: list[str]) -> None:
    """A checker that ends with a value the shell reads as success must not look like a rejection here
    either: the run in this process ends as a process does, whether the value is returned by `main` or
    raised as `SystemExit`. Each value is run as a process too, and the two must agree."""
    def raised(value):
        def main():
            raise SystemExit(value)
        return main

    for value in (None, 0, 1, 2, 255, 256, 257, -1, True, "refused", 1.5):
        child = subprocess.run(
            [sys.executable, "-B", "-c", f"import sys; sys.exit({value!r})"], check=False,
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=TIMEOUT_SECONDS)
        want = Outcome(child.returncode, "", child.stderr)
        for how, main in (("returned", lambda value=value: value), ("raised", raised(value))):
            got = checkers.call(main, Path("exit-values"), [])
            if got != want:
                failures.append(f"exit value {value!r} {how}: ends as {got}, a process ends as {want}")


def check_examples(root: Path, check, clean: Path, config: Path, failures: list[str]) -> None:
    """The example files' own values are placeholders, and the App Store configuration refuses each
    one of them in the mode that judges it, whatever the other values are. A value added to an
    example file without its refusal here fails the check."""
    ids = [f"com.fixture.product.{tier}" for tier in ("lite", "pro", "max", "ultra")]
    tip = ["--tip-jar", "--tip-products", ",".join(ids)]
    # key -> (the mode's arguments for a value, what the refusal says)
    judged = {
        "DEVELOPER_NAME": (lambda v: [*tip, "--developer-name", v],
                           "the developer name in the local configuration is the placeholder"),
        "DEVELOPER_GITHUB_HANDLE": (lambda v: [*tip, "--developer-github", v],
                                    "the developer github in the local configuration is the placeholder"),
        "DEVELOPER_X_HANDLE": (lambda v: ["--follow-x", "--follow-x-handle", v],
                               "the handle in the local configuration is the placeholder handle"),
        "DEVELOPER_ICP_NUMBER": (lambda v: ["--icp", "--icp-number", v],
                                 "the number in the local configuration is the placeholder"),
        "FEEDBACK_RECEIVER": (lambda v: ["--feedback", "--feedback-address", v], "placeholder address"),
        "REVIEW_APP_ID": (lambda v: ["--review", "--review-id", v], "is a placeholder"),
    }
    seen = set()
    for example in sorted(config.glob("*.local.xcconfig.example")):
        for line in example.read_text(encoding="utf-8").splitlines():
            key, separator, value = line.partition(" = ")
            if not separator or key.startswith("//"):
                continue
            seen.add(key)
            value = value.strip()
            if key.startswith("TIP_PRODUCT_"):
                tier = key.rpartition("_")[2].lower()
                named = [value if name.endswith("." + tier) else name for name in ids]
                check(clean, passes=False, expect=f"the {tier} identifier in the local configuration is a placeholder",
                      args=["--tip-jar", "--tip-products", ",".join(named)])
            elif key in judged:
                arguments, said = judged[key]
                check(clean, passes=False, expect=said, args=arguments(value))
            else:
                failures.append(f"{example.name}: {key} has no refusal of its placeholder in this check")
    named_keys = set(judged) | {f"TIP_PRODUCT_{tier}" for tier in ("LITE", "PRO", "MAX", "ULTRA")}
    for key in sorted(named_keys - seen):
        failures.append(f"no example file holds {key}, which this check judges")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checker", type=Path, required=True)
    options = parser.parse_args()

    failures: list[str] = []
    checkers = Checkers(options.checker)

    # The modes that judge one feature, or a framework: they read no What's New notes.
    modes = {"--feedback", "--follow-x", "--icp", "--pickers", "--tip-jar", "--review", "--runtime",
             "--host-traces"}
    injected: dict[Path, str] = {}
    # The icon a fixture names where the harness set it: DuskJade, as `app_info` writes, until a run
    # under TestFlight makes it DuskEmber.
    iconic: dict[Path, str] = {}

    def retarget_icon(app: Path, configuration: str) -> None:
        """A fixture that names the AppStore's icon gets TestFlight's (and back) in its Info.plist and
        its asset catalog, as the configuration's build compiles its own."""
        want = "DuskEmber" if configuration == "TestFlight" else "DuskJade"
        have = iconic.get(app, "DuskJade")
        if have == want:
            return
        iconic[app] = want
        try:
            with (app / "Info.plist").open("rb") as handle:
                info = plistlib.load(handle)
        except (OSError, plistlib.InvalidFileException, ValueError):
            return
        info.update(icon_info(want))
        (app / "Info.plist").write_bytes(plistlib.dumps(info))
        catalog = app / "Assets.car"
        if catalog.exists():
            data, old = catalog.read_bytes(), CATALOGS[have].read_bytes()
            if data.startswith(old):
                catalog.write_bytes(CATALOGS[want].read_bytes() + data[len(old):])

    def check(app: Path, *, passes: bool, expect: str = "", args: list[str] | None = None,
              never: str = "", notes: bool = True, icon: bool = True) -> None:
        """Runs the checker on `app`. A fixture of the full check that carries no What's New notes
        gets its configuration's track, an empty list, as every build has one, unless `notes` is false;
        and one that has the AppStore's icon has the configuration's, unless `icon` is false."""
        arguments = args or []
        if icon and not modes.intersection(arguments):
            retarget_icon(app, arguments[arguments.index("--configuration") + 1]
                          if "--configuration" in arguments else "AppStore")
        if notes and not modes.intersection(arguments):
            configuration = arguments[arguments.index("--configuration") + 1] if "--configuration" in arguments \
                else "AppStore"
            wanted = APP_STORE_NOTES if configuration == "AppStore" else BETA_NOTES
            # A fixture that runs under two configurations gets the track of each in turn.
            if injected.get(app, wanted) != wanted:
                (app / injected.pop(app)).unlink()
            if not (app / APP_STORE_NOTES).exists() and not (app / BETA_NOTES).exists():
                (app / wanted).write_text("[]", encoding="utf-8")
                injected[app] = wanted
        result = checkers.run([*arguments, str(app)])
        label = app.parent.name
        if never and never in result.stdout:
            # The output itself is not repeated: it holds what must not be printed.
            failures.append(f"{label}: the output prints text that is never to be printed")
        elif (result.returncode == 0) != passes:
            failures.append(f"{label}: expected {'a pass' if passes else 'a failure'}:\n{result.stdout}")
        elif expect and expect not in result.stdout:
            failures.append(f"{label}: output lacks {expect!r}:\n{result.stdout}")

    with tempfile.TemporaryDirectory(prefix="andarium-app-store-") as directory:
        root = Path(directory)
        compile_catalogs(root / "catalogs", options.checker.parent.parent / "Andarium" / "Shared")
        clean = build(root, "clean", CLEAN)
        knob = build(root, "knob", KNOB)
        launch = build(root, "launch", LAUNCH_KNOB)
        thermal = build(root, "thermal", THERMAL_KNOB)
        haptics = build(root, "haptics", HAPTICS_KNOB)
        probe = build(root, "probe", PROBE_KNOB)
        old_apps_probe = build(root, "old-apps-probe", OLD_APPS_PROBE_KNOB)
        reports = {
            index: build(root, f"report{index}", f'const char *fixture(void) {{ return "{line}"; }}\n')
            for index, (_name, line) in enumerate(REPORT_LINES)
        }
        # The guest kernel image rides in a section of its own; a knob name in
        # it belongs to the guest.
        guest = root / "guest.bin"
        guest.write_bytes(
            b"\0UML_ROOTFS\0KERNARIUM_GUEST_NOTE\0/Users/guest/built/here.c\0"
            b"/Volumes/NAME/built/here.c\0")
        carrier = build(
            root, "carrier", CLEAN,
            ["-Wl,-sectcreate,__TEXT,__uml_elf," + str(guest)])

        check(make_app(root, "ready", clean, app_info(), framework=clean),
              passes=True, expect="ready for the App Store")
        check(make_app(root, "guest-section", clean, app_info(), framework=carrier), passes=True)

        # Localized text: the JIT table and any text that names JIT or StikDebug are for the other configurations.
        def localized(name: str, tables: dict[str, dict]) -> Path:
            app = make_app(root, name, clean, app_info())
            lproj = app / "ja.lproj"
            lproj.mkdir()
            for table, content in tables.items():
                (lproj / table).write_bytes(plistlib.dumps(content, fmt=plistlib.FMT_BINARY))
            return app

        check(localized("localized-clean", {"Localizable.strings": {"Start": "起動", "Note": "Preparing"}}), passes=True)
        check(localized("jit-table", {"JIT.strings": {"Preparing JIT": "JITを準備中"}}),
              passes=False, expect="the JIT strings table")
        check(localized("jit-value", {"Localizable.strings": {"Note": "StikDebugからAndariumを開いてください"}}),
              passes=False, expect="carries JIT text")
        check(localized("jit-key", {"Localizable.strings": {"To use JIT, open Andarium": "x"}}),
              passes=False, expect="carries JIT text")

        # Info.plist.
        check(make_app(root, "no-encryption-key", clean, app_info(ITSAppUsesNonExemptEncryption=None)),
              passes=False, expect="ITSAppUsesNonExemptEncryption")
        check(make_app(root, "uses-encryption", clean, app_info(ITSAppUsesNonExemptEncryption=True)),
              passes=False, expect="ITSAppUsesNonExemptEncryption")
        check(make_app(root, "no-metal", clean, app_info(UIRequiredDeviceCapabilities=["arm64"])),
              passes=False, expect="lacks metal")
        check(make_app(root, "no-arm64", clean, app_info(UIRequiredDeviceCapabilities=["metal"])),
              passes=False, expect="lacks arm64")
        check(make_app(root, "ipad-only", clean, app_info(UIDeviceFamily=[2])),
              passes=False, expect="UIDeviceFamily")
        check(make_app(root, "background", clean, app_info(UIBackgroundModes=["audio"])),
              passes=False, expect="background mode")
        # Each permission text the application shows is present and not empty.
        for key in ("NSCameraUsageDescription", "NSMicrophoneUsageDescription",
                    "NSLocationWhenInUseUsageDescription"):
            check(make_app(root, f"no-{key}", clean, app_info(**{key: None})),
                  passes=False, expect=f"{key} must be a non-empty string")
            check(make_app(root, f"blank-{key}", clean, app_info(**{key: "  "})),
                  passes=False, expect=f"{key} must be a non-empty string")

        # Automation knobs in the host code of the application or a framework.
        check(make_app(root, "app-knob", knob, app_info()),
              passes=False, expect="KERNARIUM_HOST_FORWARD")
        check(make_app(root, "launch-knob", launch, app_info()),
              passes=False, expect="ANDARIUM_START")
        check(make_app(root, "thermal-knob", thermal, app_info()),
              passes=False, expect="ANDARIUM_THERMAL_STATE")
        check(make_app(root, "haptics-knob", haptics, app_info()),
              passes=False, expect="ANDARIUM_HAPTICS")
        check(make_app(root, "probe-knob", probe, app_info()),
              passes=False, expect="ANDARIUM_INPUT_PROBE")
        # The probe session's scripted list of old apps, for the App Store and for TestFlight.
        for configuration in ("AppStore", "TestFlight"):
            check(make_app(root, f"old-apps-probe-knob-{configuration}", old_apps_probe, app_info()),
                  passes=False, expect="ANDARIUM_OLD_APPS_PROBE", args=["--configuration", configuration])
        knob_app = make_app(root, "framework-knob", clean, app_info(), framework=knob)
        check(knob_app, passes=False, expect="Runtime.framework/Runtime")

        # The harness's console lines, in the application's own code, whether
        # or not anything calls them.
        for index, (name, _line) in enumerate(REPORT_LINES):
            check(make_app(root, f"report-line-{index}", reports[index], app_info()),
                  passes=False, expect=f"'{name}'")

        # What the build host leaves in a binary: the linker's debug map, whose
        # N_OSO entries name the objects of the build, and a home-directory,
        # volume or temporary-directory path. The same library stripped with
        # `strip -S` passes.
        mapped = build_with_debug_map(root, "mapped")
        stripped = strip_debug_map(mapped)
        homed = build(root, "homed", HOME_PATH)
        # A checkout under a home directory: the N_SO entries of the debug map
        # name /Users/NAME/src.
        mapped_home = build_with_debug_map(root, "mapped-home", "/Users/NAME/src")
        volumed = build(root, "volumed", VOLUME_PATH)
        spaced = build(root, "spaced", VOLUME_NAME_WITH_SPACE)
        temporary = build(root, "temporary", TEMPORARY_PATH)
        harmless = build(root, "harmless", HARMLESS_PATHS)
        # Xcode strips the application's own executable when it archives, so
        # only an embedded framework's debug map is the check's concern, and
        # the object paths in the map of either are not searched for a path:
        # the map is reported once, as the map.
        check(make_app(root, "app-debug-map", mapped, app_info()), passes=True)
        check(make_app(root, "app-debug-map-home", mapped_home, app_info()),
              passes=True, expect="ready for the App Store")
        # A framework with such a map fails on the map, and the home path its
        # stabs name is not reported as a path.
        check(make_app(root, "framework-debug-map-home", clean, app_info(), framework=mapped_home),
              passes=False, expect="Runtime.framework/Runtime: carries the linker's debug map")
        home_result = checkers.run([str(root / "framework-debug-map-home" / "Fixture.app")])
        if "home directory" in home_result.stdout:
            failures.append(
                "a debug map's source directory was reported as a path:\n"
                + home_result.stdout)
        check(make_app(root, "framework-debug-map", clean, app_info(), framework=mapped),
              passes=False, expect="Runtime.framework/Runtime: carries the linker's debug map")
        mapped_result = checkers.run([str(root / "framework-debug-map" / "Fixture.app")])
        if "mounted volume" in mapped_result.stdout:
            failures.append(
                "a debug map's object paths were reported as paths:\n"
                + mapped_result.stdout)
        check(make_app(root, "stripped-debug-map", stripped, app_info(), framework=stripped),
              passes=True, expect="ready for the App Store")
        check(make_app(root, "app-home-path", homed, app_info()),
              passes=False, expect="/Users/NAME/work/project/file.c")
        check(make_app(root, "framework-home-path", clean, app_info(), framework=homed),
              passes=False, expect="names a path under a home directory")
        # A volume path is as much the build host's as a home directory: the
        # dependency prefixes live on the volume that built them.
        check(make_app(root, "app-volume-path", volumed, app_info()),
              passes=False, expect="/Volumes/NAME/prefix/share/locale")
        check(make_app(root, "framework-volume-path", clean, app_info(), framework=volumed),
              passes=False, expect="Runtime.framework/Runtime: names a path on a mounted volume")
        check(make_app(root, "framework-volume-space", clean, app_info(), framework=spaced),
              passes=False, expect="/Volumes/NAME 2/prefix/lib")
        check(make_app(root, "app-temporary-path", temporary, app_info()),
              passes=False, expect="names a path in a temporary build directory")
        check(make_app(root, "framework-temporary-path", clean, app_info(), framework=temporary),
              passes=False, expect="/var/folders/NAME/T/source-build.abc123/stage")
        check(make_app(root, "harmless-paths", harmless, app_info(), framework=harmless),
              passes=True, expect="ready for the App Store")

        # A runtime framework alone (what package-ios-frameworks.sh --app-store
        # checks): its host code, and not the guest kernel image.
        for name, passes, expect in (
            ("framework-knob", False, "KERNARIUM_HOST_FORWARD"),
            ("framework-debug-map", False, "debug map"),
            ("framework-home-path", False, "home directory"),
            ("framework-volume-path", False, "mounted volume"),
            ("framework-temporary-path", False, "temporary build directory"),
            ("harmless-paths", True, ""),
            ("stripped-debug-map", True, ""),
            ("guest-section", True, ""),
            ("ready", True, ""),
        ):
            framework = root / name / "Fixture.app" / "Frameworks" / "Runtime.framework"
            result = checkers.run(["--runtime", str(framework)])
            if (result.returncode == 0) != passes or expect not in result.stdout:
                failures.append(f"--runtime {name}: unexpected result ({result.returncode}):\n{result.stdout}")

        # The GPU frameworks are checked for the build host's traces alone: a
        # knob-like name is no concern of theirs.
        for name, passes, expect in (
            ("framework-knob", True, ""),
            ("framework-debug-map", False, "debug map"),
            ("framework-home-path", False, "home directory"),
            ("framework-volume-path", False, "mounted volume"),
            ("framework-temporary-path", False, "temporary build directory"),
            ("harmless-paths", True, ""),
            ("stripped-debug-map", True, ""),
        ):
            framework = root / name / "Fixture.app" / "Frameworks" / "Runtime.framework"
            result = checkers.run(["--host-traces", str(framework)])
            if (result.returncode == 0) != passes or expect not in result.stdout:
                failures.append(f"--host-traces {name}: unexpected result ({result.returncode}):\n{result.stdout}")

        # Debugging and automation support: in the application's executable, in
        # an embedded framework and in a runtime checked alone, whichever way
        # the library holds it. The stand-ins of the runtime API pass.
        for index, (kind, source) in enumerate(DEBUG_SUPPORT):
            library = build(root, f"debug{index}", source)
            expect = f"carries debugging support: {kind}"
            check(make_app(root, f"debug-app-{index}", library, app_info()),
                  passes=False, expect=expect)
            debug_app = make_app(root, f"debug-framework-{index}", clean, app_info(), framework=library)
            check(debug_app, passes=False, expect=expect)
            if kind == "old apps preview":
                # TestFlight is held to the same rule.
                check(make_app(root, f"tf-debug-app-{index}", library, app_info()),
                      passes=False, expect=expect, args=["--configuration", "TestFlight"])
            runtime_only = checkers.run(["--runtime", str(debug_app / "Frameworks" / "Runtime.framework")])
            if runtime_only.returncode == 0 or expect not in runtime_only.stdout:
                failures.append(f"--runtime debug {index} ({kind}): unexpected result "
                                f"({runtime_only.returncode}):\n{runtime_only.stdout}")
        stand_ins = build(root, "stand-ins", STAND_INS)
        check(make_app(root, "stand-ins-app", stand_ins, app_info(), framework=stand_ins),
              passes=True, expect="ready for the App Store")
        stand_in_runtime = checkers.run([
            "--runtime", str(root / "stand-ins-app" / "Fixture.app" / "Frameworks" / "Runtime.framework")])
        if stand_in_runtime.returncode != 0:
            failures.append(f"--runtime stand-ins: unexpected result:\n{stand_in_runtime.stdout}")

        # Test bundles and the frameworks that run them are not in an
        # application that goes to the store.
        for name, relative, is_directory in (
            ("test-bundle", "PlugIns/FixtureTests.xctest", True),
            ("xctest-framework", "Frameworks/XCTest.framework", True),
            ("ui-automation-framework", "Frameworks/XCUIAutomation.framework", True),
            ("testing-framework", "Frameworks/Testing.framework", True),
            ("testing-foundation-framework", "Frameworks/_Testing_Foundation.framework", True),
            ("xctest-library", "Frameworks/libXCTestSwiftSupport.dylib", False),
        ):
            tested = make_app(root, name, clean, app_info(), framework=clean)
            member = tested / relative
            if is_directory:
                member.mkdir(parents=True)
                (member / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "org.example.Test"}))
            else:
                shutil.copyfile(clean, member)
            check(tested, passes=False, expect=f"{relative}: a test bundle or test framework")

        # Send feedback is compiled in only where the build names a receiver. The
        # fixtures stand for the application with it (the subject's prefix, the
        # Info.plist key, the Mail framework, a type of the feature) and for the
        # Debug build's code library; the receiver is a made-up address.
        receiver = "person@receiver.fixture"
        feature = build(root, "feature", FEEDBACK_FEATURE, ["-framework", "MessageUI"])
        partial = build(root, "partial", FEEDBACK_PARTIAL)
        feedback_info = app_info(AndariumFeedbackAddress=receiver)
        # What the build phases pass: the address the build names and the local
        # configuration's own receiver, whatever the configuration.
        appstore = ["--feedback-address", receiver, "--feedback-receiver", receiver]
        local = ["--feedback-receiver", receiver]
        arranged = ["--feedback-address", "feedback@example.com"]
        check(make_app(root, "feedback-built", feature, feedback_info), passes=True,
              expect="Send feedback is compiled in", args=appstore)
        built_notes = make_app(root, "feedback-built-notes", feature, feedback_info)
        write_notes(built_notes, [FEEDBACK_ENTRY, PLAIN_ENTRY], NOTES_STRINGS)
        check(built_notes, passes=True, expect="Send feedback is compiled in", args=appstore)
        check(make_app(root, "feedback-absent", clean, app_info()), passes=True,
              expect="Send feedback is not compiled in")
        check(make_app(root, "feedback-no-key", feature, app_info()), passes=False,
              expect="AndariumFeedbackAddress must be the receiver", args=appstore)
        check(make_app(root, "feedback-other-key", feature, app_info(AndariumFeedbackAddress="other@receiver.fixture")),
              passes=False, expect="must be the receiver the build names", args=appstore)
        check(make_app(root, "feedback-not-built", clean, feedback_info), passes=False,
              expect="lacks Send feedback", args=appstore)
        check(make_app(root, "feedback-partial", partial, feedback_info), passes=False,
              expect="MessageUI.framework", args=appstore)
        # No receiver, so nothing of it: not the code, not the key, not the strings.
        check(make_app(root, "feedback-code-without-receiver", feature, app_info()), passes=False,
              expect="carries Send feedback")
        check(make_app(root, "feedback-key-without-receiver", clean, feedback_info), passes=False,
              expect="has AndariumFeedbackAddress though the build names no receiver")
        check(make_app(root, "feedback-framework-without-receiver", clean, app_info(), framework=feature),
              passes=False, expect="Runtime.framework/Runtime: carries Send feedback")
        words = make_app(root, "feedback-words", clean, app_info())
        (words / "en.lproj").mkdir()
        (words / "en.lproj" / "Localizable.strings").write_bytes(
            plistlib.dumps({"Send feedback": "Send feedback"}, fmt=plistlib.FMT_BINARY))
        check(words, passes=False, expect="has Send feedback strings")
        # The What's New notes have two tracks, and the notes' table is one for both. A track's
        # entry about Send feedback is bundled and hidden by a product without the feature: its
        # strings, found through the bundled notes, are the one text of the feature such a
        # product may hold, in the notes' table alone and by the entry's own strings alone. The
        # AppStore bundle carries the App Store track's file and TestFlight the beta track's.
        hidden = [FEEDBACK_ENTRY, FEEDBACK_POINTS_ENTRY, PLAIN_ENTRY]
        testflight = ["--configuration", "TestFlight"]
        tracks = (("appstore", APP_STORE_NOTES, BETA_NOTES, [], "App Store"),
                  ("testflight", BETA_NOTES, APP_STORE_NOTES, testflight, "beta"))
        for label, file, _other_file, flags, _track in tracks:
            notes = make_app(root, f"notes-hidden-{label}", clean, app_info())
            write_notes(notes, hidden, NOTES_STRINGS, track=file)
            check(notes, passes=True, expect="Send feedback is not compiled in", args=flags)
            for name, other in (
                    ("key", {"Fixed Send feedback not opening": "x"}),
                    ("value", {"Snapshots": "Andarium feedback"}),
                    ("word", {"Andarium feedback": "x"})):
                leak = make_app(root, f"notes-other-{name}-{label}", clean, app_info())
                write_notes(leak, hidden, {**NOTES_STRINGS, **other}, track=file)
                check(leak, passes=False, expect="ja.lproj/WhatsNew.strings: has Send feedback strings",
                      args=flags)
            # Marked entries only: an entry with no mark, or another one, is shown in a
            # build without the feature, and so is a table with no notes beside it.
            for name, entries in (
                    ("unmarked", [{**FEEDBACK_ENTRY, "requirement": None}, PLAIN_ENTRY]),
                    ("other-feature", [{**FEEDBACK_ENTRY, "requirement": {"feature": "other"}}, PLAIN_ENTRY]),
                    ("other-requirement", [{**FEEDBACK_ENTRY, "requirement": {"device": "pad"}}, PLAIN_ENTRY]),
                    ("no-notes", None), ("broken-notes", None)):
                shown = make_app(root, f"notes-{name}-{label}", clean, app_info())
                write_notes(shown, entries, NOTES_STRINGS, track=file)
                if name == "broken-notes":
                    (shown / file).write_text("[{", encoding="utf-8")
                check(shown, passes=False, expect="ja.lproj/WhatsNew.strings: has Send feedback strings",
                      args=flags)
            # The exemption is the notes' table and nothing else.
            elsewhere = make_app(root, f"notes-elsewhere-{label}", clean, app_info())
            write_notes(elsewhere, hidden, {"Snapshots": "スナップショット"}, track=file)
            (elsewhere / "ja.lproj" / "Localizable.strings").write_bytes(
                plistlib.dumps({"Send feedback": "x"}, fmt=plistlib.FMT_BINARY))
            check(elsewhere, passes=False, expect="ja.lproj/Localizable.strings: has Send feedback strings",
                  args=flags)
        # The phases of the other configurations read the beta track's file alone.
        beta_hidden = make_app(root, "notes-hidden-release", clean, app_info())
        write_notes(beta_hidden, hidden, NOTES_STRINGS, track=BETA_NOTES)
        beta_leak = make_app(root, "notes-other-release", clean, app_info())
        write_notes(beta_leak, hidden, {**NOTES_STRINGS, "Andarium feedback": "x"}, track=BETA_NOTES)
        for configuration in ("Debug", "Release"):
            check(beta_hidden, passes=True, expect=f"Send feedback is not compiled in ({configuration})",
                  args=["--feedback", "--configuration", configuration])
            check(beta_leak, passes=False, expect="has Send feedback strings",
                  args=["--feedback", "--configuration", configuration])
        # Each bundle carries its configuration's track and not the other, each a list of
        # releases; the report says which it carries.
        for label, file, other_file, flags, track in tracks:
            says = f"What's New notes are the {track} track ({file})"
            own = make_app(root, f"notes-track-{label}", clean, app_info())
            write_notes(own, hidden, NOTES_STRINGS, track=file)
            check(own, passes=True, expect=says, args=flags)
            wrong = make_app(root, f"notes-track-wrong-{label}", clean, app_info())
            write_notes(wrong, hidden, NOTES_STRINGS, track=other_file)
            for expect in (f"{file}: is missing; {flags[1] if flags else 'AppStore'} bundles the {track} track",
                           f"{other_file}: is the other track's What's New notes"):
                check(wrong, passes=False, expect=expect, args=flags, notes=False)
            both = make_app(root, f"notes-track-both-{label}", clean, app_info())
            write_notes(both, hidden, NOTES_STRINGS, track=file)
            write_notes(both, hidden, NOTES_STRINGS, track=other_file)
            check(both, passes=False, expect=f"{other_file}: is the other track's What's New notes",
                  args=flags, notes=False)
            bare = make_app(root, f"notes-track-none-{label}", clean, app_info())
            check(bare, passes=False, expect=f"{file}: is missing", args=flags, notes=False)
            for name, text in (("object", '{"build": 11}'), ("unreadable", "[{")):
                bad = make_app(root, f"notes-track-{name}-{label}", clean, app_info())
                (bad / file).write_text(text, encoding="utf-8")
                check(bad, passes=False, expect=f"{file}: is not a list of releases", args=flags, notes=False)
            # The track with no release is a list too.
            empty = make_app(root, f"notes-track-empty-{label}", clean, app_info())
            (empty / file).write_text("[]", encoding="utf-8")
            check(empty, passes=True, expect=says, args=flags, notes=False)
            # A list the application would not accept is no notes file: it shows no notes.
            entry = {"id": "a", "title": "A", "text": "B", "symbol": "s"}
            for name, releases, expect in (
                    ("empty-release", [{}], "a release has no build number or version"),
                    ("extra-release-key", [{"build": 11, "version": "v", "entries": [entry], "x": 1}],
                     "a release is not an object with only"),
                    ("no-entries", [{"build": 11, "version": "v", "entries": []}], "has no entry"),
                    ("empty-entry", [{"build": 11, "version": "v", "entries": [{}]}], "an entry lacks its id"),
                    ("extra-entry-key", [{"build": 11, "version": "v", "entries": [{**entry, "x": 1}]}],
                     "an entry is not an object with only the keys"),
                    ("no-text", [{"build": 11, "version": "v", "entries": [{**entry, "text": None}]}],
                     "has an empty text"),
                    ("neither", [{"build": 11, "version": "v",
                                  "entries": [{key: value for key, value in entry.items() if key != "text"}]}],
                     "has neither text nor points"),
                    ("empty-points", [{"build": 11, "version": "v", "entries": [{**entry, "points": [""]}]}],
                     "has an empty list of points or an empty point"),
                    ("twice", [{"build": 11, "version": "v", "entries": [entry, entry]}], "appears twice"),
                    ("two-builds", [{"build": 11, "version": "v", "entries": [entry]},
                                    {"build": 11, "version": "w", "entries": [{**entry, "id": "b"}]}],
                     "build 11 has two releases")):
                refused = make_app(root, f"notes-track-{name}-{label}", clean, app_info())
                (refused / file).write_text(json.dumps(releases), encoding="utf-8")
                check(refused, passes=False, expect=expect, args=flags, notes=False)
            good = make_app(root, f"notes-track-good-{label}", clean, app_info())
            (good / file).write_text(json.dumps([{"build": 11, "version": "v", "date": "2026-11-15",
                                                  "entries": [{**entry, "points": ["C"], "place": "sessionSettings",
                                                               "requirement": {"device": "pad"}}]}]),
                                     encoding="utf-8")
            check(good, passes=True, expect=says, args=flags, notes=False)
            # The application reads the file at the bundle root alone: a copy elsewhere is a stray.
            for place in ("Resources/WhatsNew.json", "ja.lproj/WhatsNewAppStore.json", "Frameworks/X.framework/WhatsNew.json"):
                copied = make_app(root, f"notes-track-copy-{label}-{place.replace('/', '-')}", clean, app_info())
                write_notes(copied, hidden, NOTES_STRINGS, track=file)
                (copied / place).parent.mkdir(parents=True, exist_ok=True)
                (copied / place).write_text("[]", encoding="utf-8")
                check(copied, passes=False, expect=f"{place}: is a copy of a What's New notes file",
                      args=flags, notes=False)
        # The notes' table is one for both tracks, so an AppStore bundle whose own track has
        # no entry about Send feedback still holds the beta track's strings of it. The beta
        # track's source file (--beta-notes) says which they are; without it, or for a string
        # it does not name, they are Send feedback text in a product that has none.
        beta_source = root / "beta-source" / BETA_NOTES
        beta_source.parent.mkdir()
        beta_source.write_text(json.dumps([{"build": 12, "version": "1.0 (12)", "entries": hidden}]),
                               encoding="utf-8")
        carried = make_app(root, "notes-beta-strings", clean, app_info())
        write_notes(carried, [], NOTES_STRINGS, track=APP_STORE_NOTES)
        check(carried, passes=True, expect="Send feedback is not compiled in",
              args=["--beta-notes", str(beta_source)])
        check(carried, passes=False, expect="ja.lproj/WhatsNew.strings: has Send feedback strings")
        for name, source in (("missing", root / "beta-source" / "absent.json"), ("unreadable", None)):
            if source is None:
                source = root / "beta-source" / "unreadable.json"
                source.write_text("[{", encoding="utf-8")
            check(carried, passes=False, expect="ja.lproj/WhatsNew.strings: has Send feedback strings",
                  args=["--beta-notes", str(source)])
        stray = make_app(root, "notes-beta-stray", clean, app_info())
        write_notes(stray, [], {**NOTES_STRINGS, "Fixed Send feedback not opening": "x"}, track=APP_STORE_NOTES)
        check(stray, passes=False, expect="ja.lproj/WhatsNew.strings: has Send feedback strings",
              args=["--beta-notes", str(beta_source)])
        # The exemption never hides what a bundled entry shows: the beta track's entry about
        # Send feedback copied into the App Store file without its requirement is shown by a
        # product that has no feedback, and so is a string that a bundled entry without the mark
        # shares with a marked one, whichever track marks it.
        copied_entry = {**FEEDBACK_ENTRY, "requirement": None}
        for name, entries in (
                ("copied-unmarked", [copied_entry, PLAIN_ENTRY]),
                ("copied-other-requirement", [{**FEEDBACK_ENTRY, "requirement": {"device": "pad"}}, PLAIN_ENTRY]),
                ("shared-title", [FEEDBACK_ENTRY, {**PLAIN_ENTRY, "id": "same-title", "title": FEEDBACK_ENTRY["title"]}])):
            overlap = make_app(root, f"notes-beta-{name}", clean, app_info())
            write_notes(overlap, entries, NOTES_STRINGS, track=APP_STORE_NOTES)
            check(overlap, passes=False, expect="ja.lproj/WhatsNew.strings: has Send feedback strings",
                  args=["--beta-notes", str(beta_source)])
            check(overlap, passes=False, expect="ja.lproj/WhatsNew.strings: has Send feedback strings")
        # An entry that keeps the mark is hidden, with the beta source or without it.
        marked = make_app(root, "notes-beta-copied-marked", clean, app_info())
        write_notes(marked, [FEEDBACK_ENTRY, PLAIN_ENTRY], NOTES_STRINGS, track=APP_STORE_NOTES)
        check(marked, passes=True, expect="Send feedback is not compiled in",
              args=["--beta-notes", str(beta_source)])
        # Only an AppStore bundle takes the exemption from there: a bundle of the beta track
        # has the notes it carries.
        flagged = make_app(root, "notes-beta-testflight", clean, app_info())
        write_notes(flagged, [PLAIN_ENTRY], NOTES_STRINGS, track=BETA_NOTES)
        check(flagged, passes=False, expect="ja.lproj/WhatsNew.strings: has Send feedback strings",
              args=[*testflight, "--beta-notes", str(beta_source)])
        # The phase's real input: the application's beta notes, in a table that holds all of
        # their strings, beside the App Store track's empty list.
        real_notes = options.checker.parent.parent / "Andarium" / "Shared" / BETA_NOTES
        real = json.loads(real_notes.read_text(encoding="utf-8"))
        strings = {text: text for release in real for entry in release["entries"]
                   for text in (entry["title"], entry.get("text"), *entry.get("points", ())) if text}
        shipped = make_app(root, "notes-beta-real", clean, app_info())
        write_notes(shipped, [], strings, track=APP_STORE_NOTES)
        check(shipped, passes=True, expect="What's New notes are the App Store track",
              args=["--beta-notes", str(real_notes)])

        # The app icon is the configuration's own and no other: the AppStore bundle has DuskJade and
        # nothing of DuskEmber, the TestFlight bundle the reverse. The icon is the primary icon of the
        # iPhone's and the iPad's Info.plist block, which name no other icon, and the one app icon of
        # Assets.car, a catalog compiled in this run and read by its typed renditions; no catalog of a
        # nested bundle holds the other icon, and no icon file or document is of its name. Text that
        # only mentions an icon's name is no icon.
        for label, flags, own, other in (("appstore", [], "DuskJade", "DuskEmber"),
                                         ("testflight", testflight, "DuskEmber", "DuskJade")):
            ready = make_app(root, f"icon-{label}", clean, app_info())
            check(ready, passes=True, expect=f"app icon is {own}", args=flags)
            # Both configurations run on one fixture in turn, each with its own icon.
            check(ready, passes=True, expect=f"app icon is {'DuskEmber' if own == 'DuskJade' else 'DuskJade'}",
                  args=testflight if not flags else [])
            for name, info in (
                    ("other-primary", app_info(**icon_info(other))),
                    ("no-icon", app_info(CFBundleIcons=None, **{"CFBundleIcons~ipad": None})),
                    ("iphone-other", app_info(CFBundleIcons=icon_info(other)["CFBundleIcons"],
                                              **{"CFBundleIcons~ipad": icon_info(own)["CFBundleIcons~ipad"]})),
                    ("ipad-other", app_info(**{"CFBundleIcons~ipad": icon_info(other)["CFBundleIcons~ipad"],
                                               "CFBundleIcons": icon_info(own)["CFBundleIcons"]})),
                    ("no-icon-name", app_info(CFBundleIcons={"CFBundlePrimaryIcon": {"CFBundleIconFiles": ["x"]}}))):
                wrong = make_app(root, f"icon-{name}-{label}", clean, info)
                check(wrong, passes=False, expect="Info.plist: CFBundleIcons", args=flags, icon=False)
            # The icon metadata names no other icon: not in the files of the primary icon, nor in an
            # alternate icon.
            for name, key, extra in (
                    ("files", "CFBundleIcons", {"CFBundlePrimaryIcon": {"CFBundleIconName": own, "CFBundleIconFiles": [f"{other}60x60"]}}),
                    ("alternate", "CFBundleIcons~ipad", {**icon_info(own)["CFBundleIcons~ipad"],
                                                         "CFBundleAlternateIcons": {"Other": {"CFBundleIconName": other}}})):
                names = make_app(root, f"icon-metadata-{name}-{label}", clean, app_info(**{**icon_info(own), key: extra}))
                check(names, passes=False, expect=f"Info.plist: {key} names the {other} icon", args=flags,
                      icon=False)
            # The compiled catalog is the application's icon alone, as the platform's reader lists it: the
            # Info.plist alone is not enough, and neither is a catalog of another icon, of both, or with a
            # second icon group under any name, or one that cannot be read. (A catalog compiled from the
            # other icon's artwork under this icon's name is not told from it; the name is what a
            # catalog states.)
            for name, kind, said in (
                    ("no-catalog", None, f"Assets.car: lacks the {own} icon"),
                    ("plain-catalog", "plain", f"Assets.car: lacks the {own} icon"),
                    ("other-catalog", other, f"Assets.car: lacks the {own} icon"),
                    ("other-catalog-holds", other, f"Assets.car: holds the {other} icon"),
                    ("both-catalog", "both", f"Assets.car: holds the {other} icon"),
                    ("aliased-catalog", f"aliased-{own}", "Assets.car: holds the ArchiveArtwork icon"),
                    ("unreadable-catalog", "unreadable", "Assets.car: cannot be read for its app icons")):
                bare = make_app(root, f"icon-{name}-{label}", clean, app_info(**icon_info(own)), assets={own: False})
                if kind == "unreadable":
                    (bare / "Assets.car").write_bytes(b"not a catalog")
                elif kind:
                    clone(CATALOGS[kind], bare / "Assets.car")
                check(bare, passes=False, expect=said, args=flags, icon=False)
            # The other icon in the catalog of a nested bundle, in a file or a document of its name.
            nested = make_app(root, f"icon-nested-catalog-{label}", clean, app_info(**icon_info(own)))
            (nested / "Feature.bundle").mkdir()
            clone(CATALOGS[other], nested / "Feature.bundle" / "Assets.car")
            check(nested, passes=False, expect=f"Feature.bundle/Assets.car: holds the {other} icon", args=flags,
                  icon=False)
            for name, path, said in (
                    ("png", f"{other}60x60@2x.png", f"{other}60x60@2x.png: is a file of the {other} icon"),
                    ("png-nested", f"Feature.bundle/{other}76x76@2x~ipad.png",
                     f"Feature.bundle/{other}76x76@2x~ipad.png: is a file of the {other} icon"),
                    ("document", f"{other}.icon", f"{other}.icon: is a file of the {other} icon")):
                stray = make_app(root, f"icon-{name}-{label}", clean, app_info(**icon_info(own)))
                (stray / path).parent.mkdir(parents=True, exist_ok=True)
                (stray / path).write_bytes(b"\x89PNG")
                check(stray, passes=False, expect=said, args=flags, icon=False)
            # Text that only mentions an icon's name is no icon: a text file, a property list, UTF-16, a
            # lower-case spelling, a file named for the icon that is no icon file, and a binary with the
            # name in its code. The name of the icon the bundle has is in its files without harm too.
            inside = build(root, f"icon-code-{label}", f'const char *fixture(void) {{ return "{other}"; }}\n')
            for name, path, data in (
                    ("text", "History.txt", f"{other} is the TestFlight icon; this build uses {own}.".encode()),
                    ("plist", "Extra.plist", plistlib.dumps({"icon": other})),
                    ("utf-16", "Extra.dat", other.encode("utf-16-le")),
                    ("case", "Extra.txt", other.lower().encode()),
                    ("named-text", f"{other}-history.txt", b"the history of the icon"),
                    ("own", f"{own}60x60@2x.png", b"\x89PNG")):
                fine = make_app(root, f"icon-mention-{name}-{label}", inside if name == "text" else clean,
                                app_info(**icon_info(own)))
                (fine / path).write_bytes(data)
                check(fine, passes=True, expect=f"app icon is {own}", args=flags, icon=False)
        # The feature's own strings table (Feedback.strings, and the stringsdict of
        # its plurals) is the feature's: a product without the receiver holds none,
        # found by the file name though the table says nothing of the feature.
        for name, suffix, content in (
                ("strings", "strings", {"Hello": "Hello"}), ("stringsdict", "stringsdict", {})):
            table = make_app(root, f"feedback-table-{name}", clean, app_info())
            (table / "en.lproj").mkdir()
            (table / "en.lproj" / f"Feedback.{suffix}").write_bytes(plistlib.dumps(content, fmt=plistlib.FMT_BINARY))
            expect = f"en.lproj/Feedback.{suffix}: is the Feedback strings table though the build names no receiver"
            check(table, passes=False, expect=expect)
            for configuration in ("Debug", "Release"):
                check(table, passes=False, expect=expect, args=["--feedback", "--configuration", configuration])
        # A product with the receiver holds the table in every language, or the sheet
        # reads English in a language the product claims.
        check(make_app(root, "feedback-table-missing", feature, feedback_info, feedback_tables=False),
              passes=False, expect="lacks the Feedback strings table in ja, zh-Hans, zh-Hant", args=appstore)
        partly = make_app(root, "feedback-table-partial", feature, feedback_info, feedback_tables=False)
        write_feedback_tables(partly, ("ja", "zh-Hans"))
        check(partly, passes=False, expect="lacks the Feedback strings table in zh-Hant", args=appstore)
        check(make_app(root, "feedback-table-dict-only", feature, feedback_info, feedback_tables=False),
              passes=False, expect="lacks the Feedback strings table in", args=appstore)
        with_dict = make_app(root, "feedback-table-with-dict", feature, feedback_info)
        (with_dict / "ja.lproj" / "Feedback.stringsdict").write_bytes(plistlib.dumps({}, fmt=plistlib.FMT_BINARY))
        check(with_dict, passes=True, expect="Send feedback is compiled in", args=appstore)
        check(make_app(root, "feedback-table-arranged", feature, app_info(AndariumFeedbackAddress="feedback@example.com")),
              passes=True, expect="Send feedback is compiled in (Debug)",
              args=["--feedback", "--configuration", "Debug", "--feedback-address", "feedback@example.com"])
        # The receiver of the local configuration is one strict address, and a
        # real one: no quotes, angle brackets, trailing semicolon or second @,
        # no placeholder domain. (SendFeedbackMail.isWellFormed holds the same
        # rules; AndariumCore's SendFeedbackTests pin that side.)
        for index, address in enumerate((
                        "person", "person@receiver", "@receiver.fixture", "a b@receiver.fixture",
                        "person@example.com", "person@mail.example.org", "person@receiver.test",
                        "person@receiver.invalid",
                        '"person@receiver.fixture"', '"person"@receiver.fixture', "<person@receiver.fixture>",
                        "Person <person@receiver.fixture>", "person@receiver.fixture;",
                        "person@receiver.fixture,other@receiver.fixture", "person@receiver@receiver.fixture",
                        "per..son@receiver.fixture", ".person@receiver.fixture", "person.@receiver.fixture",
                        "person@-receiver.fixture", "person@receiver-.fixture", "person@receiver..fixture",
                        "person@receiver.fixture.", "person@receiver.f1x", "person@receiver.f",
                        "person@receiver.fixture\n", "p" * 65 + "@receiver.fixture",
                        "person@" + "r" * 64 + ".fixture")):
            check(make_app(root, f"feedback-address-{index}",
                           feature, app_info(AndariumFeedbackAddress=address)),
                  passes=False, expect="Send feedback: the receiver", args=["--feedback-address", address])
        for index, address in enumerate((
                "first.last+tag@mail.receiver.fixture", "p_q%r-s@receiver-one.fixture", "p" * 64 + "@receiver.fixture")):
            check(make_app(root, f"feedback-address-ok-{index}", feature,
                           app_info(AndariumFeedbackAddress=address)),
                  passes=True, expect="Send feedback is compiled in", args=["--feedback-address", address])
        # A build that names no receiver still has the feature's file names in the
        # linker's debug map of its Debug or Release product.
        mapped_feedback = build_with_debug_map(root, "mapped-feedback", "/Users/NAME/SendFeedbackSheet")
        # The map's symbol names are searched, though: a function the feature
        # defines is a stab the linker shares its string with the symbol for.
        symbol_only = build_with_debug_map(
            root, "symbol-only", "/Users/NAME/Project",
            # The linker gives a function's stab the symbol's own string for most
            # functions (here the second); a hidden one is in no export trie.
            "__attribute__((visibility(\"hidden\"))) int plain_first(void) { return 2; }\n"
            "__attribute__((visibility(\"hidden\"))) int _s8Andarium17SendFeedbackModelC4openyyF(void) { return 1; }\n")
        for configuration in ("Debug", "Release"):
            check(make_app(root, f"feedback-{configuration}-debug-map", mapped_feedback, app_info()),
                  passes=True, expect=f"Send feedback is not compiled in ({configuration})",
                  args=["--feedback", "--configuration", configuration])
            check(make_app(root, f"feedback-{configuration}-symbol-only", symbol_only, app_info()),
                  passes=False, expect="carries Send feedback (SendFeedback)",
                  args=["--feedback", "--configuration", configuration])
        check(make_app(root, "feedback-appstore-debug-map", mapped_feedback, app_info()),
              passes=True, expect="Send feedback is not compiled in")
        check(make_app(root, "feedback-appstore-symbol-only", symbol_only, app_info()),
              passes=False, expect="carries Send feedback (SendFeedback)")
        # The Debug build keeps the application's code in a library beside the
        # stub executable; the check reads it.
        debug = make_app(root, "feedback-debug-library", clean, app_info())
        shutil.copyfile(feature, debug / "Fixture.debug.dylib")
        check(debug, passes=False, expect="Fixture.debug.dylib: carries Send feedback")
        # The other configurations: absent, or the arranged example address,
        # which Debug alone takes.
        other = ["--feedback", "--configuration"]
        arranged_info = app_info(AndariumFeedbackAddress="feedback@example.com")
        for configuration in ("Debug", "Release"):
            check(make_app(root, f"feedback-{configuration}-absent", clean, app_info()), passes=True,
                  expect=f"Send feedback is not compiled in ({configuration})", args=[*other, configuration])
            # The local configuration's receiver never reaches them.
            check(make_app(root, f"feedback-{configuration}-receiver", feature, feedback_info), passes=False,
                  expect="not the arranged example address", args=[*other, configuration, *appstore])
            check(make_app(root, f"feedback-{configuration}-code", feature, app_info()), passes=False,
                  expect="carries Send feedback", args=[*other, configuration])
            check(make_app(root, f"feedback-{configuration}-key", clean, feedback_info), passes=False,
                  expect="though the build names no receiver", args=[*other, configuration])
        check(make_app(root, "feedback-Debug-arranged", feature, arranged_info),
              passes=True, expect="Send feedback is compiled in (Debug)", args=[*other, "Debug", *arranged])
        # Release is what sideloads and forks build: it refuses the arrangement,
        # whatever the product holds.
        check(make_app(root, "feedback-Release-arranged", feature, arranged_info),
              passes=False, expect="only Debug takes the arrangement", args=[*other, "Release", *arranged])
        check(make_app(root, "feedback-Release-arranged-absent", clean, app_info()),
              passes=False, expect="only Debug takes the arrangement", args=[*other, "Release", *arranged])
        check(make_app(root, "feedback-Debug-other-address", feature,
                       app_info(AndariumFeedbackAddress="other@receiver.fixture")),
              passes=False, expect="not the arranged example address",
              args=[*other, "Debug", "--feedback-address", "other@receiver.fixture"])
        check(make_app(root, "feedback-appstore-arranged", feature, arranged_info),
              passes=False, expect="placeholder address", args=arranged)

        # The local configuration's receiver is in no file of a bundle that does
        # not name it, and the check never prints it. Nothing here is a Mach-O
        # with a code section: bytes anywhere count, in either case.
        leaky = build(root, "leaky", f'const char *fixture(void) {{ return "{receiver}"; }}\n')
        data_file = make_app(root, "leak-data-file", clean, app_info())
        (data_file / "Data.bin").write_bytes(b"\0\1" + receiver.upper().encode() + b"\2")
        nested = make_app(root, "leak-nested-file", clean, app_info())
        (nested / "en.lproj").mkdir()
        (nested / "en.lproj" / "InfoPlist.strings").write_bytes(f'"CFBundleName" = "{receiver}";\n'.encode())
        # The chunk the check reads ends inside the receiver.
        straddle = make_app(root, "leak-straddle", clean, app_info())
        (straddle / "Big.bin").write_bytes(b"\0" * ((8 << 20) - 5) + receiver.encode() + b"\0")
        leaks = (
            ("executable", make_app(root, "leak-executable", leaky, app_info()), "Fixture"),
            ("framework", make_app(root, "leak-framework", clean, app_info(), framework=leaky),
             "Frameworks/Runtime.framework/Runtime"),
            ("info-plist", make_app(root, "leak-info-plist", clean, feedback_info), "Info.plist"),
            ("data-file", data_file, "Data.bin"),
            ("nested-file", nested, "en.lproj/InfoPlist.strings"),
            ("straddle", straddle, "Big.bin"),
        )
        for name, app, path in leaks:
            for configuration in ("Debug", "Release"):
                # No address, and the arranged one: both are a build that does
                # not name the local file's receiver.
                for arguments in (local, [*local, *arranged]):
                    check(app, passes=False, expect=f"{path}: holds the receiver of the local configuration",
                          never=receiver, args=[*other, configuration, *arguments])
            check(app, passes=False, expect=f"{path}: holds the receiver of the local configuration",
                  never=receiver, args=local)
        # The same bundles without the receiver passed in are not held to it,
        # and a bundle without the bytes passes with it.
        check(make_app(root, "leak-none", clean, app_info(), framework=clean), passes=True,
              expect="ready for the App Store", args=local)
        check(make_app(root, "leak-none-debug", clean, app_info()), passes=True,
              expect="Send feedback is not compiled in (Debug)", args=[*other, "Debug", *local])
        check(make_app(root, "leak-none-arranged", feature, arranged_info), passes=True,
              expect="Send feedback is compiled in (Debug)", args=[*other, "Debug", *local, *arranged])
        # An App Store build that names it holds it in Info.plist, and nowhere else.
        check(make_app(root, "leak-named", feature, feedback_info), passes=True,
              expect="Send feedback is compiled in", args=appstore)
        named_leak = make_app(root, "leak-named-elsewhere", feature, feedback_info)
        (named_leak / "Data.bin").write_bytes(receiver.encode())
        check(named_leak, passes=True, expect="Send feedback is compiled in", args=appstore)

        # The receiver as a binary stores a string besides UTF-8.
        for form, content in encoded_forms(receiver):
            stray = make_app(root, f"leak-{form}", clean, app_info())
            (stray / "Data.bin").write_bytes(content)
            for arguments in (local, [*other, "Debug", *local]):
                check(stray, passes=False, expect="Data.bin: holds the receiver of the local configuration",
                      never=receiver, args=arguments)

        check_tip_jar(root, check, clean, feature, feedback_info, receiver, appstore, local, arranged)
        tip_ids = {tier: f"com.fixture.product.{tier}" for tier in ("lite", "pro", "max", "ultra")}
        tip_list = ",".join(tip_ids.values())
        check_review(root, check, clean, feedback_info, app_info(AndariumTipProducts=tip_ids), appstore,
                     ["--tip-products", tip_list, "--tip-local-products", tip_list])
        check_developer(root, check, clean)
        check_icp(root, check, clean)
        check_testflight(root, check, clean, feature, receiver)
        check_whole_bundle(root, check, clean)
        check_one_walk(checkers, root, clean, failures)
        check_examples(root, check, clean, options.checker.parent.parent / "Config", failures)
        # Follow developer on X is compiled in only where the build names a handle,
        # by the same rule. The fixtures stand for the application with it (the
        # Info.plist key, a line of the row's text, a type, the FollowX table and the
        # logo in Assets.car); the handle is a made-up one that is also a word of
        # the bundle identifier, as the real one is.
        handle = "someone_real"
        x_feature = build(root, "x-feature", FOLLOW_X_FEATURE)
        x_partial = build(root, "x-partial", FOLLOW_X_PARTIAL)
        x_info = app_info(AndariumFollowXHandle=handle)
        x_appstore = ["--follow-x-handle", handle, "--developer-x-handle", handle]
        x_local = ["--developer-x-handle", handle]
        x_arranged = ["--follow-x-handle", "example_handle"]
        x_other = ["--follow-x", "--configuration"]
        check(make_app(root, "x-built", x_feature, x_info), passes=True,
              expect="Follow developer on X is compiled in", args=x_appstore)
        check(make_app(root, "x-absent", clean, app_info()), passes=True,
              expect="Follow developer on X is not compiled in")
        check(make_app(root, "x-no-key", x_feature, app_info()), passes=False,
              expect="AndariumFollowXHandle must be the handle", args=x_appstore)
        check(make_app(root, "x-other-key", x_feature, app_info(AndariumFollowXHandle="another_one")),
              passes=False, expect="must be the handle the build names", args=x_appstore)
        check(make_app(root, "x-not-built", clean, x_info), passes=False,
              expect="lacks Follow developer on X", args=x_appstore)
        check(make_app(root, "x-partial", x_partial, x_info), passes=False,
              expect="Follow developer on", args=x_appstore)
        # A row that lost its logo draws a blank: the asset catalog holds it.
        check(make_app(root, "x-no-logo", x_feature, x_info, follow_x_logo=False), passes=False,
              expect="Assets.car: lacks the logo", args=x_appstore)
        # No handle, so nothing of it: not the code, key, strings, table or logo.
        check(make_app(root, "x-code-without-handle", x_feature, app_info()), passes=False,
              expect="carries Follow developer on X")
        check(make_app(root, "x-key-without-handle", clean, x_info), passes=False,
              expect="has AndariumFollowXHandle though the build names no handle")
        check(make_app(root, "x-framework-without-handle", clean, app_info(), framework=x_feature),
              passes=False, expect="Runtime.framework/Runtime: carries Follow developer on X")
        x_words = make_app(root, "x-words", clean, app_info())
        (x_words / "en.lproj").mkdir()
        (x_words / "en.lproj" / "Localizable.strings").write_bytes(
            plistlib.dumps({"Follow developer on %@": "Follow developer on %@"}, fmt=plistlib.FMT_BINARY))
        check(x_words, passes=False, expect="has Follow developer on X strings")
        for name, suffix, content in (
                ("strings", "strings", {"Hello": "Hello"}), ("stringsdict", "stringsdict", {})):
            table = make_app(root, f"x-table-{name}", clean, app_info())
            (table / "en.lproj").mkdir()
            (table / "en.lproj" / f"FollowX.{suffix}").write_bytes(plistlib.dumps(content, fmt=plistlib.FMT_BINARY))
            expect = f"en.lproj/FollowX.{suffix}: is the FollowX strings table though the build names no handle"
            check(table, passes=False, expect=expect)
            for configuration in ("Debug", "Release"):
                check(table, passes=False, expect=expect, args=[*x_other, configuration])
        check(make_app(root, "x-logo-without-handle", clean, app_info(), follow_x_logo=True), passes=False,
              expect="Assets.car: holds the logo of Follow developer on X though the build names no handle")
        for artwork in ("x-logo.svg", "glyph.svg"):
            loose = make_app(root, f"x-loose-{artwork}", clean, app_info())
            (loose / artwork).write_bytes(b"<svg/>")
            check(loose, passes=False, expect=f"{artwork}: is artwork of the row")
            check(make_app(root, f"x-loose-named-{artwork}", x_feature, x_info), passes=True, args=x_appstore)
        # A product with the handle holds the table in every language.
        check(make_app(root, "x-table-missing", x_feature, x_info, follow_x_tables=False), passes=False,
              expect="lacks the FollowX strings table in ja, zh-Hans, zh-Hant", args=x_appstore)
        x_partly = make_app(root, "x-table-partial", x_feature, x_info, follow_x_tables=False)
        write_follow_x_tables(x_partly, ("ja", "zh-Hans"))
        check(x_partly, passes=False, expect="lacks the FollowX strings table in zh-Hant", args=x_appstore)
        # The handle of the local configuration is one of X's: 1 to 15 letters,
        # digits and underscores, and not the placeholder. (FollowXProfile.isWellFormed
        # holds the same rules; AndariumCore's FollowXTests pin that side.)
        for index, bad in enumerate((
                "a" * 16, "has space", "dash-x", "@someone", "https://x.com/someone", "someone/", "so.meone",
                "some\none", "\u00e9cole", "example_handle", "Example_Handle", "EXAMPLE_HANDLE")):
            check(make_app(root, f"x-handle-{index}", x_feature, app_info(AndariumFollowXHandle=bad)),
                  passes=False, expect="Follow developer on X: the handle in the local configuration",
                  args=["--follow-x-handle", bad])
        for index, good in enumerate(("a", "A_1", "_", "a" * 15, "someone_real", "Some_One_99")):
            check(make_app(root, f"x-handle-ok-{index}", x_feature, app_info(AndariumFollowXHandle=good)),
                  passes=True, expect="Follow developer on X is compiled in", args=["--follow-x-handle", good])
        # A build that names no handle still has the row's file names in the linker's
        # debug map of its Debug or Release product; the map's symbol names count.
        mapped_x = build_with_debug_map(root, "mapped-x", "/Users/NAME/FollowXRow")
        symbol_x = build_with_debug_map(
            root, "symbol-x", "/Users/NAME/Project",
            "__attribute__((visibility(\"hidden\"))) int plain_first(void) { return 2; }\n"
            "__attribute__((visibility(\"hidden\"))) int _s8Andarium11FollowXRowV4bodyyF(void) { return 1; }\n")
        for configuration in ("Debug", "Release"):
            check(make_app(root, f"x-{configuration}-debug-map", mapped_x, app_info()),
                  passes=True, expect=f"Follow developer on X is not compiled in ({configuration})",
                  args=[*x_other, configuration])
            check(make_app(root, f"x-{configuration}-symbol-only", symbol_x, app_info()),
                  passes=False, expect="carries Follow developer on X (FollowXRow)", args=[*x_other, configuration])
        check(make_app(root, "x-appstore-debug-map", mapped_x, app_info()), passes=True,
              expect="Follow developer on X is not compiled in")
        check(make_app(root, "x-appstore-symbol-only", symbol_x, app_info()),
              passes=False, expect="carries Follow developer on X (FollowXRow)")
        x_debug = make_app(root, "x-debug-library", clean, app_info())
        shutil.copyfile(x_feature, x_debug / "Fixture.debug.dylib")
        check(x_debug, passes=False, expect="Fixture.debug.dylib: carries Follow developer on X")
        # The other configurations: absent, or the arranged placeholder, which Debug alone takes.
        x_arranged_info = app_info(AndariumFollowXHandle="example_handle")
        for configuration in ("Debug", "Release"):
            check(make_app(root, f"x-{configuration}-absent", clean, app_info()), passes=True,
                  expect=f"Follow developer on X is not compiled in ({configuration})", args=[*x_other, configuration])
            # The local configuration's handle never reaches them.
            check(make_app(root, f"x-{configuration}-handle", x_feature, x_info), passes=False,
                  expect="not the arranged placeholder", args=[*x_other, configuration, *x_appstore])
            check(make_app(root, f"x-{configuration}-code", x_feature, app_info()), passes=False,
                  expect="carries Follow developer on X", args=[*x_other, configuration])
            check(make_app(root, f"x-{configuration}-key", clean, x_info), passes=False,
                  expect="though the build names no handle", args=[*x_other, configuration])
        check(make_app(root, "x-Debug-arranged", x_feature, x_arranged_info), passes=True,
              expect="Follow developer on X is compiled in (Debug)", args=[*x_other, "Debug", *x_arranged])
        check(make_app(root, "x-Release-arranged", x_feature, x_arranged_info), passes=False,
              expect="only Debug takes the arrangement", args=[*x_other, "Release", *x_arranged])
        check(make_app(root, "x-Release-arranged-absent", clean, app_info()), passes=False,
              expect="only Debug takes the arrangement", args=[*x_other, "Release", *x_arranged])
        check(make_app(root, "x-appstore-arranged", x_feature, x_arranged_info), passes=False,
              expect="placeholder handle", args=x_arranged)
        # The arranged placeholder is in no product that does not arrange it.
        x_stray = make_app(root, "x-placeholder-stray", clean, app_info())
        (x_stray / "Data.bin").write_bytes(b"\0Example_Handle\0")
        check(x_stray, passes=False, expect="Data.bin: holds the placeholder handle of the arrangement")
        check(x_stray, passes=False, expect="Data.bin: holds the placeholder handle of the arrangement",
              args=[*x_other, "Debug"])
        check(make_app(root, "x-placeholder-key", clean, x_arranged_info), passes=False,
              expect="Info.plist: holds the placeholder handle of the arrangement")
        # The tip header's X button names a handle of its own. It shares the logo and the
        # profile address's builder with the row and nothing else: the row's code, key and
        # table stay out of a product that names no handle for the row.
        sheet_info = app_info(AndariumDeveloperX=handle)
        sheet_args = ["--developer-x", handle]
        profile_only = build(root, "x-profile-only", FOLLOW_X_PROFILE_ONLY)
        check(make_app(root, "x-sheet", profile_only, sheet_info), passes=True,
              expect="Follow developer on X is not compiled in", args=[*x_other, "AppStore", *sheet_args, *x_local])
        check(make_app(root, "x-sheet-no-logo", profile_only, sheet_info, follow_x_logo=False), passes=False,
              expect="Assets.car: lacks the logo of Follow developer on X", args=[*x_other, "AppStore", *sheet_args])
        check(make_app(root, "x-sheet-no-builder", clean, sheet_info), passes=False,
              expect="lacks the profile address's builder", args=[*x_other, "AppStore", *sheet_args])
        check(make_app(root, "x-sheet-row-code", x_feature, sheet_info), passes=False,
              expect="carries Follow developer on X (", args=[*x_other, "AppStore", *sheet_args])
        check(make_app(root, "x-sheet-row-key", profile_only, {**sheet_info, **x_info}), passes=False,
              expect="has AndariumFollowXHandle though the build names no handle",
              args=[*x_other, "AppStore", *sheet_args])
        check(make_app(root, "x-sheet-row-table", profile_only, sheet_info, follow_x_tables=True), passes=False,
              expect="is the FollowX strings table though the build names no handle",
              args=[*x_other, "AppStore", *sheet_args])
        check(make_app(root, "x-sheet-other-local", profile_only, sheet_info), passes=True,
              expect="Follow developer on X is not compiled in",
              args=[*x_other, "AppStore", *sheet_args, "--developer-x-handle", "someone_else"])
        leaked_sheet = make_app(root, "x-sheet-address", profile_only, sheet_info)
        (leaked_sheet / "Data.bin").write_bytes(b"https://x.com/someone_else")
        check(leaked_sheet, passes=False, expect="Data.bin: holds the handle of the local configuration",
              never="someone_else", args=[*x_other, "AppStore", *sheet_args, "--developer-x-handle", "someone_else"])
        # The row and the header may name the same handle, and each product has the logo once.
        check(make_app(root, "x-sheet-and-row", x_feature, {**sheet_info, **x_info}), passes=True,
              expect="Follow developer on X is compiled in", args=[*x_other, "AppStore", *x_appstore, *sheet_args])
        # Debug's arrangement of the placeholder handle for the header alone.
        check(make_app(root, "x-sheet-arranged", profile_only, app_info(AndariumDeveloperX="example_handle")),
              passes=True, expect="Follow developer on X is not compiled in (Debug)",
              args=[*x_other, "Debug", "--developer-x", "example_handle"])
        # Both features' phase in one run says both.
        both = checkers.run(["--feedback", "--follow-x", "--configuration", "Debug",
                             str(make_app(root, "x-both", clean, app_info()))])
        if both.returncode != 0 or "Send feedback is not compiled in (Debug)" not in both.stdout \
                or "Follow developer on X is not compiled in (Debug)" not in both.stdout:
            failures.append(f"x-both: expected both features reported:\n{both.stdout}")

        # The local handle is in no file of a bundle that does not name it, as a
        # profile address or as a whole string of a property list, and the check
        # never prints it. The bare word is no leak: it is also in the bundle
        # identifier, the name of a keychain item and the project's page.
        x_address = build(root, "x-address", f'const char *fixture(void) {{ return "https://x.com/{handle}"; }}\n')
        x_old_address = build(root, "x-old-address", f'const char *fixture(void) {{ return "twitter.com/{handle}"; }}\n')
        x_data = make_app(root, "x-leak-data-file", clean, app_info())
        (x_data / "Data.bin").write_bytes(b"\0\1HTTPS://X.COM/" + handle.upper().encode() + b"\2")
        x_plist = make_app(root, "x-leak-plist-value", clean, app_info(Developer=handle.upper()))
        x_strings = make_app(root, "x-leak-strings", clean, app_info())
        (x_strings / "en.lproj").mkdir()
        (x_strings / "en.lproj" / "Localizable.strings").write_bytes(
            plistlib.dumps({"Contact": handle}, fmt=plistlib.FMT_BINARY))
        x_straddle = make_app(root, "x-leak-straddle", clean, app_info())
        (x_straddle / "Big.bin").write_bytes(b"\0" * ((8 << 20) - 5) + f"x.com/{handle}".encode() + b"\0")
        x_leaks = (
            ("executable", make_app(root, "x-leak-executable", x_address, app_info()), "Fixture"),
            ("old-address", make_app(root, "x-leak-old", x_old_address, app_info()), "Fixture"),
            ("framework", make_app(root, "x-leak-framework", clean, app_info(), framework=x_address),
             "Frameworks/Runtime.framework/Runtime"),
            ("data-file", x_data, "Data.bin"),
            ("plist-value", x_plist, "Info.plist"),
            ("strings", x_strings, "en.lproj/Localizable.strings"),
            ("straddle", x_straddle, "Big.bin"),
        )
        for name, app, path in x_leaks:
            for configuration in ("Debug", "Release"):
                for arguments in (x_local, [*x_local, *x_arranged]):
                    check(app, passes=False, expect=f"{path}: holds the handle of the local configuration",
                          never=handle, args=[*x_other, configuration, *arguments])
            check(app, passes=False, expect=f"{path}: holds the handle of the local configuration",
                  never=handle, args=x_local)
        # The bare word is in a bundle that does not name it, as the real one is.
        word = make_app(
            root, "x-word-only",
            build(root, "x-word", f'const char *fixture(void) {{ return "https://github.com/{handle}/Project"; }}\n'),
            app_info(CFBundleIdentifier=f"org.{handle}.Fixture"))
        (word / "Data.bin").write_bytes(f"keychain org.{handle}.fixture.key".encode())
        check(word, passes=True, expect="ready for the App Store", args=x_local)
        check(word, passes=True, expect="Follow developer on X is not compiled in (Debug)",
              args=[*x_other, "Debug", *x_local])
        check(make_app(root, "x-leak-none", clean, app_info(), framework=clean), passes=True,
              expect="ready for the App Store", args=x_local)
        check(make_app(root, "x-leak-none-arranged", x_feature, x_arranged_info), passes=True,
              expect="Follow developer on X is compiled in (Debug)", args=[*x_other, "Debug", *x_local, *x_arranged])
        # An App Store build that names it holds it in Info.plist, and may hold the address too.
        check(make_app(root, "x-leak-named", x_feature, x_info), passes=True,
              expect="Follow developer on X is compiled in", args=x_appstore)
        x_named = make_app(root, "x-leak-named-elsewhere", x_feature, x_info)
        (x_named / "Data.bin").write_bytes(f"x.com/{handle}".encode())
        check(x_named, passes=True, expect="Follow developer on X is compiled in", args=x_appstore)
        # The two features are independent: each in its product, each absent from the other's.
        check(make_app(root, "both-built", x_feature, {**feedback_info, **x_info}), passes=False,
              expect="has AndariumFeedbackAddress though the build names no receiver", args=x_appstore)
        check(make_app(root, "x-only-built", x_feature, x_info), passes=True,
              expect="Send feedback is not compiled in", args=x_appstore)
        check(make_app(root, "feedback-only-built", feature, feedback_info), passes=True,
              expect="Follow developer on X is not compiled in", args=appstore)

        # The built Info.plist keeps every value of Config/Info.plist, whichever
        # way the feedback block went: the preprocessor changes the feedback key
        # alone. The source here has a build setting inside a nested value, as
        # the real one does, and the feedback block.
        source = root / "Info.plist.source"
        source.write_text(INFO_SOURCE, encoding="utf-8")
        scene = {"UISceneConfigurations": {"Role": [{"UISceneConfigurationName": "Fixture",
                                                      "UISceneDelegateClassName": "Fixture.SceneDelegate"}]}}
        base_info = {"UIApplicationSceneManifest": scene}
        info_args = ["--info-source", str(source)]
        for configuration, extra, info in (
                ("Debug", [], app_info(**base_info)),
                ("Release", [], app_info(**base_info)),
                ("Debug", arranged, app_info(AndariumFeedbackAddress="feedback@example.com", **base_info))):
            code = feature if extra else clean
            check(make_app(root, f"info-source-{configuration}-{len(extra)}", code, info), passes=True,
                  expect="not compiled in" if not extra else "compiled in",
                  args=[*other, configuration, *extra, *info_args])
        check(make_app(root, "info-source-appstore", clean, app_info(**base_info)), passes=True,
              expect="ready for the App Store", args=info_args)
        check(make_app(root, "info-source-x-Debug", x_feature,
                       app_info(AndariumFollowXHandle="example_handle", **base_info)),
              passes=True, expect="compiled in", args=[*x_other, "Debug", *x_arranged, *info_args])
        check(make_app(root, "info-source-x-appstore", x_feature, app_info(AndariumFollowXHandle=handle, **base_info)),
              passes=True, expect="ready for the App Store", args=[*x_appstore, *info_args])
        check(make_app(root, "info-source-appstore-named", feature,
                       app_info(AndariumFeedbackAddress=receiver, **base_info)),
              passes=True, expect="ready for the App Store", args=[*appstore, *info_args])
        # A value the preprocessor changed: a macro expanded in a string, in a
        # list, in a nested value; a key it lost.
        for name, info, expect in (
                ("string", app_info(CFBundleName="1", **base_info), "CFBundleName differs"),
                ("list", app_info(UIRequiredDeviceCapabilities=["arm64", "1"], **base_info),
                 "UIRequiredDeviceCapabilities differs"),
                ("longer-list", app_info(UIRequiredDeviceCapabilities=["arm64", "metal", "1"], **base_info),
                 "UIRequiredDeviceCapabilities differs"),
                ("nested", app_info(UIApplicationSceneManifest={"UISceneConfigurations": {"Role": [
                    {"UISceneConfigurationName": "1", "UISceneDelegateClassName": "Fixture.SceneDelegate"}]}}),
                 "UIApplicationSceneManifest differs"),
                ("setting-gone", app_info(UIApplicationSceneManifest={"UISceneConfigurations": {"Role": [
                    {"UISceneConfigurationName": "Fixture", "UISceneDelegateClassName": 1}]}}),
                 "UIApplicationSceneManifest differs"),
                ("flag", app_info(ITSAppUsesNonExemptEncryption=True, **base_info),
                 "ITSAppUsesNonExemptEncryption differs"),
                ("missing", app_info(CFBundleName=None, **base_info), "CFBundleName of Info.plist.source is missing"),
                ("missing-nested", app_info(UIApplicationSceneManifest={}),
                 "UIApplicationSceneManifest differs")):
            for configuration in ("Debug", "Release"):
                check(make_app(root, f"info-source-{name}-{configuration}", clean, info), passes=False,
                      expect=expect, args=[*other, configuration, *info_args])
            check(make_app(root, f"info-source-{name}-appstore", clean, info), passes=False,
                  expect=expect, args=info_args)
        # A source that cannot be read is no pass.
        check(make_app(root, "info-source-absent", clean, app_info(**base_info)), passes=False,
              expect="cannot be compared", args=["--info-source", str(root / "absent.plist")])

        # The document pickers. The App Store configuration opens files in
        # place: both of SwiftUI's importers are referred to, and no trace of the
        # copy-mode presenter is in the application or in a framework. Whoever
        # takes the condition away leaves the presenter in, or the importers out.
        check(make_app(root, "pickers-in-place", clean, app_info()), passes=True,
              expect="document pickers open the files in place")
        for missing_name, lacking in (("one file", ONE_FILE_IMPORTER), ("several files", SEVERAL_FILES_IMPORTER)):
            kept = IN_PLACE_PICKERS.replace(lacking, "")
            check(make_app(root, f"pickers-lack-{missing_name.replace(' ', '-')}",
                           build(root, f"lack-{missing_name.replace(' ', '-')}", CLEAN, pickers=kept), app_info()),
                  passes=False, expect=f"lacks fileImporter for {missing_name}")
        check(make_app(root, "pickers-none", build(root, "no-pickers", CLEAN, pickers=""), app_info()),
              passes=False, expect="lacks fileImporter for one file (Install APK)")
        for index, (what, source) in enumerate(COPY_PICKERS):
            presenter = build(root, f"presenter{index}", CLEAN, pickers=IN_PLACE_PICKERS + source)
            check(make_app(root, f"pickers-copy-app-{index}", presenter, app_info()), passes=False,
                  expect="carries the copy-mode document picker")
            check(make_app(root, f"pickers-copy-framework-{index}", clean, app_info(), framework=presenter),
                  passes=False, expect="carries the copy-mode document picker")
            # Without the importers too: the copy-mode picker in place of them.
            replaced = build(root, f"replaced{index}", CLEAN, pickers=source)
            check(make_app(root, f"pickers-replaced-{index}", replaced, app_info()), passes=False,
                  expect="carries the copy-mode document picker")
        # Every other configuration copies the files: its product holds the
        # presenter, and the check says so, which shows it finds one.
        copying = build(root, "copying", CLEAN, pickers="".join(source for _what, source in COPY_PICKERS))
        for configuration in ("Debug", "Release"):
            check(make_app(root, f"pickers-{configuration}-copy", copying, app_info()), passes=True,
                  expect="document pickers copy the files", args=["--pickers", "--configuration", configuration])
            check(make_app(root, f"pickers-{configuration}-in-place", clean, app_info()), passes=False,
                  expect="lacks the copy-mode document picker", args=["--pickers", "--configuration", configuration])
            # The debug library of a Debug build holds the code, as for Send feedback.
            debug_library = make_app(root, f"pickers-{configuration}-library", clean, app_info())
            shutil.copyfile(copying, debug_library / "Fixture.debug.dylib")
            check(debug_library, passes=True, expect="document pickers copy the files",
                  args=["--pickers", "--configuration", configuration])

        # The privacy manifests are checked too.
        check(make_app(root, "no-manifest", clean, app_info(), manifest=False),
              passes=False, expect="PrivacyInfo.xcprivacy")

        check_command_line(options.checker, checkers, root, clean, knob, failures)
        check_exit_values(checkers, failures)

    for failure in failures:
        print(failure, file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
