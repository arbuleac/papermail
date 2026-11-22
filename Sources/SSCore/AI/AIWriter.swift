import Foundation
import os

/// The service the UI calls for Help Me Write; the UI never calls a provider. Owned by `AppEnvironment`, one per window
/// graph. It resolves the configured provider, refuses without the permission given in Settings › AI, runs one write
/// per field, enforces the deadline, turns Stop into a clean end, and maps every failure to an `AIError`.
///
/// It reaches beyond this Mac only for an `AIUserAction` (spec §3b): `write` and `check` take one, `localHealth` needs
/// none because it looks at this Mac alone.
///
/// Reading the stream: zero or more `.text` / `.replaceAll` / `.usage`, then exactly one `.finished(.done | .maxTokens |
/// .cancelled)`, or one thrown `AIError` (refusals, empty replies and timeouts included). `.finished(.cancelled)` comes
/// only from `stop(_:)`, `stopAll()` and a write asked for after `shutDown()`. Cancelling the consuming task also ends the
/// write, silently.
///
/// Nothing is sent before `write` is called and the stream is iterated. Content is never logged: the log carries the
/// provider kind, the prompt version and character counts, at debug level.
@MainActor
public final class AIWriter {
    /// Builds the provider for a configuration: `AIProviderFactory.provider(for:)` in the app, the demo writer in demo
    /// mode and tests. Nil means it cannot be built here (`AIError.unavailable`).
    public typealias Resolve = @Sendable (AIProviderConfiguration) -> (any AIProvider)?
    /// Whether the user allowed this provider (AppSettings). Checked again here so no path can send without it.
    public typealias Consent = @MainActor (AIProviderKind) -> Bool
    /// Where milestones go: the app's crash-report breadcrumbs and analytics, with the field the write is in, so the app
    /// can tell its writes apart.
    public typealias Milestones = @MainActor (AIWriteMilestone, AIProviderKind, AIFieldID) -> Void

    private static let logger = Logger(subsystem: "io.supersparrow.mac", category: "ai")
    private static let signposter = OSSignposter(subsystem: "io.supersparrow.mac", category: "ai")

    @MainActor private final class Run {
        // Main-actor state like the writer's own; only the gate is touched from the provider's task.
        let gate: AIStreamGate
        let kind: AIProviderKind
        let field: AIFieldID
        let signpost: OSSignpostIntervalState
        var task: Task<Void, Never>?

        init(gate: AIStreamGate, kind: AIProviderKind, field: AIFieldID, signpost: OSSignpostIntervalState) {
            self.gate = gate
            self.kind = kind
            self.field = field
            self.signpost = signpost
        }
    }

    private let resolve: Resolve
    private let hasConsent: Consent
    private let milestones: Milestones
    private var runs: [AIFieldID: Run] = [:]
    /// The checks under way (Settings' Check, a key saved with Return), so `shutDown()` can end them.
    private var checks: [UUID: Task<AIHealth, Never>] = [:]
    /// Set by `shutDown()`: the environment is going away, and no write or check starts after it.
    public private(set) var isShutDown = false

    public init(resolve: @escaping Resolve, hasConsent: @escaping Consent, milestones: @escaping Milestones = { _, _, _ in }) {
        self.resolve = resolve
        self.hasConsent = hasConsent
        self.milestones = milestones
    }

    /// Whether a write is running in `field`: ⌘J and Write are disabled while it is.
    public func isWriting(in field: AIFieldID) -> Bool {
        runs[field] != nil
    }

    /// Whether any write is running.
    public var isWriting: Bool { !runs.isEmpty }

    /// Starts a write into `field` for the user's `action`. Errors arrive through the stream, never thrown here: `busy`
    /// when the field is already writing, `consentRequired` before the user turned `configuration.kind` on in Settings ›
    /// AI, `unavailable` when no provider can be built.
    public func write(_ request: AIWriteRequest, using configuration: AIProviderConfiguration, in field: AIFieldID,
                      action: AIUserAction) -> AsyncThrowingStream<AIWriteEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: AIWriteEvent.self, throwing: Error.self)
        let gate = AIStreamGate(continuation)
        let kind = configuration.kind
        // A write asked for after the environment went away (one still building its context as the app quit) sends
        // nothing: it ends as a stop from outside would.
        guard !isShutDown else {
            gate.close(.finished(.cancelled))
            return stream
        }
        guard runs[field] == nil else {
            gate.close(.failed(.busy))
            return stream
        }
        // The demo writer sends nothing anywhere, so it needs no permission.
        guard kind == .demo || hasConsent(kind) else {
            gate.close(.failed(.consentRequired))
            return stream
        }
        guard let provider = resolve(configuration) else {
            gate.close(.failed(.unavailable))
            return stream
        }

        let run = Run(gate: gate, kind: kind, field: field, signpost: Self.signposter.beginInterval("ai.write"))
        runs[field] = run
        Self.logger.debug("Write started: \(kind.rawValue, privacy: .public), prompt \(request.promptVersion, privacy: .public), \(request.transcript.count, privacy: .public)+\(request.task.count, privacy: .public) characters")
        milestones(.started, kind, field)

        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { @MainActor [weak self] in self?.consumerLeft(run, field: field) }
        }
        // The task keeps the writer until the write's bookkeeping is done (at most the deadline), so a writer the
        // caller let go of still reports how its last write ended.
        run.task = Task.detached(priority: .userInitiated) {
            let ending = await Self.relay(provider.write(request, action: action), deadline: request.deadline, into: gate)
            let closedHere = gate.close(ending)
            await self.complete(run, field: field, ending: ending, closedHere: closedHere)
        }
        return stream
    }

    /// Stops the write in `field`: its stream yields `.finished(.cancelled)` and ends, the provider's request is
    /// cancelled (the process ends), and the field is free at once for a new write.
    public func stop(_ field: AIFieldID) {
        guard let run = runs.removeValue(forKey: field) else { return }
        run.task?.cancel()
        if run.gate.close(.finished(.cancelled)) {
            end(run, .stopped)
        }
    }

    /// Stops every write, as when the window graph goes away.
    public func stopAll() {
        for field in Array(runs.keys) { stop(field) }
    }

    /// Stops every write and check and refuses every later one: the environment is going away (quit, Leave Demo), and a
    /// write still on its way to `write` (its context being built) or a check must not start once its CLIs have been
    /// ended. Quitting is never a reason to reach a provider (spec §3b).
    public func shutDown() {
        isShutDown = true
        stopAll()
        for check in checks.values { check.cancel() }
        checks = [:]
    }

    /// The provider's health from this Mac alone (no network, no process): Settings › AI's status line as it opens and
    /// whether the reply's text shows Help me write's marks.
    public func localHealth(of configuration: AIProviderConfiguration) -> AIHealth {
        guard let provider = resolve(configuration) else {
            return .unavailable(reason: AIError.unavailable.message(for: configuration.kind))
        }
        return provider.localHealth()
    }

    /// Settings' Check button, or a key just saved: the provider's deeper check (an API key's authenticated GET, a CLI's
    /// version and sign-in), for the user's `action`.
    /// After `shutDown()` it answers from this Mac alone and sends nothing; `shutDown()` cancels one under way.
    public func check(_ configuration: AIProviderConfiguration, action: AIUserAction) async -> AIHealth {
        guard !isShutDown else { return localHealth(of: configuration) }
        guard let provider = resolve(configuration) else {
            return .unavailable(reason: AIError.unavailable.message(for: configuration.kind))
        }
        let id = UUID()
        let task = Task { await provider.check(action) }
        checks[id] = task
        defer { checks[id] = nil }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// Whether a check is under way (tests).
    public var isChecking: Bool { !checks.isEmpty }

    // MARK: Running

    /// Copies the provider's events into `gate` until it finishes, fails, or the deadline passes, whichever is first.
    /// Losing the race cancels the provider's stream, which cancels its request.
    nonisolated private static func relay(_ events: AsyncThrowingStream<AIWriteEvent, Error>, deadline: Duration,
                                          into gate: AIStreamGate) async -> AIStreamGate.Ending {
        do {
            return try await withThrowingTaskGroup(of: AIStreamGate.Ending.self) { group in
                group.addTask {
                    var wroteSomething = false
                    for try await event in events {
                        switch event {
                        case .text(let text):
                            guard !text.isEmpty else { continue }
                            if !wroteSomething { wroteSomething = text.contains { !$0.isWhitespace } }
                            gate.yield(event)
                        case .replaceAll(let text):
                            wroteSomething = text.contains { !$0.isWhitespace }
                            gate.yield(event)
                        case .usage:
                            gate.yield(event)
                        case .finished(let stop):
                            return ending(for: stop, wroteSomething: wroteSomething)
                        }
                    }
                    try Task.checkCancellation()
                    // A stream that ends without saying so ended normally.
                    return ending(for: .done, wroteSomething: wroteSomething)
                }
                group.addTask {
                    try await Task.sleep(for: deadline)
                    throw AIError.timedOut
                }
                guard let first = try await group.next() else { return .failed(.cancelled) }
                group.cancelAll()
                return first
            }
        } catch {
            return .failed(AIError.from(error))
        }
    }

    nonisolated private static func ending(for stop: AIStop, wroteSomething: Bool) -> AIStreamGate.Ending {
        switch stop {
        case .done, .maxTokens: return wroteSomething ? .finished(stop) : .failed(.emptyReply)
        case .refused: return .failed(.refused)
        case .cancelled: return .failed(.cancelled)
        }
    }

    private func complete(_ run: Run, field: AIFieldID, ending: AIStreamGate.Ending, closedHere: Bool) {
        if runs[field] === run { runs[field] = nil }
        guard closedHere else { return }
        switch ending {
        case .finished:
            end(run, .finished)
        case .failed(let error):
            Self.logger.info("Write failed: \(run.kind.rawValue, privacy: .public), \(error.description, privacy: .public)")
            end(run, .failed)
        case .abandoned:
            end(run, .stopped)
        }
    }

    private func consumerLeft(_ run: Run, field: AIFieldID) {
        guard runs[field] === run else { return }
        runs[field] = nil
        run.task?.cancel()
        if run.gate.close(.abandoned) { end(run, .stopped) }
    }

    private func end(_ run: Run, _ milestone: AIWriteMilestone) {
        Self.signposter.endInterval("ai.write", run.signpost)
        Self.logger.debug("Write ended: \(run.kind.rawValue, privacy: .public), \(String(describing: milestone), privacy: .public)")
        milestones(milestone, run.kind, run.field)
    }
}
