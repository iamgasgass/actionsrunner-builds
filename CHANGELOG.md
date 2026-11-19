# Changelog — macOSiOS X

Copia di **WindowsiOS X** (branch `claude/nice-johnson-xmx741`) con **macOS al posto di Windows 11**, sul motore
di [Henge](https://github.com/Leviidev/Henge) (branch `henge` di questo repository, commit `252f482`).
La cronologia del motore è in [docs/CHANGELOG-Henge.md](docs/CHANGELOG-Henge.md). Installazione, funzionamento
e limiti sono descritti nel [README](README.md).

## Non pubblicata

### Interfaccia come nel video di Huy Nguyen (macOS 27.2 sull'iPhone Duo piegato)
- Il deck sotto il Mac è ora quello del video: colore ardesia-lilla fino al bordo inferiore, maniglia, quattro
  pulsanti in alto a destra (tastiera, laptop, info, spegnimento rosso), tastiera MacBook con la **vera riga
  funzioni** (luminosità, Mission Control, Spotlight, dettatura, Non disturbare, ⏪ ⏯ ⏩, muto, volume, Touch ID)
  e un trackpad grande. La barra a capsula sopra il deck non c'è più.
- **Modalità Trackpad** dal pulsante laptop: barra degli strumenti sul deck e trackpad con *Click* / *Right-click*.
- Muto e volume vanno a macOS come tasti USB; luminosità regola lo schermo nell'app; Touch ID blocca lo schermo.
- Tolti i tasti funzione inventati della 1.0.0 (Finder, Safari, Terminale, blocco trascinamento, rotazione,
  Studio) e il layout solo-tastiera.

## 1.0.0 (102) — 2026-11-18

### Da WindowsiOS X, portato su macOS
- **Deck Laptop** (`ios/Henge/MacKeyboardDeck.swift`): in verticale, sotto lo schermo del Mac, la tastiera di un
  MacBook (Magic Keyboard, layout U.S. a 6 righe: fn/🌐, ⌃, ⌥, ⌘, frecce a T rovesciata con ↑↓ a mezza altezza)
  e il trackpad, al posto della tastiera Surface e del touchpad di WindowsiOS X. Tasti funzione con le azioni di
  macOS: Spotlight, Finder, Safari, Terminale, Mission Control, Scrivania, ⌘Tab, screenshot, blocco
  trascinamento, layout del deck, rotazione, Studio; con **fn** inviano F1–F12. Modificatori agganciati con spia,
  caps lock, cancella a destra. Layout **Laptop / Trackpad / Tastiera** da F10 o dalla barra.
- **Laptop e Studio**: verticale = Laptop, orizzontale = Studio a schermo intero; nuovo pulsante **Laptop** nella
  barra di Studio su iPhone.
- **Sensore cerniera dell'iPhone Duo** (`ios/Henge/HingeSensor.swift`): piegato a portatile → Laptop.
  Compilato solo se l'SDK ha `UIHingeInteraction` (`MACOSIOSX_HINGE`, prova in `package_ipa.sh`).
- **Riga del dispositivo** nella schermata *Macs*: `IPHONE 14 PRO · 6 GB · 3 GB / 5 VCPU` (modello, RAM, memoria
  proposta per un Mac, vCPU); tocca per le impostazioni.
- **Nome e identità**: *macOSiOS X*, bundle ID `com.iamgasgass.macosiosx`, versione 1.0.0 (102), team di firma
  da `MACOSIOSX_TEAM_ID`; tutti i testi visibili dell'app dicono macOSiOS X.
- **Icona** (`tools/icon/render_macos.py`): come quella di WindowsiOS X (dall'icona di Husk, con morso e foglia),
  ma con una finestra macOS e i tre "semafori" al posto dei quattro riquadri di Windows; chiara, scura e tinta.
- **CI** `.github/workflows/build-ipa.yml`: push su `main` e `claude/**`, tag `macosiosx-v*`, avvio manuale;
  Xcode più recente (beta comprese, `MACOSIOSX_XCODE` per fissarlo); produce **`macOSiOS-X.ipa`** e
  **`macOSiOS-X.tipa`**.
- **README in italiano** completo, con la stessa struttura di quello di WindowsiOS X.

### Sostituito da macOS (nulla di Windows rimane)
- Windows 11 ARM64 → **macOS** 13.6 – 27.2, installato con un **ripristino DFU** dai server di Apple al posto di
  WinPE/DISM/`unattend.xml`; firmware EDK2 → **boot ROM di Apple** scaricata e verificata; NetKVM e disco Tools →
  driver VirtIO di macOS, **cartella condivisa** e **appunti**; tablet USB → **Magic Trackpad 2**.

### Rimosso da Henge
- La sorgente AltStore di Leviidev (`repo.json`, `tools/update-source.py`) e la build Bitrise (`bitrise.yml`, `ci/`)
  di un fork: macOSiOS X si compila con il suo workflow.
