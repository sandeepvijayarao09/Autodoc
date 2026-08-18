# Privacy

**Autodoc collects nothing.** There is no account, no server, no analytics, and
no telemetry. Nothing is uploaded, and there is no network traffic beyond your
own Ollama server on `localhost`.

## What is recorded, and only while a session is running

Autodoc records nothing until you press **Start session**, and stops the moment
you press **Stop**.

| What | When | Where it goes |
|---|---|---|
| A description of your screen, written by a local vision model | On your activity (or on a fixed interval) | Encrypted `sessions/<id>.enc` |
| The screenshot pixels | **Only if** you turn on "Keep screenshot pixels" | Encrypted `frames/**.heic.enc` |
| Terminal commands + working directory | Only if you install the zsh hook | Encrypted `sessions/<id>.enc` |
| A readable per-project summary | When a session ends | Plaintext `logs/<Project>.md` |

Everything lives in `~/Library/Application Support/Autodoc/`.

## Defaults chosen for privacy

- **Screenshot pixels are not kept.** Only the model's text description is
  stored. Turning pixels on also enables "delete all screenshots when I stop".
- **Password managers and personal messaging are excluded from capture**
  (Keychain Access, 1Password, Bitwarden, LastPass, Dashlane, Proton Pass,
  KeePassXC, Messages, Mail, Signal, WhatsApp, Telegram). Add your own in
  Settings.
- **Credentials are scrubbed** from captured commands and screen descriptions
  before anything is written to disk — see `Redactor` and `SECURITY.md`.
- **The terminal hook is opt-in and session-gated.** It writes only while a
  session is active, and "Remove terminal capture" takes it back out of
  `~/.zshrc`.
- **Nothing is recorded while you're idle** in the default activity mode.

## Your controls

- **Stop** — ends recording immediately.
- **Library** — read, reveal in Finder, or delete any project log or session.
- **Data retention** — expire encrypted session records after N days.
- **Delete everything** — quit Autodoc and remove
  `~/Library/Application Support/Autodoc/`. To also drop the encryption key,
  delete the `io.github.sandeepvijayarao09.Autodoc.master-key` item in Keychain
  Access.

## Permissions Autodoc asks for, and why

- **Screen Recording** — required; it is how the app sees your screen. macOS
  shows its own recording indicator whenever a capture happens.
- **Keychain** — to store the encryption key for your data at rest.

Autodoc does **not** request Accessibility or Input Monitoring. Activity
detection uses only the system's aggregate idle timer, so individual keystrokes
are never observed.
