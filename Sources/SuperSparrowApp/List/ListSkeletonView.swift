import AppKit
import SSDesign

/// Skeleton rows for an account's first sync, before its first page lands (spec §5.10): static `fill` bars, no
/// shimmer, shown only after 300 ms so a fast first page never flashes them, and swapped for content instantly.
final class ListSkeletonView: NSView {
    var density = AppSettings.ListDensity.standard {
        didSet { if oldValue != density { needsDisplay = true } }
    }

    /// The rows stand in for rows at this Text size (spec §4.15).
    var textSize = QuireFont.TextSize.default {
        didSet { if oldValue != textSize { needsDisplay = true } }
    }

    private var revealTimer: Timer?

    override var isFlipped: Bool { true }

    /// Shows the rows after `dur.skeletonDelay` unless `conceal()` comes first.
    func reveal() {
        guard isHidden, revealTimer == nil else { return }
        let timer = Timer(timeInterval: Quire.Motion.skeletonDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.revealTimer = nil
                self?.isHidden = false
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer
    }

    func conceal() {
        revealTimer?.invalidate()
        revealTimer = nil
        isHidden = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.qPaper.setFill()
        bounds.intersection(dirtyRect).fill()
        let compact = density == .compact
        let height = QuireRowMetrics(textSize: textSize, compact: compact).height
        var y: CGFloat = 0
        var index = 0
        while y < bounds.height {
            let rect = NSRect(x: 0, y: y, width: bounds.width, height: height)
            QuireSkeleton.draw(compact ? .compactRow(index: index) : .row(index: index), in: rect, textSize: textSize)
            y += height
            index += 1
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func isAccessibilityElement() -> Bool { !isHidden }
    override func accessibilityRole() -> NSAccessibility.Role? { .busyIndicator }
    override func accessibilityLabel() -> String? { "Loading" }
}
