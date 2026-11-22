import AppKit

/// The moments macOS tells the app about that change when mail should be checked. Paper coming to the
/// front checks at once and tells the engine, whose live lane checks every 5 s while the app is frontmost and
/// every 30 s otherwise; leaving the front tells it too. The Mac waking from sleep checks at once: polls do not
/// run while it sleeps, and the mail that arrived meanwhile should show on waking, not when the next poll was due.
/// The same check has the engine send a held message whose undo window ended while the Mac slept.
/// None of these is the user asking (`MailClient.checkForMail`, not `syncNow`): an account waiting for sign-in
/// keeps waiting, rather than bring back a keychain prompt nobody may be there to answer.
///
/// Apart from `AppDelegate`, which builds its environments privately, so the tests post these notifications on
/// their own centers and count the calls.
@MainActor
final class AppWakeups {
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    init(appCenter: NotificationCenter = .default, workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         setActive: @escaping @MainActor (Bool) -> Void, checkAll: @escaping @MainActor () -> Void) {
        observe(NSApplication.didBecomeActiveNotification, on: appCenter) {
            setActive(true)
            checkAll()
        }
        observe(NSApplication.didResignActiveNotification, on: appCenter) { setActive(false) }
        observe(NSWorkspace.didWakeNotification, on: workspaceCenter) { checkAll() }
    }

    /// Stops listening. The app's instance lives as long as the app; tests call this between cases.
    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }

    private func observe(_ name: Notification.Name, on center: NotificationCenter, _ action: @escaping @MainActor () -> Void) {
        // The main queue delivers on the main thread whichever thread posts.
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
        observers.append((center, token))
    }
}
