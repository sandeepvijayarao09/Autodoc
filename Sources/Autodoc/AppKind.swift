import Foundation

/// How much to trust a frontmost app for project attribution.
///   editor/terminal → trustworthy (their titles name the workspace/path)
///   browser/other   → untrustworthy (arbitrary page titles) → inherit context
enum AppKind: String, Sendable { case editor, terminal, browser, other }

enum AppClassifier {
    private static let editors = ["cursor", "visual studio code", "code", "xcode",
        "sublime text", "sublime", "intellij", "pycharm", "webstorm", "goland",
        "clion", "phpstorm", "rubymine", "rider", "android studio", "nova", "zed",
        "fleet", "emacs", "neovim", "macvim", "textmate", "bbedit"]
    private static let terminals = ["terminal", "iterm", "warp", "alacritty",
        "kitty", "wezterm", "tabby", "ghostty", "hyper"]
    private static let browsers = ["safari", "google chrome", "chrome", "chromium",
        "firefox", "arc", "brave", "microsoft edge", "edge", "orion", "vivaldi",
        "opera", "duckduckgo"]

    static func kind(app: String?) -> AppKind {
        guard let a = app?.lowercased().trimmingCharacters(in: .whitespaces), !a.isEmpty else {
            return .other
        }
        // Short tokens (e.g. "arc", "edge") must match exactly to avoid matching
        // an unrelated app that merely contains those letters.
        func matches(_ tokens: [String]) -> Bool {
            tokens.contains { a == $0 || ($0.count >= 4 && a.contains($0)) }
        }
        if matches(editors) { return .editor }
        if matches(terminals) { return .terminal }
        if matches(browsers) { return .browser }
        return .other
    }
}
