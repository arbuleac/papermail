#if DEBUG
import AppKit
import PaperCore

extension MainWindowController {
    /// `--snapshot-state=…` (debug builds), the calendar's states (spec §5.54), applied once the first selection is made:
    /// `invite` selects the demo's dinner invitation and `critique` the design critique's, so the column pencils them in;
    /// `today` selects a mail that names no time, so the column stays on today (turning it would lose to the newest
    /// mail's invitation, whose context lands after); `day+N` turns the column N days on; `hidden` hides the column as its toggle does; `week` opens the week; `strip` narrows the window below 1,088 pt so the column
    /// folds to its strip, and `strip-open` opens the column over the reader's edge. `details=<key>` opens a demo event's
    /// details (dinner, priya, critique, fabrikam, planning, cleanup, standup, block), `details-accept=<key>` answers Accept
    /// on it too; both hold the snapshot (`debugStatesPending`) until the card is on screen.
    func applyDebugCalendarStates() {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--snapshot-state=") }) else { return }
        let states = argument.dropFirst("--snapshot-state=".count).split(separator: ",").map(String.init)
        for state in states {
            switch state {
            case "invite": selectDebugConversation(subjectContaining: "Sam's birthday dinner")
            case "critique": selectDebugConversation(subjectContaining: "Design critique")
            case "today": selectDebugConversation(subjectContaining: "Photos from the offsite")
            case "hidden": if desk.isColumnOn { toggleDay() }
            case "week": toggleWeekView()
            case "strip", "strip-open":
                guard let window else { continue }
                window.setContentSize(NSSize(width: 1_040, height: window.contentView?.frame.height ?? 800))
                window.contentView?.layoutSubtreeIfNeeded()
                if state == "strip-open" { openStrip() }
            case let state where state.hasPrefix("day+"):
                if let days = Int(state.dropFirst("day+".count)) { turnDay(by: days) }
            case let state where state.hasPrefix("details=") || state.hasPrefix("details-accept="):
                let accepts = state.hasPrefix("details-accept=")
                let key = String(state.split(separator: "=", maxSplits: 1).last ?? "")
                debugStatesPending = true
                // After the other states, once the selection's context has landed and the events are placed.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    MainActor.assumeIsolated { self?.openDebugDetails(key, accepts: accepts, deadline: Date().addingTimeInterval(15)) }
                }
            default: continue
            }
        }
    }

    /// The demo event each `details=` key opens (spec §19.2).
    private static let debugDetailsTitles: [String: String] = [
        "dinner": "Sam's birthday dinner", "priya": "Call with Priya: Lisbon plans", "critique": "Design critique",
        "fabrikam": "Fabrikam renewal call", "planning": "Quarterly planning", "cleanup": "Neighbourhood clean-up",
        "standup": "Standup",
    ]

    /// Opens the details of the demo event `key` names (its first occurrence from today on; the next weekday's for the
    /// standup), turning the column or the week to its day, and for `details-accept` answers Accept through the engine
    /// (This Event on a repeating one). `block` sets 30 minutes aside for the selected conversation first.
    private func openDebugDetails(_ key: String, accepts: Bool, deadline: Date) {
        let retry = { [weak self] in
            guard Date() < deadline else {
                self?.debugStatesPending = false
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MainActor.assumeIsolated { self?.openDebugDetails(key, accepts: accepts, deadline: deadline) }
            }
        }
        let state = calendarState
        // The selection's context first: when it lands the column turns to its day, which would close the card.
        if let selected = state.selectedConversation, state.selection?.conversationID != selected { return retry() }
        let today = state.calendar.startOfDay(for: state.now)
        let event: CalendarEvent?
        if key == "block" {
            if let existing = debugBlockID.flatMap({ id in state.events.first { $0.id == id } }) {
                event = existing
            } else {
                guard let selected = calendarState.selectedConversation else { return retry() }
                let before = Set(state.events.map(\.id))
                _ = blockTimeForSelection()
                debugBlockID = (try? environment.store.calendarEvents(in: CalendarWindow.around(state.now), accountIDs: [selected.accountID]))?
                    .first { !before.contains($0.id) && $0.isSetAside }?.id
                return retry()
            }
        } else {
            guard let title = Self.debugDetailsTitles[key] else {
                debugStatesPending = false
                return
            }
            let window = CalendarWindow.around(state.now)
            let all = (try? environment.store.calendarEvents(in: window, accountIDs: nil)) ?? []
            var start = today
            if key == "standup" { start = state.calendar.date(byAdding: .day, value: 1, to: today) ?? today }
            event = all.filter { $0.title == title && $0.start >= start && $0.isShown }.min { $0.start < $1.start }
        }
        guard let event else { return retry() }
        let day = state.calendar.startOfDay(for: event.start)
        if state.span == .week {
            if !state.shownWeekDays.contains(where: { state.calendar.isDate($0, inSameDayAs: day) }) { state.shownWeek = day }
        } else if !state.calendar.isDate(state.shownDay, inSameDayAs: day) {
            state.shownDay = day
        }
        let timeline = state.span == .week ? desk.week.timeline : desk.column.timeline
        timeline.window?.contentView?.layoutSubtreeIfNeeded()
        guard timeline.placed(withID: event.id) != nil else { return retry() }
        timeline.activate(.event(event.id))
        guard accepts else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated { self?.debugStatesPending = false }
            }
            return
        }
        let message = (try? environment.store.invitationMessages(for: event)).flatMap { RelatedInvitation.pick($0, for: event) }?.message.id
        answerCalendarEvent(.accepted, eventID: event.id, span: .occurrence, invitationMessage: message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated { self?.debugStatesPending = false }
        }
    }

    private func selectDebugConversation(subjectContaining words: String) {
        guard let row = list.conversations.first(where: { $0.subject.contains(words) }) else { return }
        list.selectedConversationID = row.id
        present(selection: [row.id])
    }
}
#endif
