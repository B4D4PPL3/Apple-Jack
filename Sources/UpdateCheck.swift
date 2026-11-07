import Foundation

enum UpdateCheckTrigger {
    case menu, command, startup, channelChange

    var isAutomatic: Bool { self == .startup || self == .channelChange }
    var showsProgress: Bool { !isAutomatic }
}

struct UpdateCheckReport {
    let message: String
    let succeeded: Bool

    static let canceled = UpdateCheckReport(message: "Update check canceled.", succeeded: false)
    static let busy = UpdateCheckReport(message: "An update is already in progress. Let it finish, then try again.", succeeded: false)
}

enum UpdateInputCommand {
    static func matches(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "update"
    }
}
