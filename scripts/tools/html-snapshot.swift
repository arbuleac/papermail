// Renders an HTML file to PNG with WebKit, in light or dark appearance.
// Usage: swift scripts/tools/html-snapshot.swift <input.html> <output.png> [width=1280] [light|dark] [height=auto]
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: html-snapshot <input.html> <output.png> [width] [light|dark] [height]\n".data(using: .utf8)!)
    exit(2)
}
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
let width = args.count > 3 ? Double(args[3]) ?? 1280 : 1280
let appearanceName: NSAppearance.Name = (args.count > 4 && args[4] == "dark") ? .darkAqua : .aqua
let fixedHeight = args.count > 5 ? Double(args[5]) : nil

final class Renderer: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let window: NSWindow
    init(width: Double) {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 800), configuration: config)
        window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.appearance = NSAppearance(named: appearanceName)
        webView.appearance = NSAppearance(named: appearanceName)
        window.contentView = webView
        webView.navigationDelegate = self
    }
    func start() {
        webView.loadFileURL(input, allowingReadAccessTo: input.deletingLastPathComponent())
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            webView.evaluateJavaScript("Math.max(document.documentElement.scrollHeight, document.body.scrollHeight)") { value, _ in
                let measured = (value as? Double) ?? 800
                let height = fixedHeight ?? min(measured, 12000)
                self.window.setContentSize(NSSize(width: width, height: height))
                webView.frame = NSRect(x: 0, y: 0, width: width, height: height)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let config = WKSnapshotConfiguration()
                    config.rect = NSRect(x: 0, y: 0, width: width, height: height)
                    webView.takeSnapshot(with: config) { image, error in
                        guard let image, let tiff = image.tiffRepresentation,
                              let rep = NSBitmapImageRep(data: tiff),
                              let png = rep.representation(using: .png, properties: [:]) else {
                            FileHandle.standardError.write("snapshot failed: \(String(describing: error))\n".data(using: .utf8)!)
                            exit(1)
                        }
                        try? png.write(to: output)
                        print(output.path)
                        exit(0)
                    }
                }
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardError.write("load failed: \(error)\n".data(using: .utf8)!); exit(1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let renderer = Renderer(width: width)
renderer.start()
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { FileHandle.standardError.write("timeout\n".data(using: .utf8)!); exit(1) }
app.run()
