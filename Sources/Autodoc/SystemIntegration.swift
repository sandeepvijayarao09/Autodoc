import Foundation
import AppKit
import ServiceManagement

/// Thin wrappers around the macOS affordances the app needs: picking a folder,
/// deep-linking into the right Privacy pane, and registering as a login item.
/// Isolated here so the views stay declarative and these calls are easy to stub.

enum FolderPicker {
    /// Present a directory chooser. Returns nil if the user cancels.
    @MainActor
    static func chooseDirectory(title: String, initial: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if let initial, !initial.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: initial)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

enum SystemSettings {
    /// Open System Settings directly at Privacy & Security → Screen Recording.
    /// Without this a denied permission is a dead end: the user sees a red status
    /// chip and has to hunt for the pane themselves.
    @MainActor
    static func openScreenRecordingPrivacy() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}

/// Launch-at-login via `SMAppService` (the supported API since macOS 13).
///
/// Registration only succeeds for a signed app bundle, so running from
/// `swift run` reports `.notFound` / throws — surfaced as `false` rather than
/// crashing.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns true when the requested state was achieved.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            return false
        }
    }
}
