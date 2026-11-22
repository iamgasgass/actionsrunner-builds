# CarPlayss

Simulatore CarPlay per iOS, pensato per **LiveContainer**: riproduce l'interfaccia di un'unità
CarPlay sullo schermo del telefono/iPad e **installa ed esegue app CarPlay reali da file IPA**,
mostrandone i template come farebbe l'auto.

- Bundle ID: `com.iamgasgass.carplayss`
- iOS 16.0 o successivo, solo orizzontale

> Progetto non ufficiale, non affiliato né approvato da Apple. "CarPlay" è un marchio di Apple Inc.
> Le icone e gli sfondi sono originali: non vengono usate risorse grafiche di Apple.

## Interfaccia

- **Barra di stato laterale** con ora, rete, 3 app recenti e tasto Home
  (tocco: Home ↔ Dashboard, pressione prolungata: assistente vocale). Con "Guida a destra" passa a destra.
- **Home** a pagine con indicatore di pagina, app integrate + app installate.
- **Dashboard** con mappa, In riproduzione, meteo e prossimo evento.
- App integrate: Mappe (ricerca, percorsi, guida simulata), In riproduzione, Musica, Radio, Telefono,
  Messaggi, Calendario, Meteo, Impostazioni.
- Risoluzioni dell'unità simulate: 800×480, 1280×720, 1440×540, 1920×720 o adatta allo schermo.

## App CarPlay installabili

Impostazioni → **App CarPlay** → **Installa IPA** (oppure "Apri con CarPlayss" da File).

Vengono accettate **solo** app compatibili con CarPlay:
- scena `CPTemplateApplicationSceneSessionRoleApplication` nell'Info.plist, oppure
- entitlement `com.apple.developer.carplay-*` (audio, comunicazione, navigazione, parcheggi, ricarica, carburante, ordini rapidi, attività di guida, sicurezza…).

Le IPA criptate dell'App Store vengono rifiutate: servono IPA decriptate.

### Come vengono eseguite

1. L'eseguibile viene trasformato in libreria dinamica (come fa LiveContainer) e caricato con `dlopen`.
2. `Bundle.main` restituisce il bundle dell'app, così risorse e Info.plist sono i suoi.
3. Viene eseguito l'AppDelegate dell'app (disattivabile), poi il suo `CPTemplateApplicationSceneDelegate`
   riceve una `CPTemplateApplicationScene` e un `CPInterfaceController` simulati
   (anche la variante `toWindow:` con `CPWindow` per le app di navigazione, e la vecchia `CPApplicationDelegate`).
4. I template impostati dall'app vengono disegnati in stile CarPlay e i tocchi richiamano i suoi handler:

| Template | Supporto |
|---|---|
| `CPListTemplate` | sezioni, immagini, dettagli, accessori, indicatore di riproduzione, avanzamento, righe immagine, messaggi, stato vuoto |
| `CPGridTemplate` | pulsanti con immagine e titolo |
| `CPTabBarTemplate` | schede in alto, badge, delegate |
| `CPNowPlayingTemplate` | dati da `MPNowPlayingInfoCenter`, controlli via `MPRemoteCommandCenter` dell'app, pulsanti (shuffle, repeat, velocità, altro…), "A seguire", album/artista |
| `CPMapTemplate` | mappa dell'app nella `CPWindow`, pulsanti mappa e barra, anteprima percorsi, avvio navigazione, manovre, stime di viaggio, panoramica, avvisi di navigazione |
| `CPPointOfInterestTemplate` | mappa con pin, elenco, dettaglio, pulsanti |
| `CPInformationTemplate`, `CPContactTemplate`, `CPSearchTemplate` | completi |
| `CPAlertTemplate`, `CPActionSheetTemplate`, `CPVoiceControlTemplate` | presentati in sovrimpressione |

### Firma del codice

- **Import dall'app** (Installa IPA): dopo l'estrazione CarPlayss firma l'app con **ZSign e il certificato di
  LiveContainer**, come LiveContainer fa con le sue app. Serve la **modalità JIT-less** di LiveContainer
  (Impostazioni → JIT-Less → "Import Certificate from SideStore" / "Import Certificate").
  Su iOS 26 LiveContainer non consente più di caricare codice non firmato con il solo JIT.
  Se un'app importata prima non è firmata, viene firmata automaticamente al primo avvio.
- **Incorporate nella build**: metti le `.ipa` nella cartella `EmbeddedApps/` del repository e fai push.
  La CI le controlla, le prepara e le inserisce in `CarPlayss.app/CarPlayApps/`; LiveContainer firma tutto
  quando installa CarPlayss.

### Limiti

È un'emulazione dentro un'unica app, non il vero CarPlay: le app che dipendono da servizi di sistema riservati
(Siri dell'auto, cluster strumenti, dati del veicolo) o che fanno controlli particolari sul processo possono non funzionare.
Se un'app lancia un'eccezione durante una chiamata, CarPlayss la mostra in basso invece di chiudersi.

## Ottenere l'IPA unsigned (GitHub Actions)

1. Carica il repository su GitHub (inclusa la cartella `.github/`).
2. Il workflow **Build unsigned IPA** parte a ogni push (o da **Actions → Run workflow**).
3. Scarica l'artifact **CarPlayss-unsigned-ipa** → `CarPlayss.ipa`.
4. Con un tag `v*` (es. `git tag v2.0.0 && git push --tags`) l'IPA viene allegata a una Release.

Il workflow genera il progetto con **XcodeGen** (`project.yml`), compila con `CODE_SIGNING_ALLOWED=NO`,
incorpora le IPA di `EmbeddedApps/` e crea `CarPlayss.ipa`.

## Installazione in LiveContainer

1. LiveContainer → **+** → `CarPlayss.ipa`.
2. Per importare IPA dall'app configura la modalità **JIT-less** di LiveContainer (certificato importato).
3. Concedi posizione, microfono/riconoscimento vocale e libreria musicale se servono.

## Compilare in locale (macOS)

```bash
brew install xcodegen
xcodegen generate
open CarPlayss.xcodeproj
```

## Struttura

```
.github/workflows/build.yml     CI: progetto, build, incorporamento IPA, IPA unsigned
project.yml                     XcodeGen (target, Info.plist, dipendenze: ZIPFoundation)
scripts/embed_carplay_apps.py   incorpora EmbeddedApps/*.ipa nella build
EmbeddedApps/                   metti qui le IPA CarPlay da incorporare
CarPlayss/
  App/            entry point e AppDelegate
  ObjC/           CPSRuntime: CPInterfaceController/scena simulati, hook, chiamate sicure
  Host/           patch Mach-O, libreria app, caricamento e sessioni CarPlay
  Models/         stato, media, navigazione, assistente vocale
  Views/          schermo auto, barra laterale, Home, Dashboard
  Views/Guest/    rendering dei template CarPlay delle app installate
  Views/Apps/     app integrate e gestione app installate
```
