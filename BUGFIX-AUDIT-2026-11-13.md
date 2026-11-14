# Audit del fork Husk — 13/11/2026

Revisione di tutto ciò che il fork ha cambiato rispetto alla base (commit `773423f`, ~7.500 righe: framework Java, runtime C,
app Swift, script CI), più un'analisi statica (`clang --analyze`) di tutti i sorgenti del runtime compilabili su Linux.
L'impacchettamento dell'IPA (`scripts/package_ipa.sh`, entitlements, workflow, bundle id) **non è stato toccato**: l'IPA si
installa esattamente come prima.

Riferimento: non esiste su GitHub un progetto chiamato "keranium"; il confronto è stato fatto con l'upstream ufficiale
`Leviidev/Husk` (ultimo codice: Husk 3.4, build 149). Il fork contiene già tutto il codice dell'upstream e altro in più, quindi
non c'era nulla da importare da lì.

## Bug corretti

| Area | Problema | Correzione |
|---|---|---|
| `android.os.Message` (pool) | Il pool introdotto per la memoria non aveva il flag "in uso" di Android: un `recycle()` doppio (un'app che ricicla il messaggio che il Looper ricicla di nuovo) metteva lo stesso oggetto due volte nel pool → `obtain()` restituiva lo **stesso Message a due mittenti** o un ciclo infinito nel pool; un `sendMessage()` di un messaggio già in coda creava un ciclo nella coda (thread bloccato) | `FLAG_IN_USE` come in AOSP: il messaggio è "in uso" da quando entra in coda finché torna nel pool; reinviare un messaggio in coda lancia `IllegalStateException` come su Android; un `recycle()` di troppo viene ignorato |
| `Message.obtain(Message)` | Restituiva **`null`** (NPE in Dialog, AndroidX, Messenger) | Copia completa come Android (what/arg/obj/data/target/callback/replyTo) |
| `Message` | `copyFrom`, `getWhen`, `peekData`, `setCallback`, `setTarget`, `setWhat` erano vuoti | Implementati |
| `Looper.quitSafely` | Uguale a `quit()`: scartava anche i messaggi già scaduti | Consegna i messaggi già dovuti, scarta solo quelli futuri |
| `SurfaceView` | Il fork liberava (recycle) i buffer in `surfaceDestroyed` **anche mentre un altro thread stava disegnando** (decoder video tra `lockCanvas` e `unlockCanvasAndPost`): use-after-free nativo → crash; inoltre `unlockCanvasAndPost` lanciava "Surface was not locked" | Se il buffer è bloccato, la liberazione avviene nel `post()` del produttore; nessuna eccezione |
| `SurfaceTexture` | Rilasciata durante un disegno: i canvas restavano vivi (perdita) | Liberati al `post()` |
| Canvas nativo (`husk-tl-dvm-graphics.c`) | Un `Canvas` che sopravvive alla sua `Bitmap` riciclata disegnava in un `CGContext` già liberato (crash); prima il caso era raro, ora il fork ricicla bitmap in `SurfaceView`/`MediaCodec` | Ogni bitmap conosce i canvas creati su di essa; quando viene liberata, i loro disegni diventano no-op |
| Decoder video (`husk-tl-dvm-media.c`) | Attesa **senza timeout** sui callback VideoToolbox: se un callback non arriva il thread di riproduzione restava bloccato per sempre (schermo nero, app ferma) | Attesa massima 1 s, poi continua e lo registra nel log |
| Decoder video | Buffer RBSP di 64 byte: lo SPS HEVC con molti sub-layer ha l'id oltre il 64° byte → id sbagliato | 128 byte |
| Decoder audio | L'array PCM di scratch non veniva liberato alla distruzione del codec (perdita a ogni cambio canale) | Liberato in `destroy` |
| Segnali (`bionic`) | Il segnale 34 (AsynchronousCloseMonitor, usato per interrompere letture HTTP al cambio canale) non era incluso nelle maschere `sigprocmask`/`pthread_sigmask`/`sigsuspend` | Maschere convertite fino al segnale 64 |
| `DownloadManager` | NPE nel ramo d'errore quando il file non ha cartella padre | Controllo del null |
| JNI `tl_jni_call` | Crash su oggetto `null` | Lancia `NullPointerException` come la JVM |
| arm32 `pthread_mutex_init`/`cond_init` | Nessun controllo di `calloc` (crash su memoria esaurita) e perdita se l'indirizzo guest non è valido | Codici d'errore `EINVAL`/`ENOMEM` |
| Firma (codesign), SQLite, binder | Possibili dereferenziazioni di puntatori nulli segnalate dall'analizzatore | Controlli aggiunti |

## Test

- `tests/java-framework/run.sh`: **tutti superati**, con 5 nuovi test (copia di `Message`, doppio recycle, doppio invio,
  consegna unica, `quitSafely`).
- `tests/translation-layer/run*.sh`: tutti superati su Linux (audio, OpenSL, binder, cmsg, parametri media, scanner).
  Due test dello scanner erano **obsoleti** (si aspettavano che le app solo-32-bit fossero rifiutate, mentre il runtime ora
  le traduce): aggiornati al comportamento attuale. `run_media_params.sh` non dipende più dalla dimensione esatta del buffer.
- `tools/codesign-selftest.sh`: superato.
- I file che usano solo SDK Apple (VideoToolbox, CoreGraphics, Swift) non si compilano su Linux: la verifica è la build CI su macOS.

## Non modificato di proposito

- Impacchettamento IPA, entitlements, workflow CI, bundle id: invariati.
- Le scelte progettuali del fork (dimensioni del buffer di input, `getTimestamp()` disattivato, diagnostica IPTV) sono state
  verificate e mantenute.

## Confronto con Kernarium / Andarium (14/11/2026)

Andarium (progetto `imxieyi/Kernarium`) ha un'architettura diversa da Husk: esegue un vero kernel Linux 6.18 (User-mode Linux)
con Android 17 completo dentro l'app, e la sua build richiede il kernel precompilato e un'immagine Android di vari GB. Husk non
è stato trasformato in Andarium (scelta: solo analisi e porting delle idee utili). Dal suo codice host (`darwin/`) sono state
portate due soluzioni:

| Da Andarium | Problema in Husk | Correzione |
|---|---|---|
| Decoder VideoToolbox (`darwin/platform/apple/video_decoder.mm`): se l'uscita BGRA non è disponibile ripiega sul formato 4:2:0 nativo; buffer IOSurface; rispetta il full range dello stream | Husk chiedeva solo BGRA: se il decoder la rifiutava (es. alcuni HEVC 10 bit) → "no decoder session" e **schermo nero** | Sessione BGRA con IOSurface; in caso di rifiuto, sessione 4:2:0 (video o full range secondo lo stream) convertita in RGBA con vImage (BT.709 per HD, BT.601 sotto) |
| Uscita audio (`darwin/device/audio/apple_playback_sink.mm`): gestisce le interruzioni di iOS e riprende la riproduzione | Dopo una chiamata, Siri o un'altra app che prende l'audio, iOS ferma la coda audio e non la riavvia: il thread audio dell'app restava **bloccato per sempre** (e con lui l'orologio del player: anche il video si bloccava) | Se la coda non accetta campioni per 250 ms viene riavviata; finché resta muta i campioni scorrono al ritmo reale, quindi nulla si blocca. Nuovo test in `tests/translation-layer/audio_test.c` |
