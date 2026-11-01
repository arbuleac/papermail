import Foundation

/// Minimal HTML escaping for text the renderer generates itself (plain-text bodies, reply headers).
enum HTMLEscaping {
    /// Escapes text content and attribute values. Quotes are escaped too so one function serves both contexts.
    static func escape(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0 == "&" || $0 == "<" || $0 == ">" || $0 == "\"" || $0 == "'" }) else {
            return text
        }
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out.append(contentsOf: "&amp;".unicodeScalars)
            case "<": out.append(contentsOf: "&lt;".unicodeScalars)
            case ">": out.append(contentsOf: "&gt;".unicodeScalars)
            case "\"": out.append(contentsOf: "&quot;".unicodeScalars)
            case "'": out.append(contentsOf: "&#39;".unicodeScalars)
            default: out.append(scalar)
            }
        }
        return String(out)
    }
}
