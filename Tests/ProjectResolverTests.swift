// Edge cases for the project resolver's signal fusion.
import XCTest
@testable import Autodoc

final class ProjectResolverTests: XCTestCase {

    private let root = "/Users/x/projects"
    private func p(_ n: String) -> String { "\(root)/\(n)" }

    private lazy var resolver: ProjectResolver = {
        ProjectResolver(fingerprints: [
            .make(name: "AutodocMac", path: p("AutodocMac"), extraTokens: ["screencapturer"]),
            .make(name: "Tryon", path: p("Tryon"), extraTokens: ["tryon-app"]),
            .make(name: "Avigis", path: p("Avigis")),
            .make(name: "avigis-athena", path: p("avigis-athena")),
            .make(name: "Meeting Bot", path: p("Meeting Bot"), extraTokens: ["meeting-bot"]),
            .make(name: "zennex", path: p("zennex")),
            .make(name: "IOSApp", path: p("IOSApp")),
        ])
    }()

    private func resolve(title: String? = nil, app: String? = nil, desc: String = "",
                         cwd: String? = nil, prev: String? = nil,
                         llm: String? = nil) -> String? {
        resolver.resolve(title: title, appName: app, description: desc, cwd: cwd,
                         previous: prev, llmGuess: llm).project
    }

    // MARK: - Core signals

    func testEditorTitleAttributes() {
        XCTAssertEqual(resolve(title: "AutodocApp.swift — AutodocMac",
                               desc: "editing swift", llm: "AutodocMac"), "AutodocMac")
    }

    func testNameCollisionPrefersLongerMatch() {
        XCTAssertEqual(resolve(title: "config.py — avigis-athena — Cursor",
                               desc: "python"), "avigis-athena")
    }

    func testPlainNameStillMatches() {
        XCTAssertEqual(resolve(title: "main.py — Avigis", desc: "code"), "Avigis")
    }

    func testWorkingDirectoryIsDecisive() {
        XCTAssertEqual(resolve(title: "zsh", desc: "npm run build",
                               cwd: p("Tryon") + "/src"), "Tryon")
    }

    func testMultiWordProjectName() {
        XCTAssertEqual(resolve(title: "server.js — Cursor",
                               desc: "editing the Meeting Bot server",
                               llm: "Meeting Bot"), "Meeting Bot")
    }

    func testAmbiguousFrameCarriesPreviousProject() {
        XCTAssertEqual(resolve(title: "Inbox — Gmail", desc: "reading email",
                               prev: "Tryon"), "Tryon")
    }

    func testUnrelatedActivityAttributesToNothing() {
        XCTAssertNil(resolve(title: "System Settings", desc: "brightness"))
    }

    func testModelGuessCorroboratesOnScreenText() {
        XCTAssertEqual(resolve(title: "Cursor", desc: "the zennex payments API",
                               llm: "zennex"), "zennex")
    }

    func testModelGuessAloneIsRejected() {
        XCTAssertNil(resolve(title: "Spotify", desc: "playing music", llm: "IOSApp"))
    }

    // MARK: - Path boundaries

    func testSiblingDirectoryDoesNotMatch() {
        // "/x/TryonBackup" must not match the project "/x/Tryon".
        XCTAssertNil(resolve(title: "zsh", desc: "ls", cwd: p("TryonBackup") + "/src"))
    }

    func testExactProjectRootMatches() {
        XCTAssertEqual(resolve(title: "zsh", desc: "ls", cwd: p("Tryon")), "Tryon")
    }

    func testLongerPathWinsCollision() {
        XCTAssertEqual(resolve(title: "x", desc: "y",
                               cwd: p("avigis-athena") + "/pkg"), "avigis-athena")
    }

    // MARK: - Case & whitespace

    func testUppercaseTitleMatches() {
        XCTAssertEqual(resolve(title: "MAIN.SWIFT — AUTODOCMAC", desc: ""), "AutodocMac")
    }

    func testModelGuessIsCaseAndWhitespaceInsensitive() {
        XCTAssertEqual(resolve(title: "Cursor", desc: "the zennex api",
                               llm: "  ZENNEX  "), "zennex")
    }

    /// "none" is ignored, and a bare mention in on-screen text (+18) stays below
    /// the accept threshold — so without corroboration it must NOT attribute.
    func testDescriptionMentionAloneIsBelowThreshold() {
        XCTAssertNil(resolve(title: "Cursor", desc: "the zennex api", llm: "none"))
    }

    func testSameDescriptionWithModelGuessAttributes() {
        XCTAssertEqual(resolve(title: "Cursor", desc: "the zennex api",
                               llm: "zennex"), "zennex")
    }

    func testUnknownModelGuessIsIgnored() {
        XCTAssertNil(resolve(title: "Cursor", desc: "random work", llm: "NotAProject"))
    }

    // MARK: - Degenerate

    func testAllEmptyAttributesToNothing() {
        XCTAssertNil(resolve())
    }

    func testEmptySignalsStillCarryPrevious() {
        XCTAssertEqual(resolve(prev: "Avigis"), "Avigis")
    }

    func testNoFingerprintsCannotAttribute() {
        let empty = ProjectResolver(fingerprints: [])
        XCTAssertNil(empty.resolve(title: "anything", appName: nil, description: "x",
                                   cwd: p("Tryon"), previous: nil, llmGuess: "Tryon").project)
    }

    func testNoFingerprintsStillCarryPrevious() {
        let empty = ProjectResolver(fingerprints: [])
        XCTAssertEqual(empty.resolve(title: "x", appName: nil, description: "x",
                                     cwd: nil, previous: "Tryon", llmGuess: nil).project,
                       "Tryon")
    }
}
