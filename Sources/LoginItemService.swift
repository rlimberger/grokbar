import Foundation
import ServiceManagement
import os.log

/// Best-effort Launch at Login via SMAppService. No UI — GrokBar always tries to stay registered.
enum LoginItemService {
    private static let log = Logger(subsystem: "com.rlimberger.GrokBar", category: "LoginItem")

    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static var isEnabled: Bool {
        status == .enabled
    }

    /// Register as a login item if not already enabled. Never throws to callers.
    /// macOS may leave status at `.requiresApproval` until the user allows the item
    /// in System Settings → General → Login Items — we still return and keep running.
    @discardableResult
    static func ensureEnabled() -> SMAppService.Status {
        let current = SMAppService.mainApp.status
        if current == .enabled {
            return current
        }
        do {
            try SMAppService.mainApp.register()
        } catch {
            log.error("Login item register failed: \(error.localizedDescription, privacy: .public)")
        }
        let after = SMAppService.mainApp.status
        if after == .requiresApproval {
            log.notice("Login item requires approval in System Settings → General → Login Items")
        } else if after != .enabled {
            log.error("Login item status after register: \(String(describing: after), privacy: .public)")
        }
        return after
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
