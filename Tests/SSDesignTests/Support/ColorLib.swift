import Foundation

// A line-for-line port of docs/design/source/colorlib.py: WCAG contrast, sRGB compositing, Machado 2009 CVD,
// CIELAB and CIEDE2000. Doubles throughout, the same operation order, the same constants, so ratios and
// distances match the python build that tuned the tokens. ColorLibTests cross-checks it against python.

/// An sRGB colour with components in 0…1 (gamma encoded), alpha last.
struct RGBA: Equatable, CustomStringConvertible {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    var description: String { ColorLib.rgb2hex(self) + String(format: "@%.3f", a) }
}

enum CVDKind: String, CaseIterable {
    case normal, protan, deutan, tritan
}

struct Lab: Equatable {
    var L: Double
    var a: Double
    var b: Double
}

enum ColorLib {
    static func hex2rgba(_ hex: String) -> RGBA {
        var h = hex
        if h.hasPrefix("#") { h.removeFirst() }
        func byte(_ k: Int) -> Double {
            let start = h.index(h.startIndex, offsetBy: k * 2)
            return Double(UInt8(h[start..<h.index(start, offsetBy: 2)], radix: 16)!) / 255
        }
        switch h.count {
        case 6: return RGBA(r: byte(0), g: byte(1), b: byte(2), a: 1)
        case 8: return RGBA(r: byte(0), g: byte(1), b: byte(2), a: byte(3))
        default: preconditionFailure("bad colour \(hex)")
        }
    }

    static func rgb2hex(_ c: RGBA) -> String {
        func byte(_ x: Double) -> Int { max(0, min(255, Int((x * 255).rounded(.toNearestOrEven)))) }
        return String(format: "#%02X%02X%02X", byte(c.r), byte(c.g), byte(c.b))
    }

    /// fg (sRGB encoded, with alpha) over an opaque bg, in gamma space as AppKit and CSS composite.
    static func over(_ fg: RGBA, _ bg: RGBA) -> RGBA {
        let a = fg.a
        return RGBA(r: fg.r * a + bg.r * (1 - a), g: fg.g * a + bg.g * (1 - a), b: fg.b * a + bg.b * (1 - a), a: 1)
    }

    /// First item is the opaque base; later items are composited over it in order.
    static func stack(_ colors: [RGBA]) -> RGBA {
        var c = colors[0]
        precondition(c.a >= 1, "base must be opaque")
        for next in colors.dropFirst() { c = over(next, c) }
        return c
    }

    static func lin(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func delin(_ c: Double) -> Double {
        let c = max(0.0, min(1.0, c))
        return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    static func luminance(_ c: RGBA) -> Double {
        0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    static func contrast(_ a: RGBA, _ b: RGBA) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static let machado: [CVDKind: [[Double]]] = [
        .protan: [[0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216], [-0.003882, -0.048116, 1.051998]],
        .deutan: [[0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413], [-0.011820, 0.042940, 0.968881]],
        .tritan: [[1.255528, -0.076749, -0.178779], [-0.078411, 0.930809, 0.147602], [0.004733, 0.691367, 0.303900]],
    ]

    static func simulate(_ c: RGBA, _ kind: CVDKind) -> RGBA {
        guard kind != .normal, let m = machado[kind] else { return RGBA(r: c.r, g: c.g, b: c.b, a: 1) }
        let l = [lin(c.r), lin(c.g), lin(c.b)]
        var out = [Double](repeating: 0, count: 3)
        for i in 0..<3 {
            // Python's sum() starts at 0 and adds left to right; keep that order for identical rounding.
            var s = 0.0
            for j in 0..<3 { s += m[i][j] * l[j] }
            out[i] = max(0.0, min(1.0, s))
        }
        return RGBA(r: delin(out[0]), g: delin(out[1]), b: delin(out[2]), a: 1)
    }

    static func rgb2lab(_ c: RGBA) -> Lab {
        let r = lin(c.r), g = lin(c.g), b = lin(c.b)
        let X = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
        let Y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let Z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b
        func f(_ t: Double) -> Double {
            t > 216.0 / 24389.0 ? pow(t, 1.0 / 3.0) : (24389.0 / 27.0 * t + 16) / 116
        }
        let fx = f(X / 0.95047), fy = f(Y / 1.0), fz = f(Z / 1.08883)
        return Lab(L: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    private static func degrees(_ r: Double) -> Double { r * 180 / .pi }
    private static func radians(_ d: Double) -> Double { d * .pi / 180 }

    /// Python's `%` on floats: the result takes the divisor's sign.
    private static func pyMod(_ x: Double, _ m: Double) -> Double {
        let r = fmod(x, m)
        return (r != 0 && (r < 0) != (m < 0)) ? r + m : r
    }

    static func de2000(_ lab1: Lab, _ lab2: Lab) -> Double {
        let (L1, a1, b1) = (lab1.L, lab1.a, lab1.b)
        let (L2, a2, b2) = (lab2.L, lab2.a, lab2.b)
        let C1 = hypot(a1, b1), C2 = hypot(a2, b2)
        let Cb = (C1 + C2) / 2
        let G = 0.5 * (1 - sqrt(pow(Cb, 7) / (pow(Cb, 7) + pow(25, 7))))
        let a1p = (1 + G) * a1, a2p = (1 + G) * a2
        let C1p = hypot(a1p, b1), C2p = hypot(a2p, b2)
        let h1p = C1p != 0 ? pyMod(degrees(atan2(b1, a1p)), 360) : 0
        let h2p = C2p != 0 ? pyMod(degrees(atan2(b2, a2p)), 360) : 0
        let dLp = L2 - L1
        let dCp = C2p - C1p
        var dhp: Double
        if C1p * C2p == 0 {
            dhp = 0
        } else {
            dhp = h2p - h1p
            if dhp > 180 { dhp -= 360 } else if dhp < -180 { dhp += 360 }
        }
        let dHp = 2 * sqrt(C1p * C2p) * sin(radians(dhp / 2))
        let Lbp = (L1 + L2) / 2
        let Cbp = (C1p + C2p) / 2
        let hbp: Double
        if C1p * C2p == 0 {
            hbp = h1p + h2p
        } else if abs(h1p - h2p) <= 180 {
            hbp = (h1p + h2p) / 2
        } else if h1p + h2p < 360 {
            hbp = (h1p + h2p + 360) / 2
        } else {
            hbp = (h1p + h2p - 360) / 2
        }
        let T = 1 - 0.17 * cos(radians(hbp - 30)) + 0.24 * cos(radians(2 * hbp))
            + 0.32 * cos(radians(3 * hbp + 6)) - 0.20 * cos(radians(4 * hbp - 63))
        let dth = 30 * exp(-pow((hbp - 275) / 25, 2))
        let Rc = 2 * sqrt(pow(Cbp, 7) / (pow(Cbp, 7) + pow(25, 7)))
        let Sl = 1 + 0.015 * pow(Lbp - 50, 2) / sqrt(20 + pow(Lbp - 50, 2))
        let Sc = 1 + 0.045 * Cbp
        let Sh = 1 + 0.015 * Cbp * T
        let Rt = -sin(radians(2 * dth)) * Rc
        return sqrt(pow(dLp / Sl, 2) + pow(dCp / Sc, 2) + pow(dHp / Sh, 2) + Rt * (dCp / Sc) * (dHp / Sh))
    }

    static func cvdLab(_ c: RGBA) -> [CVDKind: Lab] {
        var out: [CVDKind: Lab] = [:]
        for k in CVDKind.allCases { out[k] = rgb2lab(simulate(c, k)) }
        return out
    }

    /// dE2000 between two colours for normal vision and each dichromacy.
    static func deAll(_ c1: RGBA, _ c2: RGBA) -> [CVDKind: Double] {
        var out: [CVDKind: Double] = [:]
        for k in CVDKind.allCases { out[k] = de2000(rgb2lab(simulate(c1, k)), rgb2lab(simulate(c2, k))) }
        return out
    }
}
