import AppKit
import PaperDesign

/// Where the Dock badge is written: the app's Dock tile, or a test's stand-in, so no test badges a real icon.
@MainActor
protocol DockBadgeTile: AnyObject {
    var badgeLabel: String? { get set }
}

extension NSDockTile: DockBadgeTile {}

/// The unread count on the Dock icon (spec §5.28): All Inboxes' count in the words the rail's badges use
/// (`QuireBadge.unreadText`), so the two always agree, “99+” above 99 and nothing at all at zero.
///
/// Each main window's `InboxMonitor` holds it while it runs, and the newest holder that has counted is shown. A
/// window replaced by another (the demo and the real mailbox cross-fading, §5.43) is torn down after its successor
/// has counted; were stopping simply to clear the badge, the new count would vanish until it next changed.
///
/// macOS draws the badge only while badges are allowed for the app in System Settings › Notifications; with them
/// off, or notifications denied, it shows nothing. That is the user's choice, so nothing here works around it:
/// the label is still set, and appears as soon as badges are allowed again.
@MainActor
final class DockBadge {
    // `shared`, not `NSApp`: a window's monitor is built before anything else need have made the application.
    static let app = DockBadge(tile: NSApplication.shared.dockTile)

    private struct Holder {
        weak var monitor: AnyObject?
        /// False until its first count: a monitor that has not counted yet leaves the last count showing.
        var hasCounted = false
        var text: String?
    }

    private let tile: DockBadgeTile
    /// Oldest first; the newest one that has counted is shown.
    private var holders: [Holder] = []

    init(tile: DockBadgeTile) {
        self.tile = tile
    }

    /// What the Dock tile shows now.
    var text: String? { tile.badgeLabel }

    /// `monitor` started: from its first count it is shown over every holder before it.
    func claim(_ monitor: AnyObject) {
        guard !holders.contains(where: { $0.monitor === monitor }) else { return }
        holders.append(Holder(monitor: monitor))
    }

    /// `monitor`'s count of unread mail in All Inboxes.
    func show(unread count: Int, for monitor: AnyObject) {
        guard let index = holders.firstIndex(where: { $0.monitor === monitor }) else { return }
        holders[index].hasCounted = true
        holders[index].text = QuireBadge.unreadText(count)
        apply()
    }

    /// `monitor` stopped: the newest holder left is shown, or nothing when none is.
    func release(_ monitor: AnyObject) {
        holders.removeAll { $0.monitor === monitor }
        apply()
    }

    private func apply() {
        // A monitor gone without stopping (its window freed in a test) must not leave its count behind.
        holders.removeAll { $0.monitor == nil }
        let shown = holders.last(where: \.hasCounted)?.text
        // The Dock redraws on every write; the counts arrive on every archive and sync batch.
        if tile.badgeLabel != shown { tile.badgeLabel = shown }
    }
}
