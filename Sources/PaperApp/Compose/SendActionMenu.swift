import AppKit
import PaperCore
import PaperDesign

/// The Send button's drop-down (spec §5.23), Send's menu segment in the composer's bottom bar and the quick reply's tool
/// row: a system menu of the two send actions, the default checked, then Send Later's times. Choosing an action makes it
/// the default for every Send button and ⌘↩; a click never sends. Each action shows the key that does it now, as menus
/// show key equivalents: ⌘↩ beside the checked one, ⇧⌘↩ beside Send and Archive while Send is checked, none beside Send
/// while Send and Archive is (`SendAction.key(whenChosen:)`). Because the menu answers those keys while it is open, a key
/// that takes a row sends, as the row and the key both say, and never makes the row the default. A Send Later item
/// schedules the message for its time; Pick a Time… asks for one; the heading names ⇧⌘L, which hangs these times alone.
@MainActor
final class SendActionMenu: NSObject {
    private let choose: @MainActor (SendAction) -> Void
    /// Sends now as the action says: a row's key pressed while the menu is open.
    private let send: @MainActor (SendAction) -> Void
    /// A time chosen under Send Later, or nil for Pick a Time…; nil leaves Send Later out of the menu.
    private let sendLater: (@MainActor (Date?) -> Void)?
    /// How Send Later's times are written: as Later writes its own (§4.13).
    private let formatter = DateFormatting()

    init(choose: @escaping @MainActor (SendAction) -> Void, send: @escaping @MainActor (SendAction) -> Void,
         sendLater: (@MainActor (Date?) -> Void)? = nil) {
        self.choose = choose
        self.send = send
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
            if let key = action.key(whenChosen: current) {
                item.keyEquivalent = "\r"
                item.keyEquivalentModifierMask = Self.modifiers(of: key)
            }
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
        var items: [NSMenuItem] = [.sectionHeader(title: Self.laterHeading)]
        // The time sends only while Paper is open: said in the tooltip, as the Drafts row and the sheet say it.
        items += LaterMenu.timedItems(offered, now: now, formatter: formatter, target: self, action: #selector(chosenTime(_:)),
                                      showsHelp: true) {
            SendLaterCopy.help($0)
        }
        let pick = NSMenuItem(title: SendLaterCopy.pickTime, action: #selector(pickTime(_:)), keyEquivalent: "")
        pick.target = self
        items.append(pick)
        return items
    }

    @objc private func chosen(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let action = SendAction(rawValue: raw) else { return }
        if Self.isKeyEquivalent(NSApp.currentEvent, of: item) {
            send(action)
        } else {
            choose(action)
        }
    }

    /// ⇧⌘L, Message › Send Later…'s key, as the heading writes it.
    static let laterKey = "⇧⌘L"

    /// Send Later's heading: a heading draws no key equivalent, so ⇧⌘L follows its words, in the heading's own style (and
    /// VoiceOver reads it with them).
    static let laterHeading = SendLaterCopy.command + "  " + laterKey

    static func modifiers(of key: SendKey) -> NSEvent.ModifierFlags {
        switch key {
        case .commandReturn: return .command
        case .shiftCommandReturn: return [.command, .shift]
        }
    }

    /// True when `event` is `item`'s own key equivalent: what an open menu reports when a key takes a row (its key-down,
    /// or the key-up that ends the menu's tracking). Return alone, which takes the highlighted row, carries no ⌘ and is a
    /// choice; a click is a mouse event.
    static func isKeyEquivalent(_ event: NSEvent?, of item: NSMenuItem) -> Bool {
        guard let event, event.type == .keyDown || event.type == .keyUp, !item.keyEquivalent.isEmpty else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        return flags == item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
    }

    @objc private func chosenTime(_ item: NSMenuItem) {
        guard let date = item.representedObject as? Date else { return }
        sendLater?(date)
    }

    @objc private func pickTime(_ item: NSMenuItem) {
        sendLater?(nil)
    }

    /// Hangs `menu` from Send's face, both segments, its top-leading corner at the face's leading edge
    /// `menu.titleMenuOffsetY` below it, as Quire's other hung menus are (§5.4, §5.45); AppKit keeps it on screen. Tracks
    /// until it is dismissed.
    static func popUp(_ menu: NSMenu, from button: QuireSplitButton) {
        let face = button.faceRect
        menu.popUp(positioning: nil, at: NSPoint(x: face.minX, y: face.maxY + Quire.Layout.Menu.titleMenuOffsetY), in: button)
    }
}
