import AppKit
import SSCore
import SSDesign

/// The Send button's drop-down (spec §5.23), in the composer's bottom bar and the quick reply's tool row: a system menu
/// of the two send actions, the default checked. Choosing one makes it the default for every Send button and ⌘↩; the
/// menu never sends, so it carries no key equivalents (⇧⌘↩ is Message › Send and Archive's).
@MainActor
final class SendActionMenu: NSObject {
    private let choose: @MainActor (SendAction) -> Void

    init(choose: @escaping @MainActor (SendAction) -> Void) {
        self.choose = choose
        super.init()
    }

    func menu(current: SendAction) -> NSMenu {
        let menu = NSMenu(title: "Send Options")
        menu.autoenablesItems = false
        for action in SendAction.allCases {
            let item = NSMenuItem(title: action.title, action: #selector(chosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            item.state = action == current ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func chosen(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let action = SendAction(rawValue: raw) else { return }
        choose(action)
    }

    /// Hangs `menu` from `control`'s face, its top-leading corner at the face's leading edge `menu.titleMenuOffsetY` below
    /// it, as Quire's other hung menus are (§5.4, §5.45); AppKit keeps it on screen. Tracks until it is dismissed.
    static func popUp(_ menu: NSMenu, from control: QuireControl) {
        let face = control.faceRect
        menu.popUp(positioning: nil, at: NSPoint(x: face.minX, y: face.maxY + Quire.Layout.Menu.titleMenuOffsetY), in: control)
    }
}
