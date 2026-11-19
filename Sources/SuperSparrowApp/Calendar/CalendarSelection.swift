import Foundation
import SSCore

/// What the calendar knows of the selected conversation (spec §5.54, “The selected conversation”): its invitation, as
/// the reader's card has it, and the times its mail names. Read from the store off the main thread when the selection
/// changes (`CalendarState.select(_:)`), so J and K never wait on a body.
struct CalendarSelection: Equatable, Sendable {
    var conversationID: ConversationID
    /// The latest message's subject, for the Later mark and VoiceOver.
    var subject: String
    /// The conversation's messages: time set aside for one of them belongs to the selection and carries the margin
    /// rule.
    var messageIDs: Set<MessageID>
    /// The conversation's invitation: the latest revision a message carries (one a later message supersedes is never
    /// drawn), nil for none.
    var invitation: CalendarInvitation?
    /// The message that carries `invitation`, which an answer names.
    var invitationMessage: MessageID?
    /// The answer given on this Mac, which wins over the one the invitation states (spec §5.14).
    var invitationReply: InvitationResponse?
    /// The times the conversation's mail names, by start.
    var mailTimes: [MailTime]

    init(conversationID: ConversationID, subject: String = "", messageIDs: Set<MessageID> = [],
         invitation: CalendarInvitation? = nil, invitationMessage: MessageID? = nil,
         invitationReply: InvitationResponse? = nil, mailTimes: [MailTime] = []) {
        self.conversationID = conversationID
        self.subject = subject
        self.messageIDs = messageIDs
        self.invitation = invitation
        self.invitationMessage = invitationMessage
        self.invitationReply = invitationReply
        self.mailTimes = mailTimes
    }

    /// The answer the calendar draws the invitation with: the one given on this Mac, else the one it states.
    var response: CalendarEvent.Response? {
        guard let invitation else { return nil }
        if invitation.userIsOrganizer { return .organizer }
        switch invitationReply ?? invitation.userResponse {
        case .accepted?: return .accepted
        case .tentative?: return .tentative
        case .declined?: return .declined
        case .needsAction?, nil: return .needsAction
        }
    }

    /// Reads a conversation's context from the store. Runs on any thread: bodies are read newest first and only until
    /// an invitation turns up, since the newest revision is the one drawn, and a long thread's older bodies are never
    /// read for nothing.
    static func read(_ id: ConversationID, from store: MailStoring) -> CalendarSelection {
        let messages = (try? store.messages(in: id)) ?? []
        let newestFirst = messages.sorted { $0.date > $1.date }
        var selection = CalendarSelection(conversationID: id, subject: newestFirst.first?.subject ?? "",
                                          messageIDs: Set(messages.map(\.id)))
        var revisions: [(invitation: CalendarInvitation, message: MessageMetadata)] = []
        // Drafts and replies on their way out are the user's own writing, never an invitation (as the reader reads it).
        for message in newestFirst.prefix(Self.bodiesRead) where !message.roles.contains(.drafts) {
            guard let invitation = (try? store.body(for: message.id))?.invitation else { continue }
            revisions.append((invitation, message))
            if revisions.count == 2 { break }
        }
        if let current = revisions.first(where: { candidate in
            !revisions.contains { $0.invitation.supersedes(candidate.invitation) }
        }) {
            selection.invitation = current.invitation
            selection.invitationMessage = current.message.id
            selection.invitationReply = current.message.invitationReply
        }
        selection.mailTimes = ((try? store.mailTimes(in: id)) ?? []).sorted { $0.start < $1.start }
        return selection
    }

    /// The newest messages whose bodies are looked at for an invitation: a thread about one keeps it near the top.
    static let bodiesRead = 12
}
