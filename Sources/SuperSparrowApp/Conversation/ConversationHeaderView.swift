import AppKit

/// The strip above the web view: the subject (updated before any rendering happens, so key repeats
/// feel instant) and the conversation-level actions.
@MainActor
final class ConversationHeaderView: NSView {
    static let height: CGFloat = 44

    var onArchive: (() -> Void)?
    var onToggleStar: (() -> Void)?
    var onTrash: (() -> Void)?

    var subject: String = "" {
        didSet { subjectLabel.stringValue = subject.isEmpty ? "(No subject)" : subject }
    }

    var isStarred: Bool = false {
        didSet { starButton.image = Self.symbol(isStarred ? "star.fill" : "star", description: isStarred ? "Unstar" : "Star") }
    }

    private let subjectLabel = NSTextField(labelWithString: "")
    private let starButton = NSButton()
    private let archiveButton = NSButton()
    private let trashButton = NSButton()
    private let separator = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        subjectLabel.translatesAutoresizingMaskIntoConstraints = false
        subjectLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        subjectLabel.lineBreakMode = .byTruncatingTail
        subjectLabel.maximumNumberOfLines = 1
        subjectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(subjectLabel)

        configure(starButton, symbol: "star", description: "Star", action: #selector(starPressed))
        configure(archiveButton, symbol: "archivebox", description: "Archive", action: #selector(archivePressed))
        configure(trashButton, symbol: "trash", description: "Trash", action: #selector(trashPressed))

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            subjectLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            subjectLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            trashButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            trashButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            archiveButton.trailingAnchor.constraint(equalTo: trashButton.leadingAnchor, constant: -4),
            archiveButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            starButton.trailingAnchor.constraint(equalTo: archiveButton.leadingAnchor, constant: -4),
            starButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            subjectLabel.trailingAnchor.constraint(lessThanOrEqualTo: starButton.leadingAnchor, constant: -12),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func configure(_ button: NSButton, symbol: String, description: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = Self.symbol(symbol, description: description)
        button.toolTip = description
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(button)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private static func symbol(_ name: String, description: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage()
    }

    @objc private func starPressed() { onToggleStar?() }
    @objc private func archivePressed() { onArchive?() }
    @objc private func trashPressed() { onTrash?() }
}
