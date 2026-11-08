# SuperSparrow

A native macOS mail client for Gmail and Microsoft 365 / Outlook.com. One unified inbox, no folders or labels in the way, and every interaction answered from a local SQLite store, so it stays fast: Sparrow's simplicity with Superhuman's speed.

![SuperSparrow main window](docs/screenshot.png)
<!-- Screenshot placeholder: the three-column window (account strip, message list, reader). -->

## Build and run

Requires macOS 15 or later and Xcode 26 (Swift 6 toolchain) to build. SwiftPM only, no Xcode project.

```sh
scripts/run.sh                    # build, bundle dist/SuperSparrow.app and open it
scripts/run.sh -- --demo          # same, in demo mode
scripts/run.sh release -- --demo  # release build, demo mode
open dist/SuperSparrow.app --args --demo
scripts/test.sh                   # the generated design files' check, then the whole suite
```

### Demo mode

`--demo` opens two made-up mailboxes (`alex@demo-gmail.test` on "Gmail" and `alex@demo-outlook.test` on "Microsoft") with about 400 messages over the last 60 days: threads, newsletters, notifications, a Gmail-style and an Outlook-style quoted reply, an inline image and a PDF attachment. A new message arrives roughly every 45 seconds while the app runs. Archive, star, reply and send all work; nothing leaves your Mac.

Demo mode uses its own database (`~/Library/Application Support/SuperSparrow/demo.sqlite`) and never touches your real mail or the Keychain. `--reset-demo` wipes it and starts over. With no accounts set up, the welcome screen also has a **Try the demo** button.

## Adding accounts

SuperSparrow signs in through your browser with OAuth clients you register yourself. Create them once (about ten minutes, see [docs/OAUTH-SETUP.md](docs/OAUTH-SETUP.md)), paste the client IDs into **Settings → OAuth**, then click **Add Gmail account** or **Add Microsoft account**.

## Mail links

Once SuperSparrow is your default mail app, a `mailto:` link (an address in Safari, **Email** in Contacts, a link in any other app) opens a new message with its recipients, subject and body filled in, from the account you are looking at (the first account under All Inboxes). Nothing is sent until you click Send. To make it the default, click **Set as Default Mail App** in **Settings → General → Mail links** and confirm in the dialog macOS shows; you can also choose it in Mail under **Settings → General → Default email reader**.

## Notifications

A notification for one new conversation offers **Archive**, **Mark as Read** and **Reply**; a summary of several ("4 new messages") offers none. Archive and Mark as Read leave SuperSparrow in the background and sync like the same actions in the window, but they have no Undo. Reply brings SuperSparrow forward with a reply ready in a composer window. Clicking a notification for one conversation opens it.

## Keyboard shortcuts

| Key | Action |
|---|---|
| `j` / `k`, `↓` / `↑` | Next / previous conversation |
| `Return` | Open the conversation in the reader |
| `e` | Archive |
| `s` | Star / unstar |
| `u` | Mark read / unread |
| `#`, `⌘⌫` | Move to Trash |
| `⇧I`, `⇧⌘I` | Move to Inbox (restores from the Trash) |
| `z`, `⌘Z` | Undo the last mail action (last 20 are kept) |
| `r` / `a` / `f` | Reply / reply all / forward |
| `c`, `⌘N` | New message |
| `/`, `⌘F` | Search (`Esc` clears, in the search field or the list) |
| `g` then `i` / `s` / `t` / `a` | Go to Inbox / Starred / Sent / All Mail |
| `⌘0` | All inboxes |
| `⌘1` … `⌘9` | One account |
| `⌃⌘S` | Hide / show the account strip |
| `⌘,` | Settings |

Single-letter shortcuts only apply when you are not typing in a text field.

## Design

SuperSparrow's look is **Quire**: New York subjects on warm paper, one blue-black ink (Iron Gall) for what needs you, and a still list beside a generous reading page. If you prefer a sans serif, **Settings → General → Font → SF Pro** sets every New York face in the app in SF Pro, at once. The spec is [docs/DESIGN-LANGUAGE.md](docs/DESIGN-LANGUAGE.md); [docs/design/specimen.html](docs/design/specimen.html) shows every token and component (rendered as [light](docs/design/specimen-light.png) and [dark](docs/design/specimen-dark.png)). [docs/design/tokens.json](docs/design/tokens.json) is the single source: the app's design runtime (`Sources/SSDesign`), the reader's CSS, the accent colour and the app icon are generated from it, and debug builds show every component in **Debug → Design Gallery**.

## Privacy

- Your mail is stored only on this Mac, in `~/Library/Application Support/SuperSparrow/mail.sqlite` (mode 0600). Attachments are cached in `~/Library/Caches/SuperSparrow/attachments`.
- Sign-in tokens live in the login Keychain. SuperSparrow never sees your password.
- Mail content goes only to Google, Microsoft and this machine. No analytics, no crash reporting, no third-party services.
- Remote images are blocked by default (they can tell senders you opened a message). You can change that in Settings → General.
- New-mail notifications show sender and subject by default; turn off **Show sender and subject** in Settings → General to keep notifications content-free.

## More

- Architecture, launch options and performance budgets: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Roadmap, November 2026 to October 2027: [docs/ROADMAP.md](docs/ROADMAP.md)
- Design language: [docs/DESIGN-LANGUAGE.md](docs/DESIGN-LANGUAGE.md)
- Database schema: [docs/DATA-MODEL.md](docs/DATA-MODEL.md)
- OAuth setup: [docs/OAUTH-SETUP.md](docs/OAUTH-SETUP.md)
