/// A state a Quire control can be forced to draw in, whatever the pointer, the mouse button or the first
/// responder say (spec §5 conventions). A gallery or a specimen snapshot sets a control's `displayState` to
/// show every state side by side; nil, the default, draws the live state.
///
/// The states are exclusive on purpose: a forced state is one cell of a specimen table, so `.focused` draws
/// the focus ring over the rest look, `.pressed` the pressed look without a ring, and so on.
public enum QuireDisplayState: String, CaseIterable, Sendable {
    case rest
    case hover
    case pressed
    case focused
}
