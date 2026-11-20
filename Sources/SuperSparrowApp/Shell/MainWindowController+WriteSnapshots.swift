#if DEBUG
import AppKit
import SSCore
import SSDesign

extension MainWindowController {
    /// `--snapshot-state=…` (debug builds), Help me write's card on the quick reply (spec §5.55), once the first
    /// conversation's render lands: `write-idle` (notes typed, the card open), `write-writing` (a reply part-way in, held
    /// there), `write-failed` (the key refused) and `write-off` (no provider). The provider and its permission are held in
    /// memory for the run, never saved; the demo writer writes, so nothing leaves the Mac. `write-rewrite` selects the
    /// notes first, so the card offers Rewrite.
    func applyDebugWriteStates() {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--snapshot-state=") }) else { return }
        let states = Set(argument.dropFirst("--snapshot-state=".count).split(separator: ",").map(String.init))
        let card = ["write-idle", "write-writing", "write-failed", "write-off", "write-rewrite"].first(where: states.contains)
        guard let card else { return }
        let center = environment.helpMeWrite
        center.configurationOverride = AIProviderConfiguration(kind: .claudeAPI)
        center.forcesOff = card == "write-off"
        center.consentOverride = [.claudeAPI]
        let script = center.demoScript
        script?.reply = "Tuesday at ten works for me. I\u{2019}ll bring the draft budget, and we can go through the open questions "
            + "on the venue together."
        switch card {
        case "write-writing":
            script?.holdsAfter = 7
        case "write-failed":
            script?.failure = .keyRefused
            script?.failsAfter = 3
        default:
            break
        }
        conversation.whenShownRenderLands(timeout: 10) { [weak self] _ in
            guard let self, self.conversation.focusQuickReply(all: false) else { return }
            let field = self.conversation.quickReplyBar.writingTextView
            field.insertText("tue 10 works, bring budget", replacementRange: NSRange(location: 0, length: (field.string as NSString).length))
            if card == "write-rewrite" { field.setSelectedRange(NSRange(location: 0, length: (field.string as NSString).length)) }
            self.conversation.helpMeWrite(nil)
            guard let session = self.conversation.writeSession else { return }
            if states.contains("key") {
                // A snapshot launched from a terminal may never be the key window: the card draws its key-window look.
                @MainActor func forceKey(_ view: NSView) {
                    (view as? QuireControl)?.windowKeyOverride = true
                    view.subviews.forEach(forceKey)
                }
                forceKey(session.card)
            }
            session.card.instruction = card == "write-idle" || card == "write-rewrite" ? "" : "Friendly, short"
            // As if typed: the caret after the words, not the whole field selected.
            let typed = (session.card.instruction as NSString).length
            (session.card.field.textField.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: typed, length: 0))
            if card == "write-writing" || card == "write-failed" { session.write() }
        }
    }
}
#endif
