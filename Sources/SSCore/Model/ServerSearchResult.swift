import Foundation

/// What a search of the server found (`MailClient.searchServer`): the conversations holding its hits, which the list
/// adds to the local results (`ConversationQuery.serverMatches`), and the accounts whose search failed.
public struct ServerSearchResult: Hashable, Sendable {
    /// The conversations of every hit this Mac now stores: the ones the search just downloaded and the ones it already
    /// had. Hits in Trash or Spam are left out, as the list's search leaves those out.
    public var conversations: Set<ConversationID>
    /// Messages the search wrote to the store as new metadata; their bodies download when they are opened.
    public var downloaded: Int
    /// The accounts whose search failed (offline, throttled, signed out), in the order they were asked.
    public var failedAccounts: [AccountID]

    public init(conversations: Set<ConversationID> = [], downloaded: Int = 0, failedAccounts: [AccountID] = []) {
        self.conversations = conversations
        self.downloaded = downloaded
        self.failedAccounts = failedAccounts
    }
}
