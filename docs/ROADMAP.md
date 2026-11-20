# SuperSparrow roadmap: November 2026 to October 2027

**Revision: 7 November 2026.** One year of features for the Mac client, chosen and ordered so that the four things SuperSparrow is for stay true: it is usable, light, simple and fast. Every entry says what it costs on those four and how it stays inside. Dates are targets; each quarter is re-planned at its end from what shipped and what the measurements say.

**Status, 19 November 2026.** Built ahead of their quarters, and described in `docs/ARCHITECTURE.md` and Quire 1.7.0 rather than here: from Q2, Send later (Q2.2), Mark as spam (Q2.3), Text size (Q2.6), Launch at login (Q2.7) and Services (Q2.8); from Q3, inline images in the composer (Q3.3), Print and PDF (Q3.4), a conversation in its own window (Q3.5), find in conversation (Q3.6) and Mute (Q3.7); from Q4, sender rules (Q4.2) and the 300,000-message check (Q4.3, measured 20 November 2026; the architecture's budget table records it). The entries below keep their plan as written; where a built feature differs, the architecture and the spec say what it does (Send later's key, for one, is ⇧⌘L, since ⇧⌘↩ is Send and Archive). Built outside any quarter: **day and week** (Quire 1.9.0 §5.54, the architecture's "Calendar"), every account's main calendar as a day column beside the reader and a week in the reader's place, read from the store and fetched on the live lane's cycle; it writes only answers to invitations and time set aside for a mail (B), and the invitation card now says what an invitation overlaps. It is not the calendar app §6 leaves out.

`docs/ARCHITECTURE.md` says what v1 is; this document says what comes after it, and in what order. Where the two disagree, the architecture wins until the roadmap item that changes it has shipped and the architecture has been updated with it.

## 1. What this roadmap protects

Four guardrails. A feature that cannot pass all four is not on the roadmap, however popular.

**Usable.** Keyboard first: every action has a key, a menu item and a row in the cheat sheet (generated from `docs/design/tokens.json`). Every mail action is undoable with Z or ⌘Z and gets a toast when a row leaves the view. Every state has a shape or a word as well as a colour, every control a VoiceOver label, every contrast pair a generated test in four modes (Quire §4.14, §7). The copy follows §4.13: short, calm, a verb on every button. A feature that needs a tooltip to be understood goes back to design.

**Light.** Two dependencies (GRDB, SwiftSoup) and no third without the decision in §7. No helper processes, no launch agents, no menu-bar extra, no web runtime (Help me write's run of the user's own Claude Code or Codex lives only for the request the user made, so it is not a helper). The release binary stays under 20 MB stripped; the app's idle footprint under 120 MB on a 100,000-message mailbox, and under 200 MB with its three warm web views; idle CPU under 1 %, with the poll timers (5 s active, 30 s in the background), the backfill's five-minute wake, the send queue's tick (made to wait for its next due send, Q1) and the calendar's minute tick (only while a day column or a week is on screen in a window that is not covered) the only periodic work. The calendar's read adds no timer: it rides the live lane's cycle, at most once every two minutes while the app is active and once every ten minutes in the background. Disk is bounded by the retention setting of Q1. Mail goes to Google, Microsoft and this Mac, and nowhere else, with one exception the user turns on: Help me write sends the conversation being replied to to the AI provider they chose, only when they press Write and after a consent sheet (§6). The update check of Q1 is the one other request the app makes, and it can be turned off.

**Simple.** Six views, one list, one reader, one composer. No folders, no labels, no tabs, no categories, no modes, no plugins. One way to do each thing, and a feature ships complete or not at all (no flags, no beta switches in a release). New settings are rationed: this year adds at most four to General (updates, retention, text size, launch at login), three in one Appearance tab (theme, appearance, the Dark Mode default for mail colours), two per-account fields to Accounts (signature, send-as addresses), and one AI tab for Help me write (provider, its API key or CLI, its model, and the stored permission it can forget; §7, 20 November 2026), and no Settings tab ever scrolls. A feature exists on both providers, or says plainly where it does not.

**Fast.** The budgets in `docs/ARCHITECTURE.md` are unchanged and every new interaction gets a row there before it is built and a measurement before it ships. Nothing waits on the network between a keystroke and a pixel: every action is a store transaction first and an `Operation` second, as today. The `SS_PERF=1` run goes before every release; a regression blocks it.

### How a feature ships

1. A section in `docs/DESIGN-LANGUAGE.md` (tokens first, generated files after, a Quire version bump), with its states table and contrast pairs where it draws anything.
2. Local first: the store transaction, then the operation the engine replays. A schema change is a new migration and a `docs/DATA-MODEL.md` entry; a migration is never edited once released.
3. A key, a menu item, a cheat-sheet row, VoiceOver, a toast and Undo where a row leaves the view.
4. Tests at the layer it lives in (store, engine, provider fixtures, design, the app harness), a demo-mode sample so the snapshots show it, and its budget row measured.
5. `docs/ARCHITECTURE.md` updated in the same change.

## 2. Where we start

As of 7 November 2026 the client does what `docs/ARCHITECTURE.md` lists for v1, with the two-lane sync engine and Quire 1.4 (folders in the rail, accounts at its foot, one header line, no filter tabs). In short:

- Gmail and Microsoft 365 / Outlook.com over OAuth clients the user registers; a unified inbox; Inbox, Starred, Sent, Drafts, Trash and All Mail; one account or all.
- A live lane that polls every 5 s (30 s in the background) and a backfill lane behind it paced by the provider's quota, so new mail never waits for old mail; every action applied locally first and replayed from an outbox; undo for all of them.
- A reader of stacked sheets with folded quotes, blocked remote images, dark-mode adaptation, inline images, Quick Look and quarantined attachments; a quick reply with undo send.
- A composer with the plain formatting set, attachments, To/Cc/Bcc tokens with local autocomplete, drafts kept on this Mac, undo send of 5, 10 or 20 s, and sending queued while offline.
- Full-text search over subject, participants and body, as you type, local only.
- Notifications per conversation, a Dock badge, a sync line, a welcome screen, a demo mode, a Settings window of three tabs, and a complete keyboard map with a cheat sheet.
- The Quire design language, generated from one token file into AppKit, SwiftUI and the reader's CSS, with every contrast pair asserted.

What it does not do is the subject of §4. The deliberate omissions of Quire §9 (notification actions, text size, signatures, hover buttons, avatar photos, Delete Forever) and the architecture's v1 list (rules, snooze, send later, calendar invites, S/MIME, server drafts, IMAP, more windows) are where this roadmap draws from.

### Baseline, measured 7 November 2026

| Measure | Today | Limit through October 2027 |
|---|---|---|
| Dependencies | 2 (GRDB 7.11, SwiftSoup 2.14) | 2, or 3 by the updater decision in §7 |
| Release binary | 13.3 MB after `strip -x` (11.8 MB after a full `strip`; 22.7 MB as `swift build -c release` leaves it); 2 MB of resources | 20 MB after `strip -x`, which the release script runs |
| Idle footprint, one Gmail account of 41,139 messages, 92 minutes up | 73 MB for the app process; three WebContent processes of 16 to 22 MB | 120 MB app, 200 MB with the three web views, on 100,000 messages; 25 MB more per reader window (Q3) |
| Idle CPU | 0.4 % | 1 %; Energy Impact "Low" |
| Store | 292 MB for 41,139 messages, 14,281 bodies and 32,789 conversations: 1.5 KB per message for its metadata and summary rows, 15.6 KB per stored body with its full-text rows | the retention setting bounds the total; 2 KB per message without its body, 18 KB with |
| Attachment cache | 23 MB | 1 GB, oldest first |
| Source | 60,127 lines of Swift in five modules; 30,027 lines of tests; 1,434 tests in the last full run | no limit, but a feature's tests land with it |
| New mail visible | 5 s active, 30 s in the background | unchanged; under 1 s on JMAP push (Q4) |
| Launch to usable inbox, move selection, open conversation, search keystroke, list refresh | the budgets, 500 / 16 / 50 (100 with a cached body) / 50 / 50 ms, last checked by the `SS_PERF=1` run; not re-measured today | unchanged (`docs/ARCHITECTURE.md`), measured on every release |
| Settings controls in General | 7 | 12; 9 after Q3.9 moves Font and Text size |
| Settings controls in Appearance | — | 5 (three new, Font and Text size moved from General) |
| Views in the rail | 6 | 6, plus Later while something is snoozed (Q2) |

## 3. The year at a glance

| Quarter | Release | Theme | Headline |
|---|---|---|---|
| Q1 · November 2026 to January 2027 | 1.0 | It ships | Signed and notarized, Check for Updates, mailto and default mail app, notification actions, signatures, storage bounds, engine debt |
| Q2 · February to April 2027 | 1.1 | Triage | Snooze (Later), send later, mark as spam, unsubscribe, search operators, text size, launch at login, Services |
| Q3 · May to July 2027 | 1.2 | Reading and writing | Search the server for mail not on this Mac, calendar invitations, inline images in the composer, print, a conversation in its own window, find in conversation, mute, send-as aliases, themes |
| Q4 · August to October 2027 | 1.3 | Reach | JMAP (Fastmail) with push, sender rules, the 300,000-message check, macOS 26 as the floor, Shortcuts |

Each quarter keeps a fifth of its time for what use of the previous release turns up. Sizes: **S** a few days, **M** one to two weeks, **L** three to six weeks.

## 4. The quarters

### Q1 · November 2026 to January 2027 · 1.0, it ships

The client is feature-complete for v1 and nobody but its author can install it. This quarter makes it a product without adding a surface to it, and pays the engine's known debts.

**1. Signed, notarized, installable (S).** A Developer ID identity, the hardened runtime, notarization and a DMG, from `scripts/release.sh` built on `scripts/build-app.sh` (which already takes `CODESIGN_IDENTITY`). Version 1.0.0 and a `CHANGELOG.md`. A stable identity also ends the keychain prompt every rebuild causes today. *Costs:* nothing on the four. *Done when* a clean Mac installs from the DMG, Gatekeeper is silent and the keychain asks once.

**2. Check for Updates (S).** SuperSparrow › Check for Updates… and one check a day against a small JSON manifest on the release host. A newer version shows as a one-line banner, "1.0.1 is available · Download", which opens the DMG in the browser. No in-app installer, no framework, no background helper. *Costs:* one request a day; one setting ("Check for updates automatically", on). *Stays inside* by being a check, not an updater; §7 holds the Sparkle decision if installing by hand turns out to be the thing users complain about. The check is the one request that goes somewhere other than Google, Microsoft and this Mac (it carries the version, and the Mac's address as every request does), so the README's privacy section and the welcome copy name it and its off switch.

**3. mailto and the default mail app (S).** `CFBundleURLTypes` for `mailto`, RFC 6068 parsing (to, cc, bcc, subject, body) into a new composer, and Settings › General › "Set as default mail app". *Costs:* one button. *Done when* a mail link in Safari and a right-click in Contacts open a SuperSparrow composer.

**4. Notification actions (S).** Archive and Mark as Read on the notification, and Reply, which opens the composer. Each is the existing operation, enqueued the usual way, so it syncs; taken from the notification it has no toast and no undo (the history lives in the window), and the spec says so. Quire §9 excluded these from v1; they are the single highest return on zero screen space. *Costs:* nothing visible in the app. *Spec:* §5.41 gains the two actions and their copy.

**5. Signatures (M).** One per account, set in the account's detail form in Settings › Accounts, in the composer's own formatting (bold, italic, underline, links). Inserted on new messages, replies and forwards above the folded quote; replaced when From changes; empty by default, and nothing is added that the user did not type (no separator line). A local setting: it needs no new OAuth scope and never reads the provider's signature. *Costs:* one setting per account; one rule in the composer. *Stays inside* because the signature is text in the body like any other text, selected and deleted the same way. *Spec:* §5.20 and §9.

**6. Storage bounds (M).** Settings › General › "Keep mail on this Mac: Everything · 1 year · 3 months", with the store's size beside it ("292 MB"). Outside the window a body's compressed source and rendered HTML are evicted and its plain text and full-text row stay (the whole index is 17 MiB for this mailbox), so the list and the search over subject, participants and body are unchanged; an `evicted` mark in the same migration keeps the hydrator from fetching them again (`messageIDsMissingBodies` has no date bound today, so without it every evicted body would come straight back), and a message opened without its body fetches it at once, as the reader already does for mail the backfill has not reached. The attachment cache is capped at 1 GB, oldest first. The store runs `PRAGMA optimize` at quit, an FTS optimize when a backfill ends, and incremental vacuum steps while idle (enabled once by the migration; never a full `VACUUM`, which needs twice the disk and holds the writer). The default is Everything: today's behaviour, with the number in view. *Costs:* one setting. *Why now:* at 15.6 KB a body, this mailbox will reach about 700 MB once its 41,000 bodies are in, and a 300,000-message mailbox about 5 GB. "Light" needs a bound before the first large mailbox, not after. *Spec:* §5.40.

**7. Engine debt (S each; the attachment bytes M).** Graph change tracking at any folder depth (the listing covers every folder, but changes in folders below the second level are not tracked until a reconcile). Attachment downloads charged to the quota budget and reporting bytes as they arrive (the sizes are known from `AttachmentInfo`; the bytes need a streaming download in both HTTP clients, which return the file in one response today), so the chip's progress becomes determinate. A throttle on the live lane pauses the backfill too. The send queue's one-second tick waits for its next due send instead, so an idle app has no timer faster than the poll. A search signpost, which `CLAUDE.md` asks for and the code lacks (conversation open has its three). Rail tiles accept dragged rows (the rows already drag, and only the composer accepts a drop): Inbox moves to the inbox, Trash trashes, Starred stars, All Mail archives. The account scope remembered across launches. *Costs:* none; these finish what exists.

**8. Free from the system, verified (S).** The composer's text view already carries Writing Tools, text replacements, dictation and spell check, and the reader has Quick Look and the Services menu. Check each on macOS 15 and 26, and say so in the README, so nobody builds what the Mac provides.

*1.0 ships at the end of January 2027 when:* a notarized build installs from the DMG; the whole suite and the `SS_PERF=1` run pass; the baseline table above is measured again on the release and recorded here.

### Q2 · February to April 2027 · 1.1, triage

The actions people reach for a hundred times a day in Superhuman and Gmail, done the local-first way and without a new surface, except one tile that shows only while it has something in it.

**1. Snooze: Later (M).** `L` on a conversation offers Later today, This evening, Tomorrow, Next week and Pick a date…; the conversation is archived now and moved back to the Inbox at the time, its latest message marked unread, where it sorts by the time it came back (a `returned_at` the Inbox query orders by, so last week's mail does not return under last week's date head) with a "Back" tag on the row. A new message in the conversation before the time ends the snooze, since the provider puts it back in the inbox anyway; a time missed while the app was closed returns at the next launch. Both halves are the ordinary archive and move-to-inbox operations, so the phone and the web see the same state; only the timer lives on this Mac (a `snoozes` table and its observation, schema v9), and a snooze due while the Mac slept returns at wake. Neither Gmail's nor Outlook's own snooze is reachable through their APIs, which is why the round-trippable form is the design. A **Later** tile (G L) appears in the rail only while something is snoozed, as Apple Mail's Send Later mailbox does, and its rows carry "Back Tue 09:00". *Costs:* one key, one conditional tile, five presets, no setting. *Budget:* 16 ms like every local action. *Spec:* §5.2, §5.7, §6.

**2. Send later (S to M).** ⇧⌘↩ in the composer, or the Send button's menu: Tomorrow 9:00, Monday 9:00, Pick a time…. The message waits in `pending_sends` with that `send_after`, which `SendRunner` already honours, and shows in Drafts as "Sends Mon 09:00 · Cancel" (an observation on `pending_sends` and a row kind beside the local drafts); opening it cancels the schedule. It sends while SuperSparrow is running, and the row says so; a time missed while the app was closed is a `scheduled` status the runner does not claim at launch until the app has asked. *Costs:* one key, one popover. *Stays inside* by reusing the undo-send pipeline instead of adding a second one.

**3. Mark as spam (S).** `!` (⇧1, routed like `#`), the context menu and the Message menu. Gmail adds the SPAM label through `batchModify`; Graph moves to Junk Email. Toast "Marked as spam · Undo", and the inverse operation for the undo. No Spam view: the provider's own spam folder stays the place to rescue mail, as it is today. *Costs:* one key. *Model:* two new `MetadataChange` cases.

**4. Unsubscribe (M).** `List-Unsubscribe` and `List-Unsubscribe-Post` are captured at sync time (two more names in Gmail's `metadataHeaders`; on Graph from the body fetch, whose `$select` already carries `internetMessageHeaders`, since list and delta calls cannot; schema v9). A message that carries them shows "Unsubscribe" beside the sender in its sheet header (⇧⌘U). One click: an RFC 8058 one-click POST, else a mailto request sent silently from the account, else the https page in the browser; then "Unsubscribe request sent" and the conversation is archived (Undo brings the row back; the request itself cannot be unsent, and the toast says so). *Costs:* one link in the header. *Why:* the simple answer to newsletters, before rules.

**5. Search operators (M).** `from:`, `to:`, `subject:`, `has:attachment`, `is:unread`, `is:starred`, `before:` and `after:` dates, `in:sent`, `in:trash`, quoted phrases and a leading minus, parsed in `ShellQuery` into predicates on the columns plus the FTS match; `from:` and `to:` match new `sender` and `recipients` full-text columns (schema v9), because the index merges every participant today and the address JSON has no index that holds 50 ms. No UI beyond the field; one cheat-sheet line. *Budget:* the 50 ms keystroke, measured on the 100,000-message fixture with every operator.

**6. Text size (M).** The rule Quire §9 already wrote down: −1 / 0 / +1 / +2 pt on every role, rows 64 / 68 / 72 / 76 pt (compact rows by the same amounts), the reader's CSS by the same delta. A popup in Settings › General, and ⌘+ / ⌘− for the reader alone. *Costs:* one setting; every metric test re-run at four sizes. *Why:* the 11 to 14 pt text the design sets is small for some eyes, and macOS has no app text-size preference.

**7. Launch at login (S).** A General toggle through `SMAppService`, so notifications arrive from login. *Costs:* one setting.

**8. Services (S).** "New Message with Selection" and "Send with SuperSparrow" (files) in the Services menu, from `NSServices` in `Info.plist`, no extension bundle needed.

*1.1 ships at the end of April 2027.* General then holds eleven settings and the default-mail button, at the limit of twelve controls; the next setting has to replace one. Q3.9 moves Font and Text size to a new Appearance tab, which leaves General nine (ten with the update check).

### Q3 · May to July 2027 · 1.2, reading and writing

Depth in the two places people spend their time, and the one provider feature the engine already has but never uses.

**1. Search the server for mail not on this Mac (M).** When the local results end, the list ends with "Search Gmail for more" (⌘↩ in the field; ↩ already returns focus to the list). `MailProvider.search`, implemented on both providers and called by nothing today, runs then; its hits are upserted as metadata and their bodies fetched on open. Local results never wait for it. *Why:* during the first download of a large mailbox, and for bodies the retention setting evicted. *Budget:* the local keystroke is unchanged; the server call is a row at the end, never a spinner over the list.

**2. Calendar invitations (L).** A message that carries `text/calendar` opens with a card: title, when, where, organizer, attendees, and Accept · Tentative · Decline. Gmail answers the organizer with an iMIP reply by mail (`METHOD:REPLY`) and marks the user's own Google Calendar copy through the Calendar API's event patch, behind the `calendar.events` scope, because the mail alone leaves that copy at "needs action" on the phone; Microsoft answers through Graph's accept, tentatively-accept and decline calls on the event message's event, behind `Calendars.ReadWrite`. Each scope is asked for at the first answer (a reconnect). "Open in Calendar" hands the `.ics` to the Mac's Calendar, so there is no EventKit permission. The iCalendar reader is ours, small, and reads dates, time zones and a repeat rule as words; it never expands recurrences. *Costs:* one card type in the reader, one scope on each provider. *Stays inside* by answering and never becoming a calendar app: the day and week beside the mail (Quire §5.54) show the user's calendars, and write to them only answers and time set aside for a mail.

**3. Inline images in the composer (M).** Paste or drop an image into the body; it is sent as a `cid:` part through the paths forwards' inline parts already take (the MIME builder's `multipart/related` on Gmail, inline attachments with a content id on Graph). *Costs:* `importsGraphics` and the image pasteboard and drag types on (the text view takes strings only today and pastes as plain text), `allowsImageEditing` kept off, one more MIME shape.

**4. Print and PDF (M).** ⌘P prints the open conversation from its render payload (the sheets, not the screen), through the system print panel, which gives PDF for free.

**5. A conversation in its own window (M).** ⌘O, or ⌘-double-click, opens the conversation in a reader-only window, for reading beside a composer. The architecture's "no windows beyond compose" moves to "reader windows too". *Costs:* the reader must stand without the split; the one-centre-line chrome applies to the new window as it does to the composer; each window is one more WebContent process (about 25 MB, allowed for in the baseline table); the undo history and the toast move from the main window to the app, so an action taken in a reader window is undone where it was taken.

**6. Find in conversation (S to M).** ⌥⌘F highlights matches in the open conversation and steps through them. ⌘F keeps meaning search.

**7. Mute (S to M).** `M`. New messages in a muted conversation are archived as they arrive: the archive is applied inside the poll's upsert transaction, as "pending operations win" is, and its operation enqueued in the same transaction, so the row never flashes into the Inbox, no notification fires, and every device agrees once the operation lands. A `muted` column on the conversation carries the glyph; `M` again unmutes. *Why not Gmail's mute:* it is not in the API; this form round-trips.

**8. Send-as aliases (S to M).** Addresses the user adds to an account in its detail form ("Also send as"); the From popup lists them under the account, a reply defaults to the address the message came to, and the account's signature follows them. Gmail sends from any address verified in its own Send mail as settings and Outlook from any alias of the mailbox, so no scope is added; an address the provider refuses fails the send with its reason. *Costs:* one per-account field.

**9. Themes (M).** Five themes: Study, the default and today's look unchanged, and Gallery (no coloured ink), Rain, Grove and Dusk, derived from Study's table by one rule that keeps every luminance, so every contrast pair keeps its ratio, and checked pair by pair (Quire §4.16). A Settings › Appearance tab holds Theme (five tiles), Appearance (Automatic · Light · Dark) and Dark Mode (Adapt mail that sets its own colours); Font and Text size move there, and General drops to nine controls. *Costs:* three settings and one tab; up to 7.7 KB of reader CSS for a non-default theme, none for Study. *Budget:* a switch redraws the list within 50 ms and restyles every pooled reader shell within 100 ms, with nothing re-measured; nothing at idle. *Stays inside* because a theme is data: one field in the colour providers' snapshot, one SwiftUI environment value, and one replaced stylesheet in the reader. *Spec:* §4.16, §5.40.

**Stretch:** search hits highlighted in the row snippet and the reader; reply quoting only the selected text; "Remind me if no reply", the pair to Later: a sent conversation comes back at the time only if nobody answered (one flag on the `snoozes` row).

*1.2 ships at the end of July 2027.*

### Q4 · August to October 2027 · 1.3, reach

A third provider that proves the port, the smallest form of rules, and the housekeeping a year brings.

**1. JMAP: Fastmail (L).** An `SSJMAP` module over the same `MailProvider` port the two existing providers have proven: `Email/query` and `Email/changes` for sync, `EmailSubmission` for sending, and the EventSource push channel for new mail, so a JMAP account sees mail in under a second with no polling. JMAP returns parsed bodies, so no MIME parser is needed, which is why it comes before IMAP (§6). OAuth through the same loopback flow. *Costs:* a module of about the size of `SSGmail` (2,000 lines), a third case wherever `ProviderKind` is switched (the OAuth endpoints and the OAuth tab, the quota table, the Add Account menu, the account tags), a section in `docs/OAUTH-SETUP.md`, and one long-lived connection per JMAP account for push. *Stays inside* because the list, the reader, the composer and the store do not change: a third `kind` in `accounts`.

**2. Sender rules, the smallest kind (M).** Two rules from a message's context menu: "Always archive mail from this sender" and "Block sender" (to Trash on arrival). They are applied the way mute is (inside the poll's upsert, the operation enqueued in the same transaction), so they round-trip and never flash; they are listed in one sheet from the account's detail form in Settings › Accounts ("Senders…") with a − button, and nowhere else, since General is at its limit after Q2. The architecture's "no rules" becomes "no rules beyond these two". *Why last:* rules are where mail clients get complicated. This is the last item added to the year and the first cut if the quarter is short.

**3. The 300,000-message check (M).** The synthetic mailbox grows to 300,000 messages and a Graph mailbox of 200 folders; every budget row is measured there, with retention at Everything and at 1 year. What fails is fixed before anything else ships. *Measured 20 November 2026, ahead of its quarter:* every row of the budget table on 300,000 messages, Keep mail at Everything and at 1 year, and a Graph mailbox of 200 folders (`docs/ARCHITECTURE.md`, "Performance budgets"). Search failed: a word in most messages took 90 ms, `to:owner` 123 ms and the negated words up to 94 ms, because every search read every message's key and sorted every matching conversation. It now reaches its conversations by its hits or by its page (schema v21), 1 to 47 ms. Two other costs that grew with the mailbox were fixed with it: a Graph folder gone held the writer for a scan of the account's mail (63 ms), and the badge's unread count looked up every Inbox row (36 ms, off the main thread). Left for a decision: a key pressed during a first sweep to 1 year can wait up to 27 ms for the sweep's batch, when that batch is the commit in which SQLite checkpoints its WAL. Noted, under no budget: a new account of 200 folders takes about 16 minutes before every folder has finished its first delta round, one folder a poll, so that new mail never waits behind them; the Inbox, Sent and Drafts are polled from the start, and the first download lists the mail of every folder.

**4. macOS 26 as the floor (S to M).** macOS 27 is expected in September 2027; the minimum rises to 26 (N − 1) in `Package.swift`, `Resources/Info.plist`, `scripts/build-app.sh` and the README, and the macOS 15 rows of Quire §3.2's chrome table go. The compatibility appearance is tied to the SDK the build links against, not to the minimum, so whether its code paths go too is the first week's question.

**5. Shortcuts (M, investigate first).** New Message, Search Mail and Unread Count as App Intents, if their metadata step can run from `scripts/build-app.sh` without an Xcode project; if not, the same three through an AppleScript dictionary, or nothing. The investigation is the first week; the answer decides.

*1.3 ships at the end of October 2027, and this document is rewritten for the year after.*

## 5. The quarterly check

At the end of every quarter, on the release build:

- the baseline table in §2 is measured again and its "Today" column updated;
- the `SS_PERF=1` run on 100,000 messages (300,000 from Q4) is recorded against the budgets in `docs/ARCHITECTURE.md`;
- the counts of settings, views, keys and dependencies are compared with their limits;
- VoiceOver is walked through every new surface, and the four-mode snapshots are looked at, not only generated.

A limit crossed is a roadmap item for the next quarter, ahead of any feature.

## 6. Not on this roadmap, deliberately

- **Cloud AI beyond Help me write** (summaries, suggested replies, "ask your inbox", agents). Help me write shipped in its narrow form (Quire 1.11, `docs/ARCHITECTURE.md` "AI"): off by default; it runs only when the user asks it to draft the reply they are writing, with the provider they choose (Anthropic or OpenAI, by API key or through their own Claude Code or Codex sign-in), after a consent sheet the first time; nothing is computed ahead and nothing else is sent. Anything wider would send mail the user did not ask to send. The Mac's own Writing Tools still sit beside it in the composer. On-device features are not revisited before 2028, and then only opt-in and off by default.
- **Folders, labels, tabs, categories, split inboxes.** The architecture's rule, and the filter tabs were removed in Quire 1.4 for the same reason.
- **Open tracking of sent mail and read receipts.** The client blocks trackers; it will not plant them.
- **Custom themes and arbitrary accents.** Five built-in themes (Quire §4.16) are the whole set. Each is derived from the default by one rule and checked pair by pair in four modes and under Graphite; a colour a user picks cannot be. No colour picker, no theme editor or import, no per-account themes, no accent beyond the theme's ink. Graphite and Increase Contrast are honoured in every theme.
- **Plugins or extensions.**
- **A command palette (⌘K).** The menu bar, the cheat sheet and the single keys already reach every command; a palette would be a second way to each of them.
- **Analytics, crash reporting, telemetry.** The welcome screen says "No analytics, ever." A "Report a Problem…" item that opens the issue page with the version filled in is enough, and sends nothing on its own.
- **A calendar, contacts or tasks app inside the client; team features; chat.** Day and week (Quire §5.54) is not a calendar app: it shows each account's main calendar beside the mail and writes only answers to invitations and time set aside for a mail, with no month view, no editing of other people's events, no repeat rules, reminders or scheduling, and the provider's own calendar a click away from any event.
- **IMAP and iCloud Mail, Exchange on premises, S/MIME and PGP.** IMAP needs an IMAP client, SMTP and a MIME parser, several thousand lines with no delta sync to lean on; it is year-two work, after JMAP has shown the port carries a third provider.
- **Server-side drafts.** Drafts stay on this Mac. Two-way drafts mean conflict handling and duplicate drafts on the phone; the cost is real and the gain small while a draft is a window on a Mac.
- **Addresses from the Contacts app, avatar photos, a per-sender image allowlist, hover buttons on rows, row animations, Delete Forever and Empty Trash.** Quire §9's reasons stand.
- **Localisation.** The voice rules in §4.13 are precise, and a half-translated client is worse than an English one. Revisited for year two if there are users who need it.
- **Push for Gmail and Microsoft.** Both need a server of ours (Pub/Sub, Graph webhooks) between the provider and the Mac. Polling at 5 s stays, and JMAP push shows what instant looks like.
- **Mobile.**

## 7. Decisions the owner makes

| Decision | Needed by | Recommendation |
|---|---|---|
| Apple Developer Program membership for a Developer ID identity | Q1, item 1 | Yes; it is the whole of "it ships" |
| Updater: the built-in check, or Sparkle as a third dependency | Q1, item 2 | The check. Add Sparkle only if installing by hand is the complaint users actually make |
| Google OAuth: keep user-registered clients, or bundle a verified client (CASA assessment, yearly) | Before more than about 100 users | Keep user-registered clients through 1.0; `docs/OAUTH-SETUP.md` gains the step that moves the consent screen to "In production" so refresh tokens stop expiring every seven days |
| Third provider: JMAP first, or IMAP | Q4, item 1 | JMAP; IMAP is year two |
| Retention default | Q1, item 6 | Everything, with the size shown |
| Minimum macOS after macOS 27 | Q4, item 4 | 26 |
| AI: whether, where and how (decided 20 November 2026) | Help me write, Quire 1.11 | Decided by the owner: one feature, Help me write, only when the user triggers it, with a consent sheet on first use that says in few words what is sent and when. Providers: Anthropic and OpenAI, each by the user's API key or by the user's own CLI sign-in (Claude Code, Codex). Off by default |

## 8. Reading this document

Each feature carries *Costs* (which of the four guardrails it touches), *Stays inside* (how), *Budget* (its row in the performance table when it has one), *Spec* (the Quire sections it changes) and a size. An item without a cost line costs nothing on the four, which is what most of Q1 is for.

When a quarter ends with items unshipped, they move, they do not pile up: the next quarter's list is cut to fit, from the bottom. The order inside a quarter is the order of value over cost, and the last item of every quarter is the first one cut.
