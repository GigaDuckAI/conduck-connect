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
    cloudflare) tr_h="Cloudflare Tunnel (public)" ;;
    # "public" is the transport for any address the operator supplied rather than a
    # route this script opened, and that now covers an unencrypted local one — so the
    # label is read off the SCHEME. Calling a plain-http address "trusted cert" would
    # be the one line on this screen that is not true of it.
    public) case "$GW_URL" in
              [Hh][Tt][Tt][Pp]://*) tr_h="the address you gave me (http:// — not encrypted)" ;;
              *) tr_h="your own HTTPS (trusted cert)" ;;
            esac ;;
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
  note "No secrets were prompted, no passwords minted, no requests sent, no QR emitted (the QR appears only on a real run)."
  print_plan_real_run_command
}

# The command this was a dry run OF, printed at the moment the reader decides to
# commit. "Re-run without --dry-run" is an instruction to edit a command line that
# may have scrolled away, or that a driving agent composed and discarded — and the
# flags are not decoration: --allow-keyless-public dropped by accident turns a run
# the operator planned into one the wizard refuses, and --reuse-only dropped by
# accident turns a plan that changes nothing into one that changes the host.
#
# So the line is RECONSTRUCTED from the flags this run is actually holding rather
# than quoted from a template. Everything except --dry-run survives; --dry-run is
# the one flag whose whole meaning is "not this time".
print_plan_real_run_command() {
  local cmd="bash conduck-connect.sh --setup"
  $REUSE_ONLY && cmd="$cmd --reuse-only"
  $ALLOW_KEYLESS_PUBLIC && cmd="$cmd --allow-keyless-public"
  say ""
  say "  ${BOLD}Ready? Run:${RESET}"
  say "    ${BOLD}$cmd${RESET}"
  if $LEGACY_GENERIC; then
    # --generic is the retired spelling the shipped app still emits. The real run
    # above is the current one, and it asks the gateway question --generic answers
    # silently, so say which answer keeps this plan intact.
    note "You used --generic, which is the older name for custom-server setup. The command"
    note "above asks the gateway question instead: choose the OpenAI-compatible option."
  fi
  note "A plan banks nothing: the real run asks all of these questions again, and each"
  note "change still asks before it happens. Nothing above is saved anywhere."
}
