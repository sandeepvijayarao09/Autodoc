import Foundation

/// Thread-safe holder for a manual project override (nil = auto-detect).
actor SharedSelection {
    private var value: String?
    func set(_ v: String?) { value = v }
    func current() -> String? { value }
}

/// Consumes capture triggers (from `ActivityMonitor`) and, for each, samples the
/// screen, describes it with the vision model, attributes it to a project, and
/// stores the result. Fully decoupled from *when* to capture — that's the
/// trigger source's job — so the same engine serves both activity and interval
/// modes. Off-loads the model call from the main actor.
actor CaptureEngine {
    private var lastHash: UInt64 = 0
    private var haveLast = false

    func run(config: Config,
             sessionID: String,
             selection: SharedSelection,
             context: SharedContext,
             store: SecureStore,
             triggers: AsyncStream<CaptureTrigger>,
             out: AsyncStream<SampleSummary>.Continuation) async {

        let ollama = OllamaClient(host: config.ollamaHost, model: config.model)
        let resolver = ProjectResolver(fingerprints: ProjectScanner.scan(root: config.projectsRoot))
        let prompt = visionPrompt(projects: resolver.names)

        // reset per-session state
        lastHash = 0; haveLast = false

        await store.begin(sessionID: sessionID)
        await store.append(marker("session started"))
        out.yield(SampleSummary(kind: .session, text: "session started", project: nil))

        for await trigger in triggers {
            await captureOnce(trigger: trigger, sessionID: sessionID, config: config,
                              resolver: resolver, prompt: prompt, ollama: ollama,
                              selection: selection, context: context, store: store, out: out)
        }

        await store.append(marker("session stopped"))
        out.yield(SampleSummary(kind: .session, text: "session stopped", project: nil))
        out.finish()
    }

    // MARK: - One capture

    private func captureOnce(trigger: CaptureTrigger, sessionID: String, config: Config,
                             resolver: ProjectResolver, prompt: String, ollama: OllamaClient,
                             selection: SharedSelection, context: SharedContext, store: SecureStore,
                             out: AsyncStream<SampleSummary>.Continuation) async {
        do {
            let frame = try await ScreenCapturer.capture(
                excludingBundleIDs: Set(config.excludedBundleIDs),
                maxDimension: config.maxDimension,
                keepFrame: config.keepScreenshots)

            // Even a legitimate trigger can land on a visually-unchanged screen.
            if config.idleSkip && haveLast && ScreenCapturer.hamming(frame.aHash, lastHash) < 4 {
                lastHash = frame.aHash
                return
            }
            lastHash = frame.aHash
            haveLast = true

            let b64 = frame.png.base64EncodedString()
            let raw = (try? await ollama.generate(prompt: prompt, imageBase64: b64)) ?? ""
            let (described, guess) = parse(raw)
            // The model can read a token that happened to be visible on screen, so
            // its description gets the same scrubbing as a terminal command.
            let desc = Redactor.redact(described)

            let project: String?
            if let manual = await selection.current() {
                project = manual
            } else {
                let att = resolver.resolve(
                    title: frame.windowTitle, appName: frame.appName,
                    description: desc, cwd: nil,
                    previous: await context.current(), llmGuess: guess)
                project = att.project
                if att.reason.hasPrefix("matched") { await context.note(att.project) }
            }

            // Optionally persist the pixels as an encrypted HEIC, bounded by budget.
            var shot: String?
            if config.keepScreenshots, let heic = frame.heic {
                shot = await store.saveFrame(heic, sessionID: sessionID,
                                             ts: trigger.time.timeIntervalSince1970)
                await store.enforceFrameBudget(maxBytes: config.maxFrameBytes)
            }

            let ev = Event(ts: trigger.time.timeIntervalSince1970, iso: trigger.time.isoStamp,
                           type: "screen", text: desc, project: project,
                           app: frame.appName, windowTitle: frame.windowTitle,
                           trigger: trigger.reason, shot: shot)
            await store.append(ev)
            out.yield(SampleSummary(kind: .screen, text: desc, project: project))
        } catch {
            out.yield(SampleSummary(kind: .error, text: "\(error)", project: nil))
        }
    }

    // MARK: - Prompt

    private func visionPrompt(projects: [String]) -> String {
        let list = projects.isEmpty ? "(none known)" : projects.joined(separator: ", ")
        return """
        You are a work-activity logger looking at a screenshot of the user's Mac. \
        Reply in EXACTLY two lines and nothing else:
        ACTIVITY: one factual sentence — the app in focus and the SPECIFIC content \
        (file names, terminal commands, page/document titles, settings, errors). Be \
        concrete; ignore wallpaper and generic UI. If the screen is idle, write: idle
        PROJECT: which one of these projects the activity belongs to — [\(list)] — \
        judging from visible file paths, repo names, titles or content. Output only \
        the exact project name, or 'none' if genuinely unclear.
        """
    }

    private func parse(_ raw: String) -> (desc: String, guess: String?) {
        var desc = "(no description)"
        var guess: String?
        for line in raw.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if let r = l.range(of: "ACTIVITY:", options: [.caseInsensitive]) {
                desc = String(l[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if let r = l.range(of: "PROJECT:", options: [.caseInsensitive]) {
                let g = String(l[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                guess = (g.isEmpty || g.lowercased() == "none") ? nil : g
            }
        }
        if desc == "(no description)", !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            desc = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (desc, guess)
    }

    private func marker(_ text: String) -> Event {
        let now = Date()
        return Event(ts: now.timeIntervalSince1970, iso: now.isoStamp,
                     type: "session", text: text, project: nil, app: nil, windowTitle: nil)
    }
}
