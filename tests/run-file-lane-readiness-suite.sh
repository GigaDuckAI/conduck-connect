#!/usr/bin/env bash
# shellcheck disable=SC2034
#
# Focused regressions for setup-time file-lane readiness. These source the
# modular implementation directly so failures point at the owning source file,
# while run-checks-suite.sh continues to exercise the assembled release.
#
# Loopback only. Nothing is installed and no real service definition is touched.
# SC2034 is file-wide because these globals are consumed by dynamically sourced
# modules; ShellCheck deliberately does not infer that cross-file use.

set -u -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT="$HERE/.."
ADAPTER="$HERE/fixture-adapter.py"
WEBDAV="$HERE/fixture-webdav.py"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/conduck-file-ready.XXXXXX") || exit 2
PORT_PID=""
ADAPTER_PID=""
WEBDAV_PID=""

cleanup() {
  [ -n "$PORT_PID" ] && kill "$PORT_PID" 2>/dev/null
  [ -n "$ADAPTER_PID" ] && kill "$ADAPTER_PID" 2>/dev/null
  [ -n "$WEBDAV_PID" ] && kill "$WEBDAV_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT HUP INT TERM

# Minimal runtime expected by the sourced modules.
BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; RESET=""
DRY_RUN=false
REUSE_ONLY=false
SHOW_QR=false
DOCTOR=false
COMPAT=false
TRANSPORT="public"
GW_AUTH="bearer"
GW_TOKEN=""
GW_MODEL=""
OS="Linux"
STATE_DIR="$TMP/state"
STATE_DIR_EXPOSURE_REPORTED=false
GW_ID="test"
GW_LOCAL_PORT=""

say()  { printf '%s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
bad()  { printf '  ✗ %s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; return 1; }
have() { command -v "$1" >/dev/null 2>&1; }
head_() { printf '\n== %s ==\n' "$*"; }
plan_add() { printf 'PLAN %s\n' "$*"; }
safe_display() { printf '%s' "$1"; }
env_get() {
  awk -F= -v key="$2" '$1 == key { sub(/^[^=]*=/, ""); value=$0 } END { print value }' "$1"
}

# Scriptable operator answers. CONFIRM_SCRIPT is a ':'-separated queue consumed
# left to right (a step that asks twice can be answered differently each time);
# CONFIRM_ANSWER is what every prompt past the queue gets. The default is "n"
# because an undefined `confirm` used to return 127 — declining by default keeps
# every pre-existing case in this suite on the path it already took.
CONFIRM_ANSWER="n"
CONFIRM_SCRIPT=""
confirm() {
  local reply="$CONFIRM_ANSWER"
  if [ -n "$CONFIRM_SCRIPT" ]; then
    reply="${CONFIRM_SCRIPT%%:*}"
    case "$CONFIRM_SCRIPT" in
      *:*) CONFIRM_SCRIPT="${CONFIRM_SCRIPT#*:}" ;;
      *)   CONFIRM_SCRIPT="" ;;
    esac
  fi
  # The marker is what the flow assertions count: "was the operator asked twice?"
  # is a question about prompts, and only a printed prompt can be counted from a
  # captured transcript.
  printf '[confirm] %s -> %s\n' "$1" "$reply"
  [ "$reply" = "y" ]
}
# The real one `die`s under --reuse-only; `die` here returns 1, so the guard has
# to return explicitly or the caller would read a refusal as permission.
mutate_guard() {
  if $REUSE_ONLY; then
    die "--reuse-only mode is on, so I won't change anything (this step would: $1)"
    return 1
  fi
  return 0
}
# Both mirror the real pair's dry-run/reuse-only arms — the restart of an approved
# config change must stay refusable, or "reuse-only changed nothing" would pass on a
# stub that quietly ran it. The operator y/N the real ones wrap is auto-accepted.
run_step() {
  local desc="$1"; shift
  if $DRY_RUN; then plan_add "RUN  $*"; return 0; fi
  mutate_guard "$desc" || return 1
  printf '[run_step] %s\n' "$desc"
  return 0
}
print_and_wait() {
  if $DRY_RUN; then plan_add "YOU RUN  $2  ($1)"; return 0; fi
  mutate_guard "$1" || return 1
  printf '[by-hand] %s\n' "$1"
  return 0
}
ask_secret() { printf '%s' "fixture-secret"; }
secure_owned_file_mode() { return 0; }

# The file-lane unit writers create $STATE_DIR through ensure_state_dir. That is
# implementation, not runtime plumbing — stubbing it would stop this suite from
# proving the writers make a 0700 state directory — so the REAL pair is lifted
# out of the utilities module rather than sourcing all of it (which would drag
# in the CLI/global state this deliberately minimal runtime replaces).
eval "$(sed -n '/^file_mode_is_open()/,/^}/p;/^ensure_state_dir()/,/^}/p' "$ROOT/src/10-utilities.inc.sh")"
declare -F ensure_state_dir >/dev/null || { echo "could not lift ensure_state_dir out of src/10-utilities.inc.sh" >&2; exit 2; }

# shellcheck source=src/40-file-lane.inc.sh
source "$ROOT/src/40-file-lane.inc.sh"
# shellcheck source=src/41-agent-file-readiness.inc.sh
source "$ROOT/src/41-agent-file-readiness.inc.sh"
# shellcheck source=src/50-verification.inc.sh
source "$ROOT/src/50-verification.inc.sh"
# shellcheck source=src/70-check-server.inc.sh
source "$ROOT/src/70-check-server.inc.sh"
# shellcheck source=src/91-show-code.inc.sh
source "$ROOT/src/91-show-code.inc.sh"
FS_UNIT_ACTIVE_IMPL=$(declare -f fs_unit_active)

# The reach of the recall step is a property of the REAL setup functions, so they
# are lifted rather than re-stated here. Sourcing all of src/20-gateway.inc.sh
# would re-initialise the GW_* globals this suite sets above (GW_ID in
# particular), which is why only these are taken. Each declare guard turns a
# rename into a loud build failure instead of a silently skipped test.
# hermes_api_server_port comes along because configure_hermes calls it.
eval "$(sed -n '/^hermes_api_server_port()/,/^}/p;/^configure_hermes()/,/^}/p;/^hermes_settings_match_url()/,/^}/p;/^hermes_recall_checked_handoff_step()/,/^}/p;/^hermes_recall_post_file_lane_step()/,/^}/p' "$ROOT/src/20-gateway.inc.sh")"
for lifted in configure_hermes hermes_api_server_port hermes_settings_match_url \
              hermes_recall_checked_handoff_step hermes_recall_post_file_lane_step; do
  declare -F "$lifted" >/dev/null \
    || { echo "could not lift $lifted out of src/20-gateway.inc.sh" >&2; exit 2; }
done
# The quick-tunnel predicate belongs to the exposure module and the file lane
# calls it rather than carrying a second host-matching rule. Lifted, never
# re-stated: a stub here would pass while the real matcher drifted underneath it.
eval "$(sed -n '/^is_quick_tunnel_url()/,/^}/p' "$ROOT/src/30-exposure.inc.sh")"
declare -F is_quick_tunnel_url >/dev/null \
  || { echo "could not lift is_quick_tunnel_url out of src/30-exposure.inc.sh" >&2; exit 2; }

# The --check-server handoff latch, at its source default: only a passing server
# check may set it, and this suite must start every case from "not attributed".
CHECK_HANDOFF_LOCAL_HERMES=false

# The focused gate test only needs the observable omission behavior; exposure
# rollback is covered by the assembled-script regression suite.
drop_file_lane() { FS_URL=""; FS_CRED=""; }

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); printf 'FILE READY ✓ %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'FILE READY ✗ %s — %s\n' "$1" "$2"; }

expect_eq() { # <name> <actual> <expected>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got '$2', expected '$3'"; fi
}
expect_true() { # <name> <command...>
  local name="$1"; shift
  if "$@"; then pass "$name"; else fail "$name" "command returned nonzero"; fi
}
expect_false() { # <name> <command...>
  local name="$1"; shift
  if "$@"; then fail "$name" "command unexpectedly succeeded"; else pass "$name"; fi
}

reset_fake_home() {
  HOME="$TMP/home-$1"
  STATE_DIR="$HOME/state"
  mkdir -p "$HOME/.config/systemd/user" "$STATE_DIR"
  FS_LOCAL_PORT=""
  FS_CRED=""
  FS_UNIT=""
  FS_FOLDER=""
  FS_CRED_LEGACY_ARGV=false
  FS_EXISTING_UNSAFE=false
  FS_PORT_START=5006
  FS_PORT_END=5105
}

write_fake_unit() { # <gateway-id> <port> <folder>
  local path="$HOME/.config/systemd/user/conduck-files-$1.service"
  printf '%s\n' \
    '[Service]' \
    "ExecStart=/usr/bin/rclone serve webdav \"$3\" --addr 127.0.0.1:$2 --user conduck --dir-cache-time 1s" \
    > "$path"
}

test_port_allocation() {
  reset_fake_home "owned"
  GW_ID="hermes"
  write_fake_unit "openclaw" 5006 "$HOME/openclaw-files"
  if ! allocate_fs_local_port; then
    fail "owned port allocation" "no port allocated"
    return
  fi
  local chosen="$FS_LOCAL_PORT"
  if [ "$chosen" = "5006" ]; then
    fail "owned port allocation" "reused another gateway's port 5006"
  else
    pass "owned port allocation"
  fi

  write_fake_unit "hermes" "$chosen" "$HOME/hermes-files"
  printf '%s\n' 'fixture-secret' > "$STATE_DIR/fileserver-hermes.cred"
  FS_LOCAL_PORT=""; FS_CRED=""; FS_UNIT=""; FS_FOLDER=""
  if existing_fs_config && [ "$FS_LOCAL_PORT" = "$chosen" ]; then
    pass "stable per-gateway port reuse"
  else
    fail "stable per-gateway port reuse" "saved port $chosen was not recovered"
  fi

  GW_ID="custom"
  FS_LOCAL_PORT=""
  if allocate_fs_local_port && [ "$FS_LOCAL_PORT" != "5006" ] \
     && [ "$FS_LOCAL_PORT" != "$chosen" ]; then
    pass "distinct port for third gateway"
  else
    fail "distinct port for third gateway" "allocator reused an owned port"
  fi
}

test_duplicate_per_gateway_port() {
  reset_fake_home "duplicate-port"
  local openclaw_unit="$HOME/.config/systemd/user/conduck-files-openclaw.service"
  local hermes_unit="$HOME/.config/systemd/user/conduck-files-hermes.service"
  write_fake_unit "openclaw" 5006 "$HOME/openclaw-files"
  write_fake_unit "hermes" 5006 "$HOME/hermes-files"
  printf '%s\n' 'openclaw-secret' > "$STATE_DIR/fileserver-openclaw.cred"
  printf '%s\n' 'hermes-secret' > "$STATE_DIR/fileserver-hermes.cred"

  GW_ID="openclaw"
  if ! existing_fs_config || [ "$FS_UNIT" != "$openclaw_unit" ]; then
    fail "duplicate-port units retain exact gateway ownership" "OpenClaw selected another unit"
    return
  fi
  GW_ID="hermes"
  FS_UNIT=""; FS_LOCAL_PORT=""; FS_FOLDER=""; FS_CRED=""
  if existing_fs_config && [ "$FS_UNIT" = "$hermes_unit" ] \
     && [ "$FS_LOCAL_PORT" = "5006" ]; then
    pass "duplicate-port units retain exact gateway ownership"
  else
    fail "duplicate-port units retain exact gateway ownership" "Hermes selected another unit"
    return
  fi

  # Model systemd reporting only OpenClaw's exact unit active. Even though the
  # stale Hermes definition names the same listener port, its own inactive
  # service must not inherit OpenClaw's readiness.
  if (
    eval "$FS_UNIT_ACTIVE_IMPL"
    have() { [ "$1" = "systemctl" ]; }
    systemctl() {
      [ "$*" = "--user is-active --quiet conduck-files-openclaw.service" ]
    }
    OS="Linux"
    FS_UNIT="$hermes_unit"
    ! fs_unit_active || exit 1
    FS_UNIT="$openclaw_unit"
    fs_unit_active
  ); then
    pass "stale duplicate-port unit cannot inherit active lane readiness"
  else
    fail "stale duplicate-port unit cannot inherit active lane readiness" "activity was not scoped to the selected unit"
  fi
}

test_prebound_port() {
  reset_fake_home "prebound"
  GW_ID="hermes"
  python3 -m http.server 5006 --bind 127.0.0.1 \
    > "$TMP/prebound.out" 2> "$TMP/prebound.err" &
  PORT_PID=$!
  sleep 0.2
  # If another local process already owns 5006, our helper exits and the port is
  # still pre-bound for the behavior under test. Never kill that other process.
  if ! kill -0 "$PORT_PID" 2>/dev/null; then
    wait "$PORT_PID" 2>/dev/null
    PORT_PID=""
  fi
  if allocate_fs_local_port && [ "$FS_LOCAL_PORT" != "5006" ]; then
    pass "live listener reserves port 5006"
  else
    fail "live listener reserves port 5006" "allocator selected the bound port"
  fi
  [ -n "$PORT_PID" ] && kill "$PORT_PID" 2>/dev/null
  PORT_PID=""
}

test_unsafe_existing_unit() {
  reset_fake_home "unsafe"
  GW_ID="hermes"
  printf '%s\n' '[Service]' 'ExecStart=/usr/bin/rclone serve webdav /tmp/no-port' \
    > "$HOME/.config/systemd/user/conduck-files-hermes.service"
  if existing_fs_config; then
    fail "unparseable existing unit fails closed" "unit unexpectedly reused"
  elif $FS_EXISTING_UNSAFE; then
    pass "unparseable existing unit fails closed"
  else
    fail "unparseable existing unit fails closed" "unsafe state was not distinguished from absence"
  fi
}

test_unsafe_cross_gateway_unit() {
  reset_fake_home "unsafe-cross"
  GW_ID="hermes"
  printf '%s\n' '[Service]' 'ExecStart=/usr/bin/rclone serve webdav /tmp/unknown-port' \
    > "$HOME/.config/systemd/user/conduck-files-openclaw.service"
  if allocate_fs_local_port; then
    fail "unparseable other-gateway unit blocks allocation" "allocator ignored a latent collision"
  elif [ -n "$FS_PORT_ALLOCATION_REASON" ]; then
    pass "unparseable other-gateway unit blocks allocation"
  else
    fail "unparseable other-gateway unit blocks allocation" "failure had no diagnostic"
  fi
}

test_structural_unit_parsing() {
  reset_fake_home "structural"
  GW_ID="hermes"
  local unit="$HOME/.config/systemd/user/conduck-files-hermes.service"
  printf '%s\n' \
    '[Service]' \
    '# ExecStart=/usr/bin/rclone serve webdav /stale --addr 127.0.0.1:5006 --user conduck' \
    "ExecStart=/usr/bin/rclone serve webdav \"$HOME/actual files\" --addr 127.0.0.1:5091 --user conduck --dir-cache-time 1s" \
    > "$unit"
  expect_eq "systemd ignores stale commented ExecStart" \
    "$(fs_unit_port "$unit" 2>/dev/null || true)" "5091"

  printf '%s\n' \
    'ExecStart=/usr/bin/rclone serve webdav /duplicate --addr 127.0.0.1:5092 --user conduck' \
    >> "$unit"
  expect_false "duplicate systemd ExecStart is refused" fs_unit_port "$unit"
  printf '%s\n' '[Service]' \
    'ExecStart=/usr/bin/rclone serve webdav /tmp/files --addr 127.0.0.1:5092 --user conduck # unsupported inline comment' \
    > "$unit"
  expect_false "systemd inline-comment form is refused" fs_unit_port "$unit"
  printf '%s\n' '[Service]' \
    'ExecStart=/usr/bin/rclone serve webdav relative/files --addr 127.0.0.1:5092 --user conduck' \
    > "$unit"
  expect_false "systemd relative served folder is refused" fs_unit_port "$unit"

  local plist="$HOME/Library/LaunchAgents/ai.gigaduck.conduck-files-hermes.plist"
  mkdir -p "$(dirname "$plist")"
  python3 - "$plist" <<'PY'
import plistlib, sys
d = {"ProgramArguments": ["/usr/bin/rclone", "serve", "webdav", "/tmp/files",
                          "--addr", "127.0.0.1:5093",
                          "--addr", "127.0.0.1:5094", "--user", "conduck"]}
plistlib.dump(d, open(sys.argv[1], "wb"))
PY
  expect_false "duplicate plist --addr/value pair is refused" fs_unit_port "$plist"
  python3 - "$plist" <<'PY'
import plistlib, sys
d = {"ProgramArguments": ["/usr/bin/rclone", "serve", "webdav", "relative/files",
                          "--addr", "127.0.0.1:5093", "--user", "conduck"]}
plistlib.dump(d, open(sys.argv[1], "wb"))
PY
  expect_false "plist relative served folder is refused" fs_unit_port "$plist"

  local ws="$HOME/folder with \"quotes\" and \\slashes" quoted
  quoted=$(fs_systemd_quote "$ws")
  printf '%s\n' '[Service]' \
    "ExecStart=\"/usr/bin/rclone\" serve webdav $quoted --addr 127.0.0.1:5095 --user conduck" \
    > "$unit"
  expect_eq "systemd workspace quoting round-trips" \
    "$(fs_unit_field "$unit" folder 2>/dev/null || true)" "$ws"
  expect_false "systemd workspace rejects dollar expansion" fs_systemd_value_safe "$HOME/\$unsafe"
  expect_false "systemd workspace rejects percent specifier" fs_systemd_value_safe "$HOME/%h"

  local env_path="$HOME/state directory/fileserver-hermes.env" env_directive
  env_directive=$(fs_systemd_envfile_path "$env_path")
  expect_eq "systemd EnvironmentFile keeps an absolute path unquoted" \
    "$env_directive" "$env_path"
  case "$env_directive" in
    \"*|*\") fail "systemd EnvironmentFile never adds shell quotes" "path was quoted" ;;
    *) pass "systemd EnvironmentFile never adds shell quotes" ;;
  esac
  expect_false "systemd EnvironmentFile rejects a relative path" \
    fs_systemd_envfile_path "relative/fileserver.env"
  expect_false "systemd EnvironmentFile rejects percent specifiers" \
    fs_systemd_envfile_path "$HOME/%h/fileserver.env"
  expect_false "systemd EnvironmentFile rejects glob metacharacters" \
    fs_systemd_envfile_path "$HOME/fileserver-*.env"
  expect_false "systemd EnvironmentFile rejects raw backslashes" \
    fs_systemd_envfile_path "$HOME/state\\directory/fileserver.env"

  local legacy_env
  legacy_env=$(fs_systemd_quote "$env_path")
  printf '%s\n' \
    '[Unit]' \
    'Description=preserve this line exactly' \
    '[Service]' \
    "EnvironmentFile=$legacy_env" \
    "ExecStart=\"/usr/bin/rclone\" serve webdav $quoted --addr 127.0.0.1:5095 --user conduck" \
    > "$unit"
  expect_eq "legacy quoted EnvironmentFile is detected narrowly" \
    "$(fs_systemd_envfile_status "$unit" "$env_path")" "legacy-quoted"
  expect_true "legacy quoted EnvironmentFile repairs atomically" \
    fs_repair_systemd_envfile_exact "$unit" "$env_path"
  expect_eq "repaired EnvironmentFile re-checks ready" \
    "$(fs_systemd_envfile_status "$unit" "$env_path")" "ready"
  if grep -Fxq "EnvironmentFile=$env_path" "$unit" \
     && grep -Fxq 'Description=preserve this line exactly' "$unit" \
     && grep -Fq "ExecStart=\"/usr/bin/rclone\" serve webdav $quoted" "$unit"; then
    pass "EnvironmentFile repair preserves the rest of the unit"
  else
    fail "EnvironmentFile repair preserves the rest of the unit" "unrelated unit content changed"
  fi
  printf '%s\n' "EnvironmentFile=$env_path" >> "$unit"
  expect_eq "duplicate EnvironmentFile refuses migration" \
    "$(fs_systemd_envfile_status "$unit" "$env_path")" "manual"

  printf '%s\n' "safe"$'\r'"injected" > "$STATE_DIR/fileserver-hermes.cred"
  if existing_fs_config; then
    fail "control-character file credential is refused" "unsafe credential was reused"
  elif $FS_EXISTING_UNSAFE; then
    pass "control-character file credential is refused"
  else
    fail "control-character file credential is refused" "unsafe state was not reported"
  fi
}

test_systemd_unit_writer() {
  if (
    reset_fake_home "writer"
    STATE_DIR="$HOME/state directory"
    GW_ID="openclaw"
    FS_CRED="writer-fixture-secret"
    FS_LOCAL_PORT="5096"
    local fake_bin="$TMP/fake-bin" ws="$HOME/workspace with spaces"
    mkdir -p "$fake_bin" "$ws"
    printf '%s\n' '#!/usr/bin/env sh' 'exit 0' > "$fake_bin/rclone"
    chmod 755 "$fake_bin/rclone"
    PATH="$fake_bin:$PATH"
    systemctl() { return 0; }
    loginctl() { printf '%s\n' 'Linger=yes'; }
    write_fs_unit_linux "$ws" >/dev/null 2>&1 || exit 1
    local unit="$HOME/.config/systemd/user/conduck-files-openclaw.service"
    grep -Fxq "EnvironmentFile=$STATE_DIR/fileserver-openclaw.env" "$unit" \
      && ! grep -Fq 'EnvironmentFile="' "$unit" \
      && [ "$(fs_systemd_envfile_status "$unit" "$STATE_DIR/fileserver-openclaw.env")" = "ready" ] \
      && ensure_existing_fs_envfile_linux >/dev/null 2>&1 \
      && printf '%s\n' 'RCLONE_PASS=drifted-fixture-secret' \
           > "$STATE_DIR/fileserver-openclaw.env" \
      && ! ensure_existing_fs_envfile_linux >/dev/null 2>&1
  ); then
    pass "Linux unit writer emits and revalidates its EnvironmentFile"
  else
    fail "Linux unit writer emits and revalidates its EnvironmentFile" "writer output was invalid or credential drift was accepted"
  fi
}

file_mode() { # file_mode <path> -> octal permission bits, portable across BSD/GNU stat
  python3 -c 'import os,stat,sys; print("%o" % stat.S_IMODE(os.stat(sys.argv[1]).st_mode))' "$1"
}

# A bare `umask` inside a writer leaks for the remainder of the process, so
# every file written LATER silently loses its group/other bits — TOOLS.md above
# all. The assertion is the process mask itself, not a resulting file mode: the
# mask is the defect, and a file-mode assertion would keep passing if the leak
# merely moved to a different writer.
test_unit_writer_umask_is_scoped() {
  if (
    reset_fake_home "umask-linux"
    GW_ID="openclaw"
    FS_CRED="umask-fixture-secret"
    FS_LOCAL_PORT="5097"
    local fake_bin="$TMP/fake-bin-umask" ws="$HOME/workspace" before after
    mkdir -p "$fake_bin" "$ws"
    printf '%s\n' '#!/usr/bin/env sh' 'exit 0' > "$fake_bin/rclone"
    chmod 755 "$fake_bin/rclone"
    PATH="$fake_bin:$PATH"
    systemctl() { return 0; }
    loginctl() { printf '%s\n' 'Linger=yes'; }
    umask 022
    before=$(umask)
    write_fs_unit_linux "$ws" >/dev/null 2>&1 || exit 1
    after=$(umask)
    [ "$before" = "$after" ] \
      && [ "$(file_mode "$STATE_DIR/fileserver-openclaw.env")" = "600" ] \
      && [ "$(file_mode "$STATE_DIR/fileserver-openclaw.cred")" = "600" ]
  ); then
    pass "Linux unit writer leaves the process umask untouched"
  else
    fail "Linux unit writer leaves the process umask untouched" "the mask leaked or a credential file is not 0600"
  fi

  # A mask governs CREATION only, so a stale world-readable file from an earlier
  # run keeps its mode while the credential is written into it. Pre-securing is
  # what closes that window.
  #
  # COVERAGE LIMIT: this asserts the END STATE only. The write-then-chmod order
  # that opens the window is not observable from the shell without instrumenting
  # the writer, so this case passes against the unfixed source too. It catches a
  # DROPPED chmod, never a reordered one — the ordering rests on review.
  if (
    reset_fake_home "umask-linux-stale"
    GW_ID="openclaw"
    FS_CRED="umask-fixture-secret"
    FS_LOCAL_PORT="5098"
    local fake_bin="$TMP/fake-bin-umask2" ws="$HOME/workspace"
    mkdir -p "$fake_bin" "$ws" "$STATE_DIR"
    printf '%s\n' '#!/usr/bin/env sh' 'exit 0' > "$fake_bin/rclone"
    chmod 755 "$fake_bin/rclone"
    PATH="$fake_bin:$PATH"
    systemctl() { return 0; }
    loginctl() { printf '%s\n' 'Linger=yes'; }
    : > "$STATE_DIR/fileserver-openclaw.env"
    : > "$STATE_DIR/fileserver-openclaw.cred"
    chmod 644 "$STATE_DIR/fileserver-openclaw.env"
    chmod 644 "$STATE_DIR/fileserver-openclaw.cred"
    write_fs_unit_linux "$ws" >/dev/null 2>&1 || exit 1
    [ "$(file_mode "$STATE_DIR/fileserver-openclaw.env")" = "600" ] \
      && [ "$(file_mode "$STATE_DIR/fileserver-openclaw.cred")" = "600" ]
  ); then
    pass "a stale world-readable credential file does not survive the write"
  else
    fail "a stale world-readable credential file does not survive the write" "a credential file kept a permissive mode"
  fi

  # The mac twin carries the credential in the plist itself, so both its mask
  # discipline and the plist mode matter.
  if (
    reset_fake_home "umask-mac"
    GW_ID="openclaw"
    FS_CRED="umask-fixture-secret"
    FS_LOCAL_PORT="5099"
    local fake_bin="$TMP/fake-bin-umask-mac" ws="$HOME/workspace" before after
    local plist="$HOME/Library/LaunchAgents/ai.gigaduck.conduck-files-openclaw.plist"
    mkdir -p "$fake_bin" "$ws" "$HOME/Library/LaunchAgents"
    printf '%s\n' '#!/usr/bin/env sh' 'exit 0' > "$fake_bin/rclone"
    chmod 755 "$fake_bin/rclone"
    PATH="$fake_bin:$PATH"
    launchctl() { return 0; }
    pmset() { printf '%s\n' ' sleep 0'; }
    umask 022
    before=$(umask)
    write_fs_unit_mac "$ws" >/dev/null 2>&1 || exit 1
    after=$(umask)
    [ "$before" = "$after" ] \
      && [ "$(file_mode "$plist")" = "600" ] \
      && [ "$(file_mode "$STATE_DIR/fileserver-openclaw.cred")" = "600" ]
  ); then
    pass "mac unit writer leaves the process umask untouched and secures its plist"
  else
    fail "mac unit writer leaves the process umask untouched and secures its plist" "the mask leaked or the plist/credential is not 0600"
  fi
}

# The guidance block is written by the wizard and READ by the agent, which runs
# as its own uid — 1000 in the standard OpenClaw container, never the wizard's.
# A block the agent cannot read installs perfectly and does nothing, so the mode
# is the assertion: a content-only check would keep passing while the block sat
# inert.
test_tools_block_is_agent_readable() {
  local ws="$TMP/tools-ws" target="$TMP/tools-ws/TOOLS.md"
  mkdir -p "$ws"
  if (
    DRY_RUN=false
    REUSE_ONLY=false
    OPENCLAW_DIR="$TMP/no-compose-here"
    confirm() { return 0; }
    umask 077
    install_conduck_tools_block "$ws" >/dev/null 2>&1 || exit 1
    [ -f "$target" ] && [ "$(file_mode "$target")" = "644" ]
  ); then
    pass "TOOLS.md is created agent-readable even under a tight umask"
  else
    fail "TOOLS.md is created agent-readable even under a tight umask" "the file is missing or is not 0644"
  fi

  # A file the operator already owns is not ours to broaden. But installing into
  # one the agent cannot read is the silent-success case, so it must refuse,
  # leave the file alone, and name the remedy instead of reporting green.
  printf '%s\n' '# my own notes' > "$target"
  chmod 600 "$target"
  if (
    DRY_RUN=false
    REUSE_ONLY=false
    OPENCLAW_DIR="$TMP/no-compose-here"
    confirm() { return 0; }
    local out
    out=$(install_conduck_tools_block "$ws" 2>&1)
    printf '%s' "$out" | grep -q 'chmod 644' \
      && ! printf '%s' "$out" | grep -q 'block installed' \
      && [ "$(file_mode "$target")" = "600" ] \
      && ! grep -q 'conduck-connect:begin' "$target"
  ); then
    pass "an unreadable existing TOOLS.md is refused unchanged, with the remedy named"
  else
    fail "an unreadable existing TOOLS.md is refused unchanged, with the remedy named" "the mode changed, the block was installed, or the remedy was not named"
  fi
}

analysis_status() {
  hermes_config_analysis "$@" | awk -F '\t' '$1 == "status" { print $2; exit }'
}

test_hermes_config() {
  local ws="$TMP/hermes-workspace" cfg="$TMP/hermes-config.yaml" real_ws
  mkdir -p "$ws"
  real_ws=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$ws")

  printf '%s\n' \
    'terminal:' \
    "  cwd: \"$TMP/wrong-root\"" \
    'platform_toolsets:' \
    '  api_server:' \
    '    - web' \
    > "$cfg"
  expect_eq "Hermes narrow config change detected" \
    "$(analysis_status "$cfg" "$ws")" "fix"
  expect_eq "Hermes narrow config change applied" \
    "$(analysis_status "$cfg" "$ws" apply)" "applied"
  expect_eq "Hermes config re-checks ready" \
    "$(analysis_status "$cfg" "$ws")" "ready"
  if grep -q '^    - web$' "$cfg" && grep -q '^    - file$' "$cfg" \
     && grep -qF "  cwd: \"$real_ws\"" "$cfg"; then
    pass "Hermes edit preserves toolsets and aligns cwd"
  else
    fail "Hermes edit preserves toolsets and aligns cwd" "unexpected edited YAML"
  fi

  printf '%s\n' \
    'terminal:' \
    '    backend: local' \
    "    cwd: \"$TMP/wrong-four-space-root\"" \
    'platform_toolsets:' \
    '    api_server: ["web"]' \
    > "$cfg"
  expect_eq "Hermes four-space direct children are detected" \
    "$(analysis_status "$cfg" "$ws")" "fix"
  expect_eq "Hermes four-space direct children apply safely" \
    "$(analysis_status "$cfg" "$ws" apply)" "applied"
  expect_eq "Hermes four-space config re-checks ready" \
    "$(analysis_status "$cfg" "$ws")" "ready"
  if [ "$(grep -c '^    cwd:' "$cfg")" = "1" ] \
     && ! grep -q '^  cwd:' "$cfg" \
     && grep -q '^    api_server: \["web", "file"\]$' "$cfg"; then
    pass "Hermes four-space edit preserves direct-child indentation"
  else
    fail "Hermes four-space edit preserves direct-child indentation" "conflicting/lossy indentation"
  fi

  printf '%s\n' \
    'terminal:' \
    '    backend: local' \
    > "$cfg"
  expect_eq "Hermes inserts missing cwd at existing four-space indent" \
    "$(analysis_status "$cfg" "$ws" apply)" "applied"
  if grep -qF "    cwd: \"$real_ws\"" "$cfg" && ! grep -q '^  cwd:' "$cfg"; then
    pass "Hermes missing cwd preserves section indentation"
  else
    fail "Hermes missing cwd preserves section indentation" "cwd inserted at conflicting indentation"
  fi

  printf '%s\n' \
    'terminal:' \
    '  nested:' \
    "    cwd: \"$ws\"" \
    > "$cfg"
  expect_eq "Hermes nested/conflicting cwd fails closed" \
    "$(analysis_status "$cfg" "$ws")" "manual"

  printf '%s\n' \
    '"terminal":' \
    "    cwd: \"$ws\"" \
    '"platform_toolsets":' \
    '    api_server: ["web"]' \
    > "$cfg"
  cp "$cfg" "$cfg.before"
  expect_eq "Hermes quoted authoritative sections fail closed" \
    "$(analysis_status "$cfg" "$ws")" "manual"
  expect_eq "Hermes quoted sections refuse direct apply" \
    "$(analysis_status "$cfg" "$ws" apply)" "manual"
  if cmp -s "$cfg" "$cfg.before"; then
    pass "Hermes quoted sections are not duplicated or mutated"
  else
    fail "Hermes quoted sections are not duplicated or mutated" "config changed"
  fi

  printf '%s\n' \
    '"\u0074erminal":' \
    "    cwd: \"$ws\"" \
    > "$cfg"
  expect_eq "Hermes escaped quoted terminal key fails closed" \
    "$(analysis_status "$cfg" "$ws")" "manual"

  printf '%s\n' \
    '---' \
    'terminal:' \
    "  cwd: \"$TMP/wrong-document-root\"" \
    > "$cfg"
  expect_eq "Hermes plain document marker remains supported" \
    "$(analysis_status "$cfg" "$ws")" "fix"

  printf '%s\n' \
    'toolsets:' \
    '- hermes-cli' \
    'agent:' \
    '  disabled_toolsets: []' \
    '  disabled_tools: null' \
    '  personalities:' \
    '    creative: A normal PyYAML-wrapped plain personality line that continues' \
    '      as ordinary prose on a deeper continuation line' \
    '      on a deeper line without becoming another mapping entry.' \
    "    pirate: 'A normal PyYAML-wrapped single-quoted personality that continues" \
    "      disabled_tools: this target-looking text remains scalar content'" \
    '    kawaii: "A normal PyYAML-wrapped double-quoted personality that continues' \
    '      disabled_toolsets: this target-looking text remains scalar content"' \
    'terminal:' \
    '  backend: local' \
    "  cwd: \"$real_ws\"" \
    '  env_passthrough: []' \
    'platform_toolsets:' \
    '  api_server:' \
    '  - web' \
    '  - memory' \
    '  - file' \
    '  cli:' \
    '  - hermes-cli' \
    '# Root-level comments after the final section remain outside its map.' \
    > "$cfg"
  expect_eq "Hermes standard PyYAML config is accepted" \
    "$(analysis_status "$cfg" "$ws")" "ready"

  printf '%s\n' \
    'toolsets:' \
    '- hermes-cli' \
    'agent:' \
    '  disabled_toolsets: []' \
    '  disabled_tools: null' \
    '  personalities:' \
    '    creative: A normal PyYAML-wrapped plain personality line that continues' \
    '      as ordinary prose on a deeper continuation line' \
    '      on a deeper line without becoming another mapping entry.' \
    "    pirate: 'A normal PyYAML-wrapped single-quoted personality that continues" \
    "      disabled_tools: this target-looking text remains scalar content'" \
    '    kawaii: "A normal PyYAML-wrapped double-quoted personality that continues' \
    '      disabled_toolsets: this target-looking text remains scalar content"' \
    'terminal:' \
    '  backend: local' \
    "  cwd: \"$TMP/wrong-pyyaml-root\"" \
    'platform_toolsets:' \
    '  api_server:' \
    '  - web' \
    '  - memory' \
    '  cli:' \
    '  - hermes-cli' \
    '# Root-level comments after the final section remain outside its map.' \
    > "$cfg"
  expect_eq "Hermes standard PyYAML config detects narrow changes" \
    "$(analysis_status "$cfg" "$ws")" "fix"
  expect_eq "Hermes standard PyYAML config applies narrow changes" \
    "$(analysis_status "$cfg" "$ws" apply)" "applied"
  expect_eq "Hermes edited PyYAML config re-checks ready" \
    "$(analysis_status "$cfg" "$ws")" "ready"
  if grep -q '^- hermes-cli$' "$cfg" \
     && grep -q '^  - file$' "$cfg" \
     && grep -qF "  cwd: \"$real_ws\"" "$cfg" \
     && grep -q 'continues$' "$cfg"; then
    pass "Hermes PyYAML edit preserves root/list/scalar layout"
  else
    fail "Hermes PyYAML edit preserves root/list/scalar layout" "standard layout changed or target edit missing"
  fi

  printf '%s\n' \
    'agent:' \
    '  disabled_tools: []' \
    '  personalities:' \
    '    creative: A plain scalar begins here and then becomes ambiguous' \
    '      disabled_tools: this colon cannot be plain continuation syntax' \
    'terminal:' \
    "  cwd: \"$ws\"" \
    > "$cfg"
  cp "$cfg" "$cfg.before"
  expect_eq "Hermes target-like plain continuation fails closed" \
    "$(analysis_status "$cfg" "$ws")" "manual"
  expect_eq "Hermes target-like plain continuation refuses direct apply" \
    "$(analysis_status "$cfg" "$ws" apply)" "manual"
  if cmp -s "$cfg" "$cfg.before"; then
    pass "Hermes target-like plain continuation is not mutated"
  else
    fail "Hermes target-like plain continuation is not mutated" "config changed"
  fi

  printf '%s\n' \
    'terminal:' \
    '  backend: local' \
    '    dangling continuation' \
    "  cwd: \"$TMP/wrong-dangling-root\"" \
    > "$cfg"
  cp "$cfg" "$cfg.before"
  expect_eq "Hermes unproved continuation fails closed" \
    "$(analysis_status "$cfg" "$ws")" "manual"
  expect_eq "Hermes unproved continuation refuses direct apply" \
    "$(analysis_status "$cfg" "$ws" apply)" "manual"
  if cmp -s "$cfg" "$cfg.before"; then
    pass "Hermes unproved continuation is not mutated"
  else
    fail "Hermes unproved continuation is not mutated" "config changed"
  fi

  printf '%s\n' \
    'terminal:' \
    '  backend: local' \
    '  - stray' \
    "  cwd: \"$TMP/wrong-stray-root\"" \
    > "$cfg"
  expect_eq "Hermes unattached indentless list fails closed" \
    "$(analysis_status "$cfg" "$ws")" "manual"

  printf '%s\n' \
    '- hermes-cli' \
    'terminal:' \
    "  cwd: \"$ws\"" \
    > "$cfg"
  expect_eq "Hermes standalone root list fails closed" \
    "$(analysis_status "$cfg" "$ws")" "manual"

  printf '%s\n' \
    'toolsets:' \
    '- name: hermes-cli' \
    'terminal:' \
    "  cwd: \"$ws\"" \
    > "$cfg"
  expect_eq "Hermes root list-of-map fails closed" \
    "$(analysis_status "$cfg" "$ws")" "manual"

  printf '%s\n' \
    'toolsets:' \
    '- *' \
    'terminal:' \
    "  cwd: \"$ws\"" \
    > "$cfg"
  cp "$cfg" "$cfg.before"
  expect_eq "Hermes lone root alias marker fails closed" \
    "$(analysis_status "$cfg" "$ws")" "manual"
  expect_eq "Hermes lone root alias marker refuses apply" \
    "$(analysis_status "$cfg" "$ws" apply)" "manual"
  if cmp -s "$cfg" "$cfg.before"; then
    pass "Hermes lone root alias marker is not mutated"
  else
    fail "Hermes lone root alias marker is not mutated" "config changed"
  fi

  printf '%s\n' \
    'toolsets:' \
    '- -' \
    'terminal:' \
    "  cwd: \"$ws\"" \
    > "$cfg"
  expect_eq "Hermes nested root sequence marker fails closed" \
    "$(analysis_status "$cfg" "$ws")" "manual"

  printf '%s\n' \
    'toolsets:' \
    '- hermes-cli' \
    '  nested: value' \
    'terminal:' \
    "  cwd: \"$ws\"" \
    > "$cfg"
  expect_eq "Hermes root scalar list continuation fails closed" \
    "$(analysis_status "$cfg" "$ws")" "manual"

  printf '%s\n' \
    'toolsets:' \
    '  nested: invalid-mixed-node' \
    '- hermes-cli' \
    'terminal:' \
    "  cwd: \"$ws\"" \
    > "$cfg"
  cp "$cfg" "$cfg.before"
  expect_eq "Hermes mixed indented and root list value fails closed" \
    "$(analysis_status "$cfg" "$ws")" "manual"
  expect_eq "Hermes mixed root value refuses apply" \
    "$(analysis_status "$cfg" "$ws" apply)" "manual"
  if cmp -s "$cfg" "$cfg.before"; then
    pass "Hermes mixed root value is not mutated"
  else
    fail "Hermes mixed root value is not mutated" "config changed"
  fi

  printf '%s\n' \
    'terminal:' \
    '  "cwd": "/quoted-target"' \
    > "$cfg"
  cp "$cfg" "$cfg.before"
  expect_eq "Hermes quoted direct target fails closed" \
    "$(analysis_status "$cfg" "$ws")" "manual"
  expect_eq "Hermes quoted direct target refuses apply" \
    "$(analysis_status "$cfg" "$ws" apply)" "manual"
  if cmp -s "$cfg" "$cfg.before"; then
    pass "Hermes quoted direct target is not mutated"
  else
    fail "Hermes quoted direct target is not mutated" "config changed"
  fi

  printf '%s\n' \
    'terminal:' \
    '  cwd : "/spaced-target"' \
    > "$cfg"
  cp "$cfg" "$cfg.before"
  expect_eq "Hermes spaced direct target fails closed" \
    "$(analysis_status "$cfg" "$ws")" "manual"
  expect_eq "Hermes spaced direct target refuses apply" \
    "$(analysis_status "$cfg" "$ws" apply)" "manual"
  if cmp -s "$cfg" "$cfg.before"; then
    pass "Hermes spaced direct target is not mutated"
  else
    fail "Hermes spaced direct target is not mutated" "config changed"
  fi

  printf '%s\n' \
    'terminal:' \
    "  cwd: \"$ws\"" \
    "  cwd: \"$TMP/duplicate-target\"" \
    > "$cfg"
  cp "$cfg" "$cfg.before"
  expect_eq "Hermes duplicate direct target fails closed" \
    "$(analysis_status "$cfg" "$ws")" "manual"
  expect_eq "Hermes duplicate direct target refuses apply" \
    "$(analysis_status "$cfg" "$ws" apply)" "manual"
  if cmp -s "$cfg" "$cfg.before"; then
    pass "Hermes duplicate direct target is not mutated"
  else
    fail "Hermes duplicate direct target is not mutated" "config changed"
  fi

  printf '%s\n' \
    'agent:' \
    '  disabled_tools:' \
    '  - read_file' \
    'terminal:' \
    "  cwd: \"$ws\"" \
    > "$cfg"
  expect_eq "Hermes indentless global file disable fails closed" \
    "$(analysis_status "$cfg" "$ws")" "manual"

  printf '%s\n' \
    'agent:' \
    '  personalities:' \
    '    creative: "an unclosed generated scalar' \
    '      still has no closing quote' \
    'terminal:' \
    "  cwd: \"$ws\"" \
    > "$cfg"
  expect_eq "Hermes unclosed multiline scalar fails closed" \
    "$(analysis_status "$cfg" "$ws")" "manual"

  printf '%s\n' \
    'agent:' \
    '  personalities:' \
    "    creative: 'an unclosed generated scalar" \
    '      still has no closing quote' \
    'terminal:' \
    "  cwd: \"$ws\"" \
    > "$cfg"
  expect_eq "Hermes unclosed multiline single-quoted scalar fails closed" \
    "$(analysis_status "$cfg" "$ws")" "manual"

  printf '%s\n' \
    "{\"terminal\":{\"cwd\":\"$ws\"},\"platform_toolsets\":{\"api_server\":[\"web\"]}}" \
    > "$cfg"
  cp "$cfg" "$cfg.before"
  expect_eq "Hermes top-level flow JSON fails closed" \
    "$(analysis_status "$cfg" "$ws")" "manual"
  expect_eq "Hermes top-level flow JSON refuses direct apply" \
    "$(analysis_status "$cfg" "$ws" apply)" "manual"
  if cmp -s "$cfg" "$cfg.before"; then
    pass "Hermes top-level flow JSON is not duplicated or mutated"
  else
    fail "Hermes top-level flow JSON is not duplicated or mutated" "config changed"
  fi

  printf '%s\n' \
    "!!map {\"terminal\":{\"cwd\":\"$ws\"},\"platform_toolsets\":{\"api_server\":[\"web\"]}}" \
    > "$cfg"
  cp "$cfg" "$cfg.before"
  expect_eq "Hermes tagged document root fails closed" \
    "$(analysis_status "$cfg" "$ws")" "manual"
  expect_eq "Hermes tagged document root refuses direct apply" \
    "$(analysis_status "$cfg" "$ws" apply)" "manual"
  if cmp -s "$cfg" "$cfg.before"; then
    pass "Hermes tagged document root is not duplicated or mutated"
  else
    fail "Hermes tagged document root is not duplicated or mutated" "config changed"
  fi

  printf '%s\n' \
    '? terminal' \
    ':' \
    "  cwd: \"$ws\"" \
    '? platform_toolsets' \
    ':' \
    '  api_server: ["web"]' \
    > "$cfg"
  cp "$cfg" "$cfg.before"
  expect_eq "Hermes explicit mapping keys fail closed" \
    "$(analysis_status "$cfg" "$ws")" "manual"
  expect_eq "Hermes explicit mapping keys refuse direct apply" \
    "$(analysis_status "$cfg" "$ws" apply)" "manual"
  if cmp -s "$cfg" "$cfg.before"; then
    pass "Hermes explicit mapping keys are not duplicated or mutated"
  else
    fail "Hermes explicit mapping keys are not duplicated or mutated" "config changed"
  fi

  printf '%s\n' \
    'terminal :' \
    "    cwd: \"$ws\"" \
    'platform_toolsets :' \
    '    api_server: ["web"]' \
    > "$cfg"
  cp "$cfg" "$cfg.before"
  expect_eq "Hermes spaced authoritative keys fail closed" \
    "$(analysis_status "$cfg" "$ws")" "manual"
  expect_eq "Hermes spaced keys refuse direct apply" \
    "$(analysis_status "$cfg" "$ws" apply)" "manual"
  if cmp -s "$cfg" "$cfg.before"; then
    pass "Hermes spaced keys are not duplicated or mutated"
  else
    fail "Hermes spaced keys are not duplicated or mutated" "config changed"
  fi

  printf '%s\n' \
    'defaults: &defaults' \
    '  platform_toolsets:' \
    '    api_server: ["web"]' \
    '<<: *defaults' \
    'terminal:' \
    "  cwd: \"$ws\"" \
    > "$cfg"
  cp "$cfg" "$cfg.before"
  expect_eq "Hermes YAML anchor/merge semantics fail closed" \
    "$(analysis_status "$cfg" "$ws")" "manual"
  expect_eq "Hermes YAML anchor/merge refuses direct apply" \
    "$(analysis_status "$cfg" "$ws" apply)" "manual"
  if cmp -s "$cfg" "$cfg.before"; then
    pass "Hermes YAML anchor/merge config is not mutated"
  else
    fail "Hermes YAML anchor/merge config is not mutated" "config changed"
  fi

  printf '%s\n' \
    'terminal:' \
    '    extra: value' \
    "  cwd: \"$ws\"" \
    'platform_toolsets:' \
    '    extra: value' \
    '  api_server: ["web"]' \
    > "$cfg"
  cp "$cfg" "$cfg.before"
  expect_eq "Hermes mixed direct-map indentation fails closed" \
    "$(analysis_status "$cfg" "$ws")" "manual"
  expect_eq "Hermes mixed indentation refuses direct apply" \
    "$(analysis_status "$cfg" "$ws" apply)" "manual"
  if cmp -s "$cfg" "$cfg.before"; then
    pass "Hermes mixed indentation is not mutated"
  else
    fail "Hermes mixed indentation is not mutated" "config changed"
  fi

  printf '%s\n' \
    'terminal:' \
    '  backend: docker' \
    "  cwd: \"$ws\"" \
    > "$cfg"
  expect_eq "Hermes non-local backend requires manual mapping" \
    "$(analysis_status "$cfg" "$ws")" "manual"

  printf '%s\n' \
    'terminal:' \
    "  cwd: \"$ws\"" \
    'agent:' \
    '  disabled_tools:' \
    '    - read_file' \
    > "$cfg"
  expect_eq "Hermes global file disable is not silently widened" \
    "$(analysis_status "$cfg" "$ws")" "manual"

  local hash_ws="$TMP/hermes # workspace" qws
  mkdir -p "$hash_ws"
  qws=$(python3 -c 'import json,os,sys; print(json.dumps(os.path.realpath(sys.argv[1])))' "$hash_ws")
  printf '%s\n' \
    'terminal:' \
    "  cwd: $qws # outside comment" \
    'platform_toolsets:' \
    '  api_server: ["web,search", "quote\"tool", "hash # tool"] # outside comment' \
    > "$cfg"
  expect_eq "Hermes quoted comma/escape/hash array is parsed safely" \
    "$(analysis_status "$cfg" "$hash_ws")" "fix"
  expect_eq "Hermes complex JSON string array applies safely" \
    "$(analysis_status "$cfg" "$hash_ws" apply)" "applied"
  expect_eq "Hermes complex JSON string array preserves ready semantics" \
    "$(analysis_status "$cfg" "$hash_ws")" "ready"
  if python3 - "$cfg" <<'PY'
import json, sys
line = next(x for x in open(sys.argv[1]) if x.strip().startswith("api_server:"))
vals = json.loads(line.split(":", 1)[1].strip())
raise SystemExit(0 if vals == ["web,search", 'quote"tool', "hash # tool", "file"] else 1)
PY
  then
    pass "Hermes JSON array values survive canonical rewrite"
  else
    fail "Hermes JSON array values survive canonical rewrite" "comma/escape/hash value changed"
  fi

  printf '%s\n' 'terminal:' '  cwd: null' > "$cfg"
  expect_eq "Hermes null scalar fails closed" \
    "$(analysis_status "$cfg" "$ws")" "manual"
  printf '%s\n' 'terminal:' "  cwd: '$ws'" > "$cfg"
  expect_eq "Hermes single-quoted scalar fails closed" \
    "$(analysis_status "$cfg" "$ws")" "manual"
  printf '%s\n' \
    'terminal:' \
    "  cwd: \"$ws\"" \
    'platform_toolsets:' \
    "  api_server: ['web', 'file']" \
    > "$cfg"
  expect_eq "Hermes single-quoted inline list fails closed" \
    "$(analysis_status "$cfg" "$ws")" "manual"
  printf '%s\n' \
    'terminal:' \
    "  cwd: \"$ws\"" \
    'platform_toolsets:' \
    '  api_server: null' \
    > "$cfg"
  expect_eq "Hermes null toolset list fails closed" \
    "$(analysis_status "$cfg" "$ws")" "manual"
}

test_hermes_guidance() {
  local ws="$TMP/guidance" target state
  mkdir -p "$ws"
  target=$(hermes_guidance_target "$ws")
  expect_eq "Hermes verified bootstrap target" "$target" "$ws/HERMES.md"
  state=$(hermes_guidance_edit "$target" check)
  expect_eq "Hermes guidance absence detected" "$state" "missing"
  state=$(hermes_guidance_edit "$target" apply)
  expect_eq "Hermes guidance applied atomically" "$state" "applied"
  state=$(hermes_guidance_edit "$target" check)
  expect_eq "Hermes guidance re-checks ready" "$state" "ready"

  local lower="$TMP/lower-context"
  mkdir -p "$lower"
  printf '%s\n' '# existing agent policy' > "$lower/AGENTS.md"
  expect_false "Hermes context precedence fails closed" hermes_guidance_target "$lower"

  printf '%s\n' '<!-- conduck-connect:begin -->' 'broken' > "$ws/.hermes.md"
  expect_eq "Malformed Hermes marker is refused" \
    "$(hermes_guidance_edit "$ws/.hermes.md" check)" "malformed"
}

# --- Hermes API-server recall scope -------------------------------------------
# One key, `platform_toolsets.api_server`, decides whether the gateway keeps a
# conversation memory of its own: Hermes's default api_server bundle carries
# `memory` and `session_search`, so a config nobody has narrowed is stateful. That
# contradicts Conduck's client-owned history and bills the user for context it
# already replayed — and NO request/response check can detect it, because a
# remembering gateway answers every probe correctly. The classifier below is the
# only thing standing between a user and that silent state, so its four states,
# its refusal to guess, and the reach of the step that reports it are all pinned.
recall_field() { # <config> <recall|recall_fix|recall_scope|recall_after>
  hermes_config_analysis "$1" "" recall | awk -F '\t' -v k="$2" '$1 == k { print $2; exit }'
}
recall_items() { # <config> -> "memory,session_search," in file order
  hermes_config_analysis "$1" "" recall | awk -F '\t' '$1 == "recall_item" { printf "%s,", $2 }'
}
apply_status() { # <config> <workspace> <action> [approved-scope]
  hermes_config_analysis "$@" | awk -F '\t' '$1 == "status" { print $2; exit }'
}

# Every latch module 41 keeps is per-RUN, so each flow case has to start from a
# fresh run or it would inherit the previous case's answer.
reset_recall_run() {
  HERMES_RECALL_REPORTED=false
  HERMES_RECALL_DECLINED=false
  HERMES_SCOPE_CHANGED_THIS_RUN=false
  HERMES_CONFIG_CHANGED_THIS_RUN=false
  HERMES_GUIDANCE_CHANGED_THIS_RUN=false
  HERMES_RESIDUAL_REPORTED=false
  CONFIRM_SCRIPT=""
  CONFIRM_ANSWER="n"
  DRY_RUN=false
  REUSE_ONLY=false
  GW_KIND="hermes"
  CHECK_HANDOFF_LOCAL_HERMES=false
}

recall_home() { # <tag> — a fresh $HOME whose ~/.hermes looks like a working install
  HOME="$TMP/recall-home-$1"
  rm -rf "$HOME"
  mkdir -p "$HOME/.hermes"
  printf '%s\n' \
    'API_SERVER_ENABLED=true' \
    'API_SERVER_PORT=8642' \
    'API_SERVER_KEY=fixture-api-server-key' \
    > "$HOME/.hermes/.env"
}

# Ordinary formatting — a trailing comment, a separator, trailing whitespace on
# a blank line — cost Hermes its whole file lane, and none of it is reachable
# from tidy fixtures, which is exactly why it survived. The POSITIVE cases carry
# the stock config's own shapes. The NEGATIVE gates matter just as much: this
# scanner backs a fail-closed decision, so a loosening past the intended one is
# the real hazard, and these pin the refusals that must survive the fix.
test_hermes_blank_and_comment_lines() {
  local ws="$TMP/hermes-ws-blank" cfg="$TMP/hermes-blank.yaml"
  mkdir -p "$ws"

  # A value carrying a trailing comment puts the scanner into plain-continuation
  # mode; a comment can never continue a plain scalar (YAML 1.2 §7.3.3), so the
  # column-0 separator that follows must close it rather than fail the file.
  printf '%s\n' \
    'terminal:' \
    "  cwd: \"$TMP/wrong-root\"" \
    '  container_persistent: true    # Persist filesystem across sessions' \
    '# ---' \
    'platform_toolsets:' \
    '  api_server:' \
    '    - web' \
    > "$cfg"
  expect_eq "Hermes column-0 comment after an inline-commented value" \
    "$(analysis_status "$cfg" "$ws")" "fix"

  # A "blank" line that actually holds spaces is blank, not a child at indent 2.
  printf '%s\n' \
    'terminal:' \
    "  cwd: \"$TMP/wrong-root\"" \
    '  ' \
    'platform_toolsets:' \
    '  api_server:' \
    '    - web' \
    > "$cfg"
  expect_eq "Hermes space-only line inside a scanned section" \
    "$(analysis_status "$cfg" "$ws")" "fix"

  # Same defect one layer up: in the root-form scan a space-only line after an
  # indentless sequence item declared the WHOLE document unsupported, which is a
  # harder failure than one ambiguous section.
  printf '%s\n' \
    'toolsets:' \
    '- hermes-cli' \
    '  ' \
    'terminal:' \
    "  cwd: \"$TMP/wrong-root\"" \
    'platform_toolsets:' \
    '  api_server:' \
    '    - web' \
    > "$cfg"
  expect_eq "Hermes space-only line after an indentless root sequence" \
    "$(analysis_status "$cfg" "$ws")" "fix"

  # And inside a block list, where the same line reached the not-an-item refusal.
  printf '%s\n' \
    'terminal:' \
    "  cwd: \"$TMP/wrong-root\"" \
    'platform_toolsets:' \
    '  api_server:' \
    '    - web' \
    '  ' \
    > "$cfg"
  expect_eq "Hermes space-only line inside a block sequence" \
    "$(analysis_status "$cfg" "$ws")" "fix"

  # All of it at once, shaped like the stock config rather than copying that
  # third-party file into this repo.
  printf '%s\n' \
    '# Hermes configuration' \
    'toolsets:' \
    '- hermes-cli' \
    '  ' \
    '# ---' \
    'terminal:' \
    '  backend: local' \
    "  cwd: \"$TMP/wrong-root\"" \
    '  container_persistent: true    # Persist filesystem across sessions' \
    '' \
    '# ---' \
    'platform_toolsets:' \
    '  api_server:' \
    '    - web' \
    '  ' \
    > "$cfg"
  expect_eq "Hermes stock-shaped config with comments, separators and stray whitespace" \
    "$(analysis_status "$cfg" "$ws")" "fix"

  # NEGATIVE GATE: a tab is not YAML indentation and must keep failing closed.
  # `strip(" ")`, not `strip()`, is what preserves this.
  printf '%s\n' 'terminal:' "  cwd: \"$TMP/wrong-root\"" > "$cfg"
  printf '\t\n' >> "$cfg"
  printf '%s\n' 'platform_toolsets:' '  api_server:' '    - web' >> "$cfg"
  expect_eq "Hermes tab-only line still refuses" \
    "$(analysis_status "$cfg" "$ws")" "manual"

  # NEGATIVE GATE: nor is any other Unicode whitespace. A non-breaking space is
  # whitespace to Python and not to YAML, so `strip()` would have waved it past.
  printf '%s\n' 'terminal:' "  cwd: \"$TMP/wrong-root\"" > "$cfg"
  printf '\302\240\n' >> "$cfg"
  printf '%s\n' 'platform_toolsets:' '  api_server:' '    - web' >> "$cfg"
  expect_eq "Hermes non-breaking-space-only line still refuses" \
    "$(analysis_status "$cfg" "$ws")" "manual"

  # NEGATIVE GATE: the comment arm runs AFTER the tab check, so a tab-prefixed
  # comment during a plain continuation stays refused rather than skipped.
  printf '%s\n' \
    'terminal:' \
    "  cwd: \"$TMP/wrong-root\"" \
    '  container_persistent: true    # Persist filesystem across sessions' > "$cfg"
  printf '\t# tab-prefixed comment\n' >> "$cfg"
  printf '%s\n' 'platform_toolsets:' '  api_server:' '    - web' >> "$cfg"
  expect_eq "Hermes tab-prefixed comment during a plain continuation still refuses" \
    "$(analysis_status "$cfg" "$ws")" "manual"
}

test_hermes_recall_classification() {
  local cfg="$TMP/recall-config.yaml"

  printf '%s\n' 'platform_toolsets:' '  api_server: ["web", "memory"]' > "$cfg"
  expect_eq "recall: inline memory is in scope" \
    "$(recall_field "$cfg" recall)" "in-scope"
  expect_eq "recall: inline memory is literally fixable" \
    "$(recall_field "$cfg" recall_fix)" "literal"
  expect_eq "recall: inline memory names the entry" \
    "$(recall_items "$cfg")" "memory,"
  expect_eq "recall: inline removal shows the before" \
    "$(recall_field "$cfg" recall_scope)" '["web", "memory"]'
  expect_eq "recall: inline removal shows the after" \
    "$(recall_field "$cfg" recall_after)" '["web"]'

  printf '%s\n' 'platform_toolsets:' '  api_server:' '  - web' '  - memory' '  - session_search' > "$cfg"
  expect_eq "recall: block list is in scope" "$(recall_field "$cfg" recall)" "in-scope"
  expect_eq "recall: block list names both recall tools" \
    "$(recall_items "$cfg")" "memory,session_search,"

  printf '%s\n' 'platform_toolsets:' '  api_server: ["web", "file"]' > "$cfg"
  expect_eq "recall: a narrowed list reads clear" "$(recall_field "$cfg" recall)" "clear"

  # The whole reason this exists: a fresh Hermes names no toolset and gets the
  # wide default, memory included. Silence here would be the false all-clear.
  printf '%s\n' 'terminal:' '  cwd: "/tmp"' > "$cfg"
  expect_eq "recall: an absent api_server key is default-wide" \
    "$(recall_field "$cfg" recall)" "default-wide"
  printf '%s\n' 'platform_toolsets:' '  cli: ["hermes-cli"]' > "$cfg"
  expect_eq "recall: a sibling-only platform_toolsets is default-wide" \
    "$(recall_field "$cfg" recall)" "default-wide"
  # `api_server:` with nothing under it is YAML null, not an empty list — Hermes
  # falls back to the wide default there, so reading it as "[]" would print an
  # all-clear on a stateful gateway.
  printf '%s\n' 'platform_toolsets:' '  api_server:' '  cli: ["hermes-cli"]' > "$cfg"
  expect_eq "recall: a bare api_server key is default-wide, not empty" \
    "$(recall_field "$cfg" recall)" "default-wide"
  expect_eq "recall: absent config is default-wide" \
    "$(recall_field "$TMP/recall-absent.yaml" recall)" "default-wide"

  # A bundle expands to a whole platform's tools, so it cannot be edited down to
  # "everything except memory" — report it, never rewrite it.
  printf '%s\n' 'platform_toolsets:' '  api_server: ["hermes-api-server"]' > "$cfg"
  expect_eq "recall: the default bundle is in scope" "$(recall_field "$cfg" recall)" "in-scope"
  expect_eq "recall: a bundle is not literally fixable" "$(recall_field "$cfg" recall_fix)" "none"
  printf '%s\n' 'platform_toolsets:' '  api_server: ["all"]' > "$cfg"
  expect_eq "recall: a wildcard bundle is in scope" "$(recall_field "$cfg" recall)" "in-scope"
  printf '%s\n' 'platform_toolsets:' '  api_server: ["web", "hermes-discord", "memory"]' > "$cfg"
  expect_eq "recall: a bundle beside memory stays manual" "$(recall_field "$cfg" recall_fix)" "none"

  # Deleting named entries only proves the scope clean when every surviving name
  # is one this connector knows; a plugin toolset may carry recall of its own.
  printf '%s\n' 'platform_toolsets:' '  api_server: ["web", "memory", "my_plugin_tools"]' > "$cfg"
  expect_eq "recall: an unknown neighbour blocks the literal fix" \
    "$(recall_field "$cfg" recall_fix)" "none"
  printf '%s\n' 'platform_toolsets:' '  api_server: ["web", "my_plugin_tools"]' > "$cfg"
  expect_eq "recall: an unknown name alone is unknown" "$(recall_field "$cfg" recall)" "unknown"

  printf '%s\n' 'platform_toolsets:' '  api_server: ["web", "memory"] # keep this' > "$cfg"
  expect_eq "recall: a commented line is reported, not rewritten" \
    "$(recall_field "$cfg" recall_fix)" "none"
  expect_eq "recall: a commented line still reads in-scope" \
    "$(recall_field "$cfg" recall)" "in-scope"

  printf '%s\n' 'agent:' '  disabled_toolsets: ["memory", "session_search"]' \
    'platform_toolsets:' '  api_server: ["web", "memory"]' > "$cfg"
  expect_eq "recall: a global disable clears a listed entry" "$(recall_field "$cfg" recall)" "clear"
  printf '%s\n' 'agent:' '  disabled_toolsets: ["memory", "session_search"]' > "$cfg"
  expect_eq "recall: a global disable clears the wide default too" \
    "$(recall_field "$cfg" recall)" "clear"
  printf '%s\n' 'agent:' '  disabled_toolsets: ["memory"]' \
    'platform_toolsets:' '  api_server: ["web", "session_search"]' > "$cfg"
  expect_eq "recall: a partial global disable still reports" \
    "$(recall_field "$cfg" recall)" "in-scope"
  # Classification runs on the ACTIVE names. An unrecognised entry the user has
  # already switched off globally cannot carry recall, so it must not veto the
  # one edit this connector is willing to make — and it stays in the list.
  printf '%s\n' 'agent:' '  disabled_toolsets: ["my_plugin_tools"]' \
    'platform_toolsets:' '  api_server: ["web", "memory", "my_plugin_tools"]' > "$cfg"
  expect_eq "recall: a globally disabled unknown name still allows the fix" \
    "$(recall_field "$cfg" recall_fix)" "literal"
  expect_eq "recall: a globally disabled unknown name survives the removal" \
    "$(recall_field "$cfg" recall_after)" '["web", "my_plugin_tools"]'

  # Everything the conservative parser will not guess at answers "I cannot tell".
  printf '%s\n' '{"platform_toolsets": {"api_server": ["web"]}}' > "$cfg"
  expect_eq "recall: a flow-style document is unknown" "$(recall_field "$cfg" recall)" "unknown"
  printf '%s\n' 'platform_toolsets: &a' '  api_server: ["web"]' > "$cfg"
  expect_eq "recall: anchors are unknown" "$(recall_field "$cfg" recall)" "unknown"
  printf '%s\n' 'platform_toolsets:' '  api_server: null' > "$cfg"
  expect_eq "recall: an inline null is unknown" "$(recall_field "$cfg" recall)" "unknown"

  # A symlinked config is refused before classification, so it emits no recall
  # fact at all. The bash reader must still leave the globals at "unknown" —
  # keeping a previous answer here would carry an all-clear onto a config nobody
  # read.
  ln -sf "$TMP/recall-nowhere.yaml" "$TMP/recall-link.yaml"
  expect_eq "recall: a symlinked config emits no recall fact" \
    "$(recall_field "$TMP/recall-link.yaml" recall)" ""
  HERMES_RECALL_STATE="clear"
  hermes_recall_read "$TMP/recall-link.yaml"
  expect_eq "recall: an unreadable config re-arms the globals to unknown" \
    "$HERMES_RECALL_STATE" "unknown"
}

# Whatever the wizard tells an operator to type by hand has to be a shape this
# connector can read back on the next run. Both advice strings are fed to the
# REAL analyzer verbatim rather than to a copy of them, so an advice string that
# regresses to a bare flow sequence fails here instead of in a user's terminal —
# where the refusal names the key and never the quoting, leaving them with a
# config they typed exactly as instructed and no way to tell what is wrong.
test_hermes_printed_advice_parses() {
  local ws="$TMP/advice-workspace" cfg="$TMP/advice-config.yaml" qws
  mkdir -p "$ws"
  qws=$(python3 -c 'import json,os,sys; print(json.dumps(os.path.realpath(sys.argv[1])))' "$ws")

  # The file-lane advice names `file`, so a config written exactly as printed is
  # already lane-ready — no follow-up edit, which is the whole promise of the hint.
  printf '%s\n' 'terminal:' "  cwd: $qws" \
    'platform_toolsets:' "  api_server: $HERMES_API_SERVER_ADVICE_FILE" > "$cfg"
  expect_eq "advice: the printed file-lane list re-checks ready" \
    "$(analysis_status "$cfg" "$ws")" "ready"
  expect_eq "advice: the printed file-lane list reads as recall-free" \
    "$(recall_field "$cfg" recall)" "clear"

  # The gateway-only advice deliberately omits `file`, so the analyzer must ask
  # for that one concrete addition. `manual` here would mean an operator typed
  # what we printed and still got "I cannot read this config's toolset".
  printf '%s\n' 'terminal:' "  cwd: $qws" \
    'platform_toolsets:' "  api_server: $HERMES_API_SERVER_ADVICE" > "$cfg"
  expect_eq "advice: the printed gateway-only list is readable" \
    "$(analysis_status "$cfg" "$ws")" "fix"
  expect_eq "advice: the printed gateway-only list reads as recall-free" \
    "$(recall_field "$cfg" recall)" "clear"

  # The refusal this guards is syntactic, not about list length, so pin the
  # quoting itself: a future edit dropping the quotes would still satisfy every
  # assertion above only if the parser had also been loosened to accept it.
  case "$HERMES_API_SERVER_ADVICE$HERMES_API_SERVER_ADVICE_FILE" in
    *'"'*) pass "advice: both printed lists are JSON-quoted" ;;
    *) fail "advice: both printed lists are JSON-quoted" \
            "a bare flow sequence is refused by this connector's own scanner" ;;
  esac
}

test_hermes_recall_edits() {
  local ws="$TMP/recall-ws" cfg="$TMP/recall-edit.yaml" real_ws
  mkdir -p "$ws"
  real_ws=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$ws")

  # The file-readiness contract is unchanged by the recall work: an unapproved
  # `memory` survives a plain file-lane apply.
  printf '%s\n' 'terminal:' "  cwd: \"$real_ws\"" \
    'platform_toolsets:' '  api_server: ["web", "memory", "file"]' > "$cfg"
  expect_eq "recall: a stateful config is still file-lane ready" \
    "$(apply_status "$cfg" "$ws")" "ready"
  printf '%s\n' 'terminal:' '  cwd: "/nope"' \
    'platform_toolsets:' '  api_server: ["web", "memory"]' > "$cfg"
  expect_eq "recall: an unapproved apply still reports fix" "$(apply_status "$cfg" "$ws")" "fix"
  expect_eq "recall: an unapproved apply succeeds" "$(apply_status "$cfg" "$ws" apply)" "applied"
  expect_eq "recall: an unapproved apply preserves memory" \
    "$(grep -c 'api_server: \["web", "memory", "file"\]' "$cfg")" "1"

  # A bare key must never be narrowed to [file]: that would take the whole wide
  # default away and hand the user a scope they never chose.
  printf '%s\n' 'terminal:' "  cwd: \"$real_ws\"" 'platform_toolsets:' '  api_server:' > "$cfg"
  expect_eq "recall: a bare key needs no toolset change" "$(apply_status "$cfg" "$ws")" "ready"
  printf '%s\n' 'terminal:' '  cwd: "/nope"' 'platform_toolsets:' '  api_server:' > "$cfg"
  expect_eq "recall: a bare key applies only the cwd change" \
    "$(apply_status "$cfg" "$ws" apply)" "applied"
  if grep -q -- '- file' "$cfg"; then
    fail "recall: a bare key is not silently narrowed to [file]" "$(cat "$cfg")"
  else
    pass "recall: a bare key is not silently narrowed to [file]"
  fi

  # An approved removal and the file toolset are ONE before→after, not two
  # overlapping edits to the same line.
  printf '%s\n' 'terminal:' '  cwd: "/nope"' \
    'platform_toolsets:' '  api_server: ["web", "memory"]' > "$cfg"
  expect_eq "recall: approval folds into one before/after" \
    "$(hermes_config_analysis "$cfg" "$ws" analyze '["web", "memory"]' \
       | awk -F '\t' '$1 == "change" && $2 ~ /api_server/ { print $2; exit }')" \
    'platform_toolsets.api_server: ["web", "memory"] -> ["web", "file"]'
  expect_eq "recall: the combined edit applies" \
    "$(apply_status "$cfg" "$ws" apply '["web", "memory"]')" "applied"
  expect_eq "recall: the combined edit lands as one list" \
    "$(grep -c 'api_server: \["web", "file"\]' "$cfg")" "1"

  # The approval is bound to the exact list shown, so a config edited between the
  # preview and the yes refuses instead of overwriting someone else's change.
  printf '%s\n' 'platform_toolsets:' '  api_server: ["web", "memory"]' > "$cfg"
  expect_eq "recall: a stale approval refuses" \
    "$(apply_status "$cfg" "$ws" apply '["memory"]')" "manual"
  expect_eq "recall: a stale approval changed nothing" "$(grep -c memory "$cfg")" "1"

  printf '%s\n' 'platform_toolsets:' '  api_server:' '  - web   # keep me' '  - memory' \
    '  cli:' '  - hermes-cli' > "$cfg"
  expect_eq "recall: block removal applies" \
    "$(apply_status "$cfg" "" apply-recall '["web", "memory"]')" "applied"
  if grep -q '^  - web   # keep me$' "$cfg" && ! grep -q 'memory' "$cfg" \
     && grep -q '^  - hermes-cli$' "$cfg"; then
    pass "recall: block removal deletes one line and keeps the rest verbatim"
  else
    fail "recall: block removal deletes one line and keeps the rest verbatim" "$(cat "$cfg")"
  fi

  # The comment restriction is an INLINE-form rule: a block item's own trailing
  # comment travels with the line it annotates, and cannot be orphaned onto a
  # neighbour it was never about.
  printf '%s\n' 'platform_toolsets:' '  api_server:' '  - web' '  - memory  # why is this here' > "$cfg"
  expect_eq "recall: a commented block item is still fixable" \
    "$(recall_field "$cfg" recall_fix)" "literal"
  expect_eq "recall: a commented block item is removed" \
    "$(apply_status "$cfg" "" apply-recall '["web", "memory"]')" "applied"
  if ! grep -q 'why is this here' "$cfg" && grep -q '^  - web$' "$cfg"; then
    pass "recall: a removed block item takes its own comment with it"
  else
    fail "recall: a removed block item takes its own comment with it" "$(cat "$cfg")"
  fi

  # Emptying a block key would leave YAML null, which hands the wide default —
  # memory included — straight back. It has to become an explicit empty list.
  printf '%s\n' 'platform_toolsets:' '  api_server:' '  - memory' > "$cfg"
  expect_eq "recall: removing the last entry applies" \
    "$(apply_status "$cfg" "" apply-recall '["memory"]')" "applied"
  expect_eq "recall: an emptied list is written explicit" \
    "$(grep -c 'api_server: \[\]' "$cfg")" "1"
  expect_eq "recall: an emptied list re-reads clear" "$(recall_field "$cfg" recall)" "clear"

  printf '%s\n' 'terminal:' '  cwd: "/nope"' \
    'platform_toolsets:' '  api_server: ["web", "memory"]' > "$cfg"
  expect_eq "recall: a recall-only apply succeeds" \
    "$(apply_status "$cfg" "" apply-recall '["web", "memory"]')" "applied"
  if grep -q 'cwd: "/nope"' "$cfg" && grep -q 'api_server: \["web"\]' "$cfg"; then
    pass "recall: a recall-only apply leaves cwd and the file toolset alone"
  else
    fail "recall: a recall-only apply leaves cwd and the file toolset alone" "$(cat "$cfg")"
  fi
}

test_hermes_recall_operator_flow() {
  local saved_home="$HOME" out rc cfg
  cfg=".hermes/config.yaml"

  reset_recall_run
  recall_home "flow"
  printf '%s\n' 'platform_toolsets:' '  api_server: ["web", "memory"]' > "$HOME/$cfg"
  CONFIRM_ANSWER="n"
  out=$(hermes_recall_scope_step 2>&1); rc=$?
  expect_eq "recall step: a declined removal returns nonzero" "$rc" "1"
  case "$out" in *memory*) pass "recall step: a declined removal names the finding" ;;
    *) fail "recall step: a declined removal names the finding" "$out" ;; esac
  case "$out" in *config.yaml*) pass "recall step: a declined removal hands back the manual edit" ;;
    *) fail "recall step: a declined removal hands back the manual edit" "$out" ;; esac
  expect_eq "recall step: a declined removal changed nothing" \
    "$(grep -c 'api_server: \["web", "memory"\]' "$HOME/$cfg")" "1"

  reset_recall_run
  CONFIRM_ANSWER="y"
  out=$(hermes_recall_scope_step 2>&1); rc=$?
  expect_eq "recall step: an accepted removal returns zero" "$rc" "0"
  expect_eq "recall step: an accepted removal wrote the narrow list" \
    "$(grep -c 'api_server: \["web"\]' "$HOME/$cfg")" "1"

  reset_recall_run
  out=$(hermes_recall_scope_step 2>&1); rc=$?
  expect_eq "recall step: a clean scope passes" "$rc" "0"
  case "$out" in *"stays Conduck's"*) pass "recall step: a clean scope says so" ;;
    *) fail "recall step: a clean scope says so" "$out" ;; esac

  reset_recall_run
  CONFIRM_ANSWER="y"
  printf '%s\n' 'platform_toolsets:' '  api_server: ["hermes-api-server"]' > "$HOME/$cfg"
  out=$(hermes_recall_scope_step 2>&1); rc=$?
  expect_eq "recall step: a bundle returns nonzero" "$rc" "1"
  expect_eq "recall step: a bundle is never rewritten" \
    "$(grep -c 'hermes-api-server' "$HOME/$cfg")" "1"
  case "$out" in *"[confirm]"*) fail "recall step: a bundle is not offered as an edit" "asked anyway" ;;
    *) pass "recall step: a bundle is not offered as an edit" ;; esac

  reset_recall_run
  CONFIRM_ANSWER="y"
  printf '%s\n' 'terminal:' '  cwd: "/tmp"' > "$HOME/$cfg"
  out=$(hermes_recall_scope_step 2>&1); rc=$?
  expect_eq "recall step: the wide default returns nonzero" "$rc" "1"
  case "$out" in *"default bundle"*) pass "recall step: the wide default is named as the default" ;;
    *) fail "recall step: the wide default is named as the default" "$out" ;; esac
  case "$out" in *"[confirm]"*) fail "recall step: the wide default is not offered as an edit" "asked anyway" ;;
    *) pass "recall step: the wide default is not offered as an edit" ;; esac

  # A run whose whole promise is that it changes nothing may report but never gate.
  reset_recall_run
  CONFIRM_ANSWER="y"
  printf '%s\n' 'platform_toolsets:' '  api_server: ["web", "memory"]' > "$HOME/$cfg"
  DRY_RUN=true
  out=$(hermes_recall_scope_step 2>&1); rc=$?
  expect_eq "recall step: dry-run never blocks" "$rc" "0"
  expect_eq "recall step: dry-run changed nothing" \
    "$(grep -c 'api_server: \["web", "memory"\]' "$HOME/$cfg")" "1"

  reset_recall_run
  CONFIRM_ANSWER="y"
  REUSE_ONLY=true
  out=$(hermes_recall_scope_step 2>&1); rc=$?
  expect_eq "recall step: reuse-only never blocks" "$rc" "0"
  expect_eq "recall step: reuse-only changed nothing" \
    "$(grep -c 'api_server: \["web", "memory"\]' "$HOME/$cfg")" "1"

  # Two passes in ONE run, with no reset in between. This is not hypothetical: the
  # wizard's exposure menu can send the operator back to the gateway choice, which
  # re-runs configure_hermes and with it this step. A no is a no for the whole run
  # — asking the same question again reads as nagging, not as consent.
  reset_recall_run
  printf '%s\n' 'platform_toolsets:' '  api_server: ["web", "memory"]' > "$HOME/$cfg"
  CONFIRM_ANSWER="n"
  hermes_recall_scope_step >/dev/null 2>&1
  CONFIRM_ANSWER="y"
  out=$(hermes_recall_scope_step 2>&1); rc=$?
  case "$out" in *"[confirm]"*)
      fail "recall step: a second pass does not re-ask" "prompted again in the same run" ;;
    *) pass "recall step: a second pass does not re-ask" ;; esac
  expect_eq "recall step: a second pass still returns nonzero" "$rc" "1"
  expect_eq "recall step: a second pass changed nothing" \
    "$(grep -c 'api_server: \["web", "memory"\]' "$HOME/$cfg")" "1"

  reset_recall_run
  GW_KIND="openclaw"
  out=$(hermes_recall_scope_step 2>&1); rc=$?
  expect_eq "recall step: a non-Hermes gateway stays silent" "$out" ""
  expect_eq "recall step: a non-Hermes gateway passes" "$rc" "0"

  reset_recall_run
  HOME="$saved_home"
}

test_hermes_recall_file_lane() {
  local saved_home="$HOME" ws="$TMP/recall-lane-ws" real_ws out rc
  mkdir -p "$ws"
  real_ws=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$ws")

  reset_recall_run
  recall_home "lane"
  CONFIRM_ANSWER="y"
  printf '%s\n' 'terminal:' '  cwd: "/nope"' \
    'platform_toolsets:' '  api_server: ["web", "memory"]' > "$HOME/.hermes/config.yaml"
  out=$(hermes_file_readiness_step "$ws" 2>&1); rc=$?
  expect_eq "recall lane: an accepted lane succeeds" "$rc" "0"
  expect_eq "recall lane: the combined list is written once" \
    "$(grep -c 'api_server: \["web", "file"\]' "$HOME/.hermes/config.yaml")" "1"
  case "$out" in *'["web", "memory"] -> ["web", "file"]'*)
      pass "recall lane: one combined before/after is shown" ;;
    *) fail "recall lane: one combined before/after is shown" "$out" ;; esac

  # An already file-ready config is still stateful, and the memory question is
  # asked on its own merits rather than skipped as "nothing to fix".
  reset_recall_run
  CONFIRM_ANSWER="y"
  printf '%s\n' 'terminal:' "  cwd: \"$real_ws\"" \
    'platform_toolsets:' '  api_server: ["web", "memory", "file"]' > "$HOME/.hermes/config.yaml"
  out=$(hermes_file_readiness_step "$ws" 2>&1); rc=$?
  expect_eq "recall lane: a ready-but-stateful config keeps its lane" "$rc" "0"
  expect_eq "recall lane: a ready-but-stateful config still loses memory" \
    "$(grep -c 'api_server: \["web", "file"\]' "$HOME/.hermes/config.yaml")" "1"

  # File readiness being unprovable does not make the memory scope unfixable:
  # it is a different question about the same line, and it decides how CHAT
  # behaves whether or not files ever work.
  reset_recall_run
  CONFIRM_ANSWER="y"
  printf '%s\n' 'terminal:' '  backend: remote' "  cwd: \"$real_ws\"" \
    'platform_toolsets:' '  api_server: ["web", "memory", "file"]' > "$HOME/.hermes/config.yaml"
  out=$(hermes_file_readiness_step "$ws" 2>&1); rc=$?
  expect_eq "recall lane: an unusable lane is still dropped" "$rc" "1"
  expect_eq "recall lane: an unusable lane still fixes the scope" \
    "$(grep -c 'api_server: \["web", "file"\]' "$HOME/.hermes/config.yaml")" "1"
  case "$out" in *"cannot prove a safe Hermes file configuration"*)
      pass "recall lane: the manual reasons survive the scope edit" ;;
    *) fail "recall lane: the manual reasons survive the scope edit" "$out" ;; esac

  reset_recall_run
  CONFIRM_ANSWER="y"
  printf '%s\n' 'terminal:' '  cwd: "/nope"' \
    'platform_toolsets:' '  api_server: ["hermes-api-server"]' > "$HOME/.hermes/config.yaml"
  out=$(hermes_file_readiness_step "$ws" 2>&1); rc=$?
  expect_eq "recall lane: a bundle config still gets its lane" "$rc" "0"
  expect_eq "recall lane: a bundle config keeps its bundle" \
    "$(grep -c 'hermes-api-server' "$HOME/.hermes/config.yaml")" "1"

  # A no is a no for the whole run. Asking again at the next Hermes step would
  # read as nagging, not as consent.
  reset_recall_run
  printf '%s\n' 'terminal:' '  cwd: "/nope"' \
    'platform_toolsets:' '  api_server: ["web", "memory"]' > "$HOME/.hermes/config.yaml"
  CONFIRM_ANSWER="n"
  hermes_recall_scope_step >/dev/null 2>&1
  CONFIRM_ANSWER="y"
  out=$(hermes_file_readiness_step "$ws" 2>&1); rc=$?
  case "$out" in *"Remove Hermes's recall tools"*)
      fail "recall lane: a declined removal is not re-asked" "asked twice in one run" ;;
    *) pass "recall lane: a declined removal is not re-asked" ;; esac
  expect_eq "recall lane: a declined removal left memory in place" \
    "$(grep -c memory "$HOME/.hermes/config.yaml")" "1"

  reset_recall_run
  HOME="$saved_home"
}

# The reach of the report — the point of wiring it beyond the OPTIONAL file lane.
# A chat-only Hermes user never runs hermes_file_readiness_step, so without these
# call sites the common case never learns its gateway is stateful.
# configure_hermes sets GW_TOKEN/GW_AUTH/GW_LOCAL_PORT in the caller's shell, and
# the post-file-lane step sets the run-long recall latches in it, so NEITHER may be
# graded through a command substitution — a subshell would swallow exactly the
# globals these cases check. Their transcripts go to a file instead and come back
# in $out.
run_configure_hermes() {
  configure_hermes > "$TMP/reach-configure.out" 2>&1
  local rc=$?
  out=$(cat "$TMP/reach-configure.out")
  return $rc
}
run_post_recall_step() {
  hermes_recall_post_file_lane_step > "$TMP/reach-post.out" 2>&1
  local rc=$?
  out=$(cat "$TMP/reach-post.out")
  return $rc
}
run_file_readiness_step() { # run_file_readiness_step <workspace>
  hermes_file_readiness_step "$1" > "$TMP/reach-lane.out" 2>&1
  local rc=$?
  out=$(cat "$TMP/reach-lane.out")
  return $rc
}
# Restarts are the operator-visible cost of an edit, and the whole reason the
# question is asked after the file lane rather than before it. Both stub
# runners print a marked line, so one transcript can be counted either way.
count_hermes_restarts() { # count_hermes_restarts <transcript>
  printf '%s\n' "$1" | grep -c '^\[\(by-hand\|run_step\)\].*[Rr]estart Hermes'
}

test_hermes_recall_reach() {
  # configure_hermes writes the GW_* globals this suite's other cases rely on, so
  # they are saved and put back rather than left holding a fixture's values.
  local saved_home="$HOME" saved_id="${GW_ID:-}" saved_auth="${GW_AUTH:-}"
  local saved_token="${GW_TOKEN:-}" saved_port="${GW_LOCAL_PORT:-}"
  local saved_health="${GW_HEALTH_PATH:-}" saved_fs="${FS_URL:-}"
  local out rc body src n_live n_recall n_verify n_lane n_dry cfg=".hermes/config.yaml"
  local ws="$TMP/reach-ws"
  mkdir -p "$ws"

  # --- the gateway step settles the API server, and NOT the memory question ---
  # Both are the same one line in config.yaml as the optional file lane's toolset
  # edit, so settling it here would edit and restart Hermes twice for one line —
  # on a run exposure can still abort.
  reset_recall_run
  recall_home "wizard"
  printf '%s\n' 'platform_toolsets:' '  api_server: ["web", "memory"]' > "$HOME/$cfg"
  CONFIRM_ANSWER="y"
  run_configure_hermes; rc=$?
  expect_eq "reach: the gateway step reports no memory finding" \
    "$(printf '%s' "$out" | grep -c 'Hermes memory scope')" "0"
  expect_eq "reach: the gateway step asks nothing about the scope" \
    "$(printf '%s' "$out" | grep -c '\[confirm\]')" "0"
  expect_eq "reach: the gateway step edits no Hermes config" \
    "$(grep -c 'api_server: \["web", "memory"\]' "$HOME/$cfg")" "1"
  # The product call: report and offer, NEVER block. A gateway that chats fine is
  # still pairable; a fresh Hermes is default-wide, so a blocking gate anywhere in
  # this flow would stop nearly every new user until they hand-edit YAML.
  expect_eq "reach: the gateway step never blocks" "$rc" "0"
  expect_eq "reach: the gateway step still completes the gateway config" "$GW_AUTH" "bearer"
  expect_eq "reach: the gateway step still reads the API server key" \
    "$GW_TOKEN" "fixture-api-server-key"
  expect_eq "reach: the gateway step no longer settles the memory question" \
    "$(declare -f configure_hermes | grep -c 'hermes_recall')" "0"
  # The 8645-vs-8642 challenge sells the full-agent API server on what the proxy
  # really lacks — tools and skills. Recall is not on that list: Conduck replays
  # the whole conversation every turn, so naming a gateway-side memory as a
  # capability here would contradict the removal this same run offers.
  expect_eq "reach: the 8645 challenge names tools and skills" \
    "$(declare -f configure_hermes | grep -c "carries Hermes's tools and skills")" "1"
  expect_eq "reach: the 8645 challenge does not sell memory as a capability" \
    "$(declare -f configure_hermes | grep -ci 'memory')" "0"

  # …and the same run reaches the operator after the file lane has had its say.
  FS_URL=""; FS_CRED=""
  run_post_recall_step; rc=$?
  expect_eq "reach: the post-file-lane step reports" \
    "$(printf '%s' "$out" | grep -c 'Hermes memory scope')" "1"
  expect_eq "reach: the post-file-lane step applies an accepted removal" \
    "$(grep -c 'api_server: \["web"\]' "$HOME/$cfg")" "1"
  expect_eq "reach: the post-file-lane step never blocks" "$rc" "0"

  # A chat-only run — the file lane declined, or rclone missing — is exactly the
  # case that has no other route to the finding.
  reset_recall_run
  printf '%s\n' 'terminal:' '  cwd: "/tmp"' > "$HOME/$cfg"
  CONFIRM_ANSWER="n"
  run_post_recall_step; rc=$?
  expect_eq "reach: a chat-only run still reports a default-wide config" \
    "$(printf '%s' "$out" | grep -c 'Hermes memory scope')" "1"
  case "$out" in *"default bundle"*) pass "reach: a chat-only run names the wide default" ;;
    *) fail "reach: a chat-only run names the wide default" "$out" ;; esac
  expect_eq "reach: a chat-only run never blocks" "$rc" "0"

  reset_recall_run
  printf '%s\n' 'platform_toolsets:' '  api_server: ["web", "memory"]' > "$HOME/$cfg"
  CONFIRM_ANSWER="n"
  run_post_recall_step; rc=$?
  expect_eq "reach: a declined removal does not fail setup" "$rc" "0"
  expect_eq "reach: a declined removal changes nothing" \
    "$(grep -c 'api_server: \["web", "memory"\]' "$HOME/$cfg")" "1"
  # A no is a no for the whole run, and so is any other settled answer: the step
  # is reached once per run, and a second reach must not re-open the question.
  CONFIRM_ANSWER="y"
  run_post_recall_step; rc=$?
  case "$out" in *"[confirm]"*)
      fail "reach: a second reach does not re-ask the memory question" "asked again" ;;
    *) pass "reach: a second reach does not re-ask the memory question" ;; esac
  expect_eq "reach: a second reach changes nothing after a no" \
    "$(grep -c 'api_server: \["web", "memory"\]' "$HOME/$cfg")" "1"
  expect_eq "reach: a second reach still returns zero" "$rc" "0"

  # The point of going after the lane: ONE before→after, ONE write, ONE restart
  # for a line both steps want to change — and no second question afterwards.
  reset_recall_run
  printf '%s\n' 'terminal:' '  cwd: "/nope"' \
    'platform_toolsets:' '  api_server: ["web", "memory"]' > "$HOME/$cfg"
  CONFIRM_ANSWER="y"
  run_file_readiness_step "$ws"; rc=$?
  expect_eq "reach: the lane folds recall and file into one edit" \
    "$(grep -c 'api_server: \["web", "file"\]' "$HOME/$cfg")" "1"
  expect_eq "reach: the combined edit restarts Hermes once" \
    "$(count_hermes_restarts "$out")" "1"
  run_post_recall_step
  expect_eq "reach: a lane that already asked leaves the later step silent" "$out" ""

  # The same silence when the lane's answer leaves the scope unfixed. The question
  # was put to this operator once; repeating the by-hand fix a screen later is
  # nagging, not information — a no, and a shape this connector will not rewrite.
  reset_recall_run
  printf '%s\n' 'terminal:' '  cwd: "/nope"' \
    'platform_toolsets:' '  api_server: ["web", "memory"]' > "$HOME/$cfg"
  CONFIRM_ANSWER="n"
  run_file_readiness_step "$ws"
  expect_eq "reach: the lane put the question" \
    "$(printf '%s' "$out" | grep -c 'Hermes memory scope')" "1"
  run_post_recall_step
  expect_eq "reach: a removal declined in the lane is not re-offered" "$out" ""

  reset_recall_run
  printf '%s\n' 'terminal:' '  cwd: "/nope"' \
    'platform_toolsets:' '  api_server: ["hermes-api-server"]' > "$HOME/$cfg"
  CONFIRM_ANSWER="y"
  run_file_readiness_step "$ws"
  run_post_recall_step
  expect_eq "reach: a shape the lane already explained is not explained twice" "$out" ""

  reset_recall_run
  printf '%s\n' 'platform_toolsets:' '  api_server: ["web", "file"]' > "$HOME/$cfg"
  CONFIRM_ANSWER="y"
  run_post_recall_step; rc=$?
  expect_eq "reach: a clean scope is reported as clean" \
    "$(printf '%s' "$out" | grep -c "stays Conduck's")" "1"
  case "$out" in *"[confirm]"*) fail "reach: a clean scope asks nothing" "prompted anyway" ;;
    *) pass "reach: a clean scope asks nothing" ;; esac

  # The suggested replacement list follows the code this run will actually emit,
  # exactly as the --show-code re-emit does.
  reset_recall_run
  printf '%s\n' 'terminal:' '  cwd: "/tmp"' > "$HOME/$cfg"
  FS_URL="https://files.example.test"; FS_CRED="fixture-file-secret"
  run_post_recall_step
  case "$out" in *"api_server: $HERMES_API_SERVER_ADVICE_FILE"*)
      pass "reach: a run carrying a file lane suggests $HERMES_API_SERVER_ADVICE_FILE" ;;
    *) fail "reach: a run carrying a file lane suggests $HERMES_API_SERVER_ADVICE_FILE" "$out" ;; esac
  reset_recall_run
  FS_URL="https://files.example.test"; FS_CRED=""
  run_post_recall_step
  case "$out" in *"api_server: $HERMES_API_SERVER_ADVICE_FILE"*)
      fail "reach: a lane the code will not carry falls back to $HERMES_API_SERVER_ADVICE" "suggested an unused toolset" ;;
    *) pass "reach: a lane the code will not carry falls back to $HERMES_API_SERVER_ADVICE" ;; esac
  FS_URL=""; FS_CRED=""

  # A run whose whole promise is that it changes nothing may report but never gate.
  reset_recall_run
  printf '%s\n' 'platform_toolsets:' '  api_server: ["web", "memory"]' > "$HOME/$cfg"
  CONFIRM_ANSWER="y"
  DRY_RUN=true
  run_post_recall_step; rc=$?
  expect_eq "reach: dry-run reports the finding it would act on" \
    "$(printf '%s' "$out" | grep -c 'Hermes memory scope')" "1"
  expect_eq "reach: dry-run changes no Hermes config" \
    "$(grep -c 'api_server: \["web", "memory"\]' "$HOME/$cfg")" "1"
  expect_eq "reach: dry-run does not fail setup" "$rc" "0"

  reset_recall_run
  CONFIRM_ANSWER="y"
  REUSE_ONLY=true
  run_post_recall_step; rc=$?
  expect_eq "reach: reuse-only reports the finding" \
    "$(printf '%s' "$out" | grep -c 'Hermes memory scope')" "1"
  expect_eq "reach: reuse-only changes no Hermes config" \
    "$(grep -c 'api_server: \["web", "memory"\]' "$HOME/$cfg")" "1"
  expect_eq "reach: reuse-only does not fail setup" "$rc" "0"

  reset_recall_run
  GW_KIND="openclaw"
  run_post_recall_step; rc=$?
  expect_eq "reach: a non-Hermes gateway stays silent" "$out" ""
  expect_eq "reach: a non-Hermes gateway passes" "$rc" "0"

  # Pinned as source, not behavior: `|| die` is a product decision the founder
  # owns, and a future edit that quietly adds one would otherwise only surface as
  # a support ticket from a user who cannot pair a working gateway.
  expect_eq "reach: both setup call sites are explicitly non-blocking" \
    "$(declare -f hermes_recall_post_file_lane_step hermes_recall_checked_handoff_step \
       | grep -c 'hermes_recall_scope_step .* || true')" "2"
  expect_eq "reach: neither setup call site can die" \
    "$(declare -f hermes_recall_post_file_lane_step hermes_recall_checked_handoff_step \
       | grep -c '\bdie\b')" "0"

  # Wiring, not behavior: run_setup needs a whole wizard run to exercise, but the
  # ORDER is the part that matters — after the file lane so one line is edited
  # once, and before the dry-run exit so a planned run still reports.
  src=$(sed -n '/^run_setup()/,/^}/p' "$ROOT/src/99-main.inc.sh")
  n_lane=$(printf '%s\n' "$src" | grep -n '^  setup_file_lane$' | head -1 | cut -d: -f1)
  n_recall=$(printf '%s\n' "$src" | grep -n '^  hermes_recall_post_file_lane_step$' | head -1 | cut -d: -f1)
  n_dry=$(printf '%s\n' "$src" | grep -n 'print_plan' | head -1 | cut -d: -f1)
  if [ -n "$n_lane" ] && [ -n "$n_recall" ] && [ -n "$n_dry" ] \
     && [ "$n_recall" -gt "$n_lane" ] && [ "$n_recall" -lt "$n_dry" ]; then
    pass "reach: setup asks after the file lane and before the dry-run exit"
  else
    fail "reach: setup asks after the file lane and before the dry-run exit" \
      "lane=$n_lane recall=$n_recall plan=$n_dry"
  fi

  # --- --show-code, which pairs an ALREADY-configured gateway ---
  # A profile is written once; the gateway keeps changing. Nothing in the saved
  # profile or the live exposure checks can see a scope that drifted back.
  reset_recall_run
  recall_home "showcode"
  rm -f "$HOME/$cfg"          # drifted back to Hermes's own wide default
  REUSE_ONLY=true             # --show-code forces this; --dry-run is rejected
  FS_URL=""
  out=$(show_qr_recall_scope 2>&1); rc=$?
  expect_eq "reach: show-code reports a drifted scope" \
    "$(printf '%s' "$out" | grep -c 'Hermes memory scope')" "1"
  expect_eq "reach: show-code never blocks the code" "$rc" "0"
  case "$out" in *"api_server: $HERMES_API_SERVER_ADVICE"*)
      pass "reach: a gateway-only re-show suggests $HERMES_API_SERVER_ADVICE" ;;
    *) fail "reach: a gateway-only re-show suggests $HERMES_API_SERVER_ADVICE" "$out" ;; esac
  if [ -e "$HOME/$cfg" ]; then
    fail "reach: show-code writes no Hermes config" "config.yaml was created"
  else
    pass "reach: show-code writes no Hermes config"
  fi

  # show_qr_recover_file_lane can legitimately downgrade a saved lane to
  # gateway-only, so the suggested list follows the code actually being emitted.
  # The test is the SAME (FS_URL && FS_CRED) pair build_pairing_payload_json uses:
  # a recovered URL whose credential is gone carries no fileServer block, so
  # suggesting `file` there would name a toolset the pairing does not use.
  local saved_cred="${FS_CRED:-}"
  reset_recall_run
  REUSE_ONLY=true
  FS_URL="https://files.example.test"
  FS_CRED="fixture-file-secret"
  out=$(show_qr_recall_scope 2>&1); rc=$?
  case "$out" in *"api_server: $HERMES_API_SERVER_ADVICE_FILE"*)
      pass "reach: a re-show carrying a file lane suggests $HERMES_API_SERVER_ADVICE_FILE" ;;
    *) fail "reach: a re-show carrying a file lane suggests $HERMES_API_SERVER_ADVICE_FILE" "$out" ;; esac

  reset_recall_run
  REUSE_ONLY=true
  FS_URL="https://files.example.test"
  FS_CRED=""
  out=$(show_qr_recall_scope 2>&1); rc=$?
  case "$out" in *"api_server: $HERMES_API_SERVER_ADVICE_FILE"*)
      fail "reach: an unrecoverable lane falls back to $HERMES_API_SERVER_ADVICE" "suggested a lane the QR will not carry" ;;
    *) pass "reach: an unrecoverable lane falls back to $HERMES_API_SERVER_ADVICE" ;; esac
  FS_CRED="$saved_cred"

  reset_recall_run
  GW_KIND="openclaw"
  REUSE_ONLY=true
  out=$(show_qr_recall_scope 2>&1); rc=$?
  expect_eq "reach: show-code stays silent for a non-Hermes profile" "$out" ""
  expect_eq "reach: show-code passes for a non-Hermes profile" "$rc" "0"

  # Wiring, not behavior: running the whole re-show needs a live tailnet and a
  # saved profile, but the ORDER is the part that matters — a stale profile must
  # die in show_qr_check_live without collecting a warning it cannot act on, and
  # verify_all must separate the finding from the code itself.
  body=$(declare -f run_show_qr)
  n_live=$(printf '%s\n' "$body" | grep -n 'show_qr_check_live' | head -1 | cut -d: -f1)
  n_recall=$(printf '%s\n' "$body" | grep -n 'show_qr_recall_scope' | head -1 | cut -d: -f1)
  n_verify=$(printf '%s\n' "$body" | grep -n 'verify_all' | head -1 | cut -d: -f1)
  if [ -n "$n_live" ] && [ -n "$n_recall" ] && [ -n "$n_verify" ] \
     && [ "$n_recall" -gt "$n_live" ] && [ "$n_recall" -lt "$n_verify" ]; then
    pass "reach: the re-show reports between the drift gate and verification"
  else
    fail "reach: the re-show reports between the drift gate and verification" \
      "live=$n_live recall=$n_recall verify=$n_verify"
  fi

  reset_recall_run
  HOME="$saved_home"; GW_ID="$saved_id"; GW_AUTH="$saved_auth"; GW_TOKEN="$saved_token"
  GW_LOCAL_PORT="$saved_port"; GW_HEALTH_PATH="$saved_health"; FS_URL="$saved_fs"
}

# --- the --check-server handoff ----------------------------------------------
# A check that passes offers to continue into setup with the address it graded,
# and that handoff pairs it as a CUSTOM server — the check proved one endpoint,
# not a gateway product. So the Hermes question has to be reached by attribution
# instead of by kind, and attribution has to be conservative in ONE direction:
# telling someone their unrelated gateway keeps a memory it does not keep is
# worse than never mentioning it. Every case below that is not a full match must
# stay silent.
handoff_env() { # handoff_env <line...> — writes ~/.hermes/.env for the fixture home
  printf '%s\n' "$@" > "$HOME/.hermes/.env"
}

test_hermes_checked_handoff() {
  local saved_home="$HOME" saved_auth="${GW_AUTH:-}" saved_token="${GW_TOKEN:-}"
  local saved_kind="${GW_KIND:-}" saved_fs="${FS_URL:-}" out rc src
  local key="fixture-api-server-key"

  HOME="$TMP/handoff-home"; rm -rf "$HOME"; mkdir -p "$HOME/.hermes"
  GW_AUTH="bearer"; GW_TOKEN="$key"
  handoff_env 'API_SERVER_ENABLED=true' 'API_SERVER_HOST=127.0.0.1' \
    'API_SERVER_PORT=8642' "API_SERVER_KEY=$key"

  expect_true "handoff: a full settings match attributes the address" \
    hermes_settings_match_url "http://127.0.0.1:8642"
  expect_true "handoff: localhost reaches the same 127.0.0.1 bind" \
    hermes_settings_match_url "http://localhost:8642"
  expect_false "handoff: another port on the same host is another service" \
    hermes_settings_match_url "http://127.0.0.1:8643"
  # 127.0.0.2 is a different listener, and a base path can route one listener to
  # anything at all — neither is the address Hermes declares.
  expect_false "handoff: another loopback bind is another listener" \
    hermes_settings_match_url "http://127.0.0.2:8642"
  expect_false "handoff: a base path is not attributable" \
    hermes_settings_match_url "http://127.0.0.1:8642/proxy"
  # The remote case this exists to protect: Hermes installed here, gateway
  # somewhere else. A tailnet name in front of THIS Hermes lands here too, and
  # silence is the right answer for both — from here they are indistinguishable.
  expect_false "handoff: an https address is never claimed as this machine" \
    hermes_settings_match_url "https://gw.example.test:8642"
  # Same address, same port, https — a TLS terminator in front of anything at all.
  # The scheme alone has to refuse it, or the loopback checks below would attribute
  # whatever sits behind someone else's certificate.
  expect_false "handoff: an https loopback address is not attributed either" \
    hermes_settings_match_url "https://localhost:8642"
  expect_false "handoff: an IPv6 address against an IPv4 bind stays silent" \
    hermes_settings_match_url "http://[::1]:8642"

  handoff_env 'API_SERVER_ENABLED=true' 'API_SERVER_HOST=::1' \
    'API_SERVER_PORT=8642' "API_SERVER_KEY=$key"
  expect_true "handoff: an IPv6 bind matches its own address" \
    hermes_settings_match_url "http://[::1]:8642"
  handoff_env 'API_SERVER_ENABLED=true' 'API_SERVER_HOST=0.0.0.0' \
    'API_SERVER_PORT=8642' "API_SERVER_KEY=$key"
  expect_true "handoff: a wildcard bind answers on any loopback address" \
    hermes_settings_match_url "http://127.0.0.2:8642"

  # Hermes's own default port, declared by omission.
  handoff_env 'API_SERVER_ENABLED=true' "API_SERVER_KEY=$key"
  expect_true "handoff: an undeclared port falls back to 8642 like Hermes does" \
    hermes_settings_match_url "http://127.0.0.1:8642"
  # …but a declaration this connector cannot read is NOT a statement that the
  # thing on 8642 is Hermes, so it must not inherit that fallback.
  handoff_env 'API_SERVER_ENABLED=true' 'API_SERVER_PORT=8642 # the full-agent server' \
    "API_SERVER_KEY=$key"
  expect_false "handoff: an unreadable port declaration attributes nothing" \
    hermes_settings_match_url "http://127.0.0.1:8642"

  handoff_env 'API_SERVER_ENABLED=false' 'API_SERVER_PORT=8642' "API_SERVER_KEY=$key"
  expect_false "handoff: a disabled API server attributes nothing" \
    hermes_settings_match_url "http://127.0.0.1:8642"
  handoff_env 'API_SERVER_ENABLED=true' 'API_SERVER_PORT=8642'
  expect_false "handoff: no declared key leaves nothing to correlate" \
    hermes_settings_match_url "http://127.0.0.1:8642"

  # The credential is the strongest evidence available without fingerprinting the
  # listener: the check AUTHENTICATED with it. A different token, or none, is not
  # this Hermes as far as anything on disk can prove.
  handoff_env 'API_SERVER_ENABLED=true' 'API_SERVER_PORT=8642' "API_SERVER_KEY=$key"
  GW_TOKEN="some-other-token"
  expect_false "handoff: a different credential is a different service" \
    hermes_settings_match_url "http://127.0.0.1:8642"
  GW_AUTH="none"; GW_TOKEN=""
  expect_false "handoff: a keyless check attributes nothing" \
    hermes_settings_match_url "http://127.0.0.1:8642"
  GW_AUTH="bearer"; GW_TOKEN="$key"

  rm -f "$HOME/.hermes/.env"
  expect_false "handoff: no Hermes install attributes nothing" \
    hermes_settings_match_url "http://127.0.0.1:8642"
  handoff_env 'API_SERVER_ENABLED=true' 'API_SERVER_PORT=8642' "API_SERVER_KEY=$key"

  # --- what the attributed handoff actually does ---
  # The kind stays custom: the app pairs exactly the address the check graded,
  # and an address match is not authority to run Hermes-specific setup steps.
  reset_recall_run
  GW_KIND="custom"
  CHECK_HANDOFF_LOCAL_HERMES=true
  FS_URL=""; FS_CRED=""
  printf '%s\n' 'platform_toolsets:' '  api_server: ["web", "memory"]' > "$HOME/.hermes/config.yaml"
  CONFIRM_ANSWER="y"
  run_post_recall_step; rc=$?
  expect_eq "handoff: an attributed handoff reports the memory scope" \
    "$(printf '%s' "$out" | grep -c 'Hermes memory scope')" "1"
  case "$out" in *"matches this machine's Hermes API-server settings"*)
      pass "handoff: the report says why a Hermes finding appears on a custom gateway" ;;
    *) fail "handoff: the report says why a Hermes finding appears on a custom gateway" "$out" ;; esac
  case "$out" in *"not proof of which process holds that port"*)
      pass "handoff: the report claims a settings match, not certainty" ;;
    *) fail "handoff: the report claims a settings match, not certainty" "$out" ;; esac
  expect_eq "handoff: an accepted removal is applied" \
    "$(grep -c 'api_server: \["web"\]' "$HOME/.hermes/config.yaml")" "1"
  expect_eq "handoff: the paired gateway kind is untouched" "$GW_KIND" "custom"
  expect_eq "handoff: an attributed handoff never blocks" "$rc" "0"

  reset_recall_run
  GW_KIND="custom"
  CHECK_HANDOFF_LOCAL_HERMES=true
  printf '%s\n' 'platform_toolsets:' '  api_server: ["web", "memory"]' > "$HOME/.hermes/config.yaml"
  CONFIRM_ANSWER="n"
  run_post_recall_step; rc=$?
  expect_eq "handoff: a declined removal changes nothing" \
    "$(grep -c 'api_server: \["web", "memory"\]' "$HOME/.hermes/config.yaml")" "1"
  expect_eq "handoff: a declined removal never blocks" "$rc" "0"
  expect_eq "handoff: a declined removal leaves the kind alone" "$GW_KIND" "custom"

  # An unattributed custom gateway is the ordinary case: a server this run knows
  # nothing about, and nothing is what it says.
  reset_recall_run
  GW_KIND="custom"
  CONFIRM_ANSWER="y"
  run_post_recall_step; rc=$?
  expect_eq "handoff: an unattributed custom gateway stays silent" "$out" ""
  expect_eq "handoff: an unattributed custom gateway passes" "$rc" "0"
  expect_eq "handoff: an unattributed custom gateway changes nothing" \
    "$(grep -c 'api_server: \["web", "memory"\]' "$HOME/.hermes/config.yaml")" "1"

  # Only a passing --check-server may attribute, and only while the graded
  # address still exists: the handoff clears GW_URL to rebuild it as HTTPS.
  src=$(sed -n '/^run_compat()/,/^}/p' "$ROOT/src/70-check-server.inc.sh")
  expect_eq "handoff: the server check is the only thing that sets the latch" \
    "$(printf '%s\n' "$src" | grep -c 'CHECK_HANDOFF_LOCAL_HERMES=true')" "1"
  # …and it sets it only under the settings match. An unconditional latch would
  # hand every passing check a Hermes finding about somebody else's gateway.
  expect_eq "handoff: the server check latches only on a settings match" \
    "$(printf '%s\n' "$src" | grep -A1 'if hermes_settings_match_url' \
       | grep -c 'CHECK_HANDOFF_LOCAL_HERMES=true')" "1"
  expect_eq "handoff: no other module sets the latch" \
    "$(grep -l 'CHECK_HANDOFF_LOCAL_HERMES=true' "$ROOT"/src/*.inc.sh | wc -l | tr -d ' ')" "1"

  reset_recall_run
  HOME="$saved_home"; GW_AUTH="$saved_auth"; GW_TOKEN="$saved_token"
  GW_KIND="$saved_kind"; FS_URL="$saved_fs"
}

wait_ready() { # <stdout-file> <pid>
  local i=0 line
  READY_PORT=""
  while [ "$i" -lt 100 ]; do
    line=$(head -n 1 "$1" 2>/dev/null)
    case "$line" in READY\ *) READY_PORT="${line#READY }"; return 0 ;; esac
    kill -0 "$2" 2>/dev/null || return 1
    i=$((i+1)); sleep 0.05
  done
  return 1
}

start_webdav() { # <mode> <dir> <password>
  local mode="$1" dir="$2" password="$3"
  : > "$TMP/webdav.out"
  : > "$TMP/webdav.capture"
  WEBDAV_PASS="$password" python3 "$WEBDAV" --mode "$mode" --port 0 \
    --dir "$dir" --user conduck --capture "$TMP/webdav.capture" \
    > "$TMP/webdav.out" 2> "$TMP/webdav.err" &
  WEBDAV_PID=$!
  wait_ready "$TMP/webdav.out" "$WEBDAV_PID"
}

stop_webdav() {
  [ -n "$WEBDAV_PID" ] && kill "$WEBDAV_PID" 2>/dev/null
  [ -n "$WEBDAV_PID" ] && wait "$WEBDAV_PID" 2>/dev/null
  WEBDAV_PID=""
}

start_adapter() { # <mode> <dir> <token>
  local mode="$1" dir="$2" token="$3"
  : > "$TMP/adapter.out"
  CONDUCK_FILES_DIR="$dir" CONDUCK_TOKEN="$token" \
    python3 "$ADAPTER" --mode "$mode" --port 0 \
    > "$TMP/adapter.out" 2> "$TMP/adapter.err" &
  ADAPTER_PID=$!
  wait_ready "$TMP/adapter.out" "$ADAPTER_PID"
}

stop_adapter() {
  [ -n "$ADAPTER_PID" ] && kill "$ADAPTER_PID" 2>/dev/null
  [ -n "$ADAPTER_PID" ] && wait "$ADAPTER_PID" 2>/dev/null
  ADAPTER_PID=""
}

# Test override: the supervisor itself is out of scope for the loopback fixture;
# the readiness function must still prove its authenticated byte behavior.
fs_unit_active() { return 0; }

test_local_service_gate() {
  local served="$TMP/local-service" password="local-service-secret"
  mkdir -p "$served"
  start_webdav good "$served" "$password" || {
    fail "local authenticated service gate" "fixture failed to start"; return; }
  FS_UNIT="$TMP/fake.service"
  FS_FOLDER="$served"
  FS_LOCAL_PORT="$READY_PORT"
  FS_CRED="$password"
  expect_true "local authenticated service gate" fs_local_service_ready
  stop_webdav

  start_webdav delete-lies "$served" "$password" || {
    fail "local lying DELETE is repaired and re-proven" "fixture failed to start"; return; }
  FS_LOCAL_PORT="$READY_PORT"
  expect_true "local lying DELETE is repaired and re-proven" fs_local_service_ready
  stop_webdav

  printf '%s\n' 'unrelated file must survive' > "$served/unrelated-victim.txt"
  start_webdav delete-swaps-symlink "$served" "$password" || {
    fail "local cleanup refuses replacement symlink" "fixture failed to start"; return; }
  FS_LOCAL_PORT="$READY_PORT"
  if fs_local_service_ready; then
    fail "local cleanup refuses replacement symlink" "replacement symlink earned a clean pass"
  elif [ "$(cat "$served/unrelated-victim.txt" 2>/dev/null)" = "unrelated file must survive" ] \
       && find "$served" -maxdepth 1 -type l \
            -name 'conduck-connect-local-probe-*.txt' -print -quit | grep -q .; then
    pass "local cleanup refuses replacement symlink"
  else
    fail "local cleanup refuses replacement symlink" "unrelated target changed or exact symlink was followed"
  fi
  stop_webdav

  start_webdav no-final-newline "$served" "$password" || {
    fail "local newline mismatch is rejected" "fixture failed to start"; return; }
  FS_LOCAL_PORT="$READY_PORT"
  expect_false "local newline mismatch is rejected" fs_local_service_ready
  stop_webdav

  start_webdav open "$served" "$password" || {
    fail "open local service is rejected" "fixture failed to start"; return; }
  FS_LOCAL_PORT="$READY_PORT"
  expect_false "open local service is rejected" fs_local_service_ready
  stop_webdav
}

test_reply_candidate_parity() {
  expect_true "reply discovery accepts exact app candidate" \
    agent_reply_names_output "Done: output-a1b2.txt" "output-a1b2.txt" "folder/input.txt"
  expect_false "reply discovery rejects output-name substring" \
    agent_reply_names_output "Done: prefixoutput-a1b2.txt.bak" "output-a1b2.txt" "folder/input.txt"
  expect_false "reply discovery enforces app five-candidate cap" \
    agent_reply_names_output \
      "a.txt b.txt c.txt d.txt e.txt output-a1b2.txt" \
      "output-a1b2.txt" "folder/input.txt"
  expect_true "reply discovery excludes echoed inbound before cap" \
    agent_reply_names_output \
      "input.txt a.txt b.txt c.txt d.txt output-a1b2.txt" \
      "output-a1b2.txt" "folder/input.txt"
}

LAST_AGENT_PAYLOAD=""
LAST_AGENT_TIMEOUT=""
doctor_chat_request() {
  local out
  LAST_AGENT_PAYLOAD="$1"
  LAST_AGENT_TIMEOUT="${2:-}"
  out=$(printf '%s' "$1" | curl -q -sS --max-time 10 \
    -H "Authorization: Bearer $GW_TOKEN" \
    -H 'Content-Type: application/json' \
    --data-binary @- -w '\n%{http_code}' "$GW_URL/v1/chat/completions") || return 1
  DCC_CODE="${out##*$'\n'}"
  DCC_BODY="${out%$'\n'*}"
  return 0
}

test_agent_sentinel() {
  local served="$TMP/agent-sentinel" password="sentinel-secret" token="adapter-secret"
  local openclaw_payload uploaded_secret
  mkdir -p "$served"
  start_webdav good "$served" "$password" || {
    fail "agent byte sentinel" "WebDAV fixture failed to start"; return; }
  FS_URL="http://127.0.0.1:$READY_PORT"
  FS_CRED="$password"
  FS_FOLDER="$served"
  GW_TOKEN="$token"
  GW_MODEL=""

  start_adapter files-good "$served" "$token" || {
    fail "agent byte sentinel" "adapter fixture failed to start"; stop_webdav; return; }
  GW_URL="http://127.0.0.1:$READY_PORT"
  # start_adapter overwrote READY_PORT, while FS_URL intentionally retained the
  # WebDAV port captured above.
  GW_KIND="openclaw"
  CONDUCK_AGENT_CHAT_TIMEOUT_SECONDS=301
  if agent_file_probe; then
    pass "OpenClaw agent byte sentinel"
  else
    fail "OpenClaw agent byte sentinel" "$AGENT_FILE_PROBE_REASON"
  fi
  unset CONDUCK_AGENT_CHAT_TIMEOUT_SECONDS
  expect_eq "agent sentinel chat allows more than 30 seconds" \
    "$LAST_AGENT_TIMEOUT" "301"
  openclaw_payload="$LAST_AGENT_PAYLOAD"
  uploaded_secret=$(awk -F 'body=' '/^PUT .*input-.* body=/{value=$2} END{print value}' "$TMP/webdav.capture")
  if [ -n "$uploaded_secret" ] && [[ "$openclaw_payload" != *"$uploaded_secret"* ]]; then
    pass "agent sentinel content is unknown to the model"
  else
    fail "agent sentinel content is unknown to the model" "uploaded bytes were absent or leaked into the prompt"
  fi
  if printf '%s' "$openclaw_payload" | python3 -c '
import json, sys
d=json.load(sys.stdin)
t=d["messages"][0]["content"]
raise SystemExit(0 if "model" not in d and "Use read to read" in t and "Use write " in t else 1)
'; then
    pass "OpenClaw sentinel matches tools and app default-model request"
  else
    fail "OpenClaw sentinel matches tools and app default-model request" "wrong tool names or invented model"
  fi

  GW_KIND="hermes"
  if agent_file_probe; then
    pass "Hermes agent byte sentinel"
  else
    fail "Hermes agent byte sentinel" "$AGENT_FILE_PROBE_REASON"
  fi
  if printf '%s' "$LAST_AGENT_PAYLOAD" | python3 -c '
import json, sys
d=json.load(sys.stdin); t=d["messages"][0]["content"]
raise SystemExit(0 if "model" not in d and "Use read_file to read" in t and "Use write_file " in t else 1)
'; then
    pass "Hermes sentinel matches tools and app default-model request"
  else
    fail "Hermes sentinel matches tools and app default-model request" "wrong tool names or invented model"
  fi
  if find "$served" -mindepth 1 -print -quit | grep -q .; then
    fail "agent sentinel exact cleanup" "probe artifacts remain"
  else
    pass "agent sentinel exact cleanup"
  fi
  stop_adapter

  stop_webdav
  start_webdav first-output-404 "$served" "$password" || {
    fail "agent sentinel tolerates one fresh-listing miss" "WebDAV fixture failed to start"; return; }
  FS_URL="http://127.0.0.1:$READY_PORT"
  start_adapter files-good "$served" "$token" || {
    fail "agent sentinel tolerates one fresh-listing miss" "adapter fixture failed to start"; stop_webdav; return; }
  GW_URL="http://127.0.0.1:$READY_PORT"
  GW_KIND="openclaw"
  if agent_file_probe; then
    pass "agent sentinel tolerates one fresh-listing miss"
  else
    fail "agent sentinel tolerates one fresh-listing miss" "$AGENT_FILE_PROBE_REASON"
  fi
  stop_adapter

  export CONDUCK_FILES_LATE_DELAY=0.5
  start_adapter files-late-write "$served" "$token" || {
    unset CONDUCK_FILES_LATE_DELAY
    fail "OpenClaw reply-first late write is rejected" "adapter fixture failed to start"; stop_webdav; return; }
  unset CONDUCK_FILES_LATE_DELAY
  GW_URL="http://127.0.0.1:$READY_PORT"
  if agent_file_probe; then
    fail "OpenClaw reply-first late write is rejected" "post-reply output earned a pass"
  elif [[ "$AGENT_FILE_PROBE_REASON" == *"replied before"* ]] \
       && ! find "$served" -maxdepth 1 -name 'output-*.txt' -print -quit | grep -q .; then
    pass "OpenClaw reply-first late write is rejected"
  else
    fail "OpenClaw reply-first late write is rejected" "wrong diagnostic or late artifact remained"
  fi
  stop_adapter

  start_adapter files-no-final-newline "$served" "$token" || {
    fail "OpenClaw newline-mismatch false green rejected" "adapter fixture failed to start"; stop_webdav; return; }
  GW_URL="http://127.0.0.1:$READY_PORT"
  if agent_file_probe; then
    fail "OpenClaw newline-mismatch false green rejected" "missing final newline passed"
  elif [ -n "$AGENT_FILE_PROBE_REASON" ]; then
    pass "OpenClaw newline-mismatch false green rejected"
  else
    fail "OpenClaw newline-mismatch false green rejected" "failure had no diagnostic"
  fi
  stop_adapter

  start_adapter files-reference-substring "$served" "$token" || {
    fail "OpenClaw substring-only reply rejected" "adapter fixture failed to start"; stop_webdav; return; }
  GW_URL="http://127.0.0.1:$READY_PORT"
  if agent_file_probe; then
    fail "OpenClaw substring-only reply rejected" "longer filename token earned a pass"
  elif [ -n "$AGENT_FILE_PROBE_REASON" ]; then
    pass "OpenClaw substring-only reply rejected"
  else
    fail "OpenClaw substring-only reply rejected" "failure had no diagnostic"
  fi
  stop_adapter

  start_adapter files-no-write "$served" "$token" || {
    fail "OpenClaw reply-only false green rejected" "adapter fixture failed to start"; stop_webdav; return; }
  GW_URL="http://127.0.0.1:$READY_PORT"
  GW_KIND="openclaw"
  if agent_file_probe; then
    fail "OpenClaw reply-only false green rejected" "reply text passed without output bytes"
  elif [ -n "$AGENT_FILE_PROBE_REASON" ]; then
    pass "OpenClaw reply-only false green rejected"
  else
    fail "OpenClaw reply-only false green rejected" "failure had no diagnostic"
  fi
  stop_adapter

  start_adapter files-wrong-bytes "$served" "$token" || {
    fail "OpenClaw byte-mismatch false green rejected" "adapter fixture failed to start"; stop_webdav; return; }
  GW_URL="http://127.0.0.1:$READY_PORT"
  if agent_file_probe; then
    fail "OpenClaw byte-mismatch false green rejected" "wrong output bytes passed"
  elif [ -n "$AGENT_FILE_PROBE_REASON" ]; then
    pass "OpenClaw byte-mismatch false green rejected"
  else
    fail "OpenClaw byte-mismatch false green rejected" "failure had no diagnostic"
  fi
  stop_adapter

  start_adapter files-no-write "$served" "$token" || {
    fail "failed agent sentinel omits file lane" "adapter fixture failed to start"; stop_webdav; return; }
  GW_URL="http://127.0.0.1:$READY_PORT"
  FS_CRED="$password"
  if agent_file_lane_gate; then
    fail "failed agent sentinel omits file lane" "gate unexpectedly passed"
  elif [ -z "$FS_URL" ] && [ -z "$FS_CRED" ]; then
    pass "failed agent sentinel omits file lane"
  else
    fail "failed agent sentinel omits file lane" "fileServer state survived failure"
  fi
  expect_true "failed agent sentinel final cleanup" \
    agent_file_probe_cleanup_backstop true
  stop_adapter
  stop_webdav
}

test_agent_deadlines_and_cleanup() {
  local served="$TMP/agent-deadline" password="deadline-secret" token="adapter-secret"
  local t0 t1 elapsed warning warning_file tag="a1b2c3d4e5f60708"
  mkdir -p "$served"
  WEBDAV_HANG_SECONDS=10
  start_webdav hang-output-get "$served" "$password" || {
    fail "hanging output GET obeys real deadline" "WebDAV fixture failed to start"; return; }
  unset WEBDAV_HANG_SECONDS
  FS_URL="http://127.0.0.1:$READY_PORT"
  FS_CRED="$password"
  FS_FOLDER="$served"
  GW_TOKEN="$token"
  GW_MODEL=""
  GW_KIND="openclaw"
  start_adapter files-good "$served" "$token" || {
    fail "hanging output GET obeys real deadline" "adapter fixture failed to start"; stop_webdav; return; }
  GW_URL="http://127.0.0.1:$READY_PORT"
  CONDUCK_AGENT_OUTPUT_DEADLINE_MS=650
  CONDUCK_AGENT_OUTPUT_REQUEST_TIMEOUT_MS=150
  t0=$(agent_probe_now_ms)
  if agent_file_probe; then
    fail "hanging output GET obeys real deadline" "stalled downloads unexpectedly passed"
  else
    t1=$(agent_probe_now_ms)
    elapsed=$((t1 - t0))
    if [ "$elapsed" -lt 2500 ] && [ -n "$AGENT_FILE_PROBE_REASON" ]; then
      pass "hanging output GET obeys real deadline"
    else
      fail "hanging output GET obeys real deadline" "elapsed ${elapsed}ms"
    fi
  fi
  unset CONDUCK_AGENT_OUTPUT_DEADLINE_MS CONDUCK_AGENT_OUTPUT_REQUEST_TIMEOUT_MS
  stop_adapter
  stop_webdav

  rm -rf "$served"; mkdir -p "$served"
  start_webdav delete-lies "$served" "$password" || {
    fail "cleanup verifies post-delete 404" "WebDAV fixture failed to start"; return; }
  FS_URL="http://127.0.0.1:$READY_PORT"
  start_adapter files-good "$served" "$token" || {
    fail "cleanup verifies post-delete 404" "adapter fixture failed to start"; stop_webdav; return; }
  GW_URL="http://127.0.0.1:$READY_PORT"
  if agent_file_probe; then
    fail "cleanup verifies post-delete 404" "lying DELETE earned a clean pass"
  elif [ "$AGENT_PROBE_ACTIVE" = true ] && [ -n "$AGENT_FILE_PROBE_REASON" ]; then
    pass "cleanup verifies post-delete 404"
  else
    fail "cleanup verifies post-delete 404" "unproven cleanup was not retained"
  fi
  stop_adapter
  stop_webdav
  rm -rf "$served"; mkdir -p "$served"
  agent_probe_abandon_registry

  start_webdav delete-dir-lies "$served" "$password" || {
    fail "cleanup proves fallback directory absence" "WebDAV fixture failed to start"; return; }
  FS_URL="http://127.0.0.1:$READY_PORT"
  start_adapter files-good "$served" "$token" || {
    fail "cleanup proves fallback directory absence" "adapter fixture failed to start"; stop_webdav; return; }
  GW_URL="http://127.0.0.1:$READY_PORT"
  if agent_file_probe; then
    fail "cleanup proves fallback directory absence" "lying directory DELETE earned a clean pass"
  elif [ "$AGENT_PROBE_ACTIVE" = true ] \
       && [ "$AGENT_PROBE_DIR_VERIFY_METHOD" = "propfind" ] \
       && [ -d "$served/$AGENT_PROBE_DIRKEY" ]; then
    pass "cleanup proves fallback directory absence"
  else
    fail "cleanup proves fallback directory absence" "directory absence was not checked/retained"
  fi
  stop_adapter
  stop_webdav
  rm -rf "$served"; mkdir -p "$served"
  agent_probe_abandon_registry

  start_webdav good "$served" "$password" || {
    fail "exact-name EXIT cleanup backstop" "WebDAV fixture failed to start"; return; }
  FS_URL="http://127.0.0.1:$READY_PORT"
  FS_CRED="$password"
  mkdir -p "$served/conduck-connect-agent-$tag"
  printf 'owned\n' > "$served/conduck-connect-agent-$tag/input-$tag.txt"
  printf 'owned\n' > "$served/output-$tag.txt"
  printf 'keep\n' > "$served/unrelated.txt"
  AGENT_PROBE_TAG="$tag"
  AGENT_PROBE_DIRKEY="conduck-connect-agent-$tag"
  AGENT_PROBE_INPUTKEY="$AGENT_PROBE_DIRKEY/input-$tag.txt"
  AGENT_PROBE_OUTPUTKEY="output-$tag.txt"
  AGENT_PROBE_FS_URL="$FS_URL"
  AGENT_PROBE_FS_CRED="$FS_CRED"
  AGENT_PROBE_DIR_ARMED=true
  AGENT_PROBE_INPUT_ARMED=true
  AGENT_PROBE_OUTPUT_ARMED=true
  AGENT_PROBE_ACTIVE=true
  if agent_file_probe_cleanup_backstop \
     && [ -f "$served/unrelated.txt" ] \
     && [ ! -e "$served/conduck-connect-agent-$tag" ] \
     && [ ! -e "$served/output-$tag.txt" ]; then
    pass "exact-name EXIT cleanup backstop"
  else
    fail "exact-name EXIT cleanup backstop" "owned targets or unrelated file handled incorrectly"
  fi

  mkdir -p "$served/conduck-connect-agent-$tag"
  printf 'small\n' > "$served/conduck-connect-agent-$tag/input-$tag.txt"
  printf 'not-the-small-sentinel-but-deliberately-larger\n' > "$served/output-$tag.txt"
  if ! agent_output_local_snapshot "$served" "output-$tag.txt" \
       "$served/conduck-connect-agent-$tag/input-$tag.txt"; then
    pass "reply-boundary snapshot rejects wrong-sized output before comparison"
  else
    fail "reply-boundary snapshot rejects wrong-sized output before comparison" "wrong-sized output passed"
  fi
  rm -f "$served/output-$tag.txt"
  rm -f "$served/conduck-connect-agent-$tag/input-$tag.txt"
  rmdir "$served/conduck-connect-agent-$tag"

  tag="b1c2d3e4f5a60718"
  AGENT_PROBE_TAG="$tag"
  AGENT_PROBE_DIRKEY="conduck-connect-agent-$tag"
  AGENT_PROBE_INPUTKEY="$AGENT_PROBE_DIRKEY/input-$tag.txt"
  AGENT_PROBE_OUTPUTKEY="output-$tag.txt"
  AGENT_PROBE_FS_URL="$FS_URL"
  AGENT_PROBE_FS_CRED="$FS_CRED"
  AGENT_PROBE_FS_FOLDER="$served"
  AGENT_PROBE_DIR_ARMED=false
  AGENT_PROBE_INPUT_ARMED=false
  AGENT_PROBE_OUTPUT_ARMED=true
  AGENT_PROBE_DIR_VERIFY_METHOD=""
  AGENT_PROBE_LATE_RISK=true
  AGENT_PROBE_ACTIVE=true
  warning_file="$TMP/future-write-warning.txt"
  agent_file_probe_cleanup_backstop true > "$warning_file" 2>&1
  warning=$(cat "$warning_file")
  if [[ "$warning" == *"$served/output-$tag.txt"* ]] && ! $AGENT_PROBE_ACTIVE; then
    pass "timeout/cancel cleanup prints exact future-write recovery"
  else
    fail "timeout/cancel cleanup prints exact future-write recovery" "exact later-recheck path was absent"
  fi
  if grep -q 'agent_file_probe_cleanup_backstop true' "$ROOT/src/30-exposure.inc.sh" \
     && grep -q "trap 'exit 130' INT" "$ROOT/src/30-exposure.inc.sh"; then
    pass "EXIT and signal traps chain final sentinel cleanup"
  else
    fail "EXIT and signal traps chain final sentinel cleanup" "final cleanup hook/trap missing"
  fi
  stop_webdav
}

test_request_credential_controls() {
  local save_fs="$FS_CRED" save_gw="$GW_TOKEN" save_auth="$GW_AUTH"
  FS_CRED="safe"$'\r'"injected"
  expect_false "file curl refuses CR credential before request" \
    curl_fs -o /dev/null "http://127.0.0.1:1/"
  GW_AUTH="bearer"
  GW_TOKEN="safe"$'\n'"injected"
  expect_false "gateway curl refuses LF credential before request" \
    curl_gw -o /dev/null "http://127.0.0.1:1/"
  FS_CRED="$save_fs"; GW_TOKEN="$save_gw"; GW_AUTH="$save_auth"
}

test_show_code_live_folder() {
  local live_folder="$TMP/show-code-live-root"
  local stale_folder="$TMP/show-code-stale-profile-root"
  local output="$TMP/show-code-folder.out"
  if (
    json_get() {
      case "$2" in
        fileServer.url)       printf '%s' "https://files.example.test" ;;
        fileServer.localPort) printf '%s' "7443" ;;
        fileServer.folder)    printf '%s' "$stale_folder" ;;
      esac
    }
    existing_fs_config() {
      FS_CRED="fixture-file-secret"
      FS_LOCAL_PORT="5006"
      FS_FOLDER="$live_folder"
      FS_CRED_LEGACY_ARGV=false
      return 0
    }
    PROFILE_FILE="$TMP/unused-profile.json"
    FS_URL=""; FS_CRED=""; FS_LOCAL_PORT=""; FS_FOLDER=""
    show_qr_recover_file_lane > "$output" 2>&1 \
      && [ "$FS_FOLDER" = "$live_folder" ] \
      && [ "$FS_URL" = "https://files.example.test" ] \
      && [ "$FS_LOCAL_PORT" = "7443" ] \
      && grep -qF "using the structurally parsed live folder" "$output"
  ); then
    pass "show-code keeps structurally parsed live folder"
  else
    fail "show-code keeps structurally parsed live folder" "stale profile folder displaced the live service root"
  fi
}

# ========================================= the served root, resolved + gated ==
#
# The measured bug: the wizard accepted a symlink as the shared folder, wrote it
# into the unit verbatim, certified it "byte-faithful" and offered to publish it.
# Pointed at $HOME it served ~/.ssh/authorized_keys and this connector's own 0600
# credential file over WebDAV. The doctor already refuses that root; setup must
# refuse the same one, and must record the RESOLVED path so the target cannot be
# swapped under a running server.
real_path_of() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }

test_shared_folder_gate() {
  reset_fake_home "folder-gate"
  local real="$HOME/agent-workspace"
  mkdir -p "$real"
  expect_false "served root refuses /" fs_resolve_shared_folder "/"
  expect_false "served root refuses \$HOME itself" fs_resolve_shared_folder "$HOME"
  expect_false "served root refuses a relative path" fs_resolve_shared_folder "agent-workspace"
  ln -s "$HOME" "$HOME/home-link"
  expect_false "served root refuses a symlink to \$HOME" fs_resolve_shared_folder "$HOME/home-link"
  case "$FS_FOLDER_REFUSAL" in
    *"home directory"*) pass "served-root refusal carries its reason" ;;
    *) fail "served-root refusal carries its reason" "got '$FS_FOLDER_REFUSAL'" ;;
  esac
  printf 'not a folder\n' > "$HOME/a-file"
  expect_false "served root refuses a plain file" fs_resolve_shared_folder "$HOME/a-file"

  expect_true "served root accepts the agent's own folder" fs_resolve_shared_folder "$real"
  ln -s "$real" "$HOME/ws-link"
  if fs_resolve_shared_folder "$HOME/ws-link" \
     && [ "$FS_FOLDER_RESOLVED" = "$(real_path_of "$real")" ]; then
    pass "served root resolves a symlink to its target"
  else
    fail "served root resolves a symlink to its target" "got '$FS_FOLDER_RESOLVED'"
  fi
}

# One real pass through Step 4 for a NEW lane: the refused answer must be re-asked
# (never silently accepted), and what lands in the unit + the profile field must be
# the resolved path.
new_lane_run() { # new_lane_run <fs_local_service_ready rc> <folder answer…>
  local ready_rc="$1"; shift
  local queue="$TMP/new-lane-answers"
  printf '%s\n' "$@" > "$queue"
  (
    HOME="$TMP/new-lane-home"; mkdir -p "$HOME"
    STATE_DIR="$HOME/state"
    STATE_DIR_EXPOSURE_REPORTED=false
    GW_KIND="custom"; GW_ID="custom"; OS="Linux"
    TRANSPORT="public"; SCOPE="private"
    DRY_RUN=false; REUSE_ONLY=false
    FS_CRED=""; FS_URL=""; FS_FOLDER=""; FS_LOCAL_PORT=""; FS_UNIT=""
    FS_LANE_PREPARED=false; FS_UNIT_CREATED_THIS_RUN=false
    FS_ROUTE_SELF_MANAGED=false; FS_RESIDUE_REPORTED=false
    CONFIRM_ANSWER="y"
    READY_RC="$ready_rc"
    ASK_QUEUE="$queue"
    # A file, not a variable: `ask` is called inside $( ), so a queue index kept in
    # a variable would die with that subshell and re-serve the same answer forever.
    ask() {
      local reply=""
      if [ -s "$ASK_QUEUE" ]; then
        reply=$(head -n 1 "$ASK_QUEUE")
        sed '1d' "$ASK_QUEUE" > "$ASK_QUEUE.rest" && mv "$ASK_QUEUE.rest" "$ASK_QUEUE"
      fi
      [ -n "$reply" ] || reply="$2"
      printf '[ask] %s\n' "$1" >&2
      printf '%s' "$reply"
    }
    ask_url() { printf '%s' "${URL_ANSWER:-}"; }
    have() { case "$1" in rclone|systemctl|loginctl) return 0 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
    systemctl() { return 0; }
    loginctl() { printf 'Linger=yes\n'; }
    existing_fs_config() { return 1; }
    allocate_fs_local_port() { FS_LOCAL_PORT=5006; return 0; }
    fs_local_service_ready() { return "$READY_RC"; }
    hermes_residual_state_note() { :; }
    install_conduck_tools_block() { :; }
    write_fs_unit_linux() {
      FS_UNIT="$HOME/.config/systemd/user/conduck-files-$GW_ID.service"
      mkdir -p "$(dirname "$FS_UNIT")"
      printf 'ExecStart=/usr/bin/rclone serve webdav "%s" --addr 127.0.0.1:%s --user conduck\n' \
        "$1" "$FS_LOCAL_PORT" > "$FS_UNIT"
      ensure_state_dir
      printf '%s\n' "$FS_CRED" > "$(state_cred_file)"
      printf 'RCLONE_PASS=%s\n' "$FS_CRED" > "$(state_env_file)"
      return 0
    }
    setup_file_lane
    printf 'FOLDER=%s\n' "$FS_FOLDER"
  ) 2>&1
}

test_new_lane_folder_recording() {
  local home="$TMP/new-lane-home" out
  rm -rf "$home"; mkdir -p "$home/workspace"
  ln -s "$home" "$home/loop-to-home"
  ln -s "$home/workspace" "$home/ws-link"
  # First answer is a link to $HOME (refused), second is a link to a real folder.
  out=$(new_lane_run 0 "$home/loop-to-home" "$home/ws-link")
  case "$out" in *"I can't serve $home/loop-to-home"*)
      pass "new lane refuses a \$HOME-resolving answer" ;;
    *) fail "new lane refuses a \$HOME-resolving answer" "$out" ;; esac
  case "$out" in *"served over WebDAV with read AND write access"*)
      pass "new lane explains why that root is refused" ;;
    *) fail "new lane explains why that root is refused" "$out" ;; esac
  case "$out" in *"FOLDER=$(real_path_of "$home/workspace")"*)
      pass "new lane records the RESOLVED served root" ;;
    *) fail "new lane records the RESOLVED served root" "$out" ;; esac
  if grep -qF "serve webdav \"$(real_path_of "$home/workspace")\"" \
       "$home/.config/systemd/user/conduck-files-custom.service" 2>/dev/null; then
    pass "new lane writes the resolved root into the unit"
  else
    fail "new lane writes the resolved root into the unit" "unit kept the symlink path"
  fi
  # No address given on the "my own HTTPS" transport, so the lane this run built
  # never ships — the exact case that used to end green in silence.
  case "$out" in *"Before you close this terminal"*)
      pass "new lane: a built-but-unshipped lane is reported at the end" ;;
    *) fail "new lane: a built-but-unshipped lane is reported at the end" "$out" ;; esac
  case "$out" in *"systemctl --user disable --now conduck-files-custom.service"*)
      pass "new lane: its teardown commands are handed over" ;;
    *) fail "new lane: its teardown commands are handed over" "$out" ;; esac
}

# ================================ a file-lane address that will not survive ===
#
# The measured bug: a quick tunnel came back after a reboot on a NEW public
# hostname while the paired device still called the dead one, and the live address
# was in no profile and no script output. The gateway URL is warned about at
# acceptance; the file lane's own URL had the same exposure and said nothing.
quick_tunnel_warning_out() { # quick_tunnel_warning_out <file-lane url>
  (
    FS_URL="$1"
    fs_warn_quick_tunnel_url
  ) 2>&1
}

test_file_lane_quick_tunnel_warning() {
  local out
  out=$(quick_tunnel_warning_out "https://files-abc-def.trycloudflare.com")
  case "$out" in *"QUICK TUNNEL"*)
      pass "file-lane quick tunnel: the address is called out" ;;
    *) fail "file-lane quick tunnel: the address is called out" "$out" ;; esac
  case "$out" in *"attachments stop working"*)
      pass "file-lane quick tunnel: names the file-lane consequence" ;;
    *) fail "file-lane quick tunnel: names the file-lane consequence" "$out" ;; esac
  case "$out" in *"no saved profile"*)
      pass "file-lane quick tunnel: says the new address is nowhere to be found" ;;
    *) fail "file-lane quick tunnel: says the new address is nowhere to be found" "$out" ;; esac
  case "$out" in *"NAMED tunnel"*)
      pass "file-lane quick tunnel: offers an address that survives a restart" ;;
    *) fail "file-lane quick tunnel: offers an address that survives a restart" "$out" ;; esac

  # Silence is the whole point everywhere else — including the two shapes a
  # home-grown matcher gets wrong.
  local quiet
  for quiet in "" \
      "https://files.example.com" \
      "https://files.example.ts.net:8443" \
      "https://files.example.com/trycloudflare.com" \
      "https://nottrycloudflare.com"; do
    out=$(quick_tunnel_warning_out "$quiet")
    if [ -z "$out" ]; then
      pass "file-lane quick tunnel: silent for '${quiet:-(no address)}'"
    else
      fail "file-lane quick tunnel: silent for '${quiet:-(no address)}'" "$out"
    fi
  done

  # …and it has to be WIRED, not merely correct: one real pass through the
  # "my own HTTPS" branch with a quick-tunnel answer.
  local home="$TMP/new-lane-home"
  rm -rf "$home"; mkdir -p "$home/workspace"
  out=$(URL_ANSWER="https://files-xyz.trycloudflare.com" new_lane_run 0 "$home/workspace")
  case "$out" in *"QUICK TUNNEL"*)
      pass "file-lane quick tunnel: warned where the address is accepted" ;;
    *) fail "file-lane quick tunnel: warned where the address is accepted" "$out" ;; esac
}

# ============================== a lane that was built and never shipped =======
#
# The measured bug: on the two transports whose HTTPS route the operator creates
# themselves, a dropped lane rolled back nothing and said nothing — the run ended
# green while an authenticated WebDAV server over the agent's folder was still
# running, still enabled at boot, and still behind the route the script told them
# to create. One tester finished with 10 units, 9 boot-wired, and no removal
# command anywhere in the tool.
residue_run() { # residue_run <created-this-run> <route-self-managed> <os> [shipped]
  (
    HOME="$TMP/residue-home"; rm -rf "$HOME"; mkdir -p "$HOME"
    STATE_DIR="$HOME/state dir"; mkdir -p "$STATE_DIR"
    GW_ID="openclaw"; OS="$3"
    DRY_RUN="${DRY:-false}"
    FS_LANE_PREPARED=true
    FS_UNIT_CREATED_THIS_RUN="$1"
    FS_ROUTE_SELF_MANAGED="$2"
    FS_RESIDUE_REPORTED=false
    FS_LOCAL_PORT="5006"
    FS_FOLDER="$HOME/.openclaw/workspace"
    FS_URL=""; FS_CRED=""
    if [ "${4:-no}" = "shipped" ]; then
      FS_URL="https://files.example.test:8443"; FS_CRED="secret"
    fi
    if [ "$3" = "Linux" ]; then
      FS_UNIT="$HOME/.config/systemd/user/conduck-files-openclaw.service"
      printf 'RCLONE_PASS=x\n' > "$STATE_DIR/fileserver-openclaw.env"
    else
      FS_UNIT="$HOME/Library/LaunchAgents/ai.gigaduck.conduck-files-openclaw.plist"
    fi
    mkdir -p "$(dirname "$FS_UNIT")"
    printf 'unit\n' > "$FS_UNIT"
    printf 'secret\n' > "$STATE_DIR/fileserver-openclaw.cred"
    fs_lane_residue_note
    fs_lane_residue_note          # second call must add nothing
  ) 2>&1
}

test_lane_residue_report() {
  local out
  out=$(residue_run true false Linux)
  case "$out" in *"this run started a file server"*)
      pass "residue: a lane this run built is named as such" ;;
    *) fail "residue: a lane this run built is named as such" "$out" ;; esac
  case "$out" in *"conduck-files-openclaw.service"*)
      pass "residue: names the exact unit" ;;
    *) fail "residue: names the exact unit" "$out" ;; esac
  case "$out" in *"starts again at boot"*)
      pass "residue: says it survives a reboot" ;;
    *) fail "residue: says it survives a reboot" "$out" ;; esac
  case "$out" in *"systemctl --user disable --now conduck-files-openclaw.service"*)
      pass "residue: hands over the disable command" ;;
    *) fail "residue: hands over the disable command" "$out" ;; esac
  case "$out" in *"reset-failed"*)
      pass "residue: clears a crash-looped unit's failed state too" ;;
    *) fail "residue: clears a crash-looped unit's failed state too" "$out" ;; esac
  case "$out" in *"fileserver-openclaw.cred'"*)
      pass "residue: removal of a spacey credential path is quoted" ;;
    *) fail "residue: removal of a spacey credential path is quoted" "$out" ;; esac
  case "$out" in *"fileserver-openclaw.env"*)
      pass "residue: names the Linux env file as well" ;;
    *) fail "residue: names the Linux env file as well" "$out" ;; esac
  # Printed once: a second call in the same run must add nothing.
  if [ "$(printf '%s\n' "$out" | grep -c "disable --now")" = "1" ]; then
    pass "residue: reported exactly once per run"
  else
    fail "residue: reported exactly once per run" "$out"
  fi

  out=$(residue_run true true Linux)
  case "$out" in *"HTTPS route you set up for it still points at 127.0.0.1:5006"*)
      pass "residue: names the operator's own HTTPS route" ;;
    *) fail "residue: names the operator's own HTTPS route" "$out" ;; esac

  out=$(residue_run false false Darwin)
  case "$out" in *"keeps running"*)
      pass "residue: a reused lane is not claimed as this run's" ;;
    *) fail "residue: a reused lane is not claimed as this run's" "$out" ;; esac
  case "$out" in *"launchctl unload"*)
      pass "residue: macOS teardown unloads the LaunchAgent" ;;
    *) fail "residue: macOS teardown unloads the LaunchAgent" "$out" ;; esac
  case "$out" in *"fileserver-openclaw.env"*)
      fail "residue: macOS does not name a Linux-only env file" "$out" ;;
    *) pass "residue: macOS does not name a Linux-only env file" ;; esac

  out=$(residue_run true false Linux shipped)
  if [ -z "$out" ]; then
    pass "residue: a lane that ships is not reported as residue"
  else
    fail "residue: a lane that ships is not reported as residue" "$out"
  fi

  out=$( DRY=true residue_run true false Linux )
  if [ -z "$out" ]; then
    pass "residue: a dry run reports nothing (nothing was built)"
  else
    fail "residue: a dry run reports nothing (nothing was built)" "$out"
  fi
}

# ================================ a unit that exists but cannot be started ====
#
# The measured bug: the free-port check is a bind probe seconds before rclone's
# own bind, so a stolen port wedges the unit in `failed` for good — and every
# later run printed a checkmark for that corpse, refused to expose it in one
# line, and exited 0 with a green chat-only code naming no unit and no journal.
inactive_run() { # inactive_run <confirm> <reuse-only> [pre-bind-new-ports]
  (
    HOME="$TMP/inactive-home"; rm -rf "$HOME"; mkdir -p "$HOME"
    STATE_DIR="$HOME/state"; mkdir -p "$STATE_DIR"
    GW_ID="openclaw"; OS="Linux"
    DRY_RUN=false; REUSE_ONLY="$2"
    CONFIRM_ANSWER="$1"
    FS_PORT_START=5006; FS_PORT_END=5105
    FS_UNIT="$HOME/.config/systemd/user/conduck-files-openclaw.service"
    FS_LOCAL_PORT="5006"
    FS_CRED="inactive-fixture-secret"
    FS_FOLDER="$HOME/workspace"
    FS_LANE_PREPARED=true; FS_UNIT_CREATED_THIS_RUN=false
    FS_ROUTE_SELF_MANAGED=false; FS_RESIDUE_REPORTED=false
    mkdir -p "$(dirname "$FS_UNIT")" "$FS_FOLDER"
    printf '%s\n' '[Service]' \
      "ExecStart=/usr/bin/rclone serve webdav \"$FS_FOLDER\" --addr 127.0.0.1:5006 --user conduck" \
      > "$FS_UNIT"
    local fake_bin="$TMP/inactive-bin"
    mkdir -p "$fake_bin"
    printf '%s\n' '#!/usr/bin/env sh' 'exit 0' > "$fake_bin/rclone"
    chmod 755 "$fake_bin/rclone"
    PATH="$fake_bin:$PATH"
    # The global test override answers "active" for every unit; the case under test
    # is the opposite, so the real pair is restored and driven by this systemctl.
    eval "$FS_UNIT_ACTIVE_IMPL"
    have() { case "$1" in systemctl|loginctl|rclone) return 0 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
    systemctl() {
      case "$*" in
        *"is-active"*)    [ -f "$HOME/started" ] ;;
        *"enable --now"*) : > "$HOME/started"; return 0 ;;
        *)                return 0 ;;
      esac
    }
    loginctl() { printf 'Linger=yes\n'; }
    rc=0
    fs_inactive_unit_report || rc=$?
    printf 'rc=%s port=%s\n' "$rc" "$FS_LOCAL_PORT"
  ) 2>&1
}

test_inactive_unit_report() {
  local out
  out=$(inactive_run n false)
  case "$out" in *"conduck-files-openclaw.service"*)
      pass "dead unit: the unit is named" ;;
    *) fail "dead unit: the unit is named" "$out" ;; esac
  case "$out" in *"journalctl --user -u conduck-files-openclaw.service"*)
      pass "dead unit: hands over the journal command" ;;
    *) fail "dead unit: hands over the journal command" "$out" ;; esac
  case "$out" in *"took port 5006 between my free-port check"*)
      pass "dead unit: names the stolen-port cause" ;;
    *) fail "dead unit: names the stolen-port cause" "$out" ;; esac
  case "$out" in *"rc=1 port=5006"*)
      pass "dead unit: declining the move leaves the lane out" ;;
    *) fail "dead unit: declining the move leaves the lane out" "$out" ;; esac

  out=$(inactive_run y true)
  case "$out" in *"reuse-only: not moving the lane"*)
      pass "dead unit: --reuse-only changes no port" ;;
    *) fail "dead unit: --reuse-only changes no port" "$out" ;; esac
  case "$out" in *"rc=1 port=5006"*)
      pass "dead unit: --reuse-only keeps the recorded port" ;;
    *) fail "dead unit: --reuse-only keeps the recorded port" "$out" ;; esac

  out=$(inactive_run y false)
  case "$out" in *"rc=0 port=5006"*)
      fail "dead unit: accepting the move re-allocates the port" "$out" ;;
    *"rc=0 port="*)
      pass "dead unit: accepting the move re-allocates the port" ;;
    *) fail "dead unit: accepting the move re-allocates the port" "$out" ;; esac
  case "$out" in *"and its service is running again"*)
      pass "dead unit: the move is confirmed only once it runs" ;;
    *) fail "dead unit: the move is confirmed only once it runs" "$out" ;; esac
  case "$out" in *"pointed an HTTPS route at 127.0.0.1:5006"*)
      pass "dead unit: warns that the old port's route is now empty" ;;
    *) fail "dead unit: warns that the old port's route is now empty" "$out" ;; esac

  # No supervisor to ask is its own answer — never "it is dead".
  out=$(
    OS="Linux"; FS_UNIT="$TMP/absent.service"; DRY_RUN=false
    eval "$FS_UNIT_ACTIVE_IMPL"
    have() { return 1; }
    fs_inactive_unit_report 2>&1 || true
  )
  case "$out" in *"can't ask this machine whether the file server is running"*)
      pass "dead unit: an unaskable supervisor is not reported as dead" ;;
    *) fail "dead unit: an unaskable supervisor is not reported as dead" "$out" ;; esac
  case "$out" in *"exists but is not active"*)
      fail "dead unit: no death claim without evidence" "$out" ;;
    *) pass "dead unit: no death claim without evidence" ;; esac
}

# =========================== what a failed probe write may claim about disk ====
# `fs_local_code`/`fs_local_curl` are scripted here rather than served: the cases
# that matter are a reachable server that refuses or drops the WRITE, and the
# claim under test is about wording, not transport.
probe_wording_run() { # probe_wording_run <put-code> <delete-code> <get-code> <folder>
  (
    OS="Linux"; DRY_RUN=false
    FS_LOCAL_PORT="5099"; FS_CRED="probe-secret"; FS_UNIT="$TMP/probe.service"
    FS_FOLDER="$4"
    PUT_CODE="$1"; DEL_CODE="$2"; GET_CODE="$3"
    fs_unit_active() { return 0; }
    fs_local_code() {
      local kind="$1" a last="" is_put=false is_del=false
      shift
      for a in "$@"; do
        case "$a" in -T) is_put=true ;; DELETE) is_del=true ;; esac
        last="$a"
      done
      case "$last" in */) printf '200'; return 0 ;; esac
      $is_put && { printf '%s' "$PUT_CODE"; return 0; }
      $is_del && { printf '%s' "$DEL_CODE"; return 0; }
      case "$kind" in none|wrong) printf '401' ;; *) printf '%s' "$GET_CODE" ;; esac
    }
    fs_local_curl() { return 1; }
    fs_local_service_ready 2>&1 || true
  )
}

test_probe_write_failure_wording() {
  local served="$TMP/probe-served" unknown="$TMP/probe-root-not-here" out
  mkdir -p "$served"
  # Refused write; DELETE unusable, but an authenticated GET proves the name is
  # free. (Unrecoverable root, so the local-disk fallback cannot answer either.)
  out=$(probe_wording_run 403 500 404 "$unknown")
  case "$out" in *"Nothing was left behind"*)
      pass "failed probe write: absence is stated, not residue" ;;
    *) fail "failed probe write: absence is stated, not residue" "$out" ;; esac
  case "$out" in *"Cleanup was not proven"*)
      fail "failed probe write: cleanup is not blamed for a write that failed" "$out" ;;
    *) pass "failed probe write: cleanup is not blamed for a write that failed" ;; esac

  # Write dropped mid-flight with no HTTP answer and nothing usable after it.
  out=$(probe_wording_run 000 000 000 "$unknown")
  case "$out" in *"got no answer from the file server"*)
      pass "dropped probe write: says the write got no answer" ;;
    *) fail "dropped probe write: says the write got no answer" "$out" ;; esac
  case "$out" in *"I can't tell whether"*)
      pass "dropped probe write: admits it cannot tell" ;;
    *) fail "dropped probe write: admits it cannot tell" "$out" ;; esac

  # A refused write whose name still answers IS residue — say so.
  out=$(probe_wording_run 403 405 200 "$unknown")
  case "$out" in *"still answers HTTP 200"*)
      pass "refused probe write: a name that still answers is reported" ;;
    *) fail "refused probe write: a name that still answers is reported" "$out" ;; esac

  # Recoverable root, probe never stored: the local check proves the name is free,
  # so nothing may claim a removal that never happened — and nothing may warn about
  # residue either.
  out=$(probe_wording_run 403 405 404 "$served")
  case "$out" in *"removed the exact local probe directly"*)
      fail "absent probe: no removal is claimed for a probe never stored" "$out" ;;
    *) pass "absent probe: no removal is claimed for a probe never stored" ;; esac
  case "$out" in *"probe"*"may remain"*|*"Cleanup was not proven"*)
      fail "absent probe: no residue warning for a probe never stored" "$out" ;;
    *) pass "absent probe: no residue warning for a probe never stored" ;; esac
}

# ===================================== a gateway we restarted, coming back ====
#
# The measured bug these cover: on a stock OpenClaw Docker install the tool-policy
# fix's `docker compose restart` returns at about t+1s and /healthz first answers
# at about t+6s, so verification graded a gateway that was still booting and every
# user on the recommended path saw failures that meant nothing was wrong.
#
# The waiter's bound is WALL CLOCK, so proving it must not cost a real minute:
# `date` and `sleep` are shadowed by a fake clock and `local_health_ok` (the real
# one lives in the verification module) by a scripted answer queue. The waiter
# calls both as plain commands — never through $( ) or a pipeline — so the queue
# index and the clock survive from one probe to the next. Facts are PRINTED from
# inside the subshell: globals assigned there die with it.
# A file, not a variable: every call runs inside $( ), so anything the helper
# assigns dies with that subshell.
GW_WAIT_OUT="$TMP/gw-wait.out"
run_gw_wait() { # run_gw_wait <entry-fn> <health-script> <clock-step> <dry-run> [port] [pre-timed-out]
  (
    FAKE_NOW=1000
    FAKE_SLEEPS=0
    HEALTH_PROBES=0
    HEALTH_SCRIPT="$2"
    CLOCK_STEP="$3"
    DRY_RUN="$4"
    GW_LOCAL_PORT="${5-8080}"
    GW_HEALTH_PATH="/healthz"
    GW_RESTART_COMPLETED_EPOCH=""
    GW_RESTART_LOCAL_WAIT_TIMED_OUT="${6-false}"
    date() { case "$1" in +%s) printf '%s\n' "$FAKE_NOW" ;; *) command date "$@" ;; esac; }
    sleep() { FAKE_SLEEPS=$((FAKE_SLEEPS+1)); FAKE_NOW=$((FAKE_NOW + CLOCK_STEP)); }
    local_health_ok() {
      HEALTH_PROBES=$((HEALTH_PROBES+1))
      answer="n"
      if [ -n "$HEALTH_SCRIPT" ]; then
        answer="${HEALTH_SCRIPT%% *}"
        case "$HEALTH_SCRIPT" in
          *' '*) HEALTH_SCRIPT="${HEALTH_SCRIPT#* }" ;;
          *)     HEALTH_SCRIPT="" ;;
        esac
      fi
      [ "$answer" = "y" ]
    }
    rc=0
    "$1" > "$GW_WAIT_OUT" 2>&1 || rc=$?
    printf 'rc=%s probes=%s sleeps=%s timedout=%s epoch=%s\n' \
      "$rc" "$HEALTH_PROBES" "$FAKE_SLEEPS" "$GW_RESTART_LOCAL_WAIT_TIMED_OUT" \
      "${GW_RESTART_COMPLETED_EPOCH:-none}"
  )
}

test_gateway_restart_wait() {
  local facts

  # The measured shape: refused, refused, refused, then answering. The waiter
  # hands off only after the answer holds a second later.
  facts=$(run_gw_wait gw_wait_local_health_after_restart "n n n y y" 1 false)
  expect_eq "restart wait: a booting gateway is waited out" \
    "$facts" "rc=0 probes=5 sleeps=4 timedout=false epoch=none"
  case "$(cat "$GW_WAIT_OUT")" in *"answering again"*)
      pass "restart wait: says the gateway came back" ;;
    *) fail "restart wait: says the gateway came back" "$(cat "$GW_WAIT_OUT")" ;; esac

  # One answer is not proof. A gateway that answers once and stops must NOT be
  # handed to verification on that answer — probes=5 is the whole point: the
  # first success was confirmed, failed confirmation, and the wait continued.
  facts=$(run_gw_wait gw_wait_local_health_after_restart "y n n y y" 1 false)
  expect_eq "restart wait: a single unheld answer is not readiness" \
    "$facts" "rc=0 probes=5 sleeps=4 timedout=false epoch=none"

  # An answer that holds on the very first probe still costs exactly one
  # confirming second, and nothing more.
  facts=$(run_gw_wait gw_wait_local_health_after_restart "y y" 1 false)
  expect_eq "restart wait: an already-up gateway costs one confirming second" \
    "$facts" "rc=0 probes=2 sleeps=1 timedout=false epoch=none"

  # Genuinely broken: the wait ENDS, records the fact, and reports honestly.
  # probes=61 (not the 90 cap) proves the wall-clock deadline is what stopped it.
  facts=$(run_gw_wait gw_wait_local_health_after_restart "" 1 false)
  expect_eq "restart wait: a gateway that never answers ends the wait" \
    "$facts" "rc=1 probes=61 sleeps=60 timedout=true epoch=none"
  local timed_out; timed_out=$(cat "$GW_WAIT_OUT")
  case "$timed_out" in *"re-run me"*) pass "restart wait: timeout hands back the remedy" ;;
    *) fail "restart wait: timeout hands back the remedy" "$timed_out" ;; esac
  case "$timed_out" in *"saved"*) pass "restart wait: timeout says the change survived" ;;
    *) fail "restart wait: timeout says the change survived" "$timed_out" ;; esac
  case "$timed_out" in *"real problem"*) pass "restart wait: timeout still calls a repeat failure real" ;;
    *) fail "restart wait: timeout still calls a repeat failure real" "$timed_out" ;; esac

  # `date` is wall time, not monotonic. A clock stepped BACKWARDS mid-wait can
  # never reach the deadline, so the probe cap is what has to end the loop —
  # this is the case that proves "bounded" is not merely "bounded in theory".
  facts=$(run_gw_wait gw_wait_local_health_after_restart "" -1 false)
  expect_eq "restart wait: a backwards clock cannot extend the wait" \
    "$facts" "rc=1 probes=90 sleeps=90 timedout=true epoch=none"

  # Nothing local to watch: no invented sleep, and it says why rather than
  # implying it verified something.
  facts=$(run_gw_wait gw_wait_local_health_after_restart "y y" 1 false "")
  expect_eq "restart wait: no local health endpoint probes nothing" \
    "$facts" "rc=0 probes=0 sleeps=0 timedout=false epoch=none"
  case "$(cat "$GW_WAIT_OUT")" in *"local health endpoint"*)
      pass "restart wait: no local health endpoint says so" ;;
    *) fail "restart wait: no local health endpoint says so" "$(cat "$GW_WAIT_OUT")" ;; esac

  # A run that promises to change nothing restarts nothing, so it waits for
  # nothing and records nothing.
  facts=$(run_gw_wait gw_note_restart_and_wait "y y" 1 true)
  expect_eq "restart wait: dry-run neither waits nor records" \
    "$facts" "rc=0 probes=0 sleeps=0 timedout=false epoch=none"

  # A fresh restart must not inherit the previous one's timeout.
  facts=$(run_gw_wait gw_note_restart_and_wait "y y" 1 false 8080 true)
  expect_eq "restart wait: a new restart clears an older timeout" \
    "$facts" "rc=0 probes=2 sleeps=1 timedout=false epoch=1000"

  # The wrapper ALWAYS succeeds. Its caller reads a nonzero as "drop the file
  # lane", so a spent wait must never escape as one.
  facts=$(run_gw_wait gw_note_restart_and_wait "" 1 false)
  expect_eq "restart wait: a spent wait never escapes as a failure" \
    "$facts" "rc=0 probes=61 sleeps=60 timedout=true epoch=1000"
}

test_restart_timing_note() {
  local out
  # Silent unless the dedicated wait genuinely expired: a models/auth/TLS failure
  # after a gateway that came back fine is not timing, and a blanket "maybe it was
  # the restart" would excuse a real breakage forever.
  out=$(
    GW_RESTART_COMPLETED_EPOCH=""
    GW_RESTART_LOCAL_WAIT_TIMED_OUT=true
    gw_restart_timing_note 2>&1
  )
  expect_eq "restart note: silent when no restart happened" "$out" ""
  out=$(
    GW_RESTART_COMPLETED_EPOCH="1000"
    GW_RESTART_LOCAL_WAIT_TIMED_OUT=false
    gw_restart_timing_note 2>&1
  )
  expect_eq "restart note: silent when the gateway came back" "$out" ""

  out=$(
    GW_RESTART_COMPLETED_EPOCH="1000"
    GW_RESTART_LOCAL_WAIT_TIMED_OUT=true
    GW_HEALTH_PATH="/healthz"
    gw_restart_timing_note 2>&1
  )
  case "$out" in *"may be timing"*) pass "restart note: names timing as a possible cause" ;;
    *) fail "restart note: names timing as a possible cause" "$out" ;; esac
  case "$out" in *"re-run me"*) pass "restart note: hands back the remedy" ;;
    *) fail "restart note: hands back the remedy" "$out" ;; esac
  case "$out" in *"no longer a likely explanation"*)
      pass "restart note: refuses to excuse a repeat failure" ;;
    *) fail "restart note: refuses to excuse a repeat failure" "$out" ;; esac
}

# Three callers restart a gateway, and each must be told about ITS OWN change.
# Naming the wrong one is worse than naming none: it reassures the operator about
# a change they never made. These guard exactly that.
test_restart_note_names_the_right_change() {
  local out
  # The tool policy sits nowhere near the HTTP layer, so the reassurance is
  # honest and load-bearing — it is what stops a correct change being undone.
  out=$(
    GW_RESTART_WHAT="tool-policy change"; GW_RESTART_WHAT_HTTP_SAFE=true
    GW_RESTART_COMPLETED_EPOCH="1000"; GW_RESTART_LOCAL_WAIT_TIMED_OUT=true
    GW_HEALTH_PATH="/healthz"; gw_restart_timing_note 2>&1
  )
  case "$out" in *"tool-policy change is saved"*)
      pass "restart note: tool policy names itself" ;;
    *) fail "restart note: tool policy names itself" "$out" ;; esac
  case "$out" in *"cannot break a gateway's HTTP"*)
      pass "restart note: tool policy keeps its HTTP-safe reassurance" ;;
    *) fail "restart note: tool policy keeps its HTTP-safe reassurance" "$out" ;; esac

  # The chat-endpoint flag IS the HTTP layer. Enabling a route should only ever
  # add one, but the epilogue is not the place to promise that — so the
  # reassurance must be ABSENT here even though the wording is otherwise shared.
  out=$(
    GW_RESTART_WHAT="chat-endpoint setting"; GW_RESTART_WHAT_HTTP_SAFE=false
    GW_RESTART_COMPLETED_EPOCH="1000"; GW_RESTART_LOCAL_WAIT_TIMED_OUT=true
    GW_HEALTH_PATH="/healthz"; gw_restart_timing_note 2>&1
  )
  case "$out" in *"chat-endpoint setting is saved"*)
      pass "restart note: chat endpoint names itself" ;;
    *) fail "restart note: chat endpoint names itself" "$out" ;; esac
  case "$out" in *"cannot break a gateway's HTTP"*)
      fail "restart note: chat endpoint must not claim HTTP safety" "$out" ;;
    *) pass "restart note: chat endpoint must not claim HTTP safety" ;; esac
  case "$out" in *"tool-policy"*)
      fail "restart note: chat endpoint never mentions a tool policy" "$out" ;;
    *) pass "restart note: chat endpoint never mentions a tool policy" ;; esac

  # The regression that prompted all of this: a Hermes user being told their
  # tool policy is safe, about a Hermes config change they made instead.
  out=$(
    GW_RESTART_WHAT="Hermes configuration change"; GW_RESTART_WHAT_HTTP_SAFE=true
    GW_RESTART_COMPLETED_EPOCH="1000"; GW_RESTART_LOCAL_WAIT_TIMED_OUT=true
    GW_HEALTH_PATH="/v1/health"; gw_restart_timing_note 2>&1
  )
  case "$out" in *"Hermes configuration change is saved"*)
      pass "restart note: Hermes names its own change" ;;
    *) fail "restart note: Hermes names its own change" "$out" ;; esac
  case "$out" in *"tool-policy"*|*"tool policy"*)
      fail "restart note: Hermes is never told about a tool policy" "$out" ;;
    *) pass "restart note: Hermes is never told about a tool policy" ;; esac

  # The spent-wait warning names the change too, and shares the same variable —
  # so it has to move with it rather than keeping a second hardcoded noun.
  GW_RESTART_WHAT="Hermes configuration change" \
    run_gw_wait gw_wait_local_health_after_restart "" 1 false >/dev/null
  out=$(cat "$GW_WAIT_OUT")
  case "$out" in *"Hermes configuration change is saved either way"*)
      pass "restart wait: the spent-wait warning names the change too" ;;
    *) fail "restart wait: the spent-wait warning names the change too" "$out" ;; esac

  # An unparameterised call must degrade to a neutral noun, never to whichever
  # caller happened to run last.
  out=$(
    DRY_RUN=true; gw_note_restart_and_wait
    GW_RESTART_COMPLETED_EPOCH="1000"; GW_RESTART_LOCAL_WAIT_TIMED_OUT=true
    GW_HEALTH_PATH="/healthz"; gw_restart_timing_note 2>&1
  )
  case "$out" in *"configuration change is saved"*)
      pass "restart note: an unnamed change degrades to a neutral noun" ;;
    *) fail "restart note: an unnamed change degrades to a neutral noun" "$out" ;; esac
  case "$out" in *"cannot break a gateway's HTTP"*)
      fail "restart note: an unnamed change claims no HTTP safety" "$out" ;;
    *) pass "restart note: an unnamed change claims no HTTP safety" ;; esac

  # The wrapper's arg -> global mapping, which every call site depends on.
  # DRY_RUN returns before the wait loop, so this stays instant.
  out=$(
    DRY_RUN=true
    gw_note_restart_and_wait "tool-policy change" true >/dev/null 2>&1
    printf '%s|%s' "$GW_RESTART_WHAT" "$GW_RESTART_WHAT_HTTP_SAFE"
  )
  expect_eq "restart wait: names and HTTP-safe flag reach the globals" \
    "$out" "tool-policy change|true"
  # A caller that omits the flag must not inherit a previous caller's `true`.
  out=$(
    DRY_RUN=true
    gw_note_restart_and_wait "tool-policy change" true >/dev/null 2>&1
    gw_note_restart_and_wait "chat-endpoint setting" >/dev/null 2>&1
    printf '%s|%s' "$GW_RESTART_WHAT" "$GW_RESTART_WHAT_HTTP_SAFE"
  )
  expect_eq "restart wait: an omitted HTTP-safe flag never inherits true" \
    "$out" "chat-endpoint setting|false"
}

# ============================ tool policy: restart, then wait (40-file-lane) ===
#
# The step's own arms, with the waiter stubbed so the two questions stay separate:
# the waiter's semantics are proved above, and what matters here is that a restart
# the step performs is followed by a wait, that a spent wait changes no verdict,
# and that a restart the operator declined is never reported as applied.
openclaw_fix_config() { # openclaw_fix_config <path> <ready|needs-fix>
  case "$2" in
    ready) printf '%s\n' '{"tools": {"profile": "coding", "alsoAllow": ["pdf"]}}' > "$1" ;;
    *)     printf '%s\n' '{"tools": {"profile": "coding"}}' > "$1" ;;
  esac
}

# The policy step's run_step stub, out here because a `case` inside $( ) trips
# bash's parser. Two knobs, set by each case in its own subshell:
#   POLICY_CFG         — the config the modelled config-set rewrites. The real
#                        run_step executes the command it prints and the suite's
#                        stub does not, so without this the step's re-read could
#                        never reach its success arm.
#   POLICY_RESTART_RC  — 1 declines the restart half, the way an operator does.
POLICY_CFG=""
POLICY_RESTART_RC=0
policy_run_step() { # policy_run_step <description> [command…]
  local desc="$1"
  case "$desc" in
    *restart*)
      if [ "$POLICY_RESTART_RC" != "0" ]; then
        printf '[run_step declined] %s\n' "$desc"
        return 1
      fi
      ;;
    *"tool policy"*) openclaw_fix_config "$POLICY_CFG" ready ;;
  esac
  printf '[run_step] %s\n' "$desc"
  return 0
}

test_tool_policy_restart_handoff() {
  local saved_home="$HOME" home="$TMP/policy-home" cfg out facts
  cfg="$home/.openclaw/openclaw.json"

  # A config-set the step believes succeeded, a restart it also runs, and a wait
  # that spends its whole budget. The lane must survive all three: the step's
  # caller treats any nonzero as "drop the file lane".
  facts=$(
    HOME="$home"; rm -rf "$home"; mkdir -p "$home/.openclaw" "$home/openclaw"
    : > "$home/openclaw/docker-compose.yml"
    openclaw_fix_config "$cfg" needs-fix
    CONFIRM_ANSWER="n"
    WAIT_CALLS=0
    GW_RESTART_COMPLETED_EPOCH=""
    GW_RESTART_LOCAL_WAIT_TIMED_OUT=false
    POLICY_CFG="$cfg"; POLICY_RESTART_RC=0
    run_step() { policy_run_step "$@"; }
    gw_wait_local_health_after_restart() {
      WAIT_CALLS=$((WAIT_CALLS+1))
      GW_RESTART_LOCAL_WAIT_TIMED_OUT=true
      return 1
    }
    rc=0
    openclaw_tool_policy_step > "$TMP/policy.out" 2>&1 || rc=$?
    printf 'rc=%s waits=%s epoch=%s timedout=%s\n' "$rc" "$WAIT_CALLS" \
      "${GW_RESTART_COMPLETED_EPOCH:-none}" "$GW_RESTART_LOCAL_WAIT_TIMED_OUT"
  )
  case "$facts" in "rc=0 waits=1 epoch="[0-9]*" timedout=true")
      pass "tool policy: a restart is followed by a wait, and a spent wait keeps the lane" ;;
    *) fail "tool policy: a restart is followed by a wait, and a spent wait keeps the lane" "$facts" ;; esac
  out=$(cat "$TMP/policy.out")
  case "$out" in *"openclaw.json is file-transfer-ready"*)
      pass "tool policy: the re-read claims the file, not the running gateway" ;;
    *) fail "tool policy: the re-read claims the file, not the running gateway" "$out" ;; esac
  case "$out" in *"was not restarted"*)
      fail "tool policy: a completed restart is not reported as skipped" "$out" ;;
    *) pass "tool policy: a completed restart is not reported as skipped" ;; esac

  # Restart declined. The policy is on disk, the running gateway is not on it,
  # and saying otherwise is how a green claim outruns the truth.
  facts=$(
    HOME="$home"; rm -rf "$home"; mkdir -p "$home/.openclaw" "$home/openclaw"
    : > "$home/openclaw/docker-compose.yml"
    openclaw_fix_config "$cfg" needs-fix
    CONFIRM_ANSWER="n"
    WAIT_CALLS=0
    GW_RESTART_COMPLETED_EPOCH=""
    POLICY_CFG="$cfg"; POLICY_RESTART_RC=1
    run_step() { policy_run_step "$@"; }
    gw_wait_local_health_after_restart() { WAIT_CALLS=$((WAIT_CALLS+1)); return 0; }
    rc=0
    openclaw_tool_policy_step > "$TMP/policy.out" 2>&1 || rc=$?
    printf 'rc=%s waits=%s epoch=%s\n' "$rc" "$WAIT_CALLS" "${GW_RESTART_COMPLETED_EPOCH:-none}"
  )
  expect_eq "tool policy: a declined restart waits for nothing and records nothing" \
    "$facts" "rc=0 waits=0 epoch=none"
  out=$(cat "$TMP/policy.out")
  case "$out" in *"still running with its old policy"*)
      pass "tool policy: a declined restart says the gateway kept the old policy" ;;
    *) fail "tool policy: a declined restart says the gateway kept the old policy" "$out" ;; esac

  # The by-hand arm asks for the change AND the restart in one step, so its
  # confirmation is the only signal either happened — and the boot window after
  # an operator's own restart is identical.
  facts=$(
    HOME="$home"; rm -rf "$home"; mkdir -p "$home/.openclaw"
    openclaw_fix_config "$cfg" needs-fix
    CONFIRM_ANSWER="y"
    WAIT_CALLS=0
    GW_RESTART_COMPLETED_EPOCH=""
    gw_wait_local_health_after_restart() { WAIT_CALLS=$((WAIT_CALLS+1)); return 0; }
    rc=0
    openclaw_tool_policy_step > "$TMP/policy.out" 2>&1 || rc=$?
    printf 'rc=%s waits=%s epoch=%s\n' "$rc" "$WAIT_CALLS" "${GW_RESTART_COMPLETED_EPOCH:-none}"
  )
  case "$facts" in "rc=0 waits=1 epoch="[0-9]*)
      pass "tool policy: a by-hand restart is waited out too" ;;
    *) fail "tool policy: a by-hand restart is waited out too" "$facts" ;; esac

  # A run that changes nothing restarts nothing, so there is nothing to wait for.
  facts=$(
    HOME="$home"; rm -rf "$home"; mkdir -p "$home/.openclaw" "$home/openclaw"
    : > "$home/openclaw/docker-compose.yml"
    openclaw_fix_config "$cfg" needs-fix
    DRY_RUN=true
    WAIT_CALLS=0
    GW_RESTART_COMPLETED_EPOCH=""
    gw_wait_local_health_after_restart() { WAIT_CALLS=$((WAIT_CALLS+1)); return 0; }
    rc=0
    openclaw_tool_policy_step > "$TMP/policy.out" 2>&1 || rc=$?
    printf 'rc=%s waits=%s epoch=%s\n' "$rc" "$WAIT_CALLS" "${GW_RESTART_COMPLETED_EPOCH:-none}"
  )
  expect_eq "tool policy: dry-run neither restarts nor waits" \
    "$facts" "rc=0 waits=0 epoch=none"

  HOME="$saved_home"
}

test_missing_rclone_continues() {
  local saved_home="$HOME" out facts
  # Without rclone no lane can be built at all, so the policy step must not have
  # changed a foreign gateway's config or restarted it for a lane that cannot
  # exist — and the operator must be told the run continues, because reading a
  # dead end is what makes someone abandon a setup that was about to succeed.
  facts=$(
    HOME="$TMP/rclone-home"; rm -rf "$HOME"; mkdir -p "$HOME"
    GW_KIND="openclaw"
    OS="Linux"
    CONFIRM_ANSWER="y"
    POLICY_CALLS=0
    have() { [ "$1" != "rclone" ] && command -v "$1" >/dev/null 2>&1; }
    linux_install_cmd() { printf 'apt\tsudo apt install rclone'; }
    openclaw_tool_policy_step() { POLICY_CALLS=$((POLICY_CALLS+1)); return 0; }
    rc=0
    setup_file_lane > "$TMP/rclone.out" 2>&1 || rc=$?
    printf 'rc=%s policy=%s\n' "$rc" "$POLICY_CALLS"
  )
  expect_eq "missing rclone: no policy change or restart is attempted" "$facts" "rc=0 policy=0"
  out=$(cat "$TMP/rclone.out")
  case "$out" in *"setup continues without file transfer"*)
      pass "missing rclone: says the run continues" ;;
    *) fail "missing rclone: says the run continues" "$out" ;; esac
  case "$out" in *"chat-only setup code"*)
      pass "missing rclone: says a code still comes" ;;
    *) fail "missing rclone: says a code still comes" "$out" ;; esac
  case "$out" in *"re-run me to add file transfer"*)
      pass "missing rclone: says installing it later is enough" ;;
    *) fail "missing rclone: says installing it later is enough" "$out" ;; esac
  case "$out" in *"skip the file lane for now"*)
      fail "missing rclone: the dead-end wording is gone" "$out" ;;
    *) pass "missing rclone: the dead-end wording is gone" ;; esac

  HOME="$saved_home"
}

printf 'file-lane readiness regressions — source modules + loopback fixtures\n'
test_gateway_restart_wait
test_restart_timing_note
test_restart_note_names_the_right_change
test_tool_policy_restart_handoff
test_missing_rclone_continues
test_port_allocation
test_duplicate_per_gateway_port
test_prebound_port
test_unsafe_existing_unit
test_unsafe_cross_gateway_unit
test_structural_unit_parsing
test_systemd_unit_writer
test_unit_writer_umask_is_scoped
test_tools_block_is_agent_readable
test_hermes_config
test_hermes_blank_and_comment_lines
test_hermes_recall_classification
test_hermes_printed_advice_parses
test_hermes_recall_edits
test_hermes_recall_operator_flow
test_hermes_recall_file_lane
test_hermes_recall_reach
test_hermes_checked_handoff
test_hermes_guidance
test_local_service_gate
test_reply_candidate_parity
test_agent_sentinel
test_agent_deadlines_and_cleanup
test_request_credential_controls
test_show_code_live_folder
test_shared_folder_gate
test_new_lane_folder_recording
test_file_lane_quick_tunnel_warning
test_lane_residue_report
test_inactive_unit_report
test_probe_write_failure_wording

printf '\nFILE READY RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ] || exit 1
[ "$PASS" -gt 0 ] || { printf 'no cases ran\n' >&2; exit 1; }
