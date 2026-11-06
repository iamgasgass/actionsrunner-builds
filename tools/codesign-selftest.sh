#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Husk's dylib signer, end to end on Linux: a throwaway CA, RSA (legacy and modern .p12, with and without the chain) and EC
# identities, a real arm64 Mach-O dylib (clang + ld64.lld), signed by husk-tl-codesign.c (tools/codesign-test.c, under ASan) and
# checked by tools/codesign-verify.py (CodeDirectory, page hashes, CMS against the CDHash, openssl cms -verify with the chain).
# Needs clang, ld64.lld, openssl, python3, libssl-dev.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
w="$(mktemp -d)"; trap 'rm -rf "$w"' EXIT
cd "$w"
ld64="$(command -v ld64.lld || ls /usr/bin/ld64.lld-* 2>/dev/null | sort -V | tail -1)"
[ -n "$ld64" ] || { echo "no ld64.lld"; exit 1; }
cc -fsanitize=address,undefined -g -I "$here/tools/codesign-test-shim" -o cst "$here/tools/codesign-test.c" -lcrypto -lpthread
q() { "$@" >/dev/null 2>&1; }
q openssl req -x509 -newkey rsa:2048 -nodes -keyout root.key -out root.pem -days 30 -subj "/CN=Test Root CA"
q openssl req -newkey rsa:2048 -nodes -keyout int.key -out int.csr -subj "/CN=Test WWDR/OU=G3"
printf 'basicConstraints=critical,CA:true\nkeyUsage=critical,keyCertSign\n' > int.ext
printf 'basicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' > leaf.ext
q openssl x509 -req -in int.csr -CA root.pem -CAkey root.key -CAcreateserial -out int.pem -days 30 -extfile int.ext
leaf() {  # name keyspec CN
    q openssl req -newkey "$2" -nodes -keyout "$1.key" -out "$1.csr" -subj "/UID=ABCDE12345/CN=$3/OU=ABCDE12345/O=Test"
    q openssl x509 -req -in "$1.csr" -CA int.pem -CAkey int.key -CAcreateserial -out "$1.pem" -days 30 -extfile leaf.ext
}
leaf rsa rsa:2048 "iPhone Developer: t (AAAAAAAAAA)"
leaf ec ec:<(openssl ecparam -name prime256v1) "Apple Development: e (BBBBBBBBBB)"
q openssl pkcs12 -export -inkey rsa.key -in rsa.pem -out rsa-alone.p12 -passout pass: -nomac -legacy \
  || q openssl pkcs12 -export -inkey rsa.key -in rsa.pem -out rsa-alone.p12 -passout pass:
q openssl pkcs12 -export -inkey rsa.key -in rsa.pem -certfile int.pem -out rsa-chain.p12 -passout pass:pw
q openssl pkcs12 -export -inkey ec.key -in ec.pem -certfile int.pem -out ec.p12 -passout pass:e
printf 'int f(int x){return x*3+1;}\nint g=5;\n' > t.c
clang -target arm64-apple-ios14.0 -O2 -c t.c -o t.o
"$ld64" -dylib -arch arm64 -platform_version ios 14.0 14.0 -install_name @rpath/libt.dylib -o t.dylib t.o
cat root.pem int.pem > ca.pem
cp t.dylib app.bin && ./cst app.bin rsa-chain.p12 pw com.husk.app >/dev/null 2>&1    # stands for Husk's own executable
fail=0
run() {  # p12 password expect-same
    cp t.dylib s.dylib
    out="$(./cst s.dylib "$1" "$2" com.husk.app app.bin 2>&1)" || { echo "FAIL sign $1: $out"; fail=1; return; }
    grep -q "same certificate as app.bin: $3" <<<"$out" || { echo "FAIL $1: expected same-certificate $3"; fail=1; }
    if python3 "$here/tools/codesign-verify.py" s.dylib ca.pem > v.txt; then echo "ok   $1"; else echo "FAIL verify $1"; grep FAIL v.txt; fail=1; fi
}
run rsa-alone.p12 "" 1
run rsa-chain.p12 pw 1
for i in 1 2 3 4; do run ec.p12 e 0; done          # ECDSA lengths vary: several signatures
exit $fail
