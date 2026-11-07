# IPTV follow-up: input-buffer tracing and resilient NAL parsing

This follow-up is based on `Husk-main-iptv-buffer-audio-diagnostic-fixed.zip` and preserves its previous memory, codec-buffer, and audio-timestamp changes.

## What changed

- `MediaCodec` now reports each codec instance's full input-slot capacity map, the concrete Java buffer class and capacity returned for each slot, and the first queued sample size per slot. It revalidates the slot at access and before queueing, and includes codec identity in diagnostics. This distinguishes a stale/secondary 4 KiB buffer from an error raised by a different Media3 buffer path. The original log's 3.35 MB `MediaCodec` slots were correctly allocated, but the separate `newLimit > capacity (3087360 > 4096)` exception remained; this change adds evidence to isolate that remaining path rather than pretending it is already fixed.
- The H.264/H.265 NAL reader now validates NAL headers, accepts Annex-B and 1-, 2-, 3-, or 4-byte length-prefixed access units, and parses AVCDecoderConfigurationRecord (`avcC`) and HEVCDecoderConfigurationRecord (`hvcC`) codec configuration data. Allocation and size checks prevent malformed packet lengths from overflowing the output assembly buffer.
- When SPS/PPS/VPS changes, Husk drains and drops the old VideoToolbox session before creating a replacement. A partially parsed access unit is discarded rather than submitting only its prefix.
- Decoder diagnostics report the first bytes of unrecognized access units, access-unit NAL counts and sizes, and VideoToolbox bad-data callbacks as such. `-8969` is VideoToolbox `codecBadDataErr`; it means VideoToolbox rejected the compressed sample, not that the Java input buffer was too small.

## What the latest log says

- The 1920x1072 and 1920x1080 H.264 input buffers were both raised to the expected multi-megabyte capacities in Husk's custom `MediaCodec` implementation.
- The remaining `3,087,360 > 4,096` error is not yet proven to be the same object returned by that `MediaCodec`; the new per-slot and per-codec logs are intended to identify the source.
- The old audio timestamp-discontinuity lines appear in the previous-run section. In the new run, Husk logs that the software-mixer `AudioTrack.getTimestamp()` path is disabled and no new timestamp discontinuity is shown after that point.
- `MediaSessionImpl` now initializes. The `MediaSessionCompat` media-button receiver message and `MediaMetricsService unavailable` are non-fatal platform warnings.
- `Socket reset`, `Socket closed`, and `SocketTimeoutException` are transport failures/cancellations. They cannot be fixed reliably from the runtime alone without the IPTV endpoint's HTTP status, headers, and response body.
- `MPEG Layer II decoder not available` is a capability notice. The stream shown in this log uses AAC, not MP2.

## Validation limits

- All Java framework sources compiled with Java 8 language/API compatibility using JDK 21 (`javac --release 8`).
- The NAL parser passed standalone C smoke tests for Annex-B, 1-, 2-, 3-, and 4-byte length prefixes, `avcC`, and `hvcC`.
- The full iOS app was not built here, and no real IPTV server stream was available for an end-to-end test. Apple VideoToolbox `-8969` can still occur for genuinely malformed, truncated, unsupported, or out-of-sequence H.264 access units. The latest patch improves parsing and logging; it does not claim to make every IPTV stream valid.
