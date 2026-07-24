# What conduck-connect touches

Every file, service, and network port the script may read or change — and how to undo each. The script always shows you a change before making it. `--setup --dry-run` lists all of this for *your* host without changing anything, so start there:

```bash
bash conduck-connect.sh --setup --dry-run
```

## Reads

Everything here is read to discover the setup you already have. **Your gateway's own config file is read first and may be changed later in the same run** — always with your explicit yes, and only as the next table describes. The "Also changed?" column says which, so nothing here reads as a promise it isn't.

| Path / command | Why | Also changed? |
|---|---|---|
| `${OPENCLAW_CONFIG_PATH:-$HOME/.openclaw/openclaw.json}` | OpenClaw: discover the local port, read the runtime bearer token (`gateway.auth.token`), and — in the file-lane step — read the tool policy (`tools.profile/allow/alsoAllow/deny`) to grade it. | **Yes, with your yes** — the chat-endpoint flag, and the tool policy in the file-lane step. Both rows below. |
| `${OPENCLAW_DIR:-$HOME/openclaw}/.env` | OpenClaw: fallback source for the local port and bearer token when they are not literal values in the main config. | No. |
| `${OPENCLAW_DIR:-$HOME/openclaw}/docker-compose.yml` or `compose.yaml` | Existence check only: decides whether restart/start guidance should use the local Compose project. | No. |
| `~/.hermes/.env` | Hermes: discover `API_SERVER_PORT` and read `API_SERVER_KEY`. | **Yes, with your yes** — three `API_SERVER_*` keys appended. Row below. |
| `tailscale serve status --json` | Read current exposure mappings. Fail-closed: if it can't be read, the script refuses to guess rather than mutate. | No — but the mappings it describes are changed via `tailscale` itself (rows below). |
| `${XDG_CONFIG_HOME:-$HOME/.config}/conduck/` | Reuse state from earlier runs: the saved non-secret profiles (`--show-code`, drift check) and an existing file-lane credential file (reused, never rotated). | **Yes** — the script owns this directory and writes its own state here (rows below). |
| Existing `conduck-files-*`, `conduck-files`, or `conduck-fileserver` service units | The systemd user units / LaunchAgents plists an earlier run created: re-read to recover the file lane's port and credential-file path for reuse, including names used by older releases. | **Yes**, when you set up or repair a file lane — these are units the script itself created. |
| The selected OpenClaw workspace's `TOOLS.md` | Before adding or refreshing its marker-delimited Conduck guidance, the script checks the existing file, its markers, and whether it is a symlink. | **Yes, with your yes** — only the Conduck marker block. |
| The configured shared folder and its named check artifacts | `--check-adapter --files` reads the exact files it and the tested agent create to prove write-through, freshness, byte identity, and cleanup. | **Yes, for this explicitly mutating check** — exact per-run names only, then cleanup. |
| Connector-created files under `${TMPDIR:-/tmp}` | Local staging for response bodies/headers, certificate conversion, generated probes, and file-check sidecars. | **Yes, transiently** — created inside a private per-run directory and removed on exit. |
| `cloudflared tunnel list` | Cloudflare path: discover existing tunnels so the printed instructions reference the right one. | No — Cloudflare changes are printed for you to run. |
| `http://127.0.0.1:<port>/v1/models` | One loopback probe of your own server during setup, to pre-fill the model name when it advertises exactly one. | Not a file. |

The table covers persistent user configuration/state plus the transient
connector-owned categories. Every curl invocation puts `-q` first, so curl
configuration files (and files they might include) are not read. No persistent
file is changed unless it appears in the next table.

## May change — always with your confirmation

| Change | Detail | How to undo |
|---|---|---|
| Enable OpenClaw chat endpoint | Sets `gateway.http.endpoints.chatCompletions.enabled = true` and restarts OpenClaw. | Set it back to `false` and restart. |
| Fix OpenClaw tool policy (file lane only) | With your yes, updates `tools.deny` / `tools.allow` / `tools.alsoAllow` via OpenClaw's own `config set` so the agent's `read`/`write` file tools and the `pdf` tool are allowed, then restarts OpenClaw. The exact per-key before→after is shown first; wildcard entries and conflicting configs are flagged, never rewritten. | Restore the previous values shown in the before→after (they stay on your screen), or from OpenClaw's own config backup, and restart. |
| Agent-guidance block in `TOOLS.md` (file lane only, OpenClaw) | Appends (or refreshes in place) one marker-delimited block — `<!-- conduck-connect:begin -->` … `<!-- conduck-connect:end -->` — in the agent workspace's `TOOLS.md`, teaching the agent how Conduck attachments work. Everything outside the markers is untouched; a symlinked or marker-mangled file is refused. | Delete the block between (and including) the two markers. |
| Enable Hermes API server | Appends `API_SERVER_ENABLED` / `API_SERVER_HOST` / `API_SERVER_PORT` to `~/.hermes/.env`, then restarts `hermes-gateway`. An `API_SERVER_KEY` already present is reused, never rotated; a new one is generated only when none exists. If the file has to be created, it is created `0600` (the key lands inside it). | Remove the appended lines and restart. |
| Tailscale exposure | `tailscale serve` (private) or `tailscale funnel` (public) on an auto-selected HTTPS port. If that port already maps to the same gateway with the *other* verb, the mapping is switched in place — going private drops the public Funnel flag first, so the port really stops being public. | `tailscale serve --https=<port> off` / `tailscale funnel --https=<port> off`. The script also prints the exact command to restore any prior mapping it replaced. |
| Turn off a **stale public exposure it did not create** | When you choose a private path, the script looks for Tailscale **Funnels** (public) on *other* ports that still point at the same gateway or file-lane port from an earlier setup, tells you where they are, and offers to switch them off. It never does this without an explicit yes, and never touches a mapping for a different service. Declining leaves them running and says so. | Re-create it: `tailscale funnel --bg --https=<port> http://127.0.0.1:<local-port>`. Note this removal is treated as intentional, so the script's own rollback will not put it back for you. |
| File-server service (optional) | rclone WebDAV bound to `127.0.0.1:<port>`, as a service the script owns: Linux `~/.config/systemd/user/conduck-files-<id>.service`; macOS `~/Library/LaunchAgents/ai.gigaduck.conduck-files-<id>.plist`. On macOS that plist also carries the credential — see the credential rows below. | Linux: `systemctl --user disable --now conduck-files-<id>` then delete the unit. macOS: `launchctl unload <plist>` then delete it. Then remove the credential per your platform's row below. |
| Enable user-service linger (systemd/Linux, file lane only) | `sudo loginctl enable-linger <user>` so the file server keeps running after you log out. The one `sudo` step the script runs itself: it shows the exact command and asks `y/N` first — on yes it runs it, on no it prints the command as a tip. | `sudo loginctl disable-linger <user>`. |
| File-lane credential — **Linux** | A 32-hex secret written to two `0600` files under `${XDG_CONFIG_HOME:-$HOME/.config}/conduck/`: `fileserver-<id>.cred` and `fileserver-<id>.env` (holding `RCLONE_PASS=…`). The systemd unit loads the secret via `EnvironmentFile=`, so the unit file itself contains no credential. | Delete both files. |
| File-lane credential — **macOS** | The same `0600` `${XDG_CONFIG_HOME:-$HOME/.config}/conduck/fileserver-<id>.cred` — **plus a second copy, in cleartext, inside the LaunchAgent plist itself**: `~/Library/LaunchAgents/ai.gigaduck.conduck-files-<id>.plist`, under `EnvironmentVariables` → `RCLONE_PASS`. launchd has no `EnvironmentFile=` equivalent, so the value has to live in the plist. The plist is written `0600`. | **Both** locations, or the password survives: delete the `.cred` file **and** `launchctl unload` the plist and delete it. Deleting only the `.cred` file leaves the credential readable in the plist. |
| Setup profile (non-secret) | A successful setup writes `${XDG_CONFIG_HOME:-$HOME/.config}/conduck/profile-<gateway>.json` (`0600`): routing facts only — gateway kind, URLs, ports, transport — **never a token or credential**. `--show-code` reads it and never rewrites it. | Delete the file. |

## Composes for you to run — it never runs these itself

- **Cloudflare Tunnel** config / DNS — the script prints the exact commands; you run them; it re-verifies.
- Anything needing `sudo` **except** the linger step above (Tailscale operator rights, `pmset`) — printed for you to review and run.

## When it cannot prove what it did

Every exposure change is re-checked against `tailscale serve status --json` afterwards. If that check cannot confirm the result — the command needed rights it did not have, or the status could not be read — the script says so plainly and prints the exact commands to fix it by hand. It never reports a change as done on faith, and it will not end a run silently while a file server it exposed may still be reachable.

## Network

The script's own HTTP probes go **only** to the gateway and file server you
name. Every curl call ignores curl configuration files; the two diagnostic
commands also refuse proxy environment variables. Gateway model/chat requests
send `Accept: application/json`.

- Normal setup and `--show-code` verification may send a local health check,
  `GET /v1/models`, and a real `POST /v1/chat/completions` pong. If a file lane
  is configured, either path also writes, reads, and removes one small
  `conduck-connect-probe-*` file with a PUT→GET→DELETE round trip. `--show-code`
  never changes configuration or rewrites its saved profile.
- `--check-server` sends `GET /v1/models` plus several real chat
  turns: model-less and advertised-model probes, a historical-image turn, and
  an informational current-image probe. It changes no host configuration, but
  these requests can consume model compute, appear in server logs, or enter
  server-side history. It ignores curl config files and all proxies so the
  credential goes directly to the address you supplied. It also refuses HTTP
  redirects rather than forwarding that credential to a `Location` target;
  use the final server URL directly.
- `--check-adapter` additionally sends missing-token and wrong-token
  requests on both gateway routes, strict model-selection and stream probes,
  and (with `--deep`) a generated image. `--files` also exercises WebDAV
  auth/PUT/GET/Range/MKCOL/DELETE and asks the selected agent to copy one
  sentinel file, writing and removing these named artifacts in the configured
  shared folder (`<run>` is a random per-run tag):

  | Artifact | Written by |
  |---|---|
  | `conduck-check-<run>/` and the input file inside it (flat `conduck-check-<run>-…` if the server refuses `MKCOL`) | the script |
  | `output-<run>.txt`, at the folder root | **the agent** — it is the file the agent is asked to produce, so it carries no `conduck-check-` prefix |

  Targets are registered before creation and removed by exact name, never by
  pattern. Cleanup that cannot be *proven* is reported with the exact names to
  remove by hand — the check never assumes it tidied up.

There is no GigaDuck telemetry or GigaDuck server. Approved Tailscale or
Cloudflare commands may contact those providers' control planes as part of the
exposure path the user selected.

## Prerequisites it will not install

`bash`, `curl`, `python3`, `openssl` (required); `tailscale`, `cloudflared`, `rclone` (only for the path you pick). A missing prerequisite → the script explains and exits cleanly; re-run to resume.
