import SwiftUI

/// The picture on a theme tile (spec §5.40): the main window at 60 × 40, drawn in `theme` whatever the app's theme is,
/// so the tile shows what choosing it gives. Light or dark is the window's own mode, and Graphite and Increase Contrast
/// come from the root the tile sits under, as every Settings colour's do: a Graphite user sees the inkless window they
/// will get.
///
/// Left to right: the rail (`spine`); the list column (`paper`) with an unread pip in the ink and two `ink3` lines;
/// the desk (`canvas`) holding the reading sheet (`sheet`, hairline `rule`) with two `ink` lines and one line in the
/// ink. The edge is the current theme's, not the pictured one's: it is the existing "Secondary button edge vs desk"
/// pair on the Settings desk, which a pictured theme's `ruleStrong` would not be.
struct QuireThemeMiniature: View {
    let theme: QuireTheme

    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let s = Quire.Layout.Settings.self
        let shape = RoundedRectangle(cornerRadius: Quire.Radius.md, style: .circular)
        picture
            // Only the picture is in the pictured theme; the edge below reads the window's.
            .environment(\.quireTheme, theme)
            .frame(width: s.themeTile[0], height: s.themeTile[1])
            .clipShape(shape)
            .overlay { shape.strokeBorder(.qRuleStrong, lineWidth: Quire.Border.Strong.width) }
            .accessibilityHidden(true)
    }

    private var picture: some View {
        let s = Quire.Layout.Settings.self
        let width = s.themeTile[0], height = s.themeTile[1]
        let inset = s.themeTileInset, pip = s.themeTilePip
        let listX = s.themeTileSpine
        let listLineX = listX + inset / 2 + pip + inset / 2
        let listLineWidth = listX + s.themeTilePaper - inset / 2 - listLineX
        let deskX = listX + s.themeTilePaper
        let sheetX = deskX + inset
        let sheetWidth = width - sheetX - inset
        let textX = sheetX + inset
        let textWidth = sheetWidth - 2 * inset
        let firstText = inset + inset + s.themeTileLine / 2
        let hairline = QuireSettingsHairline.width(displayScale: displayScale, increasedContrast: contrast == .increased)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(.qCanvas)
            block(.qSpine, x: 0, y: 0, width: listX, height: height)
            block(.qPaper, x: listX, y: 0, width: s.themeTilePaper, height: height)
            Circle().fill(.qAccent)
                .frame(width: pip, height: pip)
                .offset(x: listX + inset / 2, y: inset)
            line(.qInk3, x: listLineX, centreY: inset + pip / 2, width: listLineWidth)
            line(.qInk3, x: listLineX, centreY: inset + pip / 2 + 2 * pip, width: listLineWidth * 0.75)
            // The sheet runs off the bottom edge, as a message longer than the pane does.
            RoundedRectangle(cornerRadius: Quire.Radius.xs, style: .circular)
                .fill(.qSheet)
                .overlay { RoundedRectangle(cornerRadius: Quire.Radius.xs, style: .circular).strokeBorder(.qRule, lineWidth: hairline) }
                .frame(width: sheetWidth, height: height)
                .offset(x: sheetX, y: inset)
            line(.qInk, x: textX, centreY: firstText, width: textWidth)
            line(.qInk, x: textX, centreY: firstText + pip, width: textWidth * 0.75)
            line(.qAccent, x: textX, centreY: firstText + 3 * pip, width: textWidth * 0.5)
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private func block(_ style: QuireColorStyle, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> some View {
        Rectangle().fill(style).frame(width: width, height: height).offset(x: x, y: y)
    }

    private func line(_ style: QuireColorStyle, x: CGFloat, centreY: CGFloat, width: CGFloat) -> some View {
        let s = Quire.Layout.Settings.self
        return Capsule(style: .circular).fill(style)
            .frame(width: width, height: s.themeTileLine)
            .offset(x: x, y: centreY - s.themeTileLine / 2)
    }
}
