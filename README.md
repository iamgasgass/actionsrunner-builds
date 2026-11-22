# CarPlay Sim

Simulatore dell'interfaccia di un'unità di bordo in stile CarPlay, scritto in SwiftUI,
pensato per girare dentro **LiveContainer** (o installato con SideStore/AltStore/TrollStore).

> Progetto non ufficiale, non affiliato né approvato da Apple. "CarPlay" è un marchio di Apple Inc.
> L'app **non** usa il framework CarPlay (che richiede entitlement Apple e un'auto vera):
> ricrea l'esperienza a schermo intero sul tuo iPhone/iPad.

## Funzioni

| App | Cosa fa |
|---|---|
| **Dashboard** | Mappa live, widget "In riproduzione", meteo e prossimo evento |
| **Mappe** | Ricerca luoghi (MapKit), percorsi alternativi, navigazione con GPS reale **o guida simulata** lungo il percorso (velocità ×1…×20) con indicazioni svolta per svolta |
| **In riproduzione** | Copertina, avanzamento, controlli, volume di sistema |
| **Musica** | Libreria Musica di iOS (playlist, album, casuale) + brani demo |
| **Radio** | Radio in streaming reale (SomaFM, Radio Paradise) con titolo del brano in diretta |
| **Telefono** | Preferiti, recenti, tastiera, schermata di chiamata (passa la chiamata a iOS con `tel://`) |
| **Messaggi** | Conversazioni di esempio, lettura ad alta voce, risposte rapide |
| **Calendario / Meteo** | Dati dimostrativi, "portami lì" dagli eventi |
| **Assistente vocale** | Riconoscimento vocale in italiano + sintesi vocale. Se il microfono non funziona (frequente in LiveContainer) puoi scrivere il comando |
| **Impostazioni** | Risoluzione schermo simulato (800×480, 1280×720, 1440×540, 1920×720 o adatta), cornice, guida a destra, tema, sfondi, velocità simulazione |

Comandi vocali di esempio: *"portami al Colosseo"*, *"metti la radio"*, *"radio groove salad"*,
*"prossimo brano"*, *"pausa"*, *"chiama Marco"*, *"leggi i messaggi"*, *"che tempo fa"*,
*"quanto manca"*, *"termina navigazione"*, *"apri impostazioni"*.

Il tasto in basso nella barra laterale alterna **Home ↔ Dashboard**; le tre icone sopra sono le app recenti.

## Ottenere l'IPA unsigned (GitHub Actions)

1. Crea un nuovo repository su GitHub e carica il contenuto di questo zip (incluse le cartelle nascoste `.github/`).
2. Vai su **Actions** → abilita i workflow se richiesto.
3. Il workflow **Build unsigned IPA** parte a ogni push (oppure avvialo a mano con **Run workflow**).
4. A fine build scarica l'artifact **CarPlaySim-unsigned-ipa** (uno zip che contiene `CarPlaySim.ipa`).
5. Facoltativo: crea un tag `v1.0.0` (`git tag v1.0.0 && git push --tags`) e l'IPA verrà allegata a una Release.

Il workflow usa `macos-latest`, l'ultima Xcode stabile, genera il progetto con **XcodeGen** da `project.yml`
e compila con `CODE_SIGNING_ALLOWED=NO`, poi impacchetta `Payload/CarPlaySim.app` in `CarPlaySim.ipa`.

## Installazione in LiveContainer

1. Apri LiveContainer → **+** → seleziona `CarPlaySim.ipa`.
2. Avvia "CarPlay Sim" e ruota il telefono in orizzontale.
3. Concedi posizione (Mappe), microfono e riconoscimento vocale (assistente) e libreria musicale se vuoi.

Note su LiveContainer:
- I permessi vengono chiesti a nome di LiveContainer; se un permesso era già stato negato, abilitalo
  per LiveContainer nelle Impostazioni di iOS.
- Il riconoscimento vocale e l'accesso alla libreria Musica potrebbero non funzionare in alcune
  configurazioni: in quel caso usa il campo di testo dell'assistente e i brani Demo/Radio.
- La musica continua in background solo se LiveContainer lo consente.

## Compilare in locale (macOS)

```bash
brew install xcodegen
xcodegen generate
open CarPlaySim.xcodeproj
```

## Struttura

```
.github/workflows/build.yml   # CI: genera progetto, compila, crea IPA unsigned
project.yml                   # definizione XcodeGen (target, Info.plist, impostazioni)
CarPlaySim/
  App/                        # entry point SwiftUI
  Models/                     # stato, media, navigazione, assistente vocale, dati demo
  Views/                      # schermo auto, dock, home, dashboard, overlay assistente
  Views/Apps/                 # Mappe, Musica, Radio, Telefono, Messaggi, Calendario, Meteo, Impostazioni
  Resources/Assets.xcassets   # icona e colore d'accento
```

Requisiti: iOS 16.0 o successivo.
