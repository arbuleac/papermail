#if DEBUG
import AppKit
import SSCore

/// `--live-write-check=<report.json>` (debug builds, demo mode only): Help Me Write once, end to end, with the provider
/// `--ai-provider` and `--ai-model` choose (with `--live-ai-clis`, the user's real Claude Code or Codex), over the demo's
/// made-up mail. It types notes into the first inbox conversation's quick reply, opens the card, checks the provider's
/// health, presses Write, answers the real consent sheet with Allow (the demo's earlier Allow for that provider is
/// forgotten first, so the sheet asks), and reports when the first words reached the field, when the reply landed,
/// what landed and the undo step, or the failure's words. A provider that is not ready is still sent the Write, as
/// Try Again would, to show that its own pre-send check refuses it.
///
/// The report holds the demo's reply in full: a debug aid's output, on made-up mail, written only where its caller asked.
@MainActor
final class LiveWriteCheck {
    /// The check under way: nothing else holds it while it waits on the card.
    private static var current: LiveWriteCheck?

    static let notes = "thu 3pm works, I will bring the mockups"
    static let instruction = "Short and friendly."

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
    private var configuration: AIProviderConfiguration?
    private let clock = ContinuousClock()
    private var pressed: ContinuousClock.Instant?
    private var allowed: ContinuousClock.Instant?
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
        self.configuration = configuration
        let kind = configuration.kind
        report["provider"] = kind.rawValue
        report["model"] = configuration.model ?? NSNull()
        report["resolvedModel"] = configuration.resolvedModel ?? NSNull()
        report["sourceLine"] = center.sourceLine(for: configuration)
        report["madeUpOnThisMac"] = center.makesUpReplies(for: kind)
        report["notes"] = Self.notes
        report["instruction"] = Self.instruction
        report["consentGivenBefore"] = center.hasConsent(for: kind)
        // So the sheet asks in this run: the demo's own Allow for this provider, never the user's.
        settings.setAIConsent(false, for: kind, demo: center.isDemo, live: center.sendsFromTheDemo(kind))
        let present = center.presentAlert
        center.presentAlert = { [weak self] alert, window, completion in
            self?.sheetShown(alert)
            present(alert, window, completion)
            // A click on Allow a moment after the sheet shows, on the system's own sheet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated { self?.pressAllow(on: window) }
            }
        }
        let conversation = window.conversation
        conversation.whenShownRenderLands(timeout: 10) { [weak self] _ in
            guard let self else { return }
            guard conversation.focusQuickReply(all: false) else {
                self.report["error"] = "no quick reply"
                self.end()
                return
            }
            let field = conversation.quickReplyBar.writingTextView
            field.insertText(Self.notes, replacementRange: NSRange(location: 0, length: (field.string as NSString).length))
            conversation.helpMeWrite(nil)
            guard let session = conversation.writeSession else {
                self.report["error"] = "the card did not open"
                self.end()
                return
            }
            self.session = session
            Task { @MainActor in
                let started = self.clock.now
                let health = await self.center.writer.health(of: configuration)
                self.report["health"] = ["ready": health.isReady, "words": health.words,
                                         "ms": Self.milliseconds(self.clock.now - started)] as [String: Any]
                // The card asks for itself as it opens: a moment for its answer to show before reading it.
                if !health.isReady {
                    for _ in 0..<100 where session.state == .idle { try? await Task.sleep(for: .milliseconds(20)) }
                }
                self.report["cardStateAfterHealth"] = Self.describe(session.state)
                session.card.instruction = Self.instruction
                self.report["forcedWriteWhileNotReady"] = !health.isReady
                self.pressed = self.clock.now
                self.watch(field: field)
                session.write()
            }
        }
    }

    private func sheetShown(_ alert: AppAlert) {
        report["consentSheet"] = ["title": alert.title, "body": alert.body, "buttons": alert.buttons.map(\.title),
                                  "shownMsAfterWrite": pressed.map { Self.milliseconds(clock.now - $0) } ?? NSNull()] as [String: Any]
    }

    private func pressAllow(on window: NSWindow?) {
        guard let sheet = window?.attachedSheet, let content = sheet.contentView else {
            report["consentAnswer"] = "no sheet on the window"
            return
        }
        let buttons = Self.buttons(in: content)
        // Which button ↩ presses: the sheet's default button, or the one holding Return as its key.
        report["consentDefaultButton"] = sheet.defaultButtonCell?.title
            ?? buttons.first { $0.keyEquivalent == "\r" }?.title ?? NSNull()
        guard let allow = buttons.first(where: { $0.title == "Allow" }) else {
            report["consentAnswer"] = "no Allow button"
            return
        }
        allowed = clock.now
        report["allowedAt"] = Date().timeIntervalSince1970
        report["consentAnswer"] = "Allow"
        allow.performClick(nil)
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons(in:))
    }

    /// Every 2 ms: when the card starts writing, when the field first changes from the notes, and how the write ends.
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
        if writing == nil, session.state == .writing { writing = now }
        if firstText == nil, writing != nil, field.string != Self.notes {
            firstText = now
            report["firstTextCharacters"] = (field.string as NSString).length
        }
        if case .failed(let reason, let offersSettings) = session.state {
            report["outcome"] = "failed"
            report["failure"] = ["reason": reason, "offersSettings": offersSettings] as [String: Any]
            report["fieldAfter"] = field.string
            report["fieldRestored"] = field.string == Self.notes
            end()
        } else if !session.isOpen {
            report["outcome"] = "inserted"
            report["inserted"] = field.string
            report["undoActionName"] = field.undoManager?.undoActionName ?? NSNull()
            end()
        }
    }

    private func end() {
        guard !finished else { return }
        finished = true
        monitor?.invalidate()
        let origin = allowed ?? pressed
        func since(_ instant: ContinuousClock.Instant?) -> Any {
            guard let origin, let instant else { return NSNull() }
            return Self.milliseconds(instant - origin)
        }
        report["timesFrom"] = allowed != nil ? "Allow clicked" : "Write pressed"
        report["writingMs"] = since(writing)
        report["firstTextMs"] = since(firstText)
        report["totalMs"] = since(clock.now)
        report["endedAt"] = Date().timeIntervalSince1970
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            FileManager.default.createFile(atPath: reportPath, contents: data)
        }
        Self.current = nil
        // The CLI is gone once the card closed or failed; a moment for its folder to go too.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [done] in MainActor.assumeIsolated { done() } }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }

    private static func describe(_ state: WriteCardView.State) -> String {
        switch state {
        case .off: return "off"
        case .idle: return "idle"
        case .writing: return "writing"
        case .needsSetup(let reason): return "needsSetup: " + reason
        case .failed(let reason, _): return "failed: " + reason
        }
    }
}
#endif
