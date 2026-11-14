import SwiftUI

/// One 56 pt row of the Settings account group (spec §5.40, Account row parts):
///
/// - the account face (30 pt, ring in the account ink) with its leading edge at x = 16;
/// - from x = 62, the name in `bodyStrong` `ink` with the provider tag 6 pt after it (the name truncates, the
///   tag never does), over the address in `snippet` `ink2`, or Sign in required in `danger` in its place;
/// - the status block 16 pt from the trailing edge, centred on the row, at least 12 pt clear of the name;
/// - when selected, the margin-rule selection: `selWash` + a 3 pt `selRule` rule while the window is key,
///   `selWashIdle` + `selRuleIdle` when not (`controlActiveState`). No hover, no pressed wash.
///
/// Rows normally live in a `QuireAccountGroup`, which draws the separators, the focus ring and selection on
/// mouse-down; a row alone is useful for galleries and tests.
public struct QuireAccountRow: View {
    let content: QuireAccountRowContent
    let isSelected: Bool
    let onAction: (() -> Void)?
    let isActionEnabled: Bool
    var showsFocusRing = false

    @Environment(\.controlActiveState) private var activeState

    /// - Parameters:
    ///   - onAction: runs the status's action (Reconnect, Cancel, Retry); its button shows only when the status
    ///     names one.
    ///   - isActionEnabled: false while another sign-in runs (spec §5.40, Reconnecting).
    public init(_ content: QuireAccountRowContent, isSelected: Bool = false, isActionEnabled: Bool = true,
                onAction: (() -> Void)? = nil) {
        self.content = content
        self.isSelected = isSelected
        self.isActionEnabled = isActionEnabled
        self.onAction = onAction
    }

    public var body: some View {
        let s = Quire.Layout.Settings.self
        let selection = QuireSelectionAppearance.resolve(isSelected: isSelected, isWindowKey: activeState != .inactive)
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                QuireAvatarView(accountMonogram: content.monogram, ink: content.inkSlot, diameter: s.accountFace)
                    .padding(.leading, s.accountFaceX)
                    .padding(.trailing, s.accountHairlineX - s.accountFaceX - s.accountFace)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: s.tagGap) {
                        Text(content.name)
                            .quireLine(.bodyStrong)
                            .truncationMode(.tail)
                            .foregroundStyle(.qInk)
                        QuireSettingsTag(content.tag)
                            .fixedSize()
                            .layoutPriority(1)
                    }
                    addressLine
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            Spacer(minLength: s.statusGap)
            QuireAccountStatusView(status: content.status, isActionEnabled: isActionEnabled, onAction: onAction)
                .fixedSize()
                .layoutPriority(1)
                .padding(.trailing, s.statusTrailing)
        }
        .frame(height: s.accountRow)
        .background {
            if let wash = selection.wash {
                Rectangle().fill(wash.style)
            }
        }
        .overlay(alignment: .leading) {
            if let rule = selection.rule {
                QuireSettingsMarginRule(color: rule)
            }
        }
        .overlay {
            if showsFocusRing {
                QuireFocusRingView(shape: .roundedRectangle(cornerRadius: s.groupRadius), gap: 0,
                                   insetBy: QuireAccountRow.focusRingInset)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The group draws its focus ring around the selected row, inset 2 pt (spec §5.40).
    static let focusRingInset: CGFloat = Quire.Space.s1

    @ViewBuilder
    private var addressLine: some View {
        if let replacement = content.status.addressReplacement {
            HStack(spacing: Quire.Space.s2) {
                QuireSymbolImage(name: Quire.Icon.signIn, size: .custom(Quire.Layout.Settings.statusGlyph))
                Text(replacement).quireLine(.snippet)
            }
            .foregroundStyle(.qDanger)
        } else {
            Text(content.address)
                .quireLine(.snippet)
                .truncationMode(.tail)
                .foregroundStyle(.qInk2)
        }
    }

    func focusRing(_ shows: Bool) -> QuireAccountRow {
        var copy = self
        copy.showsFocusRing = shows
        return copy
    }
}

/// The 3 pt margin rule, full row height, flush with the leading edge; its trailing corners round by 2 pt
/// (`border.marginRule.radius`), its leading ones stay square.
struct QuireSettingsMarginRule: View {
    let color: QuireColorToken

    var body: some View {
        let r = Quire.Border.MarginRule.radius
        UnevenRoundedRectangle(topLeadingRadius: r[0], bottomLeadingRadius: r[3], bottomTrailingRadius: r[2],
                               topTrailingRadius: r[1], style: .circular)
            .fill(color.style)
            .frame(width: Quire.Border.MarginRule.width)
    }
}

/// A provider tag (spec §5.28): 16 pt, padding 0 5, radius 3, 1 pt `ruleStrong` inset, `tag` `ink2`.
struct QuireSettingsTag: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        let t = Quire.Layout.Tag.self
        Text(text)
            .quireFont(.tag)
            .lineLimit(1)
            .foregroundStyle(.qInk2)
            .padding(.horizontal, t.padX)
            .frame(height: t.height)
            .background {
                QuireFace(shape: RoundedRectangle(cornerRadius: t.radius, style: .circular), fill: .clear, edge: .strong)
            }
    }
}

/// The status block: mark, words and bar, then the action button 8 pt after them.
struct QuireAccountStatusView: View {
    let status: QuireAccountStatus
    let isActionEnabled: Bool
    let onAction: (() -> Void)?

    var body: some View {
        let s = Quire.Layout.Settings.self
        HStack(spacing: s.statusButtonGap) {
            if status.mark != .none || status.words != nil {
                HStack(spacing: s.statusGlyphGap) {
                    switch status.mark {
                    case .none:
                        EmptyView()
                    case .glyph(let name, let color):
                        QuireSymbolImage(name: name, size: .custom(s.statusGlyph))
                            .foregroundStyle(color.style)
                    case .spinner:
                        QuireSpinner(.small)
                    }
                    if let words = status.words {
                        Text(words)
                            .quireLine(.snippet)
                            .foregroundStyle(status.wordsColor.style)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let progress = status.progress {
                        // 4 pt under the words without moving them: the block stays centred on its words.
                        QuireDeterminateBar(progress: progress)
                            .frame(width: s.statusBarWidth)
                            .offset(y: s.statusBarGap + Quire.Layout.Progress.barHeight)
                    }
                }
                .help(status.tooltip ?? "")
                .accessibilityElement(children: .combine)
            }
            if let title = status.actionTitle {
                Button(title) { onAction?() }
                    .buttonStyle(.quire(.secondary, size: .small))
                    .disabled(!isActionEnabled || onAction == nil)
            }
        }
    }
}

/// The determinate bar (spec §5.37): 4 pt, radius 2, track `fill`, fill `accent`; it jumps forward without
/// easing, never backwards.
struct QuireDeterminateBar: View {
    let progress: Double

    var body: some View {
        let p = Quire.Layout.Progress.self
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule(style: .circular).fill(.qFill)
                Capsule(style: .circular).fill(.qAccent)
                    .frame(width: geometry.size.width * min(1, max(0, progress)))
            }
        }
        .frame(height: p.barHeight)
        .clipShape(RoundedRectangle(cornerRadius: p.barRadius, style: .circular))
        .transaction { $0.animation = nil }
        .accessibilityHidden(true)
    }
}
