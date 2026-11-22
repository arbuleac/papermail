import AppKit
import PaperDesign

/// The format row (spec §5.20): toggled by the Format button or ⇧⌘T, a docked 36 pt `paper` row with a top
/// hairline directly above the bottom bar, so it never covers text and needs no motion. From x = 16: Bold ·
/// Italic · Underline, 12 pt, Bulleted list · Numbered list · Quote, 12 pt, Link, as 28 pt icon toggles 2 pt
/// apart with 14 pt symbols. A toggle is on (`accent` on `accentWash`) when its style applies at the caret or
/// across the whole selection; a mixed selection shows off.
@MainActor
final class ComposeFormatRow: NSView {
    enum Item: CaseIterable {
        case bold, italic, underline, bulletList, numberedList, quote, link

        var symbol: String {
            switch self {
            case .bold: return Quire.Icon.bold
            case .italic: return Quire.Icon.italic
            case .underline: return Quire.Icon.underline
            case .bulletList: return Quire.Icon.bulletedList
            case .numberedList: return Quire.Icon.numberedList
            case .quote: return Quire.Icon.blockQuote
            case .link: return Quire.Icon.link
            }
        }

        /// The command's menu name and shortcut (§5.34): “Bold  ⌘B”.
        var tooltip: String {
            switch self {
            case .bold: return "Bold  ⌘B"
            case .italic: return "Italic  ⌘I"
            case .underline: return "Underline  ⌘U"
            case .bulletList: return "Bulleted List  ⇧⌘8"
            case .numberedList: return "Numbered List  ⇧⌘7"
            case .quote: return "Quote  ⌘'"
            case .link: return "Add Link…  ⌘K"
            }
        }

        var accessibilityName: String {
            switch self {
            case .bold: return "Bold"
            case .italic: return "Italic"
            case .underline: return "Underline"
            case .bulletList: return "Bulleted List"
            case .numberedList: return "Numbered List"
            case .quote: return "Quote"
            case .link: return "Link"
            }
        }

        /// A gap of `formatGroupGap` goes before these.
        var startsGroup: Bool { self == .bulletList || self == .link }
    }

    var onToggle: ((Item) -> Void)?
    private(set) var buttons: [(item: Item, button: QuireIconButton)] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for item in Item.allCases {
            let button = QuireIconButton(symbolName: item.symbol, size: .large, accessibilityLabel: item.accessibilityName,
                                         target: self, action: #selector(toggled(_:)))
            button.symbolSize = .custom(Quire.Layout.IconSize.inText)
            button.onStyle = .quiet
            button.toolTip = item.tooltip
            addSubview(button)
            buttons.append((item, button))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ComposeFormatRow is built in code")
    }

    override var isFlipped: Bool { true }

    func setState(_ state: ComposeTextView.FormatState) {
        for (item, button) in buttons {
            switch item {
            case .bold: button.isOn = state.bold
            case .italic: button.isOn = state.italic
            case .underline: button.isOn = state.underline
            case .bulletList: button.isOn = state.bulletList
            case .numberedList: button.isOn = state.numberedList
            case .quote: button.isOn = state.quote
            case .link: button.isOn = state.link
            }
        }
    }

    @objc private func toggled(_ sender: QuireIconButton) {
        guard let item = buttons.first(where: { $0.button === sender })?.item else { return }
        onToggle?(item)
    }

    override func layout() {
        super.layout()
        let c = Quire.Layout.Composer.self
        var x = c.barPadX
        for (index, entry) in buttons.enumerated() {
            if index > 0 { x += entry.item.startsGroup ? c.formatGroupGap : c.formatGap }
            let visual = NSRect(x: x, y: ((bounds.height - c.formatToggle) / 2).rounded(), width: c.formatToggle, height: c.formatToggle)
            entry.button.frame = entry.button.frame(forVisualRect: visual)
            x = visual.maxX
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.qPaper.setFill()
        // Views no longer clip to their bounds (macOS 14), and the dirty rect can reach past them.
        dirtyRect.intersection(bounds).fill()
        QuireHairline.fill(along: NSRect(x: 0, y: 0, width: bounds.width, height: 1), orientation: .horizontal,
                           width: QuireHairline.width(for: self), color: .qRule, atMaxEdge: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
