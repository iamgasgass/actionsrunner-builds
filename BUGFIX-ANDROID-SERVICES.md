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
- System segue il telefono: Light di giorno, Intermediate di notte.
- Il passaggio tra Intermediate e Dark (stesso stile UIKit) ridisegna tutte le finestre con una dissolvenza.
- File: `Theme.swift` (`Theme.Appearance`, `trueBlack`, `blackAware`, `AppearancePicker`), `ConsoleUI.swift` (palette),
  `SettingsTab.swift`, `OnboardingView.swift`.
- Chi aveva scelto "Dark" ora vede il nero reale; per il look precedente basta scegliere Intermediate.

## Icona

Nuovo glifo dall'artwork fornito, nei colori dell'icona originale (sfumatura viola→blu, vetro, ombre) e in tutte le
varianti: default, dark, tinted, clear light, clear dark, tinted light (`Assets.xcassets/*.appiconset` e le anteprime
`Resources/icon-*.png`). Gli strumenti per rigenerarla sono in `tools/icon/`.
