import SwiftUI

/// The pointer over a Quire SwiftUI control (spec §4.17): the pointing hand while a click acts on it, the I-beam over a
/// field's face, where a click puts the caret, and no style of its own while the control is disabled or a click would
/// change nothing (the chosen radio or theme), so the arrow shows.
struct QuirePointerModifier: ViewModifier {
    enum Kind {
        case link
        case text
    }

    let kind: Kind
    let acts: Bool

    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.pointerStyle(Self.style(kind, shows: acts && isEnabled))
    }

    static func style(_ kind: Kind, shows: Bool) -> PointerStyle? {
        guard shows else { return nil }
        switch kind {
        case .link: return .link
        case .text: return .horizontalText
        }
    }
}

extension View {
    /// The pointing hand over this control while a click acts on it: `acts` false, or the control disabled, leaves the
    /// arrow (spec §4.17). Every Quire style applies it; a view of the app's own that acts on a click does too.
    public func quirePointer(acts: Bool = true) -> some View {
        modifier(QuirePointerModifier(kind: .link, acts: acts))
    }

    /// The I-beam over a field's face, padding included, while it is enabled.
    func quireTextPointer() -> some View {
        modifier(QuirePointerModifier(kind: .text, acts: true))
    }
}
