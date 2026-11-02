import AppKit
import SSCore
import SSDesign

/// The title menu popped from the masthead (spec §5.4): a system `NSMenu` with the six views, each with its
/// symbol and its G-sequence in a right-aligned `ink3` column (an attributed title, because `keyEquivalent`
/// cannot express a sequence), a checkmark on the current view and the Inbox unread count as a system badge.
/// In minimal mode it gains All Inboxes and the accounts, with their monograms, ⌘0…⌘9 and their counts.
@MainActor
enum TitleMenu {
    struct AccountEntry {
        var account: Account
        var monogram: String
        var unread: Int
    }

    struct Model {
        var view: MailboxView
        /// The unread Inbox count of the current scope (all accounts, or the narrowed one).
        var inboxUnread: Int
        var scope: AccountScope
        /// Minimal mode: the rail is hidden, so the menu carries the accounts.
        var showsAccounts: Bool
        var unifiedUnread: Int
        var accounts: [AccountEntry]
    }

    static let entries: [(view: MailboxView, title: String, symbol: String, sequence: String)] = [
        (.inbox, "Inbox", Quire.Icon.viewInbox, "G I"),
        (.starred, "Starred", Quire.Icon.viewStarred, "G S"),
        (.sent, "Sent", Quire.Icon.viewSent, "G T"),
        (.drafts, "Drafts", Quire.Icon.viewDrafts, "G D"),
        (.trash, "Trash", Quire.Icon.viewTrash, "G #"),
        (.all, "All Mail", Quire.Icon.viewAllMail, "G A"),
    ]

    static func title(for view: MailboxView) -> String {
        entries.first { $0.view == view }?.title ?? "Inbox"
    }

    /// Builds the menu. View items carry `MailboxView.allCases` indices as tags; account items carry the
    /// ⌘ number (0 for All Inboxes).
    static func build(_ model: Model, target: AnyObject, viewAction: Selector, scopeAction: Selector) -> NSMenu {
        let menu = NSMenu(title: "Mailbox")
        menu.autoenablesItems = false
        let font = NSFont.menuFont(ofSize: 0)
        let titleWidth = entries.map { ceil(($0.title as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
        let sequenceWidth = entries.map { ceil(($0.sequence as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
        // Room after the longest title for a badge, then the sequence column ending on the tab stop.
        let tabStop = titleWidth + 56 + sequenceWidth
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: tabStop)]

        for (index, entry) in entries.enumerated() {
            if entry.view == .all { menu.addItem(.separator()) }
            let item = NSMenuItem(title: entry.title, action: viewAction, keyEquivalent: "")
            item.target = target
            item.tag = MailboxView.allCases.firstIndex(of: entry.view) ?? index
            let title = NSMutableAttributedString(string: entry.title, attributes: [.font: font, .paragraphStyle: style])
            title.append(NSAttributedString(string: "\t" + entry.sequence,
                                            attributes: [.font: font, .paragraphStyle: style, .foregroundColor: NSColor.qInk3]))
            item.attributedTitle = title
            item.image = QuireSymbol.image(entry.symbol, size: .inText, accessibilityDescription: entry.title)
            item.state = entry.view == model.view ? .on : .off
            if entry.view == .inbox, model.inboxUnread > 0 {
                item.badge = NSMenuItemBadge(count: model.inboxUnread)
            }
            item.setAccessibilityHelp("G then \(entry.sequence.dropFirst(2))")
            menu.addItem(item)
        }

        guard model.showsAccounts else { return menu }
        menu.addItem(.separator())
        let unified = NSMenuItem(title: "All Inboxes", action: scopeAction, keyEquivalent: "0")
        unified.keyEquivalentModifierMask = .command
        unified.target = target
        unified.tag = 0
        unified.image = QuireSymbol.image(Quire.Icon.unifiedInbox, size: .inText, accessibilityDescription: "All Inboxes")
        unified.state = model.scope == .unified ? .on : .off
        if model.unifiedUnread > 0 { unified.badge = NSMenuItemBadge(count: model.unifiedUnread) }
        menu.addItem(unified)
        for (index, entry) in model.accounts.enumerated() {
            let name = AccountMonogram.name(for: entry.account)
            let item = NSMenuItem(title: "\(name) · \(entry.account.email)", action: scopeAction, keyEquivalent: index < 9 ? "\(index + 1)" : "")
            item.keyEquivalentModifierMask = .command
            item.target = target
            item.tag = index + 1
            item.image = monogramImage(entry.monogram, slot: entry.account.inkSlot)
            item.state = model.scope == .account(entry.account.id) ? .on : .off
            if entry.unread > 0 { item.badge = NSMenuItemBadge(count: entry.unread) }
            menu.addItem(item)
        }
        return menu
    }

    /// A small account face with its ring, drawn when the menu shows so it follows the appearance.
    private static func monogramImage(_ monogram: String, slot: Int) -> NSImage {
        let side: CGFloat = 18
        return NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            // Menus draw their images on the main thread.
            MainActor.assumeIsolated {
                let ring = Quire.Border.AccountRing.width / 2 + 0.5
                let face = rect.insetBy(dx: ring + 1.5, dy: ring + 1.5)
                QuireAvatarRenderer.drawAccountFace(monogram: String(monogram.prefix(1)), slot: slot, in: face)
                let path = NSBezierPath(ovalIn: rect.insetBy(dx: ring, dy: ring))
                path.lineWidth = 1.5
                NSColor.qAccount(slot).setStroke()
                path.stroke()
            }
            return true
        }
    }
}
