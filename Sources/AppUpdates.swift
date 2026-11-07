import AppKit

final class AppUpdates: NSObject, NSMenuItemValidation {
    private var work: Task<Void, Never>?
    private var progress: NSPanel?
    private let startupKey = "checkForUpdatesAtStartup"
    private let defaults: UserDefaults
    private let applicationInfo: [String: Any]
    private let loadRelease: () async throws -> UpdateRelease
    private let presentAlert: (NSAlert) -> NSApplication.ModalResponse
    private var activeCheckID: UUID?
    private var activeTrigger: UpdateCheckTrigger?
    private var isChecking = false
    var quitForUpdate: (() -> Void)?
    var canInstall: (() -> Bool)?
    var isBusy: Bool { work != nil }

    init(defaults: UserDefaults = .standard,
         applicationInfo: [String: Any] = Bundle.main.infoDictionary ?? [:],
         loadRelease: @escaping () async throws -> UpdateRelease = { try await GitHubUpdates.check() },
         presentAlert: @escaping (NSAlert) -> NSApplication.ModalResponse = {
             NSApp.activate(ignoringOtherApps: true)
             return $0.runModal()
         }) {
        self.defaults = defaults
        self.applicationInfo = applicationInfo
        self.loadRelease = loadRelease
        self.presentAlert = presentAlert
        super.init()
    }

    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Check for Updates…", action: #selector(check), keyEquivalent: "")
        item.target = self
        item.toolTip = "Check the published GitHub releases for a newer version."
        return item
    }

    func startupMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Check for Updates at Startup", action: #selector(toggleStartupChecks), keyEquivalent: "")
        item.target = self
        item.state = defaults.bool(forKey: startupKey) ? .on : .off
        item.toolTip = "Check GitHub when Jack starts. Only a newer compatible update shows a prompt."
        return item
    }

    @objc private func toggleStartupChecks() {
        let enabled = !defaults.bool(forKey: startupKey)
        defaults.set(enabled, forKey: startupKey)
        if !enabled, activeTrigger == .startup, isChecking { cancel() }
    }

    func checkAtStartup() {
        guard defaults.bool(forKey: startupKey), work == nil else { return }
        beginCheck(trigger: .startup)
    }

    func checkFromCommand(completion: @escaping (UpdateCheckReport) -> Void) {
        beginCheck(trigger: .command, completion: completion)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleStartupChecks) {
            menuItem.state = defaults.bool(forKey: startupKey) ? .on : .off
            return true
        }
        return work == nil || isChecking
    }

    @objc private func check() {
        beginCheck(trigger: .menu)
    }

    private func beginCheck(trigger: UpdateCheckTrigger, completion: ((UpdateCheckReport) -> Void)? = nil) {
        guard work == nil || isChecking else { completion?(.busy); return }
        // Replace only manifest checks, never an installation in progress.
        // A late result from the old channel must not close the newer UI.
        work?.cancel()
        closeProgress()
        let id = UUID()
        activeCheckID = id
        activeTrigger = trigger
        isChecking = true
        let channel = UpdateChannel.stable
        if trigger.showsProgress {
            NSApp.activate(ignoringOtherApps: true)
            showProgress("Checking for \(channel.title.lowercased()) updates…")
        }
        work = Task { @MainActor [weak self] in
            guard let self = self else { return }
            var report = UpdateCheckReport.canceled
            var installationRequested = false
            defer {
                if self.activeCheckID == id {
                    self.closeProgress()
                    self.work = nil
                    self.activeCheckID = nil
                    self.activeTrigger = nil
                    self.isChecking = false
                }
                completion?(report)
            }
            do {
                let release = try await self.loadRelease()
                try Task.checkCancellation()
                guard self.activeCheckID == id else { return }
                self.isChecking = false
                self.closeProgress()
                guard let buildText = self.applicationInfo["CFBundleVersion"] as? String,
                      let currentBuild = Int(buildText) else { throw UpdateError.invalidRelease }
                let version = self.applicationInfo["CFBundleShortVersionString"] as? String ?? "Unknown"
                let alert = NSAlert()
                if !release.isNewer(than: currentBuild) {
                    report = UpdateCheckReport(message: "No newer \(channel.title.lowercased()) update is available. You’re running \(version) (build \(currentBuild)).", succeeded: true)
                    guard trigger == .menu else { return }
                    alert.messageText = "Apple Jack is up to date"
                    alert.informativeText = "You’re running version \(version) (build \(currentBuild)). No newer \(channel.title.lowercased()) release is available."
                    alert.addButton(withTitle: "OK")
                    _ = self.presentAlert(alert)
                    return
                }
                guard release.supports(ProcessInfo.processInfo.operatingSystemVersion) else {
                    report = UpdateCheckReport(message: "Apple Jack \(release.version) is available on the \(channel.title) channel, but requires macOS \(release.minimumSystemVersion) or later.", succeeded: false)
                    guard trigger == .menu else { return }
                    alert.messageText = "A newer Apple Jack needs a newer macOS"
                    alert.informativeText = "Version \(release.version) requires macOS \(release.minimumSystemVersion) or later. This Mac is running version \(version) of Apple Jack."
                    alert.addButton(withTitle: "OK")
                    _ = self.presentAlert(alert)
                    return
                }
                report = UpdateCheckReport(message: "Apple Jack \(release.version) is available on the \(channel.title) channel. Choose Check for Updates to install it when you’re ready.", succeeded: true)
                alert.messageText = "Apple Jack \(release.version) is available (\(channel.title))"
                alert.informativeText = "You have version \(version).\n\n\(release.notes)\n\nInstall & Restart will close Apple Jack, update this copy in place, and reopen it. Your settings and Shortcuts stay in place."
                alert.addButton(withTitle: "Install & Restart")
                alert.addButton(withTitle: "Later")
                let choice = self.presentAlert(alert)
                guard choice == .alertFirstButtonReturn else { return }
                installationRequested = true
                guard self.canInstall?() != false else {
                    throw InstallFailure(message: "Let Jack finish the current request or stop speaking/recording, then install the update.")
                }
                self.showProgress("Preparing and verifying the update…")
                let installer = try await GitHubUpdates.download(release)
                defer { try? FileManager.default.removeItem(at: installer.deletingLastPathComponent()) }
                let target = Bundle.main.bundleURL
                let pid = ProcessInfo.processInfo.processIdentifier
                let plan = try await Task.detached(priority: .userInitiated) {
                    try UpdateInstallation.prepare(installer, release: release, target: target, parentPID: pid)
                }.value
                var handedOff = false
                defer { if !handedOff { try? FileManager.default.removeItem(at: plan.directory) } }
                try Task.checkCancellation()
                guard self.canInstall?() != false else {
                    throw InstallFailure(message: "A request started while the update was preparing. Finish it, then install again.")
                }
                let helper = plan.directory.appendingPathComponent("Installer")
                try FileManager.default.copyItem(at: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AppleJackUpdater"), to: helper)
                let process = Process()
                process.executableURL = helper
                process.arguments = [plan.file.path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                let deadline = Date().addingTimeInterval(15)
                while !FileManager.default.fileExists(atPath: plan.armed.path) {
                    if Task.isCancelled || !process.isRunning || Date() >= deadline {
                        if process.isRunning { process.terminate() }
                        try Task.checkCancellation()
                        throw InstallFailure(message: "The updater couldn’t start. Your installed app has not changed.")
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if Task.isCancelled { process.terminate(); throw CancellationError() }
                try Data().write(to: plan.proceed, options: .atomic)
                handedOff = true
                self.closeProgress()
                self.quitForUpdate?()
            } catch is CancellationError {
                // Cancel closes the progress window without an error alert.
                report = .canceled
            } catch {
                guard !Task.isCancelled, self.activeCheckID == id else { return }
                self.isChecking = false
                self.closeProgress()
                report = UpdateCheckReport(message: "Couldn’t check or complete the \(channel.title.lowercased()) update: \(error.localizedDescription)", succeeded: false)
                guard trigger == .menu || installationRequested else { return }
                let alert = NSAlert()
                alert.messageText = "Couldn’t complete the update"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                _ = self.presentAlert(alert)
            }
        }
    }


    private func showProgress(_ message: String) {
        closeProgress()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 132),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Apple Jack Updates"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        let label = NSTextField(labelWithString: message)
        label.frame = NSRect(x: 56, y: 79, width: 350, height: 24)
        let spinner = NSProgressIndicator(frame: NSRect(x: 22, y: 82, width: 20, height: 20))
        spinner.style = .spinning
        spinner.startAnimation(nil)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: 310, y: 22, width: 100, height: 32)
        cancel.keyEquivalent = "\u{1b}"
        panel.contentView?.addSubview(label)
        panel.contentView?.addSubview(spinner)
        panel.contentView?.addSubview(cancel)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        progress = panel
    }

    @objc private func cancel() { work?.cancel(); closeProgress() }
    private func closeProgress() { progress?.close(); progress = nil }
}
