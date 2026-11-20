# Crash reporting

SuperSparrow sends crashes, exceptions and hangs to [Sentry](https://sentry.io) through Sentry's Cocoa SDK. What a report holds, what never leaves the Mac and why are in [ARCHITECTURE.md](ARCHITECTURE.md), "Crash reports". This page sets it up and checks it.

A build without a Sentry project still runs; it sends nothing, and **Settings → General → Crash reports** says "Not set up in this build."

## 1. Create the project (once)

1. Sign in at [sentry.io](https://sentry.io) and create an organization. Choose the **EU** data region if you want reports kept in the EU. The region cannot be changed later.
2. **Projects → Create Project**, platform **Apple → macOS**, name it `supersparrow-macos`.
3. Under **Settings → Projects → supersparrow-macos → Client Keys (DSN)**, copy the DSN. It looks like `https://<key>@o<org>.ingest.<region>.sentry.io/<project>`. A DSN only lets an app send reports, so it is not a secret, but keep it out of a public repository so strangers cannot fill your quota.
4. Optional, recommended: under **Settings → Projects → supersparrow-macos → Security & Privacy**, turn on **Data Scrubber** and **Prevent Storing of IP Addresses**. The app already scrubs reports before they leave; this is a second net on the server.

## 2. Build with it

Put the DSN in the untracked file `Resources/SentryDSN`. `.gitignore` keeps it out of git.

```sh
echo 'https://<key>@o<org>.ingest.<region>.sentry.io/<project>' > Resources/SentryDSN
scripts/build-app.sh debug        # or release; SENTRY_DSN=… scripts/build-app.sh also works
```

`scripts/build-app.sh` writes it into the bundle's Info.plist as `SentryDSN` and writes the build's debug symbols to `dist/SuperSparrow.app.dSYM`.

## 3. Upload symbols (each build you run)

Without symbols, Sentry shows the app's own frames as image offsets. To upload them:

1. Install `sentry-cli` as the standalone binary from its [releases](https://github.com/getsentry/sentry-cli/releases). Use the `sentry-cli-Darwin-universal` asset; put it on your `PATH` as `sentry-cli` and `chmod +x` it. No npm or Homebrew.
2. Create an auth token under **Settings → Account → Personal Tokens** (scope `project:releases` and `project:write`), then:

```sh
export SENTRY_AUTH_TOKEN=… SENTRY_ORG=<your org slug> SENTRY_PROJECT=supersparrow-macos
scripts/upload-dsyms.sh                    # add --include-sources to show source lines in Sentry
```

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
dist/SuperSparrow.app/Contents/MacOS/SuperSparrow --demo --crash-test=crash
open dist/SuperSparrow.app --args --demo     # the next launch sends the crash
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
- **Turning it off:** **Settings → General → Crash reports → Send to Sentry**. This takes effect at once, the current run included, and deletes reports still queued on disk (`~/Library/Caches/io.supersparrow.mac/Sentry`), so none goes later.
