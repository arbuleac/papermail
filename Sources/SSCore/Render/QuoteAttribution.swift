import Foundation

/// Recognises the "On <date>, <name> wrote:" line that mail clients put above quoted text, in the handful of
/// languages that account for nearly all traffic. Shared by the HTML and plain-text quote detectors.
enum QuoteAttribution {
    static func isAttributionLine(_ text: String) -> Bool {
        let collapsed = collapseWhitespace(text).lowercased()
        guard collapsed.count >= 8, collapsed.count <= 400 else { return false }
        let hasPrefix = prefixes.contains(where: { collapsed.hasPrefix($0) })
        if suffixes.contains(where: { collapsed.hasSuffix($0) }) {
            if hasPrefix { return true }
            // "Jane Doe (Nov 1, 2026) wrote:" and friends: a date somewhere is enough once the verb matches.
            return collapsed.unicodeScalars.contains(where: URLPolicy.isASCIIDigit)
        }
        // German, Dutch and the Scandinavian clients put the verb before the name ("Am 27.10.2025 um 09:14
        // schrieb Jane Doe <jane@example.com>:"), so the line ends with the name rather than the verb. English is
        // deliberately left out of this form: "On Monday I wrote the plan for 2026:" is ordinary prose.
        guard hasPrefix, collapsed.hasSuffix(":") else { return false }
        guard verbsBeforeName.contains(where: { collapsed.contains(" \($0) ") }) else { return false }
        return collapsed.unicodeScalars.contains(where: URLPolicy.isASCIIDigit)
    }

    private static let suffixes = [
        "wrote:", "wrote :", "schrieb:", "a écrit :", "a écrit:", "escribió:", "escreveu:", "ha scritto:",
        "schreef:", "skrev:", "kirjoitti:", "napisał:", "napsal:", "napsal(a):", "写道：", "寫道：",
    ]

    private static let prefixes = [
        "on ", "am ", "le ", "el ", "il ", "op ", "den ", "w dniu ", "dne ", "em ", "på ", "在",
    ]

    private static let verbsBeforeName = ["schrieb", "schreef", "skrev"]

    static func collapseWhitespace(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace || scalar == "\u{A0}" {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(" "); pendingSpace = false }
                out.append(scalar)
            }
        }
        return String(out)
    }
}
