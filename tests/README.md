# tests/ — the conduck-connect regression harness

Loopback-only, stdlib-only fixtures and drivers for developing `conduck-connect.sh`.
No network, no real gateway, nothing installed — except where a file says otherwise.

Nothing here needs anything the program itself does not: `bash` (3.2 — this is
macOS's system shell, so no `declare -A`, no `${var^^}`, no `mapfile`), `python3`,
`curl`, `openssl`. One script is the exception and says so.

**No test may read or write your real state.** Every profile this tool saves lives
in `$XDG_CONFIG_HOME/conduck` (`~/.config/conduck` by default), and a stray
`--setup` or `--forget` there destroys a working pairing. The suites isolate
themselves, but if you run the script by hand while debugging, do this first:

```bash
export XDG_CONFIG_HOME="$(mktemp -d)"
```

`--setup --dry-run` and `--list` change nothing and are always safe.

| File | What it is |
|---|---|
| `../scripts/build-release.sh --check` | Proves the modular source assembles byte-for-byte into the checked-in single-file release artifact. |
| `../scripts/test-response-fixtures.sh` | Runs `app_chat_body_eval` from the generated artifact across every case in the vendored Apple-authoritative response corpus. |
| `fixtures/converse-response-v1.json` | Byte-identical snapshot of the public Apple corpus named by its embedded canonical URL/revision metadata. CI consumes it locally; no network fetch or Android authority is involved. |
| `run-checks-suite.sh` | Adapter, server, menu, and direct-command regression suite. It proves strict adapter checks, current Apple response-decoder behavior, interactive PASS→setup handoff, the exit-status split, hardened direct diagnostic transport, exact failed `[CHECK_ID]` sets, and both machine-summary grammars. It also carries the security-review guards — see [below](#the-security-review-guards). |
| `run-file-lane-readiness-suite.sh` | Focused setup-time file-lane regressions: structural systemd/plist reuse, stable collision-free per-gateway ports, control-safe credentials/paths, lossless fail-closed Hermes YAML, authenticated loopback service gating, app-parity reply discovery, reply-boundary/timeout handling, post-delete file+directory proof, and exact-name EXIT cleanup. Its loopback adapter fixtures prove the wizard's control flow and false-green rejection for the OpenClaw/Hermes prompt shapes; they are not evidence about a real OpenClaw or Hermes runtime. It is also run by the full checks suite. |
| `run-host-environment-suite.sh` | The paths that only fire on a host that is MISSING something — a required tool, a reachable systemd user manager, lingering, or the rights Tailscale wants. No CI runner and no developer Mac reproduces those, so each case lifts the real function and runs it against a simulated host. It also owns the welcome menu's numbering and the `--show-code` profile picker. It is run by the full checks suite. |
| `run-check-adapter-rclone-integration.sh` | Non-hermetic companion: proves the `--files` freshness check against a REAL `rclone serve webdav` (the one place the actual rclone dir-cache bug reproduces end to end). Requires `rclone` on PATH — a missing rclone is a hard exit 2, never a silent skip. |
| `fixture-adapter.py` | Known-good / deliberately-broken mock adapter the suite drives both checks against. |
| `fixture-webdav.py` | Minimal WebDAV-ish file server for the `--files` cases. Not a production server. |
| `fixture-canary.py` | Contract-conformant adapter that can hold a response silently for a per-turn delay, then reply deterministically — for measuring whether an exposure rail (reverse proxy / tunnel) kills long silent HTTP responses, the shape of a real agent turn. |
| `pty-run.py` | Runs one command inside a real PTY and feeds it a fixed input sequence: `pty-run.py <timeout-seconds> <input> <command> [args...]`. **A hard dependency of `run-checks-suite.sh`**, not an optional convenience — the script offers the PASS→setup handoff only to a genuine interactive terminal, so those cases cannot be driven by a pipe. A timeout kills the child and appends `PTY TIMEOUT` to the captured output rather than hanging the suite. |

## The prompt contract, and what a test may assert about it

Every prompt in the tool offers the same three controls, and shows the ones it
actually honours: `i` explains the question and asks it again, `b` goes back
where the caller can honour that, `q` stops the run.

The five value primitives (`ask`, `ask_default`, `ask_secret`, `ask_url`,
`require_choice`) are all read by their callers with `$(…)`, and that single fact
shapes everything a test can say about them. The ANSWER has to travel on stdout,
so the INTENT travels on the **exit status**:

| status | meaning |
|---|---|
| `0` | the value is on stdout |
| `10` | the user pressed `b` — reachable only where the caller passed allow-back |
| `11` | the user pressed `q` — the CALLER stops the run |
| `1` | EOF / no answer — the caller dies with `$NO_ANSWER` |

**There is no sentinel string.** A primitive never echoes a literal `q`, and a
test must never assert one: `q` is also a legitimate answer somebody could type,
and stdout is where the value lives. On a control key the primitive writes
**nothing** to stdout and returns the status above. Asserting the status *and*
the empty stdout is the pair that pins this down — `run-file-lane-readiness-suite.sh`'s
`test_shared_folder_prompt` is the worked example.

`prompt_into <variable> <primitive> [args…]` is the caller side, and it exists for
one reason a test has to protect: **a `quit_run` inside `$(…)` kills only the
subshell**, and the wizard then walks on with an empty answer past a stop the
operator asked for. `prompt_into` runs the primitive, assigns the answer to the
named variable in the CALLER's shell, and acts on `q` and on EOF there, where it
counts. `test_folder_prompt_quit_reaches_its_caller` asserts exactly that: the
line after the prompt must not run, and the caller must leave with the stop
status. Assert both — a marker in a transcript does not say which shell printed
it, and a status that escapes the caller can only have come from the caller.

`confirm` and `print_and_wait` are not captured, so they keep acting on `q`
themselves.

## The lift lists are load-bearing, and they fail SILENTLY

`run-file-lane-readiness-suite.sh` and `run-host-environment-suite.sh` do not run
the whole program. Each builds a minimal runtime: it `source`s a few modules and
**lifts** named functions out of the others with

```bash
sed -n "/^some_function()/,/^}/p" "$ROOT/src/10-utilities.inc.sh"
```

so a failure keeps pointing at the source file that owns the behaviour, and the
suite is not forced to stand up the CLI and global state it deliberately replaces.

The cost is a failure mode with no symptom. When shipped code grows a call to a
helper that no lift list names, that call is `command not found`: exit status 127,
no output — and because nearly every harness here runs its subject inside
`$( … 2>&1 )`, even the shell's complaint lands in a captured variable instead of
on your screen. **The assertion after it then passes or fails for no reason at
all.** A vacuous green is worse than a red, because nobody goes looking for it.

It can be worse than vacuous. `setup_file_lane`'s folder loop re-asks until it has
an absolute path; with `prompt_into` unlifted it assigned nothing, re-asked
forever, and buried the evidence in a command substitution — the suite did not
fail, it consumed memory until bash died in `xrealloc`, and every case after that
point silently never ran.

So both suites now carry a **tripwire**. After the lifts, every function defined
in `src/` that the suite's shell does not define is given a stub that records its
own name and returns 127 — byte for byte what the missing function already did, so
nothing about a run changes except that the gap becomes visible. A case that stubs
a function itself shadows the tripwire, which is the correct reading: there, it IS
defined. `report_undefined_lifts` runs last and fails the suite with the exact
names to add.

Two consequences worth knowing:

- **Adding a call in `src/` can turn an auxiliary suite red.** That red is the
  feature. Add the function to the relevant lift list, or stub it deliberately
  with a comment saying why — `run-host-environment-suite.sh` does the latter for
  the exposure record files, which no case there grades.
- **A lift takes the definition line through the first column-0 `}`.** One-liner
  helpers that sit between two such lines come along for the ride, and
  `run-host-environment-suite.sh` asserts by name that the ones it depends on
  arrived. Reformatting a deliberate one-liner in `src/` into a multi-line
  function truncates somebody's lift.
- **The tripwire only sees functions defined at column 0** in `src/*.inc.sh`,
  which is where they all live. It errs toward missing a gap rather than
  inventing one.

## Every HTTP fixture binds without reverse-resolving

`http.server`'s `server_bind()` calls `socket.getfqdn()` on the bind address, and
each fixture prints its `READY <port>` line only after that returns. On a host with
no reverse zone for `127.0.0.1` the lookup blocks until the resolver gives up —
around 20 seconds on GitHub's macOS runners — so the suite stops waiting for READY
while the fixture is still alive and silent, and every case that needs one fails
for a reason nothing prints. Each fixture therefore subclasses its server and
overrides `server_bind` to skip the lookup; `server_name` is read only by the CGI
handlers, which none of these use. The `fixtures-do-not-reverse-resolve-their-bind`
case enforces this across the tree.

## The security-review guards

`run-checks-suite.sh` carries these alongside its functional cases. Each is
written as a rule about the *released artifact* rather than about one call site,
and each was verified to fail against a pre-fix build — a guard never seen to
bite is not evidence of anything.

- **The saved profile carries no secret.** `write_profile` is driven with sentinel
  values in `GW_TOKEN`/`FS_CRED`, and neither may appear anywhere under the state
  directory. A control run against a deliberately leaking copy of the same function
  proves the check still bites, so a guard that stopped working fails the suite
  instead of passing quietly.
- **Gateway-supplied text cannot forge a `[CHECK_ID]` transcript line or emit
  ANSI.** The remote end must not be able to write the verdict.
- **Both URL entry points refuse `user:password@`.**
- **Dotenv-sourced gateway ports are validated** before they reach a shell command.
- **The `--files` transport probes live in one `mktemp -d`**, not in sibling names
  concatenated onto a `mktemp` file.
- **"I already run my own HTTPS" is a trust gate, not a question.** The shipped
  `classify_own_https` is driven through its accept arm and every refusal arm. It
  must stop, offer no accept-anyway override, and name the three free routes to a
  trusted certificate. Separately, the artifact is asserted free of every pinning
  symbol while still carrying both certificate-diagnosis helpers.
- **A permission change to a config this tool did not create stays behind the
  announce-then-confirm gate.** Both non-success arms — declined, and
  chmod-failed-after-yes — must still warn that the credential is exposed rather
  than going quiet.
- **`$STATE_DIR` has exactly one creator** (`ensure_state_dir`), which makes a
  fresh one `0700` in silence and reports an already-open one once, naming the
  exact `chmod 700`. Without that, an upgraded box's credential listing stays
  world-readable and unmentioned.
- **Every curl to a literal loopback URL carries `--noproxy`.**

## Running them

From the repo root:

```bash
bash tests/run-checks-suite.sh                       # everything; chains the three below at its tail
bash tests/run-host-environment-suite.sh             # seconds
bash tests/run-file-lane-readiness-suite.sh          # minutes — real fixtures, real waits
bash tests/run-check-adapter-rclone-integration.sh   # needs rclone on PATH
```

### One case at a time

`run-checks-suite.sh` takes case names as arguments and runs only those:

```bash
bash tests/run-checks-suite.sh signal-cleanup
bash tests/run-checks-suite.sh menu-q-exit menu-action-1-setup
bash tests/run-checks-suite.sh file-lane-readiness   # the chained suite, on its own
```

The name is the one printed after `SUITE ✓` / `SUITE ✗`. This is how you diagnose
a suspected flake — re-run the single case and watch it, rather than re-running a
twenty-minute suite to look at one line of it.

The two auxiliary suites take no arguments of their own; each is one file and runs
whole. `run-host-environment-suite.sh` finishes in seconds, so run it after any
change to the menu, the profile picker, or a host-detection path.

### `signal-cleanup` is the known flake, and it has a mechanism

It interrupts an adapter check mid-turn and asserts the run leaves with exit 130
and cleans up after itself. To do that faithfully it puts the check in its OWN
process group (`set -m`) and sends `SIGINT` to the group, the way a real Ctrl-C
does — signalling only the bash PID would leave the blocked `curl` running and
defer the trap.

That machinery is what makes it fragile, and the failure it produces is
misleading: `exit 0, expected 130 (SIGINT)`, under a transcript showing a
perfectly healthy 23/23 green run. It reads like the cleanup broke. It usually
means the signal never landed.

**Never conclude anything from a lone red `signal-cleanup`.** Re-run it alone,
**in the foreground of your own terminal** — not backgrounded from a wrapper
script, not under a timeout harness, not while a parallel fleet is loading the
machine. Job control behaves differently for a suite that is itself a background
job, and the case then reports a broken cleanup that is not broken. Measured: it
fails when launched as a background job of another script and passes immediately
when run in the foreground, with no change to anything it tests.
