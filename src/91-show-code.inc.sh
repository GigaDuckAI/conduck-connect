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

# Discover saved profiles and set PROFILE_FILE. None → friendly die; one → use
# it; several → numbered pick via require_choice.
# Dies directly (not via $()) so a "no profile" die halts the whole script.
PROFILE_FILE=""
show_qr_pick_profile() {
  local pf; local cand=()
  for pf in "$STATE_DIR"/profile-*.json; do
    [ -e "$pf" ] || continue          # no matches → the literal glob; skip it
    # Use the exact validator the loader uses. Corrupt/partial files are neither
    # listed nor selectable, so a menu option can never lead straight to a
    # validation dead end.
    show_qr_validate_profile "$pf" && cand+=("$pf")
  done
  [ ${#cand[@]} -gt 0 ] || die "No usable saved pairing profile on this machine yet — run setup once (bash conduck-connect.sh --setup) to pair and save one. From then on, --show-code re-shows it, skipping the setup questions (it may still ask you to pick a profile, re-enter a custom gateway's token, or confirm a gateway-only code; live verification still runs)."
  local k
  if [ ${#cand[@]} -eq 1 ]; then PROFILE_FILE="${cand[0]}"; return 0; fi
  say ""
  say "  ${BOLD}Saved pairing profiles on this machine:${RESET}"
  local i=1 n u
  for pf in "${cand[@]}"; do
    k=$(json_get "$pf" "gateway.kind"); n=$(json_get "$pf" "gateway.name"); u=$(json_get "$pf" "gateway.url")
    printf '    %d) %s%s — %s\n' "$i" "${k:-?}" "${n:+ ($n)}" "${u:-?}"
    i=$((i+1))
  done
  local pick
  while true; do
    # {1,3} length-bounds the input so the numeric compare below can't overflow bash 3.2's intmax.
    pick=$(require_choice "Which profile? Choose 1-$((i-1))" '^[0-9]{1,3}$') || die "$NO_ANSWER"
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
show_qr_is_certfp() { # show_qr_is_certfp <str> -> 0 if 64 lowercase SPKI-sha256 hex chars
  case "$1" in *[!0-9a-f]*) return 1 ;; esac
  [ "${#1}" -eq 64 ]
}
show_qr_authority_key() { # normalized https authority: lowercase host + effective port
  printf '%s:%s' "$(url_host_lc "$1")" "$(url_https_port "$1")"
}
show_qr_resolve_file_reach() { # saved file reach (possibly empty), gateway reach
  if [ -n "$1" ]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}

# One secret-free profile validator shared by the welcome menu, profile picker,
# and --show-code loader. A partial schema-1 file must never be advertised and
# then rejected only after the user chooses it.
PROFILE_VALIDATION_ERROR=""
show_qr_profile_invalid() { PROFILE_VALIDATION_ERROR="$1"; return 1; }
show_qr_validate_profile() { # show_qr_validate_profile <profile-file>
  local pf="$1" sv kind id name auth transport reach url port certfp
  local gateway_type file_type fsurl fsreach fsport fsfp
  PROFILE_VALIDATION_ERROR=""
  [ -f "$pf" ] || {
    show_qr_profile_invalid "That saved profile is missing — run setup again (bash conduck-connect.sh --setup) to recreate it."
    return 1
  }

  sv=$(json_get "$pf" "schemaVersion")
  if [ "$sv" != "1" ]; then
    show_qr_profile_invalid "That saved profile uses schema version '${sv:-unknown}', which this script ($VERSION) doesn't understand — a newer conduck-connect wrote it. Update this script, then try again (or run setup once to rewrite it)."
    return 1
  fi
  gateway_type=$(json_type "$pf" "gateway")
  file_type=$(json_type "$pf" "fileServer")
  if [ "$gateway_type" != "object" ]; then
    show_qr_profile_invalid "That saved profile has no usable gateway object — re-run setup (bash conduck-connect.sh --setup) to refresh it."
    return 1
  fi
  case "$file_type" in
    null|object) ;;
    *)
      show_qr_profile_invalid "That saved profile's fileServer value must be either an object or null — re-run setup (bash conduck-connect.sh --setup) to refresh it."
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
  certfp=$(json_get "$pf" "gateway.certFP")

  if [ -z "$kind" ] || [ -z "$id" ] || [ -z "$url" ] || [ -z "$transport" ] ||
     [ -z "$reach" ] || [ -z "$auth" ]; then
    show_qr_profile_invalid "That saved profile is missing required fields (kind/id/url/transport/reach/auth) — re-run setup (bash conduck-connect.sh --setup) to refresh it."
    return 1
  fi
  case "$kind" in
    openclaw|hermes|custom) ;;
    *)
      show_qr_profile_invalid "That saved profile names an unknown gateway kind '$kind' — this tool pairs only openclaw, hermes, or custom gateways. Re-run setup (bash conduck-connect.sh --setup) to refresh it."
      return 1 ;;
  esac
  case "$id" in
    *[!a-z0-9-]*|'')
      show_qr_profile_invalid "That saved profile's gateway id isn't a safe lowercase id — re-run setup (bash conduck-connect.sh --setup) to refresh it."
      return 1 ;;
  esac
  case "$kind:$id" in
    openclaw:openclaw|hermes:hermes|custom:custom-*) ;;
    *)
      show_qr_profile_invalid "That saved profile's gateway kind and id don't agree — re-run setup (bash conduck-connect.sh --setup) to refresh it."
      return 1 ;;
  esac
  if [ "$kind" = "custom" ] && [ -z "$(printf '%s' "$name" | tr -d '[:space:]')" ]; then
    show_qr_profile_invalid "That saved profile is a custom gateway but stores no name (or only whitespace) — re-run setup (bash conduck-connect.sh --setup) to refresh it."
    return 1
  fi
  case "$auth" in
    bearer|none) ;;
    *)
      show_qr_profile_invalid "That saved profile has an unknown auth mode '$auth' — it must be 'bearer' or 'none'. Re-run setup (bash conduck-connect.sh --setup) to refresh it."
      return 1 ;;
  esac
  show_qr_is_https_host "$url" || {
    show_qr_profile_invalid "That saved profile's gateway URL isn't a valid https:// address with a host — re-run setup (bash conduck-connect.sh --setup) to refresh it."
    return 1
  }
  case "$transport" in
    tailscale|funnel|cloudflare|public|selfsigned) ;;
    *)
      show_qr_profile_invalid "That saved profile has an unrecognized transport '$transport' — re-run setup (bash conduck-connect.sh --setup) to refresh it."
      return 1 ;;
  esac
  case "$reach" in
    private|public) ;;
    *)
      show_qr_profile_invalid "That saved profile has an unrecognized gateway reach '$reach' — re-run setup (bash conduck-connect.sh --setup) to refresh it."
      return 1 ;;
  esac
  if { [ "$transport" = "tailscale" ] && [ "$reach" != "private" ]; } ||
     { case "$transport" in funnel|cloudflare) true ;; *) false ;; esac &&
       [ "$reach" != "public" ]; }; then
    show_qr_profile_invalid "That saved profile's gateway transport and reach don't agree — re-run setup (bash conduck-connect.sh --setup) to refresh it."
    return 1
  fi
  if [ "$transport" = "selfsigned" ] && [ -z "$certfp" ]; then
    show_qr_profile_invalid "That saved profile uses a self-signed certificate but stores no fingerprint — re-run setup (bash conduck-connect.sh --setup) to refresh it."
    return 1
  fi
  if [ "$transport" != "selfsigned" ] && [ -n "$certfp" ]; then
    show_qr_profile_invalid "That saved profile pins a certificate but doesn't use the self-signed path — the app would import a wrong pin. Re-run setup (bash conduck-connect.sh --setup) to refresh it."
    return 1
  fi
  if [ -n "$port" ] && ! show_qr_is_port "$port"; then
    show_qr_profile_invalid "That saved profile's gateway local port isn't a number in 1-65535 — re-run setup (bash conduck-connect.sh --setup) to refresh it."
    return 1
  fi
  # A Tailscale mapping is compared with its loopback target. OpenClaw/Hermes
  # can re-derive a missing localPort from their canonical config (legacy
  # schema-1 profiles rely on that), but a custom gateway has no such source.
  if [ "$kind" = "custom" ] && [ -z "$port" ]; then
    case "$transport" in
      tailscale|funnel)
        show_qr_profile_invalid "That saved custom gateway uses Tailscale but stores no local port, so its live mapping cannot be verified — re-run setup (bash conduck-connect.sh --setup) to refresh it."
        return 1 ;;
    esac
  fi
  if [ -n "$certfp" ] && ! show_qr_is_certfp "$certfp"; then
    show_qr_profile_invalid "That saved profile's gateway certificate fingerprint isn't a 64-character lowercase hex value — re-run setup (bash conduck-connect.sh --setup) to refresh it."
    return 1
  fi

  fsurl=$(json_get "$pf" "fileServer.url")
  fsreach=$(json_get "$pf" "fileServer.reach")
  fsport=$(json_get "$pf" "fileServer.localPort")
  fsfp=$(json_get "$pf" "fileServer.certFP")
  if [ "$file_type" = "object" ] && [ -z "$fsurl" ]; then
    show_qr_profile_invalid "That saved profile's file-server object is missing its URL — re-run setup (bash conduck-connect.sh --setup) to refresh it."
    return 1
  fi
  if [ -n "$fsurl" ] && ! show_qr_is_https_host "$fsurl"; then
    show_qr_profile_invalid "That saved profile's file-server URL isn't a valid https:// address with a host — re-run setup (bash conduck-connect.sh --setup) to refresh it."
    return 1
  fi
  if [ -n "$fsreach" ]; then
    case "$fsreach" in
      private|public) ;;
      *)
        show_qr_profile_invalid "That saved profile has an unrecognized file-server reach '$fsreach' — re-run setup (bash conduck-connect.sh --setup) to refresh it."
        return 1 ;;
    esac
  fi
  if [ -n "$fsport" ] && ! show_qr_is_port "$fsport"; then
    show_qr_profile_invalid "That saved profile's file-server local port isn't a number in 1-65535 — re-run setup (bash conduck-connect.sh --setup) to refresh it."
    return 1
  fi
  if [ -n "$fsfp" ] && ! show_qr_is_certfp "$fsfp"; then
    show_qr_profile_invalid "That saved profile's file-server certificate fingerprint isn't a 64-character lowercase hex value — re-run setup (bash conduck-connect.sh --setup) to refresh it."
    return 1
  fi
  if [ "$transport" != "selfsigned" ] && [ -n "$fsfp" ]; then
    show_qr_profile_invalid "That saved profile pins a file-server certificate but doesn't use the self-signed path — re-run setup (bash conduck-connect.sh --setup) to refresh it."
    return 1
  fi
  # The file lane may inherit the gateway pin only when both URLs reach the same
  # authority. A different host or port presents an independent certificate and
  # therefore needs the fileServer.certFP that the writer normally records.
  if [ "$transport" = "selfsigned" ] && [ -n "$fsurl" ] && [ -z "$fsfp" ] &&
     [ "$(show_qr_authority_key "$fsurl")" != "$(show_qr_authority_key "$url")" ]; then
    show_qr_profile_invalid "That saved self-signed file server uses a different host or port but stores no certificate fingerprint — re-run setup (bash conduck-connect.sh --setup) to refresh it."
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
  GW_CERT_FP=$(json_get "$PROFILE_FILE" "gateway.certFP")

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
        GW_LOCAL_PORT=$(env_get "$HOME/.hermes/.env" "API_SERVER_PORT"); GW_LOCAL_PORT="${GW_LOCAL_PORT:-8642}"
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
    *)      die "The saved profile has an unknown auth mode '$GW_AUTH' — re-run the wizard (bash conduck-connect.sh) to refresh it." ;;
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
      # Custom gateway: nothing on disk to read (by design — this tool never stores tokens).
      say ""
      note "Custom gateways have no config file I can read, and this tool deliberately never stores your token."
      GW_TOKEN=$(ask_secret "Paste the gateway bearer token again — the secret key the gateway checks (hidden)")
      [ -n "$GW_TOKEN" ] || die "A token is required (the saved profile says auth=bearer). Re-run when you have it."
      ;;
  esac
}

# Recover the file-lane credential from disk when the profile carries a lane. If it
# can't be recovered, WARN loudly and (with an explicit confirm) continue gateway-only.
show_qr_recover_file_lane() {
  local fsurl; fsurl=$(json_get "$PROFILE_FILE" "fileServer.url")
  [ -n "$fsurl" ] || { FS_URL=""; FS_CRED=""; return 0; }   # profile has no file lane
  local saved_port saved_fp saved_folder
  saved_port=$(json_get "$PROFILE_FILE" "fileServer.localPort")
  saved_fp=$(json_get "$PROFILE_FILE" "fileServer.certFP")
  saved_folder=$(json_get "$PROFILE_FILE" "fileServer.folder")
  # existing_fs_config recovers the credential (state cred file / env file / unit) and
  # sets FS_CRED + FS_LOCAL_PORT + FS_FOLDER; keep the profile's URL/port/cert authoritative.
  if existing_fs_config && [ -n "$FS_CRED" ]; then
    FS_URL="$fsurl"
    [ -n "$saved_port" ] && FS_LOCAL_PORT="$saved_port"
    FS_CERT_FP="$saved_fp"
    if [ -n "$saved_folder" ] && [ "$saved_folder" != "$FS_FOLDER" ]; then
      note "The saved profile's informational folder differs from the live service definition; using the structurally parsed live folder."
    fi
    ok "Recovered the file-lane credential from this machine (not shown)."
    if $FS_CRED_LEGACY_ARGV; then
      note "Heads-up: that file-server unit keeps its password on the command line (visible via 'ps'). The QR is still correct."
    fi
  else
    warn "The saved profile includes a file lane at $fsurl, but I can't recover its credential on this machine"
    warn "(its 0600 credential file and the file-server unit are both gone). Without it, the QR can't carry the file password."
    if confirm "  Re-show the code for the GATEWAY ONLY (chat everywhere; no attachments)?"; then
      note "Leaving the file lane out of this QR — re-run the wizard (bash conduck-connect.sh) to rebuild it."
      FS_URL=""; FS_CRED=""; FS_CERT_FP=""; FS_FOLDER=""
    else
      die "Stopped — re-run the wizard (bash conduck-connect.sh) to rebuild the file lane and refresh the profile."
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
  die "Your setup changed since this profile was saved — re-run the wizard (bash conduck-connect.sh) to reconcile and refresh it."
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
    selfsigned)
      # Re-pin check: the cert the app would trust must be the one we saved.
      local live; live=$(compute_spki_hex "$GW_URL" 2>/dev/null)
      if [ -z "$live" ] || [ "$live" != "$GW_CERT_FP" ]; then
        bad "The gateway's certificate changed since this profile was saved."
        note "expected fingerprint: ${GW_CERT_FP:-<none>}"
        note "live fingerprint:     ${live:-<unreadable>}"
        die "The gateway's certificate changed; re-run the wizard (bash conduck-connect.sh) to re-pin — scanning an old pin would fail on the device."
      fi
      ok "Gateway certificate still matches the pinned fingerprint."
      if [ -n "$FS_URL" ] && [ -n "$FS_CRED" ] && [ -n "$FS_CERT_FP" ]; then
        local flive; flive=$(compute_spki_hex "$FS_URL" 2>/dev/null)
        if [ -z "$flive" ] || [ "$flive" != "$FS_CERT_FP" ]; then
          bad "The file lane's certificate changed since this profile was saved."
          note "expected fingerprint: $FS_CERT_FP"
          note "live fingerprint:     ${flive:-<unreadable>}"
          die "The file lane's certificate changed; re-run the wizard (bash conduck-connect.sh) to re-pin it."
        fi
        ok "File-lane certificate still matches its pinned fingerprint."
      fi
      ;;
    cloudflare|public)
      note "This transport has no local exposure to introspect — reachability is proven by the real requests below."
      ;;
    *)
      die "The saved profile has an unrecognized transport '$TRANSPORT' — re-run the wizard (bash conduck-connect.sh) to refresh it."
      ;;
  esac
}

# Orchestrate the --show-code path: pick → load → secrets → live-match gate, then the
# UNCHANGED verify_all + emit_payload. No configuration/exposure mutates
# (REUSE_ONLY is forced on), so APPLIED/FS_APPLIED stay empty. Verification can
# still write and delete one small probe on an already-configured file lane.
run_show_qr() {
  head_ "Re-show your pairing code — skips setup and changes no configuration"
  show_qr_pick_profile
  show_qr_load_profile
  show_qr_recover_gateway_secret
  show_qr_recover_file_lane
  show_qr_check_live
  verify_all
  emit_payload
}
