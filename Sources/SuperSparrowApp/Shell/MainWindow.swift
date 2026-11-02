import AppKit

/// The main window. Its only behaviour of its own is the Tab order of spec §3.4: rail → list header controls →
/// list → sync line (while it carries an action) → the reader, in that order, whatever the panes' geometry.
///
/// The shell's part of the loop is given by `shellKeyViews`; inside the reader the reader's own chain (or,
/// where it set none, top-to-bottom order) applies, and leaving the reader at either end comes back to the
/// shell. The window never rewrites any view's `nextKeyView`, so the reader keeps whatever chain it builds.
@MainActor
final class MainWindow: NSWindow {
    /// The shell's key views in Tab order (rail, header, list, sync line).
    var shellKeyViews: (() -> [NSView])?
    /// The reader's root view.
    weak var readerRoot: NSView?

    override func selectNextKeyView(_ sender: Any?) {
        if !route(forward: true, from: currentKeyView) { super.selectNextKeyView(sender) }
    }

    override func selectPreviousKeyView(_ sender: Any?) {
        if !route(forward: false, from: currentKeyView) { super.selectPreviousKeyView(sender) }
    }

    override func selectKeyView(following view: NSView) {
        if !route(forward: true, from: view) { super.selectKeyView(following: view) }
    }

    override func selectKeyView(preceding view: NSView) {
        if !route(forward: false, from: view) { super.selectKeyView(preceding: view) }
    }

    /// The first responder as a key view: a field editor stands for the field it edits.
    private var currentKeyView: NSView? {
        if let editor = firstResponder as? NSTextView, editor.isFieldEditor { return editor.delegate as? NSView }
        return firstResponder as? NSView
    }

    private func isUsable(_ view: NSView) -> Bool {
        view.window === self && !view.isHiddenOrHasHiddenAncestor && view.canBecomeKeyView
    }

    /// Returns false to leave the move to AppKit.
    private func route(forward: Bool, from view: NSView?) -> Bool {
        let shell = (shellKeyViews?() ?? []).filter(isUsable)
        guard !shell.isEmpty else { return false }
        let reader = readerKeyViews()
        guard let view else { return focus(forward ? shell.first : shell.last) }

        if let index = shell.firstIndex(where: { view === $0 || view.isDescendant(of: $0) }) {
            let next = index + (forward ? 1 : -1)
            if shell.indices.contains(next) { return focus(shell[next]) }
            return focus(forward ? (reader.first ?? shell.first) : (reader.last ?? shell.last))
        }

        guard let root = readerRoot, view.isDescendant(of: root) else { return false }
        if view.nextKeyView != nil || view.previousKeyView != nil {
            // The reader built its own chain: follow it while it stays in the reader and keeps moving the
            // same way down the page; a wrap or an exit returns to the shell.
            let candidate = forward ? view.nextValidKeyView : view.previousValidKeyView
            if let candidate, candidate.isDescendant(of: root), comesAfter(candidate, view) == forward { return false }
            return focus(forward ? shell.first : shell.last)
        }
        guard let index = reader.firstIndex(where: { view === $0 || view.isDescendant(of: $0) }) else {
            return focus(forward ? shell.first : shell.last)
        }
        let next = index + (forward ? 1 : -1)
        return focus(reader.indices.contains(next) ? reader[next] : (forward ? shell.first : shell.last))
    }

    private func focus(_ view: NSView?) -> Bool {
        guard let view else { return false }
        makeFirstResponder(view)
        return true
    }

    /// The reader's key views, top to bottom and then leading to trailing.
    private func readerKeyViews() -> [NSView] {
        guard let root = readerRoot else { return [] }
        var found: [NSView] = []
        func walk(_ view: NSView) {
            for subview in view.subviews where !subview.isHidden {
                if isUsable(subview) {
                    found.append(subview)
                } else {
                    walk(subview)
                }
            }
        }
        walk(root)
        return found.sorted { comesAfter($1, $0) }
    }

    /// True when `a` lies after `b` in reading order (lower on screen, or level and further along).
    private func comesAfter(_ a: NSView, _ b: NSView) -> Bool {
        let ra = a.convert(a.bounds, to: nil)
        let rb = b.convert(b.bounds, to: nil)
        // Window coordinates grow upward.
        if abs(ra.maxY - rb.maxY) > 2 { return ra.maxY < rb.maxY }
        return ra.minX > rb.minX
    }
}
