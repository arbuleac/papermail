#if DEBUG
import AppKit
import SSCore

/// `--snapshot-state=trackers` (debug builds, with `--demo`): Block trackers on and remote images loaded for the run, and
/// the reader on the demo's tracker sample (spec §5.60), so a render shows its pictures loaded, its three trackers held
/// back and the card's “3 trackers blocked”. `trackers-held` is the same with remote images held back, so the images
/// banner leaves the trackers out of its count. Both are held in memory for the run (`keepsExperimentsInMemory`, and the
/// reader's own image preference), never saved or reported, and nothing reaches the network: the sample's pictures are
/// made on this Mac (`DemoStandInSanitizer`) and its trackers never load.
extension MainWindowController {
    private static var trackerStates: Set<String> {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--snapshot-state=") }) else { return [] }
        return Set(argument.dropFirst("--snapshot-state=".count).split(separator: ",").map(String.init))
            .intersection(["trackers", "trackers-held"])
    }

    /// Before the first selection, so its first render is already under the run's settings.
    func applyDebugTrackerStates() {
        let states = Self.trackerStates
        guard !states.isEmpty else { return }
        let settings = AppSettings.shared
        settings.keepsExperimentsInMemory = true
        settings.blocksTrackers = true
        ConversationViewController.loadRemoteImages = !states.contains("trackers-held")
    }

    /// The tracker sample's conversation, when a tracker state asks for it and the list shows it.
    func debugTrackerSampleConversation() -> ConversationID? {
        guard !Self.trackerStates.isEmpty else { return nil }
        let store = environment.store
        return list.conversations.first { row in
            ((try? store.messages(in: row.id)) ?? []).contains(where: DemoTrackerSample.isSample)
        }?.id
    }
}
#endif
