import AppKit
import Sparkle

/// The public edition reads an HTTPS appcast and lets Sparkle verify the
/// archive against the public Ed25519 key embedded in this application.
final class SparkleUpdates: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?
    private var expectedRelease: UpdateRelease?
    private var activeFeedURL: URL?
    private var expectedDownloadURL: URL?
    private var deferredRestart: Task<Void, Never>?
    var canInstall: (() -> Bool)?
    var isBusy: Bool { expectedRelease != nil || controller?.updater.sessionInProgress == true }

    func begin(release: UpdateRelease) throws {
        guard !isBusy else { throw InstallFailure(message: UpdateCheckReport.busy.message) }
        try release.requireSparkleSignature()
        guard canInstall?() != false else {
            throw InstallFailure(message: "Finish the current request or stop speaking or recording before updating Jack.")
        }
        let repo = try GitHubUpdates.repositoryURL(Bundle.main.object(forInfoDictionaryKey: "AppleJackGitHubRepository") as? String)
        expectedRelease = release
        activeFeedURL = GitHubUpdates.feedURL(in: repo)
        expectedDownloadURL = GitHubUpdates.assetURL(for: release, in: repo)
        var launched = false
        defer { if !launched { cleanup() } }
        if controller == nil {
            let value = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
            controller = value
            try value.updater.start()
        }
        guard let controller, controller.updater.canCheckForUpdates else {
            throw InstallFailure(message: "The previous update check is still finishing. Try again shortly.")
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
        launched = true
    }

    func feedURLString(for updater: SPUUpdater) -> String? { activeFeedURL?.absoluteString }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard expectedRelease != nil else { throw UpdateError.missingRelease }
        guard canInstall?() != false else {
            throw InstallFailure(message: "Finish the current request or stop speaking or recording before updating Jack.")
        }
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard let expectedRelease,
              Int(item.versionString) == expectedRelease.build,
              item.displayVersionString == expectedRelease.version,
              item.fileURL == expectedDownloadURL else { throw UpdateError.invalidRelease }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard canInstall?() == false else { return false }
        deferredRestart = Task { @MainActor [weak self] in
            while let self, self.canInstall?() == false {
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            }
            guard !Task.isCancelled else { return }
            installHandler()
        }
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error { NSLog("Apple Jack update finished: %@", error.localizedDescription) }
        cleanup()
    }

    private func cleanup() {
        deferredRestart?.cancel()
        deferredRestart = nil
        expectedRelease = nil
        activeFeedURL = nil
        expectedDownloadURL = nil
    }
}
