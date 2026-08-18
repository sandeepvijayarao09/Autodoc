# Security Policy

## Reporting a vulnerability

Please report security issues privately rather than in a public issue:

- Open a [GitHub security advisory](https://github.com/sandeepvijayarao09/Autodoc/security/advisories/new), or
- email **vijayarao.s@northeastern.edu** with `Autodoc security` in the subject.

Please include the version (`Autodoc → Settings`, or `CFBundleShortVersionString`),
your macOS version, and enough detail to reproduce. I'll acknowledge within a
week and aim to ship a fix before any public disclosure.

## Supported versions

The latest released version receives fixes. There are no long-term support
branches.

## Threat model

Autodoc is a local-only recorder. It has no server, no account, and no
telemetry, so the interesting risks are all about **data at rest on the user's
own Mac**:

| Asset | Protection |
|---|---|
| Screen-derived text, terminal commands | AES-GCM encrypted (`sessions/*.enc`); key in the login Keychain |
| Kept screenshots (opt-in, off by default) | AES-GCM encrypted HEIC (`frames/**.enc`) |
| Per-project summaries (`logs/*.md`) | **Plaintext by design** — they are the readable product |
| Credentials in captured commands | Scrubbed by `Redactor` before they are stored, summarised, or sent to the model |

### Known limitations

- **`logs/*.md` are plaintext.** They are meant to be read, shared and diffed.
  Treat them as you would a work journal. Redaction runs before anything is
  written, but no pattern set is exhaustive.
- **Redaction is best-effort.** `Redactor` covers common credential shapes
  (vendor token prefixes, sensitive variable names, auth headers, URLs with
  passwords, PEM blocks, JWTs). A secret in an unusual form can still get
  through. Use the app-exclusion list for anything that must never be captured.
- **Excluded apps are excluded from the image, not from existence.** A password
  manager's window is filtered out of the capture, but text you paste from it
  into another app is captured normally.
- **The Keychain key is readable by you.** Anything running as your user
  account, with your consent, can request the key. Autodoc protects against
  another *user* on the machine, not against malware running as you.
- **`ollamaHost` is user-configurable.** The default is `localhost`. If you
  point it at a remote server, screen descriptions leave your machine — that is
  your choice, and the "nothing leaves your Mac" guarantee no longer holds.
