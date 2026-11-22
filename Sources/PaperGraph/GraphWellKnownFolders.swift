import Foundation
import PaperCore

/// Ids of the system folders, keyed by Graph's well-known name. Roles are derived from a message's
/// `parentFolderId` by comparing against these ids.
struct GraphWellKnownFolders: Equatable, Sendable {
    static let names = ["inbox", "sentitems", "drafts", "deleteditems", "junkemail", "archive"]

    private static let roleByName: [String: MailboxRole] = [
        "inbox": .inbox,
        "sentitems": .sent,
        "drafts": .drafts,
        "deleteditems": .trash,
        "junkemail": .spam,
    ]

    var ids: [String: String]

    init(ids: [String: String]) {
        self.ids = ids
    }

    func id(_ name: String) -> String? {
        ids[name]
    }

    /// Trash and junk never enter the local mailbox during bootstrap; the deltas pick them up later as roles.
    var excludedFromBootstrap: Set<String> {
        Set([ids["deleteditems"], ids["junkemail"]].compactMap { $0 })
    }

    func roles(folderID: String?, isDraft: Bool) -> Set<MailboxRole> {
        var roles: Set<MailboxRole> = []
        if let folderID {
            for (name, role) in Self.roleByName where ids[name] == folderID {
                roles.insert(role)
            }
        }
        if isDraft {
            roles.insert(.drafts)
        }
        return roles
    }
}
