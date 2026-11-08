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

## Signatures

Each account can have a signature: select the account in **Settings → Accounts** and type it in **Signature**, using bold (`⌘B`), italic (`⌘I`), underline (`⌘U`) and links (`⌘K`). It is saved when you leave the field or go to another window. New messages, replies and forwards then start with it below an empty line, above the quoted message; it is ordinary text you can edit or delete. Changing **From** swaps it for the other account's signature, unless you deleted it. Signatures stay on this Mac: SuperSparrow neither reads nor changes the one set in Gmail or Outlook.

## Notifications

A notification for one new conversation offers **Archive**, **Mark as Read** and **Reply**; a summary of several ("4 new messages") offers none. Archive and Mark as Read leave SuperSparrow in the background and sync like the same actions in the window, but they have no Undo. Reply brings SuperSparrow forward with a reply ready in a composer window. Clicking a notification for one conversation opens it.

## What the Mac provides

SuperSparrow leaves these to macOS instead of building its own, and keeps them switched on:

| Feature | Where it works |
|---|---|
| Spelling checked as you type | The message body, the quick reply and the signature field (grammar is off; **Edit → Spelling and Grammar** turns it on). Subject and recipients are checked on request, for spelling and grammar: **Edit → Spelling and Grammar → Check Document Now** (`⌘;`). |
| Text replacements and autocorrection | The composer (body, subject, recipients), the quick reply and the signature field, as set in System Settings → Keyboard. **Edit → Substitutions → Text Replacement** and **Edit → Spelling and Grammar → Correct Spelling Automatically** turn them on or off. |
| Writing Tools | The same places: **Edit → Writing Tools**, or right-click selected text. Needs Apple Intelligence. |
| Dictation, Emoji & Symbols | **Edit → Start Dictation…** and **Edit → Emoji & Symbols** (fn-E), in any text field; dictation's shortcut is the one set in System Settings → Keyboard. |
| Services | **SuperSparrow → Services**, or right-click selected text, in the composer and in a message you are reading. Services that change the selected text, such as Convert Text to Full Width, are offered in the message body too. |
| Quick Look | Click an attachment, or press Space in the reader. |
| Look Up, Translate, Share | Right-click selected text in the composer. A message you are reading keeps WebKit's own right-click menu, which offers them too. |

Checked on macOS 27.0.1 (build 26A434), with in-process tests and a scratch build, up to the point where macOS takes over. None of them was used as a person would use it:

- Spelling, text replacement and autocorrection were checked as settings, not by typing.
- Dictation, Emoji & Symbols and Writing Tools were checked as offered (their menu items are there and enabled), not used.
- Look Up, Translate and Share were seen in the right-click menu of the composer's message body on selected text, not used.
- Services were checked up to handing over the selected text and taking text back; no service was run.
- Quick Look was checked up to the files it would show after Space; the panel was not opened, and clicking an attachment was not tried.
- The right-click menu inside a message you are reading was not opened.

Not yet checked on macOS 15 or 26.

## Later

Press `l` (or **Message → Later…**, or **Later** in a conversation's right-click menu) to put the selected conversations away until **Later Today**, **This Evening**, **Tomorrow**, **Next Week** or a date you pick. They are archived now and come back to the Inbox at that time, their latest message unread, at the top under Today with a **Back** tag until you read them. While anything is snoozed a **Later** folder shows in the rail below Inbox (`g` then `l`), listing what comes back when, soonest first; there `l` picks a new time, `e` keeps a conversation archived and stops its return, `⇧I` brings it back now and `#` moves it to the Trash. A reply from someone else, or moving the conversation back to the Inbox yourself (here or on another device), ends the snooze early. Both halves are the ordinary archive and move to Inbox, so your phone and the web show the same state; only the timer lives on this Mac, so mail comes back while SuperSparrow is running, or as soon as it next opens or the Mac wakes, once it has checked for anything that came in the meantime. Gmail's and Outlook's own snooze cannot be reached through their APIs, so mail snoozed there does not show in Later.

## Keep mail on this Mac

**Settings → General → Keep mail on this Mac** chooses how far back messages keep their full content on your Mac: **Everything** (the default), **1 year** or **3 months**, with the space your mail takes beside it ("292 MB"). Older messages stay in the list and in search; their full content is removed from this Mac (older mail arriving during the first download is never stored in full) and downloads again when you open one (so opening old mail needs a connection); mail you have opened keeps its content until you quit. Choosing a shorter time cleans up at once; choosing a longer one removes nothing more and downloads nothing back. Drafts, messages waiting to send and changes still syncing are never touched. Attachments you open are cached up to 1 GB, the least recently used going first.

## Keyboard shortcuts

| Key | Action |
|---|---|
| `j` / `k`, `↓` / `↑` | Next / previous conversation |
| `Return` | Open the conversation in the reader |
| `e` | Archive |
| `l` | Later: snooze until a time |
| `s` | Star / unstar |
| `u` | Mark read / unread |
| `#`, `⌘⌫` | Move to Trash |
| `⇧I`, `⇧⌘I` | Move to Inbox (restores from the Trash) |
| `z`, `⌘Z` | Undo the last mail action (last 20 are kept) |
| `r` / `a` / `f` | Reply / reply all / forward |
| `c`, `⌘N` | New message |
| `/`, `⌘F` | Search (`Esc` clears, in the search field or the list) |
| `g` then `i` / `s` / `t` / `a` | Go to Inbox / Starred / Sent / All Mail |
| `g` then `l` | Go to Later, while something is snoozed |
| `⌘0` | All inboxes |
| `⌘1` … `⌘9` | One account |
| `⌃⌘S` | Hide / show the account strip |
| `⌘,` | Settings |

Single-letter shortcuts only apply when you are not typing in a text field.

## Design

SuperSparrow's look is **Quire**: New York subjects on warm paper, one blue-black ink (Iron Gall) for what needs you, and a still list beside a generous reading page. If you prefer a sans serif, **Settings → General → Font → SF Pro** sets every New York face in the app in SF Pro, at once. The spec is [docs/DESIGN-LANGUAGE.md](docs/DESIGN-LANGUAGE.md); [docs/design/specimen.html](docs/design/specimen.html) shows every token and component (rendered as [light](docs/design/specimen-light.png) and [dark](docs/design/specimen-dark.png)). [docs/design/tokens.json](docs/design/tokens.json) is the single source: the app's design runtime (`Sources/SSDesign`), the reader's CSS, the accent colour and the app icon are generated from it, and debug builds show every component in **Debug → Design Gallery**.

## Privacy

- Your mail is stored only on this Mac, in `~/Library/Application Support/SuperSparrow/mail.sqlite` (mode 0600). Attachments are cached in `~/Library/Caches/SuperSparrow/attachments` (up to 1 GB).
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
