import Foundation

/// Base direction of a paragraph, decided the way the text system decides a `.natural` paragraph: by its
/// first strong character. Outgoing HTML needs it spelled out as `dir`, because a recipient's client
/// otherwise renders every block left to right.
public enum TextDirection: Sendable {
    case leftToRight
    case rightToLeft

    /// nil when `text` has no strong character (digits, punctuation, blank).
    public static func firstStrong(in text: String) -> TextDirection? {
        for scalar in text.unicodeScalars {
            if isRightToLeft(scalar) { return .rightToLeft }
            if scalar.properties.isAlphabetic { return .leftToRight }
        }
        return nil
    }

    /// The `dir` attribute (with a leading space) a block holding `text` needs; empty for left to right,
    /// which is every client's default, so plain mail keeps its exact markup.
    public static func attribute(for text: String, explicit: TextDirection? = nil) -> String {
        (explicit ?? firstStrong(in: text)) == .rightToLeft ? " dir=\"rtl\"" : ""
    }

    /// Hebrew, Arabic, Syriac, Thaana, NKo, Samaritan, Mandaic and their presentation forms, plus the
    /// historic right-to-left scripts of the supplementary planes.
    private static func isRightToLeft(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF:
            // Combining marks and digits in these blocks are not strong; letters are.
            return scalar.properties.isAlphabetic
        case 0x200F, 0x202B, 0x202E:
            // RLM, RLE, RLO
            return true
        default:
            return false
        }
    }
}
