# conduck-connect

Pair your self-hosted AI gateway with the **[Conduck](https://gigaduck.ai/conduck)** app — one readable script you audit before you run. Zero telemetry.

## Quick start

One command — downloads the script, verifies it against the published checksum, and (only if it matches) launches the setup wizard. The wizard still **asks before every change**, so nothing touches your server without a y/N:

```bash
curl -fL --remote-name-all https://github.com/gigaduckai/conduck-connect/releases/download/v0.4.0-rc.2/conduck-connect.sh{,.sha256} && if command -v sha256sum >/dev/null; then sha256sum -c conduck-connect.sh.sha256; else shasum -a 256 -c conduck-connect.sh.sha256; fi && bash conduck-connect.sh
```

- **Preview first, change nothing?** Append ` --dry-run` to the trailing `bash conduck-connect.sh`.
- **Read it before running?** Drop the trailing `&& bash conduck-connect.sh` — the rest still downloads and verifies — then `less conduck-connect.sh` and run it when you're happy. It's a plain, readable script on purpose ([why](#why-a-shell-script)).

Works on macOS and Linux. The checksum gate means a corrupted or tampered download is refused before anything runs.

It pairs **OpenClaw**, **Hermes**, or any OpenAI-compatible server with Conduck: enables the chat endpoint, helps you expose the gateway over HTTPS, optionally stands up the agent file lane (rclone WebDAV), verifies everything with real requests, and prints a QR + paste **pairing code** the app imports in one scan.

> **Status: pre-release.** The Conduck app is not yet public. This repository is open early on purpose — so the script can be **read and audited before you ever run it.** That is the whole point of shipping it as a plain shell script.

## Why a shell script?

Because you can read exactly what would run on your server — it's a plain, auditable script, not an opaque binary or installer. The Quick start writes it to a file, checks it against a published checksum **before** anything runs, and refuses to run if that check fails. Reading it yourself is one `less` away and always encouraged for a tool that touches your gateway.

This is deliberately *not* `curl | bash` — that pipes unverified code straight into your shell, unread (and would break this script's interactive prompts anyway). Here the file lands on disk, gets verified, and only then runs.

## What each step does

The Quick start chains these together. Here they are one at a time, with what each does:

```bash
# 1. Download the script and its checksum (pinned release — not `main`)
curl -fLO https://github.com/gigaduckai/conduck-connect/releases/download/v0.4.0-rc.2/conduck-connect.sh
curl -fLO https://github.com/gigaduckai/conduck-connect/releases/download/v0.4.0-rc.2/conduck-connect.sh.sha256

# 2. Verify it downloaded intact
shasum -a 256 -c conduck-connect.sh.sha256        # Linux: sha256sum -c conduck-connect.sh.sha256

# 3. Read it — that is the point
less conduck-connect.sh

# 4. See what it WOULD do, changing nothing
bash conduck-connect.sh --dry-run

# 5. Run it for real (every change still asks first)
bash conduck-connect.sh
```

No `chmod` needed. The one large block near the bottom of the script is a vendored, unmodified QR-code encoder (Project Nayuki, MIT) used to draw the QR locally. It is inert — Python standard library only, no network, file, or process access — and safe to skip when reading.

## Flags

| Flag | Effect |
|---|---|
| _(none)_ | Interactive wizard — detects what you run |
| `--dry-run` | Baseline + plan: show current state and the exact actions a real run would take, then stop. Never prompts for secrets, mints credentials, sends requests, or emits a code. |
| `--reuse-only` | Reuse existing config; refuse any mutation. Safe to point at a **live** gateway. |
| `--openclaw` · `--hermes` · `--generic` | Skip detection; target a specific gateway kind |
| `--allow-keyless-public` | Expert: permit a keyless gateway on a public transport |
| `--help` | All flags |

## Trust posture

- Runs on **your** gateway host. Sends nothing anywhere except to your own gateway. **No telemetry, ever.** The QR is generated locally.
- Never installs gateways, Tailscale, cloudflared, rclone, or any daemon it didn't create.
- Asks before every change. Things *you* own (a Cloudflare tunnel, your reverse proxy) are printed as exact commands for you to run yourself.
- Never elevates silently — where `sudo` is needed it prints the exact command for you to review and run.
- Never makes your gateway public without telling you, in plain words, that it will — and refuses to publish a keyless gateway unless you pass `--allow-keyless-public`.
- Re-running is safe, and is also how you get the pairing code shown again.

See **[WHAT-IT-TOUCHES.md](WHAT-IT-TOUCHES.md)** for the exact files, services, and ports it reads or changes — and how to undo each.

## Requirements

`bash` (3.2+), `curl`, `python3`, `openssl`. A Linux or macOS gateway host.

## Reaching your gateway

Conduck needs the gateway at an `https://` URL. The wizard walks four paths and lets you pick — no auto-recommendation, just honest trade-offs:

- **Tailscale** — private, tailnet-only. *Note: a standalone Apple Watch cannot reach a tailnet-only gateway.*
- **Tailscale Funnel** — public, end-to-end encrypted.
- **Cloudflare Tunnel** — public; needs a domain and `cloudflared`.
- **I already run my own HTTPS** — give the address; the script trusts a publicly-valid cert (e.g. Let's Encrypt) or pins a self-signed one for you. A broken cert (expired / wrong host) stops the run rather than getting silently pinned.

## Pairing code

`conduck-setup:v1:<base64(JSON)>` — same content in the QR and the paste string. Full contract in **[PAYLOAD.md](PAYLOAD.md)**.

## Reporting a problem

Security issues: see **[SECURITY.md](SECURITY.md)** (private vulnerability reporting — please don't open a public issue). Bugs and questions: open an issue.

## Third-party code

The terminal QR renderer embeds the [Project Nayuki QR Code generator](https://www.nayuki.io/page/qr-code-generator-library) (Python, MIT), unmodified, with its license header preserved in-file. CI verifies that block against a pinned checksum and asserts it imports only the standard library. Everything else is © 2026 GigaDuck OÜ under the [MIT License](LICENSE).
