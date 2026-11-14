#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Recognise the prebuilt inputs of the Andarium IPA build and put each where the build reads it.

The trees .github/ci/fetch-prebuilt.sh unpacked are searched, however they are
laid out, for:

  kernel        the accepted Android kernel bundle (a directory holding
                kernel-artifact.json with family android-6.18, slice arm64)
                -> .build/kernel/artifacts/<its name>
  android       the LineageOS release (release-manifest.json and
                guest/system.img, which may also come compressed as
                system.img.zst/.xz/.gz) -> .build/android/releases/<its name>
  xcframeworks  an already packaged .build/kernarium-xcframeworks (it holds
                KRuntime_Android_6_18_4K.xcframework): the runtime then need
                not be built -> .build/kernarium-xcframeworks
  gpu           the iOS device GPU prefix (ios-device-arm64 with
                Frameworks/MesaEGL.framework)
                -> .build/dependencies/apple-gpu-vulkan-experiment/ios-device-arm64
  network       the iOS device network prefix (ios-device-arm64/network)
                -> .build/dependencies/ios-device-arm64/network
  storage       the ios-storage prefix (GPTFDisk.xcframework beside
                share/uml-dependencies) -> .build/dependencies/ios-storage
  zstd          the ios-zstd prefix (LibZstd.xcframework beside
                share/uml-dependencies) -> .build/dependencies/ios-zstd

A dependency prefix must be whole (its share/uml-dependencies provenance
included), since the build verifies it against this commit's manifest; the
workflow rebuilds from source any prefix that is missing or fails that check.

Anything else is ignored. The result is printed, and written as step outputs
to $GITHUB_OUTPUT when it is set: kernel_dir, android_dir (paths or empty)
and xcframeworks, gpu, network, storage, zstd (true/false).
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True

COMPRESSED_SUFFIXES = {".zst": ["zstd", "-d", "--long=31", "-q", "-f"], ".xz": ["xz", "-d", "-f"], ".gz": ["gzip", "-d", "-f"]}


def read_json(path: Path) -> dict | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def read_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip("'\"")
    return values


def is_kernel(directory: Path) -> bool:
    manifest = read_json(directory / "kernel-artifact.json")
    return bool(manifest) and manifest.get("family") == "android-6.18" and manifest.get("slice") == "arm64"


def is_android_release(directory: Path) -> bool:
    manifest = read_json(directory / "release-manifest.json")
    if not manifest or not str(manifest.get("product_family", "")).startswith("lineage-"):
        return False
    guest = directory / "guest"
    return (guest / "system.img").is_file() or any((guest / f"system.img{suffix}").is_file() for suffix in COMPRESSED_SUFFIXES)


def is_xcframeworks(directory: Path) -> bool:
    return (directory / "KRuntime_Android_6_18_4K.xcframework").is_dir()


def is_gpu(directory: Path) -> bool:
    return directory.name == "ios-device-arm64" and (directory / "Frameworks/MesaEGL.framework").is_dir()


def is_network(directory: Path) -> bool:
    return directory.name == "network" and directory.parent.name == "ios-device-arm64" and (directory / "lib").is_dir()


def is_storage(directory: Path) -> bool:
    return (directory / "GPTFDisk.xcframework").is_dir() and (directory / "share/uml-dependencies").is_dir()


def is_zstd(directory: Path) -> bool:
    return (directory / "LibZstd.xcframework").is_dir() and (directory / "share/uml-dependencies").is_dir()


KINDS = (
    ("xcframeworks", is_xcframeworks),
    ("kernel", is_kernel),
    ("android", is_android_release),
    ("gpu", is_gpu),
    ("network", is_network),
    ("storage", is_storage),
    ("zstd", is_zstd),
)


def scan(roots: list[Path]) -> dict[str, list[Path]]:
    found: dict[str, list[Path]] = {kind: [] for kind, _ in KINDS}
    for root in roots:
        for current, directories, _files in os.walk(root, followlinks=True):
            here = Path(current)
            matched = False
            for kind, test in KINDS:
                if test(here):
                    found[kind].append(here)
                    matched = True
                    break
            if matched:
                directories[:] = []
            else:
                directories[:] = [d for d in directories if d not in (".git", "__MACOSX")]
    return found


def choose(kind: str, candidates: list[Path], preferred_name: str | None) -> Path | None:
    if not candidates:
        return None
    if preferred_name:
        for candidate in candidates:
            if candidate.name == preferred_name:
                return candidate
    if len(candidates) > 1:
        print(f"place-prebuilt: several {kind} candidates, using {candidates[0]}: {', '.join(map(str, candidates))}", file=sys.stderr)
    return candidates[0]


def put(source: Path, destination: Path) -> Path:
    source = source.resolve()
    if destination.is_symlink() or destination.is_file():
        destination.unlink()
    elif destination.exists():
        shutil.rmtree(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(source), str(destination))
    print(f"place-prebuilt: {source} -> {destination}")
    return destination


def decompress_system_image(release: Path) -> None:
    image = release / "guest/system.img"
    if image.is_file():
        return
    for suffix, command in COMPRESSED_SUFFIXES.items():
        packed = release / f"guest/system.img{suffix}"
        if packed.is_file():
            print(f"place-prebuilt: decompressing {packed}")
            subprocess.run([*command, str(packed)], check=True)
            if packed.exists():
                packed.unlink()
            return


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, required=True, help="the source checkout")
    parser.add_argument("trees", type=Path, nargs="*", help="unpacked prebuilt trees")
    arguments = parser.parse_args()
    root = arguments.root.resolve()
    build = root / ".build"

    kernel_accepted = read_env(root / "kernel/mainline-6.18/artifacts/accepted-android-4k.env")
    android_accepted = read_env(root / "android/lineage-24/metadata/accepted-release.env")

    found = scan([tree for tree in arguments.trees if tree.exists()])
    result: dict[str, str] = {}

    kernel = choose("kernel", found["kernel"], kernel_accepted.get("UML_KERNEL_ARTIFACT_DIRECTORY_NAME"))
    result["kernel_dir"] = str(put(kernel, build / "kernel/artifacts" / kernel.name)) if kernel else ""

    android = choose("android", found["android"], android_accepted.get("LINEAGE24_ACCEPTED_DIRECTORY_NAME"))
    if android:
        name = android.name
        if name in ("andarium-system", "tree") or name.isdigit():
            name = android_accepted.get("LINEAGE24_ACCEPTED_DIRECTORY_NAME", name)
        placed = put(android, build / "android/releases" / name)
        decompress_system_image(placed)
        result["android_dir"] = str(placed)
    else:
        result["android_dir"] = ""

    xcframeworks = choose("xcframeworks", found["xcframeworks"], "kernarium-xcframeworks")
    if xcframeworks:
        put(xcframeworks, build / "kernarium-xcframeworks")
    result["xcframeworks"] = "true" if xcframeworks else "false"

    gpu = choose("gpu", found["gpu"], None)
    if gpu:
        put(gpu, build / "dependencies/apple-gpu-vulkan-experiment/ios-device-arm64")
    result["gpu"] = "true" if gpu else "false"

    network = choose("network", found["network"], None)
    if network:
        put(network, build / "dependencies/ios-device-arm64/network")
    result["network"] = "true" if network else "false"

    for kind, prefix in (("storage", "ios-storage"), ("zstd", "ios-zstd")):
        placed_prefix = choose(kind, found[kind], prefix)
        if placed_prefix:
            put(placed_prefix, build / "dependencies" / prefix)
        result[kind] = "true" if placed_prefix else "false"

    for key, value in result.items():
        print(f"place-prebuilt: {key}={value}")
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            for key, value in result.items():
                handle.write(f"{key}={value}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
