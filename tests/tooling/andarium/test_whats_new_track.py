#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Check that each configuration of Andarium reads its own track of What's New notes
and compiles its own app icon.

A build bundles one of two notes files (Andarium/README.md#whats-new): the beta
track's WhatsNew.json in Debug, Release and TestFlight, the App Store track's
WhatsNewAppStore.json in AppStore. The build setting WHATS_NEW_TRACK
(Config/Andarium.xcconfig) leaves the other file out of the bundle and defines
the compilation condition that picks the file `WhatsNewTrack.bundled` reads.
The bundle check sees the bundled files, not the executable, so this is the
check of the connection between them: it resolves the target's build settings
with xcodebuild for each configuration, compiles the loader's own source
(Shared/WhatsNewModel.swift, from WhatsNewTrack to the end of the file) with the
resolved WHATS_NEW_TRACK_* conditions, and runs the default loader against a
bundle that holds a different, non-empty list in each track's file. It fails
when a configuration reads the other track, when the condition is not defined
from the setting, and when a value that names neither track still compiles.
The decoder is the one thing stood in for (a release is its build number): the
application's own tests decode the shipped files.

The same resolved settings carry the app icon (README.md#configurations):
APP_ICON_NAME is DuskJade in every configuration but TestFlight, which has
DuskEmber; the target compiles it (ASSETCATALOG_COMPILER_APPICON_NAME), leaves the
other document out of the build and includes no other app icon asset. The
AndariumPreview target keeps DuskJade throughout. The bundle check sees the
built bundle's icon; this binds the settings that produce it.
"""

from __future__ import annotations

__import__("sys").dont_write_bytecode = True

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

LOADER = Path("Andarium/Andarium/Shared/WhatsNewModel.swift")
PROJECT = Path("Andarium/Andarium.xcodeproj")
BETA_FILE = "WhatsNew.json"
APP_STORE_FILE = "WhatsNewAppStore.json"
# The builds of the fixture's lists, so that a read says which file it was.
BETA_BUILD = 13
APP_STORE_BUILD = 14
ICON_JADE = "DuskJade"
ICON_EMBER = "DuskEmber"

# The start of what the probe compiles from the loader's source: the track's
# declaration, then everything after it (the track, the loader).
LOADER_START = "nonisolated enum WhatsNewTrack"

# The decoder's part of the probe: a release is its build number.
PROBE = """\
import Foundation

struct WhatsNewRelease { let build: Int }

enum WhatsNewCatalog {
    static func decode(_ data: Data) throws -> [WhatsNewRelease] {
        let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return rows.compactMap { ($0["build"] as? Int).map { WhatsNewRelease(build: $0) } }
    }
}

{loader}

@main
enum Probe {
    static func main() {
        guard CommandLine.arguments.count == 2, let bundle = Bundle(path: CommandLine.arguments[1]) else {
            print("no bundle")
            return
        }
        print(WhatsNewCatalog.load(from: bundle).map(\\.build))
    }
}
"""

# Each configuration of the target, the track it reads, and the file the build
# leaves out of the bundle.
CONFIGURATIONS = (
    ("Debug", BETA_BUILD, APP_STORE_FILE),
    ("Release", BETA_BUILD, APP_STORE_FILE),
    ("TestFlight", BETA_BUILD, APP_STORE_FILE),
    ("AppStore", APP_STORE_BUILD, BETA_FILE),
)


def run(command: list[str], timeout: int = 90) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=timeout)


def settings(root: Path, configuration: str, *overrides: str) -> dict[str, str]:
    """The resolved build settings of the Andarium target in a configuration."""
    done = run(["xcrun", "xcodebuild", "-project", str(root / PROJECT), "-target", "Andarium",
                "-configuration", configuration, "-showBuildSettings", "-json", *overrides])
    if done.returncode != 0:
        raise SystemExit(f"{configuration}: xcodebuild -showBuildSettings failed:\n{done.stderr}")
    return json.loads(done.stdout)[0]["buildSettings"]


def target_settings(root: Path, configuration: str) -> dict[str, dict[str, str]]:
    """The resolved build settings of every target in a configuration, by target."""
    done = run(["xcrun", "xcodebuild", "-project", str(root / PROJECT), "-alltargets",
                "-configuration", configuration, "-showBuildSettings", "-json"])
    if done.returncode != 0:
        raise SystemExit(f"{configuration}: xcodebuild -showBuildSettings failed:\n{done.stderr}")
    return {item["target"]: item["buildSettings"] for item in json.loads(done.stdout)}


def icon_problems(configuration: str, target: str, resolved: dict[str, str], icon: str) -> list[str]:
    """What differs in a target's resolved settings from compiling `icon` alone."""
    other = ICON_EMBER if icon == ICON_JADE else ICON_JADE
    where = f"{configuration} {target}"
    excluded = resolved.get("EXCLUDED_SOURCE_FILE_NAMES", "").split()
    found = []
    for setting in ("APP_ICON_NAME", "ASSETCATALOG_COMPILER_APPICON_NAME"):
        if resolved.get(setting) != icon:
            found.append(f"{where}: {setting} is {resolved.get(setting)}, not {icon}")
    if f"{other}.icon" not in excluded or f"{icon}.icon" in excluded:
        found.append(f"{where}: does not leave {other}.icon alone out of the build")
    if resolved.get("ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS") != "NO":
        found.append(f"{where}: includes app icon assets besides {icon}")
    return found


def conditions(resolved: dict[str, str]) -> list[str]:
    """The notes track conditions among the resolved compilation conditions."""
    return [word for word in resolved.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "").split()
            if word.startswith("WHATS_NEW_TRACK_")]


def compile_probe(work: Path, loader: str, defined: list[str]) -> tuple[Path | None, str]:
    """Compiles the probe with the loader's source under `defined`; the program, or why not."""
    name = "-".join(defined) or "none"
    source = work / f"probe-{name}.swift"
    source.write_text(PROBE.replace("{loader}", loader), encoding="utf-8")
    program = work / f"probe-{name}"
    sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).stdout.strip()
    done = run(["xcrun", "swiftc", "-parse-as-library", "-sdk", sdk, "-target", "arm64-apple-macos14.0",
                "-module-cache-path", str(work / "modules"), *[f"-D{word}" for word in defined],
                str(source), "-o", str(program)], timeout=180)
    return (program if done.returncode == 0 else None), done.stdout + done.stderr


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[3])
    root = parser.parse_args().root
    text = (root / LOADER).read_text(encoding="utf-8")
    if LOADER_START not in text:
        print(f"{LOADER}: no longer declares WhatsNewTrack; adapt this test")
        return 1
    loader = text[text.index(LOADER_START):]
    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="andarium-notes-track-") as directory:
        work = Path(directory)
        fixture = work / "Fixture.bundle"
        fixture.mkdir()
        for name, build in ((BETA_FILE, BETA_BUILD), (APP_STORE_FILE, APP_STORE_BUILD)):
            (fixture / name).write_text(json.dumps([{"build": build, "version": f"1.0 ({build})", "entries": []}]),
                                        encoding="utf-8")
        programs: dict[tuple[str, ...], tuple[Path | None, str]] = {}

        def read(defined: list[str]) -> tuple[list[int] | None, str]:
            """The builds the default loader reads under `defined`, or None and why not."""
            key = tuple(defined)
            if key not in programs:
                programs[key] = compile_probe(work, loader, defined)
            program, why = programs[key]
            if program is None:
                return None, why
            done = run([str(program), str(fixture)], timeout=30)
            return (json.loads(done.stdout) if done.returncode == 0 else None), done.stdout + done.stderr

        for configuration, build, absent in CONFIGURATIONS:
            targets = target_settings(root, configuration)
            resolved = targets["Andarium"]
            defined = conditions(resolved)
            icon = ICON_EMBER if configuration == "TestFlight" else ICON_JADE
            failures += icon_problems(configuration, "Andarium", resolved, icon)
            failures += icon_problems(configuration, "AndariumPreview", targets["AndariumPreview"], ICON_JADE)
            if absent not in resolved.get("EXCLUDED_SOURCE_FILE_NAMES", "").split():
                failures.append(f"{configuration}: does not leave {absent} out of the bundle")
            builds, why = read(defined)
            if builds != [build]:
                failures.append(f"{configuration}: conditions {defined or 'none'} read {builds}, not [{build}]"
                                + (f":\n{why}" if builds is None else ""))
        # A value that names neither track is no track: the build stops rather than read one.
        resolved = settings(root, "Debug", "WHATS_NEW_TRACK=NIGHTLY")
        defined = conditions(resolved)
        builds, why = read(defined)
        if builds is not None or "WHATS_NEW_TRACK" not in why:
            failures.append(f"WHATS_NEW_TRACK=NIGHTLY: conditions {defined} read {builds} and do not stop the compile")
    for failure in failures:
        print(failure, file=sys.stderr)
    if failures:
        return 1
    print("every configuration reads its own track of What's New notes and compiles its own app icon")
    return 0


if __name__ == "__main__":
    sys.exit(main())
