# IPTV playback compatibility fixes (Husk)

This patch addresses three failures visible in the 2026-11-07 GassPlayer / Media3 log:

1. **Too-small codec input buffers.** `KEY_MAX_INPUT_SIZE` is treated as a hint. Video input buffers now have a floor derived from the configured picture size (YUV 4:2:0 frame-size estimate plus headroom), with overflow-safe arithmetic and a 32 MiB per-buffer ceiling. This covers a 1920x1072 access unit of 3,087,360 bytes even when the stream advertises 4096 bytes.
2. **Synthetic audio timestamps.** Husk's software mixer only exposes a consumed-frame estimate; it cannot truthfully provide a hardware presentation timestamp synchronized to the speaker clock. `AudioTrack.getTimestamp()` now returns `false`, allowing Media3 to use the playback-head polling path rather than a fabricated timestamp pair.
3. **Unimplemented TrafficStats methods.** The Java compatibility implementation now supplies the tag/untag methods as inert Java methods. Husk does not expose per-thread network accounting, but this removes the `UNIMPLEMENTED` native-method path without changing socket behavior.
4. **Missing platform MediaSession service.** The Android AOSP `MediaSession` constructor expects a `media_session` platform binder, which Husk does not currently host. A local API-compatible, binder-free `MediaSession`/`MediaSessionManager` facade prevents that constructor path from throwing. It keeps session state/controller objects inside the app, but it does **not** implement OS lock-screen controls, external media-button routing, or a real system media-session binder.

## Not claimed fixed by this patch

- `NoDeclaredBrand` / `None of the available extractors could read the stream`: the log does not include the HTTP status, response Content-Type, or response bytes. This can be an HTML/JSON error response, an invalid/unsupported media segment, or a truncated response. It cannot be attributed to a Husk parser bug from this stack trace alone.
- `SocketTimeoutException`, `Connection reset`, and `Socket closed`: the log does not identify the remote endpoint or whether these are cancelled requests. Server, playlist, network path, and HTTP behavior need separate evidence.
- MPEG Layer II decoder availability: the shown active track is AAC; the missing MP2 capability is not the cause of this AAC session failure.
- `MediaMetricsService unavailable` and missing `TrafficStats` tag methods are non-fatal compatibility warnings.

The source compiles in the Java 8 compatibility check. This is not a full IPA build and does not replace testing against the actual IPTV stream and server.
