## Summary

<!-- What changes, and what a user sees differently afterward. -->

## Linked issue

<!-- e.g. Closes #123. For anything large — new gateway support, a refactor, a protocol change — discuss in an issue first. -->

## Checklist

- [ ] Commits are signed off with `git commit -s` (DCO 1.1, no CLA) — see [CONTRIBUTING.md](https://github.com/gigaduckai/conduck-connect/blob/main/CONTRIBUTING.md#sign-off-your-commits-dco).
- [ ] `bash tests/run-doctor-suite.sh` passes.
- [ ] Tests added or updated where behavior changed.
- [ ] README.md / SECURITY.md / WHAT-IT-TOUCHES.md updated if privilege, network, or persistent-state behavior changed.
- [ ] No secrets in the diff or description — pairing codes, bearer tokens, gateway URLs, file-lane credentials.
- [ ] No new runtime dependencies (beyond `bash`/`python3`/`curl`/`openssl`) without prior discussion.
- [ ] Docs stay present-tense.
