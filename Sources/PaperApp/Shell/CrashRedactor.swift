import Foundation

/// Takes out of a crash report's text what could say whose Mac it came from or what mail it held: the home folder
/// (paths of the app and of saved files), the account's short name wherever it stands as a word, and anything shaped
/// like an email address. Names from the code, image names and addresses pass through.
struct CrashRedactor: Sendable {
    let homeDirectory: String
    let userName: String

    static let current = CrashRedactor(homeDirectory: NSHomeDirectory(), userName: NSUserName())

    static let homePlaceholder = "~"
    static let userPlaceholder = "<user>"
    static let addressPlaceholder = "<address>"

    private static let address = try! NSRegularExpression(
        pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9\-]+(?:\.[A-Z0-9\-]+)*\.[A-Z]{2,}"#, options: [.caseInsensitive])

    func redact(_ text: String) -> String {
        var result = text
        if homeDirectory.count > 1 {
            result = result.replacingOccurrences(of: homeDirectory, with: Self.homePlaceholder)
        }
        // Any other account's home, as in a path copied from another Mac's report.
        result = result.replacingOccurrences(of: #"/Users/[^/\s"']+"#, with: "/Users/\(Self.userPlaceholder)",
                                             options: .regularExpression)
        let range = NSRange(result.startIndex..., in: result)
        result = Self.address.stringByReplacingMatches(in: result, range: range, withTemplate: Self.addressPlaceholder)
        // The short name as a word of its own ("rboo's MacBook Pro"); too short a name would hit words of the code.
        if userName.count >= 3 {
            let word = #"(?<![A-Za-z0-9_])"# + NSRegularExpression.escapedPattern(for: userName) + #"(?![A-Za-z0-9_])"#
            result = result.replacingOccurrences(of: word, with: Self.userPlaceholder, options: [.regularExpression, .caseInsensitive])
        }
        return result
    }

    /// Strings anywhere inside a JSON-like value (dictionaries, arrays), redacted; everything else as it was.
    func redact(_ value: Any) -> Any {
        switch value {
        case let text as String:
            return redact(text)
        case let array as [Any]:
            return array.map { redact($0) }
        case let dictionary as [String: Any]:
            return dictionary.mapValues { redact($0) }
        default:
            return value
        }
    }
}
