import Foundation
import os
import SSCore

/// One streamed write over HTTP, shared by the Anthropic and OpenAI providers: sends the request, checks the status
/// before reading the body as SSE (OpenAI answers a bad key with a `text/plain` JSON body), feeds the bytes through
/// `SSEParser` into the provider's decoder, and passes the steps on. A failure before any text is retried once
/// (`HTTPRetryPolicy`); after text, never.
///
/// The request and the replies are mail: neither is logged above debug, and neither reaches an error. The log carries
/// the provider kind, statuses, attempt numbers and counts.
struct HTTPStreamingWrite<Decoder: HTTPStreamDecoding>: Sendable {
    let session: URLSession
    let request: URLRequest
    let kind: AIProviderKind
    /// The user's action this write answers: every attempt is recorded against it (`AIEgress`).
    let action: AIUserAction
    /// Maps an error reply to the error and whether it is worth retrying.
    let mapReply: @Sendable (HTTPErrorReply) -> (error: AIError, retryable: Bool)
    var pause: HTTPRetryPolicy.Pause = HTTPRetryPolicy.sleep

    /// Error documents are a few hundred bytes; anything longer is not one.
    static var maxErrorBody: Int { 64 * 1024 }

    private static var logger: Logger { Logger(subsystem: "io.supersparrow.mac", category: "ai") }

    /// An API provider's `write`: on the stream's first read, reads the key (no key, or a Keychain that will not give
    /// it, is `missingKey` before anything is sent), builds the request with it, and runs the write.
    static func stream(kind: AIProviderKind, keys: any AIKeyStoring, session: URLSession, pause: @escaping HTTPRetryPolicy.Pause,
                       action: AIUserAction, makeRequest: @escaping @Sendable (_ key: String) throws -> URLRequest,
                       mapReply: @escaping @Sendable (HTTPErrorReply) -> (error: AIError, retryable: Bool))
        -> AsyncThrowingStream<AIWriteEvent, Error> {
        HTTPEventStream.make { continuation in
            let key: String
            do {
                guard let stored = try keys.key(for: kind), !stored.isEmpty else { throw AIError.missingKey }
                key = stored
            } catch {
                continuation.finish(throwing: AIError.missingKey)
                return
            }
            let request: URLRequest
            do {
                request = try makeRequest(key)
            } catch {
                continuation.finish(throwing: AIError.badResponse(code: 0))
                return
            }
            await HTTPStreamingWrite(session: session, request: request, kind: kind, action: action, mapReply: mapReply, pause: pause)
                .run(into: continuation)
        }
    }

    private enum AttemptEnd {
        case finished(AIStop)
        case failed(AIError, retryable: Bool, retryAfter: TimeInterval?)
    }

    /// Runs the write to its end and closes `continuation` with exactly one `.finished` or one `AIError`.
    func run(into continuation: HTTPEventStream.Continuation) async {
        var shownText = false
        var attempt = 1
        while true {
            let end = await self.attempt(attempt, shownText: &shownText, into: continuation)
            switch end {
            case .finished(let stop):
                Self.logger.debug("\(kind.rawValue, privacy: .public) reply finished: \(stop.rawValue, privacy: .public), attempt \(attempt, privacy: .public)")
                continuation.yield(.finished(stop))
                continuation.finish()
                return
            case .failed(let error, let retryable, let retryAfter):
                if retryable, !shownText, attempt < HTTPRetryPolicy.attempts, !Task.isCancelled,
                   let delay = HTTPRetryPolicy.delay(after: retryAfter) {
                    Self.logger.debug("\(kind.rawValue, privacy: .public) attempt \(attempt, privacy: .public) failed (\(error.description, privacy: .public)); retrying in \(delay, privacy: .public) s")
                    do {
                        try await pause(delay)
                    } catch {
                        continuation.finish(throwing: AIError.cancelled)
                        return
                    }
                    attempt += 1
                    continue
                }
                Self.logger.debug("\(kind.rawValue, privacy: .public) attempt \(attempt, privacy: .public) failed: \(error.description, privacy: .public)")
                continuation.finish(throwing: error)
                return
            }
        }
    }

    private func attempt(_ number: Int, shownText: inout Bool, into continuation: HTTPEventStream.Continuation) async -> AttemptEnd {
        do {
            let (bytes, response) = try await ProviderHTTP.bytes(for: request, on: session, by: action)
            // Whatever ends this attempt (a refusal mid-stream, a failure step, the reader leaving) ends the transfer.
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else {
                return .failed(.badResponse(code: 0), retryable: false, retryAfter: nil)
            }
            Self.logger.debug("\(kind.rawValue, privacy: .public) attempt \(number, privacy: .public): HTTP \(http.statusCode, privacy: .public)")
            guard (200...299).contains(http.statusCode) else {
                let body = try await Self.prefix(of: bytes, limit: Self.maxErrorBody)
                let reply = HTTPErrorReply(response: http, body: body)
                let mapped = mapReply(reply)
                return .failed(mapped.error, retryable: mapped.retryable && reply.shouldRetry != false, retryAfter: reply.retryAfter)
            }

            var parser = SSEParser()
            var decoder = Decoder()
            for try await byte in bytes {
                guard let event = parser.feed(byte) else { continue }
                if let end = deliver(decoder.decode(event), shownText: &shownText, into: continuation) { return end }
            }
            try Task.checkCancellation()
            if let event = parser.finish(),
               let end = deliver(decoder.decode(event), shownText: &shownText, into: continuation) {
                return end
            }
            return deliver(decoder.streamEnded(), shownText: &shownText, into: continuation)
                ?? .failed(.badResponse(code: 0), retryable: true, retryAfter: nil)
        } catch {
            return .failed(AIError.from(error), retryable: Self.isRetryable(error), retryAfter: nil)
        }
    }

    /// Passes steps on; returns how the attempt ended when a step ended it.
    private func deliver(_ steps: [HTTPStreamStep], shownText: inout Bool,
                         into continuation: HTTPEventStream.Continuation) -> AttemptEnd? {
        for step in steps {
            switch step {
            case .emit(let event):
                switch event {
                case .text(let text), .replaceAll(let text):
                    if !text.isEmpty { shownText = true }
                case .usage, .finished:
                    break
                }
                continuation.yield(event)
            case .finish(let stop):
                return .finished(stop)
            case .fail(let error, let retryable):
                return .failed(error, retryable: retryable, retryAfter: nil)
            }
        }
        return nil
    }

    /// A connection that broke before the reply could start; not one that never existed (offline) or timed out
    /// (a retry would spend another minute of the write's two).
    private static func isRetryable(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return error.code == .networkConnectionLost || error.code == .cannotConnectToHost
    }

    /// The start of an error body, enough for its `error.type` and `code`.
    private static func prefix(of bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { break }
        }
        return data
    }
}
