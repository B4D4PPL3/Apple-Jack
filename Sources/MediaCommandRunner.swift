import Foundation
import Darwin

enum MediaCommand: Int, CaseIterable {
    // MediaRemote transport commands, not simulated keyboard events.
    case back = 5
    case playPause = 2
    case forward = 4
}

final class MediaCommandRunner {
    private let executable: URL
    private let script: URL?
    private let nativeScript: URL?
    private let framework: URL?
    private let timeout: TimeInterval
    private var process: Process?
    private var requestID = UUID()
    private var deadline: DispatchWorkItem?
    private var completion: ((String?) -> Void)?
    var busyDidChange: ((Bool) -> Void)?
    var isBusy: Bool { process != nil }

    init(executable: URL = URL(fileURLWithPath: "/usr/bin/perl"),
         script: URL? = Bundle.main.resourceURL?.appendingPathComponent("mediaremote-adapter.pl"),
         nativeScript: URL? = Bundle.main.resourceURL?.appendingPathComponent("applejack-media.pl"),
         framework: URL? = Bundle.main.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework"),
         timeout: TimeInterval = 4) {
        self.executable = executable
        self.script = script
        self.nativeScript = nativeScript
        self.framework = framework
        self.timeout = timeout
    }

    // Drop additional clicks while a command is pending. Never queue a second
    // play/pause toggle or replay a timed-out command: it may have been delivered.
    @discardableResult
    func send(_ command: MediaCommand, target: NativeMediaRequest? = nil, completion: @escaping (String?) -> Void) -> Bool {
        guard !isBusy else { return false }
        guard let script = target == nil ? script : nativeScript, let framework = framework else {
            completion("Jack’s media helper is missing. Reinstall the latest beta and try again.")
            return false
        }
        let requestData = target.flatMap { try? JSONEncoder().encode($0) }
        if target != nil && (requestData == nil || requestData!.count > 16_384) {
            completion("This source can’t be controlled directly. Open its player to use the controls there.")
            return false
        }
        let child = Process()
        let identifier = UUID()
        requestID = identifier
        self.completion = completion
        child.executableURL = executable
        child.arguments = target == nil ? [script.path, framework.path, "send", String(command.rawValue)] : [script.path, framework.path, "selected"]
        child.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
            "APPLEJACK_HOST_PID": String(ProcessInfo.processInfo.processIdentifier)]
        let input = target == nil ? nil : Pipe()
        child.standardInput = input?.fileHandleForReading ?? FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] child in
            DispatchQueue.main.async {
                let error = child.terminationStatus == 0 ? nil : target != nil ?
                    "This source can’t currently be controlled through macOS. Open its player to use the playback controls there." :
                    "The media service didn’t accept that command. Start playback in your media app and try again."
                self?.finish(identifier, error: error)
            }
        }
        process = child
        busyDidChange?(true)
        do {
            try child.run()
            if let input, let requestData {
                if #available(macOS 10.15.4, *) {
                    try input.fileHandleForWriting.write(contentsOf: requestData)
                } else {
                    let fd = input.fileHandleForWriting.fileDescriptor
                    guard fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    try requestData.withUnsafeBytes { bytes in
                        var sent = 0
                        while sent < bytes.count {
                            let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
                            if n < 0 && errno == EINTR { continue }
                            guard n > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                            sent += n
                        }
                    }
                }
                try input.fileHandleForWriting.close()
            }
            let deadline = DispatchWorkItem { [weak self] in
                self?.finish(identifier, error: "The media service took too long to respond. Check your player before trying again.")
            }
            self.deadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: deadline)
        } catch {
            finish(identifier, error: "Jack couldn’t start the media controls. Reopen Jack and try again.")
        }
        return true
    }

    private func finish(_ identifier: UUID, error: String?) {
        guard requestID == identifier, isBusy else { return }
        let callback = completion
        cancel()
        callback?(error)
    }

    func cancel() {
        requestID = UUID()
        deadline?.cancel(); deadline = nil
        completion = nil
        let child = process
        let wasBusy = isBusy
        process = nil
        if let child = child, child.isRunning {
            child.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        if wasBusy { busyDidChange?(false) }
    }
    deinit { cancel() }
}
