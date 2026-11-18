# App icon

macOSiOS X's icon is made as WindowsiOS X's (its `tools/icon/render_windows.py`), which follows Husk's icon:
Husk drew Android's head as Apple's apple, WindowsiOS X gave Windows' four panes Apple's bite and leaf, and
here a macOS window — rounded corners, title bar, the three traffic lights — gets the bite and the leaf.
Same glass look, same rounded square and the same leaf, in macOS's violet and blue.

    python3 tools/icon/render_macos.py tools/icon/husk_leaf.json tools/icon/squircle.png ios/Henge/Assets.xcassets/AppIcon.appiconset

- `husk_leaf.json` — the leaf path from Husk's `shape.json`.
- `squircle.png` — Husk's `Icon-Default.png`; only its alpha (the rounded square) is used.

Writes `Icon-Default.png`, `Icon-Dark.png` and `Icon-Tinted.png` (1024 px). Needs numpy, scipy and Pillow.
`docs/icon.png` is `Icon-Default.png` at 512 px.
