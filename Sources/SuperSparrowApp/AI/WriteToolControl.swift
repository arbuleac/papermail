import AppKit
import SSDesign

/// What is left of 1.12's Write control, which sat in the quick reply's tool row and the composer's bottom bar. Since 1.13
/// Help me write lives in the text, at the caret (§5.56, `WriteInlineLayer`), and nothing drives this control: it stays
/// hidden and lays nothing out. The composer's bar still declares one while round 3's two branches meet (the bar is the
/// other branch's to change); delete this file with the bar's property once they have.
@MainActor
final class WriteToolControl: NSView {
    /// Never shown: the bar's Tab loop skips it.
    let writeButton = QuireButton(title: "Write", variant: .ghost, size: .small, symbolName: Quire.Icon.helpMeWrite)
    var onContentChange: (() -> Void)?
    var fittingWidth: CGFloat { 0 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        writeButton.isHidden = true
        addSubview(writeButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("built in code")
    }

    /// Hidden for good: nothing may show it again.
    override var isHidden: Bool {
        get { true }
        set { super.isHidden = true }
    }
}
