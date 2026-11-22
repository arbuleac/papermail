import Foundation

/// Remembers the resolved system folder ids for the life of the provider so `metadata(for:)` and `body(for:)`
/// can map roles without six folder lookups per call. Not persisted: the cursor carries the durable copy.
actor GraphFolderCache {
    private var folders: GraphWellKnownFolders?
    /// The Archive folder's id in Graph's default (REST) form, with the immutable id it was looked up beside: an inbox
    /// rule's `moveToFolder` may name the folder in either form (`GraphProvider+Rules`). Kept for the provider's life,
    /// and looked up again only when the Archive folder's immutable id changes (the folder made anew).
    private var defaultFormArchive: (immutable: String, rest: String)?

    func current() -> GraphWellKnownFolders? {
        folders
    }

    func store(_ value: GraphWellKnownFolders) {
        folders = value
    }

    func defaultFormArchiveID(besides immutable: String) -> String? {
        guard let defaultFormArchive, defaultFormArchive.immutable == immutable else { return nil }
        return defaultFormArchive.rest
    }

    func storeDefaultFormArchiveID(_ rest: String, besides immutable: String) {
        defaultFormArchive = (immutable, rest)
    }
}
