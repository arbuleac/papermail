import AppKit
import SSCore
import SSDesign

/// Builds `ConversationRowContent` on demand and keeps it keyed by a stable hash of the summary fields that
/// affect the row, the row's context (view, running-head time format, which date the time shows), the current day and the
/// drawing environment: appearance + contrast + Graphite + the Font setting (spec §5.7, §8.2).
/// Window key state is never part of the key: no text colour depends on it (spec §3.4).
@MainActor
final class RowContentCache {
    private let cache = NSCache<NSNumber, ConversationRowContent>()
    private let store: MailStoring
    /// Messages of rows the store does not hold (drafts kept on this Mac); nil defers to the store.
    var localMessages: ((ConversationID) -> [MessageMetadata]?)?
    let formatter: DateFormatting
    private(set) var reference: DateFormatting.Reference
    private let signposter = ListSignposts.signposter
    /// Rows built since the last reset; the list's tests read it to prove j/k never rebuilds a row.
    private(set) var buildCount = 0

    init(store: MailStoring, formatter: DateFormatting = DateFormatting()) {
        self.store = store
        self.formatter = formatter
        reference = formatter.reference()
        // Several screens of rows per loaded page, times a few pages; older versions of a row fall out first.
        cache.countLimit = 6_000
    }

    /// Call once per refresh pass so every row built in that pass agrees on what "today" is.
    func refreshReference(now: Date = Date()) {
        reference = formatter.reference(now: now)
    }

    /// `environment` is the caller's `QuireEnvironment.cacheKey(for:)` plus anything else its strings depend on.
    func content(for summary: ConversationSummary, context: ConversationRowText.Context, environment: String) -> ConversationRowContent {
        let key = NSNumber(value: ConversationRowText.cacheKey(for: summary, dayStamp: reference.dayStamp, context: context,
                                                               environment: environment))
        if let cached = cache.object(forKey: key) { return cached }
        let state = signposter.beginInterval("list.rowBuild")
        defer { signposter.endInterval("list.rowBuild", state) }
        var context = context
        fillPeople(of: summary, into: &context)
        let text = ConversationRowText(summary: summary, reference: reference, formatter: formatter, context: context)
        let content = ConversationRowContent(text: text)
        cache.setObject(content, forKey: key)
        buildCount += 1
        return content
    }

    /// The face shows the newest message's sender and Drafts and Sent rows name recipients; neither is in the
    /// denormalized summary, so a cache miss reads the conversation's messages once. The summary's
    /// `latestMessageID` is in the key, so the read happens once per new message, not per redraw.
    private func fillPeople(of summary: ConversationSummary, into context: inout ConversationRowText.Context) {
        let messages = localMessages?(summary.id) ?? (try? store.messages(in: summary.id)) ?? []
        context.latestSender = ConversationRowText.latestSender(in: messages, ownAddresses: context.ownAddresses)
        if context.kind != .received {
            context.recipients = ConversationRowText.recipients(in: messages, kind: context.kind)
        }
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    func resetBuildCount() {
        buildCount = 0
    }
}
