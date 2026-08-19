# ----------------------------------------------------------- file-lane phase --

FS_URL=""; FS_CRED=""
FS_LOCAL_PORT=""
FS_REACH=""         # the file lane's OWN reach (public|private) — can differ from the gateway's
                    # SCOPE in a mixed-scope setup; recorded as fileServer.reach for --show-code
FS_UNIT=""          # resolved unit/plist path actually in use (existing or new)
FS_FOLDER=""        # absolute served root; load-bearing for config alignment + local snapshots
FS_CRED_LEGACY_ARGV=false   # true when a reused unit keeps the password on argv (ps-visible)
FS_EXISTING_UNSAFE=false    # matching unit exists but cannot be parsed/reused without guessing
FS_PORT_ALLOCATION_REASON=""
FS_PORT_START=5006
FS_PORT_END=5105
# A file lane is a LIVE, boot-persistent, authenticated WebDAV server over the
# agent's working folder. Every path that builds one and then does not ship it
# owes the operator that fact, so these four follow the lane through the run:
FS_LANE_PREPARED=false         # a live file server for THIS gateway is in play this run
FS_UNIT_CREATED_THIS_RUN=false # …and this run is what wrote and started it
FS_ROUTE_SELF_MANAGED=false    # the operator was told to point their OWN HTTPS route at
                               # FS_LOCAL_PORT. Tailscale mappings are excluded on purpose:
                               # those this connector applies and rolls back itself (FS_APPLIED).
FS_RESIDUE_REPORTED=false      # the residue/teardown report is printed once per run
# fs_resolve_shared_folder answers in globals, never on stdout: a command
# substitution runs it in a subshell and would throw the refusal reason away.
FS_FOLDER_RESOLVED=""
FS_FOLDER_REFUSAL=""

state_cred_file() { printf '%s/fileserver-%s.cred' "$STATE_DIR" "$GW_ID"; }
state_env_file()  { printf '%s/fileserver-%s.env'  "$STATE_DIR" "$GW_ID"; }

# Every connector-owned unit and plist path in this file is rooted at "${HOME:-}",
# never at a bare "$HOME", and the difference is not cosmetic.
#
# These lookups started life inside the interactive setup, where a person is
# standing at a terminal and $HOME is a certainty. They are not only there any
# more: fs_all_units is what --list walks to report file servers with no saved
# setup behind them, and --list is the command --help and every refusal screen
# advertise as the entry point for an environment with nobody at a terminal. A CI
# or container shell legitimately runs with XDG_CONFIG_HOME set and HOME unset —
# $STATE_DIR is spelled "${HOME:-}/.config" for exactly that case — and under
# `set -u` a bare "$HOME" there does not fail politely. It kills whatever subshell
# reached it, so --list prints a raw `HOME: unbound variable` into the middle of
# the operator's inventory and then reports NO leftovers at all: a live,
# authenticated WebDAV server over the agent's working folder, restarted at every
# boot, goes unmentioned by the one surface whose whole job is to mention it.
#
# An empty root is the honest answer rather than a fallback: a host with no home
# directory has no per-user systemd or LaunchAgents directory either, so the globs
# match nothing and the scan reports what is really there. The default is spelled
# at each expansion rather than snapshotted into a global at file-scope, because a
# snapshot answers with the HOME that was set when this file was READ — wrong for
# any caller that points HOME somewhere else before calling, which the readiness
# harness does for every case it lifts these functions into.
linux_unit_candidates() {
  printf '%s\n' \
    "${HOME:-}/.config/systemd/user/conduck-files-$GW_ID.service" \
    "${HOME:-}/.config/systemd/user/conduck-files.service" \
    "${HOME:-}/.config/systemd/user/conduck-fileserver.service"
}
mac_unit_candidates() {
  printf '%s\n' \
    "${HOME:-}/Library/LaunchAgents/ai.gigaduck.conduck-files-$GW_ID.plist" \
    "${HOME:-}/Library/LaunchAgents/ai.gigaduck.conduck-files.plist" \
    "${HOME:-}/Library/LaunchAgents/ai.gigaduck.conduck-fileserver.plist"
}

fs_all_units() {
  local f
  if [ "$OS" = "Linux" ]; then
    for f in "${HOME:-}"/.config/systemd/user/conduck-files-*.service \
             "${HOME:-}/.config/systemd/user/conduck-files.service" \
             "${HOME:-}/.config/systemd/user/conduck-fileserver.service"; do
      [ -f "$f" ] && printf '%s\n' "$f"
    done
  else
    for f in "${HOME:-}"/Library/LaunchAgents/ai.gigaduck.conduck-files-*.plist \
             "${HOME:-}/Library/LaunchAgents/ai.gigaduck.conduck-files.plist" \
             "${HOME:-}/Library/LaunchAgents/ai.gigaduck.conduck-fileserver.plist"; do
      [ -f "$f" ] && printf '%s\n' "$f"
    done
  fi
}

# Parse one connector-owned systemd unit / launchd plist structurally. The
# service definition is authority for both the loopback port and served folder,
# so comments, duplicate directives, or a second --addr must never win by grep
# order. This intentionally supports only the simple argv shape this connector
# writes (and earlier connector releases wrote); anything more expressive is
# refused rather than guessed.
fs_unit_field() { # fs_unit_field <unit-or-plist> <port|folder|argv_cred|env_cred|argv_exposed>
  python3 - "$1" "$2" <<'PY' 2>/dev/null
import os, plistlib, re, shlex, sys

path, field = sys.argv[1:3]

def clean(value):
    return isinstance(value, str) and value and all(ch.isprintable() for ch in value)

def inspect_argv(argv, systemd=False):
    if not isinstance(argv, list) or not all(clean(x) for x in argv):
        raise ValueError("argv")
    if len(argv) < 6 or argv[1:3] != ["serve", "webdav"]:
        raise ValueError("shape")
    if os.path.basename(argv[0]) != "rclone":
        raise ValueError("executable")
    # Connector-written units always use an absolute served root. A relative
    # argv is resolved against the service manager's cwd, which is not a root
    # this process can safely align Hermes to or guard a local snapshot under.
    if not os.path.isabs(argv[3]):
        raise ValueError("relative folder")
    # $VAR and %specifier expansion make the literal folder unrecoverable from
    # a systemd ExecStart line. launchd argv has no such expansion.
    if systemd and any(ch in argv[3] for ch in ("$", "%")):
        raise ValueError("expanded folder")
    if systemd and any(x.startswith(("#", ";")) for x in argv[4:]):
        raise ValueError("inline comment")
    if argv.count("--addr") != 1 or any(x.startswith("--addr=") for x in argv):
        raise ValueError("addr count")
    ai = argv.index("--addr")
    if ai + 1 >= len(argv):
        raise ValueError("addr value")
    m = re.fullmatch(r"127\.0\.0\.1:([0-9]+)", argv[ai + 1])
    if not m or not 1 <= int(m.group(1)) <= 65535:
        raise ValueError("addr")
    if argv.count("--pass") > 1 or any(x.startswith("--pass=") for x in argv):
        raise ValueError("pass count")
    cred = ""
    if "--pass" in argv:
        pi = argv.index("--pass")
        if pi + 1 >= len(argv) or not clean(argv[pi + 1]):
            raise ValueError("pass value")
        cred = argv[pi + 1]
    return m.group(1), argv[3], cred

try:
    env_cred = ""
    is_systemd = not path.endswith(".plist")
    if not is_systemd:
        data = plistlib.load(open(path, "rb"))
        if not isinstance(data, dict):
            raise ValueError("plist")
        argv = data.get("ProgramArguments")
        env = data.get("EnvironmentVariables", {})
        if not isinstance(env, dict):
            raise ValueError("environment")
        if "RCLONE_PASS" in env:
            env_cred = env["RCLONE_PASS"]
            if not clean(env_cred):
                raise ValueError("environment credential")
    else:
        raw = open(path, encoding="utf-8").read()
        section = ""
        starts = []
        for physical in raw.splitlines():
            if physical.endswith("\\"):
                raise ValueError("continuation")
            stripped = physical.strip()
            if not stripped or stripped.startswith(("#", ";")):
                continue
            if stripped.startswith("[") and stripped.endswith("]"):
                section = stripped[1:-1].strip()
                continue
            if section != "Service" or "=" not in physical:
                continue
            key, value = physical.split("=", 1)
            if key.strip() == "ExecStart":
                starts.append(value.strip())
        if len(starts) != 1 or not starts[0]:
            raise ValueError("ExecStart count")
        argv = shlex.split(starts[0], posix=True, comments=False)
    port, folder, argv_cred = inspect_argv(argv, systemd=is_systemd)
    values = {
        "port": port,
        "folder": folder,
        "argv_cred": argv_cred,
        "env_cred": env_cred,
        "argv_exposed": "yes" if argv_cred else "",
    }
    if field not in values:
        raise ValueError("field")
    sys.stdout.write(values[field])
except Exception:
    sys.exit(1)
PY
}

# Echo the loopback port encoded in one connector-created service definition.
# Empty means "could not prove it"; callers must never silently treat that unit
# as owning the default port.
fs_unit_port() { fs_unit_field "$1" port; }

# Credentials ride curl's stdin config and, on Linux, a systemd EnvironmentFile.
# Reject every ASCII control (including CR/LF/DEL) before either parser sees it.
credential_value_safe() { # credential_value_safe <value>
  [ -n "$1" ] || return 1
  printf '%s' "$1" | python3 -c '
import sys
s = sys.stdin.read()
sys.exit(0 if s and all(c.isprintable() for c in s) else 1)' 2>/dev/null
}

fs_systemd_value_safe() { # fs_systemd_value_safe <literal path/argv value>
  [ -n "$1" ] || return 1
  case "$1" in *'$'*|*'%'*) return 1 ;; esac
  printf '%s' "$1" | python3 -c '
import sys
s = sys.stdin.read()
sys.exit(0 if s and all(c.isprintable() for c in s) else 1)' 2>/dev/null
}

fs_systemd_quote() { # fs_systemd_quote <literal>
  fs_systemd_value_safe "$1" || return 1
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

# Quote a literal for a command line the OPERATOR is meant to copy and paste.
# Only when it needs quoting, so the common case stays readable: an unquoted path
# with a space in it is a `rm -f` that removes something else, or nothing.
fs_shell_arg() { # fs_shell_arg <literal>
  case "$1" in
    ""|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/@:+-]*)
      local value="$1"
      value="${value//\'/\'\\\'\'}"   # ' → '\'' (close, escape, reopen)
      printf "'%s'" "$value" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Resolve the shared folder before ANY service definition records it, and refuse
# every root that turns this lane into a remote file browser for the whole
# account: /, the home directory itself, and any ancestor of $STATE_DIR. The
# third is not a special case of the second — $STATE_DIR follows
# XDG_CONFIG_HOME, so `~/.config` (or wherever XDG_CONFIG_HOME points, which
# need not be under home at all) is a perfectly ordinary-looking answer that
# publishes this script's own fileserver-*.cred / .env / profile-*.json over
# WebDAV with WRITE access, and the operator who typed it would be warned about
# nothing, because fs_folder_refusal_warn is the only place that risk is named
# and it prints solely on the refusal path.
#
# Strictly tighter than the doctor's gate in 61-check-adapter-files.inc.sh:
# setup never certifies a root the doctor refuses to grade.
#
# Resolving is load-bearing beyond the refusal: rclone re-resolves the served
# path on every request, so a symlink recorded verbatim in the unit serves
# whatever its target points at TODAY — the target can be swapped, including to
# $HOME, with no restart, no re-check, and nothing in any later transcript.
# Recording the resolved path pins the folder to the one that was certified.
#
# Answers land in globals: a command substitution would run this in a subshell
# and throw the refusal reason away.
fs_resolve_shared_folder() { # fs_resolve_shared_folder <path> -> 0 + FS_FOLDER_RESOLVED · 1 + FS_FOLDER_REFUSAL
  FS_FOLDER_RESOLVED=""; FS_FOLDER_REFUSAL=""
  local out
  out=$(python3 - "$1" "${STATE_DIR:-}" <<'PY' 2>/dev/null
import os, sys
p, state = sys.argv[1], sys.argv[2]
if not p or not os.path.isabs(p) or any(c in p for c in "\r\n"):
    print("BAD\tit is not a plain absolute path"); sys.exit(0)
rp = os.path.realpath(p)
home = os.path.realpath(os.path.expanduser("~"))
if rp == os.sep:
    print("BAD\tit resolves to /, the root of this whole filesystem"); sys.exit(0)
if rp == home:
    print("BAD\tit resolves to your home directory itself"); sys.exit(0)
if os.path.isfile(rp):
    print("BAD\tit resolves to a file, not a folder"); sys.exit(0)
# Both sides are realpath'd first, so a symlinked candidate cannot step around
# the test, and the comparison is on path BOUNDARIES: appending the separator is
# what keeps /home/u/.config from matching /home/u/.configuration. $STATE_DIR
# need not exist yet — realpath normalises a path that is not there — and an
# empty one means the caller has no state directory to protect.
if state:
    sp = os.path.realpath(state)
    if sp == rp or sp.startswith(rp.rstrip(os.sep) + os.sep):
        print("BAD\tit contains %s, where I keep this setup's saved passwords" % sp)
        sys.exit(0)
print("OK\t" + rp)
PY
) || out=""
  case "$out" in
    OK$'\t'*)  FS_FOLDER_RESOLVED="${out#OK$'\t'}"; return 0 ;;
    BAD$'\t'*) FS_FOLDER_REFUSAL="${out#BAD$'\t'}"; return 1 ;;
    *) FS_FOLDER_REFUSAL="I could not resolve that path on this machine"; return 1 ;;
  esac
}

# The same explanation wherever a folder is refused: the operator's next move is
# to name a narrower folder, and that only happens if they know WHY this one is
# refused rather than merely that it is.
fs_folder_refusal_warn() { # fs_folder_refusal_warn <path as given>
  warn "I can't serve $1 — ${FS_FOLDER_REFUSAL:-I could not resolve that path on this machine}."
  note "The shared folder is served over WebDAV with read AND write access to everything inside it."
  note "It has to be the agent's working folder, never your whole account: served from a folder that"
  note "wide, anything holding the file password can read your keys — and this script's own password"
  note "files — and write into them."
}

# The folder prompt for a gateway whose working folder this wizard cannot know.
# `ask` is not merely unhelpful here, it is unusable: it resolves a blank answer
# to its default, and a prompt with NO default would then read a stray Enter — or
# a closed stdin — as an answer, which is the whole defect this prompt exists to
# remove.
#
# The suffix is built by control_suffix like every other prompt, so this question
# states what Enter does instead of being the one place in the wizard that leaves
# it out — the banner promises every prompt says so, and a prompt whose answer
# only the operator can know is the worst one to break that promise at.
#
# $()-captured by its caller, so every human-facing line goes to stderr and only
# the path reaches stdout, and it answers on the shared prompt contract: 11 for q,
# 1 for a closed stdin. Acting on either from in here would stop the command
# substitution's subshell and let the run walk on, so prompt_into does it in the
# parent. Back is not offered: the gate that would receive it — "use a different
# folder than X?" — is asked only where a default exists, and the absence of a
# default is the entire reason this prompt is reached.
fs_ask_shared_folder() { # -> absolute path on stdout; 11 on q, 1 on a closed stdin
  local reply p
  p="  Absolute path to the folder your agent reads and writes ($(control_suffix "ask again" false)): "
  while true; do
    prompt_echo "$p"
    read -r -p "$p" reply \
      || return 1     # closed stdin — never spin a loop nobody is there to answer
    case "$reply" in
      [iI]|\?) explain_prompt "file.folder.override" >&2; continue ;;
      [qQ]) return 11 ;;
      /*) printf '%s' "$reply"; return 0 ;;
      # Enter is an advertised no-op here, so it re-asks without being told off.
      "") note "This gateway has no default folder — only you know where your agent reads and writes." >&2 ;;
      *)  warn "Please give an absolute path (starting with /)." >&2 ;;
    esac
  done
}

fs_systemd_envfile_path() { # fs_systemd_envfile_path <absolute literal path>
  # EnvironmentFile= is not ExecStart=: systemd passes the entire right-hand
  # side to its path/specifier parser and does NOT unquote it. Adding shell-like
  # quotes therefore makes the leading character `"` instead of `/`, so systemd
  # rejects the path as non-absolute and silently starts rclone without its
  # password. Spaces are valid here without quoting. Keep the controlled path
  # literal and fail closed on specifiers/control characters.
  fs_systemd_value_safe "$1" || return 1
  case "$1" in /*) ;; *) return 1 ;; esac
  # config_parse_unit_env_file() later expands this directive with safe_glob().
  # A connector-controlled state path must resolve to exactly one file, never a
  # pattern. Backslashes are also refused because this RHS is emitted raw.
  case "$1" in *'\'*|*'*'*|*'?'*|*'['*|*']'*) return 1 ;; esac
  printf '%s' "$1"
}

fs_systemd_envfile_status() { # <unit> <expected-path> -> ready|legacy-quoted|absent|manual
  local expected
  expected=$(fs_systemd_envfile_path "$2") || { printf 'manual'; return 0; }
  python3 - "$1" "$expected" <<'PY' 2>/dev/null
import os, sys

path, expected = sys.argv[1:3]
try:
    if os.path.islink(path):
        raise ValueError("symlink")
    raw = open(path, encoding="utf-8").read()
except Exception:
    print("manual"); sys.exit(0)

section = ""
values = []
for physical in raw.splitlines():
    if physical.endswith("\\"):
        print("manual"); sys.exit(0)
    stripped = physical.strip()
    if not stripped or stripped.startswith(("#", ";")):
        continue
    if stripped.startswith("[") and stripped.endswith("]"):
        section = stripped[1:-1].strip()
        continue
    if section != "Service" or "=" not in physical:
        continue
    key, value = physical.split("=", 1)
    if key.strip() == "EnvironmentFile":
        values.append(value.strip())

if not values:
    print("absent"); sys.exit(0)
if len(values) != 1:
    print("manual"); sys.exit(0)
legacy = '"' + expected.replace("\\", "\\\\").replace('"', '\\"') + '"'
if values[0] == expected:
    print("ready")
elif values[0] == legacy:
    print("legacy-quoted")
else:
    print("manual")
PY
}

fs_repair_systemd_envfile_exact() { # <unit> <expected-path>
  local expected
  expected=$(fs_systemd_envfile_path "$2") || return 1
  python3 - "$1" "$expected" <<'PY' 2>/dev/null
import os, stat, sys

path, expected = sys.argv[1:3]
if os.path.islink(path):
    sys.exit(1)
st = os.stat(path, follow_symlinks=False)
if not stat.S_ISREG(st.st_mode):
    sys.exit(1)
raw = open(path, encoding="utf-8").readlines()
legacy = '"' + expected.replace("\\", "\\\\").replace('"', '\\"') + '"'
section = ""
hits = []
for i, physical in enumerate(raw):
    body = physical.rstrip("\r\n")
    if body.endswith("\\"):
        sys.exit(1)
    stripped = body.strip()
    if not stripped or stripped.startswith(("#", ";")):
        continue
    if stripped.startswith("[") and stripped.endswith("]"):
        section = stripped[1:-1].strip()
        continue
    if section != "Service" or "=" not in body:
        continue
    key, value = body.split("=", 1)
    if key.strip() == "EnvironmentFile":
        hits.append((i, value.strip()))
if len(hits) != 1 or hits[0][1] != legacy:
    sys.exit(1)
i = hits[0][0]
ending = "\r\n" if raw[i].endswith("\r\n") else "\n"
raw[i] = "EnvironmentFile=" + expected + ending
parent = os.path.dirname(path)
tmp = os.path.join(parent, ".%s.conduck-tmp-%d" %
                   (os.path.basename(path), os.getpid()))
fd = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY, st.st_mode & 0o777)
try:
    with os.fdopen(fd, "w", encoding="utf-8", newline="") as out:
        out.writelines(raw)
        out.flush()
        os.fsync(out.fileno())
    os.replace(tmp, path)
    directory = os.open(parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
except Exception:
    try:
        os.unlink(tmp)
    except Exception:
        pass
    raise
PY
}

fs_envfile_exposure_warning() {
  warn "I did not change any pre-existing HTTPS exposure for this file port."
  warn "If you mapped it yourself, turn that exact mapping off until local authentication passes."
}

ensure_existing_fs_envfile_linux() {
  local expected status env_cred unit_name
  expected=$(state_env_file)
  status=$(fs_systemd_envfile_status "$FS_UNIT" "$expected")
  case "$status" in
    ready|legacy-quoted) ;;
    absent)
      # Older units with --pass on argv predate EnvironmentFile and remain
      # readable (with the existing ps-visible warning). A credential recovered
      # only from state cannot authenticate a unit that has no password source.
      $FS_CRED_LEGACY_ARGV && return 0
      warn "The existing file-server unit has no usable EnvironmentFile directive."
      warn "I will not expose it because its saved password is not wired into rclone."
      fs_envfile_exposure_warning
      return 1 ;;
    *)
      warn "The existing file-server unit has an EnvironmentFile form this script will not rewrite."
      warn "Repair or remove that exact file-server unit, then re-run setup."
      fs_envfile_exposure_warning
      return 1 ;;
  esac

  env_cred=$(env_get "$expected" "RCLONE_PASS" 2>/dev/null || true)
  if ! credential_value_safe "$env_cred" || [ "$env_cred" != "$FS_CRED" ]; then
    warn "The unit's environment file is missing or does not match its saved password."
    warn "Refusing to rewrite or expose it; repair/remove the exact unit and re-run."
    fs_envfile_exposure_warning
    return 1
  fi
  [ "$status" = "ready" ] && return 0

  warn "A file server this script set up earlier uses the old quoted EnvironmentFile form."
  # Wording verified against rclone 1.74: `--user conduck` with no password does
  # NOT serve openly. It demands an EMPTY password, so the saved password gets
  # 401 like every other one. Calling that "unauthenticated" sends the operator
  # hunting for an intrusion, when the real symptom is attachments that can never
  # authenticate.
  note "systemd treats those quotes as part of the path, so rclone never reads the password"
  note "file and demands an EMPTY password instead: it answers 401 to the saved password —"
  note "and to every other password — while the user 'conduck' with a blank password gets in."
  note "I can replace only that one directive with the same absolute path unquoted,"
  note "then reload and restart this unit."
  if $DRY_RUN; then
    plan_add "REPAIR legacy quoted EnvironmentFile in $FS_UNIT; daemon-reload + restart"
    note "(dry-run: a real run asks before repairing that file-server unit)"
    return 0
  fi
  if $REUSE_ONLY; then
    warn "(reuse-only: not repairing the legacy unit; leaving the file lane out)"
    return 1
  fi
  if ! confirm "  Repair that file-server unit now?" "file.unit.repair_envfile"; then
    note "Leaving the file lane out; chat is unaffected."
    fs_envfile_exposure_warning
    return 1
  fi
  mutate_guard "repair the legacy EnvironmentFile directive in that file-server unit" || return 1
  fs_repair_systemd_envfile_exact "$FS_UNIT" "$expected" || {
    warn "The exact legacy directive changed or could not be repaired safely."
    fs_envfile_exposure_warning
    return 1
  }
  unit_name=$(basename "$FS_UNIT")
  systemctl --user daemon-reload \
    && systemctl --user restart "$unit_name" \
    && [ "$(fs_systemd_envfile_status "$FS_UNIT" "$expected")" = "ready" ] \
    && systemctl --user is-active --quiet "$unit_name" || {
      warn "The repaired unit did not reload and re-check active; leaving the lane out."
      fs_envfile_exposure_warning
      return 1
    }
  ok "Legacy EnvironmentFile repaired and the exact file-server unit restarted."
  return 0
}

# Binding is the only portable, race-minimising answer to "is this port free?"
# Connector-owned units are ALSO reserved even while stopped: otherwise a second
# gateway can steal 5006 today and collide when the first unit starts tomorrow.
fs_port_bind_free() { # fs_port_bind_free <port>
  python3 - "$1" <<'PY' >/dev/null 2>&1
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
}

fs_port_owned_by_unit() { # fs_port_owned_by_unit <port>
  local want="$1" unit p
  while IFS= read -r unit; do
    p=$(fs_unit_port "$unit" 2>/dev/null || true)
    [ "$p" = "$want" ] && return 0
  done < <(fs_all_units)
  return 1
}

fs_owned_unit_ports_safe() {
  local unit p
  while IFS= read -r unit; do
    p=$(fs_unit_port "$unit" 2>/dev/null || true)
    if [ -z "$p" ]; then
      FS_PORT_ALLOCATION_REASON="Found the file-server unit $unit, which this script set up earlier, but its loopback port cannot be read safely. Repair or remove that unit before adding another file lane."
      return 1
    fi
  done < <(fs_all_units)
  return 0
}

fs_unit_is_legacy() {
  case "$(basename "$1")" in
    conduck-files.service|conduck-fileserver.service|\
    ai.gigaduck.conduck-files.plist|ai.gigaduck.conduck-fileserver.plist) return 0 ;;
    *) return 1 ;;
  esac
}

# A pre-per-gateway unit may be adopted once, but after a saved profile ties its
# port to another gateway it must not silently become this gateway's lane too.
fs_legacy_claimed_by_other_gateway() { # <legacy-unit>
  local port
  port=$(fs_unit_port "$1" 2>/dev/null || true)
  [ -n "$port" ] || return 0
  python3 - "$STATE_DIR" "$GW_ID" "$port" <<'PY' >/dev/null 2>&1
import glob, json, os, sys
state, current, port = sys.argv[1:4]
for p in glob.glob(os.path.join(state, "profile-*.json")):
    try: d = json.load(open(p))
    except Exception: continue
    gw, fs = d.get("gateway") or {}, d.get("fileServer")
    if not isinstance(fs, dict): continue
    if str(fs.get("localPort") or "") == port and (gw.get("id") or "") != current:
        sys.exit(0)
sys.exit(1)
PY
}

allocate_fs_local_port() {
  local p="$FS_PORT_START"
  FS_PORT_ALLOCATION_REASON=""
  case "$FS_PORT_START:$FS_PORT_END" in
    *[!0-9:]*|:*) die "Internal file-port range is invalid." ;;
  esac
  [ "$FS_PORT_START" -ge 1 ] 2>/dev/null && [ "$FS_PORT_END" -le 65535 ] 2>/dev/null \
    && [ "$FS_PORT_START" -le "$FS_PORT_END" ] 2>/dev/null \
    || die "Internal file-port range is invalid."
  # A stopped malformed unit is still a future listener. If we cannot recover
  # its port, allocating around only the parseable units could create a latent
  # collision when that service starts later. Refuse the new lane instead.
  fs_owned_unit_ports_safe || return 1
  while [ "$p" -le "$FS_PORT_END" ]; do
    if [ "$p" != "${GW_LOCAL_PORT:-}" ] \
       && ! fs_port_owned_by_unit "$p" \
       && fs_port_bind_free "$p"; then
      FS_LOCAL_PORT="$p"
      return 0
    fi
    p=$((p+1))
  done
  FS_PORT_ALLOCATION_REASON="No free loopback port in $FS_PORT_START-$FS_PORT_END for a new file lane."
  return 1
}

# Find an existing file-server unit (script OR app generated) and recover its
# config: local port + credential + served folder. Sets FS_LOCAL_PORT + FS_CRED +
# FS_UNIT + FS_FOLDER. The folder parse is load-bearing: setup/show-code use that
# structurally recovered live root to guard the agent's local output snapshot.
existing_fs_config() {
  local unit="" f
  FS_EXISTING_UNSAFE=false
  if [ "$OS" = "Linux" ]; then
    while IFS= read -r f; do [ -f "$f" ] && { unit="$f"; break; }; done < <(linux_unit_candidates)
  else
    while IFS= read -r f; do [ -f "$f" ] && { unit="$f"; break; }; done < <(mac_unit_candidates)
  fi
  [ -n "$unit" ] || return 1
  if fs_unit_is_legacy "$unit" && fs_legacy_claimed_by_other_gateway "$unit"; then
    note "The legacy file-server unit on port $(fs_unit_port "$unit") is already tied to another saved gateway; not reusing it for $GW_ID."
    return 1
  fi
  FS_UNIT="$unit"

  # addr port: systemd ExecStart carries `--addr 127.0.0.1:PORT` on one line, but
  # a plist splits it across two <string> elements — parse those STRUCTURALLY, or
  # a lane on a non-default port silently falls back to 5006 and probes nothing.
  local port=""
  port=$(fs_unit_port "$unit" 2>/dev/null || true)
  if [ -z "$port" ]; then
    warn "Found $unit, but its loopback port could not be read safely."
    FS_EXISTING_UNSAFE=true
    FS_UNIT=""
    return 1
  fi
  FS_LOCAL_PORT="$port"

  # The same structural parse yields the exact argv element after `webdav`.
  FS_FOLDER=$(fs_unit_field "$unit" folder 2>/dev/null || true)
  if [ -z "$FS_FOLDER" ]; then
    warn "Found $unit, but its served folder could not be read safely."
    FS_EXISTING_UNSAFE=true
    FS_UNIT=""
    return 1
  fi

  # credential: prefer our 0600 state cred file; else env file RCLONE_PASS; else
  # recover it from the unit. Plists are parsed STRUCTURALLY (`<string>--pass</string>`
  # never matches a text regex). Track whether it came from argv (visible via `ps`).
  FS_CRED=""; FS_CRED_LEGACY_ARGV=false
  if [ -f "$(state_cred_file)" ]; then FS_CRED=$(cat "$(state_cred_file)")
  elif [ -f "$(state_env_file)" ]; then FS_CRED=$(env_get "$(state_env_file)" "RCLONE_PASS")
  elif [ "${unit##*.}" = "plist" ]; then
    FS_CRED=$(fs_unit_field "$unit" argv_cred 2>/dev/null || true)
    if [ -n "$FS_CRED" ]; then
      FS_CRED_LEGACY_ARGV=true
    else
      FS_CRED=$(fs_unit_field "$unit" env_cred 2>/dev/null || true)
    fi
  else
    FS_CRED=$(fs_unit_field "$unit" argv_cred 2>/dev/null || true)
    [ -n "$FS_CRED" ] && FS_CRED_LEGACY_ARGV=true
  fi
  # The `ps`-visible-credential warning keys off the UNIT, not off which source the
  # cred was read from: a leftover state-cred file must not mask an argv-exposed unit.
  if ! $FS_CRED_LEGACY_ARGV; then
    local argv_exposed=""
    argv_exposed=$(fs_unit_field "$unit" argv_exposed 2>/dev/null || true)
    [ -n "$argv_exposed" ] && FS_CRED_LEGACY_ARGV=true
  fi
  if ! credential_value_safe "$FS_CRED"; then
    warn "Found $unit, but its file-server password could not be recovered safely."
    FS_EXISTING_UNSAFE=true
    FS_UNIT=""
    return 1
  fi
  return 0
}

# systemd stops a user's manager — and every unit under it — shortly after that
# user's LAST session ends, unless lingering is on; lingering is also what starts
# the manager at boot. So a file lane that verifies green inside the SSH session
# that created it is not yet a lane that survives logout or reboot, and this is a
# 24/7 gateway product.
#
# Asked against `id -un`, never `$USER`: `$USER` is inherited across `su` and
# `sudo -u` and can name an account whose linger state has nothing to do with the
# user manager `systemctl --user` is actually driving — which would answer
# "durable" about the wrong user and suppress the warning.
fs_linger_enabled_linux() {
  have loginctl || return 1
  loginctl show-user "$(id -un 2>/dev/null)" 2>/dev/null | grep -q '^Linger=yes'
}

# Report — and offer to fix — the one setting that decides whether a green file
# lane is still a file lane tomorrow. Runs for NEW and REUSED units alike: a lane
# created without lingering is re-shipped by every later run, so checking only at
# creation would warn exactly once and stay silent forever after. Never gates the
# lane; it tells the truth in the same run that ships it.
fs_report_linger_linux() {
  fs_linger_enabled_linux && return 0
  local u priv privcmd=()
  u=$(id -un 2>/dev/null)
  # `loginctl` is what both reads and sets lingering, so without it the honest
  # answer is "unknown", never "off" — the two need different words.
  if ! have loginctl; then
    warn "No 'loginctl' on this box, so I can't tell whether systemd keeps '$u' services"
    warn "running after logout. If it doesn't, the file lane stops answering when '$u' logs out."
    return 0
  fi
  priv=$(priv_prefix); [ -n "$priv" ] && privcmd=("$priv")
  warn "Lingering is off for '$u', so systemd stops this user's services shortly after"
  warn "its last logout — the file lane would stop answering then, and not come back on reboot."
  # --reuse-only forbids host changes, and offering this through run_step would
  # reach mutate_guard's `die` — killing a run whose whole point was to re-emit an
  # existing lane. State the fact, hand over the command, change nothing.
  if $REUSE_ONLY && ! $DRY_RUN; then
    note "(reuse-only: changing nothing.) Turn it on yourself with:  ${priv:+$priv }loginctl enable-linger $u"
    return 0
  fi
  run_step "file.service.enable_linger" "enable linger so the file server survives logout and reboot" \
    ${privcmd[@]+"${privcmd[@]}"} loginctl enable-linger "$u" || true
  $DRY_RUN && return 0
  if fs_linger_enabled_linux; then
    ok "Lingering is on for '$u' — the file server survives logout and reboot."
    return 0
  fi
  warn "The file lane still ships in your setup code, but it only answers while '$u' has a"
  warn "live session. Make it permanent any time with:  ${priv:+$priv }loginctl enable-linger $u"
  [ "$(id -u 2>/dev/null)" = 0 ] || [ -n "$priv" ] || note "That one needs root (no sudo/doas here)."
  return 0
}

# Write a per-gateway file-server unit that reads RCLONE_PASS from a 0600 env file
# (credential never appears on the process command line / in `ps`).
write_fs_unit_linux() { # write_fs_unit_linux <workspace>
  local ws="$1" envf credf rclone_bin q_ws env_directive q_rclone
  envf=$(state_env_file)
  credf=$(state_cred_file)
  rclone_bin=$(command -v rclone)
  if ! credential_value_safe "$FS_CRED" \
     || ! q_ws=$(fs_systemd_quote "$ws") \
     || ! env_directive=$(fs_systemd_envfile_path "$envf") \
     || ! q_rclone=$(fs_systemd_quote "$rclone_bin"); then
    warn "The file password or selected paths contain characters this systemd unit cannot encode safely."
    return 1
  fi
  FS_UNIT="${HOME:-}/.config/systemd/user/conduck-files-$GW_ID.service"
  # Two mkdirs, deliberately: the systemd unit directory is shared with the rest
  # of the user's units and keeps the ambient mode, while $STATE_DIR goes through
  # ensure_state_dir — it holds fileserver-*.cred/.env and profile-*.json, so it
  # is created 0700 and an already-open one is reported rather than left silent.
  mkdir -p "$(dirname "$FS_UNIT")"
  ensure_state_dir
  # Scoped, never bare. A bare `umask 077` here persists for the rest of the
  # process and silently tightens every later write — TOOLS.md then landed 0600
  # and the containerized agent, running as a different uid, could not read the
  # guidance block the wizard had just reported installing.
  #
  # Create-and-chmod BEFORE writing: a mask only governs CREATION, so a stale
  # 0644 file left by an earlier run would otherwise hold the credential for the
  # window between the write and the chmod.
  ( umask 077; : >> "$envf" ) && chmod 600 "$envf" || return 1
  printf 'RCLONE_PASS=%s\n' "$FS_CRED" > "$envf" || return 1
  ( umask 077; : >> "$credf" ) && chmod 600 "$credf" || return 1
  printf '%s\n' "$FS_CRED" > "$credf" || return 1
  # systemd ExecStart: quote the workspace; rclone reads --user, pass via env.
  # --dir-cache-time 1s: rclone's VFS caches directory listings (default 5m), so a
  # file the AGENT writes directly into the folder (bypassing WebDAV) stays
  # invisible to the server — Conduck's output-file probe fires seconds after the
  # reply and would 404. 1s makes agent-written files appear immediately;
  # re-listing a small local folder per request costs nothing. Keep the flag
  # AFTER --user: the re-parse extracts the folder between `serve webdav` and
  # `--addr` (systemd) / as the element after "webdav" (plist).
  cat > "$FS_UNIT" <<EOF
[Unit]
Description=Conduck agent file server ($GW_ID, rclone WebDAV)
After=network.target

[Service]
EnvironmentFile=$env_directive
ExecStart=$q_rclone serve webdav $q_ws --addr 127.0.0.1:$FS_LOCAL_PORT --user conduck --dir-cache-time 1s
Restart=on-failure

[Install]
WantedBy=default.target
EOF
  # The unit names the EnvironmentFile rather than carrying the credential, so
  # its mode is not a secrecy boundary — but it is 0600 today and stays 0600
  # explicitly now that the mask above no longer leaks this far. Mirrors the
  # mac twin's chmod on its plist.
  chmod 600 "$FS_UNIT" || return 1
  systemctl --user daemon-reload || return 1
  if systemctl --user enable --now "conduck-files-$GW_ID.service"; then
    ok "File server running in the background (a systemd user service)."
  else
    warn "Could not start the service — check 'systemctl --user status conduck-files-$GW_ID'."
    return 1
  fi
  fs_report_linger_linux
}

write_fs_unit_mac() { # write_fs_unit_mac <workspace>
  credential_value_safe "$FS_CRED" || {
    warn "The file password contains control characters and cannot be stored safely."
    return 1
  }
  FS_UNIT="${HOME:-}/Library/LaunchAgents/ai.gigaduck.conduck-files-$GW_ID.plist"
  # Split for the same reason as the Linux twin: LaunchAgents is shared with the
  # user's other agents and keeps the ambient mode; $STATE_DIR holds credentials
  # and profile-*.json, so it goes through ensure_state_dir.
  mkdir -p "$(dirname "$FS_UNIT")"
  ensure_state_dir
  # Same scoping and same create-then-secure-then-write order as the Linux twin
  # (see the comment there): a bare mask leaked into every later write, and a
  # mask cannot tighten a file that already exists.
  local credf; credf=$(state_cred_file)
  ( umask 077; : >> "$credf" ) && chmod 600 "$credf" || return 1
  printf '%s\n' "$FS_CRED" > "$credf" || return 1
  # Build the plist structurally with plistlib (correct escaping for any path).
  # Unlike the Linux unit this file DOES embed the credential
  # (EnvironmentVariables.RCLONE_PASS), so it is secured before plistlib opens
  # it; the chmod below stays as the durable guarantee.
  ( umask 077; : >> "$FS_UNIT" ) && chmod 600 "$FS_UNIT" || return 1
  RCLONE_BIN="$(command -v rclone)" WS="$1" PORT="$FS_LOCAL_PORT" CRED="$FS_CRED" \
  LABEL="ai.gigaduck.conduck-files-$GW_ID" PLIST="$FS_UNIT" python3 - <<'PY' || return 1
import os,plistlib
d={
 "Label": os.environ["LABEL"],
 "ProgramArguments": [os.environ["RCLONE_BIN"],"serve","webdav",os.environ["WS"],
                      "--addr","127.0.0.1:"+os.environ["PORT"],"--user","conduck",
                      "--dir-cache-time","1s"],
 "EnvironmentVariables": {"RCLONE_PASS": os.environ["CRED"]},
 "RunAtLoad": True, "KeepAlive": True,
}
with open(os.environ["PLIST"],"wb") as f: plistlib.dump(d,f)
PY
  chmod 600 "$FS_UNIT"
  launchctl unload "$FS_UNIT" 2>/dev/null || true
  if launchctl load -w "$FS_UNIT"; then
    ok "File server running in the background (a macOS LaunchAgent that restarts it automatically)."
  else
    warn "Could not load the LaunchAgent — check 'launchctl list | grep conduck'."
    return 1
  fi
  note "LaunchAgents run while this user is logged in — for a 24/7 Mac, keep automatic login on."
  if pmset -g 2>/dev/null | grep -qE '^[[:space:]]*sleep[[:space:]]+[1-9]'; then
    warn "This Mac is set to sleep — a sleeping host isn't reachable 24/7."
    note "For an always-on gateway: enable automatic login + 'sudo pmset -a sleep 0'."
  fi
}

fs_unit_label() { # fs_unit_label -> the launchd Label in $FS_UNIT (empty when unreadable)
  [ -n "$FS_UNIT" ] || return 0
  python3 - "$FS_UNIT" <<'PY' 2>/dev/null
import plistlib, sys
try:
    print(plistlib.load(open(sys.argv[1], "rb")).get("Label", ""))
except Exception:
    pass
PY
}

# A unit file existing is not readiness: it may be disabled, crash-looping, or
# shadowed by another process on the same port. `unknown` is its own answer, never
# folded into `inactive`: with no systemctl/launchctl we cannot ask, and reporting
# a healthy service as dead sends the operator debugging something that is fine.
fs_unit_state() { # fs_unit_state -> active | inactive | unknown
  [ -n "$FS_UNIT" ] || { printf 'unknown'; return 0; }
  if [ "$OS" = "Linux" ]; then
    have systemctl || { printf 'unknown'; return 0; }
    # Read what systemctl SAYS, not merely whether it succeeded. A non-zero exit
    # covers two different facts: the unit is stopped, and this shell could not
    # ask at all. `systemctl --user` with no session bus — su, sudo -u, cron, a
    # remote command against a lingering account — fails with "Failed to connect
    # to bus" and prints nothing. Folding that into "inactive" tells an operator
    # their running file server is stopped, which is exactly the invention this
    # surface exists to avoid; `unknown` already has honest wording waiting for
    # it at every call site. Measured on a lingering account: running prints
    # "active", stopped prints "inactive", an unreachable bus prints nothing.
    # Callers still fail closed, because `unknown` is not `active` either.
    local out
    out=$(systemctl --user is-active "$(basename "$FS_UNIT")" 2>/dev/null)
    case "$out" in
      active) printf 'active' ;;
      "")     printf 'unknown' ;;
      *)      printf 'inactive' ;;
    esac
  else
    have launchctl || { printf 'unknown'; return 0; }
    local label
    label=$(fs_unit_label)
    [ -n "$label" ] || { printf 'unknown'; return 0; }
    if launchctl list "$label" >/dev/null 2>&1; then
      printf 'active'
    else
      printf 'inactive'
    fi
  fi
}

# Confirm the supervisor owns a live process before any HTTPS exposure is created.
# Fails closed on `unknown`: an exposure is created from this answer.
fs_unit_active() { [ "$(fs_unit_state)" = "active" ]; }

# The exact commands that remove ONE file server this script set up. Shared by
# every caller so they cannot drift, and printed rather than run: this tool has no
# removal command, so copy-pasteable text IS the mechanism.
#
# The saved profile is deliberately NOT in this list — see fs_print_lane_record_note
# for the one caller that needs it. A file server can be removed for two different
# reasons, and only one of them touches the profile: abandoning the lane leaves the
# saved record advertising an address that no longer answers, while MOVING the lane
# to another port leaves that record entirely correct. Folding an `rm` of the
# profile in here would hand the port-move path a command that deletes the gateway.
fs_print_teardown() { # fs_print_teardown <unit-path-or-empty> [password-file…]
  local unit="$1" name f; shift
  if [ -n "$unit" ]; then
    name=$(basename "$unit")
    if [ "$OS" = "Linux" ]; then
      printf '    %ssystemctl --user disable --now %s%s\n' "$BOLD" "$(fs_shell_arg "$name")" "$RESET"
      # A unit that crash-looped into systemd's start-rate limit stays `failed`
      # even once its file is gone, and only reset-failed clears that entry.
      printf '    %ssystemctl --user reset-failed %s%s\n' "$BOLD" "$(fs_shell_arg "$name")" "$RESET"
      printf '    %srm -f %s%s\n' "$BOLD" "$(fs_shell_arg "$unit")" "$RESET"
      printf '    %ssystemctl --user daemon-reload%s\n' "$BOLD" "$RESET"
    else
      printf '    %slaunchctl unload %s%s\n' "$BOLD" "$(fs_shell_arg "$unit")" "$RESET"
      printf '    %srm -f %s%s\n' "$BOLD" "$(fs_shell_arg "$unit")" "$RESET"
    fi
  fi
  for f in "$@"; do
    printf '    %srm -f %s%s\n' "$BOLD" "$(fs_shell_arg "$f")" "$RESET"
  done
}

# The half of the teardown that lives in $STATE_DIR rather than in a service
# manager. profile-<id>.json is what --show-code reads, so an operator who runs
# the commands above and stops there keeps a saved gateway that still advertises a
# file lane: every later --show-code prints a code whose file address answers
# nothing, and the failure surfaces in the app, on a phone, days later.
#
# Only printed when the saved record actually carries a fileServer block, because
# the usual case is the harmless one — this run goes on to pair chat-only, and
# write_profile rewrites the record without the lane on its own. It is the runs
# that DON'T reach a new profile that strand it: a failed verification, a run
# stopped at a prompt, a --reuse-only pass, or a lane a check dropped, all of which
# leave the previous profile deliberately untouched.
#
# Re-running setup is offered first and the rm second, and that order is the point:
# re-running rewrites the same record without the lane, while the rm throws away
# the gateway's address, model and transport along with it.
fs_print_lane_record_note() {
  [ -n "${GW_ID:-}" ] || return 0
  local pf="$STATE_DIR/profile-$GW_ID.json"
  [ -f "$pf" ] || return 0
  [ "$(json_type "$pf" "fileServer")" = "object" ] || return 0
  say ""
  warn "Your saved record for this gateway still lists that file lane:"
  note "$pf"
  note "Until it is updated, --show-code keeps printing a code whose file address answers nothing."
  say "  Re-run me after removing the file server and I rewrite that record without the lane."
  say "  Or, to forget this gateway entirely (its address, model and transport go too):"
  printf '    %srm -f %s%s\n' "$BOLD" "$(fs_shell_arg "$pf")" "$RESET"
}

# A lane that is BUILT but never shipped leaves a live, authenticated WebDAV
# server over the agent's working folder, a credential on disk, and — on the
# transports whose HTTPS route the operator creates by hand — a route still
# pointing at it. Only Tailscale mappings get rolled back (they are the only
# exposure this connector applies itself), so on the other transports the run
# otherwise ends green and never mentions the server, the credential, or the
# route again. Same shape whether a Step-5 probe failed or the run was
# interrupted between the unit and the setup code.
#
# It removes nothing: the usual repair is "fix what failed and re-run me", and
# that re-run reuses this exact unit and credential. So name what exists and hand
# the removal commands to the operator who does want it gone.
#
# Silent when the lane IS shipping, in a dry run, and after its first call, which
# makes it safe to call from every drop path — including an exit trap.
fs_lane_residue_note() {
  $FS_LANE_PREPARED || return 0
  $FS_RESIDUE_REPORTED && return 0
  $DRY_RUN && return 0
  [ -z "$FS_URL" ] || [ -z "$FS_CRED" ] || return 0   # a shipped lane is not residue
  local unit="" f
  local files=()
  [ -n "$FS_UNIT" ] && [ -f "$FS_UNIT" ] && unit="$FS_UNIT"
  for f in "$(state_cred_file)" "$(state_env_file)"; do
    [ -f "$f" ] && files+=("$f")
  done
  # Nothing on disk means nothing to report — an early refusal that got as far as
  # naming a folder but never wrote a unit or a credential leaves no server.
  [ -n "$unit" ] || [ ${#files[@]} -gt 0 ] || return 0
  FS_RESIDUE_REPORTED=true

  say ""
  if $FS_UNIT_CREATED_THIS_RUN; then
    warn "Before you close this terminal: this run started a file server, and the setup code above"
    warn "does NOT carry it."
  else
    warn "Before you close this terminal: this gateway's file server keeps running, and the setup"
    warn "code above does NOT carry it."
  fi
  if [ -n "$unit" ]; then
    note "service:    $unit"
    if [ "$OS" = "Linux" ]; then
      note "            (a systemd user service, enabled — it starts again at boot)"
    else
      note "            (a LaunchAgent with KeepAlive — it starts again at login)"
    fi
  fi
  local served="$FS_FOLDER"
  [ -n "$served" ] || served="the folder in its service definition"
  note "serving:    $served  →  http://127.0.0.1:${FS_LOCAL_PORT:-?}"
  for f in ${files[@]+"${files[@]}"}; do
    note "password:   $f"
  done
  if $FS_ROUTE_SELF_MANAGED; then
    warn "The HTTPS route you set up for it still points at 127.0.0.1:${FS_LOCAL_PORT:-?}. That route lives in"
    warn "your own web server or tunnel config, so I can't remove it for you — for as long as it is up,"
    warn "this file server answers wherever that address answers, guarded only by its password."
  fi
  say ""
  say "  To remove the file server (chat and the code above are unaffected):"
  fs_print_teardown "$unit" ${files[@]+"${files[@]}"}
  note "The shared folder itself is left alone — on OpenClaw and Hermes it doubles as the agent's"
  note "own working directory."
  note "Leaving it running is fine too: fix what failed, re-run me, and this same lane ships again"
  note "with the same password."
  # Last, because it is the one part of the residue that is not on this machine's
  # service manager, and the one a reader who stopped at the commands above will
  # otherwise never learn about.
  fs_print_lane_record_note
  return 0
}

# "The unit exists but is not active" has one dominant cause, and it is this
# connector's own race: the free-port check is a bind probe seconds before
# rclone's own bind, so any process on the host can take that port in the gap.
# rclone then exits, systemd retries it into its start-rate limit, and the unit
# sits `failed` for good — while every later run re-finds it, refuses to expose
# it, and ends green. The operator's symptom is "attachments just never work".
# So: name the unit, hand over the command that says WHY, and offer the one fix
# that resolves it — move the lane to another free port.
# Returns 0 ONLY when the lane is live again (on a new port) and safe to continue.
fs_inactive_unit_report() {
  local state unit_name old_unit old_port uid
  state=$(fs_unit_state)
  unit_name=$(basename "${FS_UNIT:-unknown}")
  if [ "$state" = "unknown" ]; then
    warn "I can't get a usable answer from this machine's service manager about whether"
    warn "the file server is running,"
    warn "so I won't expose it."
    [ -n "$FS_UNIT" ] && note "service: $FS_UNIT"
    return 1
  fi
  warn "The file-server service exists but is not active — refusing to expose it."
  note "service:  ${FS_UNIT:-unknown}"
  note "serving:  ${FS_FOLDER:-unknown folder}  →  http://127.0.0.1:${FS_LOCAL_PORT:-?}"
  say ""
  say "  What it says about itself:"
  if [ "$OS" = "Linux" ]; then
    printf '    %ssystemctl --user status %s%s\n' "$BOLD" "$(fs_shell_arg "$unit_name")" "$RESET"
    printf '    %sjournalctl --user -u %s -n 50 --no-pager%s\n' "$BOLD" "$(fs_shell_arg "$unit_name")" "$RESET"
  else
    uid=$(id -u 2>/dev/null || true)
    printf '    %slaunchctl print gui/%s/%s%s\n' "$BOLD" "${uid:-<your-uid>}" "$(fs_shell_arg "$(fs_unit_label)")" "$RESET"
  fi
  note "The usual cause: another process took port ${FS_LOCAL_PORT:-?} between my free-port check and rclone's"
  note "own bind, so rclone couldn't listen. After a few retries the service manager stops trying,"
  note "and the port stays taken — which is why re-running me alone never fixes it."
  $DRY_RUN && return 1
  if [ -z "$FS_FOLDER" ] || [ -z "$FS_CRED" ]; then
    note "I can't rebuild it here — its served folder or password isn't recoverable. Remove the unit"
    note "and re-run me to build the lane again."
    return 1
  fi
  if $REUSE_ONLY; then
    note "(reuse-only: not moving the lane to another port — re-run without --reuse-only to do that.)"
    return 1
  fi
  if ! confirm "  Move this file lane to a different free port and start it there?" "file.service.move_port"; then
    note "Leaving the file lane out of this setup code; chat is unaffected."
    return 1
  fi
  mutate_guard "rewrite the file-server unit on a different loopback port" || return 1
  old_unit="$FS_UNIT"; old_port="$FS_LOCAL_PORT"
  if ! allocate_fs_local_port; then
    warn "${FS_PORT_ALLOCATION_REASON:-No free loopback port for the file lane right now.}"
    FS_LOCAL_PORT="$old_port"
    return 1
  fi
  # systemd's start-rate limiter is what makes the wedge permanent: until the
  # counter is reset the unit refuses to start at all, and daemon-reload does not
  # reset it — so a rewritten ExecStart on a free port would still not run.
  if [ "$OS" = "Linux" ] && have systemctl; then
    systemctl --user reset-failed "$unit_name" >/dev/null 2>&1 || true
  fi
  FS_UNIT_CREATED_THIS_RUN=true   # from here on this run owns writing and starting it
  local wrote=true live_port
  if [ "$OS" = "Linux" ]; then
    write_fs_unit_linux "$FS_FOLDER" || wrote=false
  else
    write_fs_unit_mac "$FS_FOLDER" || wrote=false
  fi
  if ! $wrote || ! fs_unit_active; then
    # Whatever is on disk is the authority on which port this lane now names — the
    # residue report that follows must name the port the unit really carries, not
    # the one this attempt hoped for.
    live_port=$(fs_unit_port "$FS_UNIT" 2>/dev/null || true)
    if [ -n "$live_port" ]; then FS_LOCAL_PORT="$live_port"; else FS_LOCAL_PORT="$old_port"; fi
    warn "The file server still isn't running — leaving the file lane out of this setup code."
    return 1
  fi
  ok "File lane moved to port $FS_LOCAL_PORT and its service is running again."
  # A unit under one of the pre-per-gateway names is NOT the file the writer just
  # wrote, so the wedged one is still on this machine, still enabled, still failing.
  if [ -n "$old_unit" ] && [ "$old_unit" != "$FS_UNIT" ] && [ -f "$old_unit" ]; then
    warn "The old unit is still on this machine and still fails to start:"
    note "  $old_unit"
    say "  Remove it:"
    fs_print_teardown "$old_unit"
  fi
  note "Anything that already pointed an HTTPS route at 127.0.0.1:$old_port now points at nothing —"
  note "the lane answers on $FS_LOCAL_PORT from here on."
  return 0
}

fs_local_curl() { # fs_local_curl <real|wrong|none> <curl args…>
  local kind="$1"; shift
  case "$kind" in
    real)
      credential_value_safe "$FS_CRED" || return 2
      local cred="$FS_CRED"
      cred="${cred//\\/\\\\}"; cred="${cred//\"/\\\"}"
      printf 'user = "conduck:%s"\n' "$cred" \
        | curl -q -sS --max-time 5 --noproxy '*' --config - "$@" ;;
    wrong)
      curl -q -sS --max-time 5 --noproxy '*' \
        -u "conduck:conduck-connect-deliberately-wrong" "$@" ;;
    none)
      curl -q -sS --max-time 5 --noproxy '*' "$@" ;;
    *) return 1 ;;
  esac
}

fs_local_code() { # fs_local_code <real|wrong|none> <curl args…>
  local kind="$1" code
  shift
  code=$(fs_local_curl "$kind" -o /dev/null -w '%{http_code}' "$@" 2>/dev/null) || true
  case "$code" in [0-9][0-9][0-9]) printf '%s' "$code" ;; *) printf '000' ;; esac
}

# Prove the exact service we will expose is active, accepts its recovered
# credential, rejects missing/wrong credentials, and serves byte-identical
# writes. This happens on loopback BEFORE creating a tunnel/Serve mapping.
fs_local_service_ready() {
  # A dead unit is a diagnosis, not a one-line refusal: fs_inactive_unit_report
  # names it, shows how to read its own log, and can re-home the lane to a free
  # port. Only a 0 from there means the service is live again and worth probing.
  fs_unit_active || fs_inactive_unit_report || return 1
  local base="http://127.0.0.1:$FS_LOCAL_PORT" i=0 code=""
  while [ "$i" -lt 20 ]; do
    code=$(fs_local_code real "$base/")
    case "$code" in 2??|3??|404) break ;; esac
    i=$((i+1)); sleep 0.25
  done
  case "$code" in 2??|3??|404) ;; *)
    warn "The active file-server service did not answer with its saved password on 127.0.0.1:$FS_LOCAL_PORT."
    return 1 ;;
  esac

  local tag probe tmp outtmp missing wrong del gone get_code local_verdict=""
  local bytes_ok=false cleanup_ok=false removed_local=false put_ok=false
  tag=$(python3 -c 'import secrets; print(secrets.token_hex(4))' 2>/dev/null) || return 1
  probe="conduck-connect-local-probe-$tag.txt"
  tmp=$(mktemp "${TMPDIR:-/tmp}/conduck-local-probe.XXXXXX" 2>/dev/null) || return 1
  outtmp=$(mktemp "${TMPDIR:-/tmp}/conduck-local-output.XXXXXX" 2>/dev/null) || {
    rm -f "$tmp"
    return 1
  }
  printf 'conduck-connect local service probe %s\n' "$tag" > "$tmp"
  code=$(fs_local_code real -T "$tmp" "$base/$probe")
  get_code="000"
  case "$code" in
    2??)
      put_ok=true
      get_code=$(fs_local_curl real -o "$outtmp" -w '%{http_code}' "$base/$probe" 2>/dev/null || true)
      case "$get_code" in 2??) cmp -s "$tmp" "$outtmp" && bytes_ok=true ;; esac
      ;;
  esac
  missing=$(fs_local_code none "$base/$probe")
  wrong=$(fs_local_code wrong "$base/$probe")
  del=$(fs_local_code real -X DELETE "$base/$probe")
  gone=$(fs_local_code real "$base/$probe")
  rm -f "$tmp" "$outtmp"

  # A 2xx DELETE alone is not proof; some broken WebDAV front ends acknowledge
  # it while leaving the object behind. Require an authenticated follow-up GET
  # to return exactly 404. If DELETE is unavailable and this exact recovered
  # root is known, remove only the randomized regular file locally and prove
  # the same 404 through WebDAV.
  case "$del:$gone" in 2??:404|404:404) cleanup_ok=true ;; esac
  if ! $cleanup_ok && [ -n "$FS_FOLDER" ]; then
    # `removed` and `absent` are deliberately different answers. Both prove the
    # exact name is not on disk, but only one of them is a removal — and claiming
    # to have removed a probe that was never stored is a false statement about
    # this run's own footprint.
    local_verdict=$(python3 - "$FS_FOLDER" "$probe" <<'PY' 2>/dev/null
import os, re, stat, sys
root, name = os.path.realpath(sys.argv[1]), sys.argv[2]
if not re.fullmatch(r"conduck-connect-local-probe-[0-9a-f]{8}\.txt", name):
    sys.exit(1)
if not os.path.isdir(root):
    sys.exit(1)
root_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
root_fd = os.open(root, root_flags)
try:
    try:
        before = os.stat(name, dir_fd=root_fd, follow_symlinks=False)
    except FileNotFoundError:
        print("absent"); sys.exit(0)
    # Never resolve or unlink through a replacement symlink. Open and re-stat
    # the exact directory entry so a swap also fails before unlinkat.
    if not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode):
        sys.exit(1)
    file_flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    file_fd = os.open(name, file_flags, dir_fd=root_fd)
    try:
        opened = os.fstat(file_fd)
        current = os.stat(name, dir_fd=root_fd, follow_symlinks=False)
        if not stat.S_ISREG(opened.st_mode) or not stat.S_ISREG(current.st_mode):
            sys.exit(1)
        if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino) \
                or (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino):
            sys.exit(1)
    finally:
        os.close(file_fd)
    os.unlink(name, dir_fd=root_fd)
    print("removed")
finally:
    os.close(root_fd)
PY
) || local_verdict=""
    case "$local_verdict" in removed) removed_local=true ;; esac
    if [ -n "$local_verdict" ]; then
      gone=$(fs_local_code real "$base/$probe")
      [ "$gone" = "404" ] && cleanup_ok=true
    fi
  fi
  if $cleanup_ok; then
    $removed_local && warn "WebDAV DELETE was not reliable (HTTP $del); removed the exact local probe directly and proved HTTP 404."
  elif $put_ok; then
    warn "Cleanup was not proven for the exact local probe $probe (DELETE HTTP $del; follow-up GET HTTP $gone)."
  else
    # The write never answered 2xx, so this run most likely never created the probe
    # at all. Reporting unproven CLEANUP here sends the operator looking through the
    # agent's folder for a file that was never written; report what the follow-up
    # GET actually proves about that exact name instead.
    local why="the file server refused the probe write (HTTP $code)"
    [ "$code" = "000" ] && why="the probe write got no answer from the file server"
    case "$gone" in
      404) warn "Nothing was left behind: $why, and an authenticated GET proves $probe is absent." ;;
      2??) warn "$probe still answers HTTP $gone although $why — remove it from ${FS_FOLDER:-the served folder} by hand." ;;
      *)   warn "I can't tell whether $probe is in ${FS_FOLDER:-the served folder}: $why, and the follow-up GET answered HTTP $gone." ;;
    esac
  fi

  if ! $bytes_ok; then
    warn "The local file server did not return the bytes just written — leaving the lane out."
    return 1
  fi
  case "$missing:$wrong" in
    401:401|401:403|403:401|403:403) ;;
    *)
      warn "The local file server did not reject both missing and wrong passwords — leaving the lane out."
      return 1 ;;
  esac
  $cleanup_ok || return 1
  ok "Local file server re-checked: active, authenticated, and byte-faithful on port $FS_LOCAL_PORT."
  return 0
}

# --- file-lane scope alignment ------------------------------------------------
# The payload carries a single, gateway-oriented `transport`, so a file lane whose
# reach (scope) differs from the gateway's is a real hazard. On a mismatch we offer
# to ALIGN the lane to the gateway, OMIT it, or INCLUDE it as-is (advanced).
# $SCOPE = the gateway's scope (public|private); the lane's is derived from its verb.

# The lane's own HTTPS mapping when it PREDATES this run. Rollback covers only
# what this run applied, and a mapping the operator made is theirs to keep — but
# leaving the lane out of the setup code does not stop that address from reaching
# an authenticated file server, so it gets named either way.
fs_note_existing_mapping() { # fs_note_existing_mapping <https-port> <verb>
  [ -n "$1" ] || return 0
  warn "Its existing Tailscale mapping is still live: port $1 → 127.0.0.1:${FS_LOCAL_PORT:-?}."
  warn "I didn't create that mapping, so I don't remove it. To take it down yourself:"
  if [ "${2:-}" = "funnel" ]; then
    printf '    %stailscale funnel --https=%s off%s   # stops the PUBLIC half\n' "$BOLD" "$1" "$RESET"
    printf '    %stailscale serve --https=%s off%s   # …and the mapping itself\n' "$BOLD" "$1" "$RESET"
  else
    printf '    %stailscale serve --https=%s off%s\n' "$BOLD" "$1" "$RESET"
  fi
}

# A quick tunnel's hostname is REASSIGNED every time `cloudflared tunnel --url`
# restarts, including at every reboot. The gateway address gets its own warning
# where it is accepted; the FILE lane needs one too, because its consequence is
# worse: this address lives ONLY inside the setup code, so after a restart the
# paired device keeps calling a hostname that no longer resolves — attachments
# fail with nothing to search for — while the same folder, behind the same
# password, comes back at a NEW public hostname that appears in no saved profile
# and in no output of this script. Nothing here can fix that (it is how the
# tunnel is designed), so the honest moment to say it is when the address is
# accepted, while the operator can still choose one that survives a restart.
fs_warn_quick_tunnel_url() {
  [ -n "$FS_URL" ] || return 0
  # 30-exposure's predicate on purpose (host-only, lowercased): a second copy of
  # a host-matching rule is how the two drift apart.
  is_quick_tunnel_url "$FS_URL" || return 0
  say ""
  warn "That file-lane address is a Cloudflare QUICK TUNNEL, and its hostname changes every time"
  warn "the tunnel restarts — a reboot, a crash, or a Ctrl-C in the terminal running it."
  warn "It is carried only inside the setup code from this run, so when it changes the app keeps"
  warn "calling a hostname that no longer exists: attachments stop working, and nothing here can"
  warn "learn the new address."
  warn "Your shared folder does come back — at a new public address, with the same password — and"
  warn "that address is in no saved profile and in no output of this script."
  say "  ${BOLD}Keep that tunnel running${RESET} for as long as you want attachments to work, and re-run this"
  say "  script for a fresh code after every restart of it."
  say "  For an address that survives a restart, give the file lane the same kind of permanent"
  say "  hostname as the gateway: a Cloudflare NAMED tunnel on a domain you manage, or Tailscale."
  say ""
}

# The file-lane address prompts accept a blank as "leave file transfer out", and
# by the time any of them runs a server EXISTS and has passed its local
# read/write check — so a blank there discards a working capability the operator
# already said yes to at "Set it up?". A fumbled paste, a stray Enter and a
# deliberate skip all arrive as the same empty string, and the cost of getting it
# wrong is a FULL re-run: --show-code re-emits the saved profile and cannot add a
# lane that was never in it.
#
# So a blank asks once, and a NO returns to the address prompt. That keeps the
# escape hatch (someone says yes, then finds they have no HTTPS route to give,
# and must not have to Ctrl-C the run) while making the skip deliberate and the
# fumble free to retry. Answering with an address costs nothing extra — the
# question exists only on the path that throws the lane away.
#
# Blank-then-EOF ends the loop: ask_url returns nonzero on a closed stdin, which
# this propagates so the caller's `|| die "$NO_ANSWER"` still fires.
#
# This helper deliberately runs in the PARENT shell and returns its value through
# ASK_FS_URL_RESULT. Both prompts accept q, and `quit_run` must exit the real
# setup process—not a command-substitution subshell that would turn q into an
# empty successful URL and continue as though the operator deliberately skipped.
# That is why the URL prompt's rc 11 is acted on here rather than folded into the
# EOF branch: the two arrive as different statuses precisely so they can lead to
# different endings, and "the operator pressed q" must not print "no answer".
ASK_FS_URL_RESULT=""
ask_fs_url() { # ask_fs_url <prompt> -> sets ASK_FS_URL_RESULT; 1 on URL-prompt EOF
  local prompt="$1" u tries=0 rc
  ASK_FS_URL_RESULT=""
  while [ "$tries" -lt 3 ]; do
    tries=$((tries + 1))
    u=$(ask_url "$prompt" "https://files.example.com" 1 "review omitting file transfer" "file.address.url"); rc=$?
    case "$rc" in
      0)  ;;
      11) quit_run ;;
      *)  return 1 ;;
    esac
    if [ -n "$u" ]; then ASK_FS_URL_RESULT="$u"; return 0; fi
    warn "No address was entered."
    confirm "  Leave file transfer OUT of this setup code?" "file.address.skip" && return 0
    note "Let's try that address again."
  done
  # BOUNDED, because --setup is not gated on an interactive terminal: a stdin
  # that keeps yielding empty lines (a pipe, `printf '\n\n\n' |`, a wedged paste)
  # would spin here forever, and a hang is a worse failure than the one this
  # confirmation exists to prevent. EOF already returns above — this is only for
  # a stdin that answers, emptily, without end. Falling through to the skip keeps
  # the old behaviour as the floor, and Step 6 still states that the code carries
  # no file transfer, so the run cannot end quietly wrong.
  warn "Still no address after three tries — leaving file transfer out of this code." >&2
  return 0
}

# Promote a private file lane to PUBLIC (Funnel) so it matches a public gateway.
# Publication event → a SECOND explicit confirm on top of the menu choice.
fs_promote_public() { # fs_promote_public <existing-https-port> <existing-verb> <host>
  local ehttps="$1" everb="$2" host="$3"
  if ! confirm "  Expose your files to the PUBLIC internet (only the password guards them)?" "file.exposure.make_public"; then
    FS_CRED=""; note "Leaving the file lane out — keeping your files off the public internet."
    fs_note_existing_mapping "$ehttps" "$everb"
    fs_lane_residue_note
    return 0
  fi
  case "$ehttps" in
    443|8443|10000)
      # Already on a Funnel-eligible port → switch in place (serve → funnel; most-recent
      # command wins, so funnel cleanly supersedes the serve handler — no `serve off`).
      if tailscale_expose "$ehttps" "$FS_LOCAL_PORT" true file; then
        FS_URL="https://$host:$ehttps"; FS_REACH="public"; ok "File lane is now public at $FS_URL."
      # A failed exposure leaves the server itself running and enabled at boot — the same
      # residue the declined branch below reports. The report is latched, so a later path
      # that also reports it prints once.
      else warn "Could not make the file lane public — leaving it out."; drop_file_lane; fs_lane_residue_note; fi
      ;;
    *)
      # Lane is on a non-Funnel port (e.g. 8444/9443) → need a free Funnel port.
      if ! pick_public_port funnel "$FS_LOCAL_PORT" file; then
        # No Funnel port free — NOTHING was changed, the lane is still private. Don't
        # silently drop a working lane: offer to keep it private instead of losing it.
        warn "Couldn't make the file lane public — all three Funnel ports (443/8443/10000) are already in use by other services on this machine."
        if confirm "  Keep the file lane PRIVATE instead (reachable on your Tailscale network)?" "file.exposure.keep_private"; then
          FS_URL="https://$host:$ehttps"; FS_REACH="private"
          warn "Keeping the file lane private at $FS_URL."
          warn "Heads-up: the gateway is PUBLIC but this file lane stays Tailscale-only, so attachments work only on your Tailscale-connected devices — an Apple Watch used away from your iPhone won't reach them. Chat still works everywhere."
        else
          FS_CRED=""; note "Leaving the file lane out."
          fs_note_existing_mapping "$ehttps" "$everb"
          fs_lane_residue_note
        fi
        return 0
      fi
      # Got a Funnel port → expose it, then drop the old private mapping (rollback-recorded).
      if tailscale_expose "$PICKED_PORT" "$FS_LOCAL_PORT" true file; then
        local newport="$PICKED_PORT"
        ts_unmap "$ehttps" "$everb"
        FS_URL="https://$host:$newport"; FS_REACH="public"; ok "File lane is now public at $FS_URL."
      else warn "Could not make the file lane public — leaving it out."; drop_file_lane; fs_lane_residue_note; fi
      ;;
  esac
}

# Demote a public file lane to PRIVATE (Serve) so it matches a private gateway.
# tailscale_expose handles the flip (drops the funnel flag first, re-applies as
# serve, then verifies the verb) — never ship a public lane labelled private.
fs_demote_private() { # fs_demote_private <existing-https-port> <existing-verb> <host>
  local ehttps="$1" everb="$2" host="$3"
  if tailscale_expose "$ehttps" "$FS_LOCAL_PORT" false file; then
    FS_URL="https://$host:$ehttps"; FS_REACH="private"; ok "File lane is now private at $FS_URL — only your Tailscale devices can reach it."
  else warn "Could not make the file lane private — leaving it out (won't ship a public lane as private)."; drop_file_lane; fs_lane_residue_note; fi
}

# The plain-words help behind the mismatch menus' `?`. Branches on the gateway's
# $SCOPE; deliberately NUMBER-FREE (the reuse-only menus number differently).
# ADDITIVE only — explains the situation, never changes the choices.
explain_fs_mismatch() {
  say ""
  say "  What's going on: chat and file transfer are two separate doors. Right now"
  if [ "$SCOPE" = "public" ]; then
    say "  the CHAT door is public (works from anywhere), but the FILE door only opens"
    say "  for devices on your Tailscale network. Left as-is, that shows up in the app"
    say "  as: chat works everywhere, attachments only on your Tailscale-connected"
    say "  devices — and a Watch away from its iPhone can't use them at all."
  else
    say "  the CHAT door only opens for devices on your Tailscale network, but the"
    say "  FILE door is on the public internet — your files are reachable more widely"
    say "  than your chat, guarded only by their password."
  fi
  say ""
  say "  Matching the two doors is the predictable setup: attachments then work"
  say "  exactly where chat works. Leaving the file lane out costs only attachments —"
  say "  chat is unaffected. Keeping the mismatch is the advanced choice: pick it only"
  say "  if the split described above is what you actually intend."
  say ""
}

# Resolve a scope mismatch: align / omit / include as-is. Sets FS_URL on inclusion,
# clears FS_CRED on omit. Under --reuse-only the align option is withheld (it mutates).
#
# All four menus go through prompt_into, which is the only place q can be acted on:
# require_choice runs inside $(…), so a quit_run it called itself would stop the
# subshell and let this function carry on choosing for the operator. The prompt text
# is bare "Choose 1-N" — require_choice renders the control list from the same
# parameters that decide the behaviour, and a caller-written copy of it can only drift.
resolve_fs_scope_mismatch() { # resolve_fs_scope_mismatch <existing-https-port> <existing-verb> <host>
  local ehttps="$1" everb="$2" host="$3" c
  if [ "$SCOPE" = "public" ]; then
    warn "Your file lane can be reached only by your own Tailscale-connected devices, but the gateway is public."
    note "As-is, attachments would work only on your Tailscale network — a Watch used away from the phone couldn't reach files."
    if $REUSE_ONLY; then
      say "    1) Leave the file lane out — chat still works everywhere; no attachments"
      say "    2) Include it as-is  (advanced) — attachments only on your Tailscale devices"
      note "(Making it public would change an exposure; --reuse-only forbids changes — re-run without it to do that.)"
      prompt_into c require_choice "Choose 1-2" '^[12]$' explain_fs_mismatch
      case "$c" in
        1) FS_CRED=""; note "Leaving the file lane out."
           fs_note_existing_mapping "$ehttps" "$everb"; fs_lane_residue_note ;;
        2) FS_URL="https://$host:$ehttps"; FS_REACH="private"; ok "Included the file lane at $FS_URL (reachable only on your Tailscale network)." ;;
      esac
      return 0
    fi
    say "    1) Make the file lane public too — attachments then work wherever chat works"
    say "       (puts the password-protected file server on the public internet)"
    say "    2) Leave the file lane out — chat still works everywhere; no attachments"
    say "    3) Include it as-is  (advanced) — attachments only on your Tailscale devices;"
    say "       the file server itself stays private"
    prompt_into c require_choice "Choose 1-3" '^[123]$' explain_fs_mismatch
    case "$c" in
      1) fs_promote_public "$ehttps" "$everb" "$host" ;;
      2) FS_CRED=""; note "Leaving the file lane out — its reach doesn't match the public gateway."
         fs_note_existing_mapping "$ehttps" "$everb"; fs_lane_residue_note ;;
      3) FS_URL="https://$host:$ehttps"; FS_REACH="private"; ok "Included the file lane at $FS_URL (reachable only on your Tailscale network)." ;;
    esac
  else
    warn "Your file lane is on the public internet, but the gateway is private (only your Tailscale devices) — that exposes your files more widely than the gateway itself."
    if $REUSE_ONLY; then
      say "    1) Leave the file lane out — chat unaffected; no attachments"
      say "    2) Keep it public anyway  (advanced) — the file server stays reachable"
      say "       from the whole internet, unlike the gateway"
      note "(Making it private would change an exposure; --reuse-only forbids changes — re-run without it to do that.)"
      prompt_into c require_choice "Choose 1-2" '^[12]$' explain_fs_mismatch
      case "$c" in
        1) FS_CRED=""; note "Leaving the file lane out."
           fs_note_existing_mapping "$ehttps" "$everb"; fs_lane_residue_note ;;
        2) FS_URL="https://$host:$ehttps"; FS_REACH="public"; warn "Including a public file lane at $FS_URL." ;;
      esac
      return 0
    fi
    say "    1) Make the file lane private too — match the gateway (recommended);"
    say "       attachments then work wherever chat works"
    say "    2) Leave the file lane out — chat unaffected; no attachments"
    say "    3) Keep it public anyway  (advanced) — the file server stays reachable"
    say "       from the whole internet, unlike the gateway"
    prompt_into c require_choice "Choose 1-3" '^[123]$' explain_fs_mismatch
    case "$c" in
      1) fs_demote_private "$ehttps" "$everb" "$host" ;;
      2) FS_CRED=""; note "Leaving the file lane out."
         fs_note_existing_mapping "$ehttps" "$everb"; fs_lane_residue_note ;;
      3) FS_URL="https://$host:$ehttps"; FS_REACH="public"; warn "Including a public file lane at $FS_URL." ;;
    esac
  fi
}

# --- OpenClaw agent-side readiness (tool policy + TOOLS.md guidance) ----------
# A green file-lane test proves only that Conduck can STORE bytes — never that
# the AGENT may read or return them. Three gateway-side traps break attachments
# silently even with every transport check green (all verified live, July 2026):
#   1. tools.deny containing group:fs (a common hardening move) — the agent
#      can't open a single uploaded file;
#   2. output files need `write` — without it there are no download chips;
#   3. MEDIA:-style reply directives are STRIPPED on the OpenAI-compatible
#      endpoint — the agent "sends" a file that never arrives.
# 1-2 are config → openclaw_tool_policy_step checks and offers the exact fix.
# 3 is agent behavior → install_conduck_tools_block teaches it (TOOLS.md),
# scoped to Conduck turns so messaging channels (where MEDIA: is correct) are
# untouched. Neither is detectable app-side (the app deliberately has no
# capability probe), which is why the wizard is where this lives.
#
# READING a PDF is a different problem, and deliberately not this step's
# business. The pdf tool is absent from the "coding" profile, and switching it on
# from here was measured against a live box: every call failed with "Unknown
# model: <slug>", because the tool needs its own model at agents.defaults.pdfModel
# and the common BYO shape (an OpenRouter-routed OpenAI model) does not resolve
# there. The correct answers came from a clawpdf binary the container carries
# whatever the tool policy says, plus the image tool that lives in the base
# profile — an image-only scanned PDF scored the same 8 of 8 facts with the tool
# on and with it off, and hallucinated nothing either way. So the write bought
# two failing tool calls per PDF request and a user-visible "tool failed" line on
# an otherwise correct reply. Turning the tool on stays the operator's own call;
# the README's file-lane troubleshooting lists the three things it needs.

# Read tools.{profile,allow,alsoAllow,deny} from openclaw.json (JSON5-tolerant)
# and print a machine-readable verdict:
#   status<TAB><ok|none|unknown|fix|manual|unreadable><TAB><reason>
#   change<TAB><key>: <before> → <after>          (fix only, one per key)
#   cmd<TAB><manual `openclaw config set …` line>  (fix only, one per key)
#   ops<TAB><config set --batch-json payload>      (fix only)
# Encodes only DOC-VERIFIED semantics (docs.openclaw.ai → gateway/config-tools,
# re-read August 2026): deny wins; entries in allow, alsoAllow and deny alike
# match CASE-INSENSITIVELY and support `*` wildcards ("Global tool allow/deny
# policy (deny wins). Case-insensitive, supports * wildcards.", with alsoAllow
# named there as allow's interchangeable form); group:fs =
# read/write/edit/apply_patch; allow and alsoAllow are mutually exclusive per
# scope. The fix is the MINIMUM relaxation: read/write on, edit/apply_patch/exec
# untouched — group:fs in deny is REPLACED by its mutating members, never just
# dropped.
#
# All three matching rules therefore apply on BOTH sides of the policy, never
# only where a bug happened to be fixed first. A plain-equality read of the allow
# side called allow ["*"] — a policy that permits every tool — a policy omitting
# read and write, and offered to "fix" it; a case-sensitive read of the deny side
# would call deny ["Write"] harmless, add permissions around a denial still in
# force, restart the gateway for nothing and then grade its own output green.
# Comparisons run over lowercased copies; what gets WRITTEN keeps the operator's
# own spelling.
#
# PROFILE NAMES are lowercased for matching too, which the docs neither require
# nor forbid: they list minimal/coding/messaging/full in lowercase and say
# nothing about case. Normalising is the direction whose worst case is harmless —
# reading "Minimal" as minimal can at most propose two tools the agent may
# already hold, while the reverse silently grades an unreadable name.
#
# The verdict concerns exactly two tools, because two are what the lane runs on:
# read opens what Conduck uploads, write produces the files that come back as
# download chips. Nothing else in the policy is proposed, added, or claimed —
# see the note above for why the pdf tool is not this step's business.
openclaw_tools_analysis() { # openclaw_tools_analysis <config-path>
  python3 - "$1" <<'PY'
import json, sys, fnmatch

def strip_json5(s):
    # Same comment/trailing-comma stripper as json_query (keep in lockstep).
    out = []; i = 0; n = len(s); q = ''
    while i < n:
        c = s[i]
        if q:
            out.append(c)
            if c == '\\' and i + 1 < n:
                out.append(s[i+1]); i += 2; continue
            if c == q: q = ''
            i += 1; continue
        if c == '"' or c == "'":
            q = c; out.append(c); i += 1; continue
        if c == '/' and i + 1 < n and s[i+1] == '/':
            i += 2
            while i < n and s[i] != '\n': i += 1
            continue
        if c == '/' and i + 1 < n and s[i+1] == '*':
            i += 2
            while i + 1 < n and not (s[i] == '*' and s[i+1] == '/'): i += 1
            i += 2; continue
        out.append(c); i += 1
    t = ''.join(out)
    res = []; i = 0; n = len(t); q = ''
    while i < n:
        c = t[i]
        if q:
            res.append(c)
            if c == '\\' and i + 1 < n:
                res.append(t[i+1]); i += 2; continue
            if c == q: q = ''
            i += 1; continue
        if c == '"' or c == "'":
            q = c; res.append(c); i += 1; continue
        if c == ',':
            j = i + 1
            while j < n and t[j] in ' \t\r\n': j += 1
            if j < n and t[j] in '}]':
                i += 1; continue
        res.append(c); i += 1
    return ''.join(res)

def emit(tag, *fields):
    print(tag + "\t" + "\t".join(fields))

try:
    cfg = json.loads(strip_json5(open(sys.argv[1]).read()))
    if not isinstance(cfg, dict):
        raise ValueError("not an object")
except Exception:
    emit("status", "unreadable", "the config did not parse (JSON5 read attempted)")
    sys.exit(0)

tools = cfg.get("tools")
if tools is None:
    emit("status", "none",
         "no tools block in openclaw.json — the default policy leaves the agent's file tools on")
    sys.exit(0)
if not isinstance(tools, dict):
    # Present, but not an object. Read as absent it would print the sentence above,
    # which is an affirmative claim that the default policy is in force — made
    # about a block this read could not interpret at all.
    emit("status", "manual",
         "tools in openclaw.json is not an object, so nothing inside it could be read and "
         "this check cannot say what the policy grants or blocks; fix the block by hand first")
    sys.exit(0)

# Keys whose list held something other than a string. Every rewrite below writes
# a WHOLE list back, so an entry this read dropped would be dropped from the
# operator's file for good — and the before/after on screen, which is the only
# rollback they are offered, would not match what the file actually said.
lossy = []

def arr(key):
    v = tools.get(key)
    if isinstance(v, list):
        strs = [x for x in v if isinstance(x, str)]
        if len(strs) != len(v):
            lossy.append("tools." + key)
        return strs
    return None

profile_raw = tools.get("profile") if isinstance(tools.get("profile"), str) else None
allow, also, deny = arr("allow"), arr("alsoAllow"), arr("deny")
# The whole of what this step concerns itself with: the two tools the file lane
# cannot work without. Every other entry in the policy is the operator's own
# decision and is neither read for a verdict nor written to.
targets = ("read", "write")
# OpenClaw's own tool-group table: group:fs is exactly these four tool ids.
FS_GROUP = ("read", "write", "edit", "apply_patch")
# Every profile OpenClaw documents. A name outside this set grants tools this
# read has no way to enumerate — see the `unknown` verdict below.
PROFILES = ("minimal", "coding", "messaging", "full")

# OpenClaw matches these entries case-insensitively, so every comparison below
# is made against lowercased copies — never against the raw list, which stays
# untouched so a rewrite writes the operator's own spelling back.
def lower_all(xs):
    return [x.lower() for x in (xs or [])]

deny_low = lower_all(deny)
# The profile is matched lowercased for the same reason (see the header note on
# why normalising is the safe direction); the raw spelling is kept for display.
profile = profile_raw.lower() if profile_raw is not None else None

def is_pattern(entry):
    return any(ch in entry for ch in "*?[")

def display(s):
    # A profile name is operator text from their own config on its way to a
    # terminal. Drop anything unprintable — a stray ANSI escape would repaint
    # this transcript — and bound it; a real profile name is one short word.
    return "".join(c if c.isprintable() else " " for c in s)[:64]

def granted(entries, tool):
    # Does an allow-side list (tools.allow or tools.alsoAllow) grant <tool>?
    # All three of OpenClaw's documented matching rules, the same three the deny
    # side reads by: case-insensitive, `*` wildcards, and group:fs standing for
    # its members. Plain equality here is what reported allow ["*"] — a policy
    # that permits every tool — as one omitting read and write.
    for e in (entries or []):
        low = e.lower()
        if low == tool:
            return True
        if low == "group:fs" and tool in FS_GROUP:
            return True
        if is_pattern(low) and (
                fnmatch.fnmatchcase(tool, low)
                or (tool in FS_GROUP and fnmatch.fnmatchcase("group:fs", low))):
            return True
    return False

# A key that is PRESENT but written as the wrong TYPE. Every accessor above reads
# one as ABSENT, and absent is indistinguishable from healthy: tools.deny written
# as the bare string "group:fs" instead of ["group:fs"] vanished from this read
# entirely, and the operator who had just switched their agent's file tools off was
# told read/write allowed. Same shape one level up for a profile that is not a
# string. This read cannot say what OpenClaw makes of such a key either — it may
# reject the config, it may ignore the key — so it grades nothing and rewrites
# nothing, the same posture as the lossy list below. A JSON null is NOT this case:
# that is a legitimate spelling of "unset" and stays absent.
mistyped = []
for key, want, kind in (("allow", "a list", list), ("alsoAllow", "a list", list),
                        ("deny", "a list", list), ("profile", "a name", str)):
    value = tools.get(key)
    if value is None or isinstance(value, kind):
        continue
    mistyped.append("tools.%s (expects %s)" % (key, want))
if mistyped:
    emit("status", "manual",
         "%s is written as the wrong type, so this read cannot tell what it grants or blocks — "
         "and a key it cannot read looks exactly like one that isn't there; correct the type by "
         "hand first" % " and ".join(mistyped))
    sys.exit(0)

# An invalid config (both allow + alsoAllow) must never be auto-edited into a
# different invalid config — surface it instead.
if allow is not None and also is not None:
    emit("status", "manual",
         "tools.allow and tools.alsoAllow are BOTH set — OpenClaw's config validation "
         "rejects that combination; reconcile the two by hand first")
    sys.exit(0)

# A list this read could not reproduce must never be rewritten from it.
if lossy:
    emit("status", "manual",
         "%s holds entries that are not tool names, which this read cannot reproduce — "
         "rewriting the list would drop them; reconcile them by hand first"
         % " and ".join(lossy))
    sys.exit(0)

# An EMPTY allowlist is not an allowlist two entries short. Adding read/write to
# it produces an authoritative allowlist where the base profile had been in
# force, revoking every tool that profile granted — the one edit this step can
# make that its own "everything else keeps its current policy" promise would not
# cover. Whether OpenClaw reads [] as "allow nothing" or ignores it entirely,
# the operator has to say which they meant.
if allow is not None and not allow:
    emit("status", "manual",
         "tools.allow is an empty list — adding to it would turn it into an allowlist "
         "that blocks every tool it omits, so it is not a change this step can make for "
         "you; name the tools you want in it, or remove the key, by hand")
    sys.exit(0)

# A wildcard deny (e.g. "wri*", "*") that reaches read or write is a deliberate,
# broad operator choice — flag it for the human, never auto-rewrite it. Matching
# is case-insensitive both ways: fnmatchcase over an already-lowercase name and a
# lowercased pattern, so "WRI*" is caught exactly as "wri*" is.
wild = [e for e in (deny or [])
        if is_pattern(e)
        and (any(fnmatch.fnmatchcase(t, e.lower()) for t in targets)
             or fnmatch.fnmatchcase("group:fs", e.lower()))]
if wild:
    emit("status", "manual",
         "tools.deny has wildcard entries (%s) matching the agent's file tools — too "
         "broad for an automatic fix; edit tools.deny by hand so read/write are not matched"
         % ", ".join(wild))
    sys.exit(0)

changes = {}   # key -> (before-or-None, after)
added = {}     # key -> [tools THIS run adds], kept as the branch produced them.
               # Re-deriving them from the before/after pair would mean redoing
               # the case comparison that made them, in a second place.

if any(e in ("group:fs",) + targets for e in deny_low):
    new_deny = []
    for e in deny:
        low = e.lower()
        if low == "group:fs":
            # Replace with its MUTATING members: read/write freed, the rest of
            # the group's denial preserved. A member the operator already denied
            # under any spelling is left as they wrote it, not duplicated.
            for m in ("edit", "apply_patch"):
                if m not in deny_low and m not in lower_all(new_deny):
                    new_deny.append(m)
        elif low in targets:
            continue
        else:
            new_deny.append(e)
    changes["tools.deny"] = (deny, new_deny)

profile_unreadable = False

if allow is not None:
    # A non-empty allowlist blocks everything omitted, and it is authoritative:
    # the base profile is applied before it, so nothing the profile grants
    # survives an allowlist that omits it. The profile is therefore not consulted
    # on this branch. (alsoAllow is invalid alongside allow, so additions go HERE.)
    missing = [t for t in targets if not granted(allow, t)]
    if missing:
        changes["tools.allow"] = (allow, allow + missing)
        added["tools.allow"] = missing
else:
    # No allowlist: the base profile decides what the agent starts with and
    # alsoAllow adds on top of it — so an alsoAllow that already covers read and
    # write settles the question whatever the profile grants, group:fs included.
    base = also or []
    if not all(granted(base, t) for t in targets):
        if profile is not None and profile not in PROFILES:
            # Nothing truthful can be said about a profile whose name is not one
            # of the four. Reported below, and only when nothing else in this
            # policy needs saying — a deny that blocks the lane still wins.
            profile_unreadable = True
        else:
            # Only a profile that may ship WITHOUT the fs tools needs anything
            # added. coding, full, and an unset profile all carry read and write.
            ensure = list(targets) if profile in ("minimal", "messaging") else []
            add = [t for t in ensure if not granted(base, t)]
            if add:
                changes["tools.alsoAllow"] = (also, base + add)
                added["tools.alsoAllow"] = add

if not changes:
    if profile_unreadable:
        # Neither green nor an alarm, because neither is true. Grading this ok
        # would certify tools nothing here looked at; grading it fix would
        # propose a repair for a policy that may be perfectly fine, and a
        # declined repair costs the operator the whole file lane. Saying what
        # was actually seen costs nothing and leaves the lane alone.
        emit("status", "unknown",
             'tools.profile is "%s", which is not one of the profiles OpenClaw '
             "documents (minimal, coding, messaging, full), so this read can't tell "
             "which file tools it grants" % display(profile_raw))
        sys.exit(0)
    detail = "profile: %s" % profile_raw if profile_raw else "no profile set"
    # Only what this read established. Whether the agent can make sense of any
    # given FORMAT once it holds the bytes turns on tools, a model, and a
    # provider that none of this looked at, so the verdict stops at the two
    # tools the lane itself runs on.
    emit("status", "ok", "read/write allowed, %s" % detail)
    sys.exit(0)

bits = []
if "tools.deny" in changes:
    bits.append("tools.deny blocks the agent's read/write file tools")
if "tools.allow" in changes:
    bits.append("tools.allow omits " + ", ".join(added["tools.allow"]))
if "tools.alsoAllow" in changes:
    bits.append("the active profile lacks " + ", ".join(added["tools.alsoAllow"]))
emit("status", "fix", "; ".join(bits))

ops = []
for key, (before, after) in changes.items():
    emit("change", "%s: %s → %s" % (
        key, json.dumps(before) if before is not None else "(absent)", json.dumps(after)))
    emit("cmd", "openclaw config set %s '%s' --strict-json" % (key, json.dumps(after)))
    ops.append({"path": key, "value": after})
emit("ops", json.dumps(ops))
PY
}

# A gateway needs a moment after a restart before it answers again: on a stock
# OpenClaw Docker install `docker compose restart` returns in about a second and
# /healthz first answers about five seconds later. Grading it inside that window
# fails a gateway that is merely booting, and the honest remedy is to wait — so
# the waiting lives beside the restart that caused it, not in the grading.
GW_RESTART_WAIT_SECONDS=60      # wall-clock budget for one restart's boot
GW_RESTART_WAIT_MAX_PROBES=90   # hard backstop: `date` is wall time, not monotonic, so a
                                # clock stepped backwards mid-wait must not extend the loop

# Facts about a restart THIS run asked for. Recorded because a user whose gateway
# was still coming back reads "some checks failed" as "I broke it" and undoes a
# change that was correct.
#   GW_RESTART_COMPLETED_EPOCH — empty until a restart this run asked for has
#     completed; then the epoch second at which it completed. A declined restart,
#     a restart command that exited non-zero, and a dry run all leave it empty.
#   GW_RESTART_LOCAL_WAIT_TIMED_OUT — the wait below spent its whole budget and
#     the gateway never answered. Deliberately a fact, not a verdict: it says the
#     wait expired, never that a later failure was caused by the restart.
#   GW_RESTART_WHAT — what the operator just approved, as a noun phrase, so the
#     two messages below name THEIR OWN change. Three callers restart a gateway
#     (the chat-endpoint flag, OpenClaw's tool policy, a Hermes config change);
#     naming the wrong one is worse than naming none, because it reassures the
#     operator about a change they did not make.
#   GW_RESTART_WHAT_HTTP_SAFE — may we honestly say the change itself cannot
#     break the gateway's HTTP? True for a tool policy and for Hermes's
#     agent-side config, both of which sit nowhere near the HTTP layer. FALSE for
#     the chat-endpoint flag, which IS that layer — enabling a route should only
#     ever add one, but this is not the place to promise it.
GW_RESTART_COMPLETED_EPOCH=""
GW_RESTART_LOCAL_WAIT_TIMED_OUT=false
GW_RESTART_WHAT="configuration change"
GW_RESTART_WHAT_HTTP_SAFE=false

# Wait for a gateway this run restarted to answer its local health endpoint
# again. Bounded twice over (deadline + probe cap), and it gates NOTHING: a
# gateway that is genuinely broken still reaches Step 5 and still fails there.
# All this removes is the grading of a gateway that had not finished booting.
#
# The probe is verification's own local_health_ok on purpose: the wait and the
# check that follows it must accept exactly the same answers. A stricter wait
# would sit out its whole budget on a gateway the check would have passed; a
# laxer one hands off early, which is the bug this exists to fix.
#
# Two answers a second apart are required. One is not proof — a container that
# starts, answers once and dies would otherwise be reported ready, and so would
# an old process still listening on its way down.
gw_wait_local_health_after_restart() { # -> 0 answering again · 1 budget spent
  if [ -z "${GW_LOCAL_PORT:-}" ] || [ -z "${GW_HEALTH_PATH:-}" ]; then
    # Nothing local to watch (no health route, or an address that isn't this
    # machine's), so there is no honest moment to wait for. Verification is then
    # the first thing that touches the gateway, exactly as it was before.
    note "There's no local health endpoint here, so I can't tell when the gateway is back."
    note "If the checks below fail, give it a minute and re-run me."
    return 0
  fi
  local url="http://127.0.0.1:$GW_LOCAL_PORT$GW_HEALTH_PATH"
  local now deadline="" probes=0
  now=$(date +%s 2>/dev/null) || now=""
  case "$now" in ''|*[!0-9]*) ;; *) deadline=$((now + GW_RESTART_WAIT_SECONDS)) ;; esac

  say "  Waiting for the gateway to answer $GW_HEALTH_PATH again after the restart"
  say "  (up to ${GW_RESTART_WAIT_SECONDS}s — a restarted gateway takes a few seconds to come back)…"
  while [ "$probes" -lt "$GW_RESTART_WAIT_MAX_PROBES" ]; do
    probes=$((probes+1))
    if local_health_ok "$url"; then
      sleep 1
      probes=$((probes+1))
      if local_health_ok "$url"; then
        ok "The gateway is answering again."
        return 0
      fi
      # A single answer that didn't hold: keep waiting rather than grade it here.
    fi
    if [ -n "$deadline" ]; then
      now=$(date +%s 2>/dev/null) || now=""
      case "$now" in ''|*[!0-9]*) break ;; esac
      [ "$now" -ge "$deadline" ] && break
    fi
    sleep 1
  done

  GW_RESTART_LOCAL_WAIT_TIMED_OUT=true
  warn "The gateway still hasn't answered $GW_HEALTH_PATH about ${GW_RESTART_WAIT_SECONDS}s after the restart finished."
  note "The $GW_RESTART_WHAT is saved either way — this wait didn't undo it."
  note "The checks below still run and may fail while the gateway is coming back. Give it a"
  note "minute and re-run me; if the same check fails again, treat it as a real problem."
  return 1
}

# The one restart fact worth repeating at the very end of a failed run: by then
# the readiness warning above has scrolled away, and the transcript the operator
# is actually looking at when they decide whether to undo their change is the
# failure epilogue. Silent unless the dedicated wait genuinely expired — a
# models/auth/TLS failure after a gateway that came back fine is not timing, and
# a blanket "maybe it was the restart" would excuse a real breakage forever.
gw_restart_timing_note() {
  [ -n "$GW_RESTART_COMPLETED_EPOCH" ] || return 0
  $GW_RESTART_LOCAL_WAIT_TIMED_OUT || return 0
  say ""
  warn "One of those may be timing: the gateway hadn't answered $GW_HEALTH_PATH again within"
  warn "${GW_RESTART_WAIT_SECONDS}s of the restart this run asked for, so it may still have been coming back."
  if $GW_RESTART_WHAT_HTTP_SAFE; then
    note "The $GW_RESTART_WHAT is saved, and it cannot break a gateway's HTTP — the restart it"
    note "needed is what interrupted this check."
  else
    note "The $GW_RESTART_WHAT is saved — the restart it needed is what interrupted this check."
  fi
  note "Give it a minute and re-run me; if the same check fails again, the"
  note "restart is no longer a likely explanation."
  return 0
}

# Record that a restart this run asked for has completed, then wait for the
# gateway. Called on BOTH restart routes (the one we run, and the one the
# operator confirms by hand) — the boot window is identical either way, and
# pressing Enter is the only signal available on the second route.
# Always returns 0: a spent wait is evidence, never a reason to abandon the lane.
# The tool-policy step is the only caller, which is why the two messages above
# name the tool-policy change by name — a second caller has to generalise them
# rather than tell a Hermes user their tool policy is safe.
gw_note_restart_and_wait() { # gw_note_restart_and_wait [<what> [<http-safe>]]
  GW_RESTART_WHAT="${1:-configuration change}"
  GW_RESTART_WHAT_HTTP_SAFE=false
  [ "${2:-false}" = "true" ] && GW_RESTART_WHAT_HTTP_SAFE=true
  GW_RESTART_COMPLETED_EPOCH=""
  GW_RESTART_LOCAL_WAIT_TIMED_OUT=false   # reset per attempt: an earlier timeout
                                          # must not be read as this restart's
  $DRY_RUN && return 0                    # nothing was restarted, so nothing to wait for
  GW_RESTART_COMPLETED_EPOCH=$(date +%s 2>/dev/null) || GW_RESTART_COMPLETED_EPOCH=""
  gw_wait_local_health_after_restart || true
  return 0
}

# The one sentence a config read is allowed to end on, and the two things that
# change it. Under --dry-run the live file test in Step 5 never runs at all — the
# mode exits at print_plan before verify_all is ever reached (README documents it
# as the mode that stops and sends nothing) — so that test must not be promised
# there. And the sentence turns on what the read ESTABLISHED, because a verdict
# and its closing line have to agree: a GREEN read is confirmed by the live test,
# while an UNKNOWN read is only settled by it. "will confirm file access" reads as
# a pass already granted, which is the exact claim the unknown verdict has just
# finished saying it cannot make — two lines reporting that nothing was graded,
# closing on a sentence that sounds like something was.
openclaw_policy_live_test_note() { # openclaw_policy_live_test_note [settles]
  if $DRY_RUN; then
    note "(dry-run: this pass stops before the live file test, so nothing here is checked against a running agent)"
  elif [ "${1:-}" = "settles" ]; then
    note "The live file test later is what settles it — if the agent can't use this lane, that test is where it shows."
  else
    note "The live file test later will confirm file access."
  fi
}

# Check OpenClaw's tool policy for the file lane; offer the exact fix through
# the same config-set + restart machinery as the Step-2 endpoint enable.
# Returns 0 = lane proceeds, 1 = user chose to drop the lane. Declining the FIX
# never silently drops the lane (consent-ladder idiom: warn loudly, explicit
# confirm to continue — byte transport still works, only agent-side use is
# broken until the policy allows it).
openclaw_tool_policy_step() {
  local cfg="$HOME/.openclaw/openclaw.json"
  [ -f "$cfg" ] || return 0

  local tab status="" reason="" ops="" line body
  tab=$(printf '\t')
  local changes=() cmds=()
  while IFS= read -r line; do
    case "$line" in
      "status$tab"*) body="${line#status$tab}"; status="${body%%$tab*}"; reason="${body#*$tab}" ;;
      "change$tab"*) changes+=("${line#change$tab}") ;;
      "cmd$tab"*)    cmds+=("${line#cmd$tab}") ;;
      "ops$tab"*)    ops="${line#ops$tab}" ;;
    esac
  done < <(openclaw_tools_analysis "$cfg")

  say ""
  say "  ${BOLD}Agent tool policy${RESET} — can the agent actually USE the files this lane carries?"
  note "A green file-lane test proves Conduck can store bytes; OpenClaw's tool policy"
  note "decides whether the AGENT may read uploads and write output files back."

  case "$status" in
    ok)
      # A verdict read off the config file, and said as one: the live sentinel in
      # Step 5 is what actually proves the agent can use this lane, and it runs
      # in this same session. Pointing at it keeps a green config read from being
      # taken for the proof that follows it.
      ok "OpenClaw's file-tool settings look ready ($reason)."
      openclaw_policy_live_test_note
      return 0 ;;
    none)
      ok "$reason."
      return 0 ;;
    unknown)
      # A profile name this read cannot interpret. Described, never graded: the
      # lane is untouched, nothing is proposed and nothing is asked, because the
      # only two alternatives are a green claim about tools nobody looked at and
      # a false alarm whose declined fix would cost the operator the whole lane.
      note "$reason."
      note "Nothing is changed here, and the file lane is kept either way."
      openclaw_policy_live_test_note settles
      return 0 ;;
    unreadable|"")
      warn "Could not read the tool policy ($reason) — continuing, but if attachments later"
      warn "fail agent-side, check tools.deny / tools.allow in openclaw.json by hand."
      return 0 ;;
  esac

  # status = fix | manual — the policy would break agent file transfer.
  warn "This tool policy would break agent file transfer:"
  say  "    $reason"
  # Two separate facts, never conflated: the policy landed in openclaw.json, and
  # the running gateway picked it up. Re-reading the config proves only the first.
  local policy_saved=false restart_done=false
  if [ "$status" = "fix" ]; then
    say ""
    say "  The fix — ONLY these keys change; edit, apply_patch, exec and everything"
    say "  else keep their current policy:"
    local c; for c in "${changes[@]}"; do say "    ${BOLD}$c${RESET}"; done
    say "  Plain words: this lets the agent READ the files Conduck uploads and WRITE"
    say "  output files back (that is what download chips are). 'write' also means it"
    say "  can overwrite files inside its own workspace — inherent to the capability."
    if $REUSE_ONLY; then
      warn "(reuse-only: not offering the change — re-run without --reuse-only to apply it)"
    else
      local compose_dir="${OPENCLAW_DIR:-$HOME/openclaw}"
      if [ -f "$compose_dir/docker-compose.yml" ] || [ -f "$compose_dir/compose.yaml" ]; then
        if run_step "file.openclaw.allow_tools" "allow the agent's file tools in OpenClaw's tool policy" \
          docker compose --project-directory "$compose_dir" run --rm --no-deps --entrypoint node openclaw-gateway \
            dist/index.js config set --batch-json "$ops"; then
          policy_saved=true
          if run_step "file.openclaw.restart_tools" "restart the gateway so the policy applies" \
            docker compose --project-directory "$compose_dir" restart openclaw-gateway; then
            restart_done=true
            gw_note_restart_and_wait "tool-policy change" true
          fi
        fi
      else
        local joined=""; local m
        for m in "${cmds[@]}"; do joined="${joined:+$joined && }$m"; done
        # One step covers both halves here, so its confirmation is the only signal
        # available for either — the same boot window follows an operator's own
        # restart, so the same wait follows it.
        if print_and_wait "file.openclaw.manual_tools" \
          "Not the standard Docker setup — apply the policy change with your install's CLI, then restart the gateway." \
          "$joined"; then
          policy_saved=true
          restart_done=true
          gw_note_restart_and_wait "tool-policy change" true
        fi
      fi
    fi
    if $policy_saved && ! $DRY_RUN; then
      # Re-read rather than trust: config set can no-op silently (wrong CLI,
      # wrong file) and verification below never exercises agent tools.
      # awk -F'\t', not sed \t — BSD sed treats \t as a literal 't'.
      local recheck; recheck=$(openclaw_tools_analysis "$cfg" | awk -F '\t' '$1=="status"{print $2; exit}')
      # `unknown` counts as repaired alongside `ok`: the change this run made is
      # in the file, and an unrecognised profile name is not something re-reading
      # the same file can settle. Only `fix` and `manual` mean the block is still
      # there, so only they may say the change didn't take.
      if [ "$recheck" = "ok" ] || [ "$recheck" = "unknown" ]; then
        if [ "$recheck" = "ok" ]; then
          ok "Tool policy re-checked — openclaw.json is file-transfer-ready."
        else
          ok "Tool policy re-checked — the change is saved in openclaw.json."
        fi
        # The re-read proves the FILE, so a policy the running gateway never
        # reloaded may not say what the config now says.
        if ! $restart_done; then
          warn "The gateway was not restarted, so it is still running with its old policy."
          note "Restart it when you can; until then the agent still can't open the files Conduck uploads."
        fi
        if [ "$recheck" = "unknown" ]; then
          openclaw_policy_live_test_note settles
        fi
        return 0
      fi
      warn "The policy still doesn't look file-transfer-ready after the change — re-check"
      warn "tools.deny / tools.allow in openclaw.json by hand."
    elif $policy_saved; then
      return 0   # dry-run: planned, nothing to re-check
    fi
  fi

  # Declined / manual / unproven: loud consequence + explicit choice, and the
  # informed "keep it" wins over silently stripping a capability the user chose.
  warn "Without read+write, attachments will upload fine but the agent cannot OPEN"
  warn "them, and it cannot produce files for you to download."
  if $DRY_RUN || $REUSE_ONLY; then
    note "(keeping the file lane in this read-only pass; a real run asks)"
    return 0
  fi
  if confirm "  Keep the file lane anyway (fix the policy later, then re-run me)?" "file.openclaw.keep_unready"; then
    return 0
  fi
  return 1
}

# Install/refresh a marker-delimited Conduck guidance block in the agent
# workspace's TOOLS.md (OpenClaw reads workspace bootstrap files into every NEW
# session's context). Idempotent: one block, replaced in place between its
# markers on re-runs; the rest of the file is never touched. Scoped to Conduck
# turns via the app's "[Conduck file transfer]" wire tag so the same agent's
# messaging channels (where MEDIA: is the correct way to send a file) keep
# their behavior. The directory this writes into belongs to the AGENT's uid
# while the write happens as root, so the file is opened O_NOFOLLOW and every
# mode decision is made through that one descriptor — never through the path.
install_conduck_tools_block() { # install_conduck_tools_block <workspace-host-path>
  local ws="$1"
  if [ -z "$ws" ]; then
    note "Workspace folder unknown (pre-existing file server) — skipping the agent-guidance"
    note "block; the same guidance lives in the README's file-lane troubleshooting."
    return 0
  fi
  local target="$ws/TOOLS.md"

  # The path the AGENT sees: the standard Docker install mounts the host
  # workspace at /home/node/.openclaw/workspace — the media/pdf absolute-path
  # hint must name the CONTAINER path there, not the host one. A non-default
  # workspace under Docker has an unknown mapping → generic wording only.
  local agent_ws="$ws"
  local compose_dir="${OPENCLAW_DIR:-$HOME/openclaw}"
  if [ -f "$compose_dir/docker-compose.yml" ] || [ -f "$compose_dir/compose.yaml" ]; then
    if [ "$ws" = "$HOME/.openclaw/workspace" ]; then
      agent_ws="/home/node/.openclaw/workspace"
    else
      agent_ws=""
    fi
  fi

  if $DRY_RUN; then
    plan_add "INSTALL/refresh the Conduck agent-guidance block in $target (marker-delimited)"
    note "(dry-run: would install the Conduck agent-guidance block in TOOLS.md)"
    return 0
  fi
  if $REUSE_ONLY; then
    note "(reuse-only: not touching $target — re-run without --reuse-only to install the agent-guidance block)"
    return 0
  fi

  say ""
  say "  OpenClaw loads ${BOLD}TOOLS.md${RESET} from the agent workspace into every NEW session."
  say "  I can install a short, marker-delimited Conduck block there that teaches the agent:"
  say "    - attached files: open them directly with file tools (never web-search for them)"
  say "    - media/pdf tools: retry with the file's ABSOLUTE workspace path if a bare name fails"
  say "    - returning files: create the folder that turn's message names and write the file"
  say "      into it, finishing before the reply — never a MEDIA: directive (Conduck turns"
  say "      only; your other channels are unaffected)"
  if [ -f "$target" ]; then
    say "  Your TOOLS.md exists — the block is appended (or refreshed in place between its"
    say "  markers); everything else in the file stays byte-identical."
  fi
  if ! confirm "  Install/refresh the block?" "file.openclaw.guidance"; then
    note "Skipped — the README's file-lane troubleshooting carries the same guidance for manual setup."
    return 0
  fi

  if python3 - "$target" "$agent_ws" <<'PY'
import errno, os, stat, sys

target, agent_ws = sys.argv[1], sys.argv[2]
BEGIN = "<!-- conduck-connect:begin -->"
END = "<!-- conduck-connect:end -->"
# The agent reads this file as ITS OWN uid — 1000 in the standard OpenClaw
# container, never the uid running this wizard. TOOLS.md carries no secret and
# is useless unless a uid that is not ours can read it, so the mode is part of
# the contract, not an afterthought.
TOOLS_MD_MODE = 0o644
AGENT_READ_BIT = 0o004

if agent_ws:
    path_hint = ('If a media/PDF tool rejects that path ("not under an allowed directory"), '
                 "retry with the absolute path: `%s/<saved-name>`." % agent_ws)
else:
    path_hint = ('If a media/PDF tool rejects that path ("not under an allowed directory"), '
                 "retry with the file's ABSOLUTE path under your working directory "
                 "(your session context names the workspace root).")

block = BEGIN + "\n" + (
    "## Conduck chat attachments (managed by conduck-connect)\n"
    "\n"
    'These rules apply ONLY to conversations whose user message contains '
    '"[Conduck file transfer]" (turns from the Conduck app). Leave every other '
    "channel's behavior unchanged.\n"
    "\n"
    "- Files the user attaches are ALREADY in your working directory, saved as "
    "`<8-hex>__<original-name>` (usually inside a per-conversation subfolder; the "
    "message names each file's exact saved path). Open them with your file tools — "
    "never search the web for an attached file.\n"
    "- Your `read` tool accepts the saved path as shown. " + path_hint + "\n"
    "- To RETURN a file: create the folder that turn's message names for its output "
    "— all of it, including any parent, because none of it exists yet — write the "
    "file inside it, and finish writing before you reply. Conduck reads that one "
    "folder as soon as the reply arrives, so a file written anywhere else, or "
    "written afterwards, does not reach the user.\n"
    "- Never use `MEDIA:` or other attachment directives in these conversations — "
    "this endpoint strips them and the file will not reach the user. Write the file "
    "into the folder that message names instead.\n"
) + END

# The workspace directory belongs to the AGENT's uid and this wizard writes as
# root, so every path-based inspection here is a check-then-use window: an
# islink() that passes, then an open() that lands on a link planted in the gap,
# with root writing attacker-chosen content to an attacker-chosen path. The
# window is not narrowed, it is removed — O_NOFOLLOW makes the refusal and the
# open the SAME syscall, so there is no moment between them to win. It is
# preferred over write-a-temp-then-os.replace because os.replace still needs
# the destination proven symlink-free at the instant it runs, which is the very
# check-then-use shape being eliminated.
#
# O_EXCL first tells "we created it" from "it was already there" without a
# second lookup to race either. O_NOFOLLOW guards the final component; the
# workspace directory above it is the root fs_resolve_shared_folder already
# resolved and pinned.
created = True
try:
    fd = os.open(target, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                 TOOLS_MD_MODE)
except FileExistsError:
    created = False
    try:
        fd = os.open(target, os.O_RDWR | os.O_NOFOLLOW)
    except OSError as exc:
        # ELOOP is the POSIX answer for O_NOFOLLOW on a symlink; some BSDs
        # answer EMLINK. Either way the name is a link and we do not follow it.
        if exc.errno in (errno.ELOOP, errno.EMLINK):
            print("TOOLS.md is a symlink — refusing to edit through it", file=sys.stderr)
        else:
            print("could not open TOOLS.md: %s" % exc.strerror, file=sys.stderr)
        sys.exit(1)
except OSError as exc:
    print("could not create TOOLS.md: %s" % exc.strerror, file=sys.stderr)
    sys.exit(1)

with os.fdopen(fd, "r+", encoding="utf-8") as fh:
    st = os.fstat(fh.fileno())
    if not stat.S_ISREG(st.st_mode):
        print("TOOLS.md is not a regular file — refusing to write through it",
              file=sys.stderr)
        sys.exit(1)
    if created:
        # A file WE created must not inherit whatever mask happens to be in
        # force. fchmod, not chmod: the descriptor is the one handle already
        # proven not to be a symlink, and a path-based chmod would reopen the
        # window just closed. Verified rather than assumed — a chmod that
        # silently does nothing recreates the exact failure this path exists to
        # close.
        os.fchmod(fh.fileno(), TOOLS_MD_MODE)
        if not (stat.S_IMODE(os.fstat(fh.fileno()).st_mode) & AGENT_READ_BIT):
            print("could not make TOOLS.md readable by the agent: %s" % target,
                  file=sys.stderr)
            sys.exit(1)
        s2 = block + "\n"
    else:
        # A TOOLS.md only its owner can read installs perfectly and stays
        # invisible to the agent: the wizard reports green for a step that did
        # not take effect. Refuse instead, and name the fix — broadening a file
        # the operator already owns is not ours to decide. Nothing has been
        # written at this point, so the refusal leaves the file byte-identical.
        if not (stat.S_IMODE(st.st_mode) & AGENT_READ_BIT):
            print("TOOLS.md exists but only its owner can read it, so the agent would "
                  "never see the block. Fix the mode first:  chmod %o %s"
                  % (TOOLS_MD_MODE, target), file=sys.stderr)
            sys.exit(1)
        s = fh.read()
        nb, ne = s.count(BEGIN), s.count(END)
        if nb == 0 and ne == 0:
            s2 = s.rstrip("\n") + ("\n\n" if s.strip() else "") + block + "\n"
        elif nb == 1 and ne == 1 and s.index(BEGIN) < s.index(END):
            s2 = s[:s.index(BEGIN)] + block + s[s.index(END) + len(END):]
        else:
            print("TOOLS.md has malformed conduck-connect markers — fix or remove them first",
                  file=sys.stderr)
            sys.exit(1)
    # Truncate AFTER the write, never before: the file is never momentarily
    # empty, so an interrupted run cannot leave the agent with no guidance at
    # all where it previously had some.
    fh.seek(0)
    fh.write(s2)
    fh.truncate()
PY
  then
    ok "Conduck agent-guidance block installed in $target."
    note "Bootstrap files load at session START — conversations already open will NOT see"
    note "it; test in a NEW conversation."
  else
    warn "Could not update TOOLS.md — install the block by hand (the README's file-lane"
    warn "troubleshooting has the same three rules)."
  fi
  return 0
}

setup_file_lane() {
  # The heading does NOT say "recommended". Enter declines this step, and a
  # heading that recommends what the default refuses leaves a user who trusts
  # defaults unable to tell whether they just made a mistake. Enter is what has to
  # stay: yes here mints a credential and starts a boot-persistent authenticated
  # file server over the agent's working folder, and a change of that size is one
  # this tool always makes the operator ask for. The recommendation is still true,
  # so it stays on screen as advice with its price attached — which is the part a
  # single word could never carry, and the part that makes declining a real choice
  # rather than the cheapest keystroke.
  head_ "Step 4 — agent file lane (optional)"
  say "  Lets Conduck hand your agent real files (PDF/CSV/zip…) for its tools, and"
  say "  download files the agent writes back. Skipping is fine — chat (including"
  say "  pasted images) still works; the agent's tools just can't open attachments"
  say "  as real files."
  say "  How: a small password-protected file server (rclone WebDAV — a standard way"
  say "  to read and write files over the web) over the agent's working folder,"
  say "  shared the same way as the gateway."
  say "  Adding it afterwards means walking this whole wizard again, so it is worth"
  say "  the minute now if you ever plan to hand the agent a document."
  if ! confirm "  Set it up?" "file.setup.enable"; then
    note "Skipped — Conduck works without it (inline-only attachments)."
    note "Re-run me whenever you want it; nothing you approved today is undone by adding it later."
    return 0
  fi

  # rclone FIRST, because asking is free: without it no lane can be built at all,
  # and changing a foreign gateway's tool policy (and restarting it) for a lane
  # that cannot exist is a change made for nothing.
  if ! have rclone; then
    warn "rclone isn't installed. It's a single binary: https://rclone.org/install/"
    # The upstream installer stays the primary route on purpose: distro rclone
    # packages lag, and some repositories don't carry one at all, so a detected
    # package command is the convenience path and never the only one offered.
    local rc_hint="" rc_pm
    if [ "$OS" = "Darwin" ]; then
      rc_hint="brew install rclone"
    else
      rc_pm=$(linux_install_cmd rclone); [ -n "$rc_pm" ] && rc_hint="${rc_pm#*$'\t'}"
    fi
    [ -n "$rc_hint" ] && note "Or, if your package manager carries it:  $rc_hint"
    # This is not the end of the run: setup continues and pairs the gateway. Say
    # so — read as a dead end, the sensible-looking reaction is to abandon a setup
    # that was about to succeed.
    note "Nothing else stops here: setup continues without file transfer, and chat (including"
    note "pasted images) still works. If the checks below pass you get a chat-only setup code."
    note "Install rclone whenever you like and re-run me to add file transfer."
    return 0
  fi

  # OpenClaw: check the agent-side half BEFORE any unit or exposure work, so a
  # user who bails out here leaves nothing behind. (Byte transport is only half
  # the lane; the tool policy decides whether the agent may actually read/return
  # the files.)
  if [ "$GW_KIND" = "openclaw" ] && ! openclaw_tool_policy_step; then
    note "Leaving the file lane out — fix the tool policy, then re-run me to add it."
    FS_CRED=""; FS_URL=""
    return 0
  fi

  # Reuse an existing file server's folder + port + credential (the unit). A new
  # gateway gets its own free, stable loopback port: connector-owned units for
  # every OTHER gateway reserve their ports even while stopped, and a live bind
  # by any process also reserves a port.
  local workspace="" new_fs=false
  if existing_fs_config; then
    # A live server for this gateway is in play from here on, so every bail-out
    # below owes the operator the residue report.
    FS_LANE_PREPARED=true
    # A unit file is not a running service. Claiming "found your file server" for a
    # unit that sits `failed` is the checkmark that makes a wedged lane invisible
    # for every later run.
    case "$(fs_unit_state)" in
      active)
        ok "Found your existing file server: folder + port $FS_LOCAL_PORT, password recovered." ;;
      inactive)
        warn "Found this gateway's file-server unit (folder + port $FS_LOCAL_PORT, password recovered),"
        warn "but its service is NOT running." ;;
      *)
        ok "Found this gateway's file-server unit: folder + port $FS_LOCAL_PORT, password recovered."
        note "(I can't ask this machine whether its service is running.)" ;;
    esac
    workspace="$FS_FOLDER"
    # The served root is re-certified and re-published on every run, so a root the
    # doctor refuses to grade must not pass here either — this is the one gate
    # between a mis-pointed unit and a setup code that publishes it.
    if ! fs_resolve_shared_folder "$FS_FOLDER"; then
      fs_folder_refusal_warn "$FS_FOLDER"
      warn "That is what this unit serves, so I won't expose it or put it in a setup code."
      note "Point the unit at the agent's working folder (or remove it, below) and re-run me."
      FS_CRED=""; FS_URL=""
      fs_lane_residue_note
      return 0
    fi
    if [ "$FS_FOLDER_RESOLVED" != "$FS_FOLDER" ]; then
      warn "That unit serves $FS_FOLDER, which is a link to $FS_FOLDER_RESOLVED."
      warn "rclone re-resolves it on every request, so whatever the link points at is what gets"
      warn "served — it can be re-pointed under the running server with no restart and no re-check."
      note "Recreate the lane against the real path when you can: remove the unit (commands are"
      note "printed whenever a lane is left out) and re-run me."
    fi
    if [ "$OS" = "Linux" ] \
       && ! ensure_existing_fs_envfile_linux; then
      FS_CRED=""; FS_URL=""
      fs_lane_residue_note
      return 0
    fi
    if $FS_CRED_LEGACY_ARGV; then
      warn "Heads-up: that older unit keeps the file password on its command line (visible via 'ps')."
      note "It still works and the QR is correct. To hide it, recreate the unit so rclone reads the"
      note "password from a 0600 env file ('RCLONE_PASS' / '--htpasswd'); newly-created units already do."
    fi
    # A reused unit is shipped in this code exactly like a fresh one, so its
    # durability is checked here too — a lane first created in a non-lingering
    # session would otherwise be re-shipped silently by every later run.
    [ "$OS" = "Linux" ] && fs_report_linger_linux
  else
    if $FS_EXISTING_UNSAFE; then
      warn "I will not overwrite or expose that existing unit. Repair/remove it explicitly, then re-run setup."
      FS_CRED=""; FS_URL=""; return 0
    fi
    if $REUSE_ONLY; then
      note "(reuse-only: no existing file server found; skipping the file lane — re-run without --reuse-only to create one)"
      FS_CRED=""; return 0
    fi
    # Keeping the file server running needs a service manager we know how to
    # drive; on Linux that's a reachable systemd USER manager. Check BEFORE
    # minting a credential or writing a unit that could never start. Named for
    # what the probe actually proves: `show-environment` answers "a user manager
    # is reachable from this shell", not "there is a login session".
    if [ "$OS" = "Linux" ] && ! { have systemctl && systemctl --user show-environment >/dev/null 2>&1; }; then
      warn "No reachable systemd user manager here (Alpine/OpenRC, some containers, or a su/sudo shell) —"
      warn "I can't keep a file server running in the background. Skipping the file lane; chat still works."
      note "If this box does run systemd, log in directly as this user (ssh, not 'su -') and re-run."
      # The credential is minted much later, so this path has none to hand over —
      # and nothing here can discover or adopt an OpenRC/runit/s6 service on a
      # later run, so a manual lane is paired by hand in the app, not by me.
      note "Advanced: under your own supervisor (OpenRC/runit/s6), run 'rclone serve webdav <folder> --addr 127.0.0.1:<free-port> --user conduck --dir-cache-time 1s' with a password YOU choose exported as RCLONE_PASS, expose that port the same way as the gateway, then enter that address and password in the app by hand — I can only pair a lane I created."
      FS_CRED=""; FS_URL=""; return 0
    fi
    if ! allocate_fs_local_port; then
      warn "${FS_PORT_ALLOCATION_REASON:-Could not allocate a safe loopback port for a new file lane.}"
      FS_CRED=""; return 0
    fi
    ok "Reserved loopback port $FS_LOCAL_PORT for this gateway's file lane."
    # A default here is a claim about where the AGENT reads and writes, and this
    # wizard can only make that claim for the two gateways it configures itself.
    # A custom gateway is any OpenAI-compatible server at all — a plain model
    # server with no filesystem of its own, an agent in a container, another
    # account, a worker on another box — so an invented path would be a folder the
    # agent never looks in, offered behind an Enter and then certified by a lane
    # that only ever proves bytes moved. Custom therefore gets NO default: the
    # operator names the folder, because only they know where their agent lives.
    case "$GW_KIND" in
      openclaw) workspace="$HOME/.openclaw/workspace" ;;
      hermes)   workspace="$HOME/.hermes/files" ;;
      *)        workspace="" ;;
    esac
    # The folder questions are the one re-askable group in this step, and the only
    # place in it where Back costs nothing: at this point the lane exists solely as
    # a port number held in memory, so walking back out writes nothing and undoes
    # nothing. `b` at the path prompt returns to "use a different folder?", and `b`
    # there re-asks the step's own yes/no — the QUESTION only, never the detection
    # above it. Re-running that would re-open the OpenClaw tool-policy step and ask
    # the operator to approve a gateway change they already answered.
    #
    # No default means there is nothing to confirm keeping, so the confirm is
    # skipped rather than answered — and the explanation it carries moves onto the
    # prompt itself (fs_ask_shared_folder's `i`), which is where an operator with
    # no default to fall back on actually needs it. That prompt offers no `b` for
    # the same reason: there is no gate above it to go back to.
    local w folder_gate
    while true; do
      folder_gate=0
      [ -n "$workspace" ] \
        && { confirm "  Use a different folder than $workspace?" "file.folder.override" true || folder_gate=$?; }
      if [ "$folder_gate" = "10" ]; then
        say ""; note "↩ Back to the file-lane question."
        if confirm "  Set it up?" "file.setup.enable"; then continue; fi
        note "Skipped — Conduck works without it (inline-only attachments)."
        note "Re-run me whenever you want it; nothing you approved today is undone by adding it later."
        FS_CRED=""; FS_URL=""; FS_FOLDER=""
        return 0
      fi
      if [ "$folder_gate" = "0" ]; then
        while true; do
          if [ -n "$workspace" ]; then
            prompt_into w ask "  Absolute path to the agent's working folder" "$workspace" "" "file.folder.override" true \
              || continue 2
          else
            prompt_into w fs_ask_shared_folder
          fi
          case "$w" in /*) ;; *) warn "Please give an absolute path (starting with /)."; continue ;; esac
          if ! fs_resolve_shared_folder "$w"; then
            fs_folder_refusal_warn "$w"
            continue
          fi
          # Only for the no-default gateways, and only because the question is a
          # different one there. OpenClaw and Hermes are asked for a folder the
          # wizard is helping to SET UP, so creating it is part of the job; a custom
          # operator is naming a folder their agent ALREADY uses, so a path that is
          # not on this machine is a typo or a path the agent will never see. Left to
          # run, it becomes an empty folder nothing writes to, served by a lane that
          # proves only that bytes moved — the exact false green this step removes.
          if [ -z "$workspace" ] && [ ! -d "$FS_FOLDER_RESOLVED" ]; then
            warn "$w does not exist on this machine."
            note "This has to be the folder your agent ALREADY reads and writes. Create it and point your"
            note "agent at it first, or give me the path it uses today."
            continue
          fi
          [ "$FS_FOLDER_RESOLVED" != "$w" ] \
            && note "$w resolves to $FS_FOLDER_RESOLVED — I'll serve and record the resolved path, so a later change to the link can't move the served folder under a running server."
          workspace="$FS_FOLDER_RESOLVED"; break
        done
      else
        # The default is resolved on exactly the same terms: `~/.openclaw/workspace`
        # is a path like any other, and it can be a link to $HOME too.
        if ! fs_resolve_shared_folder "$workspace"; then
          fs_folder_refusal_warn "$workspace"
          warn "Leaving the optional file lane out; chat is unaffected."
          FS_CRED=""; FS_URL=""; FS_FOLDER=""
          return 0
        fi
        [ "$FS_FOLDER_RESOLVED" != "$workspace" ] \
          && note "$workspace resolves to $FS_FOLDER_RESOLVED — I'll serve and record the resolved path."
        workspace="$FS_FOLDER_RESOLVED"
      fi
      break
    done
    FS_FOLDER="$workspace"   # new lane knows its own folder — recorded in the profile
    new_fs=true
  fi

  # Linux's systemd ExecStart language expands `$` environment references and
  # `%` specifiers even though a filesystem can store those characters. Refuse
  # such a newly selected workspace before any Hermes config/guidance edit or
  # file-server write; spaces, quotes, and backslashes are encoded safely.
  if $new_fs && [ "$OS" = "Linux" ] && ! fs_systemd_value_safe "$workspace"; then
    warn "That workspace path contains control characters, '$', or '%' and cannot be represented safely in a systemd service."
    warn "Choose a different folder and re-run; leaving the optional file lane out."
    FS_CRED=""; FS_URL=""; FS_FOLDER=""
    return 0
  fi

  # Hermes has two independent silent-failure gates: the API-server agent needs
  # its file toolset and exact working root, and it needs the Conduck return-file
  # convention in the context file Hermes actually loads. Both are explicit,
  # narrowly scoped, and consented. Anything ambiguous omits the optional lane.
  if [ "$GW_KIND" = "hermes" ]; then
    if [ -z "$workspace" ]; then
      warn "The existing Hermes file-server unit does not reveal its served folder — leaving the lane out."
      FS_CRED=""; FS_URL=""; fs_lane_residue_note; return 0
    fi
    if ! hermes_file_readiness_step "$workspace"; then
      hermes_residual_state_note
      FS_CRED=""; FS_URL=""; fs_lane_residue_note; return 0
    fi
    # This step advertises PDF as a supported attachment type, and Hermes reads a
    # PDF by running `pdftotext` — a Poppler tool a stock host does not carry. A
    # working lane must not be read as "PDFs work", so the gap is named here,
    # once, before the guidance block that relies on the tool.
    #
    # Advisory, never a gate: this is the wizard's shell, not the Hermes service
    # environment, and the two can have different PATHs. Print only — no install,
    # no sudo, and the lane's outcome is untouched either way.
    if ! have pdftotext; then
      note "I cannot find pdftotext in this shell. PDF files still transfer, but Hermes may not be able to read their text."
      if [ "$OS" = "Darwin" ]; then
        note "Homebrew carries it:  brew install poppler"
      elif have apt-get; then
        local pdf_priv; pdf_priv=$(priv_prefix); [ -n "$pdf_priv" ] && pdf_priv="$pdf_priv "
        note "Debian/Ubuntu carry it:  ${pdf_priv}apt-get install -y poppler-utils"
      else
        # Poppler's package name varies enough across managers that guessing one
        # would print a package that does not exist. Name the tool, not a command.
        note "Install Poppler's pdftotext with this system's package manager."
      fi
    fi
    # The same class of finding, one layer up: the block's PDF rule needs Hermes's
    # own `terminal` toolset, and an explicit api_server list can leave it out —
    # the shape an operator gets by following an older release of this wizard. The
    # rule is then inert no matter what this host has installed, so say it here
    # rather than let a green lane imply PDFs work.
    #
    # Advisory on the same terms as the note above: never a gate, and printed only
    # for a config the analyzer read cleanly and found no terminal toolset in.
    # HERMES_TERMINAL_TOOLSET is whatever hermes_file_readiness_step's last
    # analysis read said, so it already reflects any edit approved in that step.
    if [ "$HERMES_TERMINAL_TOOLSET" = "no" ]; then
      note "This API server's toolset list has no terminal tool, so the agent cannot run that PDF command at all. Every other attachment type is unaffected."
      note "To give it one, add terminal to platform_toolsets.api_server in ~/.hermes/config.yaml and restart Hermes."
    fi
    if ! install_conduck_hermes_block "$workspace"; then
      hermes_residual_state_note
      FS_CRED=""; FS_URL=""; fs_lane_residue_note; return 0
    fi
  fi

  if $new_fs; then
    if $DRY_RUN; then
      # The shared folder is a real host change, and the plan is promised to
      # enumerate every one of them. Named only when it would actually be created:
      # an existing agent workspace is reused untouched (mkdir -p is a no-op and
      # its mode is left alone), so listing it as a change would be a lie the real
      # run never tells.
      if [ -d "$workspace" ]; then
        plan_add "MINT a file-server password; write unit conduck-files-$GW_ID + 0600 password file; serve the EXISTING folder $workspace (permissions untouched) on 127.0.0.1:$FS_LOCAL_PORT"
      else
        plan_add "CREATE the shared agent folder $workspace (0700); MINT a file-server password; write unit conduck-files-$GW_ID + 0600 password file; serve $workspace on 127.0.0.1:$FS_LOCAL_PORT"
      fi
      note "(dry-run: would mint a password and write the file-server unit)"
    else
      mutate_guard "write file-server unit + password" || {
        hermes_residual_state_note
        FS_CRED=""; return 0
      }
      # Every attachment the app uploads and every file the agent writes back
      # lands in this folder. Created under `umask 077` so a shared host does not
      # get the ambient 0755 — an agent workspace that ALREADY exists keeps its
      # own mode (mkdir -p is a no-op on it), which is why the advisory below
      # reports rather than silently re-chmods somebody else's directory.
      ( umask 077; mkdir -p "$workspace" ) || {
        warn "Could not create $workspace — skipping file lane."
        hermes_residual_state_note
        FS_CRED=""; return 0
      }
      if python3 -c 'import os,sys; sys.exit(0 if os.stat(sys.argv[1]).st_mode & 0o077 else 1)' \
           "$workspace" 2>/dev/null; then
        note "$workspace is readable by other accounts on this machine (it already existed with that mode)."
        note "On a shared host, 'chmod 700 $workspace' keeps your attachments and the agent's output files private."
      fi
      FS_CRED=$(openssl rand -hex 16)
      ok "Minted a fresh high-entropy password (stored 0600; rides in the QR, never on the command line)."
      # From the next line on there is a password on disk and, moments later, a
      # boot-enabled server over the agent's folder. Recorded BEFORE the writer
      # runs, because a writer that fails halfway leaves exactly that behind.
      FS_LANE_PREPARED=true
      FS_UNIT_CREATED_THIS_RUN=true
      if [ "$OS" = "Linux" ]; then
        write_fs_unit_linux "$workspace" || {
          warn "File-server unit did not start — leaving the lane out."
          hermes_residual_state_note
          FS_CRED=""; fs_lane_residue_note; return 0
        }
      else
        write_fs_unit_mac "$workspace" || {
          warn "File-server unit did not start — leaving the lane out."
          hermes_residual_state_note
          FS_CRED=""; fs_lane_residue_note; return 0
        }
      fi
    fi
  fi

  # OpenClaw: teach the agent the Conduck attachment rules (session-start
  # bootstrap). Runs for NEW and REUSED lanes alike — the folder is known
  # either way (FS_FOLDER; empty for an unrecoverable legacy unit → the
  # installer skips with a pointer instead). Placed BEFORE exposure so a
  # decline/failure here can never leave a half-exposed lane behind. The
  # `$DRY_RUN` arm: a planned NEW lane never sets FS_CRED, but the plan must
  # still show the TOOLS.md line (every earlier bail-out already returned).
  if [ "$GW_KIND" = "openclaw" ] && { [ -n "$FS_CRED" ] || $DRY_RUN; }; then
    install_conduck_tools_block "$FS_FOLDER"
  fi

  # Never expose a path merely because a unit file exists. In a dry run we
  # promise zero network requests, so record the future gate; real setup and
  # reuse-only both prove active service ownership + authentication on loopback.
  if $DRY_RUN; then
    plan_add "VERIFY file-server unit active + authenticated PUT/GET on 127.0.0.1:$FS_LOCAL_PORT before exposure"
  elif [ -n "$FS_CRED" ] && ! fs_local_service_ready; then
    warn "The file server is not safe to expose yet — leaving it out of the QR."
    hermes_residual_state_note
    FS_CRED=""; FS_URL=""
    fs_lane_residue_note
    return 0
  fi

  # Expose the file lane. Prefer the file lane's OWN existing mapping over re-deriving
  # one from the gateway transport, and never include a lane whose reach (scope)
  # silently differs from the gateway's.
  case "$TRANSPORT" in
    tailscale|funnel)
      local gw_funnel=false; [ "$TRANSPORT" = "funnel" ] && gw_funnel=true
      local host; host=$(tailscale_dns_name)
      local existing; existing=$(ts_port_for_backend "$FS_LOCAL_PORT")
      if [ -n "$existing" ]; then
        # Already exposed — reuse THIS mapping; apply the scope-match policy.
        local ehttps="${existing%%$'\t'*}" everb="${existing#*$'\t'}"
        local escope="private"; [ "$everb" = "funnel" ] && escope="public"
        if [ "$escope" = "$SCOPE" ]; then
          FS_URL="https://$host:$ehttps"; FS_REACH="$escope"
          ok "File lane ready at $FS_URL (reusing its existing $everb exposure)."
        else
          resolve_fs_scope_mismatch "$ehttps" "$everb" "$host"
        fi
        # The lane's own backend can carry stale public Funnels on OTHER ports too.
        if [ "$SCOPE" = "private" ] && [ -n "$FS_CRED" ] && [ -n "$FS_URL" ]; then
          sweep_stale_public_funnels "$FS_LOCAL_PORT" "${FS_URL##*:}" "$host"
        fi
      elif $REUSE_ONLY; then
        note "(reuse-only: the file lane has no HTTPS exposure yet and I won't create one — leaving it out)"
        FS_CRED=""
        fs_lane_residue_note
      elif pick_public_port "$TRANSPORT" "$FS_LOCAL_PORT" "file"; then
        # Not yet exposed — allocate on the gateway's transport (scope matches by construction).
        FS_HTTPS_PORT="$PICKED_PORT"
        if tailscale_expose "$FS_HTTPS_PORT" "$FS_LOCAL_PORT" "$gw_funnel" "file"; then
          FS_URL="https://$host:$FS_HTTPS_PORT"; FS_REACH="$SCOPE"
          ok "File lane ready at $FS_URL."
        else
          warn "File-lane exposure not confirmed — leaving it out of the QR."
          drop_file_lane
          fs_lane_residue_note
        fi
      else
        warn "No free HTTPS port for the file lane on this transport — skipping the file lane."
        FS_CRED=""   # no permitted port free; file lane skipped
        fs_lane_residue_note
      fi
      ;;
    cloudflare)
      say ""
      say "  Add a second ingress rule for the file lane:"
      say ""
      say "      - hostname: ${BOLD}files.YOURDOMAIN${RESET}"
      say "        service: http://127.0.0.1:$FS_LOCAL_PORT"
      say ""
      # An HTTPS route the OPERATOR creates is one this connector can never unmap
      # for them, so a lane dropped later has to name it. Recorded the moment they
      # confirm they made it (or say they already have one).
      if $REUSE_ONLY; then
        note "(reuse-only: assuming your file-lane ingress rule already exists)"
        local h
        ask_fs_url "The file-lane web address (leave blank to review omitting file transfer)" || die "$NO_ANSWER"
        h="$ASK_FS_URL_RESULT"
        if [ -n "$h" ]; then FS_URL="$h"; FS_ROUTE_SELF_MANAGED=true; fs_warn_quick_tunnel_url
        else warn "File transfer is NOT in this setup code — chat still works."; FS_CRED=""; fs_lane_residue_note; fi
      elif print_and_wait "file.cloudflare.route" \
        "Same dance as before: ingress rule + 'tunnel route dns' + restart cloudflared." \
        "cloudflared tunnel route dns <your-tunnel> files.YOURDOMAIN"; then
        FS_ROUTE_SELF_MANAGED=true
        local h2
        ask_fs_url "The file-lane web address you configured (leave blank to review omitting file transfer)" || die "$NO_ANSWER"
        h2="$ASK_FS_URL_RESULT"
        if [ -n "$h2" ]; then FS_URL="$h2"; fs_warn_quick_tunnel_url
        else warn "File transfer is NOT in this setup code — chat still works."; FS_CRED=""; fs_lane_residue_note; fi
      else
        # Enter at that prompt means "no, I didn't add the route", so this branch is
        # now the one a hurried operator lands in — it has to say what it decided
        # rather than fall through in silence. It is still the right ending: without
        # the ingress rule there is no address that reaches the file server, so a
        # code claiming one would fail on the first attachment.
        warn "File transfer is NOT in this setup code — chat still works."
        note "Add the ingress rule whenever you like and re-run me to put file transfer in a new code."
        FS_CRED=""
        fs_lane_residue_note
      fi
      ;;
    public)
      say ""
      say "  Your gateway's web server needs a second route for the file lane → 127.0.0.1:$FS_LOCAL_PORT"
      say "  (a second server block, a subdomain, or another port)."
      note "Give it the same reach as the gateway (both public, or both private) — attachments follow this address."
      note "Its certificate must be trusted the same way the gateway's is; the app applies one rule to both."
      local h
      ask_fs_url "The https:// web address that reaches it (leave blank to review omitting file transfer)" || die "$NO_ANSWER"
      h="$ASK_FS_URL_RESULT"
      if [ -n "$h" ]; then
        FS_URL="$h"
        FS_ROUTE_SELF_MANAGED=true   # their own web server holds it; only they can take it back down
        fs_warn_quick_tunnel_url     # "my own HTTPS" reaches a quick tunnel just as easily
      else
        warn "File transfer is NOT in this setup code — chat still works (inline-only attachments)."
        FS_CRED=""
        fs_lane_residue_note
      fi
      ;;
  esac
}
