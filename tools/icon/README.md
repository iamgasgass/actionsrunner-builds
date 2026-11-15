# App icon

WindowsiOS Universal's icon is Husk's icon (Husk's branch, `tools/icon/`) adapted to Windows: Husk drew
Android's head as Apple's apple; here the apple is cut into Windows' four panes. Same glass look, same
rounded square and the same leaf, in Windows 11 blues.

    python3 tools/icon/render_windows.py tools/icon/husk_leaf.json tools/icon/squircle.png ios/Sources/Assets.xcassets/AppIcon.appiconset

- `husk_leaf.json` — the leaf path from Husk's `shape.json`.
- `squircle.png` — Husk's `Icon-Default.png`; only its alpha (the rounded square) is used.

Writes `Icon-Default.png`, `Icon-Dark.png` and `Icon-Tinted.png` (1024 px). Needs numpy, scipy and Pillow.
