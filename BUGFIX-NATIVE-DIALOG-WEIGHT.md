# Native dialog / weighted content measurement fix

The diagnostic log for GassPlayer showed a floating `DecorView` measured at 723x1012 while its weighted content `FrameLayout` was laid out at 723x2024. `DecorView.makeContent()` creates that content frame with `height=0, weight=1`.

The custom `LinearLayout` measurement code was adding the child's previous WRAP_CONTENT measurement to its allocated weight share for AT_MOST parents. Current AOSP behavior uses the allocated share for zero-sized weighted children unless the app targets Android 6.0 (API 23) or earlier, where the older inconsistent behavior is retained for compatibility.

This patch mirrors that compatibility rule for both vertical and horizontal LinearLayouts. The one-argument `LinearLayout(Context)` constructor now delegates to the full constructor, ensuring the compatibility flag is initialized on every construction path. It also retains the previously included DeviceConfig default-value fix. The temporary `HuskWindow` / `ViewDump` diagnostic logging has been removed from ViewRoot.java.

A full Husk/IPA build has not been run in this environment. The patch was checked against the supplied source tree; the local javac attempt cannot complete because the available environment lacks several platform build dependencies/stubs used by this repository.
