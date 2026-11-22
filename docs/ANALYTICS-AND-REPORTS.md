# Analytics and reports

Paper sends two things to two services, under one switch, **Settings → General → Analytics and reports**:

- **Crash reports**: crashes, exceptions and hangs, to [Sentry](https://sentry.io) through Sentry's Cocoa SDK ("Crash reports" below; why and how in [ARCHITECTURE.md](ARCHITECTURE.md), "Crash reports").
- **Analytics**: which features are used, and how fast, never what they were used on, to [TelemetryDeck](https://telemetrydeck.com) through its Swift SDK ("Analytics" below; why and how in [ARCHITECTURE.md](ARCHITECTURE.md), "Analytics").

The switch is on unless the user turns it off. Off stops both at once, the current run included, and deletes what both had queued on this Mac. On again, crash reports start at once and analytics at the next launch ("Turning it off"). It keeps the defaults key crash reports had (`sendsCrashReports`), so anyone who turned crash reports off is opted out of analytics too.

A build without a Sentry project or a TelemetryDeck app still runs and sends nothing of that kind. With neither, the switch is disabled and says "Not set up in this build."; with one, it governs that one, names it and says what it sends:

| Build | Toggle | Caption |
|---|---|---|
| Both | Send to Sentry and TelemetryDeck | Crashes, hangs and features used. Never your mail or addresses. |
| Sentry only | Send to Sentry | Crashes and hangs. Never your mail or addresses. |
| TelemetryDeck only | Send to TelemetryDeck | Features used. Never your mail or addresses. |
| Neither | Send to Sentry and TelemetryDeck (disabled) | Not set up in this build. |

# Crash reports

## 1. Create the project (once)

1. Sign in at [sentry.io](https://sentry.io) and create an organization. Choose the **EU** data region if you want reports kept in the EU. The region cannot be changed later.
2. **Projects → Create Project**, platform **Apple → macOS**, name it `paper-macos`. (A project made before the app was called Paper keeps its DSN when renamed, under **Settings → Projects → the project → General Settings**; its old releases keep their old bundle identifier. Renaming it is also what lets the reports the app had queued under its old name but not sent go after the move: the SDK keeps its queue under a hash of the DSN, so a new project's DSN never reads it.)
3. Under **Settings → Projects → paper-macos → Client Keys (DSN)**, copy the DSN. It looks like `https://<key>@o<org>.ingest.<region>.sentry.io/<project>`. A DSN only lets an app send reports, so it is not a secret, but keep it out of a public repository so strangers cannot fill your quota.
4. Optional, recommended: under **Settings → Projects → paper-macos → Security & Privacy**, turn on **Data Scrubber** and **Prevent Storing of IP Addresses**. The app already scrubs reports before they leave; this is a second net on the server. Sentry still works out a city and country from the sender's IP address before it drops the address, so also add an **Advanced Data Scrubbing** rule: **Remove**, **Anything**, from `$user.geo.**`.

## 2. Build with it

Put the DSN in the untracked file `Resources/SentryDSN`. `.gitignore` keeps it out of git.

```sh
echo 'https://<key>@o<org>.ingest.<region>.sentry.io/<project>' > Resources/SentryDSN
scripts/build-app.sh debug        # or release; SENTRY_DSN=… scripts/build-app.sh also works
```

`scripts/build-app.sh` writes it into the bundle's Info.plist as `SentryDSN` and writes the build's debug symbols to `dist/Paper.app.dSYM`.

## 3. Upload symbols (each build you run)

Without symbols, Sentry shows the app's own frames as image offsets. To upload them:

1. Install Sentry's CLI, `sentry`, a standalone binary in `~/.local/bin` (no npm or Homebrew), and sign in:

```sh
curl -fsSL https://cli.sentry.dev/install | bash
sentry auth login
```

2. Upload. Run from the repository, the CLI finds the organization and project from `Resources/SentryDSN`:

```sh
scripts/upload-dsyms.sh                    # add --include-sources to show source lines in Sentry
```

The script falls back to the legacy `sentry-cli` when `sentry` is missing. That one needs `SENTRY_AUTH_TOKEN`, `SENTRY_ORG` and `SENTRY_PROJECT` in the environment.

A debug build's dSYM is about 50 MB and a release build's about 65 MB. Each build has its own UUID, so upload after every build you run day to day.

## 4. Check it end to end

Debug builds take `--crash-test=<kind>`, which acts two seconds after launch:

| Kind | What happens | What Sentry shows |
|---|---|---|
| `crash` | The SDK's test crash (a bad memory access). The app quits. | A fatal `EXC_BAD_ACCESS` at the next launch |
| `fatal` | A Swift trap (a force-unwrapped nil). The app quits. | A fatal `EXC_BREAKPOINT` with the Swift error message, at the next launch |
| `exception` | An Objective-C exception no one catches, thrown on a background queue. The app quits. | A fatal `NSInternalInconsistencyException` with its reason, at the next launch |
| `appkit-exception` | An exception thrown while AppKit dispatches an event. AppKit catches it and the app goes on. | An error `NSInvalidArgumentException`, tag `caught_by: appkit`, at once |
| `hang` | The main thread blocked for 5 s. The app goes on. | "App hanging for at least 2000 ms", at once |

```sh
dist/Paper.app/Contents/MacOS/Paper --demo --crash-test=crash
open dist/Paper.app --args --demo     # the next launch sends the crash
```

Use `--demo` so a test never touches your real mailbox. To look at exactly what would leave the Mac without sending anything to Sentry, run the bare binary against a local listener with `--sentry-dsn=http://key@127.0.0.1:8977/1` (`NSAllowsLocalNetworking` lets it use plain http to 127.0.0.1). The listener should store every POST to `/api/1/envelope/`; the SDK gzips them.

## What is caught, and what is not

- **Caught:**
  - crashes (Mach exceptions and signals, Swift traps included)
  - uncaught Objective-C and C++ exceptions, on any thread
  - exceptions AppKit catches while it dispatches an event (reported as errors; the app goes on)
  - main-thread hangs of 2 s or more
  - MetricKit's crash, hang, CPU and disk-write diagnostics, at a later launch
  - crash-free sessions per release
- **Not caught:**
  - **A crash while a debugger is attached.** The debugger takes it first.
  - **An exception AppKit catches during layout or a Core Animation commit.** It ends the app through a private AppKit method, so Sentry shows the SIGABRT and its stack but not the exception's reason.
  - **A force quit, or the system ending the app for memory.** These leave no crash report (MetricKit may report the cause later).
  - **Crashes in WebKit's own processes.** The reader recovers from those by itself.
- **Turning it off:** **Settings → General → Analytics and reports**. This takes effect at once, the current run included, and deletes reports still queued on disk (`~/Library/Caches/app.paperinbox.mac/Sentry`), so none goes later.

# Analytics

Paper counts which features are used, from where (a key, a menu, a swipe…) and how fast, through TelemetryDeck's Swift SDK (`TelemetryDeck`, `from: "2.14.2"`). Every signal comes from a closed catalog in the code (`AnalyticsSignal`): each parameter value is one of a fixed set of words, a count put in a range, or a duration put in a range, so nothing a user wrote or received can be sent.

## 1. Create the app (once)

1. Sign in at [telemetrydeck.com](https://telemetrydeck.com) and create an organization.
2. **Create App**, name it `Paper`. Its **App ID** (a UUID) is under the app's settings. An app ID only lets an app send signals, so it is not a secret, but keep it out of a public repository so strangers cannot fill your quota.
3. Debug builds send TelemetryDeck's *test* signals, which the dashboard shows only with **Test Mode** on; release builds send live ones.

## 2. Build with it

Put the app ID in the untracked file `Resources/TelemetryDeckAppID`. `.gitignore` keeps it out of git.

```sh
echo '<app-id>' > Resources/TelemetryDeckAppID
scripts/build-app.sh debug        # or release; TELEMETRYDECK_APP_ID=… scripts/build-app.sh also works
```

`scripts/build-app.sh` writes it into the bundle's Info.plist as `TelemetryDeckAppID`. A debug build's bare binary takes `--telemetry-app-id=<id>` instead. Without an app ID nothing starts.

## 3. What is sent

Every signal carries `mode` (`demo` or `accounts`: which mailbox was on screen) besides the parameters below, TelemetryDeck's own two signals included (the app hands it to the SDK as a default parameter).

| Signal | When | Parameters |
|---|---|---|
| `App.launched` | Once a launch, when the first main window is on screen. Its number is the launch's seconds. | `launchTime`, `gmailAccounts`, `microsoftAccounts`, `theme`, `appearance`, `density`, `textSize`, `font` |
| `Settings.opened` | The Settings window opens. | none |
| `Settings.changed` | A setting changes, in Settings or by its own control elsewhere (Send's drop-down, View › Compact Rows); At login and Mail links once macOS has done what was asked; Settings › AI's Provider once turned on (or Off); an account's Face in Settings › Accounts. A value set again is no change. Reader mode switched from the reader is `ReaderMode.switched`, and moved with its experiment (Settings › Experimental) it is that toggle's change alone. | `setting`, `value` |
| `Mail.action` | Archive, Move to Trash, Mark as Spam, Move to Inbox, Star, Mark as Read or Unread, Later, Mute, Unsubscribe, Always Archive or Block a sender, from any window. Always Archive counts the conversations it archived mail in, in every account's Inbox, none included; Block counts its one conversation. | `action`, `trigger`, `conversations` |
| `Compose.started` | A composer window opens: New Message, Reply, Reply All, Forward, a kept draft opened again (Continue Editing, or Reply or Forward on a conversation whose reply or forward was kept), a mail link, the Services menu. A composer already open and only brought forward is none, nor a send undone and reopened (that is `Compose.sendUndone`). | `kind`, `origin`, `trigger` (the app's own ways in only) |
| `Compose.sent` | A composer's message goes to the outbox (its Undo window still to run). | `kind`, `archives` |
| `Compose.sendLaterScheduled` | Send Later from a composer or the quick reply. | `source` |
| `Compose.sendUndone` | Undo Send, or Undo on a Send Later toast. | `source` |
| `QuickReply.sent` | The quick reply sends. | `kind`, `archives` |
| `Search.local` | A search of this Mac that stood for 2 s (the field searches at every keystroke; only where the user stopped counts). | `operators`, `results` |
| `Search.server` | Search Gmail or Microsoft for more finishes. Its number is the seconds it took. | `outcome`, `operators`, `results`, `searchTime` |
| `Reader.windowOpened` | A conversation opens in a reader window. | `trigger` |
| `View.opened` | The user moves the window to another view or scope: the rail, the title menu, View and Go menus, ⌘0…⌘9, a G-sequence (in a reader window too). Picking where the window already is, or the app moving it on its own (an undo, a notification, an account going), is none. | `view`, `scope`, `trigger` |
| `Calendar.dayColumn` | D, View › Hide Day or Show Day, or the column's toggle shows or hides the day column. | `state`, `trigger` |
| `Calendar.weekOpened` | W, View › Show Week or the column's Week button opens the week. | `trigger` |
| `Calendar.timeBlocked` | B, a drop on the calendar or a mail's own time sets 30 minutes aside. | `trigger` |
| `Calendar.invitationAnswered` | Accept, Tentative or Decline on an invitation card. | `answer` |
| `Undo.used` | A step taken back: Z, ⌘Z, Edit › Undo or a toast's Undo. | `trigger` |
| `Account.added` | An account is added (the demo replaced included). | `provider` |
| `Account.removed` | An account is removed. | `provider` |
| `HelpMeWrite.used` | A Help me write write ends: its reply is in, it was stopped (Stop, Esc, the reply going away) or it failed. One per write (⌘J, Write, a chip, Try again), never as the field is focused, and none for a reply the demo makes up on this Mac (its sheet says nothing is sent). With it, what the write worked from and how it was asked for, by kind, and where. | `aiProvider`, `ending`, `draft`, `instruction`, `retry`, `source` |
| `ReaderMode.switched` | Reader mode is switched on or off from the reader: the header's switch, ⇧⌘R, View › Reader Mode (a reader window's too). Never when Settings › Experimental's Offer reader mode moves it. | `value`, `trigger` |
| `ReaderMode.versionSwitched` | Show original or Show text on one message in reader mode. | `readerLine` |
| `Reader.quotedText` | A message's quoted text is shown or hidden: its Show quoted text mark, or “.”. Find opening it to show a match is none. | `state`, `trigger` |
| `Trackers.blocked` | Block trackers held trackers back in a conversation the reader shows (a message shown as its text version holds none). Once a conversation per window and run. | `trackers` |
| `Trackers.linkCleaned` | A link opened from a message, with Block trackers on, went without its tracking parameters. | none |
| `Attachment.used` | An attachment is opened in Quick Look (a click on its chip, Space) or its app (a double click, Open), saved (Download, Download all, Save As…), copied, or dragged out of the reader and dropped where it was taken (the Finder, a composer, the quick reply). | `attachmentAction`, `trigger` |
| `Account.permission` | The sign-in that asks an account for a permission on top of its mail ends: the server's sender rules (Allow… in Senders, a rule's Continue, Reconnect) or its calendar (the day column's Connect). | `permission`, `result`, `provider` |
| `SenderRule.removed` | A sender rule is removed with Settings › Accounts › Senders…'s −. | `provider` |
| `Performance.listRefresh` | The list applies a change from the store (`list.refresh`). One in 20, at most 20 of each kind an hour. Its number is milliseconds. | `duration` |
| `Performance.conversationOpen` | A conversation shows in the reader (`conversation.show`). Sampled as above. | `duration` |
| `Performance.search` | A search's first page is in the list (`list.search`). Sampled as above. | `duration` |

Every value a parameter can take:

| Parameter | Values |
|---|---|
| `mode` | `demo`, `accounts` |
| `launchTime` | `<0.5s`, `0.5-1s`, `1-2s`, `2-5s`, `5s+` |
| `gmailAccounts`, `microsoftAccounts` | `0`, `1`, `2`, `3-5`, `6+` |
| `theme` | `study`, `gallery`, `rain`, `grove`, `dusk` |
| `appearance` | `automatic`, `light`, `dark` |
| `density` | `standard`, `compact` |
| `textSize` | `small`, `default`, `large`, `larger` |
| `font` | `newYork`, `sfPro` |
| `setting` | `listDensity`, `accountFaces`, `undoSend`, `remoteImages`, `notifications`, `notificationPreviews`, `keepMail`, `theme`, `appearance`, `font`, `textSize`, `adaptMailColours`, `sendAction`, `launchAtLogin`, `defaultMailApp`, `offerReaderMode`, `blockTrackers`, `aiProvider`, `accountFace` |
| `value` | the setting's own: the values of `density`, `theme`, `appearance`, `font` and `textSize` above; `on`, `off` (Mail links only `on`: the app cannot hand the role back); `5s`, `10s`, `20s`, `other` (Undo send); `everything`, `oneYear`, `threeMonths` (Keep mail); `sendAndArchive`, `send`; the values of `aiProvider` below, or `off` (Settings › AI's Provider); `automatic`, `monogram`, `paper` (an account's Face: never which paper face, nor whose account). For `ReaderMode.switched`, `on` or `off` |
| `action` | `archive`, `trash`, `spam`, `moveToInbox`, `star`, `unstar`, `markRead`, `markUnread`, `later`, `mute`, `unmute`, `unsubscribe`, `alwaysArchiveSender`, `blockSender` |
| `trigger` | `key`, `menu` (the menu bar, a context menu, the title menu), `toolbar` (a button in the reader or the calendar, the reader header's Reader switch, a message's own controls: an attachment's chip and Download, Show quoted text), `swipe`, `drag` (rows dropped on a rail folder or the calendar, files or a message's attachments dropped on the quick reply, an attachment dragged out of the reader), `click` (a double-click: a row, an attachment's chip), `rail` (a click on the account rail), `toast`, `notification` |
| `conversations` | `0` (Always Archive only: the rule set for a sender no Inbox holds; every other action that takes nothing sends nothing), `1`, `2-5`, `6-20`, `21+` |
| `kind` | `new`, `reply`, `replyAll`, `forward`, `draft` (a kept draft opened again) |
| `origin` | `app`, `mailLink`, `service` |
| `archives` | `on`, `off` (Send and Archive) |
| `source` | `composer`, `quickReply`, `sendLater` (Help me write: `composer` or `quickReply`, where the write ran) |
| `operators` | `0`, `1`, `2`, `3+` (every term but a plain word or phrase, and every negated term; the words are counted, never sent) |
| `results` | `0`, `1-10`, `11-50`, `51-199`, `200+` (a search's first page holds 200; for the server, the conversations it added) |
| `outcome` | `found`, `nothing`, `failed` |
| `searchTime` | `<0.5s`, `0.5-1s`, `1-2s`, `2-5s`, `5-10s`, `10s+` |
| `view` | `inbox`, `starred`, `sent`, `drafts`, `trash`, `all`, `later`, `outbox` |
| `scope` | `unified` (All Inboxes), `account` (one account, never which) |
| `state` | `shown`, `hidden` (the day column; a message's quoted text) |
| `answer` | `accept`, `tentative`, `decline` |
| `provider` | `gmail`, `microsoft` |
| `aiProvider` | `claudeAPI`, `claudeCode`, `openAIAPI`, `codex` (the kind of provider chosen in Settings › AI, never the model) |
| `ending` | `finished`, `stopped`, `failed` |
| `draft` | `empty` (nothing typed: written from the conversation), `notes` (from the user's notes), `selection` (a selection rewritten) |
| `instruction` | `on`, `off` (an instruction came with it: the prompt line's words or a chip; never the words) |
| `retry` | `on`, `off` (Try again) |
| `readerLine` | `text` (the sender's text part), `extracted` (the text taken from the design), `snippet` (the preview text): each switched to Show original; `original` (the message as sent, switched back with Show text) |
| `trackers` | `1`, `2-5`, `6-20`, `21+` |
| `attachmentAction` | `quickLook`, `open`, `download`, `downloadAll`, `saveAs`, `copy`, `drag` |
| `permission` | `rules`, `calendar` |
| `result` | `granted`, `notGranted` (refused, cancelled or failed) |
| `duration` | `<16ms`, `16-50ms`, `50-100ms`, `100-250ms`, `250ms-1s`, `1s+` |

`AnalyticsTests` holds every signal to this table and to the code's vocabulary.

### What TelemetryDeck adds

The SDK adds to every signal, on its own:

- **The app and the Mac:** app version and build; macOS version; the Mac's model identifier (for example `Mac16,11`) and architecture; screen resolution and scale; time zone; locale, region and languages; light or dark; Reduce Motion and Invert Colors; whether it is a debug, TestFlight or App Store build; the SDK's name and version.
- **When:** the exact time of each signal (UTC, to the second, as `receivedAt`), and the hour, day of week, day of month and year, week, month and quarter. With the session identifier (below), TelemetryDeck can line up one launch's signals in order, second by second.
- **Use over time:** the day of the first session, the number of sessions and distinct days used, and average and previous session lengths, counted on this Mac.
- **Who, anonymously:** a random identifier the SDK makes on first use and keeps in its own defaults (`com.telemetrydeck.<12 hex digits>`), hashed with SHA-256 on the Mac and hashed again with TelemetryDeck's own salt on its server; a random session identifier each launch. Paper never gives it an account's address or name.
- **Its own signals:** `TelemetryDeck.Session.started` at each launch, `TelemetryDeck.Acquisition.newInstallDetected` at the first, each with `mode`.
- **Each request:** the Mac's IP address, as any connection does, and in its headers the app's name and version and the CFNetwork and Darwin versions (`User-Agent`), and the preferred languages (`Accept-Language`).

TelemetryDeck says it stores no IP address ([privacy FAQ](https://telemetrydeck.com/docs/guides/privacy-faq/)) and keeps its servers in the EU.

### What is never sent

Mail of any kind (bodies, subjects, snippets, attachments, their names, types or sizes, links and their parameters, the trackers' addresses or senders), addresses and names (the user's, their accounts', anyone's), account names, monograms and signatures, search words, URLs and paths, calendar events' titles or times, anything of Help me write's but its provider's kind and how a write ended (no instruction, notes, reply, model, error words or API key), the Mac's name or the user's. Nothing is logged by the SDK beyond its errors.

## 4. Check it end to end

Without a TelemetryDeck account: debug builds take `--telemetry-url=<url>`, which sends this run's signals to that server instead of TelemetryDeck's, every 5 s rather than every 60, and `--analytics-check`, which (in the demo) takes a fixed round of the app's own steps once the inbox is in: opens Settings and switches the rows to Compact and back, stars and unstars, archives and undoes, goes to Starred and back to the Inbox, searches `is:unread lisbon` and the demo's server, opens a reader window, hides and shows the day column, opens the week and leaves it, and opens and closes a new message. Then it turns **Analytics and reports** off through the same setting (leaving crash reports' folder alone, which the bare binary shares with an installed copy that may be running), turns it on again, takes the same round again, and quits. Each step is logged with its time on standard error, so the listener's records can be matched to them. The listener must hold the first round and nothing after the switch: on again, analytics waits for the next launch.

```sh
swift build
# with a listener on 127.0.0.1:8978 that stores every POST body and answers 200:
.build/debug/Paper --demo --telemetry-app-id=LOCAL-CHECK --telemetry-url=http://127.0.0.1:8978 --analytics-check
```

The SDK posts a JSON array of signals (`type`, `appID`, `clientUser`, `sessionID`, `floatValue`, `payload`, `isTestMode`, `receivedAt`) to `<url>/v2/`. Search what it stored for the demo accounts' addresses and names: none may appear. (The bare binary has no Info.plist, so its signals say version 0, build 0. The locale TelemetryDeck sends can hold an `@`, as in `en_US@rg=gbzzzz`, a region chosen apart from the language.) The run's switch is saved in the bare binary's own defaults (`Paper`), so turn it back on afterwards (`defaults delete Paper sendsCrashReports`).

## Turning it off

**Settings → General → Analytics and reports.** At once, the current run included: nothing more is queued, the SDK and the signals it held in memory are dropped (a request already on its way finishes), Paper's own signals are deleted from the SDK's queue file (`~/Library/Caches/telemetrysignalcache`, written as the app quits and shared, by name, with every unsandboxed app embedding the SDK, so other apps' signals stay), and the SDK's defaults (its random identifier and session counts) are deleted, and once more 1.5 s later, after any write the SDK had begun.

**On again** in the same run, crash reports start at once, and analytics at the next launch, with a new identifier and no session history. The SDK keeps the run's session counts in an object that lives as long as the process and that stopping it does not reset: started again in the same run, it would send them under the new identifier, and write them back into the defaults just deleted. Turned on before analytics had started in the run (it starts when the app is first active), it starts at once.

**Leftovers.** A launch that finds the switch off deletes what an earlier run left for the build's app ID and for the one analytics last started with (kept in the app's defaults as `analyticsStartedAppID`): a stop that came as the app quit, or a write of the SDK's that landed after a stop. A build that sends to another app ID, or to none, deletes what the last one left.

**Other apps' signals.** The SDK reads the whole queue file as it starts, deletes it and sends every signal in it, whichever app queued it, and its write as the app quits replaces the file. So before it starts, Paper leaves only its own signals in the file and puts the others back once the SDK has read it; as Paper quits, what other apps have in the file then goes back beside the SDK's write. Paper never sends another app's signals. (This leans on NotificationCenter calling a notification's observers in the order they were added, as the stop as the app quits does; if it ever did not, those signals would be lost, never sent.)

## What it costs

Starting it reads the queue file (usually absent) on the main thread: about 0.3 ms (release, M4 Pro), and a signal costs the main thread about 0.1 ms before it is built off it. Signals are sent every 60 s. While Paper is the active app, the SDK keeps a 1 s timer on the main thread that records the session's length in its defaults (TelemetryDeck 2.x has no way to turn it off); it stops whenever the app goes behind. Once analytics has started in a run, the timer stays for the run: switched off, it keeps ticking while the app is active but writes nothing.

The SDK starts the first time Paper is the active app, not at launch: 2.x starts its session half a second after it starts, and when that session begins behind other apps, the timer it starts then is replaced without being stopped the next time the app comes to the front, and the old one then ticks every second for the rest of the run, behind other apps too. Starting while active avoids that for a launch at login, a launch behind other apps, or one the user clicked away from. Signals before then (the launch, a notification's Archive) are held, at most 100, and sent as it starts. One case is left: switching to another app within that half second after Paper first comes to the front. The fix belongs in the SDK (stop the timer before replacing it).
