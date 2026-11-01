# SuperSparrow (macOS)

Native Mac mail client for Gmail and Microsoft 365/Outlook.com. Unified inbox, Superhuman-class speed, Sparrow-style simplicity. Swift Package, AppKit shell, SwiftUI only for small chrome.

Read `docs/ARCHITECTURE.md` before changing anything. `docs/DATA-MODEL.md` is the schema contract. `docs/OAUTH-SETUP.md` is the user-facing setup.

## Commands
- Build: `swift build` (debug) or `swift build -c release`
- Tests: `swift test` (all) or `swift test --filter SSCoreTests`
- Run the app: `scripts/run.sh` (builds, assembles `dist/SuperSparrow.app`, opens it)
- Bundle only: `scripts/build-app.sh [debug|release]`
- No Node, npm, Homebrew installs or Xcode project files. SwiftPM only. Do not add dependencies beyond GRDB and SwiftSoup without asking.

## Layout
- `Sources/SSCore` — models (`Model/`), ports (`Ports/`), SQLite store (`Store/`), sync engine (`Sync/`), OAuth + Keychain (`Auth/`), HTML sanitizer (`Render/`). No AppKit, no WebKit.
- `Sources/SSGmail` — `GmailProvider: MailProvider` over the Gmail REST API.
- `Sources/SSGraph` — `GraphProvider: MailProvider` over Microsoft Graph.
- `Sources/SuperSparrowApp` — the AppKit app: windows, list, conversation renderer (WebKit), composer.
- `Tests/*` — XCTest. Core tests use in-memory GRDB. Provider tests use recorded JSON fixtures and a stub `URLProtocol`; never hit the network in tests.

## Rules
- Swift 5 language mode on Swift 6 toolchain. Use actors for engine state, `@MainActor` for UI. Mark shared types `Sendable`.
- The UI reads only from `MailStoring`. The UI never calls a provider.
- Every user action is applied to the store first (one transaction) and queued as an `Operation`; the engine replays it. Never block the UI on the network.
- Message bodies are sanitized once, at sync time, and stored render-ready. Opening a message must not parse HTML.
- No folder or label UI. Labels and folders are stored only to round-trip provider state.
- Performance budgets in `docs/ARCHITECTURE.md` are requirements, not aspirations. Keep `os_signpost` markers around list refresh, conversation open, and search.
- Comments explain why, not what. No barrel files. One type per file for public types.
- Do not log message bodies, subjects, or addresses at levels above debug.
