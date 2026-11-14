import SwiftUI

/// A Quire popup button for choosing one value (spec §5.27, §8.3): a system menu, with a checkmark on the
/// current value, under a face drawn by `QuirePopupLabel`.
///
///     QuirePopup("Undo send", selection: $delay, options: [5, 10, 20]) { "\($0) seconds" }
///     QuirePopup("Colour", selection: $ink, options: Array(0..<10), width: 160, title: { Quire.accountInkNames[$0] },
///                swatch: { $0 })
///
/// The menu is a `Menu` in `.menuStyle(.button)` with a Quire button style rather than the
/// `.menuStyle(.borderlessButton)` of the spec's table: a borderless-button menu is drawn by AppKit, which
/// keeps only the label's text and image and drops the face, edge and halo (verified on macOS 27).
public struct QuirePopup<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let width: CGFloat?
    let itemTitle: (Value) -> String
    let swatch: ((Value) -> Int)?

    /// - Parameters:
    ///   - title: the accessibility label (the Settings row label beside it).
    ///   - width: a fixed width; the popup otherwise fits its current value.
    public init(_ title: String, selection: Binding<Value>, options: [Value], width: CGFloat? = nil,
                title itemTitle: @escaping (Value) -> String) {
        self.title = title
        _selection = selection
        self.options = options
        self.width = width
        self.itemTitle = itemTitle
        self.swatch = nil
    }

    /// A popup whose values are account inks: the face and every menu item show the ink's swatch.
    public init(_ title: String, selection: Binding<Value>, options: [Value], width: CGFloat? = nil,
                title itemTitle: @escaping (Value) -> String, swatch: @escaping (Value) -> Int) {
        self.title = title
        _selection = selection
        self.options = options
        self.width = width
        self.itemTitle = itemTitle
        self.swatch = swatch
    }

    public var body: some View {
        Menu {
            Picker(selection: $selection) {
                ForEach(options, id: \.self) { option in
                    item(option).tag(option)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            QuirePopupLabel(itemTitle(selection), swatch: swatch?(selection), width: width)
        }
        .menuStyle(.button)
        .buttonStyle(QuirePopupButtonStyle())
        .menuIndicator(.hidden)
        .focusEffectDisabled()
        .fixedSize()
        .quirePointer()
        .accessibilityLabel(title)
        .accessibilityValue(itemTitle(selection))
    }

    @ViewBuilder
    private func item(_ option: Value) -> some View {
        if let swatch {
            Label {
                Text(itemTitle(option))
            } icon: {
                Image(nsImage: QuirePopupSwatch.menuImage(slot: swatch(option)))
            }
        } else {
            Text(itemTitle(option))
        }
    }
}

/// Hands the menu button's press (menu open) to the `QuirePopupLabel` it wraps.
struct QuirePopupButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.quirePopupIsPressed, configuration.isPressed)
    }
}
