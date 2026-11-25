import Foundation
import GRDB

/// SQL for `calendar_event_details` (v25, docs/DATA-MODEL.md): an event's details, upserted by its id, kept until the
/// event goes (the cascade), stale once the event's `version` moves on.
enum CalendarDetailsTable {
    /// The details, nil when there are none or their JSON does not read (a later build's shape this one cannot read).
    static func details(eventID: String, in db: Database) throws -> StoredEventDetails? {
        guard let row = try Row.fetchOne(db.cachedStatement(sql: """
            SELECT version, read_ms, details_json FROM calendar_event_details WHERE event_id = ?
            """), arguments: [eventID]) else { return nil }
        guard let details = try? MailStoreCodec.decode(CalendarEventDetails.self, from: row[2] as String) else { return nil }
        return StoredEventDetails(details: details, version: row[0], readAt: MailStoreCodec.date(row[1]))
    }

    /// Writes nothing and returns false when the event row is gone.
    static func save(_ details: CalendarEventDetails, eventID: String, version: String?, readAt: Date, in db: Database) throws -> Bool {
        let exists = try Bool.fetchOne(db.cachedStatement(sql: "SELECT EXISTS (SELECT 1 FROM calendar_events WHERE id = ?)"),
                                       arguments: [eventID]) ?? false
        guard exists else { return false }
        try db.cachedStatement(sql: """
            INSERT INTO calendar_event_details (event_id, version, read_ms, details_json) VALUES (?, ?, ?, ?)
            ON CONFLICT(event_id) DO UPDATE SET version = excluded.version, read_ms = excluded.read_ms,
                details_json = excluded.details_json
            """).execute(arguments: [eventID, version, MailStoreCodec.milliseconds(readAt), try MailStoreCodec.json(details)])
        return true
    }

    /// The newest stored `repeats` of the account's events of the series read since `since`.
    static func seriesRepeats(accountID: AccountID, seriesID: String, since: Date, in db: Database) throws -> String? {
        let rows = try Row.fetchAll(db.cachedStatement(sql: """
            SELECT d.details_json FROM calendar_events e INDEXED BY calendar_events_by_series
            JOIN calendar_event_details d ON d.event_id = e.id
            WHERE e.account_id = ? AND e.series_id = ? AND d.read_ms >= ?
            ORDER BY d.read_ms DESC
            """), arguments: [accountID.rawValue, seriesID, MailStoreCodec.milliseconds(since)])
        for row in rows {
            if let repeats = (try? MailStoreCodec.decode(CalendarEventDetails.self, from: row[0] as String))?.repeats { return repeats }
        }
        return nil
    }

    /// The account's `synced` provider rows over `interval` whose details are missing or at another version, by start;
    /// time set aside left out. One range of the time index joined to the details by id.
    static func eventsNeedingDetails(accountID: AccountID, in interval: DateInterval, limit: Int,
                                     in db: Database) throws -> [CalendarEvent] {
        let ids = try String.fetchAll(db.cachedStatement(sql: """
            SELECT e.id FROM calendar_events e INDEXED BY calendar_events_by_time
            LEFT JOIN calendar_event_details d ON d.event_id = e.id
            WHERE e.start_ms < ? AND e.end_ms > ? AND e.account_id = ? AND e.sync = 'synced' AND e.provider_id IS NOT NULL
              AND e.source_provider_id IS NULL AND (d.event_id IS NULL OR d.version IS NOT e.version)
            ORDER BY e.start_ms, e.end_ms, e.id LIMIT ?
            """), arguments: [MailStoreCodec.milliseconds(interval.end), MailStoreCodec.milliseconds(interval.start),
                              accountID.rawValue, limit])
        return try ids.compactMap { try CalendarEventTable.stored(id: $0, in: db)?.event }
    }

    /// The failed answers with no message (given from the calendar): what the window toasts about.
    static func failedCalendarAnswers(in db: Database) throws -> Set<String> {
        let rows = try Row.fetchAll(db.cachedStatement(sql: """
            SELECT id, change_json, targets_json FROM operations
            WHERE status = 'failed' AND substr(change_json, 1, 20) = '{"answerInvitation":'
            """))
        var ids: Set<String> = []
        for row in rows where (row[2] as String) == "[]" {
            guard let change = try? MailStoreCodec.decode(MetadataChange.self, from: row[1] as String),
                  CalendarAnswers.answer(of: change)?.calendar?.providerEventID != nil else { continue }
            ids.insert(row[0])
        }
        return ids
    }

    /// The card's state for the event: the row, its details, where the newest answer covering it stands.
    static func cardState(eventID: String, in db: Database) throws -> EventCardState? {
        guard let row = try CalendarEventTable.stored(id: eventID, in: db)?.event else { return nil }
        let answers = try CalendarEventTable.cardAnswers(accountID: row.accountID, in: db)
        return EventCardState(event: row, details: try details(eventID: eventID, in: db),
                              answer: CalendarAnswers.cardAnswer(for: row, answers: answers))
    }
}
