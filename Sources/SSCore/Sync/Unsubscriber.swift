import Foundation

/// Sends the unsubscribe requests the outbox holds (`MetadataChange.unsubscribe`): an RFC 8058 one-click POST to the
/// sender's server, or a mailto request sent from the account through the provider's own send. Neither is a change
/// to the provider's copy of the mail, so `OperationRunner` sends them apart from the account's other operations.
///
/// The POST is the one request the engine makes to somewhere other than Google or Microsoft. It goes out on a
/// session of its own (`configuration()`): ephemeral, no cookies sent or kept, no stored credentials, no cache, a
/// short timeout, and redirects followed only to https. Nothing of the user's goes with it beyond what the sender put
/// in the URI. The URI itself can identify the user, so it is never logged above debug.
final class Unsubscriber: @unchecked Sendable {
    enum Outcome: Equatable, Sendable {
        case sent
        /// Refused for good (a 4xx, a redirect away from https, a provider that rejects the message): the operation
        /// is dropped quietly. The reason carries no URI.
        case refused(String)
        /// Worth another try. `counted` false for what passes on its own (no network, the provider's throttle on a
        /// mailto send, a stop), which never gives up; true for a sender's server that failed or keeps throttling
        /// (5xx, 408, 429, a timeout), which gives up after `SyncTuning.maxOperationAttempts`.
        case retry(counted: Bool, retryAfter: TimeInterval?)
        /// The provider refused the account's token (a mailto request only).
        case needsReauth
    }

    /// Per request: the whole exchange, a redirect included, ends within the resource timeout.
    static let requestTimeout: TimeInterval = 15
    static let resourceTimeout: TimeInterval = 30

    /// A fresh configuration per request; tests replace it with one whose stub protocol answers.
    let configuration: @Sendable () -> URLSessionConfiguration
    /// The one-click requests running off the live cycle, by operation id. Guarded by `lock`.
    private var inFlight: [String: Task<Void, Never>] = [:]
    private let lock = NSLock()

    init(configuration: @escaping @Sendable () -> URLSessionConfiguration = { Unsubscriber.configuration() }) {
        self.configuration = configuration
    }

    // MARK: Off the cycle

    /// Runs `work` for operation `id` on a task of its own, unless one for it is still running. The live lane's
    /// cycle never waits for it.
    func detach(_ id: String, _ work: @escaping @Sendable () async -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard inFlight[id] == nil else { return }
        inFlight[id] = Task.detached(priority: .utility) { [weak self] in
            await work()
            self?.finished(id)
        }
    }

    private func finished(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        inFlight[id] = nil
    }

    /// Stops every request under way (the engine is stopping): each row stays pending for the next run.
    func cancelAll() {
        lock.lock(); defer { lock.unlock() }
        for task in inFlight.values { task.cancel() }
    }

    /// Returns once every request under way has ended and written its row.
    func waitForAll() async {
        let tasks = lock.withLock { Array(inFlight.values) }
        for task in tasks { await task.value }
    }

    /// Ephemeral and stateless: nothing from the user's browsing, Google or Microsoft rides along, and nothing the
    /// sender's server sets is kept.
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        return configuration
    }

    // MARK: One-click

    /// POSTs `List-Unsubscribe=One-Click`, form encoded, to `url` (RFC 8058 §3.2).
    func postOneClick(to url: URL) async -> Outcome {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(UnsubscribeMethod.oneClickBody.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpShouldHandleCookies = false
        // One session per request, invalidated once it is done: unsubscribes are rare, and an idle engine keeps no
        // session (or its connections) open for them.
        let session = URLSession(configuration: configuration())
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(for: request, delegate: HTTPSOnlyRedirects())
            guard let http = response as? HTTPURLResponse else { return .retry(counted: true, retryAfter: nil) }
            return Self.outcome(status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        } catch let error as URLError {
            // A stop cancels the task, and the row waits for the next run; any other cancellation is the server's.
            return Task.isCancelled ? .retry(counted: false, retryAfter: nil) : Self.outcome(error)
        } catch is CancellationError {
            return .retry(counted: false, retryAfter: nil)
        } catch {
            return .retry(counted: true, retryAfter: nil)
        }
    }

    /// A refused redirect leaves its 3xx as the answer: the request never reached a page that could act on it, and
    /// asking again would be refused the same way.
    static func outcome(status: Int, retryAfter: String?) -> Outcome {
        switch status {
        case 200..<300:
            return .sent
        case 408, 429:
            return .retry(counted: true, retryAfter: retryAfter.flatMap(TimeInterval.init))
        case 300..<500:
            return .refused("status \(status)")
        default:
            return .retry(counted: true, retryAfter: nil)
        }
    }

    /// Offline, or the connection dropped: try again when the network is back, as every operation does. A server that
    /// is down or unreachable while the Mac is online counts toward giving up, so a dead sender is not asked for ever.
    static func outcome(_ error: URLError) -> Outcome {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            return .retry(counted: false, retryAfter: nil)
        default:
            return .retry(counted: true, retryAfter: nil)
        }
    }

    // MARK: Mailto

    /// Sends the request `method` describes from `accountID` through the provider's send: no undo window, nothing in
    /// the outbox's sending count. The provider files it in Sent, where the next poll finds it.
    func sendMail(_ method: UnsubscribeMethod, from accountID: AccountID, via provider: MailProvider) async -> Outcome {
        guard let message = method.mailMessage(from: accountID) else { return .refused("not one recipient") }
        do {
            _ = try await provider.send(message)
            return .sent
        } catch let error as ProviderError {
            switch error {
            case .throttled(let retryAfter):
                return .retry(counted: false, retryAfter: retryAfter)
            case .network, .cancelled:
                return .retry(counted: false, retryAfter: nil)
            case .unauthorized:
                return .needsReauth
            case .notFound:
                return .refused("not found")
            case .server(let status, _) where (400..<500).contains(status) && status != 408 && status != 429:
                return .refused("status \(status)")
            case .server, .decoding, .resetRequired:
                return .retry(counted: true, retryAfter: nil)
            }
        } catch is CancellationError {
            return .retry(counted: false, retryAfter: nil)
        } catch {
            return .retry(counted: true, retryAfter: nil)
        }
    }
}

/// Follows a redirect only to https, so a one-click request never goes out in the clear, and answers no
/// authentication challenge but the server's own certificate check: the request carries no credentials.
final class HTTPSOnlyRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        request.url?.scheme?.lowercased() == "https" ? request : nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        Self.disposition(for: challenge.protectionSpace.authenticationMethod)
    }

    /// Declined, not cancelled: a password challenge then ends in its 401, which drops the request as any 4xx does,
    /// and a TLS server that asks for a client certificate goes on without one. Cancelling would end the task as
    /// `URLError.cancelled` and hide the server's answer. Default handling is not used: it can answer Negotiate with
    /// the user's own Kerberos ticket.
    static func disposition(for authenticationMethod: String) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        authenticationMethod == NSURLAuthenticationMethodServerTrust ? (.performDefaultHandling, nil) : (.rejectProtectionSpace, nil)
    }
}
