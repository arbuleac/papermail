# Quire

**A design language for SuperSparrow.** Editorial direction · proposal · 2 November 2026

A quire is a gathering of folded sheets, the unit a book is sewn from. Quire treats mail the same way: each conversation is a tight stack of folded messages and one open sheet, set in New York on warm paper and marked in a single ink, **Iron Gall**, the blue-black ink letters were written in for a thousand years. The list stays compact and still, like an index. The reader gets the room of a page.

Companion files in this folder:

- `specimen.html`: the main window, the composer, a component sheet and the foundations, drawn from the same tokens (CSS custom properties, light and dark, `prefers-contrast: more`).
- `specimen-light.png`, `specimen-dark.png`: the specimen rendered with WebKit at 1440 pt.

Every number in this document is a requirement unless it is marked as an example. Colour values were checked with a script (WCAG 2.x relative luminance; Machado 2009 colour-vision simulation; CIEDE2000). The script output is in §6.

---

## 1. Principles

1. **Reading is the product.** Use serif where people read and sans where they scan or write. New York sets subjects everywhere (list, reader, composer, condensed title) and the default reading text. SF Pro sets everything you scan or type.
2. **One ink, used like a proofreader's pen.** Iron Gall appears only where something needs you: unread, keyboard focus, the current selection, the single primary action. If two Iron Gall things compete on screen, one of them is wrong.
3. **A still list, a generous page.** The list is an index: fixed rows, fixed metrics, no motion, no shadows, no blur. The reader is a page: a 680 pt column, 24 pt leading, wide margins.
4. **Shape before colour.** Every state has a shape, a weight or a word: the pip, the margin rule, Semibold, the filled star, the "Other" tag, the "!" badge. Colour reinforces state but never carries it alone.
5. **Native first, then ours.** Traffic lights, menus, alerts, tooltips, notifications and scroll behaviour stay macOS. Quire styles content, not chrome.

## 2. Signature elements

| Element | What it is | Where |
|---|---|---|
| **New York subjects** | Every subject line is set in New York: 14 pt in rows, 26 pt as the reader headline, 15 pt in the composer. Mixed with SF Pro senders and snippets, the list reads like a table of contents. | List rows, reader, composer, compact rows |
| **Iron Gall** | The single accent. It reads blue-black on paper (`#1E5468`) and as wet ink in dark mode (`#6DB6C9`), where iron gall ink looks bluest before it dries. | Unread pip, focus ring, selection, primary button, links |
| **The margin rule** | A 3 pt vertical rule flush with the leading edge marks where you are, the way an editor marks a passage in the margin. It is the same mark everywhere. | Selected row, selected rail item, compact rows |
| **The quire** | Collapsed messages fold into one tight stack of 44 pt lines inside a single rounded sheet. The open message is a full sheet beneath it. No gaps or shadows between folded messages. | Reader |
| **Kicker and headline** | Above the subject, a small-caps kicker names the account (with its ink dot) and the message count, as a newspaper names its section. | Reader header |
| **The elision mark `[…]`** | Quoted text is folded behind the editor's mark for omitted text. It sits at the fold, not in a toolbar. | Reader, composer, quick reply |
| **The slip** | Toasts and the undo-send panel are inverse ink slips: opaque, small, one verb. | Toast, undo send |
| **Monograms** | Avatar initials are set in New York Semibold on soft pigment tints, like monogrammed letterhead. | Rows, reader, rail, settings |
| **Running heads** | Rows are grouped under small-caps day heads followed by a hairline. | List |

## 3. Platform decisions

**System accent: fixed Iron Gall, with one exception.** Quire does not adopt `NSColor.controlAccentColor`. Its selection, focus and button colours are tuned against the paper surfaces for contrast in four modes, and an arbitrary accent (Yellow, Graphite on paper) breaks those pairs. One exception: when the user has chosen **Graphite** (`NSColor.currentControlTint == .graphiteControlTint`, or `controlAccentColor` with saturation < 0.1), Iron Gall is replaced by the ink ramp (`q.accent → q.ink`, `q.selWash → q.selWashIdle`, `q.selRule → q.ink`), because that user has asked macOS to take colour out. Text selection inside text views keeps the system's `selectedTextBackgroundColor`, which users set as a personal habit.

**Window and title bar.** One main window, `.titled .closable .miniaturizable .resizable .fullSizeContentView`, `titlebarAppearsTransparent = true`, `titleVisibility = .hidden`, no toolbar. The top 52 pt of every pane is the title-bar zone: it accepts window drags (`mouseDownCanMoveWindow`), double-click follows the system "double-click a window's title bar" preference, and traffic lights sit at the standard position (first light origin 20,20; 12 pt lights; 8 pt gaps; they end at x = 72). The rail is 76 pt wide so the lights always sit on the rail. In minimal mode (rail hidden) the list title starts at x = 84. In full screen the title-bar zone keeps its 52 pt so nothing jumps.

**Menus, alerts, tooltips, notifications, scrollers** are system components. Quire supplies their titles, symbols, shortcuts and copy (§4.13, §5.31–5.33, §5.38).

**Appearance.** Light and dark follow the system (`NSApp.effectiveAppearance`). Increased contrast (`NSWorkspace.accessibilityDisplayShouldIncreaseContrast`, CSS `prefers-contrast: more`) switches every token to its IC value, adds 1 pt `q.ruleStrong` outlines to sheets, menus and slips, and turns the hover wash into the pressed wash. Reduce Transparency replaces the rail material with solid `q.spine`. Reduce Motion is covered in §4.10.

**One token set, three renderers.** Tokens live in one Swift file (`QuireTokens.swift`, generated from `quire-tokens.json`) and one generated CSS string in `ConversationShellAssets`. AppKit reads them through dynamic `NSColor(name:dynamicProvider:)`; SwiftUI through `Color(nsColor:)`; WebKit through custom properties under `@media (prefers-color-scheme: dark)` and `(prefers-contrast: more)`. The generator also emits the contrast table in §6, so a token change that breaks a pair fails the build.

```swift
// QuireTokens.swift (generated). One provider per token; IC is resolved inside the provider.
extension NSColor {
    static let qPaper = quire("q.paper", light: 0xFBFAF6, dark: 0x1C1B18, lightIC: 0xFDFCFA, darkIC: 0x121110)

    static func quire(_ name: String, light: UInt32, dark: UInt32, lightIC: UInt32, darkIC: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
                .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
            let isIC = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let hex = isDark ? (isIC ? darkIC : dark) : (isIC ? lightIC : light)
            return NSColor(srgbHex: hex, alpha: alpha)
        }
    }
}
```

```css
/* ConversationShellAssets.css (generated head). Names match the Swift tokens: q.paper -> --q-paper. */
:root { --q-paper:#FBFAF6; --q-canvas:#F4F2EC; --q-sheet:#FFFEFB; --q-ink:#1D1B18; --q-accent:#1E5468; /* … */ }
@media (prefers-color-scheme: dark) { :root { --q-paper:#1C1B18; --q-canvas:#171614; /* … */ } }
@media (prefers-contrast: more) { :root { /* light IC */ } }
@media (prefers-color-scheme: dark) and (prefers-contrast: more) { :root { /* dark IC */ } }
```

Layer-backed views must re-resolve `CGColor`s in `viewDidChangeEffectiveAppearance()` (and on `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`), because `CALayer` colours do not track appearance. Row content caches (`RowContentCache`) key on appearance + contrast as well as conversation id and version.

---
## 4. Foundations

### 4.1 Colour

**Neutral ramp: paper to ink.** Warm grey, hue about 75°, chroma under 4 (CIELCh). The ramp has eleven roles, which are the same in every mode; only the values move. From lightest to darkest in light mode: `spine`, `canvas`, `paper`, `sheet`, `raised` (surfaces), `rule`, `ruleStrong` (lines), `inkDisabled`, `ink3`, `ink2`, `ink` (text). Dark mode inverts the text end and puts the desk (`canvas`) and the rail (`spine`) below the paper, so sheets rise by lightness instead of shadow.

Surface hierarchy, light mode, from the back:

1. `spine`, the rail: the deepest paper tone, behind sidebar vibrancy.
2. `canvas`, the reader desk: one step below the list paper so the open sheet lifts.
3. `paper`, the list, title-bar zones, composer chrome and quick-reply bar.
4. `sheet`, message cards, fields and the composer page.
5. `raised`, menus, popovers, segmented thumbs, keycaps and the secondary button face.

`slip` is the inverse surface: ink-coloured in light mode, paper-coloured in dark mode.

**Usage rules**

- Text uses only `ink`, `ink2` and `ink3` (or `onAccent`, `onSlip`, `onSlip2`, `onDanger` on those fills). `ink3` is the lightest text allowed; `inkDisabled` is only for disabled controls.
- `rule` is decorative: separators, pane dividers, sheet edges. Anything whose edge tells you what the control is or what state it is in (fields, checkboxes, outline buttons, tags) uses `ruleStrong` (≥ 3:1).
- Washes (`hover`, `pressed`, `fill`) are ink at low alpha so they work on any surface. In AppKit draw them as a fill over the surface; in CSS layer them as `linear-gradient(var(--q-hover), var(--q-hover))` over the surface colour.
- Iron Gall (`accent`) never fills an area larger than a button. Selection is a wash (`selWash`) plus the margin rule, never a solid block.
- Semantic colours always appear with a glyph and a word: warning triangle with "Sign in required", never a red word alone.


**Surfaces**

| Token | Light | Dark | Light IC | Dark IC | Use |
|---|---|---|---|---|---|
| `q.spine` | `#ECE9E1` | `#121110` | `#E4E0D6` | `#080807` | Account rail (solid fallback under sidebar material) |
| `q.paper` | `#FBFAF6` | `#1C1B18` | `#FDFCFA` | `#121110` | List pane, title bars, composer chrome |
| `q.canvas` | `#F4F2EC` | `#171614` | `#F1EFE9` | `#0D0C0B` | Reader desk behind sheets |
| `q.sheet` | `#FFFEFB` | `#24221F` | `#FFFFFF` | `#1C1B19` | Message cards, fields, menus-like surfaces, composer body |
| `q.raised` | `#FFFFFF` | `#2C2A26` | `#FFFFFF` | `#252320` | Popovers, toasts-light, segmented thumb, kbd caps |
| `q.slip` | `#24221F` | `#EDE9E2` | `#12100E` | `#FFFFFF` | Toast / undo-send slip (inverse surface) |

**Ink**

| Token | Light | Dark | Light IC | Dark IC | Use |
|---|---|---|---|---|---|
| `q.ink` | `#1D1B18` | `#EDE9E2` | `#0F0E0C` | `#FFFFFF` | Primary text, headlines |
| `q.ink2` | `#55504A` | `#B8B2A8` | `#3A3631` | `#DCD7CE` | Secondary text: snippets, meta, labels |
| `q.ink3` | `#6B655D` | `#A29C92` | `#4A4540` | `#C8C2B8` | Tertiary text: timestamps, running heads, placeholders |
| `q.inkDisabled` | `#A9A398` | `#5F5A53` | `#8A8479` | `#7D776F` | Disabled text and glyphs (exempt from 4.5:1) |
| `q.onSlip` | `#F3F0EA` | `#1D1B18` | `#FFFFFF` | `#0F0E0C` | Text on slip |
| `q.onSlip2` | `#B8B2A8` | `#55504A` | `#D9D4CB` | `#3A3631` | Secondary text on slip |

**Rules and washes**

| Token | Light | Dark | Light IC | Dark IC | Use |
|---|---|---|---|---|---|
| `q.rule` | `#E4E0D7` | `#34312D` | `#B9B3A8` | `#55514A` | Decorative hairline: row separators, pane dividers |
| `q.ruleStrong` | `#8A8479` | `#7A746B` | `#5E5952` | `#A39D93` | State-bearing borders: fields, checkbox, outline buttons (>=3:1) |
| `q.hover` | `#1D1B18` @ 4.5% | `#EDE9E2` @ 5.5% | `#1D1B18` @ 7% | `#FFFFFF` @ 9% | Hover wash |
| `q.pressed` | `#1D1B18` @ 9% | `#EDE9E2` @ 10% | `#1D1B18` @ 13% | `#FFFFFF` @ 15% | Pressed wash |
| `q.fill` | `#1D1B18` @ 6% | `#EDE9E2` @ 8% | `#1D1B18` @ 9% | `#FFFFFF` @ 12% | Quiet fill: count badge, ghost chips, search track |
| `q.scrim` | `#1D1B18` @ 28% | `#000000` @ 50% | `#1D1B18` @ 40% | `#000000` @ 60% | Sheet scrim behind alerts (specimen only; AppKit draws its own) |

**Iron Gall: accent, selection, focus**

| Token | Light | Dark | Light IC | Dark IC | Use |
|---|---|---|---|---|---|
| `q.accent` | `#1E5468` | `#6DB6C9` | `#123E4D` | `#93D3E3` | Iron Gall: links, primary button, unread pip, focus |
| `q.accentHover` | `#18475A` | `#82C3D4` | `#0D3240` | `#A9DEEB` | Primary button hover |
| `q.accentPressed` | `#123A4A` | `#5AA2B5` | `#082733` | `#7FC4D6` | Primary button pressed |
| `q.onAccent` | `#FFFFFF` | `#0C1D22` | `#FFFFFF` | `#06161B` | Text/glyph on accent fill |
| `q.accentWash` | `#DCE8EA` | `#1F363C` | `#C8DCE0` | `#1A4049` | Emphasised selection, active token |
| `q.focus` | `#1E5468` | `#6DB6C9` | `#123E4D` | `#93D3E3` | Keyboard focus ring (2 px, 2 px offset on cards) |
| `q.selWash` | `#DCE8EA` | `#1F363C` | `#C8DCE0` | `#1A4049` | Selected row, list has focus |
| `q.selRule` | `#1E5468` | `#6DB6C9` | `#123E4D` | `#93D3E3` | Margin rule of selected row, list has focus |
| `q.selWashIdle` | `#EAE7DF` | `#2B2925` | `#DCD8CE` | `#302D29` | Selected row, focus elsewhere or window inactive |
| `q.selRuleIdle` | `#6B655D` | `#A29C92` | `#4A4540` | `#C8C2B8` | Margin rule of idle selection |

**Marks and semantics**

| Token | Light | Dark | Light IC | Dark IC | Use |
|---|---|---|---|---|---|
| `q.star` | `#8F6400` | `#E0B04A` | `#6E4C00` | `#F0C565` | Star (always with filled vs outline shape) |
| `q.success` | `#2D6A3E` | `#7BC58C` | `#1D522C` | `#9AD9A8` | Success text/glyph |
| `q.warning` | `#855200` | `#E3AE52` | `#653E00` | `#F2C374` | Warning text/glyph |
| `q.danger` | `#AE2A1F` | `#FF8B7B` | `#8C1C13` | `#FFADA1` | Danger text/glyph, destructive button fill (light) |
| `q.info` | `#365693` | `#97B0E6` | `#24417A` | `#B8CBF2` | Info text/glyph |
| `q.successWash` | `#E5EFE5` | `#1D2E21` | `#D3E6D5` | `#1E3A25` | Banner fill |
| `q.warningWash` | `#F6ECD8` | `#33291A` | `#EEDDBA` | `#3F311A` | Banner fill (remote images) |
| `q.dangerWash` | `#F8E3DF` | `#3A201C` | `#F0CEC8` | `#4A231E` | Banner fill |
| `q.infoWash` | `#E4EAF5` | `#1E2638` | `#D0DAEE` | `#22304A` | Banner fill |
| `q.dangerFill` | `#AE2A1F` | `#FF8B7B` | `#8C1C13` | `#FFADA1` | Destructive button fill |
| `q.onDanger` | `#FFFFFF` | `#2A0B07` | `#FFFFFF` | `#1E0503` | Text on destructive fill |

Alpha tokens are given as base colour @ opacity; composite them over the surface beneath. `scrim` is for the specimen only; AppKit draws its own sheet dimming.

**Accent states.** Rest `accent`, hover `accentHover`, pressed `accentPressed`, disabled = `fill` with `inkDisabled` text. In an inactive window the primary button loses its fill and draws as a secondary button, as native default buttons do.

**Selection.**

| Situation | Fill | Margin rule (3 pt) | Text |
|---|---|---|---|
| List (or rail) has keyboard focus, window key | `selWash` | `selRule` (Iron Gall) | unchanged inks |
| Focus elsewhere (reader, search, composer) or window inactive | `selWashIdle` | `selRuleIdle` (`ink3`) | unchanged inks |
| Graphite system accent | `selWashIdle` | `ink` | unchanged inks |

Text never inverts on selection. This keeps the attributed strings cached per row valid across selection changes (no rebuild on `j`/`k`).

**Focus.** 2 pt ring in `focus`, separated from the control by a 1 pt gap in the surface colour (2 pt gap around sheets and cards), following the control's corner radius plus the gap. It is never animated. In AppKit draw it yourself in `drawFocusRingMask()` or as a layer border on a sublayer; do not use the default focus-ring style (its 50 % alpha fails 3:1 on paper).

### 4.2 Account inks

Ten account inks, assigned in this order as accounts are added, editable in Settings › Accounts. Each mode has its own value so that the ring passes 3:1 against `paper`, `spine`, `sheet`, `canvas`, `selWash` and `selWashIdle` (light IC: ≥ 4.3:1 against `paper`).

| # | Ink | Light | Dark | Light IC | Dark IC |
|---|---|---|---|---|---|
| 1 | Cobalt | `#12468F` | `#6888DA` | `#003472` | `#7998EB` |
| 2 | Ochre | `#886800` | `#E8C65C` | `#705500` | `#FAD76C` |
| 3 | Oxblood | `#A3123F` | `#F06A86` | `#840230` | `#FE7E96` |
| 4 | Viridian | `#008478` | `#4FD3BD` | `#006E64` | `#6CE3CE` |
| 5 | Iris | `#6259C9` | `#C3AEF8` | `#4F48A8` | `#D3C0FF` |
| 6 | Moss | `#45530A` | `#6E9E48` | `#344001` | `#85AC64` |
| 7 | Terracotta | `#B35A47` | `#F4A585` | `#964A3A` | `#FDB99D` |
| 8 | Aubergine | `#552950` | `#A87199` | `#3F1A3B` | `#B284A5` |
| 9 | Cerulean | `#1B6587` | `#6AAFC0` | `#0E516E` | `#87BECC` |
| 10 | Graphite | `#5A5855` | `#A9A39C` | `#474543` | `#B8B3AD` |

Distinguishability (CIEDE2000 between every pair, after simulating protanopia, deuteranopia and tritanopia at full severity with the Machado 2009 matrices in linear sRGB):

| Mode | Normal | Protanopia | Deuteranopia | Tritanopia | Worst CVD pair | Min CVD ΔE for the first k accounts (k = 2…10) |
|---|---|---|---|---|---|---|
| Light | 13.4 | 8.2 | 8.4 | 8.7 | Oxblood / Graphite (8.2) | 46 · 14 · 14 · 12 · 8 · 8 · 8 · 8 · 8 |
| Dark | 17.0 | 9.9 | 8.1 | 9.0 | Oxblood / Graphite (8.1) | 44 · 19 · 17 · 13 · 11 · 9 · 9 · 9 · 8 |
| Light IC | 12.7 | 7.0 | 7.7 | 8.0 | Oxblood / Graphite (7.0) | 43 · 13 · 13 · 10 · 8 · 8 · 8 · 8 · 7 |
| Dark IC | 16.9 | 9.0 | 8.4 | 8.2 | Ochre / Terracotta (8.2) | 41 · 19 · 17 · 12 · 9 · 8 · 8 · 8 · 8 |

Reading the table: for ordinary vision every pair is at least 12.7 ΔE apart. Under the three dichromacies the closest pair is 7.0–8.2 ΔE apart (Oxblood and Graphite in most modes). The first four accounts, which cover nearly all real setups, stay at least 13 ΔE apart, and the first five at least 10. The order was chosen so each new ink is the one farthest from those already in use. A 1.5 pt ring is a small mark, so account identity is never carried by colour alone:

- the kicker above the reader headline names the account in text, next to its ink dot;
- the row's avatar tooltip and VoiceOver label include the account ("Priya Raman, Personal account");
- the rail shows each account's monogram or photo, and the list title shows the account address when narrowed;
- in compact density the account mark is a 6 pt **square** (the unread pip is a circle), so shape separates the two marks.

### 4.3 Avatar tints

Sender avatars use eight soft pigment tints, chosen by a stable hash of the lowercased address (FNV-1a, modulo 8). Faces are never account-coloured, so a sender looks the same in every account. Initials are New York Semibold at 0.42 × the diameter, max two letters, in the tint's own ink; every pair passes 4.5:1. A photo, when one exists locally, replaces the face. Initials are painted first and the photo cross-fades in only if it arrives within 100 ms; later arrivals swap without animation.

| Tint | Light face / ink | Dark face / ink | Light IC face / ink | Dark IC face / ink |
|---|---|---|---|---|
| Clay | `#EFDCD2` / `#7A3E26` | `#3E2A22` / `#EBC1AE` | `#E8CFC2` / `#5E2C18` | `#4A3128` / `#F6D7C8` |
| Wheat | `#F0E3C4` / `#6B4E0E` | `#3A3120` / `#E6CC8E` | `#E8D8AE` / `#4E3807` | `#463A22` / `#F3DFAE` |
| Fern | `#DDE8D2` / `#3B5A22` | `#29331F` / `#B9D49C` | `#CCDDBC` / `#2A4316` | `#323E26` / `#D0E5BA` |
| Sea | `#D3E8E4` / `#1F5A52` | `#1D3532` / `#A2D6CB` | `#BEDDD7` / `#12443D` | `#223F3B` / `#C1E6DE` |
| Slate | `#DCE2EE` / `#2F4A78` | `#232C3B` / `#B3C3E4` | `#C9D2E6` / `#1F375F` | `#2A3446` / `#CDD8F0` |
| Heather | `#E6DEEE` / `#55377A` | `#2E2638` / `#CDB8E8` | `#D9CDE7` / `#41255F` | `#372D43` / `#DDCDF2` |
| Rose | `#F1DCE0` / `#7C2E45` | `#3C2529` / `#EDB5C2` | `#E9C9D0` / `#5F1C31` | `#472C31` / `#F5CCD6` |
| Stone | `#E6E2DA` / `#4E4943` | `#2F2D2A` / `#CFC8BD` | `#D8D3C9` / `#36322D` | `#383532` / `#E2DCD2` |

### 4.4 Typography

System families only: **SF Pro** (`NSFont.systemFont`, CSS `-apple-system, system-ui`), **New York** (`NSFontDescriptor.withDesign(.serif)`, CSS `ui-serif`), **SF Pro Rounded** (`.withDesign(.rounded)`, CSS `ui-rounded`), **SF Mono** (`.monospacedSystemFont`, CSS `ui-monospace`). No bundled or web fonts.

| Role | Family | Size (pt) | Weight | Line height (pt) | Tracking (pt) | Used for |
|---|---|---|---|---|---|---|
| `display` | New York | 34 | Semibold (600) | 40 | -0.6 | Welcome title |
| `headline` | New York | 26 | Semibold (600) | 32 | -0.4 | Reader subject headline |
| `masthead` | New York | 20 | Semibold (600) | 24 | -0.2 | List view title ("Inbox") |
| `title` | SF Pro | 15 | Semibold (600) | 20 | -0.1 | Condensed reader title, sheet titles, settings section titles |
| `reading` | New York | 15 | Regular (400) | 24 | +0.0 | Reader default body (plain-text and unstyled mail) |
| `subject` | New York | 14 | Regular (400) | 18 | +0.0 | List row subject; Semibold (600) when unread |
| `composeSubject` | New York | 15 | Regular (400) | 20 | +0.0 | Composer subject field |
| `writing` | SF Pro | 14 | Regular (400) | 21 | +0.0 | Composer body, quick reply |
| `body` | SF Pro | 13 | Regular (400) | 18 | +0.0 | Controls, settings, menus, sender line |
| `sender` | SF Pro | 13 | Regular (400) | 16 | +0.0 | List row sender; Semibold (600) when unread |
| `label` | SF Pro | 12 | Medium (500) | 16 | +0.0 | Buttons (small), chips, tabs, field labels |
| `snippet` | SF Pro | 12 | Regular (400) | 15 | +0.0 | List snippet, collapsed card snippet |
| `meta` | SF Pro | 11 | Regular (400) | 14 | +0.1 | Timestamps (tabular digits), sync line, captions |
| `runningHead` | SF Pro | 10 | Semibold (600) | 12 | +0.8 | Date dividers, section overlines (uppercase) |
| `badge` | SF Pro Rounded | 11 | Semibold (600) | 14 | +0.0 | Count badges (tabular digits) |
| `monogram` | New York | 0.42 × avatar | Semibold (600) | 1.0 × size | +0.0 | Avatar initials, size = 0.42 x diameter |
| `kbd` | SF Pro | 11 | Medium (500) | 14 | +0.0 | Keyboard hints (keycaps); SF Pro carries the modifier glyphs |
| `mono` | SF Mono | 12 | Regular (400) | 16 | +0.0 | OAuth client IDs, raw source |

Rules:

- **Read in serif, write in sans.** Composer and quick-reply bodies use `writing` (SF Pro 14/21) because what you type is sent without a font, and recipients will see their own default sans. Only the composer subject keeps New York.
- **Reading font setting.** Settings › General › Reading font: New York (default) or SF Pro. It switches `reading` only (plain-text and unstyled bodies). HTML mail with its own fonts is never restyled.
- **Tabular digits** (`.monospacedDigit` / `font-variant-numeric: tabular-nums`) for timestamps, counts, badges, sizes and progress, so columns do not jitter during sync.
- **Tracking** is in points at the stated size. AppKit: `.kern`; CSS: `letter-spacing` in px. New York display sizes take negative tracking; the running head takes +0.8 pt and uppercase.
- **Line height** is set exactly: AppKit `NSParagraphStyle.minimumLineHeight = maximumLineHeight = value` with `baselineOffset` = (lineHeight − font.lineHeight) / 2; CSS `line-height` in px.
- **Weights.** Regular 400, Medium 500, Semibold 600. Bold 700 is not used; unread is Semibold so it does not reflow truncation much.
- **Truncation** is always tail with an ellipsis, single line, no tightening (`allowsDefaultTighteningForTruncation = false`).
- **Dynamic type.** macOS has no system text size for apps, so Quire offers Settings › General › Text size (Small −1, Default, Large +1, Larger +2 pt applied to every role; list row height steps 64 / 68 / 72 / 76 pt).
- Mapping from today's eight ad-hoc sizes: 10 → `runningHead`; 11 → `meta`; 12 → `snippet` or `label`; 13 → `body` or `sender`; 14 → `writing` or the monogram in the rail; plus the three New York display sizes, which are new.

### 4.5 Spacing

4 pt base. Use only these steps: **2, 4, 6, 8, 12, 16, 20, 24, 32, 40, 48, 64** (`q.s1`…`q.s12`). Layout constants that are not on the scale (row 68, avatar box 38 at x 20, text column 68) are component metrics and are listed with their components.

Key rhythms: list horizontal inset 16; reader column margins at least 32 (80 at 1280 pt); sheet padding 22 top, 28 sides, 14 bottom; stack-to-sheet gap 12; paragraph spacing 12 (reading) and 10 (writing).

### 4.6 Radii

| Token | Value | Used for |
|---|---|---|
| `q.r.xs` | 3 pt | Tags, account square, skeleton bars |
| `q.r.sm` | 6 pt | Buttons (regular), fields, popups, icon buttons, chips, banners; menu items and small buttons use 5 pt |
| `q.r.md` | 8 pt | Sheets and stacks, attachment chips, menus, toasts, quick-reply field, large buttons; tooltips use 5 pt |
| `q.r.lg` | 12 pt | Floating panels (undo send), the welcome card, specimen panels |
| `q.r.pill` | height / 2 | Badges, address tokens, avatars, toggles, pips |

Rail tiles use 11 pt on a 38 pt tile (a near-squircle). Small buttons use 5 pt. Window corners are the system's.

### 4.7 Borders and hairlines

- **Hairline** = one device pixel (`1 / backingScaleFactor` pt, 0.5 pt on Retina), colour `rule`. Used for row separators (inset to the text column, x = 68), pane dividers, the list header bottom, sheet edges and stack separators.
- **Strong rule** = 1 pt, `ruleStrong`: field borders, checkbox and toggle outlines, outline and secondary buttons, tags, keycap edges in IC.
- **Tab underline** = 2 pt `ink` (`ink3` when the window is inactive), sitting on the header hairline.
- **Margin rule** = 3 pt wide, height = row height − 16 (rail: 24), corner radius 0 / 2 / 2 / 0, flush with the pane's leading edge.
- **Focus ring** = 2 pt `focus` + 1 pt gap (2 pt around sheets).
- In increased contrast, hairlines become 1 pt and sheets, stacks, menus, slips and the quick-reply field gain a 1 pt `ruleStrong` edge.

### 4.8 Elevation

Paper is flat. Only things that float cast shadows, and rows never do.

| Level | Light | Dark | AppKit (primary layer) | Used for |
|---|---|---|---|---|
| e0 | none (hairline only) | none (hairline only) | none | List, stack, fields, attachment chips |
| e1 | `0 1px 2px rgba(29,27,24,.06)` | `0 1px 2px rgba(0,0,0,.35)` | opacity .06 / .35, radius 1, offset (0, −1) | The open message sheet |
| e2 | `0 6px 20px rgba(29,27,24,.14), 0 1px 3px rgba(29,27,24,.10)` | `0 8px 24px rgba(0,0,0,.50), 0 1px 3px rgba(0,0,0,.35)` | opacity .14 / .50, radius 10 / 12, offset (0, −6 / −8); second sublayer for the contact shadow | Toasts, custom tooltips in the reader, popovers |
| e3 | `0 16px 40px rgba(29,27,24,.18), 0 2px 8px rgba(29,27,24,.10)` | `0 18px 48px rgba(0,0,0,.60), 0 2px 8px rgba(0,0,0,.40)` | opacity .18 / .60, radius 20 / 24, offset (0, −16 / −18) | Undo-send panel, Quire-drawn sheets |

CSS blur = 2 × `CALayer.shadowRadius`. Set `shadowPath` on every shadowed layer (no offscreen pass). Shadows are identical in IC; the IC edge comes from the added `ruleStrong` outline. Menus, alerts and system sheets use the system's own shadows.

### 4.9 Materials

| Region | Material | Reduce Transparency | Why |
|---|---|---|---|
| Account rail | `NSVisualEffectView`, `.sidebar`, `.behindWindow`, `state = .followsWindowActiveState` | solid `spine` | Large, static, never scrolls: vibrancy costs nothing per frame |
| Title-bar zones, list, reader, composer | none (opaque `paper` / `canvas` / `sheet`) | same | Editorial pages are opaque; opaque title bars also avoid re-blurring on every scroll frame |
| Toasts, undo-send panel | none (opaque `slip`) | same | Legibility first; no blur behind moving content |
| Menus, alerts, tooltips, notifications | system | system | Native chrome |

No per-row blur, no material inside the list or the reader, no `backdrop-filter` in the shell.

### 4.10 Motion

| Token | Duration | Curve | CAMediaTimingFunction | Used for |
|---|---|---|---|---|
| `q.dur.quick` | 120 ms | `q.ease.leave` cubic-bezier(.4, 0, 1, 1) | (0.4, 0, 1, 1) | Toast out, tooltip-like reveals, cross-fades |
| `q.dur.standard` | 180 ms | `q.ease.settle` cubic-bezier(.2, .8, .2, 1) | (0.2, 0.8, 0.2, 1) | Toast in (rise 8 pt + fade), card expand/collapse, quoted text unfold, condensed-title cross-fade |
| `q.dur.standard` | 180 ms | `q.ease.glide` cubic-bezier(.4, 0, .2, 1) | (0.4, 0, 0.2, 1) | Search field width, quick-reply growth, rail show/hide |
| `q.dur.slow` | 240 ms | `q.ease.settle` | (0.2, 0.8, 0.2, 1) | Undo-send panel in, welcome → inbox |

Rules:

- **Never animated:** selection and `j`/`k`, opening a conversation (instant swap of a pre-rendered view), list scroll, rows arriving or leaving through sync, archive removing a row (the next row takes its place instantly), unread pips, badges and counts, star toggles, hover and press feedback, typing, focus rings.
- **Interruptible:** every animation starts from the current presentation value (`NSAnimationContext` with `allowsImplicitAnimation`, layer animations with `fromValue = presentation()`, CSS transitions). A second keypress during an expand reverses it from where it is.
- **No animation exceeds 240 ms.** Nothing loops except progress indicators; there is no skeleton shimmer.
- **Reduce Motion** (`accessibilityDisplayShouldReduceMotion`, `prefers-reduced-motion`): movement becomes a 120 ms cross-fade (toast, undo panel, search width); expand/collapse and rail show/hide are instant; the undo-send drain bar steps once per second instead of draining continuously.

### 4.11 Iconography

SF Symbols, **Regular** weight, **scale small** in rows and medium elsewhere. Sizes: 15 pt in the reader toolbar and window-level icon buttons, 14 pt inside text buttons and chips, 12 pt in rows and the sync line, 18–20 pt in the rail and settings tabs. Glyph colour is `ink2` at rest, `ink` on hover and press, `inkDisabled` when disabled; the starred star is `star` (`q.star`) **and** filled. Symbols in menus follow the macOS 26 menu icon convention (leading, `ink2`).

| Action | Symbol | Shortcut |
|---|---|---|
| Archive | `archivebox` | E |
| Move to Trash | `trash` | # |
| Star / Unstar | `star` / `star.fill` | S |
| Mark as Unread / Read | `envelope.badge` / `envelope.open` | U |
| Reply | `arrowshape.turn.up.left` | R |
| Reply All | `arrowshape.turn.up.left.2` | A |
| Forward | `arrowshape.turn.up.right` | F |
| New Message | custom `ss.nib` | C |
| Search | `magnifyingglass` | / or ⌘F |
| Undo | `arrow.uturn.backward` | Z or ⌘Z |
| Send | `paperplane` (button), `paperplane.fill` (panel) | ⌘↩ |
| Attach | `paperclip` | ⇧⌘A |
| Format | `textformat` | ⌘T |
| Open in composer | `arrow.up.left.and.arrow.down.right` | ⇧⌘R |
| Load images | `photo` | ⇧⌘I |
| Original colors | `circle.lefthalf.filled` | ⇧⌘O |
| Show / Hide quoted text | custom `ss.elide` | . (period, focused message) |
| Unified inbox | custom `ss.quire` | ⌘0 |
| Account N | monogram | ⌘1…⌘9 |
| Add account | `plus` | — |
| Settings | `gearshape` | ⌘, |
| Show / hide rail | `sidebar.left` | ⌃⌘S |
| Title menu | `chevron.down` (9 pt, semibold) | — |
| Popup | `chevron.up.chevron.down` | — |
| Pending sync | `arrow.triangle.2.circlepath` | — |
| Up to date | `checkmark` | — |
| Offline | `wifi.slash` | — |
| Retrying | `clock` | — |
| Error / sign-in | `exclamationmark.triangle` | — |
| Retry | `arrow.clockwise` | — |
| Remove (token, attachment) | `xmark` | ⌫ |
| File | `doc` (type-specific `doc.richtext`, `photo`, `tablecells`, `doc.zipper` when known) | — |
| More | `ellipsis` | — |
| Accounts / OAuth / General tabs | `person.crop.circle` / `key` / `gearshape` | — |
| Notifications | `bell` | — |

**Custom glyphs (four of the six allowed).** All are drawn on the stated grid at the stated stroke, round caps and joins, in `currentColor`. They scale with the symbol point size (grid units × pointSize / 16). Exact path data:

`ss.quire`: unified inbox (a gathering of letters). 16 × 16 grid, stroke 1.5, no fill.
```
M2.75 6.25h10.5a1 1 0 0 1 1 1v5.5a1 1 0 0 1-1 1H2.75a1 1 0 0 1-1-1v-5.5a1 1 0 0 1 1-1z
M2.1 7 8 10.6 13.9 7
M3.5 3.75h9
M5.25 1.5h5.5
```

`ss.nib`: new message (a pen nib at 45°). 16 × 16 grid, stroke 1.5, plus one filled circle (the vent).
```
M2.91 13.09 L4.32 7.01 C4.43 6.27 4.99 5.7 5.67 5.53 L8.64 4.68 L11.32 7.36 L10.47 10.33 C10.3 11.01 9.73 11.57 8.99 11.68 Z
M10.47 2.56 L13.44 5.53 L11.46 7.51 L8.49 4.54 Z
M2.91 13.09 L6.66 9.34
fill: circle cx 7.47 cy 8.53 r 0.9
```

`ss.elide`: quoted text, the editor's `[…]`. 16 × 16 grid, stroke 1.5, plus three filled dots.
```
M4.75 2.75h-2v10.5h2
M11.25 2.75h2v10.5h-2
fill: circles r 0.95 at (5.6, 10.6), (8, 10.6), (10.4, 10.6)
```

`ss.sparrow`: brand mark (welcome, app icon, About, empty inbox). 24 × 24 grid, filled, even-odd (the wing and the eye are holes).
```
M7.6 12.9 C8.3 9.9 10.9 7.6 14 7.2 C14.7 5 16.5 3.7 18.5 3.9 C20 4.1 21.1 5.1 21.5 6.3 L23.4 7.3 L21.5 8
C21.3 12.8 17.9 16.7 13.2 17.3 C11.6 17.5 10.1 17.3 8.8 16.8 L2.2 18.6 L3.4 16.9 L1.2 15.9 Z
M10.4 12.3 C12 10.7 14.3 10.1 16.4 10.4 C14.6 10.9 12.7 11.9 11.2 13.6 Z
M18.6 6.55 m-0.85 0 a0.85 0.85 0 1 0 1.7 0 a0.85 0.85 0 1 0 -1.7 0 Z
```

In AppKit, build each once as an `NSBezierPath` (or `CGPath`) in grid units, scale with an `NSAffineTransform`, and render into a template `NSImage` (`isTemplate = true`) cached per point size, so it tints like an SF Symbol. In the shell, inline the same paths as `<svg viewBox="0 0 16 16">`. Two slots remain unused on purpose.

### 4.12 Density

| | Standard (default) | Compact |
|---|---|---|
| Row height | 68 pt | 48 pt |
| Lines | sender · time / subject / snippet | sender · time / subject — snippet |
| Avatar | 30 pt face in a 38 pt box with account ring | none |
| Account mark | 1.5 pt ring around the avatar (unified views) | 6 pt square before the time |
| Text column | x = 68 | x = 24 |
| Rows visible at 800 pt | about 9 | about 13 |

The reader has one density. Generous is the point.

### 4.13 Voice and microcopy

- **Plain, short, calm.** Sentence case everywhere except menu items and buttons, which follow macOS title case ("Mark as Unread", "Keep Writing"). No exclamation marks. No "Oops", no "Uh-oh", no emoji.
- **Verbs on buttons.** "Send", "Discard", "Reconnect", "Load images". Never "OK" when a verb exists.
- **Past tense plus one remedy** in toasts: "Archived · Undo", "Moved to Trash · Undo", "Marked as unread · Undo". Only actions that take a row out of view get a toast; starring does not.
- **Errors say what happened and what happens next:** "Couldn't reach Gmail · retrying in 30 s", "Sign in required · Reconnect", "Couldn't send · Open draft". Never blame the user.
- **The separator is the middle dot with spaces ( · ).** The ellipsis is the single character (…), used for actions that open something ("Add Account…") and for ongoing work ("Sending…").
- **Numbers:** thousands separators from the locale ("3,412 of 8,120"); units with a thin space where the locale allows ("240 KB", "4 s").
- **Times** follow the system 12/24-hour setting: today "23:39"; yesterday "Yesterday" (rows) or "Yesterday 23:39" (reader); this week "Tue"; this year "30 Oct"; older "30 Oct 2025".
- **Empty states** are one serif sentence and one hint: "Nothing left to read." / "New mail will land here."
- **Privacy copy** is literal: "Your mail is stored on this Mac and travels only between this Mac and Google or Microsoft."

### 4.14 Accessibility summary

- Contrast: every text pair ≥ 4.5:1, every essential UI pair ≥ 3:1, in all four modes (§6).
- Every state has a non-colour cue (table below).
- Full keyboard operation; every focusable element shows the 2 pt focus ring, except list rows and rail items, which show focus through the selected wash and margin rule (the native Mac list convention).
- VoiceOver: rows read "Unread. Priya Raman. Lisbon in March? Booked the flat… 22:10. 3 messages. Starred. Personal account." Pending rows add "Syncing". Custom glyph buttons carry the action name as `accessibilityLabel`.
- Reduce Motion, Reduce Transparency and Increase Contrast are each handled (§3, §4.9, §4.10).
- Hit targets: at least 28 × 28 pt for pointer targets (rail items 44 × 44, list rows full width).

| State | Colour cue | Non-colour cue |
|---|---|---|
| Unread | Iron Gall pip | the pip's presence, Semibold sender and subject |
| Selected | `selWash` | 3 pt margin rule |
| Focused list vs idle | Iron Gall vs `ink3` rule | wash change and rule colour, plus window key state |
| Starred | `q.star` | filled star vs outline |
| Pending sync | `ink3` glyph | `arrow.triangle.2.circlepath` glyph, VoiceOver "Syncing" |
| Other category | none | "Other" text tag |
| Account | ring ink | kicker text, tooltip, VoiceOver, square mark in compact |
| Invalid address | Danger wash and border | warning glyph inside the token |
| Error | Danger | glyph and wording |
| Toggle on | Iron Gall track | knob position |
| Active tab | `ink` text | 2 pt underline, Semibold |

---
## 5. Components

Conventions: metrics in points at 1×; x/y measured from the component's top-leading corner; "row height" includes the bottom hairline. Unless a component says otherwise, its states are: **hover** = `hover` wash, glyph and text to `ink`, no animation; **pressed** = `pressed` wash; **focused** = 2 pt `focus` ring + 1 pt gap; **disabled** = `inkDisabled` text and glyph, no wash, no pointer feedback; **inactive window** = Iron Gall marks become `ink3`, primary buttons draw as secondary.

### 5.1 App window and title bar

Anatomy: rail (76) · list pane (364 default, 300–480, user-resizable, persisted) · reader (flexible, min 520). Minimum window 960 × 600; default 1280 × 800.

| Part | Metric |
|---|---|
| Title-bar zone | top 52 pt of every pane; window-drag area; no visible title |
| Traffic lights | system position (origin 20, 20), always over the rail; in minimal mode the list masthead starts at x = 84 |
| Pane dividers | hairline `rule`, 1 pt hit area widened to 6 pt by `NSSplitView` |
| Background | rail `spine` (material), list `paper`, reader `canvas` |
| Full screen | layout unchanged, title-bar zone still 52 pt |

States: key window (traffic lights coloured, Iron Gall marks active); inactive window (system grey lights, selection idle, tab underline `ink3`, primary buttons neutral).

### 5.2 Account rail

Anatomy, top to bottom: title-bar zone (52) · unified inbox tile · 20 pt hairline divider · account tiles · flexible space · Add account · Settings.

| Part | Metric |
|---|---|
| Width | 76 pt; hidden in minimal mode (⌃⌘S, View › Hide Account Rail) |
| Tile | 38 × 38 visual, 44 × 44 hit, centred at x = 38 |
| Unified tile | first tile top at y = 62; `ss.quire` 18 pt; radius 11 |
| Divider | 20 × hairline at y = 116, centred |
| Account tiles | first at y = 130, pitch 50; avatar face 30 pt with 1.5 pt gap and 1.5 pt account-ink ring (38 pt overall); monogram New York Semibold 12.5 pt, or the account photo |
| Badge | count badge (§5.27), top −5, trailing −8 relative to the tile, 2 pt `spine` cut-out ring |
| Add / Settings | 28 × 28 icon buttons, `plus` / `gearshape` 15 pt, at bottom − 92 and bottom − 52 |
| Margin rule | 3 × 24 pt at x = 0, centred on the selected tile |
| Overflow | more than 9 accounts scroll inside the rail; no scroller shown unless hovered |

States:

| State | Unified tile | Account tile |
|---|---|---|
| Rest | glyph `ink2`, no fill | avatar + ring |
| Hover | 44 pt `hover` wash, radius 12 | same |
| Pressed | 44 pt `pressed` wash | same |
| Selected | `raised` fill, `rule` edge, e1, glyph `ink`, margin rule `selRule` | margin rule `selRule` |
| Selected, rail not focused / window inactive | margin rule `selRuleIdle` | same |
| Focused (Tab into rail) | the selected tile shows the 2 pt focus ring outside its ring, 2 pt gap | same |
| Unread | Iron Gall count badge | same |
| New mail while rail is collapsed to minimal mode | — | 8 pt Iron Gall dot on the list masthead |
| Needs sign-in | — | Danger badge with "!" replaces the count; tooltip "Sign in required" |
| Syncing first time | — | 12 pt spinner replaces the badge |
| Drag to reorder | tile lifts with e2, others shift without animation | same |

Tooltips: "All Inboxes ⌘0", "Contoso · alex@contoso.test ⌘1".

### 5.3 List header

Height 92 = row 1 (52, title-bar zone) + row 2 (40). Bottom hairline `rule` spanning the pane.

| Part | Metric |
|---|---|
| Masthead | x 16, vertically centred on y 26 (aligned with the traffic lights); `masthead` (New York 20/24 Semibold); followed 6 pt later by `chevron.down` 9 pt Semibold `ink2`. Hit area: text + chevron + 6 pt padding, radius 6 |
| Account suffix | when narrowed to one account: " · alex@contoso.test" in `snippet` `ink3`, truncates first |
| Compose | 28 × 28 icon button, `ss.nib` 18 pt, trailing 12, top 12 |
| Tabs (Inbox only) | row 2, x 16, gap 18 (§5.5) |
| Search | row 2, trailing 12, top 58, 168 × 26 (§5.6); full width (x 12…352) in views without tabs |

States: masthead hover = `hover` wash behind text and chevron; pressed = `pressed`; open = title menu (§5.4); focused = focus ring around the hit area.

### 5.4 Title menu

A system `NSMenu` popped from the masthead (left-aligned to the masthead text, 4 pt below). Items:

| Item | Symbol | Shortcut column |
|---|---|---|
| Inbox | `tray` | G I |
| Starred | `star` | G S |
| Sent | `paperplane` | G T |
| Drafts | `doc` | G D |
| Trash | `trash` | G # |
| — separator — | | |
| All Mail | `archivebox` | G A |

The current view has a checkmark. G-sequences are shown as two capitals separated by a space, right-aligned with a tab stop in `ink3` (an attributed title, since `keyEquivalent` cannot express a sequence). States are the system's (highlight in the system menu selection colour).

### 5.5 Segmented filter (All · Focused · Other)

Editorial section tabs instead of a bezelled segmented control: they read as navigation, and the underline gives a ≥ 3:1 state cue that a white-on-grey thumb cannot.

| Part | Metric |
|---|---|
| Container | row 2 of the header, height 40, tabs aligned to the bottom hairline |
| Label | `label` (SF Pro 12 Medium); selected is Semibold 600 |
| Gap | 18 pt; hit area = label ± 6 pt, full row height |
| Underline | 2 pt `ink`, width = label width, overlapping the header hairline |

| State | Label | Underline |
|---|---|---|
| Rest | `ink2` | none |
| Hover | `ink` | none |
| Pressed | `ink` | none |
| Selected | `ink`, Semibold | 2 pt `ink` |
| Selected, inactive window | `ink` | 2 pt `ink3` |
| Focused | focus ring around the label (radius 3, 2 pt gap) | unchanged |
| Disabled (during first sync, Focused not yet known) | `inkDisabled` | none |

Shown only in Inbox. Keyboard: ⌥1 / ⌥2 / ⌥3, or ← → when focused. Focused maps to Gmail Primary / Outlook Focused.

### 5.6 Search field

| Part | Metric |
|---|---|
| Size | 168 × 26 at rest; expands to the full row (x 12…352) when focused, covering the tabs (180 ms glide; Reduce Motion: cross-fade) |
| Shape | radius 7; rest fill `fill`; focused fill `sheet` with 1 pt `focus` inner border and a 3 pt `focus` @ 35 % halo |
| Leading glyph | `magnifyingglass` 12 pt `ink3`, x 8 |
| Placeholder | "Search" (`body`, `ink3`); in other views "Search Starred" etc. |
| Trailing | keycap "/" when empty; clear button (18 pt circle, `fill`, `xmark` 9 pt) when there is text |
| Result count | while results show, "38 results" in `meta` `ink3` replaces the keycap |

States: rest, hover (fill → `pressed` wash), focused, typing, searching (12 pt spinner replaces the magnifier while the first page loads, only if it takes more than 150 ms), no results (empty state §5.9), disabled (no accounts: `fill`, `inkDisabled`). Esc clears; a second Esc returns focus to the list.

### 5.7 Conversation row

Fixed height **68 pt** (compact 48). Drawn by hand in `layout()`/`draw(_:)`; no Auto Layout, no shadow, no blur, no per-row animation, no layer per sub-element beyond the labels and avatar image.

Anatomy (standard density, list width 364):

| Element | Frame (x, y, w, h) | Style |
|---|---|---|
| Margin rule (selected) | 0, 8, 3, 52 | `selRule` / `selRuleIdle`, radius 0 2 2 0 |
| Unread pip | 7, 14, 7, 7 (centred on the sender line) | `accent` circle |
| Avatar box | 20, 11, 38, 38: face 30 at inset 4; 1.5 gap; 1.5 ring (outer edge at inset 1) | face tint, New York monogram 12.5 pt, ring = account ink (unified views only) |
| Sender line | 68, 10, to time − 8, 16 | `sender` 13/16; Semibold when unread; participants joined by ", " with the user as "me" |
| Time | trailing 16, baseline-aligned with sender | `meta` 11/14, tabular, `ink3`; preceded by the pending glyph when pending |
| Other tag | before the time, 6 pt gap | `tag` (§5.27) "Other", only in Inbox › All |
| Subject line | 68, 27, to glyph cluster − 6, 18 | `subject` New York 14/18; Semibold when unread |
| Glyph cluster | trailing 16, centred on the subject line, gap 5, fixed order from the trailing edge: star, attachment, count | star 12 pt filled `star`; `paperclip` 12 pt `ink2`; count badge 16 pt high, neutral |
| Snippet | 68, 46, to trailing 16, 15 | `snippet` 12/15 `ink2` |
| Separator | 68 → trailing edge, bottom | hairline `rule`; hidden on and next to the selected row |

States:

| State | Fill | Marks | Notes |
|---|---|---|---|
| Read | `paper` | none | Regular weights |
| Unread | `paper` | pip | Semibold sender and subject |
| Hover | `paper` + `hover` | — | no animation; no hover actions in rows (keyboard and context menu instead) |
| Pressed | becomes selected on mouse-down | — | |
| Selected, list focused | `selWash` | margin rule `selRule` | text unchanged; pip stays (≥ 3:1 on wash) |
| Selected, focus elsewhere or window inactive | `selWashIdle` | margin rule `selRuleIdle` | |
| Multi-selection | each selected row as above | | ⇧-click, ⌘-click, ⇧J/⇧K |
| Starred | — | filled `star` glyph | VoiceOver "Starred" |
| Has attachment | — | `paperclip` | |
| Count | — | neutral count badge, shown when ≥ 2 | |
| Pending sync | — | `arrow.triangle.2.circlepath` 12 pt `ink3` before the time | the row keeps full contrast; it never fades |
| Other (Inbox › All only) | — | "Other" tag | Focused rows show nothing |
| Account (unified views) | — | avatar ring in the account ink | single-account views drop the ring; face size unchanged |
| Drafts view | — | sender line reads "Draft to Ben Carter" in `ink2` | |
| Sent view | — | sender line reads "To Ben Carter" | |

Compact density (48 pt): pip 7, 12; sender line 24, 7; time trailing 16 with a 6 pt account square before it (radius 1.5); line 2 at 24, 25: subject in New York 14, then " — " and the snippet in `snippet` `ink2` on the same line; glyph cluster as above; separator from x 24; margin rule 0, 6, 3, 36.

Performance contract: all attributed strings built once per (conversation id, version, appearance, contrast, text size) in `RowContentCache`; avatar rendered off the main thread and cached by (initials, tint, size, ring ink, appearance); selection changes redraw only the fill and margin rule.

### 5.8 Running heads (date dividers)

Group rows by local day in every view and in search results: Today, Yesterday, Earlier this week, Last week, then month names ("October"), then "October 2025" for earlier years.

| Part | Metric |
|---|---|
| Height | 26 pt (a group row; `heightOfRow` returns 26 for it, 68 for conversations) |
| Label | x 20, baseline at y 19; `runningHead` (SF Pro 10/12 Semibold, uppercase, +0.8) `ink3` |
| Rule | from label end + 10 to trailing 16, hairline `rule`, at the label's x-height centre |

Not sticky (no floating group rows: they force extra compositing during scroll). Skipped by `j`/`k`, not selectable, not focusable; VoiceOver reads them as headings.

### 5.9 Empty states

Centred in the pane, max width 300, no illustration except the sparrow on inbox zero.

| Case | Glyph | Line 1 (New York Italic 17/22 `ink`) | Line 2 (`snippet` 12/16 `ink3`) |
|---|---|---|---|
| Inbox zero | `ss.sparrow` 30 pt `ink3`, 4 pt above | Nothing left to read. | New mail will land here. |
| Empty Starred | — | No starred conversations | Press S to star one. |
| Empty Drafts / Sent / Trash | — | Nothing in Drafts | Drafts you start here are kept on this Mac. |
| Search, no results | — | No results for "lisbon flat" | Search looks at subjects, people and message text. |
| Reader, nothing selected | — | No conversation selected | keycaps J K to move · ↩ to open |
| No accounts | — | (Welcome screen, §5.36) | |
| Offline, nothing cached | `wifi.slash` 20 pt `ink3` | You're offline | Mail will appear when you reconnect. |

### 5.10 Skeleton and loading

Shown only on the very first launch per account, before the first page lands (normally under 500 ms; the skeleton appears only after 300 ms).

| Part | Metric |
|---|---|
| Skeleton row | 68 pt; circle 30 at (24, 15); bars at the sender (120 × 9 at 68, 14), time (28 × 9, trailing 16), subject (190 × 10 at 68, 32), snippet (240 × 8 at 68, 50); widths vary per row by ±30 % from a fixed table |
| Colour | `fill`, radius 3 |
| Motion | none. No shimmer. |

Loading a message body that is not cached: the sheet shows its header immediately and three body bars (`fill`, 100 %, 92 %, 60 % width, 10 pt high, 14 pt apart) in place of the text.

### 5.11 Sync status line

Height 28 at the bottom of the list pane, top hairline `rule`, padding 0 16, gap 6. Text `meta` `ink3` with the lead phrase in Medium `ink2`.

| State | Glyph | Copy | Extras |
|---|---|---|---|
| Up to date | `checkmark` | **Up to date** · 3 accounts · checked 14:02 | — |
| Downloading | 10 pt spinner | **Downloading mail** · Contoso · 3,412 of 8,120 | 2 pt Iron Gall progress hairline along the top edge |
| Sending | 10 pt spinner | **Sending 1 message** | — |
| Offline | `wifi.slash` | **Offline** · changes will sync when you're back | — |
| Slow / retrying | `clock` in `warning` | **Gmail is slow to respond** · retrying in 30 s | — |
| Sign-in required | `exclamationmark.triangle` in `danger` | **Sign in required** · personal account (whole line in `danger`) | trailing link button "Reconnect" (`accent`, Semibold) |
| Error | `exclamationmark.triangle` in `danger` | **Couldn't sync Contoso** · details | "Retry" |

The line is always present (it is the list's footer) so the list never changes height. Clicking it opens Settings › Accounts.

### 5.12 Reader header and toolbar

**Toolbar** (title-bar zone, 52 pt, transparent over `canvas`): trailing group of 28 × 28 icon buttons, 15 pt symbols, 2 pt apart: Star · Archive · Trash, a 14 pt gap, then Reply · Reply All · Forward. Trailing inset 16. No hairline until content scrolls under it; then a hairline `rule` appears at its bottom (no animation).

**Headline block** (inside the web shell, scrolls with the conversation), left-aligned to the reading column:

| Part | Metric |
|---|---|
| Kicker | top 10 below the toolbar; `runningHead` `ink3`: account ink dot (7 pt circle), account name, 3 pt dot separator, "4 messages"; gap 8. In single-account setups the account part is omitted |
| Headline | 8 below; `headline` New York 26/32 Semibold, −0.4; max 3 lines then tail truncation; selectable |
| Participants | 6 below; `body` 13/18 `ink2`; up to 4 names then "+3" |
| Gap to stack | 20 |

**Condensed title.** When the headline scrolls out, the toolbar shows the subject at its leading edge (x 20) in `title` (SF Pro 15/20 Semibold), cross-faded in 180 ms (Reduce Motion: instant). The shell posts the scroll threshold once; no per-frame messages.

Icon button states (toolbar and elsewhere):

| State | Glyph | Fill |
|---|---|---|
| Rest | `ink2` | none |
| Hover | `ink` | `hover`, radius 6 |
| Pressed | `ink` | `pressed` |
| Focused | `ink2` | none, focus ring |
| On (starred) | `star.fill` in `star` | none |
| Disabled (e.g. Reply All with one participant) | `inkDisabled` | none |
| Loading | 12 pt spinner replaces the glyph | none |

Tooltips name the action and key ("Archive  E").

### 5.13 Message stack (collapsed messages)

All collapsed messages between expanded ones form one stack: a single `sheet` with a hairline `rule` edge, radius 8, no shadow. Collapsed rows are 44 pt tall and separated by hairlines.

| Part | Metric |
|---|---|
| Row padding | 0 16; gap 10 |
| Avatar | 24 pt monogram (no ring) |
| Name | `body` Medium 13/16 `ink`, fixed column 96 pt (truncates); Semibold when unread |
| Snippet | `body` 13/16 `ink2`, fills, tail-truncated |
| Date | `meta` 11/14 tabular `ink3`, trailing 16 |
| Unread pip | 6 pt at (5, 19) |

States: rest; hover (`hover` wash across the row; first and last rows clip to the stack radius); pressed; focused (N/P, or Tab: 2 pt `focus` inset ring following the row, with the stack radius on end rows); unread (pip + Semibold). Click or ↩ expands the message in place (180 ms height animation, settle curve; Reduce Motion: instant). A stack of more than 6 collapses its middle into one row: "4 more messages" in `label` `ink2`, centred.

### 5.14 Message sheet (expanded) and message header

| Part | Metric |
|---|---|
| Sheet | `sheet`, radius 8, hairline `rule` edge + e1; padding 22 28 14; 12 pt below the stack (or the previous sheet) |
| Header | avatar 36 (no ring) · 12 gap · who block · date |
| Name line | `body` Semibold 14/18 `ink`; the address appears after the name on hover or focus (`meta` 12, `ink3`, 6 pt gap); an unread message shows a 7 pt pip before the name |
| Recipients | `snippet` 12/16 `ink2`: "to me · cc Tom Hughes" (click to expand to full addresses) |
| Date | `snippet` 12/16 tabular `ink3`, trailing; "Today 09:12", "Yesterday 23:39", "Fri 30 Oct" |
| Header actions | on hover or focus only, before the date: 22 pt icon buttons (Star, Reply, More; plus Original colors in dark mode for HTML mail) |
| Body | 18 below the header. Plain and unstyled mail: `reading` (New York 15/24, Reading-font setting), indented 48 to the name column, measure 576 pt. HTML mail with its own layout: full sheet width (624 pt) so 600 px newsletters fit unscaled |
| Quoted-text toggle | 12 below the body, at the 48 pt indent (§5.15) |
| Attachments | 16 below, chips at the 48 pt indent, wrap with 8 pt gaps (§5.17) |
| Footer | 16 below, hairline above, 10 pt padding; ghost buttons Reply · Reply all · Forward (§5.23), at the 48 pt indent |

States: rest; hover (header actions appear, address appears); focused (N/P or Tab: 2 pt `focus` ring with a 2 pt `canvas` gap, around the whole sheet); unread (pip); loading body (skeleton bars §5.10); body failed ("Couldn't load this message · Retry" in `danger` with glyph, replacing the body); pending send (sheet at `ink` but the date reads "Sending…" with a 12 pt spinner).

Dark mode and HTML mail: bodies render with `color-scheme: light dark`. If a body declares its own background, it renders on a white inset (radius 4) inside the dark sheet; "Original colors" (button and ⇧⌘O) toggles the sender's colours for that message.

### 5.15 Quoted-text toggle (the elision mark)

| Part | Metric |
|---|---|
| Shape | 24 pt high, radius 6, padding 0 9 0 6, gap 6 |
| Glyph | `ss.elide` 14 pt |
| Label | `label` (12 Medium): "Show quoted text" / "Hide quoted text" |

| State | Fill | Text / glyph |
|---|---|---|
| Rest (folded) | `fill` | `ink2` |
| Hover | `fill` + `hover` | `ink` |
| Pressed | `fill` + `pressed` | `ink` |
| On (unfolded) | `accentWash` | `accent`, label "Hide quoted text" |
| Focused | focus ring | |

The state change is carried by the label. In the composer the folded original is a glyph-only 22 pt chip followed by "Ben Carter wrote on Yesterday 23:39" in `snippet` `ink3`; clicking either unfolds it. Unfolding animates the quote height in 180 ms (Reduce Motion: instant).

### 5.16 Remote-images banner and Original colors

The first element of a body that has hidden remote images.

| Part | Metric |
|---|---|
| Banner | 32 pt, radius 6, padding 0 6 0 10, gap 8, fill `fill` (neutral: privacy is not a warning) |
| Glyph | `photo` 14 pt `ink2` |
| Copy | "3 remote images hidden to protect your privacy." (`snippet` 12/16 `ink`); shortens to "3 remote images hidden." below 420 pt |
| Action | link button "Load images" (`label`, `accent`), 22 pt hit, radius 5; menu on long-press: "Always load from ben@contoso.test" |
| Dismissal | disappears when images load; no close button |

States: rest; action hover (`hover` behind the link); action pressed; action focused (ring); loading (12 pt spinner replaces the glyph, copy "Loading 3 images…"); partial failure ("2 images couldn't load" in `ink2`, glyph `exclamationmark.triangle` in `warning`).

**Styles banner** (warning wash) for messages whose colours were neutralised in dark mode: "This message uses its own colours." with the action "Original colors" in `ink` Semibold. Shown once per message, only in dark mode.

### 5.17 Attachment chip

| Part | Metric |
|---|---|
| Size | 44 pt high, min 196, max 264 wide; radius 8; padding 0 14 0 8; gap 10 |
| Edge / fill | inset hairline `rule`, fill `sheet` |
| Type tile | 28 × 28, radius 5, `fill`, symbol 15 pt `ink2` (`doc`, `doc.richtext`, `photo`, `tablecells`, `doc.zipper`, `film`) or a 28 pt Quick Look thumbnail when cached |
| Name | `label` 12/15 Medium `ink`, middle-truncated to keep the extension |
| Meta | `meta` 11/14 `ink3`: "PDF · 240 KB" |

| State | Change |
|---|---|
| Hover | fill + `hover`, edge `ruleStrong`, meta reads "Space to Quick Look" |
| Pressed | fill + `pressed` |
| Focused | focus ring (1 pt gap) |
| Downloading | meta replaced by a 2 pt progress bar (120 pt, `rule` track, `accent` fill) |
| Error | tile glyph `exclamationmark.triangle` in `danger`; meta "Couldn't download · Retry" in `danger` with "Retry" in `accent` Semibold |
| Dragging out | chip lifts with e2 (the only shadowed chip state) |

Click opens Quick Look; double-click opens with the default app; context menu: Quick Look, Open, Save to Downloads, Save As…, Copy.

### 5.18 Quick reply bar

Docked to the bottom of the reader, outside the scroll view.

| Part | Metric |
|---|---|
| Bar | 60 pt at rest, `paper`, top hairline `rule`; grows with content to 160 pt (6 lines), then scrolls |
| Field | aligned to the reading column (x = column x, width = column width, 680 max); 38 pt at rest; radius 8; `sheet`; 1 pt `ruleStrong` inner border |
| Leading | 20 pt monogram of the replying account (with ring in unified views), x 12 |
| Placeholder | "Reply to Ben Carter…" (`writing` 14/21, `ink3`) |
| Trailing (rest) | keycap "R"; send icon button 28 pt, `paperplane`, `inkDisabled` |
| Focused | field border 1 pt `focus` + 3 pt `focus` @ 35 % halo; a 28 pt tool row appears under the text: Reply / Reply all (small ghost toggle pair; the active one shows its glyph in `ink`), Attach, Open in composer (⇧⌘R), then keycap "⌘↩" and a small primary "Send" |
| Sending | field shows a spinner and "Sending in 4 s…" with a small secondary "Undo" (mirrors the undo-send panel) |
| Sent | field returns to rest; a toast "Sent · Undo" is not shown (the undo panel already covered it) |

States: rest, hover (border `ink3`), focused-empty, focused-with-text, sending, error ("Couldn't send · Open draft" inline in `danger`), disabled (no reply possible, e.g. a draft is open: field `fill`, placeholder "Reply in the composer").

### 5.19 Composer window

640 × 600 default (min 520 × 420), standard titled window, title = subject (or "New Message").

| Part | Metric |
|---|---|
| Title bar | 28 pt, `paper`, system title |
| Field rows | 36 pt each (subject 42), `paper`; label column 56 pt right-aligned at x 16 (`snippet` 12, `ink3`: From, To, Cc, Bcc, Subject); value from x 84; hairlines between rows from x 16 to trailing 16 |
| From | borderless popup (§5.26): 7 pt account ink dot, "Alex Morgan <alex@contoso.test>", `chevron.up.chevron.down`; shown only with 2+ accounts |
| To / Cc / Bcc | token fields (§5.20); trailing "Cc" "Bcc" small ghost buttons in the To row until revealed |
| Subject | New York 15/20 (`composeSubject`), `ink` |
| Body | `sheet`, padding 20 24 0 84 (text starts on the value column); `writing` 14/21 |
| Folded original | the elision chip + "Ben Carter wrote on Yesterday 23:39" (§5.15) |
| Attachment strip | §5.21 |
| Bottom bar | 52 pt, `paper`, top hairline; Send (primary, with `paperplane` 14), Attach (`paperclip`), Format (`textformat`) 28 pt icon buttons; trailing status "Draft saved" with `checkmark` 12 in `meta` `ink3` |

States: editing; sending (Send shows spinner "Sending…" and the window closes into the undo-send panel); send failed (an alert sheet, §5.31); offline (bottom bar status "Will send when you're back online"); inactive window (Send draws as secondary).

### 5.20 Address token

| Part | Metric |
|---|---|
| Shape | 22 pt pill, padding 0 9, gap 4 between tokens, `body` 13/16 |
| Content | display name, or the address if no name; tooltip shows the full address |

| State | Fill | Text |
|---|---|---|
| Rest | `fill` | `ink` |
| Hover | `pressed` wash | `ink` |
| Selected (click or ← →) | `accent` | `onAccent` |
| Focused field, token being edited | token turns back into text with the caret | |
| Invalid | `dangerWash` + 1 pt `danger` inner border | `danger`, leading `exclamationmark.triangle` 10 pt |
| Disabled (sending) | `fill` | `inkDisabled` |

⌫ removes the selected token; ↩ or double-click edits it; a context menu offers Copy Address, Remove, Edit.

### 5.21 Attachment strip

48 pt band above the composer's bottom bar, `sheet`, top hairline, padding 0 16, gap 8, horizontally scrollable. Appears only when there are attachments. Chips are 30 pt: radius 6, inset hairline `rule`, type glyph 14 `ink2`, name `label` 12 Medium `ink`, size `meta` `ink3`, remove button 18 pt circle (`xmark` 12, `ink3`; hover `hover` fill and `ink`). Uploading: a 2 pt progress line along the chip's bottom inside edge. Error: name in `danger` with glyph; tooltip names the problem ("Too large for Microsoft 365: 150 MB limit").

### 5.22 Send button

A primary button (§5.23) with `paperplane` 14 pt and the label "Send"; regular 28 pt in the composer, small 22 pt in quick reply.

| State | Look |
|---|---|
| Rest | `accent` fill, `onAccent` label |
| Hover / Pressed | `accentHover` / `accentPressed` |
| Focused | focus ring with 1 pt `paper` gap |
| Disabled (no valid recipient) | `fill`, `inkDisabled`; tooltip "Add a recipient" or "Fix the address priya@contoso" |
| Sending | spinner + "Sending…" |
| Inactive window | secondary look |

### 5.23 Buttons

| Variant | Fill | Label | Edge |
|---|---|---|---|
| Primary | `accent` | `onAccent`, Semibold | none |
| Secondary | `raised` | `ink`, Medium | 1 pt `ruleStrong` inset + 1 px drop (0 1 1 rgba(0,0,0,.04)) |
| Ghost / tertiary | none | `ink2`, Medium (with optional leading glyph) | none |
| Destructive | `dangerFill` | `onDanger`, Semibold | none |
| Icon | none | glyph `ink2` | none |
| Link | none | `accent`, Medium | none |

| Size | Height | Padding | Radius | Type | Glyph |
|---|---|---|---|---|---|
| Small | 22 | 0 9 | 5 | SF Pro 12 | 12 |
| Regular | 28 | 0 12 | 6 | SF Pro 13 | 14 |
| Large | 36 | 0 16 | 8 | SF Pro 14 | 18 |
| Icon | 22 / 28 square | — | 5 / 6 | — | 14 / 15 |

| State | Primary | Secondary | Ghost / Icon | Destructive |
|---|---|---|---|---|
| Hover | `accentHover` | + `hover` | `hover` fill, `ink` | 92 % brightness |
| Pressed | `accentPressed` | + `pressed` | `pressed` fill, `ink` | 84 % brightness |
| Focused | 2 pt ring, 1 pt gap | same | same | same |
| Disabled | `fill`, `inkDisabled` | `fill`, `inkDisabled`, no edge | `inkDisabled`, no fill | `fill`, `inkDisabled` |
| Loading | spinner (12) replaces the glyph, label becomes the gerund ("Sending…"), width kept | same | same | same |
| Inactive window | secondary look | unchanged | unchanged | unchanged |

One primary per window or sheet. Destructive buttons are never the default button.

### 5.24 Text field

28 pt, radius 6, `sheet`, 1 pt `ruleStrong` inner border, padding 0 8, `body` 13/16; placeholder `ink3`. OAuth IDs and secrets use `mono` (SF Mono 12). Labels sit above the field (`snippet` 12 `ink2`, 6 pt gap) in Settings, beside it in forms with right-aligned labels.

| State | Look |
|---|---|
| Hover | border `ink3` |
| Focused | border 1 pt `focus` + 3 pt `focus` @ 35 % halo; caret `accent` |
| Filled | as rest |
| Error | border 1.5 pt `danger`; help line below in `meta` `danger` with `exclamationmark.triangle` 12: "That doesn't look like a Google client ID." |
| Disabled | `fill`, no border, `inkDisabled` |
| Secure | dots in `mono` with 2 pt tracking; "Show" reveal button (eye) only on hover |

### 5.25 Checkbox, radio and toggle

| Control | Metric | Off | On | Mixed |
|---|---|---|---|---|
| Checkbox | 14 pt, radius 4 | `sheet` + 1 pt `ruleStrong` | `accent` fill + `checkmark` 10 pt `onAccent` | `accent` + 8 × 2 bar |
| Radio | 14 pt circle | `sheet` + 1 pt `ruleStrong` | `accent` + 6 pt `onAccent` dot | — |
| Toggle | 30 × 18 track, 14 pt knob, 2 pt inset | track `fill` + `ruleStrong` edge, knob left | track `accent`, knob right | — |

Knob: `raised` with 0.5 pt edge and `0 1 2 rgba(0,0,0,.18)` (the only control shadow; static). Focused: ring around the box/track with 1 pt gap. Disabled: 45 % opacity on the control, label `inkDisabled`. Labels are `body` 13 `ink`, 8 pt from the control. Toggles are for settings that apply at once; checkboxes for options in a form. In SwiftUI use `.toggleStyle(.switch)` / `.checkbox` with `.tint(Color.qAccent)`; the custom drawing applies to the AppKit shell only.

### 5.26 Popup button

24 pt, radius 6, `raised`, 1 pt `ruleStrong` inset, padding 0 6 0 9, `body` 13 `ink`, trailing `chevron.up.chevron.down` 12 `ink2`. Borderless variant (composer From): no fill or edge until hover. States: hover (+ `hover`), pressed (+ `pressed`, menu opens), focused (ring), disabled (`fill`, `inkDisabled`, no edge). The menu itself is a system `NSMenu`.

### 5.27 Badges and tags

| Badge | Metric | Colours |
|---|---|---|
| Unread count | 16 pt high, min 16 wide, padding 0 5, pill; `badge` (SF Pro Rounded 11 Semibold, tabular); 99+ cap | `accent` / `onAccent`; 2 pt cut-out ring in the surface colour when overlapping an avatar |
| Message count (rows) | 16 pt, min 18 | `fill` / `ink2` |
| Dot | 8 pt circle, 2 pt cut-out | `accent` |
| Needs attention | 16 pt circle, "!" | `dangerFill` / `onDanger` |
| Tag | 14 pt high, padding 0 4, radius 3, 1 pt `ruleStrong` inset; SF Pro 9 Semibold uppercase +0.6 | text `ink3` ("Other"), `ink2` (provider: "Gmail", "Microsoft 365") |

Badges do not animate when counts change.

### 5.28 Avatar

| Size | Use | Monogram size |
|---|---|---|
| 16 | menus, notifications grouping | 7 |
| 20 | quick reply, composer From (optional) | 8.5 |
| 24 | collapsed message rows | 10 |
| 30 (+ ring = 38) | list rows, rail, settings accounts | 12.5 |
| 36 | message header | 15 |
| 48 | contact popover | 20 |
| 64 | welcome (account added), About | 27 |

Face = avatar tint (§4.3) or photo; initials New York Semibold, max 2 letters, from the display name (first + last word), else the first letter of the address; non-letter names ("[sparrow-sync]") use the first alphanumeric. **Account ring**: 1.5 pt gap in the surface colour + 1.5 pt ring in the account ink, drawn outside the face; unified views only. Groups (several senders) show the most recent sender. States: none (avatars are not interactive in rows); in the reader, hover shows the address tooltip.

### 5.29 Toast

| Part | Metric |
|---|---|
| Slip | 34 pt high, radius 8, `slip`, e2; padding 0 6 0 14; gap 10 |
| Message | `body` Medium 13 `onSlip`: "Archived", "Moved to Trash", "Marked as unread" |
| Divider | 1 × 16, `onSlip` @ 25 % |
| Action | "Undo" Semibold `onSlip` + keycap "Z" (`onSlip2`, 1 pt `onSlip` @ 30 % edge), 24 pt hit, radius 5 |
| Placement | bottom centre of the list pane, 16 pt above the sync line; one at a time (a new toast replaces the old one without animation) |
| Timing | in: 180 ms rise 8 pt + fade (settle); stays 4 s, paused while hovered or while the pointer is over the list footer; out: 120 ms fade (leave). Reduce Motion: 120 ms fade both ways |

States: action hover (`onSlip` @ 14 % wash), action pressed (@ 22 %), action focused (2 pt ring in `onSlip`), error variant ("Couldn't send" with `exclamationmark.triangle` in `onSlip2`, action "Open draft"). Z works while the toast is visible and for 10 s after (⌘Z always).

### 5.30 Undo-send panel

| Part | Metric |
|---|---|
| Panel | non-activating floating `NSPanel`, 280 × 48, radius 12, `slip`, e3; bottom-right of the active screen's visible frame, 20 pt inset; stacks upward with 8 pt gaps for several sends |
| Content | `paperplane.fill` 15 `onSlip2` · title "Sending in 4 s" (`body` Medium 13 `onSlip`, tabular) over "Re: Contoso rollout · to Ben Carter" (`meta` `onSlip2`, tail-truncated) · "Undo" button (26 pt, radius 6, `onSlip` @ 14 % fill, Semibold) |
| Drain | 2 pt bar along the bottom edge, `onSlip` on an `onSlip` @ 18 % track, draining linearly over the undo window (5 s default) |
| Timing | in 240 ms (rise 12 pt + fade, settle); out 120 ms fade when sent, or immediately on Undo (the composer reopens) |

States: counting; hover (pauses nothing: the send time is a promise); Undo hover/pressed/focused as toast action; sent ("Sent" with `checkmark` for 1.5 s, then fades); failed ("Couldn't send" + "Open draft"). Reduce Motion: no rise; the drain bar steps once per second.

### 5.31 Alerts and sheets

System `NSAlert` presented as a window-modal sheet. Quire supplies:

- **Title** as a question or a fact, sentence case, no full stop for questions: "Discard this draft?", "Couldn't send the message".
- **Body**: what happens or what went wrong, then the remedy, one or two sentences. "The message to Ben Carter hasn't been sent. Discarding removes it from this Mac."
- **Buttons**: verbs. Destructive button marked `hasDestructiveAction` and never the default; ↩ = safe choice ("Keep Writing"), ⌘⌫ = destructive ("Discard"), Esc = cancel.
- **Icon**: the app icon (system default); no custom alert icons.

Quire-drawn sheets (only the Keyboard Shortcuts sheet, ⌘/): 520 pt wide, `raised`, radius 12, e3, padding 24, `title` heading, two columns of shortcut rows (`body` label left, keycaps right), section running heads.

### 5.32 Tooltips

System `NSToolTip` on every icon-only control and on truncated text. Content: action name, two spaces, the shortcut ("Archive  E", "Reply all  A", "All Inboxes  ⌘0"). Truncated subjects and senders show their full text. In the web shell, use `title` attributes so WebKit shows the same system tooltip. Reader-only custom hints (rare) use the `tip` style: 22 pt, radius 5, `raised`, e2, `snippet` 12, shortcut in `ink3`.

### 5.33 Menus

Main menu (system), with Quire content:

- **SuperSparrow**: About SuperSparrow · Settings… ⌘, · Services · Hide/Quit.
- **File**: New Message ⌘N (also C) · Close Window ⌘W · Add Gmail Account… · Add Microsoft Account… · Save Attachments…
- **Edit**: standard, plus Find… ⌘F (focus search).
- **View**: Inbox / Starred / Sent / Drafts / Trash / All Mail (G-sequences shown) · All / Focused / Other ⌥1–3 · All Inboxes ⌘0 · Account 1–9 ⌘1–9 · Show/Hide Account Rail ⌃⌘S · Compact Rows ⌥⌘C · Load Images ⇧⌘I · Original Colors ⇧⌘O · Show Quoted Text .
- **Message**: Reply R · Reply All A · Forward F · — · Archive E · Move to Trash # · Move to Inbox ⇧I · Star S · Mark as Unread U · — · Next Message N · Previous Message P.
- **Window**, **Help** (Keyboard Shortcuts ⌘/).

Single-key shortcuts are handled by `KeyboardRouter` and shown in the menu as attributed shortcut text (they are not `keyEquivalent`s, so they never fire in text fields). Context menu on rows and cards: Reply, Reply All, Forward, —, Archive, Star, Mark as Unread, Move to Inbox (disabled where it does not apply), —, Move to Trash; every item with its symbol and shortcut. Menu items use title case; disabled items stay visible.

### 5.34 Keyboard hints (keycaps)

| Part | Metric |
|---|---|
| Keycap | min 18 × 18 (16 inside the search field), padding 0 4, radius 4; `raised` with a 1 pt `rule` inset and a 1 pt `rule` bottom inset (pressed-key depth) |
| Text | `kbd` (SF Pro 11 Medium) `ink2`; modifiers in Apple order ⌃⌥⇧⌘; Return "↩", Delete "⌫", Escape "esc" |
| Sequences | "G then I": two keycaps with "then" in `meta` `ink3` between them |
| On slip | `onSlip2` text, 1 pt `onSlip` @ 30 % edge, no fill |

Keyboard map (all single keys are inactive while a text field has focus):

| Key | Action | Key | Action |
|---|---|---|---|
| J / K | next / previous conversation | E | archive |
| ↩ / → | open (focus the reader) | # | move to Trash |
| Esc / ← | back to the list | S | star |
| N / P | next / previous message in the reader | U | mark unread |
| . | show / hide quoted text | Z | undo |
| R / A / F | reply / reply all / forward | C | new message |
| / or ⌘F | search | ⌘0 / ⌘1…9 | all inboxes / account |
| G I, G S, G T, G D, G #, G A | Inbox, Starred, Sent, Drafts, Trash, All Mail | ⌥1 / ⌥2 / ⌥3 | All / Focused / Other |
| ⌘↩ | send | ⇧⌘R | open quick reply in the composer |
| ⌃⌘S | show / hide the rail | ⌘/ | keyboard shortcuts |

### 5.35 Progress

| Indicator | Metric | Use |
|---|---|---|
| Spinner | `NSProgressIndicator` `.spinning`, 12 (small), 16 (regular), 32 (large); tinted `ink3` (on fills: the label colour) | buttons, sync line, search, chips |
| Determinate bar | 4 pt, radius 2, track `fill`, fill `accent` | Settings sync %, large downloads |
| Sync hairline | 2 pt along the top edge of the sync line, `accent`, no track | bootstrap progress |
| Chip progress | 2 pt, 120 pt, track `rule`, fill `accent` | attachment download/upload |

Spinners appear only after 150 ms. Determinate progress never animates backwards; it jumps forward without easing.

### 5.36 Welcome screen

Fills the main window until the first account is added; the rail and list are hidden; the window background is `paper`.

| Part | Metric |
|---|---|
| Block | centred, max width 360 |
| Mark | `ss.sparrow` 52 pt in `accent` |
| Title | "SuperSparrow" in `display` (New York 34/40 Semibold), 14 below the mark |
| Tagline | "Your mail, quietly fast." New York Italic 17/24 `ink2`, 4 below |
| Actions | 28 below; two large secondary buttons, 328 wide, 10 apart: `envelope` 18 + "Add Gmail account" (trailing "Google" in `snippet` `ink3`), "Add Microsoft account" (trailing "365 · Outlook") |
| Footnote | 20 below, `meta` 11/15 `ink3`, max 330 wide: "Your mail is stored on this Mac and travels only between this Mac and Google or Microsoft. No analytics, ever." |
| Link | "Set up OAuth clients…" (`accent` link), 8 below |

States: rest; button hover/pressed/focused (§5.23; the first button has initial focus); waiting for the browser (the pressed button shows a spinner and "Finish signing in in your browser…", the other is disabled, a ghost "Cancel" appears); error ("Couldn't add the account" + reason in `danger` above the buttons); success (240 ms cross-fade to the inbox with the skeleton).

### 5.37 Settings window

SwiftUI `Settings { TabView { … } }`, toolbar tab style, 520 pt wide, height fits content. Tabs: **Accounts** (`person.crop.circle`), **OAuth** (`key`), **General** (`gearshape`). Toolbar tab items: 76 pt wide, symbol 20, label `meta` 11 Medium; selected = `fill` rounded 6 behind, symbol `accent`, label `ink`. Content padding 20 24 22 on `canvas`.

**Accounts**: a list (`sheet`, radius 8, hairline edge) of account rows, then +/− segmented square buttons (24 × 22), then "Account ink" with ten 18 pt swatches.

| Account row part | Metric |
|---|---|
| Row | 56 pt, padding 0 14 0 16, gap 12 |
| Avatar | 30 + ring |
| Name / address | `body` Semibold 13/16 `ink` over `snippet` 12/15 `ink2` |
| Status (trailing) | "Up to date" (`checkmark` `success`), "Syncing 42 %" (spinner), "Sign in required" (address line turns `danger` + "Reconnect" small secondary button), "Offline" (`wifi.slash`) |
| Provider | tag "Gmail" / "Microsoft 365" on hover, before the status |
| Selected | `selWash` (window key) / `selWashIdle` |

Swatches: 18 pt circles in the account inks, 8 apart; the chosen one has a 2 pt `canvas` gap and a 1.5 pt `ink` ring plus a white checkmark; caption "Cobalt · used on the ring, rail and kicker" in `meta` `ink3`. Swatches are radio buttons with accessible names.

**OAuth**: section titles "Google", "Microsoft" in `title`; fields stacked with labels above; client IDs in `mono`; "How to create these…" link; primary "Save" (enabled when changed).

**General** (form, labels right-aligned in a 120 pt column, 12 pt row gap, a hairline between groups): Reading font (popup: New York, SF Pro) · List density (radio: Standard, Compact) · Text size (popup) · Undo send (popup: 5, 10, 20 seconds) · — · Remote images (toggle "Load by default") · Notifications (toggle "New mail"; checkbox "Show sender and subject" with help text "Off: notifications say "New message" and the account only.").

### 5.38 Notifications

`UNUserNotificationCenter`, category per account (`threadIdentifier` = account id so they group). The system draws them; Quire supplies content:

| Field | Content |
|---|---|
| Title | sender display name ("Ben Carter") |
| Subtitle | subject ("Contoso rollout: go-live checklist") |
| Body | the first line of the snippet, max 120 characters |
| Private mode (Settings off) | title "New message", subtitle = account name, no body |
| Summary (more than 3 within 30 s) | "3 new messages" · account name |
| Actions | Archive, Reply (text input, sends with undo window), Mark as Read |
| Sound | system default, off when the app is frontmost |

No notification for mail that arrives while its conversation is open, for Other-category mail when the Inbox filter is Focused, or during bootstrap.

### 5.39 App icon

macOS squircle (system mask), three variants (default, dark, tinted, via the asset catalogue's appearance variants):

- **Default**: laid-paper face, vertical gradient `#FBF8F1` → `#ECE5D7`, with faint laid lines at 4 % ink every 1/32 of the icon; an inset "stamp" rule at 9 % of the icon size, 1 pt at 128 pt, Iron Gall at 28 %; the `ss.sparrow` mark at 60 % of the width, `#1E5468`, optically centred (shifted 2 % left and 3 % up).
- **Dark**: face `#2A2825` → `#171614`, stamp rule and mark in wet ink `#6DB6C9`.
- **Tinted**: monochrome mark on the system tint ground; no stamp rule.

The Dock badge stays system red: it is macOS chrome. The icon shares the mark with the welcome screen, About and inbox zero, and nowhere else.

### 5.40 Semantic banners

32 pt, radius 6, padding 0 6 0 10, gap 8, `snippet` 12/16 `ink` text; glyph 14 pt in the semantic colour; optional trailing link button. Variants: neutral (`fill`, glyph `ink2`), info (`infoWash`, `info`), success (`successWash`, `success`), warning (`warningWash`, `warning`), danger (`dangerWash`, `danger`). Used inside sheets and Settings; never stacked more than one per message.

---
## 6. Contrast table

Computed with WCAG 2.x relative luminance from the exact token values (alpha tokens composited over the stated base first; "a + b" means token b composited over token a). "Need" is 4.5 for text and 3.0 for essential UI (icons, state-bearing borders, focus rings, pips, rings). Avatar rows test initials on their face.

| Pair | Foreground | Background | Need | Light | Dark | Light IC | Dark IC |
|---|---|---|---|---|---|---|---|
| Primary text on list | `ink` | `paper` | 4.5 | 16.45 | 14.23 | 18.82 | 18.86 |
| Headline on reader desk | `ink` | `canvas` | 4.5 | 15.35 | 14.94 | 16.78 | 19.54 |
| Body on message sheet | `ink` | `sheet` | 4.5 | 17.04 | 13.11 | 19.29 | 17.21 |
| Text on rail | `ink` | `spine` | 4.5 | 14.16 | 15.59 | 14.64 | 20.04 |
| Row text, selected (focused list) | `ink` | `selWash` | 4.5 | 13.72 | 10.51 | 13.57 | 11.21 |
| Row text, selected (idle) | `ink` | `selWashIdle` | 4.5 | 13.90 | 12.00 | 13.56 | 13.70 |
| Snippet on list | `ink2` | `paper` | 4.5 | 7.64 | 8.18 | 11.69 | 13.16 |
| Snippet on hovered row | `ink2` | `paper + hover` | 4.5 | 6.99 | 7.15 | 10.18 | 10.49 |
| Snippet, selected row | `ink2` | `selWash` | 4.5 | 6.37 | 6.04 | 8.43 | 7.82 |
| Snippet, idle selected row | `ink2` | `selWashIdle` | 4.5 | 6.46 | 6.89 | 8.42 | 9.56 |
| Meta on sheet | `ink2` | `sheet` | 4.5 | 7.91 | 7.53 | 11.99 | 12.01 |
| Meta on desk | `ink2` | `canvas` | 4.5 | 7.13 | 8.59 | 10.42 | 13.64 |
| Rail labels | `ink2` | `spine` | 4.5 | 6.58 | 8.96 | 9.09 | 13.98 |
| Time, running head on list | `ink3` | `paper` | 4.5 | 5.52 | 6.32 | 9.24 | 10.66 |
| Time on hovered row | `ink3` | `paper + hover` | 4.5 | 5.05 | 5.53 | 8.04 | 8.49 |
| Time, selected row | `ink3` | `selWash` | 4.5 | 4.60 | 4.67 | 6.66 | 6.33 |
| Time, idle selected row | `ink3` | `selWashIdle` | 4.5 | 4.66 | 5.33 | 6.66 | 7.74 |
| Placeholder in field | `ink3` | `sheet` | 4.5 | 5.71 | 5.82 | 9.47 | 9.72 |
| Date on desk | `ink3` | `canvas` | 4.5 | 5.15 | 6.64 | 8.24 | 11.04 |
| Count badge text | `ink2` | `sheet + fill` | 4.5 | 7.02 | 6.07 | 10.01 | 8.38 |
| Search placeholder on track | `ink2` | `paper + fill` | 4.5 | 6.79 | 6.68 | 9.77 | 9.52 |
| Link / accent text on list | `accent` | `paper` | 4.5 | 7.97 | 7.53 | 11.24 | 11.38 |
| Link in reader chrome | `accent` | `sheet` | 4.5 | 8.25 | 6.94 | 11.53 | 10.38 |
| Link on desk | `accent` | `canvas` | 4.5 | 7.43 | 7.91 | 10.02 | 11.79 |
| Accent text on selection | `accent` | `selWash` | 4.5 | 6.65 | 5.56 | 8.11 | 6.76 |
| Primary button label | `onAccent` | `accent` | 4.5 | 8.32 | 7.56 | 11.53 | 11.13 |
| Primary button label, hover | `onAccent` | `accentHover` | 4.5 | 10.06 | 8.82 | 13.57 | 12.59 |
| Primary button label, pressed | `onAccent` | `accentPressed` | 4.5 | 12.14 | 5.99 | 15.57 | 9.46 |
| Toast text | `onSlip` | `slip` | 4.5 | 13.95 | 14.20 | 18.98 | 19.29 |
| Toast secondary text | `onSlip2` | `slip` | 4.5 | 7.53 | 6.59 | 12.86 | 11.99 |
| Destructive button label | `onDanger` | `dangerFill` | 4.5 | 6.67 | 8.03 | 9.17 | 10.89 |
| Error text on sheet | `danger` | `sheet` | 4.5 | 6.61 | 6.97 | 9.17 | 9.62 |
| Error text on list/sync line | `danger` | `paper` | 4.5 | 6.38 | 7.57 | 8.94 | 10.55 |
| Error banner text | `danger` | `dangerWash` | 4.5 | 5.41 | 6.58 | 6.27 | 7.58 |
| Remote-images banner text | `warning` | `warningWash` | 4.5 | 5.59 | 7.09 | 7.00 | 7.71 |
| Warning text on sheet | `warning` | `sheet` | 4.5 | 6.50 | 7.89 | 9.37 | 10.52 |
| Success text on sheet | `success` | `sheet` | 4.5 | 6.42 | 7.71 | 9.15 | 10.54 |
| Success banner text | `success` | `successWash` | 4.5 | 5.49 | 6.97 | 6.99 | 7.63 |
| Info banner text | `info` | `infoWash` | 4.5 | 5.98 | 6.96 | 7.08 | 8.09 |
| Info text on sheet | `info` | `sheet` | 4.5 | 7.16 | 7.30 | 9.94 | 10.54 |
| Banner body text | `ink` | `warningWash` | 4.5 | 14.65 | 11.78 | 14.41 | 12.61 |
| Kbd cap, segmented thumb | `ink` | `raised` | 4.5 | 17.18 | 11.84 | 19.29 | 15.67 |
| Active token text | `ink` | `accentWash` | 4.5 | 13.72 | 10.51 | 13.57 | 11.21 |
| Elision mark, active (Hide quoted text) | `accent` | `accentWash` | 4.5 | 6.65 | 5.56 | 8.11 | 6.76 |
| Shortcut column in menus and tooltips | `ink3` | `raised` | 4.5 | 5.76 | 5.26 | 9.47 | 8.85 |
| Menu glyphs, popup chevrons | `ink2` | `raised` | 4.5 | 7.98 | 6.80 | 11.99 | 10.94 |
| Address token text | `ink` | `sheet + fill` | 4.5 | 15.13 | 10.57 | 16.11 | 12.01 |
| Field / control border on list | `ruleStrong` | `paper` | 3.0 | 3.55 | 3.72 | 6.77 | 7.01 |
| Field / checkbox border on sheet | `ruleStrong` | `sheet` | 3.0 | 3.68 | 3.43 | 6.94 | 6.39 |
| Outline chip border on desk | `ruleStrong` | `canvas` | 3.0 | 3.32 | 3.91 | 6.03 | 7.26 |
| Focus ring on list | `focus` | `paper` | 3.0 | 7.97 | 7.53 | 11.24 | 11.38 |
| Focus ring on sheet | `focus` | `sheet` | 3.0 | 8.25 | 6.94 | 11.53 | 10.38 |
| Focus ring on desk (card focus) | `focus` | `canvas` | 3.0 | 7.43 | 7.91 | 10.02 | 11.79 |
| Focus ring on rail | `focus` | `spine` | 3.0 | 6.86 | 8.25 | 8.74 | 12.09 |
| Focus ring over selection | `focus` | `selWash` | 3.0 | 6.65 | 5.56 | 8.11 | 6.76 |
| Margin rule on selected row | `selRule` | `selWash` | 3.0 | 6.65 | 5.56 | 8.11 | 6.76 |
| Margin rule vs adjacent paper | `selRule` | `paper` | 3.0 | 7.97 | 7.53 | 11.24 | 11.38 |
| Idle margin rule | `selRuleIdle` | `selWashIdle` | 3.0 | 4.66 | 5.33 | 6.66 | 7.74 |
| Rail margin rule | `selRule` | `spine` | 3.0 | 6.86 | 8.25 | 8.74 | 12.09 |
| Unread pip on row | `accent` | `paper` | 3.0 | 7.97 | 7.53 | 11.24 | 11.38 |
| Unread pip on hovered row | `accent` | `paper + hover` | 3.0 | 7.30 | 6.59 | 9.79 | 9.06 |
| Unread pip on selected row | `accent` | `selWash` | 3.0 | 6.65 | 5.56 | 8.11 | 6.76 |
| Unread pip on idle selection | `accent` | `selWashIdle` | 3.0 | 6.74 | 6.35 | 8.10 | 8.26 |
| Unread pip / toggle-on on sheet | `accent` | `sheet` | 3.0 | 8.25 | 6.94 | 11.53 | 10.38 |
| Rail badge fill vs rail | `accent` | `spine` | 3.0 | 6.86 | 8.25 | 8.74 | 12.09 |
| Star glyph on row | `star` | `paper` | 3.0 | 5.04 | 8.59 | 7.59 | 11.57 |
| Star glyph on selected row | `star` | `selWash` | 3.0 | 4.20 | 6.35 | 5.48 | 6.87 |
| Star glyph on idle selection | `star` | `selWashIdle` | 3.0 | 4.26 | 7.24 | 5.47 | 8.40 |
| Star in reader | `star` | `sheet` | 3.0 | 5.22 | 7.92 | 7.79 | 10.56 |
| Star in reader toolbar | `star` | `canvas` | 3.0 | 4.70 | 9.02 | 6.77 | 11.99 |
| Icons (secondary) on list | `ink2` | `paper` | 3.0 | 7.64 | 8.18 | 11.69 | 13.16 |
| Toolbar icons on desk | `ink2` | `canvas` | 3.0 | 7.13 | 8.59 | 10.42 | 13.64 |
| Rail icons | `ink2` | `spine` | 3.0 | 6.58 | 8.96 | 9.09 | 13.98 |
| Selected tab underline | `ink` | `paper` | 3.0 | 16.45 | 14.23 | 18.82 | 18.86 |
| Error field border | `danger` | `sheet` | 3.0 | 6.61 | 6.97 | 9.17 | 9.62 |
| Pending glyph on selected row | `ink3` | `selWash` | 3.0 | 4.60 | 4.67 | 6.66 | 6.33 |
| Selected settings tab glyph | `accent` | `paper + fill` | 3.0 | 7.08 | 6.15 | 9.39 | 8.23 |
| Slow-sync glyph on list | `warning` | `paper` | 3.0 | 6.28 | 8.56 | 9.13 | 11.53 |
| Up-to-date glyph in settings | `success` | `sheet` | 3.0 | 6.42 | 7.71 | 9.15 | 10.54 |
| Sign-in glyph on sync line | `danger` | `paper` | 3.0 | 6.38 | 7.57 | 8.94 | 10.55 |
| Account ring Cobalt on list | `account.Cobalt` | `paper` | 3.0 | 8.75 | 5.02 | 11.81 | 6.74 |
| Account ring Cobalt on selected row | `account.Cobalt` | `selWash` | 3.0 | 7.30 | 3.71 | 8.52 | 4.01 |
| Account ring Cobalt on idle selection | `account.Cobalt` | `selWashIdle` | 3.0 | 7.39 | 4.23 | 8.51 | 4.89 |
| Account ring Cobalt on rail | `account.Cobalt` | `spine` | 3.0 | 7.53 | 5.50 | 9.19 | 7.16 |
| Account ring Ochre on list | `account.Ochre` | `paper` | 3.0 | 4.99 | 10.39 | 6.85 | 13.47 |
| Account ring Ochre on selected row | `account.Ochre` | `selWash` | 3.0 | 4.17 | 7.67 | 4.94 | 8.01 |
| Account ring Ochre on idle selection | `account.Ochre` | `selWashIdle` | 3.0 | 4.22 | 8.75 | 4.94 | 9.79 |
| Account ring Ochre on rail | `account.Ochre` | `spine` | 3.0 | 4.30 | 11.37 | 5.33 | 14.31 |
| Account ring Oxblood on list | `account.Oxblood` | `paper` | 3.0 | 7.40 | 5.83 | 10.08 | 7.76 |
| Account ring Oxblood on selected row | `account.Oxblood` | `selWash` | 3.0 | 6.18 | 4.31 | 7.27 | 4.61 |
| Account ring Oxblood on idle selection | `account.Oxblood` | `selWashIdle` | 3.0 | 6.26 | 4.92 | 7.26 | 5.64 |
| Account ring Oxblood on rail | `account.Oxblood` | `spine` | 3.0 | 6.37 | 6.39 | 7.84 | 8.24 |
| Account ring Viridian on list | `account.Viridian` | `paper` | 3.0 | 4.40 | 9.34 | 6.00 | 12.14 |
| Account ring Viridian on selected row | `account.Viridian` | `selWash` | 3.0 | 3.67 | 6.90 | 4.33 | 7.21 |
| Account ring Viridian on idle selection | `account.Viridian` | `selWashIdle` | 3.0 | 3.72 | 7.87 | 4.32 | 8.82 |
| Account ring Viridian on rail | `account.Viridian` | `spine` | 3.0 | 3.79 | 10.23 | 4.67 | 12.90 |
| Account ring Iris on list | `account.Iris` | `paper` | 3.0 | 5.30 | 8.80 | 7.25 | 11.45 |
| Account ring Iris on selected row | `account.Iris` | `selWash` | 3.0 | 4.42 | 6.50 | 5.23 | 6.81 |
| Account ring Iris on idle selection | `account.Iris` | `selWashIdle` | 3.0 | 4.48 | 7.42 | 5.22 | 8.32 |
| Account ring Iris on rail | `account.Iris` | `spine` | 3.0 | 4.57 | 9.64 | 5.64 | 12.17 |
| Account ring Moss on list | `account.Moss` | `paper` | 3.0 | 8.06 | 5.45 | 10.90 | 7.26 |
| Account ring Moss on selected row | `account.Moss` | `selWash` | 3.0 | 6.72 | 4.03 | 7.86 | 4.31 |
| Account ring Moss on idle selection | `account.Moss` | `selWashIdle` | 3.0 | 6.81 | 4.60 | 7.85 | 5.27 |
| Account ring Moss on rail | `account.Moss` | `spine` | 3.0 | 6.94 | 5.97 | 8.48 | 7.71 |
| Account ring Terracotta on list | `account.Terracotta` | `paper` | 3.0 | 4.50 | 8.67 | 6.14 | 11.32 |
| Account ring Terracotta on selected row | `account.Terracotta` | `selWash` | 3.0 | 3.75 | 6.40 | 4.43 | 6.73 |
| Account ring Terracotta on idle selection | `account.Terracotta` | `selWashIdle` | 3.0 | 3.80 | 7.30 | 4.42 | 8.22 |
| Account ring Terracotta on rail | `account.Terracotta` | `spine` | 3.0 | 3.87 | 9.49 | 4.77 | 12.02 |
| Account ring Aubergine on list | `account.Aubergine` | `paper` | 3.0 | 11.05 | 4.50 | 14.40 | 6.05 |
| Account ring Aubergine on selected row | `account.Aubergine` | `selWash` | 3.0 | 9.22 | 3.32 | 10.38 | 3.60 |
| Account ring Aubergine on idle selection | `account.Aubergine` | `selWashIdle` | 3.0 | 9.34 | 3.79 | 10.38 | 4.39 |
| Account ring Aubergine on rail | `account.Aubergine` | `spine` | 3.0 | 9.51 | 4.93 | 11.20 | 6.43 |
| Account ring Cerulean on list | `account.Cerulean` | `paper` | 3.0 | 6.17 | 6.98 | 8.46 | 9.22 |
| Account ring Cerulean on selected row | `account.Cerulean` | `selWash` | 3.0 | 5.15 | 5.15 | 6.10 | 5.48 |
| Account ring Cerulean on idle selection | `account.Cerulean` | `selWashIdle` | 3.0 | 5.22 | 5.88 | 6.10 | 6.70 |
| Account ring Cerulean on rail | `account.Cerulean` | `spine` | 3.0 | 5.31 | 7.64 | 6.58 | 9.80 |
| Account ring Graphite on list | `account.Graphite` | `paper` | 3.0 | 6.79 | 6.89 | 9.31 | 9.06 |
| Account ring Graphite on selected row | `account.Graphite` | `selWash` | 3.0 | 5.66 | 5.09 | 6.71 | 5.39 |
| Account ring Graphite on idle selection | `account.Graphite` | `selWashIdle` | 3.0 | 5.74 | 5.81 | 6.71 | 6.58 |
| Account ring Graphite on rail | `account.Graphite` | `spine` | 3.0 | 5.84 | 7.55 | 7.24 | 9.63 |
| Avatar initials, Clay | `avatar.clay.ink` | `avatar.clay.face` | 4.5 | 6.22 | 8.19 | 7.64 | 8.79 |
| Avatar initials, Wheat | `avatar.wheat.ink` | `avatar.wheat.face` | 4.5 | 6.06 | 8.17 | 7.85 | 8.46 |
| Avatar initials, Fern | `avatar.fern.ink` | `avatar.fern.face` | 4.5 | 6.19 | 8.16 | 7.65 | 8.42 |
| Avatar initials, Sea | `avatar.sea.ink` | `avatar.sea.face` | 4.5 | 6.22 | 8.10 | 7.56 | 8.49 |
| Avatar initials, Slate | `avatar.slate.ink` | `avatar.slate.face` | 4.5 | 6.81 | 7.92 | 7.82 | 8.75 |
| Avatar initials, Heather | `avatar.heather.ink` | `avatar.heather.face` | 4.5 | 7.25 | 8.01 | 8.36 | 8.70 |
| Avatar initials, Rose | `avatar.rose.ink` | `avatar.rose.face` | 4.5 | 6.88 | 8.05 | 8.09 | 8.66 |
| Avatar initials, Stone | `avatar.stone.ink` | `avatar.stone.face` | 4.5 | 6.89 | 8.27 | 8.53 | 8.94 |

All 128 pairs pass in all four modes (0 failures). Lowest margins: Time, selected row 4.60 (Light); Time, idle selected row 4.66 (Light); Outline chip border on desk 3.32 (Light); Account ring Aubergine on selected row 3.32 (Dark); Time on hovered row 5.05 (Light).

Not tested on purpose: `inkDisabled` (disabled text and glyphs are exempt, WCAG 1.4.3), decorative `rule` hairlines (they separate, they do not convey state) and avatar faces against their background (decorative).

## 7. Implementation notes

**Files.**

- `Sources/SuperSparrowApp/Design/quire-tokens.json`: the single source (colours in four modes, type roles, spacing, radii, motion, elevation).
- `scripts/tools/quire-tokens.swift`: a SwiftPM-friendly generator (no Node) that writes `QuireTokens.swift` (NSColor providers, `NSFont` role factories, `CGFloat` metrics, `CAMediaTimingFunction`s), the CSS head inside `ConversationShellAssets.css`, and `Tests/SSCoreTests/QuireContrastTests.swift`, which asserts every pair in §6.
- `QuireFont.swift`: `static func role(_ role: QuireTypeRole) -> NSFont`, using `NSFontDescriptor.withDesign(.serif / .rounded / .monospaced)` and cached per text-size setting.

**AppKit.** Rows: build `NSAttributedString`s with role fonts, `.kern` and fixed-line-height paragraph styles; draw pip, margin rule, account ring and count badge in `draw(_:)` with `NSBezierPath`; never set layer shadows on row views. Rail: `NSVisualEffectView(.sidebar)` behind a plain view; tiles draw themselves. Focus rings: override `drawFocusRingMask()` and `focusRingMaskBounds`, and set the ring colour via `NSColor.qFocus` in a custom `focusRingType` drawing (or draw the ring in `draw(_:)` when `window?.firstResponder === self`).

**SwiftUI (Settings).** `Color.qAccent = Color(nsColor: .qAccent)` and so on; `.tint(.qAccent)` on the `TabView`; `Form { }.formStyle(.columns)` gives right-aligned labels; fonts via `Font(QuireFont.role(.body))`.

**WebKit (reader).** Replace the `:root` block of `ConversationShellAssets.css` with the generated tokens; map existing classes: `.ss-card` → sheet (radius 8, padding 22 28 14), collapsed cards → stack rows (44 pt, joined), `.ss-button` → `.elide` and link buttons, `.ss-chip` → attachment chip, `.ss-footer a` → ghost buttons. `bodyCSS` gets `font: 15px/24px ui-serif` (or the sans setting) for plain and unstyled bodies only. The kicker and headline are rendered by `ss.render` from the payload; the shell posts `headlineHidden` once when the headline leaves the viewport.

**Migration from today's UI** (what disappears):

| Today | Quire |
|---|---|
| 8 ad-hoc font sizes (10–15 pt), all SF Pro | 18 named roles; New York for subjects and reading |
| Radii chosen per view (6, 8, 10, 12, 16 pt) | Four steps: 3, 6, 8, 12, plus pill |
| ~30 one-off hex colours and four avatar palettes | 39 semantic tokens × 4 modes, 10 account inks, 8 avatar tints |
| System blue accent, selection as solid accent | Iron Gall, selection as wash + margin rule |
| Account shown as a 10 pt dot on the avatar | 1.5 pt account ring (unified views), kicker text, square mark in compact |
| Pending rows faded to 60 % opacity (fails contrast) | full-contrast row + pending glyph |
| Toast in HUD material, accent "Undo" | opaque ink slip, "Undo" + keycap |
| Reader cards with 12 pt gaps and equal weight | one joined stack of folded messages + one open sheet |
| Tools row (Show quoted text, Original colors) above every body | elision mark at the fold; Original colors in the header actions (dark only) |

## 8. Why Quire

Sparrow was loved for doing very little very well: one list, one pane, an account strip, no chrome to speak of. Quire keeps that shape and its restraint, and adds the one thing Sparrow never had, a point of view about reading. It is unlike the system-blue mail clients (Mail, Mimestream, Spark) and unlike Superhuman's dark, purple speed aesthetic: warm paper, a serif you read in, a blue-black ink used like a pen, and a still list that never moves, so the speed shows in response rather than in motion.
