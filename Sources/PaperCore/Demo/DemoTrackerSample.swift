import Foundation

/// The demo's tracker sample (spec §5.60, `--snapshot-state=trackers`): Trailhead Outfitters' newest issue, whose hero and
/// product tiles are remote images the demo answers on this Mac (`DemoStandInSanitizer`), and which carries a known
/// open-tracking pixel and a hidden one beside the 1 px pixel every demo newsletter has.
public enum DemoTrackerSample {
    public static let sender = "news@trailhead-outfitters.test"
    static let issue = 128

    static func isSample(_ letter: DemoCatalog.Newsletter, issue: Int) -> Bool {
        letter.sender.address == sender && issue == self.issue
    }

    /// Whether `message` is the sample, as the demo's mailbox lists it.
    public static func isSample(_ message: MessageMetadata) -> Bool {
        message.from?.address == sender && message.subject.contains("#\(issue):")
    }
}
