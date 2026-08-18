// ProjectScanner, Config/Event serialization, and idempotent summary blocks.
import XCTest
@testable import Autodoc

private func makeTempDir(_ tag: String) -> URL {
    let u = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

final class ProjectScannerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = makeTempDir("adscan")
        let fm = FileManager.default

        func mkdir(_ n: String) -> URL {
            let u = root.appendingPathComponent(n)
            try? fm.createDirectory(at: u, withIntermediateDirectories: true)
            return u
        }

        // ProjA — identifiable via package.json
        let a = mkdir("ProjA")
        try #"{"name":"proj-a-pkg"}"#
            .write(to: a.appendingPathComponent("package.json"),
                   atomically: true, encoding: .utf8)

        // ProjB — identifiable via git remote
        let b = mkdir("ProjB")
        let bgit = b.appendingPathComponent(".git")
        try fm.createDirectory(at: bgit, withIntermediateDirectories: true)
        try "[remote \"origin\"]\n\turl = git@github.com:user/projb-repo.git\n"
            .write(to: bgit.appendingPathComponent("config"),
                   atomically: true, encoding: .utf8)

        _ = mkdir("ProjC")                      // bare folder

        // ProjD — malformed manifest must not break the scan
        let d = mkdir("ProjD")
        try "{ not valid json"
            .write(to: d.appendingPathComponent("package.json"),
                   atomically: true, encoding: .utf8)

        // Excluded: the app's own folders and dotfolders
        _ = mkdir("Autodoc")
        _ = mkdir("AutodocMac")
        _ = mkdir(".hidden")
        try "x".write(to: root.appendingPathComponent("afile.txt"),
                      atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testScannerSkipsFilesHiddenAndOwnFolders() {
        let scanned = ProjectScanner.scan(root: root.path)
        XCTAssertEqual(scanned.map(\.name), ["ProjA", "ProjB", "ProjC", "ProjD"])
    }

    func testScannerReadsPackageJSONName() {
        let scanned = ProjectScanner.scan(root: root.path)
        let projA = try? XCTUnwrap(scanned.first { $0.name == "ProjA" })
        XCTAssertTrue(projA?.tokens.contains("proj-a-pkg") == true)
    }

    func testScannerReadsGitRemoteName() {
        let scanned = ProjectScanner.scan(root: root.path)
        let projB = try? XCTUnwrap(scanned.first { $0.name == "ProjB" })
        XCTAssertTrue(projB?.tokens.contains("projb-repo") == true)
    }

    func testScannerSurvivesMalformedJSON() {
        let scanned = ProjectScanner.scan(root: root.path)
        XCTAssertTrue(scanned.contains { $0.name == "ProjD" })
    }

    func testMissingRootYieldsNoProjects() {
        let missing = root.appendingPathComponent("does-not-exist").path
        XCTAssertEqual(ProjectScanner.scan(root: missing).count, 0)
    }

    func testEmptyRootPathYieldsNoProjects() {
        // The default config ships an empty root until the user picks one.
        XCTAssertEqual(ProjectScanner.scan(root: "").count, 0)
    }
}

final class ConfigCodingTests: XCTestCase {

    func testConfigRoundTripsEqual() throws {
        let data = try JSONEncoder().encode(Config())
        let back = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(back, Config())
    }

    func testLenientDecodeKeepsProvidedValues() throws {
        let partial = Data(#"{"model":"custom-model","intervalSeconds":30}"#.utf8)
        let cfg = try JSONDecoder().decode(Config.self, from: partial)
        XCTAssertEqual(cfg.model, "custom-model")
        XCTAssertEqual(cfg.intervalSeconds, 30)
    }

    /// Keys added in a later version must fall back to defaults rather than
    /// throwing, so an upgrade never wipes a user's saved settings.
    func testLenientDecodeDefaultsUnknownKeys() throws {
        let partial = Data(#"{"model":"custom-model","intervalSeconds":30}"#.utf8)
        let cfg = try JSONDecoder().decode(Config.self, from: partial)
        XCTAssertEqual(cfg.captureMode, .activity)
        XCTAssertEqual(cfg.minIntervalSeconds, 15)
    }

    func testEmptyJSONYieldsAllDefaults() throws {
        let cfg = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertEqual(cfg.model, Config().model)
        XCTAssertEqual(cfg.projectsRoot, Config().projectsRoot)
    }

    /// Privacy defaults are part of the contract with the user — assert them.
    func testPrivacyDefaults() {
        let cfg = Config()
        XCTAssertFalse(cfg.keepScreenshots, "pixels must not be kept by default")
        XCTAssertTrue(cfg.deleteFramesOnStop, "frames must be wiped on stop by default")
        XCTAssertTrue(cfg.excludedBundleIDs.contains("com.apple.keychainaccess"))
    }
}

final class EventCodingTests: XCTestCase {

    func testEventFromOlderVersionDecodes() throws {
        let old = Data(
            #"{"ts":1.0,"iso":"2026-01-01T00:00:00","type":"screen","text":"hi"}"#.utf8)
        let e = try JSONDecoder().decode(Event.self, from: old)
        XCTAssertNil(e.trigger)
        XCTAssertNil(e.project)
    }

    func testEventRoundTripsTrigger() throws {
        let e = Event(ts: 1, iso: "i", type: "screen", text: "t", project: "P",
                      app: "A", windowTitle: "W", trigger: "input-settled")
        let back = try JSONDecoder().decode(Event.self, from: JSONEncoder().encode(e))
        XCTAssertEqual(back.trigger, "input-settled")
    }
}

final class SummarizerBlockTests: XCTestCase {

    private var logs: URL!

    override func setUp() { logs = makeTempDir("adlogs") }
    override func tearDown() { try? FileManager.default.removeItem(at: logs) }

    private func read() -> String {
        (try? String(contentsOf: logs.appendingPathComponent("Demo.md"),
                     encoding: .utf8)) ?? ""
    }

    /// Re-summarising a session must replace its block, not append a duplicate.
    func testRewritingSameSessionIsIdempotent() {
        let s = Summarizer(config: Config())
        s.writeBlock(in: logs, project: "Demo", sessionID: "S1",
                     date: "2026-01-01", body: "first draft")
        s.writeBlock(in: logs, project: "Demo", sessionID: "S1",
                     date: "2026-01-01", body: "second draft")
        s.writeBlock(in: logs, project: "Demo", sessionID: "S2",
                     date: "2026-01-02", body: "another session")

        let md = read()
        XCTAssertEqual(md.components(separatedBy: "<!-- session:").count - 1, 2,
                       "two sessions should produce exactly two blocks")
        XCTAssertTrue(md.contains("second draft"), "re-run should replace the body")
        XCTAssertFalse(md.contains("first draft"), "stale body should be gone")
        XCTAssertTrue(md.contains("another session"), "distinct session should append")
    }
}
