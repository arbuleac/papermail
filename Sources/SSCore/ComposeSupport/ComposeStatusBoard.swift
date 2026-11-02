import Foundation

/// Decides which `ComposeStatus` the composer shows (spec §5.20): a newer status replaces an older one,
/// except that a warning stays until the user edits the body. Loading the original outranks everything but a
/// held warning, and offline outranks the draft's own Saving… / Draft saved, because whether the message can
/// leave matters more than whether the draft was written to disk.
public struct ComposeStatusBoard: Equatable, Sendable {
    /// The newest status posted, until it is cleared or replaced.
    public private(set) var latest: ComposeStatus?
    /// A warning that has not yet met an edit of the body.
    public private(set) var heldWarning: ComposeStatus?
    public private(set) var isLoadingOriginal = false
    public private(set) var isOffline = false

    public init() {}

    /// What the bar shows now.
    public var current: ComposeStatus? {
        if let heldWarning { return heldWarning }
        if isLoadingOriginal { return .loadingOriginal }
        if isOffline { return .offline }
        return latest
    }

    public mutating func post(_ status: ComposeStatus) {
        switch status {
        case .loadingOriginal:
            isLoadingOriginal = true
        case .offline:
            isOffline = true
        default:
            if status.holdsUntilEdit { heldWarning = status }
            latest = status
        }
    }

    public mutating func finishLoadingOriginal() {
        isLoadingOriginal = false
    }

    public mutating func setOffline(_ offline: Bool) {
        isOffline = offline
    }

    /// The user typed in the body: held warnings have been seen, and Draft saved no longer describes the
    /// window (an unsaved edit follows it).
    public mutating func bodyEdited() {
        heldWarning = nil
        if latest?.holdsUntilEdit == true || latest == .saved { latest = nil }
    }

    /// Something other than the body changed (a recipient, the subject, an attachment): Draft saved is stale,
    /// but a warning about the body's content still waits for the body.
    public mutating func edited() {
        if latest == .saved { latest = nil }
    }

    /// Removes `status` if it is the latest one (Saving… once a save gives up, say).
    public mutating func clear(_ status: ComposeStatus) {
        if latest == status { latest = nil }
        if heldWarning == status { heldWarning = nil }
    }
}
