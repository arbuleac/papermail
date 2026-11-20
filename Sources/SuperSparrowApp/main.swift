import AppKit

// `--demo` opens a generated mailbox with two fake accounts; `--reset-demo` wipes it first.
MainActor.assumeIsolated {
    let options = LaunchOptions()
    // The subclass reports what AppKit catches; asked for first, it is the one `NSApp` holds.
    let app = SuperSparrowApplication.shared
    // Before anything else of the app's, so a crash at launch is reported too (docs/ARCHITECTURE.md, "Crash reports"),
    // but after the application object: making it sets AppKit's own uncaught-exception handler, which would replace the
    // crash reporter's and leave an exception on another thread reported as a bare SIGABRT, without its name or reason.
    CrashReporting.start(launch: options)
    let delegate = AppDelegate(options: options)
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    // NSApplication holds its delegate weakly; this scope never ends while the app runs.
    withExtendedLifetime(delegate) {
        app.run()
    }
}
