import AppKit
import CoreFoundation

// Independent implementation of the documented Codex account/rateLimits/read
// RPC. Codex owns sign-in. Jack never opens its credential files or starts a turn.
struct CodexUsageSnapshot {
    struct Window {
        let used: Double
        let minutes: Int
        let reset: Date
        var remaining: Double { 100 - used }
        var name: String {
            if minutes == 10_080 { return "Week" }
            if minutes == 1_440 { return "Day" }
            if minutes % 60 == 0 { return "\(minutes / 60) hr" }
            return "\(minutes) min"
        }
        func description(now: Date) -> String {
            guard reset > now else { return name + " · Checking reset…" }
            let total = max(1, Int(ceil(reset.timeIntervalSince(now) / 60)))
            let days = total / 1_440, hours = total % 1_440 / 60, mins = total % 60
            let time = days > 0 ? "\(days)d \(hours)h" : hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
            return "\(name) · \(Int(remaining.rounded()))% left · resets in \(time)"
        }
    }
    let plan: String?
    let windows: [Window]
    let observed: Date
    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    static func parse(_ result: [String: Any], now: Date = Date()) -> CodexUsageSnapshot? {
        let buckets = result["rateLimitsByLimitId"] as? [String: [String: Any]]
        guard let bucket = buckets?["codex"] ?? result["rateLimits"] as? [String: Any],
              bucket["limitId"] == nil || bucket["limitId"] as? String == "codex" else { return nil }
        let windows = ["primary", "secondary"].compactMap { key -> Window? in
            guard let value = bucket[key] as? [String: Any], let used = number(value["usedPercent"]),
                  (0...100).contains(used), let mins = number(value["windowDurationMins"]),
                  (1...525_600).contains(mins), mins.rounded(.down) == mins, let reset = number(value["resetsAt"]),
                  reset > 0 else { return nil }
            return Window(used: used, minutes: Int(mins), reset: Date(timeIntervalSince1970: reset))
        }
        guard !windows.isEmpty else { return nil }
        let plans = ["free": "Free", "go": "Go", "plus": "Plus", "pro": "Pro", "prolite": "Pro Lite",
                     "team": "Team", "business": "Business", "enterprise": "Enterprise", "edu": "Edu"]
        return CodexUsageSnapshot(plan: (bucket["planType"] as? String).flatMap { plans[$0] }, windows: windows, observed: now)
    }
}

final class CodexUsage {
    private var process: Process?
    private var input: FileHandle?
    private var timeout: DispatchWorkItem?
    private var generation = UUID()
    private var lastAttempt: Date?
    private let executable: () -> URL?
    private let timeoutSeconds: TimeInterval
    private(set) var snapshot: CodexUsageSnapshot?
    private(set) var isAvailable: Bool
    private(set) var status = "Codex usage · Not checked"
    var didChange: (() -> Void)?
    var isChecking: Bool { process != nil }
    init(executable: @escaping () -> URL? = { CodexReply.installedExecutable() }, timeoutSeconds: TimeInterval = 20) {
        self.executable = executable; self.timeoutSeconds = timeoutSeconds
        isAvailable = executable() != nil
    }
    static var arguments: [String] {
        ["app-server", "--listen", "stdio://", "--disable", "plugins", "--disable", "apps", "-c", "analytics.enabled=false"]
    }
    func refresh(force: Bool = false) {
        guard !isChecking else { return }
        let interval: TimeInterval = snapshot?.windows.contains(where: { $0.reset <= Date() }) == true ? 60 : 300
        guard force || lastAttempt == nil || Date().timeIntervalSince(lastAttempt!) >= interval else { return }
        lastAttempt = Date()
        guard let executable = executable() else {
            isAvailable = false
            fail("Codex usage · Install ChatGPT or Codex to check limits"); return
        }
        isAvailable = true
        let id = UUID(); generation = id
        let child = Process(), incoming = Pipe(), outgoing = Pipe()
        child.executableURL = executable; child.arguments = Self.arguments
        child.currentDirectoryURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        // Ignore credentials or account overrides inherited from another app.
        let allowed = Set(["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "SSL_CERT_FILE", "SSL_CERT_DIR"])
        child.environment = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
        child.standardInput = incoming; child.standardOutput = outgoing; child.standardError = FileHandle.nullDevice
        do {
            try child.run()
            process = child; input = incoming.fileHandleForWriting
            status = "Codex usage · Checking…"; didChange?()
            let deadline = DispatchWorkItem { [weak self] in
                guard let self, self.generation == id, self.isChecking else { return }
                self.fail("Codex usage · Couldn’t refresh. Try again later.")
            }
            timeout = deadline; DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds, execute: deadline)
            // One ordered reader delivers complete protocol messages before EOF.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let reader = outgoing.fileHandleForReading
                defer { try? reader.close() }
                var buffer = Data(), total = 0
                while true {
                    let data = reader.availableData
                    if data.isEmpty { break }
                    total += data.count; buffer.append(data)
                    if total > 2_000_000 || buffer.count > 1_000_000 { break }
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                        DispatchQueue.main.async { [weak self] in self?.receive(line, id: id) }
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == id, self.isChecking else { return }
                    self.fail("Codex usage · Couldn’t read limits. Check your Codex sign-in.")
                }
            }
            send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "apple_jack", "title": "Apple Jack", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.57"]]])
        } catch { fail("Codex usage · Couldn’t start the installed Codex service") }
    }
    private func send(_ value: [String: Any]) {
        do {
            let bytes = try JSONSerialization.data(withJSONObject: value) + Data([10])
            guard let input else { return }; try input.write(contentsOf: bytes)
        } catch { fail("Codex usage · Connection closed before limits were read") }
    }
    private func receive(_ line: Data, id: UUID) {
        guard generation == id, isChecking,
              let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let sequence = value["id"] as? Int, (1...3).contains(sequence) else { return }
        guard value["error"] == nil, let result = value["result"] as? [String: Any] else {
            fail("Codex usage · Unavailable. Check your Codex sign-in or update Codex."); return
        }
        switch sequence {
        case 1:
            send(["method": "initialized"])
            send(["id": 2, "method": "account/read", "params": ["refreshToken": false]])
        case 2:
            guard let account = result["account"] as? [String: Any], account["type"] as? String == "chatgpt" else {
                fail("Codex usage · Sign in to Codex with ChatGPT to see plan limits"); return
            }
            send(["id": 3, "method": "account/rateLimits/read"])
        default:
            guard let reading = CodexUsageSnapshot.parse(result) else {
                fail("Codex usage · No remaining allowance was reported"); return
            }
            snapshot = reading; status = "Codex" + (reading.plan.map { " · " + $0 } ?? "")
            stop(); didChange?()
        }
    }
    private func fail(_ message: String) { stop(); snapshot = nil; status = message; didChange?() }
    func stop() {
        generation = UUID(); timeout?.cancel(); timeout = nil
        try? input?.close(); input = nil
        guard let child = process else { return }; process = nil
        if child.isRunning {
            child.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if child.isRunning { child.interrupt() } }
        }
    }
}

private final class CodexUsageBar: NSProgressIndicator {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 4) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
        let fraction = min(1, max(0, doubleValue / 100))
        guard fraction > 0 else { return }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height), xRadius: 2, yRadius: 2).fill()
    }
}

final class CodexUsageView: NSStackView {
    private let label = NSTextField(labelWithString: "")
    private let refreshButton = NSButton()
    private let windows = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    var refresh: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .vertical; alignment = .leading; spacing = 3
        widthAnchor.constraint(equalToConstant: 150).isActive = true
        label.font = .systemFont(ofSize: 10, weight: .semibold); label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refreshButton.imagePosition = .imageOnly; refreshButton.isBordered = false
        refreshButton.controlSize = .mini; refreshButton.contentTintColor = .secondaryLabelColor
        refreshButton.setAccessibilityLabel("Refresh Codex usage")
        refreshButton.toolTip = "Refresh Codex usage"
        refreshButton.widthAnchor.constraint(equalToConstant: 16).isActive = true
        refreshButton.heightAnchor.constraint(equalToConstant: 16).isActive = true
        refreshButton.target = self; refreshButton.action = #selector(refreshClicked)
        let header = NSStackView(views: [label, NSView(), refreshButton]); header.spacing = 4
        addArrangedSubview(header); header.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        windows.orientation = .vertical; windows.alignment = .leading; windows.spacing = 3
        addArrangedSubview(windows); windows.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        statusLabel.font = .systemFont(ofSize: 10); statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addArrangedSubview(statusLabel); statusLabel.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        toolTip = "Remaining allowance for the account signed in to Codex on this Mac. This is separate from ChatGPT (Sign In) and ChatGPT (Shortcuts)."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func refreshClicked() { refresh?() }
    func update(_ reader: CodexUsage) {
        // Installed Codex stays visible for every assistant, including when its
        // account is signed out or a refresh fails. Only absence hides the panel.
        isHidden = !reader.isAvailable
        label.stringValue = "Codex" + (reader.snapshot?.plan.map { " · " + $0 } ?? "")
        refreshButton.isEnabled = !reader.isChecking
        statusLabel.stringValue = reader.isChecking ? "Checking usage…"
            : reader.status.contains("Sign in to Codex") ? "Sign in to Codex"
            : reader.status.contains("Not checked") ? "Usage not checked" : "Usage unavailable"
        statusLabel.toolTip = reader.status
        statusLabel.setAccessibilityLabel(reader.status)
        statusLabel.isHidden = reader.snapshot != nil
        for view in windows.arrangedSubviews { windows.removeArrangedSubview(view); view.removeFromSuperview() }
        for window in reader.snapshot?.windows ?? [] {
            let caption = NSTextField(labelWithString: window.reset > Date()
                ? "\(window.name) · \(Int(window.remaining.rounded()))% left" : "\(window.name) · Checking reset…")
            caption.font = .systemFont(ofSize: 10); caption.textColor = .secondaryLabelColor
            caption.toolTip = window.description(now: Date())
            caption.setAccessibilityLabel(window.description(now: Date()))
            let bar = CodexUsageBar(); bar.isIndeterminate = false; bar.style = .bar
            bar.controlSize = .mini
            bar.minValue = 0; bar.maxValue = 100; bar.doubleValue = window.reset > Date() ? window.remaining : 0
            bar.toolTip = window.description(now: Date())
            bar.setAccessibilityLabel(window.description(now: Date()))
            windows.addArrangedSubview(caption); windows.addArrangedSubview(bar)
            bar.widthAnchor.constraint(equalTo: windows.widthAnchor).isActive = true
        }
        windows.isHidden = reader.snapshot == nil
    }
}
