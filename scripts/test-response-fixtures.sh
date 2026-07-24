#!/usr/bin/env bash
#
# Exercise the generated script's pure response-body evaluator against the
# byte-for-byte vendored Apple-authoritative compatibility corpus.

set -euo pipefail

test_script_dir=$(
  unset CDPATH
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
  pwd
)
test_repo_dir=$(
  unset CDPATH
  cd -- "$test_script_dir/.."
  pwd
)
artifact="$test_repo_dir/conduck-connect.sh"
fixtures="$test_repo_dir/tests/fixtures/converse-response-v1.json"

[ -f "$artifact" ] || {
  printf 'FAIL generated artifact is missing: %s\n' "$artifact" >&2
  exit 1
}
[ -f "$fixtures" ] || {
  printf 'FAIL response fixture corpus is missing: %s\n' "$fixtures" >&2
  exit 1
}

body_evaluator=$(sed -n '/^app_chat_body_eval()/,/^}/p' "$artifact")
[ "$(printf '%s\n' "$body_evaluator" | grep -c '^app_chat_body_eval()')" = "1" ] || {
  printf 'FAIL could not isolate app_chat_body_eval from generated artifact\n' >&2
  exit 1
}
eval "$body_evaluator"

fixture_count=0
fixture_failures=0
fixture_rows=$(mktemp "${TMPDIR:-/tmp}/conduck-response-fixtures.XXXXXX")
cleanup_fixture_rows() {
  rm -f "$fixture_rows"
}
trap cleanup_fixture_rows EXIT HUP INT TERM

python3 - "$fixtures" > "$fixture_rows" <<'PY'
import base64
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    corpus = json.load(handle)

assert corpus["schema"] == "ai.gigaduck.conduck.converse-response-fixtures"
assert corpus["version"] == 1
assert corpus["metadata"]["authorityPlatform"] == "Apple"
assert corpus["metadata"]["canonicalPath"] == "Conduck/ConduckTests/Fixtures/converse-response-v1.json"
assert corpus["metadata"]["canonicalURL"] == (
    "https://github.com/GigaDuckAI/conduck/blob/main/"
    "Conduck/ConduckTests/Fixtures/converse-response-v1.json"
)
assert corpus["metadata"]["corpusRevision"] == corpus["version"]
cases = corpus["cases"]
assert cases
assert len({case["id"] for case in cases}) == len(cases)
expected_case_ids = [
    "minimal_reply",
    "unknown_fields_reply",
    "multiple_choices_returns_first",
    "empty_content_reply",
    "missing_choices_invalid",
    "empty_choices_invalid",
    "missing_message_invalid",
    "missing_content_invalid",
    "null_content_invalid",
    "non_string_content_invalid",
    "malformed_later_choice_invalid",
    "non_json_invalid",
    "empty_body_invalid",
]
actual_case_ids = [case["id"] for case in cases]
if actual_case_ids != expected_case_ids:
    print(
        "FAIL Apple-authoritative response fixture IDs changed: "
        f"expected {expected_case_ids!r}, got {actual_case_ids!r}",
        file=sys.stderr,
    )
    raise SystemExit(1)

for case in cases:
    outcome = case["expected"]["outcome"]
    assert outcome in {"reply", "invalid"}
    reply = case["expected"].get("reply")
    if outcome == "reply":
        assert isinstance(reply, str)
        expected_length = len(reply)
    else:
        assert reply is None
        expected_length = 0
    encoded_body = base64.b64encode(case["body"].encode("utf-8")).decode("ascii")
    print(f"{case['id']}|{outcome}|{expected_length}|{encoded_body}")
PY

while IFS='|' read -r fixture_id expected_outcome expected_length body_base64; do
  [ -n "$fixture_id" ] || continue
  fixture_count=$((fixture_count + 1))
  fixture_body=$(printf '%s' "$body_base64" | python3 -c '
import base64, sys
sys.stdout.write(base64.b64decode(sys.stdin.read()).decode("utf-8"))')

  actual_outcome="invalid"
  if app_chat_body_eval "$fixture_body"; then
    actual_outcome="reply"
  fi

  if [ "$actual_outcome" != "$expected_outcome" ]; then
    printf 'FAIL %s: expected %s, got %s (%s)\n' \
      "$fixture_id" "$expected_outcome" "$actual_outcome" "${CCE_REASON:-no reason}" >&2
    fixture_failures=$((fixture_failures + 1))
  elif [ "$expected_outcome" = "reply" ] && [ "${CCE_LEN:-}" != "$expected_length" ]; then
    printf 'FAIL %s: expected reply length %s, got %s\n' \
      "$fixture_id" "$expected_length" "${CCE_LEN:-unset}" >&2
    fixture_failures=$((fixture_failures + 1))
  else
    printf 'FIXTURE ✓ %s\n' "$fixture_id"
  fi
done < "$fixture_rows"

[ "$fixture_failures" = "0" ] || {
  printf 'FIXTURE RESULT: %d passed, %d failed\n' \
    "$((fixture_count - fixture_failures))" "$fixture_failures" >&2
  exit 1
}
printf 'FIXTURE RESULT: %d passed, 0 failed\n' "$fixture_count"
