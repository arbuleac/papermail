import Foundation
@testable import SuperSparrowApp

/// Stands in for LaunchServices in Settings › General's Mail links row, so no test reads or changes the Mac's real
/// default mail app. It counts what it is asked, and can hold `makeDefault` open the way macOS's confirmation does.
@MainActor
final class FakeMailtoHandler: MailtoDefaultHandling {
    /// What `isDefault()` answers.
    var answersDefault = false
    /// What `makeDefault` throws; nil succeeds.
    var failure: Error?
    /// Whether a `makeDefault` that does not throw makes this app the default (false: the user kept the other app).
    var setMakesDefault = true
    /// Holds `makeDefault` until `release()`, as macOS's confirmation does while it waits for the user.
    var holdsSet = false

    private(set) var isDefaultCalls = 0
    private(set) var makeDefaultCalls = 0
    private var held: CheckedContinuation<Void, Never>?

    init(isDefault: Bool = false) {
        answersDefault = isDefault
    }

    func isDefault() async -> Bool {
        isDefaultCalls += 1
        return answersDefault
    }

    func makeDefault() async throws {
        makeDefaultCalls += 1
        if holdsSet {
            await withCheckedContinuation { held = $0 }
        }
        if let failure { throw failure }
        if setMakesDefault { answersDefault = true }
    }

    func release() {
        held?.resume()
        held = nil
    }
}
