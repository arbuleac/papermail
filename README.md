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

`--demo` opens two made-up mailboxes (`alex@demo-gmail.test` on "Gmail" and `alex@demo-outlook.test` on "Microsoft") with about 400 messages over the last 60 days: threads, newsletters, notifications, calendar invitations, a Gmail-style and an Outlook-style quoted reply, an inline image, a PDF attachment, and a message with two attachments to try **Download all** on. A new message arrives roughly every 45 seconds while the app runs. Archive, star, reply and send all work; nothing leaves your Mac.

Demo mode uses its own database (`~/Library/Application Support/SuperSparrow/demo.sqlite`) and never touches your real mail or the Keychain. `--reset-demo` wipes it and starts over. With no accounts set up, the welcome screen also has a **Try the demo** button.

## Adding accounts

SuperSparrow signs in through your browser with OAuth clients you register yourself. Create them once (about ten minutes, see [docs/OAUTH-SETUP.md](docs/OAUTH-SETUP.md)), paste the client IDs into **Settings → OAuth**, then click **Add Gmail account** or **Add Microsoft account**. For Microsoft, choose **Work or School** or **Personal**: one address can be both, and only the one you choose is signed in.

## Mail links

Once SuperSparrow is your default mail app, a `mailto:` link (an address in Safari, **Email** in Contacts, a link in any other app) opens a new message with its recipients, subject and body filled in, from the account you are looking at (the first account under All Inboxes). Nothing is sent until you click Send. To make it the default, click **Set as Default Mail App** in **Settings → General → Mail links** and confirm in the dialog macOS shows; you can also choose it in Mail under **Settings → General → Default email reader**.

## Services

Select text in any app and choose **Services → New Message with Selection** (in the app's menu, or right-click the selection) for a new message with that text as its body. Select files in Finder and choose **Services → Send with SuperSparrow** for a new message with them attached; folders can't be attached. Both open from the account you are looking at (the first account under All Inboxes), with nothing sent until you click Send; closing the window without changing anything keeps no draft. To give either a keyboard shortcut, or to hide it, use **System Settings → Keyboard → Keyboard Shortcuts → Services**. If they don't show yet after you first open SuperSparrow, logging out and back in makes macOS read them again.

## Signatures

Each account can have a signature: select the account in **Settings → Accounts** and type it in **Signature**, using bold (`⌘B`), italic (`⌘I`), underline (`⌘U`) and links (`⌘K`). It is saved when you leave the field or go to another window. New messages, replies and forwards then start with it below an empty line, above the quoted message; it is ordinary text you can edit or delete. Changing **From** swaps it for the other account's signature, unless you deleted it. Signatures stay on this Mac: SuperSparrow neither reads nor changes the one set in Gmail or Outlook.

## Pictures in a message

Paste a picture (`⌘V`), drop one on the text of a message you are writing, or choose picture files with **Format → Insert Picture…** (`⌥⌘I`), and it goes in where the cursor is, or where you dropped it, and arrives in the text for the people you send it to. A large picture shows as a grey box of its size for a moment while it is converted; you can keep typing, and Send waits for it. A screenshot copied to the clipboard, an image copied or dragged from a browser, and picture files copied in or dragged from the Finder all work; files that are not all pictures, and files dropped anywhere else in the window, are attached instead. PNG, JPEG and GIF pictures are sent as they are; others (HEIC from an iPhone, TIFF) are converted to JPEG or PNG first. A photo's location (GPS) is taken out of what is sent. A picture is shown no wider than the text, and sent at full size: like attachments, SuperSparrow puts no limit on it, so a message larger than Gmail or Microsoft accepts fails to send after the undo window, and the draft, pictures included, stays on this Mac to change and send again. Drafts keep their pictures when you quit. The signature field takes text only.

## Notifications

A notification for one new conversation offers **Archive**, **Mark as Read** and **Reply**; a summary of several ("4 new messages") offers none. Archive and Mark as Read leave SuperSparrow in the background and sync like the same actions in the window, but they have no Undo. Reply brings SuperSparrow forward with a reply ready in a composer window. Clicking a notification for one conversation opens it.

Notifications arrive only while SuperSparrow is open. To have it open when you log in, turn on **Open SuperSparrow** in **Settings → General → At login**. If it says "Needs approval in System Settings", click **Open Login Items** and allow SuperSparrow there; you can also add or remove it yourself in System Settings → General → Login Items & Extensions.

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

## A conversation in its own window

Press `⌘O` (**File → Open in New Window**), or hold `⌘` and double-click a conversation in the list, to open it in a window of its own, to read beside a reply you are writing. The window is the reader alone: the same keys and **Message** menu act on its conversation (`e`, `l`, `#`, `!`, `m`, `s`, `u`, `r`, `z` and the rest), and so do **Print**, **Find in Conversation**, **Download Attachments** and `⌘+` / `⌘−`. Archiving, snoozing, moving it to the Trash, marking it as spam, muting it from the Inbox, discarding its draft or unsubscribing closes the window, and the main window comes forward with **Undo**, which brings the conversation back and opens its window again where it was. A reply sent with **Send and Archive** from the window closes it too, its **Undo send** in a panel on the main window. Text you typed in the window's reply field is kept when it closes: it is there again when the window reopens, or in the main window when you open the conversation there. Undo works across windows: `z` in any window undoes the last action, wherever it was taken, and its confirmation shows there. Opening a conversation that is already open brings its window forward. Each window keeps a web view of its own, about 25 MB.

## Send and Archive

Replying usually finishes a conversation, so **Send** sends and archives the conversation you answered, as `e` would: it leaves the Inbox the moment the message is queued and, in the Inbox, the next conversation opens. The arrow beside **Send** (in a composer and in the reply field under a conversation) chooses what Send and `⌘↩` do: **Send and Archive** (the default) or **Send**; the choice applies to every Send button at once and is kept. `⇧⌘↩` (**Message → Send and Archive** in a composer) always sends and archives. A new message only sends. Send's tooltip says which it does. Undo send (in the panel, the reply field's strip or `⌘Z`) also brings the conversation back to the Inbox; once the message has left, it stays archived. In **Later**, Send and Archive stops the conversation's return and keeps it archived, as `e` does there.

## Send Later

The arrow beside **Send** (in a composer and in the reply field) also offers **Send Later**: **Tomorrow** or **Monday** at 09:00, or **Pick a Time…**; `⇧⌘L` (**Message → Send Later…**) shows the same choices. The message waits on this Mac and goes at that time **while SuperSparrow is open**; nothing is archived: Send Later only sends. Until it goes it is listed in **Drafts** as "Sends Mon 09:00", with **Cancel** beside the time in the reader; opening it cancels the schedule so you can change it. If SuperSparrow was closed when the time came, it is not sent on its own when it opens: it asks whether to send it now or keep it in Drafts. Gmail's and Outlook's own scheduled send cannot be reached through their APIs, so a message scheduled there is not listed here.

## Later

Press `l` (or **Message → Later…**, or **Later** in a conversation's right-click menu) to put the selected conversations away until **Later Today**, **This Evening**, **Tomorrow**, **Next Week** or a date you pick. They are archived now and come back to the Inbox at that time, their latest message unread, at the top under Today with a **Back** tag until you read them. While anything is snoozed a **Later** folder shows in the rail below Inbox (`g` then `l`), listing what comes back when, soonest first; there `l` picks a new time, `e` keeps a conversation archived and stops its return, `⇧I` brings it back now and `#` moves it to the Trash. A reply from someone else, or moving the conversation back to the Inbox yourself (here or on another device), ends the snooze early. Both halves are the ordinary archive and move to Inbox, so your phone and the web show the same state; only the timer lives on this Mac, so mail comes back while SuperSparrow is running, or as soon as it next opens or the Mac wakes, once it has checked for anything that came in the meantime. Gmail's and Outlook's own snooze cannot be reached through their APIs, so mail snoozed there does not show in Later.

## Mark as spam

Press `!` (or **Message → Mark as Spam**, or **Mark as Spam** in a conversation's right-click menu) to send the selected conversations to your provider's spam folder: Gmail's Spam, or Junk Email on Microsoft 365 and Outlook.com. They leave the list at once, and **Undo** puts them back where they were. Your own sent messages and drafts in the conversation are never marked as spam and stay in Sent and Drafts (unless the conversation had been moved back to the Inbox whole, as Move to Inbox or a return from Later does on Gmail: then your reply goes with the rest, and Undo brings it back). SuperSparrow has no Spam folder of its own: to rescue a message later, move it out of Spam on the web or your phone, and it comes back here. Mark as spam does nothing in the Trash or Drafts.

## Mute and sender rules

Press `m` (or **Message → Mute**) to mute the selected conversations: they leave the Inbox now, and anything new in them is archived as it arrives, before it can reach the Inbox or a notification. A muted conversation shows a muted bell in its row wherever it is listed; `m` again unmutes it. The archive is the ordinary one, so your phone and the web show the same state once it has gone through (Gmail's own mute cannot be reached through its API).

From a message's menu (right-click it, or its **⋯** button, or the **Message** menu), **Always Archive Mail from This Sender** archives that sender's mail as it arrives, and **Block Sender** moves it to the Trash; either one also moves the sender's mail in the conversation you set it from, with **Undo** in the toast. Rules are kept per account and listed in **Settings → Accounts → Rules → Senders…**, where `−` removes one. They act on mail as it arrives, never on mail already on this Mac or downloaded from further back, and never on your own sent mail. When **Always Archive** takes a message in a conversation that is still in your Inbox for someone else's mail, only that message is archived: the conversation stays, and its row shows that message as its newest, without a notification. Neither a mute nor a rule ends a snooze: a muted or ruled reply to a conversation in Later leaves it to come back at its time.

## Unsubscribe

A newsletter or other list mail that says how to leave its list shows **Unsubscribe** beside the sender's name in the reader. One click, or `⇧⌘U` (**Message → Unsubscribe**), asks to stop it and archives the conversation, without a confirmation: SuperSparrow uses the one-click request the sender offers (RFC 8058), otherwise sends the unsubscribe email the sender asks for from your account (it appears in Sent), otherwise opens the sender's unsubscribe page in your browser. On a conversation in **Later**, it stops the conversation's return instead, as `e` does there, and it stays archived. **Undo** in the toast brings the conversation back (to Later, if it was there); the request itself cannot be taken back. Mail downloaded before this version shows no link until it is downloaded again.

## Saving attachments

Every attachment in the reader has a download button at its right end: it saves the file to your Downloads folder (a second copy is numbered, "plan 2.pdf"), and a note at the bottom of the list says so, with **Show in Finder**. A message with two or more attachments also says how many above them, with **Download all**, which saves every one of them with one progress bar. `⇧⌘D` (**File → Download Attachments**) does the same for the message you are reading. Saved files keep the mark macOS puts on downloaded files, so it still asks before opening anything that runs. **File → Save Attachments…** saves them to a folder you choose.

## Invitations

A message with a calendar invitation opens with a card above it: the event's title, when it is (in your time zone, and in the organizer's when that differs), how it repeats, where, who organized it and who else is invited. The message itself, usually the sender's own copy of the same invitation, starts folded under the card: **Show message** (or `.`) unfolds it as it was sent, and **Hide message** (or `.` again) folds it away; its attachments, and a note about images it keeps back or its own colours, stay in view either way. **Accept**, **Tentative** and **Decline** answer the organizer; your answer shows on the card at once and goes out in the background, and you can change it by choosing another (change it before it has gone out, and only your last answer is sent). On Gmail, SuperSparrow mails the organizer your answer and marks the event in your Google Calendar, so your phone agrees; on Microsoft 365 and Outlook.com it answers the event in your Outlook calendar. A cancelled event is marked **Cancelled**; an event you organized offers no answers, and neither does an invitation that does not name the account it came to (one forwarded to you, or sent to another of your addresses): answer it where it was sent. **Open in Calendar** hands the invitation to the Mac's Calendar app, which shows it and offers to add it; SuperSparrow never asks for access to your Mac's calendars.

The first time you answer, the account needs permission to update your calendar, which it did not ask for when you signed in: the card says "Answer invitations: SuperSparrow needs permission to update your calendar." with **Reconnect**, and Settings → Accounts reads "Calendar permission needed". Reconnect signs you in again in your browser, asking for that permission too; your answer waits and goes out as soon as it is granted. Your OAuth clients need the Google Calendar API and the calendar scope, or the Microsoft permission `Calendars.ReadWrite` (see [docs/OAUTH-SETUP.md](docs/OAUTH-SETUP.md)).

In demo mode the newest mail in each mailbox is an invitation: one to answer, an updated one you already accepted that repeats in another time zone, a cancelled one, and a weekly Teams meeting on the Outlook side.

## Print

**File → Print…** (`⌘P`) prints the open conversation through the Mac's print panel, whose **PDF** menu saves it as a PDF. Every message prints open, oldest first, with its sender, recipients and full date, on light paper even when the app is dark. Each message prints as the reader shows it: remote images print only if you loaded them (otherwise a line says how many were left out, and nothing is fetched to print them), and quoted text you have not unfolded is left out, so unfold it with `.` first if you want it on paper.

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

**Finding words in a conversation.** `⌥⌘F` (**Edit → Find in Conversation…**) opens a small bar over the message you are reading. Type, and every match in the conversation is highlighted, with the count beside your words ("3 of 12"): collapsed messages and quoted text count too, and capitals and accents don't matter. `Return` or `⌘G` goes to the next match, `⇧Return` or `⇧⌘G` to the previous one; a collapsed message or folded quoted text holding the match opens (as you type, once you pause), and stays open afterwards. `Esc` closes the bar. It searches only the open conversation; `⌘F` still searches all your mail.

## Keyboard shortcuts

| Key | Action |
|---|---|
| `j` / `k`, `↓` / `↑` | Next / previous conversation |
| `Return` | Open the conversation in the reader |
| `⌘O`, `⌘`-double-click | Open the conversation in a window of its own |
| `e` | Archive |
| `l` | Later: snooze until a time |
| `m` | Mute / unmute: new mail in the conversation skips the Inbox |
| `s` | Star / unstar |
| `u` | Mark read / unread |
| `#`, `⌘⌫` | Move to Trash |
| `!` | Mark as spam |
| `⇧I` | Move to Inbox (restores from the Trash) |
| `z`, `⌘Z` | Undo the last mail action (last 20 are kept) |
| `⇧⌘U` | Unsubscribe from the open conversation's list, then archive it |
| `⇧⌘D` | Save the open message's attachments to Downloads |
| `⌘P` | Print the open conversation, or save it as a PDF |
| `r` / `a` / `f` | Reply / reply all / forward |
| `⌘↩` | Send (sends and archives unless you chose **Send** with the arrow beside it) |
| `⇧⌘↩` | Send and archive, whatever Send does |
| `⇧⌘L` | Send later: Tomorrow, Monday or a time you pick |
| `⌥⌘I` | Insert a picture into the message you are writing |
| `esc` in a composer | Closes it while you haven't written anything; a composer with your words stays open |
| `c`, `⌘N` | New message |
| `/`, `⌘F` | Search (`Esc` clears, in the search field or the list) |
| `↩` in the search field | Search the mail server for more, then move to the results |
| `⌥⌘F` | Find in the open conversation (`⌘G` / `⇧⌘G` next / previous match) |
| `g` then `i` / `s` / `t` / `a` | Go to Inbox / Starred / Sent / All Mail |
| `g` then `l` | Go to Later, while something is snoozed |
| `⌘0` | All inboxes |
| `⌘1` … `⌘9` | One account |
| `⌃⌘S` | Hide / show the account strip |
| `⌘,` | Settings |

Single-letter shortcuts only apply when you are not typing in a text field.

On a trackpad, swipe a conversation in the list with two fingers: left shows **Archive**, right **Mark as Read** or **Mark as Unread**. Click the button, or swipe all the way across to do it at once. It acts on that conversation alone, as `e` and `u` would, so **Undo** and `z` bring it back, and a conversation `e` would leave as it is (in the Trash, say) shows no Archive. VoiceOver offers the same actions on each conversation.

## Design

SuperSparrow's look is **Quire**: New York subjects on warm paper, one blue-black ink (Iron Gall) for what needs you, and a still list beside a generous reading page. If you prefer a sans serif, **Settings → General → Font → SF Pro** sets every New York face in the app in SF Pro, at once, and **Settings → General → Text size** (Small, Default, Large, Larger) sets the list, the reader and the composer a point smaller or up to two larger; **⌘+** and **⌘−** change the reader alone. The spec is [docs/DESIGN-LANGUAGE.md](docs/DESIGN-LANGUAGE.md); [docs/design/specimen.html](docs/design/specimen.html) shows every token and component (rendered as [light](docs/design/specimen-light.png) and [dark](docs/design/specimen-dark.png)). [docs/design/tokens.json](docs/design/tokens.json) is the single source: the app's design runtime (`Sources/SSDesign`), the reader's CSS, the accent colour and the app icon are generated from it, and debug builds show every component in **Debug → Design Gallery**.

## Privacy

- Your mail is stored only on this Mac, in `~/Library/Application Support/SuperSparrow/mail.sqlite` (mode 0600). Attachments are cached in `~/Library/Caches/SuperSparrow/attachments` (up to 1 GB).
- Sign-in tokens live in the login Keychain. SuperSparrow never sees your password.
- Mail content goes only to Google, Microsoft and this machine. No analytics, no crash reporting, no third-party services.
- Apart from remote images you choose to load, **Unsubscribe** is the only time SuperSparrow contacts anyone but Google, Microsoft and this Mac: it contacts the sender's server with the sender's own one-click request (the address the sender chose, which can identify you, and no cookies or credentials), or opens the sender's unsubscribe page in your browser. An unsubscribe email goes from your account through Google or Microsoft like any other mail. Nothing is sent unless you click Unsubscribe or press `⇧⌘U`.
- Your calendar is reached only to answer an invitation, and the permission is asked for only then: the first answer asks you to reconnect, granting Google's `calendar.events` or Microsoft's `Calendars.ReadWrite`, which SuperSparrow uses to find that event and mark your answer on it. The answer reaches the organizer through Google or Microsoft. **Open in Calendar** hands the invitation to the Mac's Calendar app; SuperSparrow never reads or writes your Mac's calendars.
- Remote images are blocked by default (they can tell senders you opened a message). You can change that in Settings → General. Images you let load come as the sender serves them, encrypted or, from senders who still use plain `http`, not.
- New-mail notifications show sender and subject by default; turn off **Show sender and subject** in Settings → General to keep notifications content-free.

## More

- Architecture, launch options and performance budgets: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Roadmap, November 2026 to October 2027: [docs/ROADMAP.md](docs/ROADMAP.md)
- Design language: [docs/DESIGN-LANGUAGE.md](docs/DESIGN-LANGUAGE.md)
- Database schema: [docs/DATA-MODEL.md](docs/DATA-MODEL.md)
- OAuth setup: [docs/OAUTH-SETUP.md](docs/OAUTH-SETUP.md)
