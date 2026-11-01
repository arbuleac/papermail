import AppKit

/// One header line of the composer: a right-aligned caption, the control, an optional trailing accessory
/// and a hairline below. The row's height follows the control, so a wrapping recipient field grows it.
@MainActor
final class ComposeFieldRow: NSView {
    static let captionWidth: CGFloat = 60
    static let horizontalInset: CGFloat = 14
    static let verticalInset: CGFloat = 7

    let caption: NSTextField
    let control: NSView
    let accessory: NSView?

    private let separator = NSBox()
    private var accessoryGap: NSLayoutConstraint?
    private var accessoryCollapsed: NSLayoutConstraint?

    init(title: String, control: NSView, accessory: NSView? = nil) {
        caption = NSTextField(labelWithString: title)
        self.control = control
        self.accessory = accessory
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        caption.font = .systemFont(ofSize: 13)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .right
        caption.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(caption)
        addSubview(control)
        addSubview(separator)

        var constraints = [
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            caption.widthAnchor.constraint(equalToConstant: Self.captionWidth),
            caption.firstBaselineAnchor.constraint(equalTo: control.firstBaselineAnchor),
            control.leadingAnchor.constraint(equalTo: caption.trailingAnchor, constant: 8),
            control.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset),
            control.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalInset),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ]
        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            accessory.setContentHuggingPriority(.required, for: .horizontal)
            accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
            addSubview(accessory)
            let gap = accessory.leadingAnchor.constraint(equalTo: control.trailingAnchor, constant: 8)
            accessoryGap = gap
            accessoryCollapsed = accessory.widthAnchor.constraint(equalToConstant: 0)
            constraints += [
                gap,
                accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
                accessory.firstBaselineAnchor.constraint(equalTo: control.firstBaselineAnchor),
            ]
        } else {
            constraints.append(control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset))
        }
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ComposeFieldRow is built in code")
    }

    /// Hides the accessory and gives its space back to the control.
    func setAccessoryHidden(_ hidden: Bool) {
        accessory?.isHidden = hidden
        accessoryGap?.constant = hidden ? 0 : 8
        accessoryCollapsed?.isActive = hidden
    }
}
