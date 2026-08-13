# Security Policy

The canonical vulnerability disclosure policy — including the full scope rules and safe-harbor terms — is published at **<https://conduck.com/security/>**. A machine-readable summary lives at [`/.well-known/security.txt`](https://conduck.com/.well-known/security.txt). This file is the short version for people arriving via GitHub.

`conduck-connect` is a setup script you run on your own gateway host, often over SSH with root-capable rights. It is designed to be **read before it is run** — that is why it ships as a plain, unminified shell script.

## Reporting a vulnerability

Please report security issues **privately**, not as a public issue:

- **GitHub private vulnerability reporting** — the repository's **Security** tab → **Report a vulnerability**.
- Or email **security@gigaduck.ai**.

Please include the script version (`grep '^VERSION=' conduck-connect.sh`), your OS and shell, and a reproduction.

## What to expect

- **Acknowledgment within 3 business days** of your report.
- **An initial assessment within 10 business days**, with updates as the fix progresses.
- Confirmed vulnerabilities are addressed without delay. For critical issues, 90 days is the outer bound, not the plan — most fixes ship much faster.
- Coordinated disclosure: please hold public disclosure until a fix has shipped or 90 days have passed since your report, whichever comes first.
- Once a fix is available, an advisory is published; with your permission you are credited for the discovery. There is no monetary bug bounty at this time.

## Supported versions

The latest tagged release is supported. Older tags are not patched — re-download the current release.

| Version | Supported |
|---|---|
| latest release tag | ✅ |
| older tag / `main` snapshot | ❌ |

## What the script may do

- **Reads** your gateway's own config to discover ports and the existing token (OpenClaw `~/.openclaw/openclaw.json`; Hermes `~/.hermes/.env`).
- **Asks for your gateway token, optionally, in one place that is not setup.** Changing a saved setup's model (`--edit`) checks the name against the server's own list of models, and most servers will not return that list to a request with no credential. The script stores no gateway token, so it asks — after a question that says what the token is for and where it goes, never as a prompt that appears unbidden. What you paste is hidden, sent to the saved gateway address in one `GET /v1/models`, held only for that request, and written to no file. Answering no, or pressing Enter at the prompt, skips the check; the model is saved either way.
- **Enables** the gateway's OpenAI-compatible chat endpoint if it is off — with your confirmation.
- **Edits** your gateway's own config, and only the exact change you approve first: in Hermes's `~/.hermes/config.yaml`, the shared-folder path and the `file` toolset so the agent can reach it, and — as a separate question — taking `memory` or `session_search` out of the API-server scope, because a gateway that keeps its own recall replays history the app already sends every turn. OpenClaw's file-tool policy goes through its own `openclaw config set`. Anything it cannot parse confidently it describes for you to change by hand rather than rewriting, and it refuses to edit through a symlink.
- **Installs agent guidance** — with your confirmation, one marker-delimited block in your agent's own context file (`TOOLS.md` on OpenClaw, `.hermes.md` / `HERMES.md` on Hermes), leaving everything outside the markers alone. Four things about that block:
  - **It is instructions, not permissions.** It grants the agent no tool it does not already hold, and installs no software — it is text pointing the agent at tools your own gateway configuration decides it has. What it says: open the exact uploaded path instead of searching for it, and — for a returned file — create the folder that turn's own message names, write the file inside it, and finish before replying. The block names no destination itself; the app states one folder per reply, creates nothing, and reads only that folder. Creating it is the agent's own act, with the agent's own permissions, in the directory your gateway already works in: nothing here widens where the agent may write.
  - **Each gateway's block covers how that agent reads a PDF, and neither claims more than it does.** OpenClaw's carries one path hint — a media or PDF tool that rejects the saved path should be retried with the file's absolute workspace path — and nothing beyond it. The script never switches OpenClaw's `pdf` tool on, never grades it, and never mentions it in the tool-policy check: that tool sits outside the `coding` profile, and it also needs `agents.defaults.pdfModel` pointing at a model your gateway can actually resolve. Native PDF reading on OpenClaw stays entirely your own call; the README's file-lane troubleshooting lists what it takes. Hermes has no PDF reader in `read_file` at all, so its block says to take the text with `pdftotext` through Hermes's terminal tool, to say so plainly when that is not possible, and never to answer from a filename.
  - **Hermes's block treats attachment contents as untrusted.** Instructions found *inside* an attachment are not to be followed unless your own chat message asks the agent to follow them.
  - **The two things the PDF rule depends on are checked and reported, not assumed.** A `pdftotext` missing from the script's own shell, and a `platform_toolsets.api_server` list it can read that carries no terminal tool, each get a note naming the fix. Neither is fetched nor edited for you, and neither stops the block being offered.
- **Creates** exposure mappings using tools you already run (`tailscale serve` / `funnel`), and optionally a file-server service it owns (`conduck-files-<id>`, rclone WebDAV bound to `127.0.0.1`) together with the shared folder that service serves — the folder your attachments and the agent's output files pass through. A folder it creates is `0700`; one that already exists keeps its own permissions, and it tells you when those let other accounts read it.
- **Stores** the file-lane credential in `0600` files under `~/.config/conduck/` (a `0700` directory) — and, on **macOS only**, a second cleartext copy inside the `0600` LaunchAgent plist it creates, because launchd has no environment-file equivalent. Removing the credential therefore takes a different step per platform; [WHAT-IT-TOUCHES.md](WHAT-IT-TOUCHES.md) lists every location and the exact undo.
- **Removes**, when you ask it to. `--forget <id>` stops and deletes the file server it created for one gateway, deletes **both** copies of the file-lane password — the `.cred` and, on macOS, the one inside the LaunchAgent file — and closes **Tailscale** Serve and Funnel routes in front of it. Only Tailscale ones, and only the ones it can prove are this setup's against what Tailscale reports it is serving right now: a route it cannot prove is named and left alone, and a Cloudflare tunnel or a reverse proxy of your own was never opened by this script, so it is never closed for you. That proof is an address match, so a route you opened by hand at this setup's saved address is indistinguishable from one the script opened and would be closed too. All of that, and everything it will not touch — your shared folder, your gateway's configuration, the gateway itself — is on screen before it asks. Removal is confirmed by typing the setup's id, not by pressing Enter, and anything it cannot prove it removed is reported by exact name with the commands to finish by hand. `--list` shows what is still here, including a file server left running with no setup behind it.
- **Sends** its own HTTP probes only to your configured gateway and file lane,
  to verify they work. `--show-code` changes no configuration, but
  still performs live verification; with a configured file lane that includes
  one small PUT→GET→DELETE probe. `--check-server` and `--check-adapter` do not
  follow HTTP redirects or forward credentials to `Location` targets.

See [WHAT-IT-TOUCHES.md](WHAT-IT-TOUCHES.md) for the exhaustive list and how to undo each change.

## What the script never does

- **No GigaDuck telemetry, ever. There is no GigaDuck server.** There is no collection endpoint anywhere in the file, which is deliberately a claim about the script rather than about us: you can settle it by reading instead of by trusting. The script's own HTTP probes target only the gateway and file lane you configured. Two carve-outs, both stated because they are real: approved Tailscale or Cloudflare commands — run by the script with your consent, or printed for you to run — contact those providers' control planes as part of exposing your gateway, or closing that exposure again on `--forget`; and `tailscale status --json` / `tailscale serve status --json` are read early, before and regardless of which exposure path you choose, so the script can label the options and refuse to guess at port state. Those two are local reads from the Tailscale daemon on your own machine, not network calls to Tailscale.
- **Never installs** your gateway, Tailscale, cloudflared, or rclone — it works with what you already have, and exits cleanly with instructions if a prerequisite is missing.
- **Never elevates silently.** Every command that needs higher rights is shown in full first — prefixed with `sudo` or `doas`, whichever this machine has, and bare when you are already root or have neither. Most it prints for you to review and run yourself (Tailscale operator rights, `pmset`). The one it can run for you — `loginctl enable-linger`, so your file server survives logout — runs only after you approve the exact command at a `y/N` prompt; decline and it prints the command as a tip instead.
- **Never changes a config it didn't create** without showing you the exact change first — permissions included, not just contents.
- **Never makes your gateway public** without telling you, in plain words, that it will — and refuses to publish a **keyless** gateway on a public transport unless you explicitly run `--setup --allow-keyless-public`. The flag is a setup modifier and is rejected on its own or with any other action, so it can never be passed by reflex.

## Verifying your download

The script is delivered over HTTPS straight from GitHub Releases as plain,
unminified text rather than an opaque installer. Its modular source is
assembled deterministically, and CI rejects any byte difference between that
source build and the checked-in artifact. It is available to **inspect** before
you run it (`less conduck-connect.sh`); the release workflow tests and
checksums the exact artifact users download.

Every release also publishes `conduck-connect.sh.sha256` for an optional integrity check:

```bash
shasum -a 256 -c conduck-connect.sh.sha256        # Linux: sha256sum -c conduck-connect.sh.sha256
```

This confirms the bytes arrived intact, but the checksum rides the same release
channel as the script, so it catches a **corrupted** download, not a **swapped
or tampered** release. Inspect the script when that risk matters. Release tags
are protected and are not moved after publication, and the release workflow
refuses to overwrite an existing release's assets—a changed byte always means a
new version and tag.

## Why not certificate pinning?

It gets asked often enough to answer here. The wizard requires your gateway to present a certificate your devices **already trust**, and refuses a self-signed one, a private CA, an expired one or a wrong hostname. It does not offer to pin a fingerprint instead. That is a standing decision, not an omission:

- **A pin can only narrow trust — it cannot grant it.** On Apple platforms App Transport Security evaluates the chain before Conduck is consulted at all, so an untrusted chain is rejected at a layer no fingerprint in the app ever reaches. This is measured, not assumed: a self-signed certificate fails with the same OS-level error whether or not a pin is configured. A wizard that accepted a self-signed certificate and pinned it would mint a setup code that cannot work on a phone — and the user would find that out days later, on a device, with nothing on screen to explain it.
- **The app's *Pinned cert fingerprint* field is a tightening, not a substitute.** Narrowing an already-trusted connection to one exact key is a real defence against a mis-issued certificate. It is not a way to use an untrusted one, and the wizard will not pretend otherwise.
- **Pinning the gateway from inside this script would protect nothing.** The certificate belongs to a host you control, the verification runs on that same host, and both ends of the connection are yours. What actually protects that traffic is ordinary TLS validation with **no exceptions and no override flag** — `curl_gw` in `src/50-verification.inc.sh` is the whole of it, and the absence of an escape hatch there is the property worth checking.
- **Pinning GitHub's certificate for the download would be worse than the OS trust store.** A fingerprint baked into a shell file goes stale at the next rotation, and a security control that routinely breaks teaches people to bypass it. The download's integrity story is the section above: HTTPS from GitHub Releases, an optional same-release checksum, protected tags that are never moved, a release workflow that refuses to overwrite an existing release's assets, and a file you can read before you run it.

When it refuses a certificate, the wizard names three free ways to get one the device does trust: **Tailscale Serve** (automatic, and nothing becomes public), **Let's Encrypt** (which has issued certificates for bare IP addresses since January 2026, so no domain is required), or a reverse proxy such as **Caddy** that obtains and renews one for you.

## The setup code is a secret

The QR / paste setup code contains your gateway URL and its access token — and, when the file lane is set up, the file-server URL and its credential too. Treat it like a password: it is scannable by anyone who can see your screen, and whoever holds it can talk to your gateway and read or change files in the shared folder until you rotate those secrets. The script warns you of this when it emits the code.

## Embedded component

The QR renderer embeds the unmodified Project Nayuki QR generator (Python, MIT), which uses only the Python standard library (no network, file, or subprocess access). CI verifies this block against a pinned checksum and asserts its imports stay standard-library-only on every change (`scripts/verify-vendored-encoder.sh`).
