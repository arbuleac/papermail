import Foundation

/// Which characters New York, the system serif the reader sets plain and unstyled bodies in, draws itself.
///
/// PaperCore cannot reach the font (it is a system design, not a named font, and AppKit is off limits here), so
/// its character set was measured once with `CTFontCopyCharacterSet` and is embedded as a range table.
/// Regenerate it with `swift scripts/tools/newyork-coverage.swift` and paste the output over `ranges`,
/// keeping the comment line it prints, when a macOS release adds scripts to New York.
enum NewYorkCoverage {
    /// Inclusive scalar ranges as flat low/high pairs, ascending and non-overlapping.
    static let ranges: [UInt32] = [
        // .NewYork-Regular, macOS Version 27.0.1 (Build 26A434): 1259 scalars in 99 ranges.
        0x0009, 0x000A, 0x000D, 0x000D, 0x0020, 0x007E, 0x00A0, 0x00AC, 0x00AE, 0x0137, 0x0139, 0x0148, 0x014B, 0x017F,
        0x018F, 0x0190, 0x0192, 0x0192, 0x019F, 0x01A1, 0x01AF, 0x01B0, 0x01C4, 0x01E3, 0x01E5, 0x01ED, 0x01EF, 0x01EF,
        0x01F1, 0x01F5, 0x01F8, 0x021B, 0x021E, 0x021F, 0x0225, 0x0233, 0x0237, 0x0237, 0x0241, 0x0242, 0x0250, 0x02B4,
        0x02B6, 0x02BC, 0x02C6, 0x02C8, 0x02CC, 0x02CC, 0x02D0, 0x02D0, 0x02D8, 0x02DE, 0x02E0, 0x02E9, 0x0300, 0x0304,
        0x0306, 0x030C, 0x030F, 0x030F, 0x0311, 0x0311, 0x031B, 0x031B, 0x031F, 0x0320, 0x0323, 0x032A, 0x032C, 0x0332,
        0x034E, 0x034E, 0x0358, 0x0358, 0x035C, 0x035F, 0x0361, 0x0361, 0x0374, 0x0375, 0x0384, 0x038A, 0x038C, 0x038C,
        0x038E, 0x03A1, 0x03A3, 0x03CE, 0x0400, 0x045F, 0x0462, 0x0463, 0x0473, 0x0477, 0x048A, 0x04B4, 0x04B6, 0x04FF,
        0x0510, 0x0513, 0x051C, 0x051D, 0x0524, 0x0527, 0x052E, 0x052F, 0x0E3F, 0x0E3F, 0x1E00, 0x1E99, 0x1E9E, 0x1E9E,
        0x1EA0, 0x1EF9, 0x2010, 0x2014, 0x2018, 0x201A, 0x201C, 0x201E, 0x2020, 0x2022, 0x2026, 0x2029, 0x2030, 0x2034,
        0x2038, 0x203A, 0x2043, 0x2044, 0x2057, 0x2057, 0x20A1, 0x20AE, 0x20B1, 0x20B5, 0x20B8, 0x20BA, 0x20BC, 0x20BF,
        0x20DD, 0x20DD, 0x2116, 0x2117, 0x2120, 0x2120, 0x2122, 0x2122, 0x2126, 0x2126, 0x212A, 0x212B, 0x2153, 0x2153,
        0x2160, 0x216F, 0x2202, 0x2202, 0x2206, 0x2207, 0x220F, 0x220F, 0x2211, 0x2212, 0x2219, 0x221A, 0x221E, 0x221E,
        0x222B, 0x222B, 0x2236, 0x2236, 0x223C, 0x223C, 0x2248, 0x2248, 0x2260, 0x2262, 0x2264, 0x2265, 0x22C5, 0x22C5,
        0x25CA, 0x25CA, 0x25E6, 0x25E6, 0x2C71, 0x2C71, 0x2E31, 0x2E31, 0xA789, 0xA789, 0xA7AE, 0xA7AE, 0xFB01, 0xFB02,
        0x1F16A, 0x1F16B,
    ]

    static func contains(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        var low = 0
        var high = ranges.count / 2 - 1
        while low <= high {
            let middle = (low + high) / 2
            if value < ranges[middle * 2] {
                high = middle - 1
            } else if value > ranges[middle * 2 + 1] {
                low = middle + 1
            } else {
                return true
            }
        }
        return false
    }

    /// True when New York draws every letter and decimal digit in `text`. Those are what a script is made of;
    /// punctuation, symbols and emoji come from the same system fallback fonts beside either face, so they
    /// never decide between the serif page and its sans twin. Marks are skipped too, because a variation
    /// selector after an emoji is one and says nothing about the script. Emoji are skipped by their emoji
    /// property rather than their category, because U+2139 INFORMATION SOURCE (ℹ️, common in notification
    /// mail) is a lowercase letter by category.
    static func covers(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            // ASCII letters and digits are all covered, and everything else below 0x80 is skipped anyway.
            // (ASCII digits, # and * are emoji too, so the emoji test only runs above it.)
            if scalar.value < 0x80 || contains(scalar) || scalar.properties.isEmoji { continue }
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber:
                return false
            default:
                continue
            }
        }
        return true
    }
}
