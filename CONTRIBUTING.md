# Contributing to conduck-connect

`conduck-connect` ships as one readable shell script that pairs a self-hosted AI
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

Sign-off is the one **branch-protection–required check**: a DCO bot verifies
every commit on a pull request, and `main` will not accept the merge until it
passes. CI (`static`, `connector-checks`) runs on every pull request and is
expected to be green — maintainers don't merge a red PR — but it is not
currently wired as a hard protection gate, so treat it as review policy rather
than a mechanical block. Forgot to sign off? `git commit --amend -s` fixes the
last commit;
`git rebase --signoff <base>` fixes a whole branch. Push the corrected history
and the check re-runs.

Rather than rely on remembering the flag, enable the tracked hook once per clone:

```
git config core.hooksPath .githooks
```

`.githooks/prepare-commit-msg` then adds the trailer for you. It is keyed on the
commit **author** (the person who can certify the change, and not always the
committer), skipped for merge and squash messages, and idempotent — so
`git commit -s` keeps working and never produces a duplicate line.

## Development baseline

The script runs on **Linux and macOS** and must stay **Bash 3.2-compatible** —
that is the `bash` macOS still ships, so no `declare -A`, no `${var^^}`, no
`mapfile`. Its hard requirements beyond a POSIX shell are `python3`, `curl`, and
`openssl`; the optional path tools it integrates — Tailscale, `cloudflared`,
`rclone` — it uses only when already present and never installs. Keep both lists
as they are (see invariants below).

The maintainable source lives in [`src/`](src/) and is assembled
deterministically into the checked-in `conduck-connect.sh` release artifact.
Edit the relevant `*.inc.sh` module, then run:

```bash
bash scripts/build-release.sh
bash scripts/build-release.sh --check
```

Never hand-edit only the generated artifact: CI rejects source/artifact drift.

## Running tests

- **`bash scripts/build-release.sh --check`** — proves the checked-in release
  artifact is byte-identical to the modular source.
- **`bash scripts/build-release.sh --map`** — prints `module -> start_line`.
  CI lints the generated artifact, not `src/*.inc.sh` (the modules
  share variables across file boundaries, so linting them standalone reports
  ~50 spurious "appears unused" findings). Use `--map` to translate a reported
  artifact line back to its module and offset.
- **`bash scripts/test-response-fixtures.sh`** — runs the generated script's
  pure reply evaluator against the vendored Apple-authoritative corpus.
- **`bash tests/run-checks-suite.sh`** — the adapter/server/command regression
  matrix, with no external dependencies.
  Run it before every PR; behavioral changes must keep it green and add or
  update cases for what changed.
- **`bash tests/run-check-adapter-rclone-integration.sh`** — optional, needs `rclone`
  installed. It proves the file-lane freshness check against a real WebDAV
  server; run it by hand when you touch the file lane.

CI runs the same suite on every pull request.

## Project invariants

These are the constraints the script exists to keep. A change that breaks one is
not a bug fix — it needs prior discussion in an issue.

- **One readable release artifact.** Users download and run only
  `conduck-connect.sh`. The repository source is modular, but the generated
  script never sources fragments or helpers at runtime. Keep the generated
  artifact plain, unminified, and byte-reproducible from `src/`.
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
- **No self-signed path, and no certificate pinning.** The connector will not set
  a user up on a certificate their devices do not already trust. Two independent
  reasons, and both are permanent: App Transport Security lets an Apple app make
  certificate evaluation stricter and never looser, so the app refuses such a
  gateway below its own code; and the pairing payload carries no certificate
  field by design, because a setup code is entirely attacker-supplied — a pin is
  something a human types into the app, never something a tool hands it. So the
  "I already run my own HTTPS" answer is a **gate**, not a preference: it
  verifies, and on failure it stops and names the three free routes to a trusted
  certificate. There is no accept-anyway override, and one cannot be added. The
  suite asserts the released artifact carries no pinning symbol and no
  `selfsigned` transport, and that a saved profile naming either is filtered out
  of the menu rather than offered and then failing — while requiring both
  certificate-diagnosis helpers to survive, so a refusal is always explained.

## Protocol changes need prior discussion

Several things in this script are a contract shared with the Conduck app, and
the two must not drift independently. Open an issue before changing any of them:

- the **`conduck-setup:v1`** pairing payload (see `PAYLOAD.md`);
- the adapter/server **`[CHECK_ID]`** verdict identifiers;
- the **machine-summary schemas** (`CONDUCK_CHECK_ADAPTER schema=3 …`,
  `CONDUCK_CHECK_SERVER schema=2 …`) that build scripts parse. The grammar is
  frozen per schema number — field order, names, and enum values included — so
  *any* change to it, renaming the prefix included, must bump `schema=`;
- **URL normalization**, which is pinned to the app's own fixtures;
- any current-Apple-app request/body acceptance rule used by
  `--check-server`. This parity is scoped to the directly addressed endpoint:
  diagnostics intentionally do not follow redirects or forward credentials to
  `Location` targets. Android is still work in progress and is not the
  compatibility authority yet. Reply-shape changes start in the versioned
  Apple corpus; the connector and Android vendor byte-identical snapshots.

## Pull requests

- Keep PRs **small and focused** — one change per PR reviews and lands faster.
- In the description, say what a **user sees differently** after the change, not
  just what the code does.
- **Add or update tests** where behavior changes; keep `run-checks-suite.sh`
  green.
- Rebuild `conduck-connect.sh` after every source edit and keep
  `build-release.sh --check` green.
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

A version lives in **three** places and the release workflow refuses the tag
unless all three agree: `VERSION` in `src/00-cli.inc.sh` (rebuild the artifact
after changing it), the `## [x.y.z]` heading in `CHANGELOG.md`, and the
`source is at` line in the **Release boundary** paragraph of `README.md`. The
README one is the easiest to forget and the tag fails on it, not on the push.

## Bugs, questions, and security

- **Bugs:** open a [GitHub issue](../../issues) using the bug form. Include the
  script version, your OS and shell, and the machine-summary line if a server or
  adapter check is involved.
- **Questions and setup help:** the [Discord](https://conduck.com/discord/) is
  usually faster.
- **Security vulnerabilities:** never in a public issue. See
  [SECURITY.md](SECURITY.md) for how to report privately.

## License and trademarks

Contributions are licensed under the **Apache License 2.0**, the repository's
license. The Conduck™ name and the duck-character brand artwork are trademarks
and brand assets of GigaDuck OÜ and are **not** covered by that license.
