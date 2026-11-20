# Quire — the SuperSparrow design language

**Version 1.10.1 · 20 November 2026 · authoritative.** 1.10.1 renames Settings › General's **Crash reports** row **Analytics and reports** (§5.40): its one toggle now governs crash reports (Sentry) and product analytics (TelemetryDeck) together, at the same place and on unless turned off, and names what the build sends to, “Send to Sentry and TelemetryDeck”, or “Send to Sentry” or “Send to TelemetryDeck” when the build has only one; the caption reads “Crashes, hangs and features used. Never your mail or addresses.”, still one line; a build with neither shows it disabled, captioned “Not set up in this build.” Analytics adds no other surface: it counts which features are used, never what they were used on, and nothing in the app speaks of it. 1.9.3 adds **Crash reports** to Settings › General (§5.40): a toggle “Send to Sentry”, on unless turned off, the first row of the last group, above At login, with the caption “When the app crashes or hangs. Never your mail or addresses.”; a build without a Sentry project shows it disabled, captioned “Not set up in this build.” It adds no other surface: reports are made and sent without a word to the user, and nothing they hold names mail. 1.9.2 moves the **calendar toggle** to the window's trailing edge (§5.54): the reader header's action line holds only what acts on the conversation, and once some account has granted the calendar permission the toggle always stands at the right, at the trailing end of the day column's kicker line (on, quiet, “Hide Day  D”) while the column shows, and as the glyph atop its 28 pt strip while it is hidden, since a hidden column then folds to its strip rather than going (a click on the strip shows the column in place when the window has room for it); with no account granting it there is no toggle, and a hidden column goes as before (§5.12, §5.1). An hour label in the gutter now gives way to the now time where the label is drawn, so 00:00, held inside the timeline's top, never sits under 00:19. 1.9.1 tunes the type and the margins of **Day and week** (§5.54): a day cell's date is now the larger line (`body`, today's `bodyStrong`, under a `meta` weekday), the two lines centred in the cell at any Text size; the column's hour gutter grows to 44 pt so its labels stand clear of the column's edge; a fold is a band of `canvas` with its range and no dashed edges, which doubled the hairline over the timeline and beside every fold; a mark's chip never covers a fold's range, hanging from its line into the open hours at a fold's edge; an event too narrow for its range shows its start alone (“17:30”, never “17:30 -…”); and the hatch over an invitation's overlap stops 2 pt short of each line of its words, which it ran through. 1.9.0 adds **Day and week** (§5.54): every account's main calendar beside the mail, each event in its account's ink on a tint of it, as a 240 pt **day column** to the right of the reader, on by default, which D (or the Day button that now ends the reader header's action line, beside the Week button, §5.12) hides and shows instantly as the rail hides, which the window remembers, and which folds to a 28 pt strip of busy bars in a window too narrow for a 400 pt reader beside it, a click on the strip or D opening the column over the reader's edge; seven day cells over the column chart the week, and W gives the **week** the reader's place and the column's until W again; neither ever scrolls, since open hours share the height and empty ones fold into 14 pt bands; the selected conversation's invitation is pencilled in or carries the margin rule, what it overlaps is hatched in `warning`, and the invitation card, which no longer says it shows no conflicts, names an overlap in words (“Overlaps 1:1 with Sam, 13:30 - 14:00”, §5.14); B, or a row dropped on a day or the week, sets 30 minutes aside for the selected mail in its account's calendar with a toast and Undo, the only writing to a calendar besides answers (§4.13, §5.30, §6.1); the default window grows to 1304 pt so a new window's reader keeps its keycaps beside the column, and while the column is on the list's maximum gives up 28 pt so even the strip never takes the reader under 400 (§3.2, §5.1); and the cheat sheet gains B in Act, [ ] T in Go and D W in View, so it now scrolls under its title row in the default window as it did in shorter ones (§5.32, §6). 1.8.8 adds the **Outbox** (§5.53), shown only while a message is on its way, as Later is while something is snoozed (a rail tile after Drafts, `tray.and.arrow.up`, with its title-menu item, View › Outbox and G O, all gone and the window back in the Inbox once the last has gone, §5.2, §5.4): it lists every message on its way until the provider has taken it, each row saying where it is (“Sending…”, “Sends Mon 09:00”, “Not sent”, “Retrying shortly”, “Couldn't send” in `danger` for the moment until it is kept), where a held Send Later message, one waiting out a retry included, continues and cancels as from Drafts and no mail action applies to a row, and which a send that fails leaves for Drafts, kept once as a draft holding its reason, as a failed Send Later message already was, its row cleared only once that draft is on disk (one SuperSparrow quit while handing over says it may have gone and to check Sent, §5.31, §5.18); ↩ on the list or a **double-click** on a row now opens the conversation in a **reader window** (→ keeps opening it in the main window's reader; in Drafts they continue editing, and in the Outbox a held Send Later message too, any other row only showing; on a focused control elsewhere ↩ stays that control's), and a fresh Esc, never its key repeat, closes a reader window whose quick reply holds nothing typed and no countdown (§5.49, new §6.1 Esc row 10); ⌘Z (Edit › Undo) now **walks back** through the last 50 steps, one per press, however old (archives, stars, moves to the Trash, marks, snoozes, mutes, a message's own star), while Z still reaches only the latest toast's step within its grace (§6.1, §5.30); and the cheat sheet reads “→ esc” and “↩” in Move and G O in Go, where ⌘0 … ⌘9 now share one row (§5.32, §6). 1.8.7 sets `runningHead` in **sentence case** at the system's own tracking, as macOS sets a sidebar's section headings, where it was uppercase and tracked 0.6 pt: the list's date dividers (“Today”), the reader's kicker (“Kinvori · 2 messages”), the invitation card's kicker, the printed kicker and the cheat sheet's section titles (§4.4, §5.8, §5.12, §5.14, §5.32). It also drops the **long dash** from every string the app shows: a compact row joins subject and snippet with “ - ”, an invitation's times and days read “15:00 - 16:00”, and the demo's window title is “SuperSparrow Demo” (§5.7, §5.14, §5.39). 1.8.6 says when macOS keeps **notifications** from SuperSparrow: with them off for it in System Settings macOS shows no new mail and draws no Dock badge, though New mail reads on and the app sets the count, so Settings › General then shows a line under Notifications, “Off in System Settings” with Open Notifications and a caption naming the Dock badge, “Dock badge off in System Settings” when only the badge is off, and “Not allowed yet” with Allow… while macOS has never asked; and the app asks macOS whenever it has no answer, at launch as well as when an account is added, rather than once ever (§5.40, §5.41, §5.28). 1.8.5 draws the list's **swipe** itself, as Apple Mail does, in place of AppKit's row actions, whose title AppKit drew black on the near-black Archive fill in a key window and which could hold no icon: the row's content slides under the fingers and uncovers the row's full height in the action's fill, with the action's icon above its label, both white (`onSwipe`), centred in what it uncovers; let go past half the button it stays open, carried past 0.6 of the row's width it makes the change, and beyond that it rubber-bands; it closes on a scroll, another row's swipe, a click elsewhere, Esc, a selection change or a refresh, and settles along the motion tokens, at once under Reduce Motion (§5.7, §4.10, `layout.swipe`). 1.8.4 gives SuperSparrow its **paper plane**: one sheet of white paper folded into a dart and drawn on an isometric grid, black and white only, every edge straight. Its far wing, near wing and keel are three triangles cut apart by two folds; the trailing edge, the spine and the keel's top run on the grid's 1:2 lines, and the near wing's leading edge and the keel's foot share one 45° line. It sits white on a near-black tile in the app icon, in every appearance (the tinted icon hands the system the white plane on black), and it replaces the italic envelope as the app icon, the mark on the welcome screen with a new drawn straight-edged wordmark, and the inbox-zero glyph (§4.11, §5.42, `layout.brand`, `layout.appIcon`, docs/brand). The welcome screen's mark (64 pt) and wordmark are drawn in the brand's own black and white, `layout.brand.ink` on a light page and `paper` on a dark one, and inbox zero's mark in the system's secondary label grey, never in a theme's ink, so the `brandMark` colour token, its Graphite substitution and Graphite contrast pair, and the two marks' contrast pairs are removed (§3.1, §4.16, §5.9, §5.39). 1.8.3 gives SuperSparrow a **new mark**: the **italic envelope**, one blue envelope leaning forward 12° like italic type, its flap crease a small bird in flight, on a white tile. It is the app icon (default, dark and tinted), the mark on the welcome screen with the drawn wordmark, and the inbox-zero glyph, and it replaces the sparrow, the laid paper and the stamp rule everywhere (§5.42, `layout.brand`, `layout.appIcon`, docs/brand). 1.8.2 makes **every address in a message header copyable**: in the open list each recipient, and on the name line the sender's address, copies with a click, ↩, Space or ⌘C, shows “Copied” in its place for a moment and is announced; the list opens below its toggle, which reads “Hide addresses” and is now the only way to fold it besides Esc, on a 24 pt pitch capped at 8 lines; a person menu (Copy Address, Copy Name and Address, New Message, Show Mail from This Person) opens on any of them (§5.14, §4.10, §4.17, §5.35, §6, §6.1). It also gives each **swipe** button its own fill from the theme, Archive in the ink's fill and Mark as Read or Unread in a calm grey, each chosen to hold AppKit's white title at 4.5:1 in every theme and mode, under Increase Contrast and Graphite (§5.7, `swipeArchive`, `swipeRead`, `onSwipe`). 1.8.1 adds the **pointer** (§4.17): the pointing hand over everything a click acts on, links in message bodies included, the I-beam over text, the arrow elsewhere and over a control that is disabled or that a click would leave as it is. 1.8.0 adds **themes**: Study (the default and 1.7's palette, unchanged), Gallery, Rain, Grove and Dusk. Each is a paper and an ink (Gallery's ink has no colour) derived from Study's table by one luminance-locked rule and checked pair by pair in four modes and under Graphite (§4.16). They are chosen in a new Settings › Appearance tab, with Appearance (Automatic · Light · Dark), the Dark Mode default for mail that sets its own colours, and Font and Text size moved from General (§5.40). 1.7.0 adds **Send Later** (§5.46), **Mark as spam** (§5.47), **Print and PDF** (§5.48), the **reader window** (§5.49), **Find in conversation** (§5.50), **Mute** (§5.51) and **sender rules** (§5.52), **Text size** (§4.15), **pictures in the composer's body** and the **Services** menu's New Message with Selection and Send with SuperSparrow (§5.20), **Download** and **Download all** on attachments (§5.17), a **swipe** on a row to archive or mark it read (§5.7), **At login** in Settings › General (§5.40) and the Dock badge's **99+** as the rail's (§5.28), with a cheat sheet that lists every new key and still fits the default window whole (§5.32). 1.6.4 adds the **invitation card**: a message that carries a calendar invitation opens with a card above its body (title, when, where, organizer, guests), the body folded under it behind the elision mark (“Show message”), answered with Accept · Tentative · Decline, marked Cancelled when the organizer called it off, with Open in Calendar beside them; an answer that needs permission to update the calendar waits and asks to reconnect, on the card and in Settings › Accounts (§5.14, `layout.invitation`, §5.40, §5.44). 1.6.3 adds **Unsubscribe**: a message whose list headers offer a way out shows an “Unsubscribe” link beside the sender in its sheet header, also in its More menu, in the context menu and as Message › Unsubscribe (⇧⌘U); one click sends the request (or opens the sender's page) and archives the conversation, or, snoozed (in Later, or a search's result), ends its snooze and leaves it archived, as E does in Later, so the list's mail never comes back at its time; the toast's Undo brings the conversation back (to Later, snoozed as before) while the request stays sent, which the undo's confirmation says, and the toast never takes in a later archive (§5.14, §5.30, §5.35, §5.45, §6, the cheat sheet). 1.6.2 adds **searching the server**: once a search's local results are all listed, the list ends with **Search Gmail for more**, which ⌘↩ in the search field, a click or ↩ on its link runs, and which then says how it went (“Searching Gmail…”, “Found 12 more on Gmail”, “Nothing more on Gmail”, “Couldn't search Gmail · Try again”); the server is asked the field's text as typed, so its own search rules decide what it finds, and the operators this Mac tests on the row (`is:`, `has:`, `before:`, `after:`, `in:`) and the account scope still narrow its finds; a search with no local results offers the same in its empty state, whose line 2 may now end with a link (§5.10, §5.9, §5.6, §5.35, §6, the cheat sheet). 1.6.1 adds **search operators**: `from:`, `to:`, `subject:`, `is:unread`, `is:read`, `is:starred`, `has:attachment`, `before:`, `after:`, `in:` a view, quoted phrases and a leading minus, typed into the search field and nowhere else; an `in:` term picks the view searched, whichever view is on screen, Later included (§5.6); keys, menus, toasts and drops treat the results as rows of that view (§5.12, §5.45); the cheat sheet gains one line that lists them under the bands (§5.32, `cheatSheet.searchTermGap`). 1.6 adds **Later**: L snoozes the selection with a native menu of four times and Pick a Date… (§5.45); the conversation is archived now and comes back to the Inbox at its time, unread, sorted by the moment it came back and tagged “Back” (§5.7); a Later tile (G L) shows in the rail below Inbox only while something is snoozed (§5.2, §5.4), and the cheat sheet lists L and G L (§5.32, §6). 1.5.2 adds **Keep mail on this Mac** to General: a popup (Everything, 1 year, 3 months) with the space the mailbox takes beside it; a message older than the window keeps its row, snippet and searchable text, and its full message downloads again when it is opened (§5.40, `settings.mailboxSizeGap`). 1.5.1 adds account signatures: one per account, set in the account's detail form (§5.40), inserted by the composer one empty line below the typing point and above the folded original, and replaced when From changes (§5.20); §9 no longer excludes them. 1.5 renames the General font setting **Font** and makes it the app's typeface: SF Pro now sets every New York role in its sans twin across the app and applies live, and monograms gain the twin `monogramSans` (§4.4, §5.29, §5.40). 1.4 moves the six views into the rail as folder tiles (§5.2), anchors the accounts at the bottom of the rail just above Add, puts the masthead, search and compose on one header line (§5.3, §5.6), keeps the title menu for minimal mode only (§5.4), and removes the Focused/Other filter tabs (§5.5) and the rows' “Other” tag (§5.7). 1.3.1 records what the code does where it went past 1.3: one rule for account names and monograms (§4.2), plain text set as paragraphs (§5.14), the app icon as drawn (§5.42, `appIcon.corner`), `QuireWindowChrome` (§3.2) and the AppKit component names (§8.2), and the composer title-bar test (§8.7). 1.3 closes the eighteen gaps of the 1.2 review: pressed checkbox, radio and toggle states that keep 3:1 (`controlOnPressed`, a knob-face press, a wash-free link press), account inks that never meet a popup's hover or pressed face, a complete Graphite substitution with its own generated contrast pairs, the full alert inventory, the reconnect flow, no signatures in v1, the cheat sheet's content, Space and Tab inside a sheet, the Settings window's size and detail form, the multi-selection and Trash action sets, the positions that still had no metric, a Reduce Transparency scrim, capped token rows, expanded recipients, and the worked numbers that still assumed the macOS 15 rail. This document, `docs/design/tokens.json` and `docs/design/specimen.html` (rendered as `specimen-light.png` and `specimen-dark.png`) are the complete design language for SuperSparrow. Where they disagree, `tokens.json` wins and the other two are regenerated from it.

A quire is a gathering of folded sheets, the unit a book is sewn from. Quire treats mail the same way: each conversation is a tight stack of folded messages and one open sheet, set in New York on paper and marked in a single ink (**Iron Gall** in the default theme), the blue-black ink letters were written in for a thousand years. The list is a still index; the reader gets the room of a page. Sparrow's shape stays: a narrow account rail, one list, one reader, almost no chrome. Superhuman's speed shows in response, not in motion.

**How to read the numbers.** All metrics are points (1 pt = 1 CSS px in the reader). Colour values are given in four modes: Light, Dark, Light IC and Dark IC (IC = Increase Contrast). Alpha colours are written `#RRGGBB @ n %` here and `#RRGGBBAA` in `tokens.json`; they are always composited over the surface beneath. Every number in this file is rendered from `tokens.json`; the token path is given wherever a component lists its metrics (for example `layout.row.height`).

---

## 1. Principles

1. **Reading is the product.** Serif where people read, sans where they scan or write. New York sets subjects, the reader headline and plain mail; SF Pro sets everything you scan, operate or type.
2. **One ink, used like a pen.** Each theme writes in a single ink (Iron Gall in Study, petrol in Rain, teal in Grove, evening blue in Dusk; Gallery writes in its text ink, as Graphite does), and it marks only what needs you: unread, keyboard focus, the current selection and the single primary action. If two marks in the ink compete in one region, one of them is wrong.
3. **A still list, a generous page.** The list is an index: fixed rows, no motion, no shadow, no blur. Actions never animate rows; feedback goes to the toast. The reader is a page: a 680 pt column with 24 pt leading.
4. **Shape before colour.** Every state has a shape, a weight or a word: the pip, the margin rule, Semibold, the filled star, the queued glyph, the “!” badge. Colour confirms a state; it never carries it alone.
5. **Native first, then ours.** Traffic lights, menus, alerts, tooltips, scrollers, notifications and the Settings window frame and toolbar stay macOS. Quire styles content, the controls inside Settings (so their focus rings and edges meet 3:1), and the few surfaces macOS does not provide.

## 2. Signature elements

| Element | What it is | Where |
|---|---|---|
| **New York subjects** | Subjects are set in New York: 14 pt in rows, 24 pt as the reader headline, 15 pt in the composer. Next to SF Pro senders and snippets the list reads like a table of contents. | Rows, reader header, composer |
| **Iron Gall** | The ink of the default theme, Study: blue-black on paper (`#1E5468`), wet ink on dark paper (`#6DB6C9`). Fills use a deeper pooled ink in dark (`#2D788B`) so white labels stay crisp. Every theme has exactly one ink, and Gallery's has no colour (§4.16). | Pip, unread time, margin rule, focus, primary button, badges |
| **The margin rule** | A 3 pt rule flush with the leading edge marks where you are, as an editor marks a passage. Always drawn, in the ink while its window is key and in `ink3` when it is not. | Selected row, rail, selected Settings account row, autocomplete highlight |
| **The horizon** | The traffic lights, the masthead, the search field, the compose button and the reader's kicker share one centre line, y = 26. The list header is that 52 pt title-bar band alone, so the index starts right under the title bar; the reader header adds its headline below the line, and its hairline at 92 pt is the horizon the reader and the cheat sheet hang from. | Main window |
| **The quire** | Collapsed messages fold into one stack of 44 pt lines; the open message is a full sheet beneath it. | Reader |
| **Kicker and headline** | A small kicker names the account (with its ink dot) and the message count above a New York headline, as a newspaper names its section. | Reader header |
| **The elision mark `[…]`** | Quoted text, and the message under an invitation card, fold behind the editor's mark for omitted text (`ss.elide`), placed at the fold. | Reader, composer |
| **The slip and the contrail** | Toasts, the undo-send panel and the g-sequence HUD are small dark slips with one verb. The contrail, a 2 pt line with a 4 pt head, is the one drawn element that means time is moving. | Toast, undo send, sync line, attachment progress |
| **Monograms** | Avatar initials in New York Semibold (its SF Pro twin under the SF Pro font, §4.4) on soft tints, like monogrammed letterhead. The rail shows domain monograms (C for contoso.com). | Rows, reader, rail, Settings |

## 3. Platform decisions

### 3.1 System accent

- **Custom-drawn surfaces use the theme's ink.** Selection, focus, the unread pip, badges and primary buttons are tuned against the paper surfaces in four modes, in every theme; an arbitrary system accent (Yellow, Pink) breaks those pairs. A swipe's buttons take their fills from Quire too, under their white icon and label, whatever the accent (§5.7).
- **Native controls follow the app accent asset.** The app ships Iron Gall as its `NSAccentColorName` asset (`AccentColor` colour set: Any `#1E5468`, Dark `#2D788B`, high-contrast `#123E4D` / `#246F83`; the fill value, because macOS draws white text on it in menu highlights and default buttons). Under the default Multicolor setting, NSMenu highlights, NSAlert default buttons and the Settings toolbar's selected tab are therefore Iron Gall and match the custom drawing. (Controls inside Settings are Quire-drawn, §8.3, so they never depend on this.) When the user picks an explicit accent, native controls follow the user and custom-drawn Quire surfaces stay in the theme's ink. The accent asset stays Iron Gall in every theme: it is compiled and read once at launch. Every coloured theme's fill is held within 7.5 ΔE00 of it, so native menus and default buttons stay in family; Gallery has no coloured fill (§4.16).
- **Graphite exception.** When the system accent is Graphite (`NSColor.currentControlTint == .graphiteControlTint`, or `controlAccentColor` saturation below 0.1), every accent-family token is replaced from **the active theme's** neutral ramp, one row per token below (`graphite` in `tokens.json`). That user asked macOS to take colour out. Account inks are identity, not accent, and stay (the kicker dot, rings, the From dot, swatches); so do `selWashIdle`, `selRuleIdle`, the semantic colours and the star. Because colour no longer tells a link from text, link buttons, invitation links and links in adapted and Quire-set bodies draw their underline at rest under Graphite, **and in any mode where the theme's ink is within 15 ΔE00 of its text ink, or within 10 under a colour-vision simulation; links inside quotes, where the same holds against `ink2` (§4.16)** (hover and pressed as §5.24). Fills step back toward the surface as they are hovered and pressed (`ink` → `ink2` → `ink3`), because `ink` is already the end of the ramp. The build regenerates every contrast pair that touches one of these tokens with the substitutions applied, for each theme (123 Graphite pairs per theme, §7) and asserts them with the others; the two 1.25 scan-cue pairs are the only ones not regenerated, because under Graphite the selection wash is the idle wash and the `ink` margin rule (≥ 12:1 on `paper`) is the cue.

| Token | Under Graphite | Where it shows |
|---|---|---|
| `accent` | `ink` | Pip, unread time, links (underlined at rest under Graphite), margin rule colour, contrail, progress, drop label, caret, dot badges |
| `accentFill` | `ink` | Primary button, unread count badge, checkbox and radio on, toggle on track, selected token |
| `accentFillHover` | `ink2` | Primary button hover; checkbox and radio on, hover: the fill steps back toward the surface |
| `accentFillPressed` | `ink3` | Primary button pressed: one step further back |
| `controlOnPressed` | `ink3` | Checkbox and radio on, pressed |
| `onAccent` | `paper` | Labels, numerals, checkmark and radio dot on the neutral fills |
| `swipeArchive` | `swipeArchiveNeutral` | A swipe's Archive button (§5.7): `ink` would turn light in dark appearances under the button's white icon and label, so the slip by day and, at night, a grey light enough to stand out from the row |
| `accentWash` | `selWashIdle` | Quiet toggles on: unfolded quoted text, Original colors action, format toggles, the Format button |
| `accentWashHover` | `selWashIdle` + `hover` | Quiet toggle on, hover |
| `accentWashPressed` | `selWashIdle` + `pressed` | Quiet toggle on, pressed |
| `focus` | `ink` | Focus rings, the composer's inset ring, the drop outline |
| `selWash` | `selWashIdle` | Selection, window key: the idle wash; key and not key differ by the rule (`ink` against `ink3`), and the rule is the scan cue |
| `selRule` | `ink` | Margin rule, window key (rows, rail, Settings account row, autocomplete highlight) |
| `selWashIdle` | unchanged | Selected row, window not key |
| `selRuleIdle` | unchanged | 3 pt margin rule of the selection, window not key (>= 3:1, always drawn) |
| `knob` | `paper` | Toggle knob face, so it stays distinct from the `ink` on track in dark appearances |
| account inks | unchanged | Identity, not accent: rings, the kicker dot, the From dot, swatches, the compact square and the initial tile |

- **Text selection** in text views and the reader keeps the system highlight colour (`selectedTextBackgroundColor`, CSS `::selection` left at default).

### 3.2 Window and title bar

- One main window: `.titled .closable .miniaturizable .resizable .fullSizeContentView`, `titlebarAppearsTransparent = true`, `titleVisibility = .hidden`, and an **empty toolbar**: `window.toolbar = NSToolbar(identifier: "main")` with no items, `toolbarStyle = .unified`, `titlebarSeparatorStyle = .none` (`layout.trafficLights.mechanism`). The toolbar exists only for its geometry: it makes AppKit lay the title bar out as the 52 pt unified band, with the traffic lights inset from the corner and centred on y = 26. Without a toolbar AppKit draws the plain title bar instead (lights at x ≈ 7–9, centre y ≈ 14–16, as in today's build, `dist/screenshot-main.png`), and every metric below would be wrong. The window's title (“SuperSparrow”, or “SuperSparrow — Demo” in demo mode, §5.43) still names it in the Window menu, Mission Control and VoiceOver. `QuireWindowChrome.configureMainWindow` (SSDesign) applies this configuration, and `QuireWindowChrome.metrics(of:)` reads the lights back as described next.
- **The traffic lights stay where AppKit puts them**; they are never moved with `setFrameOrigin`. Their centre line is y = 26 on every supported macOS. Their horizontal extent depends on the release, so the layout reads it at runtime instead of assuming it: `lightsEnd` = where the zoom light is drawn to (`standardWindowButton(.zoomButton)`'s frame `minX` plus the last column it paints, `QuireWindowChrome.drawnTrailingEdge(of:)`, never more than the frame's `maxX`) and `lightsCenterY` = the close button's `midY`, both converted to the content view and measured from its top-leading corner. The drawn edge matters because AppKit's compatibility appearance, which an app linked against the macOS 15 SDK gets on every later release (SwiftPM builds today), draws the 12 pt light inside a 14 pt frame that ends 1 pt further out.

  | macOS | First light x | Light | Gap | `lightsEnd` | Rail width | Minimal-mode masthead x |
  |---|---|---|---|---|---|---|
  | 15 (the 1.1 values; asserted by `WindowChromeTests`) | 20 | 12 | 8 | 72 | 76 | 84 |
  | 26 and later (measured on 27.0.1) | 19 | 14 | 9 | 79 | 84 | 92 |
  | Any release, compatibility appearance (linked against the macOS 15 SDK; measured on 27.0.1) | 20 | 12 | 8 | 72 (the button frame ends at 73) | 76 | 84 |

  **Rail width** = the larger of 76 and the smallest even number ≥ `lightsEnd` + 4 (`layout.rail.lightsClearance`), so the lights always sit on the rail with at least 4 pt before its trailing hairline. The width includes that hairline: the split view's first divider is the hairline, so the rail's own pane is the width less one hairline (75 pt and the rule at x = 75 at 1×), and the list's default 364 likewise includes its trailing divider. Rail tiles, the divider and the utilities are centred in it (x = width / 2; `layout.rail.tileCenterX` is the macOS 15 value). In minimal mode the masthead starts at rail width + 8 (`layout.listHeader.mastheadMinimalGap`), measured from the would-be rail, so it clears the lights by at least 8 + 4 pt on every release.
- **One centre line.** The masthead (§5.3), the kicker and the reader header actions (§5.12) and the compose button are all centred on `lightsCenterY` = 26, and the title-bar zone is twice that (52). `WindowChromeTests` (§8.7) builds the main window off screen with this exact configuration and asserts the close button's centre is 26 ± 0.5 pt and that the rail clears `lightsEnd` by 4 pt. If a future macOS moves the centre, that test fails, and `titlebarZone`, `mastheadCenterY`, `kickerCenterY` and the action tops are re-derived from the measured centre (zone = 2 × centre, tops = centre − 14) instead of patched by eye.
- The top 52 pt of every pane is the title-bar zone: it drags the window (`mouseDownCanMoveWindow`), double-click follows the system preference, and controls inside it opt out. Content under the toolbar still receives clicks (hit-testing passes through the transparent unified toolbar to the content view; verified on macOS 27). The toolbar's own container is taller than the band from macOS 26 on (66 pt measured), so every view below y = 52 returns `mouseDownCanMoveWindow = false`: a click on the reader's headline or the first list row never drags the window. In full screen AppKit hides the toolbar band and reveals it on hover; the zone keeps its height so nothing jumps.
- Default size 1304 × 800, minimum 960 × 600. The default width is the macOS 26 rail (84) + the default list (364) + the narrowest reader that keeps its keycaps (616, §5.36) + the day column (240, §5.54), so a new window's reader keeps its keycaps beside the column, with 8 pt more on macOS 15 (1.9; it was 1280, which left the reader 592 pt beside the column). A window already open keeps its saved size. The reader never gets narrower than 400 pt (`layout.window.readerMinWidth`): the list's maximum width is the smaller of 480 and window width − rail − 400, and 28 pt less while the day column is on (`calendarPane.stripWidth`, §5.54), so even the column folded to its strip never takes the reader under 400. The column itself shows in full only while the reader keeps 400 pt beside it (`calendarPane.readerMinWithColumn`), and folds to the strip otherwise.
- **Composer windows** use the same transparent title bar over `paper`: `.titled .closable .miniaturizable .resizable .fullSizeContentView`, `titlebarAppearsTransparent = true`, `titleVisibility = .visible` (the system draws the title text and the lights), no toolbar, so it keeps the plain system title bar: 28 pt on macOS 15, 32 pt from macOS 26 on (measured on 27.0.1; `layout.window.composerTitlebar` / `composerTitlebar26`). `QuireWindowChrome.configureComposerWindow` applies it. The band's height is read from the window (`QuireWindowChrome.titlebarHeight(of:)`: the content view's height above `contentLayoutRect`), never assumed; the band is `paper` with a hairline at its bottom drawn by the content view, and the field rows start directly below it.
- **Reader windows** (§5.49) take the main window's chrome, not the composer's: the same style mask, transparent title bar, title hidden and the empty unified toolbar, so AppKit lays out the 52 pt band with the lights centred on y = 26, and the reader header's kicker and actions sit on that one centre line as they do in the main window. The title (the conversation's subject) still names the window in the Window menu, Mission Control and VoiceOver. `QuireWindowChrome.configureReaderWindow` applies it, with the reader window's own minimum (`layout.readerWindow`).

### 3.3 Appearance and accessibility modes

| Mode | AppKit / SwiftUI | Reader CSS | What changes |
|---|---|---|---|
| Light / Dark | `NSApp.effectiveAppearance`; app appearance follows the system unless Settings › Appearance › Appearance says otherwise | `prefers-color-scheme` | Every colour token switches value |
| Theme | `QuireEnvironment.theme` (AppKit providers) and `EnvironmentValues.quireTheme` (SwiftUI) | the reader's `<style id="ss-theme">`, stamped `data-ss-theme` | Every token that is not semantic takes the theme's value (§4.16) |
| App appearance | `NSApp.appearance`: `nil` (Automatic), `.aqua` (Light) or `.darkAqua` (Dark) | followed through `prefers-color-scheme` | Picks Light or Dark for the app, never IC: Increase Contrast stays the system's |
| Increase Contrast | `bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])`; observe `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` | `prefers-contrast: more` **and** `html.ss-ic` | Every token switches to its IC value; focus rings grow to 3 pt; sheets, the stack, the quick-reply field, autocomplete, the link popover and the cheat sheet gain a 1 pt `ruleStrong` edge (`border.icOutline`); slips keep their own edge, `slipEdge`, whose IC values are stronger; hairlines draw at 1 pt (`border.hairline.widthHC`) |
| Reduce Motion | `accessibilityDisplayShouldReduceMotion` | `prefers-reduced-motion` **and** `html.ss-rm` | Movement becomes a 120 ms fade or nothing (§4.10) |
| Reduce Transparency | `accessibilityDisplayShouldReduceTransparency` | `prefers-reduced-transparency` **and** `html.ss-rt` | One app-drawn surface is translucent: the cheat-sheet `scrim` (§5.32). Under Reduce Transparency it is drawn opaque as `scrimSolid` (the colour the scrim gives over `canvas`), so the window behind is hidden instead of seen through; the panel on it is opaque `raised` either way. Every other app surface is already opaque and does not change; system menus, alerts and notifications adapt themselves. `ss-rt` is mirrored anyway so any future translucent shell surface has its opaque fallback in place |

The app mirrors the three NSWorkspace flags onto the reader's `<html>` as `ss-ic`, `ss-rm` and `ss-rt` whenever they change, because WebKit does not reliably track all three media queries; every shell rule is written for both the query and the class.

### 3.4 Selection and focus model

- The list's selection stays **emphasized** (the ink's wash and rule) whenever the main window is key, whichever view is first responder, because `KeyboardRouter` drives `j`/`k` from the list, the reader and the quick-reply field alike. It turns idle (`selWashIdle` + `selRuleIdle`) only when the window is not key.
- The reader shows its own focus on a message (the 2 pt ring) only after keyboard navigation (`n`/`p`, Tab). Which message R, A, F and Space act on is always shown, keyboard or mouse (the target message, §5.14).
- Tab order: rail (the selected folder, the selected account, Add, Settings) → list header controls (the masthead in minimal mode only, the Demo tag while it is on the line, search, compose) → list → sync line (only while it carries an action: Reconnect, Retry, Cancel; with Full Keyboard Access always) → reader actions → messages (stack rows, and inside each expanded sheet the order of §5.14) → quick reply → the day column while it shows (‹, Today, ›, the calendar toggle, the week button, the day cells as one stop, the events in time order, the foot's button; §5.54). While the week shows it takes the reader's and the column's place in the loop. Esc follows the precedence in §6.1.

**Window not key: exactly these marks change.** When a window resigns key, AppKit stops drawing keyboard focus in it, and Quire changes only:

| Mark | Key | Not key |
|---|---|---|
| Selection wash and margin rule (list rows, rail tile, Settings account row; the selected conversation's event in the day column and the week has the rule alone, §5.54) | `selWash` + `selRule` | `selWashIdle` + `selRuleIdle` |
| The quick reply's active-mode underline | `ink` | `ink3` |
| Primary buttons (Send, Save, an event's Join) | `accentFill` | secondary look (`raised`, `ruleStrong` edge, `ink` label), as native default buttons do |
| Focus rings | drawn on the first responder | not drawn (no first responder is shown in a non-key window) |

Every other mark in the ink stays as it is: the unread pip and unread time, badges, links, the selected token, checkbox and toggle on fills, the contrail and progress. Account inks (the kicker's dot, rings, the From dot) are not the ink and never change with key state either. Because text colours never depend on key state, `RowContentCache` does not key on it and a focus change redraws only the selection fill and rule of the selected rows.

### 3.5 One token set, three renderers

`docs/design/tokens.json` is the only source. A Swift script (no Node) generates the AppKit colour providers, font roles and metrics, the reader's CSS custom properties, and the XCTest files that assert every contrast pair and every account-palette rule. Details in §8.

---

## 4. Foundations

### 4.1 Colour

**Naming (1.8).** **The ink** names the accent role (`accent`, `focus`, `selRule` and their fills and washes); **Iron Gall** names Study's ink. Values below are Study's, the default theme. Every theme keeps each token's use and its luminance (§4.16); `originalPage` is never themed.

**Neutral ramp: paper to ink.** Warm grey, hue about 75°, chroma under 4. Surfaces from the back in light mode: `spine` (rail), `canvas` (reader desk), `paper` (list and headers), `sheet` (messages, fields), `raised` (keycaps, secondary buttons, popovers). Dark mode puts the desk and the rail below the paper, so sheets rise by lightness rather than shadow. The slip is dark in both appearances.

**Usage rules**

- Text uses only `ink`, `ink2`, `ink3`, or `onAccent`, `onSlip`, `onSlip2`, `onDanger`, `onSwipe` on their fills. `ink3` is the lightest text allowed; `inkDisabled` is for disabled controls only.
- **Placeholders for missing data** (“No subject”, “No sender”) are set in the role they replace, in `ink3` and italic (New York Italic or SF Pro Italic), never Semibold, so they never read as content or as unread: list rows, the reader headline, the stack and the sheet's name line. The composer window title reads “New Message” in the system title style; notifications, which macOS draws, use the plain words; VoiceOver reads “No subject”.
- **On a slip**, a resting action's keycap legend is `onSlip2`; while the action is hovered or pressed its legend switches to `onSlip`, because `onSlip2` falls below 4.5:1 on `slip + slipPressed`.
- `rule` is decorative (separators, pane dividers, sheet edges). Anything whose edge says what a control is or what state it is in (fields, search, checkbox, toggle-off track, secondary buttons, tags) uses `ruleStrong`, which is ≥ 3:1 against every surface it sits on, at rest, in every mode.
- Washes (`hover`, `pressed`, `fill`, `slipHover`, `slipPressed`) are ink at low alpha. The quiet-toggle on states (`accentWash`, `accentWashHover`, `accentWashPressed`) are opaque, tuned so `accent` labels keep 4.5:1 in every state. AppKit draws them as a fill over the surface; CSS layers them as `linear-gradient(var(--q-hover), var(--q-hover))` over the surface colour.
- The ink is split in two. `accent` is the mark colour (text, glyphs, pips, rules, rings) and is tuned against surfaces. `accentFill` is the fill colour (buttons, badges, checkbox and toggle on, selected token, menu highlight) and is tuned for white labels: in dark mode it is a deeper ink so fills stay quiet and labels stay light, instead of pastel fills with dark labels.
- The ink never fills an area larger than a button. Selection is a wash plus the margin rule, never a solid block.
- Semantic colours always arrive with a glyph and words (“Sign in required” with `exclamationmark.triangle.fill`), never a coloured word alone. Danger is red and lives far from every theme's ink (Iron Gall is teal-blue) and from every account ink.

**Surfaces**

| Token | Light | Dark | Light IC | Dark IC | Use |
|---|---|---|---|---|---|
| `spine` | `#ECE9E1` | `#121110` | `#E4E0D6` | `#080807` | Account rail (opaque) |
| `paper` | `#FBFAF6` | `#1C1B18` | `#FDFCFA` | `#121110` | List pane, list and reader headers, composer chrome, quick-reply bar, welcome |
| `canvas` | `#F4F2EC` | `#171614` | `#F1EFE9` | `#0D0C0B` | Reader desk behind sheets, Settings window background |
| `sheet` | `#FFFEFB` | `#24221F` | `#FFFFFF` | `#1C1B19` | Message sheets and stack, fields, composer body, Settings groups |
| `raised` | `#FFFFFF` | `#2C2A26` | `#FFFFFF` | `#252320` | Selected rail tile (folder or All Inboxes), secondary button face, keycaps, popovers, cheat sheet |
| `slip` | `#24221F` | `#36332E` | `#12100E` | `#2E2B27` | Toast, undo-send panel, g-sequence HUD (a dark slip in both appearances) |
| `slipEdge` | `#000000` @ 0% | `#FFFFFF` @ 10% | `#000000` @ 0% | `#FFFFFF` @ 45% | 1 pt edge around the slip in dark appearances |
| `knob` | `#FFFFFF` | `#DCD7CE` | `#FFFFFF` | `#FFFFFF` | Toggle knob face (its boundary is the 1 pt ruleStrong knob edge, layout.toggle) |
| `swipeRead` | `#726C65` | `#524D47` | `#625C55` | `#4F4A44` | Fill of a swipe's Mark as Read or Mark as Unread button (§5.7): a grey of the ramp, mid by day and low at night, quiet beside Archive on every row and dark enough for its white icon and label |
| `swipeArchiveNeutral` | `#24221F` | `#79736B` | `#12100E` | `#77716A` | Fill of a swipe's Archive button under Graphite and in Gallery (§5.7): the slip by day; at night a grey light enough to stand out from the row, which the slip sinks into, and dark enough for its white icon and label |
| `originalPage` | `#FFFFFF` | `#FFFFFF` | `#FFFFFF` | `#FFFFFF` | Page under a styled message shown in its original colours (drawn only in dark appearances: the sender designed for white) |
| `scrimSolid` | `#B8B6B1` | `#0B0B0A` | `#9C9A95` | `#050504` | The cheat-sheet scrim under Reduce Transparency: opaque, the value `scrim` gives over `canvas`, so the window behind is hidden instead of dimmed |

**Ink**

| Token | Light | Dark | Light IC | Dark IC | Use |
|---|---|---|---|---|---|
| `ink` | `#1D1B18` | `#EDE9E2` | `#0F0E0C` | `#FFFFFF` | Primary text, headlines, active quick-reply mode underline |
| `ink2` | `#55504A` | `#B8B2A8` | `#3A3631` | `#DCD7CE` | Secondary text and resting glyphs: snippets, recipients, labels, icons |
| `ink3` | `#625C55` | `#A8A297` | `#4A4540` | `#C8C2B8` | Tertiary text: times, running heads, placeholders, captions; idle selection rule |
| `inkDisabled` | `#A9A398` | `#5F5A53` | `#8A8479` | `#7D776F` | Disabled text and glyphs only (exempt from contrast minimums) |
| `onSlip` | `#F3F0EA` | `#EDE9E2` | `#FFFFFF` | `#FFFFFF` | Text and glyphs on the slip |
| `onSlip2` | `#B8B2A8` | `#C2BCB2` | `#D9D4CB` | `#DCD7CE` | Secondary text and glyphs on the slip; keycap legends on a resting slip action (onSlip while it is hovered or pressed) |
| `onSwipe` | `#FFFFFF` | `#FFFFFF` | `#FFFFFF` | `#FFFFFF` | Icon and label of a swipe's button (§5.7): white in every mode and theme, on every swipe fill, which are chosen for it |

**Lines**

| Token | Light | Dark | Light IC | Dark IC | Use |
|---|---|---|---|---|---|
| `rule` | `#E4E0D7` | `#34312D` | `#B9B3A8` | `#55514A` | Decorative hairline: row separators, pane dividers, sheet edges, header bottoms |
| `ruleStrong` | `#7F796F` | `#8B857B` | `#5E5952` | `#A39D93` | State-bearing 1 pt edge (>= 3:1): fields, search, checkbox, toggle-off track, secondary buttons, tags |
| `onSlipEdge` | `#F3F0EA` @ 45% | `#EDE9E2` @ 45% | `#FFFFFF` @ 50% | `#FFFFFF` @ 50% | Keycap outline, toast divider and the undo panel's resting action outline on the slip (>= 3:1 on slip) |

**Washes** (composited over the surface beneath)

| Token | Light | Dark | Light IC | Dark IC | Use |
|---|---|---|---|---|---|
| `hover` | `#1D1B18` @ 5% | `#EDE9E2` @ 5% | `#1D1B18` @ 7% | `#FFFFFF` @ 9% | Pointer hover wash (never on selected rows) |
| `pressed` | `#1D1B18` @ 9% | `#EDE9E2` @ 10% | `#1D1B18` @ 13% | `#FFFFFF` @ 15% | Pressed wash |
| `fill` | `#1D1B18` @ 6% | `#EDE9E2` @ 8% | `#1D1B18` @ 9% | `#FFFFFF` @ 12% | Quiet fill: count badge, quoted-text toggle, address token, toggle-off track, skeleton (a composer picture still being prepared) |
| `slipHover` | `#F3F0EA` @ 14% | `#EDE9E2` @ 12% | `#FFFFFF` @ 18% | `#FFFFFF` @ 20% | Hover wash on slip actions |
| `slipPressed` | `#F3F0EA` @ 22% | `#EDE9E2` @ 20% | `#FFFFFF` @ 26% | `#FFFFFF` @ 28% | Pressed wash on slip actions |
| `scrim` | `#1D1B18` @ 28% | `#000000` @ 50% | `#1D1B18` @ 40% | `#000000` @ 60% | Dimming behind the cheat-sheet overlay, the only app-drawn modal surface and the only translucent app-drawn surface (AppKit dims system sheets itself) |

**The ink: accent, selection, focus** (Iron Gall in Study)

| Token | Light | Dark | Light IC | Dark IC | Use |
|---|---|---|---|---|---|
| `accent` | `#1E5468` | `#6DB6C9` | `#123E4D` | `#93D3E3` | Iron Gall as a mark: unread pip, unread time, links, margin rule, progress |
| `accentFill` | `#1E5468` | `#2D788B` | `#123E4D` | `#246F83` | Iron Gall as a fill: primary button, unread count badge, checkbox/toggle on, selected token, NSAccentColor |
| `accentFillHover` | `#18475A` | `#307F93` | `#0D3240` | `#27788C` | Primary button hover; checkbox and radio on, hover (>= 3:1 on sheet and canvas, white label >= 4.5:1) |
| `accentFillPressed` | `#123A4A` | `#286C7E` | `#082733` | `#1F6375` | Primary button pressed only (darker in every mode, white label >= 4.5:1). Never a control's on fill: it falls below 3:1 on dark surfaces |
| `controlOnPressed` | `#123A4A` | `#368699` | `#082733` | `#2A7E95` | Checkbox and radio on, pressed: darker in light modes, lighter in dark modes, so the only mark of the on state keeps >= 3:1 on sheet and canvas (toggles show the press on the knob instead) |
| `onAccent` | `#FFFFFF` | `#FFFFFF` | `#FFFFFF` | `#FFFFFF` | Text and glyphs on accentFill |
| `swipeArchive` | `#1E5468` | `#2D788B` | `#123E4D` | `#246F83` | Fill of a swipe's Archive button (§5.7): accentFill by another name, apart only under Graphite and in Gallery, where it is swipeArchiveNeutral, since `ink` would turn light at night under the button's white icon and label |
| `accentWash` | `#DCE8EA` | `#1F363C` | `#C8DCE0` | `#1A4049` | On state of quiet toggles (Hide quoted text, Original colors action, composer format toggles) |
| `accentWashHover` | `#D2E2E5` | `#233D44` | `#BDD5DA` | `#1F4A55` | Quiet toggle on, hover |
| `accentWashPressed` | `#C8DBDF` | `#182D33` | `#B2CDD3` | `#15363E` | Quiet toggle on, pressed (darker in every mode: the toggle is pushed in) |
| `focus` | `#1E5468` | `#6DB6C9` | `#123E4D` | `#93D3E3` | Keyboard focus ring |
| `selWash` | `#D0E0E5` | `#213A41` | `#C2D6DC` | `#1A4049` | Selected row (main window key) and selected Settings account row (Settings key) |
| `selRule` | `#1E5468` | `#6DB6C9` | `#123E4D` | `#93D3E3` | 3 pt margin rule of the selection, window key |
| `selWashIdle` | `#EAE7DF` | `#2B2925` | `#DCD8CE` | `#302D29` | Selected row, window not key |
| `selRuleIdle` | `#625C55` | `#A8A297` | `#4A4540` | `#C8C2B8` | 3 pt margin rule of the selection, window not key (>= 3:1, always drawn) |

**Marks and semantics**

| Token | Light | Dark | Light IC | Dark IC | Use |
|---|---|---|---|---|---|
| `star` | `#7A5500` | `#E0B04A` | `#5E4100` | `#F0C565` | Star glyph (always the filled shape) |
| `success` | `#2D6A3E` | `#7BC58C` | `#1D522C` | `#9AD9A8` | Success text and glyph |
| `warning` | `#855200` | `#E3AE52` | `#653E00` | `#F2C374` | Warning text and glyph |
| `danger` | `#AE2A1F` | `#FF8B7B` | `#8C1C13` | `#FFADA1` | Error text and glyph, error field border |
| `info` | `#365693` | `#97B0E6` | `#24417A` | `#B8CBF2` | Info text and glyph |
| `successWash` | `#E5EFE5` | `#1D2E21` | `#D3E6D5` | `#1E3A25` | Success banner |
| `warningWash` | `#F6ECD8` | `#33291A` | `#EEDDBA` | `#3F311A` | Warning banner (Original colors notice) |
| `dangerWash` | `#F8E3DF` | `#3A201C` | `#F0CEC8` | `#4A231E` | Error banner, invalid token |
| `infoWash` | `#E4EAF5` | `#1E2638` | `#D0DAEE` | `#22304A` | Info banner |
| `findWash` | `#F2DF9F` | `#3E3420` | `#EFD893` | `#463A1E` | Every match of Find in conversation, behind text set in `ink` (opaque, so it reads on any page a sender designed) |
| `findCurrent` | `#EDBE45` | `#80600F` | `#E6B030` | `#7A5A0C` | The current match of Find in conversation, behind text in `ink`, with a 1 pt `ruleStrong` ring |
| `dangerFill` | `#AE2A1F` | `#C0392B` | `#8C1C13` | `#C0392B` | Destructive button, attention badge |
| `dangerFillHover` | `#9C251B` | `#C8402F` | `#7A170F` | `#C8402F` | Destructive button hover |
| `dangerFillPressed` | `#8A2018` | `#A93226` | `#68130C` | `#A93226` | Destructive button pressed |
| `onDanger` | `#FFFFFF` | `#FFFFFF` | `#FFFFFF` | `#FFFFFF` | Text and glyph on dangerFill |

**Accent states.** Primary buttons: rest `accentFill`, hover `accentFillHover`, pressed `accentFillPressed`, disabled `fill` with `inkDisabled` label (badges and the selected token use `accentFill` alone). `accentFillPressed` is darker in every mode, which keeps a white label at 4.5:1 but drops the fill itself to as low as 2.54:1 against the dark `sheet` and `canvas` (Dark IC); that is acceptable where the label carries the control, never where the fill is the only mark of a state. So checkbox and radio on fills press to **`controlOnPressed`** instead, darker in light modes and lighter in dark modes (≥ 3:1 on `sheet` and `canvas`, checkmark ≥ 3:1 on it), and toggles take no wash at all: a press stretches the knob, a shape change rather than a colour one (§5.26). In an inactive window a primary button loses its fill and draws as a secondary button, as native default buttons do.

**Selection**

| Situation | Fill | Margin rule (3 pt) | Text |
|---|---|---|---|
| Main window key (any first responder) | `selWash` | `selRule` | unchanged inks |
| Main window not key | `selWashIdle` | `selRuleIdle` (always drawn, ≥ 3:1) | unchanged inks |
| Graphite system accent, window key | `selWashIdle` | `ink` | unchanged inks |
| Pointer over a selected row | no hover wash (hover is suppressed on selected rows) | unchanged | unchanged |

Text never inverts on selection, so the attributed strings cached per row stay valid across `j`/`k`, no on-accent string variants are needed, and no row is rebuilt when the selection moves. The light wash is deliberately stronger than a tint (1.25:1 or more against `paper`, asserted in §7) so the current row is found at a glance after fast `j`/`k`; the 3 pt rule, the hidden separators around it and the unchanged ink do the rest, and the wash is tuned so `ink3` times still read at 4.5:1 on it. Every secondary item on a selected row (time, unread time, count badge, star, pip, queued glyph, failed glyph, account ring) is in the contrast table against both washes.

**Focus.** A 2 pt ring in `focus` (3 pt in Increase Contrast), drawn outside the control, separated by a 1 pt gap in the surface colour (2 pt around sheets and cards, 2 pt around anything filled with `accentFill`, so the ring never touches a fill of the same hue). It follows the control's corner radius plus the gap and is never animated. Fields use the same ring; a focused field never shows focus only as a 1 pt colour change. **Borderless field rows** (the composer's From, To, Cc, Bcc and Subject rows) have no edge to draw outside, so their ring is drawn **inset**, around the value area: from x = 78 (84 − 6) to 16 pt before the row's trailing edge (6 pt before the Cc / Bcc buttons while they show), its outer edge 3 pt inside the row's top and bottom, radius `r.sm` (§5.20). **One exception:** the composer body, a full-pane multi-line text view, shows focus by its insertion point (`accent`, asserted ≥ 3:1 on `sheet`) and its selection, as every macOS text view does; a ring around it would frame the whole window. No other focusable element is exempt. List rows and rail items show focus through the selection itself (the native Mac list convention); with Full Keyboard Access on and an empty selection the list draws the ring inset by 2 pt. On the slip, the ring is `onSlip` (`border.focusRing.onSlipColor`). Native SwiftUI controls are never left with the system ring (its alpha falls below 3:1 on `canvas`): Settings draws this ring itself (§8.3).

### 4.2 Account inks

Ten inks, assigned in this order as accounts are added, changeable per account in Settings › Accounts. Each mode has its own value: ≥ 3:1 against `paper`, `paper + hover`, `selWash`, `selWashIdle`, `spine`, `spine + hover`, `sheet`, `canvas` and `raised` in standard contrast, and ≥ 3.5:1 against the IC surfaces in Increase Contrast (each account pair in `contrastPairs` carries `need` 3 and `needIC` 3.5, asserted per mode). These are every surface a ring, dot, square, swatch or tile edge is ever drawn on: a pressed rail tile keeps the hover wash under its ring and darkens only the 30 pt face (§5.2), so `spine + pressed` never sits under an account ink; and inside a popup (the composer's From dot, the Settings Colour swatch) the dot or swatch keeps a 2 pt `raised` halo (`layout.popup.inkHalo`), so when the popup face takes `raised + hover` or `raised + pressed` the wash stops at the halo and the ink still meets `raised` (§5.27). `raised + hover` and `raised + pressed` therefore never sit under an account ink either. The day column and the week (§5.54) add four surfaces, each with its own pairs: each ink's own **event face** (the ink at 0.13 over `sheet`, `eventFace:` in `contrastPairs`), under its edge and a tentative event's outline; `paper + pressed`, a pressed day cell under its busy bars; and `canvas + hover` and `canvas + pressed`, the folded strip hovered, and pressed or open. The column opened over the reader's edge stays `paper`, so it puts the inks on nothing new. Light and dark values of one account keep the same hue, so the rail tile, the row ring and the kicker dot always read as one colour.

| # | Ink | Light | Dark | Light IC | Dark IC |
|---|---|---|---|---|---|
| 1 | Persimmon | `#C6590D` | `#D3631A` | `#AB5014` | `#E6732B` |
| 2 | Indigo | `#26365C` | `#7782AF` | `#1C2948` | `#8E91B2` |
| 3 | Lilac | `#8A7099` | `#E2C4F1` | `#7B6283` | `#E2C4F1` |
| 4 | Jade | `#006356` | `#46A595` | `#085348` | `#589D89` |
| 5 | Iris | `#5C42B5` | `#B797FF` | `#593EC4` | `#B797FF` |
| 6 | Fern | `#60825C` | `#B4D9AF` | `#5A7056` | `#D3E5D0` |
| 7 | Umber | `#562B1C` | `#AC7765` | `#483129` | `#BD8674` |
| 8 | Azure | `#027ECB` | `#2488D7` | `#1E6EAE` | `#6896CE` |
| 9 | Mulberry | `#623958` | `#A37697` | `#6C325A` | `#AD899D` |
| 10 | Graphite | `#626875` | `#A2A9B7` | `#585E6B` | `#AEB4C0` |

**Colour vision.** CIEDE2000 between every pair, after simulating protanopia, deuteranopia and tritanopia at full severity (Machado 2009, linear sRGB). The order was searched so the first six stay as far apart as possible for every vision type and the first two are the farthest pair; accounts 7–10 are chosen for normal-vision separation.

| Mode | Normal, all 10 | Protan, first 6 | Deutan, first 6 | Tritan, first 6 | Min CVD, first 6 | Closest pair in first 6 | Min over all four visions for the first k = 2…10 | Closest pair in all 10 |
|---|---|---|---|---|---|---|---|---|
| Light | 16.7 | 14.0 | 14.7 | 14.2 | **14.0** | Persimmon / Fern (protan) | 46 · 22 · 14 · 14 · 14 · 14 · 10 · 6 · 6 | Indigo / Mulberry (protan) |
| Dark | 14.9 | 14.2 | 14.7 | 14.2 | **14.2** | Indigo / Iris (protan) | 40 · 21 · 15 · 14 · 14 · 12 · 8 · 6 · 6 | Indigo / Mulberry (protan) |
| Light IC | 15.3 | 13.1 | 16.1 | 13.4 | **13.1** | Jade / Fern (protan) | 43 · 21 · 13 · 13 · 13 · 9 · 6 · 6 · 6 | Iris / Azure (deutan) |
| Dark IC | 13.2 | 13.6 | 13.3 | 13.8 | **13.3** | Indigo / Iris (deutan) | 35 · 16 · 15 · 13 · 13 · 6 · 6 · 6 · 6 | Jade / Umber (protan) |

**Distance from the colours with meaning.** No account ink is red, none sits within 15 ΔE of **any theme's ink** for normal vision (13 of Gallery's, which is its text ink, as under Graphite), none within 10 ΔE of danger under any simulation, none within 10 of info or 8 of the star. These are build-time assertions (§8.7).

| Mode | vs accent, normal (≥ 15) | vs accent, any CVD | vs danger, normal (≥ 10) | vs danger, any CVD (≥ 10) | vs info, normal (≥ 10) | vs star, normal (≥ 8) |
|---|---|---|---|---|---|---|
| Light | 15.7 (Graphite) | 4.7 (Jade) | 16.9 (Persimmon) | 10.4 (Persimmon) | 12.2 (Indigo) | 20.6 (Persimmon) |
| Dark | 16.0 (Jade) | 4.5 (Graphite) | 16.6 (Umber) | 10.2 (Jade) | 11.7 (Graphite) | 25.7 (Persimmon) |
| Light IC | 15.5 (Indigo) | 3.9 (Mulberry) | 16.7 (Persimmon) | 10.3 (Umber) | 10.2 (Indigo) | 17.6 (Umber) |
| Dark IC | 16.7 (Graphite) | 2.7 (Lilac) | 14.7 (Umber) | 10.1 (Fern) | 10.7 (Graphite) | 23.8 (Fern) |

**Distinct colours are promised for 6 accounts.** Identity never rests on colour alone:

- the reader kicker names the account in words next to its ink dot (the open conversation's account is always readable);
- the rail shows each account's monogram and `⌘1…⌘9` order; the list masthead shows the address when narrowed to one account;
- the row's VoiceOver label ends with the account name, and the avatar's tooltip names it;
- Settings › General › Rows › **Show account initials in unified views** adds a 16 pt initial tile before the time: no fill of its own (transparent, so the row's fill, rest, hover or either selection wash, shows through), the monogram's first letter in `tag` `ink2`, and a 1.5 pt edge in the account ink. It turns on automatically, once, when a 7th account is added, and Settings says why (an info banner in Accounts and a caption under the checkbox in General, §5.40);
- compact density marks the account with a 6 pt **square** filled with the account ink, kept apart from the round unread pip by shape.

The square and the tile's edge are drawn in the account ink, never in `ruleStrong`; they are covered by the account-ink pairs (every ink against `paper`, `paper + hover`, `selWash` and `selWashIdle`, §7), and the tile's letter by the `ink2` pairs on the same four fills.

**Monograms.** Each account's monogram derives from its domain: the first letter of the registrable label (`contoso.com` → C, `fabrikam.co.uk` → F); consumer domains use the provider letter (`gmail.com`, `googlemail.com` → G; `outlook.com`, `hotmail.com`, `live.com`, `msn.com` → O, and their regional domains such as `hotmail.co.uk`). On a collision the monogram becomes two letters: the first letter plus the first letter of the address's local part (two Gmail accounts → “Ga”, “Gm”), or, for two custom domains, the first two letters of the label (“Co”, “Cl”); when those agree too, the letter where the labels first differ (`contoso` and `cobalt` → “Cn”, “Cb”; `demo-gmail` and `demo-outlook` → “Dg”, “Do”), and for two addresses on one domain the local parts' letters (“Ca”, “Cs”), so every derived monogram is unique. Collisions are resolved in the rail's order (oldest account first), never in the order a surface happens to hold the accounts. The user can edit it in Settings (max 2 characters); a typed monogram always wins, and a derived letter it takes becomes two letters. The Monogram field's placeholder is what the account would derive with its own monogram cleared. The initial tile shows the first letter of the monogram the account shows.

**Account names.** Where the account is named in words (the kicker, the sync line and its tooltip, rail tooltips, the title menu, row VoiceOver labels, notifications, Settings), the name is the provider for a consumer address (“Gmail”, “Outlook”) and otherwise the registrable label as words in title case (“Contoso”, “Demo Outlook” for `demo-outlook.test`). Nothing is stored: monograms and names are derived by one SSCore helper, `AccountLabels`, which every surface asks, so an account wears the same monogram and name everywhere.

### 4.3 Avatar tints

Sender avatars use eight soft tints chosen by a stable hash of the lowercased address (FNV-1a 32-bit, modulo 8). Faces never take account colour, so a sender looks the same in every account. Initials: New York Semibold at 0.42 × the diameter (never below 10 pt), or under the SF Pro font (§4.4) the twin `monogramSans`, SF Pro Semibold at 0.39 × the diameter (never below 10 pt); at most two letters (first and last word of the display name, else the first alphanumeric of the address), in the tint's own ink. v1 faces are initials only: no Contacts access, no remote avatars, so no photo source exists and nothing on the face ever arrives late.

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

System families only: **SF Pro** (`NSFont.systemFont`, CSS `-apple-system, system-ui`), **New York** (`NSFontDescriptor.SystemDesign.serif`, CSS `ui-serif`), **SF Pro Rounded** (`.rounded`, CSS `ui-rounded`), **SF Mono** (`NSFont.monospacedSystemFont`, CSS `ui-monospace`). No bundled or web fonts. No UI text is smaller than 11 pt.

| Role | Family | Size (pt) | Weight | Line height (pt) | Tracking (pt) | Notes | Used for |
|---|---|---|---|---|---|---|---|
| `display` | New York | 34 | 600 | 40 | -0.6 | twin `displaySans` | Welcome title |
| `headline` | New York | 24 | 600 | 30 | -0.3 | twin `headlineSans` | Reader header subject (native) |
| `masthead` | New York | 20 | 600 | 24 | -0.2 | twin `mastheadSans` | List view title (Inbox, Starred…) |
| `title` | SF Pro | 15 | 600 | 20 | 0 |  | Sheet titles, Settings section titles, cheat-sheet title |
| `reading` | New York | 15 | 400 | 24 | 0 | twin `readingSans` | Plain and unstyled message bodies |
| `subject` | New York | 14 | 400 | 18 | 0 | 600 when unread, twin `subjectSans` | List row subject |
| `composeSubject` | New York | 15 | 400 | 20 | 0 | twin `composeSubjectSans` | Composer subject field |
| `aside` | New York | 17 | 400 | 24 | 0 | italic, twin `asideSans` | Empty-state sentence, welcome tagline |
| `writing` | SF Pro | 14 | 400 | 21 | 0 |  | Composer body, quick reply (read in serif, write in sans) |
| `body` | SF Pro | 13 | 400 | 18 | 0 |  | Controls, menus, settings, message-header name line, participants |
| `sender` | SF Pro | 13 | 400 | 16 | 0 | 600 when unread | List row sender line |
| `label` | SF Pro | 12 | 500 | 16 | 0 |  | Buttons, chips, quick-reply modes, field labels |
| `snippet` | SF Pro | 12 | 400 | 15 | 0 |  | List snippet, recipients, banners, collapsed snippet |
| `meta` | SF Pro | 11 | 400 | 14 | 0 | tabular digits | Times, sizes, sync line, captions |
| `runningHead` | SF Pro | 11 | 600 | 14 | 0 |  | Date dividers, reader kicker, section overlines |
| `tag` | SF Pro | 11 | 500 | 14 | 0 |  | Tags: Gmail, Microsoft 365, Demo |
| `badge` | SF Pro Rounded | 11 | 600 | 14 | 0 | tabular digits | Count badges |
| `kbd` | SF Pro | 11 | 500 | 14 | 0 |  | Keycaps; SF Pro carries the modifier glyphs |
| `mono` | SF Mono | 12 | 400 | 16 | 0 |  | OAuth client IDs, raw source |
| `buttonLarge` | SF Pro | 14 | 500 | 18 | 0 |  | Large button labels (welcome actions) |
| `monogram` | New York | 0.42 × d (min 10) | 600 | 1.0 × size | 0 | twin `monogramSans` | Avatar and rail initials (size = 0.42 x diameter, never below 10) |

**Sans twins.** New York covers Latin, Greek and Cyrillic. Every New York role has an SF Pro twin with the **same line height** and a smaller size (SF Pro's larger x-height makes it look the same size), used when New York cannot set the text and, under the SF Pro font, everywhere:

| Role | Family | Size (pt) | Weight | Line height (pt) | Tracking (pt) | Notes | Used for |
|---|---|---|---|---|---|---|---|
| `displaySans` | SF Pro | 31 | 600 | 40 | -0.4 | twin of `display` |  |
| `headlineSans` | SF Pro | 22 | 600 | 30 | -0.2 | twin of `headline` |  |
| `mastheadSans` | SF Pro | 18 | 600 | 24 | 0 | twin of `masthead` |  |
| `readingSans` | SF Pro | 14 | 400 | 24 | 0 | twin of `reading` |  |
| `subjectSans` | SF Pro | 13 | 400 | 18 | 0 | 600 when unread, twin of `subject` |  |
| `composeSubjectSans` | SF Pro | 14 | 400 | 20 | 0 | twin of `composeSubject` |  |
| `asideSans` | SF Pro | 16 | 400 | 24 | 0 | italic, twin of `aside` |  |
| `monogramSans` | SF Pro | 0.39 × d (min 10) | 600 | 1.0 × size | 0 | twin of `monogram` | Avatar and rail initials under the SF Pro font (size = 0.39 x diameter, never below 10) |

**Weight variants.** A role has exactly one weight unless a variant is listed here; each variant keeps its base role's size, line height and tracking. The generator emits them as roles (`QuireFont.bodyStrong`, `--q-font-bodyStrong`), so no component asks for “`body` at Semibold”.

| Role | Family | Size (pt) | Weight | Line height (pt) | Tracking (pt) | Notes | Used for |
|---|---|---|---|---|---|---|---|
| `metaMedium` | SF Pro | 11 | 500 | 14 | 0 | tabular digits, variant of `meta` | Sync-line lead phrase |
| `metaStrong` | SF Pro | 11 | 600 | 14 | 0 | tabular digits, variant of `meta` | Unread time in rows; inline actions in meta lines (Retry, Reconnect, Cancel) |
| `senderMedium` | SF Pro | 13 | 500 | 16 | 0 | 600 when unread, variant of `sender` | Names in collapsed stack rows |
| `bodyMedium` | SF Pro | 13 | 500 | 18 | 0 | variant of `body` | Toast message, undo-panel title, regular secondary / ghost / link button labels |
| `bodyStrong` | SF Pro | 13 | 600 | 18 | 0 | variant of `body` | Message name line, HUD title, Settings account name, regular primary / destructive labels, slip actions (Undo) |
| `labelStrong` | SF Pro | 12 | 600 | 16 | 0 | variant of `label` | Active quick-reply mode, small primary / destructive labels |
| `buttonLargeStrong` | SF Pro | 14 | 600 | 18 | 0 | variant of `buttonLarge` | Large primary / destructive labels |

**Button labels** use roles, never bare sizes: small `label` / `labelStrong`, regular `bodyMedium` / `bodyStrong`, large `buttonLarge` / `buttonLargeStrong` (the strong role for primary and destructive buttons; `layout.button.<size>.font` / `.fontStrong`).

Rules:

- **Read in serif, write in sans.** Composer and quick-reply bodies use `writing` (SF Pro) because what you type is sent without a font. Only the composer subject keeps the serif (`composeSubject`; its twin `composeSubjectSans` under the SF Pro font).
- **Script fallback.** A string is set in a New York role only if every letter in it is covered by New York's character set (`CTFontCopyCharacterSet` of the New York system font, computed once at launch). Otherwise the role's sans twin is used and the system cascade supplies the script (PingFang, Hiragino, Apple SD Gothic Neo, Geeza Pro, Arial Hebrew, Thonburi, Kohinoor Devanagari). The test runs when the row's attributed strings are built and is cached with them; the reader header runs it when the subject changes. Because twins keep the line height, row metrics never change; `RowMetricsTests` (§8.7) lays out CJK, Arabic, Hebrew, Thai and Devanagari samples and asserts the used height stays within the role's line height.
- **Bidirectional text.** Subjects, senders and snippets use natural writing direction with leading alignment (the UI's direction), so an Arabic or Hebrew subject reads right-to-left but stays flush with the column. CSS: `dir="auto"` with `text-align: start`.
- **Font setting.** Settings › Appearance › Font: New York (default) or SF Pro. It picks the face of every New York role across the app. Under SF Pro each role is set in its sans twin wherever it appears, in AppKit, SwiftUI and the reader: `display` → `displaySans`, `headline` → `headlineSans`, `masthead` → `mastheadSans`, `reading` → `readingSans` (plain and unstyled bodies), `subject` → `subjectSans` (unread weight kept), `composeSubject` → `composeSubjectSans`, `aside` → `asideSans`, and `monogram` → `monogramSans` (§4.3, §5.29). Under New York the script fallback above still decides per string. A change applies live: every window on screen, the pre-rendered reader views and every open composer redraw in the new face at once, with no relaunch and no reselection. Twins keep the line height, so line heights and row metrics never change, no row is reloaded or re-measured and nothing moves vertically; only text widths follow the face, so the masthead takes its new width and the header items after it (the Demo tag, the search field's leading edge) shift with it. HTML mail with its own fonts is never restyled.
- **Text size.** Settings › Appearance › Text size moves every role where mail is read and written by -1 / 0 / 1 / 2 pt, size and line height together (§4.15). The tables above are Default.
- **Unstyled bodies.** “Set like a page” applies to bodies classified at sync time, never at open. The sanitizer, which already walks the tree, stores one of three values with the body: `plain` (text/plain only), `unstyled` (HTML with no `<style>` blocks, no `font-family`, `font-size`, `color`, `background` or width declarations in `style` attributes, no `<font>` face/size/color, no `bgcolor`, no layout tables with explicit widths; only text structure such as `p`, `div`, `br`, `span`, `b`, `i`, `u`, `a`, `ul`, `ol`, `li`, `blockquote`, `pre`, `code`, `img`) or `styled` (everything else). Plain and unstyled bodies get `reading` (or `readingSans`) inside the 576 pt measure; styled bodies keep their own fonts at full sheet width. The value also records whether the body's letters are covered by New York (same rule as above); if not, `readingSans` is used.
- **Tabular digits** (`.monospacedDigit` / `font-variant-numeric: tabular-nums`) for times, counts, badges, sizes and progress, so columns do not jitter during sync.
- **Tracking** is in points at the stated size: AppKit `.kern`, CSS `letter-spacing` in px. A tracking of 0 means the system's own optical tracking. No role is uppercased: every label is set as it is written.
- **Line height** is exact. AppKit: `NSParagraphStyle.minimumLineHeight = maximumLineHeight = role line height`, `baselineOffset = (lineHeight − font line height) / 2` where the font line height is `NSLayoutManager().defaultLineHeight(for: font)`. CSS: `line-height` in px. AppKit and the reader then agree to the point.
- **Weights.** Regular 400, Medium 500, Semibold 600, only through the roles and variants above. Bold is not used (the alert title is system-drawn). Unread is Semibold (`unreadWeight`, and `metaStrong` for the unread time) so truncation moves little.
- **Truncation** is single line, tail, no tightening (`allowsDefaultTighteningForTruncation = false`); attachment names truncate in the middle to keep the extension.
- **Mapping from today's eight ad-hoc sizes:** 10 → `meta` or `runningHead` (11); 11 → `meta`; 12 → `snippet` or `label`; 13 → `body` or `sender`; 14 → `writing` or `subject`; 15 → `title` or `reading`; 17 and 26 → `aside` and `headline`.

### 4.5 Spacing

A 4 pt base with two optical half-steps. Use only these steps:

| Token | s1 | s2 | s3 | s4 | s5 | s6 | s7 | s8 | s9 | s10 | s11 | s12 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| pt | 2 | 4 | 6 | 8 | 12 | 16 | 20 | 24 | 32 | 40 | 48 | 64 |

Layout constants that are not on the scale (row 68, avatar box 38 at x 20, text column 68) are component metrics and live under `layout` with their components. Key rhythms: list inset 16; reader column margins at least 32; sheet padding 22 / 28 / 14; stack-to-sheet gap 12.

### 4.6 Radii

| Token | pt | Used for |
|---|---|---|
| `r.xs` | 3 | Tags, account initial tile, keycaps (18 / 16 pt), checkboxes, skeleton bars, the original-colours inset |
| `r.sm` | 5 | Small buttons, large keycaps, attachment type tiles, autocomplete rows, slip actions (toast and undo panel), small icon buttons, composer field-row focus ring |
| `r.md` | 6 | Regular buttons, fields, search, popups, icon buttons, banners, quoted toggle, strip chips |
| `r.lg` | 8 | Sheets, stack, attachment chips, toast, quick-reply field, large buttons, Settings groups, autocomplete, link popover |
| `r.xl` | 12 | Undo-send panel, HUD, cheat-sheet overlay |
| `r.tile` | 11 | Rail tiles (38 pt near-squircle) |
| `r.pill` | height / 2 | Badges, tokens, avatars, toggles, pips |

Every `radius` metric under `layout` is one of these values; the build fails otherwise. The only exceptions are tied to a size: the margin rule's 0 / 2 / 2 / 0 corners, the 1.5 pt corners of the 6 pt compact account square, and the 2 pt ends of the 4 pt progress bar (a pill). Window corners are the system's. AppKit uses `cornerCurve = .continuous` for rail tiles and panels and circular arcs for pills.

### 4.7 Borders and hairlines

- **Hairline** = one device pixel (`1 / backingScaleFactor` pt, 0.5 pt on Retina), colour `rule`: row separators (from x = 68; hidden on the selected row and the row above it), pane dividers, header bottoms, sheet and stack edges, composer field rows. Increase Contrast draws hairlines at 1 pt (`border.hairline.widthHC`).
- **Strong edge** = 1 pt `ruleStrong`: fields, search, checkbox and radio, toggle-off track, toggle knob, secondary buttons, popups, tags, the quick-reply field. Drawn at rest in every mode.
- **Tab underline** = 2 pt `ink` (`ink3` when the window is not key), sitting on the header hairline; the quick reply's active mode uses the same underline under its label.
- **Margin rule** = 3 pt wide, corner radii 0 / 2 / 2 / 0 (leading corners square), flush with the pane's leading edge.
- **Error edge** = 1.5 pt `danger`, always with a glyph and a help line.
- **Account ring** = 2 pt in the account ink outside a 2 pt gap in the surface colour.

### 4.8 Elevation

Paper is flat. Only things that float cast shadows; rows, the rail and the list never do. AppKit gives every shadowed layer an explicit `shadowPath`; two-shadow levels use a container layer (key shadow) plus one sublayer (contact shadow). CSS blur = 2 × `CALayer.shadowRadius`. The AppKit offsets below are for a bottom-up layer; the window server applies a flipped view's geometry to the shadow offsets of every layer in its tree, so in a flipped view (every Quire component is one) the same downward shadow is (0, +6). Only a window-server capture shows the direction truthfully: `cacheDisplay` renders some flipped hierarchies the other way. Increase Contrast keeps the shadows and adds the `ruleStrong` edge (`border.icOutline`) to sheets, the stack, autocomplete, the link popover and the cheat sheet; slips use their own `slipEdge`. A shadowed `NSPanel` (the undo-send panel) is transparent and larger than what it draws, by `layout.undoPanel.shadowMargin*`, so the shadow is never clipped. The toggle knob's static contact shadow is a control detail, not a level: `layout.toggle.knobShadow`.

| Level | Light (CSS) | Dark (CSS) | AppKit | Used for |
|---|---|---|---|---|
| `e0` | `none` | `none` | — | List, rows, rail, stack, fields, chips (hairline only) |
| `e1` | `0px 1px 2px rgba(29,27,24,0.06)` | `0px 1px 2px rgba(0,0,0,0.35)` | key layer: opacity 0.06 / 0.35, radius 1 / 1, offset (0, -1 / -1) | Open message sheet, selected rail tile (folder or All Inboxes) |
| `e2` | `0px 6px 20px rgba(29,27,24,0.14), 0px 1px 3px rgba(29,27,24,0.10)` | `0px 8px 24px rgba(0,0,0,0.50), 0px 1px 3px rgba(0,0,0,0.35)` | key layer: opacity 0.14 / 0.50, radius 10 / 12, offset (0, -6 / -8) | Toast, g-sequence HUD, autocomplete, link popover, dragged chip, dragged rail tile, the day column opened over the reader's edge, an event's details, the week's invitation card |
| `e3` | `0px 16px 40px rgba(29,27,24,0.18), 0px 2px 8px rgba(29,27,24,0.10)` | `0px 18px 48px rgba(0,0,0,0.60), 0px 2px 8px rgba(0,0,0,0.40)` | key layer: opacity 0.18 / 0.60, radius 20 / 24, offset (0, -16 / -18) | Undo-send panel, cheat-sheet overlay |

### 4.9 Materials

| Region | Material | Reduce Transparency | Why |
|---|---|---|---|
| Account rail | none: opaque `spine` | same | Badge, ring and glyph contrast must not depend on the wallpaper |
| Title-bar zones, list, reader, composer | none: opaque `paper` / `canvas` / `sheet` | same | Pages are opaque; opaque headers never re-blur during scroll |
| Toast, undo-send panel, HUD | none: opaque `slip` | same | Fixed contrast for the action text |
| The day column opened over the reader's edge, an event's details, the week's invitation card (§5.54) | none: opaque `paper` (the column, as in place) and `raised` (the cards), each with `e2` and a hairline edge | same | They float over the reader but stay pages: every pair they draw is one the column or a popover already has, and nothing behind shows through |
| Cheat-sheet overlay | `scrim` over the window (the one translucent app-drawn surface), opaque `raised` panel | `scrimSolid`, opaque: the window behind is hidden, not dimmed; the panel is unchanged | Fixed contrast; the scrim is a flat wash, never a blur, and Reduce Transparency takes away its see-through, not the overlay |
| Menus, alerts, tooltips, notifications, the Settings toolbar and its tabs | system materials | system | Native chrome |

There is no app-drawn vibrancy, no per-row blur and no `backdrop-filter` in the reader.

### 4.10 Motion

| Duration token | Value |
|---|---|
| `dur.instant` | 0 ms |
| `dur.quick` | 120 ms |
| `dur.standard` | 180 ms |
| `dur.slow` | 240 ms |
| `dur.reducedFade` | 120 ms |
| `dur.spinnerDelay` | 150 ms |
| `dur.skeletonDelay` | 300 ms |
| `dur.gHudDelay` | 500 ms |
| `dur.gSequenceWindow` | 2000 ms |
| `dur.toastLife` | 5000 ms |
| `dur.undoSendChoices` | 5000 ms / 10000 ms / 20000 ms |
| `dur.toastCoalesce` | 1000 ms |
| `dur.undoKeyGrace` | 10000 ms |
| `dur.undoSendDefault` | 5000 ms |
| `dur.sentConfirm` | 1500 ms |
| `dur.copiedConfirm` | 1500 ms |
| `dur.toastConfirm` | 2000 ms |
| `dur.stripNotice` | 3000 ms |
| `dur.spinnerTurn` | 900 ms |
| `dur.contrailSweep` | 1200 ms |
| `dur.printImageWait` | 3000 ms |
| `dur.nowTick` | 60000 ms |

| Curve token | cubic-bezier | CAMediaTimingFunction |
|---|---|---|
| `ease.settle` | cubic-bezier(0.2, 0.8, 0.2, 1) | (0.2, 0.8, 0.2, 1) |
| `ease.leave` | cubic-bezier(0.4, 0, 1, 1) | (0.4, 0, 1, 1) |
| `ease.glide` | cubic-bezier(0.4, 0, 0.2, 1) | (0.4, 0, 0.2, 1) |
| `ease.linear` | cubic-bezier(0, 0, 1, 1) | (0, 0, 1, 1) |

| Use | Duration | Curve | Reduce Motion |
|---|---|---|---|
| Toast in (rise 8 pt + fade) | `dur.standard` | `ease.settle` | fade `dur.reducedFade` |
| Toast out, tooltip-like reveals, cross-fades | `dur.quick` | `ease.leave` | same (fades are kept) |
| Message expand / collapse, quoted text unfold, the message under an invitation card unfold, fold row expand, recipients expand / collapse (§5.14) | `dur.standard` | `ease.settle` | instant |
| Search field width (the field only; the list does not resize) | `dur.standard` | `ease.glide` | the width snaps; the masthead and Demo tag cross-fade `dur.reducedFade` |
| Quick-reply growth: the bar's height, drawn **over** the web view; the web view's frame never changes, only its bottom inset, once per height change | `dur.standard` | `ease.glide` | instant |
| Toggle knob travel | `dur.quick` | `ease.glide` | instant |
| Undo-send panel in (rise 12 pt + fade), welcome → inbox | `dur.slow` | `ease.settle` | fade `dur.reducedFade` |
| g-sequence HUD in / out (fade, no rise; in at `dur.gHudDelay`, out when the `dur.gSequenceWindow` ends, §5.32) | `dur.quick` in, `dur.quick` out | `ease.settle` / `ease.leave` | same |
| Cheat sheet in: scrim fade + panel fade and scale 0.98 → 1 | `dur.standard` (scrim `dur.quick`) | `ease.settle` | fade only, `dur.reducedFade` |
| Cheat sheet out | `dur.quick` | `ease.leave` | same |
| Header hover actions and the sender address appearing on hover (fade) | `dur.quick` in, instant out | `ease.settle` | same |
| The copied mark (§5.14): in at once, held `dur.copiedConfirm`, out as a cross-fade | `dur.instant` in, `dur.quick` out | `ease.leave` | same (fades are kept) |
| Link popover in / out (fade) | `dur.quick` | `ease.settle` / `ease.leave` | same |
| Undo countdown and toast lifetime (the contrail) | the window itself | `ease.linear` | steps once per second |
| Spinner | `dur.spinnerTurn` per turn | `ease.linear` | keeps turning |
| Row swipe (§5.7): the row follows the fingers; let go, or closed by a close rule, it settles open or closed; a full swipe's (or a click's) Archive slides the content the rest of the way out | the gesture; the settle `dur.standard`; Archive out `dur.quick` | `ease.settle`; out `ease.leave` | no settle and no slide: the row is at once where it settles; it still follows the fingers, as a scroll does |
| Instant, always: rail show / hide (the split view snaps; no pane resizes over frames), autocomplete open / close and row highlight, skeleton → content in the list and in a sheet, format row show / hide, Settings tab switches (system), badge and count changes; the day column and the week shown or hidden, the column folding to its strip or opened over the reader's edge, a day or a week turned, events arriving or moving, an event's details and the week's invitation card (§5.54) | `dur.instant` | — | — |

Rules:

- **The list never animates, and nothing resizes it over frames.** Selection, `j`/`k`, opening a conversation (an instant swap of a pre-rendered view), scrolling, rows arriving or leaving through sync, archive and trash removal (the next row takes the place in the same frame, after a swipe too), star and unread changes, counts and badges: all instant. A swipe moves the one row under the fingers and nothing else (§5.7). The rail toggle is instant for the same reason: animating the split view would re-lay out and re-truncate every visible row and re-measure every iframe on each frame. The toast carries the feedback.
- **The keystroke finishes motion.** Every key press first calls `finishAll()`, which jumps running animations to their end state (`CATransaction` with actions disabled on the presentation values, CSS transitions set to their end), then applies the new action. Holding `j` never queues motion.
- **Expanding a message: animate to a provisional height, then snap.** A body iframe is created on expand and sizes itself only after it loads (the shell measures at 0, 50 and 300 ms and on every image load), and CSS cannot transition to `height: auto`. So the body wrapper animates, over `dur.standard` `ease.settle`, from the collapsed 44 pt row to header + **provisional body height** + footer, where the provisional height is the body's last measured height for this message at this content width (the shell keeps it, per message id and width, for the session), or else the skeleton's height (three 10 pt bars 14 pt apart = 58 pt) with the skeleton drawn in it. When a measurement arrives, mid-animation or later, the wrapper **snaps** to it without animation (transition removed for that frame), and so does every later re-measure; when the animation ends the wrapper is set to the measured height in px (never `auto`, so the next collapse has a start value). Collapse animates from the current height to 44 pt and detaches the iframe at the end. `finishAll()` jumps a running expand to its provisional (or measured) end state and a collapse to its collapsed state. Reduce Motion: no height animation; the sheet appears at the provisional height and snaps when measured. The quoted-text unfold and the fold row use the same rule with their own measured heights.
- **Interruptible.** Every animation starts from the current presentation value (`fromValue = layer.presentation()`, `NSAnimationContext` with `allowsImplicitAnimation`, CSS transitions re-targeted). Nothing blocks input while it animates. Nothing exceeds `dur.slow`. Nothing loops except progress indicators; skeletons never shimmer.
- **The contrail means time is moving.** It is the only drawn element for elapsing time: the undo-send countdown (in the panel and in the quick-reply strip, always next to the seconds as text), the toast's lifetime (pauses while the pointer rests on the toast), the sync line's download progress and the attachment upload/download progress. It is never decoration. The calendar's now line is not a contrail: it marks a moment, not time running out, and moves once a minute as a plain redraw, never as an animation (§5.54).
- **Reduce Motion.** Rises, slides, scales, height changes and width changes become a `dur.reducedFade` cross-fade or are instant, as the table's last column says; fades stay. The contrail steps once per second instead of draining continuously, and every countdown also shows its seconds as text (“Sending in 4 s”), in AppKit and the reader alike. Spinners keep turning (they are essential and small).

### 4.11 Iconography

SF Symbols, monochrome; status glyphs use the `.fill` variant in their semantic colour.

**Defaults** (`layout.iconSize`), Regular weight unless noted: 15 pt for window-level icon buttons (reader header actions, the composer bar, the rail's Add and Settings); 14 pt inside text buttons, chips, banners, tool rows and format toggles; 12 pt **Semibold** in rows and the sync line (so the small size holds up); 18 pt for the rail's All Inboxes glyph. **Exceptions**, each a named metric of its component and the only other sizes in use: the compose button's `ss.nib` at 18 pt (`listHeader.composeGlyph`: the list header's one verb, sized against the 20 pt masthead on its line); the rail's folder symbols at 16 pt (`rail.folderGlyph`: SF Symbols fill more of their box than the custom `ss.quire`, so 16 pt reads as the same size beside it); the masthead chevron at 9 pt **Semibold** (`listHeader.chevron`: a disclosure mark, Semibold so 9 pt holds); popup chevrons, and the `chevron.down` of Send's drop-down (§5.23), at 12 pt (`popup.chevron`); the attention badge's `exclamationmark` at 9 pt **Semibold**; dismiss and remove `xmark` at 9 pt (`banner.dismissGlyph`, `composer.removeGlyph`, `search.clearGlyph`); the sheet's header hover actions at 14 pt on 24 pt buttons (`reader.headerActionGlyph`); the toast glyph at 14 pt and the undo panel's at 15 pt. The Settings toolbar tabs are system-drawn at the system's size.

Glyph colour: `ink2` at rest, `ink` on hover and press, `inkDisabled` when disabled; the star is `star` **and** filled when on. Menu items carry their symbol leading in `ink2`.

| Action | Symbol | Shortcut |
|---|---|---|
| Archive | `archivebox` | E |
| Move to Trash | `trash` | # |
| Mark as Spam | `xmark.bin` | ! (§5.47) |
| Move to Inbox (in Trash) | `tray.and.arrow.down` | ⇧I |
| Star / Unstar | `star` / `star.fill` | S |
| Mark as Unread / Read | `envelope.badge` / `envelope.open` | U |
| Reply / Reply All / Forward | `arrowshape.turn.up.left` / `arrowshape.turn.up.left.2` / `arrowshape.turn.up.right` | R / A / F |
| New Message | `ss.nib` (custom) | C, ⌘N |
| Search | `magnifyingglass` | / or ⌘F |
| Undo | `arrow.uturn.backward` | Z or ⌘Z |
| Send | `paperplane` (button), `paperplane.fill` (undo panel) | ⌘↩ |
| Attach | `paperclip` | ⇧⌘A |
| Format (toggles the format row) | `textformat` | ⇧⌘T |
| Bold / Italic / Underline | `bold` / `italic` / `underline` | ⌘B / ⌘I / ⌘U |
| Bulleted list / Numbered list / Quote | `list.bullet` / `list.number` / `text.quote` | ⇧⌘8 / ⇧⌘7 / ⌘' |
| Link | `link` | ⌘K |
| Open in composer | `arrow.up.left.and.arrow.down.right` | ⇧⌘R |
| Load images | `photo` | ⇧⌘I |
| Original colors | `circle.lefthalf.filled` | ⇧⌘O |
| Show / Hide quoted text; Show / Hide message under an invitation card (§5.14) | `ss.elide` (custom) | . |
| Quick Look the target message's attachments | — (system Quick Look) | Space (§6) |
| Download: an attachment chip's button, Download all, File › Download Attachments, the saved toast (§5.17, §5.30) | `arrow.down.circle` | ⇧⌘D (all of the target message's) |
| All Inboxes | `ss.quire` (custom) | ⌘0 |
| Account N | monogram | ⌘1…⌘9 |
| Add account / Settings | `plus` / `gearshape` | — / ⌘, |
| Provider choice (add-account menu items, welcome buttons) | `person.crop.circle.badge.plus` | — |
| Attention badge (rail tile needs sign-in) | `exclamationmark` (9 pt, `.semibold`, `onDanger`) | — |
| Waiting to sync (Settings account status) | `clock` | — |
| Login item needs approval (Settings › General › At login) | `info.circle` | — |
| Notifications or the Dock badge kept off by macOS (Settings › General › Notifications) | `bell.slash` | — |
| Discard Draft (Drafts reader, composer Message menu) | `trash` | # in Drafts |
| Remove account (Settings) | `minus` | ⌫ in the account list |
| Show / hide rail | `sidebar.left` | ⌃⌘S |
| Title menu (minimal mode), Send's drop-down (§5.23) / popup | `chevron.down` / `chevron.up.chevron.down` | — |
| Views (the rail's folder tiles, the title menu, View menu): Inbox, Starred, Sent, Drafts, Trash, All Mail | `tray`, `star`, `paperplane`, `doc`, `trash`, `archivebox` | G I, G S, G T, G D, G #, G A |
| Outbox (the rail's tile, the title menu and the View menu, only while a message is on its way, §5.2, §5.53) | `tray.and.arrow.up` | G O |
| Queued locally (row) | `ss.queued` (custom) | — |
| Operation failed (row), error, sign-in | `exclamationmark.triangle.fill` | — |
| Up to date / Offline / Retrying / Retry | `checkmark` / `wifi.slash` / `clock` / `arrow.clockwise` | — |
| Remove (token, attachment) | `xmark` | ⌫ |
| Files | `doc`, `doc.richtext`, `photo`, `tablecells`, `doc.zipper`, `film` | — |
| More | `ellipsis` | — |
| Settings tabs (system toolbar) | `person.crop.circle`, `key`, `gearshape` | — |
| Undo confirmation (toast) | `arrow.uturn.backward` | — |
| Privacy note / success / info | `lock` / `checkmark.circle.fill` / `info.circle` | — |
| Show / hide a secret (the secure field's reveal button, §5.25) | `eye` / `eye.slash` | — |

The full action-to-symbol map is `icon` in `tokens.json`: every symbol the app draws is in it, and a symbol that is not in it is not used.

**Custom glyphs (five of the six allowed; one slot stays free).** Drawn on the stated grid, round caps and joins, in the current colour. They scale with point size (grid units × point size / grid). Exact SVG path data (y down):

`ss.quire` — All Inboxes, a gathering of letters. 16 × 16 grid, stroke 1.5, no fill.
```
M2.75 6.25h10.5a1 1 0 0 1 1 1v5.5a1 1 0 0 1-1 1H2.75a1 1 0 0 1-1-1v-5.5a1 1 0 0 1 1-1z M2.1 7 8 10.6 13.9 7 M3.5 3.75h9 M5.25 1.5h5.5
```

`ss.nib` — New Message, a pen nib. 16 × 16 grid, stroke 1.5, plus a filled circle (the vent) cx 7.47 cy 8.53 r 0.9.
```
M2.91 13.09 L4.32 7.01 C4.43 6.27 4.99 5.7 5.67 5.53 L8.64 4.68 L11.32 7.36 L10.47 10.33 C10.3 11.01 9.73 11.57 8.99 11.68 Z M10.47 2.56 L13.44 5.53 L11.46 7.51 L8.49 4.54 Z M2.91 13.09 L6.66 9.34
```

`ss.elide` — Show / Hide quoted text, and Show / Hide message under an invitation card, the editor's `[…]`. 16 × 16 grid, stroke 1.5, plus three filled circles cx 5.6 cy 10.6 r 0.95, cx 8 cy 10.6 r 0.95, cx 10.4 cy 10.6 r 0.95.
```
M4.75 2.75h-2v10.5h2 M11.25 2.75h2v10.5h-2
```

`ss.queued` — queued locally: the change is applied on this Mac and waiting to reach the server. A dot (here) and a straight arrow (on its way), with clear space between them. It is static, has no circle and never rotates, so it cannot be read as a spinner or as refresh; rows never show spinners. 12 × 12 grid, stroke 1.5, plus a filled circle cx 2.75 cy 9.25 r 1.6.
```
M5.75 6.25 9.75 2.25 M6.25 2.25h3.5v3.5
```

`ss.paperPlane` — the brand mark, the **paper plane** (welcome, inbox zero, and through the app icon About, alerts and notifications): one sheet of paper folded into a dart and drawn on an isometric grid, which says mail at a glance. It is three straight-edged triangles: the far wing (N, WF, T) and the near wing (N, S, WN), which meet at the nose N, and the keel (X, Sk, K). 80 × 80 grid, one unit to an 8 px unit of the app icon's 1024 template, every vertex a whole unit: N (80, 10), WF (0, 30), T (16, 38), S (20, 40), WN (40, 50), Sk (20, 43), X (38, 52), K (20, 70). The trailing edge WF–T–S–WN is one straight line at 1:2 (26.6°), and the spine N–S, the plane's axis, runs at 1:2 too; the far leading edge N–WF rises 1:4 (14°); the near wing's leading edge N–WN and the keel's foot X–K lie on one 45° line, so the keel is flush with the wing; the keel's top Sk–X runs at 1:2, parallel to the trailing edge, and its back S–Sk–K is vertical. Two folds cut the outline: between the wings, N–T against N–S, a wedge that opens from nothing at the nose to (4, 2) at the tail, about 3.6 units across; and above the keel a gap 3 units tall (about 2.7 across) that keeps its width. The plane's box is 80 × 60, from (0, 10) to (80, 70), centred on the grid. Filled (nonzero), one path of three subpaths that never overlap; every edge is a straight segment (`M L Z` only).
```
M80 10 L0 30 L16 38 Z M80 10 L20 40 L40 50 Z M38 52 L20 43 L20 70 Z
```

The mark's rules hold everywhere it is drawn: black and white only, straight edges and sharp corners, the three triangles and both folds kept, the nose up and to the right, never mirrored, rotated, outlined, rounded or shaded, and nothing added to it: no ring, badge, trail, letter or second colour. One colour in the interface, and never a theme's: on the welcome screen the brand's own ink, `layout.brand.ink` (`#0A0A0A`) on a light page and its paper (`#FFFFFF`) on a dark one, like the wordmark under it, in every theme and under Increase Contrast and Graphite; at inbox zero the system's secondary label grey (`secondaryLabelColor`, laid over the paper at its own alpha), the grey the identity tints the one-colour mark with, where the mark is a quiet reward rather than a greeting. The interface draws it as a template image, the plane across the full width of its square, never smaller than 40 pt (64 on the welcome screen); below 24 pt the folds close up, which is why the app icon's 16 and 32 px images are separate pixel-fitted masters (§5.42). The mark is never set beside the product's name in a font: the name drawn with the mark is the wordmark, from its outlines (`layout.brand.wordmark`, docs/brand), as on the welcome screen (§5.39).

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
| `xmark` | the Original colors notice's dismiss button, 9 pt (§5.16) |
| `photo` | remote-images banner glyph (§5.16); image attachment tile (§5.17) |
| `exclamationmark.triangle.fill` | partial image failure, attachment error, body-failed banner, a cancelled invitation's kicker (§5.14, §5.16, §5.17) |
| `wifi.slash` | the body-not-downloaded-while-offline notice (§5.14) |
| `doc`, `doc.richtext`, `tablecells`, `doc.zipper`, `film` | attachment type tiles (§5.17) |
| `calendar` | the invitation card's kicker (§5.14) |
| `checkmark` | the chosen answer on the invitation card; the copied mark (§5.14) |
| `info.circle` | the invitation card's permission notice (§5.14) |
| `arrow.down.circle` | an attachment chip's Download button (§5.17) |
| `paperclip` | a message with attachments, in its stack row and its sheet header, as in the list row (§5.13, §5.14) |

The quoted-text toggle, the message's mark under an invitation card and the folded original use the custom `ss.elide` (inline SVG); spinners and skeleton bars are CSS; keycaps are text. Each symbol is rasterised with `NSImage(systemSymbolName:)` + `SymbolConfiguration(pointSize: 20, weight: .regular)` at 3× into black-on-clear PNGs on a square canvas 1.3 × the point size, encodes each once as a `data:` URI and passes them to the shell builder, which emits them as CSS custom properties (`--sym-xmark: url(data:…)`). The shell draws them as `mask-image` with `background: currentColor`, so they take any token colour in any appearance. The specimen uses exactly this pipeline.

### 4.12 Density

| | Standard (default) | Compact (View › Compact Rows, ⌥⌘C) |
|---|---|---|
| Row height | 68 (64 / 68 / 72 / 76 by Text size, §4.15) | 48 (44 / 48 / 52 / 56) |
| Lines | sender · time / subject / snippet | sender · time / subject - snippet |
| Avatar | 30 pt face in a 38 pt box | none |
| Account mark (unified views) | 2 pt ring (+ optional initial tile before the time) | 6 pt square before the time; with **Show account initials** on, the 16 pt initial tile **replaces** the square (it carries the colour and the letter) |
| Text column | x = 68 | x = 24 |
| Running head | 28 pt, label x 20 | 24 pt, label x 24, y 5, rule y 12 |
| Skeleton row | circle + four bars (§5.10) | no circle; sender, time and line-2 bars (`layout.rowCompact.skeleton*`) |
| List tail footer | 28 pt | 28 pt |

The reader has one density.

### 4.13 Voice and microcopy

- **Plain, short, calm.** No exclamation marks, no “Oops”, no emoji, no “please”.
- **Casing follows the surface, not the control.** **Title case** where macOS itself names commands: menu items (including context menus and the More menu), alert and sheet buttons, popover buttons, window and panel titles, tooltips (they repeat the command's menu name), and buttons in Settings. **Sentence case** for everything set inside a content surface: the list (empty states, the tail footer), the reader (banners and their actions, the quoted-text toggle, footer buttons, the quick reply, its tabs and its strip), the composer's content (field labels, status, the drop label; its one chrome button is “Send”), slips (toast and undo-panel actions), the g-sequence HUD and the keyboard cheat sheet (their labels describe what a key does rather than naming a menu command: “Mark as unread · read”, “Show · hide quoted text”, “Move to Trash”, where Trash is a proper name; the overlay's title “Keyboard Shortcuts” is a panel title and stays title case), the welcome screen, banners in any window (Settings included), status lines and captions. Proper names keep their capitals (Settings, Gmail, Microsoft 365, Quick Look, Trash, Inbox). Sentence-like links stay sentences (“How to create one…”, “Set up OAuth clients…”). One command can therefore appear in both forms, deliberately: Message › Reply All and the tooltip “Reply All  A”, but the footer button “Reply all”; View › Load Images and the banner action “Load images”; Message › Discard Draft… and the Drafts footer “Discard draft…”.
- **Verbs on buttons.** “Send”, “Discard”, “Reconnect”, “Load images”. Never “OK” when a verb exists.
- **Past tense plus one remedy** in toasts: “Archived · Undo”, “Moved to Trash · Undo”, “Moved to Inbox · Undo”, “Unstarred · Undo” (in Starred, where the row leaves the view), “Marked 3 as unread · Undo”, “Snoozed until Tue 09:00 · Undo”, “Marked as spam · Undo”. Coalesced: “Archived 3 conversations”. Only actions that take a row out of view, or change several rows at once, get a toast, and so does time set aside on a calendar or removed from it (“Blocked Fri 10:00 - 10:30 · Undo”, §5.54), which no row shows and which may land on a day not on screen; starring or marking one conversation unread does not, because the row itself shows the change. Such a change is still undoable: Z reaches it for the grace period, and ⌘Z for as long as the undo history holds it (§6.1). A copy gets an inline mark, “Copied”, not a toast: nothing leaves the view and nothing can be undone (§5.14).
- **What cannot be undone comes first.** An unsubscribe's toast names the request, then the archive Undo takes back: “Unsubscribe sent · Archived · Undo” (§5.30).
- **An undo confirms itself** with an action-less toast naming the undone command as Edit › Undo does: “Undid Archive”, “Undid Move to Trash”, “Undid Mark as Unread”, “Undid Snooze” (`arrow.uturn.backward`, 2000 ms, §5.30).
- **Errors say what happened and what happens next:** “Couldn't reach Gmail · retrying in 30 s”, “Sign in required · Reconnect”, “Couldn't send · Open draft”, “Couldn't archive. Restored.” Never blame the user.
- **The separator** is the middle dot with spaces ( · ). The ellipsis is the single character (…), for commands that ask for more (“Add Account…”) and for ongoing work (“Sending…”).
- **Numbers** use the locale's grouping (“3,412 of 8,120”) and a space before units (“240 KB”, “4 s”). Unread counts are the exception: wherever one shows (the rail, the title menu, the Dock) it reads “99+” above 99, and nothing at zero (§5.28).
- **Times** follow the system 12/24-hour setting and the locale's day and month order. Rows under running heads show what the head leaves out:

| Running head | Row time |
|---|---|
| Today, Yesterday | time of day: “23:39” |
| Earlier this week | weekday: “Tue” |
| Last week, a month (“October”), a month of an earlier year (“October 2025”) | day and month: “27 Oct”, “30 Oct” (the year is in the head) |
| No heads (search results, views under 8 conversations) | today “23:39”, yesterday “Yesterday”, this week “Tue”, this year “30 Oct”, older “30 Oct 2025” |
| Later (no heads: its times are ahead) | when it comes back: today “Back 15:00”, within the next six days “Back Tue 09:00”, this year or less than eleven months ahead “Back 16 Nov 09:00” (a day and month ahead can only mean the coming one), later “Back 16 Nov 2027 09:00” |

  The reader shows “Yesterday 23:39”, “Fri 30 Oct”, “30 Oct 2025”.
- **Sender lines by view:** Drafts “Draft to Ben Carter”, Sent “To Ben Carter” (the prefix in `ink2`).
- **Empty states** are one serif sentence and one hint: “Nothing left to read.” / “New mail will land here.” Every view and reader state has its pair in §5.9.
- **Privacy copy** is literal: “Your mail is stored on this Mac and travels only between this Mac and Google or Microsoft.”
- **VoiceOver announcements** repeat the toast: “Archived. Press Z to undo.”, “Undid Archive.”
- **Demo copy** says what is made up and where it lives: “Demo mode: these mailboxes are made up and live only on this Mac.”

### 4.14 Accessibility summary

- Contrast: every text pair ≥ 4.5:1 and every essential non-text pair ≥ 3:1, in all four modes, over every surface and state overlay the components produce (§7). Disabled controls are exempt and use `inkDisabled`.
- Minimum text size 11 pt; avatar initials never below 10 pt.
- Hit targets: at least 24 × 24 pt for every pointer target, enlarging the hit rect where the visual is smaller (search clear, attachment and token remove, small buttons, link buttons, header hover actions, the notice dismiss button, Settings +/−); rail tiles 44 pt, rows full width.
- Full keyboard operation; every focusable element shows the ring (§4.1).
- VoiceOver rows: “Unread. Starred. Priya Raman. Lisbon in March? Booked the flat… 22:10. 3 messages. Gmail account.” Queued rows add “Waiting to sync”; failed rows add “Couldn't archive”. A row's actions are its swipe's, Archive first, where they apply (“Archive”, “Mark as Read” or “Mark as Unread”, §5.7). Running heads are headings. Custom glyph buttons carry the action name as `accessibilityLabel`.

| State | Colour cue | Non-colour cue |
|---|---|---|
| Unread | the ink's pip and time | the pip's presence, Semibold sender, subject and time |
| Selected | `selWash` | 3 pt margin rule, always drawn |
| Autocomplete highlight | `selWash` | 3 pt margin rule (never a solid accent block) |
| Window not key | `selRuleIdle` | grey traffic lights, rule colour, idle wash |
| Starred | `star` | filled star vs outline |
| Queued locally | `ink3` glyph | `ss.queued` shape, VoiceOver “Waiting to sync” |
| Operation failed | `danger` glyph | triangle shape, toast text |
| Account | ring ink | kicker words, monogram, optional initial tile, compact square, tooltip, VoiceOver |
| Invalid address | `danger` wash and edge | triangle glyph inside the token |
| Error | `danger` | glyph and words |
| Toggle on | `accentFill` track | knob position: the knob carries a 1 pt `ruleStrong` edge, ≥ 3:1 against the off track on a group and on the desk; nothing ever washes the track or the knob (a press stretches the knob), so the cue holds in every state |
| Checkbox / radio on | `accentFill` (hover `accentFillHover`, pressed `controlOnPressed`) | the checkmark, mixed bar or dot shape |
| Quick-reply mode | `ink` label | 2 pt underline, Semibold (`labelStrong`) |
| Target message (R, A, F, Space) | — | R · A · F keycaps beside its footer buttons; a `ruleStrong` sheet edge when several messages are open |
| Missing subject or sender | `ink3` | italic, the words “No subject” / “No sender” |
| Demo mode | — | “Demo” tag text, window title, Settings banner words |
| Active tab | `ink` text | 2 pt underline, Semibold |
| Focus | `focus` ring | ring shape, 3 pt in IC; inset ring on borderless composer rows; the insertion point in the composer body (§4.1); a Quire ring on links inside message bodies (§8.4) |
| Link button | `accent` label | position and verb; the underline on hover and press, and at rest under Graphite and where the theme's flag says so (§3.1, §4.16) |

### 4.15 Text size (Q2.6)

Settings › Appearance › **Text size**: a popup of Small, Default, Large and Larger (`textSize.names`) that moves every role where mail is read and written by -1 / 0 / 1 / 2 pt (`textSize.deltas`), and ⌘+ / ⌘− for the reader alone. macOS gives apps no text-size preference; this is the one Quire has, and the 11 to 14 pt the list and the reader set by default are small for some eyes.

- **The step.** A role's size and its line height move together, so each role keeps its leading; weight, tracking and family stay. No text goes below 11 pt: at Small the 11 pt roles (`meta`, `runningHead`, `tag`, `badge`, `kbd` and their variants) keep their size and line height. Twins move with their roles, so a twin still shares its role's line (§4.4) and a Font switch still moves nothing. Monograms follow the face's diameter, which no Text size changes (§5.29).
- **Where it applies.** The mail: the list's rows, running heads and skeleton rows (§5.7, §5.8, §5.10); the reader, whose headline, sheets, collapsed rows, chips, invitation card and plain and unstyled bodies take the step through its CSS (§5.12, §8.4), the boxes a sheet header's lines sit in growing with them (`--q-step-<role>`), while styled HTML keeps its own sizes as it keeps its own fonts; the quick reply (§5.18: its field gains the step per line, so the bar at rest is 60 pt at Default and a point less or up to two more, and the face, the R keycap and the send button stay centred on the field at rest); a composer's subject and body (§5.20: its rows keep their heights) and the folded original under them. Everything drawn around a line of chrome keeps Default, because its bands and controls are sized for that line: the rail, the list header and its masthead, the sync line, the list's tail footer and server row, the reader's kicker and actions, buttons, fields, popups, tags, badges and keycaps, toasts, the undo panel, the HUD and the cheat sheet, empty states, the welcome screen and Settings (its 140 pt label column holds “Keep mail on this Mac” at `body` and no more), and what the system draws (menus, tooltips, alerts).
- **The features beside it.** Each follows the rule above. Send Later (§5.46): a waiting message's Drafts row is a row, its “Sends Mon 09:00” on the time line, and the draft sheet's “Sends Mon 09:00 · Cancel” is a sheet header line; Send's drop-down with its Send Later times is a menu. Attachments (§5.17): a chip's name and size and the “3 attachments · Download all” line take the reader's step, the Download button is a glyph and keeps its 24 pt target. Find in conversation (§5.50): the marks sit in the bodies at their text's size; the find bar is the reader's chrome, at Default as the list's search field is. A reader window (§5.49) is the reader: it takes the reader's own size with the main window's, and ⌘+ and ⌘− work there. Mute (§5.51): the muted glyph is a mark. A printout (§5.48) is paper and keeps Default. The Senders sheet (§5.52) and At login (§5.40) are Settings.
- **Rows.** Each line of a row moves by its role's step, the lines below it by the lines above, and the row's top pad by the step once more; a compact row's bottom pad too. Standard rows are 64 / 68 / 72 / 76 pt (`textSize.rowHeights`), compact rows 44 / 48 / 52 / 56 pt (`textSize.rowCompactHeights`). The marks keep their sizes and stay centred on what they mark: the pip on the sender line, the face and its ring in the row, the time cluster (the tile, the Back tag, the queued glyph) on the sender line, the glyph cluster and the count badge on line 2. The margin rule keeps its inset (8 pt, compact 6) and takes the row's height. Nothing moves horizontally.

| Standard row | Small | Default | Large | Larger |
|---|---|---|---|---|
| height | 64 | 68 | 72 | 76 |
| sender line y, h | 9, 15 | 10, 16 | 11, 17 | 12, 18 |
| subject line y, h | 25, 17 | 27, 18 | 29, 19 | 31, 20 |
| snippet line y, h | 43, 14 | 46, 15 | 49, 16 | 52, 17 |
| avatar box y | 13 | 15 | 17 | 19 |
| pip y | 12.5 | 14 | 15.5 | 17 |
| margin rule y, h | 8, 48 | 8, 52 | 8, 56 | 8, 60 |

| Compact row | Small | Default | Large | Larger |
|---|---|---|---|---|
| height | 44 | 48 | 52 | 56 |
| sender line y, h | 6, 15 | 7, 16 | 8, 17 | 9, 18 |
| line 2 y, h | 23, 17 | 25, 18 | 27, 19 | 29, 20 |
| pip y | 10 | 11.5 | 13 | 14.5 |
| margin rule y, h | 6, 32 | 6, 36 | 6, 40 | 6, 44 |

- **Running heads** keep their heights (28 pt, compact 24) and their label's place; the label's line takes `runningHead`'s step (none at Small) and the hairline stays on its centre, on the device grid. **Skeleton rows** take the row's height; each bar stays centred on the line it stands for and the circle on the row, at their own sizes.
- **The reader's own size.** ⌘+ (View › Make Text Bigger) and ⌘− (View › Make Text Smaller) step the reader alone through the same sizes, from the one Settings chose: its headline, sheets and bodies, never the list, the quick reply or a composer. ⌘+ is disabled at Larger and ⌘− at Small, so the keys never pass a size the design does not draw; there is no ⌘0, which is All Inboxes (§6), and the other key comes back. The reader keeps its size across launches; choosing a Text size in Settings sets the reader to it too.
- **Live.** A change applies at once, with no relaunch and no reselection. The list re-measures its rows, keeping the selection and the scroll position, as a density change does: the row at the top stays at the top, as far into it as before, and only a selection the taller rows push out of view is scrolled back to. Every reader shell, the pre-rendered ones and one still loading included, takes the size and measures its bodies again; the headline is set again. Every open composer sets its subject and its body again, mid-edit included: bold, italic, underline, links, lists and quotes stay, and the caret stays where it was. The quick reply does the same. A change is not an edit: the undo stack is kept, and what an undo or a redo brings back takes the size shown then.
- **Budgets.** A change re-measures rows once; moving the selection still builds nothing (`RowContentCache` keys on the Text size, §5.7). The list is re-measured and drawn within 50 ms, and every pooled reader shell has measured its open bodies again within 100 ms, after a change in Settings and after ⌘+ or ⌘− alike (the Text size row of the budgets in `docs/ARCHITECTURE.md`, read with the `list.remeasure` and `conversation.textSize` signposts).

### 4.16 Themes (1.8)

Five themes, chosen in Settings › Appearance › Theme (§5.40). **Study** is the default and the palette of §4.1–§4.3 value for value: its table in `tokens.json` is `color` itself, so nobody's app changes until they choose another. **Gallery**, **Rain**, **Grove** and **Dusk** are each named for the light the window reads like, as Quire names its own parts. A theme is a few seeds (a paper hue and strength, an ink per mode) and one rule applied to Study's table: every token keeps Study's luminance and changes only its hue and chroma, so every contrast ratio of §7 stays Study's. The few targeted adjustments are rules too, and no value is set by hand. `docs/design/source/themes_def.py` holds the seeds, `themes_lib.py` the rule and `theme_rules.py` the theme rules; `tokens.json` carries every theme's table under `themes` (Study first), with its Graphite values, both link flags, `focusOnPage` and `sheetIsPage` per mode.

| Theme | Caption (under the tiles) | Inkless |
|---|---|---|
| **Study** | “Warm paper and blue-black ink.” | — |
| **Gallery** | “Neutral grey paper and an ink with no colour.” | yes |
| **Rain** | “Cool blue-grey paper, for anyone who finds warm paper too yellow.” | — |
| **Grove** | “Sage paper and a deep teal ink.” | — |
| **Dusk** | “Heather paper by day, and a dimmer window at night.” | — |

Each caption says only what holds in every mode its tile is drawn in. No name is a brand, a paint-chip name, or a name an account ink or an avatar tint already uses.

**What never changes.** `originalPage` (white in every theme and mode), the light reading sheet (it stays the white page), the ten account inks, the eight avatar tints, every semantic mark (`success`, `warning`, `danger`, `info`, `star`, `findWash`, `findCurrent`), `onDanger`, `slipEdge`, and the elevation and toggle-knob shadows. Nor does the brand mark: the welcome screen draws it and the wordmark in the brand's black and white and inbox zero in the system's secondary label grey (§4.11), and the app icon is black and white in every theme (§5.42).

**What a theme can and cannot change.**

1. **Contrast reads only luminance.** A token at exactly its Study luminance, in any hue and chroma, keeps every ratio it is in, composited pairs included: an alpha wash over a surface moves only by 8-bit rounding. So each theme inherits Quire's pair-by-pair tuning in all four modes instead of redoing it. R4 holds every neutral token's `Y + 0.05` within 3 % of Study's. The only exceptions are tokens a theme declares deeper, and only Dusk declares any; even then the hairline, the idle selection and a quiet toggle's on state are not scaled with the surfaces but keep Study's ratio against the deeper surface they are drawn on (the ratio lock, R4b), so declared depth never weakens structure.
2. **The account palette leaves the ink only the blue-to-teal band.** An account's colour is its identity and does not change with the theme. With the ten account inks fixed, “no account ink within 15 ΔE00 of the ink” (§4.2) leaves only LCh hue 190–256 open in all four modes. R5 also keeps the ink at least 12 from `info` (at least 3 under every simulation) and at least Study's own floor from every account ink under every simulation, and R10 asks it to stay at least 15 from the text ink (at least 10 under every simulation) so links need no underline. In Light and Light IC that leaves blue-black (Iron Gall), petrol and a deep teal. **So in light modes the paper carries a theme's identity, and the ink carries it at night.** Gallery is the exception: it has no coloured ink at all.
3. **The light sheet is the white page.** A styled message that declares its own colours is shown as sent on the light sheet (§5.14), because the sheet is the white page its sender designed for. Every theme's Light sheet is therefore no farther from white, and no more chromatic, than Study's own `#FFFEFB` (R1); the Light IC sheet is `#FFFFFF`, `raised` stays `#FFFFFF` in Light and Light IC, and `originalPage` is `#FFFFFF` everywhere. A link its sender left uncoloured on that page is the page's link, not the theme's: it keeps Study's colour in every theme (`--q-linkOnPage`, R11). The build computes `sheetIsPage` per theme and mode and requires it to be exactly “not dark”, which is what the reader's offer of Original colors assumes (§5.14): a future theme that tints its light sheet fails the build until the reader learns to adapt in light.
4. **A light paper has a floor of L\* 94.4** (92.0 in Light IC). Lilac, the lightest account ink, must keep 3:1 on the selected row, so `selWash` needs Y ≥ 0.679, and the selected row must sit 1.25:1 below the paper: together, paper Y ≥ 0.861. Every theme today keeps Study's L\* 98.2; the floor binds a future theme that declares light depth.
5. **Shadows are not themed.** The elevation shadows (`e1`–`e3`) and the toggle knob's shadow are Study's ink at low alpha in every theme. In a theme's own ink they would differ by at most 1.5 ΔE00, less than the step between two adjacent greys, so they stay one set and R0 says so.

#### Study (default)

“Warm paper and blue-black ink.” Daylight on a writing desk: Quire 1.7's `color` table in every mode, with Iron Gall. Its reader stylesheet is empty.

| Token | Light | Dark | Light IC | Dark IC |
|---|---|---|---|---|
| `spine` | `#ECE9E1` | `#121110` | `#E4E0D6` | `#080807` |
| `canvas` | `#F4F2EC` | `#171614` | `#F1EFE9` | `#0D0C0B` |
| `paper` | `#FBFAF6` | `#1C1B18` | `#FDFCFA` | `#121110` |
| `sheet` | `#FFFEFB` | `#24221F` | `#FFFFFF` | `#1C1B19` |
| `raised` | `#FFFFFF` | `#2C2A26` | `#FFFFFF` | `#252320` |
| `slip` | `#24221F` | `#36332E` | `#12100E` | `#2E2B27` |
| `ink` | `#1D1B18` | `#EDE9E2` | `#0F0E0C` | `#FFFFFF` |
| `ink2` | `#55504A` | `#B8B2A8` | `#3A3631` | `#DCD7CE` |
| `ink3` | `#625C55` | `#A8A297` | `#4A4540` | `#C8C2B8` |
| `ruleStrong` | `#7F796F` | `#8B857B` | `#5E5952` | `#A39D93` |
| `accent` | `#1E5468` | `#6DB6C9` | `#123E4D` | `#93D3E3` |
| `accentFill` | `#1E5468` | `#2D788B` | `#123E4D` | `#246F83` |
| `accentWash` | `#DCE8EA` | `#1F363C` | `#C8DCE0` | `#1A4049` |
| `selWash` | `#D0E0E5` | `#213A41` | `#C2D6DC` | `#1A4049` |
| `selWashIdle` | `#EAE7DF` | `#2B2925` | `#DCD8CE` | `#302D29` |

#### Gallery

“Neutral grey paper and an ink with no colour.” An evenly lit white room, with everything printed in black. The neutral ramp at chroma 0 (greys at Study's luminances), and **no coloured ink**: its accent family is the Graphite substitution of §3.1 resolved against its own greys, in all four modes. The unread pip and time, links, the margin rule, focus rings and primary buttons are the text ink; toggle and checkbox on-fills are the text ink with a paper knob; quiet toggles take the idle wash. Links are underlined at rest in every mode, since colour cannot mark them. Colour that carries meaning stays: the account inks, the star, success, warning, danger, info and find. It is the only theme whose marks have no hue, so its window differs from Study's as much in Dark as in Light.

- **The one departure from Graphite: the key selection wash.** The system Graphite accent makes the selected row the idle wash and lets the rule carry the difference, and the build stops asserting the two 1.25 scan cues there. A theme may not drop pairs, so Gallery's `selWash` is a grey at Study's selection luminance: the selected row sits as far from the list as in Study, and every pair is asserted.
- **What the build reads as under Graphite** (“inkless”): the account rule “no account ink within 15 ΔE00 of the ink” (the ink is the text ink; R5 holds the palette's own floor between inks, 13, and the closest, Fern in Dark IC, is what Study shows under Graphite); R3 (no coloured fill to keep near the asset); R8 (key and not-key selection differ by the rule, `ink` against `ink3`, and by luminance); and R9's floor on the selected row (Study's selection under Graphite).
- **Native chrome.** The compiled accent asset stays Iron Gall (§3.1). With the Multicolor system accent, an alert's default button, menu highlights and the Settings toolbar's selected tab stay Iron Gall in Gallery; with Graphite chosen in System Settings, native chrome is grey too and Gallery looks the same everywhere.

| Token | Light | Dark | Light IC | Dark IC |
|---|---|---|---|---|
| `spine` | `#E9E9E9` | `#111111` | `#E0E0E0` | `#080808` |
| `canvas` | `#F2F2F2` | `#161616` | `#EFEFEF` | `#0C0C0C` |
| `paper` | `#FAFAFA` | `#1B1B1B` | `#FCFCFC` | `#111111` |
| `sheet` | `#FEFEFE` | `#222222` | `#FFFFFF` | `#1B1B1B` |
| `raised` | `#FFFFFF` | `#2A2A2A` | `#FFFFFF` | `#232323` |
| `slip` | `#222222` | `#333333` | `#101010` | `#2B2B2B` |
| `ink` | `#1B1B1B` | `#E9E9E9` | `#0E0E0E` | `#FFFFFF` |
| `ink2` | `#515151` | `#B3B3B3` | `#373737` | `#D7D7D7` |
| `ink3` | `#5D5D5D` | `#A3A3A3` | `#464646` | `#C3C3C3` |
| `ruleStrong` | `#7A7A7A` | `#868686` | `#5A5A5A` | `#9E9E9E` |
| `accent` | `#1B1B1B` | `#E9E9E9` | `#0E0E0E` | `#FFFFFF` |
| `accentFill` | `#1B1B1B` | `#E9E9E9` | `#0E0E0E` | `#FFFFFF` |
| `accentWash` | `#E7E7E7` | `#292929` | `#D8D8D8` | `#2D2D2D` |
| `selWash` | `#DDDDDD` | `#363636` | `#D2D2D2` | `#3B3B3B` |
| `selWashIdle` | `#E7E7E7` | `#292929` | `#D8D8D8` | `#2D2D2D` |

#### Rain

“Cool blue-grey paper, for anyone who finds warm paper too yellow.” An overcast afternoon indoors: the coolest paper of the five, the rail wet slate and the desk pale sky. The ink is a deep petrol by day and a clear aqua at night, and the slip is blue-black. In Light IC the ink moves to a bluer petrol, because no ink at Rain's own hue inside Light IC's luminance clears both R10 and R5. In Light the selection wash resolves to Study's own, because R9 keeps the Sea and Slate avatar faces off it. Rain's ink sits close to its blue-grey `ink2`, so links inside quotes are underlined at rest in every mode.

| Token | Light | Dark | Light IC | Dark IC |
|---|---|---|---|---|
| `spine` | `#DEEBF2` | `#0B1215` | `#D2E3EB` | `#01090E` |
| `canvas` | `#EAF4F8` | `#121719` | `#E7F1F5` | `#050D11` |
| `paper` | `#F5FBFE` | `#171C1E` | `#F9FDFE` | `#0B1215` |
| `sheet` | `#FDFEFF` | `#1E2326` | `#FFFFFF` | `#171C1E` |
| `raised` | `#FFFFFF` | `#242B2F` | `#FFFFFF` | `#1F2427` |
| `slip` | `#1E2326` | `#2C3539` | `#0D1113` | `#252D30` |
| `ink` | `#181C1E` | `#E2EBF0` | `#0C0F10` | `#FFFFFF` |
| `ink2` | `#495257` | `#A7B5BC` | `#30383B` | `#CDDAE0` |
| `ink3` | `#545F64` | `#96A5AC` | `#3F474B` | `#B7C5CC` |
| `ruleStrong` | `#6D7C83` | `#79888F` | `#4F5C62` | `#91A0A8` |
| `accent` | `#0C3E45` | `#66CAD8` | `#00323D` | `#83D6E2` |
| `accentFill` | `#27555B` | `#017B87` | `#103F4A` | `#03727E` |
| `accentWash` | `#DEE8E9` | `#18373C` | `#C9DCE2` | `#0B4148` |
| `selWash` | `#D0E0E5` | `#193B41` | `#C2D6DC` | `#0B4148` |
| `selWashIdle` | `#E5E7E8` | `#232A2E` | `#D5D9DB` | `#272F32` |

#### Grove

“Sage paper and a deep teal ink.” Shade under trees. The green lives in the paper; the ink cannot be green, since success, the star and the Jade and Fern accounts own that space. By day the ink is a deep teal, chromatic enough that the pip, the unread times and the margin rule read as ink rather than black and links need no underline; at night it is a soft sea-glass. The slip is green-black. In Light the selection wash is Study's own, as in Rain.

| Token | Light | Dark | Light IC | Dark IC |
|---|---|---|---|---|
| `spine` | `#E5EBE0` | `#0F120D` | `#DCE2D6` | `#060902` |
| `canvas` | `#EFF4EB` | `#151713` | `#ECF1E8` | `#0A0D07` |
| `paper` | `#F8FBF5` | `#191C17` | `#FBFDFA` | `#0F120D` |
| `sheet` | `#FEFFFD` | `#21231E` | `#FFFFFF` | `#1A1C18` |
| `raised` | `#FFFFFF` | `#282B25` | `#FFFFFF` | `#22241F` |
| `slip` | `#21231E` | `#31352D` | `#0F110D` | `#292D26` |
| `ink` | `#1A1C18` | `#E6EBE2` | `#0D0E0C` | `#FFFFFF` |
| `ink2` | `#4E524A` | `#AEB5A9` | `#343831` | `#D4D9CF` |
| `ink3` | `#5A5E55` | `#9EA599` | `#434740` | `#BEC5B9` |
| `ruleStrong` | `#767C70` | `#82887C` | `#565C51` | `#99A094` |
| `accent` | `#013A3D` | `#86D8DA` | `#002C31` | `#8CD6D6` |
| `accentFill` | `#22555A` | `#247A7E` | `#173F44` | `#147278` |
| `accentWash` | `#DDE8E8` | `#1D3737` | `#CADCDE` | `#154142` |
| `selWash` | `#D0E0E5` | `#1E3A40` | `#C1D6DA` | `#134146` |
| `selWashIdle` | `#E3E9DF` | `#272A24` | `#D4DACE` | `#2B2F28` |

#### Dusk

“Heather paper by day, and a dimmer window at night.” The blue hour: the theme people choose for its night. It **declares depth** in Dark and Dark IC: the surfaces and the idle selection take 0.7 × Study's luminance, so the window is violet-black and 30 % dimmer than Study's. The hairline, the idle selection and the quiet-toggle washes keep Study's ratio against the deeper surface they sit on (the ratio lock), and Dark declares a **night ink**: body text keeps Study's ratio on the deeper sheet instead of the higher one it would reach, and keeps at least 4.6:1 on `findCurrent` after 8-bit rounding. Its marks are sky-blue. By day it is a faint heather paper with an ink close to Iron Gall, since in light modes the band leaves no other blue (point 2 above): the paper carries it, as the caption says.

| Token | Light | Dark | Light IC | Dark IC |
|---|---|---|---|---|
| `spine` | `#EBE8F4` | `#0E0C12` | `#E2DEEC` | `#06050C` |
| `canvas` | `#F3F1FA` | `#121015` | `#F0EEF7` | `#0A080E` |
| `paper` | `#FBF9FF` | `#161519` | `#FCFCFF` | `#0E0C12` |
| `sheet` | `#FEFEFF` | `#1C1B20` | `#FFFFFF` | `#161519` |
| `raised` | `#FFFFFF` | `#232228` | `#FFFFFF` | `#1D1C21` |
| `slip` | `#232226` | `#34323A` | `#111013` | `#2C2B31` |
| `ink` | `#1C1B1F` | `#E6E3EC` | `#0E0E10` | `#FFFFFF` |
| `ink2` | `#525058` | `#B4B1BE` | `#37363C` | `#D9D6E1` |
| `ink3` | `#5E5C65` | `#A4A1AD` | `#47454C` | `#C4C1CE` |
| `ruleStrong` | `#7B7884` | `#878490` | `#5B5863` | `#9F9CA8` |
| `accent` | `#00556E` | `#77C8F4` | `#053D4E` | `#ACE7FF` |
| `accentFill` | `#00556E` | `#1E779C` | `#083E4F` | `#276E86` |
| `accentWash` | `#DCE8EE` | `#17303E` | `#C9DBE5` | `#183C48` |
| `selWash` | `#CFE0E9` | `#1E3A49` | `#C2D6DF` | `#1C3F4C` |
| `selWashIdle` | `#E8E7E9` | `#26242A` | `#DAD6E4` | `#2C2A31` |

Tokens each theme keeps from Study in all four modes: Gallery (17): `slipEdge`, `originalPage`, `onSwipe`, `star`, `success`, `warning`, `danger`, `info`, `successWash`, `warningWash`, `dangerWash`, `findWash`, `findCurrent`, `dangerFill`, `dangerFillHover`, `dangerFillPressed`, `onDanger`. Rain (18): `slipEdge`, `originalPage`, `onSwipe`, `onAccent`, `star`, `success`, `warning`, `danger`, `info`, `successWash`, `warningWash`, `dangerWash`, `findWash`, `findCurrent`, `dangerFill`, `dangerFillHover`, `dangerFillPressed`, `onDanger`. Grove (18): `slipEdge`, `originalPage`, `onSwipe`, `onAccent`, `star`, `success`, `warning`, `danger`, `info`, `warningWash`, `dangerWash`, `infoWash`, `findWash`, `findCurrent`, `dangerFill`, `dangerFillHover`, `dangerFillPressed`, `onDanger`. Dusk (18): `slipEdge`, `originalPage`, `onSwipe`, `onAccent`, `star`, `success`, `warning`, `danger`, `info`, `successWash`, `warningWash`, `dangerWash`, `findWash`, `findCurrent`, `dangerFill`, `dangerFillHover`, `dangerFillPressed`, `onDanger`. Every value of every theme is in `tokens.json` (`themes[].color`).

**How far apart they are.** Mean CIEDE2000 over the tokens that carry identity (`spine`, `canvas`, `paper`, `sheet`, `slip`, `selWash`, `accent`); about 2 is a visible tint across a pane, 4 and up reads as another window:

| Mode | Study–Gallery | Study–Rain | Study–Grove | Study–Dusk | Gallery–Rain | Gallery–Grove | Gallery–Dusk | Rain–Grove | Rain–Dusk | Grove–Dusk |
|---|---|---|---|---|---|---|---|---|---|---|
| Light | 6.0 | 5.2 | 3.9 | 4.9 | 5.8 | 6.4 | 7.0 | 4.3 | 5.3 | 7.6 |
| Dark | 6.3 | 5.0 | 4.3 | 6.0 | 7.7 | 7.7 | 7.7 | 4.9 | 6.4 | 8.7 |
| Light IC | 5.3 | 4.0 | 3.2 | 4.0 | 5.7 | 5.8 | 6.1 | 3.8 | 4.1 | 6.1 |
| Dark IC | 5.7 | 4.2 | 4.0 | 4.4 | 7.9 | 8.0 | 6.8 | 4.4 | 5.5 | 7.6 |

`paper` alone, `spine` (the rail) alone, and the ink (`accent`) alone:

| Mode | Study–Gallery | Study–Rain | Study–Grove | Study–Dusk | Gallery–Rain | Gallery–Grove | Gallery–Dusk | Rain–Grove | Rain–Dusk | Grove–Dusk |
|---|---|---|---|---|---|---|---|---|---|---|
| Light | 2.0 | 4.2 | 2.3 | 5.4 | 2.8 | 3.6 | 3.4 | 4.5 | 4.6 | 7.0 |
| Dark | 2.2 | 4.7 | 3.4 | 5.5 | 3.2 | 4.5 | 3.6 | 5.0 | 5.0 | 7.8 |
| Light IC | 1.0 | 2.5 | 1.7 | 2.6 | 1.9 | 2.0 | 1.6 | 2.1 | 2.5 | 3.5 |
| Dark IC | 0.7 | 4.0 | 3.4 | 3.9 | 3.4 | 3.4 | 3.6 | 4.6 | 4.9 | 6.9 |

| Mode | Study–Gallery | Study–Rain | Study–Grove | Study–Dusk | Gallery–Rain | Gallery–Grove | Gallery–Dusk | Rain–Grove | Rain–Dusk | Grove–Dusk |
|---|---|---|---|---|---|---|---|---|---|---|
| Light | 3.9 | 8.9 | 4.7 | 10.2 | 5.8 | 6.4 | 6.2 | 8.7 | 8.6 | 12.6 |
| Dark | 0.7 | 4.0 | 3.4 | 3.9 | 3.4 | 3.4 | 3.6 | 4.6 | 4.9 | 6.9 |
| Light IC | 4.8 | 11.0 | 5.0 | 12.1 | 7.1 | 6.8 | 7.2 | 9.8 | 10.9 | 14.0 |
| Dark IC | 0.4 | 3.4 | 2.9 | 3.5 | 3.2 | 3.3 | 3.0 | 5.0 | 3.8 | 6.3 |

| Mode | Study–Gallery | Study–Rain | Study–Grove | Study–Dusk | Gallery–Rain | Gallery–Grove | Gallery–Dusk | Rain–Grove | Rain–Dusk | Grove–Dusk |
|---|---|---|---|---|---|---|---|---|---|---|
| Light | 22.4 | 9.4 | 12.1 | 2.1 | 17.2 | 17.4 | 23.6 | 3.0 | 10.3 | 13.0 |
| Dark | 23.7 | 6.3 | 10.9 | 9.1 | 23.5 | 21.2 | 21.8 | 5.7 | 10.8 | 14.6 |
| Light IC | 18.7 | 4.5 | 7.9 | 1.1 | 16.5 | 15.4 | 19.1 | 3.8 | 4.4 | 8.0 |
| Dark IC | 20.9 | 3.7 | 7.0 | 6.0 | 22.9 | 22.7 | 17.8 | 4.5 | 8.4 | 11.4 |

In light modes the papers and rails carry the coloured themes and the coloured inks cluster, as point 2 predicts: Dusk sits close to Iron Gall, and Rain and Grove close to each other. At night the four coloured inks spread apart, and Gallery's colourless ink is far from every other theme's in every mode. Under the system Graphite accent every theme is inkless, so there Study and Gallery differ only by their paper.

**Reading comfort.** Every theme but Dusk keeps Study's light levels and text contrast to within 2 %. Dusk's night is 30 % dimmer, with body text dimmed so it stays near Study's contrast instead of glaring, and the `ink` / `ink2` ratio keeps names and snippets apart:

| Theme | Mode | Sheet luminance vs Study | Desk (`canvas`) vs Study | Body text luminance vs Study | `ink` on `sheet` | `ink2` on `sheet` | ink / ink2 |
|---|---|---|---|---|---|---|---|
| Study | Light | 100 % | 100 % | 100 % | 17.0 | 7.9 | 2.15 |
| Study | Dark | 100 % | 100 % | 100 % | 13.1 | 7.5 | 1.74 |
| Gallery | Light | 100 % | 100 % | 99 % | 17.1 | 7.9 | 2.17 |
| Gallery | Dark | 99 % | 99 % | 100 % | 13.1 | 7.6 | 1.73 |
| Rain | Light | 100 % | 100 % | 101 % | 17.0 | 7.9 | 2.15 |
| Rain | Dark | 100 % | 101 % | 100 % | 13.1 | 7.5 | 1.74 |
| Grove | Light | 101 % | 100 % | 100 % | 17.1 | 8.0 | 2.15 |
| Grove | Dark | 100 % | 102 % | 100 % | 13.1 | 7.5 | 1.74 |
| Dusk | Light | 100 % | 100 % | 102 % | 17.0 | 7.9 | 2.16 |
| Dusk | Dark | 70 % | 69 % | 95 % | 13.5 | 8.1 | 1.66 |

**The derivation.** The seeds:

| Theme | Paper ramp (LCh hue, chroma factor; inks 0.8 of it) | Dark surface chroma floor | Declared depth | The ink per mode (seed → value) |
|---|---|---|---|---|
| Study | — (it is `color`) | — | — | Iron Gall: Light `#1E5468`, Dark `#6DB6C9`, Light IC `#123E4D`, Dark IC `#93D3E3` |
| Gallery | chroma 0 | — | — | none: **inkless** (the accent family is its own Graphite substitution; `selWash` a grey at Study's luminance) |
| Rain | hue 236, chroma × 1.3 | 3 | — | Light (Y 0.04, C 16, h 212) `#0C3E45`; Dark (Y 0.5, C 30, h 212) `#66CAD8`; Light IC (Y 0.026, C 16, h 226) `#00323D`; Dark IC (Y 0.583, C 26, h 212) `#83D6E2` |
| Grove | hue 130, chroma × 1.5 | 3 | — | Light (Y 0.034, C 17, h 202) `#013A3D`; Dark (Y 0.5934, C 26, h 200) `#86D8DA`; Light IC (Y 0.02, C 14, h 212) `#002C31`; Dark IC (Y 0.5834, C 24, h 198) `#8CD6D6` |
| Dusk | hue 300, chroma × 1.5 | 3 | 0.7 × luminance for the surfaces in Dark and Dark IC; the ratio lock; a night ink in Dark | Light (Y 0.0762, C 24, h 240) `#00556E`; Dark (Y 0.52, C 32, h 246) `#77C8F4`; Light IC (Y 0.039, C 18, h 236) `#053D4E`; Dark IC (Y 0.7292, C 22, h 234) `#ACE7FF` |

The rule, per mode:

1. **Neutral ramp** (`spine`, `paper`, `canvas`, `sheet`, `raised`, `slip`, `knob`, `ink`, `ink2`, `ink3`, `inkDisabled`, `onSlip`, `onSlip2`, `rule`, `ruleStrong`, `onSlipEdge`, `hover`, `pressed`, `fill`, `slipHover`, `slipPressed`, `scrim`, `selWashIdle`, `swipeRead`, `swipeArchiveNeutral`). Each takes Study's relative luminance, multiplied by the declared depth for `spine`, `paper`, `canvas`, `sheet` and `raised` in Dark and Dark IC. Hue is the paper hue. Chroma is min(7, max(floor, k × Study's chroma)), where k is the paper factor (0.8 of it for the seven ink tokens) and the floor applies only to the six surfaces in dark modes. Out of gamut, chroma steps down by 0.1. Alpha tokens keep their alpha; pure white and pure black stay.
2. **Ratio lock** (declared depth only). `rule` takes the luminance that gives Study's `rule`-on-`sheet` ratio on the theme's deeper `sheet`, `selWashIdle` Study's ratio on the deeper `paper`, and `accentWash`, `accentWashHover` and `accentWashPressed` Study's ratio on the deeper `sheet`, on the same side of it, at the theme's hue and chroma.
3. **Night ink** (declared; Dusk, Dark only). `ink` takes the luminance that gives Study's `ink`-on-`sheet` ratio on the deeper sheet, never below 4.6:1 on `findCurrent`, its tightest pair. After 8-bit rounding the build takes the first value that meets the floor, not the nearest.
4. **The light sheet is the page.** In Light and Light IC, `sheet` gives up chroma until it is no farther from white than Study's sheet, with C\* ≤ 1.6.
5. **Fixed and derived.** `slipEdge` is Study's; `originalPage`, `onAccent` and `onSwipe` are `#FFFFFF` (Gallery's `onAccent` is its paper, as under Graphite; `onSwipe` is white everywhere, the swipe button's icon and label, §5.7); `selRuleIdle` = `ink3`; `scrimSolid` = `scrim` over `canvas`. The semantic tokens are Study's, except as rule 10 says.
6. **The ink as a mark.** `accent` = `focus` = `selRule` = the seed.
7. **Fills** (`accentFill`, `accentFillHover`, `accentFillPressed`, `controlOnPressed`). Study's luminance in the ink's hue, chroma × min(1.25, seed C / Iron Gall's C); then all four are pulled together toward Iron Gall until `accentFill` is at most 7.5 ΔE00 from the compiled accent asset (R3). In dark modes each on-state fill is then lifted until it keeps 3.03:1 on `sheet` and `canvas`, with white at least 4.6:1 on it. `swipeArchive` is `accentFill` as finally lifted.
8. **Washes.** The quiet-toggle washes take Study's luminance (or rule 2's) in the ink hue, chroma × min(1.3, that ratio). `selWash` takes Study's luminance, never deepened, so the 1.25 scan cue holds, and is never paler than Study's; its hue steps toward Study's selection hue until every avatar face clears its floor on it (R9). `selWashIdle` then gives up chroma until it is at least 6 ΔE00 from `selWash` and every avatar face clears its floor on it.
9. **Inkless** (Gallery). After rules 1–5, the accent-family tokens of `graphite` are resolved against the theme's own final neutrals, exactly as the system Graphite accent resolves them; `selWash` alone keeps Study's selection luminance in the theme's neutral.
10. **Banners stay banners.** A semantic wash closer than 6.5 ΔE00 to the theme's `sheet` or `paper`, or closer to its `canvas` than the smaller of that and Study's own distance, gains chroma at its own hue and luminance until it clears.
11. **Derived flags and page colours.** Both link flags (R10), `--q-focusOnPage` (the theme's light focus, Light IC's under Increase Contrast, in both appearances, since the page is white in both) and `--q-linkOnPage` (Study's accent, R11). Nobody sets any of these by hand.

Because the adjustments are rules, a later change to Study's table re-derives every theme and the build re-checks it. The banner washes rule 10 moved (hue and luminance kept to 8-bit rounding, so every banner text pair keeps its ratio):

| Theme | Wash | Mode | Study → theme | LCh |
|---|---|---|---|---|
| Gallery | `infoWash` | Light | `#E4EAF5` → `#E3EAF8` | C 6.0 → 7.6, h 270 → 272, L 92.5 → 92.6 |
| Rain | `infoWash` | Light | `#E4EAF5` → `#E0EAFC` | C 6.0 → 9.8, h 270 → 271, L 92.5 → 92.5 |
| Grove | `successWash` | Light | `#E5EFE5` → `#DFF1DF` | C 6.3 → 11.3, h 144 → 144, L 93.5 → 93.4 |
| Dusk | `infoWash` | Light | `#E4EAF5` → `#DFEAFE` | C 6.0 → 10.9, h 270 → 271, L 92.5 → 92.4 |

Dusk's ratio lock, against Study:

| Theme | Mode | Pair | Study | Theme (ratio-locked) |
|---|---|---|---|---|
| Dusk | Dark | `rule` on `sheet` | 1.226 | 1.225 (`#2D2B32`) |
| Dusk | Dark | `selWashIdle` on `paper` | 1.186 | 1.184 (`#26242A`) |
| Dusk | Dark | `accentWash` on `sheet` | 1.247 | 1.246 (`#17303E`) |
| Dusk | Dark | `accentWashHover` on `sheet` | 1.377 | 1.370 (`#1A3747`) |
| Dusk | Dark | `accentWashPressed` on `sheet` | 1.105 | 1.107 (`#0F2733`) |
| Dusk | Dark | `rule` on `paper` | 1.331 | 1.301 (`#2D2B32`) |
| Dusk | Dark | `rule` on `canvas` | 1.398 | 1.353 (`#2D2B32`) |
| Dusk | Dark | `accentWash` on `canvas` | 1.422 | 1.376 (`#17303E`) |
| Dusk | Dark IC | `rule` on `sheet` | 2.182 | 2.191 (`#4F4D57`) |
| Dusk | Dark IC | `selWashIdle` on `paper` | 1.377 | 1.373 (`#2C2A31`) |
| Dusk | Dark IC | `accentWash` on `sheet` | 1.535 | 1.539 (`#183C48`) |
| Dusk | Dark IC | `accentWashHover` on `sheet` | 1.778 | 1.780 (`#1D4654`) |
| Dusk | Dark IC | `accentWashPressed` on `sheet` | 1.335 | 1.343 (`#13323D`) |
| Dusk | Dark IC | `rule` on `paper` | 2.391 | 2.344 (`#4F4D57`) |
| Dusk | Dark IC | `rule` on `canvas` | 2.477 | 2.402 (`#4F4D57`) |
| Dusk | Dark IC | `accentWash` on `canvas` | 1.744 | 1.688 (`#183C48`) |

**Graphite and Increase Contrast.** The Graphite substitution of §3.1 is unchanged and resolves against **the active theme's** neutrals: a Rain user with a Graphite system accent gets Rain's blue-grey ramp and an ink margin rule. The build regenerates the Graphite pairs for each theme, and under Graphite links are underlined at rest in every theme (§3.1). Gallery's own table already is its Graphite table, except `selWash`, which under the system accent becomes the idle wash as in every theme. Key Graphite values (all of them are in `tokens.json`, `themes[].graphite`):

| Theme | Token | Light | Dark | Light IC | Dark IC |
|---|---|---|---|---|---|
| Study | `accent` | `#1D1B18` | `#EDE9E2` | `#0F0E0C` | `#FFFFFF` |
| Study | `onAccent` | `#FBFAF6` | `#1C1B18` | `#FDFCFA` | `#121110` |
| Study | `selWash` | `#EAE7DF` | `#2B2925` | `#DCD8CE` | `#302D29` |
| Study | `accentFillHover` | `#55504A` | `#B8B2A8` | `#3A3631` | `#DCD7CE` |
| Gallery | `accent` | `#1B1B1B` | `#E9E9E9` | `#0E0E0E` | `#FFFFFF` |
| Gallery | `onAccent` | `#FAFAFA` | `#1B1B1B` | `#FCFCFC` | `#111111` |
| Gallery | `selWash` | `#E7E7E7` | `#292929` | `#D8D8D8` | `#2D2D2D` |
| Gallery | `accentFillHover` | `#515151` | `#B3B3B3` | `#373737` | `#D7D7D7` |
| Rain | `accent` | `#181C1E` | `#E2EBF0` | `#0C0F10` | `#FFFFFF` |
| Rain | `onAccent` | `#F5FBFE` | `#171C1E` | `#F9FDFE` | `#0B1215` |
| Rain | `selWash` | `#E5E7E8` | `#232A2E` | `#D5D9DB` | `#272F32` |
| Rain | `accentFillHover` | `#495257` | `#A7B5BC` | `#30383B` | `#CDDAE0` |
| Grove | `accent` | `#1A1C18` | `#E6EBE2` | `#0D0E0C` | `#FFFFFF` |
| Grove | `onAccent` | `#F8FBF5` | `#191C17` | `#FBFDFA` | `#0F120D` |
| Grove | `selWash` | `#E3E9DF` | `#272A24` | `#D4DACE` | `#2B2F28` |
| Grove | `accentFillHover` | `#4E524A` | `#AEB5A9` | `#343831` | `#D4D9CF` |
| Dusk | `accent` | `#1C1B1F` | `#E6E3EC` | `#0E0E10` | `#FFFFFF` |
| Dusk | `onAccent` | `#FBF9FF` | `#161519` | `#FCFCFF` | `#0E0C12` |
| Dusk | `selWash` | `#E8E7E9` | `#26242A` | `#DAD6E4` | `#2C2A31` |
| Dusk | `accentFillHover` | `#525058` | `#B4B1BE` | `#37363C` | `#D9D6E1` |

Each theme's Light IC and Dark IC tables are derived from **Study's IC values** by the same rule, so Increase Contrast raises contrast in every theme by the steps Study takes: darker inks, stronger `rule` and `ruleStrong`, a white light sheet, Dusk's ratio-locked hairline included. The IC-only geometry (3 pt focus rings, the `ruleStrong` outline on sheets, 1 pt hairlines, the stronger `slipEdge`) is untouched, and the account inks keep their 3.5:1 IC floor on every theme's surfaces.

**The theme rules.** Asserted for every theme beside the pairs, the Graphite pairs and the account rules (`theme_rules.py`; the constants are `themeRules` in `tokens.json`). “Inkless” says how a rule reads Gallery, the way the build reads the system Graphite accent.

| Rule | Asserts | Why |
|---|---|---|
| R0 | every theme has every token in all four modes; the default theme equals `color` byte for byte; the elevation and knob shadows are one set | completeness; nobody's app changes until they choose |
| R1 | the Light and Light IC `sheet` no farther from white than Study's, with C\* ≤ 1.6; `raised` white in the light modes; `originalPage` white in every mode | the page under styled mail stays the page its sender designed for (§5.14) |
| R2 | the theme's light `focus` at least 3:1 on white (it is `--q-focusOnPage`) | the focus ring on the Original colors page |
| R3 | `accentFill` at most 7.5 ΔE00 from the accent asset in each mode. Inkless: not asserted | native chrome cannot follow a switch (§3.1) |
| R4 | no neutral token's `Y + 0.05` moves more than 3 % from Study's, except tokens the theme declares deeper (inkless: `knob`, accent family under Graphite) | the luminance lock: depth is declared, never drifted into |
| R4b | declared depth: `rule` on `sheet`, `selWashIdle` on `paper` and the three `accentWash` tokens on `sheet` keep 99 % of Study's ratio; a declared night ink keeps 4.6:1 on `findCurrent` after rounding | depth never weakens hairlines, quote bars, the idle selection or a toggle's on state |
| R5 | the ink at least 12 ΔE00 from `info` (at least 3 under protan, deutan and tritan), at least the smaller of 3 and Study's own from every account ink under every simulation, and at least 15 from success, warning, star and danger. Inkless: at least 13 from every account ink | the unread pip, links and an account dot never look like the info glyph or each other |
| R6 | `ink`, `ink2` and `ink3` at least 5 ΔE00 from success, warning, star and danger under every simulation | a meaning never reads as text |
| R7 | each banner wash at least 6.5 ΔE00 from `sheet` and `paper`, and at least the smaller of that and Study's own from `canvas` | a banner never sinks into a tinted page, or into Settings' desk |
| R8 | `selWash` at least 6 ΔE00 from `selWashIdle`. Inkless: not asserted (the rule tells key from not key, as under Graphite) | key and not-key selection stay apart |
| R9 | each avatar face at least the smaller of 5 ΔE00 and its Study distance from `paper`, `sheet`, `canvas`, `selWash` and `selWashIdle`. Inkless: on `selWash`, the Study distance under Graphite | no face sinks further than it does in Study |
| R10 | two flags. **links** (`linkUnderlineAtRest`): every link is underlined at rest where the ink is under 15 ΔE00 from `ink`, or under 10 under any simulation. **quoteLinks** (`quoteLinkUnderlineAtRest`): links inside quotes, where the same holds against `ink2` | colour must not be the only cue, beside body text or beside quoted text |
| R11 | `--q-linkOnPage` (a link its sender left uncoloured, in a body neither Quire-set nor adapted) is never closer than Study's accent to the text a sender's page sets (`#000`–`#444` light, `#FFF`–`#CCC` dark), normal or under any simulation | the sender's text, not the theme's, is what such a link sits beside |

**Results.** 5 themes × 662 pairs × 4 modes = 13,240 checks, plus 5 × 123 Graphite pairs × 4 = 2,460, plus the theme rules, 0 failures. Per theme and mode, the tightest pair is the smallest margin over its need among pairs needing 3 or more; they are Study's own, because every luminance is Study's:

| Theme | Mode | Pairs | Tightest pair (ratio, margin) | Graphite pairs | Tightest Graphite pair | Account rules | Theme rules |
|---|---|---|---|---|---|---|---|
| Study | Light | 662 / 662 | Tag edge on the selected Settings account row 3.18 (+0.180) | 123 / 123 | Tag edge on the selected Settings account row 3.49 (+0.492) | pass | pass |
| Study | Dark | 662 / 662 | Primary button label, hover 4.58 (+0.082) | 123 / 123 | Swipe button icon and label (white) on Archive's fill 4.69 (+0.190) | pass | pass |
| Study | Light IC | 662 / 662 | Account ink Lilac on hovered rail tile 3.56 (+0.055) | 123 / 123 | Account ink Lilac on selected row 3.77 (+0.267) | pass | pass |
| Study | Dark IC | 662 / 662 | Checkbox / radio on fill vs sheet 3.01 (+0.013) | 123 / 123 | Swipe button icon and label (white) on Archive's fill 4.82 (+0.323) | pass | pass |
| Gallery | Light | 662 / 662 | Tag edge on the selected Settings account row 3.16 (+0.160) | 123 / 123 | Tag edge on the selected Settings account row 3.47 (+0.471) | pass | pass |
| Gallery | Dark | 662 / 662 | Row count badge numerals, selected 4.64 (+0.142) | 123 / 123 | Swipe button icon and label (white) on Archive's fill 4.67 (+0.174) | pass | pass |
| Gallery | Light IC | 662 / 662 | Account ink Lilac on selected row 3.55 (+0.046) | 123 / 123 | Account ink Lilac on selected row 3.76 (+0.261) | pass | pass |
| Gallery | Dark IC | 662 / 662 | Account ink Jade on selected row 3.52 (+0.020) | 123 / 123 | Swipe button icon and label (white) on Archive's fill 4.81 (+0.311) | pass ¹ | pass |
| Rain | Light | 662 / 662 | Tag edge on the selected Settings account row 3.18 (+0.184) | 123 / 123 | Tag edge on the selected Settings account row 3.48 (+0.482) | pass | pass |
| Rain | Dark | 662 / 662 | Primary button label, hover 4.57 (+0.074) | 123 / 123 | Swipe button icon and label (white) on Archive's fill 4.70 (+0.204) | pass | pass |
| Rain | Light IC | 662 / 662 | Account ink Lilac on hovered rail tile 3.55 (+0.054) | 123 / 123 | Account ink Lilac on selected row 3.77 (+0.273) | pass | pass |
| Rain | Dark IC | 662 / 662 | Checkbox / radio on fill vs sheet 3.04 (+0.039) | 123 / 123 | Swipe button icon and label (white) on Archive's fill 4.82 (+0.321) | pass | pass |
| Grove | Light | 662 / 662 | Tag edge on the selected Settings account row 3.17 (+0.166) | 123 / 123 | Tag edge on the selected Settings account row 3.48 (+0.476) | pass | pass |
| Grove | Dark | 662 / 662 | Primary button label, hover 4.60 (+0.104) | 123 / 123 | Swipe button icon and label (white) on Archive's fill 4.67 (+0.174) | pass | pass |
| Grove | Light IC | 662 / 662 | Account ink Lilac on hovered rail tile 3.55 (+0.047) | 123 / 123 | Account ink Lilac on selected row 3.76 (+0.258) | pass | pass |
| Grove | Dark IC | 662 / 662 | Account ink Jade on selected row 3.52 (+0.025) | 123 / 123 | Swipe button icon and label (white) on Archive's fill 4.81 (+0.311) | pass | pass |
| Dusk | Light | 662 / 662 | Tag edge on the selected Settings account row 3.19 (+0.186) | 123 / 123 | Tag edge on the selected Settings account row 3.50 (+0.504) | pass | pass |
| Dusk | Dark | 662 / 662 | Primary button label, hover 4.58 (+0.076) | 123 / 123 | Swipe button icon and label (white) on Archive's fill 4.70 (+0.204) | pass | pass |
| Dusk | Light IC | 662 / 662 | Account ink Lilac on hovered rail tile 3.55 (+0.048) | 123 / 123 | Account ink Lilac on selected row 3.76 (+0.258) | pass | pass |
| Dusk | Dark IC | 662 / 662 | Account ink Jade on selected row 3.54 (+0.039) | 123 / 123 | Swipe button icon and label (white) on Archive's fill 4.84 (+0.341) | pass | pass |

¹ Inkless: “no account ink within 15 ΔE00 of the ink” is read as under Graphite, and R5 holds 13 instead; Study under the Graphite system accent shows the same distance.

The theme rules' values:

| Theme | Mode | R1 sheet vs white ΔE / C* | R2 focus on the page | R3 fill vs asset | R4 largest neutral move | R5 ink vs info, normal / CVD | R5 ink vs nearest account, CVD | R6 text vs meanings, CVD | R7 nearest banner to sheet or paper | R7 nearest banner to canvas | R8 key vs idle wash | R9 avatar margin |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Study | Light | 1.53 / 1.56 | 8.3 | 0.0 | 0.0 % | 13.0 / 5.2 | 4.7 Jade | 7.8 (ink3, success) | 6.7 successWash | 6.1 warningWash | 9.4 | +0.0 |
| Study | Dark | — | — | 0.0 | 0.0 % | 16.7 / 5.8 | 4.5 Graphite | 8.3 (ink2, success) | 7.7 warningWash | 10.4 warningWash | 12.9 | +0.0 |
| Study | Light IC | 0.00 / 0.00 | 11.5 | 0.0 | 0.0 % | 13.9 / 5.6 | 3.9 Mulberry | 7.9 (ink3, success) | 11.9 infoWash | 10.7 successWash | 11.3 | +0.0 |
| Study | Dark IC | — | — | 0.0 | 0.0 % | 15.9 / 3.2 | 2.7 Lilac | 5.9 (ink3, danger) | 13.6 warningWash | 16.7 warningWash | 15.9 | +0.0 |
| Gallery | Light | 0.20 / 0.00 | 17.2 | 22.4 (n/a) | 0.5 % | 28.5 / 27.9 | 13.4 Umber | 12.2 (ink3, success) | 7.3 infoWash | 6.7 infoWash | 2.2 (n/a) | +0.8 |
| Gallery | Dark | — | — | 39.7 (n/a) | 0.6 % | 22.8 / 21.7 | 12.9 Lilac | 13.4 (ink2, success) | 9.8 warningWash | 11.3 infoWash | 4.2 (n/a) | +0.7 |
| Gallery | Light IC | 0.00 / 0.00 | 19.3 | 18.7 (n/a) | 0.7 % | 26.1 / 24.3 | 13.0 Umber | 11.4 (ink3, success) | 11.5 infoWash | 10.0 infoWash | 1.4 (n/a) | +2.9 |
| Gallery | Dark IC | — | — | 46.4 (n/a) | 0.6 % | 18.5 / 17.8 | 9.4 Fern | 10.6 (ink3, danger) | 14.6 infoWash | 16.7 infoWash | 4.5 (n/a) | +0.3 |
| Rain | Light | 0.67 / 0.61 | 11.7 | 6.5 | 0.5 % | 21.6 / 12.1 | 4.6 Indigo | 13.1 (ink3, success) | 7.3 infoWash | 6.7 infoWash | 6.1 | +0.2 |
| Rain | Dark | — | — | 4.9 | 0.5 % | 20.7 / 6.1 | 5.7 Lilac | 13.8 (ink2, success) | 8.8 infoWash | 10.5 infoWash | 9.9 | +0.4 |
| Rain | Light IC | 0.00 / 0.00 | 13.8 | 2.6 | 0.4 % | 17.6 / 8.8 | 4.2 Indigo | 13.2 (ink3, success) | 11.1 infoWash | 8.7 infoWash | 6.3 | +2.3 |
| Rain | Dark IC | — | — | 4.9 | 0.5 % | 18.7 / 3.2 | 2.8 Lilac | 12.3 (ink3, success) | 13.7 infoWash | 15.5 infoWash | 11.9 | +1.2 |
| Grove | Light | 1.28 / 1.08 | 12.5 | 7.4 | 0.6 % | 24.6 / 13.5 | 4.7 Indigo | 8.3 (ink3, success) | 7.6 infoWash | 6.5 successWash | 7.9 | +0.2 |
| Grove | Dark | — | — | 7.1 | 0.5 % | 23.2 / 11.5 | 4.3 Lilac | 9.1 (ink3, danger) | 9.1 warningWash | 11.0 warningWash | 11.5 | +0.5 |
| Grove | Light IC | 0.00 / 0.00 | 15.0 | 5.4 | 0.6 % | 21.6 / 11.0 | 3.9 Indigo | 8.3 (ink3, success) | 11.1 successWash | 7.2 successWash | 8.8 | +1.2 |
| Grove | Dark IC | — | — | 7.0 | 0.5 % | 20.8 / 7.4 | 5.1 Graphite | 6.0 (ink3, danger) | 14.1 warningWash | 16.7 warningWash | 13.8 | +0.1 |
| Dusk | Light | 0.57 / 0.51 | 8.3 | 2.1 | 0.6 % | 13.4 / 4.6 | 4.3 Jade | 17.2 (ink2, success) | 7.8 infoWash | 6.6 infoWash | 7.9 | +0.1 |
| Dusk | Dark | — | — | 6.3 | 0.4 % | 13.3 / 3.3 | 3.1 Lilac | 19.8 (ink2, success) | 7.9 infoWash | 10.0 infoWash | 13.7 | +1.8 |
| Dusk | Light IC | 0.00 / 0.00 | 11.8 | 1.0 | 0.4 % | 13.9 / 5.7 | 3.2 Mulberry | 15.5 (ink3, success) | 10.5 infoWash | 7.7 infoWash | 11.9 | +0.8 |
| Dusk | Dark IC | — | — | 2.0 | 0.4 % | 14.1 / 4.4 | 2.8 Lilac | 16.9 (ink, success) | 13.6 infoWash | 15.6 infoWash | 15.4 | +2.5 |

**Links, both flags.** Every link: link buttons (`.ss-link`), invitation links (`.ss-ilink`) and every link in adapted and Quire-set bodies (`ss-links`, §8.4). Links in quotes: links inside `blockquote` and `.ss-quote` in Quire-set bodies (`ss-qlinks`). Under Graphite both are on in every theme. Study needs neither flag in any mode, so Study draws its links as before.

| Theme | Mode | ink vs `ink`, normal / worst CVD | Every link at rest (`ss-links`) | ink vs `ink2`, normal / worst CVD | Links in quotes at rest (`ss-qlinks`) |
|---|---|---|---|---|---|
| Study | Light | 23.8 / 22.3 | — | 19.1 / 15.4 | — |
| Study | Dark | 25.7 / 19.7 | — | 22.1 / 16.3 | — |
| Study | Light IC | 19.3 / 17.6 | — | 16.9 / 13.2 | — |
| Study | Dark IC | 20.9 / 13.9 | — | 20.6 / 14.3 | — |
| Gallery | Light | 0.0 / 0.0 | **underline** | 17.5 / 17.5 | — |
| Gallery | Dark | 0.0 / 0.0 | **underline** | 13.1 / 13.1 | **underline** |
| Gallery | Light IC | 0.0 / 0.0 | **underline** | 12.4 / 12.4 | **underline** |
| Gallery | Dark IC | 0.0 / 0.0 | **underline** | 8.5 / 8.5 | **underline** |
| Rain | Light | 15.3 / 10.7 | — | 13.5 / 7.9 | **underline** |
| Rain | Dark | 20.8 / 11.2 | — | 16.2 / 6.7 | **underline** |
| Rain | Light IC | 15.4 / 12.3 | — | 10.0 / 5.9 | **underline** |
| Rain | Dark IC | 22.9 / 13.2 | — | 15.4 / 5.3 | **underline** |
| Grove | Light | 16.3 / 11.0 | — | 16.9 / 12.1 | — |
| Grove | Dark | 19.5 / 10.3 | — | 18.6 / 12.7 | — |
| Grove | Light IC | 15.1 / 10.1 | — | 13.3 / 10.0 | **underline** |
| Grove | Dark IC | 22.7 / 10.9 | — | 17.5 / 8.3 | **underline** |
| Dusk | Light | 24.9 / 20.0 | — | 19.9 / 8.8 | **underline** |
| Dusk | Dark | 25.3 / 14.8 | — | 24.0 / 12.4 | — |
| Dusk | Light IC | 19.2 / 16.5 | — | 15.8 / 7.0 | **underline** |
| Dusk | Dark IC | 17.8 / 12.3 | — | 20.3 / 6.9 | **underline** |

**Switching.** Live, with no relaunch, Settings included and keyboard focus kept (§5.40). The theme is one field in the environment snapshot every colour provider already reads (`QuireEnvironment.theme`), one SwiftUI environment value (`quireTheme`), one redraw sweep of every window, and one replaced `<style id="ss-theme">` in each reader document (§8.2–§8.4). Colour never changes a height, so a switch measures nothing: the list is redrawn within 50 ms and every pooled reader shell restyled within 100 ms, and nothing runs at idle (the Theme row of the budgets in `docs/ARCHITECTURE.md`). Study's reader stylesheet is empty; another theme's is at most about 7.7 KB per shell and 2.2 KB per body document, holding only what differs from Study.

**Limits the check makes visible.**

- Study's own Stone avatar face sits close to Study's `selWashIdle` in Light and Light IC. That is today's look, and R9 measures every other theme against it; changing it would change the default, so it waits for a change made on its own terms.
- Study's ink is close to Lilac under deuteranopia in Dark IC; R5 takes Study's value as the floor there.
- The new inks sit near their floors by construction: each is the quietest that clears the rules, and the build re-checks them on every change to Study's table.
- In Light and Light IC the coloured inks cluster (point 2). The papers carry those themes by day and the inks separate at night; a wider band would mean changing account inks per theme, which would change an account's colour with the theme.
- Links inside quotes are underlined at rest in more modes than every link, because a blue or teal ink sits near a blue-grey or tinted `ink2`. Only links inside quotes in Quire-set bodies are affected.
- Under the system Graphite accent, a link its sender left uncoloured stays the ink on the page, as before 1.8, so it can vanish beside dark text when the sender also removed its underline.

### 4.17 Pointer (1.8.1)

The pointer tells what a click will do before it is made.

| Over | Pointer |
|---|---|
| Anything a click acts on: buttons of every kind (icon, text, link-style, Download and Download all, toolbar, header and footer actions, banner actions and dismiss crosses, invitation answers, Send and its drop-down, a toast's Undo), every link (in message bodies too, the ones the reader linked in plain text included, a phone number, which opens in FaceTime, and a link to a place in its own message, which scrolls the reader there, whatever cursor the sender's CSS asks for), chips, tiles (rail folders and accounts, theme tiles), rows (conversation rows, Settings' account rows, a collapsed message, the fold), each recipient of the open list and the sender's address (§5.14), the recipients toggle, popup and menu buttons, checkboxes, radios, toggles, tabs, disclosure controls, a scrim that a click closes | the pointing hand |
| Text that takes typing or selection: a field's whole face (its padding, glyph and keycap too, since a click there puts the caret in the field), the Later sheet's time digits, the composer, message bodies (a body's link that a click does nothing with, to `#` or to an inline picture, included), the reader's headline | the I-beam |
| A control that is disabled, or that a click would leave as it is: a loading button, the pending account tile, the chosen radio, theme tile or tab; words, keycaps, running heads, the open list's labels, commas and gaps, an overlay scroller while it shows, and every other surface | the arrow |
| Rows, files and pictures being dragged (§5.2, §5.7, §5.20, §5.22) | the system's move and copy pointers, unchanged |
| A window's edge, a split divider | the system's resize pointers, unchanged |
| AppKit's own chrome, which the app neither draws nor can lay a view on: a window's title-bar buttons (close, minimise, zoom), the menu bar and every menu (context menus, More, Later, Send options, a popup's list), the Settings window's toolbar tabs, the open panel (Attach, Insert Picture), Quick Look | the system's own pointer, unchanged |

- A control's pointer covers its hit rect (§4.14), never the focus-ring margin, and one region alone lies under any point: a control inside another (a field's clear button, the sync line's link, the find bar's buttons) keeps its own, and its container leaves that area out.
- A surface that lies on something clickable shows the arrow, so nothing under it shows through: the find bar and the quick reply on the reader's page, a toast on the list, the composer's suggestions and link popover on its fields and body, the cheat sheet's panel on its scrim. The G-sequence HUD takes no clicks, which go to the rows under it, so it shows theirs.
- A text view's or field's I-beam is its own bounds, cut out of what lies on it, never AppKit's over its visible rect, which reaches past them now that views no longer clip to their bounds: the composer's editor leaves the quote's chip and attribution and the failed-send banner their own pointers.
- An overlay scroller takes the click only while it shows: the rows and the page under it leave it the arrow then, and have its strip back once it fades.
- **AppKit.** Every `QuireControl` is a `QuirePointerTarget`: it adds `pointerCursor` over its hit rect as a cursor rect (a loading button, a field and a group's chosen radio override it), and `pointerRegions` lists the rects with the controls inside cut out (`QuirePointerRegion`). Another view that acts on a click adopts `QuirePointerTarget`; a control AppKit makes, such as an alert's buttons, gets a `QuirePointerOverlay`; the Later sheet's calendar gets one over all of it, its caption, weekday letters and past days included, since AppKit tells nothing of where they lie and its cell's hit test calls every point of it trackable. A surface laid over others adopts `QuirePointerCover`, and the targets and text views under it leave its frame out (`pointerCoverAreas()`), asked again once per turn of the run loop when it comes, goes, hides or its frame changes. A text view or field adds its I-beam with `addTextPointerRects()`, and a field being edited leaves the field editor's clip without the arrow AppKit gives it. Cursor rects apply in the key window only, so the undo-send panel's action, in a panel that never becomes key, also sets the pointer from its tracking area (§5.31), and takes it back when it goes, hides or changes under a resting pointer.
- **SwiftUI.** Every Quire style and control applies `.quirePointer()`, which is `.pointerStyle(.link)` while the control is enabled and acts; a `QuireButtonLabel` that is loading tells its button's style, which then shows the arrow; a field or text area takes `.horizontalText` over its whole face. SwiftUI shows no hand over a link inside text, so the inline link (§5.38, §5.40) lays a box with the hand over its own words.
- **Reader.** The shell has two rules: `button, [role="button"]` take `cursor: pointer`, and `:disabled` or `aria-disabled` ones `default`, as does the invitation's chosen answer, which a click leaves as it is (§5.14). Body documents set every element back to `auto` (the I-beam over text, the arrow elsewhere), then `cursor: pointer` on every `a[href]` and `area[href]`, and on a sender's `summary`, which opens its `details` with no script, then `text` on a link to `#` or to an inline picture, which a click leaves as it is; each is `!important` and as specific as the one before it or more, so a sender's sheet never wins (§8.4). The sanitizer drops a sender's `cursor` declarations. A click on a phone number opens it in FaceTime; one on a link to a place in its own message scrolls the reader to that place.

---
## 5. Components

Conventions: metrics in points; x and y from the component's top-leading corner; a row height includes its bottom hairline. Unless a component says otherwise its states are: **hover** = `hover` wash, glyph and text to `ink`, no animation; **pressed** = `pressed` wash (link buttons, checkbox and radio on fills and toggles have their own hover and press, §5.24 and §5.26, so that no wash ever pulls a state mark under its floor); **focused** = the focus ring (§4.1); **disabled** = `inkDisabled` text and glyph, no wash, no hover feedback, the arrow (§4.17); **window not key** = only the marks listed in §3.4 change (selection wash and rule, the quick reply's mode underline, primary buttons, focus rings); every other mark, the ink's included, stays. Every metric table below is rendered from `layout.<component>` in `tokens.json`.

### 5.1 App window and title bar

Anatomy: rail (76; 84 from macOS 26 on, §3.2) · list pane (364 default, 300–480, user-resizable, autosaved; its maximum gives up 28 pt while the day column is on, §3.2) · reader (flexible) · day column (240, fixed, on by default, folding to a 28 pt strip while the reader would fall under 400 beside it, §5.54). Pane dividers are hairlines with a 6 pt `NSSplitView` hit area. The split view keeps its three items: the reader's holds the reader and, at its trailing edge, the day column, which has no divider to drag (one width, nothing to remember), only its own leading hairline. Each pane paints its own background up to the top edge: rail `spine`, list, both headers and the day column `paper`, reader desk `canvas`, the strip `canvas`.

The default width (1304) is the macOS 26 rail, the default list, the narrowest reader that keeps its keycaps (616, §5.36) and the day column, so a new window's reader keeps its keycaps beside the column (§3.2).

`layout.window`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `dividerHit` | 6 | `defaultWidth` | 1304 | `defaultHeight` | 800 | `minWidth` | 960 |
| `minHeight` | 600 | `titlebarZone` | 52 | `composerTitlebar` | 28 | `composerTitlebar26` | 32 |
| `readerMinWidth` | 400 | `readerNarrow` | 560 | `readerKeycapsMin` | 616 |  |  |

| State | Treatment |
|---|---|
| Key | coloured traffic lights; the ink's selection, mode underline `ink`, primary buttons filled |
| Not key | system grey lights; exactly the §3.4 list changes (idle selection, `ink3` underlines, primary buttons as secondary, no focus ring); the unread pip and unread time, badges and every other mark stay |
| Full screen | traffic lights hidden by the system; layout unchanged, title-bar zone keeps 52 pt |
| Minimal mode (⌃⌘S, View › Hide Account Rail) | rail width 0, **instantly** in every mode (the split view snaps in one frame, so no row re-truncates and no iframe re-measures over frames); the masthead moves to x = rail width + 8 (84 on macOS 15, 92 from macOS 26 on, §3.2) and becomes the title menu's button again (chevron, §5.4), with the views and an Accounts section, so every folder and account the rail held is still a click away; search and compose keep the header line and search takes the width that is left (§5.3); `⌘0…⌘9` and the G-sequences keep working |
| Live resize | the list keeps its width; the reader takes the change, the day column keeping its 240 pt until the reader would fall under 400, when it folds to its strip in one frame (and back); the reader re-fits wide HTML (§5.14) once, when the resize ends |
| Day column (on by default; D, View › Hide Day or the calendar toggle at the window's trailing edge; §5.54) | the column at the reader's trailing edge, the window's full height, its header sharing the horizon; hidden, the reader takes its 240 pt back **instantly**, as the rail (all but the 28 pt strip that keeps the toggle once some account has granted the calendar permission); the window keeps the choice across launches, as it keeps a hidden rail |
| Day column folded (window width − rail − list − 400 < 240) | the 28 pt strip in the column's place; a click on it or D opens the whole column over the reader's trailing edge until Esc, D or a click in the reader (§5.54) |
| Week (W, View › Show Week, the week button in the day column's header) | the week takes the reader's place and the column's; W or D brings both back (§5.54) |
| Narrow reader (< 560 pt) | column margins 16, sheet padding x 16 (§5.14); below 616 pt the reader's keycaps hide (§5.36) |

### 5.2 Account rail and its items

Anatomy, top to bottom: title-bar zone (traffic lights) · **the folders**, one tile per view in the title menu's order: Inbox at y = 62, then Starred, Sent, Drafts and Trash at a 44 pt pitch, a 20 pt hairline at y = 285, and All Mail at y = 294; while something in the scope is snoozed the **Later** tile sits directly below Inbox, at y = 106, and Starred to Trash, the hairline and All Mail each move down one pitch (Starred at 150 … Trash at 282, the hairline at 329, All Mail at 338); while a message in the scope is on its way the **Outbox** tile sits between Drafts and Trash, at y = 238, and Trash, the hairline and All Mail each move down one pitch (Trash at 282, the hairline at 329, All Mail at 338); with both, each shown tile takes its pitch: Later at 106, Starred at 150, Sent at 194, Drafts at 238, the Outbox at 282, Trash at 326, the hairline at 373 and All Mail at 382 · flexible space · **the accounts**, anchored just above Add: the All Inboxes tile, a 20 pt hairline 16 pt below it, then the account tiles from 14 pt below the hairline at a 50 pt pitch · Add · Settings. Opaque `spine`, trailing hairline. All y values are top edges: Add's 28 pt button has its **top** at bottom − 92, Settings' top at bottom − 52. The account stack's clip ends 12 pt above Add's top and the last tile ends 6 pt inside it, so in the default 800 pt window with three accounts the last tile spans 652–690, the first starts at 552, the hairline is at 538 and All Inboxes starts at 484.

- **Folder tiles**: 38 pt, radius `r.tile`, the view's symbol (`tray`, `star`, `paperplane`, `doc`, `trash`, `archivebox`) 16 pt in `ink2`, with the All Inboxes tile's washes, raised selection and focus ring, but no margin rule: the rail carries two selections, the view (the raised tile) and the scope (the margin rule), and they must read apart. A click switches the view as the title menu does (§5.4); the G-sequences are unchanged. Inbox carries the unread count badge of the current scope's Inbox (all accounts, or the narrowed one; the count the title menu's Inbox item carries); the other folders carry none. Tooltips name the folder and its sequence: “Inbox  G I”, “Starred  G S”, “Sent  G T”, “Drafts  G D”, “Trash  G #”, “All Mail  G A”.
- **Later tile** (§5.45): `clock` 16 pt, the folder tiles' looks and states, shown only while at least one conversation in the current scope (all accounts, or the narrowed one) is snoozed, and gone the moment the last one comes back or ends, or the scope moves to an account with none; its list returns to the Inbox then (a search typed there stays, §5.45). The tiles move instantly, as everything in the rail does. Tooltip “Later  G L”; no badge (what is snoozed is not waiting to be read); it takes no drop (a snooze needs a time, which a drop cannot give). ↑/↓ step over it while it is hidden; if it has the keyboard as it goes, the Inbox tile takes it.
- **Outbox tile** (§5.53): `tray.and.arrow.up` 16 pt, the folder tiles' looks and states, shown only while at least one message in the current scope (all accounts, or the narrowed one) is on its way, that is listed in the Outbox, and gone the moment the last one has gone (taken by the provider, kept in Drafts as failed, cancelled, continued or taken back by its Undo), or the scope moves to an account with none; its list returns to the Inbox then (a search typed there stays, as from Later). A failed send may show it for the moment before it is kept in Drafts; a send leaving as another arrives never hides it, since the rail reads the whole outbox at once. Tooltip “Outbox  G O”; no badge (what is on its way is not waiting to be read); it takes no drop (a message on its way is not mail a drop could move there), and rows dragged out of it drop nowhere. ↑/↓ step over it while it is hidden; if it has the keyboard as it goes, the Inbox tile takes it.
- **Dropping rows**: conversation rows dragged from the list (§5.7) drop on four folders: Inbox moves them to the Inbox, Trash trashes them, Starred stars them and All Mail archives them, exactly as ⇧I, #, S and E do on those conversations, as one change for every dragged row with that key's toast and Undo (in Drafts, Trash is Discard Draft…, asked first, as # is there; §5.12), except that Starred only ever stars. Sent, Drafts, Later, the Outbox, All Inboxes, the account tiles and the utilities take no drop; rows dragged out of Later onto Inbox move back now and end their snooze, as ⇧I does there. A folder refuses a drop that would change nothing the list shows: the selected folder outside a search (its rows are already there; a search lists the rows of the view it looks through, All Mail or the one an `in:` term picks (§5.6), so then only the rows decide, except that Trash refuses `in:trash` results, as # does nothing there), Inbox for rows all in the Inbox, Starred for rows all starred, All Mail for rows none of which is in the Inbox; a refused drag lights nothing and ends where it began. Only the list's own rows are taken: files, text and another app's drags are refused. A drag counts over the 44 pt hit square, as a click does, and nowhere else: the folders' squares abut, so a drag at one square's rim never lands on its neighbour. The cursor shows a move, or a copy while ⌥ is held, following the modifiers as they change over a folder.
- **All Inboxes tile**: 38 pt, radius `r.tile`, `ss.quire` 18 pt in `ink2`; the first tile of the account group.
- **Account tile**: a 30 pt face (the account ink at 0.14 opacity over `sheet`), the domain monogram in New York Semibold 14 pt (12 pt for two letters; `monogramSans` under the SF Pro font, §5.29) in `ink`, and a 2 pt ring in the account ink outside a 2 pt `spine` gap (38 pt overall).
- **Badge**: unread count badge (§5.28) at top -5, trailing -8 relative to the tile, with a 2 pt `spine` cut-out ring. Inbox, All Inboxes and the account tiles read their counts in the same words as the Dock (“99+” above 99, no badge at 0), and the tile's VoiceOver help says the real number (“1,234 unread”).
- **Utilities**: 28 pt icon buttons, `plus` / `gearshape` 15 pt. Add opens the add-account menu (§5.44).
- **Margin rule**: 3 × 24 pt at x = 0, centred on the selected account tile or All Inboxes; never on a folder.
- **Capacity.** The account group sits as low as it can and rises as accounts are added, until the All Inboxes tile would come closer than 20 pt to All Mail's tile (its top at 294 + 38 + 20 = 352). From then on All Inboxes and its hairline stay there and the account tiles scroll inside their own clip view, from 6 pt above the first tile (room for the badge overhang) down to 12 pt above Add's top. Without scrolling, one account fits at the 600 pt minimum height, five at the default 800 pt and seven at 900 pt; while the Later tile or the Outbox tile shows All Mail sits a pitch lower, so All Inboxes stops at 396 and each figure is one fewer (none at the minimum height, four at the default, six at 900 pt), and while both show two pitches lower, so All Inboxes stops at 440 and each figure is two fewer (three at the default, five at 900 pt; at the minimum height the account tiles' clip has no room left at all, so the accounts are reached with ⌘1…⌘9 until the window is taller, one fitting from 656 pt). While tiles are clipped a `rule` hairline marks the clipped edge (bottom, and top once scrolled); the scroller shows only while scrolling; ⌘1…⌘9 and ↑/↓ scroll the chosen tile into view instantly. Tiles never overlap the folders or the utilities.

`layout.rail`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `width` | 76 | `lightsClearance` | 4 | `width26` | 84 | `tile` | 38 |
| `tileHit` | 44 | `tileRadius` | 11 | `tileCenterX` | 38 | `folderTop` | 62 |
| `folderPitch` | 44 | `folderGlyph` | 16 | `folderDividerY` | 285 | `allMailTop` | 294 |
| `dividerWidth` | 20 | `groupGap` | 20 | `dividerGap` | 16 | `accountGap` | 14 |
| `accountPitch` | 50 | `face` | 30 | `faceAlpha` | 0.14 | `monogram` | 14 |
| `monogramTwoLetter` | 12 | `utility` | 28 | `utilityGlyph` | 15 | `addTopFromBottom` | 92 |
| `settingsTopFromBottom` | 52 | `marginRuleHeight` | 24 | `badgeTop` | -5 | `badgeTrailing` | -8 |
| `unifiedGlyph` | 18 | `stackBottomGap` | 12 | `stackInset` | 6 | `pendingSpinner` | 16 |
| `addMenuOffsetY` | 4 |  |  |  |  |  |  |

| State | Folder tiles and All Inboxes | Account tile |
|---|---|---|
| Rest | glyph `ink2`, no fill | face + ring + monogram |
| Hover | 44 pt `hover` wash, radius `r.xl`; tooltip “Inbox  G I”, “All Inboxes  ⌘0” | same wash (it sits under the ring; `spine + hover` is an asserted ring surface); tooltip “Contoso · alex@contoso.test  ⌘1” |
| Pressed | 44 pt `pressed` wash | the hover wash stays and a `pressed` wash darkens only the 30 pt face, never the gap or the ring, so every account ink keeps ≥ 3:1 (≥ 3.5:1 in IC) against what is beside it |
| Selected | `raised` fill, `rule` edge, `e1`, glyph `ink`; All Inboxes adds the margin rule `selRule`, a folder never does | margin rule `selRule` |
| Selected, window not key | All Inboxes: margin rule `selRuleIdle`; a folder: unchanged | margin rule `selRuleIdle` |
| Drop target (§5.7 rows over a folder that takes them) | Inbox, Starred, Trash, All Mail (never Later or the Outbox): the 44 pt `pressed` wash and glyph `ink`, the look of a click, while the drag is over the hit square; it never takes focus (no ring) and never switches the view (no spring-loading). A folder refusing the drag shows nothing | — (takes no drop) |
| Focused (Tab enters the folders on the selected folder and the accounts on the selected account; ↑/↓ move within each group and choose) | ring outside the tile, 2 pt gap | ring outside the account ring |
| Unread | count badge (“99+” above 99, none at 0, §5.28): Inbox and All Inboxes only (never Later or the Outbox) | same, the account's Inbox |
| Needs sign-in | — | attention badge (`dangerFill`, `exclamationmark`) replaces the count; tooltip “Sign in required” |
| First sync | — | 12 pt spinner replaces the badge |
| Reconnecting (§5.44) | — | the attention badge **stays**: the account still needs sign-in until the browser finishes, and an abandoned sign-in must not look like progress. The tooltip reads “Finish signing in in your browser…”; the tile gets no spinner (the sync line carries the wait and its Cancel) |
| Signing in (pending tile, §5.44) | — | a placeholder at the end of the stack: 30 pt `fill` face with a 1 pt dashed `ruleStrong` ring and a 16 pt `ink3` spinner; tooltip “Finish signing in in your browser…”; not selectable |
| Collision monogram | — | two letters at 12 pt |
| Drag to reorder | — | tile lifts with `e2`; others shift instantly |

Add and Settings: rest `ink2`; hover `hover` wash (radius `r.md`), glyph `ink`; pressed `pressed` wash; Add shows `pressed` while its menu is open; focused ring with a 1 pt `spine` gap.

### 5.3 List header

One row, 52 pt: the title-bar zone itself, `paper`, its bottom hairline at y = 52. Everything in it is centred on y = 26, the traffic lights' centre line, in this order:

- **Masthead** at x = 16 (rail width + 8 in minimal mode, §5.1): the view's name in `masthead` (New York 20/24). With the rail showing it is a plain title, not a control: the folders are in the rail, so it has no chevron, no hover, no menu and no Tab stop, VoiceOver reads it as a heading, and a click on it drags the window like the rest of the zone. In minimal mode it is the title menu's button (§5.4): `chevron.down` 9 pt Semibold `ink2` after 6 pt, hit area text + chevron + 6 pt padding, radius `r.md`. After it, in this fixed order and only when they apply: the minimal-mode new-mail dot (8 pt `accent`, 8 pt after the chevron; shown in minimal mode when another account has new mail), the “Demo” tag (8 pt after the previous item, §5.43), and, narrowed to one account, “· alex@contoso.test” in `snippet` `ink3` (6 pt after the previous item).
- **Search** (§5.6): from 12 pt after the masthead cluster to 8 pt before compose.
- **Compose**: 28 pt icon button, `ss.nib` 18 pt, trailing 12, top 12.

**Who gives way.** The search field takes the free width between the cluster and compose, at rest never starts before the cluster ends (while it has the keyboard it covers the cluster, §5.6), and keeps at least 140 pt while anything else on the line can make room for it, in this order:

1. **The address** truncates (tail), and drops out whole when less than 40 pt of it would show (a lone “· a…” names nothing). While it is off the line the placeholder names the account instead (“Search Contoso”, or “Contoso” alone where that would be cut, §5.6), so the narrowed scope is always on screen; in minimal mode nothing else shows it.
2. **The Demo tag** steps off the line whole, and out of the Tab order, when the field beside it would be narrower than its minimum. The window title and the sync line still say Demo, and its menu's commands are in the File menu (§5.43). The address, which gave way first, stays off while the tag is.

The masthead text, the chevron and the dot never give way. When they alone leave less than 140 pt the field narrows to what is left, drops its keycap before its placeholder and ends the placeholder with an ellipsis. That happens only in minimal mode, where the masthead starts at 84 (92 from macOS 26) and carries the chevron: at the default list width for Starred and All Mail (and Drafts from macOS 26) and whenever the dot shows, and at the 300 pt list minimum in every view, down to 51 pt (All Mail with the dot; 43 pt from macOS 26). Beside the rail the masthead alone always leaves the minimum, so there the field never goes below 140 pt; on a list at its minimum width the Demo tag is off the line.

Worked numbers, with the rail, in Inbox, at the default list width (the header is 363 pt, the pane less its divider): the field runs from x = 82 to 315 (233 pt); with the Demo tag, which ends at x = 132, from 144; narrowed to alex@contoso.test, the address shows 87 of its 111 pt and the field is 175–315, exactly the minimum. In minimal mode (masthead at 84), narrowed, with the dot, the address is off the line and the field runs from x = 182 to 315 (133 pt), a point short of the 134 pt “Search Contoso” needs, so it reads “Contoso”; without the dot it is 149 pt and reads “Search Contoso”.

`layout.listHeader`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `mastheadHitPad` | 6 | `height` | 52 | `mastheadX` | 16 | `mastheadMinimalX` | 84 |
| `mastheadMinimalX26` | 92 | `mastheadMinimalGap` | 8 | `mastheadCenterY` | 26 | `chevronGap` | 6 |
| `chevron` | 9 | `composeSize` | 28 | `composeGlyph` | 18 | `composeTrailing` | 12 |
| `composeTop` | 12 | `searchHeight` | 26 | `searchTop` | 13 | `searchMinWidth` | 140 |
| `searchGap` | 12 | `searchComposeGap` | 8 | `minimalDotSize` | 8 | `minimalDotGap` | 8 |
| `demoTagGap` | 8 | `addressGap` | 6 | `addressMinWidth` | 40 |  |  |

States of the masthead in minimal mode: rest; hover (`hover` wash behind text and chevron); pressed / menu open (`pressed`); focused (ring around the hit area); window not key (unchanged). With the rail showing it has none.

### 5.4 Title menu

A system `NSMenu` popped from the masthead in minimal mode only: with the rail showing, the folders and accounts are in the rail and the masthead is a plain title (§5.3). Left-aligned to the masthead text, 4 pt below it.

| Item | Symbol | Shortcut column |
|---|---|---|
| Inbox | `tray` | G I |
| Later, only while something in the scope is snoozed (the rail's rule, §5.2) | `clock` | G L |
| Starred | `star` | G S |
| Sent | `paperplane` | G T |
| Drafts | `doc` | G D |
| Outbox, only while a message in the scope is on its way (the rail's rule, §5.2, §5.53) | `tray.and.arrow.up` | G O |
| Trash | `trash` | G # |
| — separator — | | |
| All Mail | `archivebox` | G A |
| — separator — | | |
| All Inboxes, then each account | monogram | ⌘0, ⌘1…⌘9 |

The current view has a checkmark. Later and the Outbox are listed exactly while their rail tiles show, in the same places, since the menu stands in for the rail. G-sequences are an attributed title with a right tab stop in `ink3` (`keyEquivalent` cannot express a sequence). Highlight and item states are the system's; under Multicolor the highlight is Iron Gall through the accent asset, in every theme (§3.1).

**Unread counts** are system menu-item badges, never custom fills: Inbox carries the unread Inbox count of the current scope (all accounts, or the narrowed one; the rail's Inbox tile shows the same count, §5.2), and All Inboxes and each account item carry theirs. The menu stands in for the rail, so it says what the rail's tiles say (§5.28): a string badge (`NSMenuItemBadge(string:)`) reading “99+” above 99, where a count badge would print the whole number. Numerals only (and the cap's plus), drawn and coloured by the system, so they stay legible on the highlighted row. Zero shows no badge. Later, Starred, Sent, Drafts, the Outbox, Trash and All Mail carry none.

### 5.5 Filter tabs (removed in 1.4)

Removed: the Inbox always shows all of its mail. Focused and Other split one inbox into two places to check, and the header now has a single line for the masthead, search and compose. The providers' categories are still stored (`inbox_section`) to round-trip provider state, and nothing filters or marks rows by them (§5.7). The section number stays so that references to the sections after it keep their meaning.

### 5.6 Search field

| Part | Spec |
|---|---|
| Size | height 26, top 13 (centred on y = 26); the width fills the header line from the masthead cluster + 12 to compose − 8, at least 140 pt and never under the masthead cluster (§5.3 says what gives way). While it has the keyboard it widens over the masthead cluster to where the masthead text starts (16, or the minimal-mode x), gliding `dur.standard` `ease.glide` while the masthead and the Demo tag fade under it and its face covers the new-mail dot and the address (Reduce Motion: the width snaps and the masthead and Demo tag cross-fade in `dur.reducedFade`, as the motion table says); faded, the cluster takes no click, Tab stop or VoiceOver focus; the placeholder then names the account when the view is narrowed to one, as it does when the address is off the line. Focus leaving gives the cluster back the same way. Compose and the field's height never move, so the list does not move |
| Shape | radius 6, `sheet`, 1 pt `ruleStrong` resting edge |
| Leading | `magnifyingglass` 12 pt `ink3` at x = 8; text and placeholder start at x = 26 |
| Placeholder | “Search” (`body`, `ink3`); “Search Starred” etc. in other views; “Search Inbox” when narrowed; while the header line has no room for the narrowed account's address (§5.3), the account's name in every view: “Search Contoso” (search looks through all of that account's mail but the Trash, whatever the view), or the name alone (“Contoso”, “Demo Gmail”) in a field too narrow to show that whole, since the magnifier already says search and a cut name may not tell two accounts apart |
| Trailing | 5 pt from the trailing edge: keycap “/” (16 pt) when empty and not focused, and only while the whole placeholder fits beside it (a field the header line has narrowed drops the keycap before the word, and a placeholder that has given up its “Search”, the bare account name, never gets the keycap in its place); while results show, the clear button (16 pt `fill` disc, `xmark` 9 pt, 24 pt hit) with “38 results” in `meta` `ink3` 6 pt before it; the query truncates before the count does |

| State | Look |
|---|---|
| Rest | as above |
| Hover | face `sheet + hover` |
| Focused | edge kept, focus ring outside a 1 pt `paper` gap |
| Typing | query `ink`, caret `accent` |
| Searching | a 12 pt spinner replaces the magnifier, only when the first page takes more than 150 ms |
| No results | list shows the empty state (§5.9) |
| Query kept, focus elsewhere | keeps its query, count and clear button with no ring, because the list below is still the result set, until the query is cleared |
| Disabled (no accounts) | `fill`, no edge, `inkDisabled` |

**Leaving.** Focus leaving the field returns it to the free width beside the cluster, a kept query and its count included (truncated as above). Esc in the field clears the query; Esc in an empty field returns focus to the list (§6.1). The clear button clears and keeps focus in the field. ↓ gives the keyboard to the list with the query kept; ↩ does too, after asking the mail server for more (below).

**Searching the server.** ↩ in the field asks the mail server for more while the list offers it, once the local results are all listed (§5.10, Edit › Search Gmail for More), and gives the keyboard to the list, so the results can be walked while the server answers; while the field has the keyboard the offer says so with a “↩” keycap: words typed too recently to have reached the list go to it first, and the search runs as soon as their results are in. After a search, and after a failure, ↩ only gives the keyboard to the list, with no keycap, so coming back to the results never searches every account again: Try again is the row's link and the Edit item. ↓ never asks the server. The server is asked the field's text as typed, operators included, so its own search rules decide what it finds (Gmail reads its own operators, Outlook its search words); the operators below that test the row (`is:`, `has:`, `before:`, `after:`, `in:`) and the account scope still narrow its finds, as they narrow the local results. The field itself shows nothing of it: no spinner, no change to its count until the found rows arrive; the list's last row carries the state.

**Operators.** The field takes a few operators besides words, and nothing else changes: no chips, no suggestions, no syntax colouring, no extra empty state. The cheat sheet's search line lists them (§5.32). Operator names and their keywords ignore case, a value may be quoted (`from:"Ben Carter"`), and several terms all apply. Nothing typed is ever an error: an unknown operator (`label:work`) or a value an operator does not take (`before:yesterday`) is searched as words.

| Term | Finds |
|---|---|
| a word | as before: the word in the subject, the people or the text, the last one typed as the start of a word |
| `"a phrase"` | the words side by side, in order; still being typed while the quote is open |
| `from:` | the sender's name or address (`from:ben`, `from:ben@example.com`, `from:"Ben Carter"`) |
| `to:` | any recipient's name or address: To, Cc and Bcc |
| `subject:` | the subject |
| `is:unread`, `is:read`, `is:starred`, `has:attachment` | what the row shows: its unread dot, its star, its paperclip |
| `after:2026-01-31`, `before:2026/01/31` | the row's date (its latest message) on or after that day, or before it, from local midnight |
| `in:inbox`, `in:sent`, `in:drafts`, `in:trash`, `in:all` | the conversation in that view. The first `in:` picks the view searched in place of the one on screen, Later included (Later and the Outbox have no `in:` of their own: a search typed in either looks through All Mail, as from any view): `in:sent` in the Inbox lists sent mail, and `in:trash` reaches the Trash, which search otherwise leaves out. The account scope still applies |
| `-` before any of these | leaves out what it describes: `-from:ben`, `-"weekly metrics"`, `-is:starred` |

Words, phrases, `from:`, `to:` and `subject:` must all hold in one message, and a minus word or address must not be in it, as Gmail and Outlook read the same query; the other operators test the row. While the last thing typed is the start of a value an operator takes (`is:un`, `before:2026-0`) it waits instead of searching for those letters. Opening a result of an `is:unread` search reads it, as anywhere, and the row stays (read) until another conversation is opened, so the selection never jumps to the next result. Keys, menus, drops on the rail's folders and the reader treat results as rows of the view searched: `in:trash` results restore with ⇧I and # leaves them be, as in the Trash (§5.12), and the Trash folder refuses them (§5.2); L snoozes All Mail results wherever the search was typed, the Trash and Drafts included, and beeps for `in:trash` and `in:drafts` ones (§5.45). An action that takes a result out of the list toasts as it would in that view: archiving in an `in:inbox` search, unstarring in an `is:starred` one.

### 5.7 Conversation row

Fixed **68 pt** (compact 48) at the Default Text size; the other sizes step the row and its lines (§4.15), and every metric below is Default's. Drawn by hand in `layout()` / `draw(_:)`: no Auto Layout, no shadow, no blur, no per-row animation, no layer per sub-element beyond the text labels and the avatar image.

| Element | Frame (x, y, w, h) | Style |
|---|---|---|
| Margin rule (selected) | 0, 8, 3, 52 | `selRule` / `selRuleIdle` |
| Unread pip | 7, 14, 7, 7 (centred on the sender line) | `accent` circle |
| Avatar box | 20, 15, 38, 38: face 30 centred; 2 pt gap; 2 pt ring | face tint, monogram (New York, or `monogramSans` under the SF Pro font), ring = account ink (unified views only). The gap is **not drawn**: it is the row's own fill showing through, so the same face serves every row state |
| Sender line | 68, 10, to the time − 8, 16 | `sender`; Semibold when unread; participants joined by “, ”, the user as “me”; Drafts/Sent prefixes in `ink2`; no sender: “No sender” in the placeholder style (§4.1) |
| Time cluster | trailing 16, on the sender line | from the trailing edge: time (`meta`, tabular, `ink3`; unread: `metaStrong` in `accent`; format per running head, §4.13) · 6 pt (`tileGap`) · optional account initial tile (16 pt) · 6 pt · the “Back” tag (§5.28) on an unread Inbox row back from Later · 4 pt (`queuedGap`) · `ss.queued` or the failed glyph (12 pt). An absent tile or tag takes its leading gap with it: with neither the glyph sits 4 pt from the time. Rows carry no category tag: the Focused/Other category is not shown anywhere (§5.5) |
| Subject line | 68, 27, to the glyph cluster − 6, 18 | `subject` (New York; `subjectSans` when New York lacks the script, and always under the SF Pro font); Semibold when unread; no subject: “No subject” in the placeholder style (italic `ink3`, regular weight even when unread) |
| Glyph cluster | trailing 16, centred on the subject line, 5 pt gaps, fixed order from the trailing edge: star, muted, attachment, count | `star.fill` 12 pt `star`; `bell.slash` 12 pt `ink3` (§5.51); `paperclip` 12 pt `ink2`; count badge 16 pt, neutral |
| Snippet | 68, 46, to trailing 16, 15 | `snippet`, `ink2` |
| Separator | from x = 68 to the trailing edge, bottom | hairline `rule`; hidden on the selected row and the row above it |

`layout.row`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `height` | 68 | `marginRuleY` | 8 | `marginRuleHeight` | 52 | `pipX` | 7 |
| `pipY` | 14 | `pip` | 7 | `avatarBoxX` | 20 | `avatarBoxY` | 15 |
| `avatarBox` | 38 | `avatarFace` | 30 | `textX` | 68 | `trailing` | 16 |
| `senderY` | 10 | `senderHeight` | 16 | `timeGap` | 8 | `subjectY` | 27 |
| `subjectHeight` | 18 | `snippetY` | 46 | `snippetHeight` | 15 | `glyph` | 12 |
| `glyphGap` | 5 | `clusterGap` | 6 | `queuedGlyph` | 12 | `queuedGap` | 4 |
| `accountTile` | 16 | `accountTileRadius` | 3 | `accountTileBorder` | 1.5 | `tileGap` | 6 |
| `separatorX` | 68 |  |  |  |  |  |  |

| State | Fill | Marks | Notes |
|---|---|---|---|
| Read | `paper` | — | Regular weights, time `ink3` |
| Unread | `paper` | pip | Semibold sender, subject and time; time in `accent` |
| Hover | `paper + hover` | — | pointer only, instant; never on a selected row; no hover action buttons in rows; suspended while the list scrolls (below) |
| Pressed | — | — | selection applies on mouse-down |
| Selected, window key | `selWash` | margin rule `selRule` | text unchanged; pip, ring, badge, star keep ≥ 3:1 / 4.5:1 |
| Selected, window not key | `selWashIdle` | margin rule `selRuleIdle` | always drawn |
| Multi-selection | each selected row as above | | ⇧-click, ⌘-click, ⇧J / ⇧K; the reader shows §5.19 |
| Keyboard focus with no selection | `paper` | 2 pt ring inset | Full Keyboard Access only |
| Starred | — | filled `star` | VoiceOver “Starred” |
| Has attachment | — | `paperclip` | |
| Muted (§5.51) | — | `bell.slash` `ink3` beside the star | in every view the conversation is listed in; `ink3`, the time's ink, whose pairs on every row fill are asserted, so it adds no pair; VoiceOver “Muted” |
| Message count ≥ 2 | — | neutral count badge | |
| Queued locally | — | `ss.queued` `ink3` before the time | full contrast, never faded; VoiceOver “Waiting to sync” |
| Operation failed permanently | — | `exclamationmark.triangle.fill` `danger` replaces `ss.queued` | the row is restored locally; toast “Couldn't archive. Restored.”; tooltip and VoiceOver “Couldn't archive”. The triangle stays until the conversation is opened (selected for 150 ms, which acknowledges it), a later operation on it succeeds, or 24 hours pass (`failed_op_kind`, §8.5) |
| Account (unified views) | — | ring; optional initial tile | single-account views drop both; face size unchanged |
| Drafts / Sent views | — | “Draft to Ben Carter” / “To Ben Carter” | |
| Back from Later (Inbox) | — | “Back” tag before the time while unread | the row sorts and shows the time it came back (the later of its newest mail and the return), so last week's mail returns under Today; read, it keeps its place and loses the tag; leaving the Inbox or newer mail ends both (`returned_at`, §8.5), and an undo of the E, # or L that took it out puts both back (§5.45). VoiceOver adds “Back from Later” |
| In Later | — | the time slot reads “Back Tue 09:00” (§4.13) | soonest first, no running heads |
| Send Later (Drafts) | — | the time slot reads “Sends Mon 09:00”, “Sending…” or “Not sent” (§5.46) | the row of a message waiting in the outbox, in place of its draft; the time's tooltip and VoiceOver add “while SuperSparrow is open” |
| Outbox (§5.53) | — | “To Ben Carter”; the time slot reads “Sending…”, “Sends Mon 09:00”, “Not sent”, “Retrying shortly” or “Couldn't send”, the last in `danger` | a message on its way, built from the outbox; soonest to go first, no running heads |
| Dragging | — | system drag image | the row itself is unchanged; Inbox, Starred, Trash and All Mail in the rail take it (§5.2) |
| Swiped | the row's own, moving with the fingers | the button it uncovers: the row's full height in `swipeArchive` or `swipeRead`, its icon and label white (`onSwipe`) | Archive on the trailing edge, Mark as Read or Mark as Unread on the leading one; Swipe, below |

**Swipe.** A two-finger sideways swipe on the trackpad slides a conversation row's content under the fingers and uncovers a button on the edge it leaves: moving left, **Archive** on the trailing edge; moving right, **Mark as Read** on a row with unread mail, else **Mark as Unread**, on the leading edge. Let go with the button open and click it, or carry the swipe across the row to do it at once; one button per edge, so a full swipe has one thing to do. The list draws all of it itself, as Apple Mail does (`RowSwipeController`, `QuireSwipeButton`, §8.2), and never uses AppKit's row actions: AppKit drew their title in a colour the app cannot set (black on the near-black Archive fill in a key window) and moved it out of the capsule under an icon.

- **What is a swipe.** A gesture whose first movement is more sideways than up or down, over a conversation row that offers a change on some edge. Everything else is the table's and scrolls as before: up and down, sideways over a running head, the list tail or the server row, a mouse's wheel, and a scroll's momentum. A swipe's own momentum is swallowed, so a flick's tail neither scrolls the list nor moves the row, and momentum never starts a swipe. A gesture that begins without moving waits for its first movement, then goes whole to the side it turns out to be. The content goes the way the fingers go, with natural scrolling or without.
- **The key's change on that one row.** Archive is E and Mark as Read or Unread is U, applied to the swiped conversation whatever the selection, through the key's own path: store first and queued, E's toast “Archived” with Undo and Z (none for a read change the row itself shows, as with U), swipes within 1000 ms coalescing into one toast and one undo (§5.30), the next row taking a removed row's place in the same frame, the selection moving on as after E when the swiped row was the selected one and staying put otherwise, and Undo selecting the conversation again.
- **Offered only where the key would change the row**, so a swipe never uncovers a button that beeps: Archive where the row has Inbox mail, and in Later on every row (E there ends the snooze and leaves the mail archived, §5.45); no Archive in Trash, Sent, Drafts, Starred or All Mail on a row with no Inbox mail, nor on a snoozed conversation a search found. A search's rows follow the view it looks through, as the keys do. A draft kept on this Mac offers neither button, nor does an Outbox row (§5.53); running heads, the list tail and the server row offer nothing. Toward an edge that offers nothing the content does not move.
- **The button.** The whole area the content uncovers, the row's full height, in the action's fill, with the action's icon above its label, both white (`onSwipe`) and centred in it. The icons are the menus' and the toast's own (§4.11): Archive's `archivebox`, Mark as Read's `envelope.open`, Mark as Unread's `envelope.badge`, at 16 pt medium; the label is the menu's command (“Archive”, “Mark as Read”, “Mark as Unread”), a verb (§4.13), in `label` at the list's Text size, 4 pt under the icon. Icon over label fits every row the swipe can uncover, the compact row at Small included, with room above and below. While the content slides, the button is as wide as what it uncovers: the label shows only where it fits whole with 12 pt either side, fading in over the last 12 pt, never truncated, and the icon rises from the centre to its place above it as the label comes; narrower, the icon shows alone, centred, fading in the same way; narrower still, the fill alone. Open, the button is the label's width with 12 pt either side, never under 80 pt. The pointing hand shows over it (§4.17); a click released on it, or VoiceOver's press, makes the change; it takes no keyboard focus. Each fill holds white at 4.5:1 in every theme and mode and under Graphite (the swipe pairs, §7):

| Button | Fill | Icon and label | Study: Light · Dark · Light IC · Dark IC |
|---|---|---|---|
| Archive | `swipeArchive`: the theme's `accentFill`, as on a primary button | `onSwipe` | `#1E5468` · `#2D788B` · `#123E4D` · `#246F83` |
| Archive under Graphite, and in Gallery | `swipeArchiveNeutral`, because `ink` turns light at night and white would not hold on it: the `slip` by day, and at night a grey of the ramp light enough to stand out from the row, which the slip sinks into, and still dark enough for white | `onSwipe` | `#24221F` · `#79736B` · `#12100E` · `#77716A` |
| Mark as Read, Mark as Unread | `swipeRead`: a grey of the ramp in the theme's paper hue, mid by day and low at night, so it is the quiet button beside Archive on every row; unchanged under Graphite | `onSwipe` | `#726C65` · `#524D47` · `#625C55` · `#4F4A44` |

The two fills stay at least 12 ΔE00 apart, and 9 under every simulated colour-vision deficiency, in every theme and mode and under Graphite, so the edges never look alike, though only one shows at a time and the word names it. Each fill is held against the row it is uncovered beside, at rest, hovered and in both selections, and Archive stands out from it more than Read does on every one of them, in every theme and mode and under Graphite (the fill-beside-the-row pairs, §7, and the build). White at 4.5:1 keeps a fill below about L\* 50, so at night no fill reaches 3:1 beside a selected row: the pairs carry floors of their own, Archive's above Read's. Both are live tokens, never the system accent: an accent the user picked (Yellow, Pink) does not reach them (§3.1). A button that is out follows every change: it draws from the live tokens, and draws again on an appearance change and on every theme, Graphite and Increase Contrast change.
- **Thresholds** (`layout.swipe`). The content follows the fingers one to one. Let go past 0.6 of the row's width (and never closer than half a button past the open width, so a narrow list still leaves room to open it), the change is made. Short of that, past the whole button, or past 0.5 of the open width while still opening, the button stays open; otherwise, and whenever the last movement was back toward rest short of the whole button, the row closes. Past the full-swipe distance the row rubber-bands, slowing toward the row's width and never reaching it (0.55, the scroll view's constant), so the point past which letting go makes the change can be felt. A gesture the system cancels never makes the change. Swiping the open row again carries on from where it is.

`layout.swipe`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `glyph` | 16 | `glyphGap` | 4 | `padX` | 12 | `minWidth` | 80 |
| `snapOpen` | 0.5 | `fullSwipe` | 0.6 | `rubberBand` | 0.55 |  |  |

- **Closing.** One row is open at a time. An open button closes, settling back, on a scroll of the list (trackpad or wheel), another row's swipe, a click anywhere but on it (at once when the click is in the list, which acts on its rows in the same moment), Esc (which then goes no further), a selection change and a refresh of the list (rows may have moved under it). A row the fingers are still moving when a close rule comes closes, and the rest of that gesture does nothing.
- **Motion.** The row follows the fingers, as a scroll does, whatever Reduce Motion says. Let go, it settles open or closed over `dur.standard` `ease.settle` from where it was let go of, and a close rule settles it closed the same way. A full swipe, or a click, that archives slides the content the rest of the way out over `dur.quick` `ease.leave`, the fill covering the row, and the row leaves in the frame the change lands, the next row taking its place as after E (§4.10); if the change leaves it listed (Archive in Starred), it settles back. A read change settles back and the row shows it. Under Reduce Motion nothing settles or slides: the row is at once where it settles. The settle steps once a frame (`QuireFrameAnimation`) and a keystroke finishes it (`Quire.Motion.finishAll()`).
- **VoiceOver.** The row's custom actions are the same buttons, Archive first, offered where the swipe offers them (§4.14); a button that is out is a button named by its words. A mouse has no swipe: E, U, the context menu and the Message menu do the same.

**Compact density** (48 pt): pip at y 11.5; sender line at x 24, y 7; a 6 pt account square (radius 1.5, filled with the account ink) before the time, replaced by the 16 pt initial tile when **Show account initials** is on (never both); line 2 at y 25: subject, then “ - ” and the snippet in `snippet` `ink2`; glyph cluster as above; margin rule y 6, height 36; separator from x 24.

`layout.rowCompact`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `height` | 48 | `marginRuleY` | 6 | `marginRuleHeight` | 36 | `pipX` | 7 |
| `pipY` | 11.5 | `textX` | 24 | `senderY` | 7 | `line2Y` | 25 |
| `accountSquare` | 6 | `accountSquareRadius` | 1.5 | `separatorX` | 24 | `skeletonSenderBar` | 24 / 10 / 120 / 9 |
| `skeletonTimeBar` | 28 / 9 | `skeletonLine2Bar` | 24 / 29 / 260 / 9 |  |  |  |  |

**Performance contract.**

- All attributed strings are built once per (conversation id, version, appearance, contrast, Font setting, Text size, day) in `RowContentCache`, including the script-coverage decision and the running-head time format. Window key state is not part of the key: no text colour depends on it (§3.4).
- **Avatars: faces are cached, rings are drawn.** The face bitmap (tint disc + monogram) renders off the main thread, cached by (initials, tint, size, appearance, contrast, Graphite, Font setting) only. The account ring is stroked in `draw(_:)` with `NSBezierPath` (a circle of radius face/2 + gap + ring/2, width 2, in the account ink), and the gap is left transparent so the row's fill (`paper`, `paper + hover`, `selWash`, `selWashIdle`) shows through. Hover and selection therefore never miss the cache or flash a wrong-coloured gap. Until a face is ready the row draws the tint disc and initials synchronously from the cached glyph run; it never shows an empty circle.
- **Hover is suspended while scrolling.** On `NSScrollView.willStartLiveScrollNotification` (and for scroll-wheel momentum) the list stops updating hover; rows that slide under a still pointer draw no wash. On `didEndLiveScrollNotification` the row under the pointer, if any, takes the hover wash once.
- Selection changes redraw only the fill and the margin rule inside `CATransaction.setDisableActions(true)`. Row views are opaque and layer-backed.

### 5.8 Running heads (date dividers)

Rows are grouped under local-day heads: Today, Yesterday, Earlier this week, Last week, then month names (“October”), then “October 2025” for earlier years. Each head sets the row time format below it (§4.13): Today and Yesterday rows show the time, Earlier this week the weekday, every later head day and month.

`layout.runningHead`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `height` | 28 | `labelX` | 20 | `labelY` | 10 | `ruleGap` | 10 |
| `ruleY` | 17 | `minConversations` | 8 | `compactHeight` | 24 | `compactLabelX` | 24 |
| `compactLabelY` | 5 | `compactRuleY` | 12 |  |  |  |  |

- Label at x 20, y 10: `runningHead` (SF Pro 11/14 Semibold, sentence case, the system's own tracking), `ink3`. A hairline runs from the label end + 10 to trailing 16 at y 17.
- **Hidden** in search results (ranked), in Later (its times are ahead) and in views with fewer than 8 conversations. The Inbox groups by the date it sorts by, so a conversation back from Later is under Today.
- **Compact density**: 24 pt, label at x 24, y 5, rule at y 12.
- **Text size** (§4.15): the head keeps its height and its label's place; the label's line takes `runningHead`'s step and the rule stays on its centre.
- **Not sticky**: plain group rows, no `floatsGroupRows` (no extra compositing during scroll). `heightOfRow` returns two fixed values per density and Text size (row and head), plus the tail footer's height (§5.10). `j`/`k`, next-unread and selection restore skip them; they are not selectable or focusable; VoiceOver reads them as headings.

### 5.9 Empty states

Centred in the pane, max width 300. Line 1 is `aside` (New York Italic 17/24) in `ink`; line 2 is `snippet` in `ink3`, 4 pt below. A line 2 that carries keycaps is a row of commands: it may run past 300 pt, up to the pane's width, and when it must wrap it breaks only before a keycap, so a keycap never ends a line apart from the words that follow it.

| Case | Glyph | Line 1 | Line 2 |
|---|---|---|---|
| Inbox zero | `ss.paperPlane` 40 pt in the system's secondary label grey (§4.11), 8 pt above | Nothing left to read. | New mail will land here. |
| Empty Starred | — | No starred conversations | Press S to star one. |
| Empty Sent | — | No sent mail | Messages you send appear here. |
| Empty Drafts | — | Nothing in Drafts | Drafts you start here are kept on this Mac. |
| Empty Trash | — | Trash is empty | Conversations you move to Trash appear here. |
| Empty All Mail | — | No mail | Every conversation in this account appears here, archived ones too. |
| Empty Later (only for the moment before the view returns to the Inbox, §5.2) | — | Nothing snoozed | Press L to bring a conversation back later. |
| Empty Outbox (§5.53; only for the moment before the view returns to the Inbox, §5.2, whatever the accounts' sync states, which say nothing of what this Mac is sending) | — | Nothing waiting to send | Messages you send wait here until they have gone. |
| First sync finished with no mail in the view (the older mail listed too, not just the first page) | — | No mail in Contoso yet | Sync finished. New mail will land here. |
| Older mail still being listed, nothing in the view yet (any view but search and offline) | — | the view's line 1, as above | Older mail is still downloading. |
| Search, no results | — | No results for “lisbon flat” | Not on this Mac? **Search Gmail** (a link; “Search Outlook”, or “Search all accounts” in All Inboxes with several accounts, as the row of §5.10 names them), then “Searching Gmail…”, then “Nothing on Gmail either.” or “Couldn't search Gmail ·” **Try again**. Found conversations replace the empty state with their rows, and the row of §5.10 ends them. With no account to search: “Search looks at subjects, people and message text.” |
| Reader, nothing selected | — | No conversation selected | keycaps J K to move · ↩ to open |
| Reader, conversation emptied while open (its last message deleted or moved elsewhere) | — | No messages to show | They were deleted or moved on another device. |
| Offline, nothing cached | `wifi.slash` 20 pt `ink3`, 8 pt above line 1 (`emptyState.offlineGlyphGap`) | You're offline | Mail will appear when you reconnect. |
| No accounts | — | the welcome screen (§5.39) | |

**A link in line 2.** Only the empty search's line 2 acts: its last words are a link, `snippet` in `accent` (`ink2` while pressed, underlined on hover, and at rest under Graphite, §3.1), with a hit area at least 24 pt tall. The empty state is then a group to VoiceOver with the link as a button inside it; ↩ in the search field does the same, and while the field has the keyboard a “↩” keycap follows the link.

In the conversation-emptied state the reader header keeps the subject (placeholder style if missing), every action but Trash is disabled, and the quick reply is hidden (§5.18); the list removes the row as usual and the selection moves on with the next keystroke.

### 5.10 Skeleton and loading

Only on the first sync of an account, before its first page lands, and only after 300 ms. Static: no shimmer.

`layout.skeleton`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `delay` | motion.duration.skeletonDelay | `circle` | 30 | `circleX` | 24 | `circleY` | 19 |
| `barRadius` | 3 | `senderBar` | 68 / 14 / 120 / 9 | `timeBar` | 28 / 9 | `subjectBar` | 68 / 32 / 190 / 10 |
| `snippetBar` | 68 / 50 / 240 / 8 | `widthJitter` | 0.3 | `bodyBars` | 1 / 0.92 / 0.6 | `bodyBarHeight` | 10 |
| `bodyBarGap` | 14 |  |  |  |  |  |  |

- Skeleton row: 68 pt; a 30 pt circle and four bars (sender, time, subject, snippet: frames above as x, y, w, h), widths varying by ±0.3 from a fixed table; colour `fill`, radius 3.
- At another Text size a skeleton row takes that row's height, its bars centred on the lines they stand for and its circle on the row (§4.15).
- Compact skeleton row: 48 pt, no circle; sender bar 24 / 10 / 120 / 9, time bar 28 / 9 (trailing 16), line-2 bar 24 / 29 / 260 / 9 (x, y, w, h), same jitter, colour and radius.
- Body not cached yet: the sheet shows its header at once and three bars at 1 / 0.92 / 0.6 of the measure, 10 pt high, 14 pt apart. In the reader these are CSS (`.ss-skel { background: var(--q-fill); border-radius: var(--q-r-xs) }`), never a full-pane spinner.
- Skeleton to content is an instant swap, in the list and in a sheet (no cross-fade: nothing in the list animates).

**List tail (paging).** The list loads older pages as the user scrolls within two screens of the end. When the next page is not in hand, a fixed 28 pt footer row ends the list: after 150 ms a 12 pt `ink3` spinner and, 6 pt after it, “Loading older mail…” in `meta` `ink3`, centred; before the delay the row is empty `paper`, so fast pages never flash. Failure: `exclamationmark.triangle.fill` `danger` + “Couldn't load older mail” + link “Retry” (`metaStrong`, `accent`). At the true end of a view there is no footer. The footer is not selectable, `j`/`k` skip it, and it is the same height in both densities.

**The end of a search.** A search's results end, once every local result is listed (the tail has nothing left to load), with one row that asks the mail server for more: during a first download the server holds mail this Mac does not have yet, and its own search reads the field's text as typed by its own rules (Gmail's operators, Outlook's search words), which decide what it finds; the operators this Mac tests on the row (`is:`, `has:`, `before:`, `after:`, `in:`, §5.6) and the account scope still narrow the finds. It is the tail's row in the tail's type: 28 pt, `paper`, the same height in both densities, a centred cluster of a 12 pt glyph and, 6 pt after it, the words in `meta`. It is never selectable and `j`/`k` skip it; its link joins the Tab order after the list, and ↩ or Space on the focused link, a click on it, or ↩ in the search field runs the search. The search never blocks the list, never puts a spinner over it, and never raises an alert; the local results stay on screen while it runs.

| State | Glyph | Words |
|---|---|---|
| Offer | `magnifyingglass` `ink3` | “Search Gmail for more” as a link (`metaStrong`, `accent`, underlined on hover; tooltip “Search Gmail for More  ↩ in the search field”), then, while the search field has the keyboard, a “↩” keycap 6 pt after it. One account in scope: the provider's name, Gmail or Outlook; All Inboxes with several accounts: “Search all accounts for more” |
| Searching | `magnifyingglass`, replaced by a 12 pt `ink3` spinner after 150 ms, as in the search field (§5.6) | “Searching Gmail…” in `ink3`, at once; it stays until the rows the search adds are listed |
| Found | `magnifyingglass` `ink3` | “Found 12 more on Gmail” (“in your accounts” for all accounts) in `ink3`: the conversations the search added to the list. They take their places among the results in date order; the row stays last |
| Nothing | `magnifyingglass` `ink3` | “Nothing more on Gmail” (“in your accounts”) in `ink3` |
| Failed | `exclamationmark.triangle.fill` `danger` | “Couldn't search Gmail” in `danger` + 6 pt + link “Try again” (`metaStrong`, `accent`), as the failed tail sets Retry. In All Inboxes the account that failed by name (“Couldn't search Contoso”), “2 accounts”, or “your accounts” when every one failed; the others' finds still list |

New words, or another scope, start again: a search still running is cancelled and the row offers the server for the new words. A finished search is not offered again for the same words. What it found stays on this Mac, so a later search lists it like any mail by its subject, people and preview (by all its text once it has downloaded). VoiceOver reads the row's words (and its link as a button), and hears the result once when the search ends and the list holds all it found, since the row may be off screen. With no local results at all, the empty state offers the same in its own words (§5.9).

### 5.11 Sync status line

28 pt at the bottom of the list pane, top hairline, padding 16, gap 6, glyph 12 pt. Text `meta` `ink3`; the lead phrase `metaMedium` `ink2`; trailing actions `metaStrong` `accent`. Always present, so the list never changes height. Clicking it opens Settings › Accounts; hover shows the per-account detail as a tooltip.

| State | Glyph | Copy | Extras |
|---|---|---|---|
| Up to date | `checkmark` `ink3` | **Up to date** · 3 accounts · checked 23:41 | — |
| Up to date, downloading older mail | `checkmark` `ink3` | **Up to date** · Contoso · older mail 3,412 of 8,120 (“older mail 3,412” while the total is unknown, “older mail…” before the first count) | determinate contrail along the top edge while the total is known (never the indeterminate sweep: new mail is current); “checked 23:41” leaves the line for the tooltip's last line (“Checked 23:41”) |
| Up to date, older mail paused | `checkmark` `ink3` | **Up to date** · Contoso · older mail paused until 10:42 | the provider is limiting the older-mail download while it is still being listed; new mail still arrives, so this is never Slow / retrying. No contrail. Once the older mail is listed, a pause of its body downloads is not older mail and never takes the line |
| Downloading | 12 pt spinner | **Downloading mail** · Contoso · 3,412 of 8,120 | determinate contrail along the top edge. Only a new account's first page of newest mail; the older mail after it shows under Up to date |
| Checking | 12 pt spinner | **Checking for mail…** | only for a check the user asked for (View › Check for New Mail ⇧⌘N, or reconnecting), and only once it has run 150 ms. The background checks, every 5 s while SuperSparrow is active and every 30 s otherwise, and the checks on app activation, on waking from sleep and when the network returns, never change the line or its tooltip (an account checked in the background reads as Settings shows it, Up to date) except to update “checked 23:41” |
| Sending | 12 pt spinner | **Sending 1 message** | after the undo window, while the send is in flight |
| Signing in (§5.44) | 12 pt spinner | adding: **Finish signing in in your browser** · Gmail (the provider: no account exists yet); reconnecting: **Finish signing in in your browser** · Fabrikam (the account's name) | trailing link “Cancel” |
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
| 8 | Checking | a check the user asked for has run 150 ms |
| 9 | Demo | demo mode (it replaces Up to date) |
| 10 | Up to date | otherwise; while any account downloads older mail, the line says how far it has come in place of “checked 23:41”, or, once every such account is paused, until when |

**Copy for several accounts.** One account in the winning state is named; two or more are counted, never listed: “**Sign in required** · Fabrikam” / “**Sign in required** · 2 accounts”; “**Couldn't sync Contoso** · details” / “**Couldn't sync 2 accounts**”; “**Gmail is slow to respond** · retrying in 30 s” / “**2 accounts are slow to respond** · retrying in 30 s” (the soonest retry); “**Downloading mail** · Contoso · 3,412 of 8,120” / “**Downloading mail** · 2 accounts · 3,412 of 8,120” (summed over the downloading accounts, “3,412 messages” while a total is unknown); “**Up to date** · Contoso · older mail 3,412 of 8,120” / “**Up to date** · 3 accounts · older mail 3,412 of 8,120” (named as Up to date names the accounts shown; the figures summed over the accounts downloading older mail, a paused one included so the figure does not jump when it pauses, and “older mail 3,412” while a total is unknown), and “**Up to date** · 3 accounts · older mail paused until 10:42” once every one of them is paused (the soonest resume). The trailing action follows the count: with one account “Reconnect” and “Retry” act on it; with two or more the link reads “Reconnect…” and opens Settings › Accounts, where each row has its own Reconnect, and “Retry” retries every failed account. Numbers use the locale's grouping (§4.13).

**Keyboard.** The line is a button (Space or ↩ opens Settings › Accounts) with the focus ring inset 2 pt inside its bounds. While it carries an action (Reconnect, Retry, Cancel) it joins the Tab order after the list, always, because no other surface offers that action in place; Tab lands on the action link (ring around the link, radius `r.sm`) and ↩ runs it. Without an action it is reachable only with Full Keyboard Access. VoiceOver reads the whole line, then the action.

### 5.12 Reader header and action buttons

A **native** view (it replaces `ConversationHeaderView`), 92 pt, `paper`, bottom hairline at the horizon, always visible. The subject updates in the same frame as the selection, before the web view renders, so key repeat feels instant.

- **Row 1** (title-bar zone): the kicker at the reading column's leading edge, centred on y = 26: a 7 pt account-ink dot, 8 pt, the account name, “·”, the message count, in `runningHead` `ink3` (single-account setups omit the account; several selected shows “Selection”). The kicker ends at least 16 pt before the first visible action (`readerHeader.kickerActionGap`); when it does not fit, the account name tail-truncates and the dot, the “·” and the count never do; if fewer than 4 characters of the name would remain, the name is dropped (dot and count stay, and the kicker's tooltip names the account). Trailing at 16, top 12: Star · Archive · Trash, a 14 pt gap, Reply · Reply All · Forward, as 28 pt icon buttons with 15 pt symbols, 2 pt apart (190 pt for all six). Nothing else ends the line: the calendar's toggle is never among the conversation's actions, and stands at the window's trailing edge instead (§5.54). The set changes per view and selection (below). At the 400 pt minimum reader the kicker keeps 400 − 16 − 190 − 16 − 16 = 162 pt, in the main window and in a reader window alike: the dot, “· 12 messages” and the first letters of the account name (the kicker's tooltip names it).
- **Row 2**: the headline at the reading column, top 56: `headline` (New York 24/30 Semibold, `headlineSans` when New York lacks the script), at the reader's Text size (§4.15: at Larger 26/32, still inside the band), one line, tail truncation, full subject in the tooltip and VoiceOver label, selectable. No subject: “No subject” in the placeholder style (`headline` italic, `ink3`).
- The reading column x = max(margin, (reader width − 680) / 2), where margin is 32, or 16 when the reader is narrower than 560 pt; recomputed in `layout()`; the kicker, headline, sheets and quick-reply field share it. In a reader window the kicker starts no nearer the leading edge than the minimal-mode masthead, so it clears the lights (§5.49).
- **Per view and selection.** Each set is drawn from the trailing edge; hidden actions close up, they never leave gaps.

  | Reader state | Actions | Notes |
  |---|---|---|
  | One conversation in Inbox, Starred, Sent, All Mail | Star · Archive · Trash, gap, Reply · Reply All · Forward | — |
  | One conversation in Later | Star · Archive · Trash, gap, Reply · Reply All · Forward | Archive ends the snooze and leaves the conversation archived, as E does there (§5.45) |
  | One conversation in Trash | Star · Move to Inbox, gap, Reply · Reply All · Forward | Archive becomes Move to Inbox (`tray.and.arrow.down`, ⇧I); **Trash is removed**: the conversation is already there and v1 has no Delete Forever (§9). # does nothing in Trash and Message › Move to Trash is disabled |
  | Several selected (any view but Drafts, Trash and the Outbox) | Star · Archive · Trash | the reply group is **hidden**: a reply answers one conversation, so R, A and F do nothing. Archive and Trash act on every selected conversation (toast “Archived 3 conversations”). Star shows the selection's state: on (`star.fill` in `star`, tooltip “Unstar All  S”) only when **every** selected conversation is starred, and then it unstars all; otherwise, none or mixed, it is off (outline `star`, tooltip “Star All  S”) and it stars all. S does the same |
  | Several selected in Trash | Star · Move to Inbox | as above, with Move to Inbox for all |
  | Drafts (one draft) | Continue Editing (`ss.nib`, ↩) · Discard Draft (`trash`, #) | Star, Archive and the reply group are hidden; Discard confirms with the “Discard this draft?” alert; the kicker reads “Draft · Contoso” (§5.19). Several drafts selected: Discard Draft only, which asks “Discard 3 drafts?” (§5.33) |
  | Outbox (one message, §5.53) | Continue Editing (`ss.nib`, ↩) while it is a Send Later message still held (waiting, missed, or waiting to go again); nothing otherwise | no mail action applies to a message on its way; the kicker reads “Outbox · Contoso”. Several selected: nothing, and the headline reads “3 messages selected” |
  | Nothing selected | the full set, disabled | — |
  | Conversation emptied while open | the view's set, every action but Trash disabled | in Trash, every action disabled |

- **No calendar button** (1.9.2). The header holds only what acts on the conversation. The calendar's toggle stands at the window's trailing edge, in the day column's header or atop its strip (§5.54), and the week opens from the column's header; reader windows have no calendar at all (§5.49).

`layout.readerHeader`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `height` | 92 | `kickerCenterY` | 26 | `kickerDot` | 7 | `kickerDotGap` | 8 |
| `headlineTop` | 56 | `headlineHeight` | 30 | `actionSize` | 28 | `actionGlyph` | 15 |
| `actionGap` | 2 | `actionGroupGap` | 14 | `actionsTrailing` | 16 | `actionsTop` | 12 |
| `kickerActionGap` | 16 | `kickerNameMinChars` | 4 |  |  |  |  |

| State | Glyph | Fill |
|---|---|---|
| Rest | `ink2` | none |
| Hover | `ink` | `hover`, radius `r.md`; tooltip “Archive  E” |
| Pressed | `ink` | `pressed` |
| Focused | `ink2` | ring |
| On (starred) | `star.fill` in `star` | none |
| Disabled (Reply All with one participant; nothing selected; every action but Trash when the conversation has no messages left) | `inkDisabled` | none |
| Loading | 12 pt spinner replaces the glyph | none |
| Window not key | unchanged | unchanged |

With nothing selected the header keeps its height, shows no kicker or headline, and its actions are disabled.

### 5.13 Message stack (collapsed messages)

Below the header the reader shell renders the participants line (`body`, `ink2`, 16 pt from the top, up to 4 names then “+3”), then the stack, 16 pt below.

All collapsed messages between expanded ones form one stack: one `sheet` with a hairline `rule` edge, radius 8, no shadow; collapsed rows are 44 pt and separated by hairlines.

| Part | Spec |
|---|---|
| Row | padding 0 16, gap 10 |
| Avatar | 24 pt monogram, no ring |
| Name | `senderMedium`, `ink`, fixed 112 pt column; Semibold when unread; “No sender” in the placeholder style |
| Snippet | `sender`, `ink2`, fills, tail-truncated |
| Starred | `star.fill` 12 pt in `star`, 4 pt before the date, when that message is starred (Gmail stars messages; for Microsoft the flag is on the message too) |
| Attachments | `paperclip` 12 pt in `ink2`, as the list row draws it, left of the star (or 4 pt before the date when not starred), when that message has attachments: until its body downloads, the provider's flag the list row uses; after, the attachments its sheet shows, so inline pictures never earn it. VoiceOver adds “has attachments” to the row |
| Date | `meta` tabular `ink3`, trailing |
| Unread pip | 6 pt `accent` circle at x = 5 (centred in the 16 pt leading padding), vertically centred on the row (y = 19 in the 44 pt row) |
| Fold | more than 6 collapsed messages keep the first 1 and last 2 and fold the rest into one row “4 more messages” (`label`, `ink2`, centred) |

States: rest; hover (`hover` across the row, end rows clipped to the radius); pressed; focused (`n`/`p` or Tab: a 2 pt `focus` ring inset 1 pt inside the row); unread (pip + Semibold); starred (the mark above). Click or ↩ expands the message in place, by the provisional-height rule of §4.10 (`dur.standard`, `ease.settle`; Reduce Motion: instant).

**Fold row** (“4 more messages”): a 44 pt stack row with the same states: hover (`hover`, label `ink`), pressed (`pressed`), focused (the inset ring; `n`/`p` land on it like a message). Click, ↩ or Space unfolds it into its collapsed rows (not into expanded messages), with the stack's height change (`dur.standard`, `ease.settle`; Reduce Motion: instant); focus moves to the first unfolded row. It does not fold again until the conversation is reopened. VoiceOver: “4 more messages, button”.

### 5.14 Message sheet (expanded) and message header

`layout.reader`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `stackRowGap` | 10 | `addressGap` | 6 | `headerPip` | 7 | `participantsMax` | 4 |
| `foldKeepStart` | 1 | `foldKeepEnd` | 2 | `columnMax` | 680 | `columnMinMargin` | 32 |
| `participantsTop` | 16 | `participantsGap` | 16 | `stackGap` | 12 | `stackRow` | 44 |
| `stackRowPadX` | 16 | `stackAvatar` | 24 | `stackNameColumn` | 112 | `stackPip` | 6 |
| `stackPipX` | 5 | `foldAbove` | 6 | `sheetRadius` | 8 | `sheetPadTop` | 22 |
| `sheetPadX` | 28 | `sheetPadBottom` | 14 | `headerAvatar` | 36 | `headerGap` | 12 |
| `bodyTop` | 18 | `bodyIndent` | 48 | `measure` | 576 | `htmlWidth` | 624 |
| `headerAction` | 24 | `headerActionGlyph` | 14 | `headerActionGap` | 2 | `headerActionDateGap` | 8 |
| `blockGap` | 12 | `attachmentsTop` | 16 | `footerTop` | 16 | `footerPad` | 10 |
| `footerButtonSize` | regular | `footerButtonGap` | 4 | `footerKeycapNextGap` | 12 | `originalInsetRadius` | 3 |
| `originalInsetPad` | 12 | `narrowColumnMargin` | 16 | `narrowSheetPadX` | 16 | `htmlMinZoom` | 0.74 |
| `starGlyph` | 12 | `starGap` | 4 | `targetKeycapGap` | 6 | `offlinePreviewGap` | 12 |
| `recipientsLabelColumn` | 28 | `recipientsFieldGap` | 0 | `recipientsMaxLines` | 8 | `recipientsTop` | 8 |
| `recipientPitch` | 24 | `recipientFace` | 20 | `recipientPadX` | 4 | `recipientRadius` | 5 |
| `recipientsToggleHitBelow` | 8 | `senderAddressHitAbove` | 6 | `unsubscribeHitGap` | 8 | `copiedGlyph` | 12 |
| `copiedGap` | 4 |  |  |  |  |  |  |

| Part | Spec |
|---|---|
| Sheet | `sheet`, radius 8, hairline `rule` edge + `e1`; padding 22 28 14; 12 pt below the stack or the previous sheet |
| Header | avatar 36 (no ring) · 12 gap · who block · date |
| Name line | `bodyStrong`, `ink` (“No sender” in the placeholder style); a starred message shows `star.fill` 12 pt in `star` 4 pt after the name, at rest; a message that offers a way to unsubscribe shows the **Unsubscribe** link next (6 pt gap; see “Unsubscribe” below); the address follows on hover or focus (`meta`, `ink3`, 6 pt gap) and copies with a click (“Copying an address”, below); a sender with no name apart from the address shows the address as the name, and the name is then what copies. Beside Unsubscribe, whose request no undo takes back, a copy target keeps 8 pt of nothing between the two hits (`reader.unsubscribeHitGap`), so the text gap is 12 pt: a press that misses the address, which fades in under the pointer, lands on neither; unread shows a 7 pt `accent` pip before the name. A right-click on the name, the address or the avatar opens the person menu (below) |
| Recipients | the toggle, on the line under the name. Folded, the summary “to me · cc Tom Hughes” (`snippet` `ink2`, tooltip “Show Addresses”); open, “Hide addresses” in the header's link style (`snippet` `ink2`, underlined 1 pt at offset 2, as “and 24 more”; tooltip “Hide Addresses”). Click, ↩ or Space opens and folds. It keeps its line in both states, and open, its hit keeps the folded summary's width (the words are shorter, the ring hugs them), so the place clicked to open the list is the place that folds it, wherever along the summary that was. Hover and press `ink`; focus: the ring outside a 1 pt `sheet` gap; hit: its line and the 8 pt below it (`reader.recipientsToggleHitBelow`), 24 pt. VoiceOver: “Recipients, to me, cc Tom Hughes, collapsed, button” / “Hide addresses, expanded, button” |
| Recipients, open | 8 pt below the toggle (`reader.recipientsTop`), inside the who block: one row per field in the order To, Cc, Bcc (Bcc only on messages the user sent), all on one 24 pt pitch (`reader.recipientPitch`, `recipientsFieldGap` 0). Each row starts with its label, “To”, “Cc” or “Bcc” (`snippet` `ink3`, level with its first line), in a 28 pt column (`reader.recipientsLabelColumn`, to the recipients' text), then the recipients wrapped in the remaining width, each one a control that copies its address (“Copying an address”, below): “Ben Carter <ben@contoso.test>,” with the name in `snippet` `ink2` and the address in `snippet` `ink3`, a comma ending each but the field's last, the user as “me <alex@contoso.test>”, a recipient with no name as its address alone. Between two recipients, the 4 pt padding of each one's face. A recipient never breaks across lines (a single over-long one tail-truncates, full text in its tooltip); one with no address (an empty group) is plain text. Past 8 lines (`reader.recipientsMaxLines`) the list stops at “and 24 more” (`snippet` `ink2`, underlined, a button that shows the rest; pressed from the keyboard, focus moves to the first recipient it shows, and clicked, it stays where a click on any button leaves it, with Tab reaching that recipient next). The labels, commas and the space around the recipients take no click (a click there only makes the message the target) and show the arrow; nothing in the list folds it. The open state lasts the session, per message. Opening and folding follow the expand rule of §4.10 (`dur.standard`, `ease.settle`; Reduce Motion: instant); the list is shell DOM, measured at once, so there is no provisional height. VoiceOver: the list is a group “Recipients”, each field a group “To”, “Cc”, “Bcc”. All inks are tested pairs on `sheet`, `sheet + hover` and `sheet + pressed` (§7) |
| Date | `snippet`, tabular, `ink3`, trailing: “Today 09:12”, “Yesterday 23:39”, “Fri 30 Oct” |
| Attachments | the stack row's `paperclip` (§5.13), 12 pt `ink2`, 4 pt before the date, after the hover actions; always shown, not only on hover |
| Hover actions | on hover or focus only (fade in `dur.quick`), before the date: 24 pt icon buttons (14 pt symbols; 24 pt hit), 2 pt apart, the last one 8 pt before the date: Star (`star` / `star.fill` in `star` when on), Reply, More; plus Original colors in dark mode for styled HTML mail that declares its own colours (off: `circle.lefthalf.filled` `ink2`, tooltip “Original Colors  ⇧⌘O”; on: the same glyph in `accent` on `accentWash`, hover `accentWashHover`, pressed `accentWashPressed`, tooltip “Adaptive Colors  ⇧⌘O”; the on state stays visible without hover) |
| More (`ellipsis`) | a system menu acting on **this message**; conversation actions stay in the header (Star Message, like the hover Star, and Mark as Unread from Here are mail actions as S and U are: the toast S or U would give in that view, so none where the row shows the change, and Z and ⌘Z undo them, §6.1): Reply · Reply All · Forward · — · Star Message / Unstar Message · Mark as Unread from Here · — · Load Images (when images are blocked) · Original Colors / Adaptive Colors (dark mode, styled, declares colours) · — · Unsubscribe ⇧⌘U (when the link shows; it acts on this message) · Always Archive Mail from This Sender · Block Sender (when someone other than the user sent it, §5.52; the rule the sender has is checked and disabled) · Copy Sender Address. Items that do not apply are hidden, not disabled |
| Invitation card | when the message carries a calendar invitation: 18 below the header, at the indent, inside the measure; 16 below it, where the body would start, the message's elision mark, the body folded behind it (“The invitation card” and “The message under the card”, below) |
| Body | 18 below the header; under an invitation card, once unfolded, 12 below the message's elision mark. Plain and unstyled: `reading` (or `readingSans`), indented 48 to the name column, measure 576 (narrower when the sheet is), paragraph gap 12. A text/plain body is stored as paragraphs: blank lines end a `<p>` and a run of them is one break, lines inside keep their `<br>`, so the gap spaces paragraphs instead of an empty line (bodies stored before 1.3.1 keep `<br><br>` until fetched again). Styled HTML: the sheet's full content width (624 at the widest column), fitted as below |
| Quoted-text toggle | 12 below the body, at the indent (§5.15); under an invitation card it folds with the body |
| Attachments | 16 below, chips at the indent, wrapping with 8 pt gaps (§5.17) |
| Footer | 16 below, hairline above, 10 pt padding; ghost buttons Reply · Reply all · Forward (sentence case, §4.13) with their symbols, at the indent, **regular** size (28 pt, `bodyMedium`, 14 pt glyphs; `layout.reader.footerButtonSize`), 4 pt apart; on the target message each button is followed by its keycap (R, A, F), 6 pt after the button and 12 pt before the next one |

**Copying an address.** Each recipient in the open list, and the sender's address on the name line, copies with a click: the address alone (`ben@contoso.test`), as plain text, since that is what any field anywhere takes. ↩ or Space with keyboard focus copies too (the app's Open and Quick Look give way, as on the elision mark, §5.15), and so do ⌘C and Edit › Copy, whatever else the page has selected. A double-click copies once. The click also makes the message the target. A target is one control, name and address together: on hover a 20 pt face (`reader.recipientFace`, centred in the 24 pt pitch, so the hit is the whole pitch), radius `r.sm` (5, `reader.recipientRadius`), 4 pt padding each side (`reader.recipientPadX`; at rest the text sits where it would without it); the sender's address has the name line's 18 pt face and a 24 pt hit that reaches 6 pt up into the sheet's padding (`reader.senderAddressHitAbove`), never down onto the toggle. Targets are not selectable text; the sender's name is, and is not a target. When the name line leaves the sender's address less than 24 pt (Unsubscribe and a long name in a narrow reader), the address hides and is no target; the person menu and More › Copy Sender Address still copy it. Tooltip “Copy Address” (a truncated recipient keeps its full text instead).

| State | Face | Text |
|---|---|---|
| Rest | none | name `ink2`, address `ink3` (the sender's: `meta` `ink3`, shown on the sheet's hover or focus) |
| Hover | `hover` | name and address `ink` |
| Pressed | `pressed` | `ink` |
| Focused | the ring outside a 1 pt `sheet` gap, around the face | unchanged |
| Copied | as the pointer gives it | what was copied gives way to `checkmark` 12 pt · 4 pt · “Copied” in its own role, in `ink`, leading-aligned in the width it had (the checkmark alone where the mark is wider). Where a long name cuts the address short or out of sight, the mark stands over the whole recipient as far as it shows, and the face's ellipsis goes while it does; 1500 ms (`dur.copiedConfirm`), then the text cross-fades back in `dur.quick` |
| Its menu open | `hover` until the menu closes | `ink` |
| Window not key | unchanged, no ring | unchanged |

The mark stands in for exactly what the pasteboard took: after Copy Address, the address with its brackets and comma (or the whole of a recipient with no name); after Copy Name and Address, the whole recipient. It shows only once the app has written the pasteboard. There is one at a time across the page, since the pasteboard holds one thing: a new copy ends the last mark, a copy of the same recipient restarts it, and a re-render of the header keeps it for its remaining time. A copy gets no toast and no sound: nothing leaves the view and there is nothing to undo. VoiceOver says “Copied ben@contoso.test.” (“Copied Ben Carter, ben@contoso.test.”). More › Copy Sender Address copies the same way, mark and announcement included.

**Keyboard in the open list.** The list is one Tab stop: Tab lands on the recipient last reached or clicked while it has been open, else the first. A click never gives a target keyboard focus: it leaves focus on the sheet, as a click on any of the reader's buttons does, since focus the pointer gave would show no ring and still take ↩, Space, ←, Esc and ⌘C from the app; a target the keyboard reached keeps its focus through a click. → and ← move along the recipients in reading order, To through Bcc, then onto “and 24 more”, and stop at either end; the app leaves ← to the page there, as on the attachment row (§5.17). ↑ and ↓ scroll the reader. Esc folds the list and moves focus to the toggle (§6.1). A re-render of the header keeps focus on the same recipient, or on the toggle when it has gone. VoiceOver names each recipient by what it shows, without the brackets: “Ben Carter, ben@contoso.test, button”, “me, alex@contoso.test, button”, and the sender's address “ben@contoso.test, button”; its help is the tooltip.

**The person menu.** A right-click (or VO-⇧-M) on a recipient, or on the sender's name, address or avatar, opens a system menu for that person: Copy Address · Copy Name and Address (“Ben Carter <ben@contoso.test>”, written as the composer's tokens are, the user's own name for “me”; only when the header gives a name) · — · New Message (a composer to that address from the conversation's account; only for a valid address) · Show Mail from This Person (the main window's search field takes `from:ben@contoso.test` and runs it as if typed, and the list takes the keyboard with the query kept, §5.6; from a reader window the main window comes forward). Items that do not apply are hidden. Labels, commas and “and 24 more” keep the conversation's menu.

**The copy is the app's.** The shell names the recipient by field and position (`copyAddress`, `cc:2`), never by its address; the app reads the address from the store, writes it to the general pasteboard as plain text, then shows the mark and announces it. The page writes no clipboard, and no address is logged above debug.

**The target message.** R, A, F and Space act on one message: the last expanded message when a conversation opens; the message last clicked anywhere inside its sheet; or the one last reached with `n`/`p` or Tab. It is always shown, without the keyboard ring: its footer carries the R · A · F keycaps, and when more than one message is expanded its sheet edge is 1 pt `ruleStrong` instead of the `rule` hairline. When the reader is narrower than 616 pt and the keycaps hide, the edge is drawn even with one message expanded. The keyboard ring (below) appears only after `n`/`p` or Tab and always sits on the target.

**Unsubscribe.** A message whose `List-Unsubscribe` header (RFC 2369) offers a mailto, https or http address shows “Unsubscribe” after the sender's name and star, before the address. It is drawn as a link, never as a button (VoiceOver still reads it as one): `snippet` in `ink2`, the recipients line's type and colour, underlined at rest (1 pt at offset 2) like the header's other link (“and 24 more”), since nothing else tells it from the name line's text; `ink` on hover and press; the Quire ring on focus (2 pt `focus` outside a 1 pt `sheet` gap). It never truncates: its room comes first from the address, which shows nothing at rest and gives up its share before the name gives any (the line still does not reflow on hover), then from the name. Tooltip “Unsubscribe  ⇧⌘U”; VoiceOver “Unsubscribe, button”; Space or ↩ acts on it like a click. It shows on every expanded sheet whose message offers it (a thread of newsletter issues can show it on each), never on a draft or a reply still in the outbox. Mail stored before 1.6.3 kept no list headers and shows none until it is fetched again. One click acts, with no alert, in this order of preference: an RFC 8058 one-click request when `List-Unsubscribe-Post` is exactly `List-Unsubscribe=One-Click` beside an https address (the app posts it from this Mac, with no cookies or credentials); else the mailto request, sent silently from the conversation's account to the link's one address, never to its Cc or Bcc (it appears in Sent; a link naming several recipients is not used); else the sender's page, opened in the browser. Then the conversation is archived as E would and the toast says both (§5.30): “Unsubscribe sent · Archived”, or “Opened in browser · Archived”. A snoozed conversation (in Later, or a search's result, §5.45) is archived already: its snooze ends instead and it stays archived, as E leaves it in Later, so the list's mail does not come back to the Inbox at its time; the toast reads the same. Asked again while that toast is up (a double-click, whose second click is ignored even where the next conversation's link has moved under the pointer; ⇧⌘U again where the archived row stays listed), the same request is not sent twice and the toast keeps its Undo. Undo (the toast, Z, ⌘Z) brings the conversation back (a snoozed one to Later, at its time as before); the request stays sent, which is why the archive is the toast's last word and why the undo confirms itself with “Undid Archive · Unsubscribe stays sent”. Message › Unsubscribe (⇧⌘U), enabled while one conversation is open and a message of it offers it, acts on that conversation's latest such message, as does the context menu's item (§5.35); the More menu's item acts on its own message.

**Tab order inside an expanded sheet.** Tab enters a sheet on the sheet itself (it takes the ring and becomes the target), then moves through, in this order: the Unsubscribe link, when it shows → the sender's address, when it shows apart from the name → the recipients toggle → the open list of recipients, one stop (“Copying an address”) → the header hover actions in visual order (Star, Reply, More, and Original colors when present; they show while anything in the sheet has focus) → the invitation card's controls in visual order (its links, Accept, Tentative, Decline, Open in Calendar, the notice's Reconnect) → the message's elision mark under the card (while the message is folded, its body's links and quoted-text toggle are no stops and come back with it; its banners stay) → banner actions in document order (Load images; the notice's Original colors / Adaptive colors, then its dismiss) → links in the body, in document order, **only with Full Keyboard Access** (the web view's `tabFocusesLinks` follows that setting; otherwise ⌥Tab reaches them, as in Safari) → the quoted-text toggle → the attachment chips, as one stop (← → move between chips, Space opens Quick Look on the focused one) → the footer buttons Reply, Reply all, Forward → the next stack row or sheet, and after the last message the quick reply. ⇧Tab reverses. Every stop draws the Quire ring; links in a body draw it through the injected `a:focus-visible` rule (§8.4: 2 pt `focus`, 3 pt in IC, outside a 1 pt gap in the sheet colour), never WebKit's default ring, whose alpha falls below 3:1. In Original colors the link ring takes the light-mode `focus` value and an `originalPage` gap, because the page under it is white.

**The invitation card.** A message that carries a calendar invitation (an iCalendar REQUEST or CANCEL, read when its body was fetched, never when it opens: §8.5) opens with a card above its body. It answers the invitation and hands it to Calendar; it never becomes a calendar: no other events and no reminders. It does say what the invitation overlaps (the overlap line, below), from the events the day column reads (§5.54), so the answer is given knowing it.

`layout.invitation`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `radius` | 8 | `padX` | 16 | `padTop` | 12 | `padBottom` | 12 |
| `kickerGlyph` | 14 | `kickerGap` | 6 | `titleTop` | 6 | `whenTop` | 2 |
| `detailsTop` | 8 | `labelColumn` | 72 | `rowGap` | 2 | `actionsTop` | 12 |
| `actionsPad` | 10 | `answerGap` | 4 | `answerSize` | small | `answerGlyph` | 12 |
| `attendeesMax` | 4 | `noticeTop` | 10 | `gapBelow` | 16 |  |  |

| Part | Spec |
|---|---|
| Card | `sheet` with an inset hairline `rule` edge (`ruleStrong` in IC), radius `r.lg` (8), padding 12 16 12; at the body indent (48), at most the measure (576) wide, 18 below the header; the message's elision mark 16 below, where the body (and its banners) would start, the body folded behind it (below). No shadow: it is content on the sheet, like a chip |
| Kicker | `calendar` 14 pt, 6 pt, “Invitation” in `runningHead` `ink3`, as the reader's kicker. Cancelled: `exclamationmark.triangle.fill` and “Cancelled”, both `danger` |
| Title | 6 pt below: `title` `ink`, wrapping (never truncated). No title: “No title” in the placeholder style (italic, `ink3`). Cancelled: `ink2` with a 1 pt line through it (the shape that says cancelled beside the word) |
| When | 2 pt below: `body` `ink`, in this Mac's zone: “Tue 11 Mar · 15:00 - 16:00”; “Tue 11 Mar · All day”; “Wed 12 Mar - Fri 14 Mar · All day”; “Tue 11 Mar, 22:00 - Wed 12 Mar, 02:00”; a date outside this year carries its year as the locale writes it. Times follow the system 12/24-hour setting (§4.13). All-day events and times written without a zone read the same everywhere and are never shifted |
| Elsewhere | when the event was written in a zone at another offset from this Mac's at its start: the same line in that zone and its name, `snippet` `ink3`: “Tue 11 Mar · 11:00 - 12:00 Eastern Time” |
| Repeat | 2 pt below, `snippet` `ink2`: the rule in words, never its occurrences: “Every week on Tuesday”, “Every 2 weeks on Monday and Thursday”, “Every month on the 3rd, until 3 March 2027”, “Every month on the last Friday, 10 times”, “Every year on the second Tuesday of March”; a rule whose parts cannot be said reads “Repeats” |
| Details | 8 pt below: rows 2 pt apart, each a label in a 72 pt column (`snippet` `ink3`) and its value (`snippet` `ink2`, wrapping): **Where** the location (a web address is a link, `accent`, underlined on hover and press as a link button, §5.24, and always under Graphite; it keeps to one line, cut with an ellipsis when longer, the whole address in its tooltip, since a Teams link runs to hundreds of characters), then a meeting link on its own row when the invitation names one apart from the location; **Organizer** the organizer's name, or “You”; **Guests** the user first as “You”, then the others by name, at most 4, then “+3 more” (rooms and equipment are never listed; the organizer has their own row) |
| Overlap | 8 pt below the details, while the event overlaps another on the user's calendars: `exclamationmark.triangle.fill` 12 pt `warning`, 6 pt, then “Overlaps 1:1 with Sam, 13:30 - 14:00” (`snippet` `ink`, wrapping), the overlapping event's title and the time the two share; with more than one, the first by start and “and 2 more” (“Overlaps Hiring sync, 11:00 - 11:30, and 2 more”). Glyph and words carry it, never the colour alone (§1). Overlaps count every account's events the store holds for that day except the invitation's own (the same iCalendar UID), declined ones, free ones and all-day ones; an invitation's times without a zone are read in this Mac's zone first (§5.54). None on a cancelled card, an updated one, one not sent to this account or the user's own event; it goes the moment the user declines, and comes back if they answer again. VoiceOver reads it after the When line. No toast, no undo and no action: the answers below are unchanged |
| Actions | 12 pt below, a hairline `rule` above and 10 pt between: Accept · Tentative · Decline as **small** buttons (22 pt, §5.24), 4 pt apart, sentence case (§4.13); then, trailing, the link button “Open in Calendar” (Calendar is the app's name) |
| Answer, not chosen | small secondary: `raised`, `ink` `label`, 1 pt `ruleStrong` inset; hover `raised + hover`, pressed `raised + pressed`; focus ring outside a 1 pt `sheet` gap |
| Answer, chosen | the user's answer: `accentWash` with `checkmark` 12 pt and the label in `labelStrong` `accent`, no edge; hover `accentWashHover`, pressed `accentWashPressed` (the quoted-text toggle's on state, §5.15: tested pairs). The checkmark and the weight carry the state, not the colour. Clicking another answer moves the mark at once; clicking the chosen one does nothing, so it shows the arrow (§4.17). An answer this Mac could not record goes back at once to the one it holds |
| Permission notice | 10 pt below the actions, an info banner (§5.38: `infoWash`, `info.circle` `info`), multi-line: “Answer invitations: SuperSparrow needs permission to update your calendar.” and the link “Reconnect” (§5.44). Only on a card answered on this Mac whose account waits for that permission |

| State | Look |
|---|---|
| Open (not answered) | the three answers, none chosen; Open in Calendar; the overlap line while it overlaps something |
| Answered | the answer chosen (given here, or as the invitation or, for Microsoft, the event states it). It is recorded on this Mac at once and goes to the organizer in the background; the row shows the queued glyph (§5.7) until it has. An answer changed before the earlier one has gone out replaces it, so the organizer hears only the latest. A failed answer goes back to the last answer that went out (none, when none did), and the row shows the failed mark: “Couldn't answer the invitation” |
| Waiting for permission | as answered, plus the permission notice; the answer goes out once the account reconnects with the permission, and the notice leaves |
| Cancelled | kicker “Cancelled” in `danger`, the title struck through, no answers; Open in Calendar stays (Calendar removes the event from there) |
| The user's own event | “Organizer · You”, no answers |
| Not sent to this account | no answers, Open in Calendar stays: an invitation that names neither the account it came to nor a group it may be on (one forwarded to the user, a Bcc, an invitation to another of their addresses) is not that account's to answer; “You” among the guests is that account alone |
| Updated | no answers and none chosen, Open in Calendar stays: a later message in the conversation carries a later revision of the same event or occurrence (a higher SEQUENCE, or the same SEQUENCE stamped later), and only that card is answered, so an answer never repeats times or a revision the organizer has replaced. The card says nothing more: the update is a later message in the same conversation |
| Unreadable | no card at all: an invitation that could not be read whole (an unknown zone, a missing start, broken syntax) shows the message as it is rather than a card that might be wrong |

**Behaviour.** Accept, Tentative and Decline record the answer on this Mac in one transaction and queue it; nothing waits on the network, and there is no undo (an answer is mailed or sent to the organizer; the user changes it by answering again) and no toast (the card shows it). Gmail mails the organizer an iMIP reply from the user's address and marks the user's own Google Calendar copy; Microsoft answers the event. The first answer asks for permission to update the calendar: without it the answer waits, the card shows the permission notice, Settings › Accounts reads “Calendar permission needed” with Reconnect (§5.40), and Reconnect signs in again asking for that permission beside mail (§5.44). Open in Calendar hands the invitation to the Mac's Calendar, which shows it and offers to add it; SuperSparrow asks for no calendar access. A repeating Microsoft event in a zone the Mac does not know goes over as its first occurrence alone: Microsoft gives its times in UTC and its repeat in that zone, which cannot be joined without knowing the zone, and a repeat on the wrong days would be worse than none. Its card still says how it repeats.

**The message under the card.** The body under a card is most often the sender's own rendering of the same invitation (Google Calendar's When, Guests, Reply and Join with Google Meet; Outlook's equivalent), so it starts folded behind the reader's elision mark (§5.15), the quoted-text toggle's component, states and motion: at the indent, 16 below the card, where the body would start, reading “Show message”; unfolded it reads “Hide message” (the on state) and stays where it is, the whole body 12 below it exactly as it shows without a card, banners first and its own quoted text still folded under its own toggle. Every state of the card folds it: to answer, answered, waiting for permission, updated by a later revision, cancelled, the user's own event, not sent to this account. A message without a card is unchanged. The mark unfolds and folds on a click, ↩ or Space with focus (focus stays on the mark; the app's ↩ for Open and Space for Quick Look give way to a focused mark, §5.15), and “.” (§6), which on a message under a card folds and unfolds the message rather than its quoted text; there the quoted-text toggle's tooltip names no key. Folding with “.” while focus is in the body (its quoted-text toggle, a link) moves the focus to the mark, never leaving it on what the fold hides. Tooltip “Show Message  .” / “Hide Message  .”; VoiceOver “Show message, toggle button” and its pressed state. The fold is remembered as the quoted-text toggle's is: per message, through the store's renders (an answer, the permission notice, a read), while the reader keeps the conversation, and forgotten when it renders it afresh. Folded, only the body itself folds: its banners (§5.16) stay in view 12 below the mark, where the body starts, as they stay over folded quoted text, so what reads the body works and answers where it can be seen, and leaves the fold as it is: Load images (the banner's link, ⇧⌘I, More) shows its progress and loads the images, Original colors (the notice's button, ⇧⌘O, the hover action, More) switches the rendering, and both show in the body once it unfolds. Attachment chips stay visible, 16 below the mark or the last banner, and the footer follows as usual. The fold is decided from the card alone, never from the HTML, and the body still loads when the message opens, out of sight and out of reach, so unfolding animates the sheet straight to its height (`dur.standard`, `ease.settle`; Reduce Motion: instant).

**Accessibility.** The card is a group named “Invitation: Design review” (“Cancelled event: Design review”); each answer is a toggle button with its pressed state (VoiceOver: “Accept, toggle button, selected”); the links and Open in Calendar are buttons; every stop draws the Quire ring and joins the sheet's Tab order (above). The card is drawn again when the store changes it (an answer recorded, the permission notice shown or gone); the control that had focus keeps it, and when that control is gone (Reconnect, once granted) focus goes to the sheet, so a keyboard or VoiceOver user never loses their place. All inks are tested pairs on `sheet`, `raised`, `accentWash` and `infoWash` (§7).

**Wide HTML.** Styled bodies render at the sheet's content width (column − 2 × sheet padding x). After an iframe loads, the shell reads the body's `scrollWidth` once (layout, not a scan of the HTML). If it is wider than the content width, the body is scaled with CSS `zoom` to fit, down to 0.74; if fitting needs less than 0.74, the body stays at 0.74 and scrolls horizontally inside its iframe (scroller only while scrolling, `overflow-x: auto`); nothing is clipped. The fit is recomputed when a live resize ends, never per frame.

Worked example, a 600 px newsletter with the default 364 pt list, for both rail widths (§3.2):

| Window | Reader (macOS 15, rail 76 / macOS 26 and later, rail 84) | Column | Content width | Zoom needed | Result |
|---|---|---|---|---|---|
| Default 1304, beside the day column (240, §5.54) | 624 / 616 | 560 / 552 | 504 / 496 | 0.840 / 0.827 | zoomed to fit on both |
| Default 1304, day column hidden (D) | 864 / 856 | 680 / 680 | 624 / 624 | — | fits unscaled |
| Minimum 960, the day column folded to its 28 pt strip (narrow reader: margins and sheet padding 16) | 492 / 484 | 460 / 452 | 428 / 420 | 0.713 / 0.700 | stays at 0.74 and scrolls |
| Minimum 960, day column hidden (narrow reader) | 520 / 512 | 488 / 480 | 456 / 448 | 0.760 / 0.747 | zoomed to fit on both |
| Minimum, day column hidden, Original colors (dark) | 520 / 512 | 488 / 480 | 432 / 424 (the inset's inner width) | 0.720 / 0.707 | stays at 0.74 and scrolls |
| 400 pt minimum reader | 400 | 368 | 336 | 0.560 | stays at 0.74 and scrolls |

`htmlMinZoom` is 0.74, set just under 0.747 so that the minimum window with the day column hidden fits a standard 600 px newsletter on every supported macOS instead of scrolling it by 2 px (beside the strip, 1.9, it scrolls by 16 or 24 px at 0.74; D gives the reader its 28 pt back) (at 0.75 the macOS 26 case would overflow 448 pt by 2 pt); 0.74 keeps a sender's 12 px text at 8.9 px, the same legibility floor as before.

**Colour in dark appearances.** What a body looks like depends on two flags stored at sync time (`typesetting` and `declaresColors`, §8.5), never on a scan at open:

| Body | Light, Light IC (every theme) | Dark, Dark IC, Adapt on (the default): **Adapted** | Dark, Dark IC, Adapt off: **Original colors** |
|---|---|---|---|
| Plain or unstyled | the theme's inks on the theme's sheet (`reading`) | the same, on the theme's dark sheet | the same: nothing to adapt, so no notice and no hover action |
| Styled, declares no colours | as sent, on the sheet, which every theme keeps the white page (§4.16); a link its sender left uncoloured in `--q-linkOnPage` | `color-scheme: dark` on the body document: the browser defaults turn light-on-transparent, so the dark sheet shows through; a link its sender left uncoloured in `--q-linkOnPage` through a zero-specificity rule (`:where(a:link)`) | the same |
| Styled, declares colours | as sent, on the sheet (the sheet is already the white page the sender designed for); no notice, no inset | the shell puts `ss-adapt` on the body document's root: `color-scheme: dark`; every declared text colour becomes `ink` (links `accent`); declared background colours and background images are removed (transparent, so the dark sheet shows); declared border colours become `rule`. Layout, fonts, sizes and `<img>` elements are untouched; all of these are the active theme's. The notice says so: “This message uses its own colours.” · Original colors (§5.16). Switched to Original colors by hand: the white inset of the next column, with “Showing the sender's colours.” · Adaptive colors | nothing is overridden: `ss-adapt` is removed and the body renders exactly as sent on an `originalPage` inset (`#FFFFFF` in every mode) inside the sheet, radius `r.xs` (3), padding 12 on every side (`layout.reader.originalInsetPad`), filling the sheet's content width; wide-HTML fitting measures the inset's inner width (content width − 2 × 12). **No notice**, since Settings chose it; the header hover action, More and ⇧⌘O adapt this one message, which then shows “This message uses its own colours.” · Original colors |

Adaptation **replaces** colours rather than inverting them or relying on `color-scheme` alone: `color-scheme` changes only the browser's defaults, so a sender's declared black text would stay black on the dark sheet, and inversion cannot promise any contrast. With Quire's inks every adapted text pair is one of the tested pairs (§7). The cost is the sender's brand colour, and images drawn for a white page (a dark logo with a transparent background) can disappear; Original colors restores both in one keystroke. In Dusk, adapted text is the dimmed night ink and adapted borders the ratio-locked `rule` (§4.16).

**The Dark Mode default** (Settings › Appearance › Dark Mode, “Adapt mail that sets its own colours”, on) decides which of the two a styled message that declares colours opens in, in a dark appearance. A message's own switch is a choice on top of it, per message and per session: the shell reads one effective state, the switch made by hand if there is one and otherwise the default, and every way to switch (⇧⌘O, the notice's button, the header hover action, More) flips what the message **shows**, so with either default the first ⇧⌘O changes the message and a second restores it. A message switched by hand keeps its choice when the default changes. View › Original Colors carries a checkmark while the focused message shows the sender's colours, read from what is shown. Every body frame sits in a permanent page wrapper (`.ss-page`) whose `ss-inset-on` class is the white inset, so a switch, a change of the default and an appearance change toggle classes and refit one message, and never build a frame again (§8.4). The white page is never themed: a link on it takes the focus ring `--q-focusOnPage`, the theme's light focus.

| State | Treatment |
|---|---|
| Rest | as above |
| Hover | header actions and the sender's address appear; a recipient or the address under the pointer takes its face |
| Focused (`n`/`p`, Tab) | ring around the sheet outside a 2 pt `canvas` gap |
| Target (several expanded, or keycaps hidden) | 1 pt `ruleStrong` edge; footer keycaps |
| Starred | `star.fill` after the name, at rest |
| Unread | pip before the name |
| Loading body | skeleton bars (§5.10), only while a body fetch is actually in flight (and after 300 ms); never as a placeholder for a fetch that is not running |
| Body not downloaded, offline | the stored snippet stands in for the body: `reading` (or `readingSans`) in `ink2`, at the indent, inside the measure, ending in “…”; 12 pt below it a neutral banner (§5.38, `fill`): `wifi.slash` `ink2` + “The full message will load when you're back online.” No action and no skeleton: when the connection returns the fetch starts by itself, the skeleton shows while it runs, then the body replaces the preview. Attachments known from the metadata still show as chips. VoiceOver reads the preview, then the notice |
| Body failed (online; the fetch itself failed) | “Couldn't load this message · Retry” as a danger banner (§5.38) in place of the body |
| Pending send | full contrast; the date reads “Sending…” with a 12 pt spinner. A reply in the outbox (scheduled or sending; not a forward, which starts its own conversation) shows as the newest sheet of the conversation it answers, built from the outbox row: its plain-text part set as a plain body, no header actions and no footer, never the target. It goes when the send leaves or is undone; the provider's copy arrives with the next sync |
| Dark mode, styled HTML that declares colours | **Adapted** with Adapt on (the default), with the notice; **Original colors** with Adapt off, with none, on the white `originalPage` inset; either switched for one message by ⇧⌘O, the hover action, More or the notice. Both renderings are specified above, under “Colour in dark appearances” |

### 5.15 Quoted-text toggle (the elision mark)

`layout.quotedToggle`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `height` | 24 | `radius` | 6 | `padLeft` | 6 | `padRight` | 9 |
| `gap` | 6 | `glyph` | 14 | `composerChip` | 22 |  |  |

`ss.elide` 14 pt + `label` “Show quoted text” / “Hide quoted text”; the same mark folds the message under an invitation card, “Show message” / “Hide message” (§5.14). The label says what the mark hides. With keyboard focus, ↩ or Space presses it: the reader's ↩ (Open) and Space (Quick Look, §6) give way to a focused mark, even on a message with attachments. Find in conversation unfolds the quote (or the message) holding its current match, and leaves it unfolded (§5.50).

| State | Fill | Text and glyph |
|---|---|---|
| Folded, rest | `fill` | `ink2`, “Show quoted text” (“Show message”) |
| Folded, hover | `fill + hover` | `ink` |
| Folded, pressed | `fill + pressed` | `ink` |
| Unfolded, rest | `accentWash` | `accent`, “Hide quoted text” (“Hide message”) |
| Unfolded, hover | `accentWashHover` | `accent` |
| Unfolded, pressed | `accentWashPressed` | `accent` |
| Focused (either) | ring outside a 1 pt `sheet` gap | unchanged |

The label carries the state; `accent` keeps 4.5:1 on all three unfolded fills in every mode (§7). In the composer the folded original is a glyph-only 22 pt chip followed by the attribution the message will carry, with the author's name only: “On 1 Nov 2026 at 23:39, Ben Carter wrote:” (a forward: “Forwarded message from Ben Carter · 1 Nov 2026 at 23:39”), in `snippet` `ink3`; the date is absolute, as sent, never “Today”. Clicking either unfolds it. Unfolding animates the quote height (`dur.standard`; Reduce Motion: instant). Revealed quotes use the shared quote style (`layout.textStyle`): a 2 pt `rule` leading bar and a 12 pt indent, text in `ink2`, in the reader and the composer alike.

### 5.16 Remote-images banner and Original colors

The first element of a body whose remote images are blocked. Neutral: privacy is not a warning.

`layout.banner`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `height` | 32 | `radius` | 6 | `padLeft` | 10 | `padRight` | 6 |
| `gap` | 8 | `glyph` | 14 | `narrowBreakpoint` | 420 | `padY` | 8 |
| `dismissGlyph` | 9 |  |  |  |  |  |  |

| Part | Spec |
|---|---|
| Banner | `fill` over `sheet`, radius 6 |
| Glyph | `photo` 14 pt `ink2` |
| Copy | “3 remote images hidden to protect your privacy.” (`snippet`, `ink`); “3 remote images hidden.” below 420 pt |
| Action | link button “Load images” (`label`, `accent`), 24 pt hit. Loading is per message, as `docs/ARCHITECTURE.md` specifies; there is no per-sender allowlist |
| Dismissal | disappears when the images load; no close button |

States: rest; action hover (the link gains its 1 pt underline; no wash: link buttons never take one, §5.24); action pressed (underline kept, label `ink2`: a `pressed` wash behind `accent` on this `fill` banner would fall to 4.22:1 in Dark); action focused (ring); loading (12 pt spinner replaces the glyph, “Loading 3 images…”); partial failure (“2 images couldn't load” with `exclamationmark.triangle.fill` in `warning`).

**Original colors notice** (warning banner, dark appearances only) at the top of a styled body whose `declaresColors` flag is set. Its two states are the two renderings of §5.14 (“Colour in dark appearances”): **Adapted** (the theme's inks on the dark sheet, the sender's colours removed) and **Original colors** (the body exactly as sent, on the white `originalPage` inset with 12 pt padding). A notice shows only while a message is not in the state the Dark Mode default chose, plus the adapted notice: with Adapt off, a message shown as sent has none. The notice itself always sits on the dark sheet, above the inset, never inside it, and keeps `warningWash` and `ink` in every theme.

| State | Glyph | Copy | Action |
|---|---|---|---|
| Adapted (Adapt on, or switched by hand with Adapt off) | `circle.lefthalf.filled` `warning` | “This message uses its own colours.” | “Original colors” (`labelStrong` in `ink`, 24 pt hit) |
| Original colors shown, switched by hand while Adapt is on | `circle.lefthalf.filled` `warning` | “Showing the sender's colours.” | “Adaptive colors” |

Hover and pressed put `hover` / `pressed` behind the action; focus rings it. A trailing dismiss button (`xmark` 9 pt `ink2`, 24 pt hit, tooltip “Don't Show Again”; `xmark` is in the reader symbol set, §4.11) hides the notice **everywhere**, from then on (one app preference, `originalColorsNoticeDismissed`); the hover action, More and ⇧⌘O keep the toggle one step away, and View › Original Colors carries a checkmark when on. The notice sits after the images banner when both apply (the one-banner-per-message rule of §5.38 counts the images banner as content, not status).

### 5.17 Attachment chip

`layout.attachmentChip`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `height` | 44 | `minWidth` | 196 | `maxWidth` | 264 | `radius` | 8 |
| `padLeft` | 8 | `padRight` | 6 | `gap` | 10 | `tile` | 28 |
| `tileRadius` | 5 | `tileGlyph` | 15 | `progressWidth` | 120 | `progressHeight` | 2 |
| `chipGap` | 8 | `download` | 24 | `downloadGlyph` | 14 | `downloadGap` | 4 |
| `downloadRadius` | 5 | `head` | 24 | `headGap` | 8 |  |  |

Anatomy: type tile (28 pt, radius 5, `fill`, 15 pt symbol `ink2`: `doc`, `doc.richtext`, `photo`, `tablecells`, `doc.zipper`, `film`; or a Quick Look thumbnail when cached) · name (`label`, `ink`, middle-truncated) over meta (`meta` `ink3`: “PDF · 240 KB”) · the Download button. Edge: inset hairline `rule`; fill `sheet`.

**Download.** Every chip carries a visible Download button at its trailing end, never only on hover (§9): a 24 pt square (its own hit target), radius 5, 4 pt after the name and meta and 6 pt from the chip's edge, with `arrow.down.circle` at 14 pt in `ink2` (`ink` on hover and press, behind it `hover`, `pressed`). It is the context menu's Save to Downloads made visible: the file is saved to Downloads under its own name, numbered as the Finder numbers a copy (“plan 2.pdf”) when the name is taken, and keeps the quarantine mark every attachment file carries, so Gatekeeper still asks before anything in it runs; a copy that cannot be marked (a Downloads folder on a volume that keeps no extended attributes) is removed, and the toast says it was not saved. The chip shows the download as its Downloading state; the saved toast follows (§5.30). Tooltip “Save to Downloads”; VoiceOver “Download plan.pdf”. While the chip downloads the button is disabled (`inkDisabled`) and a second press does nothing. A double-click saves once, even a file already on this Mac, which is saved before the second click lands; a press while the message's Download all is saving that file does nothing either.

**Download all.** A message with two attachments or more (inline images never count) opens its chips with a line of their own, 24 pt high and 8 pt above the chips: the count in `meta` `ink3` (“3 attachments”), then the link button “Download all” (§5.24, `label` `accent`, sentence case in the reader, §4.13; tooltip “Download Attachments  ⇧⌘D”). It saves every attachment of that message to Downloads, one after another, with one progress: the count gives way to the 120 × 2 pt contrail, its length the share of all the files' bytes that has arrived (by their listed sizes; a file without one counts as the average of the others), and the link is disabled until the last file is saved (a double-click saves them once). A file whose own Download is under way is left to it, so no file is saved twice. The chips themselves do not show the batch; a file that cannot be fetched shows its chip's Error state, and the rest are saved all the same. A conversation left while its files arrive shows, when it comes back, where the download stands: the contrail, or the count and the link again and any Error state, if it ended meanwhile. The toast says what was saved (§5.30). File › Download Attachments (⇧⌘D) does the same for the target message from anywhere in the main window; on a message with one attachment it is that chip's Download.

Keyboard: the chips are one Tab stop (← → move between them), followed by the focused chip's Download button; Download all comes before them. Space and ↩ press a focused Download button or Download all, as they press the elision mark (§5.15), rather than opening Quick Look or the conversation.

| State | Change |
|---|---|
| Hover | `sheet + hover`, edge `ruleStrong`, meta reads “Space to Quick Look” |
| Pressed | `sheet + pressed` |
| Focused | ring (1 pt gap) |
| Download button | rest `ink2`; hover `hover` behind it, `ink`; pressed `pressed`, `ink`; focused ring (1 pt gap); disabled `inkDisabled` while the chip downloads. Hovering the button gives the chip its hover fill and edge but not its hover meta |
| Downloading | meta replaced by a determinate contrail 120 × 2 pt on a `rule` track, shown once the fetch outlasts 150 ms (a cached file never flashes it). Its length is the share of the file that has arrived, measured against the length the server states or, without one, the attachment's listed size, and stops just short of full until the file is decoded and stored; it moves at most about ten times a second. Only while the size of what is arriving is unknown (no listed size and no stated length) does the contrail sweep, indeterminate, Reduce Motion a still segment; a length learned later turns it determinate. The meta returns when the fetch ends; a failure shows the Failed state |
| Error | tile glyph `exclamationmark.triangle.fill` `danger`; meta “Couldn't download · Retry” in `danger`, “Retry” in `metaStrong` `accent` |
| Dragging out | lifts with `e2` (the only shadowed chip state) |

Click or Space opens Quick Look; double-click opens with the default app; the Download button saves to Downloads; context menu: Quick Look, Open, Save to Downloads (what the Download button does, toast included), Save As…, Copy.

### 5.18 Quick reply bar

Docked to the bottom of the reader, drawn **over** the web view: the web view always fills the reader below the header, and the shell is told the bar's height as a bottom inset (`ss.setBottomInset(px)`, once per height change), so the last message can scroll above the bar. The web view's frame never changes while the bar grows.

`layout.quickReply`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `rest` | 60 | `barPadY` | 11 | `field` | 38 | `fieldRadius` | 8 |
| `fieldPadTop` | 9 | `fieldPadBottom` | 8 | `face` | 24 | `faceX` | 12 |
| `faceTop` | 7 | `faceMonogram` | 11 | `faceMonogramTwoLetter` | 10 | `textX` | 48 |
| `restTrailing` | 67 | `focusedTrailing` | 12 | `restSend` | 28 | `restSendGlyph` | 15 |
| `restSendInset` | 5 | `restKeycapGap` | 8 | `toolRowGap` | 4 | `toolRow` | 28 |
| `toolRowBottom` | 4 | `modeGap` | 16 | `modeHitPad` | 6 | `toolGroupGap` | 12 |
| `toolIconGap` | 2 | `toolIcon` | 22 | `toolIconGlyph` | 14 | `sendInset` | 8 |
| `sendKeycapGap` | 8 | `maxLines` | 5 | `fieldMax` | 150 | `max` | 172 |
| `stripGlyph` | 14 | `stripGap` | 8 | `stripKeycapGap` | 8 | `modeUnderlineY` | 24 |

**Anatomy and metrics** (x from the field's leading edge, y from its top):

| Part | Spec |
|---|---|
| Bar | 60 pt at rest = 11 + field 38 + 11; `paper`, top hairline |
| Field | on the reading column; radius 8; `sheet`; 1 pt `ruleStrong` edge; text padding 9 top, 8 bottom |
| Face | the replying account's rail face at 24 pt with its ring (2 pt `sheet` gap + 2 pt account ink, so the ring's outer edge is 4 pt further out), face at x = 12, y = 7; monogram New York Semibold 11 pt (10 pt for two letters; `monogramSans` under the SF Pro font, §5.29) in `ink` |
| Text | `writing` (14/21) from x = 48; trailing inset 67 at rest (room for the keycap and send), 12 when focused |
| Placeholder | “Reply to Ben Carter…” (`writing`, `ink3`); “Reply all to Ben Carter and 2 others…” in Reply all mode |
| Trailing (rest) | send icon button 28 pt, `paperplane` 15 pt, `inkDisabled`, inset 5 from the trailing and top edges; keycap “R” 8 pt before it. It does what Send does; its tooltip and VoiceOver name say which (§5.23) |
| Tool row (focused) | 28 pt, 4 pt under the last text line, 4 pt above the field's bottom, starting at x = 48: the mode tabs Reply · Reply all (16 pt apart), then after 12 pt Attach and Open in Composer (⇧⌘R) as 22 pt icon buttons with 14 pt symbols, 2 pt apart; trailing, 8 pt from the edge, Send's drop-down (a 22 pt menu button, `chevron.down` 12 pt, §5.23) and 2 pt before it a small primary “Send” with keycap “⌘↩” 8 pt before that |

**Growth.** Field height = 9 + lines × 21 + 8 when not focused and showing one line; focused = 9 + lines × 21 + 4 + 28 + 4. Focused and empty that is 66 (bar 88). The text grows to 5 lines: field max 150, bar max 172, both **including** the tool row; past that the text scrolls inside the field. Unfocused with text, the field returns to 38 pt showing the first line, tail-truncated, so the reader does not jump when focus leaves. Height changes use `dur.standard` `ease.glide` (Reduce Motion: instant).

**Reply mode** (Reply · Reply all) is a pair of underline tabs (`QuireUnderlineTabs`, the only place Quire uses them): `label` with the reply glyph at 12 pt; the active mode is `labelStrong` `ink` with a 2 pt `ink` underline under the label (2 pt `ink3` when the window is not key). Labels are centred in the 28 pt tool row (label box y = 6–22); the underline's top is at y = 24 from the tool row's top (`quickReply.modeUnderlineY`), 2 pt below the label box and 2 pt above the row's bottom; the inactive one is `label` `ink2`. Hover / pressed on the inactive tab: `ink`. Focused: ring around the label, radius `r.sm`. Reply all is disabled (`inkDisabled`, skipped by Tab) when the message has one other participant. ← → switch while a tab is focused. From the list or the reader, R focuses the field in Reply mode and A in Reply all mode; while typing, single keys type, so the mode changes only through the tabs. VoiceOver: “Reply, selected, tab 1 of 2”.

| State | Look |
|---|---|
| Rest | as above |
| Hover | edge `ink3` |
| Focused, empty / with text | ring outside a 1 pt `paper` gap; tool row |
| Counting down (sent, inside the undo window) | the strip below replaces the field's contents |
| Error (could not queue the send) | 1.5 pt `danger` edge; text kept; the tool row's leading status reads `exclamationmark.triangle.fill` + “Couldn't send · Open in composer” in `danger` (`snippet`); Send stays enabled to retry |
| No one to reply to (the reply has no recipients) | text allowed; Send disabled, tooltip “No one to reply to”; the tool row shows `exclamationmark.triangle.fill` `warning` + “No one to reply to” (`snippet` `ink2`) and Open in Composer stays available |
| Disabled (a draft for this conversation is open in the composer) | `fill`, no edge, placeholder “Reply in the composer”; clicking brings that window forward |

**Sends from the quick reply stay in the bar.** The floating undo-send panel (§5.31) is for composer sends, whose window has closed; a quick reply is sent where the eyes already are. After ⌘↩ (what Send does, Send and Archive by default) or ⇧⌘↩ (always Send and Archive, §5.23) the field clears and its frame shows the **strip** for the undo window, so the bar keeps its height and nothing else moves:

| Strip state | Content (glyph 14 pt, gap 8) | Duration |
|---|---|---|
| Counting | `paperplane.fill` `ink2` · “Sending in 4 s” (`body`, tabular, `ink`; after Send and Archive “Archived · sending in 4 s”, the archive first, since this lead never truncates) · “to Ben Carter” (`snippet` `ink3`, truncates first) · trailing small secondary “Undo”, with the keycap “⌘Z” 8 pt **before** it, outside the button (`quickReply.stripKeycapGap`; the same placement as “⌘↩” before the quick reply's Send. Only slip actions carry their keycap inside, because a slip action has no face for a keycap to sit beside); a 2 pt `accent` contrail along the strip's bottom inside edge drains over the undo window, and the seconds count down as text (Reduce Motion: the contrail steps once per second) | the undo window (Settings: 5 / 10 / 20 s) |
| Undone in time | the strip closes at once; the text returns to the field with the caret at its end, focused. After Send and Archive the conversation is back in the Inbox first, and selected again, so the text returns to its own field | — |
| Sent | `checkmark` `ink2` · “Sent” | 1500 ms, then the field returns (cross-fade `dur.quick`) |
| Undo too late | `checkmark` `ink2` · “Already sent” · “Undo came after the message left.” (`snippet` `ink3`) | 3000 ms |
| Undone after moving on (the selection changed during the countdown) | `arrow.uturn.backward` `ink2` · “Not sent · draft kept in “Contoso rollout”” · link “Show” (selects that conversation) | 3000 ms |
| Failed after the window | the bar is not involved: an error toast “Couldn't send your reply · Open draft” (§5.30); the reply is kept as a draft holding its reason and leaves the Outbox for Drafts (§5.53) | toast rules |

**Signature.** The bar never shows the replying account's signature (§5.20), but a reply sent from it carries it: below the typed text after one empty line (in the HTML, the paragraph break the bar sends for every blank line), with nothing added between them. Open in Composer hands the typed text to a reply composer, which inserts the signature by its own rule, below that text.

During Counting, clicking the strip outside Undo or pressing R brings the field back for a new reply; the countdown then continues as the tool row's leading status (“Sending in 4 s · Undo”, or “Archived · sending in 4 s · Undo”, `snippet`, with its contrail under it) until it resolves. The strip belongs to the bar, not to the conversation: it stays while the selection moves on, which Send and Archive makes the usual case in the Inbox (the conversation leaves the list and the next one opens, as after E). If the new reader state hides the bar (nothing or several selected, Drafts, Trash, Later emptied), the countdown moves to an undo-send panel (§5.31) for its remaining seconds, with the archive, so Undo is never lost.

**Visibility.**

| Reader state | Quick reply |
|---|---|
| One conversation open (Inbox, Starred, Sent, All Mail; body loading or loaded; offline) | shown; offline sends queue and the strip reads “Will send when you're back online” after the window |
| Nothing selected; several selected | hidden; the web view takes the full height |
| Drafts | hidden (Continue Editing is the action, §5.19) |
| Trash | hidden; R / A / F still open the composer |
| Conversation emptied while open | hidden |

Keycaps never sit on accent fills: “⌘↩” is beside the Send button, not inside it. The R, ⌘↩ and ⌘Z keycaps hide below a 616 pt reader (§5.36).

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
| A Send Later message (§5.46) | the same sheet, built from the message as it will be sent (its plain-text part, set as typed); the date reads “Sends Mon 09:00” followed by a middle dot and the link “Cancel” (`snippet` `ink2`, underlined like Unsubscribe's, §5.14; tooltip “Cancel Send Later”), and the time's tooltip adds “while SuperSparrow is open”. Continue Editing and ↩ cancel the schedule first, then open the draft it was written in, and so does Continue Editing on a provider's draft that draft continues (the conversation still shows that one), rather than a fresh copy that would go beside it; once it is on its way, both beep; Discard takes the schedule and the draft, and Undo brings back both. Once its time has come the date reads “Sending…” and Cancel is gone; a time missed while the app was closed reads “Not sent”. The Outbox lists it too, with every other message on its way (§5.53) |

The quick reply is hidden in Drafts.

**Conversation emptied while open.** The desk shows the empty state “No messages to show” / “They were deleted or moved on another device.” (§5.9); the header keeps the subject; only Trash stays enabled; the quick reply is hidden.

### 5.20 Composer window and fields

640 × 600 default (min 520 × 420). The window has a transparent system title bar over `paper` (28 pt on macOS 15, 32 pt from macOS 26 on, read from the window, §3.2): the system draws the lights and the title, which is the subject, or “New Message” when the subject is empty; a hairline closes the band. No toolbar.

`layout.composer`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `dropOutline` | 2 | `dropInset` | 8 | `stripGlyph` | 14 | `removeGlyph` | 9 |
| `width` | 640 | `height` | 600 | `minWidth` | 520 | `minHeight` | 420 |
| `fieldRow` | 36 | `subjectRow` | 42 | `labelX` | 16 | `labelColumn` | 56 |
| `valueX` | 84 | `bodyPadTop` | 20 | `bodyPadRight` | 24 | `bottomBar` | 52 |
| `strip` | 48 | `stripChip` | 30 | `stripChipRadius` | 6 | `removeVisual` | 16 |
| `fromDot` | 7 | `fromDotGap` | 8 | `fieldTrailing` | 16 | `ccBccGap` | 4 |
| `focusRingX` | 78 | `focusRingInsetY` | 3 | `focusRingRadius` | 5 | `focusRingButtonGap` | 6 |
| `bannerInsetX` | 16 | `bannerInsetY` | 8 | `barPadX` | 16 | `barKeycapGap` | 8 |
| `barGroupGap` | 12 | `barIconGap` | 2 | `statusGlyphGap` | 6 | `stripPadX` | 16 |
| `stripChipPadLeft` | 8 | `stripChipInnerGap` | 6 | `stripChipPadRight` | 4 | `stripChipSpacing` | 8 |
| `stripChipMaxWidth` | 240 | `formatRow` | 36 | `formatToggle` | 28 | `formatGap` | 2 |
| `formatGroupGap` | 12 | `linkPopoverWidth` | 320 | `linkPopoverPad` | 12 | `linkPopoverRadius` | 8 |
| `linkPopoverGap` | 8 | `linkPopoverAlign` | selectionStart | `linkPopoverOffsetY` | 6 | `popoverEdgeMin` | 8 |
| `pictureSelectedWash` | 0.45 |  |  |  |  |  |  |

| Part | Spec |
|---|---|
| Field rows | 36 pt (Subject 42), `paper`; labels in a 56 pt column right-aligned from x = 16 (`snippet`, `ink3`: From, To, Cc, Bcc, Subject); values from x = 84; hairlines between rows from x = 16 to 16 pt before the window's trailing edge (`layout.composer.fieldTrailing`), the same inset as the labels |
| From | borderless popup (§5.27): 7 pt account-ink dot, 8 pt, “Alex Morgan <alex@contoso.test>”, `chevron.up.chevron.down`; shown only with two or more accounts. Changing From changes the sending account and replaces the signature (below). Hovered or pressed, the face takes `raised + hover` / `raised + pressed` and the dot keeps its 2 pt `raised` halo (§5.27) |
| To / Cc / Bcc | token fields (§5.21); small ghost “Cc” and “Bcc” buttons trail the To row until used, the last one's trailing edge 16 pt from the window's edge, 4 pt apart, centred on the row's first line |
| Subject | `composeSubject` (New York; `composeSubjectSans` when needed), `ink` |
| Body | `sheet`, padding 20 24 0 84 (the text starts on the value axis); `writing`; text styles below; pictures in the text (Images in the body, below) |
| Folded original | the elision chip + “On 1 Nov 2026 at 23:39, Ben Carter wrote:” (§5.15) |
| Format row | toggled by the Format button or ⇧⌘T, remembered per window: a 36 pt `paper` row with a top hairline directly above the bottom bar (and above the strip when attachments show) |
| Attachment strip | §5.22 |
| Bottom bar | below |

**Bottom bar.** 52 pt, `paper`, top hairline, padding x 16, everything centred vertically: Send (regular primary, §5.23) · 2 pt after it, Send's drop-down (28 pt, §5.23) · the “⌘↩” keycap 8 pt after that · after 12 pt, Attach (`paperclip`) and Format (`textformat`, `accentWash` when the format row is shown) as 28 pt icon buttons 2 pt apart. Trailing, at 16: the status, `meta`, glyph 6 pt before the words.

| Status | Glyph | Copy | Lasts |
|---|---|---|---|
| Loading the original (reply, forward) | 12 pt spinner (after 150 ms) | Loading original message… (`ink3`) | until loaded; the body is editable meanwhile |
| Original gone | `info.circle` `ink3` | The original message is no longer available. (`ink2`) | until the next status |
| Original failed | `exclamationmark.triangle.fill` `warning` | Couldn't load the original message; it won't be quoted. (`ink2`) | until the next status |
| Attachments failed (forward) | `exclamationmark.triangle.fill` `warning` | One attachment couldn't be loaded. / 2 attachments couldn't be loaded. (`ink2`) | until the next status |
| Rejected drop (folders, unreadable files) | `exclamationmark.triangle.fill` `warning` | one folder: “Folders can't be attached: “Project Files”.”; one unreadable file: ““budget.xlsx” couldn't be read, so it wasn't attached.”; several: “3 items weren't attached: folders and unreadable files are skipped.” (`ink2`; the tooltip lists every name). The readable files of the same drop are attached as usual; there is no alert | until the user edits the body |
| Saved | `checkmark` `ink3` | Draft saved (`ink3`) | until the next edit |
| Saving | — | Saving… (`ink3`) | while saving |
| Offline | `wifi.slash` `ink3` | Will send when you're back online (`ink3`) | while offline |

A newer status replaces an older one, except that the warnings stay until the user edits the body, so they are read.

**Mail links.** A `mailto:` link opened in another app (a link in Safari, Email in Contacts) opens a new composer, never a reply, from the account in scope: the account the main window is narrowed to, or under All Inboxes the first account in rail order. The link's To (its address part and any `to` field, combined), Cc, Bcc, Subject and body fill the fields (Cc and Bcc rows shown when filled; the body as plain text, its line breaks kept, followed by the account's signature as on any new message); every other field a link can carry (`In-Reply-To`, `attach`, anything else) is ignored. Focus goes to To when the link names nobody, else to Subject when it has none, else to the end of the link's body, above the signature. What the link filled in is the window's starting point, as a reply's prefill is, so closing it untouched keeps no draft. Nothing is sent until Send. With no account the main window comes forward on the welcome screen (§5.39) and no composer opens. Settings › General says whether SuperSparrow opens mail links (§5.40).

**Services.** Two items in the system's Services menu, which other apps show (`NSServices` in Info.plist; no extension): New Message with Selection takes the selected text, and Send with SuperSparrow takes the selected files (Finder offers it for files, not folders, which can't be attached). Each opens a new composer, never a reply, from the account in scope, as a mail link does. The text becomes the body as plain text, its line breaks kept, without the empty lines before it or the white space after it, and is followed by the account's signature; the caret waits at its end. The files are attached as if dropped on the composer: a folder or a file that can't be read is skipped with the rejected-drop status, and the providers' size limits apply at Send as for any attachment (Send failed, below). Focus goes to To, which neither fills. What the service filled in is the window's starting point, so closing it untouched, or Esc, keeps no draft; nothing is sent until Send. With no account the main window comes forward on the welcome screen (§5.39) and no composer opens. Neither has a key or a cheat-sheet row: a service's key works in every app, so it is the user's to choose, in System Settings › Keyboard › Keyboard Shortcuts › Services. SuperSparrow's own Services menu offers New Message with Selection too, for text selected in a message or a composer.

**Signature.** Each account may have a signature, set in Settings › Accounts (§5.40) and empty by default. It is text in the body like any other: the composer inserts the From account's signature, when it has one, on a new message, a reply and a forward (a mail link's message and the quick reply's hand-off included), one empty line below the line the caret starts on and so above the folded original. Nothing else is added: no “-- ” line, no rule, no extra spacing. It is set in the composer's own formatting (`writing`; bold, italic, underline and links as typed in Settings), and the user selects, edits and deletes it as any other text; the caret starts where it does without one, above it. Text typed into it or after it is the user's.

| Event | The body |
|---|---|
| A new message, reply or forward opens | the typed or prefilled text (if any), the line break ending it, one empty line, the signature; nothing when the account has none |
| From changes, the signature still there | the inserted signature is replaced, as a whole, by the new account's; if the user edited inside it, the edits go with it. Text before and after it stays. When the new account has none, the signature goes with the empty line before it |
| From changes, the signature deleted by the user | nothing is added, for this account or any other chosen later in the window |
| From changes, the body has none because the previous account had none (or a From change removed it) | the new account's signature is added below what was written, one empty line after it |
| A kept draft or an undone send reopens | exactly as left: no second signature, and a From change replaces only a signature still in it, never adds one |

A From change is one undoable edit: Edit › Undo in the body restores the body as it was before it (the From popup keeps its choice). A From change that edits the body first closes the link popover if it is open (a click on From leaves focus in it), since the selection it would link has moved. The signature alone is not worth keeping: a message holding nothing the user wrote but its signature closes without a draft (below); text typed inside it counts as written. Settings' changes reach composers opened afterwards, a New Message from a recipient token in a window already open included; a window already open keeps the signatures it opened with.

**Closing, discarding and the subject check.** Drafts are kept on this Mac and autosaved, so closing never asks. Esc closes a composer that holds nothing worth keeping, keeping no draft (a reply opened by mistake goes with one key), and leaves one holding the user's work open (§6.1).

| Action | Result |
|---|---|
| ⌘W, the red light or File › Close Window, with content worth keeping | no alert: the last edit is saved synchronously, the window closes, and the draft stays in Drafts (“Edited 23:51”); no toast. ↩ on it in Drafts reopens it (§5.19) |
| The same with nothing worth keeping (no recipient, subject, attachment, typed body text or picture in the body: at most the folded original and the signature) | the window closes and no draft is kept |
| Message › Discard Draft… (composer windows; `trash`) | the alert “Discard this draft?”, composer form (§5.33: “Discard” destructive, “Keep Writing” default); confirming closes the window, removes the draft and shows “Draft discarded · Undo” in the main window, where Undo reopens the composer with the draft |
| ⌘↩, ⇧⌘↩ or Send with an empty or whitespace-only subject | the sheet alert “Send without a subject?” / “Messages without a subject are easy to miss.” / “Add Subject” (default, ↩ and Esc; focuses the Subject field) and “Send Anyway”. It asks every time; quick-reply sends never ask, because a reply's subject is never empty |
| Close while a send is starting (between ⌘↩ and the undo-send panel) | the window cannot close; the panel replaces it at once |

**Format row.** At x = 16: Bold · Italic · Underline, then after 12 pt Bulleted list · Numbered list · Quote, then after 12 pt Link, as 28 pt icon toggles 2 pt apart (symbols in §4.11, 14 pt). States: off `ink2`; hover `hover` wash, `ink`; pressed `pressed`; **on** (the style applies at the caret or across the whole selection) `accent` on `accentWash` (hover `accentWashHover`, pressed `accentWashPressed`); mixed selection shows off; focused ring. Each toggle's tooltip names its shortcut (“Bold  ⌘B”). It is a docked row, not a popover, so it never covers text and needs no motion.

**Text styles in the body** (`layout.textStyle`, shared with the reader so a reply looks the same before and after sending): links `accent`, 1 pt underline at offset 2; block quotes a 2 pt `rule` leading bar and 12 pt indent, text `ink2` (the composer's 3 / 16 quote of today becomes 2 / 12); lists indent 24 pt per level with the marker (“•”, or tabular numerals with a period) in `ink2` and 6 pt before the text; paragraphs have no extra spacing (what you type is what is sent).

**Images in the body (Q3.3).** A picture pasted (⌘V, Edit › Paste) or dropped on the text goes into the message where the caret is, or where it is dropped: in the text, not on the strip, as recipients will see it. It is sent as a part of the message that the text points at (`cid:`), the path a forwarded message's own pictures already take: on Gmail a `multipart/related` part beside the HTML, on Microsoft an inline attachment with a content id. Text is still pasted plain, however it comes.

| Pasted or dropped on the text | What happens |
|---|---|
| A picture without a file: a screenshot copied to the clipboard, Copy Image in a browser, a picture dragged from a web page | it goes in, at the caret or where it was dropped |
| Files that are all pictures (copied in the Finder, or dragged from it onto the text) | each goes in, in order, named as its file is |
| Files of which one is not a picture, and any files dropped outside the text (the field rows, the folded original, the strip) | they attach (§5.22), with the “Drop to attach” outline while they hover; nothing goes into the text |
| A picture file the Mac cannot read | it attaches instead |
| Text with a picture of itself (a word processor's or a spreadsheet's copy) | the text, plain |
| A browser's picture with its address as text (Copy Image, or a picture dragged from a page, which offer the address as a URL too), or a picture copied in SuperSparrow's own reader | the picture, named from a web address (a data:, blob: or reader address names none: “image.png”) |
| A spreadsheet cell or a paragraph holding one link, with a picture of itself and no URL | the link, plain |
| A selection of the body copied or cut in a composer | its pictures, as pictures of their own, and its text, plain |

**Look.** At its size on screen (its pixels over its resolution, so a Retina screenshot shows at the size it had), scaled down, never up, to the width the text has (less a list item's or a quote's indent), its shape kept, sitting on the line's baseline; that line grows to hold it, and every other line keeps its 21 pt. No frame, no handles, no resizing and no editing of the picture (`allowsImageEditing` off): it is typed over, deleted, cut, copied, moved and undone as one character. A selected picture is washed with the text's selection colour at 0.45 (`layout.composer.pictureSelectedWash`), because the selection is painted behind the text, where the picture would hide it. VoiceOver reads it as an image by its file name (“terrace.png”; a pasted one is “image.png”). Undo takes a paste or a drop out as one step (Edit › Undo Paste, Undo Drop, Undo Insert Picture).

**Preparing.** A picture goes into the text at once, at its size, read from its file's header; its bytes are read, converted where they must be (below) and decoded for the screen off the main thread, one picture at a time in the order they came, so a HEIC converted, a camera raw decoded or ten photos dropped together never stall the window. Until a picture is in, its place is a skeleton of its size in `fill`, without motion; it can be typed around, moved and deleted like any picture. Send waits for every picture still being prepared (the button shows it is sending), so a picture pasted just before ⌘↩ goes with the message; closing the window or quitting waits for it too, so the kept draft has it. A picture whose bytes turn out not to read after all leaves the text and its file is attached instead, as a picture file the Mac cannot read is.

**What is sent.** PNG, JPEG and GIF go as they came (a GIF keeps its frames; the composer shows the first). A photo in a format many mail apps cannot show (HEIC, HEIF, AVIF, WebP, JPEG XL, camera raw) becomes a JPEG; anything else (the TIFF a copied picture often arrives as, BMP, SVG) becomes a PNG, which loses nothing. A photo that records where it was taken (an EXIF GPS block) is sent without it: a converted one is written without it, and a kept PNG or JPEG has its metadata written again without it, its pixels untouched. Its name is its file's, the extension changed with the format (IMG_0412.HEIC goes as IMG_0412.jpg); a picture without a file is “image.png”, or takes the name in its address. The HTML gives it its size on screen as `width` and `height`, scaled down, never up, to 600 px (the width mail is laid out to; a 4,032 × 3,024 photo is given 600 × 450), for clients that ignore styles, and `max-width: 100%`, so it fits a phone; the bytes sent stay whole. The plain-text alternative reads “[image: terrace.png]” where it stood. A picture deleted from the body, or taken out by Undo, is not sent.

**Size.** As for attachments: SuperSparrow sets no limit of its own and never scales a picture down, so a picture of any size goes in, shows (decoded for the screen no larger than it needs, off the main thread) and is kept in the draft at full size. The provider decides as the message leaves, after the undo window: a message larger than the account allows (Gmail's attachment limit; on Microsoft, what the mailbox allows) fails as an attachment that is too large does. The undo-send panel says it could not send, the draft is kept on this Mac with its pictures, and Open draft reopens the composer with “Couldn't send: Gmail rejected the attachment size.”; taking a picture out, or sending a smaller one, and sending again is the remedy.

**Drafts.** A kept draft keeps its pictures: after a relaunch, Continue Editing in Drafts, an undone send or a failed one, they are where they were and are sent as they would have been. A body holding only a picture is worth keeping. The Drafts row's snippet leaves pictures out; the reader's draft sheet, which sets the draft as text, shows “[image: terrace.png]” in a picture's place, read from the draft's record without reading the picture. The Settings signature field takes no pictures (a signature is kept as the composer's HTML, with nowhere to keep one): a picture pasted there pastes nothing.

**Keys.** Format › Insert Picture… (⌥⌘I) opens the open panel, listing pictures only, as a sheet, and puts the files chosen into the text at the body's caret, as pasting them would (Attach Files…, ⇧⌘A, puts files on the strip instead); it acts from anywhere in the composer, and the body takes focus after it. Pasting (⌘V) and dropping need no key of their own. The cheat sheet (§5.32) lists ⌥⌘I in its Format section, whose seven rows leave band 2 as tall as Write's eight make it.

**Link popover (⌘K, or the Link toggle).** App-drawn because it anchors to the selection: `raised`, `e2`, radius 8, padding 12, width 320; `ruleStrong` edge in Increase Contrast. **Position:** its top 6 pt below the bottom of the selection's last line (`composer.linkPopoverOffsetY`), or its bottom 6 pt above the selection's first line when there is no room below; its leading edge at the selection's start on that line minus 12 pt, so the Link field starts under the selected text (`linkPopoverAlign`: selectionStart; with an empty selection, the caret); clamped to stay 8 pt inside the window's edges (`composer.popoverEdgeMin`). Content, 8 pt apart: a “Link” field (28 pt text field, placeholder “https://” `ink3`, focused on open) and, only when nothing is selected, a “Text” field; then a row with, when editing an existing link, ghost “Remove Link” leading, and trailing ghost “Cancel” and small primary “Add Link” (“Save” when editing). ↩ confirms, Esc cancels, Tab cycles inside. Invalid input: field error “Enter a web address or an email address.” (§5.25). In `dur.quick` fade; out `dur.quick`. Clicking an existing link in the body places the caret; ⌘K on it opens the popover in edit mode.

**Tab order.** From (when shown) → To → Cc → Bcc (each once shown) → Subject → Body → attachment chips (← → between them) → Send → Send's drop-down → Attach → Format → format toggles (when shown) → back to From. ⇧Tab reverses. In the body, Tab inserts a tab, or indents inside a list item; ⌃Tab and ⌃⇧Tab move focus out, as in every macOS text view. The Cc and Bcc buttons join the loop only with Full Keyboard Access (⇧⌘C and ⇧⌘B reveal those rows from anywhere).

| State | Look |
|---|---|
| Editing | as above |
| Field row focused (From, To, Cc, Bcc, Subject) | the **inset ring** (§4.1): 2 pt (3 pt in Increase Contrast) `focus`, from x = 78 to 16 pt before the trailing edge (6 pt before the Cc / Bcc buttons on the To row while they show), its outer edge 3 pt inside the row's top and bottom (30 pt tall in a 36 pt row, 36 pt in the Subject row, growing with wrapped token lines), radius `r.sm` (5); drawn inside the row, so it never touches the hairlines; never animated; not drawn while the window is not key. The From popup shows the same ring when focused. While a token is selected the ring moves from the row to that token (§5.21) |
| Body focused | the insertion point (`accent`) and the selection only: the one exception in §4.1; no ring |
| Prefilling | status “Loading original message…”; the folded-original chip appears when it loads |
| Dragging files over | the body shows a 2 pt dashed `focus` outline inset 8 pt, radius `r.lg`, and “Drop to attach” in `label` `accent`, centred in the outline (`accent` on `sheet`, asserted at 4.5:1); over the text, only while one of them is not a picture |
| Dragging pictures over the text | no outline: the insertion point (`accent`) shows where they will go in (Images in the body, above) |
| A picture being prepared | a skeleton of its size in `fill`, no motion; Send waits for it (Images in the body, above) |
| Sending | the window closes into the undo-send panel (§5.31); after Send and Archive the conversation the message answers is archived as it closes (§5.23) |
| Send failed | the window reopens with a multi-line danger banner (§5.38) under the field rows, inset 16 pt from the window's sides and 8 pt below the last row's hairline and above the body text: “Couldn't send: Microsoft 365 rejected the attachment size.” (the reason in plain words). No link: Send is the retry. It clears on the next send |
| Offline | status “Will send when you're back online” |
| Window not key | Send draws as secondary (§3.4) |

### 5.21 Address token and autocomplete

`layout.token`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `invalidGlyph` | 10 | `height` | 22 | `padX` | 9 | `gap` | 4 |
| `lineGrow` | 26 | `maxLines` | 3 | `rowMax` | 88 | `moreGap` | 6 |

A 22 pt pill, padding 0 9, 4 pt between tokens, `body`. Content: display name, or the address; the tooltip shows the full address.

**Growth is capped.** Tokens wrap inside the row, which grows by 26 pt per line up to 3 lines: 88 pt = 36 + 2 × 26 (`token.maxLines`, `token.rowMax`). Past that the focused row scrolls inside itself (vertical, scroller only while scrolling) and keeps the caret's line in view, so Subject and the body never move further down. When focus leaves the row it collapses to one line: the tokens that fit, then “+N more” (`body` `ink2`, 6 pt after the last visible token, `token.moreGap`), a borderless button; clicking it, or tabbing into the row, expands the row again. An invalid token is never hidden behind “+N more”: it is moved into the visible line. VoiceOver reads every recipient in either state.

| State | Fill | Text |
|---|---|---|
| Rest | `fill` | `ink` |
| Hover | `pressed` wash | `ink` |
| Selected (click, ← →; window not key) | `accentFill` | `onAccent` |
| Selected, window key | `accentFill`; the focus ring moves from the field row to this token, outside a 2 pt gap, so focus is never shown twice; it returns to the row when the caret does | `onAccent` |
| Being edited | turns back into text with the caret | |
| Invalid | `dangerWash` + 1 pt `danger` edge | `danger`, leading `exclamationmark.triangle.fill` 10 pt; VoiceOver “invalid address” |
| Disabled (sending) | `fill` | `inkDisabled` |

⌫ removes the selected token; ↩ or double-click edits it; the context menu offers Copy Address, Edit, Remove, New Message.

**Autocomplete** (app-drawn because it must track the caret; it opens and closes instantly and its highlight moves without animation): `raised` popover, `e2`, radius 8, padding 4, width ≥ 320. **Position:** anchored to the start of the text being completed (`autocomplete.anchor`: tokenStart, the x where the in-progress token begins), with its leading edge -46 pt from there (`autocomplete.offsetX` = −(pad + rowPadX + avatar + avatarGap)), so the suggested names line up with the typed letters; its top 4 pt below the bottom of the token line that holds the caret (`autocomplete.offsetY`; the line, not the row, which may be taller once it wraps); it flips above that line when there is no room below, and it is clamped 8 pt inside the window (`composer.popoverEdgeMin`). Rows: 40 pt, radius 5, padding x 8: 24 pt avatar · 10 pt · name (`body` `ink`, the typed prefix `bodyStrong`, wherever it matches) over the address (`meta`, `ink3`). At most 6 rows; ↑ ↓ move, ↩ or Tab accepts, Esc closes. Increase Contrast adds the `ruleStrong` edge.

**The highlighted row is a selection, drawn like list selection** (§4.1: the ink never fills more than a button): `selWash` with a 3 pt `selRule` margin rule flush with the row's leading edge (clipped by the row's radius), inks unchanged (name `ink`, address `ink3`, both tested on `selWash`), and a trailing “↩” keycap in the normal raised style (§5.36), 8 pt from the row's trailing edge. The rule is the state (≥ 3:1 against the wash and the popover); the wash is a scan cue. The popover only exists in a key composer, so there is no idle variant. Hover moves the highlight (no separate hover wash).

`layout.autocomplete`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `width` | 320 | `row` | 40 | `avatar` | 24 | `maxRows` | 6 |
| `radius` | 8 | `pad` | 4 | `rowRadius` | 5 | `rowPadX` | 8 |
| `avatarGap` | 10 | `keycapTrailing` | 8 | `highlightRule` | 3 | `anchor` | tokenStart |
| `offsetX` | -46 | `offsetY` | 4 |  |  |  |  |

### 5.22 Attachment strip

A 48 pt band above the composer's bottom bar (and the format row), `sheet`, top hairline, padding x 16, horizontally scrollable, shown only when there are attachments. Chips are 30 pt high, centred in the band, 8 pt apart, at most 240 pt wide (the name middle-truncates first), radius 6, inset hairline `rule`. Inside, from the leading edge: padding 8 · type glyph 14 pt `ink2` · 6 · name (`label`, `ink`) · 6 · size (`meta`, `ink3`) · 6 · remove button (16 pt `fill` disc, `xmark` 9 pt `ink3`, 24 pt hit; hover `ink`) · padding 4.

| State | Look |
|---|---|
| Rest | as above |
| Adding / uploading | size reads “3.1 of 4.8 MB”; a determinate contrail runs along the chip's bottom inside edge |
| Error | glyph `exclamationmark.triangle.fill` and name in `danger`; tooltip names the problem (“Too large for Microsoft 365: 150 MB limit”) |
| Focused | ring; ⌫ removes |

### 5.23 Send button

A primary button (§5.24) with `paperplane` 14 pt and the label “Send”: regular in the composer, small in the quick reply. The “⌘↩” keycap sits beside it, and so does its drop-down.

**What Send does** is one of two actions, the user's choice: **Send and Archive**, the default, sends the message and archives the conversation it answers; **Send** only sends. A click on Send, ⌘↩, Message › Send and the quick reply's rest glyph do the chosen one; ⇧⌘↩ and Message › Send and Archive always send and archive. The label stays “Send”, at the widths below; the tooltip says what it does now, “Send and Archive  ⌘↩” or “Send  ⌘↩” (§5.34), and VoiceOver hears the same name, “Send and Archive” or “Send”. A new message answers no conversation, so it only sends, and its Send says “Send  ⌘↩” whatever the choice. The choice is a preference kept across launches (Send and Archive on a fresh install) and is not in Settings: the drop-down is where it is made.

**The drop-down** is a menu button beside Send: in the composer a 28 pt icon button 2 pt after Send, the “⌘↩” keycap 8 pt after it; in the quick reply a 22 pt one 2 pt after Send, whose keycap leads it. Its glyph is `chevron.down` at the popup chevron's 12 pt, `ink2`, with an Icon button's states (§5.24), pressed while its menu is open; tooltip and VoiceOver name “Send Options”, role menu button. A press opens, on mouse-down as a pull-down does (Space with focus), a system `NSMenu` hung 4 pt below it (`menu.titleMenuOffsetY`, as Quire's other hung menus): “Send and Archive”, “Send”, the current choice checked and no key equivalents, since they are choices, not commands. Choosing one makes it the default at once, for every open composer and the quick reply. Choosing never sends. Below a separator the same menu offers Send Later (§5.46): its heading, its times and Pick a Time…, which do schedule the message. It is disabled while its composer is sending, and stays enabled while Send waits for a recipient.

**Archiving** happens as soon as the send is queued, when the undo window starts: the conversation the message answers (a reply's, or a forwarded message's) is archived as E would archive it, applied to the store and queued as the ordinary archive, only the messages in the Inbox; a conversation back from Later keeps its return mark for the undo. One already out of the Inbox stays as it is. A snoozed one (in Later, or a search's result) is archived already, so its snooze ends and it stays archived, as E does in Later. In the Inbox its row leaves the list and the selection moves on, as after E. No toast shows and nothing joins the window's undo history; the send's own feedback says it instead: the undo-send panel's second line starts “Archived ·” (§5.31) and the quick reply's strip reads “Archived · sending in 4 s” (§5.18). **One undo for both:** Undo in the panel or the strip, or ⌘Z while the send is its target (Edit › Undo reads “Undo Send and Archive”, §6.1), cancels the send and brings the conversation back exactly as Z after E would: the archived messages back in the Inbox, with their return mark, or the snooze back at its time; the conversation is selected again when the archive had taken it off the screen. Z alone never reaches it, since Z never cancels a send. Once the message has left, or when Undo comes too late, the archive stays; a send that fails after its window keeps its draft (§5.18, §5.31) and leaves the conversation where the archive put it.

| State | Look |
|---|---|
| Rest | `accentFill`, `onAccent` label; tooltip “Send and Archive  ⌘↩” or “Send  ⌘↩” |
| Hover / pressed | `accentFillHover` / `accentFillPressed` |
| Focused | ring outside a 2 pt gap |
| Disabled (no valid recipient) | `fill`, `inkDisabled`; tooltip “Add a recipient” or “Fix the address it-desk@contoso” (the quick reply's: “No one to reply to”) |
| Sending | spinner + “Sending…”; at rest the button is as wide as “Send” and it grows once to fit the gerund when sending starts (the window closes as soon as the message is queued) |
| Window not key | secondary look |

### 5.24 Buttons

| Variant | Fill | Label | Edge |
|---|---|---|---|
| Primary | `accentFill` | `onAccent`, the size's strong role | none |
| Secondary | `raised` | `ink`, the size's role (Medium) | 1 pt `ruleStrong` inset |
| Ghost (tertiary) | none | `ink2`, the size's role, optional leading glyph | none |
| Destructive | `dangerFill` | `onDanger`, the size's strong role | none |
| Link | none | `accent`, the size's role; underlined at rest only under Graphite and where the theme's flag says so (§3.1, §4.16) | none |
| Icon | none | glyph `ink2` | none |

`layout.button`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `small.height` | 22 | `small.padX` | 9 | `small.radius` | 5 | `small.font` | label |
| `small.fontStrong` | labelStrong | `small.glyph` | 12 | `regular.height` | 28 | `regular.padX` | 12 |
| `regular.radius` | 6 | `regular.font` | bodyMedium | `regular.fontStrong` | bodyStrong | `regular.glyph` | 14 |
| `large.height` | 36 | `large.padX` | 16 | `large.radius` | 8 | `large.font` | buttonLarge |
| `large.fontStrong` | buttonLargeStrong | `large.glyph` | 18 | `icon` | 22 / 24 / 28 | `iconRadius` | 5 / 5 / 6 |
| `minHit` | 24 | `glyphGap` | 6 | `linkPadX` | 4 |  |  |

| State | Primary | Secondary | Ghost / Icon / Link | Destructive |
|---|---|---|---|---|
| Hover | `accentFillHover` | `raised + hover` | ghost and icon: `hover` fill, `ink`. Link: **no fill**; it gains a 1 pt underline at offset 2 and stays `accent` | `dangerFillHover` |
| Pressed | `accentFillPressed` | `raised + pressed` | ghost and icon: `pressed` fill, `ink`. Link: **no fill**; underline kept, label `ink2` | `dangerFillPressed` |
| Focused | ring, 2 pt gap | ring, 1 pt gap | ring, 1 pt gap | ring, 2 pt gap |
| Disabled | `fill`, `inkDisabled` | `fill`, `inkDisabled`, no edge | `inkDisabled`, no fill | `fill`, `inkDisabled` |
| Loading | 12 pt spinner (in the label colour) replaces the glyph, the label becomes the gerund (“Sending…”), width kept | same | spinner replaces the glyph | same |
| Window not key | secondary look | unchanged | unchanged | unchanged |

Sizes: small 22 (padding 9, radius 5, `label` / `labelStrong`, glyph 12), regular 28 (12, 6, `bodyMedium` / `bodyStrong`, 14), large 36 (16, 8, `buttonLarge` / `buttonLargeStrong`, 18); icon buttons 22 / 24 / 28 pt square with radii 5 / 5 / 6 (`button.icon`, `button.iconRadius`): 22 pt in tool rows and Settings, 24 pt for the sheet header's hover actions and the cheat sheet's close button, 28 pt for window-level actions. **Link buttons never take a wash**: they sit on banners and washes (`fill`, `infoWash`, `dangerWash`, `selWash`) where a further wash pulls `accent` under 4.5:1, so they show hover and press in the underline and the label colour instead (pairs in §7). Labels are vertically centred on the role's line height. Every button's hit rect is at least 24 × 24. One primary per window or sheet. Destructive buttons are never the default button.

### 5.25 Text field

28 pt (24 in Settings rows), radius 6, `sheet`, 1 pt `ruleStrong` inset edge, padding 0 8, `body`; placeholder `ink3`; caret `accent`. OAuth IDs and secrets use `mono`. Labels sit beside the field, right-aligned, in Settings forms. AppKit draws it as an `NSTextField` with `isBezeled = false` inside a layer-backed container that paints face, edge and ring; SwiftUI as `QuireFieldStyle` (§8.3). Both draw the Quire ring, never the system one.

| State | Look |
|---|---|
| Hover | edge `ink3` |
| Focused | edge kept; ring outside a 1 pt gap |
| Filled | as rest |
| Error | 1.5 pt `danger` edge; help line 5 pt below in `meta` `danger` with `exclamationmark.triangle.fill`: “That doesn't look like a Google client ID.” |
| Disabled | `fill`, no edge, `inkDisabled` |
| Secure | bullets with 2 pt tracking; a reveal button only on hover (a small icon button, `eye`, `eye.slash` while revealed, centred in the field's height at its trailing edge); while the secret shows, the button stays until it is hidden again |

### 5.26 Checkbox, radio and toggle

| Control | Metric | Off | On | Mixed |
|---|---|---|---|---|
| Checkbox | 14 pt, radius 3 | `sheet` + `ruleStrong` edge | `accentFill` + `checkmark` 10 pt `onAccent` | `accentFill` + 8 / 2 pt bar |
| Radio | 14 pt circle | `sheet` + `ruleStrong` edge | `accentFill` + 6 pt `onAccent` dot | — |
| Toggle | 30 × 18 track, 14 pt knob, 2 pt inset | track `fill` + `ruleStrong` edge, knob leading | track `accentFill`, knob trailing | — |

**Knob.** Face `knob`; a 1 pt `ruleStrong` edge in both states; a static contact shadow, the only control shadow: offset (0, 1), blur 2, colour `#1D1B1833` Light, `#00000066` Dark, `#1D1B184D` Light IC, `#00000080` Dark IC (`layout.toggle.knobShadow`). The knob's face is nearly the track's colour in light modes (white on `sheet + fill`); its **edge** is what shows where it sits, and that edge is asserted at ≥ 3:1 against the off track on a group (`sheet + fill`) and on the desk (`canvas + fill`), in all four modes (§7). Those pairs hold in every state because **neither the track nor the knob ever takes a wash**: a pressed wash on the off track would drop the edge to 2.6–2.9:1, and a wash on the knob face does nothing visible in dark modes, where washes are light ink on a light knob. So the press is a shape: the knob stretches from 14 to 18 pt wide (`toggle.knobPressedWidth`) toward the track's centre, its edge, face and height unchanged, as native switches do; hover changes nothing. On the `accentFill` track the face itself carries ≥ 3:1 in every state. The knob travels in `dur.quick` `ease.glide` (Reduce Motion: instant).

| State | Checkbox / radio | Toggle |
|---|---|---|
| Rest | as above | as above |
| Hover | off: face `sheet + hover`; on: `accentFillHover` | no change (as native switches) |
| Pressed | off: face `sheet + pressed`; on: `controlOnPressed` (darker than `accentFill` in light modes, lighter in dark modes; ≥ 3:1 on `sheet` and `canvas`, checkmark ≥ 3:1 on it) | the knob stretches to 18 pt toward the centre (instant on mouse-down, back in `dur.quick` on release, or as it travels if the press toggles it); track and knob colours do not change |
| Focused | ring outside the box, 1 pt gap off, 2 pt on | ring outside the track, same gaps |
| Disabled | 0.45 opacity on the control, label `inkDisabled` | same |
| Window not key | unchanged (on fills stay in the ink, §3.4) | unchanged |

Labels are `body` `ink`, 8 pt from the control, and part of the hit area. Toggles apply at once; checkboxes are for options in a form; radios for one of a few (List density). These are Quire-drawn everywhere, Settings included: AppKit custom `NSButton` cells; SwiftUI `QuireToggleStyle`, `QuireCheckboxStyle` and `QuireRadioGroup` (§8.3).

### 5.27 Popup button

24 pt, radius 6, `raised`, 1 pt `ruleStrong` inset, padding 0 6 0 9, `body` `ink`, trailing `chevron.up.chevron.down` 12 pt `ink2`. Borderless variant (composer From): no fill or edge until hover. States: hover (`raised + hover`), pressed (menu opens; face `raised + pressed`), focused (ring outside a 1 pt gap), disabled (`fill`, `inkDisabled`, no edge). **An account dot or swatch in the label** (the From popup's 7 pt dot, the Settings Colour popup's 14 pt swatch) sits on a 2 pt `raised` halo (`popup.inkHalo`), a disc drawn under the ink before the face's wash is clipped around it: at rest the halo is invisible on the `raised` face; hovered or pressed, the wash stops at the halo, so the ink always meets `raised`, its asserted surface (§4.2). (On `raised + pressed` Persimmon, Indigo, Umber, Azure and Mulberry would fall to 2.85–2.87:1 in Dark.) In the open menu the swatches are decorative, because each item's title names the ink, and they sit on the system highlight untested. The menu is a system `NSMenu` with a checkmark on the current value. In SwiftUI this is a `Menu` whose label is drawn by `QuirePopupLabel` (§8.3); the menu stays the system's.

### 5.28 Badges and tags

`layout.badge`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `autoInitialsAt` | 7 | `height` | 16 | `minWidth` | 16 | `padX` | 5 |
| `rowMinWidth` | 18 | `dot` | 8 | `attention` | 16 | `attentionGlyph` | 9 |
| `cutout` | 2 | `cap` | 99 |  |  |  |  |

| Badge | Metric | Colours |
|---|---|---|
| Unread count (rail) | 16 pt pill, min 16, padding 0 5, `badge` role, capped at “99+”; a 2 pt cut-out ring in the surface colour where it overlaps a tile | `accentFill` / `onAccent` |
| Message count (rows) | 16 pt, min 18; exact numbers | `fill` / `ink2` (on any row fill, including both selection washes) |
| Dot | 8 pt circle | `accent` |
| Attention | 16 pt circle, `exclamationmark` 9 pt `.semibold`, centred | `dangerFill` / `onDanger` |
| Tag | 16 pt, padding 0 5, radius 3, 1 pt `ruleStrong` inset, `tag` role (SF Pro 11 Medium, sentence case) | text `ink2`: “Gmail”, “Microsoft 365” (Settings account rows), “Back” (Inbox rows back from Later, §5.7) |
| Title menu counts | system `NSMenuItemBadge(string:)` in the unread words below, numerals only (§5.4) | system |
| Dock | system red badge (`NSDockTile.badgeLabel`) with All Inboxes' unread count in the unread words below | system |

Badges never animate when counts change.

**One count, one set of words.** Every unread count goes through one formatter (`QuireBadge.unreadText`): the rail's Inbox, All Inboxes and account tiles, the title menu's items and the Dock, so the same count can never read two ways. Up to 99 it is the number in the locale's numerals; above, “99+” (1,234 unread reads “99+” in the Dock as on All Inboxes); at zero nothing shows, and the Dock badge is cleared rather than reading “0”. VoiceOver hears the real number (“1,234 unread”), never the cap. Message counts on rows are not unread counts and stay exact.

**The Dock badge** counts All Inboxes whatever the window is narrowed to, so it always matches the All Inboxes tile. It is not a notification: Settings' New mail switch leaves it. macOS draws it only while badges are allowed for SuperSparrow in System Settings › Notifications (the app asks once, as the first account or the demo arrives, for alerts, sounds and badges together); with badges turned off there, or notifications denied, the Dock shows none and the app never paints a count into its icon instead, which would overrule the user. The rail and the title menu still carry every count, and the badge returns as soon as badges are allowed again. When the demo and the real mailbox swap windows (§5.43), the Dock shows the new window's count from its first count on; the old window going away never clears it.

### 5.29 Avatar

`layout.avatar`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `sizes` | 24 / 30 / 36 | `monogramRatio` | 0.42 |  |  |  |  |

| Diameter | Use | Initials, New York (0.42 × d, min 10) | Initials, SF Pro (`monogramSans`, 0.39 × d, min 10) |
|---|---|---|---|
| 24 | collapsed stack rows, autocomplete | 10 pt | 10 pt |
| 30 | list rows (inside the 38 pt ring box) | 12.5 pt | 11.5 pt |
| 36 | message header | 15 pt | 14 pt |

Face = tint (§4.3); initials New York Semibold, or SF Pro Semibold (`monogramSans`) under the SF Pro font (§4.4), at the sizes above. **Account faces are not avatars:** the rail tile, the Settings account row and the quick-reply face show the account's domain monogram on the account face wash, at 14 / 12 pt on a 30 pt face and 11 / 10 pt on a 24 pt face (one / two letters), always with the account ring; under the SF Pro font they are set in `monogramSans` at those sizes × 0.39 / 0.42, rounded to the half point and never below 10 pt, so the letters keep their optical size. Three sizes only; there is no contact popover in v1, and About is the system panel with the app icon. **Account ring**: 2 pt gap in the surface colour + 2 pt ring in the account ink, outside the face, unified views only. A group conversation shows its most recent sender. Avatars are not interactive in rows; in the reader, hover shows the address tooltip.

### 5.30 Toast

`layout.toast`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `glyph` | 14 | `rise` | 8 | `height` | 34 | `radius` | 8 |
| `padLeft` | 14 | `padRight` | 6 | `padRightNoAction` | 14 | `gap` | 10 |
| `divider` | 16 | `action` | 26 | `actionRadius` | 5 | `actionPadX` | 8 |
| `actionKeycapGap` | 6 | `aboveSyncLine` | 16 | `sideMargin` | 16 |  |  |

| Part | Spec |
|---|---|
| Slip | 34 pt, radius 8, `slip`, `slipEdge`, `e2`; padding 0 6 0 14 with an action, 0 14 0 14 without; gap 10 |
| Content | the action's symbol 14 pt `onSlip2` · message (`bodyMedium`, `onSlip`): “Archived”, “Moved to Trash”, “Marked as spam”, “Unstarred”, “Marked 3 as unread”, “Archived 3 conversations”, “Muted” (`bell.slash`, §5.51), “Blocked deals@shop.example” (`hand.raised`, §5.52), “Snoozed until Tue 09:00”, or “Until 20 May 2027 09:00” where that would be cut off (`clock`, §5.45) |
| Divider | 1 × 16, `onSlipEdge`; only when there is an action |
| Action | “Undo” (`bodyStrong`, `onSlip`), 6 pt, keycap “Z” (18 pt, `onSlipEdge` outline; legend `onSlip2` at rest, `onSlip` while the action is hovered or pressed); 26 pt high, padding x 8 (`layout.toast.actionPadX`, `actionKeycapGap`), radius `r.sm` (5), no fill or outline at rest (the divider before it marks it as a separate control), 24 pt hit |
| Contrail | 2 pt along the bottom edge in `onSlip`, draining over the toast's life (5000 ms); it freezes while the pointer rests on the toast; only on toasts with an action |
| Placement | bottom centre of the list pane, 16 pt above the sync line, max width = list width − 2 × 16 (the message truncates); for a step taken in a reader window, bottom centre of its reader, 16 pt above the quick reply (§5.49) |

**Variants.**

| Variant | Glyph | Message | Action | Life |
|---|---|---|---|---|
| Undoable action | the action's symbol | past tense (“Archived”) | Undo + Z | 5000 ms, contrail |
| Undo confirmation | `arrow.uturn.backward` | “Undid Archive”, “Undid Move to Trash”, “Undid Mark as Spam”, “Undid Mark as Unread” (the command's menu name, §4.13); after an unsubscribe's request, “Undid Archive · Unsubscribe stays sent” | none: no divider, padding right 14 | 2000 ms, no contrail |
| Error | `exclamationmark.triangle.fill` `onSlip2` | “Couldn't archive. Restored.”, “Couldn't send your reply” | optional “Details” / “Open draft”; never Undo | 5000 ms, contrail when it has an action |
| Unsubscribe (§5.14) | `archivebox` | “Unsubscribe sent · Archived” (a one-click or mailto request), “Opened in browser · Archived” (a page in the browser) | Undo + Z: brings the conversation back; the request stays sent, and the undo's confirmation says so (“Undid Archive · Unsubscribe stays sent”; “Undid Archive” after a page). In Later, or on a snoozed search result, it ends the snooze rather than archiving, and Undo puts the snooze back. It never coalesces: an archive within 1000 ms, E in Later included, gets its own toast, so the request's words are never replaced. Both, and the confirmation, fit the default list (364 pt) whole, so the archive is never the part cut off | 5000 ms, contrail |
| Unsubscribe, nothing archived (the conversation was already out of the Inbox, and not snoozed) | `paperplane` for a request, `link` for a page | “Unsubscribe sent”, “Opened in browser” | none | 2000 ms, no contrail |
| Saved (§5.17; a notice: done, nothing to undo) | `arrow.down.circle` | “Saved to Downloads” (one file), “Saved 3 attachments to Downloads”, “Saved 2 of 3 attachments to Downloads” when a file could not be fetched (its chip says so); where the list would cut the words off beside the action, the longest that fits of “Saved 3 to Downloads”, or “Saved 2 of 3 to Downloads” then “Saved 2 of 3” (in the default list only the shorter forms fit beside “Show in Finder”), so the count is never what is cut off | “Show in Finder”: the saved files selected in the Finder; never Undo, no keycap | 5000 ms, contrail |
| Not saved (§5.17) | `exclamationmark.triangle.fill` `onSlip2` | “Couldn't save to Downloads”: a file arrived but could not be written there (a file that could not be fetched says so on its chip, with no toast) | none | 5000 ms, no contrail |
| Time set aside (§5.54: B, a row dropped on a day or the week) | `calendar.badge.plus` | “Blocked 15:00 - 15:30” (today), “Blocked Fri 10:00 - 10:30” (within the next six days), “Blocked 26 Nov 13:30 - 14:00” (later): the day as a row's time names it (§4.13), so the longest fits the default list beside its action whole | Undo + Z: the block goes (“Undid Block Time”). Each block is its own step and toast: two never coalesce, since each names its own time | 5000 ms, contrail |
| Time removed (§5.54: an event's Remove) | `calendar.badge.plus` | “Removed 15:00 - 15:30”, with the day as above | Undo + Z: the block comes back where it was (“Undid Remove Block”) | 5000 ms, contrail |
| Calendar notice (§5.54) | `calendar` | “Answer the invitation to put it in your calendar” (B on an invitation), “No free half hour on Sat 21 Nov” (a row dropped on a full day cell) | none | 2000 ms, no contrail |

Behaviour: in `dur.standard` (rise 8 pt + fade, `ease.settle`); out `dur.quick` (`ease.leave`). One toast at a time, across every window: a new toast replaces the old one instantly, without stacking, wherever the old one was, and several actions within 1000 ms in the same window coalesce into one (“Archived 3 conversations”). Z (or ⌘Z, by the precedence in §6.1) undoes the latest undoable action from anywhere in the main window or a reader window while its toast is visible and for 10000 ms after; ⌘Z goes on past that, back through the last 50 steps, one per press, however old (§6.1). The confirmation toast then replaces it, in the window where the action was taken (§5.49), or in the main window when that window has closed since. Esc dismisses (§6.1). VoiceOver announces “Archived. Press Z to undo.”, “Undid Archive.” and “Saved 3 attachments to Downloads. Show in Finder.” Reduce Motion: fades only; the contrail steps once per second.

| State | Look |
|---|---|
| Rest | as above |
| Action hover | `slipHover` behind the action; keycap legend `onSlip` |
| Action pressed | `slipPressed` behind the action; keycap legend `onSlip` |
| Action focused | 2 pt `onSlip` ring (`border.focusRing.onSlipColor`; toasts join the Tab loop only with Full Keyboard Access) |

### 5.31 Undo-send panel

A non-activating floating `NSPanel` for **composer** sends (quick-reply sends count down in their own bar, §5.18), anchored to the main window's bottom-trailing corner (20 pt inset from the window to the panel's visual edge, above the quick reply when visible; the active screen's visible frame when the main window is hidden). Several sends stack upward 8 pt apart.

`layout.undoPanel`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `glyph` | 15 | `rise` | 12 | `width` | 280 | `height` | 52 |
| `radius` | 12 | `inset` | 20 | `stackGap` | 8 | `action` | 26 |
| `padLeft` | 16 | `glyphGap` | 12 | `titleTop` | 10 | `lineGap` | 0 |
| `actionRadius` | 5 | `actionPadX` | 8 | `actionKeycapGap` | 6 | `actionGap` | 12 |
| `padRight` | 12 | `shadowMarginTop` | 32 | `shadowMarginSide` | 48 | `shadowMarginBottom` | 68 |

**Window and visual frame.** The panel window is transparent (`isOpaque = false`, clear background, `hasShadow = false`) and larger than the slip it draws by 32 pt above, 48 pt at each side and 68 pt below, so the `e3` shadow (drawn by the slip's layers with an explicit `shadowPath`) is never clipped. Insets and stacking measure the visual frame. Clicks on the transparent margin pass through to the window below.

**Anatomy** (280 × 52, radius 12, `slip`, `slipEdge`): padding left 16 · `paperplane.fill` 15 pt `onSlip2` · 12 pt · text block (title top 10: “Sending in 4 s”, `bodyMedium`, tabular, `onSlip`; 0 pt; “Re: Contoso rollout · to Ben Carter”, `meta`, `onSlip2`, tail-truncated; after Send and Archive “Archived · Re: Contoso rollout · to Ben Carter”, the archive first so the truncation never takes it, §5.23) · 12 pt · the Undo action · padding right 12; a 2 pt contrail along the bottom edge draining linearly over the undo window (5000 ms by default; Settings offers 5000 / 10000 / 20000 ms).

**The Undo action** has the toast action's metrics exactly: 26 pt high, radius `r.sm` (5, `layout.undoPanel.actionRadius`), padding x 8, “Undo” (`bodyStrong`, `onSlip`), then 6 pt and the keycap “⌘Z” (`onSlipEdge` outline). The one difference is a resting outline: the panel has no divider, so the outline is what says “button”, and it is therefore asserted at 3:1 (`onSlipEdge` on `slip`, §7).

| Action state | Fill | Label | Keycap legend |
|---|---|---|---|
| Rest | none; 1 pt `onSlipEdge` inset outline (state-bearing, ≥ 3:1 on `slip`) | `onSlip` | `onSlip2` |
| Hover | `slipHover` | `onSlip` | `onSlip` |
| Pressed | `slipPressed` | `onSlip` | `onSlip` |
| Focused | 2 pt `onSlip` ring | `onSlip` | as rest |
| Not the ⌘Z target (a newer toast took ⌘Z, §6.1) | as rest | `onSlip` | keycap hidden; the button still works by click |

| Panel state | Look |
|---|---|
| Counting | as above; hover does not pause (the send time is a promise) |
| Undo | the panel closes at once and the composer reopens with the draft; after Send and Archive the conversation is back in the Inbox first (§5.23) |
| Sending | 16 pt `onSlip2` spinner in the glyph's place + “Sending…”, no action |
| Sent | `checkmark` + “Sent” for 1500 ms, then fades (`dur.quick`) |
| Undo too late | `checkmark` + “Already sent” / “Undo came after the message left.” for 3000 ms |
| Failed | `exclamationmark.triangle.fill` + “Couldn't send” / “Your draft is kept on this Mac” + “Open draft” (same action styling, sentence case: slip content, §4.13); the message leaves the Outbox for Drafts once that draft is on disk (§5.53), and Open draft continues that draft. A panel gone before the outcome (Undo too late) leaves a later failure to the main window (§5.53) |

In: `dur.slow` (rise 12 pt + fade, `ease.settle`). Panels above a closing one drop into place instantly. Reduce Motion: no rise; the contrail steps once per second next to the numeric seconds.

### 5.32 g-sequence HUD and keyboard cheat sheet

**Arming.** G arms the sequence for 2000 ms from its key-down (`motion.duration.gSequenceWindow`; today's `KeyboardRouter.sequenceTimeout` of 1.5 s becomes 2 s, so the HUD, which appears at 500 ms, stays readable for 1.5 s). Within the window, I, S, T, D, # or A completes the sequence, L while the Later tile shows and O while the Outbox tile does (otherwise each is a key the HUD does not list); any other key disarms it and is consumed (it does nothing), and so does Esc. When the window ends the sequence disarms silently. The HUD never outlives the sequence: it shows only while the sequence is armed.

**HUD.** When no second key arrives within 500 ms of G, a slip fades in (`dur.quick`) at the bottom centre of the list pane, where the toast sits; it replaces a visible toast, which does not come back. 220 pt wide, radius 12, padding 12, `slip`, `slipEdge`, `e2`.

| Part | Spec |
|---|---|
| Header | 28 pt row: keycap “G” (18 pt, on-slip style) + 8 pt + “Go to…” (`bodyStrong`, `onSlip`) |
| Rows | 6 pt below the header; rows of 22 pt: keycap (18 pt) + 8 pt + view name (`snippet`, `onSlip2`) for I, S, T, D, #, A, with L after I while the Later tile shows and O after D while the Outbox tile shows (§5.2) |
| Size | height = 12 + 28 + 6 + 6 × 22 + 12 = 190; 212 with Later's row or the Outbox's, 234 with both |

The second key, any other key, Esc or the end of the 2000 ms window dismisses it (fade out `dur.quick`) together with the sequence. Typing “G I” quickly never shows it. It is not focusable.

**Cheat sheet** (? or ⌘/; Help › Keyboard Shortcuts) is an **in-window overlay**, not an `NSWindow` sheet: a layer-backed view above the split view of the main window.

| Part | Spec |
|---|---|
| Scrim | `scrim` over the whole window content below the title-bar zone's controls (the traffic lights stay usable); fades in `dur.quick` |
| Panel | 816 pt wide (= 2 × 24 + 3 × 240 + 2 × 24; it fits the 960 pt minimum window with 72 pt to spare on each side), centred horizontally, top at y = 92 (under the horizon), at least 24 pt from the window bottom; `raised`, radius 12, `e3`, padding 24; `ruleStrong` edge in Increase Contrast. Its full height is 736 pt (24 + 28 + 16 + band 1 (22 + 10 × 28, the rows of Move, Act and Go each) + 20 + band 2 (22 + 9 × 28) + 20 + the search line (28) + 24), so it shows whole in a window at least 92 + 736 + 24 = 852 pt high; in a shorter one, the default 800 pt window among them since 1.9's calendar rows (52 pt short there), and the 600 pt minimum, the panel ends 24 pt above the window's bottom and the bands and the search line scroll inside it under its fixed title row, as they always did in short windows |
| Title row | 28 pt: “Keyboard Shortcuts” (`title`) and a close button (24 pt icon button, `xmark`, at 16 pt from the top-trailing corner) |
| Sections | 16 pt below the title: 2 bands of 3 columns, each 240 pt, 24 pt apart: **Move · Act · Go** in the first band, **Write · Format · View** in the second, 20 pt between bands; each section opens with a 22 pt `runningHead` `ink3` title |
| Search line | 20 pt below band 2, one 28 pt row: the title (`runningHead` `ink3`) in the 96 pt key column, then the search operators as typed (`snippet`, `ink`, plain text, not keycaps: they are typed, not pressed), 8 pt apart; they take 652 of the 672 pt after the key column |
| Rows | 28 pt: large keycaps (24 pt, 4 pt apart) in a 96 pt key column, then the label (`snippet`, `ink`, sentence case, §4.13; it tail-truncates in the remaining 144 pt, which every label below fits); sequences as “G then I” (“then” in `meta` `ink3`, 6 pt either side); ranges as “⌘0 … ⌘9” |

**Content**, in this order. It is the whole single-key and command vocabulary of §6 and the menus, so nothing is learnable only from a menu (the sender rules alone have no key, §5.52, and so no row); the overlay is generated from this table (`cheatSheetContent` in `tokens.json`), and the specimen draws it from the same data.

| Band | Column | Section | # | Keycaps | Label |
|---|---|---|---|---|---|
| 1 | 1 | Move | 1 | J  K | Next · previous |
| 1 | 1 | Move | 2 | ⇧J  ⇧K | Extend the selection |
| 1 | 1 | Move | 3 | →  esc | Open · back to the list |
| 1 | 1 | Move | 4 | ↩ | Open in a new window |
| 1 | 1 | Move | 5 | N  P | Next · previous message |
| 1 | 1 | Move | 6 | space | Quick Look attachments |
| 1 | 1 | Move | 7 | ⇧⌘D | Download attachments |
| 1 | 1 | Move | 8 | / | Search |
| 1 | 1 | Move | 9 | ↩ | In search: ask the server |
| 1 | 2 | Act | 1 | E  ⇧I | Archive · move to Inbox |
| 1 | 2 | Act | 2 | L | Snooze until later |
| 1 | 2 | Act | 3 | #  ! | Move to Trash · spam |
| 1 | 2 | Act | 4 | S | Star · unstar |
| 1 | 2 | Act | 5 | U | Mark as unread · read |
| 1 | 2 | Act | 6 | M | Mute · unmute |
| 1 | 2 | Act | 7 | ⇧⌘U | Unsubscribe |
| 1 | 2 | Act | 8 | ⌘P | Print the conversation |
| 1 | 2 | Act | 9 | B | Block time for this mail |
| 1 | 2 | Act | 10 | Z | Undo |
| 1 | 3 | Go | 1 | G  then  I | Inbox |
| 1 | 3 | Go | 2 | G  then  L | Later |
| 1 | 3 | Go | 3 | G  then  S | Starred |
| 1 | 3 | Go | 4 | G  then  T | Sent |
| 1 | 3 | Go | 5 | G  then  D | Drafts |
| 1 | 3 | Go | 6 | G  then  O | Outbox |
| 1 | 3 | Go | 7 | G  then  # | Trash |
| 1 | 3 | Go | 8 | G  then  A | All Mail |
| 1 | 3 | Go | 9 | ⌘0  …  ⌘9 | All Inboxes · one account |
| 1 | 3 | Go | 10 | [  ]  T | Day before · after · today |
| 2 | 1 | Write | 1 | C | New message |
| 2 | 1 | Write | 2 | R  A | Reply · reply all |
| 2 | 1 | Write | 3 | F | Forward |
| 2 | 1 | Write | 4 | ⇧⌘R | Open in composer |
| 2 | 1 | Write | 5 | ⌘↩ | Send |
| 2 | 1 | Write | 6 | ⇧⌘↩ | Send and archive |
| 2 | 1 | Write | 7 | ⇧⌘L | Send later |
| 2 | 1 | Write | 8 | ⇧⌘A | Attach files |
| 2 | 2 | Format | 1 | ⇧⌘T | Format row |
| 2 | 2 | Format | 2 | ⌘B  ⌘I  ⌘U | Bold · italic · underline |
| 2 | 2 | Format | 3 | ⇧⌘8  ⇧⌘7 | Bulleted · numbered list |
| 2 | 2 | Format | 4 | ⌘' | Quote |
| 2 | 2 | Format | 5 | ⌘K | Add link |
| 2 | 2 | Format | 6 | ⌥⌘I | Insert picture |
| 2 | 2 | Format | 7 | ⇧⌘C  ⇧⌘B | Cc · Bcc field |
| 2 | 3 | View | 1 | ⇧⌘I  ⇧⌘O | Images · original colors |
| 2 | 3 | View | 2 | . | Show · hide quoted text |
| 2 | 3 | View | 3 | ⌥⌘F | Find in conversation |
| 2 | 3 | View | 4 | ⌘G  ⇧⌘G | Next · previous match |
| 2 | 3 | View | 5 | ⌘+  ⌘− | Text bigger · smaller |
| 2 | 3 | View | 6 | ⌥⌘C  ⌃⌘S | Compact rows · the rail |
| 2 | 3 | View | 7 | D  W | Day column · week |
| 2 | 3 | View | 8 | ⇧⌘N | Check for new mail |
| 2 | 3 | View | 9 | ? | This sheet |

Alternates that duplicate a single key (⌘F for /, ⌘N for C, ⌘O for ↩, ⌘Z for Z, ← for esc, ⌘/ for ?, ⌘= for ⌘+) are left out to keep one key per action; menus and tooltips name them. → is no alternate: it opens the conversation in the main window's reader, where ↩ opens it in a window of its own (§5.49). Keys that undo or mirror each other share a row, as J K and N P do: → esc, E ⇧I (Archive and its inverse), # ! (the two ways out to a provider's folder), ⇧⌘I ⇧⌘O and ⌥⌘C ⌃⌘S; and ⌘0 … ⌘9, All Inboxes and then each account, one range since the Outbox's G O joined Go (§5.53). Day and week (§5.54) adds three rows and no more, keys that mirror each other again sharing one: B in Act, with the other things done to the selected conversation; [ ] T in Go, since they go to a day (or a week); D W in View, beside the rail's toggle. Band 1 now holds 10 rows and band 2 9, with every key on the sheet, 736 pt in all, which no longer fits the default window whole: it scrolls there under its title row (above), as merging more rows would only hide what the keys do. Every label fits its 144 pt.

**Search line**, under the bands (`cheatSheetSearch` in `tokens.json`): the operators §5.6 describes. `in:inbox`, `in:drafts` and `in:all` work too and are left off the line, which they would push past the panel; §5.6 lists them.

| Title | Terms, in order |
|---|---|
| Search | `from:` `to:` `subject:` `is:unread` `is:read` `is:starred` `has:attachment` `before:` `after:` `in:sent` `in:trash` `"phrase"` `-word` |

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
| Later: Pick a Date… (§5.45) | When should this come back? (several: “When should these 3 come back?”) | It returns to the Inbox at this time, marked unread. (several: “They return…”) Below it, the accessory: the system's graphical calendar and a time field | Snooze (disabled while the time is not ahead) · Cancel |
| Send Later: Pick a Time… (§5.46) | When should this send? | It sends at this time while SuperSparrow is open. Until then it waits in Drafts. Below it, Later's accessory | Schedule (disabled while the time is not ahead) · Cancel |
| Launch: Send Later times missed while the app was closed (§5.46) | A scheduled message wasn't sent (several: “3 scheduled messages weren't sent”) | “Re: Contoso rollout” to Ben Carter was due to send at Mon 09:00, while SuperSparrow was closed. Send it now, or keep it in Drafts. (several: “They were due to send while SuperSparrow was closed. Send them now, or keep them in Drafts.”) | Keep in Drafts (↩ and Esc) · Send Now |

Closing a composer never asks (its draft is kept, §5.20), and a rejected attachment drop is a composer status, not an alert. **Unreadable OAuth settings** (today's “Your OAuth settings could not be read” alert) is not an alert either: the add or reconnect stops, Settings › OAuth opens, and a danger banner at the top of the tab reads “Couldn't read the OAuth settings.” + the reason + “Correct the fields below and click Save.” (§5.40, Notices); it stays until a save succeeds. Today's generic “OK” error alerts (`AppDelegate.showError`) map onto the rows above; no other error alert remains.

Sign-in failures from the main window use this alert (§5.44). Later's Pick a Date… is this alert with an accessory (§5.45), and so is Send Later's Pick a Time… (§5.46). The only app-drawn modal surface is the cheat-sheet overlay (§5.32).

### 5.34 Tooltips

System `toolTip` on every icon-only control and on truncated text; Quire defines no tooltip view and no tooltip metrics. Content: the action name, two spaces, the shortcut (“Archive  E”, “Reply All  A”, “All Inboxes  ⌘0”), in title case because it repeats the command's menu name (§4.13). Disabled controls explain why (“Nothing to undo”). A control whose action is a choice says the one in force: Send reads “Send and Archive  ⌘↩” or “Send  ⌘↩” (§5.23). The reader uses `title` attributes so WebKit shows the same system tooltip. Delay and look are the system's.

### 5.35 Menus

Main menu (system), with Quire content. Single-key shortcuts are handled by `KeyboardRouter` and shown as attributed shortcut text, so they never fire inside text fields.

- **SuperSparrow**: About SuperSparrow (the system About panel) · Settings… ⌘, · Services (the system's; SuperSparrow adds two, §5.20) · Hide · Quit.
- **File**: New Message ⌘N (also C) · Open in New Window ⌘O (the selected conversation in a reader window, §5.49) · Close Window ⌘W · Add Gmail Account… · Add Microsoft Account… · Save Attachments… · Download Attachments ⇧⌘D (the target message's, to Downloads, §5.17; enabled while it has any) · — · Print… ⌘P (the open conversation, §5.48) · in demo mode, Leave Demo… (§5.43).
- **Edit**: standard, plus Find… ⌘F (focuses search), Find in Conversation… ⌥⌘F (`text.magnifyingglass`; the find bar over the reader, §5.50), Find Next ⌘G and Find Previous ⇧⌘G (enabled while one conversation shows and there is a query to find: the bar's, or the session's last) and Search Gmail for More (§5.10, no key equivalent: ↩ in the search field runs it, and a plain ↩ on a menu item would take Return from the list, the composer and every sheet; titled by the scope: Search Outlook for More, Search All Accounts for More). It is enabled while the search field holds words whose local results are all listed (or not in yet) and the server has not been asked for them, or failed; it is disabled while any other place to type or the reader has focus, and hidden while a composer is key. Undo is titled by its target (“Undo Archive”, “Undo Send”, “Undo Send and Archive”, “Undo Typing”), following §6.1.
- **View**: Inbox · Later (while the rail shows it) · Starred · Sent · Drafts · Outbox (while the rail shows it, §5.53) · Trash · All Mail (G-sequences) · All Inboxes ⌘0 · accounts ⌘1–9 · Check for New Mail ⇧⌘N · Show/Hide Account Rail ⌃⌘S · Compact Rows ⌥⌘C · Load Images ⇧⌘I · Original Colors ⇧⌘O (checkmark when on) · Show Quoted Text . (on a message under an invitation card it shows or hides the message, §5.14) · — · Hide Day / Show Day D · Show Week / Hide Week W · Previous Day [ · Next Day ] (Previous Week, Next Week while the week shows) · Today T (This Week while the week shows; these three enabled while the day column or the week shows, §5.54) · — · Make Text Bigger ⌘+ · Make Text Smaller ⌘− (the reader's own size, §4.15; ⌘= is taken as ⌘+, as Safari takes it; disabled at Larger and at Small)
- **Message**: Reply R · Reply All A · Forward F · — · Archive E · Later… L (the Later menu at the selection, §5.45) · Move to Trash # · Mark as Spam ! (§5.47) · Move to Inbox ⇧I · Star S · Mark as Unread U · Mute M (Unmute when every selected conversation is muted, §5.51) · Block Time B (`calendar.badge.plus`; enabled while one conversation is selected, §5.54) · Undo Z · — · Unsubscribe ⇧⌘U (enabled while one conversation is open and offers it, §5.14; no symbol, since SF Symbols has none for it before macOS 26) · Always Archive Mail from This Sender · Block Sender (no key; enabled while one conversation is open with mail from someone else, the rule its sender has checked and disabled, §5.52) · — · Next Message N · Previous Message P. In a reader window the same items act on its conversation (§5.49), and the context menu on its messages is the one below, acting on that conversation.
- **Format** (composer windows only): Show Format Row ⇧⌘T · — · Bold ⌘B · Italic ⌘I · Underline ⌘U · — · Bulleted List ⇧⌘8 · Numbered List ⇧⌘7 · Quote ⌘' · — · Add Link… ⌘K · Insert Picture… ⌥⌘I (no symbol; enabled whenever the composer is not sending: it puts pictures into the body from any field, §5.20 Images in the body). In a composer window the Message menu holds Send ⌘↩ (what the Send button does, §5.23) · Send and Archive ⇧⌘↩ (always; no symbol) · Send Later… ⇧⌘L (`clock`; Send Later's times hung from the drop-down, §5.46) · Attach Files… ⇧⌘A · Add Cc Field ⇧⌘C · Add Bcc Field ⇧⌘B · — · Discard Draft… (§5.20).
- **Window**, **Help** (Keyboard Shortcuts ⌘/).

Context menu on rows and messages: Reply, Reply All, Forward, —, Archive, Later (a submenu holding the Later menu's items, §5.45), Star, Mark as Unread, Mute (§5.51), Move to Inbox (disabled where it does not apply), —, Move to Trash, Mark as Spam; every item with its symbol and shortcut, title case, disabled items visible. Then, after a separator, Unsubscribe ⇧⌘U (no symbol, as in the Message menu), present only while the open conversation offers it (§5.14), since most mail is no list's, and Always Archive Mail from This Sender and Block Sender, present only while one conversation is open with mail from someone other than the user (§5.52): on a message, its sender; on a row, the sender of the open conversation's target message (§5.14), or of its newest such mail when the user sent the target; the toast names the address it took. It acts on the selection, like the Message menu, and shares its validation (Star reads Unstar when every selected conversation is starred; Move to Inbox is disabled in the Inbox; Move to Trash in Trash; Mark as Spam in Trash and Drafts). A right-click on a row outside the selection selects that row first; heads and the list tail have no menu. On a message it opens over the sheet's or collapsed row's own chrome; inside a body, which is the sender's document, the system's text menu stays, for Copy and links. The message More menu is §5.14; the address token's menu §5.21. The person menu on a recipient or the sender in a sheet header: Copy Address, Copy Name and Address, —, New Message, Show Mail from This Person; items that do not apply are hidden (§5.14). The rail's add menu is §5.44; the demo tag's menu §5.43. The highlight is the system's (Iron Gall under Multicolor, §3.1).

### 5.36 Keyboard shortcut hints (keycaps)

`layout.kbd`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `largeHeight` | 24 | `largeFont` | 12 | `height` | 18 | `minWidth` | 18 |
| `padX` | 4 | `radius` | 3 | `largeRadius` | 5 | `inField` | 16 |

| Part | Spec |
|---|---|
| Keycap | min 18 × 18 (16 inside the search field), padding 0 4, radius 3 (`r.xs`); `raised` with a 1 pt `rule` inset and a 1 pt `rule` bottom inset (key depth); Increase Contrast uses `ruleStrong` |
| Legend | `kbd` (SF Pro 11 Medium) `ink2`; modifiers in Apple order ⌃⌥⇧⌘; Return “↩”, Delete “⌫”, Escape “esc”, Space “space” |
| Sequence | two caps with “then” in `meta` `ink3` between them (cheat sheet, empty states); adjacent caps in menus and tooltips |
| On the slip | no fill, `onSlipEdge` outline; legend `onSlip2` at rest, `onSlip` while its action is hovered or pressed |
| Large | 24 pt, radius 5 (`r.sm`), 12 pt legend (cheat sheet) |

Where keycaps appear: search “/”, the autocomplete's “↩”, quick reply “R”, “⌘↩” beside Send, the server search's “↩” while the search field has the keyboard (§5.9, §5.10), the target message's R · A · F, the quick-reply strip's “⌘Z”, toast “Z”, undo panel “⌘Z”, the Drafts “↩”, the day column's “B” on the selected mail's time (§5.54), empty states, the HUD and the cheat sheet. Keycaps never sit on accent fills, without exception: the autocomplete's “↩” sits on the `selWash` highlight in its normal raised style (§5.21), and “⌘↩” sits beside Send, not inside it.

**Narrow reader.** When the reader is narrower than 616 pt (`layout.window.readerKeycapsMin`, 680 minus two 32 pt margins), the reader's keycaps hide: the quick reply's “R” and “⌘↩”, the strip's “⌘Z”, the target message's R · A · F (its `ruleStrong` edge stays, §5.14) and the Drafts footer's “↩”. Tooltips keep naming the shortcuts. Empty-state hints on the desk keep their keycaps and wrap instead. Keycaps outside the reader (search, toast, undo panel, HUD, cheat sheet, the day column's “B”) never hide.

### 5.37 Progress

`layout.progress`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `indeterminateSegment` | 0.36 | `reducedSegment` | 0.4 | `barHeight` | 4 | `barRadius` | 2 |
| `contrail` | 2 | `contrailHead` | 4 | `contrailTail` | 32 | `spinner` | 12 / 16 / 32 |
| `spinnerStroke` | 1.5 / 2 / 3 | `spinnerArc` | 0.75 |  |  |  |  |

| Indicator | Spec | Use |
|---|---|---|
| Spinner (AppKit) | `QuireSpinnerView`, layer-drawn (not `NSProgressIndicator`, which has no 12 pt spinning size and no public tint): a `CAShapeLayer` circle path inset by half the stroke, `strokeStart` 0, `strokeEnd` 0.75 (a ¾ arc, butt caps), stroke 1.5 / 2 / 3 pt at 12 / 16 / 32 pt; a `transform.rotation.z` `CABasicAnimation` of one turn per `dur.spinnerTurn`, linear, `repeatCount = .infinity`. Colour: `ink3`; inside filled buttons the label colour (`onAccent`, `onDanger`); on slips `onSlip2`; re-resolved on appearance change. It is added 150 ms after work starts (and never if the work ends sooner), fades in over `dur.quick`, and removes its animation when hidden or off-window | buttons, sync line, search, chips, undo panel, rail tile, list footer, Settings rows |
| Spinner (reader CSS) | `.ss-spin`: the same shape, a circle with a 1.5 / 2 / 3 pt border in `currentColor` and one quarter (`border-right-color: transparent`) left open, rotating once per `dur.spinnerTurn`, linear; same delay and fade-in | message “Sending…”, image loading |
| Determinate bar | 4 pt, radius 2, track `fill`, fill `accent`; jumps forward without easing, never backwards | Settings › Accounts download status (96 pt wide, §5.40) |
| Contrail | 2 pt line in `accent` (`onSlip` on slips) whose trailing 32 pt fades to transparent, with a 4 pt head dot at the moving end. Determinate: length = progress. Indeterminate: a segment 0.36 of the width sweeping every `dur.contrailSweep` (Reduce Motion: a static segment 0.4 of the width; the text carries the state) | sync line, attachment progress, toast life, undo countdown |

Spinners appear only after 150 ms and **never in rows**; the row's only status marks are the static `ss.queued` glyph and the failed triangle.

### 5.38 Semantic banners

32 pt, radius 6, padding 0 6 0 10, gap 8, `snippet` `ink` text, glyph 14 pt in the semantic colour, optional trailing link button and optional dismiss button (`xmark` 9 pt `ink2`, 24 pt hit). Variants: neutral (`fill`, glyph `ink2`), info (`infoWash`, `info`), success (`successWash`, `success`), warning (`warningWash`, `warning`), danger (`dangerWash`, `danger`). Never more than one status banner per message.

**Multi-line.** Text that does not fit wraps instead of truncating where the words matter (Settings notices, sign-in errors): the banner grows from 32 pt with 8 pt top and bottom padding, the glyph aligns to the first line, and the link sits after the text on its last line.

### 5.39 Welcome screen

Fills the main window until the first account exists; the rail and list are hidden; window background `paper`; the traffic lights stay where the empty unified toolbar puts them (§3.2).

`layout.welcome`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `blockWidth` | 360 | `blockCenterY` | 0.45 | `mark` | 64 | `titleGap` | 8 |
| `wordmarkCap` | 24 | `taglineGap` | 6 | `actionsGap` | 28 | `buttonWidth` | 328 |
| `buttonGap` | 10 | `demoGap` | 12 | `footGap` | 20 | `footWidth` | 330 |
| `linkGap` | 10 | `bannerGap` | 16 | `spinner` | 16 |  |  |

| Part | Spec |
|---|---|
| Block | max width 360, centred horizontally; vertically its centre sits at 0.45 of the content height below the title-bar zone (`welcome.blockCenterY`: optically centred, a little high). It re-centres, instantly, whenever a banner or a state changes its height |
| Mark | `ss.paperPlane` in a 64 pt square in the brand's black and white, `#0A0A0A` on a light page and `#FFFFFF` on a dark one, like the wordmark under it, whatever the theme (§4.11); the plane spans the square's width |
| Wordmark | the drawn wordmark (`layout.brand.wordmark`, the outlines of docs/brand/source/wordmark.svg), never the name set in a font, in the mark's black or white, its cap height 24 pt, 8 pt below the mark's frame, centred on its ink. Its frame runs from the cap height to the p's descender (the letters are straight-edged and have no overshoot), the baseline on a whole point. VoiceOver reads it as an image, “SuperSparrow”; the screen itself is a group described “Welcome to SuperSparrow”, the greeting the screen no longer prints |
| Tagline | “Your mail, quietly fast.” in `aside` `ink2`, 6 pt below the wordmark's descender |
| Actions | 28 pt below: two large secondary buttons, 328 wide, 10 apart: `person.crop.circle.badge.plus` + “Add Gmail account” (trailing note “Google” in `snippet` **`ink2`**), “Add Microsoft account” (trailing note “365 · Outlook”). The note is `ink2`, not `ink3`, because it sits on `raised` and on its hover and pressed washes, where `ink3` falls to 4.24:1 in Dark (§7 tests the note on all three). Two equal choices, so neither is primary; the first has initial focus |
| Demo | ghost “Try the demo”, 12 pt below (tooltip: “Explore SuperSparrow with two made-up mailboxes. Nothing leaves this Mac.”); it opens the main window in demo mode (§5.43) |
| Footnote | 20 pt below, `meta` `ink3`, max 330 wide, with `lock`: “Your mail is stored on this Mac and travels only between this Mac and Google or Microsoft. No analytics, ever.” |
| Link | “Set up OAuth clients…”: a link button (§5.24) in `label` `accent`, centred, 10 pt below the footnote (`welcome.linkGap`); it opens Settings › OAuth |
| Banner slot | between the tagline and the actions: when a banner shows it takes the actions' place, 28 pt below the tagline, and the buttons follow 16 pt below it (`welcome.bannerGap`); full block width, multi-line (§5.38). One banner at a time, the newest winning: sign-in error, demo failed, or no OAuth client |

| State | Look |
|---|---|
| Rest | as above; the first button has initial focus |
| Hover, pressed, focused | the secondary-button states of §5.24; the trailing note stays `ink2` in every one |
| Waiting for the browser | the chosen button goes back to its **rest** face (it does not keep the pressed face) and becomes inert: a 16 pt `ink2` spinner replaces `person.crop.circle.badge.plus`, the label reads “Finish signing in in your browser…”, the trailing note hides, focus stays on it. The other provider button and the OAuth link are disabled, and the demo slot shows ghost “Cancel” in place of “Try the demo” |
| Preparing the demo (after “Try the demo”) | the ghost button becomes inert and reads “Preparing the demo…” with a 12 pt `ink2` spinner 6 pt before the label (after 150 ms, so a fast seed shows no spinner); both large buttons and the OAuth link are disabled. On success the window cross-fades to the demo inbox (`dur.slow`, §5.43) |
| Demo failed | everything re-enables and the ghost button reads “Try the demo” again; a multi-line danger banner in the banner slot: “Couldn't start the demo. The made-up mailboxes couldn't be created on this Mac.” + link “Try again” |
| Sign-in error | “Couldn't add the account” + the reason, as a multi-line danger banner in the banner slot |
| No OAuth client configured (after choosing a provider) | an info banner in the banner slot: `info.circle` + “Add your Google OAuth client in Settings › OAuth first.” + the trailing link “Open Settings” |
| Success | `dur.slow` cross-fade to the inbox with the skeleton |
 Adding accounts later, from the main window or Settings, follows §5.44 with the same copy.

### 5.40 Settings window

SwiftUI `Settings { TabView { … } }` with the **system toolbar tab style**, 560 pt wide, background `canvas`. Height fits the current tab's content, never taller than the screen's visible frame; the account group is capped (below), so the tallest tab, Accounts with a two-line notice, six visible rows, the +/− buttons and a full detail form, is 800 pt of content (20 + a 46 pt banner + 16 + 336 + 8 + 22 + 20 + 310 for six detail rows with a three-line error and the 82 pt Signature row + 22), 888 pt with the window's 88 pt title bar and toolbar (macOS 26). A shorter visible frame stops the window at its height and cuts the foot of the form, which takes all of that at once: six accounts, a notice and a three-line error. Tabs: **Accounts** (`person.crop.circle`), **OAuth** (`key`), **General** (`gearshape`), **Appearance** (`paintpalette`; `circle.lefthalf.filled` is Original colors'), appended so no tab a user knows moves. The toolbar and its tabs are system chrome: macOS draws their size, material, selection and focus (the selected tab's symbol takes the accent asset, §3.1), so Quire specifies no tab metrics and asserts no tab contrast (§7). Everything **inside** the content area is Quire-drawn with the custom SwiftUI styles of §8.3, so every edge and every focus ring there meets 3:1. Content padding 20 24 22.

`layout.settings`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `width` | 560 | `padTop` | 20 | `padX` | 24 | `padBottom` | 22 |
| `row` | 40 | `rowGap` | 12 | `accountRow` | 56 | `accountFace` | 30 |
| `accountHairlineX` | 62 | `groupRadius` | 8 | `labelColumn` | 140 | `swatch` | 14 |
| `monogramMaxLength` | 2 | `plusMinus` | 22 | `plusMinusGlyph` | 11 | `plusMinusTop` | 8 |
| `fieldHeight` | 24 | `noticeGap` | 16 | `labelGap` | 12 | `fieldWidth` | 360 |
| `captionMaxWidth` | 360 | `captionGap` | 8 | `sectionGap` | 20 | `accountFaceX` | 16 |
| `tagGap` | 6 | `statusGap` | 12 | `statusTrailing` | 16 | `statusGlyph` | 12 |
| `statusGlyphGap` | 6 | `statusButtonGap` | 8 | `statusBarWidth` | 96 | `statusBarGap` | 4 |
| `savedGap` | 8 | `groupMaxRows` | 6 | `detailTop` | 20 | `detailRow` | 40 |
| `monogramFieldWidth` | 64 | `colourPopupWidth` | 160 | `lastErrorMaxLines` | 3 | `signatureLines` | 3 |
| `signatureFieldHeight` | 66 | `mailboxSizeGap` | 12 | `sendersWidth` | 440 | `senderRow` | 40 |
| `senderRowsMax` | 8 | `senderRowX` | 12 | `senderActionGap` | 12 | `senderRemoveInset` | 9 |
| `themeTile` | 60 / 40 | `themeTileGap` | 15 | `themeRow` | 76 | `themeNameGap` | 6 |
| `themeUnderline` | 2 | `themeUnderlineGap` | 3 | `themeCaptionLines` | 2 | `themeTileSpine` | 8 |
| `themeTilePaper` | 18 | `themeTilePip` | 4 | `themeTileLine` | 1.5 | `themeTileInset` | 4 |

**Accounts.** An optional notice banner (below), then the account group (`sheet`, radius 8, hairline edge) of 56 pt rows, then the +/− buttons 8 pt below the group, then, 20 pt below the buttons (`settings.detailTop`), the detail of the selected account.

**Group capacity.** The group shows at most 6 rows (6 × 56 = 336 pt, `settings.groupMaxRows`) and scrolls beyond that, exactly like the rail's stack (§5.2): a `rule` hairline marks each clipped edge (bottom, and top once scrolled), the scroller shows only while scrolling, and ↑/↓ scroll the selected row into view instantly. The group's corner radius clips its content; the +/− buttons stay below it.

| Account row part | Spec |
|---|---|
| Face | the account's rail face (30 pt, 2 pt gap in the row's fill, 2 pt ring): the face's leading edge at x = 16 (`layout.settings.accountFaceX`), so the ring's outer edge runs from x = 12 to x = 50; vertically centred |
| Name line | from x = 62: the name in `bodyStrong` `ink`, then 6 pt and the provider tag “Gmail” / “Microsoft 365” (“Demo” in demo mode) on the same line, sharing its centre; the name truncates, the tag never does |
| Address line | `snippet` `ink2` under the name; for Sign in required it is replaced by the status words in `danger` (below) |
| Status | a trailing block, 16 pt from the group's trailing edge (`statusTrailing`), centred on the row: glyph 12 pt, 6 pt, the words in `snippet`. When the state has an action, a small secondary button takes the trailing position and the glyph and words sit 8 pt before it. The name and address block ends at least 12 pt before the status block (`statusGap`) and truncates first |
| Separators | hairlines from the text column (x = 62); hidden around the selected row |
| Selected | `selWash` + a 3 pt `selRule` margin rule flush with the group's leading edge, full row height (clipped by the group's corner radius on the first and last rows) while Settings is key; `selWashIdle` + `selRuleIdle` when it is not. The wash is a scan cue (`selWash` ≥ 1.25:1 on `sheet`); the rule is the state (≥ 3:1 on the wash and on `sheet`, both keys, §7) |
| Hover, pressed | **none.** Rows take no hover and no pressed wash: selection applies on mouse-down, as in native Mac source lists, and a wash under the account ring would need its own pairs (Jade's ring on `sheet + pressed` falls to 3.41:1 in Dark IC, below the 3.5 IC floor of §4.2). The ring therefore only ever sits on `sheet`, `selWash` and `selWashIdle`, all tested. Buttons inside a row (Reconnect, Retry, Cancel) keep their own states (§5.24) |
| Detail | the form below the +/− buttons (next table) |

**Detail form**, on the same grid as OAuth and General: labels `body` `ink`, right-aligned in the 140 pt column; controls start 12 pt after it; rows 40 pt (`settings.detailRow`), each control centred vertically in its row. It describes the selected account and is replaced by nothing (no rows) when the group is empty.

| Row | Label | Control |
|---|---|---|
| 1 | Colour | popup (§5.27), 24 pt high, 160 pt wide (`settings.colourPopupWidth`): the 14 pt swatch on its 2 pt `raised` halo, 8 pt, the ink's name (“Persimmon”); the menu lists the ten inks with swatches, a checkmark on the current one |
| 2 | Monogram | text field 64 × 24 pt (`settings.monogramFieldWidth`), max 2 characters; placeholder = the derived monogram in `ink3`, so clearing the field returns to it. No caption |
| 3 | Signature | a 3-line field: the composer's own editor (§5.20) in the text-field container (§5.25: `sheet`, radius 6, `ruleStrong` edge, `ink3` hovered, the focus ring while it edits), 360 × 66 pt (`settings.signatureFieldHeight` = 24 + (3 − 1) × 21), its top 8 pt into the row ((40 − 24) / 2, as a one-line field's), so the row is 82 pt and the label, centred in the row's first 40 pt, sits level with the first line. Text in `writing` from 8 pt in, the first line where a one-line field's text would sit ((24 − 21) / 2 pt from the top); past three lines it scrolls inside (scroller only while scrolling). Bold, italic, underline and links through the composer's shortcuts (⌘B ⌘I ⌘U, and ⌘K for its link popover, which closes, as in the composer, when focus goes anywhere else or another account is selected); lists and quotes are off (⇧⌘8, ⇧⌘7 and ⌘' do nothing there); pasting is plain, as in the composer. Empty by default, no placeholder and no caption. Saved as the HTML the composer sends (anything else dropped) when editing ends: focus leaves the field, another account is selected, another window or app comes forward, the window closes, a composer opens while Settings is in front (⌘N, a notification's Reply), or the app quits (before the store closes); never per keystroke. Emptied, the account has no signature |
| 4 | Rules | Senders… (small secondary, at the field column's leading edge): the Senders sheet, the one place sender rules are listed (§5.52) |
| 5 | Last error (only when there is one) | the error in `meta` `ink2` (“Gmail returned an unexpected response.”), wrapping in the field column (360 pt) up to 3 lines (`settings.lastErrorMaxLines`; the row grows by 14 pt per extra line), the full text in its tooltip |
| 6 | — | Remove… (small secondary, at the field column's leading edge; confirms with the destructive alert of §5.33). In demo mode it reads Leave Demo… |

**Seven accounts.** When a 7th account is added and **Show account initials in unified views** turns on by itself (§4.2), Settings says why in two places. In **Accounts**, an info banner in the notice slot: `info.circle` + “Rows now show each account's initial. With seven or more accounts, colours alone can look alike.” + the link “Change in General…” and a dismiss button; it appears once, stays (across launches) until dismissed or followed, and is not shown again. In **General**, a caption under the Rows checkbox, in the field column 8 pt below it (`meta` `ink3`): “Turned on when you added a seventh account.”, shown while the setting is still in that automatic state; once the user changes the checkbox the caption goes and the choice is kept (an eighth account does not turn it back on).

**Account status.** The same words as the sync line's tooltip (§5.11), one per account phase:

| Status | Glyph | Words (`snippet`) | Action |
|---|---|---|---|
| Up to date (idle) | `checkmark.circle.fill` `success` | “Up to date” `ink2`; tooltip “Checked 23:41” | — |
| Up to date, downloading older mail (new mail is current; the older mail downloads behind it) | `checkmark.circle.fill` `success` | “Up to date · older mail 3,412 of 8,120” `ink2` (“Up to date · older mail 3,412” while the total is unknown, “Up to date · older mail…” before the first count); while the total is known, the Downloading row's determinate bar under the words; tooltip “Checked 23:41” | — |
| Up to date, older mail paused (the provider is limiting the older-mail download) | `checkmark.circle.fill` `success` | “Up to date · older mail paused until 10:42” `ink2`, no bar; the tooltip adds the cause on its own line (“Gmail is limiting requests.”). Never Retrying: new mail still arrives | — |
| Up to date, downloading messages (the older mail is listed; the bodies the backfill still lacks arrive behind it) | `checkmark.circle.fill` `success` | “Up to date · downloading messages…” `ink2`, no bar; tooltip “Checked 23:41”. A message opened before its body arrives fetches it at once. A throttle on these downloads keeps these words, never “paused until” | — |
| Waiting to sync (added; the engine has not reached it yet) | `clock` `ink3` | “Waiting to sync” `ink3` | — |
| Downloading (a new account's first page of newest mail, before its first check; the older mail after it reads as Up to date) | 12 pt `ink3` spinner | “Downloading · 3,412 of 8,120” `ink2` (“Downloading · 3,412 messages” while the total is unknown); while the total is known, a 96 × 4 pt determinate bar (§5.37) 4 pt under the words, trailing-aligned with them | — |
| Checking (a check the user asked for) | spinner | “Checking for mail…” `ink2` | — |
| Retrying (rate limited, or unreachable while other accounts are online) | `clock` `warning` | “Retrying in 30 s” `ink2`, or “Retrying shortly” when the server gave no time; the tooltip names the cause (“Gmail is limiting requests.”, “Couldn't reach Gmail.”) | — |
| Offline | `wifi.slash` `ink2` | “Offline” `ink2` | — |
| Sign in required | `exclamationmark.triangle.fill` `danger` | “Sign in required” in `danger`, **in place of the address line**; the status block holds only the button | small secondary “Reconnect” |
| Calendar permission needed (mail is up to date; an invitation answered on this Mac waits for permission to update the calendar, §5.14) | `calendar` `ink2` | “Calendar permission needed” `ink2`; tooltip “Answer invitations: SuperSparrow needs permission to update your calendar.” The address line stays: the account still syncs. The sync line keeps Up to date and its tooltip carries the same words | small secondary “Reconnect”, which asks for the permission beside mail (§5.44) |
| Reconnecting (waiting for the browser, §5.44) | 12 pt `ink3` spinner | “Sign in required” stays in `danger` in place of the address (it is still true); the status block reads “Waiting for your browser” `ink2` | small secondary “Cancel”, in Reconnect's place |
| Error | `exclamationmark.triangle.fill` `danger` | “Couldn't sync” `danger`; the reason in plain words in the tooltip and the detail | small secondary “Retry” |
| Demo account | `info.circle` `ink3` | “Made up, nothing syncs” `ink3` | — |

Every glyph, word and bar meets its pair on `sheet`, `selWash` and `selWashIdle` (§7; `ink2` and `ink3` words through the row pairs).

The group is **not** a `List(selection:)`: SwiftUI's list selection paints an accent block with white text that cannot be restyled. It is a `VStack` of rows inside a `.focusable()` container: click selects; ↑/↓ move the selection (`onMoveCommand`); ⌫ asks to remove; Tab enters and leaves the group as one stop, drawing the focus ring around the selected row inset 2 pt; each row reports `.isSelected` to accessibility.

**+/−.** Two joined square buttons, 22 × 22 each, `raised`, 1 pt `ruleStrong` edge with a shared middle edge, outer radius `r.sm`, glyphs `plus` / `minus` 11 pt `ink2`. Hover `raised + hover`, glyph `ink`; pressed `raised + pressed`; focused ring around the focused half (each half is its own Tab stop); − disabled (`inkDisabled`, no fill change) when nothing is selected. + opens the add-account menu (§5.44) under the button; − is Remove….

| Accounts state | Look |
|---|---|
| Accounts listed | as above |
| No accounts | the group holds one 56 pt row: “No accounts yet” (`body` `ink2`) over “Add one to start syncing.” (`snippet` `ink3`), centred; − disabled; + enabled |
| Adding (waiting for the browser) | a pending row at the end of the group: 30 pt `fill` face with a dashed `ruleStrong` ring and a 16 pt `ink3` spinner, “Finish signing in in your browser…” (`body` `ink`) over “Gmail” (`snippet` `ink2`), trailing small secondary “Cancel”; + is disabled until it resolves |
| Add failed | the pending row leaves; a danger banner above the group: “Couldn't add the account” + the reason (multi-line) + link “Try again” |
| Reconnecting | the account's row shows the Reconnecting status above; + and every other Reconnect and Retry are disabled until it resolves |
| Demo mode | an info banner above the group (§5.43) |

**Notices.** Banners at the top of a tab's content, 16 pt above the first control, multi-line (§5.38): info for guidance, danger for failures. A confirmation of a button press is not a notice: it sits beside the button that caused it (OAuth “Saved”, below). The OAuth tab's incoming notice, shown when an add-account attempt found no client, is an **info** banner (`info.circle`): “To add a Gmail account, SuperSparrow needs your own Google OAuth client ID. Enter it below and click Save, then try again.” with the link “How to create one…” (opens `docs/OAUTH-SETUP.md`); it stays until Save succeeds or the tab is left. When the OAuth settings file exists but cannot be read, the tab opens with a **danger** banner instead: “Couldn't read the OAuth settings.” + the reason + “Correct the fields below and click Save.”; it stays until a save succeeds (§5.33). The seven-accounts notice (above) is the Accounts tab's only info banner besides demo mode; when both apply, demo mode's shows.

**OAuth.** One form, top to bottom (the incoming notice above it when present). Labels `body` `ink`, right-aligned in the 140 pt column; fields start 12 pt after it and fill to the content's trailing padding (360 pt at the 560 pt window: `layout.settings.fieldWidth`), 24 pt high, on 40 pt rows; section titles in `title` `ink` at the content's leading edge, 20 pt above their first row.

| Row | Label | Control | Placeholder (`ink3`) | Font |
|---|---|---|---|---|
| Section | “Google” | — | — | `title` |
| 1 | Client ID | text field | “….apps.googleusercontent.com” | `mono` |
| 2 | Client secret | secure field (§5.25: bullets, reveal button on hover) | “GOCSPX-…” | `mono` |
| Section | “Microsoft” | — | — | `title` |
| 3 | Client ID | text field | “00000000-0000-0000-0000-000000000000” | `mono` |
| 4 | Tenant | text field | “common” | `mono` |
| Caption | — | in the field column, 8 pt under the last field, max 360 pt wide, `meta` `ink3`: “Register a Desktop app client in Google Cloud Console with the Gmail API enabled, and a Mobile and desktop app in Microsoft Entra with http://localhost as its redirect URI. Leave Tenant as common to allow both work and personal Microsoft accounts.” followed by the link “How to create these…” (`meta`, `accent`; opens `docs/OAUTH-SETUP.md`) | — | — |
| Buttons | — | 20 pt under the caption: “Show File in Finder” (small secondary, at the field column's leading edge; disabled until the file exists) and, trailing at the content padding, “Save” (small primary, the default button, enabled only when a field changed) | — | — |

**“Saved”** is a status beside Save, not a banner: `checkmark.circle.fill` `success` 12 pt + “Saved” (`snippet` `ink2`), 8 pt before the Save button, from a successful save until the next edit (VoiceOver announces “Saved”). A failed save is a danger banner at the top of the tab (“Couldn't save the OAuth settings.” + the reason). Validation errors sit under their field (§5.25: “That doesn't look like a Google client ID.”).

**General** (a two-column grid: labels right-aligned in 140 pt, rows 40 pt, a hairline between groups; ten controls, eleven once the roadmap's update check lands, under its cap of twelve): List density (radio: Standard, Compact) · Rows (checkbox: Show account initials in unified views; the seven-accounts caption under it, above) · Undo send (popup: 5, 10, 20 seconds) · — · Remote images (toggle “Load by default”, caption “Off: images load only when you ask, per message.”) · Notifications (toggle “New mail”; checkbox “Show sender and subject”; while macOS keeps them from SuperSparrow, its line, below) · — · Keep mail on this Mac (below) · — · Analytics and reports (below) · At login (below) · Mail links (below). Font and Text size moved to Appearance in 1.8. General never scrolls and is never cut where Accounts is not: at its tallest (the seven-accounts caption, Notifications' line with its caption, At login's tallest line and Mail links' failure line, all at once) it stays shorter than Accounts at its tallest (760 pt of content).

**Keep mail on this Mac.** How far back messages keep their full content on this Mac: a popup, Everything (the default), 1 year, 3 months, and 12 pt after it the space the mailbox takes in plain words (“292 MB”: the mail database, less the pages it keeps free for reuse after a clean-up, and the attachment cache, decimal units as Finder counts, `meta` `ink2`; VoiceOver reads “292 MB on this Mac”). Under the row, in the field column 8 pt below it (`meta` `ink3`): “Older mail stays in the list and in search, and downloads again when you open it.” The size is measured when the tab appears, when the window reopens on it, and after each clean-up while the window is open; never on a timer, and until the first answer the row holds the popup alone, never a placeholder number. A message received before the window keeps its row, its snippet and its text for search; its full content goes, and opening it fetches it again as for mail the download has not reached yet (§5.14: the skeleton while it loads, the offline preview without a network), after which it stays until the app next starts; so does mail shown in the reader, so a clean-up never empties a conversation on screen or its attachments. Older mail the download brings in arrives already cleaned up, so the mailbox never takes its full size first. Choosing a shorter window cleans up at once, in the background, and the size follows when it is done; choosing a longer one, or Everything, removes nothing more and downloads nothing back (those messages fill in again as they are opened). Drafts, messages waiting to send and messages with an action still syncing are never touched. Attachments opened on this Mac are kept up to 1 GB, the least recently used going first.

**Notifications' line.** macOS, not the app, decides whether SuperSparrow's notifications show, and with them the Dock badge (§5.28): with notifications off for it in System Settings › Notifications (or Don't Allow answered to its prompt) macOS shows none and draws no badge, though the New mail toggle reads on and the app sets the count. So under the Notifications rows, whatever the toggle says (the badge shows with New mail off), a 40 pt row in the field column says so, in At login's approval shape: `bell.slash` `ink2` 12 pt, 6 pt, the words (`snippet` `ink2`), 8 pt, a small secondary button. macOS keeps the answer and is asked whenever the tab appears and whenever the app comes to the front while it shows; until the first answer, and while nothing stands in the way, there is no line.

| macOS's answer | Line |
|---|---|
| Allowed, with Badge application icon on; or no notification center (a bare build) | none |
| Off for SuperSparrow | “Off in System Settings”, “Open Notifications”, which opens System Settings at Notifications on SuperSparrow's page; under it the caption “No notifications and no Dock badge until they're allowed there.” |
| Allowed, with Badge application icon off | “Dock badge off in System Settings”, “Open Notifications” |
| Never asked | “Not allowed yet”, “Allow…”, which puts macOS's prompt up; the line follows its answer |

Allowed there, the line goes as the app comes back to the front. No alert, no key, no menu item.

**Analytics and reports.** Whether SuperSparrow sends a report to Sentry when it crashes, when an exception is thrown, or when the main thread stops answering for 2 s (docs/ARCHITECTURE.md, “Crash reports”), and which of its features are used, and how fast, to TelemetryDeck (“Analytics”): one toggle for both, on unless the user turns it off, the first row of the last group, so Mail links stays the last row. The toggle names the services this build sends to: “Send to Sentry and TelemetryDeck”, or “Send to Sentry” or “Send to TelemetryDeck” for a build made with only one, which the toggle then governs alone. Under it the caption (`meta` `ink3`, 8 pt below, one line) “Crashes, hangs and features used. Never your mail or addresses.” Turning it off stops both at once, the current run included, and deletes what they had queued on this Mac; turning it on starts them again without a relaunch. A build made with neither a Sentry project (no DSN) nor a TelemetryDeck app (no app ID) shows the toggle disabled, at the saved value, naming both, with the caption “Not set up in this build.” Nothing else in the app speaks of crash reports or analytics: no alert at the next launch, no badge, no menu item, no prompt. The system's own “quit unexpectedly” dialog already tells the user of a crash, and neither a report nor a signal holds anything for them to read before it goes.

**At login.** Whether SuperSparrow opens when the user logs in, so new mail notifies from then on (§5.41): a toggle “Open SuperSparrow” (VoiceOver reads “Open SuperSparrow at login”), the second row of the last group, which is SuperSparrow's place in macOS, under Analytics and reports. macOS keeps the answer (the app as a login item, `SMAppService`), not the app's settings: it is asked whenever the tab appears (the window reopening on it included) and whenever the app comes to the front while it shows, since the user can approve or remove the item in System Settings meanwhile; until the first answer the row holds no toggle, rather than one that may flip. The toggle applies at once: it moves as pressed, asks macOS once and ignores presses until macOS answers, then shows what macOS says, which wins over any error on the way. No key, no menu item: it is a setting like the rest of General.

| At login state | Look |
|---|---|
| Off, on | the toggle, off or on. Off includes a copy macOS has not met yet (it answers not found until the first register, which a press makes): the toggle stays usable |
| Needs approval (asked for and waiting for the user in System Settings › General › Login Items & Extensions, or turned off there since) | the toggle on; under it a second 40 pt row in the field column: `info.circle` `ink2` 12 pt, 6 pt, “Needs approval in System Settings” (`snippet` `ink2`), 8 pt, “Open Login Items” (small secondary), which opens System Settings at Login Items & Extensions. Approved there, the line goes as the app comes back to the front; turning the toggle off withdraws the request |
| Unavailable (a build run outside an app bundle, or macOS still cannot find this copy after a press asked it to add it, until it answers anything else) | the toggle off and disabled (§5.26); under it, in the field column 8 pt below the control and at most 360 pt wide, a caption (`meta` `ink3`): “Not available for this copy of SuperSparrow. Move it to the Applications folder and open it from there.” |
| The change failed (macOS did not end where the user asked) | the toggle where macOS says it is, enabled; under it, Mail links' error help line (below) in the same place: “Couldn't set SuperSparrow to open at login. You can add it in System Settings › General › Login Items & Extensions.”, or for turning it off “Couldn't stop SuperSparrow opening at login. You can remove it in System Settings › General › Login Items & Extensions.” It stays until macOS is found where the user asked, through a retry too, and gives way to Unavailable's caption. One line under the toggle at a time: a turn-off that fails while macOS waits for approval shows these words, which name Login Items themselves, in the approval line's place. Never an alert |

**Mail links.** The last row says which app opens `mailto:` links (§5.20). LaunchServices is asked whenever the tab appears (the window reopening on it included) and whenever the app comes to the front while it shows, since the user can choose another mail app in Mail's settings meanwhile; until the first answer the row holds nothing, rather than a button that may vanish.

| Mail links state | Look |
|---|---|
| SuperSparrow opens mail links | `checkmark.circle.fill` `success` 12 pt, 6 pt, “SuperSparrow is your default mail app.” (`snippet` `ink2`) at the field column's leading edge: the same status as OAuth's “Saved”. No button |
| Another app opens them | “Set as Default Mail App” (small secondary, at the field column's leading edge). It asks macOS to make SuperSparrow the default; macOS confirms in its own dialog, and the button is disabled until it answers. The row then shows what LaunchServices says: the words above, or the button again when the user kept the other app, with no message (a choice, not a failure) |
| The change failed | the button stays, enabled; under it, in the field column 8 pt below the control and at most 360 pt wide, a field's error help line (§5.25: `exclamationmark.triangle.fill` 10 pt, 4 pt, `meta` `danger`): “Couldn't make SuperSparrow the default mail app. You can also choose it in Mail › Settings › General.” It stays until an attempt succeeds or SuperSparrow is found to be the default: through a retry too, under the disabled button while macOS asks and after the user keeps the other app. Never an alert |

States per control as §5.24–5.27, Quire-drawn; validation errors inline under the field.

**Appearance** (§4.16), on General's grid: labels `body` `ink` right-aligned in the 140 pt column, controls 12 pt after it, 40 pt rows, captions `meta` `ink3` 8 pt under their control and at most 360 pt wide, a hairline between the groups. Font and Text size moved here from General: they are how mail looks and belong beside the theme. The tab has no buttons, so no new verb, and it never scrolls (about 374 pt of content, far below Accounts').

| Row | Label | Control | Under it |
|---|---|---|---|
| 1 | Theme | the five theme tiles (below) in a row at the field column, 15 pt apart (`settings.themeTileGap`), each with its name 6 pt below in `label`; row height 76 (`settings.themeRow`) | the chosen theme's caption (§4.16), 2 lines reserved (`settings.themeCaptionLines`) so a switch never moves the rows below |
| 2 | Appearance | radio group in one line (§5.26): Automatic · Light · Dark. VoiceOver reads the first “Automatic, follows macOS” | — |
| 3 | Dark Mode | checkbox “Adapt mail that sets its own colours” (on). Disabled, its caption kept, while Appearance is Light, where it would change nothing; with Automatic it stays enabled, since night will come | “Off: it opens in the sender's colours, on a white page. ⇧⌘O switches one message.” |
| — | hairline | | |
| 4 | Font | popup: New York, SF Pro (§4.4) | — |
| 5 | Text size | popup: Small, Default, Large, Larger (§4.15) | — |

**The theme tile** (`QuireThemeTile`, inside the `QuireThemePicker` radio group): a 60 × 40 pt miniature of the main window (`settings.themeTile`), radius `r.md`, drawn from **that theme's** tokens in the **current** mode with Increase Contrast and Graphite applied, so a Graphite user sees what they will get: a 8 pt `spine` strip; a 18 pt `paper` column with a 4 pt `accent` pip and two 1.5 pt `ink3` lines; and `canvas` holding a `sheet` card (hairline `rule`) with two `ink` lines and one `accent` line, 4 pt in. Its edge is a 1 pt `ruleStrong` of the **current** theme (the pair “Secondary button edge vs desk”). Five tiles and four gaps fill the 360 pt field column exactly. The choice is marked as the active tab is (§4.14), by weight and a mark under the name, never by a ring: a ring is the focus ring's alone.

| Tile state | Look |
|---|---|
| Chosen | name in `labelStrong` `ink`, with a 2 pt `selRule` underline 3 pt below it, as wide as the name (`selRuleIdle` while Settings is not key, as the margin rule does); the picture keeps its edge |
| Not chosen | name in `label` `ink2`; no underline |
| Hover | the name turns `ink`; the picture never takes a wash |
| Pressed | the underline shows in `ruleStrong` under the pressed tile's name until mouse-up, then the choice applies |
| Focused | the group is one Tab stop; ← → (and ↑ ↓) move the choice and apply it at once, stopping at the ends, as a radio group does; the Quire focus ring (§4.1) goes round the chosen tile's picture and name. It is the only ring the picker ever draws |
| VoiceOver | a radio group “Theme”; each tile reads as “Study, 1 of 5, selected”; the picture is hidden from accessibility; the caption is the group's help text |

Every change applies at once, Settings included: the window re-themes in place, keeping keyboard focus on the tiles and every field's state (§8.3). There is no hover preview and no Reset button: choosing Study is the reset. The values live in `UserDefaults` (`theme` = `study`, `appearance` = `automatic`, `adaptsMailColours` = true), and a value this version does not know reads as the default, so a fresh install, and every existing one, opens in Study, Automatic, adapted. The underline is two pairs of §7 (“Theme name underline, chosen, Settings key / not key”, `selRule` and `selRuleIdle` on `canvas`); the name, caption, edge and focus ring are existing pairs.

### 5.41 Notifications

`UNUserNotificationCenter`; macOS draws them, Quire supplies content. **Permission**: macOS's prompt is asked for while macOS has no answer and New mail is on, when an account is added (so it comes with an obvious reason) and at launch while there are accounts, the demo's included; macOS keeps the answer, not the app's defaults, and once answered only System Settings changes it, which Settings › General then says (§5.40, Notifications' line). One notification per new conversation; `threadIdentifier` = account id so they group; `targetContentIdentifier` = conversation id, so clicking opens and selects it.

| Field | Preview on | Preview off (Settings) |
|---|---|---|
| Title | sender display name (“Ben Carter”), else the address, else “No sender” | “New message” |
| Subtitle | subject, else “No subject” | account name |
| Body | first line of the snippet, max 120 characters | none |
| Summary (more than 3 within 30 s) | “3 new messages” · account name | same |

Sound: system default, off while the app is frontmost. No notification for mail that arrives while its conversation is open in a key window, or during an account's first sync (its first page of newest mail, including mail of that page whose rows land just after it). New mail notifies while older mail downloads behind it; the older mail itself never does, since it predates the first page. Nor does a conversation coming back from Later (§5.45): it is not new mail, and the Inbox badge and its row's Back tag say it came back. Nor does mail a mute or a sender rule took out of the Inbox as it arrived (§5.51, §5.52): it never reaches the Inbox, a muted conversation never notifies even where the user moved it back, and a row whose newest message is not itself in the Inbox (a rule's archive in a conversation the Inbox still holds for older mail, the user's own reply) stays quiet.

**Actions.** A notification for one conversation offers three actions (one category, registered at launch), which macOS lists in this order. The summary offers none: it names no conversation to act on, and a click on it only brings the app forward.

| Action | Copy | What it does |
|---|---|---|
| Archive | “Archive” | archives the conversation, as E does; the app stays where it is |
| Mark as Read | “Mark as Read” | marks every message of the conversation read; the app stays where it is |
| Reply | “Reply” | brings the app forward with a reply composer (§5.20) to the conversation's latest message, from the conversation's account, as R opens one; a button, not a text field in the notification |

Archive and Mark as Read are the window's own changes, applied on this Mac at once and queued to sync exactly as the keys apply them. Taken from a notification they show no toast and leave nothing for Z or ⌘Z: the undo history belongs to the window (§6.1), and the user acted elsewhere. The row leaves the inbox, or loses its unread mark, as a change synced from another device would. An action on a conversation that is gone, on one the change would leave as it is (already archived, already read), or on an account that is not open (a demo notification once the real accounts are back, or the other way round) does nothing, silently. An action that launches the app waits until the main window has read its accounts.

### 5.42 App icon

The brand mark, the paper plane, in black and white: a white plane on a near-black tile, by default and in dark alike, and white on black for the system to tint. On the macOS 1024 template (y down) the body is the 824 square centred on the canvas, its continuous corners 0.225 of the body (185.4, Apple's corner curve). The plane is drawn on the template's 128 × 128 construction grid of 8 px units, with an isometric lattice laid over it (verticals every 80 px and lines at 1:2 both ways, anchored on the tail point S): the glyph's 80 square fills the 640 square at (200, 216), one unit to 8 px, so every vertex is a grid point: N (840, 296), WF (200, 456), T (328, 520), S (360, 536), WN (520, 616), Sk (360, 560), X (504, 632), K (360, 776). The plane is 640 × 480, from (200, 296) to (840, 776), placed optically rather than by its box: the point midway between its box's centre (520, 536) and its ink's centroid (500, 493) lies within 3 px of the canvas's centre on each axis (1.8 px left, 2.6 px low), so the wings sit up and right of centre and the keel sits low. Its ink covers about 13% of the body. The nose clears the body's edge by about 83, the far wing's tip by 100 and the keel's foot by 148, outside Icon Composer's rim.

| Part | Default | Dark | Tinted and clear |
|---|---|---|---|
| Tile (the document's fill) | `#0A0A0A` | `#0A0A0A` | `#000000`, which the system tints |
| Plane (one layer) | `#FFFFFF` | `#FFFFFF` | `#FFFFFF` |

**Why a white plane on black.** The plane is the colour of paper, and the two folds read as shade. A black tile is rare in the Dock, so the icon is easy to find, and it has the build of Spark's icon (a solid tile, a white plane) without the blue. It is the highest contrast available, and the same two colours as the welcome screen's mark, the wordmark and the lockup, so the icon and the interface read as one drawing. The dark appearance keeps it as it is; the tinted one hands the system the white plane on black, so the plane is the luminance the system tints. There is no other hue, no gradient, no texture and no sheen: glass, specular highlights, shadow and translucency are all off in the document, and any grey the icon shows is the system's (Liquid Glass's edge, the tinted and clear looks, the Dock's reflections), never drawn.

**Small sizes.** The 16 and 32 px images are pixel-fitted masters, not reductions (`layout.appIcon.fit16`, `fit32`, drawn in pixels): the body snaps to whole pixels (768 = 12 px, 2 px in from each side; 832 = 26 px, 3 px in), and the plane is redrawn on that size's own pixel grid as straight-edged polygons, every vertex on a pixel corner, and rendered anti-aliased like every other size, so its diagonals stay straight lines and the nose a sharp point. At 32 px it is 21 × 15 px: the two wings are one contour, the fold between them kept as a short dark notch from (10, 16) to (20, 12), and the keel is its own triangle under a gap that opens from 1 to 1.5 px, so no parallel-sided cut breaks into two grey stripes. At 16 px it is 10 × 10 px: the wings are one triangle, the nose raised a pixel so it still climbs, and the keel is its own triangle under a 1 px gap, its tip stepped 1:1 to stay on whole pixels. Every other size, 64 to 512 px, is the 1024 px master reduced with Core Graphics' high-quality resampling, which is how the approved images were made (`sips -Z`): drawn from the paths at each size instead, the edges come out softer, up to 56 levels apart at 64 px.

**How it is built.** `swift scripts/tools/app-icon.swift` draws everything above from `tokens.json` alone (the `ss.paperPlane` path and `layout.appIcon`). It writes `Resources/AppIcon.icon`, an Icon Composer document that `actool` compiles for macOS 26 and later: the tile is the document's fill, specialized for dark and tinted; the plane is one layer, `plane.svg`, drawn on the document's canvas (the body), its solid fill specialized for dark and tinted, in one group with glass, specular, shadow and translucency off. Its colours live only in `icon.json`; there are no per-appearance copies of the artwork to drift. It also writes `Resources/AppIcon.icns`, the default appearance on the macOS 15 template (the same continuous corners, and the template's shadow, 10 down, 15 blurred, black at 0.28, outside the body only), packed by `iconutil` from 16 to 1024 px; inside the body every size is the approved image, pixel for pixel, the 16 and 32 px masters included. The shadow is the macOS 15 template's convention, outside the tile, never part of the mark. The `.icns` is the bundle's icon only where the asset catalog is not read: a build without Xcode's `actool`, and tools that open `CFBundleIconFile`. Once `actool` has compiled the document, the system reads `CFBundleIconName` from `Assets.car` on every supported macOS, so macOS 15 shows `actool`'s own flat renderings of the document (16 to 512 pt at 2× and 1024 px), which carry Liquid Glass's edge and reduce the plane rather than drawing the pixel-fitted masters. `actool` ignores an `AppIcon.appiconset` that shares the document's name (checked with Xcode 27.2), and an image set cannot carry dark or tinted images, so the approved pixels on macOS 15 and the document's appearances on macOS 26 cannot both ship; the build keeps the document. `--preview <png>` renders the document's six system appearances through Xcode's `ictool` beside the raster sizes, and the icon in the Dock at 64 and 32 px among Apple's white-tile apps and Mail, for review only. `--check` writes nothing: it renders into a temporary folder, compares byte for byte with `Resources/AppIcon.icon` and `Resources/AppIcon.icns`, and exits 1 listing every stale file; `scripts/test.sh` runs it, and `brand-assets.swift --check` for `docs/brand`, beside `quire-tokens.swift --check`.

The Dock badge stays system red. The icon shares its mark with the welcome screen, About, inbox zero, alerts and notifications, and nowhere else.

**Distinct from Apple Mail and from other planes.** Mail is a white envelope on a blue tile; this icon has no envelope, no blue and no circle, in any appearance (App Review Guideline 5.2.5). Spark's plane is rounded, upright and symmetric, on blue. Telegram's is also a white plane heading up and to the right with a fold, but it sits in a blue circle and has a notched tail and a keel that hangs below; this one sits on a black squircle, with a straight trailing edge and a flush keel. Stock send icons and Font Awesome's `paper-plane` have a separate tail piece that sticks out below the wing; here the keel stays inside the outline. It does not reproduce SF Symbols' `paperplane` or `paperplane.fill`, which Apple does not allow in app icons or logos: that is a symmetric 45° arrowhead with rounded joins and a slotted notch, where this has three triangles, sharp corners and a vertical keel back, and heads up at 26.6°. A look-alike sheet (kept outside the repository, comparison only) sets it beside each of them.

**Brand marks.** The symbol, the wordmark and the lockup are in `docs/brand` (SVG and PNG, with their use and clear space), built by `swift scripts/tools/brand-assets.swift` from the mark's path, `layout.brand`, `layout.appIcon` and the wordmark's outlines (`docs/brand/source/wordmark.svg`, drawn, never set in a font: straight segments, mitred joins and 45° chamfers, cap height 700, x-height 520, descender 190, stroke 100, the S's spine at the plane's 1:2 slope). Two colours only, both the icon's: ink `#0A0A0A` and paper `#FFFFFF`. The palette is written once (`BRAND` in `docs/design/source/tokens_def.py`), and `layout.brand` and the icon's colours are read from it. Beside the word the plane is 1225 wordmark units tall (1.75 cap heights), its box centred on the cap height (y -350, baseline 0) and 385 (0.55 cap heights) before the word's origin. The interface's one use of the word, under the welcome screen's mark (§5.39), draws `layout.brand.wordmark`, which `tokens_def.py` reads from the same master, so the two never part.

**Alignment with the interface.** A bundle has one icon, so the icon is black and white in every theme and appearance; the interface draws the same mark as a template in the brand's black and white (welcome) and the system's secondary label grey (inbox zero). A theme never recolours the icon or the mark, and the icon never colours the rest of the interface. The mark is `ss.paperPlane` from the token file, so the welcome screen, inbox zero and the icon are one drawing, and the welcome screen's name is the wordmark's own outline.

### 5.43 Demo mode

“Try the demo” opens the main window on two made-up mailboxes stored only on this Mac (`demo.sqlite`). Everything behaves as with real accounts except that nothing syncs or sends; the demo must never be mistaken for real mail, so it is marked in words in four places.

| Where | Marker | States |
|---|---|---|
| Masthead | a “Demo” tag (16 pt, `tag` role, `ink2`, `ruleStrong` edge, radius `r.xs`) 8 pt after the masthead (after its chevron in minimal mode, or after the minimal-mode dot, §5.3), in every view and in minimal mode while the header line keeps search's minimum beside it; on a line too crowded for both (minimal mode at the default list width, any list at its minimum width) it steps off the line and the other three markers carry the demo | it is a pull-down button: hover `hover` wash and `ink` text; pressed / menu open `pressed`; focused ring; tooltip “These mailboxes are made up and live only on this Mac.” Its menu: “Add a Real Account…” (submenu: Add Gmail Account…, Add Microsoft Account…) · — · “Leave Demo…” |
| Window title | “SuperSparrow Demo” (Window menu, Mission Control, VoiceOver; the title bar itself hides titles, §3.2) | — |
| Sync line | `info.circle` `ink3` + **Demo** · made-up mail, nothing syncs | replaces Up to date; no action |
| Settings › Accounts | an info banner above the group: `info.circle` + “Demo mode: these mailboxes are made up and live only on this Mac.” + link “Leave demo…” (sentence case in a banner, §4.13) | the demo accounts list as usual, with the tag “Demo” in place of the provider; Reconnect and Colour work, Remove is replaced by Leave Demo |

**Send Later in the demo.** The first time the demo's mailboxes are made, one message waits in the outbox for Monday 09:00 (Tomorrow's on a Sunday), so Drafts shows a row reading “Sends Mon 09:00” (§5.46) from the start, and the Outbox lists it too, its rail tile showing from launch until the message has gone or its schedule is cancelled (§5.53). It keeps no draft: opening it makes one from the message.

**The demo's calendar.** The demo accounts each have a calendar of made-up events for this week, a few a day in their inks, with an invitation in the Inbox whose event overlaps one of them (hatched, and named on its card), a snoozed conversation coming back later this week and the Send Later message above, so the day column, the week and their marks show from the start (§5.54). Its blocks are kept on this Mac, as everything in the demo is.

**Leaving.** Leave Demo… (tag menu and File menu; “Leave demo…” in the Settings banner) asks with a sheet alert: “Leave the demo?” / “The made-up mailboxes are removed from this Mac. You'll return to the welcome screen.” / buttons “Leave Demo” (default) and “Cancel”. Nothing real is lost, so the alert has no destructive button. Confirming wipes the demo store and shows the welcome screen (`dur.slow` cross-fade).

**Adding a real account from the demo.** “Add a Real Account…” starts the normal flow (§5.44). When the first real account is added, the demo leaves with it: the alert “Replace the demo with this account?” / “The made-up mailboxes are removed from this Mac when your account is added.” / “Continue” (default), “Cancel” comes first, then the browser sign-in; on success the window shows the real inbox.

### 5.44 Adding an account from the main window

Rail +, File › Add Gmail Account… / Add Microsoft Account… and Settings › Accounts + share one flow. The provider is chosen in a menu, never an alert.

| Step | Spec |
|---|---|
| Choose | rail + (and Settings +) opens a system pull-down menu 4 pt below the button, leading-aligned: `person.crop.circle.badge.plus` “Add Gmail Account…” · `person.crop.circle.badge.plus` “Add Microsoft Account…”. The File menu has both items directly |
| Kind of Microsoft account | before a Microsoft sign-in, an alert sheet: “Which kind of Microsoft account?” / “An address can be both a work or school account and a personal Microsoft account. Choose the one that holds your mail.” / “Work or School” (default), “Personal”, “Cancel”. Work or school signs in through `organizations` (or the one organisation Settings › OAuth names), personal through `consumers`, and the account renews and reconnects through it from then on, so Microsoft never picks the other mailbox of the same address. A work and a personal account with one address are two accounts |
| No OAuth client for that provider | an alert sheet: “Set up a Google OAuth client first” / “SuperSparrow needs your own Google OAuth client ID to add a Gmail account.” / “Open Settings” (default), “Cancel”; Open Settings shows Settings › OAuth with the info notice of §5.40 |
| Waiting for the browser | the browser opens; the rail gets a pending tile at the end of the stack (§5.2); the sync line reads “**Finish signing in in your browser** · Gmail” with the link “Cancel” (it joins the Tab order, §5.11); Settings › Accounts shows the pending row. Only one sign-in runs at a time: both + buttons and the File items are disabled meanwhile |
| Cancel | the pending tile and row leave at once; the sync line returns to its previous state; no message |
| Success | the pending tile becomes the account's tile (instant), the new account is selected, the list shows the skeleton (§5.10), the sync line reads “Downloading mail · Contoso…” |
| Failure | the pending tile leaves; an alert sheet on the main window (or Settings when started there): “Couldn't add the account” / the reason in plain words (“The browser sign-in was cancelled.”, “Google refused the sign-in. Check the client ID in Settings › OAuth.”, “Couldn't reach Google. Check your internet connection.”) / “Try Again” (default), “Cancel” |
| Already added | alert “alex@contoso.test is already added” / “Choose it in the rail or in Settings.” / “Show Account” (default), “Cancel” |

The welcome screen keeps its own in-place waiting state (§5.39) because it has no rail or sync line.

**Reconnecting for a permission** (the invitation card's “Reconnect”, or the Settings row's when it reads Calendar permission needed) is the same reconnect, with every step below, asking the provider for the permission beside mail (incremental authorization): the provider's own consent screen names the calendar access, in its own words. A reconnect for any other reason keeps a permission the account already granted. Success sends the answers that waited and takes the notice and the Settings status away; declining the permission in the browser leaves them as they were, with no message.

**Reconnecting an account** (the sync line's “Reconnect” with one account, or a Settings row's “Reconnect”) runs the same browser sign-in for an account that already exists:

| Step | Rail tile | Sync line | Settings › Accounts row |
|---|---|---|---|
| Waiting for the browser | the attention badge **stays** (the account still needs sign-in until the browser finishes); tooltip “Finish signing in in your browser…”; no spinner on the tile | state 1 of the precedence (§5.11): “**Finish signing in in your browser** · Fabrikam”, the account's name rather than the provider, with the link “Cancel” | “Sign in required” stays in place of the address; the status block shows a 12 pt `ink3` spinner and “Waiting for your browser” with small secondary “Cancel” in Reconnect's place (§5.40) |
| While it runs | one sign-in at a time: both + buttons, the File › Add items and every other Reconnect and Retry are disabled | — | — |
| Cancel (sync line or Settings) | unchanged: still needs sign-in | back to the state the precedence picks (Sign in required) | back to Sign in required with Reconnect; no message |
| Success | the attention badge leaves in the same frame; the unread badge, if any, takes its place | Checking for mail… (a check the user asked for, §5.11), then Up to date | Checking for mail…, then Up to date; the address line returns. VoiceOver announces “Fabrikam reconnected.” No toast: the badge leaving is the confirmation |
| Failure | unchanged | Sign in required | unchanged; an alert sheet on the window where it started: “Couldn't reconnect alex@fabrikam.test” / the reason / “Try Again” (default), “Cancel” (§5.33) |
| Signed in to a different account | unchanged | Sign in required | unchanged; the alert “Signed in to a different account” / “You signed in as sam@contoso.test, but this account is alex@fabrikam.test. Nothing was changed. Try again and choose alex@fabrikam.test in your browser.” / “Try Again” (default), “Cancel”. Nothing is replaced or added |

### 5.45 Later (snooze)

L puts the selection away until a time: it is archived now and comes back to the Inbox then, its latest message unread. Both halves are the ordinary Archive and Move to Inbox, so the phone and the web agree; only the timer lives on this Mac. One key, one conditional tile (§5.2), four presets and a date, no setting.

**The Later menu.** A system `NSMenu`, so its highlight, keyboard (↑/↓, ↩, Esc, type-to-select) and states are the system's. L pops it on the selection (one conversation or several, in the list or with the conversation open), hung from the lead row: its top-leading corner at the row's text column (x = 68, 24 in compact rows), 4 pt below the row, as the title menu hangs from the masthead (`menu.titleMenuOffsetY`); when focus is not in the list (the reader has it), from the reader header's Archive button, at its leading edge, the same distance below. Message › Later… (L) opens the same menu at the same place; the row's context menu carries its items as a Later submenu.

| Item | Time shown | Offered |
|---|---|---|
| Later Today | three hours from now, rounded up to the next full hour (“13:00”) | while that is before 18:00, This Evening's time |
| This Evening | today 18:00 (“18:00”) | before 17:00 |
| Tomorrow | the next calendar day, 09:00 (“Tue 09:00”) | always |
| Next Week | the next Monday, 09:00; a week on from a Monday (“Mon 09:00”, “17 Nov 09:00” from a Monday) | except on a Sunday, when the next Monday is Tomorrow's |
| — separator — | | |
| Pick a Date… | — | always |

So the menu reads soonest first and never offers one time twice: after 14:00 Later Today would read “18:00” beside This Evening, or a later time above it, so This Evening stands alone; on a Sunday Tomorrow is the Monday. Names are title case (§4.13). Each time follows its name in `ink3`, right-aligned on a tab stop at the longest name's width + 24 pt + the widest time's width from where the names start: the widest time begins 24 pt past the longest name, and every time ends at the stop. They are written as Later rows write times (§4.13: the time alone today, the weekday and time within six days, the date beyond, with its year only eleven months or more ahead), following the system's 12/24-hour setting, all in the local time zone; daylight-saving changes land where the wall clock says (Tomorrow is 09:00 on the wall, 23 or 25 hours away). Nothing is snoozed from the Trash or Drafts, or from `in:trash` or `in:drafts` results: L beeps there and the items are disabled. A search typed in the Trash or Drafts lists All Mail (§5.6), so L works on its results.

**Pick a Date…** is a sheet on the main window: the system alert of §5.33 (title, body, buttons in Quire's words), so no app-drawn modal surface is added. Its accessory is the system's graphical calendar (`NSDatePicker`, `.clockAndCalendar`, days before today greyed) and below it, 12 pt down and centred, a time field (`.textFieldAndStepper`, hours and minutes, the system's clock format). It opens on tomorrow at 09:00 with the calendar focused (arrows move the day, Tab reaches the time).

| State | Look |
|---|---|
| Opens | tomorrow, 09:00; Snooze enabled |
| A time not ahead (today, earlier than now) | Snooze disabled (the system's disabled default button); ↩ does nothing |
| Snooze (↩) | the sheet closes and the selection is snoozed until that time; a time that passed while the sheet was open beeps and snoozes nothing |
| Cancel (Esc) | the sheet closes; nothing changes |

**Snoozing** is one store transaction: the snoozes are written and whatever is in the Inbox is archived (a conversation already out of it, in All Mail or a search, just gets its time), so the rows leave the Inbox and the selection moves on exactly as after E. A conversation with nothing left to put away, its mail from others all in the Trash or Spam (# on Microsoft and ! on both leave the user's own reply in Sent, so it still lists in Sent, All Mail and a search), cannot be snoozed, since nothing would come back: L beeps for it, as E does when it changes nothing, the context menu's Later is disabled, and in a selection the others are snoozed while it stays where it is. The toast reads “Snoozed until Tue 09:00” however many were snoozed, with `clock`, Undo and Z: the time is what it tells, and a count would cut it off in a list of the default width (“Snoozed 3 until May 26 9:00 AM” does not fit beside Undo and Z, §5.30). Where even the sentence would be cut off (a date with a 12-hour time, a year ahead, a narrowed list) it reads “Until 20 May 2027 09:00”, so the time is never what truncates. Undo, Z and ⌘Z end the snoozes and move the archived mail back through Archive's own undo (“Undid Snooze”; Edit › Undo reads “Undo Snooze”). Snoozing a conversation that is snoozed already (from Later, or found in a search) moves its time; Undo puts the old time back.

**Coming back.** At its time, once its account has checked for mail since then (a second or two; a minute at most when it cannot, offline or signed out), the snooze ends, the mail it put away moves back to the Inbox and the latest of it is marked unread, as one store transaction queued as the ordinary operations. The check comes first so that a reply, or a move to the Inbox on another device, that came while the app was closed or the Mac slept ends the snooze instead (below) rather than being met by a return that marks old mail unread everywhere. A message in the Trash or Spam stays there, and on Microsoft the user's own copies stay in Sent Items and Drafts, as ⇧I leaves them, so the message marked unread is the one in the Inbox. It sorts by the moment it came back, under Today, with the Back tag while unread (§5.7); undoing an E, # or L that took it out of the Inbox puts it back there, under Today with its tag, as every undo puts a row back where it was. A time missed while the app was closed comes back at the next launch; one passed while the Mac slept, at wake. No notification is posted (§5.41).

**Ending early.** A snooze ends, with no Back tag, when mail from someone else arrives in the conversation (the provider puts it in the Inbox anyway), when anything puts it back in the Inbox first (⇧I, a drop on the Inbox tile, another device), when it is trashed, marked as spam or deleted (on Microsoft, where # leaves the user's own copies in Sent Items and Drafts, and on both where ! leaves them, when everything else is in the Trash or Spam, here or on another device), and when its account is removed. The user's own replies leave it snoozed, and so does mail that arrives in Spam after it was snoozed: a reply the provider files there never ends a follow-up the user set on their own message, and so does mail a mute or a sender rule covers (§5.51, §5.52): mail in a muted conversation, or from a sender with a rule, is not news, the rule keeps it out of the Inbox, and the conversation comes back at its time.

**The Later view** (the tile, G L, the title and View menus) lists the snoozed conversations in scope, soonest first, each time slot reading “Back Tue 09:00” (today “Back 15:00”), under no running heads; masthead “Later”, search placeholder “Search Later”. There L moves a time, ⇧I moves the conversation back now (the mail its time would bring back: a message in the Trash stays there, as a drop on the Inbox tile leaves it too), E ends the snooze and leaves it archived (toast “Archived”; several within 1000 ms coalesce into one toast and one undo, “Archived 3 conversations”, as E does everywhere, §5.30), Unsubscribe (⇧⌘U, the link, §5.14) sends its request and ends the snooze as E does (toast “Unsubscribe sent · Archived”, which no E joins), and # trashes it; each has its toast and Undo, which restores the snooze. When the last snooze in view ends the view returns to the Inbox; an undo then brings Later back with its row selected, unless the user has since picked a view or an account or typed a search, which an undo leaves as it is, as everywhere. A search typed in Later looks through All Mail, or the view an `in:` term picks (§5.6), as it does from any view, so its results are rows of that view (E archives, ⇧I moves to the Inbox, L snoozes or moves a time, each with that view's toast), and it stays when Later empties, with its results, selection and reader; clearing it lands in the Inbox.

### 5.46 Send Later (Q2.2)

A message can wait for a time instead of going now: written tonight, it goes tomorrow at 09:00. It waits in the outbox on this Mac and goes at its time **while SuperSparrow is open**, which every place that shows the time says or carries in its tooltip; neither Gmail's nor Outlook's own scheduling is reachable through their APIs. One key, no setting, no view of its own: the waiting message is a row in Drafts, and in the Outbox with every other message on its way (§5.53).

**Where it is offered.** Send's drop-down (§5.23), in the composer and in the quick reply, below the two send actions and a separator: the section heading “Send Later” (the system's menu heading, `NSMenuItem.sectionHeader`), its times, then Pick a Time…. ⇧⌘L and Message › Send Later… (`clock`) hang the same times, under the same heading, from the drop-down, as L hangs the Later menu from a row (§5.45); in the quick reply the text view takes ⇧⌘L before the menu, as it takes ⌘↩. Each time follows its name in `ink3` on a right tab stop, written as Later rows write times (§4.13), as the Later menu sets them:

| Item | Time shown | Offered |
|---|---|---|
| Tomorrow | the next calendar day, 09:00 (“Tue 09:00”) | always |
| Monday | the next Monday, 09:00; a week on from a Monday (“Mon 09:00”, “17 Nov 09:00” from a Monday) | except on a Sunday, when the next Monday is Tomorrow's |
| Pick a Time… | — | always |

Choosing one checks the message as Send does (a recipient, then “Send without a subject?”, §5.20) and schedules it; without a valid recipient it beeps and focus goes to the field to fix, as Send does. Message › Send Later… is disabled, and ⇧⌘L beeps, while Send is. **Pick a Time…** is Later's date sheet (§5.45) on the window it was chosen in: title “When should this send?”, body “It sends at this time while SuperSparrow is open. Until then it waits in Drafts.”, default button “Schedule”, disabled while the time is not ahead, and Cancel.

**Scheduling** keeps the draft on this Mac and puts the message in the outbox with its time; nothing is archived, since nothing has gone (Send and Archive archives when a message goes; this one has not). The composer closes, or the quick reply clears, and the window's toast reads “Sends Tue 09:00” with `clock`, Undo and Z (§5.30); Edit › Undo reads “Undo Send Later”. Undo takes the schedule back and returns the message where it was written: the composer opens with it, or the quick reply's text comes back to its bar (parked under its conversation when another is shown, with the strip's “Not sent · draft kept in …”, §5.18). No undo-send panel shows: nothing is counting down.

**In Drafts** each waiting message is a row in place of the draft it was written in, among the other drafts by when it was scheduled, its time slot reading “Sends Mon 09:00” (today “Sends 15:00”) in the time's style; the time's tooltip reads “Sends Mon 09:00 while SuperSparrow is open”, and VoiceOver hears “Sends Mon 09:00, while SuperSparrow is open.”. Its sheet is a draft's (§5.19) with “Sends Mon 09:00 · Cancel”. Opening it (↩, a double-click, Continue Editing) cancels the schedule and opens its draft in a composer, since what is being changed must not go at the old time; Cancel cancels the schedule and leaves the draft, which takes the row's place and the selection, with the toast “Send Later cancelled”, Undo and Z (Undo schedules the draft again, as it is then, for the same time while that is ahead; it beeps instead once the draft has been sent or discarded, or while a composer holds it, since the message must not go twice or go while open for sending); Discard (#) takes the schedule and the draft, with “Draft discarded · Undo”. Neither the row nor the sheet appears anywhere else but the Outbox (§5.53): the conversation it answers shows no pending sheet (§5.14) until it is on its way.

| State | Row's time slot | Sheet's date line |
|---|---|---|
| Waiting | “Sends Mon 09:00” | “Sends Mon 09:00 · Cancel” |
| Its time came, on its way (or waiting out a throttle's retry) | “Sending…” | “Sending…” |
| Missed while SuperSparrow was closed | “Not sent” | “Not sent” |
| Gone | the row and its draft leave Drafts; the sent copy arrives in Sent with the next poll | — |
| Failed | the row leaves; the draft returns as an ordinary draft holding the reason, and the toast reads “Couldn’t send “Lisbon” · Open draft” (`error`), as a quick reply's failure does (§5.18) | — |

**Its time.** It goes at its time on the wall clock, which daylight saving and a clock set by hand move with the wall, while SuperSparrow is open; a time passed while the Mac slept goes at wake. **A time missed while SuperSparrow was closed is never sent at launch**: the next launch asks, once, with the alert of §5.33 on the main window, “A scheduled message wasn't sent” (several: “3 scheduled messages weren't sent”), body ““Re: Contoso rollout” to Ben Carter was due to send at Mon 09:00, while SuperSparrow was closed. Send it now, or keep it in Drafts.”, buttons “Keep in Drafts” (default, ↩ and Esc: a message sent late cannot be taken back) and “Send Now”. Keep in Drafts leaves each as its draft; Send Now sends them at once. Until the answer the rows read “Not sent”. Once it has gone its draft is removed, and a provider's draft it continued goes to the Trash, as sending it from the composer does (§5.19).

### 5.47 Mark as spam (Q2.3)

! (⇧1 on most layouts, read from the character as # is, so it follows the keyboard layout) marks the selection as spam: one conversation or several, in the list or with the conversation open. Message › Mark as Spam ! and the context menu's Mark as Spam, after Move to Trash, do the same. No button joins the reader header (§5.12): Star · Archive · Trash keep their room, and spam is rarer than either. One key, no setting, no new surface.

**What it does.** The provider's spam folder takes the conversation's mail from others: Gmail adds the SPAM label (and takes INBOX away), Microsoft moves it to Junk Email. The user's own sent messages and drafts are never spam: they stay in Sent and Drafts on both providers, so a conversation the user replied to still lists in Sent with the reply, and one of only the user's own mail changes nothing (it beeps, as E does when it changes nothing). The exception is an own message the Inbox holds too (on Gmail, ⇧I and a return from Later put every message of the conversation in the Inbox): it goes with the rest, so the row leaves the Inbox, and the undo brings it back. What is in the Trash stays there. It is one store transaction and one queued operation, so the row leaves at once, offline too, and the selection moves on exactly as after #.

**There is no Spam view.** No view, search or count shows spam, as before (`in:` has no spam term); the provider's own spam folder, on the web or the phone, is where mail is rescued from, and mail moved out of it there comes back to the Inbox here.

| Where | ! does |
|---|---|
| Inbox, Starred, Sent, All Mail, a search's results (of those views) | marks the selection as spam; it leaves the list (in Sent and All Mail a conversation the user replied to stays, with only the reply) |
| Later | the same, and the snooze ends; Undo puts it back, snoozed as before (§5.45) |
| A conversation back from Later | the same; Undo puts it back under Today with its Back tag (§5.7) |
| Trash, Drafts, `in:trash` and `in:drafts` results | nothing: it beeps, and Message › Mark as Spam and the context menu's item are disabled, as Later is there |
| Nothing selected, the welcome screen, a text field | nothing (the key is text in a field, §6) |

**Feedback.** The toast reads “Marked as spam” with `xmark.bin`, Undo and Z (§5.30); several at once, or presses within 1000 ms, coalesce into “Marked 3 as spam”. Undo, Z and ⌘Z bring the conversations back where they were (Inbox or archive) and select them; the confirmation reads “Undid Mark as Spam”, and Edit › Undo reads “Undo Mark as Spam”. A change the provider refuses comes back with “Couldn't mark as spam. Restored.” and the row's failed glyph says “Couldn't mark as spam” (§5.7). VoiceOver reads the menu items by their titles and announces the toast as “Marked as spam. Press Z to undo.”

### 5.48 Print and PDF (Q3.4)

File › Print… (⌘P) prints the open conversation through the system print panel, whose PDF menu saves it as a PDF or opens it in Preview. It prints the conversation's sheets, not the screen: every message open, oldest first, however the reader has collapsed or scrolled them, built from the render payload the reader draws (`PrintDocumentBuilder`), never a picture of the window. Printing changes nothing, so it has no toast and no undo.

`layout.print`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `pageMargin` | 36 | `messageGap` | 24 | `partsTop` | 6 | `noteTop` | 12 |
| `noteGlyph` | 14 | `noteGap` | 6 | `attachmentGap` | 2 | `imageWait` | motion.duration.printImageWait |

| Part | Spec |
|---|---|
| Page | The paper is the sheet: no desk, no sheet edge, no shadow. Margins 36 pt on every side; paper size, orientation and scale from the print panel. WebKit lays the page out 1.25 times as wide as the printable width and scales it to fit, as Safari prints, so 15 pt reading type prints at 12 pt and a 624 pt newsletter fits a Letter or A4 page whole. Backgrounds print (avatars, a newsletter's bands) |
| Appearance | Light, whatever the app's appearance: WebKit lays a page out for print in a light appearance, the web view that prints is Aqua so what it loads before printing is decided in light too, and the document declares `color-scheme: light` on its root, over the `light dark` of the Quire head, so a sender's text with no colour of its own is black even in a dark web view. So a styled body is never adapted and the Original colors inset never appears. Paper stands in for `sheet` and is lighter, so every ink keeps the contrast its `sheet` pair asserts (§7). Print uses Study's light values whatever the theme: the print document carries the head alone, never the theme's stylesheet. A printout is paper |
| Masthead | The subject in `headline` (`headlineSans` under SF Pro; “No subject” in the placeholder style), then 6 pt below the participants and the count, “Ada Lovelace, Ben Carter, me · 3 messages” (`snippet`, `ink2`) |
| Message | 24 pt below the masthead or the previous message, a hairline `rule`, then 24 pt to its header |
| Header | As the sheet's (§5.14): avatar 36 · 12 gap · who block · date. The address stands beside the name at rest (`meta`, `ink3`, 6 pt after it), since paper has no hover; the recipients are always expanded, To, Cc and Bcc, every recipient written out (no “and 24 more”). No unread pip, star, Unsubscribe link, hover actions or footer: they are the reader's controls, not the message |
| Date | In full, in this Mac's zone, in the locale's order and the system's 12- or 24-hour form: “Fri, 13 Nov 2026 at 23:39” in British English, since “Yesterday” means nothing a week later. A draft reads “Draft · edited Fri, 13 Nov 2026 at 09:12”; a reply still in the outbox “Sending…”, as its sheet does |
| Invitation card | The card's words in its box (§5.14, `layout.invitation`), without its buttons, Open in Calendar or the permission notice; the answer given is a row of its list, “Your answer  Accepted” (Tentative, Declined). A cancelled card keeps its kicker in `danger` and its struck title. A link is written out in full |
| Body | As the reader sets it: plain and unstyled bodies on the reading page at the 48 pt indent, 18 pt below the header; styled ones across the page as their sender designed them. Each body is in a shadow root in the one page flow, not a frame, so a page break falls between two lines, never through one, and an image is never split. What a body positions, floats or lifts stays in its own sheet, as its frame keeps it in the reader: it never covers the masthead or another message's header. It is cut at the top and bottom of the body's own flow, never at its sides, so a newsletter wider than the page still shrinks to fit |
| Attachments | 16 pt below, at the indent, one line each: the name (`snippet`, `ink`) and its kind and size (“PDF · 240 KB”, `ink3`), 2 pt apart |
| Notes | A line where the reader folds or holds something back (below), 12 pt below what precedes it, at the indent, `meta` `ink3`; the folds' notes start with the elision glyph `ss.elide` (14 pt, 6 pt before the words), where the reader's mark stands |

**What the reader shows, the paper shows.** Each message prints as the reader shows it at the moment of printing (the shell reports every card's state), so what is folded stays folded and what is held back stays held back: to print quoted text, unfold it first (.); to print remote images, load them (⇧⌘I).

| In the reader | On paper |
|---|---|
| Remote images loaded (Load images, or Load remote images on) | printed |
| Remote images held back | not fetched, and left out: a held-back image takes no room on paper, where its one-pixel stand-in (as tall as it is wide under a sender's `height: auto`) would only push the page on; a note above the body says “3 remote images hidden” (the banner's count, its live sources included) |
| Quoted text folded | left out; the note “Quoted text hidden” with the elision glyph below the body |
| Quoted text shown | printed in the shared quote style (§5.15) |
| The message under an invitation card folded | the card, then the note “Message hidden” with the elision glyph |
| The message under an invitation card shown | the card, then the body, its quoted text as above |
| A body not downloaded (loading, offline, couldn't load) | the preview in `reading` `ink2`, ending in an ellipsis, then the note “Only the preview has downloaded” |
| A draft open in a composer | the note “Open in a composer window” |

A printout is one page flow with one Content-Security-Policy, while the reader gives each body its own. The printout applies the reader's per body: the bodies whose images the reader shows are attached first, with their parked sources put back as Load images does, and laid out; then, if any body's images are held back, the reader's blocking policy (`img-src ss-cid: data:`, nothing else remote) is added to the page and only then are those bodies attached. Printing therefore fetches only what the reader shows, never an image (or a tracking pixel) it held back. And as the reader's frames run no script of a body's, the printout's page runs none either: its own policy, from its first byte, lets only its own script run.

**Waiting.** The panel opens once the bodies' images have come in, each of the two steps above waiting up to 3000 ms (`motion.duration.printImageWait`) for its own, after which an image still on its way prints empty: the bodies holding their remote images back still load their inline ones, which a slow remote image in a body before them never leaves empty. Images the reader shows already come from the cache and inline images from this Mac, so the wait is seldom felt.

**Availability.** Enabled while one conversation is open in the reader; disabled with several selected, on the welcome screen and while a printout is being prepared or its panel is up. A composer has no Print…, so ⌘P there does nothing. The panel is a sheet on the main window; the job's name, which Save as PDF offers as the file's, is the subject (“No subject” without one). The paper size, orientation and scale chosen are kept for the next print until the app quits. There is no Page Setup…: the panel has paper size, orientation and scale. VoiceOver reads the item as “Print…”; the panel is the system's.

### 5.49 Reader window (Q3.5)

A conversation in a window of its own, for reading beside a composer or another conversation. ↩ (or keypad Enter) on the list opens the selected conversation, and so does ⌘O (File › Open in New Window); a double-click on a row opens that row's, ⌘ held or not. → stays in the main window: its reader shows the conversation and takes the keyboard (§6). One window per conversation: opening one that is already open brings its window forward. Nothing opens with several conversations selected (↩ is spent and ⌘O disabled), from Drafts (↩ and a double-click continue editing the draft in its composer, §5.19; ⌘O is disabled), from the Outbox (a message on its way: ↩ and a double-click continue editing a Send Later message still held and only show any other, in the main window's reader, §5.53; ⌘O is disabled), from the welcome screen, or from a row that is not a conversation (a running head, the list's tail, the server search's offer). ↩ with the keyboard in the main window's reader opens nothing new: it presses what has focus in the page, as before. Anywhere else in the main window, on a control Full Keyboard Access focuses (compose, Add Account, a toast's button), ↩ opens nothing either: it is that control's, or the window's. Esc closes the window as ⌘W does, once nothing else in it takes the key, while its quick reply holds nothing typed and no reply counting down; with the user's work there it stays (§6.1). Only a fresh press closes it: holding Esc down never closes one window after another.

`layout.readerWindow`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `defaultWidth` | 840 | `defaultHeight` | 800 | `minWidth` | 520 | `minHeight` | 420 |

| Part | Spec |
|---|---|
| Window | the main window's chrome (§3.2): transparent title bar, title hidden, the empty unified toolbar, the lights on y = 26; the title is the subject (“No subject” without one). Default 840 × 800 (the reader pane a default main window had before the day column, 1.9), minimum 520 × 420; each new window cascades from the last, and the size the user leaves one at is the next one's. No tabs |
| Content | the reader alone, without the split and without the day column or the week (§5.54), and its header holds the conversation's actions as the main window's does: the 92 pt header, the desk, the sheets and the quick reply exactly as in the main window's third pane (§5.12–5.18). Row 1 of the header shares the lights' centre line; its kicker starts at the larger of the reading column and the minimal-mode masthead's x (rail width + 8: 84 on macOS 15, 92 from 26 on, §3.2), so it clears the lights at any width; the headline, the sheets and the quick reply keep the reading column. The actions are the set of the view the conversation was opened from (§5.12): from the Trash, Star · Move to Inbox; from Later, Archive ends the snooze (§5.45). Move to Inbox makes it an Inbox row, and its undo the view's again; a conversation whose every message has gone to the Trash, from whichever window, is a Trash row (§5.12): the header, the Message menu, the context menu and # agree |
| Web view | one web view of its own, outside the main window's pool, so each window is one more WebContent process (about 25 MB, which the roadmap's baseline allows for); nothing is pre-rendered |
| Toast | bottom centre of the reader, 16 pt above the quick reply (above the window's bottom edge while the bar is hidden), at most the window's width less 16 pt a side (§5.30) |

**Keys and menus.** The reader's keys and the Message menu act on the window's conversation, as they do on the selection in the main window (§6): E, L, #, !, ⇧I, S, U, M, B, Z, R, A, F, N, P, ., Space, ⇧⌘U, ⇧⌘I, ⇧⌘O, and the sender rules (§5.52). B sets time aside as it does with the day column hidden (at the time the mail names, otherwise the first free half hour from today, §5.54), and its toast and undo are the window's. The reader's own commands work there too: Download Attachments ⇧⌘D (§5.17), Print… ⌘P (§5.48), Find in Conversation… ⌥⌘F with ⌘G and ⇧⌘G (§5.50, its bar in the window; Esc closes it after the window's toast), and the quick reply's Send Later ⇧⌘L (§5.46), whose “Sends Tue 09:00” toast and undo are the window's. C and ⌘N start a new message. / and ⌘F, the G-sequences and ? act in the main window, which comes forward; D, W, [, ] and T, with no column or week to act on, pass to the page as J and K do. J, K, ↩ and → have no list to move in or open from, and pass to the page. ⌘W closes the window, and so does Esc while the quick reply holds nothing (§6.1).

**Leaving the window.** Archive, Later, Move to Trash, Mark as Spam, Unsubscribe and a Mute that archives (from the Inbox) take the conversation off the desk, so the window closes as the step is taken: the main window comes forward with the step's toast (“Archived · Undo Z”), and its Undo (Z, ⌘Z, the button) brings the conversation back and opens its window again where it was. A step that leaves the conversation in the window (Move to Inbox, Star, Mark as Unread, a Mute that moves nothing, a sender rule) keeps it open, and the toast it gets shows in the window. ! where it does not apply (the Trash, Drafts) beeps, as in the main window. Discard Draft… on a draft in the window asks on the window, and the confirmed discard, which moves the conversation to the Trash, closes it as Move to Trash does. A reply sent from the window's quick reply with Send and Archive takes the conversation off the desk too: the window closes as the reply is queued, its countdown moving to an undo-send panel on the main window (§5.31) whose Undo brings back both the reply, in a composer, and the conversation (§5.23); Send alone keeps the window, its strip counting down in it. A conversation emptied elsewhere shows the reader's emptied state (§5.19), and the window stays until it is closed.

**What outlives the window.** Closing a window, by ⌘W or by a step, never loses what its quick reply held. Text in the box is kept with the conversation, for the next reader to show it: the window a step's undo opens again, or the main window's reader (at once, when it shows that conversation as the user closes the window). Text another reader kept for the same conversation meanwhile stays, the newer below it. A reply still counting down moves to an undo-send panel (§5.18), and one past its countdown is still watched, so a failure shows its error toast (“Couldn't send your reply · Open draft”) in the main window and leaves the Outbox for Drafts (§5.53).

**One undo history.** The undo history and its toast belong to the app, not to a window. Every window's steps join the same history, one toast shows at a time across all windows, in the window where its step was taken, and steps taken in different windows never coalesce into one toast. Z and ⌘Z reach the latest step from any window (§6.1), and its undo lands where the step was taken: the confirmation shows there, and a window the step closed opens again. That holds while Z still reaches the step (its toast shows, or its grace runs). A deeper ⌘Z, minutes later, opens no window again, since one springing up where the user left it long ago would come as a surprise: a step from a window that has closed since comes back in the main window, selected in the list, with the confirmation there, and a step from a window still open is undone in that window.

| State | Look |
|---|---|
| Key / not key | as the main window (§3.4, §5.1) |
| Conversation emptied while open | the reader's emptied state (§5.19); only Trash enabled |
| Full screen | as the main window: the band keeps its 52 pt |

VoiceOver names the window by its subject; inside it everything reads as the reader does (§4.14).

### 5.50 Find in conversation (Q3.6)

⌥⌘F (Edit › Find in Conversation…) finds words in the open conversation: a small bar over the reader, every match marked in the page, a count, and the current match brought into view. ⌘F stays the list's search (§5.6); the two never share a field.

`layout.findBar`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `width` | 320 | `height` | 40 | `pad` | 6 | `radius` | 8 |
| `top` | 8 | `trailing` | 16 | `fieldGap` | 6 | `buttonGap` | 2 |
| `matchRadius` | 3 | `currentRing` | 1 |  |  |  |  |

| Part | Spec |
|---|---|
| Bar | 320 × 40 pt, `raised`, radius 8, `e2`, a hairline `rule` edge (1 pt `ruleStrong` in Increase Contrast), padding 6; 8 pt under the reader header's bottom edge, 16 pt from the reader's trailing edge, floating over the page (the web view's frame never changes, as under the quick reply, §5.18). It fits the 400 pt minimum reader with room to spare |
| Field | 28 pt, the search field's face (§5.6): radius 6, `sheet`, 1 pt `ruleStrong` edge, `magnifyingglass` 12 pt `ink3` at x = 8, the query in `body` `ink` from x = 26; placeholder “Find in conversation” (`ink3`); the count 5 pt in from its trailing edge in `meta` `ink3`, 6 pt after the query, which truncates before the count does |
| Buttons | 6 pt after the field: Previous Match (`chevron.up`), Next Match (`chevron.down`) and Close (`xmark`), 24 pt icon buttons (§5.24), 2 pt apart; tooltips “Previous Match  ⇧⌘G”, “Next Match  ⌘G”, “Close  esc” |
| Count | “3 of 12”; “No matches” when nothing matches; nothing while the field is empty or holds only spaces. The count is the words, so the state never rests on the highlight's colour alone |

| State | Look |
|---|---|
| Opening | fades in `dur.quick` (a fade under Reduce Motion too) with the keyboard in the field, the last query of the session filled in and selected, so typing replaces it and ↩ finds it again |
| Empty | placeholder; no count; Previous and Next disabled (`inkDisabled`) |
| Matches | the count; Previous and Next enabled |
| No matches | “No matches”, calm: no red, no shake; Previous and Next disabled; ↩ and ⌘G beep |
| Field focused | the field's ring outside a 1 pt gap (§5.25) |
| Closing | fades out `dur.quick`; the marks go at once |

**Matches in the page** (reader CSS, §8.4). Every match is drawn behind its text in `findWash`; the current one in `findCurrent` with a 1 pt `ruleStrong` ring, so the current match has a shape as well as a colour. Both carry their own text colour, `ink`, and corners of 3 pt, with no padding, so a match never moves the words around it, and the mark reads the same on any page a sender designed, in Adapted and Original colors alike. A match split by formatting (`Hel<b>lo</b>`) is marked piece by piece and counts once.

**What counts.** Every message's body in the conversation: the expanded ones, the collapsed stack rows, the messages folded into “4 more messages”, the message folded under an invitation card, and quoted text, folded or not. Not the headers, the participants line, the invitation card's own words, attachment names or banners, and not a message whose body has not downloaded (its snippet stands in, §5.14). Letter case and accents do not matter (“cafe” finds “Café”), any run of white space is one space, and a match never crosses from one paragraph, cell or line break into the next. Text the sender hid in the element's own style never counts: under `display: none`, `hidden`, a zero opacity or a zero max-height (a preheader), whatever lies inside, and under a zero font size or `visibility: hidden` until an element inside sets a size of its own or `visibility: visible`, as the columns of MJML and hybrid templates do (a zero size on the column closes the gaps between inline blocks, and the text inside is sized again).

**Where a find starts.** A new search starts at the first match not yet scrolled past, so the reader keeps their place; typing more, or less, keeps the current match while a match still starts there, and otherwise goes on to the next one. After the last match comes the first, and before the first the last.

**What a step opens.** Only what hides the current match, and only when the current match lands in it: a collapsed message expands (its own folded run opens with it, and no other), the message under an invitation card unfolds, and folded quoted text unfolds, its elision mark then reading “Hide quoted text” (§5.15). A step (↩, ⌘G and their Shift twins) opens at once; typing opens only once it rests for 300 ms, and then for the match current by then, so the prefixes typed on the way to the words wanted (“o”, “of” for “offsite”) open nothing, while a match already in sight is scrolled to at once. Nothing animates, so the page does not move under the match, and the message holding it becomes the target (§5.14). What opened stays open when the find ends: refolding as the matches pass would make the page jump under the reader, and “.” folds it again. Other matches are counted, never opened.

**Keys.** ↩ in the field is Next, ⇧↩ Previous, Esc closes. ⌘G and ⇧⌘G (Edit › Find Next, Find Previous) step from anywhere in the main window while one conversation shows; with the bar closed they open it with the session's last query. ⌥⌘F with the bar open gives the field the keyboard again with its query selected. Esc from the page closes the bar first and the second Esc returns to the list, or in a reader window closes the window while its quick reply holds nothing (§6.1).

**Lifetime.** The bar belongs to the conversation it searched: showing another conversation, several or none, or the conversation emptying, closes it. Opened while the selected conversation is still on its way (⌘G pressed before its page lands), it searches nothing until that page is on screen, never the conversation being left. A store change to the open conversation (a reply arriving, a body downloading) finds again in place: the count follows, the current match stays, the page does not scroll.

**VoiceOver.** The bar is a group named “Find in conversation”; the field has the same label; the buttons read “Previous Match”, “Next Match” and “Close”; each new count is announced while the field has the keyboard (“Match 3 of 12”, “No matches”).

### 5.51 Mute (Q3.7)

M mutes the selection: it is archived now, and mail that arrives in it later is archived as it arrives, so it never reaches the Inbox and never notifies. M again unmutes. The archive is the ordinary one, so the phone and the web agree once it lands; only the mute itself lives on this Mac (Gmail's mute is not in its API). One key, one glyph, no setting.

| State | Look |
|---|---|
| Mute in the Inbox (M, Message › Mute, the context menu's Mute) | the rows leave the Inbox as after E, the selection moves on; toast “Muted” (`bell.slash`), “Muted 3 conversations” for several, with Undo + Z |
| Mute where the row stays (All Mail, Sent, Starred, a search, Later) | the muted glyph appears on the row; no toast for one (the row shows it, as for a star), a toast for several; Z reaches it for the grace period, and ⌘Z for as long as the undo history holds it (§6.1) |
| A muted row | `bell.slash` 12 pt `ink3` in the glyph cluster beside the star (§5.7), in every view it is listed in; VoiceOver adds “Muted” |
| Unmute (M on a selection that is all muted; the items read Unmute) | the glyph goes; nothing moves (the conversation stays where it is); no toast for one; Undo mutes it again |
| Undo of a mute | “Undid Mute”: the mute ends and the archived mail is back in the Inbox, selected, as Z after E: a row back from Later returns under Today with its Back tag (§5.45) |
| New mail in a muted conversation | archived as it arrives, the conversation's other mail in the Inbox with it (one moved back with ⇧I leaves again), queued as the ordinary archive; the row's time and snippet move to it, unread, in All Mail; no notification; a snooze stays, and the conversation comes back at its time (§5.45) |
| A muted conversation deleted everywhere | the mute goes with it; mail that later starts a conversation with its id starts unmuted |

The cheat sheet lists “M  Mute · unmute” in Act (§5.32).

### 5.52 Sender rules (Q4.2)

Two rules, set from a message, never typed: **Always Archive Mail from This Sender** (out of the Inbox as it arrives) and **Block Sender** (to the Trash as it arrives). Each account keeps its own, by the sender's address without case; one per sender, the second replacing the first. They act on mail as it arrives, never on mail already on this Mac or downloaded from further back, and never on the user's own sent mail or drafts; Spam is left alone. What they do is the ordinary archive or Move to Trash, so every device agrees once it lands. No setting, no key: a rule is set rarely, and a single key could set one by a slip.

| Where | What |
|---|---|
| A message's More menu (§5.14) | both items, for that message's sender, when someone other than the user sent it; the rule the sender has shows checked and disabled |
| The context menu of rows and messages, the Message menu (§5.35) | both items, for the open conversation's target message's sender (§5.14), or its newest mail from someone else when the user sent the target; disabled with several selected or for a conversation of the user's own mail |
| Setting one | in one step the rule is kept and that sender's mail in the conversation moves as the rule would move their next message (Block: out of the Trash; Always Archive: out of the Inbox); toast “Blocked deals@shop.example” (`hand.raised`) or “Always archiving news@letter.example” (`archivebox`), naming the address the rule took, since the menus' items do not, and always shown, since no row shows a rule, with Undo + Z, which puts back the rule the sender had (none, or the other) and the mail; “Undid Block Sender” |
| Their next message | archived or trashed as it arrives, never in the Inbox itself, no notification; a snooze its conversation has stays (§5.45) |
| Their next message in a conversation the Inbox holds for someone else's mail | that message alone moves; the conversation stays in the Inbox. Always Archive: its row shows the archived message as it shows any newest mail (its time, snippet and unread, which the Inbox's count takes in), with no notification; a conversation is one row, and its row is never made to hide mail it holds outside the Trash. Block: the row leaves the message out, as it leaves out anything in the Trash |
| Settings › Accounts › Rules › Senders… (§5.40) | the one place the rules are listed (below) |

**The Senders sheet.** A sheet on the Settings window, 440 pt wide on `canvas`, padded as a tab (20 24 22): the title “Senders” (`title` `ink`), then 8 pt below a caption (`meta` `ink3`): “Mail from these senders to alex@contoso.test is archived or moved to the Trash as it arrives.”, then 16 pt below the list, then 20 pt below, trailing, Done (small primary, the default button; ↩ and Esc close the sheet). The list is the account group's surface (`sheet`, radius 8, hairline edge) of 40 pt rows: the address in `body` `ink` from x = 12, cut in the middle so its start and its domain both show, then what the rule does in `snippet` `ink2` (“Blocked”, “Always archived”), 12 pt, and a − button 9 pt from the trailing edge: the +/− pair's half on its own (22 pt, `raised`, `ruleStrong` edge, radius `r.sm`, `minus` 11 pt `ink2`, and its hover, pressed, focused and disabled states, §5.40), so it adds no pair. Hairlines between rows from the text column. Rows are not selected (nothing here is chosen before acting), so they take no wash; each − is its own Tab stop, named “Remove” and the address for VoiceOver. Past 8 rows the list scrolls inside, a `rule` hairline marking each clipped edge.

| Senders state | Look |
|---|---|
| Rules listed | by address |
| No rules | one 56 pt row: “No sender rules” (`body` `ink2`) over “Set one from a message's menu.” (`snippet` `ink3`), centred |
| − | the rule goes at once, with no alert (nothing is lost: it is set again from any message), and the mail it moved stays where it is |
| A rule set from the main window while the sheet is open | it appears in its place |
| Demo mode | each demo account blocks a made-up sender, so the sheet has a row to show (§5.43) |

### 5.53 Outbox

What the user sent stays in sight until it has gone. The Outbox lists every message on this Mac the provider has not taken yet, from the moment Send is pressed: counting down its undo window, waiting for its Send Later time (§5.46), missed while SuperSparrow was closed, going now, waiting to go again, or failed. It is a view like Drafts, and like Later it shows only while it holds something: while a message in the scope is on its way its **rail tile** (`tray.and.arrow.up`) sits after Drafts, Trash, the hairline and All Mail a pitch lower (§5.2), the title menu lists it in the same place (§5.4), and **View › Outbox** and **G O** open it, with G O's row in the HUD (§5.32; the cheat sheet always lists it, as it lists G L). With nothing on its way none of them shows, and G O and View › Outbox do nothing, as G L does with nothing snoozed. When the last message in view has gone (the provider took it, it failed and was kept in Drafts, its schedule was cancelled or continued, its Undo took it back) or the scope moves to an account with none, the tile and the rest go and the window returns to the Inbox, a search typed there staying with its results, as from Later (§5.45); an undo of a Cancel taken there, before the user has picked a view or a scope or typed a search, brings the window back to the Outbox on its row, as an undo of a step taken in Later brings Later back. The tile never flickers: the rail reads the whole outbox at once, so a send leaving as another arrives keeps it, and only a failed send's moment before it is kept in Drafts may show it briefly. Masthead “Outbox”; it follows the scope, All Inboxes or the account the window is narrowed to. The search placeholder reads “Search Outbox”, and a search typed there looks through All Mail, as from Later (§5.6). Like every view but the Inbox, it is not where the next launch opens.

**Rows** are built from the outbox alone, as Drafts builds a Send Later row (§5.19): “To Ben Carter” with the first recipient's face, the subject, the plain-text part as the snippet, the paperclip for a file, dated when Send was pressed. They are in the order they go: those that go by themselves soonest first (what is going now, then what counts down or waits to go again, then Send Later times), then those waiting for the user (missed, failed), newest first. No running heads: each row says its own state. The list follows the outbox as it changes; a row leaves the moment the provider has taken the message, and the sent copy arrives in Sent with the next poll, as before.

| State | Row's time slot | Sheet's date line |
|---|---|---|
| In its undo window (the undo-send panel, or the quick reply's countdown, still offers Undo) | “Sending…” | “Sending…” |
| Going now: its window over, or its Send Later time come | “Sending…” | “Sending…” |
| Send Later, waiting | “Sends Mon 09:00”, with Drafts' tooltip and VoiceOver (§5.46) | “Sends Mon 09:00 · Cancel” |
| Send Later, missed while SuperSparrow was closed | “Not sent” | “Not sent” |
| Waiting to go again: throttled, or nothing left this Mac (no connection, no token) | “Retrying shortly” | “Retrying shortly” |
| Failed (it may have reached the provider, so it is never tried again), for the moment until its draft is kept | “Couldn't send”, in `danger` | “Couldn't send: Gmail didn't accept the message.” (`SendFailureWording`, the banner's reason), in `danger` |
| Gone | the row leaves at once; the sent copy arrives in Sent with the next poll | the sheet goes with its row |

VoiceOver hears the state as the slot says it, “Sending”, “Not sent yet, retrying shortly” or “Couldn't send”, and a Send Later message as in Drafts.

**A failed send leaves for Drafts.** The Outbox holds mail on its way, and a failed send is not. It is kept once, as a draft holding its reason (the composer opens it with the banner, §5.20), and its row leaves the Outbox as soon as that draft is on disk, never before, so the message is never lost; until then it reads “Couldn't send”. The undo-send panel or the quick reply that sent it keeps it while it still watches the send, saying so its own way (the panel's Failed state, the bar's “Couldn't send your reply · Open draft”, §5.31, §5.18). Every other failure is kept by the main window, as a failed Send Later message is (§5.46), built from the message as it would have been sent, with the error toast “Couldn’t send “Lisbon” · Open draft” once: one whose panel or quick reply has gone (its window closed, an Undo that came too late, the app quit), and one SuperSparrow quit while handing over, which the next launch fails since it may have gone. That one's draft reads “Couldn't send: SuperSparrow quit while sending it, so it may have gone. Check Sent before sending it again.” and its toast ““Lisbon” may have gone. Check Sent.”, so neither invites a second copy. A send its panel or quick reply still answers for is left to it, whatever the window sees first, so a failure is never kept twice; at launch the window keeps a failure once it has read the accounts. The demo keeps its failures among its own drafts.

**Opening a row** shows the message read-only in the reader, as Drafts shows a Send Later message (§5.19): the draft sheet, built from the message as it will be sent, its date line saying where it is; the kicker reads “Outbox · Contoso”, and the quick reply is hidden. A Send Later message still held (waiting, missed, or waiting to go again, which ↩ on its Drafts row takes back too) offers what Drafts offers it: **Continue Editing** (the header's, the footer's “Continue editing”, ↩, → and a double-click on its row) cancels the schedule and opens its draft, and a waiting one's **Cancel** takes the schedule back and leaves the draft, with “Send Later cancelled · Undo”; either way the row leaves the Outbox and the draft is in Drafts. Every other row only shows: header and footer offer nothing, and ↩, → and a double-click show it in the main window's reader, never in a reader window of its own (§5.49). An undo-send is taken back by its own Undo (the panel, the quick reply's countdown, ⌘Z, §6.1), never from here.

**Nothing else applies.** A message on its way is not mail in the store: E, S, U, #, !, L, M, ⇧I, R, A and F beep on its row, as E does where it changes nothing; the Message and context menus' mail items are disabled; it has no swipe (§5.7), no folder takes it in a drag (§5.2), and ⌘O opens no reader window (§5.49). Several selected: the header offers nothing, its headline reads “3 messages selected”, and the desk “Three messages selected” with “Select one to see it.”

**Empty**: “Nothing waiting to send” over “Messages you send wait here until they have gone.” (§5.9), whatever the accounts' sync states, for the moment before the window returns to the Inbox.

Drafts is unchanged: a Send Later message is a row there, in place of its draft, and a row here.

### 5.54 Day and week (1.9)

Every account's calendar beside the mail, each event in its account's ink (§4.2). Most of the time a calendar is looked at while working through mail, and the question is about one day: am I free at three, what does this invitation run into, when is my next call. So the **day** is a column that stays beside the reader, and the **week**, wanted for planning and wanting room, takes the reader's place when asked for. Both are fitted to the window, so neither ever scrolls, and both read only the store: each account's main calendar, which the engine reads for two weeks back and eight weeks ahead (`CalendarWindow`), the selected conversation's invitation and the times its mail names, and what is snoozed or waits to be sent. A day or a week turned to outside those weeks shows what the store holds at once and asks the engine to read its days, once each; what the read finds arrives as any change does. The provider expands repeating events, so nothing here reads a repeat rule.

SuperSparrow writes to a calendar only two things: answers to invitations, on the invitation card (§5.14), and time set aside for a mail (B or a dropped row, below), which it can take back. It is not a calendar app: no month or year view, no editing of other people's events, repeat rules, reminders or notifications, no one else's free time and no scheduling pages; the provider's own calendar is a click away from any event (§9). Nothing is set: the working day is 09:00 to 18:00 (`calendarPane.coreStartHour`, `coreEndHour`), the week starts on the Mac's first day of the week, and the column has one width.

`layout.calendarPane`

| Metric | pt | Metric | pt | Metric | pt | Metric | pt |
|---|---|---|---|---|---|---|---|
| `columnWidth` | 240 | `stripWidth` | 28 | `readerMinWithColumn` | 400 | `overlayShadow` | e2 |
| `headerHeight` | 92 | `headerPadX` | 14 | `headlineTop` | 60 | `kickerNavGap` | 8 |
| `navTrailing` | 8 | `navGap` | 2 | `dayToggleGap` | 6 | `weekHeaderPadX` | 24 |
| `bottomPad` | 10 | `dayCellsHeight` | 48 | `dayCellsInsetX` | 8 | `dayCellTop` | 4 |
| `dayCellHeight` | 40 | `dayCellRadius` | 6 | `weekHeadsHeight` | 34 | `weekHeadPadX` | 8 |
| `weekHeadTextTop` | 10 | `todayUnderlineGap` | 4 | `hourGutterColumn` | 44 | `hourGutterWeek` | 48 |
| `hourLabelGap` | 6 | `hourLabelClearance` | 14 | `trailingPadColumn` | 8 | `trailingPadWeek` | 12 |
| `foldHeight` | 14 | `foldedDayWidth` | 28 | `hourMin` | 16 | `hourMax` | 64 |
| `coreStartHour` | 9 | `coreEndHour` | 18 | `eventMinHeight` | 18 | `eventEdge` | 3 |
| `eventTintAlpha` | 0.13 | `eventRadius` | 5 | `eventInsetX` | 2 | `eventInsetY` | 1 |
| `eventGap` | 2 | `eventPadLeading` | 8 | `eventPadTrailing` | 5 | `eventPadTop` | 2 |
| `eventOneLineBelow` | 34 | `eventPlaceLineMin` | 46 | `eventGlyph` | 12 | `eventGlyphGap` | 4 |
| `maxSideBySide` | 3 | `allDayRowHeight` | 18 | `allDayRowGap` | 4 | `allDayRowsMax` | 2 |
| `allDayPadTop` | 4 | `allDayPadBottom` | 6 | `nowLineWidth` | 2 | `nowDot` | 8 |
| `markLine` | 1 | `mentionLine` | 2 | `markDash` | 3 / 3 | `markChipHeight` | 18 |
| `markChipInset` | 3 | `markChipPadLeading` | 5 | `markChipPadTrailing` | 7 | `markChipGap` | 4 |
| `pencilDash` | 3 / 2 | `hatchLine` | 1 | `hatchPitch` | 5 | `joinMinWidth` | 120 |
| `joinMinHeight` | 22 | `joinLabelMinWidth` | 150 | `detailsWidth` | 240 | `detailsGap` | 8 |
| `detailsRadius` | 8 | `detailsPadTop` | 12 | `detailsPadX` | 14 | `detailsPadBottom` | 14 |
| `detailsTitleTop` | 6 | `detailsWhenTop` | 2 | `detailsPlaceTop` | 4 | `detailsActionsTop` | 12 |
| `detailsActionGap` | 4 | `ghostEdge` | 2 | `dropDash` | 4 / 3 | `dropRing` | 2 |
| `stripGlyph` | 15 | `stripBarWidth` | 8 | `stripBarRadius` | 3 | `stripLineInset` | 3 |
| `footPadY` | 10 | `footGap` | 6 | `footLinesMax` | 2 | `blockMinutes` | 30 |
| `snapMinutes` | 15 |  |  |  |  |  |  |

Every metric is in points except `eventTintAlpha` (the account ink's opacity over `sheet` in an event's face), `coreStartHour` and `coreEndHour` (hours of the day), `blockMinutes` and `snapMinutes` (minutes), `maxSideBySide` and `allDayRowsMax` (counts) and `overlayShadow` (an elevation level, §4.8). `columnWidth` and `stripWidth` include their leading hairline, as the rail's and the list's widths include their trailing one (§3.2).

**Where it lives.** The day column is 240 pt at the reader's trailing edge, the window's full height, `paper`, with a hairline (`rule`) at its leading edge; it is on by default. D, View › Hide Day or the **calendar toggle** hides and shows it instantly, as the rail hides, and the window keeps the choice across launches as it keeps a hidden rail (in the app's settings, not the split view's autosave). Once some account has granted the calendar permission the toggle always stands at the window's trailing edge, never among the reader's actions (§5.12): at the end of the column's kicker line while the column shows (below), and as the glyph atop the 28 pt strip while it is hidden, for a hidden column then folds to its strip rather than going, and the reader takes 240 − 28 pt back. With no account granting it there is no toggle: a hidden column goes, and D or View › Show Day brings it back with its foot's Connect. The window remembers whether some account had granted it when the engine last said, so the strip stands from a launch's first frame rather than pushing the reader over once the engine has looked. The reader keeps its 400 pt minimum: while the window's width less the rail, the list and 400 is under 240, the column **folds** to a 28 pt **strip** (below), the way an empty weekend day folds in the week. While the column is on, or its strip keeps the toggle for a hidden one, the list's maximum gives up 28 pt, so even the strip never takes the reader under 400 (§3.2). W, View › Show Week or the Week button gives the **week** the reader's place and the column's; W again, D or the Week button brings both back. Reader windows have neither (§5.49).

| Window width | Reader, macOS 26 rail (84) / macOS 15 rail (76), default list | Day column |
|---|---|---|
| 960 (minimum) | 484 / 492 | folded to the strip |
| 1088 | 400 / 408 | in full (from 1080 on macOS 15) |
| 1304 (default) | 616 / 624: the reader keeps its keycaps (§5.36) | in full |
| 1440 | 752 / 760 | in full |

With the list at its 300 pt minimum the column shows in full from 1024 pt (macOS 26), and with the rail hidden (minimal mode) from 1004. With the column hidden the reader takes its 240 pt back.

**Anatomy of the day column**, top to bottom:

| Part | Spec |
|---|---|
| Header | 92 pt, `paper`, its bottom hairline on the horizon the reader header's shares (§2); the title-bar zone's rules apply to its top 52 pt (§3.2) |
| Kicker | at x = 14, centred on y = 26 (the lights' line), `runningHead` `ink3`, where the shown day is from today: “Today”, “Tomorrow”, “Yesterday”, “Earlier this week”, “Later this week”, “Next week”, “Last week”, “In 3 weeks”, “2 weeks ago”. It ends at least 8 pt before ‹ and tail-truncates there |
| ‹ Today › | trailing, 8 pt from the column's edge (or ending 6 pt before the calendar toggle), centred on y = 26, 2 pt apart: Previous Day (`chevron.left`) and Next Day (`chevron.right`) as 28 pt icon buttons (15 pt symbols, §5.24), “Today” between them as a **small** secondary button (22 pt). Tooltips “Previous Day  [”, “Today  T”, “Next Day  ]”. Today is disabled, showing the arrow, while the column shows today |
| Calendar toggle | only once some account has granted the calendar permission: the kicker line's last control, 8 pt from the column's edge, centred on y = 26, a 28 pt icon button (`calendar`), on in the quiet style as the week's calendar button is (`accentWash`, glyph `accent`, §5.15); tooltip “Hide Day  D”. A click does what D does: the column folds to its strip, whose glyph is the same toggle, off |
| Headline | the shown day, “Thursday 19 Nov” (“Thursday 19 Nov 2027” outside this year), `masthead` (New York 20/24; `mastheadSans` under SF Pro) `ink` at x = 14, top 60, so its baseline is the reader headline's; one line, tail truncation, ending 8 / 2 pt before the week button |
| Week button | the week, opened from inside the calendar: a 28 pt icon button (`rectangle.split.3x1`) at the trailing side, 8 pt from the column's edge, centred on the headline's line, under the calendar toggle; tooltip “Show Week  W” |
| Day cells | the 48 pt band under the header, a hairline at its bottom: the shown day's week as seven cells, (column − 2 × 8) / 7 = 32 pt wide, 40 pt tall at y = 4, radius `r.md` (6). Each: the weekday (“Thu”, `meta` `ink3`) over the date (`body` `ink3`), each line centred across the cell and the two together centred in it at any Text size (§4.15), the date the larger so the day reads before its name; and nothing else: the date is `ink` on a day with busy time (answered busy events of the scope's accounts; free, all-day and unanswered ones count for nothing) and `ink3` on a free day, so the week's shape shows with no mark at all. No dot, bar or account ink per event: at this size those read as noise, and the column below shows what the day holds. The shown day's cell is **selected**: `raised`, a hairline `rule` edge (`ruleStrong` in IC), `e1`, its words in `ink`. Today's date is `bodyStrong` `ink` with a 2 pt `ink` underline across the last 2 pt of its line, under its baseline. A click shows that day; a row dropped on a cell sets aside that day's first free half hour (below) |
| All-day band | only while the shown day has all-day events: up to 2 rows of 18 pt chips, 4 pt apart, 4 pt below the cells and 6 pt above a hairline; each chip spans the day like an event (its face, edge, radius and inset, below) with its title in `metaMedium` `ink`. A third or later all-day event makes the second chip end in a “+2” tag (as an event's “+N”, below) |
| Timeline | below the band (or the cells) down to 10 pt above the column's foot or bottom: the hour gutter (44 pt, with a hairline at its edge), hour labels (“09:00”, `meta` `ink3` tabular, right-aligned 6 pt before the gutter's hairline, centred on their hour's line; “9 AM” under the 12-hour setting, §4.13), a `rule` hairline at each open hour from the gutter to 8 pt from the column's edge, the folds, the events and the marks, all fitted as below |
| Foot | only while there is something to connect (below) |

**The fit: nothing ever scrolls.** The column and the week are fitted to the window by the same rules, over one day or seven, whenever the window, the day or the events change. It is arithmetic over at most 168 hours and a few hundred events, done on the main thread from the store.

1. **Open the hours that hold something.** 09:00 to 18:00 (`coreStartHour`, `coreEndHour`) is always open. Any hour holding an event, an invitation, time set aside, a mark or a time the selected mail names (30 minutes from it) on the shown day, or on any of the week's days, opens too.
2. **Fold the rest.** Each run of closed hours folds into one 14 pt band, `canvas` with no edges (the band alone says the hours are folded; edges doubled the hairline over the timeline's top and the hour line beside each fold), labelled with its range (“00:00 - 08:00”, `meta` `ink3` tabular, 6 pt in from the gutter), the way the reader folds older messages into the quire. Nothing is ever in a fold, so nothing hides behind one.
3. **Share the height.** The open hours share what is left after the folds, up to 64 pt an hour. While a quiet day would stretch past that, one more hour opens, before and after the open ones in turn (from the start of the day or the end when one side has run out), until it fits; the floor is 16 pt an hour, which holds all 24 hours and two all-day rows in the 600 pt minimum window.
4. **Share the width.** In the week, a Saturday or Sunday with nothing in it (no event, mark, time or all-day event) folds to 28 pt; the other days share the rest equally. The column folds whole, to its strip.

Times between two hours are placed in proportion inside their hour. Nothing scrolls sideways either: [ and ] turn the page.

**Events.**

| Part | Spec |
|---|---|
| Slot | the event's time on the timeline, at least 18 pt (an event shorter than a line still gets one); the face is the slot less 1 pt above and below and 2 pt in from the day's sides |
| Face | its account's ink at 0.13 over `sheet`, opaque (`eventFace` in `contrastPairs`), radius `r.sm` (5), with a 3 pt **edge** in the account ink down its leading side, inside the radius. No shadow |
| Text | padding 2 pt top, 8 pt leading (the edge included), 5 pt trailing, clipped to the face. From 34 pt tall: the time (“13:00 - 14:00”, `meta` `ink2` tabular; its start alone, “13:00”, where the range would be cut), then the title (`label` `ink`), wrapping while there is room and tail-truncated on its last line; in the column, an event at least 46 pt tall and alone across its slot adds a line: `video` and the call's service (“Google Meet”, “Teams”, “Zoom”, read from its join address, else “Video call”) or `mappin.and.ellipse` and its location (12 pt glyphs `ink2`, 4 pt, `meta` `ink2`). Under 34 pt: one line, in the column the start time (`meta` `ink2`) then the title (`metaMedium` `ink`), in the week the title alone. Set aside for a mail: `envelope` (12 pt `ink2`) before the title |
| Side by side | events that overlap share the day's width, up to 3 across, 2 pt apart, in start order (longer first at the same start); a fourth and later is not drawn and the third ends in a “+1” tag: 16 pt, `raised`, a 1 pt `ruleStrong` edge, `tag` `ink`, radius `r.xs`, 2 pt in from the face's top-trailing corner, its tooltip naming what it stands for (“Also at This Time: Hiring Sync”). Tab and VoiceOver still reach every event |
| Join | the **next video call of today** only (the first event of today, not yet ended and not pencilled, with a join address), and only while its face is at least 120 pt wide and 22 pt tall: a **small primary** button (22 pt, §5.24) flush with the face's top-trailing corner (its radius is the face's), `video` and “Join”, or the glyph alone while the face is under 150 pt wide; the title stops 4 pt before it. It opens the call in the browser (or the app registered for its address). One at a time, so the ink marks one action (§1); every call has Join in its details |

A click on an event opens its **details** (below); a click on a pencilled invitation drawn from mail selects its conversation instead. Events move and arrive in one frame as the store changes; nothing animates.

**The week.** W shows it in the reader's place and the column's: the whole right side of the window, `paper`.

| Part | Spec |
|---|---|
| Header | 92 pt, `paper`, its hairline on the horizon. Kicker at x = 24, centred on y = 26, `runningHead` `ink3`: “This week · All accounts” (“Next week”, “Last week”, “In 3 weeks”, “2 weeks ago”), or the scope's account name after its ink dot (7 pt, as the reader's kicker) when the window is narrowed to one account. Headline at x = 24, top 56: “16 - 22 November”, “30 November - 6 December”, with the year outside this one, in `headline`. Trailing at 16, top 12: Previous Week, Today (tooltip “This Week  T”), Next Week as in the column's header, a 14 pt gap, then one calendar button (`calendar`, on, quiet; tooltip “Back to Day  W”), which goes back to the reader and the day column (§5.12) |
| Day headings | a 34 pt band under the header, a hairline at its bottom: per day “Thu 19” (`runningHead` `ink3`) at x + 8, top 10; today's in `ink` with a 2 pt `ink` underline 4 pt below its line. Hover `hover`, words in `ink`. A click goes back to the reader and the column on that day (tooltip “Show Thu 19 Nov in the Day Column”) |
| Days | seven columns after a 48 pt hour gutter, the last ending 12 pt from the edge, a hairline (`rule`) between each from the header down; the all-day band across them, with “All day” (`meta` `ink3`) in the gutter; then the timeline, fitted over all seven days |
| Folded day | 28 pt, `canvas` from the header down, its heading in two centred lines (“Sa”, “21”, `runningHead` `ink3`); no hour lines, no drop |
| Invitation card | while the selected conversation's invitation falls in the shown week, a card beside its slot, with the details' surface and placement (below): the kicker “Invitation · not answered” (`calendar`), once answered “Accepted” with `checkmark` in `accent`, “Tentative” or “Declined”; the title, the when and “Bay 4 · from Rachel Kim”; the overlap line (§5.14); Accept · Tentative · Decline, as on the reader's card and with its rules: no toast and no undo. Esc hides it until the selection changes or its event is clicked (§6.1) |

[ and ] turn a week, T goes to this week; turning the page never moves the day the column will show. Leaving the week (W, D, the calendar button in its header) puts the reader and the column back on the day the column showed before the week opened, or on the selected mail's day; a click on a day's heading takes that day instead. Everything else, the keys, the marks, the colours and the fit, is the column's.

**It follows the mail.** The list keeps the keyboard: a click on an event or a day cell opens its details or shows its day and never takes it. J and K move the column (or the week) only when the selected conversation is about a time: an invitation turns it to the invitation's day, a mail naming a day and time to that day; anything else leaves it on the day it was on, and moving past a mail that turned it turns it back. The day the column shows is never stored. Hidden, the column follows nothing and J and K cost it nothing; it comes back already on the selected mail's day. While the week shows, the reader under it is hidden, not gone: it follows the selection but marks nothing read and acknowledges no failed mark until it shows again (§5.7, §8.5); R and A open the composer, as wherever the quick reply is hidden (§5.18), F as ever, and what acts on the reader's page (Find in Conversation, Next and Previous Message, Show Quoted Text) waits for it.

**Marks.**

| Mark | Spec |
|---|---|
| Now | on today only (in the week, today's column): a 2 pt `ink` line across the day, an 8 pt `ink` dot centred on its leading end, and the time (“11:40”, `metaStrong` `ink` tabular, on `paper`) in the gutter, whose hour labels within 14 pt of it give way, measured where each label is drawn (one at the timeline's top or bottom is held inside it). It moves once a minute (`dur.nowTick`), only while a calendar shows in a window on screen (not hidden, minimised or covered), and the day turns at midnight on the system's day-change notice: a column that showed today shows the new today, and a week that showed this week the new today's, and J and K go back to it; a day or a week the user turned to stays. Never a contrail and never animated (§4.10) |
| Later (§5.45) | a 1 pt dashed `ink3` line (`markDash`) across the day at the time a snoozed conversation comes back, and a chip on it, 3 pt in from the day's leading side, centred on the line except where it would cover a fold's range: there it hangs from the line into the open hours (a 09:00 mark after a folded night sits just under the line), and it never leaves the timeline: 18 pt, `r.pill`, `paper` with a 1 pt `ruleStrong` edge, padding 5 pt leading and 7 trailing, `clock` 12 pt `ink2`, 4 pt, the subject (`meta` `ink2`, tail-truncated inside the day). Tooltip “Comes Back from Later at 17:00” |
| Send Later (§5.46) | the same, with `paperplane`, at the time the message is to go. Tooltip “Sends at 16:00 While SuperSparrow Is Open” |
| The selected mail's time | for each time the selected conversation's mail names in the future (§8.5), until time is set aside there: a 2 pt dashed `accent` line across the day and a chip as above with a 1 pt `accent` edge: `envelope`, “From this mail · 15:00” (`metaStrong` `accent`), 4 pt and the keycap “B” (16 pt). A click, or B, sets 30 minutes aside there (tooltip “Block 30 Minutes for This Mail  B”) |

A click on a Later or Send Later chip opens its details: “Later” or “Send Later” as the kicker, the subject, “Back in the Inbox Fri 20 Nov, 17:00” or “Sends Thu 19 Nov, 16:00”, a line on what it is (“Snoozed. G L lists it.”, “Sends while SuperSparrow is open. It waits in the Outbox until then.”) and Show the mail. Marks are drawn above events; they never take a drop.

**The selected conversation.** Its invitation's event (the provider's copy, matched by the iCalendar UID), or, while the calendar holds no copy, the invitation drawn from the mail itself, **pencilled**, carries the **margin rule** (3 pt `selRule` down its leading side in place of the account edge, `selRuleIdle` while the window is not key, §3.4) and is drawn above its neighbours. Where it overlaps other events it is **hatched**: diagonal lines rising toward the trailing edge, 1 pt in `warning` every 5 pt, over the overlapping time only, and never through its words: the face is laid again under each line of them, 2 pt past its ends, so the words keep their pairs on the face and the hatch shows around and below them, and the overlap is said in words on the invitation card beside it (§5.14). Overlaps are counted as the card counts them: every account's events except the invitation's own, declined, free and all-day ones, with an invitation's times without a zone read in this Mac's zone first. Time set aside for the selected conversation carries the margin rule too. Only the selected conversation's invitation is pencilled from mail; every other invitation shows as the provider's own event (Google adds one as not answered, Exchange as tentative).

**Event details.** A click on an event, or ↩ or Space on a focused one, opens a card beside it:

| Part | Spec |
|---|---|
| Card | 240 pt wide, `raised`, radius `r.lg` (8), `e2`, a hairline `rule` edge (`ruleStrong` in IC), padding 12 14 14. In the column it opens to the column's leading side, over the reader, 8 pt from it, top level with the event's, and never closer than 8 pt to the reader's leading edge (over a narrow reader it covers the column's edge rather than the list); in the week beside the event, 8 pt after it, or before it where there is no room, or under it. It never leaves the timeline: it moves up to stay 8 pt above the window's bottom, never above the timeline's top |
| Kicker | the account's ink dot (7 pt), 8 pt, the account's name in `runningHead` `ink3`, then “· Tentative”, “· Not answered” or “· Set aside for a mail” where they apply |
| Title | 6 pt below: `title` `ink`, wrapping, at most three lines. No title: “No title” in the placeholder style |
| When | 2 pt below: `body` `ink` tabular, “Thu 19 Nov · 13:00 - 14:00”, as the invitation card writes it (§5.14: all day, several days, the 12/24-hour setting) |
| Place | 4 pt below, `snippet` `ink2`: the location, wrapping; the call's service on its own line when it has a join address |
| Failed | for time set aside that the provider refused: `exclamationmark.triangle.fill` `danger` and “Couldn't add this to Google Calendar.” (“to Outlook”) in `snippet` `danger` |
| Actions | 12 pt below, small buttons 4 pt apart, wrapping, sentence case: **Join** (primary, `video`; only with a join address), **Show the mail** (secondary; time set aside for a mail, or a mark: selects its conversation), **Remove** (secondary; only for time set aside from this Mac), then the link button **Open in Google Calendar** or **Open in Outlook** (only when the provider gave the event's web address). A join or web address counts only over https, the one scheme SuperSparrow opens: an event with any other shows no Join, no call line and no Open in |

One card at a time; it closes on Esc (§6.1), a click outside it, a turn of the day or week and a change of selection, returning focus to the event when the keyboard opened it. Tab moves among its buttons. While it is open its event keeps its hover look, and the event's own Join steps back to the secondary look so the card's is the one primary in sight. VoiceOver reads it as a dialog named by the event's title.

**Setting time aside.** B (Message › Block Time), a click on the selected mail's time, or a list row dropped on the column or the week sets 30 minutes aside for one conversation, in the calendar of its account: busy, titled with its subject (“No subject” without one), linked back to it in its description, with no guests and no reminder. It is stored on this Mac first, drawn at once, with `ss.queued` before its title until the provider has it, and sent by the engine (§8.5). Its toast says when, with Undo + Z (§5.30); the column (or the week) turns to it.

- **B** puts it at the first time the selected mail names that is still ahead and not set aside for it already; otherwise at the first free half hour, on the quarter hour, from now on today and from 09:00 on other days, until 18:00, of the day the column shows (today's when it shows a day already past or is hidden; while the week shows, its first day's or today's, whichever is later), going on day by day for up to three weeks and passing over a Saturday or Sunday unless it is the day the column shows (the week shows no one day), and never past the days the store holds (the kept weeks, or the days turned to beyond them). Now is read when B is pressed, whether a calendar shows or not. Busy means an event that is shown, not free and not all day, or time set aside. On a selected invitation B sets nothing aside: the toast “Answer the invitation to put it in your calendar” points to its card. With no conversation or several selected, B beeps.
- **A row dragged** over a timeline shows a **ghost** where it would go: the day under the pointer, 30 minutes from the pointer's time snapped to 15 minutes (over a fold, the hour after it), as an event's slot with `accentWash` for its face, a 2 pt dashed `focus` edge (`dropDash`) and “Thu 13:30 - 14:00” in `metaStrong` `accent`. Over a day cell, the cell takes a 2 pt `focus` ring inside its edge, and the drop sets aside that day's first free half hour (or says “No free half hour on Sat 21 Nov”). The column takes one conversation's row at a time; a drag of several shows no ghost and drops nothing. The rail's folders keep their drops (§5.2).
- **Remove**, in the details of time set aside from this Mac, takes it off at once and from the provider after; its toast offers Undo, which sets it aside again where it was. Time set aside elsewhere, and every other event, are changed in the provider's calendar.

**The strip and the column over the reader.** Folded, while the window is too narrow for it or while it is hidden once some account has granted the calendar permission, the column is a 28 pt strip in its place, `canvas`, its leading hairline kept: `calendar` 15 pt `ink2` centred on the horizon line (y = 26); below, on the column's own fit of the same day (its timeline starting where the column's would), the day's busy events as 8 pt bars, centred, radius `r.xs` (3), in their inks; an unanswered invitation hollow (1 pt `ruleStrong`); the selected conversation's event with a 1 pt `selRule` outline 1 pt outside its bar; the now line and the selected mail's time as 2 pt lines (`ink`, and dashed `accent`) 3 pt in from its sides. Hover `canvas + hover` (glyph `ink`), pressed `canvas + pressed`. A click on it, or D, shows the column: in place when the window has room for it (the column was hidden, and is on again), otherwise opened whole **over the reader's trailing edge**, just before the strip: the column as it is in place, opaque `paper`, with `e2` (`overlayShadow`) and a hairline edge (`ruleStrong` in IC, §4.9), above the reader and below toasts; the strip stays `canvas + pressed` while it is open. Esc, D, a click on the strip or a click in the reader closes it (that click does nothing else), and focus that was in it returns to the list; widening the window until the column fits puts it in place. Tooltip “Show Day  D” (“Hide Day  D” while open); VoiceOver “Day, Thursday 19 November, 4 events, button”.

**The foot.** Nothing while every account's calendar is read. While some account has not granted the calendar permission, one line at the column's bottom (and the week's): a hairline above, 10 pt padding top and bottom, at x = 14, “Show events from your calendars” in `snippet` `ink2` (at most 2 lines), 6 pt, then a small secondary **Connect** that asks each account lacking it, one after another, with the reconnect that answering an invitation uses (§5.44); it shows its loading state while one is asked. For a Google account whose OAuth client has the Google Calendar API turned off: “Turn on the Google Calendar API for Contoso” (“for Contoso and 1 more”) and the link button **How to turn it on**, which opens the setup guide's step (docs/OAUTH-SETUP.md). A read that fails for any other reason keeps the stored events and says nothing; the next cycle tries again. The timeline's fit takes the foot's height off first.

**Keyboard.** All single keys are inactive while a field has focus, and an armed G-sequence keeps its own (G then D, G then T, §6).

| Key | In the main window |
|---|---|
| D | hides or shows the day column; in a window too narrow for it, opens or closes it over the reader's edge; while the week shows, goes back to the reader and the day |
| W | shows the week in the reader's place, or brings the reader and the day back |
| [ ] | the column's day back or forward; a week while the week shows. Only while the column (in full or over the reader) or the week shows. On a layout that types [ and ] with Option (German, Swiss, Nordic, French), those chords |
| T | today; this week while the week shows. Only then |
| B | time set aside for the selected conversation, as above; in reader windows too (§5.49) |
| Tab | after the quick reply (§3.4): ‹, Today, ›, the day cells as one stop (← → move the shown day, across weeks), each event in time order (and in the week day by day), the foot's button. ↩ or Space on an event opens its details (selects the conversation for a pencilled invitation from mail); in a details card Tab moves among its buttons |
| Esc | closes an event's details, the column opened over the reader's edge, or the week's invitation card, in that order; with none of them, focus in the column or the week returns to the list (§6.1) |
| Z, ⌘Z | undo time set aside or removed, as an archive is undone (§6.1) |

**VoiceOver.** The column is a group named for its day (“Day, Thursday 19 November”) holding the day cells as a tab group (“Monday 16 November, 3 events”, the shown one selected) and the events as a list in time order. Each event reads its title, its times with “to” (“13:00 to 14:00”), its account and its place, then what applies: “not answered”, “tentative”, “set aside for a mail”, “waiting to reach Google Calendar”, “couldn't be added”, “from the selected mail”, “overlaps Hiring sync”, “has a call”. The week is a grid of seven days, each column named by its heading (“Thursday 19 November”, a button that shows that day). Marks read “Comes back from Later at 17:00: Lease renewal” and “Sends at 16:00 while SuperSparrow is open: Follow-up”; the selected mail's time reads “From this mail, Friday 20 November at 15:00. Block 30 minutes, B”, a button. A fold reads “Nothing from 00:00 to 08:00”. Join reads “Join the call, Contract review”. Setting time aside and removing it are announced as their toasts are (§4.13).

| State | Look |
|---|---|
| Rest (accepted, or the user's own) | face and 3 pt edge in the account's ink; title `ink`, time and place `ink2` |
| Hover | `eventFace + hover`; time, place and glyphs to `ink`; the pointing hand (§4.17) |
| Pressed | `eventFace + pressed`, words `ink` |
| Selected (its details open) | the hover look, held until the card closes |
| Focused | the focus ring outside a 1 pt `paper` gap, radius 5 + the gap |
| Belongs to the selected conversation | the margin rule in place of the edge, drawn above its neighbours |
| Overlap (on the selected conversation's invitation) | the `warning` hatch over the time it shares; the card's overlap line says it in words (§5.14) |
| Not answered (pencilled: the provider's invitation not answered yet, or the selected mail's invitation drawn from the mail) | `paper` face, a 1 pt dashed `ruleStrong` outline (`pencilDash`), no ink and no edge, title in `label` italic `ink2`; hover `paper + hover` with the title `ink`. A hollow bar in the day cells and the strip |
| Tentative (maybe) | the accepted look with a 1 pt dashed outline in the account ink (`pencilDash`) around the face; “Tentative” in its details and VoiceOver |
| Declined | not drawn, not busy, never an overlap; its invitation's card keeps the answer (§5.14) |
| Free (shown as free) | drawn as its answer draws it, but never busy: B, a day cell's first free half hour, the tracks and overlaps pass over it |
| Creating (set aside on this Mac, not on the provider yet) | drawn as accepted, with `ss.queued` 12 pt `ink2` before its title until the provider has it |
| Failed (the provider refused it) | drawn as accepted, with `exclamationmark.triangle.fill` 12 pt `danger` before its title, until it is removed; its details say why and offer Remove |
| Being removed | not drawn |
| Window not key | the margin rule in `selRuleIdle`; Join in the secondary look; no focus ring; everything else (inks, faces, hatch, marks, the now line) as it is (§3.4) |

| Day cell state | Look |
|---|---|
| Rest | no face; weekday and date `ink3` |
| Hover | `hover`, words `ink` (never on the selected cell) |
| Pressed | `pressed`, words `ink` |
| Selected (the shown day) | `raised`, hairline edge, `e1`, words `ink` |
| Today | the date `metaStrong` `ink`, underlined |
| Focused | the ring around the selected cell, outside a 1 pt gap |
| Taking a drop | a 2 pt `focus` ring inside its edge |

Every surface and mark above is a tested pair in every theme and mode (§7): each account ink's event face under its title and time at rest, hovered and pressed, its own edge, the margin rule in both key states, the hatch and the failed glyph; the pencilled outline, the folds, the marks, the ghost and the strip in each of its states.

**Motion.** None. The column and the week show and hide, fold and open over the reader, turn their days and weeks and take new events in one frame, as the rail does (§4.10), under every setting; the details and the week's card appear and go at once, as a menu does. The now line moves once a minute as a redraw.

**Demo.** The demo's accounts have a made-up calendar for this week (§5.43), so the column, the week, a hatched overlap, the Later and Send Later marks and the now line show from the first launch, and snapshots show them.

---

## 6. Keyboard map

All single keys are inactive while a text field has focus. Every key press first finishes running animations (§4.10).

| Key | Action | Key | Action |
|---|---|---|---|
| J / K | next / previous conversation | E | archive |
| ⇧J / ⇧K | extend the selection | # | move to Trash (nothing in Trash, §5.12) |
| ! | mark as spam (§5.47; nothing in Trash or Drafts) | M | mute: archived now, new mail archived as it arrives; M again unmutes (§5.51) |
| ↩ | open the conversation in a reader window of its own, from the list (§5.49; on a focused control outside the list and the reader, ↩ is that control's or the window's; in Drafts, continue editing, §5.19; in the Outbox, continue editing a Send Later message still held, else show the row in the main window's reader, §5.53); in the reader ↩ opens nothing new: on a focused elision mark, Download button or Download all it presses it (§5.15, §5.17), on the focused recipients toggle it opens or folds it, and on a focused address in a sheet header (§5.14) it copies the address | S | star |
| → | open the conversation in the main window's reader, which takes the keyboard (in Drafts, continue editing, §5.19, and in the Outbox on a Send Later message still held, §5.53) | U | mark unread |
| Esc / ← | back to the list; in a reader window, Esc closes the window while its quick reply holds nothing (§6.1); ← and → move along the recipients of an open list while one has focus (§5.14) | | |
| N / P | next / previous message in the reader | Z or ⌘Z | undo |
| . | show / hide quoted text; on a message under an invitation card, the message (§5.14) | C or ⌘N | new message |
| R / A / F | reply / reply all / forward | / or ⌘F | search |
| ↩ (search field) | search the server for more while the list ends with its offer (§5.6, §5.10), then the list; ↓ only the list | | |
| ⌘O, a double-click on a row (⌘ held or not) | open the conversation in a reader window, as ↩ does (§5.49) | ⌘W | close the window |
| G I, G S, G T, G D, G #, G A | Inbox, Starred, Sent, Drafts, Trash, All Mail (HUD after 500 ms) | ⌘0 / ⌘1…⌘9 | All Inboxes / account |
| L | snooze: the Later menu (§5.45; nothing in Trash or Drafts) | G L, G O | Later, Outbox, each while its tile shows (§5.2, §5.53) |
| ⇧⌘R | open the quick reply in the composer | ⌘↩ | send: what Send does, Send and Archive unless the drop-down chose Send (§5.23) |
| ⇧⌘I / ⇧⌘O | load images / original colors | ⌃⌘S | show / hide the rail |
| ⌥⌘F | find in the conversation: the find bar (§5.50); ⌘F stays search | ⌘G / ⇧⌘G | next / previous match (↩ / ⇧↩ in the find bar) |
| ⌥⌘C | compact rows | ? or ⌘/ | keyboard shortcuts |
| ⌘P | print the open conversation (§5.48) | ⌘+ / ⌘− | reader text bigger / smaller, through the four Text sizes (§4.15) |
| ⇧⌘N | check for new mail | ⇧I | move to Inbox |
| ⇧⌘U | unsubscribe, then archive; in Later, end the snooze (§5.14) | ⇧⌘↩ | send and archive, whatever Send does (composer and quick reply, §5.23) |
| ⇧⌘L | Send Later: its times, hung from Send's drop-down (composer and quick reply, §5.46) | ⇧⌘D | save the target message's attachments to Downloads (§5.17) |
| D | day column: hide or show it; in a window too narrow for it, open or close it over the reader's edge; while the week shows, back to the reader and the day (§5.54) | W | the week in the reader's place, or the reader and the day back (§5.54) |
| [ / ] | previous / next day in the day column; previous / next week while the week shows (only while either shows, §5.54) | T | today; this week while the week shows (only while either shows) |
| B | block time for the selected conversation: 30 minutes at the time the mail names, else the day's first free half hour (§5.54; main window and reader windows) | | |
| ⇧⌘T, ⌘B ⌘I ⌘U, ⇧⌘8 ⇧⌘7, ⌘', ⌘K, ⌥⌘I | composer: format row, styles, lists, quote, link, insert picture (§5.20) | ⇧⌘A, ⇧⌘C, ⇧⌘B | composer: attach files, Cc field, Bcc field |
| Space | reader (focus in the reader, not in a text field): Quick Look the target message's attachments, starting from the focused chip, else the first; Space again closes Quick Look. On a focused elision mark (§5.15), Download button or Download all (§5.17) Space presses it instead, unless Quick Look is open. On a focused address in a sheet header Space copies it, and on the focused recipients toggle Space opens or folds it. With no attachments to preview the key passes to the web view, which scrolls down a page (⇧Space up), as in Safari. In the list Space does nothing | | |

**G-sequences** arm for 2000 ms from the G key-down; the HUD appears at 500 ms and leaves with the sequence (§5.32). An armed sequence keeps its keys: G then D is Drafts and G then T is Sent, never the day column or today. The cheat sheet (§5.32) lists every row of this map, one key per action.

### 6.1 Precedence: Esc, Z and ⌘Z

Several surfaces answer the same key. The first row that applies wins and consumes the key; nothing below it runs.

**Esc**

| # | When | Esc does |
|---|---|---|
| 1 | Autocomplete is open (composer) | closes it; the typed text stays |
| 2 | The link popover is open | cancels it |
| 3 | The cheat sheet or the g-sequence HUD is showing | closes it |
| 4 | An event's details are open in the day column or the week (§5.54) | closes them; focus returns to the event when the keyboard had opened them |
| 5 | The search field is first responder and holds a query | clears the query (focus stays) |
| 6 | The search field is first responder and is empty | returns focus to the list; the field collapses |
| 7 | The find bar's field is first responder | closes the find bar; the page takes the keyboard (§5.50) |
| 8 | A toast is visible in this window | dismisses the toast (Z still reaches its action for the grace period, and ⌘Z for as long as the undo history holds it) |
| 9 | The find bar is open and focus is in the page or on a reader button (not the quick reply, which keeps its text) | closes the find bar; focus stays in the reader |
| 10 | Focus is on a recipient, or on “and 24 more”, in a sheet's open list of recipients (§5.14) | folds the list; focus goes to its toggle |
| 11 | The day column is open over the reader's edge (§5.54) | closes it back to its strip; focus that was inside it returns to the list |
| 12 | The week shows the selected conversation's invitation card (§5.54) | hides the card until the selection changes or its event is clicked; the week stays (W leaves it) |
| 13 | Focus is in a reader window (§5.49) whose quick reply holds none of the user's work: no text typed (blank text counts as none, and so does text in a bar hidden since, its conversation emptied or gone to the Trash, which is kept with the conversation) and no reply counting down | closes the window, as ⌘W and the close button do; the next window opens at its size. A fresh press only: Esc's key repeat (the key held down) still takes the rows above, as a press does, but never closes a window, so holding Esc cannot close one window after another |
| 14 | Focus is in the reader, the quick reply, the day column or the week (main window) | returns focus to the list; the quick reply keeps its text. In a reader window whose quick reply holds the user's work, focus in the quick reply returns to the page, and on the page Esc does nothing (no beep), the window staying |
| 15 | Focus is on the list | nothing (no beep); the main window never closes on Esc, and the day column and the week stay until D or W |

So in the reader with a toast up, the first Esc dismisses the toast and the second returns to the list; with the find bar open as well, the second closes the bar and the third returns to the list; with focus in an open list of recipients, the first Esc folds it and the next returns to the list; with an event's details open over the reader and a toast up, the first Esc closes the details and the second dismisses the toast. In a reader window the same Esc that would return to the list closes the window instead, unless its quick reply holds the user's work: with a toast up in it, the first Esc dismisses the toast and the second closes the window. In a composer window Esc does rows 1–2; with no popover left to close, it closes a composer that holds nothing worth keeping (nothing typed, chosen or attached beyond the prefilled reply, its folded original and the signature, §5.20), keeping no draft, and does nothing in one that holds the user's work.

**⌘Z** (Edit › Undo, titled by its target)

| # | When | ⌘Z does |
|---|---|---|
| 1 | A text view or field is first responder and its undo manager can undo | undoes typing (“Undo Typing”) |
| 2 | An undo-send panel, a quick-reply countdown or an undoable toast is live | undoes the **most recent** of them: the panel or countdown cancels the send (“Undo Send”; “Undo Send and Archive” when the send archived its conversation, which comes back with it, §5.23), the toast reverts its action (“Undo Archive”). The undo-send panel shows its “⌘Z” keycap only while it is that target |
| 3 | Otherwise, while the undo history holds a step | reverts the latest step still in it, however old, and takes it out: each ⌘Z walks one step further back, newest first, through the last 50 steps (an archive, a star, a move to the Trash, a mark as read or unread, a snooze, a mute, time set aside or removed on a calendar, §5.54, every step that joins the history, toast or no toast). Edit › Undo names the step (“Undo Archive”, “Undo Star”, “Undo Move to Trash”) and stays enabled |
| 4 | Otherwise (the history is empty) | nothing; the menu item reads “Can't Undo” and is disabled |

**Z** (single key, main window or a reader window, no text field focused) only ever reverts the latest toast's action: while the toast shows (row 2, restricted to toasts), and for 10000 ms after it has gone, or after the action when it never had a toast (a star, one mark as unread). It never cancels a send and never reaches further back; only ⌘Z walks back through the history.

**The undo history** keeps the last 50 steps, a step being what one toast says (“Archived 3 conversations” is one step), and the 51st drops the oldest. Switching views, accounts or searches leaves it as it is. Removing an account takes that account's steps out of it; leaving or entering the demo closes the mailbox, and its history with it, since the demo's and the user's never mix. A step reverted long after it was taken puts back only what it changed and is still there: mail that arrived since stays where it is, and mail deleted since is left out. A step with nothing left to put back is dropped with a beep, and the next ⌘Z reaches the step before it.

Several live sends are cancelled newest first, one ⌘Z each. The order is the app's, not a window's (§5.49): Z and ⌘Z in a reader window see the same history, toast, undo-send panels and quick-reply countdowns (the main window's and every reader window's) as in the main window.

---

## 7. Verification: contrast and colour vision

Computed by the token generator from `tokens.json` with WCAG 2.x relative luminance. Alpha tokens are composited in sRGB over the surface beneath them first; “`a` + `b`” means `b` composited over `a`. Need is 4.5 for text and 3.0 for essential non-text UI (glyphs that carry state, state-bearing edges, focus rings, pips, rules, rings, toggle and checkbox fills). The pair list is every foreground-on-surface combination the components above produce, including hover and pressed washes, both selection washes, washes over washes, fills, slips and all account inks; it is stored as `contrastPairs` in `tokens.json` and asserted by `DesignContrastTests` (§8.7), so a token change that breaks a pair fails `swift test`. Four pairs are scan cues with a 1.25 floor. `selWash` on `paper` and on `sheet` make the current row easy to find, while the margin rule, asserted at 3:1, carries the state; `findWash` on `sheet` and `findCurrent` on `findWash` make matches and the current one easy to find, while the count and the current match's `ruleStrong` ring, asserted at 3:1, carry the state (§5.50). Eight pairs hold a swipe's fill against the row it is uncovered beside (§5.7): white at 4.5:1 on the fill leaves no fill 3:1 beside a selected row at night, so each row has floors of its own, Archive's above Read's, and the white icon and label on the fill, asserted at 4.5:1, name the button. Account-ink pairs carry two needs, 3 in Light and Dark and 3.5 in the IC modes (`needIC`), and the test asserts each mode against its own.

**Result:** 662 pairs × 4 modes = 2648 checks, plus 123 Graphite pairs × 4 = 492, 0 failures (4 of the pairs are scan cues with a 1.25 floor; 8 hold a swipe's fill beside its row, Archive's floors above Read's, §5.7; account inks need 3.0, or 3.5 in IC; the rest need 4.5 or 3.0). Smallest margins: Checkbox / radio on fill vs sheet 3.01 (Dark IC, needs 3.0); Toggle on track vs sheet (rest, hover and pressed: the track never takes a wash) 3.01 (Dark IC, needs 3.0); Account ink Jade on selected row 3.52 (Dark IC, needs 3.5); Account ink Lilac on hovered rail tile 3.56 (Light IC, needs 3.5); Account ink Lilac on selected row 3.56 (Light IC, needs 3.5); Account ink Azure on hovered rail tile 3.57 (Light IC, needs 3.5).

**Themes** (§4.16): 5 themes × 662 pairs × 4 modes = 13,240 checks, plus 5 × 123 Graphite pairs × 4 = 2,460, plus the theme rules, 0 failures. The pairs below are listed with Study's values; every theme asserts the same pairs against its own table, per mode, with the theme rules beside them (`ThemeRuleTests`), and §4.16 gives each theme's tightest pair. 1.8.0 adds two pairs, the chosen theme tile's underline on the Settings desk (`selRule` and `selRuleIdle` on `canvas`). 1.8.2 adds the header's copy targets (§5.14): a recipient's name and address on `sheet + hover` and on `sheet + pressed`, and the copied mark on `sheet + pressed`. 1.9.0 adds the day column and the week (§5.54): for each of the ten inks, twelve pairs on the surfaces only the calendar draws (the title on its **event face**, `eventFace:<Ink>`, the ink at 0.13 over `sheet`, at rest, hovered and pressed, and the time and place on it; the ink's own edge, the selected conversation's margin rule in both key states, the overlap hatch and the failed glyph on it; the ink on a pressed day cell and on the folded strip hovered and pressed), and the rest once: the pencilled outline and title, the folds, the now line, the marks and the selected mail's time, the drop ghost, the strip's marks, the details' and the week's card's kicker, and the invitation card's overlap line and glyph (§5.14). `eventFace` is composited as `accountFace` is, by `build.py`, `verify_tokens.py` and the tests' `TokenResolver`.

Not tested on purpose: `inkDisabled` (disabled text and glyphs are exempt), decorative `rule` hairlines (they separate, they do not carry state), the toggle knob's face against the off track (its `ruleStrong` edge is the tested boundary), the popup halo against a hovered or pressed face (the halo is the ink's surface, not a mark), swatches inside the open Colour menu (the item's title names the ink), the cheat-sheet `scrim` and `scrimSolid` (they sit behind the panel and carry nothing), avatar faces and the account face wash against their surroundings (decorative; the initials on them are tested), and system-drawn chrome: menus and their badges, alerts, notifications, tooltips, and the Settings toolbar with its tabs. Every control inside Settings is Quire-drawn and tested. Bodies shown in Original colors are the sender's design on the `originalPage` inset and are not Quire pairs; adapted bodies use only tested inks (§5.14). The account square and the initial tile's edge are drawn in the account ink and are covered by the account-ink rows below, never by a `ruleStrong` pair.

**Colour vision** (account inks, Machado 2009 at full severity, CIEDE2000): see the tables in §4.2. Assertions in `AccountPaletteTests`: first six ≥ 13 for every vision type in all four modes (standard-contrast target ≥ 14, met); all ten ≥ 13 for normal vision; every ink ≥ 15 from every theme's `accent` (Gallery's read as under Graphite, §4.16), ≥ 10 from `danger` under every simulation, ≥ 10 from `info`, ≥ 8 from `star`.

| Pair | Foreground | Background (composited left to right) | Need | Light | Dark | Light IC | Dark IC |  |
|---|---|---|---|---|---|---|---|---|
| Row sender/subject, rest | `ink` | `paper` | 4.5 | 16.45 | 14.23 | 18.82 | 18.86 | pass |
| Row sender/subject, hover | `ink` | `paper` + `hover` | 4.5 | 15.00 | 12.45 | 16.36 | 15.02 | pass |
| Row sender/subject, selected (window key) | `ink` | `selWash` | 4.5 | 12.66 | 9.94 | 12.81 | 11.21 | pass |
| Row sender/subject, selected (window not key) | `ink` | `selWashIdle` | 4.5 | 13.90 | 12.00 | 13.56 | 13.70 | pass |
| Row snippet, rest | `ink2` | `paper` | 4.5 | 7.64 | 8.18 | 11.69 | 13.16 | pass |
| Row snippet, hover | `ink2` | `paper` + `hover` | 4.5 | 6.97 | 7.15 | 10.16 | 10.48 | pass |
| Row snippet, selected | `ink2` | `selWash` | 4.5 | 5.88 | 5.71 | 7.96 | 7.82 | pass |
| Row snippet, selected idle | `ink2` | `selWashIdle` | 4.5 | 6.46 | 6.89 | 8.42 | 9.56 | pass |
| Row time (read), rest | `ink3` | `paper` | 4.5 | 6.32 | 6.79 | 9.24 | 10.66 | pass |
| Row time (read), hover | `ink3` | `paper` + `hover` | 4.5 | 5.76 | 5.94 | 8.03 | 8.48 | pass |
| Row time (read), selected | `ink3` | `selWash` | 4.5 | 4.86 | 4.74 | 6.29 | 6.33 | pass |
| Row time (read), selected idle | `ink3` | `selWashIdle` | 4.5 | 5.34 | 5.72 | 6.66 | 7.74 | pass |
| Row time (unread, Iron Gall Semibold), rest | `accent` | `paper` | 4.5 | 7.97 | 7.53 | 11.24 | 11.38 | pass |
| Row time (unread), hover | `accent` | `paper` + `hover` | 4.5 | 7.27 | 6.59 | 9.77 | 9.06 | pass |
| Row time (unread), selected | `accent` | `selWash` | 4.5 | 6.13 | 5.26 | 7.65 | 6.76 | pass |
| Row time (unread), selected idle | `accent` | `selWashIdle` | 4.5 | 6.74 | 6.35 | 8.10 | 8.26 | pass |
| Row time (Outbox, failed send), rest | `danger` | `paper` | 4.5 | 6.38 | 7.57 | 8.94 | 10.55 | pass |
| Row time (Outbox, failed send), hover | `danger` | `paper` + `hover` | 4.5 | 5.82 | 6.62 | 7.77 | 8.40 | pass |
| Row time (Outbox, failed send), selected | `danger` | `selWash` | 4.5 | 4.91 | 5.29 | 6.09 | 6.27 | pass |
| Row time (Outbox, failed send), selected idle | `danger` | `selWashIdle` | 4.5 | 5.39 | 6.38 | 6.44 | 7.66 | pass |
| Row count badge numerals, rest | `ink2` | `paper` + `fill` | 4.5 | 6.80 | 6.71 | 9.76 | 9.47 | pass |
| Row count badge numerals, hover | `ink2` | `paper` + `hover` + `fill` | 4.5 | 6.21 | 5.77 | 8.52 | 7.13 | pass |
| Row count badge numerals, selected | `ink2` | `selWash` + `fill` | 4.5 | 5.26 | 4.62 | 6.72 | 5.44 | pass |
| Row count badge numerals, selected idle | `ink2` | `selWashIdle` + `fill` | 4.5 | 5.77 | 5.55 | 7.10 | 6.50 | pass |
| Tag text on the selected Settings account row | `ink2` | `selWash` | 4.5 | 5.88 | 5.71 | 7.96 | 7.82 | pass |
| Tag text on the selected Settings account row, window not key | `ink2` | `selWashIdle` | 4.5 | 6.46 | 6.89 | 8.42 | 9.56 | pass |
| Tag edge on the selected Settings account row | `ruleStrong` | `selWash` | 3 | 3.18 | 3.29 | 4.61 | 4.16 | pass |
| Tag edge on the selected Settings account row, window not key | `ruleStrong` | `selWashIdle` | 3 | 3.49 | 3.97 | 4.88 | 5.09 | pass |
| Unread pip, rest | `accent` | `paper` | 3 | 7.97 | 7.53 | 11.24 | 11.38 | pass |
| Unread pip, hover | `accent` | `paper` + `hover` | 3 | 7.27 | 6.59 | 9.77 | 9.06 | pass |
| Unread pip, selected | `accent` | `selWash` | 3 | 6.13 | 5.26 | 7.65 | 6.76 | pass |
| Unread pip, selected idle | `accent` | `selWashIdle` | 3 | 6.74 | 6.35 | 8.10 | 8.26 | pass |
| Star glyph, rest | `star` | `paper` | 3 | 6.43 | 8.59 | 9.18 | 11.57 | pass |
| Star glyph, hover | `star` | `paper` + `hover` | 3 | 5.86 | 7.52 | 7.98 | 9.21 | pass |
| Star glyph, selected | `star` | `selWash` | 3 | 4.95 | 6.00 | 6.25 | 6.87 | pass |
| Star glyph, selected idle | `star` | `selWashIdle` | 3 | 5.43 | 7.24 | 6.61 | 8.40 | pass |
| Paperclip glyph, rest | `ink2` | `paper` | 3 | 7.64 | 8.18 | 11.69 | 13.16 | pass |
| Paperclip glyph, selected | `ink2` | `selWash` | 3 | 5.88 | 5.71 | 7.96 | 7.82 | pass |
| Queued glyph (ss.queued), rest | `ink3` | `paper` | 3 | 6.32 | 6.79 | 9.24 | 10.66 | pass |
| Queued glyph, hover | `ink3` | `paper` + `hover` | 3 | 5.76 | 5.94 | 8.03 | 8.48 | pass |
| Queued glyph, selected | `ink3` | `selWash` | 3 | 4.86 | 4.74 | 6.29 | 6.33 | pass |
| Queued glyph, selected idle | `ink3` | `selWashIdle` | 3 | 5.34 | 5.72 | 6.66 | 7.74 | pass |
| Failed glyph (danger), rest | `danger` | `paper` | 3 | 6.38 | 7.57 | 8.94 | 10.55 | pass |
| Failed glyph, selected | `danger` | `selWash` | 3 | 4.91 | 5.29 | 6.09 | 6.27 | pass |
| Failed glyph, selected idle | `danger` | `selWashIdle` | 3 | 5.39 | 6.38 | 6.44 | 7.66 | pass |
| Selection wash vs list (scan cue for j/k, with the rule) | `selWash` | `paper` | 1.25 | 1.30 | 1.43 | 1.47 | 1.68 | pass |
| Margin rule vs selection wash | `selRule` | `selWash` | 3 | 6.13 | 5.26 | 7.65 | 6.76 | pass |
| Margin rule vs adjacent paper | `selRule` | `paper` | 3 | 7.97 | 7.53 | 11.24 | 11.38 | pass |
| Idle margin rule vs idle wash | `selRuleIdle` | `selWashIdle` | 3 | 5.34 | 5.72 | 6.66 | 7.74 | pass |
| Idle margin rule vs adjacent paper | `selRuleIdle` | `paper` | 3 | 6.32 | 6.79 | 9.24 | 10.66 | pass |
| Running head label | `ink3` | `paper` | 4.5 | 6.32 | 6.79 | 9.24 | 10.66 | pass |
| Account initial tile letter, rest | `ink2` | `paper` | 4.5 | 7.64 | 8.18 | 11.69 | 13.16 | pass |
| Account initial tile letter, hover | `ink2` | `paper` + `hover` | 4.5 | 6.97 | 7.15 | 10.16 | 10.48 | pass |
| Account initial tile letter, selected | `ink2` | `selWash` | 4.5 | 5.88 | 5.71 | 7.96 | 7.82 | pass |
| Account initial tile letter, selected idle | `ink2` | `selWashIdle` | 4.5 | 6.46 | 6.89 | 8.42 | 9.56 | pass |
| Swipe button icon and label (white) on Archive's fill | `onSwipe` | `swipeArchive` | 4.5 | 8.32 | 5.03 | 11.53 | 5.71 | pass |
| Swipe button icon and label (white) on Mark as Read or Mark as Unread's fill | `onSwipe` | `swipeRead` | 4.5 | 5.19 | 8.36 | 6.60 | 8.77 | pass |
| Swipe Archive fill beside the row, rest | `swipeArchive` | `paper` | 3 | 7.97 | 3.42 | 11.24 | 3.30 | pass |
| Swipe Archive fill beside the row, hover | `swipeArchive` | `paper` + `hover` | 2.5 | 7.27 | 2.99 | 9.77 | 2.63 | pass |
| Swipe Archive fill beside the row, selected | `swipeArchive` | `selWash` | 1.9 | 6.13 | 2.39 | 7.65 | 1.96 | pass |
| Swipe Archive fill beside the row, selected idle | `swipeArchive` | `selWashIdle` | 2.3 | 6.74 | 2.88 | 8.10 | 2.40 | pass |
| Swipe Mark as Read or Unread fill beside the row, rest | `swipeRead` | `paper` | 2 | 4.97 | 2.06 | 6.44 | 2.15 | pass |
| Swipe Mark as Read or Unread fill beside the row, hover | `swipeRead` | `paper` + `hover` | 1.6 | 4.53 | 1.80 | 5.60 | 1.71 | pass |
| Swipe Mark as Read or Unread fill beside the row, selected | `swipeRead` | `selWash` | 1.2 | 3.82 | 1.44 | 4.38 | 1.28 | pass |
| Swipe Mark as Read or Unread fill beside the row, selected idle | `swipeRead` | `selWashIdle` | 1.5 | 4.20 | 1.74 | 4.64 | 1.56 | pass |
| Masthead | `ink` | `paper` | 4.5 | 16.45 | 14.23 | 18.82 | 18.86 | pass |
| Masthead chevron, compose glyph | `ink2` | `paper` | 3 | 7.64 | 8.18 | 11.69 | 13.16 | pass |
| Masthead hover text | `ink` | `paper` + `hover` | 4.5 | 15.00 | 12.45 | 16.36 | 15.02 | pass |
| Demo tag text | `ink2` | `paper` | 4.5 | 7.64 | 8.18 | 11.69 | 13.16 | pass |
| Demo tag edge | `ruleStrong` | `paper` | 3 | 4.13 | 4.71 | 6.77 | 7.01 | pass |
| Demo tag, hover | `ink` | `paper` + `hover` | 4.5 | 15.00 | 12.45 | 16.36 | 15.02 | pass |
| List tail footer text and spinner | `ink3` | `paper` | 4.5 | 6.32 | 6.79 | 9.24 | 10.66 | pass |
| Search placeholder | `ink3` | `sheet` | 4.5 | 6.54 | 6.26 | 9.47 | 9.72 | pass |
| Search query text | `ink` | `sheet` | 4.5 | 17.04 | 13.11 | 19.29 | 17.21 | pass |
| Search glyph | `ink3` | `sheet` | 3 | 6.54 | 6.26 | 9.47 | 9.72 | pass |
| Search resting edge vs list | `ruleStrong` | `paper` | 3 | 4.13 | 4.71 | 6.77 | 7.01 | pass |
| Search resting edge vs field | `ruleStrong` | `sheet` | 3 | 4.28 | 4.34 | 6.94 | 6.39 | pass |
| Search hover face | `ink3` | `sheet` + `hover` | 4.5 | 5.97 | 5.42 | 8.23 | 7.50 | pass |
| Search clear disc glyph | `ink2` | `sheet` + `fill` | 3 | 7.04 | 6.10 | 10.01 | 8.33 | pass |
| Sync line text | `ink3` | `paper` | 4.5 | 6.32 | 6.79 | 9.24 | 10.66 | pass |
| Sync line lead phrase | `ink2` | `paper` | 4.5 | 7.64 | 8.18 | 11.69 | 13.16 | pass |
| Sync line warning glyph | `warning` | `paper` | 3 | 6.28 | 8.56 | 9.13 | 11.53 | pass |
| Sync line error text and glyph | `danger` | `paper` | 4.5 | 6.38 | 7.57 | 8.94 | 10.55 | pass |
| Sync line action link | `accent` | `paper` | 4.5 | 7.97 | 7.53 | 11.24 | 11.38 | pass |
| Contrail (sync progress) vs list | `accent` | `paper` | 3 | 7.97 | 7.53 | 11.24 | 11.38 | pass |
| Empty-state sentence (reader desk) | `ink` | `canvas` | 4.5 | 15.35 | 14.94 | 16.78 | 19.54 | pass |
| Empty-state hint (reader desk) | `ink3` | `canvas` | 4.5 | 5.90 | 7.13 | 8.24 | 11.04 | pass |
| Empty-state sentence (list) | `ink` | `paper` | 4.5 | 16.45 | 14.23 | 18.82 | 18.86 | pass |
| Rail folder and All Inboxes glyphs | `ink2` | `spine` | 3 | 6.58 | 8.96 | 9.09 | 13.98 | pass |
| Rail folder and All Inboxes glyphs, hover | `ink` | `spine` + `hover` | 3 | 12.94 | 13.93 | 12.79 | 16.63 | pass |
| Rail folder and All Inboxes glyphs, selected tile | `ink` | `raised` | 3 | 17.18 | 11.84 | 19.29 | 15.67 | pass |
| Rail folder and All Inboxes glyphs, pressed | `ink` | `spine` + `pressed` | 3 | 11.88 | 12.31 | 11.37 | 13.82 | pass |
| Rail utility glyphs, hover | `ink` | `spine` + `hover` | 3 | 12.94 | 13.93 | 12.79 | 16.63 | pass |
| Rail utility glyphs, pressed | `ink` | `spine` + `pressed` | 3 | 11.88 | 12.31 | 11.37 | 13.82 | pass |
| Rail sign-in spinner (pending tile) | `ink3` | `spine` | 3 | 5.44 | 7.44 | 7.19 | 11.32 | pass |
| Rail pending tile edge | `ruleStrong` | `spine` | 3 | 3.56 | 5.15 | 5.26 | 7.44 | pass |
| Rail utility glyphs (Add, Settings) | `ink2` | `spine` | 3 | 6.58 | 8.96 | 9.09 | 13.98 | pass |
| Rail margin rule | `selRule` | `spine` | 3 | 6.86 | 8.25 | 8.74 | 12.09 | pass |
| Rail idle margin rule | `selRuleIdle` | `spine` | 3 | 5.44 | 7.44 | 7.19 | 11.32 | pass |
| Rail unread badge fill vs rail | `accentFill` | `spine` | 3 | 6.86 | 3.75 | 8.74 | 3.51 | pass |
| Rail unread badge numerals | `onAccent` | `accentFill` | 4.5 | 8.32 | 5.03 | 11.53 | 5.71 | pass |
| Rail attention badge fill vs rail | `dangerFill` | `spine` | 3 | 5.49 | 3.47 | 6.96 | 3.68 | pass |
| Rail attention badge glyph | `onDanger` | `dangerFill` | 4.5 | 6.67 | 5.44 | 9.17 | 5.44 | pass |
| Rail focus ring | `focus` | `spine` | 3 | 6.86 | 8.25 | 8.74 | 12.09 | pass |
| Minimal-mode new-mail dot | `accent` | `paper` | 3 | 7.97 | 7.53 | 11.24 | 11.38 | pass |
| Reader kicker | `ink3` | `paper` | 4.5 | 6.32 | 6.79 | 9.24 | 10.66 | pass |
| Reader headline | `ink` | `paper` | 4.5 | 16.45 | 14.23 | 18.82 | 18.86 | pass |
| Reader header action glyphs | `ink2` | `paper` | 3 | 7.64 | 8.18 | 11.69 | 13.16 | pass |
| Reader header action glyphs, hover | `ink` | `paper` + `hover` | 3 | 15.00 | 12.45 | 16.36 | 15.02 | pass |
| Reader header star (on) | `star` | `paper` | 3 | 6.43 | 8.59 | 9.18 | 11.57 | pass |
| Participants line on desk | `ink2` | `canvas` | 4.5 | 7.13 | 8.59 | 10.42 | 13.64 | pass |
| Stack name | `ink` | `sheet` | 4.5 | 17.04 | 13.11 | 19.29 | 17.21 | pass |
| Stack snippet | `ink2` | `sheet` | 4.5 | 7.91 | 7.53 | 11.99 | 12.01 | pass |
| Stack date | `ink3` | `sheet` | 4.5 | 6.54 | 6.26 | 9.47 | 9.72 | pass |
| Stack row hover snippet | `ink2` | `sheet` + `hover` | 4.5 | 7.21 | 6.52 | 10.42 | 9.26 | pass |
| Stack row hover date | `ink3` | `sheet` + `hover` | 4.5 | 5.97 | 5.42 | 8.23 | 7.50 | pass |
| Stack unread pip | `accent` | `sheet` | 3 | 8.25 | 6.94 | 11.53 | 10.38 | pass |
| Fold row label (4 more messages) | `ink2` | `sheet` | 4.5 | 7.91 | 7.53 | 11.99 | 12.01 | pass |
| Message header name, body text | `ink` | `sheet` | 4.5 | 17.04 | 13.11 | 19.29 | 17.21 | pass |
| Message recipients | `ink2` | `sheet` | 4.5 | 7.91 | 7.53 | 11.99 | 12.01 | pass |
| Message date, address on hover | `ink3` | `sheet` | 4.5 | 6.54 | 6.26 | 9.47 | 9.72 | pass |
| Header recipient, hover (name and address) | `ink` | `sheet` + `hover` | 4.5 | 15.53 | 11.36 | 16.77 | 13.27 | pass |
| Header recipient, pressed | `ink` | `sheet` + `pressed` | 4.5 | 14.22 | 9.91 | 14.83 | 10.86 | pass |
| Copied mark (glyph and word), pressed | `ink` | `sheet` + `pressed` | 4.5 | 14.22 | 9.91 | 14.83 | 10.86 | pass |
| Header hover actions | `ink2` | `sheet` | 3 | 7.91 | 7.53 | 11.99 | 12.01 | pass |
| Header hover actions, hover | `ink` | `sheet` + `hover` | 3 | 15.53 | 11.36 | 16.77 | 13.27 | pass |
| Original colors action (on) | `accent` | `accentWash` | 3 | 6.65 | 5.56 | 8.11 | 6.76 | pass |
| Original colors action (on), hover | `accent` | `accentWashHover` | 3 | 6.24 | 5.04 | 7.52 | 5.84 | pass |
| Original colors action (on), pressed | `accent` | `accentWashPressed` | 3 | 5.81 | 6.28 | 6.90 | 7.78 | pass |
| Message starred mark (name line) | `star` | `sheet` | 3 | 6.66 | 7.92 | 9.41 | 10.56 | pass |
| Stack row starred mark | `star` | `sheet` | 3 | 6.66 | 7.92 | 9.41 | 10.56 | pass |
| Stack row starred mark, hover | `star` | `sheet` + `hover` | 3 | 6.07 | 6.86 | 8.18 | 8.14 | pass |
| Fold row label, hover | `ink` | `sheet` + `hover` | 4.5 | 15.53 | 11.36 | 16.77 | 13.27 | pass |
| Target message sheet edge vs desk | `ruleStrong` | `canvas` | 3 | 3.85 | 4.94 | 6.03 | 7.26 | pass |
| Target message footer keycap legend | `ink2` | `raised` | 4.5 | 7.98 | 6.80 | 11.99 | 10.94 | pass |
| No-subject placeholder, reader headline | `ink3` | `paper` | 4.5 | 6.32 | 6.79 | 9.24 | 10.66 | pass |
| No-messages state on desk | `ink3` | `canvas` | 4.5 | 5.90 | 7.13 | 8.24 | 11.04 | pass |
| Quoted toggle label (folded) | `ink2` | `sheet` + `fill` | 4.5 | 7.04 | 6.10 | 10.01 | 8.33 | pass |
| Quoted toggle label, hover | `ink` | `sheet` + `fill` + `hover` | 4.5 | 13.85 | 9.13 | 14.05 | 9.03 | pass |
| Quoted toggle label (unfolded) | `accent` | `accentWash` | 4.5 | 6.65 | 5.56 | 8.11 | 6.76 | pass |
| Quoted toggle label (unfolded), hover | `accent` | `accentWashHover` | 4.5 | 6.24 | 5.04 | 7.52 | 5.84 | pass |
| Quoted toggle label (unfolded), pressed | `accent` | `accentWashPressed` | 4.5 | 5.81 | 6.28 | 6.90 | 7.78 | pass |
| Quoted toggle label (folded), pressed | `ink` | `sheet` + `fill` + `pressed` | 4.5 | 12.70 | 7.98 | 12.46 | 7.50 | pass |
| Find bar field text | `ink` | `sheet` | 4.5 | 17.04 | 13.11 | 19.29 | 17.21 | pass |
| Find bar placeholder and count | `ink3` | `sheet` | 4.5 | 6.54 | 6.26 | 9.47 | 9.72 | pass |
| Find bar field edge | `ruleStrong` | `raised` | 3 | 4.31 | 3.91 | 6.94 | 5.82 | pass |
| Find bar buttons | `ink2` | `raised` | 3 | 7.98 | 6.80 | 11.99 | 10.94 | pass |
| Find bar buttons, hover | `ink` | `raised` + `hover` | 3 | 15.66 | 10.19 | 16.77 | 11.90 | pass |
| Find bar buttons, pressed | `ink` | `raised` + `pressed` | 3 | 14.34 | 8.89 | 14.83 | 9.74 | pass |
| Find match text | `ink` | `findWash` | 4.5 | 12.95 | 10.11 | 13.70 | 11.14 | pass |
| Find current match text | `ink` | `findCurrent` | 4.5 | 9.86 | 4.82 | 9.75 | 6.37 | pass |
| Find current match ring | `ruleStrong` | `sheet` | 3 | 4.28 | 4.34 | 6.94 | 6.39 | pass |
| Find match wash vs the page (a scan cue: the count says how many) | `findWash` | `sheet` | 1.25 | 1.32 | 1.30 | 1.41 | 1.54 | pass |
| Find current match vs the other matches (a scan cue: the ring carries the state) | `findCurrent` | `findWash` | 1.25 | 1.31 | 2.10 | 1.40 | 1.75 | pass |
| Remote-images banner text | `ink` | `sheet` + `fill` | 4.5 | 15.17 | 10.62 | 16.10 | 11.94 | pass |
| Remote-images banner glyph | `ink2` | `sheet` + `fill` | 3 | 7.04 | 6.10 | 10.01 | 8.33 | pass |
| Load images link, rest and hover (hover adds the underline; link buttons never take a wash) | `accent` | `sheet` + `fill` | 4.5 | 7.35 | 5.62 | 9.62 | 7.20 | pass |
| Load images link, pressed (ink2 with the underline, no wash) | `ink2` | `sheet` + `fill` | 4.5 | 7.04 | 6.10 | 10.01 | 8.33 | pass |
| Original colors banner text | `ink` | `warningWash` | 4.5 | 14.65 | 11.78 | 14.41 | 12.61 | pass |
| Original colors banner glyph | `warning` | `warningWash` | 3 | 5.59 | 7.09 | 7.00 | 7.71 | pass |
| Original colors notice action | `ink` | `warningWash` | 4.5 | 14.65 | 11.78 | 14.41 | 12.61 | pass |
| Original colors notice action, hover | `ink` | `warningWash` + `hover` | 4.5 | 13.38 | 10.15 | 12.60 | 9.54 | pass |
| Original colors notice action, pressed | `ink` | `warningWash` + `pressed` | 4.5 | 12.28 | 8.86 | 11.21 | 7.91 | pass |
| Original colors notice dismiss glyph | `ink2` | `warningWash` | 3 | 6.80 | 6.77 | 8.95 | 8.80 | pass |
| Attachment name | `ink` | `sheet` | 4.5 | 17.04 | 13.11 | 19.29 | 17.21 | pass |
| Attachment meta | `ink3` | `sheet` | 4.5 | 6.54 | 6.26 | 9.47 | 9.72 | pass |
| Attachment meta, hover | `ink3` | `sheet` + `hover` | 4.5 | 5.97 | 5.42 | 8.23 | 7.50 | pass |
| Attachment type glyph | `ink2` | `sheet` + `fill` | 3 | 7.04 | 6.10 | 10.01 | 8.33 | pass |
| Attachment error text | `danger` | `sheet` | 4.5 | 6.61 | 6.97 | 9.17 | 9.62 | pass |
| Attachment progress fill | `accent` | `sheet` | 3 | 8.25 | 6.94 | 11.53 | 10.38 | pass |
| Attachment hover edge | `ruleStrong` | `sheet` | 3 | 4.28 | 4.34 | 6.94 | 6.39 | pass |
| Attachment Download glyph | `ink2` | `sheet` | 3 | 7.91 | 7.53 | 11.99 | 12.01 | pass |
| Attachment Download glyph, chip hovered | `ink2` | `sheet` + `hover` | 3 | 7.21 | 6.52 | 10.42 | 9.26 | pass |
| Attachment Download glyph, hover | `ink` | `sheet` + `hover` + `hover` | 3 | 14.17 | 9.76 | 14.61 | 10.00 | pass |
| Attachment Download glyph, pressed | `ink` | `sheet` + `hover` + `pressed` | 3 | 13.00 | 8.52 | 12.96 | 8.25 | pass |
| Attachment count line | `ink3` | `sheet` | 4.5 | 6.54 | 6.26 | 9.47 | 9.72 | pass |
| Footer ghost buttons | `ink2` | `sheet` | 4.5 | 7.91 | 7.53 | 11.99 | 12.01 | pass |
| Footer ghost buttons, hover | `ink` | `sheet` + `hover` | 4.5 | 15.53 | 11.36 | 16.77 | 13.27 | pass |
| Body failed message | `danger` | `sheet` | 4.5 | 6.61 | 6.97 | 9.17 | 9.62 | pass |
| Body preview while offline (snippet in ink2) | `ink2` | `sheet` | 4.5 | 7.91 | 7.53 | 11.99 | 12.01 | pass |
| Offline body notice text | `ink` | `sheet` + `fill` | 4.5 | 15.17 | 10.62 | 16.10 | 11.94 | pass |
| Offline body notice glyph (wifi.slash) | `ink2` | `sheet` + `fill` | 3 | 7.04 | 6.10 | 10.01 | 8.33 | pass |
| Card focus ring on desk | `focus` | `canvas` | 3 | 7.43 | 7.91 | 10.02 | 11.79 | pass |
| Reader multi-select hint | `ink2` | `canvas` | 4.5 | 7.13 | 8.59 | 10.42 | 13.64 | pass |
| Quick reply placeholder | `ink3` | `sheet` | 4.5 | 6.54 | 6.26 | 9.47 | 9.72 | pass |
| Quick reply text | `ink` | `sheet` | 4.5 | 17.04 | 13.11 | 19.29 | 17.21 | pass |
| Quick reply field edge | `ruleStrong` | `paper` | 3 | 4.13 | 4.71 | 6.77 | 7.01 | pass |
| Quick reply keycap legend | `ink2` | `raised` | 4.5 | 7.98 | 6.80 | 11.99 | 10.94 | pass |
| Quick reply mode, active label | `ink` | `sheet` | 4.5 | 17.04 | 13.11 | 19.29 | 17.21 | pass |
| Quick reply mode, active underline | `ink` | `sheet` | 3 | 17.04 | 13.11 | 19.29 | 17.21 | pass |
| Quick reply mode, active underline, window not key | `ink3` | `sheet` | 3 | 6.54 | 6.26 | 9.47 | 9.72 | pass |
| Quick reply mode, inactive label | `ink2` | `sheet` | 4.5 | 7.91 | 7.53 | 11.99 | 12.01 | pass |
| Quick reply tool glyphs | `ink2` | `sheet` | 3 | 7.91 | 7.53 | 11.99 | 12.01 | pass |
| Quick reply tool glyphs, hover | `ink` | `sheet` + `hover` | 3 | 15.53 | 11.36 | 16.77 | 13.27 | pass |
| Quick reply strip text (Sending in 4 s) | `ink` | `sheet` | 4.5 | 17.04 | 13.11 | 19.29 | 17.21 | pass |
| Quick reply strip detail | `ink3` | `sheet` | 4.5 | 6.54 | 6.26 | 9.47 | 9.72 | pass |
| Quick reply strip glyph | `ink2` | `sheet` | 3 | 7.91 | 7.53 | 11.99 | 12.01 | pass |
| Quick reply strip contrail | `accent` | `sheet` | 3 | 8.25 | 6.94 | 11.53 | 10.38 | pass |
| Quick reply notice warning glyph | `warning` | `sheet` | 3 | 6.50 | 7.89 | 9.37 | 10.52 | pass |
| Quick reply error edge and text | `danger` | `sheet` | 4.5 | 6.61 | 6.97 | 9.17 | 9.62 | pass |
| Composer field labels | `ink3` | `paper` | 4.5 | 6.32 | 6.79 | 9.24 | 10.66 | pass |
| Composer format toggle glyph (off) | `ink2` | `paper` | 3 | 7.64 | 8.18 | 11.69 | 13.16 | pass |
| Composer format toggle glyph, hover | `ink` | `paper` + `hover` | 3 | 15.00 | 12.45 | 16.36 | 15.02 | pass |
| Composer format toggle glyph (on) | `accent` | `accentWash` | 3 | 6.65 | 5.56 | 8.11 | 6.76 | pass |
| Composer format toggle glyph (on), hover | `accent` | `accentWashHover` | 3 | 6.24 | 5.04 | 7.52 | 5.84 | pass |
| Composer body link | `accent` | `sheet` | 4.5 | 8.25 | 6.94 | 11.53 | 10.38 | pass |
| Composer block quote text | `ink2` | `sheet` | 4.5 | 7.91 | 7.53 | 11.99 | 12.01 | pass |
| Composer list marker | `ink2` | `sheet` | 4.5 | 7.91 | 7.53 | 11.99 | 12.01 | pass |
| Composer status warning glyph | `warning` | `paper` | 3 | 6.28 | 8.56 | 9.13 | 11.53 | pass |
| Composer status text | `ink2` | `paper` | 4.5 | 7.64 | 8.18 | 11.69 | 13.16 | pass |
| Link popover field edge | `ruleStrong` | `raised` | 3 | 4.31 | 3.91 | 6.94 | 5.82 | pass |
| Link popover field text | `ink` | `sheet` | 4.5 | 17.04 | 13.11 | 19.29 | 17.21 | pass |
| Link popover label | `ink3` | `raised` | 4.5 | 6.60 | 5.65 | 9.47 | 8.85 | pass |
| Composer values | `ink` | `paper` | 4.5 | 16.45 | 14.23 | 18.82 | 18.86 | pass |
| Composer body text | `ink` | `sheet` | 4.5 | 17.04 | 13.11 | 19.29 | 17.21 | pass |
| Composer folded-original caption | `ink3` | `sheet` | 4.5 | 6.54 | 6.26 | 9.47 | 9.72 | pass |
| Composer draft status | `ink3` | `paper` | 4.5 | 6.32 | 6.79 | 9.24 | 10.66 | pass |
| Address token text | `ink` | `paper` + `fill` | 4.5 | 14.65 | 11.67 | 15.72 | 13.57 | pass |
| Address token text, hover | `ink` | `paper` + `pressed` | 4.5 | 13.75 | 10.90 | 14.47 | 12.34 | pass |
| Address token selected | `onAccent` | `accentFill` | 4.5 | 8.32 | 5.03 | 11.53 | 5.71 | pass |
| Address token invalid | `danger` | `dangerWash` | 4.5 | 5.41 | 6.58 | 6.27 | 7.58 | pass |
| Invalid token edge | `danger` | `paper` | 3 | 6.38 | 7.57 | 8.94 | 10.55 | pass |
| Autocomplete row text | `ink` | `raised` | 4.5 | 17.18 | 11.84 | 19.29 | 15.67 | pass |
| Autocomplete address | `ink3` | `raised` | 4.5 | 6.60 | 5.65 | 9.47 | 8.85 | pass |
| Autocomplete highlighted name | `ink` | `selWash` | 4.5 | 12.66 | 9.94 | 12.81 | 11.21 | pass |
| Autocomplete highlighted address | `ink3` | `selWash` | 4.5 | 4.86 | 4.74 | 6.29 | 6.33 | pass |
| Autocomplete highlight margin rule vs highlight wash | `selRule` | `selWash` | 3 | 6.13 | 5.26 | 7.65 | 6.76 | pass |
| Autocomplete highlight margin rule vs popover | `selRule` | `raised` | 3 | 8.32 | 6.26 | 11.53 | 9.45 | pass |
| Autocomplete accept keycap legend (raised keycap on the highlight) | `ink2` | `raised` | 4.5 | 7.98 | 6.80 | 11.99 | 10.94 | pass |
| Composer field-row focus ring (inset, on paper) | `focus` | `paper` | 3 | 7.97 | 7.53 | 11.24 | 11.38 | pass |
| Composer body caret (the body's focus indicator) | `accent` | `sheet` | 3 | 8.25 | 6.94 | 11.53 | 10.38 | pass |
| Composer drop label (Drop to attach) | `accent` | `sheet` | 4.5 | 8.25 | 6.94 | 11.53 | 10.38 | pass |
| Composer status: rejected drop warning glyph | `warning` | `paper` | 3 | 6.28 | 8.56 | 9.13 | 11.53 | pass |
| Attachment strip chip name | `ink` | `sheet` | 4.5 | 17.04 | 13.11 | 19.29 | 17.21 | pass |
| Attachment strip chip size | `ink3` | `sheet` | 4.5 | 6.54 | 6.26 | 9.47 | 9.72 | pass |
| Attachment strip remove glyph | `ink3` | `sheet` | 3 | 6.54 | 6.26 | 9.47 | 9.72 | pass |
| Primary button label | `onAccent` | `accentFill` | 4.5 | 8.32 | 5.03 | 11.53 | 5.71 | pass |
| Primary button label, hover | `onAccent` | `accentFillHover` | 4.5 | 10.06 | 4.58 | 13.57 | 5.06 | pass |
| Primary button label, pressed | `onAccent` | `accentFillPressed` | 4.5 | 12.14 | 5.94 | 15.57 | 6.77 | pass |
| Primary button focus ring vs paper gap | `focus` | `paper` | 3 | 7.97 | 7.53 | 11.24 | 11.38 | pass |
| Secondary button label | `ink` | `raised` | 4.5 | 17.18 | 11.84 | 19.29 | 15.67 | pass |
| Secondary button label, hover | `ink` | `raised` + `hover` | 4.5 | 15.66 | 10.19 | 16.77 | 11.90 | pass |
| Secondary button label, pressed | `ink` | `raised` + `pressed` | 4.5 | 14.34 | 8.89 | 14.83 | 9.74 | pass |
| Secondary button edge vs list | `ruleStrong` | `paper` | 3 | 4.13 | 4.71 | 6.77 | 7.01 | pass |
| Secondary button edge vs sheet | `ruleStrong` | `sheet` | 3 | 4.28 | 4.34 | 6.94 | 6.39 | pass |
| Secondary button edge vs desk | `ruleStrong` | `canvas` | 3 | 3.85 | 4.94 | 6.03 | 7.26 | pass |
| Ghost button label | `ink2` | `paper` | 4.5 | 7.64 | 8.18 | 11.69 | 13.16 | pass |
| Ghost button label, hover | `ink` | `paper` + `hover` | 4.5 | 15.00 | 12.45 | 16.36 | 15.02 | pass |
| Ghost button label, pressed | `ink` | `paper` + `pressed` | 4.5 | 13.75 | 10.90 | 14.47 | 12.34 | pass |
| Link button | `accent` | `paper` | 4.5 | 7.97 | 7.53 | 11.24 | 11.38 | pass |
| Link button on sheet | `accent` | `sheet` | 4.5 | 8.25 | 6.94 | 11.53 | 10.38 | pass |
| Link button on desk | `accent` | `canvas` | 4.5 | 7.43 | 7.91 | 10.02 | 11.79 | pass |
| Link button, pressed (ink2 with the underline), on the list | `ink2` | `paper` | 4.5 | 7.64 | 8.18 | 11.69 | 13.16 | pass |
| Link button, pressed, on a sheet or group | `ink2` | `sheet` | 4.5 | 7.91 | 7.53 | 11.99 | 12.01 | pass |
| Link button, pressed, on the desk | `ink2` | `canvas` | 4.5 | 7.13 | 8.59 | 10.42 | 13.64 | pass |
| Link button, pressed, in an info banner | `ink2` | `infoWash` | 4.5 | 6.60 | 7.18 | 8.53 | 9.22 | pass |
| Link button, pressed, in a danger banner | `ink2` | `dangerWash` | 4.5 | 6.47 | 7.11 | 8.20 | 9.45 | pass |
| Destructive button label | `onDanger` | `dangerFill` | 4.5 | 6.67 | 5.44 | 9.17 | 5.44 | pass |
| Destructive button label, hover | `onDanger` | `dangerFillHover` | 4.5 | 7.79 | 4.96 | 10.73 | 4.96 | pass |
| Destructive button label, pressed | `onDanger` | `dangerFillPressed` | 4.5 | 9.13 | 6.62 | 12.45 | 6.62 | pass |
| Icon button glyph on paper | `ink2` | `paper` | 3 | 7.64 | 8.18 | 11.69 | 13.16 | pass |
| Icon button glyph, hover | `ink` | `paper` + `hover` | 3 | 15.00 | 12.45 | 16.36 | 15.02 | pass |
| Icon button glyph, pressed | `ink` | `paper` + `pressed` | 3 | 13.75 | 10.90 | 14.47 | 12.34 | pass |
| Text field text | `ink` | `sheet` | 4.5 | 17.04 | 13.11 | 19.29 | 17.21 | pass |
| Text field placeholder | `ink3` | `sheet` | 4.5 | 6.54 | 6.26 | 9.47 | 9.72 | pass |
| Text field edge vs sheet | `ruleStrong` | `sheet` | 3 | 4.28 | 4.34 | 6.94 | 6.39 | pass |
| Text field edge vs desk | `ruleStrong` | `canvas` | 3 | 3.85 | 4.94 | 6.03 | 7.26 | pass |
| Text field edge vs list | `ruleStrong` | `paper` | 3 | 4.13 | 4.71 | 6.77 | 7.01 | pass |
| Field error border and help | `danger` | `sheet` | 4.5 | 6.61 | 6.97 | 9.17 | 9.62 | pass |
| Field error help on desk | `danger` | `canvas` | 4.5 | 5.95 | 7.95 | 7.97 | 10.93 | pass |
| Focus ring vs list | `focus` | `paper` | 3 | 7.97 | 7.53 | 11.24 | 11.38 | pass |
| Focus ring vs sheet | `focus` | `sheet` | 3 | 8.25 | 6.94 | 11.53 | 10.38 | pass |
| Focus ring vs desk | `focus` | `canvas` | 3 | 7.43 | 7.91 | 10.02 | 11.79 | pass |
| Focus ring vs raised | `focus` | `raised` | 3 | 8.32 | 6.26 | 11.53 | 9.45 | pass |
| Checkbox / radio off edge | `ruleStrong` | `sheet` | 3 | 4.28 | 4.34 | 6.94 | 6.39 | pass |
| Checkbox / radio off edge vs desk | `ruleStrong` | `canvas` | 3 | 3.85 | 4.94 | 6.03 | 7.26 | pass |
| Checkbox / radio off edge, hover face (sheet + hover) | `ruleStrong` | `sheet` + `hover` | 3 | 3.90 | 3.76 | 6.03 | 4.93 | pass |
| Checkbox / radio off edge, pressed face (sheet + pressed) | `ruleStrong` | `sheet` + `pressed` | 3 | 3.57 | 3.28 | 5.33 | 4.03 | pass |
| Checkbox / radio on fill vs sheet | `accentFill` | `sheet` | 3 | 8.25 | 3.15 | 11.53 | 3.01 | pass |
| Checkbox on fill vs desk | `accentFill` | `canvas` | 3 | 7.43 | 3.59 | 10.02 | 3.42 | pass |
| Checkbox / radio on fill, hover (accentFillHover), vs sheet | `accentFillHover` | `sheet` | 3 | 9.97 | 3.46 | 13.57 | 3.40 | pass |
| Checkbox / radio on fill, hover, vs desk | `accentFillHover` | `canvas` | 3 | 8.99 | 3.95 | 11.80 | 3.86 | pass |
| Checkbox / radio on fill, pressed (controlOnPressed), vs sheet | `controlOnPressed` | `sheet` | 3 | 12.04 | 3.80 | 15.57 | 3.70 | pass |
| Checkbox / radio on fill, pressed, vs desk | `controlOnPressed` | `canvas` | 3 | 10.84 | 4.33 | 13.55 | 4.20 | pass |
| Checkmark on fill | `onAccent` | `accentFill` | 3 | 8.32 | 5.03 | 11.53 | 5.71 | pass |
| Checkmark / radio dot on the hover fill | `onAccent` | `accentFillHover` | 3 | 10.06 | 4.58 | 13.57 | 5.06 | pass |
| Checkmark / radio dot on the pressed fill | `onAccent` | `controlOnPressed` | 3 | 12.14 | 4.18 | 15.57 | 4.65 | pass |
| Toggle off track edge, on a group (rest, hover and pressed: the track never takes a wash) | `ruleStrong` | `sheet` + `fill` | 3 | 3.81 | 3.51 | 5.79 | 4.44 | pass |
| Toggle on track vs sheet (rest, hover and pressed: the track never takes a wash) | `accentFill` | `sheet` | 3 | 8.25 | 3.15 | 11.53 | 3.01 | pass |
| Toggle knob on (on track), rest, hover and pressed (the press stretches the knob; its face never changes) | `knob` | `accentFill` | 3 | 8.32 | 3.51 | 11.53 | 5.71 | pass |
| Toggle knob edge vs off track (knob position cue), on a group: rest, hover and pressed (the press stretches the knob; neither face nor track takes a wash) | `ruleStrong` | `sheet` + `fill` | 3 | 3.81 | 3.51 | 5.79 | 4.44 | pass |
| Toggle knob edge vs off track (knob position cue), on the desk: rest, hover and pressed | `ruleStrong` | `canvas` + `fill` | 3 | 3.44 | 4.10 | 5.05 | 5.36 | pass |
| Toggle off track edge, on the desk (rest, hover and pressed) | `ruleStrong` | `canvas` + `fill` | 3 | 3.44 | 4.10 | 5.05 | 5.36 | pass |
| Toggle on track vs desk (rest, hover and pressed) | `accentFill` | `canvas` | 3 | 7.43 | 3.59 | 10.02 | 3.42 | pass |
| Popup label | `ink` | `raised` | 4.5 | 17.18 | 11.84 | 19.29 | 15.67 | pass |
| Popup chevron | `ink2` | `raised` | 3 | 7.98 | 6.80 | 11.99 | 10.94 | pass |
| Popup edge vs sheet | `ruleStrong` | `sheet` | 3 | 4.28 | 4.34 | 6.94 | 6.39 | pass |
| Keycap legend | `ink2` | `raised` | 4.5 | 7.98 | 6.80 | 11.99 | 10.94 | pass |
| Keycap sequence word (then) | `ink3` | `paper` | 4.5 | 6.32 | 6.79 | 9.24 | 10.66 | pass |
| Count badge (neutral) on sheet | `ink2` | `sheet` + `fill` | 4.5 | 7.04 | 6.10 | 10.01 | 8.33 | pass |
| Unread count badge numerals | `onAccent` | `accentFill` | 4.5 | 8.32 | 5.03 | 11.53 | 5.71 | pass |
| Attention badge glyph | `onDanger` | `dangerFill` | 4.5 | 6.67 | 5.44 | 9.17 | 5.44 | pass |
| Dot badge vs list | `accent` | `paper` | 3 | 7.97 | 7.53 | 11.24 | 11.38 | pass |
| Banner (neutral) text | `ink` | `sheet` + `fill` | 4.5 | 15.17 | 10.62 | 16.10 | 11.94 | pass |
| Info banner text | `info` | `infoWash` | 4.5 | 5.98 | 6.96 | 7.08 | 8.09 | pass |
| Success banner text | `success` | `successWash` | 4.5 | 5.49 | 6.97 | 6.99 | 7.63 | pass |
| Warning banner text | `warning` | `warningWash` | 4.5 | 5.59 | 7.09 | 7.00 | 7.71 | pass |
| Error banner text | `danger` | `dangerWash` | 4.5 | 5.41 | 6.58 | 6.27 | 7.58 | pass |
| Banner body text on info wash | `ink` | `infoWash` | 4.5 | 14.23 | 12.49 | 13.73 | 13.21 | pass |
| Banner body text on error wash | `ink` | `dangerWash` | 4.5 | 13.95 | 12.37 | 13.20 | 13.55 | pass |
| Determinate bar fill vs track | `accent` | `sheet` + `fill` | 3 | 7.35 | 5.62 | 9.62 | 7.20 | pass |
| Spinner (ink3) on sheet | `ink3` | `sheet` | 3 | 6.54 | 6.26 | 9.47 | 9.72 | pass |
| Toast message | `onSlip` | `slip` | 4.5 | 13.95 | 10.39 | 18.98 | 14.08 | pass |
| Toast Undo | `onSlip` | `slip` | 4.5 | 13.95 | 10.39 | 18.98 | 14.08 | pass |
| Toast Undo, hover | `onSlip` | `slip` + `slipHover` | 4.5 | 9.21 | 7.39 | 11.14 | 7.37 | pass |
| Toast Undo, pressed | `onSlip` | `slip` + `slipPressed` | 4.5 | 7.15 | 5.91 | 8.31 | 5.72 | pass |
| Toast keycap legend (Z) | `onSlip2` | `slip` | 4.5 | 7.53 | 6.67 | 12.86 | 9.83 | pass |
| Toast keycap legend, action hovered (drawn in onSlip) | `onSlip` | `slip` + `slipHover` | 4.5 | 9.21 | 7.39 | 11.14 | 7.37 | pass |
| Toast keycap legend, action pressed (drawn in onSlip) | `onSlip` | `slip` + `slipPressed` | 4.5 | 7.15 | 5.91 | 8.31 | 5.72 | pass |
| Toast glyph | `onSlip2` | `slip` | 3 | 7.53 | 6.67 | 12.86 | 9.83 | pass |
| Toast focus ring | `onSlip` | `slip` | 3 | 13.95 | 10.39 | 18.98 | 14.08 | pass |
| Slip outline: undo-panel action at rest, keycap outline (onSlipEdge) | `onSlipEdge` | `slip` | 3 | 3.97 | 3.43 | 5.36 | 4.74 | pass |
| Toast contrail | `onSlip` | `slip` | 3 | 13.95 | 10.39 | 18.98 | 14.08 | pass |
| Undo panel title | `onSlip` | `slip` | 4.5 | 13.95 | 10.39 | 18.98 | 14.08 | pass |
| Undo panel detail | `onSlip2` | `slip` | 4.5 | 7.53 | 6.67 | 12.86 | 9.83 | pass |
| Undo panel Undo label, rest | `onSlip` | `slip` | 4.5 | 13.95 | 10.39 | 18.98 | 14.08 | pass |
| Undo panel Undo label, hover | `onSlip` | `slip` + `slipHover` | 4.5 | 9.21 | 7.39 | 11.14 | 7.37 | pass |
| Undo panel Undo label, pressed | `onSlip` | `slip` + `slipPressed` | 4.5 | 7.15 | 5.91 | 8.31 | 5.72 | pass |
| Undo panel keycap legend, rest | `onSlip2` | `slip` | 4.5 | 7.53 | 6.67 | 12.86 | 9.83 | pass |
| Undo panel keycap legend, hover (drawn in onSlip) | `onSlip` | `slip` + `slipHover` | 4.5 | 9.21 | 7.39 | 11.14 | 7.37 | pass |
| Undo panel keycap legend, pressed (drawn in onSlip) | `onSlip` | `slip` + `slipPressed` | 4.5 | 7.15 | 5.91 | 8.31 | 5.72 | pass |
| Undo panel glyph and spinner | `onSlip2` | `slip` | 3 | 7.53 | 6.67 | 12.86 | 9.83 | pass |
| Confirmation toast (no action) text | `onSlip` | `slip` | 4.5 | 13.95 | 10.39 | 18.98 | 14.08 | pass |
| g-sequence HUD rows | `onSlip2` | `slip` | 4.5 | 7.53 | 6.67 | 12.86 | 9.83 | pass |
| Settings label on desk | `ink` | `canvas` | 4.5 | 15.35 | 14.94 | 16.78 | 19.54 | pass |
| Settings row text on group | `ink` | `sheet` | 4.5 | 17.04 | 13.11 | 19.29 | 17.21 | pass |
| Settings secondary text | `ink2` | `sheet` | 4.5 | 7.91 | 7.53 | 11.99 | 12.01 | pass |
| Settings caption | `ink3` | `sheet` | 4.5 | 6.54 | 6.26 | 9.47 | 9.72 | pass |
| Settings caption on desk | `ink3` | `canvas` | 4.5 | 5.90 | 7.13 | 8.24 | 11.04 | pass |
| Settings selected row text | `ink` | `selWash` | 4.5 | 12.66 | 9.94 | 12.81 | 11.21 | pass |
| Settings selected row secondary | `ink2` | `selWash` | 4.5 | 5.88 | 5.71 | 7.96 | 7.82 | pass |
| Settings selected row text, window not key | `ink` | `selWashIdle` | 4.5 | 13.90 | 12.00 | 13.56 | 13.70 | pass |
| Settings selected row secondary, window not key | `ink2` | `selWashIdle` | 4.5 | 6.46 | 6.89 | 8.42 | 9.56 | pass |
| Settings selection wash vs group (scan cue, with the rule) | `selWash` | `sheet` | 1.25 | 1.35 | 1.32 | 1.51 | 1.54 | pass |
| Settings selection rule vs wash | `selRule` | `selWash` | 3 | 6.13 | 5.26 | 7.65 | 6.76 | pass |
| Settings selection rule vs group | `selRule` | `sheet` | 3 | 8.25 | 6.94 | 11.53 | 10.38 | pass |
| Settings idle selection rule vs idle wash | `selRuleIdle` | `selWashIdle` | 3 | 5.34 | 5.72 | 6.66 | 7.74 | pass |
| Settings idle selection rule vs group | `selRuleIdle` | `sheet` | 3 | 6.54 | 6.26 | 9.47 | 9.72 | pass |
| Settings +/- glyphs | `ink2` | `raised` | 3 | 7.98 | 6.80 | 11.99 | 10.94 | pass |
| Settings +/- edge vs desk | `ruleStrong` | `canvas` | 3 | 3.85 | 4.94 | 6.03 | 7.26 | pass |
| Settings empty-state hint | `ink3` | `sheet` | 4.5 | 6.54 | 6.26 | 9.47 | 9.72 | pass |
| Settings popup label on desk form | `ink` | `raised` | 4.5 | 17.18 | 11.84 | 19.29 | 15.67 | pass |
| Settings focus ring on desk | `focus` | `canvas` | 3 | 7.43 | 7.91 | 10.02 | 11.79 | pass |
| Settings status: up to date glyph | `success` | `sheet` | 3 | 6.42 | 7.71 | 9.15 | 10.54 | pass |
| Settings status: sign in required | `danger` | `sheet` | 4.5 | 6.61 | 6.97 | 9.17 | 9.62 | pass |
| Settings status: sign in required (selected) | `danger` | `selWash` | 4.5 | 4.91 | 5.29 | 6.09 | 6.27 | pass |
| Settings status: sign in required (selected, not key) | `danger` | `selWashIdle` | 4.5 | 5.39 | 6.38 | 6.44 | 7.66 | pass |
| Settings info banner text (OAuth notice, demo) | `ink` | `infoWash` | 4.5 | 14.23 | 12.49 | 13.73 | 13.21 | pass |
| Settings info banner glyph | `info` | `infoWash` | 3 | 5.98 | 6.96 | 7.08 | 8.09 | pass |
| Settings info banner link | `accent` | `infoWash` | 4.5 | 6.89 | 6.61 | 8.20 | 7.97 | pass |
| Settings status text | `ink2` | `sheet` | 4.5 | 7.91 | 7.53 | 11.99 | 12.01 | pass |
| Settings status: up to date glyph (selected) | `success` | `selWash` | 3 | 4.77 | 5.85 | 6.08 | 6.87 | pass |
| Settings status: up to date glyph (selected, not key) | `success` | `selWashIdle` | 3 | 5.24 | 7.06 | 6.43 | 8.39 | pass |
| Settings status: retrying glyph | `warning` | `sheet` | 3 | 6.50 | 7.89 | 9.37 | 10.52 | pass |
| Settings status: retrying glyph (selected) | `warning` | `selWash` | 3 | 4.83 | 5.98 | 6.22 | 6.85 | pass |
| Settings status: retrying glyph (selected, not key) | `warning` | `selWashIdle` | 3 | 5.30 | 7.22 | 6.58 | 8.37 | pass |
| Settings status: offline glyph | `ink2` | `sheet` | 3 | 7.91 | 7.53 | 11.99 | 12.01 | pass |
| Settings status: waiting to sync | `ink3` | `sheet` | 4.5 | 6.54 | 6.26 | 9.47 | 9.72 | pass |
| Settings status: waiting to sync (selected) | `ink3` | `selWash` | 4.5 | 4.86 | 4.74 | 6.29 | 6.33 | pass |
| Settings status: waiting to sync (selected, not key) | `ink3` | `selWashIdle` | 4.5 | 5.34 | 5.72 | 6.66 | 7.74 | pass |
| Settings status: download bar (selected row) | `accent` | `selWash` + `fill` | 3 | 5.49 | 4.25 | 6.46 | 4.71 | pass |
| OAuth Saved glyph on desk | `success` | `canvas` | 3 | 5.78 | 8.79 | 7.96 | 11.97 | pass |
| OAuth Saved text on desk | `ink2` | `canvas` | 4.5 | 7.13 | 8.59 | 10.42 | 13.64 | pass |
| General Mail links status glyph on desk | `success` | `canvas` | 3 | 5.78 | 8.79 | 7.96 | 11.97 | pass |
| General Mail links status text on desk | `ink2` | `canvas` | 4.5 | 7.13 | 8.59 | 10.42 | 13.64 | pass |
| General Mail links failure line on desk | `danger` | `canvas` | 4.5 | 5.95 | 7.95 | 7.97 | 10.93 | pass |
| General At login approval glyph on desk | `ink2` | `canvas` | 3 | 7.13 | 8.59 | 10.42 | 13.64 | pass |
| General At login approval text on desk | `ink2` | `canvas` | 4.5 | 7.13 | 8.59 | 10.42 | 13.64 | pass |
| OAuth section title on desk | `ink` | `canvas` | 4.5 | 15.35 | 14.94 | 16.78 | 19.54 | pass |
| Theme name underline, chosen, Settings key | `selRule` | `canvas` | 3 | 7.43 | 7.91 | 10.02 | 11.79 | pass |
| Theme name underline, chosen, Settings not key | `selRuleIdle` | `canvas` | 3 | 5.90 | 7.13 | 8.24 | 11.04 | pass |
| Mono field text | `ink` | `sheet` | 4.5 | 17.04 | 13.11 | 19.29 | 17.21 | pass |
| Welcome title | `ink` | `paper` | 4.5 | 16.45 | 14.23 | 18.82 | 18.86 | pass |
| Welcome tagline | `ink2` | `paper` | 4.5 | 7.64 | 8.18 | 11.69 | 13.16 | pass |
| Welcome button trailing note (ink2) | `ink2` | `raised` | 4.5 | 7.98 | 6.80 | 11.99 | 10.94 | pass |
| Welcome button trailing note, hover | `ink2` | `raised` + `hover` | 4.5 | 7.27 | 5.85 | 10.42 | 8.30 | pass |
| Welcome button trailing note, pressed | `ink2` | `raised` + `pressed` | 4.5 | 6.66 | 5.11 | 9.21 | 6.80 | pass |
| Welcome waiting label and spinner | `ink` | `raised` | 4.5 | 17.18 | 11.84 | 19.29 | 15.67 | pass |
| Welcome footnote | `ink3` | `paper` | 4.5 | 6.32 | 6.79 | 9.24 | 10.66 | pass |
| Welcome demo link | `accent` | `paper` | 4.5 | 7.97 | 7.53 | 11.24 | 11.38 | pass |
| Welcome error line | `danger` | `paper` | 4.5 | 6.38 | 7.57 | 8.94 | 10.55 | pass |
| Day and week: hour labels, a day cell's weekday and date, a week's day heading | `ink3` | `paper` | 4.5 | 6.32 | 6.79 | 9.24 | 10.66 | pass |
| Day and week: a day cell or day heading hovered, a pencilled event's title hovered (ink) | `ink` | `paper` + `hover` | 4.5 | 15.00 | 12.45 | 16.36 | 15.02 | pass |
| Day and week: a day cell pressed, a pencilled event's title pressed (ink) | `ink` | `paper` + `pressed` | 4.5 | 13.75 | 10.90 | 14.47 | 12.34 | pass |
| Day and week: the selected day cell's weekday and date; a third event's “+2” tag | `ink` | `raised` | 4.5 | 17.18 | 11.84 | 19.29 | 15.67 | pass |
| Day and week: an unanswered invitation's hollow bar in a day cell, hover | `ruleStrong` | `paper` + `hover` | 3 | 3.77 | 4.12 | 5.88 | 5.58 | pass |
| Day and week: an unanswered invitation's hollow bar in a day cell, pressed | `ruleStrong` | `paper` + `pressed` | 3 | 3.45 | 3.60 | 5.20 | 4.58 | pass |
| Day and week: an unanswered invitation's hollow bar in the selected day cell; the “+2” tag's edge | `ruleStrong` | `raised` | 3 | 4.31 | 3.91 | 6.94 | 5.82 | pass |
| Day and week: a pencilled event's dashed edge (not answered, or drawn from the mail) | `ruleStrong` | `paper` | 3 | 4.13 | 4.71 | 6.77 | 7.01 | pass |
| Day and week: a pencilled event's title | `ink2` | `paper` | 4.5 | 7.64 | 8.18 | 11.69 | 13.16 | pass |
| Day and week: the overlap hatch on a pencilled invitation | `warning` | `paper` | 3 | 6.28 | 8.56 | 9.13 | 11.53 | pass |
| Day and week: a fold band's range, a folded day's heading | `ink3` | `canvas` | 4.5 | 5.90 | 7.13 | 8.24 | 11.04 | pass |
| Day and week: a fold band's dashed edges | `ruleStrong` | `canvas` | 3 | 3.85 | 4.94 | 6.03 | 7.26 | pass |
| Day and week: the now line, its dot and its time | `ink` | `paper` | 4.5 | 16.45 | 14.23 | 18.82 | 18.86 | pass |
| Day and week: a Later or Send Later mark's dashed line | `ink3` | `paper` | 3 | 6.32 | 6.79 | 9.24 | 10.66 | pass |
| Day and week: a Later or Send Later chip's glyph and words; the foot's sentence | `ink2` | `paper` | 4.5 | 7.64 | 8.18 | 11.69 | 13.16 | pass |
| Day and week: a mark chip's edge | `ruleStrong` | `paper` | 3 | 4.13 | 4.71 | 6.77 | 7.01 | pass |
| Day and week: the selected conversation's time: its dashed line, its chip's edge and words | `accent` | `paper` | 4.5 | 7.97 | 7.53 | 11.24 | 11.38 | pass |
| Day and week: a day cell taking a drop, its ring | `focus` | `paper` | 3 | 7.97 | 7.53 | 11.24 | 11.38 | pass |
| Day and week: the drop ghost's dashed edge | `focus` | `accentWash` | 3 | 6.65 | 5.56 | 8.11 | 6.76 | pass |
| Day and week: the drop ghost's day and time | `accent` | `accentWash` | 4.5 | 6.65 | 5.56 | 8.11 | 6.76 | pass |
| Day and week: the strip's glyph | `ink2` | `canvas` | 3 | 7.13 | 8.59 | 10.42 | 13.64 | pass |
| Day and week: the strip's glyph, hover | `ink` | `canvas` + `hover` | 3 | 14.01 | 13.20 | 14.62 | 15.90 | pass |
| Day and week: the strip's hollow bar, pressed or open | `ruleStrong` | `canvas` + `pressed` | 3 | 3.23 | 3.84 | 4.66 | 4.88 | pass |
| Day and week: the strip's outline of the selected conversation's event, pressed or open | `selRule` | `canvas` + `pressed` | 3 | 6.22 | 6.14 | 7.74 | 7.92 | pass |
| Day and week: the strip's outline of the selected conversation's event, pressed or open, window not key | `selRuleIdle` | `canvas` + `pressed` | 3 | 4.94 | 5.54 | 6.37 | 7.42 | pass |
| Day and week: the strip's now line, pressed or open | `ink` | `canvas` + `pressed` | 3 | 12.85 | 11.60 | 12.96 | 13.13 | pass |
| Day and week: the strip's mail time, pressed or open | `accent` | `canvas` + `pressed` | 3 | 6.22 | 6.14 | 7.74 | 7.92 | pass |
| Event details and the week's invitation card: the kicker | `ink3` | `raised` | 4.5 | 6.60 | 5.65 | 9.47 | 8.85 | pass |
| Event details: why a block failed | `danger` | `raised` | 4.5 | 6.67 | 6.30 | 9.17 | 8.76 | pass |
| The week's invitation card: the answered kicker | `accent` | `raised` | 4.5 | 8.32 | 6.26 | 11.53 | 9.45 | pass |
| The week's invitation card: the overlap glyph | `warning` | `raised` | 3 | 6.55 | 7.12 | 9.37 | 9.58 | pass |
| Invitation card (§5.14): the overlap glyph | `warning` | `sheet` | 3 | 6.50 | 7.89 | 9.37 | 10.52 | pass |
| Invitation card (§5.14): the overlap line | `ink` | `sheet` | 4.5 | 17.04 | 13.11 | 19.29 | 17.21 | pass |
| Account ink Persimmon on list | `account:Persimmon` | `paper` | 3 (IC 3.5) | 4.16 | 4.57 | 5.27 | 6.15 | pass |
| Account ink Persimmon on hovered row | `account:Persimmon` | `paper` + `hover` | 3 (IC 3.5) | 3.79 | 4.00 | 4.58 | 4.90 | pass |
| Account ink Persimmon on selected row | `account:Persimmon` | `selWash` | 3 (IC 3.5) | 3.20 | 3.19 | 3.59 | 3.66 | pass |
| Account ink Persimmon on idle selection | `account:Persimmon` | `selWashIdle` | 3 (IC 3.5) | 3.51 | 3.85 | 3.79 | 4.47 | pass |
| Account ink Persimmon on rail | `account:Persimmon` | `spine` | 3 (IC 3.5) | 3.58 | 5.00 | 4.10 | 6.54 | pass |
| Account ink Persimmon on hovered rail tile | `account:Persimmon` | `spine` + `hover` | 3 (IC 3.5) | 3.27 | 4.47 | 3.58 | 5.43 | pass |
| Account ink Persimmon on sheet / Settings | `account:Persimmon` | `sheet` | 3 (IC 3.5) | 4.31 | 4.21 | 5.40 | 5.62 | pass |
| Account ink Persimmon on reader desk | `account:Persimmon` | `canvas` | 3 (IC 3.5) | 3.88 | 4.80 | 4.70 | 6.38 | pass |
| Account ink Persimmon on raised: popups at rest, and the 2 pt raised halo that keeps the dot or swatch off a hovered or pressed popup face | `account:Persimmon` | `raised` | 3 (IC 3.5) | 4.34 | 3.80 | 5.40 | 5.11 | pass |
| Rail monogram on Persimmon face | `ink` | `accountFace:Persimmon` | 4.5 | 14.20 | 11.10 | 15.82 | 14.16 | pass |
| Rail monogram on Persimmon face, pressed (the press wash stays inside the face) | `ink` | `accountFace:Persimmon` + `pressed` | 4.5 | 11.91 | 8.36 | 12.25 | 8.82 | pass |
| Account ink Indigo on list | `account:Indigo` | `paper` | 3 (IC 3.5) | 11.39 | 4.59 | 14.03 | 6.15 | pass |
| Account ink Indigo on hovered row | `account:Indigo` | `paper` + `hover` | 3 (IC 3.5) | 10.39 | 4.02 | 12.20 | 4.89 | pass |
| Account ink Indigo on selected row | `account:Indigo` | `selWash` | 3 (IC 3.5) | 8.77 | 3.20 | 9.55 | 3.65 | pass |
| Account ink Indigo on idle selection | `account:Indigo` | `selWashIdle` | 3 (IC 3.5) | 9.63 | 3.87 | 10.11 | 4.46 | pass |
| Account ink Indigo on rail | `account:Indigo` | `spine` | 3 (IC 3.5) | 9.81 | 5.03 | 10.91 | 6.53 | pass |
| Account ink Indigo on hovered rail tile | `account:Indigo` | `spine` + `hover` | 3 (IC 3.5) | 8.96 | 4.49 | 9.54 | 5.42 | pass |
| Account ink Indigo on sheet / Settings | `account:Indigo` | `sheet` | 3 (IC 3.5) | 11.80 | 4.23 | 14.38 | 5.61 | pass |
| Account ink Indigo on reader desk | `account:Indigo` | `canvas` | 3 (IC 3.5) | 10.63 | 4.82 | 12.51 | 6.37 | pass |
| Account ink Indigo on raised: popups at rest, and the 2 pt raised halo that keeps the dot or swatch off a hovered or pressed popup face | `account:Indigo` | `raised` | 3 (IC 3.5) | 11.90 | 3.82 | 14.38 | 5.11 | pass |
| Rail monogram on Indigo face | `ink` | `accountFace:Indigo` | 4.5 | 13.22 | 10.93 | 14.72 | 13.97 | pass |
| Rail monogram on Indigo face, pressed (the press wash stays inside the face) | `ink` | `accountFace:Indigo` + `pressed` | 4.5 | 11.11 | 8.20 | 11.43 | 8.67 | pass |
| Account ink Lilac on list | `account:Lilac` | `paper` | 3 (IC 3.5) | 4.14 | 10.99 | 5.23 | 12.04 | pass |
| Account ink Lilac on hovered row | `account:Lilac` | `paper` + `hover` | 3 (IC 3.5) | 3.77 | 9.61 | 4.55 | 9.58 | pass |
| Account ink Lilac on selected row | `account:Lilac` | `selWash` | 3 (IC 3.5) | 3.19 | 7.67 | 3.56 | 7.15 | pass |
| Account ink Lilac on idle selection | `account:Lilac` | `selWashIdle` | 3 (IC 3.5) | 3.50 | 9.26 | 3.77 | 8.74 | pass |
| Account ink Lilac on rail | `account:Lilac` | `spine` | 3 (IC 3.5) | 3.56 | 12.04 | 4.07 | 12.78 | pass |
| Account ink Lilac on hovered rail tile | `account:Lilac` | `spine` + `hover` | 3 (IC 3.5) | 3.26 | 10.75 | 3.56 | 10.61 | pass |
| Account ink Lilac on sheet / Settings | `account:Lilac` | `sheet` | 3 (IC 3.5) | 4.29 | 10.12 | 5.36 | 10.98 | pass |
| Account ink Lilac on reader desk | `account:Lilac` | `canvas` | 3 (IC 3.5) | 3.86 | 11.54 | 4.66 | 12.47 | pass |
| Account ink Lilac on raised: popups at rest, and the 2 pt raised halo that keeps the dot or swatch off a hovered or pressed popup face | `account:Lilac` | `raised` | 3 (IC 3.5) | 4.32 | 9.14 | 5.36 | 10.00 | pass |
| Rail monogram on Lilac face | `ink` | `accountFace:Lilac` | 4.5 | 14.43 | 9.33 | 16.03 | 12.39 | pass |
| Rail monogram on Lilac face, pressed (the press wash stays inside the face) | `ink` | `accountFace:Lilac` + `pressed` | 4.5 | 12.10 | 7.06 | 12.41 | 7.75 | pass |
| Account ink Jade on list | `account:Jade` | `paper` | 3 (IC 3.5) | 6.89 | 5.80 | 8.75 | 5.93 | pass |
| Account ink Jade on hovered row | `account:Jade` | `paper` + `hover` | 3 (IC 3.5) | 6.28 | 5.08 | 7.61 | 4.72 | pass |
| Account ink Jade on selected row | `account:Jade` | `selWash` | 3 (IC 3.5) | 5.30 | 4.05 | 5.96 | 3.52 | pass |
| Account ink Jade on idle selection | `account:Jade` | `selWashIdle` | 3 (IC 3.5) | 5.82 | 4.89 | 6.30 | 4.30 | pass |
| Account ink Jade on rail | `account:Jade` | `spine` | 3 (IC 3.5) | 5.93 | 6.36 | 6.81 | 6.30 | pass |
| Account ink Jade on hovered rail tile | `account:Jade` | `spine` + `hover` | 3 (IC 3.5) | 5.42 | 5.68 | 5.95 | 5.23 | pass |
| Account ink Jade on sheet / Settings | `account:Jade` | `sheet` | 3 (IC 3.5) | 7.13 | 5.35 | 8.97 | 5.41 | pass |
| Account ink Jade on reader desk | `account:Jade` | `canvas` | 3 (IC 3.5) | 6.43 | 6.09 | 7.80 | 6.14 | pass |
| Account ink Jade on raised: popups at rest, and the 2 pt raised halo that keeps the dot or swatch off a hovered or pressed popup face | `account:Jade` | `raised` | 3 (IC 3.5) | 7.19 | 4.83 | 8.97 | 4.92 | pass |
| Rail monogram on Jade face | `ink` | `accountFace:Jade` | 4.5 | 13.65 | 10.61 | 15.23 | 14.10 | pass |
| Rail monogram on Jade face, pressed (the press wash stays inside the face) | `ink` | `accountFace:Jade` + `pressed` | 4.5 | 11.46 | 7.98 | 11.82 | 8.75 | pass |
| Account ink Iris on list | `account:Iris` | `paper` | 3 (IC 3.5) | 6.93 | 7.29 | 7.04 | 7.98 | pass |
| Account ink Iris on hovered row | `account:Iris` | `paper` + `hover` | 3 (IC 3.5) | 6.32 | 6.37 | 6.12 | 6.35 | pass |
| Account ink Iris on selected row | `account:Iris` | `selWash` | 3 (IC 3.5) | 5.33 | 5.09 | 4.79 | 4.74 | pass |
| Account ink Iris on idle selection | `account:Iris` | `selWashIdle` | 3 (IC 3.5) | 5.86 | 6.14 | 5.07 | 5.80 | pass |
| Account ink Iris on rail | `account:Iris` | `spine` | 3 (IC 3.5) | 5.97 | 7.98 | 5.47 | 8.48 | pass |
| Account ink Iris on hovered rail tile | `account:Iris` | `spine` + `hover` | 3 (IC 3.5) | 5.45 | 7.13 | 4.78 | 7.04 | pass |
| Account ink Iris on sheet / Settings | `account:Iris` | `sheet` | 3 (IC 3.5) | 7.18 | 6.71 | 7.21 | 7.28 | pass |
| Account ink Iris on reader desk | `account:Iris` | `canvas` | 3 (IC 3.5) | 6.46 | 7.65 | 6.27 | 8.27 | pass |
| Account ink Iris on raised: popups at rest, and the 2 pt raised halo that keeps the dot or swatch off a hovered or pressed popup face | `account:Iris` | `raised` | 3 (IC 3.5) | 7.24 | 6.06 | 7.21 | 6.63 | pass |
| Rail monogram on Iris face | `ink` | `accountFace:Iris` | 4.5 | 13.70 | 10.16 | 15.46 | 13.44 | pass |
| Rail monogram on Iris face, pressed (the press wash stays inside the face) | `ink` | `accountFace:Iris` + `pressed` | 4.5 | 11.50 | 7.65 | 11.98 | 8.36 | pass |
| Account ink Fern on list | `account:Fern` | `paper` | 3 (IC 3.5) | 4.15 | 11.06 | 5.27 | 14.27 | pass |
| Account ink Fern on hovered row | `account:Fern` | `paper` + `hover` | 3 (IC 3.5) | 3.78 | 9.68 | 4.58 | 11.36 | pass |
| Account ink Fern on selected row | `account:Fern` | `selWash` | 3 (IC 3.5) | 3.19 | 7.72 | 3.59 | 8.48 | pass |
| Account ink Fern on idle selection | `account:Fern` | `selWashIdle` | 3 (IC 3.5) | 3.51 | 9.32 | 3.80 | 10.36 | pass |
| Account ink Fern on rail | `account:Fern` | `spine` | 3 (IC 3.5) | 3.57 | 12.11 | 4.10 | 15.16 | pass |
| Account ink Fern on hovered rail tile | `account:Fern` | `spine` + `hover` | 3 (IC 3.5) | 3.26 | 10.82 | 3.58 | 12.58 | pass |
| Account ink Fern on sheet / Settings | `account:Fern` | `sheet` | 3 (IC 3.5) | 4.30 | 10.19 | 5.40 | 13.02 | pass |
| Account ink Fern on reader desk | `account:Fern` | `canvas` | 3 (IC 3.5) | 3.87 | 11.61 | 4.70 | 14.79 | pass |
| Account ink Fern on raised: popups at rest, and the 2 pt raised halo that keeps the dot or swatch off a hovered or pressed popup face | `account:Fern` | `raised` | 3 (IC 3.5) | 4.33 | 9.20 | 5.40 | 11.86 | pass |
| Rail monogram on Fern face | `ink` | `accountFace:Fern` | 4.5 | 14.43 | 9.32 | 16.02 | 11.93 | pass |
| Rail monogram on Fern face, pressed (the press wash stays inside the face) | `ink` | `accountFace:Fern` + `pressed` | 4.5 | 12.10 | 7.06 | 12.40 | 7.49 | pass |
| Account ink Umber on list | `account:Umber` | `paper` | 3 (IC 3.5) | 11.44 | 4.58 | 11.72 | 6.13 | pass |
| Account ink Umber on hovered row | `account:Umber` | `paper` + `hover` | 3 (IC 3.5) | 10.43 | 4.00 | 10.19 | 4.88 | pass |
| Account ink Umber on selected row | `account:Umber` | `selWash` | 3 (IC 3.5) | 8.80 | 3.20 | 7.98 | 3.64 | pass |
| Account ink Umber on idle selection | `account:Umber` | `selWashIdle` | 3 (IC 3.5) | 9.67 | 3.86 | 8.45 | 4.45 | pass |
| Account ink Umber on rail | `account:Umber` | `spine` | 3 (IC 3.5) | 9.85 | 5.01 | 9.12 | 6.51 | pass |
| Account ink Umber on hovered rail tile | `account:Umber` | `spine` + `hover` | 3 (IC 3.5) | 9.00 | 4.48 | 7.97 | 5.41 | pass |
| Account ink Umber on sheet / Settings | `account:Umber` | `sheet` | 3 (IC 3.5) | 11.84 | 4.22 | 12.02 | 5.59 | pass |
| Account ink Umber on reader desk | `account:Umber` | `canvas` | 3 (IC 3.5) | 10.67 | 4.81 | 10.45 | 6.35 | pass |
| Account ink Umber on raised: popups at rest, and the 2 pt raised halo that keeps the dot or swatch off a hovered or pressed popup face | `account:Umber` | `raised` | 3 (IC 3.5) | 11.95 | 3.81 | 12.02 | 5.09 | pass |
| Rail monogram on Umber face | `ink` | `accountFace:Umber` | 4.5 | 13.19 | 10.94 | 14.97 | 14.00 | pass |
| Rail monogram on Umber face, pressed (the press wash stays inside the face) | `ink` | `accountFace:Umber` + `pressed` | 4.5 | 11.08 | 8.22 | 11.62 | 8.69 | pass |
| Account ink Azure on list | `account:Azure` | `paper` | 3 (IC 3.5) | 4.15 | 4.57 | 5.26 | 6.15 | pass |
| Account ink Azure on hovered row | `account:Azure` | `paper` + `hover` | 3 (IC 3.5) | 3.78 | 4.00 | 4.57 | 4.89 | pass |
| Account ink Azure on selected row | `account:Azure` | `selWash` | 3 (IC 3.5) | 3.19 | 3.19 | 3.58 | 3.65 | pass |
| Account ink Azure on idle selection | `account:Azure` | `selWashIdle` | 3 (IC 3.5) | 3.50 | 3.86 | 3.79 | 4.46 | pass |
| Account ink Azure on rail | `account:Azure` | `spine` | 3 (IC 3.5) | 3.57 | 5.01 | 4.09 | 6.53 | pass |
| Account ink Azure on hovered rail tile | `account:Azure` | `spine` + `hover` | 3 (IC 3.5) | 3.26 | 4.48 | 3.57 | 5.42 | pass |
| Account ink Azure on sheet / Settings | `account:Azure` | `sheet` | 3 (IC 3.5) | 4.29 | 4.21 | 5.39 | 5.61 | pass |
| Account ink Azure on reader desk | `account:Azure` | `canvas` | 3 (IC 3.5) | 3.87 | 4.80 | 4.69 | 6.37 | pass |
| Account ink Azure on raised: popups at rest, and the 2 pt raised halo that keeps the dot or swatch off a hovered or pressed popup face | `account:Azure` | `raised` | 3 (IC 3.5) | 4.33 | 3.80 | 5.39 | 5.11 | pass |
| Rail monogram on Azure face | `ink` | `accountFace:Azure` | 4.5 | 14.17 | 11.10 | 15.87 | 14.02 | pass |
| Rail monogram on Azure face, pressed (the press wash stays inside the face) | `ink` | `accountFace:Azure` + `pressed` | 4.5 | 11.89 | 8.35 | 12.29 | 8.70 | pass |
| Account ink Mulberry on list | `account:Mulberry` | `paper` | 3 (IC 3.5) | 8.95 | 4.59 | 9.14 | 6.15 | pass |
| Account ink Mulberry on hovered row | `account:Mulberry` | `paper` + `hover` | 3 (IC 3.5) | 8.17 | 4.01 | 7.94 | 4.89 | pass |
| Account ink Mulberry on selected row | `account:Mulberry` | `selWash` | 3 (IC 3.5) | 6.89 | 3.20 | 6.22 | 3.65 | pass |
| Account ink Mulberry on idle selection | `account:Mulberry` | `selWashIdle` | 3 (IC 3.5) | 7.57 | 3.87 | 6.58 | 4.46 | pass |
| Account ink Mulberry on rail | `account:Mulberry` | `spine` | 3 (IC 3.5) | 7.71 | 5.03 | 7.11 | 6.53 | pass |
| Account ink Mulberry on hovered rail tile | `account:Mulberry` | `spine` + `hover` | 3 (IC 3.5) | 7.04 | 4.49 | 6.21 | 5.42 | pass |
| Account ink Mulberry on sheet / Settings | `account:Mulberry` | `sheet` | 3 (IC 3.5) | 9.27 | 4.23 | 9.37 | 5.61 | pass |
| Account ink Mulberry on reader desk | `account:Mulberry` | `canvas` | 3 (IC 3.5) | 8.35 | 4.82 | 8.15 | 6.37 | pass |
| Account ink Mulberry on raised: popups at rest, and the 2 pt raised halo that keeps the dot or swatch off a hovered or pressed popup face | `account:Mulberry` | `raised` | 3 (IC 3.5) | 9.35 | 3.82 | 9.37 | 5.11 | pass |
| Rail monogram on Mulberry face | `ink` | `accountFace:Mulberry` | 4.5 | 13.48 | 10.93 | 15.21 | 13.98 | pass |
| Rail monogram on Mulberry face, pressed (the press wash stays inside the face) | `ink` | `accountFace:Mulberry` + `pressed` | 4.5 | 11.33 | 8.21 | 11.80 | 8.67 | pass |
| Account ink Graphite on list | `account:Graphite` | `paper` | 3 (IC 3.5) | 5.35 | 7.30 | 6.34 | 9.06 | pass |
| Account ink Graphite on hovered row | `account:Graphite` | `paper` + `hover` | 3 (IC 3.5) | 4.88 | 6.38 | 5.52 | 7.21 | pass |
| Account ink Graphite on selected row | `account:Graphite` | `selWash` | 3 (IC 3.5) | 4.12 | 5.09 | 4.32 | 5.39 | pass |
| Account ink Graphite on idle selection | `account:Graphite` | `selWashIdle` | 3 (IC 3.5) | 4.52 | 6.15 | 4.57 | 6.58 | pass |
| Account ink Graphite on rail | `account:Graphite` | `spine` | 3 (IC 3.5) | 4.61 | 7.99 | 4.94 | 9.63 | pass |
| Account ink Graphite on hovered rail tile | `account:Graphite` | `spine` + `hover` | 3 (IC 3.5) | 4.21 | 7.14 | 4.31 | 7.99 | pass |
| Account ink Graphite on sheet / Settings | `account:Graphite` | `sheet` | 3 (IC 3.5) | 5.54 | 6.72 | 6.50 | 8.27 | pass |
| Account ink Graphite on reader desk | `account:Graphite` | `canvas` | 3 (IC 3.5) | 4.99 | 7.66 | 5.66 | 9.39 | pass |
| Account ink Graphite on raised: popups at rest, and the 2 pt raised halo that keeps the dot or swatch off a hovered or pressed popup face | `account:Graphite` | `raised` | 3 (IC 3.5) | 5.59 | 6.07 | 6.50 | 7.53 | pass |
| Rail monogram on Graphite face | `ink` | `accountFace:Graphite` | 4.5 | 14.12 | 10.11 | 15.78 | 13.08 | pass |
| Rail monogram on Graphite face, pressed (the press wash stays inside the face) | `ink` | `accountFace:Graphite` + `pressed` | 4.5 | 11.85 | 7.61 | 12.22 | 8.15 | pass |
| Avatar initials, Clay | `avatarInk:Clay` | `avatarFace:Clay` | 4.5 | 6.22 | 8.19 | 7.64 | 8.79 | pass |
| Avatar initials, Wheat | `avatarInk:Wheat` | `avatarFace:Wheat` | 4.5 | 6.06 | 8.17 | 7.85 | 8.46 | pass |
| Avatar initials, Fern | `avatarInk:Fern` | `avatarFace:Fern` | 4.5 | 6.19 | 8.16 | 7.65 | 8.42 | pass |
| Avatar initials, Sea | `avatarInk:Sea` | `avatarFace:Sea` | 4.5 | 6.22 | 8.10 | 7.56 | 8.49 | pass |
| Avatar initials, Slate | `avatarInk:Slate` | `avatarFace:Slate` | 4.5 | 6.81 | 7.92 | 7.82 | 8.75 | pass |
| Avatar initials, Heather | `avatarInk:Heather` | `avatarFace:Heather` | 4.5 | 7.25 | 8.01 | 8.36 | 8.70 | pass |
| Avatar initials, Rose | `avatarInk:Rose` | `avatarFace:Rose` | 4.5 | 6.88 | 8.05 | 8.09 | 8.66 | pass |
| Avatar initials, Stone | `avatarInk:Stone` | `avatarFace:Stone` | 4.5 | 6.89 | 8.27 | 8.53 | 8.94 | pass |
| Day and week: event title on its Persimmon face | `ink` | `eventFace:Persimmon` | 4.5 | 14.42 | 11.27 | 16.09 | 14.42 | pass |
| Day and week: event time, place and queued glyph on its Persimmon face | `ink2` | `eventFace:Persimmon` | 4.5 | 6.70 | 6.48 | 10.00 | 10.06 | pass |
| Day and week: event title and time on its Persimmon face, hover | `ink` | `eventFace:Persimmon` + `hover` | 4.5 | 13.18 | 9.71 | 14.04 | 10.92 | pass |
| Day and week: event title and time on its Persimmon face, pressed | `ink` | `eventFace:Persimmon` + `pressed` | 4.5 | 12.09 | 8.48 | 12.46 | 8.98 | pass |
| Account ink Persimmon on its event face: the edge, a tentative event's dashed outline | `account:Persimmon` | `eventFace:Persimmon` | 3 (IC 3.5) | 3.65 | 3.62 | 4.50 | 4.71 | pass |
| Day and week: the selected conversation's margin rule on a Persimmon face | `selRule` | `eventFace:Persimmon` | 3 | 6.99 | 5.96 | 9.61 | 8.70 | pass |
| Day and week: the selected conversation's margin rule on a Persimmon face, window not key | `selRuleIdle` | `eventFace:Persimmon` | 3 | 5.54 | 5.38 | 7.90 | 8.15 | pass |
| Day and week: the overlap hatch on a Persimmon face | `warning` | `eventFace:Persimmon` | 3 | 5.50 | 6.78 | 7.81 | 8.81 | pass |
| Day and week: the failed glyph on a Persimmon face | `danger` | `eventFace:Persimmon` | 3 | 5.60 | 5.99 | 7.65 | 8.07 | pass |
| Account ink Persimmon on a pressed day cell | `account:Persimmon` | `paper` + `pressed` | 3 (IC 3.5) | 3.47 | 3.50 | 4.05 | 4.03 | pass |
| Account ink Persimmon on the folded strip, hover | `account:Persimmon` | `canvas` + `hover` | 3 (IC 3.5) | 3.54 | 4.24 | 4.09 | 5.19 | pass |
| Account ink Persimmon on the folded strip, pressed or open | `account:Persimmon` | `canvas` + `pressed` | 3 (IC 3.5) | 3.25 | 3.72 | 3.63 | 4.29 | pass |
| Day and week: event title on its Indigo face | `ink` | `eventFace:Indigo` | 4.5 | 13.52 | 11.11 | 15.07 | 14.24 | pass |
| Day and week: event time, place and queued glyph on its Indigo face | `ink2` | `eventFace:Indigo` | 4.5 | 6.28 | 6.38 | 9.36 | 9.94 | pass |
| Day and week: event title and time on its Indigo face, hover | `ink` | `eventFace:Indigo` + `hover` | 4.5 | 12.36 | 9.55 | 13.16 | 10.74 | pass |
| Day and week: event title and time on its Indigo face, pressed | `ink` | `eventFace:Indigo` + `pressed` | 4.5 | 11.36 | 8.34 | 11.69 | 8.83 | pass |
| Account ink Indigo on its event face: the edge, a tentative event's dashed outline | `account:Indigo` | `eventFace:Indigo` | 3 (IC 3.5) | 9.36 | 3.58 | 11.23 | 4.64 | pass |
| Day and week: the selected conversation's margin rule on a Indigo face | `selRule` | `eventFace:Indigo` | 3 | 6.55 | 5.88 | 9.00 | 8.59 | pass |
| Day and week: the selected conversation's margin rule on a Indigo face, window not key | `selRuleIdle` | `eventFace:Indigo` | 3 | 5.19 | 5.30 | 7.40 | 8.05 | pass |
| Day and week: the overlap hatch on a Indigo face | `warning` | `eventFace:Indigo` | 3 | 5.16 | 6.68 | 7.31 | 8.71 | pass |
| Day and week: the failed glyph on a Indigo face | `danger` | `eventFace:Indigo` | 3 | 5.24 | 5.91 | 7.16 | 7.97 | pass |
| Account ink Indigo on a pressed day cell | `account:Indigo` | `paper` + `pressed` | 3 (IC 3.5) | 9.52 | 3.51 | 10.79 | 4.02 | pass |
| Account ink Indigo on the folded strip, hover | `account:Indigo` | `canvas` + `hover` | 3 (IC 3.5) | 9.70 | 4.26 | 10.90 | 5.18 | pass |
| Account ink Indigo on the folded strip, pressed or open | `account:Indigo` | `canvas` + `pressed` | 3 (IC 3.5) | 8.90 | 3.74 | 9.66 | 4.28 | pass |
| Day and week: event title on its Lilac face | `ink` | `eventFace:Lilac` | 4.5 | 14.64 | 9.63 | 16.29 | 12.78 | pass |
| Day and week: event time, place and queued glyph on its Lilac face | `ink2` | `eventFace:Lilac` | 4.5 | 6.80 | 5.53 | 10.12 | 8.92 | pass |
| Day and week: event title and time on its Lilac face, hover | `ink` | `eventFace:Lilac` + `hover` | 4.5 | 13.37 | 8.29 | 14.20 | 9.64 | pass |
| Day and week: event title and time on its Lilac face, pressed | `ink` | `eventFace:Lilac` + `pressed` | 4.5 | 12.27 | 7.27 | 12.60 | 7.97 | pass |
| Account ink Lilac on its event face: the edge, a tentative event's dashed outline | `account:Lilac` | `eventFace:Lilac` | 3 (IC 3.5) | 3.68 | 7.43 | 4.53 | 8.15 | pass |
| Day and week: the selected conversation's margin rule on a Lilac face | `selRule` | `eventFace:Lilac` | 3 | 7.09 | 5.09 | 9.73 | 7.71 | pass |
| Day and week: the selected conversation's margin rule on a Lilac face, window not key | `selRuleIdle` | `eventFace:Lilac` | 3 | 5.62 | 4.59 | 8.00 | 7.22 | pass |
| Day and week: the overlap hatch on a Lilac face | `warning` | `eventFace:Lilac` | 3 | 5.58 | 5.79 | 7.90 | 7.81 | pass |
| Day and week: the failed glyph on a Lilac face | `danger` | `eventFace:Lilac` | 3 | 5.68 | 5.12 | 7.74 | 7.15 | pass |
| Account ink Lilac on a pressed day cell | `account:Lilac` | `paper` + `pressed` | 3 (IC 3.5) | 3.46 | 8.42 | 4.02 | 7.88 | pass |
| Account ink Lilac on the folded strip, hover | `account:Lilac` | `canvas` + `hover` | 3 (IC 3.5) | 3.52 | 10.19 | 4.06 | 10.15 | pass |
| Account ink Lilac on the folded strip, pressed or open | `account:Lilac` | `canvas` + `pressed` | 3 (IC 3.5) | 3.23 | 8.96 | 3.60 | 8.38 | pass |
| Day and week: event title on its Jade face | `ink` | `eventFace:Jade` | 4.5 | 13.92 | 10.82 | 15.55 | 14.37 | pass |
| Day and week: event time, place and queued glyph on its Jade face | `ink2` | `eventFace:Jade` | 4.5 | 6.46 | 6.22 | 9.66 | 10.03 | pass |
| Day and week: event title and time on its Jade face, hover | `ink` | `eventFace:Jade` + `hover` | 4.5 | 12.72 | 9.30 | 13.57 | 10.84 | pass |
| Day and week: event title and time on its Jade face, pressed | `ink` | `eventFace:Jade` + `pressed` | 4.5 | 11.68 | 8.13 | 12.05 | 8.91 | pass |
| Account ink Jade on its event face: the edge, a tentative event's dashed outline | `account:Jade` | `eventFace:Jade` | 3 (IC 3.5) | 5.83 | 4.41 | 7.23 | 4.51 | pass |
| Day and week: the selected conversation's margin rule on a Jade face | `selRule` | `eventFace:Jade` | 3 | 6.74 | 5.72 | 9.29 | 8.67 | pass |
| Day and week: the selected conversation's margin rule on a Jade face, window not key | `selRuleIdle` | `eventFace:Jade` | 3 | 5.35 | 5.16 | 7.63 | 8.12 | pass |
| Day and week: the overlap hatch on a Jade face | `warning` | `eventFace:Jade` | 3 | 5.31 | 6.51 | 7.55 | 8.78 | pass |
| Day and week: the failed glyph on a Jade face | `danger` | `eventFace:Jade` | 3 | 5.40 | 5.75 | 7.39 | 8.03 | pass |
| Account ink Jade on a pressed day cell | `account:Jade` | `paper` + `pressed` | 3 (IC 3.5) | 5.76 | 4.44 | 6.73 | 3.88 | pass |
| Account ink Jade on the folded strip, hover | `account:Jade` | `canvas` + `hover` | 3 (IC 3.5) | 5.87 | 5.38 | 6.80 | 5.00 | pass |
| Account ink Jade on the folded strip, pressed or open | `account:Jade` | `canvas` + `pressed` | 3 (IC 3.5) | 5.38 | 4.73 | 6.03 | 4.13 | pass |
| Day and week: event title on its Iris face | `ink` | `eventFace:Iris` | 4.5 | 13.96 | 10.40 | 15.76 | 13.75 | pass |
| Day and week: event time, place and queued glyph on its Iris face | `ink2` | `eventFace:Iris` | 4.5 | 6.48 | 5.97 | 9.79 | 9.60 | pass |
| Day and week: event title and time on its Iris face, hover | `ink` | `eventFace:Iris` + `hover` | 4.5 | 12.76 | 8.94 | 13.75 | 10.37 | pass |
| Day and week: event title and time on its Iris face, pressed | `ink` | `eventFace:Iris` + `pressed` | 4.5 | 11.71 | 7.82 | 12.21 | 8.54 | pass |
| Account ink Iris on its event face: the edge, a tentative event's dashed outline | `account:Iris` | `eventFace:Iris` | 3 (IC 3.5) | 5.88 | 5.32 | 5.89 | 5.82 | pass |
| Day and week: the selected conversation's margin rule on a Iris face | `selRule` | `eventFace:Iris` | 3 | 6.76 | 5.50 | 9.41 | 8.30 | pass |
| Day and week: the selected conversation's margin rule on a Iris face, window not key | `selRuleIdle` | `eventFace:Iris` | 3 | 5.36 | 4.96 | 7.74 | 7.77 | pass |
| Day and week: the overlap hatch on a Iris face | `warning` | `eventFace:Iris` | 3 | 5.32 | 6.25 | 7.65 | 8.40 | pass |
| Day and week: the failed glyph on a Iris face | `danger` | `eventFace:Iris` | 3 | 5.41 | 5.53 | 7.49 | 7.69 | pass |
| Account ink Iris on a pressed day cell | `account:Iris` | `paper` + `pressed` | 3 (IC 3.5) | 5.79 | 5.58 | 5.41 | 5.22 | pass |
| Account ink Iris on the folded strip, hover | `account:Iris` | `canvas` + `hover` | 3 (IC 3.5) | 5.90 | 6.76 | 5.47 | 6.73 | pass |
| Account ink Iris on the folded strip, pressed or open | `account:Iris` | `canvas` + `pressed` | 3 (IC 3.5) | 5.41 | 5.94 | 4.85 | 5.56 | pass |
| Day and week: event title on its Fern face | `ink` | `eventFace:Fern` | 4.5 | 14.63 | 9.62 | 16.28 | 12.35 | pass |
| Day and week: event time, place and queued glyph on its Fern face | `ink2` | `eventFace:Fern` | 4.5 | 6.79 | 5.53 | 10.11 | 8.62 | pass |
| Day and week: event title and time on its Fern face, hover | `ink` | `eventFace:Fern` + `hover` | 4.5 | 13.37 | 8.28 | 14.20 | 9.32 | pass |
| Day and week: event title and time on its Fern face, pressed | `ink` | `eventFace:Fern` + `pressed` | 4.5 | 12.26 | 7.26 | 12.59 | 7.73 | pass |
| Account ink Fern on its event face: the edge, a tentative event's dashed outline | `account:Fern` | `eventFace:Fern` | 3 (IC 3.5) | 3.69 | 7.47 | 4.56 | 9.35 | pass |
| Day and week: the selected conversation's margin rule on a Fern face | `selRule` | `eventFace:Fern` | 3 | 7.09 | 5.09 | 9.73 | 7.45 | pass |
| Day and week: the selected conversation's margin rule on a Fern face, window not key | `selRuleIdle` | `eventFace:Fern` | 3 | 5.62 | 4.59 | 7.99 | 6.98 | pass |
| Day and week: the overlap hatch on a Fern face | `warning` | `eventFace:Fern` | 3 | 5.58 | 5.79 | 7.90 | 7.55 | pass |
| Day and week: the failed glyph on a Fern face | `danger` | `eventFace:Fern` | 3 | 5.68 | 5.12 | 7.74 | 6.91 | pass |
| Account ink Fern on a pressed day cell | `account:Fern` | `paper` + `pressed` | 3 (IC 3.5) | 3.47 | 8.47 | 4.05 | 9.34 | pass |
| Account ink Fern on the folded strip, hover | `account:Fern` | `canvas` + `hover` | 3 (IC 3.5) | 3.53 | 10.26 | 4.09 | 12.03 | pass |
| Account ink Fern on the folded strip, pressed or open | `account:Fern` | `canvas` + `pressed` | 3 (IC 3.5) | 3.24 | 9.01 | 3.63 | 9.94 | pass |
| Day and week: event title on its Umber face | `ink` | `eventFace:Umber` | 4.5 | 13.48 | 11.12 | 15.30 | 14.27 | pass |
| Day and week: event time, place and queued glyph on its Umber face | `ink2` | `eventFace:Umber` | 4.5 | 6.26 | 6.39 | 9.51 | 9.96 | pass |
| Day and week: event title and time on its Umber face, hover | `ink` | `eventFace:Umber` + `hover` | 4.5 | 12.33 | 9.56 | 13.36 | 10.77 | pass |
| Day and week: event title and time on its Umber face, pressed | `ink` | `eventFace:Umber` + `pressed` | 4.5 | 11.33 | 8.35 | 11.87 | 8.86 | pass |
| Account ink Umber on its event face: the edge, a tentative event's dashed outline | `account:Umber` | `eventFace:Umber` | 3 (IC 3.5) | 9.37 | 3.58 | 9.53 | 4.64 | pass |
| Day and week: the selected conversation's margin rule on a Umber face | `selRule` | `eventFace:Umber` | 3 | 6.53 | 5.88 | 9.14 | 8.61 | pass |
| Day and week: the selected conversation's margin rule on a Umber face, window not key | `selRuleIdle` | `eventFace:Umber` | 3 | 5.18 | 5.31 | 7.51 | 8.06 | pass |
| Day and week: the overlap hatch on a Umber face | `warning` | `eventFace:Umber` | 3 | 5.14 | 6.69 | 7.43 | 8.72 | pass |
| Day and week: the failed glyph on a Umber face | `danger` | `eventFace:Umber` | 3 | 5.23 | 5.91 | 7.27 | 7.98 | pass |
| Account ink Umber on a pressed day cell | `account:Umber` | `paper` + `pressed` | 3 (IC 3.5) | 9.56 | 3.50 | 9.02 | 4.01 | pass |
| Account ink Umber on the folded strip, hover | `account:Umber` | `canvas` + `hover` | 3 (IC 3.5) | 9.74 | 4.24 | 9.11 | 5.17 | pass |
| Account ink Umber on the folded strip, pressed or open | `account:Umber` | `canvas` + `pressed` | 3 (IC 3.5) | 8.93 | 3.73 | 8.08 | 4.27 | pass |
| Day and week: event title on its Azure face | `ink` | `eventFace:Azure` | 4.5 | 14.40 | 11.27 | 16.14 | 14.29 | pass |
| Day and week: event time, place and queued glyph on its Azure face | `ink2` | `eventFace:Azure` | 4.5 | 6.68 | 6.48 | 10.03 | 9.97 | pass |
| Day and week: event title and time on its Azure face, hover | `ink` | `eventFace:Azure` + `hover` | 4.5 | 13.15 | 9.70 | 14.08 | 10.78 | pass |
| Day and week: event title and time on its Azure face, pressed | `ink` | `eventFace:Azure` + `pressed` | 4.5 | 12.07 | 8.47 | 12.49 | 8.86 | pass |
| Account ink Azure on its event face: the edge, a tentative event's dashed outline | `account:Azure` | `eventFace:Azure` | 3 (IC 3.5) | 3.63 | 3.62 | 4.51 | 4.66 | pass |
| Day and week: the selected conversation's margin rule on a Azure face | `selRule` | `eventFace:Azure` | 3 | 6.97 | 5.97 | 9.64 | 8.62 | pass |
| Day and week: the selected conversation's margin rule on a Azure face, window not key | `selRuleIdle` | `eventFace:Azure` | 3 | 5.53 | 5.38 | 7.93 | 8.07 | pass |
| Day and week: the overlap hatch on a Azure face | `warning` | `eventFace:Azure` | 3 | 5.49 | 6.78 | 7.83 | 8.73 | pass |
| Day and week: the failed glyph on a Azure face | `danger` | `eventFace:Azure` | 3 | 5.58 | 6.00 | 7.67 | 7.99 | pass |
| Account ink Azure on a pressed day cell | `account:Azure` | `paper` + `pressed` | 3 (IC 3.5) | 3.46 | 3.50 | 4.04 | 4.02 | pass |
| Account ink Azure on the folded strip, hover | `account:Azure` | `canvas` + `hover` | 3 (IC 3.5) | 3.53 | 4.24 | 4.08 | 5.18 | pass |
| Account ink Azure on the folded strip, pressed or open | `account:Azure` | `canvas` + `pressed` | 3 (IC 3.5) | 3.24 | 3.73 | 3.62 | 4.28 | pass |
| Day and week: event title on its Mulberry face | `ink` | `eventFace:Mulberry` | 4.5 | 13.76 | 11.11 | 15.53 | 14.25 | pass |
| Day and week: event time, place and queued glyph on its Mulberry face | `ink2` | `eventFace:Mulberry` | 4.5 | 6.39 | 6.38 | 9.65 | 9.94 | pass |
| Day and week: event title and time on its Mulberry face, hover | `ink` | `eventFace:Mulberry` + `hover` | 4.5 | 12.58 | 9.55 | 13.55 | 10.75 | pass |
| Day and week: event title and time on its Mulberry face, pressed | `ink` | `eventFace:Mulberry` + `pressed` | 4.5 | 11.55 | 8.34 | 12.03 | 8.84 | pass |
| Account ink Mulberry on its event face: the edge, a tentative event's dashed outline | `account:Mulberry` | `eventFace:Mulberry` | 3 (IC 3.5) | 7.49 | 3.58 | 7.54 | 4.64 | pass |
| Day and week: the selected conversation's margin rule on a Mulberry face | `selRule` | `eventFace:Mulberry` | 3 | 6.66 | 5.88 | 9.28 | 8.60 | pass |
| Day and week: the selected conversation's margin rule on a Mulberry face, window not key | `selRuleIdle` | `eventFace:Mulberry` | 3 | 5.29 | 5.30 | 7.62 | 8.05 | pass |
| Day and week: the overlap hatch on a Mulberry face | `warning` | `eventFace:Mulberry` | 3 | 5.25 | 6.69 | 7.54 | 8.71 | pass |
| Day and week: the failed glyph on a Mulberry face | `danger` | `eventFace:Mulberry` | 3 | 5.34 | 5.91 | 7.38 | 7.97 | pass |
| Account ink Mulberry on a pressed day cell | `account:Mulberry` | `paper` + `pressed` | 3 (IC 3.5) | 7.48 | 3.51 | 7.03 | 4.02 | pass |
| Account ink Mulberry on the folded strip, hover | `account:Mulberry` | `canvas` + `hover` | 3 (IC 3.5) | 7.63 | 4.26 | 7.10 | 5.18 | pass |
| Account ink Mulberry on the folded strip, pressed or open | `account:Mulberry` | `canvas` + `pressed` | 3 (IC 3.5) | 6.99 | 3.74 | 6.30 | 4.28 | pass |
| Day and week: event title on its Graphite face | `ink` | `eventFace:Graphite` | 4.5 | 14.35 | 10.35 | 16.06 | 13.43 | pass |
| Day and week: event time, place and queued glyph on its Graphite face | `ink2` | `eventFace:Graphite` | 4.5 | 6.66 | 5.95 | 9.97 | 9.37 | pass |
| Day and week: event title and time on its Graphite face, hover | `ink` | `eventFace:Graphite` + `hover` | 4.5 | 13.11 | 8.90 | 14.00 | 10.12 | pass |
| Day and week: event title and time on its Graphite face, pressed | `ink` | `eventFace:Graphite` + `pressed` | 4.5 | 12.04 | 7.78 | 12.43 | 8.34 | pass |
| Account ink Graphite on its event face: the edge, a tentative event's dashed outline | `account:Graphite` | `eventFace:Graphite` | 3 (IC 3.5) | 4.67 | 5.31 | 5.41 | 6.45 | pass |
| Day and week: the selected conversation's margin rule on a Graphite face | `selRule` | `eventFace:Graphite` | 3 | 6.95 | 5.48 | 9.59 | 8.10 | pass |
| Day and week: the selected conversation's margin rule on a Graphite face, window not key | `selRuleIdle` | `eventFace:Graphite` | 3 | 5.51 | 4.94 | 7.88 | 7.59 | pass |
| Day and week: the overlap hatch on a Graphite face | `warning` | `eventFace:Graphite` | 3 | 5.47 | 6.23 | 7.79 | 8.20 | pass |
| Day and week: the failed glyph on a Graphite face | `danger` | `eventFace:Graphite` | 3 | 5.57 | 5.51 | 7.63 | 7.51 | pass |
| Account ink Graphite on a pressed day cell | `account:Graphite` | `paper` + `pressed` | 3 (IC 3.5) | 4.47 | 5.59 | 4.88 | 5.93 | pass |
| Account ink Graphite on the folded strip, hover | `account:Graphite` | `canvas` + `hover` | 3 (IC 3.5) | 4.56 | 6.77 | 4.93 | 7.64 | pass |
| Account ink Graphite on the folded strip, pressed or open | `account:Graphite` | `canvas` + `pressed` | 3 (IC 3.5) | 4.18 | 5.95 | 4.37 | 6.31 | pass |

**Graphite.** Every pair above that touches an accent-family token, regenerated with the substitutions of §3.1 (`graphiteContrastPairs` in `tokens.json`, asserted by the same test): 123 pairs × 4 modes = 492 checks, 0 failures. Smallest margins: Graphite · Swipe button icon and label (white) on Archive's fill 4.69 (Dark, needs 4.5); Graphite · Account ink Lilac on selected row 3.77 (Light IC, needs 3.5); Graphite · Account ink Azure on selected row 3.79 (Light IC, needs 3.5); Graphite · Account ink Persimmon on selected row 3.79 (Light IC, needs 3.5).

| Pair | Foreground | Background (composited left to right) | Need | Light | Dark | Light IC | Dark IC |  |
|---|---|---|---|---|---|---|---|---|
| Graphite · Row sender/subject, selected (window key) | `ink` | `selWashIdle` | 4.5 | 13.90 | 12.00 | 13.56 | 13.70 | pass |
| Graphite · Row snippet, selected | `ink2` | `selWashIdle` | 4.5 | 6.46 | 6.89 | 8.42 | 9.56 | pass |
| Graphite · Row time (read), selected | `ink3` | `selWashIdle` | 4.5 | 5.34 | 5.72 | 6.66 | 7.74 | pass |
| Graphite · Row time (unread, Iron Gall Semibold), rest | `ink` | `paper` | 4.5 | 16.45 | 14.23 | 18.82 | 18.86 | pass |
| Graphite · Row time (unread), hover | `ink` | `paper` + `hover` | 4.5 | 15.00 | 12.45 | 16.36 | 15.02 | pass |
| Graphite · Row time (unread), selected | `ink` | `selWashIdle` | 4.5 | 13.90 | 12.00 | 13.56 | 13.70 | pass |
| Graphite · Row time (unread), selected idle | `ink` | `selWashIdle` | 4.5 | 13.90 | 12.00 | 13.56 | 13.70 | pass |
| Graphite · Row time (Outbox, failed send), selected | `danger` | `selWashIdle` | 4.5 | 5.39 | 6.38 | 6.44 | 7.66 | pass |
| Graphite · Row count badge numerals, selected | `ink2` | `selWashIdle` + `fill` | 4.5 | 5.77 | 5.55 | 7.10 | 6.50 | pass |
| Graphite · Tag text on the selected Settings account row | `ink2` | `selWashIdle` | 4.5 | 6.46 | 6.89 | 8.42 | 9.56 | pass |
| Graphite · Tag edge on the selected Settings account row | `ruleStrong` | `selWashIdle` | 3 | 3.49 | 3.97 | 4.88 | 5.09 | pass |
| Graphite · Unread pip, rest | `ink` | `paper` | 3 | 16.45 | 14.23 | 18.82 | 18.86 | pass |
| Graphite · Unread pip, hover | `ink` | `paper` + `hover` | 3 | 15.00 | 12.45 | 16.36 | 15.02 | pass |
| Graphite · Unread pip, selected | `ink` | `selWashIdle` | 3 | 13.90 | 12.00 | 13.56 | 13.70 | pass |
| Graphite · Unread pip, selected idle | `ink` | `selWashIdle` | 3 | 13.90 | 12.00 | 13.56 | 13.70 | pass |
| Graphite · Star glyph, selected | `star` | `selWashIdle` | 3 | 5.43 | 7.24 | 6.61 | 8.40 | pass |
| Graphite · Paperclip glyph, selected | `ink2` | `selWashIdle` | 3 | 6.46 | 6.89 | 8.42 | 9.56 | pass |
| Graphite · Queued glyph, selected | `ink3` | `selWashIdle` | 3 | 5.34 | 5.72 | 6.66 | 7.74 | pass |
| Graphite · Failed glyph, selected | `danger` | `selWashIdle` | 3 | 5.39 | 6.38 | 6.44 | 7.66 | pass |
| Graphite · Margin rule vs selection wash | `ink` | `selWashIdle` | 3 | 13.90 | 12.00 | 13.56 | 13.70 | pass |
| Graphite · Margin rule vs adjacent paper | `ink` | `paper` | 3 | 16.45 | 14.23 | 18.82 | 18.86 | pass |
| Graphite · Account initial tile letter, selected | `ink2` | `selWashIdle` | 4.5 | 6.46 | 6.89 | 8.42 | 9.56 | pass |
| Graphite · Swipe button icon and label (white) on Archive's fill | `onSwipe` | `swipeArchiveNeutral` | 4.5 | 15.87 | 4.69 | 18.98 | 4.82 | pass |
| Graphite · Swipe Archive fill beside the row, rest | `swipeArchiveNeutral` | `paper` | 3 | 15.19 | 3.67 | 18.52 | 3.91 | pass |
| Graphite · Swipe Archive fill beside the row, hover | `swipeArchiveNeutral` | `paper` + `hover` | 2.5 | 13.85 | 3.21 | 16.10 | 3.11 | pass |
| Graphite · Swipe Archive fill beside the row, selected | `swipeArchiveNeutral` | `selWashIdle` | 1.9 | 12.84 | 3.10 | 13.34 | 2.84 | pass |
| Graphite · Swipe Archive fill beside the row, selected idle | `swipeArchiveNeutral` | `selWashIdle` | 2.3 | 12.84 | 3.10 | 13.34 | 2.84 | pass |
| Graphite · Swipe Mark as Read or Unread fill beside the row, selected | `swipeRead` | `selWashIdle` | 1.2 | 4.20 | 1.74 | 4.64 | 1.56 | pass |
| Graphite · Sync line action link | `ink` | `paper` | 4.5 | 16.45 | 14.23 | 18.82 | 18.86 | pass |
| Graphite · Contrail (sync progress) vs list | `ink` | `paper` | 3 | 16.45 | 14.23 | 18.82 | 18.86 | pass |
| Graphite · Rail margin rule | `ink` | `spine` | 3 | 14.16 | 15.59 | 14.64 | 20.04 | pass |
| Graphite · Rail unread badge fill vs rail | `ink` | `spine` | 3 | 14.16 | 15.59 | 14.64 | 20.04 | pass |
| Graphite · Rail unread badge numerals | `paper` | `ink` | 4.5 | 16.45 | 14.23 | 18.82 | 18.86 | pass |
| Graphite · Rail focus ring | `ink` | `spine` | 3 | 14.16 | 15.59 | 14.64 | 20.04 | pass |
| Graphite · Minimal-mode new-mail dot | `ink` | `paper` | 3 | 16.45 | 14.23 | 18.82 | 18.86 | pass |
| Graphite · Stack unread pip | `ink` | `sheet` | 3 | 17.04 | 13.11 | 19.29 | 17.21 | pass |
| Graphite · Original colors action (on) | `ink` | `selWashIdle` | 3 | 13.90 | 12.00 | 13.56 | 13.70 | pass |
| Graphite · Original colors action (on), hover | `ink` | `selWashIdle` + `hover` | 3 | 12.71 | 10.33 | 11.87 | 10.32 | pass |
| Graphite · Original colors action (on), pressed | `ink` | `selWashIdle` + `pressed` | 3 | 11.67 | 9.01 | 10.57 | 8.51 | pass |
| Graphite · Quoted toggle label (unfolded) | `ink` | `selWashIdle` | 4.5 | 13.90 | 12.00 | 13.56 | 13.70 | pass |
| Graphite · Quoted toggle label (unfolded), hover | `ink` | `selWashIdle` + `hover` | 4.5 | 12.71 | 10.33 | 11.87 | 10.32 | pass |
| Graphite · Quoted toggle label (unfolded), pressed | `ink` | `selWashIdle` + `pressed` | 4.5 | 11.67 | 9.01 | 10.57 | 8.51 | pass |
| Graphite · Load images link, rest and hover (hover adds the underline; link buttons never take a wash) | `ink` | `sheet` + `fill` | 4.5 | 15.17 | 10.62 | 16.10 | 11.94 | pass |
| Graphite · Attachment progress fill | `ink` | `sheet` | 3 | 17.04 | 13.11 | 19.29 | 17.21 | pass |
| Graphite · Card focus ring on desk | `ink` | `canvas` | 3 | 15.35 | 14.94 | 16.78 | 19.54 | pass |
| Graphite · Quick reply strip contrail | `ink` | `sheet` | 3 | 17.04 | 13.11 | 19.29 | 17.21 | pass |
| Graphite · Composer format toggle glyph (on) | `ink` | `selWashIdle` | 3 | 13.90 | 12.00 | 13.56 | 13.70 | pass |
| Graphite · Composer format toggle glyph (on), hover | `ink` | `selWashIdle` + `hover` | 3 | 12.71 | 10.33 | 11.87 | 10.32 | pass |
| Graphite · Composer body link | `ink` | `sheet` | 4.5 | 17.04 | 13.11 | 19.29 | 17.21 | pass |
| Graphite · Address token selected | `paper` | `ink` | 4.5 | 16.45 | 14.23 | 18.82 | 18.86 | pass |
| Graphite · Autocomplete highlighted name | `ink` | `selWashIdle` | 4.5 | 13.90 | 12.00 | 13.56 | 13.70 | pass |
| Graphite · Autocomplete highlighted address | `ink3` | `selWashIdle` | 4.5 | 5.34 | 5.72 | 6.66 | 7.74 | pass |
| Graphite · Autocomplete highlight margin rule vs highlight wash | `ink` | `selWashIdle` | 3 | 13.90 | 12.00 | 13.56 | 13.70 | pass |
| Graphite · Autocomplete highlight margin rule vs popover | `ink` | `raised` | 3 | 17.18 | 11.84 | 19.29 | 15.67 | pass |
| Graphite · Composer field-row focus ring (inset, on paper) | `ink` | `paper` | 3 | 16.45 | 14.23 | 18.82 | 18.86 | pass |
| Graphite · Composer body caret (the body's focus indicator) | `ink` | `sheet` | 3 | 17.04 | 13.11 | 19.29 | 17.21 | pass |
| Graphite · Composer drop label (Drop to attach) | `ink` | `sheet` | 4.5 | 17.04 | 13.11 | 19.29 | 17.21 | pass |
| Graphite · Primary button label | `paper` | `ink` | 4.5 | 16.45 | 14.23 | 18.82 | 18.86 | pass |
| Graphite · Primary button label, hover | `paper` | `ink2` | 4.5 | 7.64 | 8.18 | 11.69 | 13.16 | pass |
| Graphite · Primary button label, pressed | `paper` | `ink3` | 4.5 | 6.32 | 6.79 | 9.24 | 10.66 | pass |
| Graphite · Primary button focus ring vs paper gap | `ink` | `paper` | 3 | 16.45 | 14.23 | 18.82 | 18.86 | pass |
| Graphite · Link button | `ink` | `paper` | 4.5 | 16.45 | 14.23 | 18.82 | 18.86 | pass |
| Graphite · Link button on sheet | `ink` | `sheet` | 4.5 | 17.04 | 13.11 | 19.29 | 17.21 | pass |
| Graphite · Link button on desk | `ink` | `canvas` | 4.5 | 15.35 | 14.94 | 16.78 | 19.54 | pass |
| Graphite · Focus ring vs list | `ink` | `paper` | 3 | 16.45 | 14.23 | 18.82 | 18.86 | pass |
| Graphite · Focus ring vs sheet | `ink` | `sheet` | 3 | 17.04 | 13.11 | 19.29 | 17.21 | pass |
| Graphite · Focus ring vs desk | `ink` | `canvas` | 3 | 15.35 | 14.94 | 16.78 | 19.54 | pass |
| Graphite · Focus ring vs raised | `ink` | `raised` | 3 | 17.18 | 11.84 | 19.29 | 15.67 | pass |
| Graphite · Checkbox / radio on fill vs sheet | `ink` | `sheet` | 3 | 17.04 | 13.11 | 19.29 | 17.21 | pass |
| Graphite · Checkbox on fill vs desk | `ink` | `canvas` | 3 | 15.35 | 14.94 | 16.78 | 19.54 | pass |
| Graphite · Checkbox / radio on fill, hover (accentFillHover), vs sheet | `ink2` | `sheet` | 3 | 7.91 | 7.53 | 11.99 | 12.01 | pass |
| Graphite · Checkbox / radio on fill, hover, vs desk | `ink2` | `canvas` | 3 | 7.13 | 8.59 | 10.42 | 13.64 | pass |
| Graphite · Checkbox / radio on fill, pressed (controlOnPressed), vs sheet | `ink3` | `sheet` | 3 | 6.54 | 6.26 | 9.47 | 9.72 | pass |
| Graphite · Checkbox / radio on fill, pressed, vs desk | `ink3` | `canvas` | 3 | 5.90 | 7.13 | 8.24 | 11.04 | pass |
| Graphite · Checkmark on fill | `paper` | `ink` | 3 | 16.45 | 14.23 | 18.82 | 18.86 | pass |
| Graphite · Checkmark / radio dot on the hover fill | `paper` | `ink2` | 3 | 7.64 | 8.18 | 11.69 | 13.16 | pass |
| Graphite · Checkmark / radio dot on the pressed fill | `paper` | `ink3` | 3 | 6.32 | 6.79 | 9.24 | 10.66 | pass |
| Graphite · Toggle on track vs sheet (rest, hover and pressed: the track never takes a wash) | `ink` | `sheet` | 3 | 17.04 | 13.11 | 19.29 | 17.21 | pass |
| Graphite · Toggle knob on (on track), rest, hover and pressed (the press stretches the knob; its face never changes) | `paper` | `ink` | 3 | 16.45 | 14.23 | 18.82 | 18.86 | pass |
| Graphite · Toggle on track vs desk (rest, hover and pressed) | `ink` | `canvas` | 3 | 15.35 | 14.94 | 16.78 | 19.54 | pass |
| Graphite · Unread count badge numerals | `paper` | `ink` | 4.5 | 16.45 | 14.23 | 18.82 | 18.86 | pass |
| Graphite · Dot badge vs list | `ink` | `paper` | 3 | 16.45 | 14.23 | 18.82 | 18.86 | pass |
| Graphite · Determinate bar fill vs track | `ink` | `sheet` + `fill` | 3 | 15.17 | 10.62 | 16.10 | 11.94 | pass |
| Graphite · Settings selected row text | `ink` | `selWashIdle` | 4.5 | 13.90 | 12.00 | 13.56 | 13.70 | pass |
| Graphite · Settings selected row secondary | `ink2` | `selWashIdle` | 4.5 | 6.46 | 6.89 | 8.42 | 9.56 | pass |
| Graphite · Settings selection rule vs wash | `ink` | `selWashIdle` | 3 | 13.90 | 12.00 | 13.56 | 13.70 | pass |
| Graphite · Settings selection rule vs group | `ink` | `sheet` | 3 | 17.04 | 13.11 | 19.29 | 17.21 | pass |
| Graphite · Settings focus ring on desk | `ink` | `canvas` | 3 | 15.35 | 14.94 | 16.78 | 19.54 | pass |
| Graphite · Settings status: sign in required (selected) | `danger` | `selWashIdle` | 4.5 | 5.39 | 6.38 | 6.44 | 7.66 | pass |
| Graphite · Settings info banner link | `ink` | `infoWash` | 4.5 | 14.23 | 12.49 | 13.73 | 13.21 | pass |
| Graphite · Settings status: up to date glyph (selected) | `success` | `selWashIdle` | 3 | 5.24 | 7.06 | 6.43 | 8.39 | pass |
| Graphite · Settings status: retrying glyph (selected) | `warning` | `selWashIdle` | 3 | 5.30 | 7.22 | 6.58 | 8.37 | pass |
| Graphite · Settings status: waiting to sync (selected) | `ink3` | `selWashIdle` | 4.5 | 5.34 | 5.72 | 6.66 | 7.74 | pass |
| Graphite · Settings status: download bar (selected row) | `ink` | `selWashIdle` + `fill` | 3 | 12.42 | 9.66 | 11.43 | 9.31 | pass |
| Graphite · Theme name underline, chosen, Settings key | `ink` | `canvas` | 3 | 15.35 | 14.94 | 16.78 | 19.54 | pass |
| Graphite · Welcome demo link | `ink` | `paper` | 4.5 | 16.45 | 14.23 | 18.82 | 18.86 | pass |
| Graphite · Day and week: the selected conversation's time: its dashed line, its chip's edge and words | `ink` | `paper` | 4.5 | 16.45 | 14.23 | 18.82 | 18.86 | pass |
| Graphite · Day and week: a day cell taking a drop, its ring | `ink` | `paper` | 3 | 16.45 | 14.23 | 18.82 | 18.86 | pass |
| Graphite · Day and week: the drop ghost's dashed edge | `ink` | `selWashIdle` | 3 | 13.90 | 12.00 | 13.56 | 13.70 | pass |
| Graphite · Day and week: the drop ghost's day and time | `ink` | `selWashIdle` | 4.5 | 13.90 | 12.00 | 13.56 | 13.70 | pass |
| Graphite · Day and week: the strip's outline of the selected conversation's event, pressed or open | `ink` | `canvas` + `pressed` | 3 | 12.85 | 11.60 | 12.96 | 13.13 | pass |
| Graphite · Day and week: the strip's mail time, pressed or open | `ink` | `canvas` + `pressed` | 3 | 12.85 | 11.60 | 12.96 | 13.13 | pass |
| Graphite · The week's invitation card: the answered kicker | `ink` | `raised` | 4.5 | 17.18 | 11.84 | 19.29 | 15.67 | pass |
| Graphite · Account ink Persimmon on selected row | `account:Persimmon` | `selWashIdle` | 3 (IC 3.5) | 3.51 | 3.85 | 3.79 | 4.47 | pass |
| Graphite · Account ink Indigo on selected row | `account:Indigo` | `selWashIdle` | 3 (IC 3.5) | 9.63 | 3.87 | 10.11 | 4.46 | pass |
| Graphite · Account ink Lilac on selected row | `account:Lilac` | `selWashIdle` | 3 (IC 3.5) | 3.50 | 9.26 | 3.77 | 8.74 | pass |
| Graphite · Account ink Jade on selected row | `account:Jade` | `selWashIdle` | 3 (IC 3.5) | 5.82 | 4.89 | 6.30 | 4.30 | pass |
| Graphite · Account ink Iris on selected row | `account:Iris` | `selWashIdle` | 3 (IC 3.5) | 5.86 | 6.14 | 5.07 | 5.80 | pass |
| Graphite · Account ink Fern on selected row | `account:Fern` | `selWashIdle` | 3 (IC 3.5) | 3.51 | 9.32 | 3.80 | 10.36 | pass |
| Graphite · Account ink Umber on selected row | `account:Umber` | `selWashIdle` | 3 (IC 3.5) | 9.67 | 3.86 | 8.45 | 4.45 | pass |
| Graphite · Account ink Azure on selected row | `account:Azure` | `selWashIdle` | 3 (IC 3.5) | 3.50 | 3.86 | 3.79 | 4.46 | pass |
| Graphite · Account ink Mulberry on selected row | `account:Mulberry` | `selWashIdle` | 3 (IC 3.5) | 7.57 | 3.87 | 6.58 | 4.46 | pass |
| Graphite · Account ink Graphite on selected row | `account:Graphite` | `selWashIdle` | 3 (IC 3.5) | 4.52 | 6.15 | 4.57 | 6.58 | pass |
| Graphite · Day and week: the selected conversation's margin rule on a Persimmon face | `ink` | `eventFace:Persimmon` | 3 | 14.42 | 11.27 | 16.09 | 14.42 | pass |
| Graphite · Day and week: the selected conversation's margin rule on a Indigo face | `ink` | `eventFace:Indigo` | 3 | 13.52 | 11.11 | 15.07 | 14.24 | pass |
| Graphite · Day and week: the selected conversation's margin rule on a Lilac face | `ink` | `eventFace:Lilac` | 3 | 14.64 | 9.63 | 16.29 | 12.78 | pass |
| Graphite · Day and week: the selected conversation's margin rule on a Jade face | `ink` | `eventFace:Jade` | 3 | 13.92 | 10.82 | 15.55 | 14.37 | pass |
| Graphite · Day and week: the selected conversation's margin rule on a Iris face | `ink` | `eventFace:Iris` | 3 | 13.96 | 10.40 | 15.76 | 13.75 | pass |
| Graphite · Day and week: the selected conversation's margin rule on a Fern face | `ink` | `eventFace:Fern` | 3 | 14.63 | 9.62 | 16.28 | 12.35 | pass |
| Graphite · Day and week: the selected conversation's margin rule on a Umber face | `ink` | `eventFace:Umber` | 3 | 13.48 | 11.12 | 15.30 | 14.27 | pass |
| Graphite · Day and week: the selected conversation's margin rule on a Azure face | `ink` | `eventFace:Azure` | 3 | 14.40 | 11.27 | 16.14 | 14.29 | pass |
| Graphite · Day and week: the selected conversation's margin rule on a Mulberry face | `ink` | `eventFace:Mulberry` | 3 | 13.76 | 11.11 | 15.53 | 14.25 | pass |
| Graphite · Day and week: the selected conversation's margin rule on a Graphite face | `ink` | `eventFace:Graphite` | 3 | 14.35 | 10.35 | 16.06 | 13.43 | pass |

---

## 8. Implementation map

### 8.1 Token pipeline

| Artifact | Path | Produced by |
|---|---|---|
| Source of truth | `docs/design/tokens.json` | hand-edited |
| Generator | `scripts/tools/quire-tokens.swift` (plain Foundation script, no Node; `--check` lists stale outputs and runs first in `scripts/test.sh`) | — |
| Themes | `docs/design/source/themes_def.py` (the seeds), `themes_lib.py` (the rule), `theme_rules.py` (R0–R11), written by the build into `tokens.json` (`themes`, `linkOnPage`, `themeRules`, `themeChecks`) | `make.sh` |
| AppKit colours, fonts, metrics | `Sources/SSDesign/Generated/QuireTokens{Colors,Palettes,Typography,Scales,Layout,Content,Themes}.swift` (generated, one file per kind) in the `SSDesign` library target, which the app depends on and which imports AppKit, SwiftUI and QuartzCore but not SSCore, GRDB or WebKit | generator |
| Design runtime | `Sources/SSDesign/` beside the generated files: `QuireFont`, `QuireEnvironment`, `QuireLayerColors`, `Quire.Motion` (`finishAll()`), `QuireGlyph` and `QuireSVGPath`, `QuireSymbol` | hand |
| Accent asset | `Resources/Assets.xcassets/AccentColor.colorset` (four appearances), compiled into `Contents/Resources/Assets.car` by `scripts/build-app.sh` with `xcrun actool`, which also sets `NSAccentColorName = AccentColor` in the bundled Info.plist | generator |
| Reader CSS head | `Sources/SSCore/ConversationSupport/QuireCSS.swift` (generated string, interpolated at the top of `ConversationShellAssets.css`; it lives in SSCore because the shell is built there and SSCore does not import AppKit) | generator |
| Tests | `Tests/SSDesignTests/Generated/DesignContrastTests.swift`, `AccountPaletteTests.swift`, `ThemeRuleTests.swift`, `RadiusScaleTests.swift` (generated); `Tests/SSDesignTests/RowMetricsTests.swift`, `GlyphPathTests.swift` and the rest of `Tests/SSDesignTests/` (hand-written); `Tests/SSCoreTests/Conversation/QuireCSSTests.swift` (the CSS head against the specimen) | generator / hand |
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
- **Graphite.** The generator also emits the `graphite` table: each accent-family provider checks `Quire.isGraphite` (set from `NSColor.currentControlTint == .graphiteControlTint` or `controlAccentColor` saturation below 0.1, refreshed on `NSColor.systemColorsDidChangeNotification`) and returns its substitution, a token or the composite of a stack (for example `accentWashHover` → `selWashIdle + hover`, pre-composited per mode). A change re-resolves layer colours exactly like an appearance change; `RowContentCache` adds the flag to its key. The reader gets `html.ss-graphite`, whose generated block redefines the same `--q-*` variables.
- **Themes** (§4.16). `QuireEnvironment` carries the theme in its snapshot, beside Graphite and Increase Contrast, with `setTheme(_:)` (set at launch before the first window, and on every change, posted once) and `Overrides.theme`. A token that differs across themes carries one set of values per theme and one set of Graphite values per theme; the provider reads the theme from the snapshot it already reads for Graphite and Increase Contrast, then takes that theme's `NSColor`s (its Graphite ones under Graphite) from a `LockedCache` and indexes the mode. The cache makes them the first time that theme is drawn, so a theme never chosen costs only its static table; after that a resolution allocates nothing, but a themed token takes that cache's lock as well as the snapshot's, where a token with one set takes only the snapshot's. `NSColor.quire(_:theme:)` pins one theme (the theme tiles). `QuireEnvironment.cacheKey(for:)` stays theme-free, so no sender's avatar face is drawn again for a theme; the theme goes into the list's row-content key and the account-face key. Views that paint surfaces in `draw(_:)` otherwise redraw only on an appearance change, so `setTheme` ends with one **redraw sweep**: every view of every window, from the frame view down, is marked for display, and a window whose background is a Quire token takes it again. Every link that is underlined under Graphite asks `QuireEnvironment.underlinesLinksAtRest(for: appearance)`, which adds the theme's flag for the appearance's mode (`QuireButton`, `QuireEmptyStateView`, the sync line, the list footer's Retry).
- **App appearance.** Settings › Appearance › Appearance sets `NSApp.appearance` (`nil`, `.aqua`, `.darkAqua`), AppKit's own path, the one a system switch takes: every window, Settings, composers and the web views re-resolve. Increase Contrast keeps coming from `QuireEnvironment`, because AppKit does not report it for an appearance the app sets. `--theme=` and `--appearance=` win over the settings for one process.
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

**Components.** The AppKit components live in SSDesign's `AppKit/` folder, one public type per file: `QuireControl` (hover, pressed, focused and key state for every Quire-drawn control) and the controls on it (`QuireButton`, `QuireIconButton` (also a menu button that acts on mouse-down, Send's drop-down, §5.23), `QuirePopUpButton`, `QuireCheckbox`, `QuireRadioGroupView`, `QuireToggle`, `QuireTextField` with its secure variant, `QuireSearchField`, `QuireUnderlineTabs`), `QuireFindBar` (§5.50: the panel, its field and three icon buttons; the reader owns what they do), `QuireBannerView` (§5.38), the slips (`QuireSlipView`, `QuireUndoPanelView`, `QuireSequenceHUDView`), `QuireKeycap`, `QuireBadge`, `QuireTag`, `QuireAvatarRenderer`, `QuireHairline`, `QuireEmptyStateView`, `QuireSkeleton`, `QuireProgressBar`, `QuireContrailView` and `QuireSwipeButton` (the button a list row's swipe uncovers, §5.7). The banner and the radio group carry a `View` suffix because the SwiftUI versions own the plain names (`QuireBanner`, `QuireRadioGroup`, §8.3). `QuireWindowChrome` configures and measures the main, reader and composer windows (§3.2).

**Panels and overlays.** The undo-send `NSPanel` is borderless, non-activating, transparent and outset by `layout.undoPanel.shadowMargin*` (§5.31). The cheat sheet is an overlay view in the main window's content view, above the split view, with the scrim as its own layer (§5.32). The rail toggle sets the split item's `isCollapsed` inside `NSAnimationContext` with `duration = 0`.

**Motion.** `Quire.Motion.finishAll()` is called first in `KeyboardRouter.handle(_:)`: it walks the registered animators, sets each layer's model value to its final state inside `CATransaction.setDisableActions(true)` and removes running animations; `NSAnimationContext` groups run with `allowsImplicitAnimation` and the token durations; every animation checks `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`. A view that draws what moves, and must redraw at every step (a list row's swipe settling, §5.7), steps a value along the token curve once a frame with `QuireFrameAnimation` (`Curve.progress(at:)`, the curve Core Animation would follow), registered like the others so a keystroke finishes it.

### 8.3 SwiftUI (Settings)

SwiftUI does not resolve a `Color(nsColor:)` again when a provider's output changes, so Settings draws with **`QuireColorStyle`** instead: a `ShapeStyle` per token (`.qInk`, `.qCanvas`, …, generated) whose `resolve(in:)` reads `EnvironmentValues.quireTheme` and returns that theme's colour. Each tab is hosted in a `QuireThemeRoot`, which puts the theme, Graphite and Increase Contrast in the environment, so a switch redraws every view in place and keeps its identity, `@State` and keyboard focus (§4.16). A source test keeps `Color.q…` out of SwiftUI views. Fonts via `Font(QuireFont.role(.body))`. Window background `canvas`, assigned again on a theme change. The window and its `TabView` toolbar (tab style) are the system's; the accent asset tints the selected tab's symbol. Every control **inside** the tabs uses a Quire style, because native SwiftUI controls ignore Quire's metrics and colours and draw the system focus ring, which falls below 3:1 on `canvas`:

| Control | Implementation | Tokens |
|---|---|---|
| Focus ring (all controls below) | `.focusEffectDisabled()` on the control, `@FocusState` to know which is focused, and `.overlay` of a `RoundedRectangle(cornerRadius: controlRadius + gap)` stroked 2 pt (IC 3) in `Color.qFocus`, outset by gap + width/2 | `border.focusRing` (gap 1, 2 on fills) |
| Toggle | `QuireToggleStyle: ToggleStyle` draws the track (`Capsule`, 30 × 18, off `fill` + `ruleStrong` stroke, on `accentFill`; it never changes on hover or press) and the knob (`Circle`, 14 pt, `knob` face, 18 pt wide while `configuration.isPressed`, 1 pt `ruleStrong` stroke, `.shadow` from `layout.toggle.knobShadow`); knob offset animated with `dur.quick` `ease.glide` unless Reduce Motion; the label is `body` `ink` with an 8 pt gap and part of the tap target | `layout.toggle`, §5.26 |
| Checkbox | `QuireCheckboxStyle: ToggleStyle`: 14 pt `RoundedRectangle(cornerRadius: 3)`, off `sheet` + `ruleStrong` (face `sheet + hover` / `sheet + pressed`), on `accentFill` + `checkmark` 10 pt `onAccent` (hover `accentFillHover`, pressed `controlOnPressed`) | `layout.checkbox` |
| Radio group | `QuireRadioGroup` (a `HStack` of `Button`s, one per option, each with a 14 pt circle; on `accentFill` + 6 pt `onAccent` dot, hover and press as the checkbox); one Tab stop for the group, ← → move the choice; accessibility `.isSelected` and the radio-group container trait | `layout.radio` |
| Popup | `Menu { … } label: { QuirePopupLabel(value) }` with `.menuStyle(.borderlessButton)` and `.menuIndicator(.hidden)`; the label draws 24 pt `raised` face, `ruleStrong` edge, `body` `ink` value and the `chevron.up.chevron.down` 12 pt `ink2`; the menu itself is the system's, with a checkmark on the current value | `layout.popup` |
| Text field | `.textFieldStyle(.plain)` inside `QuireFieldStyle`, a container drawing the 24 pt `sheet` face, 1 pt `ruleStrong` edge (hover `ink3`, error 1.5 pt `danger`), padding 8; `mono` font for client IDs | `layout.textField` |
| Buttons | `QuireButtonStyle(.primary / .secondary / .ghost / .link, size: .small)` drawing §5.24 fills, edges and labels (`.link` never draws a wash: underline on hover, `ink2` + underline pressed) | `layout.button` |
| Account group | `VStack` of `QuireAccountRow`s in a `.focusable()` container (not `List(selection:)`), background per row: `selWash` / `selWashIdle` plus a 3 pt leading `Rectangle` in `selRule` / `selRuleIdle`, key state from `@Environment(\.controlActiveState)`; past 6 rows the stack sits in a `ScrollView` capped at 6 × 56 pt with clipped-edge hairlines, `ScrollViewReader` keeping the selection in view | §5.40 |
| Theme picker | `QuireThemePicker` (§5.40): five `QuireThemeTile`s, each a `QuireThemeMiniature` drawn in its own theme under the window's mode; one `.focusable()` stop, ← → ↑ ↓ through `onMoveCommand`, a native radio group for VoiceOver built from `radios(selection:)`; the chosen name's underline reads `controlActiveState` | `layout.settings.theme*` |
| Form layout | a `Grid` with a trailing-aligned 140 pt label column and 40 pt rows (`Form` with `.formStyle(.columns)` would bring native control styling back) | `layout.settings` |

`controlActiveState == .inactive` (Settings not key) switches the selection to the idle pair and primary buttons to the secondary look, as §3.4 lists; nothing else changes.

### 8.4 Reader (WKWebView) CSS

- The generated head defines every colour as `--q-<token>` in four blocks (`:root`, `@media (prefers-color-scheme: dark)`, `@media (prefers-contrast: more)`, both) plus `html.ss-ic` copies of the IC blocks and `html.ss-graphite` blocks that redefine the accent-family variables per mode (§3.1; the app sets the class), and in every block `--q-focusOnPage` and `--q-linkOnPage` (§4.16); typography as `--q-font-<role>` shorthands and `--q-track-<role>`; spacing `--q-s1…`; radii `--q-r-…`; durations `--q-dur-…`; curves `--q-ease-…`; elevation `--q-e1…`. The specimen's `<style>` head is this exact output.
- **Themes** (§4.16). The shell's head carries one `<style id="ss-theme">` after the generated head, holding the active theme's sheet, `QuireCSS.themeSheet(_:)`: the head's own selectors, in the head's order, with only the tokens that differ from Study (empty for Study), so IC and Graphite still win by the same specificity. A body document carries the cut of it, `ConversationShellAssets.bodyCut(_:)`, the same keep-list filter that cuts the body's variables from the head, so the two can never disagree. The pool builds its document in the active theme, so a new reader window paints its first frame in it. `ss.setTheme({id, shell, body, links, quoteLinks})` replaces the sheet in the shell and in every body document without reloading a frame, stamps `data-ss-theme` on each root, forces style resolution in every document and posts `themed`; a frame still loading during a switch has its stale sheet replaced once it lands. The web views' under-page colour (`canvas`, which shows while a render lands or the page overscrolls) is set again on a switch and on an appearance change. The print document carries the head alone (§5.48).
- **Link classes.** `ss-links` (every link) and `ss-qlinks` (links in quotes) are worked out from the theme's two flags for the current mode, and from Graphite, and toggled on the shell and every body document whenever the theme, the modes or the appearance change. They underline link buttons (`.ss-link`), invitation links (`.ss-ilink`), links in adapted bodies (`html.ss-adapt a`) and in Quire-set bodies (`body.ss-set a`), and, with `ss-qlinks`, links in their quotes (`body.ss-set blockquote a`, `body.ss-set .ss-quote a`), at rest, a sender's `text-decoration: none` included (`!important`).
- Current variables map as: `--ss-bg` → `--q-canvas`, `--ss-card` → `--q-sheet`, `--ss-border` → `--q-rule`, `--ss-text` → `--q-ink`, `--ss-muted` → `--q-ink2` (recipients, snippets) / `--q-ink3` (dates), `--ss-accent` → `--q-accent`, `--ss-chip` → `--q-fill`, `--ss-selected` → `--q-focus`, `--ss-star` → `--q-star`.
- Classes: `.ss-card` (expanded) → sheet (radius `r.lg`, padding per §5.14, `e1`); collapsed cards → `.ss-stack` rows joined in one sheet; `.ss-button` → `.ss-elide` toggle and link buttons; `.ss-chip` → attachment chip; `.ss-footer a` → ghost buttons; `.ss-tools` is removed (Original colors moves to the header hover actions).
- **Invitation card** (§5.14): `.ss-invite` (a `section` with `role="group"`) sits between the sheet header and `.ss-body`, `hidden` when the message has none. After it, `.ss-mrow` holds the message's elision mark (`.ss-elide.ss-toggle-message`), shown only on a sheet whose message has a card (`.ss-card.ss-mfold`, decided from the payload's `invitation`, never from the HTML). Folded (`.ss-mfolded`), `.ss-frame` is clipped to 0 pt, `visibility: hidden` and `inert`, with the quoted-text row hidden, while `.ss-banners` stays in view (12 below the mark, its last banner's bottom margin dropped); the frame is still loaded and measured at full width, so unfolding sets the sheet's height to the measured one and animates there like quoted text. A fold by “.” that hides the focused element (in the frame or the quoted-text row) focuses the mark. The shell posts `focusMark` (`on`) whenever keyboard focus lands on an `.ss-elide` mark or leaves one, and after a render; the app keeps it per pooled slot, and while the reader's web view has the window's focus and a mark has the page's (`ConversationViewController.isMarkFocused`), the router's ↩ (`.open`) and the reader's Space (`ReaderShortcuts.spaceOutcome`) let the key through to the page. The fold lives on the card in the script (`messageShown`, like `quotesShown`): `ss.update` keeps it, `ss.render` and a replaced body forget it. `ss.toggleQuotes()` (the “.” command) folds and unfolds the message on a sheet that has one, and quoted text elsewhere. `.ss-ikick`, `.ss-ititle`, `.ss-iwhen`, `.ss-ielse`, `.ss-irep`, the `.ss-idet` grid (72 pt label column), `.ss-iacts` with `.ss-ans` (small secondary; `.ss-chosen` the chosen answer, `aria-pressed`) and the `.ss-iopen` link button; `.ss-invite.ss-cancelled`; the permission notice is a `.ss-banner.ss-info.ss-wrap`. A click marks the answer in place and posts `answerInvitation` with the answer's name (`accepted`, `tentative`, `declined`); `openInCalendar`, `openInvitationLink` and `reconnectForInvitation` are the other actions. The payload carries the card display-ready (`RenderPayload.Invitation`); a patch rebuilds only the card when its JSON changed, and otherwise puts the chosen mark back on the payload's answer, so an answer the store refused or gave up never stays marked.
- **Text size** (§4.15): `QuireCSS.textSizes`, generated beside the head, redefines every `--q-font-<role>` at each other size under `html.ss-text-small`, `html.ss-text-large` and `html.ss-text-larger` (size and line height moved by the role's step). The shell's root and every body document carry the reader's class, so sheets and plain and unstyled bodies follow it and styled HTML, which never reads the variables, keeps its own sizes. `ss.preferences({textSize})` switches it in place and measures every body again; the payload carries it for a shell that renders later.
- `bodyCSS`: `body.ss-set { font: var(--q-font-reading); max-width: 576px; }` for bodies whose stored typesetting is `plain` or `unstyled` (the shell receives the flag in the render payload; it never scans the HTML); `body.ss-set.ss-sans { font: var(--q-font-readingSans) }` for the SF Pro font setting or uncovered scripts. It also injects the Quire focus ring for links, in every body document, because WebKit's default ring falls below 3:1 and a sender's CSS must not decide focus:

```css
a:focus { outline: none; }
a:focus-visible { outline: 2px solid var(--q-focus) !important; outline-offset: 1px !important;
                  box-shadow: 0 0 0 1px var(--q-sheet) !important; border-radius: 2px; }   /* 1 pt gap in the sheet colour */
@media (prefers-contrast: more) { a:focus-visible { outline-width: 3px !important; } }
html.ss-ic a:focus-visible { outline-width: 3px !important; }
.ss-original a:focus-visible { --q-focus: var(--q-focusOnPage); box-shadow: 0 0 0 1px var(--q-originalPage) !important; }
```

  `--q-focusOnPage` is the theme's light focus (Light IC's under Increase Contrast) in both appearances, since the Original colors page is white in both; under Graphite it is the theme's light `ink`. The light gap and the ring together stay visible on any sender background: on a dark band the gap shows, on a light one the ring does. The web view's `tabFocusesLinks` follows Full Keyboard Access (§5.14).
- **SF Symbols**: the shell builder receives `symbolCSS` (the data-URI custom properties, §4.11) from the app and emits `.ss-sym { width: 1.3em; height: 1.3em; background: currentColor; -webkit-mask: var(--sym) center / contain no-repeat; }` with one modifier class per symbol.
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
- **Spinner** (CSS): `.ss-spin { width: 12px; height: 12px; border-radius: 50%; border: 1.5px solid currentColor; border-right-color: transparent; animation: ss-turn var(--q-dur-spinnerTurn) linear infinite; } @keyframes ss-turn { to { transform: rotate(1turn); } }`; it shows only after `--q-dur-spinnerDelay` (`animation-delay` on an opacity fade-in). It matches AppKit's `QuireSpinnerView` (§5.37): same ¾ ring, stroke, turn and delay.
- **Bottom inset.** `ss.setBottomInset(px)` sets `padding-bottom` on the conversation container to the quick reply's height + 12, so the bar overlays the web view without resizing it (§5.18). Called once per height change, never per animation frame.
- **Wide HTML.** After each body iframe loads, the shell compares the body's `scrollWidth` with the sheet's content width (the inset's inner width in Original colors) and applies `zoom` (minimum 0.74) or `overflow-x: auto` (§5.14); `ss.refit()` recomputes all of them, called by the app when a live resize ends.
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
:where(a:link) { color: var(--q-linkOnPage); }           /* a link its sender left uncoloured: Study's accent (R11) */
.ss-page { padding: 0; background: transparent; }        /* every body frame's permanent wrapper */
.ss-page.ss-inset-on { background: var(--q-originalPage); border-radius: var(--q-r-xs);
               padding: 12px; color-scheme: light; }   /* the Original colors page */
```

  `ss.originalColors(id, on)` stores an explicit choice for one message and toggles `ss-adapt` and its page's `ss-inset-on`, then refits it; the frame is never built again. `ss.preferences({adaptsColours})` carries the Dark Mode default (§5.14), which the payload carries too; a message with no choice of its own follows it, and the shell posts the messages that show the sender's colours after every render, switch, appearance change and new default, which View › Original Colors reads. `.ss-original` stays the class on such a body document's root. Light appearances never add either.
- **Expand and collapse** follow §4.10. The shell keeps `heights[messageId + ':' + contentWidth]` from every measurement. On expand it sets the body wrapper's `height` from its current px value to header + (cached height, or the 58 pt skeleton) + footer with the transition on; each measurement (`0`, `50`, `300` ms, image `load`) sets `transition: none`, writes the measured px height, forces a style flush and restores the transition, so a measurement snaps instead of retargeting the animation. `ss.finishAll()` (called by `finishAll()`, §4.10) sets every running wrapper to its target with `transition: none`. Heights are always px, never `auto`.
- **Offline body.** When a message has no stored body (`hasBody = false`) the payload carries the snippet and an `offline` flag from the app: offline, the shell renders the preview and the neutral `wifi.slash` notice (§5.14) instead of the skeleton; online, it shows the skeleton only while the app reports the fetch in flight. Today's 0.6-opacity snippet (`.ss-pending-body`) is removed.
- **Find in conversation** (§5.50). `ss.find(query)`, `ss.findStep(±1)` and `ss.findClear()`; each posts `{kind: 'find', query, count, index}` too, as does a store refresh that changes the count, and the app shows only the report for the bar's own query. The shell folds text for comparison (case, accents, white space), breaks it at block elements and `br`, and reads a body with no frame from its HTML through `DOMParser`, whose document runs no script and loads nothing, by the same walk as a framed body, so the count never depends on what is expanded. Hidden text is read from each element's inline style as the browser parsed it (`element.style`, in a frame and in a parsed document alike), so a shorthand and `!important` count; a zero font size and `visibility: hidden` pass down the walk until an element undoes them. A parsed body keeps only its folded text, its plain-ASCII runs folded a text node at a time, so the first find in a conversation, which reads every collapsed body, stays inside the keystroke budget. Matches are wrapped in `mark.ss-find` (the current one also `.ss-find-now`) in the frames that have loaded, piece by piece across elements; `ss.findClear()` unwraps them and joins the split text nodes, so the body is exactly as parsed. The frames keep their sandbox and their blocking policy: the shell adds no script and no source to a body. Every body document carries:

```css
:root body mark.ss-find {
  background-color: var(--q-findWash) !important; color: var(--q-ink) !important; border-radius: var(--q-r-xs);
  padding: 0 !important; margin: 0 !important; box-decoration-break: clone;
}
:root body mark.ss-find.ss-find-now {
  background-color: var(--q-findCurrent) !important; box-shadow: 0 0 0 1px var(--q-ruleStrong) !important;
}
```

  `:root body` outranks the dark adaptation's `body *` and a sender's own `mark` rules. The current match is scrolled to the middle of the page with `scrollIntoView`, and the frame's own scroll is put back to the top, since a frame is as tall as its body.
- **Pointer** (§4.17). The shell's only cursor rules, so nothing later takes the hand away; a body document's rules come before a sender's sheet and outrank it by `!important` and specificity, `:root:root body *` (0,2,1) over a sender's rule of a class and tags, as mail stored before the sanitizer dropped senders' cursors may hold:

```css
button, [role="button"] { cursor: pointer; }                 /* the shell: every button and button-role element */
button:disabled, [aria-disabled="true"], .ss-ans.ss-chosen { cursor: default; }   /* and the chosen answer */
:root:root body, :root:root body * { cursor: auto !important; }                        /* every body: a sender's go */
:root body a[href], :root body a[href] *, :root body area[href],
:root:root body summary, :root:root body summary * { cursor: pointer !important; }     /* links and summaries */
:root body a[href="#"], :root body a[href="#"] *,
:root body a[href^="ss-cid:"], :root body a[href^="ss-cid:"] * { cursor: text !important; }   /* links to nothing */
```

- **Copy targets** (§5.14). Each recipient of the open list (`.ss-rp`) and the sender's address (`.ss-addr`, or the name `.ss-namet` when it is the address) is a `role="button"` span with `-webkit-user-select: none` and `data-addr` naming it by field and position (`to:1`, `from:0`); the open list's labels are not selectable either, so they keep the arrow with no cursor rule of their own. The face and the ring are drawn on an inner box (`.ss-face`), so the ring hugs the 20 pt face while the hit fills the 24 pt pitch. The truncating boxes clip pseudo-elements, so the toggle's and the sender address's extra hit is padding with an equal negative margin; open, the toggle holds the summary's width with a copy of it (`.ss-rcw`) that takes no height, is hidden and `aria-hidden`. A target's `mousedown` is cancelled (focus goes to the sheet), since WebKit focuses a span with a tabindex under the pointer where it focuses no button. A click, ↩ or Space posts `{kind: 'action', type: 'copyAddress', value: 'cc:2'}`, a right-click `personMenu` with the point; the app answers with `ss.addressCopied(id, value, form)` once the pasteboard has it, `ss.personMenuClosed()` and `ss.foldAddresses()` (Esc, §6.1). The focus report (`focusMark`) carries `on` (↩ and Space are the page's: a target, the toggle, “and 24 more”), `arrows` (← → too: a recipient, “and 24 more”), `addresses` (Esc folds) and `address` (`{messageID, value}`, what ⌘C copies); `ReaderWebView` answers `copy:` and enables Edit › Copy while it names an address, and otherwise leaves both to WebKit.
- **Target message.** `ss.target(id)` marks the target sheet (`.ss-target`: footer keycaps, and the `ruleStrong` edge when `.ss-multi` is on the container); the app calls it on click, `n`/`p`, Tab and open.
- **Skeleton** (CSS): `.ss-skel` bars in `--q-fill`, radius `--q-r-xs`, no animation.

### 8.5 Data the design needs

- `SanitizedBody` gains `typesetting: BodyTypesetting` (`.plain`, `.unstyled`, `.styled`) and `coveredByNewYork: Bool`, computed once by `HTMLSanitizer` at sync time; `bodies` gains `typesetting INTEGER NULL` (NULL = styled, for bodies stored earlier). This is a schema addition to `docs/DATA-MODEL.md` and needs the usual agreement; until it lands, every body renders as styled (no visual regression, just no serif page).
- `accounts` gains `ink_slot INTEGER` and `monogram TEXT NULL` (NULL = derived). Same agreement applies. The pre-Quire `color_hex` column is retired: nothing reads it, and it stays only because v1 declared it NOT NULL (new rows store an empty string). Account names are derived (§4.2), never stored.
- **`declaresColors: Bool`** on `SanitizedBody`, set by `HTMLSanitizer` at sync time when the body sets its own background or text colour (`bgcolor`, `background`, `color` in `style` attributes or `<style>` blocks, `<font color>`, `text`/`link` attributes on `body`); `bodies.declares_colors INTEGER NULL` (NULL = unknown: treated as true for `styled` bodies, false otherwise). It decides whether a body is adapted in dark appearances, and whether it gets the Original colors notice, hover action and inset (§5.14, §5.16), without scanning HTML at render time.
- **Calendar events and mail times** (1.9, §5.54): `calendar_events` (each account's main calendar for the window `CalendarWindow` keeps, with what this Mac set aside and has not sent or removed yet) and `mail_times` (the times a message's text names, found once when its body is stored), read through `CalendarStoring`; the selected conversation's invitation comes from its body as the card's does. The UI reads only the store; the engine's calendar reads ride the live lane (docs/ARCHITECTURE.md).
- **A failed-operation mark per conversation.** `ConversationSummary` has only `hasPendingOperations`; it gains `failedOperation: OperationKind?` (the kind of the newest operation with status `failed` on any message of the conversation that has not been acknowledged), backed by `conversations.failed_op_kind TEXT NULL` maintained in the same transaction that marks an operation failed. It clears (set to NULL) when the conversation is opened (selected for 150 ms), when a later operation on it is confirmed, or when the failed row is pruned after 24 hours. Same agreement applies.
- **Later** (§5.45): a `snoozes` table (the conversation, `due_at`, `created_at`) and `conversations.returned_at INTEGER NULL`, which the Inbox sorts, pages and groups by (`COALESCE(returned_at, latest_date_ms)`) and which carries the row's Back tag; `ConversationSummary` gains `returnedAt` and, in Later, `snoozedUntil` (docs/DATA-MODEL.md, v11).
- **Mute and sender rules** (1.7.0, §5.51, §5.52): `conversations.muted` (v16), carried by `ConversationSummary.isMuted` and the row's cache key, and a `sender_rules` table (v17: account, address, action); both applied to arriving mail inside the poll's write (`docs/DATA-MODEL.md`, "Arrival rules").
- **One preference**, `originalColorsNoticeDismissed` (UserDefaults), for §5.16.
- **List headers on the message** (1.6.3): `messages.list_unsubscribe` and `list_unsubscribe_post`, captured at sync time (`docs/DATA-MODEL.md`, v14). The render payload carries one flag per message, `unsubscribe`, set when they offer a way out (`UnsubscribeMethod`), so the shell decides nothing itself.
- **Invitations** (1.6.4, §5.14): the invitation a message carries is read once when its body is fetched and stored with it (`bodies.invitation_json`, v15): method, UID and revision (SEQUENCE, and DTSTAMP to order two with the same SEQUENCE), title, start and end (all-day, floating or in a zone), the zone, location and meeting link, organizer, attendees with their answers, the repeat rule as words, the user's own answer and whether they organized it, Microsoft's event id, and the calendar text Open in Calendar hands over. The answer given on this Mac is local state on the message (`messages.invitation_reply`, v15): written by the operation that queues it, never by a provider. Whether an account waits for calendar permission comes from the engine's status (`AccountSyncStatus.permissionsNeeded`), not the store.
- **Send Later** (1.7.0, §5.46): the outbox (`pending_sends`) holds the message with its time (`send_after`), two more statuses (`later`, waiting; `missed`, its time passed while the app was closed) and `draft_id`, the draft it was written in (`docs/DATA-MODEL.md`, v18). A Drafts row carries its state as `ConversationSummary.sendLater` (`SendLaterState`), and the render payload one flag per message, `cancelsSendLater`, set on a waiting message's draft sheet, whose `dateDisplay` then says when it sends.
- **The Outbox** (§5.53): no data of its own. Its rows come from the outbox as it is (`pending_sends`, read as summaries); an Outbox row carries its state as `ConversationSummary.outbox` (`OutboxState`, in the row's cache key), and its sheet the payload's `outbox` (`continues`, `failed`), absent on every other message. `MailboxView.outbox` is the last view, so the menus' tags keep their places; the stores list no conversation for it.
- **Dropped rather than added:** no per-sender image allowlist (images load per message, as `docs/ARCHITECTURE.md` says), and no avatar photos (they would need Contacts access); faces are initials only.
- No other data changes: unread, starred, pending operations, categories and counts already exist.

### 8.6 Source map: what each section replaces

| Spec | Current source | Change |
|---|---|---|
| §4.1–4.3 tokens | `List/NSColor+Hex.swift`, hex literals across views, `.systemYellow` star, `controlAccentColor` pip, `quaternaryLabelColor` badge, four avatar palettes (`List/AvatarCache.swift`, `Shell/AccountStripButton.swift`, shell `.ss-avatar`, compose tokens) | all colours from `QuireTokens.swift`; one avatar palette, one account palette |
| §4.4 typography | font sizes set per view (10–26 pt) | `QuireFont` roles; New York subjects and reading; the Font setting through `QuireEnvironment` (SF Pro twins app-wide, live) |
| §5.1 window | `Shell/MainWindowController.swift` | empty unified toolbar (`toolbarStyle = .unified`, `titlebarSeparatorStyle = .none`) so the lights sit at the 52 pt band's centre; rail width derived from the zoom button's frame (76 / 84); title-bar zone 52 |
| §5.2 rail | `Shell/AccountStripViewController.swift`, `Shell/AccountStripButton.swift` | opaque `spine`; folder tiles at the top with a raised selection, Later and the Outbox only while they hold something (`ConditionalFolders`, `folderShift`); the account group anchored above Add with its own scrolling clip; face + ring + domain monogram; margin-rule selection; accent badges with cut-out |
| §5.3–5.6 list header | `Shell/ListPaneViewController.swift` (search field, filter, title) | one 52 pt line: masthead (the title menu only in minimal mode), search with resting edge filling the free width, compose; no filter tabs |
| §5.7 row | `List/ConversationCellView.swift`, `List/ConversationRowView.swift`, `List/ConversationRowContent.swift`, `List/RowContentCache.swift`, `List/AvatarCache.swift` | row 68 (from 72), ring drawn in `draw(_:)` instead of the 10 pt dot, ring-less face cache, `ss.queued` instead of the 0.6 alpha fade, unread time, failed state, selection from window key state, hover paused while scrolling, cache key gains appearance + contrast |
| §5.10 list tail | `List/MessageListViewController.swift` (20 pt “Loading…” footer) | 28 pt footer row with delayed spinner, “Loading older mail…”, retry; a search's end row offering the server (`ServerSearchRowView`) |
| §5.8 running heads | `List/MessageListViewController.swift`, `List/MessageListTableView.swift` | non-sticky group rows; `j`/`k` skip them |
| §5.11 sync line | `Shell/SyncStatusBar.swift` (`SyncStatusSummary.make`: reauth, then network-only errors as offline, then the first error, then bootstrapping) | 28 pt, states and contrail; the ten-step precedence and the counted copy for several accounts |
| §5.12 reader header | `Conversation/ConversationHeaderView.swift` (44 pt) | 92 pt native header with kicker, headline and both action groups |
| §5.13–5.17, §5.19 reader | `SSCore/ConversationSupport/ConversationShellAssets.swift` (CSS + `ss.render`), `Conversation/ConversationViewController.swift`, `Conversation/WebViewPool.swift` | stack + sheet, elision toggle, neutral images banner, chips, multi-select state, SF Symbol masks, `ss-ic`/`ss-rm`/`ss-rt` classes |
| §5.14 invitation card | `SSCore/ConversationSupport/InvitationCardText.swift`, `ConversationShellAssets.swift` (`fillInvitation`, and `fillMessageFold` for the message folded under it), `Conversation/ConversationViewController.swift`, `Conversation/InvitationFiles.swift` | the card's words and states from the stored invitation, the answers through `MailClient.answerInvitation`, Open in Calendar, the permission notice |
| §5.18 quick reply | `Conversation/QuickReplyView.swift`, `Conversation/ConversationViewController.swift` (`showStrip`) | field on the column overlaying the web view (bottom inset), tool row with mode tabs, the countdown strip with contrail and the outcome copy, visibility per reader state |
| §5.19 drafts | `Conversation/ConversationViewController.swift` | read-only draft sheet, Continue Editing / Discard Draft |
| §5.48 print | none (⌘P did nothing) | `SSCore/ConversationSupport/PrintDocumentBuilder.swift` (the printout from the render payload and `PrintSheetState`, the shell's card states), `PrintDocumentAssets.swift` (its page and body CSS, and the script that applies the reader's image policy per body), `Conversation/ConversationPrinter.swift` (an Aqua web view of its own, the print operation as a sheet), `Shell/MainMenu.swift` (File › Print… ⌘P) |
| §5.20–5.23 composer | `Compose/ComposeWindowController.swift`, `Compose/ComposeFieldRow.swift`, `Compose/AddressTokenField.swift`, `Compose/AttachmentStripView.swift`, `Compose/AttachmentChipView.swift`, `Compose/QuotedOriginalView.swift`, `Compose/ComposeTextView.swift`, `Compose/ComposeSignature.swift` | one text axis at x = 84, transparent title bar, tokens, autocomplete, strip, primary Send, status copy, format row, link popover (replaces the Add Link `NSAlert`), shared quote style 2 / 12 (from 3 / 16), Tab order, the signature's insertion and From rule |
| §5.30 toast | `Shell/ToastView.swift` (HUD material), `Shell/MainWindowController.swift` (“Undid …”) | opaque slip, coalescing, contrail, Esc, VoiceOver announcement, the no-action confirmation variant |
| §5.31 undo send | `Compose/UndoSendPanel.swift` | slip panel with contrail, numeric countdown, outlined Undo action, shadow margin |
| §5.20 closing and checks | `Compose/ComposeWindowController.swift` (`windowShouldClose` “Discard this message?”, “Send without a subject?”, “Some items couldn't be attached”) | close keeps the draft without an alert; Discard Draft… in the Message menu; the subject alert's new copy; rejected drops as a composer status |
| §5.32 HUD, cheat sheet | `Shell/KeyboardRouter.swift` (`sequenceTimeout` 1.5 s), `Shell/MainMenu.swift`, `Shell/AppDelegate.swift` (`showKeyboardHelp`, an `NSAlert` listing keys) | g-sequence HUD with a 2000 ms window, `finishAll()`, the ? / ⌘/ overlay with the full content table in place of the alert |
| §5.33 alerts, §5.44 reconnect | `Shell/AppDelegate.swift` (`showError` with “OK”, `showNotice`, the launch alert, `addAccount(_:reconnecting:)`) | the inventory's copy and verbs; the OAuth read failure becomes a Settings banner; reconnect states in the rail, the sync line and Settings; the wrong-account alert |
| §6 Space | `Conversation/ConversationViewController.swift` (`handleSpace`, `openQuickLookForSelectedMessage`) | kept, acting on the target message (it uses `selectedMessageID ?? last`, the same rule) |
| §5.35 menus | `Shell/MainMenu.swift` | symbols, shortcut text, G-sequences |
| §5.39 welcome | `Shell/WelcomeViewController.swift`, `Shell/AppDelegate.swift` (“Adding demo account…”) | layout, copy and states; “Try the demo” kept, with the Preparing the demo and Demo failed states |
| §5.40 settings | `Shell/SettingsWindowController.swift` (`statusText(for:)`, the OAuth `Form`), `Shell/AppSettings.swift`, `Shell/Settings/SignatureEditorView.swift`, `Shell/Settings/GeneralSettingsView.swift`, `Shell/Settings/MailboxSizeModel.swift`, `Shell/Settings/LaunchAtLoginModel.swift`, `Shell/Settings/LoginItemHandling.swift`, `Shell/Settings/NotificationPermissionModel.swift`, `Shell/Settings/NotificationPermissionHandling.swift` | system tabs; account statuses for every sync phase; the OAuth form row by row with “Saved” beside Save; Quire control styles and drawn focus rings; account group with margin-rule selection, +/−, empty and busy states; notices as banners; colour, monogram and signature, font, density, account initials, Keep mail on this Mac and the mailbox's size, At login, Notifications' line |
| §5.43 demo | `Shell/MainWindowController.swift` (window title), `Shell/ListPaneViewController.swift`, `Shell/SettingsWindowController.swift` (demo note), `Shell/AppEnvironment.swift` | Demo tag and menu, sync-line state, Settings banner, Leave Demo |
| §5.44 add account | `Shell/AppDelegate.swift` (provider `NSAlert`, “Finish signing in…”), `Shell/AccountStripViewController.swift` | provider pull-down menu, pending tile, sync-line waiting state with Cancel, error alerts |
| §5.41 notifications | `Shell/NewMailNotifier.swift`, `Shell/NewMailNotificationAction.swift`, `Shell/NewMailNotificationResponder.swift`, `Shell/MainWindowController.swift` (`answer`) | content rules; the category and its three actions; a response held until there is a main window; actions with no toast and no undo; the permission asked for while macOS has no answer |
| §4.16 themes, §5.40 Appearance | none (one palette; Font and Text size in General) | `docs/design/source/themes_*.py`, `theme_rules.py`; generated `QuireTokensThemes.swift` and per-theme providers; `QuireEnvironment.theme` and the redraw sweep; `SwiftUI/QuireThemeEnvironment.swift`, `QuireThemeRoot.swift`, `QuireColorStyle.swift`, `QuireThemePicker.swift`, `QuireThemeTile.swift`; `Shell/AppSettings.swift`, `Shell/AppAppearance.swift`, `Shell/Settings/AppearanceSettingsView.swift`; the reader's `ss-theme` sheet, link classes and page wrapper (`ConversationShellAssets.swift`, `ShellTheme.swift`, `Conversation/WebViewPool.swift`) |
| §4.11 reader symbols | `Conversation/PooledConversationView.swift`, `Conversation/WebViewPool.swift` | rasterise symbols once per pool, inject `symbolCSS` |
| §5.54 day and week | none (1.9 is new) | the reader's split item holds the reader and the day column (the split keeps its three items); the week shown in their place by hiding the reader, never removing it (its web views are pooled); `layout.calendarPane`, `eventFace` pairs; the Day button in the main window's reader header and the week button in the day column's; D, W, [, ], T and B in `KeyboardRouter`, the View and Message menus and the cheat sheet; the overlap line on the invitation card (`ConversationShellAssets.swift`) |

### 8.7 Tests

Design tests live in `Tests/SSDesignTests`: the generated ones in `Tests/SSDesignTests/Generated/` (rewritten by the generator, never edited), the hand-written ones beside them, and the colour math they share, a port of `docs/design/source/colorlib.py`, in `Tests/SSDesignTests/Support/`. Tests of the reader shell live in `Tests/SSCoreTests/Conversation/`, and tests of the app's own windows in `Tests/SuperSparrowAppTests/`.

- **`DesignContrastTests`** (generated from `contrastPairs` and `graphiteContrastPairs`): resolves each pair in four modes with the same compositing and asserts ≥ `need`, or ≥ `needIC` in the IC modes when the pair has one.
- **`AccountPaletteTests`** (generated from `accountRules`): Machado simulation + CIEDE2000; asserts the six-account floor, the ten-account normal floor and the distances from accent, danger, info and star.
- **`RowMetricsTests`**: lays out subjects in Latin, Cyrillic, Japanese, Arabic, Hebrew, Thai and Devanagari with the chosen role (New York or twin) and asserts the used line fragment height ≤ the role line height and that the coverage check picks the twin for the last five, at each of the four Text sizes. `TextSizeTests` hold the step (the floor, twins, monograms), the row tables of §4.15 and `textSize.rowHeights`, the skeleton, and the reader's CSS to the AppKit roles; `TextSizeSettingTests` switch the list, the reader and an open composer live.
- **`GlyphPathTests`**: parses the five custom glyph paths and checks their bounds stay inside the grid, and holds the brand mark to its construction: every vertex a whole unit, straight edges only, three triangles that never overlap, the trailing edge WF–T–S–WN one 1:2 line, the spine 1:2, the far leading edge 1:4, the near wing's leading edge and the keel's foot on one 45° line, the keel's top parallel to the trailing edge and its back vertical, the fold a wedge closed at the nose and open at the tail and the keel's gap open, and the box 80 × 60 centred on the grid; the app icon placing one unit on one 8 px unit with every vertex where the approved board draws it; and the 16 and 32 px masters as straight-edged polygons with every vertex on a pixel corner inside their snapped bodies. `WelcomeWordmarkTests` (SuperSparrowAppTests) holds the welcome screen to the drawn wordmark: under the mark, centred, its caps 24 pt on a whole-point baseline, no text field setting the name, and the screen's VoiceOver description, and holds the mark and the wordmark to the brand's black and white (every pixel they cover fully is `layout.brand.ink` or `paper`) in every theme and mode, under Increase Contrast and Graphite; with `SS_UI_TESTS=1` it renders the screen in Light and Dark. `ComponentColorTests` holds inbox zero's mark to the system's secondary label grey over the paper.
- **`WindowChromeTests`**: builds the main window off screen with the §3.2 configuration (empty unified toolbar) and asserts that the close button's centre is 26 ± 0.5 pt from the top, that the derived rail width is ≥ the zoom button's `maxX` + 4, and that a composer window configured by `QuireWindowChrome` measures the system title bar. `ComposerChromeTests` (SuperSparrowAppTests) builds the real composer, with and without the From row, and asserts its first field row starts at that measured height. A failure means a macOS release moved the lights or the band: re-derive the title-bar metrics (§3.2) rather than nudging numbers.
- **`ReaderSymbolTests`**: the shell's CSS references only `--sym-*` names in `readerSymbols`, and every name rasterises (`NSImage(systemSymbolName:)` is non-nil).
- **The invitation card**: `InvitationCardPayloadTests` (its words and states, an earlier revision offering no answer, and that the shell reads every key), the gated `ConversationShellWebViewTests` cases (its place at the indent above the body, small buttons, a click marking the answer and posting it, the permission notice, the cancelled title struck through; the message's mark 16 below the card and the body 12 below the mark once unfolded, every card state folding its message and a message without a card not, the unfold animating straight to the sheet's height and instant under Reduce Motion, Original colors switched under the fold with its notice in view) and `ReaderInvitationTests` (the real reader: an answer reaching the store and the provider, a refused answer taken off the card, the card asking to reconnect and stopping once granted, Open in Calendar's file, a cancellation; the message folded at open in every state, its mark's words, tooltip and pressed state, the attachments staying, the mark and “.” unfolding and folding it, a Space or ↩ on the focused mark (and on the quoted-text toggle under it) let through by the router's Open and by Quick Look of an invite.ics chip and pressing it in the page, “.” moving the focus it hides to the mark, its own quoted text folded under its own toggle, Load images under the fold with its banner and progress in view, and the fold kept and forgotten exactly as the quoted-text toggle's is; `ReaderShortcutsTests`, Space on a focused mark left to the web view). The gated `ReaderInvitationRenderTests` renders the demo's invitations folded and unfolded, light and dark, for looking at.
- **Print** (§5.48): `PrintDocumentBuilderTests` (the payload to the print document: every message open in order, the header written out, the date in full, the notes for what the reader folds or holds back, the card without buttons, bodies in inert templates with their image and quote state, the reader's blocking policy and elision glyph kept equal to the shell's, the page's own script policy and nonce, escaping, and the shell's card states read into `PrintSheetState`) and `PrintConversationTests` (the real reader printing to a PDF file through the real print operation: the text of every message on the pages, a long body over several pages, held-back images never fetched while loaded ones are, a held-back body's inline image waited for in its own step, a positioned block kept in its own sheet, no script of a body's run, folded quotes left out and unfolded ones printed, light in a dark app and `color-scheme: light` over the Quire head, the stylesheet's metrics held to `layout.print` and the reader's, ⌘P's validation and the File menu item); `PrintRenderTests` (gated, `SS_UI_TESTS=1`) writes the demo's printouts as PDFs to `SS_RENDER_DIR` for looking at.
- **Find in conversation** (§5.50): `FindBarTests` (the bar's metrics, colours in four modes, its keys, buttons and VoiceOver), `ConversationFindTests` (the count's words, the shell's reports read totally, the calls, the marks' styles in every body document), the gated `ConversationShellFindTests` (what counts and what does not, marks across elements and their removal, stepping and wrapping, what a step opens, a store refresh, a find loading nothing, the keystroke's time over 30 messages) and `FindInConversationTests` in the real main window (the menu, typing, ↩ and ⇧↩, ⌘G, Esc from the field and from the page, another conversation, a store change, ⌘F still search, the bar's place).
- **Themes** (§4.16): `DesignContrastTests` and `AccountPaletteTests` loop the five themes (every pair and Graphite pair in four modes, the account rules with Gallery's inkless reading), and the generated `ThemeRuleTests` asserts R0–R11 for each and that the sheet is the page exactly in the light modes. `ThemeTests` (every theme's tokens in four modes and under Graphite, Study equal to `color`, one post per change, the cache keys, the link flags, colours made only for a theme drawn, the sweep, SwiftUI keeping focus and identity, and source rules for `Color.q…` in SwiftUI, link underlines and layer colours), `ThemePickerTests` (the tile states, geometry and VoiceOver), `QuireCSSTests` and `ConversationShellThemeTests` (the theme sheets block by block, a switch without a reload, a frame loading during a switch, the link classes, an uncoloured newsletter link, the permanent page, the Dark Mode default through two ⇧⌘O and a change of default), and in the app `ThemePreferencesTests`, `AppearanceSettingsTests` (the tab, General's nine controls, the arrows through five themes with focus kept), `ReaderThemeTests` and `ThemeSettingTests` (a switch restyles the list, an open conversation, a composer, a reader window and Settings with no relaunch, moving no row, selection or scroll offset; the colour under the pages; `NSApp.appearance`; a reader window opened in a theme paints its first frame in it). `ThemePerformanceTests` (`SS_PERF=1`) holds the budgets, and the gated `ThemeRenderTests` (`SS_UI_TESTS=1`) renders the main window, a reader window and Settings › Appearance in every theme, Light and Dark, for looking at.
- **Swipe** (§5.7): `RowSwipeGestureTests` (the gesture's state machine fed scroll phases and deltas: the content under the fingers, snapping open, snapping back, moving back closing, past the whole button staying open, the full swipe making the change, a cancelled gesture never making it, the rubber band, an edge that offers nothing, up and down, a mouse's wheel and sideways over heads scrolling, a swipe's momentum swallowed, a gesture that begins still, one row at a time and the close rules), `QuireSwipeButtonTests` (the button rendered in every theme, mode and under Graphite: its fill to its corners, a white icon and a white label, nothing on it darker than the fill; the label only whole and the icon alone before it; the open width and the stack in every row height at every Text size; VoiceOver's press and the pointing hand; a theme change redrawing a button already out), `SwipeActionColorTests` (each fill and the white on it per theme, mode and Graphite against `tokens.json`, white at 4.5:1 on each, Archive the theme's fill or, under Graphite and in Gallery, the neutral that is the slip by day, the two fills apart, Archive louder than Read beside every row, the fills the live tokens), `SwipeToArchiveTests` (through the list's own swipe in the main window: a full swipe and a click on the open button archive as E does, with E's toast, coalescing, Undo and selection; the read change as U's; Later; no trailing button in the Trash and nothing on heads and the tail; a refresh closing the button; every close rule; Reduce Motion; the content sliding with no frame moving; the list still scrolling; a trackpad's sideways scroll through the table; VoiceOver), and the gated `SwipeButtonRenderTests`, which swipes a row of the main window open in every theme, mode and under Graphite, and a list's row at Small, Default and Larger in both densities, holds every render's pixels to the same rules and writes `swipe-buttons.png` and `swipe-buttons-sizes.png` to `SS_RENDER_DIR`. `QuireMotionTests` hold the curves stepped frame by frame and `QuireFrameAnimation`.
- **`RadiusScaleTests`** (generated): every `radius` metric in `layout` is on the scale or a listed exception (§4.6). The exception list mirrors `RADIUS_EXCEPTIONS` in `docs/design/source/tokens_def.py`; `tokens.json` does not carry it, so `scripts/tools/quire-tokens.swift` holds it, each exception pinned to its value.
- **Pointer** (§4.17): `PointerTests` (a control's hand over its hit rect, cursor rects AppKit is asked for again when it is disabled, hidden or loading, the arrow on a chosen radio or tab, the I-beam over a field's face with its button cut out, surfaces that lie on something clickable, the overlay for AppKit's own controls), `PointerStyleTests` (every Quire SwiftUI style and control carries the pointer, the inline link's box runs the link and the words around it do not), `ConversationShellPointerTests` (the shell's rules, the body documents' three and the sanitizer dropping a sender's `cursor`, headless, and in WebKit, gated, the computed cursor of every button and button-role element a conversation makes, of what is inside them, of a disabled Download, of links in plain and styled bodies, and of a sender's cursors in stored mail), `PointerCoverTests` (what lies under a cover, a divider or a showing overlay scroller leaves it out, once a turn and only when a cover's frame changes, and a text view's I-beam is its own bounds), `ConversationNavigationPolicyTests` and `ReaderAnchorTests` (gated: where a click on a body's link goes), and in the app, read from the cursor rects AppKit gets, `ComposerPointerTests`, `ReaderPointerTests`, `MainWindowPointerTests`, `ListPointerTests` and `SystemControlPointerTests`.
- **Copying an address** (§5.14): `HeaderAddressTests` (a position read back to the stored address, Bcc only on the user's own mail, the two forms, the announcement and the `from:` search) and the shell's privacy, headless; the gated `ConversationShellAddressTests` (the copy targets, what a click posts, the toggle and the fold, ← → and Esc, the mark and a recipient cut short, the focus report, the squeezed address, the gap beside Unsubscribe, the pointer and the hit rects, and real presses sent to the web view, which `element.click()` cannot stand in for since it moves no focus); and `AddressCopyTests` in the app (the pasteboard, the announcement, Edit › Copy, a refused write that beeps once, a message the page does not show, More › Copy Sender Address, the person menu, Show Mail from This Person, and no address in the log above debug).
- **Outbox** (§5.53): `OutboxTests` (each outbox status's state and words, the rows' order, the row and its cache key, the failed time in `danger`, the sheet's line, Cancel and footer, the reader's actions, the empty state, no drop), the stores' `MailStoreOutboxContractTests` (no conversation for the view, an observation that never wakes), the `Row time (Outbox, failed send)` contrast pairs, and the app's `OutboxViewTests` (View › Outbox and G O, a send followed until it is taken, the Outbox showing only while a send waits: no tile, title-menu item, View menu item, HUD row or G O with nothing waiting, all of them with a send, the window back in the Inbox as the last send goes, a search kept, narrowing to an account with none, Later's and the Outbox's tiles together, a send leaving as another arrives keeping the tile, a Cancel's undo bringing the Outbox back, reader windows going by the main window, a send waiting at launch shown once the accounts are read, the scope, every mail key spent with nothing changed, ↩ and a double-click, a held Send Later message, one waiting out a retry too, continued and cancelled as from Drafts, Drafts as before); a failed send leaving for Drafts in `FailedSendTests` (who keeps it, the id it is kept under, the toast's words) and the app's `FailedSendAppTests` (a composer's and a quick reply's failure kept once by their owner, a row a live panel answers for never kept twice, one nobody watches kept by the window, one interrupted at launch saying to check Sent, accounts not yet read, the demo, a window that is going); `OverlayAndPanelTests` holds the HUD's eighth row and its six-row height; `RailLayoutTests` the folders' places with neither, either or both conditional tiles.
- **Day and week** (§5.54): the generated `DesignContrastTests` assert every `eventFace` pair and the calendar's surfaces in five themes and four modes, `AccountPaletteTests` the account pairs on them, `MetricDriftTests` every `layout.calendarPane` leaf; `OverlayAndPanelTests` hold the cheat sheet's three new rows, its 736 pt height and its scrolling in the default window; `WindowChromeTests` the 1304 × 800 default.
- Existing signposts stay the gate: `j`/`k` ≤ 16 ms and list refresh ≤ 50 ms on the synthetic mailbox after the row changes, and a hover-while-scrolling run that asserts no avatar cache miss.

---

## 9. Scope decisions

**In v1:** everything above. New settings are limited to Theme, Appearance, Dark Mode (Adapt mail that sets its own colours), Font, Text size, List density, Show account initials, and per-account colour, monogram and signature (plus the one Original colors notice preference).

**Not in v1, deliberately:**

- **Row animations** of any kind: no slide-out on archive, no gap closing, no star pop, no dot shrink.
- **Sticky date headers** and date headers in search results.
- **App-drawn vibrancy.** The rail and every pane are opaque.
- **Custom themes, a colour picker and following an arbitrary system accent** in custom-drawn surfaces (the five checked themes are the set; only Graphite is honoured, §3.1).
- **Hover action buttons on rows**; the keyboard and the context menu cover them.
- **Avatar photos**, local or remote. Faces are initials only (no Contacts access).
- **A per-sender image allowlist.** Remote images load per message.
- **A contact popover.** Hovering an avatar shows the address tooltip; nothing more.
- **A Spam view.** Mark as Spam (§5.47) hands mail to the provider's spam folder, which stays the place to rescue it from.
- **A calendar app.** The day column and the week show each account's main calendar beside the mail and write only answers and time set aside for a mail (§5.54). No month or year view, no other calendars of an account yet, no editing of other people's events, repeat rules, reminders or notifications, no one else's free time, no scheduling pages and no calendar colours of their own: each event takes its account's ink, and the provider's calendar is a click away.
- **Delete Forever and Empty Trash.** Trash is emptied by the provider on its own schedule; in Trash the header offers Move to Inbox and no Trash action (§5.12).
- The sixth custom-glyph slot stays free.
