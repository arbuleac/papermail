import AppKit
@testable import SSDesign

/// Resolves the token names used by `contrastPairs` to sRGB colours through the generated runtime, and
/// composites stacks exactly as `resolve_stack()` and `ratio()` in docs/design/source/build.py do.
enum TokenResolver {
    /// A dynamic colour as drawn in `mode`, in sRGB.
    static func rgba(_ color: NSColor, _ mode: QuireMode) -> RGBA {
        guard let c = mode.performAsCurrent({ color.usingColorSpace(.sRGB) }) else { preconditionFailure("\(color) has no sRGB form") }
        return RGBA(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent))
    }

    /// The runtime colour for a pair token: a colour token, `account:<Ink>`, `avatarInk:<Tint>` or
    /// `avatarFace:<Tint>`.
    static func color(_ token: String) -> NSColor {
        if token.hasPrefix("account:") {
            let name = String(token.dropFirst(8))
            guard let slot = Quire.accountInkNames.firstIndex(of: name) else { preconditionFailure("unknown ink \(name)") }
            return NSColor.qAccount(slot)
        }
        if token.hasPrefix("avatarInk:") {
            return avatarTint(String(token.dropFirst(10))).ink
        }
        if token.hasPrefix("avatarFace:") {
            return avatarTint(String(token.dropFirst(11))).face
        }
        guard let t = QuireColorToken(rawValue: token) else { preconditionFailure("unknown colour token \(token)") }
        return t.color
    }

    private static func avatarTint(_ name: String) -> Quire.AvatarTint {
        guard let i = Quire.avatarTintNames.firstIndex(of: name), let tint = Quire.AvatarTint(rawValue: i) else {
            preconditionFailure("unknown avatar tint \(name)")
        }
        return tint
    }

    static func resolve(_ token: String, _ mode: QuireMode) -> RGBA {
        rgba(color(token), mode)
    }

    /// `resolve_stack()`: an `accountFace:` base is the ink at `layout.rail.faceAlpha`, and an `eventFace:` base (an
    /// event in the day column and the week, §5.54) the ink at `layout.calendarPane.eventTintAlpha`, each quantised to a
    /// byte, as the python writes it into a hex, over `sheet`; every later item is composited over the result.
    static func resolveStack(_ stack: [String], _ mode: QuireMode) -> RGBA {
        let base = stack[0]
        var cur: RGBA
        if base.hasPrefix("accountFace:") {
            var ink = resolve("account:" + base.dropFirst(12), mode)
            ink.a = (Double(Quire.Layout.Rail.faceAlpha) * 255).rounded(.toNearestOrEven) / 255
            cur = ColorLib.over(ink, resolve("sheet", mode))
        } else if base.hasPrefix("eventFace:") {
            var ink = resolve("account:" + base.dropFirst(10), mode)
            ink.a = (Double(Quire.Layout.CalendarPane.eventTintAlpha) * 255).rounded(.toNearestOrEven) / 255
            cur = ColorLib.over(ink, resolve("sheet", mode))
        } else {
            cur = resolve(base, mode)
        }
        for t in stack.dropFirst() { cur = ColorLib.over(resolve(t, mode), cur) }
        return cur
    }

    /// `ratio()`: a translucent foreground is composited over its background first.
    static func ratio(fg: [String], bg: [String], _ mode: QuireMode) -> Double {
        let b = resolveStack(bg, mode)
        var f = fg.count > 1 ? resolveStack(fg, mode) : resolve(fg[0], mode)
        if f.a < 1 { f = ColorLib.over(f, b) }
        return ColorLib.contrast(f, b)
    }
}
