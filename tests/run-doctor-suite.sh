#!/usr/bin/env bash
#
# run-doctor-suite.sh — the doctor's regression suite.
#
# For every doctor check there is a known-good fixture (must stay green) and at
# least one deliberately-broken fixture-adapter mode proving the check fails
# for its INTENDED reason. Without this, the doctor is a referee that only
# appears strict. Each case asserts:
#   1. the doctor's exit code,
#   2. the EXACT set of failed [CHECK_ID]s (nothing more, nothing less),
#   3. the machine summary line: full schema=2 grammar, last line of output,
#      required field values, and failed= consistent with the ✗ line count,
#   4. for the pass modes: the complete ✓ inventory (every check really ran).
#
# Runs everything against tests/fixture-adapter.py on an OS-assigned loopback
# port with a per-run random token. TERM=dumb keeps the doctor's output free
# of ANSI so the assertions grep plain text. Exit 0 = whole suite green.
#
#   bash Conduck/connect/tests/run-doctor-suite.sh            # whole suite
#   bash Conduck/connect/tests/run-doctor-suite.sh good sse-…  # just these cases

set -u -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../conduck-connect.sh"
FIXTURE="$HERE/fixture-adapter.py"
WEBDAV="$HERE/fixture-webdav.py"
[ -f "$SCRIPT" ] || { echo "missing $SCRIPT" >&2; exit 2; }
[ -f "$FIXTURE" ] || { echo "missing $FIXTURE" >&2; exit 2; }
[ -f "$WEBDAV" ] || { echo "missing $WEBDAV" >&2; exit 2; }

TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(24))') || exit 2
TMP=$(mktemp -d "${TMPDIR:-/tmp}/conduck-doctor-suite.XXXXXX") || exit 2
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

# The frozen schema=2 grammar — field order fixed; any change must bump schema=
# (and this regex, and the freeze doc). The three file meters are NOT_REQUESTED
# without --files; with it, each grades NOT_RUN|PASS|FAIL|ERROR independently.
FMETER='(NOT_REQUESTED|NOT_RUN|PASS|FAIL|ERROR)'
SUMMARY_RE='^CONDUCK_DOCTOR schema=2 contract=v1 revision=1\.3 harness=[0-9][0-9.]* profile=(basic|deep) core=(PASS|FAIL|NOT_RUN) history_image=(PASS|FAIL|NOT_RUN) stream=(PASS|FAIL|NOT_RUN) image_input=(VERIFIED|DECLINED|UNVERIFIED|FAIL|NOT_RUN) file_transport='$FMETER' file_access='$FMETER' file_e2e='$FMETER' checks=[0-9]+ failed=[0-9]+ exit=[0-9]+$'

# Case table: name|fixture-mode|doctor-args|keyless|expected-exit|expected-failed-ids(comma)|required summary fragments(space-sep)
# expected-failed-ids "-" = none. keyless=yes runs the doctor WITHOUT a token
# (answering the hidden prompt with Enter) against the fixture's open mode.
CASES='
good|good|--deep|no|0|-|profile=deep core=PASS history_image=PASS stream=PASS image_input=VERIFIED file_transport=NOT_REQUESTED file_access=NOT_REQUESTED file_e2e=NOT_REQUESTED exit=0
good-basic|good||no|0|-|profile=basic core=PASS history_image=PASS stream=PASS image_input=NOT_RUN checks=9 failed=0 exit=0
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

# doctor-artifact leftovers in a served dir (conduck-doctor-* / output-*), one
# per line — the post-check for the cleanup-focused file cases.
doctor_artifacts() { # doctor_artifacts <served-dir>
  find "$1" -mindepth 1 \( -name 'conduck-doctor-*' -o -name 'output-*' \) 2>/dev/null
}

PASS=0
FAIL=0
fail_case() { # fail_case <name> <why>
  FAIL=$((FAIL+1))
  printf 'SUITE ✗ %s — %s\n' "$1" "$2"
  sed 's/^/    | /' "$TMP/doctor.out" | tail -n 25
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
    printf '\n' | TERM=dumb CONDUCK_TOKEN="" bash "$SCRIPT" --doctor "http://127.0.0.1:$PORT" $args \
      > "$TMP/doctor.out" 2>&1 || rc=$?
  else
    TERM=dumb CONDUCK_TOKEN="$TOKEN" bash "$SCRIPT" --doctor "http://127.0.0.1:$PORT" $args \
      > "$TMP/doctor.out" 2>&1 < /dev/null || rc=$?
  fi
  stop_fixture

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
  # 3 — machine summary: last line, full grammar, required fragments,
  #     failed= consistent with the ✗ verdict-line count
  local summary nfail nlines frag
  summary=$(tail -n 1 "$TMP/doctor.out")
  if ! printf '%s\n' "$summary" | grep -Eq "$SUMMARY_RE"; then
    fail_case "$name" "last line isn't a valid schema=2 summary: $summary"; return
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
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# The same steps 1–4 as run_case's tail, as a reusable grader (the --files
# cases share it). Returns 0 iff every assertion held; otherwise it has already
# reported via fail_case. $args is the doctor arg string (drives the inventory).
grade_doctor() { # grade_doctor <name> <rc> <expexit> <expfails> <args> <frags>
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
  summary=$(tail -n 1 "$TMP/doctor.out")
  if ! printf '%s\n' "$summary" | grep -Eq "$SUMMARY_RE"; then
    fail_case "$name" "last line isn't a valid schema=2 summary: $summary"; return 1
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
# runs the doctor with --files against it, HOME isolated to a temp dir so no
# real pairing profile is consulted and no shared state leaks.
# name|adapter-mode|webdav-mode|env-mode|doctor-args|exp-exit|exp-fails|frags|post
#   webdav-mode "-"      = no WebDAV server (config-error cases fail before contact)
#   env-mode: full       = CONDUCK_FILES_URL(webdav)+DIR(served)+PASS(cred)
#             url-only    = only CONDUCK_FILES_URL set (partial → FILES_CONFIG)
#             home-dir    = DIR=$HOME (refused) ; none = no overrides (no profile)
#   post: - | dir-empty (served dir must hold zero doctor artifacts) | no-leak
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
  env -u XDG_CONFIG_HOME "${denv[@]}" bash "$SCRIPT" --doctor "http://127.0.0.1:$PORT" $dargs \
    </dev/null > "$TMP/doctor.out" 2>&1 || rc=$?
  stop_fixture; stop_webdav

  grade_doctor "$name" "$rc" "$expexit" "$expfails" "$dargs" "$frags" || return

  case "$post" in
    dir-empty)
      local left; left=$(doctor_artifacts "$SERVED")
      if [ -n "$left" ]; then
        fail_case "$name" "served dir still holds doctor artifacts: $(echo $left)"; return
      fi ;;
    no-leak)
      if grep -qF "$CRED" "$TMP/doctor.out"; then
        fail_case "$name" "doctor output leaked the WebDAV credential"; return
      fi
      local nonce
      nonce=$(grep -oE '[0-9a-f]{64}' "$CAPTURE" 2>/dev/null | head -n 1)
      if [ -z "$nonce" ]; then
        fail_case "$name" "no-leak: could not recover the sentinel nonce from the WebDAV capture"; return
      fi
      if grep -qF "$nonce" "$TMP/doctor.out"; then
        fail_case "$name" "doctor output leaked the sentinel content nonce"; return
      fi ;;
  esac

  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# The SIGINT-mid-turn case: interrupt the doctor during the agent file turn and
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

  # Job-control mode so the doctor gets its OWN process group: a real Ctrl-C
  # signals the whole foreground group (bash + its blocked curl child), which
  # is what makes the doctor's `trap 'exit 130' INT` fire promptly. Signalling
  # only the bash PID would leave the curl running and bash would defer the
  # trap until it returned — not a faithful Ctrl-C.
  set -m
  env -u XDG_CONFIG_HOME HOME="$CASE_HOME" TERM=dumb CONDUCK_TOKEN="$TOKEN" \
      CONDUCK_FILES_URL="http://127.0.0.1:$WPORT" CONDUCK_FILES_DIR="$SERVED" CONDUCK_FILES_PASS="$CRED" \
      bash "$SCRIPT" --doctor "http://127.0.0.1:$PORT" --files \
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
    fail_case "$name" "doctor never reached the agent file turn"
    kill "$dpid" 2>/dev/null; wait "$dpid" 2>/dev/null; stop_fixture; stop_webdav; return
  fi
  sleep 1
  kill -INT -"$dpid" 2>/dev/null    # negative pid → the doctor's process group
  local rc=0; wait "$dpid" 2>/dev/null || rc=$?
  stop_fixture; stop_webdav

  if [ "$rc" != "130" ]; then fail_case "$name" "exit $rc, expected 130 (SIGINT)"; return; fi
  local summary; summary=$(tail -n 1 "$TMP/doctor.out")
  if ! printf '%s\n' "$summary" | grep -Eq "$SUMMARY_RE"; then
    fail_case "$name" "last line isn't a valid schema=2 summary: $summary"; return
  fi
  case " $summary " in *" exit=130 "*) ;; *) fail_case "$name" "summary lacks exit=130: $summary"; return ;; esac
  local left; left=$(doctor_artifacts "$SERVED")
  if [ -n "$left" ]; then
    fail_case "$name" "SIGINT left doctor artifacts behind: $(echo $left)"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# =============================================================== --compat ====
# The compat probe (conduck-connect.sh --compat) mirrors the Conduck APP's wire
# validation — its Test Connection + reply decoder — NOT the adapter contract.
# It reuses the same fixture-adapter modes over the same loopback plumbing, so
# these cases share start_fixture/stop_fixture and the $TMP/doctor.out capture.
# Each case asserts: the doctor-parallel trio — exit code, the frozen machine
# summary (full CONDUCK_COMPAT grammar as the LAST line, required field values),
# and failed= consistent with the ✗ check-line count (the FAIL verdict line
# carries no [id], so '✗ \[' counts only genuine check failures).
#
# The frozen schema=1 grammar — field order fixed; any change must bump schema=
# (and this regex, and the harness). Mirrors how SUMMARY_RE freezes the doctor.
COMPAT_SUMMARY_RE='^CONDUCK_COMPAT schema=1 harness=[0-9][0-9.]* wire=(PASS|FAIL|NOT_RUN) models=(NOT_RUN|PASS|FAIL) chat=(NOT_RUN|PASS|FAIL) history_image=(NOT_RUN|PASS|FAIL) image_input=(VERIFIED|DECLINED|OPAQUE|IGNORED|NOT_RUN) model=(optional|required|none_advertised|NOT_RUN) model_ids=[0-9]+ auth=(bearer|none|NOT_RUN) checks=[0-9]+ failed=[0-9]+ exit=[0-9]+$'

# Case table: name|fixture-mode|keyless|expected-exit|required summary fragments(space-sep)
# keyless=yes runs the probe WITHOUT a token (an empty answer piped to stdin)
# against the fixture's open mode — the app's explicit .none auth scheme; NO
# negative-auth request is sent either way. Names are compat- prefixed so they
# never collide with the doctor case names when the positional filter is used.
#
# KNOWN DISCREPANCY — compat-require-model asserts the DESIRED contract the
# founder verified (wire=PASS model=required chat=PASS): a server that merely
# REQUIRES a model should be usable by the app, which carries the configured
# model on every turn. The probe as written only threads the discovered model
# through the two chat turns, NOT the history-image turn or the image probe —
# both send no "model" field, so require-model 400s them (history_image=FAIL,
# image_input=OPAQUE) and the real summary is wire=FAIL failed=1 exit=1. This
# row therefore FAILS today; it pins the contract until the probe carries the
# required model through those turns. Left asserting the intended outcome on
# purpose (not fudged to the buggy actual) — see the report to the founder.
COMPAT_CASES='
compat-good|good|no|0|wire=PASS models=PASS chat=PASS history_image=PASS image_input=VERIFIED model=optional model_ids=2 auth=bearer checks=4 failed=0 exit=0
compat-keyless|open|yes|0|wire=PASS auth=none exit=0
compat-sse-on-stream-true|sse-on-stream-true|no|0|wire=PASS exit=0
compat-wrong-content-type|wrong-content-type|no|0|wire=PASS exit=0
compat-wrong-content-type-models|wrong-content-type-models|no|0|wire=PASS exit=0
compat-empty-content|empty-content|no|0|wire=PASS chat=PASS image_input=IGNORED exit=0
compat-tool-calls|tool-calls|no|0|wire=PASS exit=0
compat-many-choices|many-choices|no|0|wire=PASS exit=0
compat-malformed-second-choice|malformed-second-choice|no|1|wire=FAIL chat=FAIL exit=1
compat-non-string-content|non-string-content|no|1|wire=FAIL chat=FAIL history_image=FAIL image_input=OPAQUE failed=3 exit=1
compat-reject-history-image|reject-history-image|no|1|wire=FAIL history_image=FAIL chat=PASS failed=1 exit=1
compat-text-only|text-only|no|0|wire=PASS image_input=DECLINED exit=0
compat-silent-drop-image|silent-drop-image|no|0|wire=PASS image_input=IGNORED exit=0
compat-models-bare-array|models-bare-array|no|1|wire=FAIL models=FAIL chat=NOT_RUN checks=1 failed=1 exit=1
compat-models-empty-data|models-empty-data|no|0|wire=PASS chat=PASS model_ids=0 exit=0
compat-models-no-id|models-no-id|no|0|wire=PASS model_ids=0 exit=0
compat-models-html|models-html|no|1|wire=FAIL models=FAIL chat=NOT_RUN checks=1 failed=1 exit=1
compat-models-slow|models-slow|no|1|wire=FAIL models=FAIL chat=NOT_RUN checks=1 failed=1 exit=1
compat-require-model|require-model|no|0|wire=PASS model=required chat=PASS exit=0
compat-bogus-model-200|bogus-model-200|no|0|wire=PASS exit=0
compat-bad-json|bad-json|no|1|wire=FAIL chat=FAIL exit=1
compat-sse-despite-false|sse-despite-false|no|1|wire=FAIL chat=FAIL exit=1
'

run_compat_case() { # run_compat_case <table-row>
  local name mode keyless expexit frags
  local rest="$1"
  name="${rest%%|*}"; rest="${rest#*|}"
  mode="${rest%%|*}"; rest="${rest#*|}"
  keyless="${rest%%|*}"; rest="${rest#*|}"
  expexit="${rest%%|*}"; frags="${rest#*|}"

  start_fixture "$mode" || { fail_case "$name" "fixture failed to start"; stop_fixture; return; }

  local rc=0
  if [ "$keyless" = "yes" ]; then
    printf '\n' | TERM=dumb CONDUCK_TOKEN="" bash "$SCRIPT" --compat "http://127.0.0.1:$PORT" \
      > "$TMP/doctor.out" 2>&1 || rc=$?
  else
    TERM=dumb CONDUCK_TOKEN="$TOKEN" bash "$SCRIPT" --compat "http://127.0.0.1:$PORT" \
      > "$TMP/doctor.out" 2>&1 < /dev/null || rc=$?
  fi
  stop_fixture

  # 1 — exit code (wire=PASS iff exit=0)
  if [ "$rc" != "$expexit" ]; then
    fail_case "$name" "exit $rc, expected $expexit"; return
  fi
  # 2 — machine summary: last line, full grammar, required fragments
  local summary frag
  summary=$(tail -n 1 "$TMP/doctor.out")
  if ! printf '%s\n' "$summary" | grep -Eq "$COMPAT_SUMMARY_RE"; then
    fail_case "$name" "last line isn't a valid CONDUCK_COMPAT schema=1 summary: $summary"; return
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
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

# Flag mutual-exclusion: each combination must die nonzero during arg parsing —
# BEFORE run_compat arms the compat_summary EXIT trap — so NO CONDUCK_COMPAT
# summary is ever emitted. A bare URL with neither --doctor nor --compat dies
# the same way. name|args (args word-split unquoted; empty = bare URL only).
COMPAT_EXCL_CASES='
compat-excl-doctor-compat|--doctor --compat
compat-excl-compat-deep|--compat --deep
compat-excl-compat-files|--compat --files
compat-excl-bare-url|
'

run_compat_excl_case() { # run_compat_excl_case <table-row>
  local name args rest="$1"
  name="${rest%%|*}"; args="${rest#*|}"
  local rc=0
  # Every invocation carries a bare URL: it gives the bare-url case its trigger,
  # and the flag-clash cases still die on the clash before the URL is reached.
  TERM=dumb bash "$SCRIPT" $args "https://example.com" \
    </dev/null > "$TMP/doctor.out" 2>&1 || rc=$?
  if [ "$rc" = "0" ]; then
    fail_case "$name" "expected a nonzero exit from the flag clash, got 0"; return
  fi
  if grep -q 'CONDUCK_COMPAT' "$TMP/doctor.out"; then
    fail_case "$name" "a CONDUCK_COMPAT summary leaked before the flag clash was rejected"; return
  fi
  PASS=$((PASS+1))
  printf 'SUITE ✓ %s\n' "$name"
}

ONLY="${*:-}"
printf 'doctor regression suite — fixture on 127.0.0.1 (OS-assigned port), per-run token\n'
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
  run_compat_case "$row"
done <<EOF
$COMPAT_CASES
EOF

while IFS= read -r row; do
  [ -n "$row" ] || continue
  case "$row" in \#*) continue ;; esac
  if [ -n "$ONLY" ]; then
    case " $ONLY " in *" ${row%%|*} "*) ;; *) continue ;; esac
  fi
  run_compat_excl_case "$row"
done <<EOF
$COMPAT_EXCL_CASES
EOF

printf '\nSUITE RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ] || exit 1
[ "$PASS" -gt 0 ] || { echo "no cases ran" >&2; exit 1; }
exit 0
