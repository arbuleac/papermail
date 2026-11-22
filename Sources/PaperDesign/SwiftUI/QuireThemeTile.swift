import SwiftUI

/// One theme in Settings › Appearance › Theme (spec §5.40, §4.16): the theme's miniature window (`QuireThemeMiniature`)
/// and its name 6 pt under it.
///
/// The chosen tile is marked the way Quire marks the active tab and the chosen invitation answer: by weight and a mark
/// under the name, never by a ring, because a ring is the focus ring's alone. The name is `labelStrong` `ink` with a
/// 2 pt `selRule` bar 3 pt under it, as wide as the name, `selRuleIdle` while the window is not key, as the margin rule
/// does. Other names are `label` `ink2`, turning `ink` under the pointer; the picture never takes a wash. While the
/// mouse is down the bar shows in `ruleStrong` under the pressed name, and the choice applies on mouse-up. Focused,
/// the chosen tile takes the Quire focus ring round its picture, name and bar. The bar's place is kept on every tile,
/// so a choice never moves a name.
///
/// `QuireThemePicker` lays five out as a radio group; on its own a tile is a picture for galleries and tests.
public struct QuireThemeTile: View {
    public let theme: QuireTheme
    public let isChosen: Bool
    let isPressed: Bool
    /// The picker's group has keyboard focus; only the chosen tile shows it.
    let groupFocused: Bool

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.quireForcedStates) private var forced

    public init(_ theme: QuireTheme, isChosen: Bool) {
        self.init(theme, isChosen: isChosen, isPressed: false, groupFocused: false)
    }

    init(_ theme: QuireTheme, isChosen: Bool, isPressed: Bool, groupFocused: Bool) {
        self.theme = theme
        self.isChosen = isChosen
        self.isPressed = isPressed
        self.groupFocused = groupFocused
    }

    public var body: some View {
        let s = Quire.Layout.Settings.self
        let state = QuireControlState(isHovered: isHovered, isPressed: isPressed, isFocused: groupFocused, isEnabled: isEnabled,
                                      isWindowKey: activeState != .inactive)
            .forcing(forced)
        let look = QuireThemeTileAppearance.resolve(isChosen: isChosen, state: state)
        VStack(spacing: s.themeNameGap) {
            QuireThemeMiniature(theme: theme)
            Text(theme.name)
                .quireLine(look.nameRole)
                .foregroundStyle(look.name.style)
                .overlay(alignment: .bottom) {
                    if let mark = look.mark {
                        Rectangle()
                            .fill(mark.style)
                            .frame(height: s.themeUnderline)
                            .offset(y: s.themeUnderlineGap + s.themeUnderline)
                    }
                }
                .padding(.bottom, s.themeUnderlineGap + s.themeUnderline)
        }
        .frame(width: s.themeTile[0])
        .overlay {
            if look.showsFocusRing {
                QuireFocusRingView(shape: .roundedRectangle(cornerRadius: Quire.Radius.md), gap: Quire.Border.FocusRing.gapAroundSheets)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

/// What a theme tile draws in one state (spec §5.40), pure so the state table is tested without rendering.
struct QuireThemeTileAppearance: Equatable {
    var nameRole: QuireFont.Role
    var name: QuireColorToken
    /// The bar under the name; nil draws none, keeping its place.
    var mark: QuireColorToken?
    var showsFocusRing: Bool

    static func resolve(isChosen: Bool, state live: QuireControlState) -> QuireThemeTileAppearance {
        let state = live.interactive
        let mark: QuireColorToken?
        if state.isPressed {
            mark = .ruleStrong
        } else if isChosen {
            mark = state.isWindowKey ? .selRule : .selRuleIdle
        } else {
            mark = nil
        }
        return QuireThemeTileAppearance(nameRole: isChosen ? .labelStrong : .label,
                                        name: isChosen || state.isHovered ? .ink : .ink2,
                                        mark: mark,
                                        showsFocusRing: isChosen && state.showsFocusRing)
    }
}
