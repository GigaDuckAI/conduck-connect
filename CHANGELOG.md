# Changelog

Notable changes to `conduck-connect`. Format loosely follows [Keep a Changelog](https://keepachangelog.com/); versions track the script's own `VERSION`.

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

[0.4.0-rc.2]: https://github.com/gigaduckai/conduck-connect/releases/tag/v0.4.0-rc.2
[0.4.0-rc.1]: https://github.com/gigaduckai/conduck-connect/releases/tag/v0.4.0-rc.1
