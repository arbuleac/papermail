<picture>
  <source media="(prefers-color-scheme: dark)" srcset="lockup-horizontal-white.svg">
  <img src="lockup-horizontal.svg" alt="SuperSparrow" width="420">
</picture>

# SuperSparrow brand marks

The mark is a **paper plane**: one sheet of white paper folded into a dart and drawn on an isometric grid. The trailing edge, the spine and the keel run on the grid's 1:2 lines, and the near wing and the keel share one straight 45° edge, so the outline is a single clean shape cut by two folds. It sits white on a black tile, paper on ink, so the app that sends your mail reads as a paper plane in the Dock at every size down to 16 pixels. It is black and white only, every edge a straight line, every corner sharp. The wordmark is drawn from straight strokes, mitred joins and 45° chamfers to match, never set in a font.

Everything here except this README and `source/` is built by `swift scripts/tools/brand-assets.swift` from the mark in `docs/design/tokens.json` (`ss.paperPlane`, the inks and lockup metrics in `layout.brand`, the icon grid in `layout.appIcon`) and the wordmark's outlines in `source/wordmark.svg`. Change those and run it again; never edit the files by hand. `--check` writes nothing and lists every file here that no longer matches what the script draws; `scripts/test.sh` runs it. The app icon is built separately (`scripts/tools/app-icon.swift`, spec §5.42) from the same mark and palette.

## Construction

The plane is drawn on the app icon's 1024 canvas, on an 8 px construction grid (128 × 128 units) with an isometric lattice laid over it: verticals every 80 px and lines at 1:2 both ways, anchored on the tail point S (`construction.svg`). Every vertex is a grid point. In the mark's own 80-unit square (one unit = 8 px):

| Vertex | Units | On the 1024 icon |
|---|---|---|
| N, the nose | 80, 10 | 840, 296 |
| WF, the far wing's tip | 0, 30 | 200, 456 |
| T, the far wing's root (the fold opens T–S) | 16, 38 | 328, 520 |
| S, the tail, the near wing's root | 20, 40 | 360, 536 |
| WN, the near wing's tip | 40, 50 | 520, 616 |
| Sk, the keel's top | 20, 43 | 360, 560 |
| X, the keel's tip | 38, 52 | 504, 632 |
| K, the keel's foot | 20, 70 | 360, 776 |

- The far wing is N, WF, T; the near wing N, S, WN; the keel X, Sk, K. One path, `M`, `L` and `Z` only.
- The trailing edge WF–T–S–WN is one straight line at 1:2 (26.6°), and the spine N–S, the plane's axis, runs at 1:2 too.
- The far leading edge N–WF rises 1:4 (14°).
- The near wing's leading edge and the keel's foot, N–WN–X–K, are one 45° line, so the keel is flush with the wing.
- The keel's top Sk–X runs at 1:2, parallel to the trailing edge; its back S–Sk–K is vertical.
- The fold between the wings, N–T against N–S, opens from nothing at the nose to 28.6 px across at the tail (T to S is 32 × 16 px). The gap above the keel is 24 px tall, 21.5 px across, and keeps its width.
- The plane's box is 80 × 60 units (640 × 480 on the icon). On the icon it is placed optically: the point midway between its box's centre and its ink's centroid falls on the canvas's centre, snapped to the grid, so the wings sit up and right and the keel hangs below. Its ink covers about 13% of the tile.

## Which file

| File | Use |
|---|---|
| `lockup-horizontal` | The default: the plane beside the word, on white and light grounds |
| `lockup-horizontal-white` | The same in white, on black, dark grounds and photographs; the file's ground is transparent |
| `lockup-horizontal-on-black` | The white lockup on its own ink ground, the clear space filled |
| `wordmark`, `wordmark-white` | The word alone, where the plane or the app icon is already beside it |
| `symbol`, `symbol-white` | The plane alone, from 24 px wide up. Below that use the app icon, whose 16 and 32 px images are pixel-fitted |
| `construction` | The plane on its grid and lattice, with the lines it is built on and its vertices (for reference, not for use as a logo) |

Each comes as SVG (use it wherever you can) and PNG: the symbol at 1 px per pixel of the icon in the SVG (800 × 640) and 1600 × 1280 px; the lockups 3504 × 770 px and the wordmark 2697 × 636 px, each twice its SVG's size; the construction drawing 1024 px. Every file is paths only: no text, fonts, images or links.

## Clear space and size

- **Clear space** is built into every file, so place the file whole and let nothing into its frame: one step of the lattice (80 px on the icon, 10 units) around the symbol, and half the cap height around the wordmark and the lockups.
- **Minimum size**: the plane at least 24 px wide wherever it appears: the symbol 24 px wide, and the lockup 120 px wide across its ink (130 px for the file with its clear space), where the plane is 24 px. 180 px is the comfortable small size. Below 24 px the folds close up, which is why the app icon carries separate 16 and 32 px masters.
- **Beside the word** the plane is 1.75 cap heights tall (1225 wordmark units at a cap height of 700), its box centred on the cap height, and 0.55 cap heights (385) from the plane's box to the word's origin.

## The wordmark

`source/wordmark.svg` is the master: “SuperSparrow” in straight strokes 100 units wide, cap height 700, x-height 520, descender 190, each letter built from centreline polylines stroked with mitred joins and butt caps and then unioned. Corners are chamfered at 45°, and the S's spine runs at the plane's 1:2 slope. It is 6042 units from its origin to its advance. Outer contours run anticlockwise on screen and counters clockwise, so it fills the same under nonzero and even-odd.

## Colour

| Name | Hex | Use |
|---|---|---|
| Ink | `#0A0A0A` | The app icon's tile, by default and in dark; the plane and the word on light grounds |
| Paper | `#FFFFFF` | The plane on the app icon, in every appearance; the plane and the word on dark grounds |
| Black | `#000000` | Only the tinted app icon's tile, under the white plane the system tints |

There is no other colour, no gradient and no sheen. Grey appears only where the system draws it (Liquid Glass's edge, the tinted and clear icons), where the app tints the template mark with a theme's grey, and in the construction drawing's guides, which are ink and paper mixed. The palette is written once, as `BRAND` in `docs/design/source/tokens_def.py`.

## Never

- Add a colour, a gradient, a shadow, a highlight, an outline or a texture to the plane.
- Round its corners, curve its edges, close or fill its folds, or draw them as lines.
- Rotate it, mirror it, or point the nose anywhere but up and to the right.
- Put it in a circle, a badge or a blue tile, or add a trail, letters or anything else to it.
- Set the wordmark in a font, stretch it, re-space it, or change the distance between plane and word.

## In the app

The interface draws the mark in one colour, as a template image, from the token file's path (spec §4.11):

- **Welcome screen**: the plane across a 64 pt square in the theme's `ink`, dark on a light page and light on a dark one, with the wordmark under it in the same ink at a 24 pt cap height: the one place the app shows the name with the mark, so it is the drawn wordmark (`layout.brand.wordmark`, read from `source/wordmark.svg`). “Welcome to SuperSparrow” is what VoiceOver says the screen is; the wordmark reads as “SuperSparrow”.
- **Inbox zero**: 40 pt in `ink3`, the grey of the hint under it.
- **App icon**: the white plane on the near-black tile, by default and in dark; on black for the system to tint, the white plane its luminance.

## Distinct from other marks

Checked side by side (comparison only; none of these is shipped or drawn into the brand):

- **Apple Mail**: a white envelope on a blue tile. This has no envelope, no blue and no circle (App Review 5.2.5).
- **Spark**: a rounded plane, upright and symmetric, on blue. This is sharp, straight-edged and asymmetric, on black.
- **Telegram**: also a white plane heading up and to the right with a fold, but in a blue circle, with a notched tail and a keel that hangs below. This sits on a black squircle, with a flush keel and a straight trailing edge.
- **Stock send icons and Font Awesome's `paper-plane`**: a separate tail piece that sticks out below the wing. Here the keel stays inside the outline.
- **SF Symbols `paperplane`** (which Apple does not allow in app icons or logos): a symmetric 45° arrowhead with rounded joins and a slotted notch. This has three triangles, sharp corners and a vertical keel back, and heads up at 26.6°.

## Before release

The name and the mark still need a formal clearance search: USPTO and EUIPO device marks in the Vienna division for aircraft and paper planes, Nice classes 9, 38 and 42, with a visual check against other mail and messaging apps' paper planes (Spark, Telegram, Airmail's and others' send glyphs), stock icon sets and SF Symbols' `paperplane` family. The distinctive elements to protect are the isometric construction (the 1:2 trailing edge and spine), the flush 45° line shared by the near wing and the keel, and the white plane on a black tile.
