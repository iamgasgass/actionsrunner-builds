# Changelog — Henge X

Copia di **WindowsiOS X** (branch `claude/nice-johnson-xmx741`) con **macOS al posto di Windows 11**, sul motore
di [Henge](https://github.com/Leviidev/Henge) (branch `henge` di questo repository, commit `252f482`).
La cronologia del motore è in [docs/CHANGELOG-Henge.md](docs/CHANGELOG-Henge.md). Installazione, funzionamento
e limiti sono descritti nel [README](README.md).

## Non pubblicata

### Henge ALT come il video, modalità chiara originale, Xcode 27.2
- **Henge ALT**: tastiera ricostruita dal fotogramma più nitido del video, misurando il profilo di un tasto pixel per
  pixel: tasti **illuminati dall'alto** (linea chiara sul bordo superiore, corpo che sfuma dal grigio medio al grigio
  scuro, leggero riflesso sul bordo inferiore, fessura scura), tastiera in un **pozzetto più scuro con bordo chiaro**,
  simboli **piccoli, in grassetto e tutti centrati** anche sui tasti larghi (`⇥ tab`, `⇪ caps lock`, `⇧ shift`,
  `delete`, `↩ return`, `⌃ control`, `⌥ option`, `⌘ command`), trattini su F e J, icone piccole nella riga funzioni;
  trackpad ardesia smorzato. Lo **sfondo del deck è quello di Henge X** (non più viola/lilla).
- **Aspetto Light**: gli sfondi scuri della sessione (che resta scura) e del deck sono esattamente quelli del progetto
  originale Henge (`#0B0C10`, schede `#16181F`, rilievi `#23262F`); con Dark o System restano quelli neri di iOS.
- **Compilazione con Xcode 27.2 e SDK iOS 27.2** sul runner `xcode-27` di GitHub; la build fallisce se l'SDK non è
  27.2. Il sensore cerniera dell'iPhone Duo ora viene compilato.

### Impostazioni › macOS Deck
- *Henge X*: il deck attuale (colori della modalità scura di iOS, tasti quasi neri nel pozzetto scuro, trackpad grigio,
  strumenti nella capsula). *Henge ALT*: il deck com'era nel video di macOS 27.2 sull'iPhone Duo (commit `d6267c0`):
  ardesia-lilla, tasti direttamente sul deck, trackpad viola, strumenti senza capsula; con il centramento corretto
  della barra a 7 pulsanti. Vale subito; le proporzioni restano quelle di *Aspect*.

### Proporzioni come WindowsiOS X
- **Impostazioni › Aspect**: *Henge classic* (il layout esattamente com'era prima delle nuove proporzioni: schermo a
  tutta larghezza in alto, tastiera limitata dalla larghezza, trackpad grande) o *Henge X* (le proporzioni nuove, predefinite).
- In verticale lo schermo ha un **pannello nero fino a metà altezza (49%)**, come il display di WindowsiOS X; il deck
  inizia sotto. La **tastiera prende il 62,5% del deck** e il **trackpad il resto**, largo max(246, 56%) punti come in
  WindowsiOS X (prima la tastiera era limitata dalla larghezza e il trackpad prendeva tutto lo spazio rimasto).
- Nuovo formato schermo **Laptop** (impostazioni del Mac › Screen, su iPhone): una risoluzione con la forma del
  pannello (1600 di larghezza), così macOS lo riempie invece di stare al centro con il nero sopra e sotto.

### Henge X
- Nuovo nome **Henge X** ovunque: nome dell'app, testi, JIT helper, IPA `Henge-X.ipa` / `Henge-X.tipa`, variabili
  `HENGEX_TEAM_ID`, `HENGEX_XCODE`, `HENGEX_HINGE`, tag di release `hengex-v*`, documentazione, e **bundle ID
  `com.iamgasgass.hengex`** (era `com.iamgasgass.macosiosx`). Per iOS è un'app nuova: un Mac installato con le build
  precedenti va esportato dalla vecchia app e importato nella nuova (README §9).
- **Modalità scura come quella di iOS, con il nero vero**: sfondo `#000000`, schede `#1C1C1E`, parti in rilievo `#2C2C2E`,
  testo bianco, grigi di sistema; vale con *Dark* e con *System* quando iOS è scuro.
- **Colore di accento viola, quello dell'icona** (pulsanti, schede, interruttori, link), al posto del blu.
- **Icona**: la finestra macOS occupa ora il 64% della larghezza dell'icona (era il 50%).
- **SDK più recente**: la CI legge la versione reale di ogni Xcode presente sul runner (dal suo `Info.plist`, non dal
  nome della cartella), sceglie la più alta (beta comprese; a pari versione vince la release) e scrive nel riepilogo
  della run l'elenco degli Xcode con i loro SDK iOS e quello usato. `HENGEX_XCODE` fissa una versione.

### Motore più veloce
- **Statistiche diagnostiche spente di default** (`HV_STATS=0` in `EngineTuning.swift`). Erano sempre accese:
  ogni vCPU scriveva decine di contatori nella struttura condivisa della macchina e, per la ripartizione degli
  accessi lenti, rifaceva una scansione della tabella delle pagine in più su certi accessi lenti alla memoria e sui
  mancati colpi della cache dei salti indiretti. Per riattivarle: `HV_STATS=10` in `Documents/henge-env.txt`.
- **Niente più scritture condivise sui percorsi caldi**: il contatore dei blocchi e l'anello di debug del
  dispatcher, i contatori e l'anello delle eccezioni, e i contatori di cambi di contesto, svuotamenti del TLB e
  page walk delle istruzioni (macro `HV_COUNT`) si aggiornano solo con le statistiche o il log accesi. Prima ogni
  vCPU li scriveva a ogni passaggio, e la stessa riga di cache rimbalzava tra i core. Il contatore "blocks/s"
  dell'app ora somma i contatori per-CPU (`icount`).
- **Motore compilato per A14** (`-mcpu=apple-a14`, solo `core/` e `devices/`): atomiche LSE (CAS, LDADD) al posto
  dei cicli LDXR/STXR e scheduling per i core Apple. Il resto dell'app resta generico, quindi su un iPhone più
  vecchio l'app si apre ancora e mostra il messaggio "needs an A14".
- CI: job `engine-tests` che compila ed esegue i test del motore su Apple silicon a ogni push.

### Interfaccia come nel video di Huy Nguyen (macOS 27.2 sull'iPhone Duo piegato)
- Il deck sotto il Mac è ora quello del video: fino al bordo inferiore, maniglia, quattro
  pulsanti in alto a destra (tastiera, laptop, info, spegnimento rosso), tastiera MacBook con la **vera riga
  funzioni** (luminosità, Mission Control, Spotlight, dettatura, Non disturbare, ⏪ ⏯ ⏩, muto, volume, Touch ID)
  e un trackpad grande. La barra a capsula sopra il deck non c'è più.
- Colori identici alla 1.0.0: sfondo del deck nei colori della modalità scura di iOS (#1C1C1E → nero), tasti quasi neri nel pozzetto scuro, trackpad
  grigio; barra degli strumenti e pannello del trackpad con i colori di Henge (`Desk`).
- Deck centrato: la barra degli strumenti a 7 pulsanti non è più larga dello schermo (spingeva il deck a destra).
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
  Compilato solo se l'SDK ha `UIHingeInteraction` (`HENGEX_HINGE`, prova in `package_ipa.sh`).
- **Riga del dispositivo** nella schermata *Macs*: `IPHONE 14 PRO · 6 GB · 3 GB / 5 VCPU` (modello, RAM, memoria
  proposta per un Mac, vCPU); tocca per le impostazioni.
- **Nome e identità**: *Henge X*, bundle ID `com.iamgasgass.macosiosx`, versione 1.0.0 (102), team di firma
  da `HENGEX_TEAM_ID`; tutti i testi visibili dell'app dicono Henge X.
- **Icona** (`tools/icon/render_macos.py`): come quella di WindowsiOS X (dall'icona di Husk, con morso e foglia),
  ma con una finestra macOS e i tre "semafori" al posto dei quattro riquadri di Windows; chiara, scura e tinta.
- **CI** `.github/workflows/build-ipa.yml`: push su `main` e `claude/**`, tag `hengex-v*`, avvio manuale;
  Xcode più recente (beta comprese, `HENGEX_XCODE` per fissarlo); produce **`Henge-X.ipa`** e
  **`Henge-X.tipa`**.
- **README in italiano** completo, con la stessa struttura di quello di WindowsiOS X.

### Sostituito da macOS (nulla di Windows rimane)
- Windows 11 ARM64 → **macOS** 13.6 – 27.2, installato con un **ripristino DFU** dai server di Apple al posto di
  WinPE/DISM/`unattend.xml`; firmware EDK2 → **boot ROM di Apple** scaricata e verificata; NetKVM e disco Tools →
  driver VirtIO di macOS, **cartella condivisa** e **appunti**; tablet USB → **Magic Trackpad 2**.

### Rimosso da Henge
- La sorgente AltStore di Leviidev (`repo.json`, `tools/update-source.py`) e la build Bitrise (`bitrise.yml`, `ci/`)
  di un fork: Henge X si compila con il suo workflow.
