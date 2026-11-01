import AppKit
import SSCore

/// The quoted original beneath the editor: collapsed to a "···" chip the way Gmail does it, expanded to the
/// attribution line and the original's text. It is never editable; the exporter appends the real HTML
/// after the typed content on send, so what is shown here is only a preview.
@MainActor
final class QuotedOriginalView: NSView {
    var rendering: QuotedReply.Rendering? {
        didSet { update() }
    }

    private static let inset: CGFloat = 10
    /// Long threads make a long preview; past this the text field layout gets sluggish for no benefit.
    private static let previewLimit = 20_000

    private let toggle = NSButton(title: "···", target: nil, action: nil)
    private let content = NSView()
    private let bar = NSView()
    private let headerLabel = NSTextField(wrappingLabelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private var collapsedBottom: NSLayoutConstraint?
    private var expandedBottom: NSLayoutConstraint?
    private var isExpanded = false

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

        toggle.bezelStyle = .inline
        toggle.font = .boldSystemFont(ofSize: 11)
        toggle.setButtonType(.momentaryPushIn)
        toggle.target = self
        toggle.action = #selector(toggleExpanded(_:))
        toggle.translatesAutoresizingMaskIntoConstraints = false

        content.translatesAutoresizingMaskIntoConstraints = false
        content.isHidden = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true
        headerLabel.font = .systemFont(ofSize: 12)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(bar)
        content.addSubview(headerLabel)
        content.addSubview(bodyLabel)
        addSubview(toggle)
        addSubview(content)

        let collapsed = toggle.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset)
        let expanded = content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset)
        collapsedBottom = collapsed
        expandedBottom = expanded
        NSLayoutConstraint.activate([
            toggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            toggle.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            collapsed,
            content.topAnchor.constraint(equalTo: toggle.bottomAnchor, constant: 8),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: 3),
            headerLabel.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 10),
            headerLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            headerLabel.topAnchor.constraint(equalTo: content.topAnchor),
            bodyLabel.leadingAnchor.constraint(equalTo: headerLabel.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bodyLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 6),
            bodyLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("QuotedOriginalView is built in code")
    }

    override func layout() {
        super.layout()
        bar.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        // Wrapping labels only report a multi-line height once they know how wide they may be.
        let width = max(0, content.bounds.width - 13)
        headerLabel.preferredMaxLayoutWidth = width
        bodyLabel.preferredMaxLayoutWidth = width
    }

    @objc private func toggleExpanded(_ sender: Any?) {
        isExpanded.toggle()
        applyExpansion()
    }

    private func update() {
        guard let rendering else {
            isHidden = true
            return
        }
        isHidden = false
        headerLabel.stringValue = rendering.header
        var text = rendering.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > Self.previewLimit {
            text = String(text.prefix(Self.previewLimit)) + "…"
        }
        bodyLabel.stringValue = text
        applyExpansion()
    }

    private func applyExpansion() {
        content.isHidden = !isExpanded
        collapsedBottom?.isActive = !isExpanded
        expandedBottom?.isActive = isExpanded
        toggle.toolTip = isExpanded ? "Hide quoted text" : "Show quoted text"
        invalidateIntrinsicContentSize()
    }
}
