import Foundation
import Darwin

// A PID can remain present briefly after exit until its launcher reaps it.
// Observe the kernel exit event rather than waiting for the PID to disappear.
final class ProcessExitMonitor {
    private let lock = NSLock()
    private var exited = false
    private let pid: Int32
    private let source: DispatchSourceProcess

    init(pid: Int32) {
        self.pid = pid
        source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.lock.lock(); self.exited = true; self.lock.unlock()
        }
        source.resume()
    }
    var hasExited: Bool {
        lock.lock(); let value = exited; lock.unlock()
        return value || (kill(pid, 0) != 0 && errno == ESRCH)
    }
    deinit { source.cancel() }
}
