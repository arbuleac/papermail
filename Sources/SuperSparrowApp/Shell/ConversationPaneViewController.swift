import AppKit

/// Hosts the reader below the transparent title bar. The reader's own header must not slide under the
/// title bar, where clicks drag the window instead of reaching its buttons.
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
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }
}
