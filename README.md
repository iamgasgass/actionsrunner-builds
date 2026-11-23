<div align="center">

<img src="docs/icon.png" alt="iLoader X" width="120" />

# iLoader X

**Install SideStore and LiveContainer directly on your iPhone. No PC required.**

Bundle ID `com.iamgasgass.iloaderx` · iOS 17.4+ (iOS 27 pairs with itself)

[![Install](https://img.shields.io/badge/Install-iLoader%20X-AC1A32?style=for-the-badge)](https://iamgasgass.github.io/iLoaderX/)
[![Release](https://img.shields.io/github/v/release/iamgasgass/iLoaderX?style=for-the-badge&color=AC1A32)](https://github.com/iamgasgass/iLoaderX/releases/latest)
[![License](https://img.shields.io/badge/license-SideInstaller%20License-orange?style=for-the-badge)](LICENSE.md)

</div>

---

iLoader X is a fork of **[SideInstaller by FrizzleM](https://github.com/FrizzleM/SideInstaller)**
(version 2.1.1, commit `141d7ee`), redistributed in source form under its
[licence](LICENSE.md). Everything that does the work (on-device pairing,
provisioning, signing and installing SideStore, LiveContainer and other IPAs)
is SideInstaller's; iLoader X gives it its own name, bundle ID and icon.

> [!IMPORTANT]
> iLoader X is **not** the official SideInstaller and is not affiliated with FrizzleM.
> For the original app, go to <https://github.com/FrizzleM/SideInstaller>.
> Problems with this fork belong in this repository's issues, not in SideInstaller's.

## Install

**Install page: <https://iamgasgass.github.io/iLoaderX/>** — add the source to
SideStore or AltStore, install in LiveContainer or TrollStore, or download the IPA.

| | |
|---|---|
| AltStore / SideStore source | `https://iamgasgass.github.io/iLoaderX/iloaderx.json` |
| Latest IPA (unsigned) | <https://github.com/iamgasgass/iLoaderX/releases/latest/download/iLoaderX.ipa> |

Then connect [LocalDevVPN](https://apps.apple.com/app/id6755608044), pair (iOS 27
pairs with itself; iOS 17.4 – 26 imports a pairing file made on a computer), sign
in with your Apple ID and install SideStore or LiveContainer from the Install tab.

## The icon

Drawn from scratch for iLoader X: a garnet rounded “L” with a download arrow landing on
a tray in the notch. Two looks, each with every appearance iOS asks for; the app's tool
tiles (Apps, Certificates, Downloads, Entitlements, Location, Pairing, Side by Side) are
drawn in the same glass design (`tools/icon/tools.mjs`), and the whole app is garnet
(`ios-app/Theme.swift`, `AccentColor`):

<img src="docs/icon-variants.png" alt="iLoader X icon variants" width="100%" />

| | Where | Variants |
|---|---|---|
| **Liquid Glass** (primary) | `ios-app/AppIcon.icon` (Icon Composer, iOS 26+) | Default, Dark, Clear light, Clear dark, Tinted light, Tinted dark: drawn by the system from three glass layers (L, arrow, tray) in two groups, each with its own fill per appearance |
| | `ios-app/Assets.xcassets/AppIcon.appiconset` (iOS 17.4 – 25) | every iPhone, iPad, CarPlay and App Store size; Dark and Tinted (iOS 18+) |
| **iOS 6** (alternate) | `ios-app/Assets.xcassets/AppIcon-iOS6.appiconset` | linen backdrop, beveled garnet gel “L”, embossed gunmetal arrow, the gloss arc baked in; every size, plus Dark (chrome arrow on charcoal) and Tinted |

Switch between them in **Settings › App Icon**. The artwork is generated from
code, so it can be regenerated at any size:

```sh
node tools/icon/render.mjs build/icon        # masters + Icon Composer layers + preview sheet (Playwright/Chromium)
python3 tools/icon/build_assets.py build/icon # asset catalog sets, AppIcon.icon, docs/
```

## Building

iLoader X builds with **Xcode 27.2 and the iOS 27.2 SDK**, with Rust (`aarch64-apple-ios`) and `xcodegen`:

```sh
scripts/build-ipa.sh     # → build/iLoaderX.ipa, unsigned
```

On GitHub, `.github/workflows/build.yml` (modelled on Henge X's `build-ipa.yml`) runs on
GitHub's **`xcode-27`** image (macOS 27):

| Trigger | What it does |
|---|---|
| push to `main` or `claude/**` | builds `iLoaderX.ipa` and `iLoaderX.tipa` (TrollStore, ad hoc signed), kept as artifacts |
| push of a tag `v1.0.0` | the same, plus release `v1.0.0` with both files, the AltStore/SideStore source updated and the install page redeployed |
| Actions › Build IPA › Run workflow | the same from the branch you pick; tick **release** (with a version and notes) to publish |

The Xcode step lists every Xcode on the runner, picks 27.2 and fails if the iOS SDK isn't 27.2;
the repository variables `ILOADERX_XCODE` and `ILOADERX_IOS_SDK` change them (e.g. to a newer
27.x when GitHub adds it). `checks.yml` (Rust tests, simulator build, translations) runs on the same
image; `pages.yml` publishes `site/` to GitHub Pages (Settings › Pages › Source: **GitHub Actions**).

## What this fork changes

Compared with SideInstaller 2.1.1 (`141d7ee`), as its licence asks:

- **Name**: “iLoader X” everywhere the app shows its name, in all ten languages
  (product/target `iLoaderX`, `iLoaderXTests`, `iLoaderXLiveActivity`; the
  pairing name in Settings › Developer Mode and the certificate's machine name
  are “iLoader X”).
- **Identifiers**: bundle ID `com.iamgasgass.iloaderx` (Live Activity
  `.LiveActivity`, tests `.tests`); URL scheme `iloaderx://`; document types
  `com.iamgasgass.iloaderx.ipa` / `.mobiledevicepairing`; keychain service
  `com.iamgasgass.iloaderx.appleID`. It installs beside SideInstaller and shares
  nothing with it.
- **Icon**: new artwork, Liquid Glass primary and iOS 6 alternate (above), the
  in-app logo, and a Settings › App Icon picker (`ios-app/AppIconPicker.swift`).
- **Links**: update banner, Side by Side, problem reports, source-code link and
  terms use `iamgasgass/iLoaderX` and its install page, not FrizzleM's.
- **Official-source check**: points to iamgasgass.github.io/iLoaderX instead of
  sideinstaller.net.
- **Install page and source**: `site/` (install page in English and Italian, terms,
  AltStore/SideStore source `iloaderx.json`) replaces sideinstaller.net and
  `frizzlem.json`.
- **About**: links this fork's source and credits SideInstaller by FrizzleM.
- **Removed** what only the official SideInstaller publishes: the
  sideinstaller.net pages, the AltSource (`frizzlem.json`), the DNS profile, and
  the release/signing/Pages workflows. Added `build.yml`, `pages.yml`,
  `scripts/update_source.py` and
  `scripts/patch-xcodeproj.sh` (marks `AppIcon.icon` as an Icon Composer file
  after `xcodegen`).
- Internal names that never show (the Rust core, `SideInstallerFFI`, Swift type
  names) are unchanged, so upstream changes merge cleanly.

## Licence

[SideInstaller License](LICENSE.md), © 2026 FrizzleM: non-commercial; source
redistribution with this licence, attribution and the changes listed above. iLoader X
is not sold or monetized in any way.
