import AppKit
import PaperCore
import PaperDesign

/// What an event's details say (spec §5.54, “Event details”), built from the card's state (`EventCardState`) or the
/// selected mail's pencilled invitation, the mail it came from, the account and the calendar's words. Every word the
/// card shows is made here, so tests read the words without a view.
struct EventDetailsModel {
    /// What a copy button copies, by name: VoiceOver hears the name, never the value.
    enum CopyItem: String, CaseIterable {
        case link, phone, meetingID, passcode

        var tooltip: String {
            switch self {
            case .link: return "Copy Link"
            case .phone: return "Copy Phone Number"
            case .meetingID: return "Copy Meeting ID"
            case .passcode: return "Copy Passcode"
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .link: return "Copy link"
            case .phone: return "Copy phone number"
            case .meetingID: return "Copy meeting ID"
            case .passcode: return "Copy passcode"
            }
        }

        var announcement: String {
            switch self {
            case .link: return "Copied the link."
            case .phone: return "Copied phone number."
            case .meetingID: return "Copied meeting ID."
            case .passcode: return "Copied passcode."
            }
        }

        var action: AnalyticsSignal.EventAction {
            switch self {
            case .link: return .copyLink
            case .phone: return .copyPhone
            case .meetingID: return .copyMeetingID
            case .passcode: return .copyPasscode
            }
        }
    }

    /// A piece of a row's line: words, or a link the card opens through the window's opener.
    struct Piece: Equatable {
        var text: String
        var color: NSColor = .qInk2
        var link: URL?
        /// What a click on the link is, for analytics.
        var action: AnalyticsSignal.EventAction?
        var tooltip: String?
        /// A control of the card rather than a link (Show all): `key` names it.
        var control: String?
    }

    struct Row: Equatable {
        /// Stable across re-applies: what keeps focus on a control the user is on.
        var key: String
        var label: String
        var lines: [[Piece]]
        var copy: (item: CopyItem, value: String)?
        /// At most this many lines of the first piece's text (the place: 4).
        var maxLines: Int = 0

        static func == (lhs: Row, rhs: Row) -> Bool {
            lhs.key == rhs.key && lhs.label == rhs.label && lhs.lines == rhs.lines && lhs.copy?.item == rhs.copy?.item
                && lhs.copy?.value == rhs.copy?.value && lhs.maxLines == rhs.maxLines
        }
    }

    struct MailRow: Equatable {
        var subject: String
        var subjectIsPlaceholder: Bool
        var meta: String
        /// Nil for time set aside whose mail the store no longer has: the row says so and is no button.
        var message: MessageID?
        var accessibilityLabel: String
    }

    enum AnswerLine: Equatable {
        case failed
        case outlookDecline
        case permission(AccountID)
    }

    struct Answers: Equatable {
        var chosen: InvitationResponse?
        /// An answer on its way: the chosen one shows the queued glyph.
        var waiting: Bool
        /// A repeating event: a click asks This Event or All Events.
        var asksSpan: Bool
    }

    enum ActionKind: Equatable {
        case join(URL)
        case remove
        case openIn(URL)
    }

    struct Action: Equatable {
        var key: String
        var title: String
        var variant: QuireButton.Variant
        var symbol: String?
        var kind: ActionKind
    }

    var dot: NSColor?
    var kicker: String
    var isCancelled = false
    var title: String
    var titleIsPlaceholder: Bool
    var when: String
    var elsewhere: String?
    var repeats: String?
    var status: (glyph: String, color: NSColor, text: String)?
    var overlap: String?
    var rows: [Row] = []
    var mail: MailRow?
    var notes: EventNotes?
    /// After cut notes, once expanded: “The rest is in Google Calendar.”
    var notesCutLine: String?
    var answers: Answers?
    var answerLine: AnswerLine?
    var actions: [Action] = []
    var accessibilityName: String
    /// The top as VoiceOver reads it, one line.
    var spokenTop: String
    var spokenElsewhere: String?

    // MARK: Building

    /// What the card is built from.
    struct Inputs {
        var event: CalendarEvent
        var details: CalendarEventDetails?
        var answer: EventAnswerState?
        /// The selected mail's invitation drawn from the mail: the card is its pencil.
        var pencil: CalendarSelection?
        /// The invitation mail found for the event (`RelatedInvitation.pick`), or the pencil's own message.
        var related: RelatedInvitation?
        /// For time set aside: its mail as the store has it, `.some(nil)` once looked up and gone.
        var setAsideMessage: MessageMetadata??
        var accountName: String
        var dot: NSColor?
        var kind: ProviderKind?
        var permissionNeeded = false
        var overlap: String?
        /// The mail row's conversation is the one the reader shows beside the column: no row.
        var selectedConversation: ConversationID?
        var inColumn = true
        var guestsExpanded = false
        var notesExpanded = false
        var text: CalendarText
        var now: Date
    }

    static let titlesOfAnswers: [InvitationResponse: String] = [.accepted: "Accept", .tentative: "Tentative", .declined: "Decline"]
    static let callOnlyPlaces: Set<String> = ["microsoft teams meeting", "google meet", "zoom meeting", "zoom", "webex"]

    init(_ inputs: Inputs) {
        let event = inputs.event
        let details = inputs.details
        let invitation = inputs.pencil?.invitation
        let isPencil = invitation != nil
        let provider = CalendarText.providerCalendarName(inputs.kind)
        let isCancelled = inputs.related?.invitation.isCancelled == true

        // The answer as the card shows it chosen: an answer on its way first, else what the row (or the pencil) says.
        var chosen: InvitationResponse?
        var waiting = false
        if case .live(let response)? = inputs.answer {
            chosen = response
            waiting = true
        } else if let invitation {
            chosen = (inputs.pencil?.invitationReply ?? invitation.userResponse).flatMap { $0.isAnswer ? $0 : nil }
        } else {
            switch event.response {
            case .accepted: chosen = .accepted
            case .tentative: chosen = .tentative
            case .declined: chosen = .declined
            case .needsAction, .organizer: chosen = nil
            }
        }

        // Kicker.
        dot = inputs.dot
        var kicker = [inputs.accountName]
        if isCancelled {
            kicker.append("Cancelled")
        } else {
            if isPencil { kicker.append("Invitation") }
            let isGuest = isPencil ? invitation?.isAnswerable == true : event.response != .organizer
            if isGuest {
                switch chosen {
                case nil, .needsAction?: kicker.append("Not answered")
                case .tentative?: kicker.append("Tentative")
                case .declined?: kicker.append("Declined")
                case .accepted?: break
                }
            }
            if event.isSetAside { kicker.append("Set aside for a mail") }
            switch event.kind {
            case .outOfOffice?: kicker.append("Out of office")
            case .focusTime?: kicker.append("Focus time")
            case .workingElsewhere?: kicker.append("Working elsewhere")
            case nil: if event.isFree, !event.isSetAside { kicker.append("Free") }
            }
        }
        self.kicker = kicker.joined(separator: " · ")
        self.isCancelled = isCancelled

        let rawTitle = invitation?.title ?? event.title
        titleIsPlaceholder = rawTitle.isEmpty
        title = rawTitle.isEmpty ? CalendarText.noTitle : rawTitle
        when = inputs.text.when(event, now: inputs.now)
        accessibilityName = isCancelled ? "Cancelled event: " + title : isPencil ? "Invitation: " + title : title

        // Elsewhere: the time where it was written, when that zone's offset differs from this Mac's.
        let zoneName = event.timeZone ?? invitation?.timeZoneID
        if !event.isAllDay, let zoneName, let zone = TimeZone(identifier: zoneName),
           zone.secondsFromGMT(for: event.start) != inputs.text.calendar.timeZone.secondsFromGMT(for: event.start) {
            var there = inputs.text.calendar
            there.timeZone = zone
            let words = CalendarText(calendar: there).when(event, now: inputs.now)
            let generic = zone.localizedName(for: .generic, locale: .current) ?? zone.identifier
            elsewhere = words + " " + generic
            spokenElsewhere = "In " + generic + ", " + CalendarText(calendar: there).longDay(event.start) + ", "
                + CalendarText(calendar: there).spokenRange(event.start, event.end)
        }

        if event.seriesID != nil {
            repeats = details?.repeats ?? "Repeats"
        } else if let pencilRepeats = invitation?.repeats {
            repeats = pencilRepeats
        }

        if event.isSetAside {
            if event.sync == .creating {
                status = (Quire.Icon.pending, .qInk2, "Waiting to reach " + provider)
            } else if event.sync == .failed {
                status = (Quire.Icon.failed, .qDanger, "Couldn't add this to " + provider + ".")
            }
        }

        // Answers.
        let canAnswer: Bool
        if let invitation {
            canAnswer = invitation.isAnswerable && !isCancelled
        } else {
            canAnswer = event.sync == .synced && event.providerID != nil && event.response != .organizer && !event.isSetAside
                && event.kind == nil && !isCancelled
        }
        if canAnswer {
            let asksSpan: Bool
            if isPencil || event.seriesID == nil {
                asksSpan = false
            } else if let recurrence = inputs.related?.invitation.recurrenceID,
                      abs(recurrence.timeIntervalSince(event.originalStart ?? event.start)) <= 1 {
                asksSpan = false
            } else {
                asksSpan = true
            }
            answers = Answers(chosen: chosen, waiting: waiting, asksSpan: asksSpan)
            if inputs.answer == .failed {
                answerLine = .failed
            } else if waiting, inputs.permissionNeeded {
                answerLine = .permission(event.accountID)
            } else if inputs.kind == .microsoft, chosen == .declined, !isPencil {
                answerLine = .outlookDecline
            }
            if chosen != .declined, !event.isAllDay { overlap = inputs.overlap }
        }

        rows = Self.rows(inputs, isPencil: isPencil)
        mail = Self.mailRow(inputs)
        if !event.isSetAside, !isPencil, let notes = details?.notes {
            self.notes = notes
            if notes.isCut, inputs.notesExpanded { notesCutLine = "The rest is in " + provider + "." }
        }

        // Actions.
        var actions: [Action] = []
        if let join = Self.joinAddress(inputs).flatMap(EventLinkPolicy.web) {
            actions.append(Action(key: "footer.join", title: "Join", variant: .primary, symbol: Quire.Icon.joinCall, kind: .join(join)))
        }
        if event.isSetAside {
            actions.append(Action(key: "footer.remove", title: "Remove", variant: .secondary, symbol: nil, kind: .remove))
        }
        if !isPencil, event.sync != .creating, event.sync != .failed, let web = EventLinkPolicy.web(event.webURL) {
            actions.append(Action(key: "footer.openIn", title: "Open in " + provider, variant: .link, symbol: nil, kind: .openIn(web)))
        }
        self.actions = actions

        // The top as one line for VoiceOver.
        let kickerSpoken = ([inputs.accountName] + kicker.dropFirst().map { $0.lowercased() }).joined(separator: ", ")
        let range = event.isAllDay ? "all day"
            : inputs.text.spokenRange(event.start, event.end)
        spokenTop = kickerSpoken + ". " + title + ". " + inputs.text.longDay(event.start) + ", " + range + "."
    }

    /// The call's join address: the row's (https), else one the notes name on a known call host; a pencil's meeting link.
    static func joinAddress(_ inputs: Inputs) -> String? {
        if let invitation = inputs.pencil?.invitation { return invitation.conferenceURL.flatMap { EventLinkPolicy.web($0) == nil ? nil : $0 } }
        if let join = inputs.event.joinURL, EventLinkPolicy.web(join) != nil { return join }
        return inputs.details?.call?.joinURL
    }

    // MARK: Rows

    private static func rows(_ inputs: Inputs, isPencil: Bool) -> [Row] {
        let event = inputs.event
        if event.isSetAside { return [] }
        let details = inputs.details
        var rows: [Row] = []
        let join = joinAddress(inputs)
        let place = (inputs.pencil?.invitation?.location ?? event.location)?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let place, !place.isEmpty, place != join,
           !(join != nil && callOnlyPlaces.contains(place.lowercased())) {
            let piece: Piece
            if let url = EventLinkPolicy.web(place) {
                piece = Piece(text: place, color: .qAccent, link: url, action: .placeLink, tooltip: place)
            } else {
                piece = Piece(text: place, tooltip: place)
            }
            rows.append(Row(key: "row.where", label: "Where", lines: [[piece]], maxLines: 4))
        }

        if let join {
            let service = CalendarText.serviceName(of: join, stated: event.callService)
            rows.append(Row(key: "row.call", label: "Call", lines: [[Piece(text: service, tooltip: join)]], copy: (.link, join)))
        }

        if let call = details?.call, !isPencil {
            let region = Locale.current.region?.identifier
            if let phone = call.phones.first(where: { $0.region != nil && $0.region == region }) ?? call.phones.first {
                var first: [Piece] = []
                if let url = EventLinkPolicy.phoneURL(phone.dial) {
                    first.append(Piece(text: phone.number, color: .qAccent, link: url, action: .phone, tooltip: "Call " + phone.number))
                } else {
                    first.append(Piece(text: phone.number))
                }
                if let region = phone.region { first.append(Piece(text: " (" + region + ")", color: .qInk3)) }
                var lines = [first]
                if let pin = phone.pin, !pin.isEmpty {
                    let label = call.pinLabel == .conferenceID ? "Conference ID " : "PIN "
                    lines.append([Piece(text: label + formattedPIN(pin))])
                }
                if let more = call.morePhonesURL, let url = EventLinkPolicy.web(more) {
                    lines.append([Piece(text: "More phone numbers", color: .qAccent, link: url, action: .morePhones, tooltip: more)])
                }
                rows.append(Row(key: "row.phone", label: "Phone", lines: lines, copy: (.phone, phone.dial)))
            } else if let more = call.morePhonesURL, let url = EventLinkPolicy.web(more) {
                rows.append(Row(key: "row.phone", label: "Phone",
                                lines: [[Piece(text: "More phone numbers", color: .qAccent, link: url, action: .morePhones, tooltip: more)]]))
            }
            if let id = call.meetingID {
                rows.append(Row(key: "row.meetingID", label: "Meeting ID", lines: [[Piece(text: id)]], copy: (.meetingID, id)))
            }
            if let passcode = call.passcode {
                rows.append(Row(key: "row.passcode", label: "Passcode", lines: [[Piece(text: passcode)]], copy: (.passcode, passcode)))
            }
        }

        // Organizer and guests.
        var guests: [EventGuest] = []
        var guestCount = 0
        var answersKnown = false
        var hidden = false
        var userIsOrganizer = false
        var organizer: EmailAddress?
        if let invitation = inputs.pencil?.invitation {
            userIsOrganizer = invitation.userIsOrganizer
            organizer = invitation.organizer.map { EmailAddress(name: $0.name, address: $0.address) }
            let user = invitation.userAddress?.lowercased()
            guests = invitation.attendees
                .filter { $0.address.lowercased() != invitation.organizer?.address.lowercased() }
                .map { EventGuest(name: $0.name, address: $0.address, response: $0.response, isSelf: $0.address.lowercased() == user) }
            guests = guests.filter(\.isSelf) + guests.filter { !$0.isSelf }
            guestCount = guests.count
            answersKnown = true
        } else if let details {
            userIsOrganizer = details.userIsOrganizer
            organizer = details.organizer
            guests = details.guests
            guestCount = max(details.guestCount, details.guests.count)
            answersKnown = details.answersKnown
            hidden = details.guestsHidden
        }
        let others = guests.filter { !$0.isSelf }
        let hasGuests = !others.isEmpty && !hidden
        if userIsOrganizer || event.response == .organizer {
            if hasGuests, !isPencil || userIsOrganizer {
                rows.append(Row(key: "row.organizer", label: "Organizer", lines: [[Piece(text: "You")]]))
            }
        } else if let name = organizer.map({ ($0.name?.isEmpty == false ? $0.name : nil) ?? $0.address }) ?? event.organizer {
            rows.append(Row(key: "row.organizer", label: "Organizer", lines: [[Piece(text: name, tooltip: organizer?.address)]]))
        }
        if hasGuests {
            rows.append(guestRow(guests, count: guestCount, answersKnown: answersKnown, expanded: inputs.guestsExpanded))
        }
        return rows
    }

    /// “601 225 430#”: a PIN of digits alone in threes, with the `#` dialled after it.
    static func formattedPIN(_ pin: String) -> String {
        var written = pin
        if pin.allSatisfy(\.isNumber) {
            var groups: [String] = []
            var rest = Substring(pin)
            while !rest.isEmpty {
                groups.append(String(rest.prefix(3)))
                rest = rest.dropFirst(3)
            }
            written = groups.joined(separator: " ")
        }
        return written.hasSuffix("#") ? written : written + "#"
    }

    private static func name(_ guest: EventGuest) -> String {
        guest.isSelf ? "You" : (guest.name?.isEmpty == false ? guest.name! : guest.address)
    }

    /// §5.54 Guests: by answer, four names a line then “+N more”, Show all when anything is cut.
    static func guestRow(_ guests: [EventGuest], count: Int, answersKnown: Bool, expanded: Bool) -> Row {
        let limit = Int(Quire.Layout.Invitation.attendeesMax)
        var lines: [[Piece]] = []
        var cut = false
        func line(_ prefix: String, _ people: [EventGuest]) {
            guard !people.isEmpty else { return }
            let names = people.map(name)
            var words = names.prefix(expanded ? names.count : limit).joined(separator: ", ")
            if !expanded, names.count > limit {
                words += " +\(names.count - limit) more"
                cut = true
            }
            lines.append([Piece(text: prefix + words)])
        }
        if answersKnown {
            let order: [(String, (EventGuest) -> Bool)] = [
                ("Accepted: ", { $0.response == .accepted }),
                ("Tentative: ", { $0.response == .tentative }),
                ("Not answered: ", { $0.response == .needsAction || $0.response == nil }),
                ("Declined: ", { $0.response == .declined }),
            ]
            for (label, matches) in order {
                let people = guests.filter(matches)
                line(label, people.filter(\.isSelf) + people.filter { !$0.isSelf })
            }
        } else {
            line("", guests.filter(\.isSelf) + guests.filter { !$0.isSelf })
        }
        let unseen = count - guests.count
        if expanded, unseen > 0 { lines.append([Piece(text: "and \(unseen) more", color: .qInk3)]) }
        if cut || unseen > 0 || expanded {
            let title = expanded ? "Show fewer" : "Show all \(max(count, guests.count))"
            if cut || unseen > 0 || (expanded && guests.count > limit) {
                lines.append([Piece(text: title, color: .qAccent, action: .showAllGuests, control: "guests.toggle")])
            }
        }
        return Row(key: "row.guests", label: "Guests", lines: lines)
    }

    // MARK: Mail

    private static func mailRow(_ inputs: Inputs) -> MailRow? {
        let message: MessageMetadata?
        if inputs.event.isSetAside {
            guard let looked = inputs.setAsideMessage else { return nil }
            guard let found = looked else {
                return MailRow(subject: "The mail is no longer on this Mac.", subjectIsPlaceholder: true, meta: "", message: nil,
                               accessibilityLabel: "The mail is no longer on this Mac.")
            }
            message = found
        } else {
            message = inputs.related?.message
        }
        guard let message else { return nil }
        if inputs.inColumn, message.conversationID == inputs.selectedConversation { return nil }
        let subject = message.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let sender = message.from.map { ($0.name?.isEmpty == false ? $0.name! : $0.address) } ?? ""
        var meta = [sender, inputs.text.shortDay(message.date, now: inputs.now)].filter { !$0.isEmpty }.joined(separator: " · ")
        if message.roles.contains(.trash) { meta += " · In the Trash" }
        let shown = subject.isEmpty ? "No subject" : subject
        let spoken = "Show the mail: " + shown + (sender.isEmpty ? "" : ", from " + sender) + ", " + inputs.text.longDay(message.date)
        return MailRow(subject: shown, subjectIsPlaceholder: subject.isEmpty, meta: meta, message: message.id, accessibilityLabel: spoken)
    }

    /// What the details were opened on, for analytics.
    static func kind(of event: CalendarEvent, isPencil: Bool) -> AnalyticsSignal.EventKind {
        if isPencil { return .pencil }
        if event.isSetAside { return .setAside }
        return event.response == .organizer || event.kind != nil ? .own : .invitee
    }
}
