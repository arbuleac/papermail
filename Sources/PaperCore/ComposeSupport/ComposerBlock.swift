import Foundation

/// Paragraph-level structure the composer can express. Stored on each paragraph of the composer's
/// attributed string under `ComposerBlock.attributeKey` so the exporter can rebuild lists and quotes
/// without knowing anything about AppKit paragraph styles or text lists.
public enum ComposerBlock: String, Hashable, Sendable, CaseIterable {
    case paragraph
    case bulletItem
    case numberedItem
    case quote

    /// Attribute key whose value is a `ComposerBlock.rawValue`. Paragraphs without it are plain paragraphs.
    public static let attributeKey = NSAttributedString.Key("ss.composer.block")

    /// Reads the block kind stored in an attribute dictionary, tolerating both raw strings and enum values.
    public static func from(attributes: [NSAttributedString.Key: Any]) -> ComposerBlock {
        if let block = attributes[attributeKey] as? ComposerBlock { return block }
        if let raw = attributes[attributeKey] as? String, let block = ComposerBlock(rawValue: raw) { return block }
        return .paragraph
    }

    public var isListItem: Bool {
        self == .bulletItem || self == .numberedItem
    }
}
