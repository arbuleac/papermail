import AppKit
import SSDesign

/// Hosts the reader in the window's third pane. The reader paints up to the window's top edge: its 92 pt header
/// takes the title-bar zone (the kicker and its actions sit on the traffic lights' line, §5.12) and its bottom
/// hairline meets the list header's on the horizon. The pane itself is the reader desk, `canvas`.
@MainActor
final class ConversationPaneViewController: NSViewController {
    static let minimumWidth: CGFloat = Quire.Layout.Window.readerMinWidth

    let conversation: ConversationViewController

    init(conversation: ConversationViewController) {
        self.conversation = conversation
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let root = ReaderDeskView()
        root.translatesAutoresizingMaskIntoConstraints = false
        addChild(conversation)
        let content = conversation.view
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumWidth),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }
}

/// The reader desk: opaque `canvas` behind whatever the reader does not cover.
@MainActor
private final class ReaderDeskView: NSView {
    override var isOpaque: Bool { true }
    override var isFlipped: Bool { true }
    /// The desk under the title-bar zone drags the window like the rest of the zone (§3.2).
    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.qCanvas.setFill()
        // Views do not clip to their bounds by default, so the fill is limited to them by hand.
        dirtyRect.intersection(bounds).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
