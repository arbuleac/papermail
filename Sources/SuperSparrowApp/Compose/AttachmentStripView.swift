import AppKit

/// The chips for the message's attachments, flowed left to right and wrapping onto new rows. Collapses to
/// nothing when there is nothing to show. Inline parts of a quoted original are never listed.
@MainActor
final class AttachmentStripView: NSView {
    var onRemove: ((UUID) -> Void)?

    var attachments: [ComposeAttachment] = [] {
        didSet { rebuildChips() }
    }

    private static let inset: CGFloat = 10
    private static let spacing: CGFloat = 6

    private let separator = NSBox()
    private var chips: [AttachmentChipView] = []
    private var measuredHeight: CGFloat = 0

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        separator.boxType = .separator
        separator.autoresizingMask = [.width]
        addSubview(separator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AttachmentStripView is built in code")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight)
    }

    override func layout() {
        super.layout()
        separator.frame = NSRect(x: Self.inset, y: 0, width: max(0, bounds.width - Self.inset * 2), height: 1)
        flow(width: bounds.width)
    }

    private func rebuildChips() {
        chips.forEach { $0.removeFromSuperview() }
        chips = attachments.filter { !$0.isInline }.map { attachment in
            let chip = AttachmentChipView(attachment: attachment)
            chip.onRemove = { [weak self] id in self?.onRemove?(id) }
            return chip
        }
        chips.forEach(addSubview)
        isHidden = chips.isEmpty
        needsLayout = true
        flow(width: bounds.width)
    }

    /// Places the chips in rows and reports the height they need through the intrinsic size.
    private func flow(width: CGFloat) {
        var x = Self.inset
        var y = Self.inset
        var rowHeight: CGFloat = 0
        for chip in chips {
            let size = chip.fittingSize
            if x > Self.inset, x + size.width > width - Self.inset {
                x = Self.inset
                y += rowHeight + Self.spacing
                rowHeight = 0
            }
            chip.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            x += size.width + Self.spacing
            rowHeight = max(rowHeight, size.height)
        }
        let height = chips.isEmpty ? 0 : y + rowHeight + Self.inset
        if abs(height - measuredHeight) > 0.5 {
            measuredHeight = height
            invalidateIntrinsicContentSize()
        }
    }
}
