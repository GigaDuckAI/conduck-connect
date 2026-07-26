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
GW_CERT_FP=""
FS_CERT_FP=""
OS="Linux"
STATE_DIR="$TMP/state"
GW_ID="test"
GW_LOCAL_PORT=""

say()  { printf '%s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
bad()  { printf '  ✗ %s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; return 1; }
have() { command -v "$1" >/dev/null 2>&1; }
env_get() {
  awk -F= -v key="$2" '$1 == key { sub(/^[^=]*=/, ""); value=$0 } END { print value }' "$1"
}

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

  printf '%s\n' "safe"$'\r'"injected" > "$STATE_DIR/fileserver-hermes.cred"
  if existing_fs_config; then
    fail "control-character file credential is refused" "unsafe credential was reused"
  elif $FS_EXISTING_UNSAFE; then
    pass "control-character file credential is refused"
  else
    fail "control-character file credential is refused" "unsafe state was not reported"
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
  AGENT_PROBE_TRANSPORT="$TRANSPORT"
  AGENT_PROBE_GW_CERT_FP="$GW_CERT_FP"
  AGENT_PROBE_FS_CERT_FP="$FS_CERT_FP"
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
  AGENT_PROBE_TRANSPORT="$TRANSPORT"
  AGENT_PROBE_GW_CERT_FP="$GW_CERT_FP"
  AGENT_PROBE_FS_CERT_FP="$FS_CERT_FP"
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
        fileServer.certFP)    printf '%s' "fixture-cert-fingerprint" ;;
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
    FS_URL=""; FS_CRED=""; FS_LOCAL_PORT=""; FS_CERT_FP=""; FS_FOLDER=""
    show_qr_recover_file_lane > "$output" 2>&1 \
      && [ "$FS_FOLDER" = "$live_folder" ] \
      && [ "$FS_URL" = "https://files.example.test" ] \
      && [ "$FS_LOCAL_PORT" = "7443" ] \
      && [ "$FS_CERT_FP" = "fixture-cert-fingerprint" ] \
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
test_hermes_config
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
