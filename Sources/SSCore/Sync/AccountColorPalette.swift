import Foundation

/// Fixed colors for account dots, so an account looks the same on every launch and the first two accounts
/// always get clearly different hues.
enum AccountColorPalette {
    static let hexColors: [String] = [
        "#4A90E2", "#50B86C", "#F5A623", "#D0453B", "#9B59B6",
        "#1ABC9C", "#E67E22", "#E84393", "#607D8B", "#8B572A",
    ]

    static func color(at index: Int) -> String {
        let count = hexColors.count
        let wrapped = ((index % count) + count) % count
        return hexColors[wrapped]
    }

    /// The first color no current account wears, so the slot a removed account freed is reused instead of
    /// the color at the current count, which a remaining account may already have. Wraps once all are taken.
    static func color(avoiding used: [String]) -> String {
        let taken = Set(used.map { $0.uppercased() })
        return hexColors.first { !taken.contains($0.uppercased()) } ?? color(at: used.count)
    }
}
