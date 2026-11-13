import AppKit
import SSCore
import SSDesign

/// The Send button's drop-down (spec §5.23), in the composer's bottom bar and the quick reply's tool row: a system menu
/// of the two send actions, the default checked, then Send Later's times. Choosing an action makes it the default for
/// every Send button and ⌘↩; it never sends, so those items carry no key equivalents (⇧⌘↩ is Message › Send and
/// Archive's). A Send Later item schedules the message for its time; Pick a Time… asks for one.
@MainActor
final class SendActionMenu: NSObject {
    private let choose: @MainActor (SendAction) -> Void
    /// A time chosen under Send Later, or nil for Pick a Time…; nil leaves Send Later out of the menu.
    private let sendLater: (@MainActor (Date?) -> Void)?
    /// How Send Later's times are written: as Later writes its own (§4.13).
    private let formatter = DateFormatting()

    init(choose: @escaping @MainActor (SendAction) -> Void, sendLater: (@MainActor (Date?) -> Void)? = nil) {
        self.choose = choose
        self.sendLater = sendLater
        super.init()
    }

    func menu(current: SendAction, now: Date = Date()) -> NSMenu {
        let menu = NSMenu(title: "Send Options")
        menu.autoenablesItems = false
        for action in SendAction.allCases {
            let item = NSMenuItem(title: action.title, action: #selector(chosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            item.state = action == current ? .on : .off
            menu.addItem(item)
        }
        if sendLater != nil {
            menu.addItem(.separator())
            for item in laterItems(now: now) { menu.addItem(item) }
        }
        return menu
    }

    /// Send Later's part alone, under its heading: what ⇧⌘L and Message › Send Later… hang from the drop-down.
    func laterMenu(now: Date = Date()) -> NSMenu {
        let menu = NSMenu(title: SendLaterCopy.command)
        menu.autoenablesItems = false
        for item in laterItems(now: now) { menu.addItem(item) }
        return menu
    }

    /// The heading “Send Later”, its presets with their times (Tomorrow, Monday), and Pick a Time….
    private func laterItems(now: Date) -> [NSMenuItem] {
        let offered = SendLaterPreset.offered(at: now, calendar: .autoupdatingCurrent).map { (title: $0.preset.title, date: $0.date) }
        var items: [NSMenuItem] = [.sectionHeader(title: SendLaterCopy.command)]
        items += LaterMenu.timedItems(offered, now: now, formatter: formatter, target: self, action: #selector(chosenTime(_:))) {
            SendLaterCopy.help($0)
        }
        let pick = NSMenuItem(title: SendLaterCopy.pickTime, action: #selector(pickTime(_:)), keyEquivalent: "")
        pick.target = self
        items.append(pick)
        return items
    }

    @objc private func chosen(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let action = SendAction(rawValue: raw) else { return }
        choose(action)
    }

    @objc private func chosenTime(_ item: NSMenuItem) {
        guard let date = item.representedObject as? Date else { return }
        sendLater?(date)
    }

    @objc private func pickTime(_ item: NSMenuItem) {
        sendLater?(nil)
    }

    /// Hangs `menu` from `control`'s face, its top-leading corner at the face's leading edge `menu.titleMenuOffsetY` below
    /// it, as Quire's other hung menus are (§5.4, §5.45); AppKit keeps it on screen. Tracks until it is dismissed.
    static func popUp(_ menu: NSMenu, from control: QuireControl) {
        let face = control.faceRect
        menu.popUp(positioning: nil, at: NSPoint(x: face.minX, y: face.maxY + Quire.Layout.Menu.titleMenuOffsetY), in: control)
    }
}
