import Foundation

/// What the reader shows of one message, which its printout follows (spec §5.48): its remote images, its quoted text and,
/// under an invitation card, the message itself. Read from the shell's cards at print time (`window.ss.cardStates()`),
/// because only the shell knows what the user loaded, unfolded or showed since the conversation opened.
public struct PrintSheetState: Hashable, Sendable {
    /// The reader shows the message's remote images: the preference was on when it rendered, or Load images was used.
    public var imagesShown: Bool
    /// The quoted text is unfolded (spec §5.15).
    public var quotesShown: Bool
    /// The message under an invitation card is unfolded (spec §5.14).
    public var messageShown: Bool
    /// Remote sources the reader found live in the body (stored while Load remote images was on) and holds back with the
    /// parked ones, so the printout counts what its images banner counts. Zero for a message whose body never loaded.
    public var liveRemoteImages: Int

    public init(imagesShown: Bool, quotesShown: Bool = false, messageShown: Bool = false, liveRemoteImages: Int = 0) {
        self.imagesShown = imagesShown
        self.quotesShown = quotesShown
        self.messageShown = messageShown
        self.liveRemoteImages = liveRemoteImages
    }

    /// A message as a fresh render shows it: images as the preference says, quoted text and the message under a card
    /// folded. What a message prints as when the shell has no card for it.
    public static func fresh(loadRemoteImages: Bool) -> PrintSheetState {
        PrintSheetState(imagesShown: loadRemoteImages)
    }

    /// The states `window.ss.cardStates()` returned, by render key. Anything the shell did not say (an entry without an
    /// id, a missing flag, a reply that is not a list) is left out or read as a fresh render shows it, so a shell that
    /// cannot answer prints the conversation as it opens, never with more images than the reader loaded.
    public static func states(fromShell result: Any?, loadRemoteImages: Bool) -> [String: PrintSheetState] {
        guard let cards = result as? [[String: Any]] else { return [:] }
        var states: [String: PrintSheetState] = [:]
        for card in cards {
            guard let id = card["id"] as? String, !id.isEmpty else { continue }
            states[id] = PrintSheetState(
                imagesShown: (card["imagesLoaded"] as? Bool) ?? loadRemoteImages,
                quotesShown: (card["quotesShown"] as? Bool) ?? false,
                messageShown: (card["messageShown"] as? Bool) ?? false,
                liveRemoteImages: max(0, (card["liveRemote"] as? NSNumber)?.intValue ?? 0)
            )
        }
        return states
    }
}
