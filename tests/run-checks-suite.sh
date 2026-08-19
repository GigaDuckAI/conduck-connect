#!/usr/bin/env bash
#
# run-checks-suite.sh — conduck-connect check and command regression suite.
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
SRC_DIR="$HERE/../src"
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
FILE_IDS="FILES_CONFIG FILES_WRITE_THROUGH FILES_AUTH_READ_MISSING FILES_AUTH_READ_WRONG FILES_AUTH_WRITE_MISSING FILES_AUTH_WRITE_WRONG FILES_READ_FRESH FILES_PROBE_COMPAT FILES_NESTED FILES_LISTING FILE_COPY_BYTES FILE_E2E FILES_DELETE"

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
# Streams only when the ACCEPT HEADER asks, never on the body flag. This row is the
# whole reason STREAM_SYNC now sends an Accept naming text/event-stream: under a
# json-only probe header this fixture answers every request correctly and goes green,
# which is exactly how a content-negotiating adapter would have shipped unnoticed.
# (No apostrophes in this block — CASES is single-quoted and one would end it.)
sse-on-accept-header|sse-on-accept-header|--deep|no|1|STREAM_SYNC|core=FAIL stream=FAIL exit=1
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

# check-artifact leftovers in a served dir (conduck-check-* / out-* / output-*),
# one per line — the post-check for the cleanup-focused file cases.
# Recursive on purpose, and matching every component form the check can mint:
# the agent's own output now sits two segments down, inside a folder whose inner
# segment is named "out-<nonce>" and matches neither of the other two patterns.
check_artifacts() { # check_artifacts <served-dir>
  find "$1" -mindepth 1 \( -name 'conduck-check-*' -o -name 'out-*' -o -name 'output-*' \) 2>/dev/null
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

# THE guard that keeps the rest of this file honest. Read this before adding a case.
#
# Most cases here assemble a MINIMAL runtime: extract_funcs lifts the handful of
# functions the case is about out of the release artifact, and everything else is a
# stub. That assembly degrades SILENTLY the moment a lifted function grows a new
# callee: an undefined function is exit 127 with no output, there is no `set -e`,
# so the run walks on and every assertion downstream of it passes — or fails — for
# no reason at all. This is not hypothetical. One release taught six existing
# functions to call six new helpers; no lift list was updated; the suite then ran
# with 62 undefined-function calls and reported 159 passes, an unknown number of
# them vacuous. A green suite that tests nothing is worse than a red one.
#
# So every isolated case runs its captured transcript through here. The shell's own
# "command not found" is the signal — it costs nothing, it cannot go stale, and it
# fires the first time src/ grows a callee a lift list does not carry, in whichever
# case reaches it first. The fix is always the same: add the name to that case's
# extract_funcs list, or stub it beside the case's other stubs when the case wants
# the callee neutralised rather than exercised.
#
# Callers MUST capture stderr (`2>&1`) — that is where the shell reports it. A case
# that deliberately drops stderr cannot be guarded and has to say so in a comment.
assert_runtime_defined() { # assert_runtime_defined <case-name> <transcript…>
  local name="$1"; shift
  local missing
  missing=$(printf '%s\n' "$*" \
    | sed -n 's/.*: \([A-Za-z_][A-Za-z0-9_]*\): command not found.*/\1/p' \
    | sort -u | tr '\n' ' ')
  [ -z "$missing" ] && return 0
  fail_case "$name" "the assembled runtime called undefined function(s): ${missing% }"
  return 1
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
    silent-drop-image|require-model-drop-image)
      # The verdict may say what the probe MEASURED and nothing past it. From out
      # here a missing set of digits has two causes that answer identically — the
      # image never reached the engine, or it reached one that misread the glyphs —
      # and both were seen producing this same verdict on a live run. Asserting the
      # drop sends the second builder auditing a forwarding path that works, so the
      # explanation must name both and diagnose neither.
      if ! grep -qF 'could not verify that the engine used the image' "$TMP/doctor.out"; then
        fail_case "$name" "an unproven image sighting lost its explanation"; return
      fi
      if ! grep -qF 'may never have reached the engine' "$TMP/doctor.out"; then
        fail_case "$name" "the dropped-before-the-engine cause was not named"; return
      fi
      if ! grep -qF 'misread it' "$TMP/doctor.out"; then
        fail_case "$name" "the engine-saw-it-and-misread-it cause was not named"; return
      fi
      if grep -qF 'the engine never saw the image' "$TMP/doctor.out"; then
        fail_case "$name" "the verdict asserted a cause a black-box probe cannot observe"; return
      fi
      # Failing closed on missing proof is still correct, and the way out is still
      # the contract's two conforming outcomes — softening the cause must not have
      # cost the remedy.
      if ! grep -qF 'Forward images to the engine' "$TMP/doctor.out"; then
        fail_case "$name" "the unproven-image verdict lost the forward-it remedy"; return
      fi
      if ! grep -qF 'image_unsupported' "$TMP/doctor.out"; then
        fail_case "$name" "the unproven-image verdict lost the honest-decline remedy"; return
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
# real saved profile is consulted and no shared state leaks.
# name|adapter-mode|webdav-mode|env-mode|adapter-args|exp-exit|exp-fails|frags|post
#   webdav-mode "-"      = no WebDAV server (config-error cases fail before contact)
#   env-mode: full       = CONDUCK_FILES_URL(webdav)+DIR(served)+PASS(cred)
#             url-only    = only CONDUCK_FILES_URL set (partial → FILES_CONFIG)
#             home-dir    = DIR=$HOME (refused) ; none = no overrides (no profile)
#   post: - | dir-empty (served dir must hold zero check artifacts) | no-leak
#         | stray-kept (the check's OWN artifacts are gone, and the stray file a
#           misbehaving agent wrote outside them is still there — the "exact
#           registered names only, never a glob" rule, stated as an assertion)
FILE_CASES='
files-good|files-good|good|full|--files|0|-|profile=basic core=PASS file_transport=PASS file_access=PASS file_e2e=PASS exit=0|dir-empty
files-not-requested|good|-|none|--deep|0|-|core=PASS file_transport=NOT_REQUESTED file_access=NOT_REQUESTED file_e2e=NOT_REQUESTED exit=0|-
files-stale-cache|files-good|stale-listing|full|--files|1|FILES_READ_FRESH,FILE_E2E|core=PASS file_transport=FAIL file_access=PASS file_e2e=FAIL exit=1|-
files-read-only|files-good|read-only|full|--files|1|FILES_NESTED,FILES_WRITE_THROUGH|core=PASS file_transport=FAIL file_access=PASS file_e2e=PASS exit=1|-
files-open|files-good|open|full|--files|1|FILES_AUTH_READ_MISSING,FILES_AUTH_READ_WRONG,FILES_AUTH_WRITE_MISSING,FILES_AUTH_WRITE_WRONG|core=PASS file_transport=FAIL file_access=PASS file_e2e=PASS exit=1|-
files-no-range|files-good|no-range|full|--files|0|-|core=PASS file_transport=PASS file_access=PASS file_e2e=PASS exit=0|-
files-no-delete|files-good|no-delete|full|--files|0|-|core=PASS file_transport=PASS file_access=PASS file_e2e=PASS exit=0|dir-empty
files-no-mkcol|files-good|no-mkcol|full|--files|1|FILES_NESTED|core=PASS file_transport=FAIL file_access=PASS file_e2e=PASS exit=1|-
files-mkcol-auto-parents|files-good|mkcol-refused-auto-parents|full|--files|0|-|core=PASS file_transport=PASS file_access=PASS file_e2e=PASS exit=0|dir-empty
files-no-propfind|files-good|no-propfind|full|--files|1|FILES_LISTING,FILE_COPY_BYTES|core=PASS file_transport=FAIL file_access=ERROR file_e2e=NOT_RUN exit=1|dir-empty
files-propfind-catch-all|files-good|propfind-catch-all|full|--files|1|FILES_LISTING,FILE_COPY_BYTES|core=PASS file_transport=FAIL file_access=ERROR file_e2e=NOT_RUN exit=1|dir-empty
files-propfind-catch-all-nested|files-good|propfind-catch-all-nested|full|--files|1|FILES_LISTING,FILE_COPY_BYTES|core=PASS file_transport=FAIL file_access=ERROR file_e2e=NOT_RUN exit=1|dir-empty
files-propfind-hidden|files-good|propfind-hides-contents|full|--files|1|FILES_LISTING,FILE_E2E|core=PASS file_transport=FAIL file_access=PASS file_e2e=FAIL exit=1|-
files-listing-foreign-href|files-good|listing-foreign-href|full|--files|1|FILES_LISTING,FILE_E2E|core=PASS file_transport=FAIL file_access=PASS file_e2e=FAIL exit=1|-
files-agent-no-write|files-no-write|good|full|--files|1|FILE_COPY_BYTES|core=PASS file_transport=PASS file_access=FAIL file_e2e=NOT_RUN exit=1|-
files-agent-late-write|files-late-write|good|full|--files|1|FILE_COPY_BYTES|core=PASS file_transport=PASS file_access=FAIL file_e2e=NOT_RUN exit=1|dir-empty
files-agent-wrong-bytes|files-wrong-bytes|good|full|--files|1|FILE_COPY_BYTES|core=PASS file_transport=PASS file_access=FAIL file_e2e=NOT_RUN exit=1|-
files-agent-writes-to-root|files-writes-to-root|good|full|--files|1|FILE_COPY_BYTES|core=PASS file_transport=PASS file_access=FAIL file_e2e=NOT_RUN exit=1|stray-kept
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
    stray-kept)
      # The check registers every name it may create and removes those exact
      # names. A file a MISBEHAVING agent wrote outside that registry is not
      # the check's to delete — the operator was told so up front — and a
      # cleanup that swept it would be a glob wearing a registry's clothes.
      local own stray
      own=$(find "$SERVED" -mindepth 1 -name 'conduck-check-*' 2>/dev/null)
      if [ -n "$own" ]; then
        fail_case "$name" "the check's own artifacts survived: $(echo $own)"; return
      fi
      stray=$(find "$SERVED" -mindepth 1 -name 'output-*' 2>/dev/null)
      if [ -z "$stray" ]; then
        fail_case "$name" "the stray file written outside the registry was removed anyway"; return
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

  # Per-name wording. The exact failed-id set says WHICH check fired; these say
  # the check named the right cause. Three of these rows exist only because the
  # id set alone was satisfied by the wrong reasoning, so the reason is asserted
  # rather than assumed.
  case "$name" in
    files-mkcol-auto-parents)
      # The verdict is the nested PUT + byte-echoing GET, exactly as the app
      # decides folder capability; MKCOL is a tiebreaker for a REFUSED write. A
      # green that stayed silent about the 405 would hide the whole finding.
      if ! grep -qF 'MKCOL answered HTTP 405' "$TMP/doctor.out"; then
        fail_case "$name" "the green nested verdict never says MKCOL was refused"; return
      fi
      if ! grep -qF 'creates the missing parent itself' "$TMP/doctor.out"; then
        fail_case "$name" "the green nested verdict does not name auto-created parents"; return
      fi ;;
    files-propfind-catch-all-nested)
      # This lane 404s a missing root-level name and 207s a missing one inside a
      # folder. The control has to land in the folder, or it grades a route the
      # app never takes.
      if ! grep -qF 'for a folder that cannot exist' "$TMP/doctor.out"; then
        fail_case "$name" "the control never caught the in-subfolder catch-all"; return
      fi
      if ! grep -qF 'never proved it can report a folder ABSENT' "$TMP/doctor.out"; then
        fail_case "$name" "a disqualified control still let the agent tier run"; return
      fi ;;
    files-listing-foreign-href)
      # The one that must name the app's own refusal, because the failure is
      # nothing the operator can see in a 207 that looks perfectly ordinary.
      if ! grep -qF 'entryOutsideCollection' "$TMP/doctor.out"; then
        fail_case "$name" "the listing refusal does not name its reason"; return
      fi
      if ! grep -qF 'Conduck refuses to read' "$TMP/doctor.out"; then
        fail_case "$name" "the red never says the app refuses this listing"; return
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
server-model-less-500|model-less-500|no|1|wire=FAIL chat=FAIL model=required exit=1
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
    server-silent-drop-image)
      # IGNORED is a meter name, frozen in the grammar; the sentence under it is
      # not, and it may only claim what the probe saw. Absent digits have two
      # causes that answer identically out here — the image never reached the
      # engine, or it reached one that misread the glyphs — and a generic server
      # fronting a text-weak model is the commonest way to hit the second. An
      # operator told the image "was never seen" goes looking in a delivery path
      # that is working.
      if ! grep -qF 'could not verify the engine used the image' "$TMP/doctor.out"; then
        fail_case "$name" "the IGNORED note doesn't say what went unproven"; return
      fi
      if ! grep -qF 'may never have reached the engine' "$TMP/doctor.out"; then
        fail_case "$name" "the dropped-before-the-engine cause was not named"; return
      fi
      if ! grep -qF 'misread it' "$TMP/doctor.out"; then
        fail_case "$name" "the engine-saw-it-and-misread-it cause was not named"; return
      fi
      if grep -qF 'the engine never saw' "$TMP/doctor.out"; then
        fail_case "$name" "the note asserted a cause a black-box probe cannot observe"; return
      fi
      # …and it stays informational: this result never moves the wire verdict.
      if ! grep -qF 'never changes the verdict' "$TMP/doctor.out"; then
        fail_case "$name" "the image probe stopped saying it is informational"; return
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
  # The middle branch of the three-way chat verdict, and the only place it can be
  # observed. The model-less turn failed, the model-NAMED turn succeeded — and the
  # model-less status (500) is outside the list the app's own model-required gate
  # accepts, so this is a real fault rather than a configuration fact.
  #
  # The wrong verdict is the expensive one: told "this server requires a model",
  # the operator configures one in the app, and the intermittent 5xx is still
  # there with its only diagnosis already spent. So both halves are asserted —
  # that the PASS wording is absent, and that the FAIL says which kind it is.
  if [ "$name" = "server-model-less-500" ]; then
    if grep -qF 'chat works once a model is set' "$TMP/doctor.out"; then
      fail_case "$name" "a 500 on the model-less turn was read as 'this server requires a model'"; return
    fi
    if ! grep -qF "this failure isn't the missing-model kind" "$TMP/doctor.out"; then
      fail_case "$name" "the FAIL never said why it is not the missing-model kind"; return
    fi
    # The named-model turn really did pass, so the fork above was reached at all
    # rather than the whole chat step failing for one reason.
    if ! grep -qF 'selects (the app sends what the user picked)' "$TMP/doctor.out"; then
      fail_case "$name" "the model-named turn did not pass — the arm never reached the fork"; return
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

# No terminal, no arguments. This does NOT reach the menu any more, and the change
# is the point: exit 4 means "this needs a person at a terminal", which is a
# different fact from exit 1 ("something went wrong"), and a wrapper has no other way
# to tell them apart. Reaching the menu and then dying at EOF told a machine driver
# to try harder at a question no machine can answer.
#
# HOME and XDG_CONFIG_HOME are isolated even though this run only reads: the operator's
# real ~/.config/conduck must never be an input to a test result, or the suite grades a
# different thing on the machine that paired a gateway than on a clean runner.
run_noarg_noninteractive_case() {
  local name="menu-noninteractive-eof" rc=0
  local home="$TMP/noarg-home" state="$TMP/noarg-state"
  mkdir -p "$home" "$state"
  env -u CI HOME="$home" XDG_CONFIG_HOME="$state" TERM=dumb \
    bash "$SCRIPT" </dev/null > "$TMP/doctor.out" 2>&1 || rc=$?
  if [ "$rc" != "4" ]; then
    fail_case "$name" "a no-terminal run exited $rc, expected 4 (needs a person at a terminal)"; return
  fi
  if ! grep -qF 'needs a person at a terminal' "$TMP/doctor.out"; then
    fail_case "$name" "the refusal did not say what is actually missing"; return
  fi
  # A refusal that only refuses is a dead end. It has to name what a machine CAN run
  # here, or the transcript reads: green check, instruction, failure.
  if ! grep -qF 'CI=1 CONDUCK_TOKEN=… bash conduck-connect.sh --check-server' "$TMP/doctor.out" ||
     ! grep -qF 'CI=1 CONDUCK_TOKEN=… bash conduck-connect.sh --check-adapter' "$TMP/doctor.out" ||
     ! grep -qF 'bash conduck-connect.sh --list --json' "$TMP/doctor.out"; then
    fail_case "$name" "the refusal did not name the commands a machine can run instead"; return
  fi
  # …and it must not hand a machine the one command it has just explained it cannot
  # finish. --setup --dry-run is offered explicitly "from a terminal".
  if ! grep -qF 'From a terminal, to see every change setup would make' "$TMP/doctor.out"; then
    fail_case "$name" "the dry-run suggestion no longer says it needs a terminal"; return
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
  # q at the WELCOME MENU is 0, not 3. It is a completed choice — the operator was
  # asked what to do and answered "nothing" — where 3 means a run was abandoned
  # partway. A wrapper that cannot tell those apart reads every deliberate exit as a
  # failure, or every abandoned setup as a success.
  if [ "$rc" != "0" ] ||
     ! grep -qF 'pair your self-hosted AI gateway with Conduck' "$TMP/doctor.out" ||
     ! grep -qF 'Please enter one of the listed options.' "$TMP/doctor.out" ||
     ! grep -qF 'Nothing changed.' "$TMP/doctor.out"; then
    fail_case "$name" "info / invalid retry / q did not complete the PTY menu flow"; return
  fi
  # The entry-point explanation answers a stranger's questions rather than reciting
  # the mid-wizard prompt template. Four of them, and each is a heading a reader can
  # find: what this is, what they end up with, how long, what changes on this machine.
  local heading
  for heading in 'What this is' 'What you end up with' 'How long' 'What changes on this machine'; do
    if ! grep -qF "  $heading" "$TMP/doctor.out"; then
      fail_case "$name" "the welcome explanation no longer answers '$heading'"; return
    fi
  done
  prompt_count=$(grep -c 'Choose an option (Enter = ask again; i = explain; q = stop)' "$TMP/doctor.out")
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

# The menu is a HUB, and this is the case that proves it in one process.
#
# Three separate things, and the third is why this case exists at all:
#
#   1. An action entered from the menu RETURNS to the menu on `m`, so a wrong turn
#      costs one action instead of the whole session.
#   2. `m` is offered at quit_run too — the place somebody who mis-stepped actually
#      presses q — and its wording is the CHECK flavour there, not the setup one.
#      Three of quit_run's five closing sentences are about undoing configuration
#      changes, and a check makes none; reading them after a diagnostic is alarming
#      for no reason.
#   3. NO FLAG STATE LEAKS BETWEEN TWO ACTIONS IN ONE PROCESS. This is the bug that
#      shipped: `validate_cli` runs in the PARENT shell (the action itself runs in a
#      subshell and cannot leak), it set `REUSE_ONLY=true` for a check and never
#      restored it, and both symptoms were silent to whoever caused them —
#         · a later "set up and pair" ran REUSE-ONLY, refusing every change it was
#           chosen to make, announced only by a line in a banner nobody re-reads;
#         · a later CHECK read that leftover as a `--reuse-only` on the command
#           line and killed the whole session with a usage error, from the parent,
#           so the hub could not even redraw.
#      It was caught by hand. Nothing in the suite could see it, because every
#      other case in this file runs exactly one action per process.
#
# The walk: check-server → q → m → check-adapter → q → m → setup → q → Enter.
# Two checks in a row and then a setup, which is the shortest path that exercises
# both symptoms of (3).
run_menu_hub_case() {
  local name="menu-hub-returns-and-leaks-nothing" rc=0 menus
  local home="$TMP/hub-home" state="$TMP/hub-state"
  mkdir -p "$home" "$state"
  PTY_ENV=(HOME="$home" XDG_CONFIG_HOME="$state")
  pty_run 20 $'2\nq\nm\n3\nq\nm\n1\nq\n\n' > "$TMP/doctor.out" 2>&1 || rc=$?

  # SYMPTOM B of the leak, and the sharper of the two: a hard session kill. It is
  # asserted first because if it fires, everything below it never ran.
  if grep -qF 'Usage error:' "$TMP/doctor.out"; then
    fail_case "$name" "a second action in one session died with a usage error — argv state leaked between actions"; return
  fi
  # SYMPTOM A: the setup that follows two checks must be a REAL setup.
  if grep -qF 'reuse-only: I' "$TMP/doctor.out"; then
    fail_case "$name" "setup entered from the menu ran reuse-only — --reuse-only leaked out of a check"; return
  fi
  # The hub really did come back. Three drawings: the first, and one after each m.
  #
  # Counted on the menu's QUESTION, not on its title line. The setup banner opens
  # with the same sentence one full stop apart ("…with Conduck." vs "…with
  # Conduck"), so counting the title would score the setup pass as a fourth menu.
  menus=$(grep -c '  What would you like to do?' "$TMP/doctor.out")
  if [ "$menus" != "3" ]; then
    fail_case "$name" "the welcome menu was drawn $menus times, expected 3 (start + two returns)"; return
  fi
  if ! grep -qF 'Enter = stop; m = back to the menu' "$TMP/doctor.out"; then
    fail_case "$name" "q never offered the way back to the menu"; return
  fi
  # All three actions were genuinely entered, so the count above is not three
  # redraws of a menu nothing ever left.
  if ! grep -qF 'CONDUCK_CHECK_SERVER schema=' "$TMP/doctor.out" ||
     ! grep -qF 'CONDUCK_CHECK_ADAPTER schema=' "$TMP/doctor.out" ||
     ! grep -qF 'Step 1 — find your gateway' "$TMP/doctor.out"; then
    fail_case "$name" "one of the three menu actions was never reached"; return
  fi
  # quit_run's fork. A check edits nothing, so it gets the sentence that says so —
  # and must NOT get the setup paragraph about config edits and restarts.
  if ! grep -qF 'Stopped here. Nothing was changed' "$TMP/doctor.out"; then
    fail_case "$name" "stopping a check printed the setup vocabulary instead of its own"; return
  fi
  # …and the setup pass, the last of the three, gets the setup one.
  if ! grep -qF 'Stopped here. No further setup actions will run.' "$TMP/doctor.out"; then
    fail_case "$name" "stopping the setup pass did not print the setup ending"; return
  fi
  # No FILE was written: every action here was stopped before it could change
  # anything. Directories are excluded on purpose and the distinction is real —
  # the setup pass takes its lock, which creates $STATE_DIR itself (0700, silently,
  # through the one ensure_state_dir every writer goes through) and then releases
  # it on the way out. An empty directory is the documented footprint of a run that
  # started; a file in it would be a saved gateway nobody agreed to.
  if [ -n "$(find "$home" "$state" -type f -print -quit 2>/dev/null)" ]; then
    fail_case "$name" "a session of three abandoned actions still wrote a file"; return
  fi
  # 3, from the last action: the hub propagates an action's own status rather than
  # flattening it, which is the only reason a wrapper can tell an abandoned run
  # from a finished one.
  if [ "$rc" != "3" ]; then
    fail_case "$name" "the hub session exited $rc, expected 3 from the abandoned setup"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# A menu action runs in a SUBSHELL, and bash resets every caught trap on entering
# one. So the EXIT trap armed at file scope is simply gone inside an action chosen
# from the menu, and the parent's copy cannot stand in: it fires in the PARENT, where
# the dead child's state never existed. menu_hub_loop re-arms it, and this case is
# the only thing that says so.
#
# Why it matters and why it was invisible: --show-code arms no trap of its own, and
# the agent sentinel's last DELETE-and-prove pass plus the "remove this exact file
# later" warning reach the operator through on_exit and nowhere else. Entered from a
# flag it worked; entered from the menu it silently did not, and the difference is a
# file left behind in somebody's agent workspace with nothing on screen about it. The
# checks and setup escaped it only because they re-arm their own traps first.
#
# Graded on a LIFTED menu_hub_loop with stubbed surroundings, because the observable
# in a real run is the absence of a cleanup pass on state that takes a whole gateway
# to build. The stub on_exit reports a variable that only the ACTION sets: it can be
# seen exactly once from inside the action's subshell, and once — empty — from the
# parent's own exit. Two sightings is the re-arm; one is the bug.
run_menu_trap_rearm_case() {
  local name="menu-action-runs-with-its-own-exit-trap" out rc=0 hits
  local funcs
  funcs=$(extract_funcs menu_hub_loop)
  if ! printf '%s\n' "$funcs" | grep -qF 'menu_hub_loop()'; then
    fail_case "$name" "could not extract menu_hub_loop from the release artifact"; return
  fi
  : > "$TMP/doctor.out"
  out=$(env -u CI TERM=dumb FUNCS="$funcs" bash -c '
eval "$FUNCS"
MENU_RETURN_STATUS=20
COMMAND=""
PASSES=0
say() { printf "SAY %s\n" "$*"; }
choose_main_action() {
  PASSES=$((PASSES+1))
  case "$PASSES" in 1) COMMAND="show-code" ;; *) COMMAND="exit" ;; esac
}
validate_cli() { :; }
on_exit() { printf "ON_EXIT state=[%s]\n" "${ACTION_STATE:-}"; }
dispatch_menu_command() {
  ACTION_STATE="inside-the-action"
  printf "ACTION ran\n"
  trap -p INT
  exit "$MENU_RETURN_STATUS"
}
trap on_exit EXIT
menu_hub_loop; rc=$?
printf "AFTER_LOOP rc=%s\n" "$rc"
exit "$rc"
' 2>&1) || rc=$?
  printf '%s\n' "$out" >> "$TMP/doctor.out"
  assert_runtime_defined "$name" "$out" || return
  if [ "$rc" != "0" ]; then
    fail_case "$name" "the hub fixture exited $rc, expected 0 — the loop never came back for the second pass"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF 'ACTION ran'; then
    fail_case "$name" "the menu action was never dispatched, so nothing below grades a trap"; return
  fi
  # THE assertion: on_exit fired somewhere that could still see the action's state.
  if ! printf '%s\n' "$out" | grep -qF 'ON_EXIT state=[inside-the-action]'; then
    fail_case "$name" "the EXIT trap did not run for a menu-entered action — bash reset it on subshell entry and nothing re-armed it"; return
  fi
  # Twice: once at the end of the action, once at the end of the session. One
  # sighting means only the parent's file-scope trap ever ran.
  hits=$(printf '%s\n' "$out" | grep -cF 'ON_EXIT state=')
  if [ "$hits" != "2" ]; then
    fail_case "$name" "on_exit ran $hits times, expected 2 (once per action, once for the session)"; return
  fi
  # The signal routing is re-armed by the same three lines and is worth the same
  # keystroke: without it a Ctrl-C during a menu-entered action skips the EXIT trap
  # on macOS bash 3.2 entirely.
  if ! printf '%s\n' "$out" | grep -qF "exit 130"; then
    fail_case "$name" "the action's subshell had no INT handler — signal routing was not re-armed with the EXIT trap"; return
  fi
  # …and an action that returns MENU_RETURN_STATUS returns to the hub rather than
  # ending the session, which is what makes the two sightings above two and not one.
  if ! printf '%s\n' "$out" | grep -qF 'AFTER_LOOP rc=0'; then
    fail_case "$name" "the hub did not survive the action it dispatched"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# The minimal runtime every prompt-primitive sub-case runs inside. The stubs are
# the screen (say/note/warn/explain_action) and the two guards a prompt can reach
# (mutate_guard/plan_add); everything a primitive genuinely does is lifted from the
# artifact, so a control key that stops working here stopped working for real.
#
# DOCTOR/COMPAT/SHOW_QR are seeded explicitly because run_changes_nothing reads
# them and picks quit_run's whole closing paragraph off them. Unseeded they would
# answer on their own defaults and the wording assertion below would hold for a
# reason that has nothing to do with the wizard.
PROMPT_FIXTURE_PRELUDE='
eval "$FUNCS"
BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""
DRY_RUN=false; REUSE_ONLY=false
DOCTOR=false; COMPAT=false; SHOW_QR=false; DOCTOR_FILES=false; MENU_HUB=false
say()  { printf "SAY %s\n" "$*"; }
note() { printf "NOTE %s\n" "$*"; }
warn() { printf "WARN %s\n" "$*"; }
explain_action() { printf "INFO %s\n" "$1"; }
mutate_guard() { printf "GUARD %s\n" "$1"; return 0; }
plan_add() { printf "PLAN %s\n" "$*"; }
'
# prompt_fixture <input> <body> -> transcript in $PF_OUT, process status in $PF_RC.
# Both are globals rather than a captured stdout: the STATUS is half of what these
# sub-cases grade (11 stop, 10 back, 3 stopped mid-flow), and $(…) would throw it
# away. stderr is folded in deliberately — every value primitive writes its
# human-facing lines there, because its callers capture stdout — and
# assert_runtime_defined needs it too.
PF_RC=0
PF_OUT=""
prompt_fixture() { # prompt_fixture <input> <body>
  PF_RC=0
  PF_OUT=$(env -u CI TERM=dumb FUNCS="$PROMPT_FUNCS" \
    CONFIRM_MARKER="$TMP/prompt-confirm-ran" MANUAL_MARKER="$TMP/prompt-manual-ran" \
    QUIT_MARKER="$TMP/prompt-after-quit" CHOICE_MARKER="$TMP/prompt-choice-q-ran" \
    python3 "$PTY_RUN" 10 "$1" bash -c "$PROMPT_FIXTURE_PRELUDE$2" 2>&1) || PF_RC=$?
}
# Same runtime, stdin from a PIPE. A PTY never reaches EOF — it would need an EOT
# byte — and EOF is not an exotic case here: it is what every redirected run, CI
# job and agent driver hands these prompts. Under a pipe `read -r -p` also prints
# no prompt at all, so this lane is the only place prompt_echo's stderr re-emit is
# observable, and an invisible prompt is exactly how a machine driver ends up
# answering a question it could not see.
prompt_fixture_piped() { # prompt_fixture_piped <input> <body>
  PF_RC=0
  PF_OUT=$(printf '%s' "$1" | env -u CI TERM=dumb FUNCS="$PROMPT_FUNCS" \
    CONFIRM_MARKER="$TMP/prompt-confirm-ran" MANUAL_MARKER="$TMP/prompt-manual-ran" \
    QUIT_MARKER="$TMP/prompt-after-quit" CHOICE_MARKER="$TMP/prompt-choice-q-ran" \
    bash -c "$PROMPT_FIXTURE_PRELUDE$2" 2>&1) || PF_RC=$?
}
# Appends the sub-case to the failure transcript and re-checks the runtime guard.
# Returns 1 when a lift gap was found, so the caller stops rather than grading a
# run that half-executed.
prompt_stage() { # prompt_stage <case-name> <stage-label>
  printf -- '--- %s (exit %s) ---\n%s\n' "$2" "$PF_RC" "$PF_OUT" >> "$TMP/doctor.out"
  assert_runtime_defined "$1" "$PF_OUT"
}
pf_has() { printf '%s\n' "$PF_OUT" | grep -qF "$1"; }
pf_count() { printf '%s\n' "$PF_OUT" | grep -cF "$1"; }

# The prompt primitives, exercised in a real PTY without entering setup, and graded
# as TWELVE independent sub-cases.
#
# The contract they all share: a key is a control at a prompt IF AND ONLY IF that
# prompt's own suffix advertises it, the answer travels on stdout and the intent
# travels on the exit status — 10 back, 11 stop, 1 no answer. That last part is why
# there is no literal `q` sentinel to assert any more: a user's real answer can be
# the single letter q, so the string cannot carry the meaning.
#
# One sub-case per primitive, and the split is not cosmetic. A single case spanning
# the whole contract stops at its FIRST failure, so a release that broke ask_secret
# and print_and_wait reports one red line naming confirm and never grades the other
# ten — the suite's own ✗ line points at the wrong primitive. Twelve names means the
# ✗ lines ARE the diagnosis, and a regression in one primitive can no longer hide a
# regression in another. Short keystroke scripts are the other half of the same
# reason: one long script through eight prompts is a desynchronisation waiting to
# happen, and it too names the wrong prompt when it drifts.
#
# `prompt-controls-and-defaults` survives as a SELECTOR that runs all twelve, because
# that is the name the triage tables and earlier notes use. Nothing prints it.
PROMPT_SUBCASES="prompt-confirm-controls
prompt-require-choice-retry
prompt-require-choice-q-status
prompt-into-q-stops-the-process
prompt-into-b-returns-back
prompt-into-eof-dies
prompt-literal-answer-confirmation
prompt-literal-declined-falls-through
prompt-secret-controls
prompt-default-and-resolved-echo
prompt-eof-at-every-primitive
prompt-and-wait-enter-is-no
prompt-q-status-at-every-value-primitive
prompt-back-only-where-advertised
prompt-uncaptured-q-stops-the-run"

prompt_case_wanted() { # prompt_case_wanted <sub-case-name>
  [ -n "$ONLY" ] || return 0
  case " $ONLY " in
    *" prompt-controls-and-defaults "*) return 0 ;;
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# One lift for all twelve — it is one runtime — and a broken lift fails every
# sub-case that was asked for. Failing only the first would report eleven passes for
# a runtime that was never assembled, which is the same vacuous-green the guard
# exists to kill.
#
# NO_ANSWER is a top-level string, not a function, and prompt_into's EOF arm
# dereferences it under set -u — lift the real one so the EOF sub-cases grade the
# message users actually get.
PROMPT_FUNCS=""
prompt_controls_lift() {
  local fn sub lifted why=""
  lifted="explain_prompt run_changes_nothing quit_run interactive_terminal
          control_keys control_suffix prompt_echo prompt_wants_literal
          value_prompt_control prompt_into ask_report_no_answer
          looks_like_a_secret warn_answer_looked_like_a_secret die
          url_has_userinfo
          confirm ask ask_default ask_secret ask_url require_choice print_and_wait"
  PROMPT_FUNCS=$(extract_funcs $lifted
                 sed -n '/^NO_ANSWER=/p;/^URL_USERINFO_HINT=/p' "$SCRIPT")
  for fn in $lifted; do
    printf '%s\n' "$PROMPT_FUNCS" | grep -qF "$fn()" ||
      why="could not extract $fn from the release artifact"
  done
  printf '%s\n' "$PROMPT_FUNCS" | grep -q '^NO_ANSWER=' ||
    why="could not lift NO_ANSWER from the release artifact"
  [ -z "$why" ] && return 0
  # Deliberately an EMPTY transcript: fail_case tails $TMP/doctor.out, and twelve
  # copies of the same 25 lines is how a red run becomes unreadable.
  : > "$TMP/doctor.out"
  for sub in $PROMPT_SUBCASES; do
    prompt_case_wanted "$sub" && fail_case "$sub" "$why"
  done
  return 1
}

# --- confirm: invalid retries, i explains, Enter = No, b only where offered ---
prompt_sub_confirm() {
  local name="prompt-confirm-controls" marker="$TMP/prompt-confirm-ran"
  : > "$TMP/doctor.out"; rm -f "$marker"
  prompt_fixture $'bogus\ni\n\nb\nb\n\n' '
if confirm "Fixture confirmation" "fixture.confirm"; then
  : > "$CONFIRM_MARKER"; printf "CONFIRM=yes\n"
else
  printf "CONFIRM=no rc=%s\n" "$?"
fi
confirm "Back-capable confirmation" "fixture.back" true
printf "BACK_ALLOWED_RC=%s\n" "$?"
confirm "Ordinary confirmation" "fixture.no_back"
printf "BACK_BLOCKED_RC=%s\n" "$?"
'
  prompt_stage "$name" confirm || return
  if [ "$PF_RC" != "0" ]; then
    fail_case "$name" "the confirm fixture exited $PF_RC, expected 0 — it never reached the end"; return
  fi
  if ! pf_has 'Please answer y or n, press Enter for No'; then
    fail_case "$name" "an unparseable answer was not re-asked"; return
  fi
  if ! pf_has 'INFO fixture.confirm'; then
    fail_case "$name" "i at a confirm did not print the explanation"; return
  fi
  if ! pf_has 'CONFIRM=no rc=1'; then
    fail_case "$name" "Enter at a confirm was not No (status 1)"; return
  fi
  if [ -e "$marker" ]; then
    fail_case "$name" "Enter at a confirm ran the yes branch"; return
  fi
  if ! pf_has 'Enter = No; i = explain; b = back; q = stop'; then
    fail_case "$name" "a back-capable confirm did not advertise b in its suffix"; return
  fi
  if ! pf_has 'BACK_ALLOWED_RC=10'; then
    fail_case "$name" "b at a back-capable confirm did not return status 10"; return
  fi
  # The asymmetry is the rule: the same key at a prompt whose suffix does not offer
  # it is refused out loud, not silently taken as No.
  if ! pf_has 'Enter = No; i = explain; q = stop'; then
    fail_case "$name" "an ordinary confirm advertised b it does not honour"; return
  fi
  if ! pf_has 'Back is not available at this step'; then
    fail_case "$name" "b at a confirm that does not offer it was not refused out loud"; return
  fi
  if ! pf_has 'BACK_BLOCKED_RC=1'; then
    fail_case "$name" "b at a confirm that does not offer it did not fall through to Enter = No"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# --- require_choice: Enter is an advertised no-op, not a mistake ---
# Enter at a prompt with no default is a pause, so it gets a note; a wrong answer
# is a mistake, so it gets the warning. Counting both keeps the two apart — the
# release that merged them told somebody who paused that they had erred.
prompt_sub_require_choice() {
  local name="prompt-require-choice-retry"
  : > "$TMP/doctor.out"
  prompt_fixture $'\nnope\n?\n2\n' '
choice=$(require_choice "Choose 1-2" "^[12]$" "fixture.choice")
printf "CHOICE=%s rc=%s\n" "$choice" "$?"
'
  prompt_stage "$name" require_choice || return
  if [ "$PF_RC" != "0" ]; then
    fail_case "$name" "the require_choice fixture exited $PF_RC, expected 0"; return
  fi
  if ! pf_has 'CHOICE=2 rc=0'; then
    fail_case "$name" "a valid answer after two retries was not returned"; return
  fi
  if ! pf_has 'INFO fixture.choice'; then
    fail_case "$name" "? at require_choice did not print the explanation"; return
  fi
  if ! pf_has 'Enter = ask again; i = explain; q = stop'; then
    fail_case "$name" "require_choice lost the suffix naming its controls"; return
  fi
  if [ "$(pf_count 'Nothing chosen — the options are above.')" != "1" ]; then
    fail_case "$name" "a blank answer was not treated as a pause exactly once"; return
  fi
  if [ "$(pf_count 'Please enter one of the listed options.')" != "1" ]; then
    fail_case "$name" "a wrong answer was not treated as a mistake exactly once"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# --- q at a captured primitive: status 11, EMPTY stdout, subshell survives ---
# There is no literal `q` on stdout any more and there must never be one again:
# a gateway called "q" is a legal answer, and the release where the sentinel and
# the answer were the same string minted the permanent id `custom-q`.
prompt_sub_require_choice_q() {
  local name="prompt-require-choice-q-status" marker="$TMP/prompt-choice-q-ran"
  : > "$TMP/doctor.out"; rm -f "$marker"
  prompt_fixture $'q\n' '
choice=$(require_choice "Choose 1-2" "^[12]$" "fixture.choice"); rc=$?
printf "CHOICE_Q=[%s] rc=%s\n" "$choice" "$rc"
[ "$rc" = 11 ] && [ -z "$choice" ] || : > "$CHOICE_MARKER"
printf "AFTER_CHOICE_Q=reached\n"
'
  prompt_stage "$name" 'require_choice q' || return
  if [ "$PF_RC" != "0" ]; then
    fail_case "$name" "q inside \$(…) took the whole fixture down (exit $PF_RC), not just the subshell"; return
  fi
  if ! pf_has 'CHOICE_Q=[] rc=11'; then
    fail_case "$name" "q at require_choice did not return status 11 with an empty answer"; return
  fi
  if [ -e "$marker" ]; then
    fail_case "$name" "the stop intent reached the caller as data rather than as status 11"; return
  fi
  if ! pf_has 'AFTER_CHOICE_Q=reached'; then
    fail_case "$name" "the caller of a captured primitive did not survive q"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# --- prompt_into: the reason it exists ---
# A die or an exit inside $(…) kills the subshell only and the caller walks on with
# an empty answer. prompt_into is the parent-shell half of the contract: it stops the
# PROCESS on q (status 3, with the wizard's closing wording), hands 10 back to a
# caller that offered Back, and dies on a closed stdin. One sub-case each.
prompt_sub_into_q() {
  local name="prompt-into-q-stops-the-process" marker="$TMP/prompt-after-quit"
  : > "$TMP/doctor.out"; rm -f "$marker"
  prompt_fixture $'q\n' '
prompt_into PICK require_choice "Choose 1-2" "^[12]$" "fixture.choice"
: > "$QUIT_MARKER"
printf "AFTER_PROMPT_INTO=reached\n"
'
  prompt_stage "$name" 'prompt_into q' || return
  if [ "$PF_RC" != "3" ]; then
    fail_case "$name" "q at a captured prompt exited $PF_RC, expected 3 (the operator stopped)"; return
  fi
  if pf_has 'AFTER_PROMPT_INTO=reached' || [ -e "$marker" ]; then
    fail_case "$name" "the process kept running past a q that was supposed to end it"; return
  fi
  if ! pf_has 'Stopped here. No further setup actions will run.'; then
    fail_case "$name" "stopping mid-setup did not print the setup ending"; return
  fi
  # The closing paragraph has to say what a stop does NOT do, or an operator who
  # stops halfway assumes the earlier steps were rolled back.
  if ! pf_has 'does not undo'; then
    fail_case "$name" "the closing paragraph did not say a stop does not undo earlier steps"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

prompt_sub_into_back() {
  local name="prompt-into-b-returns-back"
  : > "$TMP/doctor.out"
  prompt_fixture $'b\n' '
prompt_into PICK require_choice "Choose 1-2" "^[12]$" "fixture.choice" true; rc=$?
printf "INTO_BACK_RC=%s PICK=[%s]\n" "$rc" "${PICK:-}"
'
  prompt_stage "$name" 'prompt_into b' || return
  if [ "$PF_RC" != "0" ]; then
    fail_case "$name" "b ended the process (exit $PF_RC) instead of returning to the caller"; return
  fi
  if ! pf_has 'INTO_BACK_RC=10 PICK=[]'; then
    fail_case "$name" "b at a back-capable captured prompt did not reach the caller as status 10 with no value"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

prompt_sub_into_eof() {
  local name="prompt-into-eof-dies"
  : > "$TMP/doctor.out"
  prompt_fixture_piped '' '
prompt_into PICK require_choice "Choose 1-2" "^[12]$" "fixture.choice"
printf "AFTER_EOF=reached\n"
'
  prompt_stage "$name" 'prompt_into EOF' || return
  if [ "$PF_RC" != "1" ]; then
    fail_case "$name" "a closed stdin at a captured prompt exited $PF_RC, expected 1"; return
  fi
  if ! pf_has 'No answer (the input ended).'; then
    fail_case "$name" "the closed-stdin death did not name its cause"; return
  fi
  if pf_has 'AFTER_EOF=reached'; then
    fail_case "$name" "the caller walked on past a prompt nobody answered"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# --- the literal-value path: a user who genuinely wants the answer "q" ---
# The control is the Enter default, so the common reading costs no keystroke and the
# rare literal one costs a single y. b is NOT advertised at these calls, so it is not
# a control here and must be taken as data with no question at all — that asymmetry
# is the whole rule, and the zero count below is what pins it.
prompt_sub_literal_values() {
  local name="prompt-literal-answer-confirmation"
  : > "$TMP/doctor.out"
  prompt_fixture $'i\ny\nb\nq\ny\n' '
free_i=$(ask "Free i" ""); free_b=$(ask "Free b" ""); free_q=$(ask "Free q" "")
printf "FREEFORM=%s|%s|%s\n" "$free_i" "$free_b" "$free_q"
'
  prompt_stage "$name" 'ask literal values' || return
  if [ "$PF_RC" != "0" ]; then
    fail_case "$name" "the literal-value fixture exited $PF_RC, expected 0"; return
  fi
  if ! pf_has 'FREEFORM=i|b|q'; then
    fail_case "$name" "a confirmed literal control key was not returned as the answer"; return
  fi
  if ! pf_has 'Use "i" as your answer instead of showing an explanation? [y/N]'; then
    fail_case "$name" "i at a free-form prompt lost its literal-answer question"; return
  fi
  if ! pf_has 'Use "q" as your answer instead of stopping the run? [y/N]'; then
    fail_case "$name" "q at a free-form prompt lost its literal-answer question"; return
  fi
  if [ "$(pf_count 'as your answer instead of going back')" != "0" ]; then
    fail_case "$name" "a prompt that never offered b still bargained over it"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# …and the same keys, declined, do what the suffix promises.
prompt_sub_literal_declined() {
  local name="prompt-literal-declined-falls-through"
  : > "$TMP/doctor.out"
  prompt_fixture $'i\n\ntyped\nq\n\n' '
v=$(ask "Ctrl i" "" "leave blank" "fixture.value"); printf "CTRL_VALUE=%s\n" "$v"
w=$(ask "Ctrl q" "" "leave blank" "fixture.value"); printf "CTRL_Q_RC=%s w=[%s]\n" "$?" "$w"
'
  prompt_stage "$name" 'ask controls' || return
  if [ "$PF_RC" != "0" ]; then
    fail_case "$name" "the declined-literal fixture exited $PF_RC, expected 0"; return
  fi
  if ! pf_has 'INFO fixture.value'; then
    fail_case "$name" "a declined literal i did not fall through to the explanation"; return
  fi
  if ! pf_has 'CTRL_VALUE=typed'; then
    fail_case "$name" "the prompt did not come back for a real answer after explaining"; return
  fi
  if ! pf_has 'CTRL_Q_RC=11 w=[]'; then
    fail_case "$name" "a declined literal q did not fall through to the stop control"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# --- ask_secret: no literal question, because there is nothing to disambiguate ---
# A bearer token that is exactly one character is not a real token. Taking q as a
# control costs a stop the operator asked for; taking it as data costs a run that
# authenticates with the byte "q" and fails minutes later somewhere else entirely.
# Back is not offered at all — a hidden prompt has no visible state to return to —
# so b is data here.
prompt_sub_secret() {
  local name="prompt-secret-controls"
  : > "$TMP/doctor.out"
  prompt_fixture $'i\nb\nq\n' '
s1=$(ask_secret "Secret one" "leave empty" "fixture.secret"); printf "SECRET1=[%s] rc=%s\n" "$s1" "$?"
s2=$(ask_secret "Secret two" "leave empty" "fixture.secret"); printf "SECRET2=[%s] rc=%s\n" "$s2" "$?"
'
  prompt_stage "$name" ask_secret || return
  if [ "$PF_RC" != "0" ]; then
    fail_case "$name" "the hidden-prompt fixture exited $PF_RC, expected 0"; return
  fi
  if ! pf_has 'Secret one (Enter = leave empty; i = explain; q = stop)'; then
    fail_case "$name" "the hidden prompt's suffix no longer names exactly the keys it honours"; return
  fi
  if ! pf_has 'INFO fixture.secret'; then
    fail_case "$name" "i at a hidden prompt did not explain"; return
  fi
  if ! pf_has 'SECRET1=[b] rc=0'; then
    fail_case "$name" "b at a hidden prompt was taken as a control instead of as data"; return
  fi
  if ! pf_has 'SECRET2=[] rc=11'; then
    fail_case "$name" "q at a hidden prompt did not stop with status 11 and an empty answer"; return
  fi
  if [ "$(pf_count 'as your answer instead of')" != "0" ]; then
    fail_case "$name" "the hidden prompt started bargaining over a one-character secret"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# --- Enter defaults, and the echo of whatever the value resolved to ---
prompt_sub_default() {
  local name="prompt-default-and-resolved-echo"
  : > "$TMP/doctor.out"
  prompt_fixture $'\nover\n' '
d1=$(ask_default "Fixture value" "fixture-default"); printf "DEFAULT=%s\n" "$d1"
d2=$(ask_default "Fixture value" "fixture-default"); printf "TYPED=%s\n" "$d2"
'
  prompt_stage "$name" ask_default || return
  if [ "$PF_RC" != "0" ]; then
    fail_case "$name" "the ask_default fixture exited $PF_RC, expected 0"; return
  fi
  if ! pf_has 'Press Enter to use: fixture-default'; then
    fail_case "$name" "ask_default no longer shows the value Enter would take"; return
  fi
  if ! pf_has 'DEFAULT=fixture-default'; then
    fail_case "$name" "Enter at ask_default did not take the default"; return
  fi
  if ! pf_has 'TYPED=over'; then
    fail_case "$name" "a typed answer did not override the default"; return
  fi
  if ! pf_has '→ using over'; then
    fail_case "$name" "ask_default did not echo the value it resolved to"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# --- the EOF row of the contract, primitive by primitive ---
# Two different answers, both correct, and the split is the point. A DEFAULTED prompt
# takes its default — that is what makes a scripted run reproducible — but never in
# silence. Everything else returns nonzero, because "nobody answered" and "somebody
# chose the empty answer" must never be the same value: ask_secret returning 0 with
# an empty string is how a redirected run infers no-auth from a missing answer, which
# is the fail-closed-auth invariant in one line.
#
# This one sub-case covers eight primitives because they share ONE fixture run — a
# closed stdin cannot be reopened between them — and splitting it further would mean
# eight PTY-free runs of the same shape for no extra signal.
prompt_sub_eof_all() {
  local name="prompt-eof-at-every-primitive" marker="$TMP/prompt-manual-ran"
  : > "$TMP/doctor.out"; rm -f "$marker"
  prompt_fixture_piped '' '
a=$(ask "Free" "the-default"); printf "ASK_EOF=%s rc=%s\n" "$a" "$?"
b=$(ask "Blank" "" "leave blank"); printf "BLANK_EOF=[%s] rc=%s\n" "$b" "$?"
d=$(ask_default "Defaulted" "dflt"); printf "ASKDEF_EOF=%s rc=%s\n" "$d" "$?"
s=$(ask_secret "Secret" "leave empty"); printf "SECRET_EOF=[%s] rc=%s\n" "$s" "$?"
c=$(require_choice "Choose 1-2" "^[12]$"); printf "CHOICE_EOF=[%s] rc=%s\n" "$c" "$?"
u=$(ask_url "Address" "https://ai.example.com"); printf "URL_EOF=[%s] rc=%s\n" "$u" "$?"
confirm "Consent"; printf "CONFIRM_EOF_RC=%s\n" "$?"
print_and_wait "fixture.manual" "fixture manual action" "touch $MANUAL_MARKER"
printf "MANUAL_EOF_RC=%s\n" "$?"
'
  prompt_stage "$name" 'EOF at every primitive' || return
  if [ "$PF_RC" != "0" ]; then
    fail_case "$name" "the EOF fixture exited $PF_RC, expected 0 — it never reached the last primitive"; return
  fi
  # The two that take a default at EOF — and say so.
  if ! pf_has 'ASK_EOF=the-default rc=0' || ! pf_has 'ASKDEF_EOF=dflt rc=0'; then
    fail_case "$name" "a defaulted prompt did not take its default at EOF"; return
  fi
  if ! pf_has 'No answer — using the default: the-default'; then
    fail_case "$name" "a default was taken at EOF in silence"; return
  fi
  if ! pf_has 'BLANK_EOF=[] rc=0' || ! pf_has 'No answer — leaving this blank (leave blank).'; then
    fail_case "$name" "an explicitly-blankable prompt did not record leaving itself blank"; return
  fi
  # …and the ones that must NOT: an empty answer and no answer cannot share a status.
  if ! pf_has 'SECRET_EOF=[] rc=1'; then
    fail_case "$name" "ask_secret returned success at EOF — a redirected run would read that as no-auth"; return
  fi
  if ! pf_has 'CHOICE_EOF=[] rc=1'; then
    fail_case "$name" "require_choice returned success at EOF"; return
  fi
  if ! pf_has 'URL_EOF=[] rc=1'; then
    fail_case "$name" "ask_url returned success at EOF"; return
  fi
  if ! pf_has 'CONFIRM_EOF_RC=1' || ! pf_has 'No answer — treating this as No: Consent'; then
    fail_case "$name" "confirm did not fail closed, out loud, at EOF"; return
  fi
  if ! pf_has 'MANUAL_EOF_RC=1' || ! pf_has 'No answer — treating this step as skipped.'; then
    fail_case "$name" "print_and_wait did not fail closed, out loud, at EOF"; return
  fi
  if [ -e "$marker" ]; then
    fail_case "$name" "an unanswered print_and_wait ran the displayed command"; return
  fi
  # Under a pipe `read -r -p` prints nothing, so these lines can only have come from
  # prompt_echo. Without it a machine driver sees a menu and then silence.
  if ! pf_has 'Free (Enter = the-default; i = explain; q = stop):' ||
     ! pf_has 'Choose 1-2 (Enter = ask again; i = explain; q = stop):' ||
     ! pf_has 'Consent [y/N] (Enter = No; i = explain; q = stop):'; then
    fail_case "$name" "a prompt was invisible under a pipe — prompt_echo did not re-emit it"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# --- print_and_wait: Enter means No, exactly as it does at every confirm ---
# This prompt and a mutation gate sit six lines apart in the gateway step. If Enter
# here asserted "yes, I already ran your command", anybody in Enter-rhythm would
# claim to have applied a config change they never applied — and the tool would then
# diagnose the resulting failure as a gateway fault. The marker file proves the other
# half: the displayed command is never executed for you.
prompt_sub_print_and_wait() {
  local name="prompt-and-wait-enter-is-no" marker="$TMP/prompt-manual-ran"
  : > "$TMP/doctor.out"; rm -f "$marker"
  prompt_fixture $'bogus\ni\n\ny\n' '
if print_and_wait "fixture.manual" "fixture manual action" "touch $MANUAL_MARKER"; then
  printf "MANUAL1=acknowledged\n"; else printf "MANUAL1=skipped rc=%s\n" "$?"; fi
if print_and_wait "fixture.manual" "fixture manual action" "touch $MANUAL_MARKER"; then
  printf "MANUAL2=acknowledged\n"; else printf "MANUAL2=skipped rc=%s\n" "$?"; fi
'
  prompt_stage "$name" print_and_wait || return
  if [ "$PF_RC" != "0" ]; then
    fail_case "$name" "the print_and_wait fixture exited $PF_RC, expected 0"; return
  fi
  if ! pf_has 'Did you run it? [y/N] (Enter = No, skip; i = explain; q = stop)'; then
    fail_case "$name" "print_and_wait's suffix no longer says Enter skips"; return
  fi
  if ! pf_has 'INFO fixture.manual'; then
    fail_case "$name" "i at print_and_wait did not explain"; return
  fi
  if ! pf_has 'MANUAL1=skipped rc=1'; then
    fail_case "$name" "Enter at print_and_wait claimed the command had been run"; return
  fi
  if ! pf_has 'MANUAL2=acknowledged'; then
    fail_case "$name" "y at print_and_wait was not taken as an acknowledgement"; return
  fi
  if [ -e "$marker" ]; then
    fail_case "$name" "print_and_wait executed the command it only meant to display"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# --- the q ROW of the contract, across all five captured primitives at once ---
# The row every other sub-case only samples: q at a value prompt returns 11 with an
# EMPTY answer and does not stop anything itself. It cannot: all five are captured
# with $(…), so an exit or a die inside one kills the subshell and the wizard walks
# on with a blank value — the single behaviour this whole contract was rebuilt to
# remove. AFTER_ALL below is the proof that the parent survived all five.
#
# The other half is the emptiness. There is no `q` sentinel on stdout any more and
# there must never be one again: a gateway genuinely called "q" is a legal answer,
# and the release where the stop key and the answer were the same string minted the
# permanent id custom-q — the id the systemd unit, the credential file and the saved
# profile were all filed under.
prompt_sub_q_every_value() {
  local name="prompt-q-status-at-every-value-primitive"
  : > "$TMP/doctor.out"
  # q, then n to decline the literal question at the two free-text prompts; ask_url,
  # ask_secret and require_choice never bargain, so their q is one keystroke.
  prompt_fixture $'q\nn\nq\nn\nq\nq\nq\n' '
a=$(ask "Free" "" "leave blank" "fixture.value");            printf "QASK=[%s] rc=%s\n" "$a" "$?"
d=$(ask_default "Defaulted" "dflt" "fixture.value");         printf "QDEF=[%s] rc=%s\n" "$d" "$?"
u=$(ask_url "Address" "https://ai.example.com" 0 "" "fixture.value"); printf "QURL=[%s] rc=%s\n" "$u" "$?"
s=$(ask_secret "Secret" "leave empty" "fixture.secret");     printf "QSEC=[%s] rc=%s\n" "$s" "$?"
c=$(require_choice "Choose 1-2" "^[12]$" "fixture.choice");  printf "QCHOICE=[%s] rc=%s\n" "$c" "$?"
printf "AFTER_ALL=reached\n"
'
  prompt_stage "$name" 'q at every value primitive' || return
  if [ "$PF_RC" != "0" ]; then
    fail_case "$name" "a captured primitive stopped the process itself on q (exit $PF_RC) — only the caller may do that"; return
  fi
  if ! pf_has 'QASK=[] rc=11'; then
    fail_case "$name" "q at ask did not return status 11 with an empty answer"; return
  fi
  if ! pf_has 'QDEF=[] rc=11'; then
    fail_case "$name" "q at ask_default did not return status 11 with an empty answer"; return
  fi
  if ! pf_has 'QURL=[] rc=11'; then
    fail_case "$name" "q at ask_url did not return status 11 with an empty answer"; return
  fi
  if ! pf_has 'QSEC=[] rc=11'; then
    fail_case "$name" "q at ask_secret did not return status 11 with an empty answer"; return
  fi
  if ! pf_has 'QCHOICE=[] rc=11'; then
    fail_case "$name" "q at require_choice did not return status 11 with an empty answer"; return
  fi
  if ! pf_has 'AFTER_ALL=reached'; then
    fail_case "$name" "the caller did not survive q at all five captured primitives"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# --- the b ROW: a key is a control IF AND ONLY IF the suffix advertises it ---
# Both directions, at every primitive that can offer Back, because both failures are
# real and they point opposite ways. Honouring b where it was never advertised
# discards an answer the operator meant literally; refusing it where the suffix
# promised it strands them at the one step that was supposed to be reversible.
#
# The three primitives answer an unadvertised b differently, and that is by design,
# not drift: at a FREE-TEXT prompt "b" is a plausible value so it is taken as data,
# while at a URL prompt and at a numbered choice nothing that spells b can ever be a
# legal answer, so it is refused out loud and re-asked.
prompt_sub_back_advertised() {
  local name="prompt-back-only-where-advertised"
  : > "$TMP/doctor.out"
  # b,n (backable default) · b (plain default, data) · b (backable URL) ·
  # b,URL (plain URL, refused then answered) · b,1 (choice, refused then answered)
  prompt_fixture $'b\nn\nb\nb\nb\nhttps://ai.example.com\nb\n1\n' '
d1=$(ask_default "Backable default" "dflt" "fixture.value" true); printf "DBACK=[%s] rc=%s\n" "$d1" "$?"
d2=$(ask_default "Plain default" "dflt" "fixture.value");         printf "DPLAIN=[%s] rc=%s\n" "$d2" "$?"
u1=$(ask_url "Backable address" "https://ai.example.com" 0 "" "fixture.value" true); printf "UBACK=[%s] rc=%s\n" "$u1" "$?"
u2=$(ask_url "Plain address" "https://ai.example.com" 0 "" "fixture.value");         printf "UPLAIN=[%s] rc=%s\n" "$u2" "$?"
c=$(require_choice "Choose 1-2" "^[12]$" "fixture.choice");       printf "CPLAIN=[%s] rc=%s\n" "$c" "$?"
'
  prompt_stage "$name" 'b only where advertised' || return
  if [ "$PF_RC" != "0" ]; then
    fail_case "$name" "the back-contract fixture exited $PF_RC, expected 0 — it never reached the last prompt"; return
  fi
  # Advertised, at each of the two primitives that can offer it.
  if ! pf_has '(or type a value; i = explain; b = back; q = stop)'; then
    fail_case "$name" "a back-capable ask_default did not advertise b in its suffix"; return
  fi
  if ! pf_has 'DBACK=[] rc=10'; then
    fail_case "$name" "b at a back-capable ask_default did not return status 10 with no value"; return
  fi
  if ! pf_has 'Enter = ask again; i = explain; b = back; q = stop'; then
    fail_case "$name" "a back-capable ask_url did not advertise b in its suffix"; return
  fi
  if ! pf_has 'UBACK=[] rc=10'; then
    fail_case "$name" "b at a back-capable ask_url did not return status 10 with no value"; return
  fi
  # …and NOT advertised: same key, same release, three refusals that each fit the
  # prompt they belong to.
  if ! pf_has '(or type a value; i = explain; q = stop)'; then
    fail_case "$name" "an ordinary ask_default advertised a b it does not honour"; return
  fi
  if ! pf_has 'DPLAIN=[b] rc=0'; then
    fail_case "$name" "b at a free-text prompt that never offered it was taken as a control instead of as data"; return
  fi
  if ! pf_has 'Back is not available at this step; type an https:// URL'; then
    fail_case "$name" "b at an ask_url that does not offer it was not refused out loud"; return
  fi
  if ! pf_has 'UPLAIN=[https://ai.example.com] rc=0'; then
    fail_case "$name" "the refused b did not leave ask_url asking for a real address"; return
  fi
  if ! pf_has 'Back is not available at this step; choose one of the options above'; then
    fail_case "$name" "b at a require_choice that does not offer it was not refused out loud"; return
  fi
  if ! pf_has 'CPLAIN=[1] rc=0'; then
    fail_case "$name" "the refused b did not leave require_choice asking for a real option"; return
  fi
  # Exactly once, at the ONE prompt where b is both advertised and ambiguous. A URL
  # prompt and a numbered choice have no answer that spells b, so bargaining there
  # would be a question with only one possible answer.
  if [ "$(pf_count 'as your answer instead of going back')" != "1" ]; then
    fail_case "$name" "the literal-b question was asked somewhere other than the one free-text prompt that offers b"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# --- the two prompts that are NOT captured, and therefore act on q themselves ---
# confirm and print_and_wait are called as commands, not inside $(…), so they are the
# only prompts in the tool that can and must call quit_run directly. The asymmetry is
# load-bearing in the other direction too: if either ever started RETURNING 11 like a
# value primitive, every `if confirm …; then` site would read that nonzero as "No" and
# the run would walk straight past a stop the operator asked for — silently, because a
# declined gate looks exactly like a normal answer.
prompt_sub_uncaptured_q() {
  local name="prompt-uncaptured-q-stops-the-run" marker="$TMP/prompt-manual-ran"
  : > "$TMP/doctor.out"; rm -f "$marker"
  prompt_fixture $'q\n' '
confirm "Fixture confirmation" "fixture.confirm"
printf "CONFIRM_AFTER_Q=reached rc=%s\n" "$?"
'
  prompt_stage "$name" 'confirm q' || return
  if [ "$PF_RC" != "3" ]; then
    fail_case "$name" "q at a confirm exited $PF_RC, expected 3 (the operator stopped)"; return
  fi
  if pf_has 'CONFIRM_AFTER_Q=reached'; then
    fail_case "$name" "q at a confirm returned a status to the caller instead of ending the run"; return
  fi
  if ! pf_has 'Stopped here. No further setup actions will run.'; then
    fail_case "$name" "stopping at a confirm did not print the setup ending"; return
  fi
  prompt_fixture $'q\n' '
print_and_wait "fixture.manual" "fixture manual action" "touch $MANUAL_MARKER"
printf "MANUAL_AFTER_Q=reached rc=%s\n" "$?"
'
  prompt_stage "$name" 'print_and_wait q' || return
  if [ "$PF_RC" != "3" ]; then
    fail_case "$name" "q at a print_and_wait exited $PF_RC, expected 3 (the operator stopped)"; return
  fi
  if pf_has 'MANUAL_AFTER_Q=reached'; then
    fail_case "$name" "q at a print_and_wait returned a status to the caller instead of ending the run"; return
  fi
  if [ -e "$marker" ]; then
    fail_case "$name" "a print_and_wait the operator stopped at still ran the command it only meant to display"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

run_prompt_controls_cases() {
  local sub any=false
  for sub in $PROMPT_SUBCASES; do
    if prompt_case_wanted "$sub"; then any=true; break; fi
  done
  [ "$any" = true ] || return 0
  prompt_controls_lift || return 0
  prompt_case_wanted prompt-confirm-controls            && prompt_sub_confirm
  prompt_case_wanted prompt-require-choice-retry        && prompt_sub_require_choice
  prompt_case_wanted prompt-require-choice-q-status     && prompt_sub_require_choice_q
  prompt_case_wanted prompt-into-q-stops-the-process    && prompt_sub_into_q
  prompt_case_wanted prompt-into-b-returns-back         && prompt_sub_into_back
  prompt_case_wanted prompt-into-eof-dies               && prompt_sub_into_eof
  prompt_case_wanted prompt-literal-answer-confirmation && prompt_sub_literal_values
  prompt_case_wanted prompt-literal-declined-falls-through && prompt_sub_literal_declined
  prompt_case_wanted prompt-secret-controls             && prompt_sub_secret
  prompt_case_wanted prompt-default-and-resolved-echo   && prompt_sub_default
  prompt_case_wanted prompt-eof-at-every-primitive      && prompt_sub_eof_all
  prompt_case_wanted prompt-and-wait-enter-is-no        && prompt_sub_print_and_wait
  prompt_case_wanted prompt-q-status-at-every-value-primitive && prompt_sub_q_every_value
  prompt_case_wanted prompt-back-only-where-advertised  && prompt_sub_back_advertised
  prompt_case_wanted prompt-uncaptured-q-stops-the-run  && prompt_sub_uncaptured_q
  return 0
}

# A syntactically valid port can still be the wrong server. The review screen is
# the last mutation-free place to catch that mistake, so b must clear the draft,
# collect it again, and carry only the corrected value into the exposure step.
run_custom_review_back_case() {
  local name="custom-review-back-corrects-port" rc=0 review_count
  local home="$TMP/custom-review-home" state="$TMP/custom-review-state"
  mkdir -p "$home" "$state"
  PTY_ENV=(HOME="$home" XDG_CONFIG_HOME="$state")
  # Per pass: name, n = no https URL, t, the port, 2 = keyless (the auth question is
  # a numbered choice under --dry-run, which never solicits a real token), Enter
  # = no model, then b / Enter at the review. A final q stops in Step 3.
  #
  # The `t` before each port answer is what makes this case machine-independent. The
  # port step now offers a numbered list of whatever is LISTENING on this host first,
  # and that list exists on a developer laptop and not on a clean runner — so a bare
  # "1111" answers the picker on one machine and the typed prompt on the other, and
  # every later keystroke lands one prompt out of step. `t` takes the "type it
  # myself" row when there IS a list, and is a silent no-op at the typed prompt when
  # there is not. That property exists so this case can be written once.
  pty_run 10 $'Wrong gateway\nn\nt\n1111\n2\n\nb\nCorrected gateway\nn\nt\n2222\n2\n\n\nq\n' \
    --generic --dry-run > "$TMP/doctor.out" 2>&1 || rc=$?

  review_count=$(grep -c 'Review this gateway' "$TMP/doctor.out")
  # 3, not 0: the final `q` lands at the exposure menu — mid-flow, after the
  # operator has answered real questions — and a run abandoned there is exactly
  # what exit 3 is for. A wrapper that read this as 0 would record an aborted
  # setup as a completed pairing.
  if [ "$rc" != "3" ] || [ "$review_count" != "2" ] ||
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

# THE regression this release exists to prevent, at the real call site rather than at
# a fixture. "A short name for it (shown in the app)" is a free-text prompt whose
# answer becomes a permanent id: press q there in the old release and the gateway was
# NAMED q, filed forever under `custom-q`, and the systemd unit, the credential file
# and the saved profile all inherited it — discovered weeks later by somebody who
# never typed a name.
#
# Two lanes, one keystroke apart, and the pair is the assertion. `Filed under:
# custom-q` must be ABSENT when the operator declines the literal question (they meant
# to stop) and PRESENT when they confirm it (they meant the letter). Neither half
# means anything alone: the absence needs the lane that proves the string can appear
# here at all, and the presence needs the lane that proves it is not the default
# reading of a q.
#
# --dry-run because the point is what the wizard DECIDES, not what it writes; the
# state assertion below then also covers the dry-run contract of writing nothing.
run_custom_name_q_case() { # run_custom_name_q_case <declined|confirmed>
  local lane="$1" name rc=0 asked
  local home="$TMP/name-q-$lane-home" state="$TMP/name-q-$lane-state"
  mkdir -p "$home" "$state"
  PTY_ENV=(HOME="$home" XDG_CONFIG_HOME="$state")
  if [ "$lane" = declined ]; then
    name="custom-name-q-declined-stops-the-run"
    # q, then n: "no, I did not mean the letter" — which is the Enter default too.
    pty_run 10 $'q\nn\n' --generic --dry-run > "$TMP/doctor.out" 2>&1 || rc=$?
  else
    name="custom-name-q-confirmed-is-the-name"
    # q, y, then an ordinary custom-server pass: n = no https URL yet, t = type the
    # port myself (a silent no-op when this host offers no listening-port list —
    # same machine-independence trick as custom-review-back-corrects-port), the
    # port, 2 = keyless, Enter = no model, Enter = accept the review, q = stop in
    # Step 3 once the name has been carried the whole way.
    pty_run 15 $'q\ny\nn\nt\n1111\n2\n\n\nq\n' --generic --dry-run > "$TMP/doctor.out" 2>&1 || rc=$?
  fi

  # Asked, and asked ONCE. A prompt that re-bargained on every later question would
  # train the operator to type y without reading it.
  asked=$(grep -c 'Use "q" as your answer instead of stopping the run?' "$TMP/doctor.out")
  if [ "$asked" != "1" ]; then
    fail_case "$name" "the literal-q question was asked $asked times at the name prompt, expected 1"; return
  fi
  # Both lanes reach the naming step — without this the id assertions below are
  # vacuous, because a run that never named anything also never files anything.
  if ! grep -qF 'A short name for it (shown in the app)' "$TMP/doctor.out"; then
    fail_case "$name" "the run never reached the prompt whose answer becomes the id"; return
  fi
  if [ "$lane" = declined ]; then
    if [ "$rc" != "3" ]; then
      fail_case "$name" "a declined literal q exited $rc, expected 3 (the operator stopped)"; return
    fi
    if grep -qF 'Filed under:    custom-q' "$TMP/doctor.out"; then
      fail_case "$name" "q at the name prompt minted the permanent id custom-q — the exact regression"; return
    fi
    if grep -qF 'Step 3 — how should your phone reach this gateway?' "$TMP/doctor.out"; then
      fail_case "$name" "a stop at the name prompt carried on into the exposure step"; return
    fi
    if ! grep -qF 'Stopped here. No further setup actions will run.' "$TMP/doctor.out"; then
      fail_case "$name" "a declined literal q did not end the run the way an operator stop ends it"; return
    fi
  else
    if [ "$rc" != "3" ]; then
      fail_case "$name" "the confirmed-literal pass exited $rc, expected 3 from the q in Step 3"; return
    fi
    if ! grep -qF 'Name:           q' "$TMP/doctor.out"; then
      fail_case "$name" "a confirmed literal q was not accepted as the gateway's name"; return
    fi
    if ! grep -qF 'Filed under:    custom-q' "$TMP/doctor.out"; then
      fail_case "$name" "the confirmed name did not reach the id the profile and service files use"; return
    fi
    if ! grep -qF 'Step 3 — how should your phone reach this gateway?' "$TMP/doctor.out"; then
      fail_case "$name" "the confirmed name did not survive the review into the exposure step"; return
    fi
  fi
  if [ -n "$(find "$home" "$state" -type f -print -quit 2>/dev/null)" ]; then
    fail_case "$name" "a dry run wrote a file"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

run_menu_setup_case() {
  local name="menu-action-1-setup" rc=0
  local home="$TMP/menu-setup-home" state="$TMP/menu-setup-state"
  # 1 = setup, 3 = another server, Enter = default name, n = local, t, Enter =
  # blank port (an advertised no-op that re-asks), q = deliberate stop.
  #
  # `t` is here for the same reason as in custom-review-back-corrects-port: the
  # port step offers a list of whatever is LISTENING first, and that list exists
  # on a developer laptop and not on a clean runner. `t` takes the "type it
  # myself" row when there is a list and is a silent no-op at the typed prompt
  # when there is not, so the keystrokes after it line up on either machine.
  mkdir -p "$home" "$state"
  PTY_ENV=(HOME="$home" XDG_CONFIG_HOME="$state")
  # The final Enter answers `Enter = stop; m = back to the menu`: a run stopped
  # from inside the hub offers the way back rather than ending the session, and
  # Enter takes the stop.
  pty_run 10 $'1\n3\n\nn\nt\n\nq\n\n' > "$TMP/doctor.out" 2>&1 || rc=$?
  # 3: q mid-setup is an abandoned run, and the hub propagates the action's own
  # status rather than swallowing it — the whole reason a wrapper can tell an
  # aborted setup from a finished one.
  if [ "$rc" != "3" ] ||
     ! grep -qF 'Step 1 — find your gateway' "$TMP/doctor.out" ||
     ! grep -qF 'Step 2 — your OpenAI-compatible server' "$TMP/doctor.out" ||
     ! grep -qF 'Nothing entered — a server running on this machine needs its port number.' "$TMP/doctor.out" ||
     ! grep -qF 'Stopped here. No further setup actions will run.' "$TMP/doctor.out"; then
    fail_case "$name" "menu option 1 did not retry the blank port and stop cleanly"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# The safety invariant: finding OpenClaw on this machine must never make Enter
# MEAN OpenClaw. A detected gateway is evidence offered to the operator, not a
# default applied on their behalf, and the cost of getting it wrong is a wizard
# that reconfigures the wrong program without being asked to.
#
# Every condition below gets its OWN failure message, and that is the point of
# this case's history rather than a style preference. It used to test five
# unrelated things through one `||` chain with one message ("a detected gateway
# was treated as an Enter default"). When the exit status of a deliberate stop
# changed from 0 to 3, this case went red with that sentence — which reads as the
# safety invariant breaking, and is not what happened. One message covering five
# conditions cannot tell you which one moved, and the one it names is the one
# somebody will act on.
run_detected_requires_choice_case() {
  local name="setup-detected-still-requires-choice" rc=0 home="$TMP/detected-home"
  mkdir -p "$home/.openclaw"
  printf '{}\n' > "$home/.openclaw/openclaw.json"
  # Blank at the gateway question must re-prompt even though OpenClaw is found;
  # 3 then proves the user can deliberately configure another server. `t` absorbs
  # the listening-ports picker on a machine that has one (see menu-action-1-setup).
  PTY_ENV=(HOME="$home")
  pty_run 10 $'\n3\n\nn\nt\n\nq\n' --setup > "$TMP/doctor.out" 2>&1 || rc=$?

  # THE invariant, asserted first and alone, so it is graded whatever else moved.
  if grep -qF 'Step 2 — OpenClaw' "$TMP/doctor.out"; then
    fail_case "$name" "blank input silently selected the detected OpenClaw"; return
  fi
  if ! grep -qF 'We found these on this machine: openclaw' "$TMP/doctor.out"; then
    fail_case "$name" "the run never reported the detection — the invariant above is untested"; return
  fi
  # Blank at a no-default choice is a PAUSE, not an error: the operator is told
  # the options are still there rather than told off. A run that answered the
  # blank with a selection would print neither.
  if ! grep -qF 'Nothing chosen — the options are above.' "$TMP/doctor.out"; then
    fail_case "$name" "a blank answer at the gateway question was not re-asked"; return
  fi
  if ! grep -qF 'Step 2 — your OpenAI-compatible server' "$TMP/doctor.out"; then
    fail_case "$name" "answering 3 after the blank did not reach custom-server setup"; return
  fi
  if ! grep -qF 'Stopped here. No further setup actions will run.' "$TMP/doctor.out"; then
    fail_case "$name" "q did not stop the wizard cleanly"; return
  fi
  # Last, because it is the weakest claim of the five and the one most likely to
  # be re-decided: 3 = the operator stopped a run partway.
  if [ "$rc" != "3" ]; then
    fail_case "$name" "a deliberate stop mid-setup exited $rc, expected 3"; return
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
  local input state="$TMP/menu-check-$kind-state"
  mkdir -p "$state"
  # The trailing Enter answers the hub: an action entered from the menu ends by
  # OFFERING the menu again ("Enter = done; m = back to the menu"), and Enter is
  # "done". Without it this case would sit at that question until the PTY timeout
  # and report a hang as a failed check.
  input="$choice"$'\nhttp://127.0.0.1:'"$PORT"$'\nn\n\n'
  PTY_ENV=(CONDUCK_TOKEN="$TOKEN" XDG_CONFIG_HOME="$state")
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
  # The provenance decision, plus the word that stops a first-timer reading three
  # equal-looking options and picking the wrong one. "Diagnostic; changes nothing"
  # is the only thing on the list that says an option is safe to try.
  if ! grep -qF '2) Check a server that was NOT built for Conduck (diagnostic; changes nothing)' "$TMP/doctor.out" ||
     ! grep -qF '3) Check an adapter built for Conduck (diagnostic; changes nothing)' "$TMP/doctor.out"; then
    fail_case "$name" "the menu did not state the built-for-Conduck provenance decision"; return
  fi
  # The hub really did offer to come back, rather than the run simply ending.
  if ! grep -qF 'Enter = done; m = back to the menu' "$TMP/doctor.out"; then
    fail_case "$name" "an action entered from the menu did not end by offering the menu again"; return
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
  # 4, then Enter at the hidden token prompt. Enter there is the ADVERTISED stop
  # ("Enter = stop; this saved setup requires a token"), which is a better subject
  # than an EOT: it grades the meaning the prompt printed rather than the shell's
  # end-of-input, and it is what an operator who does not have the token to hand
  # actually presses.
  pty_run 10 $'4\n\n' > "$TMP/doctor.out" 2>&1 || rc=$?
  if [ "$rc" = "0" ] ||
     ! grep -qF '4) Show a saved setup code' "$TMP/doctor.out"; then
    fail_case "$name" "menu did not offer option 4 for a complete saved profile"; return
  fi
  # DISPATCH, not menu text: this heading is printed only by the --show-code path.
  # "setup code" is the app's word for the thing and the only one used here — the
  # screen and the menu entry that opens it once disagreed one keystroke apart.
  if ! grep -qF 'Re-show a saved setup code — skips setup and changes no configuration' "$TMP/doctor.out"; then
    fail_case "$name" "menu option 4 did not dispatch the --show-code path"; return
  fi
  if grep -qiF 'pairing code' "$TMP/doctor.out"; then
    fail_case "$name" "the show-code screen called it a pairing code, a term the app never uses"; return
  fi
  if ! grep -qF 'Using saved profile: custom (Good gateway) → https://good.example.test' "$TMP/doctor.out"; then
    fail_case "$name" "the complete profile was not loaded before the controlled token stop"; return
  fi
  # The key is deliberately not on disk, so re-showing a code for a bearer
  # gateway has to ask for it — and no answer is a hard stop, never a silent
  # keyless code. This is the fail-closed rule in words, then in behaviour.
  if ! grep -qF 'this saved setup requires a key' "$TMP/doctor.out"; then
    fail_case "$name" "the key prompt no longer says the saved setup requires one"; return
  fi
  if ! grep -qF 'A key is required (this saved setup says auth=bearer)' "$TMP/doctor.out"; then
    fail_case "$name" "an unanswered key prompt did not stop the re-show"; return
  fi
  # …and it stopped BEFORE emitting anything. A code minted here would be a
  # keyless one for a gateway whose profile says it needs a bearer token.
  if grep -qF 'conduck-setup:v1:' "$TMP/doctor.out"; then
    fail_case "$name" "a setup code was printed even though the token was never supplied"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# The other half of the gate: a profile that EXISTS but doesn't parse as schema 1
# must not be advertised as a setup code. Offering it would hand the user a menu
# entry that hard-errors the moment it is chosen.
#
# It must still be VISIBLE, though, and that is the second half of this case. A
# file this version cannot read is exactly the thing somebody wants to look at
# and get rid of, so the entries that work on the saved files themselves are
# offered for a profile that merely exists — parsed or not. Going quiet about it
# is what turns an unreadable profile into a lost one: the operator reads "no
# saved code", picks 1, and setup overwrites the file.
#
# So the menu's numbering here is 1-5 with no show-code row, and pressing 4 opens
# the inventory. The assertions below are about WHICH ACTION each number reaches,
# because that is the thing a stale number silently changes.
assert_menu_hides_show_code() { # assert_menu_hides_show_code <case-name> <what>
  local name="$1" what="$2"
  # The NUMBERED ROW, anchored — not the bare phrase. The header's warning about
  # an unreadable profile quotes the entry by name ("…so \"Show a saved setup
  # code\" is not on the list below"), and a substring match there would read the
  # explanation of the option's absence as the option being present.
  if grep -qE '^ +[0-9]+\) Show a saved setup code' "$TMP/doctor.out"; then
    fail_case "$name" "the menu offered a setup code for $what"; return 1
  fi
  # The dispatch, not the menu text. This heading belongs to the --show-code
  # screen and to nothing else, so its absence is proof the number that was
  # pressed did not reach it.
  if grep -qF 'Re-show a saved setup code' "$TMP/doctor.out"; then
    fail_case "$name" "a menu number dispatched --show-code for $what"; return 1
  fi
  return 0
}

run_menu_corrupt_profile_case() {
  local name="menu-corrupt-profile-hides-show-code" rc=0 state="$TMP/corrupt-state"
  mkdir -p "$state/conduck"
  printf '{}\n' > "$state/conduck/profile-invalid.json"
  PTY_ENV=(XDG_CONFIG_HOME="$state")
  # 4, then Enter at the hub's closing "Enter = done; m = back to the menu".
  pty_run 10 $'4\n\n' > "$TMP/doctor.out" 2>&1 || rc=$?
  assert_menu_hides_show_code "$name" "a profile it cannot parse" || return
  if ! grep -qF '4) See what this machine already has set up' "$TMP/doctor.out"; then
    fail_case "$name" "the inventory entry is not what number 4 offers here"; return
  fi
  # The warning above the list, which is the whole reason an unreadable profile is
  # still surfaced: it says the file exists, that this version cannot read it, and
  # that setting up again would replace it.
  if ! grep -qF "There IS a saved setup code on this machine, and this version can't read it" "$TMP/doctor.out"; then
    fail_case "$name" "an unreadable profile was hidden instead of being reported"; return
  fi
  if ! grep -qF 'Setting up again REPLACES the saved file' "$TMP/doctor.out"; then
    fail_case "$name" "the warning did not say what choosing 1 would cost"; return
  fi
  # …and 4 really did open the inventory, which names the unreadable id.
  if ! grep -qF 'Saved here but not usable by this version' "$TMP/doctor.out"; then
    fail_case "$name" "4 did not open the inventory that lists the unreadable profile"; return
  fi
  if [ "$rc" != "0" ]; then
    fail_case "$name" "looking at what is saved exited $rc — reading is not a failure"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# A valid JSON file with schemaVersion=1 is still unusable when its required
# routing fields are absent. It must be filtered at the same gate as malformed
# JSON, not advertised and rejected only after the user picks it.
run_menu_partial_profile_case() {
  local name="menu-partial-profile-hides-show-code" rc=0 state="$TMP/partial-state"
  mkdir -p "$state/conduck"
  printf '{"schemaVersion":1,"gateway":{},"fileServer":null}\n' \
    > "$state/conduck/profile-partial.json"
  PTY_ENV=(XDG_CONFIG_HOME="$state")
  pty_run 10 $'4\n\n' > "$TMP/doctor.out" 2>&1 || rc=$?
  assert_menu_hides_show_code "$name" "a partial schema-1 profile" || return
  if ! grep -qF '4) See what this machine already has set up' "$TMP/doctor.out"; then
    fail_case "$name" "the inventory entry is not what number 4 offers here"; return
  fi
  if [ "$rc" != "0" ]; then
    fail_case "$name" "looking at what is saved exited $rc — reading is not a failure"; return
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
  if ! grep -qF 'Which one? Choose 1-2' "$TMP/doctor.out" ||
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
  pty_run 10 $'4\n\n' > "$TMP/doctor.out" 2>&1 || rc=$?
  assert_menu_hides_show_code "$name" "a custom Tailscale/Funnel profile without localPort" || return

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
  pty_run 10 $'4\n\n' > "$TMP/doctor.out" 2>&1 || rc=$?
  assert_menu_hides_show_code "$name" "a profile pinning a self-signed certificate" || return

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
' 2>&1
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

  # classify_own_https opens with warn_quick_tunnel_url on EVERY path, so the two
  # come along or the gate runs with its first line undefined.
  funcs=$(extract_funcs classify_own_https warn_quick_tunnel_url is_quick_tunnel_url)
  if [ -z "$funcs" ] || ! printf '%s\n' "$funcs" | grep -qF 'classify_own_https()'; then
    fail_case "$name" "could not extract classify_own_https from the release artifact"; return
  fi

  # A certificate this machine trusts is the ONLY way through. curl exit 0.
  rc=0
  out=$(run_classify_own_https_isolated "$funcs" 0 0 "") || rc=$?
  printf -- '--- trusted certificate ---\n%s\n' "$out" > "$TMP/doctor.out"
  assert_runtime_defined "$name" "$out" || return
  if [ "$rc" != "0" ] || ! printf '%s\n' "$out" | grep -qF 'TRANSPORT=public'; then
    fail_case "$name" "a trusted certificate did not continue setup on the public transport"; return
  fi

  # curl 60 = the peer certificate could not be authenticated. Verify code 18 is
  # "self-signed certificate" — the exact case that used to be pinned.
  rc=0
  out=$(run_classify_own_https_isolated "$funcs" 60 18 "") || rc=$?
  printf -- '--- untrusted (self-signed) certificate ---\n%s\n' "$out" >> "$TMP/doctor.out"
  assert_runtime_defined "$name" "$out" || return
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

  # The menu reaches its choice through prompt_into + require_choice, and those two
  # pull in the whole prompt contract (the suffix renderer, the echo, the literal
  # disambiguator, and quit_run for the q arm). Lift the lot: without prompt_into
  # this case cannot obtain a choice AT ALL, and every assertion below it becomes a
  # statement about an empty string.
  funcs=$(extract_funcs choose_exposure explain_exposure_paths explain_prompt \
            require_choice prompt_into control_suffix control_keys prompt_echo \
            prompt_wants_literal value_prompt_control \
            looks_like_a_secret warn_answer_looked_like_a_secret \
            quit_run run_changes_nothing interactive_terminal \
            exposure_tailscale_ready exposure_cloudflared_ready explain_own_https_target
          sed -n '/^NO_ANSWER=/p' "$SCRIPT")
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
  assert_runtime_defined "$name" "$out" || return
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
  # Still an explicit choice with no default and no favourite — and the control list
  # is the PRIMITIVE's, rendered from the same argument that makes `b` work. There
  # is no hand-written control prose left to grep for, and there must not be: the one
  # prompt in this tool where Back genuinely works used to be the one whose own
  # control list denied it. `b = back` appearing here is therefore correct.
  prompt=$(printf '%s\n' "$out" | grep 'Choose 1-4')
  if [ -z "$prompt" ]; then
    fail_case "$name" "the menu prompt no longer asks for an explicit 1-4"; return
  fi
  if [ "$(printf '%s\n' "$prompt" | grep -cF 'Choose 1-4 (Enter = ask again; i = explain; b = back; q = stop)')" != "2" ]; then
    fail_case "$name" "i did not return to the same prompt, with the same advertised controls"; return
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

# The saved profile is the one file conduck-connect leaves on disk that must
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
  # json_query/json_type ride along too: write_profile asks them what the existing
  # profile holds before it decides what to keep.
  writer=$(extract_funcs write_profile ensure_state_dir file_mode_is_open json_query json_type)
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
    fail_case "$name" "the saved saved profile leaked a live token or file-lane credential"; return
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
    fail_case "$name" "the saved profile grew a token/credential-shaped key"; return
  fi

  # WHAT-IT-TOUCHES.md states this file is 0600. Nothing else asserts it.
  mode=$(ls -l "$prof" | cut -c1-10)
  if [ "$mode" != "-rw-------" ]; then
    fail_case "$name" "the saved profile is $mode, not 0600"; return
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
#
# emit_payload's call closure inside this harness lives in ONE list, on purpose.
# Five cases drive this same function, and the release that taught it to print
# explain_setup_code_secrecy updated none of their five separate lift lists — so all
# five ran with the tool's only "treat this code like a password" statement silently
# missing, while a case literally named "the warning states what the code is"
# reported a pass. Everything else emit_payload reaches is stubbed below.
EMIT_LIFT="emit_payload pairing_capability_summary build_pairing_payload_json
           b64_nowrap is_quick_tunnel_url explain_setup_code_secrecy
           gw_loopback_base priv_prefix have"
run_emit_payload_isolated() {
  FUNCS="$1" FS_URL_IN="$2" FS_CRED_IN="$3" GW_KIND_IN="${4:-custom}" \
  OS_IN="${5:-Darwin}" FS_UNIT_IN="${6:-}" LINGER_IN="${7:-on}" \
  GW_URL_IN="${8:-https://gw.example.test}" VF_IN="${9:-false}" \
  GW_PORT_IN="${10:-}" FS_PROOF_IN="${11:-proved}" bash -c '
eval "$FUNCS"
# The secrecy panel is say(), not warn(), but it is part of the same passage: it
# carries the two sentences the warn() lines deliberately do NOT repeat ("treat this
# code like a password", "no secret is written to disk"). Tag it so the warning case
# can grade the whole passage as one, and so its ABSENCE is visible — the panel is
# reached through a function call, which is exactly the kind of thing a stale lift
# list drops without changing any other line on screen.
SECRECY=false
original_secrecy=$(declare -f explain_setup_code_secrecy)
eval "${original_secrecy/explain_setup_code_secrecy/orig_explain_setup_code_secrecy}"
explain_setup_code_secrecy() { SECRECY=true; orig_explain_setup_code_secrecy; SECRECY=false; }
say()   { if [ "$SECRECY" = true ]; then printf "SECRECY %s\n" "$*"; else printf "%s\n" "$*"; fi; }
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
' 2>&1
}

# 0 when the warning block states the fact <regex> describes.
warning_states() { # warning_states <flattened-warning-block> <extended-regex>
  printf '%s\n' "$1" | grep -qiE "$2"
}

# The emitted warning is the only place a user is told what the code they are
# about to show around actually IS — a reusable key. SECURITY.md
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
  emit=$(extract_funcs $EMIT_LIFT)
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
  assert_runtime_defined "$name" "$out_files$out_bare" || return

  # Non-vacuous: both runs really reached the emit, not an early return.
  if ! printf '%s\n' "$out_files" | grep -qF 'conduck-setup:v1:' ||
     ! printf '%s\n' "$out_bare"  | grep -qF 'conduck-setup:v1:'; then
    fail_case "$name" "emit_payload printed no setup code — the warning below proves nothing"; return
  fi

  # The one place the tool ever says it. It is printed by emit_payload itself, so a
  # lift list that drops explain_setup_code_secrecy loses the whole statement while
  # every FACT assertion below still passes on the surrounding warn() block.
  local secrecy
  for secrecy in "$out_files" "$out_bare"; do
    if [ "$(printf '%s\n' "$secrecy" | grep -cF 'Treat this code like a password.')" != "1" ]; then
      fail_case "$name" "the success screen said 'treat this code like a password' other than exactly once"; return
    fi
    if ! printf '%s\n' "$secrecy" | grep -qF 'No secret is written to disk by this script'; then
      fail_case "$name" "the success screen stopped saying that no secret is saved on this machine"; return
    fi
  done

  # Grade the secrecy passage only — the warn() lines PLUS the panel between them,
  # which is one passage on screen even though it reaches the terminal through two
  # helpers. Flattened to one line so a fact stated across two wrapped lines still
  # matches. Grading only the warn() half would leave the sentences the panel owns
  # untested, which is how "treat this code like a password" went missing from every
  # run of this case without the case noticing.
  # The harness tag is stripped before flattening, so a fact that wraps across two
  # lines reads as one sentence here. Left in, every alternation below would have to
  # know where the line breaks fall — which is a verbatim assertion wearing a
  # regex's clothes, and it rots on the first reflow. Runs of whitespace collapse
  # for the same reason: the panel indents its continuation lines, so a phrase that
  # wraps arrives with three spaces in the middle of it.
  block_files=$(printf '%s\n' "$out_files" | grep -E '^(WARNLINE|SECRECY) ' | sed -E 's/^(WARNLINE|SECRECY) //' | tr '\n' ' ' | tr -s ' ')
  block_bare=$(printf '%s\n' "$out_bare" | grep -E '^(WARNLINE|SECRECY) ' | sed -E 's/^(WARNLINE|SECRECY) //' | tr '\n' ' ' | tr -s ' ')
  if [ -z "$block_files" ] || [ -z "$block_bare" ]; then
    fail_case "$name" "the pairing emit printed no warning at all"; return
  fi
  if ! printf '%s\n' "$out_files" | grep -q '^SECRECY ' ||
     ! printf '%s\n' "$out_bare" | grep -q '^SECRECY '; then
    fail_case "$name" "emit_payload no longer prints the secrecy panel at all"; return
  fi

  local b
  for b in "$block_files" "$block_bare"; do
    # FACT 1 — the code carries the gateway key, and that key is a secret.
    if ! warning_states "$b" 'key' ||
       ! warning_states "$b" 'like a password|is a secret|keep (it|them|these) secret'; then
      fail_case "$name" "the warning no longer names the gateway key as a secret"; return
    fi
    # FACT 2 — whoever ends up holding the code gets exactly the access the two
    # secrets in it give. This covers both halves of what used to be two facts
    # ("the holder gets the gateway's capabilities" and "handing it to a person
    # hands them the same access"); the passage now says them in one sentence, and
    # asserting them separately would only be asserting the same clause twice.
    # Every route by which somebody else comes to hold it counts as holding it —
    # that is the point of naming the photograph and the copy.
    if ! warning_states "$b" 'whoever holds|anyone who|the holder|photograph' ||
       ! warning_states "$b" 'your gateway (allows|permits|lets)|anything the gateway (allows|permits)|same access|(exactly )?the access (those|these)( two)? (secrets|credentials) give'; then
      fail_case "$name" "the warning no longer states that whoever holds the code gets that access"; return
    fi
    # FACT 3 — it stays valid until the credentials are changed at the gateway.
    # There is no expiry, and the code cannot be revoked on its own.
    if ! warning_states "$b" 'until you rotate|until you change (it|them)|until (that secret|those secrets|the key|the token) (is|are) rotated'; then
      fail_case "$name" "the warning no longer states the code works until the secrets are changed"; return
    fi
    # FACT 4 — where NOT to put it, concretely. A rule stated only in the abstract
    # ("keep it secret") is the one people obey right up to the moment they paste a
    # transcript into an issue, which is the commonest way one of these leaks.
    if ! warning_states "$b" 'do not paste|don.t paste' ||
       ! warning_states "$b" 'chat|issue|screenshot'; then
      fail_case "$name" "the warning no longer names the places the code must not be pasted"; return
    fi
    # FACT 5 — a shared key has no per-device revoke; rotation hits every
    # device on THAT key (a custom gateway may issue several, so not "every device").
    if ! warning_states "$b" '(cannot|can ?not|can.t) be (cut off|revoked|removed)( one at a time| individually| separately)?' ||
       ! warning_states "$b" 'every device (using|on|that uses) that (key|token)|all devices (using|on) that (key|token)'; then
      fail_case "$name" "the warning no longer states the shared-key revocation consequence"; return
    fi
  done

  # FACT 6 — the file-lane clause is CONDITIONAL. Present when the code really
  # carries the file-server password; absent when it does not, so the wizard
  # never claims a shared folder this run has no lane for.
  #
  # Both patterns name the FILE lane specifically. A bare `password` would also
  # match the shared secrecy panel's "the file password when file transfer is set
  # up", which is a statement about whatever the code happens to carry and is
  # printed on every run — the negative below would then fail every lane-less run
  # for saying something correct, and the usual repair for that is to delete the
  # assertion.
  if ! warning_states "$block_files" 'file[- ]server (password|credential)' ||
     ! warning_states "$block_files" 'shared folder'; then
    fail_case "$name" "a run WITH a file lane did not warn that the code carries the file-server password"; return
  fi
  if warning_states "$block_bare" 'file[- ]server (password|credential)|shared folder|file server'; then
    fail_case "$name" "a run WITHOUT a file lane still claimed a file-server password or shared folder"; return
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
  emit=$(extract_funcs $EMIT_LIFT)
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
  assert_runtime_defined "$name" "$out_custom$out_openclaw" || return

  # Non-vacuous: both runs really reached the emit, and the custom one really does
  # still offer the adapter grade — the thing the caveat below is about.
  if ! printf '%s\n' "$out_custom" | grep -qF 'conduck-setup:v1:' ||
     ! printf '%s\n' "$out_openclaw" | grep -qF 'conduck-setup:v1:'; then
    fail_case "$name" "emit_payload printed no setup code — the screen proves nothing"; return
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
  emit=$(extract_funcs $EMIT_LIFT)
  if [ -z "$emit" ] || ! printf '%s\n' "$emit" | grep -qF 'gw_loopback_base()'; then
    fail_case "$name" "could not extract emit_payload + gw_loopback_base from the release artifact"; return
  fi
  : > "$TMP/doctor.out"

  # FAILURE screen, local port known — the arm that used to hand out the loopback trap.
  out=$(run_emit_payload_isolated "$emit" "" "" custom Darwin "" on \
        "https://gw.example.test" true 11434)
  printf -- '--- failed run, local port known ---\n%s\n' "$out" >> "$TMP/doctor.out"
  assert_runtime_defined "$name" "$out" || return
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
    fail_case "$name" "the success arm printed no setup code — the screen proves nothing"; return
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
# for: Linux, a conduck-connect-owned unit, lingering actually off.
run_pairing_linger_caveat_case() {
  local name="pairing-code-restates-the-logout-caveat"
  local emit out flat arm
  emit=$(extract_funcs $EMIT_LIFT)
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
    assert_runtime_defined "$name" "$out" || return
    # Non-vacuous: the screen really was emitted, so an absent caveat means absent.
    if ! printf '%s\n' "$out" | grep -qF 'conduck-setup:v1:'; then
      fail_case "$name" "[$arm] emit_payload printed no setup code"; return
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
  emit=$(extract_funcs $EMIT_LIFT)
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
    assert_runtime_defined "$name" "$out" || return
    if ! printf '%s\n' "$out" | grep -qF 'conduck-setup:v1:'; then
      fail_case "$name" "[$arm] emit_payload printed no setup code"; return
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
#   image-gate: pass|block — what the image gate decides. STUBBED here, and it must
#     be: this harness lifts verify_all alone, and the real gate needs the whole
#     probe/evaluator chain plus a server willing to answer a picture. Its own
#     outcome table is proved against live fixtures in run_image_gate_case; what
#     the stub buys is (a) silence — an unstubbed call would be "command not
#     found" on every arm, and a case can go green through that — and (b) the one
#     thing only this harness can show: what verify_all does AFTER the gate blocks.
#
# verify_all's call closure inside this harness, in ONE list. The three cases that
# drive it kept three different lists, and the diagnosis functions a failure reaches
# (the 403 route note, the 5xx credential note) were in some of them and not others —
# so an arm could take a branch whose entire explanation was an undefined function,
# and still be graded green on the sentences it did print.
VERIFY_LIFT="verify_all gw_url_drift_note gw_403_route_note gw_5xx_credential_note
             gw_loopback_base"
run_verify_all_isolated() {
  FUNCS="$1" TRANSPORT_IN="$2" MRC="$3" MCODE="$4" MCURL="$5" LOOP="$6" \
  LPORT="$7" CHAT="$8" FSU="$9" FSC="${10}" SQ="${11}" \
  GWAUTH="${12:-bearer}" LB2XX="${13:-no}" IMGGATE="${14:-pass}" bash -c '
eval "$FUNCS"
# Stubbed rather than lifted: the quota warning is the live-verification step
# introducing itself, and these cases grade the DIAGNOSIS the step reaches. Lifting
# it would put eleven lines of unrelated prose in front of every assertion here.
explain_live_verification() { :; }
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
verify_image_intake() {
  # Mirrors the real gate on the one property this harness grades: it is silent
  # and spends nothing once verification has already failed.
  $VERIFY_FAILED && return 0
  printf "IMAGE-GATE %s\n" "$IMGGATE"
  [ "$IMGGATE" = "block" ] && VERIFY_FAILED=true
  return 0
}
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
' 2>&1
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
  funcs=$(extract_funcs $VERIFY_LIFT)
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
    assert_runtime_defined "$name" "$out" || return
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
# only DB deployments install. conduck-connect settles it by experiment rather than by
# guessing, so what this case grades is the EXPERIMENT: the control must hold before any
# claim is made, and no claim may be made when the difference is not attributable to the
# credential. Driven against a fixture whose status genuinely depends on the
# Authorization header, because a structural assertion cannot show a probe running in
# the wrong order.
run_keyless_5xx_credential_case() {
  local name="keyless-5xx-names-the-missing-credential" funcs out i line FPID="" FPORT=""
  # curl_gw refuses a token it cannot print safely before it sends anything, so the
  # experiment below only runs at all with credential_value_safe present.
  funcs=$(extract_funcs curl_gw credential_value_safe gw_5xx_credential_note)
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
        if ! printf '%s\n' "$out" | grep -qF 'wants a key after all'; then
          fail_case "$name" "[$arm] a keyless gateway whose answer depends on the key was not told so"
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
  funcs=$(extract_funcs $VERIFY_LIFT)
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
    assert_runtime_defined "$name" "$out" || return
    flat=$(printf '%s\n' "$out" | tr '\n' ' ')

    # FACT 1 — the false sentence, in the exact words that sent keyless users after a
    # key they never configured. Never sayable when GW_AUTH is none, whatever
    # the status; still sayable for a bearer gateway, where it is true.
    if [ "$auth" = "none" ] && warning_states "$flat" 'key (was )?(rejected|refused)|rejected (your|the) key'; then
      fail_case "$name" "[$arm] a keyless gateway was told its key was rejected"; return
    fi
    if [ "$auth" = "bearer" ] && [ "$code" = "401" ] && ! warning_states "$flat" 'key rejected'; then
      fail_case "$name" "[$arm] a real rejected key no longer reads as one"; return
    fi
    # FACT 2 — on the two statuses that ARE about being allowed in, a keyless run says
    # so, which is what tells the reader why no key is named. Scoped to those two
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
  funcs=$(extract_funcs $VERIFY_LIFT)
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
  assert_runtime_defined "$name" "$out" || return
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

# A LINT, not a behaviour test — and the only kind of assertion that can hold a
# vocabulary across 14,000 lines and a dozen future edits.
#
# Three words are retired from anything a user reads. Each was retired for its own
# reason and each has a real cost:
#
#   "pairing code"  — the app says "setup code" 25 times and "pairing code" zero.
#                     The script used to contradict itself one keystroke apart:
#                     menu item 4 read "Show a saved setup code" and opened a
#                     screen headed "Re-show your pairing code".
#   "connector"     — a name for this program that appears in no other surface.
#                     The program is "conduck-connect"; the --setup flow is "the
#                     wizard". A third name is a third thing to look up.
#   "helper"        — same, and worse: it also reads as a hedge about what the
#                     thing is.
#
# TWO layers, because one is not enough and the difference is instructive:
#
#   Layer 1 grades what the tool PRINTS at --help. Unambiguous, and it is the text
#   a stranger reads first.
#   Layer 2 grades the source's SCREEN CALLS — every line whose first word is one
#   of the output verbs, plus `manual.append(`, which is how the Hermes analysis
#   returns human sentences from inside a python3 heredoc. That last one is the
#   whole reason this lint is anchored to verbs rather than to whole lines: the
#   live occurrences of "connector" that survived two waves of human review were
#   sitting inside that heredoc, which does not look like tool copy in a diff.
#
# Comment lines are excluded on purpose. Developer commentary in `src/` still says
# "this connector" in dozens of places; that is a separate, cosmetic sweep, and
# rolling it into this lint would mean either failing today or maintaining an
# exclusion list that rots. What the user reads is the thing that must not drift.
# The manage surface's machine contract, which is the half of it a person never
# sees and therefore the half nothing else in this file would notice breaking.
#
# Four claims, and each has a way of being got wrong that looks like working code:
#
#   --list on a machine with nothing set up is 0. "Nothing is saved" is an ANSWER,
#   not a failure, and a wrapper that treats it as one turns a clean host into an
#   error before anything has gone wrong.
#
#   --list --json parses in the three degenerate shapes — empty, a profile this
#   version cannot read, a service file with no profile behind it. Those are
#   exactly the states a hand-built report tends to emit as a trailing comma or a
#   bare null, and they are also the states somebody reaches for the tool IN. It is
#   asserted with a real JSON parser, never with grep: grep cannot tell valid JSON
#   from a string that happens to contain the right words.
#
#   --edit and --forget with no terminal exit 4, not 1 and not a hang. 4 says "this
#   needs a person"; 1 says "something went wrong". A retry loop must be able to
#   tell those apart, and a wrapper that retries an exit-4 forever is the failure
#   this status exists to prevent.
#
#   --forget refuses an id outside [a-z0-9-] before it touches anything. The paths
#   it deletes are built by concatenation ($STATE_DIR/profile-$id.json,
#   conduck-files-$id.service), the id comes straight off the command line, and
#   this is the only irreversible command in the tool.
run_manage_surface_case() {
  local name="manage-surface-machine-contract" rc=0 out id
  local home="$TMP/manage-home" state="$TMP/manage-state" sd="$TMP/manage-state/conduck"
  mkdir -p "$home/Library/LaunchAgents" "$sd"
  : > "$TMP/doctor.out"

  # -- an empty state dir is a valid answer -----------------------------------
  rc=0
  env -u CI HOME="$home" XDG_CONFIG_HOME="$state" TERM=dumb bash "$SCRIPT" --list \
    > "$TMP/list-empty.out" 2>&1 </dev/null || rc=$?
  cat "$TMP/list-empty.out" >> "$TMP/doctor.out"
  if [ "$rc" != "0" ]; then
    fail_case "$name" "--list on a machine with nothing saved exited $rc, expected 0"; return
  fi
  if ! grep -qF 'No saved setups yet.' "$TMP/list-empty.out"; then
    fail_case "$name" "--list did not say plainly that nothing is saved"; return
  fi
  # Plan item 17: the directory reaches the screen on a SUCCESS path. Before this
  # it appeared only inside a permissions warning, so an operator who never hit a
  # failure never learned where their configuration lives.
  if ! grep -qF "$sd" "$TMP/list-empty.out"; then
    fail_case "$name" "--list never named the directory it is reporting on"; return
  fi

  # -- --list --json, three degenerate shapes ---------------------------------
  # Shape 1: empty. Shapes 2 and 3 are added below, in one dir, because that is
  # also the realistic state — a machine acquires an unreadable profile and an
  # orphaned service by the same route, an interrupted run.
  local shape
  for shape in empty mixed; do
    if [ "$shape" = "mixed" ]; then
      # A profile this version cannot parse…
      printf 'not json at all\n' > "$sd/profile-broken.json"
      # …a profile it can…
      write_valid_profile "$sd/profile-custom-good.json" \
        "custom-good" "Good gateway" "https://good.example.test"
      # …and a service file with no profile behind it. This one is the reason the
      # leftovers scan exists: it is a live authenticated WebDAV server over the
      # agent's working folder, restarted at every login, that nothing else in the
      # tool would ever mention again.
      printf '<?xml version="1.0"?><plist><dict></dict></plist>\n' \
        > "$home/Library/LaunchAgents/ai.gigaduck.conduck-files-orphan.plist"
    fi
    rc=0
    env -u CI HOME="$home" XDG_CONFIG_HOME="$state" TERM=dumb bash "$SCRIPT" --list --json \
      > "$TMP/list-$shape.json" 2>&1 </dev/null || rc=$?
    printf -- '--- --list --json (%s) ---\n' "$shape" >> "$TMP/doctor.out"
    cat "$TMP/list-$shape.json" >> "$TMP/doctor.out"
    if [ "$rc" != "0" ]; then
      fail_case "$name" "--list --json ($shape) exited $rc, expected 0"; return
    fi
    # A real parser. The point of --json is that a machine can read it, and only a
    # parser can say whether one can.
    if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TMP/list-$shape.json" 2>>"$TMP/doctor.out"; then
      fail_case "$name" "--list --json ($shape) did not parse as JSON"; return
    fi
  done

  # The unreadable profile is REPORTED rather than dropped — with readable:false
  # and a non-null problem — and the orphaned unit reaches leftovers[]. A report
  # that silently omitted either would be valid JSON saying the wrong thing, which
  # is precisely what the parse check above cannot catch.
  out=$(python3 - "$TMP/list-mixed.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
setups = {s["id"]: s for s in d["setups"]}
broken = setups.get("broken")
print("ids=%s" % ",".join(sorted(setups)))
print("broken_readable=%s" % (broken and broken["readable"]))
print("broken_problem=%s" % (broken and bool(broken["problem"])))
print("leftovers=%s" % ",".join(sorted(l["id"] for l in d["leftovers"])))
print("token_stored=%s" % d["tokenStored"])
PY
) || { fail_case "$name" "could not read the JSON report back"; return; }
  printf -- '--- report facts ---\n%s\n' "$out" >> "$TMP/doctor.out"
  if ! printf '%s\n' "$out" | grep -qF 'ids=broken,custom-good'; then
    fail_case "$name" "the JSON report did not list both the readable and the unreadable setup"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF 'broken_readable=False' ||
     ! printf '%s\n' "$out" | grep -qF 'broken_problem=True'; then
    fail_case "$name" "an unparseable profile was not reported as unreadable, with a reason"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF 'leftovers=orphan'; then
    fail_case "$name" "a service file with no profile behind it never reached leftovers[]"; return
  fi
  # The one field that is a claim about this tool rather than about this machine.
  if ! printf '%s\n' "$out" | grep -qF 'token_stored=False'; then
    fail_case "$name" "the report stopped saying that no gateway token is stored"; return
  fi

  # Shape 3, on its own rather than beside the others: a service unit and NO
  # profiles at all. It is the shape a half-removed machine is left in, and it is
  # the one that puts an EMPTY array next to a populated one — the arrangement a
  # hand-rolled emitter gets wrong (a trailing comma, or `setups: null`) and a
  # parser catches immediately. Both facts are asserted, because valid JSON that
  # dropped the leftover would be a correct-looking answer that hides a live
  # authenticated WebDAV server.
  local ohome="$TMP/manage-orphan-home" ostate="$TMP/manage-orphan-state"
  mkdir -p "$ohome/Library/LaunchAgents" "$ohome/.config/systemd/user" "$ostate/conduck"
  if [ "$(uname -s)" = "Linux" ]; then
    printf '[Service]\nExecStart=/usr/local/bin/rclone serve webdav /tmp/x --addr 127.0.0.1:8080\n' \
      > "$ohome/.config/systemd/user/conduck-files-lonely.service"
  else
    printf '<?xml version="1.0"?><plist><dict></dict></plist>\n' \
      > "$ohome/Library/LaunchAgents/ai.gigaduck.conduck-files-lonely.plist"
  fi
  rc=0
  env -u CI HOME="$ohome" XDG_CONFIG_HOME="$ostate" TERM=dumb bash "$SCRIPT" --list --json \
    > "$TMP/list-orphan.json" 2>&1 </dev/null || rc=$?
  printf -- '--- --list --json (orphan only) ---\n' >> "$TMP/doctor.out"
  cat "$TMP/list-orphan.json" >> "$TMP/doctor.out"
  if [ "$rc" != "0" ]; then
    fail_case "$name" "--list --json (orphan only) exited $rc, expected 0"; return
  fi
  out=$(python3 - "$TMP/list-orphan.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print("setups=%d" % len(d["setups"]))
print("leftovers=%s" % ",".join(sorted(l["id"] for l in d["leftovers"])))
PY
) || { fail_case "$name" "--list --json (orphan only) did not parse as JSON"; return; }
  printf -- '%s\n' "$out" >> "$TMP/doctor.out"
  if ! printf '%s\n' "$out" | grep -qF 'setups=0'; then
    fail_case "$name" "a state dir with no profiles reported setups it does not have"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF 'leftovers=lonely'; then
    fail_case "$name" "a service unit with no profile anywhere never reached leftovers[]"; return
  fi

  # -- no terminal: 4, from both commands that need one -----------------------
  local cmd
  for cmd in --edit --forget; do
    rc=0
    if [ "$cmd" = "--forget" ]; then
      env -u CI HOME="$home" XDG_CONFIG_HOME="$state" TERM=dumb bash "$SCRIPT" --forget custom-good \
        > "$TMP/noterm.out" 2>&1 </dev/null || rc=$?
    else
      env -u CI HOME="$home" XDG_CONFIG_HOME="$state" TERM=dumb bash "$SCRIPT" --edit \
        > "$TMP/noterm.out" 2>&1 </dev/null || rc=$?
    fi
    printf -- '--- %s, no terminal ---\n' "$cmd" >> "$TMP/doctor.out"
    cat "$TMP/noterm.out" >> "$TMP/doctor.out"
    if [ "$rc" != "4" ]; then
      fail_case "$name" "$cmd with no terminal exited $rc, expected 4"; return
    fi
    if ! grep -qF 'needs a person at a terminal' "$TMP/noterm.out"; then
      fail_case "$name" "$cmd refused without saying what is missing"; return
    fi
    # The refusal points at the one command in this group a machine CAN run.
    if ! grep -qF 'bash conduck-connect.sh --list --json' "$TMP/noterm.out"; then
      fail_case "$name" "$cmd's refusal did not name --list --json as the machine-readable way in"; return
    fi
  done
  # …and it refused before doing anything. The profile it was pointed at is still
  # there, unread and unremoved.
  if [ ! -f "$sd/profile-custom-good.json" ]; then
    fail_case "$name" "--forget removed a setup on a run it had already refused"; return
  fi

  # -- a bad id is refused before the filesystem is touched -------------------
  # Through a PIPE, not /dev/null: a pipe may be carrying answers, so it gets past
  # the terminal refusal and reaches the id check — which is the thing under test.
  # /dev/null would exit 4 and prove nothing about the charset.
  for id in '../../etc' 'foo/bar' 'Foo' 'has space' 'x;rm'; do
    rc=0
    out=$(printf '\n' | env -u CI HOME="$home" XDG_CONFIG_HOME="$state" TERM=dumb \
            bash "$SCRIPT" --forget "$id" 2>&1) || rc=$?
    printf -- '--- --forget %s ---\n%s\n' "$id" "$out" >> "$TMP/doctor.out"
    if [ "$rc" != "1" ]; then
      fail_case "$name" "--forget '$id' exited $rc, expected 1"; return
    fi
    if ! printf '%s\n' "$out" | grep -qF 'is not a saved setup id'; then
      fail_case "$name" "--forget '$id' did not say why the id was refused"; return
    fi
    # The rule, not just the refusal: an operator who is told no needs to know
    # what a real id looks like, or the next attempt is another guess.
    if ! printf '%s\n' "$out" | grep -qF 'lowercase letters, digits and hyphens'; then
      fail_case "$name" "the refusal did not state the id rule"; return
    fi
    # Nothing was read, so nothing was named. A transcript that echoed a
    # constructed path here would mean the id had already been concatenated into
    # one before it was checked.
    if printf '%s\n' "$out" | grep -qF "$sd/profile-"; then
      fail_case "$name" "--forget '$id' built a path out of the id before validating it"; return
    fi
  done
  # Every fixture file survived all five attempts.
  if [ ! -f "$sd/profile-custom-good.json" ] || [ ! -f "$sd/profile-broken.json" ] ||
     [ ! -f "$home/Library/LaunchAgents/ai.gigaduck.conduck-files-orphan.plist" ]; then
    fail_case "$name" "a refused --forget deleted something anyway"; return
  fi

  # -- no id at all is a USAGE error, which is a different fact ---------------
  # 2 means "you typed it wrong" and names the flag; 1 would mean "there is no
  # such setup", which is a claim about this machine and would be false.
  rc=0
  out=$(env -u CI HOME="$home" XDG_CONFIG_HOME="$state" TERM=dumb bash "$SCRIPT" --forget \
          </dev/null 2>&1) || rc=$?
  printf -- '--- --forget (no id) ---\n%s\n' "$out" >> "$TMP/doctor.out"
  if [ "$rc" != "2" ] || ! printf '%s\n' "$out" | grep -qF 'Usage error:'; then
    fail_case "$name" "--forget with no id exited $rc, expected a usage error (2)"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF -- '--list'; then
    fail_case "$name" "--forget with no id did not point at the command that shows the ids"; return
  fi

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# --forget's id check, on a REAL TERMINAL. The machine-contract case above drives
# it through a pipe, which is the right lane for the exit codes; this one is the
# lane the destructive command is actually used in, and it is not interchangeable:
#
#   With no terminal, --forget can refuse for TWO different reasons — a bad id
#   (1) and no terminal (4) — and only one of them is under test. A refusal that
#   moved AFTER the terminal gate would still exit 4 on a closed stdin and the
#   case would stay green while proving nothing about the charset. On a PTY there
#   is no second reason left: the terminal is there, so a refusal is the id check
#   or it is nothing.
#
# The pairing is the assertion (§5's rule). The bad-id lane asserts that a removal
# screen is never reached; the good-id lane, driven identically, asserts that the
# same PTY drive DOES reach one — otherwise "no removal screen" is satisfied by a
# fixture with nothing to remove, which is a green that means nothing.
run_manage_forget_pty_id_case() {
  local name="manage-forget-bad-id-refused-on-a-terminal" rc=0 id
  local home="$TMP/forgetpty-home" state="$TMP/forgetpty-state" sd="$TMP/forgetpty-state/conduck"
  mkdir -p "$home/Library/LaunchAgents" "$home/.config/systemd/user" "$sd"
  : > "$TMP/doctor.out"
  write_valid_profile "$sd/profile-custom-good.json" \
    "custom-good" "Good gateway" "https://good.example.test"
  PTY_ENV=(HOME="$home" XDG_CONFIG_HOME="$state")

  # An Enter is queued so the run cannot block if a prompt DOES appear — a hang
  # would exit 124 and be reported as a timeout rather than as this failure.
  for id in '../../etc' 'foo/bar'; do
    rc=0
    pty_run 15 $'\n' --forget "$id" > "$TMP/forget-bad.out" 2>&1 || rc=$?
    printf -- '--- --forget %s (pty) ---\n' "$id" >> "$TMP/doctor.out"
    cat "$TMP/forget-bad.out" >> "$TMP/doctor.out"
    assert_runtime_defined "$name" "$(cat "$TMP/forget-bad.out")" || return
    if [ "$rc" != "1" ]; then
      fail_case "$name" "--forget '$id' on a terminal exited $rc, expected 1"; return
    fi
    if ! grep -qF 'is not a saved setup id' "$TMP/forget-bad.out"; then
      fail_case "$name" "--forget '$id' on a terminal did not refuse the id by name"; return
    fi
    # The removal screen is the point of no return: it is where the disclosure is
    # printed and where the type-back prompt appears. Reaching it with an id like
    # ../../etc means the id has already been turned into paths.
    if grep -qF 'to remove it (Enter = cancel; i = explain; q = stop)' "$TMP/forget-bad.out"; then
      fail_case "$name" "--forget '$id' reached the removal confirmation"; return
    fi
    if grep -qF 'This removes, on this machine:' "$TMP/forget-bad.out"; then
      fail_case "$name" "--forget '$id' printed a teardown list for an id it had refused"; return
    fi
    if grep -qF "$sd/profile-" "$TMP/forget-bad.out"; then
      fail_case "$name" "--forget '$id' built a path out of the id before validating it"; return
    fi
  done
  if [ ! -f "$sd/profile-custom-good.json" ]; then
    fail_case "$name" "a refused --forget deleted the unrelated saved setup"; return
  fi

  # The presence half: the same drive, a legal id, and the removal screen the two
  # lanes above must never see. Enter at the type-back prompt CANCELS, so this
  # lane reaches the point of no return and stops one keystroke short of it.
  rc=0
  pty_run 15 $'\n' --forget custom-good > "$TMP/forget-good.out" 2>&1 || rc=$?
  printf -- '--- --forget custom-good (pty, cancelled) ---\n' >> "$TMP/doctor.out"
  cat "$TMP/forget-good.out" >> "$TMP/doctor.out"
  assert_runtime_defined "$name" "$(cat "$TMP/forget-good.out")" || return
  if ! grep -qF 'Type custom-good to remove it (Enter = cancel; i = explain; q = stop)' "$TMP/forget-good.out"; then
    fail_case "$name" "a legal id never reached the removal confirmation — the absence lanes prove nothing"; return
  fi
  if [ "$rc" = "0" ]; then
    fail_case "$name" "a cancelled removal reported success"; return
  fi
  if [ ! -f "$sd/profile-custom-good.json" ]; then
    fail_case "$name" "Enter at the type-back prompt removed the setup instead of cancelling"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# The edit screen holds ONE setup's values in its own locals and reprints itself
# from them after every action — including after action 4, which hands control to
# the whole --show-code pipeline. That pipeline is a fresh-process program: it loads
# a profile into GW_*/FS_* and, when it cannot recover a file-lane credential, it
# offers to print a gateway-only code and CLEARS FS_URL/FS_CRED to mean it. Run from
# the edit screen with those names unclaimed, both of those writes land in the edit
# screen's own state, and the next save on that screen writes them back:
# `"fileServer": null` for a lane that is still there, into a file chosen by an id
# that came out of the profile rather than off the screen.
#
# This is an ISOLATED case because the end-to-end drive is not reachable hermetically:
# --show-code exits 1 the moment live verification fails, and verification needs a
# reachable https gateway. The pipeline still runs to completion in production, which
# is exactly when the finding bites. So the network tail is stubbed and everything
# that touches the STATE — the profile load, the credential recovery, the fallback,
# the save, the encoder — is the shipped code.
#
# The fixture is the finding's own shape, and every part of it is load-bearing:
#
#   The file is profile-custom-a.json and the gateway.id INSIDE it is custom-b.
#   Nothing forbids that: show_qr_validate_profile checks the charset of the id in
#   the file and never compares it to the file's name. So the id the operator picked
#   and the id the profile carries can differ, and only one of them is the file that
#   may be written.
#
#   The credential file for custom-a EXISTS and there is no service unit. That is
#   the population most likely to press 4: manage_load_profile finds the credential
#   by the id it was asked about, existing_fs_config cannot (there is no unit to
#   find), and the gateway-only fallback fires for the reason it is meant to.
run_manage_show_code_state_isolated() {
  FUNCS="$1" STATE="$2" HOMEDIR="$3" FOLDER="$4" bash -c '
eval "$FUNCS"
say() { :; }; note() { :; }; warn() { :; }; ok() { :; }; head_() { :; }; bad() { :; }
die() { printf "DIE %s\n" "$*"; exit 9; }
preflight() { :; }
show_qr_warn_quick_tunnel() { :; }
# The network tail, and only the network tail.
show_qr_check_live()  { :; }
show_qr_recall_scope() { :; }
verify_all()          { :; }
emit_payload()        { :; }
show_qr_next_steps()  { :; }
# Answering yes is the case: the fallback is what clears the lane, so declining it
# would grade a branch that changes nothing.
confirm() { printf "CONFIRM %s\n" "$1"; return 0; }
OS=$(uname -s)
HOME="$HOMEDIR"
STATE_DIR="$STATE"
STATE_DIR_EXPOSURE_REPORTED=true
DRY_RUN=false; REUSE_ONLY=false; SHOW_QR=false
VERIFY_FAILED=false; FS_LANE_DROPPED_BY_CHECK=false

# The manage_edit frame: the values the screen is holding when 4 is pressed. An
# apostrophe cannot appear anywhere in this comment — it sits inside a single
# quoted block and would close it. A curly one closes nothing but fails the
# shellcheck gate (SC1112), so the wording simply avoids needing one. The id
# is the one the operator PICKED, which is the file name, not the id in the file.
GW_ID="custom-a"; GW_KIND="custom"; GW_NAME="Two id gateway"; GW_AUTH="none"
TRANSPORT="public"; SCOPE="public"; GW_URL="https://gw.example.test"
GW_LOCAL_PORT="8080"; GW_MODEL=""
FS_URL="https://files.example.test:8443"; FS_CRED="not-a-real-password"
FS_LOCAL_PORT="8081"; FS_REACH="public"; FS_FOLDER="$FOLDER"

printf "BEFORE GW_ID=%s FS_URL=%s FS_CRED=%s\n" "$GW_ID" "$FS_URL" "${FS_CRED:+set}"
manage_show_code custom-a
printf "AFTER GW_ID=%s FS_URL=%s FS_CRED=%s\n" "$GW_ID" "$FS_URL" "${FS_CRED:+set}"
# …and the save the screen offers next, which is where clobbered state becomes a
# written file.
GW_URL="https://moved.example.test"
manage_save_profile custom-a
' 2>&1
}

run_manage_show_code_state_case() {
  local name="manage-edit-survives-showing-a-setup-code" funcs out before after
  local home="$TMP/showstate-home" sd="$TMP/showstate-state/conduck"
  : > "$TMP/doctor.out"
  # No LaunchAgents / systemd user directory at all: "the service unit is gone".
  local folder="$TMP/showstate-state/work"
  mkdir -p "$home" "$sd" "$folder"
  # localPort as a STRING, because that is what write_profile emits — a fixture
  # that used a JSON number would report every rewrite as a change to the block.
  printf '{"schemaVersion":1,"gateway":{"id":"custom-b","kind":"custom","name":"Two id gateway","auth":"none","transport":"public","reach":"public","url":"https://gw.example.test","localPort":"8080"},"fileServer":{"url":"https://files.example.test:8443","folder":"%s","reach":"public","localPort":"8081"}}\n' \
    "$folder" > "$sd/profile-custom-a.json"
  printf 'conduck:not-a-real-password\n' > "$sd/fileserver-custom-a.cred"

  # The fileServer block as a canonical string, so "unchanged" survives the rewrite
  # reordering the document's keys — the object is what must be identical, not the
  # bytes of the file it sits in.
  before=$(python3 - "$sd/profile-custom-a.json" <<'PY'
import json, sys
print(json.dumps(json.load(open(sys.argv[1])).get("fileServer"), sort_keys=True))
PY
) || { fail_case "$name" "could not read the fixture's fileServer block"; return; }

  funcs=$(extract_funcs manage_show_code manage_save_profile manage_profile_path \
    show_qr_load_profile show_qr_validate_profile show_qr_profile_invalid \
    show_qr_profile_field_invalid show_qr_is_https_host show_qr_is_port \
    show_qr_recover_gateway_secret show_qr_recover_file_lane \
    existing_fs_config linux_unit_candidates mac_unit_candidates \
    json_query json_get json_type write_profile ensure_state_dir)
  out=$(run_manage_show_code_state_isolated "$funcs" "$sd" "$home" "$folder")
  printf -- '--- isolated show-code from the edit frame ---\n%s\n' "$out" >> "$TMP/doctor.out"
  assert_runtime_defined "$name" "$out" || return

  # Non-vacuity first. If the credential HAD been recovered, nothing would be
  # cleared and every assertion below would pass on a build with no fix in it.
  if ! printf '%s\n' "$out" | grep -qF 'CONFIRM   Re-show the code for the GATEWAY ONLY'; then
    fail_case "$name" "the gateway-only fallback never fired, so nothing cleared the lane"; return
  fi
  # The id the operator picked. Pre-fix this came back custom-b, read out of the
  # file — and it is the only thing deciding which file the next save writes.
  if ! printf '%s\n' "$out" | grep -qF 'AFTER GW_ID=custom-a'; then
    fail_case "$name" "showing a setup code replaced the id the edit screen was working on"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF 'AFTER GW_ID=custom-a FS_URL=https://files.example.test:8443 FS_CRED=set'; then
    fail_case "$name" "showing a setup code emptied the file lane the edit screen was holding"; return
  fi

  # The second barrier, independent of the first: even with the id clobbered, the
  # save must land on the file the operator picked.
  if [ ! -f "$sd/profile-custom-a.json" ]; then
    fail_case "$name" "the save did not write the profile the operator picked"; return
  fi
  if [ -f "$sd/profile-custom-b.json" ]; then
    fail_case "$name" "the save minted a second profile named after the id inside the file"; return
  fi
  # The save really happened — otherwise "the block is unchanged" is satisfied by a
  # run that wrote nothing at all.
  out=$(python3 - "$sd/profile-custom-a.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(d["gateway"]["url"])
PY
) || { fail_case "$name" "the rewritten profile did not parse"; return; }
  printf -- '--- gateway.url after the save ---\n%s\n' "$out" >> "$TMP/doctor.out"
  if [ "$out" != "https://moved.example.test" ]; then
    fail_case "$name" "the address change did not reach the file (url is '$out')"; return
  fi
  after=$(python3 - "$sd/profile-custom-a.json" <<'PY'
import json, sys
print(json.dumps(json.load(open(sys.argv[1])).get("fileServer"), sort_keys=True))
PY
) || { fail_case "$name" "could not read the rewritten fileServer block"; return; }
  printf -- '--- fileServer before/after ---\n%s\n%s\n' "$before" "$after" >> "$TMP/doctor.out"
  if [ "$after" != "$before" ]; then
    fail_case "$name" "the save rewrote the file lane after a setup code was shown"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# Every id and every path on the --list screen is FILESYSTEM-DERIVED: the id comes
# out of a filename, and the leftovers scan reads unit files nothing in this tool
# wrote. A filename is attacker-influenced on any machine where something else can
# create a file in $HOME/Library/LaunchAgents or the state directory — and a name
# carrying ANSI can rewrite the screen it is printed on, which on this screen means
# rewriting a list of what will be removed.
#
# Two shapes, because they reach the screen by different routes: a profile the
# validator rejects (its id AND the reason, which quotes the path back, so the same
# bytes arrive twice), and an orphan service unit (its id, its path, and the
# teardown command built from them).
#
# The command is the sharper half. `--forget <id>` was printed for ids manage_id_ok
# refuses — an instruction that cannot work — and fs_print_teardown quotes for the
# SHELL, which does not strip control bytes, so a "correct" command for such a path
# is by construction one that repaints the terminal. Both are now the by-hand
# route instead. The ordinary orphan beside it still gets its one-line command,
# which is what stops the fix from being "print less".
run_manage_untrusted_names_case() {
  local name="manage-list-renders-untrusted-names" rc esc evil
  local home="$TMP/rawnames-home" state="$TMP/rawnames-state" sd="$TMP/rawnames-state/conduck"
  mkdir -p "$home/Library/LaunchAgents" "$home/.config/systemd/user" "$sd"
  : > "$TMP/doctor.out"
  esc=$(printf '\033')
  evil="${esc}[31mEVIL"

  # The control: an ordinary orphan, whose instruction must survive.
  printf '<?xml version="1.0"?><plist version="1.0"><dict><key>Label</key><string>x</string><key>ProgramArguments</key><array><string>/usr/local/bin/rclone</string><string>serve</string><string>webdav</string><string>/tmp/lonelyfolder</string><string>--addr</string><string>127.0.0.1:8080</string></array></dict></plist>\n' \
    > "$home/Library/LaunchAgents/ai.gigaduck.conduck-files-lonely.plist"
  printf '[Service]\nExecStart=/usr/local/bin/rclone serve webdav /tmp/lonelyfolder --addr 127.0.0.1:8080\n' \
    > "$home/.config/systemd/user/conduck-files-lonely.service"
  # An orphan whose id carries an ESC, on both platforms' paths so the case does
  # not depend on which one it runs on.
  printf '<?xml version="1.0"?><plist version="1.0"><dict><key>Label</key><string>y</string><key>ProgramArguments</key><array><string>/usr/local/bin/rclone</string><string>serve</string><string>webdav</string><string>/tmp/evilfolder</string><string>--addr</string><string>127.0.0.1:8082</string></array></dict></plist>\n' \
    > "$home/Library/LaunchAgents/ai.gigaduck.conduck-files-$evil.plist"
  printf '[Service]\nExecStart=/usr/local/bin/rclone serve webdav /tmp/evilfolder --addr 127.0.0.1:8082\n' \
    > "$home/.config/systemd/user/conduck-files-$evil.service"
  # …a profile this version cannot read, filed under the same kind of id…
  printf 'not json at all\n' > "$sd/profile-$evil.json"
  # …and a third orphan whose id is perfectly PRINTABLE and still not one --forget
  # will accept (ids are lowercase). It separates the two halves of the defect: the
  # bytes and the instruction. Without it, an id that is merely unaddressable would
  # be graded only by the escape-byte count, which it does not trip.
  printf '<?xml version="1.0"?><plist version="1.0"><dict><key>Label</key><string>z</string><key>ProgramArguments</key><array><string>/usr/local/bin/rclone</string><string>serve</string><string>webdav</string><string>/tmp/shoutyfolder</string><string>--addr</string><string>127.0.0.1:8083</string></array></dict></plist>\n' \
    > "$home/Library/LaunchAgents/ai.gigaduck.conduck-files-SHOUTY.plist"
  printf '[Service]\nExecStart=/usr/local/bin/rclone serve webdav /tmp/shoutyfolder --addr 127.0.0.1:8083\n' \
    > "$home/.config/systemd/user/conduck-files-SHOUTY.service"

  # The fixture is only a test if the bytes are really in the names.
  if [ ! -f "$sd/profile-$evil.json" ] ||
     [ ! -f "$home/Library/LaunchAgents/ai.gigaduck.conduck-files-$evil.plist" ]; then
    fail_case "$name" "the ESC-bearing fixtures were not created — every assertion here would be vacuous"; return
  fi

  rc=0
  env -u CI HOME="$home" XDG_CONFIG_HOME="$state" TERM=dumb bash "$SCRIPT" --list \
    > "$TMP/rawnames.out" 2>&1 </dev/null || rc=$?
  # cat -v, because the raw bytes are the thing under test and a doctor dump of
  # them would carry them into the terminal of whoever reads a failing run.
  printf -- '--- --list with untrusted names (cat -v) ---\n' >> "$TMP/doctor.out"
  cat -v "$TMP/rawnames.out" >> "$TMP/doctor.out"
  assert_runtime_defined "$name" "$(cat "$TMP/rawnames.out")" || return
  if [ "$rc" != "0" ]; then
    fail_case "$name" "--list with untrusted names exited $rc, expected 0"; return
  fi
  # Colour is gated on [ -t 1 ] and this run is redirected, so the ONLY escapes
  # that could reach here came out of a filename.
  if [ "$(tr -dc "$esc" < "$TMP/rawnames.out" | wc -c | tr -d ' ')" != "0" ]; then
    fail_case "$name" "a filesystem-derived name put raw escape bytes on the screen"; return
  fi
  # Reported, not dropped: a name this screen cannot print safely is exactly the
  # one somebody needs to see and get rid of.
  if ! grep -qF 'Saved here but not usable by this version' "$TMP/rawnames.out"; then
    fail_case "$name" "a profile this version cannot read went unreported"; return
  fi
  if ! grep -qF 'File servers with no saved setup behind them' "$TMP/rawnames.out"; then
    fail_case "$name" "the leftovers scan did not run"; return
  fi
  if ! grep -qF '[31mEVIL' "$TMP/rawnames.out"; then
    fail_case "$name" "the untrusted names were suppressed rather than made safe to print"; return
  fi
  # The instruction that cannot work. An id manage_id_ok refuses gets the by-hand
  # route, never a --forget the tool will decline.
  if grep -qE -- '--forget .*EVIL' "$TMP/rawnames.out"; then
    fail_case "$name" "a --forget command was printed for an id --forget itself refuses"; return
  fi
  if grep -qF -- '--forget SHOUTY' "$TMP/rawnames.out"; then
    fail_case "$name" "a --forget command was printed for an id --forget itself refuses"; return
  fi
  if ! grep -qF '/tmp/shoutyfolder' "$TMP/rawnames.out"; then
    fail_case "$name" "an unaddressable orphan went unreported instead of getting a by-hand teardown"; return
  fi
  if ! grep -qF 'Its real filename holds characters a terminal would ACT on' "$TMP/rawnames.out"; then
    fail_case "$name" "the unprintable name was given no way to be removed at all"; return
  fi
  # The control, unchanged.
  if ! grep -qF 'bash conduck-connect.sh --forget lonely' "$TMP/rawnames.out"; then
    fail_case "$name" "an ordinary orphan lost its one-line removal command"; return
  fi
  if ! grep -qF '/tmp/lonelyfolder' "$TMP/rawnames.out"; then
    fail_case "$name" "an ordinary orphan lost the folder it serves"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# The Token row on --list answers one question — where does the token come from
# when a setup code is printed? — and the answer is different for each gateway
# kind. show_qr_recover_gateway_secret is the authority: openclaw reads the literal
# out of OpenClaw's own config, hermes reads API_SERVER_KEY from ~/.hermes/.env and
# dies if it is absent, and only the custom arm ever prompts. One sentence for all
# three told two thirds of the operators to expect a question they will never see,
# and hid the file they actually need to keep in place.
run_manage_token_row_case() {
  local name="manage-list-token-row-is-per-kind" rc kind
  local home="$TMP/tokenrow-home" state="$TMP/tokenrow-state" sd="$TMP/tokenrow-state/conduck"
  mkdir -p "$home" "$sd"
  : > "$TMP/doctor.out"
  # kind and id must agree (openclaw pairs with the id openclaw, hermes with
  # hermes, custom with custom-*), so the fixtures are named accordingly.
  printf '{"schemaVersion":1,"gateway":{"id":"custom-keyless","kind":"custom","name":"Keyless","auth":"none","transport":"public","reach":"public","url":"https://k.example.test"},"fileServer":null}\n' \
    > "$sd/profile-custom-keyless.json"
  printf '{"schemaVersion":1,"gateway":{"id":"custom-bearer","kind":"custom","name":"Custom bearer","auth":"bearer","transport":"public","reach":"public","url":"https://c.example.test"},"fileServer":null}\n' \
    > "$sd/profile-custom-bearer.json"
  printf '{"schemaVersion":1,"gateway":{"id":"hermes","kind":"hermes","name":"Hermes","auth":"bearer","transport":"public","reach":"public","url":"https://h.example.test"},"fileServer":null}\n' \
    > "$sd/profile-hermes.json"
  printf '{"schemaVersion":1,"gateway":{"id":"openclaw","kind":"openclaw","name":"OpenClaw","auth":"bearer","transport":"public","reach":"public","url":"https://o.example.test"},"fileServer":null}\n' \
    > "$sd/profile-openclaw.json"

  rc=0
  env -u CI HOME="$home" XDG_CONFIG_HOME="$state" TERM=dumb bash "$SCRIPT" --list \
    > "$TMP/tokenrow.out" 2>&1 </dev/null || rc=$?
  printf -- '--- --list, four gateway kinds ---\n' >> "$TMP/doctor.out"
  cat "$TMP/tokenrow.out" >> "$TMP/doctor.out"
  assert_runtime_defined "$name" "$(cat "$TMP/tokenrow.out")" || return
  if [ "$rc" != "0" ]; then
    fail_case "$name" "--list with four saved kinds exited $rc, expected 0"; return
  fi
  # One row per kind, each naming the place a code really re-reads the key from.
  for kind in \
    "keyless|not stored — this gateway is keyless" \
    "custom|not saved here — you re-enter it when a code is printed" \
    "hermes|not saved here — a code re-reads it from ~/.hermes/.env" \
    "openclaw|not saved here — a code re-reads it from OpenClaw's own config" \
  ; do
    if ! grep -qF "${kind#*|}" "$TMP/tokenrow.out"; then
      fail_case "$name" "the ${kind%%|*} setup's Key row did not say where its key comes from"; return
    fi
  done
  # Four DISTINCT rows. Without this, one sentence printed four times satisfies
  # every assertion above that happens to match it.
  if [ "$(grep -c 'Key:' "$TMP/tokenrow.out")" != "4" ]; then
    fail_case "$name" "expected one Key row per saved setup, found $(grep -c 'Key:' "$TMP/tokenrow.out")"; return
  fi
  if [ "$(grep 'Key:' "$TMP/tokenrow.out" | sort -u | wc -l | tr -d ' ')" != "4" ]; then
    fail_case "$name" "two gateway kinds were given the same Key row"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# --edit through a PIPE. A pipe is not a character device, so it gets past the
# dispatcher's closed-stdin guard and reaches the screen — and the screen used to
# validate every profile on the machine, draw the whole inventory, print
# "Which one? Choose 1-2", CONSUME the answer off the pipe, and only then refuse
# for want of a terminal. To a driver that reads as a tool which took its choice
# and changed its mind; worse, the answer is gone, so a wrapper cannot retry by
# feeding the same input to an interactive run.
#
# The dry-run half rides along because it is the same question asked of the same
# two commands — does the refusal arrive before anything happens? — and because
# the branches it refuses were the ones deleted as unreachable. If --edit ever
# accepted --dry-run again, its "(dry-run: …)" narration would be the first thing
# in the transcript.
run_manage_headless_refusals_case() {
  local name="manage-refuses-before-it-reads-anything" rc out lane
  local home="$TMP/headless-home" state="$TMP/headless-state" sd="$TMP/headless-state/conduck"
  mkdir -p "$home" "$sd"
  : > "$TMP/doctor.out"
  write_valid_profile "$sd/profile-custom-one.json" "custom-one" "First gateway" "https://one.example.test"
  write_valid_profile "$sd/profile-custom-two.json" "custom-two" "Second gateway" "https://two.example.test"

  rc=0
  out=$(printf '1\n' | env -u CI HOME="$home" XDG_CONFIG_HOME="$state" TERM=dumb \
          bash "$SCRIPT" --edit 2>&1) || rc=$?
  printf -- '--- printf 1 | --edit, rc=%s ---\n%s\n' "$rc" "$out" >> "$TMP/doctor.out"
  assert_runtime_defined "$name" "$out" || return
  if [ "$rc" != "4" ]; then
    fail_case "$name" "--edit through a pipe exited $rc, expected 4"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF 'needs a person at a terminal'; then
    fail_case "$name" "--edit through a pipe refused without saying what is missing"; return
  fi
  # Nothing was read. The inventory is built by validating every profile in the
  # directory, so naming one means the refusal came after that work.
  if printf '%s\n' "$out" | grep -qF 'First gateway'; then
    fail_case "$name" "--edit rendered the saved setups before refusing"; return
  fi
  if printf '%s\n' "$out" | grep -qF 'Which one? Choose'; then
    fail_case "$name" "--edit asked which setup and consumed the answer before refusing"; return
  fi

  # --dry-run, on the two commands whose dry-run branches were deleted for being
  # unreachable. Each names the flag AND says why this command does not take it.
  for lane in "--edit||--edit asks before every change" \
              "--edit|custom-one|--edit asks before every change" \
              "--forget|custom-one|--forget names everything it will remove" \
  ; do
    local cmd="${lane%%|*}"; lane="${lane#*|}"
    local arg="${lane%%|*}"; local want="${lane#*|}"
    rc=0
    if [ -n "$arg" ]; then
      out=$(env -u CI HOME="$home" XDG_CONFIG_HOME="$state" TERM=dumb \
              bash "$SCRIPT" "$cmd" "$arg" --dry-run </dev/null 2>&1) || rc=$?
    else
      out=$(env -u CI HOME="$home" XDG_CONFIG_HOME="$state" TERM=dumb \
              bash "$SCRIPT" "$cmd" --dry-run </dev/null 2>&1) || rc=$?
    fi
    printf -- '--- %s %s --dry-run, rc=%s ---\n%s\n' "$cmd" "$arg" "$rc" "$out" >> "$TMP/doctor.out"
    if [ "$rc" != "2" ]; then
      fail_case "$name" "$cmd $arg --dry-run exited $rc, expected a usage error (2)"; return
    fi
    if ! printf '%s\n' "$out" | grep -qF 'Usage error:'; then
      fail_case "$name" "$cmd $arg --dry-run did not identify itself as a usage error"; return
    fi
    # `--` because every one of these fragments starts with a flag name.
    if ! printf '%s\n' "$out" | grep -qF -- "$want"; then
      fail_case "$name" "$cmd $arg --dry-run did not say why this command has no dry run"; return
    fi
    # The narration those deleted branches would have produced. Its absence is
    # what says the refusal really did come first.
    if printf '%s\n' "$out" | grep -qF '(dry-run:'; then
      fail_case "$name" "$cmd narrated a dry run on an invocation it had refused"; return
    fi
  done
  # …and no manage transcript in this case carries it either.
  if grep -qF '(dry-run:' "$TMP/doctor.out"; then
    fail_case "$name" "a manage transcript narrated a dry run"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# The --edit screen's remaining cases all drive the same shape — one saved setup,
# one PTY, one sequence of keystrokes — so the fixture and the drive live here and
# each case owns only its fixture and its assertions.
#
# EDIT_WORK exists before the profile that names it: the screen prints the shared
# folder, and a folder that is not there changes what it prints.
EDIT_HOME=""; EDIT_STATE=""; EDIT_SD=""; EDIT_WORK=""; EDIT_RC=0
manage_edit_fixture() { # manage_edit_fixture <slug> <profile-json-with-@WORK@>
  EDIT_HOME="$TMP/editdrive-$1-home"
  EDIT_STATE="$TMP/editdrive-$1-state"
  EDIT_SD="$EDIT_STATE/conduck"
  EDIT_WORK="$TMP/editdrive-$1-work"
  mkdir -p "$EDIT_HOME/Library/LaunchAgents" "$EDIT_HOME/.config/systemd/user" \
           "$EDIT_SD" "$EDIT_WORK"
  printf '%s\n' "${2//@WORK@/$EDIT_WORK}" > "$EDIT_SD/profile-custom-a.json"
}
manage_edit_run() { # manage_edit_run <keys-with-\n> [script-args…]
  local keys="$1"; shift
  keys=$(printf '%b_' "$keys"); keys="${keys%_}"
  PTY_ENV=(HOME="$EDIT_HOME" XDG_CONFIG_HOME="$EDIT_STATE")
  EDIT_RC=0
  pty_run 40 "$keys" "$@" > "$TMP/editdrive.out" 2>&1 || EDIT_RC=$?
  cat "$TMP/editdrive.out" >> "$TMP/doctor.out"
}
# gateway.url, gateway.model and "does a fileServer block survive", read off the
# disk in one go — three separate greps of the transcript would grade what the
# screen SAID rather than what it wrote.
manage_edit_disk() { # manage_edit_disk -> "<url> <model> fs=<True|False>"
  python3 - "$EDIT_SD/profile-custom-a.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); g = d["gateway"]
print("%s %s fs=%s" % (g["url"], g.get("model"), bool(d.get("fileServer"))))
PY
}

# A Tailscale setup given an address that is not a tailnet name is the one
# inconsistency this screen can prove on its own — and the consequence is exact:
# --show-code asserts the live Tailscale mapping before it prints anything and dies
# on a non-*.ts.net host, so the record is one no setup code can be printed from.
# The screen printed that warning and then saved anyway, unasked, and offered the
# setup code whose first step it had just said would refuse.
#
# Three lanes, and the third is what makes the first two mean anything.
#
# Read this before strengthening the gate assertion: an address that does not
# ANSWER also opens the confirm gate, and no address can answer in a hermetic
# suite — ask_url takes https:// only, and this repo has no HTTPS fixture and will
# not grow a self-signed one. So "Save it anyway? appeared" is graded here as the
# gate existing at all, and it is NOT what separates the two doubts. The two facts
# that are only ever true of the transport mismatch are the sentence naming what
# saving costs, and — after a save — the refusal standing where the code offer
# would be. Those are the assertions that bite; the cloudflare lane is the same
# drive against a transport with no mismatch, same unreachable address, same gate,
# and neither of those two.
run_manage_edit_tailscale_case() {
  local name="manage-edit-confirms-a-tailscale-address-mismatch" disk
  : > "$TMP/doctor.out"
  local ts='{"schemaVersion":1,"gateway":{"id":"custom-a","kind":"custom","name":"Tailnet gateway","auth":"bearer","transport":"tailscale","reach":"private","url":"https://box.tail1234.ts.net","localPort":"8080"},"fileServer":null}'
  local cf='{"schemaVersion":1,"gateway":{"id":"custom-a","kind":"custom","name":"Cloudflared gateway","auth":"bearer","transport":"cloudflare","reach":"public","url":"https://a.trycloudflare.com"},"fileServer":null}'

  # Lane 1: the gate appears and No leaves the disk alone.
  manage_edit_fixture ts-no "$ts"
  printf -- '--- tailscale, answered No ---\n' >> "$TMP/doctor.out"
  manage_edit_run '1\nhttps://moved.example.test\nn\nq\n' --edit custom-a
  assert_runtime_defined "$name" "$(cat "$TMP/editdrive.out")" || return
  if [ "$EDIT_RC" = "124" ]; then
    fail_case "$name" "the tailscale lane hung"; return
  fi
  if ! grep -qF 'that address is not a' "$TMP/editdrive.out"; then
    fail_case "$name" "a non-tailnet address on a Tailscale setup was not called out"; return
  fi
  if ! grep -qF 'Save it anyway?' "$TMP/editdrive.out"; then
    fail_case "$name" "the address change was saved without a confirmation of any kind"; return
  fi
  if ! grep -qF 'Saving this leaves a record no setup code can be printed from' "$TMP/editdrive.out"; then
    fail_case "$name" "the confirmation did not name what saving would cost"; return
  fi
  disk=$(manage_edit_disk) || { fail_case "$name" "the tailscale profile no longer parses"; return; }
  if [ "$disk" != "https://box.tail1234.ts.net None fs=False" ]; then
    fail_case "$name" "answering No still changed the saved address (disk: $disk)"; return
  fi

  # Lane 2: Yes saves — and the code offer is replaced by the refusal.
  manage_edit_fixture ts-yes "$ts"
  printf -- '--- tailscale, answered Yes ---\n' >> "$TMP/doctor.out"
  manage_edit_run '1\nhttps://moved.example.test\ny\nq\n' --edit custom-a
  assert_runtime_defined "$name" "$(cat "$TMP/editdrive.out")" || return
  if [ "$EDIT_RC" = "124" ]; then
    fail_case "$name" "the tailscale save lane hung"; return
  fi
  disk=$(manage_edit_disk) || { fail_case "$name" "the tailscale profile no longer parses"; return; }
  if [ "$disk" != "https://moved.example.test None fs=False" ]; then
    fail_case "$name" "answering Yes did not save the address (disk: $disk)"; return
  fi
  if grep -qF 'Show the new setup code now?' "$TMP/editdrive.out"; then
    fail_case "$name" "a mismatched record was offered a setup code its own pipeline refuses"; return
  fi
  if ! grep -qF 'No setup code can be printed from this record' "$TMP/editdrive.out"; then
    fail_case "$name" "the code offer was dropped without saying why, or how to make one printable again"; return
  fi

  # Lane 3, the control: no mismatch, so neither of the two above, and the offer
  # is there.
  manage_edit_fixture cf "$cf"
  printf -- '--- cloudflare control ---\n' >> "$TMP/doctor.out"
  manage_edit_run '1\nhttps://moved.example.test\ny\nn\nq\n' --edit custom-a
  assert_runtime_defined "$name" "$(cat "$TMP/editdrive.out")" || return
  if [ "$EDIT_RC" = "124" ]; then
    fail_case "$name" "the cloudflare control lane hung"; return
  fi
  if grep -qF 'Saving this leaves a record no setup code can be printed from' "$TMP/editdrive.out"; then
    fail_case "$name" "a transport with no mismatch was warned about one — the lanes above prove nothing"; return
  fi
  if grep -qF 'No setup code can be printed from this record' "$TMP/editdrive.out"; then
    fail_case "$name" "a transport with no mismatch had its setup code refused"; return
  fi
  if ! grep -qF 'Show the new setup code now?' "$TMP/editdrive.out"; then
    fail_case "$name" "an ordinary saved address stopped offering the code that carries it"; return
  fi
  disk=$(manage_edit_disk) || { fail_case "$name" "the cloudflare profile no longer parses"; return; }
  if [ "$disk" != "https://moved.example.test None fs=False" ]; then
    fail_case "$name" "the control lane did not save (disk: $disk)"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# The model question has to fit the setup it is asked about. choose_saved_model is
# written for a gateway that PINS one — it opens with "This gateway last used the
# model:" and offers Keep it / Use a different name / Clear it — and called on a
# setup that pins nothing it rendered an empty colon and two options that are the
# same no-op. The wizard's own caller guards it on exactly that.
#
# Both sides, because a guard is only right if the guarded branch still runs: the
# un-pinned setup gets the plain question and saves, and the pinned one still
# reaches choose_saved_model and can still clear the pin.
#
# Every lane here also crosses the model roster check, which is what the third and
# fourth lanes exist for. This suite is hermetic and a saved profile may only hold
# an https:// address, so no lane can reach a real model list — what is graded here
# is the WIRING: which setups are asked for a token before the check, which are
# not, and that a check that could not be made says so and still saves. The roster
# verdicts themselves are graded against a live fixture in the case below.
run_manage_edit_model_case() {
  local name="manage-edit-model-question-fits-the-setup" disk
  : > "$TMP/doctor.out"
  local nomodel='{"schemaVersion":1,"gateway":{"id":"custom-a","kind":"custom","name":"Unpinned gateway","auth":"bearer","transport":"public","reach":"public","url":"https://gw.example.test"},"fileServer":null}'
  local pinned='{"schemaVersion":1,"gateway":{"id":"custom-a","kind":"custom","name":"Pinned gateway","auth":"bearer","transport":"public","reach":"public","url":"https://gw.example.test","model":"qwen3-coder:480b"},"fileServer":null}'
  local keyless='{"schemaVersion":1,"gateway":{"id":"custom-a","kind":"custom","name":"Keyless gateway","auth":"none","transport":"public","reach":"public","url":"https://gw.example.test"},"fileServer":null}'

  manage_edit_fixture m-none "$nomodel"
  printf -- '--- model, nothing pinned ---\n' >> "$TMP/doctor.out"
  # n declines the roster check. Answering it is not optional in a driven lane: a
  # bearer setup is asked before anything is sent, and a drive that ignored the
  # question would spend its next keystroke on it.
  manage_edit_run '2\nm9\nn\nq\n' --edit custom-a
  assert_runtime_defined "$name" "$(cat "$TMP/editdrive.out")" || return
  if [ "$EDIT_RC" = "124" ]; then
    fail_case "$name" "the un-pinned model lane hung"; return
  fi
  if grep -qF 'last used the model:' "$TMP/editdrive.out"; then
    fail_case "$name" "a setup that pins no model was told which model it last used"; return
  fi
  # The two options that are the same no-op when nothing is pinned.
  if grep -qF 'Keep it' "$TMP/editdrive.out"; then
    fail_case "$name" "a setup that pins no model was offered Keep it / Clear it"; return
  fi
  if ! grep -qF 'Model name' "$TMP/editdrive.out"; then
    fail_case "$name" "the un-pinned setup was not simply asked for a model name"; return
  fi
  # The check is OFFERED, not taken: a screen that sent the request without asking
  # would be reaching for a credential on a screen that stores none.
  if ! grep -qF 'Check the model against the server' "$TMP/editdrive.out"; then
    fail_case "$name" "a named model was saved without the roster check ever being offered"; return
  fi
  if ! grep -qF 'Not checked' "$TMP/editdrive.out"; then
    fail_case "$name" "the declined check was not reported as unchecked"; return
  fi
  disk=$(manage_edit_disk) || { fail_case "$name" "the un-pinned profile no longer parses"; return; }
  if [ "$disk" != "https://gw.example.test m9 fs=False" ]; then
    fail_case "$name" "the plain model question did not save what was typed (disk: $disk)"; return
  fi

  manage_edit_fixture m-pin "$pinned"
  printf -- '--- model, one pinned ---\n' >> "$TMP/doctor.out"
  manage_edit_run '2\n3\nq\n' --edit custom-a
  assert_runtime_defined "$name" "$(cat "$TMP/editdrive.out")" || return
  if [ "$EDIT_RC" = "124" ]; then
    fail_case "$name" "the pinned model lane hung"; return
  fi
  if ! grep -qF 'last used the model: qwen3-coder:480b' "$TMP/editdrive.out"; then
    fail_case "$name" "a setup that pins a model no longer reaches the question written for one"; return
  fi
  # Clearing the pin is an explicit "let the server pick" — there is no id to look
  # up, and a model list cannot answer whether a model-less request routes the way
  # the operator wants. The q above lands on the menu only because no question was
  # asked here; a lane that grew one would hang.
  if grep -qF 'Check the model against the server' "$TMP/editdrive.out"; then
    fail_case "$name" "clearing the model asked the server about an id that no longer exists"; return
  fi
  disk=$(manage_edit_disk) || { fail_case "$name" "the pinned profile no longer parses"; return; }
  # None, not the empty string: a pin on a model with no name is worse than no pin.
  if [ "$disk" != "https://gw.example.test None fs=False" ]; then
    fail_case "$name" "clearing a pinned model did not reach the disk (disk: $disk)"; return
  fi

  # A keyless setup is never asked for a token: its roster needs none, and a
  # credential question on a saved setup that records auth=none would be asking for
  # a secret that does not exist.
  manage_edit_fixture m-keyless "$keyless"
  printf -- '--- model, keyless setup ---\n' >> "$TMP/doctor.out"
  manage_edit_run '2\nm7\nq\n' --edit custom-a
  assert_runtime_defined "$name" "$(cat "$TMP/editdrive.out")" || return
  if [ "$EDIT_RC" = "124" ]; then
    fail_case "$name" "the keyless model lane hung"; return
  fi
  if grep -qF 'Check the model against the server' "$TMP/editdrive.out"; then
    fail_case "$name" "a keyless setup was asked for a token it records not having"; return
  fi
  if ! grep -qF 'Asking the server for its model list' "$TMP/editdrive.out"; then
    fail_case "$name" "a keyless setup skipped the roster check it needs no credential for"; return
  fi
  # gw.example.test answers nothing, and that is not evidence about the model id —
  # so it is reported and saved, with no gate in between.
  if ! grep -qF 'Not checked — nothing answered at that address' "$TMP/editdrive.out"; then
    fail_case "$name" "an unreachable gateway did not say why the model went unchecked"; return
  fi
  if grep -qF 'Save it anyway?' "$TMP/editdrive.out"; then
    fail_case "$name" "a route failure that says nothing about the model still gated the save"; return
  fi
  disk=$(manage_edit_disk) || { fail_case "$name" "the keyless profile no longer parses"; return; }
  if [ "$disk" != "https://gw.example.test m7 fs=False" ]; then
    fail_case "$name" "an unchecked model did not save (disk: $disk)"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# The defect this closes: --edit saved `totally-not-a-real-model` against a live
# LiteLLM with a green "Saved.", and LiteLLM answers 400 to every id outside its
# model_list — so the wizard's own screen certified a setup that fails every
# message. The three promise strings say --edit "re-verifies only what that
# changed"; the model path verified nothing.
#
# Driven against the chat-adapter fixture over loopback, so the shapes a real
# server can answer with are answered by a real server. The functions are lifted
# out of the release artifact rather than re-implemented, because the whole claim
# under test is that the SHIPPED classifier reads these six shapes correctly.
#
# The auth column is the fixture's, and it is also the second thing under test:
# `open` needs no credential and stands for a saved auth=none setup, which must
# never be asked for one; every other mode 401s an unauthenticated request exactly
# like the live gateways this was measured against, and stands for the bearer
# setup that is asked, once, before anything is sent.
run_manage_edit_model_roster_case() {
  local name="manage-edit-model-roster-check" funcs out rc arm mode auth wanted url
  funcs=$(extract_funcs manage_probe_model manage_report_model_probe models_is_json curl_gw \
                        credential_value_safe safe_display)
  if [ -z "$funcs" ] || ! printf '%s\n' "$funcs" | grep -qF 'manage_probe_model()'; then
    fail_case "$name" "could not extract manage_probe_model from the release artifact"; return
  fi
  : > "$TMP/doctor.out"

  # arm|fixture-mode|auth|wanted-id|expected-rc
  local arms='advertised|open|none|fixture-echo|0
absent|open|none|totally-not-a-real-model|1
empty-roster|models-empty-data|bearer|fixture-echo|1
no-usable-id|models-no-id|bearer|fixture-echo|1
not-a-model-list|models-html|bearer|fixture-echo|3
declined|good|declined|fixture-echo|2
nothing-listening|CLOSED|none|fixture-echo|3'
  local want_rc
  while IFS='|' read -r arm mode auth wanted want_rc; do
    [ -n "$arm" ] || continue
    if [ "$mode" = "CLOSED" ]; then
      # Port 1 on loopback: reserved, never bound, refused immediately — the
      # unreachable arm without a fixture to start and stop.
      url="http://127.0.0.1:1"
    else
      start_fixture "$mode" || { fail_case "$name" "[$arm] fixture $mode failed to start"; stop_fixture; return; }
      url="http://127.0.0.1:$PORT"
    fi
    # No command substitution around the probe: it sets the MODELS_* diagnostics the
    # reporter reads, and a subshell would drop every one of them.
    out=$(FUNCS="$funcs" URL="$url" WANTED="$wanted" AUTH="$auth" FIXTOKEN="$TOKEN" bash -c '
eval "$FUNCS"
say() { printf "%s\n" "$*"; }
ok() { printf "OK %s\n" "$*"; }
warn() { printf "WARN %s\n" "$*"; }
note() { printf "NOTE %s\n" "$*"; }
explain_manage_model() { :; }
confirm() { printf "CONFIRM-ASKED\n"; [ "$AUTH" != "declined" ]; }
# The real prompt_into writes the named variable; this one writes the same one,
# which under bash 3.2 dynamic scoping is manage_probe_model own local.
prompt_into() { printf "PROMPTED\n"; GW_TOKEN="$FIXTOKEN"; return 0; }
DOCTOR=false; COMPAT=false
GW_TOKEN=""
case "$AUTH" in none) GW_AUTH="none" ;; *) GW_AUTH="bearer" ;; esac
rc=0; manage_probe_model "$URL" "$WANTED" || rc=$?
manage_report_model_probe "$rc" "$WANTED"
printf "RC %s\n" "$rc"
' 2>&1)
    [ "$mode" = "CLOSED" ] || stop_fixture
    printf -- '--- %s ---\n%s\n' "$arm" "$out" >> "$TMP/doctor.out"
    assert_runtime_defined "$name" "$out" || return
    rc=$(printf '%s\n' "$out" | sed -n 's/^RC //p')
    if [ "$rc" != "$want_rc" ]; then
      fail_case "$name" "[$arm] the roster probe returned $rc, expected $want_rc"; return
    fi
    if [ "$auth" = "none" ]; then
      # A saved setup that records auth=none has no token to be asked for, and a
      # hidden prompt on this screen is precisely what it promises not to do.
      if printf '%s\n' "$out" | grep -qE 'CONFIRM-ASKED|PROMPTED'; then
        fail_case "$name" "[$arm] a keyless setup was asked for a credential"; return
      fi
    else
      if ! printf '%s\n' "$out" | grep -qF 'CONFIRM-ASKED'; then
        fail_case "$name" "[$arm] a bearer setup reached the hidden prompt with no question first"; return
      fi
      # Declining has to stop before the secret prompt, not after it.
      if [ "$auth" = "declined" ] && printf '%s\n' "$out" | grep -qF 'PROMPTED'; then
        fail_case "$name" "[$arm] a declined check still asked for the token"; return
      fi
    fi
    case "$want_rc" in
      0) if ! printf '%s\n' "$out" | grep -qF "OK That server's model list carries $wanted"; then
           fail_case "$name" "[$arm] an advertised id was not confirmed"; return
         fi ;;
      1) if ! printf '%s\n' "$out" | grep -qE "does NOT carry $wanted|names no model id at all"; then
           fail_case "$name" "[$arm] an id the server does not advertise was not called out"; return
         fi
         # The count and the first id are what turn "not in the list" into something
         # the operator can act on — and the disclaimer is what stops the first id
         # reading as a recommendation.
         if [ "$arm" = "absent" ] && ! printf '%s\n' "$out" | grep -qF 'It advertises 2 model id(s); the first is fixture-echo'; then
           fail_case "$name" "[$arm] the warning named neither how many ids the server has nor one of them"; return
         fi ;;
      2|3) if ! printf '%s\n' "$out" | grep -qF 'Not checked'; then
             fail_case "$name" "[$arm] a check that was not made did not say so"; return
           fi
           if printf '%s\n' "$out" | grep -qF 'does NOT carry'; then
             fail_case "$name" "[$arm] a server that produced no model list was read as denying the id"; return
           fi ;;
    esac
  done <<EOF
$arms
EOF
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# ONE of the four probe outcomes may stop a save, and the other three may not.
# That split is the whole design: "this server's list does not carry that id" is
# evidence about the value going to disk, while "the tunnel is down", "the token
# was refused" and "you skipped the check" are facts about the route or about this
# screen. A confirmation that cannot tell a good save from a bad one is a keystroke
# that teaches the operator to answer y — and it would fire constantly, because
# whoever's tunnel is down is exactly whoever opens this screen.
#
# Driven with a stubbed probe, deliberately: every rc is reachable in one place,
# and no lane depends on a network. The second assertion in each arm is the one
# that would have caught the older shape — choose_saved_model writes GW_MODEL the
# moment it is answered, so a declined save that did not put it back would leave
# the rejected candidate on the screen and ride the next save of any other field.
run_manage_edit_model_gate_case() {
  local name="manage-edit-model-gates-only-an-answered-roster" funcs out arm rc answer
  funcs=$(extract_funcs manage_edit_model)
  if [ -z "$funcs" ] || ! printf '%s\n' "$funcs" | grep -qF 'manage_edit_model()'; then
    fail_case "$name" "could not extract manage_edit_model from the release artifact"; return
  fi
  : > "$TMP/doctor.out"

  # arm|probe-rc|gate-answer|expect-gate|expect-saved
  local arms='advertised|0|y|no|yes
absent-saved-anyway|1|y|yes|yes
absent-declined|1|n|yes|no
not-checked-skipped|2|y|no|yes
not-checked-failed|3|y|no|yes'
  local want_gate want_saved
  while IFS='|' read -r arm rc answer want_gate want_saved; do
    [ -n "$arm" ] || continue
    out=$(FUNCS="$funcs" PRC="$rc" ANS="$answer" bash -c '
eval "$FUNCS"
say() { printf "%s\n" "$*"; }
ok() { printf "OK %s\n" "$*"; }
warn() { printf "WARN %s\n" "$*"; }
note() { printf "NOTE %s\n" "$*"; }
safe_display() { printf "%s" "$1"; }
mutate_guard() { :; }
BOLD=""; RESET=""
GW_URL="https://gw.example.test"; GW_AUTH="bearer"; GW_MODEL="old-model"
# The operator picks "use a different model name" and types one.
choose_saved_model() { GW_MODEL="candidate-model"; }
manage_probe_model() { return "$PRC"; }
manage_report_model_probe() { printf "REPORTED %s\n" "$1"; }
confirm() { printf "GATE-ASKED\n"; [ "$ANS" = "y" ]; }
manage_save_and_prove() { printf "SAVED %s\n" "$3"; return 0; }
manage_edit_model custom-a true
printf "LEFT-IN-STATE %s\n" "$GW_MODEL"
' 2>&1)
    printf -- '--- %s ---\n%s\n' "$arm" "$out" >> "$TMP/doctor.out"
    assert_runtime_defined "$name" "$out" || return

    case "$want_gate" in
      yes) if ! printf '%s\n' "$out" | grep -qF 'GATE-ASKED'; then
             fail_case "$name" "[$arm] a roster that does not carry the id saved with no confirmation"; return
           fi ;;
      no)  if printf '%s\n' "$out" | grep -qF 'GATE-ASKED'; then
             fail_case "$name" "[$arm] the save was gated on something that says nothing about the model id"; return
           fi ;;
    esac
    case "$want_saved" in
      yes) if ! printf '%s\n' "$out" | grep -qF 'SAVED candidate-model'; then
             fail_case "$name" "[$arm] the new model never reached the disk"; return
           fi
           if ! printf '%s\n' "$out" | grep -qF 'LEFT-IN-STATE candidate-model'; then
             fail_case "$name" "[$arm] a saved model is not what the screen behind this will reprint"; return
           fi ;;
      no)  if printf '%s\n' "$out" | grep -qF 'SAVED'; then
             fail_case "$name" "[$arm] a refused model was written anyway"; return
           fi
           if ! printf '%s\n' "$out" | grep -qF 'LEFT-IN-STATE old-model'; then
             fail_case "$name" "[$arm] a refused candidate stayed in the screen's state and would ride the next save"; return
           fi ;;
    esac
    # The report is always printed, whatever the outcome — a silent probe would
    # leave the operator with a green "Saved." and no idea what was checked.
    if ! printf '%s\n' "$out" | grep -qF "REPORTED $rc"; then
      fail_case "$name" "[$arm] the probe's finding was never put on screen"; return
    fi
  done <<EOF
$arms
EOF
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# A file lane whose password lives ONLY in its service unit is not an edge case —
# it is what a machine looks like after the state directory is restored from a
# backup that skipped 0600 files, or after a lane built by an older run. The edit
# screen refused every save for those setups, which is the population most likely
# to be sitting in front of it.
#
# The unit is read as a THIRD credential source, and the second assertion is the
# one that makes reading it safe: the password appears nowhere in the transcript.
# A screen that recovered the credential and then printed it would satisfy every
# other line here.
run_manage_edit_unit_credential_case() {
  local name="manage-edit-loads-a-unit-only-credential" disk sentinel unit
  sentinel='SENTINELUNITPW-must-never-be-printed-91c4'
  : > "$TMP/doctor.out"
  local lane='{"schemaVersion":1,"gateway":{"id":"custom-a","kind":"custom","name":"Lane gateway","auth":"bearer","transport":"public","reach":"public","url":"https://gw.example.test"},"fileServer":{"url":"https://files.example.test:8443","folder":"@WORK@","reach":"public","localPort":"8081"}}'
  manage_edit_fixture fs-unit "$lane"
  # No .cred and no .env on purpose — the unit is the only copy.
  if [ "$(uname -s)" = "Linux" ]; then
    unit="$EDIT_HOME/.config/systemd/user/conduck-files-custom-a.service"
    printf '[Service]\nExecStart=/usr/local/bin/rclone serve webdav %s --addr 127.0.0.1:8081 --user conduck --pass %s\n' \
      "$EDIT_WORK" "$sentinel" > "$unit"
  else
    unit="$EDIT_HOME/Library/LaunchAgents/ai.gigaduck.conduck-files-custom-a.plist"
    printf '<?xml version="1.0"?><plist version="1.0"><dict><key>Label</key><string>x</string><key>ProgramArguments</key><array><string>/usr/local/bin/rclone</string><string>serve</string><string>webdav</string><string>%s</string><string>--addr</string><string>127.0.0.1:8081</string><string>--user</string><string>conduck</string><string>--pass</string><string>%s</string></array></dict></plist>\n' \
      "$EDIT_WORK" "$sentinel" > "$unit"
  fi
  if [ -f "$EDIT_SD/fileserver-custom-a.cred" ] || [ -f "$EDIT_SD/fileserver-custom-a.env" ]; then
    fail_case "$name" "the fixture left a credential file — the unit is not the only copy"; return
  fi
  if ! grep -qF "$sentinel" "$unit"; then
    fail_case "$name" "the sentinel never reached the unit — the absence assertion below would be vacuous"; return
  fi

  manage_edit_run '1\nhttps://moved.example.test\ny\nn\nq\n' --edit custom-a
  # The transcript is appended with the sentinel masked; a leak is named by the
  # assertion that caught it, never reprinted into the suite's own log.
  sed -i.bak "s/$sentinel/[sentinel]/g" "$TMP/doctor.out" && rm -f "$TMP/doctor.out.bak"
  assert_runtime_defined "$name" "$(cat "$TMP/editdrive.out")" || return
  if [ "$EDIT_RC" = "124" ]; then
    fail_case "$name" "the unit-credential lane hung"; return
  fi
  if grep -qF 'stored password is not in' "$TMP/editdrive.out"; then
    fail_case "$name" "the screen refused to save a lane whose password is in its own service unit"; return
  fi
  if ! grep -qF '✓ Saved.' "$TMP/editdrive.out"; then
    fail_case "$name" "the address change was not saved"; return
  fi
  disk=$(manage_edit_disk) || { fail_case "$name" "the rewritten profile no longer parses"; return; }
  # fs=True is the point: write_profile reads FS_CRED as a boolean and drops the
  # whole fileServer block without one, so a save that could not recover the
  # credential would silently turn a file lane into a chat-only record.
  if [ "$disk" != "https://moved.example.test None fs=True" ]; then
    fail_case "$name" "the save lost the file lane it could not have rebuilt (disk: $disk)"; return
  fi
  if grep -qF "$sentinel" "$TMP/editdrive.out"; then
    fail_case "$name" "the screen printed the password it recovered from the service unit"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# --list is the surface whose whole job is to report what is on this machine, and
# the leftovers scan is the part of it nobody else does: a service unit with no
# profile behind it is a live authenticated WebDAV server over the agent's working
# folder, restarted at every login, that nothing else in the tool would mention
# again. That scan globs paths under $HOME — and under `set -u`, a bare $HOME with
# no HOME in the environment is a fatal expansion.
#
# The consequence is worse than a crash, which is why this case exists at all. The
# scan runs inside $(…) in a here-doc, so `set -u` kills the SUBSHELL: --list still
# exits 0, still prints an inventory, and reports `"leftovers": []`. A machine
# consumer gets a clean, confident, wrong answer with no diagnostic anywhere.
#
# HOME unset is not exotic: cron, systemd units without User=, `env -i` wrappers and
# container entrypoints all produce it, and XDG_CONFIG_HOME set with HOME unset is
# exactly how a service account is configured.
#
# The third lane is the one that keeps the other two honest. `${HOME:-}` also buys
# silence — a scan that found nothing would pass every assertion about diagnostics —
# so the same scan, with HOME set and an orphan unit seeded, must still find it and
# still print the command that removes it.
run_manage_missing_home_case() {
  local name="manage-list-survives-a-missing-home" rc out
  local state="$TMP/nohome-state" sd="$TMP/nohome-state/conduck"
  local ohome="$TMP/nohome-orphan-home" ostate="$TMP/nohome-orphan-state"
  mkdir -p "$sd" "$ohome/Library/LaunchAgents" "$ohome/.config/systemd/user" "$ostate/conduck"
  : > "$TMP/doctor.out"
  write_valid_profile "$sd/profile-custom-good.json" \
    "custom-good" "Good gateway" "https://good.example.test"

  local lane
  for lane in human json; do
    rc=0
    if [ "$lane" = "json" ]; then
      env -u CI -u HOME XDG_CONFIG_HOME="$state" TERM=dumb bash "$SCRIPT" --list --json \
        > "$TMP/nohome-$lane.out" 2>&1 </dev/null || rc=$?
    else
      env -u CI -u HOME XDG_CONFIG_HOME="$state" TERM=dumb bash "$SCRIPT" --list \
        > "$TMP/nohome-$lane.out" 2>&1 </dev/null || rc=$?
    fi
    printf -- '--- --list (%s), HOME unset, rc=%s ---\n' "$lane" "$rc" >> "$TMP/doctor.out"
    cat "$TMP/nohome-$lane.out" >> "$TMP/doctor.out"
    assert_runtime_defined "$name" "$(cat "$TMP/nohome-$lane.out")" || return
    if [ "$rc" != "0" ]; then
      fail_case "$name" "--list ($lane) with HOME unset exited $rc, expected 0"; return
    fi
    # Both streams, because the expansion error goes to stderr and the two lanes
    # are captured together for exactly that reason.
    if grep -qF 'unbound variable' "$TMP/nohome-$lane.out"; then
      fail_case "$name" "--list ($lane) with HOME unset expanded an unset variable"; return
    fi
    # Any bash diagnostic, not just that one: a `line NNN:` prefix is the shell
    # talking about the script, and none of it belongs in either lane's output.
    if grep -qE '^[^ ]*: line [0-9]+:' "$TMP/nohome-$lane.out"; then
      fail_case "$name" "--list ($lane) with HOME unset printed a shell diagnostic"; return
    fi
  done
  # The JSON lane owes a parser both arrays, not merely valid JSON: the failure this
  # case is about produced a perfectly valid document with an empty leftovers[].
  out=$(python3 - "$TMP/nohome-json.out" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print("setups=%d leftovers=%d" % (len(d["setups"]), len(d["leftovers"])))
PY
) || { fail_case "$name" "--list --json with HOME unset did not parse as JSON"; return; }
  printf -- '%s\n' "$out" >> "$TMP/doctor.out"
  if ! printf '%s\n' "$out" | grep -qF 'setups=1'; then
    fail_case "$name" "--list --json with HOME unset lost the setup it can see without a home directory"; return
  fi

  # The scan still works. Without this lane, rooting the globs at nothing would pass
  # everything above by reporting nothing at all.
  if [ "$(uname -s)" = "Linux" ]; then
    printf '[Service]\nExecStart=/usr/local/bin/rclone serve webdav /tmp/ghostfolder --addr 127.0.0.1:8080\n' \
      > "$ohome/.config/systemd/user/conduck-files-ghost.service"
  else
    printf '<?xml version="1.0"?><plist version="1.0"><dict><key>Label</key><string>x</string><key>ProgramArguments</key><array><string>/usr/local/bin/rclone</string><string>serve</string><string>webdav</string><string>/tmp/ghostfolder</string><string>--addr</string><string>127.0.0.1:8080</string></array></dict></plist>\n' \
      > "$ohome/Library/LaunchAgents/ai.gigaduck.conduck-files-ghost.plist"
  fi
  rc=0
  env -u CI HOME="$ohome" XDG_CONFIG_HOME="$ostate" TERM=dumb bash "$SCRIPT" --list \
    > "$TMP/nohome-orphan.out" 2>&1 </dev/null || rc=$?
  printf -- '--- --list with HOME set and an orphan unit, rc=%s ---\n' "$rc" >> "$TMP/doctor.out"
  cat "$TMP/nohome-orphan.out" >> "$TMP/doctor.out"
  assert_runtime_defined "$name" "$(cat "$TMP/nohome-orphan.out")" || return
  if [ "$rc" != "0" ]; then
    fail_case "$name" "--list with an orphan unit exited $rc, expected 0"; return
  fi
  if ! grep -qF 'File servers with no saved setup behind them' "$TMP/nohome-orphan.out"; then
    fail_case "$name" "the leftovers scan went quiet — the HOME-unset lanes above prove nothing"; return
  fi
  if ! grep -qF '/tmp/ghostfolder' "$TMP/nohome-orphan.out"; then
    fail_case "$name" "an orphan file server was reported without the folder it serves"; return
  fi
  if ! grep -qF 'bash conduck-connect.sh --forget ghost' "$TMP/nohome-orphan.out"; then
    fail_case "$name" "an orphan file server was reported with no way to remove it"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# Which modifiers each command takes, every cell of it. CLI_REJECTION_CASES samples
# a handful of the interesting ones; the two defects fixed in this release both lived
# in cells it does not cover — `--show-code --reuse-only` and `--list --reuse-only`
# were accepted in silence, and `--edit`/`--forget --reuse-only` walked a picker, a
# setup summary and a live probe before refusing. All four were flags --help had
# always scoped away from those commands.
#
# A sampled table cannot catch that class, because the defect IS the cell nobody
# thought to sample. So this case enumerates COMMANDS × CLI_MODIFIERS and grades
# every cell against the accept lists spelled out below — which are --help's own
# "With --setup: / With --list: / With --check-adapter:" scoping, written down a
# second time on purpose. Two independent statements of the same rule disagree
# loudly; one statement drifts in silence.
#
# The modifier list is read out of the artifact rather than hardcoded, so a new
# modifier appears in the matrix the day it is added — and the assertion that the
# list still matches this table is what forces somebody to say, here, which commands
# take it. That is the whole point of a default-DENY design: forgetting costs a red
# test rather than a silent permission.
#
# Isolated, against the real validate_cli, because the alternative is running seven
# commands for real: the ACCEPT cells would send live requests to example.com and
# open interactive screens, and a matrix that slow gets sampled again. The four
# newly-refused cells are ALSO driven end to end, by run_manage_reuse_only_case.
run_cli_matrix_isolated() {
  FUNCS="$1" MODS="$2" bash -c '
eval "$FUNCS"
eval "CLI_MODIFIERS=$MODS"
usage_die() { printf "REFUSED %s\n" "$*"; exit 2; }
die() { printf "DIED %s\n" "$*"; exit 3; }
# The URL grader and the userinfo check belong to the check arms and have their own
# cases; here they must simply not reject, or every check cell would refuse for a
# reason that is not the modifier under test.
doctor_accept_url() { printf "%s" "$1"; }
url_has_userinfo() { return 1; }
URL_USERINFO_HINT="a credential was in that URL"
for COMMAND in setup check-server check-adapter show-code list edit forget; do
  for m in $CLI_MODIFIERS; do
    ( CLI_DRY_RUN=false; CLI_REUSE_ONLY=false; CLI_DOCTOR_DEEP=false
      CLI_DOCTOR_FILES=false; CLI_ALLOW_KEYLESS_PUBLIC=false; CLI_MANAGE_JSON=false
      CLI_POSITIONAL=""
      case "$m" in
        positional)           CLI_POSITIONAL="https://example.com" ;;
        dry-run)              CLI_DRY_RUN=true ;;
        reuse-only)           CLI_REUSE_ONLY=true ;;
        deep)                 CLI_DOCTOR_DEEP=true ;;
        files)                CLI_DOCTOR_FILES=true ;;
        allow-keyless-public) CLI_ALLOW_KEYLESS_PUBLIC=true ;;
        json)                 CLI_MANAGE_JSON=true ;;
      esac
      # --forget is the one command with a REQUIRED positional, and it refuses a
      # missing one before it grades any flag. Without an id every forget cell
      # would report that refusal instead of the modifier verdict under test.
      if [ "$COMMAND" = forget ] && [ "$m" != positional ]; then CLI_POSITIONAL="custom-good"; fi
      out=$(validate_cli 2>&1); rc=$?
      printf "CELL %s %s rc=%s | %s\n" "$COMMAND" "$m" "$rc" "$out"
    )
  done
done
# The typo guard, driven directly: cli_modifier_set is the only reader of the flag
# globals, so a name in CLI_MODIFIERS it does not know would silently never be
# checked — a permission granted by a spelling mistake.
( out=$(cli_modifier_set not-a-real-modifier 2>&1); printf "TYPO rc=%s | %s\n" "$?" "$out" )
'
}

run_cli_matrix_case() {
  local name="cli-modifier-matrix" funcs mods out row cmd mod rc want accepted
  : > "$TMP/doctor.out"
  funcs=$(extract_funcs validate_cli cli_accept_only cli_modifier_set cli_modifier_refusal)
  mods=$(sed -n 's/^CLI_MODIFIERS=//p' "$SCRIPT")
  if [ -z "$mods" ]; then
    fail_case "$name" "CLI_MODIFIERS could not be read out of the artifact"; return
  fi
  out=$(run_cli_matrix_isolated "$funcs" "$mods")
  printf -- '--- command x modifier matrix ---\n%s\n' "$out" >> "$TMP/doctor.out"
  assert_runtime_defined "$name" "$out" || return

  # The list itself. A modifier added to the argument loop and not classified below
  # would otherwise be graded against an accept list that has never heard of it.
  eval "mods=$mods"
  if [ "$mods" != "positional dry-run reuse-only deep files allow-keyless-public json" ]; then
    fail_case "$name" "CLI_MODIFIERS changed to '$mods' — every command's accept list in this case needs a decision about it"; return
  fi

  # Each command's accept list, from --help's scoping. Everything not named here
  # must exit 2. show-code accepts NOTHING, which is the whole of its arm.
  local pairs='
setup|dry-run reuse-only allow-keyless-public
check-server|positional
check-adapter|positional deep files
show-code|
list|json
edit|positional
forget|positional
'
  local cells=0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    cmd="${row%%|*}"; accepted=" ${row#*|} "
    for mod in $mods; do
      cells=$((cells+1))
      rc=$(printf '%s\n' "$out" | sed -n "s/^CELL $cmd $mod rc=\([0-9]*\) .*/\1/p")
      if [ -z "$rc" ]; then
        fail_case "$name" "the matrix never graded $cmd × $mod"; return
      fi
      case "$accepted" in
        *" $mod "*)
          if [ "$rc" = "2" ]; then
            fail_case "$name" "--$cmd refuses $mod, which --help says it takes"; return
          fi ;;
        *)
          if [ "$rc" != "2" ]; then
            fail_case "$name" "--$cmd accepted $mod (exit $rc) — --help scopes that flag away from it"; return
          fi
          # Named, not just refused. A refusal that does not say which flag it is
          # about leaves the operator to guess which of two they typed was wrong.
          # `positional` has no flag spelling, so its arm is graded on saying what
          # a bare argument means for this command instead.
          if [ "$mod" = "positional" ]; then
            if ! printf '%s\n' "$out" | grep -qE "^CELL $cmd positional rc=2 \| REFUSED .*(id|URL|argument)"; then
              fail_case "$name" "--$cmd refused a bare argument without saying what one would have meant"; return
            fi
          else
            if ! printf '%s\n' "$out" | grep -qF "CELL $cmd $mod rc=2 | REFUSED " ||
               ! printf '%s\n' "$out" | sed -n "s/^CELL $cmd $mod rc=2 | //p" | grep -qF -- "--$mod"; then
              fail_case "$name" "--$cmd refused $mod without naming the flag"; return
            fi
          fi ;;
      esac
    done
  done <<EOF
$pairs
EOF
  if [ "$cells" != "49" ]; then
    fail_case "$name" "graded $cells cells, expected 49 — a command or a modifier went missing"; return
  fi

  # A name the argument loop cannot set stops the run rather than reading as a
  # silent permission. Exit 3 is this harness's stub for die.
  if ! printf '%s\n' "$out" | grep -qF "TYPO rc=3 | DIED Internal error: unknown CLI modifier 'not-a-real-modifier'."; then
    fail_case "$name" "an unknown modifier name did not stop the run — a typo in an accept list would read as permission"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# The four commands --help has always scoped away from --reuse-only, end to end.
# The matrix above grades validate_cli directly; this case grades what an operator
# actually gets, and its subject is WHEN the refusal happens rather than whether.
#
# Exit 2 alone is not the assertion and must not be: exit 2 was already reachable
# for --edit and --forget before this was fixed. What was broken is that it arrived
# LAST — --forget printed the setup summary, the full "This removes, on this
# machine:" manifest and the "This does NOT touch:" list, and --edit walked the
# picker and the "Change one thing" menu, and only then refused. A refusal that
# arrives after the disclosure has already been read is not a refusal an operator
# can distinguish from a bug, and for --edit it also means an answer has been
# consumed off stdin.
#
# So each lane asserts the absence of the screen it must never reach, and the
# presence half is not needed here: three other cases prove those screens DO render
# on the same invocations without the flag.
run_manage_reuse_only_case() {
  local name="reuse-only-is-refused-before-anything-is-asked" lane cmd arg rc
  local home="$TMP/reuseonly-home" state="$TMP/reuseonly-state" sd="$TMP/reuseonly-state/conduck"
  mkdir -p "$home" "$sd"
  : > "$TMP/doctor.out"
  write_valid_profile "$sd/profile-custom-good.json" \
    "custom-good" "Good gateway" "https://good.example.test"
  PTY_ENV=(HOME="$home" XDG_CONFIG_HOME="$state")

  # A PTY, not a pipe: --edit and --forget refuse a run with nobody at a terminal
  # at exit 4, which would hide the flag refusal behind a different one.
  for lane in "edit|--edit|custom-good" "forget|--forget|custom-good" \
              "show-code|--show-code|" "list|--list|"; do
    lane="${lane#*|}"; cmd="${lane%%|*}"; arg="${lane#*|}"
    rc=0
    if [ -n "$arg" ]; then
      pty_run 20 $'\n' "$cmd" "$arg" --reuse-only > "$TMP/reuseonly.out" 2>&1 || rc=$?
    else
      pty_run 20 $'\n' "$cmd" --reuse-only > "$TMP/reuseonly.out" 2>&1 || rc=$?
    fi
    printf -- '--- %s %s --reuse-only rc=%s ---\n' "$cmd" "$arg" "$rc" >> "$TMP/doctor.out"
    cat "$TMP/reuseonly.out" >> "$TMP/doctor.out"
    assert_runtime_defined "$name" "$(cat "$TMP/reuseonly.out")" || return
    if [ "$rc" != "2" ]; then
      fail_case "$name" "$cmd --reuse-only exited $rc, expected a usage error (2)"; return
    fi
    if ! grep -qF 'Usage error:' "$TMP/reuseonly.out"; then
      fail_case "$name" "$cmd --reuse-only did not identify itself as a usage error"; return
    fi
    if ! grep -qF -- '--reuse-only is a setup modifier' "$TMP/reuseonly.out"; then
      fail_case "$name" "$cmd --reuse-only did not name the flag it refused"; return
    fi
    # Nothing ran. Each of these strings belongs to a screen that only appears once
    # the command has committed to doing its job.
    if grep -qF 'Change one thing' "$TMP/reuseonly.out"; then
      fail_case "$name" "$cmd --reuse-only opened the edit screen before refusing"; return
    fi
    if grep -qF 'This removes, on this machine:' "$TMP/reuseonly.out"; then
      fail_case "$name" "$cmd --reuse-only printed a removal manifest before refusing"; return
    fi
    if grep -qF 'Which one?' "$TMP/reuseonly.out"; then
      fail_case "$name" "$cmd --reuse-only asked which setup before refusing"; return
    fi
    if grep -qF 'Good gateway' "$TMP/reuseonly.out"; then
      fail_case "$name" "$cmd --reuse-only rendered a saved setup before refusing"; return
    fi
    # …and it did not touch the fixture either.
    if [ ! -f "$sd/profile-custom-good.json" ]; then
      fail_case "$name" "$cmd --reuse-only removed a setup on a run it refused"; return
    fi
  done
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# "Saved." is a claim about a file on disk, and write_profile is not in a position
# to back it up: it WARNS and returns 0 on every failure it has — a state directory
# it cannot create, a python that would not build the document, a temp file it could
# not write or rename. That is the right contract for the wizard, where a pairing is
# complete whether or not the convenience record got written. On the edit screen the
# save IS the action, and the pre-fix screen printed a green
# "✓ Saved. … now points at https://moved.example.test" directly underneath
# write_profile's own "Couldn't save the pairing profile" warning, then offered to
# print a setup code carrying the address that was never recorded. The operator
# finds out days later, on a phone.
#
# A mode-500 state directory is the cheapest honest reproduction: readable, so the
# profile still loads and the whole screen still runs, and unwritable, so the rename
# fails for a reason the tool genuinely encounters (a directory owned by another
# account, a full disk, a file something else is holding).
#
# Every read-only lane is PAIRED with the identical drive on a writable directory.
# Without the pair, "does not print ✓ Saved." is satisfied by a screen that never
# got as far as saving anything, and "the disk is unchanged" by a fixture nobody
# ever tried to write.
run_manage_save_must_land_case() {
  local name="manage-edit-reports-a-save-that-did-not-land" lane
  local label mode keys want_saved home state sd rc disk
  : > "$TMP/doctor.out"

  # label|dir mode|keys|does this lane's write land?
  # The address lanes carry an extra answer: a save that lands offers a setup code,
  # and the offer has to be declined or the run blocks on it. The two lanes that
  # NAME a model carry one too — this is a bearer setup, so the roster check is
  # offered before the save, and the n declines it. Clearing the model asks
  # nothing, because there is no id to look up.
  for lane in \
    "addr-ro|500|1\nhttps://moved.example.test\ny\nq\n|no" \
    "addr-rw|700|1\nhttps://moved.example.test\ny\nn\nq\n|yes" \
    "model-ro|500|2\n2\nm2\nn\nq\n|no" \
    "model-rw|700|2\n2\nm2\nn\nq\n|yes" \
    "clear-ro|500|2\n3\nq\n|no" \
    "clear-rw|700|2\n3\nq\n|yes" \
  ; do
    label="${lane%%|*}"; lane="${lane#*|}"
    mode="${lane%%|*}"; lane="${lane#*|}"
    keys="${lane%%|*}"; want_saved="${lane#*|}"

    home="$TMP/savland-$label-home"; state="$TMP/savland-$label-state"
    sd="$state/conduck"
    mkdir -p "$home" "$sd"
    printf '{"schemaVersion":1,"gateway":{"id":"custom-ro","kind":"custom","name":"Read only gateway","auth":"bearer","transport":"public","reach":"public","url":"https://gw.example.test","model":"m1"},"fileServer":null}\n' \
      > "$sd/profile-custom-ro.json"
    chmod "$mode" "$sd"
    PTY_ENV=(HOME="$home" XDG_CONFIG_HOME="$state")
    rc=0
    lane=$(printf '%b_' "$keys"); lane="${lane%_}"
    pty_run 40 "$lane" --edit custom-ro > "$TMP/savland.out" 2>&1 || rc=$?
    # Immediately, and before any assertion can return early: the suite's own EXIT
    # trap cannot rm -rf a directory it may not write into.
    chmod 700 "$sd"
    printf -- '--- lane %s (mode %s) rc=%s ---\n' "$label" "$mode" "$rc" >> "$TMP/doctor.out"
    cat "$TMP/savland.out" >> "$TMP/doctor.out"
    assert_runtime_defined "$name" "$(cat "$TMP/savland.out")" || return
    if [ "$rc" = "124" ]; then
      fail_case "$name" "lane $label hung on the edit screen"; return
    fi

    disk=$(python3 - "$sd/profile-custom-ro.json" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))["gateway"]
print("%s %s" % (g["url"], g.get("model")))
PY
) || { fail_case "$name" "lane $label left a profile that no longer parses"; return; }
    printf -- 'disk: %s\n' "$disk" >> "$TMP/doctor.out"

    if [ "$want_saved" = "no" ]; then
      if ! grep -qF 'NOT saved.' "$TMP/savland.out"; then
        fail_case "$name" "lane $label did not say the write had failed"; return
      fi
      if grep -qF '✓ Saved.' "$TMP/savland.out"; then
        fail_case "$name" "lane $label reported a save that never reached the disk"; return
      fi
      # The offer is the second half of the lie: a setup code built from an address
      # the file does not hold would put the unsaved value on the phone.
      if grep -qF 'Show the new setup code now?' "$TMP/savland.out"; then
        fail_case "$name" "lane $label offered a setup code for a change that was not recorded"; return
      fi
      if [ "$disk" != "https://gw.example.test m1" ]; then
        fail_case "$name" "lane $label changed the profile it had just said it could not write (disk: $disk)"; return
      fi
    else
      if grep -qF 'NOT saved.' "$TMP/savland.out"; then
        fail_case "$name" "lane $label reported a failure on a directory it can write"; return
      fi
      if ! grep -qF '✓ Saved.' "$TMP/savland.out"; then
        fail_case "$name" "lane $label saved nothing on a writable directory — the read-only lane proves nothing"; return
      fi
      case "$label" in
        addr-rw)
          if ! grep -qF 'Show the new setup code now?' "$TMP/savland.out"; then
            fail_case "$name" "a landed address change did not offer the setup code that carries it"; return
          fi
          if [ "$disk" != "https://moved.example.test m1" ]; then
            fail_case "$name" "a landed address change did not reach the disk (disk: $disk)"; return
          fi ;;
        model-rw)
          if [ "$disk" != "https://gw.example.test m2" ]; then
            fail_case "$name" "a landed model change did not reach the disk (disk: $disk)"; return
          fi ;;
        clear-rw)
          # None, not the empty string: clearing the model must remove the key, or
          # the app is handed a pin on a model with no name.
          if [ "$disk" != "https://gw.example.test None" ]; then
            fail_case "$name" "clearing the model did not remove it from the disk (disk: $disk)"; return
          fi ;;
      esac
    fi
  done
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# --forget's disclosure is a claim about what will be left behind, and the most
# dangerous thing it can leave behind is a PUBLIC one: a Tailscale Funnel is an
# address on the open internet, and the record that names it lives in the state
# directory this command is emptying.
#
# read_exposure_record refuses any record whose format version is not the current
# one — that is correct, the id field the teardown depends on only arrived with the
# current version — but "cannot read" was being spelled `continue`. So on every
# machine an older conduck-connect ever touched, --forget removed the profile, the
# unit and the password, reported a clean removal, and said nothing at all about a
# public route it had just lost the last on-disk trace of. Silence there is worse
# than a wrong answer: there is nothing left to go looking with.
#
# The case is a PAIR, and the pair is the assertion. The v1 lane proves the record
# is named; the v2 lane, identical but for the version byte and the id, proves the
# ordinary disclosure still works and that the v1 lane is not passing because this
# fixture makes every run print the block. A shim `tailscale` on PATH is required
# for either: the whole exposure section is skipped unless `serve status --json`
# resolves, so without it both lanes go quiet and both assertions become vacuous.
run_manage_forget_exposure_case() {
  local name="manage-forget-discloses-unreadable-exposures" lane rc out
  local label ver gwid home state sd unit credf envf rec want_rc
  : > "$TMP/doctor.out"

  # The shim answers exactly the one question ts_targets asks, and refuses
  # everything else — a teardown that shelled out to `tailscale funnel … off`
  # would fail loudly here rather than quietly appearing to have worked.
  mkdir -p "$TMP/forgetexp-bin"
  cat > "$TMP/forgetexp-bin/tailscale" <<'SHIM'
#!/usr/bin/env bash
if [ "$1" = "serve" ] && [ "$2" = "status" ] && [ "$3" = "--json" ]; then
  printf '%s\n' '{"Web":{"box.tail1234.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8080"}}}},"AllowFunnel":{"box.tail1234.ts.net:8443":true}}'
  exit 0
fi
exit 1
SHIM
  chmod +x "$TMP/forgetexp-bin/tailscale"

  # label|record version|record's gateway id
  # A v1 record has no gateway-id field at all, so `unknown` is what a v1 line's
  # sixth column reads as here — and it is why the record can never be attributed
  # to the setup being removed, which is why it is reported rather than closed.
  for lane in "v1|1|unknown" "v2|2|custom-a"; do
    label="${lane%%|*}"; lane="${lane#*|}"
    ver="${lane%%|*}"; gwid="${lane#*|}"

    home="$TMP/forgetexp-$label-home"; state="$TMP/forgetexp-$label-state"
    sd="$state/conduck"
    mkdir -p "$home/Library/LaunchAgents" "$home/.config/systemd/user" "$sd"
    printf '{"schemaVersion":1,"gateway":{"id":"custom-a","kind":"custom","name":"Tailnet gateway","auth":"bearer","transport":"tailscale","reach":"public","url":"https://box.tail1234.ts.net:8443"},"fileServer":null}\n' \
      > "$sd/profile-custom-a.json"
    # The things the removal really does prove it removed. They are seeded so the
    # case can assert that reporting a leftover did NOT turn the removal into a
    # no-op — a "safe" fix that refused to remove anything while an unreadable
    # record existed would satisfy the disclosure assertions and break the command.
    #
    # No SERVICE UNIT in this fixture, deliberately. Removing one is gated on this
    # host being able to answer whether that service is running, and a machine
    # where launchctl/systemctl cannot answer gets the correct, different outcome:
    # the file is left alone rather than deleted on a guess, and the command exits
    # 1. That is a real behaviour with its own coverage, and folding it in here
    # would make THIS case's verdict depend on the host it runs on rather than on
    # whether an unreadable exposure record is disclosed.
    credf="$sd/fileserver-custom-a.cred"; envf="$sd/fileserver-custom-a.env"
    printf 'conduck:not-a-real-password\n' > "$credf"
    printf 'RCLONE_PASS=not-a-real-password\n' > "$envf"
    unit="$home/Library/LaunchAgents/ai.gigaduck.conduck-files-custom-a.plist"
    rm -f "$unit" "$home/.config/systemd/user/conduck-files-custom-a.service"
    rec="$sd/exposure-oldrun-001.pending"
    printf '%s\tgateway\t8443\tfunnel\thttp://127.0.0.1:8080\t%s\tEMPTY\n' "$ver" "$gwid" > "$rec"

    PTY_ENV=(HOME="$home" XDG_CONFIG_HOME="$state" PATH="$TMP/forgetexp-bin:$PATH")
    rc=0
    pty_run 30 $'custom-a\n' --forget custom-a > "$TMP/forgetexp.out" 2>&1 || rc=$?
    printf -- '--- lane %s (record version %s) rc=%s ---\n' "$label" "$ver" "$rc" >> "$TMP/doctor.out"
    cat "$TMP/forgetexp.out" >> "$TMP/doctor.out"
    assert_runtime_defined "$name" "$(cat "$TMP/forgetexp.out")" || return
    if [ "$rc" = "124" ]; then
      fail_case "$name" "lane $label hung instead of completing the removal"; return
    fi
    # The two lanes exit differently, and the shim above is the reason. The v1
    # record belongs to nobody, so no close is ever attempted and the removal is
    # complete: rc 0. The v2 record IS this setup's, so the close is attempted — and
    # this fixture's `tailscale` answers everything but the status read with exit 1,
    # deliberately, so the route is still live on the re-read. An address this
    # command tried to close and could not prove closed is "some of it is still
    # there", which the command reports on screen and answers with rc 1.
    want_rc=0
    [ "$label" = "v2" ] && want_rc=1
    if [ "$rc" != "$want_rc" ]; then
      fail_case "$name" "lane $label exited $rc, expected $want_rc"; return
    fi

    # Whichever lane this is, the removal it DID prove has to have happened. This
    # is asserted before the disclosure text, because a case that only graded the
    # warning would be green on a build that printed a beautiful warning and
    # removed nothing.
    if ! grep -qF 'Removed the saved setup' "$TMP/forgetexp.out"; then
      fail_case "$name" "lane $label never reported the removal"; return
    fi
    if [ -f "$sd/profile-custom-a.json" ]; then
      fail_case "$name" "lane $label left the saved setup on disk"; return
    fi
    if [ -f "$credf" ] || [ -f "$envf" ]; then
      fail_case "$name" "lane $label left the stored password on disk"; return
    fi

    case "$label" in
      v1)
        # The count, the path and the sentence, separately. The count is what tells
        # an operator how much is out there; the path is the only thing that lets
        # them go look; and the closing sentence is the one that stops the block
        # reading as a report of work already done.
        if ! grep -qF 'holds 1 recorded exposure(s) in a format this version cannot read' "$TMP/forgetexp.out"; then
          fail_case "$name" "an unreadable exposure record was skipped in silence"; return
        fi
        if ! grep -qF "$rec" "$TMP/forgetexp.out"; then
          fail_case "$name" "the unreadable record was counted but never named, so nothing can be gone and looked at"; return
        fi
        if ! grep -qF 'I did not run those' "$TMP/forgetexp.out"; then
          fail_case "$name" "the teardown commands were printed without saying they had not been run"; return
        fi
        # Left alone, not deleted: an unreadable record is the last on-disk trace
        # of a route this command refuses to close, so removing it would destroy
        # the evidence the warning just told the operator to go read.
        if [ ! -f "$rec" ]; then
          fail_case "$name" "the unreadable record was deleted — the only trace of an unclosed route"; return
        fi ;;
      v2)
        # The pairing. A readable record owned by this setup still gets the plain
        # line, and must NOT drag the unreadable-records block in with it — if it
        # did, the v1 assertions above would be satisfied by every run.
        if ! grep -qF 'a PUBLIC address      port 8443 → 127.0.0.1:8080' "$TMP/forgetexp.out"; then
          fail_case "$name" "a readable exposure record owned by this setup was not disclosed"; return
        fi
        if grep -qF 'in a format this version cannot read' "$TMP/forgetexp.out"; then
          fail_case "$name" "a record this version CAN read was reported as unreadable — the v1 lane proves nothing"; return
        fi ;;
    esac
  done
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# The sibling above covers the case where an exposure RECORD is still on disk. This
# one covers the case that is far more common and was, until this case existed,
# entirely unguarded: no record at all.
#
# That is not an exotic state. `on_exit` calls `prune_exposure_records all` on every
# clean run that emitted a setup code — deliberately, because a reported exposure is
# not an unreported one — so the ordinary machine, the one where setup SUCCEEDED, has
# a live Funnel and nothing on disk naming it. A --forget sourced only from records
# removed the profile, the password and the unit, exited 0, and left a PUBLIC address
# in front of a tool-capable agent, never mentioning it. Simulating "already pruned"
# is simply "the file was never written".
#
# The `tailscale` shim is STATEFUL, which is what makes this case about closure
# rather than about wording: `undo_exposure_entry` runs `funnel … off` under
# `2>/dev/null || true`, so an exit code proves nothing in either direction. The shim
# touches a marker file when the real `off` arrives and answers the next
# `serve status --json` with an empty tailnet, so the script's own post-teardown
# re-read is the evidence — and anything unexpected still fails with exit 1.
#
# Four lanes, and the last three are the assertion. `pruned` proves the route is
# found and closed; `foreign`, `contested` and `silent` prove the new source did not
# buy that by guessing — a wrongly closed stranger's port is worse than the bug.
#
# Two later lanes guard the two ways this command can go back to reporting a removal
# as complete when it is not. `unreadable` is the silence again, in the one case the
# grader cannot look anything up: a saved address it cannot parse. `closefail` is the
# exit status: a close that is attempted and fails must not come back 0.
run_manage_forget_pruned_exposure_case() {
  local name="manage-forget-closes-a-pruned-exposure" lane rc
  local home state sd closed bin hostkey reads gwurl attempts refuse want_rc
  : > "$TMP/doctor.out"

  for lane in pruned foreign contested silent recorded raced unreadable closefail; do
    home="$TMP/forgetpruned-$lane-home"; state="$TMP/forgetpruned-$lane-state"
    sd="$state/conduck"; bin="$TMP/forgetpruned-$lane-bin"
    closed="$TMP/forgetpruned-$lane-closed"; reads="$TMP/forgetpruned-$lane-reads"
    attempts="$TMP/forgetpruned-$lane-attempts"; refuse="$TMP/forgetpruned-$lane-refuse"
    rm -rf "$home" "$state" "$bin"; rm -f "$closed" "$reads" "$attempts" "$refuse"
    mkdir -p "$home/Library/LaunchAgents" "$home/.config/systemd/user" "$sd" "$bin"
    # A `tailscale` that answers `funnel … off` with exit 1 and goes on serving the
    # mapping. It is the only lane where the close is ATTEMPTED and fails, which is
    # the only way to reach the leftover branch whose exit status is in question.
    [ "$lane" = "closefail" ] && : > "$refuse"

    # The `foreign` lane serves the same PORT under a different tailnet name — the
    # one shape of near-miss a port-only close cannot tell from a hit.
    hostkey="box.tail1234.ts.net:8443"
    [ "$lane" = "foreign" ] && hostkey="other.tail1234.ts.net:8443"

    if [ "$lane" = "raced" ]; then
      # The typed confirmation can sit on screen for minutes. This shim answers the
      # DISCLOSURE's read with this setup's own address and every later read with a
      # different tailnet name, so the route stops being provable during the pause —
      # which is the only way to show that the far side of the prompt re-reads and
      # re-grades rather than acting on the list the operator just approved.
      cat > "$bin/tailscale" <<SHIM
#!/usr/bin/env bash
if [ "\$1" = "serve" ] && [ "\$2" = "status" ] && [ "\$3" = "--json" ]; then
  printf 'r\n' >> "$reads"
  host=box.tail1234.ts.net
  [ "\$(wc -l < "$reads" | tr -d ' ')" -ge 2 ] && host=other.tail1234.ts.net
  printf '{"Web":{"%s:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8080"}}}},"AllowFunnel":{"%s:8443":true}}\n' "\$host" "\$host"
  exit 0
fi
if [ "\$1" = "funnel" ] && [ "\$2" = "--https=8443" ] && [ "\$3" = "off" ]; then
  : > "$closed"
  exit 0
fi
exit 1
SHIM
    else
      cat > "$bin/tailscale" <<SHIM
#!/usr/bin/env bash
if [ "\$1" = "serve" ] && [ "\$2" = "status" ] && [ "\$3" = "--json" ]; then
  if [ -f "$closed" ]; then
    printf '%s\n' '{"Web":{},"AllowFunnel":{}}'
  else
    printf '%s\n' '{"Web":{"$hostkey":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8080"}}}},"AllowFunnel":{"$hostkey":true}}'
  fi
  exit 0
fi
if [ "\$1" = "funnel" ] && [ "\$2" = "--https=8443" ] && [ "\$3" = "off" ]; then
  printf 'off\n' >> "$attempts"
  # The attempt is logged before the refusal, because "it tried and failed" and "it
  # never tried" are the two readings of an unclosed route and only the log tells
  # them apart.
  [ -f "$refuse" ] && exit 1
  : > "$closed"
  exit 0
fi
exit 1
SHIM
    fi
    chmod +x "$bin/tailscale"

    # NO exposure-*.pending file in any lane but `recorded`. That single omission IS
    # the fixture: it is what a clean successful run leaves behind.
    if [ "$lane" = "recorded" ]; then
      # The mirror image, and the only lane where the OLD source is the one that
      # finds the route: a Cloudflare pairing whose profile names no Tailscale
      # address, plus a record an interrupted earlier Tailscale run left behind.
      # It exists to pin the boundary — a record-derived line must NOT be labelled
      # as having been matched from a saved address, because that label is what
      # tells an operator to look for a route of their own.
      printf '%s\n' '{"schemaVersion":1,"gateway":{"id":"custom-a","kind":"custom","name":"Tunnelled gateway","auth":"bearer","transport":"cloudflare","reach":"public","url":"https://gw.example.com"},"fileServer":null}' \
        > "$sd/profile-custom-a.json"
      printf '2\tgateway\t8443\tfunnel\thttp://127.0.0.1:8080\tcustom-a\tEMPTY\n' \
        > "$sd/exposure-oldrun-001.pending"
    elif [ "$lane" = "silent" ]; then
      # A reverse proxy of the operator's own: this script never opened a route for
      # it and has nothing to close, so it must not send them to read a program that
      # has nothing to do with their setup.
      printf '%s\n' '{"schemaVersion":1,"gateway":{"id":"custom-a","kind":"custom","name":"Reverse proxy","auth":"bearer","transport":"public","reach":"public","url":"https://gw.example.com"},"fileServer":null}' \
        > "$sd/profile-custom-a.json"
    else
      # The `unreadable` lane's saved address carries an underscore in the tailnet
      # name. No hand-edit is needed to get one: `ask_url` takes anything shaped like
      # https://?*, and --edit's transport check only asks whether the host ends in
      # .ts.net, so a typo sails through and is saved. Every parser downstream refuses
      # it, and refusing it silently is the original defect's exact shape.
      gwurl="https://box.tail1234.ts.net:8443"
      [ "$lane" = "unreadable" ] && gwurl="https://box_1.tail1234.ts.net:8443"
      printf '{"schemaVersion":1,"gateway":{"id":"custom-a","kind":"custom","name":"Tailnet gateway","auth":"bearer","transport":"funnel","reach":"public","url":"%s","localPort":"8080"},"fileServer":null}\n' \
        "$gwurl" > "$sd/profile-custom-a.json"
    fi
    # A second saved setup naming the SAME address. Whichever is removed first would
    # close a route the other still needs, so neither may be closed on a guess.
    [ "$lane" = "contested" ] && printf '%s\n' '{"schemaVersion":1,"gateway":{"id":"custom-b","kind":"custom","name":"Twin","auth":"bearer","transport":"funnel","reach":"public","url":"https://box.tail1234.ts.net:8443","localPort":"8080"},"fileServer":null}' \
      > "$sd/profile-custom-b.json"

    PTY_ENV=(HOME="$home" XDG_CONFIG_HOME="$state" PATH="$bin:$PATH")
    rc=0
    pty_run 30 $'custom-a\n' --forget custom-a > "$TMP/forgetpruned.out" 2>&1 || rc=$?
    printf -- '--- lane %s rc=%s ---\n' "$lane" "$rc" >> "$TMP/doctor.out"
    cat "$TMP/forgetpruned.out" >> "$TMP/doctor.out"
    assert_runtime_defined "$name" "$(cat "$TMP/forgetpruned.out")" || return
    if [ "$rc" = "124" ]; then
      fail_case "$name" "lane $lane hung instead of completing the removal"; return
    fi
    # Every lane confirms the removal, so every lane but one exits 0. `closefail` is
    # the exception and is the whole point of that lane: an address this command tried
    # to close and could not prove closed is "some of it is still there", which README
    # pins to 1 — and a caller keying on the status cannot read the screen that says so.
    want_rc=0
    [ "$lane" = "closefail" ] && want_rc=1
    if [ "$rc" != "$want_rc" ]; then
      fail_case "$name" "lane $lane exited $rc, expected $want_rc"; return
    fi
    # Asserted in every lane, first: a "safe" fix that refuses to remove anything
    # whenever it cannot prove a route would satisfy every refusal assertion below
    # and break the command.
    if ! grep -qF 'Removed the saved setup' "$TMP/forgetpruned.out"; then
      fail_case "$name" "lane $lane never reported the removal"; return
    fi
    if [ -f "$sd/profile-custom-a.json" ]; then
      fail_case "$name" "lane $lane left the saved setup on disk"; return
    fi
    # "No record at all" and "a record this version cannot parse" are different
    # facts with different advice; the second must never be printed for the first.
    if grep -qF 'in a format this version cannot read' "$TMP/forgetpruned.out"; then
      fail_case "$name" "lane $lane reported an unreadable record where no record exists at all"; return
    fi

    case "$lane" in
      pruned)
        # The disclosure line is rendered by the same loop a record-derived route
        # goes through, so the literal column alignment is the proof that the two
        # sources really do share it.
        if ! grep -qF 'a PUBLIC address      port 8443 → 127.0.0.1:8080' "$TMP/forgetpruned.out"; then
          fail_case "$name" "a live route named only by the saved profile was never disclosed"; return
        fi
        # The marker and its note are the only defence against closing a route the
        # operator opened by hand to this same address — a case no signal available
        # here can decide.
        if ! grep -qF "matched from this setup's saved address" "$TMP/forgetpruned.out"; then
          fail_case "$name" "a profile-derived route was listed with no sign of where the match came from"; return
        fi
        if ! grep -qF 'A route you opened by hand to that same address is indistinguishable' "$TMP/forgetpruned.out"; then
          fail_case "$name" "the marker was printed without the note that says what it means"; return
        fi
        if [ ! -f "$closed" ]; then
          fail_case "$name" "the PUBLIC Funnel was disclosed and then never closed — 'tailscale funnel --https=8443 off' never ran"; return
        fi
        if ! grep -qF 'Port 8443 is no longer exposed.' "$TMP/forgetpruned.out"; then
          fail_case "$name" "the close was never proven from a fresh read of Tailscale's own state"; return
        fi
        if ! grep -qF 'tailscale funnel --bg --https=8443 http://127.0.0.1:8080' "$TMP/forgetpruned.out"; then
          fail_case "$name" "a closed PUBLIC route left no way to put it back"; return
        fi ;;
      foreign)
        if [ -f "$closed" ]; then
          fail_case "$name" "a route on a tailnet name this setup does not use was CLOSED — that is somebody else's port"; return
        fi
        if grep -qF 'Port 8443 is no longer exposed.' "$TMP/forgetpruned.out"; then
          fail_case "$name" "a route that was left open was reported closed"; return
        fi
        if ! grep -qF 'this machine serves port 8443 under the name other.tail1234.ts.net' "$TMP/forgetpruned.out"; then
          fail_case "$name" "the route was refused without saying why, so nothing can be checked by hand"; return
        fi
        if ! grep -qF 'tailscale funnel --https=<port> off' "$TMP/forgetpruned.out"; then
          fail_case "$name" "a route left open was named without the command that closes it"; return
        fi
        if ! grep -qF 'I did not run those' "$TMP/forgetpruned.out"; then
          fail_case "$name" "the by-hand commands were printed without saying they had not been run"; return
        fi ;;
      contested)
        if [ -f "$closed" ]; then
          fail_case "$name" "a route two saved setups both name was closed on behalf of one of them"; return
        fi
        if ! grep -qF 'another saved setup on this machine names that same address' "$TMP/forgetpruned.out"; then
          fail_case "$name" "the contested route was refused without naming the conflict"; return
        fi ;;
      silent)
        # The widened gate must stay shut for a setup this script never opened a
        # route for. Case-insensitive, because the word is capitalised in prose.
        if grep -qi 'tailscale' "$TMP/forgetpruned.out"; then
          fail_case "$name" "a Cloudflare/reverse-proxy setup was sent to check Tailscale, which has nothing to do with it"; return
        fi ;;
      recorded)
        if ! grep -qF 'a PUBLIC address      port 8443 → 127.0.0.1:8080' "$TMP/forgetpruned.out"; then
          fail_case "$name" "the record-derived route stopped being disclosed"; return
        fi
        if [ ! -f "$closed" ]; then
          fail_case "$name" "the record-derived route stopped being closed"; return
        fi
        if grep -qF "matched from this setup's saved address" "$TMP/forgetpruned.out"; then
          fail_case "$name" "a route found in a RECORD was labelled as matched from the saved address"; return
        fi
        if grep -qF 'A route you opened by hand to that same address is indistinguishable' "$TMP/forgetpruned.out"; then
          fail_case "$name" "the profile-source caveat was printed for a route no profile named"; return
        fi
        if grep -qF 'tailscale funnel --bg --https=8443' "$TMP/forgetpruned.out"; then
          fail_case "$name" "the profile-source restore hint was printed for a record-derived route"; return
        fi ;;
      raced)
        # It has to have FOUND the route first, or "did not close it" would be true
        # for the wrong reason and this lane would prove nothing.
        if ! grep -qF 'a PUBLIC address      port 8443 → 127.0.0.1:8080' "$TMP/forgetpruned.out"; then
          fail_case "$name" "the route was never disclosed, so the re-read had nothing to change its mind about"; return
        fi
        if [ -f "$closed" ]; then
          fail_case "$name" "a route that stopped matching during the confirmation was closed anyway — the disclosure was trusted"; return
        fi
        if ! grep -qF 'Port 8443 no longer matches this setup' "$TMP/forgetpruned.out"; then
          fail_case "$name" "a disclosed route was dropped in silence instead of saying it had stopped matching"; return
        fi
        if grep -qF 'Port 8443 is no longer exposed.' "$TMP/forgetpruned.out"; then
          fail_case "$name" "a route that was left open was reported closed"; return
        fi ;;
      unreadable)
        # The silence, back in the one case the grader cannot look anything up: with
        # no port to match on, it cannot even ask whether something is live, so
        # "nothing is open" is not a thing this branch may imply. It must say it could
        # not read the address, name it, and hand over the by-hand commands.
        if [ -f "$closed" ]; then
          fail_case "$name" "a route named only by an address this version cannot read was CLOSED"; return
        fi
        if ! grep -qF 'this version cannot read that saved address at all' "$TMP/forgetpruned.out"; then
          fail_case "$name" "an unreadable saved address was dropped in SILENCE — the live PUBLIC route was never mentioned"; return
        fi
        if ! grep -qF 'https://box_1.tail1234.ts.net:8443' "$TMP/forgetpruned.out"; then
          fail_case "$name" "the address it could not read was never named, so there is nothing to go and check"; return
        fi
        if ! grep -qF 'tailscale funnel --https=<port> off' "$TMP/forgetpruned.out"; then
          fail_case "$name" "an unreadable saved address was reported with no command to close a route by hand"; return
        fi ;;
      closefail)
        # The exit status is asserted above, with every other lane's. These three
        # keep that assertion from passing for the wrong reason: the close has to
        # have been ATTEMPTED, the failure has to be on screen, and a route still
        # live must not be reported closed.
        if [ ! -f "$attempts" ]; then
          fail_case "$name" "the close was never attempted, so an exit status proves nothing about one that failed"; return
        fi
        if ! grep -qF 'Could not confirm every address in front of this gateway was closed' "$TMP/forgetpruned.out"; then
          fail_case "$name" "a close that failed was never reported on screen"; return
        fi
        if grep -qF 'Port 8443 is no longer exposed.' "$TMP/forgetpruned.out"; then
          fail_case "$name" "a route that is still live was reported closed"; return
        fi ;;
    esac
  done
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# The removal confirmation is the one prompt in this program that is NOT a y/n and
# NOT a numbered choice: the answer is the id, typed out. It sits beside prompts
# that all advertise the same three controls, and it drifted — it rendered its own
# literal "(Enter cancels)", offered no `i`, and swallowed `q` as a cancel. Every
# one of those is a prompt an operator reads by habit rather than by word, so a
# prompt here that honours fewer keys than the ones around it is not a cosmetic
# difference: `q` at the most destructive step in the tool meant something other
# than everywhere else, silently.
#
# So the suffix itself is asserted as the string control_suffix produces, and each
# advertised key is DRIVEN rather than assumed. The absence half is asserted too:
# an advertised suffix that no longer matches the code that reads the answer is
# exactly the shape the drift had, and only the pairing catches it.
#
# The last two lanes are the ambiguity this prompt cannot avoid. An id is lowercase
# letters, digits and hyphens, so `q` is a LEGAL id, and at this one prompt the two
# readings of that keystroke are "stop the run" and "delete irreversibly". Neither
# may be chosen silently, and both readings must remain reachable — a fix that made
# `q` always stop would leave a setup named `q` unremovable, and a fix that made it
# always literal would put the destructive reading behind the key everyone presses
# to leave.
run_manage_forget_prompt_controls_case() {
  local name="manage-forget-confirmation-honours-its-keys" lane
  : > "$TMP/doctor.out"

  # lane <label> <id> <input> <want-rc> <want-profile kept|gone>
  # Each lane gets its own HOME and state dir: four of the six leave the profile in
  # place and two remove it, so a shared fixture would make the ORDER of the lanes
  # part of what they assert.
  local label id input keys want_rc want_profile sd home state rc
  for lane in \
    "enter|custom-good|\n|3|kept" \
    "explain|custom-good|i\n\n|3|kept" \
    "stop|custom-good|q\n|3|kept" \
    "typed|custom-good|custom-good\n|0|gone" \
    "qid-literal|q|q\ny\n|0|gone" \
    "qid-control|q|q\n\n|3|kept" \
  ; do
    label="${lane%%|*}"; lane="${lane#*|}"
    id="${lane%%|*}"; lane="${lane#*|}"
    input="${lane%%|*}"; lane="${lane#*|}"
    want_rc="${lane%%|*}"; want_profile="${lane#*|}"

    home="$TMP/forgetkeys-$label-home"; state="$TMP/forgetkeys-$label-state"
    sd="$state/conduck"
    mkdir -p "$home" "$sd"
    write_valid_profile "$sd/profile-$id.json" "$id" "Good gateway" "https://good.example.test"
    PTY_ENV=(HOME="$home" XDG_CONFIG_HOME="$state")
    rc=0
    # The table carries \n as two literal characters, so printf renders them —
    # and the trailing `_`, stripped straight back off, is what survives command
    # substitution eating trailing newlines. Every one of these inputs ENDS in a
    # newline (that is the keystroke under test), so without the guard the lanes
    # hand pty-run.py an unterminated answer and time out at 124.
    keys=$(printf '%b_' "$input"); keys="${keys%_}"
    pty_run 20 "$keys" --forget "$id" > "$TMP/forgetkeys.out" 2>&1 || rc=$?
    printf -- '--- lane %s (--forget %s) rc=%s ---\n' "$label" "$id" "$rc" >> "$TMP/doctor.out"
    cat "$TMP/forgetkeys.out" >> "$TMP/doctor.out"
    assert_runtime_defined "$name" "$(cat "$TMP/forgetkeys.out")" || return
    if [ "$rc" = "124" ]; then
      fail_case "$name" "lane $label hung at the removal confirmation"; return
    fi
    if [ "$rc" != "$want_rc" ]; then
      fail_case "$name" "lane $label exited $rc, expected $want_rc"; return
    fi
    if [ "$want_profile" = "kept" ] && [ ! -f "$sd/profile-$id.json" ]; then
      fail_case "$name" "lane $label removed the setup on an answer that must not remove one"; return
    fi
    if [ "$want_profile" = "gone" ] && [ -f "$sd/profile-$id.json" ]; then
      fail_case "$name" "lane $label left the setup on disk after an answer that removes it"; return
    fi

    # The suffix, on every lane that reaches the prompt at all — which is all six.
    if ! grep -qF "to remove it (Enter = cancel; i = explain; q = stop)" "$TMP/forgetkeys.out"; then
      fail_case "$name" "lane $label did not advertise the controls control_suffix produces"; return
    fi
    if grep -qF 'to remove it (Enter cancels)' "$TMP/forgetkeys.out"; then
      fail_case "$name" "lane $label re-grew the hand-written suffix that named only Enter"; return
    fi

    case "$label" in
      enter)
        if ! grep -qF 'Cancelled — nothing was removed.' "$TMP/forgetkeys.out"; then
          fail_case "$name" "Enter at the confirmation did not say the removal was cancelled"; return
        fi ;;
      explain)
        # Advertised and honoured: the explanation appears AND the prompt comes
        # back. An `i` that explained and then fell through to "that is not the id"
        # would satisfy the first half alone.
        if ! grep -qF 'What typing the id does' "$TMP/forgetkeys.out"; then
          fail_case "$name" "i at the confirmation printed no explanation"; return
        fi
        if [ "$(grep -cF 'to remove it (Enter = cancel; i = explain; q = stop)' "$TMP/forgetkeys.out")" != "2" ]; then
          fail_case "$name" "i at the confirmation did not re-ask the question"; return
        fi ;;
      stop)
        # quit_run, not the cancel note: they are different facts. Cancelling is an
        # answer to THIS question; stopping is leaving the program.
        if ! grep -qF 'Stopped here.' "$TMP/forgetkeys.out"; then
          fail_case "$name" "q at the confirmation did not stop the run"; return
        fi
        if grep -qF 'Cancelled — nothing was removed.' "$TMP/forgetkeys.out"; then
          fail_case "$name" "q at the confirmation was quietly read as a cancel"; return
        fi ;;
      typed)
        if ! grep -qF 'Removed the saved setup' "$TMP/forgetkeys.out"; then
          fail_case "$name" "typing the id back did not report the removal"; return
        fi ;;
      qid-literal)
        if ! grep -qF 'Use "q" as your answer instead of stopping the run?' "$TMP/forgetkeys.out"; then
          fail_case "$name" "an id of \"q\" was resolved without asking which reading was meant"; return
        fi
        if ! grep -qF 'Removed the saved setup' "$TMP/forgetkeys.out"; then
          fail_case "$name" "a setup whose id is \"q\" could not be removed"; return
        fi ;;
      qid-control)
        if ! grep -qF 'Use "q" as your answer instead of stopping the run?' "$TMP/forgetkeys.out"; then
          fail_case "$name" "an id of \"q\" was resolved without asking which reading was meant"; return
        fi
        if ! grep -qF 'Stopped here.' "$TMP/forgetkeys.out"; then
          fail_case "$name" "declining the literal reading of \"q\" did not stop the run"; return
        fi ;;
    esac
  done
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# The manage surface's one absolute rule: it prints no secret. It is the only
# surface in this tool that READS a machine's whole file-lane state — the WebDAV
# credential file, its environment file, and the service file that carries the
# same password a second time — and it is the surface most likely to grow a
# "print everything you found" line, because that is what an inventory is for.
#
# Two distinct leaks, and they fail in different places:
#
#   A file that holds a password is opened and echoed. Guarded by seeding a
#   sentinel into all three of them and asserting the string reaches no
#   transcript. The seeding is asserted too: an absence assertion for a string
#   that is not in the fixture is green forever.
#
#   A password that arrived in a URL is printed as part of the address.
#   `ask_url` refuses `user:pass@` and the profile validator refuses it again on
#   read, so the wizard never writes one — but these surfaces deliberately read
#   profiles the validator REJECTS (showing and removing an unusable setup is
#   their job), and a hand-edited profile is exactly where such a URL survives.
#   Both halves are asserted: the credential is gone AND the host survives, since
#   dropping the whole address would also pass a "no sentinel" check.
#
# Four surfaces, because they are four different code paths to the same data:
# --list (human), --list --json (python), --edit (the picker + the same renderer)
# and --forget's disclosure screen, which is the ONLY human surface that renders a
# profile the validator rejected — and therefore the only one where the redaction
# in manage_safe_url can be observed at all.
#
# Transcripts are appended with the sentinel masked. A leak is named by the
# assertion that caught it; reprinting it into the suite's own output would put
# the thing under test in the log of every failing run.
run_manage_no_secret_case() {
  local name="manage-surface-prints-no-secret" rc=0 sentinel url
  local home="$TMP/nosecret-home" state="$TMP/nosecret-state" sd="$TMP/nosecret-state/conduck"
  local unit legacy
  sentinel='SENTINELPW-must-never-be-printed-7f3a'
  mkdir -p "$home/Library/LaunchAgents" "$home/.config/systemd/user" "$sd" "$TMP/nosecret-work"
  : > "$TMP/doctor.out"

  # A readable setup with a live file lane — the one --list, --edit and the JSON
  # all render in full.
  printf '{"schemaVersion":1,"gateway":{"id":"custom-good","kind":"custom","name":"Files gateway","auth":"bearer","transport":"public","reach":"public","url":"https://gw.example.test"},"fileServer":{"url":"https://files.example.test:8443","folder":"%s","reach":"public"}}\n' \
    "$TMP/nosecret-work" > "$sd/profile-custom-good.json"
  # …and an unusable one whose address carries the credential. Its gateway URL is
  # why this version refuses to load it, which is what puts it on the --forget
  # path and off the --edit one.
  printf '{"schemaVersion":1,"gateway":{"id":"custom-userinfo","kind":"custom","name":"Hand edited","auth":"bearer","transport":"public","reach":"public","url":"https://conduck:%s@gw2.example.test"},"fileServer":null}\n' \
    "$sentinel" > "$sd/profile-custom-userinfo.json"
  # …and the same shape with a password that CONTAINS an @, which is the fixture the
  # single-@ one above cannot stand in for. A redaction that splits the authority on
  # the FIRST @ keeps everything after it — so with one @ the whole credential goes
  # and the case is green, while with two the tail of the password is reprinted, in
  # an address still shaped like user:pass@host. That leak shipped past the single-@
  # fixture. An @ is legal in a password and illegal in a host, so the LAST one is
  # always the separator, and only a multi-@ fixture can tell the two splits apart.
  printf '{"schemaVersion":1,"gateway":{"id":"custom-atpass","kind":"custom","name":"At in password","auth":"bearer","transport":"public","reach":"public","url":"https://conduck:pa@%s@gw3.example.test"},"fileServer":null}\n' \
    "$sentinel" > "$sd/profile-custom-atpass.json"
  # The two files that really do hold the WebDAV password, under the names the
  # tool itself uses for them.
  printf 'conduck:%s\n' "$sentinel" > "$sd/fileserver-custom-good.cred"
  printf 'RCLONE_PASS=%s\n' "$sentinel" > "$sd/fileserver-custom-good.env"
  # The service file is the password's second home, and the leftovers scan parses
  # unit files it cannot attribute to any setup — so one of each: the id-bearing
  # unit for custom-good, and an unnamed legacy one, which is the entry --list
  # prints teardown commands for.
  if [ "$(uname -s)" = "Linux" ]; then
    unit="$home/.config/systemd/user/conduck-files-custom-good.service"
    legacy="$home/.config/systemd/user/conduck-fileserver.service"
    printf '[Service]\nExecStart=/usr/local/bin/rclone serve webdav %s --addr 127.0.0.1:8080 --user conduck --pass %s\n' \
      "$TMP/nosecret-work" "$sentinel" > "$unit"
    printf '[Service]\nExecStart=/usr/local/bin/rclone serve webdav %s --addr 127.0.0.1:8081 --user conduck --pass %s\n' \
      "$TMP/nosecret-work" "$sentinel" > "$legacy"
  else
    unit="$home/Library/LaunchAgents/ai.gigaduck.conduck-files-custom-good.plist"
    legacy="$home/Library/LaunchAgents/ai.gigaduck.conduck-fileserver.plist"
    printf '<?xml version="1.0"?><plist version="1.0"><dict><key>Label</key><string>x</string><key>ProgramArguments</key><array><string>/usr/local/bin/rclone</string><string>serve</string><string>webdav</string><string>%s</string><string>--addr</string><string>127.0.0.1:8080</string><string>--user</string><string>conduck</string><string>--pass</string><string>%s</string></array></dict></plist>\n' \
      "$TMP/nosecret-work" "$sentinel" > "$unit"
    printf '<?xml version="1.0"?><plist version="1.0"><dict><key>Label</key><string>y</string><key>ProgramArguments</key><array><string>/usr/local/bin/rclone</string><string>serve</string><string>webdav</string><string>%s</string><string>--addr</string><string>127.0.0.1:8081</string><string>--user</string><string>conduck</string><string>--pass</string><string>%s</string></array></dict></plist>\n' \
      "$TMP/nosecret-work" "$sentinel" > "$legacy"
  fi
  # The fixture is only a test if the string is really in it. Without this, every
  # absence below is satisfied by a typo in the seeding.
  if ! grep -qF "$sentinel" "$sd/fileserver-custom-good.cred" ||
     ! grep -qF "$sentinel" "$sd/fileserver-custom-good.env" ||
     ! grep -qF "$sentinel" "$unit" || ! grep -qF "$sentinel" "$legacy" ||
     ! grep -qF "$sentinel" "$sd/profile-custom-userinfo.json" ||
     ! grep -qF "$sentinel" "$sd/profile-custom-atpass.json"; then
    fail_case "$name" "the sentinel never reached the fixture — the absence assertions would be vacuous"; return
  fi
  # And the multi-@ fixture really is multi-@. Without this, a stray edit that
  # dropped the `pa@` prefix would quietly turn it back into the single-@ profile
  # beside it, which is the exact fixture the leak already survived.
  if ! grep -qF "conduck:pa@$sentinel@gw3.example.test" "$sd/profile-custom-atpass.json"; then
    fail_case "$name" "the multi-@ fixture lost its second @ — it can no longer tell the two splits apart"; return
  fi

  # -- surface 1: --list, the human inventory, with stdin closed ---------------
  rc=0
  env -u CI HOME="$home" XDG_CONFIG_HOME="$state" TERM=dumb bash "$SCRIPT" --list \
    > "$TMP/nosecret-list.out" 2>&1 </dev/null || rc=$?
  printf -- '--- --list ---\n' >> "$TMP/doctor.out"
  sed "s/$sentinel/[sentinel]/g" "$TMP/nosecret-list.out" >> "$TMP/doctor.out"
  assert_runtime_defined "$name" "$(cat "$TMP/nosecret-list.out")" || return
  if [ "$rc" != "0" ]; then
    fail_case "$name" "--list with a seeded file lane exited $rc, expected 0"; return
  fi
  # Reached: the setup whose credential files sit beside it was rendered in full,
  # and the leftovers scan — which parses a unit file it cannot attribute and
  # prints commands built from it — ran too.
  if ! grep -qF 'Files gateway' "$TMP/nosecret-list.out"; then
    fail_case "$name" "--list never rendered the setup the secret files belong to"; return
  fi
  if ! grep -qF 'File servers with no saved setup behind them' "$TMP/nosecret-list.out"; then
    fail_case "$name" "--list never reached the leftovers scan, which is the surface that parses unit files"; return
  fi
  if grep -qF "$sentinel" "$TMP/nosecret-list.out"; then
    fail_case "$name" "--list printed the file-lane password"; return
  fi

  # -- surface 2: --list --json, the agent-facing one -------------------------
  rc=0
  env -u CI HOME="$home" XDG_CONFIG_HOME="$state" TERM=dumb bash "$SCRIPT" --list --json \
    > "$TMP/nosecret-list.json" 2>&1 </dev/null || rc=$?
  printf -- '--- --list --json ---\n' >> "$TMP/doctor.out"
  sed "s/$sentinel/[sentinel]/g" "$TMP/nosecret-list.json" >> "$TMP/doctor.out"
  if [ "$rc" != "0" ]; then
    fail_case "$name" "--list --json with a seeded file lane exited $rc, expected 0"; return
  fi
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TMP/nosecret-list.json" 2>>"$TMP/doctor.out"; then
    fail_case "$name" "--list --json did not parse with a hand-edited profile in the directory"; return
  fi
  if grep -qF "$sentinel" "$TMP/nosecret-list.json"; then
    fail_case "$name" "--list --json emitted the credential into machine-readable output"; return
  fi
  # The redaction, both halves, read out of the parsed document rather than off
  # the text: the credential is gone AND the address is still an address.
  url=$(python3 - "$TMP/nosecret-list.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for s in d["setups"]:
    if s["id"] == "custom-userinfo":
        print(s["url"] or "")
PY
) || { fail_case "$name" "could not read the hand-edited setup's url back out of the JSON"; return; }
  printf -- '--- custom-userinfo url ---\n%s\n' "$url" >> "$TMP/doctor.out"
  if [ "$url" != "https://gw2.example.test" ]; then
    fail_case "$name" "the JSON url for a user:pass@ address was '$url', expected the host alone"; return
  fi
  # The same read for the multi-@ address, and an EQUALITY rather than an absence:
  # a redaction that gave up and emitted nothing at all would satisfy "no sentinel"
  # while telling a machine consumer nothing about which gateway this record names.
  url=$(python3 - "$TMP/nosecret-list.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for s in d["setups"]:
    if s["id"] == "custom-atpass":
        print(s["url"] or "")
PY
) || { fail_case "$name" "could not read the multi-@ setup's url back out of the JSON"; return; }
  printf -- '--- custom-atpass url ---\n%s\n' "$url" >> "$TMP/doctor.out"
  if [ "$url" != "https://gw3.example.test" ]; then
    fail_case "$name" "the JSON url for a password containing @ was '$url', expected the host alone"; return
  fi

  # -- surface 3: --edit, which needs a terminal ------------------------------
  # 1 picks the only readable setup, q stops at the first question it asks. The
  # picker and the renderer both run, which is everything --edit reads.
  PTY_ENV=(HOME="$home" XDG_CONFIG_HOME="$state")
  rc=0
  pty_run 20 $'1\nq\n' --edit > "$TMP/nosecret-edit.out" 2>&1 || rc=$?
  printf -- '--- --edit (pty) ---\n' >> "$TMP/doctor.out"
  sed "s/$sentinel/[sentinel]/g" "$TMP/nosecret-edit.out" >> "$TMP/doctor.out"
  assert_runtime_defined "$name" "$(cat "$TMP/nosecret-edit.out")" || return
  if [ "$rc" = "124" ]; then
    fail_case "$name" "--edit hung instead of reaching its menu"; return
  fi
  if ! grep -qF 'Change one thing' "$TMP/nosecret-edit.out"; then
    fail_case "$name" "--edit never reached the setup it was pointed at"; return
  fi
  if grep -qF "$sentinel" "$TMP/nosecret-edit.out"; then
    fail_case "$name" "--edit printed the file-lane password"; return
  fi

  # -- surface 4: --forget's disclosure, the only human render of a rejected
  #    profile — and therefore the only place manage_safe_url is observable.
  #    Enter at the type-back prompt cancels, so nothing is removed.
  rc=0
  pty_run 20 $'\n' --forget custom-userinfo > "$TMP/nosecret-forget.out" 2>&1 || rc=$?
  printf -- '--- --forget custom-userinfo (pty, cancelled) ---\n' >> "$TMP/doctor.out"
  sed "s/$sentinel/[sentinel]/g" "$TMP/nosecret-forget.out" >> "$TMP/doctor.out"
  assert_runtime_defined "$name" "$(cat "$TMP/nosecret-forget.out")" || return
  if ! grep -qF 'Remove the saved setup "custom-userinfo"' "$TMP/nosecret-forget.out"; then
    fail_case "$name" "--forget never rendered the hand-edited setup it was pointed at"; return
  fi
  if grep -qF "$sentinel" "$TMP/nosecret-forget.out"; then
    fail_case "$name" "--forget printed the credential out of the saved address"; return
  fi
  if ! grep -qF 'https://gw2.example.test' "$TMP/nosecret-forget.out"; then
    fail_case "$name" "the redacted address lost its host as well as its credential"; return
  fi
  # Said out loud, not merely dropped: an address that silently lost a piece is an
  # address the operator cannot match against the one they typed.
  if ! grep -qF 'a username and password were in this saved address; not shown' "$TMP/nosecret-forget.out"; then
    fail_case "$name" "the redaction happened silently — nothing said the address had been edited"; return
  fi
  # …and the same disclosure for the multi-@ address. It is a separate drive, not a
  # second grep of the run above, because manage_safe_url is reached once per
  # rendered record: a redaction that is right for one authority and wrong for the
  # other is exactly the defect, and only the record that carries the second @ can
  # show it.
  rc=0
  pty_run 20 $'\n' --forget custom-atpass > "$TMP/nosecret-forget-at.out" 2>&1 || rc=$?
  printf -- '--- --forget custom-atpass (pty, cancelled) ---\n' >> "$TMP/doctor.out"
  sed "s/$sentinel/[sentinel]/g" "$TMP/nosecret-forget-at.out" >> "$TMP/doctor.out"
  assert_runtime_defined "$name" "$(cat "$TMP/nosecret-forget-at.out")" || return
  if ! grep -qF 'Remove the saved setup "custom-atpass"' "$TMP/nosecret-forget-at.out"; then
    fail_case "$name" "--forget never rendered the setup whose password contains an @"; return
  fi
  if grep -qF "$sentinel" "$TMP/nosecret-forget-at.out"; then
    fail_case "$name" "--forget printed part of a password that contains an @"; return
  fi
  # No userinfo AT ALL, not merely no sentinel: the leak reprinted the password's
  # tail in an authority still shaped like user:pass@host, so an address that still
  # carries an @ before its host is a leak whatever is on the left of it.
  if grep -qE 'https://[^ ]*@gw3\.example\.test' "$TMP/nosecret-forget-at.out"; then
    fail_case "$name" "the redacted address still carried userinfo before the host"; return
  fi
  if ! grep -qF 'https://gw3.example.test' "$TMP/nosecret-forget-at.out"; then
    fail_case "$name" "the redacted multi-@ address lost its host as well as its credential"; return
  fi
  if [ ! -f "$sd/profile-custom-userinfo.json" ] || [ ! -f "$sd/profile-custom-atpass.json" ] ||
     [ ! -f "$sd/fileserver-custom-good.cred" ]; then
    fail_case "$name" "a cancelled --forget removed something"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

run_terminology_lint_case() {
  local name="retired-words-stay-retired" hits words
  words='connector|pairing[ -]code|helpers?'
  : > "$TMP/doctor.out"

  # -- layer 1: what --help prints -------------------------------------------
  TERM=dumb bash "$SCRIPT" --help </dev/null > "$TMP/help.out" 2>&1
  hits=$(grep -inE "$words" "$TMP/help.out")
  if [ -n "$hits" ]; then
    printf -- '--- --help ---\n%s\n' "$hits" >> "$TMP/doctor.out"
    fail_case "$name" "--help uses a retired word (see above)"; return
  fi

  # -- layer 2: every screen call in src/ ------------------------------------
  # d_say/d_ok/d_bad and c_say/c_ok/c_bad are the check commands' own emitters;
  # head_ is a screen heading; plan_add writes the dry-run plan, which the
  # operator reads as a list of things about to happen.
  #
  # The QUESTION verbs are here for the same reason manual.append( is: a prompt's
  # text is a user-visible string that does not look like one in a diff. `ask`,
  # `ask_url`, `confirm`, `require_choice` and friends take their whole screen as
  # an argument, and `prompt_into VAR ask "…"` puts the emitter in argument
  # position where a command-position scan would miss it entirely. printf is here
  # because the terminal refusals write their first line with it directly.
  hits=$(grep -nE '^[[:space:]]*(say|note|warn|ok|bad|die|usage_die|head_|hint|plan_add|d_say|d_ok|d_bad|c_say|c_ok|c_bad|prompt_echo|printf|ask|ask_default|ask_url|ask_secret|confirm|require_choice|prompt_into|print_and_wait)[[:space:]]|manual\.append\(' \
           "$SRC_DIR"/*.inc.sh | grep -inE "$words")
  if [ -n "$hits" ]; then
    printf -- '--- src/ screen calls ---\n%s\n' "$hits" >> "$TMP/doctor.out"
    fail_case "$name" "a line the user reads uses a retired word (see above)"; return
  fi

  # Non-vacuous: the scan really does reach the lines it claims to. If the verb
  # list or the file glob ever stops matching, everything above passes for free.
  if [ "$(grep -cE '^[[:space:]]*say[[:space:]]' "$SRC_DIR"/*.inc.sh | awk -F: '{n+=$2} END {print n+0}')" -lt 500 ]; then
    fail_case "$name" "the lint matched almost no screen calls — its pattern or its glob is broken"; return
  fi
  # The question verbs are a separate class with a separate way of going missing —
  # a rename of the prompt primitives would silently empty that half of the scan
  # while the `say` count above stayed healthy.
  if [ "$(grep -cE '^[[:space:]]*(ask|ask_default|ask_url|ask_secret|confirm|require_choice|prompt_into)[[:space:]]' "$SRC_DIR"/*.inc.sh | awk -F: '{n+=$2} END {print n+0}')" -lt 20 ]; then
    fail_case "$name" "the lint matched almost no prompt questions — the prompt primitives were renamed under it"; return
  fi
  if ! grep -qE 'manual\.append\(' "$SRC_DIR"/41-agent-file-readiness.inc.sh; then
    fail_case "$name" "the python heredoc's manual.append() sentences are no longer where the lint looks for them"; return
  fi

  # The word that REPLACED them is present, so this is a rename and not a deletion.
  if ! grep -qF 'setup code' "$TMP/help.out"; then
    fail_case "$name" "--help stopped naming the thing at all"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# The claim this release deliberately retired from the file header:
#
#     - Send ANY data anywhere except to your own gateway. No telemetry, ever.
#
# It is not true, and the header now says the true version instead — a "Where its
# own requests go" section that names the one path with third-party contact (the
# exposure tool the operator picked, running under their own credentials) and
# carves it out in full. `choose_main_action` states the same rule in a comment
# above the six-line intro it prints: "No telemetry" is unqualified and safe; "I
# talk only to your own gateway" is NOT, and must never be said there.
#
# A claim retired for being false is exactly the kind that comes back, because it
# is short, reassuring and reads well. So this is a RATCHET rather than a
# prohibition: it pins the number of occurrences left in `src/`, which is
# currently one (`11-explanations.inc.sh`, the nav.main panel — see the followups
# in the handoff note, it is a real defect and not mine to fix). Add a second and
# the suite goes red. Fix the one that is there and the suite ALSO goes red, with
# a message telling you to tighten the number to zero — which is the only way a
# ratchet like this cannot quietly rot into an exemption.
run_retired_gateway_claim_case() {
  local name="retired-gateway-claim-does-not-come-back" n
  : > "$TMP/doctor.out"

  TERM=dumb bash "$SCRIPT" --help </dev/null > "$TMP/help.out" 2>&1
  if grep -qF 'except to your own gateway' "$TMP/help.out"; then
    grep -nF 'except to your own gateway' "$TMP/help.out" >> "$TMP/doctor.out"
    fail_case "$name" "--help regained the retired absolute claim"; return
  fi
  # The header's replacement is still there, and still names the carve-out.
  if ! grep -qF 'Where its own requests go' "$SCRIPT"; then
    fail_case "$name" "the header lost the section that says where this script's requests actually go"; return
  fi

  # The ratchet is ZERO, everywhere in src/ — not "one tolerated site". The claim was cut
  # from the header for being false, and the welcome panel held the last copy of it three
  # lines below the very paragraph that names Tailscale and Cloudflare as the front door.
  # A count of 1 could only ever be pinned to a location, and a location check cannot see
  # the claim reappearing in a file nobody thought to name. Zero is the only setting that
  # is not a guess about where a well-meaning contributor would put it back.
  n=$(grep -cF 'except to your own gateway' "$SRC_DIR"/*.inc.sh | awk -F: '{n+=$2} END {print n+0}')
  if [ "$n" -gt 0 ]; then
    grep -nF 'except to your own gateway' "$SRC_DIR"/*.inc.sh >> "$TMP/doctor.out"
    fail_case "$name" "the retired claim is back in src/ ($n occurrence(s)) — it is false wherever it appears, because the tunnel path contacts that vendor"; return
  fi
  # Going silent is not the fix either. A reader who loses the reassurance entirely is
  # worse off than one who gets the honest carve-out, so the panel must still make the
  # absolute claim that IS true.
  if ! grep -qF 'no telemetry ever' "$SRC_DIR/11-explanations.inc.sh"; then
    fail_case "$name" "the welcome panel dropped the retired claim without keeping the honest replacement"; return
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
  # Written out, not read from the artifact: the point is that a release BUMPED
  # it, and a test that derives the number from the same file it grades can never
  # notice a release that forgot to.
  if [ "$(TERM=dumb bash "$SCRIPT" --version 2>/dev/null)" != "conduck-connect 0.15.0" ]; then
    fail_case "$name" "--version did not print the expected public version"; return
  fi
  # The manage surface is public CLI, so --help owes it the same contract as the
  # rest: named, and filed under whether a machine can drive it. --list is the one
  # command in this group that answers with no terminal at all.
  if ! grep -qF -- '--list [--json]' "$TMP/doctor.out" ||
     ! grep -qF -- '--forget <id>' "$TMP/doctor.out" ||
     ! grep -qF -- '--edit [id]' "$TMP/doctor.out"; then
    fail_case "$name" "--help omitted part of the manage surface"; return
  fi
  # The two statuses this release made contractual. A documented status nothing
  # emits is worse than an undocumented one — it tells a wrapper author to write a
  # branch that never runs — so both are asserted here and driven elsewhere in
  # this file (see the exit-4 and quit_run cases).
  if ! grep -qF '3  stopped by the operator before completion' "$TMP/doctor.out" ||
     ! grep -qF '4  this action requires an interactive terminal' "$TMP/doctor.out"; then
    fail_case "$name" "--help omitted the exit 3 / exit 4 contract"; return
  fi
  # The split that makes the COMMANDS section worth reading: which of these a
  # machine can drive, said once, at the top of each group.
  if ! grep -qF 'COMMANDS — scriptable' "$TMP/doctor.out" ||
     ! grep -qF 'COMMANDS — need a person at a terminal' "$TMP/doctor.out"; then
    fail_case "$name" "--help stopped separating scriptable commands from interactive ones"; return
  fi
  # CI=1 is the one switch that turns a blocking check into a scriptable one, and
  # it was documented nowhere. An agent that cannot find it hangs forever on a
  # question after its check already printed exit=0.
  if ! grep -qF 'CI=1' "$TMP/doctor.out"; then
    fail_case "$name" "--help does not document CI=1"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

run_check_continue_yes_case() {
  local name="check-pass-continue-setup" rc=0
  start_fixture good || { fail_case "$name" "fixture failed to start"; stop_fixture; return; }
  local input
  # Menu 2 → URL → yes → default name → b at exposure → n → Enter at the hub.
  # The checked URL/token must be reused, so there is no second gateway or auth
  # question.
  #
  # `b` at the exposure menu returns to the OFFER that started this setup — it
  # does not end the process. That matters because the check that got here sent
  # real chat turns: quota spent, a message in somebody's provider history, and a
  # result still sitting in memory. Throwing that away for a keystroke whose whole
  # meaning is "I want to go back one step" was the defect; the `n` below is the
  # second answer that keystroke now needs.
  input=$'2\nhttp://127.0.0.1:'"$PORT"$'\ny\n\nb\nn\n\n'
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
  # `b` came back to the SAME question the check offered, so a No here means what
  # a No there meant. Two different spellings of one decision is precisely what a
  # wrapper cannot be asked to tell apart, so they share an ending and a status.
  if ! grep -qF 'Continue with setup and pairing after all?' "$TMP/doctor.out"; then
    fail_case "$name" "b at the exposure menu did not return to the offer that started this setup"; return
  fi
  # The exposure menu names its own b, and names the thing it protects.
  if ! grep -qF 'b) back out of this setup (the completed check remains unchanged)' "$TMP/doctor.out"; then
    fail_case "$name" "the exposure menu no longer says what backing out costs"; return
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
  # y → default name → b at exposure → n at the offer it returns to. See
  # check-pass-continue-setup for why `b` re-asks instead of ending the process.
  pty_run 30 $'y\n\nb\nn\n' --check-server "http://127.0.0.1:$PORT" \
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

  # prompt_into is the caller side of the prompt contract and scope_choice reaches
  # its question through it, so it is lifted while require_choice itself stays
  # STUBBED — the stub is what lets the arms below distinguish "asked" from "derived
  # without asking", which is the whole case. Without prompt_into the choice is never
  # assigned at all and every arm reads as "decided without asking", including the
  # near-miss host that is supposed to be asked.
  funcs=$(extract_funcs scope_choice is_quick_tunnel_url keyless_public_guard prompt_into)
  for fn in scope_choice is_quick_tunnel_url keyless_public_guard prompt_into; do
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
    assert_runtime_defined "$name" "$out" || return

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

  # confirm renders its own control suffix and re-emits the prompt under a pipe, so
  # the three primitives behind that come with it.
  funcs=$(extract_funcs looks_like_a_secret warn_answer_looked_like_a_secret confirm \
            control_suffix control_keys prompt_echo)
  for fn in looks_like_a_secret warn_answer_looked_like_a_secret confirm \
            control_suffix control_keys prompt_echo; do
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
  if ! printf '%s\n' "$out" | grep -qF 'looked like a key or password' ||
     ! printf '%s\n' "$out" | grep -qF 'If it was real, rotate it.'; then
    fail_case "$name" "a secret-shaped answer was refused without naming it as one"; return
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
  if ! printf '%s\n' "$out" | grep -qF 'looked like a key or password' ||
     ! printf '%s\n' "$out" | grep -qF 'If it was real, rotate it.'; then
    fail_case "$name" "a secret-shaped answer was refused without naming it as one"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF 'It was shown as you typed it' ||
     printf '%s\n' "$out" | grep -qF 'Assume this session may have recorded it.'; then
    fail_case "$name" "the terminal caution did not point at the scroll-back the value is actually in"; return
  fi
  # Ordering: the caution has to sit under the value it is about. Weaker than the
  # count above — pty-run.py writes the whole input up front, so the echo lands
  # early no matter what — but it still catches a caution emitted before the read.
  tok_line=$(printf '%s\n' "$out" | grep -n -F -- "$secret" | head -1 | cut -d: -f1)
  caution_line=$(printf '%s\n' "$out" | grep -n -F 'looked like a key or password' | head -1 | cut -d: -f1)
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
# echoed to the terminal, written to the saved profile that WHAT-IT-TOUCHES.md
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
  funcs=$(extract_funcs url_has_userinfo ask_url explain_prompt \
            control_suffix control_keys prompt_echo looks_like_a_secret \
            warn_answer_looked_like_a_secret
          sed -n '/^URL_USERINFO_HINT=/p' "$SCRIPT")
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
  if ! printf '%s\n' "$out" | grep -qF 'it is asked for separately, at a hidden prompt'; then
    fail_case "$name" "ask_url did not explain where the secret actually belongs"; return
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

# SECURITY.md's load-bearing promise: conduck-connect "never changes a config it
# didn't create without showing you the exact change first". A file's PERMISSIONS
# are part of its configuration, so tightening a pre-existing ~/.hermes/.env to
# 0600 goes through the same announce-then-confirm gate as any other change to
# something the user owns.
#
# The DECLINE and FAILURE arms are graded as hard as the success arm on purpose.
# A gate that goes quiet when the user says no leaves a live gateway key readable
# by every account on the box and says nothing about it — a worse outcome than
# the silent chmod the gate replaced. So all three arms are driven end to end
# through the shipped secure_owned_file_mode, plus a wiring check on the order
# the caller does things in.
run_owned_config_mode_change_case() {
  local name="owned-config-mode-change-is-announced" funcs body out
  local envf="$TMP/announce-hermes.env" mode

  # Wiring, and it is entirely about ORDER. The promise is that the exact change
  # is SHOWN first — not that it waits behind a second question, which is what put
  # a live key into a 0644 file for as long as it took to ask. So configure_hermes
  # prints `chmod 600 <path>` beside the lines it would append, applies it once the
  # one "Append these now?" answer is yes, and only THEN writes the key;
  # secure_owned_file_mode stays behind the append as the backstop for a chmod that
  # could not be applied. Every one of those relationships is an inequality below.
  # Line continuations are joined first — `run_step "…" \` / `  chmod 600 "$envf"`
  # is ONE statement, and a per-physical-line grep reads its second half as a bare
  # chmod.
  body=$(extract_funcs configure_hermes)
  if [ -z "$body" ]; then
    fail_case "$name" "could not extract configure_hermes from the release artifact"; return
  fi
  local joined="$TMP/announce-hermes-body.txt"
  printf '%s\n' "$body" | awk '
    {
      line = $0
      while (line ~ /\\$/) {
        sub(/\\$/, "", line)
        if ((getline nxt) <= 0) break
        sub(/^[[:space:]]+/, "", nxt)
        line = line " " nxt
      }
      print line
    }' > "$joined"
  cp "$joined" "$TMP/doctor.out"

  # Exactly ONE line may actually run a chmod on the user's .env. The others that
  # name it are the announcement and the --dry-run plan entry, and neither touches
  # the file — but a second real one would be a mode change nobody was shown.
  local exec_chmod announce_ln confirm_ln chmod_ln append_ln gate_ln
  exec_chmod=$(grep -F 'chmod' "$joined" | grep -F 'envf' \
                 | grep -vE '^[[:space:]]*(#|say |note |plan_add )' | grep -c .)
  if [ "$exec_chmod" != "1" ]; then
    fail_case "$name" "expected exactly one executable chmod of the user's .env, found $exec_chmod"; return
  fi
  announce_ln=$(grep -nF 'say "    chmod 600 $envf"' "$joined" | head -1 | cut -d: -f1)
  confirm_ln=$(grep -nF 'confirm "  Append these now?"' "$joined" | head -1 | cut -d: -f1)
  chmod_ln=$(grep -nF 'chmod 600 "$envf"' "$joined" | head -1 | cut -d: -f1)
  append_ln=$(grep -nF '>> "$envf"' "$joined" | head -1 | cut -d: -f1)
  gate_ln=$(grep -nF 'secure_owned_file_mode "$envf"' "$joined" | head -1 | cut -d: -f1)
  if [ -z "$announce_ln" ] || [ -z "$confirm_ln" ] || [ -z "$chmod_ln" ] \
     || [ -z "$append_ln" ] || [ -z "$gate_ln" ]; then
    fail_case "$name" "could not locate the announce / confirm / chmod / append / backstop steps"; return
  fi
  if [ "$announce_ln" -ge "$confirm_ln" ]; then
    fail_case "$name" "the exact chmod is not shown before the operator is asked"; return
  fi
  if [ "$chmod_ln" -le "$confirm_ln" ]; then
    fail_case "$name" "the chmod runs before the operator has said yes"; return
  fi
  if [ "$chmod_ln" -ge "$append_ln" ]; then
    fail_case "$name" "the key is appended before the file is tightened"; return
  fi
  if [ "$gate_ln" -le "$append_ln" ]; then
    fail_case "$name" "the secure_owned_file_mode backstop no longer follows the append"; return
  fi

  funcs=$(extract_funcs file_mode_is_open secure_owned_file_mode run_step mutate_guard \
            confirm control_suffix control_keys prompt_echo explain_prompt quit_run \
            run_changes_nothing interactive_terminal looks_like_a_secret \
            warn_answer_looked_like_a_secret plan_add say ok warn note)
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

# The mode the Hermes API server key is written INTO, observed at the instant it
# is written rather than inferred from the file afterwards. The exposure this
# pins is a window, not an end state: a ~/.hermes/.env Hermes wrote under umask
# 022 is 0644, and a key appended into it is world-readable from the moment it
# lands — for however long it takes to ask a question, and for good if the answer
# is no. So the test hooks the append itself: an `echo` that sees the
# API_SERVER_KEY line stats the file right then, and that reading is the
# assertion.
#
# The other two arms grade the cases where 0600 is NOT reachable, because both
# are deliberate. A chmod that cannot be applied does not abort the setup — on
# the reuse path the key is already in that file, so refusing would leave the
# exposure AND an unconfigured gateway — it falls through to the backstop, which
# has to say the key is still readable. And a declined append changes nothing at
# all: no mode, no key.
run_hermes_key_lands_in_private_file_case() {
  local name="hermes-key-lands-in-a-0600-file" funcs out mode
  local home="$TMP/hermes-key-mode-home" envf
  envf="$home/.hermes/.env"

  funcs=$(extract_funcs configure_hermes hermes_api_server_port show_qr_is_port env_get \
            file_mode_is_open secure_owned_file_mode run_step mutate_guard)
  if ! printf '%s\n' "$funcs" | grep -qF 'configure_hermes()'; then
    fail_case "$name" "could not extract configure_hermes from the release artifact"; return
  fi
  : > "$TMP/doctor.out"

  # The runtime every arm shares. OS is Darwin so the restart arm is the
  # print-by-hand one on every host — a real `systemctl --user` probe would make
  # the case's path depend on the machine running it. The `echo` override is the
  # measuring instrument: it latches the file's mode on the key line and nothing
  # else, so an unrelated `echo` earlier in the function cannot move the reading.
  local runtime='
eval "$FUNCS"
DRY_RUN=false; REUSE_ONLY=false; OS="Darwin"; PLAN=()
BOLD=""; RESET=""; DIM=""; YELLOW=""; GREEN=""; RED=""
GW_ID=""; GW_LOCAL_PORT=""; GW_HEALTH_PATH=""; GW_TOKEN=""; GW_AUTH=""
HOME="$FAKE_HOME"
KEY_MODE=""
echo() {
  case "${1:-}" in
    API_SERVER_KEY=*) KEY_MODE=$(python3 -c "import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))" "$ENVF") ;;
  esac
  builtin echo "$@"
}
head_() { printf "== %s ==\n" "$*"; }
say()   { printf "%s\n" "$*"; }
ok()    { printf "  OK %s\n" "$*"; }
note()  { printf "  .. %s\n" "$*"; }
warn()  { printf "  ! %s\n" "$*"; }
die()   { printf "die: %s\n" "$*"; exit 1; }
have()  { command -v "$1" >/dev/null 2>&1; }
plan_add() { printf "PLAN %s\n" "$*"; }
gw_guard_single_saved_setup() { return 0; }
print_and_wait() { printf "[by-hand] %s\n" "$2"; return 0; }
prompt_into() { eval "$1=fixture-key"; return 0; }
confirm() { printf "[confirm] %s -> %s\n" "$1" "$CONFIRM_ANSWER"; [ "$CONFIRM_ANSWER" = "y" ]; }
'

  # Arm 1 — the file pre-exists at 0644 with no key in it, so a fresh one is
  # generated and appended. This is the arm the fix exists for.
  rm -rf "$home"; mkdir -p "$home/.hermes"
  printf 'API_SERVER_PORT=8642\n' > "$envf"
  chmod 644 "$envf"
  out=$(FUNCS="$funcs" FAKE_HOME="$home" ENVF="$envf" CONFIRM_ANSWER=y \
        bash -c "$runtime"'
configure_hermes
printf "key-write-mode=%s\n" "$KEY_MODE"
' 2>&1) || true
  printf -- '--- accepted on a 0644 file ---\n%s\n' "$out" >> "$TMP/doctor.out"
  assert_runtime_defined "$name" "$out" || return
  if ! printf '%s\n' "$out" | grep -qF 'key-write-mode=0o600'; then
    fail_case "$name" "the API server key was written into a file that was not 0600"; return
  fi
  mode=$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$envf")
  if [ "$mode" != "0o600" ]; then
    fail_case "$name" "the .env did not end up 0600 (mode $mode)"; return
  fi
  if ! grep -q '^API_SERVER_KEY=' "$envf"; then
    fail_case "$name" "no API_SERVER_KEY was appended, so the mode reading proves nothing"; return
  fi
  # One question, not two. The whole point of announcing the chmod with the
  # append is that the secret does not wait behind a second default-No prompt.
  if [ "$(printf '%s\n' "$out" | grep -c '^\[confirm\]')" != "1" ]; then
    fail_case "$name" "the mode change asked its own question instead of riding the append's"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF "chmod 600 $envf"; then
    fail_case "$name" "the exact chmod was never shown to the operator"; return
  fi
  # The generated key is a secret; it may reach the file and nothing else.
  if printf '%s\n' "$out" | grep -qE '[0-9a-f]{64}'; then
    fail_case "$name" "the generated API server key appeared in the run's output"; return
  fi

  # Arm 2 — the chmod cannot be applied (read-only mount, foreign owner). Setup
  # still completes, and the backstop after the append has to say the key is
  # exposed rather than let a failed tighten pass as a done one.
  rm -rf "$home"; mkdir -p "$home/.hermes"
  printf 'API_SERVER_PORT=8642\n' > "$envf"
  chmod 644 "$envf"
  out=$(FUNCS="$funcs" FAKE_HOME="$home" ENVF="$envf" CONFIRM_ANSWER=y \
        bash -c "$runtime"'
chmod() { return 1; }
configure_hermes
printf "key-write-mode=%s\n" "$KEY_MODE"
' 2>&1) || true
  printf -- '--- chmod refused ---\n%s\n' "$out" >> "$TMP/doctor.out"
  assert_runtime_defined "$name" "$out" || return
  if ! printf '%s\n' "$out" | grep -qF 'key-write-mode=0o644'; then
    fail_case "$name" "the arm meant to prove a failed chmod did not actually fail one"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF 'STILL readable'; then
    fail_case "$name" "a chmod that did not take was reported as success"; return
  fi
  if ! grep -q '^API_SERVER_KEY=' "$envf"; then
    fail_case "$name" "an unreachable 0600 left the gateway unconfigured as well as exposed"; return
  fi

  # Arm 3 — declined. One answer covers both halves, so no means no to both: the
  # mode is untouched and nothing is appended.
  rm -rf "$home"; mkdir -p "$home/.hermes"
  printf 'API_SERVER_PORT=8642\n' > "$envf"
  chmod 644 "$envf"
  out=$(FUNCS="$funcs" FAKE_HOME="$home" ENVF="$envf" CONFIRM_ANSWER=n \
        bash -c "$runtime"'
configure_hermes
printf "key-write-mode=%s\n" "$KEY_MODE"
' 2>&1) || true
  printf -- '--- declined ---\n%s\n' "$out" >> "$TMP/doctor.out"
  assert_runtime_defined "$name" "$out" || return
  mode=$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$envf")
  if [ "$mode" != "0o644" ]; then
    fail_case "$name" "a declined step changed the mode anyway (now $mode)"; return
  fi
  if grep -q '^API_SERVER_KEY=' "$envf"; then
    fail_case "$name" "a declined step appended the key anyway"; return
  fi

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# A gateway's Content-Type header is attacker-controlled text on its way to the
# operator's terminal, and the chat probe's failure line quotes it back. Bounding
# it with ${DCC_CT:0:60} caps LENGTH and strips NOTHING, so an ESC reaches the
# terminal: the gateway erases the ✗ line it just earned and repaints a green
# [CHAT_BASIC], and a newline forges a whole extra transcript line. safe_display
# at the parser's exit is the answer, and this case grades the exit rather than
# the print site — every later reader of DCC_CT has to inherit the clean value.
#
# The clean arm is not decoration. Sanitising the value the grader reads would be
# a real defect if it moved the grade, so a legitimate header has to arrive
# byte-identical and still classify as JSON.
run_chat_content_type_is_sanitised_case() {
  local name="chat-content-type-is-sanitised" funcs out dir
  dir="$TMP/chat-ct-sanitise"
  rm -rf "$dir"; mkdir -p "$dir"

  funcs=$(extract_funcs doctor_chat_request doctor_chat_eval doctor_transfer_reason \
            ct_is_json safe_display)
  if ! printf '%s\n' "$funcs" | grep -qF 'doctor_chat_request()'; then
    fail_case "$name" "could not extract doctor_chat_request from the release artifact"; return
  fi
  : > "$TMP/doctor.out"

  # The hostile header carries the two bytes that matter: ESC (repaint what the
  # operator already read) and CR (rewrite the current line). curl hands
  # %{content_type} over verbatim, so the stub reproduces exactly the -w line the
  # real call asks for: "<code> <seconds> <content-type>" after the body.
  out=$(FUNCS="$funcs" OUTDIR="$dir" bash -c '
eval "$FUNCS"
GW_URL="http://127.0.0.1:1"
DCC_ACCEPT="application/json"
ESC=$(printf "\033"); CR=$(printf "\r")
CT_TO_SERVE="application/json${ESC}[2K${CR}  [CHAT_BASIC] forged green line"
curl_gw() { printf "%s\n200 0.5 %s" "{}" "$CT_TO_SERVE"; }
doctor_chat_eval "{}"
printf "%s" "$DCC_CT" > "$OUTDIR/ct.bin"
printf "%s" "$DCE_REASON" > "$OUTDIR/reason.bin"
printf "hint=%s\n" "$DCE_HINT"

CT_TO_SERVE="application/json; charset=utf-8"
doctor_chat_request "{}"
printf "%s" "$DCC_CT" > "$OUTDIR/clean-ct.bin"
if ct_is_json "$DCC_CT"; then printf "clean-graded=json\n"; else printf "clean-graded=other\n"; fi
' 2>&1) || true
  printf -- '--- hostile + clean content-type ---\n%s\n' "$out" >> "$TMP/doctor.out"
  assert_runtime_defined "$name" "$out" || return

  local f
  for f in ct reason; do
    if [ ! -f "$dir/$f.bin" ]; then
      fail_case "$name" "the probe produced no $f value"; return
    fi
    if ! python3 -c 'import sys
b = open(sys.argv[1], "rb").read()
sys.exit(1 if any(x < 0x20 or x == 0x7f for x in b) else 0)' "$dir/$f.bin"; then
      fail_case "$name" "a control byte survived into $f — the terminal can still be repainted"; return
    fi
  done
  if ! grep -qF 'Content-Type is' "$dir/reason.bin"; then
    fail_case "$name" "the failure reason stopped naming the Content-Type it rejected"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF 'hint=ct'; then
    fail_case "$name" "a hostile Content-Type no longer grades as the content-type failure"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF 'clean-graded=json'; then
    fail_case "$name" "sanitising moved the grade of a legitimate Content-Type"; return
  fi
  if [ "$(cat "$dir/clean-ct.bin")" != "application/json; charset=utf-8" ]; then
    fail_case "$name" "a legitimate Content-Type did not survive byte-identical"; return
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
  local input state="$TMP/check-eof-state"
  mkdir -p "$state"
  # \004 is the EOT byte: on a PTY it is the only way to give a reader an end of
  # input, because a terminal never closes. The trailing Enter answers the hub's
  # closing question, which is a SECOND read and would otherwise block until the
  # PTY timeout — a hang the case would then report as a failed continuation.
  input=$'2\nhttp://127.0.0.1:'"$PORT"$'\n\004\n'
  PTY_ENV=(CONDUCK_TOKEN="$TOKEN" XDG_CONFIG_HOME="$state")
  pty_run 30 "$input" > "$TMP/doctor.out" 2>&1 || rc=$?
  stop_fixture
  if [ "$rc" != "0" ] ||
     ! grep -qF 'Would you like to continue with setup and pairing?' "$TMP/doctor.out" ||
     ! grep -qF 'No setup changes were made.' "$TMP/doctor.out"; then
    fail_case "$name" "EOF at the optional continuation did not safely mean no"; return
  fi
  # …and it said so. A default taken because nobody answered is a decision no
  # person made, and a transcript that records it silently is how a reader comes
  # to believe somebody declined on purpose.
  if ! grep -qF 'No answer — treating this as No: Would you like to continue with setup and pairing?' "$TMP/doctor.out"; then
    fail_case "$name" "the unanswered continuation took its default in silence"; return
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
  prompts=$(grep -c 'Key the server expects' "$TMP/doctor.out")
  if [ "$prompts" != "1" ]; then
    fail_case "$name" "the key was asked for $prompts times, expected 1"; return
  fi
  if ! grep -qF 'The key you already entered is kept' "$TMP/doctor.out"; then
    fail_case "$name" "the re-ask never said the key is kept"; return
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
DOCTOR_CONTRACT_REV="1.5"
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
  if ! grep -qF 'No key given and no answer possible' "$TMP/doctor.out"; then
    fail_case "$name" "died for some other reason than the missing key answer"; return
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
# --generic is a FUNCTIONAL legacy alias for custom-server setup: shipped App
# Store builds still emit it verbatim, so it has to keep working even though
# --help never mentions it. Two independent facts, and they need two different
# lanes to observe:
#
#   1. With no terminal it refuses at exit 4 like any other setup, BEFORE the
#      gateway phase. That is the alias inheriting the refusal rather than
#      hand-rolling its own — and the run is over before Step 2, so nothing about
#      the alias's actual behaviour is visible on this path.
#   2. On a PTY it skips detection and lands in custom-server setup even though
#      an OpenClaw install is sitting right there. That is the whole point of the
#      alias, and only a run that can answer questions ever reaches it.
run_generic_alias_case() { # run_generic_alias_case <plain|dry-run>
  local variant="$1" name="generic-legacy-alias" rc=0 home="$TMP/generic-home"
  local state="$TMP/generic-state"
  local -a extra=()
  if [ "$variant" = "dry-run" ]; then
    name="generic-legacy-alias-dry-run"; extra=(--dry-run)
    home="$TMP/generic-dry-home"; state="$TMP/generic-dry-state"
  fi
  mkdir -p "$home/.openclaw" "$state"
  printf '{}\n' > "$home/.openclaw/openclaw.json"

  # -- lane 1: no terminal -----------------------------------------------------
  env HOME="$home" XDG_CONFIG_HOME="$state" TERM=dumb bash "$SCRIPT" --generic ${extra[@]+"${extra[@]}"} \
    > "$TMP/doctor.out" 2>&1 < /dev/null || rc=$?
  if [ "$rc" != "4" ]; then
    fail_case "$name" "a no-terminal --generic run exited $rc, expected 4"; return
  fi
  if ! grep -qF 'needs a person at a terminal' "$TMP/doctor.out"; then
    fail_case "$name" "the refusal did not say what is actually missing"; return
  fi
  # Refused BEFORE the gateway phase — no question was asked and no config was
  # read. If Step 2 ever appears on this path the refusal has moved too late.
  if grep -qF 'Step 2 —' "$TMP/doctor.out"; then
    fail_case "$name" "the terminal refusal came after setup had already started asking"; return
  fi

  # -- lane 2: a real terminal -------------------------------------------------
  # Enter = the default name, n = local rather than https, t = "I'll type the
  # port" (a silent no-op when this machine offered no listening ports), q = stop.
  rc=0
  PTY_ENV=(HOME="$home" XDG_CONFIG_HOME="$state")
  pty_run 15 $'\nn\nt\nq\n' --generic ${extra[@]+"${extra[@]}"} > "$TMP/doctor.out" 2>&1 || rc=$?
  if [ "$rc" != "3" ]; then
    fail_case "$name" "q during --generic setup exited $rc, expected 3"; return
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
  if ! grep -qF 'Step 2 — your OpenAI-compatible server' "$TMP/doctor.out"; then
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

# ===================== the image gate, against real adapters =================
#
# The measured bug: `--check-server` printed "image input: IGNORED" and returned
# PASS with exit 0, and `--check-adapter --deep` failed the same adapter and then
# offered "pair it; a failed grade here doesn't block that". So an adapter that
# silently ate every photo paired successfully, and the operator found out the
# first time a picture vanished mid-conversation — the one failure the app cannot
# show, because a dropped image comes back as an ordinary confident reply and the
# pairing payload has no field to carry a warning.
#
# Every arm drives the SHIPPED verify_image_intake against a real fixture on
# loopback. The outcome table is about what a server actually answers, so a
# stubbed evaluator would only grade the stub. What is pinned is the severity
# rule: exactly which outcomes may withhold a pairing code, and which may not.
# The pass arms are the load-bearing half — a gate that blocked everything would
# satisfy "the bad adapter is stopped" while breaking every honest text-only
# setup, which is the commonest custom gateway there is.
#
# extract_funcs cannot serve this family: image_probe_gen embeds a python literal
# whose FONT dict closes with a column-0 `}`, and the sed lift every other case
# relies on stops there, half a function short. So the artifact is sourced as a
# LIBRARY — everything above the command dispatch, which is the whole function
# catalogue with its real globals and nothing that runs.
image_gate_library() { # image_gate_library <out-file>
  sed -n '1,/^if \[ "\$COMMAND" = "menu" \]; then$/p' "$SCRIPT" | sed '$d' > "$1"
  grep -q '^verify_image_intake()' "$1" && grep -q '^image_probe_gen()' "$1"
}

# One gate run against one address. Sourcing installs the release EXIT/signal
# traps, so they are cleared first: an inherited on_exit would print a run
# epilogue into the middle of the assertions.
run_image_gate_probe() { # <lib> <url> <auth> <token> <from-check-kind> <tty> <answer>
  LIB="$1" IGURL="$2" IGAUTH="$3" IGTOK="$4" IGKIND="$5" IGTTY="$6" IGANS="$7" bash -c '
. "$LIB"
trap - EXIT HUP INT TERM
GREEN=""; RED=""; YELLOW=""; DIM=""; BOLD=""; RESET=""
say()  { printf "%s\n" "$*"; }
ok()   { printf "OK %s\n" "$*"; }
bad()  { printf "BAD %s\n" "$*"; }
warn() { printf "WARN %s\n" "$*"; }
note() { printf "NOTE %s\n" "$*"; }
die()  { printf "DIE %s\n" "$*"; exit 9; }
confirm() { printf "CONFIRM %s\n" "$1"; [ "$IGANS" = "y" ]; }
interactive_terminal() { [ "$IGTTY" = "yes" ]; }
DOCTOR=false; COMPAT=false
GW_URL="$IGURL"; GW_AUTH="$IGAUTH"; GW_TOKEN="$IGTOK"; GW_MODEL=""
VERIFY_FAILED=false; SETUP_FROM_CHECK_KIND="$IGKIND"
verify_image_intake
printf "GATE proof=%s failed=%s\n" "$IMG_PROOF" "$VERIFY_FAILED"
'
}

run_image_gate_case() {
  local name="image-gate-blocks-only-the-silent-drop" lib="$TMP/gate-lib.sh"
  local arm mode kind tty ans want_proof want_failed out flat got_retry
  if ! image_gate_library "$lib"; then
    fail_case "$name" "could not lift the release artifact into a library"; return
  fi
  : > "$TMP/doctor.out"

  # Severity keys on the OUTCOME and nothing else. The two adapter-provenance
  # arms are the load-bearing pair: arriving from --check-adapter changes the
  # advice printed, never what the gate does with the answer. The probe cannot
  # observe forwarding — only whether the digits came back — so a run that came
  # through the stricter door must not convert that same inconclusive reading
  # into a verdict a conforming adapter cannot appeal.
  #
  # arm|fixture-mode|from-check-kind|tty|answer|expect-proof|expect-VERIFY_FAILED
  local arms='sees-it|good||yes|n|verified|false
declines-honestly|text-only||yes|n|declined|false
refused-too-large|strict-fields-image-413||yes|n|too-large|false
ignored-declined|silent-drop-image||yes|n|ignored|true
ignored-acknowledged|silent-drop-image||yes|y|ignored-acked|false
ignored-from-check-adapter-declined|silent-drop-image|adapter|yes|n|ignored|true
ignored-from-check-adapter-acked|silent-drop-image|adapter|yes|y|ignored-acked|false
ignored-no-terminal|silent-drop-image||no|y|ignored|true'
  while IFS='|' read -r arm mode kind tty ans want_proof want_failed; do
    [ -n "$arm" ] || continue
    start_fixture "$mode" || { fail_case "$name" "[$arm] fixture $mode failed to start"; stop_fixture; return; }
    out=$(run_image_gate_probe "$lib" "http://127.0.0.1:$PORT" bearer "$TOKEN" "$kind" "$tty" "$ans")
    stop_fixture
    printf -- '--- %s ---\n%s\n' "$arm" "$out" >> "$TMP/doctor.out"
    flat=$(printf '%s\n' "$out" | tr '\n' ' ')

    case "$flat" in *"GATE proof=$want_proof failed=$want_failed"*) ;;
      *) fail_case "$name" "[$arm] expected proof=$want_proof failed=$want_failed"; return ;;
    esac

    # A pairing code is withheld by exactly one finding, and only after the gate
    # has SEEN the same answer twice. Everything else — a size cap, an honest
    # refusal, a picture the engine read — leaves the code alone. The pass arms
    # are what stops this gate from turning into "no photos, no pairing".
    case "$want_failed" in
      true)  case "$flat" in *"answered 200 — twice"*) ;;
               *) fail_case "$name" "[$arm] a code was withheld without naming the repeated silent answer"; return ;;
             esac ;;
    esac

    # Only the blocking outcome is retried. A second live turn is a second real
    # (and on a paid gateway, billable) request, so it is spent only where the
    # first answer would otherwise cost the operator their setup — never after a
    # transport fault, an honest decline, or a size cap.
    case "$flat" in *"Trying once with a new picture"*) got_retry=yes ;; *) got_retry=no ;; esac
    case "$want_proof" in
      ignored|ignored-acked)
        [ "$got_retry" = "yes" ] || { fail_case "$name" "[$arm] judged a silent answer on one turn"; return ;} ;;
      *)
        [ "$got_retry" = "no" ] || { fail_case "$name" "[$arm] spent a second live turn on an outcome that cannot block"; return ;} ;;
    esac
  done <<ARMS
$arms
ARMS

  # Per-arm wording, where the exit state alone cannot tell a true explanation
  # from a false one.
  #
  # The honest text-only server is the case most likely to be broken by a careless
  # implementation, so it is asserted in both directions: it passes, and it is
  # never told its photos vanish.
  start_fixture text-only || { fail_case "$name" "text-only fixture failed to start"; stop_fixture; return; }
  out=$(run_image_gate_probe "$lib" "http://127.0.0.1:$PORT" bearer "$TOKEN" "" yes n)
  stop_fixture
  printf -- '--- text-only wording ---\n%s\n' "$out" >> "$TMP/doctor.out"
  flat=$(printf '%s\n' "$out" | tr '\n' ' ')
  if warning_states "$flat" 'CONFIRM|silently|BAD '; then
    fail_case "$name" "a conformant 400 + image_unsupported decline was treated as a problem"; return
  fi
  if ! warning_states "$flat" "pictures aren.t supported here"; then
    fail_case "$name" "an honest decline did not say what the app shows instead"; return
  fi

  # The provenance arm ASKS, like every other. It is measured here in both
  # directions because the earlier revision of this gate did the opposite: it
  # converted the same inconclusive reading into an unappealable block whenever
  # the run arrived from --check-adapter. The probe cannot see forwarding, only
  # whether the digits came back, so an adapter that forwarded a picture to an
  # engine that misread it produces this exact transcript — and would have been
  # refused a code for conforming. What provenance still earns is ADVICE: the
  # loop that grades the wire strictly, and the rule it grades against. Driven
  # with No, which is where an adapter author who takes the finding seriously
  # lands and therefore where the advice has to be waiting.
  start_fixture silent-drop-image || { fail_case "$name" "silent-drop fixture failed to start"; stop_fixture; return; }
  out=$(run_image_gate_probe "$lib" "http://127.0.0.1:$PORT" bearer "$TOKEN" adapter yes n)
  stop_fixture
  printf -- '--- adapter provenance ---\n%s\n' "$out" >> "$TMP/doctor.out"
  flat=$(printf '%s\n' "$out" | tr '\n' ' ')
  if ! warning_states "$flat" 'CONFIRM'; then
    fail_case "$name" "arriving from --check-adapter decided the question instead of asking it"; return
  fi
  if ! warning_states "$flat" 'check-adapter --deep' || ! warning_states "$flat" 'image_unsupported'; then
    fail_case "$name" "the adapter route named neither the way to iterate nor the conforming refusal"; return
  fi

  # A run with no terminal reaches the same fail-closed end WITHOUT printing a
  # question into a log nobody reads — --show-code has no interactivity guard of
  # its own, and a missing code whose only explanation is an unanswered prompt is
  # the worst of both.
  start_fixture silent-drop-image || { fail_case "$name" "silent-drop fixture failed to start"; stop_fixture; return; }
  out=$(run_image_gate_probe "$lib" "http://127.0.0.1:$PORT" bearer "$TOKEN" "" no y)
  stop_fixture
  printf -- '--- no terminal ---\n%s\n' "$out" >> "$TMP/doctor.out"
  flat=$(printf '%s\n' "$out" | tr '\n' ' ')
  if warning_states "$flat" 'CONFIRM'; then
    fail_case "$name" "a question was asked on a run that cannot answer one"; return
  fi
  if ! warning_states "$flat" 'no terminal'; then
    fail_case "$name" "the fail-closed run did not say why it could not ask"; return
  fi
  # No bypass flag exists, so the recovery this prints is the whole recovery and
  # it has to be actionable: re-run it somewhere the question can be answered, or
  # fix the gateway. A stop with no way forward sends the operator to the one
  # workaround always available and always wrong — deleting the check.
  if ! warning_states "$flat" 'Re-run me from a terminal' || ! warning_states "$flat" 'image_unsupported'; then
    fail_case "$name" "the fail-closed run named no way forward"; return
  fi

  # A transport failure is NOT a verdict about images. Nothing is listening on
  # port 1; the gate must report that it measured nothing, keep the code, and
  # never name a drop it did not see.
  out=$(run_image_gate_probe "$lib" "http://127.0.0.1:1" bearer "$TOKEN" "" yes n)
  printf -- '--- transport failure ---\n%s\n' "$out" >> "$TMP/doctor.out"
  flat=$(printf '%s\n' "$out" | tr '\n' ' ')
  case "$flat" in *"GATE proof=unmeasured failed=false"*) ;;
    *) fail_case "$name" "a dead address was not reported as unmeasured, or it withheld a code"; return ;;
  esac
  if ! warning_states "$flat" 'NOT measured'; then
    fail_case "$name" "a transport fault did not say the question went unanswered"; return
  fi
  if warning_states "$flat" 'silently|drops|ignored'; then
    fail_case "$name" "a transport fault was reported as a gateway that loses photos"; return
  fi

  # How many live turns each outcome actually costs. The arms above can only see
  # the sentence announcing a retry, and a sentence is not a request — an earlier
  # revision of this case stayed green with the second probe call deleted. Turns
  # are counted at the evaluator, so this is the act rather than the narration:
  # a second real (and on a metered gateway, billable) request is spent on the
  # ONE answer that would otherwise cost the operator their setup, and on nothing
  # else — least of all on a transport fault, where the tunnel dropping twice is
  # the likeliest way to double a charge for no information at all.
  local turns
  # scripted-reply|expected-turns
  local turn_rows='notoken|2
token|1
transport|1
decline|1
toobig|1'
  local scripted want_turns
  while IFS='|' read -r scripted want_turns; do
    [ -n "$scripted" ] || continue
    turns=$(LIB="$lib" SCRIPTED="$scripted" bash -c '
. "$LIB"
trap - EXIT HUP INT TERM
say(){ :; }; ok(){ :; }; bad(){ :; }; warn(){ :; }; note(){ :; }
confirm(){ return 0; }; interactive_terminal(){ return 0; }
GW_MODEL=""; DOCTOR=false; COMPAT=false
VERIFY_FAILED=false; SETUP_FROM_CHECK_KIND=""
TURNS=0
app_chat_eval() {
  TURNS=$((TURNS+1))
  DCC_CURL_RC=0; DCC_CODE=""; CCE_WIRE_CODE=""; CCE_TOKEN=""; CCE_LEN=3; CCE_REASON="scripted"
  case "$SCRIPTED" in
    token)     CCE_TOKEN="yes"; return 0 ;;
    notoken)   CCE_TOKEN="no";  return 0 ;;
    transport) DCC_CURL_RC=7; return 1 ;;
    decline)   DCC_CODE=400; CCE_WIRE_CODE="image_unsupported"; return 1 ;;
    toobig)    DCC_CODE=413; return 1 ;;
  esac
}
verify_image_intake
printf "%s\n" "$TURNS"
')
    printf -- '--- turns: %s -> %s (want %s) ---\n' "$scripted" "$turns" "$want_turns" >> "$TMP/doctor.out"
    if [ "$turns" != "$want_turns" ]; then
      fail_case "$name" "a '$scripted' answer cost $turns live turns, expected $want_turns"; return
    fi
  done <<TURNROWS
$turn_rows
TURNROWS

  # The retry has to carry DIFFERENT digits or it is not a second look: a cached
  # reply, or the one-in-nine-thousand coincidence the first turn was retried
  # for, would pass on exactly the run where it must not. Driven with no server
  # at all — the redraw happens before any request, and this asserts the property
  # the live arms above can only assume.
  local redraw
  redraw=$(LIB="$lib" bash -c '
. "$LIB"
trap - EXIT HUP INT TERM
GW_MODEL=""; DOCTOR=false; COMPAT=false
app_chat_eval() { DCC_CURL_RC=7; return 1; }   # never reaches the wire
REAL_GEN=$(declare -f image_probe_gen)

# The predicate, which nothing else in the tree exercises. "Too close" is one
# differing position or fewer, because the grader forgives exactly one; a length
# mismatch cannot be confused at all and so is never too close.
tc=""
for row in 728431:728431:close 728431:728432:close 728431:725432:far \
           728431:72843:far 728431::far 111111:222222:far; do
  a=${row%%:*}; rest=${row#*:}; b=${rest%%:*}; want=${rest#*:}
  if probe_codes_too_close "$a" "$b"; then got=close; else got=far; fi
  [ "$got" = "$want" ] || tc="$tc $a/$b=$got(want $want)"
done
printf "predicate=%s\n" "${tc:-ok}"

# The loop must REDRAW on a close code and stop once it is clear. Driven with a
# scripted generator on purpose: a live one lands within one position of a fixed
# code about once in seventeen thousand draws, so no number of random iterations
# reaches this path — the assertion below it was unreachable by construction
# while the avoid value was a different length from the code.
# The real generator runs once first, so IPG_PATH and the rest of its output are
# genuine; only the digits are then scripted.
CONDUCK_PROBE_MODEL="" image_probe_gen
draws=0
image_probe_gen() {
  draws=$((draws+1))
  case $draws in
    1) IPG_CODE="728432" ;;   # one position off the avoided code: unusable
    *) IPG_CODE="519073" ;;   # far enough: usable
  esac
}
verify_image_probe_once "728431"
printf "scripted draws=%s final=%s\n" "$draws" "$IPG_CODE"

# A generator that never clears the guard must not spin forever.
draws=0
image_probe_gen() { draws=$((draws+1)); IPG_CODE="728431"; }
verify_image_probe_once "728431"
printf "bounded draws=%s\n" "$draws"

eval "$REAL_GEN"
first=""; repeats=0; i=0
while [ $i -lt 40 ]; do
  i=$((i+1))
  verify_image_probe_once "424242"
  [ "$IPG_CODE" = "424242" ] && repeats=$((repeats+1))
  first="$first $IPG_CODE"
done
printf "repeats=%s distinct=%s\n" "$repeats" "$(printf "%s\n" $first | sort -u | wc -l | tr -d " ")"
')
  printf -- '--- retry redraw ---\n%s\n' "$redraw" >> "$TMP/doctor.out"
  case "$redraw" in *"predicate=ok"*) ;;
    *) fail_case "$name" "the too-close predicate misgraded a pair: $redraw"; return ;;
  esac
  case "$redraw" in *"scripted draws=2 final=519073"*) ;;
    *) fail_case "$name" "a code one glyph off the previous attempt was not redrawn: $redraw"; return ;;
  esac
  case "$redraw" in *"bounded draws=9"*) ;;
    *) fail_case "$name" "the redraw loop is not bounded at 8 retries: $redraw"; return ;;
  esac
  case "$redraw" in *"repeats=0"*) ;;
    *) fail_case "$name" "a retry was allowed to reuse the first attempt's digits"; return ;;
  esac
  # Non-vacuity: the generator is genuinely random, so "never 424242" is a real
  # constraint rather than a property of a generator that returns one value.
  case "$redraw" in *"distinct=1 "*|*"distinct=1")
      fail_case "$name" "the probe generator returned one fixed code, so the redraw guard proves nothing"; return ;;
  esac

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# Wiring the live arms cannot see: WHERE the gate sits, and what a blocked gate
# does to the rest of verify_all. It must run after the text round-trip (a
# gateway that cannot answer text at all is not a gateway with an image problem),
# before the file lane (whose own entry guard then reads the failure and declines
# to spend a five-minute agent turn on a run that will emit no code), and it must
# spend nothing at all when verification has already failed above it.
run_image_gate_placement_case() {
  local name="image-gate-runs-between-the-chat-turn-and-the-file-lane" verify funcs out flat
  local n_chat n_img n_lane
  verify=$(sed -n '/^verify_all()/,/^}/p' "$SCRIPT")
  n_chat=$(printf '%s\n' "$verify" | grep -n 'app_chat_eval "\$body"' | head -1 | cut -d: -f1)
  n_img=$(printf '%s\n'  "$verify" | grep -n 'verify_image_intake'    | head -1 | cut -d: -f1)
  n_lane=$(printf '%s\n' "$verify" | grep -n 'FS_URL" \] && \[ -n "\$FS_CRED' | head -1 | cut -d: -f1)
  : > "$TMP/doctor.out"
  printf 'chat=%s image=%s lane=%s\n' "$n_chat" "$n_img" "$n_lane" > "$TMP/doctor.out"
  if [ -z "$n_chat" ] || [ -z "$n_img" ] || [ -z "$n_lane" ] \
     || [ "$n_img" -le "$n_chat" ] || [ "$n_img" -ge "$n_lane" ]; then
    fail_case "$name" "the image gate is not between the chat round-trip and the file lane"; return
  fi

  funcs=$(extract_funcs verify_all gw_url_drift_note)
  if [ -z "$funcs" ] || ! printf '%s\n' "$funcs" | grep -qF 'verify_all()'; then
    fail_case "$name" "could not extract verify_all from the release artifact"; return
  fi

  # A gateway that already failed: the gate is silent and spends nothing.
  out=$(run_verify_all_isolated "$funcs" public 0 200 0 up 8080 fail "" "" false bearer no pass)
  printf -- '--- failed gateway ---\n%s\n' "$out" >> "$TMP/doctor.out"
  if warning_states "$(printf '%s\n' "$out" | tr '\n' ' ')" 'IMAGE-GATE'; then
    fail_case "$name" "a doomed run still spent a live photo turn"; return
  fi

  # A green gateway: the gate runs, and its block is what withholds the code —
  # through the same VERIFY_FAILED emit_payload already honours, not a second
  # mechanism beside it.
  out=$(run_verify_all_isolated "$funcs" public 0 200 0 up 8080 ok "" "" false bearer no block)
  printf -- '--- gate blocks ---\n%s\n' "$out" >> "$TMP/doctor.out"
  flat=$(printf '%s\n' "$out" | tr '\n' ' ')
  if ! warning_states "$flat" 'IMAGE-GATE block'; then
    fail_case "$name" "the gate never ran on a passing gateway"; return
  fi
  if ! warning_states "$flat" 'VERIFY_FAILED=true'; then
    fail_case "$name" "a blocking gate did not fail verification, so a code would still be printed"; return
  fi

  # Control: the same run with a passing gate leaves verification green. Without
  # it the assertion above could be satisfied by a verify_all that always fails.
  out=$(run_verify_all_isolated "$funcs" public 0 200 0 up 8080 ok "" "" false bearer no pass)
  printf -- '--- gate passes ---\n%s\n' "$out" >> "$TMP/doctor.out"
  if ! warning_states "$(printf '%s\n' "$out" | tr '\n' ' ')" 'VERIFY_FAILED=false'; then
    fail_case "$name" "a passing gate still failed verification"; return
  fi

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# The new consent gate owes an `i` panel, like every other confirm in setup. A
# missing entry is silent — explain_prompt falls through to the generic panel —
# so the question that costs someone their photos would be the one step in setup
# that cannot explain itself.
run_image_gate_explanation_case() {
  local name="image-gate-question-explains-itself" out lib="$TMP/gate-lib.sh"
  if [ ! -f "$lib" ] && ! image_gate_library "$lib"; then
    fail_case "$name" "could not lift the release artifact into a library"; return
  fi
  out=$(LIB="$lib" bash -c '. "$LIB"; trap - EXIT HUP INT TERM
BOLD=""; RESET=""; explain_action verification.image_ignored')
  printf -- '--- explain verification.image_ignored ---\n%s\n' "$out" > "$TMP/doctor.out"
  # The generic fallback is what a missing id produces, so its opening line is
  # the exact thing this must NOT be.
  case "$out" in *"Review the current setup action"*)
      fail_case "$name" "the image question fell through to the generic panel"; return ;;
  esac
  case "$out" in *"did not reflect the test picture"*) ;;
    *) fail_case "$name" "the panel does not describe the finding being consented to"; return ;;
  esac
  # It has to be honest about what No costs, because No is the default: a run
  # that ends here rolls the file lane's exposure back like any other failure.
  case "$out" in *"rolled back"*) ;;
    *) fail_case "$name" "the panel does not say what ending the run undoes"; return ;;
  esac
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

# The fixture reads the probe PNG by matching each glyph cell against its OWN
# copy of the generator's font, because it must not import the release artifact.
# Two copies means drift, and drift here is quiet in the worst way: an unknown
# glyph decodes to None, the fixture answers with no digits, and every honest arm
# of the deep image family goes red under [IMAGE_INPUT] — which reads as "the
# adapter drops pictures", the exact fault those arms exist to detect. A real
# edit to the shipped glyphs (they were changed once, to stop vision models
# misreading a slashed 0 and a flat-topped 3) would look identical to a
# regression. This case makes the tables answer for themselves.
# The grader decides whether a reply proves the engine saw the picture. It is
# duplicated — doctor_chat_eval and app_chat_body_eval each carry their own copy,
# because each lives in its own python -c block — and the two grading the same
# gateway differently is the one outcome an operator cannot act on. Nothing but
# this case holds them together.
#
# It also pins the ACCEPTANCE RULE itself, which shipped once with no coverage at
# all: the threshold could be widened from "one wrong position" to "three" and
# every image test in this suite still passed, because the fixture only ever
# answers with the exactly-decoded code. The rows below are the cases the fixture
# structurally cannot produce.
run_probe_grader_case() {
  local name="probe-grader" out
  out=$(SCRIPT="$SCRIPT" python3 - <<'PY'
import os, re, subprocess, sys

src = open(os.environ["SCRIPT"], encoding="utf-8").read()

# Lift every copy of the grader out of the artifact. Both must exist, and both
# must be character-identical: a divergence here is the defect this case exists
# for, so it is checked before either is exercised.
blocks = re.findall(r"^if exp != \"-\":\n(.*?)^print\(\"ok %d\" % len\(c\)\)",
                    src, re.M | re.S)
if len(blocks) != 2:
    print("expected 2 grader copies in the artifact, found %d" % len(blocks)); sys.exit(0)

# Compare the CODE, not the prose. The two copies carry deliberately different
# comments — one holds the reasoning, the other points at it — so a raw diff
# would fail permanently and this case would be deleted rather than fixed.
def code_only(b):
    return [ln.rstrip() for ln in b.splitlines()
            if ln.strip() and not ln.strip().startswith("#")]

if code_only(blocks[0]) != code_only(blocks[1]):
    print("the two grader copies have diverged"); sys.exit(0)

# Rebuilt with the block's own `if` header so its indentation stays valid, and
# with the same trailing print the artifact has, so the "no expected code" path
# is exercised by the identical source too.
body = ('import re, sys\n'
        'c = sys.stdin.read()\n'
        'exp = sys.argv[1]\n'
        'if exp != "-":\n' + blocks[0].rstrip() + '\n'
        'print("ok %d" % len(c))\n')

def grade(reply, exp):
    r = subprocess.run([sys.executable, "-c", body, exp], input=reply,
                       capture_output=True, text=True)
    if r.returncode != 0:
        return "<crash:%s>" % (r.stderr.strip().splitlines() or ["?"])[-1][:60]
    return (r.stdout.split() or ["<empty>"])[0]

CODE = "728431"
CASES = [
    # reply                                              exp     want
    (CODE,                                               CODE,   "token"),
    ("The digits are 728431.",                           CODE,   "token"),
    ("7 2 8 4 3 1",                                      CODE,   "token"),
    ("7 2 8 4 3 1. I read 6 digits.",                    CODE,   "token"),
    ("728432",                                           CODE,   "near"),    # one wrong
    ("I read 728432 in the image.",                      CODE,   "near"),
    ("728433 is my reading",                             "728431", "near"),
    ("725432",                                           CODE,   "notoken"), # two wrong
    ("I cannot see any image.",                          CODE,   "notoken"),
    ("",                                                 CODE,   "notoken"),
    # the refusal that must never assemble a code out of unrelated numbers
    ("I cannot see an image. Retry in 7 to 2 minutes, "
     "code 8, dept 4, room 3, ext 1.",                   CODE,   "notoken"),
    # Many same-length numbers must not buy one draw at the tolerance each.
    # EVERY id here is within one digit of the code on purpose: if the rule ever
    # scores the best of several candidates, this must go green and fail the case
    # no matter which candidate it happens to look at first.
    ("No image. ids: 728430 728432 728433 728434 728435", CODE,  "notoken"),
    # A degenerate expected length must not make every reply a sighting. The
    # reply carries exactly one digit so the comparison is actually reached —
    # with no digits at all the candidate list is empty and the guard is moot,
    # which is what made an earlier version of this row prove nothing.
    ("I see 5 things.",                                  "7",    "notoken"),
    # A digit run of the WRONG length must never reach the near-miss comparison:
    # zip() truncates to the shorter string, so an unfiltered 5-digit run would
    # score 5 of 5 against a 6-digit code and grade as a sighting.
    ("I read 72843 in the image.",                       CODE,   "notoken"),
    ("I read 7284310 in the image.",                     CODE,   "notoken"),
    # Spaced groups: EVERY one counts, and each must be maximal. A first-match
    # search let the first of several guesses stand alone and collect the
    # tolerance; an unanchored group let a long spray be windowed to its first n.
    ("Either 7 2 8 4 3 0 or 7 2 8 4 3 5 or 1 1 1 1 1 1 "
     "-- I cannot see the image.",                       CODE,   "notoken"),
    ("Cannot read it. Maybe 7 2 8 4 3 0 9 9 9 9.",       CODE,   "notoken"),
    ("digits 1 2 3 4 5 6 7 8 9 0 shown",                 "123456", "notoken"),
    # ...and the honest shapes those two anchors must not cost us.
    ("The code is 7 2 8 4 3 1",                          CODE,   "token"),
    ("7-2-8-4-3-1",                                      CODE,   "token"),
    ("I see 7 2 8 4 3 2 in the picture.",                CODE,   "near"),
]
bad = []
for reply, exp, want in CASES:
    got = grade(reply, exp)
    if got != want:
        bad.append("%r exp=%s -> %s (want %s)" % (reply[:42], exp, got, want))
print("OK" if not bad else " | ".join(bad))
PY
)
  if [ "$out" != "OK" ]; then
    fail_case "$name" "probe grader: ${out:-the comparison produced nothing}"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# The `near` verdict crosses TWO layers and only the python half had coverage.
# The grader prints "near"; a shell case arm in each checker has to turn that
# into "sighted, one glyph misread". Deleting either arm left all four suites
# green — and at runtime a one-glyph misread then fell into the catch-all and was
# reported as "could not grade the reply", so the honest gateway this whole
# tolerance exists to stop accusing was accused a different way. The fixture
# cannot reach this: it answers with the exactly-decoded code and has no mode
# that perturbs a digit. So the artifact's own functions are driven directly,
# with only the transport answered from here.
run_probe_near_verdict_case() {
  local name="probe-near-verdict" doctor server out
  doctor=$(sed -n '/^doctor_chat_eval()/,/^}/p' "$SCRIPT")
  server=$(sed -n '/^app_chat_body_eval()/,/^}/p' "$SCRIPT")
  if [ -z "$doctor" ] || [ -z "$server" ]; then
    fail_case "$name" "could not lift both graders out of the release artifact"; return
  fi
  out=$(DOCTOR_FN="$doctor" SERVER_FN="$server" bash -c '
set -u
eval "$DOCTOR_FN"
eval "$SERVER_FN"
ct_is_json() { return 0; }
DCC_CURL_RC=0
grade() { # grade <content> -> "<doctor rc/token/near> <server rc/token/near>"
  local body d_rc=0 s_rc=0
  body="{\"choices\":[{\"message\":{\"content\":\"$1\"}}]}"
  doctor_chat_request() { DCC_BODY="$body"; DCC_CODE="200"; DCC_CT="application/json"; return 0; }
  doctor_chat_eval "{}" "728431" || d_rc=$?
  app_chat_body_eval "$body" "728431" || s_rc=$?
  printf "%s/%s/%s %s/%s/%s" "$d_rc" "${DCE_TOKEN:--}" "${DCE_NEAR:--}" \
                             "$s_rc" "${CCE_TOKEN:--}" "${CCE_NEAR:--}"
}
printf "exact   %s\n" "$(grade "The digits are 728431.")"
printf "oneoff  %s\n" "$(grade "I read 728432 in the image.")"
printf "twooff  %s\n" "$(grade "I read 725432 in the image.")"
' 2>&1)
  # An exact read is a sighting with nothing to disclose; one wrong glyph is a
  # sighting that MUST carry the near flag onward, or the operator is told the
  # picture arrived clean when it did not; two wrong is not a sighting at all.
  if [ "$out" != "exact   0/yes/- 0/yes/-
oneoff  0/yes/yes 0/yes/yes
twooff  0/no/- 0/no/-" ]; then
    fail_case "$name" "the near verdict is not carried by both checkers: ${out:-no output}"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

run_probe_font_mirror_case() {
  local name="probe-font-mirror" out
  out=$(SCRIPT="$SCRIPT" FIXTURE="$FIXTURE" python3 - <<'PY'
import ast, os, re

def font(path):
    # literal_eval, not eval: this parses two files the suite does not own, and a
    # font table is a pure literal (digit -> 7 ints). It also spans both spellings
    # in use — the artifact writes decimal, the fixture writes 0b binary.
    src = open(path, encoding="utf-8").read()
    m = re.search(r"^FONT = \{$(.*?)^\}$", src, re.M | re.S)
    if not m:
        return None
    try:
        return ast.literal_eval("{" + m.group(1) + "}")
    except Exception:
        return None

a, b = font(os.environ["SCRIPT"]), font(os.environ["FIXTURE"])
if a is None:
    print("no FONT literal found in the release artifact")
elif b is None:
    print("no FONT literal found in the fixture")
elif len(a) != 10:
    print("the artifact font has %d glyphs, expected 10" % len(a))
elif a != b:
    print("glyphs disagree: " + ",".join(sorted(k for k in set(a) | set(b)
                                                if a.get(k) != b.get(k))))
else:
    # The SEPARATION, not just the table. The font comment argues the closest
    # pair at length, and until this ran the comment was the only thing guarding
    # it — a restyle silently dropped the minimum from 6 to 5 and nothing said
    # so. Exact, not ">=": the comment states a number, and a glyph edit that
    # moves it in EITHER direction has to move the prose with it.
    MIN_SEP, MIN_PAIR = 5, "0/8"
    worst, pair = 99, ""
    keys = sorted(a)
    for i, x in enumerate(keys):
        for y in keys[i + 1:]:
            d = sum(bin(p ^ q).count("1") for p, q in zip(a[x], a[y]))
            if d < worst:
                worst, pair = d, "%s/%s" % (x, y)
    if (worst, pair) != (MIN_SEP, MIN_PAIR):
        print("closest glyph pair is %s at %d cells; the font comment in "
              "src/60-check-adapter.inc.sh says %s at %d — update both"
              % (pair, worst, MIN_PAIR, MIN_SEP))
    else:
        print("OK")
PY
)
  if [ "$out" != "OK" ]; then
    fail_case "$name" "probe font mirror: ${out:-the comparison produced nothing}"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

ONLY="${*:-}"
printf 'conduck-connect regression suite — fixture on 127.0.0.1 (OS-assigned port), per-run token\n'
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

# The golden wire text, pinned in the SHIPPED artifact.
#
# What this can and cannot do, said plainly: the app lives in another repository,
# so nothing here can compare these strings against ConverseRequest.swift — that
# comparison is a human reading two files, and the doctor's own comment says so.
# What a test CAN hold is the two failures that have actually happened: a retired
# directive surviving somewhere in the artifact, and the two independent copies of
# the frozen line drifting apart. Both are cheap to state and neither can pass by
# accident.
run_golden_wire_case() {
  local name="golden-wire-text-is-frozen"
  local frozen="[Conduck file transfer] Files you produce for this reply go in: "
  local refhdr="The following file(s) are in your working directory — use them for this request:"
  local n
  # 1 — the retired reply-prose directive is gone everywhere. It told the agent
  #     to write at the working-directory ROOT and to name the file in plain
  #     reply text; both are rules the app no longer has, and an agent obeying
  #     either one delivers nothing.
  if grep -qF 'To return a file, write it to the root' "$SCRIPT"; then
    fail_case "$name" "the retired root-and-name-it directive is still in the artifact"; return
  fi
  if grep -qF 'Each input lives under its conversation folder' "$SCRIPT"; then
    fail_case "$name" "the retired per-conversation-folder claim is still in the artifact"; return
  fi
  # 2 — every copy of the outbox line is the SAME line. Two independent copies
  #     ship (the doctor's sentinel and the wizard's readiness probe), and a
  #     third would be just as welcome — what must never happen is two spellings.
  n=$(grep -cF "$frozen" "$SCRIPT")
  if [ "$n" -lt 2 ]; then
    fail_case "$name" "the frozen outbox line appears $n time(s); both the doctor and the readiness probe must carry it"; return
  fi
  # 3 — the doctor's input-reference header is the app's, colon and all. It is
  #     the half of the golden block that carried the falsehood.
  if ! grep -qF "$refhdr" "$SCRIPT"; then
    fail_case "$name" "the doctor's input-reference header is not the app's"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

if [ -z "$ONLY" ] || case " $ONLY " in *" golden-wire-text-is-frozen "*) true ;; *) false ;; esac; then
  run_golden_wire_case
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

if [ -z "$ONLY" ] || case " $ONLY " in *" menu-hub-returns-and-leaks-nothing "*) true ;; *) false ;; esac; then
  run_menu_hub_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" menu-action-runs-with-its-own-exit-trap "*) true ;; *) false ;; esac; then
  run_menu_trap_rearm_case
fi

# Unconditional on purpose — this is the one family whose selection its own runner
# owns, because a dozen sub-case names plus the umbrella selector do not fit the
# one-name-per-block pattern. run_prompt_controls_cases returns immediately when
# nothing in the family was asked for, and does not pay for the lift.
run_prompt_controls_cases

if [ -z "$ONLY" ] || case " $ONLY " in *" quick-tunnel-reach-is-not-a-question "*) true ;; *) false ;; esac; then
  run_scope_quick_tunnel_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" a-pasted-credential-is-named-at-the-prompt-that-refused-it "*) true ;; *) false ;; esac; then
  run_secret_shape_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" custom-review-back-corrects-port "*) true ;; *) false ;; esac; then
  run_custom_review_back_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" custom-name-q-declined-stops-the-run "*) true ;; *) false ;; esac; then
  run_custom_name_q_case declined
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" custom-name-q-confirmed-is-the-name "*) true ;; *) false ;; esac; then
  run_custom_name_q_case confirmed
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

if [ -z "$ONLY" ] || case " $ONLY " in *" manage-surface-machine-contract "*) true ;; *) false ;; esac; then
  run_manage_surface_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" manage-forget-bad-id-refused-on-a-terminal "*) true ;; *) false ;; esac; then
  run_manage_forget_pty_id_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" manage-forget-confirmation-honours-its-keys "*) true ;; *) false ;; esac; then
  run_manage_forget_prompt_controls_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" manage-forget-discloses-unreadable-exposures "*) true ;; *) false ;; esac; then
  run_manage_forget_exposure_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" manage-forget-closes-a-pruned-exposure "*) true ;; *) false ;; esac; then
  run_manage_forget_pruned_exposure_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" manage-edit-survives-showing-a-setup-code "*) true ;; *) false ;; esac; then
  run_manage_show_code_state_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" manage-edit-reports-a-save-that-did-not-land "*) true ;; *) false ;; esac; then
  run_manage_save_must_land_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" manage-list-survives-a-missing-home "*) true ;; *) false ;; esac; then
  run_manage_missing_home_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" manage-list-renders-untrusted-names "*) true ;; *) false ;; esac; then
  run_manage_untrusted_names_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" manage-list-token-row-is-per-kind "*) true ;; *) false ;; esac; then
  run_manage_token_row_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" manage-refuses-before-it-reads-anything "*) true ;; *) false ;; esac; then
  run_manage_headless_refusals_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" manage-edit-confirms-a-tailscale-address-mismatch "*) true ;; *) false ;; esac; then
  run_manage_edit_tailscale_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" manage-edit-model-question-fits-the-setup "*) true ;; *) false ;; esac; then
  run_manage_edit_model_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" manage-edit-model-roster-check "*) true ;; *) false ;; esac; then
  run_manage_edit_model_roster_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" manage-edit-model-gates-only-an-answered-roster "*) true ;; *) false ;; esac; then
  run_manage_edit_model_gate_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" manage-edit-loads-a-unit-only-credential "*) true ;; *) false ;; esac; then
  run_manage_edit_unit_credential_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" cli-modifier-matrix "*) true ;; *) false ;; esac; then
  run_cli_matrix_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" reuse-only-is-refused-before-anything-is-asked "*) true ;; *) false ;; esac; then
  run_manage_reuse_only_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" manage-surface-prints-no-secret "*) true ;; *) false ;; esac; then
  run_manage_no_secret_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" retired-words-stay-retired "*) true ;; *) false ;; esac; then
  run_terminology_lint_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" retired-gateway-claim-does-not-come-back "*) true ;; *) false ;; esac; then
  run_retired_gateway_claim_case
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

if [ -z "$ONLY" ] || case " $ONLY " in *" hermes-key-lands-in-a-0600-file "*) true ;; *) false ;; esac; then
  run_hermes_key_lands_in_private_file_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" chat-content-type-is-sanitised "*) true ;; *) false ;; esac; then
  run_chat_content_type_is_sanitised_case
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

if [ -z "$ONLY" ] || case " $ONLY " in *" probe-grader "*) true ;; *) false ;; esac; then
  run_probe_grader_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" probe-near-verdict "*) true ;; *) false ;; esac; then
  run_probe_near_verdict_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" probe-font-mirror "*) true ;; *) false ;; esac; then
  run_probe_font_mirror_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" image-gate-blocks-only-the-silent-drop "*) true ;; *) false ;; esac; then
  run_image_gate_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" image-gate-runs-between-the-chat-turn-and-the-file-lane "*) true ;; *) false ;; esac; then
  run_image_gate_placement_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" image-gate-question-explains-itself "*) true ;; *) false ;; esac; then
  run_image_gate_explanation_case
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
