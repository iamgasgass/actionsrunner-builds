#!/bin/sh
# Host test of the OpenSL ES player (husk-tl-opensles.c) as OpenAL Soft uses it.
set -e
here=$(cd "$(dirname "$0")" && pwd); src="$here/../../src/translation-layer-next"; out=$(mktemp -d)
cc -std=gnu11 -O1 -w -I"$src" -I"$src/../translation-layer" "$here/opensles_test.c" -o "$out/opensles_test" -lm -lpthread
"$out/opensles_test"
