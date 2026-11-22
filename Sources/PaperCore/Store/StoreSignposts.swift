import os

/// Intervals around the store's own reads. "store.search" is each full-text read, so Instruments can tell how
/// much of a search's wait (the app's "list.search") is SQLite and how much is the list.
enum StoreSignposts {
    static let signposter = OSSignposter(subsystem: AppIdentity.bundleIdentifier, category: "store")
    static let search: StaticString = "store.search"
}
