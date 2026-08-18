import Foundation

/// Tails the zsh command log during a session, attributes each command to a
/// project by its working directory (deterministic — no guessing), and appends
/// it to the same encrypted store the screen events go to.
actor CommandWatcher {
    func run(config: Config, context: SharedContext, store: SecureStore,
             out: AsyncStream<SampleSummary>.Continuation) async {
        let resolver = ProjectResolver(fingerprints: ProjectScanner.scan(root: config.projectsRoot))
        let url = TerminalHook.commandsLog
        var offset: UInt64 = 0   // begin() truncated the log, so start at the top

        while !Task.isCancelled {
            let (lines, newOffset) = Self.readNewLines(url: url, from: offset)
            offset = newOffset
            for line in lines {
                guard let (ts, pwd, cmd) = CommandLog.parse(line) else { continue }
                let project = resolver.projectForPath(pwd)
                // A command's cwd is a decisive, high-trust context signal that
                // then informs the screen frames around it.
                await context.note(project)
                let ev = Event(ts: ts, iso: Date(timeIntervalSince1970: ts).isoStamp,
                               type: "command", text: cmd, project: project,
                               app: "Terminal", windowTitle: pwd, trigger: "terminal")
                await store.append(ev)
                out.yield(SampleSummary(kind: .command, text: cmd, project: project))
            }
            try? await Task.sleep(nanoseconds: 800_000_000)   // ~0.8 s poll
        }
    }

    /// Read complete new lines since `offset`; a trailing partial line is left
    /// for the next poll so we never emit a half-written command.
    private static func readNewLines(url: URL, from offset: UInt64) -> (lines: [String], newOffset: UInt64) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return ([], offset) }
        defer { try? h.close() }
        try? h.seek(toOffset: offset)
        let data = (try? h.readToEnd()) ?? Data()
        guard let lastNL = data.lastIndex(of: 0x0A) else { return ([], offset) }
        let consume = data[data.startIndex...lastNL]
        let text = String(decoding: consume, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return (lines, offset + UInt64(consume.count))
    }
}
