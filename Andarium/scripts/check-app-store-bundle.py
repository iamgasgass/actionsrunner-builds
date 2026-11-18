#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Check a built Andarium application against the AppStore or TestFlight configuration.

The App Store configuration (Andarium/README.md#configurations) builds an
application that must:

  - declare no non-exempt encryption, require arm64 and Metal, target iPhone
    and iPad, and have no background mode;
  - carry no automation knob: no ANDARIUM_, KERNARIUM_, UML_ or DARWIN_UML_
    environment name (ANDARIUM_THERMAL_STATE, which states the thermal state
    in place of iOS's, among them) in the host code of the application or of
    any embedded framework (the guest kernel image inside a runtime is not
    host code);
  - carry none of the harness's console lines (ConsoleReport in the
    application: the statistics, thermal state, runtime and focus lines),
    which the configuration compiles out;
  - carry no debugging or automation support in the host code of the
    application or of a framework: the frame mirror, console input, the
    guest sampler, the footprint log, the virtual Jetsam, the activity logs,
    the census and histogram, the automation entries, the synthetic camera, the
    simulated controllers, the UI tests' input probe and the harness's
    leftovers (DEBUG_SYMBOLS and DEBUG_STRINGS name them; the stand-ins that
    keep the runtime API's layout, runtimeSetFrameSink, runtimeSendConsoleInput
    and runtimePrepareJit, are allowed), and contain no test bundle and no
    XCTest or Testing framework;
  - carry no JIT: no arm64 JIT engine, no executable-memory owner, none of the
    runtime's or the application's JIT entries or text, and no instruction
    word of the debugger request (`brk #0xf00d`, JIT_DEBUGGER_REQUEST) in the
    code of the application or of a framework (the JIT is for the other
    configurations, which a debugger prepares; an App Store build has no
    executable memory of its own);
  - carry no JIT text in a language: no JIT strings table in any lproj, and no
    localized key or value that names JIT or StikDebug (the JIT texts are a
    String Catalog of their own that the configuration excludes);
  - carry no trace of the machine that built it: no path under a user's home
    directory (/Users/<name>/), on a mounted volume (/Volumes/<name>/) or in
    the per-user temporary directories (/var/folders/) in the host code of an
    executable, and no debug stabs in an embedded framework (the linker's
    debug map, whose N_OSO entries name the object files of the build host's
    checkout and dependency trees; dsymutil has read it into the dSYM by then,
    and strip -S removes it and keeps the UUID). The strings of those stabs
    are not searched for a path. Xcode strips the application's own
    executable when it archives, and strips nothing it embeds. A path that a
    dependency compiles in from its prefix is the dependencies' to avoid
    (dependencies/README.md, "No build-host paths"); and
  - pass scripts/check-privacy-manifests.py; and
  - carry Send feedback (Andarium/README.md#send-feedback) only when the build
    names a receiver: the feature is compiled in exactly where the ignored
    local configuration holds an address, in this configuration alone. A
    product without an address holds nothing of it: no type, text, framework
    or Info.plist key; a product with one holds all of it and the address
    the build named. The local configuration's receiver is in no file of a
    bundle whose build does not name it, which the check finds by its bytes
    and never prints. Info.plist keeps every value of Config/Info.plist, as
    its preprocessing is to change only the optional features' keys. The feature's
    texts are the String Catalog table Feedback, which the build compiles in
    with the feature and no other: a product without it has no Feedback
    strings table, found by the file name whatever it holds, and a product
    with it has the table in Japanese and both Chinese. The What's New
    notes are the one exception: the entry about Send feedback is bundled
    in every product and hidden by one without it, so the strings of that
    entry, and no other string of the notes' table, may stay. The table is
    one for both tracks, so an AppStore bundle holds the beta track's strings
    too: those of its entries about Send feedback are read from the beta
    track's source file (--beta-notes); and
  - carry Buy me tokens (Andarium/README.md#buy-me-tokens) only when the build
    names its four product identifiers: the feature is compiled in exactly where
    the ignored local configuration holds all four, in this configuration alone.
    A product without them holds nothing of it: no type, StoreKit use, text,
    strings table or Info.plist key; a product with them holds all of it and
    the four identifiers the build named, each non-empty, well formed, distinct
    and no placeholder. The local configuration's identifiers are in no file of
    a bundle whose build does not name them, which the check finds by their
    bytes and never prints;
  - carry the tip header's developer (name, GitHub and X handles, the avatar and
    the GitHub mark) only where the product has Buy me tokens and the build
    names the value: an Info.plist key for each value the build names and for
    no other, and in Assets.car the GitHub mark (GitHubLogo) where a GitHub
    handle is named, the avatar (DeveloperAvatar) where a name is, and the X
    logo of Follow developer on X (XLogo) where an X handle is, and none of
    them otherwise. Artwork files lie in no bundle, and no file holds the
    profile address of a local handle. A handle is a part of the bundle
    identifier, so the check compares keys and asset names, not bytes; and
  - carry Review on the App Store (Andarium/README.md#review-on-the-app-store)
    only when the build names the application's App Store identifier: the
    feature is compiled in exactly where the ignored local configuration holds
    one, in this configuration alone. A product without one holds nothing of
    it: no type, address query, text, strings table or Info.plist key; a
    product with one holds all of it, the strings table in Japanese and both
    Chinese, and the identifier the build named (well formed, no placeholder).
    The local configuration's identifier is in no file of a bundle whose build
    does not name it, which the check finds by its digits and never prints.
    The rating prompt is part of the same feature: its counter, its record
    and the StoreKit request are in the product exactly where the item is, and
    its Debug knobs (a launch's way to set the counter) are in no AppStore
    product; and
  - carry Follow developer on X (Andarium/README.md#follow-developer-on-x)
    only when the build names a handle, by the same rule: compiled in exactly
    where the ignored local configuration holds a handle and the ignored
    Local directory holds the logo, in this configuration alone. A product
    without a handle holds nothing of it: no type, Info.plist key, FollowX
    strings table or logo in its asset catalog, unless the tip header's X
    button names a handle of its own, which keeps the logo and the type that
    builds the profile's address (FollowXProfile) and nothing of the row; a
    product with a handle holds all of it, the handle the build named, and a
    logo. The local handle is in no file of a bundle whose build does not name
    it, which the check finds as a profile address or as a property list's
    whole string (a bare scan of its bytes would match the bundle identifier,
    which holds the same word), and never prints; and
  - carry the ICP filing number at the bottom of Info
    (Andarium/README.md#icp-filing-number) only when the build names a number,
    by the same rule and a switch of its own, which needs no tip, review or X
    value: compiled in exactly where the ignored local configuration holds one,
    in this configuration alone. A product without a number holds nothing of
    it: no type, no Info.plist key. A product with one holds the type, the
    address of MIIT's filing site and the key, whose value is the number the
    build named, and the number in no other file. The local number is in no
    file of a bundle whose build does not name it, as UTF-8 or as the UTF-16 of
    a property list, and is never printed; and
  - bundle the What's New notes of its own track alone: the AppStore bundle
    holds the App Store track's file (WhatsNewAppStore.json) and not the beta
    track's, a TestFlight bundle the beta track's (WhatsNew.json) and not the
    App Store track's, each a list of releases; and
  - have the app icon of its own configuration alone: DuskJade in AppStore,
    DuskEmber in TestFlight, as the primary icon of the iPhone and the iPad in
    Info.plist and as the one app icon of the compiled asset catalog
    (Assets.car, read by its typed renditions with assetutil), and no other
    icon: none in Info.plist's icon keys, a nested catalog or an icon file or
    document of the other icon's name, so an AppStore bundle holds nothing of
    DuskEmber; and
  - open the files of the two document pickers (Install APK and the file
    browser's Import) in place, through SwiftUI's fileImporter, and hold no
    trace of the copy-mode presenter every other configuration uses
    (Andarium/README.md#configurations): the application refers to both
    importers and to none of the presenter's types.

The knob scan reads bytes, so it does not see a Swift string of up to 15 bytes
(ANDARIUM_START is one): the compiler keeps those in instruction immediates.
The launch names stay out of the application because the configuration
compiles Live/LaunchEnvironment.swift out, and the scan covers the longer names.
The leak scans read bytes too, so a local value of up to 15 bytes written as a
Swift literal in code would be out of their sight; a local value reaches the
product through a build setting and the Info.plist, never through source. A
run walks the bundle once for all of its leak scans, and looks for a value as
UTF-8 and as UTF-16 of either byte order, in every file of the bundle (the
staged system image, andarium-system/, included). The checks that find a
feature's resources look in the whole bundle too, nested bundles included: its
strings tables in any *.lproj, its keys in any property list, its asset names
in any Assets.car. A supplied value is never printed, not even as part of a
path: every line the check writes has it replaced.
The console lines are long enough to be text in the binary, so a build whose
code still holds one fails, whether or not anything calls it.

The TestFlight configuration (`--configuration TestFlight`) is held to every
rule above, and in addition to carry none of Buy me tokens, Review on the App
Store (with its rating prompt) and the ICP filing number, whatever the ignored
local configuration holds: the build names no value for them, and the product
holds no type, text, strings table, Info.plist key, tip header piece or
artwork of them and no value of the local configuration, which the check finds
by its bytes and never prints.

The Xcode project runs it as the last build phase of the AppStore and TestFlight
configurations, so a build that breaks one of these rules fails. In every other
configuration a phase runs `--feedback`, which checks Send feedback alone,
another `--tip-jar`, which checks Buy me tokens alone, a third `--review`,
which checks Review on the App Store alone, a fourth `--follow-x`, which
checks Follow developer on X alone, a fifth `--icp`, which checks the ICP
filing number alone, and a sixth `--pickers`: there each feature is absent
unless a test or capture script arranged it with the example address,
identifiers, placeholder, handle or number, in Debug alone. Each of the five
prints one line that says whether its feature is compiled in; the sixth checks
that the product holds the copy-mode presenter, the proof that the check above
finds it.
"""

from __future__ import annotations

__import__("sys").dont_write_bytecode = True

import argparse
import contextlib
import dataclasses
import functools
import json
import os
import plistlib
import re
import struct
import subprocess
import sys
from pathlib import Path

KNOB = re.compile(rb"\b(?:ANDARIUM|KERNARIUM|DARWIN_UML|UML)_[A-Z][A-Z0-9_]{2,}\b")
# What ConsoleReport (Shared/ConsoleReport.swift) prints, as far as its text is
# the same in every line; the configuration compiles the type out.
HARNESS_LINES = re.compile(
    rb"Andarium stats|Andarium thermal state|Andarium: runtime returned|Andarium: application ")
# What a path names about the machine that built the code: the account whose
# home directory held the checkout, the volume that held the checkout or the
# dependency prefixes, and the build's temporary directories. A bare
# "/Volumes/" or a format such as "/Volumes/%s" is no path of a build and
# does not match.
HOST_PATHS = (
    ("a path under a home directory",
     re.compile(rb"/Users/[A-Za-z0-9._-]+/[\x21-\x7e]*")),
    ("a path on a mounted volume",
     re.compile(rb"/Volumes/[A-Za-z0-9._ -]+/[\x21-\x7e]*")),
    ("a path in a temporary build directory",
     re.compile(rb"/(?:private/)?var/folders/[\x21-\x7e]+")),
)
# Sections that hold the guest, not the host: the Linux kernel image a runtime
# carries, and the boot files of a Linux runtime.
GUEST_SECTIONS = {("__TEXT", "__uml_elf"), ("__TEXT", "__uml_boot_base"), ("__TEXT", "__uml_boot_init")}
# Where the host's own instructions are. A word that is the debugger request
# (below) in a section of data is no request.
CODE_SECTIONS = {("__TEXT", "__text")}
# `brk #0xf00d`: the instruction a process uses to ask the debugger it is
# attached to for JIT memory (darwin/cpu/jit_memory/executable_memory.cpp).
# Only the debugger-route build of the runtime contains it.
JIT_DEBUGGER_REQUEST = bytes.fromhex("a0013ed4")

MACHO_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
CPU_TYPE_ARM64 = 0x0100000C
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
N_STAB = 0xE0
N_SO = 0x64
N_OSO = 0x66
N_SOL = 0x84
# The stabs whose strings are paths: the compilation directory and source
# file, the object file, and an included file. The others name symbols.
PATH_STABS = frozenset({N_SO, N_OSO, N_SOL})
CHECKER = Path(__file__).resolve().parents[2] / "scripts" / "check-privacy-manifests.py"

# The configurations that read the ignored local configuration. TestFlight is
# the AppStore product without Buy me tokens, Review on the App Store and the
# ICP filing number: it carries none of the three, whatever its build names.
TESTFLIGHT = "TestFlight"
APP_STORE = "AppStore"
STORE_CONFIGURATIONS = (APP_STORE, TESTFLIGHT)


def is_store(configuration: str) -> bool:
    return configuration in STORE_CONFIGURATIONS


def absence_reason(configuration: str, feature: str, default: str) -> str:
    """Why a product is to hold nothing of `feature`: TestFlight has none, and
    another configuration holds it only where its build names the value
    (`default` says so)."""
    return f"{configuration} has no {feature}" if configuration == TESTFLIGHT else default


# A value the run was given (an identifier, a number, an address, a handle, a
# name of the local configuration) is never written, not even as a part of a
# path of the bundle, which can spell it. Every line of the report goes through
# `emit`. A value shorter than MIN_REDACTED is not a secret worth the damage to
# the words around it, and the arranged placeholders are public.
MIN_REDACTED = 4
REDACTED = "<value>"
_SENSITIVE: re.Pattern[str] | None = None


def sensitive_pattern(options: argparse.Namespace) -> re.Pattern[str] | None:
    arranged = {FEEDBACK_ARRANGED, REVIEW_ARRANGED, ICP_ARRANGED, FOLLOW_X_ARRANGED,
                *TIP_ARRANGED.values(), *DEVELOPER_ARRANGED.values()}
    given = [options.feedback_address, options.feedback_receiver, options.follow_x_handle,
             options.developer_x_handle, *split_products(options.tip_products).values(),
             *split_products(options.tip_local_products).values(), options.review_id, options.review_local_id,
             options.developer_name, options.developer_github, options.developer_x,
             options.developer_local_github, options.icp_number, options.icp_local_number]
    values = {value for value in given if value and value not in arranged}
    # The digits of an App Store identifier are searched for alone, so they are replaced alone too.
    values |= {value[2:] for value in values if re.fullmatch(r"id[0-9]+", value)}
    values = {value for value in values if len(value) >= MIN_REDACTED}
    if not values:
        return None
    return re.compile("|".join(re.escape(value) for value in sorted(values, key=len, reverse=True)), re.I)


def emit(text: str, error: bool = False) -> None:
    """Write one line of the report."""
    if _SENSITIVE is not None:
        text = _SENSITIVE.sub(REDACTED, text)
    print(text, file=sys.stderr if error else sys.stdout)

# Send feedback. The build writes the receiver to Info.plist under this key
# only where the feature is compiled in (Andarium/Config/Andarium.xcconfig).
FEEDBACK_KEY = "AndariumFeedbackAddress"
# The only address a configuration other than AppStore may carry: the one the
# test and capture scripts arrange.
FEEDBACK_ARRANGED = "feedback@example.com"
# What the feature leaves in a binary: its types (Swift writes a name's length
# before it, so a fragment of the name matches), the subject's prefix, the
# Info.plist key it reads, and the system frameworks only it uses.
FEEDBACK_REQUIRED = (b"Andarium feedback: ", FEEDBACK_KEY.encode(), b"MessageUI.framework")
FEEDBACK_FRAGMENTS = (
    b"SendFeedback", b"MFMailCompose", b"PhotosUI.framework", *FEEDBACK_REQUIRED)
# Words the feature puts in a String Catalog.
FEEDBACK_WORDS = ("Send feedback", "Andarium feedback")
# The What's New notes have two tracks, each its own file of Shared that the
# configurations bundle alone: the beta track (Shared/WhatsNew.json) in every
# configuration but AppStore, and the App Store track (Shared/WhatsNewAppStore.json)
# in AppStore. A track's entry about Send feedback is marked with the feature it
# is about. A build without the feature hides the entry at run time
# (WhatsNewFeature in AndariumCore), so its strings stay in the notes' table,
# which a String Catalog compiles whole for both tracks, and are the one place
# the words may remain.
BETA_NOTES_FILE = "WhatsNew.json"
APP_STORE_NOTES_FILE = "WhatsNewAppStore.json"
NOTES_TABLE = "WhatsNew"
NOTES_FEATURE = "sendFeedback"
# The feature's own table (Localization/Feedback.xcstrings), which a String
# Catalog compiles to Feedback.strings, and to Feedback.stringsdict for a plural,
# in each language's directory; and the languages that table has besides English.
FEEDBACK_TABLE = "Feedback"
FEEDBACK_LANGUAGES = ("ja", "zh-Hans", "zh-Hant")
# Buy me tokens. The build writes the four product identifiers to Info.plist,
# a dictionary with one for each tier, under this key only where the feature is
# compiled in (Andarium/Config/Andarium.xcconfig).
TIP_KEY = "AndariumTipProducts"
TIP_TIERS = ("lite", "pro", "max", "ultra")
# The only identifiers a configuration other than AppStore may carry: the ones
# the test and capture scripts arrange.
TIP_ARRANGED = {tier: f"com.example.andarium.tip.{tier}" for tier in TIP_TIERS}
# What the feature leaves in a binary: its types (Swift writes a name's length
# before it, so a fragment of the name matches), the Info.plist key it reads
# and the system framework only it uses.
TIP_REQUIRED = (b"TipJarModel", TIP_KEY.encode(), b"StoreKit.framework")
TIP_FRAGMENTS = (b"TipJar", *TIP_REQUIRED)
# StoreKit is also what the rating prompt of Review on the App Store uses, so a
# product with that and no tip sheet links it too: the framework is required
# of a product with the sheet and says nothing about a product without.
TIP_SHARED = frozenset({b"StoreKit.framework"})
# The feature's own strings table (Localization/TipJar.xcstrings), which a String
# Catalog compiles to TipJar.strings in each language's directory, and a word of
# it that no other table has.
TIP_TABLE = "TipJar"
TIP_WORDS = ("Buy me tokens",)
# Review on the App Store. The build writes the application's App Store
# identifier ("id" and digits) to Info.plist under this key only where the
# feature is compiled in (Andarium/Config/Andarium.xcconfig).
REVIEW_KEY = "AndariumReviewID"
# The only identifier a configuration other than AppStore may carry: the
# placeholder the test scripts arrange.
REVIEW_ARRANGED = "id0000000000"
# What the feature leaves in a binary: its types, the Info.plist key it reads
# and the query that makes the address the write-review page.
# The rating prompt (Andarium/README.md#rating-prompt) is part of it: its
# counter and the StoreKit call that asks, whose symbol name is in the binary
# wherever the call is.
REVIEW_REQUIRED = (
    b"ReviewLink", REVIEW_KEY.encode(), b"action=write-review", b"ReviewAskTracker", b"requestReview")
REVIEW_FRAGMENTS = (b"ReviewServices", b"ReviewConfiguration", b"ReviewAsk", *REVIEW_REQUIRED)
# The feature's own strings table (Localization/Review.xcstrings), and a word of
# it that no other table has.
REVIEW_TABLE = "Review"
REVIEW_WORDS = ("Review on the App Store",)
# Follow developer on X. The build writes the developer's handle to Info.plist
# under this key only where the row is compiled in (Andarium/Config/Andarium.xcconfig).
FOLLOW_X_KEY = "AndariumFollowXHandle"
# The only handle a configuration other than AppStore may carry: the one the test
# and capture scripts arrange, and the placeholder of Developer.local.xcconfig.example.
FOLLOW_X_ARRANGED = "example_handle"
# What the row leaves in a binary: its types (Swift writes a name's length before
# it, so a fragment of the name matches), the line of its text that is too long
# to sit in an instruction, and the Info.plist key it reads. The type that builds
# the profile's address is the tip header's X button's as well, so it is the
# row's only where a handle is named for the row.
FOLLOW_X_REQUIRED = (b"Follow developer on", FOLLOW_X_KEY.encode())
FOLLOW_X_FRAGMENTS = (b"FollowXRow", b"FollowXTitle", b"FollowXWords", b"FollowXLogo", *FOLLOW_X_REQUIRED)
FOLLOW_X_PROFILE = b"FollowXProfile"
# Words the row puts in a String Catalog.
FOLLOW_X_WORDS = ("Follow developer on",)
# The row's own table (Localization/FollowX.xcstrings), by the same rule as Feedback.
FOLLOW_X_TABLE = "FollowX"
# The logo's name in the asset catalog the build compiles in with the row or the
# header's X button (Assets.car keeps an asset's name as plain text), and the file
# names of its artwork, which no bundle carries as a file.
FOLLOW_X_ASSET = b"XLogo"
FOLLOW_X_FILES = frozenset({"x-logo.svg", "glyph.svg"})
# The shape of a handle of X, the same rules as FollowXProfile.isWellFormed.
FOLLOW_X_HANDLE_PATTERN = re.compile(r"[A-Za-z0-9_]{1,15}")
# The hosts a profile address of the developer could name.
FOLLOW_X_HOSTS = ("x.com", "twitter.com")
# The ICP filing number at the bottom of Info. The build writes the number to
# Info.plist under this key only where the footnote is compiled in
# (Andarium/Config/Andarium.xcconfig).
ICP_KEY = "AndariumICPNumber"
# The only number a configuration other than AppStore may carry: the placeholder
# the test and capture scripts arrange, and the one of Developer.local.xcconfig.example.
ICP_ARRANGED = "示例ICP备00000000号-0A"
# What the footnote leaves in a binary: its types, the Info.plist key it reads
# and the host of the filing site its link opens.
ICP_REQUIRED = (b"ICPFiling", ICP_KEY.encode(), b"beian.miit.gov.cn")
ICP_FRAGMENTS = (b"ICPFootnote", b"ICPStorefront", *ICP_REQUIRED)
# The tip header's developer (README: Buy me tokens). Its values reach the product
# as Info.plist keys and its artwork as assets, only in an AppStore build that has the
# sheet; the tests' arrangement states the placeholder `example` for the name and the
# GitHub handle and the X placeholder for the X handle.
DEVELOPER_KEYS = {
    "name": "AndariumDeveloperName", "github": "AndariumDeveloperGitHub", "x": "AndariumDeveloperX"}
DEVELOPER_ARRANGED = {"name": "example", "github": "example", "x": FOLLOW_X_ARRANGED}
# The shape of a handle of GitHub: letters, digits and single hyphens, 1 to 39, not at either end.
GITHUB_HANDLE_PATTERN = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}")
# The asset each value brings, in the catalog: the avatar with the name, the GitHub mark
# with its handle (the X logo is judged with Follow developer on X), and the artwork
# files that no bundle carries.
DEVELOPER_ASSETS = {"name": b"DeveloperAvatar", "github": b"GitHubLogo"}
DEVELOPER_FILES = frozenset({"github-logo.svg", "developer-avatar.jpeg"})
# The document pickers of Install APK and the file browser's Import. The App
# Store configuration opens the files in place with SwiftUI's fileImporter, one
# call for a single file and one for several, which the application refers to
# by these mangled names (the name of each, the first parameters and the
# completion; Swift writes a name's length before it). Every other
# configuration presents the copy-mode picker instead (Shared/CopyDocumentPicker.swift,
# compiled out by APP_STORE): a type of it, its modifier and the files of a
# pick. The scan reads the host code, as the others do.
PICKER_IN_PLACE = {
    "fileImporter for one file (Install APK)":
        b"12fileImporter11isPresented19allowedContentTypes12onCompletion",
    "fileImporter for several files (Import)":
        b"12fileImporter11isPresented19allowedContentTypes23allowsMultipleSelection12onCompletion",
}
PICKER_COPY = (b"18CopyDocumentPicker", b"18documentCopyPicker", b"12PickedCopies")
# Domains and top-level domains that name no mailbox (RFC 2606, RFC 6761).
PLACEHOLDER_DOMAINS = ("example.com", "example.org", "example.net")
PLACEHOLDER_TLDS = ("example", "invalid", "localhost", "test")


def thin_offset(data: bytes) -> int | None:
    if len(data) < 8:
        return None
    if struct.unpack_from(">I", data, 0)[0] == FAT_MAGIC:
        count = struct.unpack_from(">I", data, 4)[0]
        for index in range(min(count, 16)):
            cpu, _sub, offset, _size, _align = struct.unpack_from(
                ">IIIII", data, 8 + 20 * index)
            if cpu == CPU_TYPE_ARM64:
                return offset
        return None
    return 0 if struct.unpack_from("<I", data, 0)[0] == MACHO_64 else None


def section_ranges(
    data: bytes, base: int, wanted: set[tuple[str, str]],
) -> list[tuple[int, int]]:
    """File ranges of the named (segment, section) pairs of one Mach-O slice."""
    found = []
    count = struct.unpack_from("<I", data, base + 16)[0]
    position = base + 32
    for _ in range(count):
        command, size = struct.unpack_from("<II", data, position)
        if command == LC_SEGMENT_64:
            sections = struct.unpack_from("<I", data, position + 64)[0]
            entry = position + 72
            for _ in range(sections):
                name = data[entry:entry + 16].rstrip(b"\0").decode()
                segment = data[entry + 16:entry + 32].rstrip(b"\0").decode()
                length, offset = struct.unpack_from("<QI", data, entry + 40)
                if (segment, name) in wanted:
                    found.append((base + offset, base + offset + length))
                entry += 80
        position += size
    return found


def guest_ranges(data: bytes, base: int) -> list[tuple[int, int]]:
    """File ranges of the sections that hold the guest."""
    return section_ranges(data, base, GUEST_SECTIONS)


def host_code(path: Path) -> tuple[bytes, int] | None:
    """The bytes of one Mach-O file with the guest's sections blanked, and the
    offset of its arm64 slice; None for a file that is not an arm64 Mach-O."""
    data = path.read_bytes()
    base = thin_offset(data[:4096])
    if base is None:
        return None
    buffer = bytearray(data)
    for start, end in guest_ranges(data, base):
        buffer[start:end] = bytes(end - start)
    return bytes(buffer), base


def knobs(path: Path) -> list[str]:
    """The automation knob names in the host code of one Mach-O file."""
    code = host_code(path)
    if code is None:
        return []
    return sorted({match.decode() for match in KNOB.findall(code[0])})


def harness_lines(path: Path) -> list[str]:
    """The harness's console lines in the host code of one Mach-O file."""
    code = host_code(path)
    if code is None:
        return []
    return sorted({match.decode().strip() for match in HARNESS_LINES.findall(code[0])})


def symbol_table(data: bytes, base: int) -> tuple[int, int, int, int] | None:
    """The symbol table of a Mach-O: the offset and count of its struct
    nlist_64 entries, and the offset and size of its string table."""
    count = struct.unpack_from("<I", data, base + 16)[0]
    position = base + 32
    for _ in range(count):
        command, size = struct.unpack_from("<II", data, position)
        if command == LC_SYMTAB:
            offset, symbols, strings, strings_size = struct.unpack_from(
                "<IIII", data, position + 8)
            return base + offset, symbols, base + strings, strings_size
        position += size
    return None


def debug_stabs(data: bytes, base: int) -> tuple[int, int]:
    """The debug stabs in a Mach-O's symbol table, and how many of them are
    N_OSO, each of which names an object file."""
    table = symbol_table(data, base)
    if table is None:
        return 0, 0
    offset, symbols, _strings, _size = table
    # struct nlist_64 is 16 bytes and n_type is its fifth.
    kinds = data[offset + 4:offset + 16 * symbols:16]
    return sum(1 for kind in kinds if kind & N_STAB), kinds.count(N_OSO)


def without_debug_map(data: bytes, base: int, kinds: frozenset[int] | None = None) -> bytes:
    """The Mach-O with the strings of its debug stabs blanked: the names of
    the objects, sources and functions the linker recorded. A framework that
    carries them fails for that, and Xcode strips them from the application's
    own executable when it archives, so neither is a path the build host left
    in the code. `kinds` limits the blanking to those stab types (PATH_STABS):
    the linker shares a string between a symbol and its stab, so blanking a
    function's stab would blank the symbol the code carries as well."""
    table = symbol_table(data, base)
    if table is None:
        return data
    offset, symbols, strings, size = table
    buffer = bytearray(data)
    for entry in range(symbols):
        string, kind = struct.unpack_from("<IB", data, offset + 16 * entry)
        if kind & N_STAB and (kinds is None or kind in kinds) and 0 < string < size:
            end = data.find(b"\0", strings + string, strings + size)
            if end > 0:
                buffer[strings + string:end] = bytes(end - strings - string)
    return bytes(buffer)


def build_host_traces(path: Path, debug_map: bool = True) -> list[str]:
    """What one Mach-O file keeps of the machine that built it. `debug_map`
    says whether its debug stabs count: they do for a framework, whose binary
    ships as linked. The strings of the stabs are never searched for a path:
    a framework with a debug map fails on the map, and the application's own
    executable loses it when Xcode archives."""
    code = host_code(path)
    if code is None:
        return []
    data, base = code
    found = []
    stabs, objects = debug_stabs(data, base) if debug_map else (0, 0)
    if stabs:
        found.append(
            f"carries the linker's debug map ({stabs} stabs, {objects} N_OSO "
            "object paths); strip -S it after dsymutil")
    data = without_debug_map(data, base)
    for label, pattern in HOST_PATHS:
        paths = sorted({match.decode() for match in pattern.findall(data)})
        if paths:
            found.append(
                f"names {label} ({len(paths)}): "
                f"{paths[0][:80]}{' ...' if len(paths) > 1 else ''}")
    return found


# The permissions Andarium asks of the person, one capability each: Camera,
# Microphone and Location.
USAGE_DESCRIPTIONS = (
    "NSCameraUsageDescription",
    "NSMicrophoneUsageDescription",
    "NSLocationWhenInUseUsageDescription",
)


def info_problems(info: dict) -> list[str]:
    found = []
    if info.get("ITSAppUsesNonExemptEncryption") is not False:
        found.append("Info.plist: ITSAppUsesNonExemptEncryption must be false")
    capabilities = info.get("UIRequiredDeviceCapabilities")
    for capability in ("arm64", "metal"):
        if not isinstance(capabilities, list) or capability not in capabilities:
            found.append(f"Info.plist: UIRequiredDeviceCapabilities lacks {capability}")
    if info.get("UIDeviceFamily") != [1, 2]:
        found.append("Info.plist: UIDeviceFamily must be [1, 2], iPhone and iPad")
    if "UIBackgroundModes" in info:
        found.append("Info.plist: the application has no background mode")
    # The system shows these when the person turns a capability on, and ends
    # the application at the request of a capability whose text is missing.
    for key in USAGE_DESCRIPTIONS:
        value = info.get(key)
        if not isinstance(value, str) or not value.strip():
            found.append(f"Info.plist: {key} must be a non-empty string")
    return found


def executables_of(bundle: Path) -> list[Path]:
    """The executable of one bundle, if its Info.plist names one."""
    try:
        with (bundle / "Info.plist").open("rb") as handle:
            name = plistlib.load(handle).get("CFBundleExecutable")
    except (OSError, plistlib.InvalidFileException, ValueError):
        return []
    return [bundle / name] if isinstance(name, str) and (bundle / name).is_file() else []


def executables(app: Path) -> list[Path]:
    """The executables of the application and of its embedded frameworks."""
    return [
        binary
        for bundle in [app, *sorted((app / "Frameworks").glob("*.framework"))]
        for binary in executables_of(bundle)
    ]


# The debugging and automation support an App Store runtime and application
# leave out (Andarium/README.md#configurations). Each entry is a kind and the
# fragments that name its machinery: mangled symbol names (C++ and Swift write
# a name's length before it) and the text its log lines hold. The stand-ins that
# keep the runtime API table's layout (runtimeSetFrameSink and
# runtimeSendConsoleInput return -ENOTSUP) are not on the list. The scan
# reads the host code, so a Swift name of up to 15 bytes in an instruction is
# not seen; the symbol fragments are what catch the application's Swift.
DEBUG_SYMBOLS = (
    ("frame mirror", (b"16FrameTapRegistry", b"11setFrameTap", b"14renderTapFrame",
                      b"7tapLoop", b"kernarium_runtime_loader_set_frame_sink")),
    ("console input", (b"13InputRegistry", b"7HostEnd4send",
                       b"kernarium_runtime_loader_send_console_input")),
    ("guest sampler", (b"11diagnostics12_GLOBAL__N_17Sampler",)),
    ("footprint log", (b"17FootprintReporter",)),
    ("virtual Jetsam", (b"13VirtualJetsam7observe", b"format_virtual_jetsam_line",
                        b"sample_process_footprint")),
    ("activity log", (b"18DisplayActivityLog", b"5video11ActivityLog")),
    ("census and histogram", (b"6census", b"execution_histogram_note",
                              b"execution_histogram_forget")),
    ("automation", (b"kernarium_runtime_automation_",
                    b"kernarium_runtime_loader_automation_", b"7harness",
                    b"14AutomationBoot")),
    ("test tooling", (b"5vsock9Forwarder", b"17UnixSocketChannel", b"_rfbGetScreen",
                      b"_rfbInitServer")),
    ("launch harness", (b"13ConsoleReport", b"15environmentName", b"13applyDeferred",
                        b"16printsStatistics", b"13launchApplied",
                        b"15ThermalOverride")),
    # The Simulator preview's denied-network notice (Model.previewNetworkNotice):
    # the Simulator cannot be denied the network, so the preview plays it.
    ("network notice preview", (b"20previewNetworkNotice",)),
    # The Simulator preview's play of the legacy install
    # (AppModel.previewInstallAttempt): the preview refuses the first attempt
    # for its version, which the application's install never does by itself.
    ("legacy install preview", (b"21previewInstallAttempt",)),
    # The list of old apps that the Simulator preview and a UI test's probe
    # session play in place of the image's command (ScriptedOldApps,
    # AppModel.scriptedOldApps and the probe's launch setting
    # OldAppsProbeLaunch): the application asks the image.
    ("old apps preview", (b"15ScriptedOldApps", b"15scriptedOldApps", b"18OldAppsProbeLaunch")),
    # The launch setting that shows the held-back text messages
    # (TextMessagesLaunch): the application offers them only once an accepted
    # image carries the service.
    ("text messages launch", (b"18TextMessagesLaunch",)),
    # The Simulator preview's hooks into the Send feedback sheet
    # (SendFeedbackServices.previewOpensAtLaunch and previewPrepare): the
    # preview opens the sheet and fills a draft; the application never does.
    ("send feedback preview",
     (b"20previewOpensAtLaunch", b"14previewPrepare")),
    # The Simulator preview's hooks into the Buy me tokens sheet
    # (TipJarServices.previewOpensSheet, previewPlays, previewFullHeight and
    # openLink, and the environment value that opens the sheet at full height):
    # the preview opens the sheet, plays a purchase, sizes it and sees which
    # profile a tap opens; the application never does.
    ("tip jar preview", (b"16previewOpensSheet", b"12previewPlays", b"17previewFullHeight",
                         b"14TipJarServicesV8openLink", b"19TipJarFullHeightKey")),
    # A Debug build's own check of the rating prompt (ReviewAskTracker.debugSet,
    # ReviewAsk.applyDebugLaunch): it sets the counter and clears the record.
    ("rating prompt debug", (b"8debugSet", b"16applyDebugLaunch")),
    # The UI tests' probe of the guest's keyboard and mouse
    # (Andarium/Shared/InputProbe.swift): its log, its launch, the recording
    # runtime and the session that runs without a guest.
    ("input probe", (b"10InputProbe", b"16InputProbeLaunch", b"29RecordingHardwareInputRuntime",
                     b"15beginInputProbe", b"17InputProbeReadout", b"19makeInputProbeModel",
                     b"10inputProbe")),
    # The UI tests' stand-in for the guest's thermal HAL, its launch (the
    # thermal state a probe states runs the thermal session) and the harness's
    # statement of Settings' "When hot" (Live/ThermalProbe.swift,
    # LaunchEnvironment.swift: ThermalProbeHal, HeatLimitLaunch,
    # LiveRuntime.beginThermalProbe).
    ("heat limit probe", (b"15ThermalProbeHal", b"15HeatLimitLaunch", b"17beginThermalProbe")),
    # The reading a test puts in place of the system's hinge and regions
    # (Andarium/Shared/FoldSceneReader.swift), compiled out by APP_STORE.
    ("fold reader stub", (b"15FoldSceneReaderC4stub",)),
    # The picked file's access that a hosted test puts in place of the real
    # one (AppModel.accessPickedFileStub), compiled out by APP_STORE.
    ("picked file access stub", (b"20accessPickedFileStub",)),
    # The camera without hardware (darwin/platform/synthetic_camera): a source
    # for tests and launchers, which an App Store runtime does not build.
    # namespace uml::platform, its class and entries.
    ("synthetic camera", (b"15SyntheticCamera", b"19SyntheticCameraImpl",
                          b"19makeSyntheticCamera", b"19encodeSyntheticJpeg",
                          b"17decodeChartMarker",
                          # The runtime's choice of it from the environment
                          # (Kernarium/Runtime/KernariumCamera.hpp).
                          b"6camera11parseSource", b"6camera12chooseSource",
                          b"15BackCamerasOnly")),
    # The camera's development lines (darwin/device/camera/camera_diagnostics.hpp):
    # what ROTATE_AND_CROP asks of the host and the footprint at each capture
    # checkpoint, printed by a launcher or a runtime that is not an App Store
    # build, and the Simulator preview's camera and thermal notices
    # (Model.previewCameraNotice and previewThermalNotice).
    ("camera diagnostics", (b"17printRotateAndCrop", b"15printCheckpoint",
                            b"19previewCameraNotice", b"20previewThermalNotice")),
    # The development build's compass check (Live/MotionSensors.swift,
    # CompassReadout, and its launch setting in Live/LaunchEnvironment.swift).
    ("compass readout", (b"14CompassReadout", b"20CompassReadoutLaunch")),
    # Simulated game controllers: the scripted input and the guest end of the
    # gamepad wire (AndariumCoreTestSupport, which only tests and the probe
    # tool link) and the host reader that moved there.
    ("synthetic controllers", (b"13GamepadScript", b"22GamepadHostFrameReader",
                               b"23AndariumCoreTestSupport")),
    # The arm64 JIT engine, the owner of executable memory and the debugger
    # route of the runtime and of the loader. namespace uml::cpu::jit_memory
    # and uml::cpu::arm64::jit, the engine's classes and entry names.
    ("JIT", (b"10jit_memory", b"5arm643jit", b"11JitCompiler", b"11JitExecutor",
             b"9JitEngine", b"16JitCacheGeometry", b"uml_arm64_jit_",
             b"darwin_uml_jit_enter_guest", b"kernarium_runtime_loader_prepare_jit",
             b"kernarium_runtime_loader_debugger_attached",
             # The application's own: the preference, the policy, the
             # debugger side and the Home section (Andarium/Shared/Jit.swift).
             b"13JitPreference", b"8JitShape", b"9JitAnswer", b"9JitStatus",
             b"11JitDebugger", b"10JitSection")),
)
DEBUG_STRINGS = (
    ("frame mirror", (b"uml-frame-tap",)),
    ("footprint log", (b"Kernarium: footprint", b"Kernarium: memory %s")),
    ("virtual Jetsam", (b"virtual Jetsam", b"uml-virtual-jetsam")),
    ("activity log", (b"uml-display %.3f", b"uml-video %.3f")),
    ("guest sampler", (b"# guest code samples",)),
    ("automation", (b"kernarium_runtime_automation_", b"automation boot with",
                    b"ADB authorization is off", b"removed the boot payload")),
    ("remote framebuffer", (b"RFB 003.00",)),
    ("input probe", (b"inputProbeLog", b"inputProbeField")),
    ("heat limit probe", (b"heat told ",)),
    ("camera diagnostics", (b"ROTATE_AND_CROP", b"Camera: memory: ")),
    ("compass readout", (b"Andarium: compass-check: ",)),
    ("synthetic camera", (b"SyntheticPhone1,1", b"SyntheticTablet1,1",
                          b"SyntheticLaptop1,1", b"synthetic-back-wide",
                          b"KERNARIUM_CAMERA_SOURCE", b"is not a back camera")),
    ("JIT", (b"--jit-cache-budget=", b"--execution-engine=jit",
             b"running on gadgets, not the JIT", b"open Andarium from StikDebug",
             b"Started without JIT")),
)
# What runs tests: a test bundle, and the frameworks and libraries that load it
# (XCTest, XCUIAutomation and the rest, Swift Testing). They are in an
# application that `xcodebuild test` hosted.
TEST_SUPPORT = re.compile(
    r"^(?:.*\.xctest|XC[A-Za-z]*\.framework|libXC[A-Za-z]*\.dylib"
    r"|_?Testing(?:_[A-Za-z0-9]+)?\.framework|lib_?Testing[A-Za-z0-9_]*\.dylib)$")


def debugger_requests(code: bytes, base: int) -> int:
    """How many instruction words of the host's code are the debugger request."""
    count = 0
    for start, end in section_ranges(code, base, CODE_SECTIONS):
        position = code.find(JIT_DEBUGGER_REQUEST, start, end)
        while position != -1:
            count += (position - start) % 4 == 0
            position = code.find(JIT_DEBUGGER_REQUEST, position + 1, end)
    return count


def debug_support(path: Path) -> list[str]:
    """The debugging and automation support in the host code of one Mach-O
    file, as `kind (fragment, ...)` for each kind found."""
    code = host_code(path)
    if code is None:
        return []
    found = []
    for table in (DEBUG_SYMBOLS, DEBUG_STRINGS):
        for kind, fragments in table:
            names = sorted(
                fragment.decode() for fragment in fragments if fragment in code[0])
            if names:
                found.append(f"{kind} ({', '.join(names)})")
    if debugger_requests(*code):
        found.append("JIT (an instruction asking a debugger for JIT memory)")
    return found


JIT_TEXT = re.compile(r"StikDebug|\bJIT\b", re.IGNORECASE)


def strings_in(value: object) -> list[str]:
    """Every key and string value of a property list."""
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        return [text for key, item in value.items() for text in (strings_in(key) + strings_in(item))]
    if isinstance(value, (list, tuple)):
        return [text for item in value for text in strings_in(item)]
    return []


def localized_jit_text(app: Path) -> list[str]:
    """The JIT text carried as localized text: a JIT strings table of any
    language, and any key or value of another table that names JIT or StikDebug."""
    found = []
    for table in sorted(app.rglob("*.lproj/*")):
        if table.suffix not in (".strings", ".stringsdict"):
            continue
        relative = table.relative_to(app)
        if table.stem == "JIT":
            found.append(f"{relative}: the JIT strings table, which an App Store build does not carry")
            continue
        raw = table.read_bytes()
        try:
            texts = strings_in(plistlib.loads(raw))
        except (plistlib.InvalidFileException, ValueError, OverflowError):
            # An old-style text file: UTF-16 with a mark, or UTF-8.
            texts = [raw.decode("utf-16" if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8", errors="replace")]
        for text in texts:
            if JIT_TEXT.search(text):
                found.append(f"{relative}: carries JIT text ({text[:60]!r})")
                break
    return found


def test_support(app: Path) -> list[str]:
    """The test bundles and test frameworks anywhere in the application."""
    found = []
    for directory, directories, files in os.walk(app):
        for name in list(directories):
            if TEST_SUPPORT.match(name):
                found.append(str((Path(directory) / name).relative_to(app)))
                directories.remove(name)
        found.extend(
            str((Path(directory) / name).relative_to(app))
            for name in files if TEST_SUPPORT.match(name))
    return sorted(found)


def feedback_files(app: Path) -> list[Path]:
    """The Mach-O files that can hold the application's code: its executable,
    the debug library a Debug build keeps the code in, and the frameworks."""
    found = list(executables(app))
    found.extend(path for path in sorted(app.glob("*.dylib")) if path not in found)
    return found


# One strict shape of an address, the same rules as SendFeedbackMail.isWellFormed:
# a local part of 1 to 64 letters, digits and . _ % + - that starts and ends
# with a letter or digit and has no two dots in a row, then @, then at least
# two dot-separated labels of letters, digits and hyphens (no label starts or
# ends with a hyphen) whose last is two or more letters. Quotes, angle
# brackets, a trailing semicolon, spaces and a second @ make no address.
FEEDBACK_ADDRESS_PATTERN = re.compile(
    r"[A-Za-z0-9](?:[A-Za-z0-9._%+-]{0,62}[A-Za-z0-9])?"
    r"@(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}")


def feedback_address_shape(address: str) -> bool:
    return (len(address) <= 254 and FEEDBACK_ADDRESS_PATTERN.fullmatch(address) is not None
            and ".." not in address.partition("@")[0])


def feedback_address_problems(configuration: str, address: str) -> list[str]:
    """What is wrong with the address a build names, whatever the product holds.
    The arranged example address is Debug's alone: Release, the build that
    sideloads and forks make, never takes one."""
    if not address:
        return []
    if not is_store(configuration):
        if address != FEEDBACK_ARRANGED:
            return [f"Send feedback: {configuration} names a receiver that is not the arranged example address; "
                    "only the AppStore and TestFlight configurations read the local configuration"]
        if configuration != "Debug":
            return [f"Send feedback: {configuration} names the arranged example address; "
                    "only Debug takes the arrangement"]
        return []
    if not feedback_address_shape(address):
        return ["Send feedback: the receiver in the local configuration is not an email address"]
    domain = address.partition("@")[2].lower()
    if (any(domain == name or domain.endswith("." + name) for name in PLACEHOLDER_DOMAINS)
            or domain.rpartition(".")[2] in PLACEHOLDER_TLDS):
        return ["Send feedback: the receiver in the local configuration is a placeholder address"]
    return []


# The leak scans. Each asks whether a file of the bundle holds a value of the
# local configuration that the build does not name; the answer names the
# files, never the value. A value is searched in the encodings a binary stores
# a string in (`encoded`): UTF-8 (the ASCII of a property list, the bytes of
# Mach-O code) and the UTF-16 of a binary property list's or a CFString's
# non-ASCII string, of either byte order, in either case of the ASCII letters,
# in every file of the bundle. A run asks all of its questions in one walk over
# the bundle (`one_walk`); a question outside that walk walks for itself.
@dataclasses.dataclass(frozen=True)
class Scan:
    """One question of a walk: whether the bytes of a file hold `needle`
    (lowercase) and, where `unless` is given, are not followed by a byte
    pattern of it (an address that goes on with a path is another address);
    or, for `whole`, whether a string of a property list or strings table is
    exactly that text (lowercase)."""
    needle: bytes = b""
    unless: bytes = b""
    whole: str = ""


# Property lists and strings tables, whose strings `Scan.whole` compares.
WHOLE_STRING_SUFFIXES = (".plist", ".strings", ".stringsdict")
WHOLE_STRING_LIMIT = 16 << 20
CHUNK = 8 << 20
# The byte that follows a value of an address in each encoding, and means the
# address goes on: a letter, digit or one of . _ / - of the next character.
ADDRESS_GOES_ON = {
    "utf-8": rb"[a-z0-9._/-]",
    "utf-16-be": rb"\x00[a-z0-9._/-]",
    "utf-16-le": rb"[a-z0-9._/-]\x00",
}
ENCODINGS = ("utf-8", "utf-16-be", "utf-16-le")


def encoded(value: str):
    """`value` in each encoding a binary stores a string in, as the bytes the
    scans compare (lowercase): the one place the encodings are named."""
    for encoding in ENCODINGS:
        yield encoding, value.encode(encoding).lower()


def value_scans(values: list[str]) -> set[Scan]:
    return {Scan(needle=needle) for value in values if value for _encoding, needle in encoded(value)}


def address_scans(addresses: list[str]) -> set[Scan]:
    return {Scan(needle=needle, unless=ADDRESS_GOES_ON[encoding])
            for address in addresses if address for encoding, needle in encoded(address)}


def scan_bundle(app: Path, scans: set[Scan]) -> dict[Scan, list[str]]:
    """The files of the bundle that answer each scan, by path, in one walk.
    A file is read in chunks, with the tail of the last one kept so that a
    match across the border is found, until each of its byte scans has
    answered or it ends. Nothing to ask is no walk."""
    found: dict[Scan, list[str]] = {scan: [] for scan in scans}
    if not scans:
        return found
    plain = [scan for scan in scans if scan.needle and not scan.unless]
    guarded = [(scan, re.compile(re.escape(scan.needle) + b"(?!" + scan.unless + b")"))
               for scan in scans if scan.needle and scan.unless]
    wholes = [scan for scan in scans if scan.whole]
    keep = max([len(scan.needle) + 2 for scan in scans if scan.needle], default=0)
    for directory, _directories, files in os.walk(app):
        for name in sorted(files):
            path = Path(directory) / name
            if path.is_symlink() or not path.is_file():
                continue
            relative = str(path.relative_to(app))
            try:
                size = path.stat().st_size
                pending_plain = list(plain)
                pending_guarded = list(guarded)
                with path.open("rb") as handle:
                    tail = b""
                    while (pending_plain or pending_guarded) and (chunk := handle.read(CHUNK)):
                        window = (tail + chunk).lower()
                        for scan in [scan for scan in pending_plain if scan.needle in window]:
                            found[scan].append(relative)
                            pending_plain.remove(scan)
                        for item in [item for item in pending_guarded if item[1].search(window)]:
                            found[item[0]].append(relative)
                            pending_guarded.remove(item)
                        tail = window[-keep:] if keep > 0 else b""
                if wholes and path.suffix in WHOLE_STRING_SUFFIXES and size <= WHOLE_STRING_LIMIT:
                    try:
                        texts = {text.lower() for text in strings_in(plistlib.loads(path.read_bytes()))}
                    except (plistlib.InvalidFileException, ValueError, OverflowError):
                        texts = set()
                    for scan in wholes:
                        if scan.whole in texts:
                            found[scan].append(relative)
            except OSError:
                continue
    return found


# The answers of the walk the run made, and the bundle they are for.
_SHARED: tuple[Path, dict[Scan, list[str]]] | None = None


@contextlib.contextmanager
def one_walk(app: Path, scans: set[Scan]):
    """Answer `scans` in one walk, for every leak question the run asks of
    `app` meanwhile. A question the walk did not plan is walked for itself."""
    global _SHARED
    bundle_tree.cache_clear()
    _SHARED = (app, scan_bundle(app, scans))
    try:
        yield
    finally:
        _SHARED = None
        bundle_tree.cache_clear()


def leaks(app: Path, scans: set[Scan]) -> list[str]:
    """The files of the bundle that answer any of `scans`; named by path, never by the value."""
    if not scans:
        return []
    if _SHARED is not None and _SHARED[0] == app:
        answers = _SHARED[1]
        missing = scans - answers.keys()
        if missing:
            answers.update(scan_bundle(app, missing))
    else:
        answers = scan_bundle(app, scans)
    return sorted({name for scan in scans for name in answers[scan]})


def value_leaks(app: Path, values: list[str]) -> list[str]:
    """The files of the bundle whose bytes hold any of the values of a local
    configuration, in either case and in the encodings above."""
    return leaks(app, value_scans(values))


def address_leaks(app: Path, addresses: list[str]) -> list[str]:
    """The files of the bundle whose bytes hold the profile address of an
    account, in either case; named by path, never by the address. An address
    that goes on with a path (the project's own repository under the same
    account) is another address."""
    return leaks(app, address_scans(addresses))


def receiver_leaks(app: Path, receiver: str) -> list[str]:
    """The files of the bundle whose bytes hold the receiver of the local configuration."""
    return value_leaks(app, [receiver])


# What a feature leaves in resources, wherever the bundle keeps them. The
# checks of a feature's strings tables, property list keys and asset names are
# made on the application's root and on every nested bundle, property list and
# asset catalog (a framework's resource bundle, a plug-in, a stray file), with
# the helpers that read the root.
RESOURCE_NAMES = (*DEVELOPER_ASSETS.values(), FOLLOW_X_ASSET)


@dataclasses.dataclass(frozen=True)
class BundleTree:
    directories: tuple[Path, ...]
    plist_keys: dict[str, frozenset[str]]
    catalog_names: dict[str, frozenset[bytes]]


@functools.lru_cache(maxsize=1)
def bundle_tree(app: Path) -> BundleTree:
    """Every directory of the bundle (links not followed), the top-level keys of
    each property list, and which of the asset names each Assets.car holds, by
    path from the root of the bundle; read once per run."""
    directories: list[Path] = []
    plist_keys: dict[str, frozenset[str]] = {}
    catalog_names: dict[str, frozenset[bytes]] = {}
    for directory, _directories, files in os.walk(app):
        directories.append(Path(directory))
        for name in sorted(files):
            path = Path(directory) / name
            if path.is_symlink() or not path.is_file():
                continue
            relative = str(path.relative_to(app))
            try:
                if path.suffix == ".plist" and path.stat().st_size <= WHOLE_STRING_LIMIT:
                    with path.open("rb") as handle:
                        content = plistlib.load(handle)
                    if isinstance(content, dict):
                        plist_keys[relative] = frozenset(str(key) for key in content)
                elif name == "Assets.car":
                    data = path.read_bytes()
                    catalog_names[relative] = frozenset(item for item in RESOURCE_NAMES if item in data)
            except (OSError, plistlib.InvalidFileException, ValueError, OverflowError):
                continue
    return BundleTree(tuple(sorted(directories)), plist_keys, catalog_names)


def lproj_files(app: Path, pattern: str = "*") -> list[Path]:
    """The files of every *.lproj directory of the bundle, nested bundles included."""
    return sorted(path for directory in bundle_tree(app).directories for path in directory.glob(f"*.lproj/{pattern}"))


def plist_holders(app: Path, key: str) -> list[str]:
    """The property lists of the bundle, root Info.plist first, whose top level has `key`; by path."""
    return sorted(path for path, keys in bundle_tree(app).plist_keys.items() if key in keys)


def catalog_holders(app: Path, name: bytes) -> list[str]:
    """The asset catalogs of the bundle that hold the asset `name`; by path."""
    return sorted(path for path, names in bundle_tree(app).catalog_names.items() if name in names)


# The optional features' blocks of Config/Info.plist, and the keys they write.
OPTIONAL_BLOCKS = re.compile(
    r"^#ifdef (?:FEEDBACK_MAIL|TIP_JAR|APP_REVIEW|SHEET_NAME|SHEET_GITHUB|SHEET_X|FOLLOW_X|ICP_FILING)\n.*?^#endif\n",
    re.S | re.M)
OPTIONAL_KEYS = frozenset({FEEDBACK_KEY, TIP_KEY, REVIEW_KEY, FOLLOW_X_KEY, ICP_KEY, *DEVELOPER_KEYS.values()})


def info_source_problems(app: Path, source: Path) -> list[str]:
    """Every key of Config/Info.plist but the optional features' (feedback, tip, review, developer and
    Follow developer on X), as the built Info.plist has it. The source is
    preprocessed (those blocks are conditional), and a build adds keys of its own and fills in build
    settings, so what is compared is each source key, a value naming a build
    setting (`$(...)`) matching whatever the build made of it. A preprocessor
    that expanded a macro in a value shows here."""
    try:
        text = OPTIONAL_BLOCKS.sub("", source.read_text(encoding="utf-8"))
        wanted = plistlib.loads(text.encode())
        with (app / "Info.plist").open("rb") as handle:
            built = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException, ValueError):
        return [f"Info.plist: cannot be compared with {source.name}"]

    def same(expected: object, actual: object) -> bool:
        if isinstance(expected, str) and "$(" in expected:
            return isinstance(actual, str)
        if isinstance(expected, dict):
            return (isinstance(actual, dict)
                    and all(key in actual and same(value, actual[key]) for key, value in expected.items()))
        if isinstance(expected, list):
            return (isinstance(actual, list) and len(actual) == len(expected)
                    and all(same(left, right) for left, right in zip(expected, actual)))
        return type(expected) is type(actual) and expected == actual

    found = []
    for key, value in wanted.items():
        if key in OPTIONAL_KEYS:
            continue
        if key not in built:
            found.append(f"Info.plist: {key} of {source.name} is missing from the built one")
        elif not same(value, built[key]):
            found.append(f"Info.plist: {key} differs from {source.name}")
    return found


def notes_file(configuration: str) -> str:
    """The notes file a configuration bundles: the App Store track's in AppStore,
    the beta track's in every other configuration (TestFlight included)."""
    return APP_STORE_NOTES_FILE if configuration == APP_STORE else BETA_NOTES_FILE


def note_strings(path: Path) -> tuple[frozenset[str], frozenset[str]]:
    """The strings (title, text and points) of the entries of a notes file, which the
    notes' table holds under their English text: those of the entries about Send
    feedback (marked with its requirement), and those of every other entry. Both
    are empty if the file is missing or unreadable, so nothing is then exempt."""
    try:
        releases = json.loads(path.read_text(encoding="utf-8"))
        entries = [entry for release in releases for entry in release["entries"]]
    except (OSError, ValueError, KeyError, TypeError):
        return frozenset(), frozenset()
    marked: set[str] = set()
    shown: set[str] = set()
    for entry in entries:
        requirement = entry.get("requirement") if isinstance(entry, dict) else None
        about = isinstance(requirement, dict) and requirement.get("feature") == NOTES_FEATURE
        points = entry.get("points") if isinstance(entry, dict) else None
        for note in (entry.get("title"), entry.get("text"), *(points if isinstance(points, list) else ())) \
                if isinstance(entry, dict) else ():
            if isinstance(note, str):
                (marked if about else shown).add(note)
    return frozenset(marked), frozenset(shown)


def hidden_notes(app: Path, configuration: str, beta_notes: Path | None = None) -> frozenset[str]:
    """The strings of the entries about Send feedback in the notes the bundle
    carries (`notes_file`). The table is one for both tracks, so an AppStore
    bundle holds the beta track's strings too, and `beta_notes`, the beta
    track's source file, says which of them are about Send feedback. A string
    that an entry of the bundled notes without the mark uses is shown by that
    entry, whichever track has it marked, so it is never hidden."""
    marked, shown = note_strings(app / notes_file(configuration))
    if configuration == APP_STORE and beta_notes is not None:
        marked |= note_strings(beta_notes)[0]
    return marked - shown


def feedback_strings(app: Path, configuration: str, beta_notes: Path | None = None) -> list[str]:
    """The String Catalog tables of the application that mention Send feedback,
    leaving out the strings of the notes' entries about it (`hidden_notes`) and
    nothing else of the notes' table."""
    found = []
    hidden = hidden_notes(app, configuration, beta_notes)
    for path in sorted(app.glob("*.lproj/*.strings")):
        try:
            with path.open("rb") as handle:
                table = plistlib.load(handle)
        except (OSError, plistlib.InvalidFileException, ValueError):
            continue
        if not isinstance(table, dict):
            continue
        if path.stem == NOTES_TABLE:
            table = {key: value for key, value in table.items() if str(key) not in hidden}
        if any(word in text for key, value in table.items() for text in (str(key), str(value))
               for word in FEEDBACK_WORDS):
            found.append(str(path.relative_to(app)))
    return found


# What the application's decoder (WhatsNewRelease, WhatsNewEntry and
# WhatsNewCatalog in AndariumCore) accepts of a notes file, in the part that a bundle
# can break: the keys of a release and of an entry, what each holds, and a build or
# an entry's id that appears once. A requirement and a date are the application's
# own tests' to read.
RELEASE_KEYS = frozenset({"build", "version", "date", "entries"})
ENTRY_KEYS = frozenset({"id", "title", "text", "points", "symbol", "place", "requirement"})


def release_problem(releases: list) -> str | None:
    """Why the application would not accept this list of releases, or None."""
    def text(value: object) -> bool:
        return isinstance(value, str) and bool(value)

    builds: set[int] = set()
    ids: set[str] = set()
    for release in releases:
        if not isinstance(release, dict) or not set(release) <= RELEASE_KEYS:
            return "a release is not an object with only build, version, date and entries"
        build = release.get("build")
        if isinstance(build, bool) or not isinstance(build, int) or not isinstance(release.get("version"), str):
            return "a release has no build number or version"
        if build in builds:
            return f"build {build} has two releases"
        builds.add(build)
        entries = release.get("entries")
        if not isinstance(entries, list) or not entries:
            return f"the release of build {build} has no entry"
        for entry in entries:
            if not isinstance(entry, dict) or not set(entry) <= ENTRY_KEYS:
                return "an entry is not an object with only the keys the application reads"
            if not (text(entry.get("id")) and text(entry.get("title")) and text(entry.get("symbol"))):
                return "an entry lacks its id, title or symbol"
            points = entry.get("points")
            if "text" in entry and not text(entry["text"]):
                return f"the entry {entry['id']} has an empty text"
            if points is not None and (not isinstance(points, list) or not points
                                       or not all(text(point) for point in points)):
                return f"the entry {entry['id']} has an empty list of points or an empty point"
            if "text" not in entry and points is None:
                return f"the entry {entry['id']} has neither text nor points"
            if entry["id"] in ids:
                return f"the entry {entry['id']} appears twice"
            ids.add(entry["id"])
    return None


def notes_problems(app: Path, configuration: str) -> tuple[list[str], str]:
    """Whether the bundle carries the notes file of its configuration's track at its
    root, and not the other track's or a copy elsewhere, and the line that says which
    it carries. Each file is a list of releases the application accepts (it
    refuses anything else, and shows no notes)."""
    own = notes_file(configuration)
    other = BETA_NOTES_FILE if own == APP_STORE_NOTES_FILE else APP_STORE_NOTES_FILE
    track = "App Store" if own == APP_STORE_NOTES_FILE else "beta"
    problems = []
    try:
        releases = json.loads((app / own).read_text(encoding="utf-8"))
        if not isinstance(releases, list):
            raise ValueError
        why = release_problem(releases)
        if why:
            problems.append(f"{own}: {why}; the application accepts no such release")
    except OSError:
        problems.append(f"{own}: is missing; {configuration} bundles the {track} track of the What's New notes")
    except ValueError:
        problems.append(f"{own}: is not a list of releases; {configuration} bundles the {track} track of the "
                        "What's New notes")
    if (app / other).exists():
        problems.append(f"{other}: is the other track's What's New notes; {configuration} bundles {own} alone")
    for directory, _names, files in os.walk(app):
        for name in sorted(files):
            if name in (BETA_NOTES_FILE, APP_STORE_NOTES_FILE) and Path(directory) != app:
                problems.append(f"{(Path(directory) / name).relative_to(app)}: is a copy of a What's New notes "
                                f"file; {configuration} bundles {own} at the bundle root alone")
    return problems, f"What's New notes are the {track} track ({own})"


# The app icon: DuskJade (Shared/DuskJade.icon) in every configuration but
# TestFlight, which has DuskEmber (Shared/DuskEmber.icon). The build compiles
# the one document its configuration names and leaves the other out.
ICON_JADE = "DuskJade"
ICON_EMBER = "DuskEmber"
# Info.plist's icon blocks, for the iPhone and for the iPad.
ICON_KEYS = ("CFBundleIcons", "CFBundleIcons~ipad")
# The files an icon's name begins: its renditions and its document.
ICON_SUFFIXES = (".png", ".icon", ".icns", ".jpg", ".jpeg", ".heic", ".pdf", ".svg")
# The asset types of an app icon in a compiled catalog (`assetutil --info`).
ICON_ASSET_TYPES = ("Icon Image", "IconImageStack")


def app_icons(configuration: str) -> tuple[str, str]:
    """The icon a configuration compiles, and the other one."""
    return (ICON_EMBER, ICON_JADE) if configuration == TESTFLIGHT else (ICON_JADE, ICON_EMBER)


@functools.lru_cache(maxsize=None)
def catalog_icons(catalog: Path) -> frozenset[str] | None:
    """The app icons a compiled asset catalog holds, by the names of its typed icon
    renditions as the platform's own reader (`assetutil --info`) lists them; None
    if the catalog cannot be read."""
    try:
        done = subprocess.run(
            ["xcrun", "assetutil", "--info", str(catalog)], check=False, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=120)
        entries = json.loads(done.stdout) if done.returncode == 0 else None
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    if not isinstance(entries, list):
        return None
    return frozenset(entry["Name"] for entry in entries
                     if isinstance(entry, dict) and entry.get("AssetType") in ICON_ASSET_TYPES
                     and isinstance(entry.get("Name"), str))


def strings_of(value: object) -> list[str]:
    """Every string of a property list value, nested ones included."""
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        return [text for item in value.values() for text in strings_of(item)]
    if isinstance(value, list):
        return [text for item in value for text in strings_of(item)]
    return []


def icon_problems(app: Path, configuration: str) -> tuple[list[str], str]:
    """Whether the bundle has its configuration's app icon and no other. The icon is
    the primary icon of both Info.plist blocks, which name no other icon, and the one
    app icon of the application's compiled asset catalog, read by its typed
    renditions; no catalog of a nested bundle holds the other icon, and no icon file
    or document of the other icon's name is in the bundle. Text that only mentions
    an icon's name is no icon. The line says which icon the bundle has."""
    own, other = app_icons(configuration)
    problems = []
    try:
        with (app / "Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException, ValueError):
        info = {}
    for key in ICON_KEYS:
        block = info.get(key) if isinstance(info, dict) else None
        primary = block.get("CFBundlePrimaryIcon") if isinstance(block, dict) else None
        named = primary.get("CFBundleIconName") if isinstance(primary, dict) else None
        if named != own:
            problems.append(f"Info.plist: {key} names {named or 'no icon'} as the primary icon; "
                            f"{configuration} has {own}")
        elif any(other.lower() in text.lower() for text in strings_of(block)):
            problems.append(f"Info.plist: {key} names the {other} icon though {configuration} has {own}")
    # What a catalog states is the icon's name: artwork compiled under the other icon's
    # name is not told from it.
    catalogs = bundle_tree(app).catalog_names
    if "Assets.car" not in catalogs:
        problems.append(f"Assets.car: lacks the {own} icon; {configuration} has it")
    for relative in sorted(catalogs):
        icons = catalog_icons(app / relative)
        if icons is None:
            # A nested catalog the platform cannot read draws no icon; the application's must be read.
            if relative == "Assets.car":
                problems.append(f"Assets.car: cannot be read for its app icons; {configuration} has {own}")
        elif relative == "Assets.car":
            if own not in icons:
                problems.append(f"Assets.car: lacks the {own} icon; {configuration} has it")
            for name in sorted(icons - {own}):
                problems.append(f"Assets.car: holds the {name} icon though {configuration} has {own} alone")
        elif other in icons:
            problems.append(f"{relative}: holds the {other} icon though {configuration} has {own}")
    for directory in bundle_tree(app).directories:
        try:
            names = sorted(path for path in directory.iterdir()
                           if path.name.lower().startswith(other.lower()) and path.suffix.lower() in ICON_SUFFIXES)
        except OSError:
            continue
        problems.extend(f"{path.relative_to(app)}: is a file of the {other} icon though {configuration} has {own}"
                        for path in names)
    return problems, f"app icon is {own}"


def feedback_tables(app: Path) -> list[Path]:
    """The Feedback table of any language, found by its file name."""
    return sorted(path for path in app.glob("*.lproj/*")
                  if path.stem == FEEDBACK_TABLE and path.suffix in (".strings", ".stringsdict"))


def feedback_problems(
    app: Path, configuration: str, address: str, receiver: str = "", beta_notes: Path | None = None,
) -> tuple[list[str], bool]:
    """Whether the product holds Send feedback as the build said it would, and
    whether it holds it. `address` is the build setting FEEDBACK_ADDRESS: the
    local configuration's receiver in the App Store configuration, empty
    otherwise, or the example address a test or capture script arranged.
    `receiver` is the local configuration's own receiver, whatever the
    configuration: wherever the build does not name it, no file of the
    bundle holds it. `beta_notes` is the beta track's source file (see
    `hidden_notes`)."""
    problems = feedback_address_problems(configuration, address)
    expected = bool(address) and not problems
    if receiver and (not expected or receiver != address):
        problems.extend(f"{name}: holds the receiver of the local configuration"
                        for name in receiver_leaks(app, receiver))
    fragments: dict[str, set[bytes]] = {}
    for binary in feedback_files(app):
        code = host_code(binary)
        if code is None:
            continue
        # The linker's debug map names the object and source files of the
        # build, which hold the feature's file names though it is compiled
        # out: the check blanks those paths and reads what the code and its
        # symbols hold, among them a symbol that a function stab shares.
        data = without_debug_map(*code, PATH_STABS)
        present = {fragment for fragment in FEEDBACK_FRAGMENTS if fragment in data}
        if present:
            fragments[str(binary.relative_to(app))] = present
    try:
        with (app / "Info.plist").open("rb") as handle:
            keyed = plistlib.load(handle).get(FEEDBACK_KEY)
    except (OSError, plistlib.InvalidFileException, ValueError):
        keyed = None
    words = feedback_strings(app, configuration, beta_notes)
    tables = feedback_tables(app)
    compiled = bool(fragments) or keyed is not None or bool(words) or bool(tables)
    if not expected:
        if address:
            problems.append("Send feedback: the build names a receiver that cannot be used")
        for name, present in fragments.items():
            problems.append(
                f"{name}: carries Send feedback ({', '.join(sorted(item.decode() for item in present))}) "
                "though the build names no receiver")
        if keyed is not None:
            problems.append(f"Info.plist: has {FEEDBACK_KEY} though the build names no receiver")
        problems.extend(f"{name}: has Send feedback strings though the build names no receiver"
                        for name in words)
        problems.extend(f"{path.relative_to(app)}: is the Feedback strings table though the build names no receiver"
                        for path in tables)
        return problems, compiled
    if keyed != address:
        problems.append(f"Info.plist: {FEEDBACK_KEY} must be the receiver the build names")
    code = set().union(*fragments.values()) if fragments else set()
    missing = [item.decode() for item in FEEDBACK_REQUIRED if item not in code]
    if missing:
        problems.append(
            f"the application lacks Send feedback ({', '.join(missing)}) though the build names a receiver")
    absent = [language for language in FEEDBACK_LANGUAGES
              if not (app / f"{language}.lproj" / f"{FEEDBACK_TABLE}.strings").is_file()]
    if absent:
        problems.append(
            f"the application lacks the Feedback strings table in {', '.join(absent)} though the build names a receiver")
    return problems, compiled


# One strict shape of a product identifier, the same rules as
# TipJarProducts.isWellFormed: 1 to 100 letters, digits, `.`, `_` and `-`,
# starting with a letter or digit.
TIP_ID_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,99}")
# Reverse-DNS prefixes that name no developer (RFC 2606's example names).
PLACEHOLDER_PREFIXES = ("com.example.", "org.example.", "net.example.", "example.")


def split_products(text: str) -> dict[str, str]:
    """The four identifiers a build setting list names, in tier order, as
    `lite,pro,max,ultra` with an empty field for one that is not set."""
    fields = text.split(",") if text else []
    fields = (fields + [""] * len(TIP_TIERS))[:len(TIP_TIERS)]
    return dict(zip(TIP_TIERS, fields))


def tip_identifier_problems(configuration: str, products: dict[str, str]) -> list[str]:
    """What is wrong with the identifiers a build names, whatever the product
    holds. The arranged example identifiers are Debug's alone: Release, the
    build that sideloads and forks make, never takes them."""
    named = {tier: value for tier, value in products.items() if value}
    if not named:
        return []
    if configuration == TESTFLIGHT:
        return [f"Buy me tokens: {configuration} names product identifiers; "
                "only the AppStore configuration has Buy me tokens"]
    if configuration != "AppStore":
        if named != TIP_ARRANGED:
            return [f"Buy me tokens: {configuration} names product identifiers that are not the arranged "
                    "example ones; only the AppStore configuration reads the local configuration"]
        if configuration != "Debug":
            return [f"Buy me tokens: {configuration} names the arranged example identifiers; "
                    "only Debug takes the arrangement"]
        return []
    missing = [tier for tier in TIP_TIERS if tier not in named]
    if missing:
        return [f"Buy me tokens: the local configuration names {len(named)} of the four product identifiers "
                f"(none for {', '.join(missing)})"]
    found = []
    for tier in TIP_TIERS:
        value = named[tier]
        if len(value) > 100 or TIP_ID_PATTERN.fullmatch(value) is None:
            found.append(f"Buy me tokens: the {tier} identifier in the local configuration is not a product identifier")
        elif value.lower().startswith(PLACEHOLDER_PREFIXES):
            found.append(f"Buy me tokens: the {tier} identifier in the local configuration is a placeholder")
    if len(set(named.values())) != len(named):
        found.append("Buy me tokens: two tiers name the same product identifier")
    return found


def tip_expected(configuration: str, products: dict[str, str]) -> bool:
    """The build names product identifiers that can be used."""
    return any(products.values()) and not tip_identifier_problems(configuration, products)


def tip_tables(app: Path) -> list[Path]:
    """The TipJar table of any language, anywhere in the bundle, found by its file name."""
    return [path for path in lproj_files(app)
            if path.stem == TIP_TABLE and path.suffix in (".strings", ".stringsdict")]


def tip_strings(app: Path) -> list[str]:
    """The String Catalog tables of the bundle that hold a word of Buy me tokens."""
    found = []
    for path in lproj_files(app, "*.strings"):
        try:
            with path.open("rb") as handle:
                table = plistlib.load(handle)
        except (OSError, plistlib.InvalidFileException, ValueError):
            continue
        if isinstance(table, dict) and any(
                word in text for key, value in table.items() for text in (str(key), str(value))
                for word in TIP_WORDS):
            found.append(str(path.relative_to(app)))
    return found


def tip_problems(
    app: Path, configuration: str, products: dict[str, str], local: dict[str, str] | None = None,
) -> tuple[list[str], bool]:
    """Whether the product holds Buy me tokens as the build said it would, and
    whether it holds it. `products` are the build settings TIP_LITE, TIP_PRO,
    TIP_MAX and TIP_ULTRA: the local configuration's identifiers in the App
    Store configuration, empty otherwise, or the example identifiers a test or
    capture script arranged. `local` is the local configuration's own
    identifiers, whatever the configuration: wherever the build does not name
    them, no file of the bundle holds one. The identifiers are never printed."""
    problems = tip_identifier_problems(configuration, products)
    named = {tier: value for tier, value in products.items() if value}
    expected = bool(named) and not problems
    values = [value for value in (local or {}).values() if value]
    if values and (not expected or any(local.get(tier, "") != products[tier] for tier in TIP_TIERS)):
        problems.extend(f"{name}: holds a product identifier of the local configuration"
                        for name in value_leaks(app, values))
    fragments: dict[str, set[bytes]] = {}
    for binary in feedback_files(app):
        code = host_code(binary)
        if code is None:
            continue
        # The linker's debug map names the object and source files of the
        # build, which hold the feature's file names though it is compiled out
        # (an excluded file is an empty one): the check blanks those paths and
        # reads what the code and its symbols hold.
        data = without_debug_map(*code, PATH_STABS)
        present = {fragment for fragment in TIP_FRAGMENTS if fragment in data}
        if present:
            fragments[str(binary.relative_to(app))] = present
    try:
        with (app / "Info.plist").open("rb") as handle:
            keyed = plistlib.load(handle).get(TIP_KEY)
    except (OSError, plistlib.InvalidFileException, ValueError):
        keyed = None
    tables = tip_tables(app)
    words = tip_strings(app)
    holders = plist_holders(app, TIP_KEY)
    own = {name: present - TIP_SHARED for name, present in fragments.items() if present - TIP_SHARED}
    compiled = bool(own) or bool(holders) or bool(tables) or bool(words)
    if not expected:
        why = absence_reason(configuration, "Buy me tokens", "the build names no product identifiers")
        if named:
            problems.append("Buy me tokens: the build names product identifiers that cannot be used")
        for name, present in own.items():
            problems.append(
                f"{name}: carries Buy me tokens ({', '.join(sorted(item.decode() for item in present))}) "
                f"though {why}")
        problems.extend(f"{path}: has {TIP_KEY} though {why}" for path in holders)
        problems.extend(f"{path.relative_to(app)}: is the TipJar strings table though {why}"
                        for path in tables)
        problems.extend(f"{name}: has Buy me tokens strings though {why}" for name in words)
        return problems, compiled
    if keyed != named:
        problems.append(f"Info.plist: {TIP_KEY} must be the four product identifiers the build names")
    code = set().union(*fragments.values()) if fragments else set()
    missing = [item.decode() for item in TIP_REQUIRED if item not in code]
    if missing:
        problems.append(
            f"the application lacks Buy me tokens ({', '.join(missing)}) though the build names the product identifiers")
    absent = [language for language in FEEDBACK_LANGUAGES
              if not (app / f"{language}.lproj" / f"{TIP_TABLE}.strings").is_file()]
    if absent:
        problems.append(
            f"the application lacks the TipJar strings table in {', '.join(absent)} though the build names the "
            "product identifiers")
    return problems, compiled


def review_identifier_problems(configuration: str, identifier: str) -> list[str]:
    """What is wrong with the identifier a build names, whatever the product
    holds. The arranged placeholder is Debug's alone: Release, the build that
    sideloads and forks make, never takes it."""
    if not identifier:
        return []
    if configuration == TESTFLIGHT:
        return [f"Review on the App Store: {configuration} names an identifier; "
                "only the AppStore configuration has Review on the App Store"]
    if configuration != "AppStore":
        if identifier != REVIEW_ARRANGED:
            return [f"Review on the App Store: {configuration} names an identifier that is not the arranged "
                    "placeholder; only the AppStore configuration reads the local configuration"]
        if configuration != "Debug":
            return [f"Review on the App Store: {configuration} names the arranged placeholder; "
                    "only Debug takes the arrangement"]
        return []
    if re.fullmatch(r"id[0-9]{5,15}", identifier) is None:
        return ["Review on the App Store: the identifier in the local configuration is not an App Store "
                "identifier (id and digits)"]
    if set(identifier[2:]) == {"0"}:
        return ["Review on the App Store: the identifier in the local configuration is a placeholder"]
    return []


def review_tables(app: Path) -> list[Path]:
    """The Review table of any language, anywhere in the bundle, found by its file name."""
    return [path for path in lproj_files(app)
            if path.stem == REVIEW_TABLE and path.suffix in (".strings", ".stringsdict")]


def review_strings(app: Path) -> list[str]:
    """The String Catalog tables of the bundle that hold a word of Review on the App Store."""
    found = []
    for path in lproj_files(app, "*.strings"):
        try:
            with path.open("rb") as handle:
                table = plistlib.load(handle)
        except (OSError, plistlib.InvalidFileException, ValueError):
            continue
        if isinstance(table, dict) and any(
                word in text for key, value in table.items() for text in (str(key), str(value))
                for word in REVIEW_WORDS):
            found.append(str(path.relative_to(app)))
    return found


def review_problems(
    app: Path, configuration: str, identifier: str, local: str = "",
) -> tuple[list[str], bool]:
    """Whether the product holds Review on the App Store as the build said it
    would, and whether it holds it. `identifier` is the build setting
    REVIEW_ID: the local configuration's identifier in the App Store
    configuration, empty otherwise, or the placeholder a test script arranged.
    `local` is the local configuration's own identifier, whatever the
    configuration: wherever the build does not name it, no file of the bundle
    holds its digits. The identifier is never printed."""
    problems = review_identifier_problems(configuration, identifier)
    expected = bool(identifier) and not problems
    if local and (not expected or local != identifier):
        problems.extend(f"{name}: holds the App Store identifier of the local configuration"
                        for name in value_leaks(app, [local[2:] if local.startswith("id") else local]))
    fragments: dict[str, set[bytes]] = {}
    for binary in feedback_files(app):
        code = host_code(binary)
        if code is None:
            continue
        data = without_debug_map(*code, PATH_STABS)
        present = {fragment for fragment in REVIEW_FRAGMENTS if fragment in data}
        if present:
            fragments[str(binary.relative_to(app))] = present
    try:
        with (app / "Info.plist").open("rb") as handle:
            keyed = plistlib.load(handle).get(REVIEW_KEY)
    except (OSError, plistlib.InvalidFileException, ValueError):
        keyed = None
    tables = review_tables(app)
    words = review_strings(app)
    holders = plist_holders(app, REVIEW_KEY)
    compiled = bool(fragments) or bool(holders) or bool(tables) or bool(words)
    if not expected:
        why = absence_reason(configuration, "Review on the App Store", "the build names no App Store identifier")
        if identifier:
            problems.append("Review on the App Store: the build names an identifier that cannot be used")
        for name, present in fragments.items():
            problems.append(
                f"{name}: carries Review on the App Store ({', '.join(sorted(item.decode() for item in present))}) "
                f"though {why}")
        problems.extend(f"{path}: has {REVIEW_KEY} though {why}" for path in holders)
        problems.extend(f"{path.relative_to(app)}: is the Review strings table though {why}"
                        for path in tables)
        problems.extend(f"{name}: has Review on the App Store strings though {why}" for name in words)
        return problems, compiled
    if keyed != identifier:
        problems.append(f"Info.plist: {REVIEW_KEY} must be the App Store identifier the build names")
    code = set().union(*fragments.values()) if fragments else set()
    missing = [item.decode() for item in REVIEW_REQUIRED if item not in code]
    if missing:
        problems.append(
            f"the application lacks Review on the App Store ({', '.join(missing)}) though the build names "
            "an App Store identifier")
    absent = [language for language in FEEDBACK_LANGUAGES
              if not (app / f"{language}.lproj" / f"{REVIEW_TABLE}.strings").is_file()]
    if absent:
        problems.append(
            f"the application lacks the Review strings table in {', '.join(absent)} though the build names "
            "an App Store identifier")
    return problems, compiled


def icp_number_problems(configuration: str, number: str) -> list[str]:
    """What is wrong with the number a build names, whatever the product holds.
    The arranged placeholder is Debug's alone: Release, the build that
    sideloads and forks make, never takes one."""
    if not number:
        return []
    if configuration == TESTFLIGHT:
        return [f"ICP filing number: {configuration} names a number; "
                "only the AppStore configuration has the ICP filing number"]
    if configuration != "AppStore":
        if number != ICP_ARRANGED:
            return [f"ICP filing number: {configuration} names a number that is not the arranged placeholder; "
                    "only the AppStore configuration reads the local configuration"]
        if configuration != "Debug":
            return [f"ICP filing number: {configuration} names the arranged placeholder; "
                    "only Debug takes the arrangement"]
        return []
    if number == ICP_ARRANGED:
        return ["ICP filing number: the number in the local configuration is the placeholder"]
    if len(number) > 100 or re.search(r"[\s/\x00-\x1f\x7f]", number):
        return ["ICP filing number: the number in the local configuration is not one number "
                "(no space, slash or control character, at most 100 characters)"]
    return []


def icp_leaks(app: Path, number: str) -> list[str]:
    """The files of the bundle whose bytes hold the number, as UTF-8 or as the
    UTF-16 a binary property list stores a non-ASCII string in; by path."""
    return value_leaks(app, [number])


def icp_problems(
    app: Path, configuration: str, number: str, local: str = "",
) -> tuple[list[str], bool]:
    """Whether the product holds the ICP filing number as the build said it
    would, and whether it holds it. `number` is the build setting ICP_NUMBER:
    the local configuration's number in the App Store configuration, empty
    otherwise, or the placeholder a test or capture script arranged. `local` is
    the local configuration's own number, whatever the configuration: wherever
    the build does not name it, no file of the bundle holds it. Where the build
    names a number for the App Store, it is in Info.plist and in no other file. The
    number is never printed."""
    problems = icp_number_problems(configuration, number)
    expected = bool(number) and not problems
    if local and (not expected or local != number):
        problems.extend(f"{name}: holds the filing number of the local configuration"
                        for name in icp_leaks(app, local))
    if number != ICP_ARRANGED or not expected:
        problems.extend(f"{name}: holds the placeholder filing number of the arrangement"
                        for name in icp_leaks(app, ICP_ARRANGED))
    fragments: dict[str, set[bytes]] = {}
    for binary in feedback_files(app):
        code = host_code(binary)
        if code is None:
            continue
        data = without_debug_map(*code, PATH_STABS)
        present = {fragment for fragment in ICP_FRAGMENTS if fragment in data}
        if present:
            fragments[str(binary.relative_to(app))] = present
    try:
        with (app / "Info.plist").open("rb") as stream:
            keyed = plistlib.load(stream).get(ICP_KEY)
    except (OSError, plistlib.InvalidFileException, ValueError):
        keyed = None
    holders = plist_holders(app, ICP_KEY)
    compiled = bool(fragments) or bool(holders)
    if not expected:
        why = absence_reason(configuration, "ICP filing number", "the build names no number")
        if number:
            problems.append("ICP filing number: the build names a number that cannot be used")
        for name, present in fragments.items():
            problems.append(
                f"{name}: carries the ICP filing number ({', '.join(sorted(item.decode() for item in present))}) "
                f"though {why}")
        problems.extend(f"{path}: has {ICP_KEY} though {why}" for path in holders)
        return problems, compiled
    if keyed != number:
        problems.append(f"Info.plist: {ICP_KEY} must be the number the build names")
    code = set().union(*fragments.values()) if fragments else set()
    missing = [item.decode() for item in ICP_REQUIRED if item not in code]
    if missing:
        problems.append(
            f"the application lacks the ICP filing number ({', '.join(missing)}) though the build names a number")
    if configuration == "AppStore":
        # (A development build's test bundle holds the arranged placeholder in its tests.)
        problems.extend(f"{name}: holds the filing number outside Info.plist"
                        for name in icp_leaks(app, number) if name != "Info.plist")
    return problems, compiled


def developer_problems(
    app: Path, configuration: str, tip_expected: bool, values: dict[str, str],
    local_github: str = "",
) -> list[str]:
    """Whether the product holds the tip header's developer as the build said
    it would: nothing of it where the build names no product identifiers or no
    value, the Info.plist key of each value the build names, the avatar and the
    GitHub mark in the asset catalog where their values are named and nowhere
    else, no artwork file in the bundle, and no profile address of the local
    GitHub handle in any file. `values` are the build settings
    SHEET_DEVELOPER_NAME, _GITHUB and _X (the local configuration's in the App
    Store configuration, the arranged placeholders for the tests, empty
    otherwise); `local_github` is the local configuration's own GitHub handle.
    The X logo is judged with the row's (`follow_x_problems`). No value is
    printed. Compared by key and asset name: a handle is a part of a bundle
    identifier, so its bytes tell nothing."""
    problems = []
    named = {piece: value for piece, value in values.items() if value}
    usable = tip_expected
    if named and not tip_expected:
        problems.append("Buy me tokens: the build names developer values though "
                        + absence_reason(configuration, "Buy me tokens", "it names no product identifiers"))
    elif named and configuration != "AppStore":
        if any(value != DEVELOPER_ARRANGED[piece] for piece, value in named.items()):
            problems.append(f"Buy me tokens: {configuration} names developer values that are not the arranged "
                            "placeholders; only the App Store configuration reads the local configuration")
            usable = False
        elif configuration != "Debug":
            problems.append(f"Buy me tokens: {configuration} names the arranged developer placeholders; "
                            "only Debug takes the arrangement")
            usable = False
    if configuration == "AppStore":
        # The example file's own values are placeholders for the name and the GitHub handle too.
        for piece in ("name", "github"):
            if named.get(piece, "").strip().lower() == DEVELOPER_ARRANGED[piece]:
                problems.append(f"Buy me tokens: the developer {piece} in the local configuration "
                                "is the placeholder")
        if named.get("github") and GITHUB_HANDLE_PATTERN.fullmatch(named["github"]) is None:
            problems.append("Buy me tokens: the GitHub handle in the local configuration is not a handle of GitHub")
        if named.get("x") and FOLLOW_X_HANDLE_PATTERN.fullmatch(named["x"]) is None:
            problems.append("Buy me tokens: the X handle in the local configuration is not a handle of X")
        elif named.get("x", "").lower() == FOLLOW_X_ARRANGED:
            problems.append("Buy me tokens: the X handle in the local configuration is the placeholder handle")
    try:
        with (app / "Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException, ValueError):
        info = {}
    for piece, key in DEVELOPER_KEYS.items():
        wanted = named.get(piece) if usable else None
        if wanted is None:
            problems.extend(
                f"{path}: has {key} though "
                + absence_reason(configuration, "Buy me tokens", "the build names no such developer value")
                for path in plist_holders(app, key))
        elif info.get(key) != wanted:
            problems.append(f"Info.plist: {key} must be the developer value the build names")

    # The artwork is in the application's asset catalog where its value is named, and in no catalog else.
    for piece, asset in DEVELOPER_ASSETS.items():
        wanted = usable and bool(named.get(piece))
        holders = catalog_holders(app, asset)
        if wanted and "Assets.car" not in holders:
            problems.append(f"Assets.car: lacks {asset.decode()} though the build names the developer's {piece}")
        elif not wanted:
            problems.extend(
                f"{path}: holds {asset.decode()} though "
                + absence_reason(configuration, "Buy me tokens", f"the build names no developer {piece}")
                for path in holders)
    problems.extend(f"{name}: is artwork of the tip header, which belongs in the asset catalog"
                    for name in loose_files(app, DEVELOPER_FILES))

    # No profile address of the local GitHub handle, whatever the build.
    if local_github and local_github != DEVELOPER_ARRANGED["github"]:
        problems.extend(f"{name}: holds a profile address of the local configuration"
                        for name in address_leaks(app, [f"github.com/{local_github}"]))
    return problems


def loose_files(app: Path, names: frozenset[str]) -> list[str]:
    """The artwork files lying in the bundle: the asset catalog is where artwork belongs."""
    return sorted(
        str((Path(directory) / name).relative_to(app))
        for directory, _directories, files in os.walk(app) for name in files if name in names)


def follow_x_handle_problems(configuration: str, handle: str) -> list[str]:
    """What is wrong with the handle a build names, whatever the product holds.
    The arranged placeholder handle is Debug's alone: Release, the build that
    sideloads and forks make, never takes one."""
    if not handle:
        return []
    if not is_store(configuration):
        if handle != FOLLOW_X_ARRANGED:
            return [f"Follow developer on X: {configuration} names a handle that is not the arranged placeholder; "
                    "only the AppStore and TestFlight configurations read the local configuration"]
        if configuration != "Debug":
            return [f"Follow developer on X: {configuration} names the arranged placeholder handle; "
                    "only Debug takes the arrangement"]
        return []
    if FOLLOW_X_HANDLE_PATTERN.fullmatch(handle) is None:
        return ["Follow developer on X: the handle in the local configuration is not a handle of X"]
    if handle.lower() == FOLLOW_X_ARRANGED:
        return ["Follow developer on X: the handle in the local configuration is the placeholder handle"]
    return []


def follow_x_scans(handle: str) -> set[Scan]:
    return (value_scans([f"{host}/{handle}" for host in FOLLOW_X_HOSTS])
            | {Scan(whole=handle.lower())})


def follow_x_leaks(app: Path, handle: str) -> list[str]:
    """The files of the bundle that hold the local configuration's handle as
    a profile address (in either case, in any file), or as the whole of a
    string of a property list or strings table. The bare word is no leak:
    the bundle identifier holds the same one. Named by path, never by the
    handle."""
    return leaks(app, follow_x_scans(handle))


def follow_x_tables(app: Path) -> list[Path]:
    """The FollowX table of any language, found by its file name."""
    return sorted(path for path in app.glob("*.lproj/*")
                  if path.stem == FOLLOW_X_TABLE and path.suffix in (".strings", ".stringsdict"))


def follow_x_words(app: Path) -> list[str]:
    """The String Catalog tables of the application that mention the row."""
    found = []
    for path in sorted(app.glob("*.lproj/*.strings")):
        try:
            with path.open("rb") as handle:
                table = plistlib.load(handle)
        except (OSError, plistlib.InvalidFileException, ValueError):
            continue
        if isinstance(table, dict) and any(
                word in text for key, value in table.items() for text in (str(key), str(value))
                for word in FOLLOW_X_WORDS):
            found.append(str(path.relative_to(app)))
    return found


def follow_x_problems(
    app: Path, configuration: str, handle: str, local_handle: str = "", sheet_handle: str = "",
) -> tuple[list[str], bool]:
    """Whether the product holds Follow developer on X as the build said it
    would, and whether it holds it. `handle` is the build setting
    FOLLOW_X_HANDLE: the local configuration's handle in the App Store
    configuration, empty otherwise, or the placeholder a test or capture
    script arranged. `sheet_handle` is SHEET_DEVELOPER_X, the tip header's X
    handle, which shares the logo and the type that builds the profile's
    address and nothing else of the row (the tip check judges the handle
    itself). `local_handle` is the local configuration's own handle, whatever
    the configuration: wherever the build does not name it, no file of the
    bundle holds its profile address. The arranged placeholder is held to the
    same rule, by its bytes, which only it has: it is in no product that does
    not arrange it."""
    problems = follow_x_handle_problems(configuration, handle)
    expected = bool(handle) and not problems
    named = {value for value in (handle, sheet_handle) if value}
    if local_handle and local_handle not in named:
        problems.extend(f"{name}: holds the handle of the local configuration"
                        for name in follow_x_leaks(app, local_handle))
    if FOLLOW_X_ARRANGED not in named or (not expected and FOLLOW_X_ARRANGED != sheet_handle):
        problems.extend(f"{name}: holds the placeholder handle of the arrangement"
                        for name in receiver_leaks(app, FOLLOW_X_ARRANGED))
    fragments: dict[str, set[bytes]] = {}
    profile: set[str] = set()
    for binary in feedback_files(app):
        code = host_code(binary)
        if code is None:
            continue
        data = without_debug_map(*code, PATH_STABS)
        present = {fragment for fragment in FOLLOW_X_FRAGMENTS if fragment in data}
        if present:
            fragments[str(binary.relative_to(app))] = present
        if FOLLOW_X_PROFILE in data:
            profile.add(str(binary.relative_to(app)))
    try:
        with (app / "Info.plist").open("rb") as stream:
            keyed = plistlib.load(stream).get(FOLLOW_X_KEY)
    except (OSError, plistlib.InvalidFileException, ValueError):
        keyed = None
    words = follow_x_words(app)
    tables = follow_x_tables(app)
    logo_holders = catalog_holders(app, FOLLOW_X_ASSET)
    logo = "Assets.car" in logo_holders
    compiled = bool(fragments) or keyed is not None or bool(words) or bool(tables)
    mark = expected or bool(sheet_handle)
    problems.extend(f"{name}: is artwork of the row, which belongs in the asset catalog"
                    for name in loose_files(app, FOLLOW_X_FILES))
    if not mark:
        compiled = compiled or bool(logo_holders) or bool(profile)
        problems.extend(f"{name}: carries the profile address's builder of Follow developer on X though the "
                        "build names no handle" for name in sorted(profile))
        problems.extend(f"{path}: holds the logo of Follow developer on X though the build names no handle"
                        for path in logo_holders)
    elif not logo:
        problems.append("Assets.car: lacks the logo of Follow developer on X though the build names a handle")
    if mark and not profile:
        problems.append("the application lacks the profile address's builder of Follow developer on X "
                        "though the build names a handle")
    if not expected:
        if handle:
            problems.append("Follow developer on X: the build names a handle that cannot be used")
        for name, present in fragments.items():
            problems.append(
                f"{name}: carries Follow developer on X ({', '.join(sorted(item.decode() for item in present))}) "
                "though the build names no handle")
        if keyed is not None:
            problems.append(f"Info.plist: has {FOLLOW_X_KEY} though the build names no handle")
        problems.extend(f"{name}: has Follow developer on X strings though the build names no handle"
                        for name in words)
        problems.extend(f"{path.relative_to(app)}: is the FollowX strings table though the build names no handle"
                        for path in tables)
        return problems, compiled or (logo and bool(handle))
    if keyed != handle:
        problems.append(f"Info.plist: {FOLLOW_X_KEY} must be the handle the build names")
    code = set().union(*fragments.values()) if fragments else set()
    missing = [item.decode() for item in FOLLOW_X_REQUIRED if item not in code]
    if missing:
        problems.append(
            f"the application lacks Follow developer on X ({', '.join(missing)}) though the build names a handle")
    absent = [language for language in FEEDBACK_LANGUAGES
              if not (app / f"{language}.lproj" / f"{FOLLOW_X_TABLE}.strings").is_file()]
    if absent:
        problems.append(
            f"the application lacks the FollowX strings table in {', '.join(absent)} though the build names a handle")
    return problems, compiled


def planned_scans(options: argparse.Namespace) -> set[Scan]:
    """Every leak question the checks this run makes can ask, so that one walk
    answers them. The checks decide which they ask; a question this list lacks
    is walked for itself, so a drift costs a walk and never an answer."""
    if options.runtime or options.host_traces:
        return set()
    if options.pickers and not (options.feedback or options.follow_x or options.icp):
        return set()
    if options.feedback or options.follow_x or options.icp:
        feedback, follow_x, icp, tip, review = options.feedback, options.follow_x, options.icp, False, False
    elif options.tip_jar:
        feedback = follow_x = icp = review = False
        tip = True
    elif options.review:
        feedback = follow_x = icp = tip = False
        review = True
    else:
        feedback = follow_x = icp = tip = review = True
    scans: set[Scan] = set()
    if feedback:
        scans |= value_scans([options.feedback_receiver])
    if follow_x:
        scans |= value_scans([FOLLOW_X_ARRANGED])
        if options.developer_x_handle:
            scans |= follow_x_scans(options.developer_x_handle)
    if icp:
        scans |= value_scans([ICP_ARRANGED, options.icp_local_number])
        if options.configuration == "AppStore":
            scans |= value_scans([options.icp_number])
    if tip:
        scans |= value_scans(list(split_products(options.tip_local_products).values()))
        if options.developer_local_github:
            scans |= address_scans([f"github.com/{options.developer_local_github}"])
    if review:
        local = options.review_local_id
        scans |= value_scans([local[2:] if local.startswith("id") else local])
    return scans


def picker_problems(app: Path, configuration: str) -> list[str]:
    """Whether the product's document pickers are the configuration's. The App
    Store configuration opens files in place: it refers to both importers and
    holds none of the copy-mode presenter. Every other configuration holds the
    presenter, which is what shows the scan can find it."""
    copy: set[bytes] = set()
    in_place: set[str] = set()
    for binary in feedback_files(app):
        code = host_code(binary)
        if code is None:
            continue
        data = without_debug_map(*code, PATH_STABS)
        copy.update(fragment for fragment in PICKER_COPY if fragment in data)
        in_place.update(name for name, fragment in PICKER_IN_PLACE.items() if fragment in data)
    if not is_store(configuration):
        if copy:
            return []
        return [f"the application lacks the copy-mode document picker ({configuration} copies the files "
                "the pickers hand over)"]
    problems = []
    if copy:
        problems.append(
            "the application carries the copy-mode document picker "
            f"({', '.join(sorted(item.decode() for item in copy))}); the {configuration} configuration opens files in place")
    problems.extend(
        f"the application lacks {name}: the {configuration} configuration opens files in place"
        for name in PICKER_IN_PLACE if name not in in_place)
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("app", type=Path)
    parser.add_argument("--privacy-checker", type=Path, default=CHECKER)
    parser.add_argument(
        "--configuration", default="AppStore",
        help="the build configuration: AppStore, TestFlight (which has none of Buy me tokens, Review on the "
             "App Store and the ICP filing number), or another, whose features the options below check")
    parser.add_argument(
        "--feedback-address", default="",
        help="the build setting FEEDBACK_ADDRESS: the receiver the build names, "
             "empty when it names none")
    parser.add_argument(
        "--feedback-receiver", default="",
        help="the build setting FEEDBACK_RECEIVER: the local configuration's receiver, "
             "which no file of a bundle that does not name it may hold")
    parser.add_argument(
        "--info-source", type=Path, default=None,
        help="Config/Info.plist, whose values the built Info.plist keeps")
    parser.add_argument(
        "--beta-notes", type=Path, default=None,
        help="Shared/WhatsNew.json, the beta track's notes, whose entries about Send feedback an AppStore "
             "bundle's notes table may still hold")
    parser.add_argument(
        "--follow-x-handle", default="",
        help="the build setting FOLLOW_X_HANDLE: the handle the build names, "
             "empty when it names none")
    parser.add_argument(
        "--developer-x-handle", default="",
        help="the build setting DEVELOPER_X_HANDLE: the local configuration's handle, "
             "whose profile address no file of a bundle that does not name it may hold")
    parser.add_argument(
        "--icp-number", default="",
        help="the build setting ICP_NUMBER: the filing number the build names, empty when it names none")
    parser.add_argument(
        "--icp-local-number", default="",
        help="the build setting DEVELOPER_ICP_NUMBER: the local configuration's number, which no file "
             "of a bundle that does not name it may hold")
    parser.add_argument(
        "--feedback", action="store_true",
        help="check Send feedback alone, for a configuration other than AppStore")
    parser.add_argument(
        "--follow-x", action="store_true",
        help="check Follow developer on X alone, for a configuration other than AppStore "
             "(with --feedback, the two)")
    parser.add_argument(
        "--icp", action="store_true",
        help="check the ICP filing number alone, for a configuration other than AppStore "
             "(with the options above, those too)")
    parser.add_argument(
        "--tip-products", default="",
        help="the build settings TIP_LITE, TIP_PRO, TIP_MAX and TIP_ULTRA, comma separated in that "
             "order: the product identifiers the build names, empty when it names none")
    parser.add_argument(
        "--tip-local-products", default="",
        help="the build settings TIP_PRODUCT_LITE, TIP_PRODUCT_PRO, TIP_PRODUCT_MAX and TIP_PRODUCT_ULTRA, "
             "the local configuration's own identifiers, which no file of a bundle that does not name "
             "them may hold")
    parser.add_argument(
        "--tip-jar", action="store_true",
        help="check Buy me tokens alone, for a configuration other than AppStore")
    parser.add_argument(
        "--review-id", default="",
        help="the build setting REVIEW_ID: the App Store identifier the build names, "
             "empty when it names none")
    parser.add_argument(
        "--review-local-id", default="",
        help="the build setting REVIEW_APP_ID: the local configuration's own identifier, "
             "whose digits no file of a bundle that does not name it may hold")
    parser.add_argument(
        "--review", action="store_true",
        help="check Review on the App Store alone, for a configuration other than AppStore")
    parser.add_argument(
        "--developer-name", default="",
        help="the build setting SHEET_DEVELOPER_NAME: the developer's name the tip header shows, empty when none")
    parser.add_argument(
        "--developer-github", default="",
        help="the build setting SHEET_DEVELOPER_GITHUB: the GitHub handle of the tip header, empty when none")
    parser.add_argument(
        "--developer-x", default="",
        help="the build setting SHEET_DEVELOPER_X: the X handle of the tip header, empty when none "
             "(the X logo and the profile address's builder are Follow developer on X's to judge)")
    parser.add_argument(
        "--developer-local-github", default="",
        help="the build setting DEVELOPER_GITHUB_HANDLE: the local configuration's own GitHub handle, "
             "whose profile address no file may hold")
    parser.add_argument(
        "--pickers", action="store_true",
        help="check the document pickers alone, for a configuration other than AppStore: "
             "the product holds the copy-mode presenter")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--runtime", action="store_true",
        help="the path is one runtime framework: check its automation knobs, "
             "its debugging support and the traces of its build host")
    mode.add_argument(
        "--host-traces", action="store_true",
        help="the path is one framework: check the traces of its build host alone")
    options = parser.parse_args()
    global _SENSITIVE
    _SENSITIVE = sensitive_pattern(options)
    with one_walk(options.app, planned_scans(options)):
        return check(options)


def check(options: argparse.Namespace) -> int:
    app = options.app
    products = split_products(options.tip_products)
    developer = {"name": options.developer_name, "github": options.developer_github, "x": options.developer_x}

    def developer_found() -> list[str]:
        return developer_problems(
            app, options.configuration, tip_expected(options.configuration, products), developer,
            options.developer_local_github)

    if options.feedback or options.follow_x or options.icp or options.pickers:
        found = []
        if options.info_source is not None:
            found.extend(info_source_problems(app, options.info_source))
        lines = []
        if options.feedback:
            more, compiled = feedback_problems(
                app, options.configuration, options.feedback_address, options.feedback_receiver,
                options.beta_notes)
            found.extend(more)
            lines.append(f"{app.name}: Send feedback is {'compiled in' if compiled else 'not compiled in'}"
                         f" ({options.configuration})")
        if options.follow_x:
            more, compiled = follow_x_problems(
                app, options.configuration, options.follow_x_handle, options.developer_x_handle,
                options.developer_x)
            found.extend(more)
            lines.append(f"{app.name}: Follow developer on X is {'compiled in' if compiled else 'not compiled in'}"
                         f" ({options.configuration})")
        if options.icp:
            more, compiled = icp_problems(app, options.configuration, options.icp_number, options.icp_local_number)
            found.extend(more)
            lines.append(f"{app.name}: ICP filing number is {'compiled in' if compiled else 'not compiled in'}"
                         f" ({options.configuration})")
        if options.pickers:
            more = picker_problems(app, options.configuration)
            found.extend(more)
            if not more:
                lines.append(f"{app.name}: document pickers copy the files ({options.configuration})")
        for line in found:
            emit(line, error=True)
        for line in lines:
            emit(line)
        return 1 if found else 0
    if options.tip_jar:
        found, compiled = tip_problems(
            app, options.configuration, products, split_products(options.tip_local_products))
        found.extend(developer_found())
        for line in found:
            emit(line, error=True)
        emit(f"{app.name}: Buy me tokens is {'compiled in' if compiled else 'not compiled in'}"
              f" ({options.configuration})")
        return 1 if found else 0
    if options.review:
        found, compiled = review_problems(
            app, options.configuration, options.review_id, options.review_local_id)
        for line in found:
            emit(line, error=True)
        emit(f"{app.name}: Review on the App Store is {'compiled in' if compiled else 'not compiled in'}"
              f" ({options.configuration})")
        return 1 if found else 0
    if options.runtime or options.host_traces:
        found = []
        for binary in executables_of(app):
            if options.runtime:
                found.extend(f"{binary.name}: carries automation knob {name}" for name in knobs(binary))
                found.extend(f"{binary.name}: carries debugging support: {item}"
                             for item in debug_support(binary))
            found.extend(f"{binary.name}: {trace}" for trace in build_host_traces(binary))
        for line in found:
            emit(line, error=True)
        return 1 if found else 0
    problems: list[str] = []
    try:
        with (app / "Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException, ValueError):
        emit(f"{app}: has no readable Info.plist", error=True)
        return 1
    problems.extend(f"{app.name}: {problem}" for problem in info_problems(info))

    for binary in executables(app):
        names = knobs(binary)
        if names:
            problems.append(
                f"{binary.relative_to(app)}: carries automation knob(s) "
                f"{', '.join(names[:6])}{' ...' if len(names) > 6 else ''}")
        lines = harness_lines(binary)
        if lines:
            problems.append(
                f"{binary.relative_to(app)}: carries the harness's console line(s) "
                f"{', '.join(repr(line) for line in lines)}")
        problems.extend(
            f"{binary.relative_to(app)}: carries debugging support: {item}"
            for item in debug_support(binary))
        # The application's own executable is stripped when Xcode archives it.
        problems.extend(
            f"{binary.relative_to(app)}: {trace}"
            for trace in build_host_traces(binary, debug_map=binary.parent != app))

    problems.extend(f"{app.name}: {text}" for text in localized_jit_text(app))

    problems.extend(
        f"{path}: a test bundle or test framework; build the application "
        "without its tests" for path in test_support(app))

    if options.info_source is not None:
        problems.extend(info_source_problems(app, options.info_source))
    feedback, compiled = feedback_problems(
        app, options.configuration, options.feedback_address, options.feedback_receiver, options.beta_notes)
    problems.extend(feedback)
    emit(f"{app.name}: Send feedback is {'compiled in' if compiled else 'not compiled in'}")
    notes, bundled = notes_problems(app, options.configuration)
    problems.extend(f"{app.name}: {problem}" for problem in notes)
    if not notes:
        emit(f"{app.name}: {bundled}")
    icon, icon_line = icon_problems(app, options.configuration)
    problems.extend(f"{app.name}: {problem}" for problem in icon)
    if not icon:
        emit(f"{app.name}: {icon_line}")
    follow, compiled = follow_x_problems(
        app, options.configuration, options.follow_x_handle, options.developer_x_handle, options.developer_x)
    problems.extend(follow)
    emit(f"{app.name}: Follow developer on X is {'compiled in' if compiled else 'not compiled in'}")
    pickers = picker_problems(app, options.configuration)
    problems.extend(pickers)
    if not pickers:
        emit(f"{app.name}: document pickers open the files in place")

    tip, tip_compiled = tip_problems(
        app, options.configuration, products, split_products(options.tip_local_products))
    problems.extend(tip)
    problems.extend(developer_found())
    emit(f"{app.name}: Buy me tokens is {'compiled in' if tip_compiled else 'not compiled in'}")

    review, review_compiled = review_problems(
        app, options.configuration, options.review_id, options.review_local_id)
    problems.extend(review)
    emit(f"{app.name}: Review on the App Store is {'compiled in' if review_compiled else 'not compiled in'}")

    icp, icp_compiled = icp_problems(app, options.configuration, options.icp_number, options.icp_local_number)
    problems.extend(icp)
    emit(f"{app.name}: ICP filing number is {'compiled in' if icp_compiled else 'not compiled in'}")

    privacy = subprocess.run(
        [sys.executable, "-B", str(options.privacy_checker), str(app)],
        check=False, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, timeout=600)
    if privacy.returncode != 0:
        problems.extend(line for line in privacy.stderr.splitlines() if line)

    for problem in problems:
        emit(problem, error=True)
    if problems:
        return 1
    emit(f"{app.name}: ready for {'TestFlight' if options.configuration == TESTFLIGHT else 'the App Store'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
