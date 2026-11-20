import AppKit
import Foundation

/// The app's life as breadcrumbs for crash reports (`CrashReporting`): coming to the front and going behind, the Mac
/// sleeping and waking, windows becoming key and closing (by their controller's type), memory pressure, quitting.
/// Actions come from `SuperSparrowApplication`. Nothing here reads a title, a field or a row.
@MainActor
final class CrashBreadcrumbs {
    private var observers: [NSObjectProtocol] = []
    private var memoryPressure: DispatchSourceMemoryPressure?

    init() {}

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let app: [(Notification.Name, StaticString)] = [
            (NSApplication.didBecomeActiveNotification, "became active"),
            (NSApplication.didResignActiveNotification, "went behind"),
            (NSApplication.willTerminateNotification, "quitting"),
        ]
        for (name, message) in app {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                CrashReporting.breadcrumb(.app, message)
            })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            CrashReporting.breadcrumb(.app, "Mac going to sleep")
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            CrashReporting.breadcrumb(.app, "Mac woke")
        })
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { CrashReporting.breadcrumb("key", window: window) }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { CrashReporting.breadcrumb("closing", window: window) }
        })
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak source] in
            guard let event = source?.data else { return }
            if event.contains(.critical) {
                CrashReporting.breadcrumb(.memory, "memory pressure critical")
            } else {
                CrashReporting.breadcrumb(.memory, "memory pressure warning")
            }
        }
        source.resume()
        memoryPressure = source
    }
}
