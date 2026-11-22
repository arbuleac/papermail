import Foundation

/// What saving attachments to Downloads came to (spec §5.17), and the toast that says so (§5.30): the chip's Download,
/// Save to Downloads in its menu, Download all and File › Download Attachments all end here.
///
/// A file that could not be fetched is not the toast's to report: its chip already says “Couldn't download · Retry”.
/// A file that arrived but could not be written to Downloads has nowhere else to say so, so the toast does.
public struct AttachmentSaveOutcome: Equatable, Sendable {
    /// How many files were asked for.
    public var requested: Int
    /// Where the saved copies are, in the order they were asked for: what Show in Finder selects.
    public var saved: [URL]
    /// How many could not be fetched; their chips show the Error state.
    public var unfetched: Int

    public init(requested: Int, saved: [URL], unfetched: Int) {
        self.requested = requested
        self.saved = saved
        self.unfetched = unfetched
    }

    /// Files that arrived but could not be written to Downloads (a full disk, a folder that cannot be written).
    public var unwritten: Int { max(0, requested - saved.count - unfetched) }

    /// The toast after the save, or nil when there is nothing a toast should add.
    public enum Toast: Equatable, Sendable {
        /// “Saved 3 attachments to Downloads”, with Show in Finder: a notice, nothing to undo.
        case saved(String)
        /// “Couldn't save to Downloads”: an error, no action.
        case failed(String)
    }

    /// The words: the longest form `fits` says the list shows whole beside Show in Finder, so the count is never what
    /// is cut off. “Saved 3 attachments to Downloads”, then “Saved 3 to Downloads”; for a partial save “Saved 2 of 3
    /// attachments to Downloads”, “Saved 2 of 3 to Downloads”, then “Saved 2 of 3” (the default list is too narrow for
    /// the second beside the action). Nothing saved because nothing could be fetched gives no toast: the chips say it.
    public func toast(fits: (String) -> Bool = { _ in true }) -> Toast? {
        guard !saved.isEmpty else {
            return unwritten > 0 ? .failed(Self.notSaved) : nil
        }
        if requested == 1 { return .saved(Self.savedOne) }
        let forms = Self.forms(saved.count, of: requested)
        return .saved(forms.first(where: fits) ?? forms[forms.count - 1])
    }

    public static let savedOne = "Saved to Downloads"
    public static let notSaved = "Couldn\u{2019}t save to Downloads"
    /// The toast's action (§5.30): sentence case, as a slip's actions are (§4.13).
    public static let showInFinder = "Show in Finder"

    /// The toast's words for `count` of `requested` files, longest first.
    static func forms(_ count: Int, of requested: Int) -> [String] {
        let n = count.formatted(.number.grouping(.automatic))
        guard count < requested else { return ["Saved \(n) attachments to Downloads", "Saved \(n) to Downloads"] }
        let some = "Saved \(n) of \(requested.formatted(.number.grouping(.automatic)))"
        return [some + " attachments to Downloads", some + " to Downloads", some]
    }
}
