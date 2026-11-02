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

    private(set) var content = Content(kicker: nil, headline: nil, placeholder: "No subject", actions: .make(.nothing))
    private let kickerView = ReaderKickerView()
    private let headline = NSTextField(labelWithString: "")
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
        headline.isSelectable = true
        headline.isEditable = false
        headline.isBordered = false
        headline.drawsBackground = false
        headline.lineBreakMode = .byTruncatingTail
        headline.maximumNumberOfLines = 1
        headline.cell?.truncatesLastVisibleLine = true
        headline.allowsDefaultTighteningForTruncation = false
        addSubview(headline)
        hairline.alignsToMaxEdge = true
        addSubview(hairline)
        heightAnchor.constraint(equalToConstant: Quire.Layout.ReaderHeader.height).isActive = true
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
        apply(content)
    }

    /// Graphite and Increase Contrast change token values without changing the appearance.
    @objc private func environmentDidChange(_ note: Notification) {
        applyHeadline()
        kickerView.needsDisplay = true
        needsDisplay = true
    }

    // MARK: Content

    func apply(_ content: Content) {
        self.content = content
        kickerView.kicker = content.kicker
        kickerView.isHidden = content.kicker == nil
        applyHeadline()
        applyActions()
        needsLayout = true
    }

    private func applyHeadline() {
        guard let subject = content.headline else {
            headline.isHidden = true
            return
        }
        headline.isHidden = false
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.isEmpty
            ? ReaderFonts.placeholder(content.placeholder, role: .headline)
            : QuireFont.attributedString(trimmed, role: .headline, color: .qInk)
        // The field is centred on the 30 pt headline line in `layout()`.
        headline.attributedStringValue = ReaderFonts.fieldString(text)
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

    override func layout() {
        super.layout()
        let metrics = Quire.Layout.ReaderHeader.self
        let column = ReaderColumn.frame(readerWidth: bounds.width)
        // Actions from the trailing edge: the reply group, the 14 pt gap, then the first group.
        var x = bounds.width - metrics.actionsTrailing
        var firstActionX = x
        let groups = [content.actions.replies, content.actions.primary]
        for (index, group) in groups.enumerated() where !group.isEmpty {
            if index == 1, !content.actions.replies.isEmpty { x -= metrics.actionGroupGap - metrics.actionGap }
            for action in group.reversed() {
                guard let button = buttons[action] else { continue }
                x -= metrics.actionSize
                button.frame = button.frame(forVisualRect: NSRect(x: x, y: metrics.actionsTop, width: metrics.actionSize, height: metrics.actionSize))
                firstActionX = x
                x -= metrics.actionGap
            }
        }
        let kickerHeight = QuireFont.Role.runningHead.lineHeight
        let kickerWidth = max(0, firstActionX - metrics.kickerActionGap - column.x)
        kickerView.frame = NSRect(x: column.x, y: metrics.kickerCenterY - kickerHeight / 2, width: kickerWidth, height: kickerHeight)
        let fieldHeight = ceil(headline.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: column.width + 4, height: 200)).height ?? metrics.headlineHeight)
        headline.frame = NSRect(x: column.x - 2, y: (metrics.headlineTop + (metrics.headlineHeight - fieldHeight) / 2).rounded(),
                                width: column.width + 4, height: fieldHeight)
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
        didSet { if oldValue != kicker { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed { needsDisplay = true }
    }

    private static let separator = " · "

    private func string(_ text: String) -> NSAttributedString {
        let attributes = QuireFont.attributes(.runningHead, color: .qInk3)
        return NSAttributedString(string: text.uppercased(with: .current), attributes: attributes)
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

    override func draw(_ dirtyRect: NSRect) {
        guard let kicker else { return }
        let metrics = Quire.Layout.ReaderHeader.self
        var x: CGFloat = 0
        if let slot = kicker.inkSlot {
            let dot = NSRect(x: 0, y: (bounds.height - metrics.kickerDot) / 2, width: metrics.kickerDot, height: metrics.kickerDot)
            NSColor.qAccount(slot).setFill()
            NSBezierPath(ovalIn: dot).fill()
            x = metrics.kickerDot + metrics.kickerDotGap
        }
        let layout = layoutText(available: max(0, bounds.width - x))
        toolTip = layout.nameDropped ? kicker.accountName : nil
        let text = string(layout.text)
        text.draw(with: NSRect(x: x, y: 0, width: max(0, bounds.width - x), height: bounds.height),
                  options: QuireFont.drawingOptions, context: nil)
        setAccessibilityLabel(layout.nameDropped ? [kicker.lead, kicker.accountName, kicker.trail].compactMap { $0 }.joined(separator: ", ") : layout.text)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
}
