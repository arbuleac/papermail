import Foundation
import SSCore

/// The browser sign-in that is running, for the surfaces that show it (spec §5.44): the rail's pending tile,
/// the sync line's “Finish signing in in your browser · Gmail” with Cancel, and Settings' pending row. The app
/// delegate posts `didChange` with the current value as the notification's object (nil when none runs), so
/// those surfaces can follow it without the app delegate knowing their views.
struct SignInProgress: Equatable {
    /// Posted on the main thread whenever a sign-in starts or ends; `object` is the `SignInProgress?`.
    static let didChange = Notification.Name("SignInProgress.didChange")

    let kind: ProviderKind
    /// The account being reconnected; nil while adding a new one.
    let reconnecting: AccountID?
    /// What the sync line names: the provider while adding (“Gmail”), the account's name while reconnecting.
    let subject: String
}
