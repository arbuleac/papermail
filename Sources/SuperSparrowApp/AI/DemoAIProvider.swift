import Foundation
import SSCore
import os

/// The demo's writer (spec §5.56): one of the demo's canned replies (`DemoAIReplies`), streamed a couple of words at a
/// time with a short pause between, so Help Me Write can be shown, rendered and tested with nothing leaving the Mac.
/// The demo, the snapshots and every app test use it, whatever provider Settings › AI names.
struct DemoAIProvider: AIProvider {
    let kind: AIProviderKind = .demo
    let script: DemoAIScript

    var destination: AIDestination { .thisMac }

    func health() async -> AIHealth {
        script.health
    }

    func write(_ request: AIWriteRequest) -> AsyncThrowingStream<AIWriteEvent, Error> {
        let script = script
        return AsyncThrowingStream { continuation in
            let task = Task {
                let plan = script.begin(request)
                do {
                    for (index, chunk) in plan.chunks.enumerated() {
                        if let failure = plan.failure, index == plan.failsAfter { throw failure }
                        if let hold = plan.holdsAfter, index == hold {
                            // The writing snapshot: the stream rests mid-reply until it is stopped.
                            while !Task.isCancelled { try await Task.sleep(for: .milliseconds(50)) }
                        }
                        try await Task.sleep(for: plan.delay)
                        continuation.yield(.text(chunk))
                    }
                    if let failure = plan.failure { throw failure }
                    continuation.yield(.usage(AIUsage(inputTokens: request.userTurn.count / 4, outputTokens: plan.chunks.count)))
                    continuation.yield(.finished(.done))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// How the demo writer behaves, and what it was asked: shared by every `DemoAIProvider` an environment resolves, so the
/// app's tests and the snapshots can make it fail, pause or write a given reply, and check that nothing was asked before
/// the user allowed it.
final class DemoAIScript: @unchecked Sendable {
    struct Plan: Sendable {
        var chunks: [String]
        var delay: Duration
        var failure: AIError?
        var failsAfter: Int
        var holdsAfter: Int?
    }

    private let lock = OSAllocatedUnfairLock()
    private var _reply: String?
    private var _delay: Duration = .milliseconds(35)
    private var _failure: AIError?
    private var _failsAfter = 0
    private var _holdsAfter: Int?
    private var _health: AIHealth = .ready(detail: "Demo · replies are made up on this Mac")
    private var _requests: [AIWriteRequest] = []

    /// The reply to write; nil writes the demo's canned reply for the request.
    var reply: String? {
        get { lock.withLock { _reply } }
        set { lock.withLock { _reply = newValue } }
    }

    /// The pause before each chunk.
    var delay: Duration {
        get { lock.withLock { _delay } }
        set { lock.withLock { _delay = newValue } }
    }

    /// Thrown after `failsAfter` chunks have streamed; nil writes the whole reply.
    var failure: AIError? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }

    var failsAfter: Int {
        get { lock.withLock { _failsAfter } }
        set { lock.withLock { _failsAfter = newValue } }
    }

    /// Rests after this many chunks until the write is stopped (the writing snapshot).
    var holdsAfter: Int? {
        get { lock.withLock { _holdsAfter } }
        set { lock.withLock { _holdsAfter = newValue } }
    }

    var health: AIHealth {
        get { lock.withLock { _health } }
        set { lock.withLock { _health = newValue } }
    }

    /// Every request the writer was handed, oldest first. In memory only; the demo's mail is made up.
    var requests: [AIWriteRequest] {
        lock.withLock { _requests }
    }

    fileprivate func begin(_ request: AIWriteRequest) -> Plan {
        lock.withLock {
            _requests.append(request)
            let text = _reply ?? DemoAIReplies.reply(for: request)
            return Plan(chunks: Self.chunks(of: text), delay: _delay, failure: _failure, failsAfter: _failsAfter, holdsAfter: _holdsAfter)
        }
    }

    /// Two words at a time, each with the space or line break after it, as a model's deltas come.
    static func chunks(of text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        var words = 0
        for character in text {
            current.append(character)
            if character.isWhitespace {
                words += 1
                if words == 2 {
                    chunks.append(current)
                    current = ""
                    words = 0
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
