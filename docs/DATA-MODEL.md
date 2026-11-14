# Data model (SQLite via GRDB)

One database per user: `~/Library/Application Support/SuperSparrow/mail.sqlite`, WAL mode, `DatabasePool`. Every table that holds account data carries `account_id` and cascades on account delete. All timestamps are Unix epoch milliseconds (INTEGER).

### The file
`auto_vacuum` is written into the file with its first page and fixed from then on: only a full VACUUM changes it. The store creates a new file with `auto_vacuum = INCREMENTAL` (`MailSchema.prepareAutoVacuum`, run by GRDB's `prepareDatabase` on the writer while the file is still empty, before WAL mode writes the first page), so the engine can hand the pages an eviction or a delete frees back to the file system a bounded step at a time (`PRAGMA incremental_vacuum(N)`, docs/ARCHITECTURE.md "Storage bounds"). A file created by an earlier build keeps `NONE`: switching it needs a full VACUUM (twice the disk, the writer held throughout), which the store never runs, so the engine's vacuum steps do nothing there (`reclaimFreePages` answers nil). Such a file stops growing while SQLite reuses its free pages, but does not shrink. The size Settings shows leaves those free pages out (`MailboxFootprint`), so it follows a clean-up even in such a file. A later release could compact it with `VACUUM INTO` a new file at a quiet launch and swap the files.

## Tables

### accounts
| column | type | notes |
|---|---|---|
| id | TEXT PK | AccountID |
| kind | TEXT | gmail / microsoft |
| email | TEXT | |
| display_name | TEXT | |
| color_hex | TEXT | retired: nothing reads it. The pre-Quire dot colour, superseded by `ink_slot`. v1 declared it NOT NULL without a default, so it stays: new rows store `''`, an upsert never changes it, and existing rows keep their old value |
| added_at | INTEGER | |
| sync_cursor | TEXT NULL | provider-opaque |
| bootstrap_json | TEXT NULL | `BootstrapState` as JSON |
| ink_slot | INTEGER NOT NULL DEFAULT 0 | account palette slot 0–9 (v4). The engine assigns it on add (`AccountInkSlot.next`: the lowest slot no account wears; once all ten are worn, the lowest slot among those worn by the fewest accounts). Accounts that existed before v4 were backfilled in creation order (`added_at`, then `id`) with the same rule, which from an empty palette is the creation index mod 10. Settings may move it (`setInkSlot`); the store refuses values outside 0–9. Colours live in the design layer, never here |
| monogram | TEXT NULL | the monogram the user typed in Settings (v4): trimmed, at most 2 characters (`Account.monogramMaxLength`). NULL = derived from the domain by the UI (docs/DESIGN-LANGUAGE.md, Monograms) |
| signature | TEXT NULL | the signature the user set in Settings › Accounts (v9), as the composer's own HTML subset (`ComposerHTMLExporter`: `div`, `p`, `b`, `i`, `u`, `a`, `br`), written by `setSignature` with the white space around it trimmed. NULL = none, the default; a blank value is stored as NULL. A local setting: never read from or written to the provider. Every rewrite of the row (`upsertAccount`) writes it from the account as given, as it does `ink_slot` and `monogram`, so a caller re-saving an account it read keeps it; signing in again or reconnecting does not rewrite the row. It goes with the row when the account is removed. The composer reads it back through `ComposerHTMLImporter`, which keeps only that subset (docs/DESIGN-LANGUAGE.md §5.20) |

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
| has_body | INTEGER | 1 when a `bodies` row exists, an evicted one included (so hydration, which looks for 0, never fetches an evicted body back) |
| list_unsubscribe | TEXT NULL | the `List-Unsubscribe` header as sent (RFC 2369), trimmed (v14); NULL when the message has none, when it is longer than 8 KB, or when nothing has reported it yet. Gmail reports it with every metadata fetch and the full body fetch; Graph only with the body fetch (`internetMessageHeaders`; list and delta calls cannot select headers), which `saveBody` writes here, never into `bodies`. Headers never change, so an upsert that carries none (a Graph listing, delta or backfill page) keeps the stored pair, and one that carries it replaces both columns. Messages stored before v14 stay NULL until their metadata (Gmail) or body (either) is fetched again; nothing fetches them back for this, so they offer no Unsubscribe. Read by `UnsubscribeMethod` (docs/ARCHITECTURE.md "Unsubscribe") |
| list_unsubscribe_post | TEXT NULL | the `List-Unsubscribe-Post` header as sent (RFC 8058), trimmed (v14); stored only beside a `list_unsubscribe`. Exactly `List-Unsubscribe=One-Click` beside an https URI makes the one-click request the way to unsubscribe |
| invitation_reply | TEXT NULL | the user's answer to the invitation the message carries, given in the reader on this Mac (v15): `accepted`, `tentative` or `declined` (`InvitationResponse` raw values; never rename them). NULL until they answer here. Local state: written only by the operation that queues the answer (`enqueue`, and a give-up, which puts back the answer it replaced, carried in the operation's change), never by `upsertMessages` or `writeBackfillMessages`, so no provider report undoes it; re-saving the body, an eviction and a reconcile's refresh keep it. Read with the row (`MessageMetadata.invitationReply`), so the conversation's observers see an answer |
| PRIMARY KEY (account_id, provider_id) | | |

Indexes: `(account_id, conversation_provider_id)`, `(account_id, has_body, date_ms DESC)` for hydration order, `(date_ms DESC)`.

### bodies
| column | type | notes |
|---|---|---|
| account_id, provider_id | PK | FK messages (cascade) |
| html | BLOB NULL | original, zlib-compressed |
| text | BLOB NULL | original text part, zlib-compressed |
| rendered_html | BLOB | sanitized, zlib-compressed. A text/plain body is `PlainTextRenderer` output: `<p>` paragraphs (blank lines end them) with `<br>` inside; plain bodies stored before paragraphs were introduced keep `<br><br>` until fetched again, since nothing re-renders a stored body |
| plain_text | TEXT | extracted, uncompressed, feeds FTS |
| attachments_json | TEXT | `[AttachmentInfo]` |
| has_quoted | INTEGER NULL | rendered_html has detected quoted text; NULL for bodies stored before v2 |
| blocked_images | INTEGER NULL | remote images blocked at sync time (parked in `data-ss-src` or `data-ss-background`, or dropped CSS `url()`); NULL for bodies stored before v2 |
| typesetting | INTEGER NULL | `BodyTypesetting` (v3): 0 = plain, 1 = unstyled, 2 = styled (fixed codes; an unknown code reads as styled). NULL for bodies stored before v3 until the engine backfills them; meanwhile a NULL body whose `rendered_html` begins with the plain wrapper (`<div class="ss-body ss-plain">`) renders as plain and any other as styled. See "Body design facts" |
| declares_colors | INTEGER NULL | the body sets its own background or text colour (v3). NULL = unknown: treated as true for styled bodies, false otherwise |
| covered_by_new_york | INTEGER NULL | New York draws every letter and decimal digit of `plain_text` (v3). NULL = unknown, treated as false |
| invitation_json | TEXT NULL | the calendar invitation the message carries (v15), as `CalendarInvitation` JSON, read once when the body was fetched (docs/ARCHITECTURE.md, "Calendar invitations"): method (`request`, `cancel`), UID, SEQUENCE, RECURRENCE-ID, DTSTAMP (`stamp`, which orders two revisions with the same SEQUENCE; absent for Microsoft's and in older rows, which reads as unknown), title, start and end (Foundation's default JSON dates, seconds since 2001; an all-day or floating event's held as its wall clock read as UTC), all-day and floating flags, the event's zone (IANA, or a fixed offset such as `GMT+0100`), location, meeting link, organizer, attendees with their answers, the repeat rule as words, the user's attendee address, whether the account answers it unnamed (`answersAsAccount`: a Graph event, or an invitation to a group; absent in older rows, which reads as no), their answer as stated, whether they organized it, Graph's event id, and the calendar text Open in Calendar hands over. NULL for every other body, for bodies stored before v15 (until fetched again) and for an evicted body (its calendar text is source). A value a later build cannot decode reads as none, never as a failed body |
| evicted | INTEGER NOT NULL DEFAULT 0 | 1 when the body was evicted for Keep mail on this Mac (v10, docs/ARCHITECTURE.md "Storage bounds"): `html`, `text` and `invitation_json` are NULL and `rendered_html` an empty blob (the column is NOT NULL since v1); `plain_text`, `attachments_json`, the facts above and the full-text row stay, so the list, snippets and search are unchanged, and `attachments(of:)` still answers the attachment list. The row and `messages.has_body` stay too, so `messageIDsMissingBodies` never returns it; `body(for:)` answers nil, so opening the message fetches it, and `saveBody` writes it whole with 0. Set by `evictBodies` (a read picks the candidates, oldest first, as a range on `messages_by_date` that starts at the date the sweep's previous batch reached; one write per batch evicts them, checking every rule, the cutoff and the kept messages again) for messages whose `date_ms` is before the cutoff, never for drafts (the drafts role) or messages a pending, in-flight or uncertain operation targets; and by `saveBody(_:for:evictingIfReceivedBefore:)`, the backfill's save, which writes a body those rules would take straight in this form (its source never written) |

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
| failed_op_kind | TEXT NULL | `OperationKind` raw value of the newest failed operation on the conversation the user has not seen (v5): `archive`, `moveToInbox`, `markRead`, `markUnread`, `star`, `unstar`, `trash`, `restoreFromTrash`, `answerInvitation` (v15's builds; `unsubscribe` is never one). Not derived from the messages: kept by the operation writes (see "Failed-operation mark") and carried over by every summary refresh |
| returned_at | INTEGER NULL | when a snooze brought the conversation back to the Inbox (v11, see "Snoozes"), written by `returnDueSnoozes` once the move has put it back, and put back by `setSnoozes` for an undo (`Snooze.Change.returnedAt`). Not derived from the messages: every summary refresh carries it over only while the conversation is in the Inbox and the value is later than `latest_date_ms`, so leaving the Inbox or newer mail ends it and reading it does not. The Inbox sorts, pages and groups by `COALESCE(returned_at, latest_date_ms)` (`ConversationSummary.inboxDate`), and the row shows a Back tag while it is set and the conversation is unread |
| muted | INTEGER NOT NULL DEFAULT 0 | 1 while the user has muted the conversation with M (v16, see "Arrival rules"), written only by `setMuted` and carried over by every summary refresh, so it lasts as long as the summary row: a conversation with no message left outside Spam, or a wipe, loses it, and one that comes back starts unmuted. Local: never read from or sent to the provider (Gmail's mute is not in its API); what it does is the ordinary archive, which round-trips. `ConversationSummary.isMuted`; the row draws the muted glyph |

Indexes: `conversations_inbox (in_inbox, COALESCE(returned_at, latest_date_ms) DESC)` (v11; `(in_inbox, latest_date_ms DESC)` before), `(is_starred, latest_date_ms DESC)`, `(in_sent, latest_date_ms DESC)`, `(latest_date_ms DESC)`, `(account_id, latest_date_ms DESC)`, and the partial `conversations_muted (account_id) WHERE muted = 1` (v16), which holds only muted rows: an upsert asks it once which accounts have anything muted. The Inbox query spells the expression exactly as the index does, which is what lets SQLite read it in index order.

After `upsertMessages` or `deleteMessages`, recompute the summary row for every touched conversation with one aggregate query per batch (`GROUP BY conversation_provider_id`). Delete the summary row when a conversation has no messages left.

### message_fts (FTS5, external content = bodies/messages)
Columns (v12): `subject`; `sender`, the From name and address; `recipients`, every To, Cc and Bcc name and address; `body`, `bodies.plain_text` (kept when a body is evicted), or `messages.snippet` while the message has no body row (v13), so metadata alone (the first download's, a search of the server's) is searchable by the words the provider showed for it. Before v12 one `participants` column held the From, To and Cc names and addresses (no Bcc). The content table is the view `message_fts_content` over `messages` LEFT JOIN `bodies`, which builds `sender` and `recipients` from the address JSON (recursive CTEs, since FTS5 reads the view with virtual tables disallowed). Tokenizer `unicode61 remove_diacritics 2`. `rowid` = `messages.rowid`. Maintained by the store on upsert (only when the subject, From, To, Cc, Bcc or snippet changed: `MessageTable.IndexedFields`, which must name every column the view reads, since FTS5 removes an entry only with the values it was indexed with), on every body save (whole or already evicted) and on delete, each bracketed by a delete of the old entry and an insert of the new from the same view (no triggers, so inserts stay in the same transaction and remain explainable). An eviction leaves the entry alone.

A search (docs/ARCHITECTURE.md "Search") matches one MATCH expression per message: words across every column, `from:` in `sender`, `to:` in `recipients`, `subject:` in `subject`, the negated ones after NOT. The matching messages become conversation keys through a scan of the covering index `messages_by_conversation`, joined to `conversations`, where the other operators are predicates on the summary row (`unread_count`, `is_starred`, `has_attachments`, `latest_date_ms`, the view flags); results order by `latest_date_ms`, an `in:inbox` search's too (its rows show their latest message's date, not a return's). The conversations a search of the server found (`ConversationQuery.serverMatches`, docs/ARCHITECTURE.md "Server search") are a second test in the same scan, on the key itself, so they join the hits whatever their stored text holds and the predicates, the order and the paging apply to them alike.

### operations
| column | type | notes |
|---|---|---|
| id | TEXT PK | |
| account_id | TEXT | |
| change_json | TEXT | `MetadataChange`. `unsubscribe` carries its method and URI (`UnsubscribeMethod`: a one-click POST or a mailto request); it changes no message, is never sent to the provider as a change, and is never written as `failed` (a refused or given-up request is deleted), so it never sets `conversations.failed_op_kind`. An invitation answer (`answerInvitation`) carries its `InvitationAnswer`: the answer, the one it replaced on this Mac, the facts a provider answers with (UID, SEQUENCE, RECURRENCE-ID, times, organizer, the user's attendee address, Graph's event id), and its reply id, made when the user answered, which Gmail's reply Message-ID is built from. The runner rewrites the replaced answer when it drops answers a newer one replaces, and a give-up rewrites it on the live answers queued after the given-up one on its message (docs/ARCHITECTURE.md, "Calendar invitations") |
| targets_json | TEXT | `[provider_id]`; empty for an `unsubscribe` operation, which therefore has no `operation_targets` rows, holds back no other operation and is not "pending operations win" state |
| created_at | INTEGER | |
| status | TEXT | pending / inFlight / confirmed / failed / uncertain |
| attempts | INTEGER | |
| last_error | TEXT NULL | |
| next_attempt_at | INTEGER NULL | next try of a pending or uncertain row. A failed row is never tried again, so for it the column holds its expiry: the runner sets failure time + 24 h (`SyncTuning.failedOperationRetention`) when it gives up, and `pruneFailedOperations` deletes failed rows at or past it (or with none) |

### operation_targets
`(operation_id, account_id, provider_id)` so "pending operations win" can find operations for a message with one indexed lookup.

| column | type | notes |
|---|---|---|
| operation_id, account_id, provider_id | PK | FK operations (cascade) |
| prior_roles, prior_is_read, prior_is_starred | INTEGER NULL | what the operation's change replaced on this target (v6), in the encoding of `messages.roles`, `is_read`, `is_starred`. Written at enqueue (the message as it was) and rewritten by every upsert that replays the operation (the provider's report with the older live operations applied), so it follows the provider. A give-up puts it back (see "Failed operations"). NULL when the target was not known at enqueue and no poll has reported it since, and for operations queued before v6 |

Target rows are kept when an operation is saved again with the same targets, so the priors survive status writes.

### pending_sends
`id TEXT PK, account_id, message_json (OutgoingMessage, attachments inline as base64), created_at, send_after, status, attempts, last_error`. Only `observePendingSends` (the sync line's sending count) observes it; no list observation reads it.

### contacts
`account_id, address (PK with account_id), name, seen_count, last_seen_ms`. Updated from from/to/cc on upsert. Suggestions order by `seen_count * recency`.

### backfill_live_marks (v8)
Sync bookkeeping for the two lanes (v8, see "Backfill marks"). No observation reads it.

| column | type | notes |
|---|---|---|
| account_id | TEXT | FK accounts (cascade) |
| provider_id | TEXT | a message the live lane wrote or deleted while the account's backfill runs. Not a foreign key: a deleted message, or one the backfill has not reached, is not stored |
| deleted | INTEGER NOT NULL DEFAULT 0 | 1 when the live lane's latest change deleted the message, 0 when it wrote it. A later mark replaces the flag |
| PRIMARY KEY (account_id, provider_id) | | `WITHOUT ROWID` |

### backfill_seen (v8)
The ids a reconciling backfill's listing has returned (v8, see "Backfill marks"). No observation reads it.

| column | type | notes |
|---|---|---|
| account_id | TEXT | FK accounts (cascade) |
| provider_id | TEXT | not a foreign key, like `backfill_live_marks.provider_id` |
| PRIMARY KEY (account_id, provider_id) | | `WITHOUT ROWID` |

### snoozes (v11)
Later's timer (spec §5.45, see "Snoozes"). One row per snoozed conversation. `MailStoring.observeSnoozes` observes it, joined to `conversations`, for the Later tile.

| column | type | notes |
|---|---|---|
| account_id | TEXT | FK accounts (cascade): removing the account removes its snoozes |
| provider_id | TEXT | the conversation's provider id (`conversations.provider_id`). Not a foreign key: the summary row comes and goes with the messages (a wipe drops it), and the snooze is the user's intent, kept like a queued operation |
| due_at | INTEGER | when it comes back: an instant, chosen as a local time when it was snoozed |
| created_at | INTEGER | when it was snoozed or last rescheduled; mail received after this ends it |
| PRIMARY KEY (account_id, provider_id) | | a rowid table, unlike the backfill marks: SQLite reports no row changes of a `WITHOUT ROWID` table, which the observation needs |

Index: `snoozes_by_due (due_at)`, for the runner's due read.

### sender_rules (v17)
The two sender rules (roadmap Q4.2, see "Arrival rules"): one row per account and address. `MailStoring.observeSenderRules` observes it for Settings › Accounts › Senders….

| column | type | notes |
|---|---|---|
| account_id | TEXT | FK accounts (cascade): removing the account removes its rules. A wipe keeps them |
| address | TEXT | the sender's address trimmed and lowercased (`SenderRule.normalizedAddress`), matched against a message's From address the same way; nothing else is folded (Gmail's dots and +tags name other senders) |
| action | TEXT | `archive` (“Always Archive Mail from This Sender”) or `trash` (“Block Sender”), `SenderRule.Action` raw values; never rename them. A row with an action a build does not know is left out of the list and takes nothing |
| created_at | INTEGER | when it was set, or last changed to the other action |
| PRIMARY KEY (account_id, address) | | one rule per sender: setting the other replaces it. The upsert's lookup is a probe of this key. A rowid table, so the Senders sheet can observe it |

### Body design facts
Worked out once by `HTMLSanitizer` at sync time and stored with the body, so the reader never scans HTML to decide how to set a message (docs/DESIGN-LANGUAGE.md §8.4, §8.5). The render payload carries them per message (`typesetting` as its name, `declaresColors`, `coveredByNewYork`, next to `hasBody`) together with the conversation account's `inkSlot`.
- **typesetting**: `plain` when the body came from the text/plain part (no HTML part, a blank one, or one that failed to parse). `unstyled` for HTML with no author styling: no `style` attribute, body style or `<style>` element (after filtering) declaring anything beyond the neutral text-flow and spacing properties (`margin*`, `padding*`, `border*`, `direction`, `unicode-bidi`, `text-align`, `word-wrap`, `overflow-wrap`, `word-break`, `white-space`, `line-break`, `-webkit-line-break`, `-webkit-nbsp-mode`, `caret-color`, `*text-size-adjust`, plus `width`, `height`, `max-width`, `max-height` in a `style` attribute on `<img>`), so Fastmail's `<style>p.MsoNormal,p.MsoNoSpacing{margin:0}</style>` and Outlook on the web's `P {margin-top:0;margin-bottom:0;}` leave a body unstyled; no colour (so unstyled never declares colours); no `<font>` with `face` or `size`; no layout table (a `<table>` with `width`, `height`, `align`, `bgcolor`, `background`, `cellpadding`, `cellspacing` or `role="presentation"`, or a table inside a table). `styled` for every other HTML body.
- **declares_colors**: true when any of these appears: a `color`, `-webkit-text-fill-color`, `background`, `background-color` or `background-image` declaration in a `style` attribute or a `<style>` block whose whole value is not a no-colour keyword (`inherit`, `initial`, `unset`, `revert`, `revert-layer`, `currentcolor`, `transparent`, `none`); a non-empty `bgcolor` or `background` attribute on any element; a non-empty `color` attribute on `<font>`; a non-empty `text` or `link` attribute on `<body>`. A blocked remote background still counts. Plain bodies never declare colours. The reader's dark adaptation must override every property in this list (including `-webkit-text-fill-color`, which WebKit paints text with over `color`).
- **Backfill**: bodies stored before v3 have NULL facts. After each hydration batch the engine takes up to 200 of them for the account (`messageIDsMissingDesignFacts`, served by the partial index `bodies_missing_design_facts`; evicted bodies are left out, having no source left, and get their facts when fetched again), runs `HTMLSanitizer` again over the stored `html`/`text` on a background task, and writes only the three facts in one transaction (`saveDesignFacts`); rendered HTML, plain text and the full-text row are left as they are. A row it cannot read gets the reader's own assumption (styled, colours declared, not covered) so it leaves the queue. Once an account has none left the engine stops asking until the next launch.
- **covered_by_new_york**: every letter (Unicode L*) and decimal digit (Nd) of the extracted text is in New York's character set; punctuation, symbols, emoji (by the Unicode Emoji property, so U+2139 ℹ️, a lowercase letter by category, is ignored too) and marks are ignored because they fall back to the same system fonts beside either face. The character set is a range table in `Render/NewYorkCoverage.swift`, measured with `CTFontCopyCharacterSet` by `scripts/tools/newyork-coverage.swift`.

### attachment_cache (file system, not SQL)
`~/Library/Caches/SuperSparrow/attachments/<account>/<message>/<attachmentID>`; inline images keyed by content id. Each path component keeps letters, digits, `-` and `_` and percent-encodes the rest (a SHA-256 in hex when that runs past 180 characters), so an entry's name never holds a dot. A download streams into `.partial/<UUID>.partial` under the cache's root (a name no account folder can have, on the same volume) and is renamed into place once complete, so a download that fails or stops never leaves a truncated entry. Gmail writes its JSON reply beside the partial file, as `<UUID>.partial.reply`, until it is decoded. Both are removed when the download ends, however it ends; what a run cut off by quitting or a crash leaves in `.partial` is deleted before the next run's first download. The cache holds at most 1 GB on disk (`AttachmentCache.capacityBytes`): past it, entries go least recently used first by modification date, which the cache sets to now whenever it serves an entry; it trims when the engine starts and after a download that takes it past the cap, and never touches `.partial`, an entry a download in flight will read back, the entry just downloaded, or the message folder a download in flight will rename its entry into.

## Migrations
Applied in order by GRDB's `DatabaseMigrator`; a migration is never edited once released.
- `v1-mailbox`: the tables above as first released, except `backfill_live_marks` and `backfill_seen` (v8), `snoozes` (v11) and `sender_rules` (v17).
- `v2-body-render-facts`: `bodies.has_quoted`, `bodies.blocked_images`.
- `v3-body-typesetting`: `bodies.typesetting`, `bodies.declares_colors`, `bodies.covered_by_new_york` (existing bodies stay NULL).
- `v4-account-ink`: `accounts.ink_slot` (backfilled in creation order), `accounts.monogram`.
- `v5-failed-operation-mark`: `conversations.failed_op_kind`.
- `v6-operation-priors`: `operation_targets.prior_roles`, `prior_is_read`, `prior_is_starred` (existing rows stay NULL).
- `v7-body-design-facts-backfill`: the partial index `bodies_missing_design_facts ON bodies(account_id) WHERE typesetting IS NULL`, for the design-facts backfill.
- `v8-backfill-marks`: the tables `backfill_live_marks` and `backfill_seen` (empty at first), for the two sync lanes (see "Backfill marks").
- `v9-account-signature`: `accounts.signature` (NULL for every existing account).
- `v10-body-eviction`: `bodies.evicted` (0 for every existing body). It does not change `auto_vacuum` (see "The file"). From this version the backfill stores bodies outside the Keep mail window already evicted, so a file migrated from v9 grows only by their plain text and index entries from then on, though it keeps whatever size it had already reached.
- `v11-snoozes`: the table `snoozes` (empty at first), `conversations.returned_at` (NULL for every existing row), and `conversations_inbox` rebuilt on `(in_inbox, COALESCE(returned_at, latest_date_ms) DESC)`, which orders every existing row as before (its `returned_at` is NULL).
- `v12-search-columns`: `message_fts` and its view `message_fts_content` dropped and created again with `sender` and `recipients` in place of `participants`, then rebuilt from the stored rows (`'rebuild'`), in the migration's transaction, once, at the first launch of a build that has it: about 1.3 s for the 100,000-message fixture (`SearchOperatorPerformanceTests`), during which the store does not open. Bcc names and addresses are indexed from then on, old mail included.
- `v13-server-search`: `message_fts_content.body` falls back to `messages.snippet` for a message with no body row. Only those messages are re-indexed (their old entries deleted through the old view, then inserted through the new one); `message_fts` is renamed aside while the view is replaced, since FTS5 reserves the name `message_fts_content` for a shadow table while the index exists, so no other entry is rebuilt. The new view follows the index in the schema, so SQLite now reads it as one of the index's shadow tables and, defensive by default on macOS, will not drop it while the index has its name: a later migration that replaces the view renames the index aside first, as v13 does.
- `v14-list-unsubscribe`: `messages.list_unsubscribe`, `messages.list_unsubscribe_post` (NULL for every existing message; no backfill: a message gets them when its metadata or body is fetched again).
- `v15-calendar-invitations`: `bodies.invitation_json` and `messages.invitation_reply`, NULL for every existing row.
- `v16-conversation-mute`: `conversations.muted` (0 for every existing row) and the partial index `conversations_muted`.
- `v17-sender-rules`: the table `sender_rules` (empty at first).

## Semantics

- **Unified inbox** = `SELECT … FROM conversations WHERE in_inbox = 1 [AND account_id IN (…)] [AND inbox_section = 'focused'] [AND unread_count > 0] ORDER BY COALESCE(returned_at, latest_date_ms) DESC LIMIT ?`. Paging uses `COALESCE(returned_at, latest_date_ms) < ?`. Every other view orders and pages by `latest_date_ms`.
- **Later** = `SELECT … FROM conversations JOIN snoozes USING the conversation key [WHERE account_id IN (…)] ORDER BY due_at, account_id, provider_id LIMIT ?`, never paged; the rows carry `due_at` as `ConversationSummary.snoozedUntil`.
- **All mail** = `message_count > 0 AND in_trash = 0`. **Trash** = `in_trash = 1`. **Starred** = `is_starred = 1 AND in_trash = 0`.
- **Pending operations win**: on upsert, for every incoming message that has rows in `operation_targets` with status pending/inFlight/uncertain, re-apply those operations' changes (oldest first, by `created_at` then `id`) on top of the incoming metadata before writing it, recording on each target row the state that operation's change now replaces (`prior_*`).
- **Confirmed operations** are deleted together with their targets (`confirmOperation`), keeping their local change. An uncertain operation a poll settles is deleted (`deleteOperation`) without being confirmed: the provider's report that follows is the truth either way. An invitation's answer is never settled so, since no report shows it.
- **Failed operations** stop winning (their changes are no longer re-applied on upsert) and are never replayed. Giving one up (writing a pending, in-flight or uncertain operation as `failed`) puts back what it changed, in the same transaction: each target with a recorded prior takes the prior's roles, read and starred flags, the live operations created after it on that target are replayed on top (and their priors move to that restored state), and the conversations are refreshed, so a failed archive is back in the inbox (docs/DESIGN-LANGUAGE.md §5.7, "the row is restored locally"). Live operations created before it are already part of its prior. A prior refreshed by a poll after the change landed already shows the change, so a request that landed despite reporting failure stays applied. Targets without a prior, or no longer stored, are left as they are. The outbox prunes failed operations at the start of every drain once `next_attempt_at` has passed, one indexed lookup on `(account_id, status, created_at)`.
- **Failed-operation mark** (`conversations.failed_op_kind`, `ConversationSummary.failedOperation`, docs/DESIGN-LANGUAGE.md §5.7, §8.5). Both stores apply the same rules, inside the transaction of the write that triggers them. "An operation targets a conversation" means one of its targets is currently a message of that conversation; "newer" compares `created_at`, then `id`.
  - *Set*: writing an operation as `failed` from any other status (or inserting it failed) sets the mark of every conversation it targets to its kind, unless that conversation already carries a mark and a failed operation newer than this one also targets it (the mark names the newest failure). Writing an already failed row again changes nothing.
  - *Acknowledged*: `acknowledgeFailedOperation(conversationID:)` sets it to NULL and leaves the failed row in place. It is for the app to call once a conversation has been open for 150 ms (wired by the list stage); the SQLite store checks for a mark with a read first, so the common case never takes the writer.
  - *Confirmed*: confirming an operation (`confirmOperation`, or writing it as `confirmed`) clears the mark of every conversation it targets, unless a failed operation newer than it still targets that conversation. So a later operation that succeeds clears an older failure and an earlier one does not.
  - *Failure ended*: deleting a failed operation (how pruning removes it) or writing it out of `failed` clears the mark of every conversation it targets, unless another failed operation still targets that conversation. Every failure is kept for the same retention, so failures expire in the order they gave up: one still standing gave up after the expired one, and if the conversation carries a mark at all, after the last acknowledgement, so its mark stays. This holds whatever order operations on different messages of one conversation give up in (the runner orders operations only per message).
  - *Dropped*: deleting a live operation (`deleteOperation`, as a poll does with an uncertain one it has settled) changes no mark: it was never confirmed.
  - The mark lives on the summary row: a conversation with no summary row (every message spam, or none left) cannot be marked, and loses its mark when the row goes.
  - Known limits: the schema keeps no per-operation acknowledgement and no failure time, so where the rules compare a failure with another operation they use creation order. The kind shown is that of the newest failure by creation, not the last to give up. A confirmation clears the mark of every failure created before it, including one that gave up only after the confirmed operation was queued. The failure-ended rule assumes one retention for every failure; after a build shortens `SyncTuning.failedOperationRetention`, a mark can stay until the failures recorded under the longer retention expire. Writing a failed row back to pending (nothing does today) is not ordered by give-up time, so it can keep a mark the same way.
- **Backfill marks** (`backfill_live_marks`, `backfill_seen`). Each account syncs in two lanes: the live lane owns the change cursor and applies changes as they arrive, and the backfill lane downloads older mail behind it, paced by the provider's quota. A backfill page can therefore be fetched before a live change and written after it. Both stores apply these rules, each call in one transaction:
  - *Live marks*: while a backfill runs, the engine marks every message the live lane writes or deletes (`markLiveChanges`), and marks it before the `upsertMessages` / `deleteMessages` that applies the change, never after. The mark is its own transaction, so only a mark that commits first closes the window in which a backfill write or sweep could run between the live write and its mark: marked after, a stale page could bring back a just-deleted message or overwrite a newer one, and a sweep could delete mail that just arrived (the cursor has already moved past it). A mark whose live write then fails is harmless: the backfill skips that message, and the live lane writes it when it retries the page, because the cursor moves only after the write. A later mark replaces an earlier one's `deleted` flag; within one call an id both written and deleted is marked deleted, the order a changes page is applied in (upserts, then deletions).
  - *Backfill writes only add*: `writeBackfillMessages` drops every message that has a live mark and, unless it is refreshing (a reconcile, below), every message already stored, then writes the rest through the same path as `upsertMessages` (full-text rows, conversation summaries, contacts, "Pending operations win"). The mark check and the write share the transaction, so a live change marked before it is written either is marked by the time the page checks (and is skipped) or is written after the page, waiting for its transaction, and overwrites it. This is why the marks exist: a page fetched before a live change must neither overwrite it (undo a read, an archive, a new label) nor bring back a message the live lane deleted. A repeated id in one page is written once, as its last copy. `backfillSkippableIDs` answers the same question before the backfill fetches metadata, so quota goes only to messages it will write; it is advisory and the write checks again. A search of the server (docs/ARCHITECTURE.md, "Server search") writes its hits through the same two calls, never refreshing: a hit already stored changes nothing, and one the live lane deleted while a backfill runs is not brought back. It needs no table of its own: what it found is an ordinary message row, indexed by its snippet until its body arrives, and the list names its conversations in the query (`ConversationQuery.serverMatches`), not in the store.
  - *Reconcile*: a rejected change cursor no longer wipes the mailbox. The live lane takes a fresh cursor and the newest page, and a reconciling backfill (`BootstrapState.reconciling`) lists the whole mailbox again, refreshing stored messages (`refreshExisting`, marked ones still skipped) and recording every id it lists in `backfill_seen` (`markBackfillSeen`).
  - *Finish*: `finishBackfill` ends the account's backfill. After a reconcile that listed everything (`sweepUnseen`), it first deletes the account's messages whose id is in neither table and that no live (pending, in-flight or uncertain) operation targets (a message the live lane writes is marked before it is stored, so the sweep never sees it unmarked), through the message delete so the full-text index and conversation summaries follow: the provider no longer has them, and this removes them without wiping the mailbox. A message a live operation targets stays, since the store cannot tell whether the provider still has it; the engine asks the provider about those targets just before the sweep (`metadata(for:)`) and deletes the ones it no longer has, because a deletion in the gap the reset covers sat in the expired history, so neither a later poll nor the operation's outcome would ever remove them. Then it deletes all of the account's rows in both tables, so marks only ever describe the backfill that is running.
  - `wipeMailData` clears both tables for the account; deleting the account removes them (the wipe, and the foreign keys).
  - No observation reads either table, so a mark never wakes the list.
- **Snoozes** (`snoozes`, `conversations.returned_at`, spec §5.45). Both stores apply these rules, each call in one transaction:
  - *Snoozing*: `setSnoozes(_:enqueueing:at:)` applies and queues its operations as `enqueue` does (the window passes the archive of whatever is in the Inbox; an unsubscribe of a snoozed conversation, its request with the snooze's end), then writes each change: a date inserts the snooze or replaces its time and `created_at` (a reschedule), nil deletes it, and a `returnedAt` (an undo of the Archive, Move to Trash or snooze that took a conversation back from Later out of the Inbox) sets `returned_at` to it where the conversation is now in the Inbox and its newest mail is older, the rule the refresh keeps the mark by. A date is written only for a conversation that has a summary row with `in_inbox = 0` and `in_trash = 0` once the operations are applied, and whose messages other than the user's own copies (outside the Inbox, with the sent or drafts role) and Spam are not all in the Trash, so a snooze always stands for mail put away (`Snooze.canHold` states the rule in Swift; the in-memory store uses it, and the window asks it of its selection as snoozing would leave it, so L beeps rather than toast a snooze that would be dropped). That last rule is for Microsoft, where Move to Trash leaves those copies in Sent Items and Drafts, so `in_trash` stays 0.
  - *Returning*: `returnDueSnoozes(at:dueBy:limit:operations:)` takes the snoozes due by `now`, soonest first, and for an account in `dueBy` only those due by its date (the engine holds back a time the account has not checked for mail past yet, docs/ARCHITECTURE.md "Later"; the batch is counted after those are left out); for each it deletes the row, reads the conversation's messages (oldest first), applies and queues the operations the caller makes from them (the engine: move to the Inbox the messages that are not in the Trash or Spam, on Microsoft leaving the user's own copies in Sent Items and Drafts as Move to Inbox does, and mark the latest of those unread, a millisecond later so the outbox replays them in that order), and, after all of them, sets `returned_at = now` where the conversation is now in the Inbox and its newest mail is older. A due snooze whose conversation has no messages left is just deleted. A read checks first whether anything is due, so a look with nothing due never takes the writer.
  - *Ending early*: every summary refresh deletes the snooze of each touched conversation that is back in the Inbox (⇧I, a drop, another device reporting it there, new mail delivered to the Inbox, a given-up archive), in the Trash (on Microsoft, everything but the user's own copies: the rule `setSnoozes` writes by), or gone (no message outside Spam). And an upsert of a message new to the store deletes its conversation's snooze when `created_at` is before the message's date, unless the message is the user's own (sent, a draft) or spam: mail from someone else ends a snooze even when a provider rule keeps it out of the Inbox, and older mail the backfill lists does not.
  - *The return mark*: a refresh carries `returned_at` over only while the conversation is in the Inbox and the value is later than its newest mail; the summary row going (no messages) takes it too.
  - `wipeMailData` keeps the snoozes (the user's intent, like queued operations) and drops the summary rows with their marks; `snoozes()` and its observation join `conversations`, so a snooze whose mail is gone stays out of sight until the mail is back. Deleting the account removes them (the foreign key; the in-memory store mirrors it).
- **Arrival rules** (`conversations.muted`, `sender_rules`; roadmap Q3.7 Mute and Q4.2 Sender rules). Mail new to the store (no row for its id yet) in a muted conversation, or from a sender the account has a rule for, is archived or moved to the Trash in the transaction that stores it, through the ordinary operation queued in that same transaction, as "Pending operations win" replays live ones: no observer sees the row in the Inbox, and the outbox replays the change so every device agrees once it lands. Both stores apply these rules (`ArrivalRules`, `ArrivalRule.change`):
  - *Which change*: on the message as stored (the provider's report with older live operations replayed), spam is left alone; a `trash` rule moves to the Trash anything not there already, never the user's own sent mail or drafts; otherwise, in the Inbox, the mute or an `archive` rule (again never the user's own mail) archives it. Block wins over the mute.
  - *Which messages*: a sender rule takes only the arriving message; the mute takes every message of the conversation in the Inbox (and not in the Trash or Spam), older ones too, so a muted conversation moved back to the Inbox (⇧I, another device) leaves it again with its next mail. Per account one Archive operation and one Move to Trash a millisecond later, created now.
  - *Which writes*: `upsertMessages` (a poll's changes, a head page) applies both; `writeBackfillMessages` (the backfill, a search of the server) applies only the mute, since its mail is old, not arriving. A report of a message already stored is never an arrival, so a rule never fires twice and a given-up archive is not redone.
  - *Priors*: the messages are written as reported first, then the operations are enqueued as a user action is, so each target's prior is the provider's report and a give-up puts the message back where the provider has it.
  - *Cost*: once per write, the accounts with anything muted (the partial index) and with any rule (a handful of rows); then, only for mail new to the store in those accounts, one primary-key probe of `conversations` and of `sender_rules`. A write with neither costs two small reads.
  - `setMuted(_:conversations:enqueueing:)` and `setSenderRule(_:for:accountID:enqueueing:at:)` apply and queue their operations as `enqueue` does (muting archives what is in the Inbox; a rule takes its sender's mail where it was set from), then write the flag or the rule, in one transaction.
- **Invitation answers** (`messages.invitation_reply`). Enqueueing an `answerInvitation` operation writes the answer on its target in the same transaction (`applying` sets it; the flags write carries it). Upserts leave the column alone, so the recorded answer stands through every poll, live operation or not; replaying live operations on an upsert re-applies a live answer, which changes nothing stored. Giving one up puts back the answer its change says it replaced, then replays the live operations created after it on that target, so a newer answer still wins; each newer live answer is rewritten in the same transaction to name the answer in place before it in that replay (the one the given-up answer replaced, for the first), since the given-up one never went out and a later give-up must not put it back. Confirming or deleting it keeps the answer. The runner deletes an answer a newer answer on the same message replaces, before anything is sent, after saving the newer one with the answer the first replaced one replaced; it deletes the newer one too when nothing deleted was ever tried and it repeats that answer.
- **Conversation key** is the provider's thread id scoped to the account. Never re-thread across accounts.
