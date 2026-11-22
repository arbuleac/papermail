import AppKit
import PaperCore
import PaperDesign

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
        /// Someone other than the user sent it, so a sender rule can be set from it (spec, Sender rules (Q4.2)).
        var offersSenderRules = false
        /// The rule its sender has now: that item shows checked and disabled.
        var senderRule: SenderRule.Action?
    }

    enum Command {
        case reply, replyAll, forward, toggleStar, markUnreadFromHere, loadImages, toggleOriginal, unsubscribe, copySenderAddress
        case alwaysArchiveSender, blockSender
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
        if options.hasSenderAddress || options.canUnsubscribe || options.offersSenderRules {
            menu.addItem(.separator())
            // Beside the sender's other items: all are about who sent it.
            if options.canUnsubscribe {
                add(.unsubscribe, "Unsubscribe", nil, key: "u", modifiers: [.command, .shift], to: menu)
            }
            if options.offersSenderRules {
                for (command, action) in [(Command.alwaysArchiveSender, SenderRule.Action.archive), (.blockSender, .trash)] {
                    let item = add(command, MailActionCopy.senderRuleCommand(action),
                                   action == .trash ? Quire.Icon.blockSender : Quire.Icon.alwaysArchiveSender, key: "", to: menu)
                    // The rule the sender has is checked and has nothing more to do; the other replaces it.
                    item.state = options.senderRule == action ? .on : .off
                    item.isEnabled = options.senderRule != action
                }
            }
            if options.hasSenderAddress {
                add(.copySenderAddress, "Copy Sender Address", nil, key: "", to: menu)
            }
        }
        return menu
    }

    /// Single-key shortcuts are shown as text: the router handles them, so they never fire from a menu.
    @discardableResult
    private func add(_ command: Command, _ title: String, _ symbol: String?, key: String,
                     modifiers: NSEvent.ModifierFlags = [], to menu: NSMenu) -> NSMenuItem {
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
        return item
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
