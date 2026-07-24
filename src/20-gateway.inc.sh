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
GW_CERT_FP=""      # SPKI SHA-256 hex, self-signed path only

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
  choice=$(require_choice "Choose 1-3" '^[123]$') || die "$NO_ANSWER"
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
# A config gateway.port is validated as a real 1-65535 port (like the interactive prompt);
# garbage is noted (stderr — this runs under $()) and skipped so it can't interpolate into
# a probe URL or the exposure commands.
openclaw_local_port() {
  local cfg="$HOME/.openclaw/openclaw.json"
  local compose_dir="${OPENCLAW_DIR:-$HOME/openclaw}"
  local praw port
  praw=$(env_get "$compose_dir/.env" "OPENCLAW_GATEWAY_PORT")
  port="${praw##*:}"
  if [ -z "$port" ]; then
    port=$(json_get "$cfg" "gateway.port")
    if [ -n "$port" ] && ! show_qr_is_port "$port"; then
      note "Ignoring gateway.port='$port' in openclaw.json — not a whole number in 1-65535; using the default." >&2
      port=""
    fi
  fi
  printf '%s' "${port:-18789}"
}

# Prompt for the OpenClaw bearer credential (hidden), or die with <die-msg> on empty input.
# In the wizard's dry-run it only notes the intent (a real run would ask). Sets GW_TOKEN.
_openclaw_prompt_secret() { # _openclaw_prompt_secret <ctx> <ask-prompt> <die-msg-on-empty>
  local ctx="$1" ask="$2" diemsg="$3"
  if [ "$ctx" = "wizard" ] && $DRY_RUN; then
    note "(dry-run: would prompt for the gateway credential)"
    return 0
  fi
  GW_TOKEN=$(ask_secret "$ask")
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
      if run_step "enable the chat endpoint" \
        docker compose --project-directory "$compose_dir" run --rm --no-deps --entrypoint node openclaw-gateway \
          dist/index.js config set --batch-json \
          '[{"path":"gateway.http.endpoints.chatCompletions.enabled","value":true}]'; then
        run_step "restart the gateway so the flag applies" \
          docker compose --project-directory "$compose_dir" restart openclaw-gateway || true
      fi
    else
      print_and_wait "Your OpenClaw doesn't look like the standard Docker setup, so apply the flag with your own install's CLI, then restart the gateway." \
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
  GW_LOCAL_PORT=$(env_get "$envf" "API_SERVER_PORT"); GW_LOCAL_PORT="${GW_LOCAL_PORT:-8642}"
  GW_HEALTH_PATH="/v1/health"

  # 8645 is Hermes's OTHER OpenAI door: the tool-less `hermes proxy`. It chats
  # fine, so nothing downstream would fail — the user would just silently lose
  # tools, skills, and memory. Challenge it here; verification can't catch it.
  if [ "$GW_LOCAL_PORT" = "8645" ]; then
    warn "API_SERVER_PORT is 8645 — the port of the tool-less 'hermes proxy', not the full-agent API server (default 8642)."
    say  "  Both can chat, but only the full-agent API server carries Hermes's tools, skills, and memory."
    if $DRY_RUN; then
      note "(dry-run: a real run asks whether to continue with 8645)"
    elif $REUSE_ONLY; then
      # reuse-only reuses what exists — it warns, never gates (a new die-by-default
      # prompt here would break "safe to point at a live gateway").
      note "(reuse-only: continuing with the existing config — if this is wrong, fix API_SERVER_PORT and re-run the wizard)"
    elif ! confirm "  Continue with port 8645 anyway?"; then
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
    if confirm "  Append these now?"; then
      [ -f "$envf" ] || ( umask 077; : > "$envf" )   # the key lands inside — never create it world-readable
      # No `|| true` here: a failed append (read-only fs, perms) must NOT report
      # "Written." and send the user on to a verify step that mis-diagnoses it.
      { echo ""; echo "# added by conduck-connect $(date -u +%Y-%m-%dT%H:%MZ)";
        echo "API_SERVER_ENABLED=true"; echo "API_SERVER_HOST=127.0.0.1";
        echo "API_SERVER_PORT=$GW_LOCAL_PORT";
        if [ -n "$keyline" ]; then echo "$keyline"; fi; } >> "$envf" \
        || die "Could not write to $envf. Fix its permissions (or add the API_SERVER_* lines yourself), then re-run me."
      ok "Written."
      if [ "$OS" = "Linux" ] && have systemctl && systemctl --user is-enabled hermes-gateway.service >/dev/null 2>&1; then
        run_step "restart Hermes so the API server starts" \
          systemctl --user restart hermes-gateway.service || true
      else
        print_and_wait "Restart Hermes however it runs on this machine so the new API server settings load." \
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
    GW_TOKEN=$(ask_secret "Paste the Hermes API server key (hidden)")
    [ -n "$GW_TOKEN" ] || die "An API key is required for Hermes."
  fi
  GW_AUTH="bearer"
}

# Probe a local OpenAI-compatible server for its model list; if exactly one model
# is returned, echo it (used to pre-fill the model default — saves a prompt).
# Sends the just-collected bearer when there is one — a compliant server 401s an
# unauthenticated probe, which used to silently kill the pre-fill.
probe_single_model() { # probe_single_model <local_port>
  [ -n "$1" ] || return 0
  local body=""
  if [ "${GW_AUTH:-none}" = "bearer" ] && [ -n "${GW_TOKEN:-}" ]; then
    # Same stdin-config idiom as curl_gw: the token never rides argv (`ps`).
    local tok="$GW_TOKEN"; tok="${tok//\\/\\\\}"; tok="${tok//\"/\\\"}"
    body=$(printf 'header = "Authorization: Bearer %s"\n' "$tok" \
      | curl -q -sS --max-time 5 --config - "http://127.0.0.1:$1/v1/models" 2>/dev/null)
  else
    body=$(curl -q -sS --max-time 5 "http://127.0.0.1:$1/v1/models" 2>/dev/null)
  fi
  printf '%s' "$body" | python3 -c '
import json,sys
try:
    ids=[m.get("id") for m in (json.load(sys.stdin).get("data") or []) if m.get("id")]
    if len(ids)==1: print(ids[0])
except Exception: pass' 2>/dev/null
}

configure_generic() {
  head_ "Step 2 — your OpenAI-compatible server"
  GW_NAME=$(ask "  A short name for it (shown in the app)" "My gateway")
  GW_ID="custom-$(slug "$GW_NAME")"; [ "$GW_ID" = "custom-" ] && GW_ID="custom-gateway"
  if confirm "  Does it already have an https:// URL?"; then
    GW_LOCAL_PORT=""
    GW_URL=$(ask_url "Its full https:// web address" "https://ai.example.com") || die "$NO_ANSWER"
    apply_gateway_url_normalization
  else
    while true; do
      GW_LOCAL_PORT=$(ask "  Local port it listens on (e.g. 11434 for Ollama)" "")
      [ -n "$GW_LOCAL_PORT" ] || die "Need the local port (or an https URL)."
      case "$GW_LOCAL_PORT" in
        *[!0-9]*) warn "That's not a port number — digits only (e.g. 11434)." ;;
        # Length-bound BEFORE the numeric test (6+ digits can't be a port): bash
        # 3.2 errors out loudly on an integer comparison wider than intmax.
        ??????*) warn "Ports go from 1 to 65535." ;;
        *) [ "$GW_LOCAL_PORT" -ge 1 ] && [ "$GW_LOCAL_PORT" -le 65535 ] && break
           warn "Ports go from 1 to 65535." ;;
      esac
    done
  fi
  GW_HEALTH_PATH=""   # no portable health endpoint on arbitrary servers
  if confirm "  Does it require a bearer token / API key?"; then
    GW_AUTH="bearer"
    if $DRY_RUN; then note "(dry-run: would prompt for the token)"; GW_TOKEN="<token>"
    else GW_TOKEN=$(ask_secret "Paste it (hidden)"); [ -n "$GW_TOKEN" ] || die "Empty token."; fi
  else
    GW_AUTH="none"; GW_TOKEN=""
    note "Keyless — fine on a private network (Tailscale/LAN) where the network is the auth."
    note "On a PUBLIC transport a keyless server is wide open; I'll guard against that below."
  fi
  say "  Some servers (Ollama, vLLM, LiteLLM without a default) need the app to"
  say "  name a model in every request."
  local model_default=""; $DRY_RUN || model_default=$(probe_single_model "$GW_LOCAL_PORT")
  if [ -n "$model_default" ]; then
    GW_MODEL=$(ask_default "Model name (your server reports exactly one):" "$model_default")
  else
    GW_MODEL=$(ask "  Model name (leave blank if your server picks a default)" "")
  fi
}
