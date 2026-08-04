# ------------------------------------------------------------- gateway phase --

GW_KIND=""         # openclaw | hermes | custom
GW_ID=""           # openclaw | hermes | custom-<slug>  (stable id for unit/state naming)
GW_NAME=""         # display name for custom
GW_LOCAL_PORT=""   # loopback port on this host ("" when user brought a full URL)
GW_HEALTH_PATH=""  # /healthz | /v1/health | "" (skip)
GW_AUTH="bearer"   # bearer | none
GW_TOKEN=""
GW_MODEL=""        # optional explicit model (generic servers like vLLM/Ollama)
GW_URL=""          # final https URL
# True once this run is changing a gateway that already has a saved setup, which
# freezes GW_ID: the name is display text from then on, and re-deriving an id
# from an edited name is what creates a duplicate instead of an edit.
GW_EDITING=false

# A --check-server handoff pairs the ONE address the check graded, so its gateway
# kind is "custom" no matter what answered — see prepare_setup_from_check. This
# latch carries the single Hermes fact that survives that decision: the checked
# address matched this machine's own Hermes API-server settings. It is set only
# by a PASSING --check-server (never by --check-adapter, which grades a different
# contract), and it only ever unlocks a report and an offer. It must never stand
# in for GW_KIND: an address match is not authority to run Hermes-specific
# configuration steps the check never verified.
CHECK_HANDOFF_LOCAL_HERMES=false

detect_gateway() {
  head_ "Step 1 — find your gateway"
  # Legacy --generic: the caller already declared "a server I configured myself",
  # so detection is skipped entirely. Without this, an unrelated OpenClaw install
  # on the same host would appear as "1) OpenClaw (detected)" to someone who never
  # asked about OpenClaw, and pairing the wrong service is a silent mis-setup.
  if [ "$SETUP_GATEWAY_HINT" = "custom" ]; then
    GW_KIND="custom"
    say "  Configuring a server you set up yourself (skipping gateway detection)."
    return 0
  fi
  local found=()
  [ -f "$HOME/.openclaw/openclaw.json" ] && found+=("openclaw")
  { [ -f "$HOME/.hermes/.env" ] || [ -d "$HOME/.hermes" ]; } && found+=("hermes")

  if [ ${#found[@]} -gt 0 ]; then
    say "  We found these on this machine: ${BOLD}${found[*]}${RESET}"
    say "  You can choose one of them, or configure a different server."
  else
    say "  No OpenClaw or Hermes install detected in the usual places."
    say "  You can still choose either one or configure a different server."
  fi

  say ""
  say "  Which gateway should Conduck talk to?"
  say "    1) OpenClaw $( [[ " ${found[*]-} " == *" openclaw "* ]] && echo '(detected)' )"
  say "    2) Hermes   $( [[ " ${found[*]-} " == *" hermes "* ]] && echo '(detected)' )"
  say "    3) Something else that speaks the OpenAI API (Ollama, LiteLLM, vLLM, your own adapter, …)"
  local choice
  choice=$(require_choice "Choose 1-3" '^[123]$' "nav.gateway") || die "$NO_ANSWER"
  [ "$choice" = "q" ] && quit_run
  case "$choice" in
    1) GW_KIND="openclaw" ;;
    2) GW_KIND="hermes" ;;
    3) GW_KIND="custom" ;;
    *) die "Invalid choice." ;;   # unreachable; a silent fallthrough would leave GW_KIND unset
  esac
}

# Resolve OpenClaw's loopback port. Precedence: a live --port override (unknowable from
# outside the process, so unread) > OPENCLAW_GATEWAY_PORT in the compose .env > gateway.port
# in openclaw.json > 18789. Shared by setup AND --show-code so the two never disagree.
# BOTH sources are validated as a real 1-65535 port (like the interactive prompt);
# garbage is noted (stderr — this runs under $()) and skipped so it can't interpolate into
# a probe URL or the exposure commands. env_get returns the rest of the line, so the
# ordinary dotenv trailing-comment form `OPENCLAW_GATEWAY_PORT=18789 # gateway` yields
# "18789 # gateway" — which word-splits inside the unquoted `tailscale …` command and
# defeats every `[ "$GW_LOCAL_PORT" = "…" ]` comparison downstream.
openclaw_local_port() {
  local cfg="$HOME/.openclaw/openclaw.json"
  local compose_dir="${OPENCLAW_DIR:-$HOME/openclaw}"
  local praw port
  praw=$(env_get "$compose_dir/.env" "OPENCLAW_GATEWAY_PORT")
  port="${praw##*:}"
  if [ -n "$port" ] && ! show_qr_is_port "$port"; then
    note "Ignoring OPENCLAW_GATEWAY_PORT='$port' in $compose_dir/.env — not a whole number in 1-65535; falling back." >&2
    port=""
  fi
  if [ -z "$port" ]; then
    port=$(json_get "$cfg" "gateway.port")
    if [ -n "$port" ] && ! show_qr_is_port "$port"; then
      note "Ignoring gateway.port='$port' in openclaw.json — not a whole number in 1-65535; using the default." >&2
      port=""
    fi
  fi
  printf '%s' "${port:-18789}"
}

# Hermes's loopback port, from API_SERVER_PORT in ~/.hermes/.env, validated the
# same way openclaw_local_port validates its own sources and for the same reason:
# `API_SERVER_PORT=8642 # full-agent server` is ordinary dotenv, and env_get hands
# back the whole remainder of the line. Unvalidated, that string word-splits
# inside the unquoted `tailscale serve/funnel …` command and silently defeats the
# `= "8645"` guard that warns about the tool-less proxy port.
# Shared by setup AND --show-code so the two can never disagree.
hermes_api_server_port() {
  local port
  port=$(env_get "$HOME/.hermes/.env" "API_SERVER_PORT")
  if [ -n "$port" ] && ! show_qr_is_port "$port"; then
    note "Ignoring API_SERVER_PORT='$port' in ~/.hermes/.env — not a whole number in 1-65535; using the default." >&2
    port=""
  fi
  printf '%s' "${port:-8642}"
}

# Prompt for the OpenClaw bearer credential (hidden), or die with <die-msg> on empty input.
# In the wizard's dry-run it only notes the intent (a real run would ask). Sets GW_TOKEN.
_openclaw_prompt_secret() { # _openclaw_prompt_secret <ctx> <ask-prompt> <die-msg-on-empty>
  local ctx="$1" ask="$2" diemsg="$3"
  if [ "$ctx" = "wizard" ] && $DRY_RUN; then
    note "(dry-run: would prompt for the gateway credential)"
    return 0
  fi
  GW_TOKEN=$(ask_secret "$ask" "stop; this credential is required")
  [ -n "$GW_TOKEN" ] || die "$diemsg"
}

# Resolve OpenClaw's gateway credential from openclaw.json's auth.mode. Shared by the wizard
# (configure_openclaw) and the --show-code re-emit so BOTH resolve IDENTICALLY. Sets GW_AUTH +
# GW_TOKEN. mode ""/token → gateway.auth.token; password → gateway.auth.password (rides as the
# bearer credential); none → keyless; trusted-proxy/unknown → prompt. A literal value is used
# as-is; an indirect value (an "${ENV}" placeholder or a SecretRef object) is NEVER embedded —
# we prompt for the real secret instead. Absent in the config falls back to
# OPENCLAW_GATEWAY_TOKEN in the compose .env (token mode), then prompts.
# ctx = "wizard" | "showqr": affects wording + dry-run only. In showqr a non-literal resolution
# ALWAYS prompts (its documented "may still ask" contract), and a bearer profile whose config
# now reads mode=none is treated as a token to re-enter — never a silent keyless downgrade.
openclaw_resolve_secret() { # openclaw_resolve_secret <ctx>
  local ctx="$1"
  local cfg="$HOME/.openclaw/openclaw.json"
  local compose_dir="${OPENCLAW_DIR:-$HOME/openclaw}"
  [ -f "$cfg" ] || die "Can't find $cfg to read the OpenClaw credential — is this the machine you paired on? Re-run the wizard (bash conduck-connect.sh) if OpenClaw moved."
  local mode; mode=$(json_get "$cfg" "gateway.auth.mode")
  case "$mode" in
    none)
      if [ "$ctx" = "showqr" ]; then
        warn "OpenClaw's config now shows auth mode 'none', but your saved profile expects a token."
        _openclaw_prompt_secret "$ctx" \
          "Paste the gateway bearer token again — the secret key the gateway checks (hidden)" \
          "A token is required (your saved profile says auth=bearer). Re-run when you have it."
        return 0
      fi
      GW_AUTH="none"; GW_TOKEN=""
      note "OpenClaw's gateway auth mode is 'none' — this gateway has no token. Fine on a private network; I'll guard against publishing it keyless below."
      ;;
    ""|token|password)
      GW_AUTH="bearer"
      local key="gateway.auth.token"; [ "$mode" = "password" ] && key="gateway.auth.password"
      local cls; cls=$(json_query "$cfg" "classify" "$key")
      case "$cls" in
        literal$'\t'*)
          GW_TOKEN="${cls#*$'\t'}"
          ok "Read the gateway bearer credential (the secret key the app sends to log in) from openclaw.json (not shown)."
          ;;
        ref)
          warn "Your OpenClaw config references the credential indirectly (an env placeholder or secret reference), not as a literal value."
          _openclaw_prompt_secret "$ctx" \
            "Paste the actual secret value the gateway checks (hidden)" \
            "OpenClaw's config points at the credential indirectly, so I can't read it — paste the real value and re-run."
          ;;
        *)
          # Absent in the config → try the compose .env (OPENCLAW_GATEWAY_TOKEN; token mode
          # only), then prompt. The seed .env can drift, but it beats no token at all.
          [ "$mode" = "password" ] || GW_TOKEN=$(env_get "$compose_dir/.env" "OPENCLAW_GATEWAY_TOKEN")
          if [ -n "$GW_TOKEN" ]; then
            ok "Read the gateway bearer token from the OpenClaw compose .env (not shown)."
          else
            warn "No literal token found at $key in $cfg (or in the compose .env)."
            _openclaw_prompt_secret "$ctx" \
              "Paste the gateway bearer token — the secret key the gateway checks on each request (hidden)" \
              "OpenClaw needs its access token (the secret key the gateway checks). Find it in openclaw.json under $key, then re-run."
          fi
          ;;
      esac
      ;;
    *)
      # trusted-proxy or anything unknown: we can't infer the credential to send.
      GW_AUTH="bearer"
      note "OpenClaw's gateway auth mode is '$mode' — I won't guess a credential for it; paste whatever bearer value the gateway expects."
      _openclaw_prompt_secret "$ctx" \
        "Paste the bearer credential the gateway expects (hidden)" \
        "This auth mode ('$mode') needs a credential I can't read automatically — paste it and re-run."
      ;;
  esac
}

configure_openclaw() {
  head_ "Step 2 — OpenClaw: chat endpoint + token"
  GW_ID="openclaw"
  local cfg="$HOME/.openclaw/openclaw.json"
  [ -f "$cfg" ] || die "Cannot find $cfg — is OpenClaw onboarded on this machine? (Run its onboarding first; this script doesn't install gateways.)"

  # OpenClaw's config is JSON5 on read (comments + trailing commas legal); its own
  # 'config set' (which the enable-endpoint step below may run) rewrites the file as
  # plain JSON and DROPS comments. Say so once when the file isn't strict JSON, so a
  # comment-keeping user can back it up first. (json_get reads it either way — it
  # parses JSON5.)
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$cfg" 2>/dev/null; then
    warn "Your OpenClaw config isn't strict JSON — it likely uses JSON5 comments or trailing commas." >&2
    note "If I enable the chat endpoint, OpenClaw's 'config set' rewrites the file as plain JSON and drops any comments — back it up first if you want to keep them." >&2
  fi

  # Loopback port + its precedence live in openclaw_local_port (shared with --show-code).
  local compose_dir="${OPENCLAW_DIR:-$HOME/openclaw}"   # still needed for the enable-endpoint check below
  GW_LOCAL_PORT=$(openclaw_local_port)
  GW_HEALTH_PATH="/healthz"
  ok "Gateway port: $GW_LOCAL_PORT"

  # The flag that bites everyone: chat endpoint is OFF by default.
  local enabled; enabled=$(json_get "$cfg" "gateway.http.endpoints.chatCompletions.enabled")
  if [ "$enabled" = "true" ]; then
    ok "OpenAI chat endpoint already enabled."
  else
    warn "The OpenAI-compatible chat endpoint is OFF (it is off by default)."
    say  "  Without it the gateway looks healthy but no app can connect."
    if [ -f "$compose_dir/docker-compose.yml" ] || [ -f "$compose_dir/compose.yaml" ]; then
      if run_step "gateway.openclaw.enable_chat" "enable the chat endpoint" \
        docker compose --project-directory "$compose_dir" run --rm --no-deps --entrypoint node openclaw-gateway \
          dist/index.js config set --batch-json \
          '[{"path":"gateway.http.endpoints.chatCompletions.enabled","value":true}]'; then
        # Same boot window as the tool-policy restart: `restart` returns in about
        # a second and the health route answers a few seconds later. Usually the
        # exposure step buys that time, but a run reusing an existing exposure
        # walks straight into verification, so wait here too. HTTP-safe is FALSE
        # — this change IS the HTTP layer, so the epilogue must not promise it
        # cannot affect it. GW_LOCAL_PORT and GW_HEALTH_PATH are set just above.
        if run_step "gateway.openclaw.restart_chat" "restart the gateway so the flag applies" \
          docker compose --project-directory "$compose_dir" restart openclaw-gateway; then
          gw_note_restart_and_wait "chat-endpoint setting" false
        fi
      fi
    else
      print_and_wait "gateway.openclaw.manual_enable_chat" \
        "Your OpenClaw doesn't look like the standard Docker setup, so apply the flag with your own install's CLI, then restart the gateway." \
        "openclaw config set gateway.http.endpoints.chatCompletions.enabled true" || true
    fi
    if ! $DRY_RUN; then
      enabled=$(json_get "$cfg" "gateway.http.endpoints.chatCompletions.enabled")
      [ "$enabled" = "true" ] && ok "Chat endpoint is now enabled." \
        || warn "Could not confirm the flag in $cfg — verification below will tell us for sure."
    fi
  fi

  # The REAL runtime credential lives in openclaw.json (the .env value is only an onboarding
  # seed and can drift from what the gateway actually checks). Resolution — mode → classify →
  # literal | env-fallback | prompt — is shared with --show-code so the two never diverge.
  openclaw_resolve_secret "wizard"
}

configure_hermes() {
  head_ "Step 2 — Hermes: API server + key"
  GW_ID="hermes"
  local envf="$HOME/.hermes/.env"
  [ -d "$HOME/.hermes" ] || die "Cannot find ~/.hermes — is Hermes installed for this user? (This script doesn't install gateways.)"

  local enabled; enabled=$(env_get "$envf" "API_SERVER_ENABLED")
  GW_LOCAL_PORT=$(hermes_api_server_port)
  GW_HEALTH_PATH="/v1/health"

  # 8645 is Hermes's OTHER OpenAI door: the tool-less `hermes proxy`. It chats
  # fine, so nothing downstream would fail — the user would just silently lose
  # tools and skills. Challenge it here; verification can't catch it.
  # Hermes's own recall is deliberately NOT in that list: Conduck replays the
  # whole conversation every turn, so a gateway-side memory is not a capability
  # this pairing wants on either port, and naming it as one here would sell the
  # 8642 API server on the very thing the API-server scope step offers to remove.
  if [ "$GW_LOCAL_PORT" = "8645" ]; then
    warn "API_SERVER_PORT is 8645 — the port of the tool-less 'hermes proxy', not the full-agent API server (default 8642)."
    say  "  Both can chat, but only the full-agent API server carries Hermes's tools and skills."
    if $DRY_RUN; then
      note "(dry-run: a real run asks whether to continue with 8645)"
    elif $REUSE_ONLY; then
      # reuse-only reuses what exists — it warns, never gates (a new die-by-default
      # prompt here would break "safe to point at a live gateway").
      note "(reuse-only: continuing with the existing config — if this is wrong, fix API_SERVER_PORT and re-run the wizard)"
    elif ! confirm "  Continue with port 8645 anyway?" "gateway.hermes.accept_8645"; then
      die "Stopped — point API_SERVER_PORT in ~/.hermes/.env at the full-agent API server (default 8642), then re-run me."
    fi
  fi

  if [ "$enabled" = "true" ]; then
    ok "Hermes OpenAI API server already enabled (port $GW_LOCAL_PORT)."
  elif $DRY_RUN; then
    note "(dry-run: would append API_SERVER_* to $envf and restart Hermes)"
    plan_add "APPEND API_SERVER_ENABLED/HOST/PORT/KEY to $envf, then restart hermes-gateway"
  else
    warn "Hermes's OpenAI API server is OFF (the setup wizard does not enable it)."
    mutate_guard "append API_SERVER_* to $envf" || return 0
    # Reuse an existing key rather than silently rotating one other clients may use.
    local newkey keyline=""
    newkey=$(env_get "$envf" "API_SERVER_KEY")
    [ -n "$newkey" ] || { newkey=$(openssl rand -hex 32); keyline="API_SERVER_KEY=$newkey"; }
    say "  I'd append to $envf:"
    say "    API_SERVER_ENABLED=true"
    say "    API_SERVER_HOST=127.0.0.1"
    say "    API_SERVER_PORT=$GW_LOCAL_PORT"
    if [ -n "$keyline" ]; then say "    API_SERVER_KEY=<freshly generated, not shown>"
    else say "    (keeping the API_SERVER_KEY already in your .env)"; fi
    if confirm "  Append these now?" "gateway.hermes.enable_api"; then
      [ -f "$envf" ] || ( umask 077; : > "$envf" )   # the key lands inside — never create it world-readable
      # No `|| true` here: a failed append (read-only fs, perms) must NOT report
      # "Written." and send the user on to a verify step that mis-diagnoses it.
      { echo ""; echo "# added by conduck-connect $(date -u +%Y-%m-%dT%H:%MZ)";
        echo "API_SERVER_ENABLED=true"; echo "API_SERVER_HOST=127.0.0.1";
        echo "API_SERVER_PORT=$GW_LOCAL_PORT";
        if [ -n "$keyline" ]; then echo "$keyline"; fi; } >> "$envf" \
        || die "Could not write to $envf. Fix its permissions (or add the API_SERVER_* lines yourself), then re-run me."
      ok "Written."
      # The `umask 077` above only covers a file we CREATE. A ~/.hermes/.env that
      # Hermes already wrote under umask 022 is 0644, and the API server key just
      # appended (or re-read) is a live gateway credential sitting in it. The
      # announce-then-confirm gate, and what it says when the answer is no or the
      # chmod fails, both live in secure_owned_file_mode.
      secure_owned_file_mode "$envf" "your API server key" || true
      if [ "$OS" = "Linux" ] && have systemctl && systemctl --user is-enabled hermes-gateway.service >/dev/null 2>&1; then
        run_step "gateway.hermes.restart_api" "restart Hermes so the API server starts" \
          systemctl --user restart hermes-gateway.service || true
      else
        print_and_wait "gateway.hermes.manual_restart_api" \
          "Restart Hermes however it runs on this machine so the new API server settings load." \
          "systemctl --user restart hermes-gateway.service   # or your own restart method" || true
      fi
    else
      note "(skipped — verification below will fail if the API server is off)"
    fi
  fi

  GW_TOKEN=$(env_get "$envf" "API_SERVER_KEY")
  if [ -n "$GW_TOKEN" ]; then ok "Read API_SERVER_KEY from ~/.hermes/.env (not shown)."
  elif $DRY_RUN; then note "(dry-run: would prompt for the Hermes API server key)"
  else
    GW_TOKEN=$(ask_secret "Paste the Hermes API server key (hidden)" "stop; Hermes requires a key")
    [ -n "$GW_TOKEN" ] || die "An API key is required for Hermes."
  fi

  GW_AUTH="bearer"

  # The API-server toolset list decides something no wire check can ever see —
  # whether this gateway keeps a conversation memory of its own — and it is asked
  # once per run by hermes_recall_post_file_lane_step, after the optional file lane
  # has had its say. Deliberately not here: the file lane rewrites the SAME
  # `platform_toolsets.api_server` line, so settling it in this function edits and
  # restarts Hermes twice for one line, on a run exposure can still abort.
}

# --- "is the address I just checked this machine's Hermes?" -------------------
# Correlation, never identity. Nothing in a static file proves which process owns
# a listening port: a reverse proxy, a container publishing 8642, or a stale
# ~/.hermes/.env can all make another engine look like Hermes. So every reachable
# declaration has to agree, and anything that does not read cleanly answers NO —
# silence is the safe failure here. Claiming a remote gateway keeps a memory it
# does not keep is worse than never mentioning it.
#
# Deliberately NOT a port test. Requiring the bind address, the port, an enabled
# API server, and the exact credential the check actually authenticated with
# means an unrelated service that merely happens to sit on 8642 stays silent.
hermes_settings_match_url() { # hermes_settings_match_url <checked-url> -> 0 when every declaration agrees
  # ${HOME:-} on purpose: --check-server is contracted to run in a bare CI shell
  # that may have no HOME at all, and `set -u` would abort the whole check on an
  # unset one. An empty HOME simply finds no install, which is the right answer.
  local url="$1" envf="${HOME:-}/.hermes/.env"
  local rest hostport host port declared_host declared_port key

  # https means the app is pairing an address off this box (doctor_accept_url only
  # ever admits plain http toward 127.*/localhost/[::1]), and a tailnet or proxy
  # hostname in front of this same Hermes is exactly the case that must not be
  # claimed: from here it is indistinguishable from someone else's gateway.
  case "$url" in
    [Hh][Tt][Tt][Pp]://?*) rest="${url#*://}" ;;
    *) return 1 ;;
  esac
  # A base path routes one listener to many services — http://127.0.0.1:8642/other
  # can be anything at all — so only the bare authority is attributable.
  hostport="${rest%%/*}"
  [ "$hostport" = "$rest" ] || return 1
  case "$hostport" in
    '['*']'*) host="${hostport%%]*}"; host="${host#\[}"; port="${hostport##*]}"; port="${port#:}" ;;
    *:*)      host="${hostport%%:*}"; port="${hostport##*:}" ;;
    *)        host="$hostport"; port="80" ;;
  esac
  [ -n "$port" ] || port="80"
  host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')

  [ -f "$envf" ] && [ -r "$envf" ] || return 1
  [ "$(env_get "$envf" "API_SERVER_ENABLED")" = "true" ] || return 1

  # hermes_api_server_port's 8642 fallback is right for SETUP (Hermes itself falls
  # back the same way) and wrong as evidence: a declaration this connector cannot
  # read is not a statement that the thing on 8642 is Hermes. Read it raw instead.
  declared_port=$(env_get "$envf" "API_SERVER_PORT")
  if [ -n "$declared_port" ]; then
    show_qr_is_port "$declared_port" || return 1
  else
    declared_port="8642"
  fi
  [ "$port" = "$declared_port" ] || return 1

  declared_host=$(env_get "$envf" "API_SERVER_HOST")
  declared_host=$(printf '%s' "$declared_host" | tr '[:upper:]' '[:lower:]')
  case "$declared_host" in
    ""|127.0.0.1|localhost)
      # Hermes's own default bind, and what this wizard writes. 127.0.0.2 answering
      # while Hermes holds 127.0.0.1 is a different listener, not this one.
      [ "$host" = "127.0.0.1" ] || [ "$host" = "localhost" ] || return 1 ;;
    0.0.0.0|'::'|'*') ;;                       # wildcard bind: any loopback address reaches it
    '::1') [ "$host" = "::1" ] || return 1 ;;
    *) [ "$host" = "$declared_host" ] || return 1 ;;
  esac

  # The credential is the strongest evidence available without a fingerprinting
  # request: the check AUTHENTICATED with this exact string, so the live listener
  # accepts the key Hermes's own .env declares. A keyless check, a check with some
  # other token, or a Hermes that declares no key all fail the equality below —
  # each of them leaves nothing to correlate, which is an answer of no.
  key=$(env_get "$envf" "API_SERVER_KEY")
  [ "${GW_AUTH:-}" = "bearer" ] || return 1
  [ -n "${GW_TOKEN:-}" ] || return 1
  [ "$GW_TOKEN" = "$key" ] || return 1
  return 0
}

# The frozen recall step guards on GW_KIND, and a check handoff must keep its
# "custom" kind — that kind decides the paired profile, the health path, the
# file-lane unit naming, and which agent-side steps are allowed to touch Hermes.
# A `local` shadows the global for the duration of the call only, so the step
# sees the gateway it is being asked about while the run keeps pairing exactly
# what it checked. The latches the step sets stay global, as they must.
hermes_recall_checked_handoff_step() {
  local GW_KIND="hermes"
  hermes_recall_scope_step || true
}

# The one place the API-server memory question is asked during setup, for every
# route into it. It sits after the optional file lane because that step asks about
# the SAME `platform_toolsets.api_server` line: letting it go first turns two
# edits and two Hermes restarts into one combined before→after, and leaves every
# host change as late in the run as it can be. A run that never reaches the lane —
# declined, no rclone, chat-only — still lands here.
#
# $HERMES_RECALL_REPORTED is the whole no-double-ask gate: the file-lane step
# reports before every recall decision it makes, so a true latch means the
# question was already put to this operator, whatever they answered. Back
# navigation cannot re-open it either, because nothing above this point asks.
#
# `|| true` is the product decision, not an accident of there being no `set -e`:
# the step returns nonzero whenever the scope is not PROVABLY recall-free, which
# includes a fresh default install and any config the parser will not guess at.
# Report and offer, never block — a gateway that chats perfectly well is still
# pairable, and refusing to pair it is the founder's call, not this step's.
hermes_recall_post_file_lane_step() {
  $HERMES_RECALL_REPORTED && return 0
  if [ "${GW_KIND:-}" = "hermes" ]; then
    hermes_recall_scope_step || true
  elif $CHECK_HANDOFF_LOCAL_HERMES; then
    # Say why a Hermes finding is appearing on a gateway this run calls "custom",
    # and say exactly how strong the claim is. A settings match is not proof of
    # which process holds the port, and this line must not pretend otherwise.
    say ""
    note "This address matches this machine's Hermes API-server settings — same bind address and port, and the check authenticated with the key in ~/.hermes/.env."
    note "That is a settings match, not proof of which process holds that port, so read what follows against your own install."
    hermes_recall_checked_handoff_step
  fi
  return 0
}

# Probe a local OpenAI-compatible server for its model list; if exactly one model
# is returned, echo it (used to pre-fill the model default — saves a prompt).
# Sends the just-collected bearer when there is one — a compliant server 401s an
# unauthenticated probe, which used to silently kill the pre-fill.
# `--noproxy '*'` is mandatory here, not cosmetic: the target is unconditionally
# 127.0.0.1, and curl has NO loopback exemption. `-q` suppresses ~/.curlrc but
# not $http_proxy/$ALL_PROXY, so without it the bearer the user just pasted would
# leave the machine in cleartext to whatever host those variables name.
probe_single_model() { # probe_single_model <local_port>
  [ -n "$1" ] || return 0
  local body=""
  if [ "${GW_AUTH:-none}" = "bearer" ] && [ -n "${GW_TOKEN:-}" ]; then
    # Same stdin-config idiom as curl_gw: the token never rides argv (`ps`).
    local tok="$GW_TOKEN"; tok="${tok//\\/\\\\}"; tok="${tok//\"/\\\"}"
    body=$(printf 'header = "Authorization: Bearer %s"\n' "$tok" \
      | curl -q -sS --max-time 5 --noproxy '*' --config - "http://127.0.0.1:$1/v1/models" 2>/dev/null)
  else
    body=$(curl -q -sS --max-time 5 --noproxy '*' "http://127.0.0.1:$1/v1/models" 2>/dev/null)
  fi
  # Same C0/DEL strip as models_is_json's classifier, for the same reason: this id
  # is echoed straight into the "Press Enter to use: …" prompt, where an ANSI
  # escape could show the operator something other than what they are accepting.
  # Not truncated — it becomes GW_MODEL and rides the pairing payload, so a long
  # legitimate id must survive whole.
  printf '%s' "$body" | python3 -c '
import json,sys
try:
    ids=[m.get("id") for m in (json.load(sys.stdin).get("data") or []) if m.get("id")]
    if len(ids)==1:
        print("".join(c for c in ids[0] if ord(c) >= 0x20 and ord(c) != 0x7f))
except Exception: pass' 2>/dev/null
}

# A bounded value prompt, unlike the free-form name/model/token prompts. `b` is
# safe here because a custom-server answer has changed nothing yet; it restarts
# this short answer group. The answer is assigned directly so q can exit the
# parent shell (a command substitution would trap that exit in a subshell).
ask_custom_gateway_port() { # sets GW_LOCAL_PORT; 0 value / 10 back / 1 EOF
  local reply
  while true; do
    read -r -p "  Local port (e.g. 11434; Enter = no default; i = explain; b = restart these answers; q = stop): " reply \
      || return 1
    case "$reply" in
      [iI]|\?) explain_prompt "gateway.custom.port"; continue ;;
      [bB]) return 10 ;;
      [qQ]) quit_run ;;
      '') warn "A local setup needs a port. Enter its number, or press b to restart these answers and choose HTTPS." ;;
      *[!0-9]*) warn "That's not a port number — digits only (e.g. 11434)." ;;
      # Length-bound BEFORE the numeric test (6+ digits can't be a port): bash
      # 3.2 errors out loudly on an integer comparison wider than intmax.
      ??????*) warn "Ports go from 1 to 65535." ;;
      *)
        if [ "$reply" -ge 1 ] && [ "$reply" -le 65535 ]; then
          GW_LOCAL_PORT="$reply"
          return 0
        fi
        warn "Ports go from 1 to 65535."
        ;;
    esac
  done
}

# Does anything on this machine already answer to this gateway id? The id keys
# THREE separate things — the saved profile, the file-lane unit, and the file
# server's credential/env pair — so "is this name taken?" cannot be a single
# profile test. Two ways an id is occupied without a profile existing:
#
#   - a run that failed verification never reaches write_profile, but HAS
#     already written the credential and the unit. A later gateway that slugs
#     onto the same id would adopt that live file server — its port, its unit
#     and its password — believing it built them itself.
#   - a profile this version cannot parse (one a newer conduck-connect wrote)
#     is deliberately not offered in the picker, and must still hold its id, or
#     hiding it becomes the thing that destroys it.
gateway_id_is_taken() { # gateway_id_is_taken <id> -> 0 when something already owns it
  local id="$1"
  [ -n "$id" ] || return 1
  [ -f "$STATE_DIR/profile-$id.json" ]    && return 0
  [ -f "$STATE_DIR/fileserver-$id.cred" ] && return 0
  [ -f "$STATE_DIR/fileserver-$id.env" ]  && return 0
  if [ "$OS" = "Linux" ]; then
    [ -f "$HOME/.config/systemd/user/conduck-files-$id.service" ] && return 0
  else
    [ -f "$HOME/Library/LaunchAgents/ai.gigaduck.conduck-files-$id.plist" ] && return 0
  fi
  return 1
}

# Say WHICH gateway a refused name collided with, and what the two ways out are.
# The name is not the identity — `slug` lowercases, folds punctuation and cuts at
# 32 characters — so two names an operator reads as obviously different can land
# on one id, and the refusal is unintelligible without naming the occupant.
report_gateway_id_collision() { # report_gateway_id_collision <id>
  # Split, not one `local id=… pf=…$id…`: a mid-`local` self-reference is
  # unbound under `set -u` (the same trap tls_connect_target documents).
  local id="$1" pf="" n=""
  pf="$STATE_DIR/profile-$id.json"
  say ""
  # Readable-or-not is decided by the SAME validator the picker lists with, not by
  # whether a name happens to parse out. A profile from a newer conduck-connect
  # still carries a readable name, so keying on the name would greet an unlisted
  # setup as though the operator could see it in the list above.
  if [ -f "$pf" ] && show_qr_validate_profile "$pf"; then
    n=$(json_get "$pf" "gateway.name")
    bad "That name belongs to a gateway you already set up: $(safe_display "${n:-$id}" 60)  (id: $id)"
    say "  Setting it up again from here would overwrite that one's saved setup and take"
    say "  over its file server — not add a second gateway."
  elif [ -f "$pf" ]; then
    bad "A saved gateway already uses the id '$id'."
    say "  Its saved file can't be read by this version, so it isn't offered in the list"
    say "  above — but the id stays reserved rather than being overwritten."
  else
    bad "An earlier, unfinished run already claimed the id '$id' on this machine."
    say "  Its file server and credential are still here even though no setup code was"
    say "  saved, so reusing the id would silently adopt them."
  fi
  note "Either pick that gateway from the list to change it, or give this one a different name."
}

# The custom gateways this machine has already set up. Without this list the only
# way to reach an existing one is to retype its name so it slugs to the same id,
# and a typo builds a SECOND gateway instead — its own unit, port, credential and
# profile — while the first keeps running, untouched and unmentioned.
#
# Returns 0 with GW_ID/GW_NAME/GW_MODEL restored (change an existing gateway), or
# 1 with nothing set (a new one). Corrupt and future-schema profiles are NOT
# offered — show_qr_validate_profile is the same validator --show-code uses, so a
# listed row can never dead-end a moment after it is chosen — but they are counted
# out loud, because their ids stay reserved and an operator who cannot see them
# cannot understand why a name is later refused.
pick_existing_custom_gateway() { # 0 = editing (globals set) / 1 = new gateway
  local pf cand=() hidden=0
  for pf in "$STATE_DIR"/profile-custom-*.json; do
    [ -e "$pf" ] || continue                 # no matches → the literal glob; skip it
    if show_qr_validate_profile "$pf"; then cand+=("$pf"); else hidden=$((hidden+1)); fi
  done
  if [ ${#cand[@]} -eq 0 ]; then
    [ "$hidden" = "0" ] && return 1          # nothing saved → today's flow, unchanged
    say ""
    note "This machine has $hidden saved gateway setup(s) this version can't read, so they aren't"
    note "listed. They keep their names reserved; updating conduck-connect is what recovers them."
    return 1
  fi
  say ""
  say "  ${BOLD}Custom gateways already set up on this machine:${RESET}"
  local i=1 n u
  for pf in "${cand[@]}"; do
    n=$(json_get "$pf" "gateway.name"); u=$(json_get "$pf" "gateway.url")
    # safe_display on both: these come off disk as free text an earlier run
    # accepted at a name prompt, and this is a terminal.
    printf '    %d) %s — %s\n' "$i" "$(safe_display "${n:-?}" 60)" "$(safe_display "${u:-?}" 80)"
    i=$((i+1))
  done
  printf '    %d) A different gateway — set up a new one\n' "$i"
  [ "$hidden" = "0" ] || note "($hidden more can't be read by this version and aren't listed; their names stay reserved.)"
  local pick
  while true; do
    # {1,3} length-bounds the input so the numeric compare can't overflow bash 3.2's intmax.
    pick=$(require_choice "Which one? Choose 1-$i" '^[0-9]{1,3}$' "nav.custom_gateway_pick") \
      || die "$NO_ANSWER"
    [ "$pick" = "q" ] && quit_run
    { [ "$pick" -ge 1 ] && [ "$pick" -le "$i" ]; } 2>/dev/null && break
    warn "Please enter a number between 1 and $i."
  done
  [ "$pick" = "$i" ] && return 1
  pf="${cand[$((pick-1))]}"
  GW_ID=$(json_get "$pf" "gateway.id")
  [ -n "$GW_ID" ] || return 1                # no id to hold on to → treat as new
  GW_NAME=$(json_get "$pf" "gateway.name")
  GW_MODEL=$(json_get "$pf" "gateway.model")
  # The saved URL, local port and auth mode are deliberately NOT restored.
  # The address because a quick tunnel's hostname is reassigned every time
  # cloudflared restarts, so the saved one is dead far more often than not, and a
  # Tailscale or Cloudflare address restored without its transport would enter the
  # wrong exposure path. The auth mode because the profile holds no token by
  # design, so bearer has to be re-established at the hidden prompt anyway.
  ok "Changing the saved gateway: $(safe_display "${GW_NAME:-$GW_ID}" 60)  (id: $GW_ID)"
  note "I'll ask for its address and token again — the address can have moved, and the"
  note "token is never saved."
  return 0
}

# Auth for a custom gateway, taken at ONE hidden prompt rather than a visible
# [y/N] followed by a hidden one. A question whose own wording is "bearer token /
# API key" invites a paste, and an echoing prompt shows what it receives: the
# token was printed, refused as not-a-yes-or-no, and left in the terminal's
# scroll-back — one line before the hidden prompt that would have taken it
# safely. Asking for the secret directly gives the paste exactly one place to
# land, and that place shows nothing.
#
# Keyless stays EXPLICIT, which is the fail-closed-auth invariant the app holds
# too: an empty answer opens a question, never settles one, and only an
# affirmative confirm sets auth=none. EOF is not an empty answer — ask_secret
# returns nonzero for it, so a redirected run dies instead of reading "nobody
# was there to answer" as "this gateway needs no token".
ask_custom_gateway_auth() { # sets GW_AUTH + GW_TOKEN; dies on EOF, exits on q
  # A dry run must never solicit a real secret, so it takes the mode as a
  # bounded choice instead. `<token>` is the same placeholder the rest of the
  # dry-run path already carries; nothing is stored either way.
  if $DRY_RUN; then
    say "  Does this server require a token (API key) on every request?"
    say "    1) Yes — it requires a token"
    say "    2) No  — it is keyless"
    local c; c=$(require_choice "Choose 1-2 ('i' explains)" '^[12]$' "gateway.custom.has_auth") \
      || die "$NO_ANSWER"
    [ "$c" = "q" ] && quit_run
    if [ "$c" = "1" ]; then
      GW_AUTH="bearer"; GW_TOKEN="<token>"
      note "(dry-run: a real run asks for the token at a hidden prompt)"
    else
      GW_AUTH="none"; GW_TOKEN=""
      # The same two cautions the real run gives. A plan that silently omits them
      # is how keyless looks free of consequence right up until it is applied.
      note "Keyless — fine on a private network (Tailscale/LAN) where the network is the auth."
      note "On a PUBLIC transport a keyless server is wide open; I'll guard against that below."
    fi
    return 0
  fi
  while true; do
    say "  If this server needs a token (API key), paste it now — nothing appears as you type."
    GW_TOKEN=$(ask_secret "Token" "this server is keyless") || die "$NO_ANSWER"
    # An all-whitespace answer is a fumbled paste, not a token and not a
    # deliberate Enter. Letting it through mints a setup code the app parses and
    # then refuses to save, which strands the operator a step later than here.
    case "$GW_TOKEN" in
      *[![:space:]]*) ;;
      ?*) warn "That was only whitespace. Paste the token again, or press Enter for keyless."
          GW_TOKEN=""; continue ;;
    esac
    if [ -n "$GW_TOKEN" ]; then
      GW_AUTH="bearer"
      ok "Token held for this run — it rides in the setup code and is never written to the saved profile."
      return 0
    fi
    note "Keyless — fine on a private network (Tailscale/LAN) where the network is the auth."
    note "On a PUBLIC transport a keyless server is wide open; I'll guard against that below."
    if confirm "  Confirm this server needs NO token?" "gateway.custom.has_auth"; then
      GW_AUTH="none"; GW_TOKEN=""
      return 0
    fi
    say ""; note "↩ Let's take the token again."
  done
}

# The model of a gateway being CHANGED, as a bounded three-way choice rather than
# a prompt with a default. `ask` and `ask_default` can return their default or a
# typed value but never emptiness, so "keep the saved model" and "clear it and let
# the server choose" would collapse onto the same keystroke — and a stale pinned
# model 404s every turn without ever saying so.
choose_saved_model() { # reads + rewrites GW_MODEL
  say ""
  say "  This gateway last used the model: $(safe_display "$GW_MODEL" 200)"
  say "    1) Keep it"
  say "    2) Use a different model name"
  say "    3) Clear it — let the server pick"
  local c; c=$(require_choice "Choose 1-3 ('i' explains)" '^[123]$' "gateway.custom.model") \
    || die "$NO_ANSWER"
  [ "$c" = "q" ] && quit_run
  case "$c" in
    1) : ;;                                              # GW_MODEL already holds it
    2) GW_MODEL=$(ask "  Model name" "" "let the server pick") ;;
    3) GW_MODEL="" ;;
  esac
}

review_custom_gateway() { # 0 continue / 10 re-enter / exits on q
  local address auth model reply
  if [ -n "$GW_URL" ]; then address="$GW_URL"
  else address="http://127.0.0.1:$GW_LOCAL_PORT (local; HTTPS comes next)"; fi
  if [ "$GW_AUTH" = "bearer" ]; then auth="Bearer token configured (hidden)"
  else auth="No token — allowed only on a private path unless explicitly overridden"; fi
  if [ -n "$GW_MODEL" ]; then model=$(safe_display "$GW_MODEL" 4096)
  else model="Server/app default (no model fixed in the setup code)"; fi

  say ""
  if $GW_EDITING; then
    say "  ${BOLD}Review this gateway${RESET}  ${DIM}(updating a gateway you already set up)${RESET}"
  else
    say "  ${BOLD}Review this gateway${RESET}  ${DIM}(new — nothing on this machine uses this name yet)${RESET}"
  fi
  say "    Name:           $(safe_display "$GW_NAME" 200)"
  # The id, not the name, is what the saved setup, the file-lane service and its
  # credential are filed under. Shown once, here, because it is derived from the
  # name by a lossy rule (lowercased, punctuation folded, cut at 32 characters)
  # and is otherwise invisible until two gateways quietly share one.
  say "    Id:             $GW_ID"
  say "    Address:        $(safe_display "$address" 4096)"
  say "    Authentication: $auth"
  say "    Model:          $model"
  say ""
  while true; do
    read -r -p "  Enter = continue; b = re-enter these answers; i = explain; q = stop: " reply \
      || die "$NO_ANSWER"
    case "$reply" in
      '') return 0 ;;
      [bB]) return 10 ;;
      [iI]|\?) explain_prompt "gateway.custom.review" ;;
      [qQ]) quit_run ;;
      *) warn "Press Enter to continue, b to re-enter, i for an explanation, or q to stop." ;;
    esac
  done
}

configure_generic() {
  head_ "Step 2 — your OpenAI-compatible server"
  while true; do
    # Clear the whole draft before a correction, especially the hidden token.
    GW_ID=""; GW_NAME=""; GW_LOCAL_PORT=""; GW_HEALTH_PATH=""
    GW_AUTH="bearer"; GW_TOKEN=""; GW_MODEL=""; GW_URL=""

    GW_EDITING=false
    if pick_existing_custom_gateway; then GW_EDITING=true; fi

    if $GW_EDITING; then
      # The name is DISPLAY only from here on: re-slugging an edited name would
      # mint a fresh id and rebuild the exact duplicate this picker exists to
      # prevent — and then the one thing the operator came here to fix, a
      # mistyped name, would be the one thing they cannot fix.
      GW_NAME=$(ask "  A short name for it (shown in the app)" "$GW_NAME")
    else
      GW_NAME=$(ask "  A short name for it (shown in the app)" "My gateway")
      GW_ID="custom-$(slug "$GW_NAME")"; [ "$GW_ID" = "custom-" ] && GW_ID="custom-gateway"
      # A new gateway may never land on an occupied id. Warning and continuing is
      # not enough: the review screen's default is Enter, the file lane adopts the
      # occupant's credential before any profile is written, and write_profile
      # replaces the file atomically at the end — by then all three are gone.
      if gateway_id_is_taken "$GW_ID"; then
        report_gateway_id_collision "$GW_ID"
        continue
      fi
    fi
    if confirm "  Does it already have an https:// URL?" "gateway.custom.has_https"; then
      GW_URL=$(ask_url "Its full https:// web address" "https://ai.example.com") || die "$NO_ANSWER"
      apply_gateway_url_normalization
    else
      ask_custom_gateway_port
      local port_rc=$?
      if [ "$port_rc" = "10" ]; then
        note "↩ Restarting the custom gateway answers. Nothing has been changed."
        continue
      fi
      [ "$port_rc" = "0" ] || die "Need the local port (or an https URL)."
    fi
    GW_HEALTH_PATH=""   # no portable health endpoint on arbitrary servers
    ask_custom_gateway_auth
    if $GW_EDITING && [ -n "$GW_MODEL" ]; then
      choose_saved_model
    else
      say "  Some servers (Ollama, vLLM, LiteLLM without a default) need the app to"
      say "  name a model in every request."
      local model_default=""; $DRY_RUN || model_default=$(probe_single_model "$GW_LOCAL_PORT")
      if [ -n "$model_default" ]; then
        GW_MODEL=$(ask_default "Model name (your server reports exactly one):" "$model_default")
      else
        GW_MODEL=$(ask "  Model name (leave blank if your server picks a default)" "")
      fi
    fi

    review_custom_gateway
    local review_rc=$?
    [ "$review_rc" = "0" ] && return 0
    [ "$review_rc" = "10" ] || return "$review_rc"
    say ""; note "↩ Re-entering the custom gateway answers. Nothing has been changed."
  done
}
