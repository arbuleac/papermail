import AppKit

/// Hosts the reader from the window's top edge: the reader header's first row is the title-bar zone, and the
/// unified toolbar passes clicks through to its buttons (spec §3.2).
@MainActor
final class ConversationPaneViewController: NSViewController {
    static let minimumWidth: CGFloat = 400

    let conversation: ConversationViewController

    init(conversation: ConversationViewController) {
        self.conversation = conversation
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.translatesAutoresizingMaskIntoConstraints = false
        addChild(conversation)
        let content = conversation.view
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumWidth),
            // The reader header is 92 pt from the window's top: its first row is the title-bar zone (spec §5.12).
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }
}
