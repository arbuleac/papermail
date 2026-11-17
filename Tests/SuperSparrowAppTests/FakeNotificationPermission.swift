import Foundation
@testable import SuperSparrowApp

/// Stands in for `UNUserNotificationCenter` in Settings › General's Notifications line, so no test reads the Mac's real
/// notification settings, puts macOS's prompt up or opens System Settings. It counts what it is asked, and can hold the
/// prompt open the way a user who has not answered yet would.
@MainActor
final class FakeNotificationPermission: NotificationPermissionHandling {
    /// What `permission()` answers.
    var answers: NotificationPermission
    /// What answering the prompt leaves.
    var promptLeaves: NotificationPermission = .allowed
    /// Holds `request()` until `release()`.
    var holdsPrompt = false

    private(set) var permissionCalls = 0
    private(set) var requestCalls = 0
    private(set) var openSettingsCalls = 0
    private var held: CheckedContinuation<Void, Never>?

    init(_ answers: NotificationPermission = .allowed) {
        self.answers = answers
    }

    func permission() async -> NotificationPermission {
        permissionCalls += 1
        return answers
    }

    func request() async {
        requestCalls += 1
        if holdsPrompt { await withCheckedContinuation { held = $0 } }
        answers = promptLeaves
    }

    func openNotificationSettings() {
        openSettingsCalls += 1
    }

    func release() {
        held?.resume()
        held = nil
    }
}
