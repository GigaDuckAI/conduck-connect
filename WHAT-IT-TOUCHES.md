# What conduck-connect touches

Every file, service, and network port the script may read or change — and how to undo each. The script always shows you a change before making it. `--dry-run` lists all of this for *your* host without changing anything, so start there:

```bash
bash conduck-connect.sh --dry-run
```

## Reads (never modified)

| Path / command | Why |
|---|---|
| `~/.openclaw/openclaw.json` | OpenClaw: discover the local port and read the runtime bearer token (`gateway.auth.token`). |
| `~/.hermes/.env` | Hermes: discover `API_SERVER_PORT` and read `API_SERVER_KEY`. |
| `tailscale serve status --json` | Read current exposure mappings. Fail-closed: if it can't be read, the script refuses to guess rather than mutate. |

## May change — always with your confirmation

| Change | Detail | How to undo |
|---|---|---|
| Enable OpenClaw chat endpoint | Sets `gateway.http.endpoints.chatCompletions.enabled = true` and restarts OpenClaw. | Set it back to `false` and restart. |
| Enable Hermes API server | Appends `API_SERVER_ENABLED` / `API_SERVER_HOST` / `API_SERVER_PORT` to `~/.hermes/.env`, then restarts `hermes-gateway`. An `API_SERVER_KEY` already present is reused, never rotated; a new one is generated only when none exists. If the file has to be created, it is created `0600` (the key lands inside it). | Remove the appended lines and restart. |
| Tailscale exposure | `tailscale serve` (private) or `tailscale funnel` (public) on an auto-selected HTTPS port. If that port already maps to the same gateway with the *other* verb, the mapping is switched in place — going private drops the public Funnel flag first, so the port really stops being public. | `tailscale serve --https=<port> off` / `tailscale funnel --https=<port> off`. The script also prints the exact command to restore any prior mapping it replaced. |
| Turn off a **stale public exposure it did not create** | When you choose a private path, the script looks for Tailscale **Funnels** (public) on *other* ports that still point at the same gateway or file-lane port from an earlier setup, tells you where they are, and offers to switch them off. It never does this without an explicit yes, and never touches a mapping for a different service. Declining leaves them running and says so. | Re-create it: `tailscale funnel --bg --https=<port> http://127.0.0.1:<local-port>`. Note this removal is treated as intentional, so the script's own rollback will not put it back for you. |
| File-server service (optional) | rclone WebDAV bound to `127.0.0.1:<port>`, as a service the script owns: Linux `~/.config/systemd/user/conduck-files-<id>.service`; macOS `~/Library/LaunchAgents/ai.gigaduck.conduck-files-<id>.plist`. | Linux: `systemctl --user disable --now conduck-files-<id>` then delete the unit. macOS: `launchctl unload <plist>` then delete it. |
| File-lane credential | A 32-hex secret written to a `0600` file under `~/.config/conduck/`. | Delete the file. |
| Setup profile (non-secret) | A successful wizard run writes `~/.config/conduck/profile-<gateway>.json` (`0600`): routing facts only — gateway kind, URLs, ports, transport — **never a token or credential**. `--show-qr` reads it and never rewrites it. | Delete the file. |

## Composes for you to run — it never runs these itself

- **Cloudflare Tunnel** config / DNS — the script prints the exact commands; you run them; it re-verifies.
- Anything needing `sudo` (Tailscale operator rights, `loginctl enable-linger`, `pmset`) — printed for you to review and run.

## When it cannot prove what it did

Every exposure change is re-checked against `tailscale serve status --json` afterwards. If that check cannot confirm the result — the command needed rights it did not have, or the status could not be read — the script says so plainly and prints the exact commands to fix it by hand. It never reports a change as done on faith, and it will not end a run silently while a file server it exposed may still be reachable.

## Network

Outbound requests go **only** to your own gateway and file server: a local health check, `/v1/models`, a live `/v1/chat/completions` pong, and (if the file lane is set up) a PUT→GET→DELETE probe. Nothing else leaves the host.

## Prerequisites it will not install

`bash`, `curl`, `python3`, `openssl` (required); `tailscale`, `cloudflared`, `rclone` (only for the path you pick). A missing prerequisite → the script explains and exits cleanly; re-run to resume.
