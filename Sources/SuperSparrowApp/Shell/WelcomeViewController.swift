import AppKit
import SSCore
import SSDesign

/// First run with no accounts (spec §5.39): the mark, the name and tagline, two equal ways in, the demo for
/// the curious, the privacy promise and the OAuth link, with the waiting, preparing and banner states the spec
/// defines. Laid out by hand in a flipped view so the block re-centres instantly whenever a state changes its
/// height.
@MainActor
final class WelcomeViewController: NSViewController {
    /// The newest message wins the banner slot.
    enum Banner: Equatable {
        /// “Couldn't add the account” + the reason.
        case signInError(reason: String)
        /// The demo store could not be seeded.
        case demoFailed
        /// A provider was chosen with no OAuth client configured for it.
        case missingClient(ProviderKind)
    }

    enum Activity: Equatable {
        case idle
        /// The browser is open for a sign-in started from this screen.
        case waiting(ProviderKind)
        /// “Try the demo” is seeding the demo store.
        case preparingDemo
    }

    var onAddAccount: ((ProviderKind) -> Void)?
    var onTryDemo: (() -> Void)?
    var onCancelSignIn: (() -> Void)?
    /// The missing-client banner's “Open Settings”, which opens Settings › OAuth with the incoming notice. When
    /// unset, and always for “Set up OAuth clients…”, the request goes up the responder chain to the app
    /// delegate (`showOAuthHelp(_:)`), which opens the tab without one.
    var onOpenOAuthSettings: (() -> Void)?

    private(set) var activity: Activity = .idle
    private(set) var banner: Banner?
    /// The provider of the last button pressed or waited for.
    private var chosen: ProviderKind = .gmail

    private let gmailButton = QuireButton(title: "Add Gmail account", variant: .secondary, size: .large,
                                          symbolName: Quire.Icon.addAccountProvider)
    private let microsoftButton = QuireButton(title: "Add Microsoft account", variant: .secondary, size: .large,
                                              symbolName: Quire.Icon.addAccountProvider)
    private let demoButton = QuireButton(title: "Try the demo", variant: .ghost, size: .regular)
    private let oauthLink = QuireButton(title: "Set up OAuth clients…", variant: .link, size: .small)
    private var bannerView: QuireBannerView?

    private var welcomeView: WelcomeView { view as! WelcomeView }

    override func loadView() {
        let root = WelcomeView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        gmailButton.trailingNote = "Google"
        microsoftButton.trailingNote = "365 · Outlook"
        for button in [gmailButton, microsoftButton] {
            button.loadingTitle = "Finish signing in in your browser…"
            button.loadingSpinnerSize = .medium
            button.loadingSpinnerColor = .qInk2
            button.target = self
        }
        gmailButton.action = #selector(addGmail)
        microsoftButton.action = #selector(addMicrosoft)
        demoButton.target = self
        demoButton.action = #selector(demoPressed)
        demoButton.loadingSpinnerColor = .qInk2
        demoButton.toolTip = "Explore SuperSparrow with two made-up mailboxes. Nothing leaves this Mac."
        oauthLink.target = self
        oauthLink.action = #selector(openOAuthSettings)
        root.buttons = (gmailButton, microsoftButton, demoButton, oauthLink)
        for control in [gmailButton, microsoftButton, demoButton, oauthLink] { root.addSubview(control) }
        gmailButton.nextKeyView = microsoftButton
        microsoftButton.nextKeyView = demoButton
        demoButton.nextKeyView = oauthLink
        oauthLink.nextKeyView = gmailButton
        view = root
        apply()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Two equal choices; the first has initial focus (§5.39).
        view.window?.makeFirstResponder(gmailButton)
    }

    // MARK: States

    /// The running sign-in (`SignInProgress`). Whichever window started an add (these buttons, File › Add…,
    /// Settings' +), the welcome shows the provider that is actually waiting, with Cancel, and offers no
    /// second sign-in; a reconnect has nothing to show here. Preparing the demo is not a sign-in's to end.
    func showSignIn(_ progress: SignInProgress?) {
        loadViewIfNeeded()
        if let progress {
            guard progress.reconnecting == nil, activity != .waiting(progress.kind) else { return }
            setActivity(.waiting(progress.kind))
        } else if case .waiting = activity {
            setActivity(.idle)
        }
    }

    func setActivity(_ activity: Activity) {
        loadViewIfNeeded()
        if case .waiting(let kind) = activity { chosen = kind }
        // A new attempt clears the old outcome; the result of this one may set a new banner.
        if activity != .idle { banner = nil }
        self.activity = activity
        apply()
    }

    func showBanner(_ banner: Banner?) {
        loadViewIfNeeded()
        self.banner = banner
        apply()
    }

    private func apply() {
        let waitingFor: ProviderKind? = { if case .waiting(let kind) = activity { return kind } else { return nil } }()
        let preparing = activity == .preparingDemo
        for (button, kind) in [(gmailButton, ProviderKind.gmail), (microsoftButton, .microsoft)] {
            let isChosen = waitingFor == kind
            button.isLoading = isChosen
            // The chosen button goes back to its rest face and becomes inert; focus stays on it.
            button.displayState = isChosen ? (view.window?.firstResponder === button ? .focused : .rest) : nil
            button.isEnabled = !preparing && (waitingFor == nil || isChosen)
        }
        demoButton.title = waitingFor != nil ? "Cancel" : "Try the demo"
        demoButton.loadingTitle = "Preparing the demo…"
        demoButton.isLoading = preparing
        demoButton.displayState = preparing ? .rest : nil
        demoButton.toolTip = waitingFor != nil ? nil : "Explore SuperSparrow with two made-up mailboxes. Nothing leaves this Mac."
        oauthLink.isEnabled = waitingFor == nil && !preparing
        applyBanner()
        welcomeView.needsLayout = true
    }

    private func applyBanner() {
        bannerView?.removeFromSuperview()
        bannerView = nil
        welcomeView.banner = nil
        guard let banner else { return }
        let made: QuireBannerView
        switch banner {
        case .signInError(let reason):
            made = QuireBannerView(kind: .danger, message: "Couldn't add the account. " + AppAlert.sentence(reason))
        case .demoFailed:
            made = QuireBannerView(kind: .danger, message: "Couldn't start the demo. The made-up mailboxes couldn't be created on this Mac.")
            made.setAction("Try again", target: self, action: #selector(tryDemoAgain))
        case .missingClient(let kind):
            let company = ErrorText.company(kind)
            made = QuireBannerView(kind: .info, message: "Add your \(company) OAuth client in Settings › OAuth first.",
                                   symbolName: Quire.Icon.info)
            made.setAction("Open Settings", target: self, action: #selector(openOAuthSettingsFromBanner))
        }
        made.allowsMultipleLines = true
        welcomeView.addSubview(made)
        welcomeView.banner = made
        bannerView = made
    }

    // MARK: Actions

    @objc private func addGmail() { choose(.gmail) }
    @objc private func addMicrosoft() { choose(.microsoft) }

    private func choose(_ kind: ProviderKind) {
        guard activity == .idle else { return }
        chosen = kind
        onAddAccount?(kind)
    }

    @objc private func demoPressed() {
        switch activity {
        case .idle: onTryDemo?()
        case .waiting: onCancelSignIn?()
        case .preparingDemo: break
        }
    }

    @objc private func tryDemoAgain() {
        guard activity == .idle else { return }
        onTryDemo?()
    }

    @objc private func openOAuthSettings() {
        guard activity == .idle else { return }
        NSApp.sendAction(#selector(AppDelegate.showOAuthHelp(_:)), to: nil, from: self)
    }

    @objc private func openOAuthSettingsFromBanner() {
        guard activity == .idle else { return }
        if let onOpenOAuthSettings {
            onOpenOAuthSettings()
        } else {
            openOAuthSettings()
        }
    }
}

/// The welcome screen's canvas: `paper` under the whole window (the title bar is transparent, §3.2) and the
/// block laid out from `layout.welcome`.
@MainActor
final class WelcomeView: NSView {
    var buttons: (gmail: QuireButton, microsoft: QuireButton, demo: QuireButton, link: QuireButton)?
    var banner: QuireBannerView? {
        didSet { needsLayout = true }
    }

    private let mark = WelcomeMarkView(frame: .zero)
    private let titleLabel = WelcomeView.label("SuperSparrow", role: .display, color: .qInk)
    private let taglineLabel = WelcomeView.label("Your mail, quietly fast.", role: .aside, color: .qInk2)
    private let footnote: NSTextField = {
        let text = NSMutableAttributedString()
        if let lock = WelcomeView.tintedSymbol(Quire.Icon.privacy, pointSize: QuireFont.Role.meta.size - 1, color: .qInk3) {
            let attachment = NSTextAttachment()
            attachment.image = lock
            attachment.bounds = NSRect(x: 0, y: -1, width: lock.size.width, height: lock.size.height)
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: "  "))
        }
        text.append(NSAttributedString(string: "Your mail is stored on this Mac and travels only between this Mac and Google or Microsoft. "
                                       + "No analytics, ever."))
        var attributes = QuireFont.attributes(.meta, color: .qInk3)
        let style = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        attributes[.paragraphStyle] = style
        text.addAttributes(attributes, range: NSRange(location: 0, length: text.length))
        let field = NSTextField(wrappingLabelWithString: "")
        field.attributedStringValue = text
        field.isSelectable = false
        field.setAccessibilityLabel("Your mail is stored on this Mac and travels only between this Mac and Google or Microsoft. No analytics, ever.")
        return field
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for subview in [mark, titleLabel, taglineLabel, footnote] as [NSView] { addSubview(subview) }
        mark.setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.qPaper.setFill()
        dirtyRect.fill()
    }

    private static func label(_ text: String, role: QuireFont.Role, color: NSColor) -> NSTextField {
        var attributes = QuireFont.attributes(role, color: color)
        let style = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        style.alignment = .center
        attributes[.paragraphStyle] = style
        let field = NSTextField(labelWithAttributedString: NSAttributedString(string: text, attributes: attributes))
        field.isSelectable = false
        return field
    }

    /// A symbol image that resolves its colour when drawn, so the footnote's lock follows the appearance.
    private static func tintedSymbol(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage? {
        guard let template = QuireSymbol.image(name, size: .custom(pointSize)) else { return nil }
        let size = template.size
        return NSImage(size: size, flipped: false) { rect in
            QuireSymbol.draw(name, size: .custom(pointSize), color: color, centredIn: rect)
            return true
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        guard let buttons else { return }
        let w = Quire.Layout.Welcome.self
        let zone = Quire.Layout.Window.titlebarZone
        let centreX = bounds.midX
        let titleHeight = QuireFont.Role.display.lineHeight
        let taglineHeight = QuireFont.Role.aside.lineHeight
        let buttonHeight = QuireButton.Size.large.height
        let footSize = footnote.sizeThatFits(NSSize(width: w.footWidth, height: .greatestFiniteMagnitude))
        let footHeight = ceil(footSize.height)
        let bannerHeight = banner.map { ceil($0.height(forWidth: w.blockWidth)) }

        var height = w.mark + w.titleGap + titleHeight + w.taglineGap + taglineHeight
        if let bannerHeight { height += w.actionsGap + bannerHeight + w.bannerGap } else { height += w.actionsGap }
        height += 2 * buttonHeight + w.buttonGap + w.demoGap + QuireButton.Size.regular.height
        height += w.footGap + footHeight + w.linkGap + QuireButton.Size.small.height

        // The block's centre sits at 0.45 of the content height below the title-bar zone: optically centred.
        let content = max(0, bounds.height - zone)
        var y = max(zone, (zone + content * w.blockCenterY - height / 2).rounded())

        mark.frame = NSRect(x: (centreX - w.mark / 2).rounded(), y: y, width: w.mark, height: w.mark)
        y += w.mark + w.titleGap
        titleLabel.frame = NSRect(x: 0, y: y, width: bounds.width, height: titleHeight)
        y += titleHeight + w.taglineGap
        taglineLabel.frame = NSRect(x: 0, y: y, width: bounds.width, height: taglineHeight)
        y += taglineHeight + w.actionsGap
        if let banner, let bannerHeight {
            banner.frame = NSRect(x: (centreX - w.blockWidth / 2).rounded(), y: y, width: w.blockWidth, height: bannerHeight)
            y += bannerHeight + w.bannerGap
        }
        let buttonX = (centreX - w.buttonWidth / 2).rounded()
        buttons.gmail.frame = buttons.gmail.frame(forVisualRect: NSRect(x: buttonX, y: y, width: w.buttonWidth, height: buttonHeight))
        y += buttonHeight + w.buttonGap
        buttons.microsoft.frame = buttons.microsoft.frame(forVisualRect: NSRect(x: buttonX, y: y, width: w.buttonWidth, height: buttonHeight))
        y += buttonHeight + w.demoGap
        let demoSize = buttons.demo.intrinsicContentSize
        buttons.demo.frame = buttons.demo.frame(forVisualRect: NSRect(x: (centreX - demoSize.width / 2).rounded(), y: y,
                                                                     width: demoSize.width, height: demoSize.height))
        y += demoSize.height + w.footGap
        footnote.frame = NSRect(x: (centreX - w.footWidth / 2).rounded(), y: y, width: w.footWidth, height: footHeight)
        y += footHeight + w.linkGap
        let linkSize = buttons.link.intrinsicContentSize
        buttons.link.frame = buttons.link.frame(forVisualRect: NSRect(x: (centreX - linkSize.width / 2).rounded(), y: y,
                                                                     width: linkSize.width, height: linkSize.height))
    }
}

/// The brand mark, `ss.sparrow` 52 pt in `accent`: the same drawing as the app icon (§5.42).
@MainActor
final class WelcomeMarkView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        QuireSymbol.draw(Quire.Icon.brand, size: .custom(Quire.Layout.Welcome.mark), color: .qAccent, centredIn: bounds)
    }
}
