import AppKit
import SSCore
import SSDesign

/// The reader header (spec §5.12): a native 92 pt band on `paper` whose bottom hairline meets the list
/// header's at the horizon. Row 1, in the title-bar zone, carries the kicker (account ink dot, account name,
/// message count) and the two action groups; row 2 the New York headline. The subject updates in the same
/// frame as the selection, before the web view renders, so key repeat feels instant.
@MainActor
final class ReaderHeaderView: NSView {
    /// What the kicker says. The account name is the only part that may truncate or drop (spec §5.12).
    struct Kicker: Equatable {
        /// Account ink slot for the 7 pt dot; nil draws no dot ("Selection").
        var inkSlot: Int?
        /// Words before the account name ("Draft").
        var lead: String?
        /// The account's name; nil in single-account setups.
        var accountName: String?
        /// Words after it ("4 messages").
        var trail: String?
    }

    struct Content: Equatable {
        var kicker: Kicker?
        /// nil shows no headline (nothing selected).
        var headline: String?
        /// Set in the placeholder style when the headline is empty: "No subject", or "New Message" for a draft.
        var placeholder: String
        var actions: ReaderActionSet
    }

    var onAction: ((ReaderActionSet.Action) -> Void)?

    /// The main window's Day and Week buttons (spec §5.12, §5.54): after every action set and a 14 pt gap, acting on the
    /// window rather than the conversation, so they are enabled whatever is selected. Reader windows have none.
    enum LayoutToggle: CaseIterable {
        case day
        case week
    }

    /// Whether the header ends with the Day and Week buttons: the main window's does, a reader window's never.
    var showsLayoutToggles = false {
        didSet {
            guard oldValue != showsLayoutToggles else { return }
            if showsLayoutToggles, layoutToggles.isEmpty { makeLayoutToggles() }
            for button in layoutToggles.values { button.isHidden = !showsLayoutToggles }
            needsLayout = true
        }
    }

    /// A click on Day or Week: what D or W does.
    var onLayoutToggle: ((LayoutToggle) -> Void)?

    /// The Day and Week buttons, once shown.
    private(set) var layoutToggles: [LayoutToggle: QuireIconButton] = [:]

    /// Day is on while the column shows (in full or over the reader's edge), Week while the week shows (§5.12).
    func setLayoutToggles(dayOn: Bool, weekOn: Bool) {
        if let day = layoutToggles[.day] {
            day.isOn = dayOn
            day.toolTip = dayOn ? "Hide Day  D" : "Show Day  D"
        }
        if let week = layoutToggles[.week] {
            week.isOn = weekOn
            week.toolTip = weekOn ? "Hide Week  W" : "Show Week  W"
        }
    }

    private func makeLayoutToggles() {
        // One calendar button: the week is opened from inside the calendar (the column's header), not from here.
        for toggle in [LayoutToggle.day] {
            let button = QuireIconButton(symbolName: toggle == .day ? Quire.Icon.dayColumn : Quire.Icon.week, size: .large,
                                         accessibilityLabel: toggle == .day ? "Day" : "Week", target: self,
                                         action: #selector(layoutTogglePressed(_:)))
            // Quiet toggles (VoiceOver: “Day, toggle button”); the window sets their state again after every click from
            // what it then shows, since D in a narrow window opens the column over the reader rather than hiding it.
            button.onStyle = .quiet
            button.togglesOnClick = true
            button.tag = toggle == .day ? 0 : 1
            addSubview(button)
            layoutToggles[toggle] = button
        }
        setLayoutToggles(dayOn: false, weekOn: false)
    }

    @objc private func layoutTogglePressed(_ sender: QuireIconButton) {
        onLayoutToggle?(sender.tag == 0 ? .day : .week)
    }

    /// Where the kicker may start at the earliest. 0 in the main window, where the list stands between the lights and the
    /// reader; in a reader window the lights are on the header's own line, and the kicker starts clear of them (§5.49).
    var kickerMinX: CGFloat = 0 {
        didSet { if oldValue != kickerMinX { needsLayout = true } }
    }

    /// The reader's Text size (spec §4.15): the headline's, never the kicker's or the actions', which are the band's
    /// chrome. The band keeps its height; the headline's line grows inside it.
    var textSize = QuireFont.TextSize.default {
        didSet {
            guard oldValue != textSize else { return }
            applyHeadline()
            needsLayout = true
        }
    }

    private(set) var content = Content(kicker: nil, headline: nil, placeholder: "No subject", actions: .make(.nothing))
    private let kickerView = ReaderKickerView()
    private let headline = ReaderHeadlineView()
    private let hairline = QuireHairline(.horizontal)
    private var buttons: [ReaderActionSet.Action: QuireIconButton] = [:]

    private static let titlebarZone = Quire.Layout.Window.titlebarZone

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    /// The band drags the window itself (`mouseDown`), so AppKit must not also start a move from it.
    override var mouseDownCanMoveWindow: Bool { false }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(kickerView)
        addSubview(headline)
        hairline.alignsToMaxEdge = true
        addSubview(hairline)
        heightAnchor.constraint(equalToConstant: Quire.Layout.ReaderHeader.height).isActive = true
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
        showContent()
    }

    /// Graphite and Increase Contrast change token values without changing the appearance.
    @objc private func environmentDidChange(_ note: Notification) {
        applyHeadline()
        kickerView.needsDisplay = true
        needsDisplay = true
    }

    // MARK: Content

    func apply(_ content: Content) {
        // The reader applies its state several times per selection change; only a change costs a relayout.
        guard content != self.content else { return }
        self.content = content
        showContent()
    }

    private func showContent() {
        kickerView.kicker = content.kicker
        kickerView.isHidden = content.kicker == nil
        applyHeadline()
        applyActions()
        needsLayout = true
    }

    /// The headline as it is set now (tests read its font).
    var headlineString: NSAttributedString { headline.attributedString() }

    private func applyHeadline() {
        guard let subject = content.headline else {
            headline.isHidden = true
            return
        }
        headline.isHidden = false
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.isEmpty
            ? ReaderFonts.placeholder(content.placeholder, role: .headline, textSize: textSize)
            : QuireFont.attributedString(trimmed, role: .headline, color: .qInk, textSize: textSize)
        headline.show(text)
        headline.toolTip = trimmed.isEmpty ? nil : trimmed
        headline.setAccessibilityLabel(trimmed.isEmpty ? content.placeholder : trimmed)
        needsLayout = true
    }

    private func applyActions() {
        let set = content.actions
        let shown = Set(set.all)
        for (action, button) in buttons where !shown.contains(action) {
            button.isHidden = true
        }
        for action in set.all {
            let button = buttons[action] ?? makeButton(action)
            button.isHidden = false
            button.isEnabled = set.isEnabled(action)
            if action == .star {
                button.isOn = set.starOn
                let several = set.replies.isEmpty
                button.toolTip = set.starOn ? (several ? "Unstar All  S" : "Unstar  S") : (several ? "Star All  S" : "Star  S")
                button.setAccessibilityLabel(set.starOn ? "Unstar" : "Star")
            }
            if action == .replyAll {
                // A disabled control says why (§5.34): Reply would already reach everyone.
                let onlyOne = !set.isEnabled(.replyAll) && set.isEnabled(.reply)
                button.toolTip = onlyOne ? "Reply All: only one other person" : Self.spec(for: .replyAll).tooltip
            }
        }
    }

    private func makeButton(_ action: ReaderActionSet.Action) -> QuireIconButton {
        let spec = Self.spec(for: action)
        let button = QuireIconButton(symbolName: spec.symbol, size: .large, accessibilityLabel: spec.label,
                                     target: self, action: #selector(actionPressed(_:)))
        button.toolTip = spec.tooltip
        button.tag = ReaderActionSet.Action.allCases.firstIndex(of: action) ?? 0
        if action == .star {
            button.onStyle = .star
            button.onSymbolName = Quire.Icon.unstar
        }
        addSubview(button)
        buttons[action] = button
        return button
    }

    private static func spec(for action: ReaderActionSet.Action) -> (symbol: String, label: String, tooltip: String) {
        switch action {
        case .star: return (Quire.Icon.star, "Star", "Star  S")
        case .archive: return (Quire.Icon.archive, "Archive", "Archive  E")
        case .moveToInbox: return (Quire.Icon.moveToInbox, "Move to Inbox", "Move to Inbox  ⇧I")
        case .trash: return (Quire.Icon.trash, "Move to Trash", "Move to Trash  #")
        case .reply: return (Quire.Icon.reply, "Reply", "Reply  R")
        case .replyAll: return (Quire.Icon.replyAll, "Reply All", "Reply All  A")
        case .forward: return (Quire.Icon.forward, "Forward", "Forward  F")
        case .continueEditing: return (Quire.Icon.compose, "Continue Editing", "Continue Editing  ↩")
        case .discardDraft: return (Quire.Icon.discardDraft, "Discard Draft", "Discard Draft…  #")
        }
    }

    @objc private func actionPressed(_ sender: QuireIconButton) {
        let all = ReaderActionSet.Action.allCases
        guard all.indices.contains(sender.tag) else { return }
        onAction?(all[sender.tag])
    }

    // MARK: Layout

    /// Where a menu for the header's conversation hangs from (the Later menu, §5.45): the Archive button's square, or,
    /// with no Archive shown, the first action's; below the kicker at the text column when no action shows.
    var menuAnchor: NSRect {
        layoutSubtreeIfNeeded()
        let shown = content.actions.primary + content.actions.replies
        if let action = ([.archive] + shown).first(where: { shown.contains($0) }), let button = buttons[action], !button.isHidden {
            return button.alignmentRect(forFrame: button.frame)
        }
        let column = ReaderColumn.frame(readerWidth: bounds.width)
        return NSRect(x: column.x, y: Quire.Layout.ReaderHeader.actionsTop, width: 0, height: Quire.Layout.ReaderHeader.actionSize)
    }

    override func layout() {
        super.layout()
        let metrics = Quire.Layout.ReaderHeader.self
        let column = ReaderColumn.frame(readerWidth: bounds.width)
        // Groups from the trailing edge, 14 pt apart: in the main window Day and Week, then the reply group, then the first.
        var x = bounds.width - metrics.actionsTrailing
        var firstActionX = x
        let toggles = showsLayoutToggles ? LayoutToggle.allCases.compactMap { layoutToggles[$0] } : []
        let groups = [toggles, content.actions.replies.compactMap { buttons[$0] }, content.actions.primary.compactMap { buttons[$0] }]
        var placedGroup = false
        for group in groups where !group.isEmpty {
            if placedGroup { x -= metrics.actionGroupGap - metrics.actionGap }
            placedGroup = true
            for button in group.reversed() {
                x -= metrics.actionSize
                button.frame = button.frame(forVisualRect: NSRect(x: x, y: metrics.actionsTop, width: metrics.actionSize, height: metrics.actionSize))
                firstActionX = x
                x -= metrics.actionGap
            }
        }
        let kickerHeight = QuireFont.Role.runningHead.lineHeight
        let kickerX = max(column.x, kickerMinX)
        let kickerWidth = max(0, firstActionX - metrics.kickerActionGap - kickerX)
        kickerView.frame = NSRect(x: kickerX, y: metrics.kickerCenterY - kickerHeight / 2, width: kickerWidth, height: kickerHeight)
        // The headline's text view lays the role's line out exactly (30 pt at Default), so its frame is the line itself.
        let headlineHeight = metrics.headlineHeight + QuireFont.Role.headline.step(at: textSize)
        headline.frame = NSRect(x: column.x, y: metrics.headlineTop, width: column.width, height: headlineHeight)
        let hair = QuireHairline.width(for: self)
        hairline.frame = NSRect(x: 0, y: bounds.height - max(hair, 1), width: bounds.width, height: max(hair, 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        // Views no longer clip to their bounds, and the dirty rect can reach past them.
        NSColor.qPaper.setFill()
        bounds.intersection(dirtyRect).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyHeadline()
        needsDisplay = true
    }

    // MARK: Title-bar zone

    /// The top 52 pt is the title-bar zone (spec §3.2): it drags the window and a double click does what the
    /// system setting says. The controls in it take their own clicks first.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.y < Self.titlebarZone, let window else {
            super.mouseDown(with: event)
            return
        }
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
            return
        }
        window.performDrag(with: event)
    }
}

/// The kicker (spec §5.12): the account ink dot, 8 pt, then `runningHead` `ink3` words. When the words do not
/// fit, the account name tail-truncates; the dot, the "·" and the count never do; with fewer than four
/// characters of the name left the name drops out and the tooltip names the account.
@MainActor
final class ReaderKickerView: NSView {
    var kicker: ReaderHeaderView.Kicker? {
        didSet { if oldValue != kicker { layOutWords() } }
    }

    /// The words as they fit the current width, built when the kicker or the width changes so `draw` only draws.
    private var words = NSAttributedString()

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed { layOutWords() }
    }

    private static let separator = " · "

    private func string(_ text: String) -> NSAttributedString {
        let attributes = QuireFont.attributes(.runningHead, color: .qInk3)
        return NSAttributedString(string: text, attributes: attributes)
    }

    private func width(_ text: String) -> CGFloat {
        ceil(string(text).size().width)
    }

    /// The words that fit in `available`, with the account name cut as far as the rules allow.
    func layoutText(available: CGFloat) -> (text: String, nameDropped: Bool) {
        guard let kicker else { return ("", false) }
        func compose(_ name: String?) -> String {
            [kicker.lead, name, kicker.trail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: Self.separator)
        }
        guard let name = kicker.accountName, !name.isEmpty else { return (compose(nil), false) }
        let full = compose(name)
        if width(full) <= available { return (full, false) }
        let minChars = Int(Quire.Layout.ReaderHeader.kickerNameMinChars)
        var characters = Array(name)
        while characters.count > minChars {
            characters.removeLast()
            let cut = String(characters).trimmingCharacters(in: .whitespaces) + "…"
            let candidate = compose(cut)
            if width(candidate) <= available { return (candidate, false) }
        }
        return (compose(nil), true)
    }

    /// Where the words start: after the dot and its gap, or at 0 with no dot ("Selection").
    private var wordsX: CGFloat {
        let metrics = Quire.Layout.ReaderHeader.self
        return kicker?.inkSlot == nil ? 0 : metrics.kickerDot + metrics.kickerDotGap
    }

    private func layOutWords() {
        defer { needsDisplay = true }
        guard let kicker else {
            words = NSAttributedString()
            toolTip = nil
            setAccessibilityLabel(nil)
            return
        }
        let layout = layoutText(available: max(0, bounds.width - wordsX))
        words = string(layout.text)
        // A cut or dropped name stays reachable: the tooltip names the account (spec §5.12, §5.34), and
        // VoiceOver does when it was dropped.
        let nameCut = kicker.accountName.map { !$0.isEmpty && !layout.text.contains($0) } ?? false
        toolTip = nameCut ? kicker.accountName : nil
        setAccessibilityLabel(layout.nameDropped ? [kicker.lead, kicker.accountName, kicker.trail].compactMap { $0 }.joined(separator: ", ") : layout.text)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let kicker else { return }
        let metrics = Quire.Layout.ReaderHeader.self
        if let slot = kicker.inkSlot {
            let dot = NSRect(x: 0, y: (bounds.height - metrics.kickerDot) / 2, width: metrics.kickerDot, height: metrics.kickerDot)
            NSColor.qAccount(slot).setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
        let x = wordsX
        words.draw(with: NSRect(x: x, y: 0, width: max(0, bounds.width - x), height: bounds.height),
                   options: QuireFont.drawingOptions, context: nil)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
}

/// The headline (spec §5.12): one selectable, tail-truncated line of New York. A non-editable text view rather
/// than a selectable label, because a label selects through the window's field editor, and while a field editor
/// is first responder the single-key shortcuts stand down as if the user were typing: one click on the subject
/// would silence J, K and E until focus moved. A read-only text view selects and copies without that.
@MainActor
private final class ReaderHeadlineView: NSTextView {
    /// The I-beam over the headline's own line (§4.17). AppKit's is over the visible rect, which, as views no longer clip
    /// to their bounds, reaches over the whole reader: its I-beam would sit over the page and stop the page's links from
    /// showing their hand. None under the cheat sheet, which covers the reader.
    override func resetCursorRects() {
        addTextPointerRects()
    }

    init() {
        // TextKit 1, configured like every Quire text stack, so the role's exact 30 pt line holds (§4.4).
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        QuireFont.configure(layoutManager)
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 1
        container.lineBreakMode = .byTruncatingTail
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = false
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        allowsUndo = false
        usesFindBar = false
        isAutomaticLinkDetectionEnabled = false
        focusRingType = .none
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Replaces the line; a selection belonged to the previous subject, so it goes.
    func show(_ text: NSAttributedString) {
        textStorage?.setAttributedString(text)
        setSelectedRange(NSRange(location: 0, length: 0))
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
}
