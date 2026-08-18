import Foundation

/// The fused "what am I working on right now" signal, updated by *every* source
/// — terminal commands (via `$PWD`), editor windows, confident screen frames —
/// and read back when a frame is ambiguous. This is what lets a `cd`+command in
/// one project correctly tag the browser/doc reading that follows it.
///
/// Newer signals win; context decays after `ttl` so it never carries forever.
actor SharedContext {
    private var project: String?
    private var updatedAt: Date = .distantPast
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 8 * 60) { self.ttl = ttl }

    func note(_ project: String?) {
        guard let project, !project.isEmpty else { return }
        self.project = project
        self.updatedAt = Date()
    }

    /// The current project, or nil if none or it has gone stale.
    func current(now: Date = Date()) -> String? {
        guard let project, now.timeIntervalSince(updatedAt) < ttl else { return nil }
        return project
    }

    func reset() { project = nil; updatedAt = .distantPast }
}
