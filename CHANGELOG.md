# Changelog

Notable changes to `conduck-connect`. Format loosely follows [Keep a Changelog](https://keepachangelog.com/); versions track the script's own `VERSION`.

## [0.10.0] — the doctor grades contract 1.3, and agent-written files appear on time

Two independent things: the `--doctor` now grades adapters against the current contract revision (1.3, published at [conduck.com/setup/adapter/v1/](https://conduck.com/setup/adapter/v1/)) with machine-readable output you can wire into a build loop — and a file-server default that silently hid your agent's output files is fixed. No breaking changes — pairing codes, flags, and profiles from 0.9.0 keep working.

### Fixed

- **The file lane now shows agent-written files immediately.** The file server (rclone WebDAV) caches folder listings for 5 minutes by default. Files *uploaded* through it appeared instantly — but a file your **agent writes directly into the folder** (which is exactly how agents return files to you) stayed invisible to the server until that cache expired. Conduck checks for the file seconds after the agent's reply, found nothing, and the download chip silently never appeared — whether it worked was a coin flip on cache timing. New file servers are now created with `--dir-cache-time 1s`, so agent-written files appear within a second. **Existing setups:** the wizard only fixes servers it creates — for a file server you already have, add `--dir-cache-time 1s` to its rclone command (the LaunchAgent plist on macOS, the systemd unit on Linux) and restart it, or recreate the lane by re-running the wizard.
- **The `--deep` image probe no longer fails honest vision models on rendering grounds.** The probe's digits were drawn too close together; a real vision model read the code reliably only when the glyphs got breathing room. Spacing widened — verified 10/10 against a live vision engine.

### Changed

- **`--doctor` grades adapter-contract revision 1.3.** New checks, all named: a **historical-image continuity** probe (a photo turn with no reply followed by a text turn must still answer — the "poisoned conversation" shape), `"stream": true` must get a synchronous JSON reply (not SSE, not a hang), the advertised model `id` must actually select (and a bogus id must get `400` with code `model_not_found`), `Content-Type` is checked on both routes, and error bodies must carry a non-empty `type`. The `--deep` image probe is now **semantic**: it renders a 4-digit code as a PNG and requires the answer to contain those digits (proving the image was *seen*, not just tolerated) — declining honestly with `400` + code `image_unsupported` still passes; silently ignoring the image now fails.
- **Every doctor verdict line carries a stable `[CHECK_ID]`**, and the last line of every doctor run — including early exits and Ctrl-C — is a one-line machine summary (`CONDUCK_DOCTOR schema=1 ...`, unrun probes reported as `NOT_RUN`). Grep the id, or parse the summary from a build script; the human text above it can keep improving without breaking your tooling.

## [0.9.0] — the agent side of the file lane

The file lane's blind spot, closed at setup time: a green file-server test proves Conduck can *store* bytes — it has never proven the **agent** may read or return them. Three gateway-side traps (all hit live, all silent — every transport check stays green) now get checked and fixed where they live. No breaking changes — pairing codes, flags, and profiles from 0.8.0 keep working.

### Added

- **OpenClaw tool-policy check in the file-lane step (runs first, before any unit or exposure work).** The wizard reads `tools.{profile,allow,alsoAllow,deny}` from `openclaw.json` (comments and trailing commas fine) and grades it. A policy that denies the agent's file tools — most commonly `tools.deny` containing `group:fs`, which makes every uploaded file invisible to the agent — gets the exact per-key before→after fix, applied only with your yes through OpenClaw's own `config set`, then re-read from the file rather than trusted. The fix is the *minimum* relaxation: `group:fs` in the deny list is replaced by `edit` + `apply_patch`, so `read`/`write` come free while the mutating members stay denied; `exec` and everything else keep their current policy. It also enables the `pdf` tool (not part of the `coding` profile — without it PDFs get read as raw bytes and answered with plausible nonsense). Wildcard deny entries and an `allow`+`alsoAllow` conflict are flagged for you, never auto-rewritten. Declining the fix never silently drops the lane — the consequence is stated plainly and you choose.
- **Agent guidance installed into the workspace `TOOLS.md`** (marker-delimited, refreshed in place on re-runs, everything else in the file untouched; symlinks and malformed markers refused). It teaches the agent three things it otherwise learns by failing: attached files are already on disk (open them — never web-search for them); media/PDF tools want the file's **absolute** workspace path when a bare name is rejected; and to *return* a file, write it to the working-directory root and **name it in plain reply text** — attachment directives like `MEDIA:` are stripped by the chat endpoint and never reach the app. The whole block is scoped to Conduck turns (they carry a `[Conduck file transfer]` marker), so the same agent's messaging channels — where `MEDIA:` is exactly right — behave as before. Guidance loads at session start; the wizard says so, and new conversations pick it up.
- **README:** the file-lane contract gains the agent-tool-policy requirement, and troubleshooting gains the three matching symptoms (agent can't see uploaded files; PDF answered with generic content; "saved" file that never arrives).

## [0.8.0] — a doctor for adapters you built yourself

New `--doctor` mode: a read-only check-up for adapters built for Conduck, graded against the rules at [conduck.com/setup/adapter/v1/](https://conduck.com/setup/adapter/v1/). No breaking changes — pairing codes, flags, and profiles from 0.7.0 keep working.

### Added

- **`--doctor [url]`.** Run it on the machine where your adapter listens and it sends a handful of real requests, grades the answers strictly, and names the first thing to fix — changing nothing anywhere. It proves what the wizard's verify step can't: that your token check is actually **enforced** — a missing token and a wrong token must each get `401`, on `/v1/models` *and* `/v1/chat/completions` (an adapter that forgot its token check passes normal verification while sitting wide open). Also graded: the `/v1/models` answer shape (with at least one usable model `id`, inside the app's 15-second patience), and one real chat turn sent the way Conduck sends it — no `model` field, an unknown extra field, `"stream": false` — whose reply must be strict JSON with exactly one choice and plain-text content. Exit code `0` means every check passed; loop it from a build script while you iterate. Plain `http://` is accepted toward `127.0.0.1`/`localhost` only, so you can test before exposing; the token comes from `$CONDUCK_TOKEN` or a hidden prompt, never the command line, and the doctor's requests ignore proxies and curl config files so they go only to the address you gave it.
- **`--deep`.** With `--doctor`: one more chat turn with an image riding along, the shape Conduck sends when a photo is attached. Answering it works; declining it honestly with HTTP `400` and a clear error also passes.
- **Pointers where you'd look for them.** When verification of a custom (`--generic`) target fails — and once at the end of a successful custom pairing — the wizard prints the exact `--doctor` command for your adapter, so you can tell an adapter problem from a connection problem. Other gateway kinds see nothing new.

## [0.7.0] — press `?` when unsure, and quieter sharp edges

Every decision prompt now explains itself in plain words on request, and a cross-surface audit (checked against current Tailscale, Cloudflare, OpenClaw, Hermes, and rclone documentation) landed a batch of correctness fixes. No breaking changes — pairing codes, flags, and profiles from 0.6.0 keep working.

> **Same-day asset refresh (2026-07-14).** The `v0.7.0` script and checksum were re-published later the same day with three small fixes; `VERSION` stays `0.7.0` and nothing about pairing changes. If a checksum you saved from the morning no longer matches, this is why. What changed: the single-model pre-fill probe now sends the token you just entered (a server that correctly rejects anonymous requests used to silently kill the pre-fill); a machine without Tailscale gets a calm "only matters if you'd pick the Tailscale path" note instead of a refusing-to-guess warning; and the `--help` text now tells `--reuse-only` apart from `--show-qr` (advanced read-only walk of a live or hand-built setup vs. re-showing a saved code), with a pointer to `--reuse-only` from `--show-qr`'s no-saved-profile message.

### Added

- **`?` help at every decision prompt.** The exposure choice, the public/private question, and the file-lane mismatch menus all take `?` and compare the options in plain words — who can reach the address, what to install, who can see traffic, and what an Apple Watch needs. Purely additive: type the answer directly and nothing changed.
- **Profiles remember the file lane's own reach.** Fixes `--show-qr` refusing with a false "your setup changed" for a public gateway paired with a private file lane (or the reverse). Old profiles keep working.

### Changed

- **OpenClaw discovery handles modern configs.** Reads JSON5 configs (comments and trailing commas no longer break detection — with a heads-up that OpenClaw's own `config set` rewrites the file as plain JSON and drops comments); honors `gateway.auth.mode` (token *and* password); never embeds a `${ENV}` placeholder or secret reference as the token — the wizard asks for the real value instead, and `--show-qr` now resolves secrets the exact same way; finds the port wherever it lives (`OPENCLAW_GATEWAY_PORT` > `gateway.port` > default, validated).
- **TLS failures name the right side.** curl exit 60 — this machine refused the *server's* certificate — is no longer reported as "the HTTPS front rejected the connection" (exit 35 keeps that wording). The Troubleshooting row's explanation covers both directions now.
- **Tailscale refusals show Tailscale's own words.** A failed `serve`/`funnel` no longer blames missing sudo rights while hiding the real error; when your tailnet still needs Funnel or HTTPS enabled, you now see Tailscale's instructions.

### Fixed

- The macOS sleep warning no longer fires on every Mac (it also matched `disksleep`/`displaysleep`).
- Bracketed IPv6 gateway URLs pin correctly (portless `https://[::1]` defaults to `:443`; no SNI is sent for IP literals), and `--show-qr` accepts IPv6 profiles.
- The advanced rclone one-liner now names `RCLONE_PASS` — run bare, it served with an *empty* password.
- Piped or exhausted input can no longer mark a press-Enter step as done; failed file-lane probes clean up their test file; `--dry-run` stopped promising a verification it never runs; a model name over 100 characters gets a warning (the app stores only the first 100).

## [0.6.0] — failures that name themselves, and a README that decodes them

Better diagnosis end to end: the wizard now says *what* failed instead of making you guess, and this README gained a [Troubleshooting](README.md#troubleshooting) section keyed to the exact messages it prints. No breaking changes — pairing codes, flags, and file locations from 0.5.0 keep working.

### Added

- **A Troubleshooting section in this README** — every verification message, what it means, and the fix, plus the silent gotchas no check can catch (wrong Hermes port, wrong WebDAV root, a lane on a narrower rail than the gateway). The Conduck setup page links straight to it.
- **Empty-model-list warning.** A server whose `/v1/models` answers the canonical envelope with zero models now verifies green *with a warning* — the endpoint is real, but with no models it can't answer a chat (matches the app's own "connected — no models yet" verdict).
- **Hermes proxy-port guard.** A Hermes config whose `API_SERVER_PORT` is 8645 — the tool-less `hermes proxy`, not the full-agent API server — gets a warning and an explicit confirm. It chats fine, so nothing downstream would ever catch the silent loss of tools, skills, and memory. (`--dry-run` notes it; `--reuse-only` warns and continues.)
- **Parity + probe test suites in CI** (`scripts/test-url-normalization.sh`, `scripts/test-models-probe.sh`) — the URL normalizer is pinned to the app's fixtures, and the `/v1/models` classifier is exercised against a live local mock server, on every push and before every release.

### Changed

- **Verification failures now name the concrete cause.** The old catch-all `unreachable or rejected (URL? token? HTTPS front?)` is gone; the wizard distinguishes DNS failure, connection refused, timeout, TLS/certificate rejection, pinned-key mismatch, `401` token rejection, `404` wrong path, `5xx` server error, and an OK reply that isn't JSON — each with its own one-line fix.
- **The HTML diagnosis stopped asserting.** `/v1/models` answering a web page used to be reported flatly as "the chat endpoint is still OFF". A reverse-proxy login or access page produces the identical symptom, so the message is now hedged and kind-aware: on OpenClaw/Hermes it names the endpoint flag as the *likely* cause with the interstitial as the alternative; on a custom server it points at the proxy/base-address family instead — and it shows the HTTP status either way.

### Fixed

- **Pasting a base URL that ends in `/v1` no longer breaks every request.** Ollama/LiteLLM docs write the endpoint as `…/v1`, but the script and the app both append `/v1/…` themselves — so the pasted form probed `/v1/v1/models` and failed. User-entered gateway URLs are now normalized exactly the way the Conduck app normalizes them (strip one terminal `/v1`, `/v1/models`, or `/v1/chat/completions` — segment-wise, percent-encoding-aware, port and path prefix preserved, query/fragment dropped), and the wizard says so when it rewrites.
- The Cloudflare hostname prompt now tolerates a pasted full URL (the scheme is stripped instead of producing `https://https://…`).

## [0.5.0] — pair a second device in seconds, and verification that matches the app exactly

Two features and a stricter verify step. No breaking changes — pairing codes, flags, and file locations from 0.4.0 keep working.

### Added

- **`--show-qr` — re-show your pairing code without redoing setup.** A successful wizard run now saves a **non-secret profile** at `~/.config/conduck/profile-<gateway>.json` (routing facts only — never tokens or credentials; see `WHAT-IT-TOUCHES.md`). `--show-qr` re-emits the same QR from it with no setup questions and zero configuration changes — the fast path for pairing a second device. It validates the saved profile before trusting it (a hand-edited or corrupted file stops with a clear message instead of emitting a code the apps reject), re-derives secrets from their canonical homes (a profile whose token can't be read stops rather than emit a keyless code), and refuses with a secret-free diff if your live setup has drifted — including a profile that names a different machine on your tailnet. It never rewrites the profile: a transient verification failure can drop the file lane from one emission, never from your saved setup. It may still ask you to pick a profile, re-enter a custom gateway's token, or confirm a gateway-only code.
- **Built your own AI? The wizard now meets you halfway.** The gateway menu names "your own adapter" alongside Ollama/LiteLLM/vLLM, and a server that answers with the wrong response shape gets its own diagnosis pointing at the published adapter contract — https://conduck.com/setup/adapter/v1/ — instead of a generic failure.

### Changed — verification now matches the Conduck app exactly

The verify step previously accepted some responses the app would go on to reject, so a green pairing code could still produce a broken first connection. Every check now mirrors the app's own parser:

- `/v1/models` must answer `200` with the canonical envelope — a JSON **object** whose top-level `data` is an **array**. Valid JSON in any other shape gets the new wrong-envelope diagnosis (see the adapter contract above) instead of passing.
- The live pong must be a clean transfer (a response that times out mid-body no longer counts), HTTP `200`, and a **non-empty text** `content` — a `tool_calls` reply carrying `content: null`, an error body, or an empty answer no longer passes.
- `NaN`/`Infinity` anywhere in a response now fail: Python's parser accepts them by default, Apple's rejects them, and the wizard must never be more lenient than the app it green-lights for.
- The pong wait now matches the app's own request timeout (300 s, up from 180 s) — slow self-hosted agents no longer fail verification the app itself would have survived.

### Fixed

- JSON responses with leading whitespace were misclassified as non-JSON by a shell-level first-byte check; the real parser now decides.

## [0.4.0] — first stable release: exposure, certificate, and secret-handling fixes

A quality-control pass over the whole wizard found four paths that did not behave the way the script documented, plus one introduced while fixing them. **If you are on `0.4.0-rc.4` or earlier, upgrade** — the exposure bug below can leave your gateway publicly reachable after you asked for a private setup.

### Fixed — exposure

- **Choosing a private path could leave an old public Funnel serving your gateway.** When a port already carried a Tailscale mapping for the same gateway with the opposite verb, the wizard allocated a *different* port instead of switching that one, so an existing public Funnel kept running untouched. Worse, the run then recorded itself as private and skipped the keyless-public refusal. The mapping is now switched **in place** (confirmed in both directions), and `funnel → serve` drops the `AllowFunnel` flag explicitly, because `serve off` alone leaves a port public.
- **Stale public Funnels are now surfaced.** On a private choice, the wizard finds Funnels on *other* ports still pointing at the same gateway or file lane from an earlier setup and offers to switch them off. It never removes one without an explicit yes — see `WHAT-IT-TOUCHES.md`.
- **Rollback is genuinely fail-closed.** Undoing a file-lane exposure now proves the port is restored by re-reading Tailscale's status before claiming success; a rollback that cannot be confirmed keeps its undo record, prints the exact commands, and refuses to end the run quietly behind a green pairing code. Undo records are written only after you confirm a change, and replayed newest-first.

### Fixed — certificates

- **The certificate diagnosis never ran.** An exit code was read after the wrong statement, so every "couldn't resolve the host / connection refused / timed out" message was unreachable, and real network failures fell through to a confusing classification error.
- Broken-certificate detection now catches **not-yet-valid** certificates (a wrong clock), not just expired ones, and the **file-lane** certificate goes through the same safety gate as the gateway's before it is pinned.

### Fixed — secrets

- **The gateway token and file-lane credential no longer appear in the process list.** They were passed to `curl` as command-line arguments, which any user on the host can read via `ps`; they now ride a private stdin config. This matches the posture the script already applied to the rclone service.
- `~/.hermes/.env` is created `0600` when it does not exist (the generated key lands inside it), and an existing `API_SERVER_KEY` is reused rather than silently rotated out from under other clients.

### Fixed — prompts (found while reviewing the fixes above)

- **A typo could silently answer a safety question.** The retry warning on a no-default prompt was written to standard output, so it was captured as part of your answer. The new public-vs-private question would then read as "private" — the one value that skips the refusal to publish a keyless gateway. All prompt output now goes to standard error, and a closed input stream stops the run instead of looping forever.

### Changed

- Verification is stricter: `/v1/models` must answer **HTTP 200** with JSON (an authentication error that happens to be JSON is no longer green), the local health check accepts any answer below 500 (an auth-gated health route is still proof the gateway is up), and the test request body is built by a real JSON encoder.
- `--help` prints the whole header (it was cut off mid-sentence). Typos re-prompt rather than aborting. `--reuse-only` no longer exits when an optional step *would* have changed something — it skips it and says so. A missing systemd user session is detected **before** a credential is minted. Trailing slashes are stripped from URLs. A file lane on a non-default port is now read correctly from a macOS LaunchAgent.

### Verification

Parse + `shellcheck --severity=warning` clean, vendored QR encoder checksum verified, and the prompt, guard, and port-validation paths exercised on macOS `bash` 3.2. The companion app's pairing-payload suite is green.

> Unlike `0.4.0-rc.1`–`rc.4`, this release has **not yet been re-run end-to-end against the live OpenClaw / Hermes rigs**; the changes are covered by static analysis and targeted regression tests. It ships now because the exposure bug it fixes is worse than the risk it carries. If you hit anything, please open an issue.

## [0.4.0-rc.3] — pairing-hint accuracy fix

Same script behavior as rc.2 — still `VERSION=0.4.0`, same flags, same exposure paths, same `conduck-setup:v1` payload. A one-line accuracy fix to the closing in-app instruction; no functional or security change.

### Changed
- **Final in-app pairing hint reworded to be label-agnostic.** The closing "In Conduck:" instruction no longer names a single button label or its on-screen position — the app's setup-code entry point now lives in a top-level **Connect** section, and its label varies by state (a first-time user sees "I have a setup code"; a returning user sees "Scan or paste setup code"). The hint now points at "the setup-code option" and spells out scan-or-paste on iPhone/iPad vs paste on Mac, so it stays accurate as the app's UI evolves.

## [0.4.0-rc.2] — clarity pass

Same script behavior as rc.1 — still `VERSION=0.4.0`, same flags, same exposure paths, re-verified against the live rigs. This is a copy-and-accuracy refinement plus a friendlier dry-run summary; no functional or security change.

### Changed
- **Clarity + accuracy pass for non-engineer operators:** plainer wording throughout — a "could you open this from your phone on cellular?" rule of thumb for public-vs-private, clearer explanations of the gateway bearer token and self-signed certificate pinning, and warmer prompts. No behavior change.
- **`--dry-run` now prints a "Decisions gathered" summary** (gateway, reachability, transport, resolved URL, any self-signed pin) just before the ordered list of actions a real run would take.

### Docs
- README leads with a single **download → verify → run** Quick start command — checksum-gated (a tampered download is refused before anything runs), and the wizard still asks before every change. Read-first and `--dry-run` variants are kept alongside.

## [0.4.0-rc.1] — first public pre-release

First public, auditable release. The script itself is `VERSION=0.4.0`, live-rig verified against OpenClaw, Hermes, and a keyless OpenAI-compatible (`--generic`) gateway, across the exposure paths (Tailscale, Funnel, Cloudflare Tunnel, and own-HTTPS including self-signed pinning).

> The Conduck app is not yet public; this pre-release exists so the script can be read and audited ahead of launch.

### Script 0.4.0 — highlights
- **File-lane scope alignment:** when an existing agent file lane is reachable on a different scope than the gateway, the wizard offers to *align* it (promote private→public behind an explicit publication confirm, or demote public→private), *omit* it, or *include as-is*. File-lane exposure changes are fail-closed: rolled back if the lane is dropped.
- **`--dry-run`** is a baseline-and-plan — shows current state and the exact actions a real run would take, then stops. No secrets, no mutation, no QR.
- **`--reuse-only`** reuses existing config and refuses any mutation — safe to point at a live box.
- **Local terminal QR** via a vendored, stdlib-only Python encoder — no `qrencode`, no install.

[0.4.0-rc.3]: https://github.com/gigaduckai/conduck-connect/releases/tag/v0.4.0-rc.3
[0.4.0-rc.2]: https://github.com/gigaduckai/conduck-connect/releases/tag/v0.4.0-rc.2
[0.4.0-rc.1]: https://github.com/gigaduckai/conduck-connect/releases/tag/v0.4.0-rc.1
