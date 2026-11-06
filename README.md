# RespringSlide

A minimal iOS respring experiment with a full-screen, power-off-style slider and **two interchangeable skins**, chosen from a native Liquid Glass "…" picker in the top-right corner:

- **Liquid Glass** (default, "app attuale"): the current app — native SwiftUI `glassEffect` slider, bubble and buttons (iOS 26+).
- **OldOS** ("UI iOS 6"): a maniacally faithful iOS 6 recreation of the classic *slide to power off* screen — graphite OldOS/OldSafari palette, dark mode, glossy 2012 "sheet-metal" controls and Helvetica Neue typography, laid out full-screen on modern iOS/iPadOS devices. Built with the appearance kit (`OldOSKit` + `OldSafariPalette`) carried over code-for-code from the OldSafari project, so it matches that project's look exactly.

The `…` picker uses the identical native Liquid Glass material as the cancel (X) button, and the chosen skin is remembered across launches. Both skins drive the **same** behaviour (slide → confirm → run) and the **same** unchanged respring engine.

### Sections

The app has two sections behind a **native Liquid Glass bottom tab bar** (iOS 26+), in the style of the iOS Files app:

- **Respring** — the slide-to-power-off screen above.
- **Impostazioni** — settings: **Aspetto** (Sistema / Chiaro / Scuro), interface skin (Liquid Glass / OldOS), confirmation toggle, haptics toggle, slide threshold, reset, and app info. All settings persist and apply live.



- **UI:** Italian, black full-screen layout, Dynamic-Island-safe Liquid Glass respring capsule, screenshot-proportioned draggable power control, and bottom cancel/reset button. Dimensions scale from the supplied 709 × 1536 px reference (slider 591 × 168 px; thumb 144 × 144 px; cancel 144 × 144 px).
- **Glass:** SwiftUI `glassEffect` / interactive Liquid Glass controls (iOS 26+ SDK).
- **Engine:** local `WKWebView` document that reproduces the iframe/backdrop-filter/WebKit pressure technique associated with `jailbreak.party/respring`.
- **Build:** XcodeGen `project.yml` + GitHub Actions `.github/workflows/build.yml`.
- **Output:** unsigned `RespringSlide-unsigned.ipa` artifact.

## Important limitations

This is an experimental WebKit-triggered respring attempt, **not an Apple-supported API**. iOS does not expose a public API that lets an ordinary App Store app restart SpringBoard. Depending on the precise iOS build, device, WebKit process policy, and memory pressure, this technique may only terminate the WebContent process or app, may do nothing, or may cause SpringBoard to restart. It is not guaranteed on iOS 27.0.1 or other releases.

The embedded loop is only started after the user completes the slider and explicitly confirms. A 15-second watchdog stops the loop if SpringBoard has not restarted. Save open documents and data before testing. Do not use this as a substitute for a normal restart or a recovery method.

The IPA produced by this workflow is **unsigned**. It cannot be installed directly on a stock iPhone until signed with a valid certificate or an appropriate sideloading workflow. This repository does not contain certificates, provisioning profiles, or signing secrets.

## Build locally

Requirements: Xcode 27, iOS 26+ SDK, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate --spec project.yml
xcodebuild \
  -project RespringSlide.xcodeproj \
  -scheme RespringSlide \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  clean build
```

Package the app into an unsigned IPA:

```sh
mkdir -p staging/Payload
cp -R build/Build/Products/Release-iphoneos/RespringSlide.app staging/Payload/
(cd staging && zip -qry ../RespringSlide-unsigned.ipa Payload)
```

## Build on GitHub Actions

1. Create an empty repository on GitHub and upload/push this folder.
2. Push to `main`, create a pull request, or run **Actions → Build unsigned IPA → Run workflow**.
3. Open the completed workflow run and download the `RespringSlide-unsigned-ipa` artifact.
4. Push a tag such as `v1.0.0` to attach the IPA to a GitHub Release automatically.

Example first push:

```sh
git init -b main
git add .
git commit -m "Initial RespringSlide project"
git remote add origin https://github.com/USERNAME/RespringSlide.git
git push -u origin main
```

## Project structure

```text
.
├── .github/workflows/build.yml
├── RespringSlide/
│   ├── Assets.xcassets/AppIcon.appiconset/
│   ├── Theme/AppTheme.swift                 # skin enum + persisted store
│   ├── Support/OldOSKit.swift               # iOS 6 appearance kit (from OldSafari)
│   ├── Support/OldSafariPalette.swift       # iOS 6 colour palette (from OldSafari)
│   ├── Views/RootPowerView.swift            # container + "…" Liquid Glass picker + engine
│   ├── Views/LiquidGlassPowerOffView.swift  # Liquid Glass skin
│   ├── Views/OldOSPowerOffView.swift        # iOS 6 "slide to power off" skin
│   ├── Respring/RespringPayloadView.swift   # unchanged engine
│   └── RespringSlideApp.swift
└── project.yml
```

## Credits and references

- Original landing page: <https://jailbreak.party/respring> (the site is now closed).
- Public Swift implementation documenting the WebKit technique and attribution to neonmodder123: <https://github.com/rooootdev/mond/blob/main/mond/helpers/utils.swift>.
- Apple's documentation for the SwiftUI Liquid Glass API: <https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)>.

The UI is a SwiftUI recreation based on the supplied screenshot, not copied Apple source code. The control dimensions are proportionally scaled from that image, and the top capsule is intentionally placed in the safe area below the Dynamic Island. The project scaffold here is original. The experimental WebKit strategy is attributed to its upstream research; this repository does not claim that technique as original work.
