import AppKit
import SSCore
import SSDesign

/// The foot of the column and the week (spec §5.54, “The foot”): nothing while every account's calendar is read; while
/// some account has not granted the calendar permission, “Show events from your calendars” and Connect; for a Google
/// account whose OAuth client has the Calendar API off, where to turn it on. A read that fails for another reason
/// keeps the stored events and says nothing.
@MainActor
final class CalendarFootView: NSView {
    typealias Pane = Quire.Layout.CalendarPane

    let state: CalendarState
    weak var delegate: CalendarViewDelegate?
    /// The words' leading inset: the column's header pad, or the week's.
    var padX: CGFloat = Quire.Layout.CalendarPane.headerPadX {
        didSet { needsLayout = true }
    }

    private let connect = QuireButton(title: "Connect", variant: .secondary, size: .small)
    private let howTo = QuireButton(title: "How to turn it on", variant: .link, size: .small)
    private var connectAccounts: [AccountID] = []
    private var apiOffAccounts: [AccountID] = []

    init(state: CalendarState) {
        self.state = state
        super.init(frame: .zero)
        // Each part fills what it is asked to draw; without the clip that reaches past its bounds onto its neighbours.
        clipsToBounds = true
        connect.loadingTitle = "Connecting…"
        connect.target = self
        connect.action = #selector(connectClicked(_:))
        howTo.target = self
        howTo.action = #selector(howToClicked(_:))
        addSubview(connect)
        addSubview(howTo)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    /// Reads the accounts' calendar states again.
    func update() {
        connectAccounts = state.accountsToConnect
        apiOffAccounts = Self.apiOffAccounts(state)
        connect.isHidden = connectAccounts.isEmpty
        howTo.isHidden = apiOffAccounts.isEmpty
        connect.isLoading = state.isConnecting
        isHidden = connectAccounts.isEmpty && apiOffAccounts.isEmpty
        needsLayout = true
        needsDisplay = true
    }

    var connectMessage: String? { Self.connectMessage(connectAccounts) }

    var apiOffMessage: String? { Self.apiOffMessage(apiOffAccounts, state: state) }

    private static func connectMessage(_ accounts: [AccountID]) -> String? {
        accounts.isEmpty ? nil : "Show events from your calendars"
    }

    /// “Turn on the Google Calendar API for Contoso” (“for Contoso and 1 more”).
    private static func apiOffMessage(_ accounts: [AccountID], state: CalendarState) -> String? {
        guard let first = accounts.first else { return nil }
        let more = accounts.count - 1
        return "Turn on the Google Calendar API for " + state.accountName(first) + (more > 0 ? " and \(more) more" : "")
    }

    private static func apiOffAccounts(_ state: CalendarState) -> [AccountID] {
        state.accountsWithCalendarAPIOff.filter { state.providerKind($0) != .microsoft }
    }

    private var blocks: [(text: String, button: QuireButton)] {
        var blocks: [(String, QuireButton)] = []
        if let connectMessage { blocks.append((connectMessage, connect)) }
        if let apiOffMessage { blocks.append((apiOffMessage, howTo)) }
        return blocks
    }

    private static func message(_ text: String) -> NSAttributedString {
        CalendarType.wrapping(text, role: .snippet, color: .qInk2)
    }

    private static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        let role = QuireFont.Role.snippet
        let box = NSSize(width: width, height: Pane.footLinesMax * role.lineHeight)
        let used = message(text).boundingRect(with: box, options: QuireFont.drawingOptions, context: nil).height
        return min(box.height, max(role.lineHeight, ceil(used / role.lineHeight) * role.lineHeight))
    }

    /// The foot's height for `messages` at `width`: 0 when it says nothing.
    private static func height(of messages: [String], width: CGFloat, padX: CGFloat) -> CGFloat {
        guard !messages.isEmpty else { return 0 }
        let inner = width - 2 * padX
        var height = Pane.footPadY
        for (index, text) in messages.enumerated() {
            if index > 0 { height += Pane.footPadY }
            height += textHeight(text, width: inner) + Pane.footGap + Quire.Layout.Button.Small.height
        }
        return ceil(height + Pane.footPadY)
    }

    /// The foot's height at `width`: 0 when it says nothing. The timeline's fit takes it off first.
    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        Self.height(of: blocks.map(\.text), width: width, padX: padX)
    }

    /// The height a foot would take for `state` now, for the strip, which fits as the column would.
    static func preferredHeight(for state: CalendarState, width: CGFloat,
                                padX: CGFloat = Quire.Layout.CalendarPane.headerPadX) -> CGFloat {
        let messages = [connectMessage(state.accountsToConnect), apiOffMessage(apiOffAccounts(state), state: state)].compactMap { $0 }
        return height(of: messages, width: width, padX: padX)
    }

    override func layout() {
        super.layout()
        let inner = bounds.width - 2 * padX
        var y = Pane.footPadY
        for (index, block) in blocks.enumerated() {
            if index > 0 { y += Pane.footPadY }
            y += Self.textHeight(block.text, width: inner) + Pane.footGap
            let size = block.button.intrinsicContentSize
            block.button.frame = block.button.frame(forVisualRect: NSRect(x: padX, y: y, width: size.width, height: size.height))
            y += Quire.Layout.Button.Small.height
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.qPaper.setFill()
        dirtyRect.fill()
        NSColor.qRule.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: QuireHairline.width(for: self)).fill()
        let inner = bounds.width - 2 * padX
        var y = Pane.footPadY
        for (index, block) in blocks.enumerated() {
            if index > 0 { y += Pane.footPadY }
            let height = Self.textHeight(block.text, width: inner)
            Self.message(block.text).draw(with: NSRect(x: padX, y: y, width: inner, height: height), options: QuireFont.drawingOptions,
                                     context: nil)
            y += height + Pane.footGap + Quire.Layout.Button.Small.height
        }
    }

    @objc private func connectClicked(_ sender: Any?) {
        delegate?.connect(accountIDs: connectAccounts)
    }

    /// The setup guide's step (docs/OAUTH-SETUP.md) when the app bundles it, else Google's page for the API.
    @objc private func howToClicked(_ sender: Any?) {
        let guide = Bundle.main.url(forResource: "OAUTH-SETUP", withExtension: "md")
            ?? URL(string: "https://console.cloud.google.com/apis/library/calendar-json.googleapis.com")
        if let guide { delegate?.openURL(guide) }
    }

    override func isAccessibilityElement() -> Bool { false }

    /// The buttons, for the window's Tab loop.
    var keyViews: [NSView] { [connect, howTo].filter { !$0.isHidden } }
}
