#!/bin/sh
# Host test of the audio output's converter (husk-tl-audio.c), with a stand-in AudioToolbox.
set -e
here=$(cd "$(dirname "$0")" && pwd); src="$here/../../src/translation-layer-next"; out=$(mktemp -d)
mkdir -p "$out/inc"; for h in husk-tl-audio.h husk-tl-bionic.h husk-tl-cocos.h; do [ -f "$src/$h" ] || { echo "missing $h"; exit 1; }; done
cc -std=gnu11 -O1 -Wall -Wno-unused-function -D_GNU_SOURCE -I"$here/audio-stub" -I"$src" -I"$src/../translation-layer" \
   "$src/husk-tl-audio.c" "$here/audio_test.c" -o "$out/audio_test" -lm -lpthread
"$out/audio_test"
