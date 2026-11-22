import AppKit

/// The app's Services menu items (spec §5.20 Services): “New Message with Selection” and “Send with Paper”,
/// declared in Info.plist's `NSServices`, whose `NSMessage` names the methods here. `NSApp.servicesProvider` points at
/// it from before launch ends. A request that launches the app comes before the main window has read its accounts; it
/// waits here, as mail links wait in `MailLinkInbox`, until the app delegate sets the receiver.
@MainActor
final class MailServicesProvider: NSObject {
    /// Requests received while there was no receiver, oldest first.
    private(set) var pending: [ServiceRequest] = []

    /// Opens one request. Setting it hands over every request that was waiting.
    var receiver: ((ServiceRequest) -> Void)? {
        didSet { deliverPending() }
    }

    /// `NSMessage` newMessageWithSelection. `error` goes back to the requesting app, which may log it; nothing opens.
    @objc(newMessageWithSelection:userData:error:)
    func newMessageWithSelection(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let request = ServiceRequest.selection(from: pasteboard) else {
            error.pointee = "No text to send."
            return
        }
        receive(request)
    }

    /// `NSMessage` sendFiles.
    @objc(sendFiles:userData:error:)
    func sendFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let request = ServiceRequest.files(from: pasteboard) else {
            error.pointee = "No files to send."
            return
        }
        receive(request)
    }

    func receive(_ request: ServiceRequest) {
        pending.append(request)
        deliverPending()
    }

    private func deliverPending() {
        guard let receiver, !pending.isEmpty else { return }
        let requests = pending
        pending = []
        requests.forEach(receiver)
    }
}
