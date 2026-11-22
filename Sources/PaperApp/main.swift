import AppKit

// `--demo` opens a generated mailbox with two fake accounts; `--reset-demo` wipes it first.
MainActor.assumeIsolated {
    // First of all, before the settings, crash reports or analytics read or write anything: the first launch as Paper
    // brings over what the app kept under its old name (docs/ARCHITECTURE.md, "Identity"). The bundled app only.
    let identity = IdentityMigrationLaunch.run()
    let options = LaunchOptions()
    // The subclass reports what AppKit catches; asked for first, it is the one `NSApp` holds.
    let app = PaperApplication.shared
    // The old app is open on a mailbox not moved yet: this launch only asks for it to be quit.
    if IdentityMigrationLaunch.mustWait(for: identity) {
        let waiting = LegacyAppOpenDelegate()
        app.delegate = waiting
        app.setActivationPolicy(.regular)
        withExtendedLifetime(waiting) {
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
