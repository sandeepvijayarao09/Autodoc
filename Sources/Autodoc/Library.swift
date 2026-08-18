import SwiftUI
import AppKit

/// Backing store for the Library window: enumerates project logs and sessions,
/// loads/edits/deletes them, and decrypts session events on demand.
@MainActor
final class LibraryStore: ObservableObject {
    @Published var projects: [String] = []
    @Published var sessions: [SessionInfo] = []

    // Lazy: created only when a session is first decrypted, so browsing the
    // plaintext project logs never triggers the keychain prompt.
    private lazy var store = SecureStore()

    struct SessionInfo: Identifiable, Hashable {
        let id: String
        let date: Date
        let bytes: Int
        var dateText: String { date.formatted(date: .abbreviated, time: .shortened) }
        var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
    }

    // MARK: - Listing

    func reload() {
        let fm = FileManager.default

        let logs = (try? fm.contentsOfDirectory(at: AppPaths.logs,
                                                 includingPropertiesForKeys: nil)) ?? []
        projects = logs.filter { $0.pathExtension == "md" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()

        let sess = (try? fm.contentsOfDirectory(
            at: AppPaths.sessions,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        sessions = sess.filter { $0.pathExtension == "enc" }.map { url in
            let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return SessionInfo(id: url.deletingPathExtension().lastPathComponent,
                               date: v?.contentModificationDate ?? .distantPast,
                               bytes: v?.fileSize ?? 0)
        }.sorted { $0.date > $1.date }
    }

    // MARK: - Project logs (plaintext markdown — no keychain needed)

    func projectMarkdown(_ name: String) -> String {
        (try? String(contentsOf: logURL(name), encoding: .utf8)) ?? ""
    }

    func saveProject(_ name: String, _ text: String) {
        try? text.write(to: logURL(name), atomically: true, encoding: .utf8)
    }

    func deleteProject(_ name: String) {
        try? FileManager.default.removeItem(at: logURL(name))
        reload()
    }

    private func logURL(_ name: String) -> URL {
        AppPaths.logs.appendingPathComponent("\(name).md")
    }

    // MARK: - Sessions (encrypted — decrypting triggers the keychain prompt)

    func events(_ sessionID: String) async -> [Event] {
        await store.readEvents(sessionID: sessionID)
    }

    /// Decrypt a kept HEIC frame into an image for the timeline thumbnail.
    func frameImage(_ relPath: String) async -> NSImage? {
        guard let data = await store.loadFrame(relPath) else { return nil }
        return NSImage(data: data)
    }

    func deleteSession(_ id: String) {
        try? FileManager.default.removeItem(
            at: AppPaths.sessions.appendingPathComponent("\(id).enc"))
        reload()
    }

    // MARK: - Finder

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func revealProject(_ name: String) { reveal(logURL(name)) }
    func revealSession(_ id: String) {
        reveal(AppPaths.sessions.appendingPathComponent("\(id).enc"))
    }
    func openLogsFolder() { NSWorkspace.shared.open(AppPaths.logs) }
}

/// What the sidebar has selected.
enum LibrarySelection: Hashable {
    case project(String)
    case session(String)
}

/// A very small Markdown renderer: headings, bullets, inline emphasis; hides the
/// `<!-- session:… -->` bookkeeping comments. Enough to read the running logs
/// nicely without pulling in a dependency.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                line(raw.trimmingCharacters(in: .whitespaces))
            }
        }
    }

    @ViewBuilder private func line(_ t: String) -> some View {
        if t.hasPrefix("<!--") {
            EmptyView()
        } else if t.hasPrefix("### ") {
            inline(String(t.dropFirst(4))).font(.headline)
        } else if t.hasPrefix("## ") {
            inline(String(t.dropFirst(3))).font(.title3.bold()).padding(.top, 4)
        } else if t.hasPrefix("# ") {
            inline(String(t.dropFirst(2))).font(.title2.bold())
        } else if t.hasPrefix("- ") || t.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                inline(String(t.dropFirst(2)))
            }
        } else if t.isEmpty {
            Spacer().frame(height: 3)
        } else {
            inline(t)
        }
    }

    private func inline(_ s: String) -> Text {
        (try? AttributedString(markdown: s)).map(Text.init) ?? Text(s)
    }
}
