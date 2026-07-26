# tests/ — connector regression harness

Loopback-only, stdlib-only fixtures and drivers for developing `conduck-connect.sh`.
No network, no real gateway, nothing installed — except where a file says otherwise.

| File | What it is |
|---|---|
| `../scripts/build-release.sh --check` | Proves the modular source assembles byte-for-byte into the checked-in single-file release artifact. |
| `../scripts/test-response-fixtures.sh` | Runs `app_chat_body_eval` from the generated artifact across every case in the vendored Apple-authoritative response corpus. |
| `fixtures/converse-response-v1.json` | Byte-identical snapshot of the public Apple corpus named by its embedded canonical URL/revision metadata. CI consumes it locally; no network fetch or Android authority is involved. |
| `run-checks-suite.sh` | Adapter, server, menu, and direct-command regression suite. It proves strict adapter checks, current Apple response-decoder behavior, interactive PASS→setup handoff, the `0` success / `1` runtime-or-check-failure / `2` usage-error split, hardened direct diagnostic transport, exact failed `[CHECK_ID]` sets, and both machine-summary grammars. |
| `run-file-lane-readiness-suite.sh` | Focused setup-time file-lane regressions: structural systemd/plist reuse, stable collision-free per-gateway ports, control-safe credentials/paths, lossless fail-closed Hermes YAML, authenticated loopback service gating, app-parity reply discovery, reply-boundary/timeout handling, post-delete file+directory proof, and exact-name EXIT cleanup. Its loopback adapter fixtures prove connector control flow and false-green rejection for the OpenClaw/Hermes prompt shapes; they are not evidence about a real OpenClaw or Hermes runtime. It is also run by the full checks suite. |
| `run-check-adapter-rclone-integration.sh` | Non-hermetic companion: proves the `--files` freshness check against a REAL `rclone serve webdav` (the one place the actual rclone dir-cache bug reproduces end to end). Requires `rclone` on PATH — a missing rclone is a hard exit 2, never a silent skip. |
| `fixture-adapter.py` | Known-good / deliberately-broken mock adapter the suite drives both checks against. |
| `fixture-webdav.py` | Minimal WebDAV-ish file server for the `--files` cases. Not a production server. |
| `fixture-canary.py` | Contract-conformant adapter that can hold a response silently for a per-turn delay, then reply deterministically — for measuring whether an exposure rail (reverse proxy / tunnel) kills long silent HTTP responses, the shape of a real agent turn. |
| `pty-run.py` | Runs one command inside a real PTY and feeds it a fixed input sequence: `pty-run.py <timeout-seconds> <input> <command> [args...]`. **A hard dependency of `run-checks-suite.sh`**, not an optional helper — the script offers the PASS→setup handoff only to a genuine interactive terminal, so those cases cannot be driven by a pipe. A timeout kills the child and appends `PTY TIMEOUT` to the captured output rather than hanging the suite. |

Run the suite from the repo root:

```bash
bash tests/run-checks-suite.sh
```
