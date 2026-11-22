import AppKit

/// An attachment chip's context menu (spec §5.17): Quick Look, Open, Save to Downloads, Save As…, Copy. A system
/// menu in title case (§4.13); the reader performs the command on the chip it was opened for.
@MainActor
final class AttachmentMenu: NSObject {
    enum Command: CaseIterable {
        case quickLook, open, saveToDownloads, saveAs, copy

        var title: String {
            switch self {
            case .quickLook: return "Quick Look"
            case .open: return "Open"
            case .saveToDownloads: return "Save to Downloads"
            case .saveAs: return "Save As\u{2026}"
            case .copy: return "Copy"
            }
        }
    }

    private let perform: (Command) -> Void

    init(perform: @escaping (Command) -> Void) {
        self.perform = perform
        super.init()
    }

    func menu() -> NSMenu {
        let menu = NSMenu(title: "Attachment")
        menu.autoenablesItems = false
        for (index, command) in Command.allCases.enumerated() {
            if command == .saveToDownloads || command == .copy { menu.addItem(.separator()) }
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
