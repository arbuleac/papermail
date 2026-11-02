import Foundation

/// Bodies shaped like what Gmail, Outlook, Apple Mail, Fastmail and bulk senders actually produce, anonymized.
enum MailShapeFixtures {
    static let gmailReply = #"""
    <div dir="ltr">Thanks, that works for me.<div><br></div><div>Best,<br>Alice</div></div><br><div class="gmail_quote"><div dir="ltr" class="gmail_attr">On Mon, Oct 27, 2025 at 9:14 AM Bob Example &lt;<a href="mailto:bob@example.com">bob@example.com</a>&gt; wrote:<br></div><blockquote class="gmail_quote" style="margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex"><div dir="ltr">Hi Alice,<div>Can we move the meeting to Thursday?</div><div><br></div><div>Bob</div></div></blockquote></div>
    """#

    static let outlookWebReply = #"""
    <html><head><meta http-equiv="Content-Type" content="text/html; charset=utf-8"><style type="text/css" style="display:none">p{margin-top:0;margin-bottom:0}</style></head><body dir="ltr"><div class="elementToProof" style="font-family: Aptos, sans-serif; font-size: 12pt; color: rgb(0, 0, 0);">Sounds good, see you then.</div><div id="appendonsend"></div><hr style="display:inline-block;width:98%" tabindex="-1"><div id="divRplyFwdMsg" dir="ltr"><font face="Calibri, sans-serif" style="font-size:11pt" color="#000000"><b>From:</b> Bob Example &lt;bob@example.com&gt;<br><b>Sent:</b> Monday, October 27, 2025 9:14 AM<br><b>To:</b> Alice Example &lt;alice@example.com&gt;<br><b>Subject:</b> Meeting</font><div>&nbsp;</div></div><div dir="ltr"><div style="font-family: Aptos, sans-serif; font-size: 12pt;">Can we move the meeting to Thursday?</div></div></body></html>
    """#

    static let outlookDesktopReply = #"""
    <div class="WordSection1"><p class="MsoNormal">Yes, Thursday works.</p><p class="MsoNormal">&nbsp;</p><div style="border:none;border-top:solid #E1E1E1 1.0pt;padding:3.0pt 0in 0in 0in"><p class="MsoNormal"><b>From:</b> Bob Example &lt;bob@example.com&gt; <br><b>Sent:</b> Monday, October 27, 2025 9:14 AM<br><b>To:</b> Alice Example &lt;alice@example.com&gt;<br><b>Subject:</b> Meeting</p></div><p class="MsoNormal">&nbsp;</p><p class="MsoNormal">Can we move the meeting to Thursday?</p></div>
    """#

    static let appleMailReply = #"""
    <html><head><meta http-equiv="Content-Type" content="text/html charset=utf-8"></head><body style="word-wrap: break-word; -webkit-nbsp-mode: space; line-break: after-white-space;" class="">Works for me.<div class=""><br class=""></div><div class="">Alice</div><div class=""><br class=""><blockquote type="cite" class=""><div class="">On 27 Oct 2025, at 09:14, Bob Example &lt;<a href="mailto:bob@example.com" class="">bob@example.com</a>&gt; wrote:</div><br class="Apple-interchange-newline"><div class=""><div dir="auto" class="">Can we move the meeting to Thursday?</div></div></blockquote></div><br class=""></body></html>
    """#

    static let fastmailReply = #"""
    <!DOCTYPE html><html><head><title></title><style type="text/css">p.MsoNormal,p.MsoNoSpacing{margin:0}</style></head><body><div>Thursday works, see you then.</div><div><br></div><div>Alice</div><div><br></div><div>On Mon, 27 Oct 2025, at 09:14, Bob Example wrote:</div><blockquote type="cite" id="qt" style=""><div dir="ltr">Hi Alice,<div>Can we move the meeting to Thursday?</div><div><br></div><div>Bob</div></div></blockquote><div><br></div></body></html>
    """#

    static let yahooReply = #"""
    <div class="ydp1234yahoo-style-wrap"><div>Fine by me.</div></div><div id="yahoo_quoted_123" class="yahoo_quoted"><div style="font-family:Helvetica;font-size:13px;color:#26282a;"><div>On Monday, October 27, 2025 at 09:14:00 AM GMT+1, Bob Example &lt;bob@example.com&gt; wrote:</div><div><br></div><div id="yiv123"><div>Can we move the meeting to Thursday?</div></div></div></div>
    """#

    static let genericReply = #"""
    <p>Agreed.</p><p>On Mon, Oct 27, 2025 at 9:14 AM, Bob Example wrote:</p><blockquote><p>Can we move the meeting to Thursday?</p></blockquote>
    """#

    static let newsletter = #"""
    <!DOCTYPE html><html><head><meta charset="utf-8"><title>Weekly</title><style>body{margin:0;background:#f4f4f4}.hero{background:url(https://cdn.example/hero.jpg) center/cover} td{font-family:Helvetica,Arial,sans-serif}</style></head><body style="margin:0;padding:0;background-color:#f4f4f4"><table width="100%" cellpadding="0" cellspacing="0" style="background-color:#f4f4f4"><tr><td align="center" style="padding:20px"><table width="600" cellpadding="0" cellspacing="0" style="background-color:#ffffff;border-radius:8px"><tr><td class="hero" style="padding:24px;background-image:url(https://cdn.example/hero.jpg)"><img src="https://cdn.example/logo.png" width="120" height="40" alt="Acme" style="display:block;border:0"></td></tr><tr><td style="padding:24px;font-size:16px;line-height:24px;color:#333333"><h1 style="margin:0 0 12px;font-size:24px">This week at Acme</h1><p style="margin:0 0 16px">Three things worth your time.</p><a href="https://acme.example/read?utm=1&amp;id=7" style="color:#1a73e8;text-decoration:none">Read more</a></td></tr><tr><td style="padding:16px;background-color:#eeeeee;font-size:12px;color:#777777"><img src="https://track.example/open.gif?id=42" width="1" height="1" alt=""><a href="https://acme.example/unsubscribe">Unsubscribe</a></td></tr></table></td></tr></table></body></html>
    """#

    static let inlineImage = #"""
    <div>Here is the chart:</div><img src="cid:<chart.png@01DB2F3A.5F2C1E80>" width="400"><div>And the logo:</div><img src="cid:my logo.png"><p>Done</p>
    """#

    /// A newsletter of roughly `approximateBytes` built from repeated table rows with inline styles, remote
    /// images and tracked links, the shape that dominates real mailboxes.
    static func largeNewsletter(approximateBytes: Int) -> String {
        var rows = ""
        var index = 0
        while rows.utf8.count < approximateBytes {
            rows += #"""
            <tr><td style="padding:16px 24px;font-family:Helvetica,Arial,sans-serif;font-size:15px;line-height:22px;color:#333333;border-bottom:1px solid #eeeeee"><table width="100%" cellpadding="0" cellspacing="0"><tr><td width="120" valign="top"><img src="https://cdn.example/thumb\#(index).jpg" width="104" height="78" alt="Story \#(index)" style="display:block;border-radius:4px"></td><td valign="top"><h3 style="margin:0 0 6px;font-size:17px;color:#111111">Story number \#(index): a headline long enough to wrap onto a second line</h3><p style="margin:0 0 8px">A short summary of the story with <b>bold</b>, <i>italic</i> and a <a href="https://acme.example/story/\#(index)?utm_source=newsletter&amp;utm_medium=email&amp;utm_campaign=weekly" style="color:#1a73e8">link to read more</a>.</p><p style="margin:0;font-size:12px;color:#888888">Posted by Writer \#(index % 7)</p></td></tr></table></td></tr>
            """#
            index += 1
        }
        return #"""
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>Weekly digest</title><style>body{margin:0;background:#f4f4f4} .wrap{max-width:600px;margin:0 auto} h3{font-weight:600} a:hover{text-decoration:underline} .hero{background:url(https://cdn.example/hero.jpg) center/cover}</style></head><body style="margin:0;padding:0;background-color:#f4f4f4"><table width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:20px"><table class="wrap" width="600" cellpadding="0" cellspacing="0" style="background-color:#ffffff;border-radius:8px"><tr><td class="hero" style="padding:24px"><img src="https://cdn.example/logo.png" width="120" height="40" alt="Acme" style="display:block"></td></tr>
        """# + rows + #"""
        <tr><td style="padding:16px;background-color:#eeeeee;font-size:12px;color:#777777"><img src="https://track.example/open.gif?id=42" width="1" height="1" alt=""><a href="https://acme.example/unsubscribe">Unsubscribe</a></td></tr></table></td></tr></table></body></html>
        """#
    }
}
