import AppKit

/// Owns every open composer window and undo-send panel. Window controllers are otherwise released as soon
/// as the presenting code returns, and a composer must outlive the code that opened it.
@MainActor
final class ComposeWindowRegistry {
    static let shared = ComposeWindowRegistry()

    private var controllers: [ObjectIdentifier: ComposeWindowController] = [:]
    /// In the order they were shown: the first sits lowest in the stack.
    private var panels: [UndoSendPanel] = []
    private var lastCascadePoint = NSPoint.zero

    var openControllers: [ComposeWindowController] {
        Array(controllers.values)
    }

    var livePanels: [UndoSendPanel] { panels }

    func register(_ controller: ComposeWindowController) {
        controllers[ObjectIdentifier(controller)] = controller
    }

    func unregister(_ controller: ComposeWindowController) {
        controllers[ObjectIdentifier(controller)] = nil
    }

    func register(_ panel: UndoSendPanel) {
        guard !panels.contains(where: { $0 === panel }) else { return }
        panels.append(panel)
    }

    func unregister(_ panel: UndoSendPanel) {
        panels.removeAll { $0 === panel }
    }

    /// Stacking position for a panel: how many panels were shown before it and are still up.
    func slot(for panel: UndoSendPanel) -> Int {
        panels.firstIndex { $0 === panel } ?? panels.count
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
