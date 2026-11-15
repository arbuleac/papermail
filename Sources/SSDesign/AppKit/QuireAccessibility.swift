import AppKit

/// VoiceOver notifications the components post (spec §4.14): value changes NSButton would announce, and the
/// spoken copies of slips, field errors and search counts, and the app's own announcements (a copied address, §5.14).
/// One place, so everything speaks the same way and tests can listen in.
@MainActor
public enum QuireAccessibility {
    /// Tests set this to hear what would be posted; nil in the app.
    static var observer: ((NSAccessibility.Notification, String?) -> Void)?

    /// A checkbox, radio, switch or toggling icon button changed its value.
    static func valueChanged(_ element: Any) {
        observer?(.valueChanged, nil)
        NSAccessibility.post(element: element, notification: .valueChanged)
    }

    /// Speaks `text` now, ahead of what VoiceOver was reading (`priority` high) or after it (medium).
    public static func announce(_ text: String, from element: Any, priority: NSAccessibilityPriorityLevel = .high) {
        guard !text.isEmpty else { return }
        observer?(.announcementRequested, text)
        NSAccessibility.post(element: element, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: priority.rawValue,
        ])
    }

    /// A keycap legend as VoiceOver should say it: “⌘Z” is “Command-Z”, “⇧⌘R” is “Shift-Command-R”.
    static func spoken(keycap: String) -> String {
        let names: [Character: String] = ["⌃": "Control-", "⌥": "Option-", "⇧": "Shift-", "⌘": "Command-", "↩": "Return", "⌫": "Delete"]
        return keycap.map { names[$0] ?? String($0) }.joined()
    }

    /// A sentence ends with a full stop (or the mark it already has).
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return trimmed }
        return ".!?…".contains(last) ? trimmed : trimmed + "."
    }
}
