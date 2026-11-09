import AppKit
import ServiceManagement

// macOS owns the saved preference. Query it when either menu opens so changes
// in System Settings are reflected without a separate UserDefaults flag.
final class StartAtLogin: NSObject, NSMenuItemValidation {
    private let service = SMAppService.mainApp

    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Start at Login", action: #selector(toggle), keyEquivalent: "")
        item.target = self
        update(item)
        return item
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        update(menuItem)
        return true
    }

    private func update(_ item: NSMenuItem) {
        item.title = "Start at Login"
        item.toolTip = "Automatically open Apple Jack when you log into your Mac."
        switch service.status {
        case .enabled:
            item.state = .on
            item.toolTip = "Apple Jack starts at login. Click to turn this off."
        case .requiresApproval:
            item.state = .mixed
            item.title = "Start at Login (Needs Approval…)"
            item.toolTip = "Approve Apple Jack in Login Items, or turn off Start at Login."
        default:
            item.state = .off
        }
    }

    @objc private func toggle() {
        switch service.status {
        case .enabled:
            setEnabled(false)
        case .requiresApproval:
            showApprovalOptions()
        case .notRegistered, .notFound:
            setEnabled(true)
        @unknown default:
            showError("macOS returned an unknown login-item status. Check Apple Jack in System Settings → General → Login Items.")
        }
    }

    private func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try service.register() }
            else { try service.unregister() }
        } catch {
            // Registration can report denied approval while the service is
            // already registered. Offer the real next step in that case.
            if enabled && service.status == .requiresApproval {
                showApprovalOptions()
            } else {
                showError(error.localizedDescription)
            }
            return
        }
        if enabled && service.status == .requiresApproval { showApprovalOptions() }
    }

    private func showApprovalOptions() {
        let alert = NSAlert()
        alert.messageText = "Allow Apple Jack to start at login"
        alert.informativeText = "macOS needs your approval. Open Login Items in System Settings and enable Apple Jack, or turn off Start at Login."
        alert.addButton(withTitle: "Open Login Settings")
        alert.addButton(withTitle: "Turn Off")
        alert.addButton(withTitle: "Cancel")
        alert.presentInJack { [self] response in
            switch response {
            case .alertFirstButtonReturn:
                SMAppService.openSystemSettingsLoginItems()
            case .alertSecondButtonReturn:
                setEnabled(false)
            default:
                break
            }
        }
    }

    private func showError(_ details: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t change Start at Login"
        alert.informativeText = details
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Login Settings")
        alert.presentInJack { response in
            if response == .alertSecondButtonReturn {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    }
}
