import Foundation

/// What a provider lets one account spend, and what each call the engine makes costs, in the provider's own
/// units. `QuotaBudget` paces the backfill lane by it so the first download stays under the limit instead of
/// running into throttles that throw work away.
struct ProviderQuota: Sendable, Equatable {
    /// The provider's allowance per account per minute.
    var unitsPerMinute: Double
    /// The part of `unitsPerMinute` the backfill may use. The rest is headroom for the live lane, which is
    /// never paced: new mail and the user's own actions must not queue behind older mail.
    var backfillShare: Double = 2.0 / 3.0
    /// One page of the id listing, or one request of a first page that reports the requests it sent
    /// (`BootstrapPage.requestCount`, Graph's).
    var listCost: Double
    /// Metadata for one message fetched by id. A listing that carries metadata inline costs only `listCost`.
    var metadataCostPerMessage: Double
    /// One body, with whatever else hydration fetches alongside it.
    var bodyCost: Double
    /// One attachment the user opens or saves, recorded as live spend like an opened body.
    var attachmentCost: Double = 1
    /// One page of changes since a cursor, or one request of it where the page reports the requests it sent
    /// (`ChangesPage.requestCount`, Graph's).
    var changesCost: Double
    /// How many backfill requests may be in flight at once.
    var maxBackfillConcurrency: Int
    /// Whether the head page and change pages carry each message's metadata (Graph's list and delta pages) rather
    /// than leaving it to be fetched by id at `metadataCostPerMessage` each (Gmail's list and history). When they
    /// do, the live lane records such a page as `listCost` or `changesCost` alone, unless the page reports the
    /// requests its call sent: a head page with `BootstrapPage.requestCount` is recorded as `listCost` per request
    /// (Graph's, which also looks up the system folders and takes the first steps of its folder walk), and a changes
    /// page with `ChangesPage.requestCount` as `changesCost` per request.
    var inlineMetadata = false
    /// What one request to the account's calendar costs on this quota (docs/ARCHITECTURE.md, "Calendar"): Graph's
    /// calendar shares the mailbox's limit, so its reads, creates and deletes are live spend and a throttle on them pauses
    /// the backfill. Nil where the calendar has a quota of its own (Google Calendar's, apart from Gmail's): nothing is
    /// charged, and a throttle there holds back only the calendar.
    var calendarRequestCost: Double?
    /// What the rules lane spends (docs/ARCHITECTURE.md, "Rules"), as live spend: each request of a read of the server
    /// rules, and a create or a delete of one. Both providers' rules share the mail's quota, so a throttle on them pauses
    /// the backfill as any live throttle does.
    var ruleReadCost: Double = 1
    var ruleCreateCost: Double = 1
    var ruleDeleteCost: Double = 1

    static func standard(for kind: ProviderKind) -> ProviderQuota {
        switch kind {
        case .gmail:
            // Gmail's 2026 per-user limit is 6,000 quota units a minute. The costs are Gmail's published
            // per-method units (the Gmail API's "Usage limits" page): messages.list 5, messages.get 20 with
            // format=metadata and 60 with format=full, messages.attachments.get 5, history.list 2. Two requests in
            // flight, because a Gmail batch already carries several calls and more parallel batches only reach the
            // limit sooner. Google Calendar is another API with a quota of its own, so its requests cost nothing here.
            // Filters are Gmail settings, priced per call as mail is: settings.filters.list 1, create and delete 5.
            return ProviderQuota(unitsPerMinute: 6_000, listCost: 5, metadataCostPerMessage: 20, bodyCost: 60,
                                 attachmentCost: 5, changesCost: 2, maxBackfillConcurrency: 2,
                                 ruleReadCost: 1, ruleCreateCost: 5, ruleDeleteCost: 5)
        case .microsoft:
            // Outlook allows 10,000 requests per 10 minutes per app per mailbox, so a unit is one request.
            // Graph counts each request inside a $batch against that limit on its own, so metadata fetched by id
            // costs a request per message even twenty to a $batch; a listing page that returns metadata inline is
            // one request. A body takes the message and its attachment list; an attachment's bytes are one GET of
            // its `$value`. A mailbox allows 4 concurrent requests; the backfill takes 2 so the live lane always has
            // the other 2. The calendar is the same mailbox: a page of its events, a create or a delete is one request.
            // Inbox rules are the same mailbox: a page of them, or a delete, is one request; a create reads the rules
            // first, for the order it goes in, so it is two.
            return ProviderQuota(unitsPerMinute: 1_000, listCost: 1, metadataCostPerMessage: 1, bodyCost: 2,
                                 attachmentCost: 1, changesCost: 1, maxBackfillConcurrency: 2, inlineMetadata: true,
                                 calendarRequestCost: 1, ruleReadCost: 1, ruleCreateCost: 2, ruleDeleteCost: 1)
        }
    }

    /// No limit, for tests and the demo provider: `QuotaBudget` never waits under it, neither for units nor after
    /// a throttle, so a caller that needs a retry delay there keeps its own. The costs stay finite and non-zero so
    /// arithmetic that divides by them stays finite, and concurrency stays bounded so a caller that sizes a worker
    /// pool by it does not start an unbounded number of tasks.
    static let unlimited = ProviderQuota(unitsPerMinute: .infinity, listCost: 1, metadataCostPerMessage: 1, bodyCost: 1,
                                         changesCost: 1, maxBackfillConcurrency: 16)
}
