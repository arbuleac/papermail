import SwiftUI

/// A Quire button label: an optional leading glyph and the title, at the metrics of the `QuireButtonStyle`
/// around it (glyph 12 / 14 / 18 pt, 6 pt gap), with the loading state of spec §5.24: a 12 pt spinner in the
/// label colour replaces the glyph, the title becomes the gerund (“Sending…”), and the width stays that of the
/// wider of the two so nothing beside the button moves.
public struct QuireButtonLabel: View {
    let title: String
    let glyph: String?
    let glyphSize: CGFloat?
    let isLoading: Bool
    let loadingTitle: String?
    let accessibilityText: String?

    @Environment(\.quireButtonSize) private var size

    /// - Parameters:
    ///   - glyph: a name from `Quire.Icon` (an SF Symbol or an `ss.` glyph).
    ///   - glyphSize: overrides the size's glyph metric, for the named exceptions (+/− at 11 pt).
    ///   - loadingTitle: the gerund shown while `isLoading`; the title stays when nil.
    public init(_ title: String, glyph: String? = nil, glyphSize: CGFloat? = nil, isLoading: Bool = false,
                loadingTitle: String? = nil) {
        self.title = title
        self.glyph = glyph
        self.glyphSize = glyphSize
        self.isLoading = isLoading
        self.loadingTitle = loadingTitle
        self.accessibilityText = nil
    }

    /// A glyph-only label for `.icon` buttons; `accessibilityLabel` names the action (spec §4.14).
    public init(glyph: String, accessibilityLabel: String, glyphSize: CGFloat? = nil, isLoading: Bool = false) {
        self.title = ""
        self.glyph = glyph
        self.glyphSize = glyphSize
        self.isLoading = isLoading
        self.loadingTitle = nil
        self.accessibilityText = accessibilityLabel
    }

    public var body: some View {
        ZStack {
            row(title: title, spinner: false)
                .opacity(isLoading ? 0 : 1)
                .accessibilityHidden(isLoading)
            if isLoading || loadingTitle != nil {
                row(title: loadingTitle ?? title, spinner: true)
                    .opacity(isLoading ? 1 : 0)
                    .accessibilityHidden(!isLoading)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText.map { Text($0) } ?? Text(isLoading ? (loadingTitle ?? title) : title))
        .preference(key: QuireButtonLoadingKey.self, value: isLoading)
    }

    private func row(title: String, spinner: Bool) -> some View {
        HStack(spacing: Quire.Layout.Button.glyphGap) {
            if spinner {
                // Spinners keep their delay here too: a press that finishes inside 150 ms never shows one.
                QuireSpinner(.small, color: nil)
            } else if let glyph {
                QuireSymbolImage(name: glyph, size: .custom(glyphSize ?? size.glyph))
            }
            if !title.isEmpty {
                Text(title)
            }
        }
    }
}

/// Whether a `QuireButtonLabel` in a button is loading, for the `QuireButtonStyle` around it, which sees only its label
/// as a view and gives a loading button the arrow (§4.17).
struct QuireButtonLoadingKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}
