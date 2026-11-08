import Foundation
import SSCore

/// Mail links (`mailto:`) other apps hand the app, held until there is a main window to open them. A link that
/// launches the app (a click in Safari, Email in Contacts) arrives during launch, before the window has read its
/// accounts; it waits here and is opened, in order, once the app delegate sets the receiver. Anything that is not
/// a mail link is dropped.
@MainActor
final class MailLinkInbox {
    /// Links received while there was no receiver, oldest first.
    private(set) var pending: [MailtoLink] = []

    /// Opens one link. Setting it hands over every link that was waiting.
    var receiver: ((MailtoLink) -> Void)? {
        didSet { deliverPending() }
    }

    func receive(_ urls: [URL]) {
        pending += urls.compactMap(MailtoLink.init(url:))
        deliverPending()
    }

    private func deliverPending() {
        guard let receiver, !pending.isEmpty else { return }
        let links = pending
        pending = []
        links.forEach(receiver)
    }
}
