import SwiftUI
import AppKit

@main
struct AutodocApp: App {
    @StateObject private var controller = Controller()
    @StateObject private var library = LibraryStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(controller)
        } label: {
            Image(systemName: controller.stats.running ? "record.circle.fill" : "record.circle")
        }
        .menuBarExtraStyle(.window)

        // WindowGroup opens a window at launch, so the app is visibly "open".
        WindowGroup("Autodoc Library", id: "library") {
            LibraryView().environmentObject(library)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView().environmentObject(controller)
        }
    }
}

// MARK: - Controller

@MainActor
final class Controller: ObservableObject {
    @Published var stats = LiveStats()
    @Published var settings = Config.load()
    @Published var currentProject: String?          // nil == auto-detect
    @Published var knownProjects: [String] = []

    private let engine = CaptureEngine()
    private let store = SecureStore()
    private let selection = SharedSelection()
    private let context = SharedContext()
    private let monitor = ActivityMonitor()
    private let commandWatcher = CommandWatcher()
    private var engineTask: Task<Void, Never>?
    private var consumeTask: Task<Void, Never>?
    private var watcherTask: Task<Void, Never>?
    private var sessionID = ""

    init() {
        knownProjects = ProjectScanner.names(root: settings.projectsRoot)
        Task { await refresh() }
    }

    func toggle() { stats.running ? stop() : start() }

    func start() {
        guard !stats.running else { return }
        AppPaths.ensure()
        if settings.deleteFramesOnStop {   // clear frames left by a previously crashed session
            let store = self.store
            Task { await store.purgeAllFrames() }
        }
        TerminalHook.begin()          // truncate command log + raise the active flag
        sessionID = Date().sessionStamp
        stats.running = true
        stats.sessionStart = Date()
        stats.screenSamples = 0
        stats.commandsCaptured = 0
        stats.projects = []
        stats.lastError = nil

        let triggers = monitor.makeStream(config: settings)
        let (sampleStream, sampleCont) = AsyncStream.makeStream(of: SampleSummary.self)
        let cfg = settings
        let sid = sessionID
        let engine = self.engine
        let store = self.store
        let selection = self.selection
        let context = self.context
        let commandWatcher = self.commandWatcher
        Task { await context.reset() }   // fresh context per session

        engineTask = Task {
            await engine.run(config: cfg, sessionID: sid, selection: selection,
                             context: context, store: store, triggers: triggers, out: sampleCont)
        }
        watcherTask = Task {
            await commandWatcher.run(config: cfg, context: context, store: store, out: sampleCont)
        }
        consumeTask = Task { [weak self] in
            for await sample in sampleStream { self?.apply(sample) }
            await self?.finishSession(sessionID: sid, config: cfg)
        }
    }

    func stop() {
        guard stats.running else { return }
        stats.running = false
        TerminalHook.end()          // lower the active flag → hook stops logging
        watcherTask?.cancel()
        watcherTask = nil
        monitor.stop()              // finishes the trigger stream → engine ends, then summarises
    }

    private func finishSession(sessionID: String, config: Config) async {
        let summarizer = Summarizer(config: config)
        await summarizer.summarize(sessionID: sessionID, store: store)
        if config.deleteFramesOnStop { await store.purgeAllFrames() }  // nothing kept overnight
        await store.enforceRetention(days: config.retentionDays)
        stats.lastDescription = "logs updated ✓"
    }

    func setProject(_ project: String?) {
        currentProject = project
        let selection = self.selection
        Task { await selection.set(project) }
    }

    func rescanProjects() {
        knownProjects = ProjectScanner.names(root: settings.projectsRoot)
    }

    /// Ask for the folder whose subfolders are the tracked projects, then rescan.
    func chooseProjectsRoot() {
        guard let url = FolderPicker.chooseDirectory(
            title: "Choose the folder that contains your projects",
            initial: settings.projectsRoot) else { return }
        settings.projectsRoot = url.path
        settings.save()
        rescanProjects()
    }

    func refresh() async {
        let permission = await ScreenCapturer.hasPermission()
        let ollamaOK = await OllamaClient(host: settings.ollamaHost,
                                          model: settings.model).ping()
        stats.permissionOK = permission
        stats.ollamaOK = ollamaOK
    }

    private func apply(_ s: SampleSummary) {
        switch s.kind {
        case .screen:
            stats.screenSamples += 1
            stats.lastDescription = s.text
            if let p = s.project { stats.projects.insert(p) }
        case .command:
            stats.commandsCaptured += 1
            stats.lastDescription = "$ \(s.text)"
            if let p = s.project { stats.projects.insert(p) }
        case .session:
            stats.lastDescription = s.text
        case .error:
            stats.lastError = s.text
            if s.text.contains("permission") { stats.permissionOK = false }
        }
    }

    var durationText: String {
        guard let start = stats.sessionStart, stats.running else { return "—" }
        let d = Int(Date().timeIntervalSince(start))
        return "\(d / 3600)h \(d % 3600 / 60)m \(d % 60)s"
    }
}

// MARK: - Menu UI

struct MenuContent: View {
    @EnvironmentObject var c: Controller
    @Environment(\.openWindow) private var openWindow
    @State private var hookChanged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(c.stats.running ? .red : .secondary).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.stats.running ? "Recording" : "Idle").font(.headline)
                    Text(c.settings.captureMode == .activity
                         ? "on activity" : "every \(c.settings.intervalSeconds)s")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }

            // First run: without a projects folder every event would be filed
            // under "_unsorted", so ask for it up front rather than silently
            // producing a useless log.
            if c.settings.projectsRoot.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Finish setup", systemImage: "folder.badge.questionmark")
                        .font(.caption).bold()
                    Text("Pick the folder that holds your projects so Autodoc can "
                         + "split your log per project.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Choose projects folder…") { c.chooseProjectsRoot() }
                        .font(.caption)
                }
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }

            if !c.stats.permissionOK {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Screen Recording is off", systemImage: "exclamationmark.triangle")
                        .font(.caption).bold()
                    Text("Autodoc can't see your screen until you allow it.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings…") {
                        SystemSettings.openScreenRecordingPrivacy()
                    }
                    .font(.caption)
                }
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }

            Button(c.stats.running ? "Stop session" : "Start session") { c.toggle() }
                .keyboardShortcut(c.stats.running ? "." : "r")
                .buttonStyle(.borderedProminent)

            if c.stats.running {
                Group {
                    row("Duration", c.durationText)
                    row("Screen samples", "\(c.stats.screenSamples)")
                    row("Commands", "\(c.stats.commandsCaptured)")
                    row("Projects", c.stats.projects.sorted().joined(separator: ", ").ifEmpty("—"))
                }
                if !c.stats.lastDescription.isEmpty {
                    Text(c.stats.lastDescription)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            Picker("Focus project", selection: Binding(
                get: { c.currentProject ?? "" },
                set: { c.setProject($0.isEmpty ? nil : $0) })) {
                Text("Auto-detect").tag("")
                ForEach(c.knownProjects, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)

            HStack(spacing: 6) {
                statusChip("Screen", ok: c.stats.permissionOK)
                statusChip("Ollama", ok: c.stats.ollamaOK)
                Spacer()
                Button("Recheck") { Task { await c.refresh() } }.font(.caption)
            }

            if let err = c.stats.lastError {
                Text(err).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }

            Divider()

            Button {
                openWindow(id: "library")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Library…", systemImage: "books.vertical")
            }
            .keyboardShortcut("l")

            // Installing edits ~/.zshrc, so removal has to be one click too.
            if TerminalHook.isInstalled {
                Button {
                    TerminalHook.uninstall()
                    hookChanged = true
                } label: {
                    Label("Remove terminal capture", systemImage: "terminal")
                }
            } else {
                Button {
                    TerminalHook.install()
                    hookChanged = true
                } label: {
                    Label("Install terminal capture…", systemImage: "terminal")
                }
            }
            if hookChanged {
                Text("Updated ~/.zshrc — open a new terminal to apply.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Open logs folder") { NSWorkspace.shared.open(AppPaths.logs) }
            SettingsLink { Text("Settings…") }
            Button("Quit Autodoc") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 300)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value) }
            .font(.caption)
    }

    private func statusChip(_ label: String, ok: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(label)
        }.font(.caption2)
    }
}

// MARK: - Settings UI

struct SettingsView: View {
    @EnvironmentObject var c: Controller
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section("Capture") {
                Picker("When to capture", selection: $c.settings.captureMode) {
                    Text("On activity (Scribe-style)").tag(CaptureMode.activity)
                    Text("Fixed interval").tag(CaptureMode.interval)
                }
                if c.settings.captureMode == .interval {
                    TextField("Interval (seconds)",
                              value: $c.settings.intervalSeconds, format: .number)
                } else {
                    TextField("Min seconds between captures",
                              value: $c.settings.minIntervalSeconds, format: .number)
                    TextField("Settle delay after input (s)",
                              value: $c.settings.debounceSeconds, format: .number)
                    TextField("Force capture during nonstop work (s)",
                              value: $c.settings.maxActiveSeconds, format: .number)
                    Text("Captures only on human interaction — typing, clicks, app "
                         + "switches — and never while you're idle.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField("Max frame size (px)",
                          value: $c.settings.maxDimension, format: .number)
                Toggle("Skip idle / unchanged frames", isOn: $c.settings.idleSkip)
                Toggle("Keep screenshot pixels (off = text only)",
                       isOn: $c.settings.keepScreenshots)
                if c.settings.keepScreenshots {
                    Toggle("Delete all screenshots when I stop (keep nothing overnight)",
                           isOn: $c.settings.deleteFramesOnStop)
                    TextField("Screenshot budget (MB)", value: Binding(
                        get: { c.settings.maxFrameBytes / 1_000_000 },
                        set: { c.settings.maxFrameBytes = max(1, $0) * 1_000_000 }),
                        format: .number)
                    Text(c.settings.deleteFramesOnStop
                         ? "Frames exist only during a live session; all are wiped on stop."
                         : "Frames persist (encrypted HEIC); oldest evicted past the cap.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Model") {
                TextField("Ollama host", text: $c.settings.ollamaHost)
                TextField("Model", text: $c.settings.model)
            }
            Section("Projects") {
                HStack {
                    Text("Projects folder")
                    Spacer()
                    Text(c.settings.projectsRoot.isEmpty
                         ? "Not set"
                         : (c.settings.projectsRoot as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(c.settings.projectsRoot.isEmpty ? .orange : .secondary)
                        .lineLimit(1).truncationMode(.head)
                    Button("Choose…") { c.chooseProjectsRoot() }
                }
                Button("Rescan projects") { c.rescanProjects() }
                    .disabled(c.settings.projectsRoot.isEmpty)
                Text(c.settings.projectsRoot.isEmpty
                     ? "Until this is set, activity can't be split per project."
                     : (c.knownProjects.isEmpty
                        ? "No subfolders found in that folder."
                        : "Detected: \(c.knownProjects.joined(separator: ", "))"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Privacy — excluded apps (bundle IDs)") {
                TextField("comma separated", text: excludedBinding)
                Text("Windows of these apps are never captured. Password managers "
                     + "and personal messaging are excluded by default.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Data retention") {
                TextField("Delete session records after (days, 0 = keep)",
                          value: $c.settings.retentionDays, format: .number)
                Text(c.settings.retentionDays > 0
                     ? "Encrypted session records older than \(c.settings.retentionDays) "
                       + "day(s) are deleted when a session ends. Your per-project "
                       + "Markdown logs are always kept."
                     : "Session records are kept indefinitely.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("General") {
                Toggle("Launch Autodoc at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { launchAtLogin = LoginItem.setEnabled($0) ? $0 : launchAtLogin }))
                Text("Requires the signed app in /Applications.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 460)
        .onChange(of: c.settings) { _, new in new.save() }
    }

    private var excludedBinding: Binding<String> {
        Binding(
            get: { c.settings.excludedBundleIDs.joined(separator: ", ") },
            set: {
                c.settings.excludedBundleIDs = $0
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            })
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
