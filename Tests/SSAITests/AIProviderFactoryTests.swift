import XCTest
import SSCore
@testable import SSAI

/// The factory the app hands to `AIWriter`: the right adapter for each choice, built without sending or reading a key.
final class AIProviderFactoryTests: XCTestCase {
    private let keys = InMemoryAIKeyStore([.claudeAPI: "sk-ant-test", .openAIAPI: "sk-test"])
    private var factory: AIProviderFactory { AIProviderFactory(keys: keys) }

    func testEachKindGetsItsAdapter() throws {
        let anthropic = try XCTUnwrap(factory.provider(for: AIProviderConfiguration(kind: .claudeAPI, model: "claude-haiku-5-5"))
            as? AnthropicMessagesProvider)
        XCTAssertEqual(anthropic.model, "claude-haiku-5-5")
        let openAI = try XCTUnwrap(factory.provider(for: AIProviderConfiguration(kind: .openAIAPI)) as? OpenAIResponsesProvider)
        XCTAssertEqual(openAI.model, "gpt-6.1-terra", "the default when nothing was chosen")
        let claudeCode = try XCTUnwrap(factory.provider(for: AIProviderConfiguration(kind: .claudeCode, model: "haiku",
                                                                                       cliPath: "/Users/someone/bin/claude"))
            as? ClaudeCodeProvider)
        XCTAssertEqual(claudeCode.model, "haiku")
        XCTAssertEqual(claudeCode.executablePath, "/Users/someone/bin/claude")
        let codex = try XCTUnwrap(factory.provider(for: AIProviderConfiguration(kind: .codex, model: "gpt-9")) as? CodexProvider)
        XCTAssertNil(codex.model, "a model this build does not offer falls back to the CLI's own default")
        XCTAssertNil(codex.executablePath)
    }

    func testEveryAdapterNamesItsKindAndDestination() {
        for kind in AIProviderKind.selectable {
            let provider = factory.provider(for: AIProviderConfiguration(kind: kind))
            XCTAssertEqual(provider?.kind, kind)
            XCTAssertEqual(provider?.destination, kind.destination)
        }
    }

    func testTheDemoWriterIsTheAppsOwn() {
        XCTAssertNil(factory.provider(for: AIProviderConfiguration(kind: .demo)))
    }

    func testBuildingAProviderReadsNoKey() {
        for kind in AIProviderKind.allCases { _ = factory.provider(for: AIProviderConfiguration(kind: kind)) }
        XCTAssertEqual(keys.reads(of: .claudeAPI), 0)
        XCTAssertEqual(keys.reads(of: .openAIAPI), 0)
    }

    func testTheSessionKeepsNothing() {
        let configuration = AIProviderFactory.makeSession().configuration
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertFalse(configuration.waitsForConnectivity)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
    }

    func testTheAdaptersAreSharedAcrossProvidersOfOneFactory() throws {
        let session = URLSession(configuration: .ephemeral)
        let runner = CLIProcessRunner(temporaryDirectory: URL(fileURLWithPath: "/private/tmp/ss-ai-tests"))
        let factory = AIProviderFactory(keys: keys, session: session, runner: runner)
        let anthropic = try XCTUnwrap(factory.provider(for: AIProviderConfiguration(kind: .claudeAPI)) as? AnthropicMessagesProvider)
        XCTAssertTrue(anthropic.session === session)
        let codex = try XCTUnwrap(factory.provider(for: AIProviderConfiguration(kind: .codex)) as? CodexProvider)
        XCTAssertEqual(codex.runner.temporaryDirectory, runner.temporaryDirectory)
    }
}
