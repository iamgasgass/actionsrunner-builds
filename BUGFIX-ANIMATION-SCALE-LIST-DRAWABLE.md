# Fix: ProgressBar / AnimationScaleListDrawable crash

The framework implementation previously omitted the protected
`DrawableContainer.setConstantState(DrawableContainerState)` method. Android's
internal `AnimationScaleListDrawable`, which is used while inflating the
indeterminate `ProgressBar` in Media3 `PlayerView`, calls that method from its
constructor. The missing method caused a `NoSuchMethodError` and crashed the
main thread when the EPG preview/player view was created.

This fix restores the expected method signature, stores the container state,
and makes the compatibility `DrawableContainerState` implementation retain
its children and attach them to the owning container. This avoids replacing the
missing method with a no-op that would leave the progress indicator without
its child drawables.

The change is in:

`src/java-framework/src/android/graphics/drawable/DrawableContainer.java`

Validation performed:

- Java framework sources compile with `javac --release 8` against the bundled
  framework stubs.
- `javap` confirms the expected JVM descriptor:
  `(Landroid/graphics/drawable/DrawableContainer$DrawableContainerState;)V`.
- A small runtime smoke test confirms that a state-added child is attached and
  can be selected by the container.

A complete iOS/IPA build and an on-device GassPlayer regression run were not
performed here.
