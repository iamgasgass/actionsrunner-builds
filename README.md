# RetroRemote

Telecomando Wi‑Fi per Smart TV con interfaccia **iOS 6** disegnata interamente a codice
(nessuna immagine esterna), **modalità scura** e layout **a tutto schermo** per gli iPhone moderni
(notch / Dynamic Island / home indicator).

## Funzioni

| | |
|---|---|
| **TV compatibili** | Roku (ECP, porta 8060) · Samsung Tizen 2016+ (WebSocket 8002/8001) · LG webOS (SSAP 3001/3000) |
| **Ricerca automatica** | scansione della sottorete Wi‑Fi /24 + aggiunta manuale per IP |
| **Telecomando** | accensione, input, muto, indietro/home/menu, croce direzionale con OK, bilancieri VOL/CH con ripetizione tenendo premuto, controlli multimediali |
| **Seconda pagina** | tastierino numerico, tasti colorati, guida, stop, info, exit |
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
