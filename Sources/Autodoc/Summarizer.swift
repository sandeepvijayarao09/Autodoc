import Foundation

/// Turns a session's raw events into a readable per-project running log.
/// Idempotent: each session contributes exactly one delimited block per project,
/// so re-summarising replaces rather than duplicates (fixes the Python bug).
struct Summarizer: Sendable {
    let config: Config

    func summarize(sessionID: String, store: SecureStore) async {
        let events = await store.readEvents(sessionID: sessionID)
        guard !events.isEmpty else { return }
        let ollama = OllamaClient(host: config.ollamaHost, model: config.model)

        // Bucket by project.
        var buckets: [String: [Event]] = [:]
        for e in events where e.type != "session" {
            buckets[e.project ?? "_unsorted", default: []].append(e)
        }

        for (project, evs) in buckets {
            let sorted = evs.sorted { $0.ts < $1.ts }
            let transcript = sorted
                .map { "\($0.iso)  [\($0.type)]  \($0.text)" }
                .joined(separator: "\n")

            let prompt = """
            You are keeping a running work log for a developer. Below is a raw, \
            timestamped transcript of one work session on the project '\(project)'. \
            'screen' lines are what was visible; 'command' lines are terminal \
            commands. Write a clean Markdown log entry a future reader could follow:
            - Group related activity into short time-ordered bullets.
            - Call out concretely: commands run, files/settings changed, tools used, \
            errors hit and how they were resolved.
            - Be faithful to the transcript; do NOT invent steps. Skip 'idle' noise.
            - No preamble, no heading — just the bullets.

            TRANSCRIPT:
            \(transcript)
            """

            let body = (try? await ollama.generate(prompt: prompt)) ?? "*(summary failed)*"
            AppPaths.ensure()
            writeBlock(in: AppPaths.logs, project: project, sessionID: sessionID,
                       date: sorted.first?.iso ?? sessionID, body: body)
        }
    }

    /// Replace-or-append a `<!-- session:ID -->…<!-- /session:ID -->` block in
    /// `logsDir/<project>.md`. Idempotent: re-running the same session replaces
    /// its block instead of appending a duplicate. `internal` for unit testing.
    func writeBlock(in logsDir: URL, project: String, sessionID: String, date: String, body: String) {
        let url = logsDir.appendingPathComponent("\(project).md")
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? "# \(project) — running log\n"

        let open = "<!-- session:\(sessionID) -->"
        let close = "<!-- /session:\(sessionID) -->"
        let block = """
        \(open)
        ## \(date)

        \(body.trimmingCharacters(in: .whitespacesAndNewlines))
        \(close)
        """

        if let r = text.range(of: open), let rc = text.range(of: close) {
            text.replaceSubrange(r.lowerBound..<rc.upperBound, with: block)
        } else {
            text += "\n\n" + block + "\n"
        }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
