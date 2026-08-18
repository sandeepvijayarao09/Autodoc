import Foundation
import CryptoKit

/// Append-only, AES-GCM encrypted event log. The symmetric key lives in the
/// login Keychain; raw screen-derived text is therefore never on disk in the clear.
///
/// File format (per session, at sessions/<id>.enc):
///   repeated  [ UInt32 big-endian length ][ AES-GCM combined blob ]
actor SecureStore {
    private let key: SymmetricKey
    private var currentURL: URL?

    init() {
        self.key = SecureStore.loadOrCreateKey()
    }

    func begin(sessionID: String) {
        AppPaths.ensure()
        let url = AppPaths.sessions.appendingPathComponent("\(sessionID).enc")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        currentURL = url
    }

    func append(_ event: Event) {
        guard let url = currentURL else { return }
        do {
            let plain = try JSONEncoder().encode(event)
            let sealed = try AES.GCM.seal(plain, using: key)
            guard let blob = sealed.combined else { return }
            var len = UInt32(blob.count).bigEndian
            var record = Data(bytes: &len, count: 4)
            record.append(blob)

            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            handle.write(record)
        } catch {
            // Non-fatal: a dropped sample must never crash capture.
        }
    }

    /// Decrypt every event from a session file.
    func readEvents(sessionID: String) -> [Event] {
        let url = AppPaths.sessions.appendingPathComponent("\(sessionID).enc")
        guard let data = try? Data(contentsOf: url) else { return [] }
        var out: [Event] = []
        var i = data.startIndex
        while i + 4 <= data.endIndex {
            let len = data.subdata(in: i..<(i + 4)).withUnsafeBytes {
                UInt32(bigEndian: $0.load(as: UInt32.self))
            }
            i += 4
            let end = i + Int(len)
            guard end <= data.endIndex else { break }
            let blob = data.subdata(in: i..<end)
            i = end
            if let box = try? AES.GCM.SealedBox(combined: blob),
               let plain = try? AES.GCM.open(box, using: key),
               let ev = try? JSONDecoder().decode(Event.self, from: plain) {
                out.append(ev)
            }
        }
        return out
    }

    // MARK: - Kept screenshots (encrypted HEIC + hard byte budget)

    /// Encrypt and write a HEIC frame; returns its path relative to the frames
    /// dir (e.g. "2026-07-19_101500/1784443036.heic.enc") for the event's `shot`.
    func saveFrame(_ heic: Data, sessionID: String, ts: Double) -> String? {
        let dir = AppPaths.frames.appendingPathComponent(sessionID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "\(Int(ts)).heic.enc"
        guard let sealed = try? AES.GCM.seal(heic, using: key).combined else { return nil }
        do {
            try sealed.write(to: dir.appendingPathComponent(name))
            return "\(sessionID)/\(name)"
        } catch { return nil }
    }

    /// Decrypt a kept frame back to HEIC bytes (for the Library thumbnail).
    func loadFrame(_ relPath: String) -> Data? {
        let url = AppPaths.frames.appendingPathComponent(relPath)
        guard let blob = try? Data(contentsOf: url),
              let box = try? AES.GCM.SealedBox(combined: blob),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return plain
    }

    // MARK: - Retention

    /// Delete encrypted session records older than `days`. Per-project Markdown
    /// summaries are intentionally preserved — see `Retention`.
    /// `days <= 0` keeps everything.
    func enforceRetention(days: Int) {
        guard days > 0 else { return }
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: AppPaths.sessions,
            includingPropertiesForKeys: [.contentModificationDateKey]) else { return }

        let files: [Retention.SessionFile] = urls.compactMap { url in
            guard url.pathExtension == "enc" else { return nil }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return .init(name: url.lastPathComponent, modified: mtime)
        }

        for name in Retention.expired(files, days: days) {
            try? fm.removeItem(at: AppPaths.sessions.appendingPathComponent(name))
        }
    }

    /// Delete every kept screenshot (all sessions). Text logs are untouched.
    func purgeAllFrames() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: AppPaths.frames, includingPropertiesForKeys: nil) else { return }
        for url in items { try? fm.removeItem(at: url) }
    }

    /// Evict oldest frames (across all sessions) until total ≤ `maxBytes`.
    func enforceFrameBudget(maxBytes: Int) {
        for path in FrameBudget.toEvict(frameFiles(), maxBytes: maxBytes) {
            try? FileManager.default.removeItem(
                at: AppPaths.frames.appendingPathComponent(path))
        }
    }

    private func frameFiles() -> [FrameBudget.FileInfo] {
        let fm = FileManager.default
        let root = AppPaths.frames
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var out: [FrameBudget.FileInfo] = []
        for case let url as URL in en where url.pathExtension == "enc" {
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard v?.isRegularFile == true else { continue }
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            out.append(.init(path: rel,
                             size: v?.fileSize ?? 0,
                             mtime: v?.contentModificationDate ?? .distantPast))
        }
        return out
    }

    // MARK: - Keychain-backed key

    private static let keyTag = "io.github.sandeepvijayarao09.Autodoc.master-key"

    private static func loadOrCreateKey() -> SymmetricKey {
        if let existing = readKey() { return existing }
        let new = SymmetricKey(size: .bits256)
        storeKey(new)
        return new
    }

    private static func readKey() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyTag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return SymmetricKey(data: data)
    }

    private static func storeKey(_ key: SymmetricKey) {
        let raw = key.withUnsafeBytes { Data($0) }
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyTag,
            kSecValueData as String: raw,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemDelete(attrs as CFDictionary)
        SecItemAdd(attrs as CFDictionary, nil)
    }
}
