import Foundation
import SSCore

extension GraphProvider {
    /// The waits before the parts the service failed in an apply are sent again, as Gmail's metadata batch retries
    /// its throttled parts: through Exchange's November 2026 outage a part failed now and then, so a second or third
    /// try lands nearly every one, where failing the call sent every part again on the outbox's backoff.
    static let applyRetryDelays: [TimeInterval] = [1, 2]

    /// Replays a local change as PATCHes and moves, 20 messages per `$batch` round trip.
    ///
    /// Every batch goes out, whatever a part of an earlier one answered, except after a throttle or a refused token,
    /// which the next request would meet too. A part the service failed (a 5xx, or a 503 or 504 without Retry-After) is
    /// sent again on its own after `applyRetryDelays`; one Graph refused (a 403, ErrorMoveCopyFailed) is not. What is
    /// still owed then is thrown: the error alone when nothing landed, otherwise a `PartialApplyError` naming the
    /// messages not changed, so the outbox retries and gives up on those alone. The error is the gravest met: a refused
    /// token, then a throttle (the longest Retry-After), then a failed request, then the service, then a refusal.
    public func apply(_ change: MetadataChange, to providerIDs: [String]) async throws {
        // Not a change to messages: the engine sends an unsubscribe request itself.
        if case .unsubscribe = change { return }
        if case .answerInvitation(let answer) = change {
            try await self.answer(answer, messageID: providerIDs.first)
            return
        }
        var seen: Set<String> = []
        let unique = providerIDs.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return }
        var owed = GraphApplyOwed()
        var pending = unique
        var delays = Self.applyRetryDelays[...]
        while true {
            var failing: [String] = []
            for chunk in pending.chunks(of: GraphBatch.maxRequests) {
                guard !owed.stopsTheCall else {
                    owed.unsent += chunk
                    continue
                }
                failing += try await applyChunk(change, chunk, into: &owed)
            }
            guard !failing.isEmpty else { break }
            guard !owed.stopsTheCall, let delay = delays.popFirst() else {
                owed.failing += failing
                break
            }
            try await applyRetryWait(delay)
            pending = failing
        }
        // A message deleted meanwhile has nothing left to change; the operation is still satisfied. But a move into
        // Archive also answers 404 when the mailbox has no Archive folder (Outlook creates it lazily), and calling that
        // done would leave the message in the server inbox for good.
        if let missing = owed.missing, case .archive = change, try await !hasArchiveFolder() {
            owed.refuse(missing.ids, ProviderError.server(status: missing.status, message: "This mailbox has no Archive folder"))
        }
        guard let error = owed.gravest else { return }
        let unapplied = Set(owed.failing + owed.refused + owed.unsent)
        guard unapplied.count < unique.count else { throw error }
        throw PartialApplyError(unapplied: unique.filter(unapplied.contains), error: error)
    }

    /// Sends one `$batch` and sorts its parts into `owed`. Returns the messages whose part the service failed, to send
    /// again.
    private func applyChunk(_ change: MetadataChange, _ chunk: [String], into owed: inout GraphApplyOwed) async throws -> [String] {
        let requests = chunk.enumerated().map { index, id in
            Self.batchRequest(for: change, messageID: id, requestID: String(index + 1))
        }
        let responses: [String: GraphBatchResponse]
        do {
            responses = GraphBatch.byID(try await client.batch(requests))
        } catch let error as ProviderError {
            // The request itself failed: the batches after it would meet the same.
            owed.stop(error)
            owed.unsent += chunk
            return []
        }
        var failing: [String] = []
        let refusedBefore = owed.refused.count
        defer {
            let failed = owed.refused.count - refusedBefore + failing.count
            if failed > 0 {
                Self.folderLog.notice("apply: \(failed, privacy: .public) of \(chunk.count, privacy: .public) parts failed")
            }
        }
        for (request, id) in zip(requests, chunk) {
            guard let response = responses[request.id] else {
                failing.append(id)
                owed.note(serviceFailure: ProviderError.decoding("$batch response missing item \(request.id)"))
                continue
            }
            if response.status == 404 {
                owed.missing = owed.missing ?? (response.status, [])
                owed.missing?.ids.append(id)
                continue
            }
            do {
                try GraphBatch.check(response)
            } catch let error as ProviderError {
                switch error {
                case .unauthorized, .throttled:
                    owed.stop(error)
                    owed.unsent.append(id)
                case _ where Self.isServiceFailure(error):
                    owed.note(serviceFailure: error)
                    failing.append(id)
                default:
                    owed.refuse([id], error)
                }
            }
        }
        return failing
    }

    private func hasArchiveFolder() async throws -> Bool {
        if try await wellKnownFolders().id("archive") != nil { return true }
        // The cache may predate the folder: the user can create Archive in Outlook at any time.
        return try await resolveWellKnownFolders().id("archive") != nil
    }

    static func batchRequest(for change: MetadataChange, messageID: String, requestID: String) -> GraphBatchRequest {
        let path = "/me/messages/\(GraphURL.pathComponent(messageID))"
        switch change {
        case .setRead(let read):
            return GraphBatchRequest(id: requestID, method: "PATCH", url: path, body: .object(["isRead": .bool(read)]))
        case .setStarred(let starred):
            let status: GraphJSONValue = .string(starred ? "flagged" : "notFlagged")
            return GraphBatchRequest(id: requestID, method: "PATCH", url: path, body: .object(["flag": .object(["flagStatus": status])]))
        case .archive:
            return move(messageID: messageID, to: "archive", requestID: requestID)
        case .moveToInbox, .restoreFromTrash, .markNotSpam:
            return move(messageID: messageID, to: "inbox", requestID: requestID)
        case .markSpam:
            return move(messageID: messageID, to: "junkemail", requestID: requestID)
        case .unsubscribe:
            // Never sent (`apply` returns first); a read of the message changes nothing if it ever were.
            return GraphBatchRequest(id: requestID, method: "GET", url: path + "?$select=id")
        case .trash:
            return move(messageID: messageID, to: "deleteditems", requestID: requestID)
        case .answerInvitation:
            // Answered on the event, never batched with message changes (`answer(_:messageID:)`); a GET changes nothing.
            return GraphBatchRequest(id: requestID, method: "GET", url: path + "?$select=id")
        }
    }

    // MARK: Invitations

    /// Answering needs `Calendars.ReadWrite` on top of mail: without it the answer waits and the account asks to
    /// reconnect.
    public func missingPermission(for change: MetadataChange) async -> AccountPermission? {
        guard case .answerInvitation = change else { return nil }
        let granted = await client.tokens.grantedScopes(for: accountID)
        return OAuthEndpoints.grants(granted, .calendar, kind: .microsoft) ? nil : .calendar
    }

    /// Accepts, tentatively accepts or declines the event (`sendResponse: true`, so Exchange answers the organizer). The
    /// event is the one the invitation named, else the event message's, looked up now.
    ///
    /// The outbox retries an answer whose request may have landed, and each POST mails the organizer, so the event's
    /// own `responseStatus` is read first: an event that already states the answer (a retry after a lost reply, or the
    /// same answer given on the phone) is done without a POST. An event that is gone answers `notFound`, which gives the
    /// answer up and puts the previous one back: nothing reached the organizer, so the card must not say it did. A
    /// decline is the exception: Exchange removes the event a decline answers, so a retry of a decline that landed
    /// finds it gone, and the user's wish, the meeting off their calendar, holds either way.
    func answer(_ answer: InvitationAnswer, messageID: String?) async throws {
        let verb: String
        switch answer.response {
        case .accepted: verb = "accept"
        case .tentative: verb = "tentativelyAccept"
        case .declined: verb = "decline"
        case .needsAction: return
        }
        do {
            var eventID = answer.graphEventID
            if eventID == nil, let messageID {
                eventID = try await eventMessage(messageID).event?.id
            }
            guard let eventID else { throw ProviderError.notFound }
            if try await responseStatus(ofEvent: eventID) == answer.response { return }
            var request = GraphRequest(method: .post, url: try GraphURL.make("/me/events/\(eventID)/\(verb)"))
            request.headers["Content-Type"] = "application/json"
            request.body = try GraphJSON.encode(["sendResponse": true])
            _ = try await client.send(request)
        } catch ProviderError.notFound where answer.response == .declined {
            return
        }
    }

    /// The user's answer as the event states it now (`responseStatus`), one small GET.
    private func responseStatus(ofEvent eventID: String) async throws -> InvitationResponse? {
        let url = try GraphURL.make("/me/events/\(eventID)", query: [("$select", "responseStatus")])
        let event = try await client.json(GraphEvent.self, for: GraphRequest(method: .get, url: url))
        return GraphInvitationMapper.response(event.responseStatus?.response)
    }

    /// `destinationId` accepts well-known folder names, which spares a folder lookup per operation.
    private static func move(messageID: String, to destination: String, requestID: String) -> GraphBatchRequest {
        GraphBatchRequest(
            id: requestID,
            method: "POST",
            url: "/me/messages/\(GraphURL.pathComponent(messageID))/move",
            body: .object(["destinationId": .string(destination)])
        )
    }
}
