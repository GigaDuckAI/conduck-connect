#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0 AND MIT
# Copyright 2026 GigaDuck OÜ
# Conduck-authored portions are Apache-2.0. The marked Project Nayuki
# QR generator block is MIT; see THIRD_PARTY_NOTICES.md.
#
# conduck-connect — pair your self-hosted AI gateway with the Conduck app.
#
# How to run (no install, nothing to compile — this is a plain, unminified shell
# script on purpose, so you can inspect it before running):
#
# Where this should come from:
#   1. Get it over HTTPS from the official release — not forwarded to you by
#      someone else:  https://github.com/gigaduckai/conduck-connect/releases
#   2. Inspect this plain, unminified file before running it when your threat
#      model calls for source review. The release tests the exact shipped artifact.
#   3. Optional integrity check: the release also ships a checksum
#        sha256sum -c conduck-connect.sh.sha256
#        # macOS: shasum -a 256 -c conduck-connect.sh.sha256
#      It catches a corrupted download, but it rides the same release channel —
#      so it can't prove the release itself wasn't swapped.
#   If you got this script any other way, get it from the link above first.
#
#     bash conduck-connect.sh            # welcome menu: setup, check a server,
#                                        #   check an adapter, or re-show a code
#     bash conduck-connect.sh --setup    # go straight to the setup wizard
#     bash conduck-connect.sh --setup --dry-run
#                                        # preview setup; changes nothing
#
# What this script DOES (always with your confirmation, step by step):
#   1. Finds your gateway (OpenClaw, Hermes, or any OpenAI-compatible server).
#   2. Enables the OpenAI-compatible chat endpoint if it is off (the #1 setup trap).
#   3. Helps you expose the gateway over HTTPS (works WITH what you have installed:
#      Tailscale, Cloudflare Tunnel, or your own reverse proxy). Whatever the path,
#      the certificate has to be one your devices already trust; a self-signed one
#      stops the run, and the script names the free ways to get a real certificate.
#   4. Optionally sets up the agent file lane (rclone WebDAV) so Conduck can hand
#      your agent real files and download its outputs. OpenClaw gets a tool-policy
#      check + TOOLS.md guidance. Hermes gets its API-server file toolset and
#      terminal.cwd checked + verified Hermes context guidance. Every edit is
#      narrow, shown first, and optional.
#   5. Verifies everything with real requests. An OpenClaw/Hermes file lane must
#      pass a real agent read -> byte-identical write sentinel before a code.
#   6. Prints a QR code you scan with the Conduck app — URL, token, and file-lane
#      credentials imported in one scan — nothing to retype on your phone
#      (iPhone or iPad).
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
#   bash conduck-connect.sh                 # welcome menu
#   bash conduck-connect.sh --setup         # setup + verify + pair
#   bash conduck-connect.sh --check-server [url]
#                                           # software NOT built for Conduck:
#                                           # check it against the app's core wire
#   bash conduck-connect.sh --check-adapter [url]
#                                           # check software built specifically
#                                           # for Conduck against its adapter contract
#   bash conduck-connect.sh --show-code     # re-show a SAVED pairing code; no
#                                           # configuration changes, but live
#                                           # verification sends requests and a
#                                           # configured file lane gets live
#                                           # transport verification; OpenClaw/
#                                           # Hermes get a real agent sentinel
#
# Modifiers:
#   bash conduck-connect.sh --setup --dry-run
#                                           # show setup state + plan; change nothing
#   bash conduck-connect.sh --setup --reuse-only
#                                           # advanced: walk setup using only what
#                                           # already exists. The first step that
#                                           # would change host configuration STOPS
#                                           # the run and names it — it is not
#                                           # skipped. Verification still sends
#                                           # requests and may run a small file probe
#   bash conduck-connect.sh --check-adapter --deep [url]
#                                           # add a semantic image-input check
#   bash conduck-connect.sh --check-adapter --files [url]
#                                           # also grade the configured file lane;
#                                           # writes and removes small probe files
#   bash conduck-connect.sh --setup --allow-keyless-public
#                                           # expert: permit a keyless
#                                           # gateway on a public transport during setup
#
# Environment:
#   CONDUCK_TOKEN=<token>                     # bearer token for a check, so it never
#                                           # reaches your shell history or argv
#   CONDUCK_CHECK_SERVER_MODEL=<model-id>
#                                           # --check-server only: grade the model you
#                                           # plan to use. Without it the named-model
#                                           # checks take whichever id /v1/models lists
#                                           # FIRST, so a server offering many models
#                                           # can report FAIL or PASS purely on the
#                                           # order it lists them. Continue into setup
#                                           # and the pairing code carries the model
#                                           # you named.
#
# Information:
#   bash conduck-connect.sh --help            # show this complete public command reference
#   bash conduck-connect.sh --version         # print the connector version and exit
#
# Exit status:
#   0  requested action succeeded (or a check passed)
#   1  setup/runtime failure, or a completed check failed
#   2  command-line usage error (unknown/retired flag, invalid combination or URL)
#   128+signal  interrupted by HUP/INT/TERM
#
# Re-running is safe: every step detects existing state and reuses what's done.
# Use --show-code to re-show a saved gateway's code, skipping setup questions
# (handy for pairing your own second device — the code is the same reusable secret,
# so treat every copy of it like the token it carries).

# GENERATED FILE — edit src/*.inc.sh and run scripts/build-release.sh; direct edits are overwritten

set -u -o pipefail

VERSION="0.13.0"
PAYLOAD_VERSION=1
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
  choice=$(require_choice "Choose an option" "$regex") || die "$NO_ANSWER"
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

confirm() {  # confirm "question" -> 0 yes / 1 no
  local reply
  read -r -p "$1 [y/N] " reply || return 1
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
# Returns NONZERO when the input ended (EOF) rather than when the user chose an
# empty answer. The two are not the same: a deliberate Enter is the app's explicit
# keyless scheme, while EOF means nobody was asked at all. Callers that treat an
# empty token as "keyless" MUST pair this with `|| die`, or a redirected run would
# infer no-auth from a missing answer — the fail-closed-auth invariant.
ask_secret() {  # ask_secret "prompt" -> echoes the secret (input hidden); 1 on EOF
  local reply rc=0
  read -rs -p "  $1: " reply || rc=1
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
# Optional 3rd arg names a help function: answering `?` prints it and re-asks.
# Help is ADDITIVE only — it explains the same options in plain words, never
# changes them (the canonical menu/prompt strings stay the single source).
# The help function's stdout is redirected to stderr here, same $()-capture rule.
require_choice() {  # require_choice "prompt" "regex" [help_fn] -> echoes the choice
  local reply
  while true; do
    read -r -p "  $1: " reply || return 1     # closed stdin — never spin the loop
    if [ -n "${3:-}" ] && [ "$reply" = "?" ]; then "$3" >&2; continue; fi
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
  run_step "tighten $f to 0600 so only you can read $what" chmod 600 "$f" || true
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
  local reply
  if ! read -r -p "  Press Enter here once it's done (or 's' to skip): " reply; then
    warn "No answer — treating this step as skipped."
    return 1
  fi
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
        # Same boot window as the tool-policy restart: `restart` returns in about
        # a second and the health route answers a few seconds later. Usually the
        # exposure step buys that time, but a run reusing an existing exposure
        # walks straight into verification, so wait here too. HTTP-safe is FALSE
        # — this change IS the HTTP layer, so the epilogue must not promise it
        # cannot affect it. GW_LOCAL_PORT and GW_HEALTH_PATH are set just above.
        if run_step "restart the gateway so the flag applies" \
          docker compose --project-directory "$compose_dir" restart openclaw-gateway; then
          gw_note_restart_and_wait "chat-endpoint setting" false
        fi
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
      # The `umask 077` above only covers a file we CREATE. A ~/.hermes/.env that
      # Hermes already wrote under umask 022 is 0644, and the API server key just
      # appended (or re-read) is a live gateway credential sitting in it. The
      # announce-then-confirm gate, and what it says when the answer is no or the
      # chmod fails, both live in secure_owned_file_mode.
      secure_owned_file_mode "$envf" "your API server key" || true
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
hermes_recall_checked_handoff_step() { # hermes_recall_checked_handoff_step <suggested-list>
  local GW_KIND="hermes"
  hermes_recall_scope_step "$1" || true
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
  # Suggest the scope the code being paired actually needs — the same (URL, cred)
  # pair the payload builder uses to decide whether a file lane rides at all.
  local suggested="[web]"
  if [ -n "${FS_URL:-}" ] && [ -n "${FS_CRED:-}" ]; then suggested="[web, file]"; fi
  if [ "${GW_KIND:-}" = "hermes" ]; then
    hermes_recall_scope_step "$suggested" || true
  elif $CHECK_HANDOFF_LOCAL_HERMES; then
    # Say why a Hermes finding is appearing on a gateway this run calls "custom",
    # and say exactly how strong the claim is. A settings match is not proof of
    # which process holds the port, and this line must not pretend otherwise.
    say ""
    note "This address matches this machine's Hermes API-server settings — same bind address and port, and the check authenticated with the key in ~/.hermes/.env."
    note "That is a settings match, not proof of which process holds that port, so read what follows against your own install."
    hermes_recall_checked_handoff_step "$suggested"
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
# ------------------------------------------------------------ exposure phase --

TRANSPORT=""       # tailscale | funnel | cloudflare | public
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

# Every undo record ALSO lives on disk, one file per exposure, written BEFORE the
# mutation it undoes. APPLIED/FS_APPLIED die with the process, and the two ways an
# interrupted run really ends are the two they cannot survive: SIGKILL or an OOM
# kill (no trap runs at all) and a dropped SSH session (the trap runs, but prints
# into a terminal that is gone). Either way the exposure stays live — possibly a
# PUBLIC Funnel in front of a tool-capable agent — while the only record of who
# opened it dies with the shell, so no later run can find it. $STATE_DIR is the
# sanctioned home for this class of data and is created only by ensure_state_dir.
EXPOSURE_RECORD_VERSION=1
EXPOSURE_RUN_TAG=""            # per-run, so a whole-run purge only drops THIS run's files
EXPOSURE_RECORD_SEQ=0          # zero-padded into the name, so restore order is recoverable
EXPOSURE_RECORD_WARNED=false   # an unusable record is named once, and kept

# THE rule for prior state, shared by every path that undoes an exposure: what WE
# applied is removed, and the prior mapping is restored only when it was PRIVATE.
# A prior PUBLIC Funnel is never re-created for the operator — a block they accept
# under the word "cleanup" must not be able to re-publish their agent to the open
# internet, least of all two prompts after they answered "yes, turn the public URL
# off" and verification then failed. The command is printed instead, labelled
# PUBLIC, so re-publishing stays a deliberate act.
prior_is_public() { # prior_is_public <prior-state>
  case "$1" in funnel$'\t'*) return 0 ;; esac
  return 1
}

# Does any of these records carry a prior PUBLIC mapping? Decides whether a
# cleanup prompt has to say out loud what it will NOT do.
entries_have_public_prior() { # entries_have_public_prior <entry>…
  local entry rest
  for entry in "$@"; do
    [ -n "$entry" ] || continue
    rest="${entry#*$'\t'}"
    prior_is_public "${rest#*$'\t'}" && return 0
  done
  return 1
}

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
    elif prior_is_public "$prior"; then
      # Clear the port, then print the re-publish separately and under its own
      # heading. Printing it inline with the others would put "make this public
      # again" inside a block the operator is being asked to accept wholesale.
      pproxy="${prior#*$'\t'}"
      printf '    %stailscale serve --https=%s off%s\n' "$BOLD" "$port" "$RESET"
      say "    ${DIM}Port $port carried a PUBLIC Tailscale Funnel before this run. Putting that back"
      say "    would return this machine to the open internet, so it is not part of the undo"
      say "    above. Only if you want port $port PUBLIC again:${RESET}"
      printf '    %stailscale funnel --bg --https=%s %s%s   # makes port %s PUBLIC again\n' "$BOLD" "$port" "$pproxy" "$RESET" "$port"
    else
      pverb="${prior%%$'\t'*}"; pproxy="${prior#*$'\t'}"
      printf '    %stailscale %s --bg --https=%s %s%s   # restore your previous private mapping\n' "$BOLD" "$pverb" "$port" "$pproxy" "$RESET"
    fi
  done
}

# Undo ONE record, by the rule above. Best-effort per command (`|| true`): the
# CALLER proves the outcome from a status re-read, because a refused command and a
# refused-but-already-correct state are indistinguishable from an exit code.
undo_exposure_entry() { # undo_exposure_entry <"port\tapplied-verb\tprior">
  local entry="$1" port rest averb prior pverb pproxy
  port="${entry%%$'\t'*}"; rest="${entry#*$'\t'}"
  averb="${rest%%$'\t'*}"; prior="${rest#*$'\t'}"
  if [ "$averb" = "funnel" ]; then tailscale funnel --https="$port" off 2>/dev/null || true; fi
  if [ "$prior" = "EMPTY" ] || prior_is_public "$prior"; then
    # Both cases end with the port CLEARED: nothing was there before, or what was
    # there was public and is not ours to re-publish. `funnel off` first, because
    # a prior public port carries the AllowFunnel flag that `serve off` leaves set.
    prior_is_public "$prior" && { tailscale funnel --https="$port" off 2>/dev/null || true; }
    tailscale serve --https="$port" off 2>/dev/null || true
  else
    pverb="${prior%%$'\t'*}"; pproxy="${prior#*$'\t'}"
    tailscale "$pverb" --bg --https="$port" "$pproxy" 2>/dev/null || true
  fi
}

# What a PROVEN undo looks like for one record — the value ts_target_for_port must
# return afterwards. A public prior targets an EMPTY port, not the prior itself:
# undo_exposure_entry clears it rather than re-publishing, so "back to prior" would
# report the SAFER outcome as an incomplete rollback and nag about a closed port.
undo_target_for_entry() { # undo_target_for_entry <entry> -> expected target, "" for a cleared port
  local rest prior
  rest="${1#*$'\t'}"; prior="${rest#*$'\t'}"
  [ "$prior" = "EMPTY" ] && return 0
  prior_is_public "$prior" && return 0
  printf '%s' "$prior"
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
  # 3) None free. The file lane is OPTIONAL — the CALLER decides what to do (skip, or
  # offer to keep it private), so don't announce "skipping the file lane" from here:
  # one caller (fs_promote_public) goes on to offer keeping it, and the double message
  # was contradictory.
  if [ "$role" = "file" ]; then
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

# ------------------------------------------------- the on-disk undo record -----
# One line per record, tab-separated, `prior` LAST because it is the one field
# that legitimately contains a tab ("verb<TAB>proxy"):
#   <format-version>  <role>  <port>  <applied-verb>  <applied-proxy>  <prior>
# Nothing else in this script reads these files.

# Every value read back out is interpolated into a `tailscale` command, so each is
# checked against the ONLY shape this script ever writes rather than trusted: a
# file under $STATE_DIR is editable by its owner and outlives version changes.
exposure_proxy_ok() { # exposure_proxy_ok <proxy>
  case "$1" in
    http://127.0.0.1:) return 1 ;;
    http://127.0.0.1:*) case "${1#http://127.0.0.1:}" in *[!0-9]*) return 1 ;; esac; return 0 ;;
  esac
  return 1
}

# Read one record into REC_* (globals, because bash 3.2 has no `declare -n`).
# Returns 1 for anything this version cannot use, WITHOUT deleting the file: an
# unreadable record may still name a live public exposure, so it is kept for a
# version that understands it, and never fed to a command.
REC_ROLE=""; REC_PORT=""; REC_AVERB=""; REC_APROXY=""; REC_PRIOR=""
read_exposure_record() { # read_exposure_record <file> -> 0 and sets REC_*, else 1
  REC_ROLE=""; REC_PORT=""; REC_AVERB=""; REC_APROXY=""; REC_PRIOR=""
  local ver role port averb aproxy prior
  IFS=$'\t' read -r ver role port averb aproxy prior < "$1" 2>/dev/null || return 1
  [ "${ver:-}" = "$EXPOSURE_RECORD_VERSION" ] || return 1
  case "${role:-}" in gateway|file) ;; *) return 1 ;; esac
  case "${port:-}" in ''|*[!0-9]*) return 1 ;; esac
  case "${averb:-}" in serve|funnel) ;; *) return 1 ;; esac
  exposure_proxy_ok "${aproxy:-}" || return 1
  case "${prior:-}" in
    EMPTY) ;;
    serve$'\t'*|funnel$'\t'*) exposure_proxy_ok "${prior#*$'\t'}" || return 1 ;;
    *) return 1 ;;
  esac
  REC_ROLE="$role"; REC_PORT="$port"; REC_AVERB="$averb"; REC_APROXY="$aproxy"; REC_PRIOR="$prior"
}

# Is the exposure a record describes STILL the one live on that port? The whole
# meaning of a record is "this script opened this, and has not told you about it",
# so both the verb and the backend have to match — a leftover private Serve is not
# the public Funnel we recorded, and a port some other tool has taken over is not
# ours to close. Reads current TS_PORTS; the caller refreshes them.
exposure_record_is_live() { # exposure_record_is_live -> 0 when REC_* still matches TS_PORTS
  [ "$(ts_target_for_port "$REC_PORT")" = "$REC_AVERB"$'\t'"$REC_APROXY" ]
}

# The disk twin of snapshot_port, written BEFORE the mutation. Best effort BY
# DESIGN: a record we cannot write must never stop an exposure the operator just
# agreed to — the cost of failing is that the NEXT run does not know, which is
# exactly where we already are today.
persist_exposure_record() { # persist_exposure_record <port> <applied-verb> <applied-proxy> <role> [prior]
  local port="$1" averb="$2" aproxy="$3" role="$4" prior="${5:-}"
  $DRY_RUN && return 0                    # nothing mutates, so there is nothing to undo
  [ -n "${STATE_DIR:-}" ] || return 0
  ensure_state_dir || return 0
  [ -n "$EXPOSURE_RUN_TAG" ] || EXPOSURE_RUN_TAG="$$-$(date +%s 2>/dev/null || printf '0')"
  EXPOSURE_RECORD_SEQ=$((EXPOSURE_RECORD_SEQ+1))
  # `prior` is passed only when re-tagging an ADOPTED record, whose prior state
  # belongs to the run that opened the port; reading it live here would record the
  # exposure itself as its own prior state and make the undo a no-op.
  [ -n "$prior" ] || prior=$(ts_target_for_port "$port")
  local f; f=$(printf '%s/exposure-%s-%03d.pending' "$STATE_DIR" "$EXPOSURE_RUN_TAG" "$EXPOSURE_RECORD_SEQ")
  # 0600 like everything else in here: the line names a gateway's port and backend.
  ( umask 077
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$EXPOSURE_RECORD_VERSION" "$role" "$port" "$averb" "$aproxy" "${prior:-EMPTY}" >"$f"
  ) 2>/dev/null || return 0
}

# Take over an earlier run's record for a mapping THIS run reuses as-is. Reusing an
# exposure makes it this run's: on success the code names it, so the record has to
# go with this run's other records, and on failure the undo still has to know the
# prior state the ORIGINAL run captured. Leaving the old file alone instead would
# have the next run offer to close a working, already-reported pairing.
adopt_exposure_records_for_port() { # adopt_exposure_records_for_port <port> <verb> <proxy> <role>
  local port="$1" verb="$2" proxy="$3" role="$4" f prior
  $DRY_RUN && return 0
  [ -n "${STATE_DIR:-}" ] || return 0
  for f in "$STATE_DIR"/exposure-*.pending; do
    [ -f "$f" ] || continue
    read_exposure_record "$f" || continue
    [ "$REC_PORT" = "$port" ] && [ "$REC_AVERB" = "$verb" ] && [ "$REC_APROXY" = "$proxy" ] || continue
    prior="$REC_PRIOR"
    rm -f "$f" 2>/dev/null || continue
    persist_exposure_record "$port" "$verb" "$proxy" "$role" "$prior"
  done
}

# Drop records that have nothing left to offer. Tag-agnostic for the proven case,
# because a record is garbage the moment its exposure is gone no matter which run
# wrote it — and a later run that offers to close an already-closed port teaches
# the operator to skip past this whole class of warning.
# FAIL CLOSED: an unreadable Tailscale state is not proof of removal, so nothing
# is dropped then.
# `all` drops THIS run's records unconditionally, used once a setup code is
# emitted: the exposure is live BECAUSE the operator asked for it, and the run has
# just said so on screen, so it is no longer an unreported one.
prune_exposure_records() { # prune_exposure_records [all]
  local force="${1:-}" f
  $DRY_RUN && return 0
  [ -n "${STATE_DIR:-}" ] || return 0
  if [ "$force" = "all" ]; then
    [ -n "$EXPOSURE_RUN_TAG" ] || return 0
    for f in "$STATE_DIR"/exposure-"$EXPOSURE_RUN_TAG"-*.pending; do
      [ -f "$f" ] && { rm -f "$f" 2>/dev/null || true; }
    done
    return 0
  fi
  ts_targets
  $TS_STATE_KNOWN || return 0
  for f in "$STATE_DIR"/exposure-*.pending; do
    [ -f "$f" ] || continue
    read_exposure_record "$f" || continue
    exposure_record_is_live && continue
    rm -f "$f" 2>/dev/null || true
  done
}

# Offer the higher-rights retry of a Tailscale command that just failed, and hand
# it over for the user to run. Three states, because an empty `priv_prefix` means
# two OPPOSITE things:
#   sudo/doas present — offer the prefixed retry (the common case).
#   already root      — there are no higher rights left to try, so reprinting the
#                       identical command the user just watched fail is noise. Say
#                       so and let the caller's status re-read decide the outcome:
#                       the command can fail and the state still be right.
#   neither           — the command is only runnable from a root shell. Print it
#                       BARE with that instruction rather than guessing `sudo`: a
#                       box without the binary answers "command not found", which
#                       reads as a different fault than the one they have.
# Never synthesises `su -c`: that assumes `su`, quotes badly around the two-command
# form, and behaves inconsistently across systems.
ts_priv_retry() { # ts_priv_retry <why> <bare-command>… -> 0 ran it, 1 declined, 2 no retry exists
  local why="$1"; shift
  local priv retry="" c
  priv=$(priv_prefix)
  if [ -z "$priv" ] && [ "$(id -u 2>/dev/null)" = 0 ]; then
    warn "This shell is already root, so there are no higher rights to retry with — Tailscale itself refused it."
    return 2
  fi
  for c in "$@"; do
    [ -n "$c" ] || continue
    retry="${retry:+$retry; }${priv:+$priv }$c"
  done
  [ -n "$priv" ] || why="$why This shell is not root and has neither sudo nor doas, so run it from a root shell."
  print_and_wait "$why" "$retry"
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
      # Reuse changes nothing, so there is nothing new to record — but an earlier
      # interrupted run may be the reason this mapping exists, and this run now
      # owns it.
      adopt_exposure_records_for_port "$httpsport" "$verb" "http://127.0.0.1:$localport" "$role"
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
    # rollback record for a port we never touched. Memory AND disk, both BEFORE
    # the first mutating command below (the demote already changes the port), so
    # the record exists even if this process never reaches another line.
    snapshot_port "$httpsport" "$verb" "$role"
    persist_exposure_record "$httpsport" "$verb" "http://127.0.0.1:$localport" "$role"
    if $demote; then tailscale funnel --https="$httpsport" off 2>/dev/null || true; fi
    $cmd || {
      warn "Tailscale refused that — often missing operator or root rights, or Funnel/HTTPS not yet enabled for your tailnet (if so, Tailscale prints instructions above)."
      local retry_rc=0
      if $demote; then
        ts_priv_retry "Tailscale serve/funnel often needs operator or root rights." "$demote_cmd" "$cmd" || retry_rc=$?
      else
        ts_priv_retry "Tailscale serve/funnel often needs operator or root rights." "$cmd" || retry_rc=$?
      fi
      # 1 = the user declined the retry, so stop. 2 = a root shell had no retry to
      # decline; fall through to the confirm below, which is the only thing that
      # can tell a refused command from a refused-but-already-correct state.
      [ "$retry_rc" = 1 ] && return 1
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
  warn "Here is how to undo what this run changed on each affected port:"
  print_undo_hints "${all[@]}"
  say ""
  # Say plainly what a "yes" will NOT do. Without this the operator reads the
  # PUBLIC re-publish line as part of the block they are accepting.
  if entries_have_public_prior "${all[@]}"; then
    warn "The PUBLIC line above is NOT included — I never re-publish a port on your behalf."
  fi
  if ! $REUSE_ONLY && confirm "  Run these cleanup commands now?"; then
    # Reverse order: the LAST mapping applied is undone first, so when two records
    # touch one port the earliest-recorded prior state is the one that survives.
    local i
    for (( i=${#all[@]}-1; i>=0; i-- )); do
      undo_exposure_entry "${all[$i]}"
    done
    ok "Cleanup attempted — verify with 'tailscale serve status' and 'tailscale funnel status'."
  fi
  APPLIED=(); FS_APPLIED=()   # handled — don't let the EXIT backstop repeat it
  # The disk records are NOT cleared with them: the prompt above may have been
  # declined, skipped by --reuse-only, or refused by Tailscale, and only a status
  # re-read can tell. prune_exposure_records keeps exactly the ones still live, so
  # a later run offers to close whatever this one did not.
  prune_exposure_records
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
  # In-memory only, deliberately: this REMOVES an exposure, so there is nothing
  # live for a later run to find and close. The disk record exists to catch an
  # exposure we OPENED and never reported; a record here would only offer to
  # re-create a mapping — and re-creating one unbidden is what prior_is_public
  # exists to prevent.
  snapshot_port "$port" "$verb" file        # record (in FS_APPLIED) so cleanup can restore it
  tailscale "$verb" --https="$port" off || {
    warn "Tailscale refused that — often missing operator or root rights, or Funnel/HTTPS not yet enabled for your tailnet (if so, Tailscale prints instructions above)."
    ts_priv_retry "Removing a Tailscale mapping often needs operator or root rights." \
      "tailscale $verb --https=$port off" || true
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
  local entry port rest prior
  for entry in "${FS_APPLIED[@]}"; do
    undo_exposure_entry "$entry"
  done
  # FAIL CLOSED: claim success only when a status re-parse PROVES each port reached
  # the state undo_target_for_entry names. Otherwise keep the record (the EXIT
  # backstop and cleanup_exposures still act on it) and say so — never "all clear"
  # on faith.
  ts_targets
  local leftover=() t want
  for entry in "${FS_APPLIED[@]}"; do
    port="${entry%%$'\t'*}"
    want=$(undo_target_for_entry "$entry")
    t=$(ts_target_for_port "$port")
    if ! $TS_STATE_KNOWN || [ "${t:-}" != "$want" ]; then leftover+=("$entry"); fi
  done
  if [ ${#leftover[@]} -eq 0 ]; then
    note "Rolled back the file-lane exposure — confirmed no public file server is left behind."
    FS_APPLIED=()
    prune_exposure_records   # proven gone: the disk records for these ports go too
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
drop_file_lane() {
  rollback_fs_exposures
  if declare -F hermes_residual_state_note >/dev/null 2>&1; then
    hermes_residual_state_note
  fi
  FS_URL=""; FS_CRED=""; FS_REACH=""
}

# Backstop: if the script exits (incl. a `die`) AFTER applying exposures but BEFORE
# emitting a code, print exactly how to undo them. Non-interactive (safe in a trap).
EMITTED=false
on_exit() {
  # The OpenClaw/Hermes setup sentinel registers exact nonce paths before any
  # remote creation. Keep that cleanup chained ahead of exposure reporting,
  # including exits where the optional lane state was already cleared.
  if declare -F agent_file_probe_cleanup_backstop >/dev/null 2>&1; then
    agent_file_probe_cleanup_backstop true || true
  fi
  $DRY_RUN && return 0
  local all=(); all+=( ${APPLIED[@]+"${APPLIED[@]}"} ); all+=( ${FS_APPLIED[@]+"${FS_APPLIED[@]}"} )
  [ ${#all[@]} -gt 0 ] || return 0
  # A successful run normally has nothing to undo. The exception: a file-lane
  # rollback that could NOT be proven — that exposure may still be live, so the
  # undo hints must survive even a green QR.
  if $EMITTED && ! $FS_ROLLBACK_INCOMPLETE; then
    prune_exposure_records all   # a clean run leaves nothing behind on disk either
    return 0
  fi
  say ""
  if $EMITTED; then
    warn "A file-lane exposure this run applied could NOT be confirmed removed. It may still be reachable. To undo it:"
  else
    warn "Exited before emitting a setup code, but exposure changes were applied. To undo them:"
  fi
  print_undo_hints "${all[@]}"
  # Printing is not evidence anybody read it, let alone acted: this same block is
  # what a dropped SSH session writes into a terminal that no longer exists. The
  # disk records stay, so the next run can offer to close whatever is still live.
  note "The next run of this script offers to close any of these that is still live."
}
trap on_exit EXIT
# macOS Bash 3.2 does not reliably run EXIT for an unhandled signal. Route
# setup signals through exit so exact-name sentinel cleanup and conventional
# 128+signal statuses both survive.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

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
    if ! { tailscale funnel --https="$rport" off \
           && tailscale serve --https="$rport" off; }; then
      warn "Tailscale refused that — often missing operator or root rights, or Funnel/HTTPS not yet enabled for your tailnet (if so, Tailscale prints instructions above)."
      ts_priv_retry "Removing a public Funnel often needs operator or root rights." \
        "$off_cmd" "tailscale serve --https=$rport off" || true
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
  # A funnel swept here can be the very one an interrupted earlier run recorded on
  # disk, so retire that record now rather than let the NEXT run offer to close a
  # port this one already closed.
  prune_exposure_records
}

# The other half of the on-disk undo record: read what earlier runs left, and offer
# to close whatever is still live. Runs at the START of a setup run, before any new
# port is chosen, because the leftover may be a PUBLIC Funnel in front of a
# tool-capable agent and that outranks the setup the operator came here for.
# Records whose exposure is already gone are retired in SILENCE — a block that
# announces closed ports is a block operators learn to skip.
# prior_is_public governs here too: a prior private mapping is put back, a prior
# public one is only ever printed.
reconcile_orphaned_exposures() {
  [ -n "${STATE_DIR:-}" ] || return 0
  local f pending_seen=false
  for f in "$STATE_DIR"/exposure-*.pending; do
    [ -f "$f" ] && pending_seen=true
  done
  $pending_seen || return 0
  # Without the CLI nothing here can be checked OR closed, and the records cannot
  # be believed either: `tailscale` missing from THIS shell's PATH is not proof its
  # mappings are gone. Name the situation and keep every file for a run that can
  # read the real state.
  if ! have tailscale; then
    say ""
    warn "An earlier run of this script recorded a Tailscale exposure it opened, but the"
    warn "'tailscale' command isn't on this shell's PATH, so I can't check whether it is"
    warn "still live. Run me from a shell that has it, or check 'tailscale funnel status'."
    return 0
  fi
  ts_targets
  if ! $TS_STATE_KNOWN; then
    say ""
    warn "An earlier run of this script recorded a Tailscale exposure it opened, and I could"
    warn "not read 'tailscale serve status --json' to see whether it is still live."
    warn "Check 'tailscale serve status' and 'tailscale funnel status'."
    return 0
  fi
  # Two passes so the operator sees the full scope before answering: collect the
  # still-live records as undo entries (the shape print_undo_hints and
  # undo_exposure_entry both take), retiring the rest as we go.
  local live=() files=() backends=() roles=() entry public=false host=""
  for f in "$STATE_DIR"/exposure-*.pending; do
    [ -f "$f" ] || continue
    if ! read_exposure_record "$f"; then
      if ! $EXPOSURE_RECORD_WARNED; then
        EXPOSURE_RECORD_WARNED=true
        warn "$STATE_DIR holds an exposure record this version cannot read. Leaving it alone (it may"
        warn "name a live exposure) — check 'tailscale serve status' and 'tailscale funnel status'."
      fi
      continue
    fi
    if ! exposure_record_is_live; then rm -f "$f" 2>/dev/null || true; continue; fi
    live+=("$REC_PORT"$'\t'"$REC_AVERB"$'\t'"$REC_PRIOR")
    files+=("$f")
    backends+=("${REC_APROXY#http://127.0.0.1:}")   # the local port it fronts, for the report
    # What sits behind it decides how alarming this is: an agent gateway answers
    # prompts and runs tools, a file lane hands out files.
    if [ "$REC_ROLE" = "file" ]; then roles+=("your shared folder"); else roles+=("your gateway"); fi
    [ "$REC_AVERB" = "funnel" ] && public=true
  done
  [ ${#live[@]} -gt 0 ] || return 0

  host=$(tailscale_dns_name)
  say ""
  warn "An earlier run of this script opened an exposure and never finished — nothing told"
  warn "you how to close it, because that run was cut off. It is still live:"
  local i port rest averb backend
  for (( i=0; i<${#live[@]}; i++ )); do
    entry="${live[$i]}"
    port="${entry%%$'\t'*}"; rest="${entry#*$'\t'}"
    averb="${rest%%$'\t'*}"
    backend="port $port → 127.0.0.1:${backends[$i]} (${roles[$i]})"
    if [ "$averb" = "funnel" ]; then
      say "    ${BOLD}$backend — PUBLIC${RESET} (Tailscale Funnel): reachable from the internet${host:+ at https://$host:$port}"
    else
      say "    $backend — private (Tailscale Serve): your tailnet only"
    fi
  done
  say ""
  $public && warn "A public one means anyone who has the URL can knock on your gateway right now."
  say "  Closing it changes nothing about the gateway itself — only the address in front of it."
  say ""
  print_undo_hints "${live[@]}"
  say ""
  if $DRY_RUN; then
    plan_add "OFFER  close the leftover exposure(s) recorded by an interrupted earlier run"
    note "(dry-run: would offer to close the above)"
    return 0
  fi
  # NOT mutate_guard: --reuse-only means report-don't-change, and dying here would
  # let one interrupted run block every later reuse-only run from even starting.
  if $REUSE_ONLY; then
    warn "(--reuse-only: leaving it as-is — run the commands above, or re-run without --reuse-only.)"
    return 0
  fi
  if ! confirm "  Close it now?"; then
    warn "Leaving it live. The commands above close it whenever you want."
    return 0
  fi
  for (( i=${#live[@]}-1; i>=0; i-- )); do
    undo_exposure_entry "${live[$i]}"
  done
  # FAIL CLOSED, per record: prove the outcome from a status re-read, retire only
  # what is proven, and name what is left rather than claiming a clean sweep.
  ts_targets
  local leftover=() t want
  for (( i=0; i<${#live[@]}; i++ )); do
    entry="${live[$i]}"
    port="${entry%%$'\t'*}"
    want=$(undo_target_for_entry "$entry")
    t=$(ts_target_for_port "$port")
    if ! $TS_STATE_KNOWN || [ "${t:-}" != "$want" ]; then
      leftover+=("$entry")
    else
      rm -f "${files[$i]}" 2>/dev/null || true
      # Two different outcomes, so say which one happened: a cleared port and a
      # port handed back to a private mapping it carried before are not the same
      # thing, and "no longer exposed" would be false for the second.
      if [ -n "$want" ]; then
        ok "Port $port is back to the private mapping it carried before that run."
      else
        ok "Port $port is no longer exposed."
      fi
    fi
  done
  if [ ${#leftover[@]} -gt 0 ]; then
    warn "Could not confirm every leftover exposure was closed — often missing operator or root"
    warn "rights. Check 'tailscale serve status' / 'tailscale funnel status'. To close by hand:"
    print_undo_hints "${leftover[@]}"
    # The printed commands have to be runnable AS PRINTED. On a box where Tailscale
    # wants operator rights, a bare command answers with a permission error the
    # operator reads as a different fault than the one they have.
    local rp; rp=$(priv_prefix)
    [ -n "$rp" ] && note "If Tailscale refuses those, prefix each with '$rp'."
  fi
}

# The plain-words comparison behind the exposure menu's `?`. ADDITIVE only: it
# explains the same four options and re-prompts — never changes the choices,
# never recommends one (co-equal paths, honest trade-offs — the user picks).
explain_exposure_paths() {
  say ""
  say "  ${BOLD}The same gateway, four ways to reach it${RESET} — what each choice really means:"
  say ""
  say "  1) Tailscale — PRIVATE  (Tailscale's own name for this: \"Serve\")"
  say "     Who can reach it:  only devices signed in to your own Tailscale network."
  say "     What to install:   the free Tailscale app on each phone, tablet, or computer"
  say "                        running Conduck (an Apple Watch rides its nearby iPhone)."
  say "     Who sees traffic:  nobody — encrypted end-to-end; when Tailscale relays it,"
  say "                        it relays only encrypted data it cannot read."
  say "     Apple Watch:       works only while your iPhone is nearby (no Watch Tailscale app)."
  say ""
  say "  2) Tailscale Funnel — PUBLIC"
  say "     Who can reach it:  anyone on the internet who finds the URL can knock;"
  say "                        your gateway's token (its secret key) is the lock."
  say "     What to install:   nothing on your devices."
  say "     Who sees traffic:  nobody in between — encrypted end-to-end, Tailscale only relays."
  say "     Apple Watch:       works on its own, anywhere."
  say ""
  say "  3) Cloudflare Tunnel — PUBLIC"
  say "     Who can reach it:  anyone on the internet — same lock: the gateway's token."
  say "     What to install:   nothing on your devices; needs a domain you manage in"
  say "                        Cloudflare (~\$8/yr for the domain) and Cloudflare's"
  say "                        connector program (cloudflared) on this machine."
  say "     Who sees traffic:  Cloudflare can read it — your HTTPS ends at their servers;"
  say "                        the onward leg to this machine rides their encrypted tunnel."
  say "     Apple Watch:       works on its own, anywhere."
  say ""
  say "  4) Your own HTTPS — reach is whatever you built"
  say "     For a gateway that already has an https:// address — a reverse proxy or a"
  say "     rented server (VPS). Its certificate has to be one your phone already"
  say "     trusts by itself; a certificate you signed yourself does not qualify, and"
  say "     there is no way for the app to make an exception (I explain the free ways"
  say "     to get a real one if yours doesn't pass)."
  say "     A cloudflared quick tunnel is this one, not 3: the *.trycloudflare.com"
  say "     address 'cloudflared tunnel --url' prints comes with a certificate your"
  say "     devices already trust, and it needs no domain of your own."
  say "     Apple Watch:       works on its own IF that address works without a VPN."
  say ""
  say "  You can re-run this script any time and pick a different path."
  say ""
}

choose_exposure() {
  # Generic with a ready URL skips the transport menu — but still puts the
  # certificate through the same trust gate as menu option 4.
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
  say "  1) ${BOLD}Tailscale${RESET} — private, free  ($ts_state)"
  say "     Only devices on your own Tailscale network reach it; each device needs the Tailscale app."
  say ""
  say "  2) ${BOLD}Tailscale Funnel${RESET} — public, free  ($ts_state)"
  say "     Reachable from anywhere; nothing to install on your devices."
  say ""
  say "  3) ${BOLD}Cloudflare Tunnel${RESET} — public  ($cf_state)"
  say "     Rides a domain you manage in Cloudflare (~\$8/yr); Cloudflare can see the traffic."
  say ""
  # The parenthetical names the commonest casual exposure of all, `cloudflared tunnel
  # --url`. Its address belongs to option 4; unnamed here, a quick-tunnel user reads
  # option 3's "✓ cloudflared found" as their row and lands on the one path that wants
  # a domain they don't have. Unconditional on purpose — gating it on `have cloudflared`
  # would hide it whenever the tunnel runs from another terminal, host, or PATH.
  say "  4) ${BOLD}I already run my own HTTPS for it${RESET}  (or a *.trycloudflare.com quick tunnel)"
  say "     You give the https:// address; its certificate has to be one your devices already trust."
  say ""
  if $SETUP_FROM_CHECK; then
    say "  ${DIM}b) stop this setup (the completed check remains unchanged)${RESET}"
  else
    say "  ${DIM}b) go back to the gateway choice${RESET}"
  fi
  say ""
  say "  An Apple Watch used away from your iPhone needs a PUBLIC path: 2, 3 — or 4"
  say "  only if that address is reachable from anywhere."
  say ""
  local back_word="goes back"
  $SETUP_FROM_CHECK && back_word="stops setup"
  local choice; choice=$(require_choice "Choose 1-4 ('?' compares them in plain words, 'b' $back_word)" '^([1-4]|[bB])$' explain_exposure_paths) || die "$NO_ANSWER"
  [[ "$choice" =~ ^[bB]$ ]] && return 10   # back/stop — no exposure change has happened yet
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
        # Unlike the three failure handlers, `tailscale up` has NOT been tried yet,
        # so a bare command is the right print when this shell is already root.
        local up_priv; up_priv=$(priv_prefix)
        warn "Run '${up_priv:+$up_priv }tailscale up' to connect it to your tailnet (your private Tailscale"
        warn "network) — it opens a browser link to sign in the first time. Then re-run this"
        warn "script; it picks up where you left off."
        [ "$(id -u 2>/dev/null)" = 0 ] || [ -n "$up_priv" ] \
          || note "This shell is not root and has neither sudo nor doas — run that from a root shell."
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
      case "$h" in http://*|https://*) h="${h#*://}" ;; esac   # tolerate a pasted URL — keep the host part
      while [ "${h%/}" != "$h" ]; do h="${h%/}"; done
      [ -n "$h" ] || die "No hostname given. This option needs a domain already added to your Cloudflare account; if you don't have one yet, re-run and pick Tailscale instead, or add a domain in Cloudflare first."
      GW_URL="https://$h"
      apply_gateway_url_normalization
      ;;
    4)
      # One option for "I run my own HTTPS." It is a GATE, not a fork: the
      # certificate is either one this machine trusts (which is the bar the app
      # applies too) or the run stops.
      GW_URL=$(ask_url "The https:// web address that reaches your gateway" "https://ai.example.com") || die "$NO_ANSWER"
      apply_gateway_url_normalization
      scope_choice
      keyless_public_guard
      classify_own_https   # sets TRANSPORT=public, or STOPs and names the free routes
      ;;
    *) die "Invalid choice." ;;
  esac
}

# The plain-words help behind the reach question's `?`. The safety stakes are
# asymmetric — "public" only ADDS checks, a wrong "private" SKIPS them — so the
# unsure are pointed at Public (a fail-safe direction, not a transport pick).
explain_scope_choice() {
  say ""
  say "  Why I ask: your answer doesn't change who can reach the address — it only"
  say "  decides how strict I am. If you answer Public, I refuse to pair a gateway"
  say "  that has no token (secret key). Calling a public address \"private\" would"
  say "  skip that protection; calling a private one \"public\" can at worst block a"
  say "  token-less private setup — it never weakens anything."
  say ""
  say "  Public  — reachable from the open internet. Typical: Tailscale Funnel,"
  say "            Cloudflare Tunnel, a rented server (VPS) with its own domain."
  say "  Private — answers only inside your home/office network or a VPN like"
  say "            Tailscale. From anywhere else the address simply doesn't load."
  say ""
  say "  Honestly unsure? Answer Public — the strict path is the safe path."
  say ""
}

# Ask whether the URL is publicly reachable. Safety-relevant (it gates the
# keyless-public guard), so it takes an explicit 1/2 — no Enter default a typo
# could fall into. Sets SCOPE.
scope_choice() {
  note "Rule of thumb: if you could open this address from your phone on cellular (Wi-Fi off),"
  note "it's public; if it only works on your home/office network or a VPN like Tailscale, it's private."
  say "    1) Public — reachable from the open internet"
  say "    2) Private — only my own network / VPN (Tailscale, home or office LAN)"
  local c; c=$(require_choice "Is this address public or private? Choose 1-2 ('?' explains)" '^[12]$' explain_scope_choice) || die "$NO_ANSWER"
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

# Split an https URL's authority into an openssl `-connect` target and an SNI
# servername, handling a bracketed IPv6 literal. Echoes "connectarg<TAB>servername".
# The servername is EMPTY for a bracketed IP literal (no SNI is sent for a bare IP);
# a portless authority defaults to :443. The naive `*:*` port test wrongly fires on an
# IPv6 literal's inner colons, so a portless [::1] never got :443 — hence the explicit
# bracket case. bash 3.2-safe (no arrays, no mid-`local` self-reference).
tls_connect_target() { # tls_connect_target <https-url> -> "connectarg\tservername"
  local a; a="${1#https://}"; a="${a%%/*}"
  local connectarg sni after port
  case "$a" in
    \[*\]*)                                    # bracketed IPv6 literal, optional :port
      sni=""                                   # openssl/curl send no SNI for an IP literal
      after="${a#*\]}"                          # "" or ":port"
      case "$after" in :*) port="${after#:}" ;; *) port="443" ;; esac
      connectarg="${a%%\]*}]:$port" ;;          # keep the brackets for -connect
    *:*)  connectarg="$a"; sni="${a%:*}" ;;     # host:port (single colon)
    *)    connectarg="$a:443"; sni="$a" ;;      # bare host, no port
  esac
  # No SNI for a bare IP literal — the IPv6 case above, and a bare IPv4 (host is only
  # digits and dots) here; curl/openssl send no SNI for an IP, so we mustn't either.
  case "$sni" in ''|*[!0-9.]*) ;; *) sni="" ;; esac
  printf '%s\t%s' "$connectarg" "$sni"
}

# Read the leaf cert's openssl verify return code — the stable X509_V_ERR_*
# numbers (same on OpenSSL and LibreSSL), so we classify WHY normal TLS trust
# failed without fragile date math.
cert_verify_code() { # cert_verify_code <https-url> -> numeric code (or "")
  local url="$1" _tgt connectarg sni; _tgt=$(tls_connect_target "$url")
  connectarg="${_tgt%%$'\t'*}"; sni="${_tgt#*$'\t'}"
  local sni_args=(); [ -n "$sni" ] && sni_args=(-servername "$sni")
  openssl s_client -connect "$connectarg" ${sni_args[@]+"${sni_args[@]}"} </dev/null 2>/dev/null \
    | sed -n 's/.*[Vv]erify return code: \([0-9][0-9]*\).*/\1/p' | tail -1
}

# Leaf-cert date sanity, checked independently of the chain verify code (some
# OpenSSL builds report the chain error first) so an untrusted certificate that
# is ALSO expired or not-yet-valid still gets its dates named — a wrong clock is
# the one cause the user can fix without changing certificate at all. Echoes
# "expired" / "notyet" / nothing; an unreadable cert counts as expired.
cert_leaf_date_problem() { # cert_leaf_date_problem <https-url>
  local url="$1" pem _tgt connectarg sni; _tgt=$(tls_connect_target "$url")
  connectarg="${_tgt%%$'\t'*}"; sni="${_tgt#*$'\t'}"
  local sni_args=(); [ -n "$sni" ] && sni_args=(-servername "$sni")
  pem=$(openssl s_client -connect "$connectarg" ${sni_args[@]+"${sni_args[@]}"} </dev/null 2>/dev/null | openssl x509 2>/dev/null)
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

# Is this address a `cloudflared tunnel --url` quick tunnel? Matched on the host
# only, lowercased, so a path or a port cannot smuggle the suffix past the test.
is_quick_tunnel_url() { # is_quick_tunnel_url <url>
  local a; a="${1#*://}"; a="${a%%/*}"; a="${a%%:*}"
  a=$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')
  case "$a" in *.trycloudflare.com) return 0 ;; esac
  return 1
}

# A quick tunnel's hostname is REASSIGNED every time `cloudflared tunnel --url`
# restarts — including at every reboot. Nothing on this machine and nothing in the
# app learns the new one: the paired device keeps calling a hostname that no longer
# resolves, and the live address exists in no saved profile and no output of this
# script. That is how the tunnel is designed, so there is nothing to fix and the
# only honest move is to say it at the moment the address is accepted, while the
# operator can still choose a path whose address survives a restart.
warn_quick_tunnel_url() {
  is_quick_tunnel_url "$GW_URL" || return 0
  say ""
  warn "That is a Cloudflare QUICK TUNNEL address, and its hostname changes every time the"
  warn "tunnel restarts — a reboot, a crash, or a Ctrl-C in the terminal running it."
  warn "When it changes, the setup code from this run points at a hostname that no longer"
  warn "exists: the app just stops connecting, and nothing here can learn the new address."
  say "  ${BOLD}Keep that tunnel running${RESET} for as long as you want Conduck to reach this gateway, and"
  say "  re-run this script for a fresh code after every restart of it."
  say "  For an address that survives a restart: a Cloudflare NAMED tunnel on a domain you"
  say "  manage (option 3), or Tailscale (options 1 and 2), whose hostname is permanent."
  say ""
}

# The "I run my own HTTPS" gate. The certificate must be one THIS machine already
# trusts, because that is the same bar the app applies on the phone: Apple's App
# Transport Security refuses an untrusted chain before the app is consulted, and a
# fingerprint pin cannot override it — a pin only NARROWS trust the device already
# has, it never grants it. So there is no accept-anyway arm to offer; an untrusted
# certificate ends the run, with the reason named and the free remedies listed.
classify_own_https() {  # GW_URL + SCOPE already set
  warn_quick_tunnel_url   # before the certificate gate: it is true whatever the cert says
  if $DRY_RUN; then
    TRANSPORT="public"   # provisional routing; a real run runs the trust gate
    plan_add "CHECK the certificate at $GW_URL — setup continues only if this machine trusts it"
    note "(dry-run: on a real run I check this certificate; one this machine doesn't trust stops setup)"
    return 0
  fi
  say ""
  note "Checking the certificate at $GW_URL …"
  # Capture curl's exit code directly — `$?` read after a completed `if` would be
  # the if-statement's own status (always 0 here), never curl's.
  local rc=0
  curl -q -sS --max-time 15 -o /dev/null "$GW_URL/v1/models" 2>/dev/null || rc=$?
  if [ "$rc" = "0" ]; then
    TRANSPORT="public"
    ok "Its certificate is trusted normally — that's exactly what the app needs."
    return 0
  fi
  case "$rc" in
    6)  die "Couldn't resolve the host in $GW_URL. Check the address and re-run." ;;
    7)  die "Couldn't connect to $GW_URL (connection refused). Is the gateway up? Re-run when it is." ;;
    28) die "Connecting to $GW_URL timed out. Check the address / firewall and re-run." ;;
  esac
  # Reached the server but trust failed. The outcome is the same either way —
  # stop — but WHY decides which remedy is the user's: a wrong clock, a wrong
  # hostname, and no trusted issuer at all are three different jobs.
  local code reason
  code=$(cert_verify_code "$GW_URL")
  case "$code" in
    18|19|20|21)
      reason="is signed by an issuer this machine doesn't trust (self-signed, or a private CA)"
      case "$(cert_leaf_date_problem "$GW_URL")" in
        expired) reason="$reason, and it has expired" ;;
        notyet)  reason="$reason, and it is not valid yet (check the gateway's clock)" ;;
      esac ;;
    10) reason="has expired" ;;
    9)  reason="is not valid yet (check the gateway's clock)" ;;
    0)  reason="is valid but does not match this address (it's issued for a different hostname)" ;;
    *)  reason="couldn't be classified (TLS verify code '${code:-none}')" ;;
  esac
  bad "The certificate at $GW_URL $reason."
  say "  Conduck needs a certificate your phone, tablet, or Mac trusts on its own — the"
  say "  same bar this machine just applied. Apple rejects an untrusted certificate"
  say "  before the app can see it, and no fingerprint you paste into the app changes"
  say "  that: pinning narrows trust a device already has, it never grants it. So there"
  say "  is no \"accept it anyway\" here, and a setup code that pretended otherwise would"
  say "  simply fail on your phone."
  say ""
  say "  ${BOLD}Three free ways to get a certificate that works${RESET} — each one automatic after setup:"
  say "    • ${BOLD}Tailscale Serve${RESET} — issues a real certificate for you and exposes nothing"
  say "      publicly. Re-run me and pick option 1."
  say "    • ${BOLD}Let's Encrypt${RESET} — free, and since January 2026 it also issues certificates for"
  say "      a bare IP address, so you don't need to own a domain."
  say "    • ${BOLD}A domain in front of it${RESET} — Caddy (or another reverse proxy) obtains and renews"
  say "      the certificate automatically."
  die "Stopped — the certificate $reason. Fix that, then re-run me."
}
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

fs_all_units() {
  local f
  if [ "$OS" = "Linux" ]; then
    for f in "$HOME"/.config/systemd/user/conduck-files-*.service \
             "$HOME/.config/systemd/user/conduck-files.service" \
             "$HOME/.config/systemd/user/conduck-fileserver.service"; do
      [ -f "$f" ] && printf '%s\n' "$f"
    done
  else
    for f in "$HOME"/Library/LaunchAgents/ai.gigaduck.conduck-files-*.plist \
             "$HOME/Library/LaunchAgents/ai.gigaduck.conduck-files.plist" \
             "$HOME/Library/LaunchAgents/ai.gigaduck.conduck-fileserver.plist"; do
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
    ""|*[!A-Za-z0-9._/@:+-]*)
      local value="$1"
      value="${value//\'/\'\\\'\'}"   # ' → '\'' (close, escape, reopen)
      printf "'%s'" "$value" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Resolve the shared folder before ANY service definition records it, and refuse
# the two roots that turn this lane into a remote file browser for the whole
# account. Mirrors the doctor's gate in 61-check-adapter-files.inc.sh, so setup
# cannot certify a root the doctor refuses to grade.
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
  out=$(python3 - "$1" <<'PY' 2>/dev/null
import os, sys
p = sys.argv[1]
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
  note "It has to be the agent's working folder, never your whole account: served from / or your home"
  note "directory, anything holding the file password can read your keys — and this connector's own"
  note "credential files — and write into them."
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
      warn "I will not expose it because its saved credential is not wired into rclone."
      fs_envfile_exposure_warning
      return 1 ;;
    *)
      warn "The existing file-server unit has an EnvironmentFile form this connector will not rewrite."
      warn "Repair or remove that exact connector-owned unit, then re-run setup."
      fs_envfile_exposure_warning
      return 1 ;;
  esac

  env_cred=$(env_get "$expected" "RCLONE_PASS" 2>/dev/null || true)
  if ! credential_value_safe "$env_cred" || [ "$env_cred" != "$FS_CRED" ]; then
    warn "The unit's environment file is missing or does not match its saved credential."
    warn "Refusing to rewrite or expose it; repair/remove the exact unit and re-run."
    fs_envfile_exposure_warning
    return 1
  fi
  [ "$status" = "ready" ] && return 0

  warn "This connector-owned unit uses the old quoted EnvironmentFile form."
  # Wording verified against rclone 1.74: `--user conduck` with no password does
  # NOT serve openly. It demands an EMPTY password, so the saved credential gets
  # 401 like every other one. Calling that "unauthenticated" sends the operator
  # hunting for an intrusion, when the real symptom is attachments that can never
  # authenticate.
  note "systemd treats those quotes as part of the path, so rclone never reads the password"
  note "file and demands an EMPTY password instead: it answers 401 to the saved credential —"
  note "and to every other password — while the user 'conduck' with a blank password gets in."
  note "I can replace only that one directive with the same absolute path unquoted,"
  note "then reload and restart this unit."
  if $DRY_RUN; then
    plan_add "REPAIR legacy quoted EnvironmentFile in $FS_UNIT; daemon-reload + restart"
    note "(dry-run: a real run asks before repairing that connector-owned unit)"
    return 0
  fi
  if $REUSE_ONLY; then
    warn "(reuse-only: not repairing the legacy unit; leaving the file lane out)"
    return 1
  fi
  if ! confirm "  Repair this connector-owned unit now?"; then
    note "Leaving the file lane out; chat is unaffected."
    fs_envfile_exposure_warning
    return 1
  fi
  mutate_guard "repair the legacy connector-owned EnvironmentFile directive" || return 1
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
      FS_PORT_ALLOCATION_REASON="Found connector-owned unit $unit, but its loopback port cannot be read safely. Repair or remove that unit before adding another file lane."
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
    warn "Found $unit, but its file-server credential could not be recovered safely."
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
  run_step "enable linger so the file server survives logout and reboot" \
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
  local ws="$1" envf rclone_bin q_ws env_directive q_rclone
  envf=$(state_env_file)
  rclone_bin=$(command -v rclone)
  if ! credential_value_safe "$FS_CRED" \
     || ! q_ws=$(fs_systemd_quote "$ws") \
     || ! env_directive=$(fs_systemd_envfile_path "$envf") \
     || ! q_rclone=$(fs_systemd_quote "$rclone_bin"); then
    warn "The file credential or selected paths contain characters this systemd unit cannot encode safely."
    return 1
  fi
  FS_UNIT="$HOME/.config/systemd/user/conduck-files-$GW_ID.service"
  # Two mkdirs, deliberately: the systemd unit directory is shared with the rest
  # of the user's units and keeps the ambient mode, while $STATE_DIR goes through
  # ensure_state_dir — it holds fileserver-*.cred/.env and profile-*.json, so it
  # is created 0700 and an already-open one is reported rather than left silent.
  mkdir -p "$(dirname "$FS_UNIT")"
  ensure_state_dir
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
EnvironmentFile=$env_directive
ExecStart=$q_rclone serve webdav $q_ws --addr 127.0.0.1:$FS_LOCAL_PORT --user conduck --dir-cache-time 1s
Restart=on-failure

[Install]
WantedBy=default.target
EOF
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
    warn "The file credential contains control characters and cannot be stored safely."
    return 1
  }
  FS_UNIT="$HOME/Library/LaunchAgents/ai.gigaduck.conduck-files-$GW_ID.plist"
  # Split for the same reason as the Linux twin: LaunchAgents is shared with the
  # user's other agents and keeps the ambient mode; $STATE_DIR holds credentials
  # and profile-*.json, so it goes through ensure_state_dir.
  mkdir -p "$(dirname "$FS_UNIT")"
  ensure_state_dir
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
    if systemctl --user is-active --quiet "$(basename "$FS_UNIT")"; then
      printf 'active'
    else
      printf 'inactive'
    fi
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

# The exact commands that remove ONE connector-owned file server. Shared by every
# caller so they cannot drift, and printed rather than run: this tool has no
# removal command, so copy-pasteable text IS the mechanism.
fs_print_teardown() { # fs_print_teardown <unit-path-or-empty> [credential-file…]
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

# A lane that is BUILT but never shipped leaves a live, authenticated WebDAV
# server over the agent's working folder, a credential on disk, and — on the
# transports whose HTTPS route the operator creates by hand — a route still
# pointing at it. Only Tailscale mappings get rolled back (they are the only
# exposure this connector applies itself), so on the other transports the run
# otherwise ends green and never mentions the server, the credential, or the
# route again. Same shape whether a Step-5 probe failed or the run was
# interrupted between the unit and the pairing code.
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
    note "credential: $f"
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
  note "with the same credential."
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
    warn "I can't ask this machine whether the file server is running (no systemctl/launchctl here),"
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
    note "I can't rebuild it here — its served folder or credential isn't recoverable. Remove the unit"
    note "and re-run me to build the lane again."
    return 1
  fi
  if $REUSE_ONLY; then
    note "(reuse-only: not moving the lane to another port — re-run without --reuse-only to do that.)"
    return 1
  fi
  if ! confirm "  Move this file lane to a different free port and start it there?"; then
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
    warn "The active file-server service did not answer with its saved credential on 127.0.0.1:$FS_LOCAL_PORT."
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
      warn "The local file server did not reject both missing and wrong credentials — leaving the lane out."
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

# Promote a private file lane to PUBLIC (Funnel) so it matches a public gateway.
# Publication event → a SECOND explicit confirm on top of the menu choice.
fs_promote_public() { # fs_promote_public <existing-https-port> <existing-verb> <host>
  local ehttps="$1" everb="$2" host="$3"
  if ! confirm "  Expose your files to the PUBLIC internet (only the credential guards them)?"; then
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
        if confirm "  Keep the file lane PRIVATE instead (reachable on your Tailscale network)?"; then
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
    c=$(require_choice "Choose 1-3 ('?' explains)" '^[123]$' explain_fs_mismatch) || die "$NO_ANSWER"
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
      c=$(require_choice "Choose 1-2 ('?' explains)" '^[12]$' explain_fs_mismatch) || die "$NO_ANSWER"
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
    c=$(require_choice "Choose 1-3 ('?' explains)" '^[123]$' explain_fs_mismatch) || die "$NO_ANSWER"
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
        if run_step "allow the agent's file tools in OpenClaw's tool policy" \
          docker compose --project-directory "$compose_dir" run --rm --no-deps --entrypoint node openclaw-gateway \
            dist/index.js config set --batch-json "$ops"; then
          policy_saved=true
          if run_step "restart the gateway so the policy applies" \
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
        if print_and_wait "Not the standard Docker setup — apply the policy change with your install's CLI, then restart the gateway." \
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
      if [ "$recheck" = "ok" ]; then
        ok "Tool policy re-checked — openclaw.json is file-transfer-ready."
        # The re-read proves the FILE, so a policy the running gateway never
        # reloaded may not say what the config now says.
        if ! $restart_done; then
          warn "The gateway was not restarted, so it is still running with its old policy."
          note "Restart it when you can; until then the agent still can't open the files Conduck uploads."
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
        ok "Found your existing file server: folder + port $FS_LOCAL_PORT, credential recovered." ;;
      inactive)
        warn "Found this gateway's file-server unit (folder + port $FS_LOCAL_PORT, credential recovered),"
        warn "but its service is NOT running." ;;
      *)
        ok "Found this gateway's file-server unit: folder + port $FS_LOCAL_PORT, credential recovered."
        note "(I can't ask this machine whether its service is running.)" ;;
    esac
    workspace="$FS_FOLDER"
    # The served root is re-certified and re-published on every run, so a root the
    # doctor refuses to grade must not pass here either — this is the one gate
    # between a mis-pointed unit and a pairing code that publishes it.
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
    case "$GW_KIND" in
      openclaw) workspace="$HOME/.openclaw/workspace" ;;
      hermes)   workspace="$HOME/.hermes/files" ;;
      *)        workspace="$HOME/conduck-files" ;;
    esac
    if [ "$GW_KIND" = "custom" ] || confirm "  Use a different folder than $workspace?"; then
      while true; do
        local w; w=$(ask "  Absolute path to the agent's working folder" "$workspace")
        case "$w" in /*) ;; *) warn "Please give an absolute path (starting with /)."; continue ;; esac
        if ! fs_resolve_shared_folder "$w"; then
          fs_folder_refusal_warn "$w"
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
        plan_add "MINT a file-server credential; write unit conduck-files-$GW_ID + 0600 cred file; serve the EXISTING folder $workspace (permissions untouched) on 127.0.0.1:$FS_LOCAL_PORT"
      else
        plan_add "CREATE the shared agent folder $workspace (0700); MINT a file-server credential; write unit conduck-files-$GW_ID + 0600 cred file; serve $workspace on 127.0.0.1:$FS_LOCAL_PORT"
      fi
      note "(dry-run: would mint a credential and write the file-server unit)"
    else
      mutate_guard "write file-server unit + credential" || {
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
      ok "Minted a fresh high-entropy credential (stored 0600; rides in the QR, never on the command line)."
      # From the next line on there is a credential on disk and, moments later, a
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
        local h; h=$(ask_url "The file-lane web address (blank to skip the file lane)" "https://files.example.com" 1) || die "$NO_ANSWER"
        if [ -n "$h" ]; then FS_URL="$h"; FS_ROUTE_SELF_MANAGED=true; fs_warn_quick_tunnel_url
        else note "No address — leaving the file lane out of the QR."; FS_CRED=""; fs_lane_residue_note; fi
      elif print_and_wait "Same dance as before: ingress rule + 'tunnel route dns' + restart cloudflared." \
        "cloudflared tunnel route dns <your-tunnel> files.YOURDOMAIN"; then
        FS_ROUTE_SELF_MANAGED=true
        local h2; h2=$(ask_url "The file-lane web address you configured (blank to skip the file lane)" "https://files.example.com" 1) || die "$NO_ANSWER"
        if [ -n "$h2" ]; then FS_URL="$h2"; fs_warn_quick_tunnel_url
        else note "No address — leaving the file lane out of the QR."; FS_CRED=""; fs_lane_residue_note; fi
      else FS_CRED=""; fs_lane_residue_note; fi
      ;;
    public)
      say ""
      say "  Your gateway's web server needs a second route for the file lane → 127.0.0.1:$FS_LOCAL_PORT"
      say "  (a second server block, a subdomain, or another port)."
      note "Give it the same reach as the gateway (both public, or both private) — attachments follow this address."
      note "Its certificate must be trusted the same way the gateway's is; the app applies one rule to both."
      local h; h=$(ask_url "The https:// web address that reaches it (blank to skip the file lane)" "https://files.example.com" 1) || die "$NO_ANSWER"
      if [ -n "$h" ]; then
        FS_URL="$h"
        FS_ROUTE_SELF_MANAGED=true   # their own web server holds it; only they can take it back down
        fs_warn_quick_tunnel_url     # "my own HTTPS" reaches a quick tunnel just as easily
      else
        note "Skipped the file lane (Conduck still works — inline-only attachments)."
        FS_CRED=""
        fs_lane_residue_note
      fi
      ;;
  esac
}
# --- Hermes agent-side readiness ---------------------------------------------
# Current Hermes API-server releases expose the full toolset by default. A
# user-supplied `platform_toolsets.api_server` narrows that default, though, and
# an explicit list without `file` removes read_file/write_file while chat stays
# perfectly green. `terminal.cwd` independently decides where those tools land.
# We inspect only these narrow YAML paths with a conservative stdlib parser.
# Anchors, flow maps, non-local backends, and global file-tool disables are
# deliberately "manual": guessing at them would broaden privileges silently.
#
# That same key decides something Conduck cares about even more than files: the
# default API-server toolset carries Hermes's `memory` and `session_search`
# tools, so an untouched Hermes answers a brand-new conversation from facts the
# app never sent. Conduck replays the whole conversation every turn and owns the
# history; a gateway that keeps its own contradicts that and pays for the hidden
# context on every turn. No request/response check can see it — a remembering
# gateway passes every wire check — so the scope is classified here, at the
# point where the configuration is chosen, and reported before anything is
# declared ready.
HERMES_CONFIG_CHANGED_THIS_RUN=false
HERMES_GUIDANCE_CHANGED_THIS_RUN=false
HERMES_GUIDANCE_TARGET_THIS_RUN=""
HERMES_RESIDUAL_REPORTED=false
HERMES_SCOPE_CHANGED_THIS_RUN=false
# Fail-safe defaults: a run that never manages to read the config must report
# "I cannot tell", never silence. Silence would read as an all-clear.
HERMES_RECALL_STATE="unknown"
HERMES_RECALL_FIX="none"
HERMES_RECALL_ITEMS=()
HERMES_RECALL_SCOPE=""
HERMES_RECALL_AFTER=""
HERMES_RECALL_REPORTED=false
# A no to the removal is a no for the whole run. Asking the same question again
# at the next Hermes step would read as nagging, not as consent.
HERMES_RECALL_DECLINED=false
HERMES_ANALYSIS_STATUS=""
HERMES_ANALYSIS_REASONS=()
HERMES_ANALYSIS_CHANGES=()

hermes_residual_state_note() {
  [ "${GW_KIND:-}" = "hermes" ] || return 0
  $HERMES_RESIDUAL_REPORTED && return 0
  local changed=false
  if $HERMES_CONFIG_CHANGED_THIS_RUN; then
    note "The narrow Hermes config.yaml edit approved earlier remains in place (terminal.cwd / the API-server toolset list only)."
    changed=true
  fi
  if $HERMES_GUIDANCE_CHANGED_THIS_RUN; then
    note "The marker-delimited Conduck guidance block remains in ${HERMES_GUIDANCE_TARGET_THIS_RUN:-the Hermes workspace}."
    changed=true
  fi
  if $HERMES_SCOPE_CHANGED_THIS_RUN; then
    note "The approved removal of Hermes's recall tools from its API-server scope also remains in place."
    changed=true
  fi
  if $changed; then
    note "Those independent host edits are not transactionally rolled back when a later optional file-lane step fails or is declined."
    HERMES_RESIDUAL_REPORTED=true
  fi
}

# hermes_config_analysis <config> <workspace> [analyze|recall|apply|apply-recall] [approved-scope-json]
# `recall` classifies only the API-server recall scope (no workspace needed).
# `apply-recall` removes ONLY the approved recall entries — it never touches
# terminal.cwd or the file toolset. The 4th argument is the exact api_server
# list the operator was shown when approving; a mismatch refuses the write, so
# an edit made between the preview and the yes can never be silently overwritten.
hermes_config_analysis() {
  python3 - "$1" "$2" "${3:-analyze}" ${4+"$4"} <<'PY'
import json, os, re, stat, sys, tempfile

path, workspace, action = sys.argv[1:4]
scope_expect = sys.argv[4] if len(sys.argv) > 4 else None
recall_only = action in ("recall", "apply-recall")
workspace = os.path.realpath(os.path.expanduser(workspace))
if os.path.lexists(path) and os.path.islink(path):
    print("status\tmanual")
    print("reason\tconfig.yaml is a symlink; refusing to edit through it")
    sys.exit(0)
try:
    raw = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
except Exception as exc:
    print("status\tmanual")
    print("reason\tcould not read config.yaml: %s" % type(exc).__name__)
    sys.exit(0)
lines = raw.splitlines(True)

KEY = re.compile(r"^([A-Za-z0-9_-]+):(?:[ \t]*(.*?))?[ \t]*(?:\n)?$")
CHILD = re.compile(r"^([ ]+)([A-Za-z0-9_-]+):(?:[ \t]*(.*?))?[ \t]*(?:\n)?$")
SPACED_KEY = re.compile(r"^([A-Za-z0-9_-]+)[ \t]+:")
PLAIN_STRING_ITEM = re.compile(
    r"^-[ ]+[A-Za-z0-9_][A-Za-z0-9_./-]*(?:[ \t]+#[^\r\n]*)?$")

def content(line):
    # Config keys/lists in the paths we edit must not rely on YAML comments,
    # anchors, tags, or multiline scalars. Values we write are JSON-quoted,
    # which is valid YAML and makes spaces/# unambiguous.
    return line.rstrip("\r\n")

def quoted_mapping_key(s):
    """Decode a simple quoted YAML mapping key; None means not safely decoded."""
    if s.startswith('"'):
        try:
            key, end = json.JSONDecoder().raw_decode(s)
        except Exception:
            return None
        if isinstance(key, str) and s[end:].lstrip().startswith(":"):
            return key
        return None
    if s.startswith("'"):
        m = re.match(r"^'((?:[^']|'')*)'[ \t]*:", s)
        if m:
            return m.group(1).replace("''", "'")
    return None

def top_section(name, src=None):
    src = lines if src is None else src
    hit = None
    for i, line in enumerate(src):
        s = content(line)
        if not s or s.lstrip().startswith("#") or s[:1].isspace():
            continue
        # A top-level flow mapping can carry every authoritative section on one
        # line (valid YAML/JSON). This block editor intentionally does not
        # rewrite flow documents; seeing one makes every queried section
        # ambiguous so apply can never append duplicate block sections.
        if s.startswith(("{", "[")):
            return ("AMBIG", None, None)
        # Quoted YAML keys are semantically the same keys, but this deliberately
        # small editor never rewrites them. Treat a quoted authoritative section
        # as ambiguous rather than appending a duplicate plain-key section.
        alternative = quoted_mapping_key(s)
        spaced = SPACED_KEY.match(s)
        if alternative == name or (spaced and spaced.group(1) == name):
            return ("AMBIG", None, None)
        m = KEY.match(s)
        if m and m.group(1) == name:
            if hit is not None:
                return ("AMBIG", None, None)
            if (m.group(2) or "").strip():
                return ("FLOW", i, None)
            hit = i
    if hit is None:
        return ("MISSING", None, None)
    end = len(src)
    for j in range(hit + 1, len(src)):
        s = content(src[j])
        if not s or s.lstrip().startswith("#"):
            continue
        if not s[:1].isspace():
            # PyYAML emits a top-level scalar sequence without indenting its
            # items (for example `toolsets:\n- hermes-cli`). Such an item still
            # belongs to the preceding root key; it is not a new root section.
            if PLAIN_STRING_ITEM.match(s):
                continue
            end = j
            break
    return ("OK", hit, end)

def unsupported_root_form(src=None):
    """True when the document root is outside the block-map subset we edit."""
    src = lines if src is None else src
    saw_document_start = False
    saw_root_entry = False
    root_sequence_open = False
    root_has_indented_content = False
    after_root_scalar_item = False
    for line in src:
        s = content(line)
        if not s or s.lstrip().startswith("#"):
            continue
        if s[:1].isspace():
            # A simple root scalar item cannot subsequently open an indented
            # mapping/continuation. Supporting that would turn this into a
            # general YAML parser, so fail closed.
            if after_root_scalar_item:
                return True
            root_has_indented_content = True
            continue
        # One plain document-start marker before the mapping is harmless. Tags,
        # directives, explicit keys, document-end markers, quoted/spaced keys,
        # and whole-document flow collections remain deliberately unsupported.
        if s == "---" and not saw_document_start and not saw_root_entry:
            saw_document_start = True
            continue
        # PyYAML's default dumper uses indentless sequences at the document
        # root. Accept only a simple scalar item attached to a preceding empty
        # plain root key. List-of-map, tagged, flow, and standalone root
        # sequences remain outside the editable subset.
        if PLAIN_STRING_ITEM.match(s):
            if not saw_root_entry or not root_sequence_open \
               or root_has_indented_content:
                return True
            after_root_scalar_item = True
            continue
        saw_root_entry = True
        after_root_scalar_item = False
        m = KEY.match(s)
        if not m:
            return True
        root_sequence_open = not (m.group(2) or "").strip()
        root_has_indented_content = False
    return False

def child(section, name, src=None):
    src = lines if src is None else src
    st, start, end = top_section(section, src)
    if st != "OK":
        return (st, None, None, None, None)
    # YAML permits any positive direct-child indentation, not just two spaces.
    # The FIRST content line establishes that direct-map indentation. Validate
    # the section as a conservative map/list tree, with two narrow additions
    # for normal PyYAML output: scalar sequence items may be indentless beneath
    # an immediately preceding empty map key, and an unrelated quoted or
    # prose-like scalar may continue on deeper lines within narrow boundaries.
    entries = []
    quote_kind = None
    quote_indent = None
    quote_escaped = False
    plain_indent = None

    def scan_double_quote(text, opened=False, escaped=False):
        i = 0
        if not opened:
            if not text.startswith('"'):
                return ("none", False)
            i = 1
        while i < len(text):
            ch = text[i]
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                tail = text[i + 1:]
                if tail.strip() and not tail.lstrip().startswith("#"):
                    return ("invalid", False)
                return ("closed", False)
            i += 1
        return ("open", escaped)

    def scan_single_quote(text, opened=False):
        i = 0
        if not opened:
            if not text.startswith("'"):
                return "none"
            i = 1
        while i < len(text):
            if text[i] == "'":
                if i + 1 < len(text) and text[i + 1] == "'":
                    i += 2
                    continue
                tail = text[i + 1:]
                if tail.strip() and not tail.lstrip().startswith("#"):
                    return "invalid"
                return "closed"
            i += 1
        return "open"

    def plain_string_can_continue(value):
        # PyYAML wraps long plain strings onto more-indented continuation
        # lines. Limit this accommodation to an obvious prose-like scalar;
        # typed/symbolic values and all authoritative target values remain
        # structurally checked rather than treated as opaque prose.
        return (
            bool(value)
            and value[0].isalnum()
            and any(ch.isspace() for ch in value)
        )

    for i in range(start + 1, end):
        s = content(src[i])
        if not s:
            continue
        # Root-level comments can follow the final section all the way to EOF.
        # Skip ordinary comments before demanding child indentation. A comment
        # inside a proved multiline quote remains scalar content and is scanned
        # below; one inside a plain continuation is handled by that state.
        if quote_kind is None and plain_indent is None \
           and s.lstrip().startswith("#"):
            continue
        prefix = s[:len(s) - len(s.lstrip(" \t"))]
        if "\t" in prefix:
            return ("AMBIG", None, None, None, None)
        lead = len(prefix)
        if lead <= 0:
            return ("AMBIG", None, None, None, None)
        if plain_indent is not None:
            if lead > plain_indent:
                if s.lstrip().startswith("#"):
                    continue
                # A colon followed by separation whitespace cannot continue a
                # YAML plain scalar. Treat it as structure instead of hiding a
                # target-looking mapping inside the prose accommodation.
                if re.search(r":(?:[ \t]|$)", s.lstrip(" ")):
                    return ("AMBIG", None, None, None, None)
                continue
            plain_indent = None
            if s.lstrip().startswith("#"):
                continue
        if quote_kind is not None:
            if lead <= quote_indent:
                return ("AMBIG", None, None, None, None)
            if quote_kind == "double":
                qst, quote_escaped = scan_double_quote(
                    s.lstrip(" "), opened=True, escaped=quote_escaped)
            else:
                qst = scan_single_quote(s.lstrip(" "), opened=True)
            if qst == "invalid":
                return ("AMBIG", None, None, None, None)
            if qst == "closed":
                quote_kind = None
                quote_indent = None
                quote_escaped = False
            continue
        m = CHILD.match(s)
        if m:
            value = (m.group(3) or "").strip()
            if value.startswith('"'):
                qst, quote_escaped = scan_double_quote(value)
            elif value.startswith("'"):
                qst = scan_single_quote(value)
            else:
                qst = "none"
            if qst == "invalid":
                return ("AMBIG", None, None, None, None)
            if qst == "open":
                quote_kind = "double" if value.startswith('"') else "single"
                quote_indent = lead
            elif m.group(2) != name and plain_string_can_continue(value):
                plain_indent = lead
        entries.append((i, lead, s))
    if quote_kind is not None:
        return ("AMBIG", None, None, None, None)

    direct_indent = entries[0][1] if entries else None
    levels, level_kinds = [], {}
    indentless_open = {}
    previous_indent, previous_opens = None, False
    for _, lead, s in entries:
        m = CHILD.match(s)
        stripped = s.strip()
        if m:
            node_kind = "map"
            node_opens = not (m.group(3) or "").strip()
        elif stripped == "-" or stripped.startswith("- "):
            item = stripped[1:].strip()
            node_kind = "list"
            node_opens = not item
        else:
            return ("AMBIG", None, None, None, None)

        indentless_item = False
        if previous_indent is None:
            levels = [lead]
        elif lead > previous_indent:
            if not previous_opens:
                return ("AMBIG", None, None, None, None)
            # This opening key chose an ordinarily indented child, so it cannot
            # later also own an indentless sequence.
            indentless_open[previous_indent] = False
            levels.append(lead)
        elif lead < previous_indent:
            while levels and levels[-1] > lead:
                levels.pop()
            if not levels or levels[-1] != lead:
                return ("AMBIG", None, None, None, None)

        expected_kind = level_kinds.get(lead)
        if expected_kind is None:
            level_kinds[lead] = node_kind
        elif expected_kind != node_kind:
            if expected_kind == "map" and node_kind == "list" \
               and indentless_open.get(lead, False) \
               and PLAIN_STRING_ITEM.match(stripped):
                indentless_item = True
            else:
                return ("AMBIG", None, None, None, None)

        if lead == direct_indent and node_kind != "map" and not indentless_item:
            return ("AMBIG", None, None, None, None)
        if node_kind == "map":
            indentless_open[lead] = node_opens
        previous_indent, previous_opens = lead, node_opens

    found = None
    for i, indent, s in entries:
        m = CHILD.match(s)
        if not m:
            continue
        if m.group(2) == name and indent != direct_indent:
            return ("AMBIG", None, None, None, None)
        if indent != direct_indent:
            continue
        if m.group(2) == name:
            if found is not None:
                return ("AMBIG", None, None, None, None)
            found = (i, (m.group(3) or "").strip(), indent, end)
    if found is None:
        return ("MISSING", None, None, direct_indent, end)
    return ("OK",) + found

NON_STRING = re.compile(
    r"(?ix)^(?:~|null|true|false|yes|no|on|off|"
    r"[-+]?(?:0|[1-9][0-9_]*)(?:\.[0-9_]*)?(?:e[-+]?[0-9]+)?|"
    r"[-+]?\.[0-9_]+(?:e[-+]?[0-9]+)?|"
    r"[-+]?\.?(?:inf|nan)|0x[0-9a-f_]+|0o[0-7_]+|0b[01_]+|"
    r"[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}(?:[tT ].*)?|[0-9]+:[0-9:]+)$")

def split_comment(value):
    """Strip a YAML plain comment, but never a # inside a JSON string."""
    quoted, escaped = False, False
    for i, ch in enumerate(value):
        if quoted:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                quoted = False
            continue
        if ch == '"':
            quoted = True
            continue
        if ch == "#" and (i == 0 or value[i - 1].isspace()):
            return value[:i].rstrip()
    if quoted or escaped:
        raise ValueError("unterminated JSON quote")
    return value.strip()

def unquoted_yaml_code(line):
    """Return only syntax outside YAML quote spans/comments for hazard scans."""
    out, double, single, escaped = [], False, False, False
    i = 0
    while i < len(line):
        ch = line[i]
        if double:
            out.append(" ")
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                double = False
            i += 1
            continue
        if single:
            out.append(" ")
            if ch == "'" and i + 1 < len(line) and line[i + 1] == "'":
                out.append(" "); i += 2; continue
            if ch == "'":
                single = False
            i += 1
            continue
        if ch == '"':
            double = True; out.append(" "); i += 1; continue
        if ch == "'":
            single = True; out.append(" "); i += 1; continue
        if ch == "#" and (i == 0 or line[i - 1].isspace()):
            break
        out.append(ch); i += 1
    return "".join(out)

ANCHOR_OR_ALIAS = re.compile(r"(?:^|[\s\[\]{},:?])(?:&|\*)[A-Za-z0-9_-]+")
MERGE_KEY = re.compile(r"(?:^|\s)<<[ \t]*:")

def string_value(value):
    try:
        value = split_comment(value)
    except ValueError:
        return "AMBIG", None
    if not value or not all(ch.isprintable() for ch in value):
        return "AMBIG", None
    # This subset deliberately accepts JSON double-quoted strings, not YAML
    # single-quoted strings. JSON decoding preserves commas, hashes, and
    # backslash escapes exactly instead of hand-stripping their delimiters.
    if value.startswith('"'):
        try:
            decoded = json.loads(value)
        except Exception:
            return "AMBIG", None
        if not isinstance(decoded, str) or not all(ch.isprintable() for ch in decoded):
            return "AMBIG", None
        return "OK", decoded
    if value.startswith("'") or value.endswith("'"):
        return "AMBIG", None
    if value[:1] in "|>&*!{[" or value.startswith("- ") \
       or ": " in value or NON_STRING.fullmatch(value):
        return "AMBIG", None
    return "OK", value

def scalar(section, name):
    st, i, value, indent, end = child(section, name)
    if st != "OK":
        return st, None
    return string_value(value)

def sequence(section, name, allow_null=False):
    st, i, value, indent, end = child(section, name)
    if st != "OK":
        return st, None, None
    if value:
        try:
            v = split_comment(value)
        except ValueError:
            return "AMBIG", None, None
        if allow_null and v == "null":
            return "OK", [], ("inline-null", i, indent, end)
        if v.startswith("[") and v.endswith("]"):
            try:
                vals = json.loads(v)
            except Exception:
                return "AMBIG", None, None
            if not isinstance(vals, list) or not all(
                    isinstance(item, str) and item and
                    all(ch.isprintable() for ch in item)
                    for item in vals):
                return "AMBIG", None, None
            return "OK", vals, ("inline", i, indent, end)
        vst, decoded = string_value(v)
        if vst != "OK":
            return "AMBIG", None, None
        return "OK", [decoded], ("inline", i, indent, end)
    # `items` carries each value with the exact line that holds it. Removing an
    # approved entry deletes that one line instead of re-serialising the list,
    # which would flatten indentation and drop the operator's own comments.
    vals, items, j, item_indent = [], [], i + 1, None
    while j < end:
        s = content(lines[j])
        if not s or s.lstrip().startswith("#"):
            j += 1; continue
        lead = len(s) - len(s.lstrip(" "))
        if lead < indent:
            break
        t = s.strip()
        # PyYAML emits a sequence value at the same indentation as its key:
        #   api_server:
        #   - web
        # A different mapping key at that level closes the sequence.
        if lead == indent and not t.startswith("- "):
            break
        if not t.startswith("- "):
            return "AMBIG", None, None
        if item_indent is None:
            item_indent = lead
        elif lead != item_indent:
            return "AMBIG", None, None
        ist, item = string_value(t[2:])
        if ist != "OK":
            return "AMBIG", None, None
        vals.append(item); items.append((j, item)); j += 1
    return "OK", vals, ("block", i, indent, j, item_indent, items)

# Hermes resolves an absent (or YAML-null) platform_toolsets.<platform> to that
# platform's own default bundle, and the API server's default bundle carries the
# `memory` and `session_search` tools. "No list" is therefore not "no recall" —
# it is the widest recall there is, which is why an unwritten key is reported
# rather than passed over.
RECALL_TOOLSETS = {"memory", "session_search"}
# Individually selectable Hermes toolsets in the releases this connector was
# built against. A name that is NOT one of these — a plugin toolset, or one a
# later release adds — is treated as unreadable rather than harmless: it may
# carry recall of its own, and assuming otherwise would print a false all-clear.
KNOWN_TOOLSETS = {
    "web", "browser", "terminal", "file", "code_execution", "vision", "video",
    "image_gen", "video_gen", "x_search", "tts", "stt", "skills", "todo",
    "memory", "context_engine", "session_search", "clarify", "delegation",
    "cronjob", "homeassistant", "spotify", "discord", "discord_admin",
    "yuanbao", "computer_use"}

def composite_bundle(name):
    """True for a name that expands to a whole platform's tools."""
    return name in ("all", "*") or name.startswith("hermes-")

def scope_line_plain(meta):
    """False when rewriting the api_server line would destroy a comment on it."""
    if not meta or meta[0] != "inline":
        return True
    m = CHILD.match(content(lines[meta[1]]))
    if not m:
        return False
    value = (m.group(3) or "").strip()
    try:
        return split_comment(value) == value
    except ValueError:
        return False

def classify_recall(readable, st, vals, meta, disabled):
    """(state, items, fixable) for recall reachable through the API server.

    state    in-scope | default-wide | clear | unknown
    fixable  literal  — plain entries this editor can delete by name
             none     — anything else; the operator edits it themselves
    """
    if not readable or st in ("AMBIG", "FLOW"):
        return ("unknown", [], "none")
    globally_off = RECALL_TOOLSETS <= disabled
    if st in ("MISSING", "NULL"):
        return ("clear", [], "none") if globally_off else ("default-wide", [], "none")
    if st != "OK":
        return ("unknown", [], "none")
    live = [v for v in vals if v not in disabled]
    composites = [v for v in live if composite_bundle(v)]
    hits = [v for v in live if v in RECALL_TOOLSETS]
    opaque = [v for v in live if v not in KNOWN_TOOLSETS and not composite_bundle(v)]
    if composites:
        # A bundle name cannot be edited down to "everything except memory";
        # deleting it would take the rest of that platform's tools with it.
        return ("clear", [], "none") if globally_off else ("in-scope", composites, "none")
    if hits:
        # Deleting the named entries only proves the scope clean when every
        # remaining name is one this connector actually knows.
        if opaque or not scope_line_plain(meta):
            return ("in-scope", hits, "none")
        return ("in-scope", hits, "literal")
    if opaque:
        return ("unknown", opaque, "none")
    return ("clear", [], "none")

manual = []
changes = []

if unsupported_root_form():
    manual.append("config.yaml uses a document-root YAML form outside this connector's conservative plain block-map subset")

if any(ANCHOR_OR_ALIAS.search(unquoted_yaml_code(content(line))) or
       MERGE_KEY.search(unquoted_yaml_code(content(line)))
       for line in lines):
    manual.append("YAML anchors, aliases, or merge keys can change the effective target paths; this connector will not edit through them")

# Whether the document itself is inside the editable subset. Captured before the
# path-specific reasons below so a workspace mismatch never makes the toolset
# look unreadable, or the other way round.
root_readable = not manual

pst, pvals, pmeta = sequence("platform_toolsets", "api_server")
# `api_server:` with nothing under it is YAML null, not an empty list. Hermes
# falls back to its wide default there, so treating it as "[]" would both
# mis-state the before→after and silently narrow the whole scope to whatever
# this connector appended.
if pst == "OK" and pmeta and pmeta[0] == "block" and not pvals:
    pst = "NULL"

dst, dvals, _dmeta = sequence("agent", "disabled_toolsets", allow_null=True)
disabled_toolsets = set(dvals) if dst == "OK" else set()

recall_state, recall_items, recall_fix = classify_recall(
    root_readable, pst, pvals, pmeta, disabled_toolsets)
print("recall\t" + recall_state)
print("recall_fix\t" + recall_fix)
for item in recall_items:
    print("recall_item\t" + item)
if recall_fix == "literal":
    # Both sides of the before→after, and the exact list the approval is bound
    # to. The caller hands `recall_scope` straight back on apply, so a config
    # edited between the preview and the yes refuses instead of overwriting.
    print("recall_scope\t" + json.dumps(pvals))
    print("recall_after\t" + json.dumps([v for v in pvals if v not in recall_items]))
if action == "recall":
    sys.exit(0)

# The approved removal, re-proved against the file as it is right now.
remove_targets = []
if scope_expect is not None:
    if recall_fix != "literal" or pst != "OK":
        manual.append("the API-server recall entries are not in the plain list form this connector edits")
    else:
        try:
            expected = json.loads(scope_expect)
        except Exception:
            expected = None
        if expected != pvals:
            manual.append("platform_toolsets.api_server changed after the exact edit was shown; re-run me")
        else:
            remove_targets = [v for v in pvals if v in recall_items]

if not recall_only:
    bst, backend = scalar("terminal", "backend")
    if bst == "OK" and backend not in ("", "local"):
        manual.append("terminal.backend is %r; a host WebDAV folder is not proven inside that backend" % backend)
    elif bst in ("AMBIG", "FLOW"):
        manual.append("terminal.backend uses YAML syntax this connector will not guess at")

    cst, cwd = scalar("terminal", "cwd")
    if cst == "OK":
        effective = os.path.realpath(os.path.expanduser(cwd))
        if not os.path.isabs(os.path.expanduser(cwd)) or effective != workspace:
            changes.append(("cwd", "terminal.cwd: %s -> %s" % (json.dumps(cwd), json.dumps(workspace))))
    elif cst in ("MISSING",):
        changes.append(("cwd", "terminal.cwd: (absent) -> %s" % json.dumps(workspace)))
    else:
        manual.append("terminal.cwd uses YAML syntax this connector will not guess at")

file_bundles = {"file", "all", "*", "hermes-api-server", "hermes-cli"}
if pst == "OK":
    # One projection, so an approved removal and the file toolset are shown and
    # written as a single before→after rather than two overlapping ones.
    want = [v for v in pvals if v not in remove_targets]
    if not recall_only and not file_bundles.intersection(want):
        want = want + ["file"]
    if want != pvals:
        changes.append(("toolset", "platform_toolsets.api_server: %s -> %s" %
                        (json.dumps(pvals), json.dumps(want))))
elif pst in ("AMBIG", "FLOW"):
    manual.append("platform_toolsets.api_server uses YAML syntax this connector will not guess at")
# Missing or null api_server means Hermes's own full API-server default remains
# authoritative, so its file tools are there. The live sentinel still proves the
# installed version rather than trusting that default on faith.

if not recall_only:
    for key, blocked in (("disabled_toolsets", {"file", "hermes-api-server"}),
                         ("disabled_tools", {"read_file", "write_file"})):
        st, vals, meta = sequence("agent", key, allow_null=True)
        if st == "OK" and blocked.intersection(vals):
            manual.append("agent.%s globally disables %s; removing it would broaden other Hermes platforms" %
                          (key, ", ".join(sorted(blocked.intersection(vals)))))
        elif st in ("AMBIG", "FLOW"):
            manual.append("agent.%s uses YAML syntax this connector will not guess at" % key)

if manual:
    print("status\tmanual")
    for reason in manual: print("reason\t" + reason)
    sys.exit(0)
if not changes:
    print("status\tready")
    if recall_only:
        print("reason\tthe API-server scope already carries no recall tools")
    else:
        print("reason\tfile toolset is not explicitly restricted and terminal.cwd matches the shared folder")
    sys.exit(0)
if action not in ("apply", "apply-recall"):
    print("status\tfix")
    for _, change in changes: print("change\t" + change)
    sys.exit(0)

def ensure_terminal(src):
    st, start, end = top_section("terminal", src)
    q = json.dumps(workspace)
    if st == "MISSING":
        if src and not src[-1].endswith(("\n", "\r")): src[-1] += "\n"
        if src and any(x.strip() for x in src): src.append("\n")
        src.extend(["terminal:\n", "  cwd: %s\n" % q])
        return src
    if st != "OK":
        raise ValueError("terminal section became ambiguous")
    cst, i, value, indent, cend = child("terminal", "cwd", src)
    if cst == "MISSING":
        child_indent = indent if indent is not None else 2
        src.insert(start + 1, " " * child_indent + "cwd: %s\n" % q)
    elif cst == "OK":
        src[i] = " " * indent + "cwd: %s\n" % q
    else:
        raise ValueError("terminal.cwd became ambiguous")
    return src

def remove_recall_entries(src, targets, expected):
    """Delete exactly the approved recall entries, or change nothing at all."""
    global lines
    lines = src
    st, vals, meta = sequence("platform_toolsets", "api_server")
    if st != "OK" or vals != expected:
        raise ValueError("api_server list changed before the edit")
    keep = [v for v in vals if v not in targets]
    kind, i, indent = meta[0], meta[1], meta[2]
    if kind == "inline":
        if not scope_line_plain(meta):
            raise ValueError("api_server line carries a comment")
        src[i] = " " * indent + "api_server: " + json.dumps(keep) + "\n"
        return src
    if kind != "block":
        raise ValueError("api_server is not in an editable list form")
    for line_no, value in sorted(meta[5], reverse=True):
        if value in targets:
            del src[line_no]
    if not keep:
        # An emptied block key is YAML null, which would hand the wide default —
        # memory included — straight back. Write the explicit empty list instead.
        src[i] = " " * indent + "api_server: []\n"
    return src

def ensure_api_file(src):
    global lines
    lines = src
    st, vals, meta = sequence("platform_toolsets", "api_server")
    if st != "OK" or file_bundles.intersection(vals):
        return src
    if meta[0] == "block" and not vals:
        return src   # bare key: YAML null, so Hermes's wide default still applies
    kind, i, indent, end = meta[:4]
    if kind == "inline":
        prefix = " " * indent + "api_server: "
        src[i] = prefix + json.dumps(vals + ["file"]) + "\n"
    else:
        item_indent = meta[4] if len(meta) > 4 and meta[4] is not None else indent + 2
        src.insert(end, " " * item_indent + "- file\n")
    return src

try:
    # Order matters: remove first, then add, then one atomic write. Each step
    # re-parses the buffer it is handed, so an insertion above the toolset key
    # cannot leave a later step editing a stale line number.
    if not recall_only:
        lines = ensure_terminal(lines)
    if remove_targets:
        lines = remove_recall_entries(lines, remove_targets, pvals)
    if not recall_only and any(kind == "toolset" for kind, _ in changes):
        lines = ensure_api_file(lines)
    data = "".join(lines)
    parent = os.path.dirname(path)
    os.makedirs(parent, exist_ok=True)
    mode = stat.S_IMODE(os.stat(path).st_mode) if os.path.exists(path) else 0o600
    fd, tmp = tempfile.mkstemp(prefix=".conduck-config.", dir=parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(data)
            f.flush(); os.fsync(f.fileno())
        os.replace(tmp, path)
    except Exception:
        try: os.unlink(tmp)
        except OSError: pass
        raise
except Exception as exc:
    print("status\tmanual")
    print("reason\tcould not apply the narrow config edit: %s" % type(exc).__name__)
    sys.exit(0)
print("status\tapplied")
PY
}

restart_hermes_for_config() {
  local restarted=1
  if [ "$OS" = "Linux" ] && have systemctl \
     && systemctl --user is-enabled hermes-gateway.service >/dev/null 2>&1; then
    run_step "restart Hermes so the approved config change applies" \
      systemctl --user restart hermes-gateway.service && restarted=0
  else
    print_and_wait "Restart Hermes however it runs on this machine so the approved config change takes effect." \
      "systemctl --user restart hermes-gateway.service   # or your own restart method" && restarted=0
  fi
  # Hermes's API server is not listening the moment the restart command returns,
  # and BOTH callers walk straight into config and lane decisions about it. Same
  # defect class as the OpenClaw restarts, so the same bounded wait. HTTP-safe is
  # TRUE: what the operator approved here is agent-side config, nowhere near the
  # HTTP layer. On a --check-server handoff the gateway is paired as `custom` and
  # GW_HEALTH_PATH is empty, so the wait says it cannot tell rather than guessing.
  [ "$restarted" -eq 0 ] && gw_note_restart_and_wait "Hermes configuration change" true
  return "$restarted"
}

# --- API-server recall scope --------------------------------------------------
# The one reader for every analysis mode. It always re-arms the recall globals
# first: a config it cannot read must report "unknown", never keep a previous
# answer, because silence here would be read as an all-clear.
hermes_analysis_read() { # hermes_analysis_read <config> <workspace> <action> [approved-scope]
  local tab line
  tab=$(printf '\t')
  HERMES_ANALYSIS_STATUS=""; HERMES_ANALYSIS_REASONS=(); HERMES_ANALYSIS_CHANGES=()
  HERMES_RECALL_STATE="unknown"; HERMES_RECALL_FIX="none"
  HERMES_RECALL_ITEMS=(); HERMES_RECALL_SCOPE=""; HERMES_RECALL_AFTER=""
  while IFS= read -r line; do
    case "$line" in
      "status$tab"*)       HERMES_ANALYSIS_STATUS="${line#status$tab}" ;;
      "reason$tab"*)       HERMES_ANALYSIS_REASONS+=("${line#reason$tab}") ;;
      "change$tab"*)       HERMES_ANALYSIS_CHANGES+=("${line#change$tab}") ;;
      "recall$tab"*)       HERMES_RECALL_STATE="${line#recall$tab}" ;;
      "recall_fix$tab"*)   HERMES_RECALL_FIX="${line#recall_fix$tab}" ;;
      "recall_item$tab"*)  HERMES_RECALL_ITEMS+=("${line#recall_item$tab}") ;;
      "recall_scope$tab"*) HERMES_RECALL_SCOPE="${line#recall_scope$tab}" ;;
      "recall_after$tab"*) HERMES_RECALL_AFTER="${line#recall_after$tab}" ;;
    esac
  done < <(hermes_config_analysis "$1" "$2" "$3" ${4+"$4"})
}

hermes_recall_read() { # hermes_recall_read <config>
  hermes_analysis_read "$1" "" recall
}

# One report per run, wherever the run first reaches a Hermes decision.
hermes_recall_report() {
  $HERMES_RECALL_REPORTED && return 0
  HERMES_RECALL_REPORTED=true
  local items
  items=$(safe_display "$(printf '%s' "${HERMES_RECALL_ITEMS[*]-}")" 120)
  say ""
  say "  ${BOLD}Hermes memory scope${RESET} — will this gateway remember what Conduck never sent it?"
  case "$HERMES_RECALL_STATE" in
    clear)
      ok "Nothing in this API-server toolset gives Hermes a memory of its own — the conversation stays Conduck's."
      return 0 ;;
    in-scope)
      warn "This gateway's API-server scope carries Hermes's own recall: ${items// /, }." ;;
    default-wide)
      warn "This config names no API-server toolset, so Hermes uses its default bundle — memory and session search included." ;;
    *)
      # `classify_recall` leaves $items non-empty here only when it read the list
      # fine but recognised none of the names — a different problem, and a
      # different fix, from a list it could not read at all.
      if [ -n "$items" ]; then
        warn "I can read this API-server list, but I do not recognise ${items// /, } — so I cannot tell whether it carries Hermes's own memory."
      else
        warn "I cannot read this config's API-server toolset, so I cannot tell whether Hermes keeps its own memory."
      fi ;;
  esac
  say "  Conduck sends the whole conversation every turn and expects the gateway to keep"
  say "  nothing of its own. One that remembers answers from things you never sent it, and"
  say "  you pay for that hidden context on every turn."
  say "  No connection check can see this, here or in --check-server: a remembering gateway"
  say "  passes them all. Test it yourself — tell it something in one conversation, then ask"
  say "  for it in a brand-new one. If it answers, the gateway is keeping its own history."
  return 0
}

# What to change by hand, for every shape this connector will not rewrite.
hermes_recall_manual_hint() { # hermes_recall_manual_hint <suggested-list>
  local suggested="${1:-[web]}"
  case "$HERMES_RECALL_STATE" in
    clear) return 0 ;;
    in-scope)
      local entry bundle=false
      for entry in ${HERMES_RECALL_ITEMS[@]+"${HERMES_RECALL_ITEMS[@]}"}; do
        case "$entry" in hermes-*|all|'*') bundle=true ;; esac
      done
      if $bundle; then
        say "  That name is a whole bundle, and Hermes's bundles carry its memory tools. In"
        say "  ${BOLD}~/.hermes/config.yaml${RESET}, replace it with the toolsets you actually want —"
        say "  for example ${BOLD}api_server: $suggested${RESET} — and restart Hermes."
      else
        say "  In ${BOLD}~/.hermes/config.yaml${RESET}, take memory and session_search out of the"
        say "  platform_toolsets.api_server list, leave everything else, and restart Hermes."
      fi ;;
    default-wide)
      say "  Name the toolsets yourself in ${BOLD}~/.hermes/config.yaml${RESET}, then restart Hermes:"
      say "    platform_toolsets:"
      say "      api_server: $suggested" ;;
    *)
      say "  Check platform_toolsets.api_server in ${BOLD}~/.hermes/config.yaml${RESET} yourself —"
      say "  memory and session_search belong to your other Hermes surfaces, not to this one." ;;
  esac
  say "  This key is per-surface: your Hermes CLI and messaging surfaces keep their memory,"
  say "  and so does anything else you point at this same API server."
  return 0
}

# The one edit offered here, and only in its plainest form: named entries in an
# explicit list. A bundle name, an unwritten key, or anything this parser cannot
# read is described instead of rewritten — deleting a bundle would take a whole
# platform's tools with it, and inventing a list where the user wrote none would
# narrow far more than memory.
hermes_recall_remove_step() { # hermes_recall_remove_step <config> -> 0 when the scope is proven clear
  local cfg="$1" status
  [ "$HERMES_RECALL_FIX" = "literal" ] || return 1
  [ -n "$HERMES_RECALL_SCOPE" ] || return 1
  say ""
  say "  ${BOLD}platform_toolsets.api_server: $HERMES_RECALL_SCOPE -> $HERMES_RECALL_AFTER${RESET}"
  say "  Only that one list changes. Every other toolset in it stays, and Hermes's other"
  say "  surfaces are untouched — but anything else talking to this same API server loses"
  say "  its memory too."
  if ! confirm "  Remove Hermes's recall tools from its API-server scope?"; then
    note "Leaving it as it is."
    HERMES_RECALL_DECLINED=true
    return 1
  fi
  mutate_guard "remove only the recall entries from platform_toolsets.api_server in $cfg" || return 1
  status=$(hermes_config_analysis "$cfg" "" apply-recall "$HERMES_RECALL_SCOPE" \
    | awk -F '\t' '$1=="status"{print $2; exit}')
  if [ "$status" != "applied" ]; then
    warn "That edit could not be applied safely, so nothing was changed."
    return 1
  fi
  HERMES_SCOPE_CHANGED_THIS_RUN=true
  hermes_recall_read "$cfg"
  if [ "$HERMES_RECALL_STATE" != "clear" ]; then
    warn "The edit landed but the scope still does not read as memory-free."
    return 1
  fi
  ok "Hermes's API-server scope re-checked — no memory or session-search tools left in it."
  restart_hermes_for_config || {
    warn "Hermes was not restarted, so it is still running with its old scope."
    return 1
  }
  return 0
}

# The gate a caller can act on. Returns 0 only when this Hermes API server is
# provably free of its own recall. Deciding what a nonzero result MEANS — stop
# before pairing, or carry on with the warning — stays with the caller: refusing
# to pair a gateway that chats fine is a product call, not a parser's.
# --dry-run and --reuse-only report and return 0 by design; neither may block a
# run whose whole promise is that it changes nothing.
hermes_recall_scope_step() { # hermes_recall_scope_step [suggested-list]
  [ "${GW_KIND:-}" = "hermes" ] || return 0
  local cfg="$HOME/.hermes/config.yaml"
  hermes_recall_read "$cfg"
  hermes_recall_report
  [ "$HERMES_RECALL_STATE" = "clear" ] && return 0
  if $DRY_RUN; then
    note "(dry-run: a real run offers to remove those entries, or shows you the exact edit)"
    hermes_recall_manual_hint "${1:-[web]}"
    return 0
  fi
  if $REUSE_ONLY; then
    warn "(reuse-only: not changing Hermes config)"
    hermes_recall_manual_hint "${1:-[web]}"
    return 0
  fi
  if [ "$HERMES_RECALL_FIX" = "literal" ] && ! $HERMES_RECALL_DECLINED \
     && hermes_recall_remove_step "$cfg"; then
    return 0
  fi
  hermes_recall_manual_hint "${1:-[web]}"
  return 1
}

hermes_file_readiness_step() { # hermes_file_readiness_step <workspace>
  local workspace="$1" cfg="$HOME/.hermes/config.yaml"
  local status approved_scope=""
  hermes_analysis_read "$cfg" "$workspace" analyze
  status="$HERMES_ANALYSIS_STATUS"

  # The memory question comes before the file question, and gets its own answer:
  # it decides what this file's single edit contains, and it matters just as much
  # to a user who ends up declining the optional file lane.
  hermes_recall_report
  if [ "$HERMES_RECALL_STATE" != "clear" ]; then
    if [ "$HERMES_RECALL_FIX" != "literal" ] || $DRY_RUN || $REUSE_ONLY \
       || $HERMES_RECALL_DECLINED; then
      hermes_recall_manual_hint "[web, file]"
    elif [ "$status" = "fix" ] || [ "$status" = "ready" ]; then
      say ""
      say "  ${BOLD}platform_toolsets.api_server: $HERMES_RECALL_SCOPE -> $HERMES_RECALL_AFTER${RESET}"
      say "  Only that one list changes. Every other toolset in it stays, and Hermes's other"
      say "  surfaces are untouched — but anything else talking to this same API server loses"
      say "  its memory too."
      if confirm "  Remove Hermes's recall tools from its API-server scope?"; then
        approved_scope="$HERMES_RECALL_SCOPE"
        # Re-read with the approval folded in, so the operator sees ONE
        # before→after for this file rather than two overlapping ones.
        hermes_analysis_read "$cfg" "$workspace" analyze "$approved_scope"
        status="$HERMES_ANALYSIS_STATUS"
      else
        note "Leaving the API-server scope as it is."
        HERMES_RECALL_DECLINED=true
        hermes_recall_manual_hint "[web, file]"
      fi
    else
      # File readiness is already unprovable here, but the memory scope is a
      # different question about the same one line, and it decides how chat
      # behaves whether or not file transfer goes ahead. Offer it on its own.
      if hermes_recall_remove_step "$cfg"; then
        hermes_analysis_read "$cfg" "$workspace" analyze
        status="$HERMES_ANALYSIS_STATUS"
      else
        hermes_recall_manual_hint "[web, file]"
      fi
    fi
  fi

  say ""
  say "  ${BOLD}Hermes file readiness${RESET} — can the API-server agent use this exact folder?"
  case "$status" in
    ready)
      ok "Hermes config is file-lane-ready (${HERMES_ANALYSIS_REASONS[0]:-working root and file tools})."
      return 0 ;;
    manual|"")
      warn "I cannot prove a safe Hermes file configuration:"
      local r; for r in ${HERMES_ANALYSIS_REASONS[@]+"${HERMES_ANALYSIS_REASONS[@]}"}; do say "    $r"; done
      warn "I will leave file transfer out rather than broaden Hermes privileges or guess at a remote/sandbox mount."
      return 1 ;;
    fix) ;;
    *)
      warn "Unexpected Hermes readiness result '$status' — leaving file transfer out."
      return 1 ;;
  esac

  if [ -n "$approved_scope" ]; then
    warn "So here is the whole edit to Hermes's config, in one place:"
  else
    warn "Hermes needs these narrow changes before its API-server agent can use the lane:"
  fi
  local c; for c in "${HERMES_ANALYSIS_CHANGES[@]}"; do say "    ${BOLD}$c${RESET}"; done
  say "  Only the API-server's toolset list and this working-folder path are in scope;"
  say "  no terminal, web, or messaging-platform permissions are added, and nothing but"
  say "  the entries shown above is taken away."
  if $DRY_RUN; then
    for c in "${HERMES_ANALYSIS_CHANGES[@]}"; do plan_add "EDIT $cfg — $c"; done
    note "(dry-run: a real run asks before editing Hermes config)"
    return 0
  fi
  if $REUSE_ONLY; then
    warn "(reuse-only: not changing Hermes config; leaving the file lane out)"
    return 1
  fi
  if ! confirm "  Apply exactly these Hermes changes?"; then
    note "Leaving the file lane out — chat is unaffected."
    if [ -n "$approved_scope" ]; then
      note "The API-server scope is unchanged too; nothing in this file was touched."
    fi
    return 1
  fi
  mutate_guard "edit only terminal.cwd / platform_toolsets.api_server in $cfg" || return 1
  status=$(hermes_config_analysis "$cfg" "$workspace" apply ${approved_scope:+"$approved_scope"} \
    | awk -F '\t' '$1=="status"{print $2; exit}')
  if [ "$status" != "applied" ]; then
    warn "The Hermes config edit could not be applied safely — leaving the file lane out."
    return 1
  fi
  HERMES_CONFIG_CHANGED_THIS_RUN=true
  if [ -n "$approved_scope" ]; then HERMES_SCOPE_CHANGED_THIS_RUN=true; fi
  hermes_analysis_read "$cfg" "$workspace" analyze
  status="$HERMES_ANALYSIS_STATUS"
  if [ "$status" != "ready" ]; then
    warn "Hermes config did not re-check as file-ready — leaving the file lane out."
    return 1
  fi
  if [ -n "$approved_scope" ] && [ "$HERMES_RECALL_STATE" != "clear" ]; then
    warn "The recall entries were removed but the scope still does not read as memory-free."
    hermes_recall_manual_hint "[web, file]"
  fi
  ok "Hermes config re-checked — file toolset + working folder are aligned."
  if ! restart_hermes_for_config; then
    warn "Hermes was not restarted, so the file change is not active — leaving the lane out."
    return 1
  fi
  return 0
}

hermes_guidance_target() { # hermes_guidance_target <workspace>
  local ws="$1"
  [ -e "$ws/.hermes.md" ] && { printf '%s' "$ws/.hermes.md"; return 0; }
  [ -e "$ws/HERMES.md" ] && { printf '%s' "$ws/HERMES.md"; return 0; }
  # Hermes gives .hermes.md/HERMES.md priority over other project context.
  # Creating one beside an existing AGENTS.md/CLAUDE.md/.cursorrules would
  # silently stop that lower-priority file from loading, so refuse rather than
  # change unrelated agent behavior.
  if [ -e "$ws/AGENTS.md" ] || [ -e "$ws/CLAUDE.md" ] || [ -e "$ws/.cursorrules" ]; then
    return 1
  fi
  printf '%s' "$ws/HERMES.md"
}

hermes_guidance_edit() { # hermes_guidance_edit <target> <check|apply>
  python3 - "$1" "$2" <<'PY'
import os, sys
target, action = sys.argv[1:3]
BEGIN = "<!-- conduck-connect:begin -->"
END = "<!-- conduck-connect:end -->"
block = BEGIN + """
## Conduck chat attachments (managed by conduck-connect)

These rules apply only when a user message contains `[Conduck file transfer]`.

- The exact uploaded path named in the message is already under this working directory. Use `read_file` on that path; never search the web for an attached file.
- To return a file, finish writing it at the working-directory root before replying, then state its exact filename in plain reply text.
- Do not use `MEDIA:` or another channel attachment directive for a Conduck turn; the OpenAI-compatible response does not deliver those directives to Conduck.
""" + END
if os.path.islink(target):
    print("symlink"); sys.exit(0)
try:
    old = open(target, encoding="utf-8").read() if os.path.exists(target) else ""
except Exception:
    print("unreadable"); sys.exit(0)
nb, ne = old.count(BEGIN), old.count(END)
if nb == 1 and ne == 1 and old.index(BEGIN) < old.index(END):
    managed = old[old.index(BEGIN):old.index(END)+len(END)]
    if managed == block:
        print("ready"); sys.exit(0)
    state = "stale"
elif nb == 0 and ne == 0:
    state = "missing"
else:
    print("malformed"); sys.exit(0)
if action == "check":
    print(state); sys.exit(0)
if state == "missing":
    new = old.rstrip("\n") + ("\n\n" if old.strip() else "") + block + "\n"
else:
    new = old[:old.index(BEGIN)] + block + old[old.index(END)+len(END):]
try:
    os.makedirs(os.path.dirname(target), exist_ok=True)
    mode = os.stat(target).st_mode & 0o777 if os.path.exists(target) else 0o644
    tmp = target + ".conduck-tmp-%d" % os.getpid()
    fd = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY, mode)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(new); f.flush(); os.fsync(f.fileno())
    os.replace(tmp, target)
except Exception:
    try: os.unlink(tmp)
    except Exception: pass
    print("failed"); sys.exit(0)
print("applied")
PY
}

install_conduck_hermes_block() { # install_conduck_hermes_block <workspace>
  local ws="$1" target state
  [ -n "$ws" ] || { warn "Hermes shared folder is unknown — cannot install or prove its file guidance."; return 1; }
  if ! target=$(hermes_guidance_target "$ws"); then
    warn "This folder already has AGENTS.md, CLAUDE.md, or .cursorrules but no Hermes-specific context file."
    warn "Creating HERMES.md would override that context in Hermes, so I will not guess; leaving the file lane out."
    return 1
  fi
  state=$(hermes_guidance_edit "$target" check)
  case "$state" in
    ready)
      ok "Hermes's Conduck file guidance is present in $target."
      return 0 ;;
    missing|stale) ;;
    symlink|malformed|unreadable)
      warn "$target is $state — refusing to edit or replace it; leaving the file lane out."
      return 1 ;;
    *)
      warn "Could not inspect Hermes file guidance safely — leaving the file lane out."
      return 1 ;;
  esac
  say ""
  say "  Hermes loads project instructions from ${BOLD}${target##*/}${RESET}. I can install a"
  say "  marker-delimited Conduck block: open the exact uploaded path with read_file;"
  say "  finish output writes before replying; name returned files in plain reply text."
  if $DRY_RUN; then
    plan_add "INSTALL/refresh the Conduck agent-guidance block in $target (marker-delimited)"
    note "(dry-run: a real run asks before editing the guidance file)"
    return 0
  fi
  if $REUSE_ONLY; then
    warn "(reuse-only: guidance is absent/stale and cannot be changed; leaving the file lane out)"
    return 1
  fi
  if ! confirm "  Install/refresh that Hermes guidance block?"; then
    note "Leaving the file lane out — chat is unaffected."
    return 1
  fi
  mutate_guard "install the marker-delimited Conduck block in $target" || return 1
  state=$(hermes_guidance_edit "$target" apply)
  if [ "$state" = "applied" ]; then
    HERMES_GUIDANCE_CHANGED_THIS_RUN=true
    HERMES_GUIDANCE_TARGET_THIS_RUN="$target"
  fi
  if [ "$state" != "applied" ] || [ "$(hermes_guidance_edit "$target" check)" != "ready" ]; then
    warn "Could not install and re-check Hermes's guidance — leaving the file lane out."
    return 1
  fi
  ok "Conduck agent-guidance block installed in $target."
  return 0
}

AGENT_FILE_PROBE_REASON=""
AGENT_PROBE_ACTIVE=false
AGENT_PROBE_TAG=""
AGENT_PROBE_DIRKEY=""
AGENT_PROBE_INPUTKEY=""
AGENT_PROBE_OUTPUTKEY=""
AGENT_PROBE_TMP=""
AGENT_PROBE_OUTTMP=""
AGENT_PROBE_FS_URL=""
AGENT_PROBE_FS_CRED=""
AGENT_PROBE_FS_FOLDER=""
AGENT_PROBE_DIR_ARMED=false
AGENT_PROBE_INPUT_ARMED=false
AGENT_PROBE_OUTPUT_ARMED=false
AGENT_PROBE_DIR_VERIFY_METHOD=""
AGENT_PROBE_LATE_RISK=false

agent_probe_now_ms() {
  python3 -c 'import time; print(int(time.monotonic() * 1000))' 2>/dev/null
}

agent_probe_ms_seconds() { # agent_probe_ms_seconds <milliseconds>
  case "$1" in 0|[1-9][0-9]*) ;; *) return 1 ;; esac
  printf '%d.%03d' "$(($1 / 1000))" "$(($1 % 1000))"
}

agent_file_chat_eval() { # dedicated five-minute sentinel turn
  local max_time="${CONDUCK_AGENT_CHAT_TIMEOUT_SECONDS:-300}"
  case "$max_time" in 0|[1-9][0-9]*) ;; *) max_time=300 ;; esac
  [ "$max_time" -ge 31 ] 2>/dev/null && [ "$max_time" -le 1800 ] 2>/dev/null \
    || max_time=300
  CCE_REASON=""; CCE_LEN=""; CCE_TOKEN=""; CCE_WIRE_CODE=""
  if ! doctor_chat_request "$1" "$max_time"; then
    CCE_REASON="transfer failed (timed out or the connection dropped)"; return 1
  fi
  app_chat_loaded_eval "-"
}

# Mirror FileTransferOutputDetector.extractCandidates: safe filename token,
# extension allowlist, first-occurrence dedupe, inbound-name exclusion, then
# the app's five-candidate cap. The sentinel output must be one exact candidate;
# merely containing its bytes inside a longer token is not discoverable.
agent_reply_names_output() { # agent_reply_names_output <reply> <outputkey> <inputkey>
  printf '%s' "$1" | python3 -c '
import re, sys
target, inbound_key = sys.argv[1:3]
reply = sys.stdin.read()
allow = {"pdf","csv","tsv","json","xml","yaml","yml","txt","md","log","zip","tar","gz",
         "png","jpg","jpeg","gif","svg","xlsx","xls","docx","doc","pptx","html",
         "py","js","ts","sh","sql","parquet"}
seen, ordered = set(), []
for token in re.findall(r"[A-Za-z0-9._-]+\.[A-Za-z0-9]{1,8}", reply):
    ext = token.rsplit(".", 1)[1].lower()
    if ext in allow and token not in seen:
        seen.add(token)
        ordered.append(token)
inbound = {inbound_key, inbound_key.rsplit("/", 1)[-1]}
candidates = [token for token in ordered if token not in inbound][:5]
sys.exit(0 if target in candidates else 1)' "$2" "$3" >/dev/null 2>&1
}

agent_output_local_snapshot() { # <known-root> <exact-output-key> <expected-file>
  python3 - "$1" "$2" "$3" <<'PY' >/dev/null 2>&1
import os, re, stat, sys
root, key, expected = sys.argv[1:4]
if not os.path.isabs(root) or not re.fullmatch(r"output-[0-9a-f]{16}\.txt", key):
    sys.exit(1)
root = os.path.realpath(root)
if not os.path.isdir(root):
    sys.exit(1)
path = os.path.join(root, key)
if os.path.dirname(os.path.realpath(path)) != root:
    sys.exit(1)
try:
    with open(expected, "rb") as fh:
        want = fh.read()
    before = os.lstat(path)
    if not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode):
        sys.exit(1)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    try:
        opened = os.fstat(fd)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            sys.exit(1)
        # The expected sentinel is connector-owned and tiny. Reject a
        # wrong-sized agent file before reading it, then perform one bounded
        # read so an exact-name giant file cannot consume connector memory.
        if not stat.S_ISREG(opened.st_mode) or opened.st_size != len(want):
            sys.exit(1)
        got = os.read(fd, len(want) + 1)
        after = os.fstat(fd)
    finally:
        os.close(fd)
    final_path = os.lstat(path)
except Exception:
    sys.exit(1)
stable = (
    (after.st_dev, after.st_ino) == (opened.st_dev, opened.st_ino) ==
    (final_path.st_dev, final_path.st_ino) and
    stat.S_ISREG(final_path.st_mode) and not stat.S_ISLNK(final_path.st_mode) and
    after.st_size == final_path.st_size == len(want)
)
sys.exit(0 if stable and got == want else 1)
PY
}

agent_probe_registered_names_safe() {
  local nested="conduck-connect-agent-$AGENT_PROBE_TAG/input-$AGENT_PROBE_TAG.txt"
  local flat="conduck-connect-agent-$AGENT_PROBE_TAG-input.txt"
  case "$AGENT_PROBE_TAG" in ''|*[!a-f0-9]*) return 1 ;; esac
  [ "${#AGENT_PROBE_TAG}" -eq 16 ] || return 1
  [ "$AGENT_PROBE_OUTPUTKEY" = "output-$AGENT_PROBE_TAG.txt" ] || return 1
  [ "$AGENT_PROBE_DIRKEY" = "conduck-connect-agent-$AGENT_PROBE_TAG" ] || return 1
  case "$AGENT_PROBE_DIR_VERIFY_METHOD" in ""|propfind|get) ;; *) return 1 ;; esac
  [ "$AGENT_PROBE_INPUTKEY" = "$nested" ] || [ "$AGENT_PROBE_INPUTKEY" = "$flat" ]
}

agent_probe_cleanup_file() { # agent_probe_cleanup_file <exact-key>
  local key="$1" code verify
  code=$(curl_fs_with_timeout 1 -X DELETE -o /dev/null -w '%{http_code}' \
    "$FS_URL/$key" 2>/dev/null || true)
  case "$code" in 2??|404) ;; *) return 1 ;; esac
  verify=$(curl_fs_with_timeout 1 -o /dev/null -w '%{http_code}' \
    "$FS_URL/$key" 2>/dev/null || true)
  [ "$verify" = "404" ]
}

agent_probe_directory_absent() {
  local code
  case "$AGENT_PROBE_DIR_VERIFY_METHOD" in
    propfind)
      code=$(curl_fs_with_timeout 1 -X PROPFIND -H 'Depth: 0' \
        -o /dev/null -w '%{http_code}' "$FS_URL/$AGENT_PROBE_DIRKEY/" \
        2>/dev/null || true)
      ;;
    get)
      code=$(curl_fs_with_timeout 1 -o /dev/null -w '%{http_code}' \
        "$FS_URL/$AGENT_PROBE_DIRKEY/" 2>/dev/null || true)
      ;;
    *)
      # An interrupt can arrive between MKCOL and capability discovery. Try the
      # WebDAV authority first, then the exact directory GET fallback; only an
      # explicit 404 is absence.
      code=$(curl_fs_with_timeout 1 -X PROPFIND -H 'Depth: 0' \
        -o /dev/null -w '%{http_code}' "$FS_URL/$AGENT_PROBE_DIRKEY/" \
        2>/dev/null || true)
      [ "$code" = "404" ] || {
        code=$(curl_fs_with_timeout 1 -o /dev/null -w '%{http_code}' \
          "$FS_URL/$AGENT_PROBE_DIRKEY/" 2>/dev/null || true)
      }
      ;;
  esac
  [ "$code" = "404" ]
}

# Exact-name cleanup for normal completion and EXIT/signal interruption. It
# snapshots the lane URL and credential at registration time, so a later
# fail-closed drop cannot turn cleanup into an unauthenticated no-op.
agent_file_probe_cleanup_backstop() { # [final:true]
  $AGENT_PROBE_ACTIVE || return 0
  local final="${1:-false}"
  local FS_URL="$AGENT_PROBE_FS_URL" FS_CRED="$AGENT_PROBE_FS_CRED"
  local clean=true code
  rm -f "$AGENT_PROBE_TMP" "$AGENT_PROBE_OUTTMP" 2>/dev/null || true
  if ! agent_probe_registered_names_safe; then
    warn "Agent sentinel cleanup registry was invalid; refusing any delete."
    return 1
  fi
  if $AGENT_PROBE_INPUT_ARMED; then
    agent_probe_cleanup_file "$AGENT_PROBE_INPUTKEY" || clean=false
  fi
  if $AGENT_PROBE_OUTPUT_ARMED; then
    agent_probe_cleanup_file "$AGENT_PROBE_OUTPUTKEY" || clean=false
  fi
  if $AGENT_PROBE_DIR_ARMED; then
    code=$(curl_fs_with_timeout 1 -X DELETE -o /dev/null -w '%{http_code}' \
      "$FS_URL/$AGENT_PROBE_DIRKEY/" 2>/dev/null || true)
    case "$code" in 2??|404) ;; *) clean=false ;; esac
    agent_probe_directory_absent || clean=false
  fi
  if $clean; then
    # A failed/timed-out chat can still have work running behind its returned
    # response. Normal cleanup proves the exact key absent now, but retains the
    # output-only registry so EXIT checks it once more. The final trap call
    # clears the registry after its last exact DELETE + 404 proof.
    if $AGENT_PROBE_LATE_RISK && [ "$final" != "true" ]; then
      AGENT_PROBE_DIR_ARMED=false
      AGENT_PROBE_INPUT_ARMED=false
      AGENT_PROBE_DIR_VERIFY_METHOD=""
      AGENT_PROBE_TMP=""; AGENT_PROBE_OUTTMP=""
      return 0
    fi
    if $AGENT_PROBE_LATE_RISK; then
      warn "Sentinel cleanup proves absence only at this moment; the failed, timed-out, cancelled, or reply-first agent turn may still have background work."
      warn "Recheck and remove this exact file later if it appears: ${AGENT_PROBE_FS_FOLDER:-<shared-root>}/$AGENT_PROBE_OUTPUTKEY"
    fi
    AGENT_PROBE_ACTIVE=false
    AGENT_PROBE_TAG=""; AGENT_PROBE_DIRKEY=""; AGENT_PROBE_INPUTKEY=""
    AGENT_PROBE_OUTPUTKEY=""; AGENT_PROBE_TMP=""; AGENT_PROBE_OUTTMP=""
    AGENT_PROBE_FS_URL=""; AGENT_PROBE_FS_CRED=""; AGENT_PROBE_FS_FOLDER=""
    AGENT_PROBE_DIR_ARMED=false; AGENT_PROBE_INPUT_ARMED=false
    AGENT_PROBE_OUTPUT_ARMED=false
    AGENT_PROBE_DIR_VERIFY_METHOD=""; AGENT_PROBE_LATE_RISK=false
    return 0
  fi
  warn "Sentinel cleanup was not proven; remove only these exact paths if present:"
  warn "$AGENT_PROBE_INPUTKEY and $AGENT_PROBE_OUTPUTKEY"
  $AGENT_PROBE_DIR_ARMED && warn "$AGENT_PROBE_DIRKEY/ (only after confirming it contains no unrelated files)"
  return 1
}

agent_probe_abandon_registry() { # no registered remote target was created
  rm -f "$AGENT_PROBE_TMP" "$AGENT_PROBE_OUTTMP" 2>/dev/null || true
  AGENT_PROBE_ACTIVE=false
  AGENT_PROBE_TAG=""; AGENT_PROBE_DIRKEY=""; AGENT_PROBE_INPUTKEY=""
  AGENT_PROBE_OUTPUTKEY=""; AGENT_PROBE_TMP=""; AGENT_PROBE_OUTTMP=""
  AGENT_PROBE_FS_URL=""; AGENT_PROBE_FS_CRED=""; AGENT_PROBE_FS_FOLDER=""
  AGENT_PROBE_DIR_ARMED=false; AGENT_PROBE_INPUT_ARMED=false
  AGENT_PROBE_OUTPUT_ARMED=false
  AGENT_PROBE_DIR_VERIFY_METHOD=""; AGENT_PROBE_LATE_RISK=false
}

agent_file_wait_for_output() { # agent_file_wait_for_output <expected> <download>
  local expected="$1" download="$2"
  local window="${CONDUCK_AGENT_OUTPUT_DEADLINE_MS:-5000}"
  local request_ms="${CONDUCK_AGENT_OUTPUT_REQUEST_TIMEOUT_MS:-750}"
  local start deadline now remaining call_ms max_time code sleep_ms
  case "$window" in 0|[1-9][0-9]*) ;; *) window=5000 ;; esac
  case "$request_ms" in 0|[1-9][0-9]*) ;; *) request_ms=750 ;; esac
  [ "$window" -ge 1 ] 2>/dev/null && [ "$window" -le 30000 ] 2>/dev/null || window=5000
  [ "$request_ms" -ge 50 ] 2>/dev/null && [ "$request_ms" -le 2000 ] 2>/dev/null || request_ms=750
  start=$(agent_probe_now_ms) || return 1
  deadline=$((start + window))
  while :; do
    now=$(agent_probe_now_ms) || return 1
    remaining=$((deadline - now))
    [ "$remaining" -gt 0 ] || return 1
    call_ms="$request_ms"; [ "$remaining" -lt "$call_ms" ] && call_ms="$remaining"
    max_time=$(agent_probe_ms_seconds "$call_ms")
    : > "$download"
    code=$(curl_fs_with_timeout "$max_time" -o "$download" -w '%{http_code}' \
      "$FS_URL/$AGENT_PROBE_OUTPUTKEY" 2>/dev/null || true)
    if [[ "$code" == 2?? ]] && cmp -s "$expected" "$download"; then
      return 0
    fi
    now=$(agent_probe_now_ms) || return 1
    remaining=$((deadline - now))
    [ "$remaining" -gt 0 ] || return 1
    sleep_ms=250; [ "$remaining" -lt "$sleep_ms" ] && sleep_ms="$remaining"
    sleep "$(agent_probe_ms_seconds "$sleep_ms")"
  done
}

agent_file_probe() {
  AGENT_FILE_PROBE_REASON=""
  if $AGENT_PROBE_ACTIVE && ! agent_file_probe_cleanup_backstop true; then
    AGENT_FILE_PROBE_REASON="a prior sentinel's exact cleanup is still unproven"
    return 1
  fi
  local tag secret dirkey inputkey outputkey tmp outtmp code content payload model reply
  local bytes_ok=false request_ms request_timeout
  local agent_name read_tool write_tool
  case "$GW_KIND" in
    openclaw)
      agent_name="OpenClaw"; read_tool="read"; write_tool="write" ;;
    hermes)
      agent_name="Hermes"; read_tool="read_file"; write_tool="write_file" ;;
    *)
      AGENT_FILE_PROBE_REASON="this gateway has no verified agent file-tool probe"
      return 1 ;;
  esac
  tag=$(python3 -c 'import secrets; print(secrets.token_hex(8))' 2>/dev/null) || {
    AGENT_FILE_PROBE_REASON="could not generate a sentinel nonce"; return 1; }
  secret=$(python3 -c 'import secrets; print(secrets.token_hex(24))' 2>/dev/null) || {
    AGENT_FILE_PROBE_REASON="could not generate sentinel content"; return 1; }
  dirkey="conduck-connect-agent-$tag"
  inputkey="$dirkey/input-$tag.txt"
  outputkey="output-$tag.txt"
  # The content nonce is independent of every name carried in the prompt. A
  # tool-less model can see the randomized path, but cannot derive these bytes
  # from it and synthesize a passing output without reading the input file.
  content="CONDUCK-AGENT-FILE-SENTINEL-$secret"
  tmp=$(mktemp "${TMPDIR:-/tmp}/conduck-agent-probe.XXXXXX" 2>/dev/null) || {
    AGENT_FILE_PROBE_REASON="could not stage the sentinel"; return 1; }
  outtmp=$(mktemp "${TMPDIR:-/tmp}/conduck-agent-output.XXXXXX" 2>/dev/null) || {
    rm -f "$tmp"
    AGENT_FILE_PROBE_REASON="could not stage the sentinel download"; return 1; }
  printf '%s\n' "$content" > "$tmp"

  # Register every exact remote/local target before the first request can
  # create it. The EXIT trap uses this snapshot even if later code drops the
  # optional file lane from the pairing state.
  AGENT_PROBE_TAG="$tag"
  AGENT_PROBE_DIRKEY="$dirkey"
  AGENT_PROBE_INPUTKEY="$inputkey"
  AGENT_PROBE_OUTPUTKEY="$outputkey"
  AGENT_PROBE_TMP="$tmp"
  AGENT_PROBE_OUTTMP="$outtmp"
  AGENT_PROBE_FS_URL="$FS_URL"
  AGENT_PROBE_FS_CRED="$FS_CRED"
  AGENT_PROBE_FS_FOLDER="$FS_FOLDER"
  AGENT_PROBE_DIR_ARMED=false
  AGENT_PROBE_INPUT_ARMED=false
  AGENT_PROBE_OUTPUT_ARMED=false
  AGENT_PROBE_DIR_VERIFY_METHOD=""
  AGENT_PROBE_LATE_RISK=false
  AGENT_PROBE_ACTIVE=true

  # Prove the randomized output name is free before the agent turn. A stale
  # output must never let a tool-less model earn a pass.
  request_ms="${CONDUCK_AGENT_OUTPUT_REQUEST_TIMEOUT_MS:-750}"
  case "$request_ms" in 0|[1-9][0-9]*) ;; *) request_ms=750 ;; esac
  [ "$request_ms" -ge 50 ] 2>/dev/null && [ "$request_ms" -le 2000 ] 2>/dev/null \
    || request_ms=750
  request_timeout=$(agent_probe_ms_seconds "$request_ms")
  code=$(curl_fs_with_timeout "$request_timeout" -o /dev/null -w '%{http_code}' \
    "$FS_URL/$outputkey" 2>/dev/null || true)
  case "$code" in 404) ;; *)
    AGENT_FILE_PROBE_REASON="the randomized output name was not provably free (HTTP ${code:-000})"
    agent_probe_abandon_registry
    return 1 ;;
  esac
  AGENT_PROBE_OUTPUT_ARMED=true

  # Match the app's nested-folder shape when MKCOL is available; rclone supports
  # it. A flat fallback preserves compatibility with manually supplied WebDAV.
  code=$(curl_fs -X MKCOL -o /dev/null -w '%{http_code}' "$FS_URL/$dirkey/" 2>/dev/null || true)
  case "$code" in 2??)
    AGENT_PROBE_DIR_ARMED=true
    code=$(curl_fs_with_timeout 1 -X PROPFIND -H 'Depth: 0' \
      -o /dev/null -w '%{http_code}' "$FS_URL/$dirkey/" 2>/dev/null || true)
    case "$code" in
      2??) AGENT_PROBE_DIR_VERIFY_METHOD="propfind" ;;
      *)
        code=$(curl_fs_with_timeout 1 -o /dev/null -w '%{http_code}' \
          "$FS_URL/$dirkey/" 2>/dev/null || true)
        case "$code" in
          2??) AGENT_PROBE_DIR_VERIFY_METHOD="get" ;;
          *)
            AGENT_FILE_PROBE_REASON="the temporary WebDAV directory could not be observed for cleanup proof"
            agent_file_probe_cleanup_backstop || true
            return 1 ;;
        esac ;;
    esac
    ;;
    *)
      inputkey="conduck-connect-agent-$tag-input.txt"
      AGENT_PROBE_INPUTKEY="$inputkey"
      dirkey="" ;;
  esac
  AGENT_PROBE_INPUT_ARMED=true
  code=$(curl_fs -T "$tmp" -o /dev/null -w '%{http_code}' "$FS_URL/$inputkey" 2>/dev/null || true)
  case "$code" in 2??) ;;
    *)
      AGENT_FILE_PROBE_REASON="could not place the agent sentinel through WebDAV (HTTP ${code:-000})"
      agent_file_probe_cleanup_backstop || true
      return 1 ;;
  esac

  # Match the app/setup request exactly: Hermes normally chooses its configured
  # default when no custom model was entered. Do not substitute the first
  # advertised model here; it could be a non-agent/tool-less model and would
  # manufacture a file-lane failure the app itself would never encounter.
  model="${GW_MODEL:-}"
  payload=$(AF_MODEL="$model" AF_INPUT="$inputkey" AF_OUTPUT="$outputkey" \
    AF_READ="$read_tool" AF_WRITE="$write_tool" python3 - <<'PY' 2>/dev/null
import json, os
e = os.environ
task = (
    "Use %s to read the exact uploaded file path listed below. Use %s "
    "to copy its bytes unchanged into a new file named %s at the ROOT of your working "
    "directory. Finish the write before replying. Do not reconstruct or guess the "
    "file contents. Then reply with one short sentence containing the exact output "
    "filename." % (e["AF_READ"], e["AF_WRITE"], e["AF_OUTPUT"]))
ref = (
    "The following file(s) are in your working directory — use them for this request. "
    "Each input lives under its conversation folder at the path shown:\n"
    "- input.txt (saved as %s)" % e["AF_INPUT"])
instr = (
    "[Conduck file transfer] To return a file, write it to the root of your working "
    "directory and state its exact filename in plain text in your reply. Attachment "
    "directives (MEDIA: lines or similar) do not reach this user — only files named "
    "in plain reply text are delivered.")
p = {"messages": [{"role": "user", "content": task + "\n\n" + ref + "\n\n" + instr}],
     "stream": False}
if e["AF_MODEL"]:
    p["model"] = e["AF_MODEL"]
print(json.dumps(p))
PY
  )
  if [ -z "$payload" ]; then
    AGENT_FILE_PROBE_REASON="could not build the agent sentinel request"
  else
    AGENT_PROBE_LATE_RISK=true
    if ! agent_file_chat_eval "$payload"; then
      AGENT_FILE_PROBE_REASON="the $agent_name file turn failed: $CCE_REASON"
    elif ! agent_output_local_snapshot "$FS_FOLDER" "$outputkey" "$tmp"; then
      AGENT_FILE_PROBE_REASON="$agent_name replied before a byte-identical regular output file existed in the guarded shared root"
      # This is cleanup-only. A later file can never turn the result green, but
      # watching the exact key for the existing five-second window lets us remove
      # common reply-first/background writes before returning.
      agent_file_wait_for_output "$tmp" "$outtmp" || true
    else
      AGENT_PROBE_LATE_RISK=false
      reply=$(printf '%s' "$DCC_BODY" | python3 -c '
import json, sys
try: print(json.load(sys.stdin)["choices"][0]["message"]["content"])
except Exception: pass' 2>/dev/null)
      # rclone's 1-second directory cache may still hold the deliberate pre-turn
      # 404 when the agent writes directly to disk. Creation is already proven
      # at the reply boundary above; these retries can prove visibility only.
      agent_file_wait_for_output "$tmp" "$outtmp" && bytes_ok=true
      if ! $bytes_ok; then
        AGENT_FILE_PROBE_REASON="$agent_name created the output before replying, but it did not become byte-identically visible through WebDAV within five seconds"
      elif ! agent_reply_names_output "$reply" "$outputkey" "$inputkey"; then
        AGENT_FILE_PROBE_REASON="the output bytes were correct, but the reply did not name the randomized output file for Conduck to discover"
      fi
    fi
  fi

  # Exact nonce names only. A successful DELETE is not proof: follow each file
  # delete with an authenticated GET that must answer 404.
  if ! agent_file_probe_cleanup_backstop; then
    [ -n "$AGENT_FILE_PROBE_REASON" ] || AGENT_FILE_PROBE_REASON="sentinel cleanup could not be proven"
    return 1
  fi
  [ -z "$AGENT_FILE_PROBE_REASON" ]
}
# ---------------------------------------------------------- verification phase --

VERIFY_FAILED=false

# A file lane that a CHECK dropped, not one the operator declined. The service keeps
# running and a saved profile still records it, so write_profile reads this to leave a
# good profile alone rather than turning one transient probe failure into a permanent
# deletion of a working lane.
FS_LANE_DROPPED_BY_CHECK=false

check() { # check "label" <command...>  (command's exit code decides)
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; VERIFY_FAILED=true; return 1; fi
}

# curl wrapper: normal TLS validation, with no exceptions and no override — the
# same trust every setup path already had to clear, so verification proves the
# route the app will actually take.
# The bearer token rides a stdin curl config, never argv (argv shows in `ps`).
curl_gw() { # curl_gw <curl args…>
  local extra=()
  # `-q` MUST be curl's first arg. Every connector request ignores curl config,
  # so a stray `proxy`/`output`/redirect/include line there can neither reroute
  # a secret nor make curl read/write files absent from our effects manifest.
  # Diagnostics additionally refuse ALL proxy environment variables because
  # they promise "direct to the server you gave me, nothing else".
  if $DOCTOR || $COMPAT; then extra+=(--noproxy '*'); fi
  # ${extra[@]+…} guard: expanding an empty array under `set -u` is an error in bash 3.2.
  if [ "$GW_AUTH" = "bearer" ]; then
    credential_value_safe "$GW_TOKEN" || return 2
    local tok="$GW_TOKEN"; tok="${tok//\\/\\\\}"; tok="${tok//\"/\\\"}"   # curl-config quoting
    printf 'header = "Authorization: Bearer %s"\n' "$tok" \
      | curl -q -sS --max-time 30 --config - ${extra[@]+"${extra[@]}"} "$@"
  else
    curl -q -sS --max-time 30 ${extra[@]+"${extra[@]}"} "$@"
  fi
}

# Diagnostics from the LAST models_is_json call — verify_all turns these into a
# concrete sub-cause instead of one lossy "unreachable or rejected" bucket.
MODELS_CURL_RC=0        # curl exit code (0 = the transfer itself completed)
MODELS_HTTP_CODE=""     # HTTP status of the reply ("" when the transfer failed)
MODELS_DATA_EMPTY=false # 200 + canonical envelope, but "data" is [] (valid, yet can't answer)
MODELS_NO_VALID_ID=false # 200 + non-empty "data", but no entry has a usable string "id"
MODELS_TIME=""          # curl %{time_total} for the models request (seconds, e.g. "0.123")
MODELS_CONTENT_TYPE=""  # the reply's Content-Type header ("" when the transfer failed).
                        # Captured for the DOCTOR only — the wizard mirrors the app, which
                        # tolerates mislabelled third-party gateways, so nothing here may
                        # tighten the wizard's grading.
MODELS_ID_COUNT=0       # how many DISTINCT usable ids were advertised (doctor: model-selection).
                        # Distinct, not entries: the adapter contract grades a server that offers
                        # exactly one model by a different normative rule than a multi-model one
                        # (only the latter must answer an unknown id with 400 "model_not_found"),
                        # so counting a duplicated entry twice would silently move a single-model
                        # adapter into the stricter branch and fail it on a rule it is exempt from.
MODELS_FIRST_ID=""      # the first usable id ("" when none) — the doctor's selection probe target
MODELS_WANTED_FOUND=false # the optional 2nd argument's id was advertised. Membership, not the
                        # roster: a caller that lets the operator NAME the model to grade must be
                        # able to say "that id isn't in this server's list" without the script
                        # retaining hundreds of ids it has no other use for.

models_is_json() { # 1 arg: base URL — /v1/models must answer success + the canonical envelope
                   #   (JSON object with a top-level "data" ARRAY), not the Control-UI HTML.
                   #   Optional 2nd arg: an id to test for membership (MODELS_WANTED_FOUND).
                   # Return codes: 0 ok · 1 unreachable/rejected/non-JSON · 2 HTML · 3 wrong shape.
                   # Sets MODELS_CURL_RC / MODELS_HTTP_CODE / MODELS_DATA_EMPTY /
                   # MODELS_NO_VALID_ID / MODELS_TIME either way.
  local out statusline body wanted="${2:-}"
  MODELS_CURL_RC=0; MODELS_HTTP_CODE=""; MODELS_DATA_EMPTY=false; MODELS_NO_VALID_ID=false
  MODELS_TIME=""; MODELS_CONTENT_TYPE=""; MODELS_ID_COUNT=0; MODELS_FIRST_ID=""
  MODELS_WANTED_FOUND=false
  out=$(curl_gw -w '\n%{http_code} %{time_total} %{content_type}' \
        -H "Accept: application/json" "$1/v1/models" 2>/dev/null) || { MODELS_CURL_RC=$?; return 1; }
  # The -w line is "<code> <seconds> <content-type>"; the body is everything
  # before that last newline (the `-w` prefix `\n` guarantees the split even for
  # an empty body). Content-Type may itself contain spaces ("…; charset=utf-8"),
  # so it's split off LAST and keeps the remainder verbatim.
  statusline="${out##*$'\n'}"; body="${out%$'\n'*}"
  MODELS_HTTP_CODE="${statusline%% *}"; statusline="${statusline#* }"
  MODELS_TIME="${statusline%% *}"
  # safe_display here, at the parser's exit: the header is whatever the server
  # chose, it is echoed verbatim in the MODELS_ENVELOPE verdict, and curl does
  # not strip control bytes from a header value. A real Content-Type is far
  # inside the 200-char bound, so the grading in ct_is_json is unaffected.
  MODELS_CONTENT_TYPE=""
  [ "$statusline" != "${statusline#* }" ] && MODELS_CONTENT_TYPE=$(safe_display "${statusline#* }" 200)
  # HTML first: the endpoint-off page often comes back 200, and it deserves its
  # own diagnosis either way.
  case "$body" in *\<html*|*\<HTML*|*\<!DOCTYPE*) return 2 ;; esac
  # The Apple app accepts every 2xx response and then validates the body.
  # Adapter conformance deliberately stays stricter: the contract requires 200.
  # A 401/500 JSON error body is always a FAILURE, not "answers with JSON".
  if $DOCTOR; then
    [ "$MODELS_HTTP_CODE" = "200" ] || return 1
  else
    case "$MODELS_HTTP_CODE" in 2??) ;; *) return 1 ;; esac
  fi
  # Canonical envelope: the app's Test Connection needs a JSON OBJECT whose
  # top-level "data" is an ARRAY. A bare array, a {"models":…} shape, or "data"
  # that isn't a list parses as JSON but fails the app's stricter probe — flag
  # it as its own case (return 3) so verify_all can say so. An EMPTY array is
  # structurally valid (the app calls it "connected — no models yet") but can't
  # answer a chat, so it reports success + the MODELS_DATA_EMPTY warning flag.
  # A non-empty array whose entries carry no usable string "id" (e.g. [{}], [1],
  # [{"id":null}]) is the CONTRACT's failure — the app has to name a model, and
  # can't — so it's flagged MODELS_NO_VALID_ID (the doctor fails on it; the
  # wizard, which mirrors the app and doesn't inspect ids, returns 0 unchanged).
  # Python is the sole classifier (unparseable → 1): a shell first-byte test
  # would wrongly reject leading whitespace and misfile JSON scalars.
  # parse_constant: NaN/Infinity are REJECTED — python accepts them by default
  # but Apple Foundation's parsers do not, and the script must never be laxer
  # than the app it green-lights for.
  # On the envelope-OK paths the classifier also prints
  # "<id-count>\t<wanted-advertised>\t<first-id>" for the doctor's model-selection
  # probe; the wizard captures and ignores it. The membership answer is compared
  # against the RAW advertised id, before the control-byte strip below, so an id
  # the operator copied verbatim out of the server's own list still matches.
  # The id is stripped of C0 controls and DEL before it leaves the classifier —
  # TAB/CR/LF because they would break this tab-delimited line, the rest because
  # the id is printed in verdict lines a hostile gateway must not be able to
  # repaint (ANSI) or forge extra transcript lines into. It is NOT truncated
  # here: the same value becomes the chat payload's model and the paired
  # profile's model, where a long-but-legitimate id must survive intact.
  local pyout prc
  pyout=$(printf '%s' "$body" | MODELS_WANTED_ID="$wanted" python3 -c '
import json, os, sys
def bad(x): raise ValueError(x)
try:
    d = json.load(sys.stdin, parse_constant=bad)
except Exception:
    sys.exit(1)
if not (isinstance(d, dict) and isinstance(d.get("data"), list)):
    sys.exit(3)
data = d["data"]
seen = set()
ids = []
for x in data:
    if not (isinstance(x, dict) and isinstance(x.get("id"), str) and x["id"]):
        continue
    if x["id"] in seen:
        continue
    seen.add(x["id"])
    ids.append(x["id"])
want = os.environ.get("MODELS_WANTED_ID", "")
found = "yes" if (want and want in ids) else "no"
first = "".join(" " if (ord(c) < 0x20 or ord(c) == 0x7f) else c for c in (ids[0] if ids else ""))
print("%d\t%s\t%s" % (len(ids), found, first))
if not data:
    sys.exit(4)
sys.exit(0 if ids else 5)' 2>/dev/null)
  prc=$?
  case "$pyout" in
    *$'\t'*$'\t'*)
      MODELS_ID_COUNT="${pyout%%$'\t'*}"
      local rest="${pyout#*$'\t'}"
      [ "${rest%%$'\t'*}" = "yes" ] && MODELS_WANTED_FOUND=true
      MODELS_FIRST_ID="${rest#*$'\t'}"
      ;;
  esac
  case "$MODELS_ID_COUNT" in ''|*[!0-9]*) MODELS_ID_COUNT=0 ;; esac
  case "$prc" in
    0) return 0 ;;
    4) MODELS_DATA_EMPTY=true; return 0 ;;
    5) MODELS_NO_VALID_ID=true; return 0 ;;
    *) return "$prc" ;;
  esac
}

# The FILE lane's curl — normal TLS validation, same single rule as curl_gw.
# The credential rides a stdin curl config, never argv (argv shows in `ps`).
curl_fs_with_timeout() { # curl_fs_with_timeout <max-seconds> <curl args…>
  local max_time="$1"; shift
  credential_value_safe "$FS_CRED" || return 2
  local cred="$FS_CRED"; cred="${cred//\\/\\\\}"; cred="${cred//\"/\\\"}"   # curl-config quoting
  printf 'user = "conduck:%s"\n' "$cred" \
    | curl -q -sS --max-time "$max_time" --config - "$@"
}
curl_fs() { curl_fs_with_timeout 30 "$@"; }

# Loopback-only health probe — every caller passes http://127.0.0.1:… .
# `--noproxy '*'` for the same reason curl_gw's diagnostics carry it: curl has no
# loopback exemption, so with $http_proxy/$ALL_PROXY set this request goes to
# that host instead, and a proxy answering 200 forges precisely the "your gateway
# is up" verdict this function exists to establish.
local_health_ok() { # local_health_ok <url> -> 0 when the server answered with < 500
  local code
  code=$(curl -q -sS --max-time 10 --noproxy '*' -o /dev/null -w '%{http_code}' "$1" 2>/dev/null) || return 1
  case "$code" in ''|000) return 1 ;; 5??) return 1 ;; *) return 0 ;; esac
}

# Name a MOVED ADDRESS as its own cause, on the two transports whose live exposure this
# script cannot introspect. The HTTP-code map alone reads as a server fault, and here that
# is usually the wrong culprit: Cloudflare answers 530 for a hostname with no tunnel
# behind it, and the `*.trycloudflare.com` address `cloudflared tunnel --url` prints is a
# DIFFERENT one after every tunnel restart — so a saved URL stops reaching this machine
# while the gateway itself never moved. Tailscale needs none of this: its live mapping is
# asserted directly, before verification runs.
# The comparison made here is the one that is available: probe the gateway on loopback.
# Answering locally while the address does not reach it IS the drift, and it separates
# "reconcile the address" from "start the gateway" instead of blaming the server for both.
gw_url_drift_note() { # reads TRANSPORT / GW_LOCAL_PORT / MODELS_CURL_RC / MODELS_HTTP_CODE
  case "$TRANSPORT" in cloudflare|public) ;; *) return 0 ;; esac
  # Only failures where the request never reached the gateway. A rejected token, an HTML
  # login page and a wrong envelope all prove it DID arrive, and calling those a moved
  # address sends the operator after a fix that changes nothing.
  if [ "$MODELS_CURL_RC" != "0" ]; then
    case "$MODELS_CURL_RC" in
      6|7) ;;               # the hostname is gone; or nothing listens at that address
      *)   return 0 ;;
    esac
  else
    case "$MODELS_HTTP_CODE" in
      # 530: nothing serves that hostname. 502/503/504: an HTTPS front answered, so the
      # address is wired to something — and what it forwards to is what did not answer.
      # Both mean the gateway never saw the request, which is what the probe below tests.
      530|502|503|504) ;;
      *) return 0 ;;
    esac
  fi
  if [ -z "$GW_LOCAL_PORT" ]; then
    note "No local port is recorded for this gateway, so I can't tell a moved address from a stopped gateway."
    note "Check the gateway is running, then check that address still reaches this machine."
  elif local_health_ok "http://127.0.0.1:$GW_LOCAL_PORT${GW_HEALTH_PATH:-/v1/models}"; then
    warn "Your gateway IS answering on this machine (127.0.0.1:$GW_LOCAL_PORT)."
    warn "That address no longer reaches it, so the address moved — the gateway did not."
  else
    note "The gateway doesn't answer on 127.0.0.1:$GW_LOCAL_PORT either, so start it first — and if it is"
    note "already up, then that address no longer reaches this machine."
  fi
  case "$TRANSPORT" in
    cloudflare) note "Check the tunnel runs, its ingress rule still points at 127.0.0.1:${GW_LOCAL_PORT:-<your gateway port>}, and the DNS route for that hostname still exists." ;;
    public)     note "A *.trycloudflare.com quick tunnel prints a NEW address every time it restarts, so a saved one stops reaching this machine." ;;
  esac
  if $SHOW_QR; then
    note "Re-run setup to reconcile the saved address with the live one:  bash conduck-connect.sh --setup"
  else
    note "Read the address that is live now, then re-run me so the code carries that one."
  fi
}

agent_file_lane_gate() {
  local agent_name fix_hint
  case "$GW_KIND" in
    openclaw)
      agent_name="OpenClaw"
      fix_hint="OpenClaw's workspace/tool policy" ;;
    hermes)
      agent_name="Hermes"
      fix_hint="Hermes file tools/terminal.cwd" ;;
    *) return 0 ;;
  esac

  say "  Asking $agent_name to read and copy a randomized sentinel with its file tools (up to 5 minutes)…"
  if agent_file_probe; then
    ok "$agent_name agent file lane: tool read + byte-identical write + reply discovery all green"
    return 0
  fi

  bad "$agent_name agent file lane failed: $AGENT_FILE_PROBE_REASON"
  # A gateway-only code is a real offer only while the GATEWAY itself passed. Once any
  # gateway check has failed, emit_payload hands out no code at all — so asking here
  # would promise one and then exit 1 anyway, over a fault this file lane cannot fix.
  if $SHOW_QR && $VERIFY_FAILED; then
    note "The gateway checks above failed too, so no code is emitted either way — fix the gateway first, then re-run --show-code."
    FS_LANE_DROPPED_BY_CHECK=true
    drop_file_lane
    return 1
  fi
  if $SHOW_QR; then
    if confirm "Show a gateway-only code anyway? (your saved profile keeps its file lane)"; then
      FS_LANE_DROPPED_BY_CHECK=true
      drop_file_lane
      return 1
    fi
    die "Stopped before emitting a new code. Any separately approved host edits from this run remain in place; fix $fix_hint, then re-run --show-code."
  fi
  note "The WebDAV transport worked, but $agent_name itself did not complete the file turn."
  note "Leaving file transfer out of this setup code; fix $fix_hint, then re-run setup."
  hermes_residual_state_note
  FS_LANE_DROPPED_BY_CHECK=true
  drop_file_lane
  return 1
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

  # Public URL: model list must come back as JSON. On failure, name the concrete
  # sub-cause (models_is_json leaves it in MODELS_CURL_RC / MODELS_HTTP_CODE) —
  # a lone "unreachable or rejected" makes the user guess among seven problems.
  local rc=0 why=""; models_is_json "$GW_URL" || rc=$?
  if [ "$rc" = "0" ]; then
    ok "$GW_URL/v1/models answers with JSON"
    if $MODELS_DATA_EMPTY; then
      warn "…but its model list is EMPTY — the endpoint is real, yet with no models it can't answer."
      say  "    (pull/load a model on the server — or set the model name your gateway expects — then re-run me)"
    fi
  elif [ "$rc" = "2" ]; then
    # Hedged on purpose: the endpoint-off page is the LIKELY cause on the known
    # gateways, but a reverse-proxy login or access interstitial produces the
    # identical symptom — asserting "it's off" would send that user in circles.
    bad "$GW_URL/v1/models returned an HTML page instead of model data (HTTP ${MODELS_HTTP_CODE:-?})"
    case "$GW_KIND" in
      openclaw|hermes)
        say "    (most likely the chat endpoint is still off — re-run Step 2, then restart the gateway;"
        say "     a 401/403 status here usually means a login or access page in front answered instead)"
        ;;
      *)
        say "    (something answered with a web page — often a reverse proxy, a login/access page, or a"
        say "     wrong base address; check the URL and whatever sits in front of the server)"
        ;;
    esac
    VERIFY_FAILED=true
  elif [ "$rc" = "3" ]; then
    bad "$GW_URL/v1/models answers, but not with the required envelope"
    say  '    (must be JSON with a top-level "data" array — see conduck.com/setup/adapter/v1/)'
    VERIFY_FAILED=true
  else
    if [ "$MODELS_CURL_RC" != "0" ]; then
      case "$MODELS_CURL_RC" in
        6)     why="DNS lookup failed — that hostname doesn't resolve" ;;
        7)     why="connection refused — nothing is listening there (wrong port? firewall? server down?)" ;;
        28)    why="timed out — no answer from the host" ;;
        35)    why="TLS/certificate problem — the HTTPS front rejected the connection" ;;
        60)    why="TLS/certificate problem — this machine doesn't trust the server's certificate" ;;
        *)     why="transfer failed (curl exit $MODELS_CURL_RC)" ;;
      esac
    else
      case "$MODELS_HTTP_CODE" in
        401|403) why="HTTP $MODELS_HTTP_CODE — token rejected (or an access layer in front wants a login)" ;;
        3??)     why="HTTP $MODELS_HTTP_CODE redirect — enter the final gateway base URL directly (this tool does not forward credentials across redirects)" ;;
        404)     why="HTTP 404 — nothing at that path (wrong base address?)" ;;
        # 530 BEFORE the 5xx bucket, which would file it as a server fault. It is the
        # answer of an HTTPS front that has nothing to forward to: Cloudflare returns it
        # for a hostname whose tunnel is gone. The server behind it never saw the request.
        530)     why="HTTP 530 — the address answered, but nothing is serving that hostname (its tunnel is gone, or it moved)" ;;
        5??)     why="HTTP $MODELS_HTTP_CODE — the server errored" ;;
        2??)     why="answered HTTP $MODELS_HTTP_CODE, but the body isn't strict JSON" ;;
        *)       why="HTTP $MODELS_HTTP_CODE" ;;
      esac
    fi
    bad "$GW_URL/v1/models failed: $why"
    gw_url_drift_note
    VERIFY_FAILED=true
  fi

  # A real round-trip. Agents can be slow; give it time. Servers like
  # Ollama/vLLM/LiteLLM need the model named — include it exactly as the app will.
  say "  Asking the gateway for a one-word reply (can take a few minutes on modest hardware or a busy agent)…"
  local body
  # Build the JSON with a real encoder — a quote/backslash in a model name must
  # not silently break the request body.
  body=$(GW_MODEL="$GW_MODEL" python3 -c '
import json, os
p = {"messages": [{"role": "user", "content": "Reply with exactly: pong"}], "stream": False}
m = os.environ.get("GW_MODEL", "")
if m: p["model"] = m
print(json.dumps(p))') || die "Could not build the test request (python3 failed)."
  [ -n "$body" ] || die "Could not build the test request."
  # Use the SAME Apple-compatible evaluator as `--check-server`: every 2xx is a
  # success status, strict JSON is required, the whole Choice array decodes
  # eagerly, and an empty String is valid. Doctor keeps its separate, stricter
  # adapter-contract evaluator.
  if app_chat_eval "$body"; then
    ok "live round-trip: response decoded the way the Conduck app does (${CCE_LEN:-0} chars)"
  else
    bad "live round-trip failed ($CCE_REASON)"
    VERIFY_FAILED=true
  fi

  # File transport first. For known agent gateways, a second real agent turn
  # below is the launch gate: WebDAV plus static config inspection must never
  # produce an end-to-end green claim by themselves.
  if [ -n "$FS_URL" ] && [ -n "$FS_CRED" ]; then
    local probe="conduck-connect-probe-$$.txt" tmp transport_ok=false
    local delete_code="" gone_code=""
    tmp=$(mktemp); echo "probe" > "$tmp"
    if curl_fs -T "$tmp" "$FS_URL/$probe" >/dev/null 2>&1 \
       && [ "$(curl_fs "$FS_URL/$probe" 2>/dev/null)" = "probe" ]; then
      delete_code=$(curl_fs -X DELETE -o /dev/null -w '%{http_code}' \
        "$FS_URL/$probe" 2>/dev/null || true)
      gone_code=$(curl_fs -o /dev/null -w '%{http_code}' \
        "$FS_URL/$probe" 2>/dev/null || true)
      if [[ "$delete_code" == 2?? || "$delete_code" = "404" ]] \
         && [ "$gone_code" = "404" ]; then
        transport_ok=true
        ok "file transport: authenticated write → read → delete all green"
      else
        bad "file transport cleanup was not proven (DELETE HTTP ${delete_code:-000}; follow-up GET HTTP ${gone_code:-000})"
        warn "The exact probe $probe may remain. Leaving file transfer out of this setup code."
        FS_LANE_DROPPED_BY_CHECK=true
        drop_file_lane
      fi
    elif $SHOW_QR; then
      # --show-code never rewrites the saved profile (write_profile guards on $SHOW_QR),
      # so dropping the lane here only affects THIS emission — the saved lane is untouched.
      bad "the saved profile's file lane failed live verification — a transient outage or a real breakage."
      # A gateway-only code is a real offer only while the GATEWAY itself passed. Once any
      # gateway check has failed, emit_payload hands out no code at all, so asking would
      # promise one and then exit 1 — and naming the file server as the thing to fix points
      # at the wrong machine when the gateway is what died.
      if $VERIFY_FAILED; then
        note "The gateway checks above failed too, so no code is emitted either way — fix the gateway first, then re-run --show-code."
        curl_fs -X DELETE "$FS_URL/$probe" >/dev/null 2>&1 || true   # the PUT may have landed
        FS_LANE_DROPPED_BY_CHECK=true
        drop_file_lane
      elif confirm "Show a gateway-only code anyway? (your saved profile keeps its file lane)"; then
        curl_fs -X DELETE "$FS_URL/$probe" >/dev/null 2>&1 || true   # the PUT may have landed
        FS_LANE_DROPPED_BY_CHECK=true
        drop_file_lane
      else
        # Best-effort probe cleanup before dying: the PUT may have landed even though
        # the GET failed, and die would also skip the rm -f below.
        if ! curl_fs -X DELETE "$FS_URL/$probe" >/dev/null 2>&1; then
          warn "Could not confirm removal of the live file-lane probe: $probe"
        fi
        rm -f "$tmp"
        die "Stopped — no configuration changed. Fix the file server (or re-run setup: bash conduck-connect.sh --setup), then try --show-code again."
      fi
    else
      bad "file lane probe failed — leaving it out of the QR (re-run me after fixing)"
      curl_fs -X DELETE "$FS_URL/$probe" >/dev/null 2>&1 || true   # the PUT may have landed
      FS_LANE_DROPPED_BY_CHECK=true
      drop_file_lane
    fi
    rm -f "$tmp"

    if $transport_ok && [ -n "$FS_URL" ] && [ -n "$FS_CRED" ]; then
      case "$GW_KIND" in
        openclaw|hermes) agent_file_lane_gate || true ;;
      esac
    fi
  fi
}
# ------------------------------------------------------------- check-adapter --
#
# --check-adapter: a black-box check of an adapter built for Conduck against the
# rules at conduck.com/setup/adapter/v1/ (contract revision 1.4). Built for
# people whose adapter was written for Conduck — by hand or by an AI coding
# tool — around Claude Code, an agent framework, anything. It sends real
# requests and grades the answers strictly; it never touches configs, saved
# state, or the QR flow. (It will run against any OpenAI-compatible server,
# but grading OpenClaw/Hermes with it invites false FAILs — they legitimately
# do things the adapter rules forbid, e.g. keyless mode.)
#
# Why it exists next to verify_all: the wizard's verify step proves the HAPPY
# path (right token, clean request). The adapter check also proves what verify can't
# without pretending to be an attacker or a sloppy client — that auth is
# actually ENFORCED (a missing or wrong token must 401; the adapter that
# forgot its token check passes verify and gets a green QR while sitting wide
# open with tool access), that a REJECTED request leaves its connection usable
# for the NEXT one (the rejected body drained, or the connection closed — the
# one fault a by-hand curl structurally cannot find, because every curl command
# opens its own connection), that an ABSENT "model" field is tolerated, that
# unknown request fields are ignored, that a supplied model id really selects
# (or answers 400 + code "model_not_found"), that an image in an EARLIER
# message can never poison the chat (forward it or replace it with the
# contract's disclosure — never reject; one bad photo must not kill every
# later turn), and that "stream": true still gets ONE synchronous JSON answer.
# CHAT_BASIC owns the absent-model rule, and it owns it alone: the history,
# stream and image probes also omit the field, so on an adapter that REQUIRES a
# model they would every one of them fail for CHAT_BASIC's reason. Once CHAT_BASIC
# has confirmed that requirement — by re-sending its identical request with the
# first advertised id — the later probes carry that id and grade their OWN rule,
# and the missing-model failure is reported once, where it belongs.
# --deep adds the semantic image probe: a locally generated PNG showing 4
# random digits (never named in the prompt or metadata) rides the newest
# message — a reply carrying those digits proves the engine truly SAW the
# image (VERIFIED); an honest HTTP 400 decline with code "image_unsupported"
# also passes (DECLINED); a 200 that ignores the image is the forbidden
# silent drop (UNVERIFIED → exit 1).
#
# --files adds the file-lane probes (MUTATING — the one adapter-check profile that
# is: it writes + removes small conduck-check-* files in the configured
# shared folder, and asks the selected agent to copy one). Three meters,
# graded independently: file_transport (this host's WebDAV <-> disk lane),
# file_access (the selected engine can read/write the shared folder and
# names its output detectably), file_e2e (the combined output-delivery path,
# probed exactly the way the app probes it). It does NOT prove public
# exposure or remote-device reachability — the wizard verifies the
# app-facing lane during setup; the plain adapter check proves conformance.
#
# Output contract: every check verdict line carries a stable [CHECK_ID], and
# the LAST line on every exit — pass, fail, or an early die — is the machine
# summary, schema=3 (fixed field order, ASCII enums, no ANSI):
#   CONDUCK_CHECK_ADAPTER schema=3 contract=v1 revision=1.4 harness=<ver>
#     profile=<basic|deep> core=<PASS|FAIL|NOT_RUN>
#     history_image=<PASS|FAIL|NOT_RUN> stream=<PASS|FAIL|NOT_RUN>
#     image_input=<VERIFIED|DECLINED|UNVERIFIED|FAIL|NOT_RUN>
#     file_transport=<…> file_access=<…> file_e2e=<…>
#     checks=<n> failed=<n> exit=<n>
# Every capability meter is a claim about something the run MEASURED, so NOT_RUN
# covers both "a prerequisite stopped this tier" and "the probe failed for a
# cause this run could not tell apart from another rule's failure". A capability
# the run could not measure is never reported as failing it — the run-level
# verdict lives in core=/failed=/exit=, and a red verdict line there is what
# says the adapter is non-conformant.
# The three file meters share one enum: NOT_REQUESTED (no --files) |
# NOT_RUN (requested, but a prerequisite stopped this tier) | PASS | FAIL |
# ERROR (unsafe config, harness failure, or unproven cleanup). Scripts key
# on that line + the exit code, NEVER on check counts (they change between
# harness versions). Any grammar change bumps schema=. File checks never
# flip core= — the file lane is an optional profile outside the core wire
# contract — but their failures still count in failed= and force exit 1.
#
# Deliberately NOT here (they need a harness inside the adapter process, not
# HTTP probes — they belong in an adapter's own tests): the 285-second
# cancellation kill, concurrency/queue behaviour, and session or permission
# internals.
#
# Exit code: 0 = every check green, 1 = runtime/preflight/check failure,
# 2 = command-line usage error. Loop it from a shell while iterating.
# This repo's tests prove every check fails for its intended reason.

DOCTOR_CHECKS=0
DOCTOR_FAILS=0
DOCTOR_CONTRACT_REV="1.4"
# Machine-summary state. "Core" = every check except the deep image probe:
# IMAGE_INPUT failing still exits 1, but must never flip core=FAIL — it grades
# an optional capability's honesty, not the core wire contract.
DOCTOR_PROFILE="basic"
DOCTOR_CORE_RAN=false
DOCTOR_CORE_FAILS=0
DOCTOR_HISTORY_IMAGE="NOT_RUN"
DOCTOR_STREAM="NOT_RUN"
DOCTOR_IMAGE_INPUT="NOT_RUN"
# The three --files meters (NOT_REQUESTED until --files flips them to NOT_RUN
# at doctor start; the file tiers then grade each independently).
DOCTOR_FILE_TRANSPORT="NOT_REQUESTED"
DOCTOR_FILE_ACCESS="NOT_REQUESTED"
DOCTOR_FILE_E2E="NOT_REQUESTED"
# The status the LAST doctor_auth_route wrong-token probe got. AUTH_CHAT_REJECT_BODY
# grades what a rejection did with the body it rejected, so it only has something
# to grade when the route actually rejected: this is that precondition.
DOCTOR_AUTH_WRONG_CODE=""

# Does this adapter tolerate a request with NO "model" field? Three probes
# deliberately omit it (the contract requires tolerating an absent model), so on
# an adapter that REQUIRES one they would all fail for that single reason — and
# each would be explained as a fault of its own rule, which is how a working
# history-image path gets told it poisons conversations. CHAT_BASIC answers the
# question ONCE and every later chat probe reads the answer here:
#   unknown        — not decided (CHAT_BASIC hasn't run, or failed some other way)
#   tolerated      — a model-less turn answered; later model-less probes are honest
#   required       — CHAT_BASIC failed model-less and the identical request answered
#                    once DOCTOR_MODEL_LANE_ID was supplied. Later probes carry that
#                    id, so they grade the rule they exist to grade.
#   unattributable — CHAT_BASIC failed model-less and this run could not separate
#                    "requires a model" from a fault of its own; later probes of the
#                    same shape report NOT graded rather than inventing a cause.
# ONLY CHAT_BASIC may write these (doctor_chat_check enforces it). Letting a later
# probe decide would let a capability check outside the core= rollup turn its own
# red into a measured green, and IMAGE_INPUT can't flip core= — so a whole run
# could go green on an adapter that violates the absent-model rule.
DOCTOR_MODEL_LANE="unknown"
DOCTOR_MODEL_LANE_ID=""

# The way out of a FAIL that isn't the reader's to fix. This grade holds software
# written FOR Conduck to Conduck-specific rules, and third-party OpenAI-compatible
# software is EXPECTED to fail it — answering "stream": true with SSE is correct
# OpenAI behaviour, keyless is a legitimate deployment choice, and neither is a
# defect in LiteLLM, Open WebUI or Ollama. Without this, the closing line points
# only at the contract docs, so a user grading someone else's server reads a wall
# of red as "this cannot be used" and stops — when the app pairs with it fine.
# Printed on EVERY --check-adapter failure exit, including the early /v1/models
# abort: the person is equally stranded whichever check stopped the run.
doctor_not_yours_hint() {
  say "  Didn't write this server yourself? Then this red says very little. The grade above"
  say "  holds software built FOR Conduck to Conduck's own rules, and generic servers (Ollama,"
  say "  LiteLLM, Open WebUI) fail rules that are correct for them — their owners did nothing"
  say "  wrong. Ask the question you actually have instead:"
  say "    ${BOLD}bash conduck-connect.sh --check-server${RESET}   — can the app talk to this server?"
  say "    ${BOLD}bash conduck-connect.sh --setup${RESET}          — pair it; a failed grade here doesn't block that"
}

d_core_mark() { # d_core_mark <check-id> <pass|fail> — feed the core= rollup
  # IMAGE_INPUT grades an optional capability's honesty; FILES_*/FILE_* grade
  # the optional file profile. None of them may flip core= (they still count
  # in checks=/failed= and force exit 1 via d_bad).
  case "$1" in IMAGE_INPUT|FILES_*|FILE_*) return 0 ;; esac
  DOCTOR_CORE_RAN=true
  [ "$2" = "fail" ] && DOCTOR_CORE_FAILS=$((DOCTOR_CORE_FAILS+1))
  return 0
}
d_ok()  { local id="$1"; shift; DOCTOR_CHECKS=$((DOCTOR_CHECKS+1)); d_core_mark "$id" pass; ok "[$id] $*"; }
d_bad() { local id="$1"; shift; DOCTOR_CHECKS=$((DOCTOR_CHECKS+1)); DOCTOR_FAILS=$((DOCTOR_FAILS+1)); d_core_mark "$id" fail; bad "[$id] $*"; }
# Explanatory detail under a verdict — same [CHECK_ID] on every line, so a
# grep for one ID collects the whole story, not just the verdict.
d_say() { local id="$1"; shift; say "    [$id] $*"; }

# stdin: a response body -> 0 iff it's the contract's OpenAI error shape,
# {"error": {"message": "<non-empty>", "type": "<non-empty>", …}}. A bare
# {"error":{}} or a message-only body is NOT enough — the contract requires
# both fields. Used by the 401 soft-warn and every decline/reject grader, so
# all judge "is this a real error body?" the same way.
doctor_is_openai_error() {
  python3 -c 'import json,sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(1)
e = d.get("error") if isinstance(d, dict) else None
ok = (isinstance(e, dict)
      and isinstance(e.get("message"), str) and e.get("message")
      and isinstance(e.get("type"), str) and e.get("type"))
sys.exit(0 if ok else 1)' 2>/dev/null
}

# stdin: a response body; $1: a required machine code -> 0 iff error.code is
# EXACTLY that string. The stable codes are what clients key on (prose is
# free-form) — "looks like it declined" is not machine-verifiable, the code is.
doctor_error_code() {
  python3 -c 'import json,sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(1)
e = d.get("error") if isinstance(d, dict) else None
sys.exit(0 if isinstance(e, dict) and e.get("code") == sys.argv[1] else 1)' "$1" 2>/dev/null
}

# 0 iff $1 is application/json — case-insensitive, parameters tolerated
# ("application/json; charset=utf-8" passes; text/plain, text/event-stream,
# and a missing header do not).
ct_is_json() {
  local ct; ct=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  ct="${ct%%;*}"
  ct="${ct#"${ct%%[![:space:]]*}"}"; ct="${ct%"${ct##*[![:space:]]}"}"
  [ "$ct" = "application/json" ]
}

# Accept an https URL anywhere, or plain http toward THIS machine only
# (127.*/localhost/[::1]) — testing on the adapter's own host before HTTPS
# exposure is exactly the right order, and refusing loopback http would force
# people to expose first and test second. Echoes the normalized URL (trimmed,
# trailing slashes stripped, scheme lowercased); rc 1 when unacceptable.
doctor_accept_url() { # doctor_accept_url <candidate>
  local reply="$1" rest hostport host
  reply="${reply#"${reply%%[![:space:]]*}"}"; reply="${reply%"${reply##*[![:space:]]}"}"
  while [ "${reply%/}" != "$reply" ]; do reply="${reply%/}"; done
  [ -n "$reply" ] || return 1
  # Pure Bash on purpose: validate_cli calls this before runtime preflight, so
  # a missing python3/curl (or any other executable) can never turn a runtime
  # dependency failure into exit-2 command misuse.
  # Userinfo is refused on BOTH schemes. The loopback arm below has to (see its
  # comment: http://127.0.0.1@evil.com is a REMOTE host); https needs it for the
  # reason --show-code's profile validator already rejects it — this URL is
  # echoed to the terminal, saved to the profile, and paired into the app, and a
  # credential must never ride a routing field.
  url_has_userinfo "$reply" && return 1
  case "$reply" in
    [Hh][Tt][Tt][Pp][Ss]://?*) printf 'https://%s' "${reply#*://}"; return 0 ;;
    [Hh][Tt][Tt][Pp]://?*) rest="${reply#*://}" ;; # maybe-loopback
    *) return 1 ;;
  esac
  # A prefix glob is NOT enough to prove loopback: "http://127.0.0.1@evil.com"
  # (curl reads the part before @ as a username and connects to evil.com) and
  # "http://127.0.0.1.evil.com" (attacker's wildcard DNS) both start with
  # "http://127." — and would carry the REAL bearer token in cleartext to a
  # remote host. Parse out the authority and validate it strictly.
  hostport="${rest%%/*}"
  case "$hostport" in *@*|*' '*) return 1 ;; esac    # userinfo/junk → refuse
  case "$hostport" in
    '[::1]'|'[::1]:'*) ;;                            # IPv6 loopback (+ optional port)
    [Ll][Oo][Cc][Aa][Ll][Hh][Oo][Ss][Tt]|[Ll][Oo][Cc][Aa][Ll][Hh][Oo][Ss][Tt]:*) ;;
    127.*) host="${hostport%%:*}"
           case "$host" in *[!0-9.]*) return 1 ;; esac ;;  # 127.x must be a pure dotted quad
    *) return 1 ;;
  esac
  printf 'http://%s' "$rest"; return 0
}

doctor_ask_url() {  # -> echoes the URL ($()-captured: every human line to stderr)
  local reply url
  say "  Where is the server? Its base address, without any /v1 tail (I strip that myself)." >&2
  say "  Plain http:// is fine toward this machine (127.0.0.1/localhost) — test locally first," >&2
  say "  expose over HTTPS after." >&2
  while true; do
    read -r -p "  URL (e.g. http://127.0.0.1:8080) > " reply || return 1   # EOF: caller dies
    if url=$(doctor_accept_url "$reply"); then
      printf '  %s→ testing %s%s\n' "$DIM" "$url" "$RESET" >&2
      printf '%s' "$url"; return 0
    fi
    if url_has_userinfo "$reply"; then
      warn "$URL_USERINFO_HINT" >&2; continue
    fi
    case "$reply" in
      [Hh][Tt][Tt][Pp]://*) warn "Plain http:// only works toward this machine (127.0.0.1 or localhost). Anywhere else needs https://." >&2 ;;
      *) warn "That has to start with https:// — or http://127.0.0.1:<port> for a local test." >&2 ;;
    esac
  done
}

# The auth-NEGATIVE requests: no Authorization header at all, or a deliberately
# wrong bearer token. Plain curl on purpose — curl_gw would helpfully inject the
# REAL token, which is exactly what these two requests must not carry. The wrong
# token is a fixed harmless literal (nothing secret rides argv).
doctor_curl_negauth() { # doctor_curl_negauth <none|wrong> <curl args…>
  local kind="$1"; shift
  # Same egress isolation as curl_gw's doctor path: `-q` (first arg) ignores
  # ~/.curlrc so it can't inject a proxy/output-file/header, and `--noproxy '*'`
  # refuses every proxy — a proxy answering these probes could otherwise forge a
  # 401 and make the doctor report auth as "enforced" when the server is open.
  if [ "$kind" = "wrong" ]; then
    printf 'header = "Authorization: Bearer conduck-check-wrong-token"\n' \
      | curl -q -sS --max-time 30 --noproxy '*' --config - "$@"
  else
    curl -q -sS --max-time 30 --noproxy '*' "$@"
  fi
}

# Does an auth rejection on THIS route poison the connection it answered on?
# An adapter that replies 401 WITHOUT consuming the request body leaves those
# bytes in the socket; on a persistent HTTP/1.1 connection the server then
# reads them as the start of the NEXT request and answers 400 (or 414/431/
# 501/505, depending on its parser) to whatever comes after. RFC 9112 is
# explicit: a rejecting response must still consume the body, or close the
# connection. Three independently built adapters shipped exactly this bug.
#
# The probe: two identical wrong-token requests ride ONE curl invocation joined
# by `--next`, so curl reuses a single connection. Echoes
# "<status-1> <status-2> <new-connections-on-2>". That last field is the
# load-bearing evidence — 0 means curl really did reuse the connection, 1 means
# it opened a fresh one (e.g. because the server correctly answered
# `Connection: close`, or the pooled connection was dead), and a differing
# second status then proves nothing at all. The caller reads all three; this
# function makes no claim.
#
# `--next` RESETS every per-transfer option, so each half repeats its own
# `-sS`/`--http1.1`/`--max-time`/`--noproxy`/headers; only `-q` is global and
# has to stay first. Plain curl, never curl_gw — the REAL token must never ride
# an auth-negative probe; the wrong token is the same fixed harmless literal
# doctor_curl_negauth sends. `--http1.1` is pinned because HTTP/2 frames bodies
# and cannot show this failure at all.
#
# `-H 'Expect:'` deletes curl's `Expect: 100-continue`, and that is load-bearing
# rather than tidiness: with it, a server that answers 401 straight away makes
# curl skip sending the body at ALL, so there is nothing left over and the probe
# would report a clean connection for an adapter that never drains anything.
# curl only adds the header above a ~1 KB body today, so nothing changes now —
# pinning it keeps the probe honest if this body ever grows.
#
# The per-transfer time limit is the caller's, because the two callers want
# different ones: the diagnostic path passes 10 (an explanatory probe fired
# after an already-answered request has no business adding another minute),
# while the counted check passes the same 30 its own precondition already
# proved this route answers within — there, a probe that merely ran out of time
# would otherwise turn into a verdict about the adapter.
doctor_desync_pair() { # doctor_desync_pair <max-seconds> <curl args addressing the route…>
  local t="$1"; shift
  curl -q -sS --http1.1 --max-time "$t" --noproxy '*' \
       -H "Authorization: Bearer conduck-check-wrong-token" -H 'Expect:' \
       -o /dev/null -w '%{http_code} ' "$@" \
    --next -sS --http1.1 --max-time "$t" --noproxy '*' \
       -H "Authorization: Bearer conduck-check-wrong-token" -H 'Expect:' \
       -o /dev/null -w '%{http_code} %{num_connects}' "$@" 2>/dev/null
}

# The statuses an HTTP request PARSER emits when it starts reading in the middle
# of something that is not a request line — the fingerprint of a connection that
# still holds the body of an already-answered request. One list, shared by both
# readers of a desync pair (the counted check and the diagnostic), so the two can
# never drift into disagreeing about what the same evidence means.
doctor_parse_level_status() { # doctor_parse_level_status <http-status>
  case "$1" in 400|414|431|501|505) return 0 ;; esac
  return 1
}

# Busy/overloaded — the two statuses the contract itself lets an adapter answer
# instead of running a turn. The counted check refuses to grade a pair carrying
# one: it fires four rejected requests at a single route inside a second, and an
# adapter that throttles that burst is being careful, not broken. Blaming its
# body handling for a throttle is exactly the false FAIL this check must not emit.
doctor_busy_status() { # doctor_busy_status <http-status>
  case "$1" in 429|503) return 0 ;; esac
  return 1
}

# Split one doctor_desync_pair result into DSP_FIRST/DSP_SECOND/DSP_CONNECTS.
# rc 1 unless it is EXACTLY three fields, both statuses are three digits not
# starting with 0 (so curl's "000" — no answer at all — never reads as a status),
# and the connect count is a plain number. The strictness is the whole point: a
# truncated or empty result must FAIL to parse rather than get reinterpreted, or
# "the probe never ran" quietly becomes a confident verdict about an adapter that
# did nothing wrong. (`"401 400"` really does slice into 401/400/400 otherwise.)
DSP_FIRST=""; DSP_SECOND=""; DSP_CONNECTS=""
doctor_desync_parse() { # doctor_desync_parse <pair-output>
  local raw="$1" f s c
  DSP_FIRST=""; DSP_SECOND=""; DSP_CONNECTS=""
  case "$raw" in *' '*' '*) ;; *) return 1 ;; esac     # at least three fields…
  f="${raw%% *}"; raw="${raw#* }"
  s="${raw%% *}"; c="${raw#* }"
  case "$c" in *' '*) return 1 ;; esac                 # …and no more than three
  case "$f" in [1-9][0-9][0-9]) ;; *) return 1 ;; esac
  case "$s" in [1-9][0-9][0-9]) ;; *) return 1 ;; esac
  case "$c" in ''|*[!0-9]*) return 1 ;; esac
  DSP_FIRST="$f"; DSP_SECOND="$s"; DSP_CONNECTS="$c"
  return 0
}

# The undrained-body reading of a WRONG-token answer that isn't 401. This is
# the single most misread verdict in the whole check: the message ("HTTP 400,
# the contract pins 401") is literally true and causally wrong, and every
# builder who hit it went hunting through a token comparison that was fine.
# Only a route that CARRIES a body can leave bytes behind, so the models GET
# never asks. Diagnostic only — d_say lines under the caller's single d_bad,
# so check counts and the machine summary are untouched.
#
# Three honest outcomes, never one guess: the pair reproduced it on a proven
# reused connection (say so plainly) · the pair's first request answered 401
# where the standalone one answered $code, so the answer is not stable (report
# that, and where to look) · the status repeats (their auth path really does
# answer it — keep the drain theory to one hedged sentence).
doctor_auth_wrong_diagnose() { # doctor_auth_wrong_diagnose <check-id> <status> <curl args…>
  local id="$1" code="$2" a has_body=false desynced=false pair first="" second="" connects=""; shift 2
  for a in "$@"; do
    if [ "$a" = "-d" ]; then has_body=true; break; fi
  done
  $has_body || return 0
  # Parse-level statuses only. A 403/405/429 is plausible middleware, not a
  # desynced request stream, and guessing at those would just relocate the
  # wild-goose chase.
  doctor_parse_level_status "$code" || return 0
  pair=$(doctor_desync_pair 10 "$@") || pair=""
  if doctor_desync_parse "$pair"; then
    first="$DSP_FIRST"; second="$DSP_SECOND"; connects="$DSP_CONNECTS"
  fi
  # A differing second status only counts as evidence when curl proves it did
  # NOT open a new connection (connects=0) and the difference is parse-level.
  if [ "$first" = "401" ] && [ "$connects" = "0" ] && doctor_parse_level_status "$second"; then
    desynced=true
  fi
  if $desynced; then
    d_say "$id" "(a follow-up probe got 401, then HTTP $second for the SAME request on the SAME reused"
    d_say "$id" " connection — that is the signature of an undrained request body, not of a broken token"
    d_say "$id" " check. A response that REJECTS a request must still consume that request's body (read"
    d_say "$id" " the Content-Length bytes, drain the chunked stream) or answer \"Connection: close\" and"
    d_say "$id" " close: whatever is left in the socket gets read as the start of the NEXT request, and"
    d_say "$id" " that is what answered $second. Conduck reuses connections and so does any reverse proxy"
    d_say "$id" " in front of you, so this breaks real turns — not just this check.)"
  elif [ "$first" = "401" ]; then
    d_say "$id" "(the identical probe answered 401 a moment later, so HTTP $code is not a stable answer from"
    d_say "$id" " your auth code — check the path before you check the comparison. The usual cause is a 401"
    d_say "$id" " that answers WITHOUT consuming the request body: those bytes stay in the socket and the"
    d_say "$id" " next request on that kept-alive connection is parsed starting mid-body. A reverse proxy"
    d_say "$id" " pooling upstream connections shows exactly this — which is why it can pass against"
    d_say "$id" " http://127.0.0.1:<port> and fail through your HTTPS front. Compare those two runs.)"
  elif [ -n "$first" ]; then
    d_say "$id" "(HTTP $code repeats on a fresh connection, so this really does look like your auth path"
    d_say "$id" " answering — the contract wants 401 on both the missing and the wrong token. If it turns"
    d_say "$id" " out to reproduce ONLY through your HTTPS front and not against http://127.0.0.1:<port>,"
    d_say "$id" " suspect the other cause instead: a 401 that never consumes the request body leaves those"
    d_say "$id" " bytes to be read as the next request on a pooled connection.)"
  else
    # The pair produced no readable evidence, so every sentence above would be an
    # invention. Say only what is true, and name the run that answers it.
    d_say "$id" "(the follow-up probe that separates a genuine auth answer from an undrained request body"
    d_say "$id" " never completed, so this run can't tell you which it is. Run me ON the adapter's own host"
    d_say "$id" " against http://127.0.0.1:<port> for the reading with nothing in between.)"
  fi
}

# Contract 1.4, normative: a response that REJECTS a request before that
# request's body has been consumed must still read and discard the remainder, or
# send "Connection: close" and close. Skip both and the leftover bytes are read
# as the start of the NEXT request on that connection — a request that was
# itself perfectly fine. Three of five independent from-scratch adapter builds
# shipped exactly this. It cannot be found by hand: every plain curl command
# opens its own connection, so a loopback self-test structurally cannot see it,
# and it surfaces only behind the pooling HTTPS front the adapter is actually
# deployed behind (Cloudflare Tunnel, Tailscale Serve, nginx) as unexplained
# failures on unrelated requests. That is why this is a COUNTED check and not
# only the diagnosis above: the diagnosis fires after some OTHER check already
# went red, so an adapter that never trips that path ships with the bug intact.
#
# Preconditions, both the caller's: bearer auth, and a standalone wrong-token
# probe that already answered 401. Without a real rejection there is no rejected
# body to grade, and the not-401 case belongs to doctor_auth_wrong_diagnose.
#
# What green means here is "no follow-up failure observed", never "internals
# proven". %{num_connects}=0 proves the CLIENT reused its connection; behind a
# reverse proxy that is the connection to the PROXY, and which upstream
# connection the proxy then picked is not knowable from out here. So a failure is
# reported as what was SEEN — identical requests, different answers — and never
# as a cause this vantage point cannot establish.
#
# FAIL needs positive evidence. Everything that merely fails to PRODUCE evidence
# — a probe that never completed, an adapter throttling the burst with 429/503 —
# counts green with a note saying so. A check that reddens a CORRECT adapter is
# worse than no check: it sends its builder auditing code that was never wrong.
doctor_reject_body_check() { # doctor_reject_body_check <curl args addressing the chat POST route…>
  local id="AUTH_CHAT_REJECT_BODY" pair first second connects
  pair=$(doctor_desync_pair 30 "$@") || pair=""
  if ! doctor_desync_parse "$pair"; then
    # One retry, and only for this outcome: an incomplete transfer is the one
    # thing a second attempt can genuinely resolve. A 429 is never retried —
    # repeating the burst makes a throttle more likely, not less.
    pair=$(doctor_desync_pair 30 "$@") || pair=""
  fi
  if ! doctor_desync_parse "$pair"; then
    d_ok "$id" "rejected-request body — the follow-up probe never completed, so nothing was observed"
    d_say "$id" "(two more wrong-token requests down ONE connection would have shown whether a rejected"
    d_say "$id" " request's body is left behind for the next request to trip over; neither finished, so"
    d_say "$id" " this run has no evidence either way and does not hold that against you. For the reading"
    d_say "$id" " with nothing in between, run me ON the adapter's host against http://127.0.0.1:<port>.)"
    return 0
  fi
  first="$DSP_FIRST"; second="$DSP_SECOND"; connects="$DSP_CONNECTS"
  if [ "$first" = "401" ] && [ "$second" = "401" ]; then
    if [ "$connects" = "0" ]; then
      d_ok "$id" "rejected-request body — a second identical request on the SAME connection still → 401"
    else
      # The contract recommends exactly this for a 401 (draining an
      # unauthenticated peer's body does the work the rejection existed to
      # avoid), so it is a first-class pass, not a lucky one.
      d_ok "$id" "rejected-request body — the 401 closed the connection; the identical retry → 401"
    fi
    return 0
  fi
  if [ "$connects" = "0" ] && [ "$second" != "$first" ] && doctor_parse_level_status "$second"; then
    d_bad "$id" "rejected-request body — identical requests → $first then HTTP $second on ONE reused connection"
    d_say "$id" "(that is the signature of a rejection answered WITHOUT consuming the request's body: the"
    d_say "$id" " leftover bytes are read as the start of the next request, and that is what answered"
    d_say "$id" " $second. Contract revision $DOCTOR_CONTRACT_REV: a response that rejects a request must still read and"
    d_say "$id" " discard the rest of that body, or send \"Connection: close\" and close after it. For a 401"
    d_say "$id" " closing is usually the better half — draining an unauthenticated peer performs exactly the"
    d_say "$id" " work the rejection existed to avoid. Conduck reuses connections and so does every reverse"
    d_say "$id" " proxy, so this breaks ordinary turns that are themselves perfectly fine. From out here I"
    d_say "$id" " can only prove MY connection was reused — which upstream connection a front picked isn't"
    d_say "$id" " visible, so confirm it on the adapter's own host against http://127.0.0.1:<port>.)"
    return 1
  fi
  if doctor_busy_status "$first" || doctor_busy_status "$second"; then
    d_ok "$id" "rejected-request body — the route answered $first then $second (busy), so it wasn't graded"
    d_say "$id" "(this probe fires four rejected requests at one route inside a second, and throttling that"
    d_say "$id" " burst is careful rather than broken, so it is not counted against you. It does mean this"
    d_say "$id" " run proves nothing about what happens to a rejected request's body — re-run me when the"
    d_say "$id" " route is idle if you want that answered.)"
    return 0
  fi
  d_bad "$id" "rejected-request body — the wrong token → 401 alone, but $first then $second down one connection"
  d_say "$id" "(the same request got two different-looking answers seconds apart, so something in the path"
  d_say "$id" " is not deciding consistently. The usual cause is a rejection answered without consuming the"
  d_say "$id" " request's body: the leftovers desync whichever pooled connection they land on, so the damage"
  d_say "$id" " shows up on a LATER request rather than this one. Contract revision $DOCTOR_CONTRACT_REV: drain the remainder,"
  d_say "$id" " or answer \"Connection: close\" and close after it. Check the HTTPS front too — it pools"
  d_say "$id" " upstream connections, so one poisoned connection resurfaces on requests that are fine.)"
  return 1
}

# Check 1 — GET /v1/models with the REAL token: reachability + the canonical
# envelope, via the same models_is_json the wizard trusts (the script must never
# be laxer than the app it green-lights for). rc 1 = transport/status trouble →
# the caller aborts the remaining checks instead of failing four ways at once.
doctor_models_check() {
  local rc=0 why="" secs over
  models_is_json "$GW_URL" || rc=$?
  # curl's own %{time_total} — the real wire time, with no python-spawn overhead
  # polluting it (formatted to 1 decimal; awk tolerates an odd value).
  secs=$(printf '%s' "${MODELS_TIME:-0}" | awk '{printf "%.1f", $1+0}' 2>/dev/null); [ -n "$secs" ] || secs="?"
  over=$(printf '%s' "${MODELS_TIME:-0}" | awk '{print ($1+0 > 15) ? 1 : 0}' 2>/dev/null)
  if [ "$rc" = "0" ]; then
    if $MODELS_DATA_EMPTY; then
      d_bad MODELS_ENVELOPE "GET /v1/models — canonical envelope, but \"data\" is EMPTY"
      d_say MODELS_ENVELOPE '(the contract requires at least one {"id": …} entry — the app has to offer a model)'
    elif $MODELS_NO_VALID_ID; then
      d_bad MODELS_ENVELOPE "GET /v1/models — \"data\" has entries, but none carry a usable \"id\" string"
      d_say MODELS_ENVELOPE '(each entry must be {"id": "<model-name>"} with a non-empty string — the app names a'
      d_say MODELS_ENVELOPE ' model from this list; an entry with no id can'\''t be selected)'
    elif [ "$over" = "1" ]; then
      # A models answer past 15s is a hard FAIL, not a warning: the app's Test
      # Connection gives up at 15s, so this gateway simply won't connect.
      d_bad MODELS_ENVELOPE "GET /v1/models — answered, but took ${secs}s (over the 15s limit)"
      d_say MODELS_ENVELOPE "(the app's Test Connection gives up after 15s — answer from cache, never cold-start"
      d_say MODELS_ENVELOPE " or lazy-load a model on this route)"
    elif ! ct_is_json "$MODELS_CONTENT_TYPE"; then
      d_bad MODELS_ENVELOPE "GET /v1/models — canonical envelope, but Content-Type is '${MODELS_CONTENT_TYPE:0:60}'"
      d_say MODELS_ENVELOPE "(answer with Content-Type: application/json — parameters like charset are fine;"
      d_say MODELS_ENVELOPE " anything else, or no header at all, is a contract failure)"
    else
      d_ok MODELS_ENVELOPE "GET /v1/models — canonical envelope (${secs}s)"
    fi
    return 0
  elif [ "$rc" = "2" ]; then
    d_bad MODELS_ENVELOPE "GET /v1/models — returned an HTML page instead of JSON (HTTP ${MODELS_HTTP_CODE:-?})"
    d_say MODELS_ENVELOPE "(something else answered — a reverse proxy, a login/access page, or a wrong base address)"
    return 1
  elif [ "$rc" = "3" ]; then
    d_bad MODELS_ENVELOPE "GET /v1/models — answers, but not the canonical envelope"
    d_say MODELS_ENVELOPE '(must be a JSON OBJECT whose top-level "data" is an ARRAY of {"id": …} — not a bare'
    d_say MODELS_ENVELOPE ' array, not {"models": …}. This is the app'\''s Test Connection rule, applied verbatim.)'
    return 1
  fi
  if [ "$MODELS_CURL_RC" != "0" ]; then
    case "$MODELS_CURL_RC" in
      6)  why="DNS lookup failed — that hostname doesn't resolve" ;;
      7)  why="connection refused — nothing is listening there (wrong port? not started?)" ;;
      28) why="timed out — no answer from the host" ;;
      35) why="TLS problem — the HTTPS front rejected the connection" ;;
      60) why="TLS problem — this machine doesn't trust the server's certificate (self-signed? run me ON the server against http://127.0.0.1:<port> instead)" ;;
      *)  why="transfer failed (curl exit $MODELS_CURL_RC)" ;;
    esac
  else
    case "$MODELS_HTTP_CODE" in
      401|403) if [ "${GW_AUTH:-}" = "none" ]; then
                 why="HTTP $MODELS_HTTP_CODE and no token was sent — this run is keyless, so the server is asking for auth you didn't supply (set CONDUCK_TOKEN=<token>)"
               else
                 why="HTTP $MODELS_HTTP_CODE with the token you gave me — the server rejected it (typo? or an access layer in front wants its own login)"
               fi ;;
      3??)     why="HTTP $MODELS_HTTP_CODE redirect — use the final server URL directly (the check does not forward credentials across redirects)" ;;
      404)     why="HTTP 404 — nothing at that path (wrong base address?)" ;;
      5??)     why="HTTP $MODELS_HTTP_CODE — the server errored" ;;
      200)     why="answered 200, but the body isn't strict JSON (NaN/Infinity also count as not-JSON — Conduck's decoder refuses them)" ;;
      *)       why="HTTP $MODELS_HTTP_CODE" ;;
    esac
  fi
  d_bad MODELS_ENVELOPE "GET /v1/models — $why"
  return 1
}

# One route's auth-enforcement pair: a no-token request AND a wrong-token
# request must EACH answer 401. `$@` is the curl args that address the route
# (URL for a GET; URL + `-H Content-Type` + `-d body` for the chat POST). The
# real token never rides these — doctor_curl_negauth sends none, or the fixed
# harmless wrong literal.
doctor_auth_route() { # doctor_auth_route <id-prefix> <route-label> <curl-args…>
  local idp="$1" route="$2"; shift 2
  local out rc code body
  out=$(doctor_curl_negauth none -w '\n%{http_code}' "$@" 2>/dev/null); rc=$?
  code="${out##*$'\n'}"; body="${out%$'\n'*}"
  if [ "$rc" != "0" ] || [ -z "$code" ] || [ "$code" = "000" ]; then
    d_bad "${idp}_MISSING" "auth ($route): WITHOUT a token — no answer (the with-token request worked, so this looks like per-request trouble)"
  elif [ "$code" = "401" ]; then
    d_ok "${idp}_MISSING" "auth ($route): WITHOUT a token → 401 (enforced)"
    # Soft check only — the status is the load-bearing part; the body shape
    # decides how nice the app's error message can be, not whether auth holds.
    if ! printf '%s' "$body" | doctor_is_openai_error; then
      warn "  [${idp}_MISSING] …its 401 body isn't the OpenAI error shape — send {\"error\": {\"message\": …, \"type\": …}} (both non-empty) so the app can show a real message."
    fi
  elif [ "$code" = "200" ]; then
    d_bad "${idp}_MISSING" "auth ($route): WITHOUT a token → 200 — the server did the work anyway"
    d_say "${idp}_MISSING" "(this is the dangerous one: anyone who can reach this address can drive your AI and"
    d_say "${idp}_MISSING" " its tools. Check the Authorization header BEFORE doing anything else, on every route.)"
  else
    d_bad "${idp}_MISSING" "auth ($route): WITHOUT a token → HTTP $code (the contract pins exactly 401)"
  fi
  code=$(doctor_curl_negauth wrong -o /dev/null -w '%{http_code}' "$@" 2>/dev/null) || code=""
  DOCTOR_AUTH_WRONG_CODE="$code"
  case "$code" in
    401) d_ok "${idp}_WRONG" "auth ($route): WRONG token → 401 (enforced)" ;;
    200) d_bad "${idp}_WRONG" "auth ($route): WRONG token → 200 — the token isn't actually compared"
         d_say "${idp}_WRONG" "(compare byte-for-byte against the token you issued — e.g. hmac.compare_digest in Python)" ;;
    ""|000) d_bad "${idp}_WRONG" "auth ($route): WRONG token — no answer (a wide-open server may instead be running a slow agent turn on the probe — check its logs)" ;;
    *)   d_bad "${idp}_WRONG" "auth ($route): WRONG token → HTTP $code (the contract pins exactly 401)"
         doctor_auth_wrong_diagnose "${idp}_WRONG" "$code" "$@" ;;
  esac
}

# Auth must be ENFORCED, not merely accepted — on EVERY route the app calls.
# Testing only /v1/models would green-light a server that gates its model list
# but leaves the tool-running /v1/chat/completions wide open: the exact hole
# this check exists to catch. So both routes are probed. The chat probe carries
# a minimal body (auth is meant to reject before that body is PROCESSED — the
# bytes must still be consumed off the socket, or the connection closed; see
# doctor_desync_pair for what skipping that costs). If a vulnerable server
# instead RUNS the agent on the unauthenticated request, the probe still fails
# — either 200 (caught) or a >30s timeout reported as a failure (fail-safe,
# never a green pass).
doctor_auth_checks() {
  local body='{"messages":[{"role":"user","content":"conduck-connect auth probe"}],"stream":false}'
  if [ "$GW_AUTH" != "bearer" ]; then
    d_bad AUTH_NOT_ENFORCED "auth enforcement — untestable: you gave me no token, so I must assume the server is keyless"
    d_say AUTH_NOT_ENFORCED "(the contract requires a bearer token on EVERY route — a keyless adapter that can run"
    d_say AUTH_NOT_ENFORCED " tools is wide open to whoever can reach it. Add a token check, then re-run me.)"
    return 0
  fi
  doctor_auth_route AUTH_MODELS "/v1/models" "$GW_URL/v1/models"
  doctor_auth_route AUTH_CHAT "/v1/chat/completions" "$GW_URL/v1/chat/completions" \
    -H "Content-Type: application/json" -d "$body"
  # Only a route that really REJECTED has a rejected body to be graded on, so
  # the counted check runs on the chat POST and only after its own wrong-token
  # probe answered 401. Never on /v1/models: a GET carries no body, so there is
  # nothing that could be left behind. When the 401 didn't happen, the failing
  # AUTH_CHAT_WRONG line already carries doctor_auth_wrong_diagnose's reading —
  # counting a second red for the same fault would just double-bill it.
  if [ "$DOCTOR_AUTH_WRONG_CODE" = "401" ]; then
    doctor_reject_body_check "$GW_URL/v1/chat/completions" \
      -H "Content-Type: application/json" -d "$body"
  fi
  return 0
}

# ---- one real chat turn: transport + grading, shared by every chat probe ----
#
# doctor_chat_request does the POST with the REAL token and lands status /
# content-type / timing / BODY in DCC_* globals (memory only: the body is
# never printed — these probes may run against a live personal agent, and this
# script never logs message content; graders emit verdict words and lengths).
#
# DCC_CURL_RC keeps curl's own exit code when the transfer never completed — a
# dead peer and a slow one are the same "no reply" to a caller that only sees
# rc 1, and that lossy bucket is exactly how an adapter killed mid-turn reads
# as a network fault. It is the WRAPPER's code: curl_gw returns 2 on its own
# credential guard before curl ever runs (preflight makes that unreachable
# here, but the code is not curl's to interpret if it ever fires).
DCC_CODE=""; DCC_CT=""; DCC_TIME=""; DCC_BODY=""; DCC_CURL_RC=0
doctor_chat_request() { # doctor_chat_request <payload-json> [max-seconds] -> 0 iff transfer completed
  local out tail_ max_time="${2:-300}"
  DCC_CODE=""; DCC_CT=""; DCC_TIME=""; DCC_BODY=""; DCC_CURL_RC=0
  # `out=$(…) || { rc=$?; }` on purpose: inside `if ! out=$(…); then` the `$?`
  # is the NEGATED status (0), and the real code would be lost.
  out=$(curl_gw -w '\n%{http_code} %{time_total} %{content_type}' "$GW_URL/v1/chat/completions" \
        --max-time "$max_time" -H "Accept: application/json" \
        -H "Content-Type: application/json" -d "$1" 2>/dev/null) || { DCC_CURL_RC=$?; return 1; }
  tail_="${out##*$'\n'}"; DCC_BODY="${out%$'\n'*}"
  DCC_CODE="${tail_%% *}"; tail_="${tail_#* }"
  DCC_TIME="${tail_%% *}"
  [ "$tail_" != "${tail_#* }" ] && DCC_CT="${tail_#* }"
  DCC_TIME=$(printf '%s' "$DCC_TIME" | awk '{printf "%.1f", $1}' 2>/dev/null)
  return 0
}

# What curl's exit code says about a transfer that never completed, in the
# words a builder can act on. Deliberately hedged where curl is: 7 covers a
# refused connection AND routing/firewall dead ends, and 52/56/18 are one story
# told at three moments (peer gone before any reply · connection broken while
# reading · reply cut off mid-body) — which one appears is decided by timing,
# TLS and any proxy, so none of them PROVES a dead process on its own. The
# caller's hint names that case; this line only reports what happened.
doctor_transfer_reason() { # doctor_transfer_reason <curl exit code>
  case "$1" in
    6)  printf 'the hostname did not resolve' ;;
    7)  printf 'could not connect to that address (refused, or blocked on the way)' ;;
    18) printf 'the reply stopped mid-body' ;;
    28) printf 'no complete answer within the time limit' ;;
    35) printf 'the TLS connection failed' ;;
    52) printf 'the server closed the connection without sending a reply' ;;
    55) printf 'the connection broke while the request was still being sent' ;;
    56) printf 'the connection broke while the reply was being read' ;;
    60) printf 'this machine does not trust the server certificate' ;;
    *)  printf 'transfer failed (curl exit %s)' "$1" ;;
  esac
}

# doctor_chat_eval grades the reply in DCC_* against the contract's response
# rules (strict JSON, exactly one choice, non-empty STRING content, no
# tool_calls, no SSE, Content-Type application/json). This is STRICTER than
# today's app decoder, which reads choices[0].message.content leniently —
# deliberately: the contract is the forward promise an adapter must meet, so
# the doctor holds that bar. It PRINTS NOTHING (callers own the verdict
# lines): failure lands in DCE_REASON/DCE_HINT, success in DCE_LEN — plus
# DCE_TOKEN when an expected digit code was given (the --deep image probe's
# semantic grading: the code must appear as a standalone digit-run in the
# reply, so "The digits are 4827." passes while "48275" does not).
DCE_REASON=""; DCE_HINT=""; DCE_LEN=""; DCE_TOKEN=""
doctor_chat_eval() { # doctor_chat_eval <payload-json> [expected-digit-code]
  local exp="${2:--}" res verdict detail
  DCE_REASON=""; DCE_HINT=""; DCE_LEN=""; DCE_TOKEN=""
  if ! doctor_chat_request "$1"; then
    # DCE_HINT stays exactly "transfer" — the file lane keys on that literal to
    # decide it may not grade the lane. The sub-case lives in DCC_CURL_RC.
    DCE_REASON=$(doctor_transfer_reason "$DCC_CURL_RC"); DCE_HINT="transfer"; return 1
  fi
  # SSE despite a synchronous request is its own diagnosis — a JSON parse
  # error would bury the actual mistake.
  case "$DCC_BODY" in data:*)
    DCE_REASON="the server answered with SSE framing"; DCE_HINT="sse"; return 1 ;;
  esac
  if [ "$DCC_CODE" != "200" ]; then
    case "$DCC_CODE" in
      3??) DCE_REASON="HTTP $DCC_CODE redirect — use the final server URL directly (the check does not forward credentials across redirects)" ;;
      *)   DCE_REASON="HTTP ${DCC_CODE:-?}" ;;
    esac
    DCE_HINT="http"; return 1
  fi
  if ! ct_is_json "$DCC_CT"; then
    DCE_REASON="HTTP 200, but Content-Type is '${DCC_CT:0:60}' (must be application/json)"; DCE_HINT="ct"; return 1
  fi
  # Strict parse (parse_constant: NaN/Infinity refused, matching the app's
  # decoder) + the contract's one-choice / non-empty-string rules on top.
  res=$(printf '%s' "$DCC_BODY" | python3 -c '
import json, sys, re
def bad(x): raise ValueError(x)
exp = sys.argv[1] if len(sys.argv) > 1 else "-"
try:
    d = json.load(sys.stdin, parse_constant=bad)
except Exception:
    print("badjson -"); sys.exit(0)
ch = d.get("choices") if isinstance(d, dict) else None
if not isinstance(ch, list) or not ch:
    print("nochoices -"); sys.exit(0)
if len(ch) != 1:
    print("manychoices %d" % len(ch)); sys.exit(0)
msg = ch[0].get("message") if isinstance(ch[0], dict) else None
if not isinstance(msg, dict):
    print("nochoices -"); sys.exit(0)
if msg.get("tool_calls"):
    print("toolcalls -"); sys.exit(0)
c = msg.get("content")
if not isinstance(c, str):
    print("notstring -"); sys.exit(0)
if not c:
    print("empty -"); sys.exit(0)
if exp != "-":
    print(("token %d" if exp in re.findall(r"\d+", c) else "notoken %d") % len(c)); sys.exit(0)
print("ok %d" % len(c))' "$exp" 2>/dev/null)
  verdict="${res%% *}"; detail="${res#* }"
  case "$verdict" in
    ok)      DCE_LEN="$detail"; return 0 ;;
    token)   DCE_LEN="$detail"; DCE_TOKEN="yes"; return 0 ;;
    notoken) DCE_LEN="$detail"; DCE_TOKEN="no";  return 0 ;;   # shape is fine; the digits aren't there
    badjson)     DCE_REASON="HTTP 200, but the body isn't strict JSON"; DCE_HINT="badjson" ;;
    nochoices)   DCE_REASON="no usable \"choices\" array"; DCE_HINT="nochoices" ;;
    manychoices) DCE_REASON="$detail choices in the reply (the contract pins exactly ONE)" ;;
    toolcalls)   DCE_REASON="the reply carries tool_calls"; DCE_HINT="toolcalls" ;;
    notstring)   DCE_REASON="\"content\" isn't a plain string"; DCE_HINT="notstring" ;;
    empty)       DCE_REASON="\"content\" is an empty string" ;;
    *)           DCE_REASON="could not grade the reply" ;;
  esac
  return 1
}

# The statuses that MIGHT mean "this request needs a model field". A status in
# here proves NOTHING on its own — it only buys the one controlled retry below the
# right to run, and that retry is the evidence. So this list exists to avoid
# wasting a five-minute turn, not to classify anything.
#
# 413 is deliberately NOT in it, and this list is deliberately NOT the one
# --check-server uses. Two separate reasons:
#   413 — the contract assigns it to a request-size / image-too-large limit, and
#     this check has a real diagnosis for that. Admitting it here would let a
#     genuine size limit be re-reported as "not graded" and bury the true cause.
#   --check-server keeps its own, wider list inline. It answers a different
#     question (can the app talk to this server) at a deliberately laxer bar, and
#     it already ships that behaviour; sharing one list would silently move a
#     verdict in a command this slice was not asked to change. Two questions, two
#     lists, each with its reason written next to it.
# This is also NOT "the set the app's model-required heuristic accepts": the app
# gates on those statuses AND then requires model-required prose in the body
# (RemoteAgentClient), so the status alone was never its rule either.
doctor_model_required_candidate_status() { # <http-status>
  case "$1" in 400|404|422) return 0 ;; esac
  return 1
}

# 0 iff the payload carries a top-level "model" key (absent and null both count
# as absent — the contract's rule is about the field the app didn't send).
doctor_payload_has_model() { # <payload-json>
  printf '%s' "$1" | python3 -c 'import json, sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if isinstance(d, dict) and d.get("model") is not None else 1)' 2>/dev/null
}

# Echo the payload with "model" set. Used to carry the advertised id on the
# probes that come AFTER the absent-model rule has already been graded.
doctor_payload_with_model() { # <payload-json> <model-id>
  printf '%s' "$1" | CONDUCK_CHECK_MODEL="$2" python3 -c 'import json, os, sys
req = json.load(sys.stdin)
req["model"] = os.environ["CONDUCK_CHECK_MODEL"]
print(json.dumps(req))' 2>/dev/null
}

# Did THIS payload only fail for want of a model? Re-sends the identical request
# with the first advertised id and nothing else changed: rc 0 means the model was
# the only thing missing — confirmed for this payload, not deduced from prose.
# Reading the error message instead would be guesswork (every adapter words it
# differently); one controlled retry is the evidence.
#
# The caller's DCC_*/DCE_* evidence is snapshotted and restored, because
# doctor_chat_eval overwrites those globals: without this the caller's own hints
# would describe the RETRY and not the model-less failure they are explaining.
doctor_model_required_probe() { # <payload-json>
  local payload="$1" retried rc=1
  local s_code="$DCC_CODE" s_ct="$DCC_CT" s_time="$DCC_TIME" s_body="$DCC_BODY" s_crc="$DCC_CURL_RC"
  local s_reason="$DCE_REASON" s_hint="$DCE_HINT" s_len="$DCE_LEN" s_token="$DCE_TOKEN"
  retried=$(doctor_payload_with_model "$payload" "$MODELS_FIRST_ID")
  if [ -n "$retried" ] && doctor_chat_eval "$retried"; then rc=0; fi
  DCC_CODE="$s_code"; DCC_CT="$s_ct"; DCC_TIME="$s_time"; DCC_BODY="$s_body"; DCC_CURL_RC="$s_crc"
  DCE_REASON="$s_reason"; DCE_HINT="$s_hint"; DCE_LEN="$s_len"; DCE_TOKEN="$s_token"
  return $rc
}

# Every verdict reached on a probe that had to BORROW a model id says so, on the
# verdict itself. Without this the transcript and the machine summary both read as
# though the probe ran under the contract's own model-less conditions, which is
# the condition it could NOT run under — and a green line that quietly relaxed
# what it tested is the same defect as a red line with an invented cause. Cheap
# and unconditional on purpose: the note is skipped only when nothing was
# borrowed, so no verdict can carry a relaxed condition silently.
# $2 is the borrowed thing itself (the rewritten payload, or the id) — EMPTY means
# this probe borrowed nothing and the note must not fire. Gating on
# DOCTOR_MODEL_LANE alone would print it on CHAT_BASIC's own verdict, the one
# probe that really did run model-less and that latched the lane a line earlier.
doctor_carried_model_note() { # doctor_carried_model_note <check-id> <borrowed-or-empty>
  [ -n "$2" ] || return 0
  [ "$DOCTOR_MODEL_LANE" = "required" ] || return 0
  d_say "$1" "(measured with \"model\": \"$(safe_display "$DOCTOR_MODEL_LANE_ID" 60)\" supplied — this adapter"
  d_say "$1" " rejects the model-less request the contract asks for, which [CHAT_BASIC] grades)"
  return 0
}

# 0 iff the failure currently in DCC_*/DCE_* is one this run could NOT attribute:
# a model-less probe rejected the same way CHAT_BASIC was, on a run that could not
# separate "this adapter requires a model" from a fault of the rule being graded.
# Callers add "and this payload really was model-less" themselves.
doctor_unattributable_modelless() {
  [ "$DOCTOR_MODEL_LANE" = "unattributable" ] || return 1
  [ "$DCE_HINT" = "http" ] || return 1
  doctor_model_required_candidate_status "$DCC_CODE"
}

# One graded chat check with its verdict line + failure hints. kind picks the
# failure explanation: plain (the tolerance turn) · history (the
# anti-poisoning turn) · stream ("stream": true).
#
# DCC_VERDICT carries the CAPABILITY verdict for the machine summary, which is
# not always the verdict line: PASS · FAIL · NOT_RUN when the probe failed for a
# cause this run could not attribute to the rule the check exists to grade. A
# capability the run could not measure must never be reported as failing it.
DCC_VERDICT="NOT_RUN"

# The capability meter for the check doctor_chat_check just graded. Fill a
# machine-summary meter from THIS, never from doctor_chat_check's exit status:
# that status answers "did this check go red", which is a different question from
# "what did this run measure". NOT_RUN is the honest answer when the probe failed
# for a cause this run could not tell apart from another rule's failure.
doctor_capability_meter() { printf '%s' "$DCC_VERDICT"; }
doctor_chat_check() { # doctor_chat_check <check-id> <label> <payload-json> <kind>
  local id="$1" label="$2" payload="$3" kind="${4:-plain}" modelless=false carried=""
  DCC_VERDICT="NOT_RUN"
  doctor_payload_has_model "$payload" || modelless=true
  # Once CHAT_BASIC has established that this adapter requires the field, every
  # later model-less probe carries the advertised id. Without it they all fail
  # for CHAT_BASIC's reason and none of them measures anything. This mirrors
  # --check-server, which carries the advertised id on every probe after it
  # learns the server requires one.
  if $modelless && [ "$DOCTOR_MODEL_LANE" = "required" ]; then
    carried=$(doctor_payload_with_model "$payload" "$DOCTOR_MODEL_LANE_ID")
    if [ -n "$carried" ]; then payload="$carried"; modelless=false; fi
  fi
  if doctor_chat_eval "$payload"; then
    DCC_VERDICT="PASS"
    [ "$id" = "CHAT_BASIC" ] && DOCTOR_MODEL_LANE="tolerated"
    d_ok "$id" "$label — one choice, non-empty string content (${DCE_LEN:-?} chars, ${DCC_TIME:-?}s)"
    doctor_carried_model_note "$id" "$carried"
    return 0
  fi
  DCC_VERDICT="FAIL"
  # The absent-model question, decided ONCE, by CHAT_BASIC only (see
  # DOCTOR_MODEL_LANE). A later probe must never latch it.
  if [ "$id" = "CHAT_BASIC" ] && $modelless && [ "$DCE_HINT" = "http" ] \
     && doctor_model_required_candidate_status "$DCC_CODE"; then
    if [ -n "$MODELS_FIRST_ID" ] && doctor_model_required_probe "$payload"; then
      DOCTOR_MODEL_LANE="required"; DOCTOR_MODEL_LANE_ID="$MODELS_FIRST_ID"
    else
      DOCTOR_MODEL_LANE="unattributable"
    fi
  fi
  d_bad "$id" "$label — $DCE_REASON"
  doctor_carried_model_note "$id" "$carried"
  # A model-less probe that failed the same way CHAT_BASIC did, on a run that
  # could not attribute that failure: the honest answer is that this check was
  # not graded — never a story about the rule it happens to be named after.
  if $modelless && [ "$id" != "CHAT_BASIC" ] && doctor_unattributable_modelless; then
    DCC_VERDICT="NOT_RUN"
    d_say "$id" "(this request deliberately carries no \"model\" field, and [CHAT_BASIC] above was"
    d_say "$id" " rejected the same way, so this run can't tell the two rules apart — it is NOT"
    d_say "$id" " grading this one. Fix that failure first, then re-run me.)"
    return 1
  fi
  case "$DCE_HINT" in
    sse)
      case "$kind" in
        stream) d_say "$id" "(even when the request says \"stream\": true, answer ONE complete JSON object."
                d_say "$id" " Conduck always sends \"stream\": false and never accepts SSE, so answer one JSON"
                d_say "$id" " object even if some other client sets the flag)" ;;
        *)      d_say "$id" "(when stream is false, answer with ONE complete JSON object — Conduck never accepts SSE)" ;;
      esac ;;
    transfer)
      case "$DCC_CURL_RC" in
        7|18|52|55|56)
          d_say "$id" "(from out here a dead adapter and a broken network look identical — and it is usually"
          d_say "$id" " the adapter: backgrounded from a terminal it dies with that shell or gets reaped"
          d_say "$id" " mid-turn, and every later check then reports transport trouble that has nothing to do"
          d_say "$id" " with the contract. Check it is still running, then keep it under something that"
          d_say "$id" " restarts it — systemd, launchd, pm2, docker restart=always — before re-running me.)" ;;
        28)
          d_say "$id" "(nothing complete came back before the deadline — either the turn genuinely runs longer"
          d_say "$id" " than that, or the adapter is wedged on this request. Its own log holds the request it"
          d_say "$id" " never finished; Conduck gives up too, so a turn this slow fails in the app as well.)" ;;
        35|60)
          d_say "$id" "(the HTTPS front refused the connection, so the adapter behind it was never reached —"
          d_say "$id" " run me ON the server against http://127.0.0.1:<port> to test the adapter itself first)" ;;
      esac ;;
    http)
      # A 5xx from a front-end proxy is about that proxy's UPSTREAM, never about
      # the contract rule this request was testing — so it pre-empts the
      # per-kind hints. Otherwise a dead adapter during the history turn reads
      # as "you rejected the historical image", which is a wild-goose chase.
      case "$DCC_CODE" in
        502|503)
          d_say "$id" "(a $DCC_CODE is the HTTPS front talking, not your adapter: the front is up but got"
          d_say "$id" " nothing usable out of the adapter behind it. Most often that process is gone —"
          d_say "$id" " backgrounded with no supervisor, or crashed on this turn — or it is bound to a"
          d_say "$id" " different port than the front sends to; an overloaded or restarting adapter looks"
          d_say "$id" " the same. Check it is running and supervised, then re-run me.)"
          return 1 ;;
        504)
          d_say "$id" "(a 504 is the HTTPS front giving up on your adapter. Either the turn outruns the"
          d_say "$id" " front's proxy timeout — agent turns are slow, raise it — or the adapter is wedged"
          d_say "$id" " on this request and its own log will say so.)"
          return 1 ;;
        413)
          # The contract spends 413 on a request-size limit, and a server that
          # answers one has STATED its cause. Telling the reader instead that they
          # reject historical images, or refuse the stream flag, is the same defect
          # as any other invented explanation — so the stated cause pre-empts every
          # per-kind story, exactly as the front-end 5xx statuses do above.
          d_say "$id" "(a 413 is a request-size limit answering, not a judgement on this request's shape."
          d_say "$id" " The probe images here are tiny, so the limit is almost always in FRONT of the"
          d_say "$id" " adapter — raise the reverse proxy's max body size (nginx client_max_body_size,"
          d_say "$id" " Caddy request_body). Conduck sends real photos, which are far larger than this.)"
          return 1 ;;
      esac
      # The one cause that would otherwise be told three different ways, none of
      # them true: this adapter requires the field the contract makes optional.
      # A retry confirmed it for this exact payload, so it is said once, plainly,
      # and never dressed up as a history-poisoning or streaming fault.
      if [ "$id" = "CHAT_BASIC" ] && [ "$DOCTOR_MODEL_LANE" = "required" ]; then
        d_say "$id" "(the identical request answered normally as soon as \"model\": \"$(safe_display "$DOCTOR_MODEL_LANE_ID" 60)\" was"
        d_say "$id" " supplied, so this adapter REQUIRES that field — and that is the ONLY fault this request"
        d_say "$id" " shows. The contract makes it optional: with no \"model\", pick your own default and answer."
        d_say "$id" " The remaining chat checks carry that id, so each grades its own rule instead of failing"
        d_say "$id" " again for this one.)"
        return 1
      fi
      case "$kind" in
        history)
          d_say "$id" "(the contract forbids rejecting a request because of an image in an EARLIER message —"
          d_say "$id" " forward it to the engine, or replace it in place with the contract's disclosure text."
          d_say "$id" " A text-only newest message must always get an answer: one rejected photo must never"
          d_say "$id" " poison every later turn of the conversation.)" ;;
        stream)
          d_say "$id" "(\"stream\": true must not be rejected — ignore the flag and answer one synchronous"
          d_say "$id" " JSON object, exactly as for stream:false)" ;;
        *)
          case "$DCC_CODE" in
            4??) d_say "$id" "(a 4xx here usually means the request body was rejected — the contract requires"
                 d_say "$id" " tolerating an ABSENT \"model\" field (pick your own default) and IGNORING unknown fields)" ;;
            5??) d_say "$id" "(the server errored — its own logs have the real story)" ;;
          esac ;;
      esac ;;
    badjson)   d_say "$id" "(one complete JSON object; NaN/Infinity are refused by Conduck's decoder)" ;;
    nochoices) d_say "$id" "(the reply must carry choices[0].message.content — see the contract's response shape)" ;;
    toolcalls) d_say "$id" "(never return tool_calls to Conduck — run your tools SERVER-side and answer with the final text)" ;;
    notstring) d_say "$id" "(in the RESPONSE, content must be a non-empty STRING — null or parts-form content is refused)" ;;
    ct)        d_say "$id" "(answer with Content-Type: application/json — parameters like charset are fine)" ;;
  esac
  return 1
}

# Model selection (one logical check, two requests). The app sends the model
# id the user picked from YOUR /v1/models — so the first advertised id must
# actually select (strict 200). And a made-up id must not silently succeed:
# with 2+ advertised models it MUST answer HTTP 400 + an OpenAI error body
# carrying code "model_not_found" (400, not 404 — the contract pins 404 to
# unknown PATHS); a single-model adapter MAY ignore the field instead (it
# advertises exactly one thing, so nothing is ambiguous).
doctor_model_selection_check() {
  local id="MODEL_SELECTION" payload count happy="skip" happy_reason="" bogus="" bogus_reason=""
  count="${MODELS_ID_COUNT:-0}"
  if [ -n "$MODELS_FIRST_ID" ]; then
    payload=$(CONDUCK_CHECK_MODEL="$MODELS_FIRST_ID" python3 -c 'import json, os
print(json.dumps({"messages": [{"role": "user", "content": "Reply with exactly: pong"}],
                  "model": os.environ["CONDUCK_CHECK_MODEL"], "stream": False}))') \
      || die "Could not build the test request (python3 failed)."
    if doctor_chat_eval "$payload"; then happy="ok"; else happy="fail"; happy_reason="$DCE_REASON"; fi
  fi
  payload=$(python3 -c 'import json
print(json.dumps({"messages": [{"role": "user", "content": "Reply with exactly: pong"}],
                  "model": "conduck-check-no-such-model", "stream": False}))') \
    || die "Could not build the test request (python3 failed)."
  if doctor_chat_eval "$payload"; then
    if [ "$count" -gt 1 ]; then bogus="accepted"; else bogus="ignored"; fi
  elif [ "$DCC_CODE" = "400" ] && printf '%s' "$DCC_BODY" | doctor_is_openai_error \
       && printf '%s' "$DCC_BODY" | doctor_error_code "model_not_found"; then
    bogus="rejected"
  else
    bogus="fail"; bogus_reason="$DCE_REASON"
    [ "$DCC_CODE" = "400" ] && bogus_reason="HTTP 400, but the error body lacks code \"model_not_found\" (or isn't the full OpenAI error shape)"
  fi
  if [ "$happy" != "fail" ] && { [ "$bogus" = "rejected" ] || [ "$bogus" = "ignored" ]; }; then
    local how="unknown id → 400 + \"model_not_found\""
    [ "$bogus" = "ignored" ] && how="unknown id ignored (single-model adapter — allowed)"
    d_ok "$id" "model selection — advertised id selects; $how"
    return 0
  fi
  if [ "$happy" = "fail" ]; then
    d_bad "$id" "model selection — asking for your OWN advertised id ('${MODELS_FIRST_ID:0:40}') failed: $happy_reason"
    d_say "$id" "(the app sends the model id the user picked from your /v1/models list — a supplied"
    d_say "$id" " advertised id must select and answer, exactly like an absent one)"
    return 1
  fi
  case "$bogus" in
    accepted)
      d_bad "$id" "model selection — a made-up model id was ACCEPTED (you advertise $count models)"
      d_say "$id" "(with more than one model advertised, the app can't tell which one answered. Reject an"
      d_say "$id" " unknown id with HTTP 400 + an error body carrying code \"model_not_found\")" ;;
    *)
      d_bad "$id" "model selection — a made-up model id wasn't rejected the contract's way: ${bogus_reason:-HTTP ${DCC_CODE:-?}}"
      d_say "$id" "(reject an unknown model id with HTTP 400 — not 404, that's for unknown paths — plus an"
      d_say "$id" " OpenAI error body {\"error\": {\"message\": …, \"type\": …, \"code\": \"model_not_found\"}})" ;;
  esac
  return 1
}

# --deep's semantic image probe. A PNG rendered HERE (stdlib zlib/struct — 4
# random digits as big block glyphs, black on white, ~632×232) rides the
# newest message; the digits are never in the prompt, filename, or metadata,
# so the ONLY way to answer them is to actually see the image. Outcomes:
#   VERIFIED   — 200 and the reply contains the digits: the engine truly sees
#                images (OCR tooling counts — this grades capability, not eyes).
#   DECLINED   — HTTP 400 + OpenAI error body + code "image_unsupported": a
#                text-only adapter refusing honestly. Allowed, passes.
#   UNVERIFIED — 200 but the digits aren't in the reply: the image was
#                silently dropped or hallucinated over — the one forbidden
#                move. Fails the deep profile.
# Anything else (wrong/missing decline code, other statuses, bad shape) FAILs:
# clients key on the machine code, so "looks declined" isn't good enough.
# ~1-in-9000 guess odds are accepted. The reply's content is never printed.
# Build the semantic image probe (shared by --deep and --check-server): sets
# IPG_CODE (the 4 digits) and IPG_PAYLOAD (the chat request carrying the PNG).
# $CONDUCK_PROBE_MODEL adds a "model" field when it is non-empty. EVERY caller
# sets it explicitly, because the python reads the ENVIRONMENT: a caller that
# merely omits it inherits whatever the operator happened to export, which
# silently changes the request being graded. The compat probe threads the
# advertised id through once it learns the server requires one; the doctor sets
# it EMPTY (contract: an absent model must be tolerated).
image_probe_gen() {
  local gen
  gen=$(python3 -c '
import json, os, zlib, struct, base64, random
FONT = {
    "0": [14, 17, 19, 21, 25, 17, 14], "1": [4, 12, 4, 4, 4, 4, 14],
    "2": [14, 17, 1, 2, 4, 8, 31],     "3": [31, 2, 4, 2, 1, 17, 14],
    "4": [2, 6, 10, 18, 31, 2, 2],     "5": [31, 16, 30, 1, 1, 17, 14],
    "6": [6, 8, 16, 30, 17, 17, 14],   "7": [31, 1, 2, 4, 8, 8, 8],
    "8": [14, 17, 17, 14, 17, 17, 14], "9": [14, 17, 17, 15, 1, 2, 12],
}
SCALE, MARGIN, GAP = 16, 60, 64  # wide GAP is load-bearing: at GAP=24 real
# vision models systematically misread adjacent glyphs (measured 1/6 correct
# vs 8/8 at GAP=64 on gpt-5.6 — tight spacing reads as merged segments)
GW, GH = 5 * SCALE, 7 * SCALE
W, H = MARGIN * 2 + 4 * GW + 3 * GAP, MARGIN * 2 + GH
code = str(random.randint(1, 9)) + "".join(str(random.randint(0, 9)) for _ in range(3))
rows = [bytearray(b"\xff" * W) for _ in range(H)]
for i, ch in enumerate(code):
    x0 = MARGIN + i * (GW + GAP)
    for r, bits in enumerate(FONT[ch]):
        for c in range(5):
            if bits & (1 << (4 - c)):
                for y in range(MARGIN + r * SCALE, MARGIN + (r + 1) * SCALE):
                    for x in range(x0 + c * SCALE, x0 + (c + 1) * SCALE):
                        rows[y][x] = 0
raw = b"".join(b"\x00" + bytes(r) for r in rows)
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 0, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
uri = "data:image/png;base64," + base64.b64encode(png).decode()
print(code)
req = {"messages": [{"role": "user", "content": [
    {"type": "text", "text": "Reply with exactly the digits shown in the image. No other text."},
    {"type": "image_url", "image_url": {"url": uri}}]}], "stream": False}
m = os.environ.get("CONDUCK_PROBE_MODEL", "")
if m:
    req["model"] = m
print(json.dumps(req))') \
    || die "Could not build the image test request (python3 failed)."
  IPG_CODE="${gen%%$'\n'*}"; IPG_PAYLOAD="${gen#*$'\n'}"
}

doctor_image_input_check() {
  local id="IMAGE_INPUT" code payload
  # Set explicitly, never inherited. $CONDUCK_PROBE_MODEL is internal plumbing for
  # handing a value to python without argv, and the probe's python reads the
  # ENVIRONMENT — so a variable the operator happens to have exported would
  # silently put a "model" field in this request and move the verdict for a reason
  # the adapter author cannot see. It is EMPTY by default, because the contract
  # makes tolerating an absent model a requirement and CHAT_BASIC is what grades
  # that rule. It carries the advertised id only once CHAT_BASIC has established
  # that this adapter requires the field: otherwise this probe fails for CHAT_BASIC's
  # reason and reports a vision fault the run never measured.
  CONDUCK_PROBE_MODEL="$DOCTOR_MODEL_LANE_ID" image_probe_gen
  code="$IPG_CODE"; payload="$IPG_PAYLOAD"
  if doctor_chat_eval "$payload" "$code"; then
    if [ "$DCE_TOKEN" = "yes" ]; then
      DOCTOR_IMAGE_INPUT="VERIFIED"
      d_ok "$id" "image input — the reply reads the digits back (VERIFIED, ${DCC_TIME:-?}s)"
      doctor_carried_model_note "$id" "$DOCTOR_MODEL_LANE_ID"
      return 0
    fi
    DOCTOR_IMAGE_INPUT="UNVERIFIED"
    d_bad "$id" "image input — answered 200, but the reply doesn't contain the image's digits (${DCE_LEN:-?} chars)"
    d_say "$id" "(the engine never saw the image — it was silently dropped somewhere, the one forbidden"
    d_say "$id" " move. Forward images to the engine, or decline honestly with HTTP 400 + an error body"
    d_say "$id" " carrying code \"image_unsupported\" — never answer as if no image was attached.)"
    doctor_carried_model_note "$id" "$DOCTOR_MODEL_LANE_ID"
    return 1
  fi
  if [ "$DCC_CODE" = "400" ] && printf '%s' "$DCC_BODY" | doctor_is_openai_error \
     && printf '%s' "$DCC_BODY" | doctor_error_code "image_unsupported"; then
    DOCTOR_IMAGE_INPUT="DECLINED"
    d_ok "$id" "image input — declined with HTTP 400 + code \"image_unsupported\" (honest refusal, allowed)"
    doctor_carried_model_note "$id" "$DOCTOR_MODEL_LANE_ID"
    return 0
  fi
  # Same rule as the chat probes, and it is asked BEFORE the decline is graded: an
  # adapter that requires a model answers this model-less probe with a 400 and a
  # perfectly well-formed error body, which the branch below would otherwise read
  # as a dishonest image decline — a vision verdict on a run that never reached the
  # engine's eyes at all. Not measured means NOT_RUN.
  if doctor_unattributable_modelless; then
    DOCTOR_IMAGE_INPUT="NOT_RUN"
    d_bad "$id" "image input — $DCE_REASON"
    d_say "$id" "(this request also carries no \"model\" field, and [CHAT_BASIC] above was rejected the same"
    d_say "$id" " way, so this run can't tell the two rules apart — it is NOT grading image input. Fix that"
    d_say "$id" " failure first, then re-run me.)"
    return 1
  fi
  if [ "$DCC_CODE" = "400" ] && printf '%s' "$DCC_BODY" | doctor_is_openai_error; then
    DOCTOR_IMAGE_INPUT="FAIL"
    d_bad "$id" "image input — declined with HTTP 400, but without code \"image_unsupported\""
    d_say "$id" "(the decline itself is allowed — but the app keys on the machine code to explain the"
    d_say "$id" " refusal and offer recovery, so add \"code\": \"image_unsupported\" to the error object)"
    doctor_carried_model_note "$id" "$DOCTOR_MODEL_LANE_ID"
    return 1
  fi
  DOCTOR_IMAGE_INPUT="FAIL"
  d_bad "$id" "image input — $DCE_REASON"
  doctor_carried_model_note "$id" "$DOCTOR_MODEL_LANE_ID"
  return 1
}
# ----------------------------------------------------- check-adapter --files --
#
# The file-lane probes: the ONE adapter-check profile that mutates. Three independent
# tiers, three independent meters:
#   tier 1  file_transport — this host's WebDAV <-> disk lane: auth on the
#           routes that actually carry user bytes, write-through fidelity,
#           direct-write freshness (the rclone --dir-cache-time trap that hid
#           agent-written files from the app), ranged-probe compatibility,
#           nested folders (tri-state — the app has a flat fallback), DELETE.
#   tier 2  file_access — one real chat turn: the SELECTED model must copy a
#           sentinel byte-for-byte to the folder root and name it detectably.
#           Graded with the app's REAL wire text (the input-reference block +
#           [Conduck file transfer] instruction from ConverseRequest.swift,
#           golden-locked) and the app's REAL detector rules (allowlist,
#           inbound exclusion, 5-candidate cap).
#   tier 3  file_e2e — the combined delivery path, probed the way the app
#           probes it: ONE immediate ranged GET when the reply lands (no
#           retry, no grace), then a separate full download byte-compare.
# A PASS proves: this host's lane + the selected model, through this adapter,
# delivered one detectable output file. It does NOT prove public exposure,
# remote-device reachability, other models, or folder confinement.
#
# Safety: every artifact name carries a per-run nonce and the recognizable
# conduck-check- prefix; targets are REGISTERED before creation and removed
# by exact name only (never a glob); direct-disk operations revalidate the
# folder's pinned device+inode first; cleanup failure is ERROR, not silence.

DF_URL=""; DF_DIR=""; DF_CRED=""; DF_USER="conduck"
DF_DEV_INO=""      # "<dev>:<ino>" pinned at resolve time — every direct disk op revalidates
DF_RUN=""          # per-run namespace nonce; every artifact name carries it
DF_ARTS=()         # "tier<TAB>kind<TAB>relkey" — registered BEFORE creation; tier T|A, kind file|dir
DF_AGENT_RAN=false
DF_WROTE=false     # true once a mutating operation could have created something. DF_ARTS
                   # proves only INTENT (registration precedes creation, by design), so
                   # anything that sends the operator looking keys off THIS flag.
df_register() { DF_ARTS+=("$1"$'\t'"$2"$'\t'"$3"); }

# The file lane's own curl: same egress isolation as the chat probes (`-q`
# ignores ~/.curlrc, --noproxy refuses every proxy — a proxy answering these
# would grade the wrong server, or receive the file credential), credential on
# a stdin curl config, never argv. Kinds: real | wrong (fixed harmless
# literal) | none (no Authorization at all).
doctor_curl_fs() { # doctor_curl_fs <real|wrong|none> <curl args…>
  local kind="$1"; shift
  case "$kind" in
    real)
      credential_value_safe "$DF_CRED" || return 2
      credential_value_safe "$DF_USER" || return 2
      local cred="$DF_CRED" user="$DF_USER"
      cred="${cred//\\/\\\\}"; cred="${cred//\"/\\\"}"
      user="${user//\\/\\\\}"; user="${user//\"/\\\"}"
      printf 'user = "%s:%s"\n' "$user" "$cred" \
        | curl -q -sS --max-time 30 --noproxy '*' --config - "$@" ;;
    wrong) curl -q -sS --max-time 30 --noproxy '*' -u "$DF_USER:conduck-check-wrong-cred" "$@" ;;
    none)  curl -q -sS --max-time 30 --noproxy '*' "$@" ;;
  esac
}
doctor_fs_code() { # doctor_fs_code <real|wrong|none> [curl args…] <url> -> echoes 3-digit code, 000 on transport failure
  local code
  code=$(doctor_curl_fs "$1" -o /dev/null -w '%{http_code}' "${@:2}" 2>/dev/null) || true
  case "$code" in [0-9][0-9][0-9]) printf '%s' "$code" ;; *) printf '000' ;; esac
}
# The ONE door for every mutating WebDAV verb (PUT, MKCOL) — same contract as
# doctor_fs_code, plus the DF_WROTE bookkeeping. An ANSWERED request may have
# created something even when it rejected the write, and even somewhere this
# host cannot see (a server serving a DIFFERENT directory than the one on
# record is exactly what FILES_WRITE_THROUGH exists to catch), so any status
# counts. A 000 means no server answered at all: nothing can have been created,
# and a later DELETE to the same silent lane cannot remove anything either.
doctor_fs_write() { # doctor_fs_write <real|wrong|none> [curl args…] <url> -> echoes 3-digit code
  local code
  code=$(doctor_fs_code "$@")
  [ "$code" = "000" ] || DF_WROTE=true
  printf '%s' "$code"
}

doctor_files_dir_ok() { # the pinned-identity gate before EVERY direct disk operation
  local now
  now=$(python3 -c 'import os, sys
try:
    st = os.stat(sys.argv[1]); print("%d:%d" % (st.st_dev, st.st_ino))
except Exception: pass' "$DF_DIR" 2>/dev/null)
  [ -n "$DF_DEV_INO" ] && [ "$now" = "$DF_DEV_INO" ]
}

# doctor_files_disk_verify <relkey> <expected-content-file>
# -> echoes OK | MISSING | MISMATCH | NOTREGULAR | TOOBIG | UNSAFE
doctor_files_disk_verify() {
  doctor_files_dir_ok || { printf 'UNSAFE'; return 0; }
  python3 - "$DF_DIR" "$1" "$2" <<'PY' 2>/dev/null || printf 'UNSAFE'
import os, stat, sys
root, rel, expf = sys.argv[1], sys.argv[2], sys.argv[3]
p = os.path.join(root, rel)
rp = os.path.realpath(p)
if not (rp == root or rp.startswith(root + os.sep)):
    print("UNSAFE"); sys.exit(0)
try:
    st = os.lstat(p)
except FileNotFoundError:
    print("MISSING"); sys.exit(0)
except Exception:
    print("UNSAFE"); sys.exit(0)
if not stat.S_ISREG(st.st_mode):
    print("NOTREGULAR"); sys.exit(0)
if st.st_size > 1048576:
    print("TOOBIG"); sys.exit(0)
exp = open(expf, "rb").read()
fd = os.open(p, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
got = os.read(fd, 1048577)
os.close(fd)
print("OK" if got == exp else "MISMATCH")
PY
}

# Resolve ONE immutable file-lane context (URL + credential + folder) and pin
# the folder's identity. Two sources, never mixed: the CONDUCK_FILES_* env
# overrides (all-or-nothing — CI rigs, manual setups), or the saved pairing
# profile whose gateway.url equals the doctor's target (EXACTLY one match),
# corroborated against the live unit before any direct-disk authority is
# granted. Everything lands under FILES_CONFIG.
doctor_files_resolve() {
  local src out
  if [ -n "${CONDUCK_FILES_URL:-}${CONDUCK_FILES_DIR:-}${CONDUCK_FILES_PASS:-}" ]; then
    src="env overrides"
    if [ -z "${CONDUCK_FILES_URL:-}" ] || [ -z "${CONDUCK_FILES_DIR:-}" ] || [ -z "${CONDUCK_FILES_PASS:-}" ]; then
      d_bad FILES_CONFIG "CONDUCK_FILES_* overrides are all-or-nothing — set URL + DIR + PASS together"
      d_say FILES_CONFIG "(mixing an overridden URL with a discovered folder could grade one lane and mutate another)"
      return 1
    fi
    if ! credential_value_safe "$CONDUCK_FILES_PASS" \
       || ! credential_value_safe "${CONDUCK_FILES_USER:-conduck}"; then
      d_bad FILES_CONFIG "CONDUCK_FILES_PASS/CONDUCK_FILES_USER contain control characters — refusing"
      return 1
    fi
    if ! DF_URL=$(doctor_accept_url "$CONDUCK_FILES_URL"); then
      if url_has_userinfo "$CONDUCK_FILES_URL"; then
        d_bad FILES_CONFIG "CONDUCK_FILES_URL carries a \"user:pass@\" credential in the address — give the plain URL"
        d_say FILES_CONFIG "(the file-lane password goes in CONDUCK_FILES_PASS, the user in CONDUCK_FILES_USER)"
      else
        d_bad FILES_CONFIG "CONDUCK_FILES_URL must be https://… or http:// toward this machine (127.0.0.1/localhost)"
      fi
      return 1
    fi
    DF_DIR="$CONDUCK_FILES_DIR"; DF_CRED="$CONDUCK_FILES_PASS"; DF_USER="${CONDUCK_FILES_USER:-conduck}"
  else
    src="saved profile"
    out=$(python3 - "$GW_URL" "$STATE_DIR" <<'PY' 2>/dev/null
import glob, json, os, sys
want = sys.argv[1].rstrip("/").lower()
hits = []
for pf in sorted(glob.glob(os.path.join(sys.argv[2], "profile-*.json"))):
    try:
        d = json.load(open(pf))
    except Exception:
        continue
    gw = d.get("gateway") or {}
    fs = d.get("fileServer")
    url = (gw.get("url") or "").rstrip("/").lower()
    if url == want and isinstance(fs, dict):
        hits.append((gw.get("id") or "", str(fs.get("localPort") or ""), fs.get("folder") or ""))
if len(hits) != 1:
    print("COUNT %d" % len(hits))
else:
    print("OK")
    for field in hits[0]:
        print(field)
PY
)
    case "$out" in
      OK*) ;;
      "COUNT 0"|"")
        d_bad FILES_CONFIG "no saved pairing profile with a file lane matches this URL"
        d_say FILES_CONFIG "(the profile route works on the machine the wizard ran on, against the same gateway URL —"
        d_say FILES_CONFIG " anywhere else, set CONDUCK_FILES_URL + CONDUCK_FILES_DIR + CONDUCK_FILES_PASS explicitly)"
        return 1 ;;
      *)
        d_bad FILES_CONFIG "more than one saved profile matches this URL — ambiguous, refusing to guess"
        d_say FILES_CONFIG "(set CONDUCK_FILES_URL + CONDUCK_FILES_DIR + CONDUCK_FILES_PASS to pick one lane explicitly)"
        return 1 ;;
    esac
    local pid pport pfolder
    pid=$(printf '%s\n' "$out" | sed -n '2p')
    pport=$(printf '%s\n' "$out" | sed -n '3p')
    pfolder=$(printf '%s\n' "$out" | sed -n '4p')
    [ -n "$pid" ] || { d_bad FILES_CONFIG "the matching profile carries no gateway id — re-run the wizard to refresh it"; return 1; }
    # existing_fs_config keys its unit/state lookups off GW_ID — safe to set
    # here: doctor mode never writes profiles or units (REUSE_ONLY is forced).
    GW_ID="$pid"
    if ! existing_fs_config; then
      d_bad FILES_CONFIG "the profile names a file lane, but no live file-server unit + credential was found for it"
      d_say FILES_CONFIG "(re-run the wizard to repair the lane, or use the CONDUCK_FILES_* overrides)"
      return 1
    fi
    # Corroborate profile vs unit BEFORE granting direct-disk authority: the
    # unit's folder parse is best-effort text extraction; the profile is an
    # independent record. Only their agreement earns writes/deletes.
    if [ -n "$pport" ] && [ "$pport" != "$FS_LOCAL_PORT" ]; then
      d_bad FILES_CONFIG "profile and service disagree on the local port ($pport vs $FS_LOCAL_PORT) — re-run the wizard"
      return 1
    fi
    if [ -z "$pfolder" ] || [ -z "$FS_FOLDER" ] || [ "$pfolder" != "$FS_FOLDER" ]; then
      d_bad FILES_CONFIG "profile and service disagree on the served folder — refusing direct-disk probes"
      d_say FILES_CONFIG "(re-run the wizard to rewrite both records, or use the CONDUCK_FILES_* overrides)"
      return 1
    fi
    # Loopback on purpose: the doctor grades THIS HOST's lane; contacting a
    # public URL the user never typed would widen the doctor's egress contract.
    DF_URL="http://127.0.0.1:$FS_LOCAL_PORT"
    DF_DIR="$pfolder"; DF_CRED="$FS_CRED"; DF_USER="conduck"
  fi
  if ! credential_value_safe "$DF_CRED"; then
    d_bad FILES_CONFIG "the recovered credential contains control characters — refusing"
    return 1
  fi
  out=$(python3 - "$DF_DIR" <<'PY' 2>/dev/null
import os, sys
p = sys.argv[1]
if not p or not os.path.isabs(p) or any(c in p for c in "\r\n"):
    print("BAD not an absolute clean path"); sys.exit(0)
rp = os.path.realpath(p)
home = os.path.realpath(os.path.expanduser("~"))
if rp == "/" or rp == home:
    print("BAD refusing / and the home directory itself"); sys.exit(0)
if not os.path.isdir(rp):
    print("BAD the folder does not exist"); sys.exit(0)
st = os.stat(rp)
print("OK %d:%d" % (st.st_dev, st.st_ino))
print(rp)
PY
)
  case "$out" in
    OK*) ;;
    BAD*) d_bad FILES_CONFIG "shared folder rejected — ${out#BAD }"; return 1 ;;
    *)    d_bad FILES_CONFIG "could not validate the shared folder (python3 failed)"; return 1 ;;
  esac
  DF_DEV_INO=$(printf '%s\n' "$out" | sed -n '1p'); DF_DEV_INO="${DF_DEV_INO#OK }"
  DF_DIR=$(printf '%s\n' "$out" | sed -n '2p')
  d_ok FILES_CONFIG "file lane resolved ($src) — server $DF_URL, folder verified (identity pinned)"
  return 0
}

# Tier 1 — transport. Sets DOCTOR_FILE_TRANSPORT.
doctor_files_transport() {
  local tfail=0 terr=0 disk_ok=true code out body tmpd tmp uprobe hdrs
  local wkey="conduck-check-$DF_RUN-wt.txt"
  local fkey="conduck-check-$DF_RUN-fresh.txt"
  local ukey1="conduck-check-$DF_RUN-unauth-none.txt"
  local ukey2="conduck-check-$DF_RUN-unauth-wrong.txt"
  local nkey="conduck-check-$DF_RUN-dir"
  local wt_nonce
  wt_nonce=$(python3 -c 'import secrets; print("conduck-check write-through " + secrets.token_hex(16))' 2>/dev/null)
  # ONE 0700 directory, three files inside it — not one mktemp file plus sibling
  # names built by string concatenation. mktemp publishes its random suffix the
  # moment it creates the file, and /tmp's sticky bit stops DELETION, not the
  # CREATION of "<that name>.u"; a local user who wins that race turns the plain
  # redirect below into a write through their symlink, at this script's
  # privileges — and `-D` lets the file server choose the bytes written.
  tmpd=$(mktemp -d "${TMPDIR:-/tmp}/conduck-check.XXXXXX" 2>/dev/null) || tmpd=""
  if [ -z "$wt_nonce" ] || [ -z "$tmpd" ]; then
    d_bad FILES_CONFIG "could not stage transport probes (python3/mktemp failed)"
    DOCTOR_FILE_TRANSPORT="ERROR"; return 0
  fi
  tmp="$tmpd/probe"; uprobe="$tmpd/unauth"; hdrs="$tmpd/headers"

  # write-through: PUT over WebDAV must land byte-identical in the folder.
  df_register T file "$wkey"
  printf '%s\n' "$wt_nonce" > "$tmp"
  code=$(doctor_fs_write real -T "$tmp" "$DF_URL/$wkey")
  local wt_ok=false
  case "$code" in
    2??)
      out=$(doctor_files_disk_verify "$wkey" "$tmp")
      case "$out" in
        OK) d_ok FILES_WRITE_THROUGH "write-through — PUT over WebDAV landed byte-identical in the configured folder"; wt_ok=true ;;
        MISSING)
          d_bad FILES_WRITE_THROUGH "PUT answered HTTP $code, but nothing appeared in the configured folder"
          d_say FILES_WRITE_THROUGH "(the server serves a DIFFERENT directory than the one on record — the app would upload"
          d_say FILES_WRITE_THROUGH " into one folder while the agent works in another. Re-run the wizard.)"
          tfail=$((tfail+1)) ;;
        MISMATCH|NOTREGULAR|TOOBIG)
          d_bad FILES_WRITE_THROUGH "PUT landed, but the on-disk file is wrong ($out)"; tfail=$((tfail+1)) ;;
        *)
          d_bad FILES_WRITE_THROUGH "could not verify the folder safely — direct-disk checks disabled this run"
          terr=$((terr+1)); disk_ok=false ;;
      esac ;;
    401|403) d_bad FILES_WRITE_THROUGH "authenticated PUT rejected (HTTP $code) — read-only folder or wrong credential"; tfail=$((tfail+1)) ;;
    000)     d_bad FILES_WRITE_THROUGH "no answer from $DF_URL — is the file server running?"; tfail=$((tfail+1)) ;;
    *)       d_bad FILES_WRITE_THROUGH "authenticated PUT answered HTTP $code"; tfail=$((tfail+1)) ;;
  esac

  # auth, on the routes that carry user bytes (a server protecting only
  # listings while GET/PUT stay open must fail here).
  if $wt_ok; then
    code=$(doctor_fs_code none "$DF_URL/$wkey")
    case "$code" in
      401|403) d_ok FILES_AUTH_READ_MISSING "GET without credentials is refused (HTTP $code)" ;;
      2??)     d_bad FILES_AUTH_READ_MISSING "GET with NO credentials answered HTTP $code — the lane is open"; tfail=$((tfail+1)) ;;
      *)       d_bad FILES_AUTH_READ_MISSING "GET without credentials answered HTTP $code (expected 401/403)"; tfail=$((tfail+1)) ;;
    esac
    code=$(doctor_fs_code wrong "$DF_URL/$wkey")
    case "$code" in
      401|403) d_ok FILES_AUTH_READ_WRONG "GET with a WRONG credential is refused (HTTP $code)" ;;
      2??)     d_bad FILES_AUTH_READ_WRONG "GET with a WRONG credential answered HTTP $code — any password works"; tfail=$((tfail+1)) ;;
      *)       d_bad FILES_AUTH_READ_WRONG "GET with a wrong credential answered HTTP $code (expected 401/403)"; tfail=$((tfail+1)) ;;
    esac
  else
    note "  [FILES_AUTH_READ_MISSING] [FILES_AUTH_READ_WRONG] skipped — need the write-through file to probe against."
  fi
  df_register T file "$ukey1"
  printf 'conduck-check unauth probe\n' > "$uprobe"
  code=$(doctor_fs_write none -T "$uprobe" "$DF_URL/$ukey1")
  case "$code" in
    401|403) d_ok FILES_AUTH_WRITE_MISSING "PUT without credentials is refused (HTTP $code)" ;;
    2??)     d_bad FILES_AUTH_WRITE_MISSING "PUT with NO credentials was ACCEPTED (HTTP $code) — anyone can write into this folder"; tfail=$((tfail+1)) ;;
    *)       d_bad FILES_AUTH_WRITE_MISSING "PUT without credentials answered HTTP $code (expected 401/403)"; tfail=$((tfail+1)) ;;
  esac
  df_register T file "$ukey2"
  code=$(doctor_fs_write wrong -T "$uprobe" "$DF_URL/$ukey2")
  case "$code" in
    401|403) d_ok FILES_AUTH_WRITE_WRONG "PUT with a WRONG credential is refused (HTTP $code)" ;;
    2??)     d_bad FILES_AUTH_WRITE_WRONG "PUT with a WRONG credential was ACCEPTED (HTTP $code)"; tfail=$((tfail+1)) ;;
    *)       d_bad FILES_AUTH_WRITE_WRONG "PUT with a wrong credential answered HTTP $code (expected 401/403)"; tfail=$((tfail+1)) ;;
  esac
  rm -f "$uprobe" 2>/dev/null

  # freshness: a file written DIRECTLY to disk (exactly how agents deliver
  # output) must become visible over WebDAV fast. Prime the directory cache
  # with a 404 for the future name FIRST — on a cold cache even the broken
  # 5-minute default answers instantly, and this check exists to catch it.
  if $disk_ok; then
    df_register T file "$fkey"
    code=$(doctor_fs_code real -r 0-0 "$DF_URL/$fkey")
    if [ "$code" = "404" ]; then
      # Revalidate the pinned folder identity IMMEDIATELY before the direct
      # write — the resolve-time check is several network round-trips old.
      if doctor_files_dir_ok; then
        # O_CREAT lands the name before the write can fail, so the create COUNTS
        # from here on whether or not it reports OK.
        DF_WROTE=true
        out=$(python3 - "$DF_DIR" "$fkey" <<'PY' 2>/dev/null
import os, secrets, sys
p = os.path.join(sys.argv[1], sys.argv[2])
fd = os.open(p, os.O_CREAT | os.O_EXCL | os.O_WRONLY | getattr(os, "O_NOFOLLOW", 0), 0o644)
os.write(fd, ("conduck-check freshness " + secrets.token_hex(16) + "\n").encode())
os.fsync(fd)
os.close(fd)
print("OK")
PY
)
      else
        out="UNSAFE"
      fi
      if [ "$out" = "UNSAFE" ]; then
        d_bad FILES_READ_FRESH "the folder failed its identity check right before the direct write — refusing"
        terr=$((terr+1))
      elif [ "$out" = "OK" ]; then
        local t0 now elapsed first=""
        t0=$(python3 -c 'import time; print("%.3f" % time.monotonic())')
        while :; do
          code=$(doctor_fs_code real -r 0-0 "$DF_URL/$fkey")
          now=$(python3 -c 'import time; print("%.3f" % time.monotonic())')
          elapsed=$(awk -v a="$t0" -v b="$now" 'BEGIN{printf "%.2f", b - a}')
          case "$code" in 2??) first="$elapsed"; break ;; esac
          if awk -v e="$elapsed" 'BEGIN{exit !(e > 5.0)}'; then break; fi
          sleep 0.25
        done
        if [ -n "$first" ] && awk -v e="$first" 'BEGIN{exit !(e <= 2.0)}'; then
          d_ok FILES_READ_FRESH "a file written directly to disk was visible over WebDAV in ${first}s"
        elif [ -n "$first" ]; then
          d_bad FILES_READ_FRESH "direct disk write reached WebDAV after ${first}s — over the 2.0s freshness limit"
          d_say FILES_READ_FRESH "(The file was already complete on disk; WebDAV directory caching delayed visibility."
          d_say FILES_READ_FRESH " Configure rclone serve webdav with --dir-cache-time 1s or lower.)"
          tfail=$((tfail+1))
        else
          d_bad FILES_READ_FRESH "direct disk write was still invisible through WebDAV after 5.0s"
          d_say FILES_READ_FRESH "(This is exactly how agent-written output files go missing in the app. Configure"
          d_say FILES_READ_FRESH " rclone serve webdav with --dir-cache-time 1s or lower, then re-run me.)"
          tfail=$((tfail+1))
        fi
      else
        d_bad FILES_READ_FRESH "could not create the freshness file directly on disk"; terr=$((terr+1))
      fi
    elif [ "$code" = "200" ] || [ "$code" = "206" ]; then
      d_bad FILES_READ_FRESH "a file with the check's random name already exists — collision, refusing"; terr=$((terr+1))
    else
      d_bad FILES_READ_FRESH "the priming request answered HTTP $code (expected 404 for a not-yet-created name)"; tfail=$((tfail+1))
    fi
  else
    note "  [FILES_READ_FRESH] skipped — direct-disk checks are disabled this run."
  fi

  # ranged-probe compatibility: the app's existence probe is Range: bytes=0-0.
  if $wt_ok; then
    code=$(doctor_fs_code real -D "$hdrs" -r 0-0 "$DF_URL/$wkey")
    case "$code" in
      206)
        if grep -qi '^content-range:' "$hdrs" 2>/dev/null; then
          d_ok FILES_PROBE_COMPAT "ranged probe honored (206 + Content-Range) — exactly what the app sends"
        else
          d_bad FILES_PROBE_COMPAT "206 without a Content-Range header"; tfail=$((tfail+1))
        fi ;;
      200)
        d_ok FILES_PROBE_COMPAT "ranged probe answered 200 (Range ignored) — compatible; the app treats 200 and 206 both as present"
        d_say FILES_PROBE_COMPAT "(degradation note: the whole file rides every probe — honoring Range: bytes=0-0 is cheaper)" ;;
      416) d_bad FILES_PROBE_COMPAT "Range: bytes=0-0 on a non-empty file answered 416 — the app's probe would see this as missing"; tfail=$((tfail+1)) ;;
      *)   d_bad FILES_PROBE_COMPAT "ranged probe answered HTTP $code"; tfail=$((tfail+1)) ;;
    esac
    rm -f "$hdrs" 2>/dev/null
  else
    note "  [FILES_PROBE_COMPAT] skipped — need the write-through file to probe against."
  fi

  # nested folders: capability, not a mandate — the app falls back to flat
  # keys on a conclusive rejection. Only an indeterminate answer is trouble.
  df_register T file "$nkey/n.txt"
  df_register T dir "$nkey"
  code=$(doctor_fs_write real -X MKCOL "$DF_URL/$nkey/")
  case "$code" in
    201)
      printf 'conduck-check nested probe\n' > "$tmp"
      code=$(doctor_fs_write real -T "$tmp" "$DF_URL/$nkey/n.txt")
      body=$(doctor_curl_fs real "$DF_URL/$nkey/n.txt" 2>/dev/null) || body=""
      # Three outcomes, three different repairs: the PUT inside the new folder
      # being refused, the file reading back empty, and it reading back wrong.
      # A single message carrying only the PUT's status prints "(HTTP 201)" next
      # to a failure, which reads as if the 201 is the problem — so the status
      # stays where it IS the finding, and the read-back failures name the read
      # instead.
      if [ "${code#2}" = "$code" ]; then
        d_bad FILES_NESTED "MKCOL created the folder, but a PUT inside it answered HTTP $code"; tfail=$((tfail+1))
      elif [ "$body" = "conduck-check nested probe" ]; then
        d_ok FILES_NESTED "nested folders SUPPORTED (MKCOL + PUT + GET round-trip)"
      elif [ -z "$body" ]; then
        d_bad FILES_NESTED "the nested PUT succeeded (HTTP $code), but reading the file back returned no bytes"; tfail=$((tfail+1))
      else
        d_bad FILES_NESTED "the nested PUT succeeded (HTTP $code), but the file reads back with different content"; tfail=$((tfail+1))
      fi ;;
    403|405|409|501)
      d_ok FILES_NESTED "nested folders REJECTED by the server (HTTP $code) — fine: the app falls back to flat keys" ;;
    000) d_bad FILES_NESTED "no answer to MKCOL — transport trouble, not a capability verdict"; tfail=$((tfail+1)) ;;
    *)   d_bad FILES_NESTED "MKCOL answered HTTP $code — neither support nor a clean rejection"; tfail=$((tfail+1)) ;;
  esac
  rm -rf "$tmpd" 2>/dev/null

  if   [ "$terr" -gt 0 ];  then DOCTOR_FILE_TRANSPORT="ERROR"
  elif [ "$tfail" -gt 0 ]; then DOCTOR_FILE_TRANSPORT="FAIL"
  else DOCTOR_FILE_TRANSPORT="PASS"; fi
  $disk_ok || DF_DEV_INO=""   # poison the pin: later tiers must not touch the disk either
  return 0
}

# Tier 2 + 3 — the agent sentinel and the app-shaped delivery probe.
# Sets DOCTOR_FILE_ACCESS + DOCTOR_FILE_E2E.
doctor_files_agent() {
  if ! doctor_files_dir_ok; then
    note "  [FILE_COPY_BYTES] [FILE_REPLY_REFERENCE] [FILE_E2E] skipped — the shared folder failed its identity check."
    return 0
  fi
  if [ -z "${MODELS_FIRST_ID:-}" ]; then
    note "  [FILE_COPY_BYTES] skipped — /v1/models offered no usable model id (already failed above)."
    return 0
  fi
  local ih okey ikey used_key content tmp code out
  ih=$(python3 -c 'import secrets; print(secrets.token_hex(4))' 2>/dev/null)
  content=$(python3 -c 'import secrets; print(secrets.token_hex(32))' 2>/dev/null)
  tmp=$(mktemp "${TMPDIR:-/tmp}/conduck-check.XXXXXX" 2>/dev/null) || tmp=""
  if [ -z "$ih" ] || [ -z "$content" ] || [ -z "$tmp" ]; then
    d_bad FILE_COPY_BYTES "could not stage the sentinel (python3/mktemp failed)"
    DOCTOR_FILE_ACCESS="ERROR"; return 0
  fi
  okey="output-$DF_RUN.txt"
  ikey="conduck-check-$DF_RUN/${ih}__input-$DF_RUN.txt"
  printf '%s\n' "$content" > "$tmp"

  # Input rides the REAL lane shape: a per-conversation folder + the
  # <8hex>__<name> stored-key form. MKCOL unsupported -> the app's flat
  # fallback, and the doctor follows it.
  df_register A dir "conduck-check-$DF_RUN"
  used_key="$ikey"
  code=$(doctor_fs_write real -X MKCOL "$DF_URL/conduck-check-$DF_RUN/")
  if [ "$code" = "201" ]; then
    df_register A file "$ikey"
    code=$(doctor_fs_write real -T "$tmp" "$DF_URL/$ikey")
  else
    used_key="conduck-check-$DF_RUN-${ih}__input-$DF_RUN.txt"
    df_register A file "$used_key"
    code=$(doctor_fs_write real -T "$tmp" "$DF_URL/$used_key")
  fi
  if [ "${code#2}" = "$code" ]; then
    # WebDAV upload failed — place the input directly on disk so the agent
    # tier can still produce evidence (independence from a broken transport).
    # Carry the upload's status into every message below: HTTP 403 (a read-only
    # folder or a rejected credential), a 5xx (out of space, a server fault) and
    # no answer at all (nothing listening) are three different repairs, and this
    # status is the only thing that separates them.
    local uwhy="HTTP $code"
    [ "$code" = "000" ] && uwhy="no answer"
    # Revalidate the pin immediately before this direct write, same as the
    # freshness create: the entry check is several probes old by now.
    doctor_files_dir_ok || {
      note "  [FILE_COPY_BYTES] skipped — the folder failed its identity check before the fallback write."
      rm -f "$tmp" 2>/dev/null
      return 0
    }
    # Same O_CREAT rule as the freshness write: the name can exist even when the
    # write below reports a failure.
    DF_WROTE=true
    out=$(python3 - "$DF_DIR" "$used_key" "$tmp" <<'PY' 2>/dev/null
import os, sys
p = os.path.join(sys.argv[1], sys.argv[2])
d = os.path.dirname(p)
if not os.path.isdir(d):
    os.makedirs(d, exist_ok=True)
data = open(sys.argv[3], "rb").read()
fd = os.open(p, os.O_CREAT | os.O_EXCL | os.O_WRONLY | getattr(os, "O_NOFOLLOW", 0), 0o644)
os.write(fd, data); os.fsync(fd); os.close(fd)
print("OK")
PY
)
    if [ "$out" != "OK" ]; then
      note "  [FILE_COPY_BYTES] skipped — the input sentinel's WebDAV upload failed ($uwhy) and the direct disk write failed too (transport already red above)."
      rm -f "$tmp" 2>/dev/null
      return 0
    fi
    note "  (input sentinel placed directly on disk — the WebDAV upload path failed ($uwhy), see tier 1.)"
  fi

  # The output name must not pre-exist — and the WebDAV 404 doubles as cache
  # priming (same rationale as FILES_READ_FRESH: a cold directory cache must
  # not hand the adapter a freshness pass it didn't earn).
  df_register A file "$okey"
  code=$(doctor_fs_code real -r 0-0 "$DF_URL/$okey")
  if [ "$code" != "404" ] && [ "$code" != "401" ] && [ "$code" != "403" ]; then
    if [ "$code" = "000" ]; then
      d_bad FILE_COPY_BYTES "no answer from the file server before the turn — cannot prove the output name is free"
    else
      d_bad FILE_COPY_BYTES "the output name already answers HTTP $code before the turn ran — collision, refusing"
    fi
    DOCTOR_FILE_ACCESS="ERROR"; rm -f "$tmp" 2>/dev/null; return 0
  fi

  local payload
  payload=$(DF_MODEL="$MODELS_FIRST_ID" DF_OKEY="$okey" DF_IKEY="$used_key" DF_INAME="input-$DF_RUN.txt" \
            python3 - <<'PY' 2>/dev/null
import json, os
e = os.environ
task = ("Copy the input file listed below to a new file named %s at the ROOT of your "
        "working directory, byte-for-byte. Then confirm in one short sentence that names "
        "the new file." % e["DF_OKEY"])
# GOLDEN WIRE TEXT — byte-identical to the app (ConverseRequest.swift:
# spliceServerFileRefs + fileDeliveryInstruction). The doctor must certify the
# prompt shape Conduck actually sends, not a paraphrase.
ref = ("The following file(s) are in your working directory — use them for this request. "
       "Each input lives under its conversation folder at the path shown:\n"
       "- %s (saved as %s)" % (e["DF_INAME"], e["DF_IKEY"]))
instr = ("[Conduck file transfer] To return a file, write it to the root of your working "
         "directory and state its exact filename in plain text in your reply. Attachment "
         "directives (MEDIA: lines or similar) do not reach this user — only files named "
         "in plain reply text are delivered.")
print(json.dumps({"model": e["DF_MODEL"],
                  "messages": [{"role": "user", "content": task + "\n\n" + ref + "\n\n" + instr}],
                  "stream": False}))
PY
)
  if [ -z "$payload" ]; then
    d_bad FILE_COPY_BYTES "could not build the sentinel request (python3 failed)"
    DOCTOR_FILE_ACCESS="ERROR"; rm -f "$tmp" 2>/dev/null; return 0
  fi

  say ""
  say "  The file sentinel — one real turn against model '$(safe_display "$MODELS_FIRST_ID" 60)': the agent must copy a"
  say "  small input file to the folder root and name the output in its reply. Agents can be slow;"
  say "  I wait up to 5 minutes…"
  DF_AGENT_RAN=true
  local turn_ok=false shape_reason=""
  if doctor_chat_eval "$payload"; then turn_ok=true; else shape_reason="$DCE_REASON"; fi

  # THE APP-SHAPED MOMENT: one ranged existence probe, immediately, no retry —
  # exactly what Conduck fires when the reply lands (headers only).
  local probe_code
  probe_code=$(doctor_fs_code real -r 0-0 "$DF_URL/$okey")
  out=$(doctor_files_disk_verify "$okey" "$tmp")
  local copy_ok=false
  [ "$out" = "OK" ] && copy_ok=true

  if ! $turn_ok && [ "${DCE_HINT:-}" = "transfer" ]; then
    d_bad FILE_COPY_BYTES "the file turn never completed ($shape_reason)"
    d_say FILE_COPY_BYTES "(the lane was not graded — file_access stays NOT_RUN; fix the transport first, then re-run)"
    rm -f "$tmp" 2>/dev/null
    return 0
  fi

  if $turn_ok && $copy_ok; then
    d_ok FILE_COPY_BYTES "model '$(safe_display "$MODELS_FIRST_ID" 60)' copied the sentinel byte-for-byte to the folder root (${DCC_TIME:-?}s)"
  elif $turn_ok; then
    case "$out" in
      MISSING)
        d_bad FILE_COPY_BYTES "agent reply arrived before a complete byte-identical output file existed"
        d_say FILE_COPY_BYTES "(Conduck probes as soon as the reply lands: wait for the agent's file tools to finish"
        d_say FILE_COPY_BYTES " before returning HTTP 200 — no grace period or retry was applied. If the engine has"
        d_say FILE_COPY_BYTES " no file tools or a different working folder, that is the real finding: this lane"
        d_say FILE_COPY_BYTES " cannot deliver files as configured.)"
        ;;
      MISMATCH)   d_bad FILE_COPY_BYTES "an output file exists but is NOT byte-identical to the input" ;;
      NOTREGULAR) d_bad FILE_COPY_BYTES "the output exists but is not a regular file — refusing it" ;;
      TOOBIG)     d_bad FILE_COPY_BYTES "the output is implausibly large — refusing to read it" ;;
      *)          d_bad FILE_COPY_BYTES "could not verify the output safely ($out)" ;;
    esac
  else
    d_bad FILE_COPY_BYTES "the file turn's HTTP reply is malformed — $shape_reason"
    $copy_ok && d_say FILE_COPY_BYTES "(the file DID land correctly — but a reply Conduck can't parse means it never finds out)"
  fi

  local ref_ok=false
  if $turn_ok; then
    out=$(printf '%s' "$DCC_BODY" | DF_OKEY="$okey" DF_IKEY="$used_key" python3 -c '
import json, os, re, sys
d = json.load(sys.stdin)
reply = d["choices"][0]["message"]["content"]
# Mirror of the app detector (FileTransferOutputDetector): filename-shaped
# tokens -> allowlisted extensions -> dedup by first appearance -> drop the
# echoed inbound stored key (full key AND its last path component) -> cap 5.
allow = {"pdf","csv","tsv","json","xml","yaml","yml","txt","md","log","zip","tar","gz",
         "png","jpg","jpeg","gif","svg","xlsx","xls","docx","doc","pptx","html",
         "py","js","ts","sh","sql","parquet"}
seen, ordered = set(), []
for tok in re.findall(r"[A-Za-z0-9._-]+\.[A-Za-z0-9]{1,8}", reply):
    ext = tok.rsplit(".", 1)[1].lower()
    if ext in allow and tok not in seen:
        seen.add(tok); ordered.append(tok)
ik = os.environ["DF_IKEY"]
inbound = {ik, ik.rsplit("/", 1)[-1]}
outputs = [t for t in ordered if t not in inbound][:5]
print("YES" if os.environ["DF_OKEY"] in outputs else "NO")' 2>/dev/null)
    if [ "$out" = "YES" ]; then
      d_ok FILE_REPLY_REFERENCE "the reply names the output file where Conduck's detector will find it"
      ref_ok=true
    else
      d_bad FILE_REPLY_REFERENCE "the reply does not name the output file detectably"
      d_say FILE_REPLY_REFERENCE "(Conduck scans reply text for allowlisted filenames — the first 5 candidates after"
      d_say FILE_REPLY_REFERENCE " dropping echoed input names — and probes only those. A correct file the app cannot"
      d_say FILE_REPLY_REFERENCE " DISCOVER is not a working lane: state the exact filename in plain reply text.)"
    fi
  fi

  if $copy_ok; then
    if [ "$probe_code" = "200" ] || [ "$probe_code" = "206" ]; then
      # Discoverable at the app's moment — now the byte-faithful download.
      # A separate step on purpose: the app's landing probe reads headers only,
      # so the full GET proves fidelity without claiming to BE landing behavior.
      local dl; dl=$(doctor_curl_fs real "$DF_URL/$okey" 2>/dev/null) || dl=""
      if [ "$dl" = "$content" ]; then
        d_ok FILE_E2E "output discoverable the instant the reply landed (HTTP $probe_code) and downloads byte-faithful"
        DOCTOR_FILE_E2E="PASS"
      else
        d_bad FILE_E2E "the probe saw the file, but the downloaded bytes differ from the on-disk output"
        DOCTOR_FILE_E2E="FAIL"
      fi
    else
      d_bad FILE_E2E "agent output existed on disk when the reply landed, but Conduck's immediate ranged WebDAV probe returned HTTP $probe_code"
      d_say FILE_E2E "(Agent file creation completed; the failure is disk-to-WebDAV visibility, not agent timing —"
      d_say FILE_E2E " see FILES_READ_FRESH and --dir-cache-time.)"
      DOCTOR_FILE_E2E="FAIL"
    fi
  else
    note "  [FILE_E2E] skipped — no verified output file to probe."
  fi

  if $turn_ok && $copy_ok && $ref_ok; then DOCTOR_FILE_ACCESS="PASS"; else DOCTOR_FILE_ACCESS="FAIL"; fi
  [ "${MODELS_ID_COUNT:-0}" -gt 1 ] 2>/dev/null \
    && note "  (file_access grades model '$(safe_display "$MODELS_FIRST_ID" 60)' only — other advertised models may differ.)"
  rm -f "$tmp" 2>/dev/null
  return 0
}

# Graded cleanup: WebDAV DELETE capability + proof that every registered
# artifact is gone. Unproven cleanup is ERROR on the owning meter — never
# silence. Exact names only, never a glob.
doctor_files_delete() {
  local entry kind rel code webdav_ok=true del_unsupported=""
  for entry in ${DF_ARTS[@]+"${DF_ARTS[@]}"}; do
    kind=$(printf '%s' "$entry" | cut -f2); rel=$(printf '%s' "$entry" | cut -f3)
    [ "$kind" = "file" ] || continue
    code=$(doctor_fs_code real -X DELETE "$DF_URL/$rel")
    case "$code" in 2??|404) ;; 403|405|501) webdav_ok=false; del_unsupported="$code" ;; *) webdav_ok=false ;; esac
  done
  for entry in ${DF_ARTS[@]+"${DF_ARTS[@]}"}; do
    kind=$(printf '%s' "$entry" | cut -f2); rel=$(printf '%s' "$entry" | cut -f3)
    [ "$kind" = "dir" ] || continue
    code=$(doctor_fs_code real -X DELETE "$DF_URL/$rel/")
    case "$code" in 2??|404) ;; 403|405|501) webdav_ok=false; del_unsupported="$code" ;; *) webdav_ok=false ;; esac
  done
  # Ground truth + guarded direct removal of anything that remains. Success
  # must be PROVEN: the checker prints a VERIFIED sentinel as its LAST line
  # only after the whole walk completed — a checker that dies mid-list can
  # never read as "clean" (empty output without the sentinel is a failure,
  # not a pass; the trailing-sentinel order is what makes a partial crash
  # unspoofable).
  local leftovers="" vout=""
  if doctor_files_dir_ok; then
    vout=$(for entry in ${DF_ARTS[@]+"${DF_ARTS[@]}"}; do printf '%s\n' "$entry"; done \
      | python3 -c '
import os, stat, sys
root = sys.argv[1]
left = []
dirs = []
for line in sys.stdin.read().splitlines():
    try:
        tier, kind, rel = line.split("\t", 2)
    except ValueError:
        continue
    if not rel.split("/", 1)[0].startswith(("conduck-check-", "output-")):
        left.append(tier + " " + rel); continue
    p = os.path.join(root, rel)
    rp = os.path.realpath(p)
    if not (rp == root or rp.startswith(root + os.sep)):
        left.append(tier + " " + rel); continue
    if kind == "dir":
        dirs.append((tier, p, rel)); continue
    try:
        st = os.lstat(p)
    except FileNotFoundError:
        continue
    except Exception:
        left.append(tier + " " + rel); continue
    try:
        if stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode):
            os.unlink(p)
        else:
            left.append(tier + " " + rel); continue
    except Exception:
        left.append(tier + " " + rel)
for tier, p, rel in dirs:
    if os.path.isdir(p):
        try:
            os.rmdir(p)
        except OSError:
            left.append(tier + " " + rel)
for x in left:
    print(x)
print("VERIFIED")' "$DF_DIR" 2>/dev/null)
    if [ "$vout" = "VERIFIED" ]; then leftovers=""
    elif [ "${vout%$'\n'VERIFIED}" != "$vout" ]; then leftovers="${vout%$'\n'VERIFIED}"
    else leftovers="? the cleanup checker itself failed — nothing proven"
    fi
  else
    leftovers="? folder identity changed mid-run — nothing removed directly"
  fi
  if [ -z "$leftovers" ]; then
    if $webdav_ok; then
      d_ok FILES_DELETE "WebDAV DELETE works — every check artifact removed and verified gone"
    elif [ -n "$del_unsupported" ]; then
      d_ok FILES_DELETE "DELETE unsupported (HTTP $del_unsupported) — artifacts removed directly on disk instead"
      d_say FILES_DELETE "(the app treats WebDAV deletion as best-effort, so this is a degradation, not a failure)"
    else
      d_ok FILES_DELETE "check artifacts removed (some DELETE requests failed; direct disk cleanup covered them)"
    fi
    DF_ARTS=()
  else
    d_bad FILES_DELETE "check artifacts could NOT all be removed"
    d_say FILES_DELETE "(remove anything starting with 'conduck-check-$DF_RUN' — and 'output-$DF_RUN.txt' — from the shared folder by hand)"
    case "$leftovers" in *"T "*|\?*) DOCTOR_FILE_TRANSPORT="ERROR" ;; esac
    case "$leftovers" in *"A "*|\?*)
      DOCTOR_FILE_ACCESS="ERROR"
      case "$DOCTOR_FILE_E2E" in PASS|FAIL) DOCTOR_FILE_E2E="ERROR" ;; esac ;;
    esac
  fi
  # Late-write backstop: a broken adapter can answer 200 and write the output
  # AFTER cleanup. One bounded second look — verdicts above stay unchanged.
  if $DF_AGENT_RAN && doctor_files_dir_ok; then
    sleep 2
    python3 -c '
import os, sys
p = os.path.join(sys.argv[1], sys.argv[2])
try:
    st = os.lstat(p)
    import stat
    if stat.S_ISREG(st.st_mode):
        os.unlink(p)
        print("LATE")
except FileNotFoundError:
    pass
except Exception:
    pass' "$DF_DIR" "output-$DF_RUN.txt" 2>/dev/null | grep -q LATE \
      && note "  (the output file appeared AFTER cleanup — removed; the adapter answered before its file tools finished)"
  fi
  return 0
}

# Best-effort backstop for early deaths and signals — the graded
# doctor_files_delete empties DF_ARTS on success, so this only fires mid-run.
doctor_files_cleanup_backstop() {
  [ "${#DF_ARTS[@]}" -gt 0 ] 2>/dev/null || return 0
  [ -n "$DF_URL" ] || return 0
  # Registration precedes creation, so a populated DF_ARTS proves only that the
  # run INTENDED those names. DF_WROTE still false means nothing ever answered a
  # mutating request and no direct disk create ran: there is nothing to remove,
  # and sending the operator to search their agent's working folder for a file
  # that cannot exist is a false alarm (a silent lane answers no DELETE either).
  $DF_WROTE || return 0
  local entry kind rel
  for entry in ${DF_ARTS[@]+"${DF_ARTS[@]}"}; do
    kind=$(printf '%s' "$entry" | cut -f2); rel=$(printf '%s' "$entry" | cut -f3)
    if [ "$kind" = "dir" ]; then doctor_curl_fs real -X DELETE "$DF_URL/$rel/" >/dev/null 2>&1 || true
    else doctor_curl_fs real -X DELETE "$DF_URL/$rel" >/dev/null 2>&1 || true; fi
  done
  warn "Adapter check exited mid-flight — attempted removal of its conduck-check-$DF_RUN files; check the shared folder if any remain."
}

run_doctor_files() {
  say ""
  say "  ${BOLD}--files — the file-lane probes.${RESET} Three meters: file_transport (this host's WebDAV <->"
  say "  disk lane), file_access (the selected agent copies a sentinel and names it), file_e2e"
  say "  (the app-shaped immediate delivery probe). This is the one adapter-check profile that MUTATES:"
  say "  small conduck-check-* files are written to and removed from the shared folder."
  DF_RUN=$(python3 -c 'import secrets; print(secrets.token_hex(4))' 2>/dev/null)
  if [ -z "$DF_RUN" ]; then
    d_bad FILES_CONFIG "could not generate a run nonce (python3 failed)"
    DOCTOR_FILE_TRANSPORT="ERROR"; return 0
  fi
  if ! doctor_files_resolve; then
    DOCTOR_FILE_TRANSPORT="ERROR"
    return 0
  fi
  doctor_files_transport
  doctor_files_agent
  doctor_files_delete
  return 0
}

# The frozen machine line (schema=3) — printed as the LAST line of EVERY
# adapter-check exit, green, red, or an early die: fixed field order, ASCII enums,
# no ANSI. Consumers (build loops, CI, the builder guide's definition of
# done) key on this + the exit code — never on check counts, which change
# between harness versions. Any grammar change bumps schema=; renaming the
# prefix CONDUCK_DOCTOR -> CONDUCK_CHECK_ADAPTER is such a change, which is why
# schema went 2 -> 3. Exactly ONE summary line is emitted (consumers use
# `tail -1`), so the retired prefix is never dual-emitted. The three file
# meters are NOT_REQUESTED without --files; with it they grade independently
# (NOT_RUN|PASS|FAIL|ERROR — see the --files block above).
doctor_summary() { # doctor_summary <exit-code>
  local rc="${1:-1}" core="NOT_RUN"
  if $DOCTOR_CORE_RAN; then
    core="PASS"
    [ "$DOCTOR_CORE_FAILS" -gt 0 ] && core="FAIL"
  fi
  printf 'CONDUCK_CHECK_ADAPTER schema=3 contract=v1 revision=%s harness=%s profile=%s core=%s history_image=%s stream=%s image_input=%s file_transport=%s file_access=%s file_e2e=%s checks=%s failed=%s exit=%s\n' \
    "$DOCTOR_CONTRACT_REV" "$VERSION" "$DOCTOR_PROFILE" "$core" \
    "$DOCTOR_HISTORY_IMAGE" "$DOCTOR_STREAM" "$DOCTOR_IMAGE_INPUT" \
    "$DOCTOR_FILE_TRANSPORT" "$DOCTOR_FILE_ACCESS" "$DOCTOR_FILE_E2E" \
    "$DOCTOR_CHECKS" "$DOCTOR_FAILS" "$rc"
}

# EXIT dispatcher: chained onto the wizard's on_exit backstop (a no-op for the
# doctor, which never applies exposures — but replacing an armed trap silently
# is how cleanups get lost). $? must be captured FIRST. INT/TERM/HUP are
# routed through exit because macOS bash 3.2 skips the EXIT trap on an
# unhandled signal — the summary line must ride even a Ctrl-C.
doctor_on_exit() {
  local rc=$?
  on_exit
  $DOCTOR_FILES && doctor_files_cleanup_backstop
  doctor_summary "$rc"
}

run_doctor() {
  # The machine summary must ride EVERY exit (frozen schema=3 grammar) — arm
  # it before anything can die. Flag-combination errors happen before this
  # function and are non-runs by definition: no doctor started, no summary.
  DOCTOR_PROFILE="basic"; $DOCTOR_DEEP && DOCTOR_PROFILE="deep"
  # --files was REQUESTED: the meters flip NOT_REQUESTED -> NOT_RUN here, so
  # even an early die reports "asked for, never executed" — never "not asked".
  if $DOCTOR_FILES; then
    DOCTOR_FILE_TRANSPORT="NOT_RUN"; DOCTOR_FILE_ACCESS="NOT_RUN"; DOCTOR_FILE_E2E="NOT_RUN"
  fi
  trap doctor_on_exit EXIT
  trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
  # Runtime dependencies are checked only AFTER the summary trap is armed.
  # A missing curl/python3 is exit 1 + a final NOT_RUN machine line, never a
  # silent pre-check exit and never an exit-2 CLI usage error.
  preflight

  say "${BOLD}conduck-connect $VERSION — --check-adapter${RESET}"
  say "Checks whether an adapter built for Conduck follows the rules at"
  say "${BOLD}conduck.com/setup/adapter/v1/${RESET} — real requests, graded strictly against contract"
  if $DOCTOR_FILES; then
    say "revision $DOCTOR_CONTRACT_REV. The chat checks change no host configuration; --files then writes and"
    say "removes small conduck-check-* files in the configured shared folder, and asks the"
    say "selected agent to copy one — I clean up after myself, but I can't promise a"
    say "MISBEHAVING agent touches nothing else."
  else
    say "revision $DOCTOR_CONTRACT_REV. Changes no host configuration; sends live adapter turns"
    say "that may consume compute or enter server-side history."
  fi
  note "Building your own adapter? Loop me from a shell — exit code 0 means every check passed."
  if interactive_terminal; then
    note "A CONDUCK_CHECK_ADAPTER machine summary prints before the optional setup handoff."
  else
    note "The last line is always a CONDUCK_CHECK_ADAPTER machine summary — scripts key on it."
  fi

  # Target: the positional URL if one was given, else ask.
  if [ -n "$CHECK_URL" ]; then
    GW_URL=$(doctor_accept_url "$CHECK_URL") \
      || usage_die "Can't test '$CHECK_URL' — use https://… (or http://127.0.0.1:<port> for a local test)."
  else
    say ""
    GW_URL=$(doctor_ask_url) || die "$NO_ANSWER"
  fi
  apply_gateway_url_normalization

  # Token: $CONDUCK_TOKEN (scripted re-runs) or a hidden prompt. Never argv.
  # Set-but-empty is an EXPLICIT keyless declaration; unset means "ask". A
  # redirected run must never infer no-auth from a missing answer, or the adapter
  # gets graded keyless and every AUTH_* check reports a failure the operator
  # never chose.
  if [ -n "${CONDUCK_TOKEN+set}" ] && [ -z "$CONDUCK_TOKEN" ]; then
    GW_AUTH="none"; GW_TOKEN=""
    note "Keyless by explicit \$CONDUCK_TOKEN=."
  elif [ -n "${CONDUCK_TOKEN:-}" ]; then
    GW_AUTH="bearer"; GW_TOKEN="$CONDUCK_TOKEN"
    note "Using the bearer token from \$CONDUCK_TOKEN."
  else
    say ""
    note "Tip: export CONDUCK_TOKEN=<token> to skip this prompt on re-runs."
    GW_TOKEN=$(ask_secret "Bearer token the server expects (Enter if it has none)") \
      || die "No token given and no answer possible (the input ended). Set CONDUCK_TOKEN=<token> for a scripted run, or set CONDUCK_TOKEN= (empty) to declare keyless deliberately."
    if [ -n "$GW_TOKEN" ]; then GW_AUTH="bearer"; else GW_AUTH="none"; fi
  fi
  # Plain TLS validation, the same rule the app applies. For a certificate this
  # machine doesn't trust, run it on the server itself against http://127.0.0.1.
  TRANSPORT=""

  head_ "Adapter check — $GW_URL"

  if ! doctor_models_check; then
    say ""
    bad "Adapter check: FAIL — /v1/models isn't answering correctly, so I stopped here."
    say "  Fix that first (every other check would only fail the same way), then re-run me."
    say "  The contract, with a copy-paste self-test: ${BOLD}https://conduck.com/setup/adapter/v1/${RESET}"
    # The same way out as the full FAIL below: this envelope rule is stricter than
    # the app's own Test Connection (Content-Type is graded, an empty "data" is a
    # failure), so third-party software can stop here and still work with the app.
    doctor_not_yours_hint
    exit 1
  fi

  doctor_auth_checks

  say ""
  say "  Now the chat checks — several real turns, each graded against the contract's response"
  say "  rules (strict JSON, one choice, string content, Content-Type application/json). The"
  say "  first goes deliberately WITHOUT a \"model\" field, WITH an unknown extra field, and"
  say "  \"stream\": false — all three must be tolerated. Agents can be slow; I wait up to 5"
  say "  minutes per turn…"
  local payload
  payload=$(python3 -c 'import json
print(json.dumps({"messages": [{"role": "user", "content": "Reply with exactly: pong"}],
                  "stream": False, "conduck_check_probe": True}))') \
    || die "Could not build the test request (python3 failed)."
  doctor_chat_check CHAT_BASIC "chat: absent model + unknown field + stream:false" "$payload" plain || true

  doctor_model_selection_check || true

  # The anti-poisoning probe, in the REAL failure shape this rule exists for:
  # a photo turn that got no assistant reply (two consecutive user messages),
  # then a text-only follow-up. The adapter must answer — forward the earlier
  # image, or swap in the contract's disclosure text; rejecting the request is
  # how one bad photo used to kill every later turn of a conversation.
  payload=$(python3 -c 'import json, zlib, struct, base64
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 0, 0, 0, 0)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(b"\x00\xff")) + chunk(b"IEND", b"")
uri = "data:image/png;base64," + base64.b64encode(png).decode()
print(json.dumps({"messages": [
    {"role": "user", "content": [
        {"type": "text", "text": "What is in this photo?"},
        {"type": "image_url", "image_url": {"url": uri}}]},
    {"role": "user", "content": "Reply with exactly: pong"}], "stream": False}))') \
    || die "Could not build the history-image test request (python3 failed)."
  # The meter comes from doctor_capability_meter, never from the check's exit
  # status: that status answers "did this check go red", and the meter answers
  # "what did this run MEASURE". They differ on exactly one path — a probe that
  # failed for a cause this run could not tell apart from another rule's failure
  # — and there the honest meter is NOT_RUN. A red verdict line, failed= and
  # exit=1 still carry the run-level verdict, so nothing is softened.
  doctor_chat_check HISTORY_IMAGE "chat: image in an EARLIER message, newest turn text-only" "$payload" history
  DOCTOR_HISTORY_IMAGE=$(doctor_capability_meter)

  payload=$(python3 -c 'import json
print(json.dumps({"messages": [{"role": "user", "content": "Reply with exactly: pong"}],
                  "stream": True}))') \
    || die "Could not build the stream test request (python3 failed)."
  doctor_chat_check STREAM_SYNC "chat: \"stream\": true still answers one JSON object" "$payload" stream
  DOCTOR_STREAM=$(doctor_capability_meter)

  if $DOCTOR_DEEP; then
    say ""
    say "  --deep: the semantic image probe — a locally generated PNG showing 4 digits rides the"
    say "  newest message. A reply carrying those digits proves the engine truly SAW it; an honest"
    say "  HTTP 400 decline with code \"image_unsupported\" also passes. Answering while silently"
    say "  ignoring the image is the one forbidden move."
    doctor_image_input_check || true
  fi

  $DOCTOR_FILES && run_doctor_files

  say ""
  if [ "$DOCTOR_FAILS" = "0" ]; then
    ok "Adapter check: PASS — $DOCTOR_CHECKS/$DOCTOR_CHECKS checks green. This adapter follows Conduck's rules."
    if ! interactive_terminal; then
      say "  To set it up later:  ${BOLD}bash conduck-connect.sh --setup${RESET}"
    fi
    return 0
  fi
  bad "Adapter check: FAIL — $DOCTOR_FAILS of $DOCTOR_CHECKS checks failed."
  say "  Every rule above, with a copy-paste self-test:  ${BOLD}https://conduck.com/setup/adapter/v1/${RESET}"
  doctor_not_yours_hint
  exit 1
}
# -------------------------------------------------------------- --check-server --
#
# App-compatibility probe: does this OpenAI-compatible server speak the core wire
# the current Apple Conduck app needs? It matches request/response acceptance at
# the directly addressed endpoint. It deliberately does not follow redirects:
# forwarding a user credential to a Location target is outside this diagnostic's
# promise, so users must supply the final server URL. This is NOT the
# adapter contract: --check-adapter grades adapters BUILT for Conduck, and generic
# servers fail it on intentional Conduck-specific rules the app itself never
# exercises on the wire (stream:true override, negative-auth enforcement,
# model_not_found status vocabulary). Scoring checks: models envelope (the
# app's probe), chat decode (the app's decoder), advertised-model selection
# (when ids exist), history-image tolerance (the poisoned-chat rule). The
# image-input capability probe INFORMS but never fails — the app can't detect
# a silently-dropped image either. No negative-auth request is ever sent.
# Every verdict describes ONE model path — the operator's
# $CONDUCK_CHECK_SERVER_MODEL, else the first advertised id, else the server's
# model-less default — and the transcript says which, because on a fan-out
# gateway the list order is arbitrary and a per-model capability graded as a
# server property flips the same server between PASS and FAIL.
# Semantic compatibility (client-owned history replay) is INVISIBLE here: a
# stateful server passes this probe and still double-counts context — that
# dimension needs its own test.
# An address whose /v1/models fails re-asks for the ADDRESS and keeps the token
# already entered (interactive runs only — a scripted one exits 1 on the first
# failure). The credential is the expensive input to re-type, the address is the
# cheap one, and the two most common first tries are a typo and a site root whose
# OpenAI API lives one path segment deeper.
COMPAT_RAN=false
COMPAT_CHECKS=0; COMPAT_FAILS=0
COMPAT_MODELS="NOT_RUN"; COMPAT_CHAT="NOT_RUN"; COMPAT_HISTORY_IMAGE="NOT_RUN"
COMPAT_IMAGE_INPUT="NOT_RUN"; COMPAT_MODEL_FIELD="NOT_RUN"

# WHICH model these verdicts describe. A fan-out gateway is one endpoint in
# front of hundreds of upstream models, and /v1/models lists them in an order
# that has nothing to do with capability — so the first advertised id is a
# SAMPLE, and a verdict reached on it is a fact about that route, never a grade
# for the server as a whole. Without this the same server flips PASS↔FAIL purely
# on the order it happens to list its models, which is how a working gateway
# gets told it is broken.
#   $CONDUCK_CHECK_SERVER_MODEL is the operator's override — the ONE public
#   model input; the internal $CONDUCK_CHECK_MODEL/$CONDUCK_PROBE_MODEL names
#   are command-scoped plumbing for handing a value to python without argv, and
#   are deliberately not user knobs.
# COMPAT_MODEL_ID doubles as the pairing answer: a setup handoff must pair
# EXACTLY the model that was proven, and "" (the server_default case) correctly
# means "leave the app's model selection open".
COMPAT_WANTED_MODEL=""   # the operator's $CONDUCK_CHECK_SERVER_MODEL, verbatim
COMPAT_MODEL_ID=""       # the id every model-bearing probe named ("" = none sent)
COMPAT_MODEL_SOURCE="server_default"  # explicit | first_advertised | server_default

c_ok()  { local id="$1"; shift; COMPAT_CHECKS=$((COMPAT_CHECKS+1)); ok "[$id] $*"; }
c_bad() { local id="$1"; shift; COMPAT_CHECKS=$((COMPAT_CHECKS+1)); COMPAT_FAILS=$((COMPAT_FAILS+1)); bad "[$id] $*"; }
c_say() { local id="$1"; shift; say "    [$id] $*"; }

# Grade a chat reply the way the current APP does
# (RemoteAgentClient.decodeReply). This is the single Apple-compatible response
# evaluator used by both normal setup verification and `--check-server`:
# strict JSON (Foundation refuses NaN/Infinity) -> choices must be a non-empty
# array -> EVERY choice must decode as {"message":{"content":"<string>"}} (the
# Swift [Choice] array decodes eagerly, so one malformed later choice
# invalidates the whole reply even when choices[0] is fine) -> the reply is
# choices[0].message.content, and an EMPTY string is a VALID reply. Response
# Content-Type is deliberately NOT checked (the app never reads it) and
# tool_calls/extra fields are tolerated (unknown JSON is ignored). On non-2xx
# the app keys on the error body's "code" field — captured in CCE_WIRE_CODE.
CCE_REASON=""; CCE_LEN=""; CCE_TOKEN=""; CCE_WIRE_CODE=""
app_chat_body_eval() { # app_chat_body_eval <response-body> [expected-digit-code]
  local body="$1" exp="${2:--}" res verdict detail
  CCE_REASON=""; CCE_LEN=""; CCE_TOKEN=""; CCE_WIRE_CODE=""
  case "$body" in data:*)
    CCE_REASON="SSE framing — the app never reads streams, so its JSON decoder fails on this"; return 1 ;;
  esac
  res=$(printf '%s' "$body" | python3 -c '
import json, sys, re
def bad(x): raise ValueError(x)
exp = sys.argv[1] if len(sys.argv) > 1 else "-"
try:
    d = json.load(sys.stdin, parse_constant=bad)
except Exception:
    print("badjson -"); sys.exit(0)
ch = d.get("choices") if isinstance(d, dict) else None
if not isinstance(ch, list) or not ch:
    print("nochoices -"); sys.exit(0)
for c in ch:
    if not (isinstance(c, dict) and isinstance(c.get("message"), dict)
            and isinstance(c["message"].get("content"), str)):
        print("badchoice -"); sys.exit(0)
c = ch[0]["message"]["content"]
if exp != "-":
    print(("token %d" if exp in re.findall(r"\d+", c) else "notoken %d") % len(c)); sys.exit(0)
print("ok %d" % len(c))' "$exp" 2>/dev/null)
  verdict="${res%% *}"; detail="${res#* }"
  case "$verdict" in
    ok)      CCE_LEN="$detail"; return 0 ;;
    token)   CCE_LEN="$detail"; CCE_TOKEN="yes"; return 0 ;;
    notoken) CCE_LEN="$detail"; CCE_TOKEN="no";  return 0 ;;
    badjson)   CCE_REASON="the 2xx body isn't the strict JSON the app's decoder accepts" ;;
    nochoices) CCE_REASON="no usable \"choices\" array (the app reads choices[0].message.content)" ;;
    badchoice) CCE_REASON="a choice doesn't decode as {\"message\":{\"content\":\"<string>\"}} — the app rejects the whole reply" ;;
    *)         CCE_REASON="could not grade the reply" ;;
  esac
  return 1
}

app_chat_loaded_eval() { # app_chat_loaded_eval [expected-digit-code] — grades current DCC_*
  local exp="${1:--}"
  case "$DCC_CODE" in
    2??) ;;
    3??)
      CCE_REASON="HTTP $DCC_CODE redirect — use the final server URL directly (this check does not forward credentials across redirects)"
      return 1
      ;;
    *)
      # error.code is a JSON string the server fully controls, and it is quoted
      # straight into CCE_REASON, which every failure verdict prints. A literal
      # newline in it forges a second "[CHECK_ID] …" line — a hostile gateway
      # writing its own green PASS into the transcript — and an ANSI escape
      # rewrites what the operator sees. C0/DEL out here at the parser; the
      # 64-char cap it already had stays.
      CCE_WIRE_CODE=$(printf '%s' "$DCC_BODY" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
e = d.get("error") if isinstance(d, dict) else None
c = e.get("code") if isinstance(e, dict) else None
if isinstance(c, str) and c:
    print("".join(ch for ch in c if ord(ch) >= 0x20 and ord(ch) != 0x7f)[:64])' 2>/dev/null)
      CCE_REASON="HTTP ${DCC_CODE:-?}${CCE_WIRE_CODE:+ (wire code \"$CCE_WIRE_CODE\")}"
      return 1
      ;;
  esac
  app_chat_body_eval "$DCC_BODY" "$exp"
}

app_chat_eval() { # app_chat_eval <payload-json> [expected-digit-code]
  local exp="${2:--}"
  CCE_REASON=""; CCE_LEN=""; CCE_TOKEN=""; CCE_WIRE_CODE=""
  if ! doctor_chat_request "$1"; then
    # "timed out or the connection dropped" makes the operator guess between a
    # dead host, a refused port, a TLS failure and a slow agent. curl already
    # knows which; doctor_chat_request leaves its exit code in DCC_CURL_RC.
    CCE_REASON=$(doctor_transfer_reason "$DCC_CURL_RC"); return 1
  fi
  app_chat_loaded_eval "$exp"
}

# The app's vision-decline classifier, mirrored: a structured code
# "image_unsupported" at any error status; ANY 413 on an image turn (the app
# maps it to image-too-large unconditionally); or — gated to 400/404 — the
# app's four vision regexes applied to error.message when the OpenAI envelope
# is present (the app deliberately scopes there to dodge metadata false
# matches), else to the whole body.
compat_image_declined_detectable() {
  [ "$CCE_WIRE_CODE" = "image_unsupported" ] && return 0
  [ "$DCC_CODE" = "413" ] && return 0
  case "$DCC_CODE" in 400|404) ;; *) return 1 ;; esac
  compat_image_message_matches
}

# Why did an image-bearing turn fail? The classifier above answers "would the app
# recognize this refusal", which is the right question for the capability probe
# and the wrong one for a history-image failure: it folds EVERY 413 into
# "declined", and 413 means the payload was too big, not that the engine is
# text-only. The two need different advice, so they get separated here.
compat_image_failure_kind() { # -> image_unsupported | too_large | other
  if [ "$CCE_WIRE_CODE" = "image_unsupported" ]; then printf 'image_unsupported\n'; return 0; fi
  if [ "$DCC_CODE" = "413" ]; then printf 'too_large\n'; return 0; fi
  case "$DCC_CODE" in
    400|404) compat_image_message_matches && { printf 'image_unsupported\n'; return 0; } ;;
  esac
  printf 'other\n'
}

# The app's four vision regexes, applied to error.message when the OpenAI
# envelope is present (the app deliberately scopes there to dodge metadata false
# matches), else to the whole body. Callers own the status gating.
compat_image_message_matches() {
  printf '%s' "$DCC_BODY" | python3 -c '
import json, sys, re
body = sys.stdin.read()
text = body
try:
    d = json.loads(body)
    e = d.get("error") if isinstance(d, dict) else None
    m = e.get("message") if isinstance(e, dict) else None
    if isinstance(m, str) and m:
        text = m
except Exception:
    pass
pats = (r"support.*image", r"image.*input", r"unsupported.*content", r"image.*not.*support")
sys.exit(0 if any(re.search(p, text, re.I | re.S) for p in pats) else 1)' 2>/dev/null
}

compat_summary() { # compat_summary <exit-code>
  local rc="${1:-1}" wire="NOT_RUN"
  if $COMPAT_RAN; then
    wire="PASS"; [ "$COMPAT_FAILS" -gt 0 ] && wire="FAIL"
  fi
  printf 'CONDUCK_CHECK_SERVER schema=2 harness=%s wire=%s models=%s chat=%s history_image=%s image_input=%s model=%s model_ids=%s auth=%s checks=%s failed=%s exit=%s\n' \
    "$VERSION" "$wire" "$COMPAT_MODELS" "$COMPAT_CHAT" "$COMPAT_HISTORY_IMAGE" \
    "$COMPAT_IMAGE_INPUT" "$COMPAT_MODEL_FIELD" "${MODELS_ID_COUNT:-0}" \
    "${GW_AUTH:-NOT_RUN}" "$COMPAT_CHECKS" "$COMPAT_FAILS" "$rc"
}

compat_on_exit() {
  local rc=$?
  on_exit
  compat_summary "$rc"
}

# A base address that fails verification RE-ASKS instead of ending the run. The
# token is already in hand — often a 300-character JWT — and an operator who
# mistyped the address, or pointed at a site root whose OpenAI API lives under a
# sub-path, should be able to try the neighbour without pasting the credential
# again. rc 0 = $GW_URL now holds a new address to grade; rc 1 = nothing left to
# try (not a terminal, an empty answer, or the input ended), and the caller owns
# the exit. Same acceptance rule as the first prompt — https anywhere, plain http
# only toward this machine — so the retry can't relax what the first ask enforced.
compat_reask_url() {
  local reply url
  interactive_terminal || return 1
  say ""
  say "  Another address to try? The token you already entered is kept — Enter to stop."
  while true; do
    read -r -p "  URL (Enter to stop) > " reply || return 1
    case "$reply" in '') return 1 ;; esac
    if url=$(doctor_accept_url "$reply"); then
      GW_URL="$url"
      apply_gateway_url_normalization
      return 0
    fi
    if url_has_userinfo "$reply"; then
      warn "$URL_USERINFO_HINT"; continue
    fi
    case "$reply" in
      [Hh][Tt][Tt][Pp]://*) warn "Plain http:// only works toward this machine (127.0.0.1 or localhost). Anywhere else needs https://." ;;
      *) warn "That has to start with https:// — or http://127.0.0.1:<port> for a local test." ;;
    esac
  done
}

# GET /v1/models at the address in $GW_URL, graded exactly the way the app's Test
# Connection grades it, with the verdict line and its diagnosis. rc 0 = this
# address is usable and the rest of the run can proceed; rc 1 = it is not, and the
# caller decides whether to ask for another address or end the run. Sets
# COMPAT_MODELS either way; every $MODELS_* fact the later probes read is left as
# this attempt found it.
compat_models_check() {
  local rc=0 secs over why=""
  models_is_json "$GW_URL" "$COMPAT_WANTED_MODEL" || rc=$?
  secs=$(printf '%s' "${MODELS_TIME:-0}" | awk '{printf "%.1f", $1+0}' 2>/dev/null); [ -n "$secs" ] || secs="?"
  over=$(printf '%s' "${MODELS_TIME:-0}" | awk '{print ($1+0 > 15) ? 1 : 0}' 2>/dev/null)
  if [ "$rc" = "0" ] && [ "$over" != "1" ]; then
    COMPAT_MODELS="PASS"
    c_ok SERVER_MODELS "GET /v1/models — the app's Test Connection passes (${secs}s)"
    # Content-Type is NOT graded: the app parses the bytes and never reads the
    # header (this is a deliberate divergence from the adapter contract).
    if $MODELS_DATA_EMPTY; then
      c_say SERVER_MODELS "(\"data\" is empty — the app reports \"connected, no models yet\"; chat needs the"
      c_say SERVER_MODELS " server to answer without a model field)"
    elif $MODELS_NO_VALID_ID; then
      c_say SERVER_MODELS "(entries carry no usable \"id\" string — the app can't offer a model picker;"
      c_say SERVER_MODELS " fine as long as the server answers without a model field)"
    fi
    return 0
  fi
  COMPAT_MODELS="FAIL"
  if [ "$rc" = "0" ]; then
    c_bad SERVER_MODELS "GET /v1/models — answered, but took ${secs}s (the app's Test Connection gives up at 15s)"
  elif [ "$rc" = "2" ]; then
    c_bad SERVER_MODELS "GET /v1/models — an HTML page (HTTP ${MODELS_HTTP_CODE:-?}), not JSON"
    c_say SERVER_MODELS "(something else answered — a login page, a reverse proxy, a wrong base address, or the"
    c_say SERVER_MODELS " OpenAI-compatible API sitting under a SUB-PATH of this one. Open WebUI is the common"
    c_say SERVER_MODELS " case: its site root answers with the app's own HTML under HTTP 200 and its API lives"
    c_say SERVER_MODELS " at <url>/api — so try this same address with /api on the end.)"
  elif [ "$rc" = "3" ]; then
    c_bad SERVER_MODELS "GET /v1/models — answers, but not the shape the app requires"
    c_say SERVER_MODELS "(the app needs a JSON OBJECT whose top-level \"data\" is an ARRAY — a bare array or"
    c_say SERVER_MODELS " {\"models\": …} fails its Test Connection; some servers have a separate OpenAI-compatible"
    c_say SERVER_MODELS " path that answers correctly — point the app at THAT base URL)"
  else
    if [ "${MODELS_CURL_RC:-0}" != "0" ]; then
      case "$MODELS_CURL_RC" in
        6)  why="DNS lookup failed — that hostname doesn't resolve" ;;
        7)  why="connection refused — nothing is listening there (wrong port? not started?)" ;;
        28) why="timed out — no answer from the host" ;;
        35|60) why="TLS problem — the app requires a certificate this machine would trust too" ;;
        *)  why="transfer failed (curl exit $MODELS_CURL_RC)" ;;
      esac
    else
      case "$MODELS_HTTP_CODE" in
        401|403) if [ "${GW_AUTH:-}" = "none" ]; then
                   why="HTTP $MODELS_HTTP_CODE and no credential was sent — this run is keyless, so the server wants auth you didn't supply (set CONDUCK_TOKEN=<token>)"
                 else
                   why="HTTP $MODELS_HTTP_CODE with the credential you gave me — the app would fail the same way"
                 fi ;;
        3??)     why="HTTP $MODELS_HTTP_CODE redirect — use the final server URL directly (this check does not forward credentials across redirects)" ;;
        404)     why="HTTP 404 — nothing at that path (wrong base address?)" ;;
        5??)     why="HTTP $MODELS_HTTP_CODE — the server errored" ;;
        2??)     why="answered HTTP $MODELS_HTTP_CODE, but the body isn't strict JSON (the app's decoder refuses NaN/Infinity too)" ;;
        *)       why="HTTP ${MODELS_HTTP_CODE:-?}" ;;
      esac
    fi
    c_bad SERVER_MODELS "GET /v1/models — $why"
  fi
  return 1
}

run_compat() {
  trap compat_on_exit EXIT
  trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
  # Arm the machine contract before runtime dependency checks. This guarantees
  # missing curl/python3 exits 1 with the summary as the final line.
  preflight

  say "${BOLD}conduck-connect $VERSION — --check-server${RESET}"
  say "Asks ONE question: does this OpenAI-compatible server speak the core wire the"
  say "current Apple Conduck app needs? It changes no host configuration. It sends live"
  say "model/chat/image requests that may consume compute or enter server-side history."
  say "The check matches the app's request/response acceptance at the directly addressed"
  say "endpoint. It does not follow redirects or forward credentials to Location targets;"
  say "use the final server URL directly. This is NOT the adapter contract:"
  say "${BOLD}--check-adapter${RESET} grades adapters built FOR Conduck,"
  say "and generic servers fail it on rules the app never exercises. A pass here does NOT"
  say "make this server a Conduck adapter."
  if interactive_terminal; then
    note "A CONDUCK_CHECK_SERVER machine summary prints before the optional setup handoff."
  else
    note "The last line is always a CONDUCK_CHECK_SERVER machine summary — scripts key on it."
  fi
  note "What this can't see: a server that keeps its OWN chat history will pass and still"
  note "double-count context — Conduck resends the full history every turn (client-owned)."
  note "This grades ONE model path. Set CONDUCK_CHECK_SERVER_MODEL=<id> to grade the model"
  note "you actually plan to use — otherwise a multi-model server is judged on one sample."

  if [ -n "$CHECK_URL" ]; then
    GW_URL=$(doctor_accept_url "$CHECK_URL") \
      || usage_die "Can't test '$CHECK_URL' — use https://… (or http://127.0.0.1:<port> for a local test)."
  else
    say ""
    GW_URL=$(doctor_ask_url) || die "$NO_ANSWER"
  fi
  apply_gateway_url_normalization

  # Token: bearer from $CONDUCK_TOKEN / prompt; a deliberate empty answer means
  # keyless — the app's explicit .none auth scheme (never inferred, and this
  # probe sends NO negative-auth requests either way).
  # CONDUCK_TOKEN set-but-empty is an EXPLICIT keyless declaration for scripted
  # runs; unset means "ask". Never infer keyless from absence.
  if [ -n "${CONDUCK_TOKEN+set}" ] && [ -z "$CONDUCK_TOKEN" ]; then
    GW_AUTH="none"; GW_TOKEN=""
    note "Keyless by explicit \$CONDUCK_TOKEN= — mirroring the app's no-auth scheme."
  elif [ -n "${CONDUCK_TOKEN:-}" ]; then
    GW_AUTH="bearer"; GW_TOKEN="$CONDUCK_TOKEN"
    note "Using the bearer token from \$CONDUCK_TOKEN."
  else
    say ""
    note "Tip: export CONDUCK_TOKEN=<token> to skip this prompt on re-runs."
    GW_TOKEN=$(ask_secret "Bearer token the server expects (Enter for keyless — the app's explicit no-auth mode)") \
      || die "No token given and no answer possible (the input ended). Set CONDUCK_TOKEN=<token> for a scripted run, or set CONDUCK_TOKEN= (empty) to declare keyless deliberately."
    if [ -n "$GW_TOKEN" ]; then GW_AUTH="bearer"; else
      GW_AUTH="none"
      note "Keyless: mirroring the app's explicit no-auth scheme — sensible only on an isolated network."
    fi
  fi
  TRANSPORT=""

  # Snapshot the operator's model choice ONCE, before any request: the graded
  # model must never change mid-run, or the verdicts stop describing a single
  # path and the optional setup handoff can no longer pair what was proven.
  COMPAT_WANTED_MODEL="${CONDUCK_CHECK_SERVER_MODEL:-}"

  # -- models: direct-endpoint acceptance from Test Connection ----------------
  # A failing address re-asks rather than ending the run (compat_reask_url): the
  # token is already entered, and making the operator paste a long one again to
  # try the neighbouring address is the tool wasting their time. Each attempt
  # re-arms the counters, so the summary describes the address that was actually
  # graded and never carries a previous attempt's red into a later PASS.
  while true; do
    head_ "Server check — $GW_URL"
    COMPAT_RAN=true
    COMPAT_CHECKS=0; COMPAT_FAILS=0; COMPAT_MODELS="NOT_RUN"
    compat_models_check && break
    compat_reask_url && continue
    say ""
    bad "Server check: FAIL — the app's Test Connection fails here, so nothing else can work."
    say "  Fix that first, then re-run me. Testing an adapter you BUILT? Use ${BOLD}--check-adapter${RESET}."
    exit 1
  done

  # An explicit model choice is announced BEFORE the first chat turn, so the
  # verdicts below are read against the right target — and so a typo'd id is
  # visible as the cause of the failures it is about to produce, rather than
  # being discovered several red lines later.
  if [ -n "$COMPAT_WANTED_MODEL" ]; then
    say ""
    note "Grading the model you named: '$(safe_display "$COMPAT_WANTED_MODEL" 60)'."
    if ! $MODELS_WANTED_FOUND; then
      if [ "${MODELS_ID_COUNT:-0}" = "0" ]; then
        note "(this server advertises no model ids at all — naming one is the only way to test it)"
      else
        note "(that id is NOT among the $MODELS_ID_COUNT this server advertises — check the spelling;"
        note " grading it anyway, as you asked)"
      fi
    fi
  fi

  say ""
  say "  Now the chat turns — graded with the app's actual decoder (empty-string replies are"
  say "  VALID, extra fields like tool_calls are tolerated, Content-Type is never read). Agents"
  say "  can be slow; I wait up to 5 minutes per turn…"

  # -- chat, the app's default shape: model OMITTED (dedicated + fresh custom) --
  local payload_a payload_b="" a_ok=false a_reason="" a_code="" b_ok="" b_reason=""
  payload_a=$(python3 -c 'import json
print(json.dumps({"messages": [{"role": "user", "content": "Reply with exactly: pong"}],
                  "stream": False}))') \
    || die "Could not build the test request (python3 failed)."
  if app_chat_eval "$payload_a"; then a_ok=true; else a_reason="$CCE_REASON"; a_code="$DCC_CODE"; fi

  # One turn WITH a NAMED model: the app sends the model the user picked from
  # THIS server's /v1/models, so named selection must work too. Also the rescue
  # path for servers that REQUIRE the field. The operator's explicit choice wins
  # over the first advertised id — on a fan-out gateway the first id is only a
  # sample of the roster, and grading it as though it spoke for the server is
  # what turns a working setup into a FAIL.
  local named_model="$COMPAT_WANTED_MODEL"
  [ -n "$named_model" ] || named_model="$MODELS_FIRST_ID"
  if [ -n "$named_model" ]; then
    payload_b=$(CONDUCK_CHECK_MODEL="$named_model" python3 -c 'import json, os
print(json.dumps({"messages": [{"role": "user", "content": "Reply with exactly: pong"}],
                  "model": os.environ["CONDUCK_CHECK_MODEL"], "stream": False}))') \
      || die "Could not build the test request (python3 failed)."
    if app_chat_eval "$payload_b"; then b_ok=true; else b_ok=false; b_reason="$CCE_REASON"; fi
  fi

  if $a_ok; then
    COMPAT_CHAT="PASS"; COMPAT_MODEL_FIELD="optional"
    c_ok SERVER_CHAT "chat without a \"model\" field — decoded by the app's rules (${CCE_LEN:-?} chars)"
  elif [ "$b_ok" = "true" ]; then
    # Only the statuses the app's own model-required gate accepts may be read as
    # "needs a model" — a transient 429/5xx that happened to clear by the second
    # turn must not claim that. This list stays INLINE and stays wider than the
    # adapter check's: this command asks whether the APP can talk to the server, so
    # it mirrors the app's own status gate (413 included, because the app reaches
    # its model-required path from there too). The adapter check grades contract
    # conformance instead and excludes 413, which the contract spends on a
    # request-size limit. Different questions, different bars — one shared list
    # would quietly move one of the two verdicts.
    case "$a_code" in
      400|404|413|422)
        COMPAT_CHAT="PASS"; COMPAT_MODEL_FIELD="required"
        c_ok SERVER_CHAT "chat works once a model is set — this server REQUIRES the \"model\" field"
        c_say SERVER_CHAT "(without one it answered: $a_reason. In the app, pick a model in the gateway's"
        c_say SERVER_CHAT " settings — a model-less request only happens when none is configured)" ;;
      *)
        COMPAT_CHAT="FAIL"; COMPAT_MODEL_FIELD="required"
        c_bad SERVER_CHAT "chat without a \"model\" field — $a_reason"
        c_say SERVER_CHAT "(the model-named turn worked, but this failure isn't the missing-model kind —"
        c_say SERVER_CHAT " something else is wrong; the app would hit it too)" ;;
    esac
  else
    COMPAT_CHAT="FAIL"
    [ "$COMPAT_MODEL_FIELD" = "NOT_RUN" ] && [ -z "$MODELS_FIRST_ID" ] && COMPAT_MODEL_FIELD="none_advertised"
    c_bad SERVER_CHAT "chat — $a_reason"
    case "$a_code" in
      401|403) c_say SERVER_CHAT "(auth works on /v1/models but not on chat — two different credential checks?)" ;;
    esac
  fi

  # -- named selection as its own verdict (when a model id exists) -------------
  if [ -n "$named_model" ]; then
    local named_what="the first advertised model id"
    [ -n "$COMPAT_WANTED_MODEL" ] && named_what="the model you named"
    if [ "$b_ok" = "true" ]; then
      c_ok SERVER_MODEL_SELECT "$named_what selects (the app sends what the user picked)"
    else
      c_bad SERVER_MODEL_SELECT "a request naming $named_what fails — $b_reason"
      if [ -n "$COMPAT_WANTED_MODEL" ] && ! $MODELS_WANTED_FOUND; then
        # Don't blame the server's picker for an id the server never offered.
        c_say SERVER_MODEL_SELECT "(that id isn't in this server's /v1/models list, so this may just be a typo —"
        c_say SERVER_MODEL_SELECT " unset CONDUCK_CHECK_SERVER_MODEL to grade the first id the server advertises)"
      else
        c_say SERVER_MODEL_SELECT "(the app's model picker is fed from YOUR /v1/models — a listed id that can't"
        c_say SERVER_MODEL_SELECT " be used breaks every user who picks it)"
      fi
    fi
  fi

  # -- which model the remaining probes grade, said out loud ------------------
  # An explicit choice always wins. Otherwise: once the server is known to
  # REQUIRE a model, every later probe carries the advertised id — the app sends
  # the user's configured model on EVERY turn, so a model-less later probe would
  # fail a server real app traffic works on. A server that accepts a model-less
  # request keeps getting model-less probes, which grade its DEFAULT route.
  local probe_model=""
  if [ -n "$COMPAT_WANTED_MODEL" ]; then
    probe_model="$COMPAT_WANTED_MODEL"; COMPAT_MODEL_SOURCE="explicit"
  elif [ "$COMPAT_MODEL_FIELD" = "required" ]; then
    probe_model="$MODELS_FIRST_ID"; COMPAT_MODEL_SOURCE="first_advertised"
  else
    COMPAT_MODEL_SOURCE="server_default"
  fi
  COMPAT_MODEL_ID="$probe_model"
  # The explicit case already announced itself before the first chat turn.
  case "$COMPAT_MODEL_SOURCE" in
    explicit) ;;
    *) say "" ;;
  esac
  case "$COMPAT_MODEL_SOURCE" in
    explicit) ;;
    first_advertised)
      if [ "${MODELS_ID_COUNT:-0}" -gt 1 ] 2>/dev/null; then
        note "Grading model '$(safe_display "$COMPAT_MODEL_ID" 60)' — the FIRST of $MODELS_ID_COUNT ids this server"
        note "advertises, picked by ITS list order, not by capability. The rest are untested, so a"
        note "failure below is a fact about THIS model's route, not a grade for the whole server."
        note "Re-run with CONDUCK_CHECK_SERVER_MODEL=<id> to grade the model you plan to use."
      else
        note "Grading model '$(safe_display "$COMPAT_MODEL_ID" 60)' — the only id this server advertises."
      fi
      ;;
    *)
      note "The probes below send NO \"model\" field, so they grade whatever this server routes to"
      note "by default — and nothing here proves two model-less requests reach the same model."
      ;;
  esac

  # -- history image: the poisoned-chat rule (a REAL app requirement) ----------
  local payload_h
  payload_h=$(CONDUCK_PROBE_MODEL="$probe_model" python3 -c 'import json, os, zlib, struct, base64
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 0, 0, 0, 0)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(b"\x00\xff")) + chunk(b"IEND", b"")
uri = "data:image/png;base64," + base64.b64encode(png).decode()
req = {"messages": [
    {"role": "user", "content": [
        {"type": "text", "text": "What is in this photo?"},
        {"type": "image_url", "image_url": {"url": uri}}]},
    {"role": "user", "content": "Reply with exactly: pong"}], "stream": False}
m = os.environ.get("CONDUCK_PROBE_MODEL", "")
if m:
    req["model"] = m
print(json.dumps(req))') \
    || die "Could not build the history-image test request (python3 failed)."
  if app_chat_eval "$payload_h"; then
    COMPAT_HISTORY_IMAGE="PASS"
    c_ok SERVER_HISTORY_IMAGE "an image in an EARLIER message doesn't break a text-only turn (${CCE_LEN:-?} chars)"
  else
    COMPAT_HISTORY_IMAGE="FAIL"
    c_bad SERVER_HISTORY_IMAGE "history image — $CCE_REASON"
    c_say SERVER_HISTORY_IMAGE "(Conduck resends the full history, so ONE photo anywhere in a conversation would"
    c_say SERVER_HISTORY_IMAGE " permanently break every later turn of that chat — on the route just graded)"
    # Name WHY, from the server's own answer, while DCC_*/CCE_* still hold it.
    # This explains the failure; it never excuses it. A route that cannot read
    # images is still required to drop or describe an OLD one and answer the new
    # text turn, so this stays a real FAIL either way.
    case "$(compat_image_failure_kind)" in
      image_unsupported)
        c_say SERVER_HISTORY_IMAGE "The server says this engine can't read images at all. That still fails: a route"
        c_say SERVER_HISTORY_IMAGE "that can't see pictures is expected to ignore an OLD one and answer the new text." ;;
      too_large)
        c_say SERVER_HISTORY_IMAGE "HTTP 413 on a 1×1 PNG points at a request-size limit in front of the server, not"
        c_say SERVER_HISTORY_IMAGE "at the engine — check the reverse proxy's max body size." ;;
    esac
    # Whenever THIS run picked the graded path rather than the operator, one model
    # out of many was a lottery draw. That is as true of the model-less default
    # route as it is of the first advertised id — and it is the default route a
    # fan-out gateway with hundreds of ids usually lands on, because a server that
    # answers a model-less request never becomes first_advertised at all.
    if [ "$COMPAT_MODEL_SOURCE" != "explicit" ] && [ "${MODELS_ID_COUNT:-0}" -gt 1 ] 2>/dev/null; then
      if [ "$COMPAT_MODEL_SOURCE" = "first_advertised" ]; then
        c_say SERVER_HISTORY_IMAGE "Only '$(safe_display "$COMPAT_MODEL_ID" 60)' was tested — the first of $MODELS_ID_COUNT advertised ids."
      else
        c_say SERVER_HISTORY_IMAGE "This turn named no model, so it graded the default route — one path out of the"
        c_say SERVER_HISTORY_IMAGE "$MODELS_ID_COUNT model ids this server advertises."
      fi
      c_say SERVER_HISTORY_IMAGE "Before judging the server, re-run with CONDUCK_CHECK_SERVER_MODEL=<id> on the one"
      c_say SERVER_HISTORY_IMAGE "you actually plan to use."
    fi
  fi

  # -- image input: capability, informational — never fails the wire verdict ---
  say ""
  say "  Last, the image capability probe (informational — the app can't detect a silently"
  say "  dropped image either, so this never changes the verdict)…"
  CONDUCK_PROBE_MODEL="$probe_model" image_probe_gen
  if app_chat_eval "$IPG_PAYLOAD" "$IPG_CODE"; then
    if [ "$CCE_TOKEN" = "yes" ]; then
      COMPAT_IMAGE_INPUT="VERIFIED"
      say "  ${GREEN}•${RESET} image input: VERIFIED — the reply reads the probe image's digits back (${DCC_TIME:-?}s)"
    else
      COMPAT_IMAGE_INPUT="IGNORED"
      warn "image input: IGNORED — answered 200 while ignoring the image. In the app, photos"
      say "    are silently unseen: users get confident answers about images the engine never saw."
    fi
  elif compat_image_declined_detectable; then
    COMPAT_IMAGE_INPUT="DECLINED"
    say "  ${GREEN}•${RESET} image input: DECLINED, detectably — the app recognizes this refusal and shows its"
    if [ "$COMPAT_HISTORY_IMAGE" = "FAIL" ]; then
      # "text chats are unaffected" is the normal case and a lie here: this route
      # already failed the history-image turn, so a photo poisons the whole chat.
      say "    pictures-unsupported message — but see the history-image failure above: on this"
      say "    route a photo also breaks the TEXT turns that follow it in the same chat."
    else
      say "    pictures-unsupported message (text chats are unaffected)"
    fi
  else
    COMPAT_IMAGE_INPUT="OPAQUE"
    warn "image input: image turns fail with an error the app can't classify ($CCE_REASON) —"
    say "    users see a generic failure instead of \"pictures aren't supported here\""
  fi

  # One line naming the graded path, on BOTH verdicts. A PASS that reads as a
  # blanket certificate and a FAIL that reads as a blanket condemnation are the
  # same bug: neither run tested more than one model.
  local graded_scope=""
  case "$COMPAT_MODEL_SOURCE" in
    explicit)         graded_scope="model '$(safe_display "$COMPAT_MODEL_ID" 60)' (the one you named)" ;;
    first_advertised) graded_scope="model '$(safe_display "$COMPAT_MODEL_ID" 60)'"
                      [ "${MODELS_ID_COUNT:-0}" -gt 1 ] 2>/dev/null \
                        && graded_scope="$graded_scope — the first of $MODELS_ID_COUNT advertised, and the only one tested" ;;
    *)                graded_scope="this server's default route (no \"model\" field was sent)" ;;
  esac

  say ""
  if [ "$COMPAT_FAILS" = "0" ]; then
    ok "Server check: PASS — core text-chat compatibility is green ($COMPAT_CHECKS/$COMPAT_CHECKS wire checks)."
    say "  Image input is separate and informational: ${BOLD}$COMPAT_IMAGE_INPUT${RESET}."
    say "  Graded: $graded_scope."
    say "  Three honest limits: this probe can't see STATEFULNESS (a server that keeps its own"
    say "  history will double-count context — Conduck resends the full history every turn),"
    say "  it grades ONE model path and says nothing about any other model this server offers,"
    say "  and a pass here does NOT make this server a Conduck adapter (that's ${BOLD}--check-adapter${RESET})."
    if [ "$COMPAT_MODEL_SOURCE" = "explicit" ]; then
      # The setup handoff pairs $COMPAT_MODEL_ID — the model this run actually
      # graded — so a deliberately-graded model is the one that gets carried.
      note "Continuing into setup? The pairing code carries the model you named here."
    fi
    # Statefulness is invisible ON THE WIRE, not always invisible: when the address
    # that just passed matches this machine's own Hermes API-server settings, the
    # answer is readable from ~/.hermes/config.yaml. Latched here — and only on a
    # PASS of THIS check, never from --check-adapter — because the handoff clears
    # $GW_URL to rebuild it as an HTTPS address, so this is the last point at which
    # the graded address still exists to be attributed.
    if hermes_settings_match_url "$GW_URL"; then
      CHECK_HANDOFF_LOCAL_HERMES=true
      if interactive_terminal; then
        say "  On statefulness I am not fully blind here: this address matches this machine's Hermes"
        say "  API-server settings, so continuing into setup reads that install's own config and says"
        say "  whether this gateway keeps a memory of its own."
      fi
    fi
    if ! interactive_terminal; then
      say "  To set it up later:  ${BOLD}bash conduck-connect.sh --setup${RESET}"
    fi
    return 0
  fi
  bad "Server check: FAIL — $COMPAT_FAILS of $COMPAT_CHECKS wire checks failed."
  say "  The app would hit the same walls on $graded_scope."
  # Same gate as the history-image note above, and for the same reason: the hint
  # belongs to every run where the TOOL chose the graded path, not only to the
  # first-advertised one. A server that accepts a model-less request never reaches
  # first_advertised, so gating on that source alone hid this line from exactly the
  # fan-out gateways whose 300-plus untested models make it matter most.
  if [ "$COMPAT_MODEL_SOURCE" != "explicit" ] && [ "${MODELS_ID_COUNT:-0}" -gt 1 ] 2>/dev/null; then
    say "  That is not yet a verdict on the server: it advertises $MODELS_ID_COUNT model ids and this run"
    say "  graded one path. CONDUCK_CHECK_SERVER_MODEL=<id> grades the model you plan to use."
  fi
  say "  Building your own adapter instead? ${BOLD}--check-adapter${RESET} grades that:"
  say "  ${BOLD}https://conduck.com/setup/adapter/v1/${RESET}"
  exit 1
}
# -------------------------------------------------------------- pairing emit --

# Write a NON-SECRET pairing profile so a later `--show-code` can re-emit without
# re-answering the wizard. NEVER holds tokens/credentials — only the routing facts
# needed to reconstruct + re-verify. 0600, umask 077, built with a real JSON
# encoder (never hand-quoted). Refreshed on every successful WIZARD emit, but NEVER
# under --show-code: that mode never rewrites saved state, and a transient probe
# failure there can drop a file lane from this one emission — rewriting the profile
# would make that drop permanent. An EXISTING profile is protected by the same
# reasoning against two more runs (see the guards below). A failure here only WARNs —
# it must not sink a completed pairing.
write_profile() {
  # --show-code never rewrites saved state; rewriting here could permanently strip a
  # file lane that a transient probe failure dropped from this one emission. Guard first.
  $SHOW_QR && return 0
  $DRY_RUN && return 0                       # emit_payload never runs in dry-run, but stay explicit
  [ -n "$GW_ID" ] || return 0                # no stable id → nowhere to key the profile; skip quietly
  local pf; pf="$STATE_DIR/profile-$GW_ID.json"
  # Three run shapes may not overwrite a profile that ALREADY exists. Writing the FIRST
  # profile is always safe — there is nothing to destroy — so every guard below is gated
  # on the file being there, and a first pairing still gets its profile either way.
  if [ -f "$pf" ]; then
    # --reuse-only refuses configuration changes, and this file IS saved configuration:
    # the reuse-only paths that leave a still-running file lane out of THIS code would
    # otherwise delete the record of that live lane for good.
    if $REUSE_ONLY; then
      note "Kept the saved pairing profile exactly as it is — --reuse-only changes nothing, and this file counts."
      note "Re-run me without --reuse-only to refresh what it records."
      return 0
    fi
    # The rule the other two guards share, held in one place: a run whose checks failed
    # has proven nothing about this setup, so it may not overwrite a record that a run
    # which passed wrote. emit_payload's failure branch exits first, so no shipping path
    # reaches this line — it is the backstop for the next caller that forgets.
    if $VERIFY_FAILED; then
      return 0
    fi
    # A lane a CHECK dropped is still running, and the operator did not remove it.
    # Recording "no file lane" here is what makes one transient probe failure a
    # permanent deletion — the exact outcome --show-code's guard above exists to avoid.
    if $FS_LANE_DROPPED_BY_CHECK && [ "$(json_type "$pf" "fileServer")" = "object" ]; then
      note "Left the saved pairing profile untouched, so the file lane it records survives this run's probe failure."
      note "Nothing from this run is saved to it — re-run me once the file server answers again to refresh it."
      return 0
    fi
  fi
  ensure_state_dir \
    || { warn "Couldn't create $STATE_DIR to save the pairing profile — pairing is still complete."; return 0; }
  local out
  out=$(GW_ID="$GW_ID" GW_KIND="$GW_KIND" GW_NAME="$GW_NAME" GW_AUTH="$GW_AUTH" \
        TRANSPORT="$TRANSPORT" SCOPE="$SCOPE" GW_URL="$GW_URL" GW_LOCAL_PORT="$GW_LOCAL_PORT" \
        GW_MODEL="$GW_MODEL" \
        FS_URL="$FS_URL" FS_CRED="$FS_CRED" FS_LOCAL_PORT="$FS_LOCAL_PORT" \
        FS_FOLDER="$FS_FOLDER" FS_REACH="$FS_REACH" \
        python3 - <<'PY'
import json, os
e = os.environ.get
# Gateway: routing facts only. No token, ever.
gw = {"id": e("GW_ID"), "kind": e("GW_KIND"), "auth": e("GW_AUTH"),
      "transport": e("TRANSPORT"), "reach": e("SCOPE"), "url": e("GW_URL")}
if e("GW_NAME"):       gw["name"] = e("GW_NAME")
if e("GW_LOCAL_PORT"): gw["localPort"] = e("GW_LOCAL_PORT")
if e("GW_MODEL"):      gw["model"] = e("GW_MODEL")
p = {"schemaVersion": 1, "gateway": gw, "fileServer": None}
# Record the file lane only when it actually shipped in the QR (URL + credential
# both present) — and record its URL/port/folder, NEVER the credential.
if e("FS_URL") and e("FS_CRED"):
    fs = {"url": e("FS_URL")}
    if e("FS_LOCAL_PORT"): fs["localPort"] = e("FS_LOCAL_PORT")
    if e("FS_REACH"):      fs["reach"]     = e("FS_REACH")
    if e("FS_FOLDER"):     fs["folder"]    = e("FS_FOLDER")
    p["fileServer"] = fs
print(json.dumps(p, indent=1))
PY
) || { warn "Couldn't build the pairing profile to save — pairing is still complete."; return 0; }
  [ -n "$out" ] || { warn "Couldn't build the pairing profile to save — pairing is still complete."; return 0; }
  # Write-then-rename: a plain redirect truncates in place, so an interrupt mid-write
  # leaves a half-profile that the menu would offer and --show-code would reject.
  # rename(2) within the same directory is atomic, so readers see old or new, never half.
  if ( umask 077; printf '%s\n' "$out" > "$pf.tmp" && mv -f "$pf.tmp" "$pf" ) 2>/dev/null; then
    chmod 600 "$pf" 2>/dev/null || true       # belt-and-suspenders; umask 077 already made it 0600
    note "Saved a non-secret pairing profile (no token) — re-show this code later with:  bash conduck-connect.sh --show-code"
  else
    rm -f "$pf.tmp" 2>/dev/null || true        # never leave a partial temp behind
    warn "Couldn't save the pairing profile to $pf — pairing is still complete."
  fi
}

# Build the exact JSON that rides inside `conduck-setup:v1`. Kept as a small
# function so regression tests can prove opaque server-owned values (especially
# long model ids) survive setup byte-for-byte before QR/base64 encoding.
build_pairing_payload_json() {
  GW_KIND="$GW_KIND" GW_NAME="$GW_NAME" GW_URL="$GW_URL" GW_AUTH="$GW_AUTH" \
  GW_TOKEN="$GW_TOKEN" GW_MODEL="$GW_MODEL" \
  FS_URL="$FS_URL" FS_CRED="$FS_CRED" \
  TRANSPORT="$TRANSPORT" PV="$PAYLOAD_VERSION" \
  python3 - <<'PY'
import json, os
e = os.environ.get
gw = {"kind": e("GW_KIND"), "url": e("GW_URL"), "auth": e("GW_AUTH")}
if e("GW_NAME"):    gw["name"] = e("GW_NAME")
if e("GW_TOKEN"):   gw["token"] = e("GW_TOKEN")
if e("GW_MODEL"):   gw["model"] = e("GW_MODEL")
p = {"v": int(e("PV")), "gateway": gw, "transport": e("TRANSPORT")}
if e("FS_URL") and e("FS_CRED"):
    p["fileServer"] = {"url": e("FS_URL"), "credential": e("FS_CRED")}
print(json.dumps(p, separators=(",", ":")))
PY
}

emit_payload() {
  head_ "Step 6 — pair with the Conduck app"
  if $VERIFY_FAILED; then
    cleanup_exposures
    warn "Some checks failed above — fix those first, then re-run me."
    warn "I only hand you a setup code that is known to work."
    # Self-guarding: silent unless a restart this run asked for was followed by a
    # readiness wait that genuinely expired. By here the Step-4 warning has
    # scrolled away, and this epilogue is what the operator is reading when they
    # decide whether to undo a change that was correct.
    gw_restart_timing_note
    # Custom targets only. Route by provenance: existing OpenAI-compatible
    # software uses the app-compatibility grader; adapters written for Conduck
    # use the stricter contract grader. OpenClaw/Hermes users need neither hint.
    if [ "$GW_KIND" = "custom" ]; then
      local dt="$GW_URL"
      [ -n "$GW_LOCAL_PORT" ] && dt="http://127.0.0.1:$GW_LOCAL_PORT"
      say ""
      say "  Existing OpenAI-compatible server? Check app compatibility:"
      say "    ${BOLD}bash conduck-connect.sh --check-server $dt${RESET}"
      say "  Adapter built for Conduck? Check the stricter adapter contract:"
      say "    ${BOLD}bash conduck-connect.sh --check-adapter $dt${RESET}"
    fi
    exit 1
  fi

  local payload
  payload=$(build_pairing_payload_json) || die "Could not build the pairing payload (python3 failed)."
  [ -n "$payload" ] || die "Could not build the pairing payload."
  local encoded; encoded=$(printf '%s' "$payload" | b64_nowrap)
  [ -n "$encoded" ] || die "Could not base64-encode the pairing payload."
  local pairing="conduck-setup:v${PAYLOAD_VERSION}:$encoded"

  say ""
  # The file-lane clause must ride the SAME condition build_pairing_payload_json uses to
  # attach fileServer — warning about a shared folder that isn't in this code is a lie the
  # user cannot check, and omitting it when it IS in the code understates what they hold.
  warn "The setup code below CONTAINS YOUR GATEWAY TOKEN — both the QR and the plain-text string."
  if [ -n "$FS_URL" ] && [ -n "$FS_CRED" ]; then
    warn "It also carries the FILE-SERVER CREDENTIAL for your shared folder."
    warn "Treat it like a password: whoever holds it can do anything your gateway allows and can"
    warn "read or change files in that folder, and it keeps working until you rotate those secrets."
  else
    warn "Treat it like a password: whoever holds it can do anything your gateway allows, and it"
    warn "keeps working until you rotate that secret."
  fi
  warn "Handing the code to another person hands them that same access. Devices sharing one token"
  warn "cannot be cut off one at a time — rotating it cuts off every device using that token."
  warn "Show it to your own phone only. Note: over SSH, Ctrl-L only clears the visible screen —"
  warn "the code stays in your scroll-back, so close the terminal (or clear scroll-back) when"
  warn "you're done, and never paste it into chat or a bug report."
  say ""

  render_qr "$pairing" || true   # prints a QR, or its own "widen/paste" note; string still follows

  say ""
  say "  ${BOLD}In Conduck:${RESET} Settings → Personal AI → look for the setup-code option."
  say "  On iPhone or iPad, scan the QR or paste this code; on Mac, paste the code below."
  say ""
  say "  Setup code (same secret as the QR — paste this for the Mac app or if scanning fails):"
  say ""
  printf '%s\n' "$pairing"
  say ""
  case "$TRANSPORT" in
    tailscale) note "Reminder: this gateway is tailnet-only — the device running Conduck (iPhone, iPad, or Mac) needs the Tailscale app, logged in to the same tailnet." ;;
  esac
  # A quick tunnel's hostname is REASSIGNED on every restart of it, a reboot included, and
  # the replacement reaches no saved profile and no output of this script. What goes stale
  # is THE CODE, so the reminder belongs where the operator is holding it — the address was
  # named at the step that accepted it, and by here that step has scrolled away.
  # The file-lane clause rides the same pair build_pairing_payload_json uses, so it can
  # never name a lane this code does not carry. 30-exposure's predicate on purpose: a
  # second copy of a host-matching rule is how the two drift apart.
  local qt_gw=false qt_fs=false
  is_quick_tunnel_url "$GW_URL" && qt_gw=true
  if [ -n "$FS_URL" ] && [ -n "$FS_CRED" ] && is_quick_tunnel_url "$FS_URL"; then qt_fs=true; fi
  if $qt_gw || $qt_fs; then
    say ""
    if $qt_gw && $qt_fs; then
      warn "This code carries Cloudflare QUICK TUNNEL addresses for BOTH the gateway and the file lane."
    elif $qt_gw; then
      warn "This code carries a Cloudflare QUICK TUNNEL address for the gateway."
    else
      warn "This code carries a Cloudflare QUICK TUNNEL address for the file lane."
    fi
    warn "That hostname is reassigned every time the tunnel restarts — a reboot, a crash, or a"
    warn "Ctrl-C in its terminal. This exact code then points at a hostname that does not exist,"
    warn "and the address it comes back on appears in no saved profile and in no output of this"
    warn "script, so there is nothing for the app or for me to look up."
    $qt_gw || warn "Chat keeps working; attachments stop."
    say "  ${BOLD}Keep that tunnel running${RESET} for as long as you want this code to work, and re-run me for a"
    say "  fresh code after every restart of it."
  fi
  # The durability caveat rides HERE as well as at the step that built the lane: this
  # screen is where the operator decides to trust the lane, and by now the Step-4 line has
  # scrolled away. Gated on the one arrangement it is true for — a systemd USER unit on
  # Linux, which systemd stops shortly after that user's last session ends.
  if [ -n "$FS_URL" ] && [ -n "$FS_CRED" ] && [ "$OS" = "Linux" ] && [ -n "$FS_UNIT" ] \
     && ! fs_linger_enabled_linux; then
    local lu lpriv; lu=$(id -un 2>/dev/null); lpriv=$(priv_prefix)
    warn "File transfer in this code rides a service that stops when you log out: lingering is off"
    warn "for '$lu', so the file server stops answering after that user's last logout and does not"
    warn "come back on reboot. Chat keeps working; attachments stop until that user logs in again."
    note "Make it survive logout and reboot:  ${lpriv:+$lpriv }loginctl enable-linger $lu"
  fi
  say "  Run this script again any time to check the connection or show the code again."
  # Custom targets only (see the matching gate in emit_payload's failure branch).
  # The adapter line rides a SUCCESS screen, so it needs the outcome named with it:
  # this pairing already works, and a user who runs the strict grader on generic
  # software gets a FAIL that means nothing about the setup they just proved.
  if [ "$GW_KIND" = "custom" ]; then
    local dt="$GW_URL"
    [ -n "$GW_LOCAL_PORT" ] && dt="http://127.0.0.1:$GW_LOCAL_PORT"
    say "  Existing OpenAI-compatible server? Re-check it with:  ${BOLD}bash conduck-connect.sh --check-server $dt${RESET}"
    say "  Adapter built for Conduck? Grade it with:             ${BOLD}bash conduck-connect.sh --check-adapter $dt${RESET}"
    note "The adapter grade only fits software built for Conduck: generic servers (Ollama, LiteLLM,"
    note "Open WebUI) fail rules that are correct for them — that does not undo the pairing above."
  fi
  if $FS_ROLLBACK_INCOMPLETE; then
    say ""
    warn "One thing still needs YOUR attention: a file-server exposure this run created"
    warn "could not be confirmed removed, so it may still be reachable. The exact undo"
    warn "commands print below — run them, then check 'tailscale funnel status'."
  fi
  EMITTED=true   # success — the EXIT backstop prints undo hints only for an unconfirmed rollback
  write_profile  # refresh the non-secret profile so a later --show-code needs no questions
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
  if ! have tailscale; then
    # Not installed is a calm fact, not a failure — the refuse-to-guess warning
    # is for an INSTALLED Tailscale whose state can't be read.
    note "(Tailscale isn't installed — only matters if you'd pick the Tailscale path)"
  elif ! $TS_STATE_KNOWN; then
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
    *) tr_h="to be decided during exposure" ;;
  esac
  case "$SCOPE" in
    public) reach_h="public (anyone with the URL)" ;; private) reach_h="private (your devices only)" ;;
    *) reach_h="to be decided during exposure" ;;
  esac
  note "gateway = $gw_h${GW_NAME:+ ($GW_NAME)}   reach = $reach_h   how = $tr_h"
  note "gateway URL = ${GW_URL:-<set during exposure>}"
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
    [ "$rejected" = "1" ] && die "There IS a saved pairing profile on this machine, and this version ($VERSION) can't use it. $reason"
    [ "$rejected" = "0" ] || die "There are $rejected saved pairing profiles on this machine, and this version ($VERSION) can't use any of them. The first one says: $reason"
    die "No usable saved pairing profile on this machine yet — run setup once (bash conduck-connect.sh --setup) to pair and save one. From then on, --show-code re-shows it, skipping the setup questions (it may still ask you to pick a profile, re-enter a custom gateway's token, or confirm a gateway-only code; live verification still runs)."
  fi
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
show_qr_resolve_file_reach() { # saved file reach (possibly empty), gateway reach
  if [ -n "$1" ]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}

# One secret-free profile validator shared by the welcome menu, profile picker,
# and --show-code loader. A partial schema-1 file must never be advertised and
# then rejected only after the user chooses it.
PROFILE_VALIDATION_ERROR=""
show_qr_profile_invalid() { PROFILE_VALIDATION_ERROR="$1"; return 1; }
show_qr_validate_profile() { # show_qr_validate_profile <profile-file>
  local pf="$1" sv kind id name auth transport reach url port
  local gateway_type file_type fsurl fsreach fsport
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
    tailscale|funnel|cloudflare|public) ;;
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

  fsurl=$(json_get "$pf" "fileServer.url")
  fsreach=$(json_get "$pf" "fileServer.reach")
  fsport=$(json_get "$pf" "fileServer.localPort")
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
  local saved_port saved_folder
  saved_port=$(json_get "$PROFILE_FILE" "fileServer.localPort")
  saved_folder=$(json_get "$PROFILE_FILE" "fileServer.folder")
  # existing_fs_config recovers the credential (state cred file / env file / unit) and
  # sets FS_CRED + FS_LOCAL_PORT + FS_FOLDER; keep the profile's URL/port authoritative.
  if existing_fs_config && [ -n "$FS_CRED" ]; then
    FS_URL="$fsurl"
    [ -n "$saved_port" ] && FS_LOCAL_PORT="$saved_port"
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
      FS_URL=""; FS_CRED=""; FS_FOLDER=""
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
    cloudflare|public)
      note "This transport has no local exposure to introspect — reachability is proven by the real requests below."
      ;;
    *)
      die "The saved profile has an unrecognized transport '$TRANSPORT' — re-run the wizard (bash conduck-connect.sh) to refresh it."
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
  # The suggested replacement list has to match the code this run is about to
  # emit, so the test is the SAME pair build_pairing_payload_json uses to decide
  # whether a fileServer block is carried at all. show_qr_recover_file_lane can
  # legitimately downgrade a saved file-lane profile to gateway-only when the
  # credential is gone, and telling that operator to write `[web, file]` would
  # suggest a toolset their pairing no longer uses.
  local suggested="[web]"
  if [ -n "${FS_URL:-}" ] && [ -n "${FS_CRED:-}" ]; then suggested="[web, file]"; fi
  hermes_recall_scope_step "$suggested" || true
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
  head_ "Re-show your pairing code — skips setup and changes no configuration"
  show_qr_pick_profile
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
}
# ----------------------------------------------------------------------- main --

prepare_setup_from_check() {
  local checked_kind="$1" checked_url="$GW_URL" checked_path="" parsed=""
  SETUP_FROM_CHECK=true
  GW_KIND="custom"
  GW_HEALTH_PATH=""
  TRANSPORT=""
  SCOPE=""

  if [ "$checked_kind" = "adapter" ]; then
    GW_NAME=$(ask "  A short name for this adapter (shown in the app)" "My Conduck adapter")
  else
    GW_NAME=$(ask "  A short name for this server (shown in the app)" "My gateway")
  fi
  GW_ID="custom-$(slug "$GW_NAME")"; [ "$GW_ID" = "custom-" ] && GW_ID="custom-gateway"

  # A server check grades ONE model path, and the handoff must pair EXACTLY that
  # path — deriving it a second time here is how a run that graded model X ends
  # up pairing model Y. $COMPAT_MODEL_ID is the single answer the check already
  # reached: the model the operator named, else the advertised id the server was
  # proven to require, else "" — and "" is not a gap, it means the check passed
  # WITHOUT a model field, so the app's model selection stays open. An adapter
  # check names no model at all (its contract requires tolerating an absent one),
  # so the kind guard, not the source, decides whether a model is carried.
  # $COMPAT_MODEL_SOURCE is read for wording only; it holds its initial value on
  # runs where --check-server never executed, so it can't stand in for the guard.
  GW_MODEL=""
  if [ "$checked_kind" = "server" ]; then
    # Model ids are opaque server-owned strings, so the id rides VERBATIM: it is
    # the one that was actually proven, LiteLLM routes and Hugging Face
    # repository names can legitimately be long, and a sanitised variant would
    # pair something no request ever tested.
    GW_MODEL="${COMPAT_MODEL_ID:-}"
    # This line is the operator's last look at what their pairing code will
    # carry, so it prints the WHOLE id — a truncated one cannot be checked
    # against the server, and "exact" would be a lie. safe_display is still
    # applied for its control-stripping: an explicitly named id is unvalidated
    # operator input, and a stray newline or ANSI escape in it must not repaint
    # this transcript. The bound is a flood stop, not a display truncation —
    # a real model id is orders of magnitude shorter.
    if [ -z "$GW_MODEL" ]; then
      note "The check passed without naming a model, so the code leaves the app's model selection open."
    elif [ "${COMPAT_MODEL_SOURCE:-}" = "explicit" ]; then
      ok "Pairing the model you named and checked: $(safe_display "$GW_MODEL" 4096)"
    else
      ok "Reusing the exact model ID the successful check required: $(safe_display "$GW_MODEL" 4096)"
    fi
  fi

  case "$checked_url" in
    http://*)
      # A local check can continue into exposure without asking for the same
      # port/token again. Keep a legitimate base-path prefix so the eventual
      # HTTPS address still reaches the exact endpoint that passed.
      parsed=$(CHECKED_URL="$checked_url" python3 -c '
import os
from urllib.parse import urlsplit
u = urlsplit(os.environ["CHECKED_URL"])
print("%s\t%s" % (u.port or 80, u.path.rstrip("/")))' 2>/dev/null) \
        || die "Could not reuse the checked local URL."
      GW_LOCAL_PORT="${parsed%%$'\t'*}"
      checked_path="${parsed#*$'\t'}"
      GW_URL=""
      ;;
    *)
      GW_LOCAL_PORT=""
      GW_URL="$checked_url"
      ;;
  esac

  CHECKED_PATH_PREFIX="$checked_path"
  note "Reusing the checked address and authentication in memory; your token is not saved."
}

apply_checked_path_prefix() {
  [ -n "${CHECKED_PATH_PREFIX:-}" ] || return 0
  case "$GW_URL" in
    *"$CHECKED_PATH_PREFIX") ;;
    *) GW_URL="${GW_URL%/}$CHECKED_PATH_PREFIX" ;;
  esac
  note "Keeping the checked server's base path: $GW_URL"
}

run_setup() {
  say "${BOLD}conduck-connect $VERSION${RESET} — pair your self-hosted AI gateway with Conduck."
  if $LEGACY_GENERIC; then
    warn "--generic is the older name for custom-server setup. Continuing with custom-server setup."
  fi
  $DRY_RUN && note "(dry-run: nothing will be changed)"
  if $REUSE_ONLY; then
    note "(reuse-only: I'll reuse what's set up and refuse configuration changes; live verification still sends requests and may write/delete a file probe)"
  fi
  say "Every change asks first, and you see the exact command before it happens. No telemetry — nothing goes anywhere except your own gateway (to verify it). Ctrl-C any time."
  note "Some commands I offer to run for you (you say yes or no to each); the rest you copy-paste and run yourself while I wait."

  # The single-instance gate, taken HERE because this is the one choke point both
  # entries pass through: the --setup dispatch below, and the check → setup handoff
  # in finish_successful_check. Everything past this line picks loopback ports and
  # writes units, credential files and profile-$GW_ID.json — all of them collision
  # points for two overlapping runs (see setup_lock_acquire for what each one costs).
  #
  # A dry run is deliberately exempt: it changes nothing and write_profile returns
  # early under it, so it neither needs the guard nor may hold one — blocking a real
  # setup because somebody is reading a plan would be a worse bug than this fixes.
  if ! $DRY_RUN; then
    setup_lock_acquire
    # Compose, never replace: on_exit is the exposure-undo backstop, and nothing
    # re-arms EXIT past this point (finish_successful_check re-arms it BEFORE it
    # reaches here). HUP/INT/TERM route through `exit`, so a signal lands here too.
    # Even a future path that did drop this trap leaves the lock recoverable — its
    # authority is the holder's liveness, not the directory's existence.
    trap 'setup_lock_release; on_exit' EXIT
  fi

  # Before any new port is chosen: an interrupted earlier run may have left a live
  # exposure recorded on disk, and a leftover PUBLIC funnel outranks this setup.
  # Ordered deliberately — AFTER setup_lock_acquire, so two overlapping runs cannot
  # both offer to close the same port, and BEFORE choose_exposure, so the operator
  # decides about old exposures while none of this run's are applied yet.
  reconcile_orphaned_exposures

  if $SETUP_FROM_CHECK; then
    choose_exposure
    local exposure_rc=$?
    if [ "$exposure_rc" = "10" ]; then
      note "Setup stopped. The completed check changed nothing on your server."
      exit 0
    fi
    [ "$exposure_rc" = "0" ] || exit "$exposure_rc"
    apply_checked_path_prefix
  else
    # Gateway selection → configure → transport, looped so the transport menu's
    # "b" can return to the gateway choice. Detection informs the menu but never
    # selects a gateway: the user always makes an explicit 1/2/3 choice.
    while true; do
      GW_KIND=""; GW_ID=""; GW_NAME=""; GW_LOCAL_PORT=""; GW_HEALTH_PATH=""
      GW_AUTH="bearer"; GW_TOKEN=""; GW_MODEL=""; GW_URL=""
      detect_gateway
      case "$GW_KIND" in
        openclaw) configure_openclaw ;;
        hermes)   configure_hermes ;;
        custom)   configure_generic ;;
      esac
      choose_exposure && break
      local rc=$?
      [ "$rc" = "10" ] || break
      say ""; note "↩ Back to the gateway choice."
    done
  fi

  setup_file_lane
  # The Hermes API-server memory question, asked once per run for every route in:
  # the gateway menu's Hermes, and a --check-server handoff whose checked address
  # matched this machine's Hermes settings (where GW_KIND is deliberately
  # "custom"). AFTER setup_file_lane because that step asks about the same
  # `platform_toolsets.api_server` line — going second turns two edits and two
  # Hermes restarts into one — and BEFORE the dry-run exit, so a planned run
  # reports the finding it would have acted on.
  hermes_recall_post_file_lane_step
  if $DRY_RUN; then
    print_plan
    exit 0
  fi

  # This is intentionally repeated even after a standalone check: setup must
  # verify the FINAL app-facing HTTPS route, not only the local/direct address.
  verify_all
  emit_payload
}

finish_successful_check() { # finish_successful_check <server|adapter>
  local kind="$1"
  if ! interactive_terminal; then
    # The check's EXIT trap prints the machine summary as the final line.
    exit 0
  fi

  # Interactive runs print the summary before offering another action. Replace
  # the check trap so a later setup error cannot rewrite a successful check as
  # failed. The optional file profile also gets its cleanup backstop now.
  if [ "$kind" = "adapter" ]; then
    $DOCTOR_FILES && doctor_files_cleanup_backstop
    doctor_summary 0
  else
    compat_summary 0
  fi
  trap on_exit EXIT

  say ""
  if ! confirm "  Would you like to continue with setup and pairing?"; then
    note "Check complete. No setup changes were made."
    exit 0
  fi

  prepare_setup_from_check "$kind"
  DOCTOR=false
  COMPAT=false
  DOCTOR_DEEP=false
  DOCTOR_FILES=false
  SHOW_QR=false
  REUSE_ONLY=false
  CHECK_URL=""

  # The standalone checks do not need openssl; setup does (it mints the gateway
  # and file-lane credentials), so run the setup preflight after transitioning.
  preflight
  run_setup
}

if [ "$COMMAND" = "menu" ]; then
  choose_main_action
fi
validate_cli
[ "$COMMAND" = "exit" ] && { note "Nothing changed."; exit 0; }

case "$COMMAND" in
  check-adapter)
    run_doctor
    finish_successful_check "adapter"
    ;;
  check-server)
    run_compat
    finish_successful_check "server"
    ;;
  show-code)
    preflight
    say "${BOLD}conduck-connect $VERSION${RESET} — re-show a saved setup code."
    note "(changes no configuration; live gateway checks run, and a configured file lane gets one small PUT → GET → DELETE probe)"
    run_show_qr
    exit 0
    ;;
  setup)
    preflight
    run_setup
    ;;
esac
