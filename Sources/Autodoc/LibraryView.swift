import SwiftUI

/// The main window: a sidebar of projects + sessions, and a detail pane that
/// shows a project's running log (editable) or a session's decrypted timeline.
struct LibraryView: View {
    @EnvironmentObject var lib: LibraryStore
    @State private var selection: LibrarySelection?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Projects") {
                    if lib.projects.isEmpty {
                        Text("No logs yet").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(lib.projects, id: \.self) { p in
                        Label(p, systemImage: "doc.text")
                            .tag(LibrarySelection.project(p))
                    }
                }
                Section("Sessions") {
                    if lib.sessions.isEmpty {
                        Text("No sessions yet").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(lib.sessions) { s in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.dateText)
                                Text(s.sizeText).font(.caption2).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "clock") }
                        .tag(LibrarySelection.session(s.id))
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 230)
            .navigationTitle("Autodoc")
            .toolbar {
                Button { lib.reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Button { lib.openLogsFolder() } label: { Label("Open Folder", systemImage: "folder") }
            }
        } detail: {
            switch selection {
            case .project(let p):
                ProjectDetailView(project: p).id(p)
            case .session(let s):
                SessionDetailView(sessionID: s).id(s)
            case nil:
                ContentUnavailableView("Select a project or session",
                                       systemImage: "sidebar.squares.left",
                                       description: Text("Projects show your running log. Sessions show the raw captured timeline."))
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear {
            lib.reload()
            if selection == nil, let first = lib.projects.first {
                selection = .project(first)
            }
        }
    }
}

// MARK: - Project running log (view + edit)

struct ProjectDetailView: View {
    @EnvironmentObject var lib: LibraryStore
    let project: String

    @State private var editing = false
    @State private var draft = ""
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if editing {
                TextEditor(text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .padding(6)
            } else {
                ScrollView {
                    MarkdownText(text: lib.projectMarkdown(project))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
            }
        }
        .navigationTitle(project)
        .navigationSubtitle("running log")
        .toolbar {
            if editing {
                Button("Cancel") { editing = false }
                Button("Save") { lib.saveProject(project, draft); editing = false }
                    .keyboardShortcut("s")
            } else {
                Button { draft = lib.projectMarkdown(project); editing = true } label: {
                    Label("Edit", systemImage: "pencil")
                }
                Button { lib.revealProject(project) } label: {
                    Label("Reveal", systemImage: "folder")
                }
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .confirmationDialog("Delete the running log for “\(project)”?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { lib.deleteProject(project) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes only the summarized log. Raw session events are kept.")
        }
    }
}

// MARK: - Session timeline (decrypted on demand)

struct SessionDetailView: View {
    @EnvironmentObject var lib: LibraryStore
    let sessionID: String

    @State private var events: [Event] = []
    @State private var loading = true
    @State private var query = ""
    @State private var confirmDelete = false

    private var filtered: [Event] {
        guard !query.isEmpty else { return events }
        return events.filter {
            $0.text.localizedCaseInsensitiveContains(query)
                || ($0.project ?? "").localizedCaseInsensitiveContains(query)
                || ($0.app ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Group {
            if loading {
                ProgressView("Decrypting session…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if events.isEmpty {
                ContentUnavailableView("No events", systemImage: "tray",
                                       description: Text("This session has no captured events."))
            } else {
                List(Array(filtered.enumerated()), id: \.offset) { _, e in
                    EventRow(event: e)
                }
                .searchable(text: $query, prompt: "Search this session")
            }
        }
        .navigationTitle(sessionID)
        .navigationSubtitle(events.isEmpty ? "" : "\(events.count) events")
        .toolbar {
            Button { lib.revealSession(sessionID) } label: { Label("Reveal", systemImage: "folder") }
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
        }
        .confirmationDialog("Delete this session and its encrypted events?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { lib.deleteSession(sessionID) }
            Button("Cancel", role: .cancel) {}
        }
        .task(id: sessionID) {
            loading = true
            events = await lib.events(sessionID)
            loading = false
        }
    }
}

private struct EventRow: View {
    let event: Event

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(timeText).font(.caption.monospaced()).foregroundStyle(.secondary)
                if let p = event.project {
                    Text(p).font(.caption.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                }
                if let app = event.app {
                    Text(app).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if let t = event.trigger {
                    Text(t).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if event.type == "command" {
                Text("$ \(event.text)").font(.callout.monospaced()).textSelection(.enabled)
                if let cwd = event.windowTitle {
                    Text(cwd).font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.head)
                }
            } else {
                Text(event.text).font(.callout).textSelection(.enabled)
            }
            if let shot = event.shot {
                FrameThumbnail(path: shot)
            }
        }
        .padding(.vertical, 3)
    }

    private var timeText: String {
        // iso is "yyyy-MM-dd'T'HH:mm:ss" — show just the clock part.
        event.iso.split(separator: "T").last.map(String.init) ?? event.iso
    }
}

/// Lazily decrypts and shows a kept screenshot for one event row.
private struct FrameThumbnail: View {
    let path: String
    @EnvironmentObject var lib: LibraryStore
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
        .frame(width: 160, height: 100, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .task(id: path) { image = await lib.frameImage(path) }
    }
}
