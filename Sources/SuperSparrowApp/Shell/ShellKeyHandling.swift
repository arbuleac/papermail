import AppKit
import SSDesign

/// A shell control that answers some keys itself while it has keyboard focus: a rail tile moves the selection
/// with ↑/↓ and chooses with ↩ (§5.2), the sync line and its action link run on ↩ (§5.11), and the masthead and
/// the Demo tag open their menus. `KeyboardRouter` sees every key first and maps ↑/↓ and ↩ to the list, so the
/// window controller asks the focused control before it lets the router act.
@MainActor
protocol ShellKeyHandling: AnyObject {
    /// True when the control will handle `event` in its own `keyDown(with:)`.
    func handlesKey(_ event: NSEvent) -> Bool
}

extension NSEvent {
    /// ↩ or the keypad's Enter, with no modifier.
    var isPlainReturn: Bool {
        guard modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        return specialKey == .carriageReturn || specialKey == .enter
    }
}

extension QuireUnderlineTabs: ShellKeyHandling {
    /// ← → choose the quick reply's Reply or Reply all (§5.18); ← would otherwise take the keyboard back to the list.
    func handlesKey(_ event: NSEvent) -> Bool {
        guard isEnabled, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        return event.specialKey == .leftArrow || event.specialKey == .rightArrow
    }
}

extension CalendarDayCellsView: ShellKeyHandling {
    /// ← → move the day column's shown day while its cells have the keyboard (§5.54); → would otherwise open the list's
    /// selection in the reader.
    func handlesKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        return event.specialKey == .leftArrow || event.specialKey == .rightArrow
    }
}
