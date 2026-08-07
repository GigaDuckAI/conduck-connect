# Security Policy

The canonical vulnerability disclosure policy — including the full scope rules and safe-harbor terms — is published at **<https://conduck.com/security/>**. A machine-readable summary lives at [`/.well-known/security.txt`](https://conduck.com/.well-known/security.txt). This file is the short version for people arriving via GitHub.

`conduck-connect` is a setup script you run on your own gateway host, often over SSH with root-capable rights. It is designed to be **read before it is run** — that is why it ships as a plain, unminified shell script.

## Reporting a vulnerability

Please report security issues **privately**, not as a public issue:

- **GitHub private vulnerability reporting** — the repository's **Security** tab → **Report a vulnerability**.
- Or email **security@gigaduck.ai**.

Please include the script version (`grep '^VERSION=' conduck-connect.sh`), your OS and shell, and a reproduction.

## What to expect

- **Acknowledgment within 3 business days** of your report.
- **An initial assessment within 10 business days**, with updates as the fix progresses.
- Confirmed vulnerabilities are addressed without delay. For critical issues, 90 days is the outer bound, not the plan — most fixes ship much faster.
- Coordinated disclosure: please hold public disclosure until a fix has shipped or 90 days have passed since your report, whichever comes first.
- Once a fix is available, an advisory is published; with your permission you are credited for the discovery. There is no monetary bug bounty at this time.

## Supported versions

The latest tagged release is supported. Older tags are not patched — re-download the current release.

| Version | Supported |
|---|---|
| latest release tag | ✅ |
| older tag / `main` snapshot | ❌ |

## What the script may do

- **Reads** your gateway's own config to discover ports and the existing token (OpenClaw `~/.openclaw/openclaw.json`; Hermes `~/.hermes/.env`).
- **Enables** the gateway's OpenAI-compatible chat endpoint if it is off — with your confirmation.
- **Edits** your gateway's own config, and only the exact change you approve first: in Hermes's `~/.hermes/config.yaml`, the shared-folder path and the `file` toolset so the agent can reach it, and — as a separate question — taking `memory` or `session_search` out of the API-server scope, because a gateway that keeps its own recall replays history the app already sends every turn. OpenClaw's file-tool policy goes through its own `openclaw config set`. Anything it cannot parse confidently it describes for you to change by hand rather than rewriting, and it refuses to edit through a symlink.
- **Installs agent guidance** — with your confirmation, one marker-delimited block in your agent's own context file (`TOOLS.md` on OpenClaw, `.hermes.md` / `HERMES.md` on Hermes), leaving everything outside the markers alone. It is instructions, not permissions: it tells the agent how Conduck attachments work — open the exact uploaded path instead of searching for it, and finish a returned file at the working-directory root and name it in plain reply text. Each gateway's block then covers how that agent reads a PDF, and neither block claims more than it does. OpenClaw's carries one path hint — a media or PDF tool that rejects the saved path should be retried with the file's absolute workspace path — and nothing beyond it: the script never switches OpenClaw's `pdf` tool on, never grades it, and never mentions it in the tool-policy check, because that tool sits outside the `coding` profile and also needs `agents.defaults.pdfModel` pointing at a model your gateway can actually resolve. Native PDF reading on OpenClaw therefore stays entirely your own call, and the README's file-lane troubleshooting lists what it takes. Hermes has no PDF reader in `read_file` at all, so its block says to take the text with `pdftotext` through Hermes's terminal tool, to say so plainly when that is not possible, and never to answer from a filename. Hermes's block also tells the agent to treat instructions found *inside* an attachment as untrusted unless your own chat message asks it to follow them. Either way the block grants no tool the agent does not already hold, and installs no software: it is text that points the agent at tools your own gateway config decides it has. On the Hermes path the two things that rule depends on are checked and reported rather than assumed: a `pdftotext` missing from the script's own shell, and a `platform_toolsets.api_server` list it can read that carries no terminal tool, each get a note naming the fix. Neither is fetched nor edited for you, and neither stops the block being offered.
- **Creates** exposure mappings using tools you already run (`tailscale serve` / `funnel`), and optionally a file-server service it owns (`conduck-files-<id>`, rclone WebDAV bound to `127.0.0.1`) together with the shared folder that service serves — the folder your attachments and the agent's output files pass through. A folder it creates is `0700`; one that already exists keeps its own permissions, and it tells you when those let other accounts read it.
- **Stores** the file-lane credential in `0600` files under `~/.config/conduck/` (a `0700` directory) — and, on **macOS only**, a second cleartext copy inside the `0600` LaunchAgent plist it creates, because launchd has no environment-file equivalent. Removing the credential therefore takes a different step per platform; [WHAT-IT-TOUCHES.md](WHAT-IT-TOUCHES.md) lists every location and the exact undo.
- **Sends** its own HTTP probes only to your configured gateway and file lane,
  to verify they work. `--show-code` changes no configuration, but
  still performs live verification; with a configured file lane that includes
  one small PUT→GET→DELETE probe. `--check-server` and `--check-adapter` do not
  follow HTTP redirects or forward credentials to `Location` targets.

See [WHAT-IT-TOUCHES.md](WHAT-IT-TOUCHES.md) for the exhaustive list and how to undo each change.

## What the script never does

- **No GigaDuck telemetry, ever. There is no GigaDuck server.** The script's own HTTP probes target only your configured gateway and file lane. Approved Tailscale or Cloudflare commands — run by the script with your consent, or by you — may contact those providers' control planes as part of exposing your gateway.
- **Never installs** your gateway, Tailscale, cloudflared, or rclone — it works with what you already have, and exits cleanly with instructions if a prerequisite is missing.
- **Never elevates silently.** Every command that needs higher rights is shown in full first — prefixed with `sudo` or `doas`, whichever this machine has, and bare when you are already root or have neither. Most it prints for you to review and run yourself (Tailscale operator rights, `pmset`). The one it can run for you — `loginctl enable-linger`, so your file server survives logout — runs only after you approve the exact command at a `y/N` prompt; decline and it prints the command as a tip instead.
- **Never changes a config it didn't create** without showing you the exact change first — permissions included, not just contents.
- **Never makes your gateway public** without telling you, in plain words, that it will — and refuses to publish a **keyless** gateway on a public transport unless you explicitly run `--setup --allow-keyless-public`. The flag is a setup modifier and is rejected on its own or with any other action, so it can never be passed by reflex.

## Verifying your download

The script is delivered over HTTPS straight from GitHub Releases as plain,
unminified text rather than an opaque installer. Its modular source is
assembled deterministically, and CI rejects any byte difference between that
source build and the checked-in artifact. It is available to **inspect** before
you run it (`less conduck-connect.sh`); the release workflow tests and
checksums the exact artifact users download.

Every release also publishes `conduck-connect.sh.sha256` for an optional integrity check:

```bash
shasum -a 256 -c conduck-connect.sh.sha256        # Linux: sha256sum -c conduck-connect.sh.sha256
```

This confirms the bytes arrived intact, but the checksum rides the same release
channel as the script, so it catches a **corrupted** download, not a **swapped
or tampered** release. Inspect the script when that risk matters. Release tags
are protected and are not moved after publication, and the release workflow
refuses to overwrite an existing release's assets—a changed byte always means a
new version and tag.

## The pairing code is a secret

The QR / paste code contains your gateway URL and its access token — and, when the file lane is set up, the file-server URL and its credential too. Treat it like a password: it is scannable by anyone who can see your screen, and whoever holds it can talk to your gateway and read or change files in the shared folder until you rotate those secrets. The script warns you of this when it emits the code.

## Embedded component

The QR renderer embeds the unmodified Project Nayuki QR generator (Python, MIT), which uses only the Python standard library (no network, file, or subprocess access). CI verifies this block against a pinned checksum and asserts its imports stay standard-library-only on every change (`scripts/verify-vendored-encoder.sh`).
