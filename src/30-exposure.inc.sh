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

# The "I run my own HTTPS" gate. The certificate must be one THIS machine already
# trusts, because that is the same bar the app applies on the phone: Apple's App
# Transport Security refuses an untrusted chain before the app is consulted, and a
# fingerprint pin cannot override it — a pin only NARROWS trust the device already
# has, it never grants it. So there is no accept-anyway arm to offer; an untrusted
# certificate ends the run, with the reason named and the free remedies listed.
classify_own_https() {  # GW_URL + SCOPE already set
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
