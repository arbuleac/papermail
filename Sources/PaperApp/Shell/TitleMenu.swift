import AppKit
import PaperCore
import PaperDesign

/// The title menu popped from the masthead (spec §5.4): a system `NSMenu` with the six views, Later below Inbox while
/// something in scope is snoozed and the Outbox after Drafts while a send in scope waits to go (the rail's conditional
/// tiles, §5.2), each with its symbol and its G-sequence in a right-aligned `ink3` column (an attributed title, because
/// `keyEquivalent` cannot express a sequence), a checkmark on the current view and the Inbox unread count as a system
/// badge. In minimal mode it gains All Inboxes and the accounts, with their faces, ⌘0…⌘9 and their counts.
@MainActor
enum TitleMenu {
    struct AccountEntry {
        var account: Account
        /// The account's face (§5.55): a paper face, or its monogram, of which the menu draws the first letter.
        var face: QuireAccountFace
        /// The account's monogram as the rail would show it: its first letter stands in for a paper face below 2× (§5.55).
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
        /// Something in the scope is snoozed: Later is listed below Inbox, as its rail tile shows (§5.2).
        var showsLater = false
        /// A send in the scope waits to go: the Outbox is listed after Drafts, as its rail tile shows (§5.2, §5.53).
        var showsOutbox = false
    }

    static let entries: [(view: MailboxView, title: String, symbol: String, sequence: String)] = [
        (.inbox, "Inbox", Quire.Icon.viewInbox, "G I"),
        (.later, "Later", Quire.Icon.viewLater, "G L"),
        (.starred, "Starred", Quire.Icon.viewStarred, "G S"),
        (.sent, "Sent", Quire.Icon.viewSent, "G T"),
        (.drafts, "Drafts", Quire.Icon.viewDrafts, "G D"),
        (.outbox, OutboxCopy.title, Quire.Icon.viewOutbox, "G O"),
        (.trash, "Trash", Quire.Icon.viewTrash, "G #"),
        (.all, "All Mail", Quire.Icon.viewAllMail, "G A"),
    ]

    /// The view's name for the masthead and the search placeholder. Every view is an entry, the conditional ones too: the
    /// Outbox is listed, as its rail tile shows, only while a send in scope waits to go (§5.4, §5.53), but its name is the
    /// same whenever it is on screen.
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
            if entry.view == .later, !model.showsLater { continue }
            if entry.view == .outbox, !model.showsOutbox { continue }
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
            let sequence = "G then \(entry.sequence.dropFirst(2))"
            if entry.view == .inbox {
                setUnread(model.inboxUnread, on: item, help: sequence)
            } else {
                item.setAccessibilityHelp(sequence)
            }
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
        setUnread(model.unifiedUnread, on: unified)
        menu.addItem(unified)
        for (index, entry) in model.accounts.enumerated() {
            let name = AccountLabels.name(for: entry.account)
            let item = NSMenuItem(title: "\(name) · \(entry.account.email)", action: scopeAction, keyEquivalent: index < 9 ? "\(index + 1)" : "")
            item.keyEquivalentModifierMask = .command
            item.target = target
            item.tag = index + 1
            item.image = faceImage(entry.face, monogram: entry.monogram, slot: entry.account.inkSlot)
            item.state = model.scope == .account(entry.account.id) ? .on : .off
            setUnread(entry.unread, on: item)
            menu.addItem(item)
        }
        return menu
    }

    /// The system badge for an unread count, in the words the rail's tiles and the Dock use (§5.28): a count badge
    /// prints the whole number, where the rail this menu stands in for reads 99+. None at zero.
    static func unreadBadge(_ count: Int) -> NSMenuItemBadge? {
        QuireBadge.unreadText(count).map { NSMenuItemBadge(string: $0) }
    }

    /// Badges `item` with an unread count and gives VoiceOver the real number in its help, before the item's own `help`,
    /// as the rail's tiles do: the badge reads 99+ past the cap, and VoiceOver would hear only that (§5.28).
    static func setUnread(_ count: Int, on item: NSMenuItem, help: String? = nil) {
        item.badge = unreadBadge(count)
        let words = [count > 0 ? QuireBadge.unreadAccessibilityText(count) : nil, help].compactMap { $0 }
        item.setAccessibilityHelp(words.isEmpty ? nil : words.joined(separator: ", "))
    }

    /// A small account face with its ring, drawn when the menu shows, so it follows the appearance and the screen it is on.
    /// A paper face is the rail's art at 12 pt, still the person or animal at that size on a 2× screen; on a 1× screen its
    /// 12 pixels are a blob, so there it is `monogram`'s first letter, as for an account that wears its monogram (§5.55).
    static func faceImage(_ face: QuireAccountFace, monogram: String, slot: Int) -> NSImage {
        let side: CGFloat = 18
        return NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            // Menus draw their images on the main thread.
            MainActor.assumeIsolated {
                let ring = Quire.Border.AccountRing.width / 2 + 0.5
                let inner = rect.insetBy(dx: ring + 1.5, dy: ring + 1.5)
                // Read from the destination, not the main screen: a menu opened on a 1× screen of a Mac that also has a 2× one.
                let scale = NSGraphicsContext.current.map { QuireAvatarRenderer.deviceScale(of: $0.cgContext) } ?? 1
                switch face {
                case .monogram(let letters):
                    QuireAvatarRenderer.drawAccountFace(monogram: String(letters.prefix(1)), slot: slot, in: inner)
                case .paper where scale < 2:
                    QuireAvatarRenderer.drawAccountFace(monogram: String(monogram.prefix(1)), slot: slot, in: inner)
                case .paper:
                    QuireAvatarRenderer.drawAccountFace(face, slot: slot, in: inner)
                }
                let path = NSBezierPath(ovalIn: rect.insetBy(dx: ring, dy: ring))
                path.lineWidth = 1.5
                NSColor.qAccount(slot).setStroke()
                path.stroke()
            }
            return true
        }
    }
}
