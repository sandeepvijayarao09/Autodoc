// Terminal-command parsing + deterministic path→project attribution.
import XCTest
@testable import Autodoc

final class CommandLogTests: XCTestCase {

    /// `<pwd>|<cmd>` for a parsed line, or nil.
    private func parsed(_ s: String) -> String? {
        guard let (_, pwd, cmd) = CommandLog.parse(s) else { return nil }
        return "\(pwd)|\(cmd)"
    }

    func testValidLine() {
        XCTAssertEqual(parsed("1720000000\t/root/Tryon\tgit status"),
                       "/root/Tryon|git status")
    }

    func testQuotesArePreserved() {
        XCTAssertEqual(parsed("1\t/p\tgit commit -m \"fix\""),
                       "/p|git commit -m \"fix\"")
    }

    /// maxSplits: 2 — tabs inside the command itself must survive.
    func testInnerTabsArePreserved() {
        XCTAssertEqual(parsed("1\t/p\techo a\tb"), "/p|echo a\tb")
    }

    func testLineWithoutTabsIsRejected() {
        XCTAssertNil(parsed("just some text"))
    }

    func testEmptyCommandIsRejected() {
        XCTAssertNil(parsed("1\t/p\t"))
    }

    func testEmptyWorkingDirectoryIsRejected() {
        XCTAssertNil(parsed("1\t\tls"))
    }

    func testUnparseableTimestampStillYieldsCommand() {
        XCTAssertEqual(parsed("xyz\t/p\tls"), "/p|ls")
    }

    /// Redaction is applied at parse time, so no caller can persist a raw secret.
    func testParseRedactsSecrets() {
        let line = "1\t/p\texport AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMIEXAMPLEKEY"
        let got = parsed(line)
        XCTAssertNotNil(got)
        XCTAssertFalse(got!.contains("wJalrXUtnFEMIEXAMPLEKEY"))
        XCTAssertTrue(got!.contains(Redactor.placeholder))
        // The shape of the command still reads as a record of what happened.
        XCTAssertTrue(got!.contains("export AWS_SECRET_ACCESS_KEY="))
    }
}

final class PathAttributionTests: XCTestCase {

    private let root = "/Users/x/projects"

    private lazy var resolver: ProjectResolver = {
        func fp(_ n: String, _ sub: String) -> ProjectFingerprint {
            .make(name: n, path: "\(root)/\(sub)")
        }
        return ProjectResolver(fingerprints: [
            fp("Tryon", "Tryon"),
            fp("Avigis", "Avigis"),
            fp("avigis-athena", "avigis-athena"),
            fp("Mono", "Mono"),
            fp("MonoSub", "Mono/Sub"),      // nested project — deepest must win
        ])
    }()

    private func proj(_ p: String) -> String? { resolver.projectForPath(p) }

    func testDirectoryUnderProject() {
        XCTAssertEqual(proj("\(root)/Tryon/src/api"), "Tryon")
    }

    func testExactProjectRoot() {
        XCTAssertEqual(proj("\(root)/Tryon"), "Tryon")
    }

    func testSiblingPrefixIsNotAMatch() {
        XCTAssertNil(proj("\(root)/TryonBackup/src"))
    }

    func testNameCollisionRespectsBoundary() {
        XCTAssertEqual(proj("\(root)/avigis-athena/pkg"), "avigis-athena")
    }

    func testShorterNameStillMatchesItsOwnTree() {
        XCTAssertEqual(proj("\(root)/Avigis/x"), "Avigis")
    }

    func testNestedProjectDeepestWins() {
        XCTAssertEqual(proj("\(root)/Mono/Sub/deep"), "MonoSub")
    }

    func testNestedParentOutsideChild() {
        XCTAssertEqual(proj("\(root)/Mono/other"), "Mono")
    }

    func testPathOutsideRoot() {
        XCTAssertNil(proj("/tmp/whatever"))
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(proj("\(root)/tryon/SRC"), "Tryon")
    }
}
