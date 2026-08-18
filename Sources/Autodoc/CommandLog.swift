import Foundation

/// Parses one line the zsh hook wrote: `<epoch>\t<pwd>\t<command>`.
/// Pure and dependency-free so it can be unit-tested directly.
enum CommandLog {
    /// Parse and **redact** one hook line. Redaction happens here, at the single
    /// point every captured command must pass through, so no caller can
    /// accidentally persist a raw credential — see `Redactor`.
    static func parse(_ line: String) -> (ts: Double, pwd: String, cmd: String)? {
        // maxSplits: 2 keeps any tabs inside the command itself intact.
        let parts = line.split(separator: "\t", maxSplits: 2,
                               omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return nil }
        let cmd = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, !parts[1].isEmpty else { return nil }
        let ts = Double(parts[0]) ?? Date().timeIntervalSince1970
        return (ts, parts[1], Redactor.redact(cmd))
    }
}
