# tests/ — connector regression harness

Loopback-only, stdlib-only fixtures and drivers for developing `conduck-connect.sh`.
No network, no real gateway, nothing installed — except where a file says otherwise.

| File | What it is |
|---|---|
| `../scripts/build-release.sh --check` | Proves the modular source assembles byte-for-byte into the checked-in single-file release artifact. |
| `../scripts/test-response-fixtures.sh` | Runs `app_chat_body_eval` from the generated artifact across every case in the vendored Apple-authoritative response corpus. |
| `fixtures/converse-response-v1.json` | Byte-identical snapshot of the public Apple corpus named by its embedded canonical URL/revision metadata. CI consumes it locally; no network fetch or Android authority is involved. |
| `run-checks-suite.sh` | Adapter, server, menu, and direct-command regression suite. It proves strict adapter checks, current Apple response-decoder behavior, interactive PASS→setup handoff, the `0` success / `1` runtime-or-check-failure / `2` usage-error split, hardened direct diagnostic transport, exact failed `[CHECK_ID]` sets, and both machine-summary grammars. It also carries the security-review guards, each written as a rule about the released artifact rather than about one call site, and each verified to fail against a pre-fix build: the saved pairing profile carries no secret (`write_profile` is driven with sentinel values in `GW_TOKEN`/`FS_CRED` and neither may appear anywhere under the state directory, with a control run against a deliberately leaking copy of the same function, so a guard that stopped biting fails the suite instead of passing quietly); gateway-supplied text cannot forge a `[CHECK_ID]` transcript line or emit ANSI; both URL entry points refuse `user:password@`; dotenv-sourced gateway ports are validated before they reach a shell command; the `--files` transport probes live in one `mktemp -d` rather than sibling names concatenated onto a `mktemp` file; the "I already run my own HTTPS" path is a trust GATE — the shipped `classify_own_https` is driven through its accept arm and every refusal arm, and must stop, offer no accept-anyway override, and name the three free routes to a trusted certificate, while the artifact itself is asserted free of every pinning symbol and still carrying both certificate-diagnosis helpers; a permission change to a config the connector did not create stays behind the announce-then-confirm gate, and its two non-success arms — declined, and chmod-failed-after-yes — still warn that the credential is exposed rather than going quiet; `$STATE_DIR` has exactly one creator (`ensure_state_dir`), which makes a fresh one 0700 in silence and reports an already-open one once, with the exact `chmod 700`, instead of leaving an upgraded box's credential listing world-readable and unmentioned; and every curl to a literal loopback URL carries `--noproxy`. |
| `run-file-lane-readiness-suite.sh` | Focused setup-time file-lane regressions: structural systemd/plist reuse, stable collision-free per-gateway ports, control-safe credentials/paths, lossless fail-closed Hermes YAML, authenticated loopback service gating, app-parity reply discovery, reply-boundary/timeout handling, post-delete file+directory proof, and exact-name EXIT cleanup. Its loopback adapter fixtures prove connector control flow and false-green rejection for the OpenClaw/Hermes prompt shapes; they are not evidence about a real OpenClaw or Hermes runtime. It is also run by the full checks suite. |
| `run-check-adapter-rclone-integration.sh` | Non-hermetic companion: proves the `--files` freshness check against a REAL `rclone serve webdav` (the one place the actual rclone dir-cache bug reproduces end to end). Requires `rclone` on PATH — a missing rclone is a hard exit 2, never a silent skip. |
| `fixture-adapter.py` | Known-good / deliberately-broken mock adapter the suite drives both checks against. |
| `fixture-webdav.py` | Minimal WebDAV-ish file server for the `--files` cases. Not a production server. |
| `fixture-canary.py` | Contract-conformant adapter that can hold a response silently for a per-turn delay, then reply deterministically — for measuring whether an exposure rail (reverse proxy / tunnel) kills long silent HTTP responses, the shape of a real agent turn. |
| `pty-run.py` | Runs one command inside a real PTY and feeds it a fixed input sequence: `pty-run.py <timeout-seconds> <input> <command> [args...]`. **A hard dependency of `run-checks-suite.sh`**, not an optional helper — the script offers the PASS→setup handoff only to a genuine interactive terminal, so those cases cannot be driven by a pipe. A timeout kills the child and appends `PTY TIMEOUT` to the captured output rather than hanging the suite. |

**Every HTTP fixture binds without reverse-resolving.** `http.server`'s
`server_bind()` calls `socket.getfqdn()` on the bind address, and each fixture
prints its `READY <port>` line only after that returns. On a host with no
reverse zone for `127.0.0.1` the lookup blocks until the resolver gives up —
around 20 seconds on GitHub's macOS runners — so the suite stops waiting for
READY while the fixture is still alive and silent, and every case that needs one
fails for a reason nothing prints. Each fixture therefore subclasses its server
and overrides `server_bind` to skip the lookup; `server_name` is read only by
the CGI handlers, which none of these use. The
`fixtures-do-not-reverse-resolve-their-bind` case enforces this across the tree.

Run the suite from the repo root:

```bash
bash tests/run-checks-suite.sh
```
