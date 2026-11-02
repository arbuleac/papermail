# Data model (SQLite via GRDB)

One database per user: `~/Library/Application Support/SuperSparrow/mail.sqlite`, WAL mode, `DatabasePool`. Every table that holds account data carries `account_id` and cascades on account delete. All timestamps are Unix epoch milliseconds (INTEGER).

## Tables

### accounts
| column | type | notes |
|---|---|---|
| id | TEXT PK | AccountID |
| kind | TEXT | gmail / microsoft |
| email | TEXT | |
| display_name | TEXT | |
| color_hex | TEXT | TEMPORARY: the pre-Quire dot colour the app still draws; superseded by `ink_slot` and dropped from use once the app draws `NSColor.qAccount(ink_slot)` |
| added_at | INTEGER | |
| sync_cursor | TEXT NULL | provider-opaque |
| bootstrap_json | TEXT NULL | `BootstrapState` as JSON |
| ink_slot | INTEGER NOT NULL DEFAULT 0 | account palette slot 0–9 (v4). The engine assigns it on add (`AccountInkSlot.next`: the lowest slot no account wears; once all ten are worn, the lowest slot among those worn by the fewest accounts). Accounts that existed before v4 were backfilled in creation order (`added_at`, then `id`) with the same rule, which from an empty palette is the creation index mod 10. Settings may move it (`setInkSlot`); the store refuses values outside 0–9. Colours live in the design layer, never here |
| monogram | TEXT NULL | the monogram the user typed in Settings (v4): trimmed, at most 2 characters (`Account.monogramMaxLength`). NULL = derived from the domain by the UI (docs/DESIGN-LANGUAGE.md, Monograms) |

### messages
| column | type | notes |
|---|---|---|
| account_id | TEXT | FK accounts |
| provider_id | TEXT | |
| conversation_provider_id | TEXT | |
| internet_message_id | TEXT NULL | |
| in_reply_to | TEXT NULL | |
| references_json | TEXT | JSON array |
| subject | TEXT | |
| snippet | TEXT | |
| from_json | TEXT NULL | EmailAddress JSON |
| to_json, cc_json, bcc_json, reply_to_json | TEXT | JSON arrays |
| date_ms | INTEGER | |
| roles | INTEGER | bitmask: inbox=1, sent=2, drafts=4, trash=8, spam=16 |
| is_read | INTEGER | |
| is_starred | INTEGER | |
| inbox_section | TEXT | focused / other / unknown |
| has_attachments | INTEGER | |
| label_ids_json | TEXT | |
| folder_id | TEXT NULL | |
| provider_version | TEXT NULL | |
| size_bytes | INTEGER NULL | |
| has_body | INTEGER | 1 when a `bodies` row exists |
| PRIMARY KEY (account_id, provider_id) | | |

Indexes: `(account_id, conversation_provider_id)`, `(account_id, has_body, date_ms DESC)` for hydration order, `(date_ms DESC)`.

### bodies
| column | type | notes |
|---|---|---|
| account_id, provider_id | PK | FK messages (cascade) |
| html | BLOB NULL | original, zlib-compressed |
| text | BLOB NULL | original text part, zlib-compressed |
| rendered_html | BLOB | sanitized, zlib-compressed |
| plain_text | TEXT | extracted, uncompressed, feeds FTS |
| attachments_json | TEXT | `[AttachmentInfo]` |
| has_quoted | INTEGER NULL | rendered_html has detected quoted text; NULL for bodies stored before v2 |
| blocked_images | INTEGER NULL | remote images blocked at sync time (parked in `data-ss-src` or `data-ss-background`, or dropped CSS `url()`); NULL for bodies stored before v2 |
| typesetting | INTEGER NULL | `BodyTypesetting` (v3): 0 = plain, 1 = unstyled, 2 = styled (fixed codes; an unknown code reads as styled). NULL for bodies stored before v3, rendered as styled. See "Body design facts" |
| declares_colors | INTEGER NULL | the body sets its own background or text colour (v3). NULL = unknown: treated as true for styled bodies, false otherwise |
| covered_by_new_york | INTEGER NULL | New York draws every letter and decimal digit of `plain_text` (v3). NULL = unknown, treated as false |

### conversations (denormalized summary rows, maintained by the store)
| column | type | notes |
|---|---|---|
| account_id, provider_id | PK | |
| subject | TEXT | subject of the first message with a non-empty subject |
| snippet | TEXT | snippet of the latest message |
| participants_json | TEXT | distinct senders oldest first |
| latest_date_ms | INTEGER | |
| latest_provider_id | TEXT | |
| message_count | INTEGER | messages not in trash/spam |
| unread_count | INTEGER | |
| is_starred | INTEGER | any message starred |
| has_attachments | INTEGER | |
| in_inbox | INTEGER | any message with inbox role and not trash/spam |
| in_sent | INTEGER | any message with sent role |
| in_drafts | INTEGER | |
| in_trash | INTEGER | every non-spam message is in trash |
| inbox_section | TEXT | focused if any inbox message is focused, else other/unknown |
| has_pending_ops | INTEGER | |
| failed_op_kind | TEXT NULL | `OperationKind` raw value of the newest failed operation on the conversation the user has not seen (v5): `archive`, `moveToInbox`, `markRead`, `markUnread`, `star`, `unstar`, `trash`, `restoreFromTrash`. Not derived from the messages: kept by the operation writes (see "Failed-operation mark") and carried over by every summary refresh |

Indexes: `(in_inbox, latest_date_ms DESC)`, `(is_starred, latest_date_ms DESC)`, `(in_sent, latest_date_ms DESC)`, `(latest_date_ms DESC)`, `(account_id, latest_date_ms DESC)`.

After `upsertMessages` or `deleteMessages`, recompute the summary row for every touched conversation with one aggregate query per batch (`GROUP BY conversation_provider_id`). Delete the summary row when a conversation has no messages left.

### message_fts (FTS5, external content = bodies/messages)
Columns: `subject`, `participants`, `body`. Tokenizer `unicode61 remove_diacritics 2`. `rowid` = `messages.rowid`. Maintained by the store on upsert/saveBody/delete (no triggers, so inserts stay in the same transaction and remain explainable). Search joins hits to `conversations` and orders by `latest_date_ms`.

### operations
| column | type | notes |
|---|---|---|
| id | TEXT PK | |
| account_id | TEXT | |
| change_json | TEXT | `MetadataChange` |
| targets_json | TEXT | `[provider_id]` |
| created_at | INTEGER | |
| status | TEXT | pending / inFlight / confirmed / failed / uncertain |
| attempts | INTEGER | |
| last_error | TEXT NULL | |
| next_attempt_at | INTEGER NULL | next try of a pending or uncertain row. A failed row is never tried again, so for it the column holds its expiry: the runner sets failure time + 24 h (`SyncTuning.failedOperationRetention`) when it gives up, and `pruneFailedOperations` deletes failed rows at or past it (or with none) |

### operation_targets
`(operation_id, account_id, provider_id)` so "pending operations win" can find operations for a message with one indexed lookup.

### pending_sends
`id TEXT PK, account_id, message_json (OutgoingMessage, attachments inline as base64), created_at, send_after, status, attempts, last_error`.

### contacts
`account_id, address (PK with account_id), name, seen_count, last_seen_ms`. Updated from from/to/cc on upsert. Suggestions order by `seen_count * recency`.

### Body design facts
Worked out once by `HTMLSanitizer` at sync time and stored with the body, so the reader never scans HTML to decide how to set a message (docs/DESIGN-LANGUAGE.md §8.4, §8.5). The render payload carries them per message (`typesetting` as its name, `declaresColors`, `coveredByNewYork`, next to `hasBody`) together with the conversation account's `inkSlot`.
- **typesetting**: `plain` when the body came from the text/plain part (no HTML part, a blank one, or one that failed to parse). `unstyled` for HTML with no author styling: no `<style>` element with content left after filtering; no `style` attribute or body style declaring anything beyond the neutral text-flow and spacing properties (`margin*`, `padding*`, `border*`, `direction`, `unicode-bidi`, `text-align`, `word-wrap`, `overflow-wrap`, `word-break`, `white-space`, `line-break`, `-webkit-line-break`, `-webkit-nbsp-mode`, `caret-color`, `*text-size-adjust`, plus `width`, `height`, `max-width`, `max-height` on `<img>`); no colour (so unstyled never declares colours); no `<font>` with `face` or `size`; no layout table (a `<table>` with `width`, `height`, `align`, `bgcolor`, `background`, `cellpadding`, `cellspacing` or `role="presentation"`, or a table inside a table). `styled` for every other HTML body.
- **declares_colors**: true when any of these appears: a `color`, `background`, `background-color` or `background-image` declaration in a `style` attribute or a `<style>` block whose whole value is not a no-colour keyword (`inherit`, `initial`, `unset`, `revert`, `revert-layer`, `currentcolor`, `transparent`, `none`); a non-empty `bgcolor` or `background` attribute on any element; a non-empty `color` attribute on `<font>`; a non-empty `text` or `link` attribute on `<body>`. A blocked remote background still counts. Plain bodies never declare colours.
- **covered_by_new_york**: every letter (Unicode L*) and decimal digit (Nd) of the extracted text is in New York's character set; punctuation, symbols, emoji and marks are ignored because they fall back to the same system fonts beside either face. The character set is a range table in `Render/NewYorkCoverage.swift`, measured with `CTFontCopyCharacterSet` by `scripts/tools/newyork-coverage.swift`.

### attachment_cache (file system, not SQL)
`~/Library/Caches/SuperSparrow/attachments/<account>/<message>/<attachmentID>`; inline images keyed by content id.

## Migrations
Applied in order by GRDB's `DatabaseMigrator`; a migration is never edited once released.
- `v1-mailbox`: the tables above as first released.
- `v2-body-render-facts`: `bodies.has_quoted`, `bodies.blocked_images`.
- `v3-body-typesetting`: `bodies.typesetting`, `bodies.declares_colors`, `bodies.covered_by_new_york` (existing bodies stay NULL).
- `v4-account-ink`: `accounts.ink_slot` (backfilled in creation order), `accounts.monogram`.
- `v5-failed-operation-mark`: `conversations.failed_op_kind`.

## Semantics

- **Unified inbox** = `SELECT … FROM conversations WHERE in_inbox = 1 [AND account_id IN (…)] [AND inbox_section = 'focused'] [AND unread_count > 0] ORDER BY latest_date_ms DESC LIMIT ?`. Paging uses `latest_date_ms < ?`.
- **All mail** = `message_count > 0 AND in_trash = 0`. **Trash** = `in_trash = 1`. **Starred** = `is_starred = 1 AND in_trash = 0`.
- **Pending operations win**: on upsert, for every incoming message that has rows in `operation_targets` with status pending/inFlight/uncertain, re-apply those operations' changes (oldest first) on top of the incoming metadata before writing it.
- **Confirmed operations** are deleted together with their targets.
- **Failed operations** stop winning (their changes are no longer re-applied on upsert) and are never replayed. The outbox prunes them at the start of every drain once `next_attempt_at` has passed, one indexed lookup on `(account_id, status, created_at)`.
- **Failed-operation mark** (`conversations.failed_op_kind`, `ConversationSummary.failedOperation`, docs/DESIGN-LANGUAGE.md §5.7, §8.5). Both stores apply the same rules, inside the transaction of the write that triggers them. "An operation targets a conversation" means one of its targets is currently a message of that conversation; "newer" compares `created_at`, then `id`.
  - *Set*: writing an operation as `failed` from any other status (or inserting it failed) sets the mark of every conversation it targets to its kind, unless that conversation already carries a mark and a failed operation newer than this one also targets it (the mark names the newest failure). Writing an already failed row again changes nothing.
  - *Acknowledged*: `acknowledgeFailedOperation(conversationID:)` sets it to NULL and leaves the failed row in place. The app calls it once a conversation has been open for 150 ms; the SQLite store checks for a mark with a read first, so the common case never takes the writer.
  - *Settled*: deleting an operation (how a confirmed operation leaves the outbox, and how a failed one is pruned), writing it out of `failed`, or writing it as `confirmed` clears the mark of every conversation it targets, unless a failed operation newer than it still targets that conversation. So a later operation that succeeds clears an older failure, an earlier one does not, and pruning the newest failed row clears what it marked.
  - The mark lives on the summary row: a conversation with no summary row (every message spam, or none left) cannot be marked, and loses its mark when the row goes.
  - Known limit: the schema keeps no per-operation acknowledgement, so the rules assume failures happen in creation order within a conversation, which is how the runner applies operations. If an older operation fails after a newer one was already acknowledged and both are still within their retention, pruning or settling the newer row can clear the older one's mark early.
- **Conversation key** is the provider's thread id scoped to the account. Never re-thread across accounts.
