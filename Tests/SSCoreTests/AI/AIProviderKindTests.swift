import XCTest
@testable import SSCore

/// The provider catalogue Settings › AI and the card read: destinations, models, source lines.
final class AIProviderKindTests: XCTestCase {
    func testRawValuesNeverChange() {
        // Stored in AppSettings and used as the Keychain item's account: renaming one loses the user's choice and key.
        XCTAssertEqual(AIProviderKind.allCases.map(\.rawValue), ["claudeAPI", "claudeCode", "openAIAPI", "codex", "demo"])
    }

    func testDestinations() {
        XCTAssertEqual(AIProviderKind.allCases.map(\.destination), [.anthropic, .anthropic, .openAI, .openAI, .thisMac])
        XCTAssertEqual(AIDestination.allCases.map(\.displayName), ["Anthropic", "OpenAI", "this Mac"])
    }

    func testSettingsOffersTheFourRealOnesGroupedByDestination() {
        XCTAssertEqual(AIProviderKind.selectable, [.claudeAPI, .claudeCode, .openAIAPI, .codex])
        XCTAssertEqual(AIProviderKind.selectable.filter(\.usesAPIKey), [.claudeAPI, .openAIAPI])
        XCTAssertEqual(AIProviderKind.selectable.compactMap(\.executableName), ["claude", "codex"])
    }

    func testModelChoicesAndDefaults() {
        XCTAssertEqual(AIProviderKind.claudeAPI.modelChoices.map(\.model), ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"])
        XCTAssertEqual(AIProviderKind.openAIAPI.modelChoices.map(\.model), ["gpt-6.1-terra", "gpt-6.2-sol", "gpt-6.2-astra", "gpt-6-luna"])
        XCTAssertEqual(AIProviderKind.claudeCode.modelChoices.map(\.model), [nil, "opus", "sonnet", "haiku"])
        XCTAssertEqual(AIProviderKind.codex.modelChoices.map(\.model), [nil, "gpt-6-luna", "gpt-6.1-terra", "gpt-6.2-sol"])
        XCTAssertEqual(AIProviderKind.claudeAPI.defaultModel, "claude-opus-5-5")
        XCTAssertEqual(AIProviderKind.openAIAPI.defaultModel, "gpt-6.1-terra")
        XCTAssertNil(AIProviderKind.claudeCode.defaultModel)
        XCTAssertNil(AIProviderKind.codex.defaultModel)
        XCTAssertEqual(AIProviderKind.claudeCode.modelChoices.first?.id, "", "Default has a stable id for the popup")
    }

    func testAModelThisBuildNoLongerOffersFallsBackToTheDefault() {
        XCTAssertEqual(AIProviderConfiguration(kind: .claudeAPI, model: "claude-haiku-5-5").resolvedModel, "claude-haiku-5-5")
        XCTAssertEqual(AIProviderConfiguration(kind: .claudeAPI, model: "claude-old-1").resolvedModel, "claude-opus-5-5")
        XCTAssertEqual(AIProviderConfiguration(kind: .openAIAPI, model: "haiku").resolvedModel, "gpt-6.1-terra")
        XCTAssertNil(AIProviderConfiguration(kind: .codex, model: "gpt-1").resolvedModel)
        XCTAssertEqual(AIProviderConfiguration(kind: .codex, model: "gpt-6-luna").resolvedModel, "gpt-6-luna")
    }

    func testTheCardsSourceLine() {
        XCTAssertEqual(AIProviderConfiguration(kind: .claudeAPI).sourceLine, "Claude Opus 5.5 · Anthropic")
        XCTAssertEqual(AIProviderConfiguration(kind: .claudeAPI, model: "claude-sonnet-5-5").sourceLine, "Claude Sonnet 5.5 · Anthropic")
        XCTAssertEqual(AIProviderConfiguration(kind: .claudeCode, model: "haiku").sourceLine, "Claude Code · Anthropic")
        XCTAssertEqual(AIProviderConfiguration(kind: .openAIAPI).sourceLine, "GPT-6.1 Terra · OpenAI")
        XCTAssertEqual(AIProviderConfiguration(kind: .codex).sourceLine, "Codex · OpenAI")
        XCTAssertEqual(AIProviderConfiguration(kind: .demo).sourceLine, "Demo · this Mac")
    }

    func testAConfigurationRoundTripsThroughCodable() throws {
        let configuration = AIProviderConfiguration(kind: .codex, model: "gpt-6-luna", cliPath: "/opt/homebrew/bin/codex")
        let decoded = try JSONDecoder().decode(AIProviderConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(decoded, configuration)
    }

    func testBreadcrumbNamesAreTheRawValuesAndMilestonesAreWords() {
        for kind in AIProviderKind.allCases {
            XCTAssertEqual("\(kind.breadcrumbName)", kind.rawValue)
        }
        XCTAssertEqual(AIWriteMilestone.allCases.map { "\($0.breadcrumbName)" },
                       ["write started", "write finished", "write failed", "write stopped"])
    }

    func testHealthWords() {
        XCTAssertTrue(AIHealth.ready(detail: "Ready · Claude Opus 5.5").isReady)
        XCTAssertFalse(AIHealth.needsSetup(reason: "Add your API key").isReady)
        XCTAssertEqual(AIHealth.needsSetup(reason: "Add your API key").words, "Add your API key")
        XCTAssertEqual(AIHealth.unavailable(reason: "No connection").words, "No connection")
    }

    func testWriteAskKnowsARewrite() {
        XCTAssertTrue(WriteAsk(draft: .selection("x")).isRewrite)
        XCTAssertFalse(WriteAsk(draft: .notes("x")).isRewrite)
        XCTAssertFalse(WriteAsk().isRewrite)
    }
}
