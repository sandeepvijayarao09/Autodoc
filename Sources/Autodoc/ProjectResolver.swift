import Foundation

/// An identifying fingerprint for one project, built once per session.
struct ProjectFingerprint: Sendable {
    let name: String            // folder name, e.g. "Meeting Bot"
    let path: String            // absolute path on disk
    let tokens: Set<String>     // lowercased distinctive identifiers (incl. name + words)

    /// Build a fingerprint, auto-deriving tokens from the display name plus any
    /// extra identifiers a scanner pulled from manifests / git.
    static func make(name: String, path: String, extraTokens: [String] = []) -> ProjectFingerprint {
        var toks = Set<String>()
        toks.insert(name.lowercased())
        for word in name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            if word.count >= 4 { toks.insert(String(word)) }
        }
        for t in extraTokens {
            let lt = t.lowercased()
            if lt.count >= 4 { toks.insert(lt) }
        }
        return ProjectFingerprint(name: name, path: path, tokens: toks)
    }

    /// Weighted evidence that a sample belongs to this project.
    func score(title: String, description: String, cwd: String?) -> Double {
        var s = 0.0
        let lname = name.lowercased()
        let lt = title.lowercased()
        let ld = description.lowercased()

        // Terminal working directory is decisive — but respect path boundaries so
        // "/x/TryonBackup" does not match the project "/x/Tryon".
        if let cwd = cwd?.lowercased() {
            let p = path.lowercased()
            if cwd == p || cwd.hasPrefix(p + "/") { s += 100 }
        }

        // Window title is high-trust (editors show the real workspace/file).
        // Longer exact-name matches win ties ("avigis-athena" beats "avigis").
        if lt.contains(lname) {
            s += 45 + Double(lname.count)
        } else if let tok = tokens.first(where: { $0 != lname && $0.count >= 4 && lt.contains($0) }) {
            s += 28 + Double(tok.count) * 0.3
        }

        // On-screen text (the vision model's OCR) is a softer signal.
        if ld.contains(lname) {
            s += 18
        } else if tokens.contains(where: { $0 != lname && $0.count >= 5 && ld.contains($0) }) {
            s += 10
        }
        return s
    }
}

struct Attribution: Sendable {
    var project: String?
    var confidence: Double      // 0…1
    var reason: String
}

/// Resolves which project a screen sample belongs to, by itself, from several
/// signals. No manual picking required (though a manual override still wins).
struct ProjectResolver: Sendable {
    let fingerprints: [ProjectFingerprint]
    var acceptThreshold: Double = 30        // min score to attribute confidently
    var llmBonus: Double = 25               // weight added to the model's own guess

    var names: [String] { fingerprints.map(\.name) }

    /// Deterministic attribution for a terminal command: map a working directory
    /// to the project whose folder contains it (deepest match, boundary-aware).
    func projectForPath(_ path: String) -> String? {
        let p = path.lowercased()
        return fingerprints
            .filter { p == $0.path.lowercased() || p.hasPrefix($0.path.lowercased() + "/") }
            .max(by: { $0.path.count < $1.path.count })?
            .name
    }

    func resolve(title: String?, appName: String?, description: String,
                 cwd: String?, previous: String?, llmGuess: String?) -> Attribution {
        // A known non-work app (browser, Slack, Music…) has an arbitrary title,
        // so mining it for a project name causes false positives. When we're sure
        // it's not an editor/terminal (and there's no decisive cwd), inherit the
        // fused context instead of guessing.
        if appName != nil, cwd == nil {
            let kind = AppClassifier.kind(app: appName)
            if kind == .browser || kind == .other {
                if let previous {
                    return Attribution(project: previous, confidence: 0.3,
                                       reason: "carried over (\(kind.rawValue))")
                }
                return Attribution(project: nil, confidence: 0, reason: "non-work app")
            }
        }

        let title = title ?? ""
        var scored: [(name: String, score: Double)] = fingerprints.map {
            ($0.name, $0.score(title: title, description: description, cwd: cwd))
        }

        // The model's own classification corroborates a matching project.
        if let g = llmGuess?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           g != "none", !g.isEmpty,
           let i = scored.firstIndex(where: { $0.name.lowercased() == g }) {
            scored[i].score += llmBonus
        }

        if let best = scored.max(by: { $0.score < $1.score }), best.score >= acceptThreshold {
            return Attribution(project: best.name,
                               confidence: min(1, best.score / 100),
                               reason: "matched signals (\(Int(best.score)))")
        }

        // Ambiguous frame (e.g. reading docs in a browser mid-task): keep the
        // project you were just in, rather than dropping to unknown every minute.
        if let previous {
            return Attribution(project: previous, confidence: 0.3, reason: "carried over")
        }
        return Attribution(project: nil, confidence: 0, reason: "no match")
    }
}

/// Scans a projects root and builds a fingerprint per subfolder, pulling
/// distinctive tokens from manifests and git so matching survives even when the
/// window title doesn't literally contain the folder name.
enum ProjectScanner {
    /// Autodoc's own folders are never treated as tracked projects.
    private static let ignore: Set<String> = ["Autodoc", "AutodocMac"]

    static func scan(root: String) -> [ProjectFingerprint] {
        // An unset root must scan nothing. `URL(fileURLWithPath: "")` resolves to
        // the process's working directory, which would silently fingerprint
        // whatever happens to be there.
        let trimmed = root.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: trimmed)
        guard let items = try? fm.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }

        var out: [ProjectFingerprint] = []
        for dir in items {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let name = dir.lastPathComponent
            if name.hasPrefix(".") || ignore.contains(name) { continue }
            out.append(make(from: dir, name: name))
        }
        return out.sorted { $0.name < $1.name }
    }

    static func names(root: String) -> [String] { scan(root: root).map(\.name) }

    private static func make(from dir: URL, name: String) -> ProjectFingerprint {
        var extra: [String] = []

        // package.json "name"
        if let data = try? Data(contentsOf: dir.appendingPathComponent("package.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let n = obj["name"] as? String {
            extra.append(n.replacingOccurrences(of: "@", with: "")
                          .replacingOccurrences(of: "/", with: "-"))
        }
        // git remote repo name
        if let cfg = try? String(contentsOf: dir.appendingPathComponent(".git/config"), encoding: .utf8) {
            for line in cfg.components(separatedBy: .newlines) where line.contains("url = ") {
                if let repo = line.split(separator: "/").last {
                    extra.append(repo.replacingOccurrences(of: ".git", with: "")
                                     .trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return ProjectFingerprint.make(name: name, path: dir.path, extraTokens: extra)
    }
}
