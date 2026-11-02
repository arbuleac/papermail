import Foundation

/// The account palette as SSCore sees it: ten numbered slots. The colours behind them belong to the design
/// layer (`NSColor.qAccount(slot)` in SSDesign), so the store and the engine only ever deal in slot numbers.
public enum AccountInkSlot {
    /// Slots run from 0 to `count - 1`.
    public static let count = 10

    public static func isValid(_ slot: Int) -> Bool {
        (0..<count).contains(slot)
    }

    /// The slot a new account takes: the lowest one no account wears, so the slot a removed account freed is
    /// reused before a later one. Once all ten are worn the count wraps: the lowest slot among those worn by
    /// the fewest accounts, which hands out 0, 1, 2… again for the eleventh account onwards.
    /// Out-of-range values in `taken` are ignored.
    public static func next(taken: [Int]) -> Int {
        var wearers = [Int](repeating: 0, count: count)
        for slot in taken where isValid(slot) { wearers[slot] += 1 }
        let fewest = wearers.min() ?? 0
        return wearers.firstIndex(of: fewest) ?? 0
    }
}
