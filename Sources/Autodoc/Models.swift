import Foundation

/// When Autodoc decides to capture.
enum CaptureMode: String, Codable, Sendable, CaseIterable {
    case activity     // only on human interaction (Scribe-style), debounced
    case interval     // every `intervalSeconds`, regardless of activity
}

/// User-tunable configuration, persisted as JSON in Application Support.
struct Config: Codable, Sendable, Equatable {
    var model = "gemma4:e4b"
    var ollamaHost = "http://localhost:11434"
    var captureMode: CaptureMode = .activity
    var intervalSeconds = 60           // used in .interval mode
    var minIntervalSeconds = 15        // .activity rate-limit floor
    var debounceSeconds = 2            // .activity: quiet period after input before capturing
    var maxActiveSeconds = 60          // .activity: force a capture during nonstop activity
    var maxDimension = 1024            // longest side of the captured frame (px)
    var idleSkip = true               // skip frames that look identical to the last
    var keepScreenshots = false       // native default: keep only text, never store pixels
    var maxFrameBytes = 2_000_000_000 // hard cap for kept screenshots (2 GB); oldest evicted
    var deleteFramesOnStop = true     // wipe ALL kept screenshots when a session ends
    /// Days to keep session logs; 0 = keep forever. Enforced when a session ends.
    var retentionDays = 0
    /// Folder whose subfolders are the tracked projects. Empty until the user
    /// picks one — there is no sensible default, and guessing would either scan
    /// the whole home directory or silently detect nothing.
    var projectsRoot = ""
    /// Apps whose windows are excluded from capture entirely (privacy).
    /// Password managers and personal messaging are excluded out of the box;
    /// users can add their own in Settings.
    var excludedBundleIDs: [String] = [
        // Password managers & credential stores
        "com.apple.keychainaccess",
        "com.1password.1password",
        "com.1password.1password-launcher",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.dashlane.Dashlane",
        "me.proton.pass.electron",
        "com.keepassxc.keepassxc",
        // Personal messaging & mail
        "com.apple.MobileSMS",
        "com.apple.mail",
        "org.whispersystems.signal-desktop",
        "net.whatsapp.WhatsApp",
        "ru.keepcoder.Telegram",
    ]

    init() {}

    /// Lenient decode: missing keys (e.g. from an older config.json written by a
    /// previous version) fall back to defaults instead of throwing, so upgrades
    /// never silently wipe a user's saved settings.
    init(from decoder: Decoder) throws {
        let d = Config()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = (try? c.decode(String.self, forKey: .model)) ?? d.model
        ollamaHost = (try? c.decode(String.self, forKey: .ollamaHost)) ?? d.ollamaHost
        captureMode = (try? c.decode(CaptureMode.self, forKey: .captureMode)) ?? d.captureMode
        intervalSeconds = (try? c.decode(Int.self, forKey: .intervalSeconds)) ?? d.intervalSeconds
        minIntervalSeconds = (try? c.decode(Int.self, forKey: .minIntervalSeconds)) ?? d.minIntervalSeconds
        debounceSeconds = (try? c.decode(Int.self, forKey: .debounceSeconds)) ?? d.debounceSeconds
        maxActiveSeconds = (try? c.decode(Int.self, forKey: .maxActiveSeconds)) ?? d.maxActiveSeconds
        maxDimension = (try? c.decode(Int.self, forKey: .maxDimension)) ?? d.maxDimension
        idleSkip = (try? c.decode(Bool.self, forKey: .idleSkip)) ?? d.idleSkip
        keepScreenshots = (try? c.decode(Bool.self, forKey: .keepScreenshots)) ?? d.keepScreenshots
        maxFrameBytes = (try? c.decode(Int.self, forKey: .maxFrameBytes)) ?? d.maxFrameBytes
        deleteFramesOnStop = (try? c.decode(Bool.self, forKey: .deleteFramesOnStop)) ?? d.deleteFramesOnStop
        retentionDays = (try? c.decode(Int.self, forKey: .retentionDays)) ?? d.retentionDays
        projectsRoot = (try? c.decode(String.self, forKey: .projectsRoot)) ?? d.projectsRoot
        excludedBundleIDs = (try? c.decode([String].self, forKey: .excludedBundleIDs)) ?? d.excludedBundleIDs
    }

    static let storeURL = AppPaths.support.appendingPathComponent("config.json")

    static func load() -> Config {
        guard let data = try? Data(contentsOf: storeURL),
              let cfg = try? JSONDecoder().decode(Config.self, from: data)
        else { return Config() }
        return cfg
    }

    func save() {
        try? FileManager.default.createDirectory(
            at: AppPaths.support, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: Config.storeURL)
        }
    }
}

/// One recorded event in a session (screen sample, terminal command, or marker).
struct Event: Codable, Sendable {
    var ts: Double
    var iso: String
    var type: String            // "screen" | "command" | "session"
    var text: String
    var project: String?
    var app: String?
    var windowTitle: String?
    var trigger: String? = nil  // what caused this capture (activity mode)
    var shot: String? = nil     // relative path to the kept encrypted HEIC frame, if any
}

/// A Sendable snapshot pushed to the UI after each sample.
struct SampleSummary: Sendable {
    enum Kind: Sendable { case screen, command, session, error }
    var kind: Kind
    var text: String
    var project: String?
}

/// Live UI state, mutated only on the main actor.
struct LiveStats: Sendable {
    var running = false
    var screenSamples = 0
    var commandsCaptured = 0
    var lastDescription = ""
    var sessionStart: Date?
    var projects: Set<String> = []
    var permissionOK = true
    var ollamaOK = true
    var lastError: String?
}

enum AppPaths {
    /// ~/Library/Application Support/Autodoc
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("Autodoc", isDirectory: true)
    }()
    static let sessions = support.appendingPathComponent("sessions", isDirectory: true)
    static let logs = support.appendingPathComponent("logs", isDirectory: true)
    static let frames = support.appendingPathComponent("frames", isDirectory: true)

    static func ensure() {
        for d in [support, sessions, logs, frames] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }
}

extension Date {
    var isoStamp: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: self)
    }
    var sessionStamp: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: self)
    }
}
