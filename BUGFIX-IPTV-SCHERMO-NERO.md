# IPTV – indagine e patch per lo schermo nero

## Cosa corregge questa patch

La patch non presume che il problema sia soltanto H.264. Rende verificabili, in ordine, i passaggi che trasformano un access unit compresso in un'immagine effettivamente mostrata:

1. **MediaCodec / uscita video** – registra configurazione, dimensioni, Surface, buffer decodificati e `releaseOutputBuffer(render=true/false)`. Ogni uscita video scartata durante il disegno ora registra il motivo specifico. Le eccezioni RuntimeException nella fase di disegno vengono intercettate per evitare che un problema grafico non gestito termini il thread di riproduzione.
2. **CoreVideo → Bitmap** – controlla il risultato di `CVPixelBufferLockBaseAddress`, verifica pixel format, base address, dimensioni e stride prima di trattare i byte come BGRA; applica la conversione BGRA→RGBA e rilascia sempre il lock del `CVPixelBuffer` e i pixel del Bitmap. Una superficie YUV/planare non viene più interpretata in modo errato come un'immagine BGRA: viene segnalata con FOURCC, numero di piani e fase del fallimento.
3. **Composizione della view** – `TextureView` e `SurfaceView` loggano quando ridisegnano realmente il bitmap ricevuto. Per `SurfaceView` viene segnalato anche il caso in cui esiste un frame software ma la view si trova in modalità GL e quindi non lo compone.
4. **Diagnostica robusta** – la descrizione di una Surface è protetta da eccezioni; una superficie non valida non deve provocare una seconda eccezione mentre si tenta di registrare il problema.

Il log `Husk video frame PRESENTED` significa che il frame è stato copiato e che `unlockCanvasAndPost` è terminato senza eccezioni. Non è, da solo, una prova della composizione finale sullo schermo: per questo sono stati aggiunti i messaggi `Husk TextureView composited video frame` e `Husk SurfaceView composited video frame`.

## Come leggere il prossimo log (in questo ordine)

| Ultimo messaggio presente | Interpretazione / area da correggere |
|---|---|
| Nessun `Husk configured` | Il percorso MediaCodec non è stato raggiunto, oppure l'app non sta caricando questo framework/Dex. Verificare sorgente, player, selezione traccia e runtime effettivamente installato. |
| `Husk configured` ma nessun `Husk queueInputBuffer` | Il codec è stato configurato ma non riceve campioni: problema a monte (datasource, demux, selezione formato/traccia o buffering). |
| `queueInputBuffer` ma nessun `media: submitting H.264/HEVC access unit` | I dati non diventano NAL riconosciute o non contengono un VCL valido: verificare formato del bitstream, configurazione codec (avcC/hvcC, SPS/PPS) e segmenti ricevuti. |
| `waiting for H.264 random-access frame` | Il decoder è stato (ri)creato e attende un IDR. Se lo stream inizia nel mezzo del GOP o il provider non invia un keyframe, il video resta nero fino al prossimo IDR. Non va rimosso il gate: accettare P/B frame senza riferimenti validi produce immagini corrotte o nessun frame. |
| `media: submitting ...` ma nessun `VideoToolbox callback frame` | La richiesta arriva a VideoToolbox, ma non c'è output: controllare status/errori di `VTDecompressionSessionDecodeFrame`, descrizione formato, SPS/PPS e supporto del codec. |
| `VideoToolbox callback frame` ma `renderFrame failed` | Il decoder ha prodotto un `CVPixelBuffer`; la diagnostica riporta il motivo preciso nella conversione CoreVideo/Bitmap (`stage`, `pixel-format`, piani, base address e stride). |
| `renderFrame ok` ma `Husk video frame NOT rendered` | Il buffer è convertito, il difetto è nell'output Surface/Canvas: leggere `reason` e la descrizione della Surface. |
| `Husk video frame PRESENTED` ma nessun `TextureView/SurfaceView composited video frame` | Il buffer è postato ma la view non lo sta componendo: lifecycle, attach/visibility, callback SurfaceTexture, tipo di Surface o rendering della view. |
| `SurfaceView ... not composited because ... GL mode` | È stata consegnata una Bitmap software a una view in modalità GL che non la disegna. Va corretto il percorso Surface/renderer scelto dall'app, non il decoder H.264. |
| `TextureView/SurfaceView composited video frame` ma schermo nero | La pipeline software ha completato anche la composizione della view; investigare livello/window compositor, overlay, clipping, alpha, z-order e presentazione dell'app. |

## Problemi preesistenti visibili nei log consegnati

I file `husk.log` e `husk-native.log` allegati hanno orario **8 novembre 2026, 01:19 UTC**; l'archivio sorgente `Husk-main-iptv-audio-pts-diagnostics.zip` è stato creato alle **01:33 UTC**. Quindi quei log precedono l'archivio/patch più recente e non possono verificare le modifiche appena aggiunte.

Nei log delle 01:19 sono comunque presenti tre problemi reali:

- `NoSuchMethodError: AudioManager.getService()Landroid/media/IAudioService;` dentro `Spatializer.getImmersiveAudioLevel()`. È una chiamata a un servizio Binder Android non disponibile in Husk. Il sorgente aggiornato contiene già `HuskSpatializer`, che restituisce valori conservativi e non invoca `getService()`; occorre che venga incluso e caricato il framework aggiornato.
- `MediaSessionManager` di piattaforma tenta di usare un `MediaServiceManager` nullo; segue un errore nella creazione della sessione. Il sorgente aggiornato contiene una facade `MediaSessionManager` senza Binder e una `MediaSession` locale. Anche questa correzione è efficace soltanto se il runtime installato contiene le classi aggiornate.
- `sun/net/ConnectionResetException: Connection reset` segnala interruzioni del collegamento alla sorgente IPTV. Non è un errore di disegno del frame. Se ricompare, controllare URL/endpoint, autenticazione e scadenza token, TLS, redirect, keep-alive e continuità del flusso. Non condividere URL completi con credenziali o token.

I successivi `NullPointerException` sul thread `ExoPlayer:Playback` sono offuscati (ad esempio `bq.e(...:240)`) e i log non contengono `mapping.txt`. Non è corretto attribuirli a una specifica riga Media3 senza il mapping R8 della precisa APK. La patch di rendering impedisce che le eccezioni RuntimeException della copia/del disegno siano propagate da `MediaCodec.draw()`, ma non può correggere un NPE interno a una classe applicativa Media3 non identificata.

Nei log consegnati non risultano messaggi `Husk configured`, `Husk queueInputBuffer`, `media: submitting ...`, `VideoToolbox callback frame` o `Husk video frame PRESENTED`. Perciò i log non provano che un campione video abbia raggiunto il decoder: non consentono di dichiarare che la causa originale dello schermo nero sia stata definitivamente individuata.

## Ricompilazione e installazione corrette

È necessario rigenerare il **Java runtime/framework di Husk**, non soltanto reinstallare l'APK IPTV. Il repository contiene questi passaggi:

```sh
# Sul Mac con toolchain Husk configurata e immagine Android/APEX disponibile:
./scripts/build_java_runtime.sh /percorso/al/root/apex

# Poi crea il pacchetto usando il runtime appena compilato:
./scripts/package_ipa.sh build/Husk-iptv-video-diagnostics.ipa
```

`build_java_runtime.sh` invoca `src/java-framework/build.sh` e produce `build/java-runtime/husk-framework.dex` e `husk-framework-core.dex`. `package_ipa.sh` copia questo runtime nel pacchetto e verifica che il DEX incluso corrisponda al runtime appena compilato. Il progetto completo dipende da Xcode e dai framework Apple: la parte nativa VideoToolbox/CoreVideo va compilata e verificata su macOS. In questo ambiente Linux è stata verificata la compilazione Java di tutti i sorgenti `src` + `gen-src` contro gli stub (`javac --release 8`, exit code 0); non è stato possibile eseguire il build iOS né compilare/linkare le API Apple native.

## Cosa raccogliere se resta nero

Dopo avere installato un pacchetto che contiene questo runtime, avviare un canale per almeno 15–20 secondi e allegare:

- `husk.log` completo;
- `husk-native.log` completo;
- il nome/MIME della traccia video e il tipo di sorgente (HLS `.m3u8`, DASH `.mpd`, TS, MP4, ecc.), senza credenziali;
- `mapping.txt` della stessa build APK, se disponibile.

Non filtrare i messaggi `MediaCodec`, `media:`, `TextureView` e `SurfaceView`: servono per individuare il primo anello della pipeline che si interrompe.
