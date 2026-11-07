# IPTV playback compatibility: unsupported spatializer

The GassPlayer/Media3 logs showed `NoSuchMethodError` from
`Spatializer.getImmersiveAudioLevel()` while calling `AudioManager.getService()`.
Husk does not provide the Android `IAudioService` binder needed for spatial audio.

`AudioManager.getSpatializer()` now returns a real `Spatializer` object that reports
spatialization as unsupported (`NONE`, unavailable, disabled, and not spatializable).
This preserves the Android API's non-null handle while allowing Media3 to select
ordinary non-spatialized audio. It does not implement spatial audio.

This change does not implement Android's `media_session` system service and does not
solve network timeouts or server-side stream disconnects. Those are separate items
which need a follow-up log after this change is tested.
