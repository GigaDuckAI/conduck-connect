#!/usr/bin/env bash
#
# conduck-connect — pair your self-hosted AI gateway with the Conduck app.
#
# How to run (no install, nothing to compile — this is a readable shell script
# on purpose, so you can audit it before running):
#
# Where this should come from:
#   1. Get it over HTTPS from the official release — not forwarded to you by
#      someone else:  https://github.com/gigaduckai/conduck-connect/releases
#   2. Skim this file before running it; it's short and meant to be read. That,
#      plus the HTTPS download, is your real protection.
#   3. Optional integrity check: the release also ships a checksum
#        sha256sum -c conduck-connect.sh.sha256
#      It catches a corrupted download, but it rides the same release channel —
#      so it can't prove the release itself wasn't swapped. Reading the script can.
#   If you got this script any other way, get it from the link above first.
#
#     bash conduck-connect.sh --dry-run  # START HERE: shows your setup + exactly what a
#                                        #   real run would change. Changes nothing.
#     bash conduck-connect.sh            # the real interactive wizard (asks before every change)
#
# What this script DOES (always with your confirmation, step by step):
#   1. Finds your gateway (OpenClaw, Hermes, or any OpenAI-compatible server).
#   2. Enables the OpenAI-compatible chat endpoint if it is off (the #1 setup trap).
#   3. Helps you expose the gateway over HTTPS (works WITH what you have installed:
#      Tailscale, Cloudflare Tunnel, your own reverse proxy, or a self-signed cert).
#   4. Optionally sets up the agent file lane (rclone WebDAV) so Conduck can hand
#      your agent real files and download its outputs.
#   5. Verifies everything end-to-end with real requests.
#   6. Prints a QR code you scan with the Conduck app — URL, token, and file-lane
#      credentials imported in one scan — nothing to retype on your phone
#      (iPhone, iPad, or Android).
#
# What this script NEVER does:
#   - Install your gateway, Tailscale, cloudflared, or any daemon it didn't create.
#   - Modify configs it didn't create without showing you the exact change first.
#   - Send ANY data anywhere except to your own gateway. No telemetry, ever.
#     The QR code is generated locally on this machine.
#   - Make your gateway public without telling you, in plain words, that it will.
#
# Works on Linux and macOS gateway hosts. Requires: bash, curl, python3, openssl.
# No extra install: the QR is rendered locally by a vendored, stdlib-only Python
# encoder (Project Nayuki, MIT — the big, inert block near the end of this file;
# it needs Python 3.7+ — on an older Python you just use the printed code).
# The pairing string is always printed too, so the QR is never required.
#
# Usage:
#   bash conduck-connect.sh                 # interactive: detect + wizard
#   bash conduck-connect.sh --openclaw      # skip detection, configure OpenClaw
#   bash conduck-connect.sh --hermes        # skip detection, configure Hermes
#   bash conduck-connect.sh --generic       # any OpenAI-compatible server
#   bash conduck-connect.sh --dry-run       # show state + plan; mutate nothing
#   bash conduck-connect.sh --show-qr       # re-show a SAVED pairing QR — skips the setup
#                                           # questions and changes NOTHING (needs one prior
#                                           # successful run; may still ask you to pick a
#                                           # profile, re-enter a custom gateway's token, or
#                                           # confirm a gateway-only code; verification still
#                                           # makes its real requests)
#   bash conduck-connect.sh --reuse-only    # only reuse what's already set up; refuse to
#                                           # change anything — use this to re-show your QR
#                                           # on a gateway you don't want touched
#   bash conduck-connect.sh --allow-keyless-public   # expert: permit a keyless
#                                           # gateway on a public transport
#
# Re-running is safe: every step detects existing state and reuses what's done.
# Run it again any time you just want the QR code back — or --show-qr to re-show a
# saved gateway's code, skipping the setup questions (handy for pairing a second device).

set -u -o pipefail

VERSION="0.5.0"
PAYLOAD_VERSION=1

# ---------------------------------------------------------------- utilities --

BOLD=$(tput bold 2>/dev/null || true); DIM=$(tput dim 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true); GREEN=$(tput setaf 2 2>/dev/null || true)
YELLOW=$(tput setaf 3 2>/dev/null || true); RESET=$(tput sgr0 2>/dev/null || true)

say()  { printf '%s\n' "$*"; }
head_() { printf '\n%s%s%s\n' "$BOLD" "$*" "$RESET"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$RED" "$RESET" "$*"; }
note() { printf '  %s%s%s\n' "$DIM" "$*" "$RESET"; }
warn() { printf '%s! %s%s\n' "$YELLOW" "$*" "$RESET"; }
die()  { printf '%sError:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

DRY_RUN=false
REUSE_ONLY=false
SHOW_QR=false
ALLOW_KEYLESS_PUBLIC=false
MODE=""            # openclaw | hermes | generic

for arg in "$@"; do
  case "$arg" in
    --openclaw) MODE="openclaw" ;;
    --hermes)   MODE="hermes" ;;
    --generic)  MODE="generic" ;;
    --dry-run)  DRY_RUN=true ;;
    --show-qr)  SHOW_QR=true ;;
    --reuse-only) REUSE_ONLY=true ;;
    --allow-keyless-public) ALLOW_KEYLESS_PUBLIC=true ;;
    --version)  say "conduck-connect $VERSION"; exit 0 ;;
    -h|--help)  sed -n '2,${/^#/!q;s/^# \{0,1\}//p;}' "$0"; exit 0 ;;   # whole header comment, wherever it ends
    *) die "Unknown argument: $arg (try --help)" ;;
  esac
done

# --show-qr re-emits a SAVED profile's QR: reads only, changes nothing. It cannot
# combine with --dry-run (which plans a fresh run and emits no QR). REUSE_ONLY is
# forced on so any mutation that gets accidentally reached dies via mutate_guard.
if $SHOW_QR; then
  $DRY_RUN && die "--show-qr and --dry-run don't combine: --show-qr re-emits a saved gateway's QR and changes nothing, while --dry-run plans a fresh run and emits no QR. Pick one."
  REUSE_ONLY=true
fi

# PLAN[] accumulates human-readable "would do" lines for --dry-run.
PLAN=()
plan_add() { PLAN+=("$*"); }

confirm() {  # confirm "question" -> 0 yes / 1 no
  local reply
  read -r -p "$1 [y/N] " reply
  case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

ask() {  # ask "prompt" "default" -> echoes answer (free-form; default optional)
  local reply
  read -r -p "$1${2:+ [$2]}: " reply
  printf '%s' "${reply:-${2:-}}"
}

# Value prompt with a clear, visually-distinct default (NOT a [y/N]). Echoes the
# resolved value back so a mis-typed answer is obvious immediately.
ask_default() {  # ask_default "prompt" "default" -> echoes resolved value
  local reply
  say "  $1" >&2
  read -r -p "  Press Enter to use: $2  (or type a value) > " reply
  reply="${reply:-$2}"
  printf '  %s→ using %s%s\n' "$DIM" "$reply" "$RESET" >&2
  printf '%s' "$reply"
}

# Secret prompt — never echoes the input to the terminal.
ask_secret() {  # ask_secret "prompt" -> echoes the secret (input hidden)
  local reply
  read -rs -p "  $1: " reply
  printf '\n' >&2
  printf '%s' "$reply"
}

# A choice with NO Enter-default — loops until the answer matches the regex.
# Callers capture this with $(), so EVERY human-facing line goes to stderr —
# a retry warning on stdout would be captured as part of the answer, and a typo
# would then silently decide a safety question. On EOF it RETURNS NONZERO rather
# than calling die: a `die` inside $() kills only the subshell, so the parent
# must be the one to stop (every caller pairs this with `|| die`).
require_choice() {  # require_choice "prompt" "regex" -> echoes the choice
  local reply
  while true; do
    read -r -p "  $1: " reply || return 1     # closed stdin — never spin the loop
    if [[ "$reply" =~ $2 ]]; then printf '%s' "$reply"; return 0; fi
    warn "Please enter one of the listed options." >&2
  done
}

NO_ANSWER="No answer (the input ended). Run me from a terminal, where I can ask you questions."

# A URL prompt that NEVER aborts on a typo — loops until it gets an https:// URL
# (or blank, when allow_blank=1, where leaving it out is a valid choice). Trims
# whitespace, accepts a capitalised scheme, always shows an example. All human
# output goes to stderr so $(...) captures only the URL.
ask_url() {  # ask_url "prompt" "example" [allow_blank] -> echoes the URL (or "")
  local prompt="$1" example="$2" allow_blank="${3:-0}" reply
  say "  $prompt" >&2
  while true; do
    read -r -p "  https URL (e.g. $example) > " reply || return 1   # EOF: caller dies (see require_choice)
    reply="${reply#"${reply%%[![:space:]]*}"}"; reply="${reply%"${reply##*[![:space:]]}"}"
    while [ "${reply%/}" != "$reply" ]; do reply="${reply%/}"; done   # trailing / would make //v1/… requests
    if [ -z "$reply" ]; then
      [ "$allow_blank" = "1" ] && return 0
      warn "Please enter an https:// URL, for example $example." >&2; continue
    fi
    case "$reply" in [Hh][Tt][Tt][Pp][Ss]://*) reply="https://${reply#*://}" ;; esac
    case "$reply" in
      https://?*) printf '  %s→ using %s%s\n' "$DIM" "$reply" "$RESET" >&2; printf '%s' "$reply"; return 0 ;;
      http://*)   warn "That's http:// — Conduck requires https:// (encrypted). Try again." >&2 ;;
      *)          warn "That has to start with https:// — for example $example. Try again." >&2 ;;
    esac
  done
}

# Rung 1 of the consent ladder: a single command we run for you, with consent.
# In --dry-run it is only recorded; in --reuse-only it is refused (see mutate_guard).
run_step() {  # run_step "description" cmd args...
  local desc="$1"; shift
  if $DRY_RUN; then plan_add "RUN  $*"; note "(dry-run: would run — $desc)"; return 0; fi
  mutate_guard "$desc" || return 1
  say ""
  say "  I'd like to run:  ${BOLD}$*${RESET}"
  if confirm "  Run it now?"; then "$@"; else
    warn "Skipped: $desc"
    return 1
  fi
}

# Rung 2: a change to something YOU own — we print the exact command, you run it.
print_and_wait() {  # print_and_wait "why" "command shown to user"
  if $DRY_RUN; then plan_add "YOU RUN  $2  ($1)"; note "(dry-run: you would run the above)"; return 0; fi
  mutate_guard "$1"
  say ""
  say "  This touches something you own, so you run it (copy-paste, e.g. in a"
  say "  second terminal):"
  say ""
  printf '    %s%s%s\n' "$BOLD" "$2" "$RESET"
  say ""
  note "$1"
  read -r -p "  Press Enter here once it's done (or 's' to skip): " reply
  [ "$reply" = "s" ] && return 1
  return 0
}

# --reuse-only safety: refuse any mutation that isn't a pure reuse of existing state.
mutate_guard() {  # mutate_guard "what would change"
  if $REUSE_ONLY; then
    die "--reuse-only mode is on, so I won't change anything (this step would: $1). Re-run without --reuse-only when you're ready to let me apply changes to this machine."
  fi
  return 0
}

need() { command -v "$1" >/dev/null 2>&1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Collect ALL missing required tools and report together, with install hints.
preflight() {
  local missing=()
  for t in curl python3 openssl; do need "$t" || missing+=("$t"); done
  if [ ${#missing[@]} -gt 0 ]; then
    bad "Missing required tool(s): ${missing[*]}"
    case "$(uname -s)" in
      Linux)  note "Install on Debian/Ubuntu:  sudo apt update && sudo apt install -y ${missing[*]}" ;;
      Darwin) note "Install with Homebrew:     brew install ${missing[*]}" ;;
    esac
    die "Install the tool(s) above, then re-run me."
  fi
}

sha256_hex() { # stdin -> lowercase hex digest
  if have sha256sum; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi
}

b64_nowrap() { # stdin -> single-line base64
  if base64 --help 2>&1 | grep -q -- '-w'; then base64 -w0; else base64 | tr -d '\n'; fi
}

json_get() { # json_get <file> <dotted.path>  (empty output when absent)
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    obj = json.load(open(sys.argv[1]))
    for part in sys.argv[2].split('.'):
        obj = obj[part]
    if obj is True: print("true")
    elif obj is False: print("false")
    elif obj is not None: print(obj)
except Exception:
    pass
PY
}

env_get() { # env_get <file> <KEY>  (last assignment wins; strips quotes)
  [ -f "$1" ] || return 0
  sed -n "s/^[[:space:]]*${2}=//p" "$1" | tail -1 | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/"
}

# Sanitize a free-form gateway name into a safe id token ([a-z0-9-], no injection).
slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//' | cut -c1-32; }

OS="$(uname -s)"   # Linux | Darwin
STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/conduck"

preflight

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
  local found=()
  [ -f "$HOME/.openclaw/openclaw.json" ] && found+=("openclaw")
  { [ -f "$HOME/.hermes/.env" ] || [ -d "$HOME/.hermes" ]; } && found+=("hermes")

  if [ -n "$MODE" ]; then
    GW_KIND=$([ "$MODE" = "generic" ] && echo "custom" || echo "$MODE")
    ok "Using --$MODE as requested."
    return
  fi

  if [ ${#found[@]} -gt 0 ]; then
    say "  Detected on this machine: ${BOLD}${found[*]}${RESET}"
  else
    say "  No OpenClaw or Hermes install detected in the usual places."
  fi

  # One detected → default to it. Zero or several → require an explicit pick.
  local default_choice=""
  if [ ${#found[@]} -eq 1 ]; then
    case "${found[0]}" in openclaw) default_choice=1 ;; hermes) default_choice=2 ;; esac
  fi

  say ""
  say "  Which gateway should Conduck talk to?"
  say "    1) OpenClaw $( [[ " ${found[*]-} " == *" openclaw "* ]] && echo '(detected)' )"
  say "    2) Hermes   $( [[ " ${found[*]-} " == *" hermes "* ]] && echo '(detected)' )"
  say "    3) Something else that speaks the OpenAI API (Ollama, LiteLLM, vLLM, your own adapter, …)"
  local choice
  if [ -n "$default_choice" ]; then
    # Enter takes the detected default; a typo re-prompts (never aborts).
    while true; do
      choice=$(ask "  Choose 1-3" "$default_choice")
      case "$choice" in [123]) break ;; *) warn "Please enter 1, 2, or 3 (or press Enter for $default_choice)." ;; esac
    done
  else
    choice=$(require_choice "Choose 1-3" '^[123]$') || die "$NO_ANSWER"
  fi
  case "$choice" in
    1) GW_KIND="openclaw" ;;
    2) GW_KIND="hermes" ;;
    3) GW_KIND="custom" ;;
    *) die "Invalid choice." ;;   # unreachable; a silent fallthrough would leave GW_KIND unset
  esac
}

configure_openclaw() {
  head_ "Step 2 — OpenClaw: chat endpoint + token"
  GW_ID="openclaw"
  local cfg="$HOME/.openclaw/openclaw.json"
  [ -f "$cfg" ] || die "Cannot find $cfg — is OpenClaw onboarded on this machine? (Run its onboarding first; this script doesn't install gateways.)"

  # Port: host publish from the compose .env (OPENCLAW_GATEWAY_PORT=127.0.0.1:18789), default 18789.
  local compose_dir="${OPENCLAW_DIR:-$HOME/openclaw}"
  local port_raw; port_raw=$(env_get "$compose_dir/.env" "OPENCLAW_GATEWAY_PORT")
  GW_LOCAL_PORT="${port_raw##*:}"; GW_LOCAL_PORT="${GW_LOCAL_PORT:-18789}"
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
    enabled=$(json_get "$cfg" "gateway.http.endpoints.chatCompletions.enabled")
    [ "$enabled" = "true" ] && ok "Chat endpoint is now enabled." \
      || warn "Could not confirm the flag in $cfg — verification below will tell us for sure."
  fi

  # The REAL runtime token is gateway.auth.token in openclaw.json (the .env value
  # is only an onboarding seed and can drift from what the gateway actually checks).
  GW_TOKEN=$(json_get "$cfg" "gateway.auth.token")
  if [ -n "$GW_TOKEN" ]; then
    ok "Read the gateway bearer token (the secret key the app sends to log in) from openclaw.json (not shown)."
  elif $DRY_RUN; then
    note "(dry-run: would prompt for the gateway bearer token)"
  else
    warn "No token found at gateway.auth.token in $cfg."
    GW_TOKEN=$(ask_secret "Paste the gateway bearer token — the secret key the gateway checks on each request (hidden)")
    [ -n "$GW_TOKEN" ] || die "OpenClaw needs its access token (the secret key the gateway checks). Find it in openclaw.json under gateway.auth.token, then re-run."
  fi
  GW_AUTH="bearer"
}

configure_hermes() {
  head_ "Step 2 — Hermes: API server + key"
  GW_ID="hermes"
  local envf="$HOME/.hermes/.env"
  [ -d "$HOME/.hermes" ] || die "Cannot find ~/.hermes — is Hermes installed for this user? (This script doesn't install gateways.)"

  local enabled; enabled=$(env_get "$envf" "API_SERVER_ENABLED")
  GW_LOCAL_PORT=$(env_get "$envf" "API_SERVER_PORT"); GW_LOCAL_PORT="${GW_LOCAL_PORT:-8642}"
  GW_HEALTH_PATH="/v1/health"

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
probe_single_model() { # probe_single_model <local_port>
  [ -n "$1" ] || return 0
  curl -sS --max-time 5 "http://127.0.0.1:$1/v1/models" 2>/dev/null | python3 -c '
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

# ------------------------------------------------------------ exposure phase --

TRANSPORT=""       # tailscale | funnel | cloudflare | public | selfsigned
SCOPE="unknown"    # private | public | unknown  (actual reachability, NOT the label)
TS_STATE_KNOWN=true
declare -a TS_PORTS=()        # "port<TAB>verb<TAB>proxy" lines from ts_targets
declare -a TS_HOSTS=()        # unique lowercased tailnet hostnames serving on THIS machine (from ts_targets)
declare -a TS_MAPS=()         # "host<TAB>port<TAB>verb<TAB>proxy" per mapping (host lowercased) — show-qr's host-qualified assert
declare -a APPLIED=()         # "port<TAB>applied-verb<TAB>prior-state" snapshots for cleanup (gateway)
declare -a FS_APPLIED=()      # same, but for the OPTIONAL file lane — rolled back on its own when the
                              # lane is dropped post-mutation, so a public Funnel is never orphaned
FS_HTTPS_PORT=""              # chosen at exposure time (transport-aware)
FS_ROLLBACK_INCOMPLETE=false  # a file-lane exposure we applied could not be proven removed

# The one undo recipe, used by every path that has to tell the user how to put a
# port back: a funnel WE created needs its OWN `off` (`serve off` clears the web
# handler but NOT the AllowFunnel flag, so public exposure would survive).
print_undo_hints() { # print_undo_hints <"port\tapplied-verb\tprior">…
  local entry port rest averb prior pverb pproxy
  for entry in "$@"; do
    [ -n "$entry" ] || continue
    port="${entry%%$'\t'*}"; rest="${entry#*$'\t'}"
    averb="${rest%%$'\t'*}"; prior="${rest#*$'\t'}"
    if [ "$averb" = "funnel" ]; then
      printf '    %stailscale funnel --https=%s off%s   # remove PUBLIC exposure\n' "$BOLD" "$port" "$RESET"
    fi
    if [ "$prior" = "EMPTY" ]; then
      printf '    %stailscale serve --https=%s off%s\n' "$BOLD" "$port" "$RESET"
    else
      pverb="${prior%%$'\t'*}"; pproxy="${prior#*$'\t'}"
      printf '    %stailscale %s --bg --https=%s %s%s   # restore previous mapping\n' "$BOLD" "$pverb" "$port" "$pproxy" "$RESET"
    fi
  done
}

tailscale_dns_name() {
  tailscale status --json 2>/dev/null | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin); n=d.get("Self",{}).get("DNSName","")
    print(n.rstrip("."))
except Exception: pass'
}

# Parse `tailscale serve status --json` into "port<TAB>verb<TAB>proxy" lines (TS_PORTS)
# plus one "HOST<TAB>hostname" line per unique serving host (→ TS_HOSTS) and one
# "MAP<TAB>host<TAB>port<TAB>verb<TAB>proxy" line per mapping (→ TS_MAPS, for show-qr's
# host-qualified assert — a matching port on a DIFFERENT hostname must not count).
# TS_PORTS' line format is UNCHANGED — several consumers split it on tabs.
# FAIL CLOSED: on any parse/exec error TS_STATE_KNOWN=false (caller refuses to mutate).
ts_targets() {
  TS_PORTS=(); TS_HOSTS=(); TS_MAPS=(); TS_STATE_KNOWN=true
  local raw; raw=$(tailscale serve status --json 2>/dev/null) || { TS_STATE_KNOWN=false; return 0; }
  [ -n "$raw" ] || return 0   # genuinely no targets is fine (empty, but known)
  local parsed
  parsed=$(printf '%s' "$raw" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(3)
web=d.get("Web") or {}
af=d.get("AllowFunnel") or {}
print("OK")
# Emit each unique serving HOST (hostport minus the trailing :port, lowercased) BEFORE
# the port lines so the caller can prove the profile URL names THIS machine.
seen=set()
for hostport in web.keys():
    host=hostport.rsplit(":",1)[0].lower()
    if host and host not in seen:
        seen.add(host)
        print(f"HOST\t{host}")
for hostport,conf in web.items():
    host=hostport.rsplit(":",1)[0].lower()
    port=hostport.rsplit(":",1)[-1]
    proxy=""
    for _,h in ((conf or {}).get("Handlers") or {}).items():
        proxy=(h or {}).get("Proxy","") or proxy
    verb="funnel" if af.get(hostport) else "serve"
    print(f"MAP\t{host}\t{port}\t{verb}\t{proxy}")
    print(f"{port}\t{verb}\t{proxy}")
') || { TS_STATE_KNOWN=false; return 0; }
  # First line must be the OK sentinel, else treat as unknown.
  [ "${parsed%%$'\n'*}" = "OK" ] || { TS_STATE_KNOWN=false; return 0; }
  local line first=true
  while IFS= read -r line; do
    if $first; then first=false; continue; fi   # skip OK
    [ -n "$line" ] || continue
    case "$line" in
      HOST$'\t'*) TS_HOSTS+=("${line#HOST$'\t'}") ;;   # host line → TS_HOSTS (additive; port consumers unaffected)
      MAP$'\t'*)  TS_MAPS+=("${line#MAP$'\t'}") ;;     # mapping tuple → TS_MAPS (additive, show-qr only)
      *)          TS_PORTS+=("$line") ;;               # unchanged "port<TAB>verb<TAB>proxy"
    esac
  done <<< "$parsed"
}

ts_target_for_port() { # echoes "verb<TAB>proxy" for <port>, empty if free
  local p="$1" line
  for line in "${TS_PORTS[@]-}"; do
    [ "${line%%$'\t'*}" = "$p" ] && { printf '%s' "${line#*$'\t'}"; return 0; }
  done
}

# Reverse lookup: find the https port already mapped to a given local backend
# (e.g. the file lane's own port). Echoes "httpsport<TAB>verb", empty if none.
ts_port_for_backend() { # ts_port_for_backend <local-port>
  local lp="$1" line port rest verb proxy
  for line in "${TS_PORTS[@]-}"; do
    port="${line%%$'\t'*}"; rest="${line#*$'\t'}"
    verb="${rest%%$'\t'*}"; proxy="${rest#*$'\t'}"
    [ "$proxy" = "http://127.0.0.1:$lp" ] && { printf '%s\t%s' "$port" "$verb"; return 0; }
  done
}

# Pick a public HTTPS port for a backend, transport-aware. Reuses our own mapping;
# never clobbers a different backend. role = "gateway" | "file". Sets PICKED_PORT.
# (Sets a global rather than echoing so an internal `die` halts the WHOLE script —
# a `die` inside $() would only kill the subshell and let main continue.)
PICKED_PORT=""
RESERVED_PORTS=" "   # ports already chosen THIS run (so gateway + file lane never collide, incl. dry-run)
pick_public_port() { # pick_public_port <transport> <local_port> <role>
  local transport="$1" role="$3" want="http://127.0.0.1:$2"
  local want_verb="serve"; [ "$transport" = "funnel" ] && want_verb="funnel"   # transport label → tailscale verb
  PICKED_PORT=""
  $TS_STATE_KNOWN || die "Could not read 'tailscale serve status --json' — refusing to guess port state. Update Tailscale or check 'tailscale serve status'."
  local candidates
  if [ "$transport" = "funnel" ]; then candidates="443 8443 10000"; else candidates="443 8443 8444 9443 10000"; fi
  # 1) Reuse a port already mapped to THIS backend with the matching verb.
  local p t verb proxy
  for p in $candidates; do
    case "$RESERVED_PORTS" in *" $p "*) continue ;; esac
    t=$(ts_target_for_port "$p"); [ -n "$t" ] || continue
    verb="${t%%$'\t'*}"; proxy="${t#*$'\t'}"
    if [ "$proxy" = "$want" ] && [ "$verb" = "$want_verb" ]; then PICKED_PORT="$p"; RESERVED_PORTS="$RESERVED_PORTS$p "; return 0; fi
  done
  # 1b) Same backend, OTHER verb → pick THAT port so the mapping is flipped in
  # place (caller warns + confirms). Allocating a fresh port here would leave the
  # old exposure live — e.g. a "go private" run that quietly keeps an old public
  # Funnel serving the same gateway.
  for p in $candidates; do
    case "$RESERVED_PORTS" in *" $p "*) continue ;; esac
    t=$(ts_target_for_port "$p"); [ -n "$t" ] || continue
    proxy="${t#*$'\t'}"
    if [ "$proxy" = "$want" ]; then PICKED_PORT="$p"; RESERVED_PORTS="$RESERVED_PORTS$p "; return 0; fi
  done
  # 2) First permitted port that is neither reserved this run nor already mapped.
  for p in $candidates; do
    case "$RESERVED_PORTS" in *" $p "*) continue ;; esac
    [ -z "$(ts_target_for_port "$p")" ] && { PICKED_PORT="$p"; RESERVED_PORTS="$RESERVED_PORTS$p "; return 0; }
  done
  # 3) None free. The file lane is OPTIONAL — skip it rather than abort the pairing.
  if [ "$role" = "file" ]; then
    warn "No free HTTPS port for the file lane on this transport — skipping the file lane." >&2
    return 1
  fi
  if [ "$transport" = "funnel" ]; then
    die "All three ports Tailscale Funnel can use (443, 8443, 10000) are already taken by other services on this machine. Run 'tailscale serve status' to see what's using them and free one, OR re-run and pick option 1 (Tailscale, private), which isn't limited to those three ports."
  fi
  die "No free HTTPS port found for the gateway on this transport."
}

snapshot_port() { # snapshot_port <port> <verb> [role] — record prior state + the verb WE apply
  local p="$1" verb="$2" role="${3:-gateway}" t; t=$(ts_target_for_port "$p")
  if [ "$role" = "file" ]; then FS_APPLIED+=("$p"$'\t'"$verb"$'\t'"${t:-EMPTY}")
  else APPLIED+=("$p"$'\t'"$verb"$'\t'"${t:-EMPTY}"); fi
}

# Run a serve/funnel mapping, then CONFIRM it actually took (never trust Enter).
tailscale_expose() { # tailscale_expose <https-port> <local-port> <funnel:true/false> <role>
  local httpsport="$1" localport="$2" funnel="$3" role="$4"
  local verb="serve"; [ "$funnel" = "true" ] && verb="funnel"
  local cmd="tailscale $verb --bg --https=$httpsport http://127.0.0.1:$localport"

  # Already exactly what we want? No-op.
  local t verb_now proxy_now; t=$(ts_target_for_port "$httpsport")
  if [ -n "$t" ]; then
    verb_now="${t%%$'\t'*}"; proxy_now="${t#*$'\t'}"
    if [ "$proxy_now" = "http://127.0.0.1:$localport" ] && [ "$verb_now" = "$verb" ]; then
      ok "Already exposed: https port $httpsport → 127.0.0.1:$localport ($verb). Reusing."
      return 0
    fi
  fi

  # Verb flip funnel→serve: a new `serve` mapping can leave the AllowFunnel flag
  # on (the port would still be public), so the flip drops the funnel explicitly
  # first; the verb-match confirm below then proves the port really went private.
  local demote=false demote_cmd="tailscale funnel --https=$httpsport off"
  [ -n "$t" ] && [ "${t%%$'\t'*}" = "funnel" ] && [ "$verb" = "serve" ] && demote=true

  say ""
  say "  Mapping: https port $httpsport  →  127.0.0.1:$localport  (${verb})"
  if $DRY_RUN; then
    $demote && plan_add "RUN  $demote_cmd   # drop the public Funnel before going private"
    plan_add "RUN  $cmd"; note "(dry-run: would run the above)"; return 0
  fi
  mutate_guard "expose port $httpsport via tailscale $verb" || return 1
  if confirm "  Run '$cmd' now?"; then
    # Snapshot only once the user has AGREED — a declined confirm must leave no
    # rollback record for a port we never touched.
    snapshot_port "$httpsport" "$verb" "$role"
    if $demote; then tailscale funnel --https="$httpsport" off 2>/dev/null || true; fi
    $cmd 2>/dev/null || {
      warn "That needs elevated rights on this machine."
      local fallback="sudo $cmd"
      $demote && fallback="sudo $demote_cmd; sudo $cmd"
      print_and_wait "Tailscale serve/funnel often needs sudo (or operator rights)." "$fallback" || { return 1; }
    }
  else
    return 1
  fi
  # Re-parse status and CONFIRM the mapping is present — matching BOTH target and verb
  # (a leftover private Serve must not be mistaken for a requested public Funnel).
  ts_targets
  t=$(ts_target_for_port "$httpsport")
  if [ -n "$t" ] && [ "${t#*$'\t'}" = "http://127.0.0.1:$localport" ] && [ "${t%%$'\t'*}" = "$verb" ]; then
    ok "Confirmed: https port $httpsport is mapped to 127.0.0.1:$localport ($verb)."
    return 0
  fi
  bad "Could not confirm the $httpsport mapping as '$verb' in 'tailscale status' — treating as failed."
  return 1
}

# Restore (cleanup) any exposures we applied — used on failure before a QR.
# Covers BOTH the gateway (APPLIED) and the file lane (FS_APPLIED).
cleanup_exposures() {
  local all=(); all+=( ${APPLIED[@]+"${APPLIED[@]}"} ); all+=( ${FS_APPLIED[@]+"${FS_APPLIED[@]}"} )
  [ ${#all[@]} -gt 0 ] || return 0
  say ""
  warn "Some exposure changes were applied but verification did not pass."
  warn "Here is how to put each affected port back the way it was:"
  print_undo_hints "${all[@]}"
  say ""
  if ! $REUSE_ONLY && confirm "  Run these cleanup commands now?"; then
    # Reverse order: the LAST mapping applied is undone first, so when two records
    # touch one port the earliest-recorded prior state is the one that survives.
    local i entry port rest averb prior pverb pproxy
    for (( i=${#all[@]}-1; i>=0; i-- )); do
      entry="${all[$i]}"
      port="${entry%%$'\t'*}"; rest="${entry#*$'\t'}"
      averb="${rest%%$'\t'*}"; prior="${rest#*$'\t'}"
      if [ "$averb" = "funnel" ]; then tailscale funnel --https="$port" off 2>/dev/null || true; fi
      if [ "$prior" = "EMPTY" ]; then tailscale serve --https="$port" off 2>/dev/null || true
      else
        pverb="${prior%%$'\t'*}"; pproxy="${prior#*$'\t'}"
        tailscale "$pverb" --bg --https="$port" "$pproxy" 2>/dev/null || true
      fi
    done
    ok "Cleanup attempted — verify with 'tailscale serve status' and 'tailscale funnel status'."
  fi
  APPLIED=(); FS_APPLIED=()   # handled — don't let the EXIT backstop repeat it
}

# Remove a Tailscale mapping we are SUPERSEDING — used only by the different-port
# file-lane promote (a new public Funnel is already up; drop the old private Serve).
# Rollback-records the old mapping FIRST (snapshot_port) so an abort restores it,
# instead of orphaning the lane. Respects --dry-run and --reuse-only.
ts_unmap() { # ts_unmap <port> <verb>
  local port="$1" verb="$2"
  case "$verb" in serve|funnel) ;; *) return 0 ;; esac
  case "$port" in ''|*[!0-9]*) return 0 ;; esac
  if $DRY_RUN; then
    plan_add "RUN  tailscale $verb --https=$port off   # remove the now-superseded $verb mapping"
    note "(dry-run: would remove the old $verb mapping on port $port)"
    return 0
  fi
  mutate_guard "remove the old $verb mapping on port $port" || return 1
  snapshot_port "$port" "$verb" file        # record (in FS_APPLIED) so cleanup can restore it
  tailscale "$verb" --https="$port" off 2>/dev/null || {
    warn "That needs elevated rights on this machine."
    print_and_wait "Removing a Tailscale mapping often needs sudo (or operator rights)." \
      "sudo tailscale $verb --https=$port off" || true
  }
  # FAIL CLOSED: only claim removal a status re-parse can prove.
  ts_targets
  if ! $TS_STATE_KNOWN; then
    warn "Could not re-read Tailscale status — cannot confirm port $port was cleared. Check 'tailscale serve status'."
  elif [ -z "$(ts_target_for_port "$port")" ]; then
    ok "Removed the old $verb mapping on port $port — the file lane now rides the public exposure."
  else
    warn "Port $port still carries a mapping — run: tailscale $verb --https=$port off"
  fi
}

# Undo ONLY the file-lane exposure changes applied this run (FS_APPLIED), best-effort +
# non-interactive. Called when the file lane is dropped AFTER its exposure was applied
# (e.g. a failed WebDAV probe), so a public Funnel is never left live while the lane is
# omitted from the QR. Restores each affected port's prior mapping.
rollback_fs_exposures() {
  [ ${#FS_APPLIED[@]} -gt 0 ] || return 0
  if $DRY_RUN; then FS_APPLIED=(); return 0; fi
  local entry port rest averb prior pverb pproxy
  for entry in "${FS_APPLIED[@]}"; do
    port="${entry%%$'\t'*}"; rest="${entry#*$'\t'}"
    averb="${rest%%$'\t'*}"; prior="${rest#*$'\t'}"
    if [ "$averb" = "funnel" ]; then tailscale funnel --https="$port" off 2>/dev/null || true; fi
    if [ "$prior" = "EMPTY" ]; then tailscale serve --https="$port" off 2>/dev/null || true
    else pverb="${prior%%$'\t'*}"; pproxy="${prior#*$'\t'}"; tailscale "$pverb" --bg --https="$port" "$pproxy" 2>/dev/null || true; fi
  done
  # FAIL CLOSED: claim success only when a status re-parse PROVES each port is
  # back to its prior state. Otherwise keep the record (the EXIT backstop and
  # cleanup_exposures still act on it) and say so — never "all clear" on faith.
  ts_targets
  local leftover=() t want
  for entry in "${FS_APPLIED[@]}"; do
    port="${entry%%$'\t'*}"; rest="${entry#*$'\t'}"; prior="${rest#*$'\t'}"
    want=""; [ "$prior" != "EMPTY" ] && want="$prior"
    t=$(ts_target_for_port "$port")
    if ! $TS_STATE_KNOWN || [ "${t:-}" != "$want" ]; then leftover+=("$entry"); fi
  done
  if [ ${#leftover[@]} -eq 0 ]; then
    note "Rolled back the file-lane exposure — confirmed no public file server is left behind."
    FS_APPLIED=()
  else
    # Keep the record AND remember the failure: emit_payload must not close a run
    # with a green QR while a file server we exposed is still reachable.
    FS_ROLLBACK_INCOMPLETE=true
    warn "Could not confirm the file-lane exposure was fully rolled back."
    warn "Check 'tailscale serve status' / 'tailscale funnel status'. To undo by hand:"
    print_undo_hints ${leftover[@]+"${leftover[@]}"}
    FS_APPLIED=( "${leftover[@]}" )
  fi
}

# Drop the file lane from the pairing AND undo any exposure we applied for it.
drop_file_lane() { rollback_fs_exposures; FS_URL=""; FS_CRED=""; }

# Backstop: if the script exits (incl. a `die`) AFTER applying exposures but BEFORE
# emitting a code, print exactly how to undo them. Non-interactive (safe in a trap).
EMITTED=false
on_exit() {
  $DRY_RUN && return 0
  local all=(); all+=( ${APPLIED[@]+"${APPLIED[@]}"} ); all+=( ${FS_APPLIED[@]+"${FS_APPLIED[@]}"} )
  [ ${#all[@]} -gt 0 ] || return 0
  # A successful run normally has nothing to undo. The exception: a file-lane
  # rollback that could NOT be proven — that exposure may still be live, so the
  # undo hints must survive even a green QR.
  if $EMITTED && ! $FS_ROLLBACK_INCOMPLETE; then return 0; fi
  say ""
  if $EMITTED; then
    warn "A file-lane exposure this run applied could NOT be confirmed removed. It may still be reachable. To undo it:"
  else
    warn "Exited before emitting a setup code, but exposure changes were applied. To undo them:"
  fi
  print_undo_hints "${all[@]}"
}
trap on_exit EXIT

# An EARLIER run (or a hand setup) may still expose the SAME local backend
# publicly on a DIFFERENT port. A private choice must not leave that live
# silently. Removal here is INTENTIONAL, so it is deliberately NOT recorded in
# APPLIED/FS_APPLIED — those drive "undo my changes", and re-creating a public
# Funnel the user just asked to kill is never the right rollback.
sweep_stale_public_funnels() { # sweep_stale_public_funnels <local-port> <keep-port> <host>
  local localport="$1" keep="$2" host="$3"
  $TS_STATE_KNOWN || return 0     # unknown state: pick_public_port already died; nothing to assert
  local rline rport rrest rverb rproxy off_cmd
  for rline in ${TS_PORTS[@]+"${TS_PORTS[@]}"}; do
    rport="${rline%%$'\t'*}"; rrest="${rline#*$'\t'}"
    rverb="${rrest%%$'\t'*}"; rproxy="${rrest#*$'\t'}"
    [ "$rproxy" = "http://127.0.0.1:$localport" ] || continue
    [ "$rverb" = "funnel" ] || continue
    [ "$rport" != "$keep" ] || continue
    warn "Port $rport ALSO exposes this backend PUBLICLY (Tailscale Funnel), from an earlier setup."
    off_cmd="tailscale funnel --https=$rport off"
    if $DRY_RUN; then
      plan_add "OFFER  $off_cmd (+ serve off)   # stale public exposure of this backend"
      note "(dry-run: would offer to turn that stale public exposure off)"
      continue
    fi
    if $REUSE_ONLY; then
      warn "(--reuse-only: leaving it as-is — re-run without --reuse-only to remove it.)"
      continue
    fi
    if ! confirm "  Turn that public exposure off now?"; then
      warn "Leaving it live: this backend stays reachable at https://$host:$rport from the internet."
      continue
    fi
    # Reserve it so the file lane can't allocate the port we're clearing.
    RESERVED_PORTS="$RESERVED_PORTS$rport "
    if ! { tailscale funnel --https="$rport" off 2>/dev/null \
           && tailscale serve --https="$rport" off 2>/dev/null; }; then
      warn "That needs elevated rights on this machine."
      print_and_wait "Removing a public Funnel often needs sudo (or operator rights)." \
        "sudo $off_cmd; sudo tailscale serve --https=$rport off" || true
    fi
    # FAIL CLOSED: an unreadable status is NOT proof of removal.
    ts_targets
    if ! $TS_STATE_KNOWN; then
      warn "Could not re-read Tailscale status — cannot confirm port $rport is closed. Check 'tailscale funnel status'."
    elif [ -z "$(ts_target_for_port "$rport")" ]; then
      ok "Port $rport is no longer exposed."
    else
      warn "Port $rport is STILL exposed — run: $off_cmd"
    fi
  done
}

choose_exposure() {
  # Generic with a ready URL skips the transport menu — but still classifies the
  # certificate (trust-or-pin), exactly like menu option 4.
  if [ -n "$GW_URL" ] && [ -z "$GW_LOCAL_PORT" ]; then
    head_ "Step 3 — HTTPS reachability"
    ok "Using your existing URL: $GW_URL"
    scope_choice
    keyless_public_guard
    classify_own_https
    return
  fi

  head_ "Step 3 — how should your phone reach this gateway?"
  ts_targets
  local ts_state="not installed" cf_state="not installed"
  if have tailscale; then
    if [ -n "$(tailscale_dns_name)" ]; then ts_state="✓ detected and running"
    else ts_state="installed, but not running/logged in"; fi
  fi
  have cloudflared && cf_state="✓ cloudflared found"

  say ""
  say "  1) ${BOLD}Tailscale${RESET} (private — also called Tailscale Serve)  ($ts_state)"
  say "     Private: only your own Tailscale devices (your \"tailnet\") reach it. Free."
  say "     Data path: device → gateway, nobody in between. Your phone needs the"
  say "     Tailscale app too (iPhone or Android)."
  say "     Apple Watch: works only while near your iPhone (no Tailscale on the Watch)."
  say ""
  say "  2) ${BOLD}Tailscale Funnel${RESET}  ($ts_state)"
  say "     Same as above but PUBLICLY reachable (TLS passes through end-to-end). Free."
  say "     No app needed on your Apple devices."
  say "     Apple Watch: works on its own, anywhere."
  say "     Anyone who finds the URL can knock — your bearer token (the gateway's"
  say "     secret key) is the lock."
  say ""
  say "  3) ${BOLD}Cloudflare Tunnel${RESET}  ($cf_state)"
  say "     Public hostname on a domain you already manage in Cloudflare (~\$8/yr);"
  say "     nothing to install on Apple devices. Data path: device → Cloudflare's"
  say "     edge → gateway — Cloudflare can see the traffic."
  say "     Apple Watch: works on its own, anywhere."
  say ""
  say "  4) ${BOLD}I already run my own HTTPS for it${RESET}"
  say "     (a reverse proxy, a VPS, or your own/self-signed certificate — I detect"
  say "     which). You give the https:// address; I check the certificate and either"
  say "     let the app trust it normally or pin it for you. No need to know which."
  say "     Apple Watch: works on its own if that address is reachable without Tailscale/VPN."
  say ""
  say "  ${DIM}b) go back to the gateway choice${RESET}"
  say ""
  note "The biggest practical difference between these: an Apple Watch used away from"
  note "your iPhone can reach a PUBLIC path (2, 3, or 4), never a private one (1)."
  say ""
  local choice; choice=$(require_choice "Choose 1-4, or 'b' to go back" '^([1-4]|[bB])$') || die "$NO_ANSWER"
  [[ "$choice" =~ ^[bB]$ ]] && return 10   # back — main re-runs gateway selection (nothing applied yet)
  $DRY_RUN || note "From here I may apply changes to this machine; to change an earlier choice, stop (Ctrl-C) and re-run."

  case "$choice" in
    1|2)
      local funnel=false; [ "$choice" = "2" ] && funnel=true
      TRANSPORT=$($funnel && echo funnel || echo tailscale)
      SCOPE=$($funnel && echo public || echo private)
      if ! have tailscale; then
        say ""
        warn "Tailscale isn't installed, and installing it is yours to do (we never"
        warn "install daemons). It's one command from https://tailscale.com/download —"
        warn "then re-run this script; it picks up where you left off."
        exit 0
      fi
      if [ -z "$(tailscale_dns_name)" ]; then
        say ""
        warn "Tailscale is installed but not logged in on this machine."
        warn "Run 'sudo tailscale up' to connect it to your tailnet (your private Tailscale"
        warn "network) — it opens a browser link to sign in the first time. Then re-run this"
        warn "script; it picks up where you left off."
        exit 0
      fi
      keyless_public_guard
      local host; host=$(tailscale_dns_name)
      pick_public_port "$TRANSPORT" "$GW_LOCAL_PORT" "gateway"; local gw_https="$PICKED_PORT"
      ok "Chosen public port for the gateway: $gw_https"
      # A verb flip changes who can reach the gateway — say so, in BOTH directions.
      local existing; existing=$(ts_target_for_port "$gw_https")
      if [ -n "$existing" ]; then
        local everb="${existing%%$'\t'*}"
        if $funnel && [ "$everb" = "serve" ]; then
          warn "Port $gw_https is currently PRIVATE (Serve). Switching it to Funnel makes"
          warn "https://$host:$gw_https reachable from the public internet."
          confirm "  Make it public?" || die "Left private. Re-run and pick option 1 (Tailscale, private) to stay private."
        elif ! $funnel && [ "$everb" = "funnel" ]; then
          warn "Port $gw_https is currently PUBLIC (Tailscale Funnel). Going private turns the"
          warn "public URL off — afterwards only devices on your tailnet reach this gateway."
          confirm "  Make it private (turn the public URL off)?" || die "Left public. Re-run and pick option 2 (Tailscale Funnel) if public is what you want."
        fi
      fi
      tailscale_expose "$gw_https" "$GW_LOCAL_PORT" "$funnel" "gateway" \
        || { cleanup_exposures; die "Gateway exposure not confirmed — cannot continue without an HTTPS URL."; }
      GW_URL="https://$host"; [ "$gw_https" != "443" ] && GW_URL="https://$host:$gw_https"
      if [ "$SCOPE" = "private" ]; then
        sweep_stale_public_funnels "$GW_LOCAL_PORT" "$gw_https" "$host"
      fi
      ;;
    3)
      TRANSPORT="cloudflare"; SCOPE="public"
      keyless_public_guard
      if ! have cloudflared; then
        say ""
        warn "cloudflared isn't installed. Set up a tunnel per Cloudflare's quickstart"
        warn "(https://developers.cloudflare.com/cloudflare-one/), then re-run me."
        exit 0
      fi
      local tunnel; tunnel=$(cloudflared tunnel list 2>/dev/null | awk 'NR>1{print $2}' | head -2)
      local tname="<your-tunnel>"
      [ "$(printf '%s\n' "$tunnel" | grep -c .)" = "1" ] && tname="$tunnel"
      say ""
      say "  Your tunnel config (usually ~/.cloudflared/config.yml) needs one 'ingress rule'"
      say "  per service — a line that tells Cloudflare to send requests for a hostname to a"
      say "  local port. For the gateway:"
      say ""
      say "      - hostname: ${BOLD}gateway.YOURDOMAIN${RESET}"
      say "        service: http://127.0.0.1:$GW_LOCAL_PORT"
      note "(127.0.0.1 means \"this same machine\" — keep it as-is if the gateway runs on this host.)"
      say ""
      if $REUSE_ONLY; then
        note "(reuse-only: assuming your gateway ingress rule already exists — I won't guide changes)"
      else
        print_and_wait "Add the ingress rule, route DNS for the new hostname, and restart cloudflared. Replace YOURDOMAIN with a host on your Cloudflare domain." \
          "cloudflared tunnel route dns $tname gateway.YOURDOMAIN" || true
      fi
      local h; h=$(ask "  The gateway hostname you configured (e.g. gateway.example.com)" "")
      [ -n "$h" ] || die "No hostname given. This option needs a domain already added to your Cloudflare account; if you don't have one yet, re-run and pick Tailscale instead, or add a domain in Cloudflare first."
      GW_URL="https://$h"
      ;;
    4)
      # One option for "I run my own HTTPS." The script figures out whether the
      # certificate is publicly trusted (no pin) or self-managed (pin its SPKI).
      GW_URL=$(ask_url "The https:// web address that reaches your gateway" "https://ai.example.com") || die "$NO_ANSWER"
      scope_choice
      keyless_public_guard
      classify_own_https   # sets TRANSPORT=public|selfsigned (+ GW_CERT_FP); STOPs on a broken cert
      ;;
    *) die "Invalid choice." ;;
  esac
}

# Ask whether the URL is publicly reachable. Safety-relevant (it gates the
# keyless-public guard), so it takes an explicit 1/2 — no Enter default a typo
# could fall into. Sets SCOPE.
scope_choice() {
  note "Rule of thumb: if you could open this address from your phone on cellular (Wi-Fi off),"
  note "it's public; if it only works on your home/office network or a VPN like Tailscale, it's private."
  say "    1) Public — reachable from the open internet"
  say "    2) Private — only my own network / VPN (Tailscale, home or office LAN)"
  local c; c=$(require_choice "Is this address public or private? Choose 1-2" '^[12]$') || die "$NO_ANSWER"
  if [ "$c" = "1" ]; then SCOPE="public"; else SCOPE="private"; fi
}

# Refuse to publish a keyless gateway unless explicitly overridden.
keyless_public_guard() {
  [ "$GW_AUTH" = "none" ] || return 0
  [ "$SCOPE" = "public" ] || return 0
  if $ALLOW_KEYLESS_PUBLIC; then
    warn "Publishing a KEYLESS gateway because --allow-keyless-public was passed. Anyone who finds the URL can use your agent."
    return 0
  fi
  bad "This gateway has NO authentication, and this transport is publicly reachable."
  say  "  That would put an unauthenticated, tool-capable agent on the open internet."
  say  "  Safer options: keep it tailnet-only (Tailscale Serve), or put a token on the"
  say  "  gateway itself. If you truly mean to, re-run with --allow-keyless-public."
  die "Refusing to publish a keyless gateway."
}

# Self-signed SPKI: compute the lowercase hex digest (for the QR) AND validate the
# key algorithm is one the app can actually pin. Echoes hex on success.
compute_spki_hex() { # compute_spki_hex <https-url>
  local url="$1" hostport
  hostport="${url#https://}"; hostport="${hostport%%/*}"   # split: bash 3.2 won't see url mid-`local`
  case "$hostport" in *:*) ;; *) hostport="$hostport:443" ;; esac
  local der; der=$(mktemp); local cert; cert=$(mktemp)
  trap 'rm -f "$der" "$cert"' RETURN
  openssl s_client -connect "$hostport" -servername "${hostport%%:*}" </dev/null 2>/dev/null \
    | openssl x509 -outform PEM > "$cert" 2>/dev/null
  [ -s "$cert" ] || return 1
  # Reject key types the app's pinner does not support (RSA 2048/3072/4096, EC P-256/P-384).
  # Diagnostics go to stderr — stdout is reserved for the hex digest (captured by $()).
  local algline; algline=$(openssl x509 -in "$cert" -noout -text 2>/dev/null)
  if printf '%s' "$algline" | grep -qi 'ED25519\|ED448'; then
    bad "That certificate uses an Ed25519/Ed448 key, which the Conduck app cannot pin." >&2; return 1
  fi
  if printf '%s' "$algline" | grep -qi 'Public Key Algorithm: id-ecPublicKey'; then
    printf '%s' "$algline" | grep -qi 'prime256v1\|secp384r1' \
      || { bad "That EC curve isn't supported (app pins only P-256 / P-384)." >&2; return 1; }
  elif printf '%s' "$algline" | grep -qi 'Public Key Algorithm: rsaEncryption'; then
    printf '%s' "$algline" | grep -qiE 'Public-Key: \((2048|3072|4096) bit\)' \
      || { bad "That RSA key size isn't supported (app pins only 2048/3072/4096-bit)." >&2; return 1; }
  else
    # Fail CLOSED: anything not RSA/EC above (DSA, RSA-PSS, Ed25519/Ed448, unknown) is unpinnable.
    bad "That certificate's key type isn't one the Conduck app can pin (needs RSA-2048/3072/4096 or EC P-256/P-384)." >&2; return 1
  fi
  openssl x509 -in "$cert" -pubkey -noout 2>/dev/null \
    | openssl pkey -pubin -outform DER 2>/dev/null > "$der"
  [ -s "$der" ] || return 1
  sha256_hex < "$der"
}

# Read the leaf cert's openssl verify return code — the stable X509_V_ERR_*
# numbers (same on OpenSSL and LibreSSL), so we classify WHY normal TLS trust
# failed without fragile date math.
cert_verify_code() { # cert_verify_code <https-url> -> numeric code (or "")
  local url="$1" hp
  hp="${url#https://}"; hp="${hp%%/*}"   # NB: bash 3.2 won't see url mid-`local`, so split
  case "$hp" in *:*) ;; *) hp="$hp:443" ;; esac
  openssl s_client -connect "$hp" -servername "${hp%%:*}" </dev/null 2>/dev/null \
    | sed -n 's/.*[Vv]erify return code: \([0-9][0-9]*\).*/\1/p' | tail -1
}

# Leaf-cert date sanity, checked independently of the chain verify code (some
# OpenSSL builds report the chain error first) so a self-signed cert that is
# ALSO expired or not-yet-valid never gets pinned. Echoes "expired" / "notyet" /
# nothing; an unreadable cert counts as expired (fail closed).
cert_leaf_date_problem() { # cert_leaf_date_problem <https-url>
  local url="$1" hp pem
  hp="${url#https://}"; hp="${hp%%/*}"
  case "$hp" in *:*) ;; *) hp="$hp:443" ;; esac
  pem=$(openssl s_client -connect "$hp" -servername "${hp%%:*}" </dev/null 2>/dev/null | openssl x509 2>/dev/null)
  [ -n "$pem" ] || { printf 'expired'; return 0; }
  printf '%s' "$pem" | openssl x509 -checkend 0 >/dev/null 2>&1 || { printf 'expired'; return 0; }
  # notBefore: `-checkend` only covers expiry, so compare the start date via the
  # python3 that's already required (portable — no GNU/BSD `date -d` split).
  local start; start=$(printf '%s' "$pem" | openssl x509 -noout -startdate 2>/dev/null | sed 's/^notBefore=//')
  [ -n "$start" ] || { printf 'expired'; return 0; }
  printf '%s' "$start" | python3 -c '
import sys, datetime
raw = sys.stdin.read().strip()
try:
    nb = datetime.datetime.strptime(raw, "%b %d %H:%M:%S %Y %Z")
except Exception:
    sys.exit(0)   # unparseable date -> do not block on this secondary check
if nb > datetime.datetime.utcnow():
    print("notyet")' 2>/dev/null
}

# Resolve the merged "I run my own HTTPS" choice: probe the cert and decide
# trust-vs-pin. Sets TRANSPORT to public (trusted, no pin) or selfsigned (pin),
# and GW_CERT_FP when pinning. STOPS on a genuinely broken cert (expired / not
# yet valid) rather than pinning it — pinning bypasses the app's chain checks
# (RemoteAgentTrustEvaluator .useCredential), so a bad cert would be trusted
# forever. An explicit advanced override can still force a pin.
classify_own_https() {  # GW_URL + SCOPE already set
  if $DRY_RUN; then
    TRANSPORT="public"   # provisional routing; a real run decides trust-vs-pin
    plan_add "CHECK the certificate at $GW_URL, then trust it (no pin) or pin its fingerprint"
    note "(dry-run: on a real run I check this certificate and either let the app trust it normally, or pin it)"
    return 0
  fi
  say ""
  note "Checking the certificate at $GW_URL …"
  # Capture curl's exit code directly — `$?` read after a completed `if` would be
  # the if-statement's own status (always 0 here), never curl's.
  local rc=0
  curl -sS --max-time 15 -o /dev/null "$GW_URL/v1/models" 2>/dev/null || rc=$?
  if [ "$rc" = "0" ]; then
    TRANSPORT="public"
    ok "Its certificate is trusted normally — the app needs no pin."
    return 0
  fi
  case "$rc" in
    6)  die "Couldn't resolve the host in $GW_URL. Check the address and re-run." ;;
    7)  die "Couldn't connect to $GW_URL (connection refused). Is the gateway up? Re-run when it is." ;;
    28) die "Connecting to $GW_URL timed out. Check the address / firewall and re-run." ;;
  esac
  # Reached the server but normal trust failed — classify why. FAIL CLOSED: pin
  # ONLY for the self-signed / unknown-issuer codes; anything else (a CA-valid but
  # WRONG-HOST cert = code 0, an expired/not-yet-valid cert, or an unclassifiable
  # failure) STOPS — pinning bypasses the app's hostname + chain checks, so we must
  # not pin a cert that failed for any reason other than "no trusted issuer".
  local code reason="" pinnable=false
  code=$(cert_verify_code "$GW_URL")
  case "$code" in
    18|19|20|21) pinnable=true ;;   # self-signed / unknown issuer — the legit pin case
    10) reason="has expired" ;;
    9)  reason="is not valid yet (check the gateway's clock)" ;;
    0)  reason="is valid but does not match this address (it's issued for a different hostname)" ;;
    *)  reason="couldn't be classified (TLS verify code '${code:-none}')" ;;
  esac
  # Belt-and-suspenders: even a self-signed cert must not be pinned while its
  # dates are wrong (expired OR not yet valid).
  if $pinnable; then
    local dateprob; dateprob=$(cert_leaf_date_problem "$GW_URL")
    case "$dateprob" in
      expired) pinnable=false; reason="has expired" ;;
      notyet)  pinnable=false; reason="is not valid yet (check the gateway's clock)" ;;
    esac
  fi
  if ! $pinnable; then
    bad "The certificate at $GW_URL $reason."
    say "  Pinning it would make the app trust it permanently and skip the normal"
    say "  hostname / validity checks — unsafe unless you know exactly why."
    say "  Best fix: correct the certificate (or use a Let's Encrypt one), then re-run."
    confirm "  Advanced: pin THIS certificate anyway?" \
      || die "Stopped — the certificate $reason. Fix it and re-run."
    warn "Pinning a certificate that $reason, at your request."
  fi
  GW_CERT_FP=$(compute_spki_hex "$GW_URL") \
    || die "Couldn't read a usable certificate from $GW_URL (key must be RSA-2048/3072/4096 or EC P-256/P-384)."
  TRANSPORT="selfsigned"
  $pinnable && ok "Detected a self-managed certificate — I'll pin it so the app trusts it."
  $pinnable && note "Pinning = the app trusts exactly this certificate from now on (and skips the normal public-trust check). Re-run this script if you ever replace the certificate."
  ok "Fingerprint: $GW_CERT_FP (rides inside the QR — no transcription)."
}

# Convert a 64-hex SPKI digest to base64-of-raw-bytes for curl --pinnedpubkey.
# We pin the SAME fingerprint that goes into the QR (computed once), NOT a freshly
# re-fetched cert — otherwise a cert that rotated mid-run could verify green yet the
# app would reject the QR's now-stale pin.
hex_to_b64() { # hex_to_b64 <64-hex>
  printf '%s' "$1" | python3 -c 'import sys,base64,binascii
h=sys.stdin.read().strip()
sys.stdout.write(base64.b64encode(binascii.unhexlify(h)).decode() if h else "")' 2>/dev/null
}

# ----------------------------------------------------------- file-lane phase --

FS_URL=""; FS_CRED=""; FS_CERT_FP=""
FS_LOCAL_PORT=""
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
  cat > "$FS_UNIT" <<EOF
[Unit]
Description=Conduck agent file server ($GW_ID, rclone WebDAV)
After=network.target

[Service]
EnvironmentFile=$envf
ExecStart=$(command -v rclone) serve webdav "$ws" --addr 127.0.0.1:$FS_LOCAL_PORT --user conduck
Restart=on-failure

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now "conduck-files-$GW_ID.service" && ok "File server running in the background (a systemd user service)." \
    || warn "Could not start the service — check 'systemctl --user status conduck-files-$GW_ID'."
  loginctl show-user "$USER" 2>/dev/null | grep -q 'Linger=yes' || {
    warn "User services stop at logout unless 'linger' is on (needed for a 24/7 box)."
    run_step "enable linger so the file server survives logout/reboot" \
      sudo loginctl enable-linger "$USER" || \
      note "Tip: 'sudo loginctl enable-linger $USER' keeps user services running after logout."
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
                      "--addr","127.0.0.1:"+os.environ["PORT"],"--user","conduck"],
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
  if pmset -g 2>/dev/null | grep -qE 'sleep[[:space:]]+[1-9]'; then
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
        FS_URL="https://$host:$ehttps"; ok "File lane is now public at $FS_URL."
      else warn "Could not make the file lane public — leaving it out."; drop_file_lane; fi
      ;;
    *)
      # Lane is on a non-Funnel port (e.g. 8444/9443) → need a free Funnel port.
      if ! pick_public_port funnel "$FS_LOCAL_PORT" file; then
        # No Funnel port free — NOTHING was changed, the lane is still private. Don't
        # silently drop a working lane: offer to keep it private instead of losing it.
        warn "Couldn't make the file lane public — all three Funnel ports (443/8443/10000) are already in use by other services on this machine."
        if confirm "  Keep the file lane PRIVATE instead (reachable on your Tailscale network)?"; then
          FS_URL="https://$host:$ehttps"
          warn "Keeping the file lane private at $FS_URL."
          warn "Heads-up: the gateway is PUBLIC but this file lane stays Tailscale-only, so attachments work only on your Tailscale-connected devices — an Apple Watch used away from your iPhone won't reach them. Chat still works everywhere."
        else FS_CRED=""; note "Leaving the file lane out."; fi
        return 0
      fi
      # Got a Funnel port → expose it, then drop the old private mapping (rollback-recorded).
      if tailscale_expose "$PICKED_PORT" "$FS_LOCAL_PORT" true file; then
        local newport="$PICKED_PORT"
        ts_unmap "$ehttps" "$everb"
        FS_URL="https://$host:$newport"; ok "File lane is now public at $FS_URL."
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
    FS_URL="https://$host:$ehttps"; ok "File lane is now private at $FS_URL — only your Tailscale devices can reach it."
  else warn "Could not make the file lane private — leaving it out (won't ship a public lane as private)."; drop_file_lane; fi
}

# Resolve a scope mismatch: align / omit / include as-is. Sets FS_URL on inclusion,
# clears FS_CRED on omit. Under --reuse-only the align option is withheld (it mutates).
resolve_fs_scope_mismatch() { # resolve_fs_scope_mismatch <existing-https-port> <existing-verb> <host>
  local ehttps="$1" everb="$2" host="$3" c
  if [ "$SCOPE" = "public" ]; then
    warn "Your file lane can be reached only by your own Tailscale-connected devices, but the gateway is public."
    note "As-is, attachments would work only on your Tailscale network — a Watch used away from the phone couldn't reach files."
    if $REUSE_ONLY; then
      say "    1) Leave the file lane out  (chat still works everywhere; no attachments)"
      say "    2) Include it as-is  (advanced — attachments only on your Tailscale devices)"
      note "(Making it public would change an exposure; --reuse-only forbids changes — re-run without it to do that.)"
      c=$(require_choice "Choose 1-2" '^[12]$') || die "$NO_ANSWER"
      case "$c" in
        1) FS_CRED=""; note "Leaving the file lane out." ;;
        2) FS_URL="https://$host:$ehttps"; ok "Included the file lane at $FS_URL (reachable only on your Tailscale network)." ;;
      esac
      return 0
    fi
    say "    1) Make the file lane public too  (puts a password-protected file server on the public internet)"
    say "    2) Leave the file lane out  (chat still works everywhere; no attachments)"
    say "    3) Include it as-is  (advanced — attachments only on your Tailscale devices)"
    c=$(require_choice "Choose 1-3" '^[123]$') || die "$NO_ANSWER"
    case "$c" in
      1) fs_promote_public "$ehttps" "$everb" "$host" ;;
      2) FS_CRED=""; note "Leaving the file lane out — its reach doesn't match the public gateway." ;;
      3) FS_URL="https://$host:$ehttps"; ok "Included the file lane at $FS_URL (reachable only on your Tailscale network)." ;;
    esac
  else
    warn "Your file lane is on the public internet, but the gateway is private (only your Tailscale devices) — that exposes your files more widely than the gateway itself."
    if $REUSE_ONLY; then
      say "    1) Leave the file lane out"
      say "    2) Keep it public anyway  (advanced)"
      note "(Making it private would change an exposure; --reuse-only forbids changes — re-run without it to do that.)"
      c=$(require_choice "Choose 1-2" '^[12]$') || die "$NO_ANSWER"
      case "$c" in
        1) FS_CRED=""; note "Leaving the file lane out." ;;
        2) FS_URL="https://$host:$ehttps"; warn "Including a public file lane at $FS_URL." ;;
      esac
      return 0
    fi
    say "    1) Make the file lane private too — match the gateway (recommended)"
    say "    2) Leave the file lane out"
    say "    3) Keep it public anyway  (advanced)"
    c=$(require_choice "Choose 1-3" '^[123]$') || die "$NO_ANSWER"
    case "$c" in
      1) fs_demote_private "$ehttps" "$everb" "$host" ;;
      2) FS_CRED=""; note "Leaving the file lane out." ;;
      3) FS_URL="https://$host:$ehttps"; warn "Including a public file lane at $FS_URL." ;;
    esac
  fi
}

setup_file_lane() {
  head_ "Step 4 — agent file lane (optional, recommended)"
  say "  Lets Conduck hand your agent REAL files (PDF/CSV/zip…) for its tools, and"
  say "  download files the agent writes back. It runs a tiny file server (over WebDAV —"
  say "  a standard way to read and write files over the web — using the rclone tool)"
  say "  over the agent's working folder, same HTTPS exposure as the gateway."
  if ! confirm "  Set it up?"; then note "Skipped — Conduck works without it (inline-only attachments)."; return 0; fi

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
      note "Advanced: run 'rclone serve webdav <folder> --addr 127.0.0.1:5006 --user conduck' under your own supervisor."
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
          FS_URL="https://$host:$ehttps"
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
          FS_URL="https://$host:$FS_HTTPS_PORT"
          ok "File lane ready at $FS_URL."
        else
          warn "File-lane exposure not confirmed — leaving it out of the QR."
          drop_file_lane
        fi
      else
        FS_CRED=""   # no permitted port free; file lane skipped (pick_public_port warned)
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

# ---------------------------------------------------------- verification phase --

VERIFY_FAILED=false

check() { # check "label" <command...>  (command's exit code decides)
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; VERIFY_FAILED=true; return 1; fi
}

# curl wrapper: normal TLS validation, EXCEPT self-signed which is verified by
# pinning the SPKI (matching what the app pins) instead of disabling checks.
# The bearer token rides a stdin curl config, never argv (argv shows in `ps`).
curl_gw() { # curl_gw <curl args…>
  local extra=()
  if [ "$TRANSPORT" = "selfsigned" ] && [ -n "$GW_CERT_FP" ]; then
    local b64; b64=$(hex_to_b64 "$GW_CERT_FP")     # pin the QR's fingerprint, not a re-fetch
    [ -n "$b64" ] && extra+=(--insecure --pinnedpubkey "sha256//$b64")
  fi
  # ${extra[@]+…} guard: expanding an empty array under `set -u` is an error in bash 3.2.
  if [ "$GW_AUTH" = "bearer" ]; then
    local tok="$GW_TOKEN"; tok="${tok//\\/\\\\}"; tok="${tok//\"/\\\"}"   # curl-config quoting
    printf 'header = "Authorization: Bearer %s"\n' "$tok" \
      | curl -sS --max-time 30 --config - ${extra[@]+"${extra[@]}"} "$@"
  else
    curl -sS --max-time 30 ${extra[@]+"${extra[@]}"} "$@"
  fi
}

models_is_json() { # 1 arg: base URL — /v1/models must answer 200 + the canonical envelope
                   #   (JSON object with a top-level "data" ARRAY), not the Control-UI HTML.
                   # Return codes: 0 ok · 1 unreachable/rejected/non-JSON · 2 HTML · 3 wrong shape.
  local out code body
  out=$(curl_gw -w '\n%{http_code}' "$1/v1/models" 2>/dev/null) || return 1
  code="${out##*$'\n'}"; body="${out%$'\n'*}"
  # HTML first: the endpoint-off page often comes back 200, and it deserves its
  # own diagnosis either way.
  case "$body" in *\<html*|*\<HTML*|*\<!DOCTYPE*) return 2 ;; esac
  # Status must be green — a 401/500 JSON error body is a FAILURE, not "answers
  # with JSON" (wrong token was the false-green case).
  [ "$code" = "200" ] || return 1
  # Canonical envelope: the app's Test Connection needs a JSON OBJECT whose
  # top-level "data" is an ARRAY (empty is fine). A bare array, a {"models":…}
  # shape, or "data" that isn't a list parses as JSON but fails the app's
  # stricter probe — flag it as its own case (return 3) so verify_all can say
  # so. Python is the sole classifier (unparseable → 1): a shell first-byte
  # test would wrongly reject leading whitespace and misfile JSON scalars.
  # parse_constant: NaN/Infinity are REJECTED — python accepts them by default
  # but Apple Foundation's parsers do not, and the script must never be laxer
  # than the app it green-lights for.
  printf '%s' "$body" | python3 -c '
import json, sys
def bad(x): raise ValueError(x)
try:
    d = json.load(sys.stdin, parse_constant=bad)
except Exception:
    sys.exit(1)
sys.exit(0 if isinstance(d, dict) and isinstance(d.get("data"), list) else 3)' 2>/dev/null
}

# A self-signed-aware curl for the FILE lane (its own pin if set, else gateway's).
# The credential rides a stdin curl config, never argv (argv shows in `ps`).
curl_fs() { # curl_fs <curl args…>
  local extra=()
  if [ "$TRANSPORT" = "selfsigned" ]; then
    local fp="$GW_CERT_FP"; [ -n "$FS_CERT_FP" ] && fp="$FS_CERT_FP"   # file's own pin if it has one
    if [ -n "$fp" ]; then local b64; b64=$(hex_to_b64 "$fp"); [ -n "$b64" ] && extra+=(--insecure --pinnedpubkey "sha256//$b64"); fi
  fi
  local cred="$FS_CRED"; cred="${cred//\\/\\\\}"; cred="${cred//\"/\\\"}"   # curl-config quoting
  printf 'user = "conduck:%s"\n' "$cred" \
    | curl -sS --max-time 30 --config - ${extra[@]+"${extra[@]}"} "$@"
}

local_health_ok() { # local_health_ok <url> -> 0 when the server answered with < 500
  local code
  code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null) || return 1
  case "$code" in ''|000) return 1 ;; 5??) return 1 ;; *) return 0 ;; esac
}

verify_all() {
  head_ "Step 5 — verify (real requests, before you touch your phone)"

  # Local health first (when the gateway has a health endpoint).
  # "Is it up locally?" — any HTTP answer below 500 counts (this request carries
  # no token, so an auth-gated health route answering 401 still proves it's up).
  # A 5xx or no answer at all is a real failure.
  if [ -n "$GW_HEALTH_PATH" ] && [ -n "$GW_LOCAL_PORT" ]; then
    check "gateway is up locally ($GW_HEALTH_PATH)" \
      local_health_ok "http://127.0.0.1:$GW_LOCAL_PORT$GW_HEALTH_PATH"
  fi

  # Public URL: model list must come back as JSON.
  local rc=0; models_is_json "$GW_URL" || rc=$?
  if [ "$rc" = "0" ]; then
    ok "$GW_URL/v1/models answers with JSON"
  elif [ "$rc" = "2" ]; then
    bad "$GW_URL/v1/models returns an HTML page — the chat endpoint is still OFF"
    say  "    (re-run Step 2, then restart the gateway)"
    VERIFY_FAILED=true
  elif [ "$rc" = "3" ]; then
    bad "$GW_URL/v1/models answers, but not with the required envelope"
    say  '    (must be JSON with a top-level "data" array — see conduck.com/setup/adapter/v1/)'
    VERIFY_FAILED=true
  else
    bad "$GW_URL/v1/models unreachable or rejected (URL? token? HTTPS front?)"
    VERIFY_FAILED=true
  fi

  # A real round-trip. Agents can be slow; give it time. Servers like
  # Ollama/vLLM/LiteLLM need the model named — include it exactly as the app will.
  say "  Asking the gateway for a one-word reply (can take a few minutes on modest hardware or a busy agent)…"
  local reply body out code resp curl_rc
  # Build the JSON with a real encoder — a quote/backslash in a model name must
  # not silently break the request body.
  body=$(GW_MODEL="$GW_MODEL" python3 -c '
import json, os
p = {"messages": [{"role": "user", "content": "Reply with exactly: pong"}], "stream": False}
m = os.environ.get("GW_MODEL", "")
if m: p["model"] = m
print(json.dumps(p))') || die "Could not build the test request (python3 failed)."
  [ -n "$body" ] || die "Could not build the test request."
  # Status AND shape must both be green — mirror the app's decoder exactly:
  # a non-200, or a 200 whose "content" isn't a non-empty STRING (a tool_calls
  # reply carries content:null, which python would happily print as "None"),
  # must not pass as a live round-trip.
  out=$(curl_gw -w '\n%{http_code}' "$GW_URL/v1/chat/completions" --max-time 300 \
      -H "Content-Type: application/json" \
      -d "$body" 2>/dev/null); curl_rc=$?
  code="${out##*$'\n'}"; resp="${out%$'\n'*}"
  reply=""
  # Parse ONLY a clean transfer: a curl that timed out or dropped mid-body can
  # still hand back a 200 + parseable prefix — that must not pass. Same strict
  # parse_constant as models_is_json (NaN/Infinity would crash the app's decode).
  if [ "$curl_rc" = "0" ] && [ "$code" = "200" ]; then
    reply=$(printf '%s' "$resp" | python3 -c 'import json,sys
def bad(x): raise ValueError(x)
try:
    c = json.load(sys.stdin, parse_constant=bad)["choices"][0]["message"]["content"]
    if isinstance(c, str): sys.stdout.write(c)
except Exception: pass' 2>/dev/null)
  fi
  if [ -n "$reply" ]; then ok "live round-trip: gateway replied (${reply%% *}…)"
  elif [ "$curl_rc" != "0" ]; then
    bad "live round-trip failed (transfer error — timed out or the connection dropped)"; VERIFY_FAILED=true
  elif [ -z "$code" ] || [ "$code" = "000" ]; then
    bad "live round-trip failed (no answer from the gateway)"; VERIFY_FAILED=true
  elif [ "$code" != "200" ]; then
    bad "live round-trip failed (HTTP $code)"; VERIFY_FAILED=true
  else
    bad 'live round-trip failed (HTTP 200, but no usable text — "content" must be a non-empty string)'
    VERIFY_FAILED=true
  fi

  # File lane: PUT → GET → DELETE a throwaway.
  if [ -n "$FS_URL" ] && [ -n "$FS_CRED" ]; then
    local probe="conduck-connect-probe-$$.txt" tmp; tmp=$(mktemp); echo "probe" > "$tmp"
    if curl_fs -T "$tmp" "$FS_URL/$probe" >/dev/null 2>&1 \
       && [ "$(curl_fs "$FS_URL/$probe" 2>/dev/null)" = "probe" ]; then
      if curl_fs -X DELETE "$FS_URL/$probe" >/dev/null 2>&1; then
        ok "file lane: write → read → delete all green"
      else
        ok "file lane: write → read green (delete probe left a stray file: $probe)"
      fi
    elif $SHOW_QR; then
      # --show-qr never rewrites the saved profile (write_profile guards on $SHOW_QR),
      # so dropping the lane here only affects THIS emission — the saved lane is untouched.
      bad "the saved profile's file lane failed live verification — a transient outage or a real breakage."
      if confirm "Show a gateway-only code anyway? (your saved profile keeps its file lane)"; then
        drop_file_lane
      else
        # Best-effort probe cleanup before dying: the PUT may have landed even though
        # the GET failed, and die would also skip the rm -f below.
        curl_fs -X DELETE "$FS_URL/$probe" >/dev/null 2>&1 || true
        rm -f "$tmp"
        die "Stopped — nothing changed. Fix the file server (or re-run the wizard: bash conduck-connect.sh), then try --show-qr again."
      fi
    else
      bad "file lane probe failed — leaving it out of the QR (re-run me after fixing)"
      drop_file_lane
    fi
    rm -f "$tmp"
  fi
}

# -------------------------------------------------------------- pairing emit --

# Write a NON-SECRET pairing profile so a later `--show-qr` can re-emit without
# re-answering the wizard. NEVER holds tokens/credentials — only the routing facts
# needed to reconstruct + re-verify. 0600, umask 077, built with a real JSON
# encoder (never hand-quoted). Refreshed on every successful WIZARD emit (incl.
# --reuse-only) but NEVER under --show-qr: that mode is a pure read of saved state,
# and a transient probe failure there can drop a file lane from this one emission —
# rewriting the profile would make that drop permanent. A failure here only WARNs —
# it must not sink a completed pairing.
write_profile() {
  # --show-qr is a pure read of saved state; rewriting here could permanently strip a
  # file lane that a transient probe failure dropped from this one emission. Guard first.
  $SHOW_QR && return 0
  $DRY_RUN && return 0                       # emit_payload never runs in dry-run, but stay explicit
  [ -n "$GW_ID" ] || return 0                # no stable id → nowhere to key the profile; skip quietly
  local pf; pf="$STATE_DIR/profile-$GW_ID.json"
  ( umask 077; mkdir -p "$STATE_DIR" ) 2>/dev/null \
    || { warn "Couldn't create $STATE_DIR to save the pairing profile — pairing is still complete."; return 0; }
  local out
  out=$(GW_ID="$GW_ID" GW_KIND="$GW_KIND" GW_NAME="$GW_NAME" GW_AUTH="$GW_AUTH" \
        TRANSPORT="$TRANSPORT" SCOPE="$SCOPE" GW_URL="$GW_URL" GW_LOCAL_PORT="$GW_LOCAL_PORT" \
        GW_MODEL="$GW_MODEL" GW_CERT_FP="$GW_CERT_FP" \
        FS_URL="$FS_URL" FS_CRED="$FS_CRED" FS_LOCAL_PORT="$FS_LOCAL_PORT" \
        FS_CERT_FP="$FS_CERT_FP" FS_FOLDER="$FS_FOLDER" \
        python3 - <<'PY'
import json, os
e = os.environ.get
# Gateway: routing facts only. No token, ever.
gw = {"id": e("GW_ID"), "kind": e("GW_KIND"), "auth": e("GW_AUTH"),
      "transport": e("TRANSPORT"), "reach": e("SCOPE"), "url": e("GW_URL")}
if e("GW_NAME"):       gw["name"] = e("GW_NAME")
if e("GW_LOCAL_PORT"): gw["localPort"] = e("GW_LOCAL_PORT")
if e("GW_MODEL"):      gw["model"] = e("GW_MODEL")
if e("GW_CERT_FP"):    gw["certFP"] = e("GW_CERT_FP")
p = {"schemaVersion": 1, "gateway": gw, "fileServer": None}
# Record the file lane only when it actually shipped in the QR (URL + credential
# both present) — and record its URL/port/cert/folder, NEVER the credential.
if e("FS_URL") and e("FS_CRED"):
    fs = {"url": e("FS_URL")}
    if e("FS_LOCAL_PORT"): fs["localPort"] = e("FS_LOCAL_PORT")
    if e("FS_CERT_FP"):    fs["certFP"]    = e("FS_CERT_FP")
    if e("FS_FOLDER"):     fs["folder"]    = e("FS_FOLDER")
    p["fileServer"] = fs
print(json.dumps(p, indent=1))
PY
) || { warn "Couldn't build the pairing profile to save — pairing is still complete."; return 0; }
  [ -n "$out" ] || { warn "Couldn't build the pairing profile to save — pairing is still complete."; return 0; }
  if ( umask 077; printf '%s\n' "$out" > "$pf" ) 2>/dev/null; then
    chmod 600 "$pf" 2>/dev/null || true       # belt-and-suspenders; umask 077 already made it 0600
    note "Saved a non-secret pairing profile (no token) — re-show this QR later with:  bash conduck-connect.sh --show-qr"
  else
    warn "Couldn't save the pairing profile to $pf — pairing is still complete."
  fi
}

emit_payload() {
  head_ "Step 6 — pair with the Conduck app"
  if $VERIFY_FAILED; then
    cleanup_exposures
    warn "Some checks failed above — fix those first, then re-run me."
    warn "I only hand you a setup code that is known to work."
    exit 1
  fi

  local payload
  payload=$(GW_KIND="$GW_KIND" GW_NAME="$GW_NAME" GW_URL="$GW_URL" GW_AUTH="$GW_AUTH" \
            GW_TOKEN="$GW_TOKEN" GW_MODEL="$GW_MODEL" GW_CERT_FP="$GW_CERT_FP" \
            FS_URL="$FS_URL" FS_CRED="$FS_CRED" FS_CERT_FP="$FS_CERT_FP" \
            TRANSPORT="$TRANSPORT" PV="$PAYLOAD_VERSION" \
            python3 - <<'PY'
import json, os
e = os.environ.get
gw = {"kind": e("GW_KIND"), "url": e("GW_URL"), "auth": e("GW_AUTH")}
if e("GW_NAME"):    gw["name"] = e("GW_NAME")
if e("GW_TOKEN"):   gw["token"] = e("GW_TOKEN")
if e("GW_MODEL"):   gw["model"] = e("GW_MODEL")
if e("GW_CERT_FP"): gw["certFP"] = e("GW_CERT_FP")
p = {"v": int(e("PV")), "gateway": gw, "transport": e("TRANSPORT")}
if e("FS_URL") and e("FS_CRED"):
    fs = {"url": e("FS_URL"), "credential": e("FS_CRED")}
    if e("FS_CERT_FP"): fs["certFP"] = e("FS_CERT_FP")
    p["fileServer"] = fs
print(json.dumps(p, separators=(",", ":")))
PY
) || die "Could not build the pairing payload (python3 failed)."
  [ -n "$payload" ] || die "Could not build the pairing payload."
  local encoded; encoded=$(printf '%s' "$payload" | b64_nowrap)
  [ -n "$encoded" ] || die "Could not base64-encode the pairing payload."
  local pairing="conduck-setup:v${PAYLOAD_VERSION}:$encoded"

  say ""
  warn "The setup code below CONTAINS YOUR TOKEN — both the QR and the plain-text string."
  warn "Treat it like a password: anyone who scans or copies it can use your agent."
  warn "Show it to your own phone only. Note: over SSH, Ctrl-L only clears the visible screen —"
  warn "the code stays in your scroll-back, so close the terminal (or clear scroll-back) when"
  warn "you're done, and never paste it into chat or a bug report."
  say ""

  render_qr "$pairing" || true   # prints a QR, or its own "widen/paste" note; string still follows

  say ""
  say "  ${BOLD}In Conduck:${RESET} Settings → Personal AI → look for the setup-code option."
  say "  On iPhone, iPad, or Android, scan the QR or paste this code; on Mac, paste the code below."
  say ""
  say "  Setup code (same secret as the QR — paste this for the Mac app or if scanning fails):"
  say ""
  printf '%s\n' "$pairing"
  say ""
  case "$TRANSPORT" in
    tailscale) note "Reminder: this gateway is tailnet-only — the device running Conduck (iPhone, iPad, Mac, or Android) needs the Tailscale app, logged in to the same tailnet." ;;
    selfsigned) note "Your gateway uses its own certificate; a secure fingerprint of it travels inside the code, so the app trusts it automatically — nothing for you to copy." ;;
  esac
  say "  Re-run this script any time to re-verify or show the code again."
  if $FS_ROLLBACK_INCOMPLETE; then
    say ""
    warn "One thing still needs YOUR attention: a file-server exposure this run created"
    warn "could not be confirmed removed, so it may still be reachable. The exact undo"
    warn "commands print below — run them, then check 'tailscale funnel status'."
  fi
  EMITTED=true   # success — the EXIT backstop prints undo hints only for an unconfirmed rollback
  write_profile  # refresh the non-secret profile so a later --show-qr needs no questions
}

# =============================================================================
# Render the pairing string as a scannable terminal QR using the python3 that is
# ALREADY required (no qrencode, no pip, no install). Prints the QR if it fits
# the terminal, else its own one-line "widen and re-run / paste below" note and
# returns non-zero. The big block below is VENDORED, UNMODIFIED Project Nayuki
# QR Code generator (MIT) + a ~50-line half-block renderer. It is INERT: it
# imports only the Python standard library (collections, itertools, re, typing)
# and reads QR_DATA/QR_COLS/QR_LINES from the environment — NO network, NO file,
# NO process calls. Safe to skip when reading the rest of this script.
# Upstream: https://www.nayuki.io/page/qr-code-generator-library
# =============================================================================
render_qr() { # render_qr <pairing-string>  -> 0 if a QR was drawn, non-zero otherwise
  local cols lines
  cols=$(tput cols 2>/dev/null || echo 80)
  lines=$(tput lines 2>/dev/null || echo 24)
  QR_DATA="$1" QR_COLS="$cols" QR_LINES="$lines" python3 - <<'CONDUCK_QR_PY'
# 
# QR Code generator library (Python)
# 
# Copyright (c) Project Nayuki. (MIT License)
# https://www.nayuki.io/page/qr-code-generator-library
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy of
# this software and associated documentation files (the "Software"), to deal in
# the Software without restriction, including without limitation the rights to
# use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
# the Software, and to permit persons to whom the Software is furnished to do so,
# subject to the following conditions:
# - The above copyright notice and this permission notice shall be included in
#   all copies or substantial portions of the Software.
# - The Software is provided "as is", without warranty of any kind, express or
#   implied, including but not limited to the warranties of merchantability,
#   fitness for a particular purpose and noninfringement. In no event shall the
#   authors or copyright holders be liable for any claim, damages or other
#   liability, whether in an action of contract, tort or otherwise, arising from,
#   out of or in connection with the Software or the use or other dealings in the
#   Software.
# 

from __future__ import annotations
import collections, itertools, re
from collections.abc import Sequence
from typing import Optional, Union


# ---- QR Code symbol class ----

class QrCode:
	"""A QR Code symbol, which is a type of two-dimension barcode.
	Invented by Denso Wave and described in the ISO/IEC 18004 standard.
	Instances of this class represent an immutable square grid of dark and light cells.
	The class provides static factory functions to create a QR Code from text or binary data.
	The class covers the QR Code Model 2 specification, supporting all versions (sizes)
	from 1 to 40, all 4 error correction levels, and 4 character encoding modes.
	
	Ways to create a QR Code object:
	- High level: Take the payload data and call QrCode.encode_text() or QrCode.encode_binary().
	- Mid level: Custom-make the list of segments and call QrCode.encode_segments().
	- Low level: Custom-make the array of data codeword bytes (including
	  segment headers and final padding, excluding error correction codewords),
	  supply the appropriate version number, and call the QrCode() constructor.
	(Note that all ways require supplying the desired error correction level.)"""
	
	# ---- Static factory functions (high level) ----
	
	@staticmethod
	def encode_text(text: str, ecl: QrCode.Ecc) -> QrCode:
		"""Returns a QR Code representing the given Unicode text string at the given error correction level.
		As a conservative upper bound, this function is guaranteed to succeed for strings that have 738 or fewer
		Unicode code points (not UTF-16 code units) if the low error correction level is used. The smallest possible
		QR Code version is automatically chosen for the output. The ECC level of the result may be higher than the
		ecl argument if it can be done without increasing the version."""
		segs: list[QrSegment] = QrSegment.make_segments(text)
		return QrCode.encode_segments(segs, ecl)
	
	
	@staticmethod
	def encode_binary(data: Union[bytes,Sequence[int]], ecl: QrCode.Ecc) -> QrCode:
		"""Returns a QR Code representing the given binary data at the given error correction level.
		This function always encodes using the binary segment mode, not any text mode. The maximum number of
		bytes allowed is 2953. The smallest possible QR Code version is automatically chosen for the output.
		The ECC level of the result may be higher than the ecl argument if it can be done without increasing the version."""
		return QrCode.encode_segments([QrSegment.make_bytes(data)], ecl)
	
	
	# ---- Static factory functions (mid level) ----
	
	@staticmethod
	def encode_segments(segs: Sequence[QrSegment], ecl: QrCode.Ecc, minversion: int = 1, maxversion: int = 40, mask: int = -1, boostecl: bool = True) -> QrCode:
		"""Returns a QR Code representing the given segments with the given encoding parameters.
		The smallest possible QR Code version within the given range is automatically
		chosen for the output. Iff boostecl is true, then the ECC level of the result
		may be higher than the ecl argument if it can be done without increasing the
		version. The mask number is either between 0 to 7 (inclusive) to force that
		mask, or -1 to automatically choose an appropriate mask (which may be slow).
		This function allows the user to create a custom sequence of segments that switches
		between modes (such as alphanumeric and byte) to encode text in less space.
		This is a mid-level API; the high-level API is encode_text() and encode_binary()."""
		
		if not (QrCode.MIN_VERSION <= minversion <= maxversion <= QrCode.MAX_VERSION) or not (-1 <= mask <= 7):
			raise ValueError("Invalid value")
		
		# Find the minimal version number to use
		for version in range(minversion, maxversion + 1):
			datacapacitybits: int = QrCode._get_num_data_codewords(version, ecl) * 8  # Number of data bits available
			datausedbits: Optional[int] = QrSegment.get_total_bits(segs, version)
			if (datausedbits is not None) and (datausedbits <= datacapacitybits):
				break  # This version number is found to be suitable
			if version >= maxversion:  # All versions in the range could not fit the given data
				msg: str = "Segment too long"
				if datausedbits is not None:
					msg = f"Data length = {datausedbits} bits, Max capacity = {datacapacitybits} bits"
				raise DataTooLongError(msg)
		assert datausedbits is not None
		
		# Increase the error correction level while the data still fits in the current version number
		for newecl in (QrCode.Ecc.MEDIUM, QrCode.Ecc.QUARTILE, QrCode.Ecc.HIGH):  # From low to high
			if boostecl and (datausedbits <= QrCode._get_num_data_codewords(version, newecl) * 8):
				ecl = newecl
		
		# Concatenate all segments to create the data bit string
		bb = _BitBuffer()
		for seg in segs:
			bb.append_bits(seg.get_mode().get_mode_bits(), 4)
			bb.append_bits(seg.get_num_chars(), seg.get_mode().num_char_count_bits(version))
			bb.extend(seg._bitdata)
		assert len(bb) == datausedbits
		
		# Add terminator and pad up to a byte if applicable
		datacapacitybits = QrCode._get_num_data_codewords(version, ecl) * 8
		assert len(bb) <= datacapacitybits
		bb.append_bits(0, min(4, datacapacitybits - len(bb)))
		bb.append_bits(0, -len(bb) % 8)  # Note: Python's modulo on negative numbers behaves better than C family languages
		assert len(bb) % 8 == 0
		
		# Pad with alternating bytes until data capacity is reached
		for padbyte in itertools.cycle((0xEC, 0x11)):
			if len(bb) >= datacapacitybits:
				break
			bb.append_bits(padbyte, 8)
		
		# Pack bits into bytes in big endian
		datacodewords = bytearray([0] * (len(bb) // 8))
		for (i, bit) in enumerate(bb):
			datacodewords[i >> 3] |= bit << (7 - (i & 7))
		
		# Create the QR Code object
		return QrCode(version, ecl, datacodewords, mask)
	
	
	# ---- Private fields ----
	
	# The version number of this QR Code, which is between 1 and 40 (inclusive).
	# This determines the size of this barcode.
	_version: int
	
	# The width and height of this QR Code, measured in modules, between
	# 21 and 177 (inclusive). This is equal to version * 4 + 17.
	_size: int
	
	# The error correction level used in this QR Code.
	_errcorlvl: QrCode.Ecc
	
	# The index of the mask pattern used in this QR Code, which is between 0 and 7 (inclusive).
	# Even if a QR Code is created with automatic masking requested (mask = -1),
	# the resulting object still has a mask value between 0 and 7.
	_mask: int
	
	# The modules of this QR Code (False = light, True = dark).
	# Immutable after constructor finishes. Accessed through get_module().
	_modules: list[list[bool]]
	
	# Indicates function modules that are not subjected to masking. Discarded when constructor finishes.
	_isfunction: list[list[bool]]
	
	
	# ---- Constructor (low level) ----
	
	def __init__(self, version: int, errcorlvl: QrCode.Ecc, datacodewords: Union[bytes,Sequence[int]], msk: int) -> None:
		"""Creates a new QR Code with the given version number,
		error correction level, data codeword bytes, and mask number.
		This is a low-level API that most users should not use directly.
		A mid-level API is the encode_segments() function."""
		
		# Check scalar arguments and set fields
		if not (QrCode.MIN_VERSION <= version <= QrCode.MAX_VERSION):
			raise ValueError("Version value out of range")
		if not (-1 <= msk <= 7):
			raise ValueError("Mask value out of range")
		
		self._version = version
		self._size = version * 4 + 17
		self._errcorlvl = errcorlvl
		
		# Initialize both grids to be size*size arrays of Boolean false
		self._modules    = [[False] * self._size for _ in range(self._size)]  # Initially all light
		self._isfunction = [[False] * self._size for _ in range(self._size)]
		
		# Compute ECC, draw modules
		self._draw_function_patterns()
		allcodewords: bytes = self._add_ecc_and_interleave(bytearray(datacodewords))
		self._draw_codewords(allcodewords)
		
		# Do masking
		if msk == -1:  # Automatically choose best mask
			minpenalty: int = 1 << 32
			for i in range(8):
				self._apply_mask(i)
				self._draw_format_bits(i)
				penalty = self._get_penalty_score()
				if penalty < minpenalty:
					msk = i
					minpenalty = penalty
				self._apply_mask(i)  # Undoes the mask due to XOR
		assert 0 <= msk <= 7
		self._mask = msk
		self._apply_mask(msk)  # Apply the final choice of mask
		self._draw_format_bits(msk)  # Overwrite old format bits
		
		del self._isfunction
	
	
	# ---- Accessor methods ----
	
	def get_version(self) -> int:
		"""Returns this QR Code's version number, in the range [1, 40]."""
		return self._version
	
	def get_size(self) -> int:
		"""Returns this QR Code's size, in the range [21, 177]."""
		return self._size
	
	def get_error_correction_level(self) -> QrCode.Ecc:
		"""Returns this QR Code's error correction level."""
		return self._errcorlvl
	
	def get_mask(self) -> int:
		"""Returns this QR Code's mask, in the range [0, 7]."""
		return self._mask
	
	def get_module(self, x: int, y: int) -> bool:
		"""Returns the color of the module (pixel) at the given coordinates, which is False
		for light or True for dark. The top left corner has the coordinates (x=0, y=0).
		If the given coordinates are out of bounds, then False (light) is returned."""
		return (0 <= x < self._size) and (0 <= y < self._size) and self._modules[y][x]
	
	
	# ---- Private helper methods for constructor: Drawing function modules ----
	
	def _draw_function_patterns(self) -> None:
		"""Reads this object's version field, and draws and marks all function modules."""
		# Draw horizontal and vertical timing patterns
		for i in range(self._size):
			self._set_function_module(6, i, i % 2 == 0)
			self._set_function_module(i, 6, i % 2 == 0)
		
		# Draw 3 finder patterns (all corners except bottom right; overwrites some timing modules)
		self._draw_finder_pattern(3, 3)
		self._draw_finder_pattern(self._size - 4, 3)
		self._draw_finder_pattern(3, self._size - 4)
		
		# Draw numerous alignment patterns
		alignpatpos: list[int] = self._get_alignment_pattern_positions()
		numalign: int = len(alignpatpos)
		skips: Sequence[tuple[int,int]] = ((0, 0), (0, numalign - 1), (numalign - 1, 0))
		for i in range(numalign):
			for j in range(numalign):
				if (i, j) not in skips:  # Don't draw on the three finder corners
					self._draw_alignment_pattern(alignpatpos[i], alignpatpos[j])
		
		# Draw configuration data
		self._draw_format_bits(0)  # Dummy mask value; overwritten later in the constructor
		self._draw_version()
	
	
	def _draw_format_bits(self, mask: int) -> None:
		"""Draws two copies of the format bits (with its own error correction code)
		based on the given mask and this object's error correction level field."""
		# Calculate error correction code and pack bits
		data: int = self._errcorlvl.formatbits << 3 | mask  # errCorrLvl is uint2, mask is uint3
		rem: int = data
		for _ in range(10):
			rem = (rem << 1) ^ ((rem >> 9) * 0x537)
		bits: int = (data << 10 | rem) ^ 0x5412  # uint15
		assert bits >> 15 == 0
		
		# Draw first copy
		for i in range(0, 6):
			self._set_function_module(8, i, _get_bit(bits, i))
		self._set_function_module(8, 7, _get_bit(bits, 6))
		self._set_function_module(8, 8, _get_bit(bits, 7))
		self._set_function_module(7, 8, _get_bit(bits, 8))
		for i in range(9, 15):
			self._set_function_module(14 - i, 8, _get_bit(bits, i))
		
		# Draw second copy
		for i in range(0, 8):
			self._set_function_module(self._size - 1 - i, 8, _get_bit(bits, i))
		for i in range(8, 15):
			self._set_function_module(8, self._size - 15 + i, _get_bit(bits, i))
		self._set_function_module(8, self._size - 8, True)  # Always dark
	
	
	def _draw_version(self) -> None:
		"""Draws two copies of the version bits (with its own error correction code),
		based on this object's version field, iff 7 <= version <= 40."""
		if self._version < 7:
			return
		
		# Calculate error correction code and pack bits
		rem: int = self._version  # version is uint6, in the range [7, 40]
		for _ in range(12):
			rem = (rem << 1) ^ ((rem >> 11) * 0x1F25)
		bits: int = self._version << 12 | rem  # uint18
		assert bits >> 18 == 0
		
		# Draw two copies
		for i in range(18):
			bit: bool = _get_bit(bits, i)
			a: int = self._size - 11 + i % 3
			b: int = i // 3
			self._set_function_module(a, b, bit)
			self._set_function_module(b, a, bit)
	
	
	def _draw_finder_pattern(self, x: int, y: int) -> None:
		"""Draws a 9*9 finder pattern including the border separator,
		with the center module at (x, y). Modules can be out of bounds."""
		for dy in range(-4, 5):
			for dx in range(-4, 5):
				xx, yy = x + dx, y + dy
				if (0 <= xx < self._size) and (0 <= yy < self._size):
					# Chebyshev/infinity norm
					self._set_function_module(xx, yy, max(abs(dx), abs(dy)) not in (2, 4))
	
	
	def _draw_alignment_pattern(self, x: int, y: int) -> None:
		"""Draws a 5*5 alignment pattern, with the center module
		at (x, y). All modules must be in bounds."""
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				self._set_function_module(x + dx, y + dy, max(abs(dx), abs(dy)) != 1)
	
	
	def _set_function_module(self, x: int, y: int, isdark: bool) -> None:
		"""Sets the color of a module and marks it as a function module.
		Only used by the constructor. Coordinates must be in bounds."""
		assert type(isdark) is bool
		self._modules[y][x] = isdark
		self._isfunction[y][x] = True
	
	
	# ---- Private helper methods for constructor: Codewords and masking ----
	
	def _add_ecc_and_interleave(self, data: bytearray) -> bytes:
		"""Returns a new byte string representing the given data with the appropriate error correction
		codewords appended to it, based on this object's version and error correction level."""
		version: int = self._version
		assert len(data) == QrCode._get_num_data_codewords(version, self._errcorlvl)
		
		# Calculate parameter numbers
		numblocks: int = QrCode._NUM_ERROR_CORRECTION_BLOCKS[self._errcorlvl.ordinal][version]
		blockecclen: int = QrCode._ECC_CODEWORDS_PER_BLOCK  [self._errcorlvl.ordinal][version]
		rawcodewords: int = QrCode._get_num_raw_data_modules(version) // 8
		numshortblocks: int = numblocks - rawcodewords % numblocks
		shortblocklen: int = rawcodewords // numblocks
		
		# Split data into blocks and append ECC to each block
		blocks: list[bytes] = []
		rsdiv: bytes = QrCode._reed_solomon_compute_divisor(blockecclen)
		k: int = 0
		for i in range(numblocks):
			dat: bytearray = data[k : k + shortblocklen - blockecclen + (0 if i < numshortblocks else 1)]
			k += len(dat)
			ecc: bytes = QrCode._reed_solomon_compute_remainder(dat, rsdiv)
			if i < numshortblocks:
				dat.append(0)
			blocks.append(dat + ecc)
		assert k == len(data)
		
		# Interleave (not concatenate) the bytes from every block into a single sequence
		result = bytearray()
		for i in range(len(blocks[0])):
			for (j, blk) in enumerate(blocks):
				# Skip the padding byte in short blocks
				if (i != shortblocklen - blockecclen) or (j >= numshortblocks):
					result.append(blk[i])
		assert len(result) == rawcodewords
		return result
	
	
	def _draw_codewords(self, data: bytes) -> None:
		"""Draws the given sequence of 8-bit codewords (data and error correction) onto the entire
		data area of this QR Code. Function modules need to be marked off before this is called."""
		assert len(data) == QrCode._get_num_raw_data_modules(self._version) // 8
		
		i: int = 0  # Bit index into the data
		# Do the funny zigzag scan
		for right in range(self._size - 1, 0, -2):  # Index of right column in each column pair
			if right <= 6:
				right -= 1
			for vert in range(self._size):  # Vertical counter
				for j in range(2):
					x: int = right - j  # Actual x coordinate
					upward: bool = (right + 1) & 2 == 0
					y: int = (self._size - 1 - vert) if upward else vert  # Actual y coordinate
					if (not self._isfunction[y][x]) and (i < len(data) * 8):
						self._modules[y][x] = _get_bit(data[i >> 3], 7 - (i & 7))
						i += 1
					# If this QR Code has any remainder bits (0 to 7), they were assigned as
					# 0/false/light by the constructor and are left unchanged by this method
		assert i == len(data) * 8
	
	
	def _apply_mask(self, mask: int) -> None:
		"""XORs the codeword modules in this QR Code with the given mask pattern.
		The function modules must be marked and the codeword bits must be drawn
		before masking. Due to the arithmetic of XOR, calling _apply_mask() with
		the same mask value a second time will undo the mask. A final well-formed
		QR Code needs exactly one (not zero, two, etc.) mask applied."""
		if not (0 <= mask <= 7):
			raise ValueError("Mask value out of range")
		masker: collections.abc.Callable[[int,int],int] = QrCode._MASK_PATTERNS[mask]
		for y in range(self._size):
			for x in range(self._size):
				self._modules[y][x] ^= (masker(x, y) == 0) and (not self._isfunction[y][x])
	
	
	def _get_penalty_score(self) -> int:
		"""Calculates and returns the penalty score based on state of this QR Code's current modules.
		This is used by the automatic mask choice algorithm to find the mask pattern that yields the lowest score."""
		result: int = 0
		size: int = self._size
		modules: list[list[bool]] = self._modules
		
		# Adjacent modules in row having same color, and finder-like patterns
		for y in range(size):
			runcolor: bool = False
			runx: int = 0
			runhistory = collections.deque([0] * 7, 7)
			for x in range(size):
				if modules[y][x] == runcolor:
					runx += 1
					if runx == 5:
						result += QrCode._PENALTY_N1
					elif runx > 5:
						result += 1
				else:
					self._finder_penalty_add_history(runx, runhistory)
					if not runcolor:
						result += self._finder_penalty_count_patterns(runhistory) * QrCode._PENALTY_N3
					runcolor = modules[y][x]
					runx = 1
			result += self._finder_penalty_terminate_and_count(runcolor, runx, runhistory) * QrCode._PENALTY_N3
		# Adjacent modules in column having same color, and finder-like patterns
		for x in range(size):
			runcolor = False
			runy: int = 0
			runhistory = collections.deque([0] * 7, 7)
			for y in range(size):
				if modules[y][x] == runcolor:
					runy += 1
					if runy == 5:
						result += QrCode._PENALTY_N1
					elif runy > 5:
						result += 1
				else:
					self._finder_penalty_add_history(runy, runhistory)
					if not runcolor:
						result += self._finder_penalty_count_patterns(runhistory) * QrCode._PENALTY_N3
					runcolor = modules[y][x]
					runy = 1
			result += self._finder_penalty_terminate_and_count(runcolor, runy, runhistory) * QrCode._PENALTY_N3
		
		# 2*2 blocks of modules having same color
		for y in range(size - 1):
			for x in range(size - 1):
				if modules[y][x] == modules[y][x + 1] == modules[y + 1][x] == modules[y + 1][x + 1]:
					result += QrCode._PENALTY_N2
		
		# Balance of dark and light modules
		dark: int = sum((1 if cell else 0) for row in modules for cell in row)
		total: int = size**2  # Note that size is odd, so dark/total != 1/2
		# Compute the smallest integer k >= 0 such that (45-5k)% <= dark/total <= (55+5k)%
		k: int = (abs(dark * 20 - total * 10) + total - 1) // total - 1
		assert 0 <= k <= 9
		result += k * QrCode._PENALTY_N4
		assert 0 <= result <= 2568888  # Non-tight upper bound based on default values of PENALTY_N1, ..., N4
		return result
	
	
	# ---- Private helper functions ----
	
	def _get_alignment_pattern_positions(self) -> list[int]:
		"""Returns an ascending list of positions of alignment patterns for this version number.
		Each position is in the range [0,177), and are used on both the x and y axes.
		This could be implemented as lookup table of 40 variable-length lists of integers."""
		if self._version == 1:
			return []
		else:
			numalign: int = self._version // 7 + 2
			step: int = (self._version * 8 + numalign * 3 + 5) // (numalign * 4 - 4) * 2
			result: list[int] = [(self._size - 7 - i * step) for i in range(numalign - 1)] + [6]
			return list(reversed(result))
	
	
	@staticmethod
	def _get_num_raw_data_modules(ver: int) -> int:
		"""Returns the number of data bits that can be stored in a QR Code of the given version number, after
		all function modules are excluded. This includes remainder bits, so it might not be a multiple of 8.
		The result is in the range [208, 29648]. This could be implemented as a 40-entry lookup table."""
		if not (QrCode.MIN_VERSION <= ver <= QrCode.MAX_VERSION):
			raise ValueError("Version number out of range")
		result: int = (16 * ver + 128) * ver + 64
		if ver >= 2:
			numalign: int = ver // 7 + 2
			result -= (25 * numalign - 10) * numalign - 55
			if ver >= 7:
				result -= 36
		assert 208 <= result <= 29648
		return result
	
	
	@staticmethod
	def _get_num_data_codewords(ver: int, ecl: QrCode.Ecc) -> int:
		"""Returns the number of 8-bit data (i.e. not error correction) codewords contained in any
		QR Code of the given version number and error correction level, with remainder bits discarded.
		This stateless pure function could be implemented as a (40*4)-cell lookup table."""
		return QrCode._get_num_raw_data_modules(ver) // 8 \
			- QrCode._ECC_CODEWORDS_PER_BLOCK    [ecl.ordinal][ver] \
			* QrCode._NUM_ERROR_CORRECTION_BLOCKS[ecl.ordinal][ver]
	
	
	@staticmethod
	def _reed_solomon_compute_divisor(degree: int) -> bytes:
		"""Returns a Reed-Solomon ECC generator polynomial for the given degree. This could be
		implemented as a lookup table over all possible parameter values, instead of as an algorithm."""
		if not (1 <= degree <= 255):
			raise ValueError("Degree out of range")
		# Polynomial coefficients are stored from highest to lowest power, excluding the leading term which is always 1.
		# For example the polynomial x^3 + 255x^2 + 8x + 93 is stored as the uint8 array [255, 8, 93].
		result = bytearray([0] * (degree - 1) + [1])  # Start off with the monomial x^0
		
		# Compute the product polynomial (x - r^0) * (x - r^1) * (x - r^2) * ... * (x - r^{degree-1}),
		# and drop the highest monomial term which is always 1x^degree.
		# Note that r = 0x02, which is a generator element of this field GF(2^8/0x11D).
		root: int = 1
		for _ in range(degree):  # Unused variable i
			# Multiply the current product by (x - r^i)
			for j in range(degree):
				result[j] = QrCode._reed_solomon_multiply(result[j], root)
				if j + 1 < degree:
					result[j] ^= result[j + 1]
			root = QrCode._reed_solomon_multiply(root, 0x02)
		return result
	
	
	@staticmethod
	def _reed_solomon_compute_remainder(data: bytes, divisor: bytes) -> bytes:
		"""Returns the Reed-Solomon error correction codeword for the given data and divisor polynomials."""
		result = bytearray([0] * len(divisor))
		for b in data:  # Polynomial division
			factor: int = b ^ result.pop(0)
			result.append(0)
			for (i, coef) in enumerate(divisor):
				result[i] ^= QrCode._reed_solomon_multiply(coef, factor)
		return result
	
	
	@staticmethod
	def _reed_solomon_multiply(x: int, y: int) -> int:
		"""Returns the product of the two given field elements modulo GF(2^8/0x11D). The arguments and result
		are unsigned 8-bit integers. This could be implemented as a lookup table of 256*256 entries of uint8."""
		if (x >> 8 != 0) or (y >> 8 != 0):
			raise ValueError("Byte out of range")
		# Russian peasant multiplication
		z: int = 0
		for i in reversed(range(8)):
			z = (z << 1) ^ ((z >> 7) * 0x11D)
			z ^= ((y >> i) & 1) * x
		assert z >> 8 == 0
		return z
	
	
	def _finder_penalty_count_patterns(self, runhistory: collections.deque[int]) -> int:
		"""Can only be called immediately after a light run is added, and
		returns either 0, 1, or 2. A helper function for _get_penalty_score()."""
		n: int = runhistory[1]
		assert n <= self._size * 3
		core: bool = n > 0 and (runhistory[2] == runhistory[4] == runhistory[5] == n) and runhistory[3] == n * 3
		return (1 if (core and runhistory[0] >= n * 4 and runhistory[6] >= n) else 0) \
		     + (1 if (core and runhistory[6] >= n * 4 and runhistory[0] >= n) else 0)
	
	
	def _finder_penalty_terminate_and_count(self, currentruncolor: bool, currentrunlength: int, runhistory: collections.deque[int]) -> int:
		"""Must be called at the end of a line (row or column) of modules. A helper function for _get_penalty_score()."""
		if currentruncolor:  # Terminate dark run
			self._finder_penalty_add_history(currentrunlength, runhistory)
			currentrunlength = 0
		currentrunlength += self._size  # Add light border to final run
		self._finder_penalty_add_history(currentrunlength, runhistory)
		return self._finder_penalty_count_patterns(runhistory)
	
	
	def _finder_penalty_add_history(self, currentrunlength: int, runhistory: collections.deque[int]) -> None:
		if runhistory[0] == 0:
			currentrunlength += self._size  # Add light border to initial run
		runhistory.appendleft(currentrunlength)
	
	
	# ---- Constants and tables ----
	
	MIN_VERSION: int =  1  # The minimum version number supported in the QR Code Model 2 standard
	MAX_VERSION: int = 40  # The maximum version number supported in the QR Code Model 2 standard
	
	# For use in _get_penalty_score(), when evaluating which mask is best.
	_PENALTY_N1: int =  3
	_PENALTY_N2: int =  3
	_PENALTY_N3: int = 40
	_PENALTY_N4: int = 10
	
	_ECC_CODEWORDS_PER_BLOCK: Sequence[Sequence[int]] = (
		# Version: (note that index 0 is for padding, and is set to an illegal value)
		# 0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40    Error correction level
		(-1,  7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30),  # Low
		(-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28),  # Medium
		(-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30),  # Quartile
		(-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30))  # High
	
	_NUM_ERROR_CORRECTION_BLOCKS: Sequence[Sequence[int]] = (
		# Version: (note that index 0 is for padding, and is set to an illegal value)
		# 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40    Error correction level
		(-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4,  4,  4,  4,  4,  6,  6,  6,  6,  7,  8,  8,  9,  9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25),  # Low
		(-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5,  5,  8,  9,  9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49),  # Medium
		(-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8,  8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68),  # Quartile
		(-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81))  # High
	
	_MASK_PATTERNS: Sequence[collections.abc.Callable[[int,int],int]] = (
		(lambda x, y:  (x + y) % 2                  ),
		(lambda x, y:  y % 2                        ),
		(lambda x, y:  x % 3                        ),
		(lambda x, y:  (x + y) % 3                  ),
		(lambda x, y:  (x // 3 + y // 2) % 2        ),
		(lambda x, y:  x * y % 2 + x * y % 3        ),
		(lambda x, y:  (x * y % 2 + x * y % 3) % 2  ),
		(lambda x, y:  ((x + y) % 2 + x * y % 3) % 2),
	)
	
	
	# ---- Public helper enumeration ----
	
	class Ecc:
		ordinal: int  # (Public) In the range 0 to 3 (unsigned 2-bit integer)
		formatbits: int  # (Package-private) In the range 0 to 3 (unsigned 2-bit integer)
		
		"""The error correction level in a QR Code symbol. Immutable."""
		# Private constructor
		def __init__(self, i: int, fb: int) -> None:
			self.ordinal = i
			self.formatbits = fb
		
		# Placeholders
		LOW     : QrCode.Ecc
		MEDIUM  : QrCode.Ecc
		QUARTILE: QrCode.Ecc
		HIGH    : QrCode.Ecc
	
	# Public constants. Create them outside the class.
	Ecc.LOW      = Ecc(0, 1)  # The QR Code can tolerate about  7% erroneous codewords
	Ecc.MEDIUM   = Ecc(1, 0)  # The QR Code can tolerate about 15% erroneous codewords
	Ecc.QUARTILE = Ecc(2, 3)  # The QR Code can tolerate about 25% erroneous codewords
	Ecc.HIGH     = Ecc(3, 2)  # The QR Code can tolerate about 30% erroneous codewords



# ---- Data segment class ----

class QrSegment:
	"""A segment of character/binary/control data in a QR Code symbol.
	Instances of this class are immutable.
	The mid-level way to create a segment is to take the payload data
	and call a static factory function such as QrSegment.make_numeric().
	The low-level way to create a segment is to custom-make the bit buffer
	and call the QrSegment() constructor with appropriate values.
	This segment class imposes no length restrictions, but QR Codes have restrictions.
	Even in the most favorable conditions, a QR Code can only hold 7089 characters of data.
	Any segment longer than this is meaningless for the purpose of generating QR Codes."""
	
	# ---- Static factory functions (mid level) ----
	
	@staticmethod
	def make_bytes(data: Union[bytes,Sequence[int]]) -> QrSegment:
		"""Returns a segment representing the given binary data encoded in byte mode.
		All input byte lists are acceptable. Any text string can be converted to
		UTF-8 bytes (s.encode("UTF-8")) and encoded as a byte mode segment."""
		bb = _BitBuffer()
		for b in data:
			bb.append_bits(b, 8)
		return QrSegment(QrSegment.Mode.BYTE, len(data), bb)
	
	
	@staticmethod
	def make_numeric(digits: str) -> QrSegment:
		"""Returns a segment representing the given string of decimal digits encoded in numeric mode."""
		if not QrSegment.is_numeric(digits):
			raise ValueError("String contains non-numeric characters")
		bb = _BitBuffer()
		i: int = 0
		while i < len(digits):  # Consume up to 3 digits per iteration
			n: int = min(len(digits) - i, 3)
			bb.append_bits(int(digits[i : i + n]), n * 3 + 1)
			i += n
		return QrSegment(QrSegment.Mode.NUMERIC, len(digits), bb)
	
	
	@staticmethod
	def make_alphanumeric(text: str) -> QrSegment:
		"""Returns a segment representing the given text string encoded in alphanumeric mode.
		The characters allowed are: 0 to 9, A to Z (uppercase only), space,
		dollar, percent, asterisk, plus, hyphen, period, slash, colon."""
		if not QrSegment.is_alphanumeric(text):
			raise ValueError("String contains unencodable characters in alphanumeric mode")
		bb = _BitBuffer()
		for i in range(0, len(text) - 1, 2):  # Process groups of 2
			temp: int = QrSegment._ALPHANUMERIC_ENCODING_TABLE[text[i]] * 45
			temp += QrSegment._ALPHANUMERIC_ENCODING_TABLE[text[i + 1]]
			bb.append_bits(temp, 11)
		if len(text) % 2 > 0:  # 1 character remaining
			bb.append_bits(QrSegment._ALPHANUMERIC_ENCODING_TABLE[text[-1]], 6)
		return QrSegment(QrSegment.Mode.ALPHANUMERIC, len(text), bb)
	
	
	@staticmethod
	def make_segments(text: str) -> list[QrSegment]:
		"""Returns a new mutable list of zero or more segments to represent the given Unicode text string.
		The result may use various segment modes and switch modes to optimize the length of the bit stream."""
		
		# Select the most efficient segment encoding automatically
		if text == "":
			return []
		elif QrSegment.is_numeric(text):
			return [QrSegment.make_numeric(text)]
		elif QrSegment.is_alphanumeric(text):
			return [QrSegment.make_alphanumeric(text)]
		else:
			return [QrSegment.make_bytes(text.encode("UTF-8"))]
	
	
	@staticmethod
	def make_eci(assignval: int) -> QrSegment:
		"""Returns a segment representing an Extended Channel Interpretation
		(ECI) designator with the given assignment value."""
		bb = _BitBuffer()
		if assignval < 0:
			raise ValueError("ECI assignment value out of range")
		elif assignval < (1 << 7):
			bb.append_bits(assignval, 8)
		elif assignval < (1 << 14):
			bb.append_bits(0b10, 2)
			bb.append_bits(assignval, 14)
		elif assignval < 1000000:
			bb.append_bits(0b110, 3)
			bb.append_bits(assignval, 21)
		else:
			raise ValueError("ECI assignment value out of range")
		return QrSegment(QrSegment.Mode.ECI, 0, bb)
	
	
	# Tests whether the given string can be encoded as a segment in numeric mode.
	# A string is encodable iff each character is in the range 0 to 9.
	@staticmethod
	def is_numeric(text: str) -> bool:
		return QrSegment._NUMERIC_REGEX.fullmatch(text) is not None
	
	
	# Tests whether the given string can be encoded as a segment in alphanumeric mode.
	# A string is encodable iff each character is in the following set: 0 to 9, A to Z
	# (uppercase only), space, dollar, percent, asterisk, plus, hyphen, period, slash, colon.
	@staticmethod
	def is_alphanumeric(text: str) -> bool:
		return QrSegment._ALPHANUMERIC_REGEX.fullmatch(text) is not None
	
	
	# ---- Private fields ----
	
	# The mode indicator of this segment. Accessed through get_mode().
	_mode: QrSegment.Mode
	
	# The length of this segment's unencoded data. Measured in characters for
	# numeric/alphanumeric/kanji mode, bytes for byte mode, and 0 for ECI mode.
	# Always zero or positive. Not the same as the data's bit length.
	# Accessed through get_num_chars().
	_numchars: int
	
	# The data bits of this segment. Accessed through get_data().
	_bitdata: list[int]
	
	
	# ---- Constructor (low level) ----
	
	def __init__(self, mode: QrSegment.Mode, numch: int, bitdata: Sequence[int]) -> None:
		"""Creates a new QR Code segment with the given attributes and data.
		The character count (numch) must agree with the mode and the bit buffer length,
		but the constraint isn't checked. The given bit buffer is cloned and stored."""
		if numch < 0:
			raise ValueError()
		self._mode = mode
		self._numchars = numch
		self._bitdata = list(bitdata)  # Make defensive copy
	
	
	# ---- Accessor methods ----
	
	def get_mode(self) -> QrSegment.Mode:
		"""Returns the mode field of this segment."""
		return self._mode
	
	def get_num_chars(self) -> int:
		"""Returns the character count field of this segment."""
		return self._numchars
	
	def get_data(self) -> list[int]:
		"""Returns a new copy of the data bits of this segment."""
		return list(self._bitdata)  # Make defensive copy
	
	
	# Package-private function
	@staticmethod
	def get_total_bits(segs: Sequence[QrSegment], version: int) -> Optional[int]:
		"""Calculates the number of bits needed to encode the given segments at
		the given version. Returns a non-negative number if successful. Otherwise
		returns None if a segment has too many characters to fit its length field."""
		result = 0
		for seg in segs:
			ccbits: int = seg.get_mode().num_char_count_bits(version)
			if seg.get_num_chars() >= (1 << ccbits):
				return None  # The segment's length doesn't fit the field's bit width
			result += 4 + ccbits + len(seg._bitdata)
		return result
	
	
	# ---- Constants ----
	
	# Describes precisely all strings that are encodable in numeric mode.
	_NUMERIC_REGEX: re.Pattern[str] = re.compile(r"[0-9]*")
	
	# Describes precisely all strings that are encodable in alphanumeric mode.
	_ALPHANUMERIC_REGEX: re.Pattern[str] = re.compile(r"[A-Z0-9 $%*+./:-]*")
	
	# Dictionary of "0"->0, "A"->10, "$"->37, etc.
	_ALPHANUMERIC_ENCODING_TABLE: dict[str,int] = {ch: i for (i, ch) in enumerate("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:")}
	
	
	# ---- Public helper enumeration ----
	
	class Mode:
		"""Describes how a segment's data bits are interpreted. Immutable."""
		
		_modebits: int  # The mode indicator bits, which is a uint4 value (range 0 to 15)
		_charcounts: tuple[int,int,int]  # Number of character count bits for three different version ranges
		
		# Private constructor
		def __init__(self, modebits: int, charcounts: tuple[int,int,int]):
			self._modebits = modebits
			self._charcounts = charcounts
		
		# Package-private method
		def get_mode_bits(self) -> int:
			"""Returns an unsigned 4-bit integer value (range 0 to 15) representing the mode indicator bits for this mode object."""
			return self._modebits
		
		# Package-private method
		def num_char_count_bits(self, ver: int) -> int:
			"""Returns the bit width of the character count field for a segment in this mode
			in a QR Code at the given version number. The result is in the range [0, 16]."""
			return self._charcounts[(ver + 7) // 17]
		
		# Placeholders
		NUMERIC     : QrSegment.Mode
		ALPHANUMERIC: QrSegment.Mode
		BYTE        : QrSegment.Mode
		KANJI       : QrSegment.Mode
		ECI         : QrSegment.Mode
	
	# Public constants. Create them outside the class.
	Mode.NUMERIC      = Mode(0x1, (10, 12, 14))
	Mode.ALPHANUMERIC = Mode(0x2, ( 9, 11, 13))
	Mode.BYTE         = Mode(0x4, ( 8, 16, 16))
	Mode.KANJI        = Mode(0x8, ( 8, 10, 12))
	Mode.ECI          = Mode(0x7, ( 0,  0,  0))



# ---- Private helper class ----

class _BitBuffer(list[int]):
	"""An appendable sequence of bits (0s and 1s). Mainly used by QrSegment."""
	
	def append_bits(self, val: int, n: int) -> None:
		"""Appends the given number of low-order bits of the given
		value to this buffer. Requires n >= 0 and 0 <= val < 2^n."""
		if (n < 0) or (val >> n != 0):
			raise ValueError("Value out of range")
		self.extend(((val >> i) & 1) for i in reversed(range(n)))


def _get_bit(x: int, i: int) -> bool:
	"""Returns true iff the i'th bit of x is set to 1."""
	return (x >> i) & 1 != 0



class DataTooLongError(ValueError):
	"""Raised when the supplied data does not fit any QR Code version. Ways to handle this exception include:
	- Decrease the error correction level if it was greater than Ecc.LOW.
	- If the encode_segments() function was called with a maxversion argument, then increase
	  it if it was less than QrCode.MAX_VERSION. (This advice does not apply to the other
	  factory functions because they search all versions up to QrCode.MAX_VERSION.)
	- Split the text data into better or optimal segments in order to reduce the number of bits required.
	- Change the text or binary data to be shorter.
	- Change the text to fit the character set of a particular segment mode (e.g. alphanumeric).
	- Propagate the error upward to the caller/user."""
	pass
# ---- conduck-connect terminal QR renderer (appended after qrcodegen) ----
# Reads QR_DATA / QR_COLS / QR_LINES from the environment. Prints a scannable
# QR using Unicode half-blocks with FORCED colors (black modules on white),
# so it scans regardless of terminal theme. Exits 3 if the QR cannot fit the
# terminal (caller falls back to the paste string). Stdlib only; no I/O beyond
# reading env + writing stdout.
import os, sys

QUIET = 4  # spec quiet zone (modules) — forced-white, theme-independent

def _fit(qr):
    t = qr.get_size() + 2 * QUIET
    return t, t, (t + 1) // 2  # total modules/side, cols, rows (half-block packs 2 rows/char)

def _draw(qr):
    size = qr.get_size()
    t = size + 2 * QUIET
    def dark(x, y):
        mx, my = x - QUIET, y - QUIET
        return qr.get_module(mx, my) if (0 <= mx < size and 0 <= my < size) else False
    out = []
    for ry in range(0, t, 2):
        cells = []
        for x in range(t):
            top = dark(x, ry)
            bot = dark(x, ry + 1) if ry + 1 < t else False
            fg = 30 if top else 97   # black vs bright white (upper half = fg)
            bg = 40 if bot else 107  # black vs bright white (lower half = bg)
            cells.append("\x1b[%d;%dm▀" % (fg, bg))
        out.append("".join(cells) + "\x1b[0m")
    return "\n".join(out)

def build(data, cols, lines):
    """Return (text, cols_needed, rows_needed) or (None, cols_needed, rows_needed)
    for the smallest fitting ECC; (None, 0, 0) if it cannot encode at all."""
    best = None
    for ecl in (QrCode.Ecc.MEDIUM, QrCode.Ecc.LOW):
        try:
            qr = QrCode.encode_text(data, ecl)
        except Exception:
            return None, 0, 0
        t, need_cols, need_rows = _fit(qr)
        if need_cols <= cols and need_rows <= lines:
            return _draw(qr), need_cols, need_rows
        if best is None:
            best = (need_cols, need_rows)
    return None, best[0], best[1]

def _main():
    data = os.environ.get("QR_DATA", "")
    try:
        cols = int(os.environ.get("QR_COLS", "0"))
        lines = int(os.environ.get("QR_LINES", "0"))
    except ValueError:
        cols = lines = 0
    if not data:
        sys.exit(2)
    text, need_cols, need_rows = build(data, cols, lines)
    if text is None:
        if need_cols == 0:
            print("  (Could not render a QR for this code — use the paste string below.)")
        else:
            print("  This QR needs about %d×%d characters; your terminal is %d×%d."
                  % (need_cols, need_rows, cols, lines))
            print("  Widen the window and re-run for a scannable QR, or just paste the code below.")
        sys.exit(3)
    sys.stdout.write(text + "\n")
    sys.exit(0)

if __name__ == "__main__":
    _main()
CONDUCK_QR_PY
}

# ------------------------------------------------------------- dry-run plan --

print_plan() {
  head_ "Dry-run plan — this is what a real run WOULD do (nothing was changed)"
  say ""
  say "  ${BOLD}Current Tailscale exposures:${RESET}"
  if ! $TS_STATE_KNOWN; then
    note "(could not read 'tailscale serve status --json' — a real run would refuse to guess)"
  elif [ ${#TS_PORTS[@]} -eq 0 ]; then
    note "(none)"
  else
    local l
    for l in "${TS_PORTS[@]}"; do note "$(printf '%s' "$l" | sed 's/\t/  /g')"; done
  fi
  say ""
  say "  ${BOLD}Decisions gathered:${RESET}"
  local gw_h tr_h reach_h
  case "$GW_KIND" in
    openclaw) gw_h="OpenClaw" ;; hermes) gw_h="Hermes" ;;
    custom)   gw_h="your OpenAI-compatible server" ;; *) gw_h="${GW_KIND:-?}" ;;
  esac
  case "$TRANSPORT" in
    tailscale) tr_h="Tailscale (private)" ;; funnel) tr_h="Tailscale Funnel (public)" ;;
    cloudflare) tr_h="Cloudflare Tunnel (public)" ;; public) tr_h="your own HTTPS (trusted cert)" ;;
    selfsigned) tr_h="your own HTTPS (pinned cert)" ;; *) tr_h="to be decided during exposure" ;;
  esac
  case "$SCOPE" in
    public) reach_h="public (anyone with the URL)" ;; private) reach_h="private (your devices only)" ;;
    *) reach_h="to be decided during exposure" ;;
  esac
  note "gateway = $gw_h${GW_NAME:+ ($GW_NAME)}   reach = $reach_h   how = $tr_h"
  note "gateway URL = ${GW_URL:-<set during exposure>}"
  [ -n "$GW_CERT_FP" ] && note "self-signed pin = $GW_CERT_FP"
  say ""
  if [ ${#PLAN[@]} -eq 0 ]; then
    note "Nothing to change — everything needed already exists (a real run would just verify + emit the QR)."
  else
    say "  ${BOLD}Actions a real run would take (in order):${RESET}"
    local a; for a in "${PLAN[@]}"; do say "    • $a"; done
  fi
  say ""
  note "No secrets were prompted, no credentials minted, no requests sent, no QR emitted (the QR appears only on a real run)."
  say "  Re-run without --dry-run to apply and show the QR (each change still asks first)."
}

# --------------------------------------------------------------- --show-qr fast path --
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
  case "$hp" in *:*) printf '%s' "${hp##*:}" ;; *) printf '443' ;; esac
}

# The host part of an https URL, lowercased. Same authority parse as
# show_qr_is_https_host (ends at the first /, ? or #; strips a trailing :port) so the
# two always agree. Empty output when the URL isn't https://. Used to prove a profile
# URL names THIS tailnet machine.
url_host_lc() { # url_host_lc <https-url>
  case "$1" in https://*) ;; *) return 0 ;; esac
  local a="${1#https://}"; a="${a%%[/?#]*}"
  local h="$a"; case "$a" in *:*) h="${a%:*}" ;; esac
  printf '%s' "$h" | tr '[:upper:]' '[:lower:]'
}

# Does a saved profile's gateway.kind match an explicit --openclaw/--hermes/--generic?
# No mode flag → every profile matches.
profile_matches_mode() { # profile_matches_mode <kind>
  case "$MODE" in
    "")       return 0 ;;
    openclaw) [ "$1" = "openclaw" ] ;;
    hermes)   [ "$1" = "hermes" ] ;;
    generic)  [ "$1" = "custom" ] ;;
    *)        return 0 ;;
  esac
}

# Discover saved profiles and set PROFILE_FILE. None → friendly die; one (or one
# matching the mode flag) → use it; several → numbered pick via require_choice.
# Dies directly (not via $()) so a "no profile" die halts the whole script.
PROFILE_FILE=""
show_qr_pick_profile() {
  local pf; local all=(); local cand=()
  for pf in "$STATE_DIR"/profile-*.json; do
    [ -e "$pf" ] || continue          # no matches → the literal glob; skip it
    all+=("$pf")
  done
  [ ${#all[@]} -gt 0 ] || die "No saved pairing profile on this machine yet — run the wizard once (bash conduck-connect.sh) to pair and save one. From then on, --show-qr re-shows the code, skipping the setup questions (it may still ask you to pick a profile, re-enter a custom gateway's token, or confirm a gateway-only code)."
  local k
  for pf in "${all[@]}"; do
    k=$(json_get "$pf" "gateway.kind")
    profile_matches_mode "$k" && cand+=("$pf")
  done
  [ ${#cand[@]} -gt 0 ] || die "No saved pairing profile matches --$MODE on this machine. Re-run --show-qr without the mode flag to pick from all saved profiles, or run the wizard to create one."
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

# --show-qr profile-validation helpers (bash 3.2-safe, secret-free — they inspect only
# routing facts, never tokens). Used by show_qr_load_profile to reject a hand-edited or
# corrupted profile up front, before any secret recovery or live probe.
show_qr_is_https_host() { # show_qr_is_https_host <url> -> 0 iff https:// + sane authority
  # Real authority parse — a bare `%%/*` host grab let https://?query, https://#frag
  # and https://user:pass@host slip through. Authority ends at the first /, ? or #;
  # userinfo is rejected (the wizard never emits it); an explicit :port must be a
  # real port; the host may contain only [A-Za-z0-9.-].
  case "$1" in https://*) ;; *) return 1 ;; esac
  local a="${1#https://}"; a="${a%%[/?#]*}"
  case "$a" in *@*) return 1 ;; esac
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
  local sv; sv=$(json_get "$PROFILE_FILE" "schemaVersion")
  [ "$sv" = "1" ] || die "That saved profile uses schema version '${sv:-unknown}', which this script ($VERSION) doesn't understand — a newer conduck-connect wrote it. Update this script, then try again (or run the wizard once to rewrite it)."

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
  [ -n "$GW_KIND" ] && [ -n "$GW_ID" ] && [ -n "$GW_URL" ] && [ -n "$TRANSPORT" ] && [ -n "$GW_AUTH" ] \
    || die "That saved profile is missing required fields (kind/id/url/transport/auth) — re-run the wizard (bash conduck-connect.sh) to refresh it."

  # ---- Schema validation. A hand-edited or corrupted profile (http:// URL, a kind the
  # apps reject, a garbage port) must die HERE with a friendly, secret-free message —
  # not sail through verification and hand the app a code it silently rejects. ----
  case "$GW_KIND" in
    openclaw|hermes|custom) ;;
    *) die "That saved profile names an unknown gateway kind '$GW_KIND' — this tool pairs only openclaw, hermes, or custom gateways. Re-run the wizard (bash conduck-connect.sh) to refresh it." ;;
  esac
  # tr -d [:space:]: a whitespace-only name passes -n but the app trims and rejects it.
  [ "$GW_KIND" != "custom" ] || [ -n "$(printf '%s' "$GW_NAME" | tr -d '[:space:]')" ] \
    || die "That saved profile is a custom gateway but stores no name (or only whitespace) — re-run the wizard (bash conduck-connect.sh) to refresh it."
  case "$GW_AUTH" in
    bearer|none) ;;
    *) die "That saved profile has an unknown auth mode '$GW_AUTH' — it must be 'bearer' or 'none'. Re-run the wizard (bash conduck-connect.sh) to refresh it." ;;
  esac
  show_qr_is_https_host "$GW_URL" \
    || die "That saved profile's gateway URL isn't a valid https:// address with a host — re-run the wizard (bash conduck-connect.sh) to refresh it."
  case "$TRANSPORT" in
    tailscale|funnel|cloudflare|public|selfsigned) ;;
    *) die "That saved profile has an unrecognized transport '$TRANSPORT' — re-run the wizard (bash conduck-connect.sh) to refresh it." ;;
  esac
  [ "$TRANSPORT" != "selfsigned" ] || [ -n "$GW_CERT_FP" ] \
    || die "That saved profile uses a self-signed certificate but stores no fingerprint — re-run the wizard (bash conduck-connect.sh) to refresh it."
  # The wizard writes a certFP ONLY on the self-signed path; anywhere else it would
  # import a WRONG pin into the app.
  [ "$TRANSPORT" = "selfsigned" ] || [ -z "$GW_CERT_FP" ] \
    || die "That saved profile pins a certificate but doesn't use the self-signed path — the app would import a wrong pin. Re-run the wizard (bash conduck-connect.sh) to refresh it."
  [ -z "$GW_LOCAL_PORT" ] || show_qr_is_port "$GW_LOCAL_PORT" \
    || die "That saved profile's gateway local port isn't a number in 1-65535 — re-run the wizard (bash conduck-connect.sh) to refresh it."
  [ -z "$GW_CERT_FP" ] || show_qr_is_certfp "$GW_CERT_FP" \
    || die "That saved profile's gateway certificate fingerprint isn't a 64-character lowercase hex value — re-run the wizard (bash conduck-connect.sh) to refresh it."
  # File-lane half (read straight from the profile — the credential itself is never stored).
  local _fsurl _fsport _fsfp
  _fsurl=$(json_get "$PROFILE_FILE" "fileServer.url")
  _fsport=$(json_get "$PROFILE_FILE" "fileServer.localPort")
  _fsfp=$(json_get "$PROFILE_FILE" "fileServer.certFP")
  if [ -n "$_fsurl" ]; then
    show_qr_is_https_host "$_fsurl" \
      || die "That saved profile's file-server URL isn't a valid https:// address with a host — re-run the wizard (bash conduck-connect.sh) to refresh it."
  fi
  [ -z "$_fsport" ] || show_qr_is_port "$_fsport" \
    || die "That saved profile's file-server local port isn't a number in 1-65535 — re-run the wizard (bash conduck-connect.sh) to refresh it."
  [ -z "$_fsfp" ] || show_qr_is_certfp "$_fsfp" \
    || die "That saved profile's file-server certificate fingerprint isn't a 64-character lowercase hex value — re-run the wizard (bash conduck-connect.sh) to refresh it."
  [ "$TRANSPORT" = "selfsigned" ] || [ -z "$_fsfp" ] \
    || die "That saved profile pins a file-server certificate but doesn't use the self-signed path — the app would import a wrong pin. Re-run the wizard (bash conduck-connect.sh) to refresh it."

  # Health path is derived from kind (not stored), exactly as the wizard sets it.
  case "$GW_KIND" in
    openclaw) GW_HEALTH_PATH="/healthz" ;;
    hermes)   GW_HEALTH_PATH="/v1/health" ;;
    *)        GW_HEALTH_PATH="" ;;
  esac
  # Local port: prefer the profile; else re-detect from the gateway config like the wizard.
  if [ -z "$GW_LOCAL_PORT" ]; then
    case "$GW_KIND" in
      openclaw)
        local compose_dir="${OPENCLAW_DIR:-$HOME/openclaw}" praw
        praw=$(env_get "$compose_dir/.env" "OPENCLAW_GATEWAY_PORT")
        GW_LOCAL_PORT="${praw##*:}"; GW_LOCAL_PORT="${GW_LOCAL_PORT:-18789}"
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
      local cfg="$HOME/.openclaw/openclaw.json"
      [ -f "$cfg" ] || die "Can't find $cfg to read the gateway token — is this the machine you paired on? Re-run the wizard (bash conduck-connect.sh) if OpenClaw moved."
      GW_TOKEN=$(json_get "$cfg" "gateway.auth.token")
      [ -n "$GW_TOKEN" ] || die "No token at gateway.auth.token in $cfg — refusing to emit a keyless code (auth is explicit). Fix the gateway config, then re-run."
      ok "Re-read the gateway bearer token from openclaw.json (not shown)."
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
    [ -n "$saved_folder" ] && FS_FOLDER="$saved_folder"
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
        show_qr_assert_mapping "$fs_host" "$(url_https_port "$FS_URL")" "$FS_LOCAL_PORT" "$want_verb" "file lane" || show_qr_stale
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

# Orchestrate the --show-qr path: pick → load → secrets → live-match gate, then the
# UNCHANGED verify_all + emit_payload. Nothing here mutates (REUSE_ONLY is forced on),
# so APPLIED/FS_APPLIED stay empty and cleanup_exposures has nothing to undo.
run_show_qr() {
  head_ "Re-show your pairing code (--show-qr) — skips the setup questions, changes nothing"
  show_qr_pick_profile
  show_qr_load_profile
  show_qr_recover_gateway_secret
  show_qr_recover_file_lane
  show_qr_check_live
  verify_all
  emit_payload
}

# ----------------------------------------------------------------------- main --

say "${BOLD}conduck-connect $VERSION${RESET} — pair your self-hosted AI gateway with Conduck."
$DRY_RUN && note "(dry-run: nothing will be changed)"
# --show-qr forces REUSE_ONLY on, so print its OWN banner instead of the reuse-only one.
if $SHOW_QR; then note "(--show-qr: re-showing a saved pairing code — skips the setup questions, changes nothing; may still ask you to pick a profile or re-enter a custom token)"
elif $REUSE_ONLY; then note "(reuse-only: I'll reuse what's set up and refuse any change — safe to run on a gateway you don't want touched)"; fi
say "Every change asks first. No telemetry — nothing goes anywhere except your own gateway (to verify it). Ctrl-C any time."
note "Two kinds of step: things I made (I offer to run them for you), and things you already own — your gateway config, Tailscale, daemons — which I never touch; I print the exact command for you to run."

# --show-qr: skip the whole wizard — reconstruct from a saved profile, then verify + emit.
if $SHOW_QR; then
  run_show_qr
  exit 0
fi

# Gateway selection → configure → transport, looped so the transport menu's "b"
# can return to the gateway choice. No EXPOSURE change has happened before the
# menu; Step-2 gateway-config changes are detect-and-reuse on re-entry. Globals
# reset each pass so "b" never leaks one gateway's answers (name/model/URL)
# into the next pick's payload.
while true; do
  GW_KIND=""; GW_ID=""; GW_NAME=""; GW_LOCAL_PORT=""; GW_HEALTH_PATH=""
  GW_AUTH="bearer"; GW_TOKEN=""; GW_MODEL=""; GW_URL=""; GW_CERT_FP=""
  detect_gateway
  case "$GW_KIND" in
    openclaw) configure_openclaw ;;
    hermes)   configure_hermes ;;
    custom)   configure_generic ;;
  esac
  choose_exposure && break
  rc=$?
  [ "$rc" = "10" ] || break   # 10 = user chose "back"; any other non-zero already died
  say ""; note "↩ Back to the gateway choice."
done
setup_file_lane

if $DRY_RUN; then
  print_plan
  exit 0
fi

verify_all
emit_payload
