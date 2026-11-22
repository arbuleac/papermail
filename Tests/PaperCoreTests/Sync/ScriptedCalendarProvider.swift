import Foundation
@testable import PaperCore

/// A `ScriptedProvider` with a calendar (`CalendarProvider`), so the engine gives its account a calendar lane. It keeps a
/// calendar of its own: a create adds to it, idempotent by client key as Google's ids and Graph's `transactionId` make
/// it, a delete takes from it, and a read lists what overlaps the window, reporting each block's client key back. Scripts
/// fail a call before it does anything, or a create after its copy is made (the reply lost); holds keep a call waiting.
/// Every call is recorded.
final class ScriptedCalendarProvider: ScriptedProvider, CalendarProvider, @unchecked Sendable {
    enum CreateScript {
        /// Makes the copy, or finds the one its client key made, and returns it.
        case make
        /// Throws before anything is made.
        case fail(Error)
        /// Makes the copy, then throws: the provider has it, the engine never heard.
        case loseReply(Error)
    }

    // MARK: Scripts

    var grantsCalendar: Bool {
        get { locked { scriptedGrant } }
        set { locked { scriptedGrant = newValue } }
    }
    /// One per read, in order; nil lets that read through. Once empty every read goes through.
    var readResults: [Error?] {
        get { locked { scriptedReads } }
        set { locked { scriptedReads = newValue } }
    }
    /// One per create, in order; once empty every create makes its copy.
    var createScripts: [CreateScript] {
        get { locked { scriptedCreates } }
        set { locked { scriptedCreates = newValue } }
    }
    /// One per delete, in order; nil lets that delete through. Once empty every delete goes through.
    var deleteResults: [Error?] {
        get { locked { scriptedDeletes } }
        set { locked { scriptedDeletes = newValue } }
    }
    /// Creates of these local ids always throw their error, before anything is made: one event the provider keeps
    /// failing (a reply that never reads, a 5xx for that item), whatever the scripts say.
    var stuckCreates: [String: Error] {
        get { locked { scriptedStuck } }
        set { locked { scriptedStuck = newValue } }
    }
    /// The requests each read reports (`CalendarListing.requestCount`).
    var requestsPerRead: Int {
        get { locked { scriptedRequests } }
        set { locked { scriptedRequests = newValue } }
    }
    /// While set, a read records the call and then waits until it is cleared (or the task is cancelled).
    var holdReads: Bool {
        get { locked { scriptedHoldReads } }
        set { locked { scriptedHoldReads = newValue } }
    }
    /// While set, a create records the call and then waits until it is cleared (or the task is cancelled).
    var holdCreates: Bool {
        get { locked { scriptedHoldCreates } }
        set { locked { scriptedHoldCreates = newValue } }
    }
    /// While set, a delete records the call, deletes, and then waits until it is cleared before it answers.
    var holdDeletes: Bool {
        get { locked { scriptedHoldDeletes } }
        set { locked { scriptedHoldDeletes = newValue } }
    }

    private var scriptedGrant = true
    private var scriptedReads: [Error?] = []
    private var scriptedCreates: [CreateScript] = []
    private var scriptedStuck: [String: Error] = [:]
    private var scriptedDeletes: [Error?] = []
    private var scriptedRequests = 1
    private var scriptedHoldReads = false
    private var scriptedHoldCreates = false
    private var scriptedHoldDeletes = false

    // MARK: The provider's calendar

    /// What the provider holds, as it would report it (no local id, no mail).
    var calendar: [CalendarEvent] { locked { held } }
    private var held: [CalendarEvent] = []
    private var made = 0

    /// Puts an event made elsewhere (on the web, a phone, an invitation the provider added) on the calendar. Returns its
    /// provider id.
    @discardableResult
    func seedEvent(_ title: String, start: Date, minutes: Double = 30, invitationUID: String? = nil,
                   response: CalendarEvent.Response = .organizer, clientKey: String? = nil) -> String {
        locked {
            made += 1
            let providerID = "seed-\(made)"
            held.append(CalendarEvent(id: "", accountID: accountID, providerID: providerID, title: title, start: start,
                                      end: start.addingTimeInterval(minutes * 60), response: response,
                                      invitationUID: invitationUID, clientKey: clientKey))
            return providerID
        }
    }

    /// The provider records an answer on its copy of an invitation, as Google and Exchange do once it has gone out.
    func answer(_ providerID: String, _ response: CalendarEvent.Response) {
        locked {
            for index in held.indices where held[index].providerID == providerID { held[index].response = response }
        }
    }

    // MARK: Recordings

    var calendarPermissionChecks: Int { locked { recordedCalendarPermissionChecks } }
    var readWindows: [DateInterval] { locked { recordedReads } }
    var createCalls: [CalendarEvent] { locked { recordedCreates } }
    var deleteCalls: [String] { locked { recordedDeletes } }

    private var recordedCalendarPermissionChecks = 0
    private var recordedReads: [DateInterval] = []
    private var recordedCreates: [CalendarEvent] = []
    private var recordedDeletes: [String] = []

    // MARK: CalendarProvider

    func hasCalendarPermission() async -> Bool {
        locked {
            recordedCalendarPermissionChecks += 1
            return scriptedGrant
        }
    }

    func calendarEvents(in window: DateInterval) async throws -> CalendarListing {
        locked { recordedReads.append(window) }
        while locked({ scriptedHoldReads }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let (failure, events, requests): (Error?, [CalendarEvent], Int) = locked {
            let failure = scriptedReads.isEmpty ? nil : scriptedReads.removeFirst()
            let events = held.filter { $0.overlaps(window) }.map { event -> CalendarEvent in
                var listed = event
                listed.id = CalendarEvent.localID(accountID: accountID, providerID: event.providerID ?? "")
                listed.sync = .synced
                return listed
            }
            return (failure, events, scriptedRequests)
        }
        if let failure { throw failure }
        return CalendarListing(events: events, requestCount: requests)
    }

    func createCalendarEvent(_ event: CalendarEvent) async throws -> CalendarEvent {
        locked { recordedCreates.append(event) }
        while locked({ scriptedHoldCreates }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        if let stuck = locked({ scriptedStuck[event.id] }) { throw stuck }
        let script: CreateScript = locked { scriptedCreates.isEmpty ? .make : scriptedCreates.removeFirst() }
        if case .fail(let error) = script { throw error }
        let copy: CalendarEvent = locked {
            if let key = event.clientKey, let existing = held.first(where: { $0.clientKey == key }) { return existing }
            made += 1
            var copy = event
            copy.id = ""
            copy.providerID = "evt-\(made)"
            copy.webURL = "https://calendar.test/evt-\(made)"
            copy.sourceMessage = nil
            copy.sync = .synced
            held.append(copy)
            return copy
        }
        if case .loseReply(let error) = script { throw error }
        var created = copy
        created.id = event.id
        created.sourceMessage = event.sourceMessage
        return created
    }

    func deleteCalendarEvent(providerID: String) async throws {
        let failure: Error? = locked {
            recordedDeletes.append(providerID)
            return scriptedDeletes.isEmpty ? nil : scriptedDeletes.removeFirst()
        }
        if let failure { throw failure }
        locked { held.removeAll { $0.providerID == providerID } }
        while locked({ scriptedHoldDeletes }) {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func releaseReads() {
        holdReads = false
    }
}
