import Foundation

/// The calendar half of the local store (docs/DATA-MODEL.md, "Calendar events" and "Mail times"). `MailStoring`
/// refines it, so the UI reads events from the same store it reads mail from, and never from the network.
///
/// Thread-safety and observation follow `MailStoring`: any thread, callbacks on the main thread, the current value
/// first. The defaults below keep nothing; both real stores (`SQLiteMailStore`, `InMemoryMailStore`) implement every
/// requirement, and the contract tests run against both.
public protocol CalendarStoring: AnyObject, Sendable {
    // MARK: Events

    /// Events that overlap `interval`, of `accountIDs` (every account when nil), ordered by start then end then id.
    /// Declined events and events being deleted are included: callers draw only `CalendarEvent.isShown`.
    func calendarEvents(in interval: DateInterval, accountIDs: [AccountID]?) throws -> [CalendarEvent]

    /// `calendarEvents(in:accountIDs:)` for every account, after every change to the events, delivered on the main
    /// thread, the current value first.
    func observeCalendarEvents(in interval: DateInterval,
                               onChange: @escaping @Sendable ([CalendarEvent]) -> Void) -> StoreObservation

    /// Writes what one read of the account's calendar found for `window`, in one transaction: every event is
    /// inserted or replaced by its id, and every `synced` event of the account that overlaps `window` and is not among
    /// them is deleted (the provider no longer has it). Events waiting for the provider are kept as they are: a
    /// `creating` one stays; a `deleting` one stays until the read no longer lists it, and then goes. An event read
    /// with the id of one being deleted keeps `deleting`. A `failed` one, which the provider never had, stays until the
    /// user removes it.
    ///
    /// A read event whose `clientKey` matches a stored row of the account takes that row's local id and
    /// `sourceMessage` (the provider's copy of time set aside on this Mac, created even if the reply to the create was
    /// lost): a `creating` row becomes `synced`; a `deleting` row stays `deleting` with the provider id filled in, so
    /// the engine can delete it. A key claims one row per read: a later event listed with the same key (an occurrence
    /// of a block made repeating elsewhere) is stored under its own id, without the key.
    ///
    /// The account's `synced` events that ended more than 30 days before `CalendarWindow.around(now)` (or before
    /// `window`, when it starts earlier) are deleted too, so history behind the window never piles up.
    func replaceCalendarEvents(_ events: [CalendarEvent], accountID: AccountID, window: DateInterval) throws

    /// Time set aside on this Mac: inserts `event` (its `sync` is `.creating`, its `providerID` nil), which the engine
    /// then creates on the provider. Throws `StoreError.conflict` when the id is taken.
    func addCalendarEvent(_ event: CalendarEvent) throws

    /// Removes an event the user removed: one `failed` goes at once, since the provider never had it; one the
    /// provider has becomes `deleting`, which the engine deletes on the provider. One still `creating` becomes a hidden
    /// `deleting` tombstone with no provider id, under the same id and client key, since its create may have reached the
    /// provider with the reply lost: a read that lists the copy by its key fills in the provider id for the engine to
    /// delete, one that does not sweeps the tombstone, and a create settled meanwhile settles its copy into it. Returns
    /// the event as it was, for an undo; nil when there was no such event.
    @discardableResult
    func removeCalendarEvent(id: String) throws -> CalendarEvent?

    /// Puts back an event `removeCalendarEvent` returned (an undo): a `deleting` row goes back to `synced`, and a
    /// tombstone with no provider id back to `creating` under its own key (a create sent again finds the copy a first
    /// one made); a row that was deleted is inserted again as `creating`, which the engine then creates, under a new
    /// client key (Google keeps a deleted event's id reserved): under its own local id when the provider never had it,
    /// and under a new local id when it did. Returns the row as it now stands.
    @discardableResult
    func restoreCalendarEvent(_ event: CalendarEvent) throws -> CalendarEvent

    /// The account's events waiting for the provider (`creating` or `deleting`), oldest first: what the engine
    /// replays before it reads the account's calendar.
    func pendingCalendarEvents(accountID: AccountID) throws -> [CalendarEvent]

    /// Records what the provider did with a pending event, in one transaction: `created` (the provider's copy, same
    /// local id) replaces a `creating` row, or fills in the provider id of a tombstone (a block removed while it was
    /// being created), which the engine then deletes; nil removes a `deleting` row (the provider deleted it). Returns
    /// false, and changes nothing, when the row has gone or is no longer in the state the call settles: the engine
    /// then deletes a copy it just created.
    @discardableResult
    func settleCalendarEvent(id: String, created: CalendarEvent?) throws -> Bool

    /// Marks a `creating` event the provider refused (`failed`); the UI shows it with the failed mark.
    func failCalendarEvent(id: String) throws

    /// Shows an answer the user gave on this Mac on the account's calendar at once, before the provider has it (store
    /// first): each `synced` event of `accountID` with the invitation's UID (`InvitationUID.matches`) takes `response`,
    /// or only the occurrence whose start is nearest `occurrence` when given (an answer to that occurrence alone). An
    /// event the user organized is left alone. The calendar's next read writes what the provider says.
    func answerCalendarEvents(_ response: CalendarEvent.Response, invitationUID uid: String, accountID: AccountID,
                              near occurrence: Date?) throws

    // MARK: Mail times

    /// Replaces the times found in one message's text, in one transaction (an empty list clears them).
    func saveMailTimes(_ times: [MailTime], for message: MessageID) throws

    /// The times found in the messages of `conversation`, ordered by start.
    func mailTimes(in conversation: ConversationID) throws -> [MailTime]
}

extension CalendarStoring {
    public func calendarEvents(in interval: DateInterval, accountIDs: [AccountID]?) throws -> [CalendarEvent] { [] }

    public func observeCalendarEvents(in interval: DateInterval,
                                      onChange: @escaping @Sendable ([CalendarEvent]) -> Void) -> StoreObservation {
        DispatchQueue.main.async { onChange([]) }
        return StoreObservation {}
    }

    public func replaceCalendarEvents(_ events: [CalendarEvent], accountID: AccountID, window: DateInterval) throws {}
    public func addCalendarEvent(_ event: CalendarEvent) throws {}
    @discardableResult
    public func removeCalendarEvent(id: String) throws -> CalendarEvent? { nil }
    @discardableResult
    public func restoreCalendarEvent(_ event: CalendarEvent) throws -> CalendarEvent { event }
    public func pendingCalendarEvents(accountID: AccountID) throws -> [CalendarEvent] { [] }
    @discardableResult
    public func settleCalendarEvent(id: String, created: CalendarEvent?) throws -> Bool { false }
    public func failCalendarEvent(id: String) throws {}
    public func answerCalendarEvents(_ response: CalendarEvent.Response, invitationUID uid: String, accountID: AccountID,
                                     near occurrence: Date?) throws {}
    public func saveMailTimes(_ times: [MailTime], for message: MessageID) throws {}
    public func mailTimes(in conversation: ConversationID) throws -> [MailTime] { [] }
}
