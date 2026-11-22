import Foundation

/// Reader mode's text as set (`ReaderText.render`), kept per text (spec §5.59): a message set again, as a store refresh,
/// a switch back to reader mode, Show text or a print does, costs a lookup instead of a pass over its words. Kept by the
/// text itself, so a body fetched again with other words is set again; bounded by the bytes it holds, the oldest going
/// first. Memory only, for the life of the reader that holds it.
public final class ReaderTextCache: @unchecked Sendable {
    /// The most text and HTML it holds, in UTF-8 bytes: a few long newsletters, or hundreds of letters.
    public let byteLimit: Int
    private let lock = NSLock()
    private var entries: [String: (html: String, hasQuotedContent: Bool)] = [:]
    private var order: [String] = []
    private var bytes = 0

    public init(byteLimit: Int = 8 << 20) {
        self.byteLimit = byteLimit
    }

    /// `ReaderText.render(text)`, from the cache when it holds it.
    public func render(_ text: String) -> (html: String, hasQuotedContent: Bool) {
        if let kept = lock.withLock({ entries[text] }) { return kept }
        let set = ReaderText.render(text)
        let size = text.utf8.count + set.html.utf8.count
        guard size <= byteLimit else { return set }
        lock.withLock {
            guard entries[text] == nil else { return }
            entries[text] = set
            order.append(text)
            bytes += size
            while bytes > byteLimit, !order.isEmpty {
                let oldest = order.removeFirst()
                if let gone = entries.removeValue(forKey: oldest) { bytes -= oldest.utf8.count + gone.html.utf8.count }
            }
        }
        return set
    }

    /// How many texts it holds (tests).
    public var count: Int { lock.withLock { entries.count } }
}
