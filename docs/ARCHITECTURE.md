# SuperSparrow architecture

SuperSparrow is a local-first Mac mail client. Every interaction is a read or write against a local SQLite store; the network never sits between a keystroke and a pixel. This document is the contract every module is built against.

## Product scope for v1

Sparrow's shape, Superhuman's speed:

- Unified inbox across Gmail and Microsoft accounts, with a thin account strip to narrow to one account.
- Views: Inbox, Starred, Sent, Drafts, Trash, All mail. No folders, no labels, ever shown.
- One "Focused" toggle on the inbox, mapping Gmail Primary category and Outlook Focused Inbox.
- Read conversations as stacked cards; quoted text folded; inline images; attachments with Quick Look.
- Actions: archive, mark read/unread, star, trash, restore. Undo for every action.
- Reply, reply all, forward, new message. Plain composer: bold, italic, underline, links, lists, quotes, attachments. Undo send (five seconds).
- Full-text search over subject, participants, and body, as you type.
- Keyboard first: `j`/`k` move, `e` archive, `s` star, `u` unread, `#` trash, `r` reply, `a` reply all, `f` forward, `c` compose, `/` search, `⌘1`..`⌘9` switch account, `⌘0` unified.
- Unread badge on the Dock icon. New-mail notifications.

Out of scope for v1: rules, snooze, send later, calendar invites, S/MIME, server drafts, on-premises Exchange, IMAP, multiple windows beyond compose.

## Modules

```
SSDesign (Quire tokens, components)
        ▲ draws with
SuperSparrowApp (AppKit, WebKit)  ──reads──▶  MailStoring (SQLite)  ◀──writes──  SyncEngine (actors)
        │ commands                                                                   │
        └──────────────▶  MailClient (facade)  ─────────────────────────────────────┘
                                                                                      │
                                                                  MailProvider ◀──────┘
                                                               ┌──────┴──────┐
                                                        GmailProvider    GraphProvider
                                                               └──────┬──────┘
                                                          AccessTokenProvider (OAuth, Keychain)
```

- **SSCore/Model**: value types shared by everything. Already written; change only by agreement.
- **SSCore/Ports**: `MailProvider`, `MailStoring`, `MailClient`, `TokenStore`, `AccessTokenProvider`, sanitizer output. Already written.
- **SSCore/Store**: `SQLiteMailStore: MailStoring` using GRDB `DatabasePool` (WAL). Schema in `docs/DATA-MODEL.md`.
- **SSCore/Sync**: `SyncEngine` (one actor per account), `OperationRunner` (outbox replay), `SendRunner` (undo window then send), `Hydrator` (bodies for the top of the inbox), `MailEngine: MailClient` (facade wiring these together).
- **SSCore/Auth**: `OAuthFlow` (PKCE, loopback redirect on 127.0.0.1, system browser), `KeychainTokenStore: TokenStore`, `TokenManager: AccessTokenProvider`, `ClientConfigurationStore` (reads `oauth-clients.json`).
- **SSCore/Render**: `HTMLSanitizer` producing `SanitizedBody` with SwiftSoup, plus `QuoteDetector` and `TextExtractor`.
- **SSGmail**: Gmail REST API client. Bootstrap = `users.messages.list` newest first with `-in:spam -in:trash -in:chats` (chats are hidden from All mail in Gmail too), hydrated via batch `messages.get?format=metadata`. Changes = `users.history.list` from the `historyId` captured by `users.getProfile` before enumeration. Bodies via `messages.get?format=full`, MIME tree walked for text/html, text/plain, attachments and inline parts. Send builds RFC 5322 MIME (multipart/alternative inside multipart/mixed) base64url-encoded into `messages.send`, with `threadId` when replying; messages over 1 MiB of MIME go through the media upload endpoint (`uploadType=multipart`) instead because Gmail caps JSON request bodies. Changes map to `messages.batchModify` label edits.
- **SSGraph**: Microsoft Graph client. Bootstrap = `/me/messages?$orderby=receivedDateTime desc&$select=...` paging, excluding Deleted Items and Junk by parentFolderId. Changes = per-folder `/me/mailFolders/{id}/messages/delta` for inbox, sentitems, drafts, archive, deleteditems, junkemail and every other folder discovered via `/me/mailFolders?includeHiddenFolders=false`, seeded without a `$filter` (the only filter message delta accepts, `receivedDateTime ge`, also limits which messages the delta tracks, so reads, moves and deletes of older mail would never be reported); the first round lists each folder once, which also repairs anything the offset-paged bootstrap skipped. The opaque cursor is a JSON map of folder id to deltaLink. Bodies via `/me/messages/{id}?$select=body,uniqueBody` with `Prefer: outlook.body-content-type="html"` and `/attachments` (Content-IDs selected as `microsoft.graph.fileAttachment/contentId`, since the base attachment type has none). Send via `/me/sendMail` while attachments fit its 4 MB request, otherwise via a draft (`POST /me/messages`); replies via `/me/messages/{id}/createReply` then PATCH then `/send` so Outlook threads them. Draft attachments of 3 MB and more go through `createUploadSession` in 3.125 MiB chunks; a draft whose filling fails is deleted so retries leave no orphans. Changes map to PATCH `isRead`/`flag` and POST `/move`. Batch with `$batch` (20 per call). Honor 429 `Retry-After`.
- **SSCore support folders** (`ListSupport/`, `ConversationSupport/`, `ComposeSupport/`, `ShellSupport/`): the pure, testable halves of the app's surfaces (row text and layout, the reader's render payload and shell, reply recipients and drafts, the sync line, undo order, toasts' words). `Model/AccountLabels` is the one place an account's monogram, tile letter, name and From title are derived, so every surface shows the same ones.
- **SSDesign**: the Quire design runtime and every component, as a library the app links. See "Design" below.
- **SuperSparrowApp**: `AppDelegate`, `MainWindowController` (NSSplitViewController: account rail, message list, conversation), `MessageListViewController` (NSTableView, fixed rows, manual layout, cached attributed strings), `ConversationViewController` (warm `WKWebView` pool, `ss-cid` scheme handler, quick reply), `ComposeWindowController`, `KeyboardRouter`, `SettingsWindowController` (SwiftUI), `NewMailNotifier`, the Dock badge, and, in debug builds, the Design Gallery (`Design/`, below).

## Data flow

1. **Add account**: `MailClient.addAccount` → `OAuthFlow` opens the system browser → loopback receives the code → tokens go to Keychain → provider `profile()` → `Account` row → engine starts bootstrap.
2. **Bootstrap**: provider pages newest first; each page is upserted in one transaction; the UI's observation fires and rows appear while enumeration continues. The change cursor from the first page is stored only after enumeration completes, so an interrupted bootstrap resumes from `BootstrapState.nextPage` and a completed one polls from a cursor that predates enumeration (no gap, duplicates are idempotent upserts).
3. **Hydration**: after every page and every poll, fetch bodies for `messageIDsMissingBodies` (inbox first, newest first), sanitize, store `StoredBody`. Bounded concurrency per account (4 in flight).
4. **Poll**: every 30 s per account, plus on `syncNow`, plus on app activation. `changes(since:)` until `hasMore == false`. `resetRequired` → `wipeMailData` → bootstrap again.
5. **User action**: UI calls `MailClient.perform` → `store.enqueue(operation)` applies the change to the targets and inserts the operation in one transaction → observations fire → `OperationRunner` replays pending operations in order per account with exponential backoff; `confirmed` operations are deleted; `uncertain` ones (timeouts) are left for the next poll to settle.
6. **Pending operations win**: when a poll upserts provider state for a message that has a pending or in-flight operation, the store re-applies the pending changes on top of the provider state so an archived thread cannot pop back into the inbox before the provider catches up.
7. **Send**: `MailClient.send` stores a `PendingSend` with `sendAfter = now + undoWindow`; `SendRunner` sends it after the window; the sent message appears via the next poll (Gmail returns `threadId`, Graph threads by `conversationId`).

## Rendering

- Sanitize at sync time with SwiftSoup: strip `script`, `iframe`, `object`, `embed`, `form`, `input`, `meta`, `link`, `base`, event-handler attributes, `javascript:` URLs; keep `style` attributes and `<style>` blocks (the body is isolated in a sandboxed iframe); rewrite `cid:` images to `ss-cid://` URLs; replace remote image `src` with `data-ss-src` and remote `background=` with `data-ss-background`, and count them; strip `url(http…)` from inline CSS (counted, but not restorable by Load images); wrap detected quoted content in `<div class="ss-quote">`.
- The conversation view is one `WKWebView` showing a shell document (CSS and JS loaded once). Rendering a conversation is one `evaluateJavaScript("ss.render(json)")` that builds cards and places each body in `<iframe sandbox srcdoc>`. Inline images load through a `WKURLSchemeHandler` for `ss-cid` that reads attachment bytes from the local cache (fetching through `MailClient.attachmentData` when missing).
- Keep a pool of three warm web views. When the selection lands on a row, render the next row, the previous row, and the next unread conversation into spare views. Selection highlight moves immediately; rendering is debounced by 30 ms while a key repeats, and pre-rendering waits until the selection has rested for 150 ms.
- A read or star change in the shown conversation patches the card headers (`ss.flags`) instead of re-sending bodies. Whether a body has quoted text and how many remote images it parks are stored with it at sync time, so no render scans HTML.
- Dark mode: the shell adapts; email bodies get `color-scheme: light dark` and a per-message "show original" escape hatch.

## Design

The design language is Quire (`docs/DESIGN-LANGUAGE.md`). `docs/design/tokens.json` is its single source; nothing downstream is edited by hand.

```
docs/design/source/tokens_def.py ──sh docs/design/source/make.sh (python3)──▶ docs/design/tokens.json
                                                                             docs/DESIGN-LANGUAGE.md, docs/design/specimen.html
docs/design/tokens.json ──swift scripts/tools/quire-tokens.swift──▶ Sources/SSDesign/Generated/QuireTokens*.swift
                                                                    Sources/SSCore/ConversationSupport/QuireCSS.swift
                                                                    Tests/SSDesignTests/Generated/*.swift
                                                                    Resources/Assets.xcassets (AccentColor)
docs/design/tokens.json ──swift scripts/tools/app-icon.swift──▶ Resources/AppIcon.icns (iconutil, macOS 15)
                                                                Resources/AppIcon.icon (Icon Composer document, macOS 26+)
```

- **SSDesign** (`Sources/SSDesign`): the design runtime as a library, so it can be unit-tested; the app depends on it. AppKit, SwiftUI and QuartzCore only: no SSCore, GRDB or WebKit. Generated tokens (`NSColor.q…` and `Color.q…` providers with the Graphite branch, account and avatar palettes, `QuireFont.Role`, `Quire.Space`/`Radius`/`Border`/`Elevation`/`Motion`, `Quire.Layout.<Group>.<name>`, icons, glyphs, the cheat sheet) sit in `Generated/`; beside them the hand-written runtime: `QuireFont` (cached fonts, exact line heights, the New York coverage test), `QuireEnvironment` (Graphite, Increase Contrast, Reduce Motion, Reduce Transparency as a thread-safe snapshot plus a change notification), `QuireLayerColors` (re-resolves `CGColor`s on appearance and environment changes), `Quire.Motion` (token animations, Reduce Motion fallbacks, `finishAll()`), `QuireGlyph`/`QuireSVGPath` and `QuireSymbol`.
- **Reader CSS**: `QuireCSS.head` lives in SSCore because the reader shell is built there and SSCore does not import AppKit. It is byte-identical to the specimen's `<style>` head (`QuireCSSTests`).
- **Components**: `Sources/SSDesign/AppKit` holds the AppKit components: `QuireControl` and the controls built on it (`QuireButton`, `QuireIconButton`, `QuirePopUpButton`, `QuireCheckbox`, `QuireRadioGroupView`, `QuireToggle`, `QuireTextField` with its secure variant, `QuireSearchField`), `QuireBannerView`, the slips (`QuireSlipView` for toasts, `QuireUndoPanelView`, `QuireSequenceHUDView`), `QuireKeycap`, `QuireAvatarRenderer`, `QuireHairline`, and `QuireWindowChrome`, which configures and measures the main and composer windows' title bars. `Sources/SSDesign/SwiftUI` holds the Settings controls (`QuireButtonStyle`, `QuireFieldStyle`, `QuireSecureField`, `QuireRadioGroup`, `QuireBanner`, `QuireAccountRow` and the rest). The app composes them and defines no colours, fonts or metrics of its own.
- **Accent and icon**: `scripts/build-app.sh` compiles `Resources/Assets.xcassets` and `Resources/AppIcon.icon` into `Contents/Resources/Assets.car` with `xcrun actool` (Xcode), and sets `NSAccentColorName = AccentColor` and `CFBundleIconName = AppIcon`; the drawn `AppIcon.icns` is copied beside it as `CFBundleIconFile`. Without actool it warns: the bundle falls back to the system accent and the `.icns` alone (no dark or tinted icon on macOS 26 and later). A macOS app icon set cannot carry dark or tinted images, which is why the icon is an Icon Composer document.
- **Design Gallery** (`Sources/SuperSparrowApp/Design`, debug builds only): Debug › Design Gallery, or `--gallery`, opens every SSDesign component in every state on a page laid out like section D of `docs/design/specimen.html`, with a bar that forces the appearance and the Quire environment (Graphite, Increase Contrast, Reduce Motion, Reduce Transparency) for that window. `--snapshot-gallery=<png>` renders the whole page. Its page furniture (`DesignGalleryStudio`) copies the specimen's, which is not a Quire token and appears on no other screen.
- **Tests**: `Tests/SSDesignTests` asserts every contrast pair in four modes (and every Graphite pair), the account-palette rules, the radius scale, row metrics across scripts, the glyph paths, and that the runtime still equals `tokens.json`. The colour math is a port of `docs/design/source/colorlib.py`; a pair that fails in Swift but passes in python is a port bug.

Regenerate after changing tokens:

```
sh docs/design/source/make.sh               # tokens.json, the spec and the specimen, from the python sources
swift scripts/tools/quire-tokens.swift      # Swift runtime, reader CSS, generated tests, accent asset
swift scripts/tools/quire-tokens.swift --check   # exits 1 and lists stale outputs; scripts/test.sh runs it first
swift scripts/tools/app-icon.swift          # the app icon, after a change to the mark, layout.appIcon or the inks
```

## Launch options

Debug aids, read by `LaunchOptions` (and `--snapshot-state` by the main window). They never touch the user's mail: the welcome and alert snapshots run over a throwaway store, and the others need `--demo`. Every path is absolute. Only `--demo` and `--reset-demo` exist in release builds; a release build ignores every other option here, so nothing can make it write its windows (Settings shows the configured OAuth client ID) to a path a caller chooses. The Design Gallery (`Sources/SuperSparrowApp/Design`) is compiled only into debug builds. Snapshots of the main window or a composer use the default frame, split and composer size, ignore the pointer, and never save a size.

| Option | What it does |
|---|---|
| `--demo` | Opens the two made-up demo mailboxes (`demo.sqlite`, §5.43) instead of the user's accounts. |
| `--reset-demo` | Wipes the demo store first; implies `--demo`. |
| `--appearance=light` / `=dark` | Forces the app's appearance, so one machine can check both. |
| `--snapshot=<png>` | In demo mode, opens the first inbox conversation and writes the main window with the reader composited in. The app keeps running. |
| `--snapshot-compose=<png>` | In demo mode, writes a reply composer for the first inbox conversation. The app keeps running. |
| `--snapshot-state=<a,b,…>` | Debug. Puts the main window in named states before `--snapshot`: `key`, `notkey`, `several` (three conversations selected), `minimal`, `narrowed`, `search`, `toast`, `adding`, `signin`, `reconnect`, `focus-rail`, `focus-action`, `hover-demo`, `hover-masthead`, `ic`, `graphite`. |
| `--snapshot-welcome=<png>` | Writes the welcome screen over a throwaway store, then quits. |
| `--snapshot-welcome-states=<png>` | Every welcome state of §5.39, stacked, then quits. |
| `--snapshot-settings=<png>` | Every Settings tab, stacked, then quits (implies `--demo`). Settings › OAuth shows the configured client ID. |
| `--snapshot-settings-states=<png>` | The Settings states of §5.40 (adding, add failed, reconnecting, empty, the OAuth notices, Saved), stacked, then quits. |
| `--snapshot-cheatsheet=<png>` | The main window with the keyboard cheat sheet open, then quits. |
| `--snapshot-hud=<png>` | The main window with the g-sequence HUD showing, then quits. |
| `--snapshot-alerts=<png>` | The alert inventory (§5.33) as the system draws it, then quits. |
| `--gallery` | Debug. Opens the Design Gallery at launch. |
| `--snapshot-gallery=<png>` | Debug. Writes the whole Design Gallery page, then quits. |

For example: `scripts/build-app.sh debug && dist/SuperSparrow.app/Contents/MacOS/SuperSparrow --demo --reset-demo --appearance=dark --snapshot-state=key --snapshot=/tmp/main-dark.png`.

## Performance budgets

Measured with `os_signpost` on a synthetic 100,000-message mailbox (see `Tests/SSCoreTests/Fixtures/SyntheticMailbox.swift`):

| Interaction | Budget |
|---|---|
| Move selection (`j`/`k`) | 16 ms |
| Open conversation, pre-rendered | 50 ms |
| Open conversation, body cached | 100 ms |
| Archive, star, mark read (local) | 16 ms |
| Search keystroke, full text | 50 ms |
| Launch to usable inbox | 500 ms |
| List refresh after a sync transaction | 50 ms |
| New mail visible with polling | 30 s |
| Sanitize a 200 KB newsletter (sync time, off the main thread) | ≤ 2.5 × the SwiftSoup parse of the same HTML, about 21 ms on M-series (`SanitizerThroughputTests`) |

The sanitizer's budget is relative because the parse is a floor the module cannot go under (about 8.5 ms for that fixture on an M-series Mac); what sanitizing adds (the scrub, the CSS filter and its design facts, quote detection, text extraction, one serialisation) must stay within 1.5 parses on top. It runs at sync time and in the design-facts backfill, never when a message opens.

Rules that keep the budgets: search observations fetch their first page off the main thread and deliver only when the rows change; fixed row heights; no Auto Layout inside list rows; attributed strings built once per row and cached by conversation id plus a version; avatars decoded off the main thread, initials painted first; `DatabasePool` reads never wait on sync writes; sync writes batched 200 messages per transaction; no network on the launch path.

## Security and privacy

- Tokens live in the Keychain. The database lives in `~/Library/Application Support/SuperSparrow/mail.sqlite` (0600).
- Remote images are blocked by default; loading them is per message, and loaded ones are cached on disk. The "Load remote images" preference is read for every body synced and by the reader, which renders each body that has not had its images loaded under a Content-Security-Policy (`img-src ss-cid: data:`, no other fetches), so turning the preference off takes effect at once, even for bodies stored while it was on.
- Attachments are written to a per-session temporary folder and quarantined as they are written (`com.apple.quarantine`, type email attachment, agent SuperSparrow), so Gatekeeper asks before anything in them runs; copies saved to Downloads or with Save As keep the mark. Opening a program or script (`.app`, `.command`, `.terminal`, `.jar`, `.pkg`, shell and AppleScripts, `.fileloc`) from the reader asks first, with Cancel as the default. Errors about these files are logged by domain and code only, since a file error names the attachment.
- No analytics, no crash reporting, no third-party services. Email content goes only to Google, Microsoft, and this machine.

## Testing

`scripts/test.sh` checks that the generated design files match `tokens.json`, then runs every target:

- **SSCoreTests**, **SSGmailTests**, **SSGraphTests**: the store, engine, providers, sanitizer and the surfaces' pure halves.
- **SSDesignTests**: the generated contrast, palette, radius and metric tests (`Generated/`, never edited) and the hand-written component, font, glyph and window-chrome tests.
- **SuperSparrowAppTests**: the app's own windows. `MainWindowHarness` builds a main window over a throwaway store in a temporary directory, and the draft tests point the shared draft store at a temporary folder, so no test touches real mail, real drafts, the Keychain or the network.

Gated runs, skipped unless asked for:

- `SS_PERF=1 swift test -c release --filter …`: the list benchmark (`MessageListPerformanceTests`, `SS_LIST_PERF_MESSAGES` sets the mailbox size, 100,000 by default), the store, row-text, layout and sanitizer throughput measurements.
- `SS_UI_TESTS=1 swift test --filter …`: renders that write files or need a live web view (`ConversationRowStatesRenderTests`, the reader shell's web view test).
- `QUIRE_GALLERY_OUT=<dir>` (`ComponentGalleryTests`) and `QUIRE_GALLERY_DIR=<dir>` (`SettingsGalleryTests`): the component galleries in all four modes, as PNGs.

What each layer covers:

- Store: contract tests against in-memory GRDB covering upsert, conversation summaries, the unified query, pending-operations-win, FTS, and paging.
- Engine: fake provider with scripted pages, throttling, reset, and uncertain outcomes; assert store state after each step and after a simulated restart.
- Providers: JSON fixtures recorded from real APIs (anonymized) decoded through the real mappers; MIME builder round-trips.
- Sanitizer: attack fixtures (script injection, event handlers, `javascript:` URLs, CSS exfiltration, cid spoofing) and real Gmail/Outlook HTML shapes.
- UI: the main window, list, multi-selection, menus, undo order, drafts, sign-in and the composer's chrome through `SuperSparrowAppTests`; the snapshots above for looking at.
