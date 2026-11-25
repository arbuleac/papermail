import Foundation
import PaperCore

/// Outlook's default calendar (docs/ARCHITECTURE.md, "Calendar"): the window's events through `calendarView`, which
/// expands repeats into their occurrences, and time set aside for a mail, created and deleted on `/me/events`. Every
/// call needs `Calendars.ReadWrite` and counts against the mailbox's request limit as mail does.
extension GraphProvider: CalendarProvider {
    /// `onlineMeeting` whole: `$select` takes top-level properties only. `transactionId` reports a block's client key;
    /// the original zones place an all-day event's dates (`GraphEventTime.allDay`).
    static let calendarSelect = "id,subject,start,end,isAllDay,originalStartTimeZone,originalEndTimeZone,location,showAs,responseStatus,isCancelled,isOrganizer,onlineMeeting,onlineMeetingUrl,webLink,organizer,iCalUId,lastModifiedDateTime,type,transactionId,seriesMasterId,originalStart,changeKey,onlineMeetingProvider"
    /// Graph pages a `calendarView` ten events at a time unless asked. On Outlook's resources `$top` sets the page size,
    /// up to Exchange's cap of a thousand (asking for more is a 400): 999, as message lists ask (`maxListPageSize`), so
    /// a busy window is one request, and the nextLink still carries anything past it.
    static let calendarPageSize = 999
    /// A listing that never ends (a nextLink that keeps coming back) fails rather than spend the mailbox's requests
    /// for ever: 20 pages are some 20,000 events, more than any ten weeks hold, and room for pages Exchange cuts short.
    static let maxCalendarPages = 20
    /// Every event time in UTC: a timed event's `dateTime` is then the instant itself. An all-day event's midnights move
    /// with it, and the mapper reads its dates back in the zone it was made in.
    static let utcEventTimes = "outlook.timezone=\"UTC\""

    /// From the scopes the token came with, as `missingPermission(for:)` decides for an answer: no request.
    public func hasCalendarPermission() async -> Bool {
        OAuthEndpoints.grants(await client.tokens.grantedScopes(for: accountID), .calendar, kind: .microsoft)
    }

    public func calendarEvents(in window: DateInterval) async throws -> CalendarListing {
        do {
            let (events, sent) = try await GraphRequestTally.counting { try await listCalendarView(window) }
            let mapper = GraphCalendarMapper(accountID: accountID)
            return CalendarListing(events: events.compactMap(mapper.event(from:)), requestCount: sent)
        } catch {
            throw await calendarError(error)
        }
    }

    /// What an event's details read selects: the body as Graph gives it (HTML), the people, the call.
    static let detailsSelect = "body,organizer,attendees,isOrganizer,hideAttendees,onlineMeeting,changeKey,seriesMasterId,type"

    /// One GET of the event; with a series whose words are not known, one more of the series master's recurrence. Each is
    /// live spend on the mailbox's quota, counted by the tally as a window read is.
    public func calendarEventDetails(providerID: String, seriesID: String?, knownRepeats: String?,
                                     account: CalendarAccountFacts) async throws -> CalendarDetailsRead? {
        guard !providerID.isEmpty else { return nil }
        do {
            let (read, sent) = try await GraphRequestTally.counting { () -> (GraphEvent, String?)? in
                let url = try GraphURL.make("/me/events/\(providerID)", query: [("$select", Self.detailsSelect)])
                let event: GraphEvent
                do {
                    event = try await client.json(GraphEvent.self, for: GraphRequest(method: .get, url: url, prefer: [Self.utcEventTimes]))
                } catch ProviderError.notFound {
                    return nil
                }
                var repeats = knownRepeats
                if repeats == nil, let master = event.seriesMasterId ?? seriesID, !master.isEmpty {
                    let seriesURL = try GraphURL.make("/me/events/\(master)", query: [("$select", "recurrence,originalStartTimeZone,start")])
                    let series = try? await client.json(GraphEvent.self, for: GraphRequest(method: .get, url: seriesURL,
                                                                                           prefer: [Self.utcEventTimes]))
                    repeats = series.map { Self.repeats(of: $0, account: account) } ?? "Repeats"
                }
                return (event, repeats)
            }
            guard let (event, repeats) = read else { return nil }
            let details = GraphCalendarDetailsMapper.details(from: event, accountEmail: account.email, repeats: repeats)
            return CalendarDetailsRead(details: details, version: event.changeKey, requestCount: sent)
        } catch {
            throw await calendarError(error)
        }
    }

    /// The series' rule in words, said in the zone it was made in (Graph states a repeat's days in that zone).
    static func repeats(of series: GraphEvent, account: CalendarAccountFacts) -> String {
        guard let recurrence = series.recurrence, let rule = GraphInvitationMapper.recurrenceRule(from: recurrence),
              let startValue = series.start, let start = GraphEventTime.read(startValue)?.date else { return "Repeats" }
        let zone = series.originalStartTimeZone.flatMap(CalendarTimeZones.timeZone(named:)) ?? account.timeZone
        return rule.words(start: start, timeZone: zone, locale: account.locale)
    }

    /// Creates the block with its client key as `transactionId`, so a create sent again after a lost reply finds the
    /// copy the first one made instead of making a second. Should Graph refuse the second as a duplicate rather than
    /// hand the copy back, the copy is looked up over the block's own half hour.
    public func createCalendarEvent(_ event: CalendarEvent) async throws -> CalendarEvent {
        do {
            let created: GraphEvent
            do {
                var request = GraphRequest(method: .post, url: try GraphURL.make("/me/events"), prefer: [Self.utcEventTimes])
                request.body = try GraphJSON.encode(GraphEventPayload(event))
                created = try await client.json(GraphEvent.self, for: request)
            } catch let error as ProviderError where Self.mayRefuseADuplicate(error) {
                guard let key = event.clientKey, let copy = try await copy(madeWithKey: key, over: event) else { throw error }
                created = copy
            }
            guard let providerID = created.id, !providerID.isEmpty else {
                throw ProviderError.decoding("GraphEvent: the created event has no id")
            }
            // A reply that does not read as an event still made one: the block keeps its own times until the next read.
            var settled = GraphCalendarMapper(accountID: accountID).event(from: created) ?? event
            settled.id = event.id
            settled.providerID = providerID
            settled.clientKey = event.clientKey
            settled.sourceMessage = event.sourceMessage
            settled.sync = .synced
            return settled
        } catch {
            throw await calendarError(error)
        }
    }

    public func deleteCalendarEvent(providerID: String) async throws {
        // An empty id would name the events collection itself.
        guard !providerID.isEmpty else { return }
        do {
            _ = try await client.send(GraphRequest(method: .delete, url: try GraphURL.make("/me/events/\(providerID)")))
        } catch ProviderError.notFound {
            // Deleted already: in Outlook, on another device, or by this call's first try whose reply was lost.
            return
        } catch {
            throw await calendarError(error)
        }
    }

    private func listCalendarView(_ window: DateInterval) async throws -> [GraphEvent] {
        var next: URL? = try GraphURL.make("/me/calendarView", query: [
            ("startDateTime", GraphDate.string(window.start)),
            ("endDateTime", GraphDate.string(window.end)),
            ("$select", Self.calendarSelect),
            ("$top", String(Self.calendarPageSize)),
        ])
        var all: [GraphEvent] = []
        var pages = 0
        while let url = next {
            guard pages < Self.maxCalendarPages else {
                throw ProviderError.decoding("calendarView: no end after \(Self.maxCalendarPages) pages")
            }
            pages += 1
            // The nextLink keeps the window and the page size but not the headers, so every page asks for UTC again.
            let page = try await client.json(GraphListResponse<GraphEvent>.self,
                                             for: GraphRequest(method: .get, url: url, prefer: [Self.utcEventTimes]))
            all += page.value
            next = try page.nextLink.map(GraphURL.absolute)
        }
        return all
    }

    /// The event a create with `key` made, found over the event's own span (at least a minute, so a block of no length
    /// still overlaps it).
    private func copy(madeWithKey key: String, over event: CalendarEvent) async throws -> GraphEvent? {
        let span = DateInterval(start: event.start, end: max(event.end, event.start.addingTimeInterval(60)))
        return try await listCalendarView(span).first { $0.transactionId == key }
    }

    /// How Graph might refuse a create whose `transactionId` it has seen: a conflict, or a refusal that names it.
    static func mayRefuseADuplicate(_ error: ProviderError) -> Bool {
        guard case .server(let status, let message) = error else { return false }
        return status == 409 || (status == 400 && message.localizedCaseInsensitiveContains("transaction"))
    }

    /// Exchange refuses the calendar (403: ErrorAccessDenied, or Entra's "insufficient privileges") to a token without
    /// `Calendars.ReadWrite`, and Connect asks for it. A token that holds the scope and is refused all the same (a policy
    /// of the organization's) keeps the 403 as a failure: calling it a missing permission would ask the user to connect
    /// again and again to no effect.
    private func calendarError(_ error: Error) async -> Error {
        guard case .server(403, _)? = error as? ProviderError else { return error }
        guard await hasCalendarPermission() else { return CalendarProviderError.permissionMissing }
        Self.folderLog.notice("calendar: refused (HTTP 403) although the token holds the calendar scope")
        return error
    }
}
