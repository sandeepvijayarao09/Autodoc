import Foundation

/// Age-based expiry for recorded sessions.
///
/// Kept screenshots already have a byte budget (`FrameBudget`), but the encrypted
/// event records had no expiry at all — a daily user accumulates them forever.
/// This policy expires the *raw* records; the per-project Markdown summaries are
/// deliberately left alone, since those are the durable, human-readable product
/// and are far smaller.
///
/// Pure and deterministic so it can be tested without touching the disk.
enum Retention {
    struct SessionFile: Sendable, Equatable {
        let name: String        // e.g. "2026-08-17_224833.enc"
        let modified: Date
    }

    /// Names to delete so that nothing older than `days` remains.
    /// `days <= 0` means "keep forever" and never deletes anything.
    static func expired(_ files: [SessionFile], days: Int, now: Date = Date()) -> [String] {
        guard days > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return files.filter { $0.modified < cutoff }.map(\.name)
    }
}
