import Foundation
import SSCore

extension GraphProvider {
    /// Replays a local change as PATCHes and moves, 20 messages per `$batch` round trip.
    public func apply(_ change: MetadataChange, to providerIDs: [String]) async throws {
        // Not a change to messages: the engine sends an unsubscribe request itself.
        if case .unsubscribe = change { return }
        if case .answerInvitation(let answer) = change {
            try await self.answer(answer, messageID: providerIDs.first)
            return
        }
        var seen: Set<String> = []
        let unique = providerIDs.filter { seen.insert($0).inserted }
        for chunk in unique.chunks(of: GraphBatch.maxRequests) {
            let requests = chunk.enumerated().map { index, id in
                Self.batchRequest(for: change, messageID: id, requestID: String(index + 1))
            }
            var missing: GraphBatchResponse?
            for response in try await client.batch(requests) {
                if response.status == 404 {
                    missing = missing ?? response
                    continue
                }
                try GraphBatch.check(response)
            }
            // A message deleted meanwhile has nothing left to change; the operation is still satisfied. But a
            // move into Archive also answers 404 when the mailbox has no Archive folder (Outlook creates it
            // lazily), and calling that done would leave the message in the server inbox for good.
            if let missing, case .archive = change, try await !hasArchiveFolder() {
                throw ProviderError.server(status: missing.status, message: "This mailbox has no Archive folder")
            }
        }
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
        case .moveToInbox, .restoreFromTrash:
            return move(messageID: messageID, to: "inbox", requestID: requestID)
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
