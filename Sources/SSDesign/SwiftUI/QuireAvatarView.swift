import AppKit
import SwiftUI

/// A Quire face, drawn natively from the tokens (spec §4.3, §5.29): a sender's monogram on its avatar tint, an
/// account's domain monogram on its account face, or the pending face of an account still signing in.
///
/// - Sender avatars: the tint chosen by the address hash (FNV-1a, `Quire.avatarTint(forAddress:)`), initials in
///   New York Semibold at 0.42 × the diameter (never under 10 pt) in the tint's ink. Sizes 24 / 30 / 36.
/// - Account faces: the account ink at `rail.faceAlpha` over `sheet`, the monogram in `ink` at 14 / 12 pt on a
///   30 pt face and 11 / 10 pt on a 24 pt face (one / two letters), always with the account ring.
/// - Under the SF Pro font every monogram is `monogramSans` (spec §4.4, §5.29). The view tracks the setting
///   itself and redraws when it changes, so a Settings window left open follows a switch at once.
/// - The account ring: 2 pt in the account ink outside a 2 pt gap. The gap is left undrawn, so the surface the
///   face sits on (a row's fill, a selection wash) shows through it, as spec §5.7 asks of row avatars.
///
/// The view's layout size is the face's diameter; the ring is drawn outside it and does not move layout, so a
/// face placed at x = 16 has its ring's outer edge at x = 12 (spec §5.40). Initials come from the caller
/// (SSCore derives them); the view never parses names.
public struct QuireAvatarView: View {
    enum Face: Equatable {
        case sender(tint: Quire.AvatarTint)
        case account(slot: Int)
        case pending
    }

    let face: Face
    let monogram: String
    let diameter: CGFloat
    let ringSlot: Int?
    /// Read in `body`, so SwiftUI redraws the letters when the Font setting changes. The theme needs no such state:
    /// an account face's `sheet` and `ink` are shape styles, which follow the environment's theme (spec §4.16).
    @State private var typeface = QuireEnvironment.typeface

    /// A sender's avatar, tinted by `address`.
    /// - Parameter ringInk: the account ink slot to ring it with (unified views only); nil for no ring.
    public init(initials: String, address: String, diameter: CGFloat = Quire.Layout.Row.avatarFace, ringInk: Int? = nil) {
        self.init(initials: initials, tint: Quire.avatarTint(forAddress: address), diameter: diameter, ringInk: ringInk)
    }

    /// A sender's avatar in a given tint.
    public init(initials: String, tint: Quire.AvatarTint, diameter: CGFloat = Quire.Layout.Row.avatarFace, ringInk: Int? = nil) {
        face = .sender(tint: tint)
        monogram = initials
        self.diameter = diameter
        ringSlot = ringInk
    }

    /// An account's face: its monogram on its ink's face wash, ringed in the ink (the Settings account row, the
    /// rail tile, the quick-reply face).
    public init(accountMonogram: String, ink slot: Int, diameter: CGFloat = Quire.Layout.Settings.accountFace) {
        face = .account(slot: slot)
        monogram = accountMonogram
        self.diameter = diameter
        ringSlot = slot
    }

    /// The face of an account that is still signing in (spec §5.40, Adding): `fill`, a dashed 1 pt
    /// `ruleStrong` ring where the account ring will be, and a 16 pt `ink3` spinner.
    public static func pending(diameter: CGFloat = Quire.Layout.Settings.accountFace) -> QuireAvatarView {
        QuireAvatarView(pendingDiameter: diameter)
    }

    private init(pendingDiameter: CGFloat) {
        face = .pending
        monogram = ""
        diameter = pendingDiameter
        ringSlot = nil
    }

    public var body: some View {
        ZStack {
            switch face {
            case .sender(let tint):
                Circle().fill(Color(nsColor: tint.face))
                Text(monogram)
                    .font(Font(QuireAvatarView.monogramFont(face: face, monogram: monogram, diameter: diameter, typeface: typeface) as CTFont))
                    .foregroundStyle(Color(nsColor: tint.ink))
            case .account(let slot):
                Circle().fill(.qSheet)
                Circle().fill(Color.qAccount(slot).opacity(Quire.Layout.Rail.faceAlpha))
                Text(monogram)
                    .font(Font(QuireAvatarView.monogramFont(face: face, monogram: monogram, diameter: diameter, typeface: typeface) as CTFont))
                    .foregroundStyle(.qInk)
            case .pending:
                Circle().fill(.qFill)
                QuireSpinner(.medium, delay: 0)
            }
        }
        .lineLimit(1)
        .frame(width: diameter, height: diameter)
        .overlay { ring }
        .accessibilityHidden(face == .pending)
        .accessibilityLabel(Text(monogram))
        .onReceive(NotificationCenter.default.publisher(for: QuireEnvironment.didChangeNotification)) { _ in
            let now = QuireEnvironment.typeface
            if now != typeface { typeface = now }
        }
    }

    @ViewBuilder
    private var ring: some View {
        let r = Quire.Border.AccountRing.self
        // Inset strokes of a circle as large as the ring's outer edge, 4 pt outside the face.
        let outer = r.gap + r.width
        if let ringSlot {
            Circle()
                .strokeBorder(Color.qAccount(ringSlot), lineWidth: r.width)
                .padding(-outer)
                .allowsHitTesting(false)
        } else if face == .pending {
            // The dashed ring's outer edge meets where the account ring's will be.
            Circle()
                .strokeBorder(.qRuleStrong, style: StrokeStyle(lineWidth: Quire.Border.Strong.width,
                                                                   dash: [QuireAvatarView.pendingDash, QuireAvatarView.pendingDash]))
                .padding(-outer)
                .allowsHitTesting(false)
        }
    }

    /// The dash of the pending ring: the specimen's CSS `dashed` 1 px border, whose dashes are 3 × the width.
    static let pendingDash: CGFloat = 3 * Quire.Border.Strong.width

    /// The monogram's font in `typeface`. Sender initials follow the ratio rule of
    /// `QuireFont.monogramFont(diameter:)`; account monograms use the named sizes of the face they sit on.
    static func monogramFont(face: Face, monogram: String, diameter: CGFloat,
                             typeface: QuireFont.Typeface = QuireEnvironment.typeface) -> NSFont {
        guard case .account = face else { return QuireFont.monogramFont(diameter: diameter, typeface: typeface) }
        let size = accountMonogramSize(diameter: diameter, letters: monogram.count, typeface: typeface)
        return QuireFont.monogramFont(size: size, typeface: typeface)
    }

    /// 14 / 12 pt on a 30 pt face (`rail.monogram`, `rail.monogramTwoLetter`), 11 / 10 pt on a 24 pt face
    /// (`quickReply.faceMonogram*`); any other diameter scales the 30 pt pair. Under the SF Pro font each is
    /// scaled to the twin (`QuireFont.monogramSize(named:)`).
    static func accountMonogramSize(diameter: CGFloat, letters: Int, typeface: QuireFont.Typeface = QuireEnvironment.typeface) -> CGFloat {
        let twoLetters = letters > 1
        let named: CGFloat
        if diameter == Quire.Layout.QuickReply.face {
            named = twoLetters ? Quire.Layout.QuickReply.faceMonogramTwoLetter : Quire.Layout.QuickReply.faceMonogram
        } else {
            let base = twoLetters ? Quire.Layout.Rail.monogramTwoLetter : Quire.Layout.Rail.monogram
            named = diameter == Quire.Layout.Rail.face ? base : ((base * diameter / Quire.Layout.Rail.face) * 2).rounded() / 2
        }
        return QuireFont.monogramSize(named: named, typeface: typeface)
    }
}
