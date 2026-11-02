import SwiftUI

/// One row of a `QuireSettingsGrid`: the label right-aligned in the 140 pt column, the control after the
/// 12 pt gap, at least 40 pt tall, the control centred vertically and free to fill the column to the content's
/// trailing padding (fields reach 360 pt at the 560 pt window).
public struct QuireSettingsRow<Control: View>: View {
    let label: String?
    let minHeight: CGFloat
    let alignment: VerticalAlignment
    let control: Control

    /// - Parameters:
    ///   - label: the row's label; nil leaves the label cell empty (a second checkbox under the first, the
    ///     Remove… button of the account detail).
    ///   - minHeight: 40 pt (`settings.row`); rows with wrapping content grow past it.
    ///   - alignment: `.center` (each control centred in its row); `.top` for a control taller than the row,
    ///     whose label is then centred in the row's first `minHeight` points. Wrapping text has its own row,
    ///     `QuireSettingsTextRow`, because `Grid` mismeasures wrapped text in a column cell.
    public init(_ label: String?, minHeight: CGFloat = Quire.Layout.Settings.row, alignment: VerticalAlignment = .center,
                @ViewBuilder control: () -> Control) {
        self.label = label
        self.minHeight = minHeight
        self.alignment = alignment
        self.control = control()
    }

    public var body: some View {
        GridRow(alignment: alignment) {
            QuireSettingsLabel(text: label, minHeight: alignment == .top ? minHeight : nil)
            control
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: Alignment(horizontal: .leading, vertical: alignment))
        }
    }
}

/// The label cell: `body` `ink`, trailing-aligned in the label column.
struct QuireSettingsLabel: View {
    let text: String?
    /// For top-aligned rows, the label's line is centred in the row's first 40 pt, as the control's is.
    var minHeight: CGFloat?

    var body: some View {
        Group {
            if let text {
                Text(text)
                    .quireLine(.body)
                    .foregroundStyle(Color.qInk)
                    .accessibilityAddTraits(.isStaticText)
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .frame(width: Quire.Layout.Settings.labelColumn, height: minHeight, alignment: .trailing)
    }
}
