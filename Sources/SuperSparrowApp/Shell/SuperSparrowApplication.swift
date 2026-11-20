import AppKit

/// The app's `NSApplication` (main.swift asks for it first, so `NSApp` is this one; Info.plist's `NSPrincipalClass`
/// names it too). It reports what crash reporting cannot see from outside (docs/ARCHITECTURE.md, "Crash reports"): an
/// exception AppKit caught on the main thread, which it only logs before going on, and every action sent, as a
/// breadcrumb holding the selector's name.
@objc(SuperSparrowApplication)
final class SuperSparrowApplication: NSApplication {
    override func reportException(_ exception: NSException) {
        CrashReporting.reportCaughtException(exception)
        super.reportException(exception)
    }

    override func sendAction(_ action: Selector, to target: Any?, from sender: Any?) -> Bool {
        CrashReporting.breadcrumb(action: action)
        return super.sendAction(action, to: target, from: sender)
    }

    #if DEBUG
    /// `--crash-test=appkit-exception` throws while AppKit dispatches an event, where AppKit catches what is thrown.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .applicationDefined, event.subtype.rawValue == CrashTest.appKitEventSubtype {
            NSException(name: .invalidArgumentException, reason: "SuperSparrow crash test (caught by AppKit)", userInfo: nil).raise()
        }
        super.sendEvent(event)
    }
    #endif
}
