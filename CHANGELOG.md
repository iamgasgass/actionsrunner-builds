# Changelog — WindowsiOS X

Fork di [`ammaarreshi/WindowsiOS`](https://github.com/ammaarreshi/WindowsiOS) al commit `0071d69`.
Il dettaglio di ogni modifica è nella sezione 13 del [README](README.md#13-cronologia-completa-delle-modifiche).

## 1.2.0 — 2026-11-15
- Nuovo nome **WindowsiOS X**, bundle ID `com.iamgasgass.windowsiosx`, IPA `WindowsiOS-X.ipa`.
  Bundle ID diverso dalle build precedenti: vedi README §9 per spostare un Windows già installato.
- Disco **"WindowsiOS X Tools"** (D:, WINIOSTOOLS) a ogni avvio, con NetKVM e `Installa-driver.cmd`.
- Nuove installazioni: NetKVM con DISM (senza `/ForceUnsigned`, risultato a schermo) e con `pnputil` al primo accesso.
- README riscritto in modo completo; questo changelog.

## 1.1.0 — 2026-11-15
- **Installazione di Windows 11 sull'iPhone**, come Henge: catalogo Microsoft (38 ESD ARM64), download
  ripristinabile in HTTP con verifica SHA-1 o importazione da File, disco d'installazione costruito sul
  dispositivo (wimlib + FatFs), Windows PE automatico, setup non presidiato, opzione Lite, ripresa dopo la chiusura.
- CI: wimlib per iOS, firmware EDK2, NetKVM, `opt_hive_arm64.exe`, catalogo.
- Compilazione con l'Xcode più recente; sensore cerniera solo se l'SDK lo contiene.
- Icona dedicata (dall'icona di Husk, logo Windows a quadrati con morso e foglia).
- **Tutti gli iPhone A14+**: profilo del dispositivo (RAM, JIT, vCPU, controllo chip), memoria per Windows
  dimensionata per dispositivo, layout Laptop/Studio senza cerniera, impostazioni, firma generica, script per
  qualsiasi UDID, workflow GitHub Actions.
