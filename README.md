# conduck-connect

Pair your self-hosted AI gateway with the **[Conduck](https://conduck.com)** app — one plain-text script you can inspect before you run. Zero telemetry.

## Quick start

One command — downloads the script from GitHub Releases to disk over HTTPS, then opens the welcome menu:

```bash
curl -fsSLO https://github.com/gigaduckai/conduck-connect/releases/latest/download/conduck-connect.sh && bash conduck-connect.sh
```

- **Go straight to setup?** Append ` --setup` to the trailing `bash conduck-connect.sh`.
- **Preview setup, change nothing?** Append ` --setup --dry-run` instead.
- **Read it before running?** Drop the trailing `&& bash conduck-connect.sh` — the rest still downloads the file — then `less conduck-connect.sh` and run it when you're happy. It stays plain text on purpose ([why](#why-a-shell-script)).

Works on macOS and Linux. `-O` lands the full file on disk before anything runs, so inspecting it is one `less` away. An optional same-release checksum is [below](#what-each-step-does); it confirms the download arrived intact but is not a tamper-proof signature.

It pairs **OpenClaw**, **Hermes**, or any OpenAI-compatible server with Conduck (built your own agent? see the [adapter contract](https://conduck.com/setup/adapter/v1/)): enables the chat endpoint, helps you expose the gateway over HTTPS, optionally stands up the agent file lane (rclone WebDAV), verifies everything with real requests, and prints a QR + paste **pairing code** the app imports in one scan. Agent-side checks are gateway-aware: OpenClaw gets a tool-policy check plus workspace `TOOLS.md` guidance; Hermes gets its API-server file toolset and exact `terminal.cwd` checked plus verified Hermes context guidance. Both must then pass a real read→byte-identical-write→reply-discovery sentinel before the file lane reaches the code.

> **Release boundary:** the script's `VERSION` remains `0.13.0`, while `main`
> may also contain entries under **Unreleased** that are not in the published
> `v0.13.0` asset. The Quick start always downloads the latest *published*
> release—not `main`; the [releases page](https://github.com/gigaduckai/conduck-connect/releases)
> is the authority on what is live. Rebuilding or testing the local artifact
> does not publish it. The Conduck app is already available on the App Store.
> Every release artifact is plain, unminified shell that can be inspected
> before it runs.

## Why a shell script?

Because you can inspect exactly what would run on your server — it is plain text, not an opaque binary or installer. The Quick start writes it to a file **before** anything runs, so review is one `less` away — always encouraged for a tool that touches your gateway.

This is deliberately *not* `curl | bash` — that pipes unverified code straight into your shell, unread (and would break this script's interactive prompts anyway). Here the file lands on disk, remains available to inspect, and only then runs.

For maintainers, the source is split by responsibility under [`src/`](src/) and
assembled deterministically. CI proves those modules reproduce the checked-in
`conduck-connect.sh` byte for byte. That keeps development navigable without
turning the user-facing tool into a runtime bundle: the release is still one
plain, unminified script.

## What each step does

The Quick start chains these together. Here they are one at a time, with what each does:

```bash
# 1. Download the script to disk (latest published release — not `main`)
curl -fsSLO https://github.com/gigaduckai/conduck-connect/releases/latest/download/conduck-connect.sh

# 2. Read it — that is the point
less conduck-connect.sh

# 3. See what setup WOULD do, changing nothing
bash conduck-connect.sh --setup --dry-run

# 4. Open the welcome menu
bash conduck-connect.sh

# Or go straight to setup (every change still asks first)
bash conduck-connect.sh --setup
```

**Optional integrity check.** Each release also ships a checksum. It confirms the file downloaded intact—it is **not** a signature and cannot prove the release was not swapped because it rides the same release channel:

```bash
curl -fsSLO https://github.com/gigaduckai/conduck-connect/releases/latest/download/conduck-connect.sh.sha256
shasum -a 256 -c conduck-connect.sh.sha256        # Linux: sha256sum -c conduck-connect.sh.sha256
```

No `chmod` needed. The one large block near the bottom of the script is a vendored, unmodified QR-code encoder (Project Nayuki, MIT) used to draw the QR locally. It is inert — Python standard library only, no network, file, or process access — and safe to skip when reading.

## Public commands and flags

| Command | Effect |
|---|---|
| _(none)_ | Welcome menu: setup, check a server, check an adapter, or re-show a saved code |
| `--setup` | Go straight to setup. Detection reports OpenClaw/Hermes installs, but you always explicitly choose OpenClaw, Hermes, or another server |
| `--check-server [url]` | Existing OpenAI-compatible software **not built for Conduck**: check core compatibility with the current Apple Conduck app |
| `--check-adapter [url]` | An adapter built specifically for Conduck: grade the stricter adapter contract |
| `--show-code` | Re-show a saved gateway's pairing code without configuration changes. Live verification sends gateway requests and, when configured, one small file-lane PUT→GET→DELETE probe; OpenClaw/Hermes lanes also get a real agent file-tool sentinel |
| `--setup --dry-run` | Show setup state and the exact actions a real run would take, then stop. Never prompts for secrets, mints credentials, sends requests, or emits a code |
| `--setup --reuse-only` | Walk setup using only what already exists. It does not apply host configuration changes — the first step that would need one stops the run and names it, rather than skipping past it. Live verification still sends gateway requests and may write/delete the normal byte probe; a configured OpenClaw/Hermes lane also runs the real agent read→write→reply sentinel |
| `--check-adapter --deep [url]` | Also test how the adapter handles a message with an image |
| `--check-adapter --files [url]` | Also grade the file lane. This explicitly mutating check writes and removes small named artifacts — `conduck-check-*` plus one `output-*.txt` — in the configured shared folder |
| `--setup --allow-keyless-public` | Expert: permit a keyless gateway on a public transport |
| `--help` / `-h` | The script's whole header: what it does, what it never does, and every public flag |
| `--version` | Print `conduck-connect <version>` and exit — nothing else runs |

Exit status is deliberately small and stable: `0` means success (or a passing
check), `1` means setup/runtime failure or a completed check that failed, and
`2` means the command line itself is invalid—an unknown or retired spelling,
incompatible flags, an extra positional argument, or an invalid direct URL.
Signal interruptions retain their conventional `128 + signal` status. Once a
noninteractive check has passed command validation, its machine summary remains
the final line even if runtime preflight fails—for example, missing `curl` or
`python3` reports `exit=1` with all check meters still `NOT_RUN`.

The public setup command is `--setup`; there is no second public “generic”
mode. One older spelling, `--generic`, remains functional but intentionally
hidden from the menu and `--help` because App Store builds already in users'
hands still invoke it. It goes directly to custom-server setup and skips
OpenClaw/Hermes detection, preserving those clients' original behavior.

After either check passes in a real terminal, the script asks whether you want to continue directly into setup and pairing. It reuses the checked URL and authentication in memory, skips the gateway-choice question, and verifies the final app-facing HTTPS route again before printing a code. In CI or any noninteractive run, it never asks: it prints the machine summary as the final line and exits.

## Check your own adapter (`--check-adapter`)

Have an adapter built for Conduck — by hand or by an AI coding tool? Before exposing or pairing it, run the check on the machine where it listens:

```bash
CONDUCK_TOKEN="$TOKEN" bash conduck-connect.sh --check-adapter http://127.0.0.1:8080
```

The check changes no host configuration. It sends a handful of real requests—which may consume compute or enter server-side history—and grades the answers against the rules at **[conduck.com/setup/adapter/v1/](https://conduck.com/setup/adapter/v1/)**. That includes the one the pairing wizard cannot prove: your token check is actually **enforced** (a missing or wrong token must get `401` on both routes). Exit code `0` means every check passed. Plain `http://` is accepted toward `127.0.0.1`/`localhost` only; the token comes from `$CONDUCK_TOKEN` or a hidden prompt, never the command line (`argv` is visible to `ps`). For a scripted run with no keys at all, export `CONDUCK_TOKEN=` **empty** — that is an explicit keyless declaration. Leaving it unset where no prompt is possible (piped or closed input) fails fast instead of grading the target as keyless, because a silently-assumed keyless run grades the wrong thing and calls it a pass. Add `--deep` to test a message with an image (an honest HTTP `400` "images unsupported" answer passes).

One scope note: it grades the *adapter* rules. Generic OpenAI-compatible software — OpenClaw, Hermes, Ollama, LiteLLM, vLLM — legitimately does things those rules forbid (honoring `stream: true` with SSE is correct OpenAI behavior; keyless modes are fine app-side), so using this strict adapter check on them produces failures that don't mean anything is wrong. **That's what `--check-server` is for** (next section): if the software was built specifically for Conduck, use `--check-adapter`; if it was not, use `--check-server`.

### Grade the file lane too (`--check-adapter --files`)

If your setup has a file lane (the shared folder the app and your agent exchange files through), `--files` grades it as three independent meters: **`file_transport`** — the WebDAV↔disk lane itself (auth on the routes that carry your bytes, byte-identical write-through, *direct-write freshness* — a file written straight to disk must be visible over WebDAV within 2 seconds, ranged-probe compatibility, nested folders, verified DELETE); **`file_access`** — one real chat turn in which the selected model must copy a small input file byte-for-byte to the folder root, finish *before* replying, and name the output in plain reply text; **`file_e2e`** — the combined delivery path. This profile **mutates**: it writes and removes small named artifacts in the configured folder — a `conduck-check-<run>/` folder with its input file, plus `output-<run>.txt` at the folder root, which is the file the agent itself is asked to write and so carries no `conduck-check-` prefix (`<run>` is a random per-run tag). Every target is registered before creation, removed by exact name — never by pattern — and cleanup that cannot be *proven* is reported by exact name rather than assumed. On the machine where setup ran it finds the lane from your saved profile; elsewhere set `CONDUCK_FILES_URL` + `CONDUCK_FILES_DIR` + `CONDUCK_FILES_PASS`.

The last line of every noninteractive adapter check is a machine summary (`CONDUCK_CHECK_ADAPTER schema=3 …`) — build scripts key on the prefix, the `schema=`, and the exit code. The grammar is frozen per schema number; any change to it bumps `schema=`, so pin the number you parse.

## Testing existing OpenAI software (`--check-server`)

Pointing Conduck at something you already run — Ollama, LiteLLM, vLLM, LM Studio, a framework's OpenAI-compatible endpoint? Use:

```bash
CONDUCK_TOKEN="$TOKEN" bash conduck-connect.sh --check-server http://127.0.0.1:11434
```

The check changes no host configuration, but it sends several real model/chat/image requests that may consume compute or enter server-side history. At the **directly addressed endpoint**, it matches the current Apple app's request and response acceptance: any 2xx response is decoded, response `Content-Type` is not graded, the full `choices` array must decode, an empty-string reply is valid, extra fields such as `tool_calls` are tolerated, `stream: true` is never sent, and no negative-auth requests are made. An empty answer at the prompt — or an exported but empty `CONDUCK_TOKEN=` — means the app's explicit keyless mode.

The diagnostic deliberately does not follow HTTP redirects or forward your credential to a `Location` target. A 3xx result tells you to use the final server URL directly. Conduck's Apple networking stack may follow an allowed redirect, but redirect policy is not part of this check's promise.

Four wire checks cover core text-chat compatibility: models envelope + 15-second limit, chat decode, advertised-model selection, and history-image tolerance. The image-capability result (`VERIFIED` / `DECLINED` / `IGNORED` / `OPAQUE`) is separate and informational; it never changes the core PASS/FAIL verdict. Servers that require a `model` field pass with a `model=required` note—in the app, pick a model in gateway settings. Android is still a work-in-progress client and is not the compatibility authority yet.

### Checking a specific model (`CONDUCK_CHECK_SERVER_MODEL`)

The check first asks your server with no model name at all, and then — whenever one is available — asks again naming a model. Left to itself, the one it names is whichever id `/v1/models` happens to return first, and that order has nothing to do with what any of those models can do. On a server that fronts many models that has a sharp edge: the same server can come back FAIL or PASS purely on the order it lists them, so the verdict you get may be about a model you were never going to use.

Name the one you actually plan to use:

```bash
CONDUCK_CHECK_SERVER_MODEL='llama-3.3-70b' bash conduck-connect.sh --check-server http://127.0.0.1:4000
```

Every request in that run that carries a model name then carries that one, and the transcript says which model each verdict describes. The requests that deliberately test model-less behavior still leave it out — that is a separate thing worth knowing about your server. An id your server does not advertise is checked anyway; you just get a note that it is not in the list, in case it is a typo. Leave the variable unset and nothing about the run changes: it falls back to the first advertised id, or to whatever your server routes to by default when it answers without a model field at all.

If you continue into setup, the pairing code keeps the routing the check actually proved — the model you named, or no model name at all when what got tested was the server's own default route.

The last line of every noninteractive run is a machine summary (`CONDUCK_CHECK_SERVER schema=2 … wire=PASS|FAIL …`); exit `0` means core text-chat compatibility is green. It does **not** certify image understanding, public reachability, HTTPS certificate trust, or make the server a Conduck adapter (that is `--check-adapter`). Statefulness is also invisible on the wire: Conduck resends the full conversation every turn, so a server that keeps its own history will silently double-count context.

## Trust posture

- Runs on **your** gateway host. **No telemetry, ever — there is no GigaDuck server.** Its own HTTP probes go only to the gateway and file lane you name, and the QR is generated locally. The exception is the exposure path you choose: `tailscale serve` / `tailscale funnel` and `cloudflared tunnel list` are that vendor's own commands, and running them contacts that vendor's control plane.
- Never installs gateways, Tailscale, cloudflared, rclone, or any daemon it didn't create.
- Asks before every change. Things *you* own (a Cloudflare tunnel, your reverse proxy) are printed as exact commands for you to run yourself.
- Never elevates silently. Every command that needs higher rights is shown in full first — prefixed with `sudo` or `doas`, whichever this machine has, and bare when you are already root or have neither — and all but one are printed for you to review and run yourself (Tailscale operator rights, `pmset`). The exception is `loginctl enable-linger <user>` in the file-lane step — lingering is what keeps your file server running after you log out. The script runs that one itself, and only after you approve the exact command at a `y/N` prompt; decline and it prints it as a tip instead.
- Never makes your gateway public without telling you, in plain words, that it will — and refuses to publish a keyless gateway unless you run setup with `--setup --allow-keyless-public`.
- Re-running is safe; `--show-code` re-shows your saved pairing code without changing configuration. Its live verification still sends gateway requests and briefly writes/removes small randomized probes when a file lane is configured (including a real OpenClaw/Hermes agent file turn).

See **[WHAT-IT-TOUCHES.md](WHAT-IT-TOUCHES.md)** for the exact files, services, and ports it reads or changes — and how to undo each.

## Requirements

`bash` (3.2+), `curl`, `python3`, `openssl`. A Linux or macOS gateway host.

The wizard is interactive and needs a real terminal: prompts cannot be piped in, and there are no non-interactive answer flags. (An AI tool driving it needs a real PTY.)

## Reaching your gateway

Conduck needs the gateway at an `https://` URL. The wizard walks four paths and lets you pick — no auto-recommendation, just honest trade-offs:

- **Tailscale** — private, tailnet-only. *Note: a standalone Apple Watch cannot reach a tailnet-only gateway.*
- **Tailscale Funnel** — public, end-to-end encrypted.
- **Cloudflare Tunnel** — public; needs a domain and `cloudflared`.
- **I already run my own HTTPS** — give the address; its certificate has to be one your devices already trust (e.g. Let's Encrypt). Anything else — self-signed, a private CA, expired, wrong hostname — stops the run, and the script names the three free ways to get a real certificate.

Whatever you pick, the certificate is not negotiable: Apple's App Transport Security rejects a chain the device doesn't trust before Conduck is ever consulted, and a fingerprint pin can only *narrow* trust a device already has — it cannot grant it. So a self-signed certificate has no working outcome on a phone, and the wizard refuses to mint a code that would fail there. The three free routes it points you at:

- **Tailscale Serve** — issues a real certificate automatically and exposes nothing publicly (that's option 1 above).
- **Let's Encrypt** — free, and since January 2026 it also issues certificates for a bare IP address, so no domain is required.
- **A domain in front of it** — Caddy or another reverse proxy obtains and renews the certificate for you.

Whichever path you pick, every address you type — gateway or file lane — has to be a plain URL. One carrying `user:pass@` credentials is refused, by the wizard and by both check commands: that password would otherwise be echoed on screen, saved into the profile, and ride inside the pairing code. Credentials belong in the token prompt, not the address.

## Set up the file lane by hand (any WebDAV server)

**The easy path is to re-run `conduck-connect`.** It's the supported way to add file transfer after chat is already paired: it detects an existing `conduck-files-<gwid>` server, reuses its stable folder/port/credential, allocates a different free loopback port when another gateway already owns the default, checks the local service before exposing it, reconciles the lane's reach against the gateway's, and emits a fresh pairing code only after live verification. Reach for the manual path below only when you run your own topology — Caddy, nginx, a NAS appliance, containers, or rclone under your own supervisor — anything that already speaks WebDAV.

Conduck doesn't care *how* the endpoint is built, only that it satisfies the contract the in-app **Test Connection** stages check. Serve that contract with whatever you already run.

**The contract**

- **HTTPS, not HTTP.** The app rejects an `http://` file URL outright. Terminate TLS with a certificate the device already trusts — the same bar as the gateway (see security notes).
- **HTTP Basic auth, username `conduck`.** The password is generated *in the app* — **Settings → your gateway → File transfer → Generate credential** — and pasted into your server's config. Conduck never accepts a password you invent; the app is the source of truth for that credential.
- **Serve the folder the agent actually reads and writes.** The WebDAV root must be the agent's working directory — for OpenClaw its workspace (`~/.openclaw/workspace` by default), for Hermes the folder `terminal.cwd` points at in `~/.hermes/config.yaml`. The wizard aligns the Hermes root and live-proves both OpenClaw and Hermes lanes before including them. For a custom/manual adapter, `--check-adapter --files` runs the same decisive kind of agent-side copy test; the in-app WebDAV test alone cannot prove the agent's working root.
- **The agent must be ALLOWED to use its file tools.** Byte transport is only half the lane: the gateway's tool policy decides whether the agent may open uploads and write output files. On OpenClaw, `tools.deny` containing `group:fs` (a common hardening move) breaks every attachment turn while transport stays green — `read` and `write` must be allowed (keep `edit`/`apply_patch`/`exec` denied if you like), and native PDF analysis additionally needs `tools.alsoAllow: ["pdf"]` (the `pdf` tool is not in the `coding` profile). The wizard checks this and offers the exact fix. On Hermes, an explicit `platform_toolsets.api_server` must keep a file-capable toolset; the wizard adds only the missing `file` entry, and refuses global-disable or non-local-backend cases it cannot safely map. That same list is also where Hermes's own recall lives, so the wizard asks separately about taking `memory` and `session_search` out of it — in this step your yes only folds that removal into the one combined before/after it shows you, and nothing is written until you approve that too (see [Other endpoint gotchas](#other-endpoint-gotchas)). `--check-adapter --files` is the end-to-end proof for hand-built adapters.
- **Same reach as the gateway.** Expose the file server on the same rail you exposed the gateway on. If the gateway is public but the file server is tailnet-only, a standalone Apple Watch can still chat but silently can't send or open attachments.

Then, in the app: paste the file-lane URL and run **Test Connection**. The staged app test proves reachability, auth, and a byte-faithful `PUT` → `GET` → `DELETE` round-trip. It does not execute your agent's tools; use the wizard's OpenClaw/Hermes sentinel or `--check-adapter --files` to prove that final half.

**Security**

- **Never put the password on a command line** — `argv` is visible to `ps`. Pass it through an environment variable or a config file with `0600` permissions.
- **HTTPS with a certificate the device already trusts.** Self-signed is not an option here either, for the same reason it isn't for the gateway — see the three free routes to a real certificate under [Reaching your gateway](#reaching-your-gateway) above. The app's *Pinned cert fingerprint* field (your gateway → **File transfer** → Advanced) isn't that fix: it's an optional *tightening* for a certificate the device already trusts, narrowing an already-trusted connection to one exact key — it can't grant trust an untrusted certificate doesn't have.
- **Isolate lanes.** If you run more than one file lane on a host, give each its own credential, port, and service name — no shared state between them.

**Exposure**

Any HTTPS route works: **Tailscale Serve** (private tailnet), **Tailscale Funnel** (public), a **Cloudflare named tunnel** (public — use a routed hostname, not the ephemeral quick-tunnel URL), or your own reverse proxy / VPS. Usually the file server should ride the *same* rail you already used for the gateway.

**Example** (illustrative, not the blessed way) — serve OpenClaw's workspace with rclone, credential via the environment so it never reaches `argv`:

```
read -rs RCLONE_PASS && export RCLONE_PASS   # paste the app-generated password at the silent prompt
rclone serve webdav ~/.openclaw/workspace --addr 127.0.0.1:5006 --user conduck --dir-cache-time 1s
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
| `The certificate at … is signed by an issuer this machine doesn't trust` | A self-signed certificate, or one from a private CA. Your phone would reject it too, before Conduck ever sees it, and no fingerprint you paste into the app changes that. | Get a certificate the device trusts: Tailscale Serve (option 1 — automatic, nothing public), Let's Encrypt (free, and it issues IP-address certificates since January 2026, so no domain needed), or a reverse proxy like Caddy that mints and renews one for you. Then re-run the wizard. |
| `…failed: HTTP 401 — token rejected` | Wrong or stale bearer token — or an access layer in front wants its own login. (A 403 prints the same shape.) | Re-read the token from the gateway's config (OpenClaw: `gateway.auth.token` · Hermes: `API_SERVER_KEY`); check any proxy access policy. |
| `…failed: HTTP 404 — nothing at that path` | No `/v1/models` at that base address. | Give the server's *base* address — the script and the app append `/v1/…` themselves. (A pasted `…/v1` is normalized away automatically.) |
| `…failed: HTTP 3xx redirect — enter the final gateway base URL directly` | The address you gave redirects elsewhere. The wizard stops rather than forwarding your token to the `Location` target. | Use the address the redirect lands on as the gateway URL. |
| `…failed: HTTP 5xx — the server errored` | The gateway itself failed. | Read the gateway's own logs. |
| `…failed: answered HTTP 200, but the body isn't strict JSON` | Something replied OK — but not with JSON the strict parser accepts: a proxy's plaintext page, malformed JSON, or `NaN`/`Infinity`, which Conduck's own decoder refuses too. | Check what actually answers at that address; the reply contract lives at https://conduck.com/setup/adapter/v1/. |
| `…but its model list is EMPTY` | The endpoint is real, yet advertises no models — it can't answer a chat. | Pull/load a model (e.g. `ollama pull …`, load one in LM Studio), or set the model name your gateway expects. |
| `live round-trip failed (no complete answer within the time limit)` | The test chat request didn't finish within 300 s — the app's own limit. | Modest hardware and busy agents are slow — try again; check server load and any proxy read-timeout in front. |
| `live round-trip failed (the server closed the connection without sending a reply)` — or `(the reply stopped mid-body)` / `(the connection broke while the reply was being read)` | The request went out, but the answer never arrived whole. Each variant names the exact break, so a reply cut short reads differently from a server that answered nothing at all. | Usually a tunnel or proxy cutting the response — check the rail the gateway rides, then the gateway's own logs. |
| `live round-trip failed (HTTP …)` | The chat endpoint rejected the request. | A 404 here usually means the named model isn't available on the server; a 400 often means the server requires a `model` field — set one when the wizard asks. |
| `live round-trip failed (no usable "choices" array …)` — or `(a choice doesn't decode as …)` / `(the 2xx body isn't the strict JSON the app's decoder accepts)` / `(SSE framing …)` | The gateway answered OK, but not in the shape the app's decoder accepts — a tool-call turn with no string `content`, malformed JSON, or a streaming-only adapter. (An **empty** string is a valid reply; that alone never fails.) | The endpoint must honor `stream: false` and return the final answer as a plain string — see the adapter contract. |
| `This gateway has NO authentication, and this transport is publicly reachable.` | Keyless + public would put an unauthenticated, tool-capable agent on the open internet. The script refuses. | Keep it private (Tailscale), put a token on the gateway — or, expert-only, re-run with `--setup --allow-keyless-public`. |

### Other endpoint gotchas

Nothing fails, so no message prints — but the result quietly isn't what you wanted:

- **Hermes: pair the full-agent API server (default `8642`), never `hermes proxy` (`8645`).** Both chat, but the proxy is a bare relay to the model — none of Hermes's tools, skills, or recall — so an agent paired there can't open what you send it or write anything back. The wizard challenges a Hermes config whose `API_SERVER_PORT` is 8645; if you wired it by hand, re-check the port.
- **Hermes: the full-agent API server keeps a memory of its own until you narrow it.** `memory` and `session_search` in `platform_toolsets.api_server` let the gateway answer from things Conduck never sent it — and because Conduck resends the whole conversation every turn, you pay for that hidden context on top of the history you already sent. Nothing on the wire shows it: a gateway in that state passes every check here and in `--check-server`. Write no `api_server` list at all and Hermes falls back to a default bundle carrying both, so a fresh install starts this way. The wizard reports the scope before pairing, offers to remove exactly those entries when they are plainly listed, describes the by-hand edit when they are not (a bundle name, or YAML it can't read without guessing), and never blocks pairing over it. The agent's tools and skills are untouched either way — this is only Hermes's own recall, not the whole agent you give up on `8645` above. Test it yourself: tell it something in one conversation, then ask for it in a brand-new one.
- **vLLM can list a model whose chat fails** — a model served without a chat template answers `/v1/models` but errors on `/v1/chat/completions`.
- **In-app symptoms** (Test Connection inside Conduck, device-specific behavior like Apple Watch reach): the setup ladder at https://conduck.com/setup/#troubleshooting covers those.

### File-lane problems

- `The file-server service exists but is not active` / `did not answer with its saved credential` / `did not reject both missing and wrong credentials` — the local service behind the planned exposure is stopped, shadowed, or insecure. The wizard leaves it out rather than putting an unproved lane in the code. Repair/restart that exact `conduck-files-<gateway>` unit and re-run. If two pre-existing per-gateway units claim the same loopback port, only the exact unit that is active and passes the authenticated byte probe can be used; the connector intentionally does not rewrite or rebind either existing definition. Stop/repair/remove the stale duplicate, or assign it a different port, then re-run.
- `OpenClaw agent file lane failed: …` / `Hermes agent file lane failed: …` — WebDAV worked, but the full agent did not read the randomized input, finish a byte-identical output at the shared root, or name it in the reply. The lane is omitted. For OpenClaw, check the workspace/tool policy/`TOOLS.md`; for Hermes, check `terminal.cwd`, the API-server `file` toolset, and `.hermes.md` / `HERMES.md`. Re-run after fixing it.
- `file lane probe failed` / `the saved profile's file lane failed live verification` — the WebDAV server didn't complete the PUT → GET → DELETE round-trip: wrong credential, server not running, or its HTTPS front broken.
- **Transport is green, but the agent never sees uploaded files** — two known causes:
  1. the WebDAV root points at the wrong folder — it must be the agent's *working directory*; see the contract in "Set up the file lane by hand" above;
  2. the gateway's **tool policy denies the agent's file tools** — on OpenClaw, `tools.deny` containing `group:fs` (or `read`) makes every upload invisible to the agent; the typical symptom is the agent web-searching for the filename, claiming it can't access files, or the first attachment turn timing out into a "no response" placeholder while the agent flails. Re-run the wizard (its file-lane step checks the policy and offers the exact fix), or allow `read`/`write` yourself and restart the gateway.
  The current OpenClaw/Hermes setup sentinel and `--check-adapter --files` detect these end to end. The app's own File transfer test intentionally grades only transport, so a manually paired lane can still need the deeper check.
- **A PDF "answers" but with generic or wrong content** — the agent read the PDF's raw bytes instead of analyzing it natively. On OpenClaw the `pdf` tool is not in the `coding` profile (`tools.alsoAllow: ["pdf"]` enables it), and it wants the file's **absolute** workspace path — a bare filename fails its allowed-directory check even where `read` succeeds. The wizard's `TOOLS.md` block teaches the agent the absolute-path retry.
- **The agent says it saved/sent a file, but no download chip appears** — the agent delivered it as a channel-attachment directive (e.g. a `MEDIA:<path>` line), which the OpenAI-compatible endpoint strips; the reply reaches Conduck without the filename, so nothing can be offered for download. The rule (installed into `TOOLS.md` by the wizard, scoped to Conduck turns): write the file to the working-directory root and **name it in plain reply text**. Agent guidance loads at session start — test in a **new** conversation. If the file was really written, asking "what is the exact filename of the file you saved?" in the same conversation makes the chip appear on the answer.
- **Chat works everywhere, but attachments fail on a standalone Apple Watch** — the file lane rides a narrower rail than the gateway (say, a tailnet-only lane behind a public gateway). Expose both on the same rail; re-running the wizard reconciles the two.

## Pairing code

`conduck-setup:v1:<base64(JSON)>` — same content in the QR and the paste string. Full contract in **[PAYLOAD.md](PAYLOAD.md)**.

It is a reusable credential, not a one-time invite: it carries your gateway token (and the file-server credential when a file lane is set up), so whoever holds it keeps that access until you rotate those secrets — see **[SECURITY.md](SECURITY.md#the-pairing-code-is-a-secret)**.

## Reporting a problem

Security issues: see **[SECURITY.md](SECURITY.md)** (private vulnerability reporting — please don't open a public issue). Bugs and questions: open an issue.

## License

`conduck-connect` is © 2026 GigaDuck OÜ and licensed under the [Apache License 2.0](LICENSE). The one exception is the terminal QR renderer, which embeds the [Project Nayuki QR Code generator](https://www.nayuki.io/page/qr-code-generator-library) (Python), used unmodified under the MIT License with its license header preserved in-file; CI verifies that block against a pinned checksum and asserts it imports only the standard library. Both are recorded in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

The Conduck name isn't covered by the code license — see [TRADEMARKS.md](TRADEMARKS.md). Truthful references are always fine; just don't pass a modified fork off as the official `conduck-connect`.
