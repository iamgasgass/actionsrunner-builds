# Build dell'IPA di Andarium (GitHub Actions)

`.github/workflows/build.yml` produce `Andarium.ipa` completa (runtime Android, frameworks GPU,
system image LineageOS dentro l'app), non firmata con certificato: firmata ad hoc con
`Andarium/Config/Andarium.entitlements`, pronta per SideStore / AltStore / TrollStore.

## Cosa serve

Un runner macOS con **Xcode 27+** (il progetto Andarium è nel formato JSON di Xcode 27 e il
deployment target è iOS 27.0). Default `macos-26`; cambialo con la variabile `ANDARIUM_RUNNER`.

Artifact prebuilt **obbligatori** (non si possono costruire su GitHub):

| Artifact | Nome atteso (da questo commit) | Contenuto |
|---|---|---|
| Kernel Android | `android-6.18-arm64-4k-20261111-6.18.60-mc2` | `kernel-artifact.json`, `kernel/vmlinux`, ... |
| Release LineageOS 24 | `lineage24-mainline6.18-4k-20261110-los24-r22` | `release-manifest.json`, `guest/system.img` (anche `.zst/.xz/.gz`), ... |

Facoltativi (se mancano vengono compilati dal sorgente e messi in cache, la prima volta 1-3 h):

- i prefissi `.build/dependencies/apple-gpu-vulkan-experiment/ios-device-arm64`,
  `.build/dependencies/ios-device-arm64/network`, `.build/dependencies/ios-storage`, `.build/dependencies/ios-zstd`
  (usati solo se verificano contro `dependencies/manifest.tsv` di questo commit);
- oppure direttamente `.build/kernarium-xcframeworks` già impacchettato: salta runtime e dipendenze
  (il kernel allora non serve, è già dentro `KRuntime_Android_6_18_4K`).

## Come passarli

Archivi tar / tar.gz / tar.xz / tar.zst / zip / 7z, anche divisi in parti, con qualsiasi struttura
interna: il workflow li riconosce dal contenuto.

1. **Input `prebuilt`** di "Run workflow", oppure **variabile di repository `ANDARIUM_PREBUILT`**:
   ```
   https://example.com/kernel.tar.zst https://example.com/android.tar.zst
   https://host/a.tar.zst.001+https://host/a.tar.zst.002      # parti di un unico archivio
   gh-release:OWNER/REPO@prebuilt-1                           # tutti gli asset di una release
   gh-release:OWNER/REPO@prebuilt-1/android.tar.zst.*         # solo alcuni
   ```
   Per una repo privata aggiungi il secret `PREBUILT_TOKEN` (token con lettura su quella repo).
2. **Cartella `prebuilt/`** nella repo (archivi o cartelle già estratte). Attenzione: GitHub rifiuta
   file > 100 MB e `.gitignore` esclude `*.img`, quindi per la system image usa il punto 1.

Preparazione sul Mac che ha gli artifact:

```sh
tar -C .build/kernel/artifacts -cf - android-6.18-arm64-4k-20261111-6.18.60-mc2 | zstd -19 -T0 -o kernel.tar.zst
tar -C .build/android/releases -cf - lineage24-mainline6.18-4k-20261110-los24-r22 | zstd -19 -T0 --long=31 -o android.tar.zst
split -b 1900m -d -a 3 android.tar.zst android.tar.zst.      # un asset di release deve stare sotto i 2 GiB
gh release create prebuilt-1 kernel.tar.zst android.tar.zst.0* --repo OWNER/REPO
```

poi `ANDARIUM_PREBUILT = gh-release:OWNER/REPO@prebuilt-1`.

## Risultato

- Artifact del workflow `Andarium-<versione>-<build>-Release` con `Andarium.ipa` e lo SHA-256.
- Con `release: true` (o un push di tag `v1.0`) anche una GitHub Release; se l'IPA supera 2 GiB viene
  pubblicata in parti: `cat Andarium.ipa.0* > Andarium.ipa`.

Input utili: `configuration` (`Release` = runtime con JIT per sideload, `AppStore` = runtime App Store
con tutti i controlli del bundle), `xcode` (versione precisa), `rebuild_dependencies` (ignora la cache).
