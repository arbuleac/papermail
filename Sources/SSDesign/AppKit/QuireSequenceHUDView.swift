import AppKit

/// The g-sequence HUD (spec §5.32): a slip that fades in 500 ms after G when no second key has come, at the
/// bottom centre of the list pane. 220 pt wide, radius 12, padding 12, `slip` with its 1 pt `slipEdge` and
/// `e2`. A 28 pt header (the “G” keycap on the slip, 8 pt, “Go to…” in `bodyStrong` `onSlip`), then 6 pt
/// below it one 22 pt row per view (keycap, 8 pt, the view's name in `snippet` `onSlip2`): 190 pt for six.
///
/// The rows come from the cheat sheet's “G then …” rows (`cheatSheetContent`), so the HUD, the overlay and
/// the key map cannot disagree. It is not focusable; the shell owns arming, timing and dismissal, and fades
/// it with `show()` and `hide(completion:)`.
@MainActor
public final class QuireSequenceHUDView: NSView {
    /// The key that armed the sequence (“G”).
    public let leader: String
    public let title: String
    /// The second keys and what they open: `keys` is the keycap legend (“I”), `label` the view (“Inbox”).
    public let rows: [QuireCheatSheetRow]

    private let surface = QuireSurfaceView(frame: .zero)
    private let content = HUDContentView(frame: .zero)

    /// Every “<leader> then <key>” row of the cheat sheet, as the key and its label.
    public static func sequenceRows(leader: String = "G", in sections: [QuireCheatSheetSection] = Quire.cheatSheet) -> [QuireCheatSheetRow] {
        sections.flatMap(\.rows).compactMap { row in
            let parts = row.parts
            guard parts.count == 3, parts[0].text == leader, parts[0].isKeycap, !parts[1].isKeycap, parts[2].isKeycap else { return nil }
            return QuireCheatSheetRow(keys: parts[2].text, label: row.label)
        }
    }

    /// The HUD's height for `rowCount` rows: 12 + 28 + 6 + rows × 22 + 12.
    public static func height(rowCount: Int) -> CGFloat {
        let h = Quire.Layout.GHud.self
        return 2 * h.pad + h.headerHeight + h.rowsTop + CGFloat(rowCount) * h.row
    }

    public init(leader: String = "G", title: String = "Go to…", rows: [QuireCheatSheetRow]? = nil) {
        self.leader = leader
        self.title = title
        self.rows = rows ?? QuireSequenceHUDView.sequenceRows(leader: leader)
        super.init(frame: NSRect(x: 0, y: 0, width: Quire.Layout.GHud.width, height: QuireSequenceHUDView.height(rowCount: self.rows.count)))
        wantsLayer = true
        clipsToBounds = false
        surface.fillColor = .qSlip
        surface.cornerRadius = Quire.Layout.GHud.radius
        surface.elevation = Quire.Elevation.e2
        surface.edge = { _ in .solid(.qSlipEdge, width: 1) }
        content.owner = self
        addSubview(surface)
        addSubview(content)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireSequenceHUDView is built in code") }

    public override var isFlipped: Bool { true }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: Quire.Layout.GHud.width, height: QuireSequenceHUDView.height(rowCount: rows.count))
    }

    public override func layout() {
        super.layout()
        surface.frame = bounds
        content.frame = bounds
    }

    // MARK: Showing

    /// Fades in over `dur.quick` (a fade, kept under Reduce Motion).
    public func show() {
        isHidden = false
        guard let layer else { return }
        layer.opacity = 0
        Quire.Motion.animate(layer, keyPath: "opacity", to: Float(1), duration: Quire.Motion.quick, curve: .settle, reduced: .keep)
    }

    /// Fades out over `dur.quick`, then hides.
    public func hide(completion: (@MainActor () -> Void)? = nil) {
        guard let layer, !isHidden else { completion?(); return }
        Quire.Motion.animate(layer, keyPath: "opacity", to: Float(0), duration: Quire.Motion.quick, curve: .leave, reduced: .keep) { [weak self] in
            self?.isHidden = true
            self?.layer?.opacity = 1
            completion?()
        }
    }

    // MARK: Pointer

    /// Clicks go through to what is under it, as they do under a reader window's toasts: it only tells which keys go
    /// where. A HUD that took them would do nothing with them while the rows under it kept their hand (§4.17).
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: Accessibility

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .group }
    public override func accessibilityLabel() -> String? {
        super.accessibilityLabel() ?? ([title] + rows.map { "\($0.keys) \($0.label)" }).joined(separator: ", ")
    }

    // MARK: Content

    fileprivate final class HUDContentView: NSView {
        weak var owner: QuireSequenceHUDView?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                                   name: QuireEnvironment.didChangeNotification, object: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("built in code") }

        @objc private func environmentDidChange(_ note: Notification) {
            needsDisplay = true
        }

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            guard let owner else { return }
            let h = Quire.Layout.GHud.self
            func line(_ legend: String, _ text: NSAttributedString, top: CGFloat, height: CGFloat, role: QuireFont.Role) {
                let cap = QuireKeycap.size(for: legend, style: .onSlip)
                let capRect = NSRect(x: h.pad, y: top + ((height - cap.height) / 2).rounded(), width: cap.width, height: cap.height)
                QuireKeycap.draw(legend, style: .onSlip, in: capRect)
                let x = capRect.maxX + h.keycapGap
                let lineHeight = role.lineHeight
                QuireDraw.draw(text, x: x, top: top + ((height - lineHeight) / 2).rounded(), maxWidth: bounds.width - h.pad - x,
                               lineHeight: lineHeight)
            }
            line(owner.leader, QuireDraw.line(owner.title, .bodyStrong, .qOnSlip), top: h.pad, height: h.headerHeight, role: .bodyStrong)
            var top = h.pad + h.headerHeight + h.rowsTop
            for row in owner.rows {
                line(row.keys, QuireDraw.line(row.label, .snippet, .qOnSlip2), top: top, height: h.row, role: .snippet)
                top += h.row
            }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        override func isAccessibilityElement() -> Bool { false }
    }
}
