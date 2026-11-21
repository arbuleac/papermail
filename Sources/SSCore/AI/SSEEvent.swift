import Foundation

/// One server-sent event, as `SSEParser` dispatches it.
public struct SSEEvent: Sendable, Hashable {
    /// The `event:` field; “message” when the stream named none (the WHATWG default).
    public var event: String
    /// The `data:` lines joined with “\n”.
    public var data: String
    /// The last `id:` seen, which carries over to later events as the spec says.
    public var id: String?

    public init(event: String = "message", data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}
