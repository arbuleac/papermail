import AppKit
import SSCore
import SSDesign

/// Drags attachments out of a reader (spec §5.17, Dragging out): one pasteboard item per file, an `AttachmentFilePromise`
/// that also carries the app's `MailAttachmentReference`, each shown as an `AttachmentDragCard` that starts exactly over
/// its chip. The reader web view hands it the press and the event that crossed the drag threshold; the session starts in
/// that event. The copy cursor shows wherever a drop copies; nothing is ever moved out of a message.
@MainActor
final class AttachmentDragController: NSObject, NSDraggingSource {
    /// A drag under way: the chips it dims and the view it started from.
    struct Drag {
        let messageID: MessageID
        let attachmentIDs: [String]
        weak var webView: ReaderWebView?
    }

    private let client: MailClient
    /// The message's files as the store lists them, inline images left out (they are never chips).
    var attachments: (MessageID) -> [AttachmentInfo] = { _ in [] }
    /// A drag of these files started (true) or ended: the reader dims their chips meanwhile.
    var onDragChange: ((Drag, Bool) -> Void)?
    /// A promise's progress and end, on the main thread: the reader shows the download on the chip and says when it failed.
    var onPromiseEvent: ((AttachmentPromiseFulfiller.Event) -> Void)?
    /// Starts the session: a card that finds no taker slides back to its chip, and several files pile under the pointer.
    /// The app's tests replace it, to read the items without a pointer to drag them.
    var beginSession: (NSView, [NSDraggingItem], NSEvent, NSDraggingSource) -> Bool = { view, items, event, source in
        let session = view.beginDraggingSession(with: items, event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = items.count > 1 ? .pile : .none
        return true
    }
    /// The fetch a promise makes; tests replace it.
    lazy var fulfiller: AttachmentPromiseFulfiller = {
        let relay = EventRelay(self)
        return AttachmentPromiseFulfiller.engine(client) { event in
            // In the order they happened: a promise's end never overtakes its start.
            DispatchQueue.main.async { MainActor.assumeIsolated { relay.controller?.onPromiseEvent?(event) } }
        }
    }()

    private(set) var current: Drag?

    init(client: MailClient) {
        self.client = client
        super.init()
    }

    /// The items a drag of `press` would put on the pasteboard, for `webView` at its scale and in its appearance: the
    /// files the store still lists, in the order the press named them, each card's frame over its chip.
    func draggingItems(for press: ConversationScriptMessage.AttachmentPress, in webView: NSView) -> [NSDraggingItem] {
        let infos = attachments(press.messageID)
        let mode = QuireMode(webView.effectiveAppearance)
        let scale = webView.window?.backingScaleFactor ?? 2
        let zoom = (webView as? ReaderWebView)?.pageScale ?? 1
        let margin = AttachmentDragCard.margin
        var items: [NSDraggingItem] = []
        for item in press.items {
            guard let info = infos.first(where: { $0.id == item.attachmentID }) else { continue }
            let reference = MailAttachmentReference(message: press.messageID, info: info)
            let content = AttachmentDragCard.content(for: info)
            let image = AttachmentDragCard.image(for: content, mode: mode, scale: scale)
            let chip = NSRect(x: item.rect.minX * zoom, y: item.rect.minY * zoom, width: item.rect.width * zoom, height: item.rect.height * zoom)
            let dragging = NSDraggingItem(pasteboardWriter: AttachmentFilePromise(reference: reference, fulfiller: fulfiller))
            dragging.setDraggingFrame(NSRect(x: chip.minX - margin.left, y: chip.minY - margin.top, width: image.size.width,
                                             height: image.size.height), contents: image)
            items.append(dragging)
        }
        return items
    }

    /// Starts the drag with `event`, the one that crossed the threshold. False when there is nothing to drag (the files
    /// are gone from the store) or AppKit would not start it; the press then stays WebKit's.
    func startDrag(_ press: ConversationScriptMessage.AttachmentPress, event: NSEvent, in webView: ReaderWebView) -> Bool {
        let items = draggingItems(for: press, in: webView)
        guard !items.isEmpty, beginSession(webView, items, event, self) else { return false }
        let ids = items.compactMap { ($0.item as? AttachmentFilePromise)?.reference.info.id }
        let drag = Drag(messageID: press.messageID, attachmentIDs: ids, webView: webView)
        current = drag
        onDragChange?(drag, true)
        return true
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragEnded()
    }

    /// The session ended, dropped or not: the chips come back.
    func dragEnded() {
        guard let drag = current else { return }
        current = nil
        onDragChange?(drag, false)
    }
}

/// Hands promise events, which arrive on any thread, to the controller on the main thread without keeping it alive.
private final class EventRelay: @unchecked Sendable {
    weak var controller: AttachmentDragController?
    init(_ controller: AttachmentDragController) { self.controller = controller }
}
