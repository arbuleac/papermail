<picture>
  <source media="(prefers-color-scheme: dark)" srcset="lockup-horizontal-reversed.svg">
  <img src="lockup-horizontal-colour.svg" alt="SuperSparrow" width="405">
</picture>

# SuperSparrow brand marks

The mark is the **italic envelope**: the plainest sign for mail, set in italics. A √2 envelope (ISO C proportions) is sheared 12°, the same angle as the wordmark, so it also reads as quick. Its crease is a tapered V whose arms bow gently upward: a paper fold first, and second a small bird in flight, the sparrow in the name. The front is the deeper blue and the flap the lighter one; the crease between them is never drawn, it is the ground showing through. The wordmark is a geometric italic drawn at the same 12°, never set in a font.

Everything here except this README and `source/` is built by `swift scripts/tools/brand-assets.swift` from the mark in `docs/design/tokens.json` (`ss.italicEnvelope`, the envelope's colours in `layout.appIcon`, the inks and lockup metrics in `layout.brand`) and the wordmark's outlines in `source/wordmark.svg`. Change those and run it again; never edit the files by hand. `--check` writes nothing and lists every file here that no longer matches what the script draws; `scripts/test.sh` runs it. The app icon is built separately (`scripts/tools/app-icon.swift`, spec §5.42), from the same palette.

## Which file

| File | Use |
|---|---|
| `lockup-horizontal-colour` | The default: on white and light grounds |
| `lockup-horizontal-reversed` | On Ink (`#0E1B30`) or other dark grounds; the file's ground is transparent |
| `lockup-horizontal-mono` | One colour, ink, where two colours are not possible |
| `lockup-horizontal-white` | One colour, white, on photographs and on colours other than ink |
| `lockup-stacked-*` | The same four with the mark above the word, for square spaces |
| `wordmark`, `wordmark-white` | The word alone, where the mark or the app icon is already beside it |
| `symbol-colour`, `symbol-reversed` | The mark alone, on light grounds and on dark ones |
| `symbol-mono` | The mark in one colour, from 24 px up. The SVG fills with `currentColor`, which takes the surrounding text colour only when the SVG is inlined in a page; through `<img>`, as a CSS background or opened as a file it draws black. For ink in those places use its PNG, which is drawn in Ink |
| `symbol-mono-small` | The same below 24 px, for 16 and 20 pt in a sidebar or a menu bar: the master's box and corners, its crease 2 wide across the arm where it meets the sides and 5 at the apex, symmetric about it, so the flap and the front never run together. An icon rather than a logo file: the SVG is the mark's square 40-unit grid with no clear space (the sidebar or menu bar gives the space), in `currentColor`; the PNGs are 16, 20 and 32 px squares in Ink, each with the envelope's top and bottom edges on whole pixels |

Each comes as SVG (use it wherever you can) and PNG at twice the SVG's size: the horizontal lockup 1620 × 259 px, the stacked lockup 1402 × 720 px, the wordmark 1320 × 251 px, the mark 1021 × 720 px (`symbol-mono-small` excepted, above). The two-colour SVGs name their gradients after themselves (`ssb-<file>-front`, `ssb-<file>-flap`), so any of them can be inlined in one page together, the colour lockup beside the reversed one, without one file's `url(#…)` reaching the other's ramps.

## Clear space and size

- **Clear space** is a quarter of the envelope's height on every side, measured from the envelope's construction box (the sheared √2 box before its corners are rounded) and from the word's ink. It is built into every file but `symbol-mono-small`, so place the file whole and let nothing into its frame.
- **Minimum size**: the mark alone 16 px in one colour (`symbol-mono-small`, its 16 px PNG), 24 px in full colour; the horizontal lockup with its envelope 16 px tall (the word's cap height is then about 15 px).
- **Beside the word**, the envelope is 1.05 × the cap height and stands on the baseline. Its sheared right side runs parallel to the word's 12° stems, half the envelope's height before the word's origin line, so the shared angle shows. **Stacked**, it is 2.2 × the cap height, centred over the word, 0.6 × the cap height above it.

## Colour

| Name | Hex | Use |
|---|---|---|
| Ink | `#0E1B30` | The wordmark on light grounds, the one-colour lockup |
| Signal | `#0A5BE0` | The one-colour mark on light grounds; the welcome screen's mark on light pages (5.9:1 on white) |
| Signal Dark | `#5AAEFF` | The one-colour mark on dark grounds; the welcome screen's mark on dark pages (7.1:1 on #1E1E1E) |
| Front | `#2C86FF` → `#0A4FE0` | The envelope's front, top to bottom (the app icon and the colour files) |
| Flap | `#6CB4FF` → `#4B9EFF` | The envelope's flap, top to bottom |
| Front, dark | `#3E9BFF` → `#1458EC` | The front on dark grounds and the dark app icon |
| Flap, dark | `#9CCFFF` → `#62AAFF` | The flap on dark grounds and the dark app icon |
| White | `#FFFFFF` | The wordmark on dark grounds, the one-colour white lockup |

The app icon's tile is white to `#E7EFFB` (`#1C2B4B` to `#0A1122` in dark). Every gradient runs top to bottom over its own part, one light direction, and none is glossy. The palette is written once, as `BRAND` in `docs/design/source/tokens_def.py`; `layout.brand`, the app icon's colours and the interface's `brandMark` are all read from it.

## Never

- Stand the envelope upright, lean it back, mirror it, or change its 12° slant or its √2 proportions.
- Draw the crease as a line, fill it in, close it, or make it lopsided; it is always the ground showing through.
- Put the mark in a ring, circle, badge or outline, add letters, a second bird or anything else to it, or make it 3D or glossy.
- Make the flap darker than the front, or use colours outside the palette.
- Set the wordmark in a font, stretch it, re-space it, or change the distance between mark and word.
- Put a white envelope on a blue tile: that is Apple Mail's icon, which the app must not resemble (App Review 5.2.5).

## In the app

The interface draws the mark in one colour (spec §4.11):

- **Welcome screen**: the mark at 65 pt in `brandMark`, the brand's own blue: Signal on light pages and Signal Dark on dark ones (`#084BBA` and `#8CC8FF` under Increase Contrast), in every coloured theme. It is never the theme's ink, so the first screen after launch shows the blue the Dock icon just showed. Under the Graphite accent and in the Gallery theme, which both ask for no colour, it is drawn in `ink`. Under it is the wordmark, drawn from these outlines (`layout.brand.wordmark` in the token file, read from `source/wordmark.svg`) in the theme's `ink` with a 24 pt cap height, about half the envelope's height below it, as on the brand board: the one place the app shows the name with the mark, so it is the real wordmark.
- **Inbox zero**: 40 pt in `ink3`, a quiet neutral.
- **Sizes** are multiples of 5 pt, so the envelope's top and bottom edges (8 and 32 on the mark's 40-unit grid) land on whole points and its long edges stay crisp.
- **The name** is never set in a font beside the mark: wherever the two appear together the name is the drawn wordmark. “Welcome to SuperSparrow” is not printed on the welcome screen; it is what VoiceOver says the screen is, and the wordmark reads as “SuperSparrow”.

Only the app icon and these files use two colours.

## Before release

The name and the mark still need a formal clearance search: USPTO and EUIPO device marks in the Vienna divisions for envelopes and letters and for birds, Nice classes 9, 38 and 42, with a visual check against the other mail apps' envelope icons (Apple Mail, Airmail, Mimestream, Spike, Canary, Edison), SF Symbols' `envelope` family and stock envelope pictograms. The distinctive elements to protect are the 12° slant shared with the wordmark and the tapered, bowed crease that reads as a bird.
