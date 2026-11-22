import Foundation

/// The text field a write goes into: the quick reply's text view or a composer's body. `AIWriter` runs one write per
/// field at a time. Built from the view itself, so the UI must stop the write before the view goes away (closing the
/// card does), or a new view at the same address would find the field busy.
public struct AIFieldID: Hashable, Sendable {
    private enum Storage: Hashable, Sendable {
        case object(ObjectIdentifier)
        case name(String)
    }

    private let storage: Storage

    public init(_ object: AnyObject) {
        storage = .object(ObjectIdentifier(object))
    }

    /// A named field, for tests and previews.
    public init(name: String) {
        storage = .name(name)
    }
}
