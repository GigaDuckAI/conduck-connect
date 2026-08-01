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
  note "Reusing the checked address and authentication in memory; your token is not saved."
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
    if [ "$SETUP_FROM_CHECK_KIND" = "adapter" ]; then
      GW_NAME=$(ask "  A short name for this adapter (shown in the app)" "My Conduck adapter")
    else
      GW_NAME=$(ask "  A short name for this server (shown in the app)" "My gateway")
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
  if ! confirm "  Would you like to continue with setup and pairing?" "check.continue_setup"; then
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
