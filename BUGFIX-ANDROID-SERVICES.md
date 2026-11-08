# Translation layer — servizi Android mancanti o non funzionanti, tema Intermediate/Dark, nuova icona

## Servizi Android (framework Java, `src/java-framework`)

Ogni voce era un servizio che un'app poteva chiamare senza errore di link ma che non faceva nulla, restituiva `null`
dove Android non lo fa mai, oppure mentiva sulle capacità del dispositivo.

| Area | Prima | Ora |
|---|---|---|
| **JobScheduler** (`android.app.job.*`) — usato da WorkManager, JobIntentService, Firebase | `JobInfo` buttava via tutto ciò che il Builder riceveva; ogni job partiva subito, ignorando latenza/periodo; `jobFinished` ignorato; `JobWorkItem.getIntent()` e `dequeueWork()` restituivano `null`, quindi il lavoro accodato con `enqueue` andava perso | `JobInfo` conserva tutti i parametri; lo scheduler rispetta latenza minima, periodo (con i minimi di Android), back-off lineare/esponenziale su `jobFinished(p, true)`, `cancel` → `onStopJob` con `STOP_REASON_CANCELLED_BY_APP`; i `JobWorkItem` vengono consegnati con `dequeueWork`/`completeWork` e il job termina quando il lavoro è esaurito; il `JobService` viene distrutto quando nulla lo tiene in vita |
| **Ciclo di vita dei Service** (`husk.Services`) | `onUnbind`/`onRebind` mai chiamati; `startId` sempre 1; `stopSelf(id)` fermava comunque; un service bound non veniva mai distrutto; `onBind` chiamato per ogni client | Come Android: un solo `onBind`, stesso binder a tutti i client, `onUnbind`/`onRebind`, `startId` crescenti, `stopSelfResult(id)` solo per l'ultimo start, `onDestroy` quando non è né avviato né bound né in uso da un job; `BIND_AUTO_CREATE` rispettato; intent con classe relativa (`.MyService`) risolti |
| **Context.bindService / start…AsUser / bindIsolatedService** | Le varianti con `BindServiceFlags` (Android 14), `AsUser` e `bindIsolatedService` restituivano `false`/`null`; `BindServiceFlags.of()` restituiva `null` (NPE) | Tutte delegano all'implementazione reale |
| **Broadcast ordinati** | `sendOrderedBroadcast` con result receiver e altre 30 varianti `send*Broadcast*` erano vuote; `setResultCode`/`abortBroadcast`/`goAsync` non funzionavano | Consegna ordinata vera: il risultato passa da un receiver al successivo, `abortBroadcast` ferma i successivi, `goAsync()` trattiene la catena finché `finish()`, il result receiver riceve il risultato finale sul suo handler; tutte le varianti consegnano |
| **AlarmManager** | `cancel()` non faceva nulla; `setRepeating` sparava una volta; `setAlarmClock` ignorato; listener chiamati sull'handler sbagliato; varianti con `Executor` vuote | Un allarme per PendingIntent/listener (reimpostarlo lo sostituisce), `cancel` funziona, ripetizioni vere (minimo 60 s come Android), `getNextAlarmClock`, listener sul loro handler/executor |
| **PendingIntent** | Ogni `getBroadcast()` creava un oggetto nuovo: impossibile ritrovarlo per `cancel`; `FLAG_NO_CREATE`/`UPDATE_CURRENT`/`CANCEL_CURRENT`/`ONE_SHOT` ignorati | Tabella dei token come Android (tipo + request code + `filterEquals`), tutti i flag rispettati, `send` dopo `cancel` lancia `CanceledException`, `OnFinished` chiamato |
| **DownloadManager** | `enqueue` restituiva 0 e `query` `null` (NPE) | Download reale HTTP(S) in background: header, redirect http↔https, pausa/ripresa con Range, retry, destinazioni (`setDestinationUri`, `…InExternalFilesDir`, `…InExternalPublicDir`), cursor con le colonne e gli stati di Android, broadcast `ACTION_DOWNLOAD_COMPLETE` |
| **TextClassifier** | `TextClassifier.NO_OP` era `null`, `TextView.getTextClassifier()` e il manager restituivano `null` (NPE alla selezione del testo) | `NO_OP` vero che risponde con risultati vuoti ma validi |
| **BiometricManager** | `canAuthenticate()` restituiva 0 = `BIOMETRIC_SUCCESS`: le app aprivano un BiometricPrompt inesistente | `BIOMETRIC_ERROR_NO_HARDWARE`: le app passano al PIN/password |
| **MessageQueue.IdleHandler** | `addIdleHandler` ignorato | Eseguiti quando la coda è inattiva; rimossi se restituiscono `false` |
| **ActivityManager.getRunningServices** | Lista vuota | I service vivi dell'app |
| Altro | `MacAddress` (parse/stampa vuoti), `Rfc822Tokenizer`, `IntArrayEvaluator`/`FloatArrayEvaluator`, `FileUtils.list*OrEmpty`, `NotificationListenerService.getActiveNotifications`, `SubscriptionManager.get*Id*`, `HardwarePropertiesManager.getDeviceTemperatures`, `PrecomputedText.getSpans`, `PerformanceHintManager.getPreferredUpdateRateNanos`, `NotificationManager.from` | Implementati o restituiscono valori vuoti validi invece di `null` |

Nessun membro pubblico è stato rimosso (verificato con `javap` sulle 112 classi toccate).

### Test

`tests/java-framework/run.sh` compila il framework e lo esegue su una JVM desktop (con `husk.Native` sostituito da
`shadow_native.py`): job con latenza, lavoro accodato e cancellazione; bind/rebind/start id/distruzione dei service;
PendingIntent e AlarmManager; broadcast ordinati con `goAsync` e abort; DownloadManager contro un server HTTP locale
(redirect, 404, byte integri); IdleHandler; classi minori. Tutti i test passano.

### Limiti onesti

"Qualsiasi APK al 100%" non è un obiettivo raggiungibile né verificabile: Husk reimplementa il framework Android, e
le app che dipendono da hardware o servizi che iOS non espone (fotocamera via Camera2, NFC, Bluetooth, biometria,
servizi Google Play reali, DRM Widevine) continuano a vedere quelle funzioni come assenti — ora lo vedono in modo
coerente invece di andare in crash. Il codice nativo del translation layer (C) non è stato modificato; le modifiche Swift
e gli asset non sono stati compilati qui (nessun Xcode su Linux): vanno verificati con `./scripts/ci_build.sh`.

## Aspetto (app iOS)

- **Settings › Appearance** ha ora quattro scelte, con anteprime: System, Light, **Intermediate** (il vecchio tema scuro
  blu notte, identico) e **Dark** (nero reale: pagine `#000000`, card quasi nere — anche risparmio energetico su OLED).
- System segue il telefono: Light di giorno, Dark (nero reale) di notte.
- Il passaggio tra Intermediate e Dark (stesso stile UIKit) ridisegna tutte le finestre con una dissolvenza.
- File: `Theme.swift` (`Theme.Appearance`, `trueBlack`, `blackAware`, `AppearancePicker`), `ConsoleUI.swift` (palette),
  `SettingsTab.swift`, `OnboardingView.swift`.
- Chi aveva scelto "Dark" ora vede il nero reale; per il look precedente basta scegliere Intermediate.

## Icona

Nuovo glifo dall'artwork fornito, nei colori dell'icona originale (sfumatura viola→blu, vetro, ombre) e in tutte le
varianti: default, dark, tinted, clear light, clear dark, tinted light (`Assets.xcassets/*.appiconset` e le anteprime
`Resources/icon-*.png`). Gli strumenti per rigenerarla sono in `tools/icon/`.

## Correzioni dai log del 08/11 (GassPlayer, iPhone15,2, iOS 27.0.1, JIT-less)

| Sintomo nel log | Causa | Correzione |
|---|---|---|
| `Audio sink error … Unexpected audio track timestamp discontinuity` ogni pochi secondi, AudioTrack resettato (audio a scatti) | `MediaCodec.Callback.onOutputBufferAvailable` riceveva **sempre lo stesso** `BufferInfo`, riciclato. L'adattatore asincrono di Media3 conserva l'oggetto finché il buffer viene prelevato, quindi i buffer audio in coda prendevano timestamp e dimensioni dei successivi (il decoder AAC era corretto: `delta=0` nel log) | Un `BufferInfo` nuovo per ogni callback, come fa Android (`android/media/MediaCodec.java`). Corregge anche i timestamp dei frame video |
| `active H.264 decoder cannot accept updated format; recreating session (… PPS=4 / 95 / 5)` in loop, poi solo `waiting for H.264 random-access frame`: **video nero** | Il decoder teneva un solo SPS/PPS: lo stream manda 3 PPS e ogni nuovo PPS sembrava un cambio di formato → sessione ricreata e tutti i frame scartati in attesa di un IDR, all'infinito | SPS/PPS/VPS tenuti **per id** (come un decoder vero) e passati tutti a VideoToolbox; un cambio di solo PPS non scarta più i frame; per stream senza IDR (intra refresh, GOP aperti, comuni in IPTV) si parte da una slice I, da un SEI recovery point o, in ultima istanza, dopo ~4 s (`husk-tl-dvm-media.c`, test: `tests/translation-layer/run_media_params.sh`) |
| `E/AsynchronousCloseMonitor: setting blocked thread signal handler failed`, poi `SocketTimeoutException: Read timed out` | Il segnale con cui libcore sveglia un thread bloccato su un socket chiuso (`__SIGRTMIN+2` = 34) non aveva equivalente su Darwin: una lettura HTTP annullata (cambio canale) restava bloccata fino al timeout | Il segnale 34 è portato su `SIGEMT`, libero su Darwin (`husk-tl-bionic.c`, `husk-tl-bionic-io.c`) |
| `ld: libc++.so / libssl.so: unresolved import _Unwind_*` | Su un telefono l'unwinder C++ sta in libc; nel runtime di Husk non c'era: ogni eccezione C++ in libc++/BoringSSL finiva su uno stub | Il loader risolve `_Unwind_*` da `libunwind.so`, che il runtime Dalvik carica per primo; `scripts/build_java_runtime.sh` ora la costruisce dall'NDK (con `ANDROID_NDK`) e la mette nel runtime, così la modalità JIT-less la converte con le altre |
| `canOpenURL: failed for URL: "stikjit://"` e `csops status` ripetuti decine di volte | Sotto LiveContainer iOS rifiuta la query (lo schema va dichiarato nell'Info.plist dell'app host, non di Husk) e le schermate JIT la ripetono più volte al secondo | Risultato in cache per 30 s; `csops` registrato solo quando cambia (`JITBootstrap.swift`) |

Non è un bug di Husk: `None of the available extractors … NoDeclaredBrand` (vedi `BUGFIX-MEDIA3-AUTO-SOURCE.md`) e i messaggi SELinux/init nel `guest-serial.log`, che è il normale avvio della macchina Android emulata.

**Aspetto:** System ora usa Light di giorno e **Dark (nero reale)** di notte; Intermediate resta disponibile come scelta esplicita.

## Correzioni dal test delle 22:19 (video capovolto)

Nel log l'audio non ha più discontinuità e il video parte su tutti i canali, compreso quello con più PPS (`decoding starts (intra slice…)`).

| Sintomo | Causa | Correzione |
|---|---|---|
| Nel video registrato, su "Rai 1 SD" (TextureView) un fotogramma sì e uno no è **capovolto** | Ogni bitmap ha un solo `CGContext` e un `Canvas` è un livello di stato sopra di esso, con il ribaltamento dell'asse y. Il doppio buffer di `SurfaceTexture` creava un nuovo `Canvas` sul buffer a ogni scambio senza liberare il precedente: sul secondo canvas il ribaltamento era applicato due volte, quindi disegnava capovolto. Il finalizer del canvas vecchio poi toglieva lo stato a quello nuovo, da un altro thread | Lato nativo (`husk-tl-dvm-graphics.c`): il canvas più recente possiede il contesto, il precedente viene "srotolato" e non lo tocca più (anche se il GC lo libera dopo); un canvas che sopravvive al proprio bitmap non usa più un contesto già liberato. Questo vale per tutte le app che fanno `new Canvas(bitmap)` a ogni disegno. Lato Java (`SurfaceTexture`): ogni buffer tiene lo stesso canvas per tutta la vita |
| `no libunwind.so in the runtime` | La CI non aveva `ANDROID_NDK` | `build_java_runtime.sh` usa anche `ANDROID_NDK_LATEST_HOME` / `ANDROID_NDK_HOME` dei runner GitHub; la chiave di cache del runtime include gli script che lo costruiscono, così viene rifatto |
