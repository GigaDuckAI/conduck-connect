#!/usr/bin/env bash
# shellcheck disable=SC2034
#
# run-host-environment-suite.sh — focused regressions for the host-environment
# paths: privilege escalation, Linux package-manager install hints, the systemd
# user-manager guard, systemd lingering, and the Tailscale escalation hints.
#
# SC2034 is file-wide, for the same reason run-file-lane-readiness-suite.sh
# carries it: the runtime globals each case sets (DOCTOR, COMPAT, OS, GW_KIND,
# DRY_RUN, TS_PORTS, RESERVED_PORTS, the FS_* and colour variables …) are read by
# functions lifted in at runtime, and ShellCheck cannot follow an `eval` into
# another file to see that use. They are required, not dead: the lifted bodies
# run under `set -u` and would abort without them.
#
# These paths are unreachable from the assembled-script suite because they only
# fire on a host that is MISSING something — a required tool, a reachable
# systemd user manager, lingering, or the rights Tailscale wants. No CI runner
# and no developer Mac reproduces those, so each case lifts the REAL function
# out of its src module and runs it against a simulated host (`id`, `have`,
# `loginctl`, `systemctl`, `tailscale` and the package managers are stubbed).
# Lifting rather than sourcing keeps a failure pointing at the owning source
# file, and avoids dragging in the CLI/global state a whole module expects.
#
# The package-NAME mapping is the fragile part and the reason per-manager cases
# are enumerated one by one: it encodes distro facts that rot SILENTLY. Arch has
# no `python3` package at all (its Python 3 IS `python`) and Gentoo wants
# category-qualified atoms, so a wrong entry prints an authoritative-looking
# command that dies with "target not found" — worse than generic advice. A
# mapping onto a library package (`openssl-libs`, `libssl3`) is equally wrong:
# those are routinely present while the CLI the script needs is missing.
#
# Loopback-free and side-effect-free: nothing is installed, no service is
# touched, no privileged command is ever really run.
#
#   bash tests/run-host-environment-suite.sh

set -u -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT="$HERE/.."
UT="$ROOT/src/10-utilities.inc.sh"
EX="$ROOT/src/30-exposure.inc.sh"
FL="$ROOT/src/40-file-lane.inc.sh"
SQ="$ROOT/src/91-show-code.inc.sh"
MN="$ROOT/src/99-main.inc.sh"
for f in "$UT" "$EX" "$FL" "$SQ" "$MN"; do
  [ -f "$f" ] || { printf 'missing %s\n' "$f" >&2; exit 2; }
done

# Lift the REAL bodies into this shell: definition line through the first
# column-0 `}`, which is the layout every module follows. The address deliberately
# stops at `()` and does not try to match the opening brace — BSD sed reads a `{`
# in an address as the start of a command block, so the brace-bearing form dies
# with "invalid command code" on macOS while passing on GNU sed.
lift() { # lift <file> <function-name>…
  local file="$1" fn body; shift
  for fn in "$@"; do
    body=$(sed -n "/^$fn()/,/^}/p" "$file")
    eval "$body"
    declare -F "$fn" >/dev/null \
      || { printf 'could not lift %s out of %s\n' "$fn" "$file" >&2; exit 2; }
  done
}

lift "$UT" priv_prefix linux_install_cmd preflight run_step mutate_guard \
           safe_display file_mode_is_open ensure_state_dir \
           setup_lock_proc_sig setup_lock_holder_state setup_lock_acquire setup_lock_release \
           saved_profile_exists choose_main_action json_query
lift "$EX" ts_priv_retry tailscale_expose ts_unmap sweep_stale_public_funnels \
           ts_target_for_port snapshot_port
lift "$FL" setup_file_lane fs_linger_enabled_linux fs_report_linger_linux
# The one-liner setters/accessors sit BETWEEN column-0 `}` lines, so the sed lift
# takes the whole run in one bite. Named here for what they bring, not for elegance:
# `show_qr_profile_invalid` carries show_qr_validate_profile with it, and json_get
# carries json_type + env_get. The bodies are the shipped ones either way.
lift "$SQ" show_qr_profile_invalid show_qr_is_https_host show_qr_is_port show_qr_pick_profile
lift "$UT" json_get
declare -F show_qr_validate_profile >/dev/null \
  || { printf 'show_qr_validate_profile did not come along with show_qr_profile_invalid\n' >&2; exit 2; }
declare -F json_type >/dev/null \
  || { printf 'json_type did not come along with json_get\n' >&2; exit 2; }

VERSION="0.13.0-test"      # the validator names it in its schema-mismatch reason
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/conduck-hostenv.XXXXXX") || exit 2
trap 'rm -rf "$TMPD"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); printf 'HOST ENV ✓ %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'HOST ENV ✗ %s — %s\n' "$1" "$2"; }

expect_eq() { # expect_eq <name> <actual> <expected>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got [$2], expected [$3]"; fi
}
expect_has() { # expect_has <name> <haystack> <needle>
  case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "output lacks [$3]" ;; esac
}
expect_lacks() { # expect_lacks <name> <haystack> <needle>
  case "$2" in *"$3"*) fail "$1" "output should not contain [$3]" ;; *) pass "$1" ;; esac
}

# ===================================================== priv_prefix (10-utils) ==
# Empty means two different things — "already root" and "no escalator here" —
# and every caller has to tell them apart, so both are pinned.
priv_of() { # priv_of <uid> [available-tool…]
  local uid="$1"; shift
  local tools=" $* "
  (
    id() { case "${1:-}" in -u) printf '%s\n' "$uid" ;; *) printf 'alice\n' ;; esac; }
    have() { case "$tools" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
    priv_prefix
  )
}

test_priv_prefix() {
  expect_eq "priv_prefix: root takes no prefix even with sudo installed" \
    "$(priv_of 0 sudo doas)" ""
  expect_eq "priv_prefix: non-root with sudo" "$(priv_of 1000 sudo)" "sudo"
  expect_eq "priv_prefix: non-root with doas only (Alpine/BSD-influenced)" \
    "$(priv_of 1000 doas)" "doas"
  expect_eq "priv_prefix: sudo wins when both are installed" \
    "$(priv_of 1000 sudo doas)" "sudo"
  expect_eq "priv_prefix: non-root with neither is empty, not a guess" \
    "$(priv_of 1000)" ""
}

# ============================================== linux_install_cmd (10-utils) ==
install_cmd() { # install_cmd <managers> <uid> <sudo|doas|none> <package…>
  local mgrs=" $1 " uid="$2" privtool="$3"; shift 3
  (
    id() { case "${1:-}" in -u) printf '%s\n' "$uid" ;; *) printf 'alice\n' ;; esac; }
    have() {
      case "$1" in
        sudo) [ "$privtool" = sudo ] ;;
        doas) [ "$privtool" = doas ] ;;
        *)    case "$mgrs" in *" $1 "*) return 0 ;; *) return 1 ;; esac ;;
      esac
    }
    linux_install_cmd "$@"
  )
}

test_install_cmd_per_manager() {
  # One case per manager: a manager whose invocation or package names drift is
  # exactly the failure this file exists to catch.
  expect_eq "install hint: apt-get (Debian/Ubuntu)" \
    "$(install_cmd apt-get 1000 sudo curl python3 openssl)" \
    "$(printf 'apt-get\tsudo apt-get update && sudo apt-get install -y curl python3 openssl')"
  expect_eq "install hint: dnf (Fedora/Rocky/Alma)" \
    "$(install_cmd dnf 1000 sudo curl python3 openssl)" \
    "$(printf 'dnf\tsudo dnf install -y curl python3 openssl')"
  expect_eq "install hint: yum (CentOS 7)" \
    "$(install_cmd yum 1000 sudo curl python3 openssl)" \
    "$(printf 'yum\tsudo yum install -y curl python3 openssl')"
  expect_eq "install hint: zypper is non-interactive (openSUSE)" \
    "$(install_cmd zypper 1000 sudo curl python3 openssl)" \
    "$(printf 'zypper\tsudo zypper --non-interactive install curl python3 openssl')"
  # `-S --needed`, never `-Sy`: a partial upgrade is the classic way to break an
  # Arch box, and a setup wizard has no business prescribing a full one either.
  expect_eq "install hint: pacman uses -S --needed, never -Sy (Arch/Manjaro)" \
    "$(install_cmd pacman 1000 sudo curl python3 openssl)" \
    "$(printf 'pacman\tsudo pacman -S --needed curl python openssl')"
  expect_eq "install hint: apk fetches the index inline (minimal images)" \
    "$(install_cmd apk 0 none curl python3 openssl)" \
    "$(printf 'apk\tapk add --no-cache curl python3 openssl')"
  expect_eq "install hint: xbps-install (Void)" \
    "$(install_cmd xbps-install 0 none curl python3 openssl)" \
    "$(printf 'xbps-install\txbps-install -Sy curl python3 openssl')"
  expect_eq "install hint: emerge takes category-qualified atoms (Gentoo)" \
    "$(install_cmd emerge 1000 sudo curl python3 openssl)" \
    "$(printf 'emerge\tsudo emerge --ask net-misc/curl dev-lang/python dev-libs/openssl')"
  expect_eq "install hint: emerge maps rclone too" \
    "$(install_cmd emerge 1000 sudo rclone)" \
    "$(printf 'emerge\tsudo emerge --ask net-misc/rclone')"
  # An unrecognised manager prints NOTHING — the caller then names the packages
  # instead. Honest beats wrong.
  expect_eq "install hint: unknown manager prints nothing" \
    "$(install_cmd '' 1000 sudo curl python3 openssl)" ""
  # Detection is by BINARY and first probe wins: /etc/os-release lies on
  # derivatives and on containers built FROM another base.
  expect_eq "install hint: first probe wins when two managers are installed" \
    "$(install_cmd 'apt-get dnf' 1000 sudo curl)" \
    "$(printf 'apt-get\tsudo apt-get update && sudo apt-get install -y curl')"
}

test_install_cmd_package_names() {
  # The mapping is per-manager, so `python3` must survive everywhere it is real
  # and become `python` on Arch only. A blanket rename would break Debian.
  expect_eq "package name: Arch has no python3 package — it is python" \
    "$(install_cmd pacman 1000 sudo python3)" \
    "$(printf 'pacman\tsudo pacman -S --needed python')"
  expect_eq "package name: apt-get keeps python3" \
    "$(install_cmd apt-get 1000 sudo python3)" \
    "$(printf 'apt-get\tsudo apt-get update && sudo apt-get install -y python3')"
  expect_eq "package name: dnf keeps python3" \
    "$(install_cmd dnf 1000 sudo python3)" \
    "$(printf 'dnf\tsudo dnf install -y python3')"
  expect_eq "package name: apk keeps python3" \
    "$(install_cmd apk 0 none python3)" \
    "$(printf 'apk\tapk add --no-cache python3')"
  expect_eq "package name: Gentoo python3 is dev-lang/python" \
    "$(install_cmd emerge 1000 sudo python3)" \
    "$(printf 'emerge\tsudo emerge --ask dev-lang/python')"
  # pacman maps python3 and NOTHING else — a stray rename of curl/openssl would
  # print a target that does not exist.
  expect_eq "package name: pacman does not rename curl" \
    "$(install_cmd pacman 1000 sudo curl)" \
    "$(printf 'pacman\tsudo pacman -S --needed curl')"
  # Never map onto a library package: `openssl-libs`/`libssl3` are routinely
  # installed while the `openssl` CLI this script needs is absent.
  local out
  out=$(install_cmd dnf 1000 sudo openssl)
  expect_lacks "package name: openssl never maps to a library package (dnf)" "$out" "openssl-libs"
  out=$(install_cmd apt-get 1000 sudo openssl)
  expect_lacks "package name: openssl never maps to a library package (apt-get)" "$out" "libssl"
}

test_install_cmd_privilege() {
  expect_eq "install hint: root gets a bare command (no sudo binary in the image)" \
    "$(install_cmd apt-get 0 none curl)" \
    "$(printf 'apt-get\tapt-get update && apt-get install -y curl')"
  expect_eq "install hint: doas box gets doas, not sudo" \
    "$(install_cmd apt-get 1000 doas curl)" \
    "$(printf 'apt-get\tdoas apt-get update && doas apt-get install -y curl')"
  # Non-root with no escalator: the command is printed BARE rather than
  # inventing a dependency on a binary this box does not have. preflight adds
  # the "run it as root" line — see test_preflight_privilege_note.
  expect_eq "install hint: non-root with no sudo/doas prints the bare command" \
    "$(install_cmd apt-get 1000 none curl)" \
    "$(printf 'apt-get\tapt-get update && apt-get install -y curl')"
  expect_eq "install hint: every apt-get sub-command carries the prefix" \
    "$(install_cmd apt-get 1000 sudo curl)" \
    "$(printf 'apt-get\tsudo apt-get update && sudo apt-get install -y curl')"
}

# ======================================================== preflight (10-utils) ==
# `absent`, not `missing`: preflight declares its OWN `local missing=()`, which
# would shadow the stub's list at every `need` call site and abort under `set -u`.
preflight_out() { # preflight_out <absent-tools> <managers> <uid> <sudo|doas|none> <uname>
  local absent=" $1 " mgrs=" $2 " uid="$3" privtool="$4" os="$5"
  (
    DOCTOR=${DOCTOR_MODE:-false}; COMPAT=${COMPAT_MODE:-false}
    bad()  { printf 'bad: %s\n' "$*"; }
    note() { printf 'note: %s\n' "$*"; }
    die()  { printf 'die: %s\n' "$*"; return 0; }
    uname() { printf '%s\n' "$os"; }
    id() { case "${1:-}" in -u) printf '%s\n' "$uid" ;; *) printf 'alice\n' ;; esac; }
    need() { case "$absent" in *" $1 "*) return 1 ;; *) return 0 ;; esac; }
    have() {
      case "$1" in
        sudo) [ "$privtool" = sudo ] ;;
        doas) [ "$privtool" = doas ] ;;
        *)    case "$mgrs" in *" $1 "*) return 0 ;; *) return 1 ;; esac ;;
      esac
    }
    preflight
  ) 2>&1
}

test_preflight() {
  expect_eq "preflight: says nothing when every tool is present" \
    "$(preflight_out '' apt-get 1000 sudo Linux)" ""
  local out
  out=$(preflight_out "curl python3" apt-get 1000 sudo Linux)
  expect_has "preflight: reports ALL missing tools together" "$out" "curl python3"
  expect_has "preflight: names the DETECTED manager, not Debian's by default" "$out" "Detected apt-get"
  expect_has "preflight: hands over a runnable command" "$out" "sudo apt-get install -y curl python3"
  expect_has "preflight: still exits hard after the hint" "$out" "die:"

  out=$(preflight_out "curl" '' 1000 sudo Linux)
  expect_has "preflight: unknown manager falls back to naming the packages" \
    "$out" "Install with your distribution's package manager:  curl"
  expect_lacks "preflight: unknown manager claims no detection" "$out" "Detected"

  out=$(preflight_out "curl" '' 1000 sudo Darwin)
  expect_has "preflight: macOS gets the Homebrew line" "$out" "brew install curl"
  expect_lacks "preflight: macOS never gets a Linux manager hint" "$out" "Detected"

  # The two standalone checks never mint a credential, so openssl is not gated
  # on them — gating a live diagnostic on a tool it does not use is a false stop.
  expect_eq "preflight: --check-adapter does not require openssl" \
    "$(DOCTOR_MODE=true preflight_out openssl apt-get 1000 sudo Linux)" ""
  expect_eq "preflight: --check-server does not require openssl" \
    "$(COMPAT_MODE=true preflight_out openssl apt-get 1000 sudo Linux)" ""
  out=$(preflight_out openssl apt-get 1000 sudo Linux)
  expect_has "preflight: the wizard DOES require openssl" "$out" "openssl"
}

test_preflight_privilege_note() {
  local out
  out=$(preflight_out curl apt-get 1000 none Linux)
  expect_has "preflight: non-root with no sudo/doas is told to become root" \
    "$out" "Run that as root: this shell is neither root nor has sudo/doas."
  # Root already IS root, so the same empty prefix must NOT produce that line.
  out=$(preflight_out curl apk 0 none Linux)
  expect_lacks "preflight: root is not told to become root" "$out" "Run that as root"
  expect_lacks "preflight: root's command carries no escalation prefix" "$out" "sudo apk"
  out=$(preflight_out curl apt-get 1000 sudo Linux)
  expect_lacks "preflight: a sudo box is not told to become root" "$out" "Run that as root"
  out=$(preflight_out curl apt-get 1000 doas Linux)
  expect_lacks "preflight: a doas box is not told to become root" "$out" "Run that as root"
}

# ======================================= systemd user-manager guard (40-file) ==
# `systemctl --user show-environment` proves "a user manager is reachable from
# THIS shell" — which is the thing that decides whether a unit could ever start.
# It must be checked BEFORE a credential is minted or a unit is written, or the
# run leaves a dead service behind.
file_lane_guard_out() { # file_lane_guard_out <systemctl yes/no> <show-environment rc>
  local sysctl_present="$1" showenv_rc="$2"
  (
    BOLD=""; RESET=""; DIM=""; GREEN=""; RED=""; YELLOW=""
    OS="Linux"; GW_KIND="custom"; GW_ID="custom-test"
    DRY_RUN=false; REUSE_ONLY=false; FS_EXISTING_UNSAFE=false
    FS_CRED=""; FS_URL=""; FS_FOLDER=""; FS_LOCAL_PORT=""; FS_REACH=""
    FS_CRED_LEGACY_ARGV=false; TRANSPORT="tailscale"; SCOPE="private"
    FS_PORT_ALLOCATION_REASON=""
    say()  { printf '%s\n' "$*"; }
    head_(){ printf '== %s\n' "$*"; }
    ok()   { printf 'ok: %s\n' "$*"; }
    bad()  { printf 'bad: %s\n' "$*"; }
    note() { printf 'note: %s\n' "$*"; }
    warn() { printf 'warn: %s\n' "$*"; }
    confirm() { return 0; }
    ask()  { printf '%s' "$2"; }
    plan_add() { :; }
    mutate_guard() { return 0; }
    hermes_residual_state_note() { :; }
    install_conduck_tools_block() { :; }
    existing_fs_config() { return 1; }
    fs_systemd_value_safe() { return 0; }
    fs_local_service_ready() { return 0; }
    openclaw_tool_policy_step() { return 0; }
    hermes_file_readiness_step() { return 0; }
    install_conduck_hermes_block() { return 0; }
    write_fs_unit_linux() { printf 'REACHED write_fs_unit_linux\n'; return 0; }
    write_fs_unit_mac()   { return 0; }
    tailscale_dns_name()  { printf 'host.example.ts.net'; }
    ts_port_for_backend() { printf ''; }
    pick_public_port()    { printf 'REACHED pick_public_port\n'; return 1; }
    drop_file_lane()      { FS_CRED=""; FS_URL=""; }
    allocate_fs_local_port() {
      printf 'REACHED allocate_fs_local_port\n'
      FS_PORT_ALLOCATION_REASON="stub: no port"; return 1
    }
    have() {
      case "$1" in
        rclone)    return 0 ;;
        systemctl) [ "$sysctl_present" = yes ] ;;
        *)         return 1 ;;
      esac
    }
    systemctl() { return "$showenv_rc"; }
    setup_file_lane
  ) 2>&1
}

test_file_lane_service_manager_guard() {
  local out
  out=$(file_lane_guard_out no 0)
  expect_has "file lane: no systemctl at all (Alpine/OpenRC) is caught" \
    "$out" "No reachable systemd user manager here"
  expect_lacks "file lane: no systemctl stops BEFORE a port is allocated" \
    "$out" "REACHED allocate_fs_local_port"
  expect_lacks "file lane: no systemctl stops BEFORE a unit is written" \
    "$out" "REACHED write_fs_unit_linux"
  expect_has "file lane: the skip offers a hand-paired manual route" \
    "$out" "Advanced: under your own supervisor"

  # systemctl exists but the USER manager is unreachable — the su/sudo-shell and
  # cloud-init case, which a `have systemctl` test alone would sail straight past.
  out=$(file_lane_guard_out yes 1)
  expect_has "file lane: unreachable user manager (su/sudo shell) is caught" \
    "$out" "No reachable systemd user manager here"
  expect_lacks "file lane: unreachable user manager allocates no port" \
    "$out" "REACHED allocate_fs_local_port"
  expect_has "file lane: the fix (log in directly, not 'su -') is spelled out" \
    "$out" "log in directly as this user"

  out=$(file_lane_guard_out yes 0)
  expect_lacks "file lane: a healthy user manager is not blocked" \
    "$out" "No reachable systemd user manager here"
  expect_has "file lane: a healthy user manager proceeds to port allocation" \
    "$out" "REACHED allocate_fs_local_port"
}

# ============================================== systemd lingering (40-file) ==
# The REAL run_step and mutate_guard are lifted, so these cases prove the whole
# prompt-and-run path, not a stand-in for it.
linger_out() { # linger_out <loginctl yes/no> <before> <after> <uid> <priv> <confirm y/n>
  local lgc="$1" before="$2" after="$3" uid="$4" privtool="$5" answer="$6"
  (
    BOLD=""; RESET=""
    DRY_RUN=${DRY:-false}; REUSE_ONLY=${RO:-false}
    STATE="$before"
    ok()   { printf 'ok: %s\n' "$*"; }
    note() { printf 'note: %s\n' "$*"; }
    warn() { printf 'warn: %s\n' "$*"; }
    say()  { printf '%s\n' "$*"; }
    plan_add() { printf 'plan: %s\n' "$*"; }
    die()  { printf 'die: %s\n' "$*"; exit 9; }
    confirm() { [ "$answer" = y ]; }
    id() { case "${1:-}" in -u) printf '%s\n' "$uid" ;; -un) printf 'alice\n' ;; esac; }
    have() {
      case "$1" in
        loginctl) [ "$lgc" = yes ] ;;
        sudo)     [ "$privtool" = sudo ] ;;
        doas)     [ "$privtool" = doas ] ;;
        *)        return 1 ;;
      esac
    }
    loginctl() {
      case "${1:-}" in
        show-user)     printf 'Linger=%s\n' "$STATE" ;;
        enable-linger) printf 'exec: loginctl enable-linger %s\n' "${2:-}"; STATE="$after" ;;
      esac
    }
    sudo() { printf 'exec: via sudo\n'; "$@"; }
    doas() { printf 'exec: via doas\n'; "$@"; }
    fs_report_linger_linux
    printf 'rc=%s\n' "$?"
  ) 2>&1
}

test_linger() {
  local out
  out=$(linger_out yes yes yes 1000 sudo y)
  expect_lacks "linger: already on stays silent (the common 24/7 box)" "$out" "Lingering is off"
  expect_has "linger: already on returns success" "$out" "rc=0"

  out=$(linger_out yes no yes 1000 sudo y)
  expect_has "linger: off + accepted runs it through sudo" \
    "$out" "loginctl enable-linger alice"
  expect_has "linger: off + accepted confirms the new state" \
    "$out" "ok: Lingering is on for 'alice'"

  out=$(linger_out yes no yes 1000 sudo n)
  expect_has "linger: declining is honoured, not retried" "$out" "Skipped:"
  expect_has "linger: declining still warns the lane is session-bound" \
    "$out" "it only answers while 'alice' has a"
  expect_lacks "linger: declining never claims success" "$out" "ok: Lingering is on"

  # Ran, returned 0, and STILL did not take — a claim of success here would be a lie.
  out=$(linger_out yes no no 1000 sudo y)
  expect_lacks "linger: a no-op enable is not reported as success" "$out" "ok: Lingering is on"
  expect_has "linger: a no-op enable hands back the command to run later" \
    "$out" "Make it permanent any time with:  sudo loginctl enable-linger alice"

  # No loginctl means UNKNOWN, never "off" — the two need different words.
  out=$(linger_out no no no 1000 sudo y)
  expect_has "linger: no loginctl reports unknown, not off" "$out" "No 'loginctl' on this box"
  expect_lacks "linger: no loginctl does not assert lingering is off" "$out" "Lingering is off"
  expect_has "linger: no loginctl is not fatal" "$out" "rc=0"
}

test_linger_privilege() {
  local out
  out=$(linger_out yes no yes 0 none y)
  expect_has "linger: a root shell runs loginctl bare" "$out" "I'd like to run:  loginctl enable-linger alice"
  expect_lacks "linger: a root shell never prefixes sudo" "$out" "sudo"

  out=$(linger_out yes no yes 1000 doas y)
  expect_has "linger: a doas box uses doas" "$out" "I'd like to run:  doas loginctl enable-linger alice"
  expect_lacks "linger: a doas box never prefixes sudo" "$out" "sudo"

  out=$(linger_out yes no yes 1000 sudo y)
  expect_has "linger: a sudo box uses sudo" "$out" "I'd like to run:  sudo loginctl enable-linger alice"

  # Non-root with no escalator: the command is printed bare AND the missing
  # privilege is named, so the user is not left retrying a command that cannot work.
  out=$(linger_out yes no no 1000 none y)
  expect_has "linger: non-root with no sudo/doas is told it needs root" \
    "$out" "That one needs root (no sudo/doas here)."
  expect_has "linger: non-root with no escalator still shows the bare command" \
    "$out" "loginctl enable-linger alice"
}

test_linger_modes() {
  local out
  # --reuse-only forbids host changes. Offering this through run_step would reach
  # mutate_guard's `die` and kill a run whose whole point was to re-emit an
  # existing lane, so the fact is stated and nothing is changed.
  out=$(RO=true linger_out yes no yes 1000 sudo y)
  expect_has "linger: --reuse-only states the fact and changes nothing" \
    "$out" "(reuse-only: changing nothing.)"
  expect_has "linger: --reuse-only hands over the command" \
    "$out" "sudo loginctl enable-linger alice"
  expect_lacks "linger: --reuse-only must NOT die" "$out" "die:"
  expect_lacks "linger: --reuse-only runs nothing" "$out" "exec:"
  expect_has "linger: --reuse-only returns success" "$out" "rc=0"

  out=$(DRY=true linger_out yes no yes 1000 sudo y)
  expect_has "linger: --dry-run plans the command" "$out" "plan: RUN  sudo loginctl enable-linger alice"
  expect_lacks "linger: --dry-run runs nothing" "$out" "exec:"
  expect_has "linger: --dry-run returns success" "$out" "rc=0"

  # Both flags: dry-run wins, so the plan is complete rather than truncated by
  # the reuse-only early return.
  out=$(DRY=true RO=true linger_out yes no yes 1000 sudo y)
  expect_has "linger: --dry-run + --reuse-only still plans the command" \
    "$out" "plan: RUN  sudo loginctl enable-linger alice"
  expect_lacks "linger: --dry-run + --reuse-only must NOT die" "$out" "die:"
  expect_lacks "linger: --dry-run + --reuse-only runs nothing" "$out" "exec:"
}

# ================================= Tailscale escalation hints (30-exposure) ==
# An empty prefix means two OPPOSITE things, and the retry offer has to tell them
# apart. Reprinting the identical command to a root shell that just watched it
# fail is noise; printing `sudo` on a box that has neither sudo nor doas swaps
# the real fault for "command not found".
priv_retry_out() { # priv_retry_out <uid> <sudo|doas|none> <accept y/n> <why> <bare-cmd>…
  local uid="$1" privtool="$2" accept="$3"; shift 3
  (
    id() { case "${1:-}" in -u) printf '%s\n' "$uid" ;; *) printf 'alice\n' ;; esac; }
    have() {
      case "$1" in
        sudo) [ "$privtool" = sudo ] ;;
        doas) [ "$privtool" = doas ] ;;
        *)    return 1 ;;
      esac
    }
    warn() { printf 'warn: %s\n' "$*"; }
    print_and_wait() { printf 'ACTION: %s\nWHY: %s\nRETRY: %s\n' "$1" "$2" "$3"; [ "$accept" = y ]; }
    ts_priv_retry "$@"
    printf 'rc=%s\n' "$?"
  ) 2>&1
}

test_ts_priv_retry() {
  local out why="Tailscale serve/funnel often needs operator or root rights."
  out=$(priv_retry_out 1000 sudo y "$why" "tailscale serve --https=443 http://127.0.0.1:8080")
  expect_has "ts retry: carries its explanation action" \
    "$out" "ACTION: exposure.tailscale.privileged_retry"
  expect_has "ts retry: sudo box gets the prefixed retry" \
    "$out" "RETRY: sudo tailscale serve --https=443 http://127.0.0.1:8080"
  expect_has "ts retry: an accepted retry reports success" "$out" "rc=0"

  out=$(priv_retry_out 1000 doas y "$why" "tailscale serve --https=443 http://127.0.0.1:8080")
  expect_has "ts retry: doas box gets doas, not sudo" \
    "$out" "RETRY: doas tailscale serve --https=443 http://127.0.0.1:8080"
  expect_lacks "ts retry: doas box never prints sudo" "$out" "sudo tailscale"

  # Root: no retry exists. Offering one would reprint the command that just failed.
  out=$(priv_retry_out 0 none y "$why" "tailscale serve --https=443 http://127.0.0.1:8080")
  expect_lacks "ts retry: a root shell is offered NO retry" "$out" "RETRY:"
  expect_has "ts retry: a root shell is told why there is nothing to retry" \
    "$out" "already root, so there are no higher rights to retry with"
  expect_has "ts retry: a root shell reports the distinct no-retry code" "$out" "rc=2"

  # Non-root, no escalator: bare command, plus the instruction that makes it work.
  out=$(priv_retry_out 1000 none y "$why" "tailscale serve --https=443 http://127.0.0.1:8080")
  expect_has "ts retry: no escalator prints the command BARE" \
    "$out" "RETRY: tailscale serve --https=443 http://127.0.0.1:8080"
  expect_lacks "ts retry: no escalator never guesses sudo" "$out" "sudo tailscale"
  expect_lacks "ts retry: no escalator never guesses doas" "$out" "doas tailscale"
  expect_has "ts retry: no escalator says to use a root shell" \
    "$out" "neither sudo nor doas, so run it from a root shell"
  # `su -c` is never synthesised: it assumes `su`, and quotes badly around the
  # two-command form.
  expect_lacks "ts retry: no escalator never synthesises su -c" "$out" "su -c"

  out=$(priv_retry_out 1000 sudo n "$why" "tailscale serve --https=443 http://127.0.0.1:8080")
  expect_has "ts retry: a declined retry is reported as declined, not as no-retry" "$out" "rc=1"

  # Two-command form: each segment carries its own prefix, joined exactly as the
  # shell would run them.
  out=$(priv_retry_out 1000 sudo y "$why" "tailscale funnel --https=10000 off" "tailscale serve --https=10000 off")
  expect_has "ts retry: two-command retry prefixes EACH command" \
    "$out" "RETRY: sudo tailscale funnel --https=10000 off; sudo tailscale serve --https=10000 off"
  out=$(priv_retry_out 1000 doas y "$why" "tailscale funnel --https=10000 off" "tailscale serve --https=10000 off")
  expect_has "ts retry: two-command retry works on doas too" \
    "$out" "RETRY: doas tailscale funnel --https=10000 off; doas tailscale serve --https=10000 off"
  out=$(priv_retry_out 1000 none y "$why" "tailscale funnel --https=10000 off" "tailscale serve --https=10000 off")
  expect_has "ts retry: two-command retry stays bare with no escalator" \
    "$out" "RETRY: tailscale funnel --https=10000 off; tailscale serve --https=10000 off"
  expect_lacks "ts retry: a bare two-command retry has no leading space" "$out" "RETRY:  "
}

# The retry offer reached through its real callers, with `tailscale` refusing.
expose_out() { # expose_out <uid> <sudo|doas|none> <accept y/n> <before> <after> [demote]
  local uid="$1" privtool="$2" accept="$3" before="$4" after="$5" demote="${6:-no}"
  (
    BOLD=""; RESET=""; DRY_RUN=false; REUSE_ONLY=false
    APPLIED=(); FS_APPLIED=(); TS_STATE_KNOWN=true
    TS_PORTS=(); [ -n "$before" ] && TS_PORTS=("$before")
    say()  { printf '%s\n' "$*"; }
    ok()   { printf 'ok: %s\n' "$*"; }
    bad()  { printf 'bad: %s\n' "$*"; }
    note() { printf 'note: %s\n' "$*"; }
    warn() { printf 'warn: %s\n' "$*"; }
    plan_add() { :; }
    mutate_guard() { return 0; }
    confirm() { return 0; }
    id() { case "${1:-}" in -u) printf '%s\n' "$uid" ;; *) printf 'alice\n' ;; esac; }
    have() {
      case "$1" in
        sudo) [ "$privtool" = sudo ] ;;
        doas) [ "$privtool" = doas ] ;;
        *)    return 1 ;;
      esac
    }
    print_and_wait() { printf 'ACTION: %s\nWHY: %s\nRETRY: %s\n' "$1" "$2" "$3"; [ "$accept" = y ]; }
    # Tailscale refuses everything — the whole point of this path.
    tailscale() { printf 'tailscale refused: %s\n' "$*" >&2; return 1; }
    # The post-attempt re-read lands on whatever state the case declares.
    ts_targets() { TS_PORTS=(); [ -n "$after" ] && TS_PORTS=("$after"); }
    [ "$demote" = yes ] && TS_PORTS=("443"$'\t'"funnel"$'\t'"http://127.0.0.1:8080")
    tailscale_expose 443 8080 false gateway
    printf 'rc=%s\n' "$?"
  ) 2>/dev/null
}

test_expose_retry() {
  local out mapped="443"$'\t'"serve"$'\t'"http://127.0.0.1:8080"
  out=$(expose_out 1000 sudo y "" "$mapped")
  expect_has "expose: a refused command offers the sudo retry" \
    "$out" "RETRY: sudo tailscale serve --bg --https=443 http://127.0.0.1:8080"
  expect_has "expose: an accepted retry that took is confirmed" "$out" "ok: Confirmed"
  expect_has "expose: an accepted retry that took returns success" "$out" "rc=0"

  # Declining stops the run: unchanged behaviour, and the reason the no-retry
  # code has to be distinct from the declined code.
  out=$(expose_out 1000 sudo n "" "$mapped")
  expect_lacks "expose: a declined retry never claims confirmation" "$out" "ok: Confirmed"
  expect_has "expose: a declined retry fails the exposure" "$out" "rc=1"

  # Root: no retry offered, and the run falls THROUGH to verification — a command
  # can be refused while the mapping is already right, and only the status re-read
  # can tell those apart.
  out=$(expose_out 0 none y "" "$mapped")
  expect_lacks "expose: a root shell is offered no retry" "$out" "RETRY:"
  expect_has "expose: a root shell still verifies the real state" "$out" "ok: Confirmed"
  expect_has "expose: a refused-but-correct state on root succeeds" "$out" "rc=0"

  out=$(expose_out 0 none y "" "")
  expect_has "expose: a root shell with no mapping still fails closed" \
    "$out" "treating as failed"
  expect_has "expose: a root shell with no mapping returns failure" "$out" "rc=1"

  out=$(expose_out 1000 none y "" "$mapped")
  expect_has "expose: no escalator prints the bare retry" \
    "$out" "RETRY: tailscale serve --bg --https=443 http://127.0.0.1:8080"
  expect_has "expose: no escalator says to use a root shell" "$out" "run it from a root shell"

  # funnel→serve flip: the demote must be prefixed too, or the port stays public.
  out=$(expose_out 1000 sudo y "" "$mapped" yes)
  expect_has "expose: a funnel→serve flip prefixes the demote AND the remap" \
    "$out" "RETRY: sudo tailscale funnel --https=443 off; sudo tailscale serve --bg --https=443 http://127.0.0.1:8080"
  out=$(expose_out 1000 none y "" "$mapped" yes)
  expect_has "expose: a flip with no escalator stays bare in both halves" \
    "$out" "RETRY: tailscale funnel --https=443 off; tailscale serve --bg --https=443 http://127.0.0.1:8080"
}

unmap_out() { # unmap_out <uid> <sudo|doas|none>
  local uid="$1" privtool="$2"
  (
    BOLD=""; RESET=""; DRY_RUN=false; REUSE_ONLY=false
    APPLIED=(); FS_APPLIED=(); TS_STATE_KNOWN=true; TS_PORTS=()
    ok()   { printf 'ok: %s\n' "$*"; }
    note() { printf 'note: %s\n' "$*"; }
    warn() { printf 'warn: %s\n' "$*"; }
    plan_add() { :; }
    mutate_guard() { return 0; }
    id() { case "${1:-}" in -u) printf '%s\n' "$uid" ;; *) printf 'alice\n' ;; esac; }
    have() {
      case "$1" in
        sudo) [ "$privtool" = sudo ] ;;
        doas) [ "$privtool" = doas ] ;;
        *)    return 1 ;;
      esac
    }
    print_and_wait() { printf 'ACTION: %s\nWHY: %s\nRETRY: %s\n' "$1" "$2" "$3"; return 0; }
    tailscale() { return 1; }
    ts_targets() { TS_PORTS=(); }
    ts_unmap 8443 serve
  ) 2>&1
}

test_unmap_retry() {
  local out
  out=$(unmap_out 1000 sudo)
  expect_has "unmap: a refused removal offers the sudo retry" \
    "$out" "RETRY: sudo tailscale serve --https=8443 off"
  out=$(unmap_out 1000 doas)
  expect_has "unmap: a doas box gets doas" "$out" "RETRY: doas tailscale serve --https=8443 off"
  out=$(unmap_out 0 none)
  expect_lacks "unmap: a root shell is offered no retry" "$out" "RETRY:"
  expect_has "unmap: a root shell still re-reads status and reports" "$out" "ok: Removed the old serve mapping"
  out=$(unmap_out 1000 none)
  expect_has "unmap: no escalator prints the bare command" "$out" "RETRY: tailscale serve --https=8443 off"
}

sweep_out() { # sweep_out <uid> <sudo|doas|none>
  local uid="$1" privtool="$2"
  (
    BOLD=""; RESET=""; DRY_RUN=false; REUSE_ONLY=false
    TS_STATE_KNOWN=true; RESERVED_PORTS=""
    TS_PORTS=("10000"$'\t'"funnel"$'\t'"http://127.0.0.1:8080")
    ok()   { printf 'ok: %s\n' "$*"; }
    note() { printf 'note: %s\n' "$*"; }
    warn() { printf 'warn: %s\n' "$*"; }
    plan_add() { :; }
    confirm() { return 0; }
    id() { case "${1:-}" in -u) printf '%s\n' "$uid" ;; *) printf 'alice\n' ;; esac; }
    have() {
      case "$1" in
        sudo) [ "$privtool" = sudo ] ;;
        doas) [ "$privtool" = doas ] ;;
        *)    return 1 ;;
      esac
    }
    print_and_wait() { printf 'ACTION: %s\nWHY: %s\nRETRY: %s\n' "$1" "$2" "$3"; return 0; }
    tailscale() { return 1; }
    ts_targets() { TS_PORTS=(); }
    sweep_stale_public_funnels 8080 443 host.example.ts.net
  ) 2>&1
}

test_sweep_retry() {
  local out
  # A funnel `off` does NOT clear the serve handler, so the retry is two commands
  # and BOTH need the prefix — a half-prefixed retry leaves the port exposed.
  out=$(sweep_out 1000 sudo)
  expect_has "sweep: a refused funnel teardown prefixes both commands" \
    "$out" "RETRY: sudo tailscale funnel --https=10000 off; sudo tailscale serve --https=10000 off"
  out=$(sweep_out 1000 doas)
  expect_has "sweep: a doas box gets doas on both commands" \
    "$out" "RETRY: doas tailscale funnel --https=10000 off; doas tailscale serve --https=10000 off"
  out=$(sweep_out 0 none)
  expect_lacks "sweep: a root shell is offered no retry" "$out" "RETRY:"
  expect_has "sweep: a root shell still verifies the port is closed" \
    "$out" "ok: Port 10000 is no longer exposed."
  out=$(sweep_out 1000 none)
  expect_has "sweep: no escalator keeps both commands bare" \
    "$out" "RETRY: tailscale funnel --https=10000 off; tailscale serve --https=10000 off"
}

# ============================================ single-instance setup lock (10-utils) ==
# Two overlapping setup runs settle on the SAME loopback port (the bind probe closes
# its socket immediately, so it reserves nothing), write the same unit and credential
# names, and both rewrite profile-<id>.json — a whole-file overwrite, so the run that
# finishes second erases the other's live file server from the saved record. There is
# no `flock` on macOS, so the gate is `mkdir`, and the lock's authority is the
# LIVENESS of the process it names. That last part is what these cases guard: an
# existence-only lock survives a SIGKILL or a reboot and then blocks every future run
# forever, which is a worse bug than the race it closes.
lock_acquire_out() { # lock_acquire_out <state-dir> [release] [ps-broken] [steal-race]
  local sd="$1" release="${2:-no}" psbroken="${3:-no}" stealrace="${4:-no}"
  (
    STATE_DIR="$sd"; STATE_DIR_EXPOSURE_REPORTED=false
    YELLOW=""; RESET=""; DIM=""
    SETUP_LOCK_PATH=""; SETUP_LOCK_HELD=false
    warn() { printf 'warn: %s\n' "$*"; }
    note() { printf 'note: %s\n' "$*"; }
    die()  { printf 'die: %s\n' "$*"; exit 9; }
    # A box with no usable `ps` must fail CLOSED — never steal a lock on a guess.
    [ "$psbroken" = yes ] && ps() { return 1; }
    # The one arm a real race cannot be scheduled on demand: the record naming
    # somebody else the instant after we wrote our own. Only the owner read-back is
    # shadowed (matched on the path), so the liveness probe's own `head` is untouched.
    [ "$stealrace" = yes ] && head() {
      case "$*" in *owner*) printf '999999\n' ;; *) command head "$@" ;; esac
    }
    local rc=0
    setup_lock_acquire || rc=$?
    printf 'rc=%s held=%s path=%s\n' "$rc" "$SETUP_LOCK_HELD" "$SETUP_LOCK_PATH"
    if [ "$release" = release ]; then
      setup_lock_release
      printf 'after-release held=%s\n' "$SETUP_LOCK_HELD"
    fi
  ) 2>&1
}

# Plant a lock that already exists, exactly as debris or a live holder would leave it.
plant_lock() { # plant_lock <state-dir> <pid|-> <host|-> <sig|-> [old]
  local sd="$1" pid="$2" host="$3" sig="$4" age="${5:-new}"
  mkdir -p "$sd/setup.lock"
  if [ "$pid" != "-" ]; then
    [ "$host" = "-" ] && host=$(uname -n)
    [ "$sig" = "-" ] && sig=$(setup_lock_proc_sig "$pid")
    printf '%s\n%s\n%s\n' "$pid" "$host" "$sig" > "$sd/setup.lock/owner"
  fi
  # An interrupted run leaves a record-less directory. Only its AGE separates that
  # from a run that is inside the sliver between mkdir and the record write.
  [ "$age" = old ] && touch -t 202001010101 "$sd/setup.lock"
  return 0
}

# A pid that is definitely gone: started, reaped, never reused inside one test run.
dead_pid() {
  local p
  ( exit 0 ) & p=$!
  wait "$p" 2>/dev/null || true
  printf '%s' "$p"
}

test_setup_lock_first_run() {
  local sd="$TMPD/lock-fresh/conduck" out owner_pid
  rm -rf "$TMPD/lock-fresh"
  out=$(lock_acquire_out "$sd")
  expect_has "setup lock: a first run takes it" "$out" "rc=0 held=true path=$sd/setup.lock"
  expect_lacks "setup lock: a first run says nothing about locks" "$out" "warn:"
  owner_pid=$(head -1 "$sd/setup.lock/owner" 2>/dev/null || true)
  # The record is what makes the lock judgeable later; without it no future run
  # could tell a live holder from debris.
  expect_eq "setup lock: the record names the holding process" "$owner_pid" "$$"
  expect_eq "setup lock: the record names this machine" \
    "$(sed -n 2p "$sd/setup.lock/owner" 2>/dev/null || true)" "$(uname -n)"
  expect_eq "setup lock: the record is not world-readable" \
    "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' \
        "$sd/setup.lock/owner")" "0o600"
}

test_setup_lock_refuses_live_holder() {
  local sd="$TMPD/lock-live/conduck" out sleeper
  rm -rf "$TMPD/lock-live"; mkdir -p "$sd"
  sleep 30 & sleeper=$!
  plant_lock "$sd" "$sleeper" - -
  out=$(lock_acquire_out "$sd")
  kill "$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true
  expect_has "setup lock: a live holder stops the second run" "$out" "die:"
  expect_has "setup lock: the block names what holds it" \
    "$out" "another conduck-connect setup is running here (process $sleeper)"
  expect_has "setup lock: the block says what the collision costs" \
    "$out" "overwrites the first one's saved profile"
  expect_has "setup lock: the block hands over the manual escape" \
    "$out" "rm -rf $sd/setup.lock"
  # Refusing must not disturb the run that is actually working.
  if [ -f "$sd/setup.lock/owner" ]; then pass "setup lock: a refused run leaves the live lock alone"
  else fail "setup lock: a refused run leaves the live lock alone" "the lock was removed"; fi
}

test_setup_lock_reclaims_debris() {
  local sd out gone
  # A SIGKILL / power cut leaves a lock naming a process that no longer exists.
  # This is the case that must NEVER need a human.
  sd="$TMPD/lock-dead/conduck"; rm -rf "$TMPD/lock-dead"; mkdir -p "$sd"
  gone=$(dead_pid)
  plant_lock "$sd" "$gone" - "bash conduck-connect.sh --setup"
  out=$(lock_acquire_out "$sd")
  expect_has "setup lock: a lock naming a dead process is reclaimed" "$out" "rc=0 held=true"
  expect_has "setup lock: the reclaim says why it was debris" \
    "$out" "Clearing a leftover setup lock — process $gone is gone."
  expect_eq "setup lock: the reclaimed lock records the new holder" \
    "$(head -1 "$sd/setup.lock/owner" 2>/dev/null || true)" "$$"

  # Reboot + pid reuse: the number is alive again, but it is somebody else. A
  # pid-only check would read this as held and block every future run.
  local sleeper
  sd="$TMPD/lock-recycled/conduck"; rm -rf "$TMPD/lock-recycled"; mkdir -p "$sd"
  sleep 30 & sleeper=$!
  plant_lock "$sd" "$sleeper" - "bash conduck-connect.sh --setup"
  out=$(lock_acquire_out "$sd")
  kill "$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true
  expect_has "setup lock: a recycled pid is reclaimed, not obeyed" "$out" "rc=0 held=true"
  expect_has "setup lock: the reclaim names pid reuse as the reason" \
    "$out" "process $sleeper belongs to another program now"

  # Killed in the sliver between mkdir and the record write: no record at all, and
  # old enough that no starting run could still be inside that sliver.
  sd="$TMPD/lock-orphan/conduck"; rm -rf "$TMPD/lock-orphan"; mkdir -p "$sd"
  plant_lock "$sd" - - - old
  out=$(lock_acquire_out "$sd")
  expect_has "setup lock: an aged record-less lock is reclaimed" "$out" "rc=0 held=true"
  expect_has "setup lock: the reclaim says the lock named no process" \
    "$out" "it names no process"
}

test_setup_lock_fails_closed() {
  local sd out gone
  # A record-less lock that is BRAND NEW is a run inside the mkdir→record sliver.
  # Stealing it would put two setups on the machine, which is the whole defect.
  sd="$TMPD/lock-starting/conduck"; rm -rf "$TMPD/lock-starting"; mkdir -p "$sd"
  plant_lock "$sd" - - -
  out=$(lock_acquire_out "$sd")
  expect_has "setup lock: a just-created record-less lock is NOT stolen" "$out" "die:"
  expect_has "setup lock: a starting run is named as such" \
    "$out" "another conduck-connect setup is starting on this machine"

  # $HOME on a network share is ONE lock for several machines. A pid from another
  # box means nothing here, so this run may not judge it either way.
  sd="$TMPD/lock-foreign/conduck"; rm -rf "$TMPD/lock-foreign"; mkdir -p "$sd"
  gone=$(dead_pid)
  plant_lock "$sd" "$gone" "not-this-box.invalid" "bash conduck-connect.sh --setup"
  out=$(lock_acquire_out "$sd")
  expect_has "setup lock: a lock from another machine is not stolen" "$out" "die:"
  expect_has "setup lock: the block names the other machine" \
    "$out" "a setup on not-this-box.invalid holds it (process $gone)"
  expect_has "setup lock: the block admits it cannot judge that run" \
    "$out" "cannot tell whether that run is still alive"
  if [ -f "$sd/setup.lock/owner" ]; then pass "setup lock: the foreign lock survives"
  else fail "setup lock: the foreign lock survives" "the lock was removed"; fi

  # No usable `ps` (a stripped container): liveness is unknowable, so the dead pid
  # above must NOT be treated as dead. Guessing here would break the invariant.
  sd="$TMPD/lock-nops/conduck"; rm -rf "$TMPD/lock-nops"; mkdir -p "$sd"
  gone=$(dead_pid)
  plant_lock "$sd" "$gone" - "bash conduck-connect.sh --setup"
  out=$(lock_acquire_out "$sd" no yes)
  expect_has "setup lock: no usable ps fails closed" "$out" "die:"
  expect_has "setup lock: no usable ps says why it cannot judge" \
    "$out" "no usable 'ps'"
  expect_has "setup lock: no usable ps still hands over the escape" \
    "$out" "rm -rf $sd/setup.lock"

  # Two runs can both clear the same debris, and the second clear would take out
  # the winner's fresh lock. Ownership is therefore read back from the record: when
  # it names somebody else, this run must NOT hold the lock.
  sd="$TMPD/lock-steal-race/conduck"; rm -rf "$TMPD/lock-steal-race"
  out=$(lock_acquire_out "$sd" no no yes)
  expect_has "setup lock: a record naming somebody else is not treated as ours" "$out" "die:"
  expect_lacks "setup lock: a lost reclaim race never reports a held lock" "$out" "held=true"
}

test_setup_lock_release() {
  local sd out sleeper
  sd="$TMPD/lock-release/conduck"; rm -rf "$TMPD/lock-release"
  out=$(lock_acquire_out "$sd" release)
  expect_has "setup lock: release clears the held flag" "$out" "after-release held=false"
  if [ -e "$sd/setup.lock" ]; then
    fail "setup lock: release removes the lock" "$sd/setup.lock survived"
  else
    pass "setup lock: release removes the lock"
  fi

  # The release runs from an EXIT trap, so it fires on runs that never took the
  # lock too — including a run that was REFUSED. It must not delete the lock the
  # other run is holding.
  sd="$TMPD/lock-release-foreign/conduck"; rm -rf "$TMPD/lock-release-foreign"; mkdir -p "$sd"
  sleep 30 & sleeper=$!
  plant_lock "$sd" "$sleeper" - -
  (
    STATE_DIR="$sd"; SETUP_LOCK_PATH=""; SETUP_LOCK_HELD=false
    setup_lock_release
  )
  kill "$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true
  if [ -f "$sd/setup.lock/owner" ]; then
    pass "setup lock: a run that never held it deletes nothing"
  else
    fail "setup lock: a run that never held it deletes nothing" "someone else's lock was removed"
  fi
}

# Wiring: the lock is worthless if the dispatch does not reach it, and worse than
# nothing if arming its release drops the exposure-undo backstop it shares EXIT with.
test_setup_lock_wiring() {
  local body guarded first_acquire first_exposure first_lane
  body=$(sed -n '/^run_setup()/,/^}/p' "$MN")
  expect_has "setup lock wiring: run_setup takes the lock" "$body" "setup_lock_acquire"
  guarded=$(printf '%s\n' "$body" | grep -A2 'if ! \$DRY_RUN; then' || true)
  expect_has "setup lock wiring: a dry run neither takes nor holds the lock" \
    "$guarded" "setup_lock_acquire"
  # Composed, not replaced: on_exit prints how to undo exposures a failed run applied.
  expect_has "setup lock wiring: the EXIT trap keeps the exposure backstop" \
    "$body" "trap 'setup_lock_release; on_exit' EXIT"
  # …and it has to be taken before anything picks a port or writes a unit.
  first_acquire=$(printf '%s\n' "$body" | grep -n '^ *setup_lock_acquire$' | head -1 | cut -d: -f1)
  first_exposure=$(printf '%s\n' "$body" | grep -n 'choose_exposure' | head -1 | cut -d: -f1)
  first_lane=$(printf '%s\n' "$body" | grep -n 'setup_file_lane' | head -1 | cut -d: -f1)
  if [ -n "$first_acquire" ] && [ -n "$first_exposure" ] && [ -n "$first_lane" ] \
     && [ "$first_acquire" -lt "$first_exposure" ] && [ "$first_acquire" -lt "$first_lane" ]; then
    pass "setup lock wiring: the lock precedes exposure and the file lane"
  else
    fail "setup lock wiring: the lock precedes exposure and the file lane" \
      "acquire@${first_acquire:-none} exposure@${first_exposure:-none} lane@${first_lane:-none}"
  fi
}

# ====================================== unreadable saved profiles (10-utils, 91) ==
# A profile FILE that exists and does not validate is NOT the same thing as no
# profile, and confusing the two is destructive: setup rewrites profile-<id>.json,
# so "there is nothing saved, run setup once" is how an older script destroys a
# profile a NEWER conduck-connect wrote. The validator's own reason is the only
# thing that knows which of the two it is looking at.
write_profile_fixture() { # write_profile_fixture <state-dir> <name> <schemaVersion>
  mkdir -p "$1"
  cat > "$1/profile-$2.json" <<JSON
{
 "schemaVersion": $3,
 "gateway": {
  "id": "$2",
  "kind": "custom",
  "name": "Fixture $2",
  "auth": "bearer",
  "transport": "tailscale",
  "reach": "private",
  "url": "https://box.example.ts.net",
  "localPort": "4711"
 },
 "fileServer": null
}
JSON
}

menu_out() { # menu_out <state-dir>
  (
    STATE_DIR="$1"
    BOLD=""; RESET=""; DIM=""; YELLOW=""; GREEN=""; RED=""
    COMMAND=""; NO_ANSWER="no answer"
    SAVED_PROFILE_REJECTED=0; SAVED_PROFILE_REJECT_REASON=""
    say()  { printf '%s\n' "$*"; }
    warn() { printf 'warn: %s\n' "$*"; }
    note() { printf 'note: %s\n' "$*"; }
    die()  { printf 'die: %s\n' "$*"; exit 9; }
    # Echo the accept regex: it is what actually decides whether option 4 exists,
    # so asserting on it beats matching menu prose.
    require_choice() { printf 'regex=%s\n' "$2" >&2; printf 'q'; }
    choose_main_action
    printf 'command=%s\n' "$COMMAND"
  ) 2>&1
}

test_menu_saved_profile_usable() {
  local sd="$TMPD/menu-ok/conduck" out
  rm -rf "$TMPD/menu-ok"
  write_profile_fixture "$sd" "custom-ok" 1
  out=$(menu_out "$sd")
  expect_has "menu: a usable profile offers option 4" "$out" "4) Show a saved setup code"
  expect_has "menu: a usable profile widens the accept regex" "$out" 'regex=^([1-4]|[qQ])$'
  expect_lacks "menu: a usable profile raises no rejection warning" "$out" "warn:"
}

test_menu_no_profile_at_all() {
  local sd="$TMPD/menu-empty/conduck" out
  rm -rf "$TMPD/menu-empty"; mkdir -p "$sd"
  out=$(menu_out "$sd")
  expect_lacks "menu: an empty state dir offers no option 4" "$out" "4) Show a saved setup code"
  expect_has "menu: an empty state dir keeps the narrow regex" "$out" 'regex=^([1-3]|[qQ])$'
  # Nothing saved is not a problem to report — only an unusable file is.
  expect_lacks "menu: an empty state dir invents no unreadable profile" "$out" "warn:"
}

test_menu_unreadable_profile() {
  local sd="$TMPD/menu-future/conduck" out
  rm -rf "$TMPD/menu-future"
  write_profile_fixture "$sd" "custom-future" 2
  out=$(menu_out "$sd")
  # Option 4 genuinely cannot be offered — but going quiet is what loses the file.
  expect_lacks "menu: an unreadable profile still cannot be shown" "$out" "4) Show a saved setup code"
  expect_has "menu: an unreadable profile is announced, not hidden" \
    "$out" "There IS a saved setup code on this machine, and this version can't read it"
  expect_has "menu: the validator's real reason reaches the operator" \
    "$out" "uses schema version '2'"
  expect_has "menu: a from-the-future profile advises updating THIS script" \
    "$out" "Update this script, then try again"
  expect_has "menu: the operator is warned that setup replaces the file" \
    "$out" "Setting up again REPLACES the saved file"

  # A usable profile answers the question; rejections behind it are the picker's business.
  write_profile_fixture "$sd" "custom-ok" 1
  out=$(menu_out "$sd")
  expect_has "menu: one usable profile beside an unreadable one still offers option 4" \
    "$out" "4) Show a saved setup code"
  expect_lacks "menu: a usable profile suppresses the rejection warning" "$out" "warn:"

  # Plural wording carries the count, so the operator knows how much is at stake.
  rm -rf "$TMPD/menu-future2"; sd="$TMPD/menu-future2/conduck"
  write_profile_fixture "$sd" "custom-a" 2
  write_profile_fixture "$sd" "custom-b" 3
  out=$(menu_out "$sd")
  expect_has "menu: several unreadable profiles are counted" \
    "$out" "There are 2 saved setup codes on this machine"
}

pick_out() { # pick_out <state-dir>
  (
    STATE_DIR="$1"; BOLD=""; RESET=""; DIM=""; PROFILE_FILE=""
    say()  { printf '%s\n' "$*"; }
    warn() { printf 'warn: %s\n' "$*"; }
    note() { printf 'note: %s\n' "$*"; }
    die()  { printf 'die: %s\n' "$*"; exit 9; }
    require_choice() { printf '1'; }
    show_qr_pick_profile
    printf 'picked=%s\n' "$PROFILE_FILE"
  ) 2>&1
}

test_show_code_picker_reason() {
  local sd out
  # --show-code is exactly where an operator lands after the menu hides option 4,
  # so it carries the same duty: name the real reason instead of prescribing the
  # one action that destroys the file.
  sd="$TMPD/pick-future/conduck"; rm -rf "$TMPD/pick-future"
  write_profile_fixture "$sd" "custom-future" 2
  out=$(pick_out "$sd")
  expect_has "--show-code: an unreadable profile is reported as unusable, not absent" \
    "$out" "There IS a saved pairing profile on this machine, and this version ($VERSION) can't use it"
  expect_has "--show-code: the validator's real reason is carried through" \
    "$out" "uses schema version '2'"
  expect_lacks "--show-code: an existing profile is never called missing" \
    "$out" "No usable saved pairing profile on this machine yet"

  # Several unusable profiles name the count and quote the first reason, so the
  # operator knows how much recoverable state is on the machine.
  sd="$TMPD/pick-future2/conduck"; rm -rf "$TMPD/pick-future2"
  write_profile_fixture "$sd" "custom-a" 2
  write_profile_fixture "$sd" "custom-b" 3
  out=$(pick_out "$sd")
  expect_has "--show-code: several unusable profiles are counted" \
    "$out" "There are 2 saved pairing profiles on this machine"
  expect_has "--show-code: the first reason is quoted as such" "$out" "The first one says:"

  # Genuinely nothing saved keeps the original onboarding message.
  sd="$TMPD/pick-empty/conduck"; rm -rf "$TMPD/pick-empty"; mkdir -p "$sd"
  out=$(pick_out "$sd")
  expect_has "--show-code: an empty state dir still says to run setup once" \
    "$out" "No usable saved pairing profile on this machine yet"

  sd="$TMPD/pick-ok/conduck"; rm -rf "$TMPD/pick-ok"
  write_profile_fixture "$sd" "custom-ok" 1
  out=$(pick_out "$sd")
  expect_has "--show-code: a single usable profile is selected without a question" \
    "$out" "picked=$sd/profile-custom-ok.json"
}

# ================================== $STATE_DIR exposure wording (10-utils) ==
# $STATE_DIR holds fileserver-<id>.cred/.env and profile-<id>.json. Group/other
# READ leaks the listing — which gateways this user paired. Group/other WRITE is a
# different harm entirely: the 0600 on those files protects their contents, not
# their place in the folder, so any local account can replace the file rclone reads
# its password from. One wording for both understates the second.
state_dir_out() { # state_dir_out <octal-mode>
  local dir="$TMPD/state-$1/conduck"
  rm -rf "$TMPD/state-$1"; mkdir -p "$dir"; chmod "$1" "$dir"
  (
    STATE_DIR="$dir"; STATE_DIR_EXPOSURE_REPORTED=false; YELLOW=""; RESET=""
    warn() { printf 'warn: %s\n' "$*"; }
    local rc=0
    ensure_state_dir || rc=$?
    printf 'rc=%s\n' "$rc"
  ) 2>&1
}

test_state_dir_exposure_wording() {
  local out dir
  expect_eq "state dir: a 0700 directory says nothing" "$(state_dir_out 700)" "rc=0"

  dir="$TMPD/state-755/conduck"
  out=$(state_dir_out 755)
  expect_has "state dir: a readable directory names the listing leak" \
    "$out" "can be listed by other accounts"
  expect_has "state dir: a readable directory names the exact fix" "$out" "chmod 700 $dir"
  expect_lacks "state dir: a readable-only directory is not called writable" "$out" "is WRITABLE"
  expect_has "state dir: reporting an exposure is not a failure for the caller" "$out" "rc=0"

  dir="$TMPD/state-777/conduck"
  out=$(state_dir_out 777)
  expect_has "state dir: a writable directory leads with WRITABLE" \
    "$out" "is WRITABLE by other accounts on this machine"
  expect_has "state dir: a writable directory names the credential swap" \
    "$out" "the file-server password rclone reads when it starts"
  expect_has "state dir: a writable directory says 0600 does not cover the folder" \
    "$out" "not the folder that holds them"
  expect_lacks "state dir: a writable directory is not downgraded to a listing problem" \
    "$out" "can be listed by other accounts"
  expect_has "state dir: a writable directory names the exact fix" "$out" "chmod 700 $dir"
  expect_eq "state dir: the fix is printed once, not per warning line" \
    "$(printf '%s\n' "$out" | grep -c "chmod 700 $dir")" "1"
}

# Wiring: --show-code reads $STATE_DIR and re-derives the gateway token and the
# file-lane credential out of it, so it owes the same exposure report the wizard
# gives — and owes it BEFORE it reads a password out of that folder.
test_show_code_state_dir_wiring() {
  local body pick check secret
  body=$(sed -n '/^run_show_qr()/,/^}/p' "$SQ")
  expect_has "--show-code wiring: the state dir mode is checked" "$body" "ensure_state_dir"
  pick=$(printf '%s\n' "$body" | grep -n 'show_qr_pick_profile' | head -1 | cut -d: -f1)
  check=$(printf '%s\n' "$body" | grep -n '^ *ensure_state_dir$' | head -1 | cut -d: -f1)
  secret=$(printf '%s\n' "$body" | grep -n 'show_qr_recover_gateway_secret' | head -1 | cut -d: -f1)
  # After the picker (a profile file proves the directory exists, so `mkdir -p` is a
  # provable no-op and a "changes nothing" command creates nothing) and before any
  # secret is recovered.
  if [ -n "$pick" ] && [ -n "$check" ] && [ -n "$secret" ] \
     && [ "$pick" -lt "$check" ] && [ "$check" -lt "$secret" ]; then
    pass "--show-code wiring: the check sits after the picker and before secret recovery"
  else
    fail "--show-code wiring: the check sits after the picker and before secret recovery" \
      "pick@${pick:-none} check@${check:-none} secret@${secret:-none}"
  fi
}

printf 'host-environment regressions — lifted source functions, simulated hosts\n'
test_priv_prefix
test_install_cmd_per_manager
test_install_cmd_package_names
test_install_cmd_privilege
test_preflight
test_preflight_privilege_note
test_file_lane_service_manager_guard
test_linger
test_linger_privilege
test_linger_modes
test_ts_priv_retry
test_expose_retry
test_unmap_retry
test_sweep_retry
test_setup_lock_first_run
test_setup_lock_refuses_live_holder
test_setup_lock_reclaims_debris
test_setup_lock_fails_closed
test_setup_lock_release
test_setup_lock_wiring
test_menu_saved_profile_usable
test_menu_no_profile_at_all
test_menu_unreadable_profile
test_show_code_picker_reason
test_state_dir_exposure_wording
test_show_code_state_dir_wiring

printf '\nHOST ENV RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ] || exit 1
[ "$PASS" -gt 0 ] || { printf 'no cases ran\n' >&2; exit 1; }
