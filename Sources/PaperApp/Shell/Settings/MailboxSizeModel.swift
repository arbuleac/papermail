import Foundation

/// Settings › General › Keep mail on this Mac: the mailbox's size on disk beside the popup, in plain words (“292 MB”,
/// spec §5.40). Measured off the main thread whenever the tab appears, the window reopens on it, and the engine reports
/// a sweep or a trim while the window is open; never on a timer. Nothing shows until the first answer.
@MainActor
final class MailboxSizeModel: ObservableObject {
    @Published private(set) var bytes: Int64?
    private let measure: @Sendable () -> Int64
    /// Bumped by every request, so a slow measurement arriving late never overwrites a newer one.
    private var generation = 0

    /// `measure` reads the file system; it runs on a background task, never on the main thread.
    init(measure: @escaping @Sendable () -> Int64) {
        self.measure = measure
    }

    /// The size as the row shows it, nil until measured.
    var label: String? {
        bytes.map(Self.words)
    }

    /// Decimal units, as Finder counts: 292,000,000 bytes is “292 MB”.
    nonisolated static func words(for bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: max(0, bytes))
    }

    func refresh() {
        generation += 1
        let asked = generation
        let measure = measure
        Task { [weak self] in
            let measured = await Task.detached(priority: .utility) { measure() }.value
            guard let self, self.generation == asked else { return }
            self.bytes = measured
        }
    }
}
