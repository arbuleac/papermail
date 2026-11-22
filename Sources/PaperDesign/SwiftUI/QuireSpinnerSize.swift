import SwiftUI

/// The three spinner sizes of spec §5.37 (`layout.progress.spinner` / `spinnerStroke`).
public enum QuireSpinnerSize: String, CaseIterable, Sendable {
    /// 12 pt, 1.5 pt stroke: buttons, rows of Settings, status lines.
    case small
    /// 16 pt, 2 pt stroke: the pending account face, rail tiles.
    case medium
    /// 32 pt, 3 pt stroke.
    case large

    public var diameter: CGFloat { Quire.Layout.Progress.spinner[index] }
    public var stroke: CGFloat { Quire.Layout.Progress.spinnerStroke[index] }

    private var index: Int {
        switch self {
        case .small: return 0
        case .medium: return 1
        case .large: return 2
        }
    }
}
