#if DEBUG
import AppKit
import SSCore
import SSDesign

/// `--snapshot-state=write-…` (debug builds): Help me write in place (spec §5.56), on the quick reply with `--snapshot`
/// and on a reply composer with `--snapshot-compose`. The provider and its permission are held in memory for the run,
/// never saved; the demo writer writes, so nothing leaves the Mac.
///
/// - `write-hint`: notes typed, the Write control and its hint “⌘J writes from your notes”;
/// - `write-writing`: a reply part-way in, in pencil, held there, the line “Writing with … esc”;
/// - `write-written`: the reply landed, “Written by … · ⌘J Try again · ⌘Z Undo”;
/// - `write-strip`: ⇧⌘J's strip docked above the notes, an instruction typed, the chips;
/// - `write-failed`: the key refused, the line in `danger` with Try again and Settings…;
/// - `write-rewrite`: part of the notes selected and rewritten, held mid-stream;
/// - `write-unavailable`: a provider chosen but not turned on, the Write control dimmed.
@MainActor
enum WriteSnapshotStates {
    static let states = ["write-hint", "write-writing", "write-written", "write-strip", "write-failed", "write-rewrite",
                         "write-unavailable"]

    static let notes = "tue 10 works, I'll bring the budget"
    static let reply = "Tuesday at ten works for me. I\u{2019}ll bring the draft budget, and we can go through the open "
        + "questions on the venue together."

    /// The state asked for on the command line, if any.
    static var requested: (state: String, all: Set<String>)? {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--snapshot-state=") }) else { return nil }
        let all = Set(argument.dropFirst("--snapshot-state=".count).split(separator: ",").map(String.init))
        return states.first(where: all.contains).map { ($0, all) }
    }

    /// Holds Claude chosen and turned on (or, for `write-unavailable`, not turned on) for this run, and scripts the demo
    /// writer for `state`.
    static func prepare(_ center: HelpMeWrite, for state: String) {
        center.configurationOverride = AIProviderConfiguration(kind: .claudeAPI)
        center.consentOverride = state == "write-unavailable" ? [] : [.claudeAPI]
        guard let script = center.demoScript else { return }
        script.reply = state == "write-rewrite" ? "I\u{2019}ll bring the draft budget and the venue options." : reply
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

    /// Types the notes into `textView` and stages `state` on `session`.
    static func stage(_ state: String, session: WriteSession, textView: NSTextView, all: Set<String>) {
        textView.window?.makeFirstResponder(textView)
        let own = session.field.ownTextRange
        textView.insertText(notes, replacementRange: own)
        session.refresh()
        if all.contains("key") {
            // A snapshot launched from a terminal may never be the key window: the controls draw their key-window look.
            @MainActor func forceKey(_ view: NSView) {
                (view as? QuireControl)?.windowKeyOverride = true
                view.subviews.forEach(forceKey)
            }
            forceKey(session.field.writeControl)
            forceKey(session.field.instructionStrip)
        }
        switch state {
        case "write-writing", "write-written", "write-failed":
            session.write()
        case "write-rewrite":
            // “I'll bring the budget”: the second half of the notes.
            let text = textView.string as NSString
            let range = text.range(of: "I\u{2019}ll bring the budget")
            textView.setSelectedRange(range.location == NSNotFound ? text.range(of: "I'll bring the budget") : range)
            session.write()
        case "write-strip":
            session.showStrip()
            session.field.instructionStrip.instruction = "Warmer, and say I can do Wednesday too"
            let typed = (session.field.instructionStrip.instruction as NSString).length
            (session.field.instructionStrip.field.textField.currentEditor() as? NSTextView)?
                .setSelectedRange(NSRange(location: typed, length: 0))
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
        WriteSnapshotStates.prepare(environment.helpMeWrite, for: state)
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
        WriteSnapshotStates.prepare(center, for: state)
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
