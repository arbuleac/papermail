import CoreGraphics
import Foundation

/// A small SVG path-data parser for the custom glyphs (spec §4.11): M L H V C S Q T A Z, absolute and
/// relative, with implicit repeats (`M2 7 8 10` continues as a line) and the compact number forms SVG
/// allows (`1-1`, `.5.5`, packed arc flags). The path is built in the data's own units, y down.
public enum QuireSVGPath {
    public static func parse(_ data: String) throws -> CGPath {
        var parser = Parser(Array(data.utf8))
        return try parser.run()
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0
        let path = CGMutablePath()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var hasCurrentPoint = false
        /// After Z the next drawing command starts a new subpath at the closed one's start.
        var needsMove = false
        /// The previous command's second control point, for S (cubic) and T (quadratic) reflection.
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func run() throws -> CGPath {
            skipSeparators()
            while i < bytes.count {
                let c = bytes[i]
                guard isCommand(c) else { throw ParseError(message: "command expected", offset: i) }
                i += 1
                try command(c)
                skipSeparators()
            }
            return path.copy() ?? path
        }

        mutating func command(_ c: UInt8) throws {
            let relative = c >= UInt8(ascii: "a")
            let upper = relative ? c - 32 : c
            if upper == UInt8(ascii: "Z") {
                if hasCurrentPoint { path.closeSubpath() }
                current = subpathStart
                needsMove = true
                lastCubicControl = nil
                lastQuadControl = nil
                return
            }
            if upper != UInt8(ascii: "M"), !hasCurrentPoint {
                throw ParseError(message: "path must start with M", offset: i - 1)
            }
            var first = true
            repeat {
                // Repeated coordinates after M are implicit line-tos (relative after m).
                let effective = (upper == UInt8(ascii: "M") && !first) ? UInt8(ascii: "L") : upper
                try segment(effective, relative: relative)
                first = false
                skipSeparators()
            } while i < bytes.count && startsNumber(bytes[i])
        }

        mutating func segment(_ upper: UInt8, relative: Bool) throws {
            let origin = relative ? current : .zero
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x, y: origin.y + y) }
            if needsMove, upper != UInt8(ascii: "M") {
                path.move(to: current)
                needsMove = false
            }
            var cubic: CGPoint?
            var quad: CGPoint?
            switch upper {
            case UInt8(ascii: "M"):
                let p = pt(try number(), try number())
                path.move(to: p)
                current = p
                subpathStart = p
                hasCurrentPoint = true
                needsMove = false
            case UInt8(ascii: "L"):
                let p = pt(try number(), try number())
                path.addLine(to: p)
                current = p
            case UInt8(ascii: "H"):
                let x = try number()
                let p = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: p)
                current = p
            case UInt8(ascii: "V"):
                let y = try number()
                let p = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: p)
                current = p
            case UInt8(ascii: "C"):
                let c1 = pt(try number(), try number())
                let c2 = pt(try number(), try number())
                let p = pt(try number(), try number())
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
                cubic = c2
            case UInt8(ascii: "S"):
                let c1 = reflect(lastCubicControl)
                let c2 = pt(try number(), try number())
                let p = pt(try number(), try number())
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
                cubic = c2
            case UInt8(ascii: "Q"):
                let c = pt(try number(), try number())
                let p = pt(try number(), try number())
                path.addQuadCurve(to: p, control: c)
                current = p
                quad = c
            case UInt8(ascii: "T"):
                let c = reflect(lastQuadControl)
                let p = pt(try number(), try number())
                path.addQuadCurve(to: p, control: c)
                current = p
                quad = c
            case UInt8(ascii: "A"):
                let rx = try number()
                let ry = try number()
                let rotation = try number()
                let large = try flag()
                let sweep = try flag()
                let p = pt(try number(), try number())
                QuireSVGPath.addArc(to: path, from: current, rx: rx, ry: ry, rotationDegrees: rotation, largeArc: large, sweep: sweep, end: p)
                current = p
            default:
                throw ParseError(message: "unsupported command", offset: i - 1)
            }
            lastCubicControl = cubic
            lastQuadControl = quad
        }

        /// The reflection of the previous control point about the current point, or the current point when
        /// the previous command was not of the same family (SVG 1.1 §8.3.6).
        func reflect(_ control: CGPoint?) -> CGPoint {
            guard let control else { return current }
            return CGPoint(x: 2 * current.x - control.x, y: 2 * current.y - control.y)
        }

        func isCommand(_ c: UInt8) -> Bool { "MmLlHhVvCcSsQqTtAaZz".utf8.contains(c) }

        func startsNumber(_ c: UInt8) -> Bool { "+-.0123456789".utf8.contains(c) }

        mutating func skipSeparators() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D, 0x0C, UInt8(ascii: ",")].contains(bytes[i]) { i += 1 }
        }

        mutating func number() throws -> CGFloat {
            skipSeparators()
            let start = i
            if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
            var digits = 0
            while i < bytes.count, isDigit(bytes[i]) { i += 1; digits += 1 }
            if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
                i += 1
                while i < bytes.count, isDigit(bytes[i]) { i += 1; digits += 1 }
            }
            guard digits > 0 else { throw ParseError(message: "number expected", offset: start) }
            if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
                var j = i + 1
                if j < bytes.count, bytes[j] == UInt8(ascii: "+") || bytes[j] == UInt8(ascii: "-") { j += 1 }
                if j < bytes.count, isDigit(bytes[j]) {
                    i = j
                    while i < bytes.count, isDigit(bytes[i]) { i += 1 }
                }
            }
            guard let value = Double(String(decoding: bytes[start..<i], as: UTF8.self)) else {
                throw ParseError(message: "bad number", offset: start)
            }
            return CGFloat(value)
        }

        /// Arc flags are a single 0 or 1 and need no separator after them (`a1 1 0 011 1`).
        mutating func flag() throws -> Bool {
            skipSeparators()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "0") || bytes[i] == UInt8(ascii: "1") else {
                throw ParseError(message: "arc flag expected", offset: i)
            }
            defer { i += 1 }
            return bytes[i] == UInt8(ascii: "1")
        }

        func isDigit(_ c: UInt8) -> Bool { c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") }
    }

    /// An SVG elliptical arc as cubic Béziers: endpoint to centre parameterisation (SVG 1.1 §F.6.5), radii
    /// scaled up when too small (§F.6.6), then one cubic per quarter turn or less.
    static func addArc(to path: CGMutablePath, from start: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat, rotationDegrees: CGFloat,
                       largeArc: Bool, sweep: Bool, end: CGPoint) {
        if start == end { return }
        var rx = abs(rxIn)
        var ry = abs(ryIn)
        if rx == 0 || ry == 0 {
            path.addLine(to: end)
            return
        }
        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx2 = (start.x - end.x) / 2
        let dy2 = (start.y - end.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let coefficient = (largeArc != sweep ? 1 : -1) * (max(0, num / den)).squareRoot()
        let cxp = coefficient * rx * y1p / ry
        let cyp = coefficient * -ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let ux = (x1p - cxp) / rx
        let uy = (y1p - cyp) / ry
        let vx = (-x1p - cxp) / rx
        let vy = (-y1p - cyp) / ry
        let theta1 = angle(1, 0, ux, uy)
        var delta = angle(ux, uy, vx, vy)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / CGFloat(segments)
        let t = 4 / 3 * tan(step / 4)
        func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cosPhi * x - ry * sinPhi * y, y: cy + rx * sinPhi * x + ry * cosPhi * y)
        }
        for s in 0..<segments {
            let a = theta1 + CGFloat(s) * step
            let b = a + step
            let c1 = map(cos(a) - t * sin(a), sin(a) + t * cos(a))
            let c2 = map(cos(b) + t * sin(b), sin(b) - t * cos(b))
            // The last segment lands exactly on the endpoint so rounding never opens a gap.
            let p = s == segments - 1 ? end : map(cos(b), sin(b))
            path.addCurve(to: p, control1: c1, control2: c2)
        }
    }
}
