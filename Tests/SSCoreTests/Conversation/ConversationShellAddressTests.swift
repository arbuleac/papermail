import WebKit
import XCTest
@testable import SSCore

/// Copying an address from a sheet header (spec §5.14): each recipient of the open list and the sender's address is a
/// control that copies with a click, named to the app by its position; the list opens below its toggle and only the
/// toggle and Esc fold it; ← → rove along it; the mark stands in for what the pasteboard took; the focus report tells the
/// app which keys are the page's. The headless half holds the script's privacy; the rest drives the real shell and is
/// gated behind `SS_UI_TESTS=1`, as `ConversationShellWebViewTests` is.
@MainActor
final class ConversationShellAddressTests: XCTestCase {
    typealias F = ConversationFixtures

    // MARK: Headless

    /// The page never writes a clipboard: a copy is the app's, which reads the address from the store.
    func testTheShellWritesNoClipboard() {
        let script = ConversationShellAssets.script
        for api in ["navigator.clipboard", "execCommand", "clipboardData", "ClipboardItem", "'copy'"] {
            XCTAssertFalse(script.contains(api), "the shell uses \(api)")
        }
        XCTAssertTrue(script.contains("type: 'copyAddress', messageID: card.message.id, attachmentID: null, value: value"),
                      "a copy names the message and the position, nothing more")
    }

    /// Every element the list is made of is a control or a group, and its targets are not selectable text; the open list
    /// adds no cursor rule, so its labels keep the arrow WebKit gives text that cannot be selected.
    func testTheListsRulesMakeControlsNotText() {
        let css = ConversationShellAssets.css
        XCTAssertTrue(css.contains(".ss-cpt { -webkit-user-select: none; }"))
        XCTAssertTrue(css.contains(".ss-rcx { margin-top: 8px; -webkit-user-select: none; }"))
        XCTAssertTrue(css.contains("--q-dur-copiedConfirm:1500ms"), "the hold the script reads is the token's")
    }

    // MARK: In WebKit

    /// A click on a recipient posts its position (`to:1`), never its address; a double-click posts once; a click on a
    /// label or in the space beside the recipients posts nothing and leaves the list open.
    func testAClickCopiesByPositionAndNothingElseInTheListActs() async throws {
        let (webView, messages) = try await openList()
        _ = try await evaluate("document.querySelector('.ss-rp[data-addr=\"to:1\"]').click()", in: webView)
        let copies = try await waitForCopies(1, in: messages)
        XCTAssertEqual(copies.first?["value"] as? String, "to:1")
        XCTAssertEqual(copies.first?["messageID"] as? String, messageKey)
        let everything = messages.received.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
            .map { String(decoding: $0, as: UTF8.self) }.joined()
        XCTAssertFalse(everything.contains("@example.com"), "no address in any script message: \(everything)")

        _ = try await evaluate("""
            document.querySelector('.ss-rp[data-addr="cc:0"]').dispatchEvent(new MouseEvent('click', { bubbles: true, detail: 1 }));
            document.querySelector('.ss-rp[data-addr="cc:0"]').dispatchEvent(new MouseEvent('click', { bubbles: true, detail: 2 }));
            true
            """, in: webView)
        let twice = try await waitForCopies(2, in: messages)
        XCTAssertEqual(twice.last?["value"] as? String, "cc:0")

        let missed = """
            (function () {
              document.querySelector('.ss-rcl').click();
              var row = document.querySelector('.ss-rcf:last-child').getBoundingClientRect();
              var beside = document.elementFromPoint(row.right - 2, row.top + 12);
              var target = beside && beside.closest('.ss-cpt');
              if (beside) { beside.click(); }
              return [!!target, !!document.querySelector('.ss-rcx')];
            })()
            """
        let result = try await evaluate(missed, in: webView) as? [Bool]
        XCTAssertEqual(result, [false, true], "the space beside the recipients is no target, and nothing folds the list")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(self.copies(in: messages).count, 2, "a double-click copies once; a label or a gap copies nothing")
    }

    /// The toggle keeps its line: folded it is the summary, open it reads “Hide addresses” in the link style, and the list
    /// opens 8 pt below it; only the toggle folds it.
    func testTheToggleStaysOnItsLineAndFolds() async throws {
        let (webView, _) = try await loadedShell()
        _ = try await evaluate("window.ss.render(\(try payload().jsonString()))", in: webView)
        let probe = """
            (function () {
              var t = document.querySelector('.ss-rc'), words = t.querySelector('.ss-rct'), list = document.querySelector('.ss-rcx');
              return [words.textContent, t.title, t.getAttribute('aria-expanded'), t.getAttribute('aria-label') || '',
                      Math.round(words.getBoundingClientRect().top), list ? Math.round(list.getBoundingClientRect().top - words.getBoundingClientRect().bottom) : -1,
                      getComputedStyle(words).textDecorationLine, list && t.getAttribute('aria-controls') === list.id];
            })()
            """
        let folded = try await evaluate(probe, in: webView) as? [Any]
        XCTAssertEqual(folded?[0] as? String, "to me, Bob, plain, x \u{00B7} cc Carol, x")
        XCTAssertEqual(folded?[1] as? String, "Show Addresses")
        XCTAssertEqual(folded?[2] as? String, "false")
        XCTAssertEqual(folded?[3] as? String, "Recipients, to me, Bob, plain, x, cc Carol, x", "the visible words are in the name")
        XCTAssertEqual(folded?[5] as? Int, -1)

        _ = try await evaluate("document.querySelector('.ss-rc').click()", in: webView)
        let open = try await evaluate(probe, in: webView) as? [Any]
        XCTAssertEqual(open?[0] as? String, "Hide addresses")
        XCTAssertEqual(open?[1] as? String, "Hide Addresses")
        XCTAssertEqual(open?[2] as? String, "true")
        XCTAssertEqual(open?[3] as? String, "", "open, the words are the name")
        XCTAssertEqual(open?[4] as? Int, folded?[4] as? Int, "the toggle stays on its line")
        XCTAssertEqual(open?[5] as? Int, 8, "the list opens 8 pt below it")
        XCTAssertEqual(open?[6] as? String, "underline", "in the header's link style")
        XCTAssertEqual(open?[7] as? Bool, true)

        _ = try await evaluate("document.querySelector('.ss-rc').click()", in: webView)
        let again = try await evaluate(probe, in: webView) as? [Any]
        XCTAssertEqual(again?[0] as? String, "to me, Bob, plain, x \u{00B7} cc Carol, x", "the place clicked to open folds it")
    }

    /// ← → rove along the open list and stop at either end; the stop the keyboard reached is where Tab lands again, and a
    /// re-render keeps focus on it; ↩ and Space copy the focused recipient.
    func testArrowsRoveClampAndRememberTheStop() async throws {
        let (webView, messages) = try await openList()
        let key = "(function (k) { document.activeElement.dispatchEvent(new KeyboardEvent('keydown', { key: k, bubbles: true, cancelable: true }));"
            + " var a = document.activeElement; return (a.dataset && a.dataset.addr) || a.className; })"
        _ = try await evaluate("document.querySelector('.ss-rp').focus(); true", in: webView)
        var stops: [String] = []
        for press in ["ArrowLeft", "ArrowRight", "ArrowRight", "ArrowRight", "ArrowRight", "ArrowRight", "ArrowRight"] {
            stops.append(try await evaluate("\(key)('\(press)')", in: webView) as? String ?? "")
        }
        XCTAssertEqual(stops, ["to:0", "to:1", "to:2", "to:3", "cc:0", "cc:1", "cc:1"], "reading order, To through Cc, stopping at the end")
        let tabStops = try await evaluate("""
            Array.prototype.filter.call(document.querySelectorAll('.ss-rcx [tabindex="0"]'), function (n) { return true; })
              .map(function (n) { return n.dataset.addr; })
            """, in: webView) as? [String]
        XCTAssertEqual(tabStops, ["cc:1"], "one Tab stop, where the keyboard was")

        _ = try await evaluate("\(key)('ArrowLeft'); document.activeElement.blur(); true", in: webView)
        let flags = "[{\"id\": \(ConversationShellAssets.jsStringLiteral(messageKey)), \"isUnread\": false, \"isStarred\": true}]"
        _ = try await evaluate("window.ss.flags(\(flags))", in: webView)
        let kept = try await evaluate("document.querySelector('.ss-rcx [tabindex=\"0\"]').dataset.addr", in: webView) as? String
        XCTAssertEqual(kept, "cc:0", "Tab lands on the recipient last reached, through a re-render")

        _ = try await evaluate("document.querySelector('.ss-rp[data-addr=\"to:2\"]').focus(); true", in: webView)
        _ = try await evaluate("window.ss.flags(\(flags.replacingOccurrences(of: "true}", with: "false}")))", in: webView)
        let focused = try await evaluate("document.activeElement.dataset.addr", in: webView) as? String
        XCTAssertEqual(focused, "to:2", "a re-render keeps focus on the same recipient")

        _ = try await evaluate("\(key)('Enter'); \(key)(' '); true", in: webView)
        let copies = try await waitForCopies(2, in: messages)
        XCTAssertEqual(copies.map { $0["value"] as? String }, ["to:2", "to:2"], "↩ and Space copy the focused recipient")
    }

    /// Esc, which the app hands the page through `ss.foldAddresses()`, folds the list and puts focus on the toggle; with
    /// focus elsewhere it does nothing. Esc reaching the page itself does the same.
    func testEscFoldsTheListOntoItsToggle() async throws {
        let (webView, _) = try await openList()
        let elsewhere = try await evaluate("window.ss.foldAddresses()", in: webView) as? Bool
        XCTAssertEqual(elsewhere, false, "focus outside the list leaves it open")
        _ = try await evaluate("document.querySelector('.ss-rp[data-addr=\"to:1\"]').focus(); true", in: webView)
        let folded = try await evaluate("window.ss.foldAddresses()", in: webView) as? Bool
        XCTAssertEqual(folded, true)
        let after = try await evaluate("""
            [!!document.querySelector('.ss-rcx'), document.activeElement.classList.contains('ss-rc'),
             document.activeElement.getAttribute('aria-expanded')]
            """, in: webView) as? [Any]
        XCTAssertEqual(after?[0] as? Bool, false)
        XCTAssertEqual(after?[1] as? Bool, true, "focus goes to the toggle")
        XCTAssertEqual(after?[2] as? String, "false")

        _ = try await evaluate("document.activeElement.click(); document.querySelector('.ss-rp').focus(); true", in: webView)
        _ = try await evaluate("""
            document.activeElement.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true })); true
            """, in: webView)
        let page = try await evaluate("[!!document.querySelector('.ss-rcx'), document.activeElement.classList.contains('ss-rc')]",
                                      in: webView) as? [Bool]
        XCTAssertEqual(page, [false, true])
    }

    /// The mark stands in for what the pasteboard took, keeping its width: the address with its brackets and comma, the
    /// whole recipient after Copy Name and Address, the checkmark alone where the word does not fit. One at a time; it
    /// survives a re-render of the header and leaves after the hold.
    func testTheMarkKeepsTheWidthAndShowsOneAtATime() async throws {
        let (webView, _) = try await openList()
        let part = """
            (function (value, part) {
              var t = document.querySelector('.ss-rp[data-addr="' + value + '"]');
              var p = t.querySelector(part), m = t.querySelector('.ss-mark');
              var pr = p.getBoundingClientRect(), tr = t.getBoundingClientRect();
              return [Math.round(pr.width * 10) / 10, Math.round(tr.width * 10) / 10, p.classList.contains('ss-copied'),
                      m ? m.textContent : '', m ? m.classList.contains('ss-glyph-only') : false,
                      m ? Math.round((m.getBoundingClientRect().left - pr.left) * 10) / 10 : -1,
                      m ? getComputedStyle(m).color === getComputedStyle(document.querySelector('.ss-nl')).color : false];
            })
            """
        let before = try await evaluate("\(part)('to:1', '.ss-cpa')", in: webView) as? [Any]
        let shown = try await evaluate("window.ss.addressCopied(\(ConversationShellAssets.jsStringLiteral(messageKey)), 'to:1', 'address')",
                                       in: webView) as? Bool
        XCTAssertEqual(shown, true)
        let during = try await evaluate("\(part)('to:1', '.ss-cpa')", in: webView) as? [Any]
        XCTAssertEqual(during?[0] as? Double, before?[0] as? Double, "the address keeps its width")
        XCTAssertEqual(during?[1] as? Double, before?[1] as? Double, "and so does the recipient")
        XCTAssertEqual(during?[2] as? Bool, true)
        XCTAssertEqual(during?[3] as? String, "Copied")
        XCTAssertEqual(during?[4] as? Bool, false)
        XCTAssertEqual(during?[5] as? Double, 0, "leading-aligned over the address")
        XCTAssertEqual(during?[6] as? Bool, true, "in ink, the name line's colour")

        _ = try await evaluate("window.ss.addressCopied(\(ConversationShellAssets.jsStringLiteral(messageKey)), 'cc:1', 'address')",
                               in: webView)
        let short = try await evaluate("\(part)('cc:1', '.ss-cpa')", in: webView) as? [Any]
        XCTAssertEqual(short?[4] as? Bool, true, "the checkmark alone over a short address")
        let marks = try await evaluate("[document.querySelectorAll('.ss-mark').length, document.querySelectorAll('.ss-copied').length]",
                                       in: webView) as? [Int]
        XCTAssertEqual(marks, [1, 1], "one mark at a time")

        _ = try await evaluate("window.ss.addressCopied(\(ConversationShellAssets.jsStringLiteral(messageKey)), 'cc:0', 'nameAndAddress')",
                               in: webView)
        let whole = try await evaluate("\(part)('cc:0', '.ss-cpc')", in: webView) as? [Any]
        XCTAssertEqual(whole?[2] as? Bool, true, "Copy Name and Address: the whole recipient gives way")
        let flags = "[{\"id\": \(ConversationShellAssets.jsStringLiteral(messageKey)), \"isUnread\": false, \"isStarred\": true}]"
        _ = try await evaluate("window.ss.flags(\(flags))", in: webView)
        let kept = try await evaluate("\(part)('cc:0', '.ss-cpc')", in: webView) as? [Any]
        XCTAssertEqual(kept?[2] as? Bool, true, "a re-render of the header keeps the mark")

        // The hold is the token's; shortened here, it ends and the text comes back.
        _ = try await evaluate("""
            document.documentElement.style.setProperty('--q-dur-copiedConfirm', '150ms');
            window.ss.addressCopied(\(ConversationShellAssets.jsStringLiteral(messageKey)), 'to:0', 'address')
            """, in: webView)
        try await Task.sleep(nanoseconds: 700_000_000)
        let gone = try await evaluate("[document.querySelectorAll('.ss-mark').length, document.querySelectorAll('.ss-copied, .ss-uncopy').length]",
                                      in: webView) as? [Int]
        XCTAssertEqual(gone, [0, 0], "the mark leaves after the hold")
        let missing = try await evaluate("window.ss.addressCopied('nobody', 'to:0', 'address')", in: webView) as? Bool
        XCTAssertEqual(missing, false)
    }

    /// The focus report tells the app which keys are the page's: on a recipient ↩ Space ← → and Esc, with the position ⌘C
    /// copies; on the toggle ↩ and Space; on the sender's address ↩ and Space with its position, ← staying the app's.
    func testTheFocusReportNamesWhatTheKeysDo() async throws {
        let (webView, messages) = try await openList()
        func report(after script: String) async throws -> [String: Any]? {
            let count = messages.received.count
            _ = try await evaluate(script + "; true", in: webView)
            for _ in 0..<50 {
                if let last = messages.received.dropFirst(count).last(where: { ($0["kind"] as? String) == "focusMark" }) { return last }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            return nil
        }
        let recipient = try await report(after: "document.querySelector('.ss-rp[data-addr=\"to:1\"]').focus()")
        XCTAssertEqual(recipient?["on"] as? Bool, true)
        XCTAssertEqual(recipient?["arrows"] as? Bool, true)
        XCTAssertEqual(recipient?["addresses"] as? Bool, true)
        XCTAssertEqual((recipient?["address"] as? [String: Any])?["value"] as? String, "to:1")
        XCTAssertEqual((recipient?["address"] as? [String: Any])?["messageID"] as? String, messageKey)

        let toggle = try await report(after: "document.querySelector('.ss-rc').focus()")
        XCTAssertEqual(toggle?["on"] as? Bool, true, "Space on the toggle is no Quick Look")
        XCTAssertEqual(toggle?["arrows"] as? Bool, false)
        XCTAssertEqual(toggle?["addresses"] as? Bool, false)
        XCTAssertNil(toggle?["address"])

        let sender = try await report(after: "document.querySelector('.ss-addr').focus()")
        XCTAssertEqual(sender?["on"] as? Bool, true)
        XCTAssertEqual(sender?["arrows"] as? Bool, false, "← goes back to the list from the sender's address")
        XCTAssertEqual(sender?["addresses"] as? Bool, false)
        XCTAssertEqual((sender?["address"] as? [String: Any])?["value"] as? String, "from:0")

        let away = try await report(after: "document.activeElement.blur()")
        XCTAssertEqual(away?["on"] as? Bool, false)
        XCTAssertNil(away?["address"])
    }

    /// VoiceOver: the list is a group of groups, each recipient a button named by what it shows without the brackets, its
    /// help the tooltip; the sender's address is a button named by the address.
    func testVoiceOverNamesTheTargets() async throws {
        let (webView, _) = try await openList()
        let names = try await evaluate("""
            Array.prototype.map.call(document.querySelectorAll('.ss-rp'), function (n) {
              return [n.getAttribute('role'), n.getAttribute('aria-label'), n.title].join(' | ');
            })
            """, in: webView) as? [String]
        XCTAssertEqual(names, [
            "button | me, me@example.com | Copy Address", "button | Bob, bob@example.com | Copy Address",
            "button | plain@example.com | Copy Address", "button | x@y.io | Copy Address",
            "button | Carol, carol@example.com | Copy Address", "button | x@y.io | Copy Address",
        ])
        let groups = try await evaluate("""
            [document.querySelector('.ss-rcx').getAttribute('role'), document.querySelector('.ss-rcx').getAttribute('aria-label')]
              .concat(Array.prototype.map.call(document.querySelectorAll('.ss-rcf'), function (r) {
                return r.getAttribute('role') + ' ' + r.getAttribute('aria-label') + ' ' + r.querySelector('.ss-rcl').getAttribute('aria-hidden');
              }))
            """, in: webView) as? [String]
        XCTAssertEqual(groups, ["group", "Recipients", "group To true", "group Cc true"])
        let sender = try await evaluate("""
            (function () { var a = document.querySelector('.ss-addr');
              return [a.getAttribute('role'), a.getAttribute('aria-label'), a.title, a.tabIndex].join(' | '); })()
            """, in: webView) as? String
        XCTAssertEqual(sender, "button | ada@example.com | Copy Address | 0")
        let direction = try await evaluate("""
            [document.querySelector('.ss-rp[data-addr="to:1"] .ss-rpn').dir, document.querySelector('.ss-rp[data-addr="to:1"] .ss-rpa').dir]
            """, in: webView) as? [String]
        XCTAssertEqual(direction, ["auto", "ltr"], "an Arabic or Hebrew name keeps its address readable")
    }

    /// A sender with no name apart from the address shows the address as the name, and the name is then the target.
    func testANamelessSendersNameIsTheTarget() async throws {
        let (webView, _) = try await loadedShell()
        let alone = EmailAddress(name: "solo@example.com", address: "solo@example.com")
        let message = F.message("m1", from: alone, date: F.utc(2025, 3, 6, 9, 0))
        let payload = F.builder.build(messages: [message], bodies: [message.id: F.body(html: "<p>Hi</p>")], accounts: F.accounts,
                                      now: F.utc(2025, 3, 20, 9, 0))
        _ = try await evaluate("window.ss.render(\(try payload.jsonString()))", in: webView)
        let line = try await evaluate("""
            (function () { var n = document.querySelector('.ss-nl .ss-name');
              return [n.className, n.dataset.addr, n.getAttribute('role'), String(!!document.querySelector('.ss-addr')),
                      getComputedStyle(n).webkitUserSelect || getComputedStyle(n).userSelect].join(' | '); })()
            """, in: webView) as? String
        XCTAssertEqual(line, "ss-name ss-namet ss-cpt | from:0 | button | false | none")
    }

    /// When Unsubscribe and a long name leave the sender's address less than a hit target, it hides and leaves the Tab
    /// order; a wider reader gives it back.
    func testTheSqueezedAddressHidesAndLeavesTheTabOrder() async throws {
        let (webView, _) = try await loadedShell(width: 520)
        var newsletter = F.message("m1", from: EmailAddress(name: "The New York Times Opinion Today", address: "nytdirect@nytimes.com"),
                                   date: F.utc(2025, 3, 6, 9, 0), isRead: false)
        newsletter.listUnsubscribe = "<https://news.example.com/u/1>"
        let payload = F.builder.build(messages: [newsletter], bodies: [newsletter.id: F.body(html: "<p>Issue</p>")], accounts: F.accounts,
                                      now: F.utc(2025, 3, 20, 9, 0))
        _ = try await evaluate("window.ss.render(\(try payload.jsonString()))", in: webView)
        let probe = """
            (function () { var a = document.querySelector('.ss-addr');
              return [a.classList.contains('ss-squeezed'), a.tabIndex, a.getAttribute('aria-hidden') || '', getComputedStyle(a).visibility].join(' '); })()
            """
        let narrow = try await evaluate(probe, in: webView) as? String
        XCTAssertEqual(narrow, "true -1 true hidden")

        webView.setFrameSize(NSSize(width: 900, height: 600))
        var wide = ""
        for _ in 0..<50 {
            wide = try await evaluate(probe, in: webView) as? String ?? ""
            if wide.hasPrefix("false") { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(wide, "false 0  visible")
    }

    /// The pointer: the hand over a recipient's whole 24 pt pitch, its face 20 pt inside it; the open list's labels are
    /// text that cannot be selected, which WebKit gives the arrow; the sender's name stays selectable, with the I-beam.
    /// Hit rects tile: just above and below the line between two lines of recipients lie two different targets, and the
    /// sender's address reaches up into the sheet's padding but not down onto the toggle, whose hit reaches 8 pt below
    /// its line.
    func testThePointerAndHitRects() async throws {
        let crowd = (1...12).map { EmailAddress(name: "Guest \($0)", address: "guest\($0)@example.com") }
        let (webView, _) = try await openList(to: crowd, cc: [], width: 620)
        let probe = """
            (function () {
              var rp = document.querySelector('.ss-rp'), face = rp.querySelector('.ss-face'), r = rp.getBoundingClientRect();
              var out = [Math.round(r.height), Math.round(face.getBoundingClientRect().height),
                         getComputedStyle(rp).cursor, getComputedStyle(face).cursor, getComputedStyle(rp.querySelector('.ss-rpa')).cursor];
              // WebKit hit-tests whole points, so the edges are probed a point inside them.
              var top = document.elementFromPoint(r.left + 6, r.top + 1), bottom = document.elementFromPoint(r.left + 6, r.bottom - 1);
              out.push(!!top && top.closest('.ss-rp') === rp, !!bottom && bottom.closest('.ss-rp') === rp);
              var label = document.querySelector('.ss-rcl');
              out.push(getComputedStyle(label).cursor, getComputedStyle(label).webkitUserSelect || getComputedStyle(label).userSelect);
              var name = document.querySelector('.ss-nl .ss-name');
              out.push(getComputedStyle(name).cursor, getComputedStyle(name).webkitUserSelect || getComputedStyle(name).userSelect);
              var lines = [], tops = {};
              document.querySelectorAll('.ss-rp').forEach(function (n) { var t = Math.round(n.getBoundingClientRect().top); if (!tops[t]) { tops[t] = n; lines.push(t); } });
              var boundary = lines[1], x = tops[lines[1]].getBoundingClientRect().left + 6;
              var above = document.elementFromPoint(x, boundary - 1), below = document.elementFromPoint(x, boundary + 1);
              out.push(lines.length > 1, !!above && !!above.closest('.ss-rp'), !!below && !!below.closest('.ss-rp'),
                       !!above && !!below && above.closest('.ss-rp') !== below.closest('.ss-rp'));
              var a = document.querySelector('.ss-addr'), ar = a.querySelector('.ss-face').getBoundingClientRect();
              var up = document.elementFromPoint(ar.left + 6, ar.top - 5), down = document.elementFromPoint(ar.left + 6, ar.bottom + 1);
              out.push(!!up && up.closest('.ss-addr') === a, !down || !down.closest('.ss-addr'));
              var words = document.querySelector('.ss-rct').getBoundingClientRect();
              var under = document.elementFromPoint(words.left + 4, words.bottom + 6);
              out.push(!!under && !!under.closest('.ss-rc'));
              return out;
            })()
            """
        let result = try await evaluate(probe, in: webView) as? [Any]
        XCTAssertEqual(result?[0] as? Int, 24, "the pitch is the hit")
        XCTAssertEqual(result?[1] as? Int, 20, "the face inside it")
        XCTAssertEqual(result?[2] as? String, "pointer")
        XCTAssertEqual(result?[3] as? String, "pointer")
        XCTAssertEqual(result?[4] as? String, "pointer")
        XCTAssertEqual(result?[5] as? Bool, true, "the hand at the pitch's top edge, outside the face")
        XCTAssertEqual(result?[6] as? Bool, true, "and at its bottom edge")
        XCTAssertEqual(result?[7] as? String, "auto")
        XCTAssertEqual(result?[8] as? String, "none", "a label is text that cannot be selected: the arrow")
        XCTAssertEqual(result?[9] as? String, "auto")
        XCTAssertEqual(result?[10] as? String, "text", "the sender's name stays text: the I-beam")
        XCTAssertEqual(result?[11] as? Bool, true, "the crowd takes more than one line")
        XCTAssertEqual(result?[12] as? Bool, true)
        XCTAssertEqual(result?[13] as? Bool, true)
        XCTAssertEqual(result?[14] as? Bool, true, "one target above the line between two lines, another below")
        XCTAssertEqual(result?[15] as? Bool, true, "the sender's address reaches up into the sheet's padding")
        XCTAssertEqual(result?[16] as? Bool, true, "and never down onto the toggle")
        XCTAssertEqual(result?[17] as? Bool, true, "the toggle's hit reaches below its line")
    }

    /// Past eight lines the list stops at “and N more”, which ends the eighth line; pressing it shows the rest and moves
    /// focus to the first recipient it shows.
    func testTheListStopsAtEightLines() async throws {
        let crowd = (1...80).map { EmailAddress(name: "Guest \($0)", address: "guest\($0)@example.com") }
        let (webView, _) = try await openList(to: crowd, cc: [])
        let probe = """
            (function () {
              var list = document.querySelector('.ss-rcx'), top = list.getBoundingClientRect().top, tops = {};
              var shown = Array.prototype.filter.call(list.querySelectorAll('.ss-rp, .ss-more'), function (n) { return n.getClientRects().length; });
              shown.forEach(function (n) { tops[Math.round(n.getBoundingClientRect().top)] = true; });
              var more = list.querySelector('.ss-more');
              return [Object.keys(tops).length, more ? more.textContent : '', more ? Math.round(more.getBoundingClientRect().top - top) : -1,
                      shown.length - (more ? 1 : 0)];
            })()
            """
        let capped = try await evaluate(probe, in: webView) as? [Any]
        XCTAssertEqual(capped?[0] as? Int, 8, "eight lines")
        let shown = capped?[3] as? Int ?? 0
        XCTAssertEqual(capped?[1] as? String, "and \(80 - shown) more")
        XCTAssertEqual(capped?[2] as? Int, 7 * 24, "on the eighth line")
        let after = try await evaluate("""
            document.querySelector('.ss-more').click();
            [document.querySelectorAll('.ss-rp').length, Array.prototype.filter.call(document.querySelectorAll('.ss-rp'), function (n) { return n.getClientRects().length; }).length,
             document.activeElement.dataset.addr, !!document.querySelector('.ss-more')]
            """, in: webView) as? [Any]
        XCTAssertEqual(after?[0] as? Int, 80)
        XCTAssertEqual(after?[1] as? Int, 80, "the rest shows")
        XCTAssertEqual(after?[2] as? String, "to:\(shown)", "focus moves to the first recipient it shows")
        XCTAssertEqual(after?[3] as? Bool, false)
    }

    /// A right-click on a recipient, the sender's name, address or avatar asks for the person menu by position, and its
    /// target keeps the hover face until the menu closes; a label keeps the conversation's menu.
    func testTheRightClickAsksForThePersonMenu() async throws {
        let (webView, messages) = try await openList()
        func rightClick(_ selector: String) async throws {
            _ = try await evaluate("""
                (function () { var n = document.querySelector(\(ConversationShellAssets.jsStringLiteral(selector))), r = n.getBoundingClientRect();
                  n.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: r.left + 3, clientY: r.top + 3 })); return true; })()
                """, in: webView)
        }
        func lastAction() async throws -> [String: Any]? {
            try await Task.sleep(nanoseconds: 100_000_000)
            return messages.received.last { ($0["kind"] as? String) == "action" }
        }
        try await rightClick(".ss-rp[data-addr=\"cc:0\"] .ss-rpa")
        var asked = try await lastAction()
        XCTAssertEqual(asked?["type"] as? String, "personMenu")
        XCTAssertEqual(asked?["value"] as? String, "cc:0")
        XCTAssertNotNil(asked?["x"])
        let marked = try await evaluate("document.querySelector('.ss-rp[data-addr=\"cc:0\"]').classList.contains('ss-menu')", in: webView) as? Bool
        XCTAssertEqual(marked, true, "it keeps the hover face while the menu is open")
        _ = try await evaluate("window.ss.personMenuClosed()", in: webView)
        let cleared = try await evaluate("document.querySelectorAll('.ss-menu').length", in: webView) as? Int
        XCTAssertEqual(cleared, 0)

        for sender in [".ss-nl .ss-name", ".ss-addr", ".ss-head .ss-av"] {
            try await rightClick(sender)
            asked = try await lastAction()
            XCTAssertEqual(asked?["type"] as? String, "personMenu", sender)
            XCTAssertEqual(asked?["value"] as? String, "from:0", sender)
        }
        try await rightClick(".ss-rcl")
        asked = try await lastAction()
        XCTAssertEqual(asked?["type"] as? String, "messageMenu", "a label keeps the conversation's menu")
    }

    // MARK: Helpers

    private var messageKey: String { RenderPayload.messageKey(for: MessageID(accountID: F.accountID, providerID: "m1")) }

    /// One message from Ada to the user, Bob, an unnamed recipient and a short one, copying Carol and another short one.
    private func payload(to: [EmailAddress]? = nil, cc: [EmailAddress]? = nil) -> RenderPayload {
        let shortOne = EmailAddress(address: "x@y.io")
        let message = F.message("m1", to: to ?? [F.me, F.bob, EmailAddress(address: "plain@example.com"), shortOne],
                                cc: cc ?? [F.carol, shortOne], date: F.utc(2025, 3, 6, 9, 0))
        return F.builder.build(messages: [message], bodies: [message.id: F.body(html: "<p>Hi</p>")], accounts: F.accounts,
                               now: F.utc(2025, 3, 20, 9, 0))
    }

    /// The shell with the one message rendered and its list open.
    private func openList(to: [EmailAddress]? = nil, cc: [EmailAddress]? = nil, width: CGFloat = 800) async throws -> (WKWebView, ShellMessages) {
        let (webView, messages) = try await loadedShell(width: width)
        _ = try await evaluate("window.ss.render(\(try payload(to: to, cc: cc).jsonString()))", in: webView)
        _ = try await evaluate("document.querySelector('.ss-rc').click(); true", in: webView)
        let open = try await evaluate("!!document.querySelector('.ss-rcx')", in: webView) as? Bool
        XCTAssertEqual(open, true)
        return (webView, messages)
    }

    private func copies(in messages: ShellMessages) -> [[String: Any]] {
        messages.received.filter { ($0["kind"] as? String) == "action" && ($0["type"] as? String) == "copyAddress" }
    }

    private func waitForCopies(_ count: Int, in messages: ShellMessages) async throws -> [[String: Any]] {
        for _ in 0..<50 where copies(in: messages).count < count {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let found = copies(in: messages)
        XCTAssertEqual(found.count, count)
        return found
    }

    private final class ShellMessages: NSObject, WKScriptMessageHandler {
        private(set) var isReady = false
        private(set) var received: [[String: Any]] = []

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any] { received.append(body) }
            if message.name == ConversationShellAssets.readyHandlerName { isReady = true }
        }
    }

    /// WebKit stalls a `loadHTMLString` whose base scheme has no handler, so the test registers one as the app does.
    private final class SchemeStub: NSObject, WKURLSchemeHandler {
        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])
            else {
                urlSchemeTask.didFailWithError(URLError(.badURL))
                return
            }
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didFinish()
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
    }

    private var configuration: WKWebViewConfiguration?
    private let schemes = SchemeStub()

    override func tearDown() {
        configuration?.userContentController.removeAllScriptMessageHandlers()
        configuration = nil
        super.tearDown()
    }

    /// The shell in a web view, once it has signalled ready. Skips unless `SS_UI_TESTS=1`.
    private func loadedShell(width: CGFloat = 800) async throws -> (WKWebView, ShellMessages) {
        guard ProcessInfo.processInfo.environment["SS_UI_TESTS"] == "1" else {
            throw XCTSkip("Set SS_UI_TESTS=1 to drive WebKit")
        }
        let handler = ShellMessages()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(schemes, forURLScheme: ConversationShellAssets.scheme)
        configuration.userContentController.add(handler, name: ConversationShellAssets.readyHandlerName)
        configuration.userContentController.add(handler, name: ConversationShellAssets.messageHandlerName)
        self.configuration = configuration
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 600), configuration: configuration)
        webView.appearance = NSAppearance(named: .aqua)
        webView.loadHTMLString(ConversationShellAssets.html, baseURL: ConversationShellAssets.baseURL)
        var attempts = 0
        while !handler.isReady, attempts < 200 {
            try await Task.sleep(nanoseconds: 100_000_000)
            attempts += 1
        }
        guard handler.isReady else { throw XCTSkip("no shell") }
        return (webView, handler)
    }

    private func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }
}
