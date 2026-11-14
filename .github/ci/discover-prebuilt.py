#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Find this commit's accepted kernel bundle and Android release among a repository's GitHub releases.

Usage: discover-prebuilt.py --root CHECKOUT --repo OWNER/REPO

Reads the release list with `gh api` (GH_TOKEN) and prints, one per line, the
`gh-release:OWNER/REPO@TAG/ASSET` sources .github/ci/fetch-prebuilt.sh takes.
An asset is chosen when its name, or its release's tag or title, carries the
accepted kernel or Android release ID / directory name
(kernel/mainline-6.18/artifacts/accepted-android-4k.env,
android/lineage-24/metadata/accepted-release.env). Applications (.ipa,
.tipa), checksums and signatures are never chosen. Prints nothing when nothing
matches; the reasons go to stderr.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True

SKIP = re.compile(r"\.(ipa|tipa|sha256|sha512|sig|asc|minisig|txt|md|json)$", re.IGNORECASE)
SPLIT_PART = re.compile(r"^(.+)\.(\d{3}|part[-_]?[a-z0-9]{1,3})$", re.IGNORECASE)
ARCHIVE = re.compile(r"\.(tar|tgz|tar\.(gz|xz|zst|bz2)|zst|xz|gz|zip|7z|\d{3}|part[-_]?[a-z0-9]{1,3})$", re.IGNORECASE)


def read_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().strip("'\"")
    return values


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--repo", required=True)
    arguments = parser.parse_args()

    kernel = read_env(arguments.root / "kernel/mainline-6.18/artifacts/accepted-android-4k.env")
    android = read_env(arguments.root / "android/lineage-24/metadata/accepted-release.env")
    wanted = {
        "kernel": [kernel["UML_KERNEL_ARTIFACT_DIRECTORY_NAME"], f"android-6.18-arm64-4k-{kernel['UML_KERNEL_ARTIFACT_RELEASE_ID']}", kernel["UML_KERNEL_ARTIFACT_RELEASE_ID"]],
        "android": [android["LINEAGE24_ACCEPTED_DIRECTORY_NAME"], android["LINEAGE24_ACCEPTED_RELEASE_ID"]],
    }
    # The bare kernel release ID is shared by the Linux bundles; an asset that
    # names only it must also say android.
    try:
        listing = subprocess.run(
            ["gh", "api", "--paginate", f"repos/{arguments.repo}/releases?per_page=100"],
            check=True, capture_output=True, text=True).stdout
    except subprocess.CalledProcessError as error:
        print(f"discover-prebuilt: cannot list the releases of {arguments.repo}: {error.stderr.strip()}", file=sys.stderr)
        return 0
    releases = []
    for chunk in re.split(r"(?<=\])\s*(?=\[)", listing.strip()):
        if chunk:
            releases.extend(json.loads(chunk))
    print(f"discover-prebuilt: {len(releases)} release(s) in {arguments.repo}", file=sys.stderr)

    chosen: dict[str, list[str]] = {"kernel": [], "android": []}
    for kind, names in wanted.items():
        for release in releases:
            tag = release.get("tag_name", "")
            label = f"{tag} {release.get('name') or ''}"
            for asset in release.get("assets", []):
                name = asset.get("name", "")
                if SKIP.search(name) or not ARCHIVE.search(name):
                    continue
                hit = False
                for index, key in enumerate(names):
                    bare_kernel_id = kind == "kernel" and index == len(names) - 1
                    if key in name and (not bare_kernel_id or "android" in name.lower()):
                        hit = True
                    elif key in label and (not bare_kernel_id or "android" in name.lower()):
                        hit = True
                if hit:
                    # The parts of a split archive are downloaded together, so they are joined.
                    part = SPLIT_PART.match(name)
                    asset_spec = f"{part.group(1)}.*" if part else name
                    source = f"gh-release:{arguments.repo}@{tag}/{asset_spec}"
                    if source not in chosen[kind]:
                        chosen[kind].append(source)
            if chosen[kind]:
                break        # the newest release that has it
        if chosen[kind]:
            print(f"discover-prebuilt: {kind}: {' '.join(chosen[kind])}", file=sys.stderr)
        else:
            print(f"discover-prebuilt: {kind}: no asset names {' / '.join(names)}", file=sys.stderr)

    sources = list(dict.fromkeys(chosen["kernel"] + chosen["android"]))
    if sources:
        print("\n".join(sources))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
