#if DEBUG
import AppKit
import PaperCore

/// `--live-write-check=<report.json>` (debug builds, demo mode only): Help Me Write once, end to end, with the provider
/// `--ai-provider` and `--ai-model` choose (with `--live-ai-clis`, the user's real Claude Code or Codex), over the demo's
/// made-up mail. It opens the demo's longest conversation (the thirteen-message offsite thread), types short notes into
/// its quick reply and presses ⌘J, as the user would; the provider is held turned on for the run (the demo's own
/// permission, never the user's). It reports the availability and the notes' ghost before, when the first words reached
/// the field, when the reply landed, what landed and its undo step, or the failure's words, and the exact context the
/// provider was given (the request's transcript and task), to show the thread newest first with older messages shortened.
///
/// The report holds the demo's reply and context in full: a debug aid's output, on made-up mail, written only where its
/// caller asked, never logged.
@MainActor
final class LiveWriteCheck {
    /// The check under way: nothing else holds it while it waits on the field.
    private static var current: LiveWriteCheck?

    static let notes = "yes to deposit, happy to do roadmap thu, invite new hires to wed dinner"
    static let threadSubject = "Team offsite: venue, dates and agenda"

    /// `--ai-provider` and `--ai-model`: the demo's provider for this process, held in memory, never saved.
    static func chooseProvider(_ options: LaunchOptions, for environment: AppEnvironment) {
        guard environment.isDemo, let raw = options.aiProvider, let kind = AIProviderKind(rawValue: raw) else { return }
        environment.helpMeWrite.configurationOverride = AIProviderConfiguration(kind: kind, model: options.aiModel)
    }

    static func run(in window: MainWindowController, center: HelpMeWrite, settings: AppSettings, report: String,
                    done: @escaping () -> Void) {
        let check = LiveWriteCheck(window: window, center: center, settings: settings, reportPath: report, done: done)
        current = check
        check.start()
    }

    private let window: MainWindowController
    private let center: HelpMeWrite
    private let settings: AppSettings
    private let reportPath: String
    private let done: () -> Void
    private var report: [String: Any] = [:]
    private var monitor: Timer?
    private var session: WriteSession?
    private let clock = ContinuousClock()
    private var pressed: ContinuousClock.Instant?
    private var writing: ContinuousClock.Instant?
    private var firstText: ContinuousClock.Instant?
    private var finished = false

    private init(window: MainWindowController, center: HelpMeWrite, settings: AppSettings, reportPath: String,
                 done: @escaping () -> Void) {
        self.window = window
        self.center = center
        self.settings = settings
        self.reportPath = reportPath
        self.done = done
    }

    private func start() {
        guard let configuration = center.configuration else {
            report["error"] = "Help Me Write is off: pass --ai-provider"
            end()
            return
        }
        let kind = configuration.kind
        report["provider"] = kind.rawValue
        report["model"] = configuration.model ?? NSNull()
        report["resolvedModel"] = configuration.resolvedModel ?? NSNull()
        report["sourceLine"] = center.sourceLine(for: configuration)
        report["madeUpOnThisMac"] = center.makesUpReplies(for: kind)
        report["notes"] = Self.notes
        // Turned on for this run only, as Settings › AI's sheet would: the demo's own permission, held in memory.
        center.consentOverride.insert(kind)
        report["permission"] = "held for the run (Settings › AI's Turn On)"
        WriteSession.requestObserver = { [weak self] request in
            self?.report["context"] = ["promptVersion": request.promptVersion, "transcript": request.transcript, "task": request.task,
                                       "userTurnCharacters": request.userTurn.count] as [String: Any]
        }
        let conversation = window.conversation
        guard let thread = Self.longestThread(in: window.environment.store) else {
            report["error"] = "no demo thread of ten or more messages"
            end()
            return
        }
        report["thread"] = ["subject": Self.threadSubject, "messages": thread.count] as [String: Any]
        window.reveal(thread.id)
        // The reader coalesces a selection's render: wait until it shows this thread (its quick reply restored for it),
        // then for its render, so nothing set after the notes are typed replaces them.
        waitForThread(thread.id, attempts: 0) { [weak self] in
            conversation.whenShownRenderLands(timeout: 10) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    MainActor.assumeIsolated { self?.typeAndPress(in: conversation) }
                }
            }
        }
    }

    private func waitForThread(_ id: ConversationID, attempts: Int, then: @escaping () -> Void) {
        if window.conversation.currentConversationID == id || attempts > 100 {
            report["threadShown"] = window.conversation.currentConversationID == id
            then()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.waitForThread(id, attempts: attempts + 1, then: then) }
        }
    }

    private func typeAndPress(in conversation: ConversationViewController) {
        guard conversation.focusQuickReply(all: false), let session = conversation.quickReplyWriteSession else {
            report["error"] = "no quick reply"
            end()
            return
        }
        self.session = session
        let field = conversation.quickReplyBar.writingTextView
        field.insertText(Self.notes, replacementRange: NSRange(location: 0, length: (field.string as NSString).length))
        session.refresh()
        report["fieldBefore"] = field.string
        report["availability"] = Self.describe(session.availability)
        session.showNotesGhostNow()
        report["hintShown"] = !session.layer.ghost.isHidden
        report["menuTitle"] = session.menuTitle(withInstructions: false)
        pressed = clock.now
        watch(field: field)
        // ⌘J, as the user presses it.
        conversation.helpMeWrite(nil)
    }

    /// The demo's offsite thread: the conversation with that subject and the most messages.
    private static func longestThread(in store: any MailStoring) -> (id: ConversationID, count: Int)? {
        let all = (try? store.conversations(ConversationQuery(view: .all, limit: .max))) ?? []
        let threads = all.filter { $0.subject.contains(threadSubject) && $0.messageCount >= 10 }
        return threads.max { $0.messageCount < $1.messageCount }.map { ($0.id, $0.messageCount) }
    }

    /// Every 2 ms: when the session is writing, when the field first changes from the notes, and how the write ends.
    private func watch(field: NSTextView) {
        let monitor = Timer(timeInterval: 0.002, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(field: field) }
        }
        RunLoop.main.add(monitor, forMode: .common)
        self.monitor = monitor
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.finished else { return }
                self.report["error"] = "no end within 180 s"
                self.end()
            }
        }
    }

    private func tick(field: NSTextView) {
        guard !finished, let session else { return }
        let now = clock.now
        if writing == nil, session.phase == .writing { writing = now }
        if firstText == nil, writing != nil, field.string != Self.notes {
            firstText = now
            report["firstTextCharacters"] = (field.string as NSString).length
        }
        switch session.phase {
        case .failed(let reason, let offersSettings):
            report["outcome"] = "failed"
            report["failure"] = ["reason": reason, "offersSettings": offersSettings] as [String: Any]
            report["fieldAfter"] = field.string
            report["fieldRestored"] = field.string == Self.notes
            end()
        case .written:
            report["outcome"] = "inserted"
            report["inserted"] = field.string
            report["line"] = session.layer.afterline.lineWords
            report["undoActionName"] = field.undoManager?.undoActionName ?? NSNull()
            report["menuTitleAfter"] = session.menuTitle(withInstructions: false)
            end()
        case .idle, .writing:
            break
        }
    }

    private func end() {
        guard !finished else { return }
        finished = true
        monitor?.invalidate()
        WriteSession.requestObserver = nil
        func since(_ instant: ContinuousClock.Instant?) -> Any {
            guard let pressed, let instant else { return NSNull() }
            return Self.milliseconds(instant - pressed)
        }
        report["timesFrom"] = "⌘J pressed"
        report["writingMs"] = since(writing)
        report["firstTextMs"] = since(firstText)
        report["totalMs"] = since(clock.now)
        report["endedAt"] = Date().timeIntervalSince1970
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            FileManager.default.createFile(atPath: reportPath, contents: data)
        }
        Self.current = nil
        // The CLI is gone once the reply landed or failed; a moment for its folder to go too.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [done] in MainActor.assumeIsolated { done() } }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }

    private static func describe(_ availability: WriteAvailability) -> String {
        switch availability {
        case .off: return "off"
        case .unavailable(let reason): return "unavailable: " + reason
        case .ready(let writer, let source): return "ready: \(writer) (\(source))"
        }
    }
}
#endif
