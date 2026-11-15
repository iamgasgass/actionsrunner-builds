#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""
Windows 11 ARM64 download catalog for the app's Install screen, the way Henge lists
Apple's restore images: every entry is a file on Microsoft's own CDN.

Reads Microsoft's Media Creation Tool catalog (products.cab -> products.xml), keeps the
ARM64 consumer ESDs (Home/Pro, one per language) and writes them as JSON:

    [{"language": "Italiano", "code": "it-it", "file": "...esd", "url": "https://...",
      "size": 5123456789, "sha1": "...", "build": "26100.4349"}, ...]

    python3 scripts/make_windows_catalog.py <out.json> [products.cab or products.xml]

Without a second argument it downloads products.cab (needs `cabextract` or `7z`/`bsdtar`).
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import xml.etree.ElementTree as ET

CATALOG_URL = "https://go.microsoft.com/fwlink/?LinkId=2156292"  # Windows 11 Media Creation Tool


def extract_cab(cab, dest):
    for cmd in (["cabextract", "-q", "-d", dest, cab], ["bsdtar", "-xf", cab, "-C", dest], ["7z", "x", "-y", f"-o{dest}", cab]):
        if shutil.which(cmd[0]) and subprocess.run(cmd, stdout=subprocess.DEVNULL).returncode == 0:
            for root, _, files in os.walk(dest):
                for f in files:
                    if f.lower() == "products.xml":
                        return os.path.join(root, f)
    sys.exit("could not extract products.xml from products.cab (install cabextract)")


def text(el, tag):
    for child in el:
        if child.tag.split("}")[-1].lower() == tag.lower():
            return (child.text or "").strip()
    return ""


def main():
    out = sys.argv[1]
    src = sys.argv[2] if len(sys.argv) > 2 else None
    tmp = tempfile.mkdtemp()
    try:
        if src is None:
            src = os.path.join(tmp, "products.cab")
            req = urllib.request.Request(CATALOG_URL, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=120) as r, open(src, "wb") as f:
                shutil.copyfileobj(r, f)
        xml_path = src if src.lower().endswith(".xml") else extract_cab(src, tmp)
        root = ET.parse(xml_path).getroot()
        entries = {}
        for el in root.iter():
            if el.tag.split("}")[-1] != "File":
                continue
            arch = text(el, "Architecture").lower()
            edition = text(el, "Edition")
            name = text(el, "FileName")
            url = text(el, "FilePath")
            if arch != "arm64" or not name.lower().endswith(".esd") or not url:
                continue
            # The consumer ESD (Home + Pro) is listed as edition "Professional"; skip business / N-only media.
            if edition and edition.lower() not in ("professional", "core", "coresinglelanguage"):
                continue
            if "CLIENTBUSINESS" in name.upper():
                continue
            code = text(el, "LanguageCode").lower()
            m = re.match(r"(\d+\.\d+)", name)
            entry = {
                "language": text(el, "Language") or code,
                "code": code,
                "file": name,
                # As Microsoft lists it: dl.delivery.mp.microsoft.com has no valid HTTPS certificate for its
                # own name. The app allows plain HTTP for that host only and checks the SHA-1 below.
                "url": url,
                "size": int(text(el, "Size") or 0),
                "sha1": text(el, "Sha1").lower(),
                "build": m.group(1) if m else "",
            }
            # Prefer the Professional-labelled entry for a language.
            if code not in entries or edition.lower() == "professional":
                entries[code] = entry
        result = sorted(entries.values(), key=lambda e: e["language"].lower())
        os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
        with open(out, "w", encoding="utf-8") as f:
            json.dump(result, f, ensure_ascii=False, indent=1)
        print(f"{len(result)} ARM64 ESDs -> {out}")
        if not result:
            sys.exit("no ARM64 ESD in Microsoft's catalog")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
