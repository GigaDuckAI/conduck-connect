# Security Policy

`conduck-connect` is a setup script you run on your own gateway host, often over SSH with root-capable rights. It is designed to be **read before it is run** — that is why it ships as a plain, unminified shell script.

## Reporting a vulnerability

Please report security issues **privately**, not as a public issue:

- **GitHub private vulnerability reporting** — the repository's **Security** tab → **Report a vulnerability**.
- Or email **security@gigaduck.ai**.

We aim to acknowledge within 5 business days. Please include the script version (`grep '^VERSION=' conduck-connect.sh`), your OS and shell, and a reproduction.

## Supported versions

The latest tagged release is supported. Older tags are not patched — re-download the current release.

| Version | Supported |
|---|---|
| latest release tag | ✅ |
| older tag / `main` snapshot | ❌ |

## What the script may do

- **Reads** your gateway's own config to discover ports and the existing token (OpenClaw `~/.openclaw/openclaw.json`; Hermes `~/.hermes/.env`).
- **Enables** the gateway's OpenAI-compatible chat endpoint if it is off — with your confirmation.
- **Creates** exposure mappings using tools you already run (`tailscale serve` / `funnel`), and optionally a file-server service it owns (`conduck-files-<id>`, rclone WebDAV bound to `127.0.0.1`).
- **Stores** a file-lane credential in a `0600` file under `~/.config/conduck/`.
- **Sends** requests only to your own gateway, to verify it works.

See [WHAT-IT-TOUCHES.md](WHAT-IT-TOUCHES.md) for the exhaustive list and how to undo each change.

## What the script never does

- **No telemetry, ever.** It makes no outbound request to anything except your own gateway. There is no GigaDuck server.
- **Never installs** your gateway, Tailscale, cloudflared, or rclone — it works with what you already have, and exits cleanly with instructions if a prerequisite is missing.
- **Never elevates silently.** Where `sudo` is required (e.g. Tailscale operator rights, `loginctl enable-linger`), it prints the exact command for you to review and run yourself.
- **Never changes a config it didn't create** without showing you the exact change first.
- **Never makes your gateway public** without telling you, in plain words, that it will — and refuses to publish a **keyless** gateway on a public transport unless you explicitly pass `--allow-keyless-public`.

## Verifying your download

The script is delivered over HTTPS straight from GitHub Releases, and it is short and meant to be **read** before you run it — those two things are your real protection. Read it first (`less conduck-connect.sh`).

Every release also publishes `conduck-connect.sh.sha256` for an optional integrity check:

```bash
shasum -a 256 -c conduck-connect.sh.sha256        # Linux: sha256sum -c conduck-connect.sh.sha256
```

This confirms the bytes arrived intact, but the checksum rides the same release channel as the script — so it catches a **corrupted** download, not a **swapped or tampered** release. Reading the script is what catches that. Release tags are protected and are not moved after publication, and the release workflow refuses to overwrite an existing release's assets — a changed byte always means a new version and tag.

## The pairing code is a secret

The QR / paste code contains your gateway URL and its access token — and, when the file lane is set up, the file-server URL and its credential too. Treat it like a password: it is scannable by anyone who can see your screen, and whoever holds it can talk to your gateway and read or change files in the shared folder until you rotate those secrets. The script warns you of this when it emits the code.

## Embedded component

The QR renderer embeds the unmodified Project Nayuki QR generator (Python, MIT), which uses only the Python standard library (no network, file, or subprocess access). CI verifies this block against a pinned checksum and asserts its imports stay standard-library-only on every change (`scripts/verify-vendored-encoder.sh`).
