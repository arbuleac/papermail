import Foundation

/// What the engine must remember between bootstrap pages: the provider's next page token and the change
/// cursor captured with the first page.
///
/// `BootstrapState` has no field for that cursor, and it must not become the account's sync cursor before
/// enumeration completes (a poll from it would race the pages still being written). So the two ride together
/// inside `BootstrapState.nextPage` as a small JSON envelope. The string is opaque to the store and the UI;
/// only this module reads it back.
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
                // A bare token (or nothing) carries no cursor, and without one a resumed bootstrap could never
                // finish correctly; reporting an empty checkpoint makes the syncer start over.
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
