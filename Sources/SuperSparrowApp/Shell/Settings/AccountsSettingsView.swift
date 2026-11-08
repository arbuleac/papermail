import SSCore
import SSDesign
import SwiftUI

/// Settings › Accounts (spec §5.40): one notice at most, the account group with its +/− buttons, then the
/// selected account's detail form.
struct AccountsSettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        let s = Quire.Layout.Settings.self
        VStack(alignment: .leading, spacing: 0) {
            if let notice {
                notice.padding(.bottom, s.noticeGap)
            }
            QuireAccountGroup(
                accounts: model.rows,
                selection: $model.selection,
                pending: model.pendingSignIn.map { kind in
                    QuireAccountPending(provider: kind == .gmail ? "Gmail" : "Microsoft 365", onCancel: model.cancelSignIn)
                },
                isAddEnabled: model.reconnecting == nil,
                onRemove: removeSelected,
                onRowAction: model.performRowAction,
                isRowActionEnabled: model.isRowActionEnabled
            ) {
                Button { model.addAccount(.gmail) } label: { Label("Add Gmail Account…", systemImage: Quire.Icon.addAccountProvider) }
                Button { model.addAccount(.microsoft) } label: { Label("Add Microsoft Account…", systemImage: Quire.Icon.addAccountProvider) }
            }
            if let account = model.selectedAccount {
                AccountDetailForm(model: model, account: account)
                    .padding(.top, s.detailTop)
            }
        }
        .settingsTabContent()
    }

    /// One banner: a failure first (it answers the user's last action), then demo mode, then the seven-accounts
    /// notice (demo mode's wins when both apply, §5.40).
    private var notice: QuireBanner? {
        if case .addFailed(let kind, let reason)? = model.accountsNotice {
            let model = self.model
            return QuireBanner(.danger, "Couldn't add the account. " + AppAlert.sentence(reason),
                               link: ("Try again", { model.addAccount(kind) }))
        }
        if model.isDemo {
            return QuireBanner(.info, "Demo mode: these mailboxes are made up and live only on this Mac.",
                               link: ("Leave demo…", model.leaveDemo))
        }
        if settings.sevenAccountsNoticePending {
            let model = self.model
            let settings = self.settings
            return QuireBanner(.info, "Rows now show each account's initial. With seven or more accounts, colours alone can look alike.",
                               link: ("Change in General…", {
                                   settings.sevenAccountsNoticePending = false
                                   model.tab = .general
                               }),
                               onDismiss: { settings.sevenAccountsNoticePending = false })
        }
        return nil
    }

    private func removeSelected() {
        guard let account = model.selectedAccount else { return }
        if model.isDemo { model.leaveDemo() } else { model.removeAccount(account) }
    }
}

/// The selected account's detail (spec §5.40, Detail form): Colour, Monogram, Signature, Last error when there is one,
/// and Remove… (Leave Demo… in demo mode), on the Settings grid.
struct AccountDetailForm: View {
    @ObservedObject var model: SettingsModel
    let account: Account

    /// The field's own text: a binding straight to the store would leave a third typed character on screen,
    /// because cutting it back to two characters leaves the stored value unchanged and SwiftUI then keeps
    /// the field as typed.
    @State private var monogramText = ""

    var body: some View {
        let s = Quire.Layout.Settings.self
        QuireSettingsGrid {
            QuireSettingsRow("Colour", minHeight: s.detailRow) {
                QuirePopup("Colour", selection: inkSlot, options: Array(0..<Quire.accountInkNames.count), width: s.colourPopupWidth,
                           title: { Quire.accountInkNames[$0] }, swatch: { $0 })
            }
            QuireSettingsRow("Monogram", minHeight: s.detailRow) {
                TextField("", text: $monogramText, prompt: QuireFieldStyle.prompt(model.derivedMonogram(for: account)))
                    .quireFieldStyle()
                    .frame(width: s.monogramFieldWidth)
                    .accessibilityLabel("Monogram")
                    .onAppear { monogramText = account.monogram ?? "" }
                    .onChange(of: account.id) { monogramText = account.monogram ?? "" }
                    .onChange(of: monogramText) { _, typed in commitMonogram(typed) }
            }
            // The field sits 8 pt into its row, as a one-line field does, its first line level with the label.
            QuireSettingsRow("Signature", minHeight: s.detailRow, alignment: .top) {
                // Read when the field saves: the app delegate sets the model's action after the form first draws.
                SignatureField(account: account, onCommit: { [model] html, id in model.setSignature(html, id) })
                    .padding(.vertical, (s.detailRow - s.fieldHeight) / 2)
            }
            if let error = model.lastError(for: account) {
                QuireSettingsTextRow("Last error", text: error)
            }
            QuireSettingsRow(nil, minHeight: s.detailRow) {
                Button(model.isDemo ? "Leave Demo…" : "Remove…") {
                    if model.isDemo { model.leaveDemo() } else { model.removeAccount(account) }
                }
                .buttonStyle(.quire(.secondary, size: .small))
            }
        }
    }

    private var inkSlot: Binding<Int> {
        Binding(get: { account.inkSlot }, set: { model.setInkSlot($0, account) })
    }

    /// At most two characters (§5.40), written as typed; clearing the field returns to the derived monogram,
    /// its placeholder.
    private func commitMonogram(_ typed: String) {
        let cut = String(typed.prefix(Account.monogramMaxLength))
        guard cut == typed else {
            monogramText = cut
            return
        }
        guard Account.normalizedMonogram(cut) != Account.normalizedMonogram(account.monogram) else { return }
        model.setMonogram(cut.isEmpty ? nil : cut, account)
    }
}

extension View {
    /// A tab's content: padding 20 24 22 on `canvas`, 560 pt wide, as tall as its content (§5.40).
    func settingsTabContent() -> some View {
        let s = Quire.Layout.Settings.self
        return self
            .padding(.top, s.padTop)
            .padding(.horizontal, s.padX)
            .padding(.bottom, s.padBottom)
            .frame(width: s.width, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.qCanvas)
    }
}
