#if DEBUG
import AppKit
import PaperCore
import PaperDesign

/// `--snapshot-state=write-…` (debug builds): Help me write at the caret (spec §5.56), on the quick reply with `--snapshot`
/// and on a reply composer with `--snapshot-compose`. The provider and its permission are held in memory for the run,
/// never saved; the demo writer writes, so nothing leaves the Mac. Renders launched from a terminal may never be the key
/// window: the session draws as in the key window.
///
/// - `write-ghost-empty`: the empty reply focused, the ghost “⌘J to write a reply” after the caret;
/// - `write-ghost-notes`: notes typed, the ghost “⌘J to write from your notes” after them, as after a pause;
/// - `write-pill`: the notes' second half selected, the pill “Rewrite ⌘J” under it (on its line in the quick reply);
/// - `write-pill-start`: the notes' first words selected, text after them on their line;
/// - `write-prompt`: ⇧⌘J's prompt line under the notes, an instruction typed, the chips;
/// - `write-writing`: a reply part-way in, in pencil, held there, the pencil mark after it;
/// - `write-written`: the reply landed, the afterline under it;
/// - `write-failed`: the key refused, the afterline in `danger` with Try again and Settings…;
/// - `write-rewrite`: part of the notes selected and rewritten, held mid-stream;
/// - `write-unavailable`: a provider chosen but not turned on, ⌘J pressed: the reason under the caret's line.
///
/// `narrow` with any of them (`--snapshot-state=write-written,narrow`): the quick reply in a half-screen window; `long`:
/// the reply as long as a real one.
@MainActor
enum WriteSnapshotStates {
    static let states = ["write-ghost-empty", "write-ghost-notes", "write-pill", "write-pill-start", "write-prompt", "write-writing", "write-written",
                         "write-failed", "write-rewrite", "write-unavailable"]

    /// Typed with its curly apostrophe, as the text's smart quotes would leave it: their late substitution would move the
    /// caret and collapse a staged selection.
    static let notes = "tue 10 works, I\u{2019}ll bring the budget"
    static let reply = "Tuesday at ten works for me. I\u{2019}ll bring the draft budget, and we can go through the open "
        + "questions on the venue together."
    /// `long`: a reply as long as a real one, past the quick reply's five lines.
    static let longReply = "Hi Sam,\n\nTuesday at ten works for me. I\u{2019}ll bring the draft budget, and we can go through "
        + "the open questions on the venue together.\n\nIf Wednesday suits the others better, I can move a call and make "
        + "that work too; just let me know by Monday.\n\nSee you then,\nAlex"

    /// `narrow` with a state: the window half a 2560 pt screen wide, the list ending where it usually does.
    static let narrowWidth: CGFloat = 1_289
    static let narrowListEdge: CGFloat = 463

    /// The state asked for on the command line, if any.
    static var requested: (state: String, all: Set<String>)? {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--snapshot-state=") }) else { return nil }
        let all = Set(argument.dropFirst("--snapshot-state=".count).split(separator: ",").map(String.init))
        return states.first(where: all.contains).map { ($0, all) }
    }

    /// Holds Claude chosen and turned on (or, for `write-unavailable`, not turned on) for this run, and scripts the demo
    /// writer for `state`.
    static func prepare(_ center: HelpMeWrite, for state: String, all: Set<String> = []) {
        center.configurationOverride = AIProviderConfiguration(kind: .claudeAPI)
        center.consentOverride = state == "write-unavailable" ? [] : [.claudeAPI]
        guard let script = center.demoScript else { return }
        script.reply = state == "write-rewrite" ? "I\u{2019}ll bring the draft budget and the venue options."
            : all.contains("long") ? longReply : reply
        script.delay = .milliseconds(12)
        switch state {
        case "write-writing": script.holdsAfter = 7
        case "write-rewrite": script.holdsAfter = 4
        case "write-failed":
            script.failure = .keyRefused
            script.failsAfter = 3
        default: break
        }
        center.availabilityChanged()
    }

    /// The second half of the notes, “I'll bring the budget”.
    private static func secondHalf(of textView: NSTextView) -> NSRange {
        let text = textView.string as NSString
        let range = text.range(of: "I\u{2019}ll bring the budget")
        return range.location == NSNotFound ? text.range(of: "I'll bring the budget") : range
    }

    /// Types the notes into `textView` and stages `state` on `session`.
    static func stage(_ state: String, session: WriteSession, textView: NSTextView, all: Set<String>) {
        textView.window?.makeFirstResponder(textView)
        session.assumesKeyWindow = true
        if state != "write-ghost-empty" {
            let own = session.field.ownTextRange
            textView.insertText(notes, replacementRange: own)
        }
        session.refresh()
        switch state {
        case "write-ghost-notes":
            session.showNotesGhostNow()
        case "write-pill":
            textView.setSelectedRange(secondHalf(of: textView))
        case "write-pill-start":
            textView.setSelectedRange(NSRange(location: session.field.ownTextRange.location, length: 6))
        case "write-writing", "write-written", "write-failed", "write-unavailable":
            session.write()
        case "write-rewrite":
            textView.setSelectedRange(secondHalf(of: textView))
            session.write()
        case "write-prompt":
            session.showPrompt()
            let prompt = session.layer.prompt
            prompt.instruction = "Warmer, and offer Wednesday too"
            let typed = (prompt.instruction as NSString).length
            (prompt.field.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: typed, length: 0))
        default:
            break
        }
    }
}

extension MainWindowController {
    /// `--snapshot-state=write-…` on the quick reply, once the first conversation's render lands.
    func applyDebugWriteStates() {
        // A composer's snapshot stages the state on the composer instead: notes typed here would move into it.
        guard let (state, all) = WriteSnapshotStates.requested,
              !CommandLine.arguments.contains(where: { $0.hasPrefix("--snapshot-compose=") }) else { return }
        WriteSnapshotStates.prepare(environment.helpMeWrite, for: state, all: all)
        if all.contains("narrow"), let window, let content = window.contentView {
            // A half-screen window, the list at its usual width: the reader's column at its narrowest in daily use.
            window.setContentSize(NSSize(width: WriteSnapshotStates.narrowWidth, height: content.frame.height))
            content.layoutSubtreeIfNeeded()
            splitView.setPosition(WriteSnapshotStates.narrowListEdge, ofDividerAt: 1)
            content.layoutSubtreeIfNeeded()
        }
        conversation.whenShownRenderLands(timeout: 10) { [weak self] _ in
            guard let self, self.conversation.focusQuickReply(all: false),
                  let session = self.conversation.quickReplyWriteSession else { return }
            WriteSnapshotStates.stage(state, session: session, textView: self.conversation.quickReplyBar.writingTextView, all: all)
        }
    }
}

extension ComposeWindowController {
    /// `--snapshot-compose` with `--snapshot-state=write-…`: the same states on a reply composer's body. False when no
    /// write state was asked for.
    func stageDebugWriteState() -> Bool {
        guard let (state, all) = WriteSnapshotStates.requested, let center = HelpMeWrite.current else { return false }
        keepNoDraft()
        WriteSnapshotStates.prepare(center, for: state, all: all)
        guard let session = bodyWriteSession else { return false }
        // After the reply's prefill has placed the signature and the folded original.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.bodyEditor.setSelectedRange(NSRange(location: 0, length: 0))
                WriteSnapshotStates.stage(state, session: session, textView: self.bodyEditor, all: all)
            }
        }
        return true
    }
}
#endif
