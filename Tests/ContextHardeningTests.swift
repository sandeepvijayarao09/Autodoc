// App classification + conservative resolver gating for non-work apps.
import XCTest
@testable import Autodoc

final class AppClassifierTests: XCTestCase {

    private func kind(_ app: String?) -> String { AppClassifier.kind(app: app).rawValue }

    func testEditorsAreRecognised() {
        XCTAssertEqual(kind("Cursor"), "editor")
        XCTAssertEqual(kind("Visual Studio Code"), "editor")
        XCTAssertEqual(kind("Xcode"), "editor")
    }

    func testTerminalsAreRecognised() {
        XCTAssertEqual(kind("Terminal"), "terminal")
        XCTAssertEqual(kind("iTerm2"), "terminal")
        XCTAssertEqual(kind("Ghostty"), "terminal")
    }

    func testBrowsersAreRecognised() {
        XCTAssertEqual(kind("Safari"), "browser")
        XCTAssertEqual(kind("Google Chrome"), "browser")
        XCTAssertEqual(kind("Arc"), "browser")
    }

    func testEverythingElseIsOther() {
        XCTAssertEqual(kind("Slack"), "other")
        XCTAssertEqual(kind("Figma"), "other")
        XCTAssertEqual(kind(nil), "other")
    }

    /// A short token like "arc" must match exactly, so "Search" is not a browser.
    func testShortTokensRequireExactMatch() {
        XCTAssertEqual(kind("Search"), "other")
    }
}

final class ContextHardeningTests: XCTestCase {

    private let root = "/Users/x/projects"

    private lazy var resolver: ProjectResolver = {
        func fp(_ n: String) -> ProjectFingerprint { .make(name: n, path: "\(root)/\(n)") }
        return ProjectResolver(fingerprints: [fp("Tryon"), fp("Avigis"), fp("MeetingBot")])
    }()

    private func resolve(title: String, app: String, desc: String = "",
                         prev: String? = nil, llm: String? = nil) -> String? {
        resolver.resolve(title: title, appName: app, description: desc, cwd: nil,
                         previous: prev, llmGuess: llm).project
    }

    // A browser page whose title NAMES a project must NOT attribute to it —
    // arbitrary page titles are untrustworthy, so it inherits fused context.

    func testBrowserTitleIsIgnoredAndContextInherited() {
        XCTAssertEqual(resolve(title: "checkout.ts · Tryon — GitHub",
                               app: "Google Chrome", desc: "reading github",
                               prev: "MeetingBot"), "MeetingBot")
    }

    func testBrowserWithNoContextAttributesToNothing() {
        XCTAssertNil(resolve(title: "Tryon pricing — Google Docs", app: "Safari",
                             desc: "a doc that says Tryon", prev: nil))
    }

    func testNonWorkAppInheritsContext() {
        XCTAssertEqual(resolve(title: "Tryon channel", app: "Slack",
                               desc: "chatting", prev: "Avigis"), "Avigis")
    }

    // An editor naming the project in its title IS trusted.

    func testEditorTitleIsTrusted() {
        XCTAssertEqual(resolve(title: "checkout.ts — Tryon", app: "Cursor",
                               desc: "editing"), "Tryon")
    }

    func testEditorWithModelCorroboration() {
        XCTAssertEqual(resolve(title: "Cursor", app: "Cursor",
                               desc: "the Avigis pipeline", llm: "Avigis"), "Avigis")
    }
}
