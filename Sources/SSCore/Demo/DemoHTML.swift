import Foundation

/// The HTML shapes real clients produce, reproduced closely enough to exercise the sanitizer, the quote
/// detector and the reader: Gmail's `gmail_quote` blocks, Outlook's `divRplyFwdMsg` headers, table-layout
/// newsletters with remote images, and transactional cards.
enum DemoHTML {
    enum QuoteStyle {
        case gmail
        case outlook
    }

    struct Quoted {
        let from: EmailAddress
        let to: EmailAddress
        let date: Date
        let subject: String
        /// The quoted message's own fragment, quotes included, so threads nest the way clients nest them.
        let fragment: String
        let text: String
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    private static let gmailAttribution = formatter("EEE, MMM d, yyyy 'at' h:mm a")
    private static let outlookSent = formatter("EEEE, MMMM d, yyyy h:mm a")
    private static let plainAttribution = formatter("EEE, MMM d, yyyy, h:mm a")

    static func addressHTML(_ address: EmailAddress) -> String {
        "\(escape(address.name ?? address.address)) &lt;<a href=\"mailto:\(escape(address.address))\">\(escape(address.address))</a>&gt;"
    }

    /// One human-written message: the new text as paragraphs, an optional inline image, then the quote.
    static func personal(
        text: String,
        style: QuoteStyle,
        quoted: Quoted?,
        inlineImageCID: String?
    ) -> (fragment: String, html: String, text: String) {
        let paragraphs = text.split(separator: "\n").map { "<div>\(escape(String($0)))</div>" }.joined(separator: "<div><br></div>")
        var fragment: String
        switch style {
        case .gmail:
            fragment = "<div dir=\"ltr\">\(paragraphs)"
            if let cid = inlineImageCID {
                fragment += "<div><br></div><div><img src=\"cid:\(cid)\" alt=\"sunset.png\" width=\"320\" height=\"200\" style=\"max-width:100%\"><br></div>"
            }
            fragment += "</div>"
        case .outlook:
            fragment = "<div style=\"font-family:Aptos,Calibri,Helvetica,sans-serif;font-size:12pt;color:rgb(0,0,0)\">\(paragraphs)"
            if let cid = inlineImageCID {
                fragment += "<div><img src=\"cid:\(cid)\" alt=\"sunset.png\" width=\"320\" height=\"200\"></div>"
            }
            fragment += "</div>"
        }
        var plain = text
        if let quoted {
            switch style {
            case .gmail:
                fragment += """
                <br><div class="gmail_quote"><div dir="ltr" class="gmail_attr">On \(gmailAttribution.string(from: quoted.date)) \
                \(addressHTML(quoted.from)) wrote:<br></div><blockquote class="gmail_quote" \
                style="margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex">\(quoted.fragment)</blockquote></div>
                """
            case .outlook:
                fragment += """
                <div id="appendonsend"></div><hr style="display:inline-block;width:98%" tabindex="-1">\
                <div id="divRplyFwdMsg" dir="ltr"><font face="Calibri, sans-serif" style="font-size:11pt" color="#000000">\
                <b>From:</b> \(escape(quoted.from.name ?? quoted.from.address)) &lt;\(escape(quoted.from.address))&gt;<br>\
                <b>Sent:</b> \(outlookSent.string(from: quoted.date))<br>\
                <b>To:</b> \(escape(quoted.to.name ?? quoted.to.address)) &lt;\(escape(quoted.to.address))&gt;<br>\
                <b>Subject:</b> \(escape(quoted.subject))</font><div>&nbsp;</div></div><div>\(quoted.fragment)</div>
                """
            }
            let quotedLines = quoted.text.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }
            plain += "\n\nOn \(plainAttribution.string(from: quoted.date)) \(quoted.from.name ?? quoted.from.address) <\(quoted.from.address)> wrote:\n"
                + quotedLines.joined(separator: "\n")
        }
        let html: String
        switch style {
        case .gmail:
            html = fragment
        case .outlook:
            html = """
            <html><head><meta http-equiv="Content-Type" content="text/html; charset=utf-8">\
            <style type="text/css" style="display:none;">P {margin-top:0;margin-bottom:0;}</style></head>\
            <body dir="ltr">\(fragment)</body></html>
            """
        }
        return (fragment, html, plain)
    }

    /// A classic 600px table-layout newsletter: header band, hero image (remote, so it is blocked by default),
    /// stories with "Read more" links and a footer with the unsubscribe link and the open pixel senders put there.
    ///
    /// `trackerSample` makes it the demo's tracker sample (spec §5.60, `DemoTrackerSample`): its hero and a row of
    /// product tiles are remote images the demo answers on this Mac (`DemoStandInSanitizer`), and it carries two trackers
    /// more, a known open-tracking endpoint (SendGrid's, on the sender's own link domain) and a pixel its style hides.
    static func newsletter(_ letter: DemoCatalog.Newsletter, issue: Int, date: Date, stories: [(String, String)],
                           trackerSample: Bool = false) -> (html: String, text: String) {
        let domain = letter.sender.address.split(separator: "@").last.map(String.init) ?? "news.test"
        let dateLine = formatter("EEEE, MMMM d").string(from: date)
        var rows = ""
        for (index, story) in stories.enumerated() {
            rows += """
            <tr><td style="padding:20px 32px 0 32px;font-family:Georgia,'Times New Roman',serif;">\
            <h2 style="margin:0 0 8px 0;font-size:20px;line-height:26px;color:#111111;">\(escape(story.0))</h2>\
            <p style="margin:0 0 12px 0;font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:15px;line-height:22px;color:#444444;">\(escape(story.1))</p>\
            <a href="https://\(domain)/issues/\(issue)/\(index + 1)" style="font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:14px;color:\(letter.accent);font-weight:600;text-decoration:none;">Read more →</a>\
            </td></tr>
            """
        }
        let html = """
        <!DOCTYPE html><html><head><meta name="viewport" content="width=device-width"><style>\
        @media (max-width: 620px) { .container { width: 100% !important; } }\
        </style></head><body style="margin:0;padding:0;background:#f2f2f2;">\
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#f2f2f2;">\
        <tr><td align="center" style="padding:24px 8px;">\
        <table role="presentation" class="container" width="600" cellpadding="0" cellspacing="0" border="0" style="background:#ffffff;border-radius:6px;overflow:hidden;">\
        <tr><td style="background:\(letter.accent);padding:24px 32px;font-family:-apple-system,Helvetica,Arial,sans-serif;">\
        <div style="font-size:26px;font-weight:700;color:#ffffff;">\(escape(letter.title))</div>\
        <div style="font-size:14px;color:rgba(255,255,255,0.85);margin-top:4px;">\(escape(letter.tagline)) · Issue #\(issue) · \(escape(dateLine))</div>\
        </td></tr>\
        <tr><td><img src="\(trackerSample ? DemoStandInSanitizer.address("trailhead-hero.svg") : "https://images.\(domain)/issues/\(issue)/hero.jpg")" \
        width="600" height="240" alt="" style="display:block;width:100%;height:auto;"></td></tr>\
        \(trackerSample ? productRow(letter) : "")\
        \(rows)\
        <tr><td style="padding:28px 32px;font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:12px;line-height:18px;color:#888888;border-top:1px solid #eeeeee;">\
        You are receiving this because you subscribed at \(escape(domain)).<br>\
        <a href="https://\(domain)/preferences" style="color:#888888;">Manage preferences</a> · <a href="https://\(domain)/unsubscribe" style="color:#888888;">Unsubscribe</a>\
        <img src="https://track.\(domain)/open.gif?i=\(issue)" width="1" height="1" alt="">\
        \(trackerSample ? samplePixels(domain: domain, issue: issue) : "")\
        </td></tr></table></td></tr></table></body></html>
        """
        let text = "\(letter.title) · Issue #\(issue)\n\n" + stories.map { "\($0.0)\n\($0.1)" }.joined(separator: "\n\n")
        return (html, text)
    }

    /// Three product tiles under the hero of the tracker sample, each a remote image the demo answers on this Mac.
    private static func productRow(_ letter: DemoCatalog.Newsletter) -> String {
        let tiles = [("trailhead-pack.svg", "Daypacks"), ("trailhead-lamp.svg", "Headlamps"), ("trailhead-mug.svg", "Camp kitchen")]
        let cells = tiles.map { file, name in
            """
            <td width="33%" style="padding:0 6px;text-align:center;font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:13px;color:#444444;">\
            <img src="\(DemoStandInSanitizer.address(file))" width="168" height="112" alt="\(escape(name))" \
            style="display:block;width:100%;height:auto;border-radius:4px;margin-bottom:6px;">\(escape(name))</td>
            """
        }.joined()
        return """
            <tr><td style="padding:20px 26px 0 26px;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">\
            <tr>\(cells)</tr></table></td></tr>
            """
    }

    /// The tracker sample's two extra pixels: SendGrid's open endpoint on the sender's own link domain, which the rules
    /// know by its path and parameter, and a pixel of ordinary size that its style hides.
    private static func samplePixels(domain: String, issue: Int) -> String {
        "<img src=\"https://url4417.\(domain)/wf/open?upn=demo-\(issue)-a1b2c3\" alt=\"\" width=\"1\" height=\"1\" border=\"0\" "
            + "style=\"height:1px !important;width:1px !important\">"
            + "<img src=\"https://px.\(domain)/v/\(issue)/open.png\" alt=\"\" width=\"600\" height=\"40\" style=\"display:none\">"
    }

    /// A transactional notification card with a single call-to-action button.
    static func notification(_ family: DemoCatalog.Notification, subject: String, line: String) -> (html: String, text: String) {
        let domain = family.sender.address.split(separator: "@").last.map(String.init) ?? "notify.test"
        let html = """
        <div style="background:#f6f8fa;padding:24px;font-family:-apple-system,Helvetica,Arial,sans-serif;">\
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;margin:0 auto;background:#ffffff;border:1px solid #e1e4e8;border-radius:6px;">\
        <tr><td style="padding:20px 24px;border-bottom:1px solid #e1e4e8;font-weight:600;font-size:14px;color:\(family.accent);">\(escape(family.sender.name))</td></tr>\
        <tr><td style="padding:20px 24px;font-size:15px;line-height:22px;color:#24292f;">\
        <p style="margin:0 0 12px 0;font-weight:600;">\(escape(subject))</p>\
        <p style="margin:0 0 20px 0;">\(escape(line))</p>\
        <a href="https://\(domain)/go" style="display:inline-block;background:\(family.accent);color:#ffffff;padding:10px 16px;border-radius:6px;text-decoration:none;font-weight:600;font-size:14px;">\(escape(family.button))</a>\
        </td></tr></table>\
        <p style="text-align:center;font-size:12px;color:#6a737d;margin-top:16px;">You're receiving this email because of your account settings at \(escape(domain)).</p></div>
        """
        // The subject is already the row title; the text part (and so the snippet) starts with what is new.
        return (html, "\(line)\n\n\(family.button): https://\(domain)/go")
    }
}
