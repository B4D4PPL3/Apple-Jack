import AppKit
import Quartz
import WebKit

/// Web links need an actual browsing surface. File members of a mixed selection
/// still use the system Quick Look renderer.
final class HeldItemPreview: NSView, WKNavigationDelegate {
    let items: [(id: UUID, url: URL)]
    private let container = NSView()
    private let status = NSTextField(labelWithString: "")
    private let previous = NSButton(title: "‹", target: nil, action: nil)
    private let next = NSButton(title: "›", target: nil, action: nil)
    private let openButton = NSButton(title: "Open in Browser", target: nil, action: nil)
    private var index = 0
    private var web: WKWebView?
    private var local: QLPreviewView?
    var dismiss: (() -> Void)?

    init(items: [(id: UUID, url: URL)]) {
        self.items = items
        super.init(frame: NSRect(x: 0, y: 0, width: 560, height: 340))
        previous.target = self; previous.action = #selector(goBack)
        next.target = self; next.action = #selector(goForward)
        previous.setAccessibilityLabel("Previous held item")
        next.setAccessibilityLabel("Next held item")
        previous.isHidden = items.count == 1; next.isHidden = items.count == 1
        openButton.target = self; openButton.action = #selector(openInBrowser)
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let toolbar = NSStackView(views: [previous, next, status, NSView(), openButton])
        toolbar.spacing = 6
        for child in [container, toolbar] {
            addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            container.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present(in navigation: BubbleNavigation, title: String, returnFocus: NSView, onLeave: (() -> Void)? = nil) {
        dismiss = { [weak self, weak navigation] in
            guard let self, navigation?.visibleBody === self else { return }
            navigation?.back()
        }
        navigation.show(title, body: self, size: frame.size, minimum: NSSize(width: 280, height: 160),
                        returnFocus: returnFocus) { [weak self] in
            self?.clearItem()
            onLeave?()
        }
        layoutSubtreeIfNeeded()
        showItem()
    }

    @objc private func goBack() { if index > 0 { index -= 1; showItem() } }
    @objc private func goForward() { if index + 1 < items.count { index += 1; showItem() } }
    @objc private func openInBrowser() {
        let url = web?.url ?? items[index].url
        guard Self.isWebsite(url) else { return }
        NativeLocationOpener.openInDefaultBrowser(url) { [weak self] result in
            switch result {
            case .success: self?.dismiss?()
            case .failure(let error): self?.status.stringValue = error.localizedDescription
            }
        }
    }

    static func isWebsite(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased()) && url.host?.isEmpty == false
    }

    func clearItem() {
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
            guard let preview = QLPreviewView(frame: container.bounds, style: .normal) else {
                status.stringValue = "Quick Look is unavailable for " + url.lastPathComponent
                return
            }
            preview.shouldCloseWithWindow = false
            local = preview
            preview.previewItem = url as NSURL
            status.stringValue = url.lastPathComponent
            surface = preview
        } else {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.mediaTypesRequiringUserActionForPlayback = .all
            let preview = WKWebView(frame: container.bounds, configuration: configuration)
            web = preview
            preview.navigationDelegate = self
            status.stringValue = "Loading " + (url.host ?? "website") + "…"
            preview.load(URLRequest(url: url, timeoutInterval: 25))
            surface = preview
        }
        surface.autoresizingMask = [.width, .height]
        container.addSubview(surface)
        if let web { window?.makeFirstResponder(web) }
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
            status.stringValue = "Use Open in Browser to view this file."
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        status.stringValue = webView.url?.absoluteString ?? items[index].url.absoluteString
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { status.stringValue = error.localizedDescription }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
    }
    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 49 where web == nil, 53:
            if !event.isARepeat { dismiss?() }
        case 123 where items.count > 1: goBack()
        case 124 where items.count > 1: goForward()
        default: return false
        }
        return true
    }
}
