# App icon

The six icon looks (default, dark, tinted, clear light, clear dark, tinted light) are drawn from one glyph.

- `shape.json` — the glyph as paths: the body, the leaf and the two eyes, traced from the source artwork with `shape.py`.
- `render.py shape.json <rounded-square.png> <out-dir>` — draws every look at 1024 px. The second argument is any existing
  1024 px icon; only its alpha (the rounded square) is used, so every look keeps the same outline.

Copy the results into `src/app/Husk/Assets.xcassets/*.appiconset/` and, at 256 px, into `src/app/Husk/Resources/icon-*.png`
(the in-app previews). Needs Python with numpy, scipy, Pillow and scikit-image.
