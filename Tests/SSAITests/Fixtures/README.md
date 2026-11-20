# SSAITests fixtures

Recorded on 2026-11-20 against the real CLIs and the OpenAI API, with the prompt `Reply with exactly: Thanks,
Thursday works.` No mail and no personal data was sent. Read them with `FixtureFiles.data("cli/claude-stream.jsonl")`.

Redacted before they were committed: home paths (`/Users/someone`), the run folders, session, message, request and
thread ids and every UUID (replaced by `00000000-0000-4000-8000-0000000000NN`, consistent within a file), Cloudflare
ray ids. The account's email, organisation id and name were redacted at capture (`<redacted>`).
`FixturePrivacyTests` fails if an address, a user's home path or a real-looking id comes back.

## cli/ (Claude Code 2.1.322, Codex 0.163.0)

| File | What it is |
|---|---|
| `claude-stream.jsonl` | A successful `claude -p --output-format stream-json --verbose --include-partial-messages --model haiku …` run (recipe in SPEC §4b): 13 lines; text arrives as two `text_delta`s, then repeated whole by `assistant` and `result.result`. Exit 0, stderr empty. First delta at 0.919 s, exit at 1.152 s. |
| `claude-bad-model.jsonl` | The same with `--model not-a-real-model-xyz`: synthetic `assistant` line with `"error":"model_not_found"`, `api_error_status: 404`; `result` with `subtype:"success"` but `is_error:true`, `terminal_reason:"api_error"`. Exit 1. |
| `claude-bad-model.stderr.txt` | Its stderr. |
| `claude-signed-out.jsonl` | The recipe without `USER` in the environment (how "signed out" was reproduced): synthetic `assistant` line with `"error":"authentication_failed"` and the text `Not logged in · Please run /login`; `result` `is_error:true`, `api_error_status:null`. Exit 1, stderr empty, no model call. |
| `claude-auth-status.json` | `claude auth status` signed in (exit 0). Never log its `email`/`org*` fields. |
| `claude-auth-status-signed-out.json` | `claude auth status` signed out (exit 1). |
| `codex-exec-signed-out.jsonl` | `codex exec --json …` (recipe in cli.md §C.2) while signed out: `thread.started`, `turn.started`, transient top-level `error` retry notices, an `item.completed` with `item.type:"error"`, then terminal `turn.failed`. Exit 1 after 16.99 s. Success shapes (`agent_message`, `turn.completed`) were not capturable: write those fixtures by hand from the documented schema and name them `*-synthetic.jsonl`. |
| `codex-exec-signed-out.stderr.txt` | Its stderr (seven 401 lines). |
| `codex-login-status-signed-out.stderr.txt` | `codex login status` signed out: this on stderr, stdout empty, exit 1. Signed in is exit 0. |
| `codex-exec-synthetic.jsonl` | **Synthetic** (written by hand from the documented `exec --json` schema; not recorded, Codex was signed out): a successful run, `thread.started`, `turn.started`, a `reasoning` item, the `agent_message` item with the whole reply, `turn.completed` with usage. Re-capture once signed in. |
| `codex-exec-usage-limit-synthetic.jsonl` | **Synthetic**: the ChatGPT plan's limit, a top-level `error` notice then `turn.failed` with “You've hit your usage limit…”. Exit 1. |
| `codex-features-list-synthetic.txt` | **Synthetic**: `codex features list` (`name  stage  effective`) with the 0.163.0 feature names cli.md §C.1 lists. |

## openai/ (live, unauthenticated probes)

| File | What it is |
|---|---|
| `401-missing-key.json` | `GET /v1/models` with no `Authorization`: HTTP 401, `application/json`. |
| `401-invalid-key.json` | `GET /v1/models` with a fake key: HTTP 401, `code: "invalid_api_key"`. |
| `401-invalid-key-stream.txt` | `POST /v1/responses` with `stream: true` and a fake key: HTTP 401 with `content-type: text/plain` (not SSE), JSON body with an extra `status` field. |

No Anthropic responses were recorded (no key on this Mac): the API track writes its SSE fixtures from the documented
event shapes and names them `anthropic/*-synthetic.*`.
