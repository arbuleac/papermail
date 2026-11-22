import Foundation

/// What the engine must remember between enumeration pages: the provider's next page token (where the
/// backfill lane resumes) and the change cursor captured with the head page.
///
/// The live lane stores that cursor as the sync cursor right after the head page, but writes it here first, so
/// a crash between the two writes leaves a state whose cursor the next launch adopts. A download the
/// single-loop engine left in progress (which kept the cursor here until enumeration completed) is adopted the
/// same way. `BootstrapState` has no field for the cursor, so the two ride together inside
/// `BootstrapState.nextPage` as a small JSON envelope. The string is opaque to the store and the UI; only this
/// module reads it back.
struct BootstrapCheckpoint: Codable, Hashable, Sendable {
    var providerPage: String?
    var changeCursor: String?

    init(providerPage: String? = nil, changeCursor: String? = nil) {
        self.providerPage = providerPage
        self.changeCursor = changeCursor
    }
}

extension BootstrapState {
    var checkpoint: BootstrapCheckpoint {
        get {
            guard let nextPage,
                  let data = nextPage.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(BootstrapCheckpoint.self, from: data) else {
                // A bare token (or nothing) carries no cursor to adopt; reporting an empty checkpoint makes an
                // account without a sync cursor fetch a new head page.
                return BootstrapCheckpoint()
            }
            return decoded
        }
        set {
            guard newValue.providerPage != nil || newValue.changeCursor != nil else {
                nextPage = nil
                return
            }
            nextPage = (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }
}
