#!/usr/bin/env bash
#
# run-checks-suite.sh — connector check and command regression suite.
#
# For every adapter check there is a known-good fixture (must stay green) and at
# least one deliberately-broken fixture-adapter mode proving the check fails
# for its INTENDED reason. Without this, the check is a referee that only
# appears strict. Each case asserts:
#   1. the check's exit code,
#   2. the EXACT set of failed [CHECK_ID]s (nothing more, nothing less),
#   3. the machine summary line: full schema grammar (adapter schema=3, server
#      schema=2), last line of output, EXACTLY ONE summary line (no retired
#      prefix dual-emitted), required field values, and failed= consistent with
#      the ✗ line count,
#   4. for the pass modes: the complete ✓ inventory (every check really ran).
#
# Runs everything against tests/fixture-adapter.py on an OS-assigned loopback
# port with a per-run random token. Colour is gated on `[ -t 1 ]`, so these
# redirected runs are ANSI-free and the assertions grep plain text (the
# no-ansi-when-redirected case proves that gate). Exit 0 = whole suite green.
#
#   bash tests/run-checks-suite.sh             # whole suite
#   bash tests/run-checks-suite.sh good sse-…  # just these cases

set -u -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../conduck-connect.sh"
FIXTURE="$HERE/fixture-adapter.py"
WEBDAV="$HERE/fixture-webdav.py"
PTY_RUN="$HERE/pty-run.py"
[ -f "$SCRIPT" ] || { echo "missing $SCRIPT" >&2; exit 2; }
[ -f "$FIXTURE" ] || { echo "missing $FIXTURE" >&2; exit 2; }
[ -f "$WEBDAV" ] || { echo "missing $WEBDAV" >&2; exit 2; }
[ -f "$PTY_RUN" ] || { echo "missing $PTY_RUN" >&2; exit 2; }

TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(24))') || exit 2
TMP=$(mktemp -d "${TMPDIR:-/tmp}/conduck-checks-suite.XXXXXX") || exit 2
FIXTURE_PID=""
WEBDAV_PID=""
cleanup() {
  [ -n "$FIXTURE_PID" ] && kill "$FIXTURE_PID" 2>/dev/null
  [ -n "$WEBDAV_PID" ] && kill "$WEBDAV_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Every check id the deep profile can emit, sorted — the pass-mode inventory.
ALL_IDS="AUTH_CHAT_MISSING AUTH_CHAT_REJECT_BODY AUTH_CHAT_WRONG AUTH_MODELS_MISSING AUTH_MODELS_WRONG CHAT_BASIC HISTORY_IMAGE IMAGE_INPUT MODELS_ENVELOPE MODEL_SELECTION STREAM_SYNC"
BASIC_IDS="AUTH_CHAT_MISSING AUTH_CHAT_REJECT_BODY AUTH_CHAT_WRONG AUTH_MODELS_MISSING AUTH_MODELS_WRONG CHAT_BASIC HISTORY_IMAGE MODELS_ENVELOPE MODEL_SELECTION STREAM_SYNC"
# The complete green file-lane inventory on a fully-conformant --files run — the
# ids appended to the core inventory when a pass case carries --files.
FILE_IDS="FILES_CONFIG FILES_WRITE_THROUGH FILES_AUTH_READ_MISSING FILES_AUTH_READ_WRONG FILES_AUTH_WRITE_MISSING FILES_AUTH_WRITE_WRONG FILES_READ_FRESH FILES_PROBE_COMPAT FILES_NESTED FILE_COPY_BYTES FILE_REPLY_REFERENCE FILE_E2E FILES_DELETE"

# The frozen schema=3 grammar — field order fixed; any change must bump schema=
# (and this regex, and the freeze doc). The three file meters are NOT_REQUESTED
# without --files; with it, each grades NOT_RUN|PASS|FAIL|ERROR independently.
#
# What is frozen is the GRAMMAR — field order, field names, enum values — plus the
# two identity fields whose literals a consumer keys off (`schema=3`, `contract=v1`).
# Free-moving VALUES are matched by shape, never pinned: `revision=`, `harness=`,
# `checks=`, `failed=` and `exit=` all move without breaking a single parser, and
# pinning one of them turns an ordinary version bump into dozens of false failures
# in a suite that is supposed to be checking the grammar. Do NOT re-pin
# `revision=` to a literal — the adapter contract revision moves on its own
# schedule (it is also carried in the module header and on the website), and
# nothing here or in CI cross-checks those markers, so a literal is a tripwire
# with no owner rather than a review gate. The revision still has to be PRESENT,
# in POSITION, and well-formed; that is what this regex is for.
FMETER='(NOT_REQUESTED|NOT_RUN|PASS|FAIL|ERROR)'
SUMMARY_RE='^CONDUCK_CHECK_ADAPTER schema=3 contract=v1 revision=[0-9]+\.[0-9]+ harness=[0-9][0-9.]* profile=(basic|deep) core=(PASS|FAIL|NOT_RUN) history_image=(PASS|FAIL|NOT_RUN) stream=(PASS|FAIL|NOT_RUN) image_input=(VERIFIED|DECLINED|UNVERIFIED|FAIL|NOT_RUN) file_transport='$FMETER' file_access='$FMETER' file_e2e='$FMETER' checks=[0-9]+ failed=[0-9]+ exit=[0-9]+$'

# Retired summary prefixes. The schema bump renamed CONDUCK_DOCTOR ->
# CONDUCK_CHECK_ADAPTER and CONDUCK_COMPAT -> CONDUCK_CHECK_SERVER; consumers read
# `tail -1`, so a transitional dual emission would silently hand them the WRONG
# line. Exactly one summary line, under the new prefix only.
RETIRED_SUMMARY_RE='^(CONDUCK_DOCTOR|CONDUCK_COMPAT)'
ESC=$(printf '\033')

# Case table: name|fixture-mode|adapter-args|keyless|expected-exit|expected-failed-ids(comma)|required summary fragments(space-sep)
# expected-failed-ids "-" = none. keyless=yes runs the adapter check WITHOUT a token
# (answering the hidden prompt with Enter) against the fixture's open mode.
#
# The four require-model-* rows are one family, and they are read together. Three
# probes deliberately send no "model" field, so an adapter that REQUIRES one fails
# all of them for a single reason: the family proves the check names that reason
# ONCE (require-model → only CHAT_BASIC red, every capability genuinely measured),
# still catches a SECOND real fault under it (require-model-reject-history,
# require-model-drop-image), and refuses to invent a cause when it cannot attribute
# the failure at all (require-model-strict-fields). run_case's per-name hooks assert
# the wording, because the exit code alone cannot tell a true explanation from a
# false one. Every row in the family pins its three capability meters, and that is
# the load-bearing half: the meters are the only part a machine consumer reads, so
# a run that measured nothing must say NOT_RUN there (require-model-strict-fields)
# and a run that measured with a borrowed model must still report what it measured
# (require-model), never the missing-model failure a third time.
CASES='
good|good|--deep|no|0|-|profile=deep core=PASS history_image=PASS stream=PASS image_input=VERIFIED file_transport=NOT_REQUESTED file_access=NOT_REQUESTED file_e2e=NOT_REQUESTED exit=0
good-basic|good||no|0|-|profile=basic core=PASS history_image=PASS stream=PASS image_input=NOT_RUN checks=10 failed=0 exit=0
direct-check-adapter|good||no|0|-|profile=basic core=PASS checks=10 failed=0 exit=0
require-accept|require-accept|--deep|no|0|-|core=PASS image_input=VERIFIED exit=0
app-success-2xx|app-success-2xx|--deep|no|1|MODELS_ENVELOPE|core=FAIL checks=1 failed=1 exit=1
chat-success-201|chat-success-201|--deep|no|1|CHAT_BASIC,HISTORY_IMAGE,IMAGE_INPUT,MODEL_SELECTION,STREAM_SYNC|core=FAIL history_image=FAIL stream=FAIL image_input=FAIL exit=1
models-redirect-307|models-redirect-307|--deep|no|1|MODELS_ENVELOPE|core=FAIL checks=1 failed=1 exit=1
chat-redirect-308|chat-redirect-308|--deep|no|1|CHAT_BASIC,HISTORY_IMAGE,IMAGE_INPUT,MODEL_SELECTION,STREAM_SYNC|core=FAIL history_image=FAIL stream=FAIL image_input=FAIL exit=1
single-model|single-model|--deep|no|0|-|core=PASS image_input=VERIFIED exit=0
text-only|text-only|--deep|no|0|-|core=PASS history_image=PASS stream=PASS image_input=DECLINED exit=0
keyless|open|--deep|yes|1|AUTH_NOT_ENFORCED|core=FAIL history_image=PASS image_input=VERIFIED exit=1
auth-models-none-ok|auth-models-none-ok|--deep|no|1|AUTH_MODELS_MISSING|core=FAIL exit=1
auth-models-any-token|auth-models-any-token|--deep|no|1|AUTH_MODELS_WRONG|core=FAIL exit=1
auth-chat-none-ok|auth-chat-none-ok|--deep|no|1|AUTH_CHAT_MISSING|core=FAIL exit=1
auth-chat-any-token|auth-chat-any-token|--deep|no|1|AUTH_CHAT_WRONG|core=FAIL exit=1
auth-403|auth-403|--deep|no|1|AUTH_MODELS_MISSING|core=FAIL exit=1
reject-no-drain|reject-no-drain|--deep|no|1|AUTH_CHAT_REJECT_BODY|core=FAIL history_image=PASS stream=PASS image_input=VERIFIED exit=1
reject-close|reject-close|--deep|no|0|-|core=PASS history_image=PASS stream=PASS image_input=VERIFIED exit=0
models-bare-array|models-bare-array|--deep|no|1|MODELS_ENVELOPE|core=FAIL history_image=NOT_RUN stream=NOT_RUN image_input=NOT_RUN checks=1 failed=1 exit=1
models-html|models-html|--deep|no|1|MODELS_ENVELOPE|core=FAIL history_image=NOT_RUN exit=1
models-empty-data|models-empty-data|--deep|no|1|MODELS_ENVELOPE|core=FAIL history_image=PASS stream=PASS exit=1
models-no-id|models-no-id|--deep|no|1|MODELS_ENVELOPE|core=FAIL exit=1
models-slow|models-slow|--deep|no|1|MODELS_ENVELOPE|core=FAIL exit=1
wrong-content-type-models|wrong-content-type-models|--deep|no|1|MODELS_ENVELOPE|core=FAIL exit=1
require-model|require-model|--deep|no|1|CHAT_BASIC|core=FAIL history_image=PASS stream=PASS image_input=VERIFIED failed=1 exit=1
require-model-reject-history|require-model-reject-history|--deep|no|1|CHAT_BASIC,HISTORY_IMAGE|core=FAIL history_image=FAIL stream=PASS image_input=VERIFIED failed=2 exit=1
require-model-drop-image|require-model-drop-image|--deep|no|1|CHAT_BASIC,IMAGE_INPUT|core=FAIL history_image=PASS stream=PASS image_input=UNVERIFIED failed=2 exit=1
require-model-strict-fields|require-model-strict-fields|--deep|no|1|CHAT_BASIC,HISTORY_IMAGE,IMAGE_INPUT,STREAM_SYNC|core=FAIL history_image=NOT_RUN stream=NOT_RUN image_input=NOT_RUN failed=4 exit=1
strict-fields-image-413|strict-fields-image-413|--deep|no|1|CHAT_BASIC,HISTORY_IMAGE,IMAGE_INPUT,STREAM_SYNC|core=FAIL history_image=FAIL stream=NOT_RUN image_input=FAIL failed=4 exit=1
reject-unknown-field|reject-unknown-field|--deep|no|1|CHAT_BASIC|core=FAIL exit=1
bogus-model-200|bogus-model-200|--deep|no|1|MODEL_SELECTION|core=FAIL exit=1
error-missing-type|error-missing-type|--deep|no|1|MODEL_SELECTION|core=FAIL exit=1
sse-despite-false|sse-despite-false|--deep|no|1|CHAT_BASIC,HISTORY_IMAGE,IMAGE_INPUT,MODEL_SELECTION|history_image=FAIL stream=PASS image_input=FAIL exit=1
reject-stream-true|reject-stream-true|--deep|no|1|STREAM_SYNC|core=FAIL stream=FAIL exit=1
sse-on-stream-true|sse-on-stream-true|--deep|no|1|STREAM_SYNC|core=FAIL stream=FAIL exit=1
reject-history-image|reject-history-image|--deep|no|1|HISTORY_IMAGE|core=FAIL history_image=FAIL image_input=VERIFIED exit=1
silent-drop-image|silent-drop-image|--deep|no|1|IMAGE_INPUT|core=PASS image_input=UNVERIFIED exit=1
decline-wrong-code|decline-wrong-code|--deep|no|1|IMAGE_INPUT|core=PASS image_input=FAIL exit=1
decline-other-code|decline-other-code|--deep|no|1|IMAGE_INPUT|core=PASS image_input=FAIL exit=1
wrong-content-type|wrong-content-type|--deep|no|1|CHAT_BASIC,HISTORY_IMAGE,IMAGE_INPUT,MODEL_SELECTION,STREAM_SYNC|core=FAIL exit=1
empty-content|empty-content|--deep|no|1|CHAT_BASIC,HISTORY_IMAGE,IMAGE_INPUT,MODEL_SELECTION,STREAM_SYNC|core=FAIL exit=1
tool-calls|tool-calls|--deep|no|1|CHAT_BASIC,HISTORY_IMAGE,IMAGE_INPUT,MODEL_SELECTION,STREAM_SYNC|core=FAIL exit=1
many-choices|many-choices|--deep|no|1|CHAT_BASIC,HISTORY_IMAGE,IMAGE_INPUT,MODEL_SELECTION,STREAM_SYNC|core=FAIL exit=1
non-string-content|non-string-content|--deep|no|1|CHAT_BASIC,HISTORY_IMAGE,IMAGE_INPUT,MODEL_SELECTION,STREAM_SYNC|core=FAIL exit=1
bad-json|bad-json|--deep|no|1|CHAT_BASIC,HISTORY_IMAGE,IMAGE_INPUT,MODEL_SELECTION,STREAM_SYNC|core=FAIL exit=1
'

ADAPTER_FILES_DIR=""   # when set, the chat adapter learns the shared folder to
                       # write --files outputs into (the file cases set it)
# How long a fixture may take to bind and print READY, in tenths of a second.
# A fixture that DIES leaves the loop immediately (the `kill -0` check), so this
# bound only ever applies to one that is alive but slow to start — raising it
# costs a healthy run nothing and spares a cold CI runner a false failure.
FIXTURE_READY_TICKS=300

# Explain why a fixture never reached READY.
#
# `fail_case` dumps `doctor.out`, which for a startup failure is the PREVIOUS
# case's output — actively misleading. The real cause is in the fixture's own
# stderr, and leaving that unread is how a single environment problem reads as a
# hundred independent test failures. Detail is printed once per run; every later
# fixture failure in the same run has the same cause, so it gets one line.
FIXTURE_DIAG_SHOWN=false
fixture_start_failed() { # fixture_start_failed <label> <outfile> <errfile>
  local label="$1" outf="$2" errf="$3" py
  if [ "$FIXTURE_DIAG_SHOWN" = true ]; then
    printf '  ! %s never printed READY (see the first fixture failure above)\n' "$label"
    return
  fi
  FIXTURE_DIAG_SHOWN=true
  py=$(command -v python3 2>/dev/null) || py=""
  printf '  ! %s never printed READY within %ss\n' "$label" "$((FIXTURE_READY_TICKS / 10))"
  printf '  ! python3: %s (%s)\n' "${py:-NOT FOUND}" "$(python3 -V 2>&1 || echo 'no version')"
  if [ -s "$errf" ]; then
    printf '  ! its stderr:\n'
    sed 's/^/  !   /' "$errf" | tail -n 20
  else
    printf '  ! its stderr was empty — the process produced no diagnostic at all\n'
  fi
  if [ -s "$outf" ]; then
    printf '  ! its stdout:\n'
    sed 's/^/  !   /' "$outf" | tail -n 5
  fi
}

start_fixture() { # start_fixture <mode> -> sets FIXTURE_PID + PORT
  local mode="$1" i line
  : > "$TMP/fixture.out"
  CONDUCK_TOKEN="$TOKEN" env ${ADAPTER_FILES_DIR:+CONDUCK_FILES_DIR="$ADAPTER_FILES_DIR"} \
    python3 "$FIXTURE" --mode "$mode" --port 0 \
    > "$TMP/fixture.out" 2>"$TMP/fixture.err" &
  FIXTURE_PID=$!
  PORT=""
  i=0
  while [ "$i" -lt "$FIXTURE_READY_TICKS" ]; do
    line=$(head -n 1 "$TMP/fixture.out" 2>/dev/null)
    case "$line" in READY\ *) PORT="${line#READY }"; break ;; esac
    kill -0 "$FIXTURE_PID" 2>/dev/null || break
    i=$((i+1)); sleep 0.1
  done
  [ -n "$PORT" ] || fixture_start_failed \
    "chat-adapter fixture (mode $mode)" "$TMP/fixture.out" "$TMP/fixture.err"
  [ -n "$PORT" ]
}

stop_fixture() {
  [ -n "$FIXTURE_PID" ] && kill "$FIXTURE_PID" 2>/dev/null && wait "$FIXTURE_PID" 2>/dev/null
  FIXTURE_PID=""
}

start_webdav() { # start_webdav <mode> <served-dir> <cred> [capture-file] -> sets WEBDAV_PID + WPORT
  local mode="$1" dir="$2" cred="$3" capture="${4:-}" i line
  : > "$TMP/webdav.out"
  WEBDAV_PASS="$cred" python3 "$WEBDAV" --mode "$mode" --port 0 --dir "$dir" \
    --user conduck ${capture:+--capture "$capture"} \
    > "$TMP/webdav.out" 2>"$TMP/webdav.err" &
  WEBDAV_PID=$!
  WPORT=""
  i=0
  while [ "$i" -lt "$FIXTURE_READY_TICKS" ]; do
    line=$(head -n 1 "$TMP/webdav.out" 2>/dev/null)
    case "$line" in READY\ *) WPORT="${line#READY }"; break ;; esac
    kill -0 "$WEBDAV_PID" 2>/dev/null || break
    i=$((i+1)); sleep 0.1
  done
  [ -n "$WPORT" ] || fixture_start_failed \
    "WebDAV fixture (mode $mode)" "$TMP/webdav.out" "$TMP/webdav.err"
  [ -n "$WPORT" ]
}

stop_webdav() {
  [ -n "$WEBDAV_PID" ] && kill "$WEBDAV_PID" 2>/dev/null && wait "$WEBDAV_PID" 2>/dev/null
  WEBDAV_PID=""
}

# check-artifact leftovers in a served dir (conduck-check-* / output-*), one
# per line — the post-check for the cleanup-focused file cases.
check_artifacts() { # check_artifacts <served-dir>
  find "$1" -mindepth 1 \( -name 'conduck-check-*' -o -name 'output-*' \) 2>/dev/null
}

# Lift named top-level functions out of the release artifact so a case can unit-
# test the SHIPPED code with stubs around it. One sed run per name on purpose:
# `sed -n '/^a()/,/^}/p;/^b()/,/^}/p'` looks equivalent but overlapping ranges
# print their shared lines TWICE, and the duplicated fragment no longer parses.
extract_funcs() { # extract_funcs <fn-name>… -> function source on stdout
  local n
  for n in "$@"; do sed -n "/^$n()/,/^}/p" "$SCRIPT"; done
}

PASS=0
FAIL=0
fail_case() { # fail_case <name> <why>
  FAIL=$((FAIL+1))
  printf 'SUITE ✗ %s — %s\n' "$1" "$2"
  sed 's/^/    | /' "$TMP/doctor.out" | tail -n 25
}

# Invariants every REDIRECTED check run owes its machine consumers, whichever
# lane produced it: exactly one summary line under the current prefix, no
# retired prefix alongside it, and no ANSI (colour is gated on `[ -t 1 ]`).
assert_machine_output() { # assert_machine_output <name> <prefix>
  local n
  n=$(grep -c "^$2 schema=" "$TMP/doctor.out")
  if [ "$n" != "1" ]; then
    fail_case "$1" "expected exactly 1 $2 summary line, found $n"; return 1
  fi
  if grep -Eq "$RETIRED_SUMMARY_RE" "$TMP/doctor.out"; then
    fail_case "$1" "a retired summary prefix was emitted alongside $2"; return 1
  fi
  if grep -qF "$ESC" "$TMP/doctor.out"; then
    fail_case "$1" "a redirected run emitted ANSI escapes"; return 1
  fi
  return 0
}

# Every INTENTIONAL-PTY case runs through here. `env -u CI` is the whole point:
# interactive_terminal() returns false whenever $CI is set, and every GitHub
# Actions runner exports CI=true — so without stripping it, these cases would
# silently grade the non-interactive path (no setup handoff, no menu question)
# and pass for the wrong reason, or fail outright. The runtime guard is correct
# and must not be weakened; the HARNESS is what has to simulate a real user at a
# terminal. PTY_ENV is applied AFTER -u, so ci-gate-no-handoff can deliberately
# put CI=true back. Callers set PTY_ENV=() (or their own list) before calling.
PTY_ENV=()
pty_run() { # PTY_ENV=(K=V …) pty_run <timeout-secs> <input> [script-args…]
  local timeout="$1" input="$2"; shift 2
  env -u CI TERM=dumb ${PTY_ENV[@]+"${PTY_ENV[@]}"} \
    python3 "$PTY_RUN" "$timeout" "$input" bash "$SCRIPT" "$@"
}

run_case() { # run_case <table-row>
  local name mode args keyless expexit expfails frags
  local rest="$1"
  name="${rest%%|*}"; rest="${rest#*|}"
  mode="${rest%%|*}"; rest="${rest#*|}"
  args="${rest%%|*}"; rest="${rest#*|}"
  keyless="${rest%%|*}"; rest="${rest#*|}"
  expexit="${rest%%|*}"; rest="${rest#*|}"
  expfails="${rest%%|*}"; frags="${rest#*|}"

  start_fixture "$mode" || { fail_case "$name" "fixture failed to start"; stop_fixture; return; }

  local rc=0
  if [ "$keyless" = "yes" ]; then
    # CONDUCK_TOKEN set-but-empty is an EXPLICIT keyless declaration, so stdin is
    # /dev/null on purpose: there must be NO prompt to answer. (Unset + EOF is the
    # fail-closed die — see run_auth_eof_case.)
    TERM=dumb CONDUCK_TOKEN="" bash "$SCRIPT" --check-adapter "http://127.0.0.1:$PORT" $args \
      > "$TMP/doctor.out" 2>&1 < /dev/null || rc=$?
  else
    TERM=dumb CONDUCK_TOKEN="$TOKEN" bash "$SCRIPT" --check-adapter "http://127.0.0.1:$PORT" $args \
      > "$TMP/doctor.out" 2>&1 < /dev/null || rc=$?
  fi
  stop_fixture

  if [ "$keyless" = "yes" ] && ! grep -qF 'Keyless by explicit' "$TMP/doctor.out"; then
    fail_case "$name" "CONDUCK_TOKEN= was not honoured as an explicit keyless declaration"; return
  fi

  # 1 — exit code
  if [ "$rc" != "$expexit" ]; then
    fail_case "$name" "exit $rc, expected $expexit"; return
  fi
  # 2 — exact failed-ID set
  local got exp
  got=$(grep -o '✗ \[[A-Z0-9_]*\]' "$TMP/doctor.out" | sed 's/.*\[\(.*\)\]/\1/' | sort -u | tr '\n' ',' | sed 's/,$//')
  exp=$(printf '%s' "$expfails" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
  [ "$expfails" = "-" ] && exp=""
  if [ "$got" != "$exp" ]; then
    fail_case "$name" "failed-ID set '{$got}', expected '{$exp}'"; return
  fi
  # 3 — machine summary: last line, full grammar, exactly one, required
  #     fragments, failed= consistent with the ✗ verdict-line count
  local summary nfail nlines frag
  assert_machine_output "$name" CONDUCK_CHECK_ADAPTER || return
  summary=$(tail -n 1 "$TMP/doctor.out")
  if ! printf '%s\n' "$summary" | grep -Eq "$SUMMARY_RE"; then
    fail_case "$name" "last line isn't a valid schema=3 summary: $summary"; return
  fi
  for frag in $frags; do
    case " $summary " in *" $frag "*) ;; *)
      fail_case "$name" "summary lacks '$frag': $summary"; return ;;
    esac
  done
  nfail=$(printf '%s\n' "$summary" | sed 's/.* failed=\([0-9]*\).*/\1/')
  nlines=$(grep -c '✗ \[' "$TMP/doctor.out")
  if [ "$nfail" != "$nlines" ]; then
    fail_case "$name" "summary failed=$nfail but $nlines ✗ verdict lines"; return
  fi
  # Every FAIL exit owes the reader the way out. This grade holds software written
  # FOR Conduck to Conduck's own rules, so third-party OpenAI-compatible software is
  # EXPECTED to fail it and its owner did nothing wrong — a closing line pointing
  # only at the adapter contract leaves them reading a wall of red as "unusable"
  # when the app pairs with it fine. Asserted on EVERY red row, including the ones
  # that abort early at /v1/models, and asserted ABSENT on every green one: a PASS
  # has nothing to steer anyone away from.
  if [ "$expexit" = "0" ]; then
    if grep -qF "Didn't write this server yourself?" "$TMP/doctor.out"; then
      fail_case "$name" "a PASS printed the not-yours way out"; return
    fi
  else
    if ! grep -qF "Didn't write this server yourself?" "$TMP/doctor.out"; then
      fail_case "$name" "a FAIL exit gave no way out for someone else's server"; return
    fi
    if ! grep -qF 'can the app talk to this server?' "$TMP/doctor.out"; then
      fail_case "$name" "the way out doesn't offer --check-server"; return
    fi
    if ! grep -qF "a failed grade here doesn't block that" "$TMP/doctor.out"; then
      fail_case "$name" "the way out doesn't say pairing is still possible"; return
    fi
  fi
  # Per-name wording assertions. A confidently WRONG explanation costs more trust
  # than a missing one, and neither the exit code nor the failed-ID set can see the
  # difference — only the words can.
  case "$name" in
    *redirect-*)
      if ! grep -qF 'final server URL directly' "$TMP/doctor.out"; then
        fail_case "$name" "redirect failure omitted the direct-final-URL hint"; return
      fi
      ;;
    require-model)
      if ! grep -qF 'REQUIRES that field' "$TMP/doctor.out"; then
        fail_case "$name" "the missing-model fault was not named plainly"; return
      fi
      if grep -qF 'poison every later turn' "$TMP/doctor.out"; then
        fail_case "$name" "a missing-model failure was retold as history poisoning"; return
      fi
      if grep -qF 'must not be rejected' "$TMP/doctor.out"; then
        fail_case "$name" "a missing-model failure was retold as a streaming fault"; return
      fi
      # Said ONCE. The whole defect was one cause told three times, so a fix that
      # merely swapped three false stories for three true ones is not the fix.
      local named
      named=$(grep -c 'REQUIRES that field' "$TMP/doctor.out")
      if [ "$named" != "1" ]; then
        fail_case "$name" "the missing-model fault was named $named times, expected once"; return
      fi
      # …and every verdict that BORROWED a model says so on itself. Without this a
      # green history_image/stream/image_input reads as a pass under the contract's
      # model-less conditions — the one condition the probe could not run under.
      local scoped id
      scoped=$(grep -c 'measured with "model"' "$TMP/doctor.out")
      if [ "$scoped" != "3" ]; then
        fail_case "$name" "$scoped verdicts named the borrowed model, expected 3 (history, stream, image)"; return
      fi
      for id in HISTORY_IMAGE STREAM_SYNC IMAGE_INPUT; do
        if ! grep -qF "[$id] (measured with \"model\"" "$TMP/doctor.out"; then
          fail_case "$name" "[$id] passed without saying a model was supplied for it"; return
        fi
      done
      # CHAT_BASIC is the one probe that really did run model-less; claiming a
      # borrowed model on ITS verdict would misreport the evidence for the failure.
      if grep -qF '[CHAT_BASIC] (measured with "model"' "$TMP/doctor.out"; then
        fail_case "$name" "CHAT_BASIC claimed a borrowed model on the model-less turn it graded"; return
      fi
      ;;
    require-model-reject-history)
      # The mirror image of the case above: with the model supplied, the history
      # rejection is REAL, so its explanation must still fire. A "fix" that simply
      # stopped saying it would pass require-model and hide this fault.
      if ! grep -qF 'poison every later turn' "$TMP/doctor.out"; then
        fail_case "$name" "a real history-image rejection lost its explanation"; return
      fi
      ;;
    require-model-drop-image)
      if ! grep -qF 'the engine never saw the image' "$TMP/doctor.out"; then
        fail_case "$name" "a real silent image drop lost its explanation"; return
      fi
      ;;
    strict-fields-image-413)
      # 413 is NOT a maybe-missing-model status: the contract spends it on a
      # request-size limit, and this server said so. An unattributable model
      # question must not swallow a cause the server stated outright — the image
      # probes keep their own verdict while the model-less TEXT probe stays ungraded.
      if grep -qF "[HISTORY_IMAGE] (this request deliberately carries no" "$TMP/doctor.out"; then
        fail_case "$name" "a stated 413 size limit was reported as an ungraded model question"; return
      fi
      if grep -qF "[IMAGE_INPUT] (this request also carries no" "$TMP/doctor.out"; then
        fail_case "$name" "a stated 413 size limit was reported as an ungraded model question"; return
      fi
      # The text-only stream probe has no image, so it really is the ambiguous one.
      if ! grep -qF "[STREAM_SYNC] (this request deliberately carries no" "$TMP/doctor.out"; then
        fail_case "$name" "the genuinely ambiguous model-less probe was graded anyway"; return
      fi
      # …and the stated cause is what gets reported. A size limit told as a
      # history-poisoning fault is the same invented explanation in a new place.
      if ! grep -qF '413 is a request-size limit answering' "$TMP/doctor.out"; then
        fail_case "$name" "a stated 413 size limit was not named as the cause"; return
      fi
      if grep -qF 'poison every later turn' "$TMP/doctor.out"; then
        fail_case "$name" "a stated 413 size limit was retold as history poisoning"; return
      fi
      ;;
    require-model-strict-fields)
      if ! grep -qF "can't tell the two rules apart" "$TMP/doctor.out"; then
        fail_case "$name" "an unattributable failure was not reported as ungraded"; return
      fi
      if grep -qF 'poison every later turn' "$TMP/doctor.out"; then
        fail_case "$name" "an unattributable failure was retold as history poisoning"; return
      fi
      if grep -qF 'must not be rejected' "$TMP/doctor.out"; then
        fail_case "$name" "an unattributable failure was retold as a streaming fault"; return
      fi
      ;;
    sse-on-stream-true)
      # The stream hint has to describe what the app DOES — all four of its call
      # sites send "stream": false — not a rule about what it would accept.
      if ! grep -qF 'always sends "stream": false' "$TMP/doctor.out"; then
        fail_case "$name" "the stream hint doesn't say the app always sends stream: false"; return
      fi
      ;;
  esac
  # 4 — pass modes: the complete ✓ inventory (every check genuinely ran)
  if [ "$expexit" = "0" ]; then
    local want inventory ok_ids
    case "$args" in *--deep*) inventory="$ALL_IDS" ;; *) inventory="$BASIC_IDS" ;; esac
    case "$args" in *--files*) inventory="$inventory $FILE_IDS" ;; esac
    ok_ids=$(grep -o '✓ \[[A-Z0-9_]*\]' "$TMP/doctor.out" | sed 's/.*\[\(.*\)\]/\1/' | sort -u | tr '\n' ' ' | sed 's/ $//')
    want=$(printf '%s\n' $inventory | sort -u | tr '\n' ' ' | sed 's/ $//')
    if [ "$ok_ids" != "$want" ]; then
      fail_case "$name" "green inventory '{$ok_ids}' != expected '{$want}'"; return
    fi
    if [ "$name" = "direct-check-adapter" ] &&
       ! grep -qF 'bash conduck-connect.sh --setup' "$TMP/doctor.out"; then
      fail_case "$name" "PASS output omitted the explicit --setup handoff"; return
    fi
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# The same steps 1–4 as run_case's tail, as a reusable grader (the --files
# cases share it). Returns 0 iff every assertion held; otherwise it has already
# reported via fail_case. $args is the adapter-check arg string (drives inventory).
grade_adapter() { # grade_adapter <name> <rc> <expexit> <expfails> <args> <frags>
  local name="$1" rc="$2" expexit="$3" expfails="$4" args="$5" frags="$6"
  if [ "$rc" != "$expexit" ]; then
    fail_case "$name" "exit $rc, expected $expexit"; return 1
  fi
  local got exp
  got=$(grep -o '✗ \[[A-Z0-9_]*\]' "$TMP/doctor.out" | sed 's/.*\[\(.*\)\]/\1/' | sort -u | tr '\n' ',' | sed 's/,$//')
  exp=$(printf '%s' "$expfails" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
  [ "$expfails" = "-" ] && exp=""
  if [ "$got" != "$exp" ]; then
    fail_case "$name" "failed-ID set '{$got}', expected '{$exp}'"; return 1
  fi
  local summary nfail nlines frag
  assert_machine_output "$name" CONDUCK_CHECK_ADAPTER || return 1
  summary=$(tail -n 1 "$TMP/doctor.out")
  if ! printf '%s\n' "$summary" | grep -Eq "$SUMMARY_RE"; then
    fail_case "$name" "last line isn't a valid schema=3 summary: $summary"; return 1
  fi
  for frag in $frags; do
    case " $summary " in *" $frag "*) ;; *)
      fail_case "$name" "summary lacks '$frag': $summary"; return 1 ;;
    esac
  done
  nfail=$(printf '%s\n' "$summary" | sed 's/.* failed=\([0-9]*\).*/\1/')
  nlines=$(grep -c '✗ \[' "$TMP/doctor.out")
  if [ "$nfail" != "$nlines" ]; then
    fail_case "$name" "summary failed=$nfail but $nlines ✗ verdict lines"; return 1
  fi
  if [ "$expexit" = "0" ]; then
    local want inventory ok_ids
    case "$args" in *--deep*) inventory="$ALL_IDS" ;; *) inventory="$BASIC_IDS" ;; esac
    case "$args" in *--files*) inventory="$inventory $FILE_IDS" ;; esac
    ok_ids=$(grep -o '✓ \[[A-Z0-9_]*\]' "$TMP/doctor.out" | sed 's/.*\[\(.*\)\]/\1/' | sort -u | tr '\n' ' ' | sed 's/ $//')
    want=$(printf '%s\n' $inventory | sort -u | tr '\n' ' ' | sed 's/ $//')
    if [ "$ok_ids" != "$want" ]; then
      fail_case "$name" "green inventory '{$ok_ids}' != expected '{$want}'"; return 1
    fi
  fi
  return 0
}

# The --files fault-injection cases. Each spins up its OWN temp served dir + a
# fixture-webdav server (own OS-assigned port, per-case random credential) and
# runs the adapter check with --files, HOME isolated so no
# real pairing profile is consulted and no shared state leaks.
# name|adapter-mode|webdav-mode|env-mode|adapter-args|exp-exit|exp-fails|frags|post
#   webdav-mode "-"      = no WebDAV server (config-error cases fail before contact)
#   env-mode: full       = CONDUCK_FILES_URL(webdav)+DIR(served)+PASS(cred)
#             url-only    = only CONDUCK_FILES_URL set (partial → FILES_CONFIG)
#             home-dir    = DIR=$HOME (refused) ; none = no overrides (no profile)
#   post: - | dir-empty (served dir must hold zero check artifacts) | no-leak
FILE_CASES='
files-good|files-good|good|full|--files|0|-|profile=basic core=PASS file_transport=PASS file_access=PASS file_e2e=PASS exit=0|dir-empty
files-not-requested|good|-|none|--deep|0|-|core=PASS file_transport=NOT_REQUESTED file_access=NOT_REQUESTED file_e2e=NOT_REQUESTED exit=0|-
files-stale-cache|files-good|stale-listing|full|--files|1|FILES_READ_FRESH,FILE_E2E|core=PASS file_transport=FAIL file_access=PASS file_e2e=FAIL exit=1|-
files-read-only|files-good|read-only|full|--files|1|FILES_WRITE_THROUGH|core=PASS file_transport=FAIL file_access=PASS file_e2e=PASS exit=1|-
files-open|files-good|open|full|--files|1|FILES_AUTH_READ_MISSING,FILES_AUTH_READ_WRONG,FILES_AUTH_WRITE_MISSING,FILES_AUTH_WRITE_WRONG|core=PASS file_transport=FAIL file_access=PASS file_e2e=PASS exit=1|-
files-no-range|files-good|no-range|full|--files|0|-|core=PASS file_transport=PASS file_access=PASS file_e2e=PASS exit=0|-
files-no-delete|files-good|no-delete|full|--files|0|-|core=PASS file_transport=PASS file_access=PASS file_e2e=PASS exit=0|dir-empty
files-no-mkcol|files-good|no-mkcol|full|--files|0|-|core=PASS file_transport=PASS file_access=PASS file_e2e=PASS exit=0|-
files-agent-no-write|files-no-write|good|full|--files|1|FILE_COPY_BYTES|core=PASS file_transport=PASS file_access=FAIL file_e2e=NOT_RUN exit=1|-
files-agent-late-write|files-late-write|good|full|--files|1|FILE_COPY_BYTES|core=PASS file_transport=PASS file_access=FAIL file_e2e=NOT_RUN exit=1|dir-empty
files-agent-wrong-bytes|files-wrong-bytes|good|full|--files|1|FILE_COPY_BYTES|core=PASS file_transport=PASS file_access=FAIL file_e2e=NOT_RUN exit=1|-
files-agent-no-reference|files-no-reference|good|full|--files|1|FILE_REPLY_REFERENCE|core=PASS file_transport=PASS file_access=FAIL file_e2e=PASS exit=1|-
files-env-partial|files-good|-|url-only|--files|1|FILES_CONFIG|core=PASS file_transport=ERROR file_access=NOT_RUN file_e2e=NOT_RUN exit=1|-
files-no-config|files-good|-|none|--files|1|FILES_CONFIG|core=PASS file_transport=ERROR file_access=NOT_RUN file_e2e=NOT_RUN exit=1|-
files-unsafe-root|files-good|-|home-dir|--files|1|FILES_CONFIG|core=PASS file_transport=ERROR file_access=NOT_RUN file_e2e=NOT_RUN exit=1|-
no-leak|files-good|good|full|--files|0|-|core=PASS file_transport=PASS file_access=PASS file_e2e=PASS exit=0|no-leak
'

run_file_case() { # run_file_case <table-row>
  local name amode wmode envmode dargs expexit expfails frags post
  local rest="$1"
  name="${rest%%|*}"; rest="${rest#*|}"
  amode="${rest%%|*}"; rest="${rest#*|}"
  wmode="${rest%%|*}"; rest="${rest#*|}"
  envmode="${rest%%|*}"; rest="${rest#*|}"
  dargs="${rest%%|*}"; rest="${rest#*|}"
  expexit="${rest%%|*}"; rest="${rest#*|}"
  expfails="${rest%%|*}"; rest="${rest#*|}"
  frags="${rest%%|*}"; post="${rest#*|}"

  local SERVED CASE_HOME CRED CAPTURE=""
  SERVED=$(mktemp -d "$TMP/served.XXXXXX") || { fail_case "$name" "mktemp served failed"; return; }
  CASE_HOME=$(mktemp -d "$TMP/home.XXXXXX") || { fail_case "$name" "mktemp home failed"; return; }
  CRED=$(python3 -c 'import secrets; print("wd-" + secrets.token_hex(8))') || { fail_case "$name" "cred gen failed"; return; }
  if [ "$post" = "no-leak" ]; then CAPTURE="$TMP/capture.txt"; : > "$CAPTURE"; fi

  ADAPTER_FILES_DIR="$SERVED"
  start_fixture "$amode" || { fail_case "$name" "adapter failed to start"; ADAPTER_FILES_DIR=""; stop_fixture; return; }
  ADAPTER_FILES_DIR=""
  WPORT=""
  if [ "$wmode" != "-" ]; then
    start_webdav "$wmode" "$SERVED" "$CRED" "$CAPTURE" \
      || { fail_case "$name" "webdav failed to start"; stop_fixture; stop_webdav; return; }
  fi

  local -a denv=(HOME="$CASE_HOME" TERM=dumb CONDUCK_TOKEN="$TOKEN")
  case "$envmode" in
    full)     denv+=(CONDUCK_FILES_URL="http://127.0.0.1:$WPORT" CONDUCK_FILES_DIR="$SERVED" CONDUCK_FILES_PASS="$CRED") ;;
    url-only) denv+=(CONDUCK_FILES_URL="http://127.0.0.1:1") ;;
    home-dir) denv+=(CONDUCK_FILES_URL="http://127.0.0.1:1" CONDUCK_FILES_DIR="$CASE_HOME" CONDUCK_FILES_PASS="$CRED") ;;
    none)     ;;
  esac

  local rc=0
  env -u XDG_CONFIG_HOME "${denv[@]}" bash "$SCRIPT" --check-adapter "http://127.0.0.1:$PORT" $dargs \
    </dev/null > "$TMP/doctor.out" 2>&1 || rc=$?
  stop_fixture; stop_webdav

  grade_adapter "$name" "$rc" "$expexit" "$expfails" "$dargs" "$frags" || return

  case "$post" in
    dir-empty)
      local left; left=$(check_artifacts "$SERVED")
      if [ -n "$left" ]; then
        fail_case "$name" "served dir still holds check artifacts: $(echo $left)"; return
      fi ;;
    no-leak)
      if grep -qF "$CRED" "$TMP/doctor.out"; then
        fail_case "$name" "adapter-check output leaked the WebDAV credential"; return
      fi
      local nonce
      nonce=$(grep -oE '[0-9a-f]{64}' "$CAPTURE" 2>/dev/null | head -n 1)
      if [ -z "$nonce" ]; then
        fail_case "$name" "no-leak: could not recover the sentinel nonce from the WebDAV capture"; return
      fi
      if grep -qF "$nonce" "$TMP/doctor.out"; then
        fail_case "$name" "adapter-check output leaked the sentinel content nonce"; return
      fi ;;
  esac

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# The SIGINT-mid-turn case: interrupt the adapter check during the agent file turn and
# prove the machine summary still rides (exit=130) and the backstop cleaned up.
run_signal_cleanup() {
  local name="signal-cleanup"
  local SERVED CASE_HOME CRED
  SERVED=$(mktemp -d "$TMP/served.XXXXXX") || { fail_case "$name" "mktemp served failed"; return; }
  CASE_HOME=$(mktemp -d "$TMP/home.XXXXXX") || { fail_case "$name" "mktemp home failed"; return; }
  CRED=$(python3 -c 'import secrets; print("wd-" + secrets.token_hex(8))') || { fail_case "$name" "cred gen failed"; return; }

  ADAPTER_FILES_DIR="$SERVED"
  start_fixture "files-slow" || { fail_case "$name" "adapter failed to start"; ADAPTER_FILES_DIR=""; stop_fixture; return; }
  ADAPTER_FILES_DIR=""
  start_webdav good "$SERVED" "$CRED" \
    || { fail_case "$name" "webdav failed to start"; stop_fixture; stop_webdav; return; }

  # Job-control mode so the check gets its OWN process group: a real Ctrl-C
  # signals the whole foreground group (bash + its blocked curl child), which
  # is what makes its `trap 'exit 130' INT` fire promptly. Signalling
  # only the bash PID would leave the curl running and bash would defer the
  # trap until it returned — not a faithful Ctrl-C.
  set -m
  env -u XDG_CONFIG_HOME HOME="$CASE_HOME" TERM=dumb CONDUCK_TOKEN="$TOKEN" \
      CONDUCK_FILES_URL="http://127.0.0.1:$WPORT" CONDUCK_FILES_DIR="$SERVED" CONDUCK_FILES_PASS="$CRED" \
      bash "$SCRIPT" --check-adapter "http://127.0.0.1:$PORT" --files \
      </dev/null > "$TMP/doctor.out" 2>&1 &
  local dpid=$!
  set +m

  local i=0 hit=""
  while [ "$i" -lt 300 ]; do
    if grep -q 'The file sentinel' "$TMP/doctor.out" 2>/dev/null; then hit=1; break; fi
    kill -0 "$dpid" 2>/dev/null || break
    i=$((i+1)); sleep 0.1
  done
  if [ -z "$hit" ]; then
    fail_case "$name" "adapter check never reached the agent file turn"
    kill "$dpid" 2>/dev/null; wait "$dpid" 2>/dev/null; stop_fixture; stop_webdav; return
  fi
  sleep 1
  kill -INT -"$dpid" 2>/dev/null    # negative pid → the check's process group
  local rc=0; wait "$dpid" 2>/dev/null || rc=$?
  stop_fixture; stop_webdav

  if [ "$rc" != "130" ]; then fail_case "$name" "exit $rc, expected 130 (SIGINT)"; return; fi
  assert_machine_output "$name" CONDUCK_CHECK_ADAPTER || return
  local summary; summary=$(tail -n 1 "$TMP/doctor.out")
  if ! printf '%s\n' "$summary" | grep -Eq "$SUMMARY_RE"; then
    fail_case "$name" "last line isn't a valid schema=3 summary: $summary"; return
  fi
  case " $summary " in *" exit=130 "*) ;; *) fail_case "$name" "summary lacks exit=130: $summary"; return ;; esac
  local left; left=$(check_artifacts "$SERVED")
  if [ -n "$left" ]; then
    fail_case "$name" "SIGINT left check artifacts behind: $(echo $left)"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# A --check-adapter FAIL must not strand the person reading it. This grade holds
# software written FOR Conduck to Conduck-specific rules, and third-party
# OpenAI-compatible software (LiteLLM, Open WebUI, Ollama) is EXPECTED to fail it
# while working perfectly with the app — its owner did nothing wrong. Pointing only
# at the contract docs tells that reader to go fix someone else's server. So both
# failure exits carry the way out, and a PASS carries none of it.
#
# Two exits, because they are reached by different paths and only one of them was
# ever likely to be remembered: the full FAIL after the checks run, and the early
# abort when /v1/models does not meet the envelope rule (stricter than the app's own
# Test Connection, so third-party software genuinely stops there).
run_adapter_fail_wayout_case() {
  local name="adapter-fail-offers-the-way-out" rc=0 mode
  for mode in reject-history-image models-bare-array; do
    start_fixture "$mode" || { fail_case "$name" "fixture $mode failed to start"; stop_fixture; return; }
    rc=0
    TERM=dumb CONDUCK_TOKEN="$TOKEN" bash "$SCRIPT" --check-adapter "http://127.0.0.1:$PORT" \
      > "$TMP/doctor.out" 2>&1 < /dev/null || rc=$?
    stop_fixture
    if [ "$rc" != "1" ]; then
      fail_case "$name" "mode $mode exited $rc, expected 1"; return
    fi
    # Non-vacuous: the two modes really do leave by the two different exits.
    case "$mode" in
      reject-history-image)
        grep -qF 'checks failed.' "$TMP/doctor.out" || {
          fail_case "$name" "mode $mode did not reach the full FAIL exit"; return; } ;;
      models-bare-array)
        grep -qF 'so I stopped here' "$TMP/doctor.out" || {
          fail_case "$name" "mode $mode did not reach the early /v1/models abort"; return; } ;;
    esac
    # FACT 1 — someone who did not write this server is told the red may not be theirs.
    if ! grep -qiE "did(n.t| not) write this|did(n.t| not) build this" "$TMP/doctor.out"; then
      fail_case "$name" "mode $mode never addressed a reader who did not write the server"; return
    fi
    # FACT 2 — named concretely enough to recognise the software in front of them.
    if ! grep -qiE 'ollama|litellm|open ?webui' "$TMP/doctor.out"; then
      fail_case "$name" "mode $mode named no third-party server that is expected to fail"; return
    fi
    # FACT 3 — the check to run instead, and FACT 4 — pairing still available.
    if ! grep -qF -- '--check-server' "$TMP/doctor.out"; then
      fail_case "$name" "mode $mode did not offer --check-server as the way out"; return
    fi
    if ! grep -qF -- '--setup' "$TMP/doctor.out"; then
      fail_case "$name" "mode $mode did not say the server can still be paired"; return
    fi
  done

  # …and none of it on a PASS. A green adapter's author has no third-party server to
  # be reassured about, and hedging a clean pass reads as doubt about the pass.
  start_fixture good || { fail_case "$name" "fixture good failed to start"; stop_fixture; return; }
  rc=0
  TERM=dumb CONDUCK_TOKEN="$TOKEN" bash "$SCRIPT" --check-adapter "http://127.0.0.1:$PORT" \
    > "$TMP/doctor.out" 2>&1 < /dev/null || rc=$?
  stop_fixture
  if [ "$rc" != "0" ]; then
    fail_case "$name" "the conformant fixture exited $rc, expected 0"; return
  fi
  if grep -qiE "did(n.t| not) write this|did(n.t| not) build this" "$TMP/doctor.out"; then
    fail_case "$name" "a PASSING adapter check hedged itself with the not-yours way out"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# ========================================================== --check-server ====
# The server check matches the current Apple app's
# direct-endpoint request/body acceptance — NOT redirects or the adapter contract.
# It reuses the same fixture-adapter modes over the same loopback plumbing, so
# these cases share start_fixture/stop_fixture and the same output capture.
# Each case asserts the same trio as the adapter checks: exit code, machine
# summary (full CONDUCK_CHECK_SERVER grammar as the LAST line, required field values),
# and failed= consistent with the ✗ check-line count (the FAIL verdict line
# carries no [id], so '✗ \[' counts only genuine check failures).
#
# The frozen schema=2 grammar — field order fixed; any change must bump schema=
# (and this regex, and the harness). Mirrors how SUMMARY_RE freezes the adapter check.
SERVER_SUMMARY_RE='^CONDUCK_CHECK_SERVER schema=2 harness=[0-9][0-9.]* wire=(PASS|FAIL|NOT_RUN) models=(NOT_RUN|PASS|FAIL) chat=(NOT_RUN|PASS|FAIL) history_image=(NOT_RUN|PASS|FAIL) image_input=(VERIFIED|DECLINED|OPAQUE|IGNORED|NOT_RUN) model=(optional|required|none_advertised|NOT_RUN) model_ids=[0-9]+ auth=(bearer|none|NOT_RUN) checks=[0-9]+ failed=[0-9]+ exit=[0-9]+$'

# Case table: name|fixture-mode|keyless|expected-exit|required summary fragments(space-sep)
# keyless=yes runs the probe with CONDUCK_TOKEN set-but-EMPTY — the EXPLICIT
# keyless declaration, mirroring the app's .none auth scheme — and closed stdin,
# so a prompt would be a failure, not an answer. NO negative-auth request is sent
# either way. Names are server- prefixed so they never collide with the adapter
# case names when the positional filter is used.
SERVER_CASES='
server-good|good|no|0|wire=PASS models=PASS chat=PASS history_image=PASS image_input=VERIFIED model=optional model_ids=2 auth=bearer checks=4 failed=0 exit=0
server-direct-check|good|no|0|wire=PASS models=PASS chat=PASS history_image=PASS exit=0
server-require-accept|require-accept|no|0|wire=PASS exit=0
server-app-success-2xx|app-success-2xx|no|0|wire=PASS models=PASS chat=PASS history_image=PASS exit=0
server-chat-success-201|chat-success-201|no|0|wire=PASS models=PASS chat=PASS history_image=PASS exit=0
server-models-redirect-307|models-redirect-307|no|1|wire=FAIL models=FAIL chat=NOT_RUN checks=1 failed=1 exit=1
server-chat-redirect-308|chat-redirect-308|no|1|wire=FAIL chat=FAIL history_image=FAIL image_input=OPAQUE failed=3 exit=1
server-hardened-transport|good|no|0|wire=PASS exit=0
server-keyless|open|yes|0|wire=PASS auth=none exit=0
server-sse-on-stream-true|sse-on-stream-true|no|0|wire=PASS exit=0
server-wrong-content-type|wrong-content-type|no|0|wire=PASS exit=0
server-wrong-content-type-models|wrong-content-type-models|no|0|wire=PASS exit=0
server-empty-content|empty-content|no|0|wire=PASS chat=PASS image_input=IGNORED exit=0
server-tool-calls|tool-calls|no|0|wire=PASS exit=0
server-many-choices|many-choices|no|0|wire=PASS exit=0
server-malformed-second-choice|malformed-second-choice|no|1|wire=FAIL chat=FAIL exit=1
server-non-string-content|non-string-content|no|1|wire=FAIL chat=FAIL history_image=FAIL image_input=OPAQUE failed=3 exit=1
server-reject-history-image|reject-history-image|no|1|wire=FAIL history_image=FAIL chat=PASS failed=1 exit=1
server-text-only|text-only|no|0|wire=PASS image_input=DECLINED exit=0
server-silent-drop-image|silent-drop-image|no|0|wire=PASS image_input=IGNORED exit=0
server-models-bare-array|models-bare-array|no|1|wire=FAIL models=FAIL chat=NOT_RUN checks=1 failed=1 exit=1
server-models-empty-data|models-empty-data|no|0|wire=PASS chat=PASS model_ids=0 exit=0
server-models-no-id|models-no-id|no|0|wire=PASS model_ids=0 exit=0
server-models-html|models-html|no|1|wire=FAIL models=FAIL chat=NOT_RUN checks=1 failed=1 exit=1
server-models-slow|models-slow|no|1|wire=FAIL models=FAIL chat=NOT_RUN checks=1 failed=1 exit=1
server-require-model|require-model|no|0|wire=PASS model=required chat=PASS exit=0
server-require-long-model|require-long-model|no|0|wire=PASS model=required model_ids=1 chat=PASS exit=0
server-bogus-model-200|bogus-model-200|no|0|wire=PASS exit=0
server-bad-json|bad-json|no|1|wire=FAIL chat=FAIL exit=1
server-sse-despite-false|sse-despite-false|no|1|wire=FAIL chat=FAIL exit=1
'

run_server_case() { # run_server_case <table-row>
  local name mode keyless expexit frags
  local rest="$1"
  name="${rest%%|*}"; rest="${rest#*|}"
  mode="${rest%%|*}"; rest="${rest#*|}"
  keyless="${rest%%|*}"; rest="${rest#*|}"
  expexit="${rest%%|*}"; frags="${rest#*|}"

  start_fixture "$mode" || { fail_case "$name" "fixture failed to start"; stop_fixture; return; }

  local rc=0 hard_home=""
  if [ "$keyless" = "yes" ]; then
    TERM=dumb CONDUCK_TOKEN="" bash "$SCRIPT" --check-server "http://127.0.0.1:$PORT" \
      > "$TMP/doctor.out" 2>&1 < /dev/null || rc=$?
  elif [ "$name" = "server-hardened-transport" ]; then
    hard_home="$TMP/curl-home"; mkdir -p "$hard_home"
    printf 'output = "%s"\n' "$TMP/curlrc-output" > "$hard_home/.curlrc"
    HOME="$hard_home" http_proxy="http://127.0.0.1:9" \
      HTTP_PROXY="http://127.0.0.1:9" NO_PROXY="" no_proxy="" \
      TERM=dumb CONDUCK_TOKEN="$TOKEN" bash "$SCRIPT" --check-server "http://127.0.0.1:$PORT" \
      > "$TMP/doctor.out" 2>&1 < /dev/null || rc=$?
  else
    TERM=dumb CONDUCK_TOKEN="$TOKEN" bash "$SCRIPT" --check-server "http://127.0.0.1:$PORT" \
      > "$TMP/doctor.out" 2>&1 < /dev/null || rc=$?
  fi
  stop_fixture

  # 1 — exit code (wire=PASS iff exit=0)
  if [ "$rc" != "$expexit" ]; then
    fail_case "$name" "exit $rc, expected $expexit"; return
  fi
  if [ "$keyless" = "yes" ] && ! grep -qF 'Keyless by explicit' "$TMP/doctor.out"; then
    fail_case "$name" "CONDUCK_TOKEN= was not honoured as an explicit keyless declaration"; return
  fi
  # 2 — machine summary: last line, full grammar, exactly one, required fragments
  local summary frag
  assert_machine_output "$name" CONDUCK_CHECK_SERVER || return
  summary=$(tail -n 1 "$TMP/doctor.out")
  if ! printf '%s\n' "$summary" | grep -Eq "$SERVER_SUMMARY_RE"; then
    fail_case "$name" "last line isn't a valid CONDUCK_CHECK_SERVER schema=2 summary: $summary"; return
  fi
  for frag in $frags; do
    case " $summary " in *" $frag "*) ;; *)
      fail_case "$name" "summary lacks '$frag': $summary"; return ;;
    esac
  done
  # 3 — failed= consistent with the ✗ check-line count (the verdict line has no [id])
  local nfail nlines
  nfail=$(printf '%s\n' "$summary" | sed 's/.* failed=\([0-9]*\).*/\1/')
  nlines=$(grep -c '✗ \[' "$TMP/doctor.out")
  if [ "$nfail" != "$nlines" ]; then
    fail_case "$name" "summary failed=$nfail but $nlines ✗ check lines"; return
  fi
  case "$name" in
    *redirect-*)
      # Must be the REDIRECT diagnostic, not the preamble: the unconditional
      # --check-server intro already says "use the final server URL directly", so
      # greping that phrase alone stays green with the hint deleted. The failure
      # line is the only place the two halves appear together.
      if ! grep -qE '✗ .*HTTP 3[0-9][0-9] redirect — use the final server URL directly' "$TMP/doctor.out"; then
        fail_case "$name" "redirect failure omitted the direct-final-URL hint on its ✗ line"; return
      fi
      ;;
  esac
  # A server advertising more than one model id, graded on ONE path the TOOL chose
  # (here the model-less default route — a server that answers model-less requests
  # never reaches the first-advertised fallback). The way to grade another model has
  # to reach the operator on that path too, in the failure note AND in the closing
  # line, or a fan-out gateway is told it is broken on the strength of one draw.
  if [ "$name" = "server-reject-history-image" ]; then
    if ! grep -qF 'This turn named no model, so it graded the default route' "$TMP/doctor.out"; then
      fail_case "$name" "the failure never said which path it graded"; return
    fi
    if ! grep -qF 'CONDUCK_CHECK_SERVER_MODEL=<id> grades the model you plan to use' "$TMP/doctor.out"; then
      fail_case "$name" "the multi-model hint never reached the closing FAIL"; return
    fi
  fi
  if [ "$name" = "server-direct-check" ] &&
     ! grep -qF 'bash conduck-connect.sh --setup' "$TMP/doctor.out"; then
    fail_case "$name" "PASS output omitted the explicit --setup handoff"; return
  fi
  if [ "$name" = "server-direct-check" ] &&
     ! grep -qF 'core text-chat compatibility is green' "$TMP/doctor.out"; then
    fail_case "$name" "PASS output overstates the informational image result"; return
  fi
  if [ "$name" = "server-hardened-transport" ] &&
     [ -e "$TMP/curlrc-output" ]; then
    fail_case "$name" "server check honored ~/.curlrc and wrote an output file"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# Retired spellings and invalid modifier/action combinations must die during
# argument validation, before either check arms a summary EXIT trap — and each
# must die with ITS OWN message, so the exit code alone is never the assertion.
# NOTE: --generic is NOT here. It is a FUNCTIONAL legacy alias (App Store builds
# still emit it verbatim) and gets real coverage in run_generic_* below.
#
# name|args (word-split)|url(yes|no)|expected message fragment
#   url=yes appends https://example.com — proves a flag clash still wins over a
#   trailing URL, and gives cli-reject-bare-url its trigger.
#   url=no is mandatory for the bare-word and single-positional cases: with a URL
#   appended they die on the SECOND positional, never on the rejection they name.
CLI_REJECTION_CASES='
removed-old-adapter-flag|--doctor|no|--doctor is now --check-adapter
removed-old-server-flag|--compat|no|--compat is now --check-server
removed-show-qr|--show-qr|no|--show-qr is now --show-code
removed-openclaw-flag|--openclaw|no|--openclaw is gone — run --setup and pick your gateway from the list
removed-hermes-flag|--hermes|no|--hermes is gone — run --setup and pick your gateway from the list
removed-command-setup|setup|no|The retired setup subcommand is now --setup
removed-command-show-code|show-code|no|The retired show-code subcommand is now --show-code
removed-command-check-server|check server|no|The retired check server form is now --check-server [url]
removed-command-check-adapter|check adapter|no|The retired check adapter form is now --check-adapter [url]
second-positional|https://first.example.com|yes|Unknown argument: https://example.com
check-excl-two-actions|--check-adapter --check-server|yes|Choose one action only
generic-excl-check-server|--generic --check-server|no|Choose one action only
check-adapter-excl-allow-keyless-public|--check-adapter --allow-keyless-public|yes|--allow-keyless-public is a setup modifier
check-server-excl-deep|--check-server --deep|yes|--deep only works with --check-adapter
check-server-excl-files|--check-server --files|yes|--files only works with --check-adapter
cli-reject-bare-url||yes|Choose an action
setup-excl-check|--setup --check-server|yes|Choose one action only
show-code-excl-dry-run|--show-code --dry-run|no|--show-code changes no configuration but performs live verification
unknown-flag|--does-not-exist|no|Unknown argument: --does-not-exist
version-with-extra|--version --setup|no|--version must be used by itself
help-with-extra|--help --setup|no|--help must be used by itself
invalid-check-server-url|--check-server http://example.com|no|use https://
invalid-check-adapter-url|--check-adapter http://example.com|no|use https://
'

run_cli_rejection_case() { # run_cli_rejection_case <table-row>
  local name args url want rest="$1"
  name="${rest%%|*}"; rest="${rest#*|}"
  args="${rest%%|*}"; rest="${rest#*|}"
  url="${rest%%|*}"; want="${rest#*|}"
  local rc=0
  if [ "$url" = "yes" ]; then
    TERM=dumb bash "$SCRIPT" $args "https://example.com" \
      </dev/null > "$TMP/doctor.out" 2>&1 || rc=$?
  else
    TERM=dumb bash "$SCRIPT" $args \
      </dev/null > "$TMP/doctor.out" 2>&1 || rc=$?
  fi
  if [ "$rc" != "2" ]; then
    fail_case "$name" "usage error exited $rc, expected 2"; return
  fi
  if grep -Eq 'CONDUCK_CHECK_(SERVER|ADAPTER) schema=' "$TMP/doctor.out"; then
    fail_case "$name" "a check summary leaked before argument validation rejected the invocation"; return
  fi
  if ! grep -qF -- "$want" "$TMP/doctor.out"; then
    fail_case "$name" "rejection did not name its reason ('$want')"; return
  fi
  if ! grep -qF 'Usage error:' "$TMP/doctor.out"; then
    fail_case "$name" "exit 2 did not identify itself as a usage error"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

run_direct_setup_case() {
  local name="direct-setup" rc=0
  local home="$TMP/direct-setup-home" state="$TMP/direct-setup-state"
  # EOF intentionally stops at the first required local-port answer. Reaching
  # Step 2 proves --setup bypassed the welcome menu; no network request or
  # mutation occurs.
  #
  # HOME and XDG_CONFIG_HOME are isolated because Step 2 reads the state
  # directory to offer the gateways already set up on this machine. Without it
  # this case grades a different question on a developer laptop that has paired
  # a gateway than on a clean runner, and the difference is invisible until the
  # laptop is the thing that fails.
  mkdir -p "$home" "$state"
  printf '3\n' | env HOME="$home" XDG_CONFIG_HOME="$state" TERM=dumb \
    bash "$SCRIPT" --setup --dry-run \
    > "$TMP/doctor.out" 2>&1 || rc=$?
  if [ "$rc" != "1" ]; then
    fail_case "$name" "runtime EOF exited $rc, expected 1"; return
  fi
  if ! grep -qF 'Step 2 — your OpenAI-compatible server' "$TMP/doctor.out"; then
    fail_case "$name" "--setup did not enter the setup wizard"; return
  fi
  if ! grep -qF 'Need the local port (or an https URL).' "$TMP/doctor.out"; then
    fail_case "$name" "setup smoke test stopped for an unexpected reason"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

run_noarg_noninteractive_case() {
  local name="menu-noninteractive-eof" rc=0
  TERM=dumb bash "$SCRIPT" </dev/null > "$TMP/doctor.out" 2>&1 || rc=$?
  if [ "$rc" != "1" ]; then
    fail_case "$name" "menu EOF exited $rc, expected runtime exit 1"; return
  fi
  if ! grep -qF 'Welcome to Conduck Connect' "$TMP/doctor.out" ||
     ! grep -qF '1) Set up and pair a gateway' "$TMP/doctor.out" ||
     ! grep -qF 'No answer (the input ended)' "$TMP/doctor.out"; then
    fail_case "$name" "noninteractive menu did not show the welcome/options/EOF help"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

run_menu_q_case() {
  local name="menu-q-exit" rc=0
  local home="$TMP/menu-q-home" state="$TMP/menu-q-state" prompt_count
  mkdir -p "$home" "$state"
  # Info must be additive, bad input must retry, and q must still leave the
  # top-level menu without dispatching an action or creating setup state.
  PTY_ENV=(HOME="$home" XDG_CONFIG_HOME="$state")
  pty_run 10 $'i\nbogus\nq\n' > "$TMP/doctor.out" 2>&1 || rc=$?
  if [ "$rc" != "0" ] ||
     ! grep -qF 'Welcome to Conduck Connect' "$TMP/doctor.out" ||
     ! grep -qF 'About this step: Choose what conduck-connect should do' "$TMP/doctor.out" ||
     ! grep -qF 'Please enter one of the listed options.' "$TMP/doctor.out" ||
     ! grep -qF 'Nothing changed.' "$TMP/doctor.out"; then
    fail_case "$name" "info / invalid retry / q did not complete the PTY menu flow"; return
  fi
  prompt_count=$(grep -c 'Choose an option (Enter = no default; i = explain; q = stop)' "$TMP/doctor.out")
  if [ "$prompt_count" != "3" ]; then
    fail_case "$name" "the menu prompt appeared $prompt_count times, expected once per info/retry/q answer"; return
  fi
  if grep -qF 'Step 1 — find your gateway' "$TMP/doctor.out" ||
     [ -n "$(find "$home" "$state" -mindepth 1 -print -quit 2>/dev/null)" ]; then
    fail_case "$name" "q dispatched setup or wrote state after an explanation/retry"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# Exercise the prompt primitives in a real PTY without entering setup. This is
# deliberately below the menu case: `i`, `?`, `b`, and `q` are controls only at
# bounded decision prompts. Free-form and hidden-value prompts must keep those
# exact bytes as data, while every visible Enter meaning remains testable.
run_prompt_controls_case() {
  local name="prompt-controls-and-defaults" funcs input out rc=0
  local confirm_marker="$TMP/prompt-confirm-ran" manual_marker="$TMP/prompt-manual-ran"
  local quit_marker="$TMP/prompt-after-quit" choice_marker="$TMP/prompt-choice-q-ran"

  funcs=$(extract_funcs \
    explain_prompt quit_run confirm ask ask_default ask_secret require_choice print_and_wait)
  for fn in explain_prompt quit_run confirm ask ask_default ask_secret require_choice print_and_wait; do
    if ! printf '%s\n' "$funcs" | grep -qF "$fn()"; then
      fail_case "$name" "could not extract $fn from the release artifact"; return
    fi
  done

  input=$'bogus\ni\n\n'          # confirm: invalid, info, Enter = No
  input+=$'b\n'                   # confirm with allow-back: b = status 10
  input+=$'b\n\n'                # ordinary confirm: b rejected, Enter = No
  input+=$'\nnope\n?\n2\n'       # required choice: no default, invalid, help, valid
  input+=$'bogus\ni\n\n'          # printed command: invalid, info, Enter = ran
  input+=$'\n'                     # value prompt: Enter = displayed default
  input+=$'i\nb\nq\n'             # free-form values stay literal
  input+=$'i\nb\nq\n'             # secret values stay literal too

  out=$(env -u CI TERM=dumb FUNCS="$funcs" \
      CONFIRM_MARKER="$confirm_marker" MANUAL_MARKER="$manual_marker" \
      python3 "$PTY_RUN" 10 "$input" bash -c '
eval "$FUNCS"
BOLD=""; DIM=""; RESET=""
DRY_RUN=false; REUSE_ONLY=false
say()  { printf "SAY %s\n" "$*"; }
note() { printf "NOTE %s\n" "$*"; }
warn() { printf "WARN %s\n" "$*"; }
explain_action() { printf "INFO %s\n" "$1"; }
mutate_guard() { printf "GUARD %s\n" "$1"; return 0; }
plan_add() { printf "PLAN %s\n" "$*"; }

if confirm "Fixture confirmation" "fixture.confirm"; then
  : > "$CONFIRM_MARKER"
  printf "CONFIRM=yes\n"
else
  printf "CONFIRM=no rc=%s\n" "$?"
fi

confirm "Back-capable confirmation" "fixture.back" true
printf "BACK_ALLOWED_RC=%s\n" "$?"
confirm "Ordinary confirmation" "fixture.no_back"
printf "BACK_BLOCKED_RC=%s\n" "$?"

choice=$(require_choice "Choose 1-2" "^[12]$" "fixture.choice")
printf "CHOICE=%s rc=%s\n" "$choice" "$?"

if print_and_wait "fixture.manual" "fixture manual action" "touch $MANUAL_MARKER"; then
  printf "MANUAL=acknowledged\n"
else
  printf "MANUAL=skipped rc=%s\n" "$?"
fi

defaulted=$(ask_default "Fixture value" "fixture-default")
printf "DEFAULT=%s\n" "$defaulted"
free_i=$(ask "Free i" ""); free_b=$(ask "Free b" ""); free_q=$(ask "Free q" "")
printf "FREEFORM=%s|%s|%s\n" "$free_i" "$free_b" "$free_q"
secret_i=$(ask_secret "Secret i" "leave empty"); secret_b=$(ask_secret "Secret b" "leave empty"); secret_q=$(ask_secret "Secret q" "leave empty")
printf "SECRETS=%s|%s|%s\n" "$secret_i" "$secret_b" "$secret_q"
' 2>&1) || rc=$?
  printf -- '--- prompt primitives ---\n%s\n' "$out" > "$TMP/doctor.out"

  if [ "$rc" != "0" ] ||
     ! printf '%s\n' "$out" | grep -qF 'CONFIRM=no rc=1' ||
     ! printf '%s\n' "$out" | grep -qF 'INFO fixture.confirm' ||
     ! printf '%s\n' "$out" | grep -qF 'Please answer y or n, press Enter for No' ||
     ! printf '%s\n' "$out" | grep -qF 'BACK_ALLOWED_RC=10' ||
     ! printf '%s\n' "$out" | grep -qF 'Enter = No; i = explain; b = back; q = stop' ||
     ! printf '%s\n' "$out" | grep -qF 'BACK_BLOCKED_RC=1' ||
     ! printf '%s\n' "$out" | grep -qF 'Back is not available at this step' ||
     ! printf '%s\n' "$out" | grep -qF 'CHOICE=2 rc=0' ||
     ! printf '%s\n' "$out" | grep -qF 'INFO fixture.choice' ||
     [ "$(printf '%s\n' "$out" | grep -c 'Please enter one of the listed options.')" != "2" ]; then
    fail_case "$name" "confirm or required-choice controls lost their retry/info/default semantics"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF 'MANUAL=acknowledged' ||
     ! printf '%s\n' "$out" | grep -qF 'INFO fixture.manual' ||
     ! printf '%s\n' "$out" | grep -qF 'Please press Enter only after running it' ||
     ! printf '%s\n' "$out" | grep -qF 'DEFAULT=fixture-default' ||
     [ -e "$confirm_marker" ] || [ -e "$manual_marker" ]; then
    fail_case "$name" "an Enter default was unclear, changed meaning, or executed the displayed command"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF 'FREEFORM=i|b|q' ||
     ! printf '%s\n' "$out" | grep -qF 'SECRETS=i|b|q' ||
     ! printf '%s\n' "$out" | grep -qF 'Secret i (Enter = leave empty)'; then
    fail_case "$name" "a navigation key was consumed by a free-form or secret prompt"; return
  fi

  # require_choice runs in $(), so q must survive as a literal sentinel for its
  # parent to interpret; it must not exit from inside the subshell.
  rc=0
  out=$(env -u CI TERM=dumb FUNCS="$funcs" CHOICE_MARKER="$choice_marker" \
      python3 "$PTY_RUN" 10 $'q\n' bash -c '
eval "$FUNCS"
BOLD=""; RESET=""
say() { printf "SAY %s\n" "$*"; }; note() { printf "NOTE %s\n" "$*"; }; warn() { printf "WARN %s\n" "$*"; }
choice=$(require_choice "Choose 1-2" "^[12]$" "fixture.choice") || exit $?
printf "CHOICE_SENTINEL=%s\n" "$choice"
[ "$choice" = q ] || : > "$CHOICE_MARKER"
' 2>&1) || rc=$?
  printf -- '--- required-choice q ---\n%s\n' "$out" >> "$TMP/doctor.out"
  if [ "$rc" != "0" ] || ! printf '%s\n' "$out" | grep -qF 'CHOICE_SENTINEL=q' || [ -e "$choice_marker" ]; then
    fail_case "$name" "require_choice did not return literal q through command substitution"; return
  fi

  # At a consent prompt q belongs to the whole run. Nothing after the prompt may
  # execute, and the clean stop still explains that earlier actions are not undone.
  rc=0
  out=$(env -u CI TERM=dumb FUNCS="$funcs" QUIT_MARKER="$quit_marker" \
      python3 "$PTY_RUN" 10 $'q\n' bash -c '
eval "$FUNCS"
BOLD=""; RESET=""
say() { printf "SAY %s\n" "$*"; }; note() { printf "NOTE %s\n" "$*"; }; warn() { printf "WARN %s\n" "$*"; }
confirm "Fixture confirmation" "fixture.confirm"
: > "$QUIT_MARKER"
' 2>&1) || rc=$?
  printf -- '--- consent q ---\n%s\n' "$out" >> "$TMP/doctor.out"
  if [ "$rc" != "0" ] ||
     ! printf '%s\n' "$out" | grep -qF 'Stopped here. No further setup actions will run.' ||
     ! printf '%s\n' "$out" | grep -qF 'does not undo' ||
     [ -e "$quit_marker" ]; then
    fail_case "$name" "q did not stop cleanly before the next action"; return
  fi

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# A syntactically valid port can still be the wrong server. The review screen is
# the last mutation-free place to catch that mistake, so b must clear the draft,
# collect it again, and carry only the corrected value into the exposure step.
run_custom_review_back_case() {
  local name="custom-review-back-corrects-port" rc=0 review_count
  local home="$TMP/custom-review-home" state="$TMP/custom-review-state"
  mkdir -p "$home" "$state"
  PTY_ENV=(HOME="$home" XDG_CONFIG_HOME="$state")
  # Per pass: name, n = no https URL, the port, 2 = keyless (the auth question is
  # a numbered choice under --dry-run, which never solicits a real token), Enter
  # = no model, then b / Enter at the review. A final q stops in Step 3.
  pty_run 10 $'Wrong gateway\nn\n1111\n2\n\nb\nCorrected gateway\nn\n2222\n2\n\n\nq\n' \
    --generic --dry-run > "$TMP/doctor.out" 2>&1 || rc=$?

  review_count=$(grep -c 'Review this gateway' "$TMP/doctor.out")
  if [ "$rc" != "0" ] || [ "$review_count" != "2" ] ||
     ! grep -qF 'Name:           Wrong gateway' "$TMP/doctor.out" ||
     ! grep -qF 'Address:        http://127.0.0.1:1111 (local; HTTPS comes next)' "$TMP/doctor.out" ||
     ! grep -qF '↩ Re-entering the custom gateway answers. Nothing has been changed.' "$TMP/doctor.out" ||
     ! grep -qF 'Name:           Corrected gateway' "$TMP/doctor.out" ||
     ! grep -qF 'Address:        http://127.0.0.1:2222 (local; HTTPS comes next)' "$TMP/doctor.out" ||
     ! grep -qF 'Step 3 — how should your phone reach this gateway?' "$TMP/doctor.out" ||
     ! grep -qF 'Stopped here. No further setup actions will run.' "$TMP/doctor.out"; then
    fail_case "$name" "review b did not replace the valid-but-wrong custom port before continuing"; return
  fi
  if [ "$(grep -c 'Enter = continue; b = re-enter these answers; i = explain; q = stop' "$TMP/doctor.out")" != "2" ] ||
     [ -n "$(find "$home" "$state" -mindepth 1 -print -quit 2>/dev/null)" ]; then
    fail_case "$name" "review did not show its Enter/b meanings twice or the dry run wrote state"; return
  fi

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

run_menu_setup_case() {
  local name="menu-action-1-setup" rc=0
  local home="$TMP/menu-setup-home" state="$TMP/menu-setup-state"
  # 1 = setup, 3 = another server, Enter = default name, n = local,
  # Enter = invalid blank port (which re-prompts), q = deliberate clean stop.
  mkdir -p "$home" "$state"
  PTY_ENV=(HOME="$home" XDG_CONFIG_HOME="$state")
  pty_run 10 $'1\n3\n\nn\n\nq\n' > "$TMP/doctor.out" 2>&1 || rc=$?
  if [ "$rc" != "0" ] ||
     ! grep -qF 'Step 1 — find your gateway' "$TMP/doctor.out" ||
     ! grep -qF 'Step 2 — your OpenAI-compatible server' "$TMP/doctor.out" ||
     ! grep -qF 'A local setup needs a port. Enter its number, or press b to restart these answers and choose HTTPS.' "$TMP/doctor.out" ||
     ! grep -qF 'Stopped here. No further setup actions will run.' "$TMP/doctor.out"; then
    fail_case "$name" "menu option 1 did not retry the blank port and stop cleanly"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

run_detected_requires_choice_case() {
  local name="setup-detected-still-requires-choice" rc=0 home="$TMP/detected-home"
  mkdir -p "$home/.openclaw"
  printf '{}\n' > "$home/.openclaw/openclaw.json"
  # Blank at the gateway question must re-prompt even though OpenClaw is found;
  # 3 then proves the user can deliberately configure another server.
  PTY_ENV=(HOME="$home")
  pty_run 10 $'\n3\n\nn\n\nq\n' --setup > "$TMP/doctor.out" 2>&1 || rc=$?
  if [ "$rc" != "0" ] ||
     ! grep -qF 'We found these on this machine: openclaw' "$TMP/doctor.out" ||
     ! grep -qF 'Please enter one of the listed options.' "$TMP/doctor.out" ||
     ! grep -qF 'Step 2 — your OpenAI-compatible server' "$TMP/doctor.out" ||
     ! grep -qF 'Stopped here. No further setup actions will run.' "$TMP/doctor.out"; then
    fail_case "$name" "a detected gateway was treated as an Enter default"; return
  fi
  if grep -qF 'Step 2 — OpenClaw' "$TMP/doctor.out"; then
    fail_case "$name" "blank input silently selected detected OpenClaw"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

run_menu_check_case() { # run_menu_check_case <server|adapter>
  local kind="$1" name="menu-action-check-$1" choice prefix rc=0
  if [ "$kind" = "server" ]; then
    choice=2; prefix="CONDUCK_CHECK_SERVER"
  else
    choice=3; prefix="CONDUCK_CHECK_ADAPTER"
  fi
  start_fixture good || { fail_case "$name" "fixture failed to start"; stop_fixture; return; }
  local input
  input="$choice"$'\nhttp://127.0.0.1:'"$PORT"$'\nn\n'
  PTY_ENV=(CONDUCK_TOKEN="$TOKEN")
  pty_run 30 "$input" > "$TMP/doctor.out" 2>&1 || rc=$?
  stop_fixture
  if [ "$(grep -c "^$prefix schema=" "$TMP/doctor.out")" != "1" ]; then
    fail_case "$name" "expected exactly 1 $prefix summary line before the handoff"; return
  fi
  if [ "$rc" != "0" ] ||
     ! grep -qF "$prefix schema=" "$TMP/doctor.out" ||
     ! grep -qF 'Would you like to continue with setup and pairing?' "$TMP/doctor.out" ||
     ! grep -qF 'No setup changes were made.' "$TMP/doctor.out"; then
    fail_case "$name" "menu check did not PASS and offer setup"; return
  fi
  if ! grep -qF '2) Check existing OpenAI-compatible software (not built for Conduck)' "$TMP/doctor.out" ||
     ! grep -qF '3) Check an adapter built specifically for Conduck' "$TMP/doctor.out"; then
    fail_case "$name" "the menu did not state the built-for-Conduck provenance decision"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

write_valid_profile() { # write_valid_profile <path> <id> <name> <url>
  printf '{"schemaVersion":1,"gateway":{"id":"%s","kind":"custom","name":"%s","auth":"bearer","transport":"public","reach":"public","url":"%s"},"fileServer":null}\n' \
    "$2" "$3" "$4" > "$1"
}

run_menu_show_code_case() {
  local name="menu-action-4-show-code" rc=0 state="$TMP/menu-state"
  mkdir -p "$state/conduck"
  write_valid_profile "$state/conduck/profile-custom-good.json" \
    "custom-good" "Good gateway" "https://good.example.test"
  PTY_ENV=(XDG_CONFIG_HOME="$state")
  pty_run 10 $'4\n\004' > "$TMP/doctor.out" 2>&1 || rc=$?
  if [ "$rc" = "0" ] ||
     ! grep -qF '4) Show a saved setup code' "$TMP/doctor.out"; then
    fail_case "$name" "menu did not offer option 4 for a complete saved profile"; return
  fi
  # DISPATCH, not menu text: these are printed only by the --show-code path.
  if ! grep -qF 'Re-show your pairing code — skips setup and changes no configuration' "$TMP/doctor.out"; then
    fail_case "$name" "menu option 4 did not dispatch the --show-code path"; return
  fi
  if ! grep -qF 'Using saved profile: custom (Good gateway) → https://good.example.test' "$TMP/doctor.out" ||
     ! grep -qF 'A token is required (the saved profile says auth=bearer)' "$TMP/doctor.out"; then
    fail_case "$name" "the complete profile was not loaded before the controlled token stop"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# The other half of the gate: a profile that EXISTS but doesn't parse as schema 1
# must not be advertised. Offering option 4 here would hand the user a menu entry
# that hard-errors the moment it is chosen.
run_menu_corrupt_profile_case() {
  local name="menu-corrupt-profile-hides-show-code" rc=0 state="$TMP/corrupt-state"
  mkdir -p "$state/conduck"
  printf '{}\n' > "$state/conduck/profile-invalid.json"
  PTY_ENV=(XDG_CONFIG_HOME="$state")
  pty_run 10 $'4\n' > "$TMP/doctor.out" 2>&1 || rc=$?
  if [ "$rc" = "0" ]; then
    fail_case "$name" "an unparseable profile still let option 4 run"; return
  fi
  if grep -qF '4) Show a saved setup code' "$TMP/doctor.out"; then
    fail_case "$name" "menu offered option 4 for a profile it cannot parse"; return
  fi
  if ! grep -qF 'Set up a gateway, or check one before pairing.' "$TMP/doctor.out"; then
    fail_case "$name" "menu header promised a saved-code option that isn't offered"; return
  fi
  if grep -qF 'Re-show your pairing code' "$TMP/doctor.out"; then
    fail_case "$name" "4 dispatched --show-code even though it was never offered"; return
  fi
  if ! grep -qF 'Please enter one of the listed options.' "$TMP/doctor.out"; then
    fail_case "$name" "4 was silently accepted instead of being re-prompted"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# A valid JSON file with schemaVersion=1 is still unusable when its required
# routing fields are absent. It must be filtered at the same gate as malformed
# JSON, not advertised and rejected only after the user chooses option 4.
run_menu_partial_profile_case() {
  local name="menu-partial-profile-hides-show-code" rc=0 state="$TMP/partial-state"
  mkdir -p "$state/conduck"
  printf '{"schemaVersion":1,"gateway":{},"fileServer":null}\n' \
    > "$state/conduck/profile-partial.json"
  PTY_ENV=(XDG_CONFIG_HOME="$state")
  pty_run 10 $'4\n' > "$TMP/doctor.out" 2>&1 || rc=$?
  if [ "$rc" = "0" ]; then
    fail_case "$name" "a partial schema-1 profile still let option 4 run"; return
  fi
  if grep -qF '4) Show a saved setup code' "$TMP/doctor.out" ||
     grep -qF 'Re-show your pairing code' "$TMP/doctor.out"; then
    fail_case "$name" "the partial schema-1 profile was advertised or dispatched"; return
  fi
  if ! grep -qF 'Please enter one of the listed options.' "$TMP/doctor.out"; then
    fail_case "$name" "the unavailable option was silently accepted"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# Picker and loader share the same validator. With two valid profiles and one
# corrupt/partial file, the picker must number only the usable pair.
run_mixed_profile_picker_case() {
  local name="mixed-profile-picker-filters-invalid" rc=0 state="$TMP/mixed-state"
  mkdir -p "$state/conduck"
  write_valid_profile "$state/conduck/profile-a.json" \
    "custom-a" "Good A" "https://a.example.test"
  write_valid_profile "$state/conduck/profile-b.json" \
    "custom-b" "Good B" "https://b.example.test"
  printf '{"schemaVersion":1,"gateway":{"id":"custom-broken","kind":"custom","name":"Broken","auth":"bearer","transport":"public","reach":"public","url":"https://broken.example.test"},"fileServer":{}}\n' \
    > "$state/conduck/profile-c-broken.json"
  PTY_ENV=(XDG_CONFIG_HOME="$state")
  pty_run 10 $'1\n\004' --show-code > "$TMP/doctor.out" 2>&1 || rc=$?
  if [ "$rc" = "0" ]; then
    fail_case "$name" "the controlled EOF after selecting a profile unexpectedly succeeded"; return
  fi
  if ! grep -qF 'Which profile? Choose 1-2' "$TMP/doctor.out" ||
     ! grep -qF 'custom (Good A) — https://a.example.test' "$TMP/doctor.out" ||
     ! grep -qF 'custom (Good B) — https://b.example.test' "$TMP/doctor.out"; then
    fail_case "$name" "the picker did not list exactly the two complete profiles"; return
  fi
  if grep -qF 'profile-c-broken' "$TMP/doctor.out" ||
     grep -qF 'Broken' "$TMP/doctor.out" ||
     grep -qF 'Choose 1-3' "$TMP/doctor.out"; then
    fail_case "$name" "the unusable profile leaked into the picker"; return
  fi
  if ! grep -qF 'Using saved profile: custom (Good A) → https://a.example.test' "$TMP/doctor.out"; then
    fail_case "$name" "selection 1 did not load the first valid profile"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

run_profile_local_port_gate_case() {
  local name="profile-local-port-gate" rc=0 state="$TMP/local-port-state"
  mkdir -p "$state/conduck"

  # Both local-mapping transports are unusable for a custom gateway without a
  # saved loopback port. If either slips through, option 4 appears.
  printf '{"schemaVersion":1,"gateway":{"id":"custom-no-port-private","kind":"custom","name":"No port private","auth":"none","transport":"tailscale","reach":"private","url":"https://private.example.test"},"fileServer":null}\n' \
    > "$state/conduck/profile-custom-no-port-private.json"
  printf '{"schemaVersion":1,"gateway":{"id":"custom-no-port-public","kind":"custom","name":"No port public","auth":"none","transport":"funnel","reach":"public","url":"https://public.example.test"},"fileServer":null}\n' \
    > "$state/conduck/profile-custom-no-port-public.json"
  PTY_ENV=(XDG_CONFIG_HOME="$state")
  pty_run 10 $'4\n' > "$TMP/doctor.out" 2>&1 || rc=$?
  if [ "$rc" = "0" ] ||
     grep -qF '4) Show a saved setup code' "$TMP/doctor.out" ||
     grep -qF 'Re-show your pairing code' "$TMP/doctor.out"; then
    fail_case "$name" "a custom Tailscale/Funnel profile without localPort was advertised"; return
  fi

  # Backward compatibility: OpenClaw/Hermes profiles may omit localPort because
  # the loader can re-derive it from their canonical configuration.
  state="$TMP/legacy-port-state"
  mkdir -p "$state/conduck"
  printf '{"schemaVersion":1,"gateway":{"id":"openclaw","kind":"openclaw","auth":"none","transport":"tailscale","reach":"private","url":"https://legacy.example.test"},"fileServer":null}\n' \
    > "$state/conduck/profile-openclaw.json"
  rc=0
  PTY_ENV=(XDG_CONFIG_HOME="$state")
  pty_run 10 $'q\n' > "$TMP/doctor.out" 2>&1 || rc=$?
  if [ "$rc" != "0" ] ||
     ! grep -qF '4) Show a saved setup code' "$TMP/doctor.out"; then
    fail_case "$name" "a valid legacy OpenClaw profile without localPort was hidden"; return
  fi

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# `selfsigned` is not a transport, and `certFP` is not a field. A saved profile
# naming either describes a setup the app cannot use, so the menu must filter it
# out rather than advertise it and fail after the user picks it. The control arm
# proves the filter is the TRANSPORT and not the picker rejecting everything.
run_profile_selfsigned_transport_refused_case() {
  local name="profile-selfsigned-transport-refused" rc=0 state="$TMP/selfsigned-transport-state"
  local fp="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  mkdir -p "$state/conduck"

  printf '{"schemaVersion":1,"gateway":{"id":"custom-pin","kind":"custom","name":"Pinned","auth":"none","transport":"selfsigned","reach":"private","url":"https://gateway.example.test:8443","certFP":"%s"},"fileServer":{"url":"https://files.example.test:9443","reach":"private"}}\n' \
    "$fp" > "$state/conduck/profile-custom-pin.json"
  PTY_ENV=(XDG_CONFIG_HOME="$state")
  pty_run 10 $'4\n' > "$TMP/doctor.out" 2>&1 || rc=$?
  if [ "$rc" = "0" ] ||
     grep -qF '4) Show a saved setup code' "$TMP/doctor.out" ||
     grep -qF 'Re-show your pairing code' "$TMP/doctor.out"; then
    fail_case "$name" "a profile pinning a self-signed certificate was still advertised"; return
  fi

  # Control: the same gateway on a trusted-certificate transport IS advertised.
  state="$TMP/public-transport-state"
  mkdir -p "$state/conduck"
  printf '{"schemaVersion":1,"gateway":{"id":"custom-trusted","kind":"custom","name":"Trusted","auth":"none","transport":"public","reach":"private","url":"https://gateway.example.test:8443"},"fileServer":{"url":"https://files.example.test:9443","reach":"private"}}\n' \
    > "$state/conduck/profile-custom-trusted.json"
  rc=0
  PTY_ENV=(XDG_CONFIG_HOME="$state")
  pty_run 10 $'q\n' > "$TMP/doctor.out" 2>&1 || rc=$?
  if [ "$rc" != "0" ] ||
     ! grep -qF '4) Show a saved setup code' "$TMP/doctor.out"; then
    fail_case "$name" "a valid trusted-certificate profile was hidden"; return
  fi

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# Drive the PRODUCTION classify_own_https with curl's verdict and the two
# certificate readers supplied, so every arm of the gate is reachable without a
# real TLS server. Everything the branch decides — accept, or stop and explain —
# is the shipped code's own.
# Args: <function-source> <curl-exit-code> <openssl-verify-code> <date-problem>.
run_classify_own_https_isolated() {
  FUNCS="$1" CURL_RC="$2" VERIFY_CODE="$3" DATE_PROBLEM="$4" bash -c '
eval "$FUNCS"
say()  { printf "%s\n" "$*"; }
ok()   { printf "OK %s\n" "$*"; }
bad()  { printf "BAD %s\n" "$*"; }
note() { printf "%s\n" "$*"; }
warn() { printf "WARN %s\n" "$*"; }
confirm() { printf "CONFIRM %s\n" "$*"; return 0; }
die()  { printf "DIE %s\n" "$*"; exit 1; }
plan_add() { :; }
curl() { return "$CURL_RC"; }
cert_verify_code()      { printf "%s" "$VERIFY_CODE"; }
cert_leaf_date_problem() { printf "%s" "$DATE_PROBLEM"; }
BOLD=""; RESET=""
DRY_RUN=false
TRANSPORT=""
GW_URL="https://gw.example.test"
classify_own_https
printf "TRANSPORT=%s\n" "$TRANSPORT"
'
}

# The exposure menu's option 4 is a GATE, not a fork. Apple's App Transport
# Security refuses a chain the device does not trust before the app is consulted,
# and a fingerprint pin can only NARROW trust a device already has — so "pin it
# anyway" has no working outcome, and a setup code minted on that promise fails
# on the phone. This creation path shipped with ZERO coverage, which is how the
# pin-anyway fork survived; the assertions below are written as rules about the
# released artifact so a future re-introduction fails here rather than shipping.
run_own_https_trust_gate_case() {
  local name="own-https-requires-trusted-cert" funcs out rc

  funcs=$(extract_funcs classify_own_https)
  if [ -z "$funcs" ] || ! printf '%s\n' "$funcs" | grep -qF 'classify_own_https()'; then
    fail_case "$name" "could not extract classify_own_https from the release artifact"; return
  fi

  # A certificate this machine trusts is the ONLY way through. curl exit 0.
  rc=0
  out=$(run_classify_own_https_isolated "$funcs" 0 0 "") || rc=$?
  printf -- '--- trusted certificate ---\n%s\n' "$out" > "$TMP/doctor.out"
  if [ "$rc" != "0" ] || ! printf '%s\n' "$out" | grep -qF 'TRANSPORT=public'; then
    fail_case "$name" "a trusted certificate did not continue setup on the public transport"; return
  fi

  # curl 60 = the peer certificate could not be authenticated. Verify code 18 is
  # "self-signed certificate" — the exact case that used to be pinned.
  rc=0
  out=$(run_classify_own_https_isolated "$funcs" 60 18 "") || rc=$?
  printf -- '--- untrusted (self-signed) certificate ---\n%s\n' "$out" >> "$TMP/doctor.out"
  if [ "$rc" = "0" ] || ! printf '%s\n' "$out" | grep -qF 'DIE '; then
    fail_case "$name" "an untrusted certificate did not stop the run"; return
  fi
  if printf '%s\n' "$out" | grep -qF 'CONFIRM '; then
    fail_case "$name" "the gate still offers an accept-it-anyway override"; return
  fi
  if printf '%s\n' "$out" | grep -qF 'TRANSPORT='; then
    fail_case "$name" "the gate fell through to a transport instead of stopping"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF "doesn't trust"; then
    fail_case "$name" "the refusal did not name WHY the certificate failed"; return
  fi
  # Refusing without a remedy just moves the dead end. All three free routes,
  # named — Tailscale Serve, Let's Encrypt (IP certificates included), a proxy.
  local route
  for route in 'Tailscale Serve' "Let's Encrypt" 'Caddy'; do
    if ! printf '%s\n' "$out" | grep -qF "$route"; then
      fail_case "$name" "the refusal did not name the free route: $route"; return
    fi
  done

  # The reason is diagnostic, not decorative: a wrong clock and a wrong hostname
  # are different jobs from "no trusted issuer", and both readers still run.
  rc=0
  out=$(run_classify_own_https_isolated "$funcs" 60 18 "expired") || rc=$?
  printf -- '--- untrusted AND expired ---\n%s\n' "$out" >> "$TMP/doctor.out"
  if [ "$rc" = "0" ] || ! printf '%s\n' "$out" | grep -qF 'has expired'; then
    fail_case "$name" "an untrusted, expired certificate did not report its expiry"; return
  fi
  rc=0
  out=$(run_classify_own_https_isolated "$funcs" 60 0 "") || rc=$?
  printf -- '--- wrong hostname ---\n%s\n' "$out" >> "$TMP/doctor.out"
  if [ "$rc" = "0" ] || ! printf '%s\n' "$out" | grep -qF 'different hostname'; then
    fail_case "$name" "a wrong-host certificate was not diagnosed as such"; return
  fi

  # Artifact-wide: nothing may mint, carry, or honour a pin any more. `certFP`
  # and `selfsigned` are wire/profile names — one occurrence anywhere means a
  # code the app rejects, or a saved profile it cannot use.
  local gone
  for gone in compute_spki_hex hex_to_b64 --pinnedpubkey certFP selfsigned; do
    if grep -qF -- "$gone" "$SCRIPT"; then
      fail_case "$name" "the released artifact still carries '$gone'"; return
    fi
  done
  # …but the two readers that explain the failure stay. Deleting them would turn
  # every refusal into an unexplained one.
  local kept
  for kept in cert_verify_code cert_leaf_date_problem; do
    if [ "$(grep -c "^$kept()" "$SCRIPT")" != "1" ]; then
      fail_case "$name" "the certificate diagnosis helper '$kept' is gone"; return
    fi
  done

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# Drive the PRODUCTION exposure menu and its `i` explainer without touching the
# host: `i` prints the comparison and `b` goes back, so no branch past the menu is
# ever entered and nothing is ever exposed. The explainer has to print on STDERR
# here — the real require_choice runs inside a command substitution, so help text
# on stdout would BE the answer. Its lines are tagged so the menu rows and the
# explainer can be graded apart.
# Args: <function-source> <cloudflared-present: yes|no>.
run_exposure_menu_isolated() {
  env -u CI TERM=dumb FUNCS="$1" CF_PRESENT="$2" \
    python3 "$PTY_RUN" 10 $'i\nb\n' bash -c '
eval "$FUNCS"
original=$(declare -f explain_exposure_paths)
eval "${original/explain_exposure_paths/original_explain_exposure_paths}"
EXPLAINING=false
explain_exposure_paths() {
  EXPLAINING=true
  original_explain_exposure_paths
  EXPLAINING=false
}
say() {
  if [ "$EXPLAINING" = true ]; then printf "EXPLAINER %s\n" "$*"
  else printf "%s\n" "$*"
  fi
}
note()  { printf "%s\n" "$*"; }
head_() { printf "%s\n" "$*"; }
ok()    { printf "OK %s\n" "$*"; }
warn()  { printf "WARN %s\n" "$*"; }
die()   { printf "DIE %s\n" "$*"; exit 1; }
have()  { case "$1" in cloudflared) [ "$CF_PRESENT" = yes ] ;; *) return 1 ;; esac; }
ts_targets()         { :; }
tailscale_dns_name() { printf ""; }
# Any branch after the menu is a test failure: i and b must not expose, classify,
# or even ask for another value.
keyless_public_guard() { printf "SIDE_EFFECT keyless guard\n"; return 99; }
tailscale_expose()     { printf "SIDE_EFFECT tailscale\n"; return 99; }
print_and_wait()       { printf "SIDE_EFFECT printed command\n"; return 99; }
ask()                  { printf "SIDE_EFFECT free-form ask\n"; return 99; }
ask_url()              { printf "SIDE_EFFECT URL ask\n"; return 99; }
scope_choice()         { printf "SIDE_EFFECT scope\n"; return 99; }
BOLD=""; RESET=""; DIM=""
DRY_RUN=true
SETUP_FROM_CHECK=false
GW_URL=""
GW_LOCAL_PORT="8080"
choose_exposure
' 2>&1
}

# The exposure menu is where a user commits to who can reach their gateway, so a
# row that is easy to misread costs them a wrong exposure or a purchase they did
# not need. Two rows carry that weight. Row 3 wants a domain the user manages in
# Cloudflare; row 4 is where a `cloudflared tunnel --url` quick tunnel belongs —
# by far the commonest casual way one of these gateways gets exposed. Row 3's
# "✓ cloudflared found" is the only cloudflared word on the menu unless row 4
# names the quick-tunnel address, so an unnamed quick tunnel points its own user
# at the single option that asks them to buy a domain. The rows are also graded
# for terseness and for staying a no-default, unrecommended choice: an explainer
# that grows into the menu is how a terse row becomes a paragraph nobody reads.
run_exposure_menu_quick_tunnel_case() {
  local name="exposure-menu-places-the-quick-tunnel" funcs out out_nocf rc
  local row3 row4 explainer prompt row lines

  funcs=$(extract_funcs choose_exposure explain_exposure_paths require_choice explain_prompt)
  if [ -z "$funcs" ] ||
     ! printf '%s\n' "$funcs" | grep -qF 'choose_exposure()' ||
     ! printf '%s\n' "$funcs" | grep -qF 'explain_exposure_paths()' ||
     ! printf '%s\n' "$funcs" | grep -qF 'require_choice()' ||
     ! printf '%s\n' "$funcs" | grep -qF 'explain_prompt()'; then
    fail_case "$name" "could not extract the exposure menu from the release artifact"; return
  fi

  rc=0
  out=$(run_exposure_menu_isolated "$funcs" yes) || rc=$?
  printf -- '--- menu, cloudflared present ---\n%s\n' "$out" > "$TMP/doctor.out"
  # 10 is the menu's own go-back status: 'b' was taken, no exposure was attempted.
  if [ "$rc" != "10" ]; then
    fail_case "$name" "the menu did not go back on 'b' (status $rc) — the rows below may come from another path"; return
  fi
  if printf '%s\n' "$out" | grep -qF 'SIDE_EFFECT '; then
    fail_case "$name" "info then back entered an exposure branch"; return
  fi
  for row in 1 2 3 4; do
    if ! printf '%s\n' "$out" | grep -qF "  $row)"; then
      fail_case "$name" "the menu no longer prints row $row"; return
    fi
  done

  row3=$(printf '%s\n' "$out" | grep '^  3)')
  row4=$(printf '%s\n' "$out" | grep '^  4)')
  # Non-vacuous: the cloudflared detection this case reasons about is really live.
  if ! printf '%s\n' "$row3" | grep -qF 'cloudflared found'; then
    fail_case "$name" "row 3 did not report the cloudflared this run has — the stub is not wired"; return
  fi
  # Row 4 must be recognisable to someone holding a quick-tunnel address: the
  # *.trycloudflare.com shape they are looking at, and Cloudflare's own name for it.
  if ! printf '%s\n' "$row4" | grep -qiF 'trycloudflare.com' ||
     ! printf '%s\n' "$row4" | grep -qiF 'quick tunnel'; then
    fail_case "$name" "row 4 does not name the quick tunnel or its *.trycloudflare.com address"; return
  fi
  # …and row 3 must not claim it. Option 3 asks for a hostname in a zone the user
  # manages; a quick-tunnel address has no such zone, so that row is a dead end.
  if printf '%s\n' "$row3" | grep -qiF 'trycloudflare'; then
    fail_case "$name" "row 3 claims the quick-tunnel address, which its flow cannot use"; return
  fi
  # Terse by design: one consequence plus one decisive constraint. Every row stays
  # at its title line plus a single body line.
  for row in 1 2 3 4; do
    lines=$(printf '%s\n' "$out" | awk -v tag="  $row)" '
      substr($0, 1, length(tag)) == tag { f = 1; n = 1; next }
      f && $0 ~ /^[[:space:]]*$/ { exit }
      f { n++ }
      END { print n + 0 }
    ')
    if [ "$lines" -gt 2 ]; then
      fail_case "$name" "menu row $row grew to $lines lines — the rows are one consequence plus one constraint"; return
    fi
  done
  # Still an explicit choice with no default and no favourite.
  prompt=$(printf '%s\n' "$out" | grep "Choose 1-4 ('i' compares them")
  if ! printf '%s\n' "$prompt" | grep -qF 'Choose 1-4'; then
    fail_case "$name" "the menu prompt no longer asks for an explicit 1-4"; return
  fi
  if [ "$(printf '%s\n' "$prompt" | grep -c 'Enter = no default; i = explain; q = stop')" != "2" ]; then
    fail_case "$name" "i did not return to the same no-default exposure prompt"; return
  fi
  if printf '%s\n' "$out" | grep -qiE 'recommend|\(default'; then
    fail_case "$name" "the menu or its comparison started recommending one of the four paths"; return
  fi

  # The `i` comparison has to agree with the row it explains, or the two drift and
  # the user gets a different answer depending on which one they read.
  explainer=$(printf '%s\n' "$out" | grep '^EXPLAINER ' | tr '\n' ' ')
  if [ -z "$explainer" ]; then
    fail_case "$name" "the 'i' comparison printed nothing"; return
  fi
  for row in '1)' '2)' '3)' '4)'; do
    case "$explainer" in *"$row"*) ;; *)
      fail_case "$name" "the 'i' comparison stopped explaining option $row"; return ;;
    esac
  done
  if ! printf '%s\n' "$explainer" | grep -qiF 'trycloudflare.com' ||
     ! printf '%s\n' "$explainer" | grep -qiF 'cloudflared tunnel --url'; then
    fail_case "$name" "the 'i' comparison does not name the quick tunnel or the command that prints its address"; return
  fi
  # Facts, not phrasing: reword freely and EXTEND the alternation. The pointer has
  # to place the quick tunnel on 4 rather than 3 — that is the whole confusion.
  if ! printf '%s\n' "$explainer" | grep -qiE 'this one, not 3|this option, not 3|option 4, not 3|not option 3|belongs here'; then
    fail_case "$name" "the 'i' comparison no longer places the quick tunnel on option 4 rather than 3"; return
  fi

  # A host with no cloudflared: the cue is about the address the user HOLDS, not
  # about a binary on this box, so it must not disappear with the detection.
  rc=0
  out_nocf=$(run_exposure_menu_isolated "$funcs" no) || rc=$?
  printf -- '--- menu, cloudflared absent ---\n%s\n' "$out_nocf" >> "$TMP/doctor.out"
  if [ "$rc" != "10" ]; then
    fail_case "$name" "the menu did not go back on 'b' without cloudflared (status $rc)"; return
  fi
  if printf '%s\n' "$out_nocf" | grep -qF 'SIDE_EFFECT '; then
    fail_case "$name" "info then back entered an exposure branch without cloudflared"; return
  fi
  if ! printf '%s\n' "$out_nocf" | grep '^  3)' | grep -qF 'not installed'; then
    fail_case "$name" "row 3 reported cloudflared on a host without it — the stub is not wired"; return
  fi
  if ! printf '%s\n' "$out_nocf" | grep '^  4)' | grep -qiF 'trycloudflare.com'; then
    fail_case "$name" "the quick-tunnel cue is gated on a local cloudflared, so a tunnel run elsewhere is unnamed"; return
  fi

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

run_profile_legacy_file_reach_case() {
  local name="profile-legacy-file-reach-fallback" rc=0 state="$TMP/legacy-file-reach-state"
  local resolver live_check
  mkdir -p "$state/conduck"

  # Early schema-1 writers did not store fileServer.reach. The show-code path
  # deliberately falls back to gateway.reach, so this remains a usable profile.
  printf '{"schemaVersion":1,"gateway":{"id":"custom-legacy-reach","kind":"custom","name":"Legacy reach","auth":"none","transport":"tailscale","reach":"private","url":"https://legacy-reach.example.test","localPort":"8080"},"fileServer":{"url":"https://legacy-reach.example.test:8443","localPort":"8090"}}\n' \
    > "$state/conduck/profile-legacy-file-reach.json"
  PTY_ENV=(XDG_CONFIG_HOME="$state")
  pty_run 10 $'q\n' > "$TMP/doctor.out" 2>&1 || rc=$?
  if [ "$rc" != "0" ] ||
     ! grep -qF '4) Show a saved setup code' "$TMP/doctor.out"; then
    fail_case "$name" "a valid schema-1 file lane without reach was hidden"; return
  fi

  # Exercise the production fallback itself, and pin its live-check wiring:
  # missing => gateway scope; an explicit lane reach still wins.
  resolver=$(sed -n '/^show_qr_resolve_file_reach()/,/^}/p' "$SCRIPT")
  if [ "$(FUNCS="$resolver" bash -c 'eval "$FUNCS"; show_qr_resolve_file_reach "" private')" != "private" ] ||
     [ "$(FUNCS="$resolver" bash -c 'eval "$FUNCS"; show_qr_resolve_file_reach public private')" != "public" ]; then
    fail_case "$name" "the production file-reach resolver lost its gateway-scope fallback"; return
  fi
  live_check=$(sed -n '/^show_qr_check_live()/,/^}/p' "$SCRIPT")
  if ! printf '%s\n' "$live_check" | grep -qF 'fs_reach=$(show_qr_resolve_file_reach'; then
    fail_case "$name" "the live drift check no longer uses the tested reach resolver"; return
  fi

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# Drive the PRODUCTION write_profile in isolation, with both live secrets in
# scope exactly as the real emit path has them.
# Args: <function-source> <state-dir> <gateway-token> <file-lane-credential>.
run_write_profile_isolated() {
  FUNCS="$1" STATE="$2" GW_SECRET="$3" FS_SECRET="$4" bash -c '
eval "$FUNCS"
warn() { :; }
note() { :; }
SHOW_QR=false
DRY_RUN=false
REUSE_ONLY=false
VERIFY_FAILED=false
FS_LANE_DROPPED_BY_CHECK=false
STATE_DIR_EXPOSURE_REPORTED=false
STATE_DIR="$STATE"
GW_ID="custom-secret-probe"
GW_KIND="custom"
GW_NAME="Secret probe"
GW_AUTH="bearer"
GW_TOKEN="$GW_SECRET"
GW_URL="https://gw.example.test"
GW_LOCAL_PORT="8080"
GW_MODEL=""
TRANSPORT="tailscale"
SCOPE="private"
FS_URL="https://files.example.test:8443"
FS_CRED="$FS_SECRET"
FS_LOCAL_PORT="5006"
FS_FOLDER="/home/probe/conduck-files"
FS_REACH="private"
write_profile
'
}

# 0 when either sentinel secret appears anywhere under <state-dir>.
profile_state_leaks() { # profile_state_leaks <state-dir> <secret> <secret>
  grep -rqF -e "$2" -e "$3" "$1" 2>/dev/null
}

# The pairing profile is the one file the connector leaves on disk that must
# hold no secret at all — WHAT-IT-TOUCHES.md promises "routing facts only …
# never a token or credential", and --show-code re-reads it indefinitely.
# write_profile builds it in a python block that already holds GW_TOKEN's and
# FS_CRED's values one e("…") away, so a single added line would silently
# persist the live file-lane password to a file users are told is non-secret.
# Prove the promise behaviourally against the shipped function — then prove the
# assertion itself bites, by re-running it on a deliberately leaking copy.
run_profile_secret_exclusion_case() {
  local name="profile-never-carries-secrets"
  local writer broken secrets gw_secret fs_secret
  local state="$TMP/profile-secret-state" broken_state="$TMP/profile-secret-control"
  local prof="$state/profile-custom-secret-probe.json" mode

  secrets=$(python3 -c 'import secrets; print(secrets.token_hex(10)); print(secrets.token_hex(10))') \
    || { fail_case "$name" "could not mint sentinel secrets"; return; }
  gw_secret="conduck-sentinel-gw-$(printf '%s\n' "$secrets" | sed -n 1p)"
  fs_secret="conduck-sentinel-fs-$(printf '%s\n' "$secrets" | sed -n 2p)"

  # fail_case tails doctor.out; this case has no live run, so give it the
  # sentinels and the produced profile as the failure context.
  printf 'pairing-profile secret-exclusion guard\n  gateway-token sentinel: %s\n  file-lane sentinel:     %s\n' \
    "$gw_secret" "$fs_secret" > "$TMP/doctor.out"

  # ensure_state_dir + file_mode_is_open ride along because write_profile creates
  # $STATE_DIR through them; the REAL helpers, not stubs, so this case still
  # proves the profile lands in a directory the shipped code made.
  writer=$(extract_funcs write_profile ensure_state_dir file_mode_is_open)
  if [ -z "$writer" ] || ! printf '%s\n' "$writer" | grep -qF 'write_profile()'; then
    fail_case "$name" "could not extract write_profile from the release artifact"; return
  fi

  mkdir -p "$state" "$broken_state"
  if ! run_write_profile_isolated "$writer" "$state" "$gw_secret" "$fs_secret"; then
    fail_case "$name" "write_profile failed to run in isolation"; return
  fi
  printf -- '--- profile written by the shipped write_profile ---\n' >> "$TMP/doctor.out"
  cat "$prof" >> "$TMP/doctor.out" 2>/dev/null || true

  # Non-vacuous: a profile that silently wrote nothing (or dropped the file
  # lane) would pass a leak scan trivially. Require the real, complete record.
  if [ ! -f "$prof" ]; then
    fail_case "$name" "write_profile wrote no profile at $prof"; return
  fi
  if ! PROF="$prof" python3 -c '
import json, os, sys
p = json.load(open(os.environ["PROF"]))
fs = p.get("fileServer")
if p.get("schemaVersion") != 1 or not p.get("gateway"): sys.exit(1)
if not fs or fs.get("url") != "https://files.example.test:8443": sys.exit(1)
if fs.get("folder") != "/home/probe/conduck-files": sys.exit(1)
'; then
    fail_case "$name" "the profile is not the complete gateway+file-lane record this guard must scan"; return
  fi

  # The invariant itself: neither live secret reached the profile — nor any
  # other file the run dropped in the state directory.
  if profile_state_leaks "$state" "$gw_secret" "$fs_secret"; then
    fail_case "$name" "the saved pairing profile leaked a live token or file-lane credential"; return
  fi

  # Structural companion: no key that would ever be a place to put one.
  if ! PROF="$prof" python3 -c '
import json, os, re, sys
bad = re.compile(r"token|credential|password|secret|passphrase", re.I)
def walk(node):
    if isinstance(node, dict):
        for k, v in node.items():
            if bad.search(k): sys.exit(1)
            walk(v)
    elif isinstance(node, list):
        for v in node: walk(v)
walk(json.load(open(os.environ["PROF"])))
'; then
    fail_case "$name" "the pairing profile grew a token/credential-shaped key"; return
  fi

  # WHAT-IT-TOUCHES.md states this file is 0600. Nothing else asserts it.
  mode=$(ls -l "$prof" | cut -c1-10)
  if [ "$mode" != "-rw-------" ]; then
    fail_case "$name" "the pairing profile is $mode, not 0600"; return
  fi

  # Control: the exact regression this guard exists for — one added line that
  # writes FS_CRED into the file-lane object. If the scan above cannot catch
  # it, the guard is decoration and the case must fail here, not in the field.
  broken=$(printf '%s\n' "$writer" | awk '
    { print }
    /fs = \{"url": e\("FS_URL"\)\}/ { print "    fs[\"credential\"] = e(\"FS_CRED\")" }')
  if [ "$broken" = "$writer" ]; then
    fail_case "$name" "could not inject the control leak — write_profile's file-lane block changed shape; re-anchor this guard"; return
  fi
  if ! run_write_profile_isolated "$broken" "$broken_state" "$gw_secret" "$fs_secret"; then
    fail_case "$name" "the control copy of write_profile failed to run"; return
  fi
  if ! profile_state_leaks "$broken_state" "$gw_secret" "$fs_secret"; then
    fail_case "$name" "the leak scan did not catch a profile that deliberately writes the credential — this guard proves nothing"; return
  fi

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# Drive the PRODUCTION write_profile against a state directory that may ALREADY hold a
# profile, over the run shapes that decide whether it may overwrite one. The gateway
# facts are fixed; only the run shape and the file-lane pair vary.
# Args: <function-source> <state-dir> <reuse-only> <verify-failed> <lane-dropped> <fs-url> <fs-cred>
run_write_profile_shaped() {
  FUNCS="$1" STATE="$2" RO="$3" VF="$4" DROPPED="$5" FSU="$6" FSC="$7" bash -c '
eval "$FUNCS"
warn() { printf "WARN %s\n" "$*"; }
note() { printf "NOTE %s\n" "$*"; }
SHOW_QR=false
DRY_RUN=false
REUSE_ONLY=$RO
VERIFY_FAILED=$VF
FS_LANE_DROPPED_BY_CHECK=$DROPPED
STATE_DIR_EXPOSURE_REPORTED=false
STATE_DIR="$STATE"
GW_ID="custom-shaped"
GW_KIND="custom"
GW_NAME="Shaped probe"
GW_AUTH="bearer"
GW_TOKEN="probe-token"
GW_URL="https://gw.example.test"
GW_LOCAL_PORT="8080"
GW_MODEL=""
TRANSPORT="public"
SCOPE="public"
FS_URL="$FSU"
FS_CRED="$FSC"
FS_LOCAL_PORT="5006"
FS_FOLDER="/home/probe/conduck-files"
FS_REACH="public"
write_profile
'
}

# The saved profile is the ONLY record of a paired file lane — the credential is
# re-derived from the host, but nothing else remembers that the lane exists. So a run
# that promised to change nothing (--reuse-only) or that lost the lane to a failed
# probe rather than to a decision must not rewrite it: the service keeps running while
# the record of it is deleted for good, and --show-code then offers a chat-only code
# forever. --show-code's own guard already makes exactly this argument.
#
# Every arm compares the file BYTE-FOR-BYTE against the saved original, because
# "kept the lane" and "rewrote the same bytes" are different promises. The last two
# arms are the non-vacuity half: the write still happens when there is nothing to
# destroy, and it still drops the lane when no guard is claiming to protect it.
run_profile_overwrite_guard_case() {
  local name="profile-refusing-runs-keep-the-saved-lane" writer
  local root="$TMP/profile-guard" prof before after arm
  local saved='{"schemaVersion":1,"gateway":{"id":"custom-shaped","kind":"custom","name":"Shaped probe","auth":"bearer","transport":"public","reach":"public","url":"https://old.example.test","localPort":"8080"},"fileServer":{"url":"https://files.example.test:8443","localPort":"5006","reach":"public","folder":"/home/probe/conduck-files"}}'

  writer=$(extract_funcs write_profile ensure_state_dir file_mode_is_open json_type json_query)
  if [ -z "$writer" ] || ! printf '%s\n' "$writer" | grep -qF 'write_profile()'; then
    fail_case "$name" "could not extract write_profile from the release artifact"; return
  fi
  printf 'pairing-profile overwrite guard\n' > "$TMP/doctor.out"

  # Every arm runs with NO file lane in hand (fs-url/fs-cred empty), which is the shape
  # that would write "fileServer": null over a recorded lane.
  # arm|reuse-only|verify-failed|lane-dropped|seed-profile|expect
  # expect: keep = the saved bytes survive · write = this run's facts are saved
  local arms='reuse-only|true|false|false|seed|keep
checks-failed|false|true|false|seed|keep
lane-dropped-by-check|false|false|true|seed|keep
lane-dropped-first-pairing|false|false|true|none|write
lane-absent-by-choice|false|false|false|seed|write'
  local ro vf dropped seed expect
  while IFS='|' read -r arm ro vf dropped seed expect; do
    [ -n "$arm" ] || continue
    rm -rf "$root"; mkdir -p "$root"
    prof="$root/profile-custom-shaped.json"
    if [ "$seed" = "seed" ]; then
      printf '%s\n' "$saved" > "$prof"
      before=$(cksum < "$prof")
    fi
    if ! run_write_profile_shaped "$writer" "$root" "$ro" "$vf" "$dropped" "" "" \
         >> "$TMP/doctor.out" 2>&1; then
      fail_case "$name" "[$arm] write_profile failed to run in isolation"; return
    fi
    if [ "$expect" = "keep" ]; then
      if [ ! -f "$prof" ]; then
        fail_case "$name" "[$arm] the saved profile was deleted outright"; return
      fi
      after=$(cksum < "$prof")
      if [ "$after" != "$before" ]; then
        printf -- '--- profile after [%s] ---\n' "$arm" >> "$TMP/doctor.out"
        cat "$prof" >> "$TMP/doctor.out"
        fail_case "$name" "[$arm] a run that must not rewrite the saved profile rewrote it"; return
      fi
    else
      if [ ! -f "$prof" ]; then
        fail_case "$name" "[$arm] no profile was written — the guards are swallowing a legitimate save"; return
      fi
      if ! PROF="$prof" python3 -c '
import json, os, sys
p = json.load(open(os.environ["PROF"]))
if p.get("gateway", {}).get("url") != "https://gw.example.test": sys.exit(1)
if p.get("fileServer") is not None: sys.exit(1)
'; then
        printf -- '--- profile after [%s] ---\n' "$arm" >> "$TMP/doctor.out"
        cat "$prof" >> "$TMP/doctor.out"
        fail_case "$name" "[$arm] the run that IS allowed to save did not write this run's facts"; return
      fi
    fi
  done <<ARMS
$arms
ARMS

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# Drive the PRODUCTION emit_payload in isolation so the warning it prints can be
# graded in both shapes it has. The file-lane pair and the gateway kind are the
# ONLY inputs that vary: an empty pair is a run with no file lane, exactly as
# build_pairing_payload_json reads it, and the kind decides whether the screen
# offers the two follow-up check commands at all. Output helpers are stubbed to
# plain text (no colour), with warn() tagged so the assertions can isolate the
# warning block from the rest of Step 6.
# The host-shape trio (OS / unit / linger) defaults to the shape that has no durability
# caveat to make — macOS, no unit — so the cases that predate it stay on that path.
# The gateway URL defaults to a permanent-looking hostname, so a case that says nothing
# about addresses stays on the path with no rotation reminder.
# Args: <function-source> <file-server-url> <file-server-credential> [gateway-kind]
#       [os] [file-server-unit] [linger:on|off] [gateway-url].
run_emit_payload_isolated() {
  FUNCS="$1" FS_URL_IN="$2" FS_CRED_IN="$3" GW_KIND_IN="${4:-custom}" \
  OS_IN="${5:-Darwin}" FS_UNIT_IN="${6:-}" LINGER_IN="${7:-on}" \
  GW_URL_IN="${8:-https://gw.example.test}" VF_IN="${9:-false}" \
  GW_PORT_IN="${10:-}" FS_PROOF_IN="${11:-proved}" bash -c '
eval "$FUNCS"
say()   { printf "%s\n" "$*"; }
warn()  { printf "WARNLINE %s\n" "$*"; }
# Tagged like warn(): the pre-code summary states what the operator is about to
# scan, and the positive half of it is an ok() line. Untagged (or undefined) it
# would be indistinguishable from the surrounding prose, and an undefined ok()
# would send the line to stderr where these assertions could never see it.
ok()    { printf "OKLINE %s\n" "$*"; }
note()  { printf "%s\n" "$*"; }
head_() { printf "%s\n" "$*"; }
die()   { printf "Error: %s\n" "$*" >&2; exit 1; }
render_qr()        { return 1; }   # no QR here; the paste string still prints
write_profile()    { :; }          # this case grades emitted text, not saved state
cleanup_exposures() { :; }
gw_restart_timing_note() { :; }    # self-guarding on a real run; silent either way here
# loginctl cannot be driven from a test, so the ANSWER is injected — the production
# call site, and the fact that it is asked at all, is what these cases grade.
fs_linger_enabled_linux() { [ "$LINGER_IN" = "on" ]; }
OS="$OS_IN"
FS_UNIT="$FS_UNIT_IN"
BOLD=""; RESET=""
VERIFY_FAILED=$VF_IN
FS_ROLLBACK_INCOMPLETE=false
EMITTED=false
PAYLOAD_VERSION=1
GW_KIND="$GW_KIND_IN"
GW_NAME="Warning probe"
GW_URL="$GW_URL_IN"
GW_AUTH="bearer"
GW_TOKEN="probe-token"
GW_MODEL=""
GW_LOCAL_PORT="$GW_PORT_IN"
CHECKED_PATH_PREFIX=""
TRANSPORT="public"
FS_URL="$FS_URL_IN"
FS_CRED="$FS_CRED_IN"
# Whether a real agent turn proved the agent can USE the shared folder. Defaults
# to "proved" so every case that is about something else — warnings, tunnels,
# lingering — keeps grading the fully-verified lane it always did.
FS_AGENT_PROOF="$FS_PROOF_IN"
emit_payload
'
}

# 0 when the warning block states the fact <regex> describes.
warning_states() { # warning_states <flattened-warning-block> <extended-regex>
  printf '%s\n' "$1" | grep -qiE "$2"
}

# The emitted warning is the only place a user is told what the code they are
# about to show around actually IS — a reusable bearer credential. SECURITY.md
# makes specific promises about that text, and nothing but this case keeps the
# two from drifting (they already did once: the doc promised a file-lane and
# rotation clause the script never printed).
#
# Grade STABLE FACTS, never the paragraph — a verbatim assertion rots on the
# first reword and gets deleted rather than fixed. Each check below is an
# alternation of phrasings for ONE fact. Reword the warning freely and EXTEND
# the alternation; do not remove a fact.
run_pairing_warning_case() {
  local name="pairing-warning-states-what-the-code-is"
  local emit out_files out_bare block_files block_bare

  # pairing_capability_summary comes along because emit_payload CALLS it: the
  # "This code carries:" block lives there so the file-lane suite can drive its
  # states directly, and an emit extracted without it would run with that block
  # silently missing — every assertion about it would then pass vacuously.
  emit=$(extract_funcs emit_payload pairing_capability_summary \
           build_pairing_payload_json b64_nowrap is_quick_tunnel_url)
  if [ -z "$emit" ] || ! printf '%s\n' "$emit" | grep -qF 'emit_payload()' \
     || ! printf '%s\n' "$emit" | grep -qF 'pairing_capability_summary()'; then
    fail_case "$name" "could not extract emit_payload and its capability summary from the release artifact"; return
  fi

  out_files=$(run_emit_payload_isolated "$emit" \
    "https://files.example.test:8443" "probe-file-credential") \
    || { printf '%s\n' "$out_files" > "$TMP/doctor.out"
         fail_case "$name" "emit_payload failed to run with a file lane"; return; }
  out_bare=$(run_emit_payload_isolated "$emit" "" "") \
    || { printf '%s\n' "$out_bare" > "$TMP/doctor.out"
         fail_case "$name" "emit_payload failed to run without a file lane"; return; }

  printf -- '--- emit_payload WITH a file lane ---\n%s\n--- emit_payload WITHOUT a file lane ---\n%s\n' \
    "$out_files" "$out_bare" > "$TMP/doctor.out"

  # Non-vacuous: both runs really reached the emit, not an early return.
  if ! printf '%s\n' "$out_files" | grep -qF 'conduck-setup:v1:' ||
     ! printf '%s\n' "$out_bare"  | grep -qF 'conduck-setup:v1:'; then
    fail_case "$name" "emit_payload printed no pairing code — the warning below proves nothing"; return
  fi

  # Grade the warning block only. Flattened to one line so a fact stated across
  # two wrapped warn() lines still matches.
  block_files=$(printf '%s\n' "$out_files" | grep '^WARNLINE ' | tr '\n' ' ')
  block_bare=$(printf '%s\n' "$out_bare" | grep '^WARNLINE ' | tr '\n' ' ')
  if [ -z "$block_files" ] || [ -z "$block_bare" ]; then
    fail_case "$name" "the pairing emit printed no warning at all"; return
  fi

  local b
  for b in "$block_files" "$block_bare"; do
    # FACT 1 — the code carries the gateway token, and that token is a secret.
    if ! warning_states "$b" 'token' ||
       ! warning_states "$b" 'like a password|is a secret|keep (it|them|these) secret'; then
      fail_case "$name" "the warning no longer names the gateway token as a secret"; return
    fi
    # FACT 2 — whoever holds the code gets whatever the gateway permits.
    if ! warning_states "$b" 'whoever holds|anyone who (holds|scans|copies|has)|the holder' ||
       ! warning_states "$b" 'your gateway (allows|permits|lets)|anything the gateway (allows|permits)'; then
      fail_case "$name" "the warning no longer states that the holder gets the gateway's capabilities"; return
    fi
    # FACT 3 — it stays valid until the secrets are rotated. No expiry.
    if ! warning_states "$b" 'until you rotate|until (that secret|those secrets|the token) (is|are) rotated'; then
      fail_case "$name" "the warning no longer states the code works until the secrets are rotated"; return
    fi
    # FACT 4 — handing it to a person hands them the same access.
    if ! warning_states "$b" 'another person|someone else|hand(ing)? (it|the code) to' ||
       ! warning_states "$b" 'same access'; then
      fail_case "$name" "the warning no longer states that giving the code away grants the same access"; return
    fi
    # FACT 5 — a shared credential has no per-device revoke; rotation hits every
    # device on THAT token (a custom gateway may issue several, so not "every device").
    if ! warning_states "$b" '(cannot|can ?not|can.t) be (cut off|revoked|removed)( one at a time| individually| separately)?' ||
       ! warning_states "$b" 'every device (using|on|that uses) that token|all devices (using|on) that token'; then
      fail_case "$name" "the warning no longer states the shared-credential revocation consequence"; return
    fi
  done

  # FACT 6 — the file-lane clause is CONDITIONAL. Present when the code really
  # carries the file-server credential; absent when it does not, so the wizard
  # never claims a shared folder this run has no lane for.
  if ! warning_states "$block_files" 'credential' ||
     ! warning_states "$block_files" 'folder'; then
    fail_case "$name" "a run WITH a file lane did not warn that the code carries the file-server credential"; return
  fi
  if warning_states "$block_bare" 'credential|shared folder|file server|file-server'; then
    fail_case "$name" "a run WITHOUT a file lane still claimed a file-server credential or shared folder"; return
  fi

  # FACT 7 — say what the code CARRIES, before it is shown. Every route that
  # drops the file lane converges on this emit — a confirmed skip at the address
  # prompt, a live probe that failed, an agent gate that could not be proved — so
  # this is the one statement that holds regardless of WHY the lane is missing,
  # and the last moment it is cheap: after the code is scanned, adding a lane
  # costs a full re-run of setup. An absence is not a statement, so the run
  # WITHOUT a lane has to say so in words rather than leave it to be noticed.
  if ! printf '%s\n' "$out_files" | grep -qiE '^OKLINE .*file transfer'; then
    fail_case "$name" "a run WITH a file lane never states that the code carries file transfer"; return
  fi
  if ! printf '%s\n' "$out_bare" | grep -qiE '^WARNLINE .*file transfer.*(not included|not in this|missing)'; then
    fail_case "$name" "a run WITHOUT a file lane never states that file transfer is missing from the code"; return
  fi
  if printf '%s\n' "$out_bare" | grep -qiE '^OKLINE .*file transfer'; then
    fail_case "$name" "a run WITHOUT a file lane claimed the code carries file transfer"; return
  fi

  # FACT 8 — the ✓ is spent on the AGENT half, not on the transport. A lane whose
  # agent turn was never passed still rides in the code (the operator can choose
  # to keep it), and the payload has no field for a caveat — so this screen is the
  # only place the difference can ever be stated. A green line there is the wizard
  # certifying a capability nothing measured, read days later on a phone as "the
  # tool said it works". The address must still appear: they have to know what got
  # published either way.
  local out_unproved
  out_unproved=$(run_emit_payload_isolated "$emit" \
    "https://files.example.test:8443" "probe-file-credential" custom Darwin "" on \
    "https://gw.example.test" false "" "unproved") \
    || { printf '%s\n' "$out_unproved" > "$TMP/doctor.out"
         fail_case "$name" "emit_payload failed to run with an unproved file lane"; return; }
  if printf '%s\n' "$out_unproved" | grep -qiE '^OKLINE .*file transfer'; then
    printf '%s\n' "$out_unproved" > "$TMP/doctor.out"
    fail_case "$name" "a lane whose agent access was never proved still got a green file-transfer line"; return
  fi
  if ! printf '%s\n' "$out_unproved" | grep -qiE '^WARNLINE .*(not proved|could not be proved|untested|not tested)'; then
    printf '%s\n' "$out_unproved" > "$TMP/doctor.out"
    fail_case "$name" "an unproved file lane is in the code and the screen does not say so"; return
  fi
  if ! printf '%s\n' "$out_unproved" | grep -qF 'https://files.example.test:8443'; then
    printf '%s\n' "$out_unproved" > "$TMP/doctor.out"
    fail_case "$name" "an unproved file lane rides in the code without naming the address it published"; return
  fi

  # Control: the exact regression FACT 6 exists for — an emit whose file-lane
  # guard is gone, so it promises a shared folder on a run that has no lane. If
  # the check above cannot catch that, it is decoration and this case must fail
  # here rather than in the field.
  local unguarded control
  unguarded=$(printf '%s\n' "$emit" | sed 's/if \[ -n "\$FS_URL" \] && \[ -n "\$FS_CRED" \]; then/if true; then/')
  if [ "$unguarded" = "$emit" ]; then
    fail_case "$name" "could not inject the control — emit_payload's file-lane guard changed shape; re-anchor this case"; return
  fi
  control=$(run_emit_payload_isolated "$unguarded" "" "" | grep '^WARNLINE ' | tr '\n' ' ')
  if ! warning_states "$control" 'credential|shared folder|file server|file-server'; then
    fail_case "$name" "the file-lane check did not see an unconditional file-server clause — it proves nothing"; return
  fi

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# Every command printed on a SUCCESS screen reads as "do this next", so one that
# is EXPECTED to fail has to say so where it is printed. `--check-adapter` grades a
# stricter contract than the app's own wire: generic OpenAI-compatible software
# pairs fine and then legitimately fails that grade (honouring `stream: true` with
# SSE is correct OpenAI behaviour; keyless is fine app-side), and a fresh user
# reads that FAIL as proof the setup they just completed is broken. The failure
# branch offers the same two commands to a user who already knows something is
# wrong; this case grades the success screen, where the FAIL has no context.
#
# Facts, never the paragraph — extend an alternation when rewording, and do not
# remove a fact. The helper is the same flattened-grep the warning case uses.
run_pairing_check_suggestion_case() {
  local name="pairing-adapter-suggestion-names-its-outcome"
  local emit out_custom out_openclaw flat_custom flat_openclaw

  # pairing_capability_summary comes along because emit_payload CALLS it: the
  # "This code carries:" block lives there so the file-lane suite can drive its
  # states directly, and an emit extracted without it would run with that block
  # silently missing — every assertion about it would then pass vacuously.
  emit=$(extract_funcs emit_payload pairing_capability_summary \
           build_pairing_payload_json b64_nowrap is_quick_tunnel_url)
  if [ -z "$emit" ] || ! printf '%s\n' "$emit" | grep -qF 'emit_payload()' \
     || ! printf '%s\n' "$emit" | grep -qF 'pairing_capability_summary()'; then
    fail_case "$name" "could not extract emit_payload and its capability summary from the release artifact"; return
  fi

  out_custom=$(run_emit_payload_isolated "$emit" "" "" custom) \
    || { printf '%s\n' "$out_custom" > "$TMP/doctor.out"
         fail_case "$name" "emit_payload failed to run for a custom gateway"; return; }
  out_openclaw=$(run_emit_payload_isolated "$emit" "" "" openclaw) \
    || { printf '%s\n' "$out_openclaw" > "$TMP/doctor.out"
         fail_case "$name" "emit_payload failed to run for an OpenClaw gateway"; return; }
  printf -- '--- success screen, custom gateway ---\n%s\n--- success screen, OpenClaw gateway ---\n%s\n' \
    "$out_custom" "$out_openclaw" > "$TMP/doctor.out"

  # Non-vacuous: both runs really reached the emit, and the custom one really does
  # still offer the adapter grade — the thing the caveat below is about.
  if ! printf '%s\n' "$out_custom" | grep -qF 'conduck-setup:v1:' ||
     ! printf '%s\n' "$out_openclaw" | grep -qF 'conduck-setup:v1:'; then
    fail_case "$name" "emit_payload printed no pairing code — the screen proves nothing"; return
  fi
  if ! printf '%s\n' "$out_custom" | grep -qF -- '--check-adapter'; then
    fail_case "$name" "the success screen no longer offers the adapter grade to a custom gateway"; return
  fi

  flat_custom=$(printf '%s\n' "$out_custom" | tr '\n' ' ')
  # FACT 1 — the grade is scoped to software built for Conduck.
  if ! warning_states "$flat_custom" 'built (specifically )?for Conduck'; then
    fail_case "$name" "the screen no longer scopes the adapter grade to software built for Conduck"; return
  fi
  # FACT 2 — software that is not built for Conduck is EXPECTED to fail it, named
  # concretely enough that a user can place the server they just paired.
  if ! warning_states "$flat_custom" 'expected to fail|fail rules|is not a (fault|problem)|(does not|doesn.t) mean|means nothing' ||
     ! warning_states "$flat_custom" 'ollama|litellm|open ?webui|vllm'; then
    fail_case "$name" "the screen no longer says generic software is expected to fail the adapter grade"; return
  fi
  # FACT 3 — that FAIL does not undo the pairing this same screen just handed over.
  if ! warning_states "$flat_custom" '(does not|doesn.t) undo the pairing|pairing above (still )?(stands|holds)|pairing (above )?is still complete'; then
    fail_case "$name" "the screen no longer says a failed adapter grade leaves the pairing intact"; return
  fi

  # The caveat is not free-floating: a gateway that is never offered the grade must
  # not be told about failing it either.
  flat_openclaw=$(printf '%s\n' "$out_openclaw" | tr '\n' ' ')
  if warning_states "$flat_openclaw" '[-][-]check-adapter|adapter grade'; then
    fail_case "$name" "an OpenClaw pairing was shown adapter-grade text meant for custom servers"; return
  fi

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# The diagnostic a failed run recommends has to exercise the route that failed. Aimed at
# loopback it PASSES on every fault that lives in the HTTPS front — the Ollama Host-header
# 403 is exactly that shape, 200 on 127.0.0.1 and 403 through the tunnel — so the operator
# watches the recommended check go green after a red run and concludes the wizard is
# broken. A recovery path that confirms the wrong theory is worse than a misleading
# message, because the operator now has evidence for it.
#
# Both screens are graded together because they carried the same substitution and only one
# of them was ever a trap: on the SUCCESS screen the public route is the one just proven
# and the one the app takes, so it is simply the right target; on the FAILURE screen it is
# the route under investigation, and the loopback run is the second half of a comparison
# whose SPLIT is the diagnosis.
run_pairing_check_targets_the_failed_route_case() {
  local name="pairing-checks-target-the-route-that-failed" emit out flat
  emit=$(extract_funcs emit_payload build_pairing_payload_json b64_nowrap is_quick_tunnel_url gw_loopback_base)
  if [ -z "$emit" ] || ! printf '%s\n' "$emit" | grep -qF 'gw_loopback_base()'; then
    fail_case "$name" "could not extract emit_payload + gw_loopback_base from the release artifact"; return
  fi
  : > "$TMP/doctor.out"

  # FAILURE screen, local port known — the arm that used to hand out the loopback trap.
  out=$(run_emit_payload_isolated "$emit" "" "" custom Darwin "" on \
        "https://gw.example.test" true 11434)
  printf -- '--- failed run, local port known ---\n%s\n' "$out" >> "$TMP/doctor.out"
  flat=$(printf '%s\n' "$out" | tr '\n' ' ')

  # Non-vacuous: this really is the failure screen, and it really does still suggest checks.
  if ! warning_states "$flat" 'checks failed above' || ! warning_states "$flat" '[-][-]check-server'; then
    fail_case "$name" "the arm did not reach the failure screen's check suggestions"; return
  fi
  # FACT 1 — the app-compatibility and adapter checks both address the failed HTTPS route.
  if ! warning_states "$flat" '[-][-]check-server https://gw\.example\.test' ||
     ! warning_states "$flat" '[-][-]check-adapter https://gw\.example\.test'; then
    fail_case "$name" "a failed run still sent both checks somewhere other than the route that failed"; return
  fi
  # FACT 2 — loopback is still offered, because a bad envelope really is diagnosed there.
  if ! warning_states "$flat" '[-][-]check-server http://127\.0\.0\.1:11434'; then
    fail_case "$name" "the loopback comparison was dropped instead of being labelled"; return
  fi
  # FACT 3 — and it is labelled as the OTHER route, with what the split proves. Unlabelled,
  # a green loopback check is read as "the wizard was wrong", which is the whole defect.
  if ! warning_states "$flat" 'skipping the HTTPS route|without (its|the) HTTPS|compare it against the server'; then
    fail_case "$name" "the loopback check was suggested without saying it tests a different route"; return
  fi
  if ! warning_states "$flat" '(green|passes).*(red|fails)|HTTPS route is refusing'; then
    fail_case "$name" "nothing said what a green loopback and a red HTTPS route together mean"; return
  fi
  # FACT 4 — the adapter grade is not duplicated onto loopback. The question the second
  # command answers is "the server, or the route?"; a fourth near-identical line buries it.
  if warning_states "$flat" '[-][-]check-adapter http://127\.0\.0\.1'; then
    fail_case "$name" "a second grader on loopback buried the one comparison that matters"; return
  fi

  # FAILURE screen, no local port: nothing to compare against, so nothing may be offered.
  out=$(run_emit_payload_isolated "$emit" "" "" custom Darwin "" on \
        "https://gw.example.test" true "")
  printf -- '--- failed run, no local port ---\n%s\n' "$out" >> "$TMP/doctor.out"
  flat=$(printf '%s\n' "$out" | tr '\n' ' ')
  if ! warning_states "$flat" '[-][-]check-server https://gw\.example\.test'; then
    fail_case "$name" "a failed run with no local port stopped suggesting the failed route"; return
  fi
  if warning_states "$flat" '127\.0\.0\.1'; then
    fail_case "$name" "a loopback comparison was offered for a gateway with no recorded port"; return
  fi

  # SUCCESS screen: verification just proved the public route, so that is what a re-check
  # must grade — a loopback grade describes a route neither the app nor this script takes.
  out=$(run_emit_payload_isolated "$emit" "" "" custom Darwin "" on \
        "https://gw.example.test" false 11434)
  printf -- '--- success screen, local port known ---\n%s\n' "$out" >> "$TMP/doctor.out"
  flat=$(printf '%s\n' "$out" | tr '\n' ' ')
  if ! printf '%s\n' "$out" | grep -qF 'conduck-setup:v1:'; then
    fail_case "$name" "the success arm printed no pairing code — the screen proves nothing"; return
  fi
  if ! warning_states "$flat" '[-][-]check-server https://gw\.example\.test' ||
     ! warning_states "$flat" '[-][-]check-adapter https://gw\.example\.test'; then
    fail_case "$name" "the success screen re-check no longer grades the route the app uses"; return
  fi
  if warning_states "$flat" '127\.0\.0\.1'; then
    fail_case "$name" "a proven public route was re-checked on loopback instead"; return
  fi

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# A systemd USER file server stops shortly after that user's last logout unless
# lingering is on — and this is a 24/7 gateway product, so a lane that verifies green
# inside the SSH session that built it is not yet a lane that survives that session.
# The step that built the lane says so, but by the pairing screen that line has
# scrolled away, and THIS screen is where the operator decides to trust the lane with
# their attachments. So it is restated here, gated on the one arrangement it is true
# for: Linux, a connector-owned unit, lingering actually off.
run_pairing_linger_caveat_case() {
  local name="pairing-code-restates-the-logout-caveat"
  local emit out flat arm
  emit=$(extract_funcs emit_payload build_pairing_payload_json b64_nowrap priv_prefix have is_quick_tunnel_url)
  if [ -z "$emit" ] || ! printf '%s\n' "$emit" | grep -qF 'emit_payload()'; then
    fail_case "$name" "could not extract emit_payload from the release artifact"; return
  fi
  # A rename of the durability helper must break HERE, not silently stop the caveat:
  # the runner stubs the answer, so only this check proves the real function is asked.
  if ! printf '%s\n' "$emit" | grep -qF 'fs_linger_enabled_linux'; then
    fail_case "$name" "emit_payload no longer asks the file-lane module about lingering"; return
  fi
  if ! grep -q '^fs_linger_enabled_linux()' "$SCRIPT"; then
    fail_case "$name" "the durability helper emit_payload calls is not defined in the artifact"; return
  fi
  : > "$TMP/doctor.out"

  # arm|os|unit|linger|fs-lane|expect-caveat
  local arms='linux-unit-linger-off|Linux|/home/u/.config/systemd/user/conduck-files-x.service|off|yes|yes
linux-unit-linger-on|Linux|/home/u/.config/systemd/user/conduck-files-x.service|on|yes|no
linux-no-lane|Linux|/home/u/.config/systemd/user/conduck-files-x.service|off|no|no
macos-unit-linger-off|Darwin|/Users/u/Library/LaunchAgents/ai.gigaduck.conduck-files-x.plist|off|yes|no
linux-no-unit|Linux||off|yes|no'
  local os unit linger lane want
  while IFS='|' read -r arm os unit linger lane want; do
    [ -n "$arm" ] || continue
    local fsu="" fsc=""
    if [ "$lane" = "yes" ]; then fsu="https://files.example.test:8443"; fsc="probe-file-credential"; fi
    out=$(run_emit_payload_isolated "$emit" "$fsu" "$fsc" custom "$os" "$unit" "$linger") \
      || { printf '%s\n' "$out" >> "$TMP/doctor.out"
           fail_case "$name" "[$arm] emit_payload failed to run"; return; }
    printf -- '--- %s ---\n%s\n' "$arm" "$out" >> "$TMP/doctor.out"
    # Non-vacuous: the screen really was emitted, so an absent caveat means absent.
    if ! printf '%s\n' "$out" | grep -qF 'conduck-setup:v1:'; then
      fail_case "$name" "[$arm] emit_payload printed no pairing code"; return
    fi
    flat=$(printf '%s\n' "$out" | tr '\n' ' ')
    if [ "$want" = "yes" ]; then
      # FACT 1 — the lane stops at logout, and does not return by itself on reboot.
      if ! warning_states "$flat" 'log ?out|logs out|logging out' ||
         ! warning_states "$flat" 'reboot|restart the machine'; then
        fail_case "$name" "[$arm] the code was handed over without saying the file lane stops at logout"; return
      fi
      # FACT 2 — chat is unaffected; it is attachments that stop. A caveat that reads
      # as "your setup is broken" would send the operator to redo a correct pairing.
      if ! warning_states "$flat" 'chat (keeps|still)' ||
         ! warning_states "$flat" 'attachment'; then
        fail_case "$name" "[$arm] the caveat did not scope the loss to attachments"; return
      fi
      # FACT 3 — the exact command that fixes it, on the screen where it is read.
      if ! warning_states "$flat" 'loginctl enable-linger'; then
        fail_case "$name" "[$arm] the caveat named the problem but not the one-line fix"; return
      fi
    else
      if warning_states "$flat" 'enable-linger|lingering is off'; then
        fail_case "$name" "[$arm] a setup with no logout problem was warned about one"; return
      fi
    fi
  done <<ARMS
$arms
ARMS

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# A `cloudflared tunnel --url` hostname is reassigned on every restart of that tunnel,
# reboots included. The address is named at the step that accepts it, but the artifact that
# goes stale is THE CODE: after a reboot the tunnel returns on a new public hostname, the
# paired device keeps calling the dead one, and the live address is in no saved profile and
# no output of this script — so there is nothing for the operator to search for. The
# reminder therefore has to sit on the screen where they are holding the code.
#
# The near-miss arm is the load-bearing one: it proves this rides 30-exposure's host-suffix
# predicate rather than a second, substring-matching copy of the rule.
run_pairing_quick_tunnel_reminder_case() {
  local name="pairing-code-warns-a-rotating-quick-tunnel"
  local emit out flat arm
  local qt='https://random-words-1234.trycloudflare.com'
  local qtf='https://files-9876.trycloudflare.com'
  # pairing_capability_summary comes along because emit_payload CALLS it: the
  # "This code carries:" block lives there so the file-lane suite can drive its
  # states directly, and an emit extracted without it would run with that block
  # silently missing — every assertion about it would then pass vacuously.
  emit=$(extract_funcs emit_payload pairing_capability_summary \
           build_pairing_payload_json b64_nowrap is_quick_tunnel_url)
  if [ -z "$emit" ] || ! printf '%s\n' "$emit" | grep -qF 'emit_payload()' \
     || ! printf '%s\n' "$emit" | grep -qF 'pairing_capability_summary()'; then
    fail_case "$name" "could not extract emit_payload and its capability summary from the release artifact"; return
  fi
  # The shared predicate, not a local re-implementation — the whole point of the near-miss arm.
  if ! printf '%s\n' "$emit" | grep -qF 'is_quick_tunnel_url()'; then
    fail_case "$name" "emit_payload does not use the shared quick-tunnel predicate"; return
  fi
  : > "$TMP/doctor.out"

  # arm|gateway-url|fs-url|fs-cred|expect: none · gateway · lane · both
  local arms="stable-both|https://gw.example.test|https://files.example.test:8443|probe-cred|none
quick-gateway|$qt|||gateway
quick-gateway-and-lane|$qt|$qtf|probe-cred|both
quick-lane-only|https://gw.example.test|$qtf|probe-cred|lane
quick-lane-not-in-code|https://gw.example.test|$qtf||none
near-miss-host|https://not-really.trycloudflare.com.example.test|||none"
  local gw fsu fsc want
  while IFS='|' read -r arm gw fsu fsc want; do
    [ -n "$arm" ] || continue
    out=$(run_emit_payload_isolated "$emit" "$fsu" "$fsc" custom Darwin "" on "$gw") \
      || { printf '%s\n' "$out" >> "$TMP/doctor.out"
           fail_case "$name" "[$arm] emit_payload failed to run"; return; }
    printf -- '--- %s ---\n%s\n' "$arm" "$out" >> "$TMP/doctor.out"
    if ! printf '%s\n' "$out" | grep -qF 'conduck-setup:v1:'; then
      fail_case "$name" "[$arm] emit_payload printed no pairing code"; return
    fi
    flat=$(printf '%s\n' "$out" | grep '^WARNLINE ' | tr '\n' ' ')
    if [ "$want" = "none" ]; then
      if warning_states "$flat" 'quick tunnel'; then
        fail_case "$name" "[$arm] an address that does not rotate was flagged as a quick tunnel"; return
      fi
      continue
    fi
    # FACT 1 — the hostname changes when the tunnel restarts, and a reboot is a restart.
    if ! warning_states "$flat" 'quick tunnel' ||
       ! warning_states "$flat" 'reassigned|changes every time|changes on every|new (public )?hostname' ||
       ! warning_states "$flat" 'reboot'; then
      fail_case "$name" "[$arm] the screen did not say the address changes on a tunnel restart"; return
    fi
    # FACT 2 — THIS code is what breaks, and the replacement address is not recoverable
    # from anything the tool wrote. Without this the operator hunts for a saved copy.
    if ! warning_states "$flat" 'this (exact )?code|the code from this run' ||
       ! warning_states "$flat" 'no saved profile|not saved|nothing (for|to) (the app|look|search)'; then
      fail_case "$name" "[$arm] the screen did not say this code dies with the hostname"; return
    fi
    # FACT 3 — WHICH address rotates. "Both" and "the file lane only" are different
    # consequences (chat dies vs attachments die), so the wording has to distinguish them.
    case "$want" in
      gateway)
        if warning_states "$flat" 'file lane'; then
          fail_case "$name" "[$arm] a stable file lane was named as the rotating address"; return
        fi ;;
      lane)
        if ! warning_states "$flat" 'file lane'; then
          fail_case "$name" "[$arm] the rotating file-lane address was not named"; return
        fi
        if ! warning_states "$flat" 'chat (keeps|still)'; then
          fail_case "$name" "[$arm] a lane-only rotation did not say chat survives it"; return
        fi ;;
      both)
        if ! warning_states "$flat" 'both'; then
          fail_case "$name" "[$arm] two rotating addresses were reported as one"; return
        fi
        if warning_states "$flat" 'chat (keeps|still)'; then
          fail_case "$name" "[$arm] a rotating GATEWAY address was paired with 'chat keeps working'"; return
        fi ;;
    esac
  done <<ARMS
$arms
ARMS

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# Drive the PRODUCTION verify_all in isolation. Every request it makes is stubbed, so
# what is graded is the DIAGNOSIS: which cause the failure epilogue names, and which
# question it asks next. The gateway probe's outcome is injected exactly as
# models_is_json reports it (return code + MODELS_* diagnostics), which is the same
# contract verify_all reads on a live run.
# Args: <function-source> <transport> <models-rc> <http-code> <curl-rc> <loopback>
#       <local-port> <chat> <fs-url> <fs-cred> <show-qr> [gw-auth] [loopback-2xx]
#   loopback: up|down — what a 127.0.0.1 health probe answers
#   chat:     ok|fail — whether the live round-trip decodes
#   fs-url/fs-cred: a pair makes the file-lane block run; its probe always FAILS here
#   gw-auth:  bearer|none — the auth mode the operator configured for this gateway
#   loopback-2xx: yes|no — whether the gateway answers the SAME request on loopback.
#     Stubbed, and it prints its target: a case that grades a diagnosis drawn from a
#     live comparison has to be able to assert the comparison was actually made, and
#     the suite must never reach a real port to find that out.
run_verify_all_isolated() {
  FUNCS="$1" TRANSPORT_IN="$2" MRC="$3" MCODE="$4" MCURL="$5" LOOP="$6" \
  LPORT="$7" CHAT="$8" FSU="$9" FSC="${10}" SQ="${11}" \
  GWAUTH="${12:-bearer}" LB2XX="${13:-no}" bash -c '
eval "$FUNCS"
say()   { printf "%s\n" "$*"; }
ok()    { printf "OK %s\n" "$*"; }
bad()   { printf "BAD %s\n" "$*"; }
warn()  { printf "WARN %s\n" "$*"; }
note()  { printf "NOTE %s\n" "$*"; }
head_() { printf "%s\n" "$*"; }
die()   { printf "DIE %s\n" "$*"; exit 9; }
confirm() { printf "CONFIRM %s\n" "$*"; return 1; }   # asked at all is what is graded
models_is_json() {
  MODELS_CURL_RC="$MCURL"; MODELS_HTTP_CODE="$MCODE"
  MODELS_DATA_EMPTY=false; MODELS_NO_VALID_ID=false
  return "$MRC"
}
local_health_ok() { [ "$LOOP" = "up" ]; }
gw_answers_on_loopback() { printf "LOOPBACK-PROBE %s\n" "$1"; [ "$LB2XX" = "yes" ]; }
app_chat_eval()   { CCE_LEN=4; CCE_REASON="stubbed failure"; [ "$CHAT" = "ok" ]; }
curl_fs()         { return 22; }                       # the file-lane probe never succeeds
drop_file_lane()  { FS_URL=""; FS_CRED=""; printf "DROPPED-LANE\n"; }
agent_file_lane_gate() { :; }
check() { local l="$1"; shift; if "$@"; then ok "$l"; else bad "$l"; VERIFY_FAILED=true; return 1; fi; }
VERIFY_FAILED=false
FS_LANE_DROPPED_BY_CHECK=false
MODELS_CURL_RC=0; MODELS_HTTP_CODE=""; MODELS_DATA_EMPTY=false; MODELS_NO_VALID_ID=false
SHOW_QR=$SQ
TRANSPORT="$TRANSPORT_IN"
GW_KIND="custom"
GW_URL="https://moved.example.test"
GW_LOCAL_PORT="$LPORT"
GW_HEALTH_PATH=""
GW_AUTH="$GWAUTH"
GW_TOKEN="probe-token"
CHECKED_PATH_PREFIX=""
GW_MODEL=""
FS_URL="$FSU"
FS_CRED="$FSC"
verify_all
printf "VERIFY_FAILED=%s LANE_DROPPED=%s\n" "$VERIFY_FAILED" "$FS_LANE_DROPPED_BY_CHECK"
'
}

# A saved address that stops reaching this machine is the commonest real failure on the
# two transports with no local exposure to introspect, and the HTTP-code map alone files
# it as a server fault: Cloudflare answers 530 for a hostname whose tunnel is gone, and
# a quick tunnel hands out a new hostname on every restart. "The server errored" sends
# that operator to the gateway (or to Cloudflare) for a fix that is a re-run of setup.
#
# Facts, not paragraphs. Each arm pins what the epilogue must and must not claim; the
# 500 and 401 arms are the non-vacuity half — a note that fires on every failure would
# diagnose nothing, and one that fires on Tailscale would contradict the drift gate that
# already refused above it.
run_moved_address_diagnosis_case() {
  local name="moved-address-is-not-a-server-error" funcs out flat arm
  funcs=$(extract_funcs verify_all gw_url_drift_note)
  if [ -z "$funcs" ] || ! printf '%s\n' "$funcs" | grep -qF 'gw_url_drift_note()'; then
    fail_case "$name" "could not extract verify_all + gw_url_drift_note from the release artifact"; return
  fi
  : > "$TMP/doctor.out"

  # arm|transport|http-code|loopback|local-port|expect-moved|expect-server-errored
  local arms='cloudflare-530-up|cloudflare|530|up|8080|yes|no
public-530-up|public|530|up|8080|yes|no
public-530-down|public|530|down|8080|maybe|no
public-530-no-port|public|530|up||maybe|no
tailscale-530|tailscale|530|up|8080|no|no
public-500|public|500|up|8080|no|yes
public-401|public|401|up|8080|no|no'
  local transport code loop port want_moved want_errored
  while IFS='|' read -r arm transport code loop port want_moved want_errored; do
    [ -n "$arm" ] || continue
    out=$(run_verify_all_isolated "$funcs" "$transport" 1 "$code" 0 "$loop" "$port" ok "" "" false) \
      || { printf '%s\n' "$out" >> "$TMP/doctor.out"
           fail_case "$name" "[$arm] verify_all failed to run in isolation"; return; }
    printf -- '--- %s ---\n%s\n' "$arm" "$out" >> "$TMP/doctor.out"
    flat=$(printf '%s\n' "$out" | tr '\n' ' ')

    # The wrong diagnosis, in the exact words that sent users at the app or at Cloudflare.
    if [ "$want_errored" = "no" ] && warning_states "$flat" 'the server errored'; then
      fail_case "$name" "[$arm] the epilogue still blamed the server"; return
    fi
    if [ "$want_errored" = "yes" ] && ! warning_states "$flat" 'the server errored'; then
      fail_case "$name" "[$arm] a real 5xx no longer reads as a server fault"; return
    fi
    # FACT — the address, not the machine, is what stopped matching. Any phrasing that
    # says the address no longer reaches here counts; extend the alternation on reword.
    case "$want_moved" in
      yes)
        if ! warning_states "$flat" 'no longer reach|does not reach|doesn.t reach|address moved'; then
          fail_case "$name" "[$arm] nothing told the operator the address stopped reaching this machine"; return
        fi
        if ! warning_states "$flat" '127\.0\.0\.1:8080'; then
          fail_case "$name" "[$arm] the loopback comparison that proves the gateway is fine was not shown"; return
        fi
        if ! warning_states "$flat" 're-run|reconcile|address that is live'; then
          fail_case "$name" "[$arm] the epilogue named the cause but not the way out"; return
        fi ;;
      # Loopback silent (or no port to probe): the two causes cannot be separated, so the
      # epilogue owes BOTH — never a confident single verdict it has not earned.
      maybe)
        if ! warning_states "$flat" 'no longer reach|does not reach|doesn.t reach|moved address|still reaches'; then
          fail_case "$name" "[$arm] the address was never named as a possible cause"; return
        fi
        if ! warning_states "$flat" 'gateway is running|start it first|stopped gateway'; then
          fail_case "$name" "[$arm] an unprovable loopback state was reported as a certain verdict"; return
        fi ;;
      no)
        if warning_states "$flat" 'no longer reach|address moved|quick tunnel'; then
          fail_case "$name" "[$arm] a failure the address cannot explain was diagnosed as drift"; return
        fi ;;
    esac
  done <<ARMS
$arms
ARMS

  # Also pin the two rows the map itself owes this diagnosis: 530 must not be swallowed
  # by the 5xx bucket, and a hostname that stops resolving is the same drift.
  out=$(run_verify_all_isolated "$funcs" "public" 1 "" 6 up 8080 ok "" "" false)
  printf -- '--- public-dns-gone ---\n%s\n' "$out" >> "$TMP/doctor.out"
  if ! warning_states "$(printf '%s\n' "$out" | tr '\n' ' ')" 'no longer reach|does not reach|doesn.t reach'; then
    fail_case "$name" "a hostname that no longer resolves was not diagnosed as a moved address"; return
  fi

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# Ollama refuses any request whose Host header is not a local address, and a tunnel
# forwards the ORIGINAL host — so a quick tunnel pointed straight at it answers 403
# forever, on the exact setup this script's own prompt suggests ("e.g. 11434 for
# Ollama"). Answering that with "token rejected" on a gateway the operator configured
# KEYLESS is not merely unhelpful: there is no token in that run, so the sentence is
# false and it sends them hunting for a secret that does not exist.
#
# Facts, not paragraphs, arm by arm. The 401 arms and the 404 arm are the non-vacuity
# half: a note that fired on every failure would diagnose nothing, and 401 is a genuine
# credential refusal whose bearer wording is correct as it stands.
#
# The loopback comparison is STUBBED (run_verify_all_isolated prints its target), so
# what is graded here is the diagnosis drawn from it. That the probe itself requires a
# 2xx and carries the configured credential is proved against real loopback servers in
# tests/run-file-lane-readiness-suite.sh.
# The two STANDALONE diagnostics carry their own copy of the status ladder, and a failed
# setup now names --check-server as the first thing to run. So the keyless-403 rule proved
# for the setup path above has to hold here too, or the operator's very next screen undoes
# it. Written as a rule about the released artifact rather than about one call site: the
# arms are pure string assignment with no reachable side effect, so grading their text is
# the whole behaviour, and a live 403 fixture per arm would buy nothing but runtime.
run_standalone_check_keyless_403_case() {
  local name="standalone-checks-do-not-invent-a-keyless-token" fn body arm
  : > "$TMP/doctor.out"

  # fn|label
  local paths='compat_models_check|--check-server
doctor_models_check|--check-adapter'
  while IFS='|' read -r fn arm; do
    [ -n "$fn" ] || continue
    body=$(extract_funcs "$fn")
    if [ -z "$body" ]; then
      fail_case "$name" "[$arm] could not extract $fn from the release artifact"; return
    fi
    printf -- '--- %s (%s) ---\n%s\n' "$arm" "$fn" "$body" >> "$TMP/doctor.out"

    # The 401 and 403 arms must be SEPARATE. A shared `401|403)` is what produced the
    # defect, so its absence is the structural half of this guard — a future merge that
    # recombines them fails here rather than at a user's terminal.
    if printf '%s\n' "$body" | grep -qE '^[[:space:]]*401\|403\)'; then
      fail_case "$name" "[$arm] 401 and 403 share one arm again — a keyless 403 will be told to supply a token"; return
    fi
    if ! printf '%s\n' "$body" | grep -qE '^[[:space:]]*403\)'; then
      fail_case "$name" "[$arm] no 403 arm at all"; return
    fi

    # FACT 1 — the 403 arm never sends a keyless run after a credential. This is the
    # sentence that made the recommended recovery actively misleading.
    local arm403
    arm403=$(printf '%s\n' "$body" | sed -n '/^[[:space:]]*403)/,/^[[:space:]]*[0-9?]\{3\})/p')
    if printf '%s\n' "$arm403" | grep -qF 'CONDUCK_TOKEN'; then
      fail_case "$name" "[$arm] a 403 still tells the operator to set CONDUCK_TOKEN"; return
    fi

    # FACT 2 — it names what a 403 actually is, and the cause worth checking first.
    if ! printf '%s\n' "$arm403" | grep -qiE 'refused|as it arrived'; then
      fail_case "$name" "[$arm] a 403 does not say the request was refused as it arrived"; return
    fi
    if ! printf '%s\n' "$arm403" | grep -qiF 'Host'; then
      fail_case "$name" "[$arm] a 403 never names the Host check as the likely cause"; return
    fi

    # FACT 3 — the 401 arm KEEPS the token advice. It is correct there (a server that
    # wants auth answers 401), and deleting it would trade one wrong cure for another.
    local arm401
    arm401=$(printf '%s\n' "$body" | sed -n '/^[[:space:]]*401)/,/^[[:space:]]*403)/p')
    if ! printf '%s\n' "$arm401" | grep -qF 'CONDUCK_TOKEN'; then
      fail_case "$name" "[$arm] a keyless 401 no longer tells the operator how to supply a token"; return
    fi
  done <<EOF
$paths
EOF
  PASS=$((PASS+1)); printf 'SUITE ✓ %s\n' "$name"
}

# A keyless run that gets a 5xx is told "the server errored", which is wrong for every
# server that reports a MISSING credential from inside its own error handler — LiteLLM
# without a database answers 500 there, measured, because the handler imports a module
# only DB deployments install. The connector settles it by experiment rather than by
# guessing, so what this case grades is the EXPERIMENT: the control must hold before any
# claim is made, and no claim may be made when the difference is not attributable to the
# credential. Driven against a fixture whose status genuinely depends on the
# Authorization header, because a structural assertion cannot show a probe running in
# the wrong order.
run_keyless_5xx_credential_case() {
  local name="keyless-5xx-names-the-missing-credential" funcs out i line FPID="" FPORT=""
  funcs=$(extract_funcs curl_gw gw_5xx_credential_note)
  if [ -z "$funcs" ] || ! printf '%s\n' "$funcs" | grep -qF 'gw_5xx_credential_note()'; then
    fail_case "$name" "could not extract curl_gw + gw_5xx_credential_note from the release artifact"; return
  fi
  : > "$TMP/doctor.out"

  # Auth-sensitive fixture: 500 with no Authorization header, 400 with one — the shape
  # measured on a real DB-less LiteLLM. Status depends on the header and nothing else, so
  # an arm that stays silent can only have done so by failing a guard, never by chance.
  cat > "$TMP/fixture-auth-5xx.py" <<'PYFIX'
import socketserver
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_GET(self):
        code = 400 if self.headers.get("Authorization") is not None else 500
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"{}")
    def log_message(self, *a):
        pass
class S(HTTPServer):
    # Same rule as every other fixture here: never reverse-resolve the bind address,
    # or READY is withheld for the resolver timeout on a host with no reverse zone.
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]
srv = S(("127.0.0.1", 0), H)
print("READY %d" % srv.server_address[1], flush=True)
srv.serve_forever()
PYFIX

  : > "$TMP/auth5xx.out"
  python3 "$TMP/fixture-auth-5xx.py" > "$TMP/auth5xx.out" 2>"$TMP/auth5xx.err" &
  FPID=$!
  i=0
  while [ "$i" -lt "$FIXTURE_READY_TICKS" ]; do
    line=$(head -n 1 "$TMP/auth5xx.out" 2>/dev/null)
    case "$line" in READY\ *) FPORT="${line#READY }"; break ;; esac
    kill -0 "$FPID" 2>/dev/null || break
    i=$((i+1)); sleep 0.1
  done
  if [ -z "$FPORT" ]; then
    fixture_start_failed "auth-sensitive 5xx fixture" "$TMP/auth5xx.out" "$TMP/auth5xx.err"
    fail_case "$name" "auth-sensitive fixture never printed READY"
    kill "$FPID" 2>/dev/null; return
  fi

  # arm|auth|claimed-status|expect-claim. The fixture always answers 500 unauthenticated,
  # so a claimed 503 is the CONTROL: the status does not reproduce, and nothing may be
  # concluded from a second request that merely came out different.
  local arms='diagnoses-the-credential|none|500|yes
control-status-does-not-reproduce|none|503|no
bearer-run-is-not-this-arms-business|bearer|500|no
wrong-status-401|none|401|no
wrong-status-404|none|404|no'
  local arm auth claimed expect
  while IFS='|' read -r arm auth claimed expect; do
    [ -n "$arm" ] || continue
    out=$(FUNCS="$funcs" URL="http://127.0.0.1:$FPORT" MCODE="$claimed" GWAUTH="$auth" bash -c '
eval "$FUNCS"
warn() { printf "WARN %s\n" "$*"; }
note() { printf "NOTE %s\n" "$*"; }
DOCTOR=false; COMPAT=false
GW_AUTH="$GWAUTH"; GW_TOKEN=""
GW_CREDENTIAL_PROBE_TOKEN="conduck-connect-probe-not-a-real-token"
GW_URL="$URL"
MODELS_CURL_RC=0; MODELS_HTTP_CODE="$MCODE"
gw_5xx_credential_note
') || { printf '%s\n' "$out" >> "$TMP/doctor.out"
            fail_case "$name" "[$arm] the note function itself failed"
            kill "$FPID" 2>/dev/null; return; }
    printf -- '--- %s ---\n%s\n' "$arm" "$out" >> "$TMP/doctor.out"

    case "$expect" in
      yes)
        if ! printf '%s\n' "$out" | grep -qF 'wants a token after all'; then
          fail_case "$name" "[$arm] a keyless gateway whose answer depends on the credential was not told so"
          kill "$FPID" 2>/dev/null; return
        fi
        # Both observed statuses must be shown, or the operator is asked to take the
        # verdict on faith instead of reading the measurement that produced it.
        if ! printf '%s\n' "$out" | grep -qF 'HTTP 500 without one' ||
           ! printf '%s\n' "$out" | grep -qF 'HTTP 400 with one'; then
          fail_case "$name" "[$arm] the claim did not show the two statuses it rests on"
          kill "$FPID" 2>/dev/null; return
        fi
        ;;
      no)
        if [ -n "$out" ]; then
          fail_case "$name" "[$arm] claimed something the experiment does not support"
          kill "$FPID" 2>/dev/null; return
        fi
        ;;
    esac
  done <<EOF
$arms
EOF
  kill "$FPID" 2>/dev/null; wait "$FPID" 2>/dev/null
  PASS=$((PASS+1)); printf 'SUITE ✓ %s\n' "$name"
}

run_keyless_403_diagnosis_case() {
  local name="keyless-403-is-not-a-rejected-token" funcs out flat arm
  funcs=$(extract_funcs verify_all gw_url_drift_note gw_403_route_note gw_loopback_base)
  if [ -z "$funcs" ] || ! printf '%s\n' "$funcs" | grep -qF 'gw_403_route_note()'; then
    fail_case "$name" "could not extract verify_all + gw_403_route_note from the release artifact"; return
  fi
  : > "$TMP/doctor.out"

  # arm|auth|http-code|local-port|loopback-2xx|expect-route-note|expect-probe|expect-server-fine
  local arms='keyless-403-answers-locally|none|403|11434|yes|yes|yes|yes
keyless-403-silent-locally|none|403|11434|no|yes|yes|no
keyless-403-no-local-port|none|403||no|yes|no|no
bearer-403|bearer|403|11434|yes|yes|yes|yes
keyless-401|none|401|11434|yes|no|no|no
bearer-401|bearer|401|11434|yes|no|no|no
keyless-404|none|404|11434|yes|no|no|no'
  local auth code port lb want_note want_probe want_fine
  while IFS='|' read -r arm auth code port lb want_note want_probe want_fine; do
    [ -n "$arm" ] || continue
    out=$(run_verify_all_isolated "$funcs" public 1 "$code" 0 up "$port" ok "" "" false "$auth" "$lb") \
      || { printf '%s\n' "$out" >> "$TMP/doctor.out"
           fail_case "$name" "[$arm] verify_all failed to run in isolation"; return; }
    printf -- '--- %s ---\n%s\n' "$arm" "$out" >> "$TMP/doctor.out"
    flat=$(printf '%s\n' "$out" | tr '\n' ' ')

    # FACT 1 — the false sentence, in the exact words that sent keyless users after a
    # credential they never configured. Never sayable when GW_AUTH is none, whatever
    # the status; still sayable for a bearer gateway, where it is true.
    if [ "$auth" = "none" ] && warning_states "$flat" 'token (was )?(rejected|refused)|rejected (your|the) token'; then
      fail_case "$name" "[$arm] a keyless gateway was told its token was rejected"; return
    fi
    if [ "$auth" = "bearer" ] && [ "$code" = "401" ] && ! warning_states "$flat" 'token rejected'; then
      fail_case "$name" "[$arm] a real rejected bearer token no longer reads as one"; return
    fi
    # FACT 2 — on the two statuses that ARE about being allowed in, a keyless run says
    # so, which is what tells the reader why no credential is named. Scoped to those two
    # deliberately: a 404 is not an authentication answer, and saying "keyless" there
    # would be noise attached to a status the auth mode has nothing to do with.
    if [ "$auth" = "none" ] && case "$code" in 401|403) true ;; *) false ;; esac &&
       ! warning_states "$flat" 'keyless'; then
      fail_case "$name" "[$arm] a keyless gateway's refusal never mentioned that it is keyless"; return
    fi

    # FACT 3 — the route explanation and its cure ride 403 ONLY. On 401 the credential
    # really is what was refused, and a Host lecture there is a wrong turn.
    case "$want_note" in
      yes)
        if ! warning_states "$flat" 'HTTPS route|arrives through your HTTPS|HTTPS layer in front|HTTPS front'; then
          fail_case "$name" "[$arm] a 403 never named the HTTPS route as what refused the request"; return
        fi
        if ! warning_states "$flat" 'host header'; then
          fail_case "$name" "[$arm] the likeliest cause of a 403 was not named"; return
        fi
        if ! warning_states "$flat" 'proxy_set_header Host' ||
           ! warning_states "$flat" 'OLLAMA_HOST=0\.0\.0\.0|non-loopback address'; then
          fail_case "$name" "[$arm] a 403 named the cause but not a cure that works"; return
        fi
        # OLLAMA_ORIGINS may be MENTIONED (it is the most-cited answer to "Ollama refuses
        # my remote request", so disarming it saves a wasted round) but never PRESCRIBED:
        # it sets the browser CORS allow-list, while this 403 comes from a separate Host
        # allow-list that never reads it. Prescribing it would be this case's own defect
        # in a new costume — a confident instruction that cannot work.
        if warning_states "$flat" 'set OLLAMA_ORIGINS|OLLAMA_ORIGINS on the server|OLLAMA_ORIGINS so it'; then
          fail_case "$name" "[$arm] OLLAMA_ORIGINS was prescribed as a cure; it only governs browser CORS"; return
        fi ;;
      no)
        if warning_states "$flat" 'proxy_set_header Host|OLLAMA_ORIGINS'; then
          fail_case "$name" "[$arm] a failure the Host header cannot explain was given the Host cure"; return
        fi ;;
    esac

    # FACT 4 — the comparison is MADE, not described, and only where it can be made.
    case "$want_probe" in
      yes) if ! warning_states "$flat" 'LOOPBACK-PROBE http://127\.0\.0\.1:11434'; then
             fail_case "$name" "[$arm] the loopback comparison was never attempted"; return
           fi ;;
      no)  if warning_states "$flat" 'LOOPBACK-PROBE'; then
             fail_case "$name" "[$arm] a loopback comparison ran where there is nothing to compare"; return
           fi ;;
    esac

    # FACT 5 — "your server is fine" is claimed only when loopback actually answered.
    # An unproven all-clear is the same defect in the other direction: it would send
    # the operator away from a gateway that is genuinely refusing everyone.
    case "$want_fine" in
      yes) if ! warning_states "$flat" 'server is up|credentials are fine'; then
             fail_case "$name" "[$arm] a proven-healthy server was not reported as healthy"; return
           fi ;;
      no)  if warning_states "$flat" 'server is up|credentials are fine'; then
             fail_case "$name" "[$arm] the server was cleared without a loopback answer to clear it"; return
           fi ;;
    esac
    # FACT 6 — and the all-clear is worded for the auth mode that produced it. Clearing
    # "your credentials" on a run that carries none puts the reader back to hunting for a
    # token to inspect, which is the same wrong turn as FACT 1 taken one line later.
    if [ "$auth" = "none" ] && warning_states "$flat" 'credentials are fine|token is fine'; then
      fail_case "$name" "[$arm] a keyless gateway was told its credentials checked out"; return
    fi
  done <<ARMS
$arms
ARMS

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# Once a GATEWAY check has failed, emit_payload emits no code at all. So the file-lane
# branch must not offer a gateway-only code (a promise the same run then breaks with
# exit 1), and must not sign off with "fix the file server" when the gateway is what
# died — the file server is then the one machine that cannot be the cause.
# The passing-gateway arm is the control: it proves the OFFER still exists, so the arm
# above is graded on the gateway verdict and not on a question that was simply deleted.
run_file_lane_failure_names_the_gateway_case() {
  local name="file-fault-does-not-mask-a-dead-gateway" funcs out flat
  funcs=$(extract_funcs verify_all gw_url_drift_note)
  if [ -z "$funcs" ] || ! printf '%s\n' "$funcs" | grep -qF 'verify_all()'; then
    fail_case "$name" "could not extract verify_all from the release artifact"; return
  fi
  : > "$TMP/doctor.out"

  # --show-code, gateway DEAD (chat fails), file-lane probe also fails. The exit status is
  # deliberately not graded here: the stubbed die() exits nonzero, and dying at all on this
  # path is one of the behaviours under test — so the OUTPUT is what answers, not the code.
  out=$(run_verify_all_isolated "$funcs" public 0 200 0 up 8080 fail \
        "https://files.example.test:8443" "probe-cred" true)
  printf -- '--- dead gateway + failed file lane ---\n%s\n' "$out" >> "$TMP/doctor.out"
  flat=$(printf '%s\n' "$out" | tr '\n' ' ')

  # Non-vacuous: the run really did fail the gateway AND reach the file-lane branch.
  # Both lines print on either side of the fix, so this can't mask the assertions below.
  if ! warning_states "$flat" 'live round-trip failed' ||
     ! warning_states "$flat" 'file lane failed live verification'; then
    fail_case "$name" "the arm did not reach the file-lane branch with a failed gateway"; return
  fi
  if warning_states "$flat" 'CONFIRM Show a gateway-only code'; then
    fail_case "$name" "a gateway-only code was offered for a run that can emit no code"; return
  fi
  if warning_states "$flat" 'Fix the file server'; then
    fail_case "$name" "the last word was still 'fix the file server' on a gateway fault"; return
  fi
  if ! warning_states "$flat" 'gateway checks above failed|fix the gateway first'; then
    fail_case "$name" "nothing named the gateway as the thing to fix"; return
  fi
  # The lane is dropped for THIS emission and flagged as check-dropped, so the saved
  # profile keeps it (see profile-refusing-runs-keep-the-saved-lane).
  if ! warning_states "$flat" 'LANE_DROPPED=true'; then
    fail_case "$name" "a check-dropped lane was not flagged for the profile guard"; return
  fi

  # Control: same file-lane failure, gateway PASSING — the offer must still be made.
  out=$(run_verify_all_isolated "$funcs" public 0 200 0 up 8080 ok \
        "https://files.example.test:8443" "probe-cred" true)
  printf -- '--- live gateway + failed file lane ---\n%s\n' "$out" >> "$TMP/doctor.out"
  flat=$(printf '%s\n' "$out" | tr '\n' ' ')
  if ! warning_states "$flat" 'CONFIRM Show a gateway-only code'; then
    fail_case "$name" "the gateway-only offer is gone even when the gateway passed — the guard above proves nothing"; return
  fi
  if ! warning_states "$flat" 'DIE .*Fix the file server'; then
    fail_case "$name" "declining the offer no longer stops with the file-server remedy"; return
  fi

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

run_help_surface_case() {
  local name="help-lists-public-meta-flags" rc=0
  TERM=dumb bash "$SCRIPT" --help </dev/null > "$TMP/doctor.out" 2>&1 || rc=$?
  if [ "$rc" != "0" ] ||
     ! grep -qF 'bash conduck-connect.sh --help' "$TMP/doctor.out" ||
     ! grep -qF 'bash conduck-connect.sh --version' "$TMP/doctor.out" ||
     ! grep -qF 'software NOT built for Conduck' "$TMP/doctor.out" ||
     ! grep -qF '0  requested action succeeded (or a check passed)' "$TMP/doctor.out" ||
     ! grep -qF '1  setup/runtime failure, or a completed check failed' "$TMP/doctor.out" ||
     ! grep -qF '2  command-line usage error' "$TMP/doctor.out"; then
    fail_case "$name" "--help omitted part of the public command/exit contract"; return
  fi
  if grep -qF -- '--generic' "$TMP/doctor.out"; then
    fail_case "$name" "--help exposed the private shipped-client compatibility arm"; return
  fi
  if [ "$(TERM=dumb bash "$SCRIPT" --version 2>/dev/null)" != "conduck-connect 0.13.0" ]; then
    fail_case "$name" "--version did not print the expected public version"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

run_check_continue_yes_case() {
  local name="check-pass-continue-setup" rc=0
  start_fixture good || { fail_case "$name" "fixture failed to start"; stop_fixture; return; }
  local input
  # Menu 2 → URL → yes → default name → b at exposure. The checked URL/token
  # must be reused, so there is no second gateway or auth question.
  input=$'2\nhttp://127.0.0.1:'"$PORT"$'\ny\n\nb\n'
  # Isolated state: the handoff asks which saved gateway this is before exposure,
  # so a machine with one paired would answer a list here instead of the name
  # prompt this input assumes.
  local home="$TMP/check-continue-home" state="$TMP/check-continue-state"
  mkdir -p "$home" "$state"
  PTY_ENV=(CONDUCK_TOKEN="$TOKEN" HOME="$home" XDG_CONFIG_HOME="$state")
  pty_run 30 "$input" > "$TMP/doctor.out" 2>&1 || rc=$?
  stop_fixture
  if [ "$rc" != "0" ] ||
     ! grep -qF 'Reusing the checked address and authentication in memory' "$TMP/doctor.out" ||
     ! grep -qF 'Step 3 — how should your phone reach this gateway?' "$TMP/doctor.out" ||
     ! grep -qF 'Setup stopped. The completed check changed nothing' "$TMP/doctor.out"; then
    fail_case "$name" "yes did not transition directly from PASS into setup"; return
  fi
  if [ "$(grep -cF 'Step 1 — find your gateway' "$TMP/doctor.out")" != "0" ]; then
    fail_case "$name" "continued setup redundantly returned to gateway selection"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

run_long_model_handoff_case() {
  local name="long-model-check-setup-payload" rc=0 long_model
  long_model=$(python3 -c 'print("org/route-" + ("opaque-model-segment-" * 8) + "final")')
  [ "${#long_model}" -gt 100 ] || {
    fail_case "$name" "test fixture model is not longer than 100 characters"; return
  }

  # Real check → setup handoff: the exact advertised model must be retained, and
  # no obsolete warning may tell the user the app will truncate it.
  start_fixture require-long-model || {
    fail_case "$name" "fixture failed to start"; stop_fixture; return
  }
  # Isolated state, same reason as check-pass-continue-setup: the handoff asks
  # which saved gateway this is, and a machine with one paired would be shown a
  # list where this input expects the name prompt.
  local lm_home="$TMP/long-model-home" lm_state="$TMP/long-model-state"
  mkdir -p "$lm_home" "$lm_state"
  PTY_ENV=(CONDUCK_TOKEN="$TOKEN" HOME="$lm_home" XDG_CONFIG_HOME="$lm_state")
  pty_run 30 $'y\n\nb\n' --check-server "http://127.0.0.1:$PORT" \
    > "$TMP/doctor.out" 2>&1 || rc=$?
  stop_fixture
  if [ "$rc" != "0" ] ||
     ! grep -qF "Reusing the exact model ID the successful check required: $long_model" "$TMP/doctor.out" ||
     ! grep -qF 'Step 3 — how should your phone reach this gateway?' "$TMP/doctor.out" ||
     ! grep -qF 'Setup stopped. The completed check changed nothing' "$TMP/doctor.out"; then
    fail_case "$name" "the real check-to-setup handoff did not preserve the long model"; return
  fi
  if grep -qiE 'over 100 characters|first 100 characters|truncate.{0,20}100' "$TMP/doctor.out"; then
    fail_case "$name" "obsolete 100-character warning is still emitted"; return
  fi

  # Pure handoff → payload proof using the production functions. This avoids
  # opening a real exposure while still proving the exact value that entered
  # prepare_setup_from_check is the value serialized into the pairing payload.
  local prepare_func payload_func display_func payload
  prepare_func=$(sed -n '/^prepare_setup_from_check()/,/^}/p' "$SCRIPT")
  payload_func=$(sed -n '/^build_pairing_payload_json()/,/^}/p' "$SCRIPT")
  # prepare_setup_from_check now routes the paired id through safe_display for the
  # transcript line, so the extracted set must carry it or the case fails on a
  # missing command rather than on the behaviour it is meant to grade.
  display_func=$(sed -n '/^safe_display()/,/^}/p' "$SCRIPT")
  payload=$(FUNCS="$prepare_func
$payload_func
$display_func" LONG_MODEL="$long_model" bash -c '
eval "$FUNCS"
ask() { printf "%s" "$2"; }
slug() { printf "%s" "$1" | tr "[:upper:]" "[:lower:]" | tr -cs "a-z0-9" "-"; }
ok() { :; }
note() { :; }
GW_URL="https://gateway.example.test"
GW_AUTH="bearer"
GW_TOKEN="secret"
# The name and id are settled by resolve_setup_from_check_identity, which runs
# later (under the setup lock) and is not part of this extraction. Standing them
# up here keeps the payload a realistic one — a custom gateway with no name is a
# code the app would reject — so the model assertion below grades the model
# rather than a payload that was never viable.
GW_NAME="My gateway"
GW_KIND=""
GW_ID="custom-my-gateway"
GW_MODEL=""
GW_LOCAL_PORT=""
GW_HEALTH_PATH=""
TRANSPORT=""
SCOPE=""
FS_URL=""
FS_CRED=""
COMPAT_MODEL_ID="$LONG_MODEL"
COMPAT_MODEL_SOURCE="first_advertised"
PAYLOAD_VERSION=1
prepare_setup_from_check server
TRANSPORT="public"
build_pairing_payload_json
') || {
    fail_case "$name" "production handoff/payload functions failed"; return
  }
  if ! EXPECTED_MODEL="$long_model" PAYLOAD="$payload" python3 -c '
import json, os
p = json.loads(os.environ["PAYLOAD"])
raise SystemExit(0 if p["gateway"].get("model") == os.environ["EXPECTED_MODEL"] else 1)
'; then
    fail_case "$name" "pairing JSON changed or truncated the long model id"; return
  fi

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# Drive the PRODUCTION reach question with every consequence stubbed. No PTY on
# purpose: the only prompt on this path is require_choice, and require_choice is
# the tripwire — a harness that had to TYPE an answer could not tell "never
# asked" from "asked and answered".
#
# The tripwire answers 2 = Private, which is the load-bearing detail. SCOPE can
# then only come out "public" from the derived branch, never from an answer, so
# a green quick-tunnel arm cannot pass vacuously: delete the branch and the arm
# reports private, which is exactly the silent-downgrade this case exists for.
# The marker goes to STDERR because require_choice runs inside $( ) — on stdout
# it would BE the answer.
# Args: <function-source> <gateway-url> <gw-auth> <allow-keyless-public>.
run_scope_choice_isolated() {
  env FUNCS="$1" GWU="$2" AUTH="$3" AKP="$4" bash -c '
eval "$FUNCS"
BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""
NO_ANSWER="no answer"
say()  { printf "%s\n" "$*"; }
note() { printf "%s\n" "$*"; }
ok()   { printf "OK %s\n" "$*"; }
bad()  { printf "BAD %s\n" "$*"; }
warn() { printf "WARN %s\n" "$*"; }
die()  { printf "DIE %s\n" "$*"; exit 7; }
quit_run()             { printf "SIDE_EFFECT quit\n"; exit 8; }
explain_scope_choice() { printf "SIDE_EFFECT explain\n" >&2; }
require_choice()       { printf "SIDE_EFFECT require_choice\n" >&2; printf "2\n"; }
SCOPE=""
GW_URL="$GWU"
GW_AUTH="$AUTH"
ALLOW_KEYLESS_PUBLIC="$AKP"
scope_choice
printf "SCOPE=%s\n" "$SCOPE"
keyless_public_guard
printf "REACHED_END\n"
' 2>&1
}

# A `cloudflared tunnel --url` address is public by construction — there is no
# private variant of one — so asking the operator to classify it does not gather
# information, it only offers them a way to switch the keyless-public guard off
# by answering wrongly. The wizard already knows the answer, and menu option 3
# sets the precedent: a NAMED Cloudflare tunnel hardcodes SCOPE=public without
# asking. Reach it CANNOT derive is still an explicit 1/2 with no Enter default.
#
# Two arms carry the regression weight. The ?query and #fragment arms are the
# guard on the authority cut inside is_quick_tunnel_url: end the authority at /
# alone and both URLs fall through to the question, which is the failure this
# whole case is about, wearing a URL that looks fine. The near-miss host arm is
# the other direction — it must STILL be asked, or the derivation has become a
# substring match. It is the same literal used by the pairing-code case.
run_scope_quick_tunnel_case() {
  local name="quick-tunnel-reach-is-not-a-question" funcs scope_src out rc fn
  local arm url auth akp scope asked exprc guard

  # Truncated before the structural guards below, not after: those two fire on a
  # stale artifact, and fail_case tails this file unconditionally.
  : > "$TMP/doctor.out"

  funcs=$(extract_funcs scope_choice is_quick_tunnel_url keyless_public_guard)
  for fn in scope_choice is_quick_tunnel_url keyless_public_guard; do
    if ! printf '%s\n' "$funcs" | grep -qF "$fn()"; then
      fail_case "$name" "could not extract $fn from the release artifact"; return
    fi
  done

  # One host-matching rule, not two. scope_choice must ASK the shared predicate;
  # a copy of the *.trycloudflare.com suffix inside scope_choice would drift from
  # the one in is_quick_tunnel_url and the two answers would disagree.
  scope_src=$(extract_funcs scope_choice)
  if ! printf '%s\n' "$scope_src" | grep -qF 'is_quick_tunnel_url'; then
    fail_case "$name" "scope_choice does not derive reach from the shared quick-tunnel predicate"; return
  fi
  if printf '%s\n' "$scope_src" | grep -qF 'trycloudflare'; then
    fail_case "$name" "scope_choice matches the quick-tunnel host itself instead of calling the shared predicate"; return
  fi

  # arm|gateway-url|gw-auth|allow-keyless-public|expected SCOPE|asked|exit|guard: none · die · warn
  local arms="quick-plain|https://x.trycloudflare.com|bearer|false|public|no|0|none
quick-query|https://x.trycloudflare.com?a=1|bearer|false|public|no|0|none
quick-fragment|https://x.trycloudflare.com#frag|bearer|false|public|no|0|none
quick-uppercase|https://X.TryCloudflare.com|bearer|false|public|no|0|none
near-miss-host|https://not-really.trycloudflare.com.example.test|bearer|false|private|yes|0|none
ordinary-host|https://ai.example.com|bearer|false|private|yes|0|none
quick-keyless-refused|https://x.trycloudflare.com|none|false|public|no|7|die
quick-keyless-overridden|https://x.trycloudflare.com|none|true|public|no|0|warn"

  while IFS='|' read -r arm url auth akp scope asked exprc guard; do
    [ -n "$arm" ] || continue
    rc=0
    out=$(run_scope_choice_isolated "$funcs" "$url" "$auth" "$akp") || rc=$?
    printf -- '--- %s ---\n%s\n' "$arm" "$out" >> "$TMP/doctor.out"

    if [ "$rc" != "$exprc" ]; then
      fail_case "$name" "[$arm] exit $rc, expected $exprc"; return
    fi
    if ! printf '%s\n' "$out" | grep -qF "SCOPE=$scope"; then
      fail_case "$name" "[$arm] reach came out as something other than $scope"; return
    fi

    # Two independent probes of the same fact, because either one alone could be
    # defeated on its own: the prompt function was never entered, AND the choice
    # the operator would have read was never printed.
    if [ "$asked" = "no" ]; then
      if printf '%s\n' "$out" | grep -qF 'SIDE_EFFECT require_choice'; then
        fail_case "$name" "[$arm] an address the wizard can classify was put to the operator anyway"; return
      fi
      if printf '%s\n' "$out" | grep -qF '2) Private'; then
        fail_case "$name" "[$arm] the public/private menu was printed for a derived answer"; return
      fi
      # …and it says why, or the operator reads an unexplained PUBLIC verdict.
      if ! printf '%s\n' "$out" | grep -qiF 'quick tunnel' ||
         ! printf '%s\n' "$out" | grep -qiF 'public'; then
        fail_case "$name" "[$arm] reach was derived silently — the screen never named the quick tunnel or the verdict"; return
      fi
    else
      if ! printf '%s\n' "$out" | grep -qF 'SIDE_EFFECT require_choice'; then
        fail_case "$name" "[$arm] reach this wizard cannot know was decided without asking"; return
      fi
      if ! printf '%s\n' "$out" | grep -qF '2) Private'; then
        fail_case "$name" "[$arm] the reach question stopped offering the two answers"; return
      fi
    fi

    # A derived PUBLIC is worth nothing if it does not reach the guard it exists
    # to arm. This is the consequence arm: refusal, not a warning the run ignores.
    case "$guard" in
      die)
        if ! printf '%s\n' "$out" | grep -qF 'DIE Refusing to publish a keyless gateway.'; then
          fail_case "$name" "[$arm] a keyless gateway on a public quick tunnel was not refused"; return
        fi
        if printf '%s\n' "$out" | grep -qF 'REACHED_END'; then
          fail_case "$name" "[$arm] the run continued past the keyless refusal"; return
        fi ;;
      warn)
        if printf '%s\n' "$out" | grep -qF 'DIE '; then
          fail_case "$name" "[$arm] --allow-keyless-public no longer overrides the refusal"; return
        fi
        if ! printf '%s\n' "$out" | grep -qF 'allow-keyless-public' ||
           ! printf '%s\n' "$out" | grep -qF 'REACHED_END'; then
          fail_case "$name" "[$arm] the deliberate override ran without saying what it published"; return
        fi ;;
      none)
        if printf '%s\n' "$out" | grep -qF 'DIE ' ||
           ! printf '%s\n' "$out" | grep -qF 'REACHED_END'; then
          fail_case "$name" "[$arm] a gateway with a token was stopped by the keyless guard"; return
        fi ;;
    esac
  done <<ARMS
$arms
ARMS

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# A credential pasted at a y/n prompt is already on screen; the only thing still
# in the wizard's control is whether it makes a SECOND copy while explaining the
# mistake. So the value must be named as a credential and never reprinted.
#
# The two transports are the whole design of this case. Under a PIPE `read` does
# not echo, so the fixture token has no legitimate reason to appear at all and
# any occurrence is one the script itself wrote — zero is the assertion. Under a
# real terminal the line discipline echoes what is typed, so exactly ONE is the
# honest floor and a second would be the script adding its own copy. Each
# transport also pins the branch of the caution that belongs to it: the warning
# must not tell a piped session the value is in its scroll-back.
#
# The fixture token is deliberately shaped, obviously fake, and never a real
# provider key — this file is committed, and a realistic-looking secret in a test
# is how a scanner alert becomes routine and gets ignored.
run_secret_shape_case() {
  local name="a-pasted-credential-is-named-at-the-prompt-that-refused-it"
  local secret="sk-fixture-000000000000000000000000"
  local funcs harness out rc fn hits tok_line caution_line
  local want value

  # Truncated before the extraction guards, which fail_case tails.
  : > "$TMP/doctor.out"

  funcs=$(extract_funcs looks_like_a_secret warn_answer_looked_like_a_secret confirm)
  for fn in looks_like_a_secret warn_answer_looked_like_a_secret confirm; do
    if ! printf '%s\n' "$funcs" | grep -qF "$fn()"; then
      fail_case "$name" "could not extract $fn from the release artifact"; return
    fi
  done

  # One caution, written once and called from every prompt — not re-typed per
  # prompt, where one copy quietly loses the rotate advice.
  if ! printf '%s\n' "$funcs" | grep -qF 'warn_answer_looked_like_a_secret'; then
    fail_case "$name" "confirm does not route a credential-shaped answer to the shared caution"; return
  fi

  harness='
eval "$FUNCS"
BOLD=""; DIM=""; RESET=""; YELLOW=""; RED=""; GREEN=""
warn()           { printf "WARN %s\n" "$*"; }
explain_prompt() { printf "SIDE_EFFECT explain %s\n" "$1"; }
quit_run()       { printf "SIDE_EFFECT quit\n"; exit 8; }
confirm "Fixture confirmation" "fixture.secret"
printf "CONFIRM_RC=%s\n" "$?"
'

  # (a) Piped. Nothing echoes, so every occurrence of the token is the script.
  rc=0
  out=$(printf '%s\nn\n' "$secret" | env FUNCS="$funcs" bash -c "$harness" 2>&1) || rc=$?
  printf -- '--- pasted secret, piped ---\n%s\n' "$out" >> "$TMP/doctor.out"

  if [ "$rc" != "0" ] || ! printf '%s\n' "$out" | grep -qF 'CONFIRM_RC=1'; then
    fail_case "$name" "the piped prompt did not recover and take the following answer"; return
  fi
  hits=$(printf '%s\n' "$out" | grep -o -F -- "$secret" | wc -l | tr -d ' ')
  if [ "$hits" != "0" ]; then
    fail_case "$name" "the wizard reprinted the pasted credential $hits time(s) — the caution must never echo the value"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF 'looked like a token or password' ||
     ! printf '%s\n' "$out" | grep -qF 'If it was real, rotate it.'; then
    fail_case "$name" "a credential-shaped answer was refused without naming it as a credential"; return
  fi
  # The branch that belongs to a pipe. Telling a piped session the value is in its
  # scroll-back states something the operator can see is untrue, which is how they
  # learn to skip the next warning.
  if ! printf '%s\n' "$out" | grep -qF 'Assume this session may have recorded it.' ||
     printf '%s\n' "$out" | grep -qF 'It was shown as you typed it'; then
    fail_case "$name" "the piped caution claimed a terminal echo that never happened"; return
  fi

  # (b) A real terminal. The tty echoes once; anything above one is the script.
  rc=0
  out=$(env -u CI TERM=dumb FUNCS="$funcs" \
      python3 "$PTY_RUN" 10 "$secret"$'\nn\n' bash -c "$harness" 2>&1) || rc=$?
  printf -- '--- pasted secret, real terminal ---\n%s\n' "$out" >> "$TMP/doctor.out"

  if [ "$rc" != "0" ] || ! printf '%s\n' "$out" | grep -qF 'CONFIRM_RC=1'; then
    fail_case "$name" "the terminal prompt did not recover and take the following answer"; return
  fi
  hits=$(printf '%s\n' "$out" | grep -o -F -- "$secret" | wc -l | tr -d ' ')
  if [ "$hits" != "1" ]; then
    fail_case "$name" "the credential appears $hits time(s) on a real terminal; exactly 1 is the tty echo and any more is a copy the wizard added"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF 'looked like a token or password' ||
     ! printf '%s\n' "$out" | grep -qF 'If it was real, rotate it.'; then
    fail_case "$name" "a credential-shaped answer was refused without naming it as a credential"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF 'It was shown as you typed it' ||
     printf '%s\n' "$out" | grep -qF 'Assume this session may have recorded it.'; then
    fail_case "$name" "the terminal caution did not point at the scroll-back the value is actually in"; return
  fi
  # Ordering: the caution has to sit under the value it is about. Weaker than the
  # count above — pty-run.py writes the whole input up front, so the echo lands
  # early no matter what — but it still catches a caution emitted before the read.
  tok_line=$(printf '%s\n' "$out" | grep -n -F -- "$secret" | head -1 | cut -d: -f1)
  caution_line=$(printf '%s\n' "$out" | grep -n -F 'looked like a token or password' | head -1 | cut -d: -f1)
  if [ -z "$tok_line" ] || [ -z "$caution_line" ] || [ "$caution_line" -le "$tok_line" ]; then
    fail_case "$name" "the caution did not follow the answer it is about"; return
  fi

  # (c)+(d) The predicate itself. Shape only — length and character mix, never a
  # known token prefix, because a prefix list only ever recognises the providers
  # someone remembered to add.
  #
  # want|value
  local arms="fire|$secret
fire|a3f9c1e40b7d2856f04a9c3e71b58d26
fire|ghp_16CharsAndMore123
quiet|y
quiet|yes please
quiet|back
quiet|11434
quiet|https://ai.example.com:8443
quiet|HTTPS://Example123.com/v1
quiet|abcdef123456789
fire|anthropic/claude-sonnet-4-5"

  out=$(env FUNCS="$funcs" ARMS="$arms" bash -c '
eval "$FUNCS"
printf "%s\n" "$ARMS" | while IFS="|" read -r want value; do
  [ -n "$want" ] || continue
  if looks_like_a_secret "$value"; then got=fire; else got=quiet; fi
  printf "PREDICATE %s|%s|%s\n" "$want" "$got" "$value"
done
' 2>&1)
  printf -- '--- secret-shape predicate ---\n%s\n' "$out" >> "$TMP/doctor.out"

  while IFS='|' read -r want value; do
    [ -n "$want" ] || continue
    if ! printf '%s\n' "$out" | grep -qF "PREDICATE $want|$want|$value"; then
      fail_case "$name" "looks_like_a_secret should $want on '$value' and did not"; return
    fi
  done <<ARMS
$arms
ARMS

  # The last arm above is a KNOWN false alarm, asserted deliberately rather than
  # left to be discovered: a model id like anthropic/claude-sonnet-4-5 is long,
  # spaceless and carries digits, so the shape rule fires on it. That is the
  # accepted trade — a false alarm costs three lines of advice, a miss leaves a
  # live token in someone's scroll-back. If a future change tightens the
  # predicate, this arm is the one to update, on purpose, in the same commit —
  # never by quietly deleting it.
  # Non-vacuous: the uppercase URL arm is the case-insensitivity guard. Test the
  # scheme before lowercasing and HTTPS://Example123.com/v1 survives it, then
  # trips the digit rule and a plain address gets refused as a credential.
  # The 15-character arm sits one character under the length floor: drop the floor
  # and it fires, so the floor is really being measured and not assumed.

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

run_fixture_bind_case() {
  local name="fixtures-do-not-reverse-resolve-their-bind" offenders

  # Structural guard: no fixture may instantiate a STOCK HTTPServer or
  # ThreadingHTTPServer. http.server's server_bind() calls socket.getfqdn() on
  # the bind address — a REVERSE DNS lookup — and every fixture prints READY
  # only after it returns. On a runner with no reverse zone for 127.0.0.1 that
  # blocks until the resolver gives up (~20s measured on GitHub's macOS images),
  # the runner stops waiting for READY, and every case needing a fixture fails
  # while the process is still alive and producing no diagnostic at all.
  #
  # Written as a rule about the tree rather than about one fixture: the same
  # line existed in four places, and three of them were found only by grepping
  # for the first. Subclasses that override server_bind do not match, which is
  # the point — the fix is to bind without resolving, not to avoid the class.
  offenders=$(grep -rnE '=[[:space:]]*(http\.server\.)?(Threading)?HTTPServer\(' \
    "$HERE"/*.py "$HERE/../scripts"/*.sh 2>/dev/null || true)
  if [ -n "$offenders" ]; then
    fail_case "$name" "binds a stock HTTPServer, whose server_bind reverse-resolves before READY: $(printf '%s' "$offenders" | head -n 1)"
    return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

run_curl_config_isolation_case() {
  local name="all-curl-calls-ignore-config" rc=0 hard_home="$TMP/curl-home"
  local curl_lines funcs

  # Structural guard: every direct curl invocation in the release artifact has
  # -q as argv[1]. That ordering matters; later -q does not suppress curlrc.
  curl_lines=$(grep -nE '^[[:space:]]*curl[[:space:]]|[|][[:space:]]*curl[[:space:]]|\$\(curl[[:space:]]|\)[[:space:]]*curl[[:space:]]' \
    "$SCRIPT" || true)
  if printf '%s\n' "$curl_lines" | grep -vE 'curl[[:space:]]+-q([[:space:]]|$)' >/dev/null; then
    fail_case "$name" "a direct curl call does not put -q first"; return
  fi

  # Structural guard, second half: `-q` suppresses ~/.curlrc but NOT $http_proxy
  # / $ALL_PROXY, and curl has no loopback exemption. Any curl whose URL literal
  # is http://127.0.0.1 would therefore hand a proxy host the request — with the
  # bearer token, on the model-probe path — so every one of them must also carry
  # --noproxy. This is written as a rule about the artifact, not about one
  # function, because the missed call site was found by reading, not by a test.
  if printf '%s\n' "$curl_lines" | grep -F 'http://127.0.0.1' \
     | grep -vF -- '--noproxy' >/dev/null; then
    fail_case "$name" "a curl call to a literal http://127.0.0.1 URL is missing --noproxy"; return
  fi
  # local_health_ok is the one loopback curl whose URL arrives as a variable, so
  # the literal-URL rule above cannot see it. A proxy answering 200 here forges
  # exactly the "your gateway is up" verdict the function exists to establish.
  if ! sed -n '/^local_health_ok()/,/^}/p' "$SCRIPT" | grep -qF -- '--noproxy'; then
    fail_case "$name" "local_health_ok probes loopback without --noproxy"; return
  fi

  # Dynamic guard for the normal setup/show-code wrapper (the diagnostics
  # already run every server case with a hostile curlrc). A curlrc `output=`
  # directive would create this file if setup still honored user config.
  mkdir -p "$hard_home"
  printf 'output = "%s"\n' "$TMP/setup-curlrc-output" > "$hard_home/.curlrc"
  start_fixture good || {
    fail_case "$name" "fixture failed to start"; stop_fixture; return
  }
  funcs=$(sed -n '/^curl_gw()/,/^}/p' "$SCRIPT")
  HOME="$hard_home" CURL_HOME="$hard_home" XDG_CONFIG_HOME="$hard_home/xdg" \
    FUNCS="$funcs" URL="http://127.0.0.1:$PORT" bash -c '
eval "$FUNCS"
TRANSPORT="public"
GW_AUTH="none"
GW_TOKEN=""
DOCTOR=false
COMPAT=false
curl_gw -o /dev/null "$URL/v1/models"
' > "$TMP/doctor.out" 2>&1 || rc=$?
  stop_fixture
  if [ "$rc" != "0" ] || [ -e "$TMP/setup-curlrc-output" ]; then
    fail_case "$name" "normal setup curl honored a hostile curl config"; return
  fi

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# A gateway is not trusted to be friendly. Model ids, Content-Type values and
# error.code all come off the wire and all reach the terminal, where the check
# transcript is a sequence of "[CHECK_ID] …" lines that CI and humans read as
# verdicts. An embedded newline forges a whole extra line — a hostile server
# printing its own green PASS — and an ANSI escape repaints what was already
# shown. Drive the three real parsers with a hostile reply and assert nothing
# with a control byte in it survives to the transcript.
run_gateway_text_sanitised_case() {
  local name="gateway-text-cannot-forge-transcript" funcs out
  local esc; esc=$(printf '\033')

  # The hostile payloads are built as real JSON, so the control bytes ride as
  # JSON string ESCAPES — which is how they actually arrive. A raw newline inside a JSON
  # string is invalid JSON and never reaches the decoder in the first place.
  local hostile_models hostile_error
  hostile_models=$(python3 -c '
import json
bad = "gpt\x1b[2Kfake\n  ✓ [MODELS_ENVELOPE] forged pass\ttab"
print(json.dumps({"data": [{"id": bad}]}))') \
    || { fail_case "$name" "could not build the hostile models payload"; return; }
  hostile_error=$(python3 -c '
import json
bad = "bad\n  ✓ [CHAT_BASIC] forged pass\x1b[0m"
print(json.dumps({"error": {"code": bad}}))') \
    || { fail_case "$name" "could not build the hostile error payload"; return; }

  # 1) The /v1/models classifier: model id + Content-Type. curl_gw is stubbed so
  #    the case stays a pure unit test of the parser (no fixture, no network).
  funcs=$(extract_funcs safe_display models_is_json)
  if ! printf '%s\n' "$funcs" | grep -qF 'models_is_json()' \
     || ! printf '%s\n' "$funcs" | grep -qF 'safe_display()'; then
    fail_case "$name" "could not extract safe_display/models_is_json from the release artifact"; return
  fi
  out=$(FUNCS="$funcs" BODY="$hostile_models" bash -c '
eval "$FUNCS"
DOCTOR=false
# The -w trailer curl_gw appends is "<code> <seconds> <content-type>"; the
# Content-Type carries an ESC, which curl would pass through verbatim.
curl_gw() { printf "%s\n200 0.010 application/json\033[31m" "$BODY"; }
models_is_json "http://127.0.0.1:1" >/dev/null 2>&1
printf "ID<%s>\nCT<%s>\n" "$MODELS_FIRST_ID" "$MODELS_CONTENT_TYPE"
' 2>/dev/null) || { fail_case "$name" "models_is_json failed to run in isolation"; return; }
  printf '%s\n' "$out" > "$TMP/doctor.out"
  if [ "$(printf '%s\n' "$out" | grep -c .)" != "2" ]; then
    fail_case "$name" "a control byte from the models reply produced extra output lines"; return
  fi
  if ! printf '%s\n' "$out" | grep -q '^ID<gpt'; then
    fail_case "$name" "the model id did not survive sanitising as usable text"; return
  fi
  case "$out" in *"$esc"*) fail_case "$name" "an ANSI escape from the models reply survived the classifier"; return ;; esac

  # 2) safe_display's own contract: strips C0/DEL, bounds the length, and keeps
  #    ordinary text (including non-ASCII) byte-for-byte. Removing the ESC is the
  #    whole job — the "[31m" left behind is inert text once it has no ESC.
  funcs=$(extract_funcs safe_display)
  out=$(FUNCS="$funcs" bash -c '
eval "$FUNCS"
printf "A<%s>\n" "$(safe_display "$(printf "a\033[31mb\tc\177d")")"
printf "B<%s>\n" "$(safe_display "aaaaaaaaaa" 4)"
printf "C<%s>\n" "$(safe_display "mistral-7b-instruct-v0.3-ü")"
') || { fail_case "$name" "safe_display failed to run in isolation"; return; }
  printf '%s\n' "$out" >> "$TMP/doctor.out"
  if ! printf '%s\n' "$out" | grep -qxF 'A<a[31mbcd>' \
     || ! printf '%s\n' "$out" | grep -qxF 'B<aaaa…>' \
     || ! printf '%s\n' "$out" | grep -qxF 'C<mistral-7b-instruct-v0.3-ü>'; then
    fail_case "$name" "safe_display did not strip, bound, and otherwise preserve as specified"; return
  fi

  # 3) error.code: quoted verbatim into CCE_REASON, which every failure verdict
  #    prints. This is the one that can forge a "[CHECK_ID] … ✓" line outright.
  funcs=$(extract_funcs app_chat_loaded_eval)
  if [ -z "$funcs" ]; then
    fail_case "$name" "could not extract app_chat_loaded_eval from the release artifact"; return
  fi
  out=$(FUNCS="$funcs" BODY="$hostile_error" bash -c '
eval "$FUNCS"
app_chat_body_eval() { return 1; }
DCC_CODE="400"
DCC_BODY="$BODY"
CCE_REASON=""; CCE_WIRE_CODE=""
app_chat_loaded_eval >/dev/null 2>&1
printf "REASON<%s>\n" "$CCE_REASON"
' 2>/dev/null) || { fail_case "$name" "app_chat_loaded_eval failed to run in isolation"; return; }
  printf '%s\n' "$out" >> "$TMP/doctor.out"
  if [ "$(printf '%s\n' "$out" | grep -c .)" != "1" ]; then
    fail_case "$name" "a newline in error.code forged an extra transcript line"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF 'wire code "bad'; then
    fail_case "$name" "the wire code stopped reaching the verdict text at all"; return
  fi
  case "$out" in *"$esc"*) fail_case "$name" "an ANSI escape in error.code reached the verdict text"; return ;; esac

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# https://user:pass@host is a credential smuggled into a routing field: it is
# echoed to the terminal, written to the pairing profile that WHAT-IT-TOUCHES.md
# calls credential-free, and paired into the app — which refuses userinfo on
# every persisted endpoint URL. Both URL entry points must refuse it too, and
# the refusal must name the real fix rather than say "use https://".
run_url_userinfo_refused_case() {
  local name="urls-refuse-embedded-credentials" funcs out
  local cred='https://spy:hunter2@gateway.example.test'

  funcs=$(extract_funcs url_has_userinfo doctor_accept_url)
  if ! printf '%s\n' "$funcs" | grep -qF 'doctor_accept_url()'; then
    fail_case "$name" "could not extract the URL acceptors from the release artifact"; return
  fi
  out=$(FUNCS="$funcs" CRED="$cred" bash -c '
eval "$FUNCS"
# Refused on the https arm, on the loopback arm, and with a path/query after the
# authority (the authority ends at the first / ? or #, not at the first slash).
for u in "$CRED" "http://127.0.0.1@evil.example.test:8080" \
         "https://spy:hunter2@gateway.example.test/v1" \
         "https://spy@gateway.example.test?x=1"; do
  doctor_accept_url "$u" >/dev/null 2>&1 && printf "ACCEPTED<%s>\n" "$u"
done
# An ordinary URL with an @ only in the PATH is still fine — the guard parses the
# authority, it does not grep the whole string.
doctor_accept_url "https://gateway.example.test/user@host/v1" || printf "REGRESSED<path-@>\n"
doctor_accept_url "http://127.0.0.1:8080" >/dev/null || printf "REGRESSED<loopback>\n"
printf "DONE\n"
') || { fail_case "$name" "doctor_accept_url failed to run in isolation"; return; }
  printf '%s\n' "$out" > "$TMP/doctor.out"
  if printf '%s\n' "$out" | grep -q '^ACCEPTED<'; then
    fail_case "$name" "doctor_accept_url accepted a URL carrying userinfo"; return
  fi
  if printf '%s\n' "$out" | grep -q '^REGRESSED<'; then
    fail_case "$name" "the userinfo guard rejected a legitimate URL"; return
  fi

  # The interactive prompt: it must re-ask rather than abort, and the warning has
  # to point at the token field instead of repeating "use https://".
  funcs=$(extract_funcs url_has_userinfo ask_url; sed -n '/^URL_USERINFO_HINT=/p' "$SCRIPT")
  if ! printf '%s\n' "$funcs" | grep -qF 'ask_url()' \
     || ! printf '%s\n' "$funcs" | grep -qF 'URL_USERINFO_HINT='; then
    fail_case "$name" "could not extract ask_url from the release artifact"; return
  fi
  out=$(FUNCS="$funcs" CRED="$cred" bash -c '
eval "$FUNCS"
DIM=""; RESET=""; YELLOW=""
say() { printf "%s\n" "$*"; }
warn() { printf "! %s\n" "$*"; }
printf "%s\nhttps://gateway.example.test\n" "$CRED" | ask_url "Address" "https://ai.example.com"
' 2>&1) || { fail_case "$name" "ask_url failed to run in isolation"; return; }
  printf '%s\n' "$out" >> "$TMP/doctor.out"
  if ! printf '%s\n' "$out" | grep -qF 'the token goes in the token prompt'; then
    fail_case "$name" "ask_url did not explain where the credential actually belongs"; return
  fi
  if printf '%s\n' "$out" | grep -qF 'hunter2@gateway'; then
    fail_case "$name" "ask_url accepted or echoed back the credential-bearing URL"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF 'using https://gateway.example.test'; then
    fail_case "$name" "ask_url did not go on to accept the corrected URL"; return
  fi

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# SECURITY.md's load-bearing promise: the connector "never changes a config it
# didn't create without showing you the exact change first". A file's PERMISSIONS
# are part of its configuration, so tightening a pre-existing ~/.hermes/.env to
# 0600 goes through the same announce-then-confirm gate as any other change to
# something the user owns.
#
# The DECLINE and FAILURE arms are graded as hard as the success arm on purpose.
# A gate that goes quiet when the user says no leaves a live gateway key readable
# by every account on the box and says nothing about it — a worse outcome than
# the silent chmod the gate replaced. So all three arms are driven end to end
# through the shipped secure_owned_file_mode, plus a wiring check that the caller
# has not gone back to chmodding the file directly.
run_owned_config_mode_change_case() {
  local name="owned-config-mode-change-is-announced" funcs body out
  local envf="$TMP/announce-hermes.env" mode

  # Wiring: configure_hermes must not chmod the user's .env itself. A bare
  # `chmod 600 "$envf"` there would satisfy every behavioural assertion below
  # while bypassing the gate entirely. Line continuations are joined first —
  # `run_step "…" \` / `  chmod 600 "$envf"` is ONE statement, and a
  # per-physical-line grep reads its second half as a bare chmod.
  body=$(extract_funcs configure_hermes)
  if [ -z "$body" ]; then
    fail_case "$name" "could not extract configure_hermes from the release artifact"; return
  fi
  printf '%s\n' "$body" > "$TMP/doctor.out"
  local chmod_lines ungated
  chmod_lines=$(printf '%s\n' "$body" | awk '
    {
      line = $0
      while (line ~ /\\$/) {
        sub(/\\$/, "", line)
        if ((getline nxt) <= 0) break
        sub(/^[[:space:]]+/, "", nxt)
        line = line " " nxt
      }
      print line
    }' | grep -F 'chmod')
  ungated=$(printf '%s\n' "$chmod_lines" | grep -F 'envf' | grep -vF 'run_step')
  if [ -n "$ungated" ]; then
    printf 'ungated chmod:\n%s\n' "$ungated" >> "$TMP/doctor.out"
    fail_case "$name" "configure_hermes chmods the user's .env directly, bypassing the announce gate"; return
  fi
  if ! printf '%s\n' "$body" | grep -qF 'secure_owned_file_mode'; then
    fail_case "$name" "configure_hermes no longer routes the .env mode through the announce gate"; return
  fi

  funcs=$(extract_funcs file_mode_is_open secure_owned_file_mode run_step mutate_guard confirm plan_add say ok warn note)
  if ! printf '%s\n' "$funcs" | grep -qF 'secure_owned_file_mode()'; then
    fail_case "$name" "could not extract secure_owned_file_mode from the release artifact"; return
  fi

  # Arm 1 — DECLINED (EOF: a redirected run has nobody to ask, and confirm says no).
  # The mode must be untouched, and the run must still name the exposure and the fix.
  printf 'API_SERVER_KEY=sentinel\n' > "$envf"
  chmod 644 "$envf"
  out=$(FUNCS="$funcs" ENVF="$envf" bash -c '
eval "$FUNCS"
DRY_RUN=false; REUSE_ONLY=false; PLAN=(); BOLD=""; RESET=""; DIM=""; YELLOW=""
: | secure_owned_file_mode "$ENVF" "your API server key"
printf "declined-rc=%d\n" "$?"
' 2>&1) || true
  printf -- '--- declined ---\n%s\n' "$out" >> "$TMP/doctor.out"
  mode=$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$envf")
  if [ "$mode" != "0o644" ]; then
    fail_case "$name" "the mode changed without a yes (now $mode)"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF "chmod 600 $envf"; then
    fail_case "$name" "a declined run did not print the exact command"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF 'STILL readable'; then
    fail_case "$name" "a declined run went quiet about the key still being readable"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF 'declined-rc=1'; then
    fail_case "$name" "a declined run did not report the still-open mode to its caller"; return
  fi

  # Arm 2 — CHMOD FAILS despite a yes. Same duty as a decline: the file is still
  # exposed, so the run must say so rather than assume the yes worked.
  out=$(FUNCS="$funcs" ENVF="$envf" bash -c '
eval "$FUNCS"
DRY_RUN=false; REUSE_ONLY=false; PLAN=(); BOLD=""; RESET=""; DIM=""; YELLOW=""
chmod() { return 1; }   # read-only fs / foreign owner, without needing either
printf "y\n" | secure_owned_file_mode "$ENVF" "your API server key"
printf "failed-rc=%d\n" "$?"
' 2>&1) || true
  printf -- '--- chmod failed ---\n%s\n' "$out" >> "$TMP/doctor.out"
  if ! printf '%s\n' "$out" | grep -qF 'STILL readable'; then
    fail_case "$name" "a failed chmod was reported as success"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF 'failed-rc=1'; then
    fail_case "$name" "a failed chmod did not report the still-open mode to its caller"; return
  fi

  # Arm 3 — ACCEPTED. The gate must not be a no-op in both directions.
  out=$(FUNCS="$funcs" ENVF="$envf" bash -c '
eval "$FUNCS"
DRY_RUN=false; REUSE_ONLY=false; PLAN=(); BOLD=""; RESET=""; DIM=""; YELLOW=""
printf "y\n" | secure_owned_file_mode "$ENVF" "your API server key"
printf "accepted-rc=%d\n" "$?"
' 2>&1) || true
  printf -- '--- accepted ---\n%s\n' "$out" >> "$TMP/doctor.out"
  mode=$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$envf")
  if [ "$mode" != "0o600" ]; then
    fail_case "$name" "an approved run did not apply the chmod (mode $mode)"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF 'accepted-rc=0'; then
    fail_case "$name" "a successful tighten did not report success to its caller"; return
  fi

  # Arm 4 — an already-private file asks nothing and says nothing.
  out=$(FUNCS="$funcs" ENVF="$envf" bash -c '
eval "$FUNCS"
DRY_RUN=false; REUSE_ONLY=false; PLAN=(); BOLD=""; RESET=""; DIM=""; YELLOW=""
: | secure_owned_file_mode "$ENVF" "your API server key"
printf "quiet-rc=%d\n" "$?"
' 2>&1) || true
  printf -- '--- already private ---\n%s\n' "$out" >> "$TMP/doctor.out"
  if [ "$(printf '%s\n' "$out" | grep -c .)" != "1" ]; then
    fail_case "$name" "an already-0600 file produced output instead of staying silent"; return
  fi

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# A dotenv value is the rest of the line. `API_SERVER_PORT=8642 # full-agent`
# is an ordinary way to write that file, and unvalidated it becomes a
# GW_LOCAL_PORT that word-splits inside the unquoted `tailscale serve …` command
# and silently defeats the `= "8645"` comparison that warns about the tool-less
# proxy port. Both gateway kinds resolve their port from a dotenv file; both
# must reduce a non-port to the documented default.
run_env_port_validation_case() {
  local name="env-ports-are-validated" funcs out home="$TMP/env-port-home"

  funcs=$(extract_funcs json_query json_get env_get show_qr_is_port openclaw_local_port hermes_api_server_port)
  if ! printf '%s\n' "$funcs" | grep -qF 'hermes_api_server_port()' \
     || ! printf '%s\n' "$funcs" | grep -qF 'openclaw_local_port()'; then
    fail_case "$name" "could not extract the port resolvers from the release artifact"; return
  fi

  rm -rf "$home"; mkdir -p "$home/.hermes" "$home/openclaw"
  printf 'API_SERVER_PORT=8642 # the full-agent API server\n' > "$home/.hermes/.env"
  printf 'OPENCLAW_GATEWAY_PORT=18789 # gateway\n' > "$home/openclaw/.env"
  out=$(HOME="$home" FUNCS="$funcs" bash -c '
eval "$FUNCS"
note() { :; }
printf "H<%s>\nO<%s>\n" "$(hermes_api_server_port)" "$(openclaw_local_port)"
' 2>/dev/null) || { fail_case "$name" "the port resolvers failed to run in isolation"; return; }
  printf '%s\n' "$out" > "$TMP/doctor.out"
  if ! printf '%s\n' "$out" | grep -qxF 'H<8642>' || ! printf '%s\n' "$out" | grep -qxF 'O<18789>'; then
    fail_case "$name" "a trailing dotenv comment leaked into the resolved port"; return
  fi

  # A real port still reads through unchanged, and an out-of-range one falls back.
  printf 'API_SERVER_PORT=8645\n' > "$home/.hermes/.env"
  printf 'OPENCLAW_GATEWAY_PORT=70000\n' > "$home/openclaw/.env"
  out=$(HOME="$home" FUNCS="$funcs" bash -c '
eval "$FUNCS"
note() { :; }
printf "H<%s>\nO<%s>\n" "$(hermes_api_server_port)" "$(openclaw_local_port)"
' 2>/dev/null) || { fail_case "$name" "the port resolvers failed on the second pass"; return; }
  printf '%s\n' "$out" >> "$TMP/doctor.out"
  if ! printf '%s\n' "$out" | grep -qxF 'H<8645>'; then
    fail_case "$name" "a valid API_SERVER_PORT was not read through verbatim"; return
  fi
  if ! printf '%s\n' "$out" | grep -qxF 'O<18789>'; then
    fail_case "$name" "an out-of-range OPENCLAW_GATEWAY_PORT was not replaced by the default"; return
  fi

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# The transport tier stages three probe files. They must live inside ONE 0700
# mktemp directory, not as sibling names built by string concatenation off a
# single mktemp file: mktemp publishes its random suffix the moment it creates
# the file, /tmp's sticky bit stops deletion but not the creation of
# "<that name>.u", and the writes are plain redirects and curl -D.
run_check_tempfile_isolation_case() {
  local name="check-probe-files-are-not-siblings" body
  body=$(extract_funcs doctor_files_transport)
  if [ -z "$body" ]; then
    fail_case "$name" "could not extract doctor_files_transport from the release artifact"; return
  fi
  printf '%s\n' "$body" > "$TMP/doctor.out"
  if printf '%s\n' "$body" | grep -qE '\$\{?tmp\}?\.[a-z]'; then
    fail_case "$name" "a probe path is still built by concatenating onto the mktemp name"; return
  fi
  if ! printf '%s\n' "$body" | grep -qF 'mktemp -d'; then
    fail_case "$name" "the transport tier no longer stages its probes in a mktemp -d directory"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# $STATE_DIR holds fileserver-*.cred/.env and profile-*.json, so the artifact
# creates it 0700 — otherwise any other account on the box can list which
# gateways this user has paired. `mkdir -p` is a no-op on an EXISTING directory,
# mode included, so `umask 077` around it only ever secures a first run: a
# $STATE_DIR left at 0755 by an earlier version, a different umask, or the
# user's own mkdir keeps that mode for good. The rule is therefore about the
# artifact, not about one writer — every creation goes through ensure_state_dir,
# and that helper is graded on both arms, because "silently correct on a fresh
# box, silently exposed on an upgraded one" is exactly the shape this misses.
run_state_dir_mode_case() {
  local name="state-dir-is-0700-or-reported" funcs out mode dir
  local artifact_mkdirs

  # Wiring: no writer may mkdir $STATE_DIR on its own. A bare
  # `( umask 077; mkdir -p "$STATE_DIR" )` at a call site satisfies every
  # behavioural assertion below while skipping the exposure report entirely.
  artifact_mkdirs=$(grep -n 'mkdir -p "\$STATE_DIR"' "$SCRIPT")
  printf '%s\n' "$artifact_mkdirs" > "$TMP/doctor.out"
  if [ "$(printf '%s\n' "$artifact_mkdirs" | grep -c .)" != "1" ]; then
    fail_case "$name" "\$STATE_DIR is created outside ensure_state_dir"; return
  fi
  funcs=$(extract_funcs ensure_state_dir file_mode_is_open warn)
  if ! printf '%s\n' "$funcs" | grep -qF 'ensure_state_dir()'; then
    fail_case "$name" "could not extract ensure_state_dir from the release artifact"; return
  fi
  # …and the sole mkdir must be the one inside ensure_state_dir.
  if ! printf '%s\n' "$funcs" | grep -qF 'mkdir -p "$STATE_DIR"'; then
    fail_case "$name" "the one \$STATE_DIR mkdir is not the one inside ensure_state_dir"; return
  fi

  # Arm 1 — a FRESH state dir is created 0700, and says nothing.
  dir="$TMP/state-fresh/conduck"
  rm -rf "$TMP/state-fresh"
  out=$(FUNCS="$funcs" SD="$dir" bash -c '
eval "$FUNCS"
STATE_DIR="$SD"; STATE_DIR_EXPOSURE_REPORTED=false; YELLOW=""; RESET=""
ensure_state_dir
printf "fresh-rc=%d\n" "$?"
' 2>&1) || true
  printf -- '--- fresh ---\n%s\n' "$out" >> "$TMP/doctor.out"
  mode=$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$dir" 2>/dev/null)
  if [ "$mode" != "0o700" ]; then
    fail_case "$name" "a freshly created \$STATE_DIR is $mode, not 0o700"; return
  fi
  if [ "$(printf '%s\n' "$out" | grep -c .)" != "1" ]; then
    fail_case "$name" "creating a fresh \$STATE_DIR produced output instead of staying silent"; return
  fi

  # Arm 2 — a PRE-EXISTING 0755 dir keeps its mode (no silent chmod of something
  # we may not have created) and the run names both the exposure and the fix.
  dir="$TMP/state-open/conduck"
  rm -rf "$TMP/state-open"; mkdir -p "$dir"; chmod 755 "$dir"
  out=$(FUNCS="$funcs" SD="$dir" bash -c '
eval "$FUNCS"
STATE_DIR="$SD"; STATE_DIR_EXPOSURE_REPORTED=false; YELLOW=""; RESET=""
ensure_state_dir
printf "open-rc=%d\n" "$?"
ensure_state_dir
printf "second-rc=%d\n" "$?"
' 2>&1) || true
  printf -- '--- pre-existing 0755 ---\n%s\n' "$out" >> "$TMP/doctor.out"
  mode=$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$dir")
  if [ "$mode" != "0o755" ]; then
    fail_case "$name" "an existing \$STATE_DIR was silently re-chmodded to $mode"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF "chmod 700 $dir"; then
    fail_case "$name" "an exposed \$STATE_DIR did not print the exact fix"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF 'can be listed by other accounts'; then
    fail_case "$name" "an exposed \$STATE_DIR went quiet about who can read the listing"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF 'open-rc=0' || ! printf '%s\n' "$out" | grep -qF 'second-rc=0'; then
    fail_case "$name" "reporting the exposure turned into a failure for the caller"; return
  fi
  # Said ONCE per run: three writers reach this helper in a single setup, and a
  # warning repeated at each of them is noise the user learns to skip.
  if [ "$(printf '%s\n' "$out" | grep -cF "chmod 700 $dir")" != "1" ]; then
    fail_case "$name" "the exposure warning repeats on every call instead of once per run"; return
  fi

  # Arm 3 — an uncreatable state dir is a clean 1, so write_profile can warn
  # about the profile rather than looking like it succeeded.
  dir="$TMP/state-blocked/conduck"
  rm -rf "$TMP/state-blocked"; : > "$TMP/state-blocked"
  out=$(FUNCS="$funcs" SD="$dir" bash -c '
eval "$FUNCS"
STATE_DIR="$SD"; STATE_DIR_EXPOSURE_REPORTED=false; YELLOW=""; RESET=""
ensure_state_dir
printf "blocked-rc=%d\n" "$?"
' 2>&1) || true
  printf -- '--- uncreatable ---\n%s\n' "$out" >> "$TMP/doctor.out"
  rm -f "$TMP/state-blocked"
  if ! printf '%s\n' "$out" | grep -qF 'blocked-rc=1'; then
    fail_case "$name" "a \$STATE_DIR that could not be created did not report failure"; return
  fi

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

run_check_continue_eof_case() {
  local name="check-pass-continuation-eof" rc=0
  start_fixture good || { fail_case "$name" "fixture failed to start"; stop_fixture; return; }
  local input
  input=$'2\nhttp://127.0.0.1:'"$PORT"$'\n\004'
  PTY_ENV=(CONDUCK_TOKEN="$TOKEN")
  pty_run 30 "$input" > "$TMP/doctor.out" 2>&1 || rc=$?
  stop_fixture
  if [ "$rc" != "0" ] ||
     ! grep -qF 'Would you like to continue with setup and pairing?' "$TMP/doctor.out" ||
     ! grep -qF 'No setup changes were made.' "$TMP/doctor.out"; then
    fail_case "$name" "EOF at the optional continuation did not safely mean no"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# The CI gate itself, in a REAL PTY: interactive_terminal() must still refuse to
# ask when $CI is set, even though stdin/stdout are terminals. Automation that
# happens to run under a TTY (GitHub Actions, a build container) must get its
# summary and exit, never a blocked prompt. This is the ONE case that keeps CI
# set — every other PTY case strips it via pty_run.
run_ci_gate_case() {
  local name="ci-gate-no-handoff" rc=0
  start_fixture good || { fail_case "$name" "fixture failed to start"; stop_fixture; return; }
  # No input at all: a question here would hang until the PTY timeout.
  PTY_ENV=(CI=true CONDUCK_TOKEN="$TOKEN")
  pty_run 60 '' --check-server "http://127.0.0.1:$PORT" > "$TMP/doctor.out" 2>&1 || rc=$?
  stop_fixture
  if grep -qF 'PTY TIMEOUT' "$TMP/doctor.out"; then
    fail_case "$name" "the check blocked on a question despite CI being set"; return
  fi
  if [ "$rc" != "0" ]; then
    fail_case "$name" "exit $rc, expected 0 (a PASS under CI)"; return
  fi
  if grep -qF 'Would you like to continue with setup and pairing?' "$TMP/doctor.out"; then
    fail_case "$name" "CI run offered the interactive setup handoff"; return
  fi
  if ! grep -qF 'The last line is always a CONDUCK_CHECK_SERVER machine summary' "$TMP/doctor.out"; then
    fail_case "$name" "CI run took the interactive preamble branch"; return
  fi
  if [ "$(grep -c '^CONDUCK_CHECK_SERVER schema=' "$TMP/doctor.out")" != "1" ]; then
    fail_case "$name" "expected exactly 1 CONDUCK_CHECK_SERVER summary line"; return
  fi
  # tr -d '\r': a PTY turns every \n into \r\n, which would break the $ anchor.
  local summary; summary=$(tail -n 1 "$TMP/doctor.out" | tr -d '\r')
  if ! printf '%s\n' "$summary" | grep -Eq "$SERVER_SUMMARY_RE"; then
    fail_case "$name" "last line isn't a valid CONDUCK_CHECK_SERVER schema=2 summary: $summary"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# An address that fails verification must not end the run. By the time it fails the
# operator has already entered the token — in the field a ~300-character JWT — and
# making them paste it again to try the neighbouring address (a sub-path, a
# different port) is the tool wasting their time. The check re-asks for the ADDRESS
# and keeps the credential. Two regressions this case exists to catch: the token
# prompt appearing twice, and a first attempt's red surviving into the summary of a
# second attempt that passed.
run_server_url_reask_case() {
  local name="server-url-reask-keeps-token" rc=0 dead input prompts summary frag
  start_fixture good || { fail_case "$name" "fixture failed to start"; stop_fixture; return; }
  # A port nothing listens on — bound, read back, released — so the first attempt
  # fails on curl's connection-refused rather than on a timeout.
  dead=$(python3 -c 'import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()') \
    || { fail_case "$name" "could not reserve an unused port"; stop_fixture; return; }
  # address that fails · token · the working address · EOT (the PTY stays open, so
  # the handoff question needs a real EOF to mean "no").
  input="http://127.0.0.1:$dead"$'\n'"$TOKEN"$'\n'"http://127.0.0.1:$PORT"$'\n\004'
  PTY_ENV=()
  pty_run 90 "$input" --check-server > "$TMP/doctor.out" 2>&1 || rc=$?
  stop_fixture
  if grep -qF 'PTY TIMEOUT' "$TMP/doctor.out"; then
    fail_case "$name" "the re-ask blocked instead of accepting a second address"; return
  fi
  if [ "$rc" != "0" ]; then
    fail_case "$name" "the retried address did not finish green (exit $rc)"; return
  fi
  prompts=$(grep -c 'Bearer token the server expects' "$TMP/doctor.out")
  if [ "$prompts" != "1" ]; then
    fail_case "$name" "the token was asked for $prompts times, expected 1"; return
  fi
  if ! grep -qF 'The token you already entered is kept' "$TMP/doctor.out"; then
    fail_case "$name" "the re-ask never said the token is kept"; return
  fi
  if [ "$(grep -c '^CONDUCK_CHECK_SERVER schema=' "$TMP/doctor.out")" != "1" ]; then
    fail_case "$name" "expected exactly 1 CONDUCK_CHECK_SERVER summary line"; return
  fi
  # Grepped, not tail -1: on an INTERACTIVE pass the summary deliberately prints
  # BEFORE the optional setup handoff, so the last line is that question.
  # tr -d '\r': a PTY turns every \n into \r\n, which would break the $ anchor.
  summary=$(grep '^CONDUCK_CHECK_SERVER schema=' "$TMP/doctor.out" | tr -d '\r')
  if ! printf '%s\n' "$summary" | grep -Eq "$SERVER_SUMMARY_RE"; then
    fail_case "$name" "not a valid CONDUCK_CHECK_SERVER schema=2 summary: $summary"; return
  fi
  # One `case` per fragment, never one glob chaining them: adjacent fields share
  # the space between them, so a chained pattern consumes it once and can never
  # match the next literal.
  for frag in wire=PASS models=PASS failed=0 exit=0; do
    case " $summary " in *" $frag "*) ;; *)
      fail_case "$name" "the failed first address bled into the retried summary ('$frag' missing): $summary"; return ;;
    esac
  done
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# The HTML diagnosis has to name the cause that actually explains it in the field:
# the OpenAI API living under a sub-path of the address given. Open WebUI is the
# common one — its site root answers GET /v1/models with app HTML under HTTP 200.
run_server_html_subpath_hint_case() {
  local name="server-html-names-the-subpath" rc=0
  start_fixture models-html || { fail_case "$name" "fixture failed to start"; stop_fixture; return; }
  TERM=dumb CONDUCK_TOKEN="$TOKEN" bash "$SCRIPT" --check-server "http://127.0.0.1:$PORT" \
    > "$TMP/doctor.out" 2>&1 < /dev/null || rc=$?
  stop_fixture
  if [ "$rc" != "1" ]; then
    fail_case "$name" "exit $rc, expected 1"; return
  fi
  if ! grep -qF 'SUB-PATH' "$TMP/doctor.out"; then
    fail_case "$name" "the HTML diagnosis never names a sub-path API"; return
  fi
  if ! grep -qF '<url>/api' "$TMP/doctor.out"; then
    fail_case "$name" "the HTML diagnosis gives no concrete sub-path to try"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# Colour is gated on `[ -t 1 ]`, NOT on $TERM: a redirected or piped run must be
# ANSI-free even under a colour-capable TERM, or every [CHECK_ID] parser reading
# a log file gets escape soup. Asserted on the real check path, where those
# parsers live. (The rest of the suite runs TERM=dumb, which would mask a
# regression here — tput emits nothing for dumb terminals either way.)
run_no_ansi_case() {
  local name="no-ansi-when-redirected" rc=0
  start_fixture good || { fail_case "$name" "fixture failed to start"; stop_fixture; return; }
  TERM=xterm-256color CONDUCK_TOKEN="$TOKEN" bash "$SCRIPT" --check-server "http://127.0.0.1:$PORT" \
    > "$TMP/doctor.out" 2>&1 < /dev/null || rc=$?
  stop_fixture
  if [ "$rc" != "0" ]; then
    fail_case "$name" "exit $rc, expected 0"; return
  fi
  if grep -qF "$ESC" "$TMP/doctor.out"; then
    fail_case "$name" "a redirected run under TERM=xterm-256color emitted ANSI escapes"; return
  fi
  if ! grep -qF '✓ [SERVER_MODELS]' "$TMP/doctor.out"; then
    fail_case "$name" "no check verdict lines to judge — the run produced nothing"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# --- the rejected-body check only grades an actual rejection -----------------
# AUTH_CHAT_REJECT_BODY asks what a rejection did with the body it rejected, so
# it must not run when nothing was rejected. Two ways that happens, both proven
# here rather than assumed: a chat route that ACCEPTS a wrong token (there was no
# rejection, and the failing AUTH_CHAT_WRONG line already carries the diagnosis —
# a second red would double-bill one fault), and a keyless run (no auth at all).
# A skip is invisible in the failed-ID set, which is exactly why it needs its own
# case: a check that quietly started PASSING here would look identical from the
# outside. So this asserts the id is absent from the whole transcript, and that
# the run it rode on still produced the failure it was supposed to.
run_reject_body_gate_case() { # run_reject_body_gate_case <wrong-token-ok|keyless>
  local kind="$1" name="reject-body-not-graded-$1" mode expect token rc=0
  if [ "$kind" = "keyless" ]; then
    mode="open"; expect="AUTH_NOT_ENFORCED"; token=""
  else
    mode="auth-chat-any-token"; expect="AUTH_CHAT_WRONG"; token="$TOKEN"
  fi
  start_fixture "$mode" || { fail_case "$name" "fixture failed to start"; stop_fixture; return; }
  TERM=dumb CONDUCK_TOKEN="$token" bash "$SCRIPT" --check-adapter "http://127.0.0.1:$PORT" \
    > "$TMP/doctor.out" 2>&1 < /dev/null || rc=$?
  stop_fixture
  if [ "$rc" != "1" ]; then
    fail_case "$name" "exit $rc, expected 1"; return
  fi
  if ! grep -qF "✗ [$expect]" "$TMP/doctor.out"; then
    fail_case "$name" "the run produced no $expect failure, so it proves nothing about the gate"; return
  fi
  if grep -qF '[AUTH_CHAT_REJECT_BODY]' "$TMP/doctor.out"; then
    fail_case "$name" "the rejected-body check ran with no rejection to grade"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# --- the rejected-body verdict matrix ----------------------------------------
# The fixture can produce the three outcomes a real adapter produces — the body
# drained, the connection closed, neither — and those are the rows the
# reject-no-drain/reject-close cases cover. It cannot produce the outcomes this
# check exists to be CAREFUL about: a throttled burst, a probe that never
# completed, a result too mangled to read. Those decide whether a CORRECT adapter
# gets wrongly reddened, which is the failure mode that costs the most, so they
# are driven here against the SHIPPED functions with only the probe stubbed.
# "401 400" is the load-bearing row: two fields, not three, and a loose reader
# slices it into 401/400/400 and reports a desync that nothing observed.
# The verdict is graded as <PASS-or-FAIL>:<which-branch>, not just red/green: two
# different readings of the same evidence can both be a FAIL while telling the
# builder to go looking in two different places, and "it failed" would call that
# a match. The tag comes from a phrase unique to each branch's verdict line.
run_reject_body_matrix_isolated() { # <function-source> <pair-output>
  FUNCS="$1" PAIR="$2" bash -c '
eval "$FUNCS"
DOCTOR_CONTRACT_REV="1.4"
tag() { case "$*" in
  *"ONE reused connection"*)   printf "reused" ;;
  *"down one connection"*)     printf "unstable" ;;
  *"(busy)"*)                  printf "busy" ;;
  *"SAME connection"*)         printf "same" ;;
  *"closed the connection"*)   printf "closed" ;;
  *"never completed"*)         printf "none" ;;
  *)                           printf "unrecognised" ;;
esac; }
d_ok()  { shift; printf "OK:%s\n" "$(tag "$@")"; }
d_bad() { shift; printf "BAD:%s\n" "$(tag "$@")"; }
d_say() { :; }
doctor_desync_pair() { printf "%s" "$PAIR"; }
doctor_reject_body_check https://gw.example.test/v1/chat/completions
'
}

run_reject_body_matrix_case() {
  local name="reject-body-verdict-matrix" funcs pair want got
  funcs=$(extract_funcs doctor_parse_level_status doctor_busy_status \
                        doctor_desync_parse doctor_reject_body_check)
  if [ -z "$funcs" ] || ! printf '%s\n' "$funcs" | grep -qF 'doctor_reject_body_check()'; then
    fail_case "$name" "could not extract the rejected-body check from the release artifact"; return
  fi
  : > "$TMP/doctor.out"
  while IFS='|' read -r pair want; do
    [ -n "$want" ] || continue
    got=$(run_reject_body_matrix_isolated "$funcs" "$pair" 2>&1)
    printf -- '--- pair "%s" want %s ---\n%s\n' "$pair" "$want" "$got" >> "$TMP/doctor.out"
    if [ "$got" != "$want" ]; then
      fail_case "$name" "pair '$pair' graded '$got', expected '$want'"; return
    fi
  done <<EOF
401 401 0|OK:same
401 401 2|OK:closed
401 400 0|BAD:reused
401 414 0|BAD:reused
401 431 0|BAD:reused
401 501 0|BAD:reused
401 505 0|BAD:reused
429 400 0|BAD:reused
503 431 0|BAD:reused
401 429 0|OK:busy
401 503 0|OK:busy
429 429 0|OK:busy
401 400 1|BAD:unstable
401 403 0|BAD:unstable
401 500 0|BAD:unstable
400 400 0|BAD:unstable
200 200 0|BAD:unstable
|OK:none
000 000 0|OK:none
401 000 0|OK:none
401 400|OK:none
401 400 0 7|OK:none
401 400 x|OK:none
EOF
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# --- the fixture's own rejection hygiene -------------------------------------
# Proven directly, not through the adapter check, because the check only ever
# exercises ONE rejection shape (auth) and only two requests deep. The fixture
# also rejects unknown paths, wrong methods, and — in require-accept mode — a
# missing Accept header, each of them before the body has been read; and one
# handler INSTANCE serves a whole keep-alive connection, so a per-request flag
# left unreset would drain the first request and skip every one after it. So this
# drives a single connection through all of it and ends on a real authenticated
# turn: the ordinary, perfectly-valid request whose corruption is the entire
# point of the rule. num_connects must be 1 only on the opening transfer — any
# later 1 means the connection was dropped rather than kept clean.
run_fixture_rejection_reuse_case() {
  local name="fixture-rejections-keep-the-connection-usable" body got want
  body='{"messages":[{"role":"user","content":"Reply with exactly: pong"}],"stream":false}'
  start_fixture good || { fail_case "$name" "fixture failed to start"; stop_fixture; return; }
  got=$(curl -q -sS --http1.1 --max-time 15 --noproxy '*' \
      -H 'Expect:' -H 'Content-Type: application/json' -H 'Authorization: Bearer wrong-token' \
      -d "$body" -o /dev/null -w '%{http_code}:%{num_connects} ' \
      "http://127.0.0.1:$PORT/v1/chat/completions" \
    --next -sS --http1.1 --max-time 15 --noproxy '*' \
      -H 'Expect:' -H 'Content-Type: application/json' -H 'Authorization: Bearer wrong-token' \
      -d "$body" -o /dev/null -w '%{http_code}:%{num_connects} ' \
      "http://127.0.0.1:$PORT/v1/chat/completions" \
    --next -sS --http1.1 --max-time 15 --noproxy '*' \
      -H 'Expect:' -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
      -d "$body" -o /dev/null -w '%{http_code}:%{num_connects} ' \
      "http://127.0.0.1:$PORT/v1/no-such-route" \
    --next -sS --http1.1 --max-time 15 --noproxy '*' -X PUT \
      -H 'Expect:' -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
      -d "$body" -o /dev/null -w '%{http_code}:%{num_connects} ' \
      "http://127.0.0.1:$PORT/v1/chat/completions" \
    --next -sS --http1.1 --max-time 15 --noproxy '*' \
      -H 'Expect:' -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
      -d "$body" -o /dev/null -w '%{http_code}:%{num_connects}' \
      "http://127.0.0.1:$PORT/v1/chat/completions" 2>&1)
  stop_fixture
  want='401:1 401:0 404:0 405:0 200:0'
  printf -- '--- good: 401 401 404 405 200 down one connection ---\n%s\n' "$got" > "$TMP/doctor.out"
  if [ "$got" != "$want" ]; then
    fail_case "$name" "one connection through four rejections gave '$got', expected '$want'"; return
  fi
  # The Accept rejection lives in its own mode. Same rule: 406 first, then a real
  # turn on the SAME connection has to be answered as if nothing happened.
  start_fixture require-accept || { fail_case "$name" "require-accept fixture failed to start"; stop_fixture; return; }
  got=$(curl -q -sS --http1.1 --max-time 15 --noproxy '*' \
      -H 'Expect:' -H 'Accept: text/plain' -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $TOKEN" \
      -d "$body" -o /dev/null -w '%{http_code}:%{num_connects} ' \
      "http://127.0.0.1:$PORT/v1/chat/completions" \
    --next -sS --http1.1 --max-time 15 --noproxy '*' \
      -H 'Expect:' -H 'Accept: application/json' -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $TOKEN" \
      -d "$body" -o /dev/null -w '%{http_code}:%{num_connects}' \
      "http://127.0.0.1:$PORT/v1/chat/completions" 2>&1)
  stop_fixture
  want='406:1 200:0'
  printf -- '--- require-accept: 406 then a real turn ---\n%s\n' "$got" >> "$TMP/doctor.out"
  if [ "$got" != "$want" ]; then
    fail_case "$name" "406 then a real turn gave '$got', expected '$want'"; return
  fi
  # A SUCCESSFUL answer to a request that carried an unexpected body desyncs the
  # connection exactly the same way a rejection does — nothing about the rule is
  # specific to errors. Nobody sends a body on a GET, which is precisely why this
  # would rot unnoticed. A PATCH gets http.server's own 501, which closes; that
  # is the lawful other half and is asserted here rather than assumed.
  start_fixture good || { fail_case "$name" "second good fixture failed to start"; stop_fixture; return; }
  got=$(curl -q -sS --http1.1 --max-time 15 --noproxy '*' -X GET \
      -H 'Expect:' -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
      -d "$body" -o /dev/null -w '%{http_code}:%{num_connects} ' \
      "http://127.0.0.1:$PORT/v1/models" \
    --next -sS --http1.1 --max-time 15 --noproxy '*' -X PATCH \
      -H 'Expect:' -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
      -d "$body" -o /dev/null -w '%{http_code}:%{num_connects} ' \
      "http://127.0.0.1:$PORT/v1/chat/completions" \
    --next -sS --http1.1 --max-time 15 --noproxy '*' \
      -H 'Expect:' -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
      -d "$body" -o /dev/null -w '%{http_code}:%{num_connects}' \
      "http://127.0.0.1:$PORT/v1/chat/completions" 2>&1)
  stop_fixture
  want='200:1 501:0 200:1'
  printf -- '--- GET with a body, PATCH, then a real turn ---\n%s\n' "$got" >> "$TMP/doctor.out"
  if [ "$got" != "$want" ]; then
    fail_case "$name" "a bodied GET then PATCH then a real turn gave '$got', expected '$want'"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# --- fail-closed auth --------------------------------------------------------
# CONDUCK_TOKEN unset + no answer possible (EOF) must DIE, not silently grade the
# target keyless: inferring no-auth from a MISSING answer reports AUTH_* failures
# the operator never chose (adapter lane) or a keyless verdict for a server that
# actually wants a token. The deliberate declaration is CONDUCK_TOKEN= (empty),
# covered by the keyless rows in both case tables.
run_auth_eof_case() { # run_auth_eof_case <server|adapter>
  local kind="$1" name="auth-eof-dies-$1" flag prefix re frag rc=0
  if [ "$kind" = "server" ]; then
    flag="--check-server"; prefix="CONDUCK_CHECK_SERVER"; re="$SERVER_SUMMARY_RE"; frag="wire=NOT_RUN"
  else
    flag="--check-adapter"; prefix="CONDUCK_CHECK_ADAPTER"; re="$SUMMARY_RE"; frag="core=NOT_RUN"
  fi
  start_fixture good || { fail_case "$name" "fixture failed to start"; stop_fixture; return; }
  env -u CONDUCK_TOKEN TERM=dumb bash "$SCRIPT" $flag "http://127.0.0.1:$PORT" \
    > "$TMP/doctor.out" 2>&1 < /dev/null || rc=$?
  stop_fixture
  if [ "$rc" != "1" ]; then
    fail_case "$name" "missing runtime token exited $rc, expected 1"; return
  fi
  if ! grep -qF 'No token given and no answer possible' "$TMP/doctor.out"; then
    fail_case "$name" "died for some other reason than the missing token answer"; return
  fi
  if ! grep -qF 'CONDUCK_TOKEN= (empty) to declare keyless deliberately' "$TMP/doctor.out"; then
    fail_case "$name" "the fail-closed error doesn't name the explicit-keyless escape hatch"; return
  fi
  if grep -qF 'Keyless' "$TMP/doctor.out"; then
    fail_case "$name" "a missing answer was reported as keyless"; return
  fi
  assert_machine_output "$name" "$prefix" || return
  local summary; summary=$(tail -n 1 "$TMP/doctor.out")
  if ! printf '%s\n' "$summary" | grep -Eq "$re"; then
    fail_case "$name" "last line isn't a valid $prefix summary: $summary"; return
  fi
  case " $summary " in *" $frag "*) ;; *)
    fail_case "$name" "summary lacks '$frag' — the check reported work it never did: $summary"; return ;;
  esac
  case " $summary " in *" exit=1 "*) ;; *)
    fail_case "$name" "runtime failure summary did not preserve exit=1: $summary"; return ;;
  esac
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# A check's documented machine line must survive failures before its first
# network request. Use a deliberately tiny PATH that contains uname and exactly
# one of the two required runtime tools, so preflight proves the other is
# missing. URL validation must remain pure shell or this would be misclassified
# as exit-2 command misuse before the summary trap is armed.
run_preflight_missing_tool_case() { # <server|adapter> <python3|curl>
  local kind="$1" missing="$2" name="preflight-missing-$2-$1"
  local flag prefix re frag rc=0 fake="$TMP/path-$1-$2"
  local bash_bin uname_bin python_bin curl_bin summary
  bash_bin=$(command -v bash)
  uname_bin=$(command -v uname)
  python_bin=$(command -v python3)
  curl_bin=$(command -v curl)
  mkdir -p "$fake"
  ln -s "$uname_bin" "$fake/uname"
  case "$missing" in
    python3) ln -s "$curl_bin" "$fake/curl" ;;
    curl)    ln -s "$python_bin" "$fake/python3" ;;
    *) fail_case "$name" "test asked for unknown missing tool '$missing'"; return ;;
  esac
  if [ "$kind" = "server" ]; then
    flag="--check-server"; prefix="CONDUCK_CHECK_SERVER"
    re="$SERVER_SUMMARY_RE"; frag="wire=NOT_RUN"
  else
    flag="--check-adapter"; prefix="CONDUCK_CHECK_ADAPTER"
    re="$SUMMARY_RE"; frag="core=NOT_RUN"
  fi

  PATH="$fake" TERM=dumb CONDUCK_TOKEN="$TOKEN" \
    "$bash_bin" "$SCRIPT" "$flag" "https://preflight.example.test" \
    > "$TMP/doctor.out" 2>&1 < /dev/null || rc=$?
  if [ "$rc" != "1" ]; then
    fail_case "$name" "missing runtime dependency exited $rc, expected 1"; return
  fi
  if ! grep -qF "Missing required tool(s): $missing" "$TMP/doctor.out" ||
     grep -qF 'Usage error:' "$TMP/doctor.out"; then
    fail_case "$name" "missing $missing was not reported as a runtime preflight failure"; return
  fi
  assert_machine_output "$name" "$prefix" || return
  summary=$(tail -n 1 "$TMP/doctor.out")
  if ! printf '%s\n' "$summary" | grep -Eq "$re"; then
    fail_case "$name" "last line isn't a valid $prefix summary: $summary"; return
  fi
  case " $summary " in *" $frag "*) ;; *)
    fail_case "$name" "preflight summary lacks '$frag': $summary"; return ;;
  esac
  case " $summary " in *" exit=1 "*) ;; *)
    fail_case "$name" "preflight summary lacks exit=1: $summary"; return ;;
  esac

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# --- --generic, the functional legacy alias ----------------------------------
# App Store builds still emit `--generic` verbatim and always fetch the newest
# script, so it must WORK, not merely diagnose. It means exactly one thing:
# custom-server setup with detection SKIPPED. The fake HOME carries an OpenClaw
# config precisely because an unrelated install must NOT become the default for
# someone who asked for a custom server. EOF at the port question is the
# deliberate clean stop (nothing is configured, no network request is made).
run_generic_alias_case() { # run_generic_alias_case <plain|dry-run>
  local variant="$1" name="generic-legacy-alias" rc=0 home="$TMP/generic-home"
  local -a extra=()
  if [ "$variant" = "dry-run" ]; then name="generic-legacy-alias-dry-run"; extra=(--dry-run); fi
  mkdir -p "$home/.openclaw"
  printf '{}\n' > "$home/.openclaw/openclaw.json"
  env -u XDG_CONFIG_HOME HOME="$home" TERM=dumb bash "$SCRIPT" --generic ${extra[@]+"${extra[@]}"} \
    > "$TMP/doctor.out" 2>&1 < /dev/null || rc=$?
  if [ "$rc" = "0" ]; then
    fail_case "$name" "expected the EOF-driven run to stop for missing input"; return
  fi
  if ! grep -qF -- '--generic is the older name for custom-server setup.' "$TMP/doctor.out"; then
    fail_case "$name" "the migration note is missing"; return
  fi
  if ! grep -qF 'Configuring a server you set up yourself (skipping gateway detection).' "$TMP/doctor.out"; then
    fail_case "$name" "--generic did not skip gateway detection"; return
  fi
  if grep -qF 'Which gateway should Conduck talk to?' "$TMP/doctor.out" ||
     grep -qF 'We found these on this machine' "$TMP/doctor.out"; then
    fail_case "$name" "a gateway picker was shown despite the custom-server hint"; return
  fi
  if grep -qF 'Step 2 — OpenClaw' "$TMP/doctor.out"; then
    fail_case "$name" "an unrelated OpenClaw install hijacked custom-server setup"; return
  fi
  if ! grep -qF 'Step 2 — your OpenAI-compatible server' "$TMP/doctor.out" ||
     ! grep -qF 'Need the local port (or an https URL).' "$TMP/doctor.out"; then
    fail_case "$name" "--generic did not enter custom-server setup"; return
  fi
  if [ "$variant" = "dry-run" ] &&
     ! grep -qF '(dry-run: nothing will be changed)' "$TMP/doctor.out"; then
    fail_case "$name" "--generic --dry-run lost the dry-run mode"; return
  fi
  # Working, but NOT documented surface: it exists only for App Store builds that
  # already emit it. Advertising it would grow a second spelling for --setup.
  if [ "$variant" = "plain" ]; then
    TERM=dumb bash "$SCRIPT" --help </dev/null > "$TMP/doctor.out" 2>&1
    if grep -qF -- '--generic' "$TMP/doctor.out"; then
      fail_case "$name" "--help advertises the legacy --generic alias"; return
    fi
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

run_checked_path_prefix_case() {
  local name="checked-local-path-survives-exposure" funcs rc=0
  funcs=$(sed -n '/^apply_checked_path_prefix()/,/^}/p' "$SCRIPT")
  TERM=dumb bash -c "$funcs
note() { :; }
GW_URL='https://gateway.example.com'
CHECKED_PATH_PREFIX='/api/agent'
apply_checked_path_prefix
[ \"\$GW_URL\" = 'https://gateway.example.com/api/agent' ] || exit 1
apply_checked_path_prefix
[ \"\$GW_URL\" = 'https://gateway.example.com/api/agent' ]" \
    > "$TMP/doctor.out" 2>&1 || rc=$?
  if [ "$rc" != "0" ]; then
    fail_case "$name" "checked path prefix was lost or appended twice"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

run_shared_app_evaluator_wiring_case() {
  local name="shared-app-evaluator" verify
  verify=$(sed -n '/^verify_all()/,/^}/p' "$SCRIPT")
  if ! printf '%s\n' "$verify" | grep -qF 'if app_chat_eval "$body"; then'; then
    fail_case "$name" "normal setup verification does not call app_chat_eval"; return
  fi
  if [ "$(grep -c '^app_chat_eval()' "$SCRIPT")" != "1" ]; then
    fail_case "$name" "app_chat_eval must have exactly one implementation"; return
  fi
  if grep -q 'compat_chat_eval' "$SCRIPT"; then
    fail_case "$name" "obsolete server-only evaluator still exists"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

ONLY="${*:-}"
printf 'connector regression suite — fixture on 127.0.0.1 (OS-assigned port), per-run token\n'
while IFS= read -r row; do
  [ -n "$row" ] || continue
  case "$row" in \#*) continue ;; esac
  if [ -n "$ONLY" ]; then
    case " $ONLY " in *" ${row%%|*} "*) ;; *) continue ;; esac
  fi
  run_case "$row"
done <<EOF
$CASES
EOF

while IFS= read -r row; do
  [ -n "$row" ] || continue
  case "$row" in \#*) continue ;; esac
  if [ -n "$ONLY" ]; then
    case " $ONLY " in *" ${row%%|*} "*) ;; *) continue ;; esac
  fi
  run_file_case "$row"
done <<EOF
$FILE_CASES
EOF

if [ -z "$ONLY" ] || case " $ONLY " in *" signal-cleanup "*) true ;; *) false ;; esac; then
  run_signal_cleanup
fi

while IFS= read -r row; do
  [ -n "$row" ] || continue
  case "$row" in \#*) continue ;; esac
  if [ -n "$ONLY" ]; then
    case " $ONLY " in *" ${row%%|*} "*) ;; *) continue ;; esac
  fi
  run_server_case "$row"
done <<EOF
$SERVER_CASES
EOF

while IFS= read -r row; do
  [ -n "$row" ] || continue
  case "$row" in \#*) continue ;; esac
  if [ -n "$ONLY" ]; then
    case " $ONLY " in *" ${row%%|*} "*) ;; *) continue ;; esac
  fi
  run_cli_rejection_case "$row"
done <<EOF
$CLI_REJECTION_CASES
EOF

if [ -z "$ONLY" ] || case " $ONLY " in *" direct-setup "*) true ;; *) false ;; esac; then
  run_direct_setup_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" menu-noninteractive-eof "*) true ;; *) false ;; esac; then
  run_noarg_noninteractive_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" menu-q-exit "*) true ;; *) false ;; esac; then
  run_menu_q_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" prompt-controls-and-defaults "*) true ;; *) false ;; esac; then
  run_prompt_controls_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" quick-tunnel-reach-is-not-a-question "*) true ;; *) false ;; esac; then
  run_scope_quick_tunnel_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" a-pasted-credential-is-named-at-the-prompt-that-refused-it "*) true ;; *) false ;; esac; then
  run_secret_shape_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" custom-review-back-corrects-port "*) true ;; *) false ;; esac; then
  run_custom_review_back_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" menu-action-1-setup "*) true ;; *) false ;; esac; then
  run_menu_setup_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" setup-detected-still-requires-choice "*) true ;; *) false ;; esac; then
  run_detected_requires_choice_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" menu-action-check-server "*) true ;; *) false ;; esac; then
  run_menu_check_case server
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" menu-action-check-adapter "*) true ;; *) false ;; esac; then
  run_menu_check_case adapter
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" menu-action-4-show-code "*) true ;; *) false ;; esac; then
  run_menu_show_code_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" menu-corrupt-profile-hides-show-code "*) true ;; *) false ;; esac; then
  run_menu_corrupt_profile_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" menu-partial-profile-hides-show-code "*) true ;; *) false ;; esac; then
  run_menu_partial_profile_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" mixed-profile-picker-filters-invalid "*) true ;; *) false ;; esac; then
  run_mixed_profile_picker_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" profile-local-port-gate "*) true ;; *) false ;; esac; then
  run_profile_local_port_gate_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" profile-selfsigned-transport-refused "*) true ;; *) false ;; esac; then
  run_profile_selfsigned_transport_refused_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" own-https-requires-trusted-cert "*) true ;; *) false ;; esac; then
  run_own_https_trust_gate_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" exposure-menu-places-the-quick-tunnel "*) true ;; *) false ;; esac; then
  run_exposure_menu_quick_tunnel_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" profile-legacy-file-reach-fallback "*) true ;; *) false ;; esac; then
  run_profile_legacy_file_reach_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" profile-never-carries-secrets "*) true ;; *) false ;; esac; then
  run_profile_secret_exclusion_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" profile-refusing-runs-keep-the-saved-lane "*) true ;; *) false ;; esac; then
  run_profile_overwrite_guard_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" pairing-warning-states-what-the-code-is "*) true ;; *) false ;; esac; then
  run_pairing_warning_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" pairing-adapter-suggestion-names-its-outcome "*) true ;; *) false ;; esac; then
  run_pairing_check_suggestion_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" pairing-code-restates-the-logout-caveat "*) true ;; *) false ;; esac; then
  run_pairing_linger_caveat_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" pairing-code-warns-a-rotating-quick-tunnel "*) true ;; *) false ;; esac; then
  run_pairing_quick_tunnel_reminder_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" pairing-checks-target-the-route-that-failed "*) true ;; *) false ;; esac; then
  run_pairing_check_targets_the_failed_route_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" moved-address-is-not-a-server-error "*) true ;; *) false ;; esac; then
  run_moved_address_diagnosis_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" keyless-403-is-not-a-rejected-token "*) true ;; *) false ;; esac; then
  run_keyless_403_diagnosis_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" keyless-5xx-names-the-missing-credential "*) true ;; *) false ;; esac; then
  run_keyless_5xx_credential_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" standalone-checks-do-not-invent-a-keyless-token "*) true ;; *) false ;; esac; then
  run_standalone_check_keyless_403_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" file-fault-does-not-mask-a-dead-gateway "*) true ;; *) false ;; esac; then
  run_file_lane_failure_names_the_gateway_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" help-lists-public-meta-flags "*) true ;; *) false ;; esac; then
  run_help_surface_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" ci-gate-no-handoff "*) true ;; *) false ;; esac; then
  run_ci_gate_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" adapter-fail-offers-the-way-out "*) true ;; *) false ;; esac; then
  run_adapter_fail_wayout_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" server-url-reask-keeps-token "*) true ;; *) false ;; esac; then
  run_server_url_reask_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" server-html-names-the-subpath "*) true ;; *) false ;; esac; then
  run_server_html_subpath_hint_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" no-ansi-when-redirected "*) true ;; *) false ;; esac; then
  run_no_ansi_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" reject-body-verdict-matrix "*) true ;; *) false ;; esac; then
  run_reject_body_matrix_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" fixture-rejections-keep-the-connection-usable "*) true ;; *) false ;; esac; then
  run_fixture_rejection_reuse_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" reject-body-not-graded-wrong-token-ok "*) true ;; *) false ;; esac; then
  run_reject_body_gate_case wrong-token-ok
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" reject-body-not-graded-keyless "*) true ;; *) false ;; esac; then
  run_reject_body_gate_case keyless
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" auth-eof-dies-server "*) true ;; *) false ;; esac; then
  run_auth_eof_case server
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" auth-eof-dies-adapter "*) true ;; *) false ;; esac; then
  run_auth_eof_case adapter
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" preflight-missing-python3-server "*) true ;; *) false ;; esac; then
  run_preflight_missing_tool_case server python3
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" preflight-missing-python3-adapter "*) true ;; *) false ;; esac; then
  run_preflight_missing_tool_case adapter python3
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" preflight-missing-curl-server "*) true ;; *) false ;; esac; then
  run_preflight_missing_tool_case server curl
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" preflight-missing-curl-adapter "*) true ;; *) false ;; esac; then
  run_preflight_missing_tool_case adapter curl
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" generic-legacy-alias "*) true ;; *) false ;; esac; then
  run_generic_alias_case plain
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" generic-legacy-alias-dry-run "*) true ;; *) false ;; esac; then
  run_generic_alias_case dry-run
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" check-pass-continue-setup "*) true ;; *) false ;; esac; then
  run_check_continue_yes_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" long-model-check-setup-payload "*) true ;; *) false ;; esac; then
  run_long_model_handoff_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" all-curl-calls-ignore-config "*) true ;; *) false ;; esac; then
  run_curl_config_isolation_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" fixtures-do-not-reverse-resolve-their-bind "*) true ;; *) false ;; esac; then
  run_fixture_bind_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" gateway-text-cannot-forge-transcript "*) true ;; *) false ;; esac; then
  run_gateway_text_sanitised_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" urls-refuse-embedded-credentials "*) true ;; *) false ;; esac; then
  run_url_userinfo_refused_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" owned-config-mode-change-is-announced "*) true ;; *) false ;; esac; then
  run_owned_config_mode_change_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" env-ports-are-validated "*) true ;; *) false ;; esac; then
  run_env_port_validation_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" check-probe-files-are-not-siblings "*) true ;; *) false ;; esac; then
  run_check_tempfile_isolation_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" state-dir-is-0700-or-reported "*) true ;; *) false ;; esac; then
  run_state_dir_mode_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" check-pass-continuation-eof "*) true ;; *) false ;; esac; then
  run_check_continue_eof_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" checked-local-path-survives-exposure "*) true ;; *) false ;; esac; then
  run_checked_path_prefix_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" shared-app-evaluator "*) true ;; *) false ;; esac; then
  run_shared_app_evaluator_wiring_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" file-lane-readiness "*) true ;; *) false ;; esac; then
  if bash "$HERE/run-file-lane-readiness-suite.sh"; then
    PASS=$((PASS+1))
    printf 'SUITE ✓ file-lane-readiness\n'
  else
    FAIL=$((FAIL+1))
    printf 'SUITE ✗ file-lane-readiness — focused suite failed\n'
  fi
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" host-environment "*) true ;; *) false ;; esac; then
  if bash "$HERE/run-host-environment-suite.sh"; then
    PASS=$((PASS+1))
    printf 'SUITE ✓ host-environment\n'
  else
    FAIL=$((FAIL+1))
    printf 'SUITE ✗ host-environment — focused suite failed\n'
  fi
fi

# The rclone integration companion. Everything above this line is hermetic — stdlib
# fixtures, no external binaries — and that is deliberate: it is what lets this suite
# run anywhere without provisioning. So this block may NOT make the suite's verdict
# depend on whether rclone happens to be installed.
#
# It is chained anyway because the alternative was worse: this script is the ONLY
# place the real `rclone serve webdav` dir-cache behaviour is graded, and nothing
# invoked it, so its cases had never run outside a human typing the path.
#
# Three outcomes, and the third is the one that matters. Exit 2 is the script's
# "rclone is absent" contract, which is NOT a failure and must not fail a hermetic
# run — but it must not read as coverage either. It is recorded and re-stated after
# the RESULT line, because a suite that goes quiet about what it did not run is how
# this became dead coverage in the first place.
NOT_RUN=""
if [ -z "$ONLY" ] || case " $ONLY " in *" rclone-integration "*) true ;; *) false ;; esac; then
  bash "$HERE/run-check-adapter-rclone-integration.sh"; integ_rc=$?
  case "$integ_rc" in
    0)
      PASS=$((PASS+1))
      printf 'SUITE ✓ rclone-integration\n' ;;
    2)
      NOT_RUN="rclone-integration (needs a real rclone binary: brew install rclone)"
      printf 'SUITE — rclone-integration DID NOT RUN — rclone is not installed\n' ;;
    *)
      FAIL=$((FAIL+1))
      printf 'SUITE ✗ rclone-integration — integration suite failed (exit %s)\n' "$integ_rc" ;;
  esac
fi

printf '\nSUITE RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
# Printed AFTER the result, where it cannot be lost above a wall of passing lines:
# a green run that skipped a coverage area has to say so on its last line.
[ -z "$NOT_RUN" ] || printf 'SUITE COVERAGE NOT RUN: %s\n' "$NOT_RUN"
[ "$FAIL" = "0" ] || exit 1
[ "$PASS" -gt 0 ] || { echo "no cases ran" >&2; exit 1; }
exit 0
