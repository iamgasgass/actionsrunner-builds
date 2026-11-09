#!/bin/sh
# Host test of the SCM_RIGHTS conversion in husk-tl-bionic-net.c (cmsg_to_darwin / cmsg_from_darwin): the two functions are taken
# out of the file and run over a real socketpair (the host's own cmsghdr stands in for Darwin's; the guest side is Linux's layout).
set -e
here=$(cd "$(dirname "$0")" && pwd); out=$(mktemp -d)
python3 "$here/net_cmsg_test.py" "$here/../../src/translation-layer-next/husk-tl-bionic-net.c" "$out/cm.c"
cc -std=gnu11 -Wall -Wno-unused-function -o "$out/cm" "$out/cm.c"
"$out/cm"
