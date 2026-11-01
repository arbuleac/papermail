import Foundation

/// The edits that turn one ordered list of unique ids into another, in the form `NSTableView` applies them
/// inside `beginUpdates`/`endUpdates`: every step is relative to the list as the previous steps left it.
///
/// Apply `removals` first (they are old indices, descending), then `moves` one at a time (each `from` is the
/// current index, each `to` the index after the move), then `insertions` (new indices, ascending). Elements that
/// keep their relative order are never moved, so a conversation jumping to the top of the inbox costs one move,
/// not a reshuffle of everything above it.
public struct ListDiff<ID: Hashable> {
    public struct Move: Hashable, Sendable {
        public let from: Int
        public let to: Int
        public init(from: Int, to: Int) {
            self.from = from
            self.to = to
        }
    }

    /// Old indices, descending.
    public let removals: [Int]
    /// Parallel to `removals`.
    public let removedIDs: [ID]
    public let moves: [Move]
    /// New indices, ascending.
    public let insertions: [Int]
    /// Parallel to `insertions`.
    public let insertedIDs: [ID]

    public var changeCount: Int { removals.count + moves.count + insertions.count }
    public var isEmpty: Bool { changeCount == 0 }

    public static func compute(old: [ID], new: [ID]) -> ListDiff {
        let newIndexByID = Dictionary(new.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let oldIDs = Set(old)

        var removals: [Int] = []
        var removedIDs: [ID] = []
        var kept: [ID] = []
        kept.reserveCapacity(min(old.count, new.count))
        for (index, id) in old.enumerated() {
            if newIndexByID[id] == nil {
                removals.append(index)
                removedIDs.append(id)
            } else {
                kept.append(id)
            }
        }
        removals.reverse()
        removedIDs.reverse()

        var insertions: [Int] = []
        var insertedIDs: [ID] = []
        var target: [ID] = []
        target.reserveCapacity(kept.count)
        for (index, id) in new.enumerated() {
            if oldIDs.contains(id) {
                target.append(id)
            } else {
                insertions.append(index)
                insertedIDs.append(id)
            }
        }

        return ListDiff(
            removals: removals,
            removedIDs: removedIDs,
            moves: moves(from: kept, to: target),
            insertions: insertions,
            insertedIDs: insertedIDs
        )
    }

    /// The id that should take over the selection when `id` leaves the list: the next surviving row below it,
    /// else the nearest surviving row above it, else the top of the new list. Keeps j/k flowing after an archive.
    public static func successor(ofRemoved id: ID, in old: [ID], new: [ID]) -> ID? {
        guard let index = old.firstIndex(of: id) else { return new.first }
        let survivors = Set(new)
        if let next = old[(index + 1)...].first(where: { survivors.contains($0) }) { return next }
        if let previous = old[..<index].last(where: { survivors.contains($0) }) { return previous }
        return new.first
    }

    /// Replays the edits on `old`. Exists so tests can prove the edit sequence really produces `new`.
    public func applied(to old: [ID]) -> [ID] {
        var current = old
        for index in removals where current.indices.contains(index) {
            current.remove(at: index)
        }
        for move in moves where current.indices.contains(move.from) {
            let id = current.remove(at: move.from)
            current.insert(id, at: min(move.to, current.count))
        }
        for (index, id) in zip(insertions, insertedIDs) {
            current.insert(id, at: min(index, current.count))
        }
        return current
    }

    // MARK: Moves

    /// `kept` and `target` hold the same ids in different orders. Elements on a longest increasing subsequence of
    /// target positions stay put; every other element is moved into place in target order, each one landing
    /// right after its predecessor in `target`, which by then is already in its final relative position.
    private static func moves(from kept: [ID], to target: [ID]) -> [Move] {
        guard kept != target else { return [] }
        let targetPosition = Dictionary(target.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let sequence = kept.compactMap { targetPosition[$0] }
        let stableTargetPositions = Set(longestIncreasingSubsequence(sequence).map { sequence[$0] })

        var current = kept
        var moves: [Move] = []
        for (position, id) in target.enumerated() where !stableTargetPositions.contains(position) {
            guard let from = current.firstIndex(of: id) else { continue }
            current.remove(at: from)
            let to: Int
            if position == 0 {
                to = 0
            } else if let predecessor = current.firstIndex(of: target[position - 1]) {
                to = predecessor + 1
            } else {
                to = current.count
            }
            current.insert(id, at: to)
            moves.append(Move(from: from, to: to))
        }
        return moves
    }

    /// Patience sorting: returns indices into `values` of one longest strictly increasing subsequence.
    private static func longestIncreasingSubsequence(_ values: [Int]) -> [Int] {
        guard !values.isEmpty else { return [] }
        var tails: [Int] = []
        var predecessors = [Int](repeating: -1, count: values.count)
        for (index, value) in values.enumerated() {
            var low = 0
            var high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if values[tails[mid]] < value { low = mid + 1 } else { high = mid }
            }
            if low > 0 { predecessors[index] = tails[low - 1] }
            if low == tails.count { tails.append(index) } else { tails[low] = index }
        }
        var result: [Int] = []
        var cursor = tails.last ?? -1
        while cursor >= 0 {
            result.append(cursor)
            cursor = predecessors[cursor]
        }
        return result.reversed()
    }
}

extension ListDiff: Sendable where ID: Sendable {}
