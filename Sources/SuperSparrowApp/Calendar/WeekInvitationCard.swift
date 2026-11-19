import AppKit
import SSCore
import SSDesign

/// The selected conversation's invitation, beside its slot in the week (spec §5.54, “The week”, and §5.14): the kicker
/// says whether it is answered, then the title, when, the place and organizer, what it overlaps, and Accept · Tentative ·
/// Decline under the card's rules (no toast, no undo). Built from the selection the state read; the shell answers.
@MainActor
enum WeekInvitationCard {
    /// The card's words and answers, or nil when the selection has no invitation that is not cancelled.
    static func model(for selection: CalendarSelection, overlap: CalendarFit.InvitationOverlap?, event: CalendarEvent?,
                      state: CalendarState, answer: @escaping (InvitationResponse, MessageID) -> Void) -> CalendarCardModel? {
        guard let invitation = selection.invitation, let message = selection.invitationMessage, !invitation.isCancelled else {
            return nil
        }
        let chosen = (selection.invitationReply ?? invitation.userResponse).flatMap { $0.isAnswer ? $0 : nil }
        let kicker: String
        var glyph: (name: String, color: NSColor) = (Quire.Icon.invitation, .qInk3)
        switch chosen {
        case .accepted?:
            kicker = "Accepted"
            glyph = (Quire.Icon.answered, .qAccent)
        case .tentative?: kicker = "Tentative"
        case .declined?: kicker = "Declined"
        case .needsAction?, nil: kicker = "Invitation · not answered"
        }
        var lines: [CalendarCardModel.Line] = []
        let organizer = invitation.userIsOrganizer ? nil : invitation.organizer?.displayName
        let place = [invitation.location, organizer.map { "from " + $0 }].compactMap { $0 }.filter { !$0.isEmpty }
        if !place.isEmpty {
            lines.append(.init(glyph: nil, text: place.joined(separator: " · "), role: .snippet, color: .qInk2))
        }
        if let overlapLine = overlapLine(overlap, state: state) {
            lines.append(.init(glyph: (Quire.Icon.warning, .qWarning), text: overlapLine, role: .snippet, color: .qInk))
        }
        var actions: [CalendarCardModel.Action] = []
        if invitation.isAnswerable {
            let titles: [InvitationResponse: String] = [.accepted: "Accept", .tentative: "Tentative", .declined: "Decline"]
            for response in InvitationResponse.answers {
                actions.append(.init(title: titles[response] ?? "", variant: .secondary, symbol: nil, isChosen: chosen == response) {
                    answer(response, message)
                })
            }
        }
        let title = invitation.title.isEmpty ? CalendarText.noTitle : invitation.title
        let when = event.map { state.text.when($0, now: state.now) }
        return CalendarCardModel(kickerGlyph: glyph, kicker: kicker, title: title, titleIsPlaceholder: invitation.title.isEmpty,
                                 when: when, lines: lines, actions: actions, accessibilityName: "Invitation: " + title)
    }

    /// “Overlaps 1:1 with Sam, 13:30 - 14:00”, “Overlaps Hiring sync, 11:00 - 11:30, and 2 more” (spec §5.14); none
    /// once declined.
    static func overlapLine(_ overlap: CalendarFit.InvitationOverlap?, state: CalendarState) -> String? {
        guard let overlap, overlap.event.isShown, let first = overlap.overlaps.first else { return nil }
        let title = first.event.title.isEmpty ? CalendarText.noTitle : first.event.title
        var line = "Overlaps " + title + ", " + state.text.range(first.interval.start, first.interval.end)
        if overlap.overlaps.count > 1 { line += ", and \(overlap.overlaps.count - 1) more" }
        return line
    }
}
