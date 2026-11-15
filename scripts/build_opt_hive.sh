#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Builds tools/opt_hive_arm64.c into a freestanding Windows ARM64 console program (no SDK,
# no CRT): import libraries are generated from .def files with llvm-dlltool.
#   ./scripts/build_opt_hive.sh <out.exe>      (needs clang, lld-link, llvm-dlltool)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/opt_hive_arm64.exe}"
LLVM_BIN="${LLVM_BIN:-}"
for c in "$LLVM_BIN" "$(brew --prefix llvm 2>/dev/null)/bin" "$(brew --prefix lld 2>/dev/null)/bin" /usr/bin; do
    [ -n "$c" ] && [ -x "$c/lld-link" ] && LLVM_BIN="$c" && break
done
CLANG="${CLANG:-$( [ -x "$LLVM_BIN/clang" ] && echo "$LLVM_BIN/clang" || command -v clang )}"
DLLTOOL="${DLLTOOL:-$( [ -x "$LLVM_BIN/llvm-dlltool" ] && echo "$LLVM_BIN/llvm-dlltool" || command -v llvm-dlltool || true )}"
LLD_LINK="$( [ -x "$LLVM_BIN/lld-link" ] && echo "$LLVM_BIN/lld-link" || command -v lld-link || true )"
echo "clang: $CLANG"; echo "llvm-dlltool: ${DLLTOOL:-missing}"; echo "lld-link: ${LLD_LINK:-missing}"
if [ -z "$DLLTOOL" ] || [ -z "$LLD_LINK" ]; then echo "error: needs llvm-dlltool and lld-link (brew install llvm lld)" >&2; exit 1; fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf 'LIBRARY kernel32.dll\nEXPORTS\nGetCurrentProcess\nGetStdHandle\nWriteFile\nExitProcess\n' > "$TMP/kernel32.def"
printf 'LIBRARY advapi32.dll\nEXPORTS\nOpenProcessToken\nLookupPrivilegeValueW\nAdjustTokenPrivileges\nRegOpenKeyExW\nRegCreateKeyExW\nRegSetValueExW\nRegCloseKey\n' > "$TMP/advapi32.def"
"$DLLTOOL" -m arm64 -d "$TMP/kernel32.def" -l "$TMP/kernel32.lib"
"$DLLTOOL" -m arm64 -d "$TMP/advapi32.def" -l "$TMP/advapi32.lib"
"$CLANG" --target=aarch64-pc-windows-msvc -O2 -ffreestanding -fno-builtin -fno-stack-protector \
    -mno-stack-arg-probe -c "$ROOT/tools/opt_hive_arm64.c" -o "$TMP/opt_hive.obj"
mkdir -p "$(dirname "$OUT")"
"$LLD_LINK" /nologo /machine:arm64 /subsystem:console /entry:mainCRTStartup /nodefaultlib \
    "$TMP/opt_hive.obj" "$TMP/kernel32.lib" "$TMP/advapi32.lib" /out:"$OUT"
echo "built $OUT ($(wc -c < "$OUT") bytes)"
