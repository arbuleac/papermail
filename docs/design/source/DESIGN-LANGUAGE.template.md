# Quire — the SuperSparrow design language

**Version {{version}} · 8 November 2026 · authoritative.** 1.5.2 adds **Keep mail on this Mac** to General: a popup (Everything, 1 year, 3 months) with the space the mailbox takes beside it; a message older than the window keeps its row, snippet and searchable text, and its full message downloads again when it is opened (§5.40, `settings.mailboxSizeGap`). 1.5.1 adds account signatures: one per account, set in the account's detail form (§5.40), inserted by the composer one empty line below the typing point and above the folded original, and replaced when From changes (§5.20); §9 no longer excludes them. 1.5 renames the General font setting **Font** and makes it the app's typeface: SF Pro now sets every New York role in its sans twin across the app and applies live, and monograms gain the twin `monogramSans` (§4.4, §5.29, §5.40). 1.4 moves the six views into the rail as folder tiles (§5.2), anchors the accounts at the bottom of the rail just above Add, puts the masthead, search and compose on one header line (§5.3, §5.6), keeps the title menu for minimal mode only (§5.4), and removes the Focused/Other filter tabs (§5.5) and the rows' “Other” tag (§5.7). 1.3.1 records what the code does where it went past 1.3: one rule for account names and monograms (§4.2), plain text set as paragraphs (§5.14), the app icon as drawn (§5.42, `appIcon.corner` and `stampWidth`), `QuireWindowChrome` (§3.2) and the AppKit component names (§8.2), and the composer title-bar test (§8.7). 1.3 closes the eighteen gaps of the 1.2 review: pressed checkbox, radio and toggle states that keep 3:1 (`controlOnPressed`, a knob-face press, a wash-free link press), account inks that never meet a popup's hover or pressed face, a complete Graphite substitution with its own generated contrast pairs, the full alert inventory, the reconnect flow, no signatures in v1, the cheat sheet's content, Space and Tab inside a sheet, the Settings window's size and detail form, the multi-selection and Trash action sets, the positions that still had no metric, a Reduce Transparency scrim, capped token rows, expanded recipients, and the worked numbers that still assumed the macOS 15 rail. This document, `docs/design/tokens.json` and `docs/design/specimen.html` (rendered as `specimen-light.png` and `specimen-dark.png`) are the complete design language for SuperSparrow. Where they disagree, `tokens.json` wins and the other two are regenerated from it.

A quire is a gathering of folded sheets, the unit a book is sewn from. Quire treats mail the same way: each conversation is a tight stack of folded messages and one open sheet, set in New York on warm paper and marked in a single ink, **Iron Gall**, the blue-black ink letters were written in for a thousand years. The list is a still index; the reader gets the room of a page. Sparrow's shape stays: a narrow account rail, one list, one reader, almost no chrome. Superhuman's speed shows in response, not in motion.

**How to read the numbers.** All metrics are points (1 pt = 1 CSS px in the reader). Colour values are given in four modes: Light, Dark, Light IC and Dark IC (IC = Increase Contrast). Alpha colours are written `#RRGGBB @ n %` here and `#RRGGBBAA` in `tokens.json`; they are always composited over the surface beneath. Every number in this file is rendered from `tokens.json`; the token path is given wherever a component lists its metrics (for example `layout.row.height`).

---

## 1. Principles

1. **Reading is the product.** Serif where people read, sans where they scan or write. New York sets subjects, the reader headline and plain mail; SF Pro sets everything you scan, operate or type.
2. **One ink, used like a pen.** Iron Gall marks only what needs you: unread, keyboard focus, the current selection and the single primary action. If two Iron Gall things compete in one region, one of them is wrong.
3. **A still list, a generous page.** The list is an index: fixed rows, no motion, no shadow, no blur. Actions never animate rows; feedback goes to the toast. The reader is a page: a {{layout.reader.columnMax}} pt column with {{typography.reading.lineHeight}} pt leading.
4. **Shape before colour.** Every state has a shape, a weight or a word: the pip, the margin rule, Semibold, the filled star, the queued glyph, the “!” badge. Colour confirms a state; it never carries it alone.
5. **Native first, then ours.** Traffic lights, menus, alerts, tooltips, scrollers, notifications and the Settings window frame and toolbar stay macOS. Quire styles content, the controls inside Settings (so their focus rings and edges meet 3:1), and the few surfaces macOS does not provide.

## 2. Signature elements

| Element | What it is | Where |
|---|---|---|
| **New York subjects** | Subjects are set in New York: {{typography.subject.size}} pt in rows, {{typography.headline.size}} pt as the reader headline, {{typography.composeSubject.size}} pt in the composer. Next to SF Pro senders and snippets the list reads like a table of contents. | Rows, reader header, composer |
| **Iron Gall** | The single accent: blue-black on paper (`{{color.accent.light}}`), wet ink on dark paper (`{{color.accent.dark}}`). Fills use a deeper pooled ink in dark (`{{color.accentFill.dark}}`) so white labels stay crisp. | Pip, unread time, margin rule, focus, primary button, badges |
| **The margin rule** | A {{border.marginRule.width}} pt rule flush with the leading edge marks where you are, as an editor marks a passage. Always drawn, in Iron Gall while its window is key and in `ink3` when it is not. | Selected row, rail, selected Settings account row, autocomplete highlight |
| **The horizon** | The traffic lights, the masthead, the search field, the compose button and the reader's kicker share one centre line, y = {{layout.listHeader.mastheadCenterY}}. The list header is that {{layout.listHeader.height}} pt title-bar band alone, so the index starts right under the title bar; the reader header adds its headline below the line, and its hairline at {{layout.readerHeader.height}} pt is the horizon the reader and the cheat sheet hang from. | Main window |
| **The quire** | Collapsed messages fold into one stack of {{layout.reader.stackRow}} pt lines; the open message is a full sheet beneath it. | Reader |
| **Kicker and headline** | A small uppercase kicker names the account (with its ink dot) and the message count above a New York headline, as a newspaper names its section. | Reader header |
| **The elision mark `[…]`** | Quoted text folds behind the editor's mark for omitted text (`ss.elide`), placed at the fold. | Reader, composer |
| **The slip and the contrail** | Toasts, the undo-send panel and the g-sequence HUD are small dark slips with one verb. The contrail, a {{layout.progress.contrail}} pt line with a {{layout.progress.contrailHead}} pt head, is the one drawn element that means time is moving. | Toast, undo send, sync line, attachment progress |
| **Monograms** | Avatar initials in New York Semibold (its SF Pro twin under the SF Pro font, §4.4) on soft tints, like monogrammed letterhead. The rail shows domain monograms (C for contoso.com). | Rows, reader, rail, Settings |

## 3. Platform decisions

### 3.1 System accent

- **Custom-drawn surfaces use fixed Iron Gall.** Selection, focus, the unread pip, badges and primary buttons are tuned against the paper surfaces in four modes; an arbitrary system accent (Yellow, Pink) breaks those pairs.
- **Native controls follow the app accent asset.** The app ships Iron Gall as its `NSAccentColorName` asset (`AccentColor` colour set: Any `{{color.accentFill.light}}`, Dark `{{color.accentFill.dark}}`, high-contrast `{{color.accentFill.lightHC}}` / `{{color.accentFill.darkHC}}`; the fill value, because macOS draws white text on it in menu highlights and default buttons). Under the default Multicolor setting, NSMenu highlights, NSAlert default buttons and the Settings toolbar's selected tab are therefore Iron Gall and match the custom drawing. (Controls inside Settings are Quire-drawn, §8.3, so they never depend on this.) When the user picks an explicit accent, native controls follow the user and custom-drawn Quire surfaces stay Iron Gall.
- **Graphite exception.** When the system accent is Graphite (`NSColor.currentControlTint == .graphiteControlTint`, or `controlAccentColor` saturation below {{platform.graphiteSaturationMax}}), every accent-family token is replaced from the neutral ramp, one row per token below (`graphite` in `tokens.json`). That user asked macOS to take colour out. Account inks are identity, not accent, and stay (the kicker dot, rings, the From dot, swatches); so do `selWashIdle`, `selRuleIdle`, the semantic colours and the star. Because colour no longer tells a link from text, link buttons draw their underline at rest under Graphite (hover and pressed as §5.24). Fills step back toward the surface as they are hovered and pressed (`ink` → `ink2` → `ink3`), because `ink` is already the end of the ramp. The build regenerates every contrast pair that touches one of these tokens with the substitutions applied ({{NGPAIRS}} Graphite pairs, §7) and asserts them with the others; the two 1.25 scan-cue pairs are the only ones not regenerated, because under Graphite the selection wash is the idle wash and the `ink` margin rule (≥ 12:1 on `paper`) is the cue.

{{TABLE:graphiteMap}}

- **Text selection** in text views and the reader keeps the system highlight colour (`selectedTextBackgroundColor`, CSS `::selection` left at default).

### 3.2 Window and title bar

- One main window: `.titled .closable .miniaturizable .resizable .fullSizeContentView`, `titlebarAppearsTransparent = true`, `titleVisibility = .hidden`, and an **empty toolbar**: `window.toolbar = NSToolbar(identifier: "main")` with no items, `toolbarStyle = .unified`, `titlebarSeparatorStyle = .none` (`layout.trafficLights.mechanism`). The toolbar exists only for its geometry: it makes AppKit lay the title bar out as the {{layout.window.titlebarZone}} pt unified band, with the traffic lights inset from the corner and centred on y = {{layout.trafficLights.centerY}}. Without a toolbar AppKit draws the plain title bar instead (lights at x ≈ 7–9, centre y ≈ 14–16, as in today's build, `dist/screenshot-main.png`), and every metric below would be wrong. The window's title (“SuperSparrow”, or “SuperSparrow — Demo” in demo mode, §5.43) still names it in the Window menu, Mission Control and VoiceOver. `QuireWindowChrome.configureMainWindow` (SSDesign) applies this configuration, and `QuireWindowChrome.metrics(of:)` reads the lights back as described next.
- **The traffic lights stay where AppKit puts them**; they are never moved with `setFrameOrigin`. Their centre line is y = {{layout.trafficLights.centerY}} on every supported macOS. Their horizontal extent depends on the release, so the layout reads it at runtime instead of assuming it: `lightsEnd` = where the zoom light is drawn to (`standardWindowButton(.zoomButton)`'s frame `minX` plus the last column it paints, `QuireWindowChrome.drawnTrailingEdge(of:)`, never more than the frame's `maxX`) and `lightsCenterY` = the close button's `midY`, both converted to the content view and measured from its top-leading corner. The drawn edge matters because AppKit's compatibility appearance, which an app linked against the macOS 15 SDK gets on every later release (SwiftPM builds today), draws the 12 pt light inside a 14 pt frame that ends 1 pt further out.

  | macOS | First light x | Light | Gap | `lightsEnd` | Rail width | Minimal-mode masthead x |
  |---|---|---|---|---|---|---|
  | 15 (the 1.1 values; asserted by `WindowChromeTests`) | {{layout.trafficLights.originX}} | {{layout.trafficLights.size}} | {{layout.trafficLights.gap}} | {{layout.trafficLights.endX}} | {{layout.rail.width}} | {{layout.listHeader.mastheadMinimalX}} |
  | 26 and later (measured on 27.0.1) | {{layout.trafficLights.originX26}} | {{layout.trafficLights.size26}} | {{layout.trafficLights.gap26}} | {{layout.trafficLights.endX26}} | {{layout.rail.width26}} | {{layout.listHeader.mastheadMinimalX26}} |
  | Any release, compatibility appearance (linked against the macOS 15 SDK; measured on 27.0.1) | 20 | 12 | 8 | 72 (the button frame ends at 73) | 76 | 84 |

  **Rail width** = the larger of {{layout.rail.width}} and the smallest even number ≥ `lightsEnd` + {{layout.rail.lightsClearance}} (`layout.rail.lightsClearance`), so the lights always sit on the rail with at least {{layout.rail.lightsClearance}} pt before its trailing hairline. The width includes that hairline: the split view's first divider is the hairline, so the rail's own pane is the width less one hairline (75 pt and the rule at x = 75 at 1×), and the list's default 364 likewise includes its trailing divider. Rail tiles, the divider and the utilities are centred in it (x = width / 2; `layout.rail.tileCenterX` is the macOS 15 value). In minimal mode the masthead starts at rail width + {{layout.listHeader.mastheadMinimalGap}} (`layout.listHeader.mastheadMinimalGap`), measured from the would-be rail, so it clears the lights by at least {{layout.listHeader.mastheadMinimalGap}} + {{layout.rail.lightsClearance}} pt on every release.
- **One centre line.** The masthead (§5.3), the kicker and the reader header actions (§5.12) and the compose button are all centred on `lightsCenterY` = {{layout.trafficLights.centerY}}, and the title-bar zone is twice that ({{layout.window.titlebarZone}}). `WindowChromeTests` (§8.7) builds the main window off screen with this exact configuration and asserts the close button's centre is {{layout.trafficLights.centerY}} ± {{layout.trafficLights.tolerance}} pt and that the rail clears `lightsEnd` by {{layout.rail.lightsClearance}} pt. If a future macOS moves the centre, that test fails, and `titlebarZone`, `mastheadCenterY`, `kickerCenterY` and the action tops are re-derived from the measured centre (zone = 2 × centre, tops = centre − 14) instead of patched by eye.
- The top {{layout.window.titlebarZone}} pt of every pane is the title-bar zone: it drags the window (`mouseDownCanMoveWindow`), double-click follows the system preference, and controls inside it opt out. Content under the toolbar still receives clicks (hit-testing passes through the transparent unified toolbar to the content view; verified on macOS 27). The toolbar's own container is taller than the band from macOS 26 on ({{layout.trafficLights.toolbarContainer26}} pt measured), so every view below y = {{layout.window.titlebarZone}} returns `mouseDownCanMoveWindow = false`: a click on the reader's headline or the first list row never drags the window. In full screen AppKit hides the toolbar band and reveals it on hover; the zone keeps its height so nothing jumps.
- Default size {{layout.window.defaultWidth}} × {{layout.window.defaultHeight}}, minimum {{layout.window.minWidth}} × {{layout.window.minHeight}}. The reader never gets narrower than {{layout.window.readerMinWidth}} pt (`layout.window.readerMinWidth`): the list's maximum width is the smaller of {{layout.list.maxWidth}} and window width − rail − {{layout.window.readerMinWidth}}.
- **Composer windows** use the same transparent title bar over `paper`: `.titled .closable .miniaturizable .resizable .fullSizeContentView`, `titlebarAppearsTransparent = true`, `titleVisibility = .visible` (the system draws the title text and the lights), no toolbar, so it keeps the plain system title bar: {{layout.window.composerTitlebar}} pt on macOS 15, {{layout.window.composerTitlebar26}} pt from macOS 26 on (measured on 27.0.1; `layout.window.composerTitlebar` / `composerTitlebar26`). `QuireWindowChrome.configureComposerWindow` applies it. The band's height is read from the window (`QuireWindowChrome.titlebarHeight(of:)`: the content view's height above `contentLayoutRect`), never assumed; the band is `paper` with a hairline at its bottom drawn by the content view, and the field rows start directly below it.

### 3.3 Appearance and accessibility modes

| Mode | AppKit / SwiftUI | Reader CSS | What changes |
|---|---|---|---|
| Light / Dark | `NSApp.effectiveAppearance`; app appearance follows the system | `prefers-color-scheme` | Every colour token switches value |
| Increase Contrast | `bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])`; observe `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` | `prefers-contrast: more` **and** `html.ss-ic` | Every token switches to its IC value; focus rings grow to {{border.focusRing.widthHC}} pt; sheets, the stack, the quick-reply field, autocomplete, the link popover and the cheat sheet gain a {{border.icOutline.width}} pt `ruleStrong` edge (`border.icOutline`); slips keep their own edge, `slipEdge`, whose IC values are stronger; hairlines draw at {{border.hairline.widthHC}} pt (`border.hairline.widthHC`) |
| Reduce Motion | `accessibilityDisplayShouldReduceMotion` | `prefers-reduced-motion` **and** `html.ss-rm` | Movement becomes a {{motion.duration.reducedFade}} ms fade or nothing (§4.10) |
| Reduce Transparency | `accessibilityDisplayShouldReduceTransparency` | `prefers-reduced-transparency` **and** `html.ss-rt` | One app-drawn surface is translucent: the cheat-sheet `scrim` (§5.32). Under Reduce Transparency it is drawn opaque as `scrimSolid` (the colour the scrim gives over `canvas`), so the window behind is hidden instead of seen through; the panel on it is opaque `raised` either way. Every other app surface is already opaque and does not change; system menus, alerts and notifications adapt themselves. `ss-rt` is mirrored anyway so any future translucent shell surface has its opaque fallback in place |

The app mirrors the three NSWorkspace flags onto the reader's `<html>` as `ss-ic`, `ss-rm` and `ss-rt` whenever they change, because WebKit does not reliably track all three media queries; every shell rule is written for both the query and the class.

### 3.4 Selection and focus model

- The list's selection stays **emphasized** (Iron Gall wash and rule) whenever the main window is key, whichever view is first responder, because `KeyboardRouter` drives `j`/`k` from the list, the reader and the quick-reply field alike. It turns idle (`selWashIdle` + `selRuleIdle`) only when the window is not key.
- The reader shows its own focus on a message (the {{border.focusRing.width}} pt ring) only after keyboard navigation (`n`/`p`, Tab). Which message R, A, F and Space act on is always shown, keyboard or mouse (the target message, §5.14).
- Tab order: rail (the selected folder, the selected account, Add, Settings) → list header controls (the masthead in minimal mode only, the Demo tag while it is on the line, search, compose) → list → sync line (only while it carries an action: Reconnect, Retry, Cancel; with Full Keyboard Access always) → reader actions → messages (stack rows, and inside each expanded sheet the order of §5.14) → quick reply. Esc follows the precedence in §6.1.

**Window not key: exactly these marks change.** When a window resigns key, AppKit stops drawing keyboard focus in it, and Quire changes only:

| Mark | Key | Not key |
|---|---|---|
| Selection wash and margin rule (list rows, rail tile, Settings account row) | `selWash` + `selRule` | `selWashIdle` + `selRuleIdle` |
| The quick reply's active-mode underline | `ink` | `ink3` |
| Primary buttons (Send, Save) | `accentFill` | secondary look (`raised`, `ruleStrong` edge, `ink` label), as native default buttons do |
| Focus rings | drawn on the first responder | not drawn (no first responder is shown in a non-key window) |

Every other Iron Gall mark stays as it is: the unread pip and unread time, badges, links, the selected token, checkbox and toggle on fills, the contrail and progress. Account inks (the kicker's dot, rings, the From dot) are not Iron Gall and never change with key state either. Because text colours never depend on key state, `RowContentCache` does not key on it and a focus change redraws only the selection fill and rule of the selected rows.

### 3.5 One token set, three renderers

`docs/design/tokens.json` is the only source. A Swift script (no Node) generates the AppKit colour providers, font roles and metrics, the reader's CSS custom properties, and the XCTest files that assert every contrast pair and every account-palette rule. Details in §8.

---

## 4. Foundations

### 4.1 Colour

**Neutral ramp: paper to ink.** Warm grey, hue about 75°, chroma under 4. Surfaces from the back in light mode: `spine` (rail), `canvas` (reader desk), `paper` (list and headers), `sheet` (messages, fields), `raised` (keycaps, secondary buttons, popovers). Dark mode puts the desk and the rail below the paper, so sheets rise by lightness rather than shadow. The slip is dark in both appearances.

**Usage rules**

- Text uses only `ink`, `ink2`, `ink3`, or `onAccent`, `onSlip`, `onSlip2`, `onDanger` on their fills. `ink3` is the lightest text allowed; `inkDisabled` is for disabled controls only.
- **Placeholders for missing data** (“No subject”, “No sender”) are set in the role they replace, in `ink3` and italic (New York Italic or SF Pro Italic), never Semibold, so they never read as content or as unread: list rows, the reader headline, the stack and the sheet's name line. The composer window title reads “New Message” in the system title style; notifications, which macOS draws, use the plain words; VoiceOver reads “No subject”.
- **On a slip**, a resting action's keycap legend is `onSlip2`; while the action is hovered or pressed its legend switches to `onSlip`, because `onSlip2` falls below 4.5:1 on `slip + slipPressed`.
- `rule` is decorative (separators, pane dividers, sheet edges). Anything whose edge says what a control is or what state it is in (fields, search, checkbox, toggle-off track, secondary buttons, tags) uses `ruleStrong`, which is ≥ 3:1 against every surface it sits on, at rest, in every mode.
- Washes (`hover`, `pressed`, `fill`, `slipHover`, `slipPressed`) are ink at low alpha. The quiet-toggle on states (`accentWash`, `accentWashHover`, `accentWashPressed`) are opaque, tuned so `accent` labels keep 4.5:1 in every state. AppKit draws them as a fill over the surface; CSS layers them as `linear-gradient(var(--q-hover), var(--q-hover))` over the surface colour.
- Iron Gall is split in two. `accent` is the mark colour (text, glyphs, pips, rules, rings) and is tuned against surfaces. `accentFill` is the fill colour (buttons, badges, checkbox and toggle on, selected token, menu highlight) and is tuned for white labels: in dark mode it is a deeper ink so fills stay quiet and labels stay light, instead of pastel fills with dark labels.
- Iron Gall never fills an area larger than a button. Selection is a wash plus the margin rule, never a solid block.
- Semantic colours always arrive with a glyph and words (“Sign in required” with `exclamationmark.triangle.fill`), never a coloured word alone. Danger is red and lives far from Iron Gall (teal-blue) and from every account ink.

**Surfaces**

{{TABLE:colors:surface}}

**Ink**

{{TABLE:colors:ink}}

**Lines**

{{TABLE:colors:line}}

**Washes** (composited over the surface beneath)

{{TABLE:colors:wash}}

**Iron Gall: accent, selection, focus**

{{TABLE:colors:accent}}

**Marks and semantics**

{{TABLE:colors:semantic}}

**Accent states.** Primary buttons: rest `accentFill`, hover `accentFillHover`, pressed `accentFillPressed`, disabled `fill` with `inkDisabled` label (badges and the selected token use `accentFill` alone). `accentFillPressed` is darker in every mode, which keeps a white label at 4.5:1 but drops the fill itself to as low as 2.54:1 against the dark `sheet` and `canvas` (Dark IC); that is acceptable where the label carries the control, never where the fill is the only mark of a state. So checkbox and radio on fills press to **`controlOnPressed`** instead, darker in light modes and lighter in dark modes (≥ 3:1 on `sheet` and `canvas`, checkmark ≥ 3:1 on it), and toggles take no wash at all: a press stretches the knob, a shape change rather than a colour one (§5.26). In an inactive window a primary button loses its fill and draws as a secondary button, as native default buttons do.

**Selection**

| Situation | Fill | Margin rule ({{border.marginRule.width}} pt) | Text |
|---|---|---|---|
| Main window key (any first responder) | `selWash` | `selRule` | unchanged inks |
| Main window not key | `selWashIdle` | `selRuleIdle` (always drawn, ≥ 3:1) | unchanged inks |
| Graphite system accent, window key | `selWashIdle` | `ink` | unchanged inks |
| Pointer over a selected row | no hover wash (hover is suppressed on selected rows) | unchanged | unchanged |

Text never inverts on selection, so the attributed strings cached per row stay valid across `j`/`k`, no on-accent string variants are needed, and no row is rebuilt when the selection moves. The light wash is deliberately stronger than a tint (1.25:1 or more against `paper`, asserted in §7) so the current row is found at a glance after fast `j`/`k`; the {{border.marginRule.width}} pt rule, the hidden separators around it and the unchanged ink do the rest, and the wash is tuned so `ink3` times still read at 4.5:1 on it. Every secondary item on a selected row (time, unread time, count badge, star, pip, queued glyph, failed glyph, account ring) is in the contrast table against both washes.

**Focus.** A {{border.focusRing.width}} pt ring in `focus` ({{border.focusRing.widthHC}} pt in Increase Contrast), drawn outside the control, separated by a {{border.focusRing.gap}} pt gap in the surface colour ({{border.focusRing.gapAroundSheets}} pt around sheets and cards, {{border.focusRing.gapOnAccentFill}} pt around anything filled with `accentFill`, so the ring never touches a fill of the same hue). It follows the control's corner radius plus the gap and is never animated. Fields use the same ring; a focused field never shows focus only as a 1 pt colour change. **Borderless field rows** (the composer's From, To, Cc, Bcc and Subject rows) have no edge to draw outside, so their ring is drawn **inset**, around the value area: from x = {{layout.composer.focusRingX}} ({{layout.composer.valueX}} − 6) to {{layout.composer.fieldTrailing}} pt before the row's trailing edge ({{layout.composer.focusRingButtonGap}} pt before the Cc / Bcc buttons while they show), its outer edge {{layout.composer.focusRingInsetY}} pt inside the row's top and bottom, radius `r.sm` (§5.20). **One exception:** the composer body, a full-pane multi-line text view, shows focus by its insertion point (`accent`, asserted ≥ 3:1 on `sheet`) and its selection, as every macOS text view does; a ring around it would frame the whole window. No other focusable element is exempt. List rows and rail items show focus through the selection itself (the native Mac list convention); with Full Keyboard Access on and an empty selection the list draws the ring inset by {{border.focusRing.width}} pt. On the slip, the ring is `onSlip` (`border.focusRing.onSlipColor`). Native SwiftUI controls are never left with the system ring (its alpha falls below 3:1 on `canvas`): Settings draws this ring itself (§8.3).

### 4.2 Account inks

Ten inks, assigned in this order as accounts are added, changeable per account in Settings › Accounts. Each mode has its own value: ≥ {{accountRules.standardMinContrast}}:1 against `paper`, `paper + hover`, `selWash`, `selWashIdle`, `spine`, `spine + hover`, `sheet`, `canvas` and `raised` in standard contrast, and ≥ {{accountRules.icMinContrast}}:1 against the IC surfaces in Increase Contrast (each account pair in `contrastPairs` carries `need` {{accountRules.standardMinContrast}} and `needIC` {{accountRules.icMinContrast}}, asserted per mode). These are every surface a ring, dot, square, swatch or tile edge is ever drawn on: a pressed rail tile keeps the hover wash under its ring and darkens only the {{layout.rail.face}} pt face (§5.2), so `spine + pressed` never sits under an account ink; and inside a popup (the composer's From dot, the Settings Colour swatch) the dot or swatch keeps a {{layout.popup.inkHalo}} pt `raised` halo (`layout.popup.inkHalo`), so when the popup face takes `raised + hover` or `raised + pressed` the wash stops at the halo and the ink still meets `raised` (§5.27). `raised + hover` and `raised + pressed` therefore never sit under an account ink either. Light and dark values of one account keep the same hue, so the rail tile, the row ring and the kicker dot always read as one colour.

{{TABLE:accounts}}

**Colour vision.** CIEDE2000 between every pair, after simulating protanopia, deuteranopia and tritanopia at full severity (Machado 2009, linear sRGB). The order was searched so the first six stay as far apart as possible for every vision type and the first two are the farthest pair; accounts 7–10 are chosen for normal-vision separation.

{{TABLE:cvd}}

**Distance from the colours with meaning.** No account ink is red, none sits within {{accountRules.minFromAccentNormal}} ΔE of Iron Gall for normal vision, none within {{accountRules.minFromDangerAnyVision}} ΔE of danger under any simulation, none within {{accountRules.minFromInfoNormal}} of info or {{accountRules.minFromStarNormal}} of the star. These are build-time assertions (§8.7).

{{TABLE:refs}}

**Distinct colours are promised for {{accountRules.promisedDistinct}} accounts.** Identity never rests on colour alone:

- the reader kicker names the account in words next to its ink dot (the open conversation's account is always readable);
- the rail shows each account's monogram and `⌘1…⌘9` order; the list masthead shows the address when narrowed to one account;
- the row's VoiceOver label ends with the account name, and the avatar's tooltip names it;
- Settings › General › Rows › **Show account initials in unified views** adds a {{layout.row.accountTile}} pt initial tile before the time: no fill of its own (transparent, so the row's fill, rest, hover or either selection wash, shows through), the monogram's first letter in `tag` `ink2`, and a {{layout.row.accountTileBorder}} pt edge in the account ink. It turns on automatically, once, when a {{layout.badge.autoInitialsAt}}th account is added, and Settings says why (an info banner in Accounts and a caption under the checkbox in General, §5.40);
- compact density marks the account with a {{layout.rowCompact.accountSquare}} pt **square** filled with the account ink, kept apart from the round unread pip by shape.

The square and the tile's edge are drawn in the account ink, never in `ruleStrong`; they are covered by the account-ink pairs (every ink against `paper`, `paper + hover`, `selWash` and `selWashIdle`, §7), and the tile's letter by the `ink2` pairs on the same four fills.

**Monograms.** Each account's monogram derives from its domain: the first letter of the registrable label (`contoso.com` → C, `fabrikam.co.uk` → F); consumer domains use the provider letter (`gmail.com`, `googlemail.com` → G; `outlook.com`, `hotmail.com`, `live.com`, `msn.com` → O, and their regional domains such as `hotmail.co.uk`). On a collision the monogram becomes two letters: the first letter plus the first letter of the address's local part (two Gmail accounts → “Ga”, “Gm”), or, for two custom domains, the first two letters of the label (“Co”, “Cl”); when those agree too, the letter where the labels first differ (`contoso` and `cobalt` → “Cn”, “Cb”; `demo-gmail` and `demo-outlook` → “Dg”, “Do”), and for two addresses on one domain the local parts' letters (“Ca”, “Cs”), so every derived monogram is unique. Collisions are resolved in the rail's order (oldest account first), never in the order a surface happens to hold the accounts. The user can edit it in Settings (max {{layout.settings.monogramMaxLength}} characters); a typed monogram always wins, and a derived letter it takes becomes two letters. The Monogram field's placeholder is what the account would derive with its own monogram cleared. The initial tile shows the first letter of the monogram the account shows.

**Account names.** Where the account is named in words (the kicker, the sync line and its tooltip, rail tooltips, the title menu, row VoiceOver labels, notifications, Settings), the name is the provider for a consumer address (“Gmail”, “Outlook”) and otherwise the registrable label as words in title case (“Contoso”, “Demo Outlook” for `demo-outlook.test`). Nothing is stored: monograms and names are derived by one SSCore helper, `AccountLabels`, which every surface asks, so an account wears the same monogram and name everywhere.

### 4.3 Avatar tints

Sender avatars use eight soft tints chosen by a stable hash of the lowercased address (FNV-1a 32-bit, modulo {{platform.avatarTintCount}}). Faces never take account colour, so a sender looks the same in every account. Initials: New York Semibold at {{typography.monogram.sizeRatio}} × the diameter (never below {{typography.monogram.minSize}} pt), or under the SF Pro font (§4.4) the twin `monogramSans`, SF Pro Semibold at {{typography.monogramSans.sizeRatio}} × the diameter (never below {{typography.monogramSans.minSize}} pt); at most two letters (first and last word of the display name, else the first alphanumeric of the address), in the tint's own ink. v1 faces are initials only: no Contacts access, no remote avatars, so no photo source exists and nothing on the face ever arrives late.

{{TABLE:avatars}}

### 4.4 Typography

System families only: **SF Pro** (`NSFont.systemFont`, CSS `-apple-system, system-ui`), **New York** (`NSFontDescriptor.SystemDesign.serif`, CSS `ui-serif`), **SF Pro Rounded** (`.rounded`, CSS `ui-rounded`), **SF Mono** (`NSFont.monospacedSystemFont`, CSS `ui-monospace`). No bundled or web fonts. No UI text is smaller than {{platform.minTextSize}} pt.

{{TABLE:type}}

**Sans twins.** New York covers Latin, Greek and Cyrillic. Every New York role has an SF Pro twin with the **same line height** and a smaller size (SF Pro's larger x-height makes it look the same size), used when New York cannot set the text and, under the SF Pro font, everywhere:

{{TABLE:twins}}

**Weight variants.** A role has exactly one weight unless a variant is listed here; each variant keeps its base role's size, line height and tracking. The generator emits them as roles (`QuireFont.bodyStrong`, `--q-font-bodyStrong`), so no component asks for “`body` at Semibold”.

{{TABLE:variants}}

**Button labels** use roles, never bare sizes: small `label` / `labelStrong`, regular `bodyMedium` / `bodyStrong`, large `buttonLarge` / `buttonLargeStrong` (the strong role for primary and destructive buttons; `layout.button.<size>.font` / `.fontStrong`).

Rules:

- **Read in serif, write in sans.** Composer and quick-reply bodies use `writing` (SF Pro) because what you type is sent without a font. Only the composer subject keeps the serif (`composeSubject`; its twin `composeSubjectSans` under the SF Pro font).
- **Script fallback.** A string is set in a New York role only if every letter in it is covered by New York's character set (`CTFontCopyCharacterSet` of the New York system font, computed once at launch). Otherwise the role's sans twin is used and the system cascade supplies the script (PingFang, Hiragino, Apple SD Gothic Neo, Geeza Pro, Arial Hebrew, Thonburi, Kohinoor Devanagari). The test runs when the row's attributed strings are built and is cached with them; the reader header runs it when the subject changes. Because twins keep the line height, row metrics never change; `RowMetricsTests` (§8.7) lays out CJK, Arabic, Hebrew, Thai and Devanagari samples and asserts the used height stays within the role's line height.
- **Bidirectional text.** Subjects, senders and snippets use natural writing direction with leading alignment (the UI's direction), so an Arabic or Hebrew subject reads right-to-left but stays flush with the column. CSS: `dir="auto"` with `text-align: start`.
- **Font setting.** Settings › General › Font: New York (default) or SF Pro. It picks the face of every New York role across the app. Under SF Pro each role is set in its sans twin wherever it appears, in AppKit, SwiftUI and the reader: `display` → `displaySans`, `headline` → `headlineSans`, `masthead` → `mastheadSans`, `reading` → `readingSans` (plain and unstyled bodies), `subject` → `subjectSans` (unread weight kept), `composeSubject` → `composeSubjectSans`, `aside` → `asideSans`, and `monogram` → `monogramSans` (§4.3, §5.29). Under New York the script fallback above still decides per string. A change applies live: every window on screen, the pre-rendered reader views and every open composer redraw in the new face at once, with no relaunch and no reselection. Twins keep the line height, so line heights and row metrics never change, no row is reloaded or re-measured and nothing moves vertically; only text widths follow the face, so the masthead takes its new width and the header items after it (the Demo tag, the search field's leading edge) shift with it. HTML mail with its own fonts is never restyled.
- **Unstyled bodies.** “Set like a page” applies to bodies classified at sync time, never at open. The sanitizer, which already walks the tree, stores one of three values with the body: `plain` (text/plain only), `unstyled` (HTML with no `<style>` blocks, no `font-family`, `font-size`, `color`, `background` or width declarations in `style` attributes, no `<font>` face/size/color, no `bgcolor`, no layout tables with explicit widths; only text structure such as `p`, `div`, `br`, `span`, `b`, `i`, `u`, `a`, `ul`, `ol`, `li`, `blockquote`, `pre`, `code`, `img`) or `styled` (everything else). Plain and unstyled bodies get `reading` (or `readingSans`) inside the {{layout.reader.measure}} pt measure; styled bodies keep their own fonts at full sheet width. The value also records whether the body's letters are covered by New York (same rule as above); if not, `readingSans` is used.
- **Tabular digits** (`.monospacedDigit` / `font-variant-numeric: tabular-nums`) for times, counts, badges, sizes and progress, so columns do not jitter during sync.
- **Tracking** is in points at the stated size: AppKit `.kern`, CSS `letter-spacing` in px. A tracking of 0 means the system's own optical tracking. `runningHead` is uppercased at string-build time (`uppercased(with: locale)`).
- **Line height** is exact. AppKit: `NSParagraphStyle.minimumLineHeight = maximumLineHeight = role line height`, `baselineOffset = (lineHeight − font line height) / 2` where the font line height is `NSLayoutManager().defaultLineHeight(for: font)`. CSS: `line-height` in px. AppKit and the reader then agree to the point.
- **Weights.** Regular 400, Medium 500, Semibold 600, only through the roles and variants above. Bold is not used (the alert title is system-drawn). Unread is Semibold (`unreadWeight`, and `metaStrong` for the unread time) so truncation moves little.
- **Truncation** is single line, tail, no tightening (`allowsDefaultTighteningForTruncation = false`); attachment names truncate in the middle to keep the extension.
- **Mapping from today's eight ad-hoc sizes:** 10 → `meta` or `runningHead` (11); 11 → `meta`; 12 → `snippet` or `label`; 13 → `body` or `sender`; 14 → `writing` or `subject`; 15 → `title` or `reading`; 17 and 26 → `aside` and `headline`.

### 4.5 Spacing

A 4 pt base with two optical half-steps. Use only these steps:

{{TABLE:space}}

Layout constants that are not on the scale (row {{layout.row.height}}, avatar box {{layout.row.avatarBox}} at x {{layout.row.avatarBoxX}}, text column {{layout.row.textX}}) are component metrics and live under `layout` with their components. Key rhythms: list inset {{layout.list.inset}}; reader column margins at least {{layout.reader.columnMinMargin}}; sheet padding {{layout.reader.sheetPadTop}} / {{layout.reader.sheetPadX}} / {{layout.reader.sheetPadBottom}}; stack-to-sheet gap {{layout.reader.stackGap}}.

### 4.6 Radii

{{TABLE:radius}}

Every `radius` metric under `layout` is one of these values; the build fails otherwise. The only exceptions are tied to a size: the margin rule's {{border.marginRule.radius}} corners, the {{layout.rowCompact.accountSquareRadius}} pt corners of the {{layout.rowCompact.accountSquare}} pt compact account square, and the {{layout.progress.barRadius}} pt ends of the {{layout.progress.barHeight}} pt progress bar (a pill). Window corners are the system's. AppKit uses `cornerCurve = .continuous` for rail tiles and panels and circular arcs for pills.

### 4.7 Borders and hairlines

- **Hairline** = one device pixel (`1 / backingScaleFactor` pt, {{border.hairline.points2x}} pt on Retina), colour `rule`: row separators (from x = {{layout.row.separatorX}}; hidden on the selected row and the row above it), pane dividers, header bottoms, sheet and stack edges, composer field rows. Increase Contrast draws hairlines at {{border.hairline.widthHC}} pt (`border.hairline.widthHC`).
- **Strong edge** = {{border.strong.width}} pt `ruleStrong`: fields, search, checkbox and radio, toggle-off track, toggle knob, secondary buttons, popups, tags, the quick-reply field. Drawn at rest in every mode.
- **Tab underline** = {{border.tabUnderline.width}} pt `ink` (`ink3` when the window is not key), sitting on the header hairline; the quick reply's active mode uses the same underline under its label.
- **Margin rule** = {{border.marginRule.width}} pt wide, corner radii {{border.marginRule.radius}} (leading corners square), flush with the pane's leading edge.
- **Error edge** = {{border.error.width}} pt `danger`, always with a glyph and a help line.
- **Account ring** = {{border.accountRing.width}} pt in the account ink outside a {{border.accountRing.gap}} pt gap in the surface colour.

### 4.8 Elevation

Paper is flat. Only things that float cast shadows; rows, the rail and the list never do. AppKit gives every shadowed layer an explicit `shadowPath`; two-shadow levels use a container layer (key shadow) plus one sublayer (contact shadow). CSS blur = 2 × `CALayer.shadowRadius`. The AppKit offsets below are for a bottom-up layer; the window server applies a flipped view's geometry to the shadow offsets of every layer in its tree, so in a flipped view (every Quire component is one) the same downward shadow is (0, +6). Only a window-server capture shows the direction truthfully: `cacheDisplay` renders some flipped hierarchies the other way. Increase Contrast keeps the shadows and adds the `ruleStrong` edge (`border.icOutline`) to sheets, the stack, autocomplete, the link popover and the cheat sheet; slips use their own `slipEdge`. A shadowed `NSPanel` (the undo-send panel) is transparent and larger than what it draws, by `layout.undoPanel.shadowMargin*`, so the shadow is never clipped. The toggle knob's static contact shadow is a control detail, not a level: `layout.toggle.knobShadow`.

{{TABLE:elevation}}

### 4.9 Materials

| Region | Material | Reduce Transparency | Why |
|---|---|---|---|
| Account rail | none: opaque `spine` | same | Badge, ring and glyph contrast must not depend on the wallpaper |
| Title-bar zones, list, reader, composer | none: opaque `paper` / `canvas` / `sheet` | same | Pages are opaque; opaque headers never re-blur during scroll |
| Toast, undo-send panel, HUD | none: opaque `slip` | same | Fixed contrast for the action text |
| Cheat-sheet overlay | `scrim` over the window (the one translucent app-drawn surface), opaque `raised` panel | `scrimSolid`, opaque: the window behind is hidden, not dimmed; the panel is unchanged | Fixed contrast; the scrim is a flat wash, never a blur, and Reduce Transparency takes away its see-through, not the overlay |
| Menus, alerts, tooltips, notifications, the Settings toolbar and its tabs | system materials | system | Native chrome |

There is no app-drawn vibrancy, no per-row blur and no `backdrop-filter` in the reader.

### 4.10 Motion

{{TABLE:motion}}

| Use | Duration | Curve | Reduce Motion |
|---|---|---|---|
| Toast in (rise {{layout.toast.rise}} pt + fade) | `dur.standard` | `ease.settle` | fade `dur.reducedFade` |
| Toast out, tooltip-like reveals, cross-fades | `dur.quick` | `ease.leave` | same (fades are kept) |
| Message expand / collapse, quoted text unfold, fold row expand, recipients expand / collapse (§5.14) | `dur.standard` | `ease.settle` | instant |
| Search field width (the field only; the list does not resize) | `dur.standard` | `ease.glide` | cross-fade `dur.reducedFade` |
| Quick-reply growth: the bar's height, drawn **over** the web view; the web view's frame never changes, only its bottom inset, once per height change | `dur.standard` | `ease.glide` | instant |
| Toggle knob travel | `dur.quick` | `ease.glide` | instant |
| Undo-send panel in (rise {{layout.undoPanel.rise}} pt + fade), welcome → inbox | `dur.slow` | `ease.settle` | fade `dur.reducedFade` |
| g-sequence HUD in / out (fade, no rise; in at `dur.gHudDelay`, out when the `dur.gSequenceWindow` ends, §5.32) | `dur.quick` in, `dur.quick` out | `ease.settle` / `ease.leave` | same |
| Cheat sheet in: scrim fade + panel fade and scale 0.98 → 1 | `dur.standard` (scrim `dur.quick`) | `ease.settle` | fade only, `dur.reducedFade` |
| Cheat sheet out | `dur.quick` | `ease.leave` | same |
| Header hover actions and the sender address appearing on hover (fade) | `dur.quick` in, instant out | `ease.settle` | same |
| Link popover in / out (fade) | `dur.quick` | `ease.settle` / `ease.leave` | same |
| Undo countdown and toast lifetime (the contrail) | the window itself | `ease.linear` | steps once per second |
| Spinner | `dur.spinnerTurn` per turn | `ease.linear` | keeps turning |
| Instant, always: rail show / hide (the split view snaps; no pane resizes over frames), autocomplete open / close and row highlight, skeleton → content in the list and in a sheet, format row show / hide, Settings tab switches (system), badge and count changes | `dur.instant` | — | — |

Rules:

- **The list never animates, and nothing resizes it over frames.** Selection, `j`/`k`, opening a conversation (an instant swap of a pre-rendered view), scrolling, rows arriving or leaving through sync, archive and trash removal (the next row takes the place in the same frame), star and unread changes, counts and badges: all instant. The rail toggle is instant for the same reason: animating the split view would re-lay out and re-truncate every visible row and re-measure every iframe on each frame. The toast carries the feedback.
- **The keystroke finishes motion.** Every key press first calls `finishAll()`, which jumps running animations to their end state (`CATransaction` with actions disabled on the presentation values, CSS transitions set to their end), then applies the new action. Holding `j` never queues motion.
- **Expanding a message: animate to a provisional height, then snap.** A body iframe is created on expand and sizes itself only after it loads (the shell measures at 0, 50 and 300 ms and on every image load), and CSS cannot transition to `height: auto`. So the body wrapper animates, over `dur.standard` `ease.settle`, from the collapsed {{layout.reader.stackRow}} pt row to header + **provisional body height** + footer, where the provisional height is the body's last measured height for this message at this content width (the shell keeps it, per message id and width, for the session), or else the skeleton's height (three {{layout.skeleton.bodyBarHeight}} pt bars {{layout.skeleton.bodyBarGap}} pt apart = 58 pt) with the skeleton drawn in it. When a measurement arrives, mid-animation or later, the wrapper **snaps** to it without animation (transition removed for that frame), and so does every later re-measure; when the animation ends the wrapper is set to the measured height in px (never `auto`, so the next collapse has a start value). Collapse animates from the current height to {{layout.reader.stackRow}} pt and detaches the iframe at the end. `finishAll()` jumps a running expand to its provisional (or measured) end state and a collapse to its collapsed state. Reduce Motion: no height animation; the sheet appears at the provisional height and snaps when measured. The quoted-text unfold and the fold row use the same rule with their own measured heights.
- **Interruptible.** Every animation starts from the current presentation value (`fromValue = layer.presentation()`, `NSAnimationContext` with `allowsImplicitAnimation`, CSS transitions re-targeted). Nothing blocks input while it animates. Nothing exceeds `dur.slow`. Nothing loops except progress indicators; skeletons never shimmer.
- **The contrail means time is moving.** It is the only drawn element for elapsing time: the undo-send countdown (in the panel and in the quick-reply strip, always next to the seconds as text), the toast's lifetime (pauses while the pointer rests on the toast), the sync line's download progress and the attachment upload/download progress. It is never decoration.
- **Reduce Motion.** Rises, slides, scales, height changes and width changes become a `dur.reducedFade` cross-fade or are instant, as the table's last column says; fades stay. The contrail steps once per second instead of draining continuously, and every countdown also shows its seconds as text (“Sending in 4 s”), in AppKit and the reader alike. Spinners keep turning (they are essential and small).

### 4.11 Iconography

SF Symbols, monochrome; status glyphs use the `.fill` variant in their semantic colour.

**Defaults** (`layout.iconSize`), Regular weight unless noted: {{layout.iconSize.window}} pt for window-level icon buttons (reader header actions, the composer bar, the rail's Add and Settings); {{layout.iconSize.inText}} pt inside text buttons, chips, banners, tool rows and format toggles; {{layout.iconSize.row}} pt **Semibold** in rows and the sync line (so the small size holds up); {{layout.iconSize.rail}} pt for the rail's All Inboxes glyph. **Exceptions**, each a named metric of its component and the only other sizes in use: the compose button's `ss.nib` at {{layout.listHeader.composeGlyph}} pt (`listHeader.composeGlyph`: the list header's one verb, sized against the {{typography.masthead.size}} pt masthead on its line); the rail's folder symbols at {{layout.rail.folderGlyph}} pt (`rail.folderGlyph`: SF Symbols fill more of their box than the custom `ss.quire`, so 16 pt reads as the same size beside it); the masthead chevron at {{layout.listHeader.chevron}} pt **Semibold** (`listHeader.chevron`: a disclosure mark, Semibold so 9 pt holds); popup chevrons at {{layout.popup.chevron}} pt (`popup.chevron`); the attention badge's `exclamationmark` at {{layout.badge.attentionGlyph}} pt **Semibold**; dismiss and remove `xmark` at {{layout.banner.dismissGlyph}} pt (`banner.dismissGlyph`, `composer.removeGlyph`, `search.clearGlyph`); the sheet's header hover actions at {{layout.reader.headerActionGlyph}} pt on {{layout.reader.headerAction}} pt buttons (`reader.headerActionGlyph`); the toast glyph at {{layout.toast.glyph}} pt and the undo panel's at {{layout.undoPanel.glyph}} pt. The Settings toolbar tabs are system-drawn at the system's size.

Glyph colour: `ink2` at rest, `ink` on hover and press, `inkDisabled` when disabled; the star is `star` **and** filled when on. Menu items carry their symbol leading in `ink2`.

| Action | Symbol | Shortcut |
|---|---|---|
| Archive | `{{icon.archive}}` | E |
| Move to Trash | `{{icon.trash}}` | # |
| Move to Inbox (in Trash) | `{{icon.moveToInbox}}` | ⇧I |
| Star / Unstar | `{{icon.star}}` / `{{icon.unstar}}` | S |
| Mark as Unread / Read | `{{icon.markUnread}}` / `{{icon.markRead}}` | U |
| Reply / Reply All / Forward | `{{icon.reply}}` / `{{icon.replyAll}}` / `{{icon.forward}}` | R / A / F |
| New Message | `{{icon.compose}}` (custom) | C, ⌘N |
| Search | `{{icon.search}}` | / or ⌘F |
| Undo | `{{icon.undo}}` | Z or ⌘Z |
| Send | `{{icon.send}}` (button), `{{icon.sendPanel}}` (undo panel) | ⌘↩ |
| Attach | `{{icon.attach}}` | ⇧⌘A |
| Format (toggles the format row) | `{{icon.format}}` | ⇧⌘T |
| Bold / Italic / Underline | `{{icon.bold}}` / `{{icon.italic}}` / `{{icon.underline}}` | ⌘B / ⌘I / ⌘U |
| Bulleted list / Numbered list / Quote | `{{icon.bulletedList}}` / `{{icon.numberedList}}` / `{{icon.blockQuote}}` | ⇧⌘8 / ⇧⌘7 / ⌘' |
| Link | `{{icon.link}}` | ⌘K |
| Open in composer | `{{icon.openInComposer}}` | ⇧⌘R |
| Load images | `{{icon.loadImages}}` | ⇧⌘I |
| Original colors | `{{icon.originalColors}}` | ⇧⌘O |
| Show / Hide quoted text | `{{icon.quotedText}}` (custom) | . |
| Quick Look the target message's attachments | — (system Quick Look) | Space (§6) |
| All Inboxes | `{{icon.unifiedInbox}}` (custom) | ⌘0 |
| Account N | monogram | ⌘1…⌘9 |
| Add account / Settings | `{{icon.addAccount}}` / `{{icon.settings}}` | — / ⌘, |
| Provider choice (add-account menu items, welcome buttons) | `{{icon.addAccountProvider}}` | — |
| Attention badge (rail tile needs sign-in) | `{{icon.attention}}` ({{layout.badge.attentionGlyph}} pt, `.semibold`, `onDanger`) | — |
| Waiting to sync (Settings account status) | `{{icon.waitingToSync}}` | — |
| Discard Draft (Drafts reader, composer Message menu) | `{{icon.discardDraft}}` | # in Drafts |
| Remove account (Settings) | `{{icon.removeAccount}}` | ⌫ in the account list |
| Show / hide rail | `{{icon.toggleRail}}` | ⌃⌘S |
| Title menu (minimal mode) / popup | `{{icon.titleMenu}}` / `{{icon.popup}}` | — |
| Views (the rail's folder tiles, the title menu, View menu): Inbox, Starred, Sent, Drafts, Trash, All Mail | `{{icon.viewInbox}}`, `{{icon.viewStarred}}`, `{{icon.viewSent}}`, `{{icon.viewDrafts}}`, `{{icon.viewTrash}}`, `{{icon.viewAllMail}}` | G I, G S, G T, G D, G #, G A |
| Queued locally (row) | `{{icon.pending}}` (custom) | — |
| Operation failed (row), error, sign-in | `{{icon.failed}}` | — |
| Up to date / Offline / Retrying / Retry | `{{icon.upToDate}}` / `{{icon.offline}}` / `{{icon.retrying}}` / `{{icon.retry}}` | — |
| Remove (token, attachment) | `{{icon.remove}}` | ⌫ |
| Files | `{{icon.file}}`, `{{icon.fileText}}`, `{{icon.fileImage}}`, `{{icon.fileSheet}}`, `{{icon.fileArchive}}`, `{{icon.fileVideo}}` | — |
| More | `{{icon.more}}` | — |
| Settings tabs (system toolbar) | `{{icon.accountsTab}}`, `{{icon.oauthTab}}`, `{{icon.generalTab}}` | — |
| Undo confirmation (toast) | `{{icon.undone}}` | — |
| Privacy note / success / info | `{{icon.privacy}}` / `{{icon.success}}` / `{{icon.info}}` | — |
| Show / hide a secret (the secure field's reveal button, §5.25) | `{{icon.reveal}}` / `{{icon.conceal}}` | — |

The full action-to-symbol map is `icon` in `tokens.json`: every symbol the app draws is in it, and a symbol that is not in it is not used.

**Custom glyphs (five of the six allowed; one slot stays free).** Drawn on the stated grid, round caps and joins, in the current colour. They scale with point size (grid units × point size / grid). Exact SVG path data (y down):

`ss.quire` — All Inboxes, a gathering of letters. {{GLYPH:ss.quire:grid}} × {{GLYPH:ss.quire:grid}} grid, stroke {{GLYPH:ss.quire:stroke}}, no fill.
```
{{PATH:ss.quire}}
```

`ss.nib` — New Message, a pen nib. {{GLYPH:ss.nib:grid}} × {{GLYPH:ss.nib:grid}} grid, stroke {{GLYPH:ss.nib:stroke}}, plus a filled circle (the vent) {{FILLS:ss.nib}}.
```
{{PATH:ss.nib}}
```

`ss.elide` — Show / Hide quoted text, the editor's `[…]`. {{GLYPH:ss.elide:grid}} × {{GLYPH:ss.elide:grid}} grid, stroke {{GLYPH:ss.elide:stroke}}, plus three filled circles {{FILLS:ss.elide}}.
```
{{PATH:ss.elide}}
```

`ss.queued` — queued locally: the change is applied on this Mac and waiting to reach the server. A dot (here) and a straight arrow (on its way), with clear space between them. It is static, has no circle and never rotates, so it cannot be read as a spinner or as refresh; rows never show spinners. {{GLYPH:ss.queued:grid}} × {{GLYPH:ss.queued:grid}} grid, stroke {{GLYPH:ss.queued:stroke}}, plus a filled circle {{FILLS:ss.queued}}.
```
{{PATH:ss.queued}}
```

`ss.sparrow` — brand mark (welcome, app icon, About, inbox zero, alerts and notifications through the app icon). {{GLYPH:ss.sparrow:grid}} × {{GLYPH:ss.sparrow:grid}} grid, filled, even-odd (the wing and the eye are holes).
```
{{PATH:ss.sparrow}}
```

AppKit builds each once as a `CGPath` in grid units (a small SVG-path parser for `M L H V C A Z` and relative forms, unit-tested), scales it with an affine transform and renders it into a template `NSImage` (`isTemplate = true`) cached per point size, so it tints like a symbol. The reader inlines the same paths as `<svg viewBox>`.

**SF Symbols in the reader.** WKWebView cannot draw SF Symbols, and redrawing them as SVG is not allowed. At shell creation the app rasterises exactly the symbols the shell draws (`readerSymbols`, audited against §5.13–5.19; a reader glyph not on this list has no legal way to be drawn, so adding one to the shell means adding it here):

| Symbol | Drawn by the shell in |
|---|---|
| `star` | sheet header hover action, off (§5.14) |
| `star.fill` | hover action on; the starred mark on the name line and in stack rows (§5.13, §5.14) |
| `arrowshape.turn.up.left` | hover Reply; footer Reply (§5.14) |
| `arrowshape.turn.up.left.2`, `arrowshape.turn.up.right` | footer Reply all, Forward |
| `ellipsis` | hover More (§5.14) |
| `circle.lefthalf.filled` | hover Original colors; the Original colors notice glyph (§5.16) |
| `xmark` | the Original colors notice's dismiss button, {{layout.banner.dismissGlyph}} pt (§5.16) |
| `photo` | remote-images banner glyph (§5.16); image attachment tile (§5.17) |
| `exclamationmark.triangle.fill` | partial image failure, attachment error, body-failed banner (§5.14, §5.16, §5.17) |
| `wifi.slash` | the body-not-downloaded-while-offline notice (§5.14) |
| `doc`, `doc.richtext`, `tablecells`, `doc.zipper`, `film` | attachment type tiles (§5.17) |

The quoted-text toggle and the folded original use the custom `ss.elide` (inline SVG); spinners and skeleton bars are CSS; keycaps are text. Each symbol is rasterised with `NSImage(systemSymbolName:)` + `SymbolConfiguration(pointSize: {{platform.readerSymbolPointSize}}, weight: .regular)` at {{platform.readerSymbolScale}}× into black-on-clear PNGs on a square canvas {{platform.readerSymbolCanvas}} × the point size, encodes each once as a `data:` URI and passes them to the shell builder, which emits them as CSS custom properties (`--sym-xmark: url(data:…)`). The shell draws them as `mask-image` with `background: currentColor`, so they take any token colour in any appearance. The specimen uses exactly this pipeline.

### 4.12 Density

| | Standard (default) | Compact (View › Compact Rows, ⌥⌘C) |
|---|---|---|
| Row height | {{layout.row.height}} | {{layout.rowCompact.height}} |
| Lines | sender · time / subject / snippet | sender · time / subject — snippet |
| Avatar | {{layout.row.avatarFace}} pt face in a {{layout.row.avatarBox}} pt box | none |
| Account mark (unified views) | {{border.accountRing.width}} pt ring (+ optional initial tile before the time) | {{layout.rowCompact.accountSquare}} pt square before the time; with **Show account initials** on, the {{layout.row.accountTile}} pt initial tile **replaces** the square (it carries the colour and the letter) |
| Text column | x = {{layout.row.textX}} | x = {{layout.rowCompact.textX}} |
| Running head | {{layout.runningHead.height}} pt, label x {{layout.runningHead.labelX}} | {{layout.runningHead.compactHeight}} pt, label x {{layout.runningHead.compactLabelX}}, y {{layout.runningHead.compactLabelY}}, rule y {{layout.runningHead.compactRuleY}} |
| Skeleton row | circle + four bars (§5.10) | no circle; sender, time and line-2 bars (`layout.rowCompact.skeleton*`) |
| List tail footer | {{layout.listFooter.height}} pt | {{layout.listFooter.height}} pt |

The reader has one density.

### 4.13 Voice and microcopy

- **Plain, short, calm.** No exclamation marks, no “Oops”, no emoji, no “please”.
- **Casing follows the surface, not the control.** **Title case** where macOS itself names commands: menu items (including context menus and the More menu), alert and sheet buttons, popover buttons, window and panel titles, tooltips (they repeat the command's menu name), and buttons in Settings. **Sentence case** for everything set inside a content surface: the list (empty states, the tail footer), the reader (banners and their actions, the quoted-text toggle, footer buttons, the quick reply, its tabs and its strip), the composer's content (field labels, status, the drop label; its one chrome button is “Send”), slips (toast and undo-panel actions), the g-sequence HUD and the keyboard cheat sheet (their labels describe what a key does rather than naming a menu command: “Mark as unread · read”, “Show · hide quoted text”, “Move to Trash”, where Trash is a proper name; the overlay's title “Keyboard Shortcuts” is a panel title and stays title case), the welcome screen, banners in any window (Settings included), status lines and captions. Proper names keep their capitals (Settings, Gmail, Microsoft 365, Quick Look, Trash, Inbox). Sentence-like links stay sentences (“How to create one…”, “Set up OAuth clients…”). One command can therefore appear in both forms, deliberately: Message › Reply All and the tooltip “Reply All  A”, but the footer button “Reply all”; View › Load Images and the banner action “Load images”; Message › Discard Draft… and the Drafts footer “Discard draft…”.
- **Verbs on buttons.** “Send”, “Discard”, “Reconnect”, “Load images”. Never “OK” when a verb exists.
- **Past tense plus one remedy** in toasts: “Archived · Undo”, “Moved to Trash · Undo”, “Moved to Inbox · Undo”, “Unstarred · Undo” (in Starred, where the row leaves the view), “Marked 3 as unread · Undo”. Coalesced: “Archived 3 conversations”. Only actions that take a row out of view, or change several rows at once, get a toast; starring or marking one conversation unread does not, because the row itself shows the change.
- **An undo confirms itself** with an action-less toast naming the undone command as Edit › Undo does: “Undid Archive”, “Undid Move to Trash”, “Undid Mark as Unread” (`arrow.uturn.backward`, {{motion.duration.toastConfirm}} ms, §5.30).
- **Errors say what happened and what happens next:** “Couldn't reach Gmail · retrying in 30 s”, “Sign in required · Reconnect”, “Couldn't send · Open draft”, “Couldn't archive. Restored.” Never blame the user.
- **The separator** is the middle dot with spaces ( · ). The ellipsis is the single character (…), for commands that ask for more (“Add Account…”) and for ongoing work (“Sending…”).
- **Numbers** use the locale's grouping (“3,412 of 8,120”) and a space before units (“240 KB”, “4 s”).
- **Times** follow the system 12/24-hour setting and the locale's day and month order. Rows under running heads show what the head leaves out:

| Running head | Row time |
|---|---|
| Today, Yesterday | time of day: “23:39” |
| Earlier this week | weekday: “Tue” |
| Last week, a month (“October”), a month of an earlier year (“October 2025”) | day and month: “27 Oct”, “30 Oct” (the year is in the head) |
| No heads (search results, views under {{layout.runningHead.minConversations}} conversations) | today “23:39”, yesterday “Yesterday”, this week “Tue”, this year “30 Oct”, older “30 Oct 2025” |

  The reader shows “Yesterday 23:39”, “Fri 30 Oct”, “30 Oct 2025”.
- **Sender lines by view:** Drafts “Draft to Ben Carter”, Sent “To Ben Carter” (the prefix in `ink2`).
- **Empty states** are one serif sentence and one hint: “Nothing left to read.” / “New mail will land here.” Every view and reader state has its pair in §5.9.
- **Privacy copy** is literal: “Your mail is stored on this Mac and travels only between this Mac and Google or Microsoft.”
- **VoiceOver announcements** repeat the toast: “Archived. Press Z to undo.”, “Undid Archive.”
- **Demo copy** says what is made up and where it lives: “Demo mode: these mailboxes are made up and live only on this Mac.”

### 4.14 Accessibility summary

- Contrast: every text pair ≥ 4.5:1 and every essential non-text pair ≥ 3:1, in all four modes, over every surface and state overlay the components produce (§7). Disabled controls are exempt and use `inkDisabled`.
- Minimum text size {{platform.minTextSize}} pt; avatar initials never below {{typography.monogram.minSize}} pt.
- Hit targets: at least {{layout.button.minHit}} × {{layout.button.minHit}} pt for every pointer target, enlarging the hit rect where the visual is smaller (search clear, attachment and token remove, small buttons, link buttons, header hover actions, the notice dismiss button, Settings +/−); rail tiles {{layout.rail.tileHit}} pt, rows full width.
- Full keyboard operation; every focusable element shows the ring (§4.1).
- VoiceOver rows: “Unread. Starred. Priya Raman. Lisbon in March? Booked the flat… 22:10. 3 messages. Gmail account.” Queued rows add “Waiting to sync”; failed rows add “Couldn't archive”. Running heads are headings. Custom glyph buttons carry the action name as `accessibilityLabel`.

| State | Colour cue | Non-colour cue |
|---|---|---|
| Unread | Iron Gall pip and time | the pip's presence, Semibold sender, subject and time |
| Selected | `selWash` | {{border.marginRule.width}} pt margin rule, always drawn |
| Autocomplete highlight | `selWash` | {{border.marginRule.width}} pt margin rule (never a solid accent block) |
| Window not key | `selRuleIdle` | grey traffic lights, rule colour, idle wash |
| Starred | `star` | filled star vs outline |
| Queued locally | `ink3` glyph | `ss.queued` shape, VoiceOver “Waiting to sync” |
| Operation failed | `danger` glyph | triangle shape, toast text |
| Account | ring ink | kicker words, monogram, optional initial tile, compact square, tooltip, VoiceOver |
| Invalid address | `danger` wash and edge | triangle glyph inside the token |
| Error | `danger` | glyph and words |
| Toggle on | `accentFill` track | knob position: the knob carries a {{layout.toggle.knobEdge}} pt `ruleStrong` edge, ≥ 3:1 against the off track on a group and on the desk; nothing ever washes the track or the knob (a press stretches the knob), so the cue holds in every state |
| Checkbox / radio on | `accentFill` (hover `accentFillHover`, pressed `controlOnPressed`) | the checkmark, mixed bar or dot shape |
| Quick-reply mode | `ink` label | {{border.tabUnderline.width}} pt underline, Semibold (`labelStrong`) |
| Target message (R, A, F, Space) | — | R · A · F keycaps beside its footer buttons; a `ruleStrong` sheet edge when several messages are open |
| Missing subject or sender | `ink3` | italic, the words “No subject” / “No sender” |
| Demo mode | — | “Demo” tag text, window title, Settings banner words |
| Active tab | `ink` text | {{border.tabUnderline.width}} pt underline, Semibold |
| Focus | `focus` ring | ring shape, {{border.focusRing.widthHC}} pt in IC; inset ring on borderless composer rows; the insertion point in the composer body (§4.1); a Quire ring on links inside message bodies (§8.4) |
| Link button | `accent` label | position and verb; the underline on hover and press, and at rest under Graphite (§3.1) |

---
## 5. Components

Conventions: metrics in points; x and y from the component's top-leading corner; a row height includes its bottom hairline. Unless a component says otherwise its states are: **hover** = `hover` wash, glyph and text to `ink`, no animation; **pressed** = `pressed` wash (link buttons, checkbox and radio on fills and toggles have their own hover and press, §5.24 and §5.26, so that no wash ever pulls a state mark under its floor); **focused** = the focus ring (§4.1); **disabled** = `inkDisabled` text and glyph, no wash, no pointer feedback; **window not key** = only the marks listed in §3.4 change (selection wash and rule, the quick reply's mode underline, primary buttons, focus rings); every other mark, Iron Gall included, stays. Every metric table below is rendered from `layout.<component>` in `tokens.json`.

### 5.1 App window and title bar

Anatomy: rail ({{layout.rail.width}}; {{layout.rail.width26}} from macOS 26 on, §3.2) · list pane ({{layout.list.defaultWidth}} default, {{layout.list.minWidth}}–{{layout.list.maxWidth}}, user-resizable, autosaved) · reader (flexible). Pane dividers are hairlines with a {{layout.window.dividerHit}} pt `NSSplitView` hit area. Each pane paints its own background up to the top edge: rail `spine`, list and both headers `paper`, reader desk `canvas`.

{{TABLE:layout:window}}

| State | Treatment |
|---|---|
| Key | coloured traffic lights; Iron Gall selection, mode underline `ink`, primary buttons filled |
| Not key | system grey lights; exactly the §3.4 list changes (idle selection, `ink3` underlines, primary buttons as secondary, no focus ring); the unread pip and unread time, badges and every other mark stay |
| Full screen | traffic lights hidden by the system; layout unchanged, title-bar zone keeps {{layout.window.titlebarZone}} pt |
| Minimal mode (⌃⌘S, View › Hide Account Rail) | rail width 0, **instantly** in every mode (the split view snaps in one frame, so no row re-truncates and no iframe re-measures over frames); the masthead moves to x = rail width + {{layout.listHeader.mastheadMinimalGap}} ({{layout.listHeader.mastheadMinimalX}} on macOS 15, {{layout.listHeader.mastheadMinimalX26}} from macOS 26 on, §3.2) and becomes the title menu's button again (chevron, §5.4), with the views and an Accounts section, so every folder and account the rail held is still a click away; search and compose keep the header line and search takes the width that is left (§5.3); `⌘0…⌘9` and the G-sequences keep working |
| Live resize | the list keeps its width; the reader takes the change; the reader re-fits wide HTML (§5.14) once, when the resize ends |
| Narrow reader (< {{layout.window.readerNarrow}} pt) | column margins {{layout.reader.narrowColumnMargin}}, sheet padding x {{layout.reader.narrowSheetPadX}} (§5.14); below {{layout.window.readerKeycapsMin}} pt the reader's keycaps hide (§5.36) |

### 5.2 Account rail and its items

Anatomy, top to bottom: title-bar zone (traffic lights) · **the folders**, one tile per view in the title menu's order: Inbox at y = {{layout.rail.folderTop}}, then Starred, Sent, Drafts and Trash at a {{layout.rail.folderPitch}} pt pitch, a {{layout.rail.dividerWidth}} pt hairline at y = {{layout.rail.folderDividerY}}, and All Mail at y = {{layout.rail.allMailTop}} · flexible space · **the accounts**, anchored just above Add: the All Inboxes tile, a {{layout.rail.dividerWidth}} pt hairline {{layout.rail.dividerGap}} pt below it, then the account tiles from {{layout.rail.accountGap}} pt below the hairline at a {{layout.rail.accountPitch}} pt pitch · Add · Settings. Opaque `spine`, trailing hairline. All y values are top edges: Add's {{layout.rail.utility}} pt button has its **top** at bottom − {{layout.rail.addTopFromBottom}}, Settings' top at bottom − {{layout.rail.settingsTopFromBottom}}. The account stack's clip ends {{layout.rail.stackBottomGap}} pt above Add's top and the last tile ends {{layout.rail.stackInset}} pt inside it, so in the default {{layout.window.defaultHeight}} pt window with three accounts the last tile spans 652–690, the first starts at 552, the hairline is at 538 and All Inboxes starts at 484.

- **Folder tiles**: {{layout.rail.tile}} pt, radius `r.tile`, the view's symbol (`{{icon.viewInbox}}`, `{{icon.viewStarred}}`, `{{icon.viewSent}}`, `{{icon.viewDrafts}}`, `{{icon.viewTrash}}`, `{{icon.viewAllMail}}`) {{layout.rail.folderGlyph}} pt in `ink2`, with the All Inboxes tile's washes, raised selection and focus ring, but no margin rule: the rail carries two selections, the view (the raised tile) and the scope (the margin rule), and they must read apart. A click switches the view as the title menu does (§5.4); the G-sequences are unchanged. Inbox carries the unread count badge of the current scope's Inbox (all accounts, or the narrowed one; the count the title menu's Inbox item carries); the other folders carry none. Tooltips name the folder and its sequence: “Inbox  G I”, “Starred  G S”, “Sent  G T”, “Drafts  G D”, “Trash  G #”, “All Mail  G A”.
- **Dropping rows**: conversation rows dragged from the list (§5.7) drop on four folders: Inbox moves them to the Inbox, Trash trashes them, Starred stars them and All Mail archives them, exactly as ⇧I, #, S and E do on those conversations, as one change for every dragged row with that key's toast and Undo (in Drafts, Trash is Discard Draft…, asked first, as # is there; §5.12), except that Starred only ever stars. Sent, Drafts, All Inboxes, the account tiles and the utilities take no drop. A folder refuses a drop that would change nothing the list shows: the selected folder outside a search (its rows are already there; a search lists mail from every view, so then only the rows decide, except that Trash still refuses while selected, as # does nothing there), Inbox for rows all in the Inbox, Starred for rows all starred, All Mail for rows none of which is in the Inbox; a refused drag lights nothing and ends where it began. Only the list's own rows are taken: files, text and another app's drags are refused. A drag counts over the {{layout.rail.tileHit}} pt hit square, as a click does, and nowhere else: the folders' squares abut, so a drag at one square's rim never lands on its neighbour. The cursor shows a move, or a copy while ⌥ is held, following the modifiers as they change over a folder.
- **All Inboxes tile**: {{layout.rail.tile}} pt, radius `r.tile`, `ss.quire` {{layout.rail.unifiedGlyph}} pt in `ink2`; the first tile of the account group.
- **Account tile**: a {{layout.rail.face}} pt face (the account ink at {{layout.rail.faceAlpha}} opacity over `sheet`), the domain monogram in New York Semibold {{layout.rail.monogram}} pt ({{layout.rail.monogramTwoLetter}} pt for two letters; `monogramSans` under the SF Pro font, §5.29) in `ink`, and a {{border.accountRing.width}} pt ring in the account ink outside a {{border.accountRing.gap}} pt `spine` gap ({{layout.rail.tile}} pt overall).
- **Badge**: unread count badge (§5.28) at top {{layout.rail.badgeTop}}, trailing {{layout.rail.badgeTrailing}} relative to the tile, with a {{layout.badge.cutout}} pt `spine` cut-out ring.
- **Utilities**: {{layout.rail.utility}} pt icon buttons, `plus` / `gearshape` {{layout.rail.utilityGlyph}} pt. Add opens the add-account menu (§5.44).
- **Margin rule**: {{border.marginRule.width}} × {{layout.rail.marginRuleHeight}} pt at x = 0, centred on the selected account tile or All Inboxes; never on a folder.
- **Capacity.** The account group sits as low as it can and rises as accounts are added, until the All Inboxes tile would come closer than {{layout.rail.groupGap}} pt to All Mail's tile (its top at {{layout.rail.allMailTop}} + {{layout.rail.tile}} + {{layout.rail.groupGap}} = 352). From then on All Inboxes and its hairline stay there and the account tiles scroll inside their own clip view, from {{layout.rail.stackInset}} pt above the first tile (room for the badge overhang) down to {{layout.rail.stackBottomGap}} pt above Add's top. Without scrolling, one account fits at the {{layout.window.minHeight}} pt minimum height, five at the default {{layout.window.defaultHeight}} pt and seven at 900 pt. While tiles are clipped a `rule` hairline marks the clipped edge (bottom, and top once scrolled); the scroller shows only while scrolling; ⌘1…⌘9 and ↑/↓ scroll the chosen tile into view instantly. Tiles never overlap the folders or the utilities.

{{TABLE:layout:rail}}

| State | Folder tiles and All Inboxes | Account tile |
|---|---|---|
| Rest | glyph `ink2`, no fill | face + ring + monogram |
| Hover | {{layout.rail.tileHit}} pt `hover` wash, radius `r.xl`; tooltip “Inbox  G I”, “All Inboxes  ⌘0” | same wash (it sits under the ring; `spine + hover` is an asserted ring surface); tooltip “Contoso · alex@contoso.test  ⌘1” |
| Pressed | {{layout.rail.tileHit}} pt `pressed` wash | the hover wash stays and a `pressed` wash darkens only the {{layout.rail.face}} pt face, never the gap or the ring, so every account ink keeps ≥ 3:1 (≥ 3.5:1 in IC) against what is beside it |
| Selected | `raised` fill, `rule` edge, `e1`, glyph `ink`; All Inboxes adds the margin rule `selRule`, a folder never does | margin rule `selRule` |
| Selected, window not key | All Inboxes: margin rule `selRuleIdle`; a folder: unchanged | margin rule `selRuleIdle` |
| Drop target (§5.7 rows over a folder that takes them) | Inbox, Starred, Trash, All Mail: the {{layout.rail.tileHit}} pt `pressed` wash and glyph `ink`, the look of a click, while the drag is over the hit square; it never takes focus (no ring) and never switches the view (no spring-loading). A folder refusing the drag shows nothing | — (takes no drop) |
| Focused (Tab enters the folders on the selected folder and the accounts on the selected account; ↑/↓ move within each group and choose) | ring outside the tile, {{border.focusRing.gapAroundSheets}} pt gap | ring outside the account ring |
| Unread | count badge (99+ cap): Inbox and All Inboxes only | same |
| Needs sign-in | — | attention badge (`dangerFill`, `exclamationmark`) replaces the count; tooltip “Sign in required” |
| First sync | — | {{layout.progress.spinner.0}} pt spinner replaces the badge |
| Reconnecting (§5.44) | — | the attention badge **stays**: the account still needs sign-in until the browser finishes, and an abandoned sign-in must not look like progress. The tooltip reads “Finish signing in in your browser…”; the tile gets no spinner (the sync line carries the wait and its Cancel) |
| Signing in (pending tile, §5.44) | — | a placeholder at the end of the stack: {{layout.rail.face}} pt `fill` face with a 1 pt dashed `ruleStrong` ring and a {{layout.rail.pendingSpinner}} pt `ink3` spinner; tooltip “Finish signing in in your browser…”; not selectable |
| Collision monogram | — | two letters at {{layout.rail.monogramTwoLetter}} pt |
| Drag to reorder | — | tile lifts with `e2`; others shift instantly |

Add and Settings: rest `ink2`; hover `hover` wash (radius `r.md`), glyph `ink`; pressed `pressed` wash; Add shows `pressed` while its menu is open; focused ring with a {{border.focusRing.gap}} pt `spine` gap.

### 5.3 List header

One row, {{layout.listHeader.height}} pt: the title-bar zone itself, `paper`, its bottom hairline at y = {{layout.listHeader.height}}. Everything in it is centred on y = {{layout.listHeader.mastheadCenterY}}, the traffic lights' centre line, in this order:

- **Masthead** at x = {{layout.listHeader.mastheadX}} (rail width + {{layout.listHeader.mastheadMinimalGap}} in minimal mode, §5.1): the view's name in `masthead` (New York {{typography.masthead.size}}/{{typography.masthead.lineHeight}}). With the rail showing it is a plain title, not a control: the folders are in the rail, so it has no chevron, no hover, no menu and no Tab stop, VoiceOver reads it as a heading, and a click on it drags the window like the rest of the zone. In minimal mode it is the title menu's button (§5.4): `chevron.down` {{layout.listHeader.chevron}} pt Semibold `ink2` after {{layout.listHeader.chevronGap}} pt, hit area text + chevron + {{layout.listHeader.mastheadHitPad}} pt padding, radius `r.md`. After it, in this fixed order and only when they apply: the minimal-mode new-mail dot ({{layout.listHeader.minimalDotSize}} pt `accent`, {{layout.listHeader.minimalDotGap}} pt after the chevron; shown in minimal mode when another account has new mail), the “Demo” tag ({{layout.listHeader.demoTagGap}} pt after the previous item, §5.43), and, narrowed to one account, “· alex@contoso.test” in `snippet` `ink3` ({{layout.listHeader.addressGap}} pt after the previous item).
- **Search** (§5.6): from {{layout.listHeader.searchGap}} pt after the masthead cluster to {{layout.listHeader.searchComposeGap}} pt before compose.
- **Compose**: {{layout.listHeader.composeSize}} pt icon button, `ss.nib` {{layout.listHeader.composeGlyph}} pt, trailing {{layout.listHeader.composeTrailing}}, top {{layout.listHeader.composeTop}}.

**Who gives way.** The search field takes the free width between the cluster and compose, never starts before the cluster ends, and keeps at least {{layout.listHeader.searchMinWidth}} pt while anything else on the line can make room for it, in this order:

1. **The address** truncates (tail), and drops out whole when less than {{layout.listHeader.addressMinWidth}} pt of it would show (a lone “· a…” names nothing). While it is off the line the placeholder names the account instead (“Search Contoso”, or “Contoso” alone where that would be cut, §5.6), so the narrowed scope is always on screen; in minimal mode nothing else shows it.
2. **The Demo tag** steps off the line whole, and out of the Tab order, when the field beside it would be narrower than its minimum. The window title and the sync line still say Demo, and its menu's commands are in the File menu (§5.43). The address, which gave way first, stays off while the tag is.

The masthead text, the chevron and the dot never give way. When they alone leave less than {{layout.listHeader.searchMinWidth}} pt the field narrows to what is left, drops its keycap before its placeholder and ends the placeholder with an ellipsis. That happens only in minimal mode, where the masthead starts at {{layout.listHeader.mastheadMinimalX}} ({{layout.listHeader.mastheadMinimalX26}} from macOS 26) and carries the chevron: at the default list width for Starred and All Mail (and Drafts from macOS 26) and whenever the dot shows, and at the {{layout.list.minWidth}} pt list minimum in every view, down to 51 pt (All Mail with the dot; 43 pt from macOS 26). Beside the rail the masthead alone always leaves the minimum, so there the field never goes below {{layout.listHeader.searchMinWidth}} pt; on a list at its minimum width the Demo tag is off the line.

Worked numbers, with the rail, in Inbox, at the default list width (the header is 363 pt, the pane less its divider): the field runs from x = 82 to 315 (233 pt); with the Demo tag, which ends at x = 132, from 144; narrowed to alex@contoso.test, the address shows 87 of its 111 pt and the field is 175–315, exactly the minimum. In minimal mode (masthead at {{layout.listHeader.mastheadMinimalX}}), narrowed, with the dot, the address is off the line and the field runs from x = 182 to 315 (133 pt), a point short of the 134 pt “Search Contoso” needs, so it reads “Contoso”; without the dot it is 149 pt and reads “Search Contoso”.

{{TABLE:layout:listHeader}}

States of the masthead in minimal mode: rest; hover (`hover` wash behind text and chevron); pressed / menu open (`pressed`); focused (ring around the hit area); window not key (unchanged). With the rail showing it has none.

### 5.4 Title menu

A system `NSMenu` popped from the masthead in minimal mode only: with the rail showing, the folders and accounts are in the rail and the masthead is a plain title (§5.3). Left-aligned to the masthead text, {{layout.menu.titleMenuOffsetY}} pt below it.

| Item | Symbol | Shortcut column |
|---|---|---|
| Inbox | `{{icon.viewInbox}}` | G I |
| Starred | `{{icon.viewStarred}}` | G S |
| Sent | `{{icon.viewSent}}` | G T |
| Drafts | `{{icon.viewDrafts}}` | G D |
| Trash | `{{icon.viewTrash}}` | G # |
| — separator — | | |
| All Mail | `{{icon.viewAllMail}}` | G A |
| — separator — | | |
| All Inboxes, then each account | monogram | ⌘0, ⌘1…⌘9 |

The current view has a checkmark. G-sequences are an attributed title with a right tab stop in `ink3` (`keyEquivalent` cannot express a sequence). Highlight and item states are the system's; under Multicolor the highlight is Iron Gall through the accent asset (§3.1).

**Unread counts** are system menu-item badges, never custom fills: Inbox carries `NSMenuItemBadge(count:)` with the unread Inbox count of the current scope (all accounts, or the narrowed one; the rail's Inbox tile shows the same count, §5.2), and All Inboxes and each account item carry theirs. Numerals only, drawn and coloured by the system, so they stay legible on the highlighted row. Zero shows no badge. Starred, Sent, Drafts, Trash and All Mail carry none.

### 5.5 Filter tabs (removed in 1.4)

Removed: the Inbox always shows all of its mail. Focused and Other split one inbox into two places to check, and the header now has a single line for the masthead, search and compose. The providers' categories are still stored (`inbox_section`) to round-trip provider state, and nothing filters or marks rows by them (§5.7). The section number stays so that references to the sections after it keep their meaning.

### 5.6 Search field

| Part | Spec |
|---|---|
| Size | height {{layout.listHeader.searchHeight}}, top {{layout.listHeader.searchTop}} (centred on y = {{layout.listHeader.mastheadCenterY}}); the width fills the header line from the masthead cluster + {{layout.listHeader.searchGap}} to compose − {{layout.listHeader.searchComposeGap}}, at least {{layout.listHeader.searchMinWidth}} pt and never under the masthead cluster (§5.3 says what gives way). It already has the free width, so focus never resizes or animates it, and the list does not move |
| Shape | radius {{layout.search.radius}}, `sheet`, {{border.strong.width}} pt `ruleStrong` resting edge |
| Leading | `magnifyingglass` {{layout.search.glyph}} pt `ink3` at x = {{layout.search.glyphX}}; text and placeholder start at x = {{layout.search.textX}} |
| Placeholder | “Search” (`body`, `ink3`); “Search Starred” etc. in other views; “Search Inbox” when narrowed; while the header line has no room for the narrowed account's address (§5.3), the account's name in every view: “Search Contoso” (search looks through all of that account's mail but the Trash, whatever the view), or the name alone (“Contoso”, “Demo Gmail”) in a field too narrow to show that whole, since the magnifier already says search and a cut name may not tell two accounts apart |
| Trailing | {{layout.search.trailingInset}} pt from the trailing edge: keycap “/” ({{layout.kbd.inField}} pt) when empty and not focused, and only while the whole placeholder fits beside it (a field the header line has narrowed drops the keycap before the word, and a placeholder that has given up its “Search”, the bare account name, never gets the keycap in its place); while results show, the clear button ({{layout.search.clearVisual}} pt `fill` disc, `xmark` {{layout.search.clearGlyph}} pt, {{layout.search.clearHit}} pt hit) with “38 results” in `meta` `ink3` {{layout.search.resultsGap}} pt before it; the query truncates before the count does |

| State | Look |
|---|---|
| Rest | as above |
| Hover | face `sheet + hover` |
| Focused | edge kept, focus ring outside a {{border.focusRing.gap}} pt `paper` gap |
| Typing | query `ink`, caret `accent` |
| Searching | a {{layout.progress.spinner.0}} pt spinner replaces the magnifier, only when the first page takes more than {{motion.duration.spinnerDelay}} ms |
| No results | list shows the empty state (§5.9) |
| Query kept, focus elsewhere | keeps its query, count and clear button with no ring, because the list below is still the result set, until the query is cleared |
| Disabled (no accounts) | `fill`, no edge, `inkDisabled` |

**Leaving.** The field keeps its size whatever has focus. Esc in the field clears the query; Esc in an empty field returns focus to the list (§6.1). The clear button clears and keeps focus in the field.

### 5.7 Conversation row

Fixed **{{layout.row.height}} pt** (compact {{layout.rowCompact.height}}). Drawn by hand in `layout()` / `draw(_:)`: no Auto Layout, no shadow, no blur, no per-row animation, no layer per sub-element beyond the text labels and the avatar image.

| Element | Frame (x, y, w, h) | Style |
|---|---|---|
| Margin rule (selected) | 0, {{layout.row.marginRuleY}}, {{border.marginRule.width}}, {{layout.row.marginRuleHeight}} | `selRule` / `selRuleIdle` |
| Unread pip | {{layout.row.pipX}}, {{layout.row.pipY}}, {{layout.row.pip}}, {{layout.row.pip}} (centred on the sender line) | `accent` circle |
| Avatar box | {{layout.row.avatarBoxX}}, {{layout.row.avatarBoxY}}, {{layout.row.avatarBox}}, {{layout.row.avatarBox}}: face {{layout.row.avatarFace}} centred; {{border.accountRing.gap}} pt gap; {{border.accountRing.width}} pt ring | face tint, monogram (New York, or `monogramSans` under the SF Pro font), ring = account ink (unified views only). The gap is **not drawn**: it is the row's own fill showing through, so the same face serves every row state |
| Sender line | {{layout.row.textX}}, {{layout.row.senderY}}, to the time − {{layout.row.timeGap}}, {{layout.row.senderHeight}} | `sender`; Semibold when unread; participants joined by “, ”, the user as “me”; Drafts/Sent prefixes in `ink2`; no sender: “No sender” in the placeholder style (§4.1) |
| Time cluster | trailing {{layout.row.trailing}}, on the sender line | from the trailing edge: time (`meta`, tabular, `ink3`; unread: `metaStrong` in `accent`; format per running head, §4.13) · {{layout.row.tileGap}} pt (`tileGap`) · optional account initial tile ({{layout.row.accountTile}} pt) · {{layout.row.queuedGap}} pt (`queuedGap`) · `ss.queued` or the failed glyph ({{layout.row.queuedGlyph}} pt). An absent tile takes its leading gap with it: with no tile the glyph sits {{layout.row.queuedGap}} pt from the time. Rows carry no category tag: the Focused/Other category is not shown anywhere (§5.5) |
| Subject line | {{layout.row.textX}}, {{layout.row.subjectY}}, to the glyph cluster − {{layout.row.clusterGap}}, {{layout.row.subjectHeight}} | `subject` (New York; `subjectSans` when New York lacks the script, and always under the SF Pro font); Semibold when unread; no subject: “No subject” in the placeholder style (italic `ink3`, regular weight even when unread) |
| Glyph cluster | trailing {{layout.row.trailing}}, centred on the subject line, {{layout.row.glyphGap}} pt gaps, fixed order from the trailing edge: star, attachment, count | `star.fill` {{layout.row.glyph}} pt `star`; `paperclip` {{layout.row.glyph}} pt `ink2`; count badge {{layout.badge.height}} pt, neutral |
| Snippet | {{layout.row.textX}}, {{layout.row.snippetY}}, to trailing {{layout.row.trailing}}, {{layout.row.snippetHeight}} | `snippet`, `ink2` |
| Separator | from x = {{layout.row.separatorX}} to the trailing edge, bottom | hairline `rule`; hidden on the selected row and the row above it |

{{TABLE:layout:row}}

| State | Fill | Marks | Notes |
|---|---|---|---|
| Read | `paper` | — | Regular weights, time `ink3` |
| Unread | `paper` | pip | Semibold sender, subject and time; time in `accent` |
| Hover | `paper + hover` | — | pointer only, instant; never on a selected row; no hover action buttons in rows; suspended while the list scrolls (below) |
| Pressed | — | — | selection applies on mouse-down |
| Selected, window key | `selWash` | margin rule `selRule` | text unchanged; pip, ring, badge, star keep ≥ 3:1 / 4.5:1 |
| Selected, window not key | `selWashIdle` | margin rule `selRuleIdle` | always drawn |
| Multi-selection | each selected row as above | | ⇧-click, ⌘-click, ⇧J / ⇧K; the reader shows §5.19 |
| Keyboard focus with no selection | `paper` | {{border.focusRing.width}} pt ring inset | Full Keyboard Access only |
| Starred | — | filled `star` | VoiceOver “Starred” |
| Has attachment | — | `paperclip` | |
| Message count ≥ 2 | — | neutral count badge | |
| Queued locally | — | `ss.queued` `ink3` before the time | full contrast, never faded; VoiceOver “Waiting to sync” |
| Operation failed permanently | — | `exclamationmark.triangle.fill` `danger` replaces `ss.queued` | the row is restored locally; toast “Couldn't archive. Restored.”; tooltip and VoiceOver “Couldn't archive”. The triangle stays until the conversation is opened (selected for {{motion.duration.spinnerDelay}} ms, which acknowledges it), a later operation on it succeeds, or 24 hours pass (`failed_op_kind`, §8.5) |
| Account (unified views) | — | ring; optional initial tile | single-account views drop both; face size unchanged |
| Drafts / Sent views | — | “Draft to Ben Carter” / “To Ben Carter” | |
| Dragging | — | system drag image | the row itself is unchanged; Inbox, Starred, Trash and All Mail in the rail take it (§5.2) |

**Compact density** ({{layout.rowCompact.height}} pt): pip at y {{layout.rowCompact.pipY}}; sender line at x {{layout.rowCompact.textX}}, y {{layout.rowCompact.senderY}}; a {{layout.rowCompact.accountSquare}} pt account square (radius {{layout.rowCompact.accountSquareRadius}}, filled with the account ink) before the time, replaced by the {{layout.row.accountTile}} pt initial tile when **Show account initials** is on (never both); line 2 at y {{layout.rowCompact.line2Y}}: subject, then “ — ” and the snippet in `snippet` `ink2`; glyph cluster as above; margin rule y {{layout.rowCompact.marginRuleY}}, height {{layout.rowCompact.marginRuleHeight}}; separator from x {{layout.rowCompact.separatorX}}.

{{TABLE:layout:rowCompact}}

**Performance contract.**

- All attributed strings are built once per (conversation id, version, appearance, contrast, Font setting, day) in `RowContentCache`, including the script-coverage decision and the running-head time format. Window key state is not part of the key: no text colour depends on it (§3.4).
- **Avatars: faces are cached, rings are drawn.** The face bitmap (tint disc + monogram) renders off the main thread, cached by (initials, tint, size, appearance, contrast, Graphite, Font setting) only. The account ring is stroked in `draw(_:)` with `NSBezierPath` (a circle of radius face/2 + gap + ring/2, width {{border.accountRing.width}}, in the account ink), and the gap is left transparent so the row's fill (`paper`, `paper + hover`, `selWash`, `selWashIdle`) shows through. Hover and selection therefore never miss the cache or flash a wrong-coloured gap. Until a face is ready the row draws the tint disc and initials synchronously from the cached glyph run; it never shows an empty circle.
- **Hover is suspended while scrolling.** On `NSScrollView.willStartLiveScrollNotification` (and for scroll-wheel momentum) the list stops updating hover; rows that slide under a still pointer draw no wash. On `didEndLiveScrollNotification` the row under the pointer, if any, takes the hover wash once.
- Selection changes redraw only the fill and the margin rule inside `CATransaction.setDisableActions(true)`. Row views are opaque and layer-backed.

### 5.8 Running heads (date dividers)

Rows are grouped under local-day heads: Today, Yesterday, Earlier this week, Last week, then month names (“October”), then “October 2025” for earlier years. Each head sets the row time format below it (§4.13): Today and Yesterday rows show the time, Earlier this week the weekday, every later head day and month.

{{TABLE:layout:runningHead}}

- Label at x {{layout.runningHead.labelX}}, y {{layout.runningHead.labelY}}: `runningHead` (SF Pro {{typography.runningHead.size}}/{{typography.runningHead.lineHeight}} Semibold, uppercase, {{typography.runningHead.tracking}} pt tracking), `ink3`. A hairline runs from the label end + {{layout.runningHead.ruleGap}} to trailing {{layout.list.inset}} at y {{layout.runningHead.ruleY}}.
- **Hidden** in search results (ranked) and in views with fewer than {{layout.runningHead.minConversations}} conversations.
- **Compact density**: {{layout.runningHead.compactHeight}} pt, label at x {{layout.runningHead.compactLabelX}}, y {{layout.runningHead.compactLabelY}}, rule at y {{layout.runningHead.compactRuleY}}.
- **Not sticky**: plain group rows, no `floatsGroupRows` (no extra compositing during scroll). `heightOfRow` returns two fixed values per density (row and head), plus the tail footer's height (§5.10). `j`/`k`, next-unread and selection restore skip them; they are not selectable or focusable; VoiceOver reads them as headings.

### 5.9 Empty states

Centred in the pane, max width {{layout.emptyState.maxWidth}}. Line 1 is `aside` (New York Italic {{typography.aside.size}}/{{typography.aside.lineHeight}}) in `ink`; line 2 is `snippet` in `ink3`, {{layout.emptyState.lineGap}} pt below. A line 2 that carries keycaps is a row of commands: it may run past {{layout.emptyState.maxWidth}} pt, up to the pane's width, and when it must wrap it breaks only before a keycap, so a keycap never ends a line apart from the words that follow it.

| Case | Glyph | Line 1 | Line 2 |
|---|---|---|---|
| Inbox zero | `ss.sparrow` {{layout.emptyState.glyph}} pt `ink3`, {{layout.emptyState.glyphGap}} pt above | Nothing left to read. | New mail will land here. |
| Empty Starred | — | No starred conversations | Press S to star one. |
| Empty Sent | — | No sent mail | Messages you send appear here. |
| Empty Drafts | — | Nothing in Drafts | Drafts you start here are kept on this Mac. |
| Empty Trash | — | Trash is empty | Conversations you move to Trash appear here. |
| Empty All Mail | — | No mail | Every conversation in this account appears here, archived ones too. |
| First sync finished with no mail in the view (the older mail listed too, not just the first page) | — | No mail in Contoso yet | Sync finished. New mail will land here. |
| Older mail still being listed, nothing in the view yet (any view but search and offline) | — | the view's line 1, as above | Older mail is still downloading. |
| Search, no results | — | No results for “lisbon flat” | Search looks at subjects, people and message text. |
| Reader, nothing selected | — | No conversation selected | keycaps J K to move · ↩ to open |
| Reader, conversation emptied while open (its last message deleted or moved elsewhere) | — | No messages to show | They were deleted or moved on another device. |
| Offline, nothing cached | `wifi.slash` {{layout.emptyState.offlineGlyph}} pt `ink3`, {{layout.emptyState.offlineGlyphGap}} pt above line 1 (`emptyState.offlineGlyphGap`) | You're offline | Mail will appear when you reconnect. |
| No accounts | — | the welcome screen (§5.39) | |

In the conversation-emptied state the reader header keeps the subject (placeholder style if missing), every action but Trash is disabled, and the quick reply is hidden (§5.18); the list removes the row as usual and the selection moves on with the next keystroke.

### 5.10 Skeleton and loading

Only on the first sync of an account, before its first page lands, and only after {{motion.duration.skeletonDelay}} ms. Static: no shimmer.

{{TABLE:layout:skeleton}}

- Skeleton row: {{layout.row.height}} pt; a {{layout.skeleton.circle}} pt circle and four bars (sender, time, subject, snippet: frames above as x, y, w, h), widths varying by ±{{layout.skeleton.widthJitter}} from a fixed table; colour `fill`, radius {{layout.skeleton.barRadius}}.
- Compact skeleton row: {{layout.rowCompact.height}} pt, no circle; sender bar {{layout.rowCompact.skeletonSenderBar}}, time bar {{layout.rowCompact.skeletonTimeBar}} (trailing {{layout.row.trailing}}), line-2 bar {{layout.rowCompact.skeletonLine2Bar}} (x, y, w, h), same jitter, colour and radius.
- Body not cached yet: the sheet shows its header at once and three bars at {{layout.skeleton.bodyBars}} of the measure, {{layout.skeleton.bodyBarHeight}} pt high, {{layout.skeleton.bodyBarGap}} pt apart. In the reader these are CSS (`.ss-skel { background: var(--q-fill); border-radius: var(--q-r-xs) }`), never a full-pane spinner.
- Skeleton to content is an instant swap, in the list and in a sheet (no cross-fade: nothing in the list animates).

**List tail (paging).** The list loads older pages as the user scrolls within two screens of the end. When the next page is not in hand, a fixed {{layout.listFooter.height}} pt footer row ends the list: after {{motion.duration.spinnerDelay}} ms a {{layout.listFooter.spinner}} pt `ink3` spinner and, {{layout.listFooter.gap}} pt after it, “Loading older mail…” in `meta` `ink3`, centred; before the delay the row is empty `paper`, so fast pages never flash. Failure: `exclamationmark.triangle.fill` `danger` + “Couldn't load older mail” + link “Retry” (`metaStrong`, `accent`). At the true end of a view there is no footer. The footer is not selectable, `j`/`k` skip it, and it is the same height in both densities.

### 5.11 Sync status line

{{layout.syncLine.height}} pt at the bottom of the list pane, top hairline, padding {{layout.syncLine.padX}}, gap {{layout.syncLine.gap}}, glyph {{layout.syncLine.glyph}} pt. Text `meta` `ink3`; the lead phrase `metaMedium` `ink2`; trailing actions `metaStrong` `accent`. Always present, so the list never changes height. Clicking it opens Settings › Accounts; hover shows the per-account detail as a tooltip.

| State | Glyph | Copy | Extras |
|---|---|---|---|
| Up to date | `checkmark` `ink3` | **Up to date** · 3 accounts · checked 23:41 | — |
| Up to date, downloading older mail | `checkmark` `ink3` | **Up to date** · Contoso · older mail 3,412 of 8,120 (“older mail 3,412” while the total is unknown, “older mail…” before the first count) | determinate contrail along the top edge while the total is known (never the indeterminate sweep: new mail is current); “checked 23:41” leaves the line for the tooltip's last line (“Checked 23:41”) |
| Up to date, older mail paused | `checkmark` `ink3` | **Up to date** · Contoso · older mail paused until 10:42 | the provider is limiting the older-mail download while it is still being listed; new mail still arrives, so this is never Slow / retrying. No contrail. Once the older mail is listed, a pause of its body downloads is not older mail and never takes the line |
| Downloading | {{layout.progress.spinner.0}} pt spinner | **Downloading mail** · Contoso · 3,412 of 8,120 | determinate contrail along the top edge. Only a new account's first page of newest mail; the older mail after it shows under Up to date |
| Checking | {{layout.progress.spinner.0}} pt spinner | **Checking for mail…** | only for a check the user asked for (View › Check for New Mail ⇧⌘N, or reconnecting), and only once it has run {{motion.duration.spinnerDelay}} ms. The background checks, every 5 s while SuperSparrow is active and every 30 s otherwise, and the checks on app activation, on waking from sleep and when the network returns, never change the line or its tooltip (an account checked in the background reads as Settings shows it, Up to date) except to update “checked 23:41” |
| Sending | {{layout.progress.spinner.0}} pt spinner | **Sending 1 message** | after the undo window, while the send is in flight |
| Signing in (§5.44) | {{layout.progress.spinner.0}} pt spinner | adding: **Finish signing in in your browser** · Gmail (the provider: no account exists yet); reconnecting: **Finish signing in in your browser** · Fabrikam (the account's name) | trailing link “Cancel” |
| Offline | `wifi.slash` `ink2` | **Offline** · changes will sync when you're back | — |
| Slow / retrying | `clock` `warning` | **Gmail is slow to respond** · retrying in 30 s | — |
| Sign-in required | `exclamationmark.triangle.fill` `danger` | **Sign in required** · Fabrikam (line in `danger`) | trailing link “Reconnect” |
| Error | `exclamationmark.triangle.fill` `danger` | **Couldn't sync Contoso** · details | trailing link “Retry” |
| Demo (§5.43) | `info.circle` `ink3` | **Demo** · made-up mail, nothing syncs | — |

**Several accounts: precedence.** The line shows one state. It is chosen from every account's status by the first rule that matches, top to bottom; the tooltip lists every account's own state (“Contoso: Downloading 3,412 of 8,120 · Fabrikam: Sign in required · Gmail: Offline”), the same words Settings › Accounts uses (§5.40).

| # | State | Wins when |
|---|---|---|
| 1 | Signing in | a sign-in the user started is waiting for the browser (it answers the user's own action, and its Cancel lives only here in the main window) |
| 2 | Sign-in required | any account needs sign-in |
| 3 | Error | any account failed with a non-network error |
| 4 | Offline | macOS reports no network path, or every account that is not idle failed with a network error |
| 5 | Slow / retrying | some accounts are waiting to retry new mail or sends: a network error while others are online, or the server asked to slow down (rate limited). A limit on the older-mail download only pauses that download, and reads as paused under Up to date (rule 10) |
| 6 | Sending | a send is in flight after its undo window |
| 7 | Downloading | a new account is fetching its first page of newest mail (its first download, before it can check for changes). The older mail downloaded behind it never takes the line (rule 10), nor do body downloads (hydration); Settings shows both |
| 8 | Checking | a check the user asked for has run {{motion.duration.spinnerDelay}} ms |
| 9 | Demo | demo mode (it replaces Up to date) |
| 10 | Up to date | otherwise; while any account downloads older mail, the line says how far it has come in place of “checked 23:41”, or, once every such account is paused, until when |

**Copy for several accounts.** One account in the winning state is named; two or more are counted, never listed: “**Sign in required** · Fabrikam” / “**Sign in required** · 2 accounts”; “**Couldn't sync Contoso** · details” / “**Couldn't sync 2 accounts**”; “**Gmail is slow to respond** · retrying in 30 s” / “**2 accounts are slow to respond** · retrying in 30 s” (the soonest retry); “**Downloading mail** · Contoso · 3,412 of 8,120” / “**Downloading mail** · 2 accounts · 3,412 of 8,120” (summed over the downloading accounts, “3,412 messages” while a total is unknown); “**Up to date** · Contoso · older mail 3,412 of 8,120” / “**Up to date** · 3 accounts · older mail 3,412 of 8,120” (named as Up to date names the accounts shown; the figures summed over the accounts downloading older mail, a paused one included so the figure does not jump when it pauses, and “older mail 3,412” while a total is unknown), and “**Up to date** · 3 accounts · older mail paused until 10:42” once every one of them is paused (the soonest resume). The trailing action follows the count: with one account “Reconnect” and “Retry” act on it; with two or more the link reads “Reconnect…” and opens Settings › Accounts, where each row has its own Reconnect, and “Retry” retries every failed account. Numbers use the locale's grouping (§4.13).

**Keyboard.** The line is a button (Space or ↩ opens Settings › Accounts) with the focus ring inset {{border.focusRing.width}} pt inside its bounds. While it carries an action (Reconnect, Retry, Cancel) it joins the Tab order after the list, always, because no other surface offers that action in place; Tab lands on the action link (ring around the link, radius `r.sm`) and ↩ runs it. Without an action it is reachable only with Full Keyboard Access. VoiceOver reads the whole line, then the action.

### 5.12 Reader header and action buttons

A **native** view (it replaces `ConversationHeaderView`), {{layout.readerHeader.height}} pt, `paper`, bottom hairline at the horizon, always visible. The subject updates in the same frame as the selection, before the web view renders, so key repeat feels instant.

- **Row 1** (title-bar zone): the kicker at the reading column's leading edge, centred on y = {{layout.readerHeader.kickerCenterY}}: a {{layout.readerHeader.kickerDot}} pt account-ink dot, {{layout.readerHeader.kickerDotGap}} pt, the account name, “·”, the message count, in `runningHead` `ink3` (single-account setups omit the account; several selected shows “Selection”). The kicker ends at least {{layout.readerHeader.kickerActionGap}} pt before the first visible action (`readerHeader.kickerActionGap`); when it does not fit, the account name tail-truncates and the dot, the “·” and the count never do; if fewer than {{layout.readerHeader.kickerNameMinChars}} characters of the name would remain, the name is dropped (dot and count stay, and the kicker's tooltip names the account). At the {{layout.window.readerMinWidth}} pt minimum reader the kicker has 400 − 16 − 190 − 16 − 16 = 162 pt: the dot, “· 12 MESSAGES” and the first letters of the account name. Trailing at {{layout.readerHeader.actionsTrailing}}, top {{layout.readerHeader.actionsTop}}: Star · Archive · Trash, a {{layout.readerHeader.actionGroupGap}} pt gap, Reply · Reply All · Forward, as {{layout.readerHeader.actionSize}} pt icon buttons with {{layout.readerHeader.actionGlyph}} pt symbols, {{layout.readerHeader.actionGap}} pt apart (190 pt for all six). The set changes per view and selection (below).
- **Row 2**: the headline at the reading column, top {{layout.readerHeader.headlineTop}}: `headline` (New York {{typography.headline.size}}/{{typography.headline.lineHeight}} Semibold, `headlineSans` when New York lacks the script), one line, tail truncation, full subject in the tooltip and VoiceOver label, selectable. No subject: “No subject” in the placeholder style (`headline` italic, `ink3`).
- The reading column x = max(margin, (reader width − {{layout.reader.columnMax}}) / 2), where margin is {{layout.reader.columnMinMargin}}, or {{layout.reader.narrowColumnMargin}} when the reader is narrower than {{layout.window.readerNarrow}} pt; recomputed in `layout()`; the kicker, headline, sheets and quick-reply field share it.
- **Per view and selection.** Each set is drawn from the trailing edge; hidden actions close up, they never leave gaps.

  | Reader state | Actions | Notes |
  |---|---|---|
  | One conversation in Inbox, Starred, Sent, All Mail | Star · Archive · Trash, gap, Reply · Reply All · Forward | — |
  | One conversation in Trash | Star · Move to Inbox, gap, Reply · Reply All · Forward | Archive becomes Move to Inbox (`tray.and.arrow.down`, ⇧I); **Trash is removed**: the conversation is already there and v1 has no Delete Forever (§9). # does nothing in Trash and Message › Move to Trash is disabled |
  | Several selected (any view but Drafts and Trash) | Star · Archive · Trash | the reply group is **hidden**: a reply answers one conversation, so R, A and F do nothing. Archive and Trash act on every selected conversation (toast “Archived 3 conversations”). Star shows the selection's state: on (`star.fill` in `star`, tooltip “Unstar All  S”) only when **every** selected conversation is starred, and then it unstars all; otherwise, none or mixed, it is off (outline `star`, tooltip “Star All  S”) and it stars all. S does the same |
  | Several selected in Trash | Star · Move to Inbox | as above, with Move to Inbox for all |
  | Drafts (one draft) | Continue Editing (`ss.nib`, ↩) · Discard Draft (`trash`, #) | Star, Archive and the reply group are hidden; Discard confirms with the “Discard this draft?” alert; the kicker reads “Draft · Contoso” (§5.19). Several drafts selected: Discard Draft only, which asks “Discard 3 drafts?” (§5.33) |
  | Nothing selected | the full set, disabled | — |
  | Conversation emptied while open | the view's set, every action but Trash disabled | in Trash, every action disabled |

{{TABLE:layout:readerHeader}}

| State | Glyph | Fill |
|---|---|---|
| Rest | `ink2` | none |
| Hover | `ink` | `hover`, radius `r.md`; tooltip “Archive  E” |
| Pressed | `ink` | `pressed` |
| Focused | `ink2` | ring |
| On (starred) | `star.fill` in `star` | none |
| Disabled (Reply All with one participant; nothing selected; every action but Trash when the conversation has no messages left) | `inkDisabled` | none |
| Loading | {{layout.progress.spinner.0}} pt spinner replaces the glyph | none |
| Window not key | unchanged | unchanged |

With nothing selected the header keeps its height, shows no kicker or headline, and its actions are disabled.

### 5.13 Message stack (collapsed messages)

Below the header the reader shell renders the participants line (`body`, `ink2`, {{layout.reader.participantsTop}} pt from the top, up to {{layout.reader.participantsMax}} names then “+3”), then the stack, {{layout.reader.participantsGap}} pt below.

All collapsed messages between expanded ones form one stack: one `sheet` with a hairline `rule` edge, radius {{layout.reader.sheetRadius}}, no shadow; collapsed rows are {{layout.reader.stackRow}} pt and separated by hairlines.

| Part | Spec |
|---|---|
| Row | padding 0 {{layout.reader.stackRowPadX}}, gap {{layout.reader.stackRowGap}} |
| Avatar | {{layout.reader.stackAvatar}} pt monogram, no ring |
| Name | `senderMedium`, `ink`, fixed {{layout.reader.stackNameColumn}} pt column; Semibold when unread; “No sender” in the placeholder style |
| Snippet | `sender`, `ink2`, fills, tail-truncated |
| Starred | `star.fill` {{layout.reader.starGlyph}} pt in `star`, {{layout.reader.starGap}} pt before the date, when that message is starred (Gmail stars messages; for Microsoft the flag is on the message too) |
| Date | `meta` tabular `ink3`, trailing |
| Unread pip | {{layout.reader.stackPip}} pt `accent` circle at x = {{layout.reader.stackPipX}} (centred in the {{layout.reader.stackRowPadX}} pt leading padding), vertically centred on the row (y = 19 in the {{layout.reader.stackRow}} pt row) |
| Fold | more than {{layout.reader.foldAbove}} collapsed messages keep the first {{layout.reader.foldKeepStart}} and last {{layout.reader.foldKeepEnd}} and fold the rest into one row “4 more messages” (`label`, `ink2`, centred) |

States: rest; hover (`hover` across the row, end rows clipped to the radius); pressed; focused (`n`/`p` or Tab: a {{border.focusRing.width}} pt `focus` ring inset {{border.focusRing.gap}} pt inside the row); unread (pip + Semibold); starred (the mark above). Click or ↩ expands the message in place, by the provisional-height rule of §4.10 (`dur.standard`, `ease.settle`; Reduce Motion: instant).

**Fold row** (“4 more messages”): a {{layout.reader.stackRow}} pt stack row with the same states: hover (`hover`, label `ink`), pressed (`pressed`), focused (the inset ring; `n`/`p` land on it like a message). Click, ↩ or Space unfolds it into its collapsed rows (not into expanded messages), with the stack's height change (`dur.standard`, `ease.settle`; Reduce Motion: instant); focus moves to the first unfolded row. It does not fold again until the conversation is reopened. VoiceOver: “4 more messages, button”.

### 5.14 Message sheet (expanded) and message header

{{TABLE:layout:reader}}

| Part | Spec |
|---|---|
| Sheet | `sheet`, radius {{layout.reader.sheetRadius}}, hairline `rule` edge + `e1`; padding {{layout.reader.sheetPadTop}} {{layout.reader.sheetPadX}} {{layout.reader.sheetPadBottom}}; {{layout.reader.stackGap}} pt below the stack or the previous sheet |
| Header | avatar {{layout.reader.headerAvatar}} (no ring) · {{layout.reader.headerGap}} gap · who block · date |
| Name line | `bodyStrong`, `ink` (“No sender” in the placeholder style); a starred message shows `star.fill` {{layout.reader.starGlyph}} pt in `star` {{layout.reader.starGap}} pt after the name, at rest; the address follows on hover or focus (`meta`, `ink3`, {{layout.reader.addressGap}} pt gap); unread shows a {{layout.reader.headerPip}} pt `accent` pip before the name |
| Recipients | `snippet` `ink2`: “to me · cc Tom Hughes”; the line is a button (click, ↩ or Space; tooltip “Show Addresses”) that expands into the full addresses below |
| Recipients, expanded | replaces the summary line in place, inside the who block: one block per field in the order To, Cc, Bcc (Bcc only on messages the user sent), {{layout.reader.recipientsFieldGap}} pt apart. Each block starts with its label, “To”, “Cc” or “Bcc” (`snippet` `ink3`), in a {{layout.reader.recipientsLabelColumn}} pt column (`reader.recipientsLabelColumn`), then the recipients wrapped in the remaining width, comma-separated, as “Ben Carter <ben@contoso.test>”: names `snippet` `ink2`, addresses `snippet` `ink3`, the user as “me <alex@contoso.test>”; a recipient never breaks across lines (a single over-long address tail-truncates, full text in its tooltip). Past {{layout.reader.recipientsMaxLines}} lines the expansion stops at “and 24 more” (`snippet` `ink2`, a button that shows the rest). Collapsing: a click anywhere on the block, ↩ or Space while it has focus (tooltip “Hide Addresses”); the state lasts for the session, per message. The height change follows the expand rule of §4.10 (`dur.standard`, `ease.settle`; Reduce Motion: instant); the block is shell DOM, measured at once, so there is no provisional height. VoiceOver: “Recipients, collapsed, button” / “expanded”. All inks are the tested `ink2` and `ink3` pairs on `sheet` |
| Date | `snippet`, tabular, `ink3`, trailing: “Today 09:12”, “Yesterday 23:39”, “Fri 30 Oct” |
| Hover actions | on hover or focus only (fade in `dur.quick`), before the date: {{layout.reader.headerAction}} pt icon buttons ({{layout.reader.headerActionGlyph}} pt symbols; {{layout.button.minHit}} pt hit), {{layout.reader.headerActionGap}} pt apart, the last one {{layout.reader.headerActionDateGap}} pt before the date: Star (`star` / `star.fill` in `star` when on), Reply, More; plus Original colors in dark mode for styled HTML mail that declares its own colours (off: `circle.lefthalf.filled` `ink2`, tooltip “Original Colors  ⇧⌘O”; on: the same glyph in `accent` on `accentWash`, hover `accentWashHover`, pressed `accentWashPressed`, tooltip “Adaptive Colors  ⇧⌘O”; the on state stays visible without hover) |
| More (`ellipsis`) | a system menu acting on **this message**; conversation actions stay in the header: Reply · Reply All · Forward · — · Star Message / Unstar Message · Mark as Unread from Here · — · Load Images (when images are blocked) · Original Colors / Adaptive Colors (dark mode, styled, declares colours) · — · Copy Sender Address. Items that do not apply are hidden, not disabled |
| Body | {{layout.reader.bodyTop}} below the header. Plain and unstyled: `reading` (or `readingSans`), indented {{layout.reader.bodyIndent}} to the name column, measure {{layout.reader.measure}} (narrower when the sheet is), paragraph gap {{layout.reader.blockGap}}. A text/plain body is stored as paragraphs: blank lines end a `<p>` and a run of them is one break, lines inside keep their `<br>`, so the gap spaces paragraphs instead of an empty line (bodies stored before 1.3.1 keep `<br><br>` until fetched again). Styled HTML: the sheet's full content width ({{layout.reader.htmlWidth}} at the widest column), fitted as below |
| Quoted-text toggle | {{layout.reader.blockGap}} below the body, at the indent (§5.15) |
| Attachments | {{layout.reader.attachmentsTop}} below, chips at the indent, wrapping with {{layout.attachmentChip.chipGap}} pt gaps (§5.17) |
| Footer | {{layout.reader.footerTop}} below, hairline above, {{layout.reader.footerPad}} pt padding; ghost buttons Reply · Reply all · Forward (sentence case, §4.13) with their symbols, at the indent, **regular** size ({{layout.button.regular.height}} pt, `bodyMedium`, {{layout.button.regular.glyph}} pt glyphs; `layout.reader.footerButtonSize`), {{layout.reader.footerButtonGap}} pt apart; on the target message each button is followed by its keycap (R, A, F), {{layout.reader.targetKeycapGap}} pt after the button and {{layout.reader.footerKeycapNextGap}} pt before the next one |

**The target message.** R, A, F and Space act on one message: the last expanded message when a conversation opens; the message last clicked anywhere inside its sheet; or the one last reached with `n`/`p` or Tab. It is always shown, without the keyboard ring: its footer carries the R · A · F keycaps, and when more than one message is expanded its sheet edge is {{border.strong.width}} pt `ruleStrong` instead of the `rule` hairline. When the reader is narrower than {{layout.window.readerKeycapsMin}} pt and the keycaps hide, the edge is drawn even with one message expanded. The keyboard ring (below) appears only after `n`/`p` or Tab and always sits on the target.

**Tab order inside an expanded sheet.** Tab enters a sheet on the sheet itself (it takes the ring and becomes the target), then moves through, in this order: the header hover actions in visual order (Star, Reply, More, and Original colors when present; they show while anything in the sheet has focus) → the recipients button → banner actions in document order (Load images; the notice's Original colors / Adaptive colors, then its dismiss) → links in the body, in document order, **only with Full Keyboard Access** (the web view's `tabFocusesLinks` follows that setting; otherwise ⌥Tab reaches them, as in Safari) → the quoted-text toggle → the attachment chips, as one stop (← → move between chips, Space opens Quick Look on the focused one) → the footer buttons Reply, Reply all, Forward → the next stack row or sheet, and after the last message the quick reply. ⇧Tab reverses. Every stop draws the Quire ring; links in a body draw it through the injected `a:focus-visible` rule (§8.4: {{border.focusRing.width}} pt `focus`, {{border.focusRing.widthHC}} pt in IC, outside a 1 pt gap in the sheet colour), never WebKit's default ring, whose alpha falls below 3:1. In Original colors the link ring takes the light-mode `focus` value and an `originalPage` gap, because the page under it is white.

**Wide HTML.** Styled bodies render at the sheet's content width (column − 2 × sheet padding x). After an iframe loads, the shell reads the body's `scrollWidth` once (layout, not a scan of the HTML). If it is wider than the content width, the body is scaled with CSS `zoom` to fit, down to {{layout.reader.htmlMinZoom}}; if fitting needs less than {{layout.reader.htmlMinZoom}}, the body stays at {{layout.reader.htmlMinZoom}} and scrolls horizontally inside its iframe (scroller only while scrolling, `overflow-x: auto`); nothing is clipped. The fit is recomputed when a live resize ends, never per frame.

Worked example, a 600 px newsletter with the default {{layout.list.defaultWidth}} pt list, for both rail widths (§3.2):

| Window | Reader (macOS 15, rail {{layout.rail.width}} / macOS 26 and later, rail {{layout.rail.width26}}) | Column | Content width | Zoom needed | Result |
|---|---|---|---|---|---|
| Default {{layout.window.defaultWidth}} | 840 / 832 | {{layout.reader.columnMax}} / {{layout.reader.columnMax}} | {{layout.reader.htmlWidth}} / {{layout.reader.htmlWidth}} | — | fits unscaled |
| Minimum {{layout.window.minWidth}} (narrow reader: margins and sheet padding {{layout.reader.narrowColumnMargin}}) | 520 / 512 | 488 / 480 | 456 / 448 | 0.760 / 0.747 | zoomed to fit on both |
| Minimum, Original colors (dark) | 520 / 512 | 488 / 480 | 432 / 424 (the inset's inner width) | 0.720 / 0.707 | stays at {{layout.reader.htmlMinZoom}} and scrolls |
| {{layout.window.readerMinWidth}} pt minimum reader | 400 | 368 | 336 | 0.560 | stays at {{layout.reader.htmlMinZoom}} and scrolls |

`htmlMinZoom` is {{layout.reader.htmlMinZoom}}, set just under 0.747 so that the minimum window fits a standard 600 px newsletter on every supported macOS instead of scrolling it by 2 px (at 0.75 the macOS 26 case would overflow 448 pt by 2 pt); 0.74 keeps a sender's 12 px text at 8.9 px, the same legibility floor as before.

**Colour in dark appearances.** What a body looks like depends on two flags stored at sync time (`typesetting` and `declaresColors`, §8.5), never on a scan at open:

| Body | Light, Light IC | Dark, Dark IC: **Adapted** (default) | Dark, Dark IC: **Original colors** |
|---|---|---|---|
| Plain or unstyled | Quire inks on the sheet (`reading`) | the same: Quire inks on the dark sheet | not offered (no notice, no hover action) |
| Styled, declares no colours | as sent, on the sheet | `color-scheme: dark` on the body document: the browser defaults turn light-on-transparent, so the dark sheet shows through; unvisited links `accent` through a zero-specificity rule (`:where(a:link)`) | not offered |
| Styled, declares colours | as sent, on the sheet (the sheet is already the white page the sender designed for); no notice, no inset | the shell puts `ss-adapt` on the body document's root: `color-scheme: dark`; every declared text colour becomes `ink` (links `accent`); declared background colours and background images are removed (transparent, so the dark sheet shows); declared border colours become `rule`. Layout, fonts, sizes and `<img>` elements are untouched. The Original colors notice says so (§5.16) | nothing is overridden: `ss-adapt` is removed and the body renders exactly as sent on an `originalPage` inset (`#FFFFFF` in every mode) inside the sheet, radius `r.xs` ({{layout.reader.originalInsetRadius}}), padding {{layout.reader.originalInsetPad}} on every side (`layout.reader.originalInsetPad`), filling the sheet's content width; wide-HTML fitting measures the inset's inner width (content width − 2 × {{layout.reader.originalInsetPad}}). The notice reads “Showing the sender's colours.” |

Adaptation **replaces** colours rather than inverting them or relying on `color-scheme` alone: `color-scheme` changes only the browser's defaults, so a sender's declared black text would stay black on the dark sheet, and inversion cannot promise any contrast. With Quire's inks every adapted text pair is one of the tested pairs (§7). The cost is the sender's brand colour, and images drawn for a white page (a dark logo with a transparent background) can disappear; Original colors restores both in one keystroke. Switching re-renders only that message's iframe (one class and the inset wrapper), then re-runs its wide-HTML fit. The choice lasts for the session, per message; View › Original Colors carries a checkmark while the focused message shows them.

| State | Treatment |
|---|---|
| Rest | as above |
| Hover | header actions and address appear |
| Focused (`n`/`p`, Tab) | ring around the sheet outside a {{border.focusRing.gapAroundSheets}} pt `canvas` gap |
| Target (several expanded, or keycaps hidden) | {{border.strong.width}} pt `ruleStrong` edge; footer keycaps |
| Starred | `star.fill` after the name, at rest |
| Unread | pip before the name |
| Loading body | skeleton bars (§5.10), only while a body fetch is actually in flight (and after {{motion.duration.skeletonDelay}} ms); never as a placeholder for a fetch that is not running |
| Body not downloaded, offline | the stored snippet stands in for the body: `reading` (or `readingSans`) in `ink2`, at the indent, inside the measure, ending in “…”; {{layout.reader.offlinePreviewGap}} pt below it a neutral banner (§5.38, `fill`): `wifi.slash` `ink2` + “The full message will load when you're back online.” No action and no skeleton: when the connection returns the fetch starts by itself, the skeleton shows while it runs, then the body replaces the preview. Attachments known from the metadata still show as chips. VoiceOver reads the preview, then the notice |
| Body failed (online; the fetch itself failed) | “Couldn't load this message · Retry” as a danger banner (§5.38) in place of the body |
| Pending send | full contrast; the date reads “Sending…” with a {{layout.progress.spinner.0}} pt spinner. A reply in the outbox (scheduled or sending; not a forward, which starts its own conversation) shows as the newest sheet of the conversation it answers, built from the outbox row: its plain-text part set as a plain body, no header actions and no footer, never the target. It goes when the send leaves or is undone; the provider's copy arrives with the next sync |
| Dark mode, styled HTML that declares colours | **Adapted** by default, with the Original colors notice; **Original colors** on request (⇧⌘O, the hover action, More or the notice), which puts the body on the white `originalPage` inset. Both renderings are specified above, under “Colour in dark appearances” |

### 5.15 Quoted-text toggle (the elision mark)

{{TABLE:layout:quotedToggle}}

`ss.elide` {{layout.quotedToggle.glyph}} pt + `label` “Show quoted text” / “Hide quoted text”.

| State | Fill | Text and glyph |
|---|---|---|
| Folded, rest | `fill` | `ink2`, “Show quoted text” |
| Folded, hover | `fill + hover` | `ink` |
| Folded, pressed | `fill + pressed` | `ink` |
| Unfolded, rest | `accentWash` | `accent`, “Hide quoted text” |
| Unfolded, hover | `accentWashHover` | `accent` |
| Unfolded, pressed | `accentWashPressed` | `accent` |
| Focused (either) | ring outside a {{border.focusRing.gap}} pt `sheet` gap | unchanged |

The label carries the state; `accent` keeps 4.5:1 on all three unfolded fills in every mode (§7). In the composer the folded original is a glyph-only {{layout.quotedToggle.composerChip}} pt chip followed by the attribution the message will carry, with the author's name only: “On 1 Nov 2026 at 23:39, Ben Carter wrote:” (a forward: “Forwarded message from Ben Carter · 1 Nov 2026 at 23:39”), in `snippet` `ink3`; the date is absolute, as sent, never “Today”. Clicking either unfolds it. Unfolding animates the quote height (`dur.standard`; Reduce Motion: instant). Revealed quotes use the shared quote style (`layout.textStyle`): a {{layout.textStyle.quoteBar}} pt `rule` leading bar and a {{layout.textStyle.quoteIndent}} pt indent, text in `ink2`, in the reader and the composer alike.

### 5.16 Remote-images banner and Original colors

The first element of a body whose remote images are blocked. Neutral: privacy is not a warning.

{{TABLE:layout:banner}}

| Part | Spec |
|---|---|
| Banner | `fill` over `sheet`, radius {{layout.banner.radius}} |
| Glyph | `photo` {{layout.banner.glyph}} pt `ink2` |
| Copy | “3 remote images hidden to protect your privacy.” (`snippet`, `ink`); “3 remote images hidden.” below {{layout.banner.narrowBreakpoint}} pt |
| Action | link button “Load images” (`label`, `accent`), {{layout.button.minHit}} pt hit. Loading is per message, as `docs/ARCHITECTURE.md` specifies; there is no per-sender allowlist |
| Dismissal | disappears when the images load; no close button |

States: rest; action hover (the link gains its {{layout.textStyle.linkUnderline}} pt underline; no wash: link buttons never take one, §5.24); action pressed (underline kept, label `ink2`: a `pressed` wash behind `accent` on this `fill` banner would fall to 4.22:1 in Dark); action focused (ring); loading ({{layout.progress.spinner.0}} pt spinner replaces the glyph, “Loading 3 images…”); partial failure (“2 images couldn't load” with `exclamationmark.triangle.fill` in `warning`).

**Original colors notice** (warning banner, dark appearances only) at the top of a styled body whose `declaresColors` flag is set. Its two states are the two renderings of §5.14 (“Colour in dark appearances”): **Adapted** (the default: Quire inks on the dark sheet, the sender's colours removed) and **Original colors** (the body exactly as sent, on the white `originalPage` inset with {{layout.reader.originalInsetPad}} pt padding). The notice itself always sits on the dark sheet, above the inset, never inside it.

| State | Glyph | Copy | Action |
|---|---|---|---|
| Adapted (default) | `circle.lefthalf.filled` `warning` | “This message uses its own colours.” | “Original colors” (`labelStrong` in `ink`, {{layout.button.minHit}} pt hit) |
| Original colors shown | `circle.lefthalf.filled` `warning` | “Showing the sender's colours.” | “Adaptive colors” |

Hover and pressed put `hover` / `pressed` behind the action; focus rings it. A trailing dismiss button (`xmark` {{layout.banner.dismissGlyph}} pt `ink2`, {{layout.button.minHit}} pt hit, tooltip “Don't Show Again”; `xmark` is in the reader symbol set, §4.11) hides the notice **everywhere**, from then on (one app preference, `originalColorsNoticeDismissed`); the hover action, More and ⇧⌘O keep the toggle one step away, and View › Original Colors carries a checkmark when on. The notice sits after the images banner when both apply (the one-banner-per-message rule of §5.38 counts the images banner as content, not status).

### 5.17 Attachment chip

{{TABLE:layout:attachmentChip}}

Anatomy: type tile ({{layout.attachmentChip.tile}} pt, radius {{layout.attachmentChip.tileRadius}}, `fill`, {{layout.attachmentChip.tileGlyph}} pt symbol `ink2`: `doc`, `doc.richtext`, `photo`, `tablecells`, `doc.zipper`, `film`; or a Quick Look thumbnail when cached) · name (`label`, `ink`, middle-truncated) over meta (`meta` `ink3`: “PDF · 240 KB”). Edge: inset hairline `rule`; fill `sheet`.

| State | Change |
|---|---|
| Hover | `sheet + hover`, edge `ruleStrong`, meta reads “Space to Quick Look” |
| Pressed | `sheet + pressed` |
| Focused | ring ({{border.focusRing.gap}} pt gap) |
| Downloading | meta replaced by a determinate contrail {{layout.attachmentChip.progressWidth}} × {{layout.attachmentChip.progressHeight}} pt on a `rule` track, shown once the fetch outlasts 150 ms (a cached file never flashes it). Its length is the share of the file that has arrived, measured against the length the server states or, without one, the attachment's listed size, and stops just short of full until the file is decoded and stored; it moves at most about ten times a second. Only while the size of what is arriving is unknown (no listed size and no stated length) does the contrail sweep, indeterminate, Reduce Motion a still segment; a length learned later turns it determinate. The meta returns when the fetch ends; a failure shows the Failed state |
| Error | tile glyph `exclamationmark.triangle.fill` `danger`; meta “Couldn't download · Retry” in `danger`, “Retry” in `metaStrong` `accent` |
| Dragging out | lifts with `e2` (the only shadowed chip state) |

Click or Space opens Quick Look; double-click opens with the default app; context menu: Quick Look, Open, Save to Downloads, Save As…, Copy.

### 5.18 Quick reply bar

Docked to the bottom of the reader, drawn **over** the web view: the web view always fills the reader below the header, and the shell is told the bar's height as a bottom inset (`ss.setBottomInset(px)`, once per height change), so the last message can scroll above the bar. The web view's frame never changes while the bar grows.

{{TABLE:layout:quickReply}}

**Anatomy and metrics** (x from the field's leading edge, y from its top):

| Part | Spec |
|---|---|
| Bar | {{layout.quickReply.rest}} pt at rest = {{layout.quickReply.barPadY}} + field {{layout.quickReply.field}} + {{layout.quickReply.barPadY}}; `paper`, top hairline |
| Field | on the reading column; radius {{layout.quickReply.fieldRadius}}; `sheet`; {{border.strong.width}} pt `ruleStrong` edge; text padding {{layout.quickReply.fieldPadTop}} top, {{layout.quickReply.fieldPadBottom}} bottom |
| Face | the replying account's rail face at {{layout.quickReply.face}} pt with its ring ({{border.accountRing.gap}} pt `sheet` gap + {{border.accountRing.width}} pt account ink, so the ring's outer edge is 4 pt further out), face at x = {{layout.quickReply.faceX}}, y = {{layout.quickReply.faceTop}}; monogram New York Semibold {{layout.quickReply.faceMonogram}} pt ({{layout.quickReply.faceMonogramTwoLetter}} pt for two letters; `monogramSans` under the SF Pro font, §5.29) in `ink` |
| Text | `writing` ({{typography.writing.size}}/{{typography.writing.lineHeight}}) from x = {{layout.quickReply.textX}}; trailing inset {{layout.quickReply.restTrailing}} at rest (room for the keycap and send), {{layout.quickReply.focusedTrailing}} when focused |
| Placeholder | “Reply to Ben Carter…” (`writing`, `ink3`); “Reply all to Ben Carter and 2 others…” in Reply all mode |
| Trailing (rest) | send icon button {{layout.quickReply.restSend}} pt, `paperplane` {{layout.quickReply.restSendGlyph}} pt, `inkDisabled`, inset {{layout.quickReply.restSendInset}} from the trailing and top edges; keycap “R” {{layout.quickReply.restKeycapGap}} pt before it |
| Tool row (focused) | {{layout.quickReply.toolRow}} pt, {{layout.quickReply.toolRowGap}} pt under the last text line, {{layout.quickReply.toolRowBottom}} pt above the field's bottom, starting at x = {{layout.quickReply.textX}}: the mode tabs Reply · Reply all ({{layout.quickReply.modeGap}} pt apart), then after {{layout.quickReply.toolGroupGap}} pt Attach and Open in Composer (⇧⌘R) as {{layout.quickReply.toolIcon}} pt icon buttons with {{layout.quickReply.toolIconGlyph}} pt symbols, {{layout.quickReply.toolIconGap}} pt apart; trailing, {{layout.quickReply.sendInset}} pt from the edge, a small primary “Send” with keycap “⌘↩” {{layout.quickReply.sendKeycapGap}} pt before it |

**Growth.** Field height = {{layout.quickReply.fieldPadTop}} + lines × {{typography.writing.lineHeight}} + {{layout.quickReply.fieldPadBottom}} when not focused and showing one line; focused = {{layout.quickReply.fieldPadTop}} + lines × {{typography.writing.lineHeight}} + {{layout.quickReply.toolRowGap}} + {{layout.quickReply.toolRow}} + {{layout.quickReply.toolRowBottom}}. Focused and empty that is 66 (bar 88). The text grows to {{layout.quickReply.maxLines}} lines: field max {{layout.quickReply.fieldMax}}, bar max {{layout.quickReply.max}}, both **including** the tool row; past that the text scrolls inside the field. Unfocused with text, the field returns to {{layout.quickReply.field}} pt showing the first line, tail-truncated, so the reader does not jump when focus leaves. Height changes use `dur.standard` `ease.glide` (Reduce Motion: instant).

**Reply mode** (Reply · Reply all) is a pair of underline tabs (`QuireUnderlineTabs`, the only place Quire uses them): `label` with the reply glyph at {{layout.button.small.glyph}} pt; the active mode is `labelStrong` `ink` with a {{border.tabUnderline.width}} pt `ink` underline under the label ({{border.tabUnderline.width}} pt `ink3` when the window is not key). Labels are centred in the {{layout.quickReply.toolRow}} pt tool row (label box y = 6–22); the underline's top is at y = {{layout.quickReply.modeUnderlineY}} from the tool row's top (`quickReply.modeUnderlineY`), 2 pt below the label box and 2 pt above the row's bottom; the inactive one is `label` `ink2`. Hover / pressed on the inactive tab: `ink`. Focused: ring around the label, radius `r.sm`. Reply all is disabled (`inkDisabled`, skipped by Tab) when the message has one other participant. ← → switch while a tab is focused. From the list or the reader, R focuses the field in Reply mode and A in Reply all mode; while typing, single keys type, so the mode changes only through the tabs. VoiceOver: “Reply, selected, tab 1 of 2”.

| State | Look |
|---|---|
| Rest | as above |
| Hover | edge `ink3` |
| Focused, empty / with text | ring outside a {{border.focusRing.gap}} pt `paper` gap; tool row |
| Counting down (sent, inside the undo window) | the strip below replaces the field's contents |
| Error (could not queue the send) | {{border.error.width}} pt `danger` edge; text kept; the tool row's leading status reads `exclamationmark.triangle.fill` + “Couldn't send · Open in composer” in `danger` (`snippet`); Send stays enabled to retry |
| No one to reply to (the reply has no recipients) | text allowed; Send disabled, tooltip “No one to reply to”; the tool row shows `exclamationmark.triangle.fill` `warning` + “No one to reply to” (`snippet` `ink2`) and Open in Composer stays available |
| Disabled (a draft for this conversation is open in the composer) | `fill`, no edge, placeholder “Reply in the composer”; clicking brings that window forward |

**Sends from the quick reply stay in the bar.** The floating undo-send panel (§5.31) is for composer sends, whose window has closed; a quick reply is sent where the eyes already are. After ⌘↩ the field clears and its frame shows the **strip** for the undo window, so the bar keeps its height and nothing else moves:

| Strip state | Content (glyph {{layout.quickReply.stripGlyph}} pt, gap {{layout.quickReply.stripGap}}) | Duration |
|---|---|---|
| Counting | `paperplane.fill` `ink2` · “Sending in 4 s” (`body`, tabular, `ink`) · “to Ben Carter” (`snippet` `ink3`, truncates first) · trailing small secondary “Undo”, with the keycap “⌘Z” {{layout.quickReply.stripKeycapGap}} pt **before** it, outside the button (`quickReply.stripKeycapGap`; the same placement as “⌘↩” before the quick reply's Send. Only slip actions carry their keycap inside, because a slip action has no face for a keycap to sit beside); a {{layout.progress.contrail}} pt `accent` contrail along the strip's bottom inside edge drains over the undo window, and the seconds count down as text (Reduce Motion: the contrail steps once per second) | the undo window (Settings: 5 / 10 / 20 s) |
| Undone in time | the strip closes at once; the text returns to the field with the caret at its end, focused | — |
| Sent | `checkmark` `ink2` · “Sent” | {{motion.duration.sentConfirm}} ms, then the field returns (cross-fade `dur.quick`) |
| Undo too late | `checkmark` `ink2` · “Already sent” · “Undo came after the message left.” (`snippet` `ink3`) | {{motion.duration.stripNotice}} ms |
| Undone after moving on (the selection changed during the countdown) | `arrow.uturn.backward` `ink2` · “Not sent · draft kept in “Contoso rollout”” · link “Show” (selects that conversation) | {{motion.duration.stripNotice}} ms |
| Failed after the window | the bar is not involved: an error toast “Couldn't send your reply · Open draft” (§5.30) | toast rules |

**Signature.** The bar never shows the replying account's signature (§5.20), but a reply sent from it carries it: below the typed text after one empty line (in the HTML, the paragraph break the bar sends for every blank line), with nothing added between them. Open in Composer hands the typed text to a reply composer, which inserts the signature by its own rule, below that text.

During Counting, clicking the strip outside Undo or pressing R brings the field back for a new reply; the countdown then continues as the tool row's leading status (“Sending in 4 s · Undo”, `snippet`, with its contrail under it) until it resolves. The strip belongs to the bar, not to the conversation: it stays while the selection moves on. If the new reader state hides the bar (nothing or several selected, Drafts, Trash), the countdown moves to an undo-send panel (§5.31) for its remaining seconds, so Undo is never lost.

**Visibility.**

| Reader state | Quick reply |
|---|---|
| One conversation open (Inbox, Starred, Sent, All Mail; body loading or loaded; offline) | shown; offline sends queue and the strip reads “Will send when you're back online” after the window |
| Nothing selected; several selected | hidden; the web view takes the full height |
| Drafts | hidden (Continue Editing is the action, §5.19) |
| Trash | hidden; R / A / F still open the composer |
| Conversation emptied while open | hidden |

Keycaps never sit on accent fills: “⌘↩” is beside the Send button, not inside it. The R, ⌘↩ and ⌘Z keycaps hide below a {{layout.window.readerKeycapsMin}} pt reader (§5.36).

### 5.19 Reader multi-selection, drafts and empty reader

**Several selected.** With two or more conversations selected, the header kicker reads “Selection”, the headline “3 conversations selected”, and the header shows only the actions that can apply to all of them: Star · Archive · Trash (Star · Move to Inbox in Trash); the reply group is hidden and Star follows the all-starred rule (§5.12). The desk shows the empty-state style: “Three conversations, one keystroke.” with “E archives them · # moves them to Trash · S stars them” and keycaps (in Trash: “⇧I moves them to Inbox · S stars them”; in Drafts, where the header offers only Discard Draft: “# discards them”). The hint sets on one line in any reader wide enough for it, past the sentence's 300 pt (§5.9).

**Nothing selected.** The desk shows “No conversation selected” and “J K to move · ↩ to open”.

**Drafts.** Drafts are local (“Drafts you start here are kept on this Mac”). Selecting a draft row shows it read-only, so `j`/`k` through Drafts stays as fast as anywhere else:

| Part | Spec |
|---|---|
| Header | kicker “Draft · Contoso” (account dot as usual); headline = the draft's subject, or “New Message” in the placeholder style; actions Continue Editing (`ss.nib`, ↩) and Discard Draft (`trash`, #) |
| Sheet | one sheet: header “To Ben Carter · cc Tom Hughes” (`snippet` `ink2`; “No recipients yet” in the placeholder style) and the date “Edited 23:51” (`snippet` `ink3`); body in `writing` (it is unsent text, set as typed); a reply's quoted original folded behind the elision chip; attachments as chips |
| Footer | secondary “Continue editing” with keycap ↩, ghost “Discard draft…” (sentence case: reader content, §4.13; the header actions' tooltips keep the command names “Continue Editing  ↩” and “Discard Draft…  #”) |
| ↩, double-click on the row, Continue Editing | opens the composer with the draft, or brings its window forward if it is already open; the reader then shows the draft as “Open in a composer window” (`snippet` `ink3`) instead of its body |
| Discard | the “Discard this draft?” alert, reader form (§5.33: “Discard” destructive, “Cancel” default); on confirm the row leaves and the toast reads “Draft discarded · Undo” |

The quick reply is hidden in Drafts.

**Conversation emptied while open.** The desk shows the empty state “No messages to show” / “They were deleted or moved on another device.” (§5.9); the header keeps the subject; only Trash stays enabled; the quick reply is hidden.

### 5.20 Composer window and fields

{{layout.composer.width}} × {{layout.composer.height}} default (min {{layout.composer.minWidth}} × {{layout.composer.minHeight}}). The window has a transparent system title bar over `paper` ({{layout.window.composerTitlebar}} pt on macOS 15, {{layout.window.composerTitlebar26}} pt from macOS 26 on, read from the window, §3.2): the system draws the lights and the title, which is the subject, or “New Message” when the subject is empty; a hairline closes the band. No toolbar.

{{TABLE:layout:composer}}

| Part | Spec |
|---|---|
| Field rows | {{layout.composer.fieldRow}} pt (Subject {{layout.composer.subjectRow}}), `paper`; labels in a {{layout.composer.labelColumn}} pt column right-aligned from x = {{layout.composer.labelX}} (`snippet`, `ink3`: From, To, Cc, Bcc, Subject); values from x = {{layout.composer.valueX}}; hairlines between rows from x = {{layout.composer.labelX}} to {{layout.composer.fieldTrailing}} pt before the window's trailing edge (`layout.composer.fieldTrailing`), the same inset as the labels |
| From | borderless popup (§5.27): {{layout.composer.fromDot}} pt account-ink dot, {{layout.composer.fromDotGap}} pt, “Alex Morgan <alex@contoso.test>”, `chevron.up.chevron.down`; shown only with two or more accounts. Changing From changes the sending account and replaces the signature (below). Hovered or pressed, the face takes `raised + hover` / `raised + pressed` and the dot keeps its {{layout.popup.inkHalo}} pt `raised` halo (§5.27) |
| To / Cc / Bcc | token fields (§5.21); small ghost “Cc” and “Bcc” buttons trail the To row until used, the last one's trailing edge {{layout.composer.fieldTrailing}} pt from the window's edge, {{layout.composer.ccBccGap}} pt apart, centred on the row's first line |
| Subject | `composeSubject` (New York; `composeSubjectSans` when needed), `ink` |
| Body | `sheet`, padding {{layout.composer.bodyPadTop}} {{layout.composer.bodyPadRight}} 0 {{layout.composer.valueX}} (the text starts on the value axis); `writing`; text styles below |
| Folded original | the elision chip + “On 1 Nov 2026 at 23:39, Ben Carter wrote:” (§5.15) |
| Format row | toggled by the Format button or ⇧⌘T, remembered per window: a {{layout.composer.formatRow}} pt `paper` row with a top hairline directly above the bottom bar (and above the strip when attachments show) |
| Attachment strip | §5.22 |
| Bottom bar | below |

**Bottom bar.** {{layout.composer.bottomBar}} pt, `paper`, top hairline, padding x {{layout.composer.barPadX}}, everything centred vertically: Send (regular primary, §5.23) · the “⌘↩” keycap {{layout.composer.barKeycapGap}} pt after it · after {{layout.composer.barGroupGap}} pt, Attach (`paperclip`) and Format (`textformat`, `accentWash` when the format row is shown) as {{layout.listHeader.composeSize}} pt icon buttons {{layout.composer.barIconGap}} pt apart. Trailing, at {{layout.composer.barPadX}}: the status, `meta`, glyph {{layout.composer.statusGlyphGap}} pt before the words.

| Status | Glyph | Copy | Lasts |
|---|---|---|---|
| Loading the original (reply, forward) | {{layout.progress.spinner.0}} pt spinner (after {{motion.duration.spinnerDelay}} ms) | Loading original message… (`ink3`) | until loaded; the body is editable meanwhile |
| Original gone | `info.circle` `ink3` | The original message is no longer available. (`ink2`) | until the next status |
| Original failed | `exclamationmark.triangle.fill` `warning` | Couldn't load the original message; it won't be quoted. (`ink2`) | until the next status |
| Attachments failed (forward) | `exclamationmark.triangle.fill` `warning` | One attachment couldn't be loaded. / 2 attachments couldn't be loaded. (`ink2`) | until the next status |
| Rejected drop (folders, unreadable files) | `exclamationmark.triangle.fill` `warning` | one folder: “Folders can't be attached: “Project Files”.”; one unreadable file: ““budget.xlsx” couldn't be read, so it wasn't attached.”; several: “3 items weren't attached: folders and unreadable files are skipped.” (`ink2`; the tooltip lists every name). The readable files of the same drop are attached as usual; there is no alert | until the user edits the body |
| Saved | `checkmark` `ink3` | Draft saved (`ink3`) | until the next edit |
| Saving | — | Saving… (`ink3`) | while saving |
| Offline | `wifi.slash` `ink3` | Will send when you're back online (`ink3`) | while offline |

A newer status replaces an older one, except that the warnings stay until the user edits the body, so they are read.

**Mail links.** A `mailto:` link opened in another app (a link in Safari, Email in Contacts) opens a new composer, never a reply, from the account in scope: the account the main window is narrowed to, or under All Inboxes the first account in rail order. The link's To (its address part and any `to` field, combined), Cc, Bcc, Subject and body fill the fields (Cc and Bcc rows shown when filled; the body as plain text, its line breaks kept, followed by the account's signature as on any new message); every other field a link can carry (`In-Reply-To`, `attach`, anything else) is ignored. Focus goes to To when the link names nobody, else to Subject when it has none, else to the end of the link's body, above the signature. What the link filled in is the window's starting point, as a reply's prefill is, so closing it untouched keeps no draft. Nothing is sent until Send. With no account the main window comes forward on the welcome screen (§5.39) and no composer opens. Settings › General says whether SuperSparrow opens mail links (§5.40).

**Signature.** Each account may have a signature, set in Settings › Accounts (§5.40) and empty by default. It is text in the body like any other: the composer inserts the From account's signature, when it has one, on a new message, a reply and a forward (a mail link's message and the quick reply's hand-off included), one empty line below the line the caret starts on and so above the folded original. Nothing else is added: no “-- ” line, no rule, no extra spacing. It is set in the composer's own formatting (`writing`; bold, italic, underline and links as typed in Settings), and the user selects, edits and deletes it as any other text; the caret starts where it does without one, above it. Text typed into it or after it is the user's.

| Event | The body |
|---|---|
| A new message, reply or forward opens | the typed or prefilled text (if any), the line break ending it, one empty line, the signature; nothing when the account has none |
| From changes, the signature still there | the inserted signature is replaced, as a whole, by the new account's; if the user edited inside it, the edits go with it. Text before and after it stays. When the new account has none, the signature goes with the empty line before it |
| From changes, the signature deleted by the user | nothing is added, for this account or any other chosen later in the window |
| From changes, the body has none because the previous account had none (or a From change removed it) | the new account's signature is added below what was written, one empty line after it |
| A kept draft or an undone send reopens | exactly as left: no second signature, and a From change replaces only a signature still in it, never adds one |

A From change is one undoable edit: Edit › Undo in the body restores the body as it was before it (the From popup keeps its choice). A From change that edits the body first closes the link popover if it is open (a click on From leaves focus in it), since the selection it would link has moved. The signature alone is not worth keeping: a message holding nothing the user wrote but its signature closes without a draft (below); text typed inside it counts as written. Settings' changes reach composers opened afterwards, a New Message from a recipient token in a window already open included; a window already open keeps the signatures it opened with.

**Closing, discarding and the subject check.** Drafts are kept on this Mac and autosaved, so closing never asks.

| Action | Result |
|---|---|
| ⌘W, the red light or File › Close Window, with content worth keeping | no alert: the last edit is saved synchronously, the window closes, and the draft stays in Drafts (“Edited 23:51”); no toast. ↩ on it in Drafts reopens it (§5.19) |
| The same with nothing worth keeping (no recipient, subject, attachment or typed body text: at most the folded original and the signature) | the window closes and no draft is kept |
| Message › Discard Draft… (composer windows; `trash`) | the alert “Discard this draft?”, composer form (§5.33: “Discard” destructive, “Keep Writing” default); confirming closes the window, removes the draft and shows “Draft discarded · Undo” in the main window, where Undo reopens the composer with the draft |
| ⌘↩ or Send with an empty or whitespace-only subject | the sheet alert “Send without a subject?” / “Messages without a subject are easy to miss.” / “Add Subject” (default, ↩ and Esc; focuses the Subject field) and “Send Anyway”. It asks every time; quick-reply sends never ask, because a reply's subject is never empty |
| Close while a send is starting (between ⌘↩ and the undo-send panel) | the window cannot close; the panel replaces it at once |

**Format row.** At x = {{layout.composer.labelX}}: Bold · Italic · Underline, then after {{layout.composer.formatGroupGap}} pt Bulleted list · Numbered list · Quote, then after {{layout.composer.formatGroupGap}} pt Link, as {{layout.composer.formatToggle}} pt icon toggles {{layout.composer.formatGap}} pt apart (symbols in §4.11, {{layout.iconSize.inText}} pt). States: off `ink2`; hover `hover` wash, `ink`; pressed `pressed`; **on** (the style applies at the caret or across the whole selection) `accent` on `accentWash` (hover `accentWashHover`, pressed `accentWashPressed`); mixed selection shows off; focused ring. Each toggle's tooltip names its shortcut (“Bold  ⌘B”). It is a docked row, not a popover, so it never covers text and needs no motion.

**Text styles in the body** (`layout.textStyle`, shared with the reader so a reply looks the same before and after sending): links `accent`, {{layout.textStyle.linkUnderline}} pt underline at offset {{layout.textStyle.linkUnderlineOffset}}; block quotes a {{layout.textStyle.quoteBar}} pt `rule` leading bar and {{layout.textStyle.quoteIndent}} pt indent, text `ink2` (the composer's 3 / 16 quote of today becomes 2 / 12); lists indent {{layout.textStyle.listIndent}} pt per level with the marker (“•”, or tabular numerals with a period) in `ink2` and {{layout.textStyle.listMarkerGap}} pt before the text; paragraphs have no extra spacing (what you type is what is sent).

**Link popover (⌘K, or the Link toggle).** App-drawn because it anchors to the selection: `raised`, `e2`, radius {{layout.composer.linkPopoverRadius}}, padding {{layout.composer.linkPopoverPad}}, width {{layout.composer.linkPopoverWidth}}; `ruleStrong` edge in Increase Contrast. **Position:** its top {{layout.composer.linkPopoverOffsetY}} pt below the bottom of the selection's last line (`composer.linkPopoverOffsetY`), or its bottom {{layout.composer.linkPopoverOffsetY}} pt above the selection's first line when there is no room below; its leading edge at the selection's start on that line minus {{layout.composer.linkPopoverPad}} pt, so the Link field starts under the selected text (`linkPopoverAlign`: selectionStart; with an empty selection, the caret); clamped to stay {{layout.composer.popoverEdgeMin}} pt inside the window's edges (`composer.popoverEdgeMin`). Content, {{layout.composer.linkPopoverGap}} pt apart: a “Link” field ({{layout.textField.height}} pt text field, placeholder “https://” `ink3`, focused on open) and, only when nothing is selected, a “Text” field; then a row with, when editing an existing link, ghost “Remove Link” leading, and trailing ghost “Cancel” and small primary “Add Link” (“Save” when editing). ↩ confirms, Esc cancels, Tab cycles inside. Invalid input: field error “Enter a web address or an email address.” (§5.25). In `dur.quick` fade; out `dur.quick`. Clicking an existing link in the body places the caret; ⌘K on it opens the popover in edit mode.

**Tab order.** From (when shown) → To → Cc → Bcc (each once shown) → Subject → Body → attachment chips (← → between them) → Send → Attach → Format → format toggles (when shown) → back to From. ⇧Tab reverses. In the body, Tab inserts a tab, or indents inside a list item; ⌃Tab and ⌃⇧Tab move focus out, as in every macOS text view. The Cc and Bcc buttons join the loop only with Full Keyboard Access (⇧⌘C and ⇧⌘B reveal those rows from anywhere).

| State | Look |
|---|---|
| Editing | as above |
| Field row focused (From, To, Cc, Bcc, Subject) | the **inset ring** (§4.1): {{border.focusRing.width}} pt ({{border.focusRing.widthHC}} pt in Increase Contrast) `focus`, from x = {{layout.composer.focusRingX}} to {{layout.composer.fieldTrailing}} pt before the trailing edge ({{layout.composer.focusRingButtonGap}} pt before the Cc / Bcc buttons on the To row while they show), its outer edge {{layout.composer.focusRingInsetY}} pt inside the row's top and bottom (30 pt tall in a {{layout.composer.fieldRow}} pt row, 36 pt in the Subject row, growing with wrapped token lines), radius `r.sm` ({{layout.composer.focusRingRadius}}); drawn inside the row, so it never touches the hairlines; never animated; not drawn while the window is not key. The From popup shows the same ring when focused. While a token is selected the ring moves from the row to that token (§5.21) |
| Body focused | the insertion point (`accent`) and the selection only: the one exception in §4.1; no ring |
| Prefilling | status “Loading original message…”; the folded-original chip appears when it loads |
| Dragging files over | the body shows a {{layout.composer.dropOutline}} pt dashed `focus` outline inset {{layout.composer.dropInset}} pt, radius `r.lg`, and “Drop to attach” in `label` `accent`, centred in the outline (`accent` on `sheet`, asserted at 4.5:1) |
| Sending | the window closes into the undo-send panel (§5.31) |
| Send failed | the window reopens with a multi-line danger banner (§5.38) under the field rows, inset {{layout.composer.bannerInsetX}} pt from the window's sides and {{layout.composer.bannerInsetY}} pt below the last row's hairline and above the body text: “Couldn't send: Microsoft 365 rejected the attachment size.” (the reason in plain words). No link: Send is the retry. It clears on the next send |
| Offline | status “Will send when you're back online” |
| Window not key | Send draws as secondary (§3.4) |

### 5.21 Address token and autocomplete

{{TABLE:layout:token}}

A {{layout.token.height}} pt pill, padding 0 {{layout.token.padX}}, {{layout.token.gap}} pt between tokens, `body`. Content: display name, or the address; the tooltip shows the full address.

**Growth is capped.** Tokens wrap inside the row, which grows by {{layout.token.lineGrow}} pt per line up to {{layout.token.maxLines}} lines: {{layout.token.rowMax}} pt = {{layout.composer.fieldRow}} + 2 × {{layout.token.lineGrow}} (`token.maxLines`, `token.rowMax`). Past that the focused row scrolls inside itself (vertical, scroller only while scrolling) and keeps the caret's line in view, so Subject and the body never move further down. When focus leaves the row it collapses to one line: the tokens that fit, then “+N more” (`body` `ink2`, {{layout.token.moreGap}} pt after the last visible token, `token.moreGap`), a borderless button; clicking it, or tabbing into the row, expands the row again. An invalid token is never hidden behind “+N more”: it is moved into the visible line. VoiceOver reads every recipient in either state.

| State | Fill | Text |
|---|---|---|
| Rest | `fill` | `ink` |
| Hover | `pressed` wash | `ink` |
| Selected (click, ← →; window not key) | `accentFill` | `onAccent` |
| Selected, window key | `accentFill`; the focus ring moves from the field row to this token, outside a {{border.focusRing.gapOnAccentFill}} pt gap, so focus is never shown twice; it returns to the row when the caret does | `onAccent` |
| Being edited | turns back into text with the caret | |
| Invalid | `dangerWash` + {{border.strong.width}} pt `danger` edge | `danger`, leading `exclamationmark.triangle.fill` {{layout.token.invalidGlyph}} pt; VoiceOver “invalid address” |
| Disabled (sending) | `fill` | `inkDisabled` |

⌫ removes the selected token; ↩ or double-click edits it; the context menu offers Copy Address, Edit, Remove, New Message.

**Autocomplete** (app-drawn because it must track the caret; it opens and closes instantly and its highlight moves without animation): `raised` popover, `e2`, radius {{layout.autocomplete.radius}}, padding {{layout.autocomplete.pad}}, width ≥ {{layout.autocomplete.width}}. **Position:** anchored to the start of the text being completed (`autocomplete.anchor`: tokenStart, the x where the in-progress token begins), with its leading edge {{layout.autocomplete.offsetX}} pt from there (`autocomplete.offsetX` = −(pad + rowPadX + avatar + avatarGap)), so the suggested names line up with the typed letters; its top {{layout.autocomplete.offsetY}} pt below the bottom of the token line that holds the caret (`autocomplete.offsetY`; the line, not the row, which may be taller once it wraps); it flips above that line when there is no room below, and it is clamped {{layout.composer.popoverEdgeMin}} pt inside the window (`composer.popoverEdgeMin`). Rows: {{layout.autocomplete.row}} pt, radius {{layout.autocomplete.rowRadius}}, padding x {{layout.autocomplete.rowPadX}}: {{layout.autocomplete.avatar}} pt avatar · {{layout.autocomplete.avatarGap}} pt · name (`body` `ink`, the typed prefix `bodyStrong`, wherever it matches) over the address (`meta`, `ink3`). At most {{layout.autocomplete.maxRows}} rows; ↑ ↓ move, ↩ or Tab accepts, Esc closes. Increase Contrast adds the `ruleStrong` edge.

**The highlighted row is a selection, drawn like list selection** (§4.1: Iron Gall never fills more than a button): `selWash` with a {{layout.autocomplete.highlightRule}} pt `selRule` margin rule flush with the row's leading edge (clipped by the row's radius), inks unchanged (name `ink`, address `ink3`, both tested on `selWash`), and a trailing “↩” keycap in the normal raised style (§5.36), {{layout.autocomplete.keycapTrailing}} pt from the row's trailing edge. The rule is the state (≥ 3:1 against the wash and the popover); the wash is a scan cue. The popover only exists in a key composer, so there is no idle variant. Hover moves the highlight (no separate hover wash).

{{TABLE:layout:autocomplete}}

### 5.22 Attachment strip

A {{layout.composer.strip}} pt band above the composer's bottom bar (and the format row), `sheet`, top hairline, padding x {{layout.composer.stripPadX}}, horizontally scrollable, shown only when there are attachments. Chips are {{layout.composer.stripChip}} pt high, centred in the band, {{layout.composer.stripChipSpacing}} pt apart, at most {{layout.composer.stripChipMaxWidth}} pt wide (the name middle-truncates first), radius {{layout.composer.stripChipRadius}}, inset hairline `rule`. Inside, from the leading edge: padding {{layout.composer.stripChipPadLeft}} · type glyph {{layout.composer.stripGlyph}} pt `ink2` · {{layout.composer.stripChipInnerGap}} · name (`label`, `ink`) · {{layout.composer.stripChipInnerGap}} · size (`meta`, `ink3`) · {{layout.composer.stripChipInnerGap}} · remove button ({{layout.composer.removeVisual}} pt `fill` disc, `xmark` {{layout.composer.removeGlyph}} pt `ink3`, {{layout.button.minHit}} pt hit; hover `ink`) · padding {{layout.composer.stripChipPadRight}}.

| State | Look |
|---|---|
| Rest | as above |
| Adding / uploading | size reads “3.1 of 4.8 MB”; a determinate contrail runs along the chip's bottom inside edge |
| Error | glyph `exclamationmark.triangle.fill` and name in `danger`; tooltip names the problem (“Too large for Microsoft 365: 150 MB limit”) |
| Focused | ring; ⌫ removes |

### 5.23 Send button

A primary button (§5.24) with `paperplane` {{layout.button.regular.glyph}} pt and the label “Send”: regular in the composer, small in the quick reply. The “⌘↩” keycap sits beside it.

| State | Look |
|---|---|
| Rest | `accentFill`, `onAccent` label |
| Hover / pressed | `accentFillHover` / `accentFillPressed` |
| Focused | ring outside a {{border.focusRing.gapOnAccentFill}} pt gap |
| Disabled (no valid recipient) | `fill`, `inkDisabled`; tooltip “Add a recipient” or “Fix the address it-desk@contoso” |
| Sending | spinner + “Sending…”; at rest the button is as wide as “Send” and it grows once to fit the gerund when sending starts (the window closes as soon as the message is queued) |
| Window not key | secondary look |

### 5.24 Buttons

| Variant | Fill | Label | Edge |
|---|---|---|---|
| Primary | `accentFill` | `onAccent`, the size's strong role | none |
| Secondary | `raised` | `ink`, the size's role (Medium) | {{border.strong.width}} pt `ruleStrong` inset |
| Ghost (tertiary) | none | `ink2`, the size's role, optional leading glyph | none |
| Destructive | `dangerFill` | `onDanger`, the size's strong role | none |
| Link | none | `accent`, the size's role; underlined at rest only under Graphite (§3.1) | none |
| Icon | none | glyph `ink2` | none |

{{TABLE:layout:button}}

| State | Primary | Secondary | Ghost / Icon / Link | Destructive |
|---|---|---|---|---|
| Hover | `accentFillHover` | `raised + hover` | ghost and icon: `hover` fill, `ink`. Link: **no fill**; it gains a {{layout.textStyle.linkUnderline}} pt underline at offset {{layout.textStyle.linkUnderlineOffset}} and stays `accent` | `dangerFillHover` |
| Pressed | `accentFillPressed` | `raised + pressed` | ghost and icon: `pressed` fill, `ink`. Link: **no fill**; underline kept, label `ink2` | `dangerFillPressed` |
| Focused | ring, {{border.focusRing.gapOnAccentFill}} pt gap | ring, {{border.focusRing.gap}} pt gap | ring, {{border.focusRing.gap}} pt gap | ring, {{border.focusRing.gapOnAccentFill}} pt gap |
| Disabled | `fill`, `inkDisabled` | `fill`, `inkDisabled`, no edge | `inkDisabled`, no fill | `fill`, `inkDisabled` |
| Loading | {{layout.progress.spinner.0}} pt spinner (in the label colour) replaces the glyph, the label becomes the gerund (“Sending…”), width kept | same | spinner replaces the glyph | same |
| Window not key | secondary look | unchanged | unchanged | unchanged |

Sizes: small {{layout.button.small.height}} (padding {{layout.button.small.padX}}, radius {{layout.button.small.radius}}, `{{layout.button.small.font}}` / `{{layout.button.small.fontStrong}}`, glyph {{layout.button.small.glyph}}), regular {{layout.button.regular.height}} ({{layout.button.regular.padX}}, {{layout.button.regular.radius}}, `{{layout.button.regular.font}}` / `{{layout.button.regular.fontStrong}}`, {{layout.button.regular.glyph}}), large {{layout.button.large.height}} ({{layout.button.large.padX}}, {{layout.button.large.radius}}, `{{layout.button.large.font}}` / `{{layout.button.large.fontStrong}}`, {{layout.button.large.glyph}}); icon buttons {{layout.button.icon}} pt square with radii {{layout.button.iconRadius}} (`button.icon`, `button.iconRadius`): {{layout.button.icon.0}} pt in tool rows and Settings, {{layout.button.icon.1}} pt for the sheet header's hover actions and the cheat sheet's close button, {{layout.button.icon.2}} pt for window-level actions. **Link buttons never take a wash**: they sit on banners and washes (`fill`, `infoWash`, `dangerWash`, `selWash`) where a further wash pulls `accent` under 4.5:1, so they show hover and press in the underline and the label colour instead (pairs in §7). Labels are vertically centred on the role's line height. Every button's hit rect is at least {{layout.button.minHit}} × {{layout.button.minHit}}. One primary per window or sheet. Destructive buttons are never the default button.

### 5.25 Text field

{{layout.textField.height}} pt ({{layout.textField.settingsHeight}} in Settings rows), radius {{layout.textField.radius}}, `sheet`, {{border.strong.width}} pt `ruleStrong` inset edge, padding 0 {{layout.textField.padX}}, `body`; placeholder `ink3`; caret `accent`. OAuth IDs and secrets use `mono`. Labels sit beside the field, right-aligned, in Settings forms. AppKit draws it as an `NSTextField` with `isBezeled = false` inside a layer-backed container that paints face, edge and ring; SwiftUI as `QuireFieldStyle` (§8.3). Both draw the Quire ring, never the system one.

| State | Look |
|---|---|
| Hover | edge `ink3` |
| Focused | edge kept; ring outside a {{border.focusRing.gap}} pt gap |
| Filled | as rest |
| Error | {{border.error.width}} pt `danger` edge; help line {{layout.textField.helpGap}} pt below in `meta` `danger` with `exclamationmark.triangle.fill`: “That doesn't look like a Google client ID.” |
| Disabled | `fill`, no edge, `inkDisabled` |
| Secure | bullets with {{layout.textField.secureTracking}} pt tracking; a reveal button only on hover (a small icon button, `{{icon.reveal}}`, `{{icon.conceal}}` while revealed, centred in the field's height at its trailing edge); while the secret shows, the button stays until it is hidden again |

### 5.26 Checkbox, radio and toggle

| Control | Metric | Off | On | Mixed |
|---|---|---|---|---|
| Checkbox | {{layout.checkbox.size}} pt, radius {{layout.checkbox.radius}} | `sheet` + `ruleStrong` edge | `accentFill` + `checkmark` {{layout.checkbox.glyph}} pt `onAccent` | `accentFill` + {{layout.checkbox.mixedBar}} pt bar |
| Radio | {{layout.radio.size}} pt circle | `sheet` + `ruleStrong` edge | `accentFill` + {{layout.radio.dot}} pt `onAccent` dot | — |
| Toggle | {{layout.toggle.width}} × {{layout.toggle.height}} track, {{layout.toggle.knob}} pt knob, {{layout.toggle.inset}} pt inset | track `fill` + `ruleStrong` edge, knob leading | track `accentFill`, knob trailing | — |

**Knob.** Face `knob`; a {{layout.toggle.knobEdge}} pt `{{layout.toggle.knobEdgeColor}}` edge in both states; a static contact shadow, the only control shadow: offset (0, {{layout.toggle.knobShadow.y}}), blur {{layout.toggle.knobShadow.blur}}, colour `{{layout.toggle.knobShadow.light}}` Light, `{{layout.toggle.knobShadow.dark}}` Dark, `{{layout.toggle.knobShadow.lightHC}}` Light IC, `{{layout.toggle.knobShadow.darkHC}}` Dark IC (`layout.toggle.knobShadow`). The knob's face is nearly the track's colour in light modes (white on `sheet + fill`); its **edge** is what shows where it sits, and that edge is asserted at ≥ 3:1 against the off track on a group (`sheet + fill`) and on the desk (`canvas + fill`), in all four modes (§7). Those pairs hold in every state because **neither the track nor the knob ever takes a wash**: a pressed wash on the off track would drop the edge to 2.6–2.9:1, and a wash on the knob face does nothing visible in dark modes, where washes are light ink on a light knob. So the press is a shape: the knob stretches from {{layout.toggle.knob}} to {{layout.toggle.knobPressedWidth}} pt wide (`toggle.knobPressedWidth`) toward the track's centre, its edge, face and height unchanged, as native switches do; hover changes nothing. On the `accentFill` track the face itself carries ≥ 3:1 in every state. The knob travels in `dur.quick` `ease.glide` (Reduce Motion: instant).

| State | Checkbox / radio | Toggle |
|---|---|---|
| Rest | as above | as above |
| Hover | off: face `sheet + hover`; on: `accentFillHover` | no change (as native switches) |
| Pressed | off: face `sheet + pressed`; on: `controlOnPressed` (darker than `accentFill` in light modes, lighter in dark modes; ≥ 3:1 on `sheet` and `canvas`, checkmark ≥ 3:1 on it) | the knob stretches to {{layout.toggle.knobPressedWidth}} pt toward the centre (instant on mouse-down, back in `dur.quick` on release, or as it travels if the press toggles it); track and knob colours do not change |
| Focused | ring outside the box, {{border.focusRing.gap}} pt gap off, {{border.focusRing.gapOnAccentFill}} pt on | ring outside the track, same gaps |
| Disabled | {{layout.checkbox.disabledOpacity}} opacity on the control, label `inkDisabled` | same |
| Window not key | unchanged (on fills stay Iron Gall, §3.4) | unchanged |

Labels are `body` `ink`, {{layout.checkbox.labelGap}} pt from the control, and part of the hit area. Toggles apply at once; checkboxes are for options in a form; radios for one of a few (List density). These are Quire-drawn everywhere, Settings included: AppKit custom `NSButton` cells; SwiftUI `QuireToggleStyle`, `QuireCheckboxStyle` and `QuireRadioGroup` (§8.3).

### 5.27 Popup button

{{layout.popup.height}} pt, radius {{layout.popup.radius}}, `raised`, {{border.strong.width}} pt `ruleStrong` inset, padding 0 {{layout.popup.padRight}} 0 {{layout.popup.padLeft}}, `body` `ink`, trailing `chevron.up.chevron.down` {{layout.popup.chevron}} pt `ink2`. Borderless variant (composer From): no fill or edge until hover. States: hover (`raised + hover`), pressed (menu opens; face `raised + pressed`), focused (ring outside a {{border.focusRing.gap}} pt gap), disabled (`fill`, `inkDisabled`, no edge). **An account dot or swatch in the label** (the From popup's {{layout.composer.fromDot}} pt dot, the Settings Colour popup's {{layout.settings.swatch}} pt swatch) sits on a {{layout.popup.inkHalo}} pt `raised` halo (`popup.inkHalo`), a disc drawn under the ink before the face's wash is clipped around it: at rest the halo is invisible on the `raised` face; hovered or pressed, the wash stops at the halo, so the ink always meets `raised`, its asserted surface (§4.2). (On `raised + pressed` Persimmon, Indigo, Umber, Azure and Mulberry would fall to 2.85–2.87:1 in Dark.) In the open menu the swatches are decorative, because each item's title names the ink, and they sit on the system highlight untested. The menu is a system `NSMenu` with a checkmark on the current value. In SwiftUI this is a `Menu` whose label is drawn by `QuirePopupLabel` (§8.3); the menu stays the system's.

### 5.28 Badges and tags

{{TABLE:layout:badge}}

| Badge | Metric | Colours |
|---|---|---|
| Unread count (rail) | {{layout.badge.height}} pt pill, min {{layout.badge.minWidth}}, padding 0 {{layout.badge.padX}}, `badge` role, capped at “{{layout.badge.cap}}+”; a {{layout.badge.cutout}} pt cut-out ring in the surface colour where it overlaps a tile | `accentFill` / `onAccent` |
| Message count (rows) | {{layout.badge.height}} pt, min {{layout.badge.rowMinWidth}}; exact numbers | `fill` / `ink2` (on any row fill, including both selection washes) |
| Dot | {{layout.badge.dot}} pt circle | `accent` |
| Attention | {{layout.badge.attention}} pt circle, `{{icon.attention}}` {{layout.badge.attentionGlyph}} pt `.semibold`, centred | `dangerFill` / `onDanger` |
| Tag | {{layout.tag.height}} pt, padding 0 {{layout.tag.padX}}, radius {{layout.tag.radius}}, {{border.strong.width}} pt `ruleStrong` inset, `tag` role (SF Pro {{typography.tag.size}} Medium, sentence case) | text `ink2`: “Gmail”, “Microsoft 365” (Settings account rows) |
| Title menu counts | system `NSMenuItemBadge(count:)`, numerals only (§5.4) | system |
| Dock | system red badge with the unified Inbox unread count | system |

Badges never animate when counts change.

### 5.29 Avatar

{{TABLE:layout:avatar}}

{{TABLE:avatarSizes}}

Face = tint (§4.3); initials New York Semibold, or SF Pro Semibold (`monogramSans`) under the SF Pro font (§4.4), at the sizes above. **Account faces are not avatars:** the rail tile, the Settings account row and the quick-reply face show the account's domain monogram on the account face wash, at {{layout.rail.monogram}} / {{layout.rail.monogramTwoLetter}} pt on a {{layout.rail.face}} pt face and {{layout.quickReply.faceMonogram}} / {{layout.quickReply.faceMonogramTwoLetter}} pt on a {{layout.quickReply.face}} pt face (one / two letters), always with the account ring; under the SF Pro font they are set in `monogramSans` at those sizes × {{typography.monogramSans.sizeRatio}} / {{typography.monogram.sizeRatio}}, rounded to the half point and never below {{typography.monogramSans.minSize}} pt, so the letters keep their optical size. Three sizes only; there is no contact popover in v1, and About is the system panel with the app icon. **Account ring**: {{border.accountRing.gap}} pt gap in the surface colour + {{border.accountRing.width}} pt ring in the account ink, outside the face, unified views only. A group conversation shows its most recent sender. Avatars are not interactive in rows; in the reader, hover shows the address tooltip.

### 5.30 Toast

{{TABLE:layout:toast}}

| Part | Spec |
|---|---|
| Slip | {{layout.toast.height}} pt, radius {{layout.toast.radius}}, `slip`, `slipEdge`, `e2`; padding 0 {{layout.toast.padRight}} 0 {{layout.toast.padLeft}} with an action, 0 {{layout.toast.padRightNoAction}} 0 {{layout.toast.padLeft}} without; gap {{layout.toast.gap}} |
| Content | the action's symbol {{layout.toast.glyph}} pt `onSlip2` · message (`bodyMedium`, `onSlip`): “Archived”, “Moved to Trash”, “Unstarred”, “Marked 3 as unread”, “Archived 3 conversations” |
| Divider | 1 × {{layout.toast.divider}}, `onSlipEdge`; only when there is an action |
| Action | “Undo” (`bodyStrong`, `onSlip`), {{layout.toast.actionKeycapGap}} pt, keycap “Z” ({{layout.kbd.height}} pt, `onSlipEdge` outline; legend `onSlip2` at rest, `onSlip` while the action is hovered or pressed); {{layout.toast.action}} pt high, padding x {{layout.toast.actionPadX}} (`layout.toast.actionPadX`, `actionKeycapGap`), radius `r.sm` ({{layout.toast.actionRadius}}), no fill or outline at rest (the divider before it marks it as a separate control), {{layout.button.minHit}} pt hit |
| Contrail | {{layout.progress.contrail}} pt along the bottom edge in `onSlip`, draining over the toast's life ({{motion.duration.toastLife}} ms); it freezes while the pointer rests on the toast; only on toasts with an action |
| Placement | bottom centre of the list pane, {{layout.toast.aboveSyncLine}} pt above the sync line, max width = list width − 2 × {{layout.toast.sideMargin}} (the message truncates) |

**Variants.**

| Variant | Glyph | Message | Action | Life |
|---|---|---|---|---|
| Undoable action | the action's symbol | past tense (“Archived”) | Undo + Z | {{motion.duration.toastLife}} ms, contrail |
| Undo confirmation | `arrow.uturn.backward` | “Undid Archive”, “Undid Move to Trash”, “Undid Mark as Unread” (the command's menu name, §4.13) | none: no divider, padding right {{layout.toast.padRightNoAction}} | {{motion.duration.toastConfirm}} ms, no contrail |
| Error | `exclamationmark.triangle.fill` `onSlip2` | “Couldn't archive. Restored.”, “Couldn't send your reply” | optional “Details” / “Open draft”; never Undo | {{motion.duration.toastLife}} ms, contrail when it has an action |

Behaviour: in `dur.standard` (rise {{layout.toast.rise}} pt + fade, `ease.settle`); out `dur.quick` (`ease.leave`). One toast at a time: a new toast replaces the old one instantly, without stacking, and several actions within {{motion.duration.toastCoalesce}} ms coalesce into one (“Archived 3 conversations”). Z (or ⌘Z, by the precedence in §6.1) undoes the latest undoable action from anywhere in the main window while its toast is visible and for {{motion.duration.undoKeyGrace}} ms after; the confirmation toast then replaces it. Esc dismisses (§6.1). VoiceOver announces “Archived. Press Z to undo.” and “Undid Archive.” Reduce Motion: fades only; the contrail steps once per second.

| State | Look |
|---|---|
| Rest | as above |
| Action hover | `slipHover` behind the action; keycap legend `onSlip` |
| Action pressed | `slipPressed` behind the action; keycap legend `onSlip` |
| Action focused | {{border.focusRing.width}} pt `onSlip` ring (`border.focusRing.onSlipColor`; toasts join the Tab loop only with Full Keyboard Access) |

### 5.31 Undo-send panel

A non-activating floating `NSPanel` for **composer** sends (quick-reply sends count down in their own bar, §5.18), anchored to the main window's bottom-trailing corner ({{layout.undoPanel.inset}} pt inset from the window to the panel's visual edge, above the quick reply when visible; the active screen's visible frame when the main window is hidden). Several sends stack upward {{layout.undoPanel.stackGap}} pt apart.

{{TABLE:layout:undoPanel}}

**Window and visual frame.** The panel window is transparent (`isOpaque = false`, clear background, `hasShadow = false`) and larger than the slip it draws by {{layout.undoPanel.shadowMarginTop}} pt above, {{layout.undoPanel.shadowMarginSide}} pt at each side and {{layout.undoPanel.shadowMarginBottom}} pt below, so the `e3` shadow (drawn by the slip's layers with an explicit `shadowPath`) is never clipped. Insets and stacking measure the visual frame. Clicks on the transparent margin pass through to the window below.

**Anatomy** ({{layout.undoPanel.width}} × {{layout.undoPanel.height}}, radius {{layout.undoPanel.radius}}, `slip`, `slipEdge`): padding left {{layout.undoPanel.padLeft}} · `paperplane.fill` {{layout.undoPanel.glyph}} pt `onSlip2` · {{layout.undoPanel.glyphGap}} pt · text block (title top {{layout.undoPanel.titleTop}}: “Sending in 4 s”, `bodyMedium`, tabular, `onSlip`; {{layout.undoPanel.lineGap}} pt; “Re: Contoso rollout · to Ben Carter”, `meta`, `onSlip2`, tail-truncated) · {{layout.undoPanel.actionGap}} pt · the Undo action · padding right {{layout.undoPanel.padRight}}; a {{layout.progress.contrail}} pt contrail along the bottom edge draining linearly over the undo window ({{motion.duration.undoSendDefault}} ms by default; Settings offers {{motion.duration.undoSendChoices}} ms).

**The Undo action** has the toast action's metrics exactly: {{layout.undoPanel.action}} pt high, radius `r.sm` ({{layout.undoPanel.actionRadius}}, `layout.undoPanel.actionRadius`), padding x {{layout.undoPanel.actionPadX}}, “Undo” (`bodyStrong`, `onSlip`), then {{layout.undoPanel.actionKeycapGap}} pt and the keycap “⌘Z” (`onSlipEdge` outline). The one difference is a resting outline: the panel has no divider, so the outline is what says “button”, and it is therefore asserted at 3:1 (`onSlipEdge` on `slip`, §7).

| Action state | Fill | Label | Keycap legend |
|---|---|---|---|
| Rest | none; {{border.strong.width}} pt `onSlipEdge` inset outline (state-bearing, ≥ 3:1 on `slip`) | `onSlip` | `onSlip2` |
| Hover | `slipHover` | `onSlip` | `onSlip` |
| Pressed | `slipPressed` | `onSlip` | `onSlip` |
| Focused | {{border.focusRing.width}} pt `onSlip` ring | `onSlip` | as rest |
| Not the ⌘Z target (a newer toast took ⌘Z, §6.1) | as rest | `onSlip` | keycap hidden; the button still works by click |

| Panel state | Look |
|---|---|
| Counting | as above; hover does not pause (the send time is a promise) |
| Undo | the panel closes at once and the composer reopens with the draft |
| Sending | {{layout.progress.spinner.1}} pt `onSlip2` spinner in the glyph's place + “Sending…”, no action |
| Sent | `checkmark` + “Sent” for {{motion.duration.sentConfirm}} ms, then fades (`dur.quick`) |
| Undo too late | `checkmark` + “Already sent” / “Undo came after the message left.” for {{motion.duration.stripNotice}} ms |
| Failed | `exclamationmark.triangle.fill` + “Couldn't send” / “Your draft is kept on this Mac” + “Open draft” (same action styling, sentence case: slip content, §4.13) |

In: `dur.slow` (rise {{layout.undoPanel.rise}} pt + fade, `ease.settle`). Panels above a closing one drop into place instantly. Reduce Motion: no rise; the contrail steps once per second next to the numeric seconds.

### 5.32 g-sequence HUD and keyboard cheat sheet

**Arming.** G arms the sequence for {{motion.duration.gSequenceWindow}} ms from its key-down (`motion.duration.gSequenceWindow`; today's `KeyboardRouter.sequenceTimeout` of 1.5 s becomes 2 s, so the HUD, which appears at {{motion.duration.gHudDelay}} ms, stays readable for 1.5 s). Within the window, I, S, T, D, # or A completes the sequence; any other key disarms it and is consumed (it does nothing), and so does Esc. When the window ends the sequence disarms silently. The HUD never outlives the sequence: it shows only while the sequence is armed.

**HUD.** When no second key arrives within {{motion.duration.gHudDelay}} ms of G, a slip fades in (`dur.quick`) at the bottom centre of the list pane, where the toast sits; it replaces a visible toast, which does not come back. {{layout.gHud.width}} pt wide, radius {{layout.gHud.radius}}, padding {{layout.gHud.pad}}, `slip`, `slipEdge`, `e2`.

| Part | Spec |
|---|---|
| Header | {{layout.gHud.headerHeight}} pt row: keycap “G” ({{layout.gHud.keycap}} pt, on-slip style) + {{layout.gHud.keycapGap}} pt + “Go to…” (`bodyStrong`, `onSlip`) |
| Rows | {{layout.gHud.rowsTop}} pt below the header; rows of {{layout.gHud.row}} pt: keycap ({{layout.gHud.keycap}} pt) + {{layout.gHud.keycapGap}} pt + view name (`snippet`, `onSlip2`) for I, S, T, D, #, A |
| Size | height = {{layout.gHud.pad}} + {{layout.gHud.headerHeight}} + {{layout.gHud.rowsTop}} + 6 × {{layout.gHud.row}} + {{layout.gHud.pad}} = 190 |

The second key, any other key, Esc or the end of the {{motion.duration.gSequenceWindow}} ms window dismisses it (fade out `dur.quick`) together with the sequence. Typing “G I” quickly never shows it. It is not focusable.

**Cheat sheet** (? or ⌘/; Help › Keyboard Shortcuts) is an **in-window overlay**, not an `NSWindow` sheet: a layer-backed view above the split view of the main window.

| Part | Spec |
|---|---|
| Scrim | `scrim` over the whole window content below the title-bar zone's controls (the traffic lights stay usable); fades in `dur.quick` |
| Panel | {{layout.cheatSheet.width}} pt wide (= 2 × {{layout.cheatSheet.pad}} + {{layout.cheatSheet.columns}} × {{layout.cheatSheet.columnWidth}} + 2 × {{layout.cheatSheet.columnGap}}; it fits the {{layout.window.minWidth}} pt minimum window with 72 pt to spare on each side), centred horizontally, top at y = {{layout.cheatSheet.top}} (under the horizon), at least {{layout.cheatSheet.minMargin}} pt from the window bottom; `raised`, radius {{layout.cheatSheet.radius}}, `e3`, padding {{layout.cheatSheet.pad}}; `ruleStrong` edge in Increase Contrast. Its full height is 576 pt ({{layout.cheatSheet.pad}} + {{layout.cheatSheet.titleRow}} + {{layout.cheatSheet.headerGap}} + band 1 ({{layout.cheatSheet.sectionTitle}} + 8 × {{layout.cheatSheet.row}}) + {{layout.cheatSheet.sectionGap}} + band 2 ({{layout.cheatSheet.sectionTitle}} + 7 × {{layout.cheatSheet.row}}) + {{layout.cheatSheet.pad}}), so it fits whole in the default window (92 + 576 + 24 = 692 ≤ {{layout.window.defaultHeight}}); in a window shorter than 692 pt the bands scroll inside the panel under a fixed title row |
| Title row | {{layout.cheatSheet.titleRow}} pt: “Keyboard Shortcuts” (`title`) and a close button ({{layout.cheatSheet.close}} pt icon button, `xmark`, at {{layout.cheatSheet.closeInset}} pt from the top-trailing corner) |
| Sections | {{layout.cheatSheet.headerGap}} pt below the title: {{layout.cheatSheet.bands}} bands of {{layout.cheatSheet.columns}} columns, each {{layout.cheatSheet.columnWidth}} pt, {{layout.cheatSheet.columnGap}} pt apart: **Move · Act · Go** in the first band, **Write · Format · View** in the second, {{layout.cheatSheet.sectionGap}} pt between bands; each section opens with a {{layout.cheatSheet.sectionTitle}} pt `runningHead` `ink3` title |
| Rows | {{layout.cheatSheet.row}} pt: large keycaps ({{layout.cheatSheet.keycap}} pt, {{layout.cheatSheet.keycapGap}} pt apart) in a {{layout.cheatSheet.keyColumn}} pt key column, then the label (`snippet`, `ink`, sentence case, §4.13; it tail-truncates in the remaining 144 pt, which every label below fits); sequences as “G then I” (“then” in `meta` `ink3`, 6 pt either side); ranges as “⌘1 … ⌘9” |

**Content**, in this order. It is the whole single-key and command vocabulary of §6 and the menus, so nothing is learnable only from a menu; the overlay is generated from this table (`cheatSheetContent` in `tokens.json`), and the specimen draws it from the same data.

{{TABLE:cheatSheet}}

Alternates that duplicate a single key (⌘F for /, ⌘N for C, ⌘Z for Z, → and ← for ↩ and esc, ⌘/ for ?) are left out to keep one key per action; menus and tooltips name them.

Motion: in, the scrim fades (`dur.quick`) and the panel fades and scales from 0.98 (`dur.standard`, `ease.settle`); out, both fade in `dur.quick` (`ease.leave`). Reduce Motion: fades only.

Focus: on open the panel becomes first responder and traps focus (Tab moves only between its close button and its scroll area); nothing behind it responds to keys. Single-key shortcuts are swallowed while it is open, so learning them is safe. Dismissal: Esc, ? or ⌘/ again, ⌘W, the close button, or a click on the scrim; focus returns to where it was. VoiceOver treats it as a modal group titled “Keyboard Shortcuts”.

### 5.33 Alerts and sheets

System `NSAlert` presented as a window-modal sheet on the window where the action started (the main window, a composer or Settings), with the app icon. The one exception is the launch failure below: no window exists yet, so it is an app-modal `runModal()` alert with nothing behind it. Quire supplies:

- **Title** as a question or a fact, sentence case: “Discard this draft?”, “Couldn't send the message”, “Remove alex@contoso.test?”.
- **Body**: what happens or what went wrong, then the remedy: “The message to Ben Carter hasn't been sent. Discarding removes it from this Mac.” / “Mail from this account is removed from this Mac. Nothing changes on the server.”
- **Buttons**: verbs, title case (§4.13). The safe choice is the default (↩); the destructive button sets `hasDestructiveAction` (system red text) and is never the default; Esc cancels. Never two destructive buttons.

The app's complete alert inventory, so no screen invents its own:

| Where | Title | Body | Buttons (default first) |
|---|---|---|---|
| Composer: Message › Discard Draft… (§5.20) | Discard this draft? | The message to Ben Carter hasn't been sent. Discarding removes it from this Mac. | Keep Writing · Discard (destructive) |
| Drafts reader: Discard Draft (§5.19) | Discard this draft? (several selected: “Discard 3 drafts?”) | The message to Ben Carter hasn't been sent. Discarding removes it from this Mac. (several: “They haven't been sent. Discarding removes them from this Mac.”) | Cancel · Discard (destructive) |
| Composer: send with an empty subject (§5.20) | Send without a subject? | Messages without a subject are easy to miss. | Add Subject · Send Anyway |
| Settings: Remove… (§5.40) | Remove alex@contoso.test? | Mail from this account is removed from this Mac. Nothing changes on the server. | Cancel · Remove (destructive) |
| Settings: Remove failed (§5.40) | Couldn't remove alex@contoso.test | the reason in plain words, then “The account is still here; nothing was deleted.” | Try Again · Cancel |
| Add account: no OAuth client (§5.44) | Set up a Google OAuth client first | SuperSparrow needs your own Google OAuth client ID to add a Gmail account. | Open Settings · Cancel |
| Add account failed (§5.44) | Couldn't add the account | the reason in plain words | Try Again · Cancel |
| Add account: already added (§5.44) | alex@contoso.test is already added | Choose it in the rail or in Settings. | Show Account · Cancel |
| Reconnect failed (§5.44) | Couldn't reconnect alex@fabrikam.test | the reason in plain words (the same list as “Couldn't add the account”) | Try Again · Cancel |
| Reconnect with a different account (§5.44) | Signed in to a different account | You signed in as sam@contoso.test, but this account is alex@fabrikam.test. Nothing was changed. Try again and choose alex@fabrikam.test in your browser. | Try Again · Cancel |
| Launch: the mail database can't be opened | SuperSparrow couldn't open its mail database | the reason in plain words, then “It is stored in ~/Library/Application Support/SuperSparrow.” | Quit (the only button; ↩ and Esc). App-modal, before any window exists: no sheet and nothing behind it; the app quits when it closes |
| Leave the demo (§5.43) | Leave the demo? | The made-up mailboxes are removed from this Mac. You'll return to the welcome screen. | Leave Demo · Cancel |
| First real account in demo mode (§5.43) | Replace the demo with this account? | The made-up mailboxes are removed from this Mac when your account is added. | Continue · Cancel |
| Reader: Open on an attachment that is a program or script (§5.17) | Open “Invoice.command”? | It is a program or script, and opening it lets it change your Mac. Open it only if you trust the sender and expected it. | Cancel · Open |

Closing a composer never asks (its draft is kept, §5.20), and a rejected attachment drop is a composer status, not an alert. **Unreadable OAuth settings** (today's “Your OAuth settings could not be read” alert) is not an alert either: the add or reconnect stops, Settings › OAuth opens, and a danger banner at the top of the tab reads “Couldn't read the OAuth settings.” + the reason + “Correct the fields below and click Save.” (§5.40, Notices); it stays until a save succeeds. Today's generic “OK” error alerts (`AppDelegate.showError`) map onto the rows above; no other error alert remains.

Sign-in failures from the main window use this alert (§5.44). The only app-drawn modal surface is the cheat-sheet overlay (§5.32).

### 5.34 Tooltips

System `toolTip` on every icon-only control and on truncated text; Quire defines no tooltip view and no tooltip metrics. Content: the action name, two spaces, the shortcut (“Archive  E”, “Reply All  A”, “All Inboxes  ⌘0”), in title case because it repeats the command's menu name (§4.13). Disabled controls explain why (“Nothing to undo”). The reader uses `title` attributes so WebKit shows the same system tooltip. Delay and look are the system's.

### 5.35 Menus

Main menu (system), with Quire content. Single-key shortcuts are handled by `KeyboardRouter` and shown as attributed shortcut text, so they never fire inside text fields.

- **SuperSparrow**: About SuperSparrow (the system About panel) · Settings… ⌘, · Services · Hide · Quit.
- **File**: New Message ⌘N (also C) · Close Window ⌘W · Add Gmail Account… · Add Microsoft Account… · Save Attachments… · in demo mode, Leave Demo… (§5.43).
- **Edit**: standard, plus Find… ⌘F (focuses search). Undo is titled by its target (“Undo Archive”, “Undo Send”, “Undo Typing”), following §6.1.
- **View**: Inbox · Starred · Sent · Drafts · Trash · All Mail (G-sequences) · All Inboxes ⌘0 · accounts ⌘1–9 · Check for New Mail ⇧⌘N · Show/Hide Account Rail ⌃⌘S · Compact Rows ⌥⌘C · Load Images ⇧⌘I · Original Colors ⇧⌘O (checkmark when on) · Show Quoted Text .
- **Message**: Reply R · Reply All A · Forward F · — · Archive E · Move to Trash # · Move to Inbox ⇧I · Star S · Mark as Unread U · Undo Z · — · Next Message N · Previous Message P.
- **Format** (composer windows only): Show Format Row ⇧⌘T · — · Bold ⌘B · Italic ⌘I · Underline ⌘U · — · Bulleted List ⇧⌘8 · Numbered List ⇧⌘7 · Quote ⌘' · — · Add Link… ⌘K. In a composer window the Message menu holds Send ⌘↩ · Attach Files… ⇧⌘A · Add Cc Field ⇧⌘C · Add Bcc Field ⇧⌘B · — · Discard Draft… (§5.20).
- **Window**, **Help** (Keyboard Shortcuts ⌘/).

Context menu on rows and messages: Reply, Reply All, Forward, —, Archive, Star, Mark as Unread, Move to Inbox (disabled where it does not apply), —, Move to Trash; every item with its symbol and shortcut, title case, disabled items visible. It acts on the selection, like the Message menu, and shares its validation (Star reads Unstar when every selected conversation is starred; Move to Inbox is disabled in the Inbox; Move to Trash in Trash). A right-click on a row outside the selection selects that row first; heads and the list tail have no menu. On a message it opens over the sheet's or collapsed row's own chrome; inside a body, which is the sender's document, the system's text menu stays, for Copy and links. The message More menu is §5.14; the rail's add menu §5.44; the demo tag's menu §5.43. The highlight is the system's (Iron Gall under Multicolor, §3.1).

### 5.36 Keyboard shortcut hints (keycaps)

{{TABLE:layout:kbd}}

| Part | Spec |
|---|---|
| Keycap | min {{layout.kbd.minWidth}} × {{layout.kbd.height}} ({{layout.kbd.inField}} inside the search field), padding 0 {{layout.kbd.padX}}, radius {{layout.kbd.radius}} (`r.xs`); `raised` with a {{border.strong.width}} pt `rule` inset and a {{border.strong.width}} pt `rule` bottom inset (key depth); Increase Contrast uses `ruleStrong` |
| Legend | `kbd` (SF Pro {{typography.kbd.size}} Medium) `ink2`; modifiers in Apple order ⌃⌥⇧⌘; Return “↩”, Delete “⌫”, Escape “esc”, Space “space” |
| Sequence | two caps with “then” in `meta` `ink3` between them (cheat sheet, empty states); adjacent caps in menus and tooltips |
| On the slip | no fill, `onSlipEdge` outline; legend `onSlip2` at rest, `onSlip` while its action is hovered or pressed |
| Large | {{layout.kbd.largeHeight}} pt, radius {{layout.kbd.largeRadius}} (`r.sm`), {{layout.kbd.largeFont}} pt legend (cheat sheet) |

Where keycaps appear: search “/”, the autocomplete's “↩”, quick reply “R”, “⌘↩” beside Send, the target message's R · A · F, the quick-reply strip's “⌘Z”, toast “Z”, undo panel “⌘Z”, the Drafts “↩”, empty states, the HUD and the cheat sheet. Keycaps never sit on accent fills, without exception: the autocomplete's “↩” sits on the `selWash` highlight in its normal raised style (§5.21), and “⌘↩” sits beside Send, not inside it.

**Narrow reader.** When the reader is narrower than {{layout.window.readerKeycapsMin}} pt (`layout.window.readerKeycapsMin`, {{layout.reader.columnMax}} minus two {{layout.reader.columnMinMargin}} pt margins), the reader's keycaps hide: the quick reply's “R” and “⌘↩”, the strip's “⌘Z”, the target message's R · A · F (its `ruleStrong` edge stays, §5.14) and the Drafts footer's “↩”. Tooltips keep naming the shortcuts. Empty-state hints on the desk keep their keycaps and wrap instead. Keycaps outside the reader (search, toast, undo panel, HUD, cheat sheet) never hide.

### 5.37 Progress

{{TABLE:layout:progress}}

| Indicator | Spec | Use |
|---|---|---|
| Spinner (AppKit) | `QuireSpinnerView`, layer-drawn (not `NSProgressIndicator`, which has no 12 pt spinning size and no public tint): a `CAShapeLayer` circle path inset by half the stroke, `strokeStart` 0, `strokeEnd` {{layout.progress.spinnerArc}} (a ¾ arc, butt caps), stroke {{layout.progress.spinnerStroke}} pt at {{layout.progress.spinner}} pt; a `transform.rotation.z` `CABasicAnimation` of one turn per `dur.spinnerTurn`, linear, `repeatCount = .infinity`. Colour: `ink3`; inside filled buttons the label colour (`onAccent`, `onDanger`); on slips `onSlip2`; re-resolved on appearance change. It is added {{motion.duration.spinnerDelay}} ms after work starts (and never if the work ends sooner), fades in over `dur.quick`, and removes its animation when hidden or off-window | buttons, sync line, search, chips, undo panel, rail tile, list footer, Settings rows |
| Spinner (reader CSS) | `.ss-spin`: the same shape, a circle with a {{layout.progress.spinnerStroke}} pt border in `currentColor` and one quarter (`border-right-color: transparent`) left open, rotating once per `dur.spinnerTurn`, linear; same delay and fade-in | message “Sending…”, image loading |
| Determinate bar | {{layout.progress.barHeight}} pt, radius {{layout.progress.barRadius}}, track `fill`, fill `accent`; jumps forward without easing, never backwards | Settings › Accounts download status ({{layout.settings.statusBarWidth}} pt wide, §5.40) |
| Contrail | {{layout.progress.contrail}} pt line in `accent` (`onSlip` on slips) whose trailing {{layout.progress.contrailTail}} pt fades to transparent, with a {{layout.progress.contrailHead}} pt head dot at the moving end. Determinate: length = progress. Indeterminate: a segment {{layout.progress.indeterminateSegment}} of the width sweeping every `dur.contrailSweep` (Reduce Motion: a static segment {{layout.progress.reducedSegment}} of the width; the text carries the state) | sync line, attachment progress, toast life, undo countdown |

Spinners appear only after {{motion.duration.spinnerDelay}} ms and **never in rows**; the row's only status marks are the static `ss.queued` glyph and the failed triangle.

### 5.38 Semantic banners

{{layout.banner.height}} pt, radius {{layout.banner.radius}}, padding 0 {{layout.banner.padRight}} 0 {{layout.banner.padLeft}}, gap {{layout.banner.gap}}, `snippet` `ink` text, glyph {{layout.banner.glyph}} pt in the semantic colour, optional trailing link button and optional dismiss button (`xmark` {{layout.banner.dismissGlyph}} pt `ink2`, {{layout.button.minHit}} pt hit). Variants: neutral (`fill`, glyph `ink2`), info (`infoWash`, `info`), success (`successWash`, `success`), warning (`warningWash`, `warning`), danger (`dangerWash`, `danger`). Never more than one status banner per message.

**Multi-line.** Text that does not fit wraps instead of truncating where the words matter (Settings notices, sign-in errors): the banner grows from {{layout.banner.height}} pt with {{layout.banner.padY}} pt top and bottom padding, the glyph aligns to the first line, and the link sits after the text on its last line.

### 5.39 Welcome screen

Fills the main window until the first account exists; the rail and list are hidden; window background `paper`; the traffic lights stay where the empty unified toolbar puts them (§3.2).

{{TABLE:layout:welcome}}

| Part | Spec |
|---|---|
| Block | max width {{layout.welcome.blockWidth}}, centred horizontally; vertically its centre sits at {{layout.welcome.blockCenterY}} of the content height below the title-bar zone (`welcome.blockCenterY`: optically centred, a little high). It re-centres, instantly, whenever a banner or a state changes its height |
| Mark | `ss.sparrow` {{layout.welcome.mark}} pt in `accent` |
| Title | “SuperSparrow” in `display`, {{layout.welcome.titleGap}} pt below the mark |
| Tagline | “Your mail, quietly fast.” in `aside` `ink2`, {{layout.welcome.taglineGap}} pt below |
| Actions | {{layout.welcome.actionsGap}} pt below: two large secondary buttons, {{layout.welcome.buttonWidth}} wide, {{layout.welcome.buttonGap}} apart: `envelope` + “Add Gmail account” (trailing note “Google” in `snippet` **`ink2`**), “Add Microsoft account” (trailing note “365 · Outlook”). The note is `ink2`, not `ink3`, because it sits on `raised` and on its hover and pressed washes, where `ink3` falls to 4.24:1 in Dark (§7 tests the note on all three). Two equal choices, so neither is primary; the first has initial focus |
| Demo | ghost “Try the demo”, {{layout.welcome.demoGap}} pt below (tooltip: “Explore SuperSparrow with two made-up mailboxes. Nothing leaves this Mac.”); it opens the main window in demo mode (§5.43) |
| Footnote | {{layout.welcome.footGap}} pt below, `meta` `ink3`, max {{layout.welcome.footWidth}} wide, with `lock`: “Your mail is stored on this Mac and travels only between this Mac and Google or Microsoft. No analytics, ever.” |
| Link | “Set up OAuth clients…”: a link button (§5.24) in `label` `accent`, centred, {{layout.welcome.linkGap}} pt below the footnote (`welcome.linkGap`); it opens Settings › OAuth |
| Banner slot | between the tagline and the actions: when a banner shows it takes the actions' place, {{layout.welcome.actionsGap}} pt below the tagline, and the buttons follow {{layout.welcome.bannerGap}} pt below it (`welcome.bannerGap`); full block width, multi-line (§5.38). One banner at a time, the newest winning: sign-in error, demo failed, or no OAuth client |

| State | Look |
|---|---|
| Rest | as above; the first button has initial focus |
| Hover, pressed, focused | the secondary-button states of §5.24; the trailing note stays `ink2` in every one |
| Waiting for the browser | the chosen button goes back to its **rest** face (it does not keep the pressed face) and becomes inert: a {{layout.welcome.spinner}} pt `ink2` spinner replaces `envelope`, the label reads “Finish signing in in your browser…”, the trailing note hides, focus stays on it. The other provider button and the OAuth link are disabled, and the demo slot shows ghost “Cancel” in place of “Try the demo” |
| Preparing the demo (after “Try the demo”) | the ghost button becomes inert and reads “Preparing the demo…” with a {{layout.progress.spinner.0}} pt `ink2` spinner {{layout.button.glyphGap}} pt before the label (after {{motion.duration.spinnerDelay}} ms, so a fast seed shows no spinner); both large buttons and the OAuth link are disabled. On success the window cross-fades to the demo inbox (`dur.slow`, §5.43) |
| Demo failed | everything re-enables and the ghost button reads “Try the demo” again; a multi-line danger banner in the banner slot: “Couldn't start the demo. The made-up mailboxes couldn't be created on this Mac.” + link “Try again” |
| Sign-in error | “Couldn't add the account” + the reason, as a multi-line danger banner in the banner slot |
| No OAuth client configured (after choosing a provider) | an info banner in the banner slot: `info.circle` + “Add your Google OAuth client in Settings › OAuth first.” + the trailing link “Open Settings” |
| Success | `dur.slow` cross-fade to the inbox with the skeleton |
 Adding accounts later, from the main window or Settings, follows §5.44 with the same copy.

### 5.40 Settings window

SwiftUI `Settings { TabView { … } }` with the **system toolbar tab style**, {{layout.settings.width}} pt wide, background `canvas`. Height fits the current tab's content, never taller than the screen's visible frame; the account group is capped (below), so the tallest tab, Accounts with a two-line notice, six visible rows, the +/− buttons and a full detail form, is 760 pt of content ({{layout.settings.padTop}} + a 46 pt banner + {{layout.settings.noticeGap}} + 336 + {{layout.settings.plusMinusTop}} + {{layout.settings.plusMinus}} + {{layout.settings.detailTop}} + 270 for five detail rows with a three-line error and the 82 pt Signature row + {{layout.settings.padBottom}}), 848 pt with the window's 88 pt title bar and toolbar (macOS 26). A shorter visible frame stops the window at its height and cuts the foot of the form, which takes all of that at once: six accounts, a notice and a three-line error. Tabs: **Accounts** (`person.crop.circle`), **OAuth** (`key`), **General** (`gearshape`). The toolbar and its tabs are system chrome: macOS draws their size, material, selection and focus (the selected tab's symbol takes the accent asset, §3.1), so Quire specifies no tab metrics and asserts no tab contrast (§7). Everything **inside** the content area is Quire-drawn with the custom SwiftUI styles of §8.3, so every edge and every focus ring there meets 3:1. Content padding {{layout.settings.padTop}} {{layout.settings.padX}} {{layout.settings.padBottom}}.

{{TABLE:layout:settings}}

**Accounts.** An optional notice banner (below), then the account group (`sheet`, radius {{layout.settings.groupRadius}}, hairline edge) of {{layout.settings.accountRow}} pt rows, then the +/− buttons {{layout.settings.plusMinusTop}} pt below the group, then, {{layout.settings.detailTop}} pt below the buttons (`settings.detailTop`), the detail of the selected account.

**Group capacity.** The group shows at most {{layout.settings.groupMaxRows}} rows ({{layout.settings.groupMaxRows}} × {{layout.settings.accountRow}} = 336 pt, `settings.groupMaxRows`) and scrolls beyond that, exactly like the rail's stack (§5.2): a `rule` hairline marks each clipped edge (bottom, and top once scrolled), the scroller shows only while scrolling, and ↑/↓ scroll the selected row into view instantly. The group's corner radius clips its content; the +/− buttons stay below it.

| Account row part | Spec |
|---|---|
| Face | the account's rail face ({{layout.settings.accountFace}} pt, {{border.accountRing.gap}} pt gap in the row's fill, {{border.accountRing.width}} pt ring): the face's leading edge at x = {{layout.settings.accountFaceX}} (`layout.settings.accountFaceX`), so the ring's outer edge runs from x = 12 to x = 50; vertically centred |
| Name line | from x = {{layout.settings.accountHairlineX}}: the name in `bodyStrong` `ink`, then {{layout.settings.tagGap}} pt and the provider tag “Gmail” / “Microsoft 365” (“Demo” in demo mode) on the same line, sharing its centre; the name truncates, the tag never does |
| Address line | `snippet` `ink2` under the name; for Sign in required it is replaced by the status words in `danger` (below) |
| Status | a trailing block, {{layout.settings.statusTrailing}} pt from the group's trailing edge (`statusTrailing`), centred on the row: glyph {{layout.settings.statusGlyph}} pt, {{layout.settings.statusGlyphGap}} pt, the words in `snippet`. When the state has an action, a small secondary button takes the trailing position and the glyph and words sit {{layout.settings.statusButtonGap}} pt before it. The name and address block ends at least {{layout.settings.statusGap}} pt before the status block (`statusGap`) and truncates first |
| Separators | hairlines from the text column (x = {{layout.settings.accountHairlineX}}); hidden around the selected row |
| Selected | `selWash` + a {{border.marginRule.width}} pt `selRule` margin rule flush with the group's leading edge, full row height (clipped by the group's corner radius on the first and last rows) while Settings is key; `selWashIdle` + `selRuleIdle` when it is not. The wash is a scan cue (`selWash` ≥ 1.25:1 on `sheet`); the rule is the state (≥ 3:1 on the wash and on `sheet`, both keys, §7) |
| Hover, pressed | **none.** Rows take no hover and no pressed wash: selection applies on mouse-down, as in native Mac source lists, and a wash under the account ring would need its own pairs (Jade's ring on `sheet + pressed` falls to 3.41:1 in Dark IC, below the 3.5 IC floor of §4.2). The ring therefore only ever sits on `sheet`, `selWash` and `selWashIdle`, all tested. Buttons inside a row (Reconnect, Retry, Cancel) keep their own states (§5.24) |
| Detail | the form below the +/− buttons (next table) |

**Detail form**, on the same grid as OAuth and General: labels `body` `ink`, right-aligned in the {{layout.settings.labelColumn}} pt column; controls start {{layout.settings.labelGap}} pt after it; rows {{layout.settings.detailRow}} pt (`settings.detailRow`), each control centred vertically in its row. It describes the selected account and is replaced by nothing (no rows) when the group is empty.

| Row | Label | Control |
|---|---|---|
| 1 | Colour | popup (§5.27), {{layout.popup.height}} pt high, {{layout.settings.colourPopupWidth}} pt wide (`settings.colourPopupWidth`): the {{layout.settings.swatch}} pt swatch on its {{layout.popup.inkHalo}} pt `raised` halo, 8 pt, the ink's name (“Persimmon”); the menu lists the ten inks with swatches, a checkmark on the current one |
| 2 | Monogram | text field {{layout.settings.monogramFieldWidth}} × {{layout.settings.fieldHeight}} pt (`settings.monogramFieldWidth`), max {{layout.settings.monogramMaxLength}} characters; placeholder = the derived monogram in `ink3`, so clearing the field returns to it. No caption |
| 3 | Signature | a {{layout.settings.signatureLines}}-line field: the composer's own editor (§5.20) in the text-field container (§5.25: `sheet`, radius {{layout.textField.radius}}, `ruleStrong` edge, `ink3` hovered, the focus ring while it edits), {{layout.settings.fieldWidth}} × {{layout.settings.signatureFieldHeight}} pt (`settings.signatureFieldHeight` = {{layout.settings.fieldHeight}} + ({{layout.settings.signatureLines}} − 1) × {{typography.writing.lineHeight}}), its top 8 pt into the row (({{layout.settings.detailRow}} − {{layout.settings.fieldHeight}}) / 2, as a one-line field's), so the row is 82 pt and the label, centred in the row's first {{layout.settings.detailRow}} pt, sits level with the first line. Text in `writing` from {{layout.textField.padX}} pt in, the first line where a one-line field's text would sit (({{layout.settings.fieldHeight}} − {{typography.writing.lineHeight}}) / 2 pt from the top); past three lines it scrolls inside (scroller only while scrolling). Bold, italic, underline and links through the composer's shortcuts (⌘B ⌘I ⌘U, and ⌘K for its link popover, which closes, as in the composer, when focus goes anywhere else or another account is selected); lists and quotes are off (⇧⌘8, ⇧⌘7 and ⌘' do nothing there); pasting is plain, as in the composer. Empty by default, no placeholder and no caption. Saved as the HTML the composer sends (anything else dropped) when editing ends: focus leaves the field, another account is selected, another window or app comes forward, the window closes, a composer opens while Settings is in front (⌘N, a notification's Reply), or the app quits (before the store closes); never per keystroke. Emptied, the account has no signature |
| 4 | Last error (only when there is one) | the error in `meta` `ink2` (“Gmail returned an unexpected response.”), wrapping in the field column ({{layout.settings.fieldWidth}} pt) up to {{layout.settings.lastErrorMaxLines}} lines (`settings.lastErrorMaxLines`; the row grows by {{typography.meta.lineHeight}} pt per extra line), the full text in its tooltip |
| 5 | — | Remove… (small secondary, at the field column's leading edge; confirms with the destructive alert of §5.33). In demo mode it reads Leave Demo… |

**Seven accounts.** When a {{layout.badge.autoInitialsAt}}th account is added and **Show account initials in unified views** turns on by itself (§4.2), Settings says why in two places. In **Accounts**, an info banner in the notice slot: `info.circle` + “Rows now show each account's initial. With seven or more accounts, colours alone can look alike.” + the link “Change in General…” and a dismiss button; it appears once, stays (across launches) until dismissed or followed, and is not shown again. In **General**, a caption under the Rows checkbox, in the field column {{layout.settings.captionGap}} pt below it (`meta` `ink3`): “Turned on when you added a seventh account.”, shown while the setting is still in that automatic state; once the user changes the checkbox the caption goes and the choice is kept (an eighth account does not turn it back on).

**Account status.** The same words as the sync line's tooltip (§5.11), one per account phase:

| Status | Glyph | Words (`snippet`) | Action |
|---|---|---|---|
| Up to date (idle) | `checkmark.circle.fill` `success` | “Up to date” `ink2`; tooltip “Checked 23:41” | — |
| Up to date, downloading older mail (new mail is current; the older mail downloads behind it) | `checkmark.circle.fill` `success` | “Up to date · older mail 3,412 of 8,120” `ink2` (“Up to date · older mail 3,412” while the total is unknown, “Up to date · older mail…” before the first count); while the total is known, the Downloading row's determinate bar under the words; tooltip “Checked 23:41” | — |
| Up to date, older mail paused (the provider is limiting the older-mail download) | `checkmark.circle.fill` `success` | “Up to date · older mail paused until 10:42” `ink2`, no bar; the tooltip adds the cause on its own line (“Gmail is limiting requests.”). Never Retrying: new mail still arrives | — |
| Up to date, downloading messages (the older mail is listed; the bodies the backfill still lacks arrive behind it) | `checkmark.circle.fill` `success` | “Up to date · downloading messages…” `ink2`, no bar; tooltip “Checked 23:41”. A message opened before its body arrives fetches it at once. A throttle on these downloads keeps these words, never “paused until” | — |
| Waiting to sync (added; the engine has not reached it yet) | `clock` `ink3` | “Waiting to sync” `ink3` | — |
| Downloading (a new account's first page of newest mail, before its first check; the older mail after it reads as Up to date) | {{layout.progress.spinner.0}} pt `ink3` spinner | “Downloading · 3,412 of 8,120” `ink2` (“Downloading · 3,412 messages” while the total is unknown); while the total is known, a {{layout.settings.statusBarWidth}} × {{layout.progress.barHeight}} pt determinate bar (§5.37) {{layout.settings.statusBarGap}} pt under the words, trailing-aligned with them | — |
| Checking (a check the user asked for) | spinner | “Checking for mail…” `ink2` | — |
| Retrying (rate limited, or unreachable while other accounts are online) | `clock` `warning` | “Retrying in 30 s” `ink2`, or “Retrying shortly” when the server gave no time; the tooltip names the cause (“Gmail is limiting requests.”, “Couldn't reach Gmail.”) | — |
| Offline | `wifi.slash` `ink2` | “Offline” `ink2` | — |
| Sign in required | `exclamationmark.triangle.fill` `danger` | “Sign in required” in `danger`, **in place of the address line**; the status block holds only the button | small secondary “Reconnect” |
| Reconnecting (waiting for the browser, §5.44) | {{layout.progress.spinner.0}} pt `ink3` spinner | “Sign in required” stays in `danger` in place of the address (it is still true); the status block reads “Waiting for your browser” `ink2` | small secondary “Cancel”, in Reconnect's place |
| Error | `exclamationmark.triangle.fill` `danger` | “Couldn't sync” `danger`; the reason in plain words in the tooltip and the detail | small secondary “Retry” |
| Demo account | `info.circle` `ink3` | “Made up, nothing syncs” `ink3` | — |

Every glyph, word and bar meets its pair on `sheet`, `selWash` and `selWashIdle` (§7; `ink2` and `ink3` words through the row pairs).

The group is **not** a `List(selection:)`: SwiftUI's list selection paints an accent block with white text that cannot be restyled. It is a `VStack` of rows inside a `.focusable()` container: click selects; ↑/↓ move the selection (`onMoveCommand`); ⌫ asks to remove; Tab enters and leaves the group as one stop, drawing the focus ring around the selected row inset {{border.focusRing.width}} pt; each row reports `.isSelected` to accessibility.

**+/−.** Two joined square buttons, {{layout.settings.plusMinus}} × {{layout.settings.plusMinus}} each, `raised`, {{border.strong.width}} pt `ruleStrong` edge with a shared middle edge, outer radius `r.sm`, glyphs `plus` / `minus` {{layout.settings.plusMinusGlyph}} pt `ink2`. Hover `raised + hover`, glyph `ink`; pressed `raised + pressed`; focused ring around the focused half (each half is its own Tab stop); − disabled (`inkDisabled`, no fill change) when nothing is selected. + opens the add-account menu (§5.44) under the button; − is Remove….

| Accounts state | Look |
|---|---|
| Accounts listed | as above |
| No accounts | the group holds one {{layout.settings.accountRow}} pt row: “No accounts yet” (`body` `ink2`) over “Add one to start syncing.” (`snippet` `ink3`), centred; − disabled; + enabled |
| Adding (waiting for the browser) | a pending row at the end of the group: {{layout.settings.accountFace}} pt `fill` face with a dashed `ruleStrong` ring and a {{layout.progress.spinner.1}} pt `ink3` spinner, “Finish signing in in your browser…” (`body` `ink`) over “Gmail” (`snippet` `ink2`), trailing small secondary “Cancel”; + is disabled until it resolves |
| Add failed | the pending row leaves; a danger banner above the group: “Couldn't add the account” + the reason (multi-line) + link “Try again” |
| Reconnecting | the account's row shows the Reconnecting status above; + and every other Reconnect and Retry are disabled until it resolves |
| Demo mode | an info banner above the group (§5.43) |

**Notices.** Banners at the top of a tab's content, {{layout.settings.noticeGap}} pt above the first control, multi-line (§5.38): info for guidance, danger for failures. A confirmation of a button press is not a notice: it sits beside the button that caused it (OAuth “Saved”, below). The OAuth tab's incoming notice, shown when an add-account attempt found no client, is an **info** banner (`info.circle`): “To add a Gmail account, SuperSparrow needs your own Google OAuth client ID. Enter it below and click Save, then try again.” with the link “How to create one…” (opens `docs/OAUTH-SETUP.md`); it stays until Save succeeds or the tab is left. When the OAuth settings file exists but cannot be read, the tab opens with a **danger** banner instead: “Couldn't read the OAuth settings.” + the reason + “Correct the fields below and click Save.”; it stays until a save succeeds (§5.33). The seven-accounts notice (above) is the Accounts tab's only info banner besides demo mode; when both apply, demo mode's shows.

**OAuth.** One form, top to bottom (the incoming notice above it when present). Labels `body` `ink`, right-aligned in the {{layout.settings.labelColumn}} pt column; fields start {{layout.settings.labelGap}} pt after it and fill to the content's trailing padding ({{layout.settings.fieldWidth}} pt at the {{layout.settings.width}} pt window: `layout.settings.fieldWidth`), {{layout.settings.fieldHeight}} pt high, on {{layout.settings.row}} pt rows; section titles in `title` `ink` at the content's leading edge, {{layout.settings.sectionGap}} pt above their first row.

| Row | Label | Control | Placeholder (`ink3`) | Font |
|---|---|---|---|---|
| Section | “Google” | — | — | `title` |
| 1 | Client ID | text field | “….apps.googleusercontent.com” | `mono` |
| 2 | Client secret | secure field (§5.25: bullets, reveal button on hover) | “GOCSPX-…” | `mono` |
| Section | “Microsoft” | — | — | `title` |
| 3 | Client ID | text field | “00000000-0000-0000-0000-000000000000” | `mono` |
| 4 | Tenant | text field | “common” | `mono` |
| Caption | — | in the field column, {{layout.settings.captionGap}} pt under the last field, max {{layout.settings.captionMaxWidth}} pt wide, `meta` `ink3`: “Register a Desktop app client in Google Cloud Console with the Gmail API enabled, and a Mobile and desktop app in Microsoft Entra with http://localhost as its redirect URI. Leave Tenant as common to allow both work and personal Microsoft accounts.” followed by the link “How to create these…” (`meta`, `accent`; opens `docs/OAUTH-SETUP.md`) | — | — |
| Buttons | — | {{layout.settings.sectionGap}} pt under the caption: “Show File in Finder” (small secondary, at the field column's leading edge; disabled until the file exists) and, trailing at the content padding, “Save” (small primary, the default button, enabled only when a field changed) | — | — |

**“Saved”** is a status beside Save, not a banner: `checkmark.circle.fill` `success` {{layout.settings.statusGlyph}} pt + “Saved” (`snippet` `ink2`), {{layout.settings.savedGap}} pt before the Save button, from a successful save until the next edit (VoiceOver announces “Saved”). A failed save is a danger banner at the top of the tab (“Couldn't save the OAuth settings.” + the reason). Validation errors sit under their field (§5.25: “That doesn't look like a Google client ID.”).

**General** (a two-column grid: labels right-aligned in {{layout.settings.labelColumn}} pt, rows {{layout.settings.row}} pt, a hairline between groups): Font (popup: New York, SF Pro; §4.4) · List density (radio: Standard, Compact) · Rows (checkbox: Show account initials in unified views; the seven-accounts caption under it, above) · Undo send (popup: 5, 10, 20 seconds) · — · Remote images (toggle “Load by default”, caption “Off: images load only when you ask, per message.”) · Notifications (toggle “New mail”; checkbox “Show sender and subject”) · — · Keep mail on this Mac (below) · — · Mail links (below).

**Keep mail on this Mac.** How far back messages keep their full content on this Mac: a popup, Everything (the default), 1 year, 3 months, and {{layout.settings.mailboxSizeGap}} pt after it the space the mailbox takes in plain words (“292 MB”: the mail database, less the pages it keeps free for reuse after a clean-up, and the attachment cache, decimal units as Finder counts, `meta` `ink2`; VoiceOver reads “292 MB on this Mac”). Under the row, in the field column {{layout.settings.captionGap}} pt below it (`meta` `ink3`): “Older mail stays in the list and in search, and downloads again when you open it.” The size is measured when the tab appears, when the window reopens on it, and after each clean-up while the window is open; never on a timer, and until the first answer the row holds the popup alone, never a placeholder number. A message received before the window keeps its row, its snippet and its text for search; its full content goes, and opening it fetches it again as for mail the download has not reached yet (§5.14: the skeleton while it loads, the offline preview without a network), after which it stays until the app next starts; so does mail shown in the reader, so a clean-up never empties a conversation on screen or its attachments. Older mail the download brings in arrives already cleaned up, so the mailbox never takes its full size first. Choosing a shorter window cleans up at once, in the background, and the size follows when it is done; choosing a longer one, or Everything, removes nothing more and downloads nothing back (those messages fill in again as they are opened). Drafts, messages waiting to send and messages with an action still syncing are never touched. Attachments opened on this Mac are kept up to 1 GB, the least recently used going first.

**Mail links.** The last group says which app opens `mailto:` links (§5.20). LaunchServices is asked whenever the tab appears (the window reopening on it included) and whenever the app comes to the front while it shows, since the user can choose another mail app in Mail's settings meanwhile; until the first answer the row holds nothing, rather than a button that may vanish.

| Mail links state | Look |
|---|---|
| SuperSparrow opens mail links | `checkmark.circle.fill` `success` {{layout.settings.statusGlyph}} pt, {{layout.settings.statusGlyphGap}} pt, “SuperSparrow is your default mail app.” (`snippet` `ink2`) at the field column's leading edge: the same status as OAuth's “Saved”. No button |
| Another app opens them | “Set as Default Mail App” (small secondary, at the field column's leading edge). It asks macOS to make SuperSparrow the default; macOS confirms in its own dialog, and the button is disabled until it answers. The row then shows what LaunchServices says: the words above, or the button again when the user kept the other app, with no message (a choice, not a failure) |
| The change failed | the button stays, enabled; under it, in the field column {{layout.settings.captionGap}} pt below the control and at most {{layout.settings.captionMaxWidth}} pt wide, a field's error help line (§5.25: `exclamationmark.triangle.fill` {{layout.textField.helpGlyph}} pt, {{layout.textField.helpGlyphGap}} pt, `meta` `danger`): “Couldn't make SuperSparrow the default mail app. You can also choose it in Mail › Settings › General.” It stays until an attempt succeeds or SuperSparrow is found to be the default: through a retry too, under the disabled button while macOS asks and after the user keeps the other app. Never an alert |

States per control as §5.24–5.27, Quire-drawn; validation errors inline under the field.

### 5.41 Notifications

`UNUserNotificationCenter`; macOS draws them, Quire supplies content. One notification per new conversation; `threadIdentifier` = account id so they group; `targetContentIdentifier` = conversation id, so clicking opens and selects it.

| Field | Preview on | Preview off (Settings) |
|---|---|---|
| Title | sender display name (“Ben Carter”), else the address, else “No sender” | “New message” |
| Subtitle | subject, else “No subject” | account name |
| Body | first line of the snippet, max {{layout.notification.bodyMaxChars}} characters | none |
| Summary (more than {{layout.notification.summaryThreshold}} within {{layout.notification.summaryWindowSeconds}} s) | “3 new messages” · account name | same |

Sound: system default, off while the app is frontmost. No notification for mail that arrives while its conversation is open in a key window, or during an account's first sync (its first page of newest mail, including mail of that page whose rows land just after it). New mail notifies while older mail downloads behind it; the older mail itself never does, since it predates the first page.

**Actions.** A notification for one conversation offers three actions (one category, registered at launch), which macOS lists in this order. The summary offers none: it names no conversation to act on, and a click on it only brings the app forward.

| Action | Copy | What it does |
|---|---|---|
| Archive | “Archive” | archives the conversation, as E does; the app stays where it is |
| Mark as Read | “Mark as Read” | marks every message of the conversation read; the app stays where it is |
| Reply | “Reply” | brings the app forward with a reply composer (§5.20) to the conversation's latest message, from the conversation's account, as R opens one; a button, not a text field in the notification |

Archive and Mark as Read are the window's own changes, applied on this Mac at once and queued to sync exactly as the keys apply them. Taken from a notification they show no toast and leave nothing for Z or ⌘Z: the undo history belongs to the window (§6.1), and the user acted elsewhere. The row leaves the inbox, or loses its unread mark, as a change synced from another device would. An action on a conversation that is gone, on one the change would leave as it is (already archived, already read), or on an account that is not open (a demo notification once the real accounts are back, or the other way round) does nothing, silently. An action that launches the app waits until the main window has read its accounts.

### 5.42 App icon

macOS squircle (system mask), Icon Composer layers so clear and tinted modes tint the mark only:

- **Default**: laid-paper face, vertical gradient `{{layout.appIcon.faceTop}}` → `{{layout.appIcon.faceBottom}}`, faint laid lines in `ink` at {{layout.appIcon.laidLineAlpha}} opacity every {{layout.appIcon.laidLineStep}} of the icon (each an eighth of the step thick); an inset “stamp” rule at {{layout.appIcon.stampInset}} of the icon size, {{layout.appIcon.stampWidth}} of it wide, in Iron Gall at {{layout.appIcon.stampAlpha}} opacity, its corners concentric with the face's ({{layout.appIcon.corner}} of the size, continuous); `ss.sparrow` at {{layout.appIcon.markWidth}} of the width in `{{color.accent.light}}`, optically centred (offset {{layout.appIcon.markOffsetX}}, {{layout.appIcon.markOffsetY}} of the size).
- **Dark**: face `{{layout.appIcon.darkFaceTop}}` → `{{layout.appIcon.darkFaceBottom}}`; stamp rule and mark in `{{color.accent.dark}}`.
- **Tinted / clear**: the mark alone on the system ground; no stamp rule.

**How it is built.** `swift scripts/tools/app-icon.swift` draws everything above from `tokens.json` (the `ss.sparrow` path, `layout.appIcon`, the inks). It writes `Resources/AppIcon.icon`, an Icon Composer document (`icon.json` and SVG layers, flat: no glass, specular or shadow inside the squircle) that `actool` compiles for macOS 26 and later with the default, dark and tinted appearances, and `Resources/AppIcon.icns`, the default face on the system's 824/1024 grid with the template's drop shadow, packed by `iconutil` from 16 to 1024 px, for macOS 15 and wherever the asset catalog is not read. (A macOS `AppIcon.appiconset` cannot carry dark or tinted images.) Below about six pixels apart the laid lines are left out of the raster, where they would only tint the face.

The Dock badge stays system red. The icon shares its mark with the welcome screen, About, inbox zero, alerts and notifications, and nowhere else.

**Alignment with the interface.** The icon is the same paper and ink as the app: its light face is the `paper` family (warm, hue about 75°), its mark is Iron Gall `accentFill` light / `accent` dark, and its stamp rule echoes the margin rule. The mark is `ss.sparrow` from the token file, so the welcome screen, inbox zero and the icon are one drawing. No other colour, gradient or glyph appears in it.

### 5.43 Demo mode

“Try the demo” opens the main window on two made-up mailboxes stored only on this Mac (`demo.sqlite`). Everything behaves as with real accounts except that nothing syncs or sends; the demo must never be mistaken for real mail, so it is marked in words in four places.

| Where | Marker | States |
|---|---|---|
| Masthead | a “Demo” tag ({{layout.tag.height}} pt, `tag` role, `ink2`, `ruleStrong` edge, radius `r.xs`) {{layout.listHeader.demoTagGap}} pt after the masthead (after its chevron in minimal mode, or after the minimal-mode dot, §5.3), in every view and in minimal mode while the header line keeps search's minimum beside it; on a line too crowded for both (minimal mode at the default list width, any list at its minimum width) it steps off the line and the other three markers carry the demo | it is a pull-down button: hover `hover` wash and `ink` text; pressed / menu open `pressed`; focused ring; tooltip “These mailboxes are made up and live only on this Mac.” Its menu: “Add a Real Account…” (submenu: Add Gmail Account…, Add Microsoft Account…) · — · “Leave Demo…” |
| Window title | “SuperSparrow — Demo” (Window menu, Mission Control, VoiceOver; the title bar itself hides titles, §3.2) | — |
| Sync line | `info.circle` `ink3` + **Demo** · made-up mail, nothing syncs | replaces Up to date; no action |
| Settings › Accounts | an info banner above the group: `info.circle` + “Demo mode: these mailboxes are made up and live only on this Mac.” + link “Leave demo…” (sentence case in a banner, §4.13) | the demo accounts list as usual, with the tag “Demo” in place of the provider; Reconnect and Colour work, Remove is replaced by Leave Demo |

**Leaving.** Leave Demo… (tag menu and File menu; “Leave demo…” in the Settings banner) asks with a sheet alert: “Leave the demo?” / “The made-up mailboxes are removed from this Mac. You'll return to the welcome screen.” / buttons “Leave Demo” (default) and “Cancel”. Nothing real is lost, so the alert has no destructive button. Confirming wipes the demo store and shows the welcome screen (`dur.slow` cross-fade).

**Adding a real account from the demo.** “Add a Real Account…” starts the normal flow (§5.44). When the first real account is added, the demo leaves with it: the alert “Replace the demo with this account?” / “The made-up mailboxes are removed from this Mac when your account is added.” / “Continue” (default), “Cancel” comes first, then the browser sign-in; on success the window shows the real inbox.

### 5.44 Adding an account from the main window

Rail +, File › Add Gmail Account… / Add Microsoft Account… and Settings › Accounts + share one flow. The provider is chosen in a menu, never an alert.

| Step | Spec |
|---|---|
| Choose | rail + (and Settings +) opens a system pull-down menu {{layout.rail.addMenuOffsetY}} pt below the button, leading-aligned: `envelope` “Add Gmail Account…” · `envelope` “Add Microsoft Account…”. The File menu has both items directly |
| No OAuth client for that provider | an alert sheet: “Set up a Google OAuth client first” / “SuperSparrow needs your own Google OAuth client ID to add a Gmail account.” / “Open Settings” (default), “Cancel”; Open Settings shows Settings › OAuth with the info notice of §5.40 |
| Waiting for the browser | the browser opens; the rail gets a pending tile at the end of the stack (§5.2); the sync line reads “**Finish signing in in your browser** · Gmail” with the link “Cancel” (it joins the Tab order, §5.11); Settings › Accounts shows the pending row. Only one sign-in runs at a time: both + buttons and the File items are disabled meanwhile |
| Cancel | the pending tile and row leave at once; the sync line returns to its previous state; no message |
| Success | the pending tile becomes the account's tile (instant), the new account is selected, the list shows the skeleton (§5.10), the sync line reads “Downloading mail · Contoso…” |
| Failure | the pending tile leaves; an alert sheet on the main window (or Settings when started there): “Couldn't add the account” / the reason in plain words (“The browser sign-in was cancelled.”, “Google refused the sign-in. Check the client ID in Settings › OAuth.”, “Couldn't reach Google. Check your internet connection.”) / “Try Again” (default), “Cancel” |
| Already added | alert “alex@contoso.test is already added” / “Choose it in the rail or in Settings.” / “Show Account” (default), “Cancel” |

The welcome screen keeps its own in-place waiting state (§5.39) because it has no rail or sync line.

**Reconnecting an account** (the sync line's “Reconnect” with one account, or a Settings row's “Reconnect”) runs the same browser sign-in for an account that already exists:

| Step | Rail tile | Sync line | Settings › Accounts row |
|---|---|---|---|
| Waiting for the browser | the attention badge **stays** (the account still needs sign-in until the browser finishes); tooltip “Finish signing in in your browser…”; no spinner on the tile | state 1 of the precedence (§5.11): “**Finish signing in in your browser** · Fabrikam”, the account's name rather than the provider, with the link “Cancel” | “Sign in required” stays in place of the address; the status block shows a {{layout.progress.spinner.0}} pt `ink3` spinner and “Waiting for your browser” with small secondary “Cancel” in Reconnect's place (§5.40) |
| While it runs | one sign-in at a time: both + buttons, the File › Add items and every other Reconnect and Retry are disabled | — | — |
| Cancel (sync line or Settings) | unchanged: still needs sign-in | back to the state the precedence picks (Sign in required) | back to Sign in required with Reconnect; no message |
| Success | the attention badge leaves in the same frame; the unread badge, if any, takes its place | Checking for mail… (a check the user asked for, §5.11), then Up to date | Checking for mail…, then Up to date; the address line returns. VoiceOver announces “Fabrikam reconnected.” No toast: the badge leaving is the confirmation |
| Failure | unchanged | Sign in required | unchanged; an alert sheet on the window where it started: “Couldn't reconnect alex@fabrikam.test” / the reason / “Try Again” (default), “Cancel” (§5.33) |
| Signed in to a different account | unchanged | Sign in required | unchanged; the alert “Signed in to a different account” / “You signed in as sam@contoso.test, but this account is alex@fabrikam.test. Nothing was changed. Try again and choose alex@fabrikam.test in your browser.” / “Try Again” (default), “Cancel”. Nothing is replaced or added |

---

## 6. Keyboard map

All single keys are inactive while a text field has focus. Every key press first finishes running animations (§4.10).

| Key | Action | Key | Action |
|---|---|---|---|
| J / K | next / previous conversation | E | archive |
| ⇧J / ⇧K | extend the selection | # | move to Trash (nothing in Trash, §5.12) |
| ↩ / → | open (focus the reader) | S | star |
| Esc / ← | back to the list | U | mark unread |
| N / P | next / previous message in the reader | Z or ⌘Z | undo |
| . | show / hide quoted text | C or ⌘N | new message |
| R / A / F | reply / reply all / forward | / or ⌘F | search |
| G I, G S, G T, G D, G #, G A | Inbox, Starred, Sent, Drafts, Trash, All Mail (HUD after {{motion.duration.gHudDelay}} ms) | ⌘0 / ⌘1…⌘9 | All Inboxes / account |
| ⇧⌘R | open the quick reply in the composer | ⌘↩ | send |
| ⇧⌘I / ⇧⌘O | load images / original colors | ⌃⌘S | show / hide the rail |
| ⌥⌘C | compact rows | ? or ⌘/ | keyboard shortcuts |
| ⇧⌘N | check for new mail | ⇧I | move to Inbox |
| ⇧⌘T, ⌘B ⌘I ⌘U, ⇧⌘8 ⇧⌘7, ⌘', ⌘K | composer: format row, styles, lists, quote, link | ⇧⌘A, ⇧⌘C, ⇧⌘B | composer: attach files, Cc field, Bcc field |
| Space | reader (focus in the reader, not in a text field): Quick Look the target message's attachments, starting from the focused chip, else the first; Space again closes Quick Look. With no attachments to preview the key passes to the web view, which scrolls down a page (⇧Space up), as in Safari. In the list Space does nothing | | |

**G-sequences** arm for {{motion.duration.gSequenceWindow}} ms from the G key-down; the HUD appears at {{motion.duration.gHudDelay}} ms and leaves with the sequence (§5.32). The cheat sheet (§5.32) lists every row of this map, one key per action.

### 6.1 Precedence: Esc, Z and ⌘Z

Several surfaces answer the same key. The first row that applies wins and consumes the key; nothing below it runs.

**Esc**

| # | When | Esc does |
|---|---|---|
| 1 | Autocomplete is open (composer) | closes it; the typed text stays |
| 2 | The link popover is open | cancels it |
| 3 | The cheat sheet or the g-sequence HUD is showing | closes it |
| 4 | The search field is first responder and holds a query | clears the query (focus stays) |
| 5 | The search field is first responder and is empty | returns focus to the list; the field collapses |
| 6 | A toast is visible | dismisses the toast (its undo keeps working for the grace period) |
| 7 | Focus is in the reader or the quick reply (main window) | returns focus to the list; the quick reply keeps its text |
| 8 | Focus is on the list | nothing (no beep) |

So in the reader with a toast up, the first Esc dismisses the toast and the second returns to the list. In a composer window Esc does only rows 1–2; it never closes the window.

**⌘Z** (Edit › Undo, titled by its target)

| # | When | ⌘Z does |
|---|---|---|
| 1 | A text view or field is first responder and its undo manager can undo | undoes typing (“Undo Typing”) |
| 2 | An undo-send panel, a quick-reply countdown or an undoable toast is live | undoes the **most recent** of them: the panel or countdown cancels the send (“Undo Send”), the toast reverts its action (“Undo Archive”). The undo-send panel shows its “⌘Z” keycap only while it is that target |
| 3 | Within {{motion.duration.undoKeyGrace}} ms of a toast's action, after the toast has gone | reverts that action |
| 4 | Otherwise | nothing; the menu item reads “Can't Undo” and is disabled |

**Z** (single key, main window, no text field focused) only ever reverts the latest toast's action (rows 2–3 above restricted to toasts); it never cancels a send. Several live sends are cancelled newest first, one ⌘Z each.

---

## 7. Verification: contrast and colour vision

Computed by the token generator from `tokens.json` with WCAG 2.x relative luminance. Alpha tokens are composited in sRGB over the surface beneath them first; “`a` + `b`” means `b` composited over `a`. Need is 4.5 for text and 3.0 for essential non-text UI (glyphs that carry state, state-bearing edges, focus rings, pips, rules, rings, toggle and checkbox fills). The pair list is every foreground-on-surface combination the components above produce, including hover and pressed washes, both selection washes, washes over washes, fills, slips and all account inks; it is stored as `contrastPairs` in `tokens.json` and asserted by `DesignContrastTests` (§8.7), so a token change that breaks a pair fails `swift test`. Two pairs are selection scan cues with a 1.25 floor (`selWash` on `paper` and on `sheet`): they make the current row easy to find, while the margin rule, asserted at 3:1, carries the state. Account-ink pairs carry two needs, {{accountRules.standardMinContrast}} in Light and Dark and {{accountRules.icMinContrast}} in the IC modes (`needIC`), and the test asserts each mode against its own.

**Result:** {{CONTRAST_SUMMARY}}

Not tested on purpose: `inkDisabled` (disabled text and glyphs are exempt), decorative `rule` hairlines (they separate, they do not carry state), the toggle knob's face against the off track (its `ruleStrong` edge is the tested boundary), the popup halo against a hovered or pressed face (the halo is the ink's surface, not a mark), swatches inside the open Colour menu (the item's title names the ink), the cheat-sheet `scrim` and `scrimSolid` (they sit behind the panel and carry nothing), avatar faces and the account face wash against their surroundings (decorative; the initials on them are tested), and system-drawn chrome: menus and their badges, alerts, notifications, tooltips, and the Settings toolbar with its tabs. Every control inside Settings is Quire-drawn and tested. Bodies shown in Original colors are the sender's design on the `originalPage` inset and are not Quire pairs; adapted bodies use only tested inks (§5.14). The account square and the initial tile's edge are drawn in the account ink and are covered by the account-ink rows below, never by a `ruleStrong` pair.

**Colour vision** (account inks, Machado 2009 at full severity, CIEDE2000): see the tables in §4.2. Assertions in `AccountPaletteTests`: first six ≥ {{accountRules.firstSixMinCVD}} for every vision type in all four modes (standard-contrast target ≥ {{accountRules.firstSixTargetStandard}}, met); all ten ≥ {{accountRules.allTenMinNormal}} for normal vision; every ink ≥ {{accountRules.minFromAccentNormal}} from `accent`, ≥ {{accountRules.minFromDangerAnyVision}} from `danger` under every simulation, ≥ {{accountRules.minFromInfoNormal}} from `info`, ≥ {{accountRules.minFromStarNormal}} from `star`.

{{TABLE:contrast}}

**Graphite.** Every pair above that touches an accent-family token, regenerated with the substitutions of §3.1 (`graphiteContrastPairs` in `tokens.json`, asserted by the same test): {{GRAPHITE_SUMMARY}}

{{TABLE:graphite}}

---

## 8. Implementation map

### 8.1 Token pipeline

| Artifact | Path | Produced by |
|---|---|---|
| Source of truth | `docs/design/tokens.json` | hand-edited |
| Generator | `scripts/tools/quire-tokens.swift` (plain Foundation script, no Node; `--check` lists stale outputs and runs first in `scripts/test.sh`) | — |
| AppKit colours, fonts, metrics | `Sources/SSDesign/Generated/QuireTokens{Colors,Palettes,Typography,Scales,Layout,Content}.swift` (generated, one file per kind) in the `SSDesign` library target, which the app depends on and which imports AppKit, SwiftUI and QuartzCore but not SSCore, GRDB or WebKit | generator |
| Design runtime | `Sources/SSDesign/` beside the generated files: `QuireFont`, `QuireEnvironment`, `QuireLayerColors`, `Quire.Motion` (`finishAll()`), `QuireGlyph` and `QuireSVGPath`, `QuireSymbol` | hand |
| Accent asset | `Resources/Assets.xcassets/AccentColor.colorset` (four appearances), compiled into `Contents/Resources/Assets.car` by `scripts/build-app.sh` with `xcrun actool`, which also sets `NSAccentColorName = AccentColor` in the bundled Info.plist | generator |
| Reader CSS head | `Sources/SSCore/ConversationSupport/QuireCSS.swift` (generated string, interpolated at the top of `ConversationShellAssets.css`; it lives in SSCore because the shell is built there and SSCore does not import AppKit) | generator |
| Tests | `Tests/SSDesignTests/Generated/DesignContrastTests.swift`, `AccountPaletteTests.swift`, `RadiusScaleTests.swift` (generated); `Tests/SSDesignTests/RowMetricsTests.swift`, `GlyphPathTests.swift` and the rest of `Tests/SSDesignTests/` (hand-written); `Tests/SSCoreTests/Conversation/QuireCSSTests.swift` (the CSS head against the specimen) | generator / hand |
| Specimen | `docs/design/specimen.html` (+ PNGs via `scripts/tools/html-snapshot.swift`) | generator |

The generator also emits the `graphite` substitutions as a second branch of every accent-family provider and CSS block (§3.1), asserts `graphiteContrastPairs` next to `contrastPairs` (with `needIC` where present), and turns `cheatSheetContent` into the overlay's rows (§5.32), so the key map, the cheat sheet and the specimen cannot drift apart. Token names map one to one: `color.paper` → `NSColor.qPaper` → `Color.qPaper` → `--q-paper`; `typography.subject` → `QuireFont.subject` → `--q-font-subject`; `layout.row.height` → `Quire.Layout.Row.height` → (AppKit only, or `--q-…` where the reader needs it); `motion.duration.standard` → `Quire.Motion.standard` → `--q-dur-standard`; `motion.curve.settle` → `CAMediaTimingFunction(controlPoints:)` → `--q-ease-settle`.

### 8.2 AppKit

**Colours.** One dynamic provider per token; IC is resolved inside the provider through `bestMatch`.

```swift
// QuireTokens.swift (generated)
extension NSColor {
    static let qPaper = quire("paper", light: 0xFBFAF6FF, dark: 0x1C1B18FF, lightHC: 0xFDFCFAFF, darkHC: 0x121110FF)

    static func quire(_ name: String, light: UInt32, dark: UInt32, lightHC: UInt32, darkHC: UInt32) -> NSColor {
        NSColor(name: NSColor.Name("q." + name)) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .darkAqua?: return NSColor(rgba: dark)
            case .accessibilityHighContrastAqua?: return NSColor(rgba: lightHC)
            case .accessibilityHighContrastDarkAqua?: return NSColor(rgba: darkHC)
            default: return NSColor(rgba: light)
            }
        }
    }
}
```

- Layer-backed views re-resolve every `CGColor` in `viewDidChangeEffectiveAppearance()` and on `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`, because `CALayer` colours do not track appearance. `RowContentCache` and the avatar face cache key on appearance + contrast (never on window key state or row state).
- Account inks: `NSColor.qAccount(index)` returns the dynamic ink for palette slot 0–9; the slot is stored on the account.
- **Graphite.** The generator also emits the `graphite` table: each accent-family provider checks `Quire.isGraphite` (set from `NSColor.currentControlTint == .graphiteControlTint` or `controlAccentColor` saturation below {{platform.graphiteSaturationMax}}, refreshed on `NSColor.systemColorsDidChangeNotification`) and returns its substitution, a token or the composite of a stack (for example `accentWashHover` → `selWashIdle + hover`, pre-composited per mode). A change re-resolves layer colours exactly like an appearance change; `RowContentCache` adds the flag to its key. The reader gets `html.ss-graphite`, whose generated block redefines the same `--q-*` variables.
- **Reduce Transparency.** The cheat-sheet scrim layer reads `accessibilityDisplayShouldReduceTransparency` when it is shown and uses `scrimSolid` instead of `scrim` (observing the change while it is open).

**Fonts.** `QuireFont.role(_:) -> NSFont`, cached per role:

```swift
static func make(_ r: Role) -> NSFont {
    let base = NSFont.systemFont(ofSize: r.size, weight: r.weight)               // SF Pro
    var d = base.fontDescriptor
    switch r.family {
    case .serif:   d = d.withDesign(.serif) ?? d                                  // New York
    case .rounded: d = d.withDesign(.rounded) ?? d                                // SF Pro Rounded
    case .mono:    return NSFont.monospacedSystemFont(ofSize: r.size, weight: r.weight)
    case .sf:      break
    }
    if r.italic  { d = d.withSymbolicTraits(.italic) }
    if r.tabular { d = d.addingAttributes([.featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                                               .selectorIdentifier: kMonospacedNumbersSelector]]]) }
    return NSFont(descriptor: d, size: r.size) ?? base
}
```

Paragraph style per role: `minimumLineHeight = maximumLineHeight = lineHeight`, `baselineOffset = (lineHeight − layoutManager.defaultLineHeight(for: font)) / 2`, `lineBreakMode = .byTruncatingTail`, `allowsDefaultTighteningForTruncation = false`, `baseWritingDirection = .natural`, `alignment = .left` in left-to-right UI; `.kern` for tracking. New York coverage: `CTFontCopyCharacterSet` of the serif font, computed once; the row builder checks it and picks the twin. **Font setting:** the app sets the choice on `QuireEnvironment` at launch, before the first window, and on every change; `QuireFont` maps each serif role to its twin under SF Pro before it looks a font up, so its caches key on the role actually set and can never hand back the other face. The choice is part of `QuireEnvironment.cacheKey(for:)`, so row strings and avatar faces rebuild, and the change is posted as `QuireEnvironment.didChangeNotification`: every view that holds a font or a laid-out string re-applies on it, and the reader toggles `html.ss-sf` and `body.ss-sans` in every pooled view through `ss.preferences`.

**Drawing.** Rows draw the pip, margin rule, account ring, initial tile, count badge and tag in `draw(_:)` with `NSBezierPath`; the cached avatar face is a ring-less bitmap drawn first, and the ring is stroked over the row fill with the gap left undrawn (§5.7). Never set a layer shadow on a row. `ConversationRowView.drawSelection(in:)` reads `window?.isKeyWindow` (not first-responder state) for emphasized vs idle and suppresses hover when selected; the list's hover tracking is paused between `willStartLiveScroll` and `didEndLiveScroll`. Focus rings are drawn by the control in `draw(_:)` when it is first responder (with `focusRingType = .none`), because the system ring's alpha falls below 3:1 on paper.

**Spinners.** One `QuireSpinnerView` (layer-backed `NSView` with a `CAShapeLayer`, §5.37) replaces every `NSProgressIndicator`; it takes a size (12 / 16 / 32) and a colour token and owns its delay, fade-in and rotation.

**Components.** The AppKit components live in SSDesign's `AppKit/` folder, one public type per file: `QuireControl` (hover, pressed, focused and key state for every Quire-drawn control) and the controls on it (`QuireButton`, `QuireIconButton`, `QuirePopUpButton`, `QuireCheckbox`, `QuireRadioGroupView`, `QuireToggle`, `QuireTextField` with its secure variant, `QuireSearchField`, `QuireUnderlineTabs`), `QuireBannerView` (§5.38), the slips (`QuireSlipView`, `QuireUndoPanelView`, `QuireSequenceHUDView`), `QuireKeycap`, `QuireBadge`, `QuireTag`, `QuireAvatarRenderer`, `QuireHairline`, `QuireEmptyStateView`, `QuireSkeleton`, `QuireProgressBar` and `QuireContrailView`. The banner and the radio group carry a `View` suffix because the SwiftUI versions own the plain names (`QuireBanner`, `QuireRadioGroup`, §8.3). `QuireWindowChrome` configures and measures the main and composer windows (§3.2).

**Panels and overlays.** The undo-send `NSPanel` is borderless, non-activating, transparent and outset by `layout.undoPanel.shadowMargin*` (§5.31). The cheat sheet is an overlay view in the main window's content view, above the split view, with the scrim as its own layer (§5.32). The rail toggle sets the split item's `isCollapsed` inside `NSAnimationContext` with `duration = 0`.

**Motion.** `Quire.Motion.finishAll()` is called first in `KeyboardRouter.handle(_:)`: it walks the registered animators, sets each layer's model value to its final state inside `CATransaction.setDisableActions(true)` and removes running animations; `NSAnimationContext` groups run with `allowsImplicitAnimation` and the token durations; every animation checks `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`.

### 8.3 SwiftUI (Settings)

`Color.qAccent = Color(nsColor: .qAccent)` and so on for every token; fonts via `Font(QuireFont.role(.body))`. Window background `Color.qCanvas`. The window and its `TabView` toolbar (tab style) are the system's; the accent asset tints the selected tab's symbol. Every control **inside** the tabs uses a Quire style, because native SwiftUI controls ignore Quire's metrics and colours and draw the system focus ring, which falls below 3:1 on `canvas`:

| Control | Implementation | Tokens |
|---|---|---|
| Focus ring (all controls below) | `.focusEffectDisabled()` on the control, `@FocusState` to know which is focused, and `.overlay` of a `RoundedRectangle(cornerRadius: controlRadius + gap)` stroked {{border.focusRing.width}} pt (IC {{border.focusRing.widthHC}}) in `Color.qFocus`, outset by gap + width/2 | `border.focusRing` (gap {{border.focusRing.gap}}, {{border.focusRing.gapOnAccentFill}} on fills) |
| Toggle | `QuireToggleStyle: ToggleStyle` draws the track (`Capsule`, {{layout.toggle.width}} × {{layout.toggle.height}}, off `fill` + `ruleStrong` stroke, on `accentFill`; it never changes on hover or press) and the knob (`Circle`, {{layout.toggle.knob}} pt, `knob` face, {{layout.toggle.knobPressedWidth}} pt wide while `configuration.isPressed`, {{layout.toggle.knobEdge}} pt `ruleStrong` stroke, `.shadow` from `layout.toggle.knobShadow`); knob offset animated with `dur.quick` `ease.glide` unless Reduce Motion; the label is `body` `ink` with an {{layout.checkbox.labelGap}} pt gap and part of the tap target | `layout.toggle`, §5.26 |
| Checkbox | `QuireCheckboxStyle: ToggleStyle`: {{layout.checkbox.size}} pt `RoundedRectangle(cornerRadius: {{layout.checkbox.radius}})`, off `sheet` + `ruleStrong` (face `sheet + hover` / `sheet + pressed`), on `accentFill` + `checkmark` {{layout.checkbox.glyph}} pt `onAccent` (hover `accentFillHover`, pressed `controlOnPressed`) | `layout.checkbox` |
| Radio group | `QuireRadioGroup` (a `HStack` of `Button`s, one per option, each with a {{layout.radio.size}} pt circle; on `accentFill` + {{layout.radio.dot}} pt `onAccent` dot, hover and press as the checkbox); one Tab stop for the group, ← → move the choice; accessibility `.isSelected` and the radio-group container trait | `layout.radio` |
| Popup | `Menu { … } label: { QuirePopupLabel(value) }` with `.menuStyle(.borderlessButton)` and `.menuIndicator(.hidden)`; the label draws {{layout.popup.height}} pt `raised` face, `ruleStrong` edge, `body` `ink` value and the `chevron.up.chevron.down` {{layout.popup.chevron}} pt `ink2`; the menu itself is the system's, with a checkmark on the current value | `layout.popup` |
| Text field | `.textFieldStyle(.plain)` inside `QuireFieldStyle`, a container drawing the {{layout.settings.fieldHeight}} pt `sheet` face, {{border.strong.width}} pt `ruleStrong` edge (hover `ink3`, error {{border.error.width}} pt `danger`), padding {{layout.textField.padX}}; `mono` font for client IDs | `layout.textField` |
| Buttons | `QuireButtonStyle(.primary / .secondary / .ghost / .link, size: .small)` drawing §5.24 fills, edges and labels (`.link` never draws a wash: underline on hover, `ink2` + underline pressed) | `layout.button` |
| Account group | `VStack` of `QuireAccountRow`s in a `.focusable()` container (not `List(selection:)`), background per row: `selWash` / `selWashIdle` plus a {{border.marginRule.width}} pt leading `Rectangle` in `selRule` / `selRuleIdle`, key state from `@Environment(\.controlActiveState)`; past {{layout.settings.groupMaxRows}} rows the stack sits in a `ScrollView` capped at {{layout.settings.groupMaxRows}} × {{layout.settings.accountRow}} pt with clipped-edge hairlines, `ScrollViewReader` keeping the selection in view | §5.40 |
| Form layout | a `Grid` with a trailing-aligned {{layout.settings.labelColumn}} pt label column and {{layout.settings.row}} pt rows (`Form` with `.formStyle(.columns)` would bring native control styling back) | `layout.settings` |

`controlActiveState == .inactive` (Settings not key) switches the selection to the idle pair and primary buttons to the secondary look, as §3.4 lists; nothing else changes.

### 8.4 Reader (WKWebView) CSS

- The generated head defines every colour as `--q-<token>` in four blocks (`:root`, `@media (prefers-color-scheme: dark)`, `@media (prefers-contrast: more)`, both) plus `html.ss-ic` copies of the IC blocks and `html.ss-graphite` blocks that redefine the accent-family variables per mode (§3.1; the app sets the class); typography as `--q-font-<role>` shorthands and `--q-track-<role>`; spacing `--q-s1…`; radii `--q-r-…`; durations `--q-dur-…`; curves `--q-ease-…`; elevation `--q-e1…`. The specimen's `<style>` head is this exact output.
- Current variables map as: `--ss-bg` → `--q-canvas`, `--ss-card` → `--q-sheet`, `--ss-border` → `--q-rule`, `--ss-text` → `--q-ink`, `--ss-muted` → `--q-ink2` (recipients, snippets) / `--q-ink3` (dates), `--ss-accent` → `--q-accent`, `--ss-chip` → `--q-fill`, `--ss-selected` → `--q-focus`, `--ss-star` → `--q-star`.
- Classes: `.ss-card` (expanded) → sheet (radius `r.lg`, padding per §5.14, `e1`); collapsed cards → `.ss-stack` rows joined in one sheet; `.ss-button` → `.ss-elide` toggle and link buttons; `.ss-chip` → attachment chip; `.ss-footer a` → ghost buttons; `.ss-tools` is removed (Original colors moves to the header hover actions).
- `bodyCSS`: `body.ss-set { font: var(--q-font-reading); max-width: {{layout.reader.measure}}px; }` for bodies whose stored typesetting is `plain` or `unstyled` (the shell receives the flag in the render payload; it never scans the HTML); `body.ss-set.ss-sans { font: var(--q-font-readingSans) }` for the SF Pro font setting or uncovered scripts. It also injects the Quire focus ring for links, in every body document, because WebKit's default ring falls below 3:1 and a sender's CSS must not decide focus:

```css
a:focus { outline: none; }
a:focus-visible { outline: {{border.focusRing.width}}px solid var(--q-focus) !important; outline-offset: 1px !important;
                  box-shadow: 0 0 0 1px var(--q-sheet) !important; border-radius: 2px; }   /* 1 pt gap in the sheet colour */
@media (prefers-contrast: more) { a:focus-visible { outline-width: {{border.focusRing.widthHC}}px !important; } }
html.ss-ic a:focus-visible { outline-width: {{border.focusRing.widthHC}}px !important; }
.ss-original a:focus-visible { --q-focus: {{color.focus.light}}; box-shadow: 0 0 0 1px var(--q-originalPage) !important; }
@media (prefers-contrast: more) { .ss-original a:focus-visible { --q-focus: {{color.focus.lightHC}}; } }
html.ss-ic .ss-original a:focus-visible { --q-focus: {{color.focus.lightHC}}; }
```

  The light gap and the ring together stay visible on any sender background: on a dark band the gap shows, on a light one the ring does. The web view's `tabFocusesLinks` follows Full Keyboard Access (§5.14).
- **SF Symbols**: the shell builder receives `symbolCSS` (the data-URI custom properties, §4.11) from the app and emits `.ss-sym { width: {{platform.readerSymbolCanvas}}em; height: {{platform.readerSymbolCanvas}}em; background: currentColor; -webkit-mask: var(--sym) center / contain no-repeat; }` with one modifier class per symbol.
- **Reduced motion, precisely.** Movement uses `--q-move`, which defaults to the token duration; fades use `--q-dur-reducedFade` and are exempt:

```css
.ss-card-body { transition: height var(--q-move, var(--q-dur-standard)) var(--q-ease-settle),
                            opacity var(--q-dur-reducedFade) linear; }
@media (prefers-reduced-motion: reduce) { :root { --q-move: 0ms; } }
html.ss-rm { --q-move: 0ms; }
.ss-contrail { transition: width var(--q-countdown) linear; }
@media (prefers-reduced-motion: reduce) { .ss-contrail { transition-timing-function: steps(var(--q-countdown-steps)); } }
html.ss-rm .ss-contrail { transition-timing-function: steps(var(--q-countdown-steps)); }
```

The countdown text (“Sending in 4 s”) is always present, in AppKit and the reader.
- **Spinner** (CSS): `.ss-spin { width: {{layout.progress.spinner.0}}px; height: {{layout.progress.spinner.0}}px; border-radius: 50%; border: {{layout.progress.spinnerStroke.0}}px solid currentColor; border-right-color: transparent; animation: ss-turn var(--q-dur-spinnerTurn) linear infinite; } @keyframes ss-turn { to { transform: rotate(1turn); } }`; it shows only after `--q-dur-spinnerDelay` (`animation-delay` on an opacity fade-in). It matches AppKit's `QuireSpinnerView` (§5.37): same ¾ ring, stroke, turn and delay.
- **Bottom inset.** `ss.setBottomInset(px)` sets `padding-bottom` on the conversation container to the quick reply's height + {{layout.reader.stackGap}}, so the bar overlays the web view without resizing it (§5.18). Called once per height change, never per animation frame.
- **Wide HTML.** After each body iframe loads, the shell compares the body's `scrollWidth` with the sheet's content width (the inset's inner width in Original colors) and applies `zoom` (minimum {{layout.reader.htmlMinZoom}}) or `overflow-x: auto` (§5.14); `ss.refit()` recomputes all of them, called by the app when a live resize ends.
- **Dark-mode colour.** The render payload carries `typesetting` and `declaresColors` per message and the app passes the appearance. In a dark appearance the shell sets `color-scheme: dark` on every styled body document, and for `declaresColors` bodies adds `ss-adapt` to that document's root unless the message is in Original colors. The adaptation sheet is injected once per body document:

```css
html.ss-adapt { color-scheme: dark; }
html.ss-adapt, html.ss-adapt body, html.ss-adapt body * {
  color: var(--q-ink) !important;
  background-color: transparent !important;
  background-image: none !important;
  border-color: var(--q-rule) !important;
}
html.ss-adapt a, html.ss-adapt a * { color: var(--q-accent) !important; }
:where(a:link) { color: var(--q-accent); }               /* styled bodies that declare nothing */
.ss-original { background: var(--q-originalPage); border-radius: var(--q-r-xs);
               padding: {{layout.reader.originalInsetPad}}px; color-scheme: light; }   /* Original colors wrapper */
```

  `ss.originalColors(id, on)` toggles `ss-adapt` and the `.ss-original` wrapper for one message, then refits it. Light appearances never add either.
- **Expand and collapse** follow §4.10. The shell keeps `heights[messageId + ':' + contentWidth]` from every measurement. On expand it sets the body wrapper's `height` from its current px value to header + (cached height, or the 58 pt skeleton) + footer with the transition on; each measurement (`0`, `50`, `300` ms, image `load`) sets `transition: none`, writes the measured px height, forces a style flush and restores the transition, so a measurement snaps instead of retargeting the animation. `ss.finishAll()` (called by `finishAll()`, §4.10) sets every running wrapper to its target with `transition: none`. Heights are always px, never `auto`.
- **Offline body.** When a message has no stored body (`hasBody = false`) the payload carries the snippet and an `offline` flag from the app: offline, the shell renders the preview and the neutral `wifi.slash` notice (§5.14) instead of the skeleton; online, it shows the skeleton only while the app reports the fetch in flight. Today's 0.6-opacity snippet (`.ss-pending-body`) is removed.
- **Target message.** `ss.target(id)` marks the target sheet (`.ss-target`: footer keycaps, and the `ruleStrong` edge when `.ss-multi` is on the container); the app calls it on click, `n`/`p`, Tab and open.
- **Skeleton** (CSS): `.ss-skel` bars in `--q-fill`, radius `--q-r-xs`, no animation.

### 8.5 Data the design needs

- `SanitizedBody` gains `typesetting: BodyTypesetting` (`.plain`, `.unstyled`, `.styled`) and `coveredByNewYork: Bool`, computed once by `HTMLSanitizer` at sync time; `bodies` gains `typesetting INTEGER NULL` (NULL = styled, for bodies stored earlier). This is a schema addition to `docs/DATA-MODEL.md` and needs the usual agreement; until it lands, every body renders as styled (no visual regression, just no serif page).
- `accounts` gains `ink_slot INTEGER` and `monogram TEXT NULL` (NULL = derived). Same agreement applies. The pre-Quire `color_hex` column is retired: nothing reads it, and it stays only because v1 declared it NOT NULL (new rows store an empty string). Account names are derived (§4.2), never stored.
- **`declaresColors: Bool`** on `SanitizedBody`, set by `HTMLSanitizer` at sync time when the body sets its own background or text colour (`bgcolor`, `background`, `color` in `style` attributes or `<style>` blocks, `<font color>`, `text`/`link` attributes on `body`); `bodies.declares_colors INTEGER NULL` (NULL = unknown: treated as true for `styled` bodies, false otherwise). It decides whether a body is adapted in dark appearances, and whether it gets the Original colors notice, hover action and inset (§5.14, §5.16), without scanning HTML at render time.
- **A failed-operation mark per conversation.** `ConversationSummary` has only `hasPendingOperations`; it gains `failedOperation: OperationKind?` (the kind of the newest operation with status `failed` on any message of the conversation that has not been acknowledged), backed by `conversations.failed_op_kind TEXT NULL` maintained in the same transaction that marks an operation failed. It clears (set to NULL) when the conversation is opened (selected for {{motion.duration.spinnerDelay}} ms), when a later operation on it is confirmed, or when the failed row is pruned after 24 hours. Same agreement applies.
- **One preference**, `originalColorsNoticeDismissed` (UserDefaults), for §5.16.
- **Dropped rather than added:** no per-sender image allowlist (images load per message, as `docs/ARCHITECTURE.md` says), and no avatar photos (they would need Contacts access); faces are initials only.
- No other data changes: unread, starred, pending operations, categories and counts already exist.

### 8.6 Source map: what each section replaces

| Spec | Current source | Change |
|---|---|---|
| §4.1–4.3 tokens | `List/NSColor+Hex.swift`, hex literals across views, `.systemYellow` star, `controlAccentColor` pip, `quaternaryLabelColor` badge, four avatar palettes (`List/AvatarCache.swift`, `Shell/AccountStripButton.swift`, shell `.ss-avatar`, compose tokens) | all colours from `QuireTokens.swift`; one avatar palette, one account palette |
| §4.4 typography | font sizes set per view (10–26 pt) | `QuireFont` roles; New York subjects and reading; the Font setting through `QuireEnvironment` (SF Pro twins app-wide, live) |
| §5.1 window | `Shell/MainWindowController.swift` | empty unified toolbar (`toolbarStyle = .unified`, `titlebarSeparatorStyle = .none`) so the lights sit at the 52 pt band's centre; rail width derived from the zoom button's frame ({{layout.rail.width}} / {{layout.rail.width26}}); title-bar zone {{layout.window.titlebarZone}} |
| §5.2 rail | `Shell/AccountStripViewController.swift`, `Shell/AccountStripButton.swift` | opaque `spine`; folder tiles at the top with a raised selection; the account group anchored above Add with its own scrolling clip; face + ring + domain monogram; margin-rule selection; accent badges with cut-out |
| §5.3–5.6 list header | `Shell/ListPaneViewController.swift` (search field, filter, title) | one {{layout.listHeader.height}} pt line: masthead (the title menu only in minimal mode), search with resting edge filling the free width, compose; no filter tabs |
| §5.7 row | `List/ConversationCellView.swift`, `List/ConversationRowView.swift`, `List/ConversationRowContent.swift`, `List/RowContentCache.swift`, `List/AvatarCache.swift` | row {{layout.row.height}} (from 72), ring drawn in `draw(_:)` instead of the 10 pt dot, ring-less face cache, `ss.queued` instead of the 0.6 alpha fade, unread time, failed state, selection from window key state, hover paused while scrolling, cache key gains appearance + contrast |
| §5.10 list tail | `List/MessageListViewController.swift` (20 pt “Loading…” footer) | {{layout.listFooter.height}} pt footer row with delayed spinner, “Loading older mail…”, retry |
| §5.8 running heads | `List/MessageListViewController.swift`, `List/MessageListTableView.swift` | non-sticky group rows; `j`/`k` skip them |
| §5.11 sync line | `Shell/SyncStatusBar.swift` (`SyncStatusSummary.make`: reauth, then network-only errors as offline, then the first error, then bootstrapping) | {{layout.syncLine.height}} pt, states and contrail; the ten-step precedence and the counted copy for several accounts |
| §5.12 reader header | `Conversation/ConversationHeaderView.swift` (44 pt) | {{layout.readerHeader.height}} pt native header with kicker, headline and both action groups |
| §5.13–5.17, §5.19 reader | `SSCore/ConversationSupport/ConversationShellAssets.swift` (CSS + `ss.render`), `Conversation/ConversationViewController.swift`, `Conversation/WebViewPool.swift` | stack + sheet, elision toggle, neutral images banner, chips, multi-select state, SF Symbol masks, `ss-ic`/`ss-rm`/`ss-rt` classes |
| §5.18 quick reply | `Conversation/QuickReplyView.swift`, `Conversation/ConversationViewController.swift` (`showStrip`) | field on the column overlaying the web view (bottom inset), tool row with mode tabs, the countdown strip with contrail and the outcome copy, visibility per reader state |
| §5.19 drafts | `Conversation/ConversationViewController.swift` | read-only draft sheet, Continue Editing / Discard Draft |
| §5.20–5.23 composer | `Compose/ComposeWindowController.swift`, `Compose/ComposeFieldRow.swift`, `Compose/AddressTokenField.swift`, `Compose/AttachmentStripView.swift`, `Compose/AttachmentChipView.swift`, `Compose/QuotedOriginalView.swift`, `Compose/ComposeTextView.swift`, `Compose/ComposeSignature.swift` | one text axis at x = {{layout.composer.valueX}}, transparent title bar, tokens, autocomplete, strip, primary Send, status copy, format row, link popover (replaces the Add Link `NSAlert`), shared quote style 2 / 12 (from 3 / 16), Tab order, the signature's insertion and From rule |
| §5.30 toast | `Shell/ToastView.swift` (HUD material), `Shell/MainWindowController.swift` (“Undid …”) | opaque slip, coalescing, contrail, Esc, VoiceOver announcement, the no-action confirmation variant |
| §5.31 undo send | `Compose/UndoSendPanel.swift` | slip panel with contrail, numeric countdown, outlined Undo action, shadow margin |
| §5.20 closing and checks | `Compose/ComposeWindowController.swift` (`windowShouldClose` “Discard this message?”, “Send without a subject?”, “Some items couldn't be attached”) | close keeps the draft without an alert; Discard Draft… in the Message menu; the subject alert's new copy; rejected drops as a composer status |
| §5.32 HUD, cheat sheet | `Shell/KeyboardRouter.swift` (`sequenceTimeout` 1.5 s), `Shell/MainMenu.swift`, `Shell/AppDelegate.swift` (`showKeyboardHelp`, an `NSAlert` listing keys) | g-sequence HUD with a {{motion.duration.gSequenceWindow}} ms window, `finishAll()`, the ? / ⌘/ overlay with the full content table in place of the alert |
| §5.33 alerts, §5.44 reconnect | `Shell/AppDelegate.swift` (`showError` with “OK”, `showNotice`, the launch alert, `addAccount(_:reconnecting:)`) | the inventory's copy and verbs; the OAuth read failure becomes a Settings banner; reconnect states in the rail, the sync line and Settings; the wrong-account alert |
| §6 Space | `Conversation/ConversationViewController.swift` (`handleSpace`, `openQuickLookForSelectedMessage`) | kept, acting on the target message (it uses `selectedMessageID ?? last`, the same rule) |
| §5.35 menus | `Shell/MainMenu.swift` | symbols, shortcut text, G-sequences |
| §5.39 welcome | `Shell/WelcomeViewController.swift`, `Shell/AppDelegate.swift` (“Adding demo account…”) | layout, copy and states; “Try the demo” kept, with the Preparing the demo and Demo failed states |
| §5.40 settings | `Shell/SettingsWindowController.swift` (`statusText(for:)`, the OAuth `Form`), `Shell/AppSettings.swift`, `Shell/Settings/SignatureEditorView.swift`, `Shell/Settings/GeneralSettingsView.swift`, `Shell/Settings/MailboxSizeModel.swift` | system tabs; account statuses for every sync phase; the OAuth form row by row with “Saved” beside Save; Quire control styles and drawn focus rings; account group with margin-rule selection, +/−, empty and busy states; notices as banners; colour, monogram and signature, font, density, account initials, Keep mail on this Mac and the mailbox's size |
| §5.43 demo | `Shell/MainWindowController.swift` (window title), `Shell/ListPaneViewController.swift`, `Shell/SettingsWindowController.swift` (demo note), `Shell/AppEnvironment.swift` | Demo tag and menu, sync-line state, Settings banner, Leave Demo |
| §5.44 add account | `Shell/AppDelegate.swift` (provider `NSAlert`, “Finish signing in…”), `Shell/AccountStripViewController.swift` | provider pull-down menu, pending tile, sync-line waiting state with Cancel, error alerts |
| §5.41 notifications | `Shell/NewMailNotifier.swift`, `Shell/NewMailNotificationAction.swift`, `Shell/NewMailNotificationResponder.swift`, `Shell/MainWindowController.swift` (`answer`) | content rules; the category and its three actions; a response held until there is a main window; actions with no toast and no undo |
| §4.11 reader symbols | `Conversation/PooledConversationView.swift`, `Conversation/WebViewPool.swift` | rasterise symbols once per pool, inject `symbolCSS` |

### 8.7 Tests

Design tests live in `Tests/SSDesignTests`: the generated ones in `Tests/SSDesignTests/Generated/` (rewritten by the generator, never edited), the hand-written ones beside them, and the colour math they share, a port of `docs/design/source/colorlib.py`, in `Tests/SSDesignTests/Support/`. Tests of the reader shell live in `Tests/SSCoreTests/Conversation/`, and tests of the app's own windows in `Tests/SuperSparrowAppTests/`.

- **`DesignContrastTests`** (generated from `contrastPairs` and `graphiteContrastPairs`): resolves each pair in four modes with the same compositing and asserts ≥ `need`, or ≥ `needIC` in the IC modes when the pair has one.
- **`AccountPaletteTests`** (generated from `accountRules`): Machado simulation + CIEDE2000; asserts the six-account floor, the ten-account normal floor and the distances from accent, danger, info and star.
- **`RowMetricsTests`**: lays out subjects in Latin, Cyrillic, Japanese, Arabic, Hebrew, Thai and Devanagari with the chosen role (New York or twin) and asserts the used line fragment height ≤ the role line height and that the coverage check picks the twin for the last five.
- **`GlyphPathTests`**: parses the five custom glyph paths and checks their bounds stay inside the grid.
- **`WindowChromeTests`**: builds the main window off screen with the §3.2 configuration (empty unified toolbar) and asserts that the close button's centre is {{layout.trafficLights.centerY}} ± {{layout.trafficLights.tolerance}} pt from the top, that the derived rail width is ≥ the zoom button's `maxX` + {{layout.rail.lightsClearance}}, and that a composer window configured by `QuireWindowChrome` measures the system title bar. `ComposerChromeTests` (SuperSparrowAppTests) builds the real composer, with and without the From row, and asserts its first field row starts at that measured height. A failure means a macOS release moved the lights or the band: re-derive the title-bar metrics (§3.2) rather than nudging numbers.
- **`ReaderSymbolTests`**: the shell's CSS references only `--sym-*` names in `readerSymbols`, and every name rasterises (`NSImage(systemSymbolName:)` is non-nil).
- **`RadiusScaleTests`** (generated): every `radius` metric in `layout` is on the scale or a listed exception (§4.6). The exception list mirrors `RADIUS_EXCEPTIONS` in `docs/design/source/tokens_def.py`; `tokens.json` does not carry it, so `scripts/tools/quire-tokens.swift` holds it, each exception pinned to its value.
- Existing signposts stay the gate: `j`/`k` ≤ 16 ms and list refresh ≤ 50 ms on the synthetic mailbox after the row changes, and a hover-while-scrolling run that asserts no avatar cache miss.

---

## 9. Scope decisions

**In v1:** everything above. New settings are limited to Font, List density, Show account initials, and per-account colour, monogram and signature (plus the one Original colors notice preference).

**Not in v1, deliberately:**

- **A Text size setting.** macOS has no app text-size preference; if the team adds one later, it applies {{deferred.textSize.deltas}} pt to every role and steps standard rows {{deferred.textSize.rowHeights}} pt (compact rows by the same amounts). Nothing in this language depends on it.
- **Row animations** of any kind: no slide-out on archive, no gap closing, no star pop, no dot shrink.
- **Sticky date headers** and date headers in search results.
- **App-drawn vibrancy.** The rail and every pane are opaque.
- **Following an arbitrary system accent** in custom-drawn surfaces (only Graphite is honoured, §3.1).
- **Hover action buttons on rows**; the keyboard and the context menu cover them.
- **Avatar photos**, local or remote. Faces are initials only (no Contacts access).
- **A per-sender image allowlist.** Remote images load per message.
- **A contact popover.** Hovering an avatar shows the address tooltip; nothing more.
- **Delete Forever and Empty Trash.** Trash is emptied by the provider on its own schedule; in Trash the header offers Move to Inbox and no Trash action (§5.12).
- The sixth custom-glyph slot stays free.
