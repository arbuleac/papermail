import AppKit
import Foundation
import Sentry

/// `--crash-test=<kind>` (debug builds): ends or stalls the app on purpose so a report can be followed from the crash
/// to Sentry (docs/ANALYTICS-AND-REPORTS.md). The SDK sends a crash at the next launch; an error or a hang at once.
enum CrashTest {
    enum Kind: String, CaseIterable {
        /// The SDK's own test crash (a bad memory access).
        case crash
        /// A Swift runtime trap, as a force-unwrapped nil or an index out of range ends the app.
        case fatal
        /// An Objective-C exception no one catches, thrown on a background queue.
        case exception
        /// An exception AppKit catches on the main thread: reported as an error, and the app goes on.
        case appkitException = "appkit-exception"
        /// The main thread blocked for 5 s, then the app goes on.
        case hang
    }

    #if DEBUG
    @MainActor
    static func run(_ kind: Kind) {
        // After launch has settled, so the report carries the launch's breadcrumbs and the session it ends.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            CrashReporting.breadcrumb(.app, "crash test")
            switch kind {
            case .crash:
                SentrySDK.crash()
            case .fatal:
                let nothing: Int? = Int("not a number")
                _ = nothing!
            case .exception:
                DispatchQueue.global().async {
                    NSException(name: .internalInconsistencyException, reason: "SuperSparrow crash test", userInfo: nil).raise()
                }
            case .appkitException:
                // Thrown by `SuperSparrowApplication.sendEvent(_:)`: inside AppKit's event dispatch, not a dispatch block.
                if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: 0, context: nil, subtype: appKitEventSubtype, data1: 0, data2: 0) {
                    NSApp.postEvent(event, atStart: false)
                }
            case .hang:
                Thread.sleep(forTimeInterval: 5)
            }
        }
    }

    /// The application-defined event `--crash-test=appkit-exception` posts ("SS").
    static let appKitEventSubtype: Int16 = 0x5353
    #endif
}
