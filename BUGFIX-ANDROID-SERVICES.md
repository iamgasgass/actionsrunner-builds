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

## Correzioni dai crash report delle 21:57 (GassPlayer)

| Sintomo | Causa | Correzione |
|---|---|---|
| **"The app crashed"**: `IllegalStateException` in `PlaybackController.ensurePlayer` → costruttore di ExoPlayer (`PlaybackLooperProvider.obtainLooper`, `checkState`), che chiude il thread principale | Il provider del looper di Media3 crea un `HandlerThread` e ne prende il looper. Se un avvio precedente era fallito (`pthread_create` rifiutato per mancanza di spazio di indirizzamento), il thread restava segnato "vivo" per sempre: `Thread_nativeCreate` lo marcava vivo prima di crearlo e non lo rimetteva a posto in caso di errore. Inoltre `HandlerThread.getLooper()` aspettava all'infinito su un thread mai partito o già finito, e `getThreadHandler()` restituiva `null` | `husk-tl-dvm-natives.c`: se il thread non può essere creato, non risulta più vivo, viene scritto nel log e parte `OutOfMemoryError`. `HandlerThread` ha ora la semantica di Android: `getLooper()` restituisce `null` se il thread non è vivo; `quit`/`quitSafely` non si bloccano; `getThreadHandler()`, `getThreadExecutor()` e `getThreadId()` sono implementati. Ci sono test host apposta |
| **"Husk closed while the game was running"**: dopo circa 5 minuti di riproduzione, la memoria libera scende in modo costante da 3,8 GiB a 75 MiB (circa 11 MB/s) e iOS (jetsam) chiude l'app senza lasciare traccia | La DVM di Husk non ha ancora un garbage collector: ogni oggetto Java creato resta in memoria. Un'app che alloca a ogni fotogramma (Compose, buffer di rete, ExoPlayer) prima o poi esaurisce la RAM | **Diagnostica**: ogni 10 secondi (dopo i primi 40) il log riporta una riga `heap:` con gli oggetti creati, i MiB totali e quelli nuovi dall'ultima riga, e le 8 classi che allocano di più. Con quel log si possono mettere in pool le allocazioni più grosse, come è già stato fatto per i buffer di MediaCodec e per l'audio. La soluzione definitiva è un GC tracciante, un progetto a parte |

## Correzioni dai log del 09/11 (GTA SA e GassPlayer)

| Sintomo | Causa | Correzione |
|---|---|---|
| **Audio distorto/accelerato in GTA SA** | OpenAL Soft crea il player OpenSL con il formato esteso di Android (`SLAndroidDataFormat_PCM_EX`). Husk leggeva solo `SLDataFormat_PCM`, quindi il player restava a 48000 Hz e 16 bit mentre il gioco mandava 22050 Hz | `husk-tl-opensles.c`: legge sia `PCM` sia `PCM_EX`, con frequenza in mHz (o in Hz, se un motore la passa così), canali, bit (8/16/24/32), ordine dei byte e rappresentazione (intero con e senza segno, float). Converte in 16 bit, applica volume e muto (`SLVolumeItf` reale), restituisce durata e posizione (`SLPlayItf`) invece di valori non scritti |
| Audio alla velocità sbagliata o muto quando un secondo flusso ha un'altra frequenza o un altro numero di canali | `husk-tl-audio.c` apriva la coda iOS alla prima frequenza e la teneva per sempre; un flusso con un diverso numero di canali veniva scartato | La coda è sempre stereo, a 44.1/48 kHz. Le altre frequenze vengono ricampionate con interpolazione lineare, con fase continua tra una scrittura e l'altra (nessun clic). Mono va su entrambi i canali; 5.1 e simili usano i due frontali. Se il formato coincide, i campioni passano identici. Il ring copia in due blocchi invece che campione per campione |
| GassPlayer: centinaia di MB di `float[]` ogni 10 secondi (righe `heap:`) | Il disegno creava oggetti a ogni fotogramma: ogni operazione di `Matrix` due `float[9]`, `Canvas.concat`/`setMatrix`/`getMatrix` un array, `RenderNode` un `Matrix`, un `Paint` e una `Camera` per livello, `ViewGroup` una copia dei figli e un `int[]` per gruppo, il clip al contorno un `Outline`, un `Path` e un `RectF` per vista, il testo con span un `TextPaint` (e un `Paint` per ogni sfondo), `Paint.reset()` un `Paint` nuovo | Tutti questi percorsi ora riusano i propri oggetti. Il riuso è protetto dalle chiamate annidate: un gruppo ridisegnato mentre disegna, o una `ReplacementSpan` che disegna testo, prendono oggetti propri. `Matrix` dà esattamente gli stessi numeri di prima: test su 3000 sequenze casuali, differenza massima 0.0 |

Test aggiunti: `tests/translation-layer/run_audio.sh` (conversione dell'uscita audio), `tests/translation-layer/run_opensles.sh` (player OpenSL come lo usa OpenAL) e il confronto di `Matrix` in `tests/java-framework`.

Il garbage collector della macchina virtuale Java non è incluso in questa versione (vedi il messaggio di consegna).

## Correzioni dai log delle 20:19 (GassPlayer, build v9)

| Sintomo | Causa | Correzione |
|---|---|---|
| Risoluzione dei nomi (DNS) diversa da Android in tutte le app Java | `husk-tl-bionic-net.c` leggeva i flag `AI_*` di `getaddrinfo` e `NI_*` di `getnameinfo` con i valori di glibc. Bionic usa invece quelli BSD/NetBSD (`AI_NUMERICSERV` 0x8, `AI_ADDRCONFIG` 0x400, `AI_V4MAPPED` 0x800; `NI_NUMERICHOST` 0x2, `NI_NAMEREQD` 0x4). Così l'`AI_ADDRCONFIG` che libcore usa per ogni risoluzione arrivava a iOS come `AI_NUMERICSERV`: niente filtro sulle famiglie raggiungibili (IPv6 anche senza rete IPv6). Inoltre la ricerca inversa con `NI_NAMEREQD` restituiva l'indirizzo numerico come nome | Flag convertiti con i valori di bionic, verificati sul suo `netdb.h`. Per `NI_*` i valori di bionic e di iOS coincidono |
| `recvfrom`/`recvmsg` su socket TCP | iOS non restituisce un indirizzo per un socket connesso, ma veniva convertito comunque il buffer non inizializzato | Lunghezza dell'indirizzo 0, come su Linux |
| `recvmsg`: flag e messaggi di controllo persi | `msg_flags` sempre azzerato; `SCM_RIGHTS` (passaggio di file descriptor, usato da `LocalSocket` e `ParcelFileDescriptor`) non veniva né spedito né ricevuto, e i descriptor ricevuti restavano aperti | `MSG_TRUNC`/`MSG_CTRUNC`/`MSG_EOR`/`MSG_OOB` convertiti. `SCM_RIGHTS` convertito nei due sensi (intestazione da 16 byte allineata a 8 su Android, da 12 allineata a 4 su iOS). I descriptor che non entrano nel buffer vengono chiusi con `MSG_CTRUNC`. Test: `tests/translation-layer/run_net_cmsg.sh` |
| `getsockopt(SO_RCVTIMEO/SO_SNDTIMEO)` | Su iOS `tv_usec` è di 4 byte con 4 byte di riempimento: l'app leggeva un valore sporco | Valore azzerato e microsecondi estesi a 8 byte |
| `SO_LINGER` | Su iOS `SO_LINGER` è in tick di clock, su Linux in secondi | Usato `SO_LINGER_SEC` |
| Opzioni mancanti | `SO_RCVLOWAT`, `SO_SNDLOWAT`, `IPV6_TCLASS` (`Socket.setTrafficClass` di libcore) venivano ignorate; `SO_PEERCRED` (`LocalSocket.getPeerCredentials`) falliva | Tradotte; `SO_PEERCRED` è costruito da `LOCAL_PEERPID` e `getpeereid` |
| `libunwind.so` assente dal runtime (eccezioni C++ di libc++/libssl non gestite) | Un runtime Java fornito per URL (`HUSK_JAVA_RUNTIME_URL`) ha la precedenza su quello costruito in CI e può essere precedente a `libunwind.so` | `build.yml`: se il runtime ricevuto non ha `libunwind.so`, la CI lo costruisce con l'NDK del runner e lo aggiunge; se non può, lo segnala con un avviso |
