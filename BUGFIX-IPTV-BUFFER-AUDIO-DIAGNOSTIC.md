# IPTV follow-up: codec input-buffer capacity and audio timestamp diagnostics

The 2026-11-07 Husk log confirms that increasing `KEY_MAX_INPUT_SIZE` alone did not fix the media path: Media3 still attempted `ByteBuffer.limit(3,087,360)` on a buffer whose reported capacity was 4,096 bytes. This follow-up changes the custom `MediaCodec` input buffers to heap `ByteBuffer`s. Husk copies queued input into a Java byte array before native decode, so the direct-buffer requirement of Android's platform codec implementation is not needed here. The runtime now checks actual capacity before exposing a buffer and reports the requested and actual sizes.

The direct-buffer allocator is bypassed specifically for codec input because the exception is thrown by `MappedByteBuffer.limit`; this avoids depending on the runtime's direct-buffer capacity implementation for large compressed access units. Output PCM buffers remain separately pooled.

Input, output, and compressed-scratch pools are now bounded by total retained bytes in addition to item counts. This is a mitigation for channel changes/player recreation, not proof that the earlier `Ran out of memory` condition has been eliminated. The prior-run log shows memory pressure reached roughly 3 MiB available before jetsam; that is a separate failure from the 4 KiB buffer exception.

`AudioTrack.getTimestamp()` already returns `false`, because Husk cannot produce a hardware presentation timestamp. This patch adds a one-time diagnostic when Media3 actually queries that method. If timestamp discontinuities continue but the diagnostic never appears, the active audio path is not using this Husk implementation. If it does appear, the new log will help establish whether the error is produced despite the disabled timestamp path.

## Validation limits

Java source compilation is checked separately. No full iOS build, runtime execution, or live IPTV test is available here. The HTTP timeout/socket-close messages still require server/response diagnostics; this patch does not claim to fix them.
