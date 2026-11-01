import Foundation

/// Who a reply goes to, derived from the original message and the replying account.
///
/// Rules match what Mail and Gmail do so threads behave the way correspondents expect:
/// - The reply target is `replyTo` when the sender set one, otherwise `from`.
/// - Reply-all puts the target and the original `to` recipients in To, and the original `cc` in Cc.
/// - The account's own addresses are removed everywhere; nobody wants to receive their own reply.
/// - Replying to a message the account itself sent addresses the original recipients instead,
///   so "reply" on a sent message continues the conversation rather than talking to oneself.
public struct ReplyRecipients: Hashable, Sendable {
    public var to: [EmailAddress]
    public var cc: [EmailAddress]

    public init(to: [EmailAddress], cc: [EmailAddress] = []) {
        self.to = to
        self.cc = cc
    }

    public static func reply(to original: MessageMetadata, ownAddresses: [String]) -> ReplyRecipients {
        compute(for: original, all: false, ownAddresses: ownAddresses)
    }

    public static func replyAll(to original: MessageMetadata, ownAddresses: [String]) -> ReplyRecipients {
        compute(for: original, all: true, ownAddresses: ownAddresses)
    }

    public static func compute(for original: MessageMetadata, all: Bool, ownAddresses: [String]) -> ReplyRecipients {
        let own = Set(ownAddresses.map(normalize))
        let target: [EmailAddress] = original.replyTo.isEmpty ? [original.from].compactMap { $0 } : original.replyTo

        var to = dedupe(target.filter { !own.contains(normalize($0.address)) })
        if all {
            to = dedupe(to + original.to.filter { !own.contains(normalize($0.address)) })
        }
        if to.isEmpty {
            // The account wrote the original (or it was addressed only to itself): continue with its recipients.
            to = dedupe(original.to.filter { !own.contains(normalize($0.address)) })
        }
        if to.isEmpty {
            // A note to self stays a note to self.
            to = dedupe(target)
        }

        var cc: [EmailAddress] = []
        if all {
            let taken = Set(to.map { normalize($0.address) })
            cc = dedupe(original.cc.filter { !own.contains(normalize($0.address)) && !taken.contains(normalize($0.address)) })
        }
        return ReplyRecipients(to: to, cc: cc)
    }

    private static func normalize(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Keeps the first occurrence of each address so the name the sender used wins.
    private static func dedupe(_ addresses: [EmailAddress]) -> [EmailAddress] {
        var seen: Set<String> = []
        return addresses.filter { seen.insert(normalize($0.address)).inserted }
    }
}
