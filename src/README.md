# Connector source

These files are the maintainable source for `conduck-connect.sh`. They are
concatenated, byte for byte and in `manifest.txt` order, by
`scripts/build-release.sh`, which additionally stamps one `GENERATED FILE`
banner line into the artifact. The banner is emitted by the builder rather than
stored here, so no source module can be mistaken for the generated output; it
sits just past the header block so `--help` never prints it.

The generated root script remains the only runtime and release artifact:

- users download one plain-text file;
- it never sources repository files at runtime;
- the checked-in artifact stays readable and diffable;
- CI rejects any source/artifact drift.

Edit the relevant `*.inc.sh` module, then run:

```bash
bash scripts/build-release.sh
bash scripts/build-release.sh --check
```

The fragments are not standalone programs. Parse, lint, test, checksum, and
release the generated `conduck-connect.sh`.

`80-pairing.inc.sh` intentionally contains the large, unmodified vendored
Project Nayuki QR encoder. Its pinned integrity check still runs against the
generated artifact.
