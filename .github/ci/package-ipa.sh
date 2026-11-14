#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Package an unsigned Andarium.app as a sideloadable IPA.
#
# Usage: .github/ci/package-ipa.sh APP ENTITLEMENTS OUTPUT.ipa
#
# "Unsigned" as sideloaders mean it: no developer certificate. Every nested
# framework and dylib is ad hoc signed, then the application with its
# entitlements (increased memory limit, extended virtual addressing) embedded,
# so SideStore / AltStore keep them when they re-sign at install and
# TrollStore installs the IPA as it is. The application is copied, never
# changed in place.
set -eu

fail()
{
	printf '%s\n' "package-ipa.sh: $*" >&2
	exit 1
}

[ "$#" -eq 3 ] || fail "usage: package-ipa.sh APP ENTITLEMENTS OUTPUT.ipa"
APP=$1
ENTITLEMENTS=$2
OUTPUT=$3
[ -d "$APP" ] || fail "no application at $APP"
[ -f "$ENTITLEMENTS" ] || fail "no entitlements at $ENTITLEMENTS"

WORK=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ipa.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT HUP INT TERM
mkdir -p -- "$WORK/Payload"
NAME=$(basename -- "$APP")
/usr/bin/ditto -- "$APP" "$WORK/Payload/$NAME"
BUNDLE="$WORK/Payload/$NAME"

# Strip what an IPA must not carry.
find "$BUNDLE" -name '_CodeSignature' -type d -prune -exec rm -rf {} +
find "$BUNDLE" -name 'embedded.mobileprovision' -type f -delete
find "$BUNDLE" -name '.DS_Store' -type f -delete

# Innermost first: dylibs, then frameworks, then the application.
find "$BUNDLE" -type f -name '*.dylib' | while IFS= read -r library; do
	/usr/bin/codesign --force --sign - --timestamp=none "$library"
done
find "$BUNDLE" -depth -type d \( -name '*.framework' -o -name '*.appex' \) |
	while IFS= read -r nested; do
		/usr/bin/codesign --force --sign - --timestamp=none \
			--preserve-metadata=identifier,flags "$nested"
	done
/usr/bin/codesign --force --sign - --timestamp=none \
	--entitlements "$ENTITLEMENTS" --generate-entitlement-der "$BUNDLE"
/usr/bin/codesign --verify --deep --strict "$BUNDLE" ||
	fail "the ad hoc signature does not verify"
/usr/bin/codesign -d --entitlements - --xml "$BUNDLE" >/dev/null 2>&1 ||
	fail "the application carries no entitlements"

OUTPUT_DIR=$(dirname -- "$OUTPUT")
mkdir -p -- "$OUTPUT_DIR"
OUTPUT="$(CDPATH= cd -- "$OUTPUT_DIR" && pwd -P)/$(basename -- "$OUTPUT")"
rm -f -- "$OUTPUT"
# Store the system image uncompressed (deflating gigabytes gains little and
# costs minutes) and compress the rest; -y keeps the frameworks' symlinks.
(
	cd -- "$WORK"
	/usr/bin/zip -qry -n .img:.erofs:.zst "$OUTPUT" Payload
)
printf '%s\n' "packaged $(du -h -- "$OUTPUT" | cut -f1) $OUTPUT"
