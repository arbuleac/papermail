import AppKit
import PaperCore
import PaperDesign

/// An event's details (spec §5.54): a fixed top (kicker, title, when), a middle that scrolls when the card would pass
/// the window's bottom (where it was written, how it repeats, its status and overlap, the rows, the mail, the notes),
/// and a fixed footer (the answers, the answer line, Join, Remove, Open in). Built from `EventDetailsModel`; `apply`
/// re-uses nothing but keeps focus on the control with the same key and keeps the scroll offset, so a re-read in place
/// never moves the user. A pointer cover: the arrow over it, the hand on its controls, the I-beam over its text.
@MainActor
final class EventDetailsCardView: NSView, QuirePointerCover {
    typealias Pane = Quire.Layout.CalendarPane

    // What the card asks of whoever shows it.
    var onAnswer: ((InvitationResponse, QuireButton) -> Void)?
    var onLink: ((URL, AnalyticsSignal.EventAction) -> Void)?
    var onCopy: ((EventDetailsModel.CopyItem, String, QuireIconButton) -> Void)?
    var onShowMail: ((MessageID) -> Void)?
    var onAction: ((EventDetailsModel.ActionKind) -> Void)?
    var onControl: ((String) -> Void)?
    var onReconnect: ((AccountID) -> Void)?
    var onClose: (() -> Void)?

    private let sheet = QuireSheetView(frame: .zero)
    private let top = CardStack()
    private let scroll = NSScrollView()
    private let middle = CardStack()
    private let footer = CardStack()
    private let middleTopRule = NSBox()
    private let middleBottomRule = NSBox()
    private(set) var model: EventDetailsModel?
    /// The controls by stable key, in Tab order.
    private(set) var keyed: [(key: String, view: NSView)] = []
    private(set) var answerButtons: [InvitationResponse: QuireButton] = [:]
    private(set) var notesView: EventNotesTextView?
    /// How tall the card may be: the presenter's room (at most `detailsMaxHeight`).
    var maxHeight: CGFloat = Pane.detailsMaxHeight {
        didSet { if oldValue != maxHeight { needsLayout = true } }
    }
    var notesExpanded = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Pane.detailsWidth, height: 100))
        sheet.fillColor = .qRaised
        sheet.elevation = Quire.Elevation.e2
        sheet.cornerRadius = Pane.detailsRadius
        sheet.showsEdge = true
        addSubview(sheet)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.documentView = middle
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        for rule in [middleTopRule, middleBottomRule] {
            rule.boxType = .custom
            rule.borderWidth = 0
            rule.fillColor = .qRule
            rule.isHidden = true
        }
        sheet.contentView.addSubview(top)
        sheet.contentView.addSubview(scroll)
        sheet.contentView.addSubview(footer)
        sheet.contentView.addSubview(middleTopRule)
        sheet.contentView.addSubview(middleBottomRule)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilitySubrole(.dialog)
        setAccessibilityHelp("Event details")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var inner: CGFloat { Pane.detailsWidth - 2 * Pane.detailsPadX }

    // MARK: Building

    func apply(_ model: EventDetailsModel) {
        let focusedKey = keyed.first { window?.firstResponder === $0.view }?.key
        let offset = scroll.contentView.bounds.origin
        self.model = model
        keyed = []
        answerButtons = [:]
        top.clear()
        middle.clear()
        footer.clear()
        buildTop(model)
        buildMiddle(model)
        buildFooter(model)
        setAccessibilityLabel(model.accessibilityName)
        relayout()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(offset.y, max(0, middle.frame.height - scroll.contentView.bounds.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
        linkKeyViews()
        if let focusedKey, let view = keyed.first(where: { $0.key == focusedKey })?.view {
            window?.makeFirstResponder(view)
        } else if focusedKey != nil {
            // The control that had focus is gone (an answer that is no longer offered): the card itself takes it.
            window?.makeFirstResponder(self)
        }
        pointerCoverDidChange()
    }

    private func buildTop(_ model: EventDetailsModel) {
        let kicker = KickerView(dot: model.dot, text: model.kicker, cancelled: model.isCancelled)
        top.add(kicker, gap: 0)
        let title = EventDetailsText.label(model.title, role: .title,
                                           color: model.isCancelled ? .qInk2 : model.titleIsPlaceholder ? .qInk3 : .qInk,
                                           selectable: !model.titleIsPlaceholder, maxLines: 3, italic: model.titleIsPlaceholder,
                                           struck: model.isCancelled)
        top.add(title, gap: Pane.detailsTitleTop)
        top.add(EventDetailsText.label(model.when, role: .body, color: .qInk, selectable: true, tabular: true), gap: Pane.detailsWhenTop)
        top.spoken = model.spokenTop
    }

    private func buildMiddle(_ model: EventDetailsModel) {
        var first = true
        func gap(_ value: CGFloat) -> CGFloat {
            defer { first = false }
            return first ? 0 : value
        }
        if let elsewhere = model.elsewhere {
            let field = EventDetailsText.label(elsewhere, role: .snippet, color: .qInk3, selectable: true, tabular: true)
            field.setAccessibilityLabel(model.spokenElsewhere)
            middle.add(field, gap: gap(Pane.detailsLineTop))
        }
        if let repeats = model.repeats {
            middle.add(EventDetailsText.label(repeats, role: .snippet, color: .qInk2, selectable: true), gap: gap(Pane.detailsLineTop))
        }
        if let status = model.status {
            middle.add(GlyphLine(glyph: status.glyph, glyphColor: status.color, text: status.text, color: status.color),
                       gap: gap(Pane.detailsStatusTop))
        }
        if let overlap = model.overlap {
            middle.add(GlyphLine(glyph: Quire.Icon.warning, glyphColor: .qWarning, text: overlap, color: .qInk), gap: gap(Pane.detailsStatusTop))
        }
        var firstRow = true
        for row in model.rows {
            let view = EventDetailsRowView(row: row)
            view.onLink = { [weak self] url, action in self?.onLink?(url, action) }
            view.onCopy = { [weak self] item, value, button in self?.onCopy?(item, value, button) }
            view.onControl = { [weak self] control in self?.onControl?(control) }
            middle.add(view, gap: gap(firstRow ? Pane.detailsSectionTop : Pane.detailsRowGap))
            firstRow = false
            for (index, control) in view.controls.enumerated() { keyed.append((row.key + ".\(index)", control)) }
        }
        if let mail = model.mail {
            let view = MailRowView(mail: mail) { [weak self] id in self?.onShowMail?(id) }
            middle.add(view, gap: gap(firstRow ? Pane.detailsSectionTop : Pane.detailsRowGap))
            if let button = view.button { keyed.append(("row.mail", button)) }
        }
        if let notes = model.notes {
            let rule = NSBox()
            rule.boxType = .custom
            rule.borderWidth = 0
            rule.fillColor = .qRule
            middle.add(rule, gap: gap(Pane.detailsSectionTop), height: 1)
            let text = EventNotesTextView()
            text.show(notes)
            text.onLink = { [weak self] url in self?.onLink?(url, .notesLink) }
            notesView = text
            let lines = notesExpanded ? 0 : Int(Pane.detailsNotesLines)
            middle.add(text, gap: Pane.detailsSectionTop, measure: { width in text.height(forWidth: width, lines: lines) })
            if notesExpanded || text.isClamped(atWidth: inner, lines: Int(Pane.detailsNotesLines)) {
                let more = QuireButton(title: notesExpanded ? "Show less" : "Show more", variant: .link, size: .small,
                                       target: self, action: #selector(toggleNotes(_:)))
                middle.add(more, gap: 4, leadingInset: -Quire.Layout.Button.linkPadX)
                keyed.append(("notes.more", more))
            }
            if let cut = model.notesCutLine {
                middle.add(EventDetailsText.label(cut, role: .snippet, color: .qInk3), gap: 4)
            }
        }
    }

    private func buildFooter(_ model: EventDetailsModel) {
        var hasAnswers = false
        if let answers = model.answers {
            hasAnswers = true
            let rule = NSBox()
            rule.boxType = .custom
            rule.borderWidth = 0
            rule.fillColor = (QuireEnvironment.increaseContrast ? NSColor.qRuleStrong : .qRule)
            footer.add(rule, gap: 0, height: 1)
            let row = ButtonRow(gap: Quire.Layout.Invitation.answerGap)
            for response in InvitationResponse.answers {
                let button = QuireButton(title: EventDetailsModel.titlesOfAnswers[response] ?? "", variant: .choice, size: .small,
                                         target: self, action: #selector(answerClicked(_:)))
                button.tag = InvitationResponse.answers.firstIndex(of: response) ?? 0
                button.isOn = answers.chosen == response
                if button.isOn, answers.waiting { button.onSymbol = Quire.Icon.pending }
                if answers.waiting, button.isOn { button.setAccessibilityHelp("Your answer is on its way.") }
                if answers.asksSpan { button.setAccessibilityHelp("Asks whether to answer this event or all events.") }
                row.add(button)
                answerButtons[response] = button
                keyed.append(("answer.\(response.rawValue)", button))
            }
            footer.add(row, gap: Quire.Layout.Invitation.actionsPad)
            switch model.answerLine {
            case .failed?:
                footer.add(GlyphLine(glyph: Quire.Icon.failed, glyphColor: .qDanger, text: "Couldn't answer the invitation.",
                                     color: .qDanger), gap: 6)
            case .outlookDecline?:
                footer.add(EventDetailsText.label("Outlook takes declined events off your calendar.", role: .snippet, color: .qInk3),
                           gap: 6)
            case .permission(let account)?:
                let banner = QuireBannerView(kind: .info, message: "Answer invitations: Paper needs permission to update your calendar.")
                banner.allowsMultipleLines = true
                let reconnect = banner.setAction("Reconnect", target: self, action: #selector(reconnectClicked(_:)))
                reconnect?.identifier = NSUserInterfaceItemIdentifier(account.rawValue)
                footer.add(banner, gap: Quire.Layout.Invitation.noticeTop, measure: { width in banner.height(forWidth: width) })
                if let reconnect { keyed.append(("answer.reconnect", reconnect)) }
            case nil:
                break
            }
        }
        if !model.actions.isEmpty {
            let row = ButtonRow(gap: Pane.detailsActionGap)
            for (index, action) in model.actions.enumerated() {
                let button = QuireButton(title: action.title, variant: action.variant, size: .small, symbolName: action.symbol,
                                         target: self, action: #selector(actionClicked(_:)))
                button.tag = index
                if case .join = action.kind { button.setAccessibilityLabel("Join the call, " + model.title) }
                row.add(button, trailing: action.variant == .link)
                keyed.append((action.key, button))
            }
            footer.add(row, gap: hasAnswers ? Pane.detailsFooterGap : 0)
        }
    }

    /// The Tab loop: the card's controls in order, around and around.
    private func linkKeyViews() {
        let views = keyed.map(\.view)
        for (index, view) in views.enumerated() {
            view.nextKeyView = views[(index + 1) % views.count]
        }
    }

    /// The control focus goes to when the keyboard opened the card: Join, else the first that is not an answer, else
    /// the card itself. Never an answer: a second ↩ would answer.
    var initialKeyView: NSView {
        if let join = keyed.first(where: { $0.key == "footer.join" })?.view { return join }
        return keyed.first { !$0.key.hasPrefix("answer.") }?.view ?? self
    }

    var keyViews: [NSView] { keyed.map(\.view) }

    /// The card's buttons, in Tab order.
    var buttons: [QuireButton] { keyed.compactMap { $0.view as? QuireButton } }

    // MARK: Layout

    private var footerHeight: CGFloat {
        let height = footer.height(forWidth: inner)
        return height > 0 ? Quire.Layout.Invitation.actionsTop + height : 0
    }

    private var naturalHeight: CGFloat {
        let middleHeight = middle.height(forWidth: inner)
        return ceil(Pane.detailsPadTop + top.height(forWidth: inner) + (middleHeight > 0 ? Pane.detailsSectionTop : 0) + middleHeight
                    + footerHeight + Pane.detailsPadBottom)
    }

    /// The card's height: its content, at most `maxHeight`, the middle keeping at least its minimum.
    var preferredHeight: CGFloat {
        let fixed = Pane.detailsPadTop + top.height(forWidth: inner) + footerHeight + Pane.detailsPadBottom
        let middleHeight = middle.height(forWidth: inner)
        guard middleHeight > 0 else { return ceil(fixed) }
        return ceil(min(naturalHeight, max(maxHeight, fixed + Pane.detailsSectionTop + min(middleHeight, Pane.detailsMiddleMinHeight))))
    }

    /// Whether the middle is cut and scrolls.
    var middleScrolls: Bool { naturalHeight > preferredHeight + 0.5 }

    private func relayout() {
        setFrameSize(NSSize(width: Pane.detailsWidth, height: preferredHeight))
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        sheet.frame = bounds
        let x = Pane.detailsPadX
        let topHeight = top.height(forWidth: inner)
        top.frame = NSRect(x: x, y: Pane.detailsPadTop, width: inner, height: topHeight)
        top.layoutStack()
        let footerHeight = footer.height(forWidth: inner)
        let footerTop = bounds.height - Pane.detailsPadBottom - footerHeight
        footer.frame = NSRect(x: x, y: footerTop, width: inner, height: footerHeight)
        footer.layoutStack()
        let middleHeight = middle.height(forWidth: inner)
        let middleTop = Pane.detailsPadTop + topHeight + (middleHeight > 0 ? Pane.detailsSectionTop : 0)
        let middleBottom = footerHeight > 0 ? footerTop - Quire.Layout.Invitation.actionsTop : bounds.height - Pane.detailsPadBottom
        scroll.frame = NSRect(x: x - 4, y: middleTop, width: inner + 8, height: max(0, middleBottom - middleTop))
        middle.frame = NSRect(x: 0, y: 0, width: inner + 8, height: middleHeight)
        middle.insetX = 4
        middle.layoutStack()
        middleTopRule.frame = NSRect(x: x, y: middleTop, width: inner, height: 1)
        middleBottomRule.frame = NSRect(x: x, y: scroll.frame.maxY - 1, width: inner, height: 1)
        updateScrollRules()
        pointerRegionsDidChange()
    }

    @objc private func scrolled() {
        updateScrollRules()
    }

    /// A hairline on an edge of the middle while content is cut off there.
    private func updateScrollRules() {
        let visible = scroll.contentView.bounds
        middleTopRule.isHidden = visible.minY <= 0.5
        middleBottomRule.isHidden = visible.maxY >= middle.frame.height - 0.5
    }

    /// Scrolls the middle so `view` (Show more's text, a focused control) is in sight.
    func reveal(_ view: NSView) {
        let rect = middle.convert(view.bounds, from: view)
        middle.scrollToVisible(rect)
    }

    // MARK: Actions

    @objc private func answerClicked(_ sender: QuireButton) {
        guard InvitationResponse.answers.indices.contains(sender.tag) else { return }
        onAnswer?(InvitationResponse.answers[sender.tag], sender)
    }

    @objc private func actionClicked(_ sender: QuireButton) {
        guard let actions = model?.actions, actions.indices.contains(sender.tag) else { return }
        onAction?(actions[sender.tag].kind)
    }

    @objc private func toggleNotes(_ sender: QuireButton) {
        onControl?("notes.toggle")
    }

    @objc private func reconnectClicked(_ sender: QuireButton) {
        guard let raw = sender.identifier?.rawValue else { return }
        onReconnect?(AccountID(raw))
    }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

    // MARK: Pointer

    var pointerRegions: [QuirePointerRegion] {
        QuirePointerRegion.regions(bounds, cursor: .arrow, cutting: childPointerAreas())
    }

    override func resetCursorRects() {
        addPointerRects()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pointerCoverDidChange()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let old = frame.origin
        super.setFrameOrigin(newOrigin)
        if frame.origin != old { pointerCoverDidChange() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let old = frame.size
        super.setFrameSize(newSize)
        if frame.size != old { pointerCoverDidChange() }
    }

    /// A click on the card itself (not a control) stays on it, rather than reaching what lies under it.
    override func mouseDown(with event: NSEvent) {}

    override var acceptsFirstResponder: Bool { true }

    override func accessibilityChildren() -> [Any]? { [top, scroll, footer] }
}

// MARK: Parts

/// A vertical stack laid out by hand: each part with its gap above and its height at a width.
@MainActor
final class CardStack: NSView {
    private var parts: [(view: NSView, gap: CGFloat, height: CGFloat?, measure: ((CGFloat) -> CGFloat)?, inset: CGFloat)] = []
    var insetX: CGFloat = 0
    /// What VoiceOver reads for the whole stack, when it reads as one line (the card's top).
    var spoken: String? {
        didSet {
            setAccessibilityElement(spoken != nil)
            setAccessibilityRole(.staticText)
            setAccessibilityLabel(spoken)
        }
    }

    override var isFlipped: Bool { true }

    func clear() {
        for part in parts { part.view.removeFromSuperview() }
        parts = []
    }

    func add(_ view: NSView, gap: CGFloat, height: CGFloat? = nil, leadingInset: CGFloat = 0,
             measure: ((CGFloat) -> CGFloat)? = nil) {
        addSubview(view)
        parts.append((view, gap, height, measure, leadingInset))
    }

    private func height(of part: (view: NSView, gap: CGFloat, height: CGFloat?, measure: ((CGFloat) -> CGFloat)?, inset: CGFloat),
                        width: CGFloat) -> CGFloat {
        if let height = part.height { return height }
        if let measure = part.measure { return measure(width) }
        switch part.view {
        case let field as NSTextField: return EventDetailsText.height(of: field, width: width)
        case let row as EventDetailsRowView: return row.height(forWidth: width)
        case let measured as MeasuredView: return measured.height(forWidth: width)
        case let button as QuireButton: return button.intrinsicContentSize.height
        default: return part.view.fittingSize.height
        }
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        parts.reduce(0) { $0 + $1.gap + height(of: $1, width: width) }
    }

    func layoutStack() {
        let width = bounds.width - 2 * insetX
        var y: CGFloat = 0
        for part in parts {
            y += part.gap
            let h = height(of: part, width: width)
            if let button = part.view as? QuireButton {
                let size = button.intrinsicContentSize
                button.frame = button.frame(forVisualRect: NSRect(x: insetX + part.inset, y: y, width: size.width, height: size.height))
            } else {
                part.view.frame = NSRect(x: insetX + part.inset, y: y, width: width - part.inset, height: h)
            }
            y += h
        }
    }

    override func accessibilityChildren() -> [Any]? {
        spoken != nil ? nil : parts.map(\.view)
    }
}

/// A part that knows its height at a width.
@MainActor
protocol MeasuredView: NSView {
    func height(forWidth width: CGFloat) -> CGFloat
}

/// Buttons in a row, wrapping; a trailing one (Open in…) at the trailing edge.
@MainActor
final class ButtonRow: NSView, MeasuredView {
    private var buttons: [(button: QuireButton, trailing: Bool)] = []
    private let gap: CGFloat

    init(gap: CGFloat) {
        self.gap = gap
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }

    func add(_ button: QuireButton, trailing: Bool = false) {
        addSubview(button)
        buttons.append((button, trailing))
    }

    private func rows(width: CGFloat) -> [[(button: QuireButton, trailing: Bool)]] {
        var rows: [[(button: QuireButton, trailing: Bool)]] = []
        var row: [(button: QuireButton, trailing: Bool)] = []
        var used: CGFloat = 0
        for item in buttons {
            let w = item.button.intrinsicContentSize.width
            if !row.isEmpty, used + gap + w > width {
                rows.append(row)
                row = []
                used = 0
            }
            used += (row.isEmpty ? 0 : gap) + w
            row.append(item)
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let count = CGFloat(rows(width: width).count)
        return count == 0 ? 0 : count * Quire.Layout.Button.Small.height + (count - 1) * gap
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for row in rows(width: bounds.width) {
            var x: CGFloat = 0
            var trailingX = bounds.width
            for item in row.reversed() where item.trailing {
                let size = item.button.intrinsicContentSize
                trailingX -= size.width
                let visual = NSRect(x: trailingX + (item.button.variant == .link ? Quire.Layout.Button.linkPadX : 0), y: y,
                                    width: size.width, height: size.height)
                item.button.frame = item.button.frame(forVisualRect: visual)
                trailingX -= gap
            }
            for item in row where !item.trailing {
                let size = item.button.intrinsicContentSize
                item.button.frame = item.button.frame(forVisualRect: NSRect(x: x, y: y, width: size.width, height: size.height))
                x += size.width + gap
            }
            y += Quire.Layout.Button.Small.height + gap
        }
    }
}

/// The kicker: the account's ink dot and its words, or Cancelled in `danger`.
@MainActor
final class KickerView: NSView, MeasuredView {
    private let dot: NSColor?
    private let text: String
    private let cancelled: Bool

    init(dot: NSColor?, text: String, cancelled: Bool) {
        self.dot = dot
        self.text = text
        self.cancelled = cancelled
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }

    func height(forWidth width: CGFloat) -> CGFloat { QuireFont.Role.runningHead.lineHeight }

    override func draw(_ dirtyRect: NSRect) {
        let height = QuireFont.Role.runningHead.lineHeight
        var x: CGFloat = 0
        if let dot {
            let side = Quire.Layout.ReaderHeader.kickerDot
            QuireDraw.fillCircle(NSRect(x: 0, y: (height - side) / 2, width: side, height: side), dot)
            x = side + Quire.Layout.ReaderHeader.kickerDotGap
        }
        var words = text
        if cancelled, let separator = text.range(of: " · ", options: .backwards) {
            let account = String(text[..<separator.lowerBound])
            let lead = QuireFont.attributedString(account + " · ", role: .runningHead, color: .qInk3)
            lead.draw(with: NSRect(x: x, y: 0, width: max(0, bounds.width - x), height: height), options: QuireFont.drawingOptions, context: nil)
            x += ceil(lead.size().width)
            let glyph = Quire.Layout.CalendarPane.eventGlyph
            QuireSymbol.draw(Quire.Icon.failed, size: .custom(glyph), color: .qDanger, centredIn: NSRect(x: x, y: 0, width: glyph, height: height))
            x += glyph + 4
            words = "Cancelled"
            QuireFont.attributedString(words, role: .runningHead, color: .qDanger)
                .draw(with: NSRect(x: x, y: 0, width: max(0, bounds.width - x), height: height), options: QuireFont.drawingOptions, context: nil)
            return
        }
        let line = NSMutableAttributedString(attributedString: QuireFont.attributedString(words, role: .runningHead, color: .qInk3))
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
        line.draw(with: NSRect(x: x, y: 0, width: max(0, bounds.width - x), height: height), options: QuireFont.drawingOptions, context: nil)
    }
}

/// A line led by a 12 pt glyph: a status, the overlap, a failure.
@MainActor
final class GlyphLine: NSView, MeasuredView {
    private let glyph: String
    private let glyphColor: NSColor
    private let field: NSTextField

    init(glyph: String, glyphColor: NSColor, text: String, color: NSColor) {
        self.glyph = glyph
        self.glyphColor = glyphColor
        field = EventDetailsText.label(text, role: .snippet, color: color, selectable: true)
        super.init(frame: .zero)
        addSubview(field)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }

    private var indent: CGFloat { Quire.Layout.CalendarPane.eventGlyph + 6 }

    func height(forWidth width: CGFloat) -> CGFloat { EventDetailsText.height(of: field, width: width - indent) }

    override func layout() {
        super.layout()
        field.frame = NSRect(x: indent, y: 0, width: bounds.width - indent, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let side = Quire.Layout.CalendarPane.eventGlyph
        QuireSymbol.draw(glyph, size: .custom(side), color: glyphColor,
                         centredIn: NSRect(x: 0, y: 0, width: side, height: QuireFont.Role.snippet.lineHeight))
    }

    override func accessibilityChildren() -> [Any]? { [field] }
}

/// The Mail row: the label, then a row button holding the mail's subject and its sender and day.
@MainActor
final class MailRowView: NSView, MeasuredView {
    private let label = EventDetailsText.label("Mail", role: .snippet, color: .qInk3)
    private(set) var button: MailButton?
    private var goneField: NSTextField?

    init(mail: EventDetailsModel.MailRow, onShow: @escaping (MessageID) -> Void) {
        super.init(frame: .zero)
        addSubview(label)
        if let message = mail.message {
            let button = MailButton(mail: mail) { onShow(message) }
            addSubview(button)
            self.button = button
        } else {
            let field = EventDetailsText.label(mail.subject, role: .snippet, color: .qInk3)
            addSubview(field)
            goneField = field
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Mail")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }

    private var valueX: CGFloat { Quire.Layout.Invitation.labelColumn - Quire.Layout.CalendarPane.detailsMailPadX }

    func height(forWidth width: CGFloat) -> CGFloat {
        if let goneField { return EventDetailsText.height(of: goneField, width: width - Quire.Layout.Invitation.labelColumn) }
        return MailButton.height
    }

    override func layout() {
        super.layout()
        let pad = Quire.Layout.CalendarPane.detailsMailPadX
        label.frame = NSRect(x: 0, y: button == nil ? 0 : 4, width: valueX, height: QuireFont.Role.snippet.lineHeight)
        button?.frame = NSRect(x: valueX, y: 0, width: bounds.width - valueX + pad, height: bounds.height)
        goneField?.frame = NSRect(x: Quire.Layout.Invitation.labelColumn, y: 0, width: bounds.width - Quire.Layout.Invitation.labelColumn,
                                  height: bounds.height)
    }

    override func accessibilityChildren() -> [Any]? { [button ?? goneField].compactMap { $0 } }
}

/// The mail as a row button: the pointing hand, `hover` and `pressed`.
@MainActor
final class MailButton: QuireControl {
    static let height: CGFloat = 4 + QuireFont.Role.label.lineHeight + QuireFont.Role.meta.lineHeight + 4

    private let mail: EventDetailsModel.MailRow
    private let onShow: () -> Void

    init(mail: EventDetailsModel.MailRow, onShow: @escaping () -> Void) {
        self.mail = mail
        self.onShow = onShow
        super.init(frame: .zero)
        toolTip = "Show the Mail"
        setAccessibilityLabel(mail.accessibilityLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }

    override func activate() { onShow() }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func draw(_ dirtyRect: NSRect) {
        let face = bounds
        switch interactionState {
        case .pressed: QuireDraw.fill(face, radius: Quire.Radius.sm, .qPressed)
        case .hover: QuireDraw.fill(face, radius: Quire.Radius.sm, .qHover)
        default: break
        }
        if hasKeyboardFocus { QuireFocusRing.draw(around: face, cornerRadius: Quire.Radius.sm) }
        let pad = Quire.Layout.CalendarPane.detailsMailPadX
        let glyph = Quire.Layout.CalendarPane.eventGlyph
        let labelHeight = QuireFont.Role.label.lineHeight
        QuireSymbol.draw(Quire.Icon.fromThisMail, size: .custom(glyph), color: .qInk2,
                         centredIn: NSRect(x: pad, y: 4, width: glyph, height: labelHeight))
        let x = pad + glyph + 4
        let subject = EventDetailsText.attributed(mail.subject, role: .label, color: mail.subjectIsPlaceholder ? .qInk3 : .qInk,
                                                  italic: mail.subjectIsPlaceholder)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let line = NSMutableAttributedString(attributedString: subject)
        line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
        line.draw(with: NSRect(x: x, y: 4, width: max(0, face.width - x - pad), height: labelHeight), options: QuireFont.drawingOptions,
                  context: nil)
        let meta = NSMutableAttributedString(attributedString: QuireFont.attributedString(mail.meta, role: .meta, color: .qInk3))
        meta.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: meta.length))
        meta.draw(with: NSRect(x: x, y: 4 + labelHeight, width: max(0, face.width - x - pad), height: QuireFont.Role.meta.lineHeight),
                  options: QuireFont.drawingOptions, context: nil)
    }
}
