import Foundation
import SSCore

/// A message posted by the shell through `window.webkit.messageHandlers`. Bodies are untrusted
/// dictionaries, so parsing is total: anything malformed becomes nil and is ignored.
enum ConversationScriptMessage: Equatable {
    /// An address in a sheet header that has keyboard focus (spec §5.14), named by message and position, never by address.
    struct FocusedAddress: Equatable {
        let messageID: MessageID
        let address: HeaderAddress
    }

    /// A primary press on an attachment chip, or on Download all: the files a drag from here would carry and where their
    /// chips are, in the page's coordinates (spec §5.17). The app starts the drag once the pointer moves past the drag
    /// threshold; the page itself never does.
    struct AttachmentPress: Equatable {
        struct Item: Equatable {
            let attachmentID: String
            let rect: CGRect
        }

        let messageID: MessageID
        let items: [Item]
        /// Where the press was.
        let point: CGPoint

        /// The most files one press may carry: a message lists far fewer, and anything past it is not the shell's.
        static let maxItems = 200
    }

    case ready
    /// A button in a sheet. `on` is the state a toggle asks for (star); `point` is where a menu opens (More),
    /// in the web view's coordinates; `value` is what the button names (an invitation's answer, a link).
    case action(type: String, messageID: MessageID?, attachmentID: String?, on: Bool?, point: CGPoint?, value: String?)
    /// The target message changed: R, A, F and Space act on it.
    case select(MessageID)
    /// An attachment chip took keyboard focus: Space previews from it.
    case focusAttachment(MessageID, String)
    /// Keyboard focus landed on an elision mark, a Download button, Download all, a sheet header's copy target, the
    /// recipients toggle or “and 24 more” (true) or left it (false): Space and ↩ are that control's while it has it
    /// (spec §5.14, §5.15, §5.17). `arrows`: it is on an attachment chip or its Download button, or in an open list of
    /// recipients, where ← and → move along the row. `addresses`: it is in an open list of recipients, which Esc folds.
    /// `address`: the copy target it is on, which ⌘C and Edit › Copy copy.
    case focusMark(Bool, arrows: Bool, addresses: Bool = false, address: FocusedAddress? = nil)
    /// The messages the page shows in the sender's colours, after a render, a switch, an appearance change or a new Dark
    /// Mode default: whichever way each came to it (spec §5.16).
    case originalColors(shown: Set<MessageID>)
    /// The page and every body in it are restyled in the theme `id` (spec §4.16).
    case themed(String)
    /// A height animation started; the next key press finishes it.
    case motion
    /// Find in conversation reported its count and current match (spec §5.50).
    case find(ConversationFind.Result)
    case attachmentPress(AttachmentPress)

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
        case "focusMark":
            guard let on = dictionary["on"] as? Bool else { return nil }
            var focused: FocusedAddress?
            if let address = dictionary["address"] as? [String: Any],
               let message = (address["messageID"] as? String).flatMap(RenderPayload.messageID(fromKey:)),
               let position = (address["value"] as? String).flatMap(HeaderAddress.init) {
                focused = FocusedAddress(messageID: message, address: position)
            }
            self = .focusMark(on, arrows: dictionary["arrows"] as? Bool ?? false, addresses: dictionary["addresses"] as? Bool ?? false,
                              address: focused)
        case "originalColors":
            guard let shown = dictionary["shown"] as? [String] else { return nil }
            self = .originalColors(shown: Set(shown.compactMap(RenderPayload.messageID(fromKey:))))
        case "themed":
            guard let id = dictionary["id"] as? String else { return nil }
            self = .themed(id)
        case "find":
            guard let result = ConversationFind.Result(body: dictionary) else { return nil }
            self = .find(result)
        case "attachmentPress":
            guard let messageID, let point = Self.point(dictionary["x"], dictionary["y"]),
                  let list = dictionary["items"] as? [[String: Any]], !list.isEmpty, list.count <= AttachmentPress.maxItems else { return nil }
            var items: [AttachmentPress.Item] = []
            for entry in list {
                guard let id = entry["attachmentID"] as? String, !id.isEmpty, let origin = Self.point(entry["x"], entry["y"]),
                      let size = Self.point(entry["width"], entry["height"]), size.x >= 0, size.y >= 0 else { return nil }
                items.append(AttachmentPress.Item(attachmentID: id, rect: CGRect(origin: origin, size: CGSize(width: size.x, height: size.y))))
            }
            self = .attachmentPress(AttachmentPress(messageID: messageID, items: items, point: point))
        default:
            return nil
        }
    }

    /// Two finite numbers as a point; nil for anything else.
    private static func point(_ x: Any?, _ y: Any?) -> CGPoint? {
        guard let x = (x as? NSNumber)?.doubleValue, let y = (y as? NSNumber)?.doubleValue, x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }
}
