import Foundation

/// Token counts a provider reports, for the debug log and later a cost hint. Optional everywhere: Codex reports them
/// only at the end and a CLI may not at all.
public struct AIUsage: Sendable, Hashable {
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}
