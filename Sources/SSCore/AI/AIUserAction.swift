import Foundation

/// Proof that the user asked for Help Me Write to reach beyond this Mac (spec §3b): nothing is sent to Anthropic or
/// OpenAI, and none of the user's CLIs is started, unless the user acts. Every provider request and every CLI launch
/// takes one of these (`AIWriter.write`, `AIWriter.check`, `AIProvider.write`, `AIProvider.check`, and in SSAI each
/// `URLSession` call and each `CLICommand`), so a call site without a user action does not compile.
///
/// Only the handlers of the user's own actions make one: Write, ⌘J, ⇧⌘J, a preset chip and Try again
/// (`WriteSession`); Settings › AI's Check button and saving a key (`AISettingsModel`); and the debug-only live check.
/// `HelpMeWriteEgressTests` holds the list: a new `AIUserAction(userPressed:)` elsewhere fails it.
public struct AIUserAction: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        /// Write, ⌘J, ⇧⌘J, a preset chip or Try again: the request, and for a CLI its version and sign-in check right
        /// before it.
        case write
        /// Settings › AI's Check, or a key just saved: the provider's models list, or the CLI's version and sign-in.
        case check
        /// The debug-only live check (`--live-write-check`), on the demo's made-up mail.
        case liveCheck
    }

    public let kind: Kind

    /// The user pressed something that sends: see the type's list of the only places that may say so.
    public init(userPressed kind: Kind) {
        self.kind = kind
    }
}
