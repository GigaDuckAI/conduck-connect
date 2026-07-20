# conduck-connect

Pair your self-hosted AI gateway with the **[Conduck](https://conduck.com)** app — one readable script you audit before you run. Zero telemetry.

## Quick start

One command — downloads the script from GitHub Releases to disk over HTTPS, then launches the setup wizard. The wizard still **asks before every change**, so nothing touches your server without a y/N:

```bash
curl -fsSLO https://github.com/gigaduckai/conduck-connect/releases/latest/download/conduck-connect.sh && bash conduck-connect.sh
```

- **Preview first, change nothing?** Append ` --dry-run` to the trailing `bash conduck-connect.sh`.
- **Read it before running?** Drop the trailing `&& bash conduck-connect.sh` — the rest still downloads the file — then `less conduck-connect.sh` and run it when you're happy. It's a plain, readable script on purpose ([why](#why-a-shell-script)).

Works on macOS and Linux. `-O` lands the full file on disk before anything runs, so reading it first is one `less` away — that, plus the HTTPS download from GitHub, is your real protection. (An optional same-release checksum is [below](#what-each-step-does); it confirms the download arrived intact but is not a tamper-proof signature.)

It pairs **OpenClaw**, **Hermes**, or any OpenAI-compatible server with Conduck (built your own agent? see the [adapter contract](https://conduck.com/setup/adapter/v1/)): enables the chat endpoint, helps you expose the gateway over HTTPS, optionally stands up the agent file lane (rclone WebDAV) — on OpenClaw also checking the gateway's **tool policy** (a policy denying the agent's `read`/`write` breaks attachments agent-side while every transport test stays green) and installing a short agent-guidance block in the workspace `TOOLS.md` — verifies everything with real requests, and prints a QR + paste **pairing code** the app imports in one scan.

> **Status: the script is at `v0.10.0`; the Conduck app is not yet public.** This repository is open early on purpose — so the script can be **read and audited before you ever run it.** That is the whole point of shipping it as a plain shell script.

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
| `--show-qr` | Re-show a saved gateway's pairing code — reads only, changes nothing (uses the non-secret profile a successful run saves; may still ask you to pick a profile, re-enter a custom gateway's token, or confirm a gateway-only code). Verification still makes its real requests. |
| `--openclaw` · `--hermes` · `--generic` | Skip detection; target a specific gateway kind |
| `--doctor [url]` | Check an adapter built for Conduck against the rules at [conduck.com/setup/adapter/v1/](https://conduck.com/setup/adapter/v1/) — real requests, graded strictly, changes nothing (see below) |
| `--deep` | With `--doctor`: also test how the adapter handles a message with an image |
| `--allow-keyless-public` | Expert: permit a keyless gateway on a public transport |
| `--help` | All flags |

## Check your own adapter (`--doctor`)

Have an adapter built for Conduck — by hand or by an AI coding tool? Before exposing or pairing it, run the check on the machine where it listens:

```bash
CONDUCK_TOKEN="$TOKEN" bash conduck-connect.sh --doctor http://127.0.0.1:8080
```

The script changes nothing. It sends a handful of real requests, grades the answers against the rules at **[conduck.com/setup/adapter/v1/](https://conduck.com/setup/adapter/v1/)** — including the one the pairing wizard can't prove: that your token check is actually **enforced** (a missing or a wrong token must both get `401`, on both routes) — and tells you what to fix. Exit code `0` means every check passed, so you can loop it from a build script while you iterate. Plain `http://` is accepted toward `127.0.0.1`/`localhost` only; the token comes from `$CONDUCK_TOKEN` or a hidden prompt, never the command line. Add `--deep` to also test a message with an image (an honest HTTP `400` "images unsupported" answer passes).

One scope note: it grades the *adapter* rules. OpenClaw and Hermes legitimately do things those rules forbid (keyless mode, for one), so pointing the doctor at them produces failures that don't mean anything is wrong — use the normal wizard verification for those.

## Trust posture

- Runs on **your** gateway host. Sends nothing anywhere except to your own gateway. **No telemetry, ever.** The QR is generated locally.
- Never installs gateways, Tailscale, cloudflared, rclone, or any daemon it didn't create.
- Asks before every change. Things *you* own (a Cloudflare tunnel, your reverse proxy) are printed as exact commands for you to run yourself.
- Never elevates silently — where `sudo` is needed it prints the exact command for you to review and run.
- Never makes your gateway public without telling you, in plain words, that it will — and refuses to publish a keyless gateway unless you pass `--allow-keyless-public`.
- Re-running is safe; `--show-qr` re-shows your saved pairing code without touching anything.

See **[WHAT-IT-TOUCHES.md](WHAT-IT-TOUCHES.md)** for the exact files, services, and ports it reads or changes — and how to undo each.

## Requirements

`bash` (3.2+), `curl`, `python3`, `openssl`. A Linux or macOS gateway host.

The wizard is interactive and needs a real terminal: prompts cannot be piped in, and there are no non-interactive answer flags. (An AI tool driving it needs a real PTY.)

## Reaching your gateway

Conduck needs the gateway at an `https://` URL. The wizard walks four paths and lets you pick — no auto-recommendation, just honest trade-offs:

- **Tailscale** — private, tailnet-only. *Note: a standalone Apple Watch cannot reach a tailnet-only gateway.*
- **Tailscale Funnel** — public, end-to-end encrypted.
- **Cloudflare Tunnel** — public; needs a domain and `cloudflared`.
- **I already run my own HTTPS** — give the address; the script trusts a publicly-valid cert (e.g. Let's Encrypt) or pins a self-signed one for you. A broken cert (expired / wrong host) stops the run rather than getting silently pinned.

## Set up the file lane by hand (any WebDAV server)

**The easy path is to re-run `conduck-connect`.** It's the supported way to add file transfer after chat is already paired: it detects an existing `conduck-files-<gwid>` server, reuses its folder, port, and credential, reconciles the lane's reach against the gateway's, verifies a `PUT` → `GET` → `DELETE` round-trip, and emits a fresh pairing code. Reach for the manual path below only when you run your own topology — Caddy, nginx, a NAS appliance, containers, or rclone under your own supervisor — anything that already speaks WebDAV.

Conduck doesn't care *how* the endpoint is built, only that it satisfies the contract the in-app **Test Connection** stages check. Serve that contract with whatever you already run.

**The contract**

- **HTTPS, not HTTP.** The app rejects an `http://` file URL outright. Terminate TLS with a real or self-signed certificate (see security notes).
- **HTTP Basic auth, username `conduck`.** The password is generated *in the app* — **Settings → your gateway → File transfer → Generate credential** — and pasted into your server's config. Conduck never accepts a password you invent; the app is the source of truth for that credential.
- **Serve the folder the agent actually reads and writes.** The WebDAV root must be the agent's working directory — for OpenClaw its workspace (`~/.openclaw/workspace` by default), for Hermes the folder `terminal.cwd` points at in `~/.hermes/config.yaml`. No test can catch this: point the root at the wrong folder and uploads land on disk, every check goes green, and your agent still never sees the file.
- **The agent must be ALLOWED to use its file tools.** Byte transport is only half the lane: the gateway's tool policy decides whether the agent may open uploads and write output files. On OpenClaw, `tools.deny` containing `group:fs` (a common hardening move) breaks every attachment turn while every transport check stays green — `read` and `write` must be allowed (keep `edit`/`apply_patch`/`exec` denied if you like), and native PDF analysis additionally needs `tools.alsoAllow: ["pdf"]` (the `pdf` tool is not in the `coding` profile). The wizard checks this and offers the exact fix; hand-built setups must mind it themselves. No test can catch this one either.
- **Same reach as the gateway.** Expose the file server on the same rail you exposed the gateway on. If the gateway is public but the file server is tailnet-only, a standalone Apple Watch can still chat but silently can't send or open attachments.

Then, in the app: paste the file-lane URL and run **Test Connection**. The staged test proves reachability, auth, and a byte-faithful `PUT` → `GET` → `DELETE` round-trip — everything except whether the root is the *right* folder, which only you can confirm.

**Security**

- **Never put the password on a command line** — `argv` is visible to `ps`. Pass it through an environment variable or a config file with `0600` permissions.
- **HTTPS with a real or self-signed cert.** Self-signed is fine — paste its SPKI fingerprint in the app (your gateway → **File transfer** → Advanced → *Pinned cert fingerprint*) so Conduck trusts exactly that key.
- **Isolate lanes.** If you run more than one file lane on a host, give each its own credential, port, and service name — no shared state between them.

**Exposure**

Any HTTPS route works: **Tailscale Serve** (private tailnet), **Tailscale Funnel** (public), a **Cloudflare named tunnel** (public — use a routed hostname, not the ephemeral quick-tunnel URL), or your own reverse proxy / VPS. Usually the file server should ride the *same* rail you already used for the gateway.

**Example** (illustrative, not the blessed way) — serve OpenClaw's workspace with rclone, credential via the environment so it never reaches `argv`:

```
read -rs RCLONE_PASS && export RCLONE_PASS   # paste the app-generated password at the silent prompt
rclone serve webdav ~/.openclaw/workspace --addr 127.0.0.1:5006 --user conduck
```

(`read -rs` keeps the password out of your shell history and off `argv`; a `0600` env file read by your service manager does the same job for a persistent unit.)

`serve` runs in the foreground and binds to loopback only — put it under systemd / launchd / your own supervisor for a real deployment, and front it with the tunnel or reverse proxy of your choice to reach it over HTTPS. Swap the folder, port, and exposure for whatever your setup uses.

## Troubleshooting

The wizard's Step 5 verifies with real requests and names what failed. What each message means, and the fix (the last row prints during the exposure step, before verification). App-side setup help — including what to do *before* the script runs — lives at https://conduck.com/setup/#troubleshooting.

| The wizard says | What it means | The fix |
|---|---|---|
| `…/v1/models returned an HTML page instead of model data` | On OpenClaw/Hermes, most likely the chat endpoint is still off (it ships off by default). Behind a tunnel or reverse proxy, a login/access page may have answered instead — a 401/403 status shown in the message points that way. | Re-run the wizard (its Step 2 enables the endpoint), restart the gateway. If an access layer answered, allow the gateway host through it. |
| `…answers, but not with the required envelope` | The server replied JSON, but not the shape Conduck requires: an object with a top-level `"data"` array. Bare arrays and `{"models": …}` shapes are refused — by the script and the app alike. | Fix the server's `/v1/models` reply — the contract lives at https://conduck.com/setup/adapter/v1/. |
| `…failed: DNS lookup failed` | The hostname doesn't resolve. | Check the spelling; a just-created DNS record can take a minute to propagate. |
| `…failed: connection refused` | Nothing is listening at that host and port. | Is the server running? Right port? Firewall open? Many local servers (Ollama, LM Studio) bind to `127.0.0.1` only — front them with the wizard's exposure step. |
| `…failed: timed out` | No answer at all. | Host offline, unreachable address, or a firewall silently dropping traffic. |
| `…failed: TLS/certificate problem` | Either the server's certificate is bad (expired, wrong hostname) or this machine's own trust store rejected it. | Renew or fix the certificate — expired and wrong-hostname certs both stop the run, deliberately. A wrong system clock on either end produces the same failure. |
| `…failed: pinned key mismatch` | The server's certificate is not the one this run pinned. | Re-run the wizard so it pins the current cert (it never re-pins silently). |
| `…failed: HTTP 401 — token rejected` | Wrong or stale bearer token — or an access layer in front wants its own login. (A 403 prints the same shape.) | Re-read the token from the gateway's config (OpenClaw: `gateway.auth.token` · Hermes: `API_SERVER_KEY`); check any proxy access policy. |
| `…failed: HTTP 404 — nothing at that path` | No `/v1/models` at that base address. | Give the server's *base* address — the script and the app append `/v1/…` themselves. (A pasted `…/v1` is normalized away automatically.) |
| `…failed: HTTP 5xx — the server errored` | The gateway itself failed. | Read the gateway's own logs. |
| `…failed: answered 200, but the body isn't JSON` | Something replied OK — but not with JSON (a proxy's plaintext page, or malformed JSON the strict parser refuses). | Check what actually answers at that address; the reply contract lives at https://conduck.com/setup/adapter/v1/. |
| `…but its model list is EMPTY` | The endpoint is real, yet advertises no models — it can't answer a chat. | Pull/load a model (e.g. `ollama pull …`, load one in LM Studio), or set the model name your gateway expects. |
| `live round-trip failed (transfer error — timed out or the connection dropped)` | The test chat request didn't complete within 300 s (the app's own limit), or the connection broke mid-reply. | Modest hardware and busy agents are slow — try again; check server load and any proxy read-timeout in front. |
| `live round-trip failed (no answer from the gateway)` | The request went out, but nothing came back — no status, no body. | Usually a tunnel or proxy swallowing the request — check the rail the gateway rides, then the gateway's own logs. |
| `live round-trip failed (HTTP …)` | The chat endpoint rejected the request. | A 404 here usually means the named model isn't available on the server; a 400 often means the server requires a `model` field — set one when the wizard asks. |
| `live round-trip failed (HTTP 200, but no usable text — "content" must be a non-empty string)` | The reply's `content` wasn't plain text — e.g. a tool-call turn, or a streaming-only adapter. | The endpoint must honor `stream: false` and return the final answer as a plain string — see the adapter contract. |
| `This gateway has NO authentication, and this transport is publicly reachable.` | Keyless + public would put an unauthenticated, tool-capable agent on the open internet. The script refuses. | Keep it private (Tailscale), put a token on the gateway — or, expert-only, re-run with `--allow-keyless-public`. |

### Other endpoint gotchas

Nothing fails, so no message prints — but the result quietly isn't what you wanted:

- **Hermes: pair the full-agent API server (default `8642`), never `hermes proxy` (`8645`).** Both chat, but the proxy carries no tools, skills, or memory. The wizard challenges a Hermes config whose `API_SERVER_PORT` is 8645; if you wired it by hand, re-check the port.
- **vLLM can list a model whose chat fails** — a model served without a chat template answers `/v1/models` but errors on `/v1/chat/completions`.
- **In-app symptoms** (Test Connection inside Conduck, device-specific behavior like Apple Watch reach): the setup ladder at https://conduck.com/setup/#troubleshooting covers those.

### File-lane problems

- `file lane probe failed` / `the saved profile's file lane failed live verification` — the WebDAV server didn't complete the PUT → GET → DELETE round-trip: wrong credential (regenerate it in the app and update the server), server not running, or its HTTPS front broken.
- **Every check green, but the agent never sees uploaded files** — two known causes, neither detectable by any test:
  1. the WebDAV root points at the wrong folder — it must be the agent's *working directory*; see the contract in "Set up the file lane by hand" above;
  2. the gateway's **tool policy denies the agent's file tools** — on OpenClaw, `tools.deny` containing `group:fs` (or `read`) makes every upload invisible to the agent; the typical symptom is the agent web-searching for the filename, claiming it can't access files, or the first attachment turn timing out into a "no response" placeholder while the agent flails. Re-run the wizard (its file-lane step checks the policy and offers the exact fix), or allow `read`/`write` yourself and restart the gateway.
- **A PDF "answers" but with generic or wrong content** — the agent read the PDF's raw bytes instead of analyzing it natively. On OpenClaw the `pdf` tool is not in the `coding` profile (`tools.alsoAllow: ["pdf"]` enables it), and it wants the file's **absolute** workspace path — a bare filename fails its allowed-directory check even where `read` succeeds. The wizard's `TOOLS.md` block teaches the agent the absolute-path retry.
- **The agent says it saved/sent a file, but no download chip appears** — the agent delivered it as a channel-attachment directive (e.g. a `MEDIA:<path>` line), which the OpenAI-compatible endpoint strips; the reply reaches Conduck without the filename, so nothing can be offered for download. The rule (installed into `TOOLS.md` by the wizard, scoped to Conduck turns): write the file to the working-directory root and **name it in plain reply text**. Agent guidance loads at session start — test in a **new** conversation. If the file was really written, asking "what is the exact filename of the file you saved?" in the same conversation makes the chip appear on the answer.
- **Chat works everywhere, but attachments fail on a standalone Apple Watch** — the file lane rides a narrower rail than the gateway (say, a tailnet-only lane behind a public gateway). Expose both on the same rail; re-running the wizard reconciles the two.

## Pairing code

`conduck-setup:v1:<base64(JSON)>` — same content in the QR and the paste string. Full contract in **[PAYLOAD.md](PAYLOAD.md)**.

## Reporting a problem

Security issues: see **[SECURITY.md](SECURITY.md)** (private vulnerability reporting — please don't open a public issue). Bugs and questions: open an issue.

## Third-party code

The terminal QR renderer embeds the [Project Nayuki QR Code generator](https://www.nayuki.io/page/qr-code-generator-library) (Python, MIT), unmodified, with its license header preserved in-file. CI verifies that block against a pinned checksum and asserts it imports only the standard library. Everything else is © 2026 GigaDuck OÜ under the [MIT License](LICENSE).
