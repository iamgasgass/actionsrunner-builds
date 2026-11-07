# IPTV / Media3 spatializer compatibility fix

Husk does not expose Android's `IAudioService` binder. Media3 1.11.x nevertheless
registers a `Spatializer.OnSpatializerStateChangedListener` when it creates its
audio capabilities. The platform implementation routes that registration through
`AudioManager.getService()`, which is unavailable in Husk and raises
`NoSuchMethodError` on ExoPlayer's playback thread.

`AudioManager.HuskSpatializer` now reports spatialization as unavailable and
implements listener registration/removal as no-ops. This keeps Media3 on the
normal non-spatialized audio path and avoids the unsupported binder call.

This does not implement Android `MediaSessionService`, add an MPEG Layer II
decoder, or repair external IPTV server/network timeouts. Those remain separate
compatibility or connectivity issues to validate with a new runtime log.
