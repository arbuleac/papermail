import Foundation

extension QuireUndoPanelView {
    /// The panel states of spec §5.31.
    public enum State: Equatable, Sendable {
        /// “Sending in 4 s” over the message summary, `paperplane.fill`, the outlined Undo with “⌘Z”, and the
        /// contrail draining over the undo window. Hover does not pause it: the send time is a promise.
        case counting(secondsLeft: Int)
        /// A 16 pt `onSlip2` spinner in the glyph's place, “Sending…”, no action.
        case sending
        /// `checkmark` + “Sent” for 1500 ms, then the panel fades.
        case sent
        /// `checkmark` + “Already sent” / “Undo came after the message left.” for 3000 ms.
        case undoTooLate
        /// `exclamationmark.triangle.fill` + “Couldn't send” / “Your draft is kept on this Mac” + “Open draft”.
        case failed

        /// The first line (`bodyMedium`, tabular, `onSlip`).
        public var title: String {
            switch self {
            case .counting(let seconds): return "Sending in \(max(0, seconds)) s"
            case .sending: return "Sending…"
            case .sent: return "Sent"
            case .undoTooLate: return "Already sent"
            case .failed: return "Couldn't send"
            }
        }

        /// The second line, when the state replaces the message summary.
        public var fixedSubtitle: String? {
            switch self {
            case .undoTooLate: return "Undo came after the message left."
            case .failed: return "Your draft is kept on this Mac"
            case .counting, .sending, .sent: return nil
            }
        }

        /// The glyph; nil while the spinner takes its place.
        public var symbolName: String? {
            switch self {
            case .counting: return Quire.Icon.sendPanel
            case .sending: return nil
            case .sent, .undoTooLate: return Quire.Icon.upToDate
            case .failed: return Quire.Icon.error
            }
        }

        /// The action's words (sentence case, slip content, §4.13), when the state has one.
        public var actionTitle: String? {
            switch self {
            case .counting: return "Undo"
            case .failed: return "Open draft"
            case .sending, .sent, .undoTooLate: return nil
            }
        }
    }
}
