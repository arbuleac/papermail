// Generates the Quire design runtime, the reader CSS head, the generated design tests and the accent
// colour asset from docs/design/tokens.json (spec §3.5, §8.1).
//
// Usage: swift scripts/tools/quire-tokens.swift [--check] [--root <repo>]
//   --check  writes nothing; exits 1 and lists every output that is missing or out of date.
//
// Plain Foundation, no packages. The output is a pure function of tokens.json: keys are emitted in the
// order tokens.json lists them (the JSON is read with an order-preserving parser, because
// JSONSerialization forgets key order) and numbers are formatted canonically, so two runs on the same
// input produce identical bytes.
import Foundation

// MARK: - Failure

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("quire-tokens: \(message)\n".utf8))
    exit(2)
}

/// Lets `value ?? fail("…")` read as one expression: Swift does not treat Never as a bottom type there.
func fail<T>(_ message: String) -> T { fail(message) as Never }

// MARK: - Order-preserving JSON

indirect enum JSON {
    case object([(String, JSON)])
    case array([JSON])
    case string(String)
    /// The literal text is kept so integer-looking values can stay integers where the type matters.
    case number(Double, String)
    case bool(Bool)
    case null

    subscript(key: String) -> JSON? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.first(where: { $0.0 == key })?.1
    }
    var object: [(String, JSON)]? { if case .object(let o) = self { return o }; return nil }
    var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var double: Double? { if case .number(let d, _) = self { return d }; return nil }
    var isIntegerLiteral: Bool {
        if case .number(_, let raw) = self { return !raw.contains(".") && !raw.contains("e") && !raw.contains("E") }
        return false
    }

    func require(_ key: String, _ path: String) -> JSON {
        guard let v = self[key] else { fail("tokens.json: missing \(path).\(key)") }
        return v
    }
}

struct JSONParser {
    let bytes: [UInt8]
    var i = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    mutating func parse() -> JSON {
        let v = value()
        skipSpace()
        if i != bytes.count { fail("tokens.json: trailing characters at byte \(i)") }
        return v
    }

    mutating func skipSpace() {
        while i < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[i]) { i += 1 }
    }

    mutating func value() -> JSON {
        skipSpace()
        guard i < bytes.count else { fail("tokens.json: unexpected end") }
        switch bytes[i] {
        case UInt8(ascii: "{"):
            i += 1
            var pairs: [(String, JSON)] = []
            skipSpace()
            if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
            while true {
                skipSpace()
                guard case .string(let key) = value() else { fail("tokens.json: object key expected at byte \(i)") }
                skipSpace()
                expect(":")
                let v = value()
                if pairs.contains(where: { $0.0 == key }) { fail("tokens.json: duplicate key \(key)") }
                pairs.append((key, v))
                skipSpace()
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                expect("}")
                return .object(pairs)
            }
        case UInt8(ascii: "["):
            i += 1
            var items: [JSON] = []
            skipSpace()
            if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                items.append(value())
                skipSpace()
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                expect("]")
                return .array(items)
            }
        case UInt8(ascii: "\""):
            return .string(stringLiteral())
        case UInt8(ascii: "t"):
            word("true"); return .bool(true)
        case UInt8(ascii: "f"):
            word("false"); return .bool(false)
        case UInt8(ascii: "n"):
            word("null"); return .null
        default:
            let start = i
            while i < bytes.count, "+-0123456789.eE".utf8.contains(bytes[i]) { i += 1 }
            let raw = String(decoding: bytes[start..<i], as: UTF8.self)
            guard let d = Double(raw) else { fail("tokens.json: bad number \(raw)") }
            return .number(d, raw)
        }
    }

    mutating func expect(_ c: Character) {
        guard i < bytes.count, bytes[i] == c.asciiValue! else { fail("tokens.json: expected \(c) at byte \(i)") }
        i += 1
    }

    mutating func word(_ w: String) {
        for c in w.utf8 {
            guard i < bytes.count, bytes[i] == c else { fail("tokens.json: expected \(w)") }
            i += 1
        }
    }

    mutating func stringLiteral() -> String {
        i += 1
        var out = [UInt8]()
        var pendingHigh: UInt32?
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "\"") { i += 1; return String(decoding: out, as: UTF8.self) }
            if b == UInt8(ascii: "\\") {
                i += 1
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "u"):
                    let hex = String(decoding: bytes[i..<(i + 4)], as: UTF8.self)
                    i += 4
                    guard let code = UInt32(hex, radix: 16) else { fail("tokens.json: bad \\u escape") }
                    if (0xD800...0xDBFF).contains(code) { pendingHigh = code; continue }
                    var scalarValue = code
                    if let high = pendingHigh, (0xDC00...0xDFFF).contains(code) {
                        scalarValue = 0x10000 + ((high - 0xD800) << 10) + (code - 0xDC00)
                        pendingHigh = nil
                    }
                    guard let scalar = Unicode.Scalar(scalarValue) else { fail("tokens.json: bad scalar") }
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                default: out.append(e)
                }
                continue
            }
            out.append(b)
            i += 1
        }
        fail("tokens.json: unterminated string")
    }
}

// MARK: - Formatting

let swiftKeywords: Set<String> = [
    "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout",
    "internal", "let", "open", "operator", "private", "precedencegroup", "protocol", "public", "rethrows",
    "static", "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue", "default", "defer",
    "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw", "switch", "where",
    "while", "Any", "as", "await", "false", "is", "nil", "self", "Self", "super", "throws", "true", "try",
]
/// Nested type names that would shadow the types the generated declarations themselves use.
let reservedTypeNames: Set<String> = ["String", "Bool", "Int", "Double", "CGFloat", "Array", "Optional", "Type", "Protocol", "Self", "Any", "NSColor", "Color"]

/// Maps a tokens.json key to a Swift identifier deterministically: runs of characters that are not
/// letters or digits become word breaks (`ss.quire` → `ssQuire`), a leading digit gains `_`.
func identifierWords(_ key: String) -> [String] {
    var words: [String] = []
    var current = ""
    for ch in key {
        if ch.isLetter || ch.isNumber, ch.isASCII { current.append(ch) } else if !current.isEmpty { words.append(current); current = "" }
    }
    if !current.isEmpty { words.append(current) }
    if words.isEmpty { fail("cannot map key '\(key)' to an identifier") }
    return words
}

func upperFirst(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
func lowerFirst(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }

func memberName(_ key: String) -> String {
    let w = identifierWords(key)
    var s = w[0] + w.dropFirst().map(upperFirst).joined()
    if s.first!.isNumber { s = "_" + s }
    return swiftKeywords.contains(s) ? "`\(s)`" : s
}

func typeName(_ key: String) -> String {
    var s = identifierWords(key).map(upperFirst).joined()
    if s.first!.isNumber { s = "_" + s }
    if reservedTypeNames.contains(s) || swiftKeywords.contains(s) { s += "_" }
    return s
}

/// Canonical Swift literal for a number: integers without a fraction, everything else in Swift's
/// shortest round-tripping form.
func swiftNumber(_ d: Double) -> String {
    if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
    return "\(d)"
}

func swiftString(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 || scalar.value == 0x7F { out += "\\u{\(String(scalar.value, radix: 16))}" } else { out.unicodeScalars.append(scalar) }
        }
    }
    return out + "\""
}

/// Python's `'%g' % v`, which is C's `%g`: the CSS in the specimen was written with it.
func pyG(_ d: Double) -> String { String(format: "%g", d) }

func docComment(_ text: String, indent: String) -> String {
    "\(indent)/// \(text.replacingOccurrences(of: "\n", with: " "))\n"
}

let header = "// generated by scripts/tools/quire-tokens.swift, do not edit\n// Source: docs/design/tokens.json. Regenerate with `swift scripts/tools/quire-tokens.swift`.\n"

// MARK: - Colour math (the subset of colorlib.py the generator needs)

struct RGBA { var r, g, b, a: Double }

func hex2rgba(_ hex: String) -> RGBA {
    var h = hex
    if h.hasPrefix("#") { h.removeFirst() }
    func byte(_ k: Int) -> Double {
        let start = h.index(h.startIndex, offsetBy: k * 2)
        guard let v = UInt8(h[start..<h.index(start, offsetBy: 2)], radix: 16) else { fail("bad colour \(hex)") }
        return Double(v) / 255
    }
    switch h.count {
    case 6: return RGBA(r: byte(0), g: byte(1), b: byte(2), a: 1)
    case 8: return RGBA(r: byte(0), g: byte(1), b: byte(2), a: byte(3))
    default: fail("bad colour \(hex)")
    }
}

/// `over()` from colorlib.py: fg composited over an opaque bg in gamma space, as AppKit and CSS do.
func over(_ fg: RGBA, _ bg: RGBA) -> RGBA {
    let a = fg.a
    return RGBA(r: fg.r * a + bg.r * (1 - a), g: fg.g * a + bg.g * (1 - a), b: fg.b * a + bg.b * (1 - a), a: 1)
}

/// Python's `round()` (half to even on the exact binary value), clamped like `rgb2hex()`.
func byte255(_ c: Double) -> Int { max(0, min(255, Int((c * 255).rounded(.toNearestOrEven)))) }

func rgb2hex(_ c: RGBA) -> String { String(format: "#%02X%02X%02X", byte255(c.r), byte255(c.g), byte255(c.b)) }

func rgbaLiteral(_ hex: String) -> String {
    var h = hex
    if h.hasPrefix("#") { h.removeFirst() }
    if h.count == 6 { h += "FF" }
    guard h.count == 8, UInt32(h, radix: 16) != nil else { fail("bad colour \(hex)") }
    return "0x" + h.uppercased()
}

// MARK: - Model

let modes = ["light", "dark", "lightHC", "darkHC"]

struct ColorToken {
    let name: String
    let values: [String: String]
    let group: String
    let use: String
}

struct Account {
    let name: String
    let values: [String: String]
}

struct AvatarTint {
    let name: String
    let face: [String: String]
    let ink: [String: String]
}

/// One family's file ink (spec §5.57): the band of its file marks, fixed across themes like the account inks.
struct FileInk {
    let name: String
    let values: [String: String]
    let use: String
}

/// One theme of `themes` (spec §4.16): its full colour table and Graphite values, its link flags and its page colours.
struct Theme {
    let id: String
    let name: String
    let caption: String
    let inkless: Bool
    let colors: [String: [String: String]]
    let graphite: [String: [String: String]]
    let links: [String: Bool]
    let quoteLinks: [String: Bool]
    let focusOnPage: [String: String]
    let sheetIsPage: [String: Bool]
    let declaredDeeper: [String: [String]]
}

struct Pair {
    let use: String
    let fg: [String]
    let bg: [String]
    let need: Double
    let needIC: Double?
}

final class Tokens {
    let root: JSON
    let colors: [ColorToken]
    let colorByName: [String: ColorToken]
    let accounts: [Account]
    let avatars: [AvatarTint]
    let fileInks: [FileInk]
    /// The label on every file ink (spec §5.57).
    let fileLabel: [String: String]
    let graphite: [(String, [String])]
    let themes: [Theme]
    /// `linkOnPage`: a link its sender left uncoloured, outside Graphite, in every theme (spec §5.14).
    let linkOnPage: [String: String]

    init(_ root: JSON) {
        self.root = root
        guard let colorObject = root.require("color", "").object else { fail("color must be an object") }
        colors = colorObject.map { name, v in
            var values: [String: String] = [:]
            for m in modes {
                guard let s = v.require(m, "color.\(name)").string else { fail("color.\(name).\(m) must be a string") }
                values[m] = s
            }
            return ColorToken(name: name, values: values, group: v["group"]?.string ?? "", use: v["use"]?.string ?? "")
        }
        colorByName = Dictionary(uniqueKeysWithValues: colors.map { ($0.name, $0) })
        accounts = (root.require("accountPalette", "").array ?? []).map { a in
            var values: [String: String] = [:]
            for m in modes { values[m] = a.require(m, "accountPalette").string ?? fail("accountPalette.\(m)") }
            return Account(name: a.require("name", "accountPalette").string ?? fail("accountPalette.name"), values: values)
        }
        avatars = (root.require("avatarPalette", "").array ?? []).map { a in
            var face: [String: String] = [:]
            var ink: [String: String] = [:]
            for m in modes {
                let mv = a.require(m, "avatarPalette")
                face[m] = mv.require("face", "avatarPalette.\(m)").string ?? fail("avatarPalette face")
                ink[m] = mv.require("ink", "avatarPalette.\(m)").string ?? fail("avatarPalette ink")
            }
            return AvatarTint(name: a.require("name", "avatarPalette").string ?? fail("avatarPalette.name"), face: face, ink: ink)
        }
        fileInks = (root.require("filePalette", "").array ?? []).map { f in
            var values: [String: String] = [:]
            for m in modes { values[m] = f.require(m, "filePalette").string ?? fail("filePalette.\(m)") }
            return FileInk(name: f.require("name", "filePalette").string ?? fail("filePalette.name"), values: values,
                           use: f["use"]?.string ?? "")
        }
        if fileInks.isEmpty { fail("filePalette must list the file inks") }
        if Set(fileInks.map { $0.name.lowercased() }).count != fileInks.count { fail("filePalette names must be unique") }
        let label = root.require("fileLabel", "")
        var labelValues: [String: String] = [:]
        for m in modes { labelValues[m] = label.require(m, "fileLabel").string ?? fail("fileLabel.\(m)") }
        fileLabel = labelValues
        graphite = (root.require("graphite", "").object ?? []).map { key, v in
            let value = v.require("value", "graphite.\(key)")
            if let s = value.string { return (key, [s]) }
            if let a = value.array { return (key, a.map { $0.string ?? fail("graphite.\(key) stack must hold token names") }) }
            fail("graphite.\(key).value must be a token or a stack")
        }
        for (key, stack) in graphite {
            if colorByName[key] == nil { fail("graphite substitutes unknown token \(key)") }
            for t in stack where colorByName[t] == nil { fail("graphite.\(key) refers to unknown token \(t)") }
        }
        let colorNames = colors.map(\.name)
        let graphiteNames = graphite.map(\.0)
        func modeMap<T>(_ v: JSON, _ path: String, _ read: (JSON) -> T?) -> [String: T] {
            var out: [String: T] = [:]
            for m in modes { out[m] = read(v.require(m, path)) ?? fail("\(path).\(m) has the wrong type") }
            return out
        }
        func bool(_ j: JSON) -> Bool? { if case .bool(let b) = j { return b }; return nil }
        func table(_ v: JSON, _ path: String, _ names: [String]) -> [String: [String: String]] {
            guard let obj = v.object else { fail("\(path) must be an object") }
            if obj.map(\.0) != names { fail("\(path) must list \(names.count) tokens in the order of `color`") }
            return Dictionary(uniqueKeysWithValues: obj.map { name, values in (name, modeMap(values, "\(path).\(name)") { $0.string }) })
        }
        themes = (root.require("themes", "").array ?? []).map { th in
            let id = th.require("id", "themes").string ?? fail("themes.id must be a string")
            let path = "themes.\(id)"
            return Theme(id: id, name: th.require("name", path).string ?? fail("\(path).name"),
                         caption: th.require("caption", path).string ?? fail("\(path).caption"),
                         inkless: bool(th.require("inkless", path)) ?? fail("\(path).inkless must be a boolean"),
                         colors: table(th.require("color", path), "\(path).color", colorNames),
                         graphite: table(th.require("graphite", path), "\(path).graphite", graphiteNames),
                         links: modeMap(th.require("linkUnderlineAtRest", path), "\(path).linkUnderlineAtRest", bool),
                         quoteLinks: modeMap(th.require("quoteLinkUnderlineAtRest", path), "\(path).quoteLinkUnderlineAtRest", bool),
                         focusOnPage: modeMap(th.require("focusOnPage", path), "\(path).focusOnPage") { $0.string },
                         sheetIsPage: modeMap(th.require("sheetIsPage", path), "\(path).sheetIsPage", bool),
                         declaredDeeper: modeMap(th.require("declaredDeeper", path), "\(path).declaredDeeper") { $0.array?.compactMap(\.string) })
        }
        linkOnPage = modeMap(root.require("linkOnPage", ""), "linkOnPage") { $0.string }
        guard let first = themes.first else { fail("themes must list at least the default theme") }
        // The default theme is `color` itself, so every reader of `color` keeps drawing what it drew before themes.
        for c in colors where first.colors[c.name] != c.values { fail("themes[0] (\(first.id)) must equal `color`: \(c.name) differs") }
        for (key, stack) in graphite where first.graphite[key] != Dictionary(uniqueKeysWithValues: modes.map { ($0, rgb2hex(composite(stack, $0))) }) {
            fail("themes[0].graphite.\(key) must be the substitution resolved against `color`")
        }
        if Set(themes.map(\.id)).count != themes.count { fail("theme ids must be unique") }
    }

    /// The theme's Graphite value of `token` in `mode` (`--q-focusOnPage` and `--q-linkOnPage` included).
    func graphitePage(_ theme: Theme, _ mode: String) -> [(String, String)] {
        let light = mode.hasSuffix("HC") ? "lightHC" : "light"
        return [("focusOnPage", theme.graphite["focus"]![light]!), ("linkOnPage", theme.graphite["accent"]![mode]!)]
    }

    /// `--q-focusOnPage` and `--q-linkOnPage` outside Graphite (`page_variables()` in build.py).
    func page(_ theme: Theme, _ mode: String) -> [(String, String)] {
        [("focusOnPage", theme.focusOnPage[mode]!), ("linkOnPage", linkOnPage[mode]!)]
    }

    /// `hexof()` from build.py.
    func hex(_ token: String, _ mode: String) -> String {
        if token.hasPrefix("account:") {
            let n = String(token.dropFirst(8))
            guard let a = accounts.first(where: { $0.name == n }) else { fail("unknown account ink \(n)") }
            return a.values[mode]!
        }
        if token.hasPrefix("avatarInk:") {
            let n = String(token.dropFirst(10))
            guard let a = avatars.first(where: { $0.name == n }) else { fail("unknown avatar tint \(n)") }
            return a.ink[mode]!
        }
        if token.hasPrefix("avatarFace:") {
            let n = String(token.dropFirst(11))
            guard let a = avatars.first(where: { $0.name == n }) else { fail("unknown avatar tint \(n)") }
            return a.face[mode]!
        }
        if token.hasPrefix("fileInk:") {
            let n = String(token.dropFirst(8))
            guard let f = fileInks.first(where: { $0.name == n }) else { fail("unknown file ink \(n)") }
            return f.values[mode]!
        }
        if token == "fileLabel" { return fileLabel[mode]! }
        guard let c = colorByName[token] else { fail("unknown colour token \(token)") }
        return c.values[mode]!
    }

    /// `resolve_stack()` from build.py, for stacks of plain colour tokens (the graphite substitutions).
    func composite(_ stack: [String], _ mode: String) -> RGBA {
        var cur = hex2rgba(hex(stack[0], mode))
        for t in stack.dropFirst() { cur = over(hex2rgba(hex(t, mode)), cur) }
        return cur
    }

    func pairs(_ key: String) -> [Pair] {
        (root.require(key, "").array ?? []).map { p in
            let fgValue = p.require("fg", key)
            let fg: [String] = fgValue.string.map { [$0] } ?? (fgValue.array ?? []).map { $0.string ?? fail("\(key): fg") }
            let bg = (p.require("bg", key).array ?? []).map { $0.string ?? fail("\(key): bg") }
            if fg.isEmpty || bg.isEmpty { fail("\(key): empty fg or bg") }
            return Pair(use: p.require("use", key).string ?? fail("\(key): use"), fg: fg, bg: bg,
                        need: p.require("need", key).double ?? fail("\(key): need"), needIC: p["needIC"]?.double)
        }
    }
}

// MARK: - Generic namespaces (layout, border, platform, …)

enum NumberStyle {
    /// Every number is a CGFloat: metrics.
    case cgFloat
    /// Integer literals stay Int, the rest are Double: counts and ratios.
    case intOrDouble
}

func literalType(_ items: [JSON], _ style: NumberStyle, _ path: String) -> (type: String, literal: String) {
    if items.allSatisfy({ $0.string != nil }) {
        return ("[String]", "[" + items.map { swiftString($0.string!) }.joined(separator: ", ") + "]")
    }
    if items.allSatisfy({ $0.double != nil }) {
        switch style {
        case .cgFloat: return ("[CGFloat]", "[" + items.map { swiftNumber($0.double!) }.joined(separator: ", ") + "]")
        case .intOrDouble:
            if items.allSatisfy({ $0.isIntegerLiteral }) { return ("[Int]", "[" + items.map { swiftNumber($0.double!) }.joined(separator: ", ") + "]") }
            return ("[Double]", "[" + items.map { swiftNumber($0.double!) }.joined(separator: ", ") + "]")
        }
    }
    if items.allSatisfy({ if case .bool = $0 { return true }; return false }) {
        return ("[Bool]", "[" + items.map { if case .bool(let b) = $0 { return b ? "true" : "false" }; return "" }.joined(separator: ", ") + "]")
    }
    fail("\(path): arrays must hold only numbers, only strings or only booleans")
}

func emitMembers(_ object: [(String, JSON)], indent: String, path: String, style: NumberStyle) -> String {
    var out = ""
    var seen: [String: String] = [:]
    func claim(_ ident: String, _ key: String) {
        let folded = ident.trimmingCharacters(in: CharacterSet(charactersIn: "`")).lowercased()
        if let other = seen[folded] { fail("\(path): keys '\(other)' and '\(key)' map to the same Swift name \(ident)") }
        seen[folded] = key
    }
    for (key, value) in object {
        let p = path.isEmpty ? key : "\(path).\(key)"
        switch value {
        case .object(let inner):
            let t = typeName(key)
            claim(t, key)
            out += "\(indent)public enum \(t) {\n"
            out += emitMembers(inner, indent: indent + "    ", path: p, style: style)
            out += "\(indent)}\n"
        case .number(let d, _):
            let m = memberName(key)
            claim(m, key)
            switch style {
            case .cgFloat: out += "\(indent)public static let \(m): CGFloat = \(swiftNumber(d))\n"
            case .intOrDouble:
                out += "\(indent)public static let \(m): \(value.isIntegerLiteral ? "Int" : "Double") = \(swiftNumber(d))\n"
            }
        case .string(let s):
            let m = memberName(key)
            claim(m, key)
            out += "\(indent)public static let \(m): String = \(swiftString(s))\n"
        case .bool(let b):
            let m = memberName(key)
            claim(m, key)
            out += "\(indent)public static let \(m): Bool = \(b)\n"
        case .array(let items):
            let m = memberName(key)
            claim(m, key)
            if items.isEmpty { fail("\(p): empty arrays have no type") }
            let (t, lit) = literalType(items, style, p)
            out += "\(indent)public static let \(m): \(t) = \(lit)\n"
        case .null:
            fail("\(p): null has no Swift type")
        }
    }
    return out
}

// MARK: - Emitters: Swift runtime

func colorValuesLiteral(_ values: [String: String]) -> String {
    "QuireColorValues(light: \(rgbaLiteral(values["light"]!)), dark: \(rgbaLiteral(values["dark"]!)), lightHC: \(rgbaLiteral(values["lightHC"]!)), darkHC: \(rgbaLiteral(values["darkHC"]!)))"
}

func graphiteValues(_ t: Tokens, _ stack: [String]) -> [String: String] {
    var v: [String: String] = [:]
    for m in modes { v[m] = rgb2hex(t.composite(stack, m)) }
    return v
}

func colorProperty(_ name: String) -> String { "q" + upperFirst(memberName(name).trimmingCharacters(in: CharacterSet(charactersIn: "`"))) }

/// A token is themed when any theme gives it another value, or another Graphite value, than the default theme does.
/// Every other token keeps one set of values and the single-set provider it had before themes.
func isThemed(_ t: Tokens, _ name: String) -> Bool {
    let first = t.themes[0]
    return t.themes.contains { $0.colors[name] != first.colors[name] || $0.graphite[name] != first.graphite[name] }
}

func themeArrayLiteral(_ values: [[String: String]], indent: String) -> String {
    "[\n" + values.map { "\(indent)    \(colorValuesLiteral($0))," }.joined(separator: "\n") + "\n\(indent)]"
}

func emitColors(_ t: Tokens) -> String {
    let graphite = Dictionary(uniqueKeysWithValues: t.graphite)
    let themed = t.colors.filter { isThemed(t, $0.name) }
    var out = header + "\nimport AppKit\nimport SwiftUI\n\n"
    out += "// One dynamic provider per colour token (spec §8.2). The provider resolves Light, Dark and both Increase\n"
    out += "// Contrast variants through `bestMatch`; accent-family tokens also carry their Graphite substitution (§3.1),\n"
    out += "// pre-composited per mode by the generator, and return it while `QuireEnvironment.isGraphite` is on. A token\n"
    out += "// that differs across themes (§4.16) carries one set of values per theme, in `QuireTheme` order, and returns the\n"
    out += "// set of `QuireEnvironment`'s theme.\n"
    out += "extension NSColor {\n"
    for c in t.colors {
        let use = c.use.isEmpty ? c.group : "\(c.use) (\(c.group))"
        out += docComment("`color.\(c.name)`: \(use).", indent: "    ")
        if let stack = graphite[c.name] {
            out += docComment("Under Graphite: \(stack.map { "`\($0)`" }.joined(separator: " + ")).", indent: "    ")
        }
        let m = memberName(c.name)
        if isThemed(t, c.name) {
            let g = graphite[c.name] != nil ? ", graphite: QuireThemeTable.\(graphiteTableName(c.name))" : ""
            out += "    public static let \(colorProperty(c.name)) = NSColor.quire(\(swiftString(c.name)), themes: QuireThemeTable.\(m)\(g))\n"
        } else if let stack = graphite[c.name] {
            out += "    public static let \(colorProperty(c.name)) = NSColor.quire(\(swiftString(c.name)), \(colorValuesLiteral(c.values)),\n"
            out += "        graphite: \(colorValuesLiteral(graphiteValues(t, stack))))\n"
        } else {
            out += "    public static let \(colorProperty(c.name)) = NSColor.quire(\(swiftString(c.name)), \(colorValuesLiteral(c.values)))\n"
        }
    }
    out += "}\n\n"
    out += "extension Color {\n"
    for c in t.colors {
        out += "    public static let \(colorProperty(c.name)) = Color(nsColor: .\(colorProperty(c.name)))\n"
    }
    out += "}\n\n"
    out += "// `.qInk`, `.qCanvas`, … wherever SwiftUI takes a shape style: resolved from the view's `quireTheme`, so a theme\n"
    out += "// switch redraws in place (spec §4.16).\n"
    out += "extension ShapeStyle where Self == QuireColorStyle {\n"
    for c in t.colors {
        out += "    public static var \(colorProperty(c.name)): QuireColorStyle { QuireColorStyle(.\(memberName(c.name))) }\n"
    }
    out += "}\n\n"
    out += "/// Every themed token's values per theme, in `QuireTheme` order: static integers, so a theme never drawn costs no\n"
    out += "/// colour object.\n"
    out += "enum QuireThemeTable {\n"
    for c in themed {
        out += "    static let \(memberName(c.name)): [QuireColorValues] = \(themeArrayLiteral(t.themes.map { $0.colors[c.name]! }, indent: "    "))\n"
        if graphite[c.name] != nil {
            out += "    static let \(graphiteTableName(c.name)): [QuireColorValues] = \(themeArrayLiteral(t.themes.map { $0.graphite[c.name]! }, indent: "    "))\n"
        }
    }
    out += "}\n\n"
    out += "/// Every colour token by its tokens.json name, for code that looks tokens up by name (tests, the CSS bridge).\n"
    out += "public enum QuireColorToken: String, CaseIterable, Sendable {\n"
    for c in t.colors {
        let m = memberName(c.name)
        out += m == c.name ? "    case \(m)\n" : "    case \(m) = \(swiftString(c.name))\n"
    }
    out += "\n    /// The dynamic colour, Graphite-aware where the token has a substitution.\n"
    out += "    public var color: NSColor {\n        switch self {\n"
    for c in t.colors { out += "        case .\(memberName(c.name)): return .\(colorProperty(c.name))\n" }
    out += "        }\n    }\n\n"
    out += "    /// The four values from tokens.json, alpha kept: the default theme's.\n"
    out += "    public var values: QuireColorValues {\n        switch self {\n"
    for c in t.colors { out += "        case .\(memberName(c.name)): return \(colorValuesLiteral(c.values))\n" }
    out += "        }\n    }\n\n"
    out += "    /// The four values in `theme`, alpha kept.\n"
    out += "    public func values(theme: QuireTheme) -> QuireColorValues {\n        switch self {\n"
    for c in themed { out += "        case .\(memberName(c.name)): return QuireThemeTable.\(memberName(c.name))[theme.index]\n" }
    if themed.count < t.colors.count { out += "        default: return values\n" }
    out += "        }\n    }\n\n"
    out += "    /// The four Graphite values in `theme`, or nil when Graphite leaves the token unchanged.\n"
    out += "    public func graphiteValues(theme: QuireTheme) -> QuireColorValues? {\n        switch self {\n"
    for c in t.colors {
        guard let stack = graphite[c.name] else { continue }
        if isThemed(t, c.name) {
            out += "        case .\(memberName(c.name)): return QuireThemeTable.\(graphiteTableName(c.name))[theme.index]\n"
        } else {
            out += "        case .\(memberName(c.name)): return \(colorValuesLiteral(graphiteValues(t, stack)))\n"
        }
    }
    out += "        default: return nil\n        }\n    }\n\n"
    out += "    /// True when some theme gives the token another value than the default theme does.\n"
    out += "    public var isThemed: Bool {\n        switch self {\n"
    for c in themed { out += "        case .\(memberName(c.name)): return true\n" }
    out += "        default: return false\n        }\n    }\n\n"
    out += "    /// The token's Graphite stack (composited left to right), or nil when Graphite leaves it unchanged.\n"
    out += "    public var graphiteStack: [String]? {\n        switch self {\n"
    for c in t.colors where graphite[c.name] != nil {
        out += "        case .\(memberName(c.name)): return [\(graphite[c.name]!.map(swiftString).joined(separator: ", "))]\n"
    }
    out += "        default: return nil\n        }\n    }\n\n"
    out += "    /// The token's group in tokens.json (surface, ink, line, wash, accent, mark).\n"
    out += "    public var group: String {\n        switch self {\n"
    for c in t.colors { out += "        case .\(memberName(c.name)): return \(swiftString(c.group))\n" }
    out += "        }\n    }\n}\n"
    return out
}

func graphiteTableName(_ name: String) -> String {
    memberName(name).trimmingCharacters(in: CharacterSet(charactersIn: "`")) + "Graphite"
}

/// `QuireTheme` (spec §4.16): the themes in Settings order, the first the default, with what each needs at run time.
func emitThemes(_ t: Tokens) -> String {
    var out = header + "\n"
    out += "/// The themes (spec §4.16), in the order Settings shows them. The first is the default and is `color` itself.\n"
    out += "public enum QuireTheme: String, CaseIterable, Sendable {\n"
    for th in t.themes {
        out += docComment(th.caption, indent: "    ")
        let m = memberName(th.id)
        out += m == th.id ? "    case \(m)\n" : "    case \(m) = \(swiftString(th.id))\n"
    }
    func property(_ name: String, _ type: String, _ doc: String, _ value: (Theme) -> String) {
        out += "\n" + docComment(doc, indent: "    ")
        out += "    public var \(name): \(type) {\n        switch self {\n"
        for th in t.themes { out += "        case .\(memberName(th.id)): return \(value(th))\n" }
        out += "        }\n    }\n"
    }
    func perMode(_ name: String, _ doc: String, _ value: (Theme) -> [String: Bool]) {
        out += "\n" + docComment(doc, indent: "    ")
        out += "    public func \(name)(_ mode: QuireMode) -> Bool {\n        switch self {\n"
        for th in t.themes {
            let v = value(th)
            out += "        case .\(memberName(th.id)): return [\(modes.map { v[$0]! ? "true" : "false" }.joined(separator: ", "))][mode.index]\n"
        }
        out += "        }\n    }\n"
    }
    property("name", "String", "The name under the theme's tile.") { swiftString($0.name) }
    property("caption", "String", "What the theme is, in every mode: the line under the tiles.") { swiftString($0.caption) }
    property("index", "Int", "The theme's place in `allCases`, which indexes every per-theme table.") { th in String(t.themes.firstIndex { $0.id == th.id }!) }
    property("isInkless", "Bool", "True when the theme writes in its text ink (its accent family is its own Graphite substitution).") { $0.inkless ? "true" : "false" }
    perMode("underlinesLinksAtRest", "True where the theme's ink sits too near its text ink for colour alone to mark a link (R10): every link draws its underline at rest.") { $0.links }
    perMode("underlinesQuoteLinksAtRest", "True where the ink sits too near `ink2` (R10): links inside quoted text draw their underline at rest.") { $0.quoteLinks }
    perMode("sheetIsPage", "True where the sheet is the white page a sender designed for (R1), so styled mail is shown on it as sent.") { $0.sheetIsPage }
    out += "}\n"
    return out
}

func emitPalettes(_ t: Tokens) -> String {
    var out = header + "\nimport AppKit\nimport SwiftUI\n\n"
    out += "extension Quire {\n"
    out += "    /// The ten account inks in assignment order (spec §4.2). Identity, not accent: Graphite leaves them alone.\n"
    out += "    public enum AccountInk: Int, CaseIterable, Sendable {\n"
    for (i, a) in t.accounts.enumerated() { out += "        case \(memberName(a.name.lowercased())) = \(i)\n" }
    out += "\n        /// The ink's name as Settings shows it.\n"
    out += "        public var name: String { Quire.accountInkNames[rawValue] }\n"
    out += "        public var color: NSColor { Quire.accountInkColors[rawValue] }\n"
    out += "        public var values: QuireColorValues {\n            switch self {\n"
    for a in t.accounts { out += "            case .\(memberName(a.name.lowercased())): return \(colorValuesLiteral(a.values))\n" }
    out += "            }\n        }\n    }\n\n"
    out += "    public static let accountInkNames: [String] = [\(t.accounts.map { swiftString($0.name) }.joined(separator: ", "))]\n\n"
    out += "    static let accountInkColors: [NSColor] = AccountInk.allCases.map { NSColor.quire(\"account.\" + $0.name, $0.values) }\n\n"
    out += "    /// The eight sender-avatar tints (spec §4.3): a face and its ink per mode.\n"
    out += "    public enum AvatarTint: Int, CaseIterable, Sendable {\n"
    for (i, a) in t.avatars.enumerated() { out += "        case \(memberName(a.name.lowercased())) = \(i)\n" }
    out += "\n        public var name: String { Quire.avatarTintNames[rawValue] }\n"
    out += "        public var face: NSColor { Quire.avatarFaceColors[rawValue] }\n"
    out += "        public var ink: NSColor { Quire.avatarInkColors[rawValue] }\n"
    out += "        public var faceValues: QuireColorValues {\n            switch self {\n"
    for a in t.avatars { out += "            case .\(memberName(a.name.lowercased())): return \(colorValuesLiteral(a.face))\n" }
    out += "            }\n        }\n"
    out += "        public var inkValues: QuireColorValues {\n            switch self {\n"
    for a in t.avatars { out += "            case .\(memberName(a.name.lowercased())): return \(colorValuesLiteral(a.ink))\n" }
    out += "            }\n        }\n    }\n\n"
    out += "    public static let avatarTintNames: [String] = [\(t.avatars.map { swiftString($0.name) }.joined(separator: ", "))]\n\n"
    out += "    static let avatarFaceColors: [NSColor] = AvatarTint.allCases.map { NSColor.quire(\"avatar.\" + $0.name + \".face\", $0.faceValues) }\n"
    out += "    static let avatarInkColors: [NSColor] = AvatarTint.allCases.map { NSColor.quire(\"avatar.\" + $0.name + \".ink\", $0.inkValues) }\n\n"
    out += "    /// The tint for a sender: FNV-1a 32-bit over the UTF-8 of the lowercased address, modulo the tint count\n"
    out += "    /// (spec §4.3). Stable across launches and machines, so a sender keeps one face everywhere.\n"
    out += "    public static func avatarTintIndex(forAddress address: String) -> Int {\n"
    out += "        var hash: UInt32 = 2_166_136_261\n"
    out += "        for byte in address.lowercased().utf8 {\n"
    out += "            hash ^= UInt32(byte)\n"
    out += "            hash = hash &* 16_777_619\n"
    out += "        }\n"
    out += "        return Int(hash % UInt32(AvatarTint.allCases.count))\n"
    out += "    }\n\n"
    out += "    public static func avatarTint(forAddress address: String) -> AvatarTint {\n"
    out += "        AvatarTint(rawValue: avatarTintIndex(forAddress: address))!\n"
    out += "    }\n\n"
    out += "    /// The file inks (spec §5.57): the band of a file mark, one per family of file types, by the family's name in\n"
    out += "    /// lower case (SSCore's `FileFamily` raw values). Fixed across themes and Graphite, like the account inks.\n"
    out += "    public enum FileInk: String, CaseIterable, Sendable {\n"
    for f in t.fileInks {
        out += docComment(upperFirst(f.use) + ".", indent: "        ")
        out += "        case \(memberName(f.name.lowercased())) = \(swiftString(f.name.lowercased()))\n"
    }
    out += "\n        /// The family's name as the spec writes it.\n"
    out += "        public var name: String {\n            switch self {\n"
    for f in t.fileInks { out += "            case .\(memberName(f.name.lowercased())): return \(swiftString(f.name))\n" }
    out += "            }\n        }\n"
    out += "        public var color: NSColor { Quire.fileInkColors[Self.allCases.firstIndex(of: self)!] }\n"
    out += "        public var values: QuireColorValues {\n            switch self {\n"
    for f in t.fileInks { out += "            case .\(memberName(f.name.lowercased())): return \(colorValuesLiteral(f.values))\n" }
    out += "            }\n        }\n    }\n\n"
    out += "    static let fileInkColors: [NSColor] = FileInk.allCases.map { NSColor.quire(\"file.\" + $0.rawValue, $0.values) }\n\n"
    out += "    /// The label on every file ink (spec §5.57).\n"
    out += "    public static let fileLabelValues = \(colorValuesLiteral(t.fileLabel))\n"
    out += "    static let fileLabelColor = NSColor.quire(\"file.label\", fileLabelValues)\n"
    out += "}\n\n"
    out += "extension NSColor {\n"
    out += "    /// The account ink for palette slot `slot`, wrapping so any stored slot draws.\n"
    out += "    public static func qAccount(_ slot: Int) -> NSColor {\n"
    out += "        let n = Quire.accountInkColors.count\n"
    out += "        return Quire.accountInkColors[((slot % n) + n) % n]\n"
    out += "    }\n\n"
    out += "    public static func qAvatarFace(_ index: Int) -> NSColor {\n"
    out += "        let n = Quire.avatarFaceColors.count\n"
    out += "        return Quire.avatarFaceColors[((index % n) + n) % n]\n"
    out += "    }\n\n"
    out += "    public static func qAvatarInk(_ index: Int) -> NSColor {\n"
    out += "        let n = Quire.avatarInkColors.count\n"
    out += "        return Quire.avatarInkColors[((index % n) + n) % n]\n"
    out += "    }\n\n"
    out += "    /// The label on a file mark's band (spec §5.57).\n"
    out += "    public static var qFileLabel: NSColor { Quire.fileLabelColor }\n"
    out += "}\n\n"
    out += "extension Color {\n"
    out += "    public static func qAccount(_ slot: Int) -> Color { Color(nsColor: .qAccount(slot)) }\n"
    out += "    public static func qAvatarFace(_ index: Int) -> Color { Color(nsColor: .qAvatarFace(index)) }\n"
    out += "    public static func qAvatarInk(_ index: Int) -> Color { Color(nsColor: .qAvatarInk(index)) }\n"
    out += "}\n"
    return out
}

/// The paper faces (spec §5.55): the papers as a palette that follows Light and Dark only, and the twelve faces' cut-outs as
/// SVG path data, each with its paper and lift. A face that names a paper the palette lacks, or a lift with no shadow, fails
/// the run, so the Swift that compiles is the art as drawn.
func emitPaperFaces(_ t: Tokens) -> String {
    guard let papers = t.root.require("paperPalette", "").array, !papers.isEmpty else { fail("paperPalette must list the papers") }
    guard let faces = t.root.require("paperFaces", "").array, !faces.isEmpty else { fail("paperFaces must list the faces") }
    let paperNames = papers.map { $0.require("name", "paperPalette").string ?? fail("paperPalette.name must be a string") }
    if Set(paperNames).count != paperNames.count { fail("paperPalette names must be unique") }
    let lifts = t.root.require("layout", "").require("paperFaces", "layout").require("shadowY", "layout.paperFaces").array?.count ?? 0
    var out = header + "\nimport AppKit\nimport SwiftUI\n\n"
    out += "extension Quire {\n"
    out += "    /// The papers the paper faces are cut from (spec §5.55), in the art's order. Illustration, not interface: no theme\n"
    out += "    /// recolours them, Graphite leaves them alone and Increase Contrast keeps them; they follow Light and Dark only.\n"
    out += "    public enum Paper: Int, CaseIterable, Sendable {\n"
    for (i, n) in paperNames.enumerated() { out += "        case \(memberName(n)) = \(i)\n" }
    out += "\n        /// The paper's name in the art (`paper_faces.json`).\n"
    out += "        public var name: String { Quire.paperNames[rawValue] }\n"
    out += "        public var color: NSColor { Quire.paperColors[rawValue] }\n"
    out += "        public var values: QuireColorValues {\n            switch self {\n"
    for (p, n) in zip(papers, paperNames) {
        var values: [String: String] = [:]
        for m in modes { values[m] = p.require(m, "paperPalette.\(n)").string ?? fail("paperPalette.\(n).\(m) must be a string") }
        out += "            case .\(memberName(n)): return \(colorValuesLiteral(values))\n"
    }
    out += "            }\n        }\n    }\n\n"
    out += "    public static let paperNames: [String] = [\(paperNames.map(swiftString).joined(separator: ", "))]\n\n"
    out += "    static let paperColors: [NSColor] = Paper.allCases.map { NSColor.quire(\"paper.\" + $0.name, $0.values) }\n\n"
    var ids: [String] = []
    var cases: [(member: String, name: String, ground: String, layers: [(String, String, Int)])] = []
    for f in faces {
        let id = f.require("id", "paperFaces").string ?? fail("paperFaces.id must be a string")
        if ids.contains(id) { fail("paperFaces: duplicate id \(id)") }
        ids.append(id)
        let path = "paperFaces.\(id)"
        let ground = f.require("ground", path).string ?? fail("\(path).ground must be a string")
        if !paperNames.contains(ground) { fail("\(path).ground \(ground) is not a paper") }
        let layers = (f.require("layers", path).array ?? fail("\(path).layers must be an array")).enumerated().map { i, l -> (String, String, Int) in
            let lp = "\(path).layers[\(i)]"
            let d = l.require("d", lp).string ?? fail("\(lp).d must be a string")
            let paper = l.require("paper", lp).string ?? fail("\(lp).paper must be a string")
            if !paperNames.contains(paper) { fail("\(lp).paper \(paper) is not a paper") }
            guard let lift = l.require("lift", lp).double, lift == lift.rounded(), lift >= 0, Int(lift) < lifts else {
                fail("\(lp).lift must be an integer below \(lifts)")
            }
            return (d, paper, Int(lift))
        }
        cases.append((memberName(id), f.require("name", path).string ?? fail("\(path).name must be a string"), ground, layers))
    }
    out += "    /// The paper faces (spec §5.55), in the picker's order; an account that has chosen none wears the one its ink slot\n"
    out += "    /// picks (`automatic(forSlot:)`). Each is cut-outs laid on a ground paper, drawn by `QuireAvatarRenderer`.\n"
    out += "    public enum PaperFace: String, CaseIterable, Sendable {\n"
    for (c, id) in zip(cases, ids) { out += "        case \(c.member) = \(swiftString(id))\n" }
    out += "\n        /// What VoiceOver calls the face, in the picker only: elsewhere an account's face is read as the account.\n"
    out += "        public var name: String {\n            switch self {\n"
    for c in cases { out += "            case .\(c.member): return \(swiftString(c.name))\n" }
    out += "            }\n        }\n\n"
    out += "        /// The paper that fills the disc behind the cut-outs.\n"
    out += "        public var ground: Paper {\n            switch self {\n"
    for c in cases { out += "            case .\(c.member): return .\(memberName(c.ground))\n" }
    out += "            }\n        }\n\n"
    out += "        /// The cut-outs, bottom first: SVG path data in the art's square (`layout.paperFaces.artBox`, y down), each\n"
    out += "        /// with its paper and its lift, which picks its shadow.\n"
    out += "        public var layers: [QuirePaperLayer] {\n            switch self {\n"
    for c in cases {
        out += "            case .\(c.member):\n                return [\n"
        for (d, paper, lift) in c.layers {
            out += "                    QuirePaperLayer(path: \(swiftString(d)),\n                                    paper: .\(memberName(paper)), lift: \(lift)),\n"
        }
        out += "                ]\n"
    }
    out += "            }\n        }\n    }\n"
    out += "}\n\n"
    out += "extension NSColor {\n"
    out += "    /// A paper of the paper faces (spec §5.55), the same in every theme.\n"
    out += "    public static func qAvatarPaper(_ paper: Quire.Paper) -> NSColor { Quire.paperColors[paper.rawValue] }\n"
    out += "}\n\n"
    out += "extension Color {\n"
    out += "    public static func qAvatarPaper(_ paper: Quire.Paper) -> Color { Color(nsColor: .qAvatarPaper(paper)) }\n"
    out += "}\n"
    return out
}

let knownFamilies = ["sf", "serif", "rounded", "mono"]
let knownTypeKeys: Set<String> = ["family", "size", "weight", "lineHeight", "tracking", "twin", "twinOf", "variantOf", "unreadWeight",
                                  "numeric", "style", "case", "sizeRatio", "minSize", "use"]

func emitTypography(_ t: Tokens) -> String {
    guard let roles = t.root.require("typography", "").object else { fail("typography must be an object") }
    let names = Set(roles.map { $0.0 })
    var out = header + "\nimport AppKit\n\n"
    out += "extension QuireFont {\n"
    out += "    /// One case per `typography` entry (spec §4.4): base roles, sans twins and weight variants.\n"
    out += "    public enum Role: String, CaseIterable, Sendable {\n"
    for (name, _) in roles {
        let m = memberName(name)
        out += m == name ? "        case \(m)\n" : "        case \(m) = \(swiftString(name))\n"
    }
    out += "    }\n}\n\n"
    out += "extension QuireFont.Role {\n"
    out += "    /// Every field tokens.json gives the role.\n"
    out += "    public var spec: QuireFont.Spec {\n        switch self {\n"
    for (name, v) in roles {
        guard let fields = v.object else { fail("typography.\(name) must be an object") }
        for (k, _) in fields where !knownTypeKeys.contains(k) {
            fail("typography.\(name).\(k) is new: teach scripts/tools/quire-tokens.swift and QuireFont.Spec about it")
        }
        func num(_ k: String) -> Double { v.require(k, "typography.\(name)").double ?? fail("typography.\(name).\(k) must be a number") }
        func role(_ k: String) -> String {
            guard let r = v[k]?.string else { return "nil" }
            if !names.contains(r) { fail("typography.\(name).\(k) names unknown role \(r)") }
            return "." + memberName(r)
        }
        let family = v.require("family", "typography.\(name)").string ?? ""
        if !knownFamilies.contains(family) { fail("typography.\(name).family \(family) is not one of \(knownFamilies)") }
        if let n = v["numeric"]?.string, n != "tabular" { fail("typography.\(name).numeric \(n) is not supported") }
        if let s = v["style"]?.string, s != "italic" { fail("typography.\(name).style \(s) is not supported") }
        if let c = v["case"]?.string, c != "upper" { fail("typography.\(name).case \(c) is not supported") }
        let opt: (String) -> String = { k in v[k]?.double.map(swiftNumber) ?? "nil" }
        out += "        case .\(memberName(name)):\n"
        out += "            return QuireFont.Spec(family: .\(family), size: \(swiftNumber(num("size"))), weight: \(swiftNumber(num("weight"))), "
        out += "lineHeight: \(swiftNumber(num("lineHeight"))), tracking: \(swiftNumber(num("tracking"))),\n"
        out += "                                  italic: \(v["style"]?.string == "italic"), tabular: \(v["numeric"]?.string == "tabular"), "
        out += "uppercase: \(v["case"]?.string == "upper"), unreadWeight: \(opt("unreadWeight")),\n"
        out += "                                  twin: \(role("twin")), twinOf: \(role("twinOf")), variantOf: \(role("variantOf")), "
        out += "sizeRatio: \(opt("sizeRatio")), minSize: \(opt("minSize")),\n"
        out += "                                  use: \(swiftString(v["use"]?.string ?? "")))\n"
    }
    out += "        }\n    }\n}\n\n"
    out += "// `typography.subject` → `QuireFont.subject` (spec §8.1).\n"
    out += "extension QuireFont {\n"
    for (name, _) in roles {
        out += "    public static var \(memberName(name)): NSFont { font(.\(memberName(name))) }\n"
    }
    out += "}\n"
    return out
}

func emitScales(_ t: Tokens) -> String {
    var out = header + "\nimport AppKit\nimport QuartzCore\n\n"
    out += "extension Quire {\n"
    // Space
    guard let space = t.root.require("space", "").object else { fail("space must be an object") }
    out += "    /// The spacing scale (spec §4.5). Use only these steps.\n"
    out += "    public enum Space {\n"
    for (k, v) in space { out += "        public static let \(memberName(k)): CGFloat = \(swiftNumber(v.double ?? fail("space.\(k)")))\n" }
    out += "        public static let scale: [CGFloat] = [\(space.map { memberName($0.0) }.joined(separator: ", "))]\n"
    out += "    }\n\n"
    // Radius
    guard let radius = t.root.require("radius", "").object else { fail("radius must be an object") }
    out += "    /// The radius scale (spec §4.6). `pill` is a sentinel: a pill's radius is its height / 2.\n"
    out += "    public enum Radius {\n"
    for (k, v) in radius { out += "        public static let \(memberName(k)): CGFloat = \(swiftNumber(v.double ?? fail("radius.\(k)")))\n" }
    out += "        /// Every fixed radius on the scale (all but `pill`).\n"
    out += "        public static let scale: [CGFloat] = [\(radius.filter { $0.0 != "pill" }.map { memberName($0.0) }.joined(separator: ", "))]\n"
    out += "    }\n\n"
    // Border
    guard let border = t.root.require("border", "").object else { fail("border must be an object") }
    out += "    /// Borders and hairlines (spec §4.7). Colour fields name colour tokens (`QuireColorToken(rawValue:)`).\n"
    out += "    public enum Border {\n"
    out += emitMembers(border, indent: "        ", path: "border", style: .cgFloat)
    out += "    }\n\n"
    // Elevation
    guard let elevation = t.root.require("elevation", "").object else { fail("elevation must be an object") }
    out += "    /// Elevation levels (spec §4.8): CSS-style shadow layers for the light and dark appearances; the\n"
    out += "    /// Increase Contrast modes use their base appearance's layers.\n"
    out += "    public enum Elevation {\n"
    for (k, v) in elevation {
        func layers(_ m: String) -> String {
            let items = v.require(m, "elevation.\(k)").array ?? fail("elevation.\(k).\(m) must be an array")
            return "[" + items.map { s -> String in
                func n(_ f: String) -> String { swiftNumber(s.require(f, "elevation.\(k).\(m)").double ?? fail("elevation.\(k).\(m).\(f)")) }
                let color = s.require("color", "elevation.\(k).\(m)").string ?? fail("elevation.\(k).\(m).color")
                return "QuireShadowLayer(x: \(n("x")), y: \(n("y")), blur: \(n("blur")), spread: \(n("spread")), rgba: \(rgbaLiteral(color)))"
            }.joined(separator: ", ") + "]"
        }
        if let use = v["use"]?.string { out += docComment(use, indent: "        ") }
        out += "        public static let \(memberName(k)) = QuireElevationLevel(light: \(layers("light")),\n"
        out += "                                                   dark: \(layers("dark")))\n"
    }
    out += "    }\n\n"
    // Motion
    guard let motion = t.root.require("motion", "").object, let durations = t.root.require("motion", "")["duration"]?.object,
          let curves = t.root.require("motion", "")["curve"]?.object else { fail("motion needs duration and curve") }
    for (k, _) in motion where k != "duration" && k != "curve" { fail("motion.\(k) is new: teach the generator about it") }
    out += "    /// Motion tokens (spec §4.10): durations in seconds, curves as cubic-bezier control points.\n"
    out += "    public enum Motion {\n"
    for (k, v) in durations {
        if let ms = v.double {
            out += "        public static let \(memberName(k)): TimeInterval = \(swiftNumber(ms / 1000))\n"
        } else if let list = v.array {
            out += "        public static let \(memberName(k)): [TimeInterval] = [\(list.map { swiftNumber(($0.double ?? fail("motion.duration.\(k)")) / 1000) }.joined(separator: ", "))]\n"
        } else {
            fail("motion.duration.\(k) must be a number or a list")
        }
    }
    out += "\n        public enum Curve: String, CaseIterable, Sendable {\n"
    for (k, _) in curves { out += "            case \(memberName(k))\n" }
    out += "\n            /// The cubic-bezier control points (x1, y1, x2, y2), as CSS writes them.\n"
    out += "            public var controlPoints: (Float, Float, Float, Float) {\n                switch self {\n"
    for (k, v) in curves {
        let p = (v.array ?? []).map { swiftNumber($0.double ?? fail("motion.curve.\(k)")) }
        if p.count != 4 { fail("motion.curve.\(k) needs four control points") }
        out += "                case .\(memberName(k)): return (\(p.joined(separator: ", ")))\n"
    }
    out += "                }\n            }\n\n"
    out += "            public var timingFunction: CAMediaTimingFunction {\n"
    out += "                let p = controlPoints\n"
    out += "                return CAMediaTimingFunction(controlPoints: p.0, p.1, p.2, p.3)\n"
    out += "            }\n        }\n"
    out += "    }\n"
    out += "}\n"
    return out
}

func emitLayout(_ t: Tokens) -> String {
    guard let layout = t.root.require("layout", "").object else { fail("layout must be an object") }
    var out = header + "\nimport CoreGraphics\n\n"
    out += "// Component metrics (`layout.<group>.<name>` → `Quire.Layout.<Group>.<name>`, spec §8.1). Numbers are\n"
    out += "// points, strings name tokens or mechanisms, arrays keep their order.\n"
    out += "extension Quire {\n    public enum Layout {\n"
    out += emitMembers(layout, indent: "        ", path: "layout", style: .cgFloat)
    out += "    }\n}\n"
    return out
}

func emitContent(_ t: Tokens) -> String {
    var out = header + "\nimport CoreGraphics\n\n"
    out += "extension Quire {\n"
    out += "    public static let name = \(swiftString(t.root["name"]?.string ?? ""))\n"
    out += "    public static let version = \(swiftString(t.root["version"]?.string ?? ""))\n\n"
    // Icons
    guard let icons = t.root.require("icon", "").object else { fail("icon must be an object") }
    out += "    /// Every symbol the app draws, by action (spec §4.11). `ss.` names are custom glyphs (`QuireGlyph`).\n"
    out += "    public enum Icon {\n"
    var seen = Set<String>()
    for (k, v) in icons {
        let m = memberName(k)
        if !seen.insert(m).inserted { fail("icon.\(k) collides with another icon name") }
        out += "        public static let \(m) = \(swiftString(v.string ?? fail("icon.\(k) must be a string")))\n"
    }
    out += "    }\n\n"
    // Custom glyphs
    guard let glyphs = t.root.require("customGlyphs", "").object else { fail("customGlyphs must be an object") }
    out += "    /// The custom glyphs (spec §4.11): SVG path data in grid units, y down.\n"
    out += "    public enum CustomGlyph: String, CaseIterable, Sendable {\n"
    for (k, _) in glyphs { out += "        case \(memberName(k)) = \(swiftString(k))\n" }
    func glyphSwitch(_ name: String, _ type: String, _ doc: String, _ body: (String, JSON) -> String) {
        out += "\n" + docComment(doc, indent: "        ")
        out += "        public var \(name): \(type) {\n            switch self {\n"
        for (k, v) in glyphs { out += "            case .\(memberName(k)): return \(body(k, v))\n" }
        out += "            }\n        }\n"
    }
    glyphSwitch("grid", "CGFloat", "The side of the square design grid.") { k, v in swiftNumber(v.require("grid", "customGlyphs.\(k)").double ?? fail("customGlyphs.\(k).grid")) }
    glyphSwitch("stroke", "CGFloat", "Stroke width in grid units; 0 means the paths are filled.") { k, v in swiftNumber(v.require("stroke", "customGlyphs.\(k)").double ?? fail("customGlyphs.\(k).stroke")) }
    glyphSwitch("paths", "[String]", "SVG path data, one subpath group per entry.") { k, v in
        "[" + (v.require("paths", "customGlyphs.\(k)").array ?? []).map { swiftString($0.string ?? fail("customGlyphs.\(k).paths")) }.joined(separator: ", ") + "]"
    }
    glyphSwitch("fills", "[QuireGlyphCircle]", "Filled circles drawn on top of the paths.") { k, v in
        "[" + (v.require("fills", "customGlyphs.\(k)").array ?? []).map { f -> String in
            guard let c = f["circle"]?.array, c.count == 3, f.object?.count == 1 else { fail("customGlyphs.\(k).fills: only {circle: [cx, cy, r]} is supported") }
            return "QuireGlyphCircle(cx: \(swiftNumber(c[0].double!)), cy: \(swiftNumber(c[1].double!)), r: \(swiftNumber(c[2].double!)))"
        }.joined(separator: ", ") + "]"
    }
    glyphSwitch("fillRule", "CGPathFillRule", "How filled paths treat overlaps (`evenodd` cuts a hole where subpaths overlap).") { k, v in
        switch v["fillRule"]?.string {
        case nil, "nonzero": return ".winding"
        case "evenodd": return ".evenOdd"
        case let other: fail("customGlyphs.\(k).fillRule \(other!) is not supported")
        }
    }
    glyphSwitch("meaning", "String", "What the glyph stands for.") { _, v in swiftString(v["meaning"]?.string ?? "") }
    out += "    }\n\n"
    // Reader symbols
    let symbols = (t.root.require("readerSymbols", "").array ?? []).map { $0.string ?? fail("readerSymbols must hold strings") }
    out += "    /// The SF Symbols the reader shell may draw (spec §4.11), rasterised once per web-view pool.\n"
    out += "    public static let readerSymbols: [String] = [\n"
    for s in symbols { out += "        \(swiftString(s)),\n" }
    out += "    ]\n\n"
    // Cheat sheet
    out += "    /// The keyboard cheat sheet's content (spec §5.32), band by band, left to right.\n"
    out += "    public static let cheatSheet: [QuireCheatSheetSection] = [\n"
    for sec in t.root.require("cheatSheetContent", "").array ?? [] {
        out += "        QuireCheatSheetSection(title: \(swiftString(sec.require("section", "cheatSheetContent").string ?? "")), rows: [\n"
        for row in sec.require("rows", "cheatSheetContent").array ?? [] {
            out += "            QuireCheatSheetRow(keys: \(swiftString(row.require("keys", "cheatSheetContent").string ?? "")), label: \(swiftString(row.require("label", "cheatSheetContent").string ?? ""))),\n"
        }
        out += "        ]),\n"
    }
    out += "    ]\n\n"
    let search = t.root.require("cheatSheetSearch", "")
    let searchTitle = search.require("title", "cheatSheetSearch").string ?? fail("cheatSheetSearch.title must be a string")
    let searchTerms = (search.require("terms", "cheatSheetSearch").array ?? []).map { $0.string ?? fail("cheatSheetSearch.terms must hold strings") }
    out += "    /// The title of the search operators' line under the cheat sheet's bands (spec §5.32, §5.6).\n"
    out += "    public static let cheatSheetSearchTitle = \(swiftString(searchTitle))\n\n"
    out += "    /// The search operators on that line, as typed, in order.\n"
    out += "    public static let cheatSheetSearch: [String] = [\n"
    for term in searchTerms { out += "        \(swiftString(term)),\n" }
    out += "    ]\n\n"
    // Platform, account rules, text size
    for (key, type, doc) in [("platform", "Platform", "Platform constants (minimum text size, the Graphite threshold, reader symbol rasterisation)."),
                             ("accountRules", "AccountRules", "The account palette's build-time rules (spec §4.2), asserted by AccountPaletteTests."),
                             ("textSize", "TextSize", "Settings › Appearance › Text size (spec §4.15): the popup's names, each size's step in points, and the row heights that follow.")] {
        guard let obj = t.root.require(key, "").object else { fail("\(key) must be an object") }
        out += docComment(doc, indent: "    ")
        out += "    public enum \(type) {\n"
        out += emitMembers(obj, indent: "        ", path: key, style: .intOrDouble)
        out += "    }\n\n"
    }
    out.removeLast()
    out += "}\n"
    return out
}

// MARK: - Emitter: reader CSS (mirrors css_all() in docs/design/source/build.py)

func fmtRGBA(_ hex: String) -> String {
    let c = hex2rgba(hex)
    return String(format: "rgba(%d,%d,%d,%.2f)", byte255(c.r), byte255(c.g), byte255(c.b), c.a)
}

func shadowCSS(_ layers: [JSON]) -> String {
    if layers.isEmpty { return "none" }
    return layers.map { s in
        "\(pyG(s["x"]!.double!))px \(pyG(s["y"]!.double!))px \(pyG(s["blur"]!.double!))px \(fmtRGBA(s["color"]!.string!))"
    }.joined(separator: ", ")
}

func cssHead(_ t: Tokens) -> [String] {
    guard let elevation = t.root["elevation"]?.object, let typography = t.root["typography"]?.object,
          let space = t.root["space"]?.object, let radius = t.root["radius"]?.object,
          let durations = t.root["motion"]?["duration"]?.object, let curves = t.root["motion"]?["curve"]?.object else { fail("tokens.json is incomplete") }
    let shadowed = elevation.filter { !($0.1["light"]?.array ?? []).isEmpty || !($0.1["dark"]?.array ?? []).isEmpty }

    func block(_ mode: String) -> String {
        var parts: [String] = []
        for c in t.colors { parts.append("--q-\(c.name):\(c.values[mode]!)") }
        for (name, value) in t.page(t.themes[0], mode) { parts.append("--q-\(name):\(value)") }
        for (i, a) in t.accounts.enumerated() {
            parts.append("--q-acct-\(i + 1):\(a.values[mode]!)")
            parts.append("--q-acct-\(a.name.lowercased()):\(a.values[mode]!)")
        }
        for a in t.avatars {
            parts.append("--q-av-\(a.name.lowercased())-face:\(a.face[mode]!)")
            parts.append("--q-av-\(a.name.lowercased())-ink:\(a.ink[mode]!)")
        }
        for f in t.fileInks { parts.append("--q-file-\(f.name.lowercased()):\(f.values[mode]!)") }
        parts.append("--q-file-label:\(t.fileLabel[mode]!)")
        for (k, v) in shadowed {
            parts.append("--q-\(k):\(shadowCSS(v[mode.hasPrefix("dark") ? "dark" : "light"]?.array ?? []))")
        }
        return parts.joined(separator: ";") + ";"
    }

    func staticBlock() -> String {
        var p = ["--q-sans:-apple-system,system-ui,sans-serif", "--q-serif:ui-serif,serif", "--q-rounded:ui-rounded,-apple-system,sans-serif", "--q-mono:ui-monospace,monospace"]
        let famvar = ["sf": "var(--q-sans)", "serif": "var(--q-serif)", "rounded": "var(--q-rounded)", "mono": "var(--q-mono)"]
        for (role, v) in typography {
            let size = v["size"]!.double!
            if size == 0 { continue }
            let style = v["style"]?.string == "italic" ? "italic " : ""
            p.append("--q-font-\(role):\(style)\(Int(v["weight"]!.double!)) \(pyG(size))px/\(pyG(v["lineHeight"]!.double!))px \(famvar[v["family"]!.string!]!)")
            p.append("--q-track-\(role):\(pyG(v["tracking"]!.double!))px")
        }
        for (k, v) in space { p.append("--q-\(k):\(pyG(v.double!))px") }
        for (k, v) in radius { p.append("--q-r-\(k):\(pyG(v.double!))px") }
        for (k, v) in durations { if let ms = v.double { p.append("--q-dur-\(k):\(Int(ms))ms") } }
        for (k, v) in curves {
            let c = v.array!.map { pyG($0.double!) }
            p.append("--q-ease-\(k):cubic-bezier(\(c.joined(separator: ",")))")
        }
        return ":root{" + p.joined(separator: ";") + ";}"
    }

    func graphiteBlock(_ mode: String) -> String {
        (t.graphite.map { "--q-\($0.0):\(rgb2hex(t.composite($0.1, mode)))" } + t.graphitePage(t.themes[0], mode).map { "--q-\($0.0):\($0.1)" })
            .joined(separator: ";") + ";"
    }

    return [
        staticBlock(),
        ":root{color-scheme:light dark;\(block("light"))}",
        "@media (prefers-color-scheme:dark){:root{\(block("dark"))}}",
        "@media (prefers-contrast:more){:root{\(block("lightHC"))}}",
        "@media (prefers-color-scheme:dark) and (prefers-contrast:more){:root{\(block("darkHC"))}}",
        "html.ss-ic{\(block("lightHC"))}",
        "@media (prefers-color-scheme:dark){html.ss-ic{\(block("darkHC"))}}",
        "html.ss-graphite{\(graphiteBlock("light"))}",
        "@media (prefers-color-scheme:dark){html.ss-graphite{\(graphiteBlock("dark"))}}",
        "@media (prefers-contrast:more){html.ss-graphite{\(graphiteBlock("lightHC"))}}",
        "@media (prefers-color-scheme:dark) and (prefers-contrast:more){html.ss-graphite{\(graphiteBlock("darkHC"))}}",
        "html.ss-ic.ss-graphite{\(graphiteBlock("lightHC"))}",
        "@media (prefers-color-scheme:dark){html.ss-ic.ss-graphite{\(graphiteBlock("darkHC"))}}",
    ]
}

/// Every role's `--q-font-` shorthand again at each Text size but Default (spec §4.15), under `html.ss-text-<name>`: size
/// and line height moved by the role's step, which `QuireFont.Role.step(at:)` computes the same way (the size's delta,
/// held at `platform.minTextSize`). After them each role's step as `--q-step-<role>`, for the boxes the shell sizes
/// around a line of that role (`calc(18px + var(--q-step-bodyStrong, 0px))`). A role the step leaves alone is not repeated.
func cssTextSizes(_ t: Tokens) -> [String] {
    guard let typography = t.root["typography"]?.object, let sizes = t.root.require("textSize", "").object,
          let floor = t.root["platform"]?["minTextSize"]?.double else { fail("tokens.json is incomplete") }
    let lookup = Dictionary(uniqueKeysWithValues: sizes)
    guard let names = lookup["names"]?.array?.compactMap(\.string), let deltas = lookup["deltas"]?.array?.compactMap(\.double),
          names.count == deltas.count else { fail("textSize.names and textSize.deltas must be arrays of the same length") }
    let famvar = ["sf": "var(--q-sans)", "serif": "var(--q-serif)", "rounded": "var(--q-rounded)", "mono": "var(--q-mono)"]
    var lines: [String] = []
    for (name, delta) in zip(names, deltas) where delta != 0 {
        var p: [String] = []
        var steps: [String] = []
        for (role, v) in typography {
            let size = v["size"]!.double!
            if size == 0 { continue }
            let step = max(delta, min(0, floor - size))
            if step == 0 { continue }
            let style = v["style"]?.string == "italic" ? "italic " : ""
            p.append("--q-font-\(role):\(style)\(Int(v["weight"]!.double!)) \(pyG(size + step))px/\(pyG(v["lineHeight"]!.double! + step))px \(famvar[v["family"]!.string!]!)")
            steps.append("--q-step-\(role):\(pyG(step))px")
        }
        lines.append("html.ss-text-\(name.lowercased()){" + (p + steps).joined(separator: ";") + ";}")
    }
    return lines
}

/// The theme's sheet (spec §4.16): the head's own colour selectors in the head's order, each holding only the variables
/// whose value in this theme differs from the default theme's in some mode, so it overrides the head and nothing else. It
/// follows the head in the document, so Increase Contrast and Graphite still win by the same specificity. The default
/// theme's sheet is empty.
func cssThemeSheet(_ t: Tokens, _ theme: Theme) -> [String] {
    let study = t.themes[0]
    let colorNames = t.colors.map(\.name) + ["focusOnPage", "linkOnPage"]
    func value(_ th: Theme, _ name: String, _ mode: String) -> String {
        th.colors[name]?[mode] ?? t.page(th, mode).first { $0.0 == name }!.1
    }
    func graphiteValue(_ th: Theme, _ name: String, _ mode: String) -> String {
        th.graphite[name]?[mode] ?? t.graphitePage(th, mode).first { $0.0 == name }!.1
    }
    let names = colorNames.filter { n in modes.contains { value(theme, n, $0) != value(study, n, $0) } }
    let graphiteNames = (t.graphite.map(\.0) + ["focusOnPage", "linkOnPage"]).filter { n in modes.contains { graphiteValue(theme, n, $0) != graphiteValue(study, n, $0) } }
    if names.isEmpty && graphiteNames.isEmpty { return [] }
    func block(_ mode: String) -> String { names.map { "--q-\($0):\(value(theme, $0, mode))" }.joined(separator: ";") + ";" }
    func graphiteBlock(_ mode: String) -> String { graphiteNames.map { "--q-\($0):\(graphiteValue(theme, $0, mode))" }.joined(separator: ";") + ";" }
    return [
        ":root{\(block("light"))}",
        "@media (prefers-color-scheme:dark){:root{\(block("dark"))}}",
        "@media (prefers-contrast:more){:root{\(block("lightHC"))}}",
        "@media (prefers-color-scheme:dark) and (prefers-contrast:more){:root{\(block("darkHC"))}}",
        "html.ss-ic{\(block("lightHC"))}",
        "@media (prefers-color-scheme:dark){html.ss-ic{\(block("darkHC"))}}",
        "html.ss-graphite{\(graphiteBlock("light"))}",
        "@media (prefers-color-scheme:dark){html.ss-graphite{\(graphiteBlock("dark"))}}",
        "@media (prefers-contrast:more){html.ss-graphite{\(graphiteBlock("lightHC"))}}",
        "@media (prefers-color-scheme:dark) and (prefers-contrast:more){html.ss-graphite{\(graphiteBlock("darkHC"))}}",
        "html.ss-ic.ss-graphite{\(graphiteBlock("lightHC"))}",
        "@media (prefers-color-scheme:dark){html.ss-ic.ss-graphite{\(graphiteBlock("darkHC"))}}",
    ]
}

/// `var SS_FILE_MARK = {…};`: `layout.fileMark` as a JSON object, keys in the file's order, plus `families`.
func fileMarkScript(_ t: Tokens) -> String {
    guard let mark = t.root["layout"]?["fileMark"]?.object else { fail("layout.fileMark must be an object") }
    func json(_ v: JSON) -> String {
        if let d = v.double { return pyG(d) }
        if let s = v.string { return "\"" + s + "\"" }
        fail("layout.fileMark holds numbers and path strings only")
    }
    let fields = mark.map { "\"\($0.0)\":\(json($0.1))" }
    let families = "\"families\":[" + t.fileInks.map { "\"\($0.name.lowercased())\"" }.joined(separator: ",") + "]"
    return "var SS_FILE_MARK = {" + (fields + [families]).joined(separator: ",") + "};"
}

func emitCSS(_ t: Tokens) -> String {
    var out = header + "\n"
    out += "/// The reader's Quire custom properties (spec §8.4): every colour as `--q-<token>` for Light, Dark and both\n"
    out += "/// Increase Contrast variants (media queries and the `html.ss-ic` class the app mirrors), the Graphite\n"
    out += "/// substitutions under `html.ss-graphite`, and the type, space, radius, motion and elevation variables.\n"
    out += "/// The specimen's `<style>` head is this exact text.\n"
    out += "public enum QuireCSS {\n"
    out += "    public static let head: String = [\n"
    for line in cssHead(t) { out += "        \(swiftString(line)),\n" }
    out += "    ].joined(separator: \"\\n\")\n\n"
    out += "    /// The type variables at each other Text size (spec §4.15), one `html.ss-text-<size>` block per line; the shell and\n"
    out += "    /// every body document carry the reader's class. Not part of the specimen's head.\n"
    out += "    public static let textSizes: String = [\n"
    for line in cssTextSizes(t) { out += "        \(swiftString(line)),\n" }
    out += "    ].joined(separator: \"\\n\")\n\n"
    out += "    /// The file mark (spec §5.57) for the reader's script: `layout.fileMark` (its derived paths included) and the families\n"
    out += "    /// in palette order, as `var SS_FILE_MARK = {…};`. The shell draws the mark as inline SVG from exactly these numbers,\n"
    out += "    /// as `QuireFileMark` does in AppKit, and fills each band with `--q-file-<family>`.\n"
    out += "    public static let fileMarkScript: String = \(swiftString(fileMarkScript(t)))\n\n"
    out += "    /// The theme ids (spec §4.16), in Settings order; the first is the default.\n"
    out += "    public static let themeIDs: [String] = [\(t.themes.map { swiftString($0.id) }.joined(separator: ", "))]\n\n"
    out += "    /// The sheet the reader puts in `<style id=\"ss-theme\">` for theme `id` (spec §4.16): the head's colour selectors,\n"
    out += "    /// in the head's order, holding only the variables that differ from the default theme's, so it goes after the head\n"
    out += "    /// and overrides nothing else. Empty for the default theme and for an id no theme has.\n"
    out += "    public static func themeSheet(_ id: String) -> String {\n"
    out += "        switch id {\n"
    for th in t.themes where !cssThemeSheet(t, th).isEmpty {
        out += "        case \(swiftString(th.id)): return \(memberName(th.id))Sheet\n"
    }
    out += "        default: return \"\"\n"
    out += "        }\n    }\n"
    for th in t.themes {
        let lines = cssThemeSheet(t, th)
        if lines.isEmpty { continue }
        out += "\n    private static let \(memberName(th.id))Sheet: String = [\n"
        for line in lines { out += "        \(swiftString(line)),\n" }
        out += "    ].joined(separator: \"\\n\")\n"
    }
    out += "}\n"
    return out
}

// MARK: - Emitters: tests

func emitContrastTests(_ t: Tokens) -> String {
    let groups: [(String, String, [Pair])] = [("contrastPairs", "testContrastPairs", t.pairs("contrastPairs")),
                                              ("graphiteContrastPairs", "testGraphiteContrastPairs", t.pairs("graphiteContrastPairs"))]
    var out = header + "\nimport XCTest\n@testable import SSDesign\n\n"
    out += "/// Every pair of `contrastPairs` and `graphiteContrastPairs` in all four modes and in every theme (spec §7, §8.7,\n"
    out += "/// §4.16): colours come from the generated providers, with the theme set as an override (Graphite forced off: the\n"
    out += "/// Graphite pairs already name the substituted tokens), and are composited exactly as docs/design/source/build.py\n"
    out += "/// does. A failure here is a token change that broke a pair, never a threshold to relax.\n"
    out += "final class DesignContrastTests: XCTestCase {\n"
    out += "    override func setUp() {\n        super.setUp()\n        QuireTestEnvironment.forceDefaults()\n    }\n\n"
    out += "    override func tearDown() {\n        QuireTestEnvironment.reset()\n        super.tearDown()\n    }\n\n"
    out += "    private func inEveryTheme(_ body: () -> Void) {\n"
    out += "        for theme in QuireTheme.allCases {\n"
    out += "            QuireTestEnvironment.forceDefaults(theme: theme)\n"
    out += "            body()\n"
    out += "        }\n"
    out += "        QuireTestEnvironment.forceDefaults()\n"
    out += "    }\n"
    let chunk = 40
    for (key, prefix, pairs) in groups {
        for start in stride(from: 0, to: pairs.count, by: chunk) {
            let end = min(start + chunk, pairs.count)
            out += "\n    /// `\(key)[\(start)..<\(end)]`\n"
            out += "    func \(prefix)\(String(format: "%03d", start))() {\n"
            out += "        inEveryTheme {\n"
            for p in pairs[start..<end] {
                let fg = "[" + p.fg.map(swiftString).joined(separator: ", ") + "]"
                let bg = "[" + p.bg.map(swiftString).joined(separator: ", ") + "]"
                let ic = p.needIC.map { ", needIC: \(swiftNumber($0))" } ?? ""
                out += "            assertContrast(\(swiftString(p.use)), fg: \(fg), bg: \(bg), need: \(swiftNumber(p.need))\(ic))\n"
            }
            out += "        }\n"
            out += "    }\n"
        }
    }
    out += "\n    func testPairCounts() {\n"
    out += "        // tokens.json lists \(groups[0].2.count) contrast pairs and \(groups[1].2.count) Graphite pairs, each asserted in \(t.themes.count) themes; a regenerated\n"
    out += "        // file must keep them all.\n"
    out += "        XCTAssertEqual(DesignTokensFile.shared.pairCount(\"contrastPairs\"), \(groups[0].2.count))\n"
    out += "        XCTAssertEqual(DesignTokensFile.shared.pairCount(\"graphiteContrastPairs\"), \(groups[1].2.count))\n"
    out += "        XCTAssertEqual(QuireTheme.allCases.count, \(t.themes.count))\n"
    out += "    }\n"
    out += "}\n"
    return out
}

func emitAccountPaletteTests(_ t: Tokens) -> String {
    guard let rules = t.root.require("accountRules", "").object else { fail("accountRules must be an object") }
    func rule(_ k: String) -> Double {
        guard let v = rules.first(where: { $0.0 == k })?.1.double else { fail("accountRules.\(k) is missing") }
        return v
    }
    let accountPairs = t.pairs("contrastPairs").filter { $0.fg.count == 1 && $0.fg[0].hasPrefix("account:") }
    guard let inklessFloor = t.root.require("themeRules", "")["inklessAccentVsAccountMinDE00"]?.double else { fail("themeRules.inklessAccentVsAccountMinDE00 is missing") }
    var out = header + "\nimport XCTest\n@testable import SSDesign\n\n"
    out += "/// The account palette's rules (`accountRules`, spec §4.2, §8.7) in every theme (§4.16): Machado 2009 colour-vision\n"
    out += "/// simulation at full severity in linear sRGB, then CIEDE2000, mirroring docs/design/source/build.py. Inks come from\n"
    out += "/// the generated providers, resolved per mode with the theme set as an override.\n"
    out += "final class AccountPaletteTests: XCTestCase {\n"
    out += "    override func setUp() {\n        super.setUp()\n        QuireTestEnvironment.forceDefaults()\n    }\n\n"
    out += "    override func tearDown() {\n        QuireTestEnvironment.reset()\n        super.tearDown()\n    }\n\n"
    out += "    private func inEveryTheme(_ body: (QuireTheme) -> Void) {\n"
    out += "        for theme in QuireTheme.allCases {\n"
    out += "            QuireTestEnvironment.forceDefaults(theme: theme)\n"
    out += "            body(theme)\n"
    out += "        }\n"
    out += "        QuireTestEnvironment.forceDefaults()\n"
    out += "    }\n\n"
    let promised = Int(rule("promisedDistinct"))
    out += "    /// `firstSixMinCVD` \(swiftNumber(rule("firstSixMinCVD"))): the first `promisedDistinct` (\(promised)) inks stay apart for normal vision and every dichromacy.\n"
    out += "    func testPromisedInksStayApartUnderEveryVision() {\n"
    out += "        for mode in QuireMode.allCases {\n"
    out += "            let closest = PaletteMath.closestPair(PaletteMath.accountInks(mode).prefix(\(promised)), kinds: CVDKind.allCases)\n"
    out += "            XCTAssertGreaterThanOrEqual(closest.distance, \(swiftNumber(rule("firstSixMinCVD"))) - 1e-9, \"\\(mode): \\(closest.label)\")\n"
    out += "        }\n    }\n\n"
    out += "    /// `firstSixTargetStandard` \(swiftNumber(rule("firstSixTargetStandard"))): the same floor, raised for the standard-contrast modes.\n"
    out += "    func testPromisedInksMeetTheStandardContrastTarget() {\n"
    out += "        for mode in [QuireMode.light, .dark] {\n"
    out += "            let closest = PaletteMath.closestPair(PaletteMath.accountInks(mode).prefix(\(promised)), kinds: CVDKind.allCases)\n"
    out += "            XCTAssertGreaterThanOrEqual(closest.distance, \(swiftNumber(rule("firstSixTargetStandard"))) - 1e-9, \"\\(mode): \\(closest.label)\")\n"
    out += "        }\n    }\n\n"
    out += "    /// `allTenMinNormal` \(swiftNumber(rule("allTenMinNormal"))): all ten inks stay apart for normal vision.\n"
    out += "    func testAllInksStayApartForNormalVision() {\n"
    out += "        for mode in QuireMode.allCases {\n"
    out += "            let closest = PaletteMath.closestPair(PaletteMath.accountInks(mode)[...], kinds: [.normal])\n"
    out += "            XCTAssertEqual(PaletteMath.accountInks(mode).count, \(t.accounts.count))\n"
    out += "            XCTAssertGreaterThanOrEqual(closest.distance, \(swiftNumber(rule("allTenMinNormal"))) - 1e-9, \"\\(mode): \\(closest.label)\")\n"
    out += "        }\n    }\n\n"
    let refs: [(String, String, String, String)] = [
        ("Accent", "accent", "minFromAccentNormal", "[.normal]"),
        ("DangerUnderEveryVision", "danger", "minFromDangerAnyVision", "CVDKind.allCases"),
        ("Info", "info", "minFromInfoNormal", "[.normal]"),
        ("Star", "star", "minFromStarNormal", "[.normal]"),
    ]
    for (label, token, key, kinds) in refs {
        let floor = token == "accent"
            ? "theme.isInkless ? \(swiftNumber(inklessFloor)) : \(swiftNumber(rule(key)))"
            : swiftNumber(rule(key))
        out += "    /// `\(key)` \(swiftNumber(rule(key))): no ink sits within that distance of `\(token)`, in any theme.\n"
        if token == "accent" {
            out += "    /// An inkless theme's ink is its text ink: the rule is read as under Graphite, and the inks keep\n"
            out += "    /// `themeRules.inklessAccentVsAccountMinDE00` (\(swiftNumber(inklessFloor))) from it instead.\n"
        }
        out += "    func testInksKeepClearOf\(label)() {\n"
        out += "        inEveryTheme { theme in\n"
        out += "            for mode in QuireMode.allCases {\n"
        out += "                let closest = PaletteMath.closestTo(\(swiftString(token)), mode: mode, kinds: \(kinds))\n"
        out += "                XCTAssertGreaterThanOrEqual(closest.distance, \(floor) - 1e-9, \"\\(theme) \\(mode): \\(closest.label)\")\n"
        out += "            }\n"
        out += "        }\n    }\n\n"
    }
    out += "    /// `standardMinContrast` \(swiftNumber(rule("standardMinContrast"))) and `icMinContrast` \(swiftNumber(rule("icMinContrast"))): every surface an account ink is\n"
    out += "    /// drawn on (the account pairs of `contrastPairs`), in every theme, held to the rule's floors rather than the pair's own need.\n"
    out += "    func testInksMeetTheRuleContrastFloors() {\n"
    out += "        inEveryTheme { _ in\n"
    for p in accountPairs {
        let bg = "[" + p.bg.map(swiftString).joined(separator: ", ") + "]"
        out += "            assertContrast(\(swiftString(p.use)), fg: [\(swiftString(p.fg[0]))], bg: \(bg), need: \(swiftNumber(rule("standardMinContrast"))), needIC: \(swiftNumber(rule("icMinContrast"))))\n"
    }
    out += "        }\n"
    out += "    }\n"
    out += "}\n"
    return out
}

/// The theme rules R0–R11 (spec §4.16) for every theme, with `themeRules`' constants and each theme's declared depth
/// written in, so a rule or a value edited in tokens.json without regenerating fails here.
func emitThemeRuleTests(_ t: Tokens) -> String {
    guard let rules = t.root.require("themeRules", "").object else { fail("themeRules must be an object") }
    let lookup = Dictionary(uniqueKeysWithValues: rules)
    func number(_ k: String) -> String { swiftNumber(lookup[k]?.double ?? fail("themeRules.\(k) must be a number")) }
    func strings(_ k: String) -> String {
        "[" + (lookup[k]?.array ?? fail("themeRules.\(k) must be a list")).map { swiftString($0.string ?? fail("themeRules.\(k)")) }.joined(separator: ", ") + "]"
    }
    func modeStrings(_ v: JSON?, _ k: String, list: Bool) -> String {
        guard let v else { fail("\(k) is missing") }
        return "[" + modes.map { m -> String in
            let x = v.require(m, k)
            let literal = list ? "[" + (x.array ?? []).map { swiftString($0.string ?? fail(k)) }.joined(separator: ", ") + "]" : swiftString(x.string ?? fail(k))
            return ".\(m): \(literal)"
        }.joined(separator: ", ") + "]"
    }
    let ratioLock = (lookup["ratioLock"]?.object ?? fail("themeRules.ratioLock must be an object")).map { "(\(swiftString($0.0)), \(swiftString($0.1.string ?? fail("themeRules.ratioLock"))))" }
    var out = header + "\nimport XCTest\n@testable import SSDesign\n\n"
    out += "/// The theme rules (`themeRules`, spec §4.16) for every theme, beside the pairs `DesignContrastTests` asserts in every\n"
    out += "/// theme: the light sheet is the page, the fill stays near the accent asset, the luminance lock and the ratio lock,\n"
    out += "/// the ink against info, the account inks and the meanings, banners, selection, avatar faces, both link flags and the\n"
    out += "/// link colour on a sender's page (`ThemeRuleChecks`, mirroring docs/design/source/theme_rules.py).\n"
    out += "final class ThemeRuleTests: XCTestCase {\n"
    out += "    private let checks = ThemeRuleChecks(rules: .init(\n"
    for k in ["sheetWhiteMaxDE00", "sheetMaxChroma", "focusOnPageMinContrast", "fillVsAccentAssetMaxDE00", "neutralLuminanceTolerance",
              "ratioLockTolerance", "nightInkMinOnFindCurrent", "accentVsInfoMinDE00", "accentVsInfoMinAnyVision", "accentVsAccountMinAnyVision",
              "inklessAccentVsAccountMinDE00", "accentVsMeaningMinDE00", "textVsMeaningMinAnyVision", "bannerVsPageMinDE00",
              "selectionKeyVsIdleMinDE00", "avatarFaceVsSurfaceMinDE00", "linkUnderlineMinDE00", "linkUnderlineMinAnyVision"] {
        out += "        \(k): \(number(k)),\n"
    }
    out += "        neutralTokens: \(strings("neutralTokens")),\n"
    out += "        ratioLock: [\(ratioLock.joined(separator: ", "))],\n"
    out += "        bannerWashes: \(strings("bannerWashes")),\n"
    out += "        avatarSurfaces: \(strings("avatarSurfaces")),\n"
    out += "        pageText: \(modeStrings(lookup["pageText"], "themeRules.pageText", list: true)),\n"
    out += "        accentAsset: \(modeStrings(lookup["accentAsset"], "themeRules.accentAsset", list: false)),\n"
    out += "        linkOnPage: \(modeStrings(t.root["linkOnPage"], "linkOnPage", list: false))))\n"
    for th in t.themes {
        let deeper = modes.filter { !(th.declaredDeeper[$0] ?? []).isEmpty }.map { m in
            ".\(m): [\((th.declaredDeeper[m] ?? []).map(swiftString).joined(separator: ", "))]"
        }
        out += "\n    func test\(typeName(th.id))KeepsEveryThemeRule() {\n"
        out += "        XCTAssertEqual(checks.failures(.\(memberName(th.id)), declaredDeeper: [\(deeper.isEmpty ? ":" : deeper.joined(separator: ", "))]), [])\n"
        out += "    }\n"
    }
    out += "\n    /// R0: every theme has every token in every mode, and the default theme is `color` value for value.\n"
    out += "    func testTheDefaultThemeIsColor() {\n"
    out += "        XCTAssertEqual(QuireTheme.allCases.first, .\(memberName(t.themes[0].id)))\n"
    out += "        for token in QuireColorToken.allCases {\n"
    out += "            XCTAssertEqual(token.values(theme: .\(memberName(t.themes[0].id))), token.values, token.rawValue)\n"
    out += "        }\n"
    out += "    }\n"
    out += "\n    /// The reader offers original colours only in a dark appearance, because the light sheet is the page; a theme that\n"
    out += "    /// tinted its light sheet would need the reader to adapt in light too.\n"
    out += "    func testTheSheetIsThePageExactlyWhenTheModeIsLight() {\n"
    out += "        for theme in QuireTheme.allCases {\n"
    out += "            for mode in QuireMode.allCases { XCTAssertEqual(theme.sheetIsPage(mode), !mode.isDark, \"\\(theme) \\(mode)\") }\n"
    out += "        }\n"
    out += "    }\n"
    out += "}\n"
    return out
}

/// Radii in `layout` that are deliberately off the scale (spec §4.6). tokens.json does not carry this list
/// (docs/design/source/tokens_def.py keeps it as RADIUS_EXCEPTIONS for build.py), so it lives here, pinned
/// to its values: an exception only holds while the metric keeps the listed value.
let radiusExceptions: [(String, Double)] = [("rowCompact.accountSquareRadius", 1.5), ("progress.barRadius", 2), ("fileMark.radius", 2),
                                            ("fileMark.foldRadius", 1)]

func emitRadiusTests(_ t: Tokens) -> String {
    guard let layout = t.root.require("layout", "").object else { fail("layout must be an object") }
    var metrics: [(path: String, swift: String, values: [Double], isList: Bool)] = []
    func walk(_ path: [String], _ swiftPath: [String], _ v: JSON) {
        if let obj = v.object {
            for (k, vv) in obj { walk(path + [k], swiftPath + [typeName(k)], vv) }
            return
        }
        guard let last = path.last, last.contains("adius") else { return }
        let swiftName = (swiftPath.dropLast() + [memberName(last)]).joined(separator: ".")
        if let d = v.double { metrics.append((path.joined(separator: "."), swiftName, [d], false)) }
        if let a = v.array { metrics.append((path.joined(separator: "."), swiftName, a.map { $0.double ?? fail("layout.\(path.joined(separator: ".")) must hold numbers") }, true)) }
    }
    for (k, v) in layout { walk([k], ["Quire.Layout." + typeName(k)], v) }
    for (path, _) in radiusExceptions where !metrics.contains(where: { $0.path == path }) {
        fail("radius exception \(path) is not a layout metric any more: update radiusExceptions in the generator")
    }
    var out = header + "\nimport XCTest\nimport SSDesign\n\n"
    out += "/// Every `radius` metric under `layout` is on the radius scale or a listed exception (spec §4.6, §8.7). The values\n"
    out += "/// are read from the generated `Quire.Layout`, so the test covers what the app draws.\n"
    out += "final class RadiusScaleTests: XCTestCase {\n"
    out += "    /// The exceptions of spec §4.6, each pinned to its value.\n"
    out += "    let exceptions: [String: CGFloat] = [\(radiusExceptions.map { "\(swiftString($0.0)): \(swiftNumber($0.1))" }.joined(separator: ", "))]\n\n"
    out += "    func testEveryLayoutRadiusIsOnTheScale() {\n"
    for m in metrics where !m.path.hasSuffix("pill") {
        if m.isList {
            out += "        for (i, r) in \(m.swift).enumerated() { assertOnScale(\"layout.\(m.path)[\\(i)]\", r) }\n"
        } else {
            out += "        assertOnScale(\"layout.\(m.path)\", \(m.swift))\n"
        }
    }
    out += "    }\n\n"
    out += "    func testTheRadiusMetricsAreAllCovered() {\n"
    out += "        // tokens.json has \(metrics.count) radius metrics under layout; this file asserts each of them.\n"
    out += "        XCTAssertEqual(DesignTokensFile.shared.layoutRadiusPaths().count, \(metrics.count))\n"
    out += "    }\n\n"
    out += "    private func assertOnScale(_ path: String, _ value: CGFloat, file: StaticString = #filePath, line: UInt = #line) {\n"
    out += "        let key = path.hasPrefix(\"layout.\") ? String(path.dropFirst(7)) : path\n"
    out += "        if let pinned = exceptions[key] {\n"
    out += "            XCTAssertEqual(value, pinned, \"\\(path) is a listed exception only at \\(pinned) pt\", file: file, line: line)\n"
    out += "            return\n"
    out += "        }\n"
    out += "        XCTAssertTrue(Quire.Radius.scale.contains(value), \"\\(path) = \\(value) is not on the radius scale \\(Quire.Radius.scale)\", file: file, line: line)\n"
    out += "    }\n"
    out += "}\n"
    return out
}

// MARK: - Emitter: metric drift tests (spec §8.7)

/// Every leaf of `layout`, `border` and `platform` checked against tokens.json at test time, so a value edited in
/// tokens.json without regenerating fails plain `swift test`, not only `--check`.
func emitMetricTests(_ t: Tokens) -> String {
    var functions: [(name: String, lines: [String])] = []
    var total = 0
    func leaves(_ path: [String], _ swiftPath: [String], _ v: JSON, into lines: inout [String]) {
        if let obj = v.object {
            for (k, vv) in obj { leaves(path + [k], swiftPath + [typeName(k)], vv, into: &lines) }
            return
        }
        let dotted = path.joined(separator: ".")
        let swift = (swiftPath.dropLast() + [memberName(path.last!)]).joined(separator: ".")
        total += 1
        switch v {
        case .number:
            lines.append("        number(\(swift), \(swiftString(dotted)))")
        case .string:
            lines.append("        string(\(swift), \(swiftString(dotted)))")
        case .bool:
            lines.append("        bool(\(swift), \(swiftString(dotted)))")
        case .array(let items):
            if items.allSatisfy({ $0.string != nil }) {
                lines.append("        strings(\(swift), \(swiftString(dotted)))")
            } else if items.allSatisfy({ if case .bool = $0 { return true }; return false }) {
                lines.append("        bools(\(swift), \(swiftString(dotted)))")
            } else {
                lines.append("        numbers(\(swift).map { Double($0) }, \(swiftString(dotted)))")
            }
        default:
            fail("\(dotted): no Swift value to check")
        }
    }
    for (top, type) in [("layout", "Quire.Layout"), ("border", "Quire.Border"), ("platform", "Quire.Platform")] {
        guard let obj = t.root.require(top, "").object else { fail("\(top) must be an object") }
        if top == "layout" {
            for (k, v) in obj {
                var lines: [String] = []
                leaves([top, k], [type, typeName(k)], v, into: &lines)
                functions.append(("Layout" + upperFirst(typeName(k)), lines))
            }
        } else {
            var lines: [String] = []
            for (k, v) in obj { leaves([top, k], [type, typeName(k)], v, into: &lines) }
            functions.append((upperFirst(top), lines))
        }
    }
    var out = header + "\nimport XCTest\nimport SSDesign\n\n"
    out += "/// Every metric of `layout`, `border` and `platform` equals its value in docs/design/tokens.json (spec §8.7):\n"
    out += "/// the generated Swift is compared with the file at test time, so editing tokens.json without regenerating fails.\n"
    out += "final class MetricDriftTests: XCTestCase {\n"
    out += "    private let file = DesignTokensFile.shared\n\n"
    out += "    func testEveryMetricIsCovered() {\n"
    out += "        // tokens.json had \(total) leaves under layout, border and platform when this file was generated.\n"
    out += "        XCTAssertEqual(file.leafCount(under: [\"layout\", \"border\", \"platform\"]), \(total), \"regenerate with swift scripts/tools/quire-tokens.swift\")\n"
    out += "    }\n"
    for f in functions {
        out += "\n    func test\(f.name)() {\n"
        out += f.lines.joined(separator: "\n") + "\n"
        out += "    }\n"
    }
    out += """

        private func number<T: BinaryFloatingPoint>(_ value: T, _ path: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(Double(value), self.file.number(path) ?? .nan, accuracy: 1e-9, path, file: file, line: line)
        }

        private func number(_ value: Int, _ path: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(Double(value), self.file.number(path) ?? .nan, path, file: file, line: line)
        }

        private func string(_ value: String, _ path: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(value, self.file.value(path) as? String, path, file: file, line: line)
        }

        private func bool(_ value: Bool, _ path: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(value, self.file.value(path) as? Bool, path, file: file, line: line)
        }

        private func numbers(_ value: [Double], _ path: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(value, (self.file.value(path) as? [NSNumber])?.map(\\.doubleValue), path, file: file, line: line)
        }

        private func strings(_ value: [String], _ path: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(value, self.file.value(path) as? [String], path, file: file, line: line)
        }

        private func bools(_ value: [Bool], _ path: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(value, self.file.value(path) as? [Bool], path, file: file, line: line)
        }
    }

    """
    return out
}

// MARK: - Emitter: accent colour asset (spec §3.1)

func colorsetEntry(_ hex: String, appearances: [(String, String)]) -> String {
    let c = hex2rgba(hex)
    var out = "    {\n"
    if !appearances.isEmpty {
        out += "      \"appearances\" : [\n"
        out += appearances.map { "        {\n          \"appearance\" : \"\($0.0)\",\n          \"value\" : \"\($0.1)\"\n        }" }.joined(separator: ",\n")
        out += "\n      ],\n"
    }
    out += "      \"color\" : {\n"
    out += "        \"color-space\" : \"srgb\",\n"
    out += "        \"components\" : {\n"
    out += "          \"alpha\" : \"\(String(format: "%.3f", c.a))\",\n"
    out += "          \"blue\" : \"\(String(format: "0x%02X", byte255(c.b)))\",\n"
    out += "          \"green\" : \"\(String(format: "0x%02X", byte255(c.g)))\",\n"
    out += "          \"red\" : \"\(String(format: "0x%02X", byte255(c.r)))\"\n"
    out += "        }\n"
    out += "      },\n"
    out += "      \"idiom\" : \"universal\"\n"
    out += "    }"
    return out
}

/// The asset catalog's author field carries the do-not-edit note, because JSON has no comments.
let assetAuthor = "generated by scripts/tools/quire-tokens.swift, do not edit"

func emitAccentColorset(_ t: Tokens) -> String {
    // The fill value: macOS draws white labels on the accent in menu highlights and default buttons (§3.1).
    guard let fill = t.colorByName["accentFill"] else { fail("color.accentFill is missing") }
    let entries = [
        colorsetEntry(fill.values["light"]!, appearances: []),
        colorsetEntry(fill.values["dark"]!, appearances: [("luminosity", "dark")]),
        colorsetEntry(fill.values["lightHC"]!, appearances: [("contrast", "high")]),
        colorsetEntry(fill.values["darkHC"]!, appearances: [("luminosity", "dark"), ("contrast", "high")]),
    ]
    return "{\n  \"colors\" : [\n" + entries.joined(separator: ",\n") + "\n  ],\n  \"info\" : {\n    \"author\" : \"\(assetAuthor)\",\n    \"version\" : 1\n  }\n}\n"
}

func emitAssetCatalogRoot() -> String {
    "{\n  \"info\" : {\n    \"author\" : \"\(assetAuthor)\",\n    \"version\" : 1\n  }\n}\n"
}

// MARK: - Main

var args = Array(CommandLine.arguments.dropFirst())
let check = args.contains("--check")
args.removeAll { $0 == "--check" }
var rootOverride: String?
if let i = args.firstIndex(of: "--root"), i + 1 < args.count { rootOverride = args[i + 1]; args.removeSubrange(i...(i + 1)) }
if let unknown = args.first { fail("unknown argument \(unknown). Usage: swift scripts/tools/quire-tokens.swift [--check] [--root <repo>]") }

func findRoot() -> URL {
    let fm = FileManager.default
    if let r = rootOverride { return URL(fileURLWithPath: r).standardizedFileURL }
    let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
    // The script's own location first (scripts/tools/ → repo), then the working directory and its parents.
    var candidates = [URL(fileURLWithPath: #filePath, relativeTo: cwd).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()]
    var dir = cwd.standardizedFileURL
    while dir.path != "/" { candidates.append(dir); dir = dir.deletingLastPathComponent() }
    for c in candidates where fm.fileExists(atPath: c.appendingPathComponent("docs/design/tokens.json").path) && fm.fileExists(atPath: c.appendingPathComponent("Package.swift").path) {
        return c
    }
    fail("cannot find the repository (no docs/design/tokens.json next to a Package.swift); pass --root")
}

let root = findRoot()
guard let data = FileManager.default.contents(atPath: root.appendingPathComponent("docs/design/tokens.json").path) else { fail("cannot read docs/design/tokens.json") }
var parser = JSONParser(data)
let tokens = Tokens(parser.parse())

let designGenerated = "Sources/SSDesign/Generated"
let testsGenerated = "Tests/SSDesignTests/Generated"
let outputs: [(String, String)] = [
    ("\(designGenerated)/QuireTokensColors.swift", emitColors(tokens)),
    ("\(designGenerated)/QuireTokensPalettes.swift", emitPalettes(tokens)),
    ("\(designGenerated)/QuireTokensTypography.swift", emitTypography(tokens)),
    ("\(designGenerated)/QuireTokensScales.swift", emitScales(tokens)),
    ("\(designGenerated)/QuireTokensLayout.swift", emitLayout(tokens)),
    ("\(designGenerated)/QuireTokensContent.swift", emitContent(tokens)),
    ("\(designGenerated)/QuireTokensThemes.swift", emitThemes(tokens)),
    ("\(designGenerated)/QuireTokensPaperFaces.swift", emitPaperFaces(tokens)),
    ("Sources/SSCore/ConversationSupport/QuireCSS.swift", emitCSS(tokens)),
    ("\(testsGenerated)/DesignContrastTests.swift", emitContrastTests(tokens)),
    ("\(testsGenerated)/AccountPaletteTests.swift", emitAccountPaletteTests(tokens)),
    ("\(testsGenerated)/RadiusScaleTests.swift", emitRadiusTests(tokens)),
    ("\(testsGenerated)/MetricDriftTests.swift", emitMetricTests(tokens)),
    ("\(testsGenerated)/ThemeRuleTests.swift", emitThemeRuleTests(tokens)),
    ("Resources/Assets.xcassets/Contents.json", emitAssetCatalogRoot()),
    ("Resources/Assets.xcassets/AccentColor.colorset/Contents.json", emitAccentColorset(tokens)),
]

let fm = FileManager.default
var stale: [String] = []
var written: [String] = []
let produced = Set(outputs.map { $0.0 })

for (path, content) in outputs {
    let url = root.appendingPathComponent(path)
    let current = fm.contents(atPath: url.path)
    if current == Data(content.utf8) { continue }
    stale.append(path)
    if !check {
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url, options: .atomic)
            written.append(path)
        } catch {
            fail("cannot write \(path): \(error)")
        }
    }
}

// A generated file the generator no longer produces (a renamed kind) would keep compiling stale tokens.
for dir in [designGenerated, testsGenerated] {
    let url = root.appendingPathComponent(dir)
    for name in ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).sorted() where name.hasSuffix(".swift") {
        let path = "\(dir)/\(name)"
        if produced.contains(path) { continue }
        stale.append(path + " (no longer generated)")
        if !check { try? fm.removeItem(at: url.appendingPathComponent(name)); written.append(path + " (removed)") }
    }
}

if check {
    if stale.isEmpty {
        print("quire-tokens: \(outputs.count) generated files are up to date")
        exit(0)
    }
    FileHandle.standardError.write(Data("quire-tokens: out of date (run `swift scripts/tools/quire-tokens.swift`):\n".utf8))
    for s in stale { FileHandle.standardError.write(Data("  \(s)\n".utf8)) }
    exit(1)
}
if written.isEmpty {
    print("quire-tokens: \(outputs.count) generated files already up to date")
} else {
    for w in written { print("quire-tokens: wrote \(w)") }
}
