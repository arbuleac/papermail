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

      function bodyDocument(html) {
        return '<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark"><style>'
          + SS_BODY_CSS + '</style></head><body>' + html + '</body></html>';
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
        iframe.srcdoc = bodyDocument(card.message.html);
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

      function loadImages(card, button) {
        if (!card.expanded) { expand(card); }
        var doc = frameDocument(card);
        if (!doc || !doc.body) {
          setTimeout(function () { loadImages(card, button); }, 50);
          return;
        }
        var images = doc.querySelectorAll('img[data-ss-src]');
        for (var i = 0; i < images.length; i++) {
          var img = images[i];
          img.addEventListener('load', card.remeasure);
          img.addEventListener('error', card.remeasure);
          img.src = img.getAttribute('data-ss-src');
          img.removeAttribute('data-ss-src');
        }
        if (button) { button.remove(); }
        card.imagesLoaded = true;
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

      function buildCard(m) {
        var card = {
          message: m, element: null, bodyElement: null, iframe: null, observer: null,
          expanded: false, quotesShown: false, original: false, height: 0, measureTimer: null
        };
        card.remeasure = function () { scheduleMeasure(card); };

        var article = el('article', 'ss-card');
        article.dataset.id = m.id;
        if (m.isUnread) { article.classList.add('ss-unread'); }
        if (m.isStarred) { article.classList.add('ss-starred'); }

        var header = el('header', 'ss-header');
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
        header.appendChild(avatar);
        header.appendChild(who);
        header.appendChild(date);
        header.addEventListener('click', function (event) {
          event.stopPropagation();
          select(card);
          toggle(card);
        });

        var tools = el('div', 'ss-tools');
        if (m.blockedRemoteImageCount > 0) {
          var loadButton = el('button', 'ss-button ss-load-images', 'Load images (' + m.blockedRemoteImageCount + ')');
          loadButton.addEventListener('click', function (event) { event.stopPropagation(); loadImages(card, loadButton); });
          tools.appendChild(loadButton);
        }
        if (m.hasQuotedContent) {
          var quoteButton = el('button', 'ss-button ss-toggle-quote', 'Show quoted text');
          quoteButton.addEventListener('click', function (event) { event.stopPropagation(); toggleQuotes(card, quoteButton); });
          tools.appendChild(quoteButton);
        }
        if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) {
          var originalButton = el('button', 'ss-button ss-original-colors', 'Original colors');
          originalButton.addEventListener('click', function (event) { event.stopPropagation(); toggleOriginal(card, originalButton); });
          tools.appendChild(originalButton);
        }

        var body = el('div', 'ss-body');
        if (!m.hasBody) { body.classList.add('ss-pending-body'); }

        var attachments = el('div', 'ss-attachments');
        for (var i = 0; i < m.attachments.length; i++) {
          attachments.appendChild(buildChip(card, m.attachments[i]));
        }

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
        card.bodyElement = body;
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
        for (var i = 0; i < state.cards.length; i++) {
          var card = state.cards[i];
          if (card.observer) { try { card.observer.disconnect(); } catch (e) {} }
          if (card.measureTimer) { clearTimeout(card.measureTimer); }
        }
        state.cards = [];
        state.byID = {};
        state.selected = null;
        state.payload = null;
      }

      function render(payload) {
        teardown();
        state.payload = payload;
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

      function clear() {
        teardown();
        document.title = '';
        root.replaceChildren(el('div', 'ss-empty', ''));
      }

      window.addEventListener('resize', function () {
        for (var i = 0; i < state.cards.length; i++) { scheduleMeasure(state.cards[i]); }
      });

      window.ss = {
        version: 1,
        render: render,
        clear: clear,
        cardCount: function () { return state.cards.length; },
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
