import AppKit

// `--demo` opens a generated mailbox with two fake accounts; `--reset-demo` wipes it first.
MainActor.assumeIsolated {
    // First of all, before the settings, crash reports or analytics read or write anything: the first launch as Paper
    // brings over what the app kept under its old name (docs/ARCHITECTURE.md, "Identity"). The bundled app only.
    let identity = IdentityMigrationLaunch.run()
    let options = LaunchOptions()
    // The subclass reports what AppKit catches; asked for first, it is the one `NSApp` holds.
    let app = PaperApplication.shared
    // The old app is open on a mailbox not moved yet, or the move could not bring it over: this launch opens nothing (a
    // mailbox started in the new folder would leave the old one where it is for good), it only says why, and quits.
    if let alert = AppAlert.identityHold(for: identity) {
        let holding = IdentityHoldDelegate(outcome: identity, alert: alert)
        app.delegate = holding
        app.setActivationPolicy(.regular)
        withExtendedLifetime(holding) {
            app.run()
        }
        return
    }
    // Before anything else of the app's, so a crash at launch is reported too (docs/ARCHITECTURE.md, "Crash reports"),
    // but after the application object: making it sets AppKit's own uncaught-exception handler, which would replace the
    // crash reporter's and leave an exception on another thread reported as a bare SIGABRT, without its name or reason.
    CrashReporting.start(launch: options)
    // Analytics follows the same switch (docs/ARCHITECTURE.md, "Analytics"). It takes signals from here, but starts the
    // SDK only once the app is active, so the SDK's session begins in front (`Analytics`); turned off, it deletes what an
    // earlier run left.
    Analytics.start(launch: options)
    let delegate = AppDelegate(options: options)
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    // NSApplication holds its delegate weakly; this scope never ends while the app runs.
    withExtendedLifetime(delegate) {
        app.run()
    }
}
