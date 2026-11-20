import Foundation
import os

/// The service the UI calls for Help Me Write; the UI never calls a provider. Owned by `AppEnvironment`, one per window
/// graph. It resolves the configured provider, refuses without consent, runs one write per field, enforces the
/// deadline, turns Stop into a clean end, and maps every failure to an `AIError`.
///
/// Reading the stream: zero or more `.text` / `.replaceAll` / `.usage`, then exactly one `.finished(.done | .maxTokens |
/// .cancelled)`, or one thrown `AIError` (refusals, empty replies and timeouts included). `.finished(.cancelled)` comes
/// only from `stop(_:)`. Cancelling the consuming task also ends the write, silently.
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
    /// Where milestones go: the app's crash-report breadcrumbs.
    public typealias Milestones = @MainActor (AIWriteMilestone, AIProviderKind) -> Void

    private static let logger = Logger(subsystem: "io.supersparrow.mac", category: "ai")
    private static let signposter = OSSignposter(subsystem: "io.supersparrow.mac", category: "ai")

    @MainActor private final class Run {
        // Main-actor state like the writer's own; only the gate is touched from the provider's task.
        let gate: AIStreamGate
        let kind: AIProviderKind
        let signpost: OSSignpostIntervalState
        var task: Task<Void, Never>?

        init(gate: AIStreamGate, kind: AIProviderKind, signpost: OSSignpostIntervalState) {
            self.gate = gate
            self.kind = kind
            self.signpost = signpost
        }
    }

    private let resolve: Resolve
    private let hasConsent: Consent
    private let milestones: Milestones
    private var runs: [AIFieldID: Run] = [:]

    public init(resolve: @escaping Resolve, hasConsent: @escaping Consent, milestones: @escaping Milestones = { _, _ in }) {
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

    /// Starts a write into `field`. Errors arrive through the stream, never thrown here: `busy` when the field is
    /// already writing, `consentRequired` before the user allowed `configuration.kind`, `unavailable` when no provider
    /// can be built.
    public func write(_ request: AIWriteRequest, using configuration: AIProviderConfiguration,
                      in field: AIFieldID) -> AsyncThrowingStream<AIWriteEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: AIWriteEvent.self, throwing: Error.self)
        let gate = AIStreamGate(continuation)
        let kind = configuration.kind
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

        let run = Run(gate: gate, kind: kind, signpost: Self.signposter.beginInterval("ai.write"))
        runs[field] = run
        Self.logger.debug("Write started: \(kind.rawValue, privacy: .public), prompt \(request.promptVersion, privacy: .public), \(request.transcript.count, privacy: .public)+\(request.task.count, privacy: .public) characters")
        milestones(.started, kind)

        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { @MainActor [weak self] in self?.consumerLeft(run, field: field) }
        }
        // The task keeps the writer until the write's bookkeeping is done (at most the deadline), so a writer the
        // caller let go of still reports how its last write ended.
        run.task = Task.detached(priority: .userInitiated) {
            let ending = await Self.relay(provider.write(request), deadline: request.deadline, into: gate)
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

    /// The provider's health, for Settings › AI's status line and the card's “needs setup” state.
    public func health(of configuration: AIProviderConfiguration) async -> AIHealth {
        guard let provider = resolve(configuration) else {
            return .unavailable(reason: AIError.unavailable.message(for: configuration.kind))
        }
        return await provider.health()
    }

    /// Settings' Check button: the provider's deeper check (an API key's authenticated GET).
    public func check(_ configuration: AIProviderConfiguration) async -> AIHealth {
        guard let provider = resolve(configuration) else {
            return .unavailable(reason: AIError.unavailable.message(for: configuration.kind))
        }
        return await provider.check()
    }

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
        milestones(milestone, run.kind)
    }
}
