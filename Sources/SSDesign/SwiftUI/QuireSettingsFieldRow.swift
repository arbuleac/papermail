import SwiftUI

/// A Settings row for a text field that can show its error help line (spec §5.25, §5.40): the field sits
/// centred in the row's first 40 pt with the label beside it, and the help line hangs below, growing the row
/// downwards. A centred row would centre the label on the field and its help line together, which put it
/// half a line below the field.
public struct QuireSettingsFieldRow<Field: View>: View {
    let label: String
    let field: Field

    public init(_ label: String, @ViewBuilder field: () -> Field) {
        self.label = label
        self.field = field()
    }

    public var body: some View {
        let s = Quire.Layout.Settings.self
        QuireSettingsRow(label, alignment: .top) {
            field.padding(.top, (s.row - s.fieldHeight) / 2)
        }
    }
}
