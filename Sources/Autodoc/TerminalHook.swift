import Foundation

/// Manages the opt-in zsh hook that logs terminal commands (with `$PWD`) while a
/// session is active. The hook only writes when the `active` flag file exists, so
/// it has zero effect — and logs nothing — outside a recording session.
enum TerminalHook {
    static var commandsLog: URL { AppPaths.support.appendingPathComponent("commands.log") }
    static var activeFlag: URL { AppPaths.support.appendingPathComponent("active") }

    private static var zshrc: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
    }
    private static let marker = "# >>> autodoc terminal capture >>>"
    private static let endMarker = "# <<< autodoc terminal capture <<<"

    private static func block() -> String {
        """
        \(marker)
        autoload -Uz add-zsh-hook 2>/dev/null
        _autodoc_preexec() {
          [[ -f '\(activeFlag.path)' ]] || return
          print -r -- "${EPOCHSECONDS:-$(date +%s)}"$'\\t'"$PWD"$'\\t'"$1" >> '\(commandsLog.path)' 2>/dev/null
        }
        add-zsh-hook preexec _autodoc_preexec 2>/dev/null
        \(endMarker)
        """
    }

    static var isInstalled: Bool {
        (try? String(contentsOf: zshrc, encoding: .utf8))?.contains(marker) ?? false
    }

    static func install() {
        guard !isInstalled else { return }
        var text = (try? String(contentsOf: zshrc, encoding: .utf8)) ?? ""
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += "\n" + block() + "\n"
        try? text.write(to: zshrc, atomically: true, encoding: .utf8)
    }

    static func uninstall() {
        guard var text = try? String(contentsOf: zshrc, encoding: .utf8),
              let start = text.range(of: marker),
              let end = text.range(of: endMarker) else { return }
        text.removeSubrange(start.lowerBound..<end.upperBound)
        try? text.write(to: zshrc, atomically: true, encoding: .utf8)
    }

    /// Session start: clear the command log and raise the active flag.
    static func begin() {
        AppPaths.ensure()
        try? Data().write(to: commandsLog)
        FileManager.default.createFile(atPath: activeFlag.path, contents: nil)
    }

    /// Session stop: lower the active flag so the hook stops logging immediately.
    static func end() {
        try? FileManager.default.removeItem(at: activeFlag)
    }
}
