# ------------------------------------------------------------- --show-code fast path --
# Re-emit a SAVED profile's QR while skipping the SETUP questions and making ZERO
# configuration changes. It is NOT question-free: it may still ask you to pick a profile
# (when several are saved), re-enter a custom gateway's token, or confirm a gateway-only
# code. "No changes" means no serve/funnel/config mutations — verification's real
# requests (incl. the file-lane PUT/GET/DELETE probe) still run, on purpose. The whole
# path reconstructs state from $STATE_DIR/profile-*.json (non-secret), re-derives secrets
# from their canonical homes, refuses on any drift from the saved expectations, then
# hands off to the UNCHANGED verify_all + emit_payload.

# The https port a URL reaches on (443 when the URL carries none). Authority parse
# matches url_host_lc/show_qr_is_https_host (ends at the first /, ? or #).
url_https_port() { # url_https_port <https-url>
  local hp="${1#https://}"; hp="${hp%%[/?#]*}"
  case "$hp" in
    \[*\]:*) printf '%s' "${hp##*\]:}" ;;   # bracketed IPv6 with an explicit port
    \[*\])   printf '443' ;;                 # bracketed IPv6, no port (inner colons aren't a port)
    *:*)     printf '%s' "${hp##*:}" ;;
    *)       printf '443' ;;
  esac
}

# The host part of an https URL, lowercased. Same authority parse as
# show_qr_is_https_host (ends at the first /, ? or #; strips a trailing :port) so the
# two always agree. Empty output when the URL isn't https://. Used to prove a profile
# URL names THIS tailnet machine.
url_host_lc() { # url_host_lc <https-url>
  case "$1" in https://*) ;; *) return 0 ;; esac
  local a="${1#https://}"; a="${a%%[/?#]*}"
  local h
  case "$a" in
    \[*\]*) h="${a%%\]*}]" ;;               # bracketed IPv6 → keep [..], drop any trailing :port
    *:*)    h="${a%:*}" ;;                   # host:port
    *)      h="$a" ;;
  esac
  printf '%s' "$h" | tr '[:upper:]' '[:lower:]'
}

# What a saved setup IS, in the lines an operator needs to recognise it: the name
# the app shows, the address the code will point at, and how that address is
# reached. Printed for a lone profile as well as for a list — auto-selecting the
# only saved setup is right, showing it anyway is the other half of right. The very
# next thing --show-code does on a custom gateway is ask for a key, and
# being asked for a password before being told what it unlocks is how somebody
# pastes the key to a different gateway.
show_qr_describe_saved_setup() { # show_qr_describe_saved_setup <profile-file>
  local pf="$1" k n u t
  k=$(json_get "$pf" "gateway.kind"); n=$(json_get "$pf" "gateway.name")
  u=$(json_get "$pf" "gateway.url");  t=$(json_get "$pf" "gateway.transport")
  say "    ${k:-?}${n:+ ($n)} — ${u:-?}"
  [ -n "$t" ] && note "reached over: $t"
  return 0
}

# A Cloudflare quick tunnel's hostname is REASSIGNED every time the tunnel
# restarts — a reboot, a crash, a Ctrl-C in its terminal — and this tool's most
# common real-world failure is a saved setup that was correct last night and points
# at a hostname that no longer resolves this morning. That is also the most likely
# reason somebody typed --show-code at all.
#
# Said HERE, before the live check, because from there on a dead quick tunnel looks
# exactly like a broken gateway: the same connection error, none of the cause.
# 30-exposure's own predicate on purpose — a second copy of a host-matching rule is
# how the two drift apart.
show_qr_warn_quick_tunnel() { # show_qr_warn_quick_tunnel <profile-file>
  local pf="$1" u f hit=false
  u=$(json_get "$pf" "gateway.url"); f=$(json_get "$pf" "fileServer.url")
  is_quick_tunnel_url "$u" && hit=true
  [ -n "$f" ] && is_quick_tunnel_url "$f" && hit=true
  $hit || return 0
  say ""
  warn "This saved setup rides a Cloudflare QUICK TUNNEL, and that hostname is reassigned"
  warn "every time the tunnel restarts. If the app stopped connecting, check that first:"
  warn "the address saved here is the one this machine last published, not necessarily the"
  warn "one the tunnel answers on now — and the new one appears in no file I can read."
  note "Keep that tunnel running, or move to a named tunnel (re-run setup) for an address"
  note "that survives a restart."
  return 0
}

# Discover saved profiles and set PROFILE_FILE. None → friendly die; one → use
# it (and say which); several → numbered pick.
# Dies directly (not via $()) so a "no profile" die halts the whole script.
PROFILE_FILE=""
show_qr_pick_profile() {
  local pf; local cand=() rejected=0 reason=""
  for pf in "$STATE_DIR"/profile-*.json; do
    [ -e "$pf" ] || continue          # no matches → the literal glob; skip it
    # Use the exact validator the loader uses. Corrupt/partial files are neither
    # listed nor selectable, so a menu option can never lead straight to a
    # validation dead end.
    if show_qr_validate_profile "$pf"; then
      cand+=("$pf")
    else
      # Keep the FIRST rejection's reason. "Nothing usable" and "nothing at all"
      # need opposite advice: re-running setup rewrites profile-<id>.json, so
      # prescribing it for a file this version merely cannot PARSE (one a newer
      # conduck-connect wrote) destroys the very state the operator came to reuse.
      rejected=$((rejected+1))
      [ -n "$reason" ] || reason="$PROFILE_VALIDATION_ERROR"
    fi
  done
  if [ ${#cand[@]} -eq 0 ]; then
    [ "$rejected" = "1" ] && die "There IS a saved setup code on this machine, and this version ($VERSION) can't use it. $reason"
    [ "$rejected" = "0" ] || die "There are $rejected saved setup codes on this machine, and this version ($VERSION) can't use any of them. The first one says: $reason"
    die "No usable saved setup code on this machine yet — run setup once (bash conduck-connect.sh --setup) to pair and save one. From then on, --show-code re-shows it, skipping the setup questions (it may still ask you to pick one, re-enter a custom gateway's key, or confirm a gateway-only code; live verification still runs)."
  fi
  local k
  if [ ${#cand[@]} -eq 1 ]; then
    PROFILE_FILE="${cand[0]}"
    # Auto-selected, and shown anyway: there is nothing to decide, but there is
    # something to recognise before the questions that follow.
    say ""
    say "  ${BOLD}The one saved setup on this machine:${RESET}"
    show_qr_describe_saved_setup "$PROFILE_FILE"
    return 0
  fi
  say ""
  say "  ${BOLD}Saved setups on this machine:${RESET}"
  local i=1 n u
  for pf in "${cand[@]}"; do
    k=$(json_get "$pf" "gateway.kind"); n=$(json_get "$pf" "gateway.name"); u=$(json_get "$pf" "gateway.url")
    printf '    %d) %s%s — %s\n' "$i" "${k:-?}" "${n:+ ($n)}" "${u:-?}"
    i=$((i+1))
  done
  local pick
  while true; do
    # {1,3} length-bounds the input so the numeric compare below can't overflow bash 3.2's intmax.
    # prompt_into, not $(…): q at this prompt has to stop the RUN, and a quit_run
    # inside a command substitution stops only the subshell that ran the prompt.
    prompt_into pick require_choice "Which one? Choose 1-$((i-1))" '^[0-9]{1,3}$' "nav.saved_profile"
    { [ "$pick" -ge 1 ] && [ "$pick" -le $((i-1)) ]; } 2>/dev/null && break
    warn "Please enter a number between 1 and $((i-1))."
  done
  PROFILE_FILE="${cand[$((pick-1))]}"
}

# --show-code profile-validation helpers (bash 3.2-safe, secret-free — they inspect only
# routing facts, never tokens). Used by show_qr_load_profile to reject a hand-edited or
# corrupted profile up front, before any secret recovery or live probe.
show_qr_is_https_host() { # show_qr_is_https_host <url> -> 0 iff https:// + sane authority
  # Real authority parse — a bare `%%/*` host grab let https://?query, https://#frag
  # and https://user:pass@host slip through. Authority ends at the first /, ? or #;
  # userinfo is rejected (the wizard never emits it); an explicit :port must be a
  # real port; the host may contain only [A-Za-z0-9.-], OR be a bracketed IPv6 literal.
  case "$1" in https://*) ;; *) return 1 ;; esac
  local a="${1#https://}"; a="${a%%[/?#]*}"
  case "$a" in *@*) return 1 ;; esac
  # A bracketed IPv6 literal ([hex:.]) with an optional :port is a valid authority too.
  local ip
  case "$a" in
    \[*\]:*) show_qr_is_port "${a##*\]:}" || return 1; ip="${a#\[}"; ip="${ip%%\]*}"
             case "$ip" in ''|*[!0-9A-Fa-f:.]*) return 1 ;; *) return 0 ;; esac ;;
    \[*\])   ip="${a#\[}"; ip="${ip%\]}"
             case "$ip" in ''|*[!0-9A-Fa-f:.]*) return 1 ;; *) return 0 ;; esac ;;
    \[*)     return 1 ;;   # opened a bracket but no valid close → reject
  esac
  local h="$a"
  case "$a" in *:*) show_qr_is_port "${a##*:}" || return 1; h="${a%:*}" ;; esac
  [ -n "$h" ] || return 1
  case "$h" in *[!A-Za-z0-9.-]*) return 1 ;; esac
  return 0
}
show_qr_is_port() { # show_qr_is_port <str> -> 0 if a decimal in 1..65535
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 5 ] || return 1        # length-bound so bash 3.2's intmax can't overflow
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}
show_qr_resolve_file_reach() { # saved file reach (possibly empty), gateway reach
  if [ -n "$1" ]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}

# One secret-free profile validator shared by the welcome menu, profile picker,
# and --show-code loader. A partial schema-1 file must never be advertised and
# then rejected only after the user chooses it.
PROFILE_VALIDATION_ERROR=""
show_qr_profile_invalid() { PROFILE_VALIDATION_ERROR="$1"; return 1; }

# The same rejection, told to somebody who can act on it: which file, which field,
# and that repairing the one line is an alternative to rebuilding the whole file.
#
# "Re-run setup" as the sole advice is actively harmful here, and it is the advice
# every one of these branches used to give: setup REWRITES profile-<id>.json, so it
# destroys the state the operator opened this command to recover — over one wrong
# character the validator can point straight at. The schemaVersion branch already
# knew this (it says update the script first) and this makes the rest agree.
#
# The offer can be made without qualification because write_profile records routing
# facts only: no token, no file-lane credential, nothing that must not be opened in
# an editor. Setup stays in the message as the other road, with what it costs said
# out loud.
#
# One line, no column-0 `}`, exactly like the setter above it. The host-environment
# suite lifts these helpers out of this file with a `sed` range that ends at the
# first `^}`, and that range has to keep reaching show_qr_validate_profile below —
# a multi-line body here silently truncates it.
# show_qr_profile_field_invalid <file> <field-phrase> <what is wrong>
# "holds no secret" is true of every profile this tool writes and false of one it can
# read: a hand-edited address of the form https://user:pass@host puts a password in the
# file, which is exactly why the inventory redacts userinfo before printing a URL. An
# invalid gateway.url is the most likely way that profile reaches this message, so the
# one case that most often reads the reassurance is the one it would be wrong about.
# The claim is therefore scoped rather than dropped — a reader deciding whether it is
# safe to open the file in an editor still gets an answer.
show_qr_profile_field_invalid() { show_qr_profile_invalid "$3 $2. The file is $1 — you can correct that line in a text editor (it is plain JSON, and holds no secret unless an address in it carries a password), or re-run setup (bash conduck-connect.sh --setup) to rebuild it, which REPLACES everything in it."; }
show_qr_validate_profile() { # show_qr_validate_profile <profile-file>
  local pf="$1" sv kind id name auth transport reach url port
  local gateway_type file_type fsurl fsreach fsport
  PROFILE_VALIDATION_ERROR=""
  [ -f "$pf" ] || {
    show_qr_profile_invalid "That saved setup is missing — the file $pf is not there. Run setup again (bash conduck-connect.sh --setup) to recreate it."
    return 1
  }

  sv=$(json_get "$pf" "schemaVersion")
  if [ "$sv" != "1" ]; then
    show_qr_profile_invalid "That saved setup uses schema version '${sv:-unknown}', which this script ($VERSION) doesn't understand — a newer conduck-connect wrote $pf. Update this script, then try again (or run setup once to rewrite it, which REPLACES everything in that file)."
    return 1
  fi
  gateway_type=$(json_type "$pf" "gateway")
  file_type=$(json_type "$pf" "fileServer")
  if [ "$gateway_type" != "object" ]; then
    show_qr_profile_field_invalid "$pf" 'The field is "gateway", which has to be a JSON object' \
      "That saved setup has no usable gateway object."
    return 1
  fi
  case "$file_type" in
    null|object) ;;
    *)
      show_qr_profile_field_invalid "$pf" 'The field is "fileServer"' \
        "That saved setup's fileServer value has to be either a JSON object or null."
      return 1 ;;
  esac

  kind=$(json_get "$pf" "gateway.kind")
  id=$(json_get "$pf" "gateway.id")
  name=$(json_get "$pf" "gateway.name")
  auth=$(json_get "$pf" "gateway.auth")
  transport=$(json_get "$pf" "gateway.transport")
  reach=$(json_get "$pf" "gateway.reach")
  url=$(json_get "$pf" "gateway.url")
  port=$(json_get "$pf" "gateway.localPort")

  # Named one by one rather than as a set: the operator is being sent to a text
  # editor, and "one of these six is empty" is a search, not an address.
  local missing=""
  [ -n "$kind" ]      || missing="$missing gateway.kind"
  [ -n "$id" ]        || missing="$missing gateway.id"
  [ -n "$url" ]       || missing="$missing gateway.url"
  [ -n "$transport" ] || missing="$missing gateway.transport"
  [ -n "$reach" ]     || missing="$missing gateway.reach"
  [ -n "$auth" ]      || missing="$missing gateway.auth"
  if [ -n "$missing" ]; then
    show_qr_profile_field_invalid "$pf" "The missing fields are${missing}" \
      "That saved setup has no value for something it cannot be used without."
    return 1
  fi
  case "$kind" in
    openclaw|hermes|custom) ;;
    *)
      show_qr_profile_field_invalid "$pf" 'The field is "gateway.kind"' \
        "That saved setup names an unknown gateway kind '$kind' — this tool pairs only openclaw, hermes, or custom gateways."
      return 1 ;;
  esac
  case "$id" in
    *[!a-z0-9-]*|'')
      show_qr_profile_field_invalid "$pf" 'The field is "gateway.id", which may hold only lowercase letters, digits and hyphens' \
        "That saved setup's gateway id isn't a safe lowercase id."
      return 1 ;;
  esac
  case "$kind:$id" in
    openclaw:openclaw|hermes:hermes|custom:custom-*) ;;
    *)
      show_qr_profile_field_invalid "$pf" 'The fields are "gateway.kind" and "gateway.id" — openclaw pairs with the id openclaw, hermes with hermes, and custom with an id starting custom-' \
        "That saved setup's gateway kind and id don't agree."
      return 1 ;;
  esac
  if [ "$kind" = "custom" ] && [ -z "$(printf '%s' "$name" | tr -d '[:space:]')" ]; then
    show_qr_profile_field_invalid "$pf" 'The field is "gateway.name"' \
      "That saved setup is a custom gateway but stores no name (or only whitespace)."
    return 1
  fi
  case "$auth" in
    bearer|none) ;;
    *)
      show_qr_profile_field_invalid "$pf" 'The field is "gateway.auth", which must be "bearer" or "none"' \
        "That saved setup has an unknown auth mode '$auth'."
      return 1 ;;
  esac
  show_qr_is_https_host "$url" || {
    show_qr_profile_field_invalid "$pf" 'The field is "gateway.url"' \
      "That saved setup's gateway URL isn't a valid https:// address with a host."
    return 1
  }
  case "$transport" in
    tailscale|funnel|cloudflare|public) ;;
    *)
      show_qr_profile_field_invalid "$pf" 'The field is "gateway.transport", which must be tailscale, funnel, cloudflare or public' \
        "That saved setup has an unrecognized transport '$transport'."
      return 1 ;;
  esac
  case "$reach" in
    private|public) ;;
    *)
      show_qr_profile_field_invalid "$pf" 'The field is "gateway.reach", which must be private or public' \
        "That saved setup has an unrecognized gateway reach '$reach'."
      return 1 ;;
  esac
  if { [ "$transport" = "tailscale" ] && [ "$reach" != "private" ]; } ||
     { case "$transport" in funnel|cloudflare) true ;; *) false ;; esac &&
       [ "$reach" != "public" ]; }; then
    show_qr_profile_field_invalid "$pf" 'The fields are "gateway.transport" and "gateway.reach" — tailscale is private; funnel and cloudflare are public' \
      "That saved setup's gateway transport and reach don't agree."
    return 1
  fi
  if [ -n "$port" ] && ! show_qr_is_port "$port"; then
    show_qr_profile_field_invalid "$pf" 'The field is "gateway.localPort"' \
      "That saved setup's gateway local port isn't a number in 1-65535."
    return 1
  fi
  # A Tailscale mapping is compared with its loopback target. OpenClaw/Hermes
  # can re-derive a missing localPort from their canonical config (legacy
  # schema-1 profiles rely on that), but a custom gateway has no such source.
  if [ "$kind" = "custom" ] && [ -z "$port" ]; then
    case "$transport" in
      tailscale|funnel)
        show_qr_profile_field_invalid "$pf" 'The missing field is "gateway.localPort" — the port on 127.0.0.1 that Tailscale forwards to' \
          "That saved custom gateway uses Tailscale but stores no local port, so its live mapping cannot be verified."
        return 1 ;;
    esac
  fi

  fsurl=$(json_get "$pf" "fileServer.url")
  fsreach=$(json_get "$pf" "fileServer.reach")
  fsport=$(json_get "$pf" "fileServer.localPort")
  if [ "$file_type" = "object" ] && [ -z "$fsurl" ]; then
    show_qr_profile_field_invalid "$pf" 'The missing field is "fileServer.url" (setting "fileServer" to null drops file transfer entirely)' \
      "That saved setup's file-server object has no URL."
    return 1
  fi
  if [ -n "$fsurl" ] && ! show_qr_is_https_host "$fsurl"; then
    show_qr_profile_field_invalid "$pf" 'The field is "fileServer.url"' \
      "That saved setup's file-server URL isn't a valid https:// address with a host."
    return 1
  fi
  if [ -n "$fsreach" ]; then
    case "$fsreach" in
      private|public) ;;
      *)
        show_qr_profile_field_invalid "$pf" 'The field is "fileServer.reach", which must be private or public' \
          "That saved setup has an unrecognized file-server reach '$fsreach'."
        return 1 ;;
    esac
  fi
  if [ -n "$fsport" ] && ! show_qr_is_port "$fsport"; then
    show_qr_profile_field_invalid "$pf" 'The field is "fileServer.localPort"' \
      "That saved setup's file-server local port isn't a number in 1-65535."
    return 1
  fi
  return 0
}

# Is <host-lc> one of the hostnames THIS machine currently serves (TS_HOSTS)? Compares
# case-insensitively and FAILS CLOSED when TS_HOSTS is empty (host state unknown).
ts_host_known() { # ts_host_known <host> — lowercases BOTH sides before comparing
  local want h
  want=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  [ ${#TS_HOSTS[@]} -gt 0 ] || return 1
  for h in "${TS_HOSTS[@]}"; do
    [ "$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]')" = "$want" ] && return 0
  done
  return 1
}

# Reconstruct the GW_* vars from PROFILE_FILE. Health path + (missing) local port are
# re-derived exactly as the wizard does, never trusted blindly from the file.
show_qr_load_profile() {
  show_qr_validate_profile "$PROFILE_FILE" || die "$PROFILE_VALIDATION_ERROR"
  GW_KIND=$(json_get "$PROFILE_FILE" "gateway.kind")
  GW_ID=$(json_get "$PROFILE_FILE" "gateway.id")
  GW_NAME=$(json_get "$PROFILE_FILE" "gateway.name")
  GW_AUTH=$(json_get "$PROFILE_FILE" "gateway.auth")
  TRANSPORT=$(json_get "$PROFILE_FILE" "gateway.transport")
  SCOPE=$(json_get "$PROFILE_FILE" "gateway.reach")
  GW_URL=$(json_get "$PROFILE_FILE" "gateway.url")
  GW_LOCAL_PORT=$(json_get "$PROFILE_FILE" "gateway.localPort")
  GW_MODEL=$(json_get "$PROFILE_FILE" "gateway.model")

  # Health path is derived from kind (not stored), exactly as the wizard sets it.
  case "$GW_KIND" in
    openclaw) GW_HEALTH_PATH="/healthz" ;;
    hermes)   GW_HEALTH_PATH="/v1/health" ;;
    *)        GW_HEALTH_PATH="" ;;
  esac
  # Local port: prefer the profile; else re-detect from the gateway config exactly as the
  # wizard does (same precedence + gateway.port validation), so the drift check never
  # false-alarms on a gateway.port-configured install.
  if [ -z "$GW_LOCAL_PORT" ]; then
    case "$GW_KIND" in
      openclaw)
        GW_LOCAL_PORT=$(openclaw_local_port)
        ;;
      hermes)
        GW_LOCAL_PORT=$(hermes_api_server_port)
        ;;
    esac
  fi
  ok "Using saved profile: ${GW_KIND}${GW_NAME:+ ($GW_NAME)} → $GW_URL"
}

# Re-derive the gateway secret from its canonical home — exactly like the wizard.
# FAIL CLOSED: a bearer profile whose token can't be recovered DIES; never emit keyless.
show_qr_recover_gateway_secret() {
  case "$GW_AUTH" in
    none)   GW_TOKEN=""; note "This gateway has no token (auth=none in the saved profile)."; return 0 ;;
    bearer) ;;
    *)      die "The saved profile has an unknown auth mode '$GW_AUTH' — re-run setup (bash conduck-connect.sh --setup) to refresh it." ;;
  esac
  case "$GW_KIND" in
    openclaw)
      # Same mode-aware resolution as the wizard: honours auth.mode, reads the right key
      # (token vs password), and NEVER embeds an indirect "${ENV}"/SecretRef value — it
      # prompts for the real secret instead (the --show-code "may still ask" contract).
      openclaw_resolve_secret "showqr"
      ;;
    hermes)
      local envf="$HOME/.hermes/.env"
      GW_TOKEN=$(env_get "$envf" "API_SERVER_KEY")
      [ -n "$GW_TOKEN" ] || die "No API_SERVER_KEY in $envf — refusing to emit a keyless code (auth is explicit). Fix Hermes, then re-run."
      ok "Re-read API_SERVER_KEY from ~/.hermes/.env (not shown)."
      ;;
    *)
      # Custom gateway: nothing on disk to read (by design — this tool never stores keys).
      say ""
      note "Custom gateways have no config file I can read, and this tool deliberately never stores your key."
      # prompt_into so q here stops the RUN. Inside $(…) a quit_run kills only the
      # subshell, and the parent then reads the empty answer as "no key given" and
      # dies with the wrong reason. The action-id gives `i` the key panel — the one
      # shared by all six hidden-key prompts in the tool.
      prompt_into GW_TOKEN ask_secret "Paste the gateway key again — what the gateway checks on each request (hidden)" \
        "stop; this saved setup requires a key" "gateway.token"
      [ -n "$GW_TOKEN" ] || die "A key is required (this saved setup says auth=bearer). Re-run when you have it."
      ;;
  esac
}

# Recover the file-lane password from disk when the profile carries a lane. If it
# can't be recovered, WARN loudly and (with an explicit confirm) continue gateway-only.
show_qr_recover_file_lane() {
  local fsurl; fsurl=$(json_get "$PROFILE_FILE" "fileServer.url")
  [ -n "$fsurl" ] || { FS_URL=""; FS_CRED=""; return 0; }   # profile has no file lane
  local saved_port saved_folder
  saved_port=$(json_get "$PROFILE_FILE" "fileServer.localPort")
  saved_folder=$(json_get "$PROFILE_FILE" "fileServer.folder")
  # existing_fs_config recovers the password (state password file / env file / unit) and
  # sets FS_CRED + FS_LOCAL_PORT + FS_FOLDER; keep the profile's URL/port authoritative.
  if existing_fs_config && [ -n "$FS_CRED" ]; then
    FS_URL="$fsurl"
    [ -n "$saved_port" ] && FS_LOCAL_PORT="$saved_port"
    if [ -n "$saved_folder" ] && [ "$saved_folder" != "$FS_FOLDER" ]; then
      note "The saved profile's informational folder differs from the live service definition; using the structurally parsed live folder."
    fi
    ok "Recovered the file-lane password from this machine (not shown)."
    if $FS_CRED_LEGACY_ARGV; then
      note "Heads-up: that file-server unit keeps its password on the command line (visible via 'ps'). The QR is still correct."
    fi
  else
    warn "The saved profile includes a file lane at $fsurl, but I can't recover its password on this machine"
    warn "(its 0600 password file and the file-server unit are both gone). Without it, the QR can't carry the file password."
    if confirm "  Re-show the code for the GATEWAY ONLY (chat everywhere; no attachments)?" "verification.gateway_only"; then
      note "Leaving the file lane out of this QR — re-run setup (bash conduck-connect.sh --setup) to rebuild it."
      FS_URL=""; FS_CRED=""; FS_FOLDER=""
    else
      die "Stopped — re-run setup (bash conduck-connect.sh --setup) to rebuild the file lane and refresh the profile."
    fi
  fi
}

# Compare ONE (host, https-port) pair's live Tailscale mapping to what the profile
# expects, via TS_MAPS. HOST-QUALIFIED on purpose: a port-only lookup would accept a
# correct-looking mapping that lives on a DIFFERENT tailnet hostname of this machine
# (stale profile naming beta.ts.net passing on alpha.ts.net's mapping). Used only by
# the show-qr path; the wizard's ts_target_for_port consumers are untouched.
# Prints a SECRET-FREE diff and returns non-zero on mismatch. Reads only.
show_qr_assert_mapping() { # show_qr_assert_mapping <host-lc> <https-port> <local-port> <want-verb> <label>
  local host="$1" port="$2" localp="$3" wantverb="$4" label="$5"
  host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')   # TS_MAPS hosts are lowercased; match that
  local wantproxy="http://127.0.0.1:$localp"
  local m rest mhost mport verb proxy matched=false
  for m in ${TS_MAPS[@]+"${TS_MAPS[@]}"}; do
    mhost="${m%%$'\t'*}"; rest="${m#*$'\t'}"
    mport="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    [ "$mhost" = "$host" ] && [ "$mport" = "$port" ] || continue
    verb="${rest%%$'\t'*}"; proxy="${rest#*$'\t'}"
    matched=true; break
  done
  if ! $matched; then
    bad "The $label is no longer exposed at $host:$port."
    note "expected: $host:$port → $wantproxy ($wantverb)"
    note "live:     no live mapping for $host:$port"
    return 1
  fi
  if [ "$proxy" != "$wantproxy" ] || [ "$verb" != "$wantverb" ]; then
    bad "The $label's exposure changed since this profile was saved."
    note "expected: $host:$port → $wantproxy ($wantverb)"
    note "live:     $host:$port → ${proxy:-<none>} (${verb:-<none>})"
    return 1
  fi
  ok "$label exposure still matches the saved profile ($host:$port, $wantverb)."
  return 0
}

# The mismatch gate: refuse (secret-free) when the machine's live state no longer
# matches the saved profile. READS ONLY — no serve/funnel/config mutations. Runs
# BEFORE verify_all so drift reads as "your setup changed", not a generic failure.
show_qr_stale() {
  die "Your setup changed since this profile was saved — re-run setup (bash conduck-connect.sh --setup) to reconcile and refresh it."
}
show_qr_check_live() {
  head_ "Checking your saved setup still matches this machine"
  case "$TRANSPORT" in
    tailscale|funnel)
      ts_targets
      $TS_STATE_KNOWN || die "Couldn't read 'tailscale serve status --json', so I can't confirm your saved exposure still matches — refusing to show a possibly-wrong code. Check 'tailscale serve status' (is Tailscale up?), then re-run. To reconcile from scratch: bash conduck-connect.sh."
      local want_verb="serve"; [ "$SCOPE" = "public" ] && want_verb="funnel"
      # HOST gate first for the clearer "names another machine" diagnostic; the
      # host-qualified show_qr_assert_mapping below closes the cross-host hole
      # behind it. Fails closed when TS_HOSTS is empty (ts_host_known non-zero).
      local gw_host; gw_host=$(url_host_lc "$GW_URL")
      if ! ts_host_known "$gw_host"; then
        bad "The gateway URL points at a tailnet host this machine no longer serves."
        note "expected host (from profile): ${gw_host:-<none>}"
        note "live tailscale hosts:         ${TS_HOSTS[*]:-<none>}"
        show_qr_stale
      fi
      show_qr_assert_mapping "$gw_host" "$(url_https_port "$GW_URL")" "$GW_LOCAL_PORT" "$want_verb" "gateway" || show_qr_stale
      if [ -n "$FS_URL" ] && [ -n "$FS_CRED" ]; then
        local fs_host; fs_host=$(url_host_lc "$FS_URL")
        if ! ts_host_known "$fs_host"; then
          bad "The file lane's URL points at a tailnet host this machine no longer serves."
          note "expected host (from profile): ${fs_host:-<none>}"
          note "live tailscale hosts:         ${TS_HOSTS[*]:-<none>}"
          show_qr_stale
        fi
        # The lane can legitimately ride a DIFFERENT reach than the gateway (a mixed-scope
        # setup the wizard allows). Assert the LANE's own verb from its saved reach; fall
        # back to the gateway's scope only for older profiles with no fileServer.reach.
        local fs_reach
        fs_reach=$(show_qr_resolve_file_reach \
          "$(json_get "$PROFILE_FILE" "fileServer.reach")" "$SCOPE")
        local fs_verb="serve"; [ "$fs_reach" = "public" ] && fs_verb="funnel"
        show_qr_assert_mapping "$fs_host" "$(url_https_port "$FS_URL")" "$FS_LOCAL_PORT" "$fs_verb" "file lane" || show_qr_stale
      fi
      ;;
    cloudflare|public)
      note "This transport has no local exposure to introspect — reachability is proven by the real requests below."
      ;;
    *)
      die "The saved profile has an unrecognized transport '$TRANSPORT' — re-run setup (bash conduck-connect.sh --setup) to refresh it."
      ;;
  esac
}

# A profile is written once; the gateway it describes keeps changing afterwards. A
# Hermes whose API-server scope was memory-free at pairing time can drift back —
# an upgrade that rewrites config.yaml, another tool appending a toolset, a hand
# edit — and neither the saved profile nor the live exposure checks above would
# notice: a remembering gateway passes every one of them. So the scope is
# re-classified before every successful re-emission, not only at setup.
#
# --show-code forces REUSE_ONLY, so this reports the finding and the by-hand fix
# and returns 0 without opening config.yaml for writing. Offering the edit stays
# with the wizard; a command whose whole promise is "changes no configuration"
# must not grow a mutation prompt.
show_qr_recall_scope() {
  hermes_recall_scope_step || true
}

# Orchestrate the --show-code path: pick → load → secrets → live-match gate, then the
# UNCHANGED verify_all + emit_payload. No configuration/exposure mutates
# (REUSE_ONLY is forced on), so APPLIED/FS_APPLIED stay empty. Verification can
# still write and delete one small probe on an already-configured file lane.
# The recall report sits after the drift gate and before verification: a stale
# profile dies above without collecting an irrelevant warning it can't act on, and
# verify_all's output then separates the finding from the code itself rather than
# interrupting the operator at the moment of payoff.
run_show_qr() {
  head_ "Re-show a saved setup code — skips setup and changes no configuration"
  # The opening block, before the first question: what this command is for (pairing
  # a SECOND device is the reason it exists, and nothing on this screen used to say
  # so), what it changes, and why a command that promises to ask nothing may still
  # ask for a key.
  explain_show_code
  show_qr_pick_profile
  # Said before the token prompt and long before the live check, because from the
  # live check onwards a reassigned quick-tunnel hostname is indistinguishable from
  # a gateway that stopped working.
  show_qr_warn_quick_tunnel "$PROFILE_FILE"
  # This path reads $STATE_DIR exactly the way the wizard does — it parses the
  # saved profile and re-derives the gateway token and the file-lane credential
  # from it — so it owes the same exposure report the wizard gives. It runs AFTER
  # the picker, where a profile file has just proven the directory exists: the
  # `mkdir -p` inside is then a provable no-op, so a command whose promise is
  # "changes no configuration" still creates nothing. It runs BEFORE any secret is
  # recovered, so an operator learns the folder is open before the run reads a
  # password out of it.
  ensure_state_dir
  show_qr_load_profile
  show_qr_recover_gateway_secret
  show_qr_recover_file_lane
  show_qr_check_live
  show_qr_recall_scope
  verify_all
  emit_payload
  show_qr_next_steps
}

# The last screen of --show-code, which used to be a total dead end: it named no
# other command, and never said the thing it is FOR — that scanning this same code
# on a second phone, tablet or Mac is how a device gets added. A user who does not
# know that runs the whole wizard again for their iPad.
#
# The "not connecting?" half deliberately does NOT reprint a --check-server line:
# emit_payload above prints exactly that command, with this same address, on every
# successful emission. Two copies of one command on one screen is how an operator
# starts skimming the screen.
show_qr_next_steps() {
  say ""
  say "  ${BOLD}Pairing another device${RESET}"
  say "  Scan this same code, or paste it, on every device you want connected — a second"
  say "  phone, an iPad, a Mac. There is no per-device setup and nothing else to run."
  note "They share one key, so rotating it at the gateway cuts off all of them together."
  say ""
  say "  ${BOLD}Still not connecting?${RESET} The --check-server line above grades exactly the route"
  say "  this code points at, and changes nothing on your machine or your server."
}
