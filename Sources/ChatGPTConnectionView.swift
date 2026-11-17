import AppKit

final class ChatGPTConnectionView: NSObject {
    let connection: ChatGPTConnection
    private var panel: NSWindow?
    private let accounts = NSPopUpButton()
    private let models = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let usage = NSTextField(wrappingLabelWithString: "")
    private let welcome = NSTextField(wrappingLabelWithString: "You’re using your ChatGPT plan. Eligible requests in Apple Jack count toward its existing limits. You can manage usage in ChatGPT settings.")
    private let gotIt = NSButton(title: "Got it", target: nil, action: nil)
    private let unlock = NSButton(title: "Unlock ChatGPT Connection", target: nil, action: nil)
    private let connect = NSButton(title: "Continue with ChatGPT", target: nil, action: nil)
    private let add = NSButton(title: "Add Account…", target: nil, action: nil)
    private let signOut = NSButton(title: "Sign Out", target: nil, action: nil)
    private let refresh = NSButton(title: "Refresh Models", target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel Sign-In", target: nil, action: nil)
    private let fallback = NSButton(title: "Use ChatGPT (Shortcuts)", target: nil, action: nil)
    var useShortcuts: (() -> Void)?
    init(connection: ChatGPTConnection) { self.connection = connection; super.init() }

    func show() {
        connection.loadIfNeeded()
        if panel == nil { build() }
        refreshState()
        NSApp.activate(ignoringOtherApps: true)
        if let nav = BubbleNavigation.current, let panel {
            nav.show(panel, title: "ChatGPT Connection", onLeave: { [weak self] in self?.connection.cancelSignIn() })
        } else { panel?.makeKeyAndOrderFront(nil) }
        if connection.canUsePlan && connection.models.isEmpty && !connection.isBusy { connection.refreshModels() }
    }
    func refreshState() {
        guard panel != nil else { return }
        let c = connection, profile = c.activeProfile
        accounts.removeAllItems()
        if c.profiles.isEmpty { accounts.addItem(withTitle: c.needsUnlock ? "Unlock to view saved accounts" : "No connected account") }
        for p in c.profiles { accounts.addItem(withTitle: p.label); accounts.lastItem?.representedObject = p.id }
        if let index = c.profiles.firstIndex(where: { $0.id == profile?.id }) { accounts.selectItem(at: index) }
        accounts.isEnabled = !c.isBusy && !c.needsUnlock && !c.profiles.isEmpty
        models.removeAllItems()
        for model in c.models { models.addItem(withTitle: model.name); models.lastItem?.representedObject = model.slug }
        if c.models.isEmpty { models.addItem(withTitle: profile?.model ?? "Available after connecting") }
        if let index = c.models.firstIndex(where: { $0.slug == profile?.model }) { models.selectItem(at: index) }
        models.isEnabled = !c.isBusy && !c.needsUnlock && c.canUsePlan && !c.models.isEmpty
        status.stringValue = c.status
        usage.stringValue = c.usageSummary + (c.lastReplyTokens.map { "\nLast completed reply: \($0) tokens (input and output)." } ?? "")
        unlock.isHidden = !c.needsUnlock
        unlock.isEnabled = !c.isBusy
        connect.isEnabled = !c.isBusy && !c.needsUnlock
        add.isEnabled = !c.isBusy && !c.needsUnlock
        signOut.isEnabled = !c.isBusy && !c.needsUnlock && profile?.credentials != nil
        refresh.isEnabled = !c.isBusy && !c.needsUnlock && c.canUsePlan
        cancel.isHidden = !c.isSigningIn
        fallback.isEnabled = !c.isBusy
        welcome.isHidden = !c.needsWelcome; gotIt.isHidden = !c.needsWelcome
    }
    private func build() {
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "ChatGPT Connection"; panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 570, height: 560)
        let body = NSView(frame: NSRect(x: 0, y: 0, width: 570, height: 560))
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; body.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -22), stack.topAnchor.constraint(equalTo: body.topAnchor, constant: 12)])
        func label(_ text: String) {
            let view = NSTextField(wrappingLabelWithString: text)
            view.font = .systemFont(ofSize: 12); view.textColor = .secondaryLabelColor
            stack.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        label("Use your eligible ChatGPT plan for answers inside Jack. Sign in securely with OpenAI in your browser. No API key or answering shortcut is needed for this connection.")
        accounts.setAccessibilityLabel("Connected ChatGPT account"); models.setAccessibilityLabel("ChatGPT model")
        accounts.target = self; accounts.action = #selector(accountChanged)
        models.target = self; models.action = #selector(modelChanged)
        for (name, control) in [("Account", accounts), ("Model", models)] {
            let title = NSTextField(labelWithString: name); title.widthAnchor.constraint(equalToConstant: 65).isActive = true
            let row = NSStackView(views: [title, control]); row.spacing = 8
            control.setContentHuggingPriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        for (button, action) in [(unlock, #selector(unlockConnection)), (connect, #selector(begin)), (add, #selector(addAccount)), (signOut, #selector(logOut)),
                                  (refresh, #selector(refreshModels)), (cancel, #selector(cancelSignIn)), (gotIt, #selector(acknowledge)), (fallback, #selector(shortcuts))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
        }
        stack.addArrangedSubview(unlock)
        stack.addArrangedSubview(NSStackView(views: [connect, add, signOut]))
        stack.addArrangedSubview(NSStackView(views: [refresh, cancel]))
        status.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(status); status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let line = NSBox(); line.boxType = .separator; stack.addArrangedSubview(line); line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        usage.font = .systemFont(ofSize: 12)
        let manage = NSButton(title: "Manage Usage", target: self, action: #selector(manageUsage))
        let usageRow = NSStackView(views: [usage, NSView(), manage]); usageRow.spacing = 10
        stack.addArrangedSubview(usageRow); usageRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        label("Session counts show Jack’s completed replies on this Mac, not your remaining allowance. View official plan and app limits in Manage Usage.")
        welcome.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(welcome); welcome.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(gotIt)
        label("This connection does not import ChatGPT conversations, memory, or your Dot. Jack’s conversation memory stays separate. The existing Shortcuts option remains available.")
        stack.addArrangedSubview(fallback)
        panel.contentView = body
        self.panel = panel
    }
    @objc private func unlockConnection() {
        if connection.unlock(), connection.canUsePlan { connection.refreshModels() }
    }
    @objc private func begin() { connection.signIn() }
    @objc private func addAccount() { connection.signIn(newAccount: true) }
    @objc private func logOut() { connection.signOut() }
    @objc private func cancelSignIn() { connection.cancelSignIn() }
    @objc private func refreshModels() { connection.refreshModels() }
    @objc private func acknowledge() { connection.acknowledgeWelcome() }
    @objc private func manageUsage() { NSWorkspace.shared.open(ChatGPTSignInProtocol.usageURL) }
    @objc private func accountChanged() {
        if let id = accounts.selectedItem?.representedObject as? UUID { connection.selectProfile(id) }
    }
    @objc private func modelChanged() {
        if let slug = models.selectedItem?.representedObject as? String { connection.selectModel(slug) }
    }
    @objc private func shortcuts() { useShortcuts?() }
}
