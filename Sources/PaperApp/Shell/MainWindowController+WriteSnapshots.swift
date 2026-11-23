#if DEBUG
import AppKit
import PaperCore
import PaperDesign

/// `--snapshot-state=write-…` (debug builds): Help me write at the caret (spec §5.56), on the quick reply with `--snapshot`
/// and on a composer with `--snapshot-compose`: a reply, or with `new` a new message, with `forward` a forward. The
/// provider and its permission are held in memory for the run, never saved; the demo writer writes, so nothing leaves
/// the Mac. Renders launched from a terminal may never be the key window: the session draws as in the key window.
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
/// - `write-unavailable`: a provider chosen but not turned on, ⌘J pressed: the reason under the caret's line;
/// - `write-ask`: nothing typed, ⌘J pressed. Where there is nothing to write from (`new`) the prompt line opens, the
///   capsule alone with no chips; elsewhere ⌘J writes, as in `write-written`;
/// - `write-replies-only`: a provider turned on before its sheet named new messages and forwards, ⌘J pressed. With
///   `new` or `forward`: “Help Me Write is on for replies only” under the caret's line, with Settings….
///
/// `narrow` with any of them (`--snapshot-state=write-written,narrow`): the quick reply in a half-screen window; `long`:
/// the reply as long as a real one. With `--snapshot-compose`, `new`: the composer is a new message to a named
/// recipient, whose `write-ghost-empty` reads “⌘J to say what to write” and whose `write-writing`, `write-written` and
/// `write-failed` are written from a brief said in the prompt line, the body left empty (a written one has its
/// subject); `forward`: a forward of the selected conversation, staged once its forwarded message is in, written from
/// that message alone.
@MainActor
enum WriteSnapshotStates {
    static let states = ["write-ghost-empty", "write-ghost-notes", "write-pill", "write-pill-start", "write-prompt", "write-writing", "write-written",
                         "write-failed", "write-rewrite", "write-unavailable", "write-ask", "write-replies-only"]

    /// Typed with its curly apostrophe, as the text's smart quotes would leave it: their late substitution would move the
    /// caret and collapse a staged selection.
    static let notes = "tue 10 works, I\u{2019}ll bring the budget"
    static let reply = "Tuesday at ten works for me. I\u{2019}ll bring the draft budget, and we can go through the open "
        + "questions on the venue together."
    /// `long`: a reply as long as a real one, past the quick reply's five lines.
    static let longReply = "Hi Sam,\n\nTuesday at ten works for me. I\u{2019}ll bring the draft budget, and we can go through "
        + "the open questions on the venue together.\n\nIf Wednesday suits the others better, I can move a call and make "
        + "that work too; just let me know by Monday.\n\nSee you then,\nAlex"

    /// A new message's samples: who it is to, the notes typed for it, the brief said in the prompt line, and the draft
    /// the demo writer answers with, its subject line first, as a model sends it.
    static let newMessageRecipient = EmailAddress(name: "Priya Raman", address: "priya.raman@demo-mail.test")
    static let newMessageNotes = "lunch thursday, somewhere near the office"
    static let newMessageBrief = "Ask Priya to lunch on Thursday, somewhere near the office"
    static let newMessageDraft = "Subject: Lunch on Thursday?\n\nHi Priya,\n\nAre you free for lunch on Thursday? I was thinking of "
        + "somewhere near the office, around [time].\n\nLet me know if that works for you."
    /// A forward's notes. Its drafts are the demo's own (`DemoAIReplies.forwardMessages`), which say nothing of the
    /// forwarded message that a made-up draft could get wrong.
    static let forwardNotes = "fyi before thursday, tell me what you think"

    /// The notes typed where `kind` is written.
    static func notes(for kind: WriteKind) -> String {
        switch kind {
        case .reply: return notes
        case .newMessage: return newMessageNotes
        case .forward: return forwardNotes
        }
    }

    /// `narrow` with a state: the window half a 2560 pt screen wide, the list ending where it usually does.
    static let narrowWidth: CGFloat = 1_289
    static let narrowListEdge: CGFloat = 463

    /// The state asked for on the command line, if any.
    static var requested: (state: String, all: Set<String>)? {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--snapshot-state=") }) else { return nil }
        let all = Set(argument.dropFirst("--snapshot-state=".count).split(separator: ",").map(String.init))
        return states.first(where: all.contains).map { ($0, all) }
    }

    /// `new` with a write state: `--snapshot-compose` opens a new message instead of a reply.
    static var opensNewMessage: Bool { requested?.all.contains("new") ?? false }

    /// `forward` with a write state: `--snapshot-compose` forwards the selected conversation instead of replying.
    static var opensForward: Bool { !opensNewMessage && requested?.all.contains("forward") ?? false }

    /// Holds Claude chosen and turned on (for `write-unavailable`, not turned on; for `write-replies-only`, turned on
    /// before the sheet named anything but replies) for this run, and scripts the demo writer for `state`.
    static func prepare(_ center: HelpMeWrite, for state: String, all: Set<String> = []) {
        center.configurationOverride = AIProviderConfiguration(kind: .claudeAPI)
        center.consentOverride = state == "write-unavailable" ? [] : [.claudeAPI]
        center.consentOverrideIsForRepliesOnly = state == "write-replies-only"
        guard let script = center.demoScript else { return }
        if state == "write-rewrite" {
            script.reply = "I\u{2019}ll bring the draft budget and the venue options."
        } else if all.contains("new") {
            script.reply = newMessageDraft
        } else if all.contains("forward") {
            script.reply = nil
        } else {
            script.reply = all.contains("long") ? longReply : reply
        }
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

    /// The second half of the notes: what follows their comma (“I'll bring the budget”).
    private static func secondHalf(of textView: NSTextView, own: NSRange) -> NSRange {
        let text = textView.string as NSString
        let comma = text.range(of: ", ", options: [], range: own)
        guard comma.location != NSNotFound else { return own }
        return NSRange(location: NSMaxRange(comma), length: NSMaxRange(own) - NSMaxRange(comma))
    }

    /// Types the notes for what `session`'s field writes into `textView` and stages `state`. Where there is nothing to
    /// write from without them (a new message), the states that write leave the body empty and say a brief in the
    /// prompt line instead, which ⌘J opens there.
    static func stage(_ state: String, session: WriteSession, textView: NSTextView, all: Set<String>) {
        textView.window?.makeFirstResponder(textView)
        session.assumesKeyWindow = true
        session.refresh()
        let kind = session.field.writeKind
        let asksWhat = kind.hasNothingToWriteFrom(WriteAsk())
        let writes = ["write-writing", "write-written", "write-failed"].contains(state)
        if state != "write-ghost-empty", state != "write-ask", !(asksWhat && writes) {
            textView.insertText(notes(for: kind), replacementRange: session.field.ownTextRange)
        }
        session.refresh()
        let own = session.field.ownTextRange
        switch state {
        case "write-ghost-notes":
            session.showNotesGhostNow()
        case "write-pill":
            textView.setSelectedRange(secondHalf(of: textView, own: own))
        case "write-pill-start":
            textView.setSelectedRange(NSRange(location: own.location, length: 6))
        case "write-writing", "write-written", "write-failed":
            session.write()
            // An empty new message: ⌘J opened the prompt line and sent nothing. The brief is said there, then ↩.
            if session.isPromptShown {
                session.layer.prompt.instruction = newMessageBrief
                session.write()
            }
        case "write-unavailable", "write-replies-only", "write-ask":
            session.write()
        case "write-rewrite":
            textView.setSelectedRange(secondHalf(of: textView, own: own))
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

extension MainWindowController {
    /// `--snapshot-compose` with `new` and a write state: a new message to a named recipient, so its draft has someone
    /// to greet. False when no composer opened (no account).
    func openNewMessageComposerForWriteSnapshot() -> Bool {
        openMailLink(MailtoLink(to: [WriteSnapshotStates.newMessageRecipient])) != nil
    }
}

extension ComposeWindowController {
    /// `--snapshot-compose` with `--snapshot-state=write-…`: the same states on this composer's body, whatever it
    /// writes. False when no write state was asked for.
    func stageDebugWriteState() -> Bool {
        guard let (state, all) = WriteSnapshotStates.requested, let center = HelpMeWrite.current else { return false }
        keepNoDraft()
        WriteSnapshotStates.prepare(center, for: state, all: all)
        guard let session = bodyWriteSession else { return false }
        stageDebugWriteState(state, all: all, on: session, tries: 40)
        return true
    }

    /// Stages after a reply's prefill has placed the signature and the folded original; a forward's once its forwarded
    /// message is in (or will not come), since that is what it is written from.
    private func stageDebugWriteState(_ state: String, all: Set<String>, on session: WriteSession, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isLoadingForwardedMessage, tries > 0 {
                    self.stageDebugWriteState(state, all: all, on: session, tries: tries - 1)
                    return
                }
                self.bodyEditor.setSelectedRange(NSRange(location: 0, length: 0))
                WriteSnapshotStates.stage(state, session: session, textView: self.bodyEditor, all: all)
            }
        }
    }
}
#endif
