import AppKit
import Darwin

@main struct AppleJackUpdater {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // AppKit process-lifecycle properties require a running main run loop.
        Task { @MainActor in await install() }
        app.run()
    }

    @MainActor static func install() async {
        var plan: UpdateInstallPlan?
        var exchanged = false
        var replacement: NSRunningApplication?
        var replacementExit: ProcessExitMonitor?
        do {
            guard CommandLine.arguments.count == 2 else { throw InstallFailure(message: "Missing update plan.") }
            let file = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
            let decoded = try JSONDecoder().decode(UpdateInstallPlan.self, from: Data(contentsOf: file))
            try decoded.validatePaths()
            guard decoded.file == file,
                  URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL == decoded.directory.appendingPathComponent("Installer") else {
                throw InstallFailure(message: "The updater was not started from its prepared folder.")
            }
            plan = decoded
            try UpdateInstallation.validateApp(decoded.target, build: decoded.oldBuild)
            try UpdateInstallation.validateApp(decoded.stagedApp, build: decoded.newBuild, version: decoded.version, channel: decoded.channel)
            guard let original = NSRunningApplication(processIdentifier: decoded.parentPID),
                  original.bundleURL?.resolvingSymlinksInPath() == decoded.target else {
                throw InstallFailure(message: "The original Apple Jack process could not be identified. Nothing was replaced.")
            }
            let originalExit = ProcessExitMonitor(pid: decoded.parentPID)
            try Data().write(to: decoded.armed, options: .atomic)
            let deadline = Date().addingTimeInterval(45)
            while !FileManager.default.fileExists(atPath: decoded.proceed.path) || !originalExit.hasExited {
                guard Date() < deadline else { throw InstallFailure(message: "Apple Jack did not finish quitting. Nothing was replaced. Please try again.") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            // Recheck after waiting; a second updater must not replace a newer app.
            try UpdateInstallation.validateApp(decoded.target, build: decoded.oldBuild)
            try UpdateInstallation.validateApp(decoded.stagedApp, build: decoded.newBuild, version: decoded.version, channel: decoded.channel)
            try JSONEncoder().encode(decoded).write(to: UpdateInstallation.pendingFile(for: decoded.target), options: .atomic)
            try UpdateInstallation.verifyPublisher(of: decoded.stagedApp, against: decoded.target)
            try UpdateInstallation.swap(decoded)
            exchanged = true
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = ["--applejack-update-token", decoded.token]
            replacement = try await NSWorkspace.shared.openApplication(at: decoded.target, configuration: configuration)
            if let replacement = replacement { replacementExit = ProcessExitMonitor(pid: replacement.processIdentifier) }
            let startupDeadline = Date().addingTimeInterval(45)
            while (try? String(contentsOf: decoded.ready, encoding: .utf8)) != String(decoded.newBuild) {
                guard Date() < startupDeadline, replacementExit?.hasExited == false else {
                    throw InstallFailure(message: "The updated Apple Jack didn’t finish starting.")
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            // Keep a recovery copy rather than discard the last working version.
            let note = "Apple Jack updated to \(decoded.version). This hidden folder contains the previous app as Apple Jack.app. It can be removed after the update has been tested.\n"
            try? note.write(to: decoded.directory.appendingPathComponent("Recovery.txt"), atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: UpdateInstallation.pendingFile(for: decoded.target))
            try? FileManager.default.removeItem(at: decoded.directory.appendingPathComponent("Installer"))
            exit(0)
        } catch {
            var detail = error.localizedDescription
            if let plan = plan { try? FileManager.default.removeItem(at: UpdateInstallation.pendingFile(for: plan.target)) }
            if let plan = plan, exchanged {
                if let replacement = replacement, replacementExit?.hasExited == false {
                    replacement.terminate()
                    let deadline = Date().addingTimeInterval(5)
                    while replacementExit?.hasExited == false && Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
                }
                if replacement == nil || replacementExit?.hasExited == true {
                    do {
                        try UpdateInstallation.swap(plan)
                        _ = try await NSWorkspace.shared.openApplication(at: plan.target, configuration: .init())
                        detail += "\n\nThe previous version was restored and reopened."
                    } catch {
                        detail += "\n\nRecovery needs your help. The app copies are at:\n\(plan.target.path)\n\(plan.stagedApp.path)"
                    }
                } else {
                    detail += "\n\nThe new app is still running. Your previous version is saved at:\n\(plan.stagedApp.path)"
                }
            }
            if let plan = plan { try? detail.write(to: plan.directory.appendingPathComponent("Error.txt"), atomically: true, encoding: .utf8) }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Apple Jack update couldn’t finish"
            alert.informativeText = detail
            alert.addButton(withTitle: "OK")
            alert.runModal()
            exit(1)
        }
    }
}
