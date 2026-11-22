import Foundation

/// The design facts a sanitized body carries (`StoredBody.typesetting`, `declaresColors`, `coveredByNewYork`),
/// on their own: what the engine writes back for bodies stored before the facts were kept (DATA-MODEL.md,
/// "Body design facts").
public struct BodyDesignFacts: Hashable, Sendable {
    public var typesetting: BodyTypesetting
    public var declaresColors: Bool
    public var coveredByNewYork: Bool

    public init(typesetting: BodyTypesetting, declaresColors: Bool, coveredByNewYork: Bool) {
        self.typesetting = typesetting
        self.declaresColors = declaresColors
        self.coveredByNewYork = coveredByNewYork
    }

    /// What the reader assumes for a body with no facts: styled, colours declared, coverage unknown. Written
    /// for a row the backfill cannot read, so it leaves the backfill's queue.
    public static let unknown = BodyDesignFacts(typesetting: .styled, declaresColors: true, coveredByNewYork: false)
}
