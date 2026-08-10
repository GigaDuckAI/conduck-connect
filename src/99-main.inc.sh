# ----------------------------------------------------------------------- main --

prepare_setup_from_check() {
  local checked_kind="$1" checked_url="$GW_URL" checked_path="" parsed=""
  SETUP_FROM_CHECK=true
  SETUP_FROM_CHECK_KIND="$checked_kind"
  GW_KIND="custom"
  GW_HEALTH_PATH=""
  TRANSPORT=""
  SCOPE=""

  # The name and id are NOT decided here — see resolve_setup_from_check_identity.
  # This function runs before run_setup takes the single-instance lock, and
  # choosing an identity means reading the saved profiles, file-lane units and
  # credential files that a second run may be writing at that moment.

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
  # The address as the operator TYPED it, kept for the copy-pasteable re-check line
  # a declined setup prints. $GW_URL cannot serve that purpose: the local-port branch
  # above deliberately empties it, so by the time somebody backs out of the exposure
  # menu the only surviving spelling of "the thing you just graded" is this one.
  SETUP_FROM_CHECK_URL="$checked_url"
  note "Reusing the checked address and authentication in memory; your token is not saved."
}

# The two endings that leave a COMPLETED check behind without pairing anything: the
# offer right after the check, and that same question re-asked when Back walks out
# of the exposure menu. Both are a deliberate No, so both say the same thing — the
# check proved something and it is not free to prove again.
#
# The re-check line carries the address. The operator's next move is usually to
# change one thing on the server and grade it again, and rebuilding
# `--check-server https://…` out of scroll-back is the friction that turns a
# two-minute retry into a re-read of the whole transcript.
check_declined_next_steps() { # check_declined_next_steps <server|adapter>
  local kind="$1" flag="--check-server" url
  [ "$kind" = "adapter" ] && flag="--check-adapter"
  url="${SETUP_FROM_CHECK_URL:-${GW_URL:-}}"
  say ""
  say "  ${BOLD}What you can do from here${RESET}"
  say "  Set it up and pair whenever you like:  ${BOLD}bash conduck-connect.sh --setup${RESET}"
  if [ -n "$url" ]; then
    say "  Grade this same address again:         ${BOLD}bash conduck-connect.sh $flag $url${RESET}"
  else
    say "  Grade an address again:                ${BOLD}bash conduck-connect.sh $flag${RESET}"
  fi
  note "Nothing from this check is saved. Setup asks its own questions and sends its own"
  note "requests, so coming back later costs the same quota this check just spent."
}

# The last question of a menu-entered action: one more turn at the hub, or done.
#
# The status is the ONLY channel out of the subshell menu_hub_loop runs each action
# in, which is why this exits rather than returning a value somebody has to thread
# back through six call frames. A run started by flag prints nothing here: MENU_HUB
# is false, and there is no menu behind it to return to — the operator is standing
# at the shell prompt they launched from.
offer_menu_return() {
  local reply
  [ "${MENU_HUB:-false}" = "true" ] || return 0
  interactive_terminal || return 0
  say ""
  while true; do
    read -r -p "  Enter = done; m = back to the menu: " reply || return 0
    case "$reply" in
      '')   return 0 ;;
      [mM]) exit "${MENU_RETURN_STATUS:-20}" ;;
      *)    warn "Press Enter to finish, or m to go back to the menu." ;;
    esac
  done
}

# Can anybody answer a question in this run?
#
# NOT the same question as interactive_terminal, and the difference is the whole
# point: piping answers into --setup is a supported way to drive it (the test
# suites do exactly that), so "stdin is not a tty" must not by itself refuse a run
# that is about to be answered perfectly well. Two things do prove nobody is there:
# CI declares itself a machine, and a stdin that is a character device while not
# being a terminal is /dev/null — a stream that will never deliver a byte, no
# matter how long the wizard waits.
# Anything else — a pipe, a file, a here-doc — may be carrying answers, so it is
# allowed through and fails, if it fails at all, at the prompt that runs dry.
nobody_can_answer() {
  case "${CI:-}" in 1|true|TRUE|yes|YES) return 0 ;; esac
  [ -t 0 ] && return 1
  [ -c /dev/stdin ] 2>/dev/null && return 0
  return 1
}

# Exit 4 — "this action requires an interactive terminal" — is a documented status
# in --help and in the file header, and a documented status nothing emits is worse
# than an undocumented one: it tells a wrapper author to write a branch that never
# runs. Setup asks questions and ends in a QR code somebody points a phone at, so
# there is no version of it a machine finishes.
#
# The refusal names what IS scriptable rather than stopping at "no". A driver that
# reaches this line wants an answer about a gateway, and three of this tool's
# commands give one with no terminal at all.
#
# The reason a machine cannot finish is a PARAMETER, because the commands that
# refuse do not all refuse for the same reason and a wrong reason is worse than a
# terse one: setup and the menu end in a code somebody scans with a phone, while
# --edit and --forget end in a question about a specific saved setup that only a
# person can answer. Passing no reason keeps the wizard's wording, which is what
# the two original callers want.
refuse_without_a_terminal() { # refuse_without_a_terminal <subject> [reason-line …]
  local subject="$1" line
  shift
  say ""
  printf '%sError:%s %s\n' "$RED" "$RESET" "$subject needs a person at a terminal." >&2
  if [ "$#" -gt 0 ]; then
    for line in "$@"; do say "  $line"; done
  else
    say "  There are questions to answer, and setup ends in a setup code somebody scans"
    say "  with the Conduck app on a phone, or pastes into the Mac app — so there is no"
    say "  point in this run at which a machine could finish it."
  fi
  say ""
  say "  ${BOLD}What runs with no terminal at all:${RESET}"
  say "    CI=1 CONDUCK_TOKEN=… bash conduck-connect.sh --check-server https://ai.example.com"
  say "    CI=1 CONDUCK_TOKEN=… bash conduck-connect.sh --check-adapter https://ai.example.com"
  note "Both end in one machine-readable summary line and never wait for an answer."
  note "CONDUCK_TOKEN keeps the bearer token out of argv and shell history; drop it for"
  note "a gateway with no key."
  say ""
  say "    bash conduck-connect.sh --list --json"
  note "Reports the setups this machine has already saved, and asks nothing. It is the"
  note "way to find the id that --edit and --forget want."
  say ""
  say "  From a terminal, to see every change setup would make and make none of them:"
  say "    ${BOLD}bash conduck-connect.sh --setup --dry-run${RESET}"
  exit 4
}

# The gateway identity for a check → setup handoff, asked under the setup lock.
#
# It runs the SAME selector and the same collision refusal as the gateway menu's
# custom path, because the id derived here keys the same three things — the saved
# setup, the file-lane service, and that service's credential — and a second copy
# of the derivation is a second place for a typo to build a duplicate gateway.
#
# Everything the check PROVED stays untouched: the address, the auth mode, the
# token in memory, and the graded model. Only the name and id are decided.
resolve_setup_from_check_identity() {
  local checked_model
  while true; do
    checked_model="$GW_MODEL"
    GW_EDITING=false
    if pick_existing_custom_gateway; then
      GW_EDITING=true
      # The picker restores the model this gateway used LAST time. The check just
      # graded one specific model path and the handoff must pair exactly that one,
      # so the checked value wins — an untested saved model would quietly replace
      # the only one this run has evidence for.
      GW_MODEL="$checked_model"
      return 0
    fi
    # The action-id is what makes `i` answer THIS question rather than the generic
    # panel: the name is the label the app shows in its gateway list, it is not the
    # gateway's address and it is not a secret, and gateway.display_name is the one
    # place that is written down. prompt_into rather than $(…) so that q here stops
    # the run in this shell — inside $(…) it would kill only the subshell and the
    # wizard would walk on with the literal answer as the gateway's name.
    if [ "$SETUP_FROM_CHECK_KIND" = "adapter" ]; then
      prompt_into GW_NAME ask "  A short name for this adapter (shown in the app)" \
        "My Conduck adapter" "" "gateway.display_name"
    else
      prompt_into GW_NAME ask "  A short name for this server (shown in the app)" \
        "My gateway" "" "gateway.display_name"
    fi
    GW_ID="custom-$(slug "$GW_NAME")"; [ "$GW_ID" = "custom-" ] && GW_ID="custom-gateway"
    gateway_id_is_taken "$GW_ID" || return 0
    report_gateway_id_collision "$GW_ID"
  done
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
  # Before the banner, because a refusal that arrives four screens into a wizard
  # nobody is reading is a worse refusal. A check that handed off has already
  # cleared interactive_terminal, so this only ever fires on a direct --setup.
  nobody_can_answer && refuse_without_a_terminal "Setup"
  say "${BOLD}conduck-connect $VERSION${RESET} — pair your self-hosted AI gateway with Conduck."
  if $LEGACY_GENERIC; then
    warn "--generic is the older name for custom-server setup. Continuing with custom-server setup."
  fi
  $DRY_RUN && note "(dry-run: nothing will be changed)"
  if $REUSE_ONLY; then
    note "(reuse-only: I'll reuse what's set up and refuse configuration changes; live verification still sends requests and may write/delete a file probe)"
  fi
  say "Gateway, service, and network changes ask first, and you see the exact command. No telemetry — verification talks only to your own gateway."
  note "At bounded questions: i explains this step, q stops, and b appears only where going back is safe. Every prompt states what Enter does."
  note "q or Ctrl-C stops the run; it does not undo an earlier change you approved. Exposure undo commands are preserved and printed if needed."

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
    # Under the lock, and before any port is picked or unit written: which saved
    # gateway is this, or is it a new one?
    resolve_setup_from_check_identity
    # Back at the exposure menu returns to the OFFER that started this setup, not
    # to the shell. The check that got here sent real chat requests — quota spent,
    # a message in somebody's provider history — and its result is still in memory,
    # so ending the process throws away something that costs money to reproduce.
    # The identity question stays outside the loop: it was answered under the lock
    # and nothing about going back to the exposure menu unanswers it.
    local exposure_rc
    while true; do
      choose_exposure && break
      exposure_rc=$?
      [ "$exposure_rc" = "10" ] || exit "$exposure_rc"
      say ""
      # The same question as the offer that started this setup, so a No here means
      # exactly what a No there meant: the check was the whole errand. It leaves by
      # the same ending and the same exit status, because a wrapper cannot be asked
      # to tell two spellings of one decision apart.
      if ! confirm "  Continue with setup and pairing after all?" "check.continue_setup"; then
        note "Setup stopped. The completed check changed nothing on your server."
        check_declined_next_steps "$SETUP_FROM_CHECK_KIND"
        offer_menu_return
        exit 0
      fi
    done
    apply_checked_path_prefix
  else
    # Gateway selection → configure → transport, looped so the transport menu's
    # "b" can return to the gateway choice. Detection informs the menu but never
    # selects a gateway: the user always makes an explicit 1/2/3 choice.
    while true; do
      GW_KIND=""; GW_ID=""; GW_NAME=""; GW_LOCAL_PORT=""; GW_HEALTH_PATH=""
      GW_AUTH="bearer"; GW_TOKEN=""; GW_MODEL=""; GW_URL=""; GW_EDITING=false
      detect_gateway
      case "$GW_KIND" in
        openclaw) configure_openclaw ;;
        hermes)   configure_hermes ;;
        custom)   configure_generic ;;
      esac
      choose_exposure && break
      local rc=$?
      [ "$rc" = "10" ] || break
      say ""; note "↩ Back to the gateway choice. Earlier approved gateway changes stay in place; setup is not transactional."
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
    # A plan is a decision aid, so the hub is exactly where its reader wants to be
    # next: they came to look before committing, and the commit is one menu item away.
    offer_menu_return
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
  # The highest-traffic ending in the whole check path: the default is No, and Enter
  # is what a reader presses at a [y/N] after ten green lines. It used to be the
  # quietest ending too — while the machine that will never read it was handed the
  # "To set it up later" line one screen earlier, gated on NOT being interactive.
  if ! confirm "  Would you like to continue with setup and pairing?" "check.continue_setup"; then
    note "Check complete. No setup changes were made."
    check_declined_next_steps "$kind"
    offer_menu_return
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

# Every action, in ONE place, reached identically by a flag and by the welcome
# menu. It is a function because the menu is a hub: menu_hub_loop runs it in a
# subshell so that each action's `exit` becomes a status the loop can read, and so
# that the next action starts from the globals the script was launched with rather
# than a half-filled draft an abandoned setup left behind.
#
# Nothing in here knows which entry it came from. That is deliberate — the moment a
# command has to ask "was I chosen from the menu?", the menu stops being a way to
# reach the same program and becomes a second one. The manage commands hold that
# line too: their id comes from $MANAGE_ID, which validate_cli fills from argv, and
# a menu-entered one simply finds it empty and asks.
dispatch_menu_command() {
  local rc=0
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
      offer_menu_return
      exit 0
      ;;
    setup)
      preflight
      run_setup
      offer_menu_return
      ;;
    # The three manage commands. Each ends at offer_menu_return, so a run that came
    # from the hub can go straight back to it — somebody who has just read their
    # inventory almost always wants to act on one line of it, and a tool that exits
    # after answering makes them start the program again to do so.
    list)
      # --list is scriptable and must answer with stdin closed, so it neither calls
      # nobody_can_answer nor asks anything. It also skips preflight: that gate
      # demands curl and openssl, which the wizard needs to mint credentials and
      # probe a gateway, and a command that only reads files on this disk has no
      # business refusing to run on a host without them. python3 is the one it
      # genuinely cannot do without — the saved profiles are JSON.
      need python3 || die "--list reads the saved setups with python3, and this host doesn't have it."
      manage_list
      offer_menu_return
      exit 0
      ;;
    edit)
      # Exit 4, not a prompt that reads EOF and guesses: an edit re-asks ONE value
      # and then re-verifies against a live gateway, so a driver that reached here
      # without a person would be answering a question about which saved setup to
      # change — and the wrong answer rewrites a working pairing.
      nobody_can_answer && refuse_without_a_terminal "Changing a saved setup" \
        "It asks what the new value should be — and, with no id, which saved setup you" \
        "mean — then rewrites and re-verifies only what that changed. There is no" \
        "version of it a machine can finish safely."
      preflight
      # No id means "ask me", which is the shape of the ABI rather than an accident:
      # passing an empty string as an id would make the manage module tell the two
      # cases apart by inspecting a value, and this way it never has to.
      if [ -n "$MANAGE_ID" ]; then manage_edit "$MANAGE_ID" || rc=$?
      else manage_edit || rc=$?; fi
      offer_menu_return
      exit "$rc"
      ;;
    forget)
      nobody_can_answer && refuse_without_a_terminal "Removing a saved setup" \
        "Removal is the one thing here that cannot be undone, and it is confirmed by" \
        "typing the id — deliberately not by pressing Enter — so it never completes" \
        "without a person deciding."
      # preflight would demand curl and openssl here. Removal sends no request and
      # mints no credential, and refusing to clean up a machine because it lacks the
      # tools for setting one up is exactly the dead end this command exists to end.
      need python3 || die "--forget reads the saved setup with python3 to know what to stop, and this host doesn't have it."
      # The status comes straight back out: 0 removed, 1 refused or no such setup,
      # 3 the operator backed out. Those are already this tool's contract for
      # success / runtime failure / stopped by the operator, which is why the manage
      # ABI was written to those three numbers rather than to its own.
      manage_forget "$MANAGE_ID" || rc=$?
      offer_menu_return
      exit "$rc"
      ;;
  esac
}

# The menu is a HUB: menu_hub_loop draws it, dispatches, and draws it again, so a
# wrong turn costs one action instead of the session. It returns only when the
# operator chooses to leave, and the two lines below then run exactly as they do
# for a flag-entered run — q at the welcome menu is a completed choice and still
# exits 0.
if [ "$COMMAND" = "menu" ]; then
  # Same refusal as --setup, one screen earlier: a menu nobody can answer is the
  # same dead end as a wizard nobody can answer, and "No answer (the input ended)"
  # at exit 1 tells a driver neither what went wrong nor what it could have run.
  nobody_can_answer && refuse_without_a_terminal "The welcome menu"
  menu_hub_loop
fi
validate_cli
[ "$COMMAND" = "exit" ] && { note "Nothing changed."; exit 0; }

dispatch_menu_command
