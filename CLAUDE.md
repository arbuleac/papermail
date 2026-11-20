# SuperSparrow (macOS)

Native Mac mail client for Gmail and Microsoft 365/Outlook.com. Unified inbox, Superhuman-class speed, Sparrow-style simplicity. Swift Package, AppKit shell, SwiftUI only for small chrome.

Read `docs/ARCHITECTURE.md` before changing anything. `docs/DATA-MODEL.md` is the schema contract. `docs/OAUTH-SETUP.md` is the user-facing setup.

## Commands
- Build: `swift build` (debug) or `swift build -c release`
- Tests: `scripts/test.sh` (token check, then all), `swift test` or `swift test --filter SSCoreTests`
- Run the app: `scripts/run.sh` (builds, assembles `dist/SuperSparrow.app`, opens it)
- Bundle only: `scripts/build-app.sh [debug|release]`
- No Node, npm, Homebrew installs or Xcode project files. SwiftPM only. Do not add dependencies beyond GRDB, SwiftSoup and Sentry (crash reporting) without asking.

## Layout
- `Sources/SSCore` — models (`Model/`), ports (`Ports/`), SQLite store (`Store/`), sync engine (`Sync/`), OAuth + Keychain (`Auth/`), HTML sanitizer (`Render/`). No AppKit, no WebKit.
- `Sources/SSGmail` — `GmailProvider: MailProvider` over the Gmail REST API.
- `Sources/SSGraph` — `GraphProvider: MailProvider` over Microsoft Graph.
- `Sources/SSAI` — Help Me Write's providers (`AIProvider` in `SSCore/Ports`, the service `AIWriter` and the prompt in `SSCore/AI`): Anthropic and OpenAI over `URLSession`, the user's Claude Code and Codex as processes. Foundation only; the UI never calls one (it writes through `AIWriter`). Tests use fixtures, a stub `URLProtocol` and fake executables; never the network, a real CLI or the Keychain.
- `Sources/SSDesign` — the Quire design runtime (`docs/DESIGN-LANGUAGE.md`): generated tokens in `Generated/`, AppKit components in `AppKit/`, Settings controls in `SwiftUI/`. AppKit, SwiftUI and QuartzCore only; no SSCore. `docs/design/tokens.json` is the single source: after changing it run `swift scripts/tools/quire-tokens.swift` (Swift tokens, reader CSS `QuireCSS.swift`, generated tests, the accent asset; `--check` lists stale outputs) and, for the icon, `swift scripts/tools/app-icon.swift`. The tokens themselves come from `docs/design/source/` via `sh docs/design/source/make.sh`. Never edit generated files.
- `Sources/SuperSparrowApp` — the AppKit app: windows, list, conversation renderer (WebKit), composer, and the debug-only Design Gallery (`Design/`).
- `Tests/*` — XCTest. Core tests use in-memory GRDB. Provider tests use recorded JSON fixtures and a stub `URLProtocol`; never hit the network in tests. `SuperSparrowAppTests` drives the app's windows over a throwaway store (`MainWindowHarness`). `scripts/test.sh` runs the token check and the whole suite; `SS_PERF=1` and `SS_UI_TESTS=1` enable the gated benchmarks and renders.

## Rules
- Swift 5 language mode on Swift 6 toolchain. Use actors for engine state, `@MainActor` for UI. Mark shared types `Sendable`.
- The UI reads only from `MailStoring`. The UI never calls a provider.
- Every user action is applied to the store first (one transaction) and queued as an `Operation`; the engine replays it. Never block the UI on the network.
- Message bodies are sanitized once, at sync time, and stored render-ready. Opening a message must not parse HTML.
- No folder or label UI. Labels and folders are stored only to round-trip provider state.
- Performance budgets in `docs/ARCHITECTURE.md` are requirements, not aspirations. Keep `os_signpost` markers around list refresh, conversation open, and search.
- Comments explain why, not what. No barrel files. One type per file for public types.
- Do not log message bodies, subjects, or addresses at levels above debug. Nor prompts, model output, CLI output or API keys (Help Me Write).
