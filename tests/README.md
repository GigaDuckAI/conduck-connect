# tests/ — doctor regression harness

Loopback-only, stdlib-only fixtures and drivers for developing `conduck-connect.sh`.
No network, no real gateway, nothing installed — except where a file says otherwise.

| File | What it is |
|---|---|
| `run-doctor-suite.sh` | The doctor's regression suite: for every doctor check, a known-good fixture (must stay green) plus at least one deliberately-broken fixture mode proving the check fails for its intended reason. Asserts exit codes, the exact set of failed `[CHECK_ID]`s, and the full `schema=2` machine-summary grammar. |
| `run-doctor-rclone-integration.sh` | Non-hermetic companion: proves the `--files` freshness check against a REAL `rclone serve webdav` (the one place the actual rclone dir-cache bug reproduces end to end). Requires `rclone` on PATH — a missing rclone is a hard exit 2, never a silent skip. |
| `fixture-adapter.py` | Known-good / deliberately-broken mock adapter the suite drives the doctor against. |
| `fixture-webdav.py` | Minimal WebDAV-ish file server for the `--files` cases. Not a production server. |
| `fixture-canary.py` | Doctor-conformant adapter that can hold a response silently for a per-turn delay, then reply deterministically — for measuring whether an exposure rail (reverse proxy / tunnel) kills long silent HTTP responses, the shape of a real agent turn. |

Run the suite from the repo root:

```bash
bash tests/run-doctor-suite.sh
```
