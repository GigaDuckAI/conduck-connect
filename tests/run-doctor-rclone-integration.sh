#!/usr/bin/env bash
#
# run-doctor-rclone-integration.sh — the NON-hermetic companion to the
# regression suite (run-doctor-suite.sh). It proves the doctor's --files
# freshness check against a REAL `rclone serve webdav`, not the stdlib
# fixture — the one place the actual rclone dir-cache bug can be reproduced
# end to end. It is deliberately NOT part of the suite (which must stay
# rclone-free), and a MISSING rclone is a hard exit 2, never a silent skip.
#
# Two cases, same served dir shape as the app, OS-assigned ports, a per-run
# random credential, HOME isolated so no real pairing profile is consulted:
#   default    rclone's default dir-cache-time (5m) → a file written straight
#              to disk stays invisible over WebDAV → FILES_READ_FRESH FAILs
#              (and the immediate agent-output probe → FILE_E2E FAILs): the
#              exact real-world failure the check exists to catch.
#   cache-1s   --dir-cache-time 1s → the transport tier PASSes (the direct
#              write is visible well inside the 2s freshness limit). FILE_E2E
#              still fails: the app's immediate, no-grace probe races rclone's
#              ~1s listing refresh — an honest property of the real server, not
#              a doctor defect.
#
# Assertion style mirrors the suite: exact exit code, the EXACT set of
# failed [CHECK_ID]s, the schema=2 summary grammar as the last line, and the
# required file-meter fragments.
#
#   bash Conduck/connect/tests/run-doctor-rclone-integration.sh

set -u -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../conduck-connect.sh"
FIXTURE="$HERE/fixture-adapter.py"
[ -f "$SCRIPT" ]  || { echo "missing $SCRIPT" >&2; exit 2; }
[ -f "$FIXTURE" ] || { echo "missing $FIXTURE" >&2; exit 2; }

if ! command -v rclone >/dev/null 2>&1; then
  echo "FAIL: rclone is not installed — this integration test REQUIRES a real rclone binary." >&2
  echo "      Install it (brew install rclone) and re-run. The hermetic coverage lives in" >&2
  echo "      run-doctor-suite.sh; this script deliberately does not fake rclone." >&2
  exit 2
fi

TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(24))') || exit 2
TMP=$(mktemp -d "${TMPDIR:-/tmp}/conduck-doctor-rclone.XXXXXX") || exit 2
ADAPTER_PID=""; RCLONE_PID=""
cleanup() {
  [ -n "$ADAPTER_PID" ] && kill "$ADAPTER_PID" 2>/dev/null
  [ -n "$RCLONE_PID" ] && kill "$RCLONE_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

SUMMARY_RE='^CONDUCK_DOCTOR schema=2 contract=v1 revision=1\.3 harness=[0-9][0-9.]* profile=(basic|deep) core=(PASS|FAIL|NOT_RUN) history_image=(PASS|FAIL|NOT_RUN) stream=(PASS|FAIL|NOT_RUN) image_input=(VERIFIED|DECLINED|UNVERIFIED|FAIL|NOT_RUN) file_transport=(NOT_REQUESTED|NOT_RUN|PASS|FAIL|ERROR) file_access=(NOT_REQUESTED|NOT_RUN|PASS|FAIL|ERROR) file_e2e=(NOT_REQUESTED|NOT_RUN|PASS|FAIL|ERROR) checks=[0-9]+ failed=[0-9]+ exit=[0-9]+$'

PASS=0; FAIL=0
fail_case() { FAIL=$((FAIL+1)); printf 'INTEG ✗ %s — %s\n' "$1" "$2"; sed 's/^/    | /' "$TMP/doctor.out" | tail -n 22; }

start_adapter() { # start_adapter <served> -> ADAPTER_PID + APORT
  : > "$TMP/adapter.out"
  CONDUCK_TOKEN="$TOKEN" env CONDUCK_FILES_DIR="$1" \
    python3 "$FIXTURE" --mode files-good --port 0 \
    > "$TMP/adapter.out" 2>"$TMP/adapter.err" &
  ADAPTER_PID=$!
  APORT=""; local i=0 line
  while [ "$i" -lt 100 ]; do
    line=$(head -n 1 "$TMP/adapter.out" 2>/dev/null)
    case "$line" in READY\ *) APORT="${line#READY }"; break ;; esac
    kill -0 "$ADAPTER_PID" 2>/dev/null || break
    i=$((i+1)); sleep 0.1
  done
  [ -n "$APORT" ]
}
stop_adapter() { [ -n "$ADAPTER_PID" ] && kill "$ADAPTER_PID" 2>/dev/null && wait "$ADAPTER_PID" 2>/dev/null; ADAPTER_PID=""; }

start_rclone() { # start_rclone <served> <cred> [extra rclone args…] -> RCLONE_PID + RPORT
  local served="$1" cred="$2"; shift 2
  : > "$TMP/rclone.err"
  rclone serve webdav "$served" --addr 127.0.0.1:0 --user conduck --pass "$cred" "$@" \
    > "$TMP/rclone.out" 2>"$TMP/rclone.err" &
  RCLONE_PID=$!
  RPORT=""; local i=0
  while [ "$i" -lt 100 ]; do
    RPORT=$(grep -hoE 'Server started on \[http://127\.0\.0\.1:[0-9]+' "$TMP/rclone.err" 2>/dev/null \
            | grep -oE '[0-9]+$' | head -n 1)
    [ -n "$RPORT" ] && break
    kill -0 "$RCLONE_PID" 2>/dev/null || break
    i=$((i+1)); sleep 0.1
  done
  [ -n "$RPORT" ]
}
stop_rclone() { [ -n "$RCLONE_PID" ] && kill "$RCLONE_PID" 2>/dev/null && wait "$RCLONE_PID" 2>/dev/null; RCLONE_PID=""; }

# assert_doctor <label> <rc> <expexit> <expfails-csv|-> <frags…>
assert_doctor() {
  local label="$1" rc="$2" expexit="$3" expfails="$4"; shift 4
  if [ "$rc" != "$expexit" ]; then fail_case "$label" "exit $rc, expected $expexit"; return 1; fi
  local got exp
  got=$(grep -o '✗ \[[A-Z0-9_]*\]' "$TMP/doctor.out" | sed 's/.*\[\(.*\)\]/\1/' | sort -u | tr '\n' ',' | sed 's/,$//')
  exp=$(printf '%s' "$expfails" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
  [ "$expfails" = "-" ] && exp=""
  if [ "$got" != "$exp" ]; then fail_case "$label" "failed-ID set '{$got}', expected '{$exp}'"; return 1; fi
  local summary frag
  summary=$(tail -n 1 "$TMP/doctor.out")
  if ! printf '%s\n' "$summary" | grep -Eq "$SUMMARY_RE"; then
    fail_case "$label" "last line isn't a valid schema=2 summary: $summary"; return 1
  fi
  for frag in "$@"; do
    case " $summary " in *" $frag "*) ;; *) fail_case "$label" "summary lacks '$frag': $summary"; return 1 ;; esac
  done
  return 0
}

run_rclone_case() { # run_rclone_case <label> <expexit> <expfails> <frags-space-joined> -- [rclone args…]
  local label="$1" expexit="$2" expfails="$3" frags="$4"; shift 4
  [ "${1:-}" = "--" ] && shift
  local served home cred
  served=$(mktemp -d "$TMP/served.XXXXXX") || { fail_case "$label" "mktemp served"; return; }
  home=$(mktemp -d "$TMP/home.XXXXXX") || { fail_case "$label" "mktemp home"; return; }
  cred=$(python3 -c 'import secrets; print("rc-" + secrets.token_hex(8))') || { fail_case "$label" "cred gen"; return; }

  start_adapter "$served" || { fail_case "$label" "adapter failed to start"; stop_adapter; return; }
  RCLONE_PASS="$cred" start_rclone "$served" "$cred" "$@" \
    || { fail_case "$label" "rclone serve failed to start"; stop_adapter; stop_rclone; return; }

  local rc=0
  env -u XDG_CONFIG_HOME HOME="$home" TERM=dumb CONDUCK_TOKEN="$TOKEN" \
      CONDUCK_FILES_URL="http://127.0.0.1:$RPORT" CONDUCK_FILES_DIR="$served" CONDUCK_FILES_PASS="$cred" \
      bash "$SCRIPT" --doctor "http://127.0.0.1:$APORT" --files \
      </dev/null > "$TMP/doctor.out" 2>&1 || rc=$?
  stop_adapter; stop_rclone

  assert_doctor "$label" "$rc" "$expexit" "$expfails" $frags || return
  PASS=$((PASS+1)); printf 'INTEG ✓ %s\n' "$label"
}

printf 'doctor --files rclone integration — real `rclone serve webdav`, OS-assigned ports, per-run credential\n'
printf 'rclone: %s\n' "$(rclone version | head -n 1)"

# default dir-cache-time (5m): the freshness trap. A direct-disk write stays
# 404 over WebDAV; the immediate agent-output probe sees the same → FILE_E2E.
run_rclone_case "rclone-default" 1 "FILES_READ_FRESH,FILE_E2E" \
  "core=PASS file_transport=FAIL file_access=PASS file_e2e=FAIL exit=1" --

# --dir-cache-time 1s: transport tier recovers (freshness inside 2s). FILE_E2E
# still fails — the app's immediate no-grace probe races rclone's ~1s refresh.
run_rclone_case "rclone-cache-1s" 1 "FILE_E2E" \
  "core=PASS file_transport=PASS file_access=PASS file_e2e=FAIL exit=1" -- --dir-cache-time 1s

printf '\nINTEGRATION RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ] || exit 1
[ "$PASS" -gt 0 ] || { echo "no cases ran" >&2; exit 1; }
exit 0
