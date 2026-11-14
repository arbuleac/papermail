import Foundation

/// What each attachment chip shows while its file is fetched (spec §5.17): nothing for the first 150 ms, so a file
/// already on this Mac never flashes a download; then the contrail, determinate at the latest fraction the download
/// reported, or sweeping while it has reported none (its size is unknown); and the meta again once the fetch ends.
///
/// The reader keeps one and feeds it, on the main thread, the fetch's start, the end of the 150 ms, each fraction
/// and the end; each call returns what the chip should show now, or nil when nothing changes.
public struct AttachmentDownloadBoard: Sendable {
    public enum Display: Equatable, Sendable {
        case sweeping
        case fraction(Double)
        /// The fetch ended: the chip gives the meta back.
        case done
    }

    public struct Chip: Hashable, Sendable {
        public var message: MessageID
        public var attachmentID: String

        public init(message: MessageID, attachmentID: String) {
            self.message = message
            self.attachmentID = attachmentID
        }

        /// Download all on `message` (spec §5.17): its count line shows one progress for every file. No attachment
        /// has an empty id, so this never names a chip.
        public static func allAttachments(of message: MessageID) -> Chip {
            Chip(message: message, attachmentID: "")
        }

        public var isAllAttachments: Bool { attachmentID.isEmpty }
    }

    /// One fetch's claim on its chip.
    public struct Ticket: Hashable, Sendable {
        public let chip: Chip
        fileprivate let serial: UInt64
    }

    /// How long a fetch runs before its chip shows it: as long as spinners wait.
    public static let revealDelay: Duration = .milliseconds(150)

    private struct Entry {
        var serial: UInt64
        var shown = false
        var fraction: Double?
    }

    private var entries: [Chip: Entry] = [:]
    private var nextSerial: UInt64 = 0

    public init() {}

    /// A fetch starts on `chip`. A second fetch of a chip still downloading (Quick Look, then Save As) takes the
    /// chip over where it stands; the first one's events no longer move it.
    public mutating func begin(_ chip: Chip) -> Ticket {
        nextSerial &+= 1
        var entry = entries[chip] ?? Entry(serial: nextSerial)
        entry.serial = nextSerial
        entries[chip] = entry
        return Ticket(chip: chip, serial: nextSerial)
    }

    /// The fetch has run for `revealDelay`: the chip shows the download, determinate when a fraction has come.
    public mutating func reveal(_ ticket: Ticket) -> Display? {
        guard var entry = entries[ticket.chip], entry.serial == ticket.serial, !entry.shown else { return nil }
        entry.shown = true
        entries[ticket.chip] = entry
        return entry.fraction.map(Display.fraction) ?? .sweeping
    }

    /// The download reached `fraction` (0…1). Shown at once when the chip already shows the download; kept for the
    /// reveal when it does not yet. A fraction that does not rise changes nothing.
    public mutating func progress(_ fraction: Double, for ticket: Ticket) -> Display? {
        guard var entry = entries[ticket.chip], entry.serial == ticket.serial else { return nil }
        let clamped = min(1, max(0, fraction))
        if let current = entry.fraction, clamped <= current { return nil }
        entry.fraction = clamped
        entries[ticket.chip] = entry
        return entry.shown ? .fraction(clamped) : nil
    }

    /// The fetch ended, either way: the chip gives the meta back, unless a later fetch has taken it over.
    public mutating func end(_ ticket: Ticket) -> Display? {
        guard let entry = entries[ticket.chip], entry.serial == ticket.serial else { return nil }
        entries[ticket.chip] = nil
        return .done
    }

    /// Whether a fetch is under way on `chip`.
    public func isDownloading(_ chip: Chip) -> Bool {
        entries[chip] != nil
    }

    /// Each file's share of Download all's one progress (spec §5.17), fetched one after another: by listed size, so a
    /// large file moves the contrail as much as it takes time; a file with no listed size counts as the average of the
    /// others, and with no sizes at all each file counts the same. The shares add up to 1.
    public static func batchShares(sizes: [Int]) -> [Double] {
        guard !sizes.isEmpty else { return [] }
        let known = sizes.filter { $0 > 0 }
        let stand = known.isEmpty ? 1 : Double(known.reduce(0, +)) / Double(known.count)
        let weights = sizes.map { $0 > 0 ? Double($0) : stand }
        let total = weights.reduce(0, +)
        return weights.map { $0 / total }
    }

    /// Download all's fraction while file `index` of a batch with `shares` is at `fraction` of its own bytes.
    public static func batchFraction(shares: [Double], index: Int, fraction: Double) -> Double {
        guard shares.indices.contains(index) else { return 1 }
        let before = shares[..<index].reduce(0, +)
        return min(1, before + shares[index] * min(1, max(0, fraction)))
    }
}
