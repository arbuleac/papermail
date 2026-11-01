import AppKit
import UniformTypeIdentifiers

/// One attachment in the strip: the file's icon, its name, its size and a remove button.
@MainActor
final class AttachmentChipView: NSView {
    let attachmentID: UUID
    var onRemove: ((UUID) -> Void)?

    init(attachment: ComposeAttachment) {
        attachmentID = attachment.id
        super.init(frame: .zero)
        toolTip = attachment.filename

        let icon = NSImageView(image: Self.icon(for: attachment))
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: attachment.filename)
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let size = NSTextField(labelWithString: ComposeAttachment.formattedSize(attachment.sizeBytes))
        size.font = .systemFont(ofSize: 11)
        size.textColor = .secondaryLabelColor

        let remove = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove") ?? NSImage(), target: self, action: #selector(removeTapped(_:)))
        remove.isBordered = false
        remove.contentTintColor = .secondaryLabelColor
        remove.toolTip = "Remove"
        remove.setButtonType(.momentaryChange)

        let stack = NSStackView(views: [icon, name, size, remove])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AttachmentChipView is built in code")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternarySystemFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    @objc private func removeTapped(_ sender: Any?) {
        onRemove?(attachmentID)
    }

    private static func icon(for attachment: ComposeAttachment) -> NSImage {
        let type = UTType(mimeType: attachment.mimeType)
            ?? UTType(filenameExtension: (attachment.filename as NSString).pathExtension)
            ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}
