import Foundation

/// The conversation shell: one HTML document each pooled web view loads once, after which every
/// conversation is a single `window.ss.render(payload)` call.
///
/// The assets live in SSCore as plain strings (no WebKit import) so the JavaScript contract can be
/// exercised from SSCoreTests next to `RenderPayload`, whose keys it reads. The CSS is Quire's reader
/// stylesheet (spec §8.4): the generated `QuireCSS.head` first, then the shell's own rules written against it.
public enum ConversationShellAssets {
    /// Scheme of the shell document. The app registers a `WKURLSchemeHandler` for it: WebKit never finishes a
    /// `loadHTMLString` whose base scheme has no handler, so this is not optional.
    public static let scheme = "ss-shell"
    /// Base URL of the shell document. Message bodies live in `sandbox="allow-same-origin"` iframes, which
    /// inherit this origin so the shell can measure them; nothing else is ever loaded from it.
    public static let baseURLString = scheme + "://local/"
    public static var baseURL: URL? { URL(string: baseURLString) }

    /// Script message handler the shell uses for everything but readiness.
    public static let messageHandlerName = "ss"
    /// Script message handler the shell pings once its `window.ss` API exists.
    public static let readyHandlerName = "ssReady"

    /// The SF Symbols the shell draws (spec §4.11, `readerSymbols` in tokens.json). The app rasterises exactly
    /// these once per web-view pool and hands them to `document(symbolCSS:)`; a glyph not on this list has no
    /// legal way to be drawn. `ReaderSymbolTests` holds it to tokens.json and to every name the CSS uses.
    public static let symbols: [String] = [
        "star", "star.fill", "arrowshape.turn.up.left", "arrowshape.turn.up.left.2", "arrowshape.turn.up.right",
        "ellipsis", "circle.lefthalf.filled", "xmark", "photo", "exclamationmark.triangle.fill", "wifi.slash",
        "doc", "doc.richtext", "tablecells", "doc.zipper", "film", "calendar", "checkmark", "info.circle",
    ]

    /// The custom property a rasterised symbol travels in: `star.fill` → `--sym-star-fill`.
    public static func symbolVariable(_ name: String) -> String {
        "--sym-" + name.replacingOccurrences(of: ".", with: "-")
    }

    /// The shell document. `symbolCSS` is the app's rasterised symbols as custom properties
    /// (`:root{--sym-star:url(data:…);…}`); without it every glyph is blank but nothing else changes.
    public static func document(symbolCSS: String = "") -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Conversation</title>
        <style>
        \(css)
        \(symbolCSS)
        </style>
        </head>
        <body>
        <main id="ss-root"></main>
        <script>
        \(js)
        </script>
        </body>
        </html>
        """
    }

    /// The shell without symbols, for tests and anything that never draws a glyph.
    public static let html: String = document()

    /// One modifier class per reader symbol, so markup names a glyph without knowing how it travels.
    static let symbolClasses: String = symbols.map { name in
        ".ss-sym-" + name.replacingOccurrences(of: ".", with: "-") + "{--sym:var(" + symbolVariable(name) + ")}"
    }.joined(separator: "\n")

    public static let css: String = QuireCSS.head + "\n" + shellCSS + "\n" + symbolClasses

    /// The shell's own rules (spec §5.13–5.19, §8.4). Every colour, font, radius and duration is a Quire
    /// variable; the old `--ss-*` names stay defined, mapped onto Quire, for anything that still reads them.
    static let shellCSS: String = #"""
    :root {
      --ss-bg: var(--q-canvas); --ss-card: var(--q-sheet); --ss-border: var(--q-rule); --ss-text: var(--q-ink);
      --ss-muted: var(--q-ink2); --ss-accent: var(--q-accent); --ss-chip: var(--q-fill); --ss-selected: var(--q-focus);
      --ss-star: var(--q-star);
      --ss-hair: 1px; --ss-ring: 2px; --ss-margin: 32px; --ss-pad-x: 28px; --ss-inset: 0px;
    }
    @media (min-resolution: 2dppx) { :root { --ss-hair: 0.5px; } }
    @media (prefers-contrast: more) { :root { --ss-hair: 1px; --ss-ring: 3px; } }
    html.ss-ic { --ss-hair: 1px; --ss-ring: 3px; }
    @media (max-width: 559px) { :root { --ss-margin: 16px; --ss-pad-x: 16px; } }
    @media (prefers-reduced-motion: reduce) { :root { --q-move: 0ms; } }
    html.ss-rm { --q-move: 0ms; }

    * { box-sizing: border-box; }
    html, body { margin: 0; padding: 0; background: var(--q-canvas); color: var(--q-ink); }
    body { font: var(--q-font-body); -webkit-user-select: text; -webkit-font-smoothing: antialiased; }
    button { font: inherit; color: inherit; margin: 0; -webkit-appearance: none; appearance: none; cursor: default; }
    button:focus, [tabindex]:focus { outline: none; }

    /* The reading column (spec §5.12): x = max(margin, (width − 680) / 2); margin 32, or 16 below 560 pt. */
    #ss-root {
      max-width: calc(680px + 2 * var(--ss-margin)); margin: 0 auto;
      padding: 16px var(--ss-margin) calc(var(--ss-inset) + 12px);
    }
    .ss-parts {
      font: var(--q-font-body); letter-spacing: var(--q-track-body); color: var(--q-ink2); margin: 0 0 16px;
      white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
    }

    /* SF Symbols, rasterised by the app into masks (spec §4.11): they take any token colour. */
    .ss-sym {
      display: inline-block; flex: none; width: 1.3em; height: 1.3em; background: currentColor;
      -webkit-mask-image: var(--sym); -webkit-mask-size: contain; -webkit-mask-repeat: no-repeat; -webkit-mask-position: center;
      mask-image: var(--sym); mask-size: contain; mask-repeat: no-repeat; mask-position: center;
    }
    .ss-glyph { display: inline-block; flex: none; width: 1em; height: 1em; }
    .ss-glyph svg { display: block; width: 100%; height: 100%; overflow: visible; }

    /* Cards: a collapsed card is a 44 pt stack row, an expanded one a sheet. Heights are always px so the
       expand and collapse transitions have values at both ends (spec §4.10). */
    .ss-card {
      position: relative; background: var(--q-sheet); overflow: hidden; height: 44px;
      transition: height var(--q-move, var(--q-dur-standard)) var(--q-ease-settle), opacity var(--q-dur-reducedFade) linear;
    }
    .ss-card.ss-sheet { margin-top: 12px; border-radius: var(--q-r-lg); box-shadow: 0 0 0 var(--ss-hair) var(--q-rule), var(--q-e1); }
    .ss-strow { position: relative; background: var(--q-sheet); box-shadow: 0 0 0 var(--ss-hair) var(--q-rule); }
    .ss-strow.ss-run-start { margin-top: 12px; border-top-left-radius: var(--q-r-lg); border-top-right-radius: var(--q-r-lg); }
    .ss-strow.ss-run-end { border-bottom-left-radius: var(--q-r-lg); border-bottom-right-radius: var(--q-r-lg); }
    .ss-folded { display: none; }
    html.ss-ic .ss-card.ss-sheet { box-shadow: 0 0 0 1px var(--q-ruleStrong), var(--q-e1); }
    html.ss-ic .ss-strow { box-shadow: 0 0 0 1px var(--q-ruleStrong); }
    @media (prefers-contrast: more) {
      .ss-card.ss-sheet { box-shadow: 0 0 0 1px var(--q-ruleStrong), var(--q-e1); }
      .ss-strow { box-shadow: 0 0 0 1px var(--q-ruleStrong); }
    }
    /* The target message's edge while several are open, and whenever the keycaps hide (spec §5.14). */
    #ss-root.ss-multi .ss-card.ss-sheet.ss-target { box-shadow: 0 0 0 1px var(--q-ruleStrong), var(--q-e1); }
    @media (max-width: 615px) { .ss-card.ss-sheet.ss-target { box-shadow: 0 0 0 1px var(--q-ruleStrong), var(--q-e1); } }
    .ss-card.ss-sheet.ss-focus {
      box-shadow: 0 0 0 var(--ss-hair) var(--q-rule), 0 0 0 2px var(--q-canvas), 0 0 0 calc(2px + var(--ss-ring)) var(--q-focus), var(--q-e1);
    }
    .ss-strow.ss-focus::after {
      content: ''; position: absolute; inset: 1px; border-radius: 6px; box-shadow: inset 0 0 0 2px var(--q-focus); pointer-events: none;
    }

    /* Stack rows (spec §5.13). */
    .ss-row { display: none; align-items: center; gap: 10px; height: 44px; padding: 0 16px; white-space: nowrap; position: relative; }
    .ss-collapsed .ss-row { display: flex; }
    .ss-collapsed .ss-inner { display: none; }
    .ss-strow:hover { background: linear-gradient(var(--q-hover), var(--q-hover)), var(--q-sheet); }
    .ss-strow:active { background: linear-gradient(var(--q-pressed), var(--q-pressed)), var(--q-sheet); }
    .ss-rpip { position: absolute; left: 5px; top: 19px; width: 6px; height: 6px; border-radius: 50%; background: var(--q-accent); display: none; }
    .ss-unread .ss-rpip { display: block; }
    .ss-rname { width: 112px; flex: none; overflow: hidden; text-overflow: ellipsis; font: var(--q-font-senderMedium); color: var(--q-ink); }
    .ss-unread .ss-rname { font-weight: 600; }
    .ss-rsnip { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; font: var(--q-font-sender); color: var(--q-ink2); }
    .ss-rstar { font-size: 12px; color: var(--q-star); margin-right: -6px; }
    .ss-rdate { flex: none; font: var(--q-font-meta); font-variant-numeric: tabular-nums; color: var(--q-ink3); }
    .ss-fold { height: 44px; display: flex; align-items: center; justify-content: center; font: var(--q-font-label); color: var(--q-ink2); }
    .ss-fold:hover { color: var(--q-ink); }
    .ss-ph { font-style: italic; font-weight: 400; color: var(--q-ink3); }

    /* Avatars: initials on the eight soft tints (spec §4.3), New York Semibold at 0.42 × the diameter. */
    .ss-av {
      flex: none; border-radius: 50%; display: inline-flex; align-items: center; justify-content: center;
      font-family: var(--q-serif); font-weight: 600; background: var(--ss-face); color: var(--ss-avink); -webkit-user-select: none;
    }
    .ss-av24 { width: 24px; height: 24px; font-size: 10px; line-height: 24px; }
    .ss-av36 { width: 36px; height: 36px; font-size: 15px; line-height: 36px; }
    /* The SF Pro font (spec §4.4): the twin `monogramSans`, SF Pro Semibold at 0.39 × the diameter (24 pt stays at the 10 pt floor). */
    html.ss-sf .ss-av { font-family: var(--q-sans); }
    html.ss-sf .ss-av36 { font-size: 14px; }
    .ss-tint-0 { --ss-face: var(--q-av-clay-face); --ss-avink: var(--q-av-clay-ink); }
    .ss-tint-1 { --ss-face: var(--q-av-wheat-face); --ss-avink: var(--q-av-wheat-ink); }
    .ss-tint-2 { --ss-face: var(--q-av-fern-face); --ss-avink: var(--q-av-fern-ink); }
    .ss-tint-3 { --ss-face: var(--q-av-sea-face); --ss-avink: var(--q-av-sea-ink); }
    .ss-tint-4 { --ss-face: var(--q-av-slate-face); --ss-avink: var(--q-av-slate-ink); }
    .ss-tint-5 { --ss-face: var(--q-av-heather-face); --ss-avink: var(--q-av-heather-ink); }
    .ss-tint-6 { --ss-face: var(--q-av-rose-face); --ss-avink: var(--q-av-rose-ink); }
    .ss-tint-7 { --ss-face: var(--q-av-stone-face); --ss-avink: var(--q-av-stone-ink); }

    /* The open sheet (spec §5.14): padding 22 28 14 (16 at the sides below 560 pt). */
    .ss-inner { padding: 22px var(--ss-pad-x) 14px; }
    .ss-head { display: flex; gap: 12px; align-items: flex-start; }
    .ss-who { flex: 1; min-width: 0; }
    .ss-nl {
      display: flex; align-items: center; min-width: 0; height: 18px; white-space: nowrap;
      font: var(--q-font-bodyStrong); color: var(--q-ink);
    }
    .ss-name { overflow: hidden; text-overflow: ellipsis; min-width: 0; }
    .ss-pip7 { width: 7px; height: 7px; border-radius: 50%; background: var(--q-accent); margin-right: 6px; flex: none; display: none; }
    .ss-unread .ss-pip7 { display: inline-block; }
    .ss-nstar { font-size: 12px; color: var(--q-star); margin-left: 4px; }
    .ss-addr {
      flex: 0 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis;
      font: var(--q-font-meta); color: var(--q-ink3); margin-left: 6px; opacity: 0;
    }
    .ss-sheet:hover .ss-addr, .ss-sheet:focus-within .ss-addr, .ss-sheet.ss-focus .ss-addr {
      opacity: 1; transition: opacity var(--q-dur-quick) var(--q-ease-settle);
    }
    /* Unsubscribe beside the sender (spec §5.14): a link in the recipients line's type and colour, underlined like
       the header's other link ("and 24 more"), at rest as well, since it is the only way to tell it from the name
       line's text; it never shrinks, the name truncates first. */
    .ss-unsub {
      flex: none; margin-left: 6px; padding: 0; border: 0; background: none; border-radius: 3px;
      font: var(--q-font-snippet); line-height: 16px; color: var(--q-ink2);
      text-decoration: underline; text-decoration-thickness: 1px; text-underline-offset: 2px;
    }
    .ss-unsub:hover, .ss-unsub:active { color: var(--q-ink); }
    .ss-unsub:focus-visible { box-shadow: 0 0 0 1px var(--q-sheet), 0 0 0 calc(1px + var(--ss-ring)) var(--q-focus); }
    /* The link takes room the name line had; the address, which shows nothing at rest, gives its share up before the
       name gives any, and the line still does not reflow on hover. */
    .ss-unsub + .ss-addr { flex-shrink: 1000; }
    .ss-rc {
      display: block; max-width: 100%; padding: 0; border: 0; background: none; border-radius: 3px; text-align: start;
      font: var(--q-font-snippet); line-height: 16px; color: var(--q-ink2);
      white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
    }
    .ss-rc:focus-visible, .ss-rcx:focus-visible { box-shadow: 0 0 0 1px var(--q-sheet), 0 0 0 calc(1px + var(--ss-ring)) var(--q-focus); }
    .ss-rcx { display: grid; gap: 2px; border-radius: 3px; }
    .ss-rcf { display: grid; grid-template-columns: 28px minmax(0, 1fr); font: var(--q-font-snippet); }
    .ss-rcl { color: var(--q-ink3); }
    .ss-rcv { color: var(--q-ink2); min-width: 0; }
    .ss-person { display: inline-block; max-width: 100%; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; vertical-align: top; margin-right: 0.3em; }
    .ss-person .ss-pad { color: var(--q-ink3); }
    .ss-more { padding: 0; border: 0; background: none; font: var(--q-font-snippet); color: var(--q-ink2); text-decoration: underline; text-underline-offset: 2px; }
    .ss-meta {
      flex: none; display: flex; align-items: center; height: 18px;
      font: var(--q-font-snippet); line-height: 18px; font-variant-numeric: tabular-nums; color: var(--q-ink3);
    }
    .ss-hacts { display: flex; gap: 2px; margin: -3px 8px -3px 0; }
    .ss-hacts:empty { display: none; }
    .ss-hact { opacity: 0; }
    .ss-hact.ss-qon,
    .ss-sheet:hover .ss-hact, .ss-sheet:focus-within .ss-hact, .ss-sheet.ss-focus .ss-hact {
      opacity: 1; transition: opacity var(--q-dur-quick) var(--q-ease-settle);
    }
    .ss-ib {
      width: 24px; height: 24px; padding: 0; border: 0; border-radius: var(--q-r-sm); background: none;
      color: var(--q-ink2); display: inline-flex; align-items: center; justify-content: center; font-size: 14px;
    }
    .ss-ib:hover { background: var(--q-hover); color: var(--q-ink); }
    .ss-ib:active { background: var(--q-pressed); color: var(--q-ink); }
    .ss-ib.ss-on, .ss-ib.ss-on:hover, .ss-ib.ss-on:active { color: var(--q-star); }
    .ss-ib.ss-qon { background: var(--q-accentWash); color: var(--q-accent); }
    .ss-ib.ss-qon:hover { background: var(--q-accentWashHover); color: var(--q-accent); }
    .ss-ib.ss-qon:active { background: var(--q-accentWashPressed); color: var(--q-accent); }
    .ss-ib:focus-visible { box-shadow: 0 0 0 1px var(--q-sheet), 0 0 0 calc(1px + var(--ss-ring)) var(--q-focus); }

    /* Body: plain and unstyled bodies sit at the 48 pt indent inside the 576 pt measure; styled ones take the
       full content width (spec §5.14). */
    .ss-ind { margin-left: 48px; }
    .ss-body { margin-top: 18px; }
    .ss-card.ss-typeset .ss-body { margin-left: 48px; max-width: 576px; }
    .ss-card.ss-draft .ss-body { margin-left: 0; margin-top: 10px; }
    .ss-incomposer { margin: 0; font: var(--q-font-snippet); letter-spacing: var(--q-track-snippet); color: var(--q-ink3); }
    /* A draft's body is set from the sheet's edge, so its elision chip, chips and footer start there too (spec §5.19). */
    .ss-card.ss-draft .ss-ind { margin-left: 0; }
    .ss-frame { position: relative; }
    .ss-frame iframe { display: block; width: 100%; height: 0; border: 0; background: transparent; color-scheme: light dark; }
    .ss-original { background: var(--q-originalPage); border-radius: var(--q-r-xs); padding: 12px; color-scheme: light; }
    .ss-original iframe { color-scheme: light; }
    .ss-preview { margin: 0 0 12px; max-width: 576px; font: var(--q-font-reading); color: var(--q-ink2); }
    .ss-preview.ss-sans { font: var(--q-font-readingSans); }
    .ss-skels { display: grid; gap: 14px; padding-top: 2px; }
    /* Bars only after skeletonDelay: while a fetch runs (ss-delayed), and while a frame is loading under its
       provisional height (ss-held), which almost always lands first, so no bars flash (spec §5.14). */
    .ss-skels.ss-delayed, .ss-skels.ss-held { opacity: 0; animation: ss-appear 1ms linear var(--q-dur-skeletonDelay) forwards; }
    .ss-frame > .ss-skels:not(:only-child) { position: absolute; left: 0; right: 0; top: 0; }
    .ss-skel { display: block; height: 10px; border-radius: var(--q-r-xs); background: var(--q-fill); }
    .ss-skel:nth-child(2) { width: 92%; }
    .ss-skel:nth-child(3) { width: 60%; }

    /* Banners (spec §5.16, §5.38): neutral for remote images, warning for the Original colors notice. */
    .ss-banners:empty { display: none; }
    .ss-banner {
      display: flex; align-items: center; gap: 8px; min-height: 32px; margin-bottom: 12px; padding: 0 6px 0 10px;
      border-radius: var(--q-r-md); background: var(--q-fill); color: var(--q-ink);
      font: var(--q-font-snippet); line-height: 16px;
    }
    .ss-frame .ss-banner { margin: 0; }
    .ss-banner > .ss-sym { font-size: 14px; color: var(--q-ink2); }
    .ss-banner > .ss-spin { color: var(--q-ink3); margin: 0 1px; }
    .ss-sending { display: inline-flex; align-items: center; gap: 6px; }
    .ss-sending > .ss-spin { color: var(--q-ink3); }
    .ss-btxt { flex: 1; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; padding: 8px 0; }
    .ss-btxt .ss-narrow { display: none; }
    @media (max-width: 419px) { .ss-btxt .ss-wide { display: none; } .ss-btxt .ss-narrow { display: inline; } }
    .ss-banner.ss-warn { background: var(--q-warningWash); }
    .ss-banner.ss-warn > .ss-sym, .ss-banner > .ss-sym.ss-warning { color: var(--q-warning); }
    .ss-banner.ss-bad { background: var(--q-dangerWash); }
    .ss-banner.ss-bad > .ss-sym { color: var(--q-danger); }
    .ss-link {
      flex: none; height: 24px; padding: 0 4px; border: 0; border-radius: var(--q-r-sm); background: none;
      font: var(--q-font-label); color: var(--q-accent);
    }
    .ss-link:hover { text-decoration: underline; text-decoration-thickness: 1px; text-underline-offset: 2px; }
    .ss-link:active { text-decoration: underline; text-decoration-thickness: 1px; text-underline-offset: 2px; color: var(--q-ink2); }
    html.ss-graphite .ss-link { text-decoration: underline; text-decoration-thickness: 1px; text-underline-offset: 2px; }
    .ss-link:focus-visible, .ss-na:focus-visible, .ss-bx:focus-visible {
      box-shadow: 0 0 0 1px var(--q-sheet), 0 0 0 calc(1px + var(--ss-ring)) var(--q-focus);
    }
    .ss-na {
      flex: none; height: 24px; padding: 0 6px; border: 0; border-radius: var(--q-r-sm); background: none;
      font: var(--q-font-labelStrong); color: var(--q-ink);
    }
    .ss-na:hover { background: var(--q-hover); }
    .ss-na:active { background: var(--q-pressed); }
    .ss-bx {
      flex: none; width: 24px; height: 24px; padding: 0; border: 0; border-radius: var(--q-r-sm); background: none;
      display: inline-flex; align-items: center; justify-content: center; color: var(--q-ink2); font-size: 9px;
    }
    .ss-bx:hover { background: var(--q-hover); color: var(--q-ink); }

    .ss-banner.ss-info { background: var(--q-infoWash); }
    .ss-banner.ss-info > .ss-sym { color: var(--q-info); }
    .ss-banner.ss-wrap { align-items: flex-start; }
    .ss-banner.ss-wrap > .ss-sym { margin-top: 9px; }
    .ss-banner.ss-wrap .ss-btxt { white-space: normal; }
    .ss-banner.ss-wrap > .ss-link { align-self: flex-end; margin-bottom: 4px; }

    /* The invitation card (spec §5.14, layout.invitation): above the body at the indent, inside the measure; the
       chosen answer is an accentWash button with a checkmark, the others small secondary buttons. */
    .ss-invite {
      margin: 18px 0 0 48px; max-width: 576px; padding: 12px 16px; border-radius: var(--q-r-lg); background: var(--q-sheet);
      box-shadow: inset 0 0 0 var(--ss-hair) var(--q-rule);
    }
    html.ss-ic .ss-invite { box-shadow: inset 0 0 0 1px var(--q-ruleStrong); }
    @media (prefers-contrast: more) { .ss-invite { box-shadow: inset 0 0 0 1px var(--q-ruleStrong); } }
    .ss-invite:not([hidden]) + .ss-body { margin-top: 16px; }
    .ss-ikick {
      display: flex; align-items: center; gap: 6px; font: var(--q-font-runningHead); letter-spacing: var(--q-track-runningHead);
      text-transform: uppercase; color: var(--q-ink3);
    }
    .ss-ikick > .ss-sym { font-size: 14px; width: 14px; height: 14px; }
    .ss-invite.ss-cancelled .ss-ikick { color: var(--q-danger); }
    .ss-ititle { margin-top: 6px; font: var(--q-font-title); letter-spacing: var(--q-track-title); color: var(--q-ink); overflow-wrap: anywhere; }
    .ss-ititle.ss-ph { font-style: italic; color: var(--q-ink3); }
    .ss-invite.ss-cancelled .ss-ititle { color: var(--q-ink2); text-decoration: line-through; text-decoration-thickness: 1px; }
    .ss-iwhen { margin-top: 2px; font: var(--q-font-body); letter-spacing: var(--q-track-body); color: var(--q-ink); }
    .ss-ielse { font: var(--q-font-snippet); letter-spacing: var(--q-track-snippet); color: var(--q-ink3); }
    .ss-irep { margin-top: 2px; font: var(--q-font-snippet); letter-spacing: var(--q-track-snippet); color: var(--q-ink2); }
    .ss-idet {
      margin: 8px 0 0; display: grid; grid-template-columns: 72px minmax(0, 1fr); row-gap: 2px;
      font: var(--q-font-snippet); letter-spacing: var(--q-track-snippet); line-height: 16px;
    }
    .ss-idet dt { color: var(--q-ink3); }
    .ss-idet dd { margin: 0; color: var(--q-ink2); overflow-wrap: anywhere; }
    /* One line, cut with an ellipsis: a Teams link runs to hundreds of characters. The whole address is the tooltip. */
    .ss-idet .ss-ilink {
      display: block; max-width: 100%; padding: 0; height: auto; border: 0; background: none; font: inherit;
      color: var(--q-accent); text-align: start; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
      border-radius: var(--q-r-xs);
    }
    .ss-idet .ss-ilink:hover { text-decoration: underline; text-decoration-thickness: 1px; text-underline-offset: 2px; }
    .ss-idet .ss-ilink:active { text-decoration: underline; color: var(--q-ink2); }
    html.ss-graphite .ss-idet .ss-ilink { text-decoration: underline; text-decoration-thickness: 1px; text-underline-offset: 2px; }
    .ss-idet .ss-ilink:focus-visible { box-shadow: 0 0 0 1px var(--q-sheet), 0 0 0 calc(1px + var(--ss-ring)) var(--q-focus); }
    .ss-iacts {
      margin-top: 12px; padding-top: 10px; border-top: var(--ss-hair) solid var(--q-rule);
      display: flex; align-items: center; gap: 4px; flex-wrap: wrap;
    }
    .ss-iacts .ss-iopen { margin-left: auto; }
    .ss-ans {
      height: 22px; padding: 0 9px; border: 0; border-radius: var(--q-r-sm); background: var(--q-raised);
      box-shadow: inset 0 0 0 1px var(--q-ruleStrong); display: inline-flex; align-items: center; gap: 6px;
      font: var(--q-font-label); color: var(--q-ink); white-space: nowrap;
    }
    .ss-ans > .ss-sym { display: none; font-size: 12px; width: 12px; height: 12px; }
    .ss-ans:hover { background: linear-gradient(var(--q-hover), var(--q-hover)), var(--q-raised); }
    .ss-ans:active { background: linear-gradient(var(--q-pressed), var(--q-pressed)), var(--q-raised); }
    .ss-ans:focus-visible { box-shadow: inset 0 0 0 1px var(--q-ruleStrong), 0 0 0 1px var(--q-sheet), 0 0 0 calc(1px + var(--ss-ring)) var(--q-focus); }
    .ss-ans.ss-chosen { background: var(--q-accentWash); box-shadow: none; color: var(--q-accent); font: var(--q-font-labelStrong); padding-left: 7px; }
    .ss-ans.ss-chosen > .ss-sym { display: inline-block; }
    .ss-ans.ss-chosen:hover { background: var(--q-accentWashHover); }
    .ss-ans.ss-chosen:active { background: var(--q-accentWashPressed); }
    .ss-ans.ss-chosen:focus-visible { box-shadow: 0 0 0 1px var(--q-sheet), 0 0 0 calc(1px + var(--ss-ring)) var(--q-focus); }
    .ss-invite > .ss-banner { margin: 10px 0 0; }

    /* The elision mark (spec §5.15). */
    .ss-qrow { margin-top: 12px; }
    .ss-elide {
      display: inline-flex; align-items: center; gap: 6px; height: 24px; padding: 0 9px 0 6px; border: 0;
      border-radius: var(--q-r-md); background: var(--q-fill); color: var(--q-ink2);
      font: var(--q-font-label); white-space: nowrap;
    }
    .ss-elide .ss-glyph { font-size: 14px; }
    .ss-elide:hover { background: linear-gradient(var(--q-hover), var(--q-hover)), var(--q-fill); color: var(--q-ink); }
    .ss-elide:active { background: linear-gradient(var(--q-pressed), var(--q-pressed)), var(--q-fill); color: var(--q-ink); }
    .ss-elide.ss-on { background: var(--q-accentWash); color: var(--q-accent); }
    .ss-elide.ss-on:hover { background: var(--q-accentWashHover); color: var(--q-accent); }
    .ss-elide.ss-on:active { background: var(--q-accentWashPressed); color: var(--q-accent); }
    .ss-elide:focus-visible { box-shadow: 0 0 0 1px var(--q-sheet), 0 0 0 calc(1px + var(--ss-ring)) var(--q-focus); }

    /* Attachment chips (spec §5.17). */
    .ss-atts { margin-top: 16px; display: flex; flex-wrap: wrap; gap: 8px; }
    .ss-atts:empty { display: none; }
    .ss-chip {
      position: relative; height: 44px; min-width: 196px; max-width: 264px; padding: 0 14px 0 8px; border: 0;
      border-radius: var(--q-r-lg); background: var(--q-sheet); box-shadow: inset 0 0 0 var(--ss-hair) var(--q-rule);
      display: flex; align-items: center; gap: 10px; text-align: start; overflow: hidden; white-space: nowrap;
    }
    .ss-chip:hover { background: linear-gradient(var(--q-hover), var(--q-hover)), var(--q-sheet); box-shadow: inset 0 0 0 1px var(--q-ruleStrong); }
    .ss-chip:active { background: linear-gradient(var(--q-pressed), var(--q-pressed)), var(--q-sheet); }
    .ss-chip:focus-visible {
      box-shadow: inset 0 0 0 var(--ss-hair) var(--q-rule), 0 0 0 1px var(--q-sheet), 0 0 0 calc(1px + var(--ss-ring)) var(--q-focus);
    }
    .ss-tile {
      flex: none; width: 28px; height: 28px; border-radius: var(--q-r-sm); background: var(--q-fill); color: var(--q-ink2);
      display: flex; align-items: center; justify-content: center; font-size: 15px;
    }
    .ss-chip-text { display: flex; flex-direction: column; min-width: 0; }
    .ss-chip-name { display: flex; min-width: 0; font: var(--q-font-label); color: var(--q-ink); }
    .ss-chip-name .ss-cb { overflow: hidden; text-overflow: ellipsis; min-width: 0; }
    .ss-chip-name .ss-ce { flex: none; }
    .ss-chip-meta { font: var(--q-font-meta); color: var(--q-ink3); }
    .ss-chip-meta .ss-hover-meta, .ss-chip:hover .ss-chip-meta .ss-rest-meta { display: none; }
    .ss-chip:hover .ss-chip-meta .ss-hover-meta { display: inline; }
    .ss-chip.ss-failed .ss-tile { color: var(--q-danger); }
    .ss-chip.ss-failed .ss-chip-meta, .ss-chip.ss-failed:hover .ss-chip-meta .ss-rest-meta { display: inline; color: var(--q-danger); }
    .ss-chip.ss-failed .ss-chip-meta .ss-hover-meta { display: none; }
    .ss-chip.ss-failed .ss-retry { font: var(--q-font-metaStrong); color: var(--q-accent); }
    /* Downloading (spec §5.17, §5.37): the meta gives way to a 120 × 2 pt contrail on a rule track. Determinate
       when the fetch reports progress, otherwise a 0.36 segment sweeping (Reduce Motion: a still 0.4 segment). */
    .ss-dl { display: none; position: relative; width: 120px; height: 2px; margin: 6px 0 5px; border-radius: 1px;
             background: var(--q-rule); overflow: visible; }
    .ss-chip.ss-loading .ss-chip-meta { display: none; }
    .ss-chip.ss-loading .ss-dl { display: block; }
    .ss-dl-fill { position: absolute; left: 0; top: 0; height: 2px; width: 0;
                  background: linear-gradient(to left, var(--q-accent) calc(100% - 32px), transparent 100%); }
    .ss-dl-fill::after { content: ''; position: absolute; right: -2px; top: -1px; width: 4px; height: 4px; border-radius: 50%;
                         background: var(--q-accent); }
    .ss-dl.ss-sweep .ss-dl-fill { width: 36%; animation: ss-sweep var(--q-dur-contrailSweep) linear infinite; }
    @keyframes ss-sweep { from { left: -36%; } to { left: 100%; } }
    @media (prefers-reduced-motion: reduce) { .ss-dl.ss-sweep .ss-dl-fill { width: 40%; left: 30%; animation: none; } }
    html.ss-rm .ss-dl.ss-sweep .ss-dl-fill { width: 40%; left: 30%; animation: none; }

    /* Footer (spec §5.14): ghost buttons at the indent; the target's carry R · A · F keycaps. */
    .ss-foot {
      margin-top: 16px; padding-top: 10px; border-top: var(--ss-hair) solid var(--q-rule);
      display: flex; align-items: center; gap: 4px; flex-wrap: wrap;
    }
    .ss-gb, .ss-sb {
      height: 28px; padding: 0 10px 0 8px; border: 0; border-radius: var(--q-r-md); background: none;
      display: inline-flex; align-items: center; gap: 6px; white-space: nowrap;
      font: var(--q-font-bodyMedium); color: var(--q-ink2);
    }
    .ss-gb .ss-sym, .ss-sb .ss-sym, .ss-sb .ss-glyph { font-size: 14px; }
    .ss-gb:hover { background: var(--q-hover); color: var(--q-ink); }
    .ss-gb:active { background: var(--q-pressed); color: var(--q-ink); }
    .ss-sb { padding: 0 12px 0 10px; background: var(--q-raised); color: var(--q-ink); box-shadow: inset 0 0 0 1px var(--q-ruleStrong); }
    .ss-sb:hover { background: linear-gradient(var(--q-hover), var(--q-hover)), var(--q-raised); }
    .ss-sb:active { background: linear-gradient(var(--q-pressed), var(--q-pressed)), var(--q-raised); }
    .ss-gb:focus-visible { box-shadow: 0 0 0 1px var(--q-sheet), 0 0 0 calc(1px + var(--ss-ring)) var(--q-focus); }
    .ss-sb:focus-visible { box-shadow: inset 0 0 0 1px var(--q-ruleStrong), 0 0 0 1px var(--q-sheet), 0 0 0 calc(1px + var(--ss-ring)) var(--q-focus); }
    .ss-kbd {
      display: none; align-items: center; justify-content: center; height: 18px; min-width: 18px; padding: 0 4px;
      margin: 0 8px 0 2px; border-radius: var(--q-r-xs); background: var(--q-raised);
      box-shadow: inset 0 0 0 var(--ss-hair) var(--q-rule), inset 0 -1px 0 var(--q-rule);
      font: var(--q-font-kbd); color: var(--q-ink2); white-space: nowrap; flex: none; -webkit-user-select: none;
    }
    html.ss-ic .ss-kbd { box-shadow: inset 0 0 0 1px var(--q-ruleStrong), inset 0 -1px 0 var(--q-ruleStrong); }
    @media (prefers-contrast: more) { .ss-kbd { box-shadow: inset 0 0 0 1px var(--q-ruleStrong), inset 0 -1px 0 var(--q-ruleStrong); } }
    .ss-target .ss-foot .ss-kbd, .ss-draft .ss-foot .ss-kbd { display: inline-flex; }
    @media (max-width: 615px) { .ss-foot .ss-kbd { display: none !important; } }

    /* Drafts (spec §5.19). */
    .ss-dhead { display: flex; align-items: baseline; gap: 12px; font: var(--q-font-snippet); line-height: 16px; }
    .ss-dto { flex: 1; min-width: 0; color: var(--q-ink2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .ss-ddate { flex: none; color: var(--q-ink3); font-variant-numeric: tabular-nums; }
    .ss-draft .ss-foot { gap: 8px; }
    .ss-draft .ss-foot .ss-kbd { margin: 0 4px 0 -2px; }

    /* Spinner (spec §5.37): a ¾ ring turning once per spinnerTurn, shown only after spinnerDelay. */
    .ss-spin {
      display: inline-block; flex: none; width: 12px; height: 12px; border-radius: 50%;
      border: 1.5px solid currentColor; border-right-color: transparent; opacity: 0;
      animation: ss-turn var(--q-dur-spinnerTurn) linear infinite, ss-appear var(--q-dur-quick) linear var(--q-dur-spinnerDelay) forwards;
    }
    @keyframes ss-turn { to { transform: rotate(1turn); } }
    @keyframes ss-appear { to { opacity: 1; } }
    .ss-contrail { transition: width var(--q-countdown) linear; }
    @media (prefers-reduced-motion: reduce) { .ss-contrail { transition-timing-function: steps(var(--q-countdown-steps)); } }
    html.ss-rm .ss-contrail { transition-timing-function: steps(var(--q-countdown-steps)); }
    """#

    /// The variables a body document needs, cut from `QuireCSS.head` block by block, so `html.ss-ic` and
    /// `html.ss-graphite` switch them inside the frame exactly as they do in the shell.
    static let bodyVariables: String = {
        let keep: Set<String> = [
            "--q-ink", "--q-ink2", "--q-ink3", "--q-accent", "--q-rule", "--q-focus", "--q-sheet", "--q-fill",
            "--q-originalPage", "--q-sans", "--q-serif", "--q-font-reading", "--q-font-readingSans", "--q-font-writing",
            "--q-track-reading", "--q-track-readingSans", "--q-track-writing", "--q-r-xs",
        ]
        return QuireCSS.head.components(separatedBy: "\n").compactMap { line -> String? in
            guard let first = line.range(of: "--") else { return nil }
            let prefix = String(line[..<first.lowerBound])
            var suffix = ""
            var body = Substring(line[first.lowerBound...])
            while body.hasSuffix("}") {
                suffix.append("}")
                body = body.dropLast()
            }
            let kept = body.split(separator: ";").filter { declaration in
                guard let colon = declaration.firstIndex(of: ":") else { return false }
                return keep.contains(String(declaration[..<colon]))
            }
            guard !kept.isEmpty else { return nil }
            return prefix + kept.joined(separator: ";") + ";" + suffix
        }.joined(separator: "\n")
    }()

    /// Styles injected into every body iframe (spec §8.4): the Quire reading page for plain and unstyled bodies,
    /// the link focus ring, dark-mode adaptation for bodies that declare colours, and the quote fold.
    public static let bodyCSS: String = bodyVariables + "\n" + #"""
    html, body { margin: 0; padding: 0; }
    html { overflow-x: hidden; overflow-y: hidden; }
    html.ss-wide { overflow-x: auto; }
    body {
      font: 13px/1.45 -apple-system, BlinkMacSystemFont, "Helvetica Neue", Helvetica, Arial, sans-serif;
      overflow-wrap: break-word; word-wrap: break-word;
      /* The shell's own text is set this way; without it a body's light-on-dark text renders a weight heavier. */
      -webkit-font-smoothing: antialiased;
    }
    img { max-width: 100%; height: auto; }
    pre { white-space: pre-wrap; }
    .ss-quote { display: none; }
    body.ss-show-quotes .ss-quote { display: block; }
    /* Gmail and others put a <br> between the new text and the quote. With the quote folded that break is an
       empty line, and the elision mark would sit a line below the 12 pt the spec gives it (§5.14). It is
       hidden only while the folded quote is the last thing in its block, so no text can join up. */
    body:not(.ss-show-quotes) br:has(+ .ss-quote:last-child) { display: none; }
    .ss-quote { border-left: 2px solid var(--q-rule); padding-left: 12px; }
    .ss-plain { white-space: pre-wrap; }
    body.ss-set { font: var(--q-font-reading); letter-spacing: var(--q-track-reading); color: var(--q-ink); max-width: 576px; background: transparent; }
    body.ss-set.ss-sans { font: var(--q-font-readingSans); letter-spacing: var(--q-track-readingSans); }
    body.ss-set.ss-draft { font: var(--q-font-writing); letter-spacing: var(--q-track-writing); }
    body.ss-set p { margin: 0 0 12px; }
    body.ss-set p:last-child { margin-bottom: 0; }
    body.ss-set blockquote { margin: 0; border-left: 2px solid var(--q-rule); padding-left: 12px; color: var(--q-ink2); }
    body.ss-set .ss-quote { color: var(--q-ink2); }
    body.ss-set a:link { color: var(--q-accent); }
    a:focus { outline: none; }
    a:focus-visible { outline: 2px solid var(--q-focus) !important; outline-offset: 1px !important;
                      box-shadow: 0 0 0 1px var(--q-sheet) !important; border-radius: 2px; }
    @media (prefers-contrast: more) { a:focus-visible { outline-width: 3px !important; } }
    html.ss-ic a:focus-visible { outline-width: 3px !important; }
    .ss-original a:focus-visible { --q-focus: #1E5468; box-shadow: 0 0 0 1px var(--q-originalPage) !important; }
    @media (prefers-contrast: more) { .ss-original a:focus-visible { --q-focus: #123E4D; } }
    html.ss-ic.ss-original a:focus-visible { --q-focus: #123E4D; }
    html.ss-adapt { color-scheme: dark; }
    html.ss-adapt, html.ss-adapt body, html.ss-adapt body * {
      color: var(--q-ink) !important;
      background-color: transparent !important;
      background-image: none !important;
      border-color: var(--q-rule) !important;
    }
    html.ss-adapt a, html.ss-adapt a * { color: var(--q-accent) !important; }
    :where(a:link) { color: var(--q-accent); }
    html.ss-original { color-scheme: light; }
    """#

    public static let js: String = "var SS_BODY_CSS = " + jsStringLiteral(bodyCSS) + ";\n" + script

    /// Message bodies are loaded with `srcdoc` into `sandbox="allow-same-origin"` iframes: no scripts run
    /// inside them, not even listeners the shell adds, so the shell measures each document from the parent
    /// after load, on resize and on a timer, and sizes the frame to its content.
    static let script: String = #"""
    (function () {
      'use strict';
      var root = document.getElementById('ss-root');
      var state = { payload: null, cards: [], byID: {}, target: null, focusEl: null, folds: [] };
      // The "Load remote images" preference of the payload being rendered.
      var loadRemote = false;
      var prefs = { readingSans: false, noticeDismissed: false };
      // Session memory that outlives a render: measured body heights per message and width, the messages
      // shown in Original colors, and the recipient blocks the user opened (spec §4.10, §5.14).
      var heights = {};
      var originalOn = {};
      var recipientsOpen = {};
      var moving = [];
      var motionPosted = false;
      var keyboardNav = false;
      var MIN_ZOOM = 0.74;
      var SKELETON_HEIGHT = 58;
      var MOVE_MS = 180;
      var IMAGE_POLL_MS = 250;
      var FOCUS_WATCH_MS = 300;
      var IMAGE_LOAD_TIMEOUT = 20000;
      // Bodies whose images are not loaded render under this policy: nothing remote is fetched, whatever
      // the stored HTML holds (a body stored while the preference was on keeps live remote sources).
      var BLOCKING_CSP = "default-src 'none'; img-src ss-cid: data:; style-src 'unsafe-inline'; font-src ss-cid: data:";
      // Sources the policy holds back: any image not served locally, plus remote backgrounds.
      var LIVE_REMOTE = 'img[src]:not([src^="data:" i]):not([src^="ss-cid:" i]), [background^="http" i], [style*="url(http" i]';
      var ELIDE_SVG = '<svg viewBox="0 0 16 16" aria-hidden="true"><g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4.75 2.75h-2v10.5h2"/><path d="M11.25 2.75h2v10.5h-2"/></g><g fill="currentColor"><circle cx="5.6" cy="10.6" r="0.95"/><circle cx="8" cy="10.6" r="0.95"/><circle cx="10.4" cy="10.6" r="0.95"/></g></svg>';
      var NIB_SVG = '<svg viewBox="0 0 16 16" aria-hidden="true"><g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M2.91 13.09 L4.32 7.01 C4.43 6.27 4.99 5.7 5.67 5.53 L8.64 4.68 L11.32 7.36 L10.47 10.33 C10.3 11.01 9.73 11.57 8.99 11.68 Z"/><path d="M10.47 2.56 L13.44 5.53 L11.46 7.51 L8.49 4.54 Z"/><path d="M2.91 13.09 L6.66 9.34"/></g><circle cx="7.47" cy="8.53" r="0.9" fill="currentColor"/></svg>';
      var darkQuery = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null;
      var reducedQuery = window.matchMedia ? window.matchMedia('(prefers-reduced-motion: reduce)') : null;

      function post(handler, body) {
        try {
          var handlers = window.webkit && window.webkit.messageHandlers;
          var target = handlers && handlers[handler];
          if (target) { target.postMessage(body); }
        } catch (e) { /* no host: running in a plain browser */ }
      }

      function el(tag, cls, text) {
        var node = document.createElement(tag);
        if (cls) { node.className = cls; }
        if (text !== undefined && text !== null) { node.textContent = text; }
        return node;
      }

      function sym(name, cls) {
        var node = el('i', 'ss-sym ss-sym-' + name.split('.').join('-') + (cls ? ' ' + cls : ''));
        node.setAttribute('aria-hidden', 'true');
        return node;
      }

      function glyph(svg) {
        var node = el('span', 'ss-glyph');
        node.innerHTML = svg;
        return node;
      }

      function button(cls, label, title) {
        var node = el('button', cls, label);
        node.type = 'button';
        if (title) { node.title = title; }
        return node;
      }

      function kbd(legend) { return el('span', 'ss-kbd', legend); }

      function isDark() { return !!(darkQuery && darkQuery.matches); }

      function reducedMotion() {
        return document.documentElement.classList.contains('ss-rm') || !!(reducedQuery && reducedQuery.matches);
      }

      function stop(event) { event.stopPropagation(); }

      // MARK: Motion

      // The app finishes running motion before acting on a key (spec §4.10); it learns that something moves here.
      function noteMotion(node) {
        if (moving.indexOf(node) < 0) { moving.push(node); }
        if (!motionPosted) {
          motionPosted = true;
          post('ss', { kind: 'motion' });
          setTimeout(function () { motionPosted = false; }, MOVE_MS);
        }
      }

      function settled(node) {
        var i = moving.indexOf(node);
        if (i >= 0) { moving.splice(i, 1); }
      }

      function setHeight(node, px, animate) {
        var value = px + 'px';
        if (animate && !reducedMotion()) {
          if (node.style.height === value) { return; }
          node.style.transition = '';
          node.style.height = value;
          noteMotion(node);
          return;
        }
        if (node.style.height === value && node.style.transition === '') { return; }
        node.style.transition = 'none';
        node.style.height = value;
        void node.offsetHeight;
        node.style.transition = '';
        settled(node);
      }

      function finishAll() {
        var running = moving.slice();
        moving = [];
        for (var i = 0; i < state.cards.length; i++) {
          var card = state.cards[i];
          if (card.collapseTimer) { finishCollapse(card); }
        }
        for (var j = 0; j < running.length; j++) {
          var node = running[j];
          var height = node.style.height;
          node.style.transition = 'none';
          node.style.height = height;
          void node.offsetHeight;
          node.style.transition = '';
        }
      }

      // MARK: Body documents

      function htmlClasses(card) {
        var classes = [];
        var shell = document.documentElement.classList;
        if (shell.contains('ss-ic')) { classes.push('ss-ic'); }
        if (shell.contains('ss-graphite')) { classes.push('ss-graphite'); }
        if (adapts(card)) { classes.push('ss-adapt'); }
        if (showsInset(card)) { classes.push('ss-original'); }
        if (card.wide) { classes.push('ss-wide'); }
        return classes;
      }

      function bodyClasses(card) {
        var m = card.message;
        if (!card.typeset) { return ''; }
        var classes = ['ss-set'];
        if (m.isDraft) { classes.push('ss-draft'); }
        else if (prefs.readingSans || !m.coveredByNewYork) { classes.push('ss-sans'); }
        if (card.quotesShown) { classes.push('ss-show-quotes'); }
        return classes.join(' ');
      }

      function bodyDocument(card) {
        var policy = card.imagesLoaded ? '' : '<meta http-equiv="Content-Security-Policy" content="' + BLOCKING_CSP + '">';
        return '<!DOCTYPE html><html class="' + htmlClasses(card).join(' ') + '"><head><meta charset="utf-8">' + policy
          + '<meta name="color-scheme" content="light dark"><style>'
          + SS_BODY_CSS + '</style></head><body class="' + bodyClasses(card) + '">' + card.message.html + '</body></html>';
      }

      // Styled HTML that sets its own colours is adapted in dark appearances unless the user asked for the
      // sender's colours; plain and unstyled bodies already use Quire inks (spec §5.14).
      function offersOriginal(card) {
        var m = card.message;
        return isDark() && m.hasBody && m.typesetting === 'styled' && !!m.declaresColors;
      }
      function adapts(card) { return offersOriginal(card) && !originalOn[card.message.id]; }
      function showsInset(card) { return offersOriginal(card) && !!originalOn[card.message.id]; }

      function syncDocumentClasses(card) {
        var doc = frameDocument(card);
        if (!doc || !doc.documentElement) { return; }
        doc.documentElement.className = htmlClasses(card).join(' ');
        if (doc.body) {
          var quotes = !!card.quotesShown;
          doc.body.className = bodyClasses(card);
          doc.body.classList.toggle('ss-show-quotes', quotes);
        }
      }

      // Puts parked remote sources back. Runs only in a frame built without the blocking policy.
      function restoreRemote(card, doc) {
        var images = doc.querySelectorAll('img[data-ss-src]');
        for (var i = 0; i < images.length; i++) {
          var img = images[i];
          img.src = img.getAttribute('data-ss-src');
          img.removeAttribute('data-ss-src');
        }
        var backgrounds = doc.querySelectorAll('[data-ss-background]');
        for (var j = 0; j < backgrounds.length; j++) {
          backgrounds[j].setAttribute('background', backgrounds[j].getAttribute('data-ss-background'));
          backgrounds[j].removeAttribute('data-ss-background');
        }
      }

      // Counts the remote images a Load images is waiting for, so the banner can say "Loading 3 images…" and
      // then either go or report the ones that failed (spec §5.16).
      function trackImageLoad(card, doc) {
        if (!card.imageLoad || card.imageLoad.tracking) { return; }
        var remote = [];
        var failedAlready = 0;
        var images = doc.images;
        for (var i = 0; i < images.length; i++) {
          // Remote means what the blocking policy holds back: anything not served from this Mac.
          var src = images[i].getAttribute('src') || '';
          if (!src || /^(data|ss-cid):/i.test(src)) { continue; }
          // Sources live in the stored HTML load with the document, before its load event: count those that broke.
          if (!images[i].complete) { remote.push(images[i]); } else if (images[i].naturalWidth === 0) { failedAlready++; }
        }
        card.imageLoad.tracking = true;
        card.imageLoad.failed = (card.imageLoad.failed || 0) + failedAlready;
        card.imageLoad.pending = remote.length;
        // WebKit runs no event listener inside a body document, whose scripts the sandbox turns off, even one the
        // shell adds: `load` and `error` never arrive. The shell polls the images' own state instead.
        var frame = card.iframe;
        var started = Date.now();
        function poll() {
          if (!card.imageLoad || card.iframe !== frame) { return; }
          var pending = 0;
          for (var j = 0; j < remote.length; j++) { if (!remote[j].complete) { pending++; } }
          card.imageLoad.pending = pending;
          var timedOut = Date.now() - started >= IMAGE_LOAD_TIMEOUT;
          if (pending > 0 && !timedOut) {
            card.imageLoad.timer = setTimeout(poll, IMAGE_POLL_MS);
            return;
          }
          // A broken image is complete with no pixels; one still loading at the timeout counts as failed too.
          var failed = pending;
          for (var k = 0; k < remote.length; k++) { if (remote[k].complete && remote[k].naturalWidth === 0) { failed++; } }
          card.imageLoad.failed += failed;
          settleImageLoad(card);
        }
        poll();
      }

      function settleImageLoad(card) {
        if (!card.imageLoad) { return; }
        if (card.imageLoad.timer) { clearTimeout(card.imageLoad.timer); }
        card.imageFailures = card.imageLoad.failed || 0;
        card.imageLoad = null;
        renderBanners(card);
      }

      function frameDocument(card) {
        if (!card.iframe) { return null; }
        try { return card.iframe.contentDocument; } catch (e) { return null; }
      }

      // body.scrollHeight reflects content in standards mode and is independent of the frame's own
      // height, so frames can shrink again when quoted text is hidden. A zoomed body reports its laid-out
      // size, so the visible height is that times the zoom.
      function contentHeight(card, doc) {
        var body = doc.body;
        if (!body) { return 0; }
        var natural = Math.max(body.scrollHeight, body.offsetHeight);
        var zoom = card.zoom || 1;
        return Math.ceil(natural * zoom + (card.wide ? 0 : 0));
      }

      // Wide HTML (spec §5.14): a styled body wider than its frame is zoomed to fit down to 0.74, past
      // which it stays at 0.74 and scrolls sideways inside the frame. Read once per load and on refit.
      function fitWidth(card) {
        var doc = frameDocument(card);
        if (!doc || !doc.body || !doc.documentElement) { return; }
        var wasWide = card.wide;
        card.zoom = 1;
        card.wide = false;
        doc.body.style.zoom = '';
        doc.documentElement.classList.remove('ss-wide');
        if (card.typeset) { return; }
        var available = card.iframe.clientWidth;
        var natural = Math.max(doc.body.scrollWidth, doc.documentElement.scrollWidth);
        if (available > 0 && natural > available + 1) {
          var zoom = available / natural;
          if (zoom < MIN_ZOOM) {
            zoom = MIN_ZOOM;
            card.wide = true;
            doc.documentElement.classList.add('ss-wide');
          }
          card.zoom = zoom;
          doc.body.style.zoom = String(zoom);
        }
        if (wasWide !== card.wide) { card.iframe.setAttribute('scrolling', card.wide ? 'auto' : 'no'); }
      }

      function heightKey(card) {
        return card.message.id + ':' + Math.round(card.frameWrap.clientWidth);
      }

      function measure(card) {
        var doc = frameDocument(card);
        if (!doc || !doc.body) { return 0; }
        var height = contentHeight(card, doc);
        if (height > 0) {
          if (!card.measured) {
            card.measured = true;
            card.frameWrap.style.minHeight = '';
            var skeletons = card.frameWrap.querySelectorAll('.ss-skels');
            for (var i = 0; i < skeletons.length; i++) { skeletons[i].remove(); }
          }
          if (height !== card.height) {
            card.height = height;
            card.iframe.style.height = height + 'px';
          }
          heights[heightKey(card)] = height;
          refitCard(card);
        }
        return height;
      }

      // The card's px height follows its content. Called directly after every change rather than left to a
      // ResizeObserver, which never fires in a pooled view that is not on screen.
      function refitCard(card) {
        if (!card.expanded) { return; }
        var animate = card.animateFit;
        card.animateFit = false;
        fit(card, animate);
      }

      // setTimeout rather than requestAnimationFrame: a pooled view that is not on screen still has to
      // finish sizing its frames before it is swapped in.
      function scheduleMeasure(card) {
        if (card.measureTimer) { return; }
        card.measureTimer = setTimeout(function () { card.measureTimer = null; measure(card); }, 0);
      }

      function attachMeasurement(card) {
        var doc = frameDocument(card);
        if (!doc || !doc.body) { return; }
        // Only the message's own document counts; a transient about:blank says nothing about the body.
        if (doc.URL && doc.URL !== 'about:srcdoc') { return; }
        if (card.imagesLoaded) {
          restoreRemote(card, doc);
          trackImageLoad(card, doc);
        } else {
          var live = doc.querySelectorAll(LIVE_REMOTE).length;
          if (live !== card.liveRemote) { card.liveRemote = live; renderBanners(card); }
        }
        syncDocumentClasses(card);
        if (card.observer) { try { card.observer.disconnect(); } catch (e) {} card.observer = null; }
        // No listener runs inside a body document (see trackImageLoad), so images that change its size are caught
        // by a ResizeObserver, which reports to the shell, and by the timed measurements below. Link clicks are
        // the navigation policy's (ConversationNavigationPolicy), and a click making the message the target
        // is learnt from focus moving into the frame (`frameFocused`).
        try {
          if (window.ResizeObserver) {
            card.observer = new ResizeObserver(card.remeasure);
            card.observer.observe(doc.body);
          }
        } catch (e) { card.observer = null; }
        fitWidth(card);
        measure(card);
        setTimeout(card.remeasure, 50);
        setTimeout(card.remeasure, 300);
      }

      function releaseFrame(card) {
        if (card.observer) { try { card.observer.disconnect(); } catch (e) {} card.observer = null; }
        if (card.measureTimer) { clearTimeout(card.measureTimer); card.measureTimer = null; }
      }

      function dropFrame(card) {
        releaseFrame(card);
        if (card.iframe) { card.iframe.remove(); card.iframe = null; }
        card.height = 0;
        card.measured = false;
        card.zoom = 1;
        card.wide = false;
      }

      // `kind` is 'ss-delayed' for a body fetch in flight, 'ss-held' for a frame loading under its provisional height.
      function skeletons(kind) {
        var wrap = el('div', 'ss-skels ' + kind);
        wrap.appendChild(el('i', 'ss-skel'));
        wrap.appendChild(el('i', 'ss-skel'));
        wrap.appendChild(el('i', 'ss-skel'));
        return wrap;
      }

      // What stands where the body goes: the frame (inside the white inset in Original colors), the skeleton
      // while a fetch runs, or the offline preview with its notice (spec §5.14, §8.4).
      function renderFrame(card) {
        renderFrameContent(card);
        refitCard(card);
      }

      function renderFrameContent(card) {
        dropFrame(card);
        var m = card.message;
        var wrap = card.frameWrap;
        wrap.replaceChildren();
        wrap.style.minHeight = '';
        if (!m.hasBody) {
          if (m.bodyState === 'offline') {
            var preview = el('p', 'ss-preview' + (prefs.readingSans || !m.coveredByNewYork ? ' ss-sans' : ''));
            preview.textContent = (m.snippet || '').replace(/[\s.…]+$/, '') + '…';
            wrap.appendChild(preview);
            var notice = el('div', 'ss-banner');
            notice.appendChild(sym('wifi.slash'));
            notice.appendChild(el('span', 'ss-btxt', 'The full message will load when you’re back online.'));
            wrap.appendChild(notice);
          } else if (m.bodyState === 'loading') {
            wrap.appendChild(skeletons('ss-delayed'));
          } else if (m.bodyState === 'inComposer') {
            wrap.appendChild(el('p', 'ss-incomposer', 'Open in a composer window'));
          }
          return;
        }
        if (!card.expanded) { return; }
        var iframe = document.createElement('iframe');
        iframe.setAttribute('sandbox', 'allow-same-origin');
        iframe.setAttribute('scrolling', 'no');
        iframe.setAttribute('title', 'Message body');
        iframe.addEventListener('load', function () { attachMeasurement(card); });
        card.iframe = iframe;
        // srcdoc before insertion: an iframe inserted without one loads about:blank and fires `load` at once,
        // which would measure the blank page into the height cache and settle a Load images that has not run.
        iframe.srcdoc = bodyDocument(card);
        // Animate to a provisional height, then snap (spec §4.10): the last measured height at this width, or
        // the skeleton's 58 pt with the skeleton drawn in it.
        var cached = heights[heightKey(card)];
        var host = iframe;
        if (showsInset(card)) {
          host = el('div', 'ss-original');
          host.appendChild(iframe);
        }
        wrap.appendChild(host);
        if (cached) {
          wrap.style.minHeight = cached + (showsInset(card) ? 24 : 0) + 'px';
        } else {
          wrap.style.minHeight = SKELETON_HEIGHT + 'px';
          wrap.appendChild(skeletons('ss-held'));
        }
      }

      function ensureFrame(card) {
        if (card.message.hasBody && !card.iframe) { renderFrame(card); }
      }

      // MARK: Banners

      function bannerNode(variant, symbolName, words, narrow) {
        var node = el('div', 'ss-banner' + (variant ? ' ' + variant : ''));
        if (symbolName) { node.appendChild(sym(symbolName)); }
        var text = el('span', 'ss-btxt');
        if (narrow) {
          text.appendChild(el('span', 'ss-wide', words));
          text.appendChild(el('span', 'ss-narrow', narrow));
        } else {
          text.textContent = words;
        }
        node.appendChild(text);
        return node;
      }

      function plural(n, one, many) { return n + ' ' + (n === 1 ? one : many); }

      function renderBanners(card) {
        var m = card.message;
        var list = [];
        if (m.hasBody) {
          var blocked = (m.blockedRemoteImageCount || 0) + (card.liveRemote || 0);
          if (card.imageLoad) {
            var loading = bannerNode('', null, 'Loading ' + plural(card.imageLoad.total || blocked, 'image', 'images') + '…');
            loading.insertBefore(el('span', 'ss-spin'), loading.firstChild);
            list.push(loading);
          } else if (card.imageFailures > 0) {
            var failed = bannerNode('', 'exclamationmark.triangle.fill', plural(card.imageFailures, 'image', 'images') + ' couldn’t load.');
            failed.firstChild.classList.add('ss-warning');
            list.push(failed);
          } else if (blocked > 0 && !card.imagesLoaded) {
            var images = bannerNode('', 'photo',
              plural(blocked, 'remote image', 'remote images') + ' hidden to protect your privacy.',
              plural(blocked, 'remote image', 'remote images') + ' hidden.');
            var load = button('ss-link ss-load-images', 'Load images', 'Load Images  ⇧⌘I');
            load.addEventListener('click', function (event) { stop(event); loadImages(card); });
            images.appendChild(load);
            list.push(images);
          }
          if (offersOriginal(card) && !prefs.noticeDismissed) {
            var on = !!originalOn[m.id];
            var notice = bannerNode('ss-warn', 'circle.lefthalf.filled', on ? 'Showing the sender’s colours.' : 'This message uses its own colours.');
            var toggle = button('ss-na ss-notice-toggle', on ? 'Adaptive colors' : 'Original colors', on ? 'Adaptive Colors  ⇧⌘O' : 'Original Colors  ⇧⌘O');
            toggle.addEventListener('click', function (event) { stop(event); setOriginal(card, !originalOn[m.id]); });
            notice.appendChild(toggle);
            var dismiss = button('ss-bx', null, 'Don’t Show Again');
            dismiss.setAttribute('aria-label', 'Don’t show again');
            dismiss.appendChild(sym('xmark'));
            dismiss.addEventListener('click', function (event) {
              stop(event);
              post('ss', { kind: 'action', type: 'dismissColorsNotice', messageID: m.id, attachmentID: null });
              setPreferences({ readingSans: prefs.readingSans, colorsNoticeDismissed: true });
            });
            notice.appendChild(dismiss);
            list.push(notice);
          }
        } else if (m.bodyState === 'failed') {
          var bad = bannerNode('ss-bad', 'exclamationmark.triangle.fill', 'Couldn’t load this message.');
          var retry = button('ss-link', 'Retry');
          retry.addEventListener('click', function (event) {
            stop(event);
            post('ss', { kind: 'action', type: 'retryBody', messageID: m.id, attachmentID: null });
          });
          bad.appendChild(retry);
          list.push(bad);
        }
        card.banners.replaceChildren.apply(card.banners, list);
        refitCard(card);
      }

      // MARK: Invitation card (spec §5.14)

      var ANSWERS = [['accepted', 'Accept'], ['tentative', 'Tentative'], ['declined', 'Decline']];

      function inviteRow(list, label, content) {
        list.appendChild(el('dt', null, label));
        var value = el('dd');
        if (typeof content === 'string') { value.textContent = content; } else { value.appendChild(content); }
        list.appendChild(value);
      }

      function inviteLink(card, url, key) {
        var link = button('ss-ilink', url, url);
        link.dataset.ifocus = key;
        link.addEventListener('click', function (event) {
          stop(event);
          setTarget(card, true);
          post('ss', { kind: 'action', type: 'openInvitationLink', messageID: card.message.id, attachmentID: null, value: url });
        });
        return link;
      }

      function chooseAnswer(card, response) {
        var buttons = card.invite.querySelectorAll('.ss-ans');
        for (var i = 0; i < buttons.length; i++) {
          var on = buttons[i].dataset.response === response;
          buttons[i].classList.toggle('ss-chosen', on);
          buttons[i].setAttribute('aria-pressed', on ? 'true' : 'false');
        }
      }

      // The store renders the card again after an answer and when the permission notice comes or goes, which
      // rebuilds it: the control that had focus takes it again (each carries data-ifocus), or the sheet when that
      // control is gone, so a keyboard or VoiceOver user keeps their place.
      function refocusInvite(card, key) {
        var node = (key && card.invite.querySelector('[data-ifocus="' + CSS.escape(key) + '"]')) || card.element;
        try { node.focus({ preventScroll: true }); } catch (e) { node.focus(); }
      }

      function fillInvitation(card) {
        var m = card.message;
        var inv = m.invitation;
        var active = document.activeElement;
        var refocus = active && active !== card.invite && card.invite.contains(active) ? (active.dataset.ifocus || '') : null;
        if (!inv) {
          card.invite.hidden = true;
          card.invite.replaceChildren();
          card.invite.classList.remove('ss-cancelled');
          if (refocus !== null) { refocusInvite(card, null); }
          return;
        }
        card.invite.hidden = false;
        card.invite.classList.toggle('ss-cancelled', !!inv.isCancelled);
        card.invite.setAttribute('aria-label', (inv.isCancelled ? 'Cancelled event: ' : 'Invitation: ') + (inv.title || 'No title'));
        var parts = [];
        var kicker = el('div', 'ss-ikick');
        kicker.appendChild(sym(inv.isCancelled ? 'exclamationmark.triangle.fill' : 'calendar'));
        kicker.appendChild(el('span', null, inv.isCancelled ? 'Cancelled' : 'Invitation'));
        parts.push(kicker);
        parts.push(el('div', 'ss-ititle' + (inv.title ? '' : ' ss-ph'), inv.title || 'No title'));
        parts.push(el('div', 'ss-iwhen', inv.when));
        if (inv.whenElsewhere) { parts.push(el('div', 'ss-ielse', inv.whenElsewhere)); }
        if (inv.repeats) { parts.push(el('div', 'ss-irep', inv.repeats)); }
        var details = el('dl', 'ss-idet');
        if (inv.location) { inviteRow(details, 'Where', inv.locationURL ? inviteLink(card, inv.locationURL, 'where') : inv.location); }
        if (inv.conferenceURL) { inviteRow(details, inv.location ? '' : 'Where', inviteLink(card, inv.conferenceURL, 'meeting')); }
        if (inv.organizer) { inviteRow(details, 'Organizer', inv.organizer); }
        if (inv.guests) { inviteRow(details, 'Guests', inv.guests); }
        if (details.childNodes.length) { parts.push(details); }
        var actions = el('div', 'ss-iacts');
        if (inv.canAnswer && !inv.isCancelled) {
          for (var i = 0; i < ANSWERS.length; i++) {
            (function (response, label) {
              var answer = button('ss-ans', null);
              answer.dataset.response = response;
              answer.dataset.ifocus = response;
              answer.appendChild(sym('checkmark'));
              answer.appendChild(el('span', null, label));
              answer.addEventListener('click', function (event) {
                stop(event);
                setTarget(card, true);
                if (answer.classList.contains('ss-chosen')) { return; }
                chooseAnswer(card, response);
                post('ss', { kind: 'action', type: 'answerInvitation', messageID: m.id, attachmentID: null, value: response });
              });
              actions.appendChild(answer);
            })(ANSWERS[i][0], ANSWERS[i][1]);
          }
        }
        if (inv.canOpen) {
          var open = button('ss-link ss-iopen', 'Open in Calendar');
          open.dataset.ifocus = 'open';
          open.addEventListener('click', function (event) {
            stop(event);
            setTarget(card, true);
            post('ss', { kind: 'action', type: 'openInCalendar', messageID: m.id, attachmentID: null });
          });
          actions.appendChild(open);
        }
        if (actions.childNodes.length) { parts.push(actions); }
        if (inv.needsPermission) {
          var notice = bannerNode('ss-info ss-wrap', 'info.circle', 'Answer invitations: SuperSparrow needs permission to update your calendar.');
          var reconnect = button('ss-link', 'Reconnect');
          reconnect.dataset.ifocus = 'reconnect';
          reconnect.addEventListener('click', function (event) {
            stop(event);
            setTarget(card, true);
            post('ss', { kind: 'action', type: 'reconnectForInvitation', messageID: m.id, attachmentID: null });
          });
          notice.appendChild(reconnect);
          parts.push(notice);
        }
        card.invite.replaceChildren.apply(card.invite, parts);
        chooseAnswer(card, inv.response || null);
        if (refocus !== null) { refocusInvite(card, refocus); }
        refitCard(card);
      }

      // MARK: Headers

      function headerKey(m) {
        return JSON.stringify([m.from, m.to, m.cc, m.recipients, m.snippet, m.dateDisplay, m.dateISO, m.isUnread, m.isStarred, m.isDraft,
          !!m.unsubscribe]);
      }

      function nameNode(m, cls) {
        if (m.from && m.from.name) { return el('span', cls, m.from.name); }
        return el('span', cls + ' ss-ph', 'No sender');
      }

      function fillRow(card) {
        var m = card.message;
        var row = card.row;
        var pip = el('i', 'ss-rpip');
        var avatar = el('span', 'ss-av ss-av24 ss-tint-' + (m.from.tint || 0), m.from.initials || '?');
        avatar.setAttribute('aria-hidden', 'true');
        var name = nameNode(m, 'ss-rname');
        var snippet = el('span', 'ss-rsnip', m.isDraft ? 'Draft' : (m.snippet || ''));
        var date = m.isPending ? sendingDate('ss-rdate') : el('time', 'ss-rdate', m.dateDisplay);
        if (!m.isPending) { date.setAttribute('datetime', m.dateISO); }
        var parts = [pip, avatar, name, snippet];
        if (m.isStarred) { parts.push(sym('star.fill', 'ss-rstar')); }
        parts.push(date);
        row.replaceChildren.apply(row, parts);
      }

      function recipientSummary(m) {
        var text = '';
        if (m.to) { text += 'to ' + m.to; }
        if (m.cc) { text += (text ? ' · ' : '') + 'cc ' + m.cc; }
        return text;
      }

      function personNode(person, last) {
        var node = el('span', 'ss-person');
        var label = person.name || '';
        node.title = label ? label + ' <' + person.address + '>' : person.address;
        if (label) {
          node.appendChild(document.createTextNode(label + ' '));
          node.appendChild(el('span', 'ss-pad', '<' + person.address + '>' + (last ? '' : ',')));
        } else {
          node.appendChild(document.createTextNode(person.address + (last ? '' : ',')));
        }
        return node;
      }

      // The expanded recipients (spec §5.14): one block per field, each recipient whole on its line, cut at
      // twelve lines behind "and 24 more".
      function expandedRecipients(card) {
        var m = card.message;
        var block = el('div', 'ss-rcx');
        block.tabIndex = 0;
        block.setAttribute('role', 'button');
        block.setAttribute('aria-expanded', 'true');
        block.setAttribute('aria-label', 'Recipients');
        block.title = 'Hide Addresses';
        var fields = m.recipients || [];
        for (var i = 0; i < fields.length; i++) {
          var row = el('div', 'ss-rcf');
          row.appendChild(el('span', 'ss-rcl', fields[i].label));
          var value = el('span', 'ss-rcv');
          var people = fields[i].people || [];
          for (var j = 0; j < people.length; j++) { value.appendChild(personNode(people[j], j === people.length - 1)); }
          row.appendChild(value);
          block.appendChild(row);
        }
        function close(event) {
          if (event) { stop(event); }
          recipientsOpen[m.id] = false;
          card.animateFit = true;
          fillWho(card);
          var summary = card.who.querySelector('.ss-rc');
          if (summary && block === document.activeElement) { summary.focus(); }
        }
        block.addEventListener('click', close);
        block.addEventListener('keydown', function (event) {
          if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); close(event); }
        });
        return block;
      }

      function capRecipients(block) {
        var people = block.querySelectorAll('.ss-person');
        if (people.length === 0) { return; }
        var lineHeight = 15;
        var limit = block.getBoundingClientRect().top + lineHeight * 12 + 2 * 11;
        var hidden = [];
        for (var i = 0; i < people.length; i++) {
          if (people[i].getBoundingClientRect().top >= limit - 1) { hidden.push(people[i]); }
        }
        if (hidden.length === 0) { return; }
        for (var j = 0; j < hidden.length; j++) { hidden[j].style.display = 'none'; }
        var more = button('ss-more', 'and ' + hidden.length + ' more');
        more.addEventListener('click', function (event) {
          stop(event);
          for (var k = 0; k < hidden.length; k++) { hidden[k].style.display = ''; }
          more.remove();
        });
        var lastVisible = people[people.length - hidden.length - 1];
        if (lastVisible && lastVisible.parentNode) { lastVisible.parentNode.insertBefore(more, lastVisible.nextSibling); }
      }

      function fillWho(card) {
        var m = card.message;
        var who = card.who;
        var line = el('div', 'ss-nl');
        line.appendChild(el('i', 'ss-pip7'));
        line.appendChild(nameNode(m, 'ss-name'));
        if (m.isStarred) { line.appendChild(sym('star.fill', 'ss-nstar')); }
        // Before the address, which takes its place at rest without showing: after it, the link would float.
        if (m.unsubscribe) {
          var unsubscribe = button('ss-unsub', 'Unsubscribe', 'Unsubscribe  ⇧⌘U');
          unsubscribe.addEventListener('click', function (event) {
            stop(event);
            // A double-click's second click is no second request, even where the archive has already put the next
            // conversation's link under the pointer (event.detail is 0 from the keyboard, 1 for a single click).
            if (event.detail > 1) { return; }
            setTarget(card, true);
            action('unsubscribe', card);
          });
          line.appendChild(unsubscribe);
        }
        if (m.from && m.from.address && m.from.address !== m.from.name) { line.appendChild(el('span', 'ss-addr', m.from.address)); }
        var parts = [line];
        if (recipientsOpen[m.id] && (m.recipients || []).length) {
          var block = expandedRecipients(card);
          parts.push(block);
          who.replaceChildren.apply(who, parts);
          capRecipients(block);
          refitCard(card);
          return;
        }
        var summary = button('ss-rc', recipientSummary(m), 'Show Addresses');
        summary.setAttribute('aria-expanded', 'false');
        summary.setAttribute('aria-label', 'Recipients, collapsed');
        summary.addEventListener('click', function (event) {
          stop(event);
          setTarget(card, true);
          if (!(m.recipients || []).length) { return; }
          recipientsOpen[m.id] = true;
          card.animateFit = true;
          fillWho(card);
          var opened = who.querySelector('.ss-rcx');
          if (opened && keyboardNav) { opened.focus(); }
        });
        parts.push(summary);
        who.replaceChildren.apply(who, parts);
        refitCard(card);
      }

      function headerAction(symbolName, title, label, cls) {
        var node = button('ss-ib ss-hact' + (cls ? ' ' + cls : ''), null, title);
        node.setAttribute('aria-label', label);
        node.appendChild(sym(symbolName));
        return node;
      }

      // A reply still in the outbox reads “Sending…” with the 12 pt spinner where its date goes (spec §5.14).
      function sendingDate(className) {
        var date = el('span', className + ' ss-sending');
        date.appendChild(el('span', 'ss-spin'));
        date.appendChild(document.createTextNode('Sending\u2026'));
        return date;
      }

      function fillMeta(card) {
        var m = card.message;
        var actions = el('span', 'ss-hacts');
        if (m.isPending) {
          // Nothing to star, reply to or open a menu on until the provider has it.
          card.meta.replaceChildren(actions, sendingDate('ss-date'));
          return;
        }
        if (!m.isDraft) {
          var star = headerAction(m.isStarred ? 'star.fill' : 'star', m.isStarred ? 'Unstar Message' : 'Star Message',
            m.isStarred ? 'Unstar' : 'Star', m.isStarred ? 'ss-on' : '');
          star.addEventListener('click', function (event) {
            stop(event);
            setTarget(card, true);
            post('ss', { kind: 'action', type: 'star', messageID: m.id, attachmentID: null, on: !m.isStarred });
          });
          var reply = headerAction('arrowshape.turn.up.left', 'Reply  R', 'Reply');
          reply.addEventListener('click', function (event) { stop(event); setTarget(card, true); action('reply', card); });
          var more = headerAction('ellipsis', 'More', 'More');
          more.addEventListener('click', function (event) {
            stop(event);
            setTarget(card, true);
            var rect = more.getBoundingClientRect();
            post('ss', { kind: 'action', type: 'more', messageID: m.id, attachmentID: null, x: rect.left, y: rect.bottom + 2 });
          });
          actions.appendChild(star);
          actions.appendChild(reply);
          actions.appendChild(more);
          if (offersOriginal(card)) {
            var on = !!originalOn[m.id];
            var colors = headerAction('circle.lefthalf.filled', on ? 'Adaptive Colors  ⇧⌘O' : 'Original Colors  ⇧⌘O',
              on ? 'Adaptive colors' : 'Original colors', on ? 'ss-qon' : '');
            colors.setAttribute('aria-pressed', on ? 'true' : 'false');
            colors.addEventListener('click', function (event) { stop(event); setTarget(card, true); setOriginal(card, !originalOn[m.id]); });
            actions.appendChild(colors);
          }
        }
        var date = el('time', 'ss-date', m.dateDisplay);
        date.setAttribute('datetime', m.dateISO);
        date.title = m.dateISO;
        card.meta.replaceChildren(actions, date);
      }

      function fillHead(card) {
        var m = card.message;
        if (m.isDraft) {
          var head = el('div', 'ss-dhead');
          var to = recipientSummary(m).replace(/^to /, 'To ');
          head.appendChild(to ? el('span', 'ss-dto', to) : el('span', 'ss-dto ss-ph', 'No recipients yet'));
          head.appendChild(el('span', 'ss-ddate', m.dateDisplay));
          card.head.replaceWith(head);
          card.head = head;
          return;
        }
        card.avatar.className = 'ss-av ss-av36 ss-tint-' + (m.from.tint || 0);
        card.avatar.textContent = m.from.initials || '?';
        card.avatar.title = m.from.address || '';
        fillWho(card);
        fillMeta(card);
      }

      function fillHeader(card) {
        var m = card.message;
        fillRow(card);
        fillHead(card);
        card.element.classList.toggle('ss-unread', !!m.isUnread);
        card.element.classList.toggle('ss-starred', !!m.isStarred);
        card.element.setAttribute('aria-label', (m.from && m.from.name ? m.from.name : 'No sender') + ', ' + m.dateDisplay);
      }

      // MARK: Quoted text, attachments, footer

      function fillQuote(card) {
        var m = card.message;
        card.qrow.replaceChildren();
        card.qrow.style.display = m.hasBody && m.hasQuotedContent ? '' : 'none';
        if (!(m.hasBody && m.hasQuotedContent)) { refitCard(card); return; }
        var toggle = button('ss-elide ss-toggle-quote' + (card.quotesShown ? ' ss-on' : ''), null,
          card.quotesShown ? 'Hide Quoted Text  .' : 'Show Quoted Text  .');
        toggle.appendChild(glyph(ELIDE_SVG));
        toggle.appendChild(document.createTextNode(card.quotesShown ? 'Hide quoted text' : 'Show quoted text'));
        toggle.setAttribute('aria-pressed', card.quotesShown ? 'true' : 'false');
        toggle.addEventListener('click', function (event) { stop(event); setTarget(card, true); toggleQuotes(card); });
        card.qrow.appendChild(toggle);
        refitCard(card);
      }

      function chipName(name) {
        var node = el('span', 'ss-chip-name');
        // Middle truncation keeps the extension (spec §4.4): the head shrinks, the last characters never do.
        var dot = name.lastIndexOf('.');
        var keep = dot > 0 ? Math.min(name.length, (name.length - dot) + 4) : Math.min(name.length, 6);
        node.appendChild(el('span', 'ss-cb', name.slice(0, name.length - keep)));
        node.appendChild(el('span', 'ss-ce', name.slice(name.length - keep)));
        return node;
      }

      function buildChip(card, attachment, index) {
        var chip = button('ss-chip');
        chip.title = attachment.name;
        chip.tabIndex = index === 0 ? 0 : -1;
        chip.dataset.attachmentId = attachment.id;
        chip.dataset.mime = attachment.mime || '';
        var failed = !!(card.failedAttachments && card.failedAttachments[attachment.id]);
        chip.classList.toggle('ss-failed', failed);
        var tile = el('span', 'ss-tile');
        tile.appendChild(sym(failed ? 'exclamationmark.triangle.fill' : (attachment.symbol || 'doc')));
        var text = el('span', 'ss-chip-text');
        text.appendChild(chipName(attachment.name));
        var meta = el('span', 'ss-chip-meta');
        if (failed) {
          // Opening the chip again is the retry (spec §5.17).
          var rest = el('span', 'ss-rest-meta', 'Couldn’t download · ');
          rest.appendChild(el('span', 'ss-retry', 'Retry'));
          meta.appendChild(rest);
        } else {
          meta.appendChild(el('span', 'ss-rest-meta', (attachment.kind ? attachment.kind + ' · ' : '') + attachment.size));
        }
        meta.appendChild(el('span', 'ss-hover-meta', 'Space to Quick Look'));
        text.appendChild(meta);
        var download = el('span', 'ss-dl');
        download.setAttribute('aria-hidden', 'true');
        download.appendChild(el('span', 'ss-dl-fill'));
        text.appendChild(download);
        var progress = card.attachmentProgress ? card.attachmentProgress[attachment.id] : undefined;
        if (progress !== undefined && !failed) { showProgress(chip, progress); }
        chip.appendChild(tile);
        chip.appendChild(text);
        chip.addEventListener('click', function (event) {
          stop(event);
          setTarget(card, true);
          action('openAttachment', card, attachment.id);
        });
        chip.addEventListener('focus', function () {
          post('ss', { kind: 'focusAttachment', messageID: card.message.id, attachmentID: attachment.id });
        });
        // Double click opens with the default app; the context menu is the app's system menu (spec §5.17).
        chip.addEventListener('dblclick', function (event) {
          stop(event);
          action('openAttachmentWithApp', card, attachment.id);
        });
        chip.addEventListener('contextmenu', function (event) {
          event.preventDefault();
          stop(event);
          setTarget(card, true);
          post('ss', { kind: 'action', type: 'attachmentMenu', messageID: card.message.id, attachmentID: attachment.id,
                       x: event.clientX, y: event.clientY });
        });
        return chip;
      }

      function fillAttachments(card) {
        var m = card.message;
        var list = card.atts;
        var focused = document.activeElement && list.contains(document.activeElement) ? document.activeElement.dataset.attachmentId : null;
        list.replaceChildren();
        for (var i = 0; i < m.attachments.length; i++) { list.appendChild(buildChip(card, m.attachments[i], i)); }
        if (focused) {
          var again = list.querySelector('.ss-chip[data-attachment-id="' + CSS.escape(focused) + '"]');
          if (again) { again.focus(); }
        }
        refitCard(card);
      }

      // A chip's download (spec §5.17): fraction 0…1 fills the contrail, null sweeps it (size unknown), and a
      // negative value ends the download, giving the meta back. Kept per card so a rebuilt chip keeps it.
      function showProgress(chip, fraction) {
        var bar = chip.querySelector('.ss-dl');
        var fill = chip.querySelector('.ss-dl-fill');
        chip.classList.add('ss-loading');
        chip.setAttribute('aria-busy', 'true');
        if (fraction === null) {
          bar.classList.add('ss-sweep');
          fill.style.width = '';
        } else {
          bar.classList.remove('ss-sweep');
          fill.style.width = Math.round(Math.max(0, Math.min(1, fraction)) * 120) + 'px';
        }
      }

      function attachmentProgress(id, attachmentID, fraction) {
        var card = state.byID[id];
        if (!card) { return; }
        card.attachmentProgress = card.attachmentProgress || {};
        var chip = card.atts.querySelector('.ss-chip[data-attachment-id="' + CSS.escape(attachmentID) + '"]');
        if (fraction !== null && fraction < 0) {
          delete card.attachmentProgress[attachmentID];
          if (chip) { chip.classList.remove('ss-loading'); chip.removeAttribute('aria-busy'); }
          return;
        }
        card.attachmentProgress[attachmentID] = fraction;
        if (chip) { showProgress(chip, fraction); }
      }

      function attachmentFailed(id, attachmentID, failed) {
        var card = state.byID[id];
        if (!card) { return; }
        if (card.attachmentProgress) { delete card.attachmentProgress[attachmentID]; }
        card.failedAttachments = card.failedAttachments || {};
        if (!!card.failedAttachments[attachmentID] === !!failed) { return; }
        if (failed) { card.failedAttachments[attachmentID] = true; } else { delete card.failedAttachments[attachmentID]; }
        fillAttachments(card);
      }

      function footerButton(card, type, label, symbolName, key, title) {
        var node = button('ss-gb ss-' + type, null, title);
        node.appendChild(sym(symbolName));
        node.appendChild(document.createTextNode(label));
        node.addEventListener('click', function (event) {
          event.preventDefault();
          stop(event);
          setTarget(card, true);
          action(type, card, null);
        });
        return [node, kbd(key)];
      }

      function fillFooter(card) {
        var m = card.message;
        var foot = card.foot;
        var parts = [];
        if (m.isPending) {
          parts = [];
        } else if (m.isDraft) {
          var cont = button('ss-sb ss-continueDraft', null, 'Continue Editing  ↩');
          cont.appendChild(glyph(NIB_SVG));
          cont.appendChild(document.createTextNode('Continue editing'));
          cont.addEventListener('click', function (event) { stop(event); setTarget(card, true); action('continueDraft', card, null); });
          var discard = button('ss-gb ss-discardDraft', 'Discard draft…', 'Discard Draft…  #');
          discard.addEventListener('click', function (event) { stop(event); setTarget(card, true); action('discardDraft', card, null); });
          parts = [cont, kbd('↩'), discard];
        } else {
          parts = parts
            .concat(footerButton(card, 'reply', 'Reply', 'arrowshape.turn.up.left', 'R', 'Reply  R'))
            .concat(footerButton(card, 'replyAll', 'Reply all', 'arrowshape.turn.up.left.2', 'A', 'Reply All  A'))
            .concat(footerButton(card, 'forward', 'Forward', 'arrowshape.turn.up.right', 'F', 'Forward  F'));
        }
        foot.replaceChildren.apply(foot, parts);
      }

      // MARK: Cards

      function markDesign(card) {
        var m = card.message;
        card.typeset = m.hasBody && (m.typesetting === 'plain' || m.typesetting === 'unstyled');
        card.element.dataset.typesetting = m.typesetting || 'styled';
        card.element.dataset.declaresColors = m.declaresColors === false ? 'false' : 'true';
        card.element.dataset.coveredByNewYork = m.coveredByNewYork ? 'true' : 'false';
        card.element.classList.toggle('ss-typeset', card.typeset || (!m.hasBody && m.bodyState === 'offline'));
        card.element.classList.toggle('ss-draft', !!m.isDraft);
      }

      // The body itself changed (hydration replaced the snippet fallback): the frame is rebuilt, and the
      // per-frame state goes with it because it described the old document.
      function replaceBody(card) {
        card.imagesLoaded = loadRemote;
        card.liveRemote = 0;
        card.quotesShown = false;
        card.imageLoad = null;
        card.imageFailures = 0;
        markDesign(card);
        renderBanners(card);
        renderFrame(card);
        fillQuote(card);
      }

      function patch(card, m) {
        var previous = card.message;
        card.message = m;
        if (headerKey(previous) !== headerKey(m)) { fillHeader(card); }
        if (previous.html !== m.html || previous.hasBody !== m.hasBody) {
          replaceBody(card);
        } else if (previous.bodyState !== m.bodyState) {
          applyBodyState(card, m.bodyState);
        }
        if (JSON.stringify(previous.attachments) !== JSON.stringify(m.attachments)) { fillAttachments(card); }
        // A click marks its answer before the store has it; one the store refused or gave up leaves the card's facts as
        // they were, so the mark is put back to the store's answer even when nothing else changed.
        if (JSON.stringify(previous.invitation || null) !== JSON.stringify(m.invitation || null)) { fillInvitation(card); }
        else if (m.invitation) { chooseAnswer(card, m.invitation.response || null); }
      }

      function fit(card, animate) {
        if (card.collapseTimer || card.folded) { return; }
        var target = card.expanded ? Math.ceil(card.inner.getBoundingClientRect().height) : 44;
        if (target <= 0) { return; }
        setHeight(card.element, target, animate);
      }

      function buildCard(m) {
        var card = {
          message: m, element: null, row: null, inner: null, head: null, avatar: null, who: null, meta: null,
          invite: null, banners: null, frameWrap: null, qrow: null, atts: null, foot: null, iframe: null, observer: null,
          expanded: false, folded: false, imagesLoaded: loadRemote, liveRemote: 0, quotesShown: false, height: 0,
          measured: false, measureTimer: null, collapseTimer: null, imageLoad: null, imageFailures: 0, zoom: 1,
          wide: false, typeset: false, animateFit: false, sizeObserver: null
        };
        card.remeasure = function () { scheduleMeasure(card); };

        var article = el('article', 'ss-card ss-collapsed ss-strow');
        article.dataset.id = m.id;
        article.tabIndex = 0;
        // A collapsed row is a control that opens: VoiceOver says so, and expand/collapse keep it current.
        article.setAttribute('role', 'button');
        article.setAttribute('aria-expanded', 'false');
        // The conversation's context menu on the card's own chrome (spec §5.35). A body lives in its own frame,
        // where the system's text menu stays for Copy and links; a chip has its own menu and stops the event.
        article.addEventListener('contextmenu', function (event) {
          if (event.defaultPrevented) { return; }
          event.preventDefault();
          setTarget(card, true);
          post('ss', { kind: 'action', type: 'messageMenu', messageID: m.id, attachmentID: null,
                       x: event.clientX, y: event.clientY });
        });
        var row = el('div', 'ss-row');
        var inner = el('div', 'ss-inner');
        var head = el('header', 'ss-head');
        var avatar = el('span', 'ss-av ss-av36');
        avatar.setAttribute('aria-hidden', 'true');
        var who = el('div', 'ss-who');
        var meta = el('div', 'ss-meta');
        head.appendChild(avatar);
        head.appendChild(who);
        head.appendChild(meta);
        var invite = el('section', 'ss-invite');
        invite.setAttribute('role', 'group');
        invite.hidden = true;
        var body = el('div', 'ss-body');
        var banners = el('div', 'ss-banners');
        var frameWrap = el('div', 'ss-frame');
        body.appendChild(banners);
        body.appendChild(frameWrap);
        var qrow = el('div', 'ss-qrow ss-ind');
        var atts = el('div', 'ss-atts ss-ind');
        var foot = el('footer', 'ss-foot ss-ind');
        inner.appendChild(head);
        inner.appendChild(invite);
        inner.appendChild(body);
        inner.appendChild(qrow);
        inner.appendChild(atts);
        inner.appendChild(foot);
        article.appendChild(row);
        article.appendChild(inner);

        row.addEventListener('click', function (event) {
          stop(event);
          setTarget(card, true);
          expand(card, true);
        });
        inner.addEventListener('click', function () { setTarget(card, true); });
        article.addEventListener('focus', function () {
          setTarget(card, true);
          if (keyboardNav) { showFocusRing(article); }
        });
        article.addEventListener('keydown', function (event) {
          if (event.target !== article) { return; }
          if ((event.key === 'Enter') && !card.expanded) { event.preventDefault(); expand(card, true); }
        });
        atts.addEventListener('keydown', function (event) {
          if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') { return; }
          var chips = Array.prototype.slice.call(atts.querySelectorAll('.ss-chip'));
          var i = chips.indexOf(document.activeElement);
          if (i < 0) { return; }
          event.preventDefault();
          var next = chips[Math.max(0, Math.min(chips.length - 1, i + (event.key === 'ArrowRight' ? 1 : -1)))];
          for (var c = 0; c < chips.length; c++) { chips[c].tabIndex = chips[c] === next ? 0 : -1; }
          next.focus();
        });

        card.element = article;
        card.row = row;
        card.inner = inner;
        card.head = head;
        card.avatar = avatar;
        card.who = who;
        card.meta = meta;
        card.invite = invite;
        card.banners = banners;
        card.frameWrap = frameWrap;
        card.qrow = qrow;
        card.atts = atts;
        card.foot = foot;
        markDesign(card);
        fillHeader(card);
        fillInvitation(card);
        renderBanners(card);
        fillQuote(card);
        fillAttachments(card);
        fillFooter(card);
        if (!m.hasBody) { renderFrame(card); }
        try {
          if (window.ResizeObserver) {
            card.sizeObserver = new ResizeObserver(function () {
              var animate = card.animateFit;
              card.animateFit = false;
              fit(card, animate);
            });
            card.sizeObserver.observe(inner);
          }
        } catch (e) { card.sizeObserver = null; }
        return card;
      }

      // MARK: Expand and collapse (spec §4.10)

      function expand(card, animate) {
        if (card.expanded) { return; }
        if (card.folded) { unfoldAll(); }
        if (card.collapseTimer) { clearTimeout(card.collapseTimer); card.collapseTimer = null; }
        // Only an animated expand needs where it starts from; reading it forces a layout, which a render of
        // several open messages should not pay once per message.
        var start = animate ? (card.element.getBoundingClientRect().height || 44) : 0;
        card.expanded = true;
        card.element.classList.remove('ss-collapsed', 'ss-strow', 'ss-run-start', 'ss-run-end');
        card.element.classList.add('ss-sheet');
        // Open, the sheet is content again, not a button.
        card.element.removeAttribute('role');
        card.element.setAttribute('aria-expanded', 'true');
        ensureFrame(card);
        restack();
        if (animate) {
          card.element.style.transition = 'none';
          card.element.style.height = start + 'px';
          void card.element.offsetHeight;
          card.element.style.transition = '';
        }
        fit(card, animate);
      }

      function collapse(card, animate) {
        if (!card.expanded) { return; }
        card.expanded = false;
        if (animate && !reducedMotion()) {
          setHeight(card.element, 44, true);
          card.collapseTimer = setTimeout(function () { finishCollapse(card); }, MOVE_MS + 40);
        } else {
          finishCollapse(card);
        }
      }

      function finishCollapse(card) {
        if (card.collapseTimer) { clearTimeout(card.collapseTimer); card.collapseTimer = null; }
        if (card.expanded) { return; }
        card.element.classList.remove('ss-sheet');
        card.element.classList.add('ss-collapsed', 'ss-strow');
        card.element.setAttribute('role', 'button');
        card.element.setAttribute('aria-expanded', 'false');
        dropFrame(card);
        if (card.message.hasBody) { card.frameWrap.replaceChildren(); }
        setHeight(card.element, 44, false);
        restack();
      }

      function toggle(card) {
        if (card.expanded) { collapse(card, true); } else { expand(card, true); }
      }

      // Collapsed rows between sheets form one stack: the classes give each run its rounded ends (spec §5.13).
      function restack() {
        var prev = null;
        var prevIsRow = false;
        var expanded = 0;
        var children = root.children;
        for (var i = 0; i < children.length; i++) {
          var child = children[i];
          if (child.classList.contains('ss-folded') || child.classList.contains('ss-parts')) { continue; }
          var isRow = child.classList.contains('ss-strow');
          if (child.classList.contains('ss-sheet')) { expanded++; }
          child.classList.toggle('ss-run-start', isRow && !prevIsRow);
          if (prev) { prev.classList.toggle('ss-run-end', prevIsRow && !isRow); }
          prev = child;
          prevIsRow = isRow;
        }
        if (prev) { prev.classList.toggle('ss-run-end', prevIsRow); }
        root.classList.toggle('ss-multi', expanded > 1);
      }

      // More than six collapsed messages in a run keep the first one and the last two and fold the rest into
      // one "4 more messages" row, until the conversation is reopened (spec §5.13).
      function foldRuns() {
        var run = [];
        function flush() {
          if (run.length > 6) {
            var hidden = run.slice(1, run.length - 2);
            var fold = el('div', 'ss-fold ss-strow', hidden.length + ' more messages');
            fold.tabIndex = 0;
            fold.setAttribute('role', 'button');
            for (var i = 0; i < hidden.length; i++) {
              hidden[i].folded = true;
              hidden[i].element.classList.add('ss-folded');
            }
            root.insertBefore(fold, run[0].element.nextSibling);
            var entry = { element: fold, cards: hidden };
            state.folds.push(entry);
            fold.addEventListener('click', function (event) { stop(event); unfold(entry, true); });
            fold.addEventListener('keydown', function (event) {
              if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); unfold(entry, true); }
            });
            fold.addEventListener('focus', function () { if (keyboardNav) { showFocusRing(fold); } });
          }
          run = [];
        }
        for (var c = 0; c < state.cards.length; c++) {
          if (state.cards[c].expanded) { flush(); } else { run.push(state.cards[c]); }
        }
        flush();
      }

      function unfold(entry, animate) {
        var index = state.folds.indexOf(entry);
        if (index < 0) { return; }
        state.folds.splice(index, 1);
        var hadFocus = entry.element === state.focusEl;
        entry.element.remove();
        for (var i = 0; i < entry.cards.length; i++) {
          var card = entry.cards[i];
          card.folded = false;
          card.element.classList.remove('ss-folded');
          if (animate && !reducedMotion()) {
            card.element.style.transition = 'none';
            card.element.style.height = '0px';
            void card.element.offsetHeight;
            card.element.style.transition = '';
            setHeight(card.element, 44, true);
          } else {
            setHeight(card.element, 44, false);
          }
        }
        restack();
        if (entry.cards.length && (hadFocus || animate)) {
          var first = entry.cards[0];
          if (hadFocus) { focusStop(first.element); } else { setTarget(first, true); }
        }
      }

      function unfoldAll() {
        while (state.folds.length) { unfold(state.folds[0], false); }
      }

      // MARK: Target and focus (spec §5.14)

      function setTarget(card, notify) {
        if (!card || state.target === card) { return; }
        if (state.target) { state.target.element.classList.remove('ss-target'); }
        state.target = card;
        card.element.classList.add('ss-target');
        if (notify) { post('ss', { kind: 'select', messageID: card.message.id }); }
      }

      function clearFocusRing() {
        if (state.focusEl) { state.focusEl.classList.remove('ss-focus'); }
        state.focusEl = null;
      }

      function showFocusRing(node) {
        clearFocusRing();
        state.focusEl = node;
        node.classList.add('ss-focus');
      }

      function cardForElement(node) {
        for (var i = 0; i < state.cards.length; i++) { if (state.cards[i].element === node) { return state.cards[i]; } }
        return null;
      }

      function stops() {
        var list = [];
        var children = root.children;
        for (var i = 0; i < children.length; i++) {
          var child = children[i];
          if (child.classList.contains('ss-folded')) { continue; }
          if (child.classList.contains('ss-card') || child.classList.contains('ss-fold')) { list.push(child); }
        }
        return list;
      }

      function focusStop(node) {
        keyboardNav = true;
        showFocusRing(node);
        var card = cardForElement(node);
        if (card) { setTarget(card, true); }
        try { node.focus({ preventScroll: true }); } catch (e) { node.focus(); }
        node.scrollIntoView({ block: 'nearest' });
      }

      // N and P: the next or previous stack row, fold row or sheet takes the ring and becomes the target.
      function step(delta) {
        var list = stops();
        if (list.length === 0) { return null; }
        var current = state.focusEl || (state.target && state.target.element);
        var i = list.indexOf(current);
        var next = i < 0 ? (delta > 0 ? 0 : list.length - 1) : Math.max(0, Math.min(list.length - 1, i + delta));
        focusStop(list[next]);
        return state.target ? state.target.message.id : null;
      }

      function action(type, card, attachmentID) {
        post('ss', { kind: 'action', type: type, messageID: card.message.id, attachmentID: attachmentID || null });
      }

      // MARK: Commands

      // The blocking policy of a document cannot be lifted, so the frame is rebuilt without it; parked
      // sources are restored once the new document has loaded.
      function loadImages(card) {
        if (!card || card.imagesLoaded) { return; }
        var blocked = (card.message.blockedRemoteImageCount || 0) + (card.liveRemote || 0);
        card.imagesLoaded = true;
        card.imageFailures = 0;
        card.imageLoad = blocked > 0 ? { total: blocked, failed: 0, pending: blocked, tracking: false, timer: null } : null;
        renderBanners(card);
        if (card.expanded) { renderFrame(card); } else { expand(card, true); }
      }

      function toggleQuotes(card) {
        if (!card || !card.message.hasQuotedContent) { return; }
        card.quotesShown = !card.quotesShown;
        fillQuote(card);
        var doc = frameDocument(card);
        if (doc && doc.body) {
          doc.body.classList.toggle('ss-show-quotes', card.quotesShown);
          card.animateFit = true;
          measure(card);
        }
      }

      function setOriginal(card, on) {
        if (!card) { return; }
        if (on) { originalOn[card.message.id] = true; } else { delete originalOn[card.message.id]; }
        renderBanners(card);
        fillMeta(card);
        if (card.expanded && card.message.hasBody) { renderFrame(card); }
        post('ss', { kind: 'originalColors', messageID: card.message.id, on: !!on });
      }

      function applyBodyState(card, bodyState) {
        card.message = Object.assign({}, card.message, { bodyState: bodyState });
        if (card.message.hasBody) { return; }
        markDesign(card);
        renderBanners(card);
        renderFrame(card);
      }

      // `readingSans` is the app's Font setting (spec §4.4): bodies take `readingSans` and the shell's own New
      // York (the avatar initials) its sans twin through the root class.
      function applyTypeface() {
        document.documentElement.classList.toggle('ss-sf', prefs.readingSans);
      }

      function setPreferences(p) {
        var sansChanged = !!p.readingSans !== prefs.readingSans;
        var noticeChanged = !!p.colorsNoticeDismissed !== prefs.noticeDismissed;
        prefs.readingSans = !!p.readingSans;
        prefs.noticeDismissed = !!p.colorsNoticeDismissed;
        applyTypeface();
        for (var i = 0; i < state.cards.length; i++) {
          var card = state.cards[i];
          if (sansChanged) {
            syncDocumentClasses(card);
            if (!card.message.hasBody) { renderFrame(card); }
          }
          if (noticeChanged) { renderBanners(card); }
        }
      }

      // The app mirrors Increase Contrast, Reduce Motion, Reduce Transparency and Graphite onto the shell and
      // every body document, because WebKit does not reliably track the media queries (spec §3.3, §8.4).
      function setModes(modes) {
        var shell = document.documentElement.classList;
        shell.toggle('ss-ic', !!modes.ic);
        shell.toggle('ss-rm', !!modes.rm);
        shell.toggle('ss-rt', !!modes.rt);
        shell.toggle('ss-graphite', !!modes.graphite);
        for (var i = 0; i < state.cards.length; i++) { syncDocumentClasses(state.cards[i]); }
      }

      function appearanceChanged() {
        for (var i = 0; i < state.cards.length; i++) {
          var card = state.cards[i];
          var hadInset = !!(card.frameWrap.querySelector('.ss-original'));
          renderBanners(card);
          if (!card.message.isDraft) { fillMeta(card); }
          if (card.expanded && card.message.hasBody && hadInset !== showsInset(card)) {
            renderFrame(card);
          } else {
            syncDocumentClasses(card);
          }
        }
      }
      if (darkQuery) {
        if (darkQuery.addEventListener) { darkQuery.addEventListener('change', appearanceChanged); }
        else if (darkQuery.addListener) { darkQuery.addListener(appearanceChanged); }
      }

      function refit() {
        for (var i = 0; i < state.cards.length; i++) {
          var card = state.cards[i];
          if (!card.iframe) { continue; }
          fitWidth(card);
          measure(card);
        }
      }

      // MARK: Rendering

      function teardown() {
        for (var i = 0; i < state.cards.length; i++) {
          var card = state.cards[i];
          releaseFrame(card);
          if (card.collapseTimer) { clearTimeout(card.collapseTimer); }
          if (card.sizeObserver) { try { card.sizeObserver.disconnect(); } catch (e) {} }
          if (card.imageLoad && card.imageLoad.timer) { clearTimeout(card.imageLoad.timer); }
        }
        state.cards = [];
        state.byID = {};
        state.target = null;
        state.focusEl = null;
        state.folds = [];
        state.payload = null;
        moving = [];
      }

      function readPayloadSettings(payload) {
        loadRemote = !!payload.loadRemoteImages;
        prefs.readingSans = !!payload.readingSans;
        prefs.noticeDismissed = !!payload.colorsNoticeDismissed;
        applyTypeface();
        root.dataset.inkSlot = String(payload.inkSlot || 0);
        document.title = payload.subject || '';
      }

      function participantsNode(payload) {
        var node = el('div', 'ss-parts', payload.participants || '');
        node.style.display = payload.participants ? '' : 'none';
        return node;
      }

      function render(payload) {
        teardown();
        state.payload = payload;
        readPayloadSettings(payload);
        var messages = payload.messages || [];
        var fragment = document.createDocumentFragment();
        fragment.appendChild(participantsNode(payload));
        for (var i = 0; i < messages.length; i++) {
          var card = buildCard(messages[i]);
          state.cards.push(card);
          state.byID[card.message.id] = card;
          fragment.appendChild(card.element);
        }
        root.replaceChildren(fragment);
        var lastExpanded = null;
        var firstExpanded = null;
        for (var j = 0; j < state.cards.length; j++) {
          var c = state.cards[j];
          if (j === state.cards.length - 1 || c.message.isUnread || c.message.isDraft) {
            expand(c, false);
            if (!firstExpanded) { firstExpanded = c; }
            lastExpanded = c;
          }
        }
        foldRuns();
        restack();
        if (lastExpanded) { setTarget(lastExpanded, true); }
        window.scrollTo(0, 0);
        if (firstExpanded && firstExpanded !== state.cards[0]) {
          firstExpanded.element.scrollIntoView({ block: 'start' });
        }
        return state.cards.length;
      }

      function sameList(a, b) {
        if (a.length !== b.length) { return false; }
        for (var i = 0; i < a.length; i++) { if (a[i] !== b[i]) { return false; } }
        return true;
      }

      // Patches the cards in place so what the reader is looking at survives a store change: expansion,
      // scroll position, loaded images and shown quotes all stay, and only what changed is touched. New
      // messages are inserted around the survivors; a reorder of survivors falls back to a full render,
      // because moving an iframe in the DOM reloads it.
      function update(payload) {
        var messages = payload.messages || [];
        if (!state.payload || state.cards.length === 0 || messages.length === 0) { return render(payload); }
        if (!!payload.loadRemoteImages !== loadRemote) { return render(payload); }
        readPayloadSettings(payload);
        var parts = root.querySelector('.ss-parts');
        if (parts) {
          parts.textContent = payload.participants || '';
          parts.style.display = payload.participants ? '' : 'none';
        }
        var incoming = {};
        for (var i = 0; i < messages.length; i++) { incoming[messages[i].id] = messages[i]; }
        var surviving = [];
        for (var j = 0; j < state.cards.length; j++) {
          var id = state.cards[j].message.id;
          if (incoming[id]) { surviving.push(id); }
        }
        var kept = [];
        for (var k = 0; k < messages.length; k++) {
          if (state.byID[messages[k].id]) { kept.push(messages[k].id); }
        }
        if (!sameList(surviving, kept)) { return render(payload); }
        // A fold row stands for particular cards; once cards come or go it would miscount, so it opens.
        if (surviving.length !== state.cards.length || kept.length !== messages.length) { unfoldAll(); }
        for (var r = 0; r < state.cards.length; r++) {
          var gone = state.cards[r];
          if (incoming[gone.message.id]) { continue; }
          releaseFrame(gone);
          if (gone.sizeObserver) { try { gone.sizeObserver.disconnect(); } catch (e) {} }
          gone.element.remove();
          if (state.target === gone) { state.target = null; }
          if (state.focusEl === gone.element) { state.focusEl = null; }
        }
        var cards = [];
        var byID = {};
        var next = null;
        var added = [];
        for (var n = messages.length - 1; n >= 0; n--) {
          var m = messages[n];
          var card = state.byID[m.id];
          if (card) {
            patch(card, m);
          } else {
            card = buildCard(m);
            root.insertBefore(card.element, next);
            added.push({ card: card, expand: m.isUnread || n === messages.length - 1 || m.isDraft });
          }
          cards.push(card);
          byID[m.id] = card;
          next = card.element;
        }
        cards.reverse();
        state.cards = cards;
        state.byID = byID;
        state.payload = payload;
        for (var a = 0; a < added.length; a++) { if (added[a].expand) { expand(added[a].card, false); } }
        restack();
        if (!state.target) { setTarget(cards[cards.length - 1], false); }
        return cards.length;
      }

      // Read and star changes patch the headers only; the bodies, and the frames showing them, stay put.
      function flags(patches) {
        var patched = 0;
        for (var i = 0; i < patches.length; i++) {
          var p = patches[i];
          var card = state.byID[p.id];
          if (!card) { continue; }
          var m = Object.assign({}, card.message, { isUnread: p.isUnread, isStarred: p.isStarred });
          var previous = card.message;
          card.message = m;
          if (headerKey(previous) !== headerKey(m)) { fillHeader(card); }
          patched++;
        }
        return patched;
      }

      function bodyStates(patches) {
        var patched = 0;
        for (var i = 0; i < patches.length; i++) {
          var card = state.byID[patches[i].id];
          if (!card || card.message.hasBody || card.message.bodyState === patches[i].bodyState) { continue; }
          applyBodyState(card, patches[i].bodyState);
          patched++;
        }
        return patched;
      }

      function clear() {
        teardown();
        document.title = '';
        root.replaceChildren();
      }

      document.addEventListener('keydown', function () { keyboardNav = true; }, true);
      // A click (or Tab) into a body moves focus into its frame and away from the shell. Listeners inside the
      // sandboxed body never run, so this is how the click makes that message the target (spec §5.14).
      // Focus can also move from one body straight into another, which the shell hears nothing of: while it is
      // inside a body the shell looks again every FOCUS_WATCH_MS, and stops once it has left. Only a page with focus
      // can move it, so the shell also stops once the page loses focus (another window or app, the list), where the
      // body stays the active element; the app calls `focusChanged` when the page may have focus again.
      var focusWatch = null;
      function frameFocused() {
        var active = document.activeElement;
        var inBody = !!active && active.tagName === 'IFRAME';
        if (inBody && document.hasFocus()) {
          if (!focusWatch) { focusWatch = setInterval(frameFocused, FOCUS_WATCH_MS); }
        } else if (focusWatch) {
          clearInterval(focusWatch);
          focusWatch = null;
        }
        if (!inBody) { return; }
        for (var i = 0; i < state.cards.length; i++) {
          var card = state.cards[i];
          if (card.iframe === active) {
            if (state.target === card) { return; }
            if (!keyboardNav) { clearFocusRing(); }
            setTarget(card, true);
            return;
          }
        }
      }
      window.addEventListener('blur', function () { setTimeout(frameFocused, 0); });
      // The window became key or the web view first responder. Focus going back to a body raises no event here, and
      // WebKit may not have told the page yet, so the shell looks one watch interval later and goes on only then.
      function focusChanged() {
        if (!focusWatch) { focusWatch = setInterval(frameFocused, FOCUS_WATCH_MS); }
      }
      document.addEventListener('mousedown', function () { keyboardNav = false; clearFocusRing(); }, true);
      document.addEventListener('transitionend', function (event) {
        if (event.propertyName === 'height') { settled(event.target); }
      });
      window.addEventListener('resize', function () {
        for (var i = 0; i < state.cards.length; i++) { scheduleMeasure(state.cards[i]); }
      });

      function targetCard() { return state.target; }

      window.ss = {
        version: 3,
        render: render,
        update: update,
        flags: flags,
        bodyStates: bodyStates,
        clear: clear,
        setBottomInset: function (px) {
          document.documentElement.style.setProperty('--ss-inset', Math.max(0, Math.round(px)) + 'px');
        },
        setModes: setModes,
        preferences: setPreferences,
        refit: refit,
        finishAll: finishAll,
        step: step,
        target: function (id) { var card = state.byID[id]; if (card) { setTarget(card, false); } },
        focusChanged: focusChanged,
        targetState: function () {
          var card = targetCard();
          if (!card) { return null; }
          var m = card.message;
          return {
            id: m.id, offersOriginal: offersOriginal(card), original: !!originalOn[m.id],
            imagesBlocked: m.hasBody && !card.imagesLoaded && ((m.blockedRemoteImageCount || 0) + (card.liveRemote || 0)) > 0,
            hasQuotes: !!(m.hasBody && m.hasQuotedContent), quotesShown: !!card.quotesShown, isStarred: !!m.isStarred
          };
        },
        toggleQuotes: function () { toggleQuotes(targetCard()); },
        toggleOriginal: function () {
          var card = targetCard();
          if (!card || !offersOriginal(card)) { return null; }
          setOriginal(card, !originalOn[card.message.id]);
          return !!originalOn[card.message.id];
        },
        originalColors: function (id, on) { setOriginal(state.byID[id], !!on); },
        cardCount: function () { return state.cards.length; },
        cardStates: function () {
          var states = [];
          for (var i = 0; i < state.cards.length; i++) {
            var card = state.cards[i];
            states.push({
              id: card.message.id, expanded: card.expanded, imagesLoaded: card.imagesLoaded,
              quotesShown: card.quotesShown, hasFrame: !!card.iframe, folded: card.folded
            });
          }
          return states;
        },
        measureAll: function () {
          var heights = [];
          for (var i = 0; i < state.cards.length; i++) { heights.push(measure(state.cards[i])); }
          return heights;
        },
        iframeHeights: function () {
          var list = [];
          for (var i = 0; i < state.cards.length; i++) {
            var card = state.cards[i];
            list.push(card.iframe ? (parseFloat(card.iframe.style.height) || 0) : -1);
          }
          return list;
        },
        expandAll: function () {
          for (var i = 0; i < state.cards.length; i++) { expand(state.cards[i], false); }
        },
        toggle: function (id) { var card = state.byID[id]; if (card) { toggle(card); } },
        select: function (id) { var card = state.byID[id]; if (card) { setTarget(card, true); } },
        selectedMessageID: function () { return state.target ? state.target.message.id : null; },
        loadImages: function (id) { loadImages(id ? state.byID[id] : targetCard()); },
        attachmentFailed: attachmentFailed,
        attachmentProgress: attachmentProgress
      };

      post('ssReady', { kind: 'ready' });
      post('ss', { kind: 'ready' });
    })();
    """#

    /// A JavaScript string literal for arbitrary text (JSON string escaping is a subset of JS).
    public static func jsStringLiteral(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "<": out += "\\u003c"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
