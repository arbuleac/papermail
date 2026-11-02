import Foundation

/// What one Settings account row shows (spec §5.40). Plain values, so SSDesign never sees the mail model; the
/// app maps its accounts into these.
public struct QuireAccountRowContent: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    /// “Gmail”, “Microsoft 365”, or “Demo” in demo mode.
    public var tag: String
    public var address: String
    /// The domain monogram, one or two letters (spec §4.2).
    public var monogram: String
    /// The account's ink slot, 0–9 (`Quire.AccountInk`).
    public var inkSlot: Int
    public var status: QuireAccountStatus

    public init(id: String, name: String, tag: String, address: String, monogram: String, inkSlot: Int,
                status: QuireAccountStatus = .upToDate()) {
        self.id = id
        self.name = name
        self.tag = tag
        self.address = address
        self.monogram = monogram
        self.inkSlot = inkSlot
        self.status = status
    }
}
