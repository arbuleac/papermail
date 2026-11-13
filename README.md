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

`--demo` opens two made-up mailboxes (`alex@demo-gmail.test` on "Gmail" and `alex@demo-outlook.test` on "Microsoft") with about 400 messages over the last 60 days: threads, newsletters, notifications, calendar invitations, a Gmail-style and an Outlook-style quoted reply, an inline image and a PDF attachment. A new message arrives roughly every 45 seconds while the app runs. Archive, star, reply and send all work; nothing leaves your Mac.

Demo mode uses its own database (`~/Library/Application Support/SuperSparrow/demo.sqlite`) and never touches your real mail or the Keychain. `--reset-demo` wipes it and starts over. With no accounts set up, the welcome screen also has a **Try the demo** button.

## Adding accounts

SuperSparrow signs in through your browser with OAuth clients you register yourself. Create them once (about ten minutes, see [docs/OAUTH-SETUP.md](docs/OAUTH-SETUP.md)), paste the client IDs into **Settings → OAuth**, then click **Add Gmail account** or **Add Microsoft account**. For Microsoft, choose **Work or School** or **Personal**: one address can be both, and only the one you choose is signed in.

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

## Send and Archive

Replying usually finishes a conversation, so **Send** sends and archives the conversation you answered, as `e` would: it leaves the Inbox the moment the message is queued and, in the Inbox, the next conversation opens. The arrow beside **Send** (in a composer and in the reply field under a conversation) chooses what Send and `⌘↩` do: **Send and Archive** (the default) or **Send**; the choice applies to every Send button at once and is kept. `⇧⌘↩` (**Message → Send and Archive** in a composer) always sends and archives. A new message only sends. Send's tooltip says which it does. Undo send (in the panel, the reply field's strip or `⌘Z`) also brings the conversation back to the Inbox; once the message has left, it stays archived. In **Later**, Send and Archive stops the conversation's return and keeps it archived, as `e` does there.

## Send Later

The arrow beside **Send** (in a composer and in the reply field) also offers **Send Later**: **Tomorrow** or **Monday** at 09:00, or **Pick a Time…**; `⇧⌘L` (**Message → Send Later…**) shows the same choices. The message waits on this Mac and goes at that time **while SuperSparrow is open**; nothing is archived until then. Until it goes it is listed in **Drafts** as "Sends Mon 09:00", with **Cancel** beside the time in the reader; opening it cancels the schedule so you can change it. If SuperSparrow was closed when the time came, it is not sent on its own when it opens: it asks whether to send it now or keep it in Drafts. Gmail's and Outlook's own scheduled send cannot be reached through their APIs, so a message scheduled there is not listed here.

## Later

Press `l` (or **Message → Later…**, or **Later** in a conversation's right-click menu) to put the selected conversations away until **Later Today**, **This Evening**, **Tomorrow**, **Next Week** or a date you pick. They are archived now and come back to the Inbox at that time, their latest message unread, at the top under Today with a **Back** tag until you read them. While anything is snoozed a **Later** folder shows in the rail below Inbox (`g` then `l`), listing what comes back when, soonest first; there `l` picks a new time, `e` keeps a conversation archived and stops its return, `⇧I` brings it back now and `#` moves it to the Trash. A reply from someone else, or moving the conversation back to the Inbox yourself (here or on another device), ends the snooze early. Both halves are the ordinary archive and move to Inbox, so your phone and the web show the same state; only the timer lives on this Mac, so mail comes back while SuperSparrow is running, or as soon as it next opens or the Mac wakes, once it has checked for anything that came in the meantime. Gmail's and Outlook's own snooze cannot be reached through their APIs, so mail snoozed there does not show in Later.

## Unsubscribe

A newsletter or other list mail that says how to leave its list shows **Unsubscribe** beside the sender's name in the reader. One click, or `⇧⌘U` (**Message → Unsubscribe**), asks to stop it and archives the conversation, without a confirmation: SuperSparrow uses the one-click request the sender offers (RFC 8058), otherwise sends the unsubscribe email the sender asks for from your account (it appears in Sent), otherwise opens the sender's unsubscribe page in your browser. On a conversation in **Later**, it stops the conversation's return instead, as `e` does there, and it stays archived. **Undo** in the toast brings the conversation back (to Later, if it was there); the request itself cannot be taken back. Mail downloaded before this version shows no link until it is downloaded again.

## Invitations

A message with a calendar invitation opens with a card above it: the event's title, when it is (in your time zone, and in the organizer's when that differs), how it repeats, where, who organized it and who else is invited. The message itself, usually the sender's own copy of the same invitation, starts folded under the card: **Show message** (or `.`) unfolds it as it was sent, and **Hide message** (or `.` again) folds it away; its attachments, and a note about images it keeps back or its own colours, stay in view either way. **Accept**, **Tentative** and **Decline** answer the organizer; your answer shows on the card at once and goes out in the background, and you can change it by choosing another (change it before it has gone out, and only your last answer is sent). On Gmail, SuperSparrow mails the organizer your answer and marks the event in your Google Calendar, so your phone agrees; on Microsoft 365 and Outlook.com it answers the event in your Outlook calendar. A cancelled event is marked **Cancelled**; an event you organized offers no answers, and neither does an invitation that does not name the account it came to (one forwarded to you, or sent to another of your addresses): answer it where it was sent. **Open in Calendar** hands the invitation to the Mac's Calendar app, which shows it and offers to add it; SuperSparrow never asks for access to your Mac's calendars.

The first time you answer, the account needs permission to update your calendar, which it did not ask for when you signed in: the card says "Answer invitations: SuperSparrow needs permission to update your calendar." with **Reconnect**, and Settings → Accounts reads "Calendar permission needed". Reconnect signs you in again in your browser, asking for that permission too; your answer waits and goes out as soon as it is granted. Your OAuth clients need the Google Calendar API and the calendar scope, or the Microsoft permission `Calendars.ReadWrite` (see [docs/OAUTH-SETUP.md](docs/OAUTH-SETUP.md)).

In demo mode the newest mail in each mailbox is an invitation: one to answer, an updated one you already accepted that repeats in another time zone, a cancelled one, and a weekly Teams meeting on the Outlook side.

## Keep mail on this Mac

**Settings → General → Keep mail on this Mac** chooses how far back messages keep their full content on your Mac: **Everything** (the default), **1 year** or **3 months**, with the space your mail takes beside it ("292 MB"). Older messages stay in the list and in search; their full content is removed from this Mac (older mail arriving during the first download is never stored in full) and downloads again when you open one (so opening old mail needs a connection); mail you have opened keeps its content until you quit. Choosing a shorter time cleans up at once; choosing a longer one removes nothing more and downloads nothing back. Drafts, messages waiting to send and changes still syncing are never touched. Attachments you open are cached up to 1 GB, the least recently used going first.

## Search

Press `/` (or `⌘F`) and type: results narrow as you type, across subjects, people and message text (a message's preview until its content has downloaded), in every account the rail shows, everywhere but the Trash and Spam. Add operators to the same field:

| Operator | Finds |
|---|---|
| `from:ben`, `from:"Ben Carter"` | mail from that name or address |
| `to:ana` | mail to that name or address, in To, Cc or Bcc |
| `subject:lisbon` | that word in the subject |
| `is:unread`, `is:read`, `is:starred`, `has:attachment` | conversations that are unread, read, starred, or have an attachment |
| `after:2026-01-31`, `before:2026/01/31` | the latest message on or after that day, or before it |
| `in:inbox`, `in:sent`, `in:drafts`, `in:trash`, `in:all` | that view, whichever one is on screen, Later included (`in:trash` searches the Trash) |
| `"weekly metrics"` | those words together, in that order |
| `-word`, `-from:ben`, `-is:starred` | leaves those out |

Operators combine (`from:ben is:unread after:2026-01-01 -invoice`), ignore case, and anything that is not an operator is searched as words. A result you open in an `is:unread` search stays in the list, read, until you open another. The keyboard cheat sheet (`?`) lists the operators on its last line.

**Searching the server.** Search looks through the mail on this Mac. When the results end, the list ends with **Search Gmail for more** (**Search Outlook for more** for a Microsoft account, **Search all accounts for more** under All Inboxes): click it, or press `↩` in the search field (the row shows a `↩` keycap while you type), to ask the mail server too, for mail that has not downloaded yet, as during the first download of a large mailbox. The server is asked what you typed, operators included, and searches by its own rules (Gmail understands its own `from:`, `is:unread` and `has:attachment`, Outlook its own search words), so it can also find what this Mac's search reads differently; `is:`, `has:`, `before:`, `after:` and `in:` still narrow what it finds, as they narrow the rest. What it finds joins the results in date order and stays on this Mac, so a later search finds it like any other mail; a message's content downloads when you open it. The row then says how many more it found, or **Nothing more on Gmail**, or **Couldn't search Gmail · Try again** when offline. `Return` in the search field always takes you to the list as well; once the server has answered or failed it only does that (**Try again** asks again), and `↓` goes to the list without asking the server. New words start a new search.

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
| `⇧⌘U` | Unsubscribe from the open conversation's list, then archive it |
| `r` / `a` / `f` | Reply / reply all / forward |
| `⌘↩` | Send (sends and archives unless you chose **Send** with the arrow beside it) |
| `⇧⌘↩` | Send and archive, whatever Send does |
| `⇧⌘L` | Send later: Tomorrow, Monday or a time you pick |
| `esc` in a composer | Closes it while you haven't written anything; a composer with your words stays open |
| `c`, `⌘N` | New message |
| `/`, `⌘F` | Search (`Esc` clears, in the search field or the list) |
| `↩` in the search field | Search the mail server for more, then move to the results |
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
- Apart from remote images you choose to load, **Unsubscribe** is the only time SuperSparrow contacts anyone but Google, Microsoft and this Mac: it contacts the sender's server with the sender's own one-click request (the address the sender chose, which can identify you, and no cookies or credentials), or opens the sender's unsubscribe page in your browser. An unsubscribe email goes from your account through Google or Microsoft like any other mail. Nothing is sent unless you click Unsubscribe or press `⇧⌘U`.
- Your calendar is reached only to answer an invitation, and the permission is asked for only then: the first answer asks you to reconnect, granting Google's `calendar.events` or Microsoft's `Calendars.ReadWrite`, which SuperSparrow uses to find that event and mark your answer on it. The answer reaches the organizer through Google or Microsoft. **Open in Calendar** hands the invitation to the Mac's Calendar app; SuperSparrow never reads or writes your Mac's calendars.
- Remote images are blocked by default (they can tell senders you opened a message). You can change that in Settings → General.
- New-mail notifications show sender and subject by default; turn off **Show sender and subject** in Settings → General to keep notifications content-free.

## More

- Architecture, launch options and performance budgets: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Roadmap, November 2026 to October 2027: [docs/ROADMAP.md](docs/ROADMAP.md)
- Design language: [docs/DESIGN-LANGUAGE.md](docs/DESIGN-LANGUAGE.md)
- Database schema: [docs/DATA-MODEL.md](docs/DATA-MODEL.md)
- OAuth setup: [docs/OAUTH-SETUP.md](docs/OAUTH-SETUP.md)
