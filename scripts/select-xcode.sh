#!/bin/bash
# Pick the Xcode with the newest iOS SDK at or above MIN_IOS_SDK (default 27.0)
# among /Applications/Xcode*.app, and export it as DEVELOPER_DIR (to
# GITHUB_ENV on Actions). Stable Xcodes win over release candidates and betas
# (newest stable iOS 27.x SDK); a beta/RC is taken only when no stable Xcode
# has iOS 27. PREFER_NEWEST=1 takes the newest SDK, prerelease or not.
#
#   scripts/select-xcode.sh            # newest iOS 27.x SDK
#   XCODE=27.1 scripts/select-xcode.sh # that Xcode, if it's there
set -euo pipefail
MIN_IOS_SDK="${MIN_IOS_SDK:-27.0}"
ver_ge() { [ "$(printf '%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }
xcode_version() { defaults read "$1/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?'; }
ios_sdk() { DEVELOPER_DIR="$1/Contents/Developer" xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || echo 0; }

APPS_GLOB="${APPS_GLOB:-/Applications/Xcode*.app}"
candidates=""
echo "Xcodes on this machine:"
for app in $APPS_GLOB; do
  [ -d "$app/Contents/Developer" ] || continue
  v="$(xcode_version "$app")"
  sdk="$(ios_sdk "$app")"
  case "$(basename "$app" | tr '[:upper:]' '[:lower:]')" in
    *beta*|*_rc*|*release_candidate*) rank=0 ;;
    *) rank=1 ;;
  esac
  echo "  $app  Xcode $v  iOS SDK $sdk$([ $rank = 0 ] && echo '  (prerelease)' || true)"
  if [ -n "${XCODE:-}" ] && [ "$v" != "$XCODE" ] && [ "$(basename "$app")" != "Xcode_${XCODE}.app" ]; then continue; fi
  ver_ge "$sdk" "$MIN_IOS_SDK" || continue
  # sort key: stable before prerelease (unless PREFER_NEWEST=1), then SDK, then Xcode
  [ "${PREFER_NEWEST:-0}" = 1 ] && key="$sdk $rank" || key="$rank $sdk"
  candidates+="$key $v|$app|$sdk"$'\n'
done
best="" best_sdk=""
if [ -n "$candidates" ]; then
  line="$(printf '%s' "$candidates" | sort -V -t'|' -k1,1 | tail -1)"
  best="$(cut -d'|' -f2 <<<"$line")"; best_sdk="$(cut -d'|' -f3 <<<"$line")"
fi

if [ -z "$best" ]; then
  echo "::error::No Xcode here has the iOS $MIN_IOS_SDK SDK or later${XCODE:+ (asked for Xcode $XCODE)}. iLoader X builds with Xcode 27 and the iOS 27.x SDK: use a runner image that has it (repository variable IOS27_RUNNER)."
  exit 1
fi
dev="$best/Contents/Developer"
echo "==> Using $best (iOS SDK $best_sdk)"
[ -n "${GITHUB_ENV:-}" ] && echo "DEVELOPER_DIR=$dev" >> "$GITHUB_ENV"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -z "${SELECT_XCODE_DRY:-}" ] && echo "Built with $(DEVELOPER_DIR="$dev" xcodebuild -version | tr '\n' ' ')— iOS SDK $best_sdk" >> "$GITHUB_STEP_SUMMARY"
[ -n "${SELECT_XCODE_DRY:-}" ] || DEVELOPER_DIR="$dev" xcodebuild -version
