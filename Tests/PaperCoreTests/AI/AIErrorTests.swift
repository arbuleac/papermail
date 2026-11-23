import XCTest
@testable import PaperCore

/// The failure vocabulary: its words (spec §1.6), its mapping, and the rule that no error ever carries request text.
final class AIErrorTests: XCTestCase {
    static let everyCase: [AIError] = [
        .keyRefused, .missingKey, .signedOut, .planLimit, .noCredit, .rateLimited(retryAfter: nil), .rateLimited(retryAfter: 1),
        .rateLimited(retryAfter: 30), .rateLimited(retryAfter: 90), .overloaded, .refused, .modelUnavailable, .notInstalled,
        .unsupportedVersion(found: "2.1.322 (Claude Code)"), .newerVersion(found: "3.0.1"), .toolsStayOn(found: "codex-cli 0.163.0"),
        .otherSignIn, .timedOut, .offline, .cancelled, .badResponse(code: 0),
        .badResponse(code: 529), .busy, .emptyReply, .unavailable, .consentRequired, .tooLong(selection: true),
        .tooLong(selection: false), .instructionTooLong,
    ]

    // MARK: Words

    func testTheSpecsWords() {
        XCTAssertEqual(AIError.keyRefused.message(for: .claudeAPI), "The Anthropic API key was refused")
        XCTAssertEqual(AIError.signedOut.message(for: .claudeCode), "Claude Code is signed out. Run claude in Terminal to sign in.")
        XCTAssertEqual(AIError.signedOut.message(for: .codex), "Codex is signed out. Run codex login in Terminal.")
        XCTAssertEqual(AIError.planLimit.message(for: .claudeCode), "Your Claude plan's limit is reached")
        XCTAssertEqual(AIError.planLimit.message(for: .codex), "Your ChatGPT plan's limit is reached")
        XCTAssertEqual(AIError.noCredit.message(for: .openAIAPI), "OpenAI says the key has no credit")
        XCTAssertEqual(AIError.notInstalled.message(for: .codex), "Codex isn't installed")
        XCTAssertEqual(AIError.offline.message(for: .claudeAPI), "No connection")
        XCTAssertEqual(AIError.overloaded.message(for: .claudeAPI), "Anthropic is busy. Try again in a moment.")
        XCTAssertEqual(AIError.refused.message(for: .claudeAPI), "Claude declined to write this.")
        XCTAssertEqual(AIError.refused.message(for: .claudeCode), "Claude declined to write this.")
    }

    func testOtherWords() {
        XCTAssertEqual(AIError.keyRefused.message(for: .claudeCode), AIError.signedOut.message(for: .claudeCode))
        XCTAssertEqual(AIError.signedOut.message(for: .openAIAPI), "The OpenAI API key was refused")
        XCTAssertEqual(AIError.missingKey.message(for: .openAIAPI), "Add your OpenAI API key in Settings › AI")
        XCTAssertEqual(AIError.rateLimited(retryAfter: 30).message(for: .openAIAPI), "OpenAI is limiting requests. Try again in 30 seconds.")
        XCTAssertEqual(AIError.rateLimited(retryAfter: 0.4).message(for: .claudeAPI), "Anthropic is limiting requests. Try again in a second.")
        XCTAssertEqual(AIError.rateLimited(retryAfter: 61).message(for: .claudeAPI), "Anthropic is limiting requests. Try again in 2 minutes.")
        XCTAssertEqual(AIError.rateLimited(retryAfter: nil).message(for: .claudeAPI), "Anthropic is limiting requests. Try again in a moment.")
        XCTAssertEqual(AIError.unsupportedVersion(found: "codex-cli 0.99.1\nextra").message(for: .codex),
                       "Codex 0.99.1 is too old. Update it, then try again.")
        XCTAssertEqual(AIError.newerVersion(found: "3.0.1 (Claude Code)").message(for: .claudeCode),
                       "Claude Code 3.0.1 is newer than this version of Paper supports", "updating cannot help: no “Update it”")
        XCTAssertEqual(AIError.otherSignIn.message(for: .claudeCode), "Claude Code isn't using your claude.ai sign-in")
        XCTAssertEqual(AIError.toolsStayOn(found: "codex-cli 0.163.0").message(for: .codex),
                       "Codex 0.163.0 can't turn its tools off, so Help Me Write doesn't use it")
        XCTAssertEqual(AIError.tooLong(selection: true).message(for: .claudeAPI),
                       "The selection is too long to rewrite. Select less, then try again.")
        XCTAssertEqual(AIError.tooLong(selection: false).message(for: .codex),
                       "Your draft is too long to send as notes. Shorten it, or select a part to rewrite.")
        XCTAssertEqual(AIError.instructionTooLong.message(for: .claudeAPI), "Your instruction is too long. Shorten it.")
        XCTAssertEqual(AIError.instructionTooLong.lineMessage(for: .claudeCode), "Your instruction is too long. Shorten it.")
        XCTAssertFalse(AIError.instructionTooLong.needsSettings)
        XCTAssertEqual(AIError.badResponse(code: 529).message(for: .claudeAPI), "Unexpected answer from Anthropic (code 529)")
        XCTAssertEqual(AIError.badResponse(code: 1).message(for: .claudeCode), "Unexpected answer from Claude Code (code 1)")
        XCTAssertEqual(AIError.timedOut.message(for: .codex), "Codex took too long to answer")
        XCTAssertEqual(AIError.timedOut.message(for: .openAIAPI), "OpenAI took too long to answer")
        XCTAssertEqual(AIError.consentRequired.message(for: .codex), "Turn Codex on in Settings \u{203a} AI first")
        XCTAssertEqual(AIError.refused.message(for: .codex), "Codex declined to write this.")
        XCTAssertEqual(AIError.refused.message(for: .openAIAPI), "The model declined to write this.")
    }

    /// The tool row's words leave Try again and Settings… to the links beside them, and keep a wait the provider named.
    func testTheLinesWordsNeverRepeatItsLinks() {
        XCTAssertEqual(AIError.rateLimited(retryAfter: 30).lineMessage(for: .claudeAPI), "Anthropic is limiting requests. Wait 30 seconds.")
        XCTAssertEqual(AIError.rateLimited(retryAfter: nil).lineMessage(for: .claudeAPI), "Anthropic is limiting requests")
        XCTAssertEqual(AIError.overloaded.lineMessage(for: .claudeAPI), "Anthropic is busy")
        XCTAssertEqual(AIError.emptyReply.lineMessage(for: .claudeAPI), "Nothing came back")
        XCTAssertEqual(AIError.modelUnavailable.lineMessage(for: .claudeAPI), "That model isn't available")
        XCTAssertEqual(AIError.missingKey.lineMessage(for: .claudeAPI), "Add your Anthropic API key")
        XCTAssertEqual(AIError.unsupportedVersion(found: "2.0.1").lineMessage(for: .claudeCode), "Claude Code 2.0.1 is too old. Update it.")
        XCTAssertEqual(AIError.keyRefused.lineMessage(for: .claudeAPI), AIError.keyRefused.message(for: .claudeAPI))
        XCTAssertEqual(AIError.signedOut.lineMessage(for: .claudeCode), "Claude Code is signed out. Run claude in Terminal.",
                       "as Settings › AI says it, short enough to show whole in the default reader")
        XCTAssertEqual(AIError.keyRefused.lineMessage(for: .claudeCode), AIError.signedOut.lineMessage(for: .claudeCode))
        for error in Self.everyCase {
            for kind in AIProviderKind.allCases + [nil] {
                let words = error.lineMessage(for: kind)
                XCTAssertFalse(words.isEmpty)
                XCTAssertFalse(words.lowercased().contains("try again"), "\(error) says Try again beside its link: \(words)")
                if error.needsSettings {
                    XCTAssertFalse(words.contains("in Settings \u{203a} AI.") && error != .consentRequired,
                                   "\(error) names Settings beside its link: \(words)")
                }
            }
        }
    }

    func testEveryCaseHasWordsForEveryKindAndWithout() {
        for error in Self.everyCase {
            XCTAssertFalse(error.message(for: nil).isEmpty)
            XCTAssertEqual(error.errorDescription, error.message(for: nil))
            XCTAssertEqual(error.localizedDescription, error.message(for: nil))
            XCTAssertEqual(String(describing: error), error.message(for: nil))
            XCTAssertEqual(error.message(for: .demo), error.message(for: nil), "the demo writer gets the neutral words")
            for kind in AIProviderKind.allCases {
                let words = error.message(for: kind)
                XCTAssertFalse(words.isEmpty)
                XCTAssertFalse(words.contains("Optional"), words)
            }
        }
    }

    func testOnlySettingsFixableErrorsOfferSettings() {
        XCTAssertEqual(Self.everyCase.filter(\.needsSettings),
                       [.keyRefused, .missingKey, .signedOut, .modelUnavailable, .notInstalled,
                        .unsupportedVersion(found: "2.1.322 (Claude Code)"), .newerVersion(found: "3.0.1"),
                        .toolsStayOn(found: "codex-cli 0.163.0"), .otherSignIn, .unavailable, .consentRequired])
    }

    func testAVersionKeepsOnlyItsDigitsAndDots() {
        XCTAssertEqual(AIError.sanitizedVersion("2.1.322 (Claude Code)"), "2.1.322")
        XCTAssertEqual(AIError.sanitizedVersion("codex-cli 0.163.0"), "0.163.0")
        XCTAssertEqual(AIError.sanitizedVersion("v1."), "1")
        XCTAssertEqual(AIError.sanitizedVersion("Here is the secret plan"), "")
        XCTAssertEqual(AIError.sanitizedVersion(String(repeating: "9", count: 40)).count, 16)
    }

    // MARK: Mapping

    func testMappingWhatProvidersThrow() {
        XCTAssertEqual(AIError.from(AIError.planLimit), .planLimit)
        XCTAssertEqual(AIError.from(CancellationError()), .cancelled)
        XCTAssertEqual(AIError.from(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(AIError.from(URLError(.networkConnectionLost)), .offline)
        XCTAssertEqual(AIError.from(URLError(.cannotFindHost)), .offline)
        XCTAssertEqual(AIError.from(URLError(.timedOut)), .timedOut)
        XCTAssertEqual(AIError.from(URLError(.cancelled)), .cancelled)
        XCTAssertEqual(AIError.from(URLError(.badServerResponse)), .badResponse(code: 0))
        XCTAssertEqual(AIError.from(NSError(domain: "x", code: 7)), .badResponse(code: 0))
    }

    // MARK: No request text, ever

    /// Words that cannot occur in the fixed text by chance, so finding any window of them means a leak.
    private static func distinctiveText(_ generator: inout SeededGenerator, words: Int) -> String {
        (0..<words).map { _ in
            String((0..<9).map { _ in Character(Unicode.Scalar(UInt8(97 + Int(generator.next() % 26)))) })
        }.joined(separator: " ")
    }

    /// Every six-character window of `text` that is not white space.
    static func windows(of text: String, size: Int = 6) -> Set<String> {
        let characters = Array(text)
        guard characters.count >= size else { return [] }
        return Set((0...(characters.count - size)).map { String(characters[$0..<($0 + size)]) }
            .filter { !$0.contains(where: \.isWhitespace) })
    }

    func testNoDescriptionContainsRequestText() {
        var generator = SeededGenerator(seed: 0xA1)
        for round in 0..<25 {
            let instruction = Self.distinctiveText(&generator, words: 4)
            let transcript = Self.distinctiveText(&generator, words: 30)
            let notes = Self.distinctiveText(&generator, words: 8)
            let output = Self.distinctiveText(&generator, words: 10)
            let leaks = Self.windows(of: instruction + " " + transcript + " " + notes + " " + output)
            // Even errors built carelessly from request text (a version string, an underlying error's message) must not
            // carry it into words.
            let built: [AIError] = Self.everyCase + [
                .unsupportedVersion(found: transcript), .unsupportedVersion(found: "1.2 " + notes),
                .newerVersion(found: transcript), .newerVersion(found: "3.1 " + notes),
                .toolsStayOn(found: transcript), .toolsStayOn(found: "0.2 " + output),
                AIError.from(NSError(domain: transcript, code: 3, userInfo: [NSLocalizedDescriptionKey: output])),
                AIError.from(URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: instruction])),
            ]
            for error in built {
                var texts = [error.description, error.debugDescription, error.localizedDescription, String(reflecting: error)]
                texts += AIProviderKind.allCases.map { error.message(for: $0) }
                for text in texts {
                    let found = Self.windows(of: text).intersection(leaks)
                    XCTAssertTrue(found.isEmpty, "round \(round): \(error) leaked \(found)")
                }
            }
        }
    }
}
