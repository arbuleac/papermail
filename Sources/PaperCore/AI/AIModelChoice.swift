import Foundation

/// One entry of Settings › AI's Model popup.
public struct AIModelChoice: Sendable, Hashable, Identifiable {
    /// The id sent to the provider: an API model id (“claude-opus-5-5”) or a CLI alias (“haiku”). Nil is the
    /// CLI's own default, for which no model flag is passed at all.
    public var model: String?
    /// The popup title and, for API providers, the source line's model name.
    public var title: String

    public init(model: String?, title: String) {
        self.model = model
        self.title = title
    }

    public var id: String { model ?? "" }
}
