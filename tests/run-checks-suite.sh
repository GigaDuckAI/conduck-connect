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
ALL_IDS="AUTH_CHAT_MISSING AUTH_CHAT_WRONG AUTH_MODELS_MISSING AUTH_MODELS_WRONG CHAT_BASIC HISTORY_IMAGE IMAGE_INPUT MODELS_ENVELOPE MODEL_SELECTION STREAM_SYNC"
BASIC_IDS="AUTH_CHAT_MISSING AUTH_CHAT_WRONG AUTH_MODELS_MISSING AUTH_MODELS_WRONG CHAT_BASIC HISTORY_IMAGE MODELS_ENVELOPE MODEL_SELECTION STREAM_SYNC"
# The complete green file-lane inventory on a fully-conformant --files run — the
# ids appended to the core inventory when a pass case carries --files.
FILE_IDS="FILES_CONFIG FILES_WRITE_THROUGH FILES_AUTH_READ_MISSING FILES_AUTH_READ_WRONG FILES_AUTH_WRITE_MISSING FILES_AUTH_WRITE_WRONG FILES_READ_FRESH FILES_PROBE_COMPAT FILES_NESTED FILE_COPY_BYTES FILE_REPLY_REFERENCE FILE_E2E FILES_DELETE"

# The frozen schema=3 grammar — field order fixed; any change must bump schema=
# (and this regex, and the freeze doc). The three file meters are NOT_REQUESTED
# without --files; with it, each grades NOT_RUN|PASS|FAIL|ERROR independently.
FMETER='(NOT_REQUESTED|NOT_RUN|PASS|FAIL|ERROR)'
SUMMARY_RE='^CONDUCK_CHECK_ADAPTER schema=3 contract=v1 revision=1\.3 harness=[0-9][0-9.]* profile=(basic|deep) core=(PASS|FAIL|NOT_RUN) history_image=(PASS|FAIL|NOT_RUN) stream=(PASS|FAIL|NOT_RUN) image_input=(VERIFIED|DECLINED|UNVERIFIED|FAIL|NOT_RUN) file_transport='$FMETER' file_access='$FMETER' file_e2e='$FMETER' checks=[0-9]+ failed=[0-9]+ exit=[0-9]+$'

# Retired summary prefixes. The schema bump renamed CONDUCK_DOCTOR ->
# CONDUCK_CHECK_ADAPTER and CONDUCK_COMPAT -> CONDUCK_CHECK_SERVER; consumers read
# `tail -1`, so a transitional dual emission would silently hand them the WRONG
# line. Exactly one summary line, under the new prefix only.
RETIRED_SUMMARY_RE='^(CONDUCK_DOCTOR|CONDUCK_COMPAT)'
ESC=$(printf '\033')

# Case table: name|fixture-mode|adapter-args|keyless|expected-exit|expected-failed-ids(comma)|required summary fragments(space-sep)
# expected-failed-ids "-" = none. keyless=yes runs the adapter check WITHOUT a token
# (answering the hidden prompt with Enter) against the fixture's open mode.
CASES='
good|good|--deep|no|0|-|profile=deep core=PASS history_image=PASS stream=PASS image_input=VERIFIED file_transport=NOT_REQUESTED file_access=NOT_REQUESTED file_e2e=NOT_REQUESTED exit=0
good-basic|good||no|0|-|profile=basic core=PASS history_image=PASS stream=PASS image_input=NOT_RUN checks=9 failed=0 exit=0
direct-check-adapter|good||no|0|-|profile=basic core=PASS checks=9 failed=0 exit=0
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
models-bare-array|models-bare-array|--deep|no|1|MODELS_ENVELOPE|core=FAIL history_image=NOT_RUN stream=NOT_RUN image_input=NOT_RUN checks=1 failed=1 exit=1
models-html|models-html|--deep|no|1|MODELS_ENVELOPE|core=FAIL history_image=NOT_RUN exit=1
models-empty-data|models-empty-data|--deep|no|1|MODELS_ENVELOPE|core=FAIL history_image=PASS stream=PASS exit=1
models-no-id|models-no-id|--deep|no|1|MODELS_ENVELOPE|core=FAIL exit=1
models-slow|models-slow|--deep|no|1|MODELS_ENVELOPE|core=FAIL exit=1
wrong-content-type-models|wrong-content-type-models|--deep|no|1|MODELS_ENVELOPE|core=FAIL exit=1
require-model|require-model|--deep|no|1|CHAT_BASIC,HISTORY_IMAGE,IMAGE_INPUT,STREAM_SYNC|history_image=FAIL stream=FAIL image_input=FAIL exit=1
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
start_fixture() { # start_fixture <mode> -> sets FIXTURE_PID + PORT
  local mode="$1" i line
  : > "$TMP/fixture.out"
  CONDUCK_TOKEN="$TOKEN" env ${ADAPTER_FILES_DIR:+CONDUCK_FILES_DIR="$ADAPTER_FILES_DIR"} \
    python3 "$FIXTURE" --mode "$mode" --port 0 \
    > "$TMP/fixture.out" 2>"$TMP/fixture.err" &
  FIXTURE_PID=$!
  PORT=""
  i=0
  while [ "$i" -lt 100 ]; do
    line=$(head -n 1 "$TMP/fixture.out" 2>/dev/null)
    case "$line" in READY\ *) PORT="${line#READY }"; break ;; esac
    kill -0 "$FIXTURE_PID" 2>/dev/null || break
    i=$((i+1)); sleep 0.1
  done
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
  while [ "$i" -lt 100 ]; do
    line=$(head -n 1 "$TMP/webdav.out" 2>/dev/null)
    case "$line" in READY\ *) WPORT="${line#READY }"; break ;; esac
    kill -0 "$WEBDAV_PID" 2>/dev/null || break
    i=$((i+1)); sleep 0.1
  done
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
  case "$name" in
    *redirect-*)
      if ! grep -qF 'final server URL directly' "$TMP/doctor.out"; then
        fail_case "$name" "redirect failure omitted the direct-final-URL hint"; return
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
  # EOF intentionally stops at the first required local-port answer. Reaching
  # Step 2 proves --setup bypassed the welcome menu; no network request or
  # mutation occurs.
  printf '3\n' | TERM=dumb bash "$SCRIPT" --setup --dry-run \
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
  PTY_ENV=()
  pty_run 10 $'q\n' > "$TMP/doctor.out" 2>&1 || rc=$?
  if [ "$rc" != "0" ] ||
     ! grep -qF 'Welcome to Conduck Connect' "$TMP/doctor.out" ||
     ! grep -qF 'Nothing changed.' "$TMP/doctor.out"; then
    fail_case "$name" "q did not exit the PTY menu cleanly"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

run_menu_setup_case() {
  local name="menu-action-1-setup" rc=0
  # 1 = setup, 3 = another server, Enter = default name, n = local,
  # Enter = invalid blank port and a deliberate clean stop.
  PTY_ENV=()
  pty_run 10 $'1\n3\n\nn\n\n' > "$TMP/doctor.out" 2>&1 || rc=$?
  if [ "$rc" = "0" ] ||
     ! grep -qF 'Step 1 — find your gateway' "$TMP/doctor.out" ||
     ! grep -qF 'Step 2 — your OpenAI-compatible server' "$TMP/doctor.out" ||
     ! grep -qF 'Need the local port (or an https URL).' "$TMP/doctor.out"; then
    fail_case "$name" "menu option 1 did not enter setup"; return
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
  pty_run 10 $'\n3\n\nn\n\n' --setup > "$TMP/doctor.out" 2>&1 || rc=$?
  if [ "$rc" = "0" ] ||
     ! grep -qF 'We found these on this machine: openclaw' "$TMP/doctor.out" ||
     ! grep -qF 'Please enter one of the listed options.' "$TMP/doctor.out" ||
     ! grep -qF 'Step 2 — your OpenAI-compatible server' "$TMP/doctor.out"; then
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

run_profile_selfsigned_file_pin_case() {
  local name="profile-selfsigned-file-pin-gate" rc=0 state="$TMP/selfsigned-pin-state"
  local fp="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  mkdir -p "$state/conduck"

  # A different file authority presents an independent certificate. Without
  # fileServer.certFP the loader would incorrectly reuse the gateway's pin.
  printf '{"schemaVersion":1,"gateway":{"id":"custom-pin","kind":"custom","name":"Pinned","auth":"none","transport":"selfsigned","reach":"private","url":"https://gateway.example.test:8443","certFP":"%s"},"fileServer":{"url":"https://files.example.test:9443","reach":"private"}}\n' \
    "$fp" > "$state/conduck/profile-missing-file-pin.json"
  PTY_ENV=(XDG_CONFIG_HOME="$state")
  pty_run 10 $'4\n' > "$TMP/doctor.out" 2>&1 || rc=$?
  if [ "$rc" = "0" ] ||
     grep -qF '4) Show a saved setup code' "$TMP/doctor.out" ||
     grep -qF 'Re-show your pairing code' "$TMP/doctor.out"; then
    fail_case "$name" "a different self-signed file authority without its own pin was advertised"; return
  fi

  # Shared authority is the intentional legacy/writer fallback: both routes
  # present the same certificate, so omitting fileServer.certFP is valid.
  state="$TMP/selfsigned-shared-state"
  mkdir -p "$state/conduck"
  printf '{"schemaVersion":1,"gateway":{"id":"custom-shared-pin","kind":"custom","name":"Shared pin","auth":"none","transport":"selfsigned","reach":"private","url":"https://shared.example.test:8443/gateway","certFP":"%s"},"fileServer":{"url":"https://shared.example.test:8443/files","reach":"private"}}\n' \
    "$fp" > "$state/conduck/profile-shared-pin.json"
  rc=0
  PTY_ENV=(XDG_CONFIG_HOME="$state")
  pty_run 10 $'q\n' > "$TMP/doctor.out" 2>&1 || rc=$?
  if [ "$rc" != "0" ] ||
     ! grep -qF '4) Show a saved setup code' "$TMP/doctor.out"; then
    fail_case "$name" "a valid shared-authority self-signed profile was hidden"; return
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
STATE_DIR="$STATE"
GW_ID="custom-secret-probe"
GW_KIND="custom"
GW_NAME="Secret probe"
GW_AUTH="bearer"
GW_TOKEN="$GW_SECRET"
GW_URL="https://gw.example.test"
GW_LOCAL_PORT="8080"
GW_MODEL=""
GW_CERT_FP=""
TRANSPORT="tailscale"
SCOPE="private"
FS_URL="https://files.example.test:8443"
FS_CRED="$FS_SECRET"
FS_LOCAL_PORT="5006"
FS_CERT_FP=""
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

  writer=$(sed -n '/^write_profile()/,/^}/p' "$SCRIPT")
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
  PTY_ENV=(CONDUCK_TOKEN="$TOKEN")
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
  PTY_ENV=(CONDUCK_TOKEN="$TOKEN")
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
  local prepare_func payload_func payload
  prepare_func=$(sed -n '/^prepare_setup_from_check()/,/^}/p' "$SCRIPT")
  payload_func=$(sed -n '/^build_pairing_payload_json()/,/^}/p' "$SCRIPT")
  payload=$(FUNCS="$prepare_func
$payload_func" LONG_MODEL="$long_model" bash -c '
eval "$FUNCS"
ask() { printf "%s" "$2"; }
slug() { printf "%s" "$1" | tr "[:upper:]" "[:lower:]" | tr -cs "a-z0-9" "-"; }
ok() { :; }
note() { :; }
GW_URL="https://gateway.example.test"
GW_AUTH="bearer"
GW_TOKEN="secret"
GW_NAME=""
GW_KIND=""
GW_ID=""
GW_MODEL=""
GW_CERT_FP=""
GW_LOCAL_PORT=""
GW_HEALTH_PATH=""
TRANSPORT=""
SCOPE=""
FS_URL=""
FS_CRED=""
FS_CERT_FP=""
COMPAT_MODEL_FIELD="required"
MODELS_FIRST_ID="$LONG_MODEL"
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
GW_CERT_FP=""
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
# 0600 has to go through the same announce-then-confirm gate as any other change
# to something the user owns — a silent chmod would break the promise even though
# it touches no content. Two halves: the wiring stays on run_step, and run_step
# really does refuse to act without a yes.
run_owned_config_mode_change_case() {
  local name="owned-config-mode-change-is-announced" funcs body out
  local envf="$TMP/announce-hermes.env" mode

  # Wiring: inside configure_hermes, `chmod` on the user's .env may appear ONLY as
  # a run_step argument. A bare `chmod 600 "$envf"` would pass every behavioural
  # test below while bypassing the gate entirely.
  body=$(extract_funcs configure_hermes)
  if [ -z "$body" ]; then
    fail_case "$name" "could not extract configure_hermes from the release artifact"; return
  fi
  printf '%s\n' "$body" > "$TMP/doctor.out"
  # Line continuations are joined first: `run_step "…" \` / `  chmod 600 "$envf"`
  # is ONE statement, and a per-physical-line grep reads its second half as a bare
  # chmod. Rule on the joined text: every logical line that chmods $envf must also
  # name run_step, and there must be at least one such line.
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
    }' | grep -F 'chmod' | grep -F 'envf')
  if [ -z "$chmod_lines" ]; then
    fail_case "$name" "configure_hermes no longer tightens the .env at all"; return
  fi
  ungated=$(printf '%s\n' "$chmod_lines" | grep -vF 'run_step')
  if [ -n "$ungated" ]; then
    printf 'ungated chmod:\n%s\n' "$ungated" >> "$TMP/doctor.out"
    fail_case "$name" "configure_hermes chmods the user's .env outside run_step, bypassing the announce gate"; return
  fi

  # Behaviour: run_step must print the exact command, and must NOT run it unless
  # the answer is yes. EOF counts as no — a redirected run has nobody to ask.
  funcs=$(extract_funcs run_step mutate_guard confirm plan_add say warn note)
  if ! printf '%s\n' "$funcs" | grep -qF 'run_step()'; then
    fail_case "$name" "could not extract run_step from the release artifact"; return
  fi
  printf 'API_SERVER_KEY=sentinel\n' > "$envf"
  chmod 644 "$envf"
  out=$(FUNCS="$funcs" ENVF="$envf" bash -c '
eval "$FUNCS"
DRY_RUN=false; REUSE_ONLY=false; PLAN=(); BOLD=""; RESET=""; DIM=""; YELLOW=""
: | run_step "tighten it" chmod 600 "$ENVF"   # EOF on stdin = no answer
printf "declined-rc=%d\n" "$?"
' 2>&1) || true
  printf '%s\n' "$out" >> "$TMP/doctor.out"
  mode=$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$envf")
  if [ "$mode" != "0o644" ]; then
    fail_case "$name" "run_step changed the file mode without a yes (mode now $mode)"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF "chmod 600 $envf"; then
    fail_case "$name" "run_step did not print the exact command before asking"; return
  fi
  if ! printf '%s\n' "$out" | grep -qF 'declined-rc=1'; then
    fail_case "$name" "a declined run_step did not report failure to its caller"; return
  fi

  # And a yes really does apply it — the gate must not be a no-op in both directions.
  out=$(FUNCS="$funcs" ENVF="$envf" bash -c '
eval "$FUNCS"
DRY_RUN=false; REUSE_ONLY=false; PLAN=(); BOLD=""; RESET=""; DIM=""; YELLOW=""
printf "y\n" | run_step "tighten it" chmod 600 "$ENVF"
printf "accepted-rc=%d\n" "$?"
' 2>&1) || true
  printf '%s\n' "$out" >> "$TMP/doctor.out"
  mode=$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$envf")
  if [ "$mode" != "0o600" ]; then
    fail_case "$name" "an approved run_step did not apply the chmod (mode $mode)"; return
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

if [ -z "$ONLY" ] || case " $ONLY " in *" profile-selfsigned-file-pin-gate "*) true ;; *) false ;; esac; then
  run_profile_selfsigned_file_pin_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" profile-legacy-file-reach-fallback "*) true ;; *) false ;; esac; then
  run_profile_legacy_file_reach_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" profile-never-carries-secrets "*) true ;; *) false ;; esac; then
  run_profile_secret_exclusion_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" help-lists-public-meta-flags "*) true ;; *) false ;; esac; then
  run_help_surface_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" ci-gate-no-handoff "*) true ;; *) false ;; esac; then
  run_ci_gate_case
fi

if [ -z "$ONLY" ] || case " $ONLY " in *" no-ansi-when-redirected "*) true ;; *) false ;; esac; then
  run_no_ansi_case
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

printf '\nSUITE RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ] || exit 1
[ "$PASS" -gt 0 ] || { echo "no cases ran" >&2; exit 1; }
exit 0
