# RetroRemote

Telecomando Wi‑Fi per Smart TV con **due interfacce** selezionabili dal menu **«…»**:

- **Liquid Glass** — superfici di vetro (`UIGlassEffect` su iOS 26, materiale traslucido su iOS 15–18),
  controlli e tabelle di sistema;
- **iOS 6** — interfaccia scheuomorfica disegnata interamente a codice (nessuna immagine esterna).

Entrambe hanno **modalità scura** (Automatico / Chiaro / Scuro) e layout **a tutto schermo** per gli
iPhone moderni (notch / Dynamic Island / home indicator).

## Schermata principale

- Testata con la TV corrente e lo stato (tocca per scegliere un'altra TV), menu «…» e pulsante
  **«Tocca per connetterti»** quando la TV non è connessa.
- Cinque modalità nella barra in basso: **Tasti**, **Touchpad**, **Numeri**, **App**, **Testo**.
- Riga di **app rapide** configurabile (fino a 3) sotto tasti, touchpad e tastierino.
- Menu «…»: scegli TV, ricerca vocale, connetti/disconnetti, accendi (Wake‑on‑LAN),
  **Interfaccia** (Liquid Glass / iOS 6), **Aspetto** e Impostazioni.

## Funzioni

| | |
|---|---|
| **Samsung** | Tizen 2016+ (WebSocket 8002/8001), tastiera, app, accensione Wake‑on‑LAN |
| **LG** | webOS (SSAP 3001/3000), tastiera, app, touchpad come mouse, Wake‑on‑LAN |
| **Roku** | Roku e Roku TV (TCL, Hisense, Sharp…) via ECP 8060, tastiera, app |
| **Android TV / Google TV** | Sony, Philips, TCL, Hisense, Xiaomi, Sharp, Nvidia Shield, Chromecast con Google TV: protocollo Android TV Remote v2 (TLS 6466/6467) con associazione tramite codice |
| **Amazon Fire TV** | Fire TV Stick/Cube/Edition via ADB (TCP 5555): tasti, tastiera, elenco e avvio app |
| **VIZIO** | SmartCast (HTTPS 7345/9000) con PIN |
| **Panasonic** | Viera 2012–2018 (SOAP 55000) |
| **Ricerca automatica** | scansione della sottorete Wi‑Fi /24 su tutte le porte note + nomi via Bonjour, oppure aggiunta manuale per IP |
| **Telecomando** | accensione, input, muto, indietro/home/menu, croce direzionale con OK, bilancieri VOL/CH con ripetizione tenendo premuto, controlli multimediali |
| **Testo** | digitazione dal vivo (ogni lettera arriva subito alla TV), cancella, invio, dettatura |
| **Touchpad** | scorri = frecce, tocco = OK, due dita = Indietro, tieni premuto = Menu; modalità mouse su LG |
| **App rapide** | Netflix, YouTube, Prime Video, Disney+ con un tocco |
| **Ricerca vocale** | dettatura in italiano inviata alla TV (su Android TV apre la ricerca di YouTube) |
| **Tasti volume iPhone** | i tasti laterali regolano il volume della TV |
| **Cambio rapido** | tocca il titolo per passare da una TV all'altra |
| **Terza pagina** | tastierino numerico, tasti colorati, guida, stop, info, exit |
| **Tastiera** | invio di testo alla TV |
| **App** | elenco e avvio delle app installate sulla TV, con icone lucide stile iOS 6 |
| **Impostazioni** | Aspetto Automatico/Chiaro/Scuro, vibrazione, clic dei tasti, schermo intero, schermo sempre attivo |

## Interfaccia iOS 6

Tutto è disegnato con Core Graphics in `RetroRemote/UI`:

- navigation bar blu‑grigia con titolo in rilievo e pulsanti a "freccia indietro";
- tab bar nera lucida con icone a gradiente blu e alone sulla scheda attiva;
- tabelle raggruppate su sfondo *pinstripe*, celle con angoli arrotondati, chevron grigio,
  spunta blu e pulsante di dettaglio blu rotondo;
- interruttori "SÌ / NO", alert blu traslucidi con animazione "pop", pulsante rosso "Elimina";
- superficie del telecomando in alluminio spazzolato (chiaro) o lino scuro (scuro).

**Modalità scura:** `ThemeManager` ha due palette complete (`Palette.light` / `Palette.dark`).
In "Automatico" segue iOS; ogni componente si ridisegna da solo quando cambia il tema.

**Tutto schermo:** la navigation bar si estende sotto la barra di stato, la tab bar fino al bordo
inferiore. L'opzione "Schermo intero" nasconde anche la barra di stato.

## Build

Il progetto Xcode è generato da [XcodeGen](https://github.com/yonaskolb/XcodeGen) partendo da `project.yml`.

```bash
brew install xcodegen
xcodegen generate
open RetroRemote.xcodeproj
```

### GitHub Actions

`.github/workflows/build.yml` genera il progetto, compila senza firma su `macos-15` e
carica `RetroRemote.ipa` come artifact. Se fai il push di un tag `v*` (per esempio `v1.0.0`),
l'IPA viene allegato anche a una Release. L'IPA non è firmato: installalo con AltStore,
SideStore, TrollStore o firmalo con il tuo certificato.

Requisiti: iOS 15+, iPhone e iPad (solo verticale).

## Note sui protocolli

- **Roku:** sulla TV attiva *Impostazioni › Sistema › Impostazioni di sistema avanzate › Controllo da app mobili*.
- **Samsung:** alla prima connessione la TV chiede di autorizzare "RetroRemote"; il token viene salvato.
- **LG:** alla prima connessione accetta la richiesta sulla TV; la chiave client viene salvata.
  Alcuni firmware webOS recenti limitano il socket "pointer" ai client firmati: in quel caso
  volume, canali, multimedia, app e accensione funzionano, mentre le frecce potrebbero non rispondere.
- La rete locale richiede il permesso "Rete locale" di iOS (richiesto al primo avvio).

- **Android TV:** alla prima connessione la TV mostra un codice di 6 caratteri da inserire nell'app.
  L'app genera una chiave RSA e un certificato client salvati nel portachiavi.
- **Fire TV:** attiva *Impostazioni › La mia Fire TV › Opzioni sviluppatore › Debug ADB*, poi accetta
  la richiesta "Consentire il debug USB?" sulla TV (spunta "Consenti sempre").
- **VIZIO:** inserisci il PIN mostrato sulla TV.
- **Wake‑on‑LAN:** iOS può bloccare i pacchetti broadcast senza l'entitlement multicast di Apple; l'app
  prova comunque broadcast e unicast. Roku e le Android TV di solito si accendono anche con il tasto Power.

## Icona

`scripts/generate_icon.py` (Pillow) rigenera `AppIcon.png`.

## Struttura

```
RetroRemote/
  App/          AppDelegate, SceneDelegate
  Theme/        palette chiaro/scuro, helper di disegno, texture generate
  UI/           componenti iOS 6 disegnati a mano
  Controllers/  schermate (Telecomando, App, Dispositivi, Dettaglio, Impostazioni)
  Core/         modelli, archivio dispositivi, preferenze, scansione di rete
  TV/           controller Roku, Samsung, LG
```
