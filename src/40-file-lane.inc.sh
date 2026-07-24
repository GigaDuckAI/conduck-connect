# ----------------------------------------------------------- file-lane phase --

FS_URL=""; FS_CRED=""; FS_CERT_FP=""
FS_LOCAL_PORT=""
FS_REACH=""         # the file lane's OWN reach (public|private) — can differ from the gateway's
                    # SCOPE in a mixed-scope setup; recorded as fileServer.reach for --show-code
FS_UNIT=""          # resolved unit/plist path actually in use (existing or new)
FS_FOLDER=""        # served workspace path — for the non-secret profile only; "" when unknown
FS_CRED_LEGACY_ARGV=false   # true when a reused unit keeps the password on argv (ps-visible)

state_cred_file() { printf '%s/fileserver-%s.cred' "$STATE_DIR" "$GW_ID"; }
state_env_file()  { printf '%s/fileserver-%s.env'  "$STATE_DIR" "$GW_ID"; }

linux_unit_candidates() {
  printf '%s\n' \
    "$HOME/.config/systemd/user/conduck-files-$GW_ID.service" \
    "$HOME/.config/systemd/user/conduck-files.service" \
    "$HOME/.config/systemd/user/conduck-fileserver.service"
}
mac_unit_candidates() {
  printf '%s\n' \
    "$HOME/Library/LaunchAgents/ai.gigaduck.conduck-files-$GW_ID.plist" \
    "$HOME/Library/LaunchAgents/ai.gigaduck.conduck-files.plist" \
    "$HOME/Library/LaunchAgents/ai.gigaduck.conduck-fileserver.plist"
}

# Find an existing file-server unit (script OR app generated) and recover its
# config: local port + credential + served folder. Sets FS_LOCAL_PORT + FS_CRED +
# FS_UNIT + FS_FOLDER (folder is best-effort — for the profile only, never gates).
existing_fs_config() {
  local unit="" f
  if [ "$OS" = "Linux" ]; then
    while IFS= read -r f; do [ -f "$f" ] && { unit="$f"; break; }; done < <(linux_unit_candidates)
  else
    while IFS= read -r f; do [ -f "$f" ] && { unit="$f"; break; }; done < <(mac_unit_candidates)
  fi
  [ -n "$unit" ] || return 1
  FS_UNIT="$unit"

  # addr port: systemd ExecStart carries `--addr 127.0.0.1:PORT` on one line, but
  # a plist splits it across two <string> elements — parse those STRUCTURALLY, or
  # a lane on a non-default port silently falls back to 5006 and probes nothing.
  local port=""
  if [ "${unit##*.}" = "plist" ]; then
    port=$(python3 - "$unit" <<'PY' 2>/dev/null
import sys, plistlib
try:
    a = plistlib.load(open(sys.argv[1], 'rb')).get("ProgramArguments", [])
    i = a.index("--addr")
    print(a[i + 1].rsplit(":", 1)[-1])
except Exception: pass
PY
)
  else
    port=$(grep -oE -- '--addr[" >]+127\.0\.0\.1:[0-9]+' "$unit" 2>/dev/null | grep -oE '[0-9]+$' | head -1)
  fi
  case "$port" in ''|*[!0-9]*) port="" ;; esac
  FS_LOCAL_PORT="${port:-5006}"

  # served folder: the `rclone serve webdav <folder>` argument. Plist → the element
  # right after "webdav" (STRUCTURAL, handles any path); systemd → the text between
  # `serve webdav` and `--addr` (the existing grep style; strip its surrounding
  # quotes). Best-effort: recorded in the profile only, omitted when unreadable.
  FS_FOLDER=""
  if [ "${unit##*.}" = "plist" ]; then
    FS_FOLDER=$(python3 - "$unit" <<'PY' 2>/dev/null
import sys, plistlib
try:
    a = plistlib.load(open(sys.argv[1], 'rb')).get("ProgramArguments", [])
    i = a.index("webdav")
    print(a[i + 1])
except Exception: pass
PY
)
  else
    FS_FOLDER=$(sed -n 's/^ExecStart=.* serve webdav \(.*\) --addr .*/\1/p' "$unit" 2>/dev/null | head -1)
    FS_FOLDER="${FS_FOLDER#\"}"; FS_FOLDER="${FS_FOLDER%\"}"
  fi

  # credential: prefer our 0600 state cred file; else env file RCLONE_PASS; else
  # recover it from the unit. Plists are parsed STRUCTURALLY (`<string>--pass</string>`
  # never matches a text regex). Track whether it came from argv (visible via `ps`).
  FS_CRED=""; FS_CRED_LEGACY_ARGV=false
  if [ -f "$(state_cred_file)" ]; then FS_CRED=$(cat "$(state_cred_file)")
  elif [ -f "$(state_env_file)" ]; then FS_CRED=$(env_get "$(state_env_file)" "RCLONE_PASS")
  elif [ "${unit##*.}" = "plist" ]; then
    local line; line=$(python3 - "$unit" <<'PY' 2>/dev/null
import sys,plistlib
try:
    d=plistlib.load(open(sys.argv[1],'rb')); a=d.get("ProgramArguments",[])
    if "--pass" in a: print("ARGV\t"+a[a.index("--pass")+1])           # app plist: cred on argv
    else:
        c=(d.get("EnvironmentVariables",{}) or {}).get("RCLONE_PASS","")
        if c: print("ENV\t"+c)
except Exception: pass
PY
)
    if [ -n "$line" ]; then FS_CRED="${line#*$'\t'}"; [ "${line%%$'\t'*}" = "ARGV" ] && FS_CRED_LEGACY_ARGV=true; fi
  else
    FS_CRED=$(grep -oE -- '--pass[" >]+[a-f0-9]{16,}' "$unit" 2>/dev/null | grep -oE '[a-f0-9]{16,}' | head -1)
    [ -n "$FS_CRED" ] && FS_CRED_LEGACY_ARGV=true
  fi
  # The `ps`-visible-credential warning keys off the UNIT, not off which source the
  # cred was read from: a leftover state-cred file must not mask an argv-exposed unit.
  if ! $FS_CRED_LEGACY_ARGV; then
    local argv_exposed=""
    if [ "${unit##*.}" = "plist" ]; then
      argv_exposed=$(python3 - "$unit" <<'PY' 2>/dev/null
import sys,plistlib
try:
    a=plistlib.load(open(sys.argv[1],'rb')).get("ProgramArguments",[])
    print("yes" if "--pass" in a else "")
except Exception: pass
PY
)
    elif grep -qE -- '--pass[" >]+[a-f0-9]{16,}' "$unit" 2>/dev/null; then
      argv_exposed="yes"
    fi
    [ -n "$argv_exposed" ] && FS_CRED_LEGACY_ARGV=true
  fi
  [ -n "$FS_CRED" ] || { FS_UNIT=""; return 1; }
  return 0
}

# Write a per-gateway file-server unit that reads RCLONE_PASS from a 0600 env file
# (credential never appears on the process command line / in `ps`).
write_fs_unit_linux() { # write_fs_unit_linux <workspace>
  local ws="$1" envf; envf=$(state_env_file)
  FS_UNIT="$HOME/.config/systemd/user/conduck-files-$GW_ID.service"
  mkdir -p "$(dirname "$FS_UNIT")" "$STATE_DIR"
  umask 077
  printf 'RCLONE_PASS=%s\n' "$FS_CRED" > "$envf"; chmod 600 "$envf"
  printf '%s\n' "$FS_CRED" > "$(state_cred_file)"; chmod 600 "$(state_cred_file)"
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
EnvironmentFile=$envf
ExecStart=$(command -v rclone) serve webdav "$ws" --addr 127.0.0.1:$FS_LOCAL_PORT --user conduck --dir-cache-time 1s
Restart=on-failure

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now "conduck-files-$GW_ID.service" && ok "File server running in the background (a systemd user service)." \
    || warn "Could not start the service — check 'systemctl --user status conduck-files-$GW_ID'."
  local user_name="${USER:-$(id -un)}"   # $USER can be unset under set -u (su/cron shells)
  loginctl show-user "$user_name" 2>/dev/null | grep -q 'Linger=yes' || {
    warn "User services stop at logout unless 'linger' is on (needed for a 24/7 box)."
    run_step "enable linger so the file server survives logout/reboot" \
      sudo loginctl enable-linger "$user_name" || \
      note "Tip: 'sudo loginctl enable-linger $user_name' keeps user services running after logout."
  }
}

write_fs_unit_mac() { # write_fs_unit_mac <workspace>
  FS_UNIT="$HOME/Library/LaunchAgents/ai.gigaduck.conduck-files-$GW_ID.plist"
  mkdir -p "$(dirname "$FS_UNIT")" "$STATE_DIR"
  umask 077
  printf '%s\n' "$FS_CRED" > "$(state_cred_file)"; chmod 600 "$(state_cred_file)"
  # Build the plist structurally with plistlib (correct escaping for any path).
  RCLONE_BIN="$(command -v rclone)" WS="$1" PORT="$FS_LOCAL_PORT" CRED="$FS_CRED" \
  LABEL="ai.gigaduck.conduck-files-$GW_ID" PLIST="$FS_UNIT" python3 - <<'PY'
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
  launchctl load -w "$FS_UNIT" && ok "File server running in the background (a macOS LaunchAgent that restarts it automatically)." \
    || warn "Could not load the LaunchAgent — check 'launchctl list | grep conduck'."
  note "LaunchAgents run while this user is logged in — for a 24/7 Mac, keep automatic login on."
  if pmset -g 2>/dev/null | grep -qE '^[[:space:]]*sleep[[:space:]]+[1-9]'; then
    warn "This Mac is set to sleep — a sleeping host isn't reachable 24/7."
    note "For an always-on gateway: enable automatic login + 'sudo pmset -a sleep 0'."
  fi
}

# --- file-lane scope alignment ------------------------------------------------
# The payload carries a single, gateway-oriented `transport`, so a file lane whose
# reach (scope) differs from the gateway's is a real hazard. On a mismatch we offer
# to ALIGN the lane to the gateway, OMIT it, or INCLUDE it as-is (advanced).
# $SCOPE = the gateway's scope (public|private); the lane's is derived from its verb.

# Promote a private file lane to PUBLIC (Funnel) so it matches a public gateway.
# Publication event → a SECOND explicit confirm on top of the menu choice.
fs_promote_public() { # fs_promote_public <existing-https-port> <existing-verb> <host>
  local ehttps="$1" everb="$2" host="$3"
  if ! confirm "  Expose your files to the PUBLIC internet (only the credential guards them)?"; then
    FS_CRED=""; note "Leaving the file lane out — keeping your files off the public internet."
    return 0
  fi
  case "$ehttps" in
    443|8443|10000)
      # Already on a Funnel-eligible port → switch in place (serve → funnel; most-recent
      # command wins, so funnel cleanly supersedes the serve handler — no `serve off`).
      if tailscale_expose "$ehttps" "$FS_LOCAL_PORT" true file; then
        FS_URL="https://$host:$ehttps"; FS_REACH="public"; ok "File lane is now public at $FS_URL."
      else warn "Could not make the file lane public — leaving it out."; drop_file_lane; fi
      ;;
    *)
      # Lane is on a non-Funnel port (e.g. 8444/9443) → need a free Funnel port.
      if ! pick_public_port funnel "$FS_LOCAL_PORT" file; then
        # No Funnel port free — NOTHING was changed, the lane is still private. Don't
        # silently drop a working lane: offer to keep it private instead of losing it.
        warn "Couldn't make the file lane public — all three Funnel ports (443/8443/10000) are already in use by other services on this machine."
        if confirm "  Keep the file lane PRIVATE instead (reachable on your Tailscale network)?"; then
          FS_URL="https://$host:$ehttps"; FS_REACH="private"
          warn "Keeping the file lane private at $FS_URL."
          warn "Heads-up: the gateway is PUBLIC but this file lane stays Tailscale-only, so attachments work only on your Tailscale-connected devices — an Apple Watch used away from your iPhone won't reach them. Chat still works everywhere."
        else FS_CRED=""; note "Leaving the file lane out."; fi
        return 0
      fi
      # Got a Funnel port → expose it, then drop the old private mapping (rollback-recorded).
      if tailscale_expose "$PICKED_PORT" "$FS_LOCAL_PORT" true file; then
        local newport="$PICKED_PORT"
        ts_unmap "$ehttps" "$everb"
        FS_URL="https://$host:$newport"; FS_REACH="public"; ok "File lane is now public at $FS_URL."
      else warn "Could not make the file lane public — leaving it out."; drop_file_lane; fi
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
  else warn "Could not make the file lane private — leaving it out (won't ship a public lane as private)."; drop_file_lane; fi
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
resolve_fs_scope_mismatch() { # resolve_fs_scope_mismatch <existing-https-port> <existing-verb> <host>
  local ehttps="$1" everb="$2" host="$3" c
  if [ "$SCOPE" = "public" ]; then
    warn "Your file lane can be reached only by your own Tailscale-connected devices, but the gateway is public."
    note "As-is, attachments would work only on your Tailscale network — a Watch used away from the phone couldn't reach files."
    if $REUSE_ONLY; then
      say "    1) Leave the file lane out — chat still works everywhere; no attachments"
      say "    2) Include it as-is  (advanced) — attachments only on your Tailscale devices"
      note "(Making it public would change an exposure; --reuse-only forbids changes — re-run without it to do that.)"
      c=$(require_choice "Choose 1-2 ('?' explains)" '^[12]$' explain_fs_mismatch) || die "$NO_ANSWER"
      case "$c" in
        1) FS_CRED=""; note "Leaving the file lane out." ;;
        2) FS_URL="https://$host:$ehttps"; FS_REACH="private"; ok "Included the file lane at $FS_URL (reachable only on your Tailscale network)." ;;
      esac
      return 0
    fi
    say "    1) Make the file lane public too — attachments then work wherever chat works"
    say "       (puts the password-protected file server on the public internet)"
    say "    2) Leave the file lane out — chat still works everywhere; no attachments"
    say "    3) Include it as-is  (advanced) — attachments only on your Tailscale devices;"
    say "       the file server itself stays private"
    c=$(require_choice "Choose 1-3 ('?' explains)" '^[123]$' explain_fs_mismatch) || die "$NO_ANSWER"
    case "$c" in
      1) fs_promote_public "$ehttps" "$everb" "$host" ;;
      2) FS_CRED=""; note "Leaving the file lane out — its reach doesn't match the public gateway." ;;
      3) FS_URL="https://$host:$ehttps"; FS_REACH="private"; ok "Included the file lane at $FS_URL (reachable only on your Tailscale network)." ;;
    esac
  else
    warn "Your file lane is on the public internet, but the gateway is private (only your Tailscale devices) — that exposes your files more widely than the gateway itself."
    if $REUSE_ONLY; then
      say "    1) Leave the file lane out — chat unaffected; no attachments"
      say "    2) Keep it public anyway  (advanced) — the file server stays reachable"
      say "       from the whole internet, unlike the gateway"
      note "(Making it private would change an exposure; --reuse-only forbids changes — re-run without it to do that.)"
      c=$(require_choice "Choose 1-2 ('?' explains)" '^[12]$' explain_fs_mismatch) || die "$NO_ANSWER"
      case "$c" in
        1) FS_CRED=""; note "Leaving the file lane out." ;;
        2) FS_URL="https://$host:$ehttps"; FS_REACH="public"; warn "Including a public file lane at $FS_URL." ;;
      esac
      return 0
    fi
    say "    1) Make the file lane private too — match the gateway (recommended);"
    say "       attachments then work wherever chat works"
    say "    2) Leave the file lane out — chat unaffected; no attachments"
    say "    3) Keep it public anyway  (advanced) — the file server stays reachable"
    say "       from the whole internet, unlike the gateway"
    c=$(require_choice "Choose 1-3 ('?' explains)" '^[123]$' explain_fs_mismatch) || die "$NO_ANSWER"
    case "$c" in
      1) fs_demote_private "$ehttps" "$everb" "$host" ;;
      2) FS_CRED=""; note "Leaving the file lane out." ;;
      3) FS_URL="https://$host:$ehttps"; FS_REACH="public"; warn "Including a public file lane at $FS_URL." ;;
    esac
  fi
}

# --- OpenClaw agent-side readiness (tool policy + TOOLS.md guidance) ----------
# A green file-lane test proves only that Conduck can STORE bytes — never that
# the AGENT may read or return them. Four gateway-side traps break attachments
# silently even with every transport check green (all verified live, July 2026):
#   1. tools.deny containing group:fs (a common hardening move) — the agent
#      can't open a single uploaded file;
#   2. the pdf tool isn't in the "coding" profile — PDFs get read as raw bytes
#      and answered with plausible nonsense;
#   3. output files need `write` — without it there are no download chips;
#   4. MEDIA:-style reply directives are STRIPPED on the OpenAI-compatible
#      endpoint — the agent "sends" a file that never arrives.
# 1-3 are config → openclaw_tool_policy_step checks and offers the exact fix.
# 4 is agent behavior → install_conduck_tools_block teaches it (TOOLS.md),
# scoped to Conduck turns so messaging channels (where MEDIA: is correct) are
# untouched. Neither is detectable app-side (the app deliberately has no
# capability probe), which is why the wizard is where this lives.

# Read tools.{profile,allow,alsoAllow,deny} from openclaw.json (JSON5-tolerant)
# and print a machine-readable verdict:
#   status<TAB><ok|none|fix|manual|unreadable><TAB><reason>
#   change<TAB><key>: <before> → <after>          (fix only, one per key)
#   cmd<TAB><manual `openclaw config set …` line>  (fix only, one per key)
#   ops<TAB><config set --batch-json payload>      (fix only)
# Encodes only DOC-VERIFIED semantics (docs.openclaw.ai, July 2026): deny wins;
# group:fs = read/write/edit/apply_patch; allow and alsoAllow are mutually
# exclusive per scope; pdf is absent from the coding profile. The fix is the
# MINIMUM relaxation: read/write (+pdf) on, edit/apply_patch/exec untouched —
# group:fs in deny is REPLACED by its mutating members, never just dropped.
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
if not isinstance(tools, dict):
    emit("status", "none",
         "no tools block in openclaw.json — the default policy leaves the agent's file tools on")
    sys.exit(0)

def arr(key):
    v = tools.get(key)
    if isinstance(v, list):
        return [x for x in v if isinstance(x, str)]
    return None

profile = tools.get("profile") if isinstance(tools.get("profile"), str) else None
allow, also, deny = arr("allow"), arr("alsoAllow"), arr("deny")
targets = ("read", "write", "pdf")

# An invalid config (both allow + alsoAllow) must never be auto-edited into a
# different invalid config — surface it instead.
if allow is not None and also is not None:
    emit("status", "manual",
         "tools.allow and tools.alsoAllow are BOTH set — OpenClaw's config validation "
         "rejects that combination; reconcile the two by hand first")
    sys.exit(0)

# A wildcard deny (e.g. "wri*", "*") that matches a file tool is a deliberate,
# broad operator choice — flag it for the human, never auto-rewrite it.
wild = [e for e in (deny or [])
        if any(ch in e for ch in "*?[")
        and (any(fnmatch.fnmatchcase(t, e.lower()) for t in targets)
             or fnmatch.fnmatchcase("group:fs", e.lower()))]
if wild:
    emit("status", "manual",
         "tools.deny has wildcard entries (%s) matching the agent's file tools — too "
         "broad for an automatic fix; edit tools.deny by hand so read/write are not matched"
         % ", ".join(wild))
    sys.exit(0)

changes = {}   # key -> (before-or-None, after)

if deny and any(e in ("group:fs", "read", "write") for e in deny):
    new_deny = []
    for e in deny:
        if e == "group:fs":
            # Replace with its MUTATING members: read/write freed, the rest of
            # the group's denial preserved.
            for m in ("edit", "apply_patch"):
                if m not in deny and m not in new_deny:
                    new_deny.append(m)
        elif e in ("read", "write"):
            continue
        else:
            new_deny.append(e)
    changes["tools.deny"] = (deny, new_deny)

if allow is not None:
    # A non-empty allowlist blocks everything omitted; group:fs inside it
    # already covers read/write. (alsoAllow is invalid alongside allow, so the
    # additions go HERE.)
    missing = [t for t in targets
               if t not in allow and not ("group:fs" in allow and t in ("read", "write"))]
    if missing:
        changes["tools.allow"] = (allow, allow + missing)
else:
    ensure = ["pdf"]                      # not in the coding profile
    if profile in ("minimal", "messaging"):
        ensure = ["read", "write", "pdf"]  # base profile may lack fs entirely
    elif profile == "full":
        ensure = []                        # full already includes everything
    base = also or []
    add = [t for t in ensure if t not in base]
    if add:
        changes["tools.alsoAllow"] = (also, base + add)

if not changes:
    detail = "profile: %s" % profile if profile else "no profile set"
    emit("status", "ok", "read/write allowed, pdf on (%s)" % detail)
    sys.exit(0)

bits = []
if "tools.deny" in changes:
    bits.append("tools.deny blocks the agent's read/write file tools")
if "tools.allow" in changes:
    bits.append("tools.allow omits " + ", ".join(
        t for t in targets if t in changes["tools.allow"][1] and t not in changes["tools.allow"][0]))
if "tools.alsoAllow" in changes:
    bits.append("the active profile lacks " + ", ".join(
        t for t in changes["tools.alsoAllow"][1]
        if t not in (changes["tools.alsoAllow"][0] or [])))
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
      ok "Tool policy is file-transfer-ready ($reason)."
      return 0 ;;
    none)
      ok "$reason."
      return 0 ;;
    unreadable|"")
      warn "Could not read the tool policy ($reason) — continuing, but if attachments later"
      warn "fail agent-side, check tools.deny / tools.allow in openclaw.json by hand."
      return 0 ;;
  esac

  # status = fix | manual — the policy would break agent file transfer.
  warn "This tool policy would break agent file transfer:"
  say  "    $reason"
  local applied=false
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
        if run_step "allow the agent's file tools in OpenClaw's tool policy" \
          docker compose --project-directory "$compose_dir" run --rm --no-deps --entrypoint node openclaw-gateway \
            dist/index.js config set --batch-json "$ops"; then
          run_step "restart the gateway so the policy applies" \
            docker compose --project-directory "$compose_dir" restart openclaw-gateway || true
          applied=true
        fi
      else
        local joined=""; local m
        for m in "${cmds[@]}"; do joined="${joined:+$joined && }$m"; done
        if print_and_wait "Not the standard Docker setup — apply the policy change with your install's CLI, then restart the gateway." \
          "$joined"; then applied=true; fi
      fi
    fi
    if $applied && ! $DRY_RUN; then
      # Re-read rather than trust: config set can no-op silently (wrong CLI,
      # wrong file) and verification below never exercises agent tools.
      # awk -F'\t', not sed \t — BSD sed treats \t as a literal 't'.
      local recheck; recheck=$(openclaw_tools_analysis "$cfg" | awk -F '\t' '$1=="status"{print $2; exit}')
      if [ "$recheck" = "ok" ]; then
        ok "Tool policy re-checked — now file-transfer-ready."
        return 0
      fi
      warn "The policy still doesn't look file-transfer-ready after the change — re-check"
      warn "tools.deny / tools.allow in openclaw.json by hand."
    elif $applied; then
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
  if confirm "  Keep the file lane anyway (fix the policy later, then re-run me)?"; then
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
# their behavior.
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
  say "    - returning files: write the file, then NAME it in plain reply text — never a"
  say "      MEDIA: directive (Conduck turns only; your other channels are unaffected)"
  if [ -f "$target" ]; then
    say "  Your TOOLS.md exists — the block is appended (or refreshed in place between its"
    say "  markers); everything else in the file stays byte-identical."
  fi
  if ! confirm "  Install/refresh the block?"; then
    note "Skipped — the README's file-lane troubleshooting carries the same guidance for manual setup."
    return 0
  fi

  if python3 - "$target" "$agent_ws" <<'PY'
import os, sys

target, agent_ws = sys.argv[1], sys.argv[2]
BEGIN = "<!-- conduck-connect:begin -->"
END = "<!-- conduck-connect:end -->"

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
    "- To RETURN a file: write it to the ROOT of your working directory and state its "
    "exact filename in plain text in your reply. Never use `MEDIA:` or other "
    "attachment directives in these conversations — this endpoint strips them and "
    "the file will not reach the user.\n"
) + END

if os.path.islink(target):
    print("TOOLS.md is a symlink — refusing to edit through it", file=sys.stderr)
    sys.exit(1)

if os.path.exists(target):
    s = open(target).read()
    nb, ne = s.count(BEGIN), s.count(END)
    if nb == 0 and ne == 0:
        s2 = s.rstrip("\n") + ("\n\n" if s.strip() else "") + block + "\n"
    elif nb == 1 and ne == 1 and s.index(BEGIN) < s.index(END):
        s2 = s[:s.index(BEGIN)] + block + s[s.index(END) + len(END):]
    else:
        print("TOOLS.md has malformed conduck-connect markers — fix or remove them first",
              file=sys.stderr)
        sys.exit(1)
else:
    s2 = block + "\n"

open(target, "w").write(s2)
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
  head_ "Step 4 — agent file lane (optional, recommended)"
  say "  Lets Conduck hand your agent real files (PDF/CSV/zip…) for its tools, and"
  say "  download files the agent writes back. Skipping is fine — chat (including"
  say "  pasted images) still works; the agent's tools just can't open attachments"
  say "  as real files."
  say "  How: a small password-protected file server (rclone WebDAV — a standard way"
  say "  to read and write files over the web) over the agent's working folder,"
  say "  shared the same way as the gateway."
  if ! confirm "  Set it up?"; then note "Skipped — Conduck works without it (inline-only attachments)."; return 0; fi

  # OpenClaw: check the agent-side half FIRST — before any unit or exposure
  # work, so a user who bails out here leaves nothing behind. (Byte transport
  # is only half the lane; the tool policy decides whether the agent may
  # actually read/return the files.)
  if [ "$GW_KIND" = "openclaw" ] && ! openclaw_tool_policy_step; then
    note "Leaving the file lane out — fix the tool policy, then re-run me to add it."
    FS_CRED=""; FS_URL=""
    return 0
  fi

  if ! have rclone; then
    warn "rclone isn't installed (single binary; https://rclone.org/install/ —"
    warn "brew install rclone / apt install rclone). Install it and re-run me,"
    warn "or skip the file lane for now."
    return 0
  fi

  # Reuse an existing file server's folder + port + credential (the unit). Whether
  # it ends up in the QR is decided by the exposure/scope step below — so this only
  # reports the unit, never "done."
  if existing_fs_config; then
    ok "Found your existing file server: folder + port $FS_LOCAL_PORT, credential recovered."
    if $FS_CRED_LEGACY_ARGV; then
      warn "Heads-up: that older unit keeps the file password on its command line (visible via 'ps')."
      note "It still works and the QR is correct. To hide it, recreate the unit so rclone reads the"
      note "password from a 0600 env file ('RCLONE_PASS' / '--htpasswd'); newly-created units already do."
    fi
  else
    if $REUSE_ONLY; then
      note "(reuse-only: no existing file server found; skipping the file lane — re-run without --reuse-only to create one)"
      FS_CRED=""; return 0
    fi
    # Keeping the file server running needs a service manager we know how to
    # drive; on Linux that's a systemd USER session. Check BEFORE minting a
    # credential or writing a unit that could never start.
    if [ "$OS" = "Linux" ] && ! { have systemctl && systemctl --user show-environment >/dev/null 2>&1; }; then
      warn "No systemd user session here (Alpine/OpenRC, some containers, or a su/sudo shell) —"
      warn "I can't keep a file server running in the background. Skipping the file lane; chat still works."
      note "If this box does run systemd, log in directly as this user (ssh, not 'su -') and re-run."
      note "Advanced: run 'rclone serve webdav <folder> --addr 127.0.0.1:5006 --user conduck --dir-cache-time 1s' with the app-generated password exported as RCLONE_PASS, under your own supervisor."
      FS_CRED=""; return 0
    fi
    FS_LOCAL_PORT=5006
    local workspace
    case "$GW_KIND" in
      openclaw) workspace="$HOME/.openclaw/workspace" ;;
      hermes)   workspace="$HOME/.hermes/files" ;;
      *)        workspace="$HOME/conduck-files" ;;
    esac
    if [ "$GW_KIND" = "custom" ] || confirm "  Use a different folder than $workspace?"; then
      while true; do
        local w; w=$(ask "  Absolute path to the agent's working folder" "$workspace")
        case "$w" in /*) ;; *) warn "Please give an absolute path (starting with /)."; continue ;; esac
        workspace="$w"; break
      done
    fi
    [ "$GW_KIND" = "hermes" ] && note "Hermes: also point terminal.cwd at this folder in ~/.hermes/config.yaml so its tools land here."
    FS_FOLDER="$workspace"   # new lane knows its own folder — recorded in the profile

    if $DRY_RUN; then
      plan_add "MINT a file-server credential; write unit conduck-files-$GW_ID + 0600 cred file; serve $workspace on 127.0.0.1:$FS_LOCAL_PORT"
      note "(dry-run: would mint a credential and write the file-server unit)"
    else
      mutate_guard "write file-server unit + credential" || { FS_CRED=""; return 0; }
      mkdir -p "$workspace" || { warn "Could not create $workspace — skipping file lane."; FS_CRED=""; return 0; }
      FS_CRED=$(openssl rand -hex 16)
      ok "Minted a fresh high-entropy credential (stored 0600; rides in the QR, never on the command line)."
      if [ "$OS" = "Linux" ]; then write_fs_unit_linux "$workspace"; else write_fs_unit_mac "$workspace"; fi
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
      elif pick_public_port "$TRANSPORT" "$FS_LOCAL_PORT" "file"; then
        # Not yet exposed — allocate on the gateway's transport (scope matches by construction).
        FS_HTTPS_PORT="$PICKED_PORT"
        if tailscale_expose "$FS_HTTPS_PORT" "$FS_LOCAL_PORT" "$gw_funnel" "file"; then
          FS_URL="https://$host:$FS_HTTPS_PORT"; FS_REACH="$SCOPE"
          ok "File lane ready at $FS_URL."
        else
          warn "File-lane exposure not confirmed — leaving it out of the QR."
          drop_file_lane
        fi
      else
        warn "No free HTTPS port for the file lane on this transport — skipping the file lane."
        FS_CRED=""   # no permitted port free; file lane skipped
      fi
      ;;
    cloudflare)
      say ""
      say "  Add a second ingress rule for the file lane:"
      say ""
      say "      - hostname: ${BOLD}files.YOURDOMAIN${RESET}"
      say "        service: http://127.0.0.1:$FS_LOCAL_PORT"
      say ""
      if $REUSE_ONLY; then
        note "(reuse-only: assuming your file-lane ingress rule already exists)"
        local h; h=$(ask_url "The file-lane web address (blank to skip the file lane)" "https://files.example.com" 1) || die "$NO_ANSWER"
        [ -n "$h" ] && FS_URL="$h" || { note "No address — leaving the file lane out of the QR."; FS_CRED=""; }
      elif print_and_wait "Same dance as before: ingress rule + 'tunnel route dns' + restart cloudflared." \
        "cloudflared tunnel route dns <your-tunnel> files.YOURDOMAIN"; then
        local h2; h2=$(ask_url "The file-lane web address you configured (blank to skip the file lane)" "https://files.example.com" 1) || die "$NO_ANSWER"
        [ -n "$h2" ] && FS_URL="$h2" || { note "No address — leaving the file lane out of the QR."; FS_CRED=""; }
      else FS_CRED=""; fi
      ;;
    public|selfsigned)
      say ""
      say "  Your gateway's web server needs a second route for the file lane → 127.0.0.1:$FS_LOCAL_PORT"
      say "  (a second server block, a subdomain, or another port)."
      note "Give it the same reach as the gateway (both public, or both private) — attachments follow this address."
      local h; h=$(ask_url "The https:// web address that reaches it (blank to skip the file lane)" "https://files.example.com" 1) || die "$NO_ANSWER"
      if [ -n "$h" ]; then
        FS_URL="$h"
        # If self-signed AND a different host than the gateway, pin the file host
        # too — behind the same broken-cert date gate as the gateway pin.
        if [ "$TRANSPORT" = "selfsigned" ]; then
          local g_host="${GW_URL#https://}"; g_host="${g_host%%/*}"
          local f_host="${FS_URL#https://}"; f_host="${f_host%%/*}"
          if [ "$f_host" != "$g_host" ]; then
            if $DRY_RUN; then note "(dry-run: would compute the file host's SPKI fingerprint from $FS_URL)"
            else
              local fs_datep; fs_datep=$(cert_leaf_date_problem "$FS_URL")
              if [ "$fs_datep" = "notyet" ]; then
                warn "The file host's certificate is not valid yet (check its clock) — leaving the file lane out. Fix it and re-run."
                FS_CRED=""; FS_URL=""
              elif [ -n "$fs_datep" ]; then
                warn "The file host's certificate has expired (or could not be read) — leaving the file lane out. Fix it and re-run."
                FS_CRED=""; FS_URL=""
              else
                FS_CERT_FP=$(compute_spki_hex "$FS_URL") || { warn "Could not pin the file host's cert — leaving file lane out."; FS_CRED=""; FS_URL=""; }
                [ -n "$FS_CERT_FP" ] && ok "File-lane fingerprint computed (rides in the QR)."
              fi
            fi
          fi
        fi
      else note "Skipped the file lane (Conduck still works — inline-only attachments)."; FS_CRED=""; fi
      ;;
  esac
}
