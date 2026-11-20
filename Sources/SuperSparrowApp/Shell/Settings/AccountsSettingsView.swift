import SSCore
import SSDesign
import SwiftUI

/// Settings › Accounts (spec §5.40): one notice at most, the account group with its +/− buttons, then the
/// selected account's detail form.
struct AccountsSettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var settings: AppSettings

    /// The face button's focus, given back when the picker closes. The form owns the button; the tab owns the card
    /// (`model.showsFacePicker`), so the card can open over the account group as well as the form and never changes the
    /// form's height (Quire §5.55).
    @FocusState private var faceButtonFocused: Bool

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
                AccountDetailForm(model: model, account: account, faceButtonFocus: $faceButtonFocused)
                    .padding(.top, s.detailTop)
            }
        }
        .settingsTabContent()
        .overlayPreferenceValue(FaceButtonAnchorKey.self) { anchor in
            if model.showsFacePicker, let anchor, let account = model.selectedAccount {
                GeometryReader { proxy in
                    facePicker(for: account, button: proxy[anchor], in: proxy.size)
                }
            }
        }
    }

    /// The card under the face button, `pickerOffset` off its ring, or over it when the tab has no room below; kept
    /// `pickerEdgeMin` inside the tab either way. Behind it, a clear layer takes the click outside that closes it.
    @ViewBuilder
    private func facePicker(for account: Account, button: CGRect, in container: CGSize) -> some View {
        let frame = AccountsSettingsView.facePickerFrame(button: button, container: container)
        let current = model.face(for: account)
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { closeFacePicker(refocus: true) }
                .accessibilityHidden(true)
            QuireFacePicker(monogram: current.monogram, ink: account.inkSlot, chosen: current.face,
                            onPick: { face in
                                model.setFace(AccountFaces.choice(face), account)
                                closeFacePicker(refocus: true)
                            },
                            onClose: { closeFacePicker(refocus: true) })
                // A card per account: its focus starts on that account's face, never where another's was left.
                .id(account.id)
                .offset(x: frame.minX, y: frame.minY)
        }
        .frame(width: container.width, height: container.height, alignment: .topLeading)
    }

    /// Where the card goes for a face button at `button` (its face, in the tab's coordinates) in a tab of `container`.
    static func facePickerFrame(button: CGRect, container: CGSize) -> CGRect {
        let p = Quire.Layout.PaperFaces.self
        let size = QuireFacePicker.size
        let ring = Quire.Border.AccountRing.gap + Quire.Border.AccountRing.width
        let edge = p.pickerEdgeMin
        let x = min(max(button.midX - size.width / 2, edge), max(edge, container.width - edge - size.width))
        var y = button.maxY + ring + p.pickerOffset
        if y + size.height > container.height - edge {
            let above = button.minY - ring - p.pickerOffset - size.height
            y = above >= edge ? above : max(edge, container.height - edge - size.height)
        }
        return CGRect(origin: CGPoint(x: x.rounded(), y: y.rounded()), size: size)
    }

    private func closeFacePicker(refocus: Bool) {
        guard model.showsFacePicker else { return }
        model.showsFacePicker = false
        // The button had focus when it opened the card; it gets it back, as a popover's button does.
        if refocus { faceButtonFocused = true }
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
            return QuireBanner(.info, "Rows now show each account's face. With seven or more accounts, colours alone can look alike.",
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

/// The selected account's detail (spec §5.40, Detail form): Colour, Face (the face button, and the monogram field while
/// the account wears its monogram), Signature, Rules (Senders…, the sender rules' one list), Last error when there is one,
/// and Remove… (Leave Demo… in demo mode), on the Settings grid.
struct AccountDetailForm: View {
    @ObservedObject var model: SettingsModel
    let account: Account
    /// The face button's focus, the tab's, so it can give focus back when the picker closes.
    var faceButtonFocus: FocusState<Bool>.Binding?

    /// The field's own text: a binding straight to the store would leave a third typed character on screen,
    /// because cutting it back to two characters leaves the stored value unchanged and SwiftUI then keeps
    /// the field as typed.
    @State private var monogramText = ""
    @State private var showsSenders = false

    var body: some View {
        let s = Quire.Layout.Settings.self
        QuireSettingsGrid {
            QuireSettingsRow("Colour", minHeight: s.detailRow) {
                QuirePopup("Colour", selection: inkSlot, options: Array(0..<Quire.accountInkNames.count), width: s.colourPopupWidth,
                           title: { Quire.accountInkNames[$0] }, swatch: { $0 })
            }
            // The Monogram row's place and height (Quire §5.55): the face, and the letters' field only while they are the face.
            QuireSettingsRow("Face", minHeight: s.detailRow) {
                // The ring reaches 4 pt past the face's frame: the field stands `labelGap` clear of the ring itself.
                let ring = Quire.Border.AccountRing.gap + Quire.Border.AccountRing.width
                HStack(spacing: s.labelGap + ring) {
                    let current = model.face(for: account)
                    QuireFaceButton(face: current.face, ink: account.inkSlot, accountName: AccountLabels.name(for: account),
                                    isOpen: model.showsFacePicker, focus: faceButtonFocus) {
                        model.showsFacePicker.toggle()
                    }
                    .anchorPreference(key: FaceButtonAnchorKey.self, value: .bounds) { $0 }
                    if account.face == .monogram {
                        TextField("", text: $monogramText, prompt: QuireFieldStyle.prompt(model.derivedMonogram(for: account)))
                            .quireFieldStyle()
                            .frame(width: s.monogramFieldWidth)
                            .accessibilityLabel("Monogram")
                            .onAppear { monogramText = account.monogram ?? "" }
                            .onChange(of: account.id) { monogramText = account.monogram ?? "" }
                            .onChange(of: monogramText) { _, typed in commitMonogram(typed) }
                    }
                }
                // and the ring's outer edge on the field column's leading edge.
                .padding(.leading, ring)
            }
            // The field sits 8 pt into its row, as a one-line field does, its first line level with the label.
            QuireSettingsRow("Signature", minHeight: s.detailRow, alignment: .top) {
                // Read when the field saves: the app delegate sets the model's action after the form first draws.
                SignatureField(account: account, onCommit: { [model] html, id in model.setSignature(html, id) })
                    .padding(.vertical, (s.detailRow - s.fieldHeight) / 2)
            }
            QuireSettingsRow("Rules", minHeight: s.detailRow) {
                Button("Senders…") { showsSenders = true }
                    .buttonStyle(.quire(.secondary, size: .small))
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
        .sheet(isPresented: $showsSenders) {
            SendersSheet(model: model, account: account) { showsSenders = false }
        }
        // Another account chosen while the sheet is up (it is modal to the window, so only from code): it was this one's.
        .onChange(of: account.id) { showsSenders = false }
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
            .background(.qCanvas)
    }
}

/// Where the face button is, for the tab's face picker to anchor to.
struct FaceButtonAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}
