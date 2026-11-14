import SwiftUI

/// Settings › Appearance › Theme (spec §5.40, §4.16): the five themes as `QuireThemeTile`s in one row, 15 pt apart,
/// exactly the 360 pt field column, in a 76 pt row; then the chosen theme's caption in `meta` `ink3`, with two lines
/// reserved so a choice never moves the rows below.
///
/// It is a radio group. The group is one Tab stop; ← → and ↑ ↓ move the choice and apply it at once, clamped at the
/// ends as native radio groups are. Focus stays on the group through every step: the window re-themes in place under
/// its `QuireThemeRoot`, so nothing is rebuilt. Clicking a tile chooses it on mouse-up. VoiceOver sees a native radio
/// group named `title`, each tile its theme's name ("Study, 1 of 5, selected"), the pictures hidden and the caption as
/// the group's help.
///
///     QuireThemePicker("Theme", selection: $settings.theme)
public struct QuireThemePicker: View {
    let title: String
    @Binding var selection: QuireTheme
    let focus: FocusState<Bool>.Binding?

    @FocusState private var ownFocus: Bool
    @Environment(\.quireForcedStates) private var forced

    /// - Parameters:
    ///   - title: the group's accessibility label (the Settings row label beside it).
    ///   - focus: an external focus binding, for forms that move focus themselves; the group tracks its own otherwise.
    public init(_ title: String, selection: Binding<QuireTheme>, focus: FocusState<Bool>.Binding? = nil) {
        self.title = title
        _selection = selection
        self.focus = focus
    }

    public var body: some View {
        let s = Quire.Layout.Settings.self
        let groupFocused = (focus?.wrappedValue ?? ownFocus) || forced.contains(.focused)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: s.themeTileGap) {
                ForEach(QuireTheme.allCases, id: \.self) { theme in
                    Button {
                        selection = theme
                    } label: {
                        Text(theme.name)
                    }
                    .buttonStyle(QuireThemeTileButton(theme: theme, isChosen: theme == selection, groupFocused: groupFocused))
                    .focusable(false)
                }
            }
            .frame(height: s.themeRow, alignment: .top)
            .focusable()
            .focusEffectDisabled()
            .focused(focus ?? $ownFocus)
            .onMoveCommand { direction in
                switch direction {
                case .left, .up: move(by: -1)
                case .right, .down: move(by: 1)
                default: break
                }
            }
            .accessibilityRepresentation {
                Picker(title, selection: $selection) {
                    ForEach(Self.radios(selection: selection), id: \.theme) { radio in
                        Text(radio.name).tag(radio.theme)
                    }
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .accessibilityHint(selection.caption)
            }
            Text(selection.caption)
                .quireParagraph(.meta)
                .foregroundStyle(.qInk3)
                .lineLimit(Int(s.themeCaptionLines))
                .frame(width: s.captionMaxWidth, height: s.themeCaptionLines * QuireFont.Role.meta.lineHeight, alignment: .topLeading)
                // Read as the group's help, not twice.
                .accessibilityHidden(true)
        }
    }

    /// What the tiles are to VoiceOver: one radio per theme, named, in Settings' order, the chosen one selected. The
    /// accessibility representation is built from it, so tests read what VoiceOver is given: SwiftUI builds its own
    /// accessibility tree only while an assistive client is connected.
    static func radios(selection: QuireTheme) -> [QuireThemeRadio] {
        let themes = QuireTheme.allCases
        return themes.enumerated().map { i, theme in
            QuireThemeRadio(theme: theme, name: theme.name, position: i + 1, count: themes.count, isSelected: theme == selection)
        }
    }

    /// The theme `offset` steps along, clamped to the ends, chosen at once.
    func move(by offset: Int) {
        let themes = QuireTheme.allCases
        guard let next = QuireStep.index(after: themes.firstIndex(of: selection), by: offset, count: themes.count) else { return }
        selection = themes[next]
    }
}

/// One theme as VoiceOver reads it in the picker's radio group.
struct QuireThemeRadio: Equatable {
    let theme: QuireTheme
    let name: String
    let position: Int
    let count: Int
    let isSelected: Bool

    /// VoiceOver's own phrasing for a radio button in a group of `count`: “Study, 1 of 5, selected”.
    var spoken: String {
        "\(name), \(position) of \(count)" + (isSelected ? ", selected" : "")
    }
}

/// A tile as a button, so the pressed look lasts until mouse-up and the choice applies there.
struct QuireThemeTileButton: ButtonStyle {
    let theme: QuireTheme
    let isChosen: Bool
    let groupFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        QuireThemeTile(theme, isChosen: isChosen, isPressed: configuration.isPressed, groupFocused: groupFocused)
    }
}
