import Foundation

/// An account still signing in, shown as the pending row at the end of the Settings group (spec §5.40,
/// Adding): the pending face, the title in `body` `ink` over the provider in `snippet` `ink2`, and a small
/// secondary Cancel. While it shows, + is disabled.
public struct QuireAccountPending {
    public var title: String
    /// “Gmail” or “Microsoft 365”.
    public var provider: String
    public var cancelTitle: String
    public var onCancel: () -> Void

    public init(title: String = "Finish signing in in your browser…", provider: String, cancelTitle: String = "Cancel",
                onCancel: @escaping () -> Void) {
        self.title = title
        self.provider = provider
        self.cancelTitle = cancelTitle
        self.onCancel = onCancel
    }
}
