# Media3/Husk — correzione sorgenti IPTV senza estensione

Questo pacchetto aggiunge un'integrazione applicativa di riferimento per risolvere endpoint IPTV senza estensione. Non modifica il decoder Husk: nel log esaminato Media3 fallisce nello `ProgressiveMediaSource` prima di creare una traccia e invocare `MediaCodec`.

## Diagnosi basata sul sorgente

- `NoDeclaredBrand` si presenta quando l'extractor MP4 non trova il brand dichiarato nel contenuto sniffato. Il messaggio esterno `None of the available extractors could read the stream` è un errore del percorso progressivo di Media3, non di VideoToolbox.
- `DefaultMediaSourceFactory` sceglie HLS/DASH/SmoothStreaming in base a suffisso URI oppure a `MediaItem.mimeType`; quando nessuno di questi identifica una sorgente adattiva, ripiega su `ProgressiveMediaSource`.
- `guest manifest fetch failed` appartiene a `GuestManifest.swift` e interroga il manifest GitHub per gli aggiornamenti dell'immagine/snapshot Android di Husk; non è la playlist IPTV.

## Integrazione

La classe `integration/gassplayer-media3/.../AutoMediaSourceResolver.java` è da integrare nel progetto Android GassPlayer (non nel runtime Husk). Esegue una verifica HTTP limitata, distingue HLS/DASH/SmoothStreaming da M3U canali e sorgenti progressive, e costruisce il `MediaSource` appropriato. Le istruzioni sono in `integration/gassplayer-media3/README.md`.

## Limite di consegna

Il repository Husk fornito non include il sorgente GassPlayer né la factory Media3 dell'APK `GassPlayer-Android-TV-release.apk`. Pertanto la presente integrazione è un helper pronto per l'app ma non è stata iniettata nell'APK binario e non cambia il comportamento dell'app finché non viene collegata al punto in cui il player crea il `MediaItem`/`MediaSource`.

Non è corretto promettere compatibilità con qualsiasi codec/protocollo: il runtime Husk espone attualmente AVC, HEVC quando disponibile via VideoToolbox, AAC, MP3, AC-3, E-AC-3 e MPEG Layer I/II dove disponibili via AudioToolbox. I codec non implementati richiedono decoder reali e corrispondenti test; dichiararli soltanto in `MediaCodecList` causerebbe errori più avanti nella pipeline.
