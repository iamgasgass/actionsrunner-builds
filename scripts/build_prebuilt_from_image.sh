#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# build/java-runtime and build/android-system from the LineageOS image Husk's Android guest boots (GuestImage.swift downloads it:
# releases/lineage-v2/vda-v12.qcow2), with no Android tree and no Mac: what scripts/build_java_runtime.sh and
# scripts/build_android_system.sh take from a local copy of that system, taken from the image itself. Runs on Linux (CI) and macOS.
#
#   scripts/build_prebuilt_from_image.sh <vda.qcow2 | vda.raw> [java-runtime] [android-system]     (no part named: both)
#
# Environment: HUSK_JDK (a JDK home; default $JAVA_HOME), HUSK_D8 (R8 8.5+ jar), HUSK_AOSP (0: no AOSP framework.jar beside
# Husk's framework, as build_java_runtime.sh), HUSK_IMAGE_WORK (where the image is unpacked; default a temporary folder).
# Needs: qemu-img, python3, debugfs (e2fsprogs) for ext4 or fsck.erofs (erofs-utils) for EROFS partitions.
set -euo pipefail

HUSK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMG="${1:?usage: build_prebuilt_from_image.sh <vda.qcow2|vda.raw> [java-runtime] [android-system]}"
shift
PARTS=("$@"); [ ${#PARTS[@]} -eq 0 ] && PARTS=(java-runtime android-system)
want() { local p; for p in "${PARTS[@]}"; do [ "$p" = "$1" ] && return 0; done; return 1; }

WORK="${HUSK_IMAGE_WORK:-$(mktemp -d)}"
mkdir -p "$WORK"
[ -n "${HUSK_IMAGE_WORK:-}" ] || trap 'rm -rf "$WORK"' EXIT
step() { printf '==> %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

DEBUGFS="$(command -v debugfs || ls /opt/homebrew/opt/e2fsprogs/sbin/debugfs /usr/local/opt/e2fsprogs/sbin/debugfs /sbin/debugfs 2>/dev/null | head -1 || true)"
FSCK_EROFS="$(command -v fsck.erofs || true)"

# ---------------------------------------------------------------- reading files out of a filesystem image
fs_kind() {   # ext4 | erofs
    python3 - "$1" <<'PY'
import struct, sys
f = open(sys.argv[1], 'rb')
f.seek(1024); sb = f.read(64)
if struct.unpack_from('<I', sb, 0)[0] == 0xE0F5E1E2: print('erofs')
elif struct.unpack_from('<H', sb, 56)[0] == 0xEF53: print('ext4')
else: print('unknown')
PY
}
# fs_get <image> <path in it> <destination>: a file to a file, a folder into <destination>/<its name>
fs_get() {
    local img="$1" path="$2" dest="$3" kind
    [ "$img" = "$SYSIMG" ] && ensure_system
    kind="$(fs_kind "$img")"
    case "$kind" in
        ext4)
            [ -n "$DEBUGFS" ] || die "debugfs (e2fsprogs) is needed to read ext4 images"
            if "$DEBUGFS" -R "stat $path" "$img" 2>/dev/null | grep -q "Type: directory"; then
                mkdir -p "$dest"; "$DEBUGFS" -R "rdump $path $dest" "$img" >/dev/null 2>&1
            else
                mkdir -p "$(dirname "$dest")"; "$DEBUGFS" -R "dump $path $dest" "$img" >/dev/null 2>&1
            fi ;;
        erofs)
            [ -n "$FSCK_EROFS" ] || die "fsck.erofs (erofs-utils) is needed to read EROFS images"
            local all="${img}.extracted"
            if [ ! -f "$all.done" ]; then rm -rf "$all"; "$FSCK_EROFS" --extract="$all" "$img" >/dev/null; touch "$all.done"; fi
            if [ -d "$all$path" ]; then mkdir -p "$dest"; cp -R "$all$path" "$dest/"
            elif [ -e "$all$path" ]; then mkdir -p "$(dirname "$dest")"; cp "$all$path" "$dest"; fi ;;
        *) die "$(basename "$img"): neither ext4 nor EROFS" ;;
    esac
}
# ---------------------------------------------------------------- the image, read only when something is not already unpacked
# (CI keeps $HUSK_IMAGE_WORK/apex and /sysroot between runs: a change to Husk's Java framework rebuilds the runtime from those, without
# fetching and unpacking 1 GB of image again)
SYSIMG="$WORK/system.img"
SYSKIND=""; SYSROOT_PATH=/system
ensure_system() {
[ -n "$SYSKIND" ] && return 0
[ -e "$IMG" ] || die "$IMG is not there, and $WORK does not have everything unpacked yet"
RAW="$IMG"
case "$IMG" in
    *.qcow2)
        RAW="$WORK/vda.raw"
        command -v qemu-img >/dev/null || die "qemu-img is needed for a .qcow2 (qemu-utils / brew install qemu)"
        if [ ! -s "$RAW" ]; then step "converting $(basename "$IMG") to raw (sparse)"; qemu-img convert -O raw "$IMG" "$RAW.part" && mv "$RAW.part" "$RAW"; fi ;;
esac

# ---------------------------------------------------------------- the system partition, out of super
# GPT, then the partition holding Android's logical-partition metadata (geometry magic "gDla" 4 KiB in), then the extents of its
# "system" logical partition: the reading build_android_system.sh does, without macOS's gpt(8).
if [ ! -s "$SYSIMG" ]; then
    step "unpacking system from the super partition"
    python3 - "$RAW" "$SYSIMG" <<'PY'
import struct, sys
raw, out = sys.argv[1], sys.argv[2]
f = open(raw, 'rb')
f.seek(512); h = f.read(92)
assert h[:8] == b'EFI PART', 'no GPT in the image'
lba, n, esz = struct.unpack_from('<QII', h, 72)
f.seek(lba * 512); table = f.read(n * esz)
parts = []
for i in range(n):
    e = table[i * esz:(i + 1) * esz]
    first, last = struct.unpack_from('<QQ', e, 32)
    if first == 0: continue
    name = e[56:128].decode('utf-16-le', 'replace').split('\0')[0]
    parts.append((name, first, last))
base = None
for name, first, last in parts:
    f.seek(first * 512 + 4096)
    if struct.unpack('<I', f.read(4))[0] == 0x616C4467:          # LP_METADATA_GEOMETRY_MAGIC
        base = first * 512; print(f'   super is partition "{name}"'); break
assert base is not None, 'no partition with logical partitions (super) in: ' + ', '.join(p[0] for p in parts)
f.seek(base + 12288); h = f.read(256)                          # reserved 4 KiB, two geometry copies, then metadata slot 0
magic, _, _, hsize = struct.unpack_from('<IHHI', h, 0)
assert magic == 0x414C5030, 'no logical partition metadata'
tsize = struct.unpack_from('<I', h, 12 + 32)[0]
descs = [struct.unpack_from('<III', h, 12 + 32 + 4 + 32 + 12 * i) for i in range(4)]
f.seek(base + 12288 + hsize); T = f.read(tsize)
(po, pn, ps), (eo, en, es) = descs[0], descs[1]
ext = [struct.unpack_from('<QIQI', T, eo + es * i) for i in range(en)]
names = []
for i in range(pn):
    e = T[po + ps * i:po + ps * (i + 1)]
    name = e[:36].split(b'\0')[0].decode(); _, fi, ne, _ = struct.unpack_from('<IIII', e, 36)
    names.append(name)
    if name not in ('system', 'system_a'): continue
    total = 0
    with open(out, 'wb') as w:
        for j in range(fi, fi + ne):
            nsec, kind, data, _ = ext[j]
            left = nsec * 512; total += left
            if kind == 1:                                       # LP_TARGET_TYPE_ZERO
                w.seek(left, 1); continue
            f.seek(base + data * 512)
            while left:
                b = f.read(min(left, 64 << 20)); w.write(b); left -= len(b)
        w.truncate(total)
    print(f'   {name}: {total >> 20} MiB')
    break
else:
    raise SystemExit('no system logical partition (there are: ' + ', '.join(names) + ')')
PY
fi


    SYSKIND="$(fs_kind "$SYSIMG")"
    echo "   system is $SYSKIND"
    # system-as-root: the partition's root holds /system
    SYSROOT_PATH=/system
    if [ "$SYSKIND" = ext4 ] && ! "$DEBUGFS" -R "stat /system/framework" "$SYSIMG" 2>/dev/null | grep -q directory; then SYSROOT_PATH=""; fi
}


# An APEX (.apex, or compressed .capex) from /system/apex, its payload unpacked to $WORK/apex/<name>
apex_out() {
    local name="$1" out="$WORK/apex/$1" file=""
    [ -d "$out" ] && return 0
    for ext in capex apex; do
        fs_get "$SYSIMG" "$SYSROOT_PATH/apex/$name.$ext" "$WORK/apexfiles/$name.$ext"
        if [ -s "$WORK/apexfiles/$name.$ext" ]; then file="$WORK/apexfiles/$name.$ext"; break; fi
    done
    [ -n "$file" ] || die "no $name APEX in the image's /system/apex"
    python3 - "$file" "$WORK/apexfiles/$name.img" <<'PY'
import sys, zipfile, io
z = zipfile.ZipFile(sys.argv[1])
if 'original_apex' in z.namelist(): z = zipfile.ZipFile(io.BytesIO(z.read('original_apex')))
open(sys.argv[2], 'wb').write(z.read('apex_payload.img'))
PY
    mkdir -p "$out.tmp"
    case "$(fs_kind "$WORK/apexfiles/$name.img")" in
        ext4) "$DEBUGFS" -R "rdump / $out.tmp" "$WORK/apexfiles/$name.img" >/dev/null 2>&1 ;;
        erofs) "$FSCK_EROFS" --extract="$out.tmp/x" "$WORK/apexfiles/$name.img" >/dev/null && mv "$out.tmp/x"/* "$out.tmp/" && rmdir "$out.tmp/x" ;;
        *) die "$name's payload: neither ext4 nor EROFS" ;;
    esac
    mv "$out.tmp" "$out"
    echo "   $name: $(du -sh "$out" | cut -f1)"
}

# ---------------------------------------------------------------- android-system (as build_android_system.sh)
if want android-system; then
    OUT="$HUSK_ROOT/build/android-system"
    step "android-system: fonts, font lists, CA certificates"
    rm -rf "$OUT" "$WORK/dump"; mkdir -p "$OUT/etc" "$OUT/fonts" "$WORK/dump"
    fs_get "$SYSIMG" "$SYSROOT_PATH/fonts" "$WORK/dump"
    find "$WORK/dump/fonts" -type f ! -name '*CJK*' -size +100c -exec cp {} "$OUT/fonts/" \;
    for x in fonts.xml font_fallback.xml; do fs_get "$SYSIMG" "$SYSROOT_PATH/etc/$x" "$OUT/etc/$x"; done
    apex_out com.android.conscrypt
    mkdir -p "$OUT/cacerts"; cp "$WORK/apex/com.android.conscrypt/cacerts/"* "$OUT/cacerts/"
    nf="$(ls "$OUT/fonts" | wc -l | tr -d ' ')"; nc="$(ls "$OUT/cacerts" | wc -l | tr -d ' ')"
    [ "$nf" -gt 0 ] && [ "$nc" -gt 0 ] || die "android-system came out empty ($nf fonts, $nc certificates)"
    echo "   $OUT: $nf fonts, $nc certificates ($(du -sh "$OUT" | cut -f1))"
fi

# ---------------------------------------------------------------- java-runtime (through build_java_runtime.sh itself)
if want java-runtime; then
    step "java-runtime: the APEXes and /system/framework"
    for a in com.android.art com.android.i18n com.android.tzdata com.android.conscrypt; do apex_out "$a"; done
    SYS="$WORK/sysroot"
    if [ ! -d "$SYS/framework" ]; then
        rm -rf "$SYS"; mkdir -p "$SYS/lib64"
        fs_get "$SYSIMG" "$SYSROOT_PATH/framework" "$SYS"
        for l in libandroid_runtime.so libbinder.so libutils.so libcutils.so libui.so libgui.so libhwui.so; do
            fs_get "$SYSIMG" "$SYSROOT_PATH/lib64/$l" "$SYS/lib64/$l"
        done
    fi
    [ -f "$SYS/framework/framework-res.apk" ] || die "no framework-res.apk in the image's /system/framework"
    [ -f "$SYS/framework/org.apache.http.legacy.jar" ] || die "no org.apache.http.legacy.jar in the image's /system/framework"
    export HUSK_JDK="${HUSK_JDK:-${JAVA_HOME:?set HUSK_JDK or JAVA_HOME to a JDK}}"
    [ -n "${HUSK_D8:-}" ] && [ -f "$HUSK_D8" ] || die "set HUSK_D8 to an R8 8.5+ jar (com.android.tools:r8)"
    step "java-runtime: building (scripts/build_java_runtime.sh)"
    HTTP_LEGACY="$SYS/framework/org.apache.http.legacy.jar" FRAMEWORK_RES="$SYS/framework/framework-res.apk" ANDROID_SYSROOT="$SYS" \
        bash "$HUSK_ROOT/scripts/build_java_runtime.sh" "$WORK/apex"
    [ -f "$HUSK_ROOT/build/java-runtime/husk-framework.dex" ] || die "build_java_runtime.sh made no husk-framework.dex"
fi
step "done"
