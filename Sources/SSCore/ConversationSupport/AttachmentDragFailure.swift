import Foundation

/// Why a dragged attachment did not arrive where it was dropped outside the app (spec §5.17, Dragging out), and the error
/// toast that says so (§5.30): the drop asks for the file once it lands, and the reader's window says what went wrong.
public enum AttachmentDragFailure: Error, Equatable, Sendable {
    /// The file could not be fetched (offline, or the server no longer has it). The chip shows its Error state too.
    case unfetched
    /// The file arrived but could not be written there (a full disk, a folder that cannot be written, a volume that keeps
    /// no quarantine mark).
    case unwritten

    /// “Couldn't download “plan.pdf””, or without the name when `fits` says the toast cannot show it whole.
    public func toast(filename: String, fits: (String) -> Bool = { _ in true }) -> String {
        let named: String
        let plain: String
        switch self {
        case .unfetched:
            named = "Couldn\u{2019}t download \u{201C}\(filename)\u{201D}"
            plain = "Couldn\u{2019}t download the attachment"
        case .unwritten:
            named = "Couldn\u{2019}t save \u{201C}\(filename)\u{201D}"
            plain = "Couldn\u{2019}t save the attachment"
        }
        return !filename.isEmpty && fits(named) ? named : plain
    }
}
