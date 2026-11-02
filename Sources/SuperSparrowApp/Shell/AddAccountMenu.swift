import AppKit
import SSDesign

/// The add-account pull-down (spec §5.44): the provider is chosen in a menu, never an alert. The rail's +
/// opens it 4 pt below the button, leading-aligned; with a nil target its items travel the responder chain to
/// the app delegate, so any + can use it.
@MainActor
enum AddAccountMenu {
    static func make(target: AnyObject? = nil) -> NSMenu {
        let menu = NSMenu(title: "Add Account")
        menu.addItem(MainMenu.item("Add Gmail Account…", #selector(AppDelegate.addGmailAccount(_:)), symbol: Quire.Icon.addAccountProvider,
                                   target: target))
        menu.addItem(MainMenu.item("Add Microsoft Account…", #selector(AppDelegate.addMicrosoftAccount(_:)),
                                   symbol: Quire.Icon.addAccountProvider, target: target))
        return menu
    }

    /// Opens the menu under `button`, leading-aligned, `rail.addMenuOffsetY` below it.
    static func popUp(below button: NSView, target: AnyObject? = nil) {
        let menu = make(target: target)
        let offset = Quire.Layout.Rail.addMenuOffsetY
        let point = button.isFlipped ? NSPoint(x: 0, y: button.bounds.maxY + offset) : NSPoint(x: 0, y: -offset)
        menu.popUp(positioning: nil, at: point, in: button)
    }
}
