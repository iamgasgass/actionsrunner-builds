#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Runs media_params_test.c against the parameter-set readers in src/translation-layer-next/husk-tl-dvm-media.c.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT
SRC="$HERE/../../src/translation-layer-next/husk-tl-dvm-media.c"
{ printf '#include <stdint.h>\n#include <stddef.h>\n#include <stdbool.h>\n'
  sed -n '/^typedef struct { uint8_t b\[[0-9]*\]; size_t n, bit; } rbsp;/,/^static void ready_push/p' "$SRC" | sed '$d'; } > "$OUT/media_params_helpers.c"
cc -std=gnu11 -Wall -Wextra -Werror -Wno-unused-function -I"$OUT" -o "$OUT/t" "$HERE/media_params_test.c"
"$OUT/t"
