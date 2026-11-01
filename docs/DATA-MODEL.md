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
| color_hex | TEXT | |
| added_at | INTEGER | |
| sync_cursor | TEXT NULL | provider-opaque |
| bootstrap_json | TEXT NULL | `BootstrapState` as JSON |

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
| next_attempt_at | INTEGER NULL | |

### operation_targets
`(operation_id, account_id, provider_id)` so "pending operations win" can find operations for a message with one indexed lookup.

### pending_sends
`id TEXT PK, account_id, message_json (OutgoingMessage, attachments inline as base64), created_at, send_after, status, attempts, last_error`.

### contacts
`account_id, address (PK with account_id), name, seen_count, last_seen_ms`. Updated from from/to/cc on upsert. Suggestions order by `seen_count * recency`.

### attachment_cache (file system, not SQL)
`~/Library/Caches/SuperSparrow/attachments/<account>/<message>/<attachmentID>`; inline images keyed by content id.

## Semantics

- **Unified inbox** = `SELECT … FROM conversations WHERE in_inbox = 1 [AND account_id IN (…)] [AND inbox_section = 'focused'] [AND unread_count > 0] ORDER BY latest_date_ms DESC LIMIT ?`. Paging uses `latest_date_ms < ?`.
- **All mail** = `message_count > 0 AND in_trash = 0`. **Trash** = `in_trash = 1`. **Starred** = `is_starred = 1 AND in_trash = 0`.
- **Pending operations win**: on upsert, for every incoming message that has rows in `operation_targets` with status pending/inFlight/uncertain, re-apply those operations' changes (oldest first) on top of the incoming metadata before writing it.
- **Confirmed operations** are deleted together with their targets.
- **Conversation key** is the provider's thread id scoped to the account. Never re-thread across accounts.
