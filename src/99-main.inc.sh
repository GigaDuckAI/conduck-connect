# ----------------------------------------------------------------------- main --

prepare_setup_from_check() {
  local checked_kind="$1" checked_url="$GW_URL" checked_path="" parsed=""
  SETUP_FROM_CHECK=true
  GW_KIND="custom"
  GW_HEALTH_PATH=""
  GW_CERT_FP=""
  TRANSPORT=""
  SCOPE=""

  if [ "$checked_kind" = "adapter" ]; then
    GW_NAME=$(ask "  A short name for this adapter (shown in the app)" "My Conduck adapter")
  else
    GW_NAME=$(ask "  A short name for this server (shown in the app)" "My gateway")
  fi
  GW_ID="custom-$(slug "$GW_NAME")"; [ "$GW_ID" = "custom-" ] && GW_ID="custom-gateway"

  # A server check only proves a specific model is required when the model-less
  # request failed and an advertised model succeeded. Reuse that proven model;
  # otherwise leave selection open for the app instead of guessing among ids.
  GW_MODEL=""
  if [ "$checked_kind" = "server" ] &&
     [ "${COMPAT_MODEL_FIELD:-}" = "required" ] &&
     [ -n "${MODELS_FIRST_ID:-}" ]; then
    GW_MODEL="$MODELS_FIRST_ID"
    # Model ids are opaque server-owned strings. Preserve the exact advertised id:
    # LiteLLM routes and Hugging Face repository names can legitimately be long.
    ok "Reusing the exact model ID the successful check required: $GW_MODEL"
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
      GW_AUTH="bearer"; GW_TOKEN=""; GW_MODEL=""; GW_URL=""; GW_CERT_FP=""
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

  # The standalone checks do not need openssl; setup might need it for
  # certificate trust/pinning, so run the setup preflight after transitioning.
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
