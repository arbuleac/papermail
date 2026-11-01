import Foundation
import SSCore

/// The sanitizer with the "Load remote images" preference read for every body, so a change applies to the
/// next body synced rather than after a relaunch. The reader gates remote fetches on its own as well,
/// which covers bodies stored under the other setting.
struct PreferenceSanitizer: BodySanitizing {
    func sanitize(_ body: MessageBody, messageID: MessageID) -> SanitizedBody {
        HTMLSanitizer(allowRemoteImages: AppSettings.loadRemoteImagesNow()).sanitize(body, messageID: messageID)
    }
}
