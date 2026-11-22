import Foundation
import PaperCore

/// The browser sign-in that is running, for the surfaces that show it (spec §5.44): the welcome screen's
/// waiting button, the rail's pending tile, the sync line's “Finish signing in in your browser · Gmail” with
/// Cancel, and Settings' pending row. The app delegate posts every change with `post(_:)`; the surfaces follow
/// `didChange` (and read `current` when they are built mid-sign-in), so they show what is really running
/// without the app delegate knowing their views.
struct SignInProgress: Equatable {
    /// Posted on the main thread whenever a sign-in starts or ends; `object` is the `SignInProgress?`.
    static let didChange = Notification.Name("SignInProgress.didChange")

    /// The sign-in running now, if any.
    @MainActor private(set) static var current: SignInProgress?

    let kind: ProviderKind
    /// The account being reconnected; nil while adding a new one.
    let reconnecting: AccountID?
    /// What the sync line names: the provider while adding (“Gmail”), the account's name while reconnecting.
    let subject: String

    /// Records `progress` as the current sign-in and tells every surface.
    @MainActor static func post(_ progress: SignInProgress?) {
        current = progress
        NotificationCenter.default.post(name: didChange, object: progress)
    }
}
