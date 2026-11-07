import SwiftUI

/// Every SwiftUI Quire component in every state, side by side, on the Settings `canvas`: the SwiftUI
/// counterpart of section D of docs/design/specimen.html for the controls of spec §8.3. States are forced with
/// `.quireForcedStates(_:)`, `.disabled(_:)` and `controlActiveState`, so the sheet needs no pointer and no
/// keyboard; tests render it in all four modes, and the app can show it for a visual check.
///
/// The whole sheet is drawn as if its window were key (`controlActiveState = .key`), except the cells that
/// show the not-key look.
public struct QuireSettingsGallery: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: Quire.Space.s8) {
            QuireGallerySection("Buttons · layout.button") { QuireGalleryButtons() }
            HStack(alignment: .top, spacing: Quire.Space.s9) {
                QuireGallerySection("Text field · layout.textField") { QuireGalleryFields() }
                QuireGallerySection("Checkbox, radio, toggle · §5.26") { QuireGalleryChoices() }
            }
            HStack(alignment: .top, spacing: Quire.Space.s9) {
                QuireGallerySection("Popup · layout.popup") { QuireGalleryPopups() }
                QuireGallerySection("Spinner, avatars · §5.37 · §5.29") { QuireGalleryFaces() }
            }
            QuireGallerySection("Banners · layout.banner") { QuireGalleryBanners() }
            HStack(alignment: .top, spacing: Quire.Space.s9) {
                QuireGallerySection("Accounts · key, selected") { QuireGalleryAccounts(windowKey: true) }
                QuireGallerySection("Accounts · not key, adding") { QuireGalleryAccounts(windowKey: false) }
            }
            HStack(alignment: .top, spacing: Quire.Space.s9) {
                QuireGallerySection("Accounts · seven, scrolled cap") { QuireGalleryAccountsCapped() }
                QuireGallerySection("Accounts · empty, focused") { QuireGalleryAccountsEmpty() }
            }
            QuireGallerySection("Settings grid · General") { QuireGalleryGeneral() }
                .frame(width: Quire.Layout.Settings.width - 2 * Quire.Layout.Settings.padX, alignment: .leading)
        }
        .padding(.top, Quire.Layout.Settings.padTop)
        .padding(.horizontal, Quire.Layout.Settings.padX)
        .padding(.bottom, Quire.Layout.Settings.padBottom)
        .background(Color.qCanvas)
        .environment(\.controlActiveState, .key)
    }
}

/// A titled block of the gallery.
struct QuireGallerySection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Quire.Space.s5) {
            Text(title).quireLine(.title).foregroundStyle(Color.qInk)
            content()
        }
    }
}

/// A state's caption under a cell.
struct QuireGalleryCaption: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text).quireLine(.meta).foregroundStyle(Color.qInk3)
    }
}

struct QuireGalleryButtons: View {
    private let states: [(String, QuireForcedStates, Bool, Bool)] = [
        ("Rest", [], false, false), ("Hover", .hovered, false, false), ("Pressed", .pressed, false, false),
        ("Focused", .focused, false, false), ("Disabled", [], true, false), ("Loading", [], false, true),
    ]
    private let variants: [(QuireButtonVariant, String, String, String?)] = [
        (.primary, "Send", "Sending…", Quire.Icon.send), (.secondary, "Reconnect", "Loading…", nil),
        (.ghost, "Cancel", "Cancel", nil), (.destructive, "Discard", "Removing…", nil),
        (.link, "Load images", "Load images", nil), (.icon, "", "", Quire.Icon.archive),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Quire.Space.s5) {
            Grid(alignment: .leading, horizontalSpacing: Quire.Space.s6, verticalSpacing: Quire.Space.s5) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    ForEach(states, id: \.0) { QuireGalleryCaption($0.0) }
                }
                ForEach(variants, id: \.0) { variant in
                    GridRow {
                        QuireGalleryCaption(variant.0.rawValue.capitalized)
                        ForEach(states, id: \.0) { state in
                            cell(variant, state)
                        }
                    }
                }
            }
            HStack(spacing: Quire.Space.s5) {
                Button {} label: { QuireButtonLabel("Send") }.buttonStyle(.quire(.primary, size: .small))
                Button {} label: { QuireButtonLabel("Send", glyph: Quire.Icon.send) }.buttonStyle(.quire(.primary, size: .regular))
                Button {} label: { QuireButtonLabel("Send", glyph: Quire.Icon.send) }.buttonStyle(.quire(.primary, size: .large))
                Button("Reconnect") {}.buttonStyle(.quire(.secondary, size: .small))
                Button("Add Gmail Account") {}.buttonStyle(.quire(.secondary, size: .large))
                Button("Send") {}.buttonStyle(.quire(.primary, size: .regular))
                    .environment(\.controlActiveState, .inactive)
                QuireGalleryCaption("small · regular · large · not key")
            }
        }
    }

    @ViewBuilder
    private func cell(_ variant: (QuireButtonVariant, String, String, String?), _ state: (String, QuireForcedStates, Bool, Bool)) -> some View {
        Button {} label: {
            if variant.0 == .icon {
                QuireButtonLabel(glyph: variant.3 ?? Quire.Icon.archive, accessibilityLabel: "Archive",
                                 glyphSize: Quire.Layout.IconSize.window, isLoading: state.3)
            } else {
                // Only the loading column names its gerund: a label given one keeps its width for it.
                QuireButtonLabel(variant.1, isLoading: state.3, loadingTitle: state.3 ? variant.2 : nil)
            }
        }
        .buttonStyle(.quire(variant.0, size: variant.0 == .icon ? .large : .regular))
        .disabled(state.2)
        .quireForcedStates(state.1)
    }
}

struct QuireGalleryFields: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Quire.Space.s4) {
            field("", prompt: "Client ID")
            field("", prompt: "Hover").quireForcedStates(.hovered)
            field("alex@contoso", prompt: "").quireForcedStates(.focused)
            field("Disabled", prompt: "").disabled(true)
            field("1084-ab3f.apps", prompt: "", variant: .mono, error: "That doesn't look like a Google client ID.")
            field("1084-ab3f.apps.googleusercontent.com", prompt: "", variant: .mono)
            field("", prompt: "Disabled placeholder").disabled(true)
            QuireSecureField("Client secret", text: .constant("GOCSPX-k2v9"))
            QuireSecureField("Client secret", text: .constant("GOCSPX-k2v9")).quireForcedStates(.hovered)
            QuireGalleryCaption("rest · hover · focused · disabled · error · mono")
            QuireGalleryCaption("disabled placeholder · secure · secure hover")
        }
        .frame(width: 260)
    }

    private func field(_ text: String, prompt: String, variant: QuireFieldVariant = .standard, error: String? = nil) -> some View {
        TextField("", text: .constant(text), prompt: QuireFieldStyle.prompt(prompt))
            .quireFieldStyle(variant, error: error)
    }
}

struct QuireGalleryChoices: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Quire.Space.s4) {
            HStack(spacing: Quire.Space.s5) {
                check(false)
                check(true)
                // Mixed: a toggle over several values that disagree.
                Toggle("", sources: [Binding.constant(true), .constant(false)], isOn: \.self)
                    .toggleStyle(.quireCheckbox).labelsHidden()
                check(false).quireForcedStates(.focused)
                check(true).quireForcedStates(.focused)
                check(false).disabled(true)
            }
            QuireGalleryCaption("off · on · mixed · focused · on + focused · disabled")
            HStack(spacing: Quire.Space.s5) {
                check(false).quireForcedStates(.hovered)
                check(false).quireForcedStates(.pressed)
                check(true).quireForcedStates(.hovered)
                check(true).quireForcedStates(.pressed)
            }
            QuireGalleryCaption("off hover · off pressed · on hover · on pressed")
            HStack(spacing: Quire.Space.s5) {
                radio(false)
                radio(true)
                radio(true).quireForcedStates(.focused)
                radio(false).quireForcedStates(.hovered)
                radio(true).quireForcedStates(.pressed)
                radio(true).disabled(true)
            }
            QuireGalleryCaption("radio: off · on · focused · hover · pressed · disabled")
            HStack(spacing: Quire.Space.s5) {
                toggle(false)
                toggle(true)
                toggle(false).quireForcedStates(.focused)
                toggle(true).quireForcedStates(.focused)
                toggle(false).quireForcedStates(.pressed)
                toggle(true).quireForcedStates(.pressed)
                toggle(true).disabled(true)
            }
            QuireGalleryCaption("toggle: off · on · focused · on + focused · pressed · on pressed · disabled")
            QuireRadioGroup("List density", selection: .constant("Standard"), options: ["Standard", "Compact"]) { $0 }
            Toggle("Show account initials in unified views", isOn: .constant(false)).toggleStyle(.quireCheckbox)
            Toggle("Load by default", isOn: .constant(true)).toggleStyle(.quire)
        }
    }

    private func check(_ on: Bool) -> some View {
        Toggle("", isOn: .constant(on)).toggleStyle(.quireCheckbox).labelsHidden()
    }

    private func radio(_ on: Bool) -> some View {
        QuireRadioGroup("Radio", selection: .constant(on ? 1 : 0), options: [1]) { _ in "" }
    }

    private func toggle(_ on: Bool) -> some View {
        Toggle("", isOn: .constant(on)).toggleStyle(.quire).labelsHidden()
    }
}

struct QuireGalleryPopups: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Quire.Space.s4) {
            HStack(spacing: Quire.Space.s4) {
                QuirePopupLabel("5 seconds")
                QuirePopupLabel("Hover").quireForcedStates(.hovered)
                QuirePopupLabel("Pressed").quireForcedStates(.pressed)
                QuirePopupLabel("Focused").quireForcedStates(.focused)
                QuirePopupLabel("Off").disabled(true)
            }
            QuireGalleryCaption("rest · hover · pressed (menu open) · focused · disabled")
            HStack(spacing: Quire.Space.s4) {
                QuirePopupLabel("Persimmon", swatch: 0, width: Quire.Layout.Settings.colourPopupWidth)
                QuirePopupLabel("Persimmon", swatch: 0, width: Quire.Layout.Settings.colourPopupWidth).quireForcedStates(.pressed)
            }
            QuireGalleryCaption("Colour: the swatch keeps its 2 pt raised halo when pressed")
            HStack(spacing: Quire.Space.s4) {
                QuirePopup("Font", selection: .constant("New York"), options: ["New York", "SF Pro"]) { $0 }
                QuirePopup("Colour", selection: .constant(3), options: Array(0..<10), width: Quire.Layout.Settings.colourPopupWidth,
                           title: { Quire.accountInkNames[$0] }, swatch: { $0 })
            }
            QuireGalleryCaption("live popups (Menu)")
        }
    }
}

struct QuireGalleryFaces: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Quire.Space.s5) {
            HStack(spacing: Quire.Space.s6) {
                QuireSpinner(.small, delay: 0)
                QuireSpinner(.medium, delay: 0)
                QuireSpinner(.large, delay: 0)
                QuireGalleryCaption("12 · 16 · 32")
            }
            HStack(spacing: Quire.Space.s6) {
                QuireAvatarView(initials: "AM", address: "alex@contoso.test", diameter: 24)
                QuireAvatarView(initials: "PR", address: "priya@fabrikam.test", diameter: 30)
                QuireAvatarView(initials: "BC", address: "ben@contoso.test", diameter: 36)
                QuireAvatarView(initials: "PR", address: "priya@fabrikam.test", diameter: 30, ringInk: 1)
            }
            HStack(spacing: Quire.Space.s7) {
                QuireAvatarView(accountMonogram: "C", ink: 0)
                QuireAvatarView(accountMonogram: "Ga", ink: 3)
                QuireAvatarView(accountMonogram: "C", ink: 4, diameter: 24)
                QuireAvatarView.pending()
            }
            QuireGalleryCaption("senders 24 / 30 / 36 · ringed · account faces · pending")
        }
        .padding(.leading, Quire.Space.s2)
    }
}

struct QuireGalleryBanners: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Quire.Space.s4) {
            QuireBanner(.neutral, "3 remote images hidden to protect your privacy.", glyph: Quire.Icon.loadImages,
                        link: ("Load images", {}), wraps: false)
            QuireBanner(.neutral, "2 images couldn't load.", glyph: Quire.Icon.warning, glyphColor: .warning, wraps: false)
            QuireBanner(.info, "Demo mode: these mailboxes are made up and live only on this Mac.", link: ("Leave demo…", {}))
            QuireBanner(.success, "OAuth clients saved.")
            QuireBanner(.warning, "This message uses its own colours.", glyph: Quire.Icon.originalColors)
            QuireBanner(.danger, "Couldn't load this message.", link: ("Retry", {}))
            QuireBanner(.info, "To add a Gmail account, SuperSparrow needs your own Google OAuth client ID. Enter it below and click Save, then try again.",
                        link: ("How to create one…", {}))
            QuireBanner(.info, "Rows now show each account's initial. With seven or more accounts, colours alone can look alike.",
                        link: ("Change in General…", {}), onDismiss: {})
        }
        .frame(width: Quire.Layout.Settings.width - 2 * Quire.Layout.Settings.padX)
    }
}

enum QuireGallerySamples {
    static let accounts: [QuireAccountRowContent] = [
        QuireAccountRowContent(id: "contoso", name: "Contoso", tag: "Microsoft 365", address: "alex@contoso.test", monogram: "C",
                               inkSlot: 0, status: .upToDate(checked: "23:41")),
        QuireAccountRowContent(id: "personal", name: "Gmail", tag: "Gmail", address: "alex.morgan@gmail.com", monogram: "G",
                               inkSlot: 1, status: .downloading(done: 3412, total: 8120, locale: Locale(identifier: "en_US"))),
        QuireAccountRowContent(id: "northwind", name: "Northwind", tag: "Gmail", address: "alex@northwind.test", monogram: "N",
                               inkSlot: 3, status: .retrying(inSeconds: 30)),
        QuireAccountRowContent(id: "fabrikam", name: "Fabrikam", tag: "Microsoft 365", address: "alex@fabrikam.test", monogram: "F",
                               inkSlot: 2, status: .signInRequired),
    ]

    static let more: [QuireAccountRowContent] = [
        QuireAccountRowContent(id: "wingtip", name: "Wingtip", tag: "Gmail", address: "alex@wingtip.test", monogram: "W",
                               inkSlot: 4, status: .offline),
        QuireAccountRowContent(id: "tailspin", name: "Tailspin", tag: "Gmail", address: "alex@tailspin.test", monogram: "T",
                               inkSlot: 5, status: .error(reason: "Gmail returned an unexpected response.")),
        QuireAccountRowContent(id: "adatum", name: "Adatum", tag: "Microsoft 365", address: "alex@adatum.test", monogram: "A",
                               inkSlot: 6, status: .waitingToSync),
    ]
}

struct QuireGalleryAccounts: View {
    let windowKey: Bool

    var body: some View {
        QuireAccountGroup(accounts: windowKey ? QuireGallerySamples.accounts : Array(QuireGallerySamples.accounts.prefix(1)),
                          selection: .constant("contoso"),
                          pending: windowKey ? nil : QuireAccountPending(provider: "Gmail", onCancel: {}),
                          onRemove: {}) {
            Button("Add Gmail Account…") {}
            Button("Add Microsoft Account…") {}
        }
        .frame(width: Quire.Layout.Settings.width - 2 * Quire.Layout.Settings.padX)
        .environment(\.controlActiveState, windowKey ? .key : .inactive)
    }
}

struct QuireGalleryAccountsCapped: View {
    var body: some View {
        QuireAccountGroup(accounts: QuireGallerySamples.accounts + QuireGallerySamples.more, selection: .constant("fabrikam"),
                          isAddEnabled: false, onRemove: {},
                          isRowActionEnabled: { $0.id == "fabrikam" }) {
            Button("Add Gmail Account…") {}
        }
        .frame(width: Quire.Layout.Settings.width - 2 * Quire.Layout.Settings.padX)
    }
}

struct QuireGalleryAccountsEmpty: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Quire.Space.s6) {
            QuireAccountGroup(accounts: [], selection: .constant(nil), onRemove: {}) {
                Button("Add Gmail Account…") {}
            }
            QuireAccountGroup(accounts: Array(QuireGallerySamples.accounts.prefix(2)), selection: .constant("personal"), onRemove: {}) {
                Button("Add Gmail Account…") {}
            }
            .quireForcedStates(.focused)
            QuireAccountRow(QuireAccountRowContent(id: "fabrikam", name: "Fabrikam", tag: "Microsoft 365", address: "alex@fabrikam.test",
                                                   monogram: "F", inkSlot: 2, status: .reconnecting), onAction: {})
                .background(Color.qSheet)
        }
        .frame(width: Quire.Layout.Settings.width - 2 * Quire.Layout.Settings.padX)
    }
}

struct QuireGalleryGeneral: View {
    var body: some View {
        QuireSettingsGrid {
            QuireSettingsRow("Font") {
                QuirePopup("Font", selection: .constant("New York"), options: ["New York", "SF Pro"]) { $0 }
            }
            QuireSettingsRow("List density") {
                QuireRadioGroup("List density", selection: .constant("Standard"), options: ["Standard", "Compact"]) { $0 }
            }
            QuireSettingsRow("Rows") {
                Toggle("Show account initials in unified views", isOn: .constant(false)).toggleStyle(.quireCheckbox)
            }
            QuireSettingsCaption("Turned on when you added a seventh account.")
            QuireSettingsRow("Undo send") {
                QuirePopup("Undo send", selection: .constant(5), options: [5, 10, 20]) { "\($0) seconds" }
            }
            QuireSettingsDivider()
            QuireSettingsRow("Remote images") {
                Toggle("Load by default", isOn: .constant(false)).toggleStyle(.quire)
            }
            QuireSettingsCaption("Off: images load only when you ask, per message.")
            QuireSettingsRow("Notifications") {
                Toggle("New mail", isOn: .constant(true)).toggleStyle(.quire)
            }
            QuireSettingsRow(nil) {
                Toggle("Show sender and subject", isOn: .constant(true)).toggleStyle(.quireCheckbox)
            }
            QuireSettingsSection("Account detail")
            QuireSettingsRow("Colour") {
                QuirePopup("Colour", selection: .constant(0), options: Array(0..<10), width: Quire.Layout.Settings.colourPopupWidth,
                           title: { Quire.accountInkNames[$0] }, swatch: { $0 })
            }
            QuireSettingsRow("Monogram") {
                TextField("", text: .constant(""), prompt: QuireFieldStyle.prompt("C"))
                    .quireFieldStyle()
                    .frame(width: Quire.Layout.Settings.monogramFieldWidth)
            }
            QuireSettingsTextRow("Last error", text: "Gmail returned an unexpected response. The server closed the connection before the "
                                 + "download finished; SuperSparrow will try again in a few minutes.")
            QuireSettingsRow(nil) {
                Button("Remove…") {}.buttonStyle(.quire(.secondary, size: .small))
            }
            QuireSettingsSection("Google")
            QuireSettingsRow("Client ID") {
                TextField("", text: .constant("1084-ab3f9kq2.apps.googleusercontent.com"), prompt: QuireFieldStyle.prompt("….apps.googleusercontent.com"))
                    .quireFieldStyle(.mono)
            }
            QuireSettingsRow("Client secret") {
                QuireSecureField("Client secret", text: .constant("GOCSPX-k2v9f3Qm"))
            }
            QuireSettingsRow("Tenant") {
                TextField("", text: .constant(""), prompt: QuireFieldStyle.prompt("common"))
                    .quireFieldStyle(.mono)
            }
            QuireSettingsCaption("Register a Desktop app client in Google Cloud Console with the Gmail API enabled.",
                                 link: ("How to create these…", {}), spacingBelow: Quire.Layout.Settings.sectionGap)
            QuireSettingsRow(nil) {
                HStack(spacing: Quire.Layout.Settings.savedGap) {
                    Button("Show File in Finder") {}.buttonStyle(.quire(.secondary, size: .small))
                    Spacer(minLength: 0)
                    Button("Save") {}.buttonStyle(.quire(.primary, size: .small)).disabled(true)
                }
            }
        }
    }
}
