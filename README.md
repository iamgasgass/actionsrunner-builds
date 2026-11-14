<div align="center">

# 🗺️ GassMaps

**Il mondo reale in stile videogioco, con le funzioni di un navigatore vero.**

![iOS](https://img.shields.io/badge/iOS-26%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-5-orange?logo=swift)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI%20%C2%B7%20Liquid%20Glass-0A84FF)
![MapLibre](https://img.shields.io/badge/Mappa-MapLibre%20Native-396CB2)
![Build](https://img.shields.io/badge/IPA-non%20firmata-6E40C9)

</div>

GassMaps è un'app iOS (SwiftUI + MapLibre) che mostra la mappa reale in **13 temi ispirati ai videogiochi**,
con navigazione svolta per svolta, ricerca, percorsi alternativi e guida vocale in italiano.
L'interfaccia è interamente in **Liquid Glass nativo** di iOS 26.

---

## Indice

- [Temi](#-temi)
- [Funzioni](#-funzioni)
- [Impostazioni](#️-impostazioni)
- [Compilare l'IPA con GitHub Actions](#-compilare-lipa-con-github-actions)
- [Compilare in locale](#-compilare-in-locale)
- [Struttura del progetto](#-struttura-del-progetto)
- [Personalizzazione](#-personalizzazione)
- [Font della splash](#-font-della-splash)
- [Dati, licenze e limiti](#-dati-licenze-e-limiti)

---

## 🎨 Temi

Si scelgono dal **globo 3D** (pulsante 🌍): ogni tema ha la sua mappa, le sue icone dei luoghi, il suo globo e la sua splash.

| # | Tema | Stile |
|---|------|-------|
| 1 | Dust Valley | pergamena seppia western, edifici a inchiostro |
| 2 | **Vice Noir** *(predefinito)* | noir urbano scuro, strade a doppia linea, icone nere con contorno bianco |
| 3 | Bunker OS | terminale verde fosforescente, icone esagonali |
| 4 | Pixel Land | mondo a blocchi: erba, acqua e tetti pixelati, icone pixel art, freccia a blocchi |
| 5 | Neon District | nero con strade ciano, edifici 3D cremisi, icone esagonali |
| 6 | Palm Coast | campagna verde, città grigie, strade nere, icone colorate |
| 7 | Street Heat | satellite tinto di viola, strade grigio-azzurre |
| 8 | Old Kingdom | medievale, tetti di coppi in 3D |
| 9 | Silent Contract | mappa tattica grigia, icone quadrate nere |
| 10 | Storm Isle | isola cartoon: prati, boschi, fiumi con schiuma, sentieri di sabbia |
| 11 | Midnight Route | guida notturna indaco, edifici 3D blu, luoghi colorati per tipo |
| 12 | Crimson Heat | fondo antracite, quartieri a pennellate rosse bordati di nero, edifici 3D, strade e icone di Vice Noir |
| 13 | Canyon Run | notte da corse: quartieri a mimetico turchese bordati di nero, edifici 3D, icone gialle/blu/rosse |

> Gli stili sono ispirati ai videogiochi ma **disegnati da zero**: nessuna mappa, icona o grafica originale è inclusa.

---

## ✨ Funzioni

### Mappa
- **Verticale e orizzontale**: in orizzontale, come Google Maps, ricerca, schede e navigazione stanno in una colonna a sinistra e la mappa si centra nello spazio libero a destra
- Vista 3D inclinata (per tema), nomi delle vie, sensi unici, numeri civici, sigle stradali (SS18…)
- **Freccia della posizione** che segue la bussola da fermo e la direzione di marcia in movimento, con cono di precisione
- **Bussola** sempre visibile sotto *Livelli*: tacche, nord in rosso e lettera N / E / S / O; tocco per tornare al nord
- **Livelli**: tema o satellite, trasporti pubblici, piste ciclabili
- **Pulsante posizione** come Google Maps: centra → modalità bussola → nord in alto

### Ricerca
- Suggerimenti in tempo reale, cronologia, *Trova nelle vicinanze*, chip rapidi (Ristoranti, Benzina, Caffè…)
- **Ricerca vocale** in italiano, **ricerca per coordinate** (`40.85, 14.26`)
- *Cerca in questa zona* quando sposti la mappa sui risultati

### Luoghi
- Scheda del luogo con categoria, indirizzo, **Plus Code**, tempi in auto e a piedi, chiama, sito web, condividi
- Menu ••• : Casa, Lavoro, **parcheggio auto**, elenchi, **note personali**, **misura distanza**, copia coordinate
- **Elenchi** *Preferiti / Da visitare / Luoghi speciali* con filtri
- Tocco sulla freccia → **La tua posizione**: indirizzo, precisione, salva parcheggio, condividi, calibra bussola

### Indicazioni e navigazione
- Auto / A piedi / Mezzi, **percorsi alternativi**, evita pedaggi o autostrade, tappa intermedia, orario di partenza
- **Navigazione svolta per svolta**: freccia della manovra, “Poi…”, guida vocale, ricalcolo automatico, tachimetro
- Destra/sinistra **verificate sulla forma reale della strada** (rotonde comprese) e avvisi vocali in base alla velocità
- Vista con molta strada davanti, tratto percorso che sparisce, zoom secondo la velocità
- **Vista dall'alto**, **Riposiziona**, **percorsi alternativi durante la guida** (“4 min in più”, “Durata simile”)
- Cerca lungo il percorso, condividi l'orario di arrivo, funziona anche a schermo spento
- **Avatar di guida**: *Default* (freccia del tema) o *Alternative* (disco blu con freccia bianca)

### Posizione
- Core Location alla massima precisione, filtro anti-salti, precisione completa richiesta se è attiva quella approssimativa

---

## ⚙️ Impostazioni

Organizzate come Google Maps:

| Sezione | Contenuto |
|---------|-----------|
| App e display | tema, icona app, unità, bussola, scala, vista 3D, feedback aptico, accessibilità |
| Navigazione | voce, volume, velocità della voce, evita autostrade/pedaggi, tachimetro, schermo acceso, modalità predefinita |
| I tuoi veicoli | tipo di motore (con elettrico propone la ricarica), avatar di guida |
| Posizione e privacy | permessi, luoghi esplorati, parcheggio, cronologia, Casa/Lavoro, cancella i miei dati |
| Mappe offline | scarica la zona visibile, aggiorna, elimina, svuota cache |
| Notifiche | promemoria parcheggio, consigli settimanali |
| Informazioni e termini | versione, termini, privacy, note legali, valuta l'app, condividi, contatti |

---

## 📦 Compilare l'IPA con GitHub Actions

1. Carica **tutto** il contenuto della cartella nel repository, compresa la cartella nascosta **`.github`**.
2. Il workflow [`build.yml`](.github/workflows/build.yml) parte a ogni push su `main`
   (oppure da **Actions → Build unsigned IPA → Run workflow**).
3. A build verde scarica l'artifact **`GassMaps-unsigned-ipa`** → `GassMaps-unsigned.ipa`.
4. Firmala e installala con il tuo strumento (Sideloadly, AltStore, Feather, ESign, TrollStore…).
5. Con un tag `v1.0.0` l'IPA viene pubblicata anche come **Release**.

Se la compilazione fallisce il workflow **si ferma** (nessuna IPA rotta) e mostra gli errori nel riepilogo;
il log completo è nell'artifact **`xcodebuild-log`**.

**Requisiti:** runner `macos-26`, Xcode 26, iOS 26+ su iPhone.

---

## 💻 Compilare in locale

```bash
brew install xcodegen
xcodegen generate
open GassMaps.xcodeproj
```

---

## 🗂️ Struttura del progetto

```
GassMaps/
├── App/            avvio, stato dell'app, configurazione, font
├── Models/         temi, luoghi, percorsi
├── Services/       posizione, ricerca, percorsi, navigazione, ricerca vocale
├── Map/            mappa MapLibre, icone, texture, freccia, segnaposto
├── Globe/          globo 3D della selezione dei temi
├── Views/          schermate SwiftUI (mappa, pannelli, ricerca, impostazioni, splash)
├── Styles/         stili MapLibre generati (un file per tema + uno per il globo)
├── Fonts/          qui va il font della splash (non incluso)
└── Assets.xcassets icone dell'app e colori
tools/
├── generate_styles.py   genera gli stili dei temi
└── generate_icons.py    genera le icone dell'app
project.yml               progetto XcodeGen
.github/workflows/        build dell'IPA non firmata
```

---

## 🛠️ Personalizzazione

| Cosa | Dove |
|------|------|
| Link (Discord, privacy, termini, email) | `GassMaps/App/AppConfig.swift` |
| Colori e stile delle mappe | `tools/generate_styles.py` → poi `python3 tools/generate_styles.py` |
| Nomi, colori del globo, freccia e inclinazione dei temi | `GassMaps/Models/MapTheme.swift` |
| Icone dei luoghi per tema | `GassMaps/Map/MapIcons.swift` |
| Texture (pergamena, blocchi, mimetico…) | `GassMaps/Map/Textures.swift` |
| Icone dell'app | `tools/generate_icons.py` |

---

## 🔤 Font della splash

La scritta **GassMaps** usa il font *Pricedown*, che per licenza non può stare nel repository.
Scaricalo gratis da [Typodermic](https://typodermicfonts.com/pricedown/) e copia il file `.ttf`/`.otf` in `GassMaps/Fonts/`:
l'app lo trova da sola. Senza il file viene usato un sostituto simile.

---

## 📄 Dati, licenze e limiti

- Mappe: tile vettoriali gratuiti di [OpenFreeMap](https://openfreemap.org), dati © [OpenStreetMap](https://www.openstreetmap.org/copyright) contributors (ODbL; attribuzione sempre visibile con il pulsante ⓘ)
- Rendering: [MapLibre Native](https://maplibre.org)
- Ricerca, indirizzi e percorsi: Apple MapKit
- Satellite (Street Heat e livello *Satellite*): Esri World Imagery © Esri, Maxar, Earthstar Geographics — per un uso commerciale verifica i termini Esri

**Non disponibili** (dati non accessibili gratuitamente): traffico in tempo reale, Street View, corsie e limiti di velocità,
orari, recensioni e foto dei luoghi, percorsi dettagliati dei mezzi pubblici, condivisione della posizione in tempo reale, CarPlay.
Le mappe offline mostrano la mappa senza rete, ma ricerca e percorsi richiedono internet.

GassMaps è un progetto indipendente e non è affiliato ai produttori dei giochi a cui si ispirano i temi.
