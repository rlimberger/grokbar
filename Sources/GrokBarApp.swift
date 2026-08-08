import AppKit
import ServiceManagement
import SwiftUI

@main
struct GrokBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Placeholder scene — the real UI is the AppKit status item.
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = UsageViewModel()
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Optional one-shot CLI for debugging login-item registration.
        if CommandLine.arguments.contains("--register-login-item") {
            let status = LoginItemService.ensureEnabled()
            fputs("launch-at-login: \(statusDescription(status))\n", stderr)
            if status == .requiresApproval {
                fputs(
                    "Allow GrokBar in System Settings → General → Login Items.\n",
                    stderr
                )
            }
            exit(status == .enabled || status == .requiresApproval ? 0 : 1)
        }
        if CommandLine.arguments.contains("--unregister-login-item") {
            do {
                try LoginItemService.setEnabled(false)
                fputs("launch-at-login: disabled\n", stderr)
                exit(0)
            } catch {
                fputs("launch-at-login failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        // Menu-bar only: no Dock icon.
        NSApp.setActivationPolicy(.accessory)

        // Pin placement prefs before the status item is created.
        StatusBarController.preferLeftmostStatusItem()

        let controller = StatusBarController(model: model)
        controller.install()
        statusBar = controller

        // model.start() also re-asserts Launch at Login silently.
        model.start()
    }

    private func statusDescription(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

// MARK: - Shared icon

enum GrokMenuIcon {
    /// Official Grok mark as a template image (system recolors for light/dark menu bar).
    static let image: NSImage = {
        let pointSize = NSSize(width: 16, height: 16)
        let img = NSImage(size: pointSize)
        img.isTemplate = true

        let names = ["GrokIcon", "GrokIcon@2x", "GrokIcon@3x"]
        for name in names {
            let url =
                Bundle.main.url(forResource: name, withExtension: "png")
                ?? Bundle.main.resourceURL?.appendingPathComponent("\(name).png")
            guard let url,
                  FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let rep = NSBitmapImageRep(data: data)
            else { continue }
            rep.size = pointSize
            img.addRepresentation(rep)
        }

        if img.representations.isEmpty {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Grok")?
                .withSymbolConfiguration(config)
            {
                symbol.isTemplate = true
                return symbol
            }
        }

        return img
    }()
}

enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    static var versionLabel: String {
        "v\(version) (\(build))"
    }
}
