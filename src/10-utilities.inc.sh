# ---------------------------------------------------------------- utilities --

# Colour is keyed on stdout being a terminal, not on $TERM alone: a redirected or
# piped run (CI parsing [CHECK_ID] lines) must get clean text, never escape soup.
if [ -t 1 ]; then
  BOLD=$(tput bold 2>/dev/null || true); DIM=$(tput dim 2>/dev/null || true)
  RED=$(tput setaf 1 2>/dev/null || true); GREEN=$(tput setaf 2 2>/dev/null || true)
  YELLOW=$(tput setaf 3 2>/dev/null || true); RESET=$(tput sgr0 2>/dev/null || true)
else
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; RESET=""
fi

say()  { printf '%s\n' "$*"; }
head_() { printf '\n%s%s%s\n' "$BOLD" "$*" "$RESET"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$RED" "$RESET" "$*"; }
note() { printf '  %s%s%s\n' "$DIM" "$*" "$RESET"; }
warn() { printf '%s! %s%s\n' "$YELLOW" "$*" "$RESET"; }
die()  { printf '%sError:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }
usage_die() { printf '%sUsage error:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 2; }

# The ONE sanitiser for gateway-supplied text on its way to the terminal — model
# ids, Content-Type values, wire error codes. A gateway is not trusted to be
# friendly: an embedded newline forges an extra "[CHECK_ID] …" line in the check
# transcript (a hostile server printing its own green PASS), and an ANSI escape
# repaints or erases what the operator already read. Strips every C0 control and
# DEL, then bounds the length so one reply cannot flood the run. Applied where a
# value LEAVES its parser, so every later print site inherits it.
# `tr`, not python3: this runs on failure paths, and a display helper must not be
# able to fail. C1 (0x80-0x9F) is deliberately left alone — in a UTF-8 terminal
# those bytes only occur inside multi-byte characters, and deleting them would
# mangle a legitimate non-ASCII model id.
safe_display() { # safe_display <value> [max-chars, default 120] -> printable, bounded
  local max="${2:-120}" s
  s=$(printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177' 2>/dev/null)
  [ "${#s}" -le "$max" ] || s="${s:0:$max}…"
  printf '%s' "$s"
}

# https://user:pass@host is a legal URL that NO endpoint here may carry. It is a
# credential the app would have to store inside a routing field, and this script
# echoes the URL back on screen, writes it to the pairing profile that
# WHAT-IT-TOUCHES.md calls credential-free, and puts it in the QR. The Conduck app
# refuses userinfo on every persisted endpoint URL, on write and on read alike;
# the connector has to agree, or the wizard happily emits a code the app rejects.
# Pure Bash — doctor_accept_url calls this before the runtime preflight, so it may
# not depend on python3/curl existing. The authority ends at the first / ? or #.
url_has_userinfo() { # url_has_userinfo <url> -> 0 when the authority carries user[:pass]@
  case "$1" in *://*) ;; *) return 1 ;; esac   # no scheme, no authority — let the scheme check answer
  local a="${1#*://}"; a="${a%%[/?#]*}"
  case "$a" in *@*) return 0 ;; *) return 1 ;; esac
}
URL_USERINFO_HINT="Credentials don't belong in the address. Drop the \"user:pass@\" part and give the plain URL — the token goes in the token prompt, not the URL."

DRY_RUN=false
REUSE_ONLY=false
SHOW_QR=false
ALLOW_KEYLESS_PUBLIC=false
DOCTOR=false
DOCTOR_DEEP=false
DOCTOR_FILES=false
COMPAT=false
CHECK_URL=""
COMMAND=""         # menu | setup | check-server | check-adapter | show-code
SETUP_FROM_CHECK=false
CLI_ARG_COUNT=$#
# Legacy compatibility (see the --generic arm below). SETUP_GATEWAY_HINT skips
# gateway detection entirely; it is set ONLY by --generic and never by the new CLI.
SETUP_GATEWAY_HINT=""
LEGACY_GENERIC=false

set_command() { # set_command <command>
  if [ -n "$COMMAND" ]; then
    usage_die "Choose one action only: --setup, --check-server, --check-adapter, or --show-code."
  fi
  COMMAND="$1"
}

# Temporary pre-0.13 subcommand spellings were published briefly. They do not
# remain aliases, but people following an old instruction deserve the exact
# replacement instead of a generic positional-argument failure.
case "${1:-}:${2:-}" in
  setup:*)       usage_die "The retired setup subcommand is now --setup (try --help)." ;;
  show-code:*)   usage_die "The retired show-code subcommand is now --show-code (try --help)." ;;
  check:server)  usage_die "The retired check server form is now --check-server [url] (try --help)." ;;
  check:adapter) usage_die "The retired check adapter form is now --check-adapter [url] (try --help)." ;;
esac

for arg in "$@"; do
  case "$arg" in
    --setup)         set_command "setup" ;;
    --check-server)  set_command "check-server" ;;
    --check-adapter) set_command "check-adapter" ;;
    --show-code)     set_command "show-code" ;;
    --dry-run)  DRY_RUN=true ;;
    --reuse-only) REUSE_ONLY=true ;;
    --allow-keyless-public) ALLOW_KEYLESS_PUBLIC=true ;;
    --deep)     DOCTOR_DEEP=true ;;
    --files)    DOCTOR_FILES=true ;;
    --version)
      [ "$CLI_ARG_COUNT" = "1" ] || usage_die "--version must be used by itself."
      say "conduck-connect $VERSION"; exit 0 ;;
    -h|--help)
      [ "$CLI_ARG_COUNT" = "1" ] || usage_die "$arg must be used by itself."
      sed -n '2,${/^#/!q;s/^# \{0,1\}//p;}' "$0"; exit 0 ;;   # whole header comment, wherever it ends
    # --- compatibility with pre-0.13.0 spellings -------------------------------
    # Conduck app builds already on the App Store emit `--generic` verbatim, and
    # every client resolves releases/latest, so an old install always downloads the
    # newest script. --generic therefore stays FUNCTIONAL (not merely diagnosed) and
    # cannot be removed on a later release while those builds exist. It is
    # compatibility plumbing: deliberately absent from --help and the welcome menu.
    # It preserves its original meaning — skip gateway detection so a stray OpenClaw
    # or Hermes install on the same host can never become the default.
    --generic)
      set_command "setup"
      SETUP_GATEWAY_HINT="custom"
      LEGACY_GENERIC=true ;;
    # The rest were only ever typed by a human from docs, so a named error that
    # points at the replacement is enough — no behavior is preserved.
    --doctor)   usage_die "--doctor is now --check-adapter (try --help)." ;;
    --compat)   usage_die "--compat is now --check-server (try --help)." ;;
    --show-qr)  usage_die "--show-qr is now --show-code (try --help)." ;;
    --openclaw|--hermes)
      usage_die "$arg is gone — run --setup and pick your gateway from the list (try --help)." ;;
    -*) usage_die "Unknown argument: $arg (try --help)" ;;
    *)  if [ -z "$CHECK_URL" ]; then CHECK_URL="$arg"
        else usage_die "Unknown argument: $arg (try --help)"; fi ;;
  esac
done

if [ -z "$COMMAND" ]; then
  if [ "$CLI_ARG_COUNT" = "0" ]; then
    COMMAND="menu"
  else
    usage_die "Choose an action: --setup, --check-server, --check-adapter, or --show-code (try --help)."
  fi
fi

# Is this a real person at a terminal? Checks use this to offer setup after a
# PASS. A CI job or redirected/piped invocation must always print its summary
# and exit without waiting for an answer.
interactive_terminal() {
  case "${CI:-}" in 1|true|TRUE|yes|YES) return 1 ;; esac
  [ -t 0 ] && [ -t 1 ]
}

# True only when a profile this version can actually use exists. The validator
# is defined in the --show-code module and shared with its picker/loader, so the
# menu can never advertise an entry those paths would reject moments later.
#
# A profile FILE that exists and does NOT validate is a third state, and it has to
# be carried out of here rather than folded into "no profile": the two lead to
# opposite advice. "Run setup once" rewrites profile-<id>.json, so offering it for
# a file a NEWER conduck-connect wrote is how an older script destroys recoverable
# state. The count and the validator's own first reason travel back with the
# answer — the validator is the only place that knows whether the file is corrupt
# (setup IS the fix) or from the future (updating this script is).
SAVED_PROFILE_REJECTED=0
SAVED_PROFILE_REJECT_REASON=""
saved_profile_exists() {
  local p
  SAVED_PROFILE_REJECTED=0
  SAVED_PROFILE_REJECT_REASON=""
  for p in "$STATE_DIR"/profile-*.json; do
    [ -f "$p" ] || continue
    if show_qr_validate_profile "$p"; then
      # A usable profile answers the question; the rejections behind it are the
      # picker's business, not the menu's.
      SAVED_PROFILE_REJECTED=0
      SAVED_PROFILE_REJECT_REASON=""
      return 0
    fi
    SAVED_PROFILE_REJECTED=$((SAVED_PROFILE_REJECTED+1))
    [ -n "$SAVED_PROFILE_REJECT_REASON" ] || SAVED_PROFILE_REJECT_REASON="$PROFILE_VALIDATION_ERROR"
  done
  return 1
}

choose_main_action() {
  # Evaluated ONCE: the answer decides three lines below it, and each validation
  # pass re-parses every profile on disk.
  local have_saved=false
  saved_profile_exists && have_saved=true
  say "${BOLD}Welcome to Conduck Connect${RESET}"
  if $have_saved; then
    say "Set up a gateway, check one before pairing, or re-show a saved setup code."
  else
    say "Set up a gateway, or check one before pairing."
  fi
  # Option 4 genuinely cannot be offered for a profile this version cannot read,
  # but going quiet about it is what turns an unreadable profile into a lost one:
  # the operator reads "no saved code", picks 1, and setup overwrites the file.
  if ! $have_saved && [ "$SAVED_PROFILE_REJECTED" -gt 0 ]; then
    say ""
    if [ "$SAVED_PROFILE_REJECTED" = "1" ]; then
      warn "There IS a saved setup code on this machine, and this version can't read it — so \"Show a saved setup code\" is not on the list below."
    else
      warn "There are $SAVED_PROFILE_REJECTED saved setup codes on this machine, and this version can't read any of them — so \"Show a saved setup code\" is not on the list below."
    fi
    note "$SAVED_PROFILE_REJECT_REASON"
    note "Setting up again REPLACES the saved file, so read that line before choosing 1."
  fi
  say ""
  say "  What would you like to do?"
  say "    1) Set up and pair a gateway"
  say "    2) Check existing OpenAI-compatible software (not built for Conduck)"
  say "    3) Check an adapter built specifically for Conduck"
  if $have_saved; then
    say "    4) Show a saved setup code"
  fi
  say "    q) Exit"
  say ""
  local choice regex='^([1-3]|[qQ])$'
  $have_saved && regex='^([1-4]|[qQ])$'
  choice=$(require_choice "Choose an option" "$regex" "nav.main") || die "$NO_ANSWER"
  case "$choice" in
    1) COMMAND="setup" ;;
    2) COMMAND="check-server" ;;
    3) COMMAND="check-adapter" ;;
    4) COMMAND="show-code" ;;
    q|Q) COMMAND="exit" ;;
  esac
}

validate_cli() {
  DOCTOR=false; COMPAT=false; SHOW_QR=false
  case "$COMMAND" in
    setup)
      [ -z "$CHECK_URL" ] || usage_die "A URL argument only works with --check-server or --check-adapter."
      $DOCTOR_DEEP && usage_die "--deep only works with --check-adapter."
      $DOCTOR_FILES && usage_die "--files only works with --check-adapter."
      ;;
    check-server)
      COMPAT=true
      if [ -n "$CHECK_URL" ] && ! doctor_accept_url "$CHECK_URL" >/dev/null; then
        # The userinfo case gets its own message, and deliberately does NOT echo
        # the URL back: the rejected value contains the password.
        url_has_userinfo "$CHECK_URL" && usage_die "$URL_USERINFO_HINT"
        usage_die "Can't test '$CHECK_URL' — use https://… (or http://127.0.0.1:<port> for a local test)."
      fi
      $DRY_RUN && usage_die "--check-server sends live requests, so it doesn't combine with --dry-run."
      $REUSE_ONLY && usage_die "--reuse-only is a setup modifier; --check-server already changes no host configuration."
      $DOCTOR_DEEP && usage_die "--deep only works with --check-adapter; --check-server already reports image capability."
      $DOCTOR_FILES && usage_die "--files only works with --check-adapter."
      $ALLOW_KEYLESS_PUBLIC && usage_die "--allow-keyless-public is a setup modifier; --check-server never publishes anything."
      REUSE_ONLY=true
      ;;
    check-adapter)
      DOCTOR=true
      if [ -n "$CHECK_URL" ] && ! doctor_accept_url "$CHECK_URL" >/dev/null; then
        # The userinfo case gets its own message, and deliberately does NOT echo
        # the URL back: the rejected value contains the password.
        url_has_userinfo "$CHECK_URL" && usage_die "$URL_USERINFO_HINT"
        usage_die "Can't test '$CHECK_URL' — use https://… (or http://127.0.0.1:<port> for a local test)."
      fi
      $DRY_RUN && usage_die "--check-adapter sends live requests, so it doesn't combine with --dry-run."
      $REUSE_ONLY && usage_die "--reuse-only is a setup modifier; --check-adapter already changes no host configuration unless --files is requested."
      $ALLOW_KEYLESS_PUBLIC && usage_die "--allow-keyless-public is a setup modifier; --check-adapter never publishes anything."
      REUSE_ONLY=true
      ;;
    show-code)
      SHOW_QR=true
      [ -z "$CHECK_URL" ] || usage_die "A URL argument only works with --check-server or --check-adapter."
      $DRY_RUN && usage_die "--show-code changes no configuration but performs live verification; it doesn't combine with --dry-run."
      $DOCTOR_DEEP && usage_die "--deep only works with --check-adapter."
      $DOCTOR_FILES && usage_die "--files only works with --check-adapter."
      $ALLOW_KEYLESS_PUBLIC && usage_die "--allow-keyless-public is a setup modifier."
      REUSE_ONLY=true
      ;;
    exit) ;;
    *) die "Internal error: unknown action '$COMMAND'." ;;
  esac
}

# PLAN[] accumulates human-readable "would do" lines for --dry-run.
PLAN=()
plan_add() { PLAN+=("$*"); }

# Explain one bounded prompt without changing its answer. Most callers pass an
# action id that the explanation catalogue resolves; the few older/specialised
# menus pass their existing help function instead. Keeping this indirection here
# makes the prompt primitives usable in isolated tests and in partial-source
# harnesses too: when the catalogue is not loaded, `i` still gives an honest
# generic explanation rather than failing.
explain_prompt() { # explain_prompt [action-id | help-function]
  local help="${1:-}"
  case "$help" in
    ''|*[!a-zA-Z0-9_]*) ;;
    *) if declare -F "$help" >/dev/null 2>&1; then "$help"; return 0; fi ;;
  esac
  if declare -F explain_action >/dev/null 2>&1; then
    explain_action "${help:-general}"
    return 0
  fi
  say ""
  say "  ${BOLD}About this step${RESET}"
  say "  This question controls the action described immediately above it."
  say "  Answering No or skipping leaves that action undone; it does not undo"
  say "  anything you approved earlier in this run."
  say ""
}

quit_run() { # stop cleanly; EXIT traps still report any exposure undo commands
  say ""
  note "Stopped here. No further setup actions will run."
  note "This does not undo changes you already approved: config edits, restarts,"
  note "services, folders, and commands stay in place."
  note "If this run applied a tracked Tailscale exposure, its exact undo commands"
  note "are printed below and kept for the next run. A Cloudflare or reverse-proxy"
  note "command you ran remains yours to undo."
  exit 0
}

confirm() {  # confirm "question" [action-id] [allow-back] -> 0 yes / 1 no / 10 back
  local reply action="${2:-general}" allow_back="${3:-false}" controls
  controls="Enter = No; i = explain; q = stop"
  case "$allow_back" in true|1|yes) controls="Enter = No; i = explain; b = back; q = stop" ;; esac
  while true; do
    read -r -p "$1 [y/N] ($controls): " reply || return 1
    case "$reply" in
      [yY]|[yY][eE][sS]) return 0 ;;
      ''|[nN]|[nN][oO]) return 1 ;;
      [iI]|\?) explain_prompt "$action" ;;
      [qQ]) quit_run ;;
      [bB])
        case "$allow_back" in true|1|yes) return 10 ;; esac
        warn "Back is not available at this step; choose Yes, No, info, or stop."
        ;;
      *) warn "Please answer y or n, press Enter for No, i for an explanation, or q to stop." ;;
    esac
  done
}

ask() {  # ask "prompt" "default" [blank-meaning] -> echoes answer
  local reply blank_meaning="${3:-leave blank}"
  if [ -n "${2:-}" ]; then
    read -r -p "$1 (Enter = $2): " reply
  else
    read -r -p "$1 (Enter = $blank_meaning): " reply
  fi
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
# Returns NONZERO when the input ended (EOF) rather than when the user chose an
# empty answer. The two are not the same: a deliberate Enter is the app's explicit
# keyless scheme, while EOF means nobody was asked at all. Callers that treat an
# empty token as "keyless" MUST pair this with `|| die`, or a redirected run would
# infer no-auth from a missing answer — the fail-closed-auth invariant.
ask_secret() {  # ask_secret "prompt" "empty-meaning" -> secret (hidden); 1 on EOF
  local reply rc=0 empty_meaning="${2:-leave empty}"
  read -rs -p "  $1 (Enter = $empty_meaning): " reply || rc=1
  printf '\n' >&2
  printf '%s' "$reply"
  return $rc
}

# A choice with NO Enter-default — loops until the answer matches the regex.
# Callers capture this with $(), so EVERY human-facing line goes to stderr —
# a retry warning on stdout would be captured as part of the answer, and a typo
# would then silently decide a safety question. On EOF it RETURNS NONZERO rather
# than calling die: a `die` inside $() kills only the subshell, so the parent
# must be the one to stop (every caller pairs this with `|| die`).
# Optional 3rd arg names an action id or help function: answering `i` (or the
# older `?` alias) prints it and re-asks. `q` is always recognised, even when the
# caller's own regex does not list it. Because callers capture this function with
# $(), it ECHOES the literal sentinel `q`; the parent caller must call quit_run.
# Help is ADDITIVE only — it explains the same options in plain words, never
# changes them (the canonical menu/prompt strings stay the single source).
# The help function's stdout is redirected to stderr here, same $()-capture rule.
require_choice() {  # require_choice "prompt" "regex" [action-id | help-fn] -> choice | q
  local reply
  while true; do
    read -r -p "  $1 (Enter = no default; i = explain; q = stop): " reply \
      || return 1     # closed stdin — never spin the loop
    case "$reply" in
      [iI]|\?) explain_prompt "${3:-general}" >&2; continue ;;
      [qQ]) printf 'q'; return 0 ;;
    esac
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
    if [ "$allow_blank" = "1" ]; then
      read -r -p "  https URL (e.g. $example; Enter = skip) > " reply || return 1
    else
      read -r -p "  https URL (e.g. $example; Enter = no default) > " reply || return 1
    fi
    reply="${reply#"${reply%%[![:space:]]*}"}"; reply="${reply%"${reply##*[![:space:]]}"}"
    while [ "${reply%/}" != "$reply" ]; do reply="${reply%/}"; done   # trailing / would make //v1/… requests
    if [ -z "$reply" ]; then
      [ "$allow_blank" = "1" ] && return 0
      warn "Please enter an https:// URL, for example $example." >&2; continue
    fi
    case "$reply" in [Hh][Tt][Tt][Pp][Ss]://*) reply="https://${reply#*://}" ;; esac
    if url_has_userinfo "$reply"; then
      warn "$URL_USERINFO_HINT" >&2; continue
    fi
    case "$reply" in
      https://?*) printf '  %s→ using %s%s\n' "$DIM" "$reply" "$RESET" >&2; printf '%s' "$reply"; return 0 ;;
      http://*)   warn "That's http:// — Conduck requires https:// (encrypted). Try again." >&2 ;;
      *)          warn "That has to start with https:// — for example $example. Try again." >&2 ;;
    esac
  done
}

# Rung 1 of the consent ladder: a single command we run for you, with consent.
# In --dry-run it is only recorded; in --reuse-only it is refused (see mutate_guard).
# Action ids affect explanation copy only; the command, mutation guard and
# consent result are otherwise unchanged.
run_step() {  # run_step "action-id" "description" cmd args...
  local action="$1" desc="$2"; shift 2
  if $DRY_RUN; then plan_add "RUN  $*"; note "(dry-run: would run — $desc)"; return 0; fi
  mutate_guard "$desc" || return 1
  say ""
  say "  I'd like to run:  ${BOLD}$*${RESET}"
  if confirm "  Run it now?" "$action"; then "$@"; else
    warn "Skipped: $desc"
    return 1
  fi
}

file_mode_is_open() { # file_mode_is_open <file> [octal mask, default 077] -> 0 when a mask bit is set
  # python3 is a hard preflight requirement on every path that calls this; a
  # missing one answers "not open" and stays quiet rather than warning blindly.
  # The mask is a parameter because "another account can READ this" and "another
  # account can REPLACE this" are different harms that need different words: 077
  # is any access at all, 022 is group/other WRITE.
  python3 -c 'import os,sys; sys.exit(0 if os.stat(sys.argv[1]).st_mode & int(sys.argv[2], 8) else 1)' \
    "$1" "${2:-77}" 2>/dev/null
}

# Rung 1b: a file the USER owns whose MODE is too open for a secret we just helped
# put in it. A file's permissions are part of its configuration, so this goes
# through run_step like any other change to something we did not create — the
# exact command is printed and nothing happens without a yes. A silent chmod
# would break "never changes a config it didn't create without showing you the
# exact change first" even though it touches no content.
# The two NON-success arms carry as much weight as the success one: a declined or
# failed chmod leaves a live credential readable by every account on the box, and
# going quiet there would be a worse outcome than the silent chmod this gate
# replaced. So the final state is RE-READ from the file rather than inferred from
# run_step's exit code — "still exposed" is then a fact about the file, not a
# guess about why, and it is correct whether the user declined, the chmod failed,
# or something else moved the mode underneath us.
secure_owned_file_mode() { # secure_owned_file_mode <file> <what-is-inside> -> 1 if still open
  local f="$1" what="$2"
  file_mode_is_open "$f" || return 0
  warn "$f can be read by other accounts on this machine — $what is inside it."
  run_step "security.owned_file.chmod_0600" \
    "tighten $f to 0600 so only you can read $what" chmod 600 "$f" || true
  if $DRY_RUN; then return 0; fi     # run_step only recorded the plan; nothing changed yet
  if file_mode_is_open "$f"; then
    warn "$what is STILL readable by other accounts on this machine."
    warn "Fix it when you can:  chmod 600 $f"
    return 1
  fi
  ok "Tightened — only you can read $f now."
  return 0
}

# The ONE way $STATE_DIR is created. It holds fileserver-*.cred/.env and
# profile-*.json, so it is created 0700: at the ambient 0755 any other account
# on the box can list which gateways this user has paired, and the file names
# alone carry that.
#
# `mkdir -p` is a no-op on a directory that ALREADY exists, mode included, so
# creating it under `umask 077` only ever secures a first run. A $STATE_DIR that
# an earlier version, a different umask, or the user's own `mkdir` left open keeps
# that mode for good — the files inside stay 0600, but the directory holding them
# does not, and nothing ever says so. A directory we may not have created is not
# re-chmodded silently (same rule as the agent workspace), so the exposure is
# REPORTED, once per run, with the exact fix.
#
# Group/other WRITE is graded apart from read, because the read wording badly
# understates it. 0600 on fileserver-<id>.cred protects what is INSIDE the file;
# in a writable directory any local account can replace the whole file, and
# rclone then reads its password out of somebody else's copy at the next start.
# Same for profile-<id>.json, which is the record --show-code rebuilds a pairing
# code from.
STATE_DIR_EXPOSURE_REPORTED=false
ensure_state_dir() {  # -> 1 when the directory does not exist and could not be created
  ( umask 077; mkdir -p "$STATE_DIR" ) 2>/dev/null || return 1
  $STATE_DIR_EXPOSURE_REPORTED && return 0
  file_mode_is_open "$STATE_DIR" || return 0
  STATE_DIR_EXPOSURE_REPORTED=true
  if file_mode_is_open "$STATE_DIR" 22; then
    warn "$STATE_DIR is WRITABLE by other accounts on this machine (it already existed with that mode)."
    warn "Any local account can swap the files in it — including the file-server password rclone reads when it starts, and the saved profile that says where your gateway is."
    warn "Their 0600 protects what is inside those files, not the folder that holds them."
  else
    warn "$STATE_DIR can be listed by other accounts on this machine (it already existed with that mode)."
    warn "The credential files inside are 0600, but the folder itself names every gateway you have paired."
  fi
  warn "Fix it when you can:  chmod 700 $STATE_DIR"
  return 0
}

# ------------------------------------------------------ single-instance setup --
# Two setup runs at once are not merely racy, they are silently destructive. Both
# scan the same loopback range and settle on the SAME free port (the bind probe
# closes its socket immediately, so it reserves nothing), both write
# conduck-files-$GW_ID and fileserver-$GW_ID.cred/.env, and both finish by writing
# profile-$GW_ID.json — which is a whole-file overwrite, so a run whose lane lost
# the port race erases a live file server from the record the winner just saved.
# Sequential re-runs are idempotent by design; only the overlap breaks.
#
# `mkdir` is the gate, not `flock`: macOS ships no flock binary, and mkdir is the
# one create-or-fail primitive that is atomic on every filesystem a $HOME lands on.
#
# Nothing here ever WAITS, so there is no deadlock to have: a run either takes the
# lock, reclaims provable debris, or stops with what holds it and what to do.
#
# The lock's authority is the LIVENESS of the process named inside it, never the
# existence of the directory. That is what makes a SIGKILL, a reboot, or a power
# cut recoverable with no human in the loop — the debris names a pid that is gone,
# and the next run reclaims it. Existence-as-authority would block every future
# run for good, which is the one failure mode a lock like this must not have.
SETUP_LOCK_PATH=""       # set only while WE hold it — the release deletes this exact path
SETUP_LOCK_HELD=false

# What identifies a process beyond its number: its command line. A pid alone is
# not identity — after a reboot the same number belongs to something else, and a
# lock that outlived a kill would then read as held forever. `ps -p <pid> -o
# command=` is the one spelling Linux and macOS agree on. The stored value and the
# live one both come through THIS helper, so the bound and the control-stripping
# can never make a living holder look like a stranger.
setup_lock_proc_sig() { # setup_lock_proc_sig <pid> -> its command line (empty when the process is gone)
  local s
  s=$(ps -p "$1" -o command= 2>/dev/null | head -1) || s=""
  safe_display "$s" 200
}

# Who holds <lock-dir>, and can this run even tell? Echoes "held<TAB><what to tell
# the user>" or "stale<TAB><why it is debris>". Reads only.
setup_lock_holder_state() { # setup_lock_holder_state <lock-dir>
  local lock="$1" pid="" host="" sig="" live=""
  if [ -r "$lock/owner" ]; then
    { IFS= read -r pid; IFS= read -r host; IFS= read -r sig; } < "$lock/owner" 2>/dev/null || true
  fi
  case "$pid" in
    ''|*[!0-9]*)
      # No owner record at all. Either a run died in the sliver between creating
      # the directory and writing the record, or a run is inside that sliver right
      # now — and only age separates those. A minute is orders of magnitude longer
      # than the two statements it spans, so an older record-less lock is debris
      # while a younger one is a run that is starting.
      if [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
        printf 'stale\t%s' "it names no process (a run was interrupted before it could record one)"
      else
        printf 'held\t%s' "another conduck-connect setup is starting on this machine"
      fi
      return 0 ;;
  esac
  if [ -n "$host" ] && [ "$host" != "$(uname -n 2>/dev/null)" ]; then
    # A $HOME on a network share is ONE lock for several machines. Process $pid
    # means nothing here, so this run may not judge it and must not steal it.
    printf 'held\t%s' "a setup on $host holds it (process $pid), and this machine cannot tell whether that run is still alive"
    return 0
  fi
  # Probe `ps` against our OWN pid first: a stripped container may have no usable
  # one, and "ps printed nothing" would otherwise read as "the holder is gone".
  # Unknowable liveness fails CLOSED — never steal a lock on a guess.
  if [ -z "$(setup_lock_proc_sig $$)" ]; then
    printf 'held\t%s' "it names process $pid, and this box has no usable 'ps' for me to check whether that run is still alive"
    return 0
  fi
  live=$(setup_lock_proc_sig "$pid")
  if [ -z "$live" ]; then
    printf 'stale\t%s' "process $pid is gone"
  elif [ "$live" != "$sig" ]; then
    printf 'stale\t%s' "process $pid belongs to another program now"
  else
    printf 'held\t%s' "another conduck-connect setup is running here (process $pid)"
  fi
}

setup_lock_acquire() {
  # No state directory means nowhere to put a lock. Don't stop the run over it —
  # it will fail soon on its own merits, with a better diagnosis than this one.
  ensure_state_dir || return 0
  local lock="$STATE_DIR/setup.lock" state kind why attempt=0
  # Bounded, because the loop's "reclaim debris and try again" arm is the only one
  # that repeats: an adversary re-creating the lock in that window must not be able
  # to spin us forever.
  while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt+1))
    if mkdir "$lock" 2>/dev/null; then
      if ( umask 077; printf '%s\n%s\n%s\n' \
             "$$" "$(uname -n 2>/dev/null)" "$(setup_lock_proc_sig $$)" > "$lock/owner" ) 2>/dev/null; then
        # Ownership is CONFIRMED from the file, never inferred from mkdir having
        # succeeded: two runs that both find the same debris can both clear it, and
        # the second clear would take out the winner's fresh lock. A record naming
        # somebody else means they got it — loop, find it held, and stop saying so.
        # This narrows that window rather than closing it: doing better needs a
        # second lock to serialise the reclaim, and a second lock is one more thing
        # a SIGKILL can strand, which is the failure this whole design avoids.
        if [ "$(head -1 "$lock/owner" 2>/dev/null || true)" = "$$" ]; then
          SETUP_LOCK_PATH="$lock"; SETUP_LOCK_HELD=true
          return 0
        fi
        continue
      fi
      # A lock no later run can judge is worse than no lock: it would be reclaimed
      # by the age rule while this run is still going. Drop it and say so instead.
      rm -rf "$lock" 2>/dev/null || true
      warn "Couldn't write $lock/owner, so I can't guard against a second setup running at the same time. Don't start another one until this run finishes."
      return 0
    fi
    state=$(setup_lock_holder_state "$lock")
    kind="${state%%$'\t'*}"; why="${state#*$'\t'}"
    if [ "$kind" = "held" ]; then
      die "I won't start a second setup on this machine: $why. Two at once pick the same loopback port and the same service name, and whichever finishes second overwrites the first one's saved profile. Let that run finish (or stop it), then re-run me. If you are certain nothing else is running, remove the lock and re-run me:  rm -rf $lock"
    fi
    note "Clearing a leftover setup lock — $why."
    rm -rf "$lock" 2>/dev/null || true
  done
  die "Couldn't take the setup lock at $lock — something keeps re-creating it. Remove it and re-run me:  rm -rf $lock"
}

# Released on EVERY exit path: the caller composes this into the EXIT trap, which
# covers `die` and the plain end of the run, and HUP/INT/TERM are routed through
# `exit` so they land there too. Idempotent, and it removes ONLY the path this run
# created — a run that never took the lock must never delete the one another run
# is holding.
setup_lock_release() {
  $SETUP_LOCK_HELD || return 0
  SETUP_LOCK_HELD=false
  [ -n "$SETUP_LOCK_PATH" ] || return 0
  rm -rf "$SETUP_LOCK_PATH" 2>/dev/null || true
  SETUP_LOCK_PATH=""
}

# Rung 2: a change to something YOU own — we print the exact command, you run it.
print_and_wait() {  # print_and_wait "action-id" "why" "command shown to user"
  local action="$1" why="$2" command="$3"
  if $DRY_RUN; then plan_add "YOU RUN  $command  ($why)"; note "(dry-run: you would run the above)"; return 0; fi
  mutate_guard "$why"
  say ""
  say "  This touches something you own, so you run it (copy-paste, e.g. in a"
  say "  second terminal):"
  say ""
  printf '    %s%s%s\n' "$BOLD" "$command" "$RESET"
  say ""
  note "$why"
  local reply
  while true; do
    if ! read -r -p "  Enter = I ran it; s = skip; i = explain; q = stop: " reply; then
      warn "No answer — treating this step as skipped."
      return 1
    fi
    case "$reply" in
      '') return 0 ;;
      [sS]) return 1 ;;
      [iI]|\?) explain_prompt "$action" ;;
      [qQ]) quit_run ;;
      *) warn "Please press Enter only after running it, s to skip, i for an explanation, or q to stop." ;;
    esac
  done
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

# The escalation prefix for a command that has to run as root. A hardcoded `sudo`
# is wrong in three real environments: a root shell needs no prefix at all, the
# minimal Alpine/Debian images that run as root ship no `sudo` binary (so the
# prefixed command dies with "command not found"), and OpenBSD-lineage setups
# carry `doas` instead. Empty output means "run it as root yourself" — the caller
# prints the bare command rather than inventing a dependency.
priv_prefix() { # priv_prefix -> sudo | doas | (empty)
  [ "$(id -u 2>/dev/null)" = 0 ] && return 0
  if have sudo; then printf 'sudo'
  elif have doas; then printf 'doas'
  fi
}

# The install line a Linux user can actually run. Detection is by BINARY
# (`command -v`), never by parsing `/etc/os-release`: the binary is what the
# printed command invokes, while `ID`/`ID_LIKE` lie on derivatives and on
# containers built FROM another base. The caller presents it as *detected*, not
# as "your distribution's command" — a box with two managers installed takes the
# first probe, and the wording has to leave room for that.
#
# Package NAMES are mapped wherever they diverge from the command name, because a
# confidently printed `pacman -S python3` dies with "target not found": worse than
# generic advice, since it reads as authoritative and is wrong. Arch/Manjaro have
# no `python3` package at all (their Python 3 is `python`), and Gentoo needs
# category-qualified atoms. Never map onto a library package (`openssl-libs`,
# `libssl3`) — those are routinely installed while the `openssl` CLI is missing,
# which is exactly the case that got us here. An unrecognised manager prints
# nothing, and the caller names the packages instead: honest beats wrong.
linux_install_cmd() { # linux_install_cmd <command-name>… -> "<manager>\t<command>", or empty
  local priv mgr pkgs="" body="" p
  priv=$(priv_prefix); [ -n "$priv" ] && priv="$priv "
  if   have apt-get;      then mgr="apt-get"
  elif have dnf;          then mgr="dnf"
  elif have yum;          then mgr="yum"
  elif have zypper;       then mgr="zypper"
  elif have pacman;       then mgr="pacman"
  elif have apk;          then mgr="apk"
  elif have xbps-install; then mgr="xbps-install"
  elif have emerge;       then mgr="emerge"
  else return 0
  fi
  for p in "$@"; do
    case "$mgr:$p" in
      pacman:python3) p="python" ;;
      emerge:curl)    p="net-misc/curl" ;;
      emerge:python3) p="dev-lang/python" ;;
      emerge:openssl) p="dev-libs/openssl" ;;
      emerge:rclone)  p="net-misc/rclone" ;;
    esac
    pkgs="$pkgs $p"
  done
  case "$mgr" in
    apt-get)      body="${priv}apt-get update && ${priv}apt-get install -y$pkgs" ;;
    dnf|yum)      body="${priv}$mgr install -y$pkgs" ;;
    zypper)       body="${priv}zypper --non-interactive install$pkgs" ;;
    # Arch does not support partial upgrades, so `-Sy` without `-u` is the classic
    # way to break a box — and a setup wizard has no business prescribing a full
    # system upgrade either. `-S --needed` is the non-expansive form; a stale
    # package database is the user's own `pacman -Syu` to run.
    pacman)       body="${priv}pacman -S --needed$pkgs" ;;
    # --no-cache fetches the index inline: minimal images ship without one, and a
    # bare `apk add` there fails with "unable to select packages".
    apk)          body="${priv}apk add --no-cache$pkgs" ;;
    xbps-install) body="${priv}xbps-install -Sy$pkgs" ;;
    emerge)       body="${priv}emerge --ask$pkgs" ;;
  esac
  printf '%s\t%s' "$mgr" "$body"
}

# Collect ALL missing required tools and report together, with install hints.
preflight() {
  local missing=()
  # openssl is only used by the wizard, to mint credentials and to read a
  # failing certificate's own diagnosis; the two standalone checks never reach
  # it, so don't gate a live diagnostic on a tool it doesn't use.
  local tools="curl python3"; { $DOCTOR || $COMPAT; } || tools="$tools openssl"
  for t in $tools; do need "$t" || missing+=("$t"); done
  if [ ${#missing[@]} -gt 0 ]; then
    bad "Missing required tool(s): ${missing[*]}"
    case "$(uname -s)" in
      Linux)
        # This is the last thing the user reads before the hard exit below, so it
        # has to be a command their box will accept — not Debian's.
        local hint; hint=$(linux_install_cmd "${missing[@]}")
        if [ -n "$hint" ]; then
          note "Detected ${hint%%$'\t'*} — install with:  ${hint#*$'\t'}"
          [ "$(id -u 2>/dev/null)" = 0 ] || [ -n "$(priv_prefix)" ] \
            || note "Run that as root: this shell is neither root nor has sudo/doas."
        else
          note "Install with your distribution's package manager:  ${missing[*]}"
        fi
        ;;
      Darwin) note "Install with Homebrew:     brew install ${missing[*]}" ;;
    esac
    die "Install the tool(s) above, then re-run me."
  fi
}

b64_nowrap() { # stdin -> single-line base64
  if base64 --help 2>&1 | grep -q -- '-w'; then base64 -w0; else base64 | tr -d '\n'; fi
}

# Read a value from a JSON *or* JSON5 config. Strict json.load first; on failure a
# string-aware strip of // and /* */ comments + trailing commas, then strict again
# (OpenClaw writes plain JSON, but its config format legalises JSON5). If both fail,
# fail empty (unchanged behaviour). Ops:
#   get      -> a scalar leaf value; empty for absent/null/non-scalar
#   classify -> "absent" | "ref" (an object/array or a "${…}" placeholder — an
#               indirect secret we must NOT use) | "literal\t<value>"
json_query() { # json_query <file> <op:get|classify|type> <dotted.path>  (empty output when absent)
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys

def strip_json5(s):
    # Remove // and /* */ comments, then trailing commas — but NEVER touch bytes
    # inside a "…" or '…' literal (a // inside a value must survive verbatim).
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
            if j < n and (t[j] == '}' or t[j] == ']'):
                i += 1; continue
        res.append(c); i += 1
    return ''.join(res)

def load(path):
    raw = open(path).read()
    try:
        return json.loads(raw)
    except Exception:
        return json.loads(strip_json5(raw))

def scalar(v):
    if v is True: return "true"
    if v is False: return "false"
    return str(v)

path, op, dotted = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    obj = load(path)
except Exception:
    if op == "classify" or op == "type": sys.stdout.write("absent")
    sys.exit(0)
cur = obj
try:
    for part in dotted.split('.'):
        cur = cur[part]
except Exception:
    if op == "classify" or op == "type": sys.stdout.write("absent")
    sys.exit(0)
if op == "type":
    if cur is None: sys.stdout.write("null")
    elif isinstance(cur, bool): sys.stdout.write("boolean")
    elif isinstance(cur, dict): sys.stdout.write("object")
    elif isinstance(cur, list): sys.stdout.write("array")
    elif isinstance(cur, str): sys.stdout.write("string")
    elif isinstance(cur, (int, float)): sys.stdout.write("number")
    else: sys.stdout.write("unknown")
    sys.exit(0)
if op == "classify":
    if isinstance(cur, (dict, list)):
        sys.stdout.write("ref")
    elif cur is None or cur == "":
        sys.stdout.write("absent")
    else:
        s = scalar(cur)
        sys.stdout.write("ref" if s.startswith("${") else "literal\t" + s)
    sys.exit(0)
if cur is True: print("true")
elif cur is False: print("false")
elif isinstance(cur, (dict, list)): pass
elif cur is not None: print(cur)
PY
}

json_get() { json_query "$1" "get" "$2"; }   # scalar leaf value (empty when absent)
json_type() { json_query "$1" "type" "$2"; } # JSON type, or "absent"

env_get() { # env_get <file> <KEY>  (last assignment wins; strips quotes)
  [ -f "$1" ] || return 0
  sed -n "s/^[[:space:]]*${2}=//p" "$1" | tail -1 | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/"
}

# Sanitize a free-form gateway name into a safe id token ([a-z0-9-], no injection).
slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//' | cut -c1-32; }

normalize_gateway_base_url() { # normalize_gateway_base_url <url> -> echoes the app-parity base URL
  # Mirror of the app's SettingsViewModel.normalizedGatewayBaseURL — keep the two
  # in lockstep (parity fixtures belong in the public repo's CI; land them there
  # at release — no CI guards this today). Users paste the
  # full endpoint their server's docs name (Ollama/LiteLLM write it as "…/v1"),
  # but the app and this script both append /v1/… themselves — a base that
  # already ends in it would 404 every request. Segment-wise on the URL PATH (a
  # host or segment that merely contains "v1" is untouched): strip exactly ONE
  # terminal /v1/chat/completions, /v1/models, or /v1 (longest first), drop
  # query+fragment, keep port and any legitimate path prefix.
  # Suffix comparison runs on percent-DECODED segments (Foundation's
  # URLComponents.path decodes, so the app recognizes an encoded "/v1" too);
  # the surviving path is emitted exactly as typed — no re-encoding surprises.
  printf '%s' "$1" | python3 -c '
import sys
from urllib.parse import urlsplit, urlunsplit, unquote
u = urlsplit(sys.stdin.read().strip())
segs = [s for s in u.path.split("/") if s]
dec = [unquote(s) for s in segs]
for suf in (["v1", "chat", "completions"], ["v1", "models"], ["v1"]):
    if len(dec) >= len(suf) and dec[-len(suf):] == suf:
        del segs[-len(suf):]
        break
sys.stdout.write(urlunsplit((u.scheme, u.netloc, "/" + "/".join(segs) if segs else "", "", "")))' 2>/dev/null
}

apply_gateway_url_normalization() { # rewrites GW_URL in place; says so when it changed
  local norm; norm=$(normalize_gateway_base_url "$GW_URL")
  [ -n "$norm" ] || return 0   # python hiccup → keep the URL as typed
  if [ "$norm" != "$GW_URL" ]; then
    note "Using $norm — Conduck adds /v1/… itself, so the base address must not already end in it."
    GW_URL="$norm"
  fi
}

OS="$(uname -s)"   # Linux | Darwin
# ${HOME:-} so a check run in a HOME-less environment (a bare CI shell) doesn't
# abort here under `set -u` on a path it never uses; the wizard would fail later
# anyway if it genuinely needed a state dir, which is the correct place to notice.
STATE_DIR="${XDG_CONFIG_HOME:-${HOME:-}/.config}/conduck"
