import Foundation
import PaperCore
import os

/// The demo's writer (spec §5.56): one of the demo's canned drafts (`DemoAIReplies`, picked by what the request
/// writes), streamed a couple of words at a time with a short pause between, so Help Me Write can be shown, rendered
/// and tested with nothing leaving the Mac. The demo, the snapshots and every app test use it, whatever provider
/// Settings › AI names.
///
/// Where a new message's request asks for a subject it answers as a model would, a first line `Subject: …`, an empty
/// line, then the message, so the demo's subject reaches the composer through the same split a provider's does.
struct DemoAIProvider: AIProvider {
    let kind: AIProviderKind = .demo
    let script: DemoAIScript

    var destination: AIDestination { .thisMac }

    func localHealth() -> AIHealth {
        script.health
    }

    func write(_ request: AIWriteRequest, action: AIUserAction) -> AsyncThrowingStream<AIWriteEvent, Error> {
        let script = script
        return AsyncThrowingStream { continuation in
            let task = Task {
                let plan = script.begin(request)
                do {
                    for chunk in plan.subjectLine {
                        try await Task.sleep(for: plan.delay)
                        continuation.yield(.text(chunk))
                    }
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
                    continuation.yield(.usage(AIUsage(inputTokens: request.userTurn.count / 4,
                                                      outputTokens: plan.subjectLine.count + plan.chunks.count)))
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
        /// The answer's subject line and the empty line under it, in chunks; none unless the answer opens with one.
        var subjectLine: [String]
        /// The message, in chunks: `failsAfter` and `holdsAfter` count these, so a write fails or rests as far into the
        /// message as it is asked to, whether or not a subject line came first.
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
    private var _health: AIHealth = .ready(detail: "Demo · drafts are made up on this Mac")
    private var _requests: [AIWriteRequest] = []

    /// The answer to write, as a model would send it (a new message's may open with its `Subject:` line); nil writes
    /// the demo's canned draft for the request.
    var reply: String? {
        get { lock.withLock { _reply } }
        set { lock.withLock { _reply = newValue } }
    }

    /// The pause before each chunk.
    var delay: Duration {
        get { lock.withLock { _delay } }
        set { lock.withLock { _delay = newValue } }
    }

    /// Thrown after `failsAfter` chunks of the message have streamed; nil writes the whole draft.
    var failure: AIError? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }

    var failsAfter: Int {
        get { lock.withLock { _failsAfter } }
        set { lock.withLock { _failsAfter = newValue } }
    }

    /// Rests after this many chunks of the message until the write is stopped (the writing snapshot).
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
            let answer = Self.answer(_reply, for: request)
            return Plan(subjectLine: Self.chunks(of: answer.subjectLine), chunks: Self.chunks(of: answer.message), delay: _delay,
                        failure: _failure, failsAfter: _failsAfter, holdsAfter: _holdsAfter)
        }
    }

    /// The answer to `request` in its two parts: the subject line, with the empty line under it, and the message.
    /// The demo's own draft has a subject line only when the request asked for one. A scripted answer is taken as it
    /// is: where the writer would read its first line as a subject line (a new message's full write), that line is the
    /// first part, found by the split the writer itself uses.
    static func answer(_ scripted: String?, for request: AIWriteRequest) -> (subjectLine: String, message: String) {
        guard let scripted else {
            let draft = DemoAIReplies.draft(for: request)
            return (draft.subjectLine ?? "", draft.body)
        }
        guard request.readsSubjectLine else { return ("", scripted) }
        let split = WriteSubjectLine.split(scripted, final: true)
        guard split.subject != nil, !split.body.isEmpty, scripted.hasSuffix(split.body) else { return ("", scripted) }
        return (String(scripted.dropLast(split.body.count)), split.body)
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
