import AppKit
import Quartz
import WebKit

/// Web links need an actual browsing surface. File members of a mixed selection
/// still use the system Quick Look renderer.
final class HeldWebsitePreview: NSPanel, WKNavigationDelegate {
    let items: [(id: UUID, url: URL)]
    private let container = NSView()
    private let status = NSTextField(labelWithString: "")
    private let previous = NSButton(title: "‹", target: nil, action: nil)
    private let next = NSButton(title: "›", target: nil, action: nil)
    private let openButton = NSButton(title: "Open in Safari", target: nil, action: nil)
    private var index = 0
    private var web: WKWebView?
    private var local: QLPreviewView?
    private let openURL: (URL) -> Void
    var didClose: (() -> Void)?

    init(items: [(id: UUID, url: URL)], anchor: NSWindow, openURL: @escaping (URL) -> Void) {
        self.items = items
        self.openURL = openURL
        let screen = anchor.screen?.visibleFrame ?? anchor.frame
        let size = NSSize(width: min(720, screen.width * 0.85), height: min(490, screen.height * 0.75))
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = anchor.level
        minSize = NSSize(width: 330, height: 220)
        previous.target = self; previous.action = #selector(goBack)
        next.target = self; next.action = #selector(goForward)
        previous.setAccessibilityLabel("Previous held item")
        next.setAccessibilityLabel("Next held item")
        previous.isHidden = items.count == 1; next.isHidden = items.count == 1
        openButton.target = self; openButton.action = #selector(openInSafari)
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let toolbar = NSStackView(views: [previous, next, status, NSView(), openButton])
        toolbar.spacing = 6
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        contentView = root
        for child in [container, toolbar] {
            root.addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            container.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        ])
        setFrameOrigin(NSPoint(x: screen.midX - frame.width / 2, y: screen.midY - frame.height / 2))
        showItem()
    }

    @objc private func goBack() { if index > 0 { index -= 1; showItem() } }
    @objc private func goForward() { if index + 1 < items.count { index += 1; showItem() } }
    @objc private func openInSafari() {
        let url = web?.url ?? items[index].url
        guard Self.isWebsite(url) else { return }
        close()
        openURL(url)
    }

    static func isWebsite(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased()) && url.host?.isEmpty == false
    }

    private func clearItem() {
        web?.navigationDelegate = nil
        web?.stopLoading()
        web?.removeFromSuperview()
        web = nil
        local?.close()
        local?.removeFromSuperview()
        local = nil
    }

    private func showItem() {
        clearItem()
        let url = items[index].url
        previous.isEnabled = index > 0; next.isEnabled = index + 1 < items.count
        openButton.isHidden = url.isFileURL
        let surface: NSView
        if url.isFileURL {
            let preview = QLPreviewView(frame: container.bounds, style: .normal)!
            preview.shouldCloseWithWindow = false
            local = preview
            preview.previewItem = url as NSURL
            title = url.lastPathComponent
            status.stringValue = title
            surface = preview
        } else {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.mediaTypesRequiringUserActionForPlayback = .all
            let preview = WKWebView(frame: container.bounds, configuration: configuration)
            web = preview
            preview.navigationDelegate = self
            title = url.host ?? "Website Preview"
            status.stringValue = "Loading " + title + "…"
            preview.load(URLRequest(url: url, timeoutInterval: 25))
            surface = preview
        }
        surface.autoresizingMask = [.width, .height]
        container.addSubview(surface)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.targetFrame?.isMainFrame != false {
            guard let url = action.request.url, Self.isWebsite(url) else { decisionHandler(.cancel); return }
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame && !response.canShowMIMEType {
            status.stringValue = "This file can be opened in Safari."
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        title = webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? items[index].url.host ?? "Website Preview"
        status.stringValue = webView.url?.absoluteString ?? items[index].url.absoluteString
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { status.stringValue = error.localizedDescription }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
    }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            switch event.keyCode {
            case 49, 53: if !event.isARepeat { close() }; return
            case 36 where !openButton.isHidden, 76 where !openButton.isHidden: if !event.isARepeat { openInSafari() }; return
            case 123 where items.count > 1: goBack(); return
            case 124 where items.count > 1: goForward(); return
            default: break
            }
        }
        super.sendEvent(event)
    }
    override func close() {
        clearItem()
        super.close()
        didClose?()
    }
}
