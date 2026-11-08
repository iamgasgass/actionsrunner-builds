# GassPlayer / Media3 — automatic source resolver

This folder is an **application-side integration**, not a Husk framework patch. The APK in the supplied Husk repository is external/prebuilt; the Husk repository does not contain GassPlayer's `MediaItem`/`MediaSource` creation code. Therefore this helper must be added to the GassPlayer Android project and called where a selected channel URI is handed to Media3.

## Why this is needed

The log contains:

```text
ExoPlayerImplInternal: Playback error
Source error
None of the available extractors could read the stream
sniff failures: [NoDeclaredBrand, NoDeclaredBrand]
```

Media3's `DefaultMediaSourceFactory` chooses HLS/DASH/SmoothStreaming from a recognized URI suffix or an explicit `MediaItem.mimeType`; otherwise it falls back to `ProgressiveMediaSource` and its extractors. An extensionless HLS endpoint that is not tagged with `APPLICATION_M3U8` is therefore treated as progressive media and fails exactly at the extractor stage. See the official `DefaultMediaSourceFactory` reference and Media items guide linked below.

The resolver performs a bounded HTTP range GET (up to 64 KiB), follows HTTP redirects, carries the provider's request headers, checks the HTTP status and `Content-Type`, and inspects the beginning of the body. It distinguishes:

- HLS manifest (`#EXTM3U` with `#EXT-X-` tags, or a verified `.m3u8` endpoint);
- DASH (`<MPD`);
- SmoothStreaming (`<SmoothStreamingMedia`);
- a normal IPTV channel playlist (`#EXTM3U` + `#EXTINF` without HLS `#EXT-X-` tags);
- progressive containers such as MP4, MPEG-TS, Matroska/WebM, Ogg, MP3, ADTS AAC, MPEG-PS, AVI/WAVE, FLV and AIFF;
- RTSP based on URI scheme;
- obvious HTML/JSON authentication or provider error responses.

For ordinary progressive media, it deliberately **does not force a MIME type**. Media3's default extractors remain responsible for sniffing the real container. HLS/DASH/SmoothStreaming receive the exact MIME hint required for factory dispatch.

## Required Media3 modules

Keep all Media3 artifacts at the exact same version as the APK. The supplied log reports `AndroidXMedia3/1.11.1`, so the example below pins 1.11.1:

```gradle
implementation "androidx.media3:media3-exoplayer:1.11.1"
implementation "androidx.media3:media3-exoplayer-hls:1.11.1"
implementation "androidx.media3:media3-exoplayer-dash:1.11.1"
implementation "androidx.media3:media3-exoplayer-smoothstreaming:1.11.1"
implementation "androidx.media3:media3-exoplayer-rtsp:1.11.1"
```

Do not mix Media3 versions. HLS, DASH, SmoothStreaming and RTSP support require their corresponding modules; progressive files use the base ExoPlayer module.

## Integration point

Add `AutoMediaSourceResolver.java` to GassPlayer's Java source tree. Where the app currently calls `player.setMediaItem(MediaItem.fromUri(channelUrl))`, replace that part with the following pattern. The resolver is blocking network I/O and must run off the main thread. All player mutation must return to the main thread.

```java
Map<String, String> headers = new HashMap<>();
// Preserve the same User-Agent, Referer, Cookie and provider headers the app
// already uses for the channel. Never log their values.

Uri uri = Uri.parse(channelUrl);
ExecutorService io = Executors.newSingleThreadExecutor();
Handler main = new Handler(Looper.getMainLooper());

io.execute(() -> {
    try {
        AutoMediaSourceResolver.ResolvedSource resolved =
                AutoMediaSourceResolver.resolve(uri, headers);
        MediaSource source = AutoMediaSourceResolver.createMediaSource(
                appContext, resolved, headers);
        main.post(() -> {
            player.setMediaSource(source);
            player.prepare();
            player.play();
        });
        Log.i("GassPlayer", "Media source selected: " + resolved.kind
                + ", HTTP=" + resolved.httpStatus
                + ", MIME=" + (resolved.responseMimeType.isEmpty()
                    ? "unknown" : resolved.responseMimeType));
    } catch (IOException e) {
        Log.e("GassPlayer", "Media source preflight failed: " + e.getMessage());
        main.post(() -> showPlaybackError(e.getMessage()));
    }
});
```

`appContext`, `player`, `showPlaybackError` and `channelUrl` are the app's existing objects/callbacks; wire them to the actual screen/player lifecycle. Shut down/reuse the executor appropriately rather than creating one for every zap. Cancel an in-flight probe when the user changes channel.

Also attach a `Player.Listener` and log the full exception object (but not the URI, query string, credentials, cookies or authorization headers):

```java
player.addListener(new Player.Listener() {
    @Override public void onPlayerError(PlaybackException error) {
        Log.e("GassPlayer", "Media3 playback failed", error);
    }
});
```

## Important limits and safety notes

1. **An M3U channel list is not a playable channel.** The resolver deliberately returns an actionable error for a plain IPTV M3U list. Parse it, show the channels, and run source resolution on the selected channel URL. An HLS media/variant playlist has `#EXT-X-` tags and is routed to HLS.
2. **The probe is an extra GET.** It uses `Range: bytes=0-65535`; servers that ignore Range may send more data, but only the first 64 KiB is read before the connection closes. Some one-shot URLs, POST-only portals, nonce URLs, or strict WAFs may reject a preflight. For those providers, use the provider's trusted format metadata or implement a provider-specific resolver; do not guess HLS globally.
3. **Headers must match playback.** Pass the same User-Agent, Referer, Cookie and other required headers to both `resolve()` and Media3. Be careful not to leak credentials if child HLS playlists/segments switch host.
4. **Unknown binary content falls back to progressive sniffing.** If Media3 still reports `UnrecognizedInputFormatException`, the response is not a container recognized by the installed extractors, is truncated, encrypted, or is not media. Do not relabel arbitrary bytes as MP4/HLS.
5. **This is not “all codecs on Android”.** Husk currently implements MediaCodec decoders for AVC/H.264, HEVC/H.265 (only when VideoToolbox reports support), AAC, MP3, AC-3, E-AC-3 and MPEG Layer I/II (conditional availability for some audio decoders). It does not currently implement every Android device codec (for example VP8/VP9, AV1, Opus, Vorbis, MPEG-2 video, Dolby Vision profiles, etc.). A stream container can be recognized and still fail later if its elementary codec is unsupported. The correct fix is to add a real decoder and advertise it only when implemented, not to claim fake capabilities in `MediaCodecList`.
6. **DRM/encrypted IPTV is separate.** Widevine/PlayReady/FairPlay DRM, provider entitlement, key systems, multicast UDP, SRT, RTMP and proprietary middleware require dedicated modules/implementations; no generic MIME switch can make them universal.
7. **RTSP authentication** is passed in the RTSP URI user-info per Media3's documented behavior. Avoid logging that URI.

## Husk manifest log clarification

The Husk line `guest manifest fetch failed` is from `src/app/Husk/GuestManifest.swift`: it requests Husk's GitHub release `manifest.json` with a 15-second timeout to check whether the Android guest image/snapshot has an update. It is not GassPlayer's IPTV playlist request, and the guest update check is explicitly non-fatal. Do not use it as evidence that the IPTV source timed out.

## Official Media3 references

- https://developer.android.com/reference/androidx/media3/exoplayer/source/DefaultMediaSourceFactory
- https://developer.android.com/media/media3/exoplayer/media-items
- https://developer.android.com/media/media3/exoplayer/hls
- https://developer.android.com/media/media3/exoplayer/rtsp
