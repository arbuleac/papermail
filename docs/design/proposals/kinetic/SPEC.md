# Flit — the SuperSparrow design language

Proposal for direction **“Kinetic minimal”** · v1 · 2 November 2026
Files in this folder: `SPEC.md` (this document), `specimen.html` (self-contained specimen, tokens as CSS custom properties), `specimen-light.png`, `specimen-dark.png` (1440 wide renders).

Flit is named for how a sparrow moves: short, direct hops that are over before you notice them. The language is built on one idea: **the keystroke is the animation.** Every action draws its end state in the same frame as the key press; motion arrives afterwards only to confirm what already happened, and any key cuts it short. Around that idea sit one vivid signature color (Flare), one signature shape (the wing cut), one signature line (the contrail) and a visible keyboard vocabulary (keycaps).

Scope matches `docs/ARCHITECTURE.md`: unified inbox, six views, Focused/Other, stacked conversation cards, plain composer, undo for everything, keyboard first. No folder or label UI appears anywhere in this language.

---

## 1. Principles

1. **The key beats the pixel.** State changes render in the frame of the keystroke (selection, star, archive, read). Motion is a 90–200 ms confirmation layered on top of an already-final state, and a new key always completes the running animation at once. Nothing waits for the network, so nothing shows a spinner for a local action.
2. **Flare means you.** The signature color marks only what is about the person right now: where you are (the wing slab, the selected rail item), what you can fire (the primary button), what you just did (the toast's Undo and its contrail), and what is waiting for you (unread dot, star). Everything else is ink and graphite. Selection and primary-action Flare is shown only in the key window; inactive windows fall back to graphite, exactly as AppKit does with its own accent. Content marks (unread, star) keep their color.
3. **Say it twice.** Every state has two carriers: shape, weight, glyph or words, plus color. Unread = dot + semibold. Selected = wing-cut slab + inverted text. Error = glyph + sentence. Account = monogram or address + color. Pending sync = contrail glyph + VoiceOver phrase.
4. **Quiet until touched.** Hints, counts and chrome sit low (ink badges, graphite icons, keycaps that appear on hover) so mail content is the loudest thing on screen. Hover and focus raise them instantly.

## 2. Signature elements

| Element | What it is | Where it appears | Rule |
|---|---|---|---|
| **Wing cut** | A rounded rectangle whose top-leading and bottom-trailing corners are large and whose other two are small (14/4 on a row). It reads as a feather or a forward-leaning wing. | Wing slab (selected row), selected rail item (the avatar morphs from circle to wing), segmented thumb, primary button, toast, undo-send panel, g-sequence HUD. | The wing cut marks the present only: where you are, what fires, what just happened. Containers, cards, fields and secondary buttons keep symmetric radii. In right-to-left layouts the cut mirrors (top-trailing / bottom-leading large). |
| **Wing slab** | The selection highlight: a Flare wing-cut slab inset 6pt horizontally and 2pt vertically inside the 72pt row, with every glyph and line of text inverted to white. | Focused list. | Snaps to the new row with no animation. Turns graphite with a 3pt leading wing bar when the list is not first responder or the window is inactive. |
| **Contrail** | A 2pt line that is solid Flare at its head (a 4pt dot) and fades to transparent behind it, like a vapour trail. | Undo countdown along the bottom of toasts and the undo-send panel (drains right to left); sync activity on the top edge of the sync line; skeleton loading; determinate and indeterminate progress; spinner arc; the `flit.contrail` glyph for pending sync on rows; the flight line on the welcome screen and app icon. | A contrail always means *time is moving*: a countdown or work in flight. It is never decoration. |
| **Keycaps** | Small Rounded caps (16pt, 22pt large) with a heavier bottom edge. | Search field (“/”), quick reply (“R”), message footer (R, A, F), Send (⌘↩), toasts (Z), hint tooltips, empty states, welcome, g-sequence HUD, cheat sheet. | Every visible command that has a single-key shortcut shows its keycap at least once in its natural place. Menus use the native shortcut column instead. |
| **Flit mark** | A sparrow in flight with a forked tail and a swept wing (custom glyph `flit.mark`). | App icon, welcome, unified inbox rail item, reader empty state, alert icon, notification icon. | One mark, three sizes (16, 21–24, 46–78). The perched variant (`flit.perch`) is reserved for inbox zero. |

## 3. Foundations

### 3.1 Color

**Architecture: one table, three outputs.** All color values live in one Swift data table in SSCore (`Sources/SSCore/Design/FlitTokens.swift`, plain hex strings, no AppKit), with four values per token: light, dark, light increased contrast, dark increased contrast. From it:

- **AppKit:** `NSColor+Flit.swift` builds one dynamic `NSColor(name:dynamicProvider:)` per token. The provider picks with `appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])`, so Increase Contrast is handled by AppKit itself.
- **SwiftUI (Settings):** `Color(nsColor: .flitAccent)` and so on; no asset catalog duplication.
- **WKWebView reader:** `FlitTokens.cssVariables` emits the four `:root` blocks exactly as in `specimen.html` (light default, `prefers-color-scheme: dark`, `prefers-contrast: more`, both). `ConversationShellAssets.css` interpolates it at the top. The shell also mirrors `NSWorkspace.accessibilityDisplayShouldIncreaseContrast`, `…ShouldReduceMotion` and `…ShouldReduceTransparency` as classes `ss-ic`, `ss-rm`, `ss-rt` on `<html>` (set from the app on change), because WebKit's media queries are not guaranteed to track all three in every OS version. Rules are written for both the media query and the class.

Alpha values are written `#RRGGBB @a` and are composited over the surface named in the contrast table.

**Signature color: Flare.** A vivid vermilion that nods to the rufous wing bar of the house sparrow. No other mainstream mail client uses this hue (blue: Mail, Outlook, Spark, Mimestream; purple: Superhuman, Proton; yellow-green: HEY), so a single slab of it is recognizable at a glance. Flare 600 `#D2421A` is the working accent because it is the most vivid vermilion that still carries white text at ≥ 4.5:1 (4.63:1). Flare 500 `#F25A26` is brighter and reserved for non-text brand surfaces (icon, welcome mark).

**System accent decision: Flare is the app accent; custom-drawn signature elements ignore the system accent.** SuperSparrow ships Flare as its `NSAccentColorName` asset. When the user's system accent is Multicolor (the default), native controls (menus, NSSwitch, NSButton checkboxes, focus rings on native fields) adopt Flare too, and the whole app is consistent. When the user picks a specific accent (blue, graphite…), native controls follow the user's choice, which is the respectful Mac behavior; the custom-drawn signature elements (wing slab, primary button, unread dot, star, contrail, rail perch) stay Flare because their contrast is tuned per appearance and because they are the product's identity. Text selection in the reader and composer always follows the system highlight color.

#### Reference ramps

| Graphite | 0 | 25 | 50 | 100 | 150 | 200 | 300 | 400 | 500 | 600 | 700 | 750 | 800 | 850 | 900 | 950 | 1000 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Hex | `#FFFFFF` | `#FAFAFC` | `#F4F4F7` | `#EDEDF1` | `#E4E4E9` | `#D6D6DD` | `#BBBBC4` | `#96969F` | `#77777F` | `#5C5C66` | `#45454E` | `#34343B` | `#2A2A30` | `#212126` | `#1A1A1E` | `#121215` | `#0A0A0C` |

Graphite is cool (hue ≈ 280, chroma < 3) so Flare is the only warm thing in the interface.

| Flare | 50 | 100 | 200 | 300 | 400 | 500 | 600 | 700 | 800 | 900 |
|---|---|---|---|---|---|---|---|---|---|---|
| Hex | `#FFF1EB` | `#FFE0D2` | `#FFC0A5` | `#FF9A73` | `#FF7A4A` | `#F25A26` | `#D2421A` | `#B5370F` | `#8F2B0C` | `#661F09` |

#### Semantic tokens

Selection is covered by `bg-selected`, `bg-selected-inactive`, `border-selected-inactive`; focus by `focus-ring`; semantic status by `success`, `warning`, `danger`, `info` (ink), their `-tint` fills and `danger-fill`.

| Token | Light | Dark | Light IC | Dark IC | Use |
|---|---|---|---|---|---|
| `bg-rail` | `#EAEAEE` | `#1F1F24` | `#E1E1E7` | `#141418` | Account rail (solid fallback under the sidebar material) |
| `bg-list` | `#FFFFFF` | `#1A1A1E` | `#FFFFFF` | `#0F0F12` | List pane, composer body, quick reply bar |
| `bg-canvas` | `#F4F4F7` | `#121215` | `#EBEBF0` | `#000000` | Reader background behind cards |
| `bg-card` | `#FFFFFF` | `#212126` | `#FFFFFF` | `#1A1A1F` | Message cards, settings groups |
| `bg-sunken` | `#EDEDF1` | `#2A2A30` | `#E4E4EA` | `#26262C` | Search field, text fields, count pills, segmented track |
| `bg-elevated` | `#FFFFFF` | `#2A2A30` | `#FFFFFF` | `#26262C` | Popovers, undo-send panel body, menus drawn by us |
| `bg-toast` | `#1D1D22` | `#38383F` | `#000000` | `#45454E` | Toasts, hint tooltips, g-sequence HUD (inverse in light) |
| `bg-hover` | `#16161D` @0.045 | `#FFFFFF` @0.055 | `#16161D` @0.08 | `#FFFFFF` @0.1 | Hover wash on rows, ghost buttons, rail items |
| `bg-pressed` | `#16161D` @0.09 | `#FFFFFF` @0.1 | `#16161D` @0.14 | `#FFFFFF` @0.16 | Pressed wash |
| `bg-selected` | `#D2421A` | `#D2421A` | `#B5370F` | `#C43D14` | Wing slab: selected row in a focused list |
| `bg-selected-inactive` | `#E4E4E9` | `#34343B` | `#DCDCE3` | `#3A3A42` | Wing slab when the list is not first responder or the window is inactive |
| `bg-accent-tint` | `#D2421A` @0.1 | `#FF7A4A` @0.16 | `#B5370F` @0.14 | `#FFA27E` @0.2 | Drop targets, token hover, active quick-reply field wash |
| `fg-primary` | `#17171B` | `#F3F3F6` | `#000000` | `#FFFFFF` | Primary text and icons |
| `fg-secondary` | `#5C5C66` | `#A3A3AE` | `#3B3B44` | `#D0D0DA` | Snippets, metadata, placeholders, secondary icons |
| `fg-disabled` | `#A3A3AD` | `#5E5E68` | `#85858F` | `#7A7A84` | Disabled labels (exempt from contrast minimums) |
| `fg-on-accent` | `#FFFFFF` | `#FFFFFF` | `#FFFFFF` | `#FFFFFF` | Text and glyphs on the wing slab, primary buttons, badges |
| `fg-on-toast` | `#F5F5F7` | `#F5F5F7` | `#FFFFFF` | `#FFFFFF` | Toast text |
| `fg-on-toast-secondary` | `#B3B3BD` | `#D0D0D8` | `#D0D0D8` | `#E0E0E8` | Toast secondary text, kbd in toasts |
| `fg-toast-action` | `#FF9A73` | `#FFA680` | `#FFB08F` | `#FFC0A5` | Undo action in toasts |
| `fg-accent` | `#BC3A10` | `#FF7A4A` | `#A2310C` | `#FFA27E` | Accent text and links on surfaces |
| `fg-toast-danger` | `#FF8597` | `#FF8597` | `#FFA3B1` | `#FFB3BE` | Error glyph inside toasts |
| `fg-toast-success` | `#5BD98A` | `#5BD98A` | `#7AE6A2` | `#8CEBB0` | Success glyph inside toasts |
| `border-hairline` | `#18181F` @0.1 | `#FFFFFF` @0.1 | `#8C8C96` | `#8A8A96` | Dividers, card edges (decorative in standard contrast) |
| `border-control` | `#85858F` | `#7A7A86` | `#5C5C66` | `#A3A3AF` | Text field, checkbox, off-toggle and secondary-button boundary (>=3:1) |
| `border-selected-inactive` | `#7C7C86` | `#8C8C98` | `#5C5C66` | `#B0B0BC` | Leading wing bar of an inactive selection (>=3:1) |
| `focus-ring` | `#D2421A` | `#FF7A4A` | `#A2310C` | `#FFA27E` | Keyboard focus ring, 2pt (3pt in increased contrast) |
| `accent` | `#D2421A` | `#D2421A` | `#B5370F` | `#C43D14` | Flare: primary buttons, slab, unread dot (light), badges |
| `accent-hover` | `#BF3B15` | `#BF3B15` | `#A2310C` | `#B5370F` | Primary button hover |
| `accent-pressed` | `#A8330F` | `#A8330F` | `#8F2B0C` | `#A2310C` | Primary button pressed |
| `accent-signature` | `#F25A26` | `#F25A26` | `#F25A26` | `#F25A26` | App icon, welcome mark, contrail head glow (decorative only) |
| `unread` | `#D2421A` | `#FF7A4A` | `#B5370F` | `#FFA27E` | Unread dot |
| `star` | `#D2421A` | `#FF7A4A` | `#B5370F` | `#FFA27E` | Star glyph (filled) |
| `success` | `#17772F` | `#3FCF7A` | `#11652A` | `#7AE6A2` | Success ink: sent, connected, up to date |
| `warning` | `#8F5B00` | `#F2B544` | `#6E4600` | `#FFD27A` | Warning ink: offline, paused, slow |
| `danger` | `#C01F3D` | `#FF6B80` | `#9C1430` | `#FF9BA9` | Danger ink: errors, destructive text |
| `danger-fill` | `#C8213F` | `#C8213F` | `#A3162F` | `#B81C38` | Destructive button fill (white text) |
| `danger-fill-hover` | `#B01C38` | `#B01C38` | `#8C1229` | `#A3162F` | Destructive button hover |
| `danger-fill-pressed` | `#981830` | `#981830` | `#780F23` | `#8C1229` | Destructive button pressed |
| `info` | `#0B62C4` | `#5EA8FF` | `#084C99` | `#99C8FF` | Info ink: remote-images banner icon, tips |
| `success-tint` | `#1A7F37` @0.1 | `#3FCF7A` @0.14 | `#1A7F37` @0.14 | `#3FCF7A` @0.2 | Success banner fill |
| `warning-tint` | `#B87800` @0.12 | `#F2B544` @0.14 | `#B87800` @0.16 | `#F2B544` @0.2 | Warning banner fill |
| `danger-tint` | `#C01F3D` @0.09 | `#FF6B80` @0.14 | `#C01F3D` @0.13 | `#FF6B80` @0.2 | Danger banner fill |
| `info-tint` | `#0B62C4` @0.09 | `#5EA8FF` @0.14 | `#0B62C4` @0.13 | `#5EA8FF` @0.2 | Info banner fill |
| `kbd-bg` | `#FFFFFF` | `#34343B` | `#FFFFFF` | `#3A3A42` | Keycap face |
| `kbd-border` | `#18181F` @0.18 | `#FFFFFF` @0.14 | `#5C5C66` | `#B0B0BC` | Keycap edge (bottom edge doubles) |
| `kbd-on-accent-bg` | `#000000` @0.22 | `#000000` @0.22 | `#000000` @0.3 | `#000000` @0.3 | Keycap face inside a Flare button |
| `kbd-on-toast-bg` | `#FFFFFF` @0.12 | `#FFFFFF` @0.12 | `#FFFFFF` @0.16 | `#FFFFFF` @0.16 | Keycap face inside toasts, tooltips, HUD |
| `badge-on-slab-bg` | `#FFFFFF` | `#FFFFFF` | `#FFFFFF` | `#FFFFFF` | Count badge pill inside the wing slab (text = accent) |
| `kbd-fg` | `#45454E` | `#D6D6DE` | `#17171B` | `#FFFFFF` | Keycap legend |


Rules:
- **Increased contrast** darkens Flare one step (600 → 700) in light and replaces every alpha hairline with a solid border that clears 3:1; focus rings go from 2pt to 3pt; secondary text darkens to ≥ 8:1.
- **Status ink is never alone.** `success`, `warning`, `danger`, `info` always sit next to a glyph (checkmark, wifi.slash, exclamationmark.triangle, info/photo) and a sentence.
- `fg-disabled` is exempt from contrast minimums (WCAG 1.4.3), but disabled controls also lose their boundary contrast and never rely on color to say “disabled”: the control stops responding to hover and the tooltip explains why where it matters (Send: “Add a recipient”).

#### Account palette (10)

Accounts are colored in this order as they are added; the user can change it in Settings. The palette is separated by **lightness as well as hue** so that it survives color-vision deficiencies, and every color clears 3:1 against the list, rail, canvas and card in its own appearance. Rail avatars use the initials ink listed (white or `#141417`, whichever clears 4.5:1).

| # | Name | Light | Dark | Light IC | Dark IC | Initials ink (L / D) |
|---|---|---|---|---|---|---|
| 1 | Cobalt | `#006CD3` | `#669FFF` | `#005CC0` | `#7CB2FF` | white / `#141417` |
| 2 | Amber | `#B5761C` | `#FFBF4B` | `#A16502` | `#FFD05B` | `#141417` / `#141417` |
| 3 | Orchid | `#B8338D` | `#D959AC` | `#A41B7B` | `#EE6DBF` | white / `#141417` |
| 4 | Emerald | `#1F8555` | `#5CDE9A` | `#007244` | `#71F2AD` | white / `#141417` |
| 5 | Indigo | `#393BA4` | `#6F66D3` | `#202B91` | `#8377E7` | white / white |
| 6 | Rose | `#C7354D` | `#FF7682` | `#B21D3D` | `#FF8994` | white / `#141417` |
| 7 | Teal | `#008FA7` | `#00B6D5` | `#007C95` | `#1CCAE9` | `#141417` / `#141417` |
| 8 | Olive | `#476201` | `#87A342` | `#355100` | `#9AB554` | white / `#141417` |
| 9 | Cocoa | `#6D3C26` | `#9B654C` | `#5B2C17` | `#AF765D` | white / white |
| 10 | Graphite | `#3B3D45` | `#80838E` | `#2C2E35` | `#9396A0` | white / `#141417` |

Minimum pairwise CIEDE2000 distance across all 45 pairs, after simulating each vision type (Machado et al. 2009, severity 1.0):

| Vision | Light: min ΔE00 (pair) | Dark: min ΔE00 (pair) | First 4 only, light / dark |
|---|---|---|---|
| Typical | 18.4 (orchid / rose) | 19.7 (orchid / rose) | 35.5 / 36.9 |
| Protanopia | 6.8 (orchid / indigo) | 8.0 (orchid / indigo) | 11.6 / 12.0 |
| Deuteranopia | 6.8 (emerald / rose) | 6.5 (emerald / rose) | 16.6 / 16.0 |
| Tritanopia | 8.3 (orchid / rose) | 6.2 (orchid / rose) | 11.4 / 14.4 |


Identity is never color alone: the rail avatar shows a **domain monogram** (C for contoso.com, G for gmail.com, O for outlook.com; a second letter is added on collision, editable in Settings) because a single-user mail client showing the user's own initials on every account carries no information. The reader header shows an account chip (monogram + address), and every pip has a tooltip and VoiceOver label with the address. Row pips appear only in the unified view.

Method: CIEDE2000 between every pair after simulating protanopia, deuteranopia and tritanopia with the Machado 2009 matrices at full severity, in linear RGB. The script is in the appendix.

#### Avatar palette (8, tinted)

Sender avatars are **tinted** (pale fill, deep initials) rather than solid. That keeps 9 rows of faces quieter than the account pips and the Flare slab, and replaces today's four avatar palettes with one. Hue index = stable hash of the lowercased address mod 8 (the existing `AvatarCache.colorIndex(for:)` contract). Initials: Rounded semibold, 1 or 2 letters.

| # | Name | Light bg / fg | Dark bg / fg | Light IC bg / fg | Dark IC bg / fg |
|---|---|---|---|---|---|
| 1 | Sky | `#D2EBFF` / `#005E9C` | `#1E4158` / `#8BDAFF` | `#C9E6FF` / `#004782` | `#13384E` / `#BBEEFF` |
| 2 | Iris | `#E8E5FF` / `#474E98` | `#3C3B56` / `#CECBFF` | `#E2DFFE` / `#2C377E` | `#33324D` / `#E7E3FF` |
| 3 | Orchid | `#FCE0F4` / `#853775` | `#513549` / `#FFBCEF` | `#F9DAF0` / `#6B1D5C` | `#472C40` / `#FFD9FE` |
| 4 | Rose | `#FFDFE2` / `#962F44` | `#583337` / `#FFB8C1` | `#FFD8DB` / `#7A112E` | `#4F2A2E` / `#FFD7DC` |
| 5 | Amber | `#FAE5CE` / `#754C02` | `#4D3A23` / `#F8C990` | `#F6DFC5` / `#5B3500` | `#43321B` / `#FFE2B8` |
| 6 | Moss | `#DFEDD3` / `#325F16` | `#334228` / `#B8DC9D` | `#D8E7CB` / `#184700` | `#2A3920` / `#D6F0C1` |
| 7 | Lagoon | `#C8F0EC` / `#006660` | `#104542` / `#6DE4DC` | `#BDECE7` / `#004D49` | `#033C39` / `#A7F6F0` |
| 8 | Slate | `#E4E9F0` / `#4D5661` | `#3A3E44` / `#CBD2DD` | `#DEE3EA` / `#363E49` | `#31353A` / `#E1E9F3` |


### 3.2 Typography

Families (system only): **SF Pro** for content (`NSFont.systemFont`, CSS `-apple-system, system-ui`), **SF Pro Rounded** for chrome and numerals (`NSFont.systemFont(ofSize:weight:)` with `fontDescriptor.withDesign(.rounded)`, SwiftUI `.fontDesign(.rounded)`, CSS `ui-rounded`), **SF Mono** for credentials and code (`NSFont.monospacedSystemFont`, CSS `ui-monospace`). **New York** is not used in v1 (reserved for a possible reading-font option). No bundled or web fonts.

Why Rounded for chrome: the rounded terminals echo the wing cut and make numerals (times, counts, keycaps) feel soft and quick; content stays in SF Pro because long runs of Rounded text read slower.

| Role | Family | Size (pt) | Weight | Line height | Tracking (pt) | Used for |
|---|---|---|---|---|---|---|
| Display | SF Pro Rounded | 26 | Bold 700 | 32 | −0.4 | Welcome title |
| Title | SF Pro Rounded | 20 | Semibold 600 | 26 | −0.25 | Reader subject |
| Heading | SF Pro Rounded | 16 | Bold 700 | 20 | −0.1 | List title menu, empty-state titles, rail monograms |
| Reading | SF Pro | 14 | Regular 400 | 21 | 0 | Message bodies, composer body, quick reply text, welcome subtitle |
| Body | SF Pro | 13 | Regular 400 (Medium 500 for toast text and collapsed-card names) | 18 | 0 | Read subject and sender, field values, settings rows |
| Body Strong | SF Pro | 13 | Semibold 600 | 18 | 0 | Unread sender and subject, card sender, settings row titles |
| Label | SF Pro Rounded | 13 (14 on large buttons) | Semibold 600 | 16 | 0 | Buttons, title-menu items drawn by us |
| Label Small | SF Pro Rounded | 12 | Semibold 600 (Medium 500 for unselected segments) | 16 | 0 | Small buttons, reader tools, segmented filter, large keycaps |
| Small | SF Pro | 12 | Regular 400 (Medium 500 for attachment names) | 16 | 0 | Snippets, recipients line, banners, settings detail, captions under controls |
| Caption | SF Pro Rounded | 11 | Medium 500 | 14 | +0.1 | Times, dates, sync line, attachment sizes, account chip |
| Micro | SF Pro Rounded | 10 | Semibold 600 (Bold 700 in badges) | 12 (16 inside a 16pt pill) | +0.3 | Keycaps, count badges, “Other” tag, rail badges |
| Mono | SF Mono | 12 | Regular 400 | 16 | 0 | OAuth client ID and secret, `pre`/code in plain-text bodies |

Rules:
- All times, dates, counts and sizes use tabular figures (`.monospacedDigit()` / `font-variant-numeric: tabular-nums`) so rows do not jitter while scrolling or when a count changes.
- Avatar initials are Rounded Semibold at 36% of the avatar diameter (13 at 36, 10 at 28, 9 at 24, 7 at 18–22). Rail monograms are Heading 16 Bold.
- Truncate with a tail ellipsis on one line everywhere in the list and headers; never tighten letter spacing to fit (`allowsDefaultTighteningForTruncation = false`, as today).
- Dynamic type: macOS has no system text-size setting for AppKit apps; General settings offers **Text size: Default / Large** which adds +2pt to Reading, Body, Small and Caption and switches rows to 84pt (comfortable) / 60pt (compact). Every metric below scales from those row heights.
- In AppKit, apply tracking with `.kern`; build attribute dictionaries once and share them (current `ConversationRowContent.Style` pattern).

### 3.3 Spacing

4pt base. Tokens: `space-0.5` 2 · `space-1` 4 · `space-1.5` 6 · `space-2` 8 · `space-3` 12 · `space-4` 16 · `space-5` 20 · `space-6` 24 · `space-8` 32 · `space-12` 48. Two is only for optical nudges (slab vertical inset, badge offsets). Pane gutters are 12 (list) and 24 (reader); cards stack with 8; card padding 18 × 20; field rows are 40.

### 3.4 Radii and the wing cut

| Token | Value | Used for |
|---|---|---|
| `radius-xs` | 4 | Keycaps (16pt), checkbox, inline code |
| `radius-sm` | 6 | 24pt controls (small buttons, small icon buttons, popup), tooltips, file-type tiles, menu item highlight |
| `radius-md` | 8 | 28–32pt controls (buttons, icon buttons, title menu, fields, segmented track), attachment chips, banners |
| `radius-lg` | 12 | Message cards, quick reply field, menus, windows we draw (system draws real windows) |
| `radius-xl` | 16 | Notification-like floating panels if ever drawn by us |
| `radius-pill` | h/2 | Count badges, tags, address tokens, account chip, quoted-text fold |
| `wing-sm` | 7 / 2 | Segmented thumb, small primary button (≤ 24pt) |
| `wing-md` | 10 / 3 | Primary button 28–32pt, notification icon tile |
| `wing-lg` | 14 / 4 | Wing slab (68pt), toast (36pt), undo-send panel (44pt), g-sequence HUD, alert icon |
| `wing-av` | 14 / 5 | Selected 36pt rail avatar or unified tile |
| `wing-xl` | 18 / 6 | 64–72pt brand tiles (welcome mark, about box) |

Wing values are `large / small`: large on top-leading and bottom-trailing, small on top-trailing and bottom-leading. CSS: `border-radius: 14px 4px 14px 4px`. SwiftUI: `UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 4, bottomTrailingRadius: 14, topTrailingRadius: 4, style: .continuous)`. AppKit: build once per size and cache:

```swift
/// Wing-cut path in a flipped view (y grows down). Cached per (rect.size, large, small).
static func wing(_ r: CGRect, large L: CGFloat, small s: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: CGPoint(x: r.minX + L, y: r.minY))
    p.line(to: CGPoint(x: r.maxX - s, y: r.minY))
    p.appendArc(from: CGPoint(x: r.maxX, y: r.minY), to: CGPoint(x: r.maxX, y: r.minY + s), radius: s)
    p.line(to: CGPoint(x: r.maxX, y: r.maxY - L))
    p.appendArc(from: CGPoint(x: r.maxX, y: r.maxY), to: CGPoint(x: r.maxX - L, y: r.maxY), radius: L)
    p.line(to: CGPoint(x: r.minX + s, y: r.maxY))
    p.appendArc(from: CGPoint(x: r.minX, y: r.maxY), to: CGPoint(x: r.minX, y: r.maxY - s), radius: s)
    p.line(to: CGPoint(x: r.minX, y: r.minY + L))
    p.appendArc(from: CGPoint(x: r.minX, y: r.minY), to: CGPoint(x: r.minX + L, y: r.minY), radius: L)
    p.close()
    return p
}
```

For layer-backed views on macOS 13+, `CALayer.cornerRadius` cannot do mixed radii, so the slab and toast use a `CAShapeLayer` with this path (one per visible slab; only one row is selected at a time unless multi-select).

### 3.5 Borders and hairlines

- **Hairline** (`border-hairline`): 1pt (1px at any scale; on 2x displays draw at 0.5pt only for the list row separators, which are inset to the text column at x = 70). Used for pane dividers, card edges, field-row separators, menu separators. Decorative in standard contrast; solid and ≥ 3:1 in increased contrast.
- **Control boundary** (`border-control`): 1pt inside edge on every editable or toggleable control (text fields, search, quick reply, checkbox, off toggle, secondary buttons, popup buttons). ≥ 3:1 against the surface around it in all four appearances (WCAG 1.4.11).
- **Focus ring** (`focus-ring`): 2pt (3pt in increased contrast), drawn outside the control with a 2pt gap in the surrounding surface color for filled controls (buttons, checkboxes, toggles), and directly on the edge for fields (inner 1pt + outer 2pt, so the field edge itself turns Flare). Never animated. Rows do not get rings: in the list, the wing slab is the focus indicator.
- **Wing bar** (`border-selected-inactive`): 3 × (h − 32)pt, radius 2, 4pt from the slab's leading edge, only on an inactive slab.

### 3.6 Elevation

Flat by default. Rows and collapsed cards never cast shadows (performance budget and calm). Values are `x y blur spread color`.

| Level | Light | Dark | Used for |
|---|---|---|---|
| e0 | none (1pt `border-hairline`) | none (1pt `border-hairline`) | Rows, collapsed cards, fields, settings groups |
| e1 | `0 1 2 0 #000 @0.06`, `0 1 1 0 #000 @0.04` | `0 1 2 0 #000 @0.40` + inner `0 0 0 1 #FFF @0.02` | Expanded message card |
| e2 | `0 6 16 0 #000 @0.12`, `0 1 3 0 #000 @0.08` | `0 8 20 0 #000 @0.45`, `0 1 3 0 #000 @0.35` + inner `0 0 0 1 #FFF @0.06` | Hint tooltips, our popovers (title menu uses native NSMenu shadow) |
| e3 | `0 12 32 0 #000 @0.20`, `0 2 6 0 #000 @0.10` | `0 14 36 0 #000 @0.55`, `0 2 6 0 #000 @0.35` + inner `0 0 0 1 #FFF @0.08` | Toast, undo-send panel, g-sequence HUD |
| window | system window shadow | system window shadow | Main, composer, settings, welcome |

AppKit: two shadows = two sublayers with an explicit `shadowPath` (the wing path), so no offscreen pass. Increased contrast keeps the shadows and adds the solid border.

### 3.7 Materials

| Surface | Material | Reduced transparency |
|---|---|---|
| Account rail (72 × full height) | `NSVisualEffectView` `.sidebar`, `.behindWindow`, state `.followsWindowActiveState` | Solid `bg-rail` |
| Welcome window background | `.underWindowBackground` | Solid `bg-canvas` |
| Settings toolbar | System default | System default |
| Everything else (list, reader, cards, toasts, HUD, panels) | None. Solid tokens. | Same |

The list is never translucent: it scrolls 100,000-row mailboxes and must not blend per frame. Toasts and the HUD are solid inverse surfaces for contrast; they are small and transient, which is exactly where vibrancy costs more than it gives.

### 3.8 Motion

| Token | Duration | Curve | Notes |
|---|---|---|---|
| `instant` | 0 ms | — | Selection, focus ring, hover in, content swap |
| `snap` | 90 ms | linear or `flit-in` | Press release, hover out, unread dot out, fades in reduced motion |
| `quick` | 140 ms | `flit-out` | Toast in, wing morph, quick reply grow, row fly-out |
| `move` | 200 ms | `flit-out` | Rows closing the gap after archive/trash, undo fly-back |
| `max` | 250 ms | — | Hard ceiling. Nothing in Flit runs longer, except continuous indicators and the undo countdown |

Curves: `flit-out` = cubic-bezier(0.2, 0.8, 0.2, 1) (enter, decelerate), `flit-in` = cubic-bezier(0.4, 0, 1, 1) (exit, accelerate), `pop` = cubic-bezier(0.34, 1.56, 0.64, 1) (star only; AppKit: `CASpringAnimation` mass 1, stiffness 520, damping 26, settles in ≈ 180 ms).

What animates, on the one affected row or overlay only:

| Action | Frame 0 (with the key) | Then |
|---|---|---|
| `j` / `k`, click | Slab drawn on the new row; reader swaps to the pre-rendered view | Nothing |
| `e` archive, `#` trash | Row removed from the model; slab on the next row; toast shown | Removed row content slides 24pt toward the trailing edge and fades out (140 ms `flit-in`); rows below close the 72pt gap (200 ms `flit-out`, `NSTableView.removeRows(withAnimation: .slideUp)`); toast rises 8pt and fades in (140 ms) |
| `s` star | Star glyph drawn | Scale 0.6 → 1.0 with `pop` (180 ms) on that glyph layer only; unstar fades 90 ms |
| `u` unread / open | Weight changes | Dot scales 0 ↔ 1 (90 ms) |
| `z` undo | Row restored, slab on it | Row slides in from +24pt with fade (140 ms `flit-out`) |
| Rail selection | List filtered; perch drawn | Avatar corners morph circle → wing-av, perch grows 8 → 20pt (140 ms) |
| Toast / undo-send | Shown | Contrail drains linearly over the undo window (8 s toast, 5 s send); exit fades 90 ms |
| Quick reply focus | Field focused | Height grows to content (140 ms) |
| Sync activity | — | Indeterminate contrail sweeps the sync line every 1.2 s (ease-in-out); spinner 800 ms per turn, linear |

Never animated: scrolling content and anything inside rows while scrolling; selection movement; list refresh after sync (new mail appears in place, scroll position is kept); counts and badges (no count-up); text; row heights; card expand/collapse (instant height, body fades in 90 ms); appearance changes; window resizing; conversation switching.

Interruptible: every animation starts from the presentation layer and every key press first calls a `finishAll()` that jumps running animations to their end state, then applies the new action. Holding `j` therefore never queues motion; at 30 key repeats per second the list simply moves.

Reduced motion (`accessibilityDisplayShouldReduceMotion`, CSS `prefers-reduced-motion` / `.ss-rm`): translations and scales are replaced by 90 ms opacity fades; wing morph and quick-reply growth are instant; the indeterminate contrail becomes a static 40% segment and the sync line text carries the state; the undo countdown keeps draining (it is information, under 2pt, and doubles as the only visible timer) and the toast also exposes the remaining seconds to VoiceOver.

### 3.9 Iconography

SF Symbols, rendering mode monochrome (hierarchical for status glyphs in banners), weight **medium**, scale **medium**. Sizes: 15pt in the reader header and composer bar (in 28pt buttons), 14pt in 24pt buttons, 13pt in rows and small buttons, 12pt in the sync line, 18pt in Settings tabs. Row glyphs are drawn semibold at 12pt to hold up at small size (as today). Color: `fg-secondary` at rest, `fg-primary` on hover, `star` when on, white on the slab.

| Action / meaning | SF Symbol | Shortcut |
|---|---|---|
| Archive | `archivebox` | E |
| Move to Trash | `trash` | # |
| Star / starred | `star` / `star.fill` | S |
| Mark unread / read | `envelope.badge` / `envelope.open` | U |
| Reply / Reply all / Forward | `arrowshape.turn.up.left` / `arrowshape.turn.up.left.2` / `arrowshape.turn.up.right` | R / A / F |
| New message | `square.and.pencil` | C |
| Search | `magnifyingglass` | / |
| Attachment | `paperclip` | ⇧⌘A (attach) |
| Send | `paperplane.fill` | ⌘↩ |
| Undo | `arrow.uturn.backward` | Z / ⌘Z |
| Move to Inbox (restore) | `tray.and.arrow.down` | ⇧I |
| More | `ellipsis` | — |
| Show quoted text | `ellipsis` (in a pill) | — |
| Load images | `photo` | — |
| Original colors | `circle.lefthalf.filled` | — |
| Formatting | `textformat` | — |
| Add account / settings | `plus` / `gearshape` | — / ⌘, |
| Account rail toggle | `sidebar.left` | ⌃⌘S |
| Offline / error / success / info | `wifi.slash` / `exclamationmark.triangle.fill` / `checkmark` / `info.circle` | — |
| Settings tabs | `person.crop.circle` (Accounts), `key` (OAuth), `gearshape` (General) | — |
| Privacy note | `lock` | — |
| Attachment types | `doc`, `doc.richtext`, `photo`, `film`, `doc.zipper`, `tablecells` | — |

**Symbols in the reader.** WKWebView cannot render SF Symbols. When the shell loads, the app rasterizes the handful the shell uses (`ellipsis`, `photo`, `circle.lefthalf.filled`, `paperclip`, the three reply arrows, `star`, `star.fill`, `exclamationmark.triangle.fill`) to template PDFs, converts them to `data:` URIs once, and injects them as CSS variables (`--sym-photo: url(data:…)`). The CSS uses them as `mask-image` with `background: currentColor`, so they take any token color in any appearance.

**Custom glyphs (4 of the 6 allowed).** All are fill-only, single color, exact SVG paths below. Coordinates are y-down; in an unflipped AppKit view apply `scaleY: -1, translateY: height`. Even-odd fill.

1. `flit.mark` — sparrow in flight. viewBox 0 0 24 24. Used at 16, 21 (rail), 24, 30–46 (alerts, welcome), 78 (icon).
```
M23 8.1L20.6 7.3C20 5.5 17.6 5 16.3 6.6L14.2 9.2C11.6 6.3 8.2 3.6 3.6 2C5.6 5.8 8 9.3 11 11.4C8.2 12.5 5 13.3 1.4 13.6L5 15.6L2.6 18.6C9.4 19.4 15.2 17.6 18.4 14.2C19.8 12.7 20.6 10.9 20.9 9.2Z
M17.7 8.1a0.8 0.8 0 1 0 1.6 0a0.8 0.8 0 1 0 -1.6 0Z
```
NSBezierPath: `move(23,8.1) line(20.6,7.3) curve(16.3,6.6 c1 20,5.5 c2 17.6,5) line(14.2,9.2) curve(3.6,2 c1 11.6,6.3 c2 8.2,3.6) curve(11,11.4 c1 5.6,5.8 c2 8,9.3) curve(1.4,13.6 c1 8.2,12.5 c2 5,13.3) line(5,15.6) line(2.6,18.6) curve(18.4,14.2 c1 9.4,19.4 c2 15.2,17.6) curve(20.9,9.2 c1 19.8,12.7 c2 20.6,10.9) close`, then `appendOval(in: (17.7, 7.3, 1.6, 1.6))` (the eye, a hole under even-odd). Below 20pt the eye may be omitted.

2. `flit.contrail` — a dot leaving a trail; means “in flight”. viewBox 0 0 16 16. Used at 12 (row pending state), 16, and as the shape language for every contrail line.
```
M1.75 7.25H3.25A0.75 0.75 0 0 1 3.25 8.75H1.75A0.75 0.75 0 0 1 1.75 7.25Z
M6.5 7H8.5A1 1 0 0 1 8.5 9H6.5A1 1 0 0 1 6.5 7Z
M13 5.5A2.5 2.5 0 1 1 13 10.5A2.5 2.5 0 1 1 13 5.5Z
```
NSBezierPath: `appendRoundedRect((1,7.25,3,1.5), xRadius: 0.75, yRadius: 0.75)`, `appendRoundedRect((5.5,7,4,2), xRadius: 1, yRadius: 1)`, `appendOval(in: (10.5,5.5,5,5))`.

3. `flit.perch` — the sparrow perched on a wire; inbox zero only. viewBox 0 0 32 24. Used at 32 × 24 and 64 × 48.
```
M1 20.5H31V22H1Z
M24.8 8.3L22.5 7.5C21.9 5.6 19.3 5.1 18 6.8C16.6 8.6 14.1 9.7 12.6 12L6.6 17.4L9.3 17.9C10.8 19.4 13.2 20.4 16.2 20.4C19.8 20.4 22.4 17 22.7 11.4C22.8 10.1 23.5 9 24.8 8.3Z
M19.6 8.6a0.7 0.7 0 1 0 1.4 0a0.7 0.7 0 1 0 -1.4 0Z
M12.6 15.6C15.2 13 18.6 12.6 20.6 14.2C19.2 16.8 16.2 17.8 13.4 16.9Z
```
NSBezierPath: `appendRect((1,20.5,30,1.5))`; body: `move(24.8,8.3) line(22.5,7.5) curve(18,6.8 c1 21.9,5.6 c2 19.3,5.1) curve(12.6,12 c1 16.6,8.6 c2 14.1,9.7) line(6.6,17.4) line(9.3,17.9) curve(16.2,20.4 c1 10.8,19.4 c2 13.2,20.4) curve(22.7,11.4 c1 19.8,20.4 c2 22.4,17) curve(24.8,8.3 c1 22.8,10.1 c2 23.5,9) close`; eye `appendOval(in: (19.6,7.9,1.4,1.4))`; wing (hole) `move(12.6,15.6) curve(20.6,14.2 c1 15.2,13 c2 18.6,12.6) curve(13.4,16.9 c1 19.2,16.8 c2 16.2,17.8) close`.

4. `flit.wing` — the wing-cut leaf on its own, for the About box, the cheat-sheet header and marketing. viewBox 0 0 16 16.
```
M1.5 14.5C3 8 7.5 3 14.5 1.5C13 8 8.5 13 1.5 14.5Z
```
NSBezierPath: `move(1.5,14.5) curve(14.5,1.5 c1 3,8 c2 7.5,3) curve(1.5,14.5 c1 13,8 c2 8.5,13) close`.

Two custom slots remain unused on purpose.

### 3.10 Density

| Density | Row | Avatar | Lines | Text x | Default |
|---|---|---|---|---|---|
| Comfortable | 72pt | 36 | sender + time / subject + glyphs / snippet | 70 | Yes |
| Compact | 52pt | 28 | sender + time / subject + glyphs (no snippet) | 62 | — |

Both are fixed heights (the table never measures rows). The reader has one density. Large text adds 12pt (84) and 8pt (60) respectively.

### 3.11 Voice and microcopy

- **Short, plain, past tense for done things, present for state.** “Archived”, “Starred 3 conversations”, “Synced just now”, “Offline · changes sync when you're back”.
- **Name the next key** in empty states and onboarding: “Nothing left. Press C to write.” Never more than one instruction.
- **Errors say what happened and what happens next**, no blame, no “Oops”, no exclamation marks: “Couldn't move to Trash. It will retry.”, “Not sent, draft kept”, “Can't sync alex@gmail.com · Reconnect”.
- **Sentence case** everywhere except the product name and proper nouns; menu items keep Apple title case (“Mark as Unread”, “Move to Trash”) because they sit beside system items.
- **Middle dot** separates a fact from its action or a pair of facts (“Archived · Undo”, “Microsoft 365 · Up to date”). Ellipsis `…` (one glyph) only for in-progress states and items that open a dialog (“Add Account…”, “Checking for mail…”).
- **Numbers as numerals**, grouped with the locale separator (12,480), times in the user's 12/24-hour setting; “Today 09:12”, “Sun”, “30 Oct”.
- **Privacy is stated once, calmly**: “Your mail goes only between this Mac, Google and Microsoft.” and “Loading them tells the sender you opened this.”
- Words to avoid: “Oops”, “Uh oh”, “Successfully”, “Please”, “Error:” prefixes, “Inbox Zero!”.

### 3.12 Keyboard and focus model

- One first responder region at a time: rail, list, reader, quick reply. Only the first responder shows Flare focus (slab, ring); the others show their inactive state. `Tab` / `⇧Tab` cycle regions; `Esc` returns to the list from anywhere in the main window.
- List: the wing slab is the focus indicator. Reader: the focused card has the 2pt ring; `n`/`p` move between messages, `o`/`↩` toggles a card.
- Every interactive element reachable with Full Keyboard Access gets the 2pt Flare ring (custom views draw it in `drawFocusRingMask`; native controls keep the system ring, which is Flare under Multicolor).
- Shortcut map: `j`/`k` move, `e` archive, `s` star, `u` unread, `#` trash, `r` reply, `a` reply all, `f` forward, `c` compose, `/` search, `z` undo, `⌘1`…`⌘9` account, `⌘0` all inboxes, `g i` Inbox, `g s` Starred, `g t` Sent, `g d` Drafts, `g #` Trash, `g a` All Mail, `?` cheat sheet, `⌃⌘S` toggle rail, `⌘↩` send, `⇧⌘A` attach.


## 4. Components

Metrics are in points (CSS px in the reader). x is measured from the leading edge of the component, y from its top. “Flare fills fall back” means: in an inactive window the fill becomes `bg-selected-inactive` and its content `fg-primary`.

### 4.1 App window and title bar

- `NSWindow` with `.fullSizeContentView`, `titlebarAppearsTransparent = true`, `titleVisibility = .hidden`, and an empty `NSToolbar` with style `.unified`, which gives a **52pt title band** and lets the system centre the traffic lights in it. We never reposition the traffic lights.
- The band is not a bar: each pane paints its own background to the top edge (rail material, list `bg-list`, reader `bg-canvas`). Pane dividers are 1pt `border-hairline`, full height.
- Panes: rail 72 (0 in minimal mode), list 340 default (300–440, autosaved), reader ≥ 480. Window default 1280 × 800, minimum 900 × 560.
- Band backgrounds drag the window (`mouseDownCanMoveWindow = true`); controls in the band do not.
- States: **key** (normal); **inactive** (traffic lights grey from the system; Flare fills fall back: slab, unified tile, perch, primary buttons, selected tokens; unread dots and stars unchanged); **full screen** (traffic lights hidden, band stays 52 for rhythm).

### 4.2 Account rail

Anatomy, top to bottom: 52pt band (traffic lights) · unified item · 24 × 1 hairline divider (8 above, 4 below) · one item per account in ⌘1…⌘9 order · flexible space · add (`plus`) and settings (`gearshape`) 28pt icon buttons, 6 apart, 12 from the bottom. Background: `.sidebar` material over `bg-rail`; 1pt trailing hairline.

**Rail item:** 72 × 48 cell, 4pt between cells, 36pt avatar centred. Perch bar at x 0: 3pt wide, radius 0/2/2/0. Badge: 16pt pill, right edge 5pt from the rail edge, top 1pt, 2pt ring in `bg-rail`.

- Unified item: transparent 36pt circle with a 1.5pt `border-control` ring and `flit.mark` at 21pt in `fg-secondary`. Badge = unified unread count.
- Account item: 36pt circle in the account color with its domain monogram (Heading 16 Bold, initials ink from §3.1). Badge = that account's unread count.

| State | Unified | Account |
|---|---|---|
| Rest | Ring, graphite mark | Circle, monogram |
| Hover | Fill `bg-list`, hairline ring; 3 × 8 perch nub in `border-control`; hint tooltip “All Inboxes ⌘0” after 400 ms | Perch nub; tooltip “alex@contoso.com ⌘1” |
| Pressed | Fill `bg-pressed` | 8% black overlay on the circle |
| Selected | Perch 3 × 20 `accent`; tile becomes wing-av, fill `accent`, mark white | Perch 3 × 20 `accent`; circle morphs to wing-av (140 ms) |
| Selected, inactive window | Perch `border-selected-inactive`; tile `bg-selected-inactive`, mark `fg-primary` | Perch `border-selected-inactive`; wing shape kept |
| Focused (Tab into rail, ↑/↓ move) | 2pt `focus-ring` with a 2pt `bg-rail` gap | Same |
| Needs sign-in | — | Avatar at 45% opacity, 16pt `danger-fill` alert badge with white `exclamationmark` 10pt; tooltip “alex@fabrikam.io needs sign-in” |
| First sync | — | A 2pt contrail arc orbits the avatar at r = 21 (800 ms/turn; static arc in reduced motion) |
| Badge | Ink pill (`fg-primary` fill, `bg-list` text), Micro Bold, min 16, padding 0 4.5, caps at “99+”; hidden at 0 | Same |

**Minimal mode** (View ▸ Hide Account Rail, ⌃⌘S): rail width 0 with no animation; the list header gains a 78pt leading inset to clear the traffic lights; the title menu shows the unread count (“Inbox 21”, Label Small `fg-secondary`); ⌘0…⌘9 keep working and the title menu gains an account section.

### 4.3 List header

Height 90 + 1pt hairline: 52pt band (title menu at x 12; segmented filter and compose button trailing with 10pt inset, 8 apart) and a search row (field at x 12 … W−12, y 52, 28 high, 10 below).

### 4.4 Title menu

28pt high, radius 8, padding 0 6; Heading 16 Bold `fg-primary` + `chevron.down` 10pt semibold `fg-secondary`, 4pt gap. Opens a native NSMenu aligned to the text: Inbox (G I), Starred (G S), Sent (G T), Drafts (G D), Trash (G #), All Mail (G A); the current view is checked.

| State | Visual |
|---|---|
| Rest | Text only |
| Hover | `bg-hover` fill |
| Pressed / open | `bg-pressed` fill while the menu is open |
| Focused | 2pt `focus-ring` |
| Minimal mode | Count appended (“Inbox 21”) |

### 4.5 Segmented filter (All / Focused / Other)

Shown in Inbox only, and only when at least one account has Focused Inbox / Gmail Primary mapping. Track 24 high, radius 8, `bg-sunken`, 2pt inset. Segments 20 high, padding 0 9, Label Small Medium `fg-secondary`. **Selected thumb: ink** (`fg-primary` fill, `bg-list` text, Semibold) with wing-sm corners. The thumb is ink, not Flare, so it never competes with the slab directly below.

| State | Visual |
|---|---|
| Rest | As above |
| Hover (unselected segment) | `bg-hover` fill, `fg-primary` text |
| Pressed | `bg-pressed` |
| Selected | Ink thumb, moves instantly |
| Focused | 2pt ring around the track; ← / → change selection |
| Inactive window | Unchanged (ink is not Flare) |

### 4.6 Search field

28 high, radius 8, `bg-sunken`, 1pt `border-control`. `magnifyingglass` 14pt `fg-secondary` at x 8, 6pt gap, placeholder “Search” (Body `fg-secondary`), trailing keycap “/”.

| State | Visual |
|---|---|
| Rest | As above |
| Focused (/ or click) | Fill `bg-list`; edge 1pt Flare + 2pt outer ring; keycap hidden |
| Typing | Results replace the list on every keystroke (local FTS, ≤ 50 ms, no spinner); trailing result count (Caption tnum) and clear button (`xmark` 14pt in a 20pt hit area) |
| No results | Count “0”; list shows the No results empty state |
| Esc | First press clears, second returns focus to the list |
| Disabled (no accounts) | `border-hairline`, `fg-disabled` |

### 4.7 Conversation row

Fixed **72pt** (52 compact). Hand laid out, no Auto Layout, attributed strings cached per summary version (the existing `ConversationCellView` contract). Metrics for list width W:

| Part | Frame | Style |
|---|---|---|
| Wing slab | x 6 … W−6, y 2 … 70, wing-lg 14/4 | See states |
| Unread dot | 7pt circle at (11, 15.5): centred on line 1, not on the row | `unread` |
| Avatar | 36 at (22, 12) | Tinted palette, initials 13 |
| Account pip | 10pt at (49, 39) with a 2pt halo in `bg-list`; unified view only | `acct-n` |
| Line 1 | x 70 … W−18, y 10, h 18 | Sender (Body; Body Strong when unread) · trailing time (Caption tnum) |
| Pending glyph | `flit.contrail` 12pt, 4pt before the time | `fg-secondary` |
| Line 2 | y 28, h 18 | Subject (Body; Body Strong when unread) · trailing glyph cluster, 6 apart, fixed order from the trailing edge: star 13, paperclip 13, count badge, Other tag |
| Line 3 | y 46, h 16 | Snippet, Small `fg-secondary` |
| Separator | x 70 … W at y 71.5, 0.5pt `border-hairline` | Hidden on the selected row and the row above it |

Compact (52): slab y 2 … 50; dot (11, 13.5); avatar 28 at (22, 12); text x 62; line 1 y 8, line 2 y 26; no snippet.

| State | Slab | Text and glyphs |
|---|---|---|
| Read, rest | none | Sender and subject Body `fg-primary`; snippet and time `fg-secondary` |
| Unread | none | Dot + sender and subject Body Strong (two carriers) |
| Hover | `bg-hover` wing slab | Unchanged. No hover keycaps on rows (cost and noise) |
| Pressed | Selection is applied on mouse-down | — |
| Selected, list focused | `bg-selected` (Flare) | Every line, glyph and dot turns `fg-on-accent`; count badge becomes a white pill with Flare text; Other tag outline turns white; pip keeps its `bg-list` halo |
| Selected, inactive (window inactive or reader/quick reply is first responder) | `bg-selected-inactive` + 3pt wing bar `border-selected-inactive` | Normal colors |
| Multi-selected (⌘/⇧-click, ⇧J/⇧K) | Each row its own slab; the 4pt gaps between slabs read as a stack of feathers | As selected |
| Starred | — | `star.fill` in `star` (white on the slab) |
| Has attachment | — | `paperclip` `fg-secondary` |
| Message count ≥ 2 | — | Count badge |
| Pending sync | — | `flit.contrail` before the time; text stays at full opacity (today's 0.6 alpha fails 4.5:1); VoiceOver appends “, syncing” |
| Operation failed permanently | — | `exclamationmark.triangle.fill` in `danger` replaces the contrail; toast explains (“Couldn't archive. Restored.”) |
| Account color | — | Pip in unified view; hidden when narrowed to one account |
| Focused vs Other | — | In Inbox ▸ All, conversations from Other carry the “Other” tag; Focused carry nothing. Hidden in the Focused and Other filters |
| Dragging | Lifted row image with e2 | — |

Performance: the slab and the hover wash are the only fills, one `CAShapeLayer` each, created once per cell and toggled; no shadows, blur or animation inside rows; star pop and dot shrink run only on the row the user acted on, never during scroll.

### 4.8 List section and date dividers

**Not used.** Date headers break the fixed-row rhythm that makes `j`/`k` predictable and complicate the fixed-height table; the time column already carries the date (“09:41”, “Sun”, “30 Oct”). Search results are ordered by date too, so they do not need them either.

### 4.9 Empty states

Centred in the pane, 24pt padding: glyph (34pt SF Symbol at weight light, or `flit.perch` 64 × 48) in `fg-secondary` · 6pt · title (Heading 16 Bold `fg-primary`) · 6pt · one sentence (Small `fg-secondary`, max width 230, may contain keycaps).

| Context | Glyph | Title | Sentence |
|---|---|---|---|
| Inbox / All Mail, no conversations | `flit.perch` | Inbox zero | Nothing left. Press C to write, or G A for All Mail. |
| Focused or Other empty | `tray` | Nothing in Focused | Other has 4 conversations. |
| Starred | `star` | Nothing starred | Press S on any conversation to keep it here. |
| Sent / Drafts / Trash | `paperplane` / `doc` / `trash` | Nothing sent yet / No drafts / Trash is empty | Messages you send appear here. / Drafts you keep appear here. / Deleted conversations stay here for 30 days. |
| Search | `magnifyingglass` | No results | Nothing matches “…” in subjects, people or message text. |
| Account needs sign-in (rail narrowed to it) | `exclamationmark.triangle` (`danger`) | Sign in to alex@fabrikam.io again | + secondary button “Reconnect” |
| Reader, nothing selected | `flit.mark` | Nothing selected | Use J K to move through your inbox. |
| Reader, several selected | `flit.contrail` | 3 conversations selected | E archives them, # moves them to Trash. |

### 4.10 Skeleton and loading

- **List skeleton** only before the first bootstrap page arrives (normally never seen; launch budget 500 ms): up to 8 static rows with a 36pt `bg-sunken` circle and bars (radius 4, `bg-sunken`): 120 × 10 at (70, 14), 30 × 10 trailing at y 14, 190 × 10 at (70, 32), 230 × 8 at (70, 50). **No shimmer.** Activity is carried by one indeterminate contrail on the list's top hairline.
- **Reader** when a body is not cached and takes > 150 ms: the card header renders from metadata at once, the body shows three bars (100%, 92%, 60% width, 10 high, 8 apart), and a contrail runs along the card's top edge.
- **Load more** at the list bottom: a 28pt row with a 16pt spinner and “Loading…” Caption.

### 4.11 Sync status line

28pt at the list foot, 1pt top hairline, padding 0 12, Caption `fg-secondary`, leading 12pt glyph 6pt before the text, optional trailing item. Activity rides a 2pt contrail on the top edge.

| State | Glyph | Text | Trailing / contrail |
|---|---|---|---|
| Up to date | `checkmark` `success` | Synced just now / Synced 3 min ago | “3 accounts” |
| Checking | — | Checking for mail… | Indeterminate contrail |
| Downloading | — | Downloading mail · 12,480 of 19,500 | Determinate contrail (width = progress) |
| Sending | — | Sending 1 message… | Indeterminate contrail |
| Offline | `wifi.slash` `warning` | Offline · changes sync when you're back | — |
| Paused | `pause.circle` `fg-secondary` | Paused | — |
| Error | `exclamationmark.triangle.fill` `danger` | Can't sync alex@gmail.com | Ghost action “Reconnect” in `fg-accent` |

Hover shows a per-account tooltip; click opens Settings ▸ Accounts.

### 4.12 Reader header and action buttons

52pt band on `bg-canvas`, no divider until content scrolls under it (then a 1pt hairline appears, no animation). Subject: Title 20/26 at x 24, one line, tail truncation, full subject in a tooltip. Actions trailing (12pt inset, 2pt apart): star, archive, trash, more, as 28pt icon buttons with 15pt symbols. In Trash, archive becomes `tray.and.arrow.down` “Move to Inbox”. Under the band, inside the scroll content: the **meta line**: account chip (unified view: 20pt pill, `bg-sunken`, 14pt monogram + address, Caption) then “4 messages · Ben Carter, Alex Morgan, Tom Hughes” (Small `fg-secondary`), 12pt above the first card.

Icon button states: **rest** `fg-secondary`; **hover** `bg-hover`, `fg-primary`, hint tooltip after 400 ms (“Archive E”); **pressed** `bg-pressed`; **focused** 2pt ring; **on** (star) `star.fill` in `star`; **disabled** `fg-disabled` (nothing selected); **inactive window** unchanged.

### 4.13 Message card and message header

Card: `bg-card`, radius 12, 1pt `border-hairline` inside edge, max width 760 centred with 24pt reader gutters, 8pt between cards.

**Collapsed** (48pt): padding 0 16 0 12; avatar 24, 10pt gap; name (Body Medium; Body Strong when unread, with a 7pt `unread` dot before the avatar); snippet Body `fg-secondary` filling the line; date Caption trailing. Five or more collapsed cards in a row fold into one 32pt “4 more messages” pill (Small `fg-secondary` on `bg-sunken`).

**Expanded**: padding 18 / 20 / 14, e1 shadow.
- Header: avatar 36, 12pt gap; name Body Strong (unread: 7pt dot before it), address Small `fg-secondary` (shown on header hover, always for senders not in the conversation before); recipients Small `fg-secondary` (“to me · cc Tom Hughes”); trailing date Caption (“Today 09:12”), star toggle and more as 24pt icon buttons. A message sent from one of your accounts shows a 2pt ring in that account's color, 2pt off the avatar.
- Tools row (14pt below): small secondary buttons, only those that apply (quoted text, images, original colors).
- Body (14pt below): Reading 14/21 in the sandboxed iframe; links `fg-accent`, underline on hover; quoted blocks indented 10 with a 2pt `border-control` rule, Small `fg-secondary`.
- Attachments (14pt below), then footer (14pt below): 1pt hairline, 10pt top padding, ghost neutral small buttons Reply, Reply all, Forward with keycaps R, A, F; icons optically aligned to the text column (−8pt).

| State | Visual |
|---|---|
| Collapsed, rest | Hairline edge |
| Collapsed, hover | Edge `border-control`, pointer cursor |
| Collapsed, unread | Dot + Body Strong name |
| Expanded, rest | e1 |
| Focused (reader is first responder; N/P move, O or ↩ toggles) | 2pt `focus-ring` replaces the edge, e1 kept |
| Selected-inactive | No ring (focus lives elsewhere) |
| Body loading | Header real, body skeleton, contrail on the card's top edge |
| Pending local change | Star/read patches via `ss.flags`, no re-render |

### 4.14 Quoted-text toggle

Small secondary button, `ellipsis` + “Show quoted text”. On: `bg-accent-tint`, `fg-accent`, label “Hide quoted text”. Only present when the body has quoted text (stored at sync). Toggle is instant (iframe re-measure), no animation. Focused: 2pt ring. In the composer the same idea is the **quoted-original fold** (§4.18).

### 4.15 Remote-images control and banner

Default: tools-row button `photo` + “Load images (N)”. Banner variant for the first card of a conversation when N ≥ 3: 34pt, radius 8, `info-tint`, `photo` 15pt `info`, Small text “3 remote images hidden. Loading them tells the sender you opened this.”, trailing small secondary “Load images”.

| State | Visual |
|---|---|
| Rest | As above |
| Hover / pressed / focused | Button states |
| Loading | Button shows 13pt spinner + “Loading…” |
| Loaded | Control removed (banner fades 90 ms) |
| Partially failed | Banner turns `danger-tint` with triangle: “2 images couldn't load.” + “Retry” |
| Preference on | Never shown |

### 4.16 Original colors toggle

Shown only in dark appearance for HTML bodies. Small secondary button, `circle.lefthalf.filled` + “Original colors”. On: `bg-accent-tint` + `fg-accent`; the body renders `color-scheme: light` on white inside the card with a 1pt hairline around the iframe. Remembered per message for the session.

### 4.17 Attachment chip

40pt, radius 8, `bg-sunken`, padding 0 12 0 8, max width 260, 8pt gaps, wraps. File tile 24pt radius 6 with a 3-letter type label (Micro Bold white) on a type color (PDF `#C8213F`, image `#1F8555`, document `#006CD3`, archive `#5C5C66`, other `#77777F`); name Small Medium (truncates middle: “go-live-che…list.pdf”); size Caption `fg-secondary`.

| State | Visual |
|---|---|
| Rest | As above |
| Hover | 1pt `border-control` edge; tooltip with full name |
| Pressed | `bg-pressed` overlay |
| Focused (Tab / arrows in the card) | 2pt ring; Space opens Quick Look |
| Downloading | 2pt Flare bar on the bottom edge; size line “Downloading 40%” |
| Error | Size line `danger`: “Couldn't download · Retry” |
| Dragging out | Lifted with e2 |

### 4.18 Quick reply bar

Docked under the conversation on `bg-canvas`, padding 10 24 12, field width matches the cards (max 760). Field: min 38, radius 12, `bg-card`, 1pt `border-control`; 22pt avatar of the recipient, 8pt gap, placeholder “Reply to Ben Carter…”, trailing keycap R.

| State | Visual |
|---|---|
| Rest | As above |
| Hover | Edge `fg-secondary` |
| Focused (R) | Edge Flare + 2pt ring; grows to content (140 ms) up to 6 lines of Reading, then scrolls; bottom row: reply target (“↩ Priya”, click toggles Reply / Reply all), open-in-window icon button (⇧⌘O), small primary Send with ⌘↩ keycap |
| Sending | Field locks, 16pt spinner + “Sending to Priya Raman…”, then clears as the undo-send panel appears |
| Error | `danger-tint` banner above: “Couldn't send. Draft kept.” + Open |
| Disabled | Placeholder “No one to reply to”, `fg-disabled`, no keycap |
| Inactive | Send falls back to graphite |

Esc (empty field) returns focus to the list; Esc with text asks nothing and keeps the draft.

### 4.19 Composer window

640 × 560 default, minimum 480 × 360, standard titled window (title = subject or “New Message”), unified 52pt title band with a hairline under it.

- **Field rows:** 40pt each, separators inset 16; label column 52 right-aligned (Body `fg-secondary`), 8pt gap.
  - From: borderless popup (§4.26) with the account monogram (14pt) + “Alex Morgan <alex@contoso.com>”.
  - To: address token field; trailing ghost “Cc” and “Bcc” (Small, `fg-secondary`), hidden once their rows are shown (rows appear instantly under To).
  - Subject: Body Medium.
- **Body:** padding 16 / 20, Reading 14/21. ⌘B / ⌘I / ⌘U / ⌘K and lists. The `textformat` button toggles a 36pt format bar above the strip (B, I, U, link, bullets, numbers, quote as 28pt icon buttons).
- **Quoted original fold:** pill 24pt, radius 12, `bg-sunken`: three 3pt dots + “Ben Carter wrote on Mon 2 Nov, 09:12” (Small `fg-secondary`) + `chevron.down` 11pt. Click expands inline (instant), label becomes “Hide original”. Loading: spinner + “Loading original message…”; error: `warning` text “Couldn't load the original message; it won't be quoted.”
- **Attachment strip** (§4.21) when there are attachments.
- **Bottom bar:** 56pt, top hairline, padding 0 12 0 16: Send (§4.22), 6pt, attach (`paperclip`) and format (`textformat`) icon buttons; spacer; “Draft saved” Caption `fg-secondary` (appears 1.5 s after typing stops); discard (`trash`) icon button, which asks first if the body is not empty.
- **Drop target:** an 8pt-inset overlay with `bg-accent-tint` fill, 2pt dashed Flare edge (radius 12) and the label “Drop to attach” (Label `fg-accent`). Dashes + words carry the state, not just color.

### 4.20 Address token

24pt pill (radius 12), `bg-sunken`, padding 0 8 0 3, 18pt tinted avatar, name Body. Unknown address: no avatar, padding 0 8, shows the address.

| State | Visual |
|---|---|
| Rest | As above |
| Hover | 1pt `border-control` edge; `chevron.down` 9pt appears (menu: Copy Address, Edit, Remove) |
| Selected (click, or ⌫ once) | `accent` fill, white text, avatar inverted (white disc, Flare initials). Second ⌫ deletes |
| Invalid | `danger-tint` fill, 1pt `danger` edge, `danger` text with a wavy underline; tooltip “Not a valid address” |
| Dragging | e2, follows the pointer |
| Inactive window | Selected falls back to graphite |

Tab or comma completes the typed text into a token; autocomplete menu is native.

### 4.21 Attachment strip

10 / 16 padding, top hairline, horizontal row of chips (36pt variant of §4.17) with a 16pt circular remove button (`xmark` 11pt) at the trailing end. States per chip: **adding** (bottom progress bar, “Adding… 62%”), **ready** (size), **error** (`danger` “Couldn't read “file””, chip keeps the remove button), **hover** (edge), **focused** (ring; ⌫ removes). Overflow scrolls horizontally with a 24pt edge fade.

### 4.22 Send button

Primary large: 32pt, wing-md, padding 0 16, `paperplane.fill` 15pt + “Send” (Label 14) + keycap “⌘↩” on `kbd-on-accent-bg` (6.85:1).

| State | Visual |
|---|---|
| Rest | `accent` |
| Hover | `accent-hover` |
| Pressed | `accent-pressed` |
| Focused | 2pt ring with 2pt surface gap |
| Disabled (no valid recipient) | `bg-sunken`, `fg-disabled`, no keycap; tooltip “Add a recipient” |
| Sending (quick reply only) | White spinner replaces the glyph, label “Sending” |
| Inactive window | Falls back to graphite |

### 4.23 Buttons

| Kind | Fill / edge | Label | Radius (24 / 28 / 32) |
|---|---|---|---|
| Primary | `accent` | `fg-on-accent`, Label | wing-sm / wing-md / wing-md |
| Secondary | `bg-card` + 1pt `border-control` | `fg-primary` | 6 / 8 / 8 |
| Ghost (tertiary) | none | `fg-accent` (neutral variant `fg-primary` for footers) | 6 / 8 / 8 |
| Destructive | `danger-fill` | white | 6 / 8 / 8 |
| Destructive secondary | `bg-card` + `border-control` | `danger` | 6 / 8 / 8 |
| Icon | none | `fg-secondary` symbol (14 / 15) | 6 / 8 |

Sizes: small 24 (padding 0 9, Label Small, 13pt symbol, 5pt gap), regular 28 (0 12, Label 13, 15pt symbol, 6pt gap), large 32 (0 16, Label 14, 15pt symbol). Minimum text button width 64 in alerts and forms.

| State | Primary | Secondary | Ghost | Destructive | Icon |
|---|---|---|---|---|---|
| Rest | `accent` | as above | transparent | `danger-fill` | `fg-secondary` |
| Hover | `accent-hover` | `bg-sunken` fill | `bg-hover` | `danger-fill-hover` | `bg-hover`, `fg-primary` |
| Pressed | `accent-pressed` | `bg-sunken` + `fg-secondary` edge | `bg-pressed` | `danger-fill-pressed` | `bg-pressed` |
| Focused | 2pt `focus-ring` outside a 2pt surface gap | same | same | same | 2pt ring, no gap |
| Disabled | `bg-sunken`, `fg-disabled` | `border-hairline` edge, `fg-disabled` | `fg-disabled` | as primary disabled | `fg-disabled` |
| Loading | Spinner replaces the leading glyph (white on fills, `fg-accent` otherwise); width is locked; label becomes the progressive verb (“Sending”, “Signing in”) | same | same | same | Spinner replaces the symbol |
| Toggle on | — | `bg-accent-tint` + `fg-accent` | — | — | Symbol filled, `star` / `fg-accent` |
| Inactive window | Falls back to graphite | unchanged | unchanged | unchanged | unchanged |

Press feedback is immediate on mouse-down; release fades in 90 ms. Return triggers the default (primary) button, Esc the cancel button.


### 4.24 Text field

28pt (24 small), radius 8 (6 small), fill `bg-sunken` (`bg-card` inside settings groups), 1pt `border-control`, padding 0 8, Body text, placeholder `fg-secondary`. Mono variant (SF Mono 12) for OAuth credentials.

| State | Visual |
|---|---|
| Rest | As above (fields do not react to hover, as on the Mac) |
| Focused | Fill `bg-list`; inner 1pt Flare edge + outer 2pt `focus-ring` |
| Filled | Text `fg-primary` |
| Error | 1pt `danger` edge + `exclamationmark.triangle` 14pt `danger` inside the trailing edge + message (Small `danger`) 4pt below: “That secret doesn't match this client ID.” |
| Disabled | `border-hairline` edge, `fg-disabled` text |
| Read-only | No edge, selectable text |

Native `NSTextField` / SwiftUI `TextField` in Settings keep the system bezel and focus ring (Flare under Multicolor); the tokens above are for the fields we draw (search, quick reply, composer rows).

### 4.25 Checkbox and toggle

**Checkbox:** 16pt, radius 4, `bg-card` + 1pt `border-control`; checked = `accent` fill + white `checkmark` (12pt, 2.2 stroke); mixed = `accent` + white 8 × 2 dash; label Body 8pt after. **Toggle:** 32 × 18 track (radius 9); off = `bg-sunken` + 1pt `border-control`; on = `accent`; 14pt white knob with `0 1 2 #000 @0.25` shadow; knob travels in 140 ms `flit-out` (instant in reduced motion). In SwiftUI Settings use native `Toggle(.switch)` with `.controlSize(.small)` and native checkboxes; these specs apply to any we draw.

| State | Checkbox | Toggle |
|---|---|---|
| Rest | as above | as above |
| Hover | Edge `fg-secondary` | Edge `fg-secondary` (off) |
| Pressed | `bg-pressed` overlay | Knob widens to 18 |
| Focused | 2pt ring with 2pt gap | Same |
| Disabled | `border-hairline`, label `fg-disabled` | 45% opacity |
| Inactive window | On state falls back to graphite | Same |

### 4.26 Popup button

24pt, radius 6, padding 0 6 0 8, Body, `chevron.up.chevron.down` 12pt `fg-secondary`, 6pt gap. Bordered variant (forms): `bg-card` + 1pt `border-control`. Borderless variant (composer From): no fill until hover. States: **rest**; **hover** (`bg-hover` for borderless, edge `fg-secondary` for bordered); **open** (native menu, button `bg-pressed`); **focused** (2pt ring with gap); **disabled** (`fg-disabled`, hairline edge). Settings uses native `Picker(.menu)`.

### 4.27 Badges

| Badge | Metrics | Colors |
|---|---|---|
| Row count | 16 high, min 18, padding 0 5, pill, Micro Semibold tnum; shown when the conversation has ≥ 2 messages | `bg-sunken` / `fg-secondary`; on the slab a white pill (`badge-on-slab-bg`) with `bg-selected` text |
| Rail count | 16 high, min 16, padding 0 4.5, Micro Bold, 2pt `bg-rail` ring, caps at “99+” | Ink: `fg-primary` fill, `bg-list` text |
| Alert | 16pt circle, `exclamationmark` 10pt | `danger-fill` / white |
| Unread dot | 7pt | `unread` (white on the slab) |
| Tag (“Other”) | 16 high, padding 0 5, pill, 1pt `border-control` edge, Micro Semibold | `fg-secondary` (white edge and text on the slab) |
| Dock | System `NSDockTile.badgeLabel` with the unified Inbox unread count | System red |

### 4.28 Avatar

Sizes: 16 (inline), 18 (token), 22 (quick reply), 24 (collapsed card), 28 (compact row), 32 (settings), 36 (row, card, rail), 64 (about, contact popover). Circle, tinted palette by address hash, initials Rounded Semibold at 36% of the diameter (account monograms: Bold, 40–44%). Painted from cached images off the main thread (existing `AvatarCache`); initials only, no network avatars.

- **Account pip:** 10pt with a 2pt `bg-list` halo at the bottom-trailing edge of a 36pt avatar (16pt with a 3pt halo on 64); unified view only.
- **Account ring:** messages you sent from one of your accounts get a 2pt ring in that account's color, 2pt off the avatar (reader cards).
- **Rail selection:** circle → wing-av morph (not a ring).
- States: rest; pressed (rail only); dimmed 45% (account needs sign-in).

### 4.29 Toast with action

36pt, wing-lg, `bg-toast`, e3, padding 0 6 0 12, `overflow: hidden`. Leading symbol of the action (15pt, `fg-on-toast-secondary`), 8pt, message Body Medium `fg-on-toast`, “·”, Undo button (26pt, radius 6, padding 0 4 0 8, Label `fg-toast-action` + keycap Z on `kbd-on-toast-bg`). The **contrail** runs along the bottom edge (2pt, `fg-toast-action` head fading to transparent) and drains over the 8 s lifetime.

- Position: bottom centre of the list pane, 12pt above the sync line; max width list width − 24 (message truncates).
- Behavior: a new action replaces the toast instantly (no stacking); several actions in 1 s coalesce (“Archived 3 conversations”). Hover pauses the countdown (contrail freezes). Z or ⌘Z undoes from anywhere in the main window; Esc dismisses.
- States: **rest**; **Undo hover** (`#FFFFFF @0.10` fill); **Undo pressed** (`@0.16`); **Undo focused** (2pt `fg-toast-action` ring); **error** (`fg-toast-danger` triangle, no Undo, e.g. “Couldn't move to Trash. It will retry.”); **reduced motion** (fades only).
- VoiceOver: announcement “Archived. Press Z to undo.”

### 4.30 Undo-send panel

Borderless, non-activating `NSPanel` (floating level), 44pt high, min width 280, wing-lg, `bg-toast`, e3 drawn by layers. Anchored bottom centre of the main window, 20pt above its bottom edge (bottom centre of the screen when the main window is hidden).

Anatomy: countdown numeral (Label 13 Bold tnum `fg-toast-action`, 14pt column) · message Body Medium (“Sending to Ben Carter”) · Undo (keycap ⌘Z) · contrail draining over the 5 s window.

| State | Visual |
|---|---|
| Counting (5 → 1) | Numeral + message + Undo + draining contrail. Hover does not pause (the deadline belongs to `SendRunner`) |
| Undo | Panel closes; the composer reopens with the draft immediately (tooltip and VoiceOver: “Cancel sending and reopen the message”) |
| Sending | 16pt spinner (`fg-toast-action`) + “Sending…” |
| Sent | `checkmark.circle` `fg-toast-success` + “Sent”, dismisses after 1.2 s (90 ms fade) |
| Too late | “Already sent” for 1.2 s |
| Failed | `fg-toast-danger` triangle + “Not sent, draft kept” + action “Open” (reopens the composer) |

### 4.31 Alerts and sheets

Native `NSAlert` as a sheet on the relevant window; the alert icon is the app icon. We own the words and button roles: title is the question, informative text is the consequence, buttons are verbs. Destructive buttons set `hasDestructiveAction = true`; the safe choice is the default (Return) when data would be lost.

| Alert | Title | Informative | Buttons |
|---|---|---|---|
| Discard draft | Discard this message? | You'll lose what you wrote to Ben Carter. This can't be undone. | Discard (destructive) · Keep Writing (default) |
| Remove account | Remove alex@contoso.com? | Its mail is removed from this Mac. Nothing changes on the server. | Remove (destructive) · Cancel (default) |
| Add account failed | Couldn't add the account | {reason from OAuthFlow} | OK |
| Send failed | Couldn't send | {reason}. Your draft is kept. | Open Draft · OK |

### 4.32 Tooltips

- **Hint tooltip** (custom, for icon buttons in the reader header, composer bar, list header and rail): 26pt, radius 6, `bg-toast`, e2, padding 0 6 0 9, Small `fg-on-toast` + keycap. Appears 400 ms after hover, then instantly for 1 s after another hint closes; 6pt below the control, centred, clamped inside the window. Never on rows.
- **Native `toolTip`** for everything else (truncated subjects, pips, file names).

### 4.33 Menus

Native `NSMenu` everywhere (main menu, title menu, row and card context menus, token menu, attachment menu); highlight follows the system accent (Flare under Multicolor). Items carry SF Symbols in context menus and the single-key shortcuts in the shortcut column (unmodified key equivalents, as Mail and Superhuman do).

- Row context menu: Reply (R), Reply All (A), Forward (F) · Archive (E), Star (S), Mark as Unread (U), Move to Trash (#) · Move to Inbox (⇧I, only outside Inbox).
- Mailbox menu: Inbox, Starred, Sent, Drafts, Trash, All Mail (G-sequences shown as “G I” in the title, since NSMenu cannot show sequences as key equivalents), All Inboxes ⌘0, accounts ⌘1…⌘9.
- View menu: Hide Account Rail ⌃⌘S, Density ▸ Comfortable / Compact, Show Focused Filter.

### 4.34 Keyboard shortcut hints (keycaps), HUD and cheat sheet

**Keycap:** 16 high, min width 16, padding 0 4, radius 4, `kbd-bg`, 1pt `kbd-border` with a doubled bottom edge (`inset 0 −1 0 1`), legend Micro Semibold uppercase `kbd-fg`. Combos in one cap with system glyphs (“⌘↩”, “⇧⌘A”); sequences as two caps with “then” (Caption) between. **Large:** 22 high, radius 6, Label Small. **On toast:** `kbd-on-toast-bg`, `fg-on-toast-secondary`, white 16% edge. **On Flare:** `kbd-on-accent-bg`, white.

**g-sequence HUD:** if G is pressed and no second key arrives within 500 ms, a HUD appears at the bottom centre of the list: wing-lg, `bg-toast`, e3, padding 10 12, header keycap G + “Go to…” (Label), then rows keycap + view name (Small `fg-on-toast-secondary`). The second key, Esc or 2 s idle dismisses it. Typing G I quickly never shows it.

**Cheat sheet** (`?`): a sheet on the main window, 560 wide, four columns (Move, Act, Write, Go), large keycaps, Esc closes. `flit.wing` in the header.

### 4.35 Progress

| Indicator | Metrics | Behavior |
|---|---|---|
| Spinner | 16 (inline) or 24 (panels); 300° contrail arc, ring 1.6 / 2.4pt; `fg-accent` on surfaces, white on Flare, `fg-toast-action` on toasts | 800 ms per turn, linear; `CAShapeLayer` arc masked by a `.conic` `CAGradientLayer`; keeps turning in reduced motion (essential and tiny) |
| Determinate bar | 4pt track (`bg-sunken` + hairline), radius 2; fill is a contrail gradient (Flare at 15% → 100%) | Width tracks progress without easing |
| Inline bar | 2pt on the bottom edge of a chip | Attachment download / add |
| Indeterminate contrail | 36% segment on a 2pt line | Sweeps leading → trailing every 1.2 s, ease-in-out; static 40% segment in reduced motion |

### 4.36 Welcome screen

Fixed 600 × 560 window, `.underWindowBackground` material over `bg-canvas`, content column centred (max 380):

1. Brand tile 72pt, wing-xl, Flare gradient (`#F86A33` → `#D2421A`, 160°), `flit.mark` 46pt white, shadow `0 8 20 0 #D2421A @0.30`; a 3pt contrail flight line curves in from the lower left to the tile's tail.
2. 22pt · Display “Welcome to SuperSparrow”.
3. 6pt · Reading `fg-secondary`: “Gmail and Outlook in one fast inbox. Add an account to start; you can add more later.”
4. 26pt · 280-wide stack, 10 apart: primary large “Add Gmail account”, secondary large “Add Microsoft account”.
5. 28pt · large keycaps J K E S R + Small “Five keys run most of your day. Press ? any time.”
6. 22pt · `lock` 13pt + Small “Your mail goes only between this Mac, Google and Microsoft.”

States: **rest**; **adding** (pressed button shows its spinner + “Finish signing in in your browser…”, the other is disabled, a ghost “Cancel” appears below); **error** (`danger-tint` banner above the buttons: “Couldn't add the account. {reason}”, buttons re-enabled); **demo** (“Adding demo account…”). Focus starts on the primary button; Tab moves between buttons with the 2pt ring.

### 4.37 Settings window (SwiftUI)

`Settings` scene, 560 wide, `TabView` toolbar tabs: Accounts (`person.crop.circle`), OAuth (`key`), General (`gearshape`); the selected tab is system-drawn. Content padding 20, `Form` with `.formStyle(.grouped)`; rows min 52 with a detail line, 44 single-line.

- **Account row:** avatar 32 (account color, monogram Rounded Bold 13) · address Body Strong · status line Small: 7pt status dot + provider + words · trailing color popup (12pt swatch + chevrons; menu lists the 10 palette colors by name, current checked).

| Status | Dot / glyph | Words | Trailing |
|---|---|---|---|
| Up to date | `success` dot | Microsoft 365 · Up to date | Color popup |
| Syncing | 10pt spinner | Gmail · Downloading 12,480 messages | Color popup |
| Offline | `warning` dot | Gmail · Offline | Color popup |
| Paused | `fg-secondary` dot | Gmail · Paused | Color popup |
| Needs sign-in | `danger` triangle, text in `danger` | Gmail · Needs sign-in | Secondary small “Reconnect” |

  Below the group: secondary small “Add Account…” (menu: Add Gmail Account…, Add Microsoft Account…) and destructive-secondary small “Remove…” (alert §4.31). Rows use native list selection.
- **OAuth:** per provider, Client ID and Client secret (Mono fields), Small help text with a link to `docs/OAUTH-SETUP.md`, field errors as §4.24.
- **General:** “Notify me about new mail” (toggle), “Load remote images by default” (toggle, detail “Senders can see when you open”), Row density (Comfortable / Compact), Text size (Default / Large), Show account rail (toggle).

### 4.38 New-mail notifications

`UNUserNotificationCenter`, category `message` with actions **Archive**, **Reply** (text input, placeholder “Reply…”), **Mark as Read**. Content: title = sender display name, subtitle = subject, body = snippet (system truncates to 2 lines), `threadIdentifier` = conversation id, summary “%u more from alex@contoso.com”. Only Inbox mail (Focused only, when the account uses Focused); none while the app is frontmost and the conversation is visible. Respects the system “Show previews” setting. Icon: the app icon.

### 4.39 App icon alignment

macOS 26 layered icon (Icon Composer):
- **Background:** Flare radial gradient, `#FF8A55` at top-left → `#F25A26` at 45% → `#C83A12` bottom-right.
- **Middle:** the contrail flight line, white at 55% alpha, round caps, 4/128 stroke, dashes 6/9, curving from the lower left to under the tail.
- **Foreground:** `flit.mark` in white at 61% of the canvas width, offset 4% right and 4% up (optical centre of a bird moving forward), soft shadow `0 3 4 #781E00 @0.30`.
- **Dark variant:** mark in Flare 500 on Graphite 900; **tinted/clear:** system monochrome from the foreground layer.
- The same mark appears in the rail (unified item), the welcome tile, the alert icon and notifications, so the icon, the Dock and the app share one silhouette. The Dock badge stays system red.

## 5. Implementation notes

- **Token source:** `Sources/SSCore/Design/FlitTokens.swift` (data only; no AppKit), generated by hand from the tables above; `NSColor+Flit.swift` and `Font+Flit.swift` in the app; the reader shell gets `FlitTokens.cssVariables` and the symbol `data:` URIs at load.
- **Existing code this replaces:** `NSColor+Hex.swift` one-offs and `.systemYellow` star in `ConversationCellView`; the `--ss-*` variables in `ConversationShellAssets.css`; the four avatar palettes (`AvatarCache`, `AccountStripButton`, shell `.ss-avatar`, compose tokens) collapse into `av-1…8` and `acct-1…10`; `ToastView`, `UndoSendPanel`, `SyncStatusBar`, `QuickReplyView` adopt §4.29, §4.30, §4.11, §4.18.
- **Row cost check:** after adopting Flit, a selected row adds one `CAShapeLayer` (slab) and a hovered row one more; no other per-row layers. Keep the 16 ms `j`/`k` signpost budget.
- **Order of adoption:** tokens and fonts → row + slab → rail → reader CSS → toasts/undo → composer → settings.

## 6. Contrast table

Every value computed with the WCAG 2.x relative-luminance formula by the script in the appendix (alpha tokens composited over the stated surface). Minimum = 4.5 for text, 3 for essential non-text UI (icons, state-bearing borders, focus rings, slab, dots, pips). All 118 pairs pass in all four appearances.

| Foreground | Background | Role | Min | Light | Dark | Light IC | Dark IC |
|---|---|---|---|---|---|---|---|
| `fg-primary` | `bg-list` | Body text | 4.5 | 17.88 | 15.67 | 21.00 | 19.14 |
| `fg-secondary` | `bg-list` | Secondary text | 4.5 | 6.61 | 6.95 | 11.08 | 12.50 |
| `fg-primary` | `bg-canvas` | Body text | 4.5 | 16.28 | 16.88 | 17.67 | 21.00 |
| `fg-secondary` | `bg-canvas` | Secondary text | 4.5 | 6.02 | 7.49 | 9.33 | 13.72 |
| `fg-primary` | `bg-card` | Body text | 4.5 | 17.88 | 14.47 | 21.00 | 17.33 |
| `fg-secondary` | `bg-card` | Secondary text | 4.5 | 6.61 | 6.42 | 11.08 | 11.32 |
| `fg-primary` | `bg-sunken` | Body text | 4.5 | 15.31 | 12.88 | 16.58 | 15.04 |
| `fg-secondary` | `bg-sunken` | Secondary text | 4.5 | 5.66 | 5.71 | 8.75 | 9.83 |
| `fg-primary` | `bg-elevated` | Body text | 4.5 | 17.88 | 12.88 | 21.00 | 15.04 |
| `fg-secondary` | `bg-elevated` | Secondary text | 4.5 | 6.61 | 5.71 | 11.08 | 9.83 |
| `fg-primary` | `bg-rail` | Body text | 4.5 | 14.90 | 14.82 | 16.13 | 18.37 |
| `fg-secondary` | `bg-rail` | Secondary text | 4.5 | 5.51 | 6.57 | 8.51 | 12.00 |
| `fg-primary` | `bg-selected-inactive` | Body text | 4.5 | 14.11 | 11.15 | 15.39 | 11.27 |
| `fg-secondary` | `bg-selected-inactive` | Secondary text | 4.5 | 5.22 | 4.94 | 8.12 | 7.36 |
| `fg-primary` | `bg-hover` over `bg-list` | Body text on hover row | 4.5 | 16.33 | 13.51 | 17.84 | 14.90 |
| `fg-secondary` | `bg-hover` over `bg-list` | Snippet on hover row | 4.5 | 6.04 | 5.99 | 9.41 | 9.73 |
| `fg-on-accent` | `bg-selected` | Text on Flare fill | 4.5 | 4.63 | 4.63 | 5.97 | 5.22 |
| `fg-on-accent` | `accent` | Text on Flare fill | 4.5 | 4.63 | 4.63 | 5.97 | 5.22 |
| `fg-on-accent` | `accent-hover` | Text on Flare fill | 4.5 | 5.45 | 5.45 | 7.04 | 5.97 |
| `fg-on-accent` | `accent-pressed` | Text on Flare fill | 4.5 | 6.68 | 6.68 | 8.34 | 7.04 |
| `fg-on-accent` | `danger-fill` | Destructive button label | 4.5 | 5.61 | 5.61 | 7.74 | 6.44 |
| `fg-on-accent` | `danger-fill-hover` | Destructive hover label | 4.5 | 6.84 | 6.84 | 9.40 | 7.74 |
| `fg-on-accent` | `danger-fill-pressed` | Destructive pressed label | 4.5 | 8.37 | 8.37 | 11.10 | 9.40 |
| `fg-on-toast` | `bg-toast` | Toast text | 4.5 | 15.42 | 10.68 | 21.00 | 9.48 |
| `fg-on-toast-secondary` | `bg-toast` | Toast secondary / kbd | 4.5 | 8.07 | 7.59 | 13.70 | 7.22 |
| `fg-toast-action` | `bg-toast` | Toast Undo action | 4.5 | 8.09 | 6.10 | 11.86 | 6.02 |
| `fg-accent` | `bg-list` | Accent text / link | 4.5 | 5.60 | 6.72 | 7.04 | 9.77 |
| `fg-accent` | `bg-canvas` | Accent text / link | 4.5 | 5.10 | 7.24 | 5.93 | 10.72 |
| `fg-accent` | `bg-card` | Accent text / link | 4.5 | 5.60 | 6.21 | 7.04 | 8.85 |
| `fg-accent` | `bg-sunken` | Accent text / link | 4.5 | 4.79 | 5.53 | 5.56 | 7.68 |
| `fg-accent` | `bg-elevated` | Accent text / link | 4.5 | 5.60 | 5.53 | 7.04 | 7.68 |
| `success` | `bg-list` | Success text | 4.5 | 5.65 | 8.61 | 7.19 | 12.46 |
| `success` | `bg-card` | Success text | 4.5 | 5.65 | 7.95 | 7.19 | 11.28 |
| `success` | `bg-canvas` | Success text | 4.5 | 5.15 | 9.28 | 6.06 | 13.67 |
| `success` | `success-tint` over `bg-card` | Success text on banner | 4.5 | 4.94 | 6.07 | 5.95 | 7.58 |
| `warning` | `bg-list` | Warning text | 4.5 | 5.73 | 9.47 | 8.27 | 13.44 |
| `warning` | `bg-card` | Warning text | 4.5 | 5.73 | 8.75 | 8.27 | 12.18 |
| `warning` | `bg-canvas` | Warning text | 4.5 | 5.22 | 10.21 | 6.96 | 14.75 |
| `warning` | `warning-tint` over `bg-card` | Warning text on banner | 4.5 | 5.00 | 6.51 | 6.90 | 7.90 |
| `danger` | `bg-list` | Danger text | 4.5 | 5.99 | 6.33 | 8.21 | 9.58 |
| `danger` | `bg-card` | Danger text | 4.5 | 5.99 | 5.85 | 8.21 | 8.68 |
| `danger` | `bg-canvas` | Danger text | 4.5 | 5.46 | 6.83 | 6.91 | 10.51 |
| `danger` | `danger-tint` over `bg-card` | Danger text on banner | 4.5 | 5.17 | 4.74 | 6.63 | 6.35 |
| `info` | `bg-list` | Info text | 4.5 | 5.90 | 7.04 | 8.39 | 10.99 |
| `info` | `bg-card` | Info text | 4.5 | 5.90 | 6.50 | 8.39 | 9.96 |
| `info` | `bg-canvas` | Info text | 4.5 | 5.38 | 7.59 | 7.06 | 12.06 |
| `info` | `info-tint` over `bg-card` | Info text on banner | 4.5 | 5.17 | 5.10 | 6.92 | 6.98 |
| `kbd-fg` | `kbd-bg` | Keycap legend | 4.5 | 9.48 | 8.55 | 17.88 | 11.27 |
| `fg-on-accent` | `kbd-on-accent-bg` over `accent` | Keycap legend in Send button | 4.5 | 6.85 | 6.85 | 9.61 | 8.70 |
| `fg-on-toast-secondary` | `kbd-on-toast-bg` over `bg-toast` | Keycap legend in toast | 4.5 | 5.60 | 5.23 | 9.51 | 4.55 |
| `bg-list` | `fg-primary` | Ink badge / segmented thumb label | 4.5 | 17.88 | 15.67 | 21.00 | 19.14 |
| `bg-selected` | `badge-on-slab-bg` | Count badge on slab (Flare text on white pill) | 4.5 | 4.63 | 4.63 | 5.97 | 5.22 |
| `fg-secondary` | `bg-sunken` | Count badge text | 4.5 | 5.66 | 5.71 | 8.75 | 9.83 |
| `danger` | `danger-tint` over `bg-list` | Invalid address token | 4.5 | 5.17 | 5.16 | 6.63 | 7.18 |
| `fg-primary` | `info-tint` over `bg-card` | Banner body text | 4.5 | 15.67 | 11.35 | 17.33 | 12.16 |
| `fg-primary` | `bg-accent-tint` over `bg-list` | Text on accent wash | 4.5 | 15.54 | 12.17 | 16.91 | 13.06 |
| `bg-selected` | `bg-list` | Wing slab / perch vs surface | 3 | 4.63 | 3.75 | 5.97 | 3.67 |
| `bg-selected` | `bg-rail` | Wing slab / perch vs surface | 3 | 3.86 | 3.54 | 4.58 | 3.52 |
| `border-selected-inactive` | `bg-list` | Inactive wing bar vs list | 3 | 4.13 | 5.22 | 6.61 | 8.91 |
| `border-selected-inactive` | `bg-selected-inactive` | Inactive wing bar vs slab | 3 | 3.26 | 3.72 | 4.84 | 5.25 |
| `unread` | `bg-list` | Unread dot | 3 | 4.63 | 6.72 | 5.97 | 9.77 |
| `unread` | `bg-selected-inactive` | Unread dot | 3 | 3.65 | 4.78 | 4.37 | 5.75 |
| `unread` | `bg-card` | Unread dot | 3 | 4.63 | 6.21 | 5.97 | 8.85 |
| `star` | `bg-list` | Star glyph | 3 | 4.63 | 6.72 | 5.97 | 9.77 |
| `star` | `bg-selected-inactive` | Star glyph | 3 | 3.65 | 4.78 | 4.37 | 5.75 |
| `star` | `bg-card` | Star glyph | 3 | 4.63 | 6.21 | 5.97 | 8.85 |
| `focus-ring` | `bg-list` | Focus ring | 3 | 4.63 | 6.72 | 7.04 | 9.77 |
| `focus-ring` | `bg-canvas` | Focus ring | 3 | 4.22 | 7.24 | 5.93 | 10.72 |
| `focus-ring` | `bg-card` | Focus ring | 3 | 4.63 | 6.21 | 7.04 | 8.85 |
| `focus-ring` | `bg-sunken` | Focus ring | 3 | 3.97 | 5.53 | 5.56 | 7.68 |
| `focus-ring` | `bg-rail` | Focus ring | 3 | 3.86 | 6.36 | 5.41 | 9.38 |
| `focus-ring` | `bg-elevated` | Focus ring | 3 | 4.63 | 5.53 | 7.04 | 7.68 |
| `border-control` | `bg-list` | Control boundary | 3 | 3.65 | 4.09 | 6.61 | 7.67 |
| `border-control` | `bg-card` | Control boundary | 3 | 3.65 | 3.78 | 6.61 | 6.95 |
| `border-control` | `bg-canvas` | Control boundary | 3 | 3.33 | 4.41 | 5.56 | 8.42 |
| `border-control` | `bg-elevated` | Control boundary | 3 | 3.65 | 3.37 | 6.61 | 6.03 |
| `fg-secondary` | `bg-list` | Secondary icon | 3 | 6.61 | 6.95 | 11.08 | 12.50 |
| `fg-secondary` | `bg-canvas` | Secondary icon | 3 | 6.02 | 7.49 | 9.33 | 13.72 |
| `fg-secondary` | `bg-card` | Secondary icon | 3 | 6.61 | 6.42 | 11.08 | 11.32 |
| `fg-secondary` | `bg-sunken` | Secondary icon | 3 | 5.66 | 5.71 | 8.75 | 9.83 |
| `fg-secondary` | `bg-rail` | Secondary icon | 3 | 5.51 | 6.57 | 8.51 | 12.00 |
| `accent` | `bg-list` | Checkbox/toggle on, primary button vs surface | 3 | 4.63 | 3.75 | 5.97 | 3.67 |
| `accent` | `bg-card` | Primary button vs card | 3 | 4.63 | 3.46 | 5.97 | 3.32 |
| `fg-primary` | `bg-sunken` | Segmented ink thumb vs track | 3 | 15.31 | 12.88 | 16.58 | 15.04 |
| `fg-on-accent` | `bg-selected` | Glyphs on slab (star, dot, pip halo) | 3 | 4.63 | 4.63 | 5.97 | 5.22 |
| `danger` | `bg-list` | Error icon | 3 | 5.99 | 6.33 | 8.21 | 9.58 |
| `fg-toast-danger` | `bg-toast` | Toast error glyph | 3 | 7.24 | 5.01 | 11.13 | 5.62 |
| `fg-toast-success` | `bg-toast` | Toast success glyph | 3 | 9.38 | 6.50 | 13.67 | 6.60 |
| `warning` | `bg-list` | Warning icon | 3 | 5.73 | 9.47 | 8.27 | 13.44 |
| `success` | `bg-list` | Success icon | 3 | 5.65 | 8.61 | 7.19 | 12.46 |
| `acct-1` (cobalt) | worst of list, rail, canvas, card | Account pip / rail avatar | 3 | 4.28 | 6.08 | 4.90 | 7.98 |
| `acct-2` (amber) | worst of list, rail, canvas, card | Account pip / rail avatar | 3 | 3.14 | 9.77 | 3.68 | 11.91 |
| `acct-3` (orchid) | worst of list, rail, canvas, card | Account pip / rail avatar | 3 | 4.49 | 4.56 | 5.34 | 6.25 |
| `acct-4` (emerald) | worst of list, rail, canvas, card | Account pip / rail avatar | 3 | 3.85 | 9.44 | 4.62 | 12.39 |
| `acct-5` (indigo) | worst of list, rail, canvas, card | Account pip / rail avatar | 3 | 7.49 | 3.45 | 8.88 | 4.75 |
| `acct-6` (rose) | worst of list, rail, canvas, card | Account pip / rail avatar | 3 | 4.33 | 6.23 | 5.14 | 7.64 |
| `acct-7` (teal) | worst of list, rail, canvas, card | Account pip / rail avatar | 3 | 3.19 | 6.60 | 3.74 | 8.81 |
| `acct-8` (olive) | worst of list, rail, canvas, card | Account pip / rail avatar | 3 | 5.80 | 5.61 | 6.93 | 7.52 |
| `acct-9` (cocoa) | worst of list, rail, canvas, card | Account pip / rail avatar | 3 | 7.53 | 3.33 | 8.87 | 4.60 |
| `acct-10` (graphite) | worst of list, rail, canvas, card | Account pip / rail avatar | 3 | 9.02 | 4.24 | 10.41 | 5.87 |
| `acct-1-ink` | `acct-1` | Rail avatar initials | 4.5 | 5.14 | 6.98 | 6.38 | 8.47 |
| `acct-2-ink` | `acct-2` | Rail avatar initials | 4.5 | 4.88 | 11.21 | 4.80 | 12.63 |
| `acct-3-ink` | `acct-3` | Rail avatar initials | 4.5 | 5.39 | 5.23 | 6.95 | 6.63 |
| `acct-4-ink` | `acct-4` | Rail avatar initials | 4.5 | 4.62 | 10.83 | 6.02 | 13.14 |
| `acct-5-ink` | `acct-5` | Rail avatar initials | 4.5 | 8.99 | 4.65 | 11.56 | 5.04 |
| `acct-6-ink` | `acct-6` | Rail avatar initials | 4.5 | 5.19 | 7.15 | 6.70 | 8.11 |
| `acct-7-ink` | `acct-7` | Rail avatar initials | 4.5 | 4.80 | 7.57 | 4.86 | 9.35 |
| `acct-8-ink` | `acct-8` | Rail avatar initials | 4.5 | 6.96 | 6.43 | 9.02 | 7.98 |
| `acct-9-ink` | `acct-9` | Rail avatar initials | 4.5 | 9.03 | 4.82 | 11.55 | 4.88 |
| `acct-10-ink` | `acct-10` | Rail avatar initials | 4.5 | 10.83 | 4.86 | 13.55 | 6.23 |
| `av-1-fg` | `av-1-bg` (sky) | Avatar initials | 4.5 | 5.54 | 6.95 | 7.31 | 9.86 |
| `av-2-fg` | `av-2-bg` (iris) | Avatar initials | 4.5 | 6.08 | 6.97 | 8.30 | 9.88 |
| `av-3-fg` | `av-3-bg` (orchid) | Avatar initials | 4.5 | 6.11 | 7.00 | 8.34 | 9.76 |
| `av-4-fg` | `av-4-bg` (rose) | Avatar initials | 4.5 | 6.07 | 6.63 | 8.27 | 9.40 |
| `av-5-fg` | `av-5-bg` (amber) | Avatar initials | 4.5 | 6.15 | 7.07 | 8.33 | 9.83 |
| `av-6-fg` | `av-6-bg` (moss) | Avatar initials | 4.5 | 6.18 | 7.06 | 8.36 | 10.03 |
| `av-7-fg` | `av-7-bg` (lagoon) | Avatar initials | 4.5 | 5.58 | 7.06 | 7.56 | 9.99 |
| `av-8-fg` | `av-8-bg` (slate) | Avatar initials | 4.5 | 6.11 | 7.07 | 8.38 | 10.08 |


## Appendix: contrast and color-vision script

The tables above were produced by this script (Python 3, standard library only) run over the token table; `contrast()` is WCAG 2.x, `simulate()` applies the Machado et al. 2009 full-severity matrices in linear RGB, and `de2000()` is CIEDE2000.

```python
import math
def hex2rgb(h):
    h=h.lstrip('#'); return tuple(int(h[i:i+2],16)/255 for i in (0,2,4))
def rgb2hex(c): return '#%02X%02X%02X'%tuple(max(0,min(255,round(v*255))) for v in c)
def lin(v): return v/12.92 if v<=0.04045 else ((v+0.055)/1.055)**2.4
def unlin(v): return 12.92*v if v<=0.0031308 else 1.055*v**(1/2.4)-0.055
def lum(c):
    r,g,b=[lin(x) for x in c]; return 0.2126*r+0.7152*g+0.0722*b
def parse(s):
    # "#RRGGBB" or "#RRGGBB@0.12"
    if '@' in s:
        h,a=s.split('@'); return hex2rgb(h),float(a)
    return hex2rgb(s),1.0
def over(fg,a,bg): return tuple(f*a+b*(1-a) for f,b in zip(fg,bg))
def contrast(c1,c2):
    l1,l2=lum(c1),lum(c2); hi,lo=max(l1,l2),min(l1,l2); return (hi+0.05)/(lo+0.05)
def resolve(s,bg=None):
    c,a=parse(s)
    if a<1:
        assert bg is not None; return over(c,a,bg)
    return c
# CIELAB + CIEDE2000
def rgb2lab(c):
    r,g,b=[lin(x) for x in c]
    X=0.4124564*r+0.3575761*g+0.1804375*b
    Y=0.2126729*r+0.7151522*g+0.0721750*b
    Z=0.0193339*r+0.1191920*g+0.9503041*b
    X/=0.95047; Z/=1.08883
    f=lambda t: t**(1/3) if t>0.008856 else 7.787*t+16/116
    fx,fy,fz=f(X),f(Y),f(Z)
    return (116*fy-16,500*(fx-fy),200*(fy-fz))
def de2000(l1,l2):
    L1,a1,b1=l1; L2,a2,b2=l2
    C1=math.hypot(a1,b1); C2=math.hypot(a2,b2); Cb=(C1+C2)/2
    G=0.5*(1-math.sqrt(Cb**7/(Cb**7+25**7)))
    a1p=(1+G)*a1; a2p=(1+G)*a2
    C1p=math.hypot(a1p,b1); C2p=math.hypot(a2p,b2)
    h1p=math.degrees(math.atan2(b1,a1p))%360; h2p=math.degrees(math.atan2(b2,a2p))%360
    dLp=L2-L1; dCp=C2p-C1p
    dhp=h2p-h1p
    if C1p*C2p==0: dhp=0
    elif dhp>180: dhp-=360
    elif dhp<-180: dhp+=360
    dHp=2*math.sqrt(C1p*C2p)*math.sin(math.radians(dhp/2))
    Lbp=(L1+L2)/2; Cbp=(C1p+C2p)/2
    if C1p*C2p==0: hbp=h1p+h2p
    elif abs(h1p-h2p)>180: hbp=(h1p+h2p+360)/2
    else: hbp=(h1p+h2p)/2
    T=1-0.17*math.cos(math.radians(hbp-30))+0.24*math.cos(math.radians(2*hbp))+0.32*math.cos(math.radians(3*hbp+6))-0.20*math.cos(math.radians(4*hbp-63))
    dth=30*math.exp(-((hbp-275)/25)**2)
    RC=2*math.sqrt(Cbp**7/(Cbp**7+25**7))
    SL=1+0.015*(Lbp-50)**2/math.sqrt(20+(Lbp-50)**2)
    SC=1+0.045*Cbp; SH=1+0.015*Cbp*T
    RT=-math.sin(math.radians(2*dth))*RC
    return math.sqrt((dLp/SL)**2+(dCp/SC)**2+(dHp/SH)**2+RT*(dCp/SC)*(dHp/SH))
MACHADO={
 'protan':[[0.152286,1.052583,-0.204868],[0.114503,0.786281,0.099216],[-0.003882,-0.048116,1.051998]],
 'deutan':[[0.367322,0.860646,-0.227968],[0.280085,0.672501,0.047413],[-0.011820,0.042940,0.968881]],
 'tritan':[[1.255528,-0.076749,-0.178779],[-0.078411,0.930809,0.147602],[0.004733,0.691367,0.303900]],
}
def simulate(c,kind):
    if kind=='normal': return c
    l=[lin(x) for x in c]; m=MACHADO[kind]
    o=[max(0,min(1,sum(m[i][j]*l[j] for j in range(3)))) for i in range(3)]
    return tuple(unlin(x) for x in o)
def lab2rgb(lab):
    L,a,b=lab
    fy=(L+16)/116; fx=fy+a/500; fz=fy-b/200
    finv=lambda t: t**3 if t**3>0.008856 else (t-16/116)/7.787
    X=finv(fx)*0.95047; Y=finv(fy); Z=finv(fz)*1.08883
    r= 3.2404542*X-1.5371385*Y-0.4985314*Z
    g=-0.9692660*X+1.8760108*Y+0.0415560*Z
    b2=0.0556434*X-0.2040259*Y+1.0572252*Z
    return tuple(unlin(max(0,min(1,v))) for v in (r,g,b2))
def lch(L,C,h):
    return rgb2hex(lab2rgb((L,C*math.cos(math.radians(h)),C*math.sin(math.radians(h)))))
def tolch(hx):
    L,a,b=rgb2lab(hex2rgb(hx)); return L,math.hypot(a,b),math.degrees(math.atan2(b,a))%360
```
