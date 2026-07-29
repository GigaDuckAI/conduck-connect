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

# The chat-only reach of the recall step is a property of the REAL configure_hermes,
# so the real one is lifted rather than re-stated here. Sourcing all of
# src/20-gateway.inc.sh would re-initialise the GW_* globals this suite sets above
# (GW_ID in particular), which is why only the two functions are taken. The declare
# guard turns a rename into a loud build failure instead of a silently skipped test.
# hermes_api_server_port comes along because configure_hermes calls it.
eval "$(sed -n '/^hermes_api_server_port()/,/^}/p;/^configure_hermes()/,/^}/p' "$ROOT/src/20-gateway.inc.sh")"
declare -F configure_hermes >/dev/null || { echo "could not lift configure_hermes out of src/20-gateway.inc.sh" >&2; exit 2; }
declare -F hermes_api_server_port >/dev/null || { echo "could not lift hermes_api_server_port out of src/20-gateway.inc.sh" >&2; exit 2; }

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
# configure_hermes sets GW_TOKEN/GW_AUTH/GW_LOCAL_PORT in the caller's shell, so it
# must NOT be graded through a command substitution — a subshell would swallow
# exactly the globals these cases check. Its transcript goes to a file instead and
# comes back in $out.
run_configure_hermes() {
  configure_hermes > "$TMP/reach-configure.out" 2>&1
  local rc=$?
  out=$(cat "$TMP/reach-configure.out")
  return $rc
}

test_hermes_recall_reach() {
  # configure_hermes writes the GW_* globals this suite's other cases rely on, so
  # they are saved and put back rather than left holding a fixture's values.
  local saved_home="$HOME" saved_id="${GW_ID:-}" saved_auth="${GW_AUTH:-}"
  local saved_token="${GW_TOKEN:-}" saved_port="${GW_LOCAL_PORT:-}"
  local saved_health="${GW_HEALTH_PATH:-}" saved_fs="${FS_URL:-}"
  local out rc body n_live n_recall n_verify cfg=".hermes/config.yaml"

  # --- the pairing wizard's chat-only path ---
  reset_recall_run
  recall_home "wizard"
  printf '%s\n' 'terminal:' '  cwd: "/tmp"' > "$HOME/$cfg"
  CONFIRM_ANSWER="n"
  run_configure_hermes; rc=$?
  expect_eq "reach: configure_hermes reports on a default-wide config" \
    "$(printf '%s' "$out" | grep -c 'Hermes memory scope')" "1"
  # The product call: report and offer, NEVER block. A gateway that chats fine is
  # still pairable; a fresh Hermes is default-wide, so a blocking gate here would
  # stop nearly every new user until they hand-edit YAML.
  expect_eq "reach: configure_hermes never blocks on an unproven scope" "$rc" "0"
  expect_eq "reach: configure_hermes still completes the gateway config" "$GW_AUTH" "bearer"
  expect_eq "reach: configure_hermes still reads the API server key" \
    "$GW_TOKEN" "fixture-api-server-key"
  # The step runs LAST, after the API server and its key are settled: everything
  # above it can die, and a config.yaml edit on a run about to abort would leave a
  # change the user never got to use.
  n_live=$(printf '%s\n' "$out" | grep -n 'API server already enabled' | head -1 | cut -d: -f1)
  n_recall=$(printf '%s\n' "$out" | grep -n 'Hermes memory scope' | head -1 | cut -d: -f1)
  if [ -n "$n_live" ] && [ -n "$n_recall" ] && [ "$n_recall" -gt "$n_live" ]; then
    pass "reach: the memory report follows the API-server result"
  else
    fail "reach: the memory report follows the API-server result" "enabled=$n_live recall=$n_recall"
  fi

  reset_recall_run
  printf '%s\n' 'platform_toolsets:' '  api_server: ["web", "memory"]' > "$HOME/$cfg"
  CONFIRM_ANSWER="y"
  run_configure_hermes; rc=$?
  expect_eq "reach: configure_hermes applies an accepted removal" \
    "$(grep -c 'api_server: \["web"\]' "$HOME/$cfg")" "1"
  expect_eq "reach: an accepted removal still returns zero" "$rc" "0"

  reset_recall_run
  printf '%s\n' 'platform_toolsets:' '  api_server: ["web", "memory"]' > "$HOME/$cfg"
  CONFIRM_ANSWER="n"
  run_configure_hermes; rc=$?
  expect_eq "reach: a declined removal does not fail the gateway step" "$rc" "0"
  expect_eq "reach: a declined removal changes nothing" \
    "$(grep -c 'api_server: \["web", "memory"\]' "$HOME/$cfg")" "1"

  # The exposure menu's "b" returns to the gateway choice, so configure_hermes can
  # run twice in one process. The second pass must not re-open a settled question.
  reset_recall_run
  printf '%s\n' 'platform_toolsets:' '  api_server: ["web", "memory"]' > "$HOME/$cfg"
  CONFIRM_ANSWER="n"
  run_configure_hermes
  CONFIRM_ANSWER="y"
  run_configure_hermes; rc=$?
  case "$out" in *"[confirm]"*)
      fail "reach: back-navigation does not re-ask the memory question" "asked again" ;;
    *) pass "reach: back-navigation does not re-ask the memory question" ;; esac
  expect_eq "reach: back-navigation changes nothing after a no" \
    "$(grep -c 'api_server: \["web", "memory"\]' "$HOME/$cfg")" "1"
  expect_eq "reach: back-navigation still completes the gateway step" "$rc" "0"

  reset_recall_run
  printf '%s\n' 'platform_toolsets:' '  api_server: ["web", "file"]' > "$HOME/$cfg"
  CONFIRM_ANSWER="y"
  run_configure_hermes; rc=$?
  expect_eq "reach: a clean scope is reported as clean" \
    "$(printf '%s' "$out" | grep -c "stays Conduck's")" "1"
  case "$out" in *"[confirm]"*) fail "reach: a clean scope asks nothing" "prompted anyway" ;;
    *) pass "reach: a clean scope asks nothing" ;; esac

  reset_recall_run
  printf '%s\n' 'platform_toolsets:' '  api_server: ["web", "memory"]' > "$HOME/$cfg"
  CONFIRM_ANSWER="y"
  DRY_RUN=true
  run_configure_hermes; rc=$?
  expect_eq "reach: dry-run reports through configure_hermes" \
    "$(printf '%s' "$out" | grep -c 'Hermes memory scope')" "1"
  expect_eq "reach: dry-run changes no Hermes config" \
    "$(grep -c 'api_server: \["web", "memory"\]' "$HOME/$cfg")" "1"
  expect_eq "reach: dry-run does not fail the gateway step" "$rc" "0"

  reset_recall_run
  CONFIRM_ANSWER="y"
  REUSE_ONLY=true
  run_configure_hermes; rc=$?
  expect_eq "reach: reuse-only reports through configure_hermes" \
    "$(printf '%s' "$out" | grep -c 'Hermes memory scope')" "1"
  expect_eq "reach: reuse-only changes no Hermes config" \
    "$(grep -c 'api_server: \["web", "memory"\]' "$HOME/$cfg")" "1"
  expect_eq "reach: reuse-only does not fail the gateway step" "$rc" "0"

  # Pinned as source, not behavior: `|| die` is a product decision the founder
  # owns, and a future edit that quietly adds one would otherwise only surface as
  # a support ticket from a user who cannot pair a working gateway.
  expect_eq "reach: the wizard call site is explicitly non-blocking" \
    "$(declare -f configure_hermes | grep -c 'hermes_recall_scope_step "\[web\]" || true')" "1"

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
  case "$out" in *"api_server: [web]"*)
      pass "reach: a gateway-only re-show suggests [web]" ;;
    *) fail "reach: a gateway-only re-show suggests [web]" "$out" ;; esac
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
  case "$out" in *"api_server: [web, file]"*)
      pass "reach: a re-show carrying a file lane suggests [web, file]" ;;
    *) fail "reach: a re-show carrying a file lane suggests [web, file]" "$out" ;; esac

  reset_recall_run
  REUSE_ONLY=true
  FS_URL="https://files.example.test"
  FS_CRED=""
  out=$(show_qr_recall_scope 2>&1); rc=$?
  case "$out" in *"api_server: [web, file]"*)
      fail "reach: an unrecoverable lane falls back to [web]" "suggested a lane the QR will not carry" ;;
    *) pass "reach: an unrecoverable lane falls back to [web]" ;; esac
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

printf 'file-lane readiness regressions — source modules + loopback fixtures\n'
test_port_allocation
test_duplicate_per_gateway_port
test_prebound_port
test_unsafe_existing_unit
test_unsafe_cross_gateway_unit
test_structural_unit_parsing
test_systemd_unit_writer
test_hermes_config
test_hermes_recall_classification
test_hermes_recall_edits
test_hermes_recall_operator_flow
test_hermes_recall_file_lane
test_hermes_recall_reach
test_hermes_guidance
test_local_service_gate
test_reply_candidate_parity
test_agent_sentinel
test_agent_deadlines_and_cleanup
test_request_credential_controls
test_show_code_live_folder

printf '\nFILE READY RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ] || exit 1
[ "$PASS" -gt 0 ] || { printf 'no cases ran\n' >&2; exit 1; }
