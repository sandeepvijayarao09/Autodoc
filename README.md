# Autodoc for Mac — native

## In 30 seconds
- **What it is:** A Mac menu-bar app that notes what you work on and writes a running log per project.
- **Why it matters:** Screen capture, AI processing and storage all stay on your Mac; raw records are encrypted and credentials are scrubbed before storage.
- **Key result:** A local Gemma vision model (via Ollama on `localhost`) reads each screen capture; 126 tests run with `swift test`. Status: not yet notarized by Apple.
- **What I did:** Solo project: rewrote my Python CLI prototype as a native Swift app.
- **Built with:** Swift 6, SwiftUI (`MenuBarExtra`), ScreenCaptureKit, CryptoKit + Keychain, Ollama, Gemma 4 E4B.
- **Try it:** With Ollama running and `gemma4:e4b` pulled, run `./make-signing-cert.sh`, `./build.sh`, then `open build/Autodoc.app`.

The Apple-standard rewrite of Autodoc: a native **Swift 6 / SwiftUI menu-bar app**
that logs what you do across your projects, entirely on-device, and turns it into
a per-project running log with a local Gemma vision model.

Everything stays on your Mac: capture, inference and storage are all local, and
the only network traffic is to your own Ollama server on `localhost`.

Autodoc began as a Python CLI prototype; this is the production rewrite and the
only supported version.

## What makes it "Apple standard"

| Concern | Implementation |
|---|---|
| Screen capture | **ScreenCaptureKit** (`SCScreenshotManager`) — the supported API; reports permission denial explicitly instead of silently capturing a blank desktop |
| Concurrency | Swift 6 **strict concurrency**, actors (`CaptureEngine`, `SecureStore`, `SharedSelection`) + an `AsyncStream` UI pipeline. **Compiles with 0 warnings.** Capture never blocks on the model |
| Privacy at rest | **CryptoKit AES-GCM**; the symmetric key lives in the **Keychain**. Raw screen text is never on disk in the clear |
| Redaction | **`SCContentFilter`** excludes chosen apps (password managers, personal messaging) from capture entirely |
| Credential scrubbing | `Redactor` strips secrets from commands and screen text **before** they are stored, summarised, or sent to the model |
| UI | **SwiftUI `MenuBarExtra`**, `LSUIElement` agent (no Dock icon) |
| Idempotent logs | Summaries are keyed by session id and *replace* their block — re-running never duplicates (fixes the Python bug) |
| Data location | `~/Library/Application Support/Autodoc/` |
| Packaging | Real `.app` bundle, ad-hoc **codesigned** (satisfies its Designated Requirement) |

## Requirements

| | |
|---|---|
| macOS | 14 (Sonoma) or later, Apple silicon or Intel |
| [Ollama](https://ollama.com) | **0.20.0 or later** (required by the model) |
| Model | `gemma4:e4b` — a **9.6 GB** download, pulled once |
| Disk | ~10 GB for the model; logs are well under 1 MB/day (pixels off by default) |
| Xcode / Swift | 6.0+ toolchain, to build from source |

Autodoc runs the vision model on your own machine, so expect real work per
frame: roughly **10–20 s of inference per capture** on an M-series Mac. Activity
mode only captures when you're actually working, and never while you're idle, so
an idle machine costs nothing — but during sustained work the model is the main
cost, and on a laptop you'll notice it.

```sh
ollama serve
ollama pull gemma4:e4b     # 9.6 GB, one time
```

## Install

Download the DMG from the [latest release](https://github.com/sandeepvijayarao09/Autodoc/releases/latest)
and drag Autodoc to Applications.

> **Until the app is notarized** (see [Known limitations](#known-limitations)),
> macOS Gatekeeper will refuse the first launch. Right-click the app → **Open**,
> then confirm. Building from source avoids this entirely.

On first launch Autodoc asks you to:

1. **Pick your projects folder** — the folder whose subfolders are your projects.
   Without it, everything is filed under `_unsorted`.
2. **Grant Screen Recording** — *System Settings → Privacy & Security → Screen
   Recording*. The menu links straight there if it's missing.
3. *(optional)* **Install terminal capture** — adds a session-gated `zsh` hook so
   your commands are logged too. Removable from the same menu.

## Build & run

```sh
./make-signing-cert.sh     # ONCE: create a stable self-signed signing identity
./build.sh                 # compile + icon + bundle + sign  ->  build/Autodoc.app
open build/Autodoc.app     # shows in the Dock + menu bar, opens the Library window
```

**Permissions that stick.** Without a stable code signature, macOS treats every
rebuild as a new app and re-asks for Screen Recording + Keychain access.
`make-signing-cert.sh` creates a self-signed *"Autodoc Local Signing"* identity
(no Apple account needed); `build.sh` then signs with it. On the **first** signed
build macOS asks to let `codesign` use the key — click **Always Allow** once.
After that, grant Screen Recording once and it persists across rebuilds.
Set `AUTODOC_ADHOC=1 ./build.sh` to force an (unstable) ad-hoc build.

First time you press **Start session**, macOS asks for **Screen Recording**
permission (*System Settings → Privacy & Security → Screen Recording*). Grant it
to Autodoc and press Start again.

Requires [Ollama](https://ollama.com) running with the model pulled:
```sh
ollama serve
ollama pull gemma4:e4b
```

## Architecture

```
 MenuBarExtra (SwiftUI, @MainActor Controller)
        │  start()                         apply(SampleSummary)
        ▼                                        ▲
   CaptureEngine (actor) ── AsyncStream ─────────┘
        │ every N s
        ├─ ScreenCapturer  (ScreenCaptureKit, app-exclusion, aHash idle-skip)
        ├─ OllamaClient    (async URLSession → gemma4:e4b, think:false)
        └─ SecureStore     (actor, AES-GCM + Keychain, append-only .enc)
                                   │  on stop
                                   ▼
                            Summarizer (per-project Markdown, idempotent)
                                   ▼
                 ~/Library/Application Support/Autodoc/logs/<Project>.md
```

### Library window

Open it from the menu bar → **Open Library…** (⌘L). A standard macOS
split-view window to manage everything Autodoc captures:

- **Sidebar** — every project (its running log) and every recorded session.
- **Project detail** — the running log rendered as Markdown, with **Edit**
  (edit + save the notes yourself), **Reveal in Finder**, and **Delete**.
- **Session detail** — the raw captured timeline, decrypted on demand, with
  per-event project/app/trigger tags and **search**.
- Browsing project logs is **prompt-free**; the keychain prompt only appears the
  first time you open a session (that's when the encrypted events are decrypted).

### Screenshots & storage budget

By default Autodoc keeps **only the text** the model extracts — pixels are
described, then discarded (a full 8-hour day costs well under 1 MB). Turn on
**Keep screenshot pixels** in Settings and each frame is stored as an
**encrypted HEIC** (~7× smaller than PNG), viewable inline in a session's
timeline. A hard **screenshot budget** (`maxFrameBytes`, default 2 GB) bounds
the total: once exceeded, the **oldest frames are evicted** first, so the
footprint can never grow without limit. Text logs are never evicted.

### Capture modes

- **On activity (default, Scribe-style)** — captures only on real human
  interaction: typing, clicks, scrolls, and app switches, *debounced* so it logs
  the **result** of an action rather than every keystroke. When you're idle it
  captures **nothing**. Activity is detected permission-free via
  `CGEventSource.secondsSinceLastEventType` + `NSWorkspace` app-switch
  notifications — no keylogger / Input-Monitoring permission required. Tunable:
  `minIntervalSeconds` (rate-limit floor), `debounceSeconds` (settle delay),
  `maxActiveSeconds` (force a frame during nonstop work).
- **Fixed interval** — the classic timer: one frame every `intervalSeconds`,
  active or not.

Because activity mode scales frames with *work*, not the clock, an idle machine
costs zero — the direct fix for unbounded screenshot growth. The `TriggerPolicy`
rules are covered by `Tests/TriggerPolicyTests.swift`.

### Terminal capture (exact commands, exact project)

Screen capture reads what's *visible*; terminal work needs precision. The menu's
**Install terminal capture…** adds a small, session-gated `zsh` hook to
`~/.zshrc` that logs **every command verbatim** with its `$PWD` — but only while
a session is active (it checks an `active` flag file, so it records nothing
otherwise, and `TerminalHook.uninstall()` reverses it).

During a session, `CommandWatcher` tails that log and attributes each command to
a project **deterministically** from `$PWD` → the folder it ran in (`ProjectResolver.projectForPath`,
deepest-match, boundary-aware). No guessing, no stickiness — so simultaneous
terminals in different projects are each tagged correctly even with a bare `$`
prompt. Commands land in the same encrypted store and flow into each project's
running log alongside the screen activity.

### Project auto-detection

Autodoc figures out which project each frame belongs to **by itself** — the
*Focus project* picker is only an optional override. `ProjectResolver` scores
every sample across several signals:

1. **Terminal working directory** (decisive) — a path under a project folder
2. **Window title** (high trust — editors show the real workspace/file); longer
   exact-name matches win collisions (`avigis-athena` beats `avigis`)
3. **On-screen text** the vision model OCRs (file paths, repo names)
4. **The model's own classification** — gemma is asked to pick the project from
   the known list; it corroborates, but can't attribute on its own (no hallucinated tags)
5. **App classification** — the frontmost app is typed as editor / terminal /
   browser / other. Editors and terminals are **trusted** (their titles name the
   workspace); browsers and other apps are **not** — their arbitrary page titles
   are never mined for a project name (so a browser tab that mentions "Tryon"
   won't mis-tag), and instead inherit the fused context.
6. **Fused context** — a single "what am I working on now" signal updated by
   *every* source (a terminal command's `$PWD`, a confident editor frame) and read
   back on ambiguous frames, decaying after 8 min. So a `cd`+command in `Tryon`
   correctly tags the docs/browser reading that immediately follows it.

The bias is toward **precision**: when unsure, Autodoc inherits context or marks
the frame unknown rather than guessing — a wrong tag poisons a project's log.

Each project's **fingerprint** is built at session start by scanning the
**Projects folder** you pick on first run (Settings → Projects) — folder name,
name-words, plus tokens pulled from `package.json` and the git remote, so
matching survives even when the window title doesn't contain the folder name.

The scoring logic is covered by `Tests/ProjectResolverTests.swift`. Run the
whole suite (126 tests) the standard way:
```sh
swift test
```

## Files

```
AutodocMac/
├── Package.swift
├── Info.plist                 # LSUIElement, ATS local-networking
├── VERSION                    # single source of the release version
├── build.sh                   # local dev build
├── release.sh                 # test → build → sign → DMG
├── notarize.sh                # notarize + staple for distribution
└── Sources/Autodoc/
    ├── AutodocApp.swift        # @main App, Controller, menu + settings UI
    ├── Library.swift           # Library window data store + Markdown renderer
    ├── LibraryView.swift       # sidebar + project/session detail UI
    ├── Models.swift            # Config, Event, paths
    ├── ScreenCapturer.swift    # ScreenCaptureKit + average-hash idle detect
    ├── ActivityMonitor.swift   # permission-free activity/app-switch trigger source
    ├── TriggerPolicy.swift     # pure, tested "when to capture" rules
    ├── CaptureEngine.swift     # trigger-driven capture loop
    ├── ProjectResolver.swift   # multi-signal auto-attribution + fingerprints
    ├── OllamaClient.swift      # local model client
    ├── SecureStore.swift       # encrypted event log (CryptoKit + Keychain)
    ├── Redactor.swift           # credential scrubbing before anything is stored
    ├── Retention.swift          # age-based expiry of session records
    ├── SystemIntegration.swift  # folder picker, privacy deep link, login item
    ├── CommandLog.swift         # hook-line parsing (redaction entry point)
    ├── CommandWatcher.swift     # tails the hook log during a session
    ├── SharedContext.swift      # fused "what am I working on" signal
    ├── AppKind.swift            # editor / terminal / browser / other trust model
    ├── FrameBudget.swift        # screenshot eviction policy
    └── Summarizer.swift        # idempotent per-project running log
```

## Known limitations

- **Not yet notarized.** `./release.sh` produces a Hardened Runtime build and a
  drag-to-install DMG, but distributing to other Macs without a Gatekeeper
  warning needs an Apple Developer Program membership; run `./notarize.sh` once
  you have the certificate. See [DISTRIBUTION.md](DISTRIBUTION.md).
- **One display per capture.** Autodoc captures the display your frontmost
  window is on (falling back to the pointer's display, then the primary). Work
  on a second monitor at the same moment isn't in that frame.
- **Redaction is best-effort.** `Redactor` catches common credential shapes, not
  every possible one. Anything that must never be captured belongs in the
  app-exclusion list. See [SECURITY.md](SECURITY.md).
- **`logs/*.md` are plaintext by design** — they're the readable product. The
  encrypted store holds the raw records; the summaries are meant to be read and
  shared.
- **zsh only.** The terminal hook uses `preexec`; bash/fish aren't supported.

## License

[MIT](LICENSE) © 2026 Sandeep Vijayarao
