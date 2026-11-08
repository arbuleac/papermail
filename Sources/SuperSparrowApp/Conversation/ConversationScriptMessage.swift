import Foundation
import SSCore

/// A message posted by the shell through `window.webkit.messageHandlers`. Bodies are untrusted
/// dictionaries, so parsing is total: anything malformed becomes nil and is ignored.
enum ConversationScriptMessage: Equatable {
    case ready
    /// A button in a sheet. `on` is the state a toggle asks for (star); `point` is where a menu opens (More),
    /// in the web view's coordinates; `value` is what the button names (an invitation's answer, a link).
    case action(type: String, messageID: MessageID?, attachmentID: String?, on: Bool?, point: CGPoint?, value: String?)
    /// The target message changed: R, A, F and Space act on it.
    case select(MessageID)
    /// An attachment chip took keyboard focus: Space previews from it.
    case focusAttachment(MessageID, String)
    /// A message switched between Original and Adaptive colors.
    case originalColors(MessageID, Bool)
    /// A height animation started; the next key press finishes it.
    case motion

    init?(body: Any) {
        guard let dictionary = body as? [String: Any], let kind = dictionary["kind"] as? String else { return nil }
        let messageID = (dictionary["messageID"] as? String).flatMap(RenderPayload.messageID(fromKey:))
        switch kind {
        case "ready":
            self = .ready
        case "motion":
            self = .motion
        case "action":
            guard let type = dictionary["type"] as? String else { return nil }
            let attachmentID = dictionary["attachmentID"] as? String
            var point: CGPoint?
            if let x = (dictionary["x"] as? NSNumber)?.doubleValue, let y = (dictionary["y"] as? NSNumber)?.doubleValue,
               x.isFinite, y.isFinite {
                point = CGPoint(x: x, y: y)
            }
            self = .action(type: type, messageID: messageID, attachmentID: attachmentID, on: dictionary["on"] as? Bool, point: point,
                           value: dictionary["value"] as? String)
        case "select":
            guard let messageID else { return nil }
            self = .select(messageID)
        case "focusAttachment":
            guard let messageID, let attachmentID = dictionary["attachmentID"] as? String else { return nil }
            self = .focusAttachment(messageID, attachmentID)
        case "originalColors":
            guard let messageID, let on = dictionary["on"] as? Bool else { return nil }
            self = .originalColors(messageID, on)
        default:
            return nil
        }
    }
}
