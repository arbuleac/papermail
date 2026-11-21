import SSCore
import SSDesign
import SwiftUI

/// Settings › Accounts › Senders… (spec §5.40, §5.52): the account's sender rules as its server keeps them, Gmail filters
/// or Outlook rules, the one place they are listed, each with its − to remove it. The server is the one source of truth:
/// the sheet shows the store's mirror of it, with the changes made on this Mac until the server has them, and asks the
/// engine to read the server as it opens. Rules are set from a message's menu, never here, so the sheet has no +.
struct SendersSheet: View {
    @ObservedObject var model: SettingsModel
    let account: Account
    let onDone: () -> Void

    var content: SendersSheetContent {
        model.sendersContent(for: account)
    }

    var rows: [QuireRemovableList.Row] {
        SendersSheetBody.rows(content)
    }

    /// A row's −: its rule goes through the model, which the app delegate points at the engine. It is deleted on the
    /// server, and the row says so until the server has done it.
    func remove(_ row: QuireRemovableList.Row) {
        guard let rule = model.senderRules(for: account).first(where: { $0.address == row.id }), rule.isActive else { return }
        model.removeSenderRule(rule)
    }

    /// The drawn sheet, wired to the model: Allow… and Cancel to the sign-in, the foot's link to the browser.
    var sheetBody: SendersSheetBody {
        let model = self.model
        let account = self.account
        let url = content.webSettingsURL
        return SendersSheetBody(content: content, onRemove: remove, onAllow: { model.connectRules(account) },
                                onCancelSignIn: { model.cancelSignIn() }, onOpenSettings: { if let url { model.openWebSettings(url) } },
                                onDone: onDone)
    }

    var body: some View {
        let model = self.model
        let account = self.account
        sheetBody
            // What another device or the web changed since the last read shows while the sheet is open.
            .onAppear { model.refreshServerRules(account) }
    }
}

/// The sheet drawn from its content alone, for the window and for the snapshot of its states.
struct SendersSheetBody: View {
    let content: SendersSheetContent
    let onRemove: (QuireRemovableList.Row) -> Void
    let onAllow: () -> Void
    let onCancelSignIn: () -> Void
    let onOpenSettings: () -> Void
    let onDone: () -> Void

    static func rows(_ content: SendersSheetContent) -> [QuireRemovableList.Row] {
        content.rows.map {
            QuireRemovableList.Row(id: $0.address, title: $0.address, detail: $0.detail, state: $0.state, isRemovable: $0.isRemovable)
        }
    }

    var body: some View {
        QuireRuleSheet(title: "Senders", caption: content.caption, notice: notice, rows: Self.rows(content), emptyTitle: "No sender rules",
                       emptyHint: "Set one from a message's menu.", foot: foot, onRemove: onRemove, onDone: onDone)
    }

    /// The banner's kind, words and link, apart from the banner so tests can follow the link.
    var noticeParts: (variant: QuireBannerVariant, words: String, link: (title: String, action: () -> Void)?)? {
        switch content.notice {
        case .needsPermission(let words)?: return (.info, words, ("Allow…", onAllow))
        case .waitingForBrowser(let words)?: return (.info, words, ("Cancel", onCancelSignIn))
        case .failed(let words)?: return (.danger, words, nil)
        case nil: return nil
        }
    }

    private var notice: QuireBanner? {
        noticeParts.map { QuireBanner($0.variant, $0.words, link: $0.link) }
    }

    var foot: QuireRuleSheetFoot? {
        switch content.foot {
        case .reading(let words):
            return QuireRuleSheetFoot(words: words, isWorking: true)
        case .others(let words, let link):
            guard words != nil || link != nil else { return nil }
            return QuireRuleSheetFoot(words: words, link: link.map { ($0, onOpenSettings) })
        }
    }
}
