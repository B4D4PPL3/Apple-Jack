import AppKit

final class HoldThisService: NSObject {
    private let store: HoldThisStore
    var reveal: (() -> Void)?
    init(store: HoldThisStore) { self.store = store }

    @objc func addToHoldThis(_ board: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        do {
            try receive(board)
            reveal?()
        } catch let failure {
            error.pointee = failure.localizedDescription as NSString
        }
    }
    func receive(_ board: NSPasteboard) throws {
        // Finder Services can still send one legacy list of multiple paths.
        // Normalize that list without changing either the service pasteboard or
        // the user's general clipboard. The ordinary drop importer handles the rest.
        if let paths = board.propertyList(forType: .init("NSFilenamesPboardType")) as? [String], !paths.isEmpty {
            guard paths.allSatisfy({ ($0 as NSString).isAbsolutePath }) else {
                throw NSError(domain: "AppleJack.HoldThis", code: 1, userInfo: [NSLocalizedDescriptionKey: "The source app did not provide valid file locations."])
            }
            let transfer = NSPasteboard.withUniqueName()
            defer { transfer.releaseGlobally() }
            guard transfer.writeObjects(paths.map { NSURL(fileURLWithPath: $0) }) else {
                throw NSError(domain: "AppleJack.HoldThis", code: 2, userInfo: [NSLocalizedDescriptionKey: "Jack couldn’t receive the selected files."])
            }
            try store.accept(transfer)
        } else { try store.accept(board) }
    }
}
