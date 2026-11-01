import Foundation
import SSCore

/// One request inside a `$batch` envelope. `url` is relative to `/v1.0`.
struct GraphBatchRequest: Encodable, Sendable {
    var id: String
    var method: String
    var url: String
    var headers: [String: String]?
    var body: GraphJSONValue?
}

struct GraphBatchResponse: Decodable, Sendable {
    var id: String
    var status: Int
    var headers: [String: String]?
    var body: GraphJSONValue?
}

struct GraphBatchEnvelope: Encodable, Sendable {
    var requests: [GraphBatchRequest]
}

struct GraphBatchResponseEnvelope: Decodable, Sendable {
    var responses: [GraphBatchResponse]
}

enum GraphBatch {
    /// Graph rejects envelopes with more than 20 requests.
    static let maxRequests = 20

    /// Maps one item's status the way the transport maps a whole response, so callers see one error vocabulary.
    static func check(_ response: GraphBatchResponse) throws {
        guard !(200..<300).contains(response.status) else { return }
        throw GraphErrorMapper.error(status: response.status, headers: response.headers ?? [:], body: response.body)
    }

    /// Responses may come back in any order; callers want them keyed by the id they chose.
    static func byID(_ responses: [GraphBatchResponse]) -> [String: GraphBatchResponse] {
        var map: [String: GraphBatchResponse] = [:]
        for response in responses { map[response.id] = response }
        return map
    }
}

extension Array {
    func chunks(of size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
