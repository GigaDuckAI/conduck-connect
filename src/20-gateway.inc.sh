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
# True once this run has renamed a gateway it is editing. The id is frozen by
# then (see GW_EDITING), so the review screen has to say that the rename is
# display-only — otherwise the service and credential files keep a name the
# operator has just been shown is no longer the gateway's.
GW_RENAMED=false
# True when the saved-gateway picker actually put a list on screen. It decides
# whether the name prompt offers Back: with a list above it, Back returns to a
# real question; without one, the name IS the first question and advertising a
# control that leads nowhere is the defect this release exists to remove.
GW_PICKER_SHOWN=false

# A --check-server handoff pairs the ONE address the check graded, so its gateway
# kind is "custom" no matter what answered — see prepare_setup_from_check. This
# latch carries the single Hermes fact that survives that decision: the checked
# address matched this machine's own Hermes API-server settings. It is set only
# by a PASSING --check-server (never by --check-adapter, which grades a different
# contract), and it only ever unlocks a report and an offer. It must never stand
# in for GW_KIND: an address match is not authority to run Hermes-specific
# configuration steps the check never verified.
CHECK_HANDOFF_LOCAL_HERMES=false

# The two paths Step 1 actually reads, named in ONE place so the "found" report,
# the "nothing found" notice and the recovery message after a wrong choice can
# never cite a path the detector does not look at. Both live in THIS user
# account's home folder, which is the whole reason a detection miss is so often
# wrong in the user's eyes: somebody else installed the gateway, under their own
# account, on the same machine.
openclaw_config_file() { printf '%s' "$HOME/.openclaw/openclaw.json"; }
hermes_config_dir()    { printf '%s' "$HOME/.hermes"; }

# What to say when the operator picks a gateway whose configuration is not on
# this machine. Dying here is the wrong shape and was the tool's single worst
# dead end: it is the first real question, one keystroke in, and it is the most
# likely wrong answer for exactly the person this wizard is written for — a
# friend installed the gateway for them, so "which one is it" is a guess. So
# every way out gets named and the run goes back to the same menu, which is a
# question they have already been asked once and can now answer differently.
gateway_not_here() { # gateway_not_here <display-name> <path-searched>
  local name="$1" path="$2"
  say ""
  bad "I can't set up $name here — its settings aren't on this machine, under this user account."
  say "  I looked for: $path"
  say ""
  say "  That almost always means one of three things:"
  say "    • $name is installed under a DIFFERENT user account on this machine."
  say "      Its settings live in that account's own home folder, so log in as that"
  say "      user (or switch to them) and run me again there."
  say "    • $name runs on ANOTHER machine. I configure the machine I'm running on,"
  say "      so run me there instead — or, if that machine already answers on an"
  say "      https:// address, choose option 3 below and give me that address."
  say "    • $name was never finished setting up here. Run its own setup first;"
  say "      this script never installs a gateway."
  say ""
  note "Not sure which of the three you have? Choose option 3. It works with anything that"
  note "speaks the OpenAI API — OpenClaw and Hermes included — and it asks you for an"
  note "address or a port instead of reading a config file."
  say ""
  note "↩ Back to the gateway choice. Nothing has been changed."
}

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
  local oc_cfg hm_dir choice
  oc_cfg=$(openclaw_config_file)
  hm_dir=$(hermes_config_dir)
  local found=()
  # Re-detected on every pass: an operator sent away to run a gateway's own
  # onboarding can do it in another window and come straight back, and a menu
  # still reporting the state from before that would be actively misleading.
  while true; do
    found=()
    [ -f "$oc_cfg" ] && found+=("openclaw")
    { [ -f "$hm_dir/.env" ] || [ -d "$hm_dir" ]; } && found+=("hermes")

    if [ ${#found[@]} -gt 0 ]; then
      say "  We found these on this machine: ${BOLD}${found[*]}${RESET}"
      say "  You can choose one of them, or configure a different server."
    else
      # "the usual places" told a user whose gateway IS installed that the tool
      # looked somewhere — without saying where — so they could neither check
      # nor correct it. Naming both paths turns a dead end into something the
      # operator can act on, usually by noticing the home folder is not theirs.
      say "  I found no OpenClaw or Hermes install here. I looked for:"
      say "    OpenClaw:  $oc_cfg"
      say "    Hermes:    $hm_dir/"
      say "  Those are this user account's own settings folders, so a gateway installed"
      say "  under a different account — or running on another machine — doesn't show up."
      say "  You can still pick one; I'll say exactly what I couldn't find."
    fi

    say ""
    say "  Which gateway should Conduck talk to?"
    say "    1) OpenClaw $( [[ " ${found[*]-} " == *" openclaw "* ]] && echo '(detected)' )"
    say "    2) Hermes   $( [[ " ${found[*]-} " == *" hermes "* ]] && echo '(detected)' )"
    say "    3) Something else that speaks the OpenAI API (Ollama, LiteLLM, vLLM, your own adapter, …)"
    prompt_into choice require_choice "Choose 1-3" '^[123]$' "nav.gateway"
    case "$choice" in
      # The same file configure_openclaw needs. Checking it HERE, where the menu
      # is still on screen, is what turns "wrong keystroke" into "answer again".
      1) [ -f "$oc_cfg" ] && { GW_KIND="openclaw"; return 0; }
         gateway_not_here "OpenClaw" "$oc_cfg" ;;
      # configure_hermes tests the directory, not the .env, because it can create
      # the .env itself — so this gate has to test exactly the same thing.
      2) [ -d "$hm_dir" ] && { GW_KIND="hermes"; return 0; }
         gateway_not_here "Hermes" "$hm_dir" ;;
      3) GW_KIND="custom"; return 0 ;;
      *) die "Invalid choice." ;;   # unreachable; a silent fallthrough would leave GW_KIND unset
    esac
    say ""
  done
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

# Prompt for the OpenClaw gateway key (hidden), or die with <die-msg> on empty input.
# In the wizard's dry-run it only notes the intent (a real run would ask). Sets GW_TOKEN.
_openclaw_prompt_secret() { # _openclaw_prompt_secret <ctx> <ask-prompt> <die-msg-on-empty>
  local ctx="$1" ask="$2" diemsg="$3"
  if [ "$ctx" = "wizard" ] && $DRY_RUN; then
    note "(dry-run: would prompt for the gateway key)"
    return 0
  fi
  # prompt_into, not a plain $(…): ask_secret answers `q` with rc 11, and acting
  # on that has to happen in THIS shell — a quit_run inside a command
  # substitution would stop the subshell and let the wizard walk on with an
  # empty token.
  prompt_into GW_TOKEN ask_secret "$ask" "stop; this key is required" "gateway.token"
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
  [ -f "$cfg" ] || die "Can't find $cfg to read the OpenClaw gateway key — is this the machine you paired on? Re-run the wizard (bash conduck-connect.sh) if OpenClaw moved."
  local mode; mode=$(json_get "$cfg" "gateway.auth.mode")
  case "$mode" in
    none)
      if [ "$ctx" = "showqr" ]; then
        warn "OpenClaw's config now shows auth mode 'none', but your saved profile expects a key."
        _openclaw_prompt_secret "$ctx" \
          "Paste the gateway key again — what the gateway checks on each request (hidden)" \
          "A key is required (your saved profile says auth=bearer). Re-run when you have it."
        return 0
      fi
      GW_AUTH="none"; GW_TOKEN=""
      note "OpenClaw's gateway auth mode is 'none' — this gateway has no key. Fine on a private network; I'll guard against publishing it keyless below."
      ;;
    ""|token|password)
      GW_AUTH="bearer"
      local key="gateway.auth.token"; [ "$mode" = "password" ] && key="gateway.auth.password"
      local cls; cls=$(json_query "$cfg" "classify" "$key")
      case "$cls" in
        literal$'\t'*)
          GW_TOKEN="${cls#*$'\t'}"
          ok "Read the gateway key (what the app sends to log in) from openclaw.json (not shown)."
          ;;
        ref)
          warn "Your OpenClaw config references the key indirectly (an env placeholder or secret reference), not as a literal value."
          _openclaw_prompt_secret "$ctx" \
            "Paste the actual key the gateway checks (hidden)" \
            "OpenClaw's config points at the key indirectly, so I can't read it — paste the real value and re-run."
          ;;
        *)
          # Absent in the config → try the compose .env (OPENCLAW_GATEWAY_TOKEN; token mode
          # only), then prompt. The seed .env can drift, but it beats no token at all.
          [ "$mode" = "password" ] || GW_TOKEN=$(env_get "$compose_dir/.env" "OPENCLAW_GATEWAY_TOKEN")
          if [ -n "$GW_TOKEN" ]; then
            ok "Read the gateway key from the OpenClaw compose .env (not shown)."
          else
            warn "No literal key found at $key in $cfg (or in the compose .env)."
            _openclaw_prompt_secret "$ctx" \
              "Paste the gateway key — what the gateway checks on each request (hidden)" \
              "OpenClaw needs its key. Find it in openclaw.json under $key, then re-run."
          fi
          ;;
      esac
      ;;
    *)
      # trusted-proxy or anything unknown: we can't infer the key to send.
      GW_AUTH="bearer"
      note "OpenClaw's gateway auth mode is '$mode' — I won't guess a key for it; paste whatever key the gateway expects."
      _openclaw_prompt_secret "$ctx" \
        "Paste the key the gateway expects (hidden)" \
        "This auth mode ('$mode') needs a key I can't read automatically — paste it and re-run."
      ;;
  esac
}

# --- one saved setup per first-class gateway ---------------------------------
#
# OpenClaw and Hermes are never asked for a name: their ids are the constants
# "openclaw" and "hermes", so every run of either lands on the SAME saved
# profile, the same file-server unit and the same credential. That single-setup
# model is right for what a machine actually has — one OpenClaw per user account
# — but it means a second run REPLACES the first run's saved record wholesale,
# at the very end, inside write_profile, and nothing on screen said so. Options 1
# and 2 are the paths the wizard leads with, and they were the two with no
# collision gate at all; the custom path has had one since it grew a name prompt.
#
# This is a CONFIRMATION, not a refusal, and that difference is the whole design.
# Re-running the wizard IS the supported way to repair a gateway whose address
# moved — a Cloudflare quick tunnel's hostname is reassigned on every restart of
# it, which is this tool's commonest real-world failure — so refusing the way the
# custom path refuses a duplicate name would block the repair people come here
# for. What the operator gets instead is the record they are about to lose, on
# screen, before they answer, plus the shorter way round when only one value has
# changed.
#
# It tests the PROFILE only, deliberately not gateway_id_is_taken. A leftover
# unit or credential filed under a fixed id belongs to this same gateway by
# construction — there is no second OpenClaw it could have come from — so
# adopting it is correct, and the file lane already detects, reports and reuses
# what it finds. The saved record is the one thing this run can destroy and
# nothing can reconstruct, so it is the one thing gated.
#
# Read by the `i` panel below, which cannot take arguments. Set immediately
# before the gate that uses them and never read anywhere else. EDITABLE carries
# the one fact the panel cannot re-derive: whether the saved file is one this
# version can parse, and so whether the edit-one-value alternative it recommends
# actually exists for this operator.
GW_REPLACE_ID=""
GW_REPLACE_NAME="this gateway"
GW_REPLACE_EDITABLE=true
# The id this run has already put the replace screen up for. `b` at the exposure
# menu returns to the gateway choice (99-main loops), so configure_openclaw can
# run twice in one process — and a consent screen that comes round again on the
# way back through a step nobody re-decided is how a reader learns to answer it
# without reading. It also keeps --dry-run's plan from listing one replacement
# twice. Keyed by id, so going back and choosing the OTHER gateway still asks.
GW_REPLACE_ASKED_ID=""

# What the saved record actually says, in the four lines the next few steps are
# about to overwrite. Its own function so the gate reads as one thought, and
# because the manage surface wants the same four facts (see the handoff note).
gw_print_saved_setup_summary() { # gw_print_saved_setup_summary <profile-file>
  local pf="$1" u t r m fsu fsf reach_note=""
  u=$(json_get "$pf" "gateway.url")
  t=$(json_get "$pf" "gateway.transport")
  r=$(json_get "$pf" "gateway.reach")
  m=$(json_get "$pf" "gateway.model")
  # safe_display on every one of them: these come off disk as free text, and this
  # is a terminal. Bounded generously — a model id is server-owned and a long
  # legitimate one has to be recognisable, which is the only reason it is here.
  say "    Address:       $(safe_display "${u:-—}" 4096)"
  [ -n "$r" ] && reach_note=" ($(safe_display "$r" 20))"
  # Transport and reach are one fact to a reader ("tailscale, private"), and two
  # rows for them would put the answer to "can anyone else get at this?" on a
  # line of its own where it reads as a separate setting.
  [ -z "$t" ] || say "    Reached over:  $(safe_display "$t" 60)$reach_note"
  if [ -n "$m" ]; then say "    Model:         $(safe_display "$m" 4096)"
  else                 say "    Model:         whichever model your server picks"; fi
  if [ "$(json_type "$pf" "fileServer")" = "object" ]; then
    fsf=$(json_get "$pf" "fileServer.folder"); fsu=$(json_get "$pf" "fileServer.url")
    say "    Shared folder: $(safe_display "${fsf:-—}" 200)"
    say "                   reached at $(safe_display "${fsu:-—}" 4096)"
  else
    say "    Shared folder: none — attachments stay inside the conversation"
  fi
  return 0
}

# `i` at the replace gate. A named function rather than an id in the explanation
# catalog because it has to name the gateway's own id in the line that matters
# most (the --edit alternative), and the catalog's arms take no arguments.
gw_explain_replace_saved_setup() {
  local unsure
  if [ "${GW_REPLACE_EDITABLE:-true}" = "true" ]; then
    unsure="If only ONE value has changed — the web address moved, or you want a different model — say No, and run 'bash conduck-connect.sh --edit ${GW_REPLACE_ID:-<gateway>}' instead. That asks the one question, re-checks it, and leaves the rest of the saved setup alone."
  else
    # No alternative to offer, so none is invented: the edit surface reads saved
    # setups through the same validator that has just refused this file.
    unsure="There is no way to change one value inside a saved file this version cannot read — updating conduck-connect is what opens it again. Say No if that file is worth keeping; nothing else on this machine is waiting on this answer."
  fi
  explain_panel \
    "Whether to replace the setup this machine has already saved for ${GW_REPLACE_NAME:-this gateway}" \
    "One gateway, one saved setup. ${GW_REPLACE_NAME:-This gateway} is filed under a fixed id, so a second run writes over the record of the first instead of sitting beside it. Only a server you set up yourself (option 3 at the first question) can have several, because each of those is given a name and the name is what keeps them apart." \
    "Yes carries on with setup. The steps after this one decide how this gateway is reached from outside — that is where its web address comes from — and whether it has a shared folder; what they produce is saved in place of the values printed above. Its port and its key are read from the gateway's own settings, so you never type those. No stops the run without writing anything." \
    "The run stops there and makes no further change. Your saved setup stays exactly as it is, and so does the app on your phone. (It is not a claim that this run has changed nothing at all: before it reaches this question it offers to close any leftover Tailscale mapping from an earlier run, and you may already have said yes to that.)" \
    "The old values are not kept anywhere — this script keeps no history of them, so the printout above is the last you see of them. Either way this question does not touch the gateway itself, the folder it works in, or the setup code already scanned into the app: that app keeps using the address and key it was given until you scan a new code." \
    "$unsure"
}

# The gate itself. Called at the TOP of Step 2 for both first-class gateways —
# before a config file is read, before a flag is switched, before anything is
# exposed — because consent to lose the record has to come before the work that
# depends on it. The cost of asking here is that this run's REPLACEMENT values
# are not known yet, so the screen names the fields that will be replaced rather
# than the values that will replace them. That trade is the right way round: a
# review screen at the end would ask for consent after the host had already been
# changed, which is the one thing the tool's per-mutation-consent model refuses.
gw_guard_single_saved_setup() { # gw_guard_single_saved_setup <id> <display-name>
  # Split, not one `local id=… pf=…$id…`: a mid-`local` self-reference reads the
  # OUTER value (or nothing at all under `set -u`), which is the same trap
  # report_gateway_id_collision documents a few functions down.
  local id="$1" name="$2" pf="" readable=true
  pf="$STATE_DIR/profile-$id.json"
  [ -f "$pf" ] || return 0
  # Defaulted like every other latch the test harnesses lift a function without:
  # an unset global would abort the whole run under `set -u`, and this one has to
  # be the safest possible read. Set BEFORE the branches, not after the answer:
  # every exit below is "this screen has been shown for this id", including the
  # two flag branches that never ask.
  [ "${GW_REPLACE_ASKED_ID:-}" = "$id" ] && return 0
  GW_REPLACE_ASKED_ID="$id"
  GW_REPLACE_ID="$id"; GW_REPLACE_NAME="$name"; GW_REPLACE_EDITABLE=true
  say ""
  # The same validator the picker and --show-code use, so "can't read it" here
  # means exactly what it means there — including for the edit surface, which is
  # why the alternative below is offered only when this passes.
  if show_qr_validate_profile "$pf"; then
    warn "This machine already has a saved $name setup, and going on replaces it."
    say ""
    say "  ${BOLD}What is saved now:${RESET}"
    gw_print_saved_setup_summary "$pf"
  else
    readable=false; GW_REPLACE_EDITABLE=false
    # An unreadable file makes the replacement MORE consequential, not less: one
    # this version cannot parse is one a NEWER conduck-connect wrote, and
    # overwriting it is what makes the newer script's record unrecoverable. So
    # the branch says what it cannot show, and names the file so the operator can
    # copy it somewhere first.
    warn "This machine already has a saved $name setup, in a file this version can't read."
    note "$pf"
    note "A newer conduck-connect wrote it, so its values can't be shown here. Updating this"
    note "script is what recovers them; going on replaces the file and they are gone."
  fi
  say ""
  say "  conduck-connect saves ONE setup per gateway, and $name is always filed"
  say "  under the id '$id'. This run updates that one — it cannot add a second"
  say "  $name beside it. (Servers you set up yourself, option 3, can sit side by"
  say "  side: each of those is given a name, and the name keeps them apart.)"
  say ""
  # "Re-asks the address" would be wrong for these two: OpenClaw and Hermes are
  # never asked for a web address or a model at all — the address is whatever
  # Step 3 publishes, and the port and token come out of the gateway's own config
  # file. So the sentence names the STEPS that produce the saved values, which is
  # also what tells the reader where in the run the replacement gets decided.
  say "  Going on re-does the steps that produced those values — how this gateway is"
  say "  reached from outside, and whether it has a shared folder — and saves what"
  if $readable; then
    say "  this run ends up with in place of the values above."
  else
    say "  this run ends up with in place of whatever that file holds."
  fi
  say "  Not touched either way: $name itself, the folder it works in, and the setup code"
  say "  already scanned into the app — that app keeps using the address and key it was"
  say "  given until you scan a new code."
  say ""
  if $readable; then
    # Named by what it does, not by the flag alone: somebody reading this has a
    # working setup and one broken value in it, and "there is a flag" is not an
    # answer to that. This is the moment the shorter way round is worth knowing.
    say "  ${BOLD}Only one value to change${RESET} — an address that moved, a different model?"
    say "    ${BOLD}bash conduck-connect.sh --edit $id${RESET}"
    say "  asks that one question, re-checks it, and leaves the rest of the saved setup"
    say "  alone. No exposure step, no new file server, no walk through this wizard."
  else
    # Offering the edit surface here would be offering a door that is locked from
    # the same side: it reads saved setups through the validator that has just
    # refused this one. The only thing that opens it is a newer script.
    say "  Editing one value instead is not available for a file this version can't read —"
    say "  updating conduck-connect is what opens it. Replacing it here is the other way,"
    say "  and it is one-directional."
  fi
  say ""
  # A dry run writes no profile at all (write_profile returns early), so there is
  # nothing to consent to — but printing what a real run would do to this host is
  # the entire job of --dry-run, and losing a saved setup is one of the larger
  # entries on that list.
  if $DRY_RUN; then
    note "(dry-run: nothing is written, so the saved setup stays as it is — a real run asks first)"
    # The plan is headed "in order", and this entry is added first while the
    # replacement itself happens LAST — write_profile runs after a code has been
    # emitted — so the line carries its own timing rather than borrowing the
    # list's.
    plan_add "REPLACE the saved setup in $pf with this run's answers (last, and only if the run ends in a working setup code)"
    return 0
  fi
  # --reuse-only refuses configuration changes, and write_profile counts an
  # existing profile as configuration: it keeps the file exactly as it is. There
  # is nothing to lose here, so there is nothing to gate.
  if $REUSE_ONLY; then
    note "(--reuse-only: the saved setup above is kept exactly as it is — this run reuses what exists and rewrites no record)"
    return 0
  fi
  # Enter is No, which is the safe direction: a closed stdin, or an operator in
  # Enter-rhythm, stops the run rather than spending the record. Not a typed
  # confirmation — that is reserved for removal, which takes the file server and
  # the credential with it. This one only re-asks questions the operator is here
  # to answer, and gating it behind typing would train the reflex out of the
  # place it exists for.
  confirm "  Replace the saved $name setup?" "gw_explain_replace_saved_setup" && return 0
  say ""
  note "↩ Stopping instead — your saved $name setup is exactly as it was."
  $readable && note "To change one value in it without a full run:  bash conduck-connect.sh --edit $id"
  quit_run
}

configure_openclaw() {
  head_ "Step 2 — OpenClaw: chat endpoint + key"
  GW_ID="openclaw"
  local cfg="$HOME/.openclaw/openclaw.json"
  [ -f "$cfg" ] || die "Cannot find $cfg — is OpenClaw onboarded on this machine? (Run its onboarding first; this script doesn't install gateways.)"
  # Before the config is read and before any flag is touched: a second run of a
  # first-class gateway replaces the first one's saved setup, and this is the
  # only point in the run where saying so is still cost-free.
  gw_guard_single_saved_setup "openclaw" "OpenClaw"

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
      # Enter here means "no, I skipped it", so skipping is now the answer a
      # reader in Enter-rhythm gives — and it has to be named rather than passed
      # over in silence. The re-read just below is what settles the truth either
      # way; this line only makes the transcript say which of the two happened.
      print_and_wait "gateway.openclaw.manual_enable_chat" \
        "Your OpenClaw doesn't look like the standard Docker setup, so apply the flag with your own install's CLI, then restart the gateway." \
        "openclaw config set gateway.http.endpoints.chatCompletions.enabled true" \
        || note "(skipped — the chat endpoint stays off unless something else already turned it on)"
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
  # Same gate, same reason as configure_openclaw's: "hermes" is a fixed id, so a
  # second run of this step replaces the saved setup of the first, and this is
  # the last point where that costs nothing to say.
  gw_guard_single_saved_setup "hermes" "Hermes"

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
        # Skipping is Enter, so it is the likely answer and gets said out loud:
        # the .env is written either way, and a Hermes still running on the old
        # settings fails verification for a reason that has nothing to do with
        # the address or the key.
        print_and_wait "gateway.hermes.manual_restart_api" \
          "Restart Hermes however it runs on this machine so the new API server settings load." \
          "systemctl --user restart hermes-gateway.service   # or your own restart method" \
          || note "(not restarted — the settings are written, but Hermes keeps running with the old ones until it restarts)"
      fi
    else
      note "(skipped — verification below will fail if the API server is off)"
    fi
  fi

  GW_TOKEN=$(env_get "$envf" "API_SERVER_KEY")
  if [ -n "$GW_TOKEN" ]; then ok "Read API_SERVER_KEY from ~/.hermes/.env (not shown)."
  elif $DRY_RUN; then note "(dry-run: would prompt for the Hermes API server key)"
  else
    prompt_into GW_TOKEN ask_secret "Paste the Hermes API server key (hidden)" \
      "stop; Hermes requires a key" "gateway.token"
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

# What is listening on this machine right now, as "<port>\t<program>" lines.
#
# This exists because the port question is the one value in the wizard its
# intended reader most often cannot supply from memory, and the machine already
# knows the answer. It is READ-ONLY and best-effort by design: every tool here is
# run without privilege (so on macOS it sees only this user's own processes,
# which is where their gateway almost certainly is), nothing is installed, and a
# machine with none of these tools simply gets the typed prompt with no list and
# no complaint. This must never become a dependency — `have` gates every branch.
gw_scan_listening() { # -> "<port>\t<program>" lines on stdout, possibly none
  case "${OS:-}" in
    Darwin)
      have lsof || return 0
      # -n/-P skip DNS and service-name lookups (fast, and no outbound query);
      # -w silences the warnings an unreadable process directory produces. The
      # NAME column is the last field: "127.0.0.1:11434", "*:8080", "[::1]:631".
      lsof -nP -w -iTCP -sTCP:LISTEN 2>/dev/null \
        | awk 'NR>1 {
            n=$NF; if (n ~ /^\(/) n=$(NF-1)      # the NAME column carries a trailing "(LISTEN)"
            sub(/.*:/,"",n)
            if (n ~ /^[0-9]+$/) printf "%s\t%s\n", n, $1
          }'
      ;;
    *)
      # ss first: it is what modern Linux ships and it needs no privilege to
      # list sockets (only the OWNING PROGRAM is redacted without it, which
      # costs a label, not a row). netstat is the fallback on older systems,
      # lsof the last resort.
      if have ss; then
        ss -ltnp 2>/dev/null | awk '
          $1=="LISTEN" {
            a=$4; sub(/.*:/,"",a); prog="";
            if (match($0, /users:\(\("[^"]+"/)) { prog=substr($0, RSTART+9, RLENGTH-9); gsub(/"/,"",prog) }
            if (a ~ /^[0-9]+$/) printf "%s\t%s\n", a, prog
          }'
      elif have netstat; then
        netstat -ltnp 2>/dev/null | awk '
          /LISTEN/ {
            a=$4; sub(/.*:/,"",a); prog=$NF; sub(/^[0-9]*\//,"",prog);
            if (prog=="-" || prog ~ /:/) prog="";
            if (a ~ /^[0-9]+$/) printf "%s\t%s\n", a, prog
          }'
      elif have lsof; then
        lsof -nP -w -iTCP -sTCP:LISTEN 2>/dev/null \
          | awk 'NR>1 {
            n=$NF; if (n ~ /^\(/) n=$(NF-1)      # the NAME column carries a trailing "(LISTEN)"
            sub(/.*:/,"",n)
            if (n ~ /^[0-9]+$/) printf "%s\t%s\n", n, $1
          }'
      fi
      ;;
  esac
}

# The scan, deduplicated by port and ordered so the likeliest answer is row 1.
#
# The rank list is the ONLY place vendor port numbers appear in this module, and
# it is deliberately invisible: it decides ordering, never wording, so it cannot
# drift out of step with the numbers `gateway.custom.port`'s explanation panel
# prints. A port that is not on it is still offered, one row lower.
gw_port_candidates() { # -> "<port>\t<program>" lines, likeliest first
  # Only IANA's registered range, 1024-49151, is offered. Below it are the
  # system's own privileged services (ssh, printing, file sharing); above it is
  # the dynamic range the operating system hands out to short-lived connections,
  # which on a Mac is most of what a scan returns. Neither is where a person
  # starts an AI server, and every one of them listed is a row the reader has to
  # rule out by hand. A gateway genuinely on 80, 443 or 50000 is not lost: `t`
  # takes any number at all, and a gateway already reachable over https belongs
  # on the other branch of this question anyway.
  gw_scan_listening | awk -F'\t' '
    $1 >= 1024 && $1 <= 49151 && !seen[$1]++ {
      likely = ($1==11434 || $1==1234 || $1==4000 || $1==8000 || $1==8642 || $1==18789) ? 0 : 1
      printf "%d\t%s\t%s\n", likely, $1, $2
    }' | sort -t"$(printf '\t')" -k1,1n -k2,2n | cut -f2-
}

GW_PORT_LIST_MAX=8   # a busy laptop listens on dozens of ports; a wall of them helps nobody

# Offer the detected ports as a numbered list, the same shape
# pick_existing_custom_gateway uses for saved profiles — with one deliberate
# difference: the escape row is the letter `t`, not the next number. This list's
# length depends on what the machine happens to be running, so a numbered escape
# row would sit on a different key every run and on every machine. `t` is fixed,
# and it is the same idiom as the welcome menu's `q) Exit`.
gw_offer_listening_ports() { # 0 = GW_LOCAL_PORT set / 2 = no list, or "type it" / 10 back / 1 EOF
  local rows=() line i n p pick rc extra=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ ${#rows[@]} -lt "$GW_PORT_LIST_MAX" ]; then rows+=("$line"); else extra=$((extra+1)); fi
  done <<EOF
$(gw_port_candidates)
EOF
  [ ${#rows[@]} -gt 0 ] || return 2

  say ""
  say "  ${BOLD}Programs listening on this machine right now:${RESET}"
  i=1
  for line in "${rows[@]}"; do
    n="${line%%$'\t'*}"; p="${line#*$'\t'}"
    # The program name comes from the operating system, so it is the one label
    # here that cannot go stale — and it is what the reader actually recognises
    # ("ollama", "python3"), far more than the number beside it.
    if [ -n "$p" ]; then printf '    %d) port %-6s — %s\n' "$i" "$n" "$(safe_display "$p" 40)"
    else                 printf '    %d) port %s\n' "$i" "$n"; fi
    i=$((i+1))
  done
  say "    t) Not listed — I'll type the port number myself"
  [ "$extra" = "0" ] || note "($extra more are listening than fit here; t takes any number.)"
  say ""
  while true; do
    # Explicit statuses rather than prompt_into: EOF has to travel back to
    # configure_generic as 1 so it can say what was missing (see the header of
    # ask_custom_gateway_port).
    pick=$(require_choice "Which one is your AI server? Choose 1-$((i-1)), or t" '^([0-9]{1,3}|[tT])$' "gateway.custom.port" true); rc=$?
    case "$rc" in
      0)  ;;
      10) return 10 ;;
      11) quit_run ;;
      *)  return 1 ;;
    esac
    case "$pick" in
      [tT]) return 2 ;;
    esac
    if { [ "$pick" -ge 1 ] && [ "$pick" -lt "$i" ]; } 2>/dev/null; then
      line="${rows[$((pick-1))]}"
      GW_LOCAL_PORT="${line%%$'\t'*}"
      p="${line#*$'\t'}"
      if [ -n "$p" ]; then ok "Using port $GW_LOCAL_PORT — the one $(safe_display "$p" 40) is listening on."
      else                 ok "Using port $GW_LOCAL_PORT."; fi
      return 0
    fi
    warn "Please enter a number between 1 and $((i-1)), or t to type the port yourself."
  done
}

# The typed port prompt. `t` is accepted as a no-op here so that the same answer
# works whether or not a list was offered — a reader who has just been told
# "press t to type it yourself" should not be told off for pressing it again.
gw_read_port_number() { # sets GW_LOCAL_PORT; 0 value / 10 back / 1 EOF
  local reply p
  p="  Port number, 1-65535 ($(control_suffix "ask again" true)): "
  while true; do
    prompt_echo "$p"
    read -r -p "$p" reply || return 1
    case "$reply" in
      [iI]|\?) explain_prompt "gateway.custom.port"; continue ;;
      [bB]) return 10 ;;
      [qQ]) quit_run ;;
      [tT]) continue ;;
      # Enter is an advertised no-op here (the suffix says "ask again"), so it is
      # a note rather than a telling-off — pressing it at a question with no
      # default is a pause, not a mistake.
      '') note "Nothing entered — a server running on this machine needs its port number." ;;
      *[!0-9]*) warn "That's not a port number — digits only." ;;
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

# The port question, in the order a reader needs it: what the number IS, then
# what this machine can already tell us, then the typed fallback. `b` is safe
# throughout because a custom-server answer has changed nothing yet; it returns
# to the https:// question, which is the answer somebody who lands here by
# mistake actually wants to change.
#
# EOF returns 1 rather than dying, so configure_generic can name what is missing.
ask_custom_gateway_port() { # sets GW_LOCAL_PORT; 0 value / 10 back / 1 EOF
  local rc
  say "  Which port on this machine does your server listen on?"
  say "  It's the number after the last colon in the address your server prints when"
  say "  it starts up: http://localhost:8080 means 8080."
  gw_offer_listening_ports; rc=$?
  case "$rc" in
    0|1|10) return "$rc" ;;
  esac
  gw_read_port_number
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
report_gateway_id_collision() { # report_gateway_id_collision <id> [name-just-typed]
  # Split, not one `local id=… pf=…$id…`: a mid-`local` self-reference is
  # unbound under `set -u` (the same trap tls_connect_target documents).
  local id="$1" typed="${2:-}" pf="" n=""
  pf="$STATE_DIR/profile-$id.json"
  say ""
  # Readable-or-not is decided by the SAME validator the picker lists with, not by
  # whether a name happens to parse out. A profile from a newer conduck-connect
  # still carries a readable name, so keying on the name would greet an unlisted
  # setup as though the operator could see it in the list above.
  if [ -f "$pf" ] && show_qr_validate_profile "$pf"; then
    n=$(json_get "$pf" "gateway.name")
    bad "That name belongs to a gateway you already set up: $(safe_display "${n:-$id}" 60)  (id: $id)"
    # Two names that read as obviously different can produce one id, and without
    # this the refusal is unanswerable: the operator is looking at a name they
    # did not type, being told it is the name they did. The rule is stated
    # rather than hinted at, because it is the only way to pick a name that
    # will not collide again on the next try.
    if [ -n "$typed" ] && [ -n "$n" ] && [ "$typed" != "$n" ]; then
      say "  Those two names do read differently — but the identity here isn't the name."
      say "  It's a short form of it: lowercased, anything that isn't a letter or digit"
      say "  turned into a hyphen, and cut to 32 characters. Both of yours end up filed"
      say "  as '$id'."
    fi
    say "  Setting it up again from here would overwrite that one's saved setup and take"
    say "  over its file server — not add a second gateway."
  elif [ -f "$pf" ]; then
    bad "A saved gateway already uses the id '$id'."
    say "  Its saved file can't be read by this version, so it isn't offered in the list"
    say "  above — but the id stays reserved rather than being overwritten."
  else
    # There are TWO ways to arrive here and the message named only one of them.
    # The other is the most plausible piece of self-service cleanup this tool
    # invites: profile-<id>.json is plain JSON with no secret in it, so deleting
    # it looks exactly like deleting the gateway — and it is not. The file server
    # keeps running, authenticated, over the agent's own working folder, and the
    # id stays occupied by the unit and the credential nobody removed. Naming one
    # cause made the message half-right in the case where being wrong costs the
    # most, so it names both and then points at the one surface that can say
    # which of them this machine has.
    bad "Something on this machine already answers to the id '$id', with no saved setup beside it."
    say "  A file server and its password are filed under that id — left either by an"
    say "  earlier, unfinished run, or by a saved setup that was deleted by hand while its"
    say "  file server carried on running. Reusing the id would silently adopt them: the"
    say "  same service, the same port, the same password."
    # By what it does, not by the flag alone — and deliberately without promising
    # which of the two causes it will report, because that is the inventory's
    # answer to give.
    note "To see what is left over on this machine — and the exact commands that stop and"
    note "remove it:  bash conduck-connect.sh --list"
    # This arm gets its own closing line. "Pick that gateway from the list" is the
    # right advice in the two arms above and nonsense here: there is no saved
    # gateway, so there is nothing in the list to pick. The two real ways forward
    # are a different name now, or clearing the leftovers and coming back.
    note "So: give this one a different name, or clear those leftovers first and re-run me."
    return 0
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
  GW_PICKER_SHOWN=false
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
  GW_PICKER_SHOWN=true
  local pick rc
  while true; do
    # {1,3} length-bounds the input so the numeric compare can't overflow bash 3.2's intmax.
    # The statuses are read here rather than through prompt_into so that this
    # function stays liftable on its own: it is the one gateway function the host
    # suite exercises directly, against its own $STATE_DIR fixtures.
    pick=$(require_choice "Which one? Choose 1-$i" '^[0-9]{1,3}$' "nav.custom_gateway_pick"); rc=$?
    case "$rc" in
      0)  ;;
      11) quit_run ;;                # q — the primitive no longer echoes a sentinel
      *)  die "$NO_ANSWER" ;;
    esac
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
  note "I'll ask for its address and key again — the address can have moved, and the"
  note "key is never saved."
  return 0
}

# Auth for a custom gateway, taken at ONE hidden prompt rather than a visible
# [y/N] followed by a hidden one. A question whose own wording names the key
# invites a paste, and an echoing prompt shows what it receives: the
# key was printed, refused as not-a-yes-or-no, and left in the terminal's
# scroll-back — one line before the hidden prompt that would have taken it
# safely. Asking for the secret directly gives the paste exactly one place to
# land, and that place shows nothing.
#
# Keyless stays EXPLICIT, which is the fail-closed-auth invariant the app holds
# too: an empty answer opens a question, never settles one, and only an
# affirmative confirm sets auth=none. EOF is not an empty answer — ask_secret
# returns nonzero for it, so a redirected run dies instead of reading "nobody
# was there to answer" as "this gateway needs no key".
ask_custom_gateway_auth() { # sets GW_AUTH + GW_TOKEN; dies on EOF, exits on q
  # A dry run must never solicit a real secret, so it takes the mode as a
  # bounded choice instead. `<token>` is the same placeholder the rest of the
  # dry-run path already carries; nothing is stored either way.
  if $DRY_RUN; then
    say "  Does this server require a key on every request?"
    say "    1) Yes — it requires a key"
    say "    2) No  — it is keyless"
    # No hand-rolled "('i' explains)" here: require_choice renders its own
    # control list, and a second one beside it is what trains a reader to stop
    # reading the suffix that carries the keys the prompt really honours.
    local c
    prompt_into c require_choice "Choose 1-2" '^[12]$' "gateway.custom.has_auth"
    if [ "$c" = "1" ]; then
      GW_AUTH="bearer"; GW_TOKEN="<token>"
      note "(dry-run: a real run asks for the key at a hidden prompt)"
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
    say "  If this server needs a key, paste it now — nothing appears as you type."
    prompt_into GW_TOKEN ask_secret "Key" "this server is keyless" "gateway.token"
    # An all-whitespace answer is a fumbled paste, not a token and not a
    # deliberate Enter. Letting it through mints a setup code the app parses and
    # then refuses to save, which strands the operator a step later than here.
    case "$GW_TOKEN" in
      *[![:space:]]*) ;;
      ?*) warn "That was only whitespace. Paste the key again, or press Enter for keyless."
          GW_TOKEN=""; continue ;;
    esac
    if [ -n "$GW_TOKEN" ]; then
      GW_AUTH="bearer"
      ok "Key held for this run — it rides in the setup code and is never written to the saved profile."
      return 0
    fi
    note "Keyless — fine on a private network (Tailscale/LAN) where the network is the auth."
    note "On a PUBLIC transport a keyless server is wide open; I'll guard against that below."
    if confirm "  Confirm this server needs NO key?" "gateway.custom.has_auth"; then
      GW_AUTH="none"; GW_TOKEN=""
      return 0
    fi
    say ""; note "↩ Let's take the key again."
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
  local c
  prompt_into c require_choice "Choose 1-3" '^[123]$' "gateway.custom.model"
  case "$c" in
    1) : ;;                                              # GW_MODEL already holds it
    2) prompt_into GW_MODEL ask "  Model name" "" "let the server pick" "gateway.custom.model" ;;
    3) GW_MODEL="" ;;
  esac
}

review_custom_gateway() { # 0 continue / 10 re-enter / exits on q
  local address auth model reply p
  if [ -n "$GW_URL" ]; then address="$GW_URL"
  else address="http://127.0.0.1:$GW_LOCAL_PORT (local; HTTPS comes next)"; fi
  if [ "$GW_AUTH" = "bearer" ]; then auth="Key configured (hidden)"
  else auth="No key — allowed only on a private path unless explicitly overridden"; fi
  # "Server/app default (no model fixed in the setup code)" described the wire
  # payload, in a row headed by the word the reader typed nothing into — so the
  # commonest, most correct answer here read as a report of something missing.
  # This says the same fact as an outcome instead.
  if [ -n "$GW_MODEL" ]; then model=$(safe_display "$GW_MODEL" 4096)
  else model="Whichever model your server picks (you named none — that is normal)"; fi

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
  # and is otherwise invisible until two gateways quietly share one. "Id" was a
  # bare field name for a value the operator never chose and never sees again,
  # so the row now says what the value is FOR, which is the only reason it earns
  # a line on a five-line screen.
  say "    Filed under:    $GW_ID   ${DIM}(its settings and service files use this)${RESET}"
  say "    Address:        $(safe_display "$address" 4096)"
  # 127.0.0.1 is the one value on this screen the tool put there itself, and a
  # reader who has never seen it cannot tell whether it is their machine, a
  # placeholder, or a mistake. Glossed only on the local branch: an operator who
  # typed their own https:// address needs no help reading it back.
  if [ -z "$GW_URL" ]; then
    say "                    ${DIM}127.0.0.1 means this machine talking to itself, so${RESET}"
    say "                    ${DIM}nothing outside reaches it yet — that is Step 3's job.${RESET}"
  fi
  say "    Authentication: $auth"
  say "    Model:          $model"
  # A rename here changes the label and nothing else, and the operator has just
  # been shown the id it does NOT change. Saying so now is what makes a later
  # "that name belongs to <the old name>" refusal readable instead of baffling.
  if $GW_EDITING && $GW_RENAMED; then
    say ""
    note "The new name is what the Conduck app shows. This gateway stays filed under"
    note "$GW_ID — its saved settings, its file service and its stored password"
    note "all keep the old name, so they go on matching each other."
  fi
  say ""
  while true; do
    p="  Enter = continue; b = re-enter these answers; i = explain; q = stop: "
    prompt_echo "$p"
    read -r -p "$p" reply || die "$NO_ANSWER"
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

    GW_EDITING=false; GW_RENAMED=false
    if pick_existing_custom_gateway; then GW_EDITING=true; fi

    # Back at the name is offered only when the picker put a list on screen —
    # that is the question Back would return to. On a machine with nothing saved
    # the name IS the first question, and a `b` that re-asks the same prompt is
    # the kind of hollow control this release exists to remove.
    local name_back=false; $GW_PICKER_SHOWN && name_back=true
    if $GW_EDITING; then
      # The name is DISPLAY only from here on: re-slugging an edited name would
      # mint a fresh id and rebuild the exact duplicate this picker exists to
      # prevent — and then the one thing the operator came here to fix, a
      # mistyped name, would be the one thing they cannot fix.
      local prior_name="$GW_NAME"
      prompt_into GW_NAME ask "  A short name for it (shown in the app)" "$GW_NAME" "" \
        "gateway.display_name" "$name_back" \
        || { say ""; note "↩ Back to the list of saved gateways."; continue; }
      [ "$GW_NAME" = "$prior_name" ] || GW_RENAMED=true
    else
      prompt_into GW_NAME ask "  A short name for it (shown in the app)" "My gateway" "" \
        "gateway.display_name" "$name_back" \
        || { say ""; note "↩ Back to the list of saved gateways."; continue; }
      GW_ID="custom-$(slug "$GW_NAME")"; [ "$GW_ID" = "custom-" ] && GW_ID="custom-gateway"
      # A new gateway may never land on an occupied id. Warning and continuing is
      # not enough: the review screen's default is Enter, the file lane adopts the
      # occupant's credential before any profile is written, and write_profile
      # replaces the file atomically at the end — by then all three are gone.
      if gateway_id_is_taken "$GW_ID"; then
        report_gateway_id_collision "$GW_ID" "$GW_NAME"
        continue
      fi
    fi

    # The address group — the https:// gate and whichever question it leads to —
    # in its own loop. Back at either of those questions returns to the gate
    # that sent the operator there, not to the top: a wrong `y` here is the most
    # likely wrong answer in Step 2, and until now it stranded the run at a URL
    # prompt with no exit at all. Back at the gate itself restarts the group,
    # which is where the name lives.
    local addr_rc
    while true; do
      GW_URL=""; GW_LOCAL_PORT=""
      confirm "  Does it already have an https:// URL?" "gateway.custom.has_https" true
      addr_rc=$?
      case "$addr_rc" in
        10) break ;;                      # back at the gate → restart the group
        0)  prompt_into GW_URL ask_url "Its full https:// web address" "https://ai.example.com" \
              0 "" "gateway.custom.address" true && { apply_gateway_url_normalization; break; }
            say ""; note "↩ Back to the https:// question."
            continue ;;
        *)  ask_custom_gateway_port; addr_rc=$?
            [ "$addr_rc" = "0" ] && break
            if [ "$addr_rc" = "10" ]; then
              say ""; note "↩ Back to the https:// question."
              continue
            fi
            die "Need the local port (or an https URL)." ;;
      esac
    done
    if [ "$addr_rc" = "10" ]; then
      say ""; note "↩ Restarting the custom gateway answers. Nothing has been changed."
      continue
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
        prompt_into GW_MODEL ask_default "Model name (your server reports exactly one):" \
          "$model_default" "gateway.custom.model"
      else
        prompt_into GW_MODEL ask "  Model name" "" "let your server pick" "gateway.custom.model"
      fi
    fi

    review_custom_gateway
    local review_rc=$?
    [ "$review_rc" = "0" ] && return 0
    [ "$review_rc" = "10" ] || return "$review_rc"
    say ""; note "↩ Re-entering the custom gateway answers. Nothing has been changed."
  done
}
