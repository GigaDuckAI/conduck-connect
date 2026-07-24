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
