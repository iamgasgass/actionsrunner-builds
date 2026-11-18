#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Capture every screen and state of Andarium from the Simulator preview.

AndariumPreview opens any screen with mock data from a launch argument
(`-screen <name>`, see Preview/AppEntry.swift). This script launches each
screen in the build already installed on a Simulator and saves a labelled PNG
for it, plus a manifest.json that says, per file, the device, orientation,
appearance, screen and what to look at. It installs nothing and rotates
nothing: build and install AndariumPreview first, rotate an iPad (Simulator:
Device > Rotate, or a UI driver) between runs, and the orientation is read
from each image.

    capture-screens.py --out DIR --device <udid> [--device <udid> ...]
    capture-screens.py --out DIR --device <udid> --language ja
    capture-screens.py --list

`--language` runs the Preview in one of Andarium's languages (en, zh-Hans,
zh-Hant, ja): the launch carries `-AppleLanguages` and `-AppleLocale`, the
file names and the manifest name the language, and the Simulator's own
language stays as it is. Without it the Simulator's language decides.

One run at a time captures into a directory: the runs would share the
screenshots' working files and read and write manifest.json. A second run into
the same --out refuses at once and names the first; the lock is released when
the run ends, however it ends. Name several --device options for one run, or
give each run its own --out.

Capture on a Simulator made for the run (`simctl create`, deleted afterwards),
never one another session or test uses: any other app that comes to the front
spoils a picture. The script keeps a picture only when the Preview reports
(`capture-state.json`, written by `Preview/CaptureState.swift`) that it is the
launched process, on the shot's screen, and active, both before and after the
screenshot, and the frame is neither blank nor black; a shot that fails is
reported and not recorded.

A shot with `-systemMicrophone YES` (or `-systemLocation YES`) runs the
Microphone (or Location) switch against the Simulator's own permission: the
script sets it first with `simctl privacy` (grant, revoke or reset), and the
revoked-while-backgrounded shot takes the permission away while the app is in
the background. The Simulator keeps the system's permission alert up, over
whatever launches next, until SpringBoard is restarted, and a restart turns an
iPad upright. A launch under such an alert leaves the app inactive, which the
check above refuses, so the shots that raise the alert run last, and
SpringBoard is restarted after each: rotate the iPad again before the next
run.

The shots of Send feedback exist only in a Preview built with the arrangement
that turns the feature on, which gives it the example receiver and never reads
the local file:

    xcodebuild -project Andarium/Andarium.xcodeproj -scheme AndariumPreview \\
        -destination 'generic/platform=iOS Simulator' \\
        FEEDBACK_ADDRESS=feedback@example.com build

Without it the Preview has no Send feedback, its shots are skipped and said
so, and the rest is unaffected. The shots of Buy me tokens are the same: they
need the four settings of its arrangement, which carry the example product
identifiers and never read the local file:

        TIP_LITE=com.example.andarium.tip.lite TIP_PRO=com.example.andarium.tip.pro \\
        TIP_MAX=com.example.andarium.tip.max TIP_ULTRA=com.example.andarium.tip.ultra

The header of Buy me tokens shows the developer's avatar, name and profile
logos in a Preview built with `SHEET_DEVELOPER_NAME=example
SHEET_DEVELOPER_GITHUB=example SHEET_DEVELOPER_X=example_handle` (and
`SHEET_ARTWORK_SOURCE=local` with `FOLLOW_X_LOGO_SOURCE=local` for the files of
`Config/Local/`); without them it reads the role alone.

The shots of Info's filing number (`info-icp…`) need a Preview built with
`ICP_NUMBER=示例ICP备00000000号-0A`, which is the placeholder and never the
local file's number; without it they are skipped and said so. The storefront is
the Preview's own (`-icpStorefront CHN|USA|none`), so that a shot does not depend
on the Simulator's account.

The Info shots show Follow developer on X in a Preview built with
`FOLLOW_X_HANDLE=example_handle` (and `FOLLOW_X_LOGO_SOURCE=local` for the real
logo from `Config/Local/`); without it the row is absent from them.

Light mode is captured for every screen; dark mode only for the screens flagged
in the table, where the design adapts to it. Every Simulator command has a hard
time bound. A rerun replaces the files and manifest entries it captures and
keeps the rest.
"""

from __future__ import annotations

__import__("sys").dont_write_bytecode = True

import argparse
import contextlib
import fcntl
import json
import os
import re
import struct
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

BUNDLE = "com.imxieyi.AndariumPreview"
COMMAND_SECONDS = 60
SETTLE_SECONDS = 15
SETTLED_FRACTION = 0.003
# How long the Preview has, after a launch, to report that it is the app in front.
FRONT_SECONDS = 10
STATE_FILE = "capture-state.json"
# The languages of the application and the locale each is shown with.
LANGUAGES = {"en": "en_US", "zh-Hans": "zh_CN", "zh-Hant": "zh_TW", "ja": "ja_JP"}
LOCK_FILE = ".capture.lock"


@dataclass(frozen=True)
class Shot:
    id: str
    group: str
    screen: str
    description: str
    args: tuple[str, ...] = ()
    dark: bool = False
    wait: float = 3.0
    # The Simulator's permission before the launch: "grant", "revoke" or "reset" (not asked).
    privacy: str | None = None
    # Which permission `privacy` and `flow` set: the `simctl privacy` service.
    service: str = "microphone"
    # Steps after the launch, for a state that needs the app in the background: "background", "grant", "revoke",
    # "foreground".
    flow: tuple[str, ...] = ()
    # The shot raises the system's own alert, which stays up over whatever launches next: it runs last, and
    # SpringBoard is restarted after it.
    alert: bool = False
    # The screen is Send feedback's, which only a Preview built with FEEDBACK_ADDRESS has.
    feedback: bool = False
    # The screen is Buy me tokens', which only a Preview built with the four TIP_ settings has.
    tipjar: bool = False
    # The screen shows the ICP filing number, which only a Preview built with ICP_NUMBER has.
    icp: bool = False

    def launch_arguments(self, language: str | None = None) -> list[str]:
        arguments = ["-screen", self.screen, *self.args]
        if language is not None:
            arguments += ["-AppleLanguages", f"({language})", "-AppleLocale", LANGUAGES[language]]
        return arguments


def s(id: str, group: str, screen: str, description: str, *args: str, dark: bool = False, wait: float = 3.0) -> Shot:
    return Shot(id, group, screen, description, tuple(args), dark, wait)


def feedback(id: str, screen: str, description: str, *args: str, dark: bool = False, wait: float = 14.0) -> Shot:
    """A shot of Send feedback, which exists only in a Preview built with `FEEDBACK_ADDRESS=feedback@example.com`."""
    return Shot(id, "Feedback", screen, description, tuple(args), dark, wait, feedback=True)


def tipjar(id: str, screen: str, description: str, *args: str, dark: bool = False, wait: float = 8.0) -> Shot:
    """A shot of Buy me tokens, which exists only in a Preview built with the arrangement of the four `TIP_` settings."""
    return Shot(id, "Buy me tokens", screen, description, tuple(args), dark, wait, tipjar=True)


def icp(id: str, screen: str, description: str, *args: str, dark: bool = False, wait: float = 4.0) -> Shot:
    """A shot of Info's filing number, which exists only in a Preview built with the arranged `ICP_NUMBER`."""
    return Shot(id, "Info", screen, description, tuple(args), dark, wait, icp=True)


SYSTEM = ("-systemMicrophone", "YES")
SYSTEM_LOCATION = ("-systemLocation", "YES")
SYSTEM_CAMERA = ("-systemCamera", "YES")


def system_mic(id: str, group: str, screen: str, description: str, privacy: str, *flow: str) -> Shot:
    """A shot with the Microphone switch on the Simulator's own permission, set to `privacy` first."""
    return Shot(id, group, screen, description, SYSTEM, privacy=privacy, flow=tuple(flow), alert=privacy == "reset")


def system_location(id: str, group: str, screen: str, description: str, privacy: str, *flow: str, alert: bool | None = None) -> Shot:
    """A shot with the Location switch on the Simulator's own permission, set to `privacy` first. `alert` says the
    shot raises the system's question; a reset permission does when the screen turns the switch on."""
    return Shot(
        id, group, screen, description, SYSTEM_LOCATION, privacy=privacy, service="location", flow=tuple(flow),
        alert=privacy == "reset" and screen == "home-location-ask" if alert is None else alert,
    )


def system_camera(id: str, group: str, screen: str, description: str) -> Shot:
    """A shot with the Camera switch on the Simulator's own permission, reset first so that it has not been asked.
    `simctl privacy` has no camera service to grant or revoke, so only the question can be raised this way; the
    refused and restricted states are the preview's own (`home-camera-denied`, `home-camera-restricted`). The service
    is `all` because a reset names no camera."""
    return Shot(id, group, screen, description, SYSTEM_CAMERA, privacy="reset", service="all", alert=True)


def boot_stages(prefix: str, screen: str, names: list[str], what: str, dark_step: int | None = None) -> list[Shot]:
    return [
        s(
            f"{prefix}-{index}-{name.lower().replace(' ', '-')}",
            "Boot",
            screen,
            f"{what}, step {index + 1} of {len(names)} ({name}) under way.",
            "-bootStage",
            str(index),
            dark=index == dark_step,
        )
        for index, name in enumerate(names)
    ]


SHOTS: list[Shot] = [
    # Home
    s("home", "Home", "home", "Home with a configured guest: Virtual machine (matched rows: CPU and memory with Edit, Resolution with Change, then Storage with its usage bar and Resize, and Snapshots), JIT (in the builds that have it), Capabilities, Backup, Erase virtual machine, and the Start bar.", dark=True),
    s("home-welcome", "Home", "welcome", "Home before any guest exists: the welcome and Set up virtual machine. First screen of the initial setup."),
    s("home-first-start", "Home", "home-new", "A guest just created and not yet started: Home as it is before the first start."),
    s("home-resolution", "Home", "home-resolution", "Home scrolled to Virtual machine: the Resolution row between CPU and memory and Storage, with the guest's pixels (nobody has chosen, and the device states no memory limit: 320 dpi) and, where the choice is an end, its name, and Change.", dark=True),
    s("home-resolution-low-memory", "Home", "home-resolution", "The Resolution row of someone who never chose, on a device the system holds to 2,867 MiB of memory (an iPad mini 6's): 240 dpi, the pixels alone.", "-memoryLimitMiB", "2867"),
    s("home-resolution-native-2", "Home", "home-resolution", "The Resolution row of someone who never chose, on a 744 x 1133 point screen of native scale 2.0 with no memory limit: 320 dpi is native there, so the line says Native.", "-displayNative", "2", "-displayPoints", "744x1133"),
    s("home-resolution-native-2-low-memory", "Home", "home-resolution", "The same screen held to 2,867 MiB: 240 dpi, the pixels alone.", "-displayNative", "2", "-displayPoints", "744x1133", "-memoryLimitMiB", "2867"),
    s("home-resolution-fastest", "Home", "home-resolution", "The Resolution row with the fastest choice (one guest pixel to a point): the line says Fastest.", "-displayScale", "1"),
    s("home-resolution-middle", "Home", "home-resolution", "The Resolution row with a choice between the ends: the pixels alone.", "-displayScale", "1.5"),
    s("home-resolution-one-choice", "Home", "home-resolution", "The Resolution row on a screen with one choice (native scale 1.0): the resolution without a name, and Change dimmed.", "-displayNative", "1"),
    s("home-capabilities", "Home", "home-capabilities", "Home scrolled to Capabilities: Location off, Microphone off, Camera off and, on an iPhone, Haptics on (their defaults), no notes.", dark=True),
    s("home-jit", "Home", "home-jit", "Home scrolled to JIT: the toggle on and a debugger attached, so the note says it is ready for the next start.", dark=True),
    s("home-jit-no-debugger", "Home", "home-jit-no-debugger", "JIT on with no debugger attached: the note says to open Andarium from StikDebug."),
    s("home-jit-fallback", "Home", "home-jit-fallback", "Home after a start that ran without the JIT it was asked for: the note says StikDebug was not connected."),
    s("home-capabilities-mic-on", "Home", "home-mic-on", "Capabilities with Microphone on, iOS having allowed it."),
    s("home-capabilities-mic-denied", "Home", "home-mic-denied", "Capabilities after iOS refused the microphone or its app permission was removed: the row is dimmed and says it is not allowed in Settings.", dark=True),
    s("home-capabilities-mic-alert", "Home", "home-mic-alert", "Turning Microphone on while iOS refuses it: the alert that offers Settings."),
    s("home-capabilities-haptics-off", "Home", "home-haptics-off", "Capabilities on an iPhone after Haptics was turned off; an iPad has no Haptics row.", dark=True),
    s("home-capabilities-location-on", "Home", "home-location-on", "Capabilities with Location on, iOS having allowed it with the exact position."),
    s("home-capabilities-location-approximate", "Home", "home-location-approximate", "Location on while iOS gives only an approximate location: the line under it says Approximate location, with an info mark that explains.", dark=True),
    s("home-capabilities-location-approximate-alert", "Home", "home-location-approximate-alert", "The explanation behind Approximate location: Precise Location is off for Andarium, with Open Settings."),
    s("home-capabilities-location-denied", "Home", "home-location-denied", "Capabilities after iOS refused the location or its app permission was removed: the row is dimmed and says it is not allowed in Settings.", dark=True),
    s("home-capabilities-location-alert", "Home", "home-location-alert", "Turning Location on while iOS refuses it: the alert that offers Settings."),
    s("home-capabilities-location-restricted", "Home", "home-location-restricted", "Capabilities on a device that restricts the location (Screen Time or a profile): the row is dimmed and says it is restricted."),
    s("home-capabilities-location-restricted-alert", "Home", "home-location-restricted-alert", "Turning Location on while the device restricts it: the alert explains and has only OK."),
    s("home-capabilities-location-services-off", "Home", "home-location-services-off", "Capabilities while Location Services are off for the whole device: the row is dimmed and says so."),
    s("home-capabilities-location-services-off-alert", "Home", "home-location-services-off-alert", "Turning Location on while Location Services are off: the alert explains where to turn them on."),
    s("home-capabilities-camera-on", "Home", "home-camera-on", "Capabilities with Camera on, iOS having allowed it.", dark=True),
    s("home-capabilities-camera-denied", "Home", "home-camera-denied", "Capabilities after iOS refused the camera or its app permission was removed: the row is dimmed and says it is not allowed in Settings.", dark=True),
    s("home-capabilities-camera-alert", "Home", "home-camera-alert", "Turning Camera on while iOS refuses it: the alert that offers Settings.", dark=True),
    s("home-capabilities-camera-restricted", "Home", "home-camera-restricted", "Capabilities on a device that restricts the camera (Screen Time or a profile): the row is dimmed and says it is restricted.", dark=True),
    s("home-capabilities-camera-restricted-alert", "Home", "home-camera-restricted-alert", "Turning Camera on while the device restricts it: the alert explains and has only OK.", dark=True),
    s("home-capabilities-camera-unavailable", "Home", "home-camera-unavailable", "Capabilities on a device with no camera (the Simulator, say): Camera is disabled and the note says there is no camera to share.", dark=True),
    s("home-backup", "Home", "home-backup", "Home scrolled to Backup: the Include in backups switch and the note under it."),
    s("home-erase", "Home", "home-erase", "Home scrolled to the end: Erase virtual machine in a card of its own, with no heading.", dark=True),
    s("home-storage-grow", "Home", "home-grow", "Virtual machine with a larger storage size chosen: the Storage row's bar outlines the new size and the note under it says the growth takes effect at the next start.", dark=True),
    s("home-storage-max", "Home", "home-max", "Virtual machine with storage at its largest size (128 GiB, in 4 GiB steps): the note under the Storage bar says so and Resize is dimmed.", dark=True),
    s("home-update", "Home", "home-update", "A system update waiting: the card above the Start bar."),
    s("home-update-unfinished", "Home", "home-update-failed", "An update that did not finish: the card offers retry or restoring the saved data."),
    s("home-update-unfinished-restore-only", "Home", "home-update-failed-restore", "An unfinished update that can only be restored."),
    s("home-blocked", "Home", "home-blocked", "Start blocked because the guest is newer than the system in this app."),
    s("home-notice-closed", "Home", "home-closed", "The notice shown after iOS closed Andarium while it was paused."),
    s("home-notice-network-cellular", "Home", "home-network-cellular", "The notice that iOS denies Andarium cellular data, with the way to Settings.", dark=True),
    s("home-notice-network-wifi", "Home", "home-network-wifi", "The notice that iOS denies Andarium Wi-Fi, with the way to Settings.", dark=True),
    s("home-notice-ended", "Home", "home-ended", "The notice shown at the launch after Android's previous session ended badly, here in a kernel panic."),
    s("home-notice-low-space", "Home", "home-low-space", "The low free space notice on Home."),
    s("home-notice-memory-high", "Home", "home-memory-warning", "A guest with more memory than a new one gets (the most the device offers): the notice above Virtual machine says iOS is likely to close Andarium and what is safer.", dark=True),
    s("busy-create", "Operations", "busy-create", "The overlay while the guest is created: title, detail and progress."),
    s("busy-erase", "Operations", "busy-erase", "The overlay while the guest is erased."),
    s("alert-error", "Alerts", "alert-error", "An error alert (an operation that failed with the system's message)."),
    # Sheets and dialogs
    s("setup-new-guest", "Setup", "create", "The initial setup sheet: Storage and Backup only; vCPUs and memory are no longer asked.", dark=True),
    s("setup-new-guest-low-space", "Setup", "create-low-space", "The setup sheet when the device lacks the free space the first start needs: the notice and a disabled Create."),
    s("start-low-space-alert", "Setup", "start-low-space", "Start pressed without enough free space: the alert."),
    s("storage-resize", "Sheets", "resize", "The Resize sheet for the guest's storage."),
    s("system-edit", "Sheets", "system-edit", "The System sheet, opened from Edit: vCPUs and memory with the device's limits, and beneath them the estimated VRAM (graphics memory) with the note that it is separate from the guest's RAM. A guest at the default memory shows no warning.", dark=True),
    s("system-edit-memory-high", "Sheets", "system-memory-warning", "The System sheet with memory above what a new guest gets (the most the device offers): the ticks past the default are orange, the line beneath the ruler says iOS is likely to close Andarium above it and the VRAM estimate is orange.", dark=True),
    s("system-edit-vram-warning", "Sheets", "system-edit", "The System sheet on a device whose default is held below the line where iOS is likely to close Andarium (an iPhone 18 Pro Max mock) with memory between the two: the ticks past the default are orange and beyond the closing size red, the line beneath says games may run out of graphics memory and the VRAM estimate is orange. Home shows no notice at this size.", "-device", "iphone-18-pro-max", "-memoryMiB", "3584", dark=True),
    s("system-edit-camera-off", "Sheets", "system-edit", "The System sheet on an iPad mini 6 mock with Camera off: the VRAM estimate is the GPU's whole budget.", "-device", "ipad-mini-6"),
    s("system-edit-camera-on", "Sheets", "system-edit-camera", "The System sheet on an iPad mini 6 mock with Camera on and allowed: the VRAM estimate is the budget less what the layout of the cameras holds (the runtime's figure for them, 171 MiB in this mock; the ceiling, 197 MiB, where the runtime cannot say).", "-device", "ipad-mini-6"),
    s("system-edit-camera-off-phone", "Sheets", "system-edit", "The System sheet on an iPhone 18 Pro Max mock with Camera off: the VRAM estimate is the GPU's whole budget.", "-device", "iphone-18-pro-max"),
    s("system-edit-camera-on-phone", "Sheets", "system-edit-camera", "The System sheet on an iPhone 18 Pro Max mock with Camera on and allowed: the VRAM estimate is the budget less what the layout of the cameras holds (197 MiB, the ceiling, in this mock).", "-device", "iphone-18-pro-max"),
    s("system-edit-ipad-mini", "Sheets", "system-edit", "The System sheet on an iPad mini 6 mock at its default memory (1.5 GiB): the two sizes coincide, so no graphics warning shows and the VRAM estimate is plain.", "-device", "ipad-mini-6"),
    s("system-edit-memory-mac-64", "Sheets", "system-edit", "The System sheet on a Mac mock with 64 GiB and a guest of 24 GiB: the memory ruler has about a thousand positions, so its labels thin out to round numbers of gibibytes that do not touch, and no short ticks are drawn.", "-device", "mac-64-gib", "-memoryMiB", "24576"),
    s("resolution-sheet", "Sheets", "resolution-sheet", "The Resolution sheet, opened from Change: every choice with its pixels, and under them its density and, at the ends, Native and Fastest; the current choice is ticked (nobody has chosen, and the device states no memory limit: 320 dpi).", dark=True),
    s("resolution-sheet-low-memory", "Sheets", "resolution-sheet", "The sheet of someone who never chose, on a device held to 2,867 MiB of memory: 240 dpi is ticked.", "-memoryLimitMiB", "2867"),
    s("resolution-sheet-native-2", "Sheets", "resolution-sheet", "The sheet of someone who never chose, on a screen of native scale 2.0 with no memory limit: 1.0, 1.5 and native, with native (320 dpi) ticked.", "-displayNative", "2", "-displayPoints", "744x1133"),
    s("resolution-sheet-native-2-low-memory", "Sheets", "resolution-sheet", "The same screen held to 2,867 MiB: 240 dpi is ticked.", "-displayNative", "2", "-displayPoints", "744x1133", "-memoryLimitMiB", "2867"),
    s("resolution-sheet-middle", "Sheets", "resolution-sheet", "The Resolution sheet with a choice between the ends ticked.", "-displayScale", "2"),
    s("resolution-sheet-native-2-3", "Sheets", "resolution-sheet", "The sheet on a screen whose native scale is 2.3: 1.0, 1.5, 2.0 and 2.3, with 2.0 ticked.", "-displayNative", "2.3"),
    s("resolution-sheet-native-2-61", "Sheets", "resolution-sheet", "The sheet on a screen whose native scale is 2.61: 2.5 is left out for being near native, so 1.0, 1.5, 2.0 and 2.61, with 2.0 ticked.", "-displayNative", "2.61"),
    s("erase-alert", "Alerts", "erase", "Erase virtual machine: the standard destructive confirmation over Home. Confirming returns to the first-launch screen (home-welcome).", dark=True),
    s("info", "Info", "info", "Info: the app and version, System info (Build, Android version, Security patch, Kernel, Architecture, Supported architectures), Project on GitHub and Acknowledgements.", dark=True),
    icp("info-icp", "info-bottom", "Info scrolled to its end in mainland China's storefront: the filing number as one centred footnote line in the secondary colour, below every section, a link to MIIT's filing site.", "-icpStorefront", "CHN", dark=True),
    icp("info-icp-other-storefront", "info-bottom", "Info scrolled to its end in another storefront: no footnote.", "-icpStorefront", "USA"),
    icp("info-icp-unknown-storefront", "info-bottom", "Info scrolled to its end while the storefront is not known: no footnote.", "-icpStorefront", "none"),
    s("info-acknowledgements", "Info", "info-acknowledgements", "Acknowledgements: projects by group; the names and marks line is at the bottom.", dark=True),
    s("info-license", "Info", "info-license", "A project's page: copyright holders, the license name and the license text (Mesa, MIT).", dark=True),
    s("info-license-long", "Info", "info-license-gpl", "A page with a long license text (Linux: syscall exception and GPL v2)."),
    # Snapshots and What's New (more of each are in the Preview: see SnapshotPreview and WhatsNewPreview)
    s("snapshots", "Snapshots", "snapshots", "The Snapshots sheet over Home with mock snapshots: the list newest first, the space they use and Take snapshot at the foot.", dark=True),
    s("snapshots-detail", "Snapshots", "snapshots-detail", "One snapshot's page: its name, when it was taken, what deleting frees, Restore and Delete."),
    s("whatsnew-open", "What's New", "whatsnew-open", "The notes of the update, opened from the ribbon above Start."),
    # Boot
    *boot_stages("boot", "boot", ["System image", "Linux kernel", "Storage", "Startup"], "Normal boot over the dimmed guest display, no progress bar"),
    s("boot-single-vcpu", "Boot", "boot-single-vcpu", "Normal boot of a guest with a single vCPU: the Linux kernel line says \"1 vCPU\"."),
    s("boot-first-start", "Boot", "boot-first", "First start: Storage prepares the disk and Startup sets up for the first time; the panel last in the column, below the note, says Android has no Google apps, on purpose."),
    s("boot-update", "Boot", "boot-upgrade", "The first start after an update: Startup updates the apps."),
    s("boot-restart", "Boot", "boot-restart", "The guest restarting."),
    s("boot-slow", "Boot", "boot-slow", "A start that has run 3 minutes 17 seconds, still at Startup: the notice above the steps says it is taking longer than usual, that it can be waited out or stopped, and that stopping needs Andarium closed in the App Switcher and opened again to start again; a red Stop and, in a build with Send feedback, Send feedback, both of one width. The steps stay in view below it.", dark=True),
    s("boot-slow-clock-early", "Boot", "boot-slow-live", "The notice over a start that began 3 minutes 17 seconds ago, the clock running, 3 seconds after the launch: the status line and the notice show one time.", wait=3.0),
    s("boot-slow-clock-later", "Boot", "boot-slow-live", "The same launch 9 seconds after it: the status line and the notice have both moved on by the same seconds.", wait=9.0),
    s("boot-slow-first-start", "Boot", "boot-slow-first", "A first start 8 minutes 17 seconds in: the notice comes at eight minutes and its title does not say the start is slower than usual; the first-start note stays under the steps."),
    s("boot-slow-update", "Boot", "boot-slow-upgrade", "The first start after an update, 8 minutes 11 seconds in: the same later notice and plain title, with the update note under the steps."),
    s("boot-slow-recovery", "Boot", "boot-slow-recovery", "A Recovery start 3 minutes 17 seconds in: the notice over Recovery's opaque screen, with the ordinary title.", dark=True),
    s("boot-slow-stop-dialog", "Boot", "boot-slow-stop", "Stop chosen on the notice: the dialog asks Stop the virtual machine?, says that Andarium has to be closed in the App Switcher and opened again to start it, and offers Stop (red) and Cancel. The alert is dark, as the screen under it is, whatever the system's appearance is.", dark=True),
    s("boot-slow-recovery-stop-dialog", "Boot", "boot-slow-recovery-stop", "Stop chosen on a Recovery start's notice: the same dialog over Recovery's own screen, which follows the system's appearance, and so does the dialog.", dark=True),
    s("boot-slow-storage", "Boot", "boot-slow-storage", "The notice over an earlier step (Storage under way): the step and the time name where the start is.", "-bootStage", "2"),
    s("boot-slow-stopping", "Boot", "boot-slow-stopping", "Stop confirmed: the status line says Stopping\u2026, Stop's label says it too (with a spinner where the buttons are side by side) and is disabled until the run ends, and the buttons keep their size."),
    feedback("feedback-boot", "feedback-boot", "Send feedback opened from the slow-start notice: the sheet the root presents over the boot screen. The card says a bug report and a screenshot need the virtual machine to finish starting and that the start log is attached; the log is a row of its own with its size and a remove button, and the information block carries the start's step, time and restarts."),
    feedback("feedback-boot-filled", "feedback-boot-filled", "The same sheet with a typed problem, details and a photo: the start log stays the first row, counted in the total."),
    feedback("feedback-boot-details", "feedback-boot-details", "The same sheet with the information block expanded: the Boot line says the step and time of the start."),
    feedback("feedback-boot-removed", "feedback-boot-removed", "The same sheet after the start log was taken out: no row, no total, and the sheet does not attach it again."),
    feedback("feedback-boot-finished", "feedback-boot-finished", "The sheet opened over the boot screen with a typed draft, after the start finished: it is still open, with the draft and the start log, over the running session, where the card now offers the bug report."),
    s("boot-jit", "Boot", "boot-jit", "The debugger preparing the JIT: the System image step says Preparing JIT."),
    s("boot-jit-fallback", "Boot", "boot-jit-fallback", "A boot that ran without the JIT it was asked for: a note under the steps says why."),
    *boot_stages("boot-recovery", "boot-recovery", ["System image", "Linux kernel", "Storage", "Recovery"], "Recovery boot (opaque, own stage list, no progress bar)", dark_step=3),
    # Running guest
    s("session", "Guest", "session", "The running guest with the side keys closed."),
    s("session-tip", "Guest", "session-tip", "The side-keys tip over the running guest: the keys line and the line that says Settings holds Install APK.", "-resetTips", "YES"),
    s("session-tip-left", "Guest", "session-tip-left", "The side-keys tip beside the keys on the left edge: the popover opens to the right of them.", "-resetTips", "YES"),
    s("session-side-keys", "Guest", "session-open", "The side keys open: Power, volume, Back, Home and Settings."),
    s("session-left-edge", "Guest", "session-left", "The side keys on the left edge."),
    s("session-volume", "Guest", "session-volume", "The volume panel after a volume key press."),
    s("session-power-menu", "Guest", "session-power", "Android's power menu."),
    s("session-keyboard", "Guest", "session-keyboard", "The guest's own keyboard up over its search."),
    s("session-stats", "Guest", "session-stats", "The CPU, memory, VRAM and frame rate readout drawn over the guest: memory and VRAM in use over bars of their share.", dark=True),
    s("session-stats-fresh", "Guest", "session-stats", "The readout before the session's first reading: every figure a dash, the CPU bars all dimmed floor bars and the memory bars empty tracks.", "-statsReadings", "0"),
    s("session-stats-vram-high", "Guest", "session-stats", "The readout with VRAM at 93% of its budget: its bar is orange.", "-statsReadings", "10", "-statsVramMiB", "498"),
    s("session-stats-short", "Guest", "session-stats", "The readout after three CPU readings: the bars fill from the right, the older slots stay dimmed floor bars.", "-statsReadings", "3"),
    s("session-graphics-notice", "Guest", "session-graphics-notice", "The notice over the running guest that Android ran out of graphics memory."),
    s("session-thermal-notice", "Guest", "session-thermal-notice", "The notice over the running guest that the frame rate is lowered while the device is hot: its words end in a chevron and open the alert, and Dismiss only dismisses."),
    s("session-thermal-alert", "Guest", "session-thermal-alert", "The alert the thermal notice's words open: Turn off the frame rate limit?, what it costs and where to turn it back on, with Turn Off (red) and Cancel."),
    s("session-thermal-off", "Guest", "session-thermal-off", "The session after Turn Off: the frame rate limit is off and no notice shows, whatever the heat."),
    s("session-network-cellular", "Guest", "session-network-cellular", "The notice over the running guest that iOS denies Andarium cellular data, with the way to Settings.", dark=True),
    s("session-network-wifi", "Guest", "session-network-wifi", "The notice over the running guest that iOS denies Andarium Wi-Fi, with the way to Settings.", dark=True),
    s("session-camera-notice", "Guest", "session-camera-notice", "The notice over the running guest that the camera is paused while other apps share the screen (iPad Split View or Slide Over).", dark=True),
    s("session-camera-off-notice", "Guest", "session-camera-off-notice", "The notice over the running guest that Camera is off after an app in the guest opened a camera, with how to turn it on (shut down, then Capabilities).", dark=True),
    s("session-setup", "Guest", "session-setup", "The guest's own first-run setup screen."),
    s("session-off", "Guest", "session-off", "The guest's screen after it powered off."),
    s("space-pause", "Guest", "space-pause", "The running guest paused because the device is nearly out of space: the screen over it with Resume and Shut down.", dark=True),
    s("space-pause-short", "Guest", "space-pause-short", "The same screen after Resume found the space still short: it states what is free now."),
    s("space-pause-pausing", "Guest", "space-pause-pausing", "The same screen while the guest is being paused: it offers nothing until the guest holds still."),
    s("space-pause-running", "Guest", "space-pause-running", "The guest did not hold still: the screen says it still runs and offers Shut down and Check again."),
    s("space-pause-shutting-down", "Guest", "space-pause-shutting-down", "The same screen once Shut down was chosen: the buttons give way to Shutting down."),
    s("recovery", "Guest", "recovery", "Recovery running."),
    s("recovery-side-keys", "Guest", "recovery-open", "Recovery with the side keys open."),
    # Settings during a session
    s("settings", "Settings", "settings", "Settings at full height: Apps (Install APK) and File browser first, then Stats, Developer and Diagnostics.", dark=True),
    s("settings-medium", "Settings", "settings-medium", "Settings as the side keys open it, at the medium detent: Apps (Install APK) and File browser at the top of the first screenful.", dark=True),
    s("settings-stats", "Settings", "settings-stats", "Settings scrolled to Stats: CPU, Memory and VRAM with bars of their share, and Frame rate.", dark=True),
    s("settings-stats-short", "Settings", "settings-stats", "Settings scrolled to Stats after three CPU readings: the bars fill from the right.", "-statsReadings", "3"),
    s("settings-performance", "Settings", "settings-performance", "Settings' Performance section after Stats, with the limit on: When hot reads Limit frame rate, and the footnote says what the limit does.", dark=True),
    s("settings-performance-menu", "Settings", "settings-performance-menu", "The When hot menu open: Limit frame rate (checked, Lets this device cool down) and Full frame rate (Hotter, and the battery drains faster)."),
    s("settings-performance-off", "Settings", "settings-performance-off", "Performance with the limit off: When hot reads Full frame rate, and the footnote warns what it costs."),
    s("settings-performance-hot", "Settings", "settings-performance-hot", "Performance while the device is held hot and the limit is on: an orange tile, a thermometer line that the frame rate is limited until it cools, and Frame rate at 30 fps."),
    s("settings-performance-hot-off", "Settings", "settings-performance-hot-off", "Performance while the device is held hot and the limit is off: the thermometer line says the frame rate is not limited, with the warning under it."),
    system_mic("home-mic-system-prompt", "Capabilities", "home-mic-alert", "The system's own question when Microphone is turned on for the first time (the Simulator's alert).", "reset"),
    system_mic("home-mic-system-allowed", "Capabilities", "home-mic-on", "Microphone on after iOS allowed it.", "grant"),
    system_mic("home-mic-system-refused", "Capabilities", "home-capabilities", "Microphone after iOS refused it: the row is dimmed and says it is not allowed in Settings.", "revoke"),
    system_mic("home-mic-system-settings-prompt", "Capabilities", "home-mic-alert", "Turning Microphone on after a refusal: Andarium explains and offers Settings.", "revoke"),
    system_mic("home-mic-system-revoked", "Capabilities", "home-mic-on", "Microphone on, access taken away in Settings while Andarium was in the background, Andarium active again: the switch is off and dimmed.", "grant", "background", "revoke", "foreground"),
    system_location("home-location-system-prompt", "Capabilities", "home-location-ask", "The system's own question when Location is turned on for the first time (the Simulator's alert).", "reset"),
    system_location("home-location-system-allowed", "Capabilities", "home-location-on", "Location on after iOS allowed it.", "grant"),
    system_location("home-location-system-refused", "Capabilities", "home-capabilities", "Location after iOS refused it: the row is dimmed and says it is not allowed in Settings.", "revoke"),
    system_location("home-location-system-settings-prompt", "Capabilities", "home-location-alert", "Turning Location on after a refusal: Andarium explains and offers Settings.", "revoke"),
    system_location("home-location-system-revoked", "Capabilities", "home-location-on", "Location on, access taken away in Settings while Andarium was in the background, Andarium active again: the switch is off and dimmed.", "grant", "background", "revoke", "foreground"),
    system_camera("home-camera-system-prompt", "Capabilities", "home-camera-ask", "The system's own question when Camera is turned on for the first time (the Simulator's alert), if the Simulator raises one without a camera."),
    s("settings-adb", "Settings", "settings-adb", "Developer: ADB over network on, the address a computer connects to."),
    s("settings-adb-no-address", "Settings", "settings-adb-no-address", "Developer: ADB over network on with no network address."),
    s("settings-adb-off", "Settings", "settings-adb-off", "Developer: ADB over network unavailable because USB debugging is off."),
    s("settings-old-apps", "Settings", "settings-old-apps", "Settings as the side keys open it: Apps has Install APK and the Old app compatibility row, saying On because one app has it.", dark=True),
    s("old-apps-page", "Old apps", "settings-old-apps-page", "Old app compatibility: Built for Android before 4.0, two made-up apps with their package names and a switch each (one on), and the footer.", dark=True, wait=4.0),
    s("old-apps-turn-on", "Old apps", "settings-old-apps-turn-on", "The alert that asks before the switch is turned on for an app that is not open.", wait=4.0),
    s("old-apps-turn-on-open", "Old apps", "settings-old-apps-turn-on-open", "The same alert for an app that is open: it adds that the app closes now.", wait=4.0),
    s("old-apps-turn-off", "Old apps", "settings-old-apps-turn-off", "The alert that asks before the switch is turned off for an app that is open.", wait=4.0),
    s("old-apps-refused", "Old apps", "settings-old-apps-refused", "The alert when the virtual machine did not take the change.", wait=4.0),
    s("old-apps-empty", "Old apps", "settings-old-apps-empty", "The page when no app built for Android before 4.0 is installed.", wait=4.0),
    s("old-apps-failed", "Old apps", "settings-old-apps-failed", "The page when the virtual machine did not answer the listing: the message and Try again.", wait=4.0),
    s("old-apps-loading", "Old apps", "settings-old-apps-loading", "The page while the virtual machine is asked which apps it can apply to.", wait=3.0),
    # Operations on the guest
    s("overlay-bug-report", "Operations", "bug-report", "The full-screen progress while a bug report is made.", wait=2.0),
    s("overlay-install-apk", "Operations", "install-apk", "The full-screen progress while an app installs from Files.", wait=2.0),
    s("alert-install-legacy", "Operations", "install-legacy", "The question over the install overlay when Android refused an app built for a much older version: Cancel and Install anyway.", wait=2.0),
    s("overlay-install-legacy-hint", "Operations", "install-legacy-hint", "The install overlay at its end after Install anyway of an app built for an Android before 4.0 that Old app compatibility lists: the card says where its switch is.", dark=True),
    s("overlay-install-legacy-hint-data", "Operations", "install-legacy-hint-data", "The same hint on the warning card of an app whose data files were not all copied."),
    s("overlay-install-done", "Operations", "install-done", "The install overlay at its end: App installed with Done. It stays until closed."),
    s("overlay-install-failed", "Operations", "install-failed", "The install overlay at its end: App not installed, the guest's reason and OK."),
    s("overlay-install-not-apk", "Operations", "install-not-apk", "A file that is not an app, refused at once on the overlay."),
    s("overlay-install-parts", "Operations", "install-parts", "The full-screen progress while an app that comes in parts (.apks, .xapk, .apkm) is sent, part by part.", wait=2.0),
    s("overlay-install-app-bundle", "Operations", "install-app-bundle", "A file named .apks, .xapk or .apkm that holds an app bundle for publishing apps, refused once it is read."),
    s("overlay-install-data", "Operations", "install-data", "The install overlay while an app's data files are copied, after the app is in: Cancel is back and the line counts the file.", wait=2.0),
    s("overlay-install-done-without-data", "Operations", "install-done-without-data", "The install overlay at its end when the copy of the data files was stopped or failed: a warning (the caution symbol in orange, the title App installed, some data missing), not the plain success; the app is in, and installing the file again copies them.", dark=True),
    s("overlay-install-done-data-not-placed", "Operations", "install-done-data-not-placed", "The install overlay at its end when some of the file's data is of a kind that is not copied, or a pack that is delivered later is left out: the same warning card, without the line about installing again."),
    s("overlay-install-done-container", "Operations", "install-done-container", "The install overlay at its end for an app in parts that installed whole: the plain success (the check, the title App installed), to set beside the warning."),
    s("overlay-install-encrypted", "Operations", "install-encrypted", "A file whose entries are encrypted, refused once it is read."),
    s("overlay-install-damaged-or-encrypted", "Operations", "install-damaged-or-encrypted", "An .apkm that is not a ZIP, which may be damaged or the encrypted kind, refused once it is read."),
    s("overlay-install-no-app", "Operations", "install-no-app", "An archive that holds no app, refused once it is read."),
    s("overlay-install-damaged", "Operations", "install-damaged", "A file that is damaged, cut short, or whose parts do not fit together, refused once it is read."),
    s("overlay-install-missing-split", "Operations", "install-missing-split", "The package manager's refusal of an app that lacks parts it requires."),
    s("overlay-install-part-too-large", "Operations", "install-part-too-large", "An app with a part of 4 GiB or more, which Android cannot install, refused once the file is read."),
    # Send feedback: needs a Preview built with FEEDBACK_ADDRESS=feedback@example.com (see --help)
    feedback("feedback-menu-home", "home-menu", "Home's toolbar menu open on a configured guest: Info, then Send feedback after a separator.", dark=True, wait=3.0),
    feedback("feedback-menu-welcome", "welcome-menu", "The same menu open on the welcome screen, before any guest exists: Send feedback is reachable from the first screen.", dark=True, wait=3.0),
    feedback("feedback-entrance-settings", "settings-feedback", "Settings scrolled to Diagnostics: Send feedback is the first row, above Create bug report.", dark=True, wait=3.0),
    feedback("feedback-empty", "feedback", "Send feedback opened from a running session's Settings, empty: the subject and body lines, the information block folded, the card that asks for a bug report and the bar (Bug report, Screenshot, Add, Send feedback). Send is enabled: a tap with the problem or the details empty says which."),
    feedback("feedback-filled", "feedback-filled", "Send feedback from a session with a problem and details, and three attachments (bug report, screenshot, photo) with their sizes and remove buttons and the total under them; the bar shows the bug report as attached.", dark=True),
    feedback("feedback-ask", "feedback-ask", "Send tapped with the problem and the details written, no bug report attached and the virtual machine running: the alert asks before the mail opens, with two buttons, Create bug report (the preferred one) and Send without bug report, and says that without a bug report a problem will most likely not get fixed."),
    feedback("feedback-report", "feedback-report", "Send feedback after Create bug report from that alert: the report is attached, its row leads in (a chevron, a hairline, then its remove button) and says its size and how many files it holds, and the sheet is still open with the draft as it was; no mail composer."),
    feedback("feedback-viewer", "feedback-viewer", "The bug report's row opened inside the sheet's own navigation (Back, no Done): the file as it goes with the mail (its name, size, file count, unpacked size and the sentence that it goes as it is), then its top level as folders and files; a folder that holds one folder is one row, a text, a picture and an archive open, and a file that is not text is dimmed, says so and opens nothing.", dark=True),
    feedback("feedback-viewer-folder", "feedback-viewer-folder", "A folder of the bug report opened: its files, each with its size and what it is, as Files shows a folder."),
    feedback("feedback-viewer-text", "feedback-viewer-text", "A long text of the bug report opened: one page of plain lines that scrolls on, with its name and size in the bar and the thumb on the trailing edge held, saying where it points (a percentage and the bytes of the whole)."),
    feedback("feedback-viewer-picture", "feedback-viewer-picture", "The screenshot of the bug report opened as a picture, scaled to fit with its pixels and size under it; nothing to zoom, share or save."),
    feedback("feedback-viewer-nested", "feedback-viewer-nested", "An archive stored inside the bug report, opened like a folder: its name, size and file count, then its files."),
    feedback("feedback-viewer-damaged", "feedback-viewer-damaged", "A bug report that is damaged (cut short): the first page says it can't be read, and the row on the sheet says nothing of files."),
    feedback("feedback-details", "feedback-details", "Send feedback filled, with the app and device details opened in full at the end of the mail."),
    feedback("feedback-large", "feedback-large", "Send feedback with attachments over 20 MiB: the total turns orange and says some mail services refuse mail over 20 MiB; Send still works."),
    feedback("feedback-file", "feedback-file", "Send feedback with one file from Files attached, a ZIP: a document tile, its name and size, a remove button and the total under it. The bar has three buttons, Bug report, Screenshot and Add (a paperclip whose menu offers Photos and Files).", dark=True),
    feedback("feedback-file-bar-xxxlarge", "feedback-file", "The same sheet at the largest standard text size: no label is cut in the bar.", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"),
    feedback("feedback-file-long", "feedback-file-long", "A file with a long name (the end of the base cut in the middle, the extension kept) at the default text size."),
    feedback("feedback-file-names", "feedback-file-names", "Two files named in Chinese and in Japanese: the rows keep the names as written, and so does the mail."),
    feedback("feedback-file-mixed", "feedback-file-mixed", "Send feedback with a bug report, a screenshot, a photo and a file together, in the order they were added, one total under them."),
    feedback("feedback-file-large", "feedback-file-large", "A file of about 1.9 GiB attached: its size is its own and the total turns orange with the warning that some mail services refuse mail over 20 MiB; Send still works. The file is mapped, never read, for the size.", dark=True),
    feedback("feedback-file-copying", "feedback-file-copying", "The card over the sheet while a file that cannot be used where it is kept (not downloaded from its cloud storage) is copied first: a progress bar and Cancel. Send and the bar are dimmed and the file's row is not there yet; the screenshot attached before stays.", dark=True),
    feedback("feedback-file-refused", "feedback-file-refused", "The alert after a folder and an empty file were chosen: two items weren't added, one line for each reason.", dark=True),
    feedback("feedback-file-refused-one", "feedback-file-refused-one", "The alert for one file that was not added: the title for one item and its reason."),
    feedback("feedback-file-refused-four", "feedback-file-refused-four", "The alert for four items that were not added for four different reasons: not enough space, a folder or a package, an empty file and a file that could not be read, a line each.", dark=True),
    feedback("feedback-file-apk", "feedback-file-apk", "One pick of an ordinary file and an APK: the file is attached, and the alert says that mail services reject a message that carries an APK, so the APK was not attached, and asks for a download link in the details."),
    feedback("feedback-file-apk-several", "feedback-file-apk-several", "One pick of a file and three Android packages (.apk, .apks, .xapk): the file is attached, and one alert says the packages were not attached, in the plural."),
    feedback("feedback-file-gone", "feedback-file-gone", "Send, after the only file attached was deleted from where it was kept: Attachment not available, the file taken out of the list.", dark=True),
    feedback("feedback-file-picker", "feedback-file-picker", "The system's document picker over the sheet, as a tap on Files in the Add menu opens it.", wait=20.0),
    feedback("feedback-file-menu", "feedback-file-menu", "The bar's Add menu open: Photos and Files, anchored on the button."),
    feedback("feedback-generating", "feedback-generating", "Send feedback while the bug report is made: the app's progress overlay with Cancel over the whole sheet, Settings still open beneath."),
    feedback("feedback-sent", "feedback-sent", "Send feedback once the mail was sent: the Feedback sent card with Done over the sheet, which still shows the problem, the details, the attachments and the information block that were sent."),
    feedback("feedback-missing-both", "feedback-missing-both", "Send tapped with the problem and the details both empty: Can't send yet, and what to write in each.", dark=True),
    feedback("feedback-missing-problem", "feedback-missing-problem", "Send tapped with the details written and the problem empty: the alert asks for the Problem line."),
    feedback("feedback-missing-details", "feedback-missing-details", "Send tapped with the problem written and the details empty: the alert asks for what was done and what happened."),
    feedback("feedback-discard", "feedback-discard", "Cancel after something is typed or attached: Discard or Keep editing."),
    feedback("feedback-nomail", "feedback-nomail", "Send feedback where Mail cannot send (no account): the error and the way to fix it, and every control disabled."),
    feedback("feedback-home", "feedback-home", "Send feedback opened from Home's toolbar menu, where no virtual machine runs: the no-Google-apps line is at the top, collapsed; the card says that without a bug report a problem will most likely not get fixed and gives three steps to one (start the virtual machine, make the problem happen again, open Send feedback from there with a bug report attached); the rest of the form works.", dark=True),
    feedback("feedback-home-answer", "feedback-home-answer", "Send feedback from Home with the no-Google-apps line opened in place: the question, That's on purpose, and the reason."),
    feedback("feedback-home-filled", "feedback-home-filled", "Feedback that is not a bug, from Home: a suggestion with a photo; Send is ready."),
    # Buy me tokens: needs a Preview built with the four TIP_ settings (see --help)
    tipjar("tipjar-entrance-home", "tipjar-home", "Home's toolbar after a virtual machine is set up: the one menu button where Info was, which holds Info, Send feedback, Review on the App Store and Buy me tokens (the menu itself is not captured).", dark=True, wait=3.0),
    tipjar("tipjar", "tipjar", "Buy me tokens over Home: the chat with Andarium's developer (the header shows the developer's avatar, name and two profile logos where the Preview is given them), the plain statement and the four tiers with the store's prices.", dark=True),
    tipjar("tipjar-tall", "tipjar", "Buy me tokens at the full height of a page, taller than its conversation: the conversation stands at the top, under the title, and the tiers stay at the foot.", "-tipHeight", "full"),
    tipjar("tipjar-loading", "tipjar-loading", "The store has not answered yet: the four tiers with a spinner for each price."),
    tipjar("tipjar-missing", "tipjar-missing", "The store knows three of the four: the others are offered, Max is left out."),
    tipjar("tipjar-unavailable", "tipjar-unavailable", "The store gave nothing: a note that tips are not available and Try again."),
    tipjar("tipjar-restricted", "tipjar-restricted", "Purchases are not allowed on this device: the tiers dimmed with their prices and one line, no way to lift the restriction."),
    tipjar("tipjar-purchasing", "tipjar-purchasing", "A purchase of Pro is under way: the person's reply with a spinner while the store's own sheet is up."),
    tipjar("tipjar-thanks", "tipjar-thanks", "After a tip: the developer's thanks inside the sheet, and Done as the one control; the tiers are not offered again.", dark=True),
    tipjar("tipjar-pending", "tipjar-pending", "A tip that waits for a family organiser's approval (Ask to Buy): the note says it can be closed meanwhile."),
    tipjar("tipjar-failed", "tipjar-failed", "A purchase that failed: the store's own message under a note, the tiers still offered."),
    tipjar("tipjar-prices", "tipjar", "The tiers with four prices of very different widths, as different storefronts format them.", "-tipPrices", "mixed"),
    # End: a clean power-off returns to Home; only a failed run keeps an end screen
    s("end-failed", "End", "failed", "The screen after the guest stopped unexpectedly."),
    s("end-stopped", "End", "stopped", "The screen after Stop on the slow-start notice: it says the person stopped the virtual machine and that Andarium must be closed in the App Switcher and opened again to start it; no fault mark, the report block starts Virtual machine ended.", dark=True),
]


def run(command: list[str], *, timeout: float = COMMAND_SECONDS) -> subprocess.CompletedProcess[str]:
    """Run a command with a hard time bound; a command that outlives it fails."""
    try:
        return subprocess.run(
            command, check=False, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout
        )
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(command, 124, "", f"timed out after {timeout:.0f} s")


def simctl(*arguments: str, timeout: float = COMMAND_SECONDS) -> subprocess.CompletedProcess[str]:
    return run(["xcrun", "simctl", *arguments], timeout=timeout)


def device_names() -> dict[str, str]:
    result = simctl("list", "devices", "--json")
    if result.returncode != 0:
        sys.exit(f"capture-screens.py: simctl list failed: {result.stderr.strip()}")
    names: dict[str, str] = {}
    for devices in json.loads(result.stdout)["devices"].values():
        for device in devices:
            names[device["udid"]] = device["name"]
    return names


def png_size(path: Path) -> tuple[int, int]:
    header = path.read_bytes()[:24]
    return struct.unpack(">II", header[16:24])


def slug(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")


def differing_pixels(first: Path, second: Path) -> float:
    """The fraction of pixels that differ between two screenshots (1.0 if unknown)."""
    try:
        result = run(["magick", "compare", "-metric", "AE", "-fuzz", "5%", str(first), str(second), "null:"], timeout=30)
        width, height = png_size(first)
        return float(result.stderr.split()[0]) / (width * height)
    except (OSError, ValueError, IndexError, subprocess.TimeoutExpired):
        return 1.0


def empty_frame(path: Path) -> str | None:
    """"white" for a plain white frame (an app that has not drawn yet), "black" for a plain black one (a display
    that is off or an app that went away), None for anything with content."""
    try:
        result = run(["magick", str(path), "-format", "%[fx:mean] %[fx:standard_deviation]", "info:"], timeout=30)
        mean, deviation = (float(value) for value in result.stdout.split())
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None
    if deviation >= 0.02:
        return None
    if mean > 0.97:
        return "white"
    return "black" if mean < 0.03 else None


def app_state(udid: str) -> dict | None:
    """What the Preview last wrote to its capture-state.json: its process, screen and whether it is active."""
    container = simctl("get_app_container", udid, BUNDLE, "data")
    if container.returncode != 0:
        return None
    try:
        return json.loads((Path(container.stdout.strip()) / "Library" / "Caches" / STATE_FILE).read_text())
    except (OSError, ValueError):
        return None


def alive(pid: int) -> bool:
    """A Simulator app is a process of the host's own."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def not_in_front(udid: str, pid: int, shot: Shot, *, after: bool = False) -> str | None:
    """Why the app is not showing `shot`: None when it is the launched process, on the shot's screen and active;
    otherwise the reason. An app launched while a system alert is up stays inactive, so a stale alert shows here.
    The alert a shot raises itself leaves the app active; if it does not, `after` the screenshot it is no reason."""
    if not alive(pid):
        return f"the app (process {pid}) is not running"
    state = app_state(udid)
    if state is None:
        return "the app has not reported its state"
    if state.get("pid") != pid:
        return f"the app that reported is process {state.get('pid')}, not the launched {pid}"
    if state.get("screen") != shot.screen:
        return f"the app reported screen {state.get('screen')!r}, not {shot.screen!r}"
    if shot.feedback and state.get("feedback") is not True:
        return "this Preview has no Send feedback: build it with FEEDBACK_ADDRESS=feedback@example.com on the command line"
    if shot.feedback and shot.screen.startswith("feedback") and state.get("feedbackReady") is not True:
        return "the sheet of Send feedback is not open with its draft made"
    if shot.tipjar and state.get("tipjar") is not True:
        return "this Preview has no Buy me tokens: build it with the four TIP_ settings of the arrangement on the command line"
    if shot.icp and state.get("icp") is not True:
        return "this Preview has no filing number: build it with ICP_NUMBER of the arrangement on the command line"
    if state.get("state") != "active" and not (after and shot.alert):
        return f"the app is {state.get('state')}, not active: a system alert, another app or the Home screen is in front"
    return None


def wait_in_front(udid: str, pid: int, shot: Shot, seconds: float = FRONT_SECONDS) -> str | None:
    """`not_in_front`, given a few seconds after a launch for the app to report."""
    deadline = time.monotonic() + seconds
    while True:
        reason = not_in_front(udid, pid, shot)
        if reason is None or time.monotonic() >= deadline:
            return reason
        time.sleep(0.5)


def settled_screenshot(udid: str, shot_id: str, out: Path) -> tuple[Path | None, bool]:
    """Screenshot once the screen has stopped changing (a launch animation or a
    scroll is over): two looks a second apart that differ in under 0.3% of
    their pixels. After SETTLE_SECONDS the last look is taken as it is."""
    temporary = out / f".{shot_id}.png"
    previous = out / f".{shot_id}.previous.png"
    deadline = time.monotonic() + SETTLE_SECONDS
    settled = False
    while True:
        taken = simctl("io", udid, "screenshot", str(temporary))
        if taken.returncode != 0 or not temporary.is_file():
            print(f"  {shot_id}: screenshot failed: {taken.stderr.strip()}", file=sys.stderr)
            return None, False
        if previous.is_file() and differing_pixels(previous, temporary) < SETTLED_FRACTION and empty_frame(temporary) is None:
            settled = True
            break
        if time.monotonic() >= deadline:
            break
        temporary.replace(previous)
        time.sleep(1.0)
    previous.unlink(missing_ok=True)
    return temporary, settled


def play_flow(udid: str, shot: Shot, pid: int, language: str | None = None) -> int | None:
    """The steps that follow the launch of a shot whose state needs the app in the background; the process that
    ends them, or None. The Simulator ends an app whose permission changes, as iOS does, so the last step is a
    relaunch there; an app still running just comes forward, which is the activation."""
    for step in shot.flow:
        if step == "background":
            result = simctl("launch", udid, "com.apple.Preferences")
        elif step in ("grant", "revoke"):
            result = simctl("privacy", udid, step, shot.service, BUNDLE)
        elif step == "foreground":
            result = simctl("launch", udid, BUNDLE, *shot.launch_arguments(language))
            if result.returncode == 0:
                again = launched_pid(result)
                print(f"  {shot.id}: {'the app was still running' if again == pid else 'the permission change ended the app'}")
                pid = again if again is not None else pid
        else:
            sys.exit(f"capture-screens.py: unknown flow step {step!r}")
        if result.returncode != 0:
            print(f"  {shot.id}: {step} failed: {result.stderr.strip()}", file=sys.stderr)
            return None
        time.sleep(2.0)
    return pid


def launched_pid(launched: subprocess.CompletedProcess[str]) -> int | None:
    """The process `simctl launch` started: its output is "<bundle>: <pid>"."""
    try:
        return int(launched.stdout.strip().rsplit(" ", 1)[-1])
    except ValueError:
        return None


def clear_system_alert(udid: str) -> None:
    """The Simulator keeps its permission alert up, over whatever launches next, until someone answers it.
    Restarting SpringBoard takes the alert and the app with it, and turns an iPad upright."""
    simctl("spawn", udid, "launchctl", "kill", "SIGKILL", "user/foreground/com.apple.SpringBoard")
    time.sleep(15.0)


def capture(
    udid: str, name: str, shot: Shot, appearance: str, out: Path, wait: float, orientation: str | None,
    language: str | None = None,
) -> dict | None:
    """One shot, or None (with the reason on stderr) when the picture cannot be Andarium's: the app is not the
    launched process on the shot's screen in front, the frame is empty, or the device turned since the run began
    (`orientation`)."""
    simctl("terminate", udid, BUNDLE)
    if shot.privacy is not None:
        privacy = simctl("privacy", udid, shot.privacy, shot.service, BUNDLE)
        if privacy.returncode != 0:
            print(f"  {shot.id}: privacy {shot.privacy} failed: {privacy.stderr.strip()}", file=sys.stderr)
            return None
    launched = simctl("launch", udid, BUNDLE, *shot.launch_arguments(language))
    pid = launched_pid(launched)
    if launched.returncode != 0 or pid is None:
        print(f"  {shot.id}: launch failed: {launched.stderr.strip()}", file=sys.stderr)
        return None
    time.sleep(max(wait, shot.wait))
    if shot.flow:
        pid = play_flow(udid, shot, pid, language)
        if pid is None:
            return None
    reason = wait_in_front(udid, pid, shot)
    if reason is not None:
        print(f"  {shot.id}: not recorded: {reason}", file=sys.stderr)
        return None
    temporary, settled = settled_screenshot(udid, shot.id, out)
    if temporary is None:
        return None
    reason = not_in_front(udid, pid, shot, after=True) or (f"the frame is {empty_frame(temporary)}" if empty_frame(temporary) else None)
    if reason is None:
        width, height = png_size(temporary)
        now = "landscape" if width > height else "portrait"
        if orientation is not None and now != orientation:
            reason = f"the device is {now}, not {orientation} as at the start of the run"
    if reason is not None:
        temporary.unlink(missing_ok=True)
        print(f"  {shot.id}: not recorded: {reason}", file=sys.stderr)
        return None
    if not settled:
        print(f"  {shot.id}: the screen kept changing; kept the last look", file=sys.stderr)
    idiom = "iPad" if "iPad" in name else "iPhone"
    file = f"{idiom.lower()}-{now}-{appearance}-{shot.id}{'' if language is None else f'-{language}'}.png"
    temporary.replace(out / file)
    return {
        "file": file,
        "device": name,
        "idiom": idiom,
        "orientation": now,
        "appearance": appearance,
        "group": shot.group,
        "id": shot.id,
        "screen": shot.screen,
        "launch_arguments": " ".join(shot.launch_arguments(language)),
        "language": language,
        "pixels": [width, height],
        "settled": settled,
        "description": shot.description,
    }


def preflight(udid: str, name: str, out: Path, language: str | None = None) -> str | None:
    """Before the first shot: the Preview must come to the front on a plain screen. A permission alert left up by
    an earlier use of the Simulator is cleared (which turns an iPad upright, as is said). The result is the
    orientation the run keeps, or None when the Preview cannot be brought to the front."""
    probe = Shot("preflight", "", "home", "")
    for attempt in range(2):
        simctl("terminate", udid, BUNDLE)
        launched = simctl("launch", udid, BUNDLE, *probe.launch_arguments(language))
        pid = launched_pid(launched)
        if pid is not None and wait_in_front(udid, pid, probe) is None:
            temporary = out / ".preflight.png"
            if simctl("io", udid, "screenshot", str(temporary)).returncode == 0 and temporary.is_file():
                width, height = png_size(temporary)
                temporary.unlink()
                return "landscape" if width > height else "portrait"
        if attempt == 0:
            print(f"{name}: the Preview did not come to the front; restarting SpringBoard to clear an alert", file=sys.stderr)
            clear_system_alert(udid)
    return None


class OutputBusy(Exception):
    """Another run holds the output directory."""


@contextlib.contextmanager
def output_lock(out: Path):
    """Hold the output directory for this run, or raise OutputBusy at once.

    The lock is an exclusive flock on LOCK_FILE in the directory: the kernel drops it when the process ends
    however it ends, so a killed run never leaves the directory locked. The file records the holder's pid for the
    message of a refused run and stays in the directory.
    """
    descriptor = os.open(out / LOCK_FILE, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            holder = os.pread(descriptor, 32, 0).decode(errors="replace").strip()
            raise OutputBusy(holder or "unknown") from None
        os.ftruncate(descriptor, 0)
        os.pwrite(descriptor, f"{os.getpid()}\n".encode(), 0)
        yield
    finally:
        os.close(descriptor)


def write_manifest(path: Path, entries: dict[str, dict]) -> None:
    manifest = {"schema": 1, "shots": sorted(entries.values(), key=lambda entry: entry["file"])}
    path.write_text(json.dumps(manifest, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, help="directory for the PNG files and manifest.json")
    parser.add_argument("--device", action="append", default=[], metavar="UDID", help="a booted Simulator (repeatable)")
    parser.add_argument("--only", metavar="REGEX", help="capture only shots whose id matches")
    parser.add_argument("--appearance", choices=("light", "dark"), help="capture only this appearance")
    parser.add_argument("--wait", type=float, default=0.0, help="minimum seconds after each launch")
    parser.add_argument("--language", choices=sorted(LANGUAGES), help="show the Preview in this language (default: the Simulator's)")
    parser.add_argument("--list", action="store_true", help="list the shots and exit")
    args = parser.parse_args(argv)
    if args.list:
        for shot in SHOTS:
            print(f"{shot.id}\t{shot.group}\t{' '.join(shot.launch_arguments())}\t{'light,dark' if shot.dark else 'light'}")
        return 0
    if args.out is None or not args.device:
        parser.error("--out and at least one --device are required")
    ids = [shot.id for shot in SHOTS]
    if len(ids) != len(set(ids)):
        sys.exit("capture-screens.py: duplicate shot ids")
    args.out.mkdir(parents=True, exist_ok=True)
    try:
        with output_lock(args.out):
            return capture_all(args)
    except OutputBusy as busy:
        print(
            f"capture-screens.py: another capture is running into {args.out} (pid {busy}); a directory takes one run "
            "at a time, so wait for it, name several --device options in one run, or use another --out",
            file=sys.stderr,
        )
        return 1


def capture_all(args: argparse.Namespace) -> int:
    manifest_path = args.out / "manifest.json"
    entries: dict[str, dict] = {}
    if manifest_path.is_file():
        entries = {entry["file"]: entry for entry in json.loads(manifest_path.read_text())["shots"]}
    names = device_names()
    selected = [shot for shot in SHOTS if not args.only or re.search(args.only, shot.id)]
    status = 0
    for udid in args.device:
        name = names.get(udid)
        if name is None:
            sys.exit(f"capture-screens.py: no Simulator {udid}")
        simctl(
            "status_bar", udid, "override", "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100",
            "--cellularMode", "active", "--cellularBars", "4", "--wifiBars", "3", "--dataNetwork", "wifi",
        )
        orientation = preflight(udid, name, args.out, args.language)
        if orientation is None:
            print(f"capture-screens.py: {name} ({udid}): the Preview does not come to the front; nothing captured", file=sys.stderr)
            status = 1
            continue
        # The Preview reports (from the launch that preflight made) whether it was built with Send feedback and
        # with Buy me tokens.
        reported = app_state(udid) or {}
        has_feedback = reported.get("feedback") is True
        has_tipjar = reported.get("tipjar") is True
        has_icp = reported.get("icp") is True
        wanted = [shot for shot in selected
                  if (has_feedback or not shot.feedback) and (has_tipjar or not shot.tipjar) and (has_icp or not shot.icp)]
        for label, present, flagged in (("Send feedback", has_feedback, lambda shot: shot.feedback),
                                        ("Buy me tokens", has_tipjar, lambda shot: shot.tipjar),
                                        ("the filing number", has_icp, lambda shot: shot.icp)):
            skipped = sum(1 for shot in selected if flagged(shot) and not present)
            if skipped:
                print(
                    f"{name}: skipping {skipped} shots of {label}: this Preview was built without it (see --help)",
                    file=sys.stderr,
                )
        # The shot of the system's own alert runs last: the alert outlives its shot and covers whatever launches next.
        plain = [shot for shot in wanted if not shot.alert]
        passes = [("light", plain), ("dark", [shot for shot in plain if shot.dark]),
                  ("light", [shot for shot in wanted if shot.alert])]
        passes = [(appearance, shots) for appearance, shots in passes if args.appearance in (None, appearance)]
        asked = False
        for appearance, shots in passes:
            simctl("ui", udid, "appearance", appearance)
            for shot in shots:
                if shot.alert and asked:
                    # The alert an earlier shot raised is still up over whatever launches. Clearing it turns an iPad
                    # upright, so the orientation of the start no longer holds.
                    clear_system_alert(udid)
                    orientation = None
                entry = capture(udid, name, shot, appearance, args.out, args.wait, orientation, args.language)
                if entry is None:
                    entry = capture(udid, name, shot, appearance, args.out, args.wait, orientation, args.language)
                asked = asked or shot.alert
                if entry is None:
                    status = 1
                    continue
                entries[entry["file"]] = entry
                write_manifest(manifest_path, entries)
                print(f"{name} {entry['orientation']} {appearance}: {shot.id}", flush=True)
        simctl("ui", udid, "appearance", "light")
        if asked:
            clear_system_alert(udid)
    write_manifest(manifest_path, entries)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
