import AppKit
import SSDesign

/// The sheet header's More menu (spec §5.14): a system menu acting on one message, every item with its
/// symbol leading and its shortcut. Items that do not apply are hidden, not disabled. Conversation actions
/// stay in the reader header.
@MainActor
final class MessageMoreMenu: NSObject {
    struct Options {
        var isStarred: Bool
        var imagesBlocked: Bool
        var offersOriginal: Bool
        var showsOriginal: Bool
        var hasSenderAddress: Bool
        /// The message's list headers offer a way to unsubscribe (its sheet shows the link).
        var canUnsubscribe = false
    }

    enum Command {
        case reply, replyAll, forward, toggleStar, markUnreadFromHere, loadImages, toggleOriginal, unsubscribe, copySenderAddress
    }

    private let perform: (Command) -> Void
    private var commands: [Command] = []

    init(perform: @escaping (Command) -> Void) {
        self.perform = perform
        super.init()
    }

    func menu(_ options: Options) -> NSMenu {
        let menu = NSMenu(title: "More")
        menu.autoenablesItems = false
        commands = []
        add(.reply, "Reply", Quire.Icon.reply, key: "r", to: menu)
        add(.replyAll, "Reply All", Quire.Icon.replyAll, key: "a", to: menu)
        add(.forward, "Forward", Quire.Icon.forward, key: "f", to: menu)
        menu.addItem(.separator())
        add(.toggleStar, options.isStarred ? "Unstar Message" : "Star Message",
            options.isStarred ? Quire.Icon.unstar : Quire.Icon.star, key: "s", to: menu)
        add(.markUnreadFromHere, "Mark as Unread from Here", Quire.Icon.markUnread, key: "", to: menu)
        if options.imagesBlocked || options.offersOriginal {
            menu.addItem(.separator())
            if options.imagesBlocked {
                add(.loadImages, "Load Images", Quire.Icon.loadImages, key: "i", modifiers: [.command, .shift], to: menu)
            }
            if options.offersOriginal {
                add(.toggleOriginal, options.showsOriginal ? "Adaptive Colors" : "Original Colors", Quire.Icon.originalColors,
                    key: "o", modifiers: [.command, .shift], to: menu)
            }
        }
        if options.hasSenderAddress || options.canUnsubscribe {
            menu.addItem(.separator())
            // Beside the sender's other item: both are about who sent it.
            if options.canUnsubscribe {
                add(.unsubscribe, "Unsubscribe", nil, key: "u", modifiers: [.command, .shift], to: menu)
            }
            if options.hasSenderAddress {
                add(.copySenderAddress, "Copy Sender Address", nil, key: "", to: menu)
            }
        }
        return menu
    }

    /// Single-key shortcuts are shown as text: the router handles them, so they never fire from a menu.
    private func add(_ command: Command, _ title: String, _ symbol: String?, key: String,
                     modifiers: NSEvent.ModifierFlags = [], to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: modifiers.isEmpty ? "" : key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.tag = commands.count
        commands.append(command)
        if let symbol { item.image = QuireSymbol.image(symbol, size: .inText) }
        if modifiers.isEmpty, !key.isEmpty {
            item.attributedTitle = Self.title(title, shortcut: key.uppercased())
        }
        menu.addItem(item)
    }

    private static func title(_ title: String, shortcut: String) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let result = NSMutableAttributedString(string: title, attributes: [.font: font])
        let tab = NSMutableParagraphStyle()
        tab.tabStops = [NSTextTab(textAlignment: .right, location: 220)]
        result.append(NSAttributedString(string: "\t" + shortcut, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        result.addAttribute(.paragraphStyle, value: tab, range: NSRange(location: 0, length: result.length))
        return result
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard commands.indices.contains(sender.tag) else { return }
        perform(commands[sender.tag])
    }
}
