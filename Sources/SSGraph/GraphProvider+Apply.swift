import Foundation
import SSCore

extension GraphProvider {
    /// Replays a local change as PATCHes and moves, 20 messages per `$batch` round trip.
    public func apply(_ change: MetadataChange, to providerIDs: [String]) async throws {
        var seen: Set<String> = []
        let unique = providerIDs.filter { seen.insert($0).inserted }
        for chunk in unique.chunks(of: GraphBatch.maxRequests) {
            let requests = chunk.enumerated().map { index, id in
                Self.batchRequest(for: change, messageID: id, requestID: String(index + 1))
            }
            for response in try await client.batch(requests) {
                // A message deleted meanwhile has nothing left to change; the operation is still satisfied.
                if response.status == 404 { continue }
                try GraphBatch.check(response)
            }
        }
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
        case .trash:
            return move(messageID: messageID, to: "deleteditems", requestID: requestID)
        }
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
