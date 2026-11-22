import Foundation

/// What Help Me Write writes in demo mode, the snapshots and the app tests: the demo's own canned replies, so the
/// feature can be shown with nothing leaving the Mac. The app's demo writer streams one of these.
public enum DemoAIReplies {
    public static let replies: [String] = DemoCatalog.replies

    /// The reply for `request`, the same on every run for the same request (a snapshot must not change), different
    /// across asks.
    public static func reply(for request: AIWriteRequest) -> String {
        // FNV-1a over the user's part: `hashValue` changes from launch to launch.
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in request.task.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return replies[Int(hash % UInt64(replies.count))]
    }
}
