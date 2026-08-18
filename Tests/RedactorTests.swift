// Credential scrubbing. These assertions are the guard rail that keeps live
// secrets out of the plaintext per-project Markdown logs.
import XCTest
@testable import Autodoc

final class RedactorTests: XCTestCase {

    /// Asserts the secret is gone, a placeholder is present, and (optionally)
    /// that the readable shape of the command survived.
    private func assertRedacted(_ input: String, secret: String,
                                keeps: String? = nil,
                                file: StaticString = #filePath, line: UInt = #line) {
        let out = Redactor.redact(input)
        XCTAssertFalse(out.contains(secret),
                       "secret survived redaction: \(out)", file: file, line: line)
        XCTAssertTrue(out.contains(Redactor.placeholder),
                      "no placeholder inserted: \(out)", file: file, line: line)
        if let keeps {
            XCTAssertTrue(out.contains(keeps),
                          "lost readable context \(keeps): \(out)", file: file, line: line)
        }
    }

    // MARK: - Environment assignments

    func testAWSSecretKeyExport() {
        assertRedacted("export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMIK7MDENGbPxRfiCY",
                       secret: "wJalrXUtnFEMIK7MDENGbPxRfiCY",
                       keeps: "export AWS_SECRET_ACCESS_KEY=")
    }

    func testGenericTokenExport() {
        assertRedacted("export MY_TOKEN=supersecret123", secret: "supersecret123")
    }

    func testPasswordAssignment() {
        assertRedacted("DB_PASSWORD=hunter2 npm start",
                       secret: "hunter2", keeps: "npm start")
    }

    func testQuotedValue() {
        assertRedacted(#"export API_KEY="abc def ghi""#, secret: "abc def ghi")
    }

    func testSingleQuotedValue() {
        assertRedacted("export CLIENT_SECRET='sh h'", secret: "sh h")
    }

    func testLowercaseAndDashedFlagNames() {
        assertRedacted("mytool --api-key=abcdef123456", secret: "abcdef123456")
        assertRedacted("mytool --password=letmein", secret: "letmein")
    }

    func testColonSeparatedAssignment() {
        assertRedacted("password: correcthorse", secret: "correcthorse")
    }

    // MARK: - Prefixed vendor tokens (secret wherever it appears)

    func testAWSAccessKeyID() {
        assertRedacted("aws configure set x AKIAIOSFODNN7EXAMPLE",
                       secret: "AKIAIOSFODNN7EXAMPLE")
    }

    func testGitHubPersonalAccessToken() {
        assertRedacted("git remote add o https://ghp_16C7e42F292c6912E7710c838347Ae178B4a@x",
                       secret: "ghp_16C7e42F292c6912E7710c838347Ae178B4a")
    }

    func testGitHubFineGrainedToken() {
        assertRedacted("echo github_pat_11ABCDEFG0abcdefghijklmnopqrstuvwxyz123456",
                       secret: "github_pat_11ABCDEFG0abcdefghijklmnopqrstuvwxyz123456")
    }

    func testGitLabToken() {
        assertRedacted("glab auth login -t glpat-ABCDEFGHIJ1234567890",
                       secret: "glpat-ABCDEFGHIJ1234567890")
    }

    func testSlackToken() {
        assertRedacted("curl -d token=xoxb-123456789012-abcdefghijklmno",
                       secret: "xoxb-123456789012-abcdefghijklmno")
    }

    func testOpenAIStyleKey() {
        assertRedacted("llm --key sk-abcdefghijklmnopqrstuvwxyz123456",
                       secret: "sk-abcdefghijklmnopqrstuvwxyz123456")
    }

    func testAnthropicKey() {
        assertRedacted("export X=sk-ant-api03-abcdefghijklmnopqrstuvwxyz",
                       secret: "sk-ant-api03-abcdefghijklmnopqrstuvwxyz")
    }

    func testGoogleAPIKey() {
        assertRedacted("curl 'https://x/?k=AIzaSyA1234567890abcdefghijklmnopqrstuv'",
                       secret: "AIzaSyA1234567890abcdefghijklmnopqrstuv")
    }

    func testJSONWebToken() {
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K"
        assertRedacted("curl -H 'Auth: \(jwt)'", secret: jwt)
    }

    func testPEMPrivateKeyBlock() {
        let pem = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEAxyz
        -----END RSA PRIVATE KEY-----
        """
        assertRedacted("echo \"\(pem)\" > k.pem", secret: "MIIEowIBAAKCAQEAxyz")
    }

    // MARK: - URLs, flags and headers

    func testCredentialsInURL() {
        assertRedacted("psql postgres://admin:s3cr3tpw@db.example.com/app",
                       secret: "s3cr3tpw", keeps: "db.example.com/app")
    }

    func testCurlUserFlag() {
        assertRedacted("curl -u alice:mypassword https://api.example.com",
                       secret: "mypassword", keeps: "alice")
    }

    func testAttachedPasswordFlag() {
        assertRedacted("mysql -uroot -phunter2 mydb", secret: "hunter2")
    }

    func testAuthorizationBearerHeader() {
        assertRedacted("curl -H 'Authorization: Bearer abc123def456ghi' https://x",
                       secret: "abc123def456ghi", keeps: "Authorization: Bearer")
    }

    func testApiKeyHeader() {
        assertRedacted("curl -H 'X-Api-Key: secretvalue123' https://x",
                       secret: "secretvalue123")
    }

    // MARK: - Must NOT over-redact

    /// Ordinary commands have to survive verbatim, or the logs become useless.
    func testOrdinaryCommandsAreUntouched() {
        let harmless = [
            "git status",
            "npm run build",
            "git commit -m \"fix auth redirect\"",
            "cd ~/projects/Tryon && ls -la",
            "swift build -c release",
            "docker compose up -d",
            "grep -rn \"password\" .",          // mentions the word, assigns nothing
            "kubectl get pods -n prod",
            "ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519",
            "brew install ollama",
        ]
        for cmd in harmless {
            XCTAssertEqual(Redactor.redact(cmd), cmd, "over-redacted: \(cmd)")
        }
    }

    /// A bare `-p` prompts interactively — there is no secret on the line.
    func testBarePasswordFlagIsLeftAlone() {
        XCTAssertEqual(Redactor.redact("mysql -u root -p"), "mysql -u root -p")
    }

    func testEmptyAndWhitespaceInput() {
        XCTAssertEqual(Redactor.redact(""), "")
        XCTAssertEqual(Redactor.redact("   "), "   ")
    }

    // MARK: - Name classification

    func testSensitiveNameDetection() {
        for name in ["AWS_SECRET_ACCESS_KEY", "MY_TOKEN", "db_password",
                     "--api-key", "CLIENT_SECRET", "GITHUB_TOKEN", "passwd"] {
            XCTAssertTrue(Redactor.isSensitive(name: name), "should be sensitive: \(name)")
        }
    }

    func testNonSensitiveNameDetection() {
        for name in ["PATH", "HOME", "NODE_ENV", "--verbose", "count", "branch"] {
            XCTAssertFalse(Redactor.isSensitive(name: name), "should be safe: \(name)")
        }
    }

    // MARK: - Idempotence

    /// Redacting twice must not corrupt already-redacted text.
    func testRedactionIsIdempotent() {
        let once = Redactor.redact("export TOKEN=abcdefghij")
        XCTAssertEqual(Redactor.redact(once), once)
    }
}
