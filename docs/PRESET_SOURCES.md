# MobileGestalt preset catalog

The catalog is organized around user actions. Individual capabilities are not proof that the device has the required hardware, downloadable models or service eligibility. No device runtime validation was performed for these additions.

## Sources checked on 2026-11-16

- [Erosion](https://github.com/jailbreakdotparty/Erosion/blob/main/Erosion/Tweaks/MobileGestalt/GestaltStore.swift): combined iPad multitasking flags, existing hardware capabilities and US region pairs.
- [mond](https://github.com/rooootdev/mond/blob/main/mond/helpers/mg.swift): PWM capability, existing presets and experimental binary-patch behavior.
- [Nugget](https://github.com/leminlimez/Nugget/blob/main/src/tweaks/tweak_loader.py): baseline preset coverage and the distinction between MobileGestalt, SpringBoard preferences and feature flags.
- [GestaltX](https://github.com/huamidev/GestaltX/blob/main/GestaltX/Capabilities.swift): extended display, audio, intelligence and internal capability coverage; named region pairs.
- [MGKeys mappings](https://github.com/PoomSmart/MGKeys/blob/master/mapping.h) and [version data](https://github.com/PoomSmart/MGKeys/blob/master/keys_versions.py): independently cross-checked hashes, names and introduction versions for each added capability. Version data identifies when a key exists, not whether an override is effective on a particular device.

## Added coverage

| Group | Additions | Minimum system in GestAltX |
| --- | --- | --- |
| Display | HDR photos; Always-On flipbook widgets | iOS 26 |
| Display | High-luminance Always-On Display | iOS 27 |
| Hardware settings | Pulse-width maximization; DisplayPort output | iOS 26 |
| Audio | Audio Mix; FaceTime spatial audio playback | iOS 26 |
| Internal | Internal settings bundle | iOS 26 |
| Region | US, Hong Kong, Japan, mainland China, Taiwan, UK, Canada | iOS 26 |

Siri AI is a single setup action rather than a set of independent capability switches. Supported and unknown device regions retain their original region and regulatory-model fields. Unsupported iOS 27 devices temporarily spoof an eligible product/hardware/CPU identity for model setup. Only iOS 27 uses the two-stage flow and special backup; iOS 26 retains the original spoof/setup flow and ordinary backup. Based on the user’s device feedback, setup saves the ordinary timestamp-named full backup plus a specially named identity-restore snapshot before writing. The dedicated restore merges only the three original identity fields into the current plist, preserving SiriMode = 2, AI flags and later edits. Repeated setup reuses an earlier unspoofed identity baseline rather than capturing the spoof. This workflow has local regression coverage but has not been device-validated in this session. Only explicit mainland-China MG markers trigger a US device-region adjustment on iPhone/iPad. System region and Locale are not used to infer restrictions. It does not read or change Apple Account region, determine physical location, or establish server-side eligibility. Readback checks the exact pending region fields rather than requiring US values for every device. Independent region selection remains separate.

The seven previously added AI capability entries have been removed from the default catalog after the [AI preset research](AI_PRESET_RESEARCH.zh-CN.md). They are not silently bundled into Siri AI.

The iPadOS preset includes Stage Manager and iPad app compatibility. The individual options remain available inside a disclosure group. AOD vibrancy and brighter AOD remain optional rather than being forced with basic AOD.

On-device Siri understanding was not added as a Boolean switch: the existing capability is not uniformly Boolean across devices. SpringBoard suppression and unrelated preference-file tweaks are outside the MobileGestalt preset catalog. Arbitrary flipbook counts and additional binary internal-build patches were not added without device evidence.

## Validation

Run `xcrun swiftc GestAltX/GestaltModels.swift GestAltX/GestaltTweaks.swift GestAltX/GestaltBackupStore.swift Tests/GestaltPresets/main.swift -o /tmp/gestalt-preset-tests` and then `/tmp/gestalt-preset-tests`.

The checks cover bundle selection, mutually exclusive Glass settings, CacheData validation, atomic failure, OS-version boundaries, preservation of identity and unrelated bytes, binary-plist round-trip, catalog completeness and standalone region writes. An unsigned iOS build checks integration; it does not validate effects on a device.
