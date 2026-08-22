# conduck-connect manual

This is the exhaustive operator manual for `conduck-connect`. For the product overview, audit-first quick start, and common commands, start with the [README](README.md).

Pair your self-hosted AI gateway with the **[Conduck](https://conduck.com)** app — one plain-text script you can read before you run it. Zero telemetry. Conduck itself is on the App Store; this is the piece that runs on your own server.

## What it does

You already run an AI agent somewhere — a VPS, a home server, a Mac mini that never sleeps. Conduck is the iPhone, iPad and Mac app that talks to it by voice. `conduck-connect` is what joins the two, and it runs on the machine your agent runs on.

Point it at a gateway — **OpenClaw**, **Hermes**, or any server that speaks the OpenAI chat API — and it will:

1. **Switch the chat endpoint on** if it is off. OpenClaw and Hermes both ship it off, so the gateway looks perfectly healthy while `/v1/chat/completions` answers 404 and no app can connect.
2. **Help you reach it over HTTPS.** Conduck only talks to an `https://` address whose certificate your devices already trust. The script walks the four ways to get one and lets you choose; it does not choose for you.
3. **Optionally set up file transfer** — the shared folder your attachments land in and your agent writes files back to — as a small WebDAV server bound to your own machine.
4. **Verify all of it with real requests**, ending with one real chat turn in which your actual agent has to read a file and write one back. A green transport with an agent that cannot see the files is the failure this exists to catch.
5. **Print a setup code**, as a QR code and as text. Scan it with the app and you are paired.

It will also **grade a server without changing anything** (two check commands, further down), and **manage what you have already set up**: list it, change one field of it, or remove it completely.

What it never does: install a gateway, Tailscale, cloudflared or rclone; elevate to root without showing you the exact command first; change your gateway's configuration without showing you the exact before-and-after; make your machine publicly reachable without saying so in plain words; or send a byte anywhere except the gateway and file server *you* named. There is no GigaDuck server for it to report to — a claim you can settle by reading the file rather than by trusting us.

**Four words used throughout.** The **wizard** is the `--setup` flow; **conduck-connect** is the whole program. Your **gateway** is the agent server this script configures. The **setup code** is the QR/paste string that pairs a device — treat it like a password. The **file lane** is the pair of things that make attachments work: the shared folder your agent reads and writes, and the small file server in front of it.

## Quick start

One command — downloads the script from GitHub Releases to disk over HTTPS, then opens the welcome menu:

```bash
curl -fsSLO https://github.com/gigaduckai/conduck-connect/releases/latest/download/conduck-connect.sh && bash conduck-connect.sh
```

- **Go straight to setup?** Append ` --setup` to the trailing `bash conduck-connect.sh`.
- **Preview setup, change nothing?** Append ` --setup --dry-run` instead.
- **Read it before running?** Drop the trailing `&& bash conduck-connect.sh` — the rest still downloads the file — then `less conduck-connect.sh` and run it when you're happy. It stays plain text on purpose ([how to read it](#read-it-before-you-run-it)).

Works on macOS and Linux. `-O` lands the whole file on disk before anything runs, so you can read it first — see [Read it before you run it](#read-it-before-you-run-it) for how. An optional same-release checksum is [below](#what-each-step-does); it confirms the download arrived intact but is not a tamper-proof signature.

## Read it before you run it

That is the point of shipping one plain file, and the Quick start writes it to disk **before** anything executes. This is deliberately *not* `curl | bash`, which pipes unread code straight into your shell — and would break the script's prompts anyway.

Now the honest part: **the released script is far too long to audit top to bottom before a first run.** Most of that length is explanation, verification and refusals — it is a wizard that argues with you — so this manual maps concerns to source modules instead of pretending a linear read is the useful path. Read for a question, not from the top.

The release is one file, but it is assembled from the modules in [`src/`](src/), and those modules are your map. CI proves they reproduce the released script byte for byte, so reading a module is reading the shipped code — and each one opens with a comment stating its job and its reasoning.

| If you want to know | Read this |
|---|---|
| What it claims to do and never do, in its own words | the comment header at the top of `conduck-connect.sh` — the same text is [`src/00-cli.inc.sh`](src/00-cli.inc.sh) |
| Whether it can phone home | `grep -n 'curl -q' src/*.inc.sh` — eighteen call sites, each taking its address from a value you supplied. The two wrappers that build them, `curl_gw` and `curl_fs_*`, are in [`src/50-verification.inc.sh`](src/50-verification.inc.sh) |
| What it can change on your machine, and how it asks first | `run_step`, `print_and_wait`, `mutate_guard` and `confirm` in [`src/10-utilities.inc.sh`](src/10-utilities.inc.sh) — every change on the machine goes through one of them |
| What it reads from — and may write to — your gateway's own config | [`src/20-gateway.inc.sh`](src/20-gateway.inc.sh) |
| What could make your machine reachable from outside | [`src/30-exposure.inc.sh`](src/30-exposure.inc.sh): every `tailscale` command it can run, every Cloudflare command it prints for you, and the records that let a later run close what an interrupted one opened |
| Where the file-server password comes from, and where it is stored | [`src/40-file-lane.inc.sh`](src/40-file-lane.inc.sh) |
| What it writes into your agent's own instructions file | [`src/41-agent-file-readiness.inc.sh`](src/41-agent-file-readiness.inc.sh) |
| What ends up inside the setup code | [`src/80-pairing.inc.sh`](src/80-pairing.inc.sh), and [PAYLOAD.md](PAYLOAD.md) for the format |
| What `--list`, `--edit` and `--forget` do — and exactly what `--forget` deletes | [`src/95-manage.inc.sh`](src/95-manage.inc.sh) |
| Which command runs what | [`src/99-main.inc.sh`](src/99-main.inc.sh) |

Two things to save you time. The one very large block near the bottom of the released script is a vendored, unmodified QR encoder (Project Nayuki, MIT) used to draw the QR locally; it is inert — Python standard library only, no network, file or process access, checked in CI against a pinned checksum — and safe to skip. And `bash conduck-connect.sh --setup --dry-run` prints the exact actions a real run would take **on your host** without taking any of them, which answers "what would this do to my machine" faster than any amount of reading.

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

# Or go straight to setup (review and approve bounded actions as you go)
bash conduck-connect.sh --setup
```

**Optional integrity check.** Each release also ships a checksum. It confirms the file downloaded intact—it is **not** a signature and cannot prove the release was not swapped because it rides the same release channel:

```bash
curl -fsSLO https://github.com/gigaduckai/conduck-connect/releases/latest/download/conduck-connect.sh.sha256
shasum -a 256 -c conduck-connect.sh.sha256        # Linux: sha256sum -c conduck-connect.sh.sha256
```

No `chmod` needed — `bash <file>` runs it without the execute bit.

## Prompt controls — `i`, `b`, `q`

Every interactive question — a yes/no gate, a menu, a value you type, a hidden
token — ends with the controls that work at *that* question and says exactly
what pressing **Enter** will do. A key is a control there if and only if the
prompt lists it, which is why a question that will not accept `b` does not
offer it.

- **`i` — explain this step.** What this action does, why it is part of setup,
  what it may read, change, contact, restart or expose, what declining means,
  and — where the answer is genuinely hard — what to pick if you are honestly
  unsure. The same question is then asked again.
- **`q` — stop.** Stops deliberately rather than being read as “no”, and the run
  exits `3`. It does not undo configuration changes you already approved,
  commands you already ran, or exposure changes already confirmed; it says so
  before it goes.
- **`b` — go back.** Offered where there is a safe, defined earlier choice to
  return to. It is not offered after the script has handed you a command to run,
  or anywhere “back” could be mistaken for undo, and it never rolls back an
  approved change.

If you genuinely want to *answer* a question with one of those letters — a
gateway named `q`, say — the script asks you to confirm it once rather than
guessing.

Enter is not one global answer. At `[y/N]` it means **No**. At a value with a
displayed default it accepts that default. At a menu with no default it selects
nothing and asks again. At an explicitly optional value it skips, or selects
keyless mode, only where the prompt says so. And after the script prints a
command for *you* to run, Enter means **No, skip** — the same as everywhere
else, so an Enter pressed in rhythm can never claim you applied a change you
never made.

If the answer is a closed pipe or an empty file, the script says which question
went unanswered and what it assumed, instead of proceeding in silence.

## Where your configuration lives

Everything the script saves goes in one directory, and nowhere else:

```
${XDG_CONFIG_HOME:-~/.config}/conduck/
```

The script creates it `0700`, so only your account can read it. A directory that *already* existed with a wider mode keeps that mode — the script will not silently re-permission a folder it did not create — but it says so once per run and prints the exact `chmod`. It holds, per gateway you have paired:

| File | What it is | Holds a secret? |
|---|---|---|
| `profile-<id>.json` | Routing facts: gateway kind, web address, transport, model, shared folder, file address. Plain, readable JSON. | No |
| `fileserver-<id>.cred` | The file server's password — the one your app uses to reach the shared folder. | **Yes**, `0600` |
| `fileserver-<id>.env` | The same password as `RCLONE_PASS=…` (Linux only). It exists so the systemd service can read the password without it appearing in the service file or in `ps`. | **Yes**, `0600` |
| `exposure-<run>-<n>.pending` | One line per HTTPS route a run opened but has not yet reported to you, so a later run can offer to close what an interrupted one left open. | No |
| `setup.lock` | A directory that exists only while a setup is running, so two runs cannot pick the same port and overwrite each other's saved setup. | No |

**Your gateway token is never written to disk by this script** — not in the profile, not anywhere in that directory. That is a deliberate limit on what a compromised configuration folder is worth, and it is why `--show-code` asks you for the token again.

**On macOS the file-server password exists in a second place.** The LaunchAgent that keeps your file server running (`~/Library/LaunchAgents/ai.gigaduck.conduck-files-<id>.plist`) carries it in cleartext, because launchd has no equivalent of an environment file. The file is written `0600`. Deleting only the `.cred` leaves the password on disk; `--forget <id>` removes both, and [WHAT-IT-TOUCHES.md](WHAT-IT-TOUCHES.md) has the by-hand version.

```bash
bash conduck-connect.sh --list
```

prints all of it for your machine: the directory itself, every saved setup in it, and whether each file server is running right now. It asks nothing, changes nothing, and prints no password and no setup code.

## Managing what you have already set up

Pairing is not the end of the story. A tunnel hands out a new hostname, you want a different model, or you stop using a gateway entirely — and until you deal with the last one, a live authenticated file server keeps running over your agent's working folder, at every boot, indefinitely.

```bash
bash conduck-connect.sh --list                 # what is set up here, and what is still running
bash conduck-connect.sh --list --json          # the same, for a script
bash conduck-connect.sh --edit [id]            # change one thing about one setup
bash conduck-connect.sh --forget <id>          # remove one setup completely
```

**`--list`** names your configuration directory and then every saved setup: id, gateway kind, web address, how it is reached, model, shared folder, file address, and the *live* state of its file server. Tokens are reported as `not stored` rather than omitted, so the absence is visible. It also lists **file servers with no saved setup behind them** — the leftovers of a gateway you removed by hand — with the command to remove each one. A saved setup this version cannot parse is listed separately, with the reason, because its id stays taken.

**`--edit [id]`** changes exactly one field and re-runs only the verification that field affects: the web address, the model, or a hand-off to setup for the shared folder (which has to agree in three places at once, so it is not a one-field change). From the same screen you can re-show the setup code or remove the setup. Leave the id out and it asks which one you mean.

The case it exists for: a Cloudflare **quick tunnel** (`*.trycloudflare.com`) is reassigned a new hostname every time it restarts, so a setup that worked last night is dead by morning. `--edit` takes the new address, checks that something answers there, offers to move the file address to the same new host, and offers to print the updated setup code — instead of a full walk through the wizard. The screen says so at the top when it recognises one.

Changing the **model** asks your server for its own list of models and tells you whether the name you typed is in it. That is one `GET /v1/models` and no chat turn, so nothing is billed. If the list comes back without your name, you are told what the server does advertise and asked whether to save anyway — a name can be an alias a server accepts without advertising, or a model you are about to add, and only you can tell. Most servers will not show that list without their token, and this tool stores none: it asks before it sends one, the token is used for that single request and written nowhere, and skipping is a normal answer — the name is saved either way, unchecked. Clearing the model instead is an explicit "let the server pick", so there is nothing to look up and nothing is sent.

**`--forget <id>`** is the only irreversible thing in this tool, so it is the one action Enter cannot complete: you confirm by typing the id. Before it asks, it lists everything it will remove — the saved setup, the file-server service, **both** copies of the file-server password, and each **Tailscale** route this machine is still serving in front of it — and everything it will **not** touch:

- **your shared folder and everything in it.** On OpenClaw and Hermes that folder is the agent's own working directory.
- **your agent's `TOOLS.md`**, and any gateway configuration this script edited.
- **the gateway itself.** It keeps running, on the same port, with the same token.
- **the pairing already on your phone, tablet or Mac.** That device still holds the gateway's address and its token, and nothing on this machine can reach it — remove the connection in the app too. If you are removing this because the token leaked, rotate the token at the gateway; that is the only thing that revokes it.

Anything it cannot *prove* it removed is reported by exact name, with the commands to finish by hand and a plain statement that it did not run them. The routes it can close are Tailscale Serve and Funnel mappings on this machine; a Cloudflare tunnel or a reverse proxy of your own was never opened by this script, so it is never closed for you. A Tailscale route it cannot prove belongs to this setup is named, left alone, and printed with the command to close it by hand. It exits `0` when everything is gone, `1` when some of it is still there.

## Public commands and flags

| Command | Effect |
|---|---|
| _(none)_ | Welcome menu, and a hub you return to: set up, check a server, check an adapter, re-show a saved code, see what is already set up, change or remove one of them. Finishing an action offers the menu again rather than ending the session |
| `--setup` | Go straight to setup. Detection reports OpenClaw/Hermes installs, but you always explicitly choose OpenClaw, Hermes, or another server |
| `--check-server [url]` | Existing OpenAI-compatible software **not built for Conduck**: check core compatibility with the current Apple Conduck app |
| `--check-adapter [url]` | An adapter built specifically for Conduck: grade the stricter adapter contract |
| `--list` | What this machine already has set up: every saved setup, where its files live, and any file server still running with no setup behind it. Asks nothing, changes nothing, prints no secret |
| `--list --json` | The same inventory as one JSON object, with its own `schemaVersion`. Needs no terminal |
| `--edit [id]` | Change one thing about one saved setup — its web address, its model — and re-verify only what that changed. Re-showing the code and removing the setup live here too. Without an id, it asks which setup you mean |
| `--forget <id>` | Remove one saved setup: stop and delete its file server, close the Tailscale routes this machine is serving for it, delete both copies of its file-server password, delete the saved setup. Confirmed by typing the id. Never deletes your shared folder. Exits `1` if no setup has that id |
| `--show-code` | Re-show a saved gateway's setup code without configuration changes. It re-emits exactly what the saved profile holds, so a code minted without a file lane stays chat-only — attachments remain inline-only until a full `--setup` run captures a lane. Live verification sends gateway requests — including the photo turn every verification makes — and, when configured, one small file-lane PUT→GET→DELETE probe; every configured lane also gets a real agent sentinel turn — tool-named on OpenClaw/Hermes, tool-agnostic on any other server — which costs one real chat turn on a metered gateway |
| `--setup --dry-run` | Show setup state and the exact actions a real run would take, then stop. Never prompts for secrets, mints credentials, sends requests, or emits a code. It ends by printing the exact command that runs it for real, rebuilt from the flags you used, so committing to the run cannot silently drop one |
| `--setup --reuse-only` | Walk setup using only what already exists. It does not apply host configuration changes — the first step that would need one stops the run and names it, rather than skipping past it. Live verification still sends gateway requests, including the closing photo turn, and may write/delete the normal byte probe; a configured lane also runs the real agent file-lane sentinel |
| `--check-adapter --deep [url]` | Also test how the adapter handles a message with an image |
| `--check-adapter --files [url]` | Also grade the file lane. This explicitly mutating check writes and removes small named `conduck-check-*` files and folders in the configured shared folder, and asks the agent to create one folder and write a file inside it |
| `--setup --allow-keyless-public` | Expert: permit a keyless gateway on a public transport |
| `--help` / `-h` | A one-screen reference: synopsis, every command split by whether a script can drive it, options, environment variables, exit status, examples |
| `--version` | Print `conduck-connect <version>` and exit — nothing else runs |

Exit status is deliberately small and stable:

| Status | Meaning |
|---|---|
| `0` | The action succeeded, or a check passed. Choosing "exit" at the welcome menu is also `0` — that is a completed choice, not an abort |
| `1` | A setup or runtime failure, or a completed check that failed |
| `2` | The command line itself is invalid: an unknown or retired spelling, incompatible flags, an extra positional argument, an invalid direct URL |
| `3` | You stopped the run before it finished — `q` at a prompt, or backing out of a removal |
| `4` | This action needs a person at a terminal |
| `128+signal` | Interrupted by HUP/INT/TERM, in the conventional way |

Once a noninteractive check has passed command validation, its machine summary
remains the final line even if runtime preflight fails — for example, missing
`curl` or `python3` reports `exit=1` with all check meters still `NOT_RUN`.
Machine-driven use — `CI=1`, `CONDUCK_TOKEN`, the summary grammars, and what a
tool can and cannot finish on its own — is written up in
[AGENTS.md](AGENTS.md#for-ai-tools-driving-this-script).

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

Running it from a build script or an AI coding tool? Put `CI=1` in front. Without it, a check that **passes** in a real terminal goes on to ask whether you want to continue into setup — and an automated caller that has already read `exit=0` sits at that question forever. `CI=1` makes the machine summary the last thing either check prints.

The check changes no host configuration. It sends a handful of real requests—which may consume compute or enter server-side history—and grades the answers against the rules at **[conduck.com/setup/adapter/v1/](https://conduck.com/setup/adapter/v1/)**. That includes the one the pairing wizard cannot prove: your token check is actually **enforced** (a missing or wrong token must get `401` on both routes). Exit code `0` means every check passed. Plain `http://` is accepted toward `127.0.0.1`/`localhost` only; the token comes from `$CONDUCK_TOKEN` or a hidden prompt, never the command line (`argv` is visible to `ps`). For a scripted run with no keys at all, export `CONDUCK_TOKEN=` **empty** — that is an explicit keyless declaration. Leaving it unset where no prompt is possible (piped or closed input) fails fast instead of grading the target as keyless, because a silently-assumed keyless run grades the wrong thing and calls it a pass. Add `--deep` to test a message with an image (an honest HTTP `400` "images unsupported" answer passes).

One scope note: it grades the *adapter* rules. Generic OpenAI-compatible software — OpenClaw, Hermes, Ollama, LiteLLM, vLLM — legitimately does things those rules forbid (honoring `stream: true` with SSE is correct OpenAI behavior; keyless modes are fine app-side), so using this strict adapter check on them produces failures that don't mean anything is wrong. **That's what `--check-server` is for** (next section): if the software was built specifically for Conduck, use `--check-adapter`; if it was not, use `--check-server`. Every failure exit says this too, including the early `/v1/models` abort — a wall of red on software you did not write means little, and `--setup` still pairs it — so you do not have to have read this section to find the way out. A passing run says none of it.

### Grade the file lane too (`--check-adapter --files`)

If your setup has a file lane (the shared folder the app and your agent exchange files through), `--files` grades it as three independent meters.

**`file_transport`** — the WebDAV↔disk lane itself: auth on the routes that carry your bytes, byte-identical write-through, *direct-write freshness* (a file written straight to disk must be visible over WebDAV within 2 seconds), ranged-probe compatibility, folder creation, **listings**, verified DELETE. Two of those are new requirements rather than nice-to-haves. The app names a two-part folder for every reply that might return a file, so a server that refuses to create folders has no delivery route at all — there is no flat fallback. And the app *finds* a returned file by listing that one folder, never by guessing a name, so `PROPFIND` with `Depth: 1` has to be answered: `rclone serve webdav` does, `ngx_http_dav_module` and stock Caddy `file_server` do not. Every listing is judged against a control — a folder that cannot exist must come back a definite 404, because a server that cannot say *no* can say nothing believable about what *is* there.

**`file_access`** — one real chat turn. The turn names a folder that does not exist and asks for a file inside it, byte-for-byte, finished *before* the reply. **Nothing creates that folder in advance, and the check proves both its parts absent first.** That direction is the whole point: a folder created over WebDAV belongs to whoever the file server runs as, so an agent running as a different user is refused inside it — a folder made *for* the agent is worse than no folder at all. The agent must therefore create it, parents included, and own it. A byte-perfect file written correctly *beside* that folder scores nothing.

**`file_e2e`** — the combined delivery path, probed the way the app probes it: one immediate `PROPFIND Depth: 1` of that folder the moment the reply lands, no grace and no retry, then a full download byte-compare. A folder the agent made that your file server cannot read into — `0700` under a service running as someone else, or a server that only reflects its own writes — fails here while a direct fetch of the exact name still works, and that is the distinction: the app never has the exact name.

This profile **mutates**: it writes and removes small named artifacts in the configured folder — a `conduck-check-<run>/` folder with its input file, plus the `conduck-check-<run>-out/out-<nonce>/` folder that **the agent** creates — both segments, since the check makes neither — and the `output-<run>.txt` **the agent** writes inside it (`<run>` is a random per-run tag). Every target is registered before creation, removed by exact name — never by pattern — and cleanup that cannot be *proven* is reported by exact name rather than assumed. The flip side of exact names is stated rather than hidden: a file a misbehaving agent writes *outside* those names is not something this check will delete for you. On the machine where setup ran it finds the lane from your saved profile; elsewhere set `CONDUCK_FILES_URL` + `CONDUCK_FILES_DIR` + `CONDUCK_FILES_PASS`.

The last line of every noninteractive adapter check is a machine summary (`CONDUCK_CHECK_ADAPTER schema=3 …`) — build scripts key on the prefix, the `schema=`, and the exit code. The grammar is frozen per schema number; any change to it bumps `schema=`, so pin the number you parse.

## Testing existing OpenAI software (`--check-server`)

Pointing Conduck at something you already run — Ollama, LiteLLM, vLLM, LM Studio, a framework's OpenAI-compatible endpoint? Use:

```bash
CONDUCK_TOKEN="$TOKEN" bash conduck-connect.sh --check-server http://127.0.0.1:11434
```

The check changes no host configuration, but it sends several real model/chat/image requests that may consume compute or enter server-side history. At the **directly addressed endpoint**, it matches the current Apple app's request and response acceptance: any 2xx response is decoded, response `Content-Type` is not graded, the full `choices` array must decode, an empty-string reply is valid, extra fields such as `tool_calls` are tolerated, `stream: true` is never sent, and no negative-auth requests are made. An empty answer at the prompt — or an exported but empty `CONDUCK_TOKEN=` — means the app's explicit keyless mode.

Get the address wrong interactively and it re-asks for the **address only**, keeping the credential you already typed — that is the expensive input, and often a 300-character token. The retry enforces the same rule as the first ask (`https` anywhere, plain `http` only toward an address on your own network), and each attempt re-arms its own counters so a failed first address cannot bleed into a passing second one. A scripted run still exits `1` on the first failure rather than prompting. If the address answers with a web page, the diagnosis now names the most common real cause: an OpenAI-compatible API living under a **sub-path** of what you gave it — Open WebUI's `<url>/api` being the usual case.

The diagnostic deliberately does not follow HTTP redirects or forward your credential to a `Location` target. A 3xx result tells you to use the final server URL directly. Conduck's Apple networking stack may follow an allowed redirect, but redirect policy is not part of this check's promise.

Four wire checks cover core text-chat compatibility: models envelope + 15-second limit, chat decode, advertised-model selection, and history-image tolerance. The image-capability result (`VERIFIED` / `DECLINED` / `IGNORED` / `OPAQUE`) is separate and informational; it never changes the core PASS/FAIL verdict. Servers that require a `model` field pass with a `model=required` note—in the app, pick a model in gateway settings. Android is still a work-in-progress client and is not the compatibility authority yet.

### Checking a specific model (`CONDUCK_CHECK_SERVER_MODEL`)

The check first asks your server with no model name at all, and then — whenever one is available — asks again naming a model. Left to itself, the one it names is whichever id `/v1/models` happens to return first, and that order has nothing to do with what any of those models can do. On a server that fronts many models that has a sharp edge: the same server can come back FAIL or PASS purely on the order it lists them, so the verdict you get may be about a model you were never going to use.

Name the one you actually plan to use:

```bash
CONDUCK_CHECK_SERVER_MODEL='llama-3.3-70b' bash conduck-connect.sh --check-server http://127.0.0.1:4000
```

Every request in that run that carries a model name then carries that one, and the transcript says which model each verdict describes. The requests that deliberately test model-less behavior still leave it out — that is a separate thing worth knowing about your server. An id your server does not advertise is checked anyway; you just get a note that it is not in the list, in case it is a typo. Leave the variable unset and nothing about the run changes: it falls back to the first advertised id, or to whatever your server routes to by default when it answers without a model field at all.

If you continue into setup, the setup code keeps the routing the check actually proved — the model you named, or no model name at all when what got tested was the server's own default route.

The last line of every noninteractive run is a machine summary (`CONDUCK_CHECK_SERVER schema=2 … wire=PASS|FAIL …`); exit `0` means core text-chat compatibility is green. It does **not** certify image understanding, public reachability, HTTPS certificate trust, or make the server a Conduck adapter (that is `--check-adapter`). Statefulness is also invisible on the wire: Conduck resends the full conversation every turn, so a server that keeps its own history will silently double-count context.

## Trust posture

- Runs on **your** gateway host. **No telemetry, ever — there is no GigaDuck server.** Its own HTTP probes go only to the gateway and file lane you name, and the QR is generated locally. The exception is the exposure path you choose: `tailscale serve` / `tailscale funnel` and `cloudflared tunnel list` are that vendor's own commands, and running them contacts that vendor's control plane.
- Never installs gateways, Tailscale, cloudflared, rclone, or any background program it didn't create.
- Previews and asks before changing gateway or user-owned configuration and before changing network exposure. Bookkeeping the script owns, plus the exact verification artifacts, may be created automatically inside the bounded setup or check action you chose; the complete list and undo guidance is in [WHAT-IT-TOUCHES.md](WHAT-IT-TOUCHES.md). Things *you* own (a Cloudflare tunnel, your reverse proxy) are printed as exact commands for you to run yourself.
- Never elevates silently. Every command that needs higher rights is shown in full first — prefixed with `sudo` or `doas`, whichever this machine has, and bare when you are already root or have neither — and all but one are printed for you to review and run yourself (Tailscale operator rights, `pmset`). The exception is `loginctl enable-linger <user>` in the file-lane step — lingering is what keeps your file server running after you log out. The script runs that one itself, and only after you approve the exact command at a `y/N` prompt; decline and it prints it as a tip instead.
- Never makes your gateway public without telling you, in plain words, that it will — and refuses to publish a keyless gateway unless you run setup with `--setup --allow-keyless-public`.
- Re-running is safe; `--show-code` re-shows your saved setup code without changing configuration. Its live verification still sends gateway requests — including the photo turn every verification makes — and briefly writes/removes small randomized probes when a file lane is configured (including one real agent file turn, on any gateway kind).
- Removal is the one irreversible action, and it is the one Enter cannot complete: `--forget <id>` lists everything it will remove *and* everything it will leave alone, then asks you to type the id.

See **[WHAT-IT-TOUCHES.md](WHAT-IT-TOUCHES.md)** for the exact files, services, and ports it reads or changes — and how to undo each.

## Requirements

`bash` (3.2+), `curl`, `python3`, `openssl`. A Linux or macOS gateway host.

The wizard is interactive and needs a real terminal: prompts cannot be piped in, and there are no non-interactive answer flags. Setup also ends in a QR code somebody scans with a phone, so a machine cannot finish it however good its PTY is. What *is* fully scriptable — `--check-server`, `--check-adapter` and `--list --json`, with `CI=1` so a passing check never waits for a person — is written up in [AGENTS.md](AGENTS.md#for-ai-tools-driving-this-script).

## Reaching your gateway

Conduck needs the gateway at an `https://` URL, or at a plain `http://` one that only your own network can reach. The wizard walks four paths and lets you pick — no auto-recommendation, just honest trade-offs:

- **Tailscale** — private, tailnet-only. *Note: a standalone Apple Watch cannot reach a tailnet-only gateway.*
- **Tailscale Funnel** — public, end-to-end encrypted.
- **Cloudflare Tunnel** — public; needs a domain and `cloudflared`.
- **I already have an address for it** also covers a `cloudflared tunnel --url` quick tunnel — the `*.trycloudflare.com` address you get without a domain. Pick that option, not the Cloudflare Tunnel one above, and note the hostname changes every time the tunnel restarts, so a saved code goes stale on a reboot.
- **I already have an address for it** — give the address. An `https://` one needs a certificate your devices already trust (e.g. Let's Encrypt); anything else — self-signed, a private CA, expired, wrong hostname — stops the run, and the script names the three free ways to get a real certificate.
- **A plain `http://` address on your own network** is the fifth case, and it lives inside the option above rather than beside it: type it and it is taken. A server such as **Ollama** answers on `http://<this machine's LAN address>:11434` and cannot be configured to do anything else, so refusing it outright shuts those setups out of the product. What qualifies is a loopback or private IP literal, an IPv6 ULA or link-local literal, or a `.local` name — a **domain name never does, however private the machine behind it is**, and neither does the carrier-grade NAT range an overlay VPN hands out. Neither does a **bare one-word name** such as `nas` or `ollama`: names like that look local but real one-label TLDs answer at the public DNS root, so a resolver falling through its search domains could hand your key to a stranger. The same machine's `.local` name, or its IP address, is the spelling that works, and the refusal says so. That boundary is Apple's, decided from the address string before any connection is attempted, so the wizard applies the same one rather than mint a code that fails on the phone. Two things it costs you, both said at the prompt: nothing on that lane is encrypted, so anyone on that network reads your messages and your key; and the device only reaches it while it is on that network, so a standalone Apple Watch never does. Plain `http://` is taken when you type it and is never suggested or defaulted to.

Where an address *is* encrypted, the certificate is not negotiable: Apple's App Transport Security rejects a chain the device doesn't trust before Conduck is ever consulted, and a fingerprint pin can only *narrow* trust a device already has — it cannot grant it. So a self-signed certificate has no working outcome on a phone, and the wizard refuses to mint a code that would fail there. The three free routes it points you at:

- **Tailscale Serve** — issues a real certificate automatically and exposes nothing publicly (that's option 1 above).
- **Let's Encrypt** — free, and since January 2026 it also issues certificates for a bare IP address, so no domain is required.
- **A domain in front of it** — Caddy or another reverse proxy obtains and renews the certificate for you.

Whichever path you pick, every address you type — gateway or file lane — has to be a plain URL. One carrying `user:pass@` credentials is refused, by the wizard and by both check commands: that password would otherwise be echoed on screen, saved into the profile, and ride inside the setup code. Credentials belong in the token prompt, not the address.

## Set up the file lane by hand (any WebDAV server)

**The easy path is to re-run `conduck-connect`.** It's the supported way to add file transfer after chat is already paired: it detects an existing `conduck-files-<gwid>` server, reuses its stable folder/port/credential, allocates a different free loopback port when another gateway already owns the default, checks the local service before exposing it, reconciles the lane's reach against the gateway's, and emits a fresh setup code only after live verification. `--show-code` is not a shortcut for this: it re-emits the saved profile as it stands, and a profile captured without a file lane has none to hand over — skip the lane during `--setup` and the code you scan carries chat only, with attachments inline-only, until a later `--setup` run gives the lane an address. Reach for the manual path below only when you run your own topology — Caddy, nginx, a NAS appliance, containers, or rclone under your own supervisor — anything that already speaks WebDAV.

Conduck doesn't care *how* the endpoint is built, only that it satisfies the contract the in-app **Test Connection** stages check. Serve that contract with whatever you already run.

**The contract**

- **HTTPS, unless the address is a local-network one.** The app applies the same admissibility rule to the file URL as to the gateway: `https://` with a certificate the device already trusts, or plain `http://` toward an address nothing outside your own network can reach. Anything else is rejected outright. If you terminate TLS, do it with a certificate the device already trusts — the same bar as the gateway (see security notes).
- **HTTP Basic auth, username `conduck`.** The password is generated *in the app* — **Settings → your gateway → File transfer → Generate credential** — and pasted into your server's config. Conduck never accepts a password you invent; the app is the source of truth for that credential.
- **Serve the folder the agent actually reads and writes.** The WebDAV root must be the agent's working directory — for OpenClaw its workspace (`~/.openclaw/workspace` by default), for Hermes the folder `terminal.cwd` points at in `~/.hermes/config.yaml`. The wizard aligns the Hermes root and live-proves **every** lane before including it — OpenClaw and Hermes by their own tool names, any other server with the same read→byte-identical-write sentinel worded without them — so re-running it is the decisive agent-side test whatever you run. **The requirement, stated plainly: your agent must be able to create a folder, and Conduck must be able to read it.** Not "your WebDAV server can create a writable folder" — Conduck names a folder for each reply and creates nothing, so the agent makes it and owns it. That is deliberate: a folder made over WebDAV belongs to whoever the file server runs as, and an agent running as a different user is then refused inside it, which is precisely how the two most common gateways fail. The sentinel measures that exact direction: it names a two-part folder that does not exist, proves it does not exist, asks for a file inside it, and then lists the folder the agent made. For an adapter you built to the Conduck contract, `--check-adapter --files` runs the same kind of copy test. The in-app WebDAV test alone cannot prove the agent's working root.
- **The agent must be ALLOWED to use its file tools.** Byte transport is only half the lane: the gateway's tool policy decides whether the agent may open uploads and write output files. On OpenClaw, `tools.deny` containing `group:fs` (a common hardening move) breaks every attachment turn while transport stays green — `read` and `write` must be allowed (keep `edit`/`apply_patch`/`exec` denied if you like). That much the wizard checks, and it offers the exact fix; those two tools are its whole concern, and it proposes nothing else. Native PDF analysis is a separate matter that the wizard leaves entirely alone: the `pdf` tool is not in the `coding` profile, and switching it on also means pointing `agents.defaults.pdfModel` at a model your gateway can actually resolve. Treat PDFs as their own checklist: **[A PDF "answers" but with generic or wrong content](#file-lane-problems)** in Troubleshooting walks all of it. On Hermes, an explicit `platform_toolsets.api_server` must keep a file-capable toolset; the wizard adds only the missing `file` entry, and refuses global-disable or non-local-backend cases it cannot safely map. That same list is also where Hermes's own recall lives, so the wizard asks separately about taking `memory` and `session_search` out of it — in this step your yes only folds that removal into the one combined before/after it shows you, and nothing is written until you approve that too (see [Other endpoint gotchas](#other-endpoint-gotchas)). `--check-adapter --files` is the end-to-end proof for hand-built adapters.
- **Same reach as the gateway.** Expose the file server on the same rail you exposed the gateway on. If the gateway is public but the file server is tailnet-only, a standalone Apple Watch can still chat but silently can't send or open attachments.

Then, in the app: paste the file-lane URL and run **Test Connection**. The staged app test proves reachability, auth, and a byte-faithful `PUT` → `GET` → `DELETE` round-trip. It does not execute your agent's tools; use the wizard's sentinel — it runs on every gateway kind — or, for an adapter you built to the Conduck contract, `--check-adapter --files`, to prove that final half.

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
| `…failed: connection refused` | Nothing is listening at that host and port. | Is the server running? Right port? Firewall open? Many local servers (Ollama, LM Studio) bind to `127.0.0.1` only — front them with the wizard's exposure step, and make that front **rewrite** the `Host` header rather than forward it, or the same servers answer `403` instead (see the `HTTP 403` row below). |
| `…failed: timed out` | No answer at all. | Host offline, unreachable address, or a firewall silently dropping traffic. |
| `…failed: TLS/certificate problem` | Either the server's certificate is bad (expired, wrong hostname) or this machine's own trust store rejected it. | Renew or fix the certificate — expired and wrong-hostname certs both stop the run, deliberately. A wrong system clock on either end produces the same failure. |
| `The certificate at … is signed by an issuer this machine doesn't trust` | A self-signed certificate, or one from a private CA. Your phone would reject it too, before Conduck ever sees it, and no fingerprint you paste into the app changes that. | Get a certificate the device trusts: Tailscale Serve (option 1 — automatic, nothing public), Let's Encrypt (free, and it issues IP-address certificates since January 2026, so no domain needed), or a reverse proxy like Caddy that mints and renews one for you. Then re-run the wizard. |
| `…failed: HTTP 401 — token rejected (or an access layer in front wants a login)` — a keyless gateway reads `…HTTP 401 — this gateway is keyless, so no token was sent` instead | A credential problem: a wrong or stale bearer token, or an access layer in front wanting its own login. On a keyless gateway there is no token to be wrong, so either the server wants one after all or something in front of it does. | Re-read the token from the gateway's config (OpenClaw: `gateway.auth.token` · Hermes: `API_SERVER_KEY`); check any proxy access policy. |
| `…failed: HTTP 403 — refused: either the token, or the request itself as it arrived over your HTTPS route` — a keyless gateway reads `…this gateway is keyless, so there is no token to reject: the request itself was refused as it arrived over your HTTPS route` instead | The request arrived and was **refused**, so the address and the network are fine. The usual cause is `Host` validation. Every HTTP request carries the address name it was sent to — its `Host` header — and servers meant to be reached only from the machine they run on, **Ollama** above all, accept only a local name. A tunnel or reverse proxy passes on the *public* name it was asked for, so such a server refuses the request however healthy it is. Where a local port is known, the wizard sends the same request with the same credential to `127.0.0.1` and reports the split: succeed there and fail over HTTPS, and the server and your credentials are fine — the refusal belongs to the HTTPS route in front of it. | Make whatever fronts the gateway **rewrite** that header rather than forward it — in nginx, `proxy_set_header Host 127.0.0.1:<port>;`. Ollama's own alternative is to listen beyond loopback (`OLLAMA_HOST=0.0.0.0`), which skips its host check entirely — at the cost of answering on every interface. `OLLAMA_ORIGINS` is *not* a cure for this: it allow-lists browser `Origin` headers for CORS, and neither Conduck nor this wizard sends one, so it never reaches the check that refused you. A bare `cloudflared tunnel --url` pointed straight at Ollama rewrites nothing, so it cannot succeed until one of the two real fixes is in place. |
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
| `photo turn: answered 200 — twice — without reading either test picture's digits back` | Verification sends one real chat turn carrying a small picture of six random digits and asks for them back; a reply that gets all but one of them right still counts as having seen it. This gateway answered confidently, twice, on two different pictures, without coming close to either — so it could not be shown that the engine saw them. Two causes look identical from outside: the picture never reached the engine, or it reached one that couldn't read it. In the app, either way, a photo comes back as a confident answer that does not reflect the picture, and the app has no way to know. | Send pictures to an engine that can see them — **or** refuse them honestly: `400` with an error body carrying code `image_unsupported`, which makes the app show *pictures aren't supported here* instead. Text-only on purpose? The second option is the supported answer, and it passes cleanly. You're asked whether to pair anyway — however you got here — and **Enter means no**; the finding is that photos are *unverified*, which is not the same as proven broken, so it is not converted into a verdict. Reaching setup from `--check-adapter` additionally points you at `--check-adapter --deep`, where the wire is graded strictly and this result is red. A run with no terminal to ask on stops rather than deciding for you — re-run it where you can answer. |
| `Image support was NOT measured — the photo turn didn't complete (…)` | The picture turn never finished: a dropped tunnel, a timeout, a refused connection. Nothing was learned about photos either way. | Nothing to fix here — the code still prints, because a run that measured nothing may not convict. Re-run if you want the answer. |
| `The test picture was refused as TOO LARGE (HTTP 413)` | Something on the route caps request bodies below a few kilobytes; a real photo is far larger, so every picture will fail. | Raise the body limit on whatever answered — a reverse proxy, a tunnel, or the gateway. The adapter contract's floor is 50 MiB. The app shows a clear picture-too-large message, so this doesn't hold up your code. |

### Other endpoint gotchas

Nothing fails, so no message prints — but the result quietly isn't what you wanted:

- **Hermes: pair the full-agent API server (default `8642`), never `hermes proxy` (`8645`).** Both chat, but the proxy is a bare relay to the model — none of Hermes's tools or skills — so an agent paired there can't open what you send it or write anything back. The wizard challenges a Hermes config whose `API_SERVER_PORT` is 8645; if you wired it by hand, re-check the port.
- **Hermes: the full-agent API server keeps a memory of its own until you narrow it.** `memory` and `session_search` in `platform_toolsets.api_server` let the gateway answer from things Conduck never sent it — and because Conduck resends the whole conversation every turn, you pay for that hidden context on top of the history you already sent. Nothing on the wire shows it: a gateway in that state passes every check here and in `--check-server`. Write no `api_server` list at all and Hermes falls back to a default bundle carrying both, so a fresh install starts this way. The wizard reports the scope before pairing, offers to remove exactly those entries when they are plainly listed, and never blocks pairing over it. Whichever route you take, the agent's other tools and skills stay — this is only Hermes's own recall, not the whole agent you give up on `8645` above. Test it yourself: tell it something in one conversation, then ask for it in a brand-new one. Where the wizard will not make the edit for you, what it prints depends on what it can prove:
  - **Entries it can see by name in an explicit list** — take exactly those two out, leave every other entry alone.
  - **No `api_server` key at all, or a list holding exactly the one bundle name `hermes-api-server`** — Hermes has no exclusion syntax, so nothing subtracts two names from a bundle and the per-surface fix is to write the list out. It prints the one line to write — `api_server: ["browser", "code_execution", "cronjob", "delegation", "file", "image_gen", "skills", "terminal", "todo", "vision", "web"]` — as that child key alone, names its full path `platform_toolsets.api_server`, and says where it goes before it shows it: two spaces in under a `platform_toolsets:` line and never at the left margin — inside the `platform_toolsets:` section your file already has, leaving that section's other platforms alone, or under one you add at the left margin yourself if there is no such section anywhere. Placement is the whole game here: two `platform_toolsets:` sections in one file do not merge — one wins outright, and the platforms configured in the other stop applying. The list is the reviewed Hermes API-server default minus the two recall toolsets, so everything else that default resolves to **from your configuration alone** — terminal, code execution, the browser, skills, vision, image generation — survives the move to an explicit list. Two toolsets sit outside that promise and outside the list: Hermes switches `homeassistant` and `x_search` on from `HASS_TOKEN` / `XAI_API_KEY` in its own environment, and only while no explicit list exists, so add either one yourself if you run Home Assistant or xAI search. The wizard says so where it prints the list. The list is otherwise a deliberate freeze: from then on it is yours to maintain, and a later Hermes that adds a toolset to its own bundle will not add it here.
  - **A bundle it has not reviewed** — `all`, `*`, `hermes-cli`, any other `hermes-*` — is described, not handed a list. The wizard cannot know what those contain, so it asks you to name the toolsets this API server should have rather than printing a set that might silently drop tools you use.
  - **`hermes-api-server` with anything beside it** — that bundle *is* the one the wizard has reviewed, and it has just named it on your screen, so it does not pretend otherwise. What it will not do is decide the fate of the entries standing next to it: those are deliberate choices of yours, and any replacement list has to either carry them across or drop them. It asks you to write the list out yourself — what that bundle gives this API server, without the two recall toolsets, plus the entries beside it you still want. An entry your `agent.disabled_toolsets` currently switches off counts as an entry beside it: that is a dormant choice you made, not a line to discard for you.
  - **YAML it cannot read, or a toolset name it doesn't recognise** — it says exactly that and stops there: no claim about what the key holds, and no replacement for it.
  - **The one-line global alternative, named wherever the fix means writing a list** — **add** (never set) `memory` and `session_search` to `agent.disabled_toolsets`. It is printed the same way: the `disabled_toolsets:` key and its two items alone, to append to the `agent:` section your file already has, with a fresh `agent:` line of your own only if there is none — two `agent:` sections do not merge either, one wins, and everything the other one set stops applying. It buys simplicity at a price the wizard states out loud: it reaches every Hermes surface at once rather than just this API server, Hermes's own `hermes tools` screen can silently drop those entries again when you re-enable a toolset anywhere, and it stops memory writes and session search without stopping saved memories from reaching the prompt.
- **vLLM can list a model whose chat fails** — a model served without a chat template answers `/v1/models` but errors on `/v1/chat/completions`.
- **In-app symptoms** (Test Connection inside Conduck, device-specific behavior like Apple Watch reach): the setup ladder at https://conduck.com/setup/#troubleshooting covers those.

### File-lane problems

- `The file-server service exists but is not active` / `did not answer with its saved credential` / `did not reject both missing and wrong credentials` — the local service behind the planned exposure is stopped, shadowed, or insecure. The wizard leaves it out rather than putting an unproved lane in the code. Repair/restart that exact `conduck-files-<gateway>` unit and re-run. If two pre-existing per-gateway units claim the same loopback port, only the exact unit that is active and passes the authenticated byte probe can be used; the wizard intentionally does not rewrite or rebind either existing definition. Stop/repair/remove the stale duplicate, or assign it a different port, then re-run.
- `OpenClaw agent file lane failed: …` / `Hermes agent file lane failed: …` — WebDAV worked, but the full agent did not read the randomized input, did not create the folder it was named, or did not finish a byte-identical output inside it. The lane is omitted. The screen says which of those it was, and the distinction is the whole fix: an agent that never made the folder needs file tools that can create directories, while an agent that made one whose contents your file server cannot list needs the folder readable by the account that server runs as. For OpenClaw, check the workspace/tool policy/`TOOLS.md`; for Hermes, check `terminal.cwd`, the API-server `file` toolset, and `.hermes.md` / `HERMES.md`. Re-run after fixing it.
- `The file-lane sentinel did not pass: …` (any other OpenAI-compatible server) — the same sentinel, worded without tool names because your server's file tools are whatever its author called them. The screen names which step fell short, and that decides what it means: a failure at the agent's own file work is the expected result for a plain model server — Ollama, vLLM and LiteLLM have no file tools at all, and nothing on your host is wrong — while a WebDAV refusal, a chat request that never came back, or a temp file the script could not stage says nothing about your agent, which was never asked anything. The agent-side failure can equally mean the agent works somewhere other than the folder you named, or sees a different filesystem than the machine you ran setup on — a container, another account, a worker on another box. You are asked whether to include the file server anyway, and the default is to leave it out; the setup code has no field for "untested", so a lane you keep arrives in the app looking fully working. Declining also closes an HTTPS route that run opened for the lane; the file server itself keeps running.
- `file lane probe failed` / `the saved profile's file lane failed live verification` — the WebDAV server didn't complete the PUT → GET → DELETE round-trip: wrong credential, server not running, or its HTTPS front broken.
- **Transport is green, but the agent never sees uploaded files** — two known causes:
  1. the WebDAV root points at the wrong folder — it must be the agent's *working directory*; see the contract in "Set up the file lane by hand" above;
  2. the gateway's **tool policy denies the agent's file tools** — on OpenClaw, `tools.deny` containing `group:fs` (or `read`) makes every upload invisible to the agent; the typical symptom is the agent web-searching for the filename, claiming it can't access files, or the first attachment turn timing out into a "no response" placeholder while the agent flails. Re-run the wizard (its file-lane step checks the policy and offers the exact fix), or allow `read`/`write` yourself and restart the gateway.
  The setup sentinel detects both end to end on **every** gateway kind — tool-named for OpenClaw/Hermes, tool-agnostic for anything else — so re-running the wizard is the check to reach for here, whatever your server is. `--check-adapter --files` proves the same half only for software built to the Conduck adapter contract: on generic OpenAI-compatible servers it grades rules they are expected to break (see the scope note under `--check-adapter` above) and probes the first model the server advertises rather than the one you paired, so its red says nothing about your attachments. The app's own File transfer test intentionally grades only transport, so a manually paired lane can still need the deeper check.
- **A PDF "answers" but with generic or wrong content** — the agent never got the document's text and answered from the filename or from raw bytes. The cause is gateway-specific:
  1. On **OpenClaw**, three separate things have to be true, and the wizard touches none of them — this list is the check, and it is yours to work down. Take them in order, because each one masks the ones below it.
     - **Nothing may deny the tool.** Deny beats allow, so a `pdf` in `tools.deny` (or a wildcard reaching it, e.g. `pd*`) leaves the tool off however you allow it elsewhere. Matching ignores case, so `PDF` denies it just the same. Take the entry out of `tools.deny` yourself; the wizard never edits it in either direction.
     - **The tool has to be on.** It is not in the `coding` profile; `tools.alsoAllow: ["pdf"]` adds it. The `tools` block in `~/.openclaw/openclaw.json` is what to look at. Restart the gateway afterwards — a saved config the running process never reloaded changes nothing.
     - **The model behind it has to resolve.** The tool does not use your chat model; it uses whatever `agents.defaults.pdfModel` names, and that name has to be one this gateway can reach. Measured on a live box with an OpenRouter-routed OpenAI model in that key, every single call came back `Unknown model: <that name>` — with the tool present and fully permitted. This is the step that most often survives a policy someone has already "fixed", and it announces itself: a failed call appends a visible *tool failed* line to the reply, so that line is what to look for.

     One more trap once all three hold: the tool wants the file's **absolute** workspace path — a bare filename fails its allowed-directory check even where `read` succeeds. The wizard's `TOOLS.md` block teaches the agent that retry.
  2. On **Hermes**, `read_file` is not a PDF text extractor: on a `.pdf` it returns PDF syntax, or reports the file as binary. The wizard's `.hermes.md` / `HERMES.md` block tells the agent to treat neither as the document's text, to extract it with `pdftotext -layout <the uploaded path> -` through Hermes's `terminal` tool, and to say so plainly when that isn't possible instead of guessing. The block is instructions, not permissions, so two things have to be true on your side before that rule can do anything — and setup checks each one and prints a note about it, never a blocker.
     - **The API-server scope has to carry the `terminal` toolset.** Setup reads that from `platform_toolsets.api_server` and `agent.disabled_toolsets` together: where it can read them cleanly and finds no terminal tool the agent could reach, it says the agent cannot run that command at all, scopes the damage to PDFs (every other attachment type is unaffected), and gives you the fix — add `terminal` to that list and restart Hermes. An absent `api_server` key needs nothing on its own: Hermes's own default carries the toolset. A bundle it has not enumerated, or YAML it cannot read, gets no claim either way. Narrowing that list by hand is where the toolset usually gets lost; see the recall entry under [Other endpoint gotchas](#other-endpoint-gotchas).
     - **`pdftotext` has to exist on the gateway host.** It ships by default almost nowhere: install poppler (`apt install poppler-utils`, `brew install poppler`). Setup prints a note when it cannot find `pdftotext` in its own shell — that shell isn't necessarily the agent's, so it is a hint, not a verdict — and it installs nothing either way.

     `pdftotext` also does no OCR, so a scanned PDF has no text layer to extract, and a password-protected one gives up nothing; in both cases the honest answer is that the text can't be read, which is what the block asks the agent for.
- **The agent says it saved/sent a file, but no download chip appears** — the agent delivered it as a channel-attachment directive (e.g. a `MEDIA:<path>` line), which the OpenAI-compatible endpoint strips; the directive is discarded and no file is ever written where Conduck looks. Conduck states one folder per turn, in the message itself, and reads exactly that folder when the reply lands — so a file written anywhere else, or written after the reply, is not offered for download however clearly the reply describes it. The rule (installed into `TOOLS.md` by the wizard, scoped to Conduck turns): **create the folder that turn's message names and write the file into it**, finishing before you reply, and never as a `MEDIA:` directive. That folder does not exist until the agent makes it, so an agent whose file tools can write a file but not create a directory is the other common shape of this symptom. Agent guidance loads at session start — test in a **new** conversation. Asking the agent to write the file again, into the folder named in that new turn's message, is the way to recover one that went astray; the folder is per-reply, so the name in the earlier turn is not the one to reuse.
- **Chat works everywhere, but attachments fail on a standalone Apple Watch** — the file lane rides a narrower rail than the gateway (say, a tailnet-only lane behind a public gateway). Expose both on the same rail; re-running the wizard reconciles the two.

## Setup code

`conduck-setup:v1:<base64(JSON)>` — same content in the QR and the paste string. Full contract in **[PAYLOAD.md](PAYLOAD.md)**.

It is a reusable credential, not a one-time invite: it carries your gateway token (and the file-server credential when a file lane is set up), so whoever holds it keeps that access until you rotate those secrets — see **[SECURITY.md](SECURITY.md#the-setup-code-is-a-secret)**.

## Reporting a problem

Security issues: see **[SECURITY.md](SECURITY.md)** (private vulnerability reporting — please don't open a public issue). Bugs and questions: open an issue.

## For contributors

The maintainable source is the numbered modules under [`src/`](src/), concatenated in `src/manifest.txt` order into the single `conduck-connect.sh` at the repository root. Edit a module, never the root script; CI rejects any drift between the two. [CONTRIBUTING.md](CONTRIBUTING.md) holds the invariants and the contracts shared with the app, and [AGENTS.md](AGENTS.md) is the short orientation for a contributor — human or AI — arriving cold.

**Release boundary.** The Quick start always downloads the latest *published* release, not `main`. This checkout's source is at `v0.15.0`. `main` may carry changes under **Unreleased** in [CHANGELOG.md](CHANGELOG.md) that are not in the published asset, and rebuilding or testing the artifact locally does not publish it — the [releases page](https://github.com/gigaduckai/conduck-connect/releases) is the authority on what is live. Every release artifact is plain, unminified shell that can be read before it runs.

## License

`conduck-connect` is © 2026 GigaDuck OÜ and licensed under the [Apache License 2.0](LICENSE). The one exception is the terminal QR renderer, which embeds the [Project Nayuki QR Code generator](https://www.nayuki.io/page/qr-code-generator-library) (Python), used unmodified under the MIT License with its license header preserved in-file; CI verifies that block against a pinned checksum and asserts it imports only the standard library. Both are recorded in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

The Conduck name isn't covered by the code license — see [TRADEMARKS.md](TRADEMARKS.md). Truthful references are always fine; just don't pass a modified fork off as the official `conduck-connect`.
