import Foundation
@testable import PaperApp

/// Stands in for `SMAppService.mainApp` in Settings › General's At login row, so no test reads or changes the Mac's real
/// login items. It counts what it is asked, and can hold a change open the way a slow answer from macOS would.
@MainActor
final class FakeLoginItem: LoginItemHandling {
    /// What `status()` answers.
    var answers: LoginItemStatus
    /// What `register()` and `unregister()` throw; nil succeeds.
    var failure: Error?
    /// The status a `register()` that does not throw leaves (macOS may hold the item for the user's approval, or still
    /// not find this copy).
    var registerLeaves: LoginItemStatus = .enabled
    /// Holds `register()` and `unregister()` until `release()`.
    var holdsChange = false

    private(set) var statusCalls = 0
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0
    private(set) var openSettingsCalls = 0
    private var held: CheckedContinuation<Void, Never>?

    init(_ answers: LoginItemStatus = .notRegistered) {
        self.answers = answers
    }

    func status() async -> LoginItemStatus {
        statusCalls += 1
        return answers
    }

    func register() async throws {
        registerCalls += 1
        if holdsChange { await withCheckedContinuation { held = $0 } }
        if let failure { throw failure }
        answers = registerLeaves
    }

    func unregister() async throws {
        unregisterCalls += 1
        if holdsChange { await withCheckedContinuation { held = $0 } }
        if let failure { throw failure }
        answers = .notRegistered
    }

    func openLoginItemsSettings() {
        openSettingsCalls += 1
    }

    var changeCalls: Int { registerCalls + unregisterCalls }

    func release() {
        held?.resume()
        held = nil
    }
}
