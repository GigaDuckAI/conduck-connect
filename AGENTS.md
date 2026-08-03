# Working in this repository

`conduck-connect` walks someone through pairing a self-hosted AI gateway with the
[Conduck](https://conduck.com) app, and carries two standalone diagnostics that
grade someone else's server against what the app needs. `README.md` is the user
manual and the best description of what the tool actually does.

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
