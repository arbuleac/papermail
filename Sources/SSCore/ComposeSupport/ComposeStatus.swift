import Foundation

/// What the composer's bottom bar says on its trailing side (spec §5.20, Status). The copy lives here, next to
/// the rules for which status wins (`ComposeStatusBoard`), so both are tested without a window.
public enum ComposeStatus: Hashable, Sendable {
    /// Replying or forwarding while the original is fetched; a spinner after 150 ms.
    case loadingOriginal
    /// The original was deleted before it could be quoted.
    case originalGone
    /// The original's body could not be fetched, so nothing is quoted.
    case originalFailed
    /// Some of a forward's attachments could not be fetched.
    case attachmentsFailed(count: Int)
    /// A drop or Attach Files… brought folders or unreadable files; the readable files were attached.
    case rejectedDrop(RejectedDrop)
    /// A file that was readable when attached could not be read when the message was built.
    case unreadableAttachment(name: String)
    /// An attachment dragged from a message could not be fetched, so its chip was taken away again.
    case droppedAttachmentFailed(name: String)
    case saving
    case saved
    /// The sending account cannot reach its provider; a send waits in the outbox.
    case offline

    /// The items of one drop that were not attached.
    public struct RejectedDrop: Hashable, Sendable {
        public var folders: [String]
        public var unreadable: [String]

        public init(folders: [String] = [], unreadable: [String] = []) {
            self.folders = folders
            self.unreadable = unreadable
        }

        public var isEmpty: Bool { folders.isEmpty && unreadable.isEmpty }
        public var count: Int { folders.count + unreadable.count }
    }

    /// How the status is drawn: the glyph's colour family and the words' ink.
    public enum Tone: Hashable, Sendable {
        /// Glyph and words in `ink3`.
        case quiet
        /// `info.circle` in `ink3`, words in `ink2`.
        case info
        /// `exclamationmark.triangle.fill` in `warning`, words in `ink2`.
        case warning
    }

    public var text: String {
        switch self {
        case .loadingOriginal: return "Loading original message…"
        case .originalGone: return "The original message is no longer available."
        case .originalFailed: return "Couldn't load the original message; it won't be quoted."
        case .attachmentsFailed(let count):
            return count == 1 ? "One attachment couldn't be loaded." : "\(count) attachments couldn't be loaded."
        case .rejectedDrop(let drop):
            if drop.count == 1, let folder = drop.folders.first {
                return "Folders can't be attached: “\(folder)”."
            }
            if drop.count == 1, let file = drop.unreadable.first {
                return "“\(file)” couldn't be read, so it wasn't attached."
            }
            return "\(drop.count) items weren't attached: folders and unreadable files are skipped."
        case .unreadableAttachment(let name):
            return "“\(name)” couldn't be read. Remove it to send."
        case .droppedAttachmentFailed(let name):
            return "“\(name)” couldn't be downloaded, so it wasn't attached."
        case .saving: return "Saving…"
        case .saved: return "Draft saved"
        case .offline: return "Will send when you're back online"
        }
    }

    /// Every name a rejected drop skipped, for the status's tooltip; nil when the words already say it all.
    public var tooltip: String? {
        guard case .rejectedDrop(let drop) = self, drop.count > 1 else { return nil }
        return (drop.folders + drop.unreadable).joined(separator: "\n")
    }

    public var tone: Tone {
        switch self {
        case .originalFailed, .attachmentsFailed, .rejectedDrop, .unreadableAttachment, .droppedAttachmentFailed: return .warning
        case .originalGone: return .info
        case .loadingOriginal, .saving, .saved, .offline: return .quiet
        }
    }

    /// The SF Symbol before the words; nil for the spinner (loading) and for Saving…, which has no glyph.
    public var symbolName: String? {
        switch self {
        case .loadingOriginal, .saving: return nil
        case .originalGone: return "info.circle"
        case .originalFailed, .attachmentsFailed, .rejectedDrop, .unreadableAttachment, .droppedAttachmentFailed:
            return "exclamationmark.triangle.fill"
        case .saved: return "checkmark"
        case .offline: return "wifi.slash"
        }
    }

    public var showsSpinner: Bool { self == .loadingOriginal }

    /// Warnings stay until the user edits the body, so they are read, instead of giving way to the next
    /// Saving… or Draft saved.
    public var holdsUntilEdit: Bool { tone == .warning }
}
