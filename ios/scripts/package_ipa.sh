#!/bin/zsh
# Builds macOSiOS X for iOS and writes ~/Desktop/macOSiOS-X.ipa (or ~/Desktop/macOSiOS-X.tipa with --trollstore).
# (The Xcode target keeps Henge's name, so the bundle inside is Payload/Henge.app.)
# Unsigned build, then signed ad hoc inside out with the entitlements file named by the
# HENGE_ENTITLEMENTS environment variable (default Henge/Henge.entitlements), as Husk's
# package_ipa.sh does: the sideloader (SideStore, AltStore, Impactor) re-signs it
# with the user's own certificate and keeps the entitlements it can.
# --trollstore strips the entitlements TrollStore bans under PPL/TXM.
set -e
IOS="$(cd "$(dirname "$0")/.." && pwd)"
TROLLSTORE=false
[ "$1" = "--trollstore" ] && TROLLSTORE=true
OUT="${HENGE_IPA_OUT:-$HOME/Desktop/macOSiOS-X.ipa}" # HENGE_IPA_OUT: somewhere else (a trial build that must not replace the one on the Desktop)
[ "$TROLLSTORE" = true ] && OUT="${OUT%.ipa}.tipa"
[ -d "$IOS/deps/StikJIT.xcframework" ] || "$IOS/scripts/fetch_deps.sh"
cd "$IOS"
xcodegen generate >/dev/null
DD="$IOS/build/DerivedData"
mkdir -p "$IOS/build"
# Optional APIs newer than some SDKs: compiled in only when this SDK has them. Decided by type-checking a
# one-line probe against the SDK (not by searching headers), as WindowsiOS X does for UIHingeInteraction.
CONDITIONS='$(inherited)'
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
PROBE="$IOS/build/probe_scene_accessory.swift"
printf 'import SwiftUI\n@available(iOS 27.0, *) func probe(_ v: some View) -> some View { v.sceneAccessory { ExternalNonInteractiveAccessory { Color.black } } }\n' > "$PROBE"
if xcrun --sdk iphoneos swiftc -typecheck -sdk "$SDK_PATH" -target arm64-apple-ios17.0 "$PROBE" >/dev/null 2>&1; then
    CONDITIONS="$CONDITIONS HENGE_SCENE_ACCESSORY"
    echo "iOS SDK $(xcrun --sdk iphoneos --show-sdk-version): external display scene accessory (iOS 27) compiled in"
else
    echo "iOS SDK $(xcrun --sdk iphoneos --show-sdk-version): no scene accessory API; external displays use the scene delegate on every iOS"
fi
rm -f "$PROBE"
# The iPhone Duo's hinge sensor (UIHingeInteraction, iOS 27.1 SDK), as WindowsiOS X probes it.
PROBE="$IOS/build/probe_hinge.swift"
printf 'import UIKit\n@available(iOS 27.1, *) func probe(_ v: UIView) { v.addInteraction(UIHingeInteraction { _, u in if let h = u.hinge { _ = (h.status.rawValue, Double(h.angle)) } }) }\n' > "$PROBE"
if xcrun --sdk iphoneos swiftc -typecheck -sdk "$SDK_PATH" -target arm64-apple-ios17.0 "$PROBE" >/dev/null 2>&1; then
    CONDITIONS="$CONDITIONS MACOSIOSX_HINGE"
    echo "UIHingeInteraction: yes (iPhone Duo hinge sensor compiled in)"
else
    echo "UIHingeInteraction: not in this SDK, building without the hinge sensor"
fi
rm -f "$PROBE"
xcodebuild -project Henge.xcodeproj -scheme Henge -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS="$CONDITIONS" build > "$DD.buildlog" 2>&1 || {
    # Never package what an older build left behind.
    grep -E "error:|BUILD" "$DD.buildlog" | sort -u
    echo "==> the build failed; nothing packaged" >&2
    exit 1
}
grep -E "BUILD" "$DD.buildlog" || true
APP="$DD/Build/Products/Release-iphoneos/Henge.app"
rc=0
for f in "$APP/Henge" "$APP/henge-jit.js" "$APP/PlugIns/HengeJITHelper.appex/HengeJITHelper" \
         "$APP/Frameworks/StikJIT.framework/StikJIT" "$APP/Frameworks/StikJIT.framework/Info.plist"; do
    if [ -f "$f" ]; then printf "  ok       %s\n" "${f#$APP/}"; else echo "  MISSING  ${f#$APP/}" >&2; rc=1; fi
done
[ $rc -eq 0 ] || { echo "==> bundle is not installable; refusing to package" >&2; exit 1; }

STAGE="$(mktemp -d "$DD/stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
ENT="$STAGE/entitlements.plist"
# HENGE_ENTITLEMENTS picks another file, as for xcodebuild (Henge/Henge.personal.entitlements for a free team).
cp "$IOS/${HENGE_ENTITLEMENTS:-Henge/Henge.entitlements}" "$ENT"
BANNED_KEYS=("com.apple.private.cs.debugger" "dynamic-codesigning" "com.apple.private.skip-library-validation")
if [ "$TROLLSTORE" = true ]; then for k in "${BANNED_KEYS[@]}"; do plutil -remove "$k" "$ENT" 2>/dev/null || true; done; fi
SAPP="$STAGE/Payload/Henge.app"
plutil -insert HengeBuildCommit -string "$(git -C "$IOS/.." rev-parse --short=12 HEAD 2>/dev/null || echo unknown)" "$SAPP/Info.plist"
plutil -insert HengeBuildDate -string "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SAPP/Info.plist"
# Apple's boot ROM is fetched on the device (BootROM.swift) and must never ship. An older build folder can still
# hold a copy from when the app bundled it, so it goes, and nothing is packaged if any is left.
rm -f "$SAPP/AVPBooter.vmapple2.bin"
if [ -n "$(find "$STAGE" -iname 'AVPBooter*' -o -iname 'AVPSEPBooter*')" ]; then
  echo "Apple's boot ROM is in the app: not packaging." >&2
  exit 1
fi
sign() { codesign --force --sign - --timestamp=none "$@"; }
for fw in "$SAPP"/Frameworks/*.framework; do [ -d "$fw" ] && sign "$fw"; done
for ex in "$SAPP"/PlugIns/*.appex; do [ -d "$ex" ] && sign "$ex"; done
sign --entitlements "$ENT" "$SAPP"
EMBEDDED=$(codesign -d --entitlements - "$SAPP" 2>&1 || true)
# Every key the entitlements file asks for must be in the signature.
for k in $(plutil -convert json -o - "$ENT" | python3 -I -c 'import json, sys; print(" ".join(json.load(sys.stdin)))'); do
    grep -q "$k" <<< "$EMBEDDED" || { echo "==> $k did not embed; refusing to package" >&2; exit 1; }
done
( cd "$STAGE" && zip -qry "$STAGE/package.tmp" Payload )
mv -f "$STAGE/package.tmp" "$OUT" # atomic: a half-written IPA never sits where the good one was
echo "==> $OUT ($(du -h "$OUT" | cut -f1))"
