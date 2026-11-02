import Foundation

/// The conversation shell: one HTML document each pooled web view loads once, after which every
/// conversation is a single `window.ss.render(payload)` call.
///
/// The assets live in SSCore as plain strings (no WebKit import) so the JavaScript contract can be
/// exercised from SSCoreTests next to `RenderPayload`, whose keys it reads.
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

    public static let html: String = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Conversation</title>
        <style>
        \(css)
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

    public static let css: String = #"""
    :root {
      color-scheme: light dark;
      --ss-bg: #f2f2f6;
      --ss-card: #ffffff;
      --ss-border: rgba(0, 0, 0, 0.12);
      --ss-text: #1d1d1f;
      --ss-muted: #6e6e73;
      --ss-accent: #0a84ff;
      --ss-chip: rgba(0, 0, 0, 0.05);
      --ss-selected: rgba(10, 132, 255, 0.45);
      --ss-star: #f5a623;
      font: 13px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Helvetica, Arial, sans-serif;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --ss-bg: #1c1c1e;
        --ss-card: #2a2a2d;
        --ss-border: rgba(255, 255, 255, 0.12);
        --ss-text: #f5f5f7;
        --ss-muted: #98989d;
        --ss-chip: rgba(255, 255, 255, 0.08);
      }
    }
    html, body { margin: 0; padding: 0; background: var(--ss-bg); color: var(--ss-text); }
    body { padding: 16px; -webkit-user-select: text; -webkit-font-smoothing: antialiased; }
    #ss-root { max-width: 920px; margin: 0 auto; }
    .ss-card {
      background: var(--ss-card);
      border: 1px solid var(--ss-border);
      border-radius: 12px;
      padding: 16px;
      margin-bottom: 12px;
      box-sizing: border-box;
    }
    .ss-card.ss-selected { box-shadow: 0 0 0 2px var(--ss-selected); }
    .ss-header { display: flex; align-items: flex-start; gap: 12px; }
    .ss-collapsed .ss-header { cursor: pointer; align-items: center; }
    .ss-avatar {
      width: 36px; height: 36px; border-radius: 50%;
      color: #fff; display: flex; align-items: center; justify-content: center;
      font-weight: 600; font-size: 14px; flex: none; letter-spacing: 0.5px;
      -webkit-user-select: none;
    }
    .ss-who { flex: 1 1 auto; min-width: 0; }
    .ss-name-line { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .ss-name { font-weight: 600; }
    .ss-address { display: none; color: var(--ss-muted); margin-left: 6px; font-weight: 400; }
    .ss-header:hover .ss-address { display: inline; }
    .ss-star { color: var(--ss-star); margin-left: 6px; }
    .ss-unread .ss-name::before {
      content: ""; display: inline-block; width: 8px; height: 8px; border-radius: 50%;
      background: var(--ss-accent); margin-right: 6px; vertical-align: 1px;
    }
    .ss-recipients, .ss-snippet { color: var(--ss-muted); font-size: 12px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .ss-snippet { display: none; }
    .ss-collapsed .ss-snippet { display: block; }
    .ss-collapsed .ss-recipients { display: none; }
    .ss-date { color: var(--ss-muted); font-size: 12px; text-align: right; flex: none; white-space: nowrap; }
    .ss-tools { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 10px; }
    .ss-tools:empty { display: none; }
    .ss-button {
      font: inherit; font-size: 12px; color: var(--ss-accent); background: transparent;
      border: 1px solid var(--ss-border); border-radius: 6px; padding: 3px 9px; cursor: pointer;
    }
    .ss-button:hover { background: var(--ss-chip); }
    .ss-body { margin-top: 12px; }
    .ss-body iframe { width: 100%; height: 0; border: 0; display: block; overflow: hidden; }
    .ss-body.ss-pending-body { opacity: 0.6; }
    .ss-attachments { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 12px; }
    .ss-attachments:empty { display: none; }
    .ss-chip {
      font: inherit; font-size: 12px; color: var(--ss-text);
      display: inline-flex; align-items: center; gap: 6px; max-width: 100%;
      background: var(--ss-chip); border: 1px solid transparent; border-radius: 8px;
      padding: 6px 10px; cursor: pointer;
    }
    .ss-chip:hover { border-color: var(--ss-border); }
    .ss-chip-name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .ss-chip-size { color: var(--ss-muted); flex: none; }
    .ss-footer {
      display: flex; gap: 16px; margin-top: 12px; padding-top: 12px;
      border-top: 1px solid var(--ss-border); font-size: 12px;
    }
    .ss-footer a { color: var(--ss-accent); text-decoration: none; cursor: pointer; }
    .ss-footer a:hover { text-decoration: underline; }
    .ss-collapsed .ss-tools, .ss-collapsed .ss-body, .ss-collapsed .ss-attachments, .ss-collapsed .ss-footer { display: none; }
    .ss-empty { color: var(--ss-muted); text-align: center; padding: 48px 16px; }
    """#

    /// Styles injected into every body iframe. `color-scheme: light dark` lets plain emails follow the
    /// appearance; `.ss-original` is the per-message escape hatch back to the sender's light colors.
    public static let bodyCSS: String = #"""
    html, body { margin: 0; padding: 0; }
    body {
      font: 13px/1.45 -apple-system, BlinkMacSystemFont, "Helvetica Neue", Helvetica, Arial, sans-serif;
      color-scheme: light dark;
      overflow-wrap: break-word;
      word-wrap: break-word;
    }
    body.ss-original { color-scheme: light; background: #fff; color: #000; }
    img { max-width: 100%; height: auto; }
    pre { white-space: pre-wrap; }
    blockquote { margin: 0 0 0 8px; padding-left: 8px; border-left: 2px solid rgba(128, 128, 128, 0.4); }
    .ss-quote { display: none; }
    body.ss-show-quotes .ss-quote { display: block; }
    .ss-plain { white-space: pre-wrap; }
    .ss-pending { opacity: 0.7; }
    """#

    public static let js: String = "var SS_BODY_CSS = " + jsStringLiteral(bodyCSS) + ";\n" + script

    /// Message bodies are loaded with `srcdoc` into `sandbox="allow-same-origin"` iframes: no scripts run
    /// inside them, so the shell measures each document from the parent after load, on every image load
    /// and on window resize, and sizes the frame to its content.
    static let script: String = #"""
    (function () {
      'use strict';
      var root = document.getElementById('ss-root');
      var state = { payload: null, cards: [], byID: {}, selected: null };
      // The "Load remote images" preference of the payload being rendered.
      var loadRemote = false;
      // Bodies whose images are not loaded render under this policy: nothing remote is fetched, whatever
      // the stored HTML holds (a body stored while the preference was on keeps live remote sources).
      var BLOCKING_CSP = "default-src 'none'; img-src ss-cid: data:; style-src 'unsafe-inline'; font-src ss-cid: data:";
      // Sources the policy holds back: any image not served locally, plus remote backgrounds.
      var LIVE_REMOTE = 'img[src]:not([src^="data:" i]):not([src^="ss-cid:" i]), [background^="http" i], [style*="url(http" i]';

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

      function bodyDocument(html, allowRemote) {
        var policy = allowRemote ? '' : '<meta http-equiv="Content-Security-Policy" content="' + BLOCKING_CSP + '">';
        return '<!DOCTYPE html><html><head><meta charset="utf-8">' + policy
          + '<meta name="color-scheme" content="light dark"><style>'
          + SS_BODY_CSS + '</style></head><body>' + html + '</body></html>';
      }

      // Puts parked remote sources back. Runs only in a frame built without the blocking policy.
      function restoreRemote(card, doc) {
        var images = doc.querySelectorAll('img[data-ss-src]');
        for (var i = 0; i < images.length; i++) {
          var img = images[i];
          img.addEventListener('load', card.remeasure);
          img.addEventListener('error', card.remeasure);
          img.src = img.getAttribute('data-ss-src');
          img.removeAttribute('data-ss-src');
        }
        var backgrounds = doc.querySelectorAll('[data-ss-background]');
        for (var j = 0; j < backgrounds.length; j++) {
          backgrounds[j].setAttribute('background', backgrounds[j].getAttribute('data-ss-background'));
          backgrounds[j].removeAttribute('data-ss-background');
        }
      }

      function frameDocument(card) {
        if (!card.iframe) { return null; }
        try { return card.iframe.contentDocument; } catch (e) { return null; }
      }

      // body.scrollHeight reflects content in standards mode and is independent of the frame's own
      // height, so frames can shrink again when quoted text is hidden.
      function contentHeight(doc) {
        var body = doc.body;
        if (!body) { return 0; }
        return Math.max(body.scrollHeight, body.offsetHeight);
      }

      function measure(card) {
        var doc = frameDocument(card);
        if (!doc) { return 0; }
        var height = contentHeight(doc);
        if (height > 0 && height !== card.height) {
          card.height = height;
          card.iframe.style.height = height + 'px';
        }
        return height;
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
        if (card.imagesLoaded) {
          restoreRemote(card, doc);
        } else {
          var live = doc.querySelectorAll(LIVE_REMOTE).length;
          if (live !== card.liveRemote) { card.liveRemote = live; fillTools(card); }
        }
        // A frame rebuilt to load images starts from a fresh document; the reader's toggles come along.
        doc.body.classList.toggle('ss-show-quotes', !!card.quotesShown);
        doc.body.classList.toggle('ss-original', !!card.original);
        if (card.observer) { try { card.observer.disconnect(); } catch (e) {} card.observer = null; }
        var images = doc.images;
        for (var i = 0; i < images.length; i++) {
          images[i].addEventListener('load', card.remeasure);
          images[i].addEventListener('error', card.remeasure);
        }
        try {
          if (window.ResizeObserver) {
            card.observer = new ResizeObserver(card.remeasure);
            card.observer.observe(doc.body);
          }
        } catch (e) { card.observer = null; }
        if (!doc.ssLinksHooked) {
          doc.ssLinksHooked = true;
          doc.addEventListener('click', function (event) {
            var target = event.target;
            var anchor = target && target.closest ? target.closest('a[href]') : null;
            if (!anchor) { select(card); return; }
            event.preventDefault();
            post('ss', { kind: 'openLink', url: anchor.href });
          });
        }
        measure(card);
        setTimeout(card.remeasure, 50);
        setTimeout(card.remeasure, 300);
      }

      function ensureFrame(card) {
        if (card.iframe) { return; }
        var iframe = document.createElement('iframe');
        iframe.setAttribute('sandbox', 'allow-same-origin');
        iframe.setAttribute('scrolling', 'no');
        iframe.setAttribute('title', 'Message body');
        iframe.addEventListener('load', function () { attachMeasurement(card); });
        card.iframe = iframe;
        iframe.srcdoc = bodyDocument(card.message.html, card.imagesLoaded);
        card.bodyElement.appendChild(iframe);
      }

      function expand(card) {
        card.expanded = true;
        card.element.classList.remove('ss-collapsed');
        ensureFrame(card);
        scheduleMeasure(card);
      }

      function collapse(card) {
        card.expanded = false;
        card.element.classList.add('ss-collapsed');
      }

      function toggle(card) {
        if (card.expanded) { collapse(card); } else { expand(card); }
      }

      function select(card) {
        if (state.selected === card) { return; }
        if (state.selected) { state.selected.element.classList.remove('ss-selected'); }
        state.selected = card;
        if (card) {
          card.element.classList.add('ss-selected');
          post('ss', { kind: 'select', messageID: card.message.id });
        }
      }

      function action(type, card, attachmentID) {
        post('ss', { kind: 'action', type: type, messageID: card.message.id, attachmentID: attachmentID || null });
      }

      // The blocking policy of a document cannot be lifted, so the frame is rebuilt without it; parked
      // sources are restored once the new document has loaded.
      function loadImages(card, button) {
        if (button) { button.remove(); }
        if (card.imagesLoaded) { return; }
        card.imagesLoaded = true;
        releaseFrame(card);
        if (card.iframe) { card.iframe.remove(); card.iframe = null; }
        if (card.expanded) { ensureFrame(card); } else { expand(card); }
        scheduleMeasure(card);
      }

      function toggleQuotes(card, button) {
        var doc = frameDocument(card);
        if (!doc || !doc.body) { return; }
        card.quotesShown = !card.quotesShown;
        doc.body.classList.toggle('ss-show-quotes', card.quotesShown);
        button.textContent = card.quotesShown ? 'Hide quoted text' : 'Show quoted text';
        measure(card);
        scheduleMeasure(card);
      }

      function toggleOriginal(card, button) {
        var doc = frameDocument(card);
        if (!doc || !doc.body) { return; }
        card.original = !card.original;
        doc.body.classList.toggle('ss-original', card.original);
        button.textContent = card.original ? 'Adaptive colors' : 'Original colors';
        scheduleMeasure(card);
      }

      function headerKey(m) {
        return JSON.stringify([m.from, m.to, m.cc, m.snippet, m.dateDisplay, m.dateISO, m.isUnread, m.isStarred]);
      }

      function fillHeader(card) {
        var m = card.message;
        var avatar = el('div', 'ss-avatar', m.from.initials);
        avatar.style.backgroundColor = m.from.color;
        var who = el('div', 'ss-who');
        var nameLine = el('div', 'ss-name-line');
        nameLine.appendChild(el('span', 'ss-name', m.from.name || m.from.address));
        if (m.from.address && m.from.address !== m.from.name) {
          nameLine.appendChild(el('span', 'ss-address', m.from.address));
        }
        if (m.isStarred) { nameLine.appendChild(el('span', 'ss-star', '★')); }
        who.appendChild(nameLine);
        var recipients = '';
        if (m.to) { recipients += 'To ' + m.to; }
        if (m.cc) { recipients += (recipients ? ' · ' : '') + 'Cc ' + m.cc; }
        who.appendChild(el('div', 'ss-recipients', recipients));
        who.appendChild(el('div', 'ss-snippet', m.snippet || ''));
        var date = el('time', 'ss-date', m.dateDisplay);
        date.setAttribute('datetime', m.dateISO);
        date.title = m.dateISO;
        card.headerElement.replaceChildren(avatar, who, date);
        card.element.classList.toggle('ss-unread', !!m.isUnread);
        card.element.classList.toggle('ss-starred', !!m.isStarred);
      }

      // Tools follow the body: they are rebuilt only with it, so a "Load images" the user already
      // pressed does not come back on a metadata change.
      function fillTools(card) {
        var m = card.message;
        var tools = card.toolsElement;
        tools.replaceChildren();
        var blocked = (m.blockedRemoteImageCount || 0) + (card.liveRemote || 0);
        if (blocked > 0 && !card.imagesLoaded) {
          var loadButton = el('button', 'ss-button ss-load-images', 'Load images (' + blocked + ')');
          loadButton.addEventListener('click', function (event) { event.stopPropagation(); loadImages(card, loadButton); });
          tools.appendChild(loadButton);
        }
        if (m.hasQuotedContent) {
          var quoteButton = el('button', 'ss-button ss-toggle-quote', card.quotesShown ? 'Hide quoted text' : 'Show quoted text');
          quoteButton.addEventListener('click', function (event) { event.stopPropagation(); toggleQuotes(card, quoteButton); });
          tools.appendChild(quoteButton);
        }
        if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) {
          var originalButton = el('button', 'ss-button ss-original-colors', card.original ? 'Adaptive colors' : 'Original colors');
          originalButton.addEventListener('click', function (event) { event.stopPropagation(); toggleOriginal(card, originalButton); });
          tools.appendChild(originalButton);
        }
      }

      function fillAttachments(card) {
        var m = card.message;
        var list = card.attachmentsElement;
        list.replaceChildren();
        for (var i = 0; i < m.attachments.length; i++) {
          list.appendChild(buildChip(card, m.attachments[i]));
        }
      }

      function releaseFrame(card) {
        if (card.observer) { try { card.observer.disconnect(); } catch (e) {} card.observer = null; }
        if (card.measureTimer) { clearTimeout(card.measureTimer); card.measureTimer = null; }
      }

      // The body itself changed (hydration replaced the snippet fallback): the frame is rebuilt, and the
      // per-frame state goes with it because it described the old document.
      function replaceBody(card) {
        releaseFrame(card);
        if (card.iframe) { card.iframe.remove(); card.iframe = null; }
        card.height = 0;
        card.imagesLoaded = loadRemote;
        card.liveRemote = 0;
        card.quotesShown = false;
        card.original = false;
        card.bodyElement.classList.toggle('ss-pending-body', !card.message.hasBody);
        fillTools(card);
        if (card.expanded) {
          ensureFrame(card);
          scheduleMeasure(card);
        }
      }

      function patch(card, m) {
        var previous = card.message;
        card.message = m;
        if (headerKey(previous) !== headerKey(m)) { fillHeader(card); }
        if (previous.html !== m.html || previous.hasBody !== m.hasBody) { replaceBody(card); }
        if (JSON.stringify(previous.attachments) !== JSON.stringify(m.attachments)) { fillAttachments(card); }
      }

      function buildCard(m) {
        var card = {
          message: m, element: null, headerElement: null, toolsElement: null, bodyElement: null,
          attachmentsElement: null, iframe: null, observer: null, expanded: false, imagesLoaded: loadRemote, liveRemote: 0,
          quotesShown: false, original: false, height: 0, measureTimer: null
        };
        card.remeasure = function () { scheduleMeasure(card); };

        var article = el('article', 'ss-card');
        article.dataset.id = m.id;
        var header = el('header', 'ss-header');
        header.addEventListener('click', function (event) {
          event.stopPropagation();
          select(card);
          toggle(card);
        });
        var tools = el('div', 'ss-tools');
        var body = el('div', 'ss-body');
        body.classList.toggle('ss-pending-body', !m.hasBody);
        var attachments = el('div', 'ss-attachments');
        var footer = el('footer', 'ss-footer');
        footer.appendChild(buildFooterLink(card, 'reply', 'Reply'));
        footer.appendChild(buildFooterLink(card, 'replyAll', 'Reply all'));
        footer.appendChild(buildFooterLink(card, 'forward', 'Forward'));

        article.appendChild(header);
        article.appendChild(tools);
        article.appendChild(body);
        article.appendChild(attachments);
        article.appendChild(footer);
        article.addEventListener('click', function () { select(card); });

        card.element = article;
        card.headerElement = header;
        card.toolsElement = tools;
        card.bodyElement = body;
        card.attachmentsElement = attachments;
        fillHeader(card);
        fillTools(card);
        fillAttachments(card);
        return card;
      }

      function buildChip(card, attachment) {
        var chip = el('button', 'ss-chip');
        chip.appendChild(el('span', 'ss-chip-name', attachment.name));
        chip.appendChild(el('span', 'ss-chip-size', attachment.size));
        chip.title = attachment.mime;
        chip.dataset.attachmentId = attachment.id;
        chip.addEventListener('click', function (event) {
          event.stopPropagation();
          select(card);
          action('openAttachment', card, attachment.id);
        });
        return chip;
      }

      function buildFooterLink(card, type, label) {
        var link = el('a', 'ss-' + type, label);
        link.setAttribute('role', 'button');
        link.href = '#';
        link.addEventListener('click', function (event) {
          event.preventDefault();
          event.stopPropagation();
          select(card);
          action(type, card, null);
        });
        return link;
      }

      function teardown() {
        for (var i = 0; i < state.cards.length; i++) { releaseFrame(state.cards[i]); }
        state.cards = [];
        state.byID = {};
        state.selected = null;
        state.payload = null;
      }

      function render(payload) {
        teardown();
        state.payload = payload;
        loadRemote = !!payload.loadRemoteImages;
        document.title = payload.subject || '';
        var messages = payload.messages || [];
        var fragment = document.createDocumentFragment();
        for (var i = 0; i < messages.length; i++) {
          var card = buildCard(messages[i]);
          state.cards.push(card);
          state.byID[card.message.id] = card;
          fragment.appendChild(card.element);
        }
        if (messages.length === 0) { fragment.appendChild(el('div', 'ss-empty', 'No messages')); }
        root.replaceChildren(fragment);
        var firstExpanded = null;
        for (var j = 0; j < state.cards.length; j++) {
          var c = state.cards[j];
          if (j === state.cards.length - 1 || c.message.isUnread) {
            expand(c);
            if (!firstExpanded) { firstExpanded = c; }
          } else {
            collapse(c);
          }
        }
        if (state.cards.length > 0) { select(state.cards[state.cards.length - 1]); }
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
        for (var r = 0; r < state.cards.length; r++) {
          var gone = state.cards[r];
          if (incoming[gone.message.id]) { continue; }
          releaseFrame(gone);
          gone.element.remove();
          if (state.selected === gone) { state.selected = null; }
        }
        var cards = [];
        var byID = {};
        var next = null;
        for (var n = messages.length - 1; n >= 0; n--) {
          var m = messages[n];
          var card = state.byID[m.id];
          if (card) {
            patch(card, m);
          } else {
            card = buildCard(m);
            root.insertBefore(card.element, next);
            if (m.isUnread || n === messages.length - 1) { expand(card); } else { collapse(card); }
          }
          cards.push(card);
          byID[m.id] = card;
          next = card.element;
        }
        cards.reverse();
        state.cards = cards;
        state.byID = byID;
        state.payload = payload;
        document.title = payload.subject || '';
        if (!state.selected) { select(cards[cards.length - 1]); }
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

      function clear() {
        teardown();
        document.title = '';
        root.replaceChildren(el('div', 'ss-empty', ''));
      }

      window.addEventListener('resize', function () {
        for (var i = 0; i < state.cards.length; i++) { scheduleMeasure(state.cards[i]); }
      });

      window.ss = {
        version: 2,
        render: render,
        update: update,
        flags: flags,
        clear: clear,
        cardCount: function () { return state.cards.length; },
        cardStates: function () {
          var states = [];
          for (var i = 0; i < state.cards.length; i++) {
            var card = state.cards[i];
            states.push({
              id: card.message.id, expanded: card.expanded, imagesLoaded: card.imagesLoaded,
              quotesShown: card.quotesShown, hasFrame: !!card.iframe
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
          var heights = [];
          for (var i = 0; i < state.cards.length; i++) {
            var card = state.cards[i];
            heights.push(card.iframe ? (parseFloat(card.iframe.style.height) || 0) : -1);
          }
          return heights;
        },
        expandAll: function () {
          for (var i = 0; i < state.cards.length; i++) { expand(state.cards[i]); }
        },
        select: function (id) { var card = state.byID[id]; if (card) { select(card); } },
        selectedMessageID: function () { return state.selected ? state.selected.message.id : null; },
        loadImages: function (id) {
          var card = state.byID[id];
          if (!card) { return; }
          var button = card.element.querySelector('.ss-load-images');
          loadImages(card, button);
        }
      };

      post('ssReady', { kind: 'ready' });
      post('ss', { kind: 'ready' });
    })();
    """#

    /// A JavaScript string literal for arbitrary text (JSON string escaping is a subset of JS).
    static func jsStringLiteral(_ text: String) -> String {
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
