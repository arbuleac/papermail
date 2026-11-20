#if DEBUG
import AppKit
import SSDesign

/// `--snapshot-state=minimal,title-menu` (debug builds): the title menu's items as a menu draws them, image and title, on
/// a raised card over the window, because a render cannot capture a system menu that is open. It shows what the menu's
/// account items carry, the 12 pt faces above all (Quire §5.55); the system's own chrome is not imitated.
@MainActor
final class TitleMenuSnapshotView: NSView {
    private let items: [NSMenuItem]
    private static let rowHeight: CGFloat = 22
    private static let padding: CGFloat = 6
    private static let titleX: CGFloat = 52
    /// Past the longest title, as a menu leaves room after its items.
    private static let trailing: CGFloat = 20

    init(menu: NSMenu, origin: NSPoint) {
        items = menu.items
        let height = items.reduce(Self.padding * 2) { $0 + ($1.isSeparatorItem ? 11 : Self.rowHeight) }
        // As wide as the longest title: an account's name and address are as long as the user's, never a fixed card's.
        let font = NSFont.menuFont(ofSize: 0)
        let widest = items.map { ceil((Self.title(of: $0) as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
        super.init(frame: NSRect(x: origin.x, y: origin.y, width: Self.titleX + widest + Self.trailing, height: height))
    }

    /// The title as the menu shows it, without the G-sequence column after its tab.
    private static func title(of item: NSMenuItem) -> String {
        (item.attributedTitle?.string ?? item.title).components(separatedBy: "\t").first ?? ""
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        QuireDraw.fill(bounds, radius: Quire.Radius.lg, .qRaised)
        QuireDraw.strokeInside(bounds, radius: Quire.Radius.lg, width: 1, .qRuleStrong)
        var y = Self.padding
        let font = NSFont.menuFont(ofSize: 0)
        for item in items {
            if item.isSeparatorItem {
                QuireDraw.fill(NSRect(x: 10, y: y + 5, width: bounds.width - 20, height: 1), radius: 0, .qRule)
                y += 11
                continue
            }
            if item.state == .on {
                ("✓" as NSString).draw(at: NSPoint(x: 10, y: y + 3), withAttributes: [.font: font, .foregroundColor: NSColor.qInk])
            }
            if let image = item.image {
                let side = image.size.height
                image.draw(in: NSRect(x: 26, y: y + (Self.rowHeight - side) / 2, width: image.size.width, height: side),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            (Self.title(of: item) as NSString).draw(at: NSPoint(x: Self.titleX, y: y + 3),
                                                     withAttributes: [.font: font, .foregroundColor: NSColor.qInk])
            y += Self.rowHeight
        }
    }
}
#endif
