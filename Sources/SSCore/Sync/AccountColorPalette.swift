import Foundation

/// TEMPORARY(quire): the pre-Quire account dot colours, kept only so `Account.colorHex` stays filled while
/// the app still draws it. SSCore carries the palette slot (`Account.inkSlot`, assigned by `AccountInkSlot`);
/// the colours come from SSDesign (`NSColor.qAccount(slot)`). Delete this file, `Account.colorHex` and the
/// `accounts.color_hex` writes once the list, the account strip and Settings draw from the slot.
///
/// It keeps choosing by colour rather than by slot on purpose: existing accounts' slots were backfilled in
/// creation order, which need not match the colours they already wear, and the dots must not change or
/// collide before the app switches over.
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
