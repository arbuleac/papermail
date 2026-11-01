import AppKit
import SSCore

/// Builds `ConversationRowContent` on demand and keeps it keyed by a stable hash of the summary fields that
/// affect the row plus the current day, so a row is formatted once per version and once per calendar day.
@MainActor
final class RowContentCache {
    private let cache = NSCache<NSNumber, ConversationRowContent>()
    private let formatter: DateFormatting
    private(set) var reference: DateFormatting.Reference
    private let signposter = ListSignposts.signposter

    init(formatter: DateFormatting = DateFormatting()) {
        self.formatter = formatter
        reference = formatter.reference()
        // Several screens of rows per loaded page, times a few pages; older versions of a row fall out first.
        cache.countLimit = 6_000
    }

    /// Call once per refresh pass so every row built in that pass agrees on what "today" is.
    func refreshReference(now: Date = Date()) {
        reference = formatter.reference(now: now)
    }

    func content(for summary: ConversationSummary) -> ConversationRowContent {
        let key = NSNumber(value: ConversationRowText.cacheKey(for: summary, dayStamp: reference.dayStamp))
        if let cached = cache.object(forKey: key) { return cached }
        let state = signposter.beginInterval("list.rowBuild")
        let text = ConversationRowText(summary: summary, reference: reference, formatter: formatter)
        let content = ConversationRowContent(text: text, summary: summary)
        signposter.endInterval("list.rowBuild", state)
        cache.setObject(content, forKey: key)
        return content
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
