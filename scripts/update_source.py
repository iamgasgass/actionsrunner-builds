#!/usr/bin/env python3
"""Put a release on iLoader X's AltStore / SideStore source (site/iloaderx.json).

    VERSION=1.0.0 IPA=build/iLoaderX.ipa NOTES_FILE=notes.md python3 scripts/update_source.py

The release's entry goes first in `versions` (one already there for the same
version is replaced) and the app's top-level fields follow it, for the older
AltStore format. downloadURL is the release asset on iamgasgass/iloaderx.
"""
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO = os.environ.get("REPO", "iamgasgass/iloaderx")
SOURCE = Path(os.environ.get("SOURCE_FILE", "site/iloaderx.json"))
version = os.environ.get("VERSION", "").strip().lstrip("vV")
ipa = Path(os.environ.get("IPA", "build/iLoaderX.ipa"))
notes_file = os.environ.get("NOTES_FILE")
if not version:
    sys.exit("error: VERSION isn't set")
if not ipa.is_file():
    sys.exit(f"error: no IPA at {ipa}")
notes = Path(notes_file).read_text().strip() if notes_file else f"iLoader X {version}"

src = json.loads(SOURCE.read_text())
app = src["apps"][0]
entry = {
    "version": version.split("-")[0],
    "date": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "downloadURL": f"https://github.com/{REPO}/releases/download/v{version}/iLoaderX.ipa",
    "localizedDescription": notes,
    "size": ipa.stat().st_size,
    "minOSVersion": "17.4",
}
app["versions"] = [entry] + [v for v in app.get("versions", []) if v.get("version") != entry["version"]]
app.update({
    "version": entry["version"],
    "versionDate": entry["date"],
    "versionDescription": notes,
    "downloadURL": entry["downloadURL"],
    "size": entry["size"],
})
SOURCE.write_text(json.dumps(src, indent=2, ensure_ascii=False) + "\n")
print(f"{SOURCE}: iLoader X {entry['version']} ({entry['size']} bytes)")
