# Contributing to conduck-connect

`conduck-connect` is one readable shell script that pairs a self-hosted AI
gateway with the [Conduck](https://conduck.com) app. Contributions are welcome:
bug fixes, clearer diagnostics, new gateway support, tests, and documentation
improvements alike. Thanks for taking the time.

## Sign off your commits (DCO)

This repository enforces the [Developer Certificate of Origin 1.1](https://developercertificate.org/).
Every commit must carry a `Signed-off-by` line, added with:

```
git commit -s
```

By signing off you certify the DCO — in short, that you wrote the change or
otherwise have the right to submit it under the repository's license
(Apache-2.0). That's the whole agreement: there is **no CLA** and no copyright
assignment.

Sign-off is a **required check** — a DCO bot verifies every commit on a pull
request, and the branch will not merge until it passes (alongside CI). Forgot to
sign off? `git commit --amend -s` fixes the last commit;
`git rebase --signoff <base>` fixes a whole branch. Push the corrected history
and the check re-runs.

## Development baseline

The script runs on **Linux and macOS** and must stay **Bash 3.2-compatible** —
that is the `bash` macOS still ships, so no `declare -A`, no `${var^^}`, no
`mapfile`. Its hard requirements beyond a POSIX shell are `python3`, `curl`, and
`openssl`; the optional path tools it integrates — Tailscale, `cloudflared`,
`rclone` — it uses only when already present and never installs. Keep both lists
as they are (see invariants below). Edit `conduck-connect.sh` directly — there
is no build step.

## Running tests

- **`bash tests/run-doctor-suite.sh`** — 76 checks, no external dependencies.
  Run it before every PR; behavioral changes must keep it green and add or
  update cases for what changed.
- **`bash tests/run-doctor-rclone-integration.sh`** — optional, needs `rclone`
  installed. It proves the file-lane freshness check against a real WebDAV
  server; run it by hand when you touch the file lane.

CI runs the same suite on every pull request.

## Project invariants

These are the constraints the script exists to keep. A change that breaks one is
not a bug fix — it needs prior discussion in an issue.

- **One readable main script.** The whole tool is `conduck-connect.sh`, meant to
  be audited before it is run. Keep it readable; don't split it into sourced
  fragments or an opaque helper.
- **Zero telemetry.** The script's only outbound requests go to the user's own
  gateway and file lane. It never phones home; there is no GigaDuck server.
- **No silent privilege elevation.** Any `sudo` is shown in full first and runs
  only after an explicit confirmation — and several paths just print the command
  for the user to run themselves. The script never elevates silently or runs a
  command the user hasn't seen.
- **No new runtime dependencies** beyond `bash`/`python3`/`curl`/`openssl`
  without prior discussion. Every dependency is a host the user must already
  have; additions are deliberate.
- **Secrets never appear** in issues, test output, fixtures, or commits.
  Pairing codes (`conduck-setup:...`), bearer tokens, gateway URLs, and
  file-lane credentials are all secrets — a pairing code alone grants full
  access to the user's agent. Tests and fixtures use placeholders.
- **The vendored Nayuki QR block is third-party** (Project Nayuki, MIT) and
  stays **unmodified**. CI verifies it against a pinned checksum and asserts it
  imports only the Python standard library; a change there fails the build.

## Protocol changes need prior discussion

Several things in this script are a contract shared with the Conduck app, and
the two must not drift independently. Open an issue before changing any of them:

- the **`conduck-setup:v1`** pairing payload (see `PAYLOAD.md`);
- the doctor and compat **`[CHECK_ID]`** verdict identifiers;
- the **machine-summary schemas** (`CONDUCK_DOCTOR schema=2 …`,
  `CONDUCK_COMPAT schema=1 …`) that build scripts parse;
- **URL normalization**, which is pinned to the app's own fixtures;
- any behavior the app **mirrors** — its Test Connection probe and reply
  decoder, which `--compat` reproduces exactly.

## Pull requests

- Keep PRs **small and focused** — one change per PR reviews and lands faster.
- In the description, say what a **user sees differently** after the change, not
  just what the code does.
- **Add or update tests** where behavior changes; keep `run-doctor-suite.sh`
  green.
- Update **README.md**, **SECURITY.md**, and **WHAT-IT-TOUCHES.md** whenever the
  script's **privilege, network, or persistent-state** behavior changes — those
  docs are the audit surface and must stay accurate.
- Keep the docs in **present tense** — they describe the current design, not the
  history of changes.
- Sign off every commit (see above).

For anything large — new gateway support, a refactor, a protocol change — please
open an issue to discuss the direction first. It protects your time.

## Releases

Maintainers own **versioning, tags, and releases**. Don't bump `VERSION` or add
a `CHANGELOG.md` release heading in a feature PR unless a maintainer asks — the
release is cut separately, with the checksum and license files it ships beside
the script.

## Bugs, questions, and security

- **Bugs:** open a [GitHub issue](../../issues) using the bug form. Include the
  script version, your OS and shell, and the machine-summary line if a doctor or
  compat run is involved.
- **Questions and setup help:** the [Discord](https://discord.gg/HqVwTmM7) is
  usually faster.
- **Security vulnerabilities:** never in a public issue. See
  [SECURITY.md](SECURITY.md) for how to report privately.

## License and trademarks

Contributions are licensed under the **Apache License 2.0**, the repository's
license. The Conduck™ name and the duck-character brand artwork are trademarks
and brand assets of GigaDuck OÜ and are **not** covered by that license.
