import Foundation

final class PetAutoImport {
    private let enabledKey = "automaticallyImportChatGPTPets"
    private let sourcesKey = "automaticallyImportedPetSources"
    private let library: ImportedPets
    // Manual changes and automatic imports commit one at a time.
    let libraryQueue = DispatchQueue(label: "com.fonz.applejack.pet-library", qos: .userInitiated)
    private let worker = OperationQueue()
    private var task: BlockOperation?
    private var timer: Timer?
    private(set) var status: String?
    var changed: (() -> Void)?
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    init(library: ImportedPets) {
        self.library = library
        worker.maxConcurrentOperationCount = 1
        worker.qualityOfService = .utility
    }

    func toggle() {
        UserDefaults.standard.set(!isEnabled, forKey: enabledKey)
        start()
    }

    func start() {
        timer?.invalidate()
        timer = nil
        if isEnabled {
            let next = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in self?.check() }
            next.tolerance = 60
            timer = next
            check()
        } else {
            task?.cancel()
            task = nil
            status = nil
            changed?()
        }
    }

    private func check() {
        guard isEnabled, task == nil else { return }
        let job = BlockOperation()
        task = job
        status = "Checking for pets…"
        changed?()
        job.addExecutionBlock { [weak self, weak job] in
            guard let self, let job, !job.isCancelled else { return }
            let local = ChatGPTPetCatalog.installed()
            let account = try? ChatGPTAccountPets.list()
            let candidates = ChatGPTPetCatalog.merged(local: local, account: account ?? [])
            var failed = 0
            for pet in candidates {
                guard !job.isCancelled else { return }
                guard let key = pet.id else { continue }
                let index = UserDefaults.standard.dictionary(forKey: self.sourcesKey) as? [String: String] ?? [:]
                if let digest = index[key], self.library.contains(digest) { continue }
                do {
                    try autoreleasepool {
                        let data = try pet.data()
                        try self.libraryQueue.sync {
                            guard !job.isCancelled else { return }
                            let (saved, _) = try self.library.add(data: data, named: pet.name)
                            var updated = index
                            updated[key] = saved.id
                            UserDefaults.standard.set(updated, forKey: self.sourcesKey)
                        }
                    }
                } catch { failed += 1 }
            }
            let message: String?
            if account == nil { message = "Account unavailable · Will retry" }
            else if failed > 0 { message = "Some pets couldn’t import · Will retry" }
            else { message = nil }
            DispatchQueue.main.async {
                guard self.task === job else { return }
                self.status = message
                self.task = nil
                self.changed?()
            }
        }
        worker.addOperation(job)
    }
}
