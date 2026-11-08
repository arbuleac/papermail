import Foundation

/// The trailing status block of a Settings account row, one per account phase (spec §5.40, Account status):
/// a mark, the words in `snippet`, an optional determinate bar under them, an optional small secondary action
/// button, and for Sign in required the words that replace the address line.
///
/// The presets are the rows of the spec's table, with its words; build a custom one for anything else.
public struct QuireAccountStatus: Equatable, Sendable {
    public var mark: QuireAccountStatusMark
    /// The words beside the mark; nil when the block holds only its button.
    public var words: String?
    public var wordsColor: QuireColorToken
    /// 0…1 draws the 96 × 4 pt determinate bar 4 pt under the words, trailing-aligned with them.
    public var progress: Double?
    public var tooltip: String?
    /// The small secondary button's title (Reconnect, Cancel, Retry); the row calls its action.
    public var actionTitle: String?
    /// Words shown in place of the address line, after a danger triangle (Sign in required).
    public var addressReplacement: String?

    public init(mark: QuireAccountStatusMark = .none, words: String? = nil, wordsColor: QuireColorToken = .ink2,
                progress: Double? = nil, tooltip: String? = nil, actionTitle: String? = nil, addressReplacement: String? = nil) {
        self.mark = mark
        self.words = words
        self.wordsColor = wordsColor
        self.progress = progress
        self.tooltip = tooltip
        self.actionTitle = actionTitle
        self.addressReplacement = addressReplacement
    }

    // MARK: The spec's table

    /// Idle. `checked` is the time of the last check, for the tooltip (“Checked 23:41”).
    public static func upToDate(checked: String? = nil) -> QuireAccountStatus {
        QuireAccountStatus(mark: .glyph(Quire.Icon.success, .success), words: "Up to date", wordsColor: .ink2,
                           tooltip: checked.map { "Checked \($0)" })
    }

    /// Added; the engine has not reached it yet.
    public static let waitingToSync = QuireAccountStatus(mark: .glyph(Quire.Icon.waitingToSync, .ink3), words: "Waiting to sync",
                                                         wordsColor: .ink3)

    /// The first download. With a known total the words count both and the bar shows the fraction.
    public static func downloading(done: Int, total: Int?, locale: Locale = .current) -> QuireAccountStatus {
        let format = IntegerFormatStyle<Int>(locale: locale)
        if let total, total > 0 {
            return QuireAccountStatus(mark: .spinner, words: "Downloading · \(done.formatted(format)) of \(total.formatted(format))",
                                      progress: min(1, max(0, Double(done) / Double(total))))
        }
        return QuireAccountStatus(mark: .spinner, words: "Downloading · \(done.formatted(format)) messages")
    }

    /// Bodies, after the first download.
    public static let downloadingMessages = QuireAccountStatus(mark: .spinner, words: "Downloading messages…")

    /// A check the user asked for.
    public static let checking = QuireAccountStatus(mark: .spinner, words: "Checking for mail…")

    /// Rate limited, or unreachable while other accounts are online. `cause` is the tooltip
    /// (“Gmail is limiting requests.”).
    public static func retrying(inSeconds seconds: Int?, cause: String? = nil) -> QuireAccountStatus {
        QuireAccountStatus(mark: .glyph(Quire.Icon.retrying, .warning),
                           words: seconds.map { "Retrying in \($0) s" } ?? "Retrying shortly", tooltip: cause)
    }

    public static let offline = QuireAccountStatus(mark: .glyph(Quire.Icon.offline, .ink2), words: "Offline")

    /// The status block holds only Reconnect; the words replace the address line.
    public static let signInRequired = QuireAccountStatus(actionTitle: "Reconnect", addressReplacement: "Sign in required")

    /// Waiting for the browser during a reconnect: Sign in required stays (it is still true), Cancel replaces
    /// Reconnect.
    public static let reconnecting = QuireAccountStatus(mark: .spinner, words: "Waiting for your browser", actionTitle: "Cancel",
                                                        addressReplacement: "Sign in required")

    /// A sync error; `reason` in plain words is the tooltip.
    public static func error(reason: String? = nil) -> QuireAccountStatus {
        QuireAccountStatus(mark: .glyph(Quire.Icon.error, .danger), words: "Couldn't sync", wordsColor: .danger, tooltip: reason,
                           actionTitle: "Retry")
    }

    /// Mail is up to date, but an invitation the user answered waits for permission to update the calendar
    /// (spec §5.40, §5.14): Reconnect signs in again asking for it.
    public static let calendarPermission = QuireAccountStatus(
        mark: .glyph(Quire.Icon.invitation, .ink2), words: "Calendar permission needed", wordsColor: .ink2,
        tooltip: "Answer invitations: SuperSparrow needs permission to update your calendar.", actionTitle: "Reconnect"
    )

    public static let demo = QuireAccountStatus(mark: .glyph(Quire.Icon.demo, .ink3), words: "Made up, nothing syncs", wordsColor: .ink3)
}
