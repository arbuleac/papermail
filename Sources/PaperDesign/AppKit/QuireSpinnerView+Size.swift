import CoreGraphics

extension QuireSpinnerView {
    /// The three spinner sizes of spec §5.37 (`layout.progress.spinner` / `spinnerStroke`).
    public enum Size: Int, CaseIterable, Sendable {
        /// 12 pt: buttons, the sync line, search, chips, rail tiles, the list footer.
        case small
        /// 16 pt: the undo panel, the pending rail tile, the welcome screen.
        case medium
        /// 32 pt.
        case large

        public var diameter: CGFloat { Quire.Layout.Progress.spinner[rawValue] }
        public var strokeWidth: CGFloat { Quire.Layout.Progress.spinnerStroke[rawValue] }
    }
}
