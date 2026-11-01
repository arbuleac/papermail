import AppKit

// `--demo` opens a generated mailbox with two fake accounts; `--reset-demo` wipes it first.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(options: LaunchOptions())
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    // NSApplication holds its delegate weakly; this scope never ends while the app runs.
    withExtendedLifetime(delegate) {
        app.run()
    }
}
