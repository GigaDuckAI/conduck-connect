# conduck-connect

Pair your self-hosted AI gateway with the **[Conduck](https://gigaduck.ai/conduck)** app — one readable script you audit before you run. Zero telemetry.

## Quick start

One command — downloads the script from GitHub Releases to disk over HTTPS, then launches the setup wizard. The wizard still **asks before every change**, so nothing touches your server without a y/N:

```bash
curl -fsSLO https://github.com/gigaduckai/conduck-connect/releases/latest/download/conduck-connect.sh && bash conduck-connect.sh
```

- **Preview first, change nothing?** Append ` --dry-run` to the trailing `bash conduck-connect.sh`.
- **Read it before running?** Drop the trailing `&& bash conduck-connect.sh` — the rest still downloads the file — then `less conduck-connect.sh` and run it when you're happy. It's a plain, readable script on purpose ([why](#why-a-shell-script)).

Works on macOS and Linux. `-O` lands the full file on disk before anything runs, so reading it first is one `less` away — that, plus the HTTPS download from GitHub, is your real protection. (An optional same-release checksum is [below](#what-each-step-does); it confirms the download arrived intact but is not a tamper-proof signature.)

It pairs **OpenClaw**, **Hermes**, or any OpenAI-compatible server with Conduck: enables the chat endpoint, helps you expose the gateway over HTTPS, optionally stands up the agent file lane (rclone WebDAV), verifies everything with real requests, and prints a QR + paste **pairing code** the app imports in one scan.

> **Status: pre-release.** The Conduck app is not yet public. This repository is open early on purpose — so the script can be **read and audited before you ever run it.** That is the whole point of shipping it as a plain shell script.

## Why a shell script?

Because you can read exactly what would run on your server — it's a plain, auditable script, not an opaque binary or installer. The Quick start writes it to a file **before** anything runs, so reading it yourself is one `less` away — always encouraged for a tool that touches your gateway.

This is deliberately *not* `curl | bash` — that pipes unverified code straight into your shell, unread (and would break this script's interactive prompts anyway). Here the file lands on disk, remains available to inspect, and only then runs.

## What each step does

The Quick start chains these together. Here they are one at a time, with what each does:

```bash
# 1. Download the script to disk (latest published release — not `main`)
curl -fsSLO https://github.com/gigaduckai/conduck-connect/releases/latest/download/conduck-connect.sh

# 2. Read it — that is the point
less conduck-connect.sh

# 3. See what it WOULD do, changing nothing
bash conduck-connect.sh --dry-run

# 4. Run it for real (every change still asks first)
bash conduck-connect.sh
```

**Optional integrity check.** Each release also ships a checksum. It confirms the file downloaded intact — it is **not** a signature and can't prove the release wasn't swapped (it rides the same release channel); reading the script is what catches that:

```bash
curl -fsSLO https://github.com/gigaduckai/conduck-connect/releases/latest/download/conduck-connect.sh.sha256
shasum -a 256 -c conduck-connect.sh.sha256        # Linux: sha256sum -c conduck-connect.sh.sha256
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
