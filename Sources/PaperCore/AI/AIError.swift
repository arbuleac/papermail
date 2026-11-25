import Foundation

/// Why a write failed, in the one vocabulary every provider maps to. Providers throw these; `AIWriter` maps anything
/// else they throw (`AIError.from(_:)`), so the UI only ever sees an `AIError`.
///
/// No case carries text from the request, the model or a CLI's output: the descriptions are fixed words plus numbers
/// (a status code, seconds, a sanitised version), because error descriptions end up in logs and, through a careless
/// call, in crash reports, while the request is mail. Words name the provider through `message(for:)`, which the card
/// shows; `errorDescription` gives the same words without the provider's name.
public enum AIError: Error, Sendable, Hashable {
    /// The API key was rejected (HTTP 401).
    case keyRefused
    /// No API key is stored for an API provider.
    case missingKey
    /// The CLI is not signed in (`claude auth status`/`codex login status` failed, or an authentication error).
    case signedOut
    /// The user's Claude or ChatGPT plan, or the API usage limit, is used up.
    case planLimit
    /// The API account has no credit (Anthropic 402 `billing_error`, OpenAI 429 `insufficient_quota`).
    case noCredit
    /// Too many requests; `retryAfter` in seconds when the provider said.
    case rateLimited(retryAfter: TimeInterval?)
    /// The provider is overloaded (Anthropic 529 `overloaded_error`, OpenAI 503).
    case overloaded
    /// The model declined to write the reply.
    case refused
    /// The chosen model does not exist or this key or plan may not use it.
    case modelUnavailable
    /// The CLI was not found (standard folders, or the path chosen in Settings).
    case notInstalled
    /// The CLI is older than the versions this build was tested with, so updating it helps; `found` is its version (only
    /// its first dotted number reaches the words).
    case unsupportedVersion(found: String)
    /// The CLI is newer than the versions this build was tested with, or no longer takes the recipe's flags, features or
    /// settings: updating it cannot help (Claude Code updates itself). `found` as for `unsupportedVersion`.
    case newerVersion(found: String)
    /// The CLI's version still hands the model a tool under the recipe (Codex 0.163's code mode, its agents and its
    /// questions to the user), so it never runs: updating may help once a version is checked. `found` as for
    /// `unsupportedVersion`.
    case toolsStayOn(found: String)
    /// The CLI is set up to send somewhere other than the provider's own service under the user's own sign-in (another
    /// cloud, a gateway, an API key or a key helper): nothing goes through it, since the consent sheet named the company
    /// and the plan.
    case otherSignIn
    /// No answer within the deadline, or the CLI fell silent.
    case timedOut
    /// No network.
    case offline
    /// The write was cancelled without the user asking (the user's own Stop finishes the stream instead).
    case cancelled
    /// An answer this build cannot use: an HTTP status, a CLI exit status, or 0 when there was none.
    case badResponse(code: Int)
    /// A write is already running in this field (`AIWriter` allows one per field).
    case busy
    /// The model finished without writing anything.
    case emptyReply
    /// The provider cannot be used at all here (not built into this build, or nothing is configured).
    case unavailable
    /// The user has not turned this provider on in Settings › AI (its privacy sheet's Turn On): the writer refuses, and
    /// the reply's Write line says where to turn it on.
    case consentRequired
    /// The selection to rewrite (`selection`) or the notes are longer than Help Me Write sends
    /// (`ReplyContextBuilder.Limits.maxAskCharacters`): nothing is sent, rather than a cut part that the reply would
    /// then replace whole.
    case tooLong(selection: Bool)
    /// The instruction for a new message or a forward is longer than Help Me Write sends: nothing is sent, rather than
    /// a brief cut short (`WriteKind.lengthRefusal`). A reply's instruction is cut instead, as it always was.
    case instructionTooLong
    /// A rewrite's answer copied the rest of the user's draft (`WriteRewriteAnswer.repeatsDraft`, or an answer that was
    /// the draft and nothing else): it would have put the draft into itself, so nothing lands. The words carry nothing
    /// of the request.
    case rewriteRepeated

    /// Maps whatever a provider threw. Its own description is never read, since it may quote the request.
    public static func from(_ error: any Error) -> AIError {
        if let error = error as? AIError { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timedOut
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .internationalRoamingOff, .dataNotAllowed, .callIsActive:
                return .offline
            default: return .badResponse(code: 0)
            }
        }
        return .badResponse(code: 0)
    }

    /// Whether the fix is in Settings › AI, so the Write line offers Settings… beside Try again.
    public var needsSettings: Bool {
        switch self {
        case .keyRefused, .missingKey, .signedOut, .notInstalled, .unsupportedVersion, .newerVersion, .toolsStayOn,
             .otherSignIn, .modelUnavailable, .unavailable, .consentRequired:
            return true
        default:
            return false
        }
    }

    /// The card's reason line (spec §1.6), naming the provider: “The Anthropic API key was refused”, “Claude Code is
    /// signed out. Run claude in Terminal to sign in.” Nil `kind` gives the neutral words `errorDescription` uses.
    public func message(for kind: AIProviderKind?) -> String {
        // The demo writer has no company, key or plan of its own: it gets the neutral words.
        let kind = kind == .demo ? nil : kind
        let company = Self.company(kind)
        switch self {
        case .keyRefused:
            if let kind, !kind.usesAPIKey { return AIError.signedOut.message(for: kind) }
            return kind.map { "The \($0.destination.displayName) API key was refused" } ?? "The API key was refused"
        case .missingKey:
            return kind.map { "Add your \($0.destination.displayName) API key in Settings › AI" } ?? "Add your API key in Settings › AI"
        case .signedOut:
            switch kind {
            case .claudeCode: return "Claude Code is signed out. Run claude in Terminal to sign in."
            case .codex: return "Codex is signed out. Run codex login in Terminal."
            case .claudeAPI, .openAIAPI: return AIError.keyRefused.message(for: kind)
            case .demo, nil: return "You're signed out"
            }
        case .planLimit:
            switch kind {
            case .claudeCode: return "Your Claude plan's limit is reached"
            case .codex: return "Your ChatGPT plan's limit is reached"
            case .claudeAPI, .openAIAPI: return "Your \(company) usage limit is reached"
            case .demo, nil: return "Your plan's limit is reached"
            }
        case .noCredit:
            return "\(company) says the key has no credit"
        case .rateLimited(let retryAfter):
            return "\(company) is limiting requests. Try again \(Self.when(retryAfter))."
        case .overloaded:
            return "\(company) is busy. Try again in a moment."
        case .refused:
            switch kind {
            case .claudeAPI, .claudeCode: return "Claude declined to write this."
            case .codex: return "Codex declined to write this."
            case .openAIAPI, .demo, nil: return "The model declined to write this."
            }
        case .modelUnavailable:
            return "That model isn't available. Choose another in Settings › AI."
        case .notInstalled:
            return "\(Self.product(kind)) isn't installed"
        case .unsupportedVersion(let found):
            return "\(Self.productAndVersion(kind, found)) is too old. Update it, then try again."
        case .newerVersion(let found):
            return "\(Self.productAndVersion(kind, found)) is newer than this version of Paper supports"
        case .toolsStayOn(let found):
            return "\(Self.productAndVersion(kind, found)) can't turn its tools off, so Help Me Write doesn't use it"
        case .otherSignIn:
            switch kind {
            case .claudeCode: return "Claude Code isn't using your claude.ai sign-in"
            case .codex: return "Codex isn't using your own sign-in"
            case .claudeAPI, .openAIAPI, .demo, nil: return "\(Self.product(kind)) isn't using your own sign-in"
            }
        case .timedOut:
            return "\(Self.source(kind)) took too long to answer"
        case .offline:
            return "No connection"
        case .cancelled:
            return "Stopped"
        case .badResponse(let code):
            let source = kind == nil ? "the provider" : Self.source(kind)
            return code == 0 ? "Unexpected answer from \(source)" : "Unexpected answer from \(source) (code \(code))"
        case .busy:
            return "Help Me Write is already writing here"
        case .emptyReply:
            return "Nothing came back. Try again."
        case .unavailable:
            return kind.map { "\($0.displayName) isn't available right now" } ?? "Help Me Write isn't available right now"
        case .consentRequired:
            return kind.map { "Turn \($0.displayName) on in Settings \u{203a} AI first" } ?? "Turn it on in Settings \u{203a} AI"
        case .tooLong(let selection):
            return selection ? "The selection is too long to rewrite. Select less, then try again."
                : "Your draft is too long to send as notes. Shorten it, or select a part to rewrite."
        case .instructionTooLong:
            return "Your instruction is too long. Shorten it."
        case .rewriteRepeated:
            return "The rewrite repeated the rest of your draft. Try again."
        }
    }

    /// The reply's tool-row words (§5.56), where Try again and, when the fix is there, Settings… are links beside them:
    /// `message(for:)` without the closing “Try again …” or “… in Settings › AI” the links already say, so the line never
    /// says Try again twice and the reason keeps the room. A wait the provider named stays: “Wait 30 seconds.”
    public func lineMessage(for kind: AIProviderKind?) -> String {
        let kind = kind == .demo ? nil : kind
        switch self {
        case .rateLimited(let retryAfter):
            let limiting = "\(Self.company(kind)) is limiting requests"
            guard let wait = Self.wait(retryAfter) else { return limiting }
            return limiting + ". Wait \(wait)."
        case .overloaded:
            return "\(Self.company(kind)) is busy"
        case .emptyReply:
            return "Nothing came back"
        case .modelUnavailable:
            return "That model isn't available"
        case .missingKey:
            return kind.map { "Add your \($0.destination.displayName) API key" } ?? "Add your API key"
        case .unsupportedVersion(let found):
            return "\(Self.productAndVersion(kind, found)) is too old. Update it."
        case .signedOut where kind == .claudeCode:
            return "Claude Code is signed out. Run claude in Terminal."
        case .keyRefused where kind == .claudeCode:
            return AIError.signedOut.lineMessage(for: kind)
        case .tooLong(let selection):
            return selection ? "The selection is too long to rewrite. Select less." : message(for: kind)
        case .rewriteRepeated:
            return "The rewrite repeated the rest of your draft"
        default:
            return message(for: kind)
        }
    }

    /// The first dotted number in what a CLI printed (“2.1.322 (Claude Code)” gives “2.1.322”): digits and dots only,
    /// so nothing else the CLI wrote, or anything a provider put there by mistake, reaches the words.
    static func sanitizedVersion(_ found: String) -> String {
        var version = ""
        for character in found {
            if character.isASCII, character.isNumber {
                version.append(character)
            } else if character == ".", !version.isEmpty, version.last != "." {
                version.append(character)
            } else if !version.isEmpty {
                break
            }
            if version.count >= 16 { break }
        }
        while version.last == "." { version.removeLast() }
        return version
    }

    private static func company(_ kind: AIProviderKind?) -> String {
        kind?.destination.displayName ?? "The provider"
    }

    /// Who answered: the company for an API, the CLI for a CLI (its own process timed out or failed).
    private static func source(_ kind: AIProviderKind?) -> String {
        guard let kind else { return "The provider" }
        return kind.usesAPIKey ? kind.destination.displayName : kind.displayName
    }

    private static func product(_ kind: AIProviderKind?) -> String {
        kind?.displayName ?? "The tool"
    }

    /// “Claude Code 2.1.322”, or the product alone when nothing printed was a version.
    private static func productAndVersion(_ kind: AIProviderKind?, _ found: String) -> String {
        let version = sanitizedVersion(found)
        return product(kind) + (version.isEmpty ? "" : " \(version)")
    }

    private static func when(_ retryAfter: TimeInterval?) -> String {
        wait(retryAfter).map { "in " + $0 } ?? "in a moment"
    }

    /// “30 seconds”, “a minute”, “3 minutes”; nil when the provider named no wait.
    private static func wait(_ retryAfter: TimeInterval?) -> String? {
        guard let retryAfter, retryAfter.isFinite, retryAfter > 0 else { return nil }
        let seconds = Int(retryAfter.rounded(.up))
        if seconds <= 1 { return "a second" }
        if seconds < 60 { return "\(seconds) seconds" }
        let minutes = (seconds + 59) / 60
        return minutes == 1 ? "a minute" : "\(minutes) minutes"
    }
}

extension AIError: LocalizedError {
    public var errorDescription: String? { message(for: nil) }
}

/// `String(describing:)` and `String(reflecting:)` give the same fixed words, so a log line or a crash report that
/// prints the error carries no associated value in raw form.
extension AIError: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { message(for: nil) }
    public var debugDescription: String { "AIError: " + message(for: nil) }
}
