import Foundation

/// Reader mode's text as set (`ReaderText.render`), kept per text (spec §5.59): a message set again, as a store refresh,
/// a switch back to reader mode, Show text or a print does, costs a lookup instead of a pass over its words. Kept by the
/// text itself (and whether its history folds), so a body fetched again with other words is set again; bounded by the
/// bytes it holds, the oldest going first. Memory only, for the life of the reader that holds it.
public final class ReaderTextCache: @unchecked Sendable {
    /// One text as set, with whether New York draws all of it (`NewYorkCoverage`), worked out in the same miss.
    public struct Setting: Hashable, Sendable {
        public var html: String
        public var hasQuotedContent: Bool
        public var coveredByNewYork: Bool
    }

    private struct Key: Hashable {
        var text: String
        var foldsHistory: Bool
    }

    /// The most text and HTML it holds, in UTF-8 bytes: a few long newsletters, or hundreds of letters.
    public let byteLimit: Int
    private let lock = NSLock()
    private var entries: [Key: Setting] = [:]
    private var order: [Key] = []
    private var bytes = 0
    /// The latest text too long for the limit (a text part of several megabytes; the extracted text and an evicted body's
    /// kept text stop at 200 KB): held alone, beside the limit, so the conversation that shows it pays its pass once and
    /// not at every refresh, while the next long text takes its place.
    private var long: (key: Key, setting: Setting)?

    public init(byteLimit: Int = 8 << 20) {
        self.byteLimit = byteLimit
    }

    /// `ReaderText.render(text, foldsHistory:)` and the text's New York coverage, from the cache when it holds them.
    public func render(_ text: String, foldsHistory: Bool = true) -> Setting {
        let key = Key(text: text, foldsHistory: foldsHistory)
        if let kept = lock.withLock({ entries[key] ?? (long?.key == key ? long?.setting : nil) }) { return kept }
        let set = ReaderText.render(text, foldsHistory: foldsHistory)
        let setting = Setting(html: set.html, hasQuotedContent: set.hasQuotedContent, coveredByNewYork: NewYorkCoverage.covers(text))
        let size = text.utf8.count + set.html.utf8.count
        lock.withLock {
            guard size <= byteLimit else {
                long = (key, setting)
                return
            }
            guard entries[key] == nil else { return }
            entries[key] = setting
            order.append(key)
            bytes += size
            while bytes > byteLimit, !order.isEmpty {
                let oldest = order.removeFirst()
                if let gone = entries.removeValue(forKey: oldest) { bytes -= oldest.text.utf8.count + gone.html.utf8.count }
            }
        }
        return setting
    }

    /// How many texts it holds within its limit (tests).
    public var count: Int { lock.withLock { entries.count } }

    /// Whether it holds a text too long for its limit (tests).
    public var holdsLongText: Bool { lock.withLock { long != nil } }
}
