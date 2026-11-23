#!/bin/bash
# After `xcodegen generate`: give ios-app/AppIcon.icon the Icon Composer file
# type, so Xcode's actool compiles it into the iOS 26 Liquid Glass icon
# (and keeps AppIcon.appiconset for iOS 17.4 - 25). An XcodeGen that doesn't
# know the type leaves it as a plain folder, which Xcode would just copy.
#
#   scripts/patch-xcodeproj.sh iLoaderX.xcodeproj
set -euo pipefail
pbx="${1:-iLoaderX.xcodeproj}/project.pbxproj"
[ -f "$pbx" ] || { echo "error: no $pbx" >&2; exit 1; }
grep -q 'path = AppIcon.icon;' "$pbx" || { echo "error: AppIcon.icon isn't in $pbx" >&2; exit 1; }
perl -pi -e 'if (/path = AppIcon\.icon;/) { s/(lastKnownFileType|explicitFileType) = [^;]+;/lastKnownFileType = folder.iconcomposer.icon;/ }' "$pbx"
grep -q 'lastKnownFileType = folder.iconcomposer.icon; .*path = AppIcon.icon;\|path = AppIcon.icon; .*lastKnownFileType = folder.iconcomposer.icon;' "$pbx" ||
  perl -pi -e 's/(\{isa = PBXFileReference; )(.*path = AppIcon\.icon;)/$1lastKnownFileType = folder.iconcomposer.icon; $2/' "$pbx"
grep -q 'AppIcon.icon in Resources' "$pbx" || { echo "error: AppIcon.icon isn't a resource of the app" >&2; exit 1; }
echo "==> AppIcon.icon: Icon Composer document"
