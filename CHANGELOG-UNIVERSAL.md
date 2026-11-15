# WindowsiOS Universal — changelog

## 1.1.0 (2026-11-15)

Fork of `ammaarreshi/WindowsiOS` at `0071d69` (latest upstream commit), extended from the
iPhone Duo to every iPhone/iPad with an A14 / M1 chip or newer, following Henge's device rules.

- New `ios/Sources/Native/winios_device.{c,h}`: host profile (model, RAM, cores, FEAT_* flags),
  per-tier guest RAM / JIT size / vCPU recommendations, user overrides, chip check.
- `winios_jit.c`: guest RAM pre-allocation sized per device, 512 MB step-down, 1.5 GB kept for iOS.
- `winios_bridge.{h,m}`: JIT size and vCPUs from the profile; refuses to start on A13 and older with a
  clear message; Jetsam-safe fallback when ledger-exempt RAM is unavailable; device properties for Swift.
- `DeviceSupport.swift` (new): marketing names, hinge detection, settings sheet (RAM / vCPU).
- `VMViewModel.swift`, `HingeSensorView.swift`, `SessionView.swift`: laptop deck in portrait / Studio in
  landscape on phones without a hinge; device line + settings button on the boot card.
- `project.yml`, `Info.plist`, `WindowsiOS.entitlements`: no upstream team / profile, automatic signing,
  bundle ID `com.windowsios.universal`, generic microphone text, `increased-memory-limit` requested.
- Scripts: `launch_on_device.sh` (any UDID), `launch_on_duo.sh` alias, env-configurable UDID / bundle ID,
  `build_ios_deps.sh` without personal paths, libslirp patch vendored in `patches/` (from Husk, GPL-2.0+).
- CI: `.github/workflows/build-ipa.yml` builds an unsigned IPA.
