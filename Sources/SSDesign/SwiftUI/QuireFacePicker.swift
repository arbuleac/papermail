import SwiftUI

/// The face picker (spec §5.55): a card Quire draws itself (there is no popover in the app), opened from the account's
/// face button in Settings › Accounts and anchored to it. Thirteen tiles in rows of `pickerColumns`: the paper faces in
/// order, then Monogram, the account's letters on its ink's face wash. Each face is `pickerFace` pt in a `pickerCell` pt
/// cell; the chosen one wears the account's ring, as it will in the rail.
///
/// The card is `raised` with `e2`, radius `pickerRadius`, and the 1 pt `ruleStrong` outline in Increase Contrast. The
/// grid is one Tab stop and takes focus when the card opens, on the chosen tile: ← → step through the tiles, ↑ ↓ move a
/// row, all clamped at the ends; Return or Space picks the focused tile, a click picks the clicked one, and Esc closes
/// without a change. The focused tile shows the Quire focus ring outside any account ring. Under the pointer a face darkens
/// (`hover`, then `pressed` while the mouse is down), never a wash around it. VoiceOver sees a radio group named `title`,
/// each tile by its face's name (“Fox, 8 of 13”), the chosen one selected.
public struct QuireFacePicker: View {
    let monogram: String
    let ink: Int
    let chosen: QuireAccountFace
    let title: String
    let onPick: (QuireAccountFace) -> Void
    let onClose: () -> Void

    @State private var focusIndex: Int
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.quireForcedStates) private var forced

    /// - Parameters:
    ///   - monogram: the account's letters, for the Monogram tile.
    ///   - ink: the account's ink slot: the ring of the chosen tile and the Monogram tile's wash.
    ///   - chosen: the account's face now (an automatic one included), marked and focused first.
    ///   - onPick: a tile was picked; the caller stores it and closes the card. Picking the chosen tile changes nothing.
    ///   - onClose: Esc, or a click outside the card (the caller's).
    public init(monogram: String, ink: Int, chosen: QuireAccountFace, title: String = "Face",
                onPick: @escaping (QuireAccountFace) -> Void, onClose: @escaping () -> Void) {
        self.monogram = monogram
        self.ink = ink
        self.chosen = chosen
        self.title = title
        self.onPick = onPick
        self.onClose = onClose
        let options = QuireFacePicker.options(monogram: monogram)
        _focusIndex = State(initialValue: QuireFacePicker.index(of: chosen, in: options) ?? 0)
    }

    /// The card's size: the grid and its padding (spec §5.55), for the caller's placement.
    public static var size: CGSize {
        let p = Quire.Layout.PaperFaces.self
        let count = CGFloat(Quire.PaperFace.allCases.count + 1)
        let rows = (count / p.pickerColumns).rounded(.up)
        return CGSize(width: p.pickerColumns * p.pickerCell + (p.pickerColumns - 1) * p.pickerGap + 2 * p.pickerPad,
                      height: rows * p.pickerCell + (rows - 1) * p.pickerGap + 2 * p.pickerPad)
    }

    /// The tiles in order: every paper face, then the monogram.
    static func options(monogram: String) -> [QuireAccountFace] {
        Quire.PaperFace.allCases.map(QuireAccountFace.paper) + [.monogram(monogram)]
    }

    /// Where `face` is among `options`: a monogram matches the Monogram tile whatever its letters.
    static func index(of face: QuireAccountFace, in options: [QuireAccountFace]) -> Int? {
        options.firstIndex { option in
            switch (option, face) {
            case (.monogram, .monogram): return true
            default: return option == face
            }
        }
    }

    static func name(of face: QuireAccountFace) -> String {
        switch face {
        case .paper(let paper): return paper.name
        case .monogram: return "Monogram"
        }
    }

    /// What VoiceOver is given: one radio per tile, named, in the grid's order, the chosen one selected. The accessibility
    /// representation is built from it, so tests read what VoiceOver hears.
    static func radios(monogram: String, chosen: QuireAccountFace) -> [QuireFaceRadio] {
        let options = options(monogram: monogram)
        let selected = index(of: chosen, in: options)
        return options.enumerated().map { i, face in
            QuireFaceRadio(face: face, name: name(of: face), position: i + 1, count: options.count, isSelected: i == selected)
        }
    }

    /// The tile `offset` steps along, or a row up or down, clamped to the grid; nil when the move goes nowhere.
    static func step(from index: Int, by move: MoveCommandDirection, count: Int, columns: Int) -> Int {
        switch move {
        case .left: return max(0, index - 1)
        case .right: return min(count - 1, index + 1)
        case .up: return index - columns >= 0 ? index - columns : index
        // Down from a column the last row does not reach lands on the last tile.
        case .down: return index + columns < count ? index + columns : (index / columns < (count - 1) / columns ? count - 1 : index)
        @unknown default: return index
        }
    }

    public var body: some View {
        let p = Quire.Layout.PaperFaces.self
        let options = QuireFacePicker.options(monogram: monogram)
        let columns = Int(p.pickerColumns)
        let chosenIndex = QuireFacePicker.index(of: chosen, in: options)
        let showsFocus = (isFocused || forced.contains(.focused)) && activeState != .inactive
        VStack(alignment: .leading, spacing: p.pickerGap) {
            ForEach(Array(stride(from: 0, to: options.count, by: columns)), id: \.self) { start in
                HStack(spacing: p.pickerGap) {
                    ForEach(start..<min(start + columns, options.count), id: \.self) { i in
                        Button {
                            focusIndex = i
                            pick(options[i])
                        } label: {
                            EmptyView()
                        }
                        .buttonStyle(QuireFacePickerTileStyle(face: options[i], ink: ink, isChosen: i == chosenIndex,
                                                              showsFocusRing: showsFocus && i == focusIndex))
                        .focusable(false)
                        .help(QuireFacePicker.name(of: options[i]))
                    }
                }
            }
        }
        .padding(p.pickerPad)
        .frame(width: QuireFacePicker.size.width, height: QuireFacePicker.size.height, alignment: .topLeading)
        .background { card }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear {
            // Focus moves into the grid as the card opens, so the keys reach it at once.
            DispatchQueue.main.async { isFocused = true }
        }
        .onMoveCommand { move in
            focusIndex = QuireFacePicker.step(from: focusIndex, by: move, count: options.count, columns: columns)
        }
        .onKeyPress(.return) {
            pick(options[focusIndex])
            return .handled
        }
        .onKeyPress(.space) {
            pick(options[focusIndex])
            return .handled
        }
        .onExitCommand(perform: onClose)
        .accessibilityRepresentation {
            Picker(title, selection: Binding(get: { chosenIndex ?? 0 }, set: { pick(options[$0]) })) {
                ForEach(QuireFacePicker.radios(monogram: monogram, chosen: chosen), id: \.position) { radio in
                    Text(radio.name).tag(radio.position - 1)
                }
            }
            .pickerStyle(.radioGroup)
        }
    }

    private func pick(_ face: QuireAccountFace) {
        if QuireFacePicker.index(of: face, in: [chosen]) != nil {
            onClose()
        } else {
            onPick(face)
        }
    }

    /// `raised`, `e2` (two shadows, the key and the contact), the IC outline.
    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: Quire.Layout.PaperFaces.pickerRadius, style: .continuous)
        let layers = Quire.Elevation.e2.layers(for: colorScheme == .dark ? .dark : .light)
        return shape.fill(.qRaised)
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(.qRuleStrong, lineWidth: Quire.Border.IcOutline.width)
                }
            }
            .shadow(color: Color(nsColor: layers[0].color), radius: layers[0].shadowRadius, x: layers[0].x, y: layers[0].y)
            .shadow(color: Color(nsColor: layers[1].color), radius: layers[1].shadowRadius, x: layers[1].x, y: layers[1].y)
    }
}

/// One tile as VoiceOver reads it in the picker's radio group.
struct QuireFaceRadio: Equatable {
    let face: QuireAccountFace
    let name: String
    let position: Int
    let count: Int
    let isSelected: Bool

    /// VoiceOver's phrasing for a radio button in a group of `count`: “Fox, 8 of 13, selected”.
    var spoken: String {
        "\(name), \(position) of \(count)" + (isSelected ? ", selected" : "")
    }
}

/// A tile as a button, so the pressed look lasts until mouse-up and the pick happens there.
struct QuireFacePickerTileStyle: ButtonStyle {
    let face: QuireAccountFace
    let ink: Int
    let isChosen: Bool
    let showsFocusRing: Bool

    func makeBody(configuration: Configuration) -> some View {
        QuireFacePickerTile(face: face, ink: ink, isChosen: isChosen, isPressed: configuration.isPressed, showsFocusRing: showsFocusRing)
    }
}

/// One cell: the 48 pt face, ringed when chosen, darkened under the pointer, with the focus ring outside it all.
struct QuireFacePickerTile: View {
    let face: QuireAccountFace
    let ink: Int
    let isChosen: Bool
    let isPressed: Bool
    let showsFocusRing: Bool

    @State private var isHovered = false
    @Environment(\.quireForcedStates) private var forced

    var body: some View {
        let p = Quire.Layout.PaperFaces.self
        let ring = Quire.Border.AccountRing.gap + Quire.Border.AccountRing.width
        let state = QuireControlState(isHovered: isHovered, isPressed: isPressed).forcing(forced.subtracting(.focused))
        QuireAvatarView(account: face, ink: ink, diameter: p.pickerFace, ringed: isChosen)
            .overlay {
                if state.isPressed {
                    Circle().fill(.qPressed)
                } else if state.isHovered {
                    Circle().fill(.qHover)
                }
            }
            .overlay {
                if showsFocusRing {
                    QuireFocusRingView(shape: .circle, gap: Quire.Border.FocusRing.gap)
                        .padding(-ring)
                }
            }
            .frame(width: p.pickerCell, height: p.pickerCell)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .quirePointer(acts: !isChosen)
            .accessibilityHidden(true)
    }
}
