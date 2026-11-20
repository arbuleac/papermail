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

## openai/ (live, unauthenticated probes; the streams and other errors synthetic)

| File | What it is |
|---|---|
| `401-missing-key.json` | `GET /v1/models` with no `Authorization`: HTTP 401, `application/json`. |
| `401-invalid-key.json` | `GET /v1/models` with a fake key: HTTP 401, `code: "invalid_api_key"`. |
| `401-invalid-key-stream.txt` | `POST /v1/responses` with `stream: true` and a fake key: HTTP 401 with `content-type: text/plain` (not SSE), JSON body with an extra `status` field. |
| `stream-text-synthetic.sse` | Synthetic (from the documented stream, openai.md §2): a reasoning item first, three `response.output_text.delta`s, a `:` comment, `output_text.done` repeating the text, `response.completed` with usage and `store: false`. |
| `stream-refusal-synthetic.sse` | Synthetic: a `refusal` content part (`response.refusal.delta`/`.done`, words marked `SENTINEL-REFUSAL-WORDS` so tests can prove they never reach the field). |
| `stream-incomplete-synthetic.sse` | Synthetic: partial text, then `response.incomplete` with `incomplete_details.reason: "max_output_tokens"`. |
| `stream-failed-synthetic.sse` | Synthetic: `response.failed` with `error.code: "server_error"` before any text (retried once). |
| `stream-error-after-text-synthetic.sse` | Synthetic: one delta, then a top-level `error` event (never retried after text). |
| `error-429-insufficient-quota-synthetic.json`, `error-429-spend-limit-synthetic.json`, `error-429-rate-limit-synthetic.json`, `error-400-model-not-found-synthetic.json`, `error-400-invalid-request-synthetic.json`, `error-503-overloaded-synthetic.json`, `error-500-synthetic.json` | Synthetic error bodies in the documented `{"error":{message,type,param,code}}` shape (openai.md §3); the 400 quotes `SENTINEL-REQUEST-ECHO` so tests can prove a body never reaches an error's words. |
| `models-synthetic.json` | Synthetic `GET /v1/models` list (no `gpt-6.2-astra`, for Check's “not available with this key”). |

No Anthropic responses were recorded (no key on this Mac): the API track writes its SSE fixtures from the documented
event shapes and names them `anthropic/*-synthetic.*`.

## anthropic/ (synthetic, from the documented Messages API shapes; API version 2026-10-21)

Written by hand from the event and error shapes in the claude-api skill (SPEC §4); no key was available to record.
Ids are `msg_fixtureN` / `req_fixtureN`.

| File | What it is |
|---|---|
| `stream-text-synthetic.sse` | `message_start` (usage), `ping`s, an empty `thinking` block with its `signature_delta`, a `text` block in three `text_delta`s, `message_delta` (`end_turn`, output tokens), `message_stop`. |
| `stream-fallback-synthetic.sse` | Server-side fallback mid-reply: partial text, a `fallback` block (`from`/`to` models), an empty thinking block, then a new text block that continues the text. |
| `stream-refusal-synthetic.sse` | Haiku (no fallback): partial text, then `stop_reason: "refusal"` with `stop_details`. |
| `stream-max-tokens-synthetic.sse` | Partial text, then `stop_reason: "max_tokens"`. |
| `stream-overloaded-synthetic.sse` | `event: error` `overloaded_error` before any text (retried once). |
| `stream-error-after-text-synthetic.sse` | One delta, then `event: error` `overloaded_error` (never retried after text). |
| `error-{400,401,402,403,404,413,429,500,529}-synthetic.json` | `{"type":"error","error":{type,message},"request_id"}` per status; the 400 quotes `SENTINEL-REQUEST-ECHO`. |
| `models-synthetic.json` | `GET /v1/models` page with the three 5.5 models and `has_more: false`. |
