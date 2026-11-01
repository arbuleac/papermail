import Foundation

/// The last few mail actions, newest last. `z` and ⌘Z pop one and apply its inverse.
public struct MailActionUndoStack: Sendable {
    public static let capacity = 20

    public private(set) var records: [MailActionRecord] = []

    public init() {}

    public var isEmpty: Bool { records.isEmpty }
    public var last: MailActionRecord? { records.last }

    public mutating func push(_ record: MailActionRecord) {
        records.append(record)
        if records.count > Self.capacity { records.removeFirst(records.count - Self.capacity) }
    }

    public mutating func pop() -> MailActionRecord? {
        records.popLast()
    }

    public mutating func removeAll() {
        records.removeAll()
    }
}
