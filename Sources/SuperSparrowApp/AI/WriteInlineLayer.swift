import AppKit
import SSDesign
import os

/// Help me write's marks in a reply's text (§5.56): the ghost after the caret, the selection pill, the prompt line, the
/// pencil while a reply streams and the afterline under a draft. One per field (the quick reply's, a reply composer's
/// body), the same in both: only the host differs. They are subviews of the text view, so they scroll with the text, and
/// placed from its layout manager: the caret's line and baseline, a selection's or a draft's last line. The pill floats
/// in `floatHost`, which does not clip it where the text's own scroll view would (the quick reply's bar).
///
/// The prompt line and the afterline are **reserved blocks**: a full-width exclusion in the text container under their
/// anchor line, so the lines below move down to make room and nothing is ever drawn over text. The text storage never
/// changes for them (nothing in the draft, the undo stack or autosave). Where the anchor is the last line nothing moves:
/// the block hangs below the text, and the host adds `overflow` to its height.
///
/// The layer shows what `WriteSession` asks (`apply(_:)`); it reads nothing of Help me write itself, so nothing here can
/// reach a provider.
@MainActor
final class WriteInlineLayer {
    /// Where a block hangs.
    enum Anchor: Equatable {
        /// Under the caret's line at this location.
        case caret(Int)
        /// Under the line of the last letter before this location: a selection's end, a draft's.
        case end(Int)

        var location: Int {
            switch self {
            case .caret(let at), .end(let at): return at
            }
        }
    }

    enum Block: Equatable {
        case prompt(Anchor)
        case afterline(Anchor, WriteAfterline.Content)

        var anchor: Anchor {
            switch self {
            case .prompt(let anchor), .afterline(let anchor, _): return anchor
            }
        }

        /// The block's height in the text's flow, its gaps included.
        var height: CGFloat {
            let c = Quire.Layout.WriteCaret.self
            switch self {
            case .prompt: return WritePromptLine.blockHeight
            case .afterline: return c.blockGapTop + WriteAfterline.height + c.blockGapBottom
            }
        }

        var isPrompt: Bool {
            if case .prompt = self { return true }
            return false
        }
    }

    /// The ghost after the caret.
    struct Ghost: Equatable {
        var location: Int
        var words: String
        /// How far after the caret it starts: the quick reply's placeholder's words, when they show.
        var offset: CGFloat = 0
        /// It fades in (the notes ghost after a pause); else it shows at once.
        var fades = false
    }

    /// What shows now.
    struct State: Equatable {
        var ghost: Ghost?
        /// The selection the pill hangs under (its trimmed core).
        var pill: NSRange?
        var block: Block?
        /// Where the pencil sits while a reply streams: just after this location.
        var pencil: Int?
    }

    let textView: NSTextView
    /// Where the pill floats; the text view when nothing else is given.
    private weak var floatHost: NSView?

    let ghost = WriteCaretHint(frame: .zero)
    let pill = WriteSelectionPill(frame: .zero)
    let prompt = WritePromptLine(frame: .zero)
    let pencil = WritePencilMark(frame: .zero)
    let afterline = WriteAfterline(frame: .zero)

    /// A block opened, closed or moved: the host lays its field out again.
    var onReservedSpaceChange: (() -> Void)?
    /// The text scrolled: the session takes the ghost away.
    var onScroll: (() -> Void)?
    /// Text size changed (§4.15): the session gives the marks the text's new writing style before the block is measured
    /// again under its anchor.
    var onEnvironmentChange: (() -> Void)?

    private(set) var state = State()

    /// The block's height while one shows, its gaps included; 0 with none.
    private(set) var reservedHeight: CGFloat = 0
    /// The part of the block that lies below the text's last line, which the text's own height does not hold: the host
    /// adds it to the field's.
    private(set) var overflow: CGFloat = 0
    /// The block's rect in the text container, while one shows.
    private(set) var blockRect: NSRect?

    /// The writing style the marks take: the field's (`WriteField.writeAttributes`), set by the session.
    var textAttributes: [NSAttributedString.Key: Any] = [:] {
        didSet {
            ghost.textAttributes = textAttributes
            pencil.textAttributes = textAttributes
            prompt.textAttributes = textAttributes
        }
    }

    /// Renders launched from a terminal draw the key window's look (the prompt's ring).
    var windowKeyOverride: Bool? {
        didSet {
            prompt.windowKeyOverride = windowKeyOverride
            for view in [ghost, pill, pencil] as [QuireControl] { view.windowKeyOverride = windowKeyOverride }
        }
    }

    private var containerWidth: CGFloat = 0
    /// A block opened or changed and has not been scrolled into view yet (`revealBlockIfNeeded`).
    private(set) var revealsBlock = false
    private var savedInsertionPointColor: NSColor?
    private var observers: [NSObjectProtocol] = []
    private static let signposter = OSSignposter(subsystem: "io.supersparrow.mac", category: "ai")

    init(textView: NSTextView, floatHost: NSView? = nil) {
        self.textView = textView
        self.floatHost = floatHost
        for view in [ghost, pencil, prompt, afterline] as [NSView] {
            view.isHidden = true
            textView.addSubview(view)
        }
        pill.isHidden = true
        (floatHost ?? textView).addSubview(pill)
        textView.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: textView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.textFrameDidChange() }
        })
        observers.append(center.addObserver(forName: QuireEnvironment.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            // Text size moves every line: the marks take the new style, and a block is measured again under its anchor.
            MainActor.assumeIsolated {
                self?.onEnvironmentChange?()
                self?.relayout(remeasure: true)
            }
        })
        if let clip = textView.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.onScroll?()
                    self.placePill()
                }
            })
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Showing

    /// Shows `new`: what changed comes or goes, a block's room is made or given back, and everything is placed again.
    func apply(_ new: State) {
        let signpost = Self.signposter.beginInterval("ai.place")
        defer { Self.signposter.endInterval("ai.place", signpost) }
        let old = state
        state = new
        if old.block != new.block {
            // A block that opens, or shows something new, is scrolled into view once its host has made its room.
            revealsBlock = new.block != nil
            setBlock(new.block)
        }
        place()
        if new.ghost != nil, !ghost.isHidden {
            if old.ghost == nil, new.ghost?.fades == true { ghost.fadeIn() } else if old.ghost == nil { ghost.showNow() }
        }
        updateInsertionPoint()
        invalidatePointer()
    }

    /// The marks came, went or moved: the text's I-beam is cut out of them again (§4.17).
    private func invalidatePointer() {
        guard let window = textView.window else { return }
        window.invalidateCursorRects(for: textView)
        if let clip = textView.enclosingScrollView?.contentView { window.invalidateCursorRects(for: clip) }
    }

    /// Everything placed again, as the text moved (a stream, a new width); `remeasure` measures a block's anchor again.
    func relayout(remeasure: Bool = false) {
        if remeasure, state.block != nil { setBlock(state.block, remeasured: true) }
        place()
    }

    /// While a reply streams the insertion point is not drawn: the pencil takes its place.
    private func updateInsertionPoint() {
        let hides = !pencil.isHidden || state.pencil != nil
        if hides, savedInsertionPointColor == nil {
            savedInsertionPointColor = textView.insertionPointColor
            textView.insertionPointColor = .clear
        } else if !hides, let saved = savedInsertionPointColor {
            textView.insertionPointColor = saved
            savedInsertionPointColor = nil
        }
    }

    private func textFrameDidChange() {
        let width = textView.textContainer?.size.width ?? 0
        if abs(width - containerWidth) > 0.5, state.block != nil {
            // A new width wraps the text again: the block is measured again under its anchor's line.
            setBlock(state.block, remeasured: true)
        }
        place()
    }

    // MARK: Blocks

    /// Makes `block`'s room in the text, or gives it back. `remeasured`: the text moved under a block that stays (a new
    /// width, a new text size), and its host may have measured its height against the room where it was: it is told
    /// again, even when the block's height and overflow come out the same.
    private func setBlock(_ block: Block?, remeasured: Bool = false) {
        guard let container = textView.textContainer, let manager = textView.layoutManager else { return }
        let before = (reservedHeight, overflow)
        containerWidth = container.size.width
        if !container.exclusionPaths.isEmpty { container.exclusionPaths = [] }
        guard let block else {
            blockRect = nil
            reservedHeight = 0
            overflow = 0
            if before != (reservedHeight, overflow) { onReservedSpaceChange?() }
            return
        }
        let line: NSRect?
        switch block.anchor {
        case .caret(let at):
            line = WriteTextGeometry.caret(at: at, in: textView, attributes: textAttributes).map {
                NSRect(x: 0, y: $0.line.minY - textView.textContainerOrigin.y, width: container.size.width, height: $0.line.height)
            }
        case .end(let at):
            line = WriteTextGeometry.lastLine(endingAt: at, in: textView)
        }
        let top = line?.maxY ?? 0
        let rect = NSRect(x: 0, y: top, width: container.size.width, height: block.height)
        container.exclusionPaths = [NSBezierPath(rect: rect)]
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        blockRect = rect
        reservedHeight = rect.height
        overflow = max(0, rect.maxY - max(used.maxY, manager.extraLineFragmentRect.maxY))
        if remeasured || before != (reservedHeight, overflow) { onReservedSpaceChange?() }
    }

    // MARK: Placing

    private var column: NSRect { WriteTextGeometry.column(of: textView) }

    /// Places every mark that shows, and hides the rest.
    func place() {
        placeBlock()
        placeGhost()
        placePencil()
        placePill()
    }

    private func placeBlock() {
        let c = Quire.Layout.WriteCaret.self
        let origin = textView.textContainerOrigin
        // Each is hidden or shown once, never hidden on the way: hiding the prompt line would take the keyboard out of it.
        let block = blockRect == nil ? nil : state.block
        prompt.isHidden = !(block?.isPrompt ?? false)
        afterline.isHidden = block == nil || block?.isPrompt == true
        guard let block, let rect = blockRect else { return }
        let column = column
        let top = origin.y + rect.minY + c.blockGapTop
        switch block {
        case .prompt:
            prompt.frame = NSRect(x: column.minX, y: top, width: column.width, height: rect.height - c.blockGapTop - c.blockGapBottom)
        case .afterline(_, let content):
            afterline.content = content
            afterline.frame = NSRect(x: column.minX, y: top, width: column.width, height: WriteAfterline.height)
        }
    }

    private func placeGhost() {
        guard let wanted = state.ghost,
              let caret = WriteTextGeometry.caret(at: wanted.location, in: textView, attributes: textAttributes), !caret.textFollows else {
            ghost.isHidden = true
            return
        }
        let c = Quire.Layout.WriteCaret.self
        ghost.words = wanted.words
        let x = caret.x + c.ghostGap + wanted.offset
        let room = caret.line.maxX - x
        let lineHeight = (textAttributes[.paragraphStyle] as? NSParagraphStyle)?.maximumLineHeight ?? caret.line.height
        // Whole where its line has room, its keycap alone where only that fits, else not at all: it never wraps and never
        // runs past the column.
        if ghost.width(showingWords: true) <= room {
            ghost.showsWords = true
        } else if ghost.width(showingWords: false) <= room {
            ghost.showsWords = false
        } else {
            ghost.isHidden = true
            return
        }
        let top = caret.baseline - ghost.baselineFromTop
        ghost.frame = ghost.frame(forVisualRect: NSRect(x: x, y: top, width: ghost.width(showingWords: ghost.showsWords),
                                                        height: lineHeight > 0 ? lineHeight : caret.line.height))
        ghost.isHidden = false
    }

    private func placePencil() {
        guard let location = state.pencil, let caret = WriteTextGeometry.caret(at: location, in: textView, attributes: textAttributes) else {
            pencil.isHidden = true
            return
        }
        let c = Quire.Layout.WriteCaret.self
        let lineHeight = (textAttributes[.paragraphStyle] as? NSParagraphStyle)?.maximumLineHeight ?? caret.line.height
        let probe = WriteTextGeometry.probeBaseline(textAttributes)
        func put(x: CGFloat, baseline: CGFloat, keycap: Bool) {
            pencil.showsKeycap = keycap
            pencil.frame = pencil.frame(forVisualRect: NSRect(x: x, y: baseline - probe, width: pencil.width(showingKeycap: keycap),
                                                              height: lineHeight))
            pencil.isHidden = false
            pencil.needsLayout = true
        }
        let x = caret.x + c.pencilGap
        let room = caret.textFollows ? 0 : caret.line.maxX - x
        if pencil.width(showingKeycap: true) <= room {
            put(x: x, baseline: caret.baseline, keycap: true)
        } else if pencil.width(showingKeycap: false) <= room {
            put(x: x, baseline: caret.baseline, keycap: false)
        } else if let next = emptyLineAfter(location) {
            // No room on the caret's line: the start of the next line, only when that line holds nothing.
            put(x: next.x + c.pencilGap, baseline: next.baseline, keycap: pencil.width(showingKeycap: true) <= next.line.maxX - next.x)
        } else {
            pencil.isHidden = true
        }
    }

    /// The caret at the start of the line after `location`'s, when that line is empty.
    private func emptyLineAfter(_ location: Int) -> WriteTextGeometry.Caret? {
        let text = textView.string as NSString
        guard location < text.length, WriteTextGeometry.isLineEnd(text.character(at: location)) else { return nil }
        let next = location + 1
        guard next == text.length || WriteTextGeometry.isLineEnd(text.character(at: next)) else { return nil }
        return WriteTextGeometry.caret(at: next, in: textView, attributes: textAttributes)
    }

    /// The pill hangs under the selection's last line, its leading edge at the selection's end; only where it lies wholly
    /// in the text's visible area (never over the quick reply's tool row, never out of the field or past the body's
    /// bottom edge). Else on the selection's last line, just after its end, where nothing follows it; else above the
    /// selection's first line; else at the end of the last line's text. Where none of these is in sight, it is not shown:
    /// ⌘J still rewrites.
    func placePill() {
        let host = floatHost ?? textView
        guard let selection = state.pill, !textView.isHiddenOrHasHiddenAncestor,
              let last = WriteTextGeometry.lastLine(endingAt: NSMaxRange(selection), in: textView),
              let end = WriteTextGeometry.caret(at: NSMaxRange(selection), in: textView, attributes: textAttributes),
              let start = WriteTextGeometry.caret(at: selection.location, in: textView, attributes: textAttributes) else {
            pill.isHidden = true
            return
        }
        let c = Quire.Layout.WriteCaret.self
        let size = pill.intrinsicContentSize
        let column = column
        let origin = textView.textContainerOrigin
        let lastLine = NSRect(x: column.minX, y: origin.y + last.minY, width: column.width, height: last.height)
        func clamped(_ x: CGFloat) -> CGFloat { min(max(x, column.minX), max(column.minX, column.maxX - size.width)) }
        func onLine(_ line: NSRect, x: CGFloat) -> NSRect {
            NSRect(x: x, y: (line.midY - size.height / 2).rounded(), width: size.width, height: size.height)
        }
        var candidates: [(rect: NSRect, inline: Bool)] = [
            (NSRect(x: clamped(end.x), y: lastLine.maxY + c.pillGap, width: size.width, height: size.height), false),
        ]
        if !end.textFollows, end.x + c.pillGap + size.width <= column.maxX {
            candidates.append((onLine(lastLine, x: end.x + c.pillGap), true))
        }
        candidates.append((NSRect(x: clamped(end.x), y: start.line.minY - c.pillGap - size.height, width: size.width,
                                  height: size.height), false))
        if let used = usedEnd(ofLineAt: NSMaxRange(selection) - 1), used + c.pillGap + size.width <= column.maxX {
            candidates.append((onLine(lastLine, x: used + c.pillGap), true))
        }
        // The text's visible area, in the text view: the quick reply's text area, the body's visible page.
        var visible = textView.visibleRect
        if let clip = textView.enclosingScrollView?.contentView { visible = textView.convert(clip.bounds, from: clip) }
        let chosen = candidates.first { candidate in
            // A pill on its line may reach past a one-line field by its own extra height, never past its line's room.
            let room = candidate.inline ? visible.insetBy(dx: 0, dy: -(size.height - lastLine.height) / 2 - 1) : visible
            return room.contains(candidate.rect) && visible.intersects(lastLine)
        }
        guard let chosen else {
            pill.isHidden = true
            return
        }
        pill.frame = pill.frame(forVisualRect: host.convert(chosen.rect, from: textView))
        pill.isHidden = false
        if pill.superview !== host { host.addSubview(pill) }
    }

    /// Where the text of the line holding `character` ends, in the text view: the last letter's trailing edge.
    private func usedEnd(ofLineAt character: Int) -> CGFloat? {
        guard character >= 0, let manager = textView.layoutManager, character < (textView.textStorage?.length ?? 0) else { return nil }
        let glyph = manager.glyphIndexForCharacter(at: character)
        var range = NSRange()
        let fragment = manager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: &range)
        return textView.textContainerOrigin.x + fragment.maxX
    }

    // MARK: Reading

    /// The marks' areas, in the text view: the text's I-beam is cut out of them, so each keeps its own pointer.
    var pointerHoles: [NSRect] {
        var holes: [NSRect] = []
        for view in [ghost, pencil, prompt, afterline] as [NSView] where !view.isHidden {
            if let control = view as? QuireControl {
                holes.append(control.convert(control.hitRect, to: textView))
            } else {
                holes.append(view.frame)
            }
        }
        // The pill floats on its host (the quick reply's bar), over the text all the same: the I-beam leaves it its own.
        if !pill.isHidden, pill.superview != nil { holes.append(pill.convert(pill.hitRect, to: textView)) }
        return holes
    }

    /// Whether the keyboard is in the prompt line.
    var promptHoldsFocus: Bool { !prompt.isHidden && prompt.holdsFocus }

    /// Scrolls the text so a block that just opened or changed shows whole, with the line it hangs under: a reply longer
    /// than the field leaves the caret on its last visible line, and the afterline under it out of sight. Once per block;
    /// the host calls it when the field has taken the block's room (after its layout), so the scroll is measured against
    /// the room the field ends with. Scrolling back up past it afterwards is the reader's own.
    func revealBlockIfNeeded() {
        guard revealsBlock else { return }
        revealsBlock = false
        guard let rect = blockRect, textView.enclosingScrollView != nil else { return }
        let origin = textView.textContainerOrigin
        let anchorTop: CGFloat
        switch state.block?.anchor {
        case .caret(let at)?:
            anchorTop = WriteTextGeometry.caret(at: at, in: textView, attributes: textAttributes).map { $0.line.minY - origin.y } ?? rect.minY
        case .end(let at)?:
            anchorTop = WriteTextGeometry.lastLine(endingAt: at, in: textView)?.minY ?? rect.minY
        case nil:
            anchorTop = rect.minY
        }
        let shown = NSRect(x: 0, y: origin.y + min(anchorTop, rect.minY), width: textView.bounds.width,
                           height: rect.maxY - min(anchorTop, rect.minY))
        // Where the field cannot hold the line and the block together, the block wins: it holds what to do next.
        let visible = textView.visibleRect.height
        textView.scrollToVisible(shown.height > visible ? NSRect(x: 0, y: shown.maxY - visible, width: shown.width, height: visible) : shown)
    }

    /// The height the text needs with the block: its used rect, and the block where it hangs below it.
    var contentHeight: CGFloat {
        guard let manager = textView.layoutManager, let container = textView.textContainer else { return 0 }
        let used = manager.usedRect(for: container)
        return max(used.maxY, blockRect?.maxY ?? 0)
    }
}
