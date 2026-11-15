import AppKit

/// The person menu on an address in a sheet header (spec §5.14, §5.35): Copy Address · Copy Name and Address · — · New
/// Message · Show Mail from This Person. A system menu in title case, without symbols, as the composer token's menu (§5.21).
/// Items that do not apply are hidden, as in the More menu: a disabled Copy Name and Address on half the recipients would
/// only be noise. The reader performs the command on the address the menu was opened for.
@MainActor
final class PersonMenu: NSObject {
    struct Options {
        /// The header gives a name apart from the address.
        var offersNameAndAddress: Bool
        /// The address is one a message can be written to.
        var offersNewMessage: Bool
    }

    enum Command: CaseIterable {
        case copyAddress, copyNameAndAddress, newMessage, showMail

        var title: String {
            switch self {
            case .copyAddress: return "Copy Address"
            case .copyNameAndAddress: return "Copy Name and Address"
            case .newMessage: return "New Message"
            case .showMail: return "Show Mail from This Person"
            }
        }
    }

    private let perform: (Command) -> Void

    init(perform: @escaping (Command) -> Void) {
        self.perform = perform
        super.init()
    }

    func menu(_ options: Options) -> NSMenu {
        let menu = NSMenu(title: "Person")
        menu.autoenablesItems = false
        for (index, command) in Command.allCases.enumerated() {
            if command == .copyNameAndAddress, !options.offersNameAndAddress { continue }
            if command == .newMessage, !options.offersNewMessage { continue }
            if command == .newMessage || (command == .showMail && !options.offersNewMessage) { menu.addItem(.separator()) }
            let item = NSMenuItem(title: command.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        return menu
    }

    @objc private func choose(_ sender: NSMenuItem) {
        let all = Command.allCases
        guard all.indices.contains(sender.tag) else { return }
        perform(all[sender.tag])
    }
}
