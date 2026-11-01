import Foundation
import SSCore

/// A message posted by the shell through `window.webkit.messageHandlers`. Bodies are untrusted
/// dictionaries, so parsing is total: anything malformed becomes nil and is ignored.
enum ConversationScriptMessage: Equatable {
    case ready
    case action(type: String, messageID: MessageID?, attachmentID: String?)
    case openLink(URL)
    case select(MessageID)

    init?(body: Any) {
        guard let dictionary = body as? [String: Any], let kind = dictionary["kind"] as? String else { return nil }
        switch kind {
        case "ready":
            self = .ready
        case "action":
            guard let type = dictionary["type"] as? String else { return nil }
            let messageID = (dictionary["messageID"] as? String).flatMap(RenderPayload.messageID(fromKey:))
            let attachmentID = dictionary["attachmentID"] as? String
            self = .action(type: type, messageID: messageID, attachmentID: attachmentID)
        case "openLink":
            guard let string = dictionary["url"] as? String, let url = URL(string: string) else { return nil }
            self = .openLink(url)
        case "select":
            guard let key = dictionary["messageID"] as? String, let id = RenderPayload.messageID(fromKey: key) else { return nil }
            self = .select(id)
        default:
            return nil
        }
    }
}
