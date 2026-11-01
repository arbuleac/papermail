import Foundation

/// Fixed colors handed to accounts in the order they are added, so an account's dot looks the same on every
/// launch and the first two accounts always get clearly different hues.
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
}
