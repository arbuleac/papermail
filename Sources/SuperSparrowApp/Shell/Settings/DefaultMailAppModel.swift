import Foundation
import os

/// Settings › General › Mail links (spec §5.40): whether SuperSparrow opens mail links from other apps, and the
/// button that asks macOS to make it. The answer comes from `MailtoDefaultHandling`, asked again whenever the row
/// appears and the app comes to the front, since the user can choose another mail app elsewhere meanwhile.
@MainActor
final class DefaultMailAppModel: ObservableObject {
    enum State: Equatable {
        /// Not answered yet: the row shows nothing rather than a guess.
        case unknown
        case isDefault
        case notDefault
        /// Waiting for macOS, which asks the user to confirm; the button is disabled meanwhile.
        case setting
        /// An attempt failed: the button stays, with the failure in words under it, until an attempt succeeds or
        /// SuperSparrow is found to be the default. A retry the user declines leaves it here.
        case failed
    }

    /// What the row shows: the words, or the button, and a failure under it.
    struct Row: Equatable {
        /// SuperSparrow opens mail links: said in plain words, with the success glyph.
        var words: String?
        var buttonTitle: String?
        var isButtonEnabled = false
        /// In `danger` under the row (§5.25's help line), never an alert.
        var failure: String?
    }

    static let isDefaultWords = "SuperSparrow is your default mail app."
    static let buttonTitle = "Set as Default Mail App"
    static let failureWords = "Couldn't make SuperSparrow the default mail app. You can also choose it in Mail › Settings › General."

    private static let log = Logger(subsystem: "io.supersparrow.mac", category: "shell")

    @Published private(set) var state: State = .unknown
    private let handler: MailtoDefaultHandling
    /// Bumped by every request, so an older answer arriving late never overwrites a newer one.
    private var generation = 0
    /// A snapshot set the state; the row appearing must not ask over it.
    private var isPinnedForSnapshot = false
    /// `setting` began from `failed`: the failure's words stay under the disabled button while macOS asks, so the row
    /// neither loses them nor shrinks under the dialog.
    private var isRetryingAfterFailure = false

    init(handler: MailtoDefaultHandling) {
        self.handler = handler
    }

    var row: Row {
        switch state {
        case .unknown: return Row()
        case .isDefault: return Row(words: Self.isDefaultWords)
        case .notDefault: return Row(buttonTitle: Self.buttonTitle, isButtonEnabled: true)
        case .setting:
            return Row(buttonTitle: Self.buttonTitle, isButtonEnabled: false, failure: isRetryingAfterFailure ? Self.failureWords : nil)
        case .failed: return Row(buttonTitle: Self.buttonTitle, isButtonEnabled: true, failure: Self.failureWords)
        }
    }

    /// Asks which app opens mail links. A failure's words stay until SuperSparrow is found to be the default.
    func refresh() {
        guard state != .setting, !isPinnedForSnapshot else { return }
        generation += 1
        let asked = generation
        let handler = handler
        Task { [weak self] in
            let isDefault = await handler.isDefault()
            guard let self, self.generation == asked else { return }
            if isDefault {
                self.state = .isDefault
            } else if self.state != .failed {
                self.state = .notDefault
            }
        }
    }

    /// The button: asks macOS once, then shows what LaunchServices answers afterwards. Declining in macOS's own
    /// confirmation is the user's choice, not a failure, so it brings the button back without new words; an earlier
    /// failure's words stay, since no attempt has succeeded.
    func makeDefault() {
        guard state != .setting, state != .isDefault else { return }
        generation += 1
        let asked = generation
        let retrying = state == .failed
        isRetryingAfterFailure = retrying
        state = .setting
        let handler = handler
        Task { [weak self] in
            var failure: Error?
            do {
                try await handler.makeDefault()
            } catch {
                failure = error
            }
            let isDefault = await handler.isDefault()
            guard let self, self.generation == asked else { return }
            if isDefault {
                self.state = .isDefault
            } else if let failure, !Self.isCancellation(failure) {
                let error = failure as NSError
                Self.log.error("default mail app not set: \(error.domain, privacy: .public) \(error.code, privacy: .public)")
                self.state = .failed
            } else {
                self.state = retrying ? .failed : .notDefault
            }
        }
    }

    /// `--snapshot-settings-states` only: shows a state without asking or changing anything.
    func showForSnapshot(_ state: State) {
        generation += 1
        isPinnedForSnapshot = true
        isRetryingAfterFailure = false
        self.state = state
    }

    private static func isCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        // userCanceledErr (-128), the Carbon code LaunchServices may report when the user keeps the current app.
        return (error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError)
            || (error.domain == NSOSStatusErrorDomain && error.code == -128)
    }
}
