import Foundation

/// Strips credentials out of captured text *before* it is ever stored, summarised,
/// or sent to the model.
///
/// This runs at the earliest possible point (`CommandLog.parse`) because a
/// terminal command is the one capture path that reliably carries live secrets:
/// `export AWS_SECRET_ACCESS_KEY=…`, `curl -u user:pass`, `psql postgres://…`.
/// The per-project Markdown logs are plaintext on disk and are exactly what a
/// user pastes into a standup or commits to a repo, so a secret that reaches
/// them has effectively leaked.
///
/// Design notes:
///   * Fail safe, not clever — when a pattern looks credential-shaped we redact
///     it. Over-redacting a log line is harmless; under-redacting is not.
///   * The *shape* of the command survives (`export AWS_SECRET_ACCESS_KEY=‹redacted›`)
///     so the log still reads as a record of what happened.
///   * Pure and synchronous so it can be unit-tested exhaustively.
enum Redactor {

    /// What replaces a secret. Deliberately not a fixed-width mask: it must be
    /// obvious in a log that redaction happened, and impossible to mistake for
    /// the real value.
    static let placeholder = "‹redacted›"

    /// Environment-variable / flag names whose value is always a secret.
    /// Matched case-insensitively as a substring, so `MY_GITHUB_TOKEN` and
    /// `--api-key` are both caught.
    private static let sensitiveNameFragments = [
        "secret", "token", "password", "passwd", "pwd", "apikey", "api_key",
        "api-key", "accesskey", "access_key", "access-key", "auth", "credential",
        "private_key", "privatekey", "private-key", "sessionkey", "session_key",
        "client_secret", "clientsecret", "signing", "cert_pass", "keystore",
    ]

    /// Patterns for values that are self-evidently secrets wherever they appear,
    /// regardless of the surrounding syntax. Ordered most-specific first.
    private static let valuePatterns: [String] = [
        // PEM private key blocks (any type: RSA, EC, OPENSSH, PGP…)
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
        // Cloud / vendor tokens with fixed, unambiguous prefixes
        #"\bAKIA[0-9A-Z]{16}\b"#,                          // AWS access key id
        #"\bASIA[0-9A-Z]{16}\b"#,                          // AWS temporary key id
        #"\bghp_[A-Za-z0-9]{20,}"#,                        // GitHub personal token
        #"\bgho_[A-Za-z0-9]{20,}"#,
        #"\bghu_[A-Za-z0-9]{20,}"#,
        #"\bghs_[A-Za-z0-9]{20,}"#,
        #"\bghr_[A-Za-z0-9]{20,}"#,
        #"\bgithub_pat_[A-Za-z0-9_]{20,}"#,
        #"\bglpat-[A-Za-z0-9\-_]{16,}"#,                   // GitLab
        #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#,               // Slack
        #"\bsk-[A-Za-z0-9\-_]{16,}"#,                      // OpenAI-style
        #"\bsk-ant-[A-Za-z0-9\-_]{16,}"#,                  // Anthropic
        #"\bAIza[0-9A-Za-z\-_]{30,}"#,                     // Google API key
        #"\bya29\.[0-9A-Za-z\-_]+"#,                       // Google OAuth
        #"\bSG\.[A-Za-z0-9\-_]{20,}\.[A-Za-z0-9\-_]{20,}"# ,  // SendGrid
        #"\bnpm_[A-Za-z0-9]{30,}"#,                        // npm
        #"\bdop_v1_[a-f0-9]{60,}"#,                        // DigitalOcean
        #"\bhf_[A-Za-z0-9]{30,}"#,                         // Hugging Face
        // JSON Web Token (three base64url segments)
        #"\beyJ[A-Za-z0-9\-_]{8,}\.[A-Za-z0-9\-_]{8,}\.[A-Za-z0-9\-_]+"#,
    ]

    /// Redact every credential-shaped construct in `text`.
    ///
    /// Order matters: the HTTP-header rules run *before* the generic
    /// `NAME: value` scrubber, because `Authorization: Bearer <token>` would
    /// otherwise be read as name `Authorization` with value `Bearer` — masking
    /// the scheme and leaving the actual token exposed.
    static func redact(_ text: String) -> String {
        var out = text

        // 1. Standalone secret values (prefix-identifiable tokens, PEM blocks, JWTs).
        for pattern in valuePatterns {
            out = replace(in: out, pattern: pattern, with: placeholder)
        }

        // 2. HTTP auth headers: `Authorization: Bearer …`, `-H "X-Api-Key: …"`.
        out = replace(in: out,
                      pattern: #"(?i)(authorization\s*:\s*)(bearer|basic|token|digest)\s+\S+"#,
                      with: "$1$2 \(placeholder)")
        out = replace(in: out,
                      pattern: #"(?i)((?:x-)?api[-_]?key\s*:\s*)\S+"#,
                      with: "$1\(placeholder)")

        // 3. `NAME=value` / `NAME:value` where NAME looks sensitive.
        //    Handles `export X=v`, `X=v cmd`, `--api-key=v`, `-Dpassword=v`, `X: v`.
        out = replaceSensitiveAssignments(in: out)

        // 4. Credentials embedded in a URL: scheme://user:pass@host
        out = replace(in: out,
                      pattern: #"([a-zA-Z][a-zA-Z0-9+.\-]*://[^\s:/@]+):[^\s@/]+@"#,
                      with: "$1:\(placeholder)@")

        // 5. `curl -u user:pass` (and `--user user:pass`)
        out = replace(in: out,
                      pattern: #"(?<=\s)(-u|--user)(\s+|=)([^\s:]+):[^\s]+"#,
                      with: "$1$2$3:\(placeholder)")

        // 6. Password-ish short flags whose value is attached: `-p<secret>`,
        //    mysql/redis style. Only when something follows, so a bare `-p` (which
        //    prompts interactively) is left alone.
        out = replace(in: out,
                      pattern: #"(?<=\s)(-p|-P)(?=\S)\S+"#,
                      with: "$1\(placeholder)")

        return out
    }

    // MARK: - Assignment scrubbing

    /// Rewrite `NAME=value` (or `NAME: value`) when NAME contains a sensitive
    /// fragment. Done with an explicit scan rather than one mega-regex so the
    /// name test stays readable and the value's own quoting is preserved.
    private static func replaceSensitiveAssignments(in text: String) -> String {
        // Capture: 1 = name, 2 = separator, 3 = value (quoted or bare).
        let pattern = #"([A-Za-z_][A-Za-z0-9_.\-]*)(\s*=\s*|\s*:\s*)("[^"]*"|'[^']*'|\S+)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }

        let ns = text as NSString
        var result = ""
        var last = 0

        // Values that are not themselves secrets: an auth scheme keyword is
        // followed by the credential (already handled by the header rules), and
        // an existing placeholder must survive so redaction stays idempotent.
        let notASecret: Set<String> = ["bearer", "basic", "token", "digest", placeholder]

        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            let value = ns.substring(with: m.range(at: 3))
            guard isSensitive(name: name),
                  !notASecret.contains(value.lowercased()) else { continue }
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            result += name + ns.substring(with: m.range(at: 2)) + placeholder
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    /// True when a variable/flag name implies its value is a credential.
    static func isSensitive(name: String) -> Bool {
        let n = name.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        // "key" alone is too broad (`ssh-keygen -f key`, `sort -key`), so it only
        // counts when paired: apikey, access_key, private_key… handled by the
        // fragment list. Everything else is a direct substring test.
        return sensitiveNameFragments.contains { n.contains($0) }
    }

    // MARK: - Helpers

    private static func replace(in text: String, pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        return re.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: template)
    }
}
