import Foundation

/// Remembers the resolved system folder ids for the life of the provider so `metadata(for:)` and `body(for:)`
/// can map roles without six folder lookups per call. Not persisted: the cursor carries the durable copy.
actor GraphFolderCache {
    private var folders: GraphWellKnownFolders?

    func current() -> GraphWellKnownFolders? {
        folders
    }

    func store(_ value: GraphWellKnownFolders) {
        folders = value
    }
}
