import SwiftUI

/// `--snapshot-scale` (debug snapshots) for SwiftUI: a view that picks a bitmap by `displayScale`, as a paper face does
/// (Quire §5.55), reads the window's backing scale, so a 2× render of Settings from a 1× screen would hold 1× art scaled
/// up. Under a snapshot scale the hosted views are told that scale instead; otherwise nothing changes.
struct SnapshotDisplayScale: ViewModifier {
    func body(content: Content) -> some View {
        if let scale = SnapshotRenderer.scale {
            content.environment(\.displayScale, scale)
        } else {
            content
        }
    }
}
