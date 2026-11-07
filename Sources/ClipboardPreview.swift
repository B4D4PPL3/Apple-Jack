import AppKit

// The window owns this on the main thread. Image reads/decoding stay off the
// main thread; cancelled or superseded selections cannot publish stale images.
final class ClipboardPreviewLoader {
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.fonz.applejack.clipboard-preview"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private var generation = 0
    private let decode: (ClipboardEntry) -> NSImage?
    init(decode: @escaping (ClipboardEntry) -> NSImage? = ClipboardCapture.thumbnail) { self.decode = decode }
    func cancel() {
        generation += 1
        queue.cancelAllOperations()
    }
    func load(_ entry: ClipboardEntry, completion: @escaping (NSImage?) -> Void) {
        cancel()
        let token = generation
        let decode = self.decode
        queue.addOperation { [weak self] in
            let image = autoreleasepool { decode(entry) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                completion(image)
            }
        }
    }
    deinit { queue.cancelAllOperations() }
}
