# WebDAV listing fixture corpus

A frozen set of WebDAV `207 Multi-Status` bodies with the verdict each one must
produce, and the safety net for the one piece of logic this connector and the
Conduck app both have to implement identically.

## Why this exists

Conduck never guesses the name of a file its agent produced. It **lists** the
folder the agent wrote into and offers what the listing holds. Both sides read
the same listing:

- the **app**, in `FileServerClient.parseListing` with its
  `StrictListingParserDelegate` and `resolveListingHref`
  (`Conduck/Conduck/Services/RemoteAgent/FileServerClient.swift`);
- **conduck-connect**, in the `STRICT_LISTING_MIRROR` reproduction of it
  (`src/41-agent-file-readiness.inc.sh`), which is what the wizard's agent
  sentinel and `check-adapter --files` grade a real server's answer with.

The connector's verdict is what **mints a setup code**. So a divergence is a
false certification in one direction or the other: a checker looser than the app
tells an operator their setup works and every real delivery then fails, and a
checker stricter than the app refuses a deployment the app reads perfectly.
Neither is a bug you find by reading two implementations side by side a year
apart — you find it when a user's file never arrives.

**These fixtures are the contract BOTH parsers must satisfy.** The shell suite
already runs the mirror against every one of them. The app side does not yet
have a test that reads this directory; adding one is the other half of the net,
and until it exists the Swift is checked by review alone.

The Swift is authoritative in every disagreement. When the app's listing rules
change, change these fixtures first, then both readers.

## Layout

- `manifest.tsv` — one row per case: `case`, `requested-url`, `wanted-entry`,
  `expected-verdict`, `parity`. Tab-separated; `#` starts a comment, and every
  row carries a comment above it saying what the case pins.
- `<case>.xml` — the response body for that case, **byte-exact and with no
  trailing newline**. Two of them sit exactly on the 256 KiB bound, so feed the
  file to the parser directly rather than through a shell variable, which would
  strip the trailing bytes. `.gitattributes` marks the directory `-text` so no
  checkout can rewrite a line ending and move a boundary.

## Verdict vocabulary

The connector's mirror prints one token. In app terms:

| Token | `FileServerListingVerdict` |
|---|---|
| `PRESENT` | `.entries` containing the wanted entry |
| `ABSENT` | `.entries` **not** containing it |
| `REFUSED:<reason>` | `.unusable(.<reason>)`, using `FileTransferListingRefusal`'s own case names |

`ABSENT` here never means the app's `.absent`, which only comes from an HTTP
`404` on the collection. Every fixture is a `207`, so the status gate is not
what any of them exercise; the app's `case 207: break` is where they start.

## The `parity` column

- **`app`** — both readers must return this verdict. Every case but one.
- **`mirror-stricter`** — a deliberate, documented one-way divergence: the
  connector refuses a body the app may accept. Only `entity-declaration` is
  marked this way, and only because refusing an entity declaration outright is
  fail-closed against billion-laughs while the app switches off external entity
  resolution and lets Foundation expand an internal one. A checker that refuses
  more than the client costs an operator a retry; one that accepts more mints a
  code for a lane that never delivers. There is no `app-stricter` value and
  there must never be one.

## Coverage

Each case's comment in `manifest.tsv` says what it pins. The load-bearing ones:

- **`proxy-stripped-prefix`** — a path-stripping reverse proxy (Caddy
  `handle_path`, nginx `proxy_pass` with a trailing slash) returns hrefs without
  the mount point. The match is anchored at the END of the requested path, so
  this deployment reads. `proxy-served-root` and `proxy-wrong-mount` pin the
  other side of that: a tail, never an empty match and never a subsequence.
- **`nested-response`** — a `<response>` below anything but `<multistatus>`
  refuses the whole body. Dropping it would report a file that exists as an
  empty folder, and past the grace window that stamps the turn done forever.
- **`nfc-nfd-collision`** — the two spellings of `café` are ONE name under
  Unicode canonical equivalence, which is what Swift string equality is. A
  folder holding both refuses as a duplicate.
- **Bounds** — `entries-at-cap` / `entries-over-cap`, `depth-at-limit` /
  `depth-over-limit`, `bytes-at-limit` / `bytes-over-limit`. Each bound is
  inclusive, and each is refused rather than truncated: a silently shortened
  listing looks complete, and the file that fell off it is simply never
  delivered.

## Adding a case

Write the body as `<case>.xml` with no trailing newline, add the row and its
comment to `manifest.tsv`, and run
`bash tests/run-file-lane-readiness-suite.sh`. The suite fails on an `.xml` the
manifest does not name and on a manifest row with no file, so neither half can
be added without the other.

Fixtures are public. Use the placeholder host, folder and names the corpus
already uses — never a real gateway URL, folder path, or credential.
