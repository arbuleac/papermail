import AppKit

/// Owns every open composer window and undo-send panel. Window controllers are otherwise released as soon
/// as the presenting code returns, and a composer must outlive the code that opened it.
@MainActor
final class ComposeWindowRegistry {
    static let shared = ComposeWindowRegistry()

    private var controllers: [ObjectIdentifier: ComposeWindowController] = [:]
    private var panels: [ObjectIdentifier: UndoSendPanel] = [:]
    private var lastCascadePoint = NSPoint.zero

    var openControllers: [ComposeWindowController] {
        Array(controllers.values)
    }

    func register(_ controller: ComposeWindowController) {
        controllers[ObjectIdentifier(controller)] = controller
    }

    func unregister(_ controller: ComposeWindowController) {
        controllers[ObjectIdentifier(controller)] = nil
    }

    func register(_ panel: UndoSendPanel) {
        panels[ObjectIdentifier(panel)] = panel
    }

    func unregister(_ panel: UndoSendPanel) {
        panels[ObjectIdentifier(panel)] = nil
    }

    /// Stacking position for a new panel so simultaneous undo panels do not cover each other.
    func slot(for panel: UndoSendPanel) -> Int {
        panels.values.filter { $0 !== panel && $0.isVisible }.count
    }

    /// Offsets each new composer from the previous one, the way document windows cascade.
    func cascade(_ window: NSWindow) {
        if lastCascadePoint == .zero {
            window.center()
            lastCascadePoint = window.cascadeTopLeft(from: NSPoint(x: window.frame.minX, y: window.frame.maxY))
        } else {
            lastCascadePoint = window.cascadeTopLeft(from: lastCascadePoint)
        }
    }
}
