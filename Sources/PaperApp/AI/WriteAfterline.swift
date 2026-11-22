import AppKit
import PaperDesign

/// The afterline (§5.56): one quiet `meta` row in the text's flow, under the draft's last line (a failure's under the
/// caret's line), at the text column's leading edge. After a reply lands: `pencil.line` and “Written by Claude”
/// (`ink3`), then its actions, each its words then its quiet keycap: Try again ⌘J · Shorter · Say how ⇧⌘J · Undo ⌘Z
/// (`metaStrong` `ink2`, `accent` under the pointer, no borders). After a failure: the failed glyph, the reason in
/// `danger`, Try again ⌘J and, when the fix is there, Settings….
///
/// The row never draws past the column. Where it is tight it gives way in a fixed order, each step measured: a reply's
/// keycaps first, then Shorter, then “Written by Claude”'s words (the glyph stays), then Say how; a failure's keycap,
/// then its reason cut at a character with an ellipsis.
@MainActor
final class WriteAfterline: NSView {
    enum Content: Equatable {
        /// A reply (or, `rewrite`, a selection) just written by `writer`; `source` the model and its company, for the
        /// tooltip.
        case written(writer: String, rewrite: Bool, source: String?)
        case failed(reason: String, offersSettings: Bool)
    }

    enum Action: CaseIterable {
        case tryAgain, shorter, sayHow, undo, settings
    }

    var content: Content = .written(writer: "Claude", rewrite: false, source: nil) {
        didSet { if oldValue != content { apply() } }
    }

    var onAction: ((Action) -> Void)?

    private(set) var actions: [Action: ActionLink] = [:]

    /// The form the row takes now (tests): what its room let it keep.
    private(set) var form = Form()

    struct Form: Equatable {
        var keycaps = true
        var shorter = true
        var words = true
        var sayHow = true
        /// A failure's reason cut to the room left.
        var cutsReason = false
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for action in Action.allCases {
            let link = ActionLink(frame: .zero)
            link.onPress = { [weak self] in self?.onAction?(action) }
            actions[action] = link
            addSubview(link)
        }
        actions[.tryAgain]?.title = WriteWords.tryAgain
        actions[.tryAgain]?.keycap = "\u{2318}J"
        actions[.tryAgain]?.toolTip = "Try Again  \u{2318}J"
        actions[.shorter]?.title = WriteWords.presets[0]
        actions[.shorter]?.toolTip = "Write It Shorter"
        actions[.sayHow]?.title = WriteWords.sayHow
        actions[.sayHow]?.keycap = "\u{21e7}\u{2318}J"
        actions[.sayHow]?.toolTip = "Say How  \u{21e7}\u{2318}J"
        actions[.undo]?.title = WriteWords.undo
        actions[.undo]?.keycap = "\u{2318}Z"
        actions[.undo]?.toolTip = "Undo Help Me Write  \u{2318}Z"
        actions[.settings]?.title = WriteWords.settings
        actions[.settings]?.toolTip = "Settings \u{203a} AI\u{2026}"
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("built in code")
    }

    override var isFlipped: Bool { true }

    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Content

    private var glyphName: String {
        if case .failed = content { return Quire.Icon.failed }
        return Quire.Icon.helpMeWrite
    }

    private var glyphColor: NSColor {
        if case .failed = content { return .qDanger }
        return .qInk3
    }

    /// The row's words before its actions: “Written by Claude”, or a failure's reason.
    var words: String {
        switch content {
        case .written(let writer, let rewrite, _): return WriteWords.written(by: writer, rewrite: rewrite)
        case .failed(let reason, _): return reason
        }
    }

    private var wordsColor: NSColor {
        if case .failed = content { return .qDanger }
        return .qInk3
    }

    /// The actions the content offers, in order.
    private var offered: [Action] {
        switch content {
        case .written: return [.tryAgain, .shorter, .sayHow, .undo]
        case .failed(_, let settings): return settings ? [.tryAgain, .settings] : [.tryAgain]
        }
    }

    /// The whole row in words, keys included, whatever its room shows: VoiceOver's, and the tests'.
    var lineWords: String {
        ([words] + offered.map { action -> String in
            guard let link = actions[action] else { return "" }
            return link.keycap.map { "\(link.title) \($0)" } ?? link.title
        }).joined(separator: " \u{00b7} ")
    }

    /// What the row shows now, as its room left it (tests and renders).
    var shownWords: String {
        var parts: [String] = []
        if form.words || content.isFailure { parts.append(shownReason) }
        for action in offered {
            guard let link = actions[action], !link.isHidden else { continue }
            parts.append(link.showsKeycap ? "\(link.title) \(link.keycap ?? "")".trimmingCharacters(in: .whitespaces) : link.title)
        }
        return parts.joined(separator: " \u{00b7} ")
    }

    private var shownReason = ""

    private func apply() {
        switch content {
        case .written(_, _, let source):
            toolTip = source
            setAccessibilityLabel(lineWords)
        case .failed(let reason, _):
            toolTip = reason
            setAccessibilityLabel("Couldn\u{2019}t write. " + lineWords)
        }
        actions[.tryAgain]?.isRemedy = content.isFailure
        actions[.settings]?.isRemedy = true
        needsLayout = true
        needsDisplay = true
    }

    // MARK: Layout

    private var forms: [Form] {
        switch content {
        case .written:
            return [Form(), Form(keycaps: false), Form(keycaps: false, shorter: false),
                    Form(keycaps: false, shorter: false, words: false),
                    Form(keycaps: false, shorter: false, words: false, sayHow: false)]
        case .failed:
            return [Form(), Form(keycaps: false), Form(keycaps: false, cutsReason: true)]
        }
    }

    /// The row's height (`layout.writeCaret.afterlineHeight`).
    nonisolated static var height: CGFloat { Quire.Layout.WriteCaret.afterlineHeight }

    private struct Placed {
        var glyph: NSRect = .zero
        var words: NSRect = .zero
        var reason = ""
        var dots: [CGFloat] = []
        var links: [(Action, NSRect, Bool)] = []
        var width: CGFloat = 0
    }

    private var placed = Placed()

    private static func text(_ words: String, _ role: QuireFont.Role, _ color: NSColor) -> NSAttributedString {
        QuireFont.attributedString(words, role: role, color: color)
    }

    private static let dot = "\u{00b7}"

    /// Lays `form` out from the leading edge in a row `room` wide; its trailing edge is `width`.
    private func place(_ form: Form, room: CGFloat) -> Placed {
        let c = Quire.Layout.WriteCaret.self
        let height = bounds.height > 0 ? bounds.height : Self.height
        var out = Placed()
        let glyph = WriteGlyph.size(glyphName, size: c.afterGlyph, weight: content.isFailure ? .semibold : .regular)
        out.glyph = NSRect(x: 0, y: ((height - glyph.height) / 2).rounded(), width: ceil(glyph.width), height: ceil(glyph.height))
        var x = out.glyph.maxX
        let lineHeight = QuireFont.Role.meta.lineHeight
        let dotWidth = ceil(Self.text(Self.dot, .meta, .qInk3).size().width)
        let actionsWidth = offered.filter { include($0, form) }.reduce(CGFloat(0)) { sum, action in
            sum + 2 * c.afterGap + dotWidth + (actions[action]?.width(showingKeycap: form.keycaps) ?? 0)
        }
        if form.words || content.isFailure {
            var reason = words
            var width = ceil(Self.text(reason, .meta, wordsColor).size().width)
            if form.cutsReason {
                let available = max(0, room - x - c.afterGlyphGap - actionsWidth)
                if width > available {
                    reason = WriteAfterline.cut(words, toFit: available, color: wordsColor)
                    width = ceil(Self.text(reason, .meta, wordsColor).size().width)
                }
            }
            out.reason = reason
            out.words = NSRect(x: x + c.afterGlyphGap, y: ((height - lineHeight) / 2).rounded(), width: width, height: lineHeight)
            x = out.words.maxX
        }
        for action in offered where include(action, form) {
            guard let link = actions[action] else { continue }
            out.dots.append(x + c.afterGap)
            x += c.afterGap + dotWidth + c.afterGap
            let size = NSSize(width: link.width(showingKeycap: form.keycaps), height: link.faceHeight)
            out.links.append((action, NSRect(x: x, y: ((height - size.height) / 2).rounded(), width: size.width, height: size.height),
                              form.keycaps))
            x += size.width
        }
        out.width = ceil(x)
        return out
    }

    private func include(_ action: Action, _ form: Form) -> Bool {
        switch action {
        case .shorter: return form.shorter
        case .sayHow: return form.sayHow
        default: return true
        }
    }

    /// The width the row would like: everything whole.
    var fittingWidth: CGFloat { place(Form(), room: .greatestFiniteMagnitude).width }

    override func layout() {
        super.layout()
        let room = bounds.width
        let chosen = forms.first { place($0, room: room).width <= room + 0.5 } ?? forms.last ?? Form()
        form = chosen
        placed = place(chosen, room: room)
        shownReason = placed.reason
        let shown = Set(placed.links.map(\.0))
        for (action, link) in actions {
            link.isHidden = !shown.contains(action)
        }
        for (action, rect, keycaps) in placed.links {
            guard let link = actions[action] else { continue }
            link.showsKeycap = keycaps
            link.frame = link.frame(forVisualRect: rect)
            // A guard, should a measure and a placement ever disagree: nothing shows past the column.
            if rect.maxX > room + 0.5 { link.isHidden = true }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = Quire.Layout.WriteCaret.self
        WriteGlyph.draw(glyphName, size: c.afterGlyph, weight: content.isFailure ? .semibold : .regular, color: glyphColor,
                        centredIn: placed.glyph)
        if !placed.reason.isEmpty, placed.words.width > 0 {
            Self.text(placed.reason, .meta, wordsColor).draw(with: placed.words.insetBy(dx: 0, dy: 0).offsetBy(dx: 0, dy: 0),
                                                              options: QuireFont.drawingOptions, context: nil)
        }
        let lineHeight = QuireFont.Role.meta.lineHeight
        for x in placed.dots {
            Self.text(Self.dot, .meta, .qInk3).draw(with: NSRect(x: x, y: ((bounds.height - lineHeight) / 2).rounded(), width: 8,
                                                                 height: lineHeight), options: QuireFont.drawingOptions, context: nil)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// `words` cut at a character to fit `width` points, with an ellipsis: at least its first letter and the ellipsis.
    static func cut(_ words: String, toFit width: CGFloat, color: NSColor) -> String {
        func measure(_ s: String) -> CGFloat { ceil(text(s, .meta, color).size().width) }
        guard measure(words) > width else { return words }
        let characters = Array(words)
        var low = 1
        var high = characters.count
        while low < high {
            let mid = (low + high + 1) / 2
            let candidate = String(characters[..<mid]).trimmingCharacters(in: .whitespaces) + "\u{2026}"
            if measure(candidate) <= width { low = mid } else { high = mid - 1 }
        }
        return String(characters[..<low]).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    // MARK: Actions

    /// One of the afterline's actions: its words in `metaStrong` `ink2`, `accent` under the pointer, then its quiet
    /// keycap. On a failure, Try again and Settings… are the remedy and keep `accent`.
    final class ActionLink: WriteInlineControl {
        var title = "" { didSet { needsDisplay = true; setAccessibilityLabel(title) } }
        var keycap: String? { didSet { needsDisplay = true } }
        var showsKeycap = true { didSet { if oldValue != showsKeycap { needsDisplay = true } } }
        /// A failure's way out: `accent` at rest too.
        var isRemedy = false { didSet { if oldValue != isRemedy { needsDisplay = true } } }

        var faceHeight: CGFloat { max(QuireFont.Role.metaStrong.lineHeight, Quire.Layout.WriteCaret.keycapHeight) }

        private func label(_ color: NSColor) -> NSAttributedString {
            QuireFont.attributedString(title, role: .metaStrong, color: color)
        }

        func width(showingKeycap: Bool) -> CGFloat {
            var width = ceil(label(.qInk2).size().width)
            if showingKeycap, let keycap {
                width += Quire.Layout.WriteCaret.keycapGap + WriteQuietKeycap.size(keycap).width
            }
            return width
        }

        override var intrinsicContentSize: NSSize { NSSize(width: width(showingKeycap: showsKeycap), height: faceHeight) }

        override func draw(_ dirtyRect: NSRect) {
            let face = bodyRect
            let state = interactionState
            let color: NSColor = state == .pressed ? .qInk : (state == .hover || isRemedy ? .qAccent : .qInk2)
            let text = label(color)
            let width = ceil(text.size().width)
            let lineHeight = QuireFont.Role.metaStrong.lineHeight
            let top = (face.midY - lineHeight / 2).rounded()
            text.draw(with: NSRect(x: face.minX, y: top, width: width + 1, height: lineHeight), options: QuireFont.drawingOptions,
                      context: nil)
            if state != .rest || QuireEnvironment.underlinesLinksAtRest(for: effectiveAppearance) && isRemedy {
                color.setFill()
                NSRect(x: face.minX, y: (top + lineHeight - 2).rounded(), width: width, height: 1).fill()
            }
            if showsKeycap, let keycap {
                let size = WriteQuietKeycap.size(keycap)
                let rect = NSRect(x: face.minX + width + Quire.Layout.WriteCaret.keycapGap, y: (face.midY - size.height / 2).rounded(),
                                  width: size.width, height: size.height)
                WriteQuietKeycap.draw(keycap, in: rect, ink: state == .rest ? .qInk3 : .qInk2,
                                      edge: state == .rest ? .qRule : .qRuleStrong, hairline: hairline)
            }
        }
    }
}

private extension WriteAfterline.Content {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
