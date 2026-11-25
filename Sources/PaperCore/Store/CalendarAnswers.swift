import Foundation

/// The rules an invitation answer follows on the calendar (docs/DATA-MODEL.md, "Calendar events" › Answers and
/// "Pending answers win"), as pure functions both stores apply, so `InMemoryMailStore` cannot drift from the SQLite one.
/// An answer's state lives in its operation (`InvitationAnswer.calendar`): the rows it covers, what each said before
/// it. Nothing on `calendar_events` says an answer waits.
enum CalendarAnswers {
    typealias Stored = CalendarEventTable.Stored

    /// An answer's response as a calendar row says it.
    static func response(of answer: InvitationAnswer) -> CalendarEvent.Response? {
        CalendarEvent.Response(rawValue: answer.response.rawValue)
    }

    /// A row an answer may change: the account's, as the provider last reported it, and not the user's own.
    static func isAnswerable(_ row: CalendarEvent, accountID: AccountID) -> Bool {
        row.accountID == accountID && row.sync == .synced && row.response != .organizer
    }

    /// The rows `scope` covers when the answer is queued, among the candidates the store read for it.
    static func covered(_ scope: CalendarCopies.Scope, accountID: AccountID, rows: [Stored]) -> [Stored] {
        let own = rows.filter { isAnswerable($0.event, accountID: accountID) }.sorted { $0.event.id < $1.event.id }
        switch scope {
        case .invitation(let uid, let near):
            let matching = own.filter { InvitationUID.matches($0.event.invitationUID, uid) }
            guard let near else { return matching }
            // An answer to one occurrence is that occurrence's alone: the one whose start is nearest.
            let distance = { (row: Stored) in abs(row.event.start.timeIntervalSince(near)) }
            return matching.min { distance($0) < distance($1) }.map { [$0] } ?? []
        case .event(let id):
            return own.filter { $0.event.id == id }
        case .series(let id):
            return own.filter { $0.event.seriesID == id }
        }
    }

    /// What a first enqueue of `answer` writes, in its transaction: the answer with `previous` filled (every row covered,
    /// with the answer it had), and the covered rows whose answer changes. Nil when the answer has no calendar part or was
    /// queued before (`previous` already written: a re-save never recomputes it).
    static func enqueuing(_ answer: InvitationAnswer, accountID: AccountID,
                          rows: [Stored]) -> (answer: InvitationAnswer, rows: [Stored])? {
        guard var copies = answer.calendar, copies.previous.isEmpty, let response = response(of: answer) else { return nil }
        var changed: [Stored] = []
        for row in covered(copies.scope, accountID: accountID, rows: rows) {
            copies.previous[row.event.id] = row.event.response
            guard row.event.response != response else { continue }
            var answered = row
            answered.event.response = response
            changed.append(answered)
        }
        var filled = answer
        filled.calendar = copies
        return (filled, changed)
    }

    /// Whether an answer covers a row of its own account: the row is among those it recorded, or its scope takes it (the
    /// event itself, an occurrence of the series, a row of the invitation when it answers every occurrence). A row the
    /// window brought in after the answer was queued is covered by scope without being recorded.
    static func covers(_ answer: InvitationAnswer, _ row: CalendarEvent) -> Bool {
        guard let copies = answer.calendar else { return false }
        if copies.previous[row.id] != nil { return true }
        switch copies.scope {
        case .event(let id):
            return row.id == id
        case .series(let id):
            return row.seriesID == id
        case .invitation(let uid, let near):
            return near == nil && InvitationUID.matches(row.invitationUID, uid)
        }
    }

    /// Pending answers win: a row a read wrote, with the newest live answer that covers it (`live` oldest first) saying
    /// its answer. Every other field comes from the read; the operation is never rewritten by a read, since the outbox
    /// may be holding it.
    static func winning(_ merged: Stored, live: [InvitationAnswer]) -> Stored {
        guard merged.event.sync == .synced, merged.event.response != .organizer,
              let newest = live.last(where: { covers($0, merged.event) }),
              let response = response(of: newest), response != merged.event.response else { return merged }
        var row = merged
        row.event.response = response
        return row
    }

    /// What a give-up of `givenUp` writes, given each row it recorded as the store holds it now and the live answers
    /// of the account queued after it, oldest first: the rows put back, and the newer answers whose `previous` named the
    /// given-up answer, rewritten to name what it replaced (it never went out). A row a newer answer covers is that
    /// answer's; a row a read has since rewritten (it no longer says the given-up answer) keeps the provider's word.
    static func givingBack(_ givenUp: InvitationAnswer, rows: [String: Stored],
                           newer: [(id: String, answer: InvitationAnswer)]) -> (rows: [Stored], rewritten: [(id: String, answer: InvitationAnswer)]) {
        guard let copies = givenUp.calendar, let given = response(of: givenUp) else { return ([], []) }
        var later = newer
        var rewrittenIDs: [String] = []
        var putBack: [Stored] = []
        for (rowID, previous) in copies.previous.sorted(by: { $0.key < $1.key }) {
            guard let current = rows[rowID], current.event.sync == .synced else { continue }
            guard let index = later.firstIndex(where: { covers($0.answer, current.event) }) else {
                guard current.event.response == given, previous != given else { continue }
                var row = current
                row.event.response = previous
                putBack.append(row)
                continue
            }
            guard var newerCopies = later[index].answer.calendar, newerCopies.previous[rowID] == given else { continue }
            newerCopies.previous[rowID] = previous
            later[index].answer.calendar = newerCopies
            if !rewrittenIDs.contains(later[index].id) { rewrittenIDs.append(later[index].id) }
        }
        let rewritten = rewrittenIDs.compactMap { id in later.first { $0.id == id } }
        return (putBack, rewritten)
    }

    /// Where the newest answer covering the row stands, from the account's answers (live and failed), oldest first.
    static func cardAnswer(for row: CalendarEvent, answers: [(status: OperationStatus, answer: InvitationAnswer)]) -> EventAnswerState? {
        guard let newest = answers.last(where: { covers($0.answer, row) }) else { return nil }
        if newest.status.isLive { return .live(newest.answer.response) }
        return newest.status == .failed ? .failed : nil
    }

    /// The answers of the outbox that have a calendar part.
    static func answer(of change: MetadataChange) -> InvitationAnswer? {
        guard case .answerInvitation(let answer) = change, answer.calendar != nil else { return nil }
        return answer
    }
}
