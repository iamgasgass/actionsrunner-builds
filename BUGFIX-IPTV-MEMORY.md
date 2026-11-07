# IPTV memory-pressure mitigation

The 2026-11-07 GassPlayer reports show a sharp drop in memory available before jetsam while H.264/AAC playback is active. The first run falls from roughly 3.8 GiB available to 50 MiB; the next run creates several Media3 player/decoder instances and changes video resolutions. The log does not prove one single leak, but it is consistent with asynchronous video decode getting ahead of frame consumption and with native/direct-buffer allocations accumulating in a runtime that does not currently perform Java garbage collection (`JVM_GC` is a no-op).

This change adds several bounded/reuse measures:

- VideoToolbox decode submissions are capped at four in-flight access units per decoder. The native callback signals completion, and Java waits briefly for a frame before returning more compressed input to ExoPlayer.
- Asynchronous MediaCodec output is limited to eight unreleased outputs. Input callbacks pause at that limit and resume as ExoPlayer releases output buffers.
- Compressed-input scratch arrays, PCM output buffers, direct input buffers, callback tasks, and output records are reused across packets and channel changes.
- The native audio bridge reuses one PCM byte array per codec instead of pinning a new Java byte array for every audio packet.
- Replaced video-frame and SurfaceView bitmaps are explicitly recycled when resolution/surface dimensions change. SurfaceView also reuses its drawing canvas and releases its buffers when detached.
- Handler messages are pooled and recycled after dispatch/removal/queue shutdown to reduce per-frame message churn.

## Scope and remaining issues

This is a memory-pressure mitigation in Husk's MediaCodec/SurfaceView/runtime path, not proof that every memory leak is fixed. It cannot correct a GassPlayer-side player lifecycle leak if the app itself keeps creating ExoPlayer instances without releasing them.

The supplied logs also contain independent issues not addressed here:

- `MediaSessionManager` / `media_session` service is missing and `GassPlayerMediaService.onCreate` throws a `NullPointerException`.
- Network reads time out or sockets reset.
- The audio renderer reports timestamp discontinuities.
- MPEG Layer II is unavailable on this device/runtime; this matters only for MP2 audio streams (the shown streams use AAC).

## Validation

The Java framework sources compile with `javac --release 8`. The native C change calls Apple's VideoToolbox/CoreMedia APIs and could not be compiled in this Linux environment because the Apple SDK headers/libraries are not available. No iOS IPA build or real-device streaming test has been performed. Rebuild Husk with the source package and verify that `available-before-jetsam` stabilizes during a long channel-switch/playback test; this patch must not be treated as validated until that test passes.
