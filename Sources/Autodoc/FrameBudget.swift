import Foundation

/// Ring-buffer policy for kept screenshots: keep total bytes under a hard cap by
/// evicting the OLDEST frames first. Pure and deterministic so it can be tested
/// without touching the disk.
enum FrameBudget {
    struct FileInfo: Sendable {
        let path: String
        let size: Int
        let mtime: Date
    }

    /// Returns the paths to delete so the remaining total is ≤ `maxBytes`.
    /// A `maxBytes <= 0` means "keep nothing" → evict everything.
    static func toEvict(_ files: [FileInfo], maxBytes: Int) -> [String] {
        var total = files.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return [] }
        var evict: [String] = []
        for f in files.sorted(by: { $0.mtime < $1.mtime }) {   // oldest first
            if total <= maxBytes { break }
            evict.append(f.path)
            total -= f.size
        }
        return evict
    }
}
