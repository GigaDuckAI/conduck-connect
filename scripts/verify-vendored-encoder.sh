#!/usr/bin/env bash
#
# Verify the vendored Project Nayuki QR encoder embedded in conduck-connect.sh:
#   1. its bytes match a pinned checksum (no silent drift), and
#   2. it imports only the Python standard library (no network / file / process deps).
#
# Run from the repo root:  bash scripts/verify-vendored-encoder.sh
#
# If you intentionally update the embedded block, re-pin with:
#   bash scripts/verify-vendored-encoder.sh --print > scripts/vendored-encoder.sha256
# and review the diff of the block carefully before committing.
set -u -o pipefail

SCRIPT="${SCRIPT:-conduck-connect.sh}"
PIN_FILE="${PIN_FILE:-scripts/vendored-encoder.sha256}"
MARKER="CONDUCK_QR_PY"

[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found (run from the repo root)"; exit 1; }

# Extract the heredoc body strictly between the two MARKER lines (opener + closer).
extract_body() {
  awk -v m="$MARKER" '
    $0 ~ m { c++; if (c==1) { f=1; next } if (c==2) { f=0 } }
    f { print }
  ' "$SCRIPT"
}

sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  else shasum -a 256 | awk '{print $1}'; fi
}

body="$(extract_body)"
[ -n "$body" ] || { echo "FAIL: could not extract the $MARKER block from $SCRIPT"; exit 1; }
got="$(printf '%s\n' "$body" | sha256_stdin)"

# --print: emit the current checksum (used to (re-)pin) and exit.
if [ "${1:-}" = "--print" ]; then echo "$got  vendored-encoder"; exit 0; fi

[ -f "$PIN_FILE" ] || { echo "FAIL: $PIN_FILE not found"; exit 1; }
want="$(awk '{print $1}' "$PIN_FILE")"
if [ "$got" != "$want" ]; then
  echo "FAIL: vendored encoder checksum drift"
  echo "  expected: $want"
  echo "  got:      $got"
  echo "  If this change is intentional, re-review the block and update $PIN_FILE (see header)."
  exit 1
fi

# stdlib-only imports, parsed with Python's ast so docstrings/comments can't false-trigger.
# Body is passed via env (not stdin) so the heredoc program and the body don't both claim stdin.
CONDUCK_QR_BODY="$body" python3 - <<'PY' || exit 1
import ast, os, sys
ALLOWED = {"__future__", "collections", "itertools", "re", "typing",
           "os", "sys", "base64", "json", "binascii", "math", "unicodedata"}
tree = ast.parse(os.environ["CONDUCK_QR_BODY"])
bad = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        for n in node.names:
            bad |= ({n.name.split(".")[0]} - ALLOWED)
    elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
        bad |= ({node.module.split(".")[0]} - ALLOWED)
if bad:
    print("FAIL: vendored encoder imports outside the stdlib allowlist:", ", ".join(sorted(bad)))
    sys.exit(1)
print("OK: vendored encoder matches the pinned checksum and imports only the standard library.")
PY
