#!/usr/bin/env python3
"""Incorpora le IPA CarPlay di EmbeddedApps/ dentro CarPlayss.app/CarPlayApps/.

Per ogni IPA:
  - estrae Payload/*.app
  - accetta solo app compatibili con CarPlay (scena CPTemplateApplicationSceneSessionRoleApplication
    o entitlement com.apple.developer.carplay-*) e non criptate (FairPlay)
  - rimuove estensioni e app Watch
  - trasforma l'eseguibile in libreria dinamica (come fa CarPlayss a runtime)

Così LiveContainer firma anche il codice delle app incorporate quando installa CarPlayss.

Uso: embed_carplay_apps.py <CarPlayss.app> <cartella con le .ipa>
"""

import os
import plistlib
import re
import shutil
import struct
import sys
import tempfile
import zipfile

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
CPU_TYPE_ARM64 = 0x0100000C
MH_EXECUTE = 0x2
MH_DYLIB = 0x6
MH_NO_REEXPORTED_DYLIBS = 0x100000
MH_PIE = 0x200000
LC_SEGMENT_64 = 0x19
LC_ID_DYLIB = 0xD
LC_CODE_SIGNATURE = 0x1D
LC_ENCRYPTION_INFO_64 = 0x2C
DYLIB_COMMANDS = {0xC, 0x80000018, 0x8000001F, 0x20, 0x80000023, 0x8000001C}


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def set32(b, o, v):
    struct.pack_into("<I", b, o, v & 0xFFFFFFFF)


def arm64_slices(b):
    if u32(b, 0) == MH_MAGIC_64:
        return [0]
    magic = struct.unpack_from(">I", b, 0)[0]
    if magic not in (FAT_MAGIC, FAT_MAGIC_64):
        raise ValueError("non è un Mach-O")
    n = struct.unpack_from(">I", b, 4)[0]
    res = []
    for i in range(n):
        if magic == FAT_MAGIC:
            cpu, _, off = struct.unpack_from(">III", b, 8 + i * 20)
        else:
            cpu, _, off = struct.unpack_from(">IIQ", b, 8 + i * 32)
        if cpu == CPU_TYPE_ARM64 and u32(b, off) == MH_MAGIC_64:
            res.append(off)
    if not res:
        raise ValueError("nessuna slice arm64")
    return res


def commands(b, s):
    res, off = [], s + 32
    for _ in range(u32(b, s + 16)):
        cmd, size = u32(b, off), u32(b, off + 4)
        if size < 8 or off + size > len(b):
            break
        res.append((cmd, off, size))
        off += size
    return res


def is_encrypted(b):
    for s in arm64_slices(b):
        for cmd, off, _ in commands(b, s):
            if cmd == LC_ENCRYPTION_INFO_64 and u32(b, off + 16) != 0:
                return True
    return False


def signature_text(b):
    text = b""
    for s in arm64_slices(b):
        for cmd, off, _ in commands(b, s):
            if cmd == LC_CODE_SIGNATURE:
                start, length = s + u32(b, off + 8), u32(b, off + 12)
                text += bytes(b[start:start + length])
    return text


def patch_slice(b, s, exe_name, is_main=True, depth=0):
    loader_root = b"@loader_path" + b"/.." * depth
    cmds = commands(b, s)
    seen_rpaths = set()
    for cmd, off, size in cmds:
        if cmd in DYLIB_COMMANDS:
            str_off = u32(b, off + 8)
            start = off + str_off
            raw = bytes(b[start:off + size]).split(b"\0", 1)[0]
            new = raw
            if new.startswith(b"@executable_path"):
                new = loader_root + new[len(b"@executable_path"):]
            if cmd == 0x8000001C:  # LC_RPATH: dyld rifiuta i duplicati
                while new in seen_rpaths and new.startswith(b"@loader_path"):
                    new = b"@loader_path/." + new[len(b"@loader_path"):]
                seen_rpaths.add(new)
            if new != raw and len(new) < size - str_off:
                b[start:off + size] = new + b"\0" * (size - str_off - len(new))

    if not is_main or u32(b, s + 12) != MH_EXECUTE:
        return
    set32(b, s + 12, MH_DYLIB)
    flags = (u32(b, s + 24) | MH_NO_REEXPORTED_DYLIBS) & ~MH_PIE
    set32(b, s + 24, flags)

    first_section = None
    for cmd, off, _ in cmds:
        if cmd != LC_SEGMENT_64:
            continue
        name = bytes(b[off + 8:off + 24]).split(b"\0", 1)[0]
        vmaddr = struct.unpack_from("<Q", b, off + 24)[0]
        if name == b"__PAGEZERO" and vmaddr == 0:
            struct.pack_into("<QQ", b, off + 24, 0x100000000 - 0x4000, 0x4000)
        for i in range(u32(b, off + 64)):
            sec_off = u32(b, off + 72 + i * 80 + 48)
            if sec_off > 0:
                first_section = sec_off if first_section is None else min(first_section, sec_off)

    if any(c[0] == LC_ID_DYLIB for c in cmds):
        return
    name = exe_name.encode()
    cmd_size = (24 + len(name) + 1 + 7) & ~7
    sizeofcmds = u32(b, s + 20)
    if first_section is None or first_section - (32 + sizeofcmds) < cmd_size:
        raise ValueError("spazio insufficiente per LC_ID_DYLIB")
    start = s + 32
    b[start + cmd_size:start + cmd_size + sizeofcmds] = b[start:start + sizeofcmds]
    cmd = struct.pack("<IIIIII", LC_ID_DYLIB, cmd_size, 24, 2, 0x10000, 0x10000) + name
    b[start:start + cmd_size] = cmd + b"\0" * (cmd_size - len(cmd))
    set32(b, s + 16, u32(b, s + 16) + 1)
    set32(b, s + 20, sizeofcmds + cmd_size)


def carplay_report(app_dir, info):
    manifest = info.get("UIApplicationSceneManifest", {}).get("UISceneConfigurations", {})
    has_scene = "CPTemplateApplicationSceneSessionRoleApplication" in manifest
    exe = os.path.join(app_dir, info.get("CFBundleExecutable", ""))
    data = bytearray(open(exe, "rb").read())
    text = signature_text(data)
    prov = os.path.join(app_dir, "embedded.mobileprovision")
    if os.path.exists(prov):
        text += open(prov, "rb").read()
    categories = sorted(set(m.decode() for m in re.findall(rb"com\.apple\.developer\.carplay-([a-z-]+)", text)))
    return has_scene, categories, is_encrypted(data)


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 1
    host_app, source = sys.argv[1], sys.argv[2]
    ipas = sorted(f for f in os.listdir(source) if f.lower().endswith(".ipa")) if os.path.isdir(source) else []
    if not ipas:
        print("Nessuna IPA in", source, "- niente da incorporare.")
        return 0

    out_dir = os.path.join(host_app, "CarPlayApps")
    os.makedirs(out_dir, exist_ok=True)
    failures = 0
    for ipa in ipas:
        with tempfile.TemporaryDirectory() as tmp:
            try:
                with zipfile.ZipFile(os.path.join(source, ipa)) as z:
                    z.extractall(tmp)
                payload = os.path.join(tmp, "Payload")
                apps = [d for d in os.listdir(payload) if d.endswith(".app")]
                if not apps:
                    raise ValueError("manca Payload/*.app")
                app_dir = os.path.join(payload, apps[0])
                with open(os.path.join(app_dir, "Info.plist"), "rb") as f:
                    info = plistlib.load(f)
                has_scene, categories, encrypted = carplay_report(app_dir, info)
                if encrypted:
                    raise ValueError("IPA criptata (App Store): serve un'IPA decriptata")
                if not has_scene and not categories:
                    raise ValueError("non compatibile con CarPlay")
                for extra in ("PlugIns", "Extensions", "Watch", "AppClips", "com.apple.WatchPlaceholder", "_CodeSignature"):
                    shutil.rmtree(os.path.join(app_dir, extra), ignore_errors=True)
                exe_name = info["CFBundleExecutable"]
                exe = os.path.join(app_dir, exe_name)
                data = bytearray(open(exe, "rb").read())
                for s in arm64_slices(data):
                    patch_slice(data, s, exe_name)
                open(exe, "wb").write(data)
                # tutte le altre dylib/framework/tweak del bundle: @executable_path -> @loader_path/..
                for dirpath, _, files in os.walk(app_dir):
                    for fname in files:
                        path = os.path.join(dirpath, fname)
                        if path == exe or os.path.islink(path):
                            continue
                        with open(path, "rb") as fh:
                            head = fh.read(4)
                        if len(head) < 4 or (struct.unpack("<I", head)[0] != MH_MAGIC_64
                                             and struct.unpack(">I", head)[0] not in (FAT_MAGIC, FAT_MAGIC_64)):
                            continue
                        depth = len(os.path.relpath(dirpath, app_dir).split(os.sep)) if dirpath != app_dir else 0
                        try:
                            other = bytearray(open(path, "rb").read())
                            for sl in arm64_slices(other):
                                patch_slice(other, sl, fname, is_main=False, depth=depth)
                            open(path, "wb").write(other)
                        except ValueError:
                            pass
                bundle_id = info.get("CFBundleIdentifier", os.path.splitext(ipa)[0])
                dest = os.path.join(out_dir, bundle_id + ".app")
                shutil.rmtree(dest, ignore_errors=True)
                shutil.move(app_dir, dest)
                print(f"OK  {ipa}: {info.get('CFBundleDisplayName') or info.get('CFBundleName')} "
                      f"[{', '.join(categories) or 'scena CarPlay'}]")
            except Exception as exc:  # noqa: BLE001
                failures += 1
                print(f"NO  {ipa}: {exc}")
    print(f"Incorporate: {len(ipas) - failures}/{len(ipas)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
