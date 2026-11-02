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
- **SuperSparrowApp**: `AppDelegate`, `MainWindowController` (NSSplitViewController: account strip, message list, conversation), `MessageListViewController` (NSTableView, fixed 72pt rows, manual layout, cached attributed strings), `ConversationViewController` (warm `WKWebView` pool, `ss-cid` scheme handler, quick reply `NSTextView`), `ComposeWindowController`, `SearchField`, `KeyboardShortcuts`, `NotificationCenter` bridge, `DockBadge`.

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

Rules that keep the budgets: search observations fetch their first page off the main thread and deliver only when the rows change; fixed row heights; no Auto Layout inside list rows; attributed strings built once per row and cached by conversation id plus a version; avatars decoded off the main thread, initials painted first; `DatabasePool` reads never wait on sync writes; sync writes batched 200 messages per transaction; no network on the launch path.

## Security and privacy

- Tokens live in the Keychain. The database lives in `~/Library/Application Support/SuperSparrow/mail.sqlite` (0600).
- Remote images are blocked by default; loading them is per message, and loaded ones are cached on disk. The "Load remote images" preference is read for every body synced and by the reader, which renders each body that has not had its images loaded under a Content-Security-Policy (`img-src ss-cid: data:`, no other fetches), so turning the preference off takes effect at once, even for bodies stored while it was on.
- No analytics, no crash reporting, no third-party services. Email content goes only to Google, Microsoft, and this machine.

## Testing

- Store: contract tests against in-memory GRDB covering upsert, conversation summaries, the unified query, pending-operations-win, FTS, and paging.
- Engine: fake provider with scripted pages, throttling, reset, and uncertain outcomes; assert store state after each step and after a simulated restart.
- Providers: JSON fixtures recorded from real APIs (anonymized) decoded through the real mappers; MIME builder round-trips.
- Sanitizer: attack fixtures (script injection, event handlers, `javascript:` URLs, CSS exfiltration, cid spoofing) and real Gmail/Outlook HTML shapes.
- UI: a smoke test that launches the app with a seeded database and asserts first paint under budget.
