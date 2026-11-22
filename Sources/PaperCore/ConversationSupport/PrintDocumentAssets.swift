import Foundation

/// The print document's stylesheet and script (spec §5.48), beside `QuireCSS.head`, which gives them every Quire
/// variable. Metrics are the reader's (`layout.reader`, `layout.invitation`) and `layout.print`; colours are Quire's light
/// inks, since the web view that prints is Aqua whatever the app's appearance.
enum PrintDocumentAssets {
    /// The reader's policy for a body whose images are not loaded (the shell's `BLOCKING_CSP`): nothing remote, only
    /// inline images and fonts. A test holds the two equal.
    static let blockingPolicy = "default-src 'none'; img-src ss-cid: data:; style-src 'unsafe-inline'; font-src ss-cid: data:"

    /// The page's own policy, from its first byte: no script runs but the document's own, the one carrying `nonce`.
    ///
    /// In the reader each body is a document of its own in a frame whose sandbox runs no script; on paper every body is in
    /// this one page, beside the script that attaches them and the handler it reports to, so a script or event handler
    /// that got past the sanitizer would run here with every other message in reach. Inline handlers, `javascript:` URLs
    /// and script elements without the nonce are refused; images, styles and fonts are left to the reader's policies,
    /// the blocking one added for the held-back bodies (`script`).
    static func scriptPolicy(nonce: String) -> String {
        "script-src 'nonce-" + nonce + "'; object-src 'none'"
    }

    /// The elision mark's glyph (`paper.elide`), exactly as the shell draws it, for the lines that stand where the reader
    /// folds something away. A test holds it to the shell's.
    static let elideSVG = #"<svg viewBox="0 0 16 16" aria-hidden="true"><g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4.75 2.75h-2v10.5h2"/><path d="M11.25 2.75h2v10.5h-2"/></g><g fill="currentColor"><circle cx="5.6" cy="10.6" r="0.95"/><circle cx="8" cy="10.6" r="0.95"/><circle cx="10.4" cy="10.6" r="0.95"/></g></svg>"#

    /// The page: the paper is the sheet, so there is no desk, no edge and no shadow; a hairline separates the messages.
    /// Backgrounds print (avatars, a newsletter's bands), as the reader shows them.
    static let css: String = #"""
    * { box-sizing: border-box; }
    /* `html:root`, not `html`: it must outrank the `:root { color-scheme: light dark }` of the Quire head above it. */
    html:root { color-scheme: light; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
    html, body { margin: 0; padding: 0; background: transparent; color: var(--q-ink); }
    body { font: var(--q-font-body); letter-spacing: var(--q-track-body); }
    .ss-ph { font-style: italic; font-weight: 400; color: var(--q-ink3); }

    /* The masthead: the subject as the reader header's headline, then who took part and how many messages. */
    .ss-psubject { margin: 0; font: var(--q-font-headline); letter-spacing: var(--q-track-headline); color: var(--q-ink); overflow-wrap: anywhere; }
    html.ss-sf .ss-psubject { font: var(--q-font-headlineSans); letter-spacing: var(--q-track-headlineSans); }
    .ss-psubject.ss-ph { color: var(--q-ink3); }
    .ss-pparts { margin: 6px 0 0; font: var(--q-font-snippet); letter-spacing: var(--q-track-snippet); color: var(--q-ink2); }

    /* One sheet per message (layout.print.messageGap above and below its rule). */
    .ss-pmsg { margin-top: 24px; padding-top: 24px; border-top: 1px solid var(--q-rule); }
    .ss-phead { display: flex; gap: 12px; align-items: flex-start; break-inside: avoid; break-after: avoid; }
    .ss-pwho { flex: 1; min-width: 0; }
    .ss-pnl { font: var(--q-font-bodyStrong); letter-spacing: var(--q-track-bodyStrong); color: var(--q-ink); overflow-wrap: anywhere; }
    .ss-paddr { margin-left: 6px; font: var(--q-font-meta); letter-spacing: var(--q-track-meta); color: var(--q-ink3); }
    .ss-prcpt { display: flex; margin-top: 2px; font: var(--q-font-snippet); letter-spacing: var(--q-track-snippet); color: var(--q-ink2); }
    .ss-plabel { flex: none; width: 28px; color: var(--q-ink3); }
    .ss-ppeople { flex: 1; min-width: 0; }
    .ss-pperson { display: inline-block; max-width: 100%; overflow-wrap: anywhere; }
    .ss-pad { color: var(--q-ink3); }
    .ss-pdate { flex: none; font: var(--q-font-snippet); letter-spacing: var(--q-track-snippet); font-variant-numeric: tabular-nums; color: var(--q-ink3); }

    /* The indent: plain and unstyled bodies, the card, the notes and the attachments sit at the name column. */
    .ss-pind { margin-left: 48px; }
    /* A body's own containing block, formatting context and paint scope, as its frame is in the reader: what it positions
       absolutely, floats or lifts with a z-index or a negative margin stays in its sheet and never lands on the masthead
       or another message's header. Clipped top and bottom only, so a newsletter wider than the paper still shrinks to
       fit; what a body places beyond the end of its own flow is cut there (the reader's frame would grow to it), the
       price of no message drawing over another. */
    .ss-pbody { margin-top: 18px; display: flow-root; position: relative; isolation: isolate; overflow-y: clip; }
    .ss-ppreview { margin-top: 18px; margin-bottom: 0; max-width: 576px; font: var(--q-font-reading); letter-spacing: var(--q-track-reading); color: var(--q-ink2); }
    .ss-ppreview.ss-sans { font: var(--q-font-readingSans); letter-spacing: var(--q-track-readingSans); }
    .ss-pnote {
      display: flex; align-items: center; gap: 6px; margin-top: 12px; margin-bottom: 0; break-inside: avoid;
      font: var(--q-font-meta); letter-spacing: var(--q-track-meta); color: var(--q-ink3);
    }
    .ss-pnote svg { flex: none; width: 14px; height: 14px; }
    .ss-patts { list-style: none; margin-top: 16px; margin-bottom: 0; padding: 0; font: var(--q-font-snippet); letter-spacing: var(--q-track-snippet); color: var(--q-ink); }
    .ss-patts li { break-inside: avoid; overflow-wrap: anywhere; }
    .ss-patts li + li { margin-top: 2px; }
    .ss-pattmeta { margin-left: 6px; color: var(--q-ink3); }

    /* The invitation card (spec §5.14, layout.invitation) without its buttons: the answer is written in its list. */
    .ss-pinvite { margin-top: 18px; max-width: 576px; padding: 12px 16px; border: 1px solid var(--q-rule); border-radius: var(--q-r-lg); break-inside: avoid; }
    .ss-pikick { font: var(--q-font-runningHead); letter-spacing: var(--q-track-runningHead); color: var(--q-ink3); }
    .ss-pinvite.ss-cancelled .ss-pikick { color: var(--q-danger); }
    .ss-pititle { margin-top: 6px; font: var(--q-font-title); letter-spacing: var(--q-track-title); color: var(--q-ink); overflow-wrap: anywhere; }
    .ss-pinvite.ss-cancelled .ss-pititle { color: var(--q-ink2); text-decoration: line-through; text-decoration-thickness: 1px; }
    .ss-piwhen { margin-top: 2px; font: var(--q-font-body); letter-spacing: var(--q-track-body); color: var(--q-ink); }
    .ss-pielse { font: var(--q-font-snippet); letter-spacing: var(--q-track-snippet); color: var(--q-ink3); }
    .ss-pirep { margin-top: 2px; font: var(--q-font-snippet); letter-spacing: var(--q-track-snippet); color: var(--q-ink2); }
    .ss-pidet {
      margin: 8px 0 0; display: grid; grid-template-columns: 72px minmax(0, 1fr); row-gap: 2px;
      font: var(--q-font-snippet); letter-spacing: var(--q-track-snippet); line-height: 16px;
    }
    .ss-pidet dt { color: var(--q-ink3); }
    .ss-pidet dd { margin: 0; color: var(--q-ink2); overflow-wrap: anywhere; }

    /* Avatars: initials on the eight soft tints (spec §4.3), as the sheet header draws them. */
    .ss-av {
      flex: none; border-radius: 50%; display: inline-flex; align-items: center; justify-content: center;
      font-family: var(--q-serif); font-weight: 600; background: var(--ss-face); color: var(--ss-avink);
    }
    .ss-av36 { width: 36px; height: 36px; font-size: 15px; line-height: 36px; }
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
    """#

    /// Each body's own stylesheet, in its shadow root: the reader's body CSS (`ConversationShellAssets.bodyCSS`) for a
    /// light appearance, on the `html` and `body` elements the script gives every body, so the reading page, the quote
    /// fold and a sender's own rules for `html` and `body` apply as they do in the reader's frame. The Quire variables
    /// come from the page, since custom properties inherit into a shadow tree. Nothing scrolls on paper, so the frame's
    /// overflow rules have no counterpart, and an image is kept whole on one page.
    ///
    /// A held-back image (still parked, so only in a body whose images the reader holds back) takes no room on paper. On
    /// screen its one-pixel stand-in keeps a place, which a sender's `height: auto` makes as tall as it is wide; on paper
    /// that empty square, kept whole like any image, would push the rest of a newsletter onto the next page. The note
    /// above the body says how many were left out.
    static let bodyCSS: String = #"""
    html, body { display: block; margin: 0; padding: 0; }
    body {
      font: 13px/1.45 -apple-system, BlinkMacSystemFont, "Helvetica Neue", Helvetica, Arial, sans-serif;
      color: CanvasText; overflow-wrap: break-word; word-wrap: break-word;
    }
    img { max-width: 100%; height: auto; break-inside: avoid; }
    img[data-ss-src] { display: none !important; }
    pre { white-space: pre-wrap; }
    .ss-quote { display: none; }
    body.ss-show-quotes .ss-quote { display: block; }
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
    :where(a:link) { color: var(--q-accent); }
    """#

    /// Attaches the bodies and says when the page is ready to print.
    ///
    /// One document has one Content-Security-Policy, and the reader gives each body its own, so the script applies the
    /// reader's in two steps. First the bodies whose images the reader shows are attached with their parked sources put
    /// back (as Load images does) and laid out, so everything they fetch is asked for. Then, if any body prints with its
    /// images hidden, the reader's blocking policy is added to the page, which WebKit enforces on every fetch asked for
    /// after it, and only then are those bodies attached: whatever a body still holds live (one stored while Load remote
    /// images was on) is never fetched. A body is inert in its template until it is attached, so nothing loads early.
    ///
    /// Each step waits for its own images, up to `imageWait` each: the held-back bodies still load their inline images
    /// (`ss-cid`, answered from the attachment cache or a download), which a first step spent on a slow remote image
    /// must not leave empty. So a page is ready at most twice `imageWait` after it loads.
    static func script(imageWait: TimeInterval) -> String {
        let wait = Int((max(0, imageWait) * 1000).rounded())
        return "var SS_PRINT_WAIT = \(wait);\nvar SS_PRINT_POLICY = " + ConversationShellAssets.jsStringLiteral(blockingPolicy)
            + ";\nvar SS_PRINT_BODY_CSS = " + ConversationShellAssets.jsStringLiteral(bodyCSS) + ";\n" + scriptBody
    }

    private static let scriptBody: String = #"""
    (function () {
      'use strict';
      var ready = false;

      function post() {
        if (ready) { return; }
        ready = true;
        document.documentElement.setAttribute('data-ss-ready', '');
        try { window.webkit.messageHandlers.ssPrint.postMessage('ready'); } catch (e) { /* no host: opened in a browser */ }
      }

      // Puts parked remote sources back, as Load images does in the reader: the trackers too, unless Block trackers holds
      // them back there (spec §5.60).
      function restore(fragment, holdsTrackers) {
        var parked = fragment.querySelectorAll(holdsTrackers ? 'img[data-ss-src]:not([data-ss-tracker])' : 'img[data-ss-src]');
        for (var i = 0; i < parked.length; i++) {
          parked[i].setAttribute('src', parked[i].getAttribute('data-ss-src'));
          parked[i].removeAttribute('data-ss-src');
        }
        var backgrounds = fragment.querySelectorAll('[data-ss-background]');
        for (var j = 0; j < backgrounds.length; j++) {
          backgrounds[j].setAttribute('background', backgrounds[j].getAttribute('data-ss-background'));
          backgrounds[j].removeAttribute('data-ss-background');
        }
      }

      // Attaches one body and adds its images to `images`, the ones its step waits for.
      function attach(host, images) {
        var template = document.getElementById('ss-pb-' + host.getAttribute('data-body'));
        if (!template) { return; }
        // Still inert: a source set here is fetched only once the body joins the page.
        var content = template.content.cloneNode(true);
        if (host.getAttribute('data-images') === 'shown') { restore(content, host.getAttribute('data-trackers') === 'held'); }
        // A lazy image waits to be scrolled to, which a page being printed never is.
        var lazy = content.querySelectorAll('[loading]');
        for (var i = 0; i < lazy.length; i++) { lazy[i].removeAttribute('loading'); }
        var root = host.attachShadow({ mode: 'open' });
        var style = document.createElement('style');
        style.textContent = SS_PRINT_BODY_CSS;
        var html = document.createElement('html');
        var body = document.createElement('body');
        body.className = host.getAttribute('data-classes') || '';
        body.appendChild(content);
        html.appendChild(body);
        root.appendChild(style);
        root.appendChild(html);
        var found = root.querySelectorAll('img');
        for (var j = 0; j < found.length; j++) { images.push(found[j]); }
      }

      // Waits a turn at least, so what layout asked for is under way, then until each of a step's images has come in or
      // failed, or the step's own wait is over: a wait from when the step began, so the second step's images get theirs
      // however long the first took. Load and error events, not a poll: WebKit holds a hidden page's repeating timers to
      // one a second, and this page is never on screen.
      function settle(images, then) {
        var done = false;
        function finish() {
          if (done) { return; }
          done = true;
          clearTimeout(deadline);
          then();
        }
        var deadline = setTimeout(finish, SS_PRINT_WAIT);
        setTimeout(function () {
          var pending = 0;
          function arrived() { if (--pending === 0) { finish(); } }
          for (var i = 0; i < images.length; i++) {
            if (images[i].complete) { continue; }
            pending++;
            images[i].addEventListener('load', arrived, { once: true });
            images[i].addEventListener('error', arrived, { once: true });
          }
          if (pending === 0) { finish(); }
        }, 0);
      }

      var hosts = document.querySelectorAll('.ss-pbody[data-body]');
      var shownImages = [];
      var hidden = [];
      for (var i = 0; i < hosts.length; i++) {
        if (hosts[i].getAttribute('data-images') === 'shown') { attach(hosts[i], shownImages); } else { hidden.push(hosts[i]); }
      }
      void document.body.offsetHeight;
      settle(shownImages, function () {
        if (!hidden.length) { return post(); }
        var policy = document.createElement('meta');
        policy.httpEquiv = 'Content-Security-Policy';
        policy.content = SS_PRINT_POLICY;
        document.head.appendChild(policy);
        var hiddenImages = [];
        for (var j = 0; j < hidden.length; j++) { attach(hidden[j], hiddenImages); }
        void document.body.offsetHeight;
        settle(hiddenImages, post);
      });
    })();
    """#
}
