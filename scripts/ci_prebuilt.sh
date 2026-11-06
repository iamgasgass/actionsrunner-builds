#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# CI: put a prebuilt part of Husk where the build expects it, and check it is what it says it is.
#
# Three parts of the app cannot be built from this repository alone:
#   java-runtime    build/java-runtime       libcore, ICU, conscrypt and Husk's framework.dex (scripts/build_java_runtime.sh,
#                                            from an Android image's APEXes)
#   android-system  build/android-system     fonts and CA certificates (scripts/build_android_system.sh, from the Lineage image)
#   ps4             build/ios-arm64/lib/libhuskps4.dylib
#                                            the PS4 layer (scripts/build_ps4_ios.sh, from Bachata-S4 and husk-fex)
# so CI takes them as archives made from a Mac that has those inputs.
#
# Usage: scripts/ci_prebuilt.sh <java-runtime|android-system|ps4> <source> [sha256]
#
#   source   https://...                       any URL curl can fetch (HUSK_PREBUILT_TOKEN, if set, is sent as a bearer token)
#            gh-release:OWNER/REPO@TAG/ASSET   a release asset, fetched with gh (private repositories too, with GH_TOKEN)
#            /path/or/file://path              a local file or directory
#   sha256   the archive's SHA-256; checked when given
#
# Archives: .tar, .tar.gz/.tgz, .tar.xz, .tar.bz2, .zip, or (ps4 only) the bare .dylib. An archive whose only top-level entry is
# a directory is taken as that directory's contents, so `tar czf java-runtime.tgz java-runtime` and `cd java-runtime && tar czf
# ../java-runtime.tgz .` both work.
#
# Exit status: 0 installed and verified, 1 failed (the build must not go on with it), 2 usage.
set -euo pipefail

HUSK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIND="${1:-}"; SOURCE="${2:-}"; SHA="${3:-}"
[ -n "$KIND" ] && [ -n "$SOURCE" ] || { sed -n '3,30p' "$0" >&2; exit 2; }

say()  { printf '[prebuilt %s] %s\n' "$KIND" "$*"; }
unzip_to() { if command -v ditto >/dev/null 2>&1; then ditto -x -k "$1" "$2"; else unzip -q "$1" -d "$2"; fi; }
fail() { printf '::error title=Prebuilt %s::%s\n' "$KIND" "$*" >&2; exit 1; }

case "$KIND" in
    java-runtime)   DEST="$HUSK_ROOT/build/java-runtime" ;;
    android-system) DEST="$HUSK_ROOT/build/android-system" ;;
    ps4)            DEST="$HUSK_ROOT/build/ios-arm64/lib/libhuskps4.dylib" ;;
    *) echo "unknown part '$KIND' (java-runtime, android-system or ps4)" >&2; exit 2 ;;
esac

WORK="$(mktemp -d "${RUNNER_TEMP:-/tmp}/husk-prebuilt-$KIND.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- fetch
FILE=""
case "$SOURCE" in
    gh-release:*)
        spec="${SOURCE#gh-release:}"            # OWNER/REPO@TAG/ASSET
        repo="${spec%%@*}"; rest="${spec#*@}"
        tag="${rest%%/*}"; asset="${rest#*/}"
        [ -n "$repo" ] && [ -n "$tag" ] && [ -n "$asset" ] && [ "$rest" != "$spec" ] \
            || fail "gh-release source must be gh-release:OWNER/REPO@TAG/ASSET, got '$SOURCE'"
        say "release asset $asset of $repo@$tag"
        gh release download "$tag" --repo "$repo" --pattern "$asset" --dir "$WORK/dl" \
            || fail "could not download $asset from $repo@$tag (does GH_TOKEN reach that repository?)"
        FILE="$WORK/dl/$asset"
        ;;
    http://*|https://*)
        name="$(basename "${SOURCE%%\?*}")"; [ -n "$name" ] || name=download
        FILE="$WORK/dl/$name"; mkdir -p "$WORK/dl"
        say "downloading $(printf '%s' "$SOURCE" | sed -E 's#(://)[^/@]*@#\1***@#')"     # never print credentials in a URL
        auth=(); [ -n "${HUSK_PREBUILT_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $HUSK_PREBUILT_TOKEN")
        curl -fSL --retry 5 --retry-delay 10 --retry-all-errors --connect-timeout 30 \
             ${auth[@]+"${auth[@]}"} -o "$FILE" "$SOURCE" || fail "download failed"
        ;;
    file://*) FILE="${SOURCE#file://}" ;;
    *) FILE="$SOURCE" ;;
esac
[ -e "$FILE" ] || fail "nothing at $FILE"

# ---------------------------------------------------------------- checksum
if [ -n "$SHA" ]; then
    [ -f "$FILE" ] || fail "a checksum was given, but the source is a directory"
    got="$(shasum -a 256 "$FILE" | awk '{print $1}')"
    want="$(printf '%s' "$SHA" | tr 'A-F' 'a-f' | tr -d '[:space:]')"
    [ "$got" = "$want" ] || fail "SHA-256 mismatch: got $got, expected $want"
    say "sha256 ok ($got)"
elif [ -f "$FILE" ]; then
    say "sha256 $(shasum -a 256 "$FILE" | awk '{print $1}') (not pinned: set the matching *_SHA256 variable to pin it)"
fi

# ---------------------------------------------------------------- unpack
ROOT="$WORK/root"; mkdir -p "$ROOT"
if [ -d "$FILE" ]; then
    cp -R "$FILE/." "$ROOT/"
else
    case "$(echo "$FILE" | tr 'A-Z' 'a-z')" in
        *.zip)                     unzip_to "$FILE" "$ROOT" || fail "not a readable zip" ;;
        *.tar|*.tar.gz|*.tgz|*.tar.xz|*.txz|*.tar.bz2|*.tbz2) tar -xf "$FILE" -C "$ROOT" || fail "not a readable tar" ;;
        *.dylib)                   cp "$FILE" "$ROOT/" ;;
        *) # no telling extension (a GitHub API asset URL): by content
           if unzip -tq "$FILE" >/dev/null 2>&1; then unzip_to "$FILE" "$ROOT"
           elif tar -tf "$FILE" >/dev/null 2>&1; then tar -xf "$FILE" -C "$ROOT"
           elif file -b "$FILE" | grep -q "Mach-O"; then cp "$FILE" "$ROOT/libhuskps4.dylib"
           else fail "unrecognised archive: $(file -b "$FILE")"; fi ;;
    esac
fi
rm -rf "$ROOT/__MACOSX"; find "$ROOT" -name .DS_Store -delete
# one directory at the top: its contents are the part
entries=("$ROOT"/* "$ROOT"/.[!.]*); real=()
for e in "${entries[@]}"; do [ -e "$e" ] && real+=("$e"); done
if [ ${#real[@]} -eq 1 ] && [ -d "${real[0]}" ]; then ROOT="${real[0]}"; fi

# ---------------------------------------------------------------- verify and install
case "$KIND" in
    java-runtime)
        # What scripts/build_java_runtime.sh makes and the runtime opens first: without any of these Java apps do not start.
        for f in husk-framework.dex \
                 com.android.art/javalib/core-oj.jar com.android.art/javalib/core-libart.jar \
                 com.android.art/lib64/libjavacore.so com.android.art/lib64/libopenjdk.so \
                 com.android.i18n/javalib/core-icu4j.jar com.android.i18n/etc/icu \
                 com.android.conscrypt/javalib/conscrypt.jar; do
            [ -e "$ROOT/$f" ] || fail "no $f in it: not a build/java-runtime (scripts/build_java_runtime.sh)"
        done
        head -c 4 "$ROOT/husk-framework.dex" | grep -q "dex" || fail "husk-framework.dex is not a DEX file"
        for so in "$ROOT"/com.android.art/lib64/*.so; do
            file -b "$so" | grep -q "ELF 64-bit LSB.*aarch64\|ELF 64-bit LSB.*ARM aarch64" \
                || fail "$(basename "$so") is not a 64-bit ARM ELF library"
        done
        rm -rf "$DEST"; mkdir -p "$DEST"; cp -R "$ROOT/." "$DEST/"
        say "installed: $(du -sh "$DEST" | cut -f1), framework.dex $(wc -c < "$DEST/husk-framework.dex" | tr -d ' ') bytes"
        ;;
    android-system)
        [ -d "$ROOT/fonts" ] || fail "no fonts/ in it: not a build/android-system (scripts/build_android_system.sh)"
        n="$(find "$ROOT/fonts" -type f \( -name '*.ttf' -o -name '*.otf' -o -name '*.ttc' \) | wc -l | tr -d ' ')"
        [ "$n" -gt 0 ] || fail "fonts/ has no fonts"
        rm -rf "$DEST"; mkdir -p "$DEST"; cp -R "$ROOT/." "$DEST/"
        certs="$DEST/cacerts"; [ -d "$certs" ] || certs="$DEST/etc/security/cacerts"
        nc=0; [ -d "$certs" ] && nc="$(ls "$certs" | wc -l | tr -d ' ')"
        [ "$nc" -gt 0 ] || echo "::warning title=Prebuilt android-system::no CA certificates in it (cacerts/): HTTPS in Flutter apps will fail"
        say "installed: $(du -sh "$DEST" | cut -f1), $n fonts, $nc CA certificates"
        ;;
    ps4)
        lib="$(find "$ROOT" -name 'libhuskps4.dylib' -type f | head -1)"
        [ -n "$lib" ] || lib="$(find "$ROOT" -name '*.dylib' -type f | head -1)"
        [ -n "$lib" ] || fail "no dylib in it"
        file -b "$lib" | grep -q "Mach-O 64-bit dynamically linked shared library arm64" || fail "not an arm64 dylib: $(file -b "$lib")"
        # iOS (platform 2), not macOS or the simulator: a wrong one installs fine and fails only when a PS4 game starts
        plat="$(otool -l "$lib" | awk '/LC_BUILD_VERSION/{b=1} b&&/platform/{print $2; exit}')"
        [ "$plat" = 2 ] || fail "built for platform '${plat:-?}', not iOS (2)"
        # the one entry point the console host looks up (scripts/build_ps4_ios.sh checks the same)
        exports="$(nm -gU "$lib" | awk '{print $3}')"
        [ "$exports" = "_husk_console_module_v1" ] || fail "exports more or other than _husk_console_module_v1: $(echo $exports | head -c 300)"
        minos="$(otool -l "$lib" | awk '/LC_BUILD_VERSION/{b=1} b&&/minos/{print $2; exit}')"
        mkdir -p "$(dirname "$DEST")"; cp "$lib" "$DEST"
        say "installed: $(du -h "$DEST" | cut -f1), minos $minos"
        ;;
esac
