# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] — 2026-08-17

First public release. A native Swift 6 / SwiftUI menu-bar app that logs what you
do across your projects entirely on-device and turns it into a per-project
running log with a local Gemma vision model.

### Added

- Activity-driven capture (Scribe-style) with a fixed-interval mode as an option.
- Per-project running logs, written idempotently — re-summarising a session
  replaces its block instead of appending a duplicate.
- Automatic project attribution from window titles, terminal working
  directories, on-screen text and the model's own classification, with an
  app-kind trust model so arbitrary browser titles don't cause false positives.
- Encryption at rest: AES-GCM for all session records and kept frames, with the
  key in the login Keychain.
- `Redactor` — credential scrubbing applied before anything is stored,
  summarised, or sent to the model. Covers vendor token prefixes, sensitive
  variable names, auth headers, URLs with embedded passwords, PEM blocks and JWTs.
- Privacy deny-list excluding password managers and personal messaging from
  capture via `SCContentFilter`, editable in Settings.
- Opt-in, session-gated zsh hook for terminal commands, installable *and*
  removable from the menu.
- Library window: read, reveal, or delete any project log or session.
- Data retention: expire encrypted session records after a configurable number
  of days, keeping the readable summaries.
- Screenshot byte budget with oldest-first eviction, plus "delete all
  screenshots when I stop" (on by default).
- Launch-at-login via `SMAppService`, and a direct link to the Screen Recording
  privacy pane when permission is missing.
- Release pipeline: `./release.sh` (test → build → icon → bundle → Hardened
  Runtime sign → verify → DMG) and `./notarize.sh` (notarize + staple the app,
  then rebuild and notarize the DMG).
- 126 tests covering the trigger policy, frame budget, retention, project
  resolution, app classification, command parsing, config/event decoding,
  summary idempotency and redaction.
