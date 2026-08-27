# Working in this repository

`conduck-connect` walks someone through pairing a self-hosted AI gateway with the
[Conduck](https://conduck.com) app, and carries two standalone diagnostics that
grade someone else's server against what the app needs. `README.md` is the
public overview and quick start; `MANUAL.md` is the exhaustive operator manual
and the best description of what the tool actually does.

**Never edit `conduck-connect.sh`.** The file at the repository root is a
generated artifact. The maintainable source is the numbered modules under `src/`,
concatenated in `src/manifest.txt` order — edit a module, then run
`scripts/build-release.sh` followed by `scripts/build-release.sh --check`. CI
rejects any drift between the two, so an edit made directly to the root script is
reverted by the next build. `src/README.md` explains why the release stays one
plain file.

There is no separate architecture document, and there should not be:
`src/manifest.txt` is the map, every module opens with a header comment giving
its job and its reasons, and `CONTRIBUTING.md` holds the invariants and the
contracts shared with the app.

---

# For AI tools driving this script

This section is for an AI coding tool that has been asked to *run*
`conduck-connect` on somebody's machine, rather than to change it. Read it before
you run anything: some of this tool is fully scriptable, and one central part of
it structurally is not.

## The one thing you cannot do

**`--setup` ends in a QR code a human scans with a phone. A machine cannot
finish it.** This is not a missing flag and there is no `--yes`. The last step of
a successful setup is a QR code (and the same string as text) that the person
imports into the Conduck app on an iPhone, iPad or Mac. Nothing you can do in a
terminal completes that.

There is also no non-interactive answer mode for the *wizard*: its prompts cannot
be piped in, it has no answer flags, and its whole safety model is one explicit
consent per change to the machine. If you drive it through a PTY you will still
stop at the QR.

So do not attempt it. Hand your operator the command instead:

```bash
bash conduck-connect.sh --setup
```

and tell them it ends in a QR code to scan with the Conduck app. If you run it
anyway with no terminal, it exits **4** and prints the same explanation.

**The setup CODE is a different question, and that one you can answer.** What a
machine cannot do is walk a person through configuring and verifying a host. If
you already know the gateway's address, its key and its model — the normal case
when you just built the thing — `--emit-code` prints the code itself, with no
terminal and no saved setup, and it is the same code `--setup` would have
printed. Reach for it instead of hand-assembling the base64 from `PAYLOAD.md`.

## What you *can* run

Four commands are fully machine-drivable. All four finish without a person.

```bash
# Grade a server that was NOT built for Conduck against the app's wire protocol
CI=1 CONDUCK_TOKEN="$TOKEN" bash conduck-connect.sh --check-server https://gw.example.com

# Grade a server that WAS built for Conduck against the adapter contract
CI=1 CONDUCK_TOKEN="$TOKEN" bash conduck-connect.sh --check-adapter http://127.0.0.1:8080

# Print ONE setup code for a gateway you describe on the command line
CONDUCK_TOKEN="$TOKEN" bash conduck-connect.sh --emit-code \
  --url https://gw.example.com --name "My adapter" --model my-model

# What this machine already has set up, as one JSON object
bash conduck-connect.sh --list --json
```

- **`CI=1` is required for the two checks in any unattended context.** Without
  it, a check that *passes* in an interactive terminal goes on to ask whether the
  operator wants to continue into setup — after it has already printed `exit=0`.
  An automated caller that has read the summary and is waiting for the process to
  end waits forever. `CI=1` makes the machine summary the last thing printed.
  It accepts `1`, `true` or `yes`.
- **`--list --json` needs no terminal and no `CI=1`.** It reads files, changes
  nothing, and prints no token, no password and no setup code. It is how you find
  the id that `--edit` and `--forget` want. Its top-level `schemaVersion` is the
  number to pin.
- **`--emit-code` is how a machine produces a setup code.** It needs no
  terminal, reads no saved setup, sends no request and writes nothing, so it works
  on a build rig before the gateway is exposed — and it goes through the same
  payload builder `--setup` does, so the code is byte-identical to the one the
  wizard would print for the same gateway. `--url` is required and is held to the
  same address rule the app applies on import. The key rides `CONDUCK_TOKEN`;
  for a gateway that genuinely has none, say so with `--keyless` (or the
  set-but-empty `CONDUCK_TOKEN` that means the same thing everywhere else here) —
  an *unset* variable is never read as keyless. `--files-url` plus
  `CONDUCK_FILES_PASS` add a file lane, both or neither. Stdout is exactly the
  `conduck-setup:v1:…` string, so `$(…)` around it captures a usable value; the
  one warning it prints goes to stderr. **The code carries the gateway key** —
  treat every copy of it, and every log it lands in, as the key itself.
- **Both checks send real requests** to the address you give them: real model and
  chat turns that may consume paid quota and land in that server's own history.
  `--check-adapter --files` additionally writes and removes named files in the
  configured shared folder. Neither check changes host configuration.
- **Both checks are SLOW, legitimately.** Each real turn waits up to five
  minutes, so budget roughly 20 minutes for `--check-server`, 25 for
  `--check-adapter`, 30 with `--deep` and 35 with `--files`. A turn in flight
  prints a heartbeat line to **stderr** every 30 seconds, which is how a
  redirected run tells slow apart from wedged. Do not kill a quiet run that is
  inside those bounds; read the heartbeat instead.

Everything else needs a person. `--setup`, `--edit`, `--forget` and the
no-argument welcome menu detect that nobody can answer and exit **4** with their
own reason, rather than hanging. `--show-code` is the exception in form only. It never
stores a gateway token, so for a custom gateway it asks for it again at a hidden
prompt, and with nobody to answer it fails there with **1** instead of refusing
up front. It is also not a shortcut around setup: it re-emits exactly what the
saved profile holds, and it runs live verification, which spends at least two real
chat turns — a text round-trip and a photo turn — plus one more whenever a file
lane is configured.

That photo turn is the second way `--show-code` stops with nobody at the keyboard,
and unlike the token prompt it can happen on a gateway whose credentials are all
on disk. If the gateway answers a picture without reading it back, twice, the run
has found the one failure the app cannot report later — and that is a decision, so
it asks. With no terminal to ask on it stops with **1** and no code rather than
printing a question into a log. There is no flag that answers it: what the run
would go on to print is a QR code a person scans with a phone, so re-running it
where somebody can answer is the whole recovery. Hand the command to your operator.

## Credentials

**Pass the bearer token in `CONDUCK_TOKEN`, never on the command line** — `argv`
is visible to every process on the host via `ps`. There is no `--token` flag, for
that reason.

For a target with no authentication at all, export `CONDUCK_TOKEN=` **empty**.
That is an explicit keyless declaration. Leaving it unset where no prompt is
possible fails fast instead of grading the target as keyless — a silently assumed
keyless run grades the wrong thing and calls it a pass.

`CONDUCK_CHECK_SERVER_MODEL` (`--check-server` only) names the model to grade.
Without it, the named-model checks take whichever id `/v1/models` happens to list
first, which has nothing to do with what you intend to use.

## Exit status

| Status | Meaning | What a wrapper should do |
|---|---|---|
| `0` | The action succeeded, or the check passed | Continue |
| `1` | A setup/runtime failure, or a completed check that failed | Read the summary meters; the failure is real |
| `2` | Command-line usage error — unknown or retired flag, incompatible flags, an extra positional argument, an invalid URL | Fix your invocation; nothing ran |
| `3` | **A person stopped the run before it finished** | Not a failure of the target. Do not retry unattended |
| `4` | **This action needs a person at a terminal** | Stop and hand the command to your operator |
| `128+signal` | Interrupted by HUP/INT/TERM | — |

`3` and `4` are the two a naive wrapper gets wrong. Treating `3` as success
reports an abandoned setup as a completed pairing; retrying `4` in a loop
achieves nothing, because no number of retries produces a terminal.

## The machine summaries

Each check prints exactly one summary line, and in a non-interactive run
(including any run under `CI=1`) it is the **last** line. Consume it with
`tail -1`, key on the prefix and the `schema=` number, and ignore a line whose
schema you do not know.

```
CONDUCK_CHECK_SERVER  schema=2 harness=… wire=… models=… chat=… … exit=…
CONDUCK_CHECK_ADAPTER schema=4 contract=v1 revision=… profile=… core=… … exit=…
```

**The key/value domains are published inside the script itself, and that is the
copy of record — read them there, not here.** They live in a comment block above
each summary function, because the one artifact you are guaranteed to have is the
file you downloaded:

- `--check-server`, `schema=2` → the comment block above `compat_summary` in
  [`src/70-check-server.inc.sh`](src/70-check-server.inc.sh)
- `--check-adapter`, `schema=4` → the comment block above `doctor_summary` in
  [`src/61-check-adapter-files.inc.sh`](src/61-check-adapter-files.inc.sh)

Both blocks also state the two rules that matter most to a retry loop, in full:
what `NOT_RUN` means versus `NOT_REQUESTED`, and why `checks=` and `failed=` are
never to be keyed on as absolute numbers. Restating those domains in this file
would guarantee the two drift at the next schema bump, so this file does not.

## Etiquette on somebody else's machine

- **Never invent an answer to a prompt.** If a command stops to ask, that is the
  design working; report the question to your operator.
- **`--setup --dry-run` is the safe way to find out what a real run would do** on
  this host. It sends no requests, mints no credentials, prompts for no secrets,
  and emits no setup code — and it ends by printing the exact command that would
  run it for real.
- **`--forget <id>` is irreversible and needs a terminal.** It is confirmed by
  typing the id, deliberately not by pressing Enter, so there is no unattended
  form of it. `--list` is the read-only half.
- **`WHAT-IT-TOUCHES.md` is the exhaustive list** of every file, service and port
  the tool reads or changes, with the undo for each. Cite it to your operator
  rather than paraphrasing it.
