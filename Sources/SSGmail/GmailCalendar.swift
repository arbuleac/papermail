import Foundation
import SSCore
import os

/// The account's main Google Calendar (`calendars/primary`) for the day column and the week (docs/ARCHITECTURE.md,
/// "Calendar"): a read of the window, and the create and delete of time set aside for a mail. Every call goes through
/// the provider's HTTP client (token, one retry on a 401, the shared status mapping); the Calendar API's own 403s for a
/// missing scope and for the API turned off become `CalendarProviderError`. The Calendar API's quota is its own, counted
/// in requests rather than Gmail's units: the provider reports a read's requests (`CalendarListing.requestCount`) and
/// charges nothing itself.
extension GmailProvider: CalendarProvider {
    /// Pages one read takes at most. A listing longer than that is taken as one that never ends, and fails rather than
    /// reporting part of the window as all of it, which would remove the rest from the store. Generous beside the page
    /// size, since Google may hand back a page shorter than asked for (even an empty one) with more to come.
    static let maxCalendarPages = 20
    /// The most `events.list` gives a page (its default is 250): a busy window is one request, not several in a row.
    static let calendarPageSize = 2500
    /// Only the fields `GoogleCalendarMapper` reads: a page of full events carries descriptions and every attendee.
    static let calendarFields = "items(id,status,summary,location,start,end,transparency,attendees(self,responseStatus),"
        + "organizer(self,displayName,email),hangoutLink,conferenceData(entryPoints(entryPointType,uri)),htmlLink,iCalUID,"
        + "updated,eventType,extendedProperties/private),nextPageToken"
    /// The line a block's description starts with, before the subject.
    static let setAsideLead = "Set aside in SuperSparrow for: "
    /// Gmail's web app, where a conversation's link starts.
    static let gmailWebApp = "https://mail.google.com/mail/"

    private static let calendarLog = Logger(subsystem: "io.supersparrow.mac", category: "gmail")

    /// Read from the scopes the token was granted, which come with it: no request.
    public func hasCalendarPermission() async -> Bool {
        OAuthEndpoints.grants(await http.tokens.grantedScopes(for: accountID), .calendar, kind: .gmail)
    }

    public func calendarEvents(in window: DateInterval) async throws -> CalendarListing {
        let mapper = GoogleCalendarMapper(accountID: accountID)
        let bounds = ISO8601DateFormatter()
        var query = [
            // timeMin bounds the end and timeMax the start, so every event that overlaps the window comes back.
            URLQueryItem(name: "timeMin", value: bounds.string(from: window.start)),
            URLQueryItem(name: "timeMax", value: bounds.string(from: window.end)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "showDeleted", value: "false"),
            URLQueryItem(name: "maxResults", value: String(Self.calendarPageSize)),
            URLQueryItem(name: "fields", value: Self.calendarFields),
            // Google indents its JSON unless told not to: whitespace to download and parse every minute.
            URLQueryItem(name: "prettyPrint", value: "false"),
        ]
        var events: [CalendarEvent] = []
        var pages = 0
        var seenTokens: Set<String> = []
        while true {
            let response = try await http.send(try GmailRequest.calendarEvents(query: query), refusal: Self.calendarRefusal)
            pages += 1
            let page = try GmailHTTPClient.decode(GoogleCalendarEventList.self, from: response.data)
            events += (page.items ?? []).compactMap(mapper.event(from:))
            guard let token = page.nextPageToken, !token.isEmpty else { break }
            guard pages < Self.maxCalendarPages, seenTokens.insert(token).inserted else {
                throw ProviderError.decoding("Calendar events: the listing did not end after \(pages) pages")
            }
            query.removeAll { $0.name == "pageToken" }
            query.append(URLQueryItem(name: "pageToken", value: token))
        }
        Self.calendarLog.debug("calendar read: \(events.count, privacy: .public) events in \(pages, privacy: .public) pages")
        return CalendarListing(events: events, requestCount: pages)
    }

    /// The block is created under its client key as its id, so a create replayed after a lost reply answers 409 and
    /// the copy already made is read back instead of a second one made. The key also rides in a private extended
    /// property, which every read reports.
    public func createCalendarEvent(_ event: CalendarEvent) async throws -> CalendarEvent {
        let id = event.clientKey.flatMap { Self.isGoogleEventID($0) ? $0 : nil }
        let title = Self.blockTitle(event.title)
        let link = try await conversationLink(for: event)
        let body = GoogleCalendarEventInsert(
            id: id,
            summary: title,
            description: Self.setAsideDescription(subject: title, conversationLink: link),
            start: Self.calendarTime(event.start, isAllDay: event.isAllDay),
            end: Self.calendarTime(event.end, isAllDay: event.isAllDay),
            transparency: "opaque",
            reminders: GoogleCalendarEventInsert.Reminders(useDefault: false),
            extendedProperties: event.clientKey.map {
                GoogleCalendarEventInsert.ExtendedProperties(privateProperties: [GoogleCalendarMapper.clientKeyProperty: $0])
            }
        )
        let resource: GoogleCalendarEvent
        do {
            let request = try GmailRequest.calendarEvents(method: .post, query: [Self.noUpdates], json: try Self.encodeCalendarBody(body))
            let response = try await http.send(request, refusal: Self.calendarRefusal)
            resource = try GmailHTTPClient.decode(GoogleCalendarEvent.self, from: response.data)
        } catch let error as ProviderError {
            guard case .server(409, _) = error, let id else { throw error }
            // The id is taken, so an earlier attempt made it (client keys are never reused): that copy is the block.
            resource = try await calendarEvent(id: id)
            guard resource.status != "cancelled" else {
                // Deleted since (on the web, a phone): this key cannot make it again.
                throw ProviderError.server(status: 409, message: "The event made under this key has been deleted")
            }
        }
        var created = event
        created.title = title
        created.providerID = resource.id
        created.webURL = GoogleCalendarMapper.secureWebAddress(resource.htmlLink) ?? event.webURL
        created.updatedAt = resource.updated.flatMap(GoogleCalendarMapper(accountID: accountID).instant(_:)) ?? event.updatedAt
        created.invitationUID = resource.iCalUID ?? event.invitationUID
        created.sync = .synced
        return created
    }

    /// An event Google no longer has (404) or has already deleted (410) counts as deleted.
    public func deleteCalendarEvent(providerID: String) async throws {
        do {
            let request = try GmailRequest.calendarEvents(Self.pathComponent(providerID), method: .delete, query: [Self.noUpdates])
            _ = try await http.send(request, refusal: Self.calendarRefusal)
        } catch ProviderError.notFound {
            Self.calendarLog.debug("calendar delete: already gone")
        } catch ProviderError.server(let status, _) where status == 410 {
            Self.calendarLog.debug("calendar delete: already deleted")
        }
    }

    // MARK: Helpers

    /// Nobody is mailed about a block: it has no attendees, and this says so to Google as well.
    private static let noUpdates = URLQueryItem(name: "sendUpdates", value: "none")

    private func calendarEvent(id: String) async throws -> GoogleCalendarEvent {
        let response = try await http.send(try GmailRequest.calendarEvents(Self.pathComponent(id)), refusal: Self.calendarRefusal)
        return try GmailHTTPClient.decode(GoogleCalendarEvent.self, from: response.data)
    }

    /// The Calendar API's refusals the user can act on: a token without the calendar scope (Connect asks for it) and
    /// the API not enabled for the OAuth client (only the Google Cloud console turns it on). A 403 for a rate limit, and
    /// every other status, is left to the shared mapping.
    static func calendarRefusal(status: Int, body: Data) -> Error? {
        guard status == 403 else { return nil }
        let reasons = Set(GoogleErrorReasons.reasons(in: body))
        if !reasons.isDisjoint(with: ["accessNotConfigured", "SERVICE_DISABLED"]) { return CalendarProviderError.apiDisabled }
        if !reasons.isDisjoint(with: ["insufficientPermissions", "ACCESS_TOKEN_SCOPE_INSUFFICIENT"]) {
            return CalendarProviderError.permissionMissing
        }
        return nil
    }

    /// The link back to the mail: Gmail's web address of its conversation. The engine hands the thread id over
    /// (`CalendarEvent.sourceThreadID`, from the store), so a create costs no request of its own. Only when it did not
    /// (an older row) is the thread asked of Gmail, one `messages.get` of two fields. Without it the description is the
    /// sentence alone: the block matters more than its link, so Gmail's refusal here never fails the create; a token
    /// refused, or one that cannot be had, fails it, as it would fail the create itself.
    private func conversationLink(for event: CalendarEvent) async throws -> String? {
        if let thread = event.sourceThreadID, Self.isThreadID(thread) {
            return Self.conversationLink(thread: thread, accountEmail: accountEmail)
        }
        guard let message = event.sourceMessage, message.accountID == accountID, !message.providerID.isEmpty else { return nil }
        let query = [URLQueryItem(name: "format", value: "minimal"), URLQueryItem(name: "fields", value: "id,threadId")]
        do {
            let request = try GmailRequest.get("messages/" + Self.pathComponent(message.providerID), query: query, kind: .message)
            let reference = try await http.json(GmailMessageRef.self, for: request)
            guard let thread = reference.threadId, Self.isThreadID(thread) else { return nil }
            return Self.conversationLink(thread: thread, accountEmail: accountEmail)
        } catch let error as ProviderError {
            switch error {
            case .unauthorized, .cancelled:
                throw error
            default:
                Self.calendarLog.notice("calendar create: no link back to the mail: \(String(describing: error), privacy: .private)")
                return nil
            }
        }
    }

    /// Gmail's thread ids are hexadecimal; anything else is not one, and never goes into a link.
    static func isThreadID(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    /// The conversation in Gmail's web app, in the block's own account: `authuser` names the account by its address,
    /// so a browser signed in to several Google accounts opens this one rather than the first signed in (where the
    /// thread is not found), and one not signed in to it is asked for that account. `authuser` rather than the path
    /// form `/mail/u/<address>/`: it is the account selector every Google site reads, documented and taken before Gmail
    /// loads, where the path form is Gmail's own; the fragment rides through Google's redirect to `/mail/u/<n>/`.
    /// Without an address (a provider made only to sign in) the link opens the browser's first account.
    static func conversationLink(thread: String, accountEmail: String?) -> String {
        let account = accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
            .addingPercentEncoding(withAllowedCharacters: unreservedASCII) ?? ""
        return gmailWebApp + (account.isEmpty ? "" : "?authuser=" + account) + "#all/" + thread
    }

    /// RFC 3986's unreserved characters, ASCII only: `@` and `+` of an address are escaped, and so is any letter
    /// beyond ASCII, which `CharacterSet.alphanumerics` would let through.
    private static let unreservedASCII = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// The block's title: the conversation's subject on one line, "No subject" when it has none (the app names it so
    /// already; a blank title would leave Google's own "(No title)" on the user's calendar).
    static func blockTitle(_ subject: String) -> String {
        let flat = subject.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.isEmpty ? noSubject : flat
    }

    static let noSubject = "No subject"

    /// One plain line (docs/ARCHITECTURE.md, "Calendar"): the sentence naming the mail, then its link when there is one.
    static func setAsideDescription(subject: String, conversationLink: String?) -> String {
        [setAsideLead + subject, conversationLink].compactMap { $0 }.joined(separator: " ")
    }

    /// Google's event ids: 5 to 1,024 characters of base32hex (`0-9`, `a-v`). `CalendarEvent.newClientKey()` makes
    /// 32 lowercase hexadecimal digits, which are.
    static func isGoogleEventID(_ value: String) -> Bool {
        (5...1024).contains(value.count) && value.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."v").contains($0) }
    }

    /// A timed instant in UTC (`dateTime`); an all-day date as the day its floating UTC midnight names (`date`).
    static func calendarTime(_ date: Date, isAllDay: Bool) -> GoogleCalendarEvent.Time {
        let formatter = ISO8601DateFormatter()
        guard isAllDay else { return GoogleCalendarEvent.Time(dateTime: formatter.string(from: date)) }
        formatter.formatOptions = [.withFullDate]
        return GoogleCalendarEvent.Time(date: formatter.string(from: date))
    }

    private static func encodeCalendarBody(_ body: GoogleCalendarEventInsert) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        do {
            return try encoder.encode(body)
        } catch {
            throw ProviderError.decoding("Could not encode the calendar event: \(error)")
        }
    }
}
