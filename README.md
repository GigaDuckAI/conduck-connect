# conduck-connect

One script that pairs a self-hosted AI gateway — **OpenClaw**, **Hermes**, or any OpenAI-compatible server — with the [Conduck](https://gigaduck.ai/conduck) app. It enables the chat endpoint, helps you expose the gateway over HTTPS, optionally stands up the agent file lane (rclone WebDAV), verifies everything with real requests, and prints a QR + paste **pairing code** the app imports in one scan.

> **Status: pre-release.** The Conduck app is not yet public. This repository is open early on purpose — so the script can be **read and audited before you ever run it.** That is the whole point of shipping it as a plain shell script.

## Why a shell script?

Because you should be able to read exactly what runs on your server before it runs. No binary, no installer, no `curl | bash`. You download it, read it, and run it with `bash`.

## Get it and run it

```bash
# 1. Download the script and its checksum (pinned release — not `main`)
curl -fLO https://github.com/gigaduckai/conduck-connect/releases/download/v0.4.0-rc.1/conduck-connect.sh
curl -fLO https://github.com/gigaduckai/conduck-connect/releases/download/v0.4.0-rc.1/conduck-connect.sh.sha256

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
