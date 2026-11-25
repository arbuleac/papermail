import Foundation

/// What Help Me Write writes in demo mode, the snapshots and the app tests: the demo's own canned drafts, so the
/// feature can be shown with nothing leaving the Mac. The app's demo writer streams one of these, picked by what the
/// request writes: a reply, a new message (each with its subject) or the message above a forward.
public enum DemoAIReplies {
    /// A canned draft: its message, and for a new message whose request asked for one, its subject.
    public struct Draft: Sendable, Hashable {
        public var subject: String?
        public var body: String

        public init(subject: String? = nil, body: String) {
            self.subject = subject
            self.body = body
        }

        /// The first line a model would send for the subject, with the empty line under it; nil without a subject.
        /// The demo writer streams it ahead of `body`, so the demo's answers are split by the code a provider's are.
        public var subjectLine: String? {
            subject.map { "Subject: \($0)\n\n" }
        }

        /// The whole answer as a model would send it.
        public var answer: String {
            (subjectLine ?? "") + body
        }
    }

    public static let replies: [String] = DemoCatalog.replies

    /// New messages, each with the subject it would propose. They greet no one by name and sign with none: the demo
    /// writes the same draft whoever the message is to.
    public static let newMessages: [Draft] = [
        Draft(subject: "Offsite dates in March",
              body: "Hi,\n\nI'm putting the spring offsite on the calendar and wanted to check dates with you first. "
                + "Would the week of [date] work on your side?\n\nIf it does, I'll book the venue and send the agenda around."),
        Draft(subject: "Quick question about the budget",
              body: "Hi,\n\nBefore I send the budget on, could you look over the travel line? "
                + "I think we can bring it down, but I'd like a second pair of eyes.\n\nThanks for taking a look."),
        Draft(subject: "Lunch next week?",
              body: "Hi,\n\nIt's been a while. Are you free for lunch one day next week? "
                + "I can do any day but Wednesday, and I'm happy to come to you."),
        Draft(subject: "Notes from today's call",
              body: "Hi all,\n\nThanks for the time today. Here is what we agreed:\n\n"
                + "We keep the launch date, the copy is due on [date], and I'll share the revised plan tomorrow.\n\n"
                + "Tell me if I missed anything."),
        Draft(subject: "Thank you",
              body: "Hi,\n\nJust a note to say thank you for stepping in last week. "
                + "It made a real difference, and the team noticed.\n\nI owe you a coffee."),
        Draft(subject: "Moving our meeting",
              body: "Hi,\n\nSomething has come up on my side. Could we move our meeting to [time]? "
                + "Sorry for the short notice, and thanks for being flexible."),
    ]

    /// Messages to go above a forwarded one: short, and saying nothing of what it holds that a made-up draft could
    /// get wrong. Each is long enough for the writing render to rest part-way into it, wherever the pick lands.
    public static let forwardMessages: [String] = [
        "Hi,\n\nForwarding this so you have it. The details are in the message below.",
        "Hi,\n\nSharing the message below for context. Tell me what you think when you've had a look.",
        "Hi,\n\nPassing this along, since it touches what you're working on. Nothing needed from you yet.",
        "Hi all,\n\nSee the message below. I'd like to talk it through when we next meet.",
        "Hi,\n\nI thought you should see this before we talk. Have a look when you have a minute.",
        "Hi,\n\nForwarding the message below for your records, so you have it to hand when you need it.",
    ]

    /// The draft for `request`, the same on every run for the same request (a snapshot must not change), different
    /// across asks. A subject comes with it only when the request asked for one.
    public static func draft(for request: AIWriteRequest) -> Draft {
        // FNV-1a over the user's part: `hashValue` changes from launch to launch. Without the request's fence code,
        // which is new on every request, so the same ask picks the same draft on every run.
        let key = request.fence.isEmpty ? request.task : request.task.replacingOccurrences(of: request.fence, with: "")
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        func pick<Element>(_ list: [Element]) -> Element { list[Int(hash % UInt64(list.count))] }
        switch request.kind {
        case .reply:
            return Draft(body: pick(replies))
        case .newMessage:
            let draft = pick(newMessages)
            return Draft(subject: request.wantsSubject ? draft.subject : nil, body: draft.body)
        case .forward:
            return Draft(body: pick(forwardMessages))
        }
    }

    /// The draft's message alone, without its subject line.
    public static func reply(for request: AIWriteRequest) -> String {
        draft(for: request).body
    }
}
