# Wingbar

**Paper design language · direction “Heritage, rebuilt” · v1.0 · 2026-11-02**

Wingbar keeps Sparrow’s 2011 shape — a dark slate account rail, a crisp bright list, one confident blue, compact avatar-forward rows — and rebuilds it with 2026 craft: device-pixel hairlines, a two-tier type hierarchy (compact list, comfortable reading), rounded-square tinted avatars and a dark mode tuned value by value. The account rail is the *wing*; in the unified inbox every row carries its account’s *wingbar*, a 3 pt ribbon on the leading edge that visually continues the rail into the list.

Companion files in this folder: `specimen.html` (self-contained, tokens as CSS custom properties generated from the same table as this document, light and dark; SF Symbols are drawn there as inline-SVG stand-ins, the three custom glyphs are the exact paths below), `specimen-light.png`, `specimen-dark.png`.

All metrics are in points (pt). In CSS 1 pt = 1 px. “L / D / L·IC / D·IC” = light, dark, light increased contrast, dark increased contrast.

---

## 1. Principles

1. **The list is the product.** Rows are fixed-height, painted once from cached strings, and never animate. Selection moves in the same frame as the key press. Anything that would cost a frame during `j`/`k` (blur, shadow, per-row animation, Auto Layout) does not exist in the list.
2. **Slate frames, paper holds.** Dark slate is chrome: identity, navigation, transient feedback (rail, toasts, undo send, app icon). Bright surfaces carry mail. In dark mode the relationship is kept: the rail is the darkest surface, the list one step up, cards one step above the reader canvas.
3. **One blue, one meaning.** Sparrow Blue (`#1F69E0`) means *selected*, *unread* or *the primary action*. Links and ghost buttons use the text tone of the same blue. Nothing decorative is blue; accounts never get a blue that competes with selection (account 1’s blue is lighter and only appears as a 3 pt ribbon or a rail tile).
4. **Every state has a shape.** Unread is a dot plus weight; selected is a fill plus the open conversation; starred is a filled glyph; pending is a glyph; errors carry a glyph and words. Color confirms state; it never carries it alone.
5. **Native first, then signature.** Standard menus, window buttons, alerts, Settings and notifications stay system. The signature lives in four places only: the rail, the wingbar, the avatars and the horizon line.

## 2. Signature elements

| Element | What it is | Why it is Sparrow, and why it is not Mail |
|---|---|---|
| **The wing (slate rail)** | 72 pt opaque slate column (`#2B3036` light, `#0F1114` dark) holding traffic lights, All Inboxes, one 36 pt account tile per account, Add and Settings. Selection is a lighter *well* plus a 3 × 20 pt white *perch* on the outer edge. | Sparrow’s dark account strip, kept dark in **both** appearances. Mail has no rail; Superhuman has no accounts column. |
| **The wingbar** | In the unified inbox, a 3 pt ribbon of the account color on each row’s leading edge, full row height, so consecutive rows of one account read as one ribbon flowing out of the rail tile of the same color. | Unique to Wingbar. Replaces the current 10 pt account dot that collides with avatars. |
| **Rounded-square tinted avatars** | Avatars are squircles (r = 0.3 × d, continuous corners) in a soft tint with deep initials in SF Pro Rounded. Account tiles in the rail use the same shape filled with the account’s glow color. | Sparrow used rounded-square contact photos; macOS Mail uses circles. Tints keep 9 rows calm so the blue reads. |
| **The horizon** | List header and reader header are both 88 pt with the same bg; their bottom hairlines meet at one y across the window. The 52 pt title band above it is shared with the rail’s traffic lights. | Precise, quiet structure instead of toolbars. |
| **Chalk badges** | Unread badges on slate are white pills with slate numerals (SF Pro Rounded Bold), cut out of the tile by a 2 pt ring. | Sparrow’s pill counts, rebuilt with a cut-out instead of a drop shadow. |
| **Blue time** | An unread row’s time turns accent blue and semibold, next to the dot and the semibold sender. | Direct Sparrow heritage, made redundant with the dot and weight. |
| **The deck** | In the reader, consecutive collapsed messages are one card (“deck”) split by hairlines; the expanded message lifts out 12 pt below it. | Sparrow stacked cards, rebuilt flatter and faster to scan. |

## 3. Platform decisions

- **System accent color: not followed for selection or primary actions.** Decision: Sparrow Blue is fixed. Reasons: (a) the selected-row fill must keep ≥ 4.5:1 with white text and ≥ 3:1 against the list in both appearances — several system accents (yellow, graphite, multicolor-pink) fail one of these; (b) the account palette was tuned against this blue so account 1 never reads as “selected”; (c) brand recognition — blue is the Sparrow memory. We *do* honor the system **highlight color** for text selection inside text views and the reader (AppKit `selectedTextBackgroundColor`, CSS `::selection` left at system default), and the system **accent** inside standard controls we do not restyle (NSAlert default button, menus, SwiftUI `Toggle` in Settings when the user picks a non-blue accent).
- **Appearance:** follows the system (`NSApp.appearance = nil`). No in-app override.
- **Increased contrast:** separate token values (§4.1). AppKit detects it through `NSAppearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])`; WKWebView through `@media (prefers-contrast: more)`, with the app also setting `data-contrast="more"` on `<html>` when `NSWorkspace.accessibilityDisplayShouldIncreaseContrast` changes (belt and braces). IC adds: 1 pt `line-control` outlines on fields, segmented track and secondary buttons; hairlines become 38–40 % alpha; inactive selection gets an inset keyline; toggles keep their outline.
- **Reduce motion:** every movement becomes a ≤ 100 ms opacity change or nothing (§4.12).
- **Reduce transparency:** the only app-owned material (reader header scroll-under) becomes opaque `bg-list`; menus and notifications are system and follow automatically. Toasts and the rail are opaque already.
- **Window chrome:** standard traffic lights, repositioned (not redrawn) to center on the rail; full-size content view, transparent title bar, hidden title, an empty unified `NSToolbar` only to get the 52 pt title band. Standard menu bar with every command, its key equivalent and an SF Symbol.

---

## 4. Foundations

### 4.1 Color

**Slate ramp (reference palette).** Cool neutral, hue ≈ 215°. Components use semantic tokens below, never ramp steps directly.

| Step | 0 | 25 | 50 | 100 | 150 | 200 | 300 | 400 | 500 |
|---|---|---|---|---|---|---|---|---|---|
| Hex | `#FFFFFF` | `#F9FAFB` | `#F3F5F7` | `#EBEEF1` | `#E1E5E9` | `#D3D8DE` | `#B6BDC5` | `#8F97A1` | `#6E7681` |

| Step | 600 | 700 | 750 | 800 | 850 | 900 | 925 | 950 | 1000 |
|---|---|---|---|---|---|---|---|---|---|
| Hex | `#555D67` | `#3F454D` | `#343A41` | `#2B3036` | `#23272C` | `#1C1F23` | `#17191D` | `#121417` | `#0D0F11` |

**Semantic tokens.** Values marked “@ n %” are the color at that alpha (use `NSColor(…).withAlphaComponent`, CSS `rgba`). The CSS names are `--wb-<token>`; the Swift names are `Wingbar.Color.<lowerCamel>` (e.g. `bgList`).

| Token | Use | Light | Dark | Light · IC | Dark · IC |
|---|---|---|---|---|---|
| `bg-rail` | Account rail. Slate in both appearances; darker than the list in dark mode | `#2B3036` | `#0F1114` | `#1C1F23` | `#000000` |
| `bg-list` | List pane, list header, reader header, quick-reply bar, welcome | `#FFFFFF` | `#1A1D21` | `#FFFFFF` | `#0E1012` |
| `bg-reader` | Reader canvas behind message cards; Settings window background | `#F2F4F6` | `#131518` | `#E8EBEE` | `#000000` |
| `bg-card` | Message cards, composer, Settings groups | `#FFFFFF` | `#1F2226` | `#FFFFFF` | `#16181B` |
| `bg-raised` | Menus, popovers, tooltips, alerts, focused fields, segmented thumb | `#FFFFFF` | `#272B30` | `#FFFFFF` | `#1C1F23` |
| `bg-field` | Search, quick-reply and text fields at rest; banners; attachment chips | `#EDF0F3` | `#2A2E33` | `#FFFFFF` | `#000000` |
| `bg-hover` | Pointer hover on rows and ghost/icon buttons | `#F4F6F8` | `#212428` | `#EBEEF1` | `#22262B` |
| `bg-pressed` | Pressed ghost/icon buttons, open title menu | `#E9EDF0` | `#2A2E33` | `#DDE2E7` | `#30353B` |
| `bg-slate` | Toasts and the undo-send panel (lifted slate in dark) | `#2B3036` | `#363C43` | `#1C1F23` | `#3A4048` |
| `fill-subtle` | Count badges, secondary buttons, segmented track, pills, account chip | `#E9ECF0` | `#2E3338` | `#DCE1E6` | `#3A4047` |
| `fill-strong` | Hover on secondary buttons/pills, toggle-off track, quote bar | `#D8DDE3` | `#3A4047` | `#C5CCD4` | `#4A515A` |
| `fill-selected` | Selected row, key window; highlighted menu item | `#1F69E0` | `#2667D6` | `#0F55C8` | `#2463D6` |
| `fill-selected-inactive` | Selected row when the window is not key | `#E1E6EC` | `#2E333A` | `#D3D9DF` | `#3A414A` |
| `fill-accent` | Primary button, checkbox/toggle on, selected token | `#1F69E0` | `#2667D6` | `#0F55C8` | `#2463D6` |
| `fill-accent-hover` | Primary hover | `#1A5FCF` | `#2E70DE` | `#0C4AB0` | `#2A69DB` |
| `fill-accent-pressed` | Primary pressed | `#164FB0` | `#1F5BC4` | `#093E96` | `#1C55BE` |
| `accent-subtle` | Address tokens, “images loaded” banner, active pill | `#E5EEFC` | `#1E2D45` | `#D3E2FB` | `#17284A` |
| `text-primary` | Primary text | `#16191D` | `#ECEEF1` | `#000000` | `#FFFFFF` |
| `text-secondary` | Snippets, recipients, secondary labels | `#4A525B` | `#B0B7C0` | `#30363D` | `#D5DAE0` |
| `text-tertiary` | Times, captions, placeholders, sync line, date dividers | `#5E666F` | `#989FA9` | `#454C54` | `#BAC1C9` |
| `text-disabled` | Disabled labels (exempt from contrast) | `#A5ACB4` | `#596069` | `#7C848E` | `#7C848E` |
| `text-accent` | Links, ghost buttons, unread time, focused segmented text | `#1A63D6` | `#6CA6FF` | `#0B4FBF` | `#A3C7FF` |
| `text-on-accent` | Text on fill-selected / fill-accent | `#FFFFFF` | `#FFFFFF` | `#FFFFFF` | `#FFFFFF` |
| `text-on-accent-2` | Snippet and time on a selected row | `#FFFFFF` @ 92% | `#FFFFFF` @ 94% | `#FFFFFF` @ 100% | `#FFFFFF` @ 100% |
| `text-on-slate` | Text and glyphs on the rail and toasts | `#F2F4F6` | `#F2F4F6` | `#FFFFFF` | `#FFFFFF` |
| `text-on-slate-2` | Secondary text and utility glyphs on slate | `#A9B1BA` | `#A9B1BA` | `#D0D5DB` | `#C3CAD2` |
| `text-accent-on-slate` | “Undo” and other actions on slate | `#8DBBFF` | `#9CC4FF` | `#B5D2FF` | `#B5D2FF` |
| `text-success` | Success text | `#1B7A3A` | `#5CCB82` | `#0F5F2A` | `#8BE3A8` |
| `text-warning` | Warning text | `#8A5300` | `#F0B44C` | `#6B4000` | `#FFD07A` |
| `text-danger` | Error and destructive text | `#C0262E` | `#FF7B80` | `#9C1A21` | `#FFA4A8` |
| `line-hairline` | Row separators, card edges, header bottoms (1 device pixel) | `#16191D` @ 10% | `#FFFFFF` @ 8% | `#16191D` @ 38% | `#FFFFFF` @ 40% |
| `line-pane` | List | reader divider (1 pt) | `#DCE0E5` | `#08090B` | `#8C949E` | `#6E7681` |
| `line-control` | Checkbox and toggle-off outlines; field outline in increased contrast | `#8C949E` | `#79818B` | `#555D67` | `#B6BDC5` |
| `line-rail` | Separator inside the rail | `#FFFFFF` @ 12% | `#FFFFFF` @ 10% | `#FFFFFF` @ 40% | `#FFFFFF` @ 45% |
| `focus-ring` | Keyboard focus ring (2 pt, 1 pt gap) | `#1F69E0` | `#6CA6FF` | `#0B4FBF` | `#A3C7FF` |
| `focus-ring-on-slate` | Focus ring on slate surfaces | `#8DBBFF` | `#8DBBFF` | `#B5D2FF` | `#B5D2FF` |
| `success` | Success glyphs | `#2B8A4B` | `#4CC277` | `#1B6E37` | `#7FDDA0` |
| `warning` | Warning glyphs, rail “sign in again” badge | `#B26F00` | `#F0B44C` | `#8A5300` | `#FFD07A` |
| `danger` | Destructive button, error glyphs | `#C9282F` | `#D2343B` | `#A81E25` | `#C8333A` |
| `success-subtle` | Success banner background | `#E3F3E8` | `#173022` | `#D0EBD9` | `#123222` |
| `warning-subtle` | Warning banner background | `#FFF1D6` | `#342812` | `#FCE4B3` | `#3A2A0B` |
| `danger-subtle` | Invalid token, error banner background | `#FDE7E8` | `#3B1C1F` | `#FAD3D5` | `#43161A` |
| `star` | Star glyph | `#C27C00` | `#FFC23D` | `#9A6200` | `#FFD36E` |
| `star-on-selected` | Star glyph on a selected row | `#FFD566` | `#FFD566` | `#FFE08A` | `#FFE08A` |
| `unread` | Unread dot | `#1F69E0` | `#4F94FF` | `#0F55C8` | `#80B2FF` |
| `rail-well` | Selected rail item well | `#FFFFFF` @ 10% | `#FFFFFF` @ 8% | `#FFFFFF` @ 20% | `#FFFFFF` @ 22% |
| `rail-well-hover` | Hovered rail item well | `#FFFFFF` @ 5% | `#FFFFFF` @ 4% | `#FFFFFF` @ 12% | `#FFFFFF` @ 14% |
| `rail-badge` | Rail unread badge fill | `#FFFFFF` | `#FFFFFF` | `#FFFFFF` | `#FFFFFF` |
| `rail-badge-text` | Rail unread badge numerals | `#2B3036` | `#0F1114` | `#000000` | `#000000` |
| `line-selected-inactive` | Inset keyline on inactive selection (increased contrast only) | clear | clear | `#555D67` | `#B6BDC5` |
| `kbd-bg` | Keyboard hint cap | `#FFFFFF` | `#2E3338` | `#FFFFFF` | `#000000` |
| `kbd-border` | Keyboard hint edge | `#16191D` @ 18% | `#FFFFFF` @ 14% | `#16191D` @ 60% | `#FFFFFF` @ 60% |
| `kbd-text` | Keyboard hint glyph | `#4A525B` | `#B0B7C0` | `#30363D` | `#D5DAE0` |

**Implementation from one source.** The token table lives in one JSON file (proposed `Sources/PaperCore/Design/wingbar-tokens.json`, no AppKit import so tests can read it). A Swift script in `scripts/tools/` (no Node) generates:
- `Sources/PaperApp/Design/Wingbar+Color.swift`: `NSColor(name: "wb.bg-list") { appearance in … }` with the four-way `bestMatch` switch; SwiftUI uses `Color(nsColor:)`.
- the `:root` block of `ConversationShellAssets.css`, replacing today’s `--ss-*` variables, with `@media (prefers-color-scheme: dark)`, `@media (prefers-contrast: more)` and the combined query — exactly the block embedded at the top of `specimen.html`.

### 4.2 Accent, selection and focus rules

- `fill-selected` is used for exactly two things: the selected conversation row in a key window and the highlighted item in app-drawn menus (autocomplete). Its text is `text-on-accent`; secondary text on it is `text-on-accent-2`.
- Selected row in a non-key window → `fill-selected-inactive`, normal text colors. The list keeps the emphasized (blue) style whenever the main window is key, even when the reader or quick reply is first responder, because `j`/`k` always drive the list (`KeyboardRouter`).
- `unread` (dot) and `text-accent` (unread time) both read ≥ 4.6:1 on every list surface.
- **Focus ring:** 2 pt `focus-ring`, drawn outside the control with a 1 pt gap in the surface color (`0 0 0 1px <surface>, 0 0 0 3px ring`). Rows and fields draw the ring inset (no gap). On slate use `focus-ring-on-slate`. AppKit: custom `drawFocusRingMask` is not used; draw the ring yourself in layer-backed controls so its color is the token, and set `focusRingType = .none` on those controls only.

### 4.3 Semantic status

| Status | Glyph (SF Symbol) | Glyph color | Text color | Banner bg |
|---|---|---|---|---|
| Success | `checkmark.circle.fill` | `success` | `text-success` | `success-subtle` |
| Warning / needs action | `exclamationmark.triangle.fill` or `exclamationmark.circle.fill` | `warning` | `text-warning` | `warning-subtle` |
| Error / destructive | `exclamationmark.triangle.fill` | `danger` | `text-danger` | `danger-subtle` |
| Info | `info.circle` / context glyph | `text-secondary` | `text-secondary` | `bg-field` |

Info is deliberately neutral: privacy banners and sync notes are not alarming and must not borrow blue (principle 3).

### 4.4 Account palette (10)

Each account gets a palette slot at creation, in order; the user can change it in Settings ▸ Accounts (popup of the 10 names). Two tones per color: **ink** for light surfaces (wingbar on the light list, account chip square, composer From square) and **glow** for dark surfaces (wingbar in dark mode, rail tiles in both appearances — the rail is always dark — and Settings avatars). Rail tiles show the account monogram (first letter of the account label; default label = mail domain, `gmail.com`/`outlook.com` → “Personal”) in `#0F1114` on the glow fill.

| # | Name | Ink (light surfaces) | Glow (dark surfaces, rail) | Ink on `bg-list` L | Glow on `bg-list` D | Glow on `bg-rail` L | Glow on `bg-rail` D | Monogram `#0F1114` on glow |
|---|---|---|---|---|---|---|---|---|
| 1 | Blue | `#2F8EF0` | `#2386E8` | 3.36 | 4.55 | 3.58 | 5.08 | 5.08 |
| 2 | Amber | `#AA7319` | `#F8A340` | 4.06 | 8.30 | 6.53 | 9.28 | 9.28 |
| 3 | Rose | `#821525` | `#DF4E68` | 10.08 | 4.37 | 3.44 | 4.89 | 4.89 |
| 4 | Teal | `#1C6555` | `#7DE5C0` | 6.90 | 11.15 | 8.77 | 12.46 | 12.46 |
| 5 | Violet | `#58199C` | `#D0BFF9` | 10.32 | 10.07 | 7.92 | 11.26 | 11.26 |
| 6 | Graphite | `#717A86` | `#858F96` | 4.35 | 5.13 | 4.03 | 5.73 | 5.73 |
| 7 | Green | `#508848` | `#7CCB5C` | 4.24 | 8.50 | 6.68 | 9.50 | 9.50 |
| 8 | Brown | `#705843` | `#EFC7B7` | 6.63 | 10.89 | 8.57 | 12.18 | 12.18 |
| 9 | Cyan | `#02628D` | `#27B2DF` | 6.70 | 6.86 | 5.40 | 7.67 | 7.67 |
| 10 | Plum | `#944184` | `#E391B9` | 6.27 | 7.26 | 5.71 | 8.12 | 8.12 |

**Color-vision check.** ΔE2000 between every pair, computed in CIELAB after simulating color-vision deficiency with the Machado–Oliveira–Fernandes (2009) matrices on linear sRGB. Minimum pair shown:

| Accounts in use | Tone | Normal vision | Full dichromacy (protan/deutan/tritan, severity 1.0) | Anomalous trichromacy (severity 0.6) |
|---|---|---|---|---|
| 1–2 | ink | 51.4 (Blue/Amber) | 51.4 (Blue/Amber, normal) | 44.5 (Blue/Amber, tritan) |
| 1–2 | glow | 54.2 (Blue/Amber) | 54.2 (Blue/Amber, normal) | 48.8 (Blue/Amber, tritan) |
| 1–3 | ink | 37.0 (Amber/Rose) | 21.8 (Amber/Rose, tritan) | 27.5 (Amber/Rose, deutan) |
| 1–3 | glow | 38.0 (Amber/Rose) | 16.9 (Amber/Rose, tritan) | 25.7 (Amber/Rose, tritan) |
| 1–4 | ink | 37.0 (Amber/Rose) | 14.8 (Rose/Teal, protan) | 25.9 (Amber/Teal, protan) |
| 1–4 | glow | 38.0 (Amber/Rose) | 16.9 (Amber/Rose, tritan) | 24.8 (Amber/Teal, protan) |
| 1–6 | ink | 19.0 (Blue/Graphite) | 14.7 (Teal/Graphite, deutan) | 17.5 (Teal/Graphite, protan) |
| 1–6 | glow | 18.3 (Blue/Graphite) | 14.6 (Rose/Graphite, protan) | 18.3 (Blue/Graphite, normal) |
| 1–8 | ink | 18.8 (Teal/Green) | 6.1 (Teal/Brown, protan) | 11.8 (Teal/Brown, protan) |
| 1–8 | glow | 17.4 (Teal/Green) | 3.8 (Teal/Brown, protan) | 11.8 (Amber/Green, protan) |
| 1–10 | ink | 17.6 (Graphite/Cyan) | 3.6 (Cyan/Plum, protan) | 11.8 (Teal/Brown, protan) |
| 1–10 | glow | 17.4 (Teal/Green) | 3.8 (Teal/Brown, protan) | 11.2 (Violet/Cyan, protan) |

The order is chosen so the realistic case (2–6 accounts) stays clearly separable even for full dichromats (≥ 14.6), and all ten stay ≥ 11 for anomalous trichromats (the common deficiencies, ≈ 6 % of men). Accounts 7–10 can collide for full protanopes, so identity is never color alone: rail tiles carry monograms and `⌘n` order, the reader header names the account in its chip, the row’s accessibility label ends with “, <account label>”, and hovering the wingbar shows the account label as a tooltip.

### 4.5 Avatar palette (8)

Initials avatars use a tint, not a saturated fill. Index = `fnv1a32(lowercased email) % 8`, stable across launches and devices. Initials: up to two letters (first + last word), SF Pro Rounded semibold at round(0.39 × d), +0.2 pt tracking. Contact photos (when available) replace the tint and keep the shape and the 0.5 pt inner hairline (`#10161E` @ 6 % light, `#FFFFFF` @ 6 % dark).

| # | Tint | Light bg | Light initials | Ratio | Dark bg | Dark initials | Ratio |
|---|---|---|---|---|---|---|---|
| 1 | Blue | `#E0EBFC` | `#1D4F9E` | 6.55 | `#1F3352` | `#A8C9FF` | 7.54 |
| 2 | Teal | `#D8F0EC` | `#0E5F57` | 6.30 | `#173B38` | `#8FDCD1` | 7.75 |
| 3 | Green | `#E1F1DE` | `#2B6526` | 5.96 | `#1F3920` | `#A2D99B` | 7.77 |
| 4 | Amber | `#FAEDCF` | `#774C00` | 6.42 | `#3B2F14` | `#F0CB7C` | 8.45 |
| 5 | Orange | `#FCE5D8` | `#8F3E0E` | 6.06 | `#41271A` | `#FFB68E` | 8.06 |
| 6 | Rose | `#FBE1E4` | `#9A2433` | 6.35 | `#422027` | `#FFA9B3` | 7.89 |
| 7 | Violet | `#ECE3FA` | `#5A3492` | 7.23 | `#32264A` | `#CDB4FF` | 7.65 |
| 8 | Slate | `#E4E8EC` | `#3E4650` | 7.76 | `#2E333A` | `#C3CAD3` | 7.70 |

### 4.6 Typography

macOS system families only: SF Pro (Text/Display optical sizes switch automatically), SF Pro Rounded, New York, SF Mono. CSS: `-apple-system, system-ui` / `ui-rounded` / `ui-serif` / `ui-monospace`. No bundled or web fonts.

| Role | Family (AppKit / CSS) | Size pt | Weight | Line height pt | Tracking override | Used for |
|---|---|---|---|---|---|---|
| `display` | SF Pro (Display) · `-apple-system, system-ui` | 28 | 700 | 34 | -0.6 pt | Welcome title, empty-state hero |
| `title-1` | SF Pro (Display) · `-apple-system, system-ui` | 20 | 600 | 25 | -0.2 pt | Reader subject |
| `title-2` | SF Pro · `-apple-system, system-ui` | 15 | 600 | 20 | — (system) | List title menu, composer subject, settings group titles |
| `headline` | SF Pro · `-apple-system, system-ui` | 13 | 600 | 17 | — (system) | Message-card sender, unread row sender, dialog titles |
| `body` | SF Pro · `-apple-system, system-ui` | 13 | 400 | 18 | — (system) | Default UI text, row subject, form rows |
| `body-medium` | SF Pro · `-apple-system, system-ui` | 13 | 500 | 18 | — (system) | Unread row subject, button labels, toasts |
| `reading` | SF Pro · `-apple-system, system-ui` | 14 | 400 | 21 | — (system) | Message bodies (fallback CSS), composer body, quick reply |
| `reading-serif` | New York · `ui-serif` | 15 | 400 | 23 | — (system) | Optional reading font (General > Reading font) |
| `callout` | SF Pro · `-apple-system, system-ui` | 12 | 400 | 16 | — (system) | Row snippet, recipients line, banners, chip names |
| `callout-medium` | SF Pro · `-apple-system, system-ui` | 12 | 500 | 16 | — (system) | Small buttons, segmented labels, tokens |
| `caption` | SF Pro · `-apple-system, system-ui` | 11 | 400 | 14 | — (system) | Row time (medium), sync line, sizes, helper text |
| `overline` | SF Pro · `-apple-system, system-ui` | 11 | 600 | 14 | +0.6 pt | Date dividers, uppercase section labels |
| `badge` | SF Pro Rounded · `ui-rounded` | 11 | 700 | 14 | — (system) | Count badges, rail badges (tabular numerals) |
| `monogram` | SF Pro Rounded · `ui-rounded` | 15 | 600 | 20 | — (system) | Rail account monograms; avatar initials scale with size |
| `kbd` | SF Mono · `ui-monospace` | 11 | 500 | 14 | — (system) | Keyboard hints |
| `mono` | SF Mono · `ui-monospace` | 12 | 400 | 18 | — (system) | Code in message bodies, OAuth client IDs |

Rules:
- **Tracking:** AppKit, SwiftUI and WebKit apply SF’s built-in size-specific tracking. Only the three overrides above are applied as kern (`NSAttributedString.Key.kern`, CSS `letter-spacing`).
- **Numerals:** times, counts, sizes and progress use tabular figures (`.monospacedDigit()`, `font-variant-numeric: tabular-nums`) so columns do not shimmer when values change.
- **State through weight:** unread sender 600 / read 400; unread subject 500 / read 400; unread time 600 + `text-accent` / read 500 + `text-tertiary`.
- **Truncation:** single-line tail truncation everywhere in the list; attachment names middle-truncate; subjects in the reader header tail-truncate with the full subject in the tooltip and VoiceOver label.
- **Reading font preference** (Settings ▸ General ▸ Reading font: SF Pro / New York) switches only `reading` → `reading-serif` in message bodies, quick reply and composer.
- **Replaces today’s eight ad-hoc sizes** (10, 11, 12, 13, 14, 15, 17, 26 across AppKit views and the reader CSS) with seven sizes (11, 12, 13, 14, 15, 20, 28) on 16 named roles; avatar initials are the only scaled exception (0.39 × d).

### 4.7 Spacing

4 pt grid with two optical steps (2, 6): `space-2 · 4 · 6 · 8 · 12 · 16 · 20 · 24 · 32 · 48`.

| Use | Value |
|---|---|
| Glyph ↔ label inside a control | 5–6 |
| Between inline controls (chips, tokens, pills) | 4 (tokens), 6 (pills), 8 (chips) |
| Row internal leading (text block top) | 10 |
| Pane horizontal inset | 16 (list), 24 (reader), 20 (Settings) |
| Card padding | 16 top · 20 sides · 12 bottom |
| Between deck and expanded card, between cards | 12 |
| Section gaps in forms | 14 |
| Empty-state stack | 14 / 4 / 14 |

### 4.8 Radii

| Token | pt | Used for |
|---|---|---|
| `radius-xs` | 3 | kbd caps, progress bar ends |
| `radius-sm` | 5 | buttons (small, regular), text fields, tokens, popup buttons, pills, menu items, account chip |
| `radius-md` | 8 | large buttons, attachment chips, banners, quick-reply field |
| `radius-lg` | 10 | message cards, deck, toasts, menus/popovers, Settings groups |
| `radius-xl` | 14 | undo-send panel, alerts drawn by the app; rail wells use 13 at 48 pt |
| `radius-pill` | ∞ | badges, search field (28 pt → 14), toggles |
| avatar | round(0.3 × d) | 16→5, 20→6, 24→7, 28→8, 32→10, 36→11, 40→12, 64→15 (welcome tile) |

AppKit: `layer.cornerCurve = .continuous` for avatars, rail wells, cards and the app tile; circular arcs for badges and pills.

### 4.9 Borders and hairlines

- **Hairline** = one device pixel: `1 / window.backingScaleFactor` pt (0.5 pt on Retina), color `line-hairline`. CSS `0.5px` (WebKit snaps to a device pixel). Used for row separators (from x 68 to the trailing edge, never under or above a selected row), card edges (as a 0.5 pt outer stroke, not a border that changes layout), header bottoms, composer field rows (from x 16).
- **Pane divider** list | reader: 1 pt `line-pane` (dark: darker than both panes — `#08090B` — so the split reads as a seam, not a highlight). Rail | list: no divider; the rail draws a 1 pt `line-rail-edge` inner highlight on its trailing edge.
- **Control outline**: 1 pt `line-control` (≥ 3:1) on checkbox, toggle-off track; in IC also on fields, segmented track and secondary buttons.
- **Focus**: 2 pt + 1 pt gap (§4.2). **Error**: 1.5 pt `danger` on fields.

### 4.10 Elevation

Three levels; shadows exist only on floating surfaces, never on rows, never on the rail, never animated in size.

| Token | Light | Dark | Light · IC | Dark · IC |
|---|---|---|---|---|
| `shadow-1` | `0 1px 2px rgba(16,22,30,0.06)` | `none` | `0 1px 2px rgba(16,22,30,0.10)` | `none` |
| `shadow-2` | `0 4px 14px rgba(16,22,30,0.12), 0 1px 3px rgba(16,22,30,0.08)` | `0 8px 24px rgba(0,0,0,0.50), 0 1px 3px rgba(0,0,0,0.40)` | `0 4px 14px rgba(16,22,30,0.16), 0 1px 3px rgba(16,22,30,0.12)` | `0 8px 24px rgba(0,0,0,0.60), 0 1px 3px rgba(0,0,0,0.50)` |
| `shadow-3` | `0 12px 32px rgba(16,22,30,0.22), 0 2px 8px rgba(16,22,30,0.12)` | `0 16px 40px rgba(0,0,0,0.60), 0 2px 8px rgba(0,0,0,0.45)` | `0 12px 32px rgba(16,22,30,0.26), 0 2px 8px rgba(16,22,30,0.16)` | `0 16px 40px rgba(0,0,0,0.70), 0 2px 8px rgba(0,0,0,0.55)` |
| `line-float` | `rgba(16,22,30,0.08)` | `rgba(255,255,255,0.10)` | `rgba(16,22,30,0.55)` | `rgba(255,255,255,0.55)` |
| `line-rail-edge` | `rgba(255,255,255,0.06)` | `rgba(255,255,255,0.05)` | `rgba(255,255,255,0.30)` | `rgba(255,255,255,0.35)` |

| Level | Surfaces | Recipe |
|---|---|---|
| e0 | list, rows, rail, headers | none |
| e1 | message deck and cards | 0.5 pt `line-hairline` outer stroke + `shadow-1` (light only) |
| e2 | menus, autocomplete, tooltips, popovers | `bg-raised` + 0.5 pt `line-float` + `shadow-2` |
| e3 | toasts, undo-send panel, app-drawn alerts | 0.5 pt `line-float` + `shadow-3` |

AppKit: a layer has one shadow, so e2/e3 use a container layer (key shadow) plus a sublayer (ambient shadow), both with an explicit `shadowPath`. Windows and sheets keep the system shadow.

### 4.11 Materials

| Region | Material | Reduced transparency | Why |
|---|---|---|---|
| Rail | none — opaque `bg-rail` | same | identity color must be exact; badges’ contrast must not depend on wallpaper |
| Reader header | `NSVisualEffectView` `.headerView`, `.withinWindow`, only while message content is scrolled beneath it; otherwise opaque `bg-list` | opaque `bg-list` | one large static region; signals “content continues” |
| List header | opaque `bg-list` | same | sits over the hot path; no blending during scroll |
| Toasts, undo send | opaque `bg-slate` | same | fixed contrast for the action text |
| Menus, tooltips, notifications, alerts | system | system | native |

No blur, vibrancy or translucency anywhere inside the list or on a per-row basis.

### 4.12 Motion

| Token | Duration | Curve (CSS / `CAMediaTimingFunction`) | Used for |
|---|---|---|---|
| `instant` | 0 | — | selection, row hover, list inserts/removals, unread/star changes, badges, focus rings, sync-line text |
| `fast` | 100 ms | `cubic-bezier(0.2, 0, 0, 1)` | button/pill fill changes, chevron rotation, toast replace cross-fade |
| `base` | 160 ms | `cubic-bezier(0.2, 0, 0, 1)` | card expand/collapse (height + body opacity), quoted text reveal, segmented thumb slide, quick-reply grow |
| `emphasized` | 220 ms | `cubic-bezier(0.05, 0.7, 0.1, 1)` | toast and undo-send enter (8 pt rise + fade), rail collapse/expand (width) |
| `exit` | 120 ms | `cubic-bezier(0.3, 0, 0.8, 0.15)` | toast/panel exit (fade + 4 pt drop), app-drawn menu fade |
| `countdown` | = undo window (default 5 s) | linear | undo-send ring, determinate progress |

**Never animates:** list selection, row content during scroll, archive/trash removal (the row disappears and the next row is selected in the same frame; the toast carries the feedback), badge numbers, avatar decode (initials, then photo swap with no fade), reader content swap between conversations (pre-rendered views swap instantly), window resizes.

**Interruptible:** all animations begin from the current presentation value; a new key press cancels any running card animation (`CATransaction` with `beginFromCurrentState`, CSS transitions re-targeted). Nothing blocks input while animating.

**Reduce motion:** movement (rise, drop, slide, height) is removed; toasts and panels fade in 100 ms and out 100 ms; card expand is instant; the segmented thumb jumps; the countdown ring is replaced by the numeric countdown (“4 s”) which still updates each second; indeterminate bars show a static 30 % segment with a text label.

### 4.13 Iconography

SF Symbols, monochrome rendering mode, except status glyphs (`.fill` variants in their semantic color, hierarchical allowed). Weights: **regular** in toolbars/headers/menus, **medium** inside text buttons, **semibold** in rows (small sizes need the weight to hold up).

| Context | Point size | Weight | Frame |
|---|---|---|---|
| Header / toolbar icon buttons | 16 | regular | 28 × 28 |
| Rail utilities (Add, Settings) | 16 | regular | 32 × 28 |
| Rail All Inboxes | 20 (custom `wb.unified`) | — | 48 well |
| Menu items, text-button glyphs | 14 | regular / medium | — |
| Row glyphs (star, paperclip) | 12 | semibold | 12 × 12 |
| Row pending | 11 (custom `wb.pending`) | 1.5 stroke | — |
| Sync line, help text | 11–12 | medium | — |

**Symbol per action**

| Action | Key | SF Symbol |
|---|---|---|
| Archive | `e` | `archivebox` |
| Trash / restore | `#` | `trash` / `arrow.uturn.backward` |
| Star / unstar | `s` | `star` / `star.fill` |
| Mark unread / read | `u` | `envelope.badge` / `envelope.open` |
| Reply / Reply all / Forward | `r` `a` `f` | `arrowshape.turn.up.left` / `arrowshape.turn.up.left.2` / `arrowshape.turn.up.right` |
| Compose | `c` | `square.and.pencil` |
| Undo | `z` | `arrow.uturn.backward` |
| Search | `/` | `magnifyingglass` |
| Next / previous | `j` `k` | `chevron.down` / `chevron.up` (menus only) |
| Attachment / attach | — | `paperclip` |
| Load images | — | `photo` |
| Original colors | — | `circle.lefthalf.filled` |
| Show quoted text | — | `ellipsis.rectangle` |
| Open in composer | `⌘⇧O` | `arrow.up.left.and.arrow.down.right` |
| Send (quick reply, icon form) | `⌘↩` | `arrow.up.circle.fill` |
| Formatting | — | `textformat` |
| Offline | — | `wifi.slash` |
| Sign in again | — | `person.crop.circle.badge.exclamationmark` |
| Sync | — | `arrow.triangle.2.circlepath` |
| Add account / Settings | `⌘,` | `plus` / `gearshape` |
| Hide accounts (minimal mode) | `⌃⌘S` | `sidebar.left` |
| Views (title menu) | `g i` `g s` `g t` `g d` `g #` `g a` | `tray` · `star` · `paperplane` · `doc.text` · `trash` · `archivebox` |
| Settings tabs | — | `person.crop.circle` · `key` · `gearshape` |

**Custom glyphs (3 of the 6 allowed).** Fill rule non-zero unless stated. SVG coordinates are y-down; for `NSBezierPath` draw in a flipped view or apply `AffineTransform(scaleByX: s, byY: -s)` then translate by the view height. All three are designed on a whole-pixel grid at their primary size.

1. **`wb.wing`** — brand mark (welcome tile, empty “caught up” state, app icon, notifications). viewBox `0 0 16 16`, fill:
   ```
   M1.25 13.25C2.6 8 6.9 3.6 14.75 2.75C14.2 4.6 13 6 11.4 6.9H13.6C12.4 8.9 10.4 10.1 8.1 10.6H9.9C7.9 12.9 4.9 13.9 1.25 13.25Z
   ```
2. **`wb.unified`** — All Inboxes in the rail: four rail tiles. viewBox `0 0 16 16`, fill (four 5.75 pt squares, r 1.75):
   ```
   M3.25 1.5h2.25a1.75 1.75 0 0 1 1.75 1.75v2.25a1.75 1.75 0 0 1-1.75 1.75H3.25A1.75 1.75 0 0 1 1.5 5.5V3.25A1.75 1.75 0 0 1 3.25 1.5Z
   M10.5 1.5h2.25a1.75 1.75 0 0 1 1.75 1.75v2.25a1.75 1.75 0 0 1-1.75 1.75H10.5A1.75 1.75 0 0 1 8.75 5.5V3.25A1.75 1.75 0 0 1 10.5 1.5Z
   M3.25 8.75h2.25a1.75 1.75 0 0 1 1.75 1.75v2.25a1.75 1.75 0 0 1-1.75 1.75H3.25a1.75 1.75 0 0 1-1.75-1.75V10.5a1.75 1.75 0 0 1 1.75-1.75Z
   M10.5 8.75h2.25a1.75 1.75 0 0 1 1.75 1.75v2.25a1.75 1.75 0 0 1-1.75 1.75H10.5a1.75 1.75 0 0 1-1.75-1.75V10.5a1.75 1.75 0 0 1 1.75-1.75Z
   ```
3. **`wb.pending`** — “applied here, on its way to the server” (row, before the time). viewBox `0 0 12 12`; stroke 1.5, round cap, no fill, plus one filled dot:
   ```
   stroke: M10.25 6A4.25 4.25 0 1 1 6 1.75
   fill:   circle cx 9.1 cy 2.9 r 1.05
   ```
   NSBezierPath: `appendArc(withCenter: (6,6), radius: 4.25, startAngle: 0, endAngle: 90, clockwise: true)` in flipped coordinates, `lineWidth 1.5`, `.round` cap; dot `NSBezierPath(ovalIn: NSRect(x: 8.05, y: 1.85, width: 2.1, height: 2.1))`.

Three slots stay free for later needs; do not spend them on glyphs SF Symbols already covers.

### 4.14 Density

| Mode | Row | Avatar | Lines | Other |
|---|---|---|---|---|
| Standard (default) | 68 pt | 36 pt r 11 at x 20 | sender · subject · snippet | text x 68 |
| Compact | 52 pt | 28 pt r 8 at x 22 | sender · subject (no snippet) | text x 62; dot at y 13 |
| Minimal mode (independent) | — | — | — | rail width 0 (`⌃⌘S`); list header insets 78 pt from the leading edge so the traffic lights sit over it; the title menu gains an “Accounts” section; `⌘0`–`⌘9` keep working; the wingbar stays |

The reader never changes density (reading 14/21 in a 760 pt column). Rail targets stay 48 pt.

### 4.15 Voice and microcopy

- Sentence case everywhere except the two-letter overline labels (uppercase via the `overline` role, not typed in caps).
- Verb first, past tense for done things: “Archived”, “Moved to Trash”, “Marked unread”. Action follows a middle dot: “Archived · Undo”.
- Errors: what happened, then what to do, no codes, no blame, no “please”, no “Oops”: “Can’t sync maya@fabrikam.com · Retry”, “Sign in again to alex@contoso.com”, “Offline · changes will sync later”, “Couldn’t send to Ben Carter · Saved to Drafts”.
- Ellipsis “…” only for work in progress (“Checking for mail…”) or a command that asks for more (“Remove…”, “Add Gmail Account…”).
- Confirmations name the object: “Remove alex@contoso.com?” with “Mail from this account will be deleted from this Mac. Nothing changes on the server.”
- Times: today “10:42” (24 h or 12 h per locale), yesterday in the Yesterday section “18:20”, this week “Mon”, this year “30 Oct”, older “30 Oct 2025”. Counts use locale grouping (12,480). No exclamation marks, no emoji.
- Privacy is stated plainly once, where it matters: welcome footer, remote-images banner, notification-preview setting.

### 4.16 Accessibility summary

- Every text pair ≥ 4.5:1 and every essential non-text pair ≥ 3:1 in all four appearances (computed table, §6). The only sub-3:1 state indicator is the inactive-window selection fill in standard contrast (1.26 L / 1.33 D), which matches the platform’s unemphasized selection, appears only when the window cannot take input, and is always paired with the conversation open in the reader; with Increase Contrast on it gains a 2 pt inset keyline at 4.69 / 5.44:1.
- **Non-color cues:** unread = dot + weight (+ blue time); selected = fill + reader content (+ VoiceOver “selected”); starred = filled star glyph; pending = `wb.pending` glyph (no fading — the old 0.6 alpha fade is removed because it broke contrast); Other category = “Other” tag text; invalid address = glyph + wavy underline + VoiceOver “invalid address”; errors = glyph + words; toggles = knob position; focused = ring; account = monogram, chip text, tooltip, label.
- **Keyboard:** every command has a menu item and key equivalent; single-key shortcuts are suspended while a text field is first responder; `esc` leaves a field and returns focus to the list; Tab order: rail → list header controls → list → reader actions → message cards (`n`/`p` move focus between cards when the reader is focused) → quick reply. Full keyboard access draws the 2 pt ring on every focusable control.
- **VoiceOver:** row label = “Unread. Starred. Ben Carter, Alex Morgan, Tom Hughes. Contoso rollout: go-live checklist. Tested with three accounts… 10:42. 4 messages. Has attachments. Work.”; pending appends “Waiting to sync”. Toasts post `.announcementRequested` with the toast text.
- Hit targets ≥ 24 pt (icon buttons 28, small icon buttons 24, rail items 48).

---

## 5. Components

Each component lists anatomy, metrics and states. Unlisted states do not exist for that component (e.g. rows have no disabled state). “Hover” is pointer-only feedback and never required to discover a function.

### 5.1 App window and title band

- **Default** 1280 × 800, minimum 840 × 560. Columns: rail 72 · list 372 (320–480, user-resizable, autosaved) · 1 pt pane divider · reader (min 440).
- **Title band** 52 pt across the window, draggable everywhere except controls. Traffic lights (system buttons, repositioned in `layout()` via `standardWindowButton(_:)?.setFrameOrigin`) centered as a group on the rail center line x = 36 and on y = 26.
- **Horizon:** list header and reader header both 88 pt, both `bg-list`; their bottom hairlines are at the same y.
- **States:** key window (blue selection, colored traffic lights) · non-key (traffic lights grey, selection → inactive fill, rail and headers unchanged) · full screen (rail starts at y 0; title band keeps 52 so content does not jump) · minimal mode (rail hidden, list header leading inset 78).

### 5.2 Account rail and items

- **Rail:** 72 pt, `bg-rail`, trailing 1 pt `line-rail-edge`. Content from top: title band (traffic lights) → All Inboxes item at y 60 → 20 × 1 `line-rail` separator at y 116 (x 26) → accounts from y 124, pitch 52 → flexible space → Add (y = height − 84) → Settings (y = height − 48).
- **Item:** 48 × 48 well, r 13, at x 12. Content: All Inboxes = `wb.unified` 20 pt `text-on-slate`; account = 36 pt tile r 11, glow fill, monogram `monogram` role in `#0F1114`, 0.5 pt inner stroke `#000` @ 12 %.
- **Badge:** top −1, right −4 relative to the well (it overhangs the well, never the monogram); 16 pt high, min width 18, padding 0 5, `rail-badge` fill, `rail-badge-text` numerals (`badge` role), 2 pt ring in the surface color under it (cut-out). “99+” above 99. All Inboxes shows the unified unread count.
- **Utilities:** 32 × 28, r 7, glyph 16 pt `text-on-slate-2`.

| State | Treatment |
|---|---|
| Rest | no well |
| Hover | well `rail-well-hover`; tooltip “Work — alex@contoso.com  ⌘1” after 0.6 s |
| Pressed | well `rail-well`; tile scales to 0.94 for the press only (no spring) |
| Selected | well `rail-well` + perch 3 × 20 at x 0, y 14 of the well, `text-on-slate`, right corners r 2 |
| Focused (keyboard) | 2 pt `focus-ring-on-slate` around the well, no gap |
| Needs sign-in | tile desaturated (saturation 35 %, brightness 80 %); badge replaced by a 16 pt `warning` disc with `exclamationmark` in `#1C1F23`; tooltip “Sign in again to …” |
| First sync | 1.5 pt `text-on-slate` arc (30 % of the perimeter) circling the well’s inner squircle; static under reduced motion |
| Drag to reorder | tile lifts with e2 shadow; others shift instantly (no animation) |
| Disabled | not used |

### 5.3 List header

- 88 pt, `bg-list`, bottom hairline. **Row 1** (title band, 0–52): title menu at x 10 (button 26 high, padding 0 6, r 5) centered on y 26 · segmented filter right-aligned at 46 from the edge (Inbox only) · compose icon button 28 × 28 at 10 from the edge. **Row 2**: search field x 16 → −16, y 54, 28 high.
- In minimal mode the title menu moves to x 88.
- During a `g` sequence a kbd chip “G” appears right of the title for 1.5 s (or until the next key).

### 5.4 Title menu

- Button: `title-2` label + `chevron.down` 11 pt `text-secondary`, gap 5. States: rest · hover `bg-hover` · pressed/open `bg-pressed` · focused ring (inset) · disabled not used.
- Menu: a standard `NSMenu` (system material) with items Inbox · Starred · Sent · Drafts · Trash · All Mail, each with its SF Symbol, a checkmark on the current view, the unread count for Inbox as a trailing badge and the `g` sequence shown right-aligned (“G I”) via an attributed title with a right tab stop (NSMenu cannot show multi-key equivalents natively). `⌘1…⌘9` stay reserved for accounts. In minimal mode an “Accounts” section follows with the same items as the rail.

### 5.5 Segmented filter (All · Focused · Other)

- Track 24 pt, padding 2, r 6, `fill-subtle`. Segments 20 pt, padding 0 9, r 4, `callout-medium`, `text-secondary`. Selected thumb `bg-raised` (dark `#474D55`), 0.5 pt `line-float`, `0 1px 2px rgba(16,22,30,.10)` (light only), label 600 `text-primary`. 1 × 10 hairline dividers between unselected neighbours.
- States: rest · hover (label `text-primary`) · pressed (thumb `bg-pressed`) · selected · focused (2 pt ring around the focused segment) · disabled (`text-disabled`, track unchanged).
- Shown only for Inbox; other views hide it (no placeholder space). Thumb slides `base` 160 ms; reduce motion: jump.

### 5.6 Search field

- 28 pt pill (r 14), `bg-field`, padding 0 6 0 10. `magnifyingglass` 13 pt `text-tertiary`, gap 6, `body` text, placeholder “Search” (`text-tertiary`), trailing kbd “/”.
- States: rest · hover (no change) · focused (`bg-raised` + 2 pt ring, placeholder “Search all accounts” in unified) · filled (query `text-primary`, trailing result count `caption` `text-tertiary` “14 results”, clear button 16 pt `text-tertiary` disc with an 8 pt `xmark`) · no results (count reads “No results”) · searching (count replaced by a 12 pt spinner only if results take > 150 ms) · disabled not used.
- `esc` clears, second `esc` returns focus to the list.

### 5.7 Conversation row

Anatomy and metrics (Standard density, 68 pt; flipped coordinates from the row’s top-left):

| Part | Frame / spec |
|---|---|
| Wingbar | x 0, full height, 3 pt wide, account ink (L) / glow (D). Only in All Inboxes with ≥ 2 accounts. |
| Unread dot | 8 pt circle at x 7, y 14 (centered on the sender line), `unread` |
| Avatar | 36 pt at x 20, y 16, r 11 |
| Line 1 | y 10, h 16: sender (`body`, 600 if unread; additional participants after the first in `text-secondary`) · optional `wb.pending` 11 pt · time (`caption` 11/16, 500, tabular) right-aligned at trailing 14 |
| Line 2 | y 28, h 16: subject (`body`, 500 if unread) · trailing cluster, right to left in fixed order: star (12 pt `star.fill`, `star`) · paperclip (12 pt, `text-tertiary`) · message count badge (≥ 2 messages; 16 pt pill, `fill-subtle`, `text-secondary`, `badge` role) · “Other” tag (16 pt, r 4, 1 pt inset `line-hairline`, `caption` 11/16 500, `text-tertiary`; only in the All filter for Other-category mail). Cluster gap 5, subject ends 6 pt before the cluster. |
| Line 3 | y 45, h 15: snippet (`callout` 12/15, `text-secondary`), full width to trailing 14 |
| Separator | 0.5 pt `line-hairline` from x 68 to the trailing edge at the bottom; hidden on the selected row and on the row above it |

| State | Treatment |
|---|---|
| Read | as above, sender 400, time `text-tertiary` |
| Unread | dot + sender 600 + subject 500 + time 600 `text-accent` |
| Hover | background `bg-hover` (pointer only; instant) |
| Selected · key window | full-bleed `fill-selected`; all text `text-on-accent`, snippet/time/extra participants `text-on-accent-2`; dot white; count badge `#FFFFFF` @ 22 % with white numerals; star `star-on-selected`; glyphs white @ 92 %; Other tag outline white @ 55 %; wingbar keeps its color with a 1 pt white keyline on its trailing side |
| Selected · inactive window | `fill-selected-inactive`, normal colors; IC adds a 2 pt inset `line-selected-inactive` keyline |
| Keyboard focus, no selection | 2 pt inset `focus-ring` (list is first responder with an empty selection) |
| Starred / attachment / count | glyphs and badge per anatomy; no row tint |
| Pending (operation queued, not confirmed) | `wb.pending` before the time; text stays full contrast (the old 0.6 alpha fade is removed) |
| Other category | “Other” tag in the All filter; nothing in Focused/Other filters |
| Compact density | 52 pt, avatar 28 at x 22 y 12, text x 62, lines at y 9 and 27, no snippet |
| Dragging | system drag image of the row; row itself unchanged |

Performance contract: fixed height per density, manual layout, cached attributed strings (`RowContentCache`), the wingbar/dot/badge drawn in `draw(_:)`, opaque layer background (`layer.isOpaque = true` with the row color), no shadows, no blur, no animations, selection color change inside `CATransaction.setDisableActions(true)`.

### 5.8 Date dividers

- 24 pt group rows (fixed height), sticky (`NSTableView.floatsGroupRows`), opaque `bg-list`, label at x 68 (aligned with row text), baseline-centered at y 8–22, `overline` role, `text-tertiary`. Bottom hairline only while floating.
- Buckets: Today · Yesterday · Earlier this week · Last week · Month name (“October”) · Year (“2025”). Not shown in search results (results are ranked) or when a view has fewer than 8 conversations.
- No wingbar, no hover, no selection.

### 5.9 Empty states

- Centered in the pane, optical center raised 40 pt. Stack: tile 56 pt r 16 `fill-subtle` with a 26 pt glyph `text-secondary` → 14 → title (`title-2`, `text-primary`) → 4 → line (`callout`, `text-tertiary`, max 240 pt) → 14 → optional action (small secondary button) or kbd hint.
- Variants: **Inbox zero** (`wb.wing`, “You’re all caught up”, “Nothing new in Inbox.”, hint “C to write a message”) · **Empty view** (view glyph, “No starred conversations”, “Press S on a conversation to star it.”) · **No search results** (`magnifyingglass`, “No results for “ssso””, “Check the spelling, or search every view.”, button “Search All Mail”) · **Reader, nothing selected** (on `bg-reader`; tile `bg-card` with hairline; `envelope`; “No conversation selected”; hint “J K to move · ↩ to open”) · **No accounts** (welcome screen, §5.37).

### 5.10 Skeleton and loading

- Only on first launch while the first page bootstraps (launch otherwise paints real rows from the store). Static skeleton rows: avatar block 36 r 11, three bars (10, 10, 9 pt high; widths 120/190/240 and 90/150/210 alternating; r 4) in `fill-subtle`, the third at 70 % opacity. **No shimmer** (no per-row animation); after 1 s without rows the sync line shows “Downloading mail…”.
- Reader loading a body not yet cached: the card shows its header immediately and a 3-line skeleton body; never a full-pane spinner.

### 5.11 Sync status line

- 24 pt at the bottom of the list, top hairline, `bg-list`, padding 0 12 0 16, `caption` `text-tertiary`, glyph 11 pt, gap 6. Always present so the list never jumps.

| State | Glyph | Text | Trailing |
|---|---|---|---|
| Up to date | `checkmark` `text-tertiary` | “Up to date · 10:42” | — |
| Checking | 11 pt spinner | “Checking for mail…” | — |
| Downloading | — | “Downloading mail · 12,480 messages” | 64 pt progress bar |
| Offline | `wifi.slash` `text-secondary` | “Offline · changes will sync later” (`text-secondary`) | — |
| Error | `exclamationmark.triangle.fill` `danger` | “Can’t sync maya@fabrikam.com” | text button “Retry” (`text-accent` 600) |
| Sign in again | `exclamationmark.circle.fill` `warning` | “Sign in again to alex@contoso.com” | text button “Reconnect” |

Hover over the text shows the detail (`SyncStatusSummary.detail`) as a tooltip; clicking the text opens Settings ▸ Accounts on that account.

### 5.12 Reader header and action buttons

- 88 pt, `bg-list`, bottom hairline (shown only when content is scrolled under; material per §4.11). Subject `title-1` at x 24, centered on y 26, trailing 170, tail truncation. Actions at trailing 14, y 12: star · archive · trash · 1 × 16 hairline divider (4 pt margins) · more (`ellipsis`). Icon buttons 28 × 28, r 6, glyph 16 pt `text-secondary`, gap 2.
- Meta row at y 58: account chip (20 pt, r 5, `fill-subtle`, 10 pt account square r 3 in ink/glow, `caption` 500 `text-secondary`: “Work · alex@contoso.com”) · gap 10 · `caption` `text-tertiary` “4 messages · Ben Carter, Alex Morgan, Tom Hughes”.
- Action button states: rest · hover (`bg-hover`, glyph `text-primary`, tooltip “Archive  E”) · pressed (`bg-pressed`) · focused (2 pt ring) · on (star: `star.fill` in `star`) · disabled (`text-disabled`; e.g. Trash in Trash view shows “Restore” instead).
- With no conversation the header keeps its height and shows nothing (empty state below).

### 5.13 Message deck and cards

- Column max 760 pt, centered, 24 pt side insets, 16 pt top. Canvas `bg-reader`.
- **Deck:** consecutive collapsed messages form one e1 card (r 10). Collapsed row 48 pt: padding 0 16 0 14; avatar 28 r 8; gap 10; name (`body` 500, fixed 128 pt column, tail truncation); snippet (`body`, `text-secondary`, flex); date (`caption` 500 `text-tertiary`, tabular). Rows separated by hairlines.
- **Expanded card:** 12 pt below the deck (and 12 between expanded cards), e1, r 10, padding 16 20 12. Header (§5.14) → optional remote-images banner (14 above) → tools row (12 above: quoted text toggle, original colors) → body (`reading` 14/21 fallback CSS; the email’s own HTML in a sandboxed iframe) → attachments (14 above) → footer (16 above, hairline top, 8 pt padding): ghost buttons Reply · Reply all · Forward, each with a 14 pt glyph and a kbd hint (R, A, F).

| State | Treatment |
|---|---|
| Collapsed read | as above |
| Collapsed unread | 7 pt `unread` dot before the name, name 600 |
| Collapsed hover | row `bg-hover`; click expands |
| Expanded | as above; newest message expanded by default, plus every unread message |
| Focused (keyboard, `n`/`p` inside the reader) | 2 pt `focus-ring` around the card or deck row, no gap, r 10 |
| Loading body | header + 3-line skeleton |
| Body pending (sending/queued) | body at full contrast with `wb.pending` + “Sending…” caption in the header instead of the date |

Expand/collapse: `base` 160 ms height + body fade; reduce motion: instant.

### 5.14 Message header

- Avatar 36 r 11 · gap 12 · who block: name `headline`; on hover the address appears inline after the name (`body` 400 `text-tertiary`, 4 pt gap); second line `callout` `text-secondary` “to me · cc Tom Hughes” (click toggles a full recipients list in `callout`). Trailing: date `caption` 500 `text-tertiary` (“10:42”, full date in tooltip) + 24 pt star icon button.
- States: rest · hover (address visible) · starred (star `star.fill`) · focused (card ring) · unread (dot before name).

### 5.15 Quoted-text toggle

- Pill 22 pt, r 5, padding 0 8 0 7, `fill-subtle`, `callout-medium` `text-secondary`, glyph `ellipsis.rectangle` 13 pt, gap 5. Labels “Show quoted text” / “Hide quoted text”.
- States: rest · hover (`fill-strong`, `text-primary`) · pressed (`fill-strong`, glyph `text-primary`) · on/shown (`accent-subtle`, `text-accent`) · focused (2 pt ring, 1 pt gap) · disabled not used.
- Revealed quotes: 2 pt `fill-strong` leading bar, 12 pt indent, `callout` 12/18 `text-secondary`; reveal is `base`.
- Composer variant: “Show quoted original” in the composer body.

### 5.16 Remote-images banner

- Inside the card under the header: min 36 pt, r 8, `bg-field`, padding 4 4 4 10, `photo` 14 pt `text-secondary`, `callout` `text-secondary` “Remote images are blocked to protect your privacy.” (narrow cards: “3 remote images blocked.”), trailing small secondary button “Load images (3)”.
- States: blocked (as above) · loading (button shows a 12 pt spinner + “Loading…”) · loaded (banner turns `accent-subtle`, `checkmark.circle.fill` `text-accent`, “Images loaded.”, ghost button “Always for this sender”; disappears on the next open) · none (no banner when the count is 0 or the preference loads images).

### 5.17 Original colors toggle

- Dark appearance only, only for bodies that carry their own colors. Pill as §5.15 with `circle.lefthalf.filled` 12 pt, label “Original colors”. Off: body rendered with `color-scheme: light dark` adaptation. On (`accent-subtle`, `text-accent`): body iframe gets `.ss-original` (sender’s light colors on a light card inset with r 8). States: rest · hover · on · focused.

### 5.18 Attachment chip

- 40 pt (36 in composer), r 8, `bg-field`, padding 0 12 0 6, max width 260. Type tile 28 r 6 `bg-card` + hairline, 14 pt glyph tinted by type: PDF `text-danger` `doc`, image `text-accent` `photo`, other `text-success`/`text-secondary` `doc.text`. Name `callout-medium` 12/15 (middle truncation), size `caption` `text-tertiary`.
- States: rest · hover (`fill-subtle` + hairline; tooltip with full name) · pressed (`fill-strong`) · focused (2 pt ring) · downloading (tile shows a 14 pt spinner; size reads “61 of 140 MB”) · error (tile `exclamationmark.triangle.fill` `text-danger`; size line “Couldn’t download · Retry” in `text-danger`) · composer variant adds an 18 pt remove button (`xmark` 11 pt, `text-tertiary`, hover `bg-hover`).
- Space opens Quick Look; ↩ opens with the default app; drag out to Finder.

### 5.19 Quick reply bar

- Docked at the reader bottom, `bg-list`, top hairline, padding 8 24 (the field aligns with the 760 pt card column). Collapsed 52 pt: field 36 pt, r 8, `bg-field`, padding 0 8 0 12, `arrowshape.turn.up.left` 14 pt `text-tertiary`, placeholder `reading` “Reply to Ben Carter…”, trailing kbd “R”.
- Expanded (focused with text): grows 112–280 pt, `bg-raised` + 2 pt ring; text `reading`; bottom bar inside the field: `caption` `text-tertiary` mode label (“Reply all · Work”), open-in-composer icon button (24 pt, `arrow.up.left.and.arrow.down.right`), small primary “Send ⌘↩”.
- States: collapsed · focused empty (ring, kbd hint becomes “esc”) · typing/expanded · sending (text `text-secondary`, “Sending in 4 s” caption, small secondary “Undo ⌘Z”) · error (help line `text-danger` “Couldn’t send · Saved to Drafts”) · disabled (no conversation: hidden).
- Grow is `base`; reduce motion: instant.

### 5.20 Composer window and fields

- Window 640 × 560 default (specimen 620 × 560), min 480 × 360; standard title bar (38 pt) with the subject as title (`headline` 600 `text-secondary`); `bg-card`.
- **Field rows:** label column 64 pt, right-aligned `body` `text-tertiary`; values start at x 72 (one text axis for every field and the body). Rows 36 pt (Subject 44 pt in `title-2`). 0.5 pt hairline under each row from x 16.
  - From: popup without chrome: 10 pt account square r 3 (ink/glow) · name `body` `text-primary` · address `text-tertiary` · `chevron.up.chevron.down` 12 pt. Changing From also changes the signature.
  - To / Cc / Bcc: token fields (§5.21). Cc and Bcc are hidden until used; small neutral text buttons “Cc” “Bcc” sit at the trailing end of the To row.
  - Subject: plain field, `title-2`.
- **Body:** padding 16 24 0 72, `reading` (or `reading-serif`), formatting via `⌘B/⌘I/⌘U/⌘K`, lists, quote. Quoted original folded behind the “Show quoted original” pill.
- **Attachment strip** (§5.22) and **bottom bar** 52 pt: Send (§5.23) · attach icon button (`paperclip`) · formatting icon button (`textformat`, opens a small popover with B I U link list quote) · spacer · draft status `caption` `text-tertiary` (“Draft saved”, “Saving…”) · discard icon button (`trash`, confirms if the draft has content).
- States: editing · dragging files over (whole body gets a 2 pt dashed `focus-ring` inset 8, r 10, and “Drop to attach” `callout` centered) · sending (window closes on Send; the undo panel takes over) · send failed (window reopens with an error banner under the fields: `danger-subtle`, glyph + text).

### 5.21 Address token and autocomplete

- Token 20 pt, r 5, padding 0 7, `accent-subtle`, `callout-medium` `text-accent`, gap 4 between tokens, wraps to new lines inside the row (row grows by 24 pt per line).
- States: rest · hover (`accent-subtle` mixed 20 % toward `text-accent`, trailing `chevron.down` 11 pt → menu Copy Address · Edit · Remove · New Message) · selected (`fill-accent`, white text; Backspace removes) · invalid (`danger-subtle`, `text-danger`, leading `exclamationmark.circle.fill` 12 pt, wavy underline on the address, VoiceOver “invalid address”) · focused field (caret `text-accent` 1.5 pt) · dragging (token lifts with e2).
- Autocomplete: e2 menu, width ≥ 320, rows 40 pt: 24 pt avatar r 7 · name `body` with the typed prefix in 600 · address `caption` `text-tertiary` · highlighted row `fill-selected` with white text and a trailing kbd “↩” on-accent. Max 6 rows; ↑/↓ move, ↩/Tab accept, esc closes.

### 5.22 Attachment strip

- Above the bottom bar, top hairline, padding 10 16 10 72 (on the text axis), chips 36 pt (§5.18 composer variant), gap 8, horizontal scroll when it overflows (no wrap).
- States: hidden when empty · adding (chip with spinner while the file is read/hashed) · error (chip error variant with the reason: “Over 25 MB”, “Can’t read file”) · focused chip (ring; Delete removes).

### 5.23 Send button

- Primary regular button: “Send” + on-accent kbd “⌘↩” (kbd: 18 pt, `#FFFFFF` @ 18 %, white glyph, no border).
- States: rest · hover · pressed · focused · disabled (no recipients: `fill-subtle` + `text-disabled`, tooltip “Add a recipient”) · invalid recipients (enabled; clicking shows an alert listing invalid addresses) · sending (not shown — the window closes and the undo-send panel appears).

### 5.24 Buttons

| Variant | Fill | Label | Hover | Pressed | Focused | Disabled | Loading |
|---|---|---|---|---|---|---|---|
| Primary | `fill-accent` | `text-on-accent` | `fill-accent-hover` | `fill-accent-pressed` | ring 2 pt + 1 pt gap | `fill-subtle` + `text-disabled` | 12 pt white spinner + “Sending…”, keeps width |
| Secondary | `fill-subtle` | `text-primary` | `fill-strong` | `fill-strong` mixed 30 % toward `text-tertiary` | ring | `fill-subtle` + `text-disabled` | spinner + “Loading…” |
| Ghost (tertiary) | none, padding 0 8 | `text-accent` (+ glyph) | `bg-hover` | `bg-pressed` | ring | `text-disabled` | spinner replaces glyph |
| Neutral ghost | none | `text-secondary` | `bg-hover` | `bg-pressed` | ring | `text-disabled` | — |
| Destructive | `danger` | white | `danger` 88 % + black | `danger` 76 % + black | ring | `fill-subtle` + `text-disabled` | spinner |
| Destructive ghost | none | `text-danger` | `danger-subtle` | `danger-subtle` | ring | `text-disabled` | — |
| Icon | none, 28 × 28 r 6 (small 24 × 24 r 5) | glyph 16 `text-secondary` | `bg-hover`, glyph `text-primary` | `bg-pressed` | ring (no gap) | `text-disabled` | 16 pt spinner |

Sizes: **small** 22 pt, `callout-medium` 12, padding 0 8, glyph 12–13, r 5 · **regular** 28 pt, `body-medium` 13, padding 0 12, glyph 14, r 5 · **large** 32 pt, `body-medium` 13, padding 0 16, glyph 14, r 8 (welcome, alerts). Pressed never scales text buttons. One primary per surface. Default button (↩) is the primary; destructive actions are never the default.

### 5.25 Text field

- 28 pt (24 in Settings rows), r 5, `bg-field`, padding 0 8, `body`; placeholder `text-tertiary`; IC adds a 1 pt `line-control` outline.
- States: rest · hover (no change) · focused (`bg-raised` + 2 pt ring, no gap) · filled · error (`bg-raised` + 1.5 pt `danger`; help line below: 12 pt `exclamationmark.circle.fill` + `caption` `text-danger`, 5 pt above) · disabled (`text-disabled`, 70 % opacity) · read-only (no fill, selectable).
- Secrets (`SecureField`) show bullets with 2 pt tracking.

### 5.26 Checkbox and toggle

- **Checkbox** 14 pt, r 4. Off: `bg-list` + 1 pt inset `line-control`. On: `fill-accent` + 10 pt white `checkmark` (2.4 stroke). Mixed: `fill-accent` + white `minus`. Focused: ring 2 pt + 1 pt gap. Disabled: 40 % opacity. Label `body`, 8 pt gap.
- **Toggle** 30 × 18, r 9; knob 14 pt white, `0 1px 2px rgba(0,0,0,.25)`. Off: `fill-strong` track + 1 pt inset `line-control` (≥ 3:1); knob left. On: `fill-accent`, knob right. Focused: ring. Disabled: 40 %. Knob slides `fast` 100 ms; reduce motion: jump. In SwiftUI Settings use `Toggle` with `.toggleStyle(.switch)` and `.tint(Wingbar.Color.fillAccent)`.

### 5.27 Popup button

- 24 pt (Settings) / 28 pt (toolbar contexts), r 5, `fill-subtle`, padding 0 6 0 9, `body` `text-primary`, trailing `chevron.up.chevron.down` 12 pt `text-secondary`, gap 8. Menu is a standard `NSMenu` with a checkmark on the current value.
- States: rest · hover (`fill-strong`) · pressed/open (`fill-strong`) · focused (ring + gap) · disabled (`text-disabled` label and chevron). Composer From uses the chrome-less variant (no fill).

### 5.28 Badges

| Badge | Spec |
|---|---|
| Count (neutral) | 16 pt pill, min width 18 (20 in rows), padding 0 5, `fill-subtle`, `text-secondary`, `badge` role (SF Pro Rounded 11 Bold, tabular) |
| Count (unread, accent) | same, `fill-accent`, white — title menu Inbox count |
| Rail | white pill, slate numerals, 2 pt cut-out ring (§5.2) |
| On selection | `#FFFFFF` @ 22 %, white numerals |
| Dot | 8 pt `unread` (7 pt inside message cards) |
| Dock | system red badge with the unified unread count (system-drawn) |

Counts above 99 read “99+” (rail, title menu) or the exact number (rows: message counts are small).

### 5.29 Avatar

- Sizes 16 · 20 · 24 · 28 · 32 · 36 · 40 · 64 with radius round(0.3 × d). Uses: 16 menus, 20 token menus, 24 autocomplete, 28 deck rows and compact rows, 32 Settings, 36 rows and expanded headers, 40 large, 64 welcome tile.
- Initials avatar (§4.5) · photo avatar (same shape, 0.5 pt inner hairline) · account avatar (glow fill + monogram, used in rail and Settings) · avatar with account ring (2 pt surface gap + 2 pt account ink/glow ring; used in the From popup menu and Settings when showing the user’s own identity per account).
- Decoding happens off the main thread; initials paint first and are replaced by a photo without animation.

### 5.30 Toast with action

- Bottom-center of the list pane, 12 pt above the sync line; height 36, r 10, `bg-slate`, padding 0 6 0 14, e3. Content: 14 pt glyph `text-on-slate-2` · `body-medium` `text-on-slate` message · 1 × 16 divider `#FFFFFF` @ 16 % · action button (26 pt, r 6, padding 0 6 0 8, `text-accent-on-slate` 600) with on-slate kbd “Z”.
- States: enter (`emphasized`, rise 8 + fade) · rest (4 s) · hover (timer paused; action hover `#FFFFFF` @ 10 %) · action pressed (`#FFFFFF` @ 16 %) · action focused (2 pt `focus-ring-on-slate`; toasts are not in the Tab loop, focus only with Full Keyboard Access) · replaced (cross-fade `fast`) · exit (`exit`). One toast at a time; `z` undoes the last action even after the toast is gone (until the next action).
- Messages: “Archived”, “Moved to Trash”, “Marked unread”, “Starred 3 conversations” (no action when undo is not useful), “Restored to Inbox”.

### 5.31 Undo-send panel

- Non-activating `NSPanel` anchored to the main window’s bottom-right (16 pt inset; above the quick reply bar when visible); 312 × 56, r 14, `bg-slate`, e3, padding 0 8 0 16, gap 12.
- Anatomy: 22 pt countdown ring (2.5 stroke; track `#FFFFFF` @ 18 %, progress `text-on-slate`, round cap, starting at 12 o’clock, emptying linearly) · text block (`body-medium` “Sending to Ben Carter”, `caption` `text-on-slate-2` “4 s · Work”) · action “Undo” + on-slate kbd “⌘Z”.
- States: counting (as above; reduce motion: ring hidden, “4 s” keeps counting) · hover (countdown continues — the window is short and predictable) · undone (panel exits, composer reopens with the draft) · sending (12 pt spinner replaces ring, “Sending…”, no action) · sent (`checkmark.circle.fill` `success`, “Sent”, exits after 1 s) · failed (`exclamationmark.triangle.fill` `#FFB4B7`, “Couldn’t send to Ben Carter”, “Saved to Drafts”, action “Open”).

### 5.32 Alerts and sheets

- Use `NSAlert` (system appearance, our app icon). Title names the object, informative text says the consequence. Buttons: for destructive confirmations the safe action (“Cancel”) is the default (↩) and the destructive button sets `hasDestructiveAction = true` (system red text). Never two destructive buttons. Suppression checkbox only for repeated, low-risk confirmations.
- Sheets (rare: OAuth client import) use `NSWindow.beginSheet` with the same field and button specs as Settings.

### 5.33 Tooltips

- System `toolTip` (system appearance). Content format: “Label  K” — label in sentence case, two spaces, shortcut in plain text (`⌘⇧O`, `G S`). The specimen draws them with a kbd cap to show the content; the app uses the system tooltip text only. Disabled controls explain why (“Nothing to undo”). Delay is system default.

### 5.34 Menus

- **Menu bar:** Paper · File (New Message ⌘N, Close ⌘W) · Edit · View (Inbox…All Mail with `g` hints, Focused/Other filter ⌘⌥1–3, Show/Hide Accounts ⌃⌘S, List Density ▸) · Message (Reply R, Reply All A, Forward F, Archive E, Move to Trash #, Star S, Mark as Unread U, Undo Z) · Mailbox (All Inboxes ⌘0, accounts ⌘1–⌘9, Check for Mail ⌘⇧N) · Window · Help. Single-key equivalents are displayed in menus but handled by `KeyboardRouter` so they never fire inside text fields.
- **Context menus** on rows and cards: Reply · Forward · — · Archive · Star · Mark as Unread · — · Move to Trash (glyph tinted `text-danger`), each with its glyph and key.
- **App-drawn menus** (autocomplete only): e2, r 10, padding 5, items 24 pt (40 with two lines), r 5, highlight `fill-selected`.

### 5.35 Keyboard shortcut hints (kbd)

- 18 pt high, min width 18, padding 0 4, r 3, `kbd-bg`, 0.5 pt `kbd-border` plus a 1 pt bottom edge in `kbd-border`, `kbd` role (SF Mono 11 Medium) `kbd-text`. Variants: on accent (`#FFFFFF` @ 18 %, white, no border) · on slate (`#FFFFFF` @ 10 %, 0.5 pt `#FFFFFF` @ 20 %, `text-on-slate-2`) · in tooltips 16 pt / 10 pt.
- Sequences: two caps separated by `caption` “then” (onboarding, Help) or adjacent caps (menus, tooltips).
- Where shown inline: search field “/”, reader footer R/A/F, quick reply R/esc, toast Z, undo ⌘Z, send ⌘↩, empty states. Hidden when the reader is narrower than 560 pt.

### 5.36 Progress

- **Spinner:** `NSProgressIndicator` `.spinning` at 12 (small), 16 (regular), 20 (toolbar/panel), 32 (welcome waiting); never full-pane. On slate it uses the light appearance variant.
- **Bar:** 4 pt, r 2, track `fill-subtle`, fill `fill-accent`. Determinate width animates with the value only (`linear`, ≤ 250 ms per update). Indeterminate: 30 % segment sliding 1.2 s linear loop; reduce motion: static segment + text.
- **Countdown ring:** see §5.31.

### 5.37 Welcome screen

- Inside the main window; the rail stays (empty, with only Add highlighted in its well) so the shape of the app is visible from the first second. Content on `bg-list`, centered, 28 pt above optical center: app tile 64 pt r 15 (slate gradient `#3D434B → #2B3036 → #22262B`, `wb.wing` 36 pt `#F5F7F9`) → 18 → “Welcome to Paper” `display` → 6 → “A fast, simple home for your Gmail and Microsoft mail.” 15/20 `text-secondary`, max 420 → 22 → large primary “Add Gmail account” (260 wide, `envelope` glyph, default ↩) → 8 → large secondary “Add Microsoft account” → 10 → ghost “Try the demo” (tooltip “Explore Paper with two made-up mailboxes. Nothing leaves this Mac.”). Footer 18 pt from the bottom: `lock` 12 pt + `caption` `text-tertiary` “Your mail stays on this Mac. Sign-in happens in your browser.”
- States: rest · waiting (buttons disabled; a status line below the buttons: 12 pt spinner + “Finish signing in in your browser…” + small secondary “Cancel”) · error (help line `text-danger` “Sign-in was cancelled in the browser. Try again.”; buttons re-enabled) · no OAuth client configured (secondary text “Add your OAuth client in Settings ▸ OAuth first.” + ghost “Open Settings”).

### 5.38 Settings window (SwiftUI)

- 600 pt wide, height fits content; `TabView` with toolbar tabs Accounts (`person.crop.circle`), OAuth (`key`), General (`gearshape`); selected tab tinted `text-accent` on `fill-subtle` (system style). `Form { … }.formStyle(.grouped)`: window background `bg-reader`, groups `bg-card` r 10 with 0.5 pt hairline, rows 40 pt (52 with a footnote, 56 for accounts), hairlines inset 12 (54 under account avatars), group titles `caption` 600 `text-secondary`.
- **Account row:** account avatar 32 r 10 (glow + monogram) · gap 10 · email `body` 500 · status line `caption` `text-secondary` with a leading 11 pt status glyph: `checkmark.circle.fill` `success` “Microsoft · Up to date · 10:42” · spinner “Gmail · Downloading · 12,480” · `checkmark`-less “Waiting to sync” · `exclamationmark.triangle.fill` `text-warning` “Signed out · reconnect to sync” (+ small secondary “Reconnect”) · `exclamationmark.triangle.fill` `text-danger` “Error: …” (+ “Retry”) · trailing destructive ghost “Remove…” (confirmation alert). Account color popup (10 names with swatches) in the row’s context menu.
- **Add:** small secondary “Add Gmail Account…”, “Add Microsoft Account…” right-aligned under the group. Demo mode row with explanation.
- **OAuth tab:** groups Google (Gmail) and Microsoft; label left, 24 pt field right (190–240 wide, `mono` for IDs); help footnote; “Show File in Finder” (small secondary) and “Save” (small primary) with a “Saved” success note.
- **General tab:** Notifications (Notify me about new mail · Show sender and subject) · Reading (Load remote images by default + privacy footnote · Reading font popup · List density popup) · Sending (Undo send popup: Off, 5, 10, 20, 30 seconds).
- States per control as §5.25–5.27; validation errors inline under the field.

### 5.39 Notifications content

- `UNMutableNotificationContent`, one per new conversation (not per message), `threadIdentifier` = conversation id so macOS groups a thread, `targetContentIdentifier` = conversation id (click opens and selects it).
- **Preview on:** title = sender display name (“Ben Carter”), subtitle = subject, body = snippet (≤ 140 chars, whitespace collapsed). `summaryArgument` = account label so grouped summaries read “3 more from Work”.
- **Preview off** (Settings ▸ Show sender and subject off): title “Paper”, body “New message in Work”; grouped “3 new messages in All Inboxes”.
- No sound by default (respect system settings), no images, no actions in v1 (Archive / Mark as Read are a later addition with category `message`). Never sent for mail that arrives while the conversation is open and the window is key.

### 5.40 App icon alignment

- macOS icon grid squircle; background slate vertical gradient `#3D434B` → `#2B3036` (55 %) → `#22262B`, 0.5 pt top highlight `#FFFFFF` @ 22 %; foreground `wb.wing` in `#F5F7F9` at 56 % of the tile width, optically centered (+2 % right, −2 % up). Icon Composer layers: background (gradient), foreground (wing) so Liquid Glass clear/tinted modes tint the wing only.
- It is the same slate as the rail and the same glyph as the welcome tile, empty state and notifications, so the icon, the rail and the first screen read as one object. Small sizes (16, 32) drop the highlight and thicken the wing by snapping the feather notches to the pixel grid.

---

## 6. Contrast table

Computed with the WCAG 2.x relative-luminance formula (sRGB, ratio = (L1 + 0.05) / (L2 + 0.05)) by a script over the token table above; alpha tokens are composited over their actual background first (and that background over white in light / black in dark where it is itself translucent). “Text (4.5)” rows are text or glyph-as-text pairs; “UI (3.0)” rows are essential non-text pairs (glyphs that carry state, focus rings, control outlines, selection fill against the list, account colors are in §4.4). Every pair passes in all four appearances except the two documented inactive-selection rows (§4.16).

| Kind (min) | Foreground | Background | Light | Dark | Light · IC | Dark · IC | ≥ min |
|---|---|---|---|---|---|---|---|
| Text (4.5) | `text-primary` | `bg-list` | 17.63 | 14.55 | 21.00 | 19.06 | pass |
| Text (4.5) | `text-primary` | `bg-card` | 17.63 | 13.74 | 21.00 | 17.79 | pass |
| Text (4.5) | `text-primary` | `bg-reader` | 15.99 | 15.74 | 17.55 | 21.00 | pass |
| Text (4.5) | `text-primary` | `bg-hover` | 16.28 | 13.41 | 18.03 | 15.22 | pass |
| Text (4.5) | `text-primary` | `bg-field` | 15.42 | 11.75 | 21.00 | 21.00 | pass |
| Text (4.5) | `text-primary` | `fill-selected-inactive` | 14.05 | 10.94 | 14.76 | 10.32 | pass |
| Text (4.5) | `text-primary` | `bg-raised` | 17.63 | 12.25 | 21.00 | 16.54 | pass |
| Text (4.5) | `text-secondary` | `bg-list` | 7.93 | 8.36 | 12.20 | 13.56 | pass |
| Text (4.5) | `text-secondary` | `bg-card` | 7.93 | 7.89 | 12.20 | 12.65 | pass |
| Text (4.5) | `text-secondary` | `bg-reader` | 7.19 | 9.04 | 10.20 | 14.93 | pass |
| Text (4.5) | `text-secondary` | `bg-hover` | 7.32 | 7.70 | 10.48 | 10.82 | pass |
| Text (4.5) | `text-secondary` | `bg-field` | 6.93 | 6.75 | 12.20 | 14.93 | pass |
| Text (4.5) | `text-secondary` | `fill-selected-inactive` | 6.32 | 6.29 | 8.58 | 7.34 | pass |
| Text (4.5) | `text-secondary` | `bg-raised` | 7.93 | 7.04 | 12.20 | 11.76 | pass |
| Text (4.5) | `text-tertiary` | `bg-list` | 5.82 | 6.34 | 8.70 | 10.49 | pass |
| Text (4.5) | `text-tertiary` | `bg-card` | 5.82 | 5.98 | 8.70 | 9.79 | pass |
| Text (4.5) | `text-tertiary` | `bg-reader` | 5.28 | 6.85 | 7.27 | 11.56 | pass |
| Text (4.5) | `text-tertiary` | `bg-hover` | 5.38 | 5.84 | 7.47 | 8.38 | pass |
| Text (4.5) | `text-tertiary` | `bg-field` | 5.09 | 5.12 | 8.70 | 11.56 | pass |
| Text (4.5) | `text-tertiary` | `fill-selected-inactive` | 4.64 | 4.77 | 6.11 | 5.68 | pass |
| Text (4.5) | `text-tertiary` | `bg-raised` | 5.82 | 5.34 | 8.70 | 9.10 | pass |
| Text (4.5) | `text-tertiary` | `fill-subtle` | 4.91 | 4.78 | 6.61 | 5.77 | pass |
| Text (4.5) | `text-secondary` | `fill-subtle` | 6.69 | 6.30 | 9.27 | 7.45 | pass |
| Text (4.5) | `text-accent` | `bg-list` | 5.53 | 6.87 | 7.28 | 11.05 | pass |
| Text (4.5) | `text-accent` | `bg-card` | 5.53 | 6.49 | 7.28 | 10.31 | pass |
| Text (4.5) | `text-accent` | `bg-reader` | 5.01 | 7.43 | 6.08 | 12.17 | pass |
| Text (4.5) | `text-accent` | `accent-subtle` | 4.73 | 5.63 | 5.56 | 8.46 | pass |
| Text (4.5) | `text-accent` | `bg-hover` | 5.10 | 6.33 | 6.25 | 8.82 | pass |
| Text (4.5) | `text-on-accent` | `fill-selected` | 5.05 | 5.26 | 6.66 | 5.48 | pass |
| Text (4.5) | `text-on-accent-2` | `fill-selected` | 4.53 | 4.85 | 6.66 | 5.48 | pass |
| Text (4.5) | `text-on-accent` | `fill-accent` | 5.05 | 5.26 | 6.66 | 5.48 | pass |
| Text (4.5) | `text-on-accent` | `fill-accent-hover` | 5.86 | 4.68 | 8.01 | 5.07 | pass |
| Text (4.5) | `text-on-accent` | `fill-accent-pressed` | 7.56 | 6.27 | 9.81 | 6.79 | pass |
| Text (4.5) | `text-on-slate` | `bg-rail` | 12.06 | 17.15 | 16.54 | 21.00 | pass |
| Text (4.5) | `text-on-slate` | `bg-slate` | 12.06 | 10.11 | 16.54 | 10.46 | pass |
| Text (4.5) | `text-on-slate-2` | `bg-rail` | 6.13 | 8.72 | 11.20 | 12.70 | pass |
| Text (4.5) | `text-on-slate-2` | `bg-slate` | 6.13 | 5.14 | 11.20 | 6.33 | pass |
| Text (4.5) | `text-accent-on-slate` | `bg-slate` | 6.77 | 6.24 | 10.73 | 6.79 | pass |
| Text (4.5) | `rail-badge-text` | `rail-badge` | 13.30 | 18.91 | 21.00 | 21.00 | pass |
| Text (4.5) | `text-danger` | `bg-card` | 5.90 | 6.39 | 8.13 | 9.43 | pass |
| Text (4.5) | `text-danger` | `danger-subtle` | 4.99 | 6.12 | 5.94 | 8.13 | pass |
| Text (4.5) | `text-success` | `bg-card` | 5.40 | 7.85 | 7.80 | 11.56 | pass |
| Text (4.5) | `text-success` | `success-subtle` | 4.69 | 6.96 | 6.16 | 9.07 | pass |
| Text (4.5) | `text-warning` | `bg-card` | 6.33 | 8.62 | 8.90 | 12.33 | pass |
| Text (4.5) | `text-warning` | `warning-subtle` | 5.67 | 7.77 | 7.16 | 9.60 | pass |
| Text (4.5) | `text-on-accent` | `danger` | 5.49 | 4.89 | 7.30 | 5.26 | pass |
| Text (4.5) | `kbd-text` | `kbd-bg` | 7.93 | 6.30 | 12.20 | 14.93 | pass |
| Text (4.5) | `text-primary` | `accent-subtle` | 15.09 | 11.91 | 16.04 | 14.60 | pass |
| UI (3.0) | `unread` | `bg-list` | 5.05 | 5.65 | 6.66 | 8.83 | pass |
| UI (3.0) | `unread` | `bg-hover` | 4.67 | 5.20 | 5.72 | 7.05 | pass |
| UI (3.0) | `text-on-accent` | `fill-selected` | 5.05 | 5.26 | 6.66 | 5.48 | pass |
| UI (3.0) | `star` | `bg-list` | 3.40 | 10.50 | 5.10 | 13.43 | pass |
| UI (3.0) | `star` | `bg-hover` | 3.14 | 9.67 | 4.38 | 10.72 | pass |
| UI (3.0) | `star` | `bg-card` | 3.40 | 9.91 | 5.10 | 12.53 | pass |
| UI (3.0) | `star-on-selected` | `fill-selected` | 3.60 | 3.75 | 5.16 | 4.25 | pass |
| UI (3.0) | `focus-ring` | `bg-list` | 5.05 | 6.87 | 7.28 | 11.05 | pass |
| UI (3.0) | `focus-ring` | `bg-card` | 5.05 | 6.49 | 7.28 | 10.31 | pass |
| UI (3.0) | `focus-ring` | `bg-reader` | 4.58 | 7.43 | 6.08 | 12.17 | pass |
| UI (3.0) | `focus-ring` | `bg-field` | 4.42 | 5.55 | 7.28 | 12.17 | pass |
| UI (3.0) | `focus-ring-on-slate` | `bg-rail` | 6.77 | 9.62 | 10.73 | 13.63 | pass |
| UI (3.0) | `focus-ring-on-slate` | `bg-slate` | 6.77 | 5.67 | 10.73 | 6.79 | pass |
| UI (3.0) | `line-control` | `bg-list` | 3.07 | 4.29 | 6.67 | 10.05 | pass |
| UI (3.0) | `line-control` | `bg-card` | 3.07 | 4.05 | 6.67 | 9.38 | pass |
| UI (3.0) | `line-control` | `bg-raised` | 3.07 | 3.61 | 6.67 | 8.72 | pass |
| UI (3.0) | `fill-selected` | `bg-list` | 5.05 | 3.22 | 6.66 | 3.48 | pass |
| UI (3.0) | `fill-accent` | `bg-card` | 5.05 | 3.04 | 6.66 | 3.24 | pass |
| UI (3.0) | `text-tertiary` | `bg-list` | 5.82 | 6.34 | 8.70 | 10.49 | pass |
| UI (3.0) | `text-on-slate-2` | `bg-rail` | 6.13 | 8.72 | 11.20 | 12.70 | pass |
| UI (3.0) | `success` | `bg-card` | 4.34 | 7.06 | 6.30 | 10.80 | pass |
| UI (3.0) | `warning` | `bg-card` | 4.06 | 8.62 | 6.33 | 12.33 | pass |
| UI (3.0) | `danger` | `bg-card` | 5.49 | 3.27 | 7.30 | 3.38 | pass |
| UI (3.0) | `fill-selected-inactive` | `bg-list` | 1.26 | 1.33 | 1.42 | 1.85 | see note |
| UI (3.0) | `line-selected-inactive` | `fill-selected-inactive` | 1.00 | 1.00 | 4.69 | 5.44 | see note |
| UI (3.0) | `rail-badge` | `bg-rail` | 13.30 | 18.91 | 16.54 | 21.00 | pass |

Account colors: every ink tone ≥ 3.36:1 on `bg-list` light; every glow tone ≥ 4.37:1 on `bg-list` dark and ≥ 3.44:1 on the light-mode rail; monograms ≥ 4.89:1 (§4.4 table). Avatar initials ≥ 5.96:1 (§4.5 table). Text on selected rows: primary 5.05 L / 5.26 D, secondary (`text-on-accent-2`) 4.53 L / 4.85 D.

---

## 7. Implementation notes

| Concern | AppKit (main window, composer) | SwiftUI (Settings) | CSS in WKWebView (reader shell) |
|---|---|---|---|
| Colors | `Wingbar.Color.*` → `NSColor(name:dynamicProvider:)`, four-way `bestMatch` | `Color(nsColor: Wingbar.Color.*)` | `--wb-*` custom properties, generated `:root` block with `prefers-color-scheme` and `prefers-contrast` queries; `data-contrast` attribute set by the app as a fallback |
| Type | `Wingbar.Font.<role>` returns `NSFont.systemFont(ofSize:weight:)`, `.monospacedDigitSystemFont`, rounded via `NSFontDescriptor.withDesign(.rounded)`, mono via `.monospacedSystemFont` | `.font(.system(size:weight:design:))` | `font: var(--wb-type-<role>)`; `letter-spacing` only for the three overrides |
| Hairline | `1 / backingScaleFactor`, redraw on `viewDidChangeBackingProperties` | `.overlay(Rectangle().frame(height: 1 / displayScale))` | `0.5px` |
| Radii | `layer.cornerRadius`, `.continuous` curve | `RoundedRectangle(cornerRadius:style: .continuous)` | `border-radius` |
| Shadows | two layers with `shadowPath` (floating surfaces only) | `.shadow` twice | `box-shadow` list as in the token |
| Motion | `NSAnimationContext` with token duration and `CAMediaTimingFunction(controlPoints:)`; check `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` | `.animation(.timingCurve(…, duration:))`, `@Environment(\.accessibilityReduceMotion)` | `transition` with `var(--wb-dur-*)` / `var(--wb-ease-*)`; `@media (prefers-reduced-motion: reduce) { * { transition-duration: 0s } }` plus the 100 ms fade exceptions |
| Materials | `NSVisualEffectView(.headerView)` for the reader header only | system | none (reader shell is opaque; `prefers-reduced-transparency` unused) |
| Icons | `NSImage(systemSymbolName:)` + `SymbolConfiguration(pointSize:weight:)`; custom glyphs as `NSBezierPath` drawn in `draw(_:)` | `Image(systemName:)`; custom via `Shape` from the same path strings | inline SVG (custom glyphs) — the reader only needs `wb.pending`, the star, chevrons and attachment glyphs as inline SVG |

**List performance rules (unchanged budgets: 16 ms selection, 50 ms list refresh):** row views are opaque and layer-backed; colors resolved once per appearance change and cached alongside the attributed strings (cache key gains the appearance name); no `NSShadow`, no `NSVisualEffectView`, no `CAAnimation` in `ConversationCellView`; selection drawing in a custom `NSTableRowView.drawSelection(in:)` that reads `isEmphasized`; the wingbar, dot and badge are three fills in `draw(_:)`; date dividers are group rows of fixed height.

**Reader shell mapping:** `--ss-bg` → `--wb-bg-reader`, `--ss-card` → `--wb-bg-card`, `--ss-border` → `--wb-line-hairline`, `--ss-text` → `--wb-text-primary`, `--ss-muted` → `--wb-text-secondary` / `--wb-text-tertiary` (dates), `--ss-accent` → `--wb-text-accent` (links) / `--wb-unread` (dot), `--ss-chip` → `--wb-fill-subtle` / `--wb-bg-field` (chips), `--ss-selected` → `--wb-focus-ring`, `--ss-star` → `--wb-star`. Card radius 12 → 10, avatar circle → squircle r 11, `.ss-button` → pill (§5.15), `.ss-footer a` → ghost buttons with kbd hints, body font 13/1.45 → `reading` 14/21.

## 8. What changes from today’s UI

| Today | Wingbar |
|---|---|
| Rail 64 pt, near-black, circle avatars with the same initials for every account, red badges | 72 pt slate rail, account tiles in the account’s glow color with distinct monograms, white chalk badges, well + perch selection |
| 10 pt account dot overlapping the avatar | 3 pt wingbar ribbon (unified only) |
| Row 72 pt, circle avatars in 12 saturated colors, pending rows faded to 60 % | Row 68 pt, squircle tinted avatars in 8 tints, `wb.pending` glyph at full contrast |
| `systemYellow` star, `controlAccentColor` unread, `quaternaryLabelColor` badge | `star` (≥ 3.14:1), fixed Sparrow Blue `unread`, `fill-subtle` badge with rounded tabular numerals |
| Reader: equal-weight stacked cards, 12 pt radius, blue focus outline by default | Collapsed messages merged into one deck, expanded card lifted 12 pt below; focus ring only after keyboard navigation |
| Quick reply: bare text line | Docked 36 pt field on the card axis with kbd hint, grows to an inline mini-composer |
| Composer: grey bottom bar with a grey Send | One text axis at x 72, title-2 subject, primary Send with ⌘↩ hint, attachment strip on the same axis |
| ~30 one-off hex colors, 4 avatar palettes, 8 font sizes, radii 4–16 | 53 semantic color tokens × 4 appearances, 1 account palette (10), 1 avatar palette (8), 16 type roles on 7 sizes, 6 radii |
