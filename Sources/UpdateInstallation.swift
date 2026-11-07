import AppKit
import Security
import Foundation
import Darwin
import CryptoKit

struct InstallFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// No shell interpolation: every path is passed as a separate process argument.
enum UpdateCommand {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 120) throws -> Data {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: log) }
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw InstallFailure(message: "Preparing the update took too long. Your installed app is unchanged. Try again.")
        }
        process.waitUntilExit()
        let data = try Data(contentsOf: log)
        guard process.terminationStatus == 0 else {
            let detail = String(data: data.prefix(2000), encoding: .utf8) ?? ""
            throw InstallFailure(message: "The update couldn’t be prepared. \(detail)")
        }
        return data
    }
}

struct UpdateInstallPlan: Codable {
    let target: URL
    let directory: URL
    let token: String
    let parentPID: Int32
    let oldBuild: Int
    let newBuild: Int
    let version: String
    let channel: String
    var stagedApp: URL { directory.appendingPathComponent("Apple Jack.app", isDirectory: true) }
    var ready: URL { directory.appendingPathComponent("ready") }
    var armed: URL { directory.appendingPathComponent("armed") }
    var proceed: URL { directory.appendingPathComponent("proceed") }
    var file: URL { directory.appendingPathComponent("plan.json") }

    func validatePaths() throws {
        let parent = target.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        guard UUID(uuidString: token) != nil,
              target.pathExtension == "app", target == target.resolvingSymlinksInPath().standardizedFileURL,
              directory == parent.appendingPathComponent(".AppleJackUpdate-" + token, isDirectory: true),
              directory == directory.resolvingSymlinksInPath().standardizedFileURL,
              newBuild > oldBuild, oldBuild > 0, UpdateChannel(rawValue: channel) != nil else {
            throw InstallFailure(message: "The update installation plan is invalid.")
        }
    }
}

enum UpdateInstallation {
    static let identifier = UpdateRelease.bundleIdentifier
    static func info(at app: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == identifier,
              info["CFBundleExecutable"] as? String == "AppleJack" else {
            throw InstallFailure(message: "The installer does not contain Apple Jack.")
        }
        return info
    }

    static func validateApp(_ app: URL, build: Int, version: String? = nil, channel: String? = nil) throws {
        let info = try info(at: app)
        guard info["CFBundleVersion"] as? String == String(build),
              version == nil || info["CFBundleShortVersionString"] as? String == version,
              channel == nil || (info["AppleJackReleaseChannel"] as? String ?? "stable") == channel else {
            throw InstallFailure(message: "The app inside the installer doesn’t match the advertised release.")
        }
        // Bundle resources may contain links, but none may escape the bundle.
        let root = app.resolvingSymlinksInPath().path + "/"
        guard let entries = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw InstallFailure(message: "The update app couldn’t be read.")
        }
        for case let entry as URL in entries {
            if try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true,
               !entry.resolvingSymlinksInPath().path.hasPrefix(root) {
                throw InstallFailure(message: "The update contains an invalid file link.")
            }
        }
        _ = try UpdateCommand.run("/usr/bin/codesign", ["--verify", "--deep", app.path])
        let architectures = Set(Bundle(url: app)?.executableArchitectures?.map(\.int32Value) ?? [])
        guard architectures.contains(CPU_TYPE_ARM64), architectures.contains(CPU_TYPE_X86_64) else {
            throw InstallFailure(message: "The installer is missing a supported Mac architecture.")
        }
    }

    // Pin replacements to the Developer ID team that signed the installed app.
    // The detached updater repeats this check immediately before the swap.
    static func verifyPublisher(of newApp: URL, against installed: URL) throws {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(installed as CFURL, [], &code) == errSecSuccess,
              let code, SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
            throw InstallFailure(message: "This is a locally signed build. Install the first Developer ID–signed release from GitHub to enable Install & Restart.")
        }
        let requirement = "anchor apple generic and identifier \"com.fonz.applejack.public\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"" + team + "\""
        _ = try UpdateCommand.run("/usr/bin/codesign", ["--verify", "--strict", "--deep", "-R=" + requirement, newApp.path])
    }

    static func prepare(_ image: URL, release: UpdateRelease, target: URL, parentPID: Int32) throws -> UpdateInstallPlan {
        let manager = FileManager.default
        let target = target.standardizedFileURL
        guard target == target.resolvingSymlinksInPath(),
              !target.path.hasPrefix("/Volumes/"), !target.path.contains("/AppTranslocation/"),
              manager.isWritableFile(atPath: target.path),
              manager.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw InstallFailure(message: "Apple Jack can’t replace this copy in its current location. Install it in your personal Applications folder first, then check again.")
        }
        let current = try info(at: target)
        guard let text = current["CFBundleVersion"] as? String, let oldBuild = Int(text), release.build > oldBuild else {
            throw InstallFailure(message: "The installed app changed while checking. Please check for updates again.")
        }
        let mount = image.deletingLastPathComponent().appendingPathComponent("MountedUpdate", isDirectory: true)
        try manager.createDirectory(at: mount, withIntermediateDirectories: false)
        var mounted = false
        defer {
            if mounted {
                if (try? UpdateCommand.run("/usr/bin/hdiutil", ["detach", mount.path], timeout: 30)) != nil {
                    try? manager.removeItem(at: mount)
                }
            } else { try? manager.removeItem(at: mount) }
        }
        _ = try UpdateCommand.run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path])
        mounted = true
        let source = mount.appendingPathComponent("Apple Jack Public.app", isDirectory: true)
        guard source.resolvingSymlinksInPath().deletingLastPathComponent() == mount.resolvingSymlinksInPath() else {
            throw InstallFailure(message: "The installer contains an invalid application link.")
        }
        try validateApp(source, build: release.build, version: release.version, channel: release.releaseChannel.rawValue)
        try verifyPublisher(of: source, against: target)
        let token = UUID().uuidString
        let directory = target.deletingLastPathComponent().appendingPathComponent(".AppleJackUpdate-" + token, isDirectory: true)
        let plan = UpdateInstallPlan(target: target, directory: directory, token: token, parentPID: parentPID,
                                     oldBuild: oldBuild, newBuild: release.build, version: release.version,
                                     channel: release.releaseChannel.rawValue)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try plan.validatePaths()
            _ = try UpdateCommand.run("/usr/bin/ditto", ["--rsrc", "--extattr", source.path, plan.stagedApp.path])
            try validateApp(plan.stagedApp, build: release.build, version: release.version, channel: plan.channel)
            try JSONEncoder().encode(plan).write(to: plan.file, options: .atomic)
            return plan
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    // Atomic exchange: there is never a moment where the installed path is absent.
    // The previous app remains at stagedApp until the new app confirms startup.
    static func swap(_ plan: UpdateInstallPlan) throws {
        try plan.validatePaths()
        guard renamex_np(plan.stagedApp.path, plan.target.path, UInt32(RENAME_SWAP)) == 0 else {
            throw InstallFailure(message: "Apple Jack couldn’t replace the installed copy: \(String(cString: strerror(errno))). The previous app is still available.")
        }
    }

    static func pendingFile(for target: URL) -> URL {
        let name = SHA256.hash(data: Data(target.lastPathComponent.utf8)).map { String(format: "%02x", $0) }.joined()
        return target.deletingLastPathComponent().appendingPathComponent(".AppleJackPending-" + name + ".json")
    }

    static func acknowledgeStartup() {
        acknowledgeStartup(at: Bundle.main.bundleURL,
                           build: Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0)
    }

    static func acknowledgeStartup(at app: URL, build: Int) {
        // Read a validated, per-installation marker rather than launch arguments.
        // Launch Services can reopen an already-starting app without passing args.
        let target = app.resolvingSymlinksInPath().standardizedFileURL
        guard let data = try? Data(contentsOf: pendingFile(for: target)),
              let plan = try? JSONDecoder().decode(UpdateInstallPlan.self, from: data),
              (try? plan.validatePaths()) != nil, plan.target.path == target.path,
              plan.newBuild == build,
              FileManager.default.fileExists(atPath: plan.proceed.path) else { return }
        try? Data(String(plan.newBuild).utf8).write(to: plan.ready, options: .atomic)
    }
}
