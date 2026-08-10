# ------------------------------------------------------ managing saved setups --
#
# The wizard writes a setup and then has no way to look at one again. Everything
# it leaves behind — a profile, a credential, a boot-persistent WebDAV server over
# the agent's working folder, sometimes a public HTTPS route — is reachable only by
# walking the whole wizard a second time, and the source says so out loud in
# fs_print_teardown: "this tool has no removal command, so copy-pasteable text IS
# the mechanism." This module is the other half: see what is saved, change one
# field of it, and remove one completely.
#
# Three rules shape everything below, and they are the reason this file is longer
# than its function list suggests:
#
#   1. NOTHING here prints a token, a WebDAV password, or a setup code as a side
#      effect. Listing and editing read $STATE_DIR, which holds two live secrets;
#      a surface whose whole job is "show me what I have" is exactly where one
#      leaks into a scroll-back or a pasted transcript.
#   2. Removal takes a TYPED confirmation, never [y/N]. It is the only irreversible
#      action in a program whose entire muscle memory is pressing Enter, and Enter
#      is No at every other gate precisely so that rhythm is safe — a [y/N] here
#      would make the one keystroke that has always been safe the one that is not.
#   3. Anything this module cannot PROVE it removed is reported as not removed,
#      with the exact command, and with the sentence "I did not run it". A removal
#      surface that overstates itself leaves a live authenticated file server on a
#      machine whose owner has been told it is gone.

# --json for --list. Owned here rather than in the argument parser because the
# parser sets a command and an argument and nothing else — every mode flag this
# surface honours is defined next to the code that reads it.
MANAGE_JSON=false
# The id the picker last resolved. Callers that pass their own variable name get
# it there too; this is the fallback channel for a caller that does not care to
# name one, and it is what makes manage_pick_profile usable from a one-liner.
MANAGE_ID=""

# The id charset, checked at EVERY entry point that takes one from outside.
# `$STATE_DIR/profile-$id.json` and `conduck-files-$id.service` are both built by
# concatenation, so an id containing `/` or `..` addresses a file this tool has no
# business touching — and the one command here that deletes files takes its id
# straight from the command line. The charset is the one show_qr_validate_profile
# already enforces on gateway.id, so nothing this script ever wrote can fail it.
manage_id_ok() { # manage_id_ok <id>
  case "${1:-}" in
    ''|*[!a-z0-9-]*) return 1 ;;
    *) return 0 ;;
  esac
}

manage_profile_path() { printf '%s/profile-%s.json' "$STATE_DIR" "$1"; }
manage_cred_path()    { printf '%s/fileserver-%s.cred' "$STATE_DIR" "$1"; }
manage_env_path()     { printf '%s/fileserver-%s.env' "$STATE_DIR" "$1"; }

# The service file for ONE gateway, by id. The id-bearing form only: the two
# legacy unnamed units (conduck-files.service, ai.gigaduck.conduck-fileserver.plist)
# belong to no id at all, which is why they are reported by the leftovers scan
# rather than removed by an id-addressed teardown.
manage_unit_path() { # manage_unit_path <id>
  if [ "$OS" = "Linux" ]; then
    printf '%s/.config/systemd/user/conduck-files-%s.service' "${HOME:-}" "$1"
  else
    printf '%s/Library/LaunchAgents/ai.gigaduck.conduck-files-%s.plist' "${HOME:-}" "$1"
  fi
}

# The gateway id a unit file is filed under — empty for the legacy unnamed units,
# which is the answer that matters: an id nothing can be derived from is an id no
# teardown can be attributed to, and the scan says exactly that instead of guessing.
manage_unit_id() { # manage_unit_id <unit-path>
  local b; b=$(basename "$1")
  case "$b" in
    conduck-files-*.service)           b="${b#conduck-files-}"; printf '%s' "${b%.service}" ;;
    ai.gigaduck.conduck-files-*.plist) b="${b#ai.gigaduck.conduck-files-}"; printf '%s' "${b%.plist}" ;;
  esac
}

# fs_unit_state answers about $FS_UNIT, a global the file-lane phase owns. Setting
# it as a LOCAL here means bash's dynamic scoping hands the value down to
# fs_unit_state (and to fs_unit_label under it) while the caller's own FS_UNIT —
# which may belong to a live setup run in the same process — is restored the moment
# this returns. Every function in this file that borrows a file-lane global does it
# this way, and does it for that reason.
manage_unit_state() { # manage_unit_state <unit-path> -> active | inactive | unknown | absent
  local FS_UNIT="$1"
  [ -f "$FS_UNIT" ] || { printf 'absent'; return 0; }
  fs_unit_state
}

# The served folder recorded in a unit, or empty when it cannot be read
# structurally. Never guessed from a text match: fs_unit_field is the same parser
# the file-lane phase trusts, and a folder recovered by any other means is a path
# this surface would print as fact.
manage_unit_folder() { # manage_unit_folder <unit-path>
  [ -f "$1" ] || return 0
  fs_unit_field "$1" folder 2>/dev/null || true
}

# Every saved setup on this machine, readable or not, one profile path per line.
# `profile-*.json`, not `profile-custom-*.json`: openclaw and hermes are saved the
# same way and have never appeared in any list this tool prints, which is how an
# operator ends up believing the tool forgot the gateway it set up for them.
manage_saved_profiles() {
  local pf
  for pf in "$STATE_DIR"/profile-*.json; do
    [ -f "$pf" ] || continue          # no matches → the literal glob
    printf '%s\n' "$pf"
  done
}

# The id a profile FILE is filed under, taken from its name rather than from
# gateway.id inside it. The filename is the operative one: write_profile names the
# file after $GW_ID, and the file-lane unit, its credential and its environment
# file are all named after that same value — so a hand-edited gateway.id would send
# a teardown at files that belong to something else.
manage_profile_id() { # manage_profile_id <profile-path>
  local b; b=$(basename "$1"); b="${b#profile-}"; printf '%s' "${b%.json}"
}

# A saved URL on its way to a screen or to the JSON, with any `user:pass@` in it
# removed first.
#
# The wizard never writes such a URL — `ask_url` refuses userinfo and the profile
# validator refuses it again on the way back in. But these surfaces deliberately
# read profiles the validator REJECTS, because their whole job is to show and to
# remove setups this version cannot otherwise use, and a hand-edited or
# older-version profile can carry `https://conduck:PASSWORD@files.example`. Printing
# that in an inventory, or emitting it into JSON an agent will log, publishes a
# password on a surface whose first rule is that it never prints one.
#
# The authority ends at the first /, ? or # — the same parse url_has_userinfo uses,
# so the two cannot disagree about where the credential was.
#
# The userinfo ends at the LAST `@` in that authority, never the first. A password
# is allowed to contain `@` — `https://conduck:pa@ss@gw.example` is one address, not
# two — and cutting at the first `@` publishes `ss@gw.example`: the tail of the
# password, still shaped like a `user:pass@host` authority, on the one surface whose
# first rule is that it prints no password. A host may not contain `@` at all, so
# the last one is always the separator and everything before it is the credential.
manage_safe_url() { # manage_safe_url <url> [max-chars]
  local u="$1" scheme rest auth
  if url_has_userinfo "$u"; then
    scheme="${u%%://*}"; rest="${u#*://}"
    auth="${rest%%[/?#]*}"
    u="$scheme://${auth##*@}${rest#"$auth"}   [a username and password were in this saved address; not shown]"
  fi
  safe_display "$u" "${2:-200}"
}

manage_kind_label() { # manage_kind_label <kind>
  case "$1" in
    openclaw) printf 'OpenClaw' ;;
    hermes)   printf 'Hermes' ;;
    custom)   printf 'OpenAI-compatible server' ;;
    *)        printf '%s' "$(safe_display "${1:-unknown}" 40)" ;;
  esac
}

# How the address is reached, in the words the exposure menu used when it was
# chosen. The reach word is repeated even when the transport implies it, because
# "public" is the fact an operator scanning this list is looking for and a
# transport name is not a synonym anybody should have to know.
manage_transport_label() { # manage_transport_label <transport> <reach>
  case "$1" in
    tailscale) printf 'Tailscale — private (your tailnet only)' ;;
    funnel)    printf 'Tailscale Funnel — PUBLIC (reachable from the internet)' ;;
    cloudflare) printf 'Cloudflare Tunnel — %s' "${2:-public}" ;;
    public)    printf 'your own HTTPS front — %s' "${2:-public}" ;;
    *)         printf '%s — %s' "$(safe_display "${1:-unknown}" 40)" "${2:-unknown}" ;;
  esac
}

# ------------------------------------------------------------------ --list --

# The inventory. rc 0 ALWAYS, including for an empty state directory: "you have
# saved nothing" is a complete and correct answer to "what have I saved", and a
# nonzero status there would make every wrapper treat a fresh machine as a fault.
manage_list() {
  if $MANAGE_JSON; then manage_list_json; return 0; fi

  head_ "Saved setups on this machine"

  # $STATE_DIR is named FIRST, before anything in it. Today the path reaches the
  # screen only inside a permissions warning and on the last line of a successful
  # pairing, so an operator who never hits a failure and has scrolled past the end
  # of one wizard run has genuinely never been told where their configuration is.
  say ""
  say "  ${BOLD}Where your configuration lives${RESET}"
  say "  $STATE_DIR"
  if [ -d "$STATE_DIR" ]; then
    note "One profile-<id>.json per saved setup. They hold routing facts only — address,"
    note "transport, model, folder — and are readable plain JSON."
  else
    note "That folder does not exist yet; the first finished setup creates it."
  fi

  local pf ids=() rejected_ids=() rejected_reasons=()
  while IFS= read -r pf; do
    [ -n "$pf" ] || continue
    if show_qr_validate_profile "$pf"; then
      ids+=("$(manage_profile_id "$pf")")
    else
      rejected_ids+=("$(manage_profile_id "$pf")")
      rejected_reasons+=("$PROFILE_VALIDATION_ERROR")
    fi
  done <<EOF
$(manage_saved_profiles)
EOF

  if [ ${#ids[@]} -eq 0 ] && [ ${#rejected_ids[@]} -eq 0 ]; then
    say ""
    note "No saved setups yet."
    say "  Pair one and it appears here:  ${BOLD}bash conduck-connect.sh --setup${RESET}"
    manage_leftovers_scan
    return 0
  fi

  local i id
  for (( i=0; i<${#ids[@]}; i++ )); do
    id="${ids[$i]}"
    say ""
    manage_print_one "$id" "$((i+1))"
  done

  if [ ${#rejected_ids[@]} -gt 0 ]; then
    say ""
    warn "Saved here but not usable by this version ($VERSION):"
    # Both halves go through safe_display, and the REASON needs it as much as the
    # id does: the validator's message quotes the profile's own path back, so an
    # id with an escape byte in it arrives here twice, once as itself and once
    # inside a sentence. The reason is a full sentence rather than a field, so it
    # is bounded generously — the cap is there to stop a pathological file, not to
    # abbreviate a message the operator is being sent to a text editor with.
    for (( i=0; i<${#rejected_ids[@]}; i++ )); do
      say "    $(safe_display "${rejected_ids[$i]}" 60)"
      note "$(safe_display "${rejected_reasons[$i]}" 4096)"
    done
    note "Their ids stay taken, which is why setup can refuse a name that looks free."
  fi

  manage_leftovers_scan

  # The two things a reader of this screen actually wants to do next. Printed
  # unconditionally, including when the only entries are unreadable ones — forget
  # is exactly the command for a profile this version cannot repair.
  say ""
  say "  ${BOLD}What you can do from here${RESET}"
  say "  Change one thing (address, model, folder):  ${BOLD}bash conduck-connect.sh --edit${RESET}"
  say "  Remove one completely:                      ${BOLD}bash conduck-connect.sh --forget <id>${RESET}"
  note "--edit asks which setup if you leave the id out. Both ask before changing anything."
  return 0
}

# One saved setup, as the rows an operator needs to recognise it and to judge
# whether it is still doing what they think. The live service state is read here
# rather than remembered, because the one question a saved record cannot answer is
# whether the thing it describes is still running.
manage_print_one() { # manage_print_one <id> [ordinal]
  local id="$1" ord="${2:-}" pf name kind url transport reach model auth
  local fsurl fsfolder fsreach unit state folder
  pf=$(manage_profile_path "$id")
  name=$(json_get "$pf" "gateway.name")
  kind=$(json_get "$pf" "gateway.kind")
  url=$(json_get "$pf" "gateway.url")
  transport=$(json_get "$pf" "gateway.transport")
  reach=$(json_get "$pf" "gateway.reach")
  model=$(json_get "$pf" "gateway.model")
  auth=$(json_get "$pf" "gateway.auth")
  fsurl=$(json_get "$pf" "fileServer.url")
  fsfolder=$(json_get "$pf" "fileServer.folder")
  fsreach=$(json_get "$pf" "fileServer.reach")

  # safe_display on every field: these come off disk as free text an earlier run
  # accepted at a prompt, the file is editable by its owner, and this is a
  # terminal — an embedded escape here would repaint the inventory it appears in.
  #
  # The id is no exception, and it is the one a reader will assume is already
  # clean. It is the FILENAME's id (see manage_profile_id), and the validator
  # that let this profile through checks the charset of gateway.id INSIDE the
  # file, never the name of the file itself — so `profile-<ESC>[2J.json` holding a
  # perfectly conformant gateway object reaches this line and clears the screen
  # the inventory is being drawn on. For an id this tool wrote, safe_display is a
  # no-op.
  local safe_id; safe_id=$(safe_display "$id" 60)
  if [ -n "$ord" ]; then
    say "  ${BOLD}$ord) $(safe_display "${name:-$id}" 60)${RESET}   ${DIM}($safe_id)${RESET}"
  else
    say "  ${BOLD}$(safe_display "${name:-$id}" 60)${RESET}   ${DIM}($safe_id)${RESET}"
  fi
  say "     Gateway:       $(manage_kind_label "$kind")"
  say "     Web address:   $(manage_safe_url "${url:-?}" 200)"
  say "     Reached by:    $(manage_transport_label "$transport" "$reach")"
  if [ -n "$model" ]; then
    say "     Model:         $(safe_display "$model" 200)"
  else
    say "     Model:         ${DIM}whichever model the server picks (none pinned)${RESET}"
  fi
  # Said out loud, on every setup, every time. Its absence from $STATE_DIR is a
  # deliberate design decision — this tool writes no token to disk — and an
  # operator who is not told that assumes the tool lost it, or worse, assumes it
  # IS here and treats the folder accordingly.
  #
  # The second half of the row is per-KIND, because "you re-enter it" is true of
  # exactly one of the three and this is the most security-relevant line on a
  # screen whose entire purpose is telling somebody what is and is not on their
  # disk. show_qr_recover_gateway_secret is the authority: openclaw reads the
  # credential back out of OpenClaw's own config (or its compose .env), hermes
  # reads API_SERVER_KEY out of ~/.hermes/.env, and only a custom gateway has
  # nothing on this machine to read and therefore asks. Telling an OpenClaw or
  # Hermes operator they will be asked for a token invites the opposite of the
  # truth: that nothing on this disk can produce one.
  if [ "$auth" = "none" ]; then
    say "     Token:         ${DIM}not stored — this gateway is keyless${RESET}"
  else
    case "$kind" in
      openclaw) say "     Token:         ${DIM}not saved here — a code re-reads it from OpenClaw's own config${RESET}" ;;
      hermes)   say "     Token:         ${DIM}not saved here — a code re-reads it from ~/.hermes/.env${RESET}" ;;
      *)        say "     Token:         ${DIM}not saved here — you re-enter it when a code is printed${RESET}" ;;
    esac
  fi

  unit=$(manage_unit_path "$id")
  state=$(manage_unit_state "$unit")
  folder="$fsfolder"
  [ -n "$folder" ] || folder=$(manage_unit_folder "$unit")
  if [ -n "$fsurl" ]; then
    say "     Shared folder: $(safe_display "${folder:-?}" 200)"
    say "     File address:  $(manage_safe_url "$fsurl" 200)${fsreach:+   ${DIM}($fsreach)${RESET}}"
  elif [ -n "$folder" ]; then
    # A unit exists for this gateway but the saved code carries no file address:
    # the server is running and the app was never told about it.
    say "     Shared folder: $(safe_display "$folder" 200)   ${DIM}(not in the saved setup code)${RESET}"
  else
    say "     Shared folder: ${DIM}none — chat only${RESET}"
  fi
  case "$state" in
    active)   say "     File server:   running   ${DIM}$(safe_display "$(basename "$unit")" 120)${RESET}" ;;
    inactive) say "     File server:   ${YELLOW}not running${RESET}   ${DIM}$(safe_display "$(basename "$unit")" 120)${RESET}" ;;
    unknown)  say "     File server:   ${DIM}installed; this shell cannot ask whether it is running${RESET}" ;;
    absent)   [ -n "$fsurl" ] && say "     File server:   ${YELLOW}no service file for it on this machine${RESET}" ;;
  esac
}

# --------------------------------------------------------------- leftovers --

# A file server whose gateway is gone. This is the single worst thing $STATE_DIR
# can hide: rclone keeps serving the agent's working folder over authenticated
# WebDAV, restarted at every boot or login, for as long as the machine lives —
# and nothing in this tool has ever mentioned it, because the only surface that
# knew the unit existed was the setup run that created it.
#
# Nearly free, because fs_unit_state and fs_all_units already exist. rc 0 always,
# including when it finds nothing: a scan that reports "clean" as a failure would
# make the inventory that calls it nonzero on a healthy machine.
manage_leftovers_scan() {
  local unit id known=" " pf orphan_units=() orphan_ids=() unnamed=()
  while IFS= read -r pf; do
    [ -n "$pf" ] || continue
    known="$known$(manage_profile_id "$pf") "
  done <<EOF
$(manage_saved_profiles)
EOF
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    id=$(manage_unit_id "$unit")
    # An id this command cannot ADDRESS goes in the same bucket as no id at all,
    # and the two really are one case. The entries below differ in exactly one
    # thing — the first prescribes `--forget <id>`, the second prints a by-hand
    # teardown — so an id that --forget will refuse (manage_id_ok is the same
    # gate, and every id this tool has ever written passes it) must not land in
    # the branch that prescribes it. The alternative is an inventory that tells
    # somebody to run a command and a command that answers "that is not a saved
    # setup id", with nothing on either screen explaining the contradiction.
    if [ -z "$id" ] || ! manage_id_ok "$id"; then unnamed+=("$unit"); continue; fi
    case "$known" in *" $id "*) continue ;; esac
    orphan_units+=("$unit"); orphan_ids+=("$id")
  done <<EOF
$(fs_all_units)
EOF
  [ ${#orphan_units[@]} -gt 0 ] || [ ${#unnamed[@]} -gt 0 ] || return 0

  local i state folder
  say ""
  warn "File servers with no saved setup behind them:"
  say "  Each one is a live, authenticated WebDAV server over your agent's working"
  say "  folder, started again at every boot or login, for as long as this machine"
  say "  runs. Nothing removes it on its own."
  for (( i=0; i<${#orphan_units[@]}; i++ )); do
    unit="${orphan_units[$i]}"; id="${orphan_ids[$i]}"
    state=$(manage_unit_state "$unit")
    folder=$(manage_unit_folder "$unit")
    say ""
    # The id and the path are both FILENAME-derived, which is to say chosen by
    # whoever could write to ~/.config/systemd/user or ~/Library/LaunchAgents,
    # and this is a terminal: an escape byte in a unit's name repaints the very
    # inventory that is reporting it, which is the one thing the safe_display
    # rule two hundred lines above exists to prevent. Everything past the loop
    # above is a saved-setup id (safe_display is a no-op on those), so this costs
    # nothing on a healthy machine and is the whole defence on an unhealthy one.
    say "    ${BOLD}$(safe_display "$id" 60)${RESET}   ${DIM}$(safe_display "$unit" 400)${RESET}"
    case "$state" in
      active)   say "      State:  ${YELLOW}running right now${RESET}" ;;
      inactive) say "      State:  not running (it starts again at the next boot or login)" ;;
      *)        say "      State:  this shell cannot ask whether it is running" ;;
    esac
    if [ -n "$folder" ]; then
      say "      Serves: $(safe_display "$folder" 200)"
    else
      note "      Its served folder could not be read from that file."
    fi
    say "      Remove it: ${BOLD}bash conduck-connect.sh --forget $id${RESET}"
  done
  for (( i=0; i<${#unnamed[@]}; i++ )); do
    unit="${unnamed[$i]}"
    state=$(manage_unit_state "$unit")
    folder=$(manage_unit_folder "$unit")
    say ""
    say "    ${BOLD}$(safe_display "$(basename "$unit")" 120)${RESET}   ${DIM}$(safe_display "$unit" 400)${RESET}"
    say "      This one carries no gateway id I can address, so I cannot attribute it to"
    say "      any saved setup and will not remove it for you.${folder:+ It serves $(safe_display "$folder" 200).}"
    case "$state" in
      active) say "      State:  ${YELLOW}running right now${RESET}" ;;
      inactive) say "      State:  not running (it starts again at the next boot or login)" ;;
      *) say "      State:  this shell cannot ask whether it is running" ;;
    esac
    # The teardown block is the one thing on this screen that is NOT for reading:
    # it is meant to be copied into a shell verbatim, so fs_print_teardown quotes
    # the path for the shell rather than sanitising it for the terminal — the two
    # are opposite jobs and only one of them can be done to a string that has to
    # still work when pasted. A path carrying a control byte therefore cannot be
    # both printable and correct, and printing it anyway would hand the terminal
    # the very bytes the display above is filtering out. So that path gets the
    # folder and a sentence instead of a command that would repaint the screen.
    say "      To remove it yourself:"
    case "$unit" in
      *[[:cntrl:]]*)
        say "      Its real filename holds characters a terminal would ACT on rather than"
        say "      print, so no copy-pasteable command for it can be shown here without"
        say "      handing your terminal those same characters. The name above is that"
        say "      filename with those characters taken out; the real one lives in:"
        say "        $(safe_display "$(dirname "$unit")" 400)"
        say "      Stop the service and delete that file by hand — a file manager, or a"
        say "      shell with tab-completion, will fill the name in for you." ;;
      *)
        fs_print_teardown "$unit" ;;
    esac
    note "I did not run any of that — this is a file I cannot prove belongs to a setup of mine."
  done
  return 0
}

# ------------------------------------------------------------ --list --json --

# The agent-facing inventory. python3 is already a hard dependency and it is the
# only correct way to emit this: a hand-rolled JSON writer in shell gets a folder
# name containing a quote or a backslash wrong, and the reader of this output is a
# machine that will not notice until it does something destructive with the value.
#
# Every object carries every key, with null where the value is unknown, so a
# consumer can address a field without first testing whether it exists. Three
# shapes have to stay parseable and each is a real state: an empty $STATE_DIR, a
# corrupt profile (readable:false plus the validator's own reason), and a service
# unit with no profile behind it (the leftovers array).
#
# No secrets: the profile itself holds none, and the two files that do — the .cred
# and, on macOS, the plist — are never opened here.
manage_list_json() {
  local pf id readable problem unit state args=() known=" "
  args+=("$STATE_DIR")
  while IFS= read -r pf; do
    [ -n "$pf" ] || continue
    id=$(manage_profile_id "$pf")
    known="$known$id "
    if show_qr_validate_profile "$pf"; then readable=true; problem=""
    else readable=false; problem="$PROFILE_VALIDATION_ERROR"; fi
    unit=$(manage_unit_path "$id")
    state=$(manage_unit_state "$unit")
    # Six argv slots per setup rather than a delimited line: a served folder or a
    # $STATE_DIR under a path with a tab in it is legal, and argv is the one
    # channel into python that cannot be re-split by accident.
    args+=("setup" "$pf" "$id" "$readable" "$problem" "$unit" "$state")
  done <<EOF
$(manage_saved_profiles)
EOF
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    id=$(manage_unit_id "$unit")
    [ -n "$id" ] || { args+=("leftover" "" "$unit" "$(manage_unit_state "$unit")"); continue; }
    case "$known" in *" $id "*) continue ;; esac
    args+=("leftover" "$id" "$unit" "$(manage_unit_state "$unit")")
  done <<EOF
$(fs_all_units)
EOF
  python3 - "${args[@]}" <<'PY'
import json, sys

# The shell twin of manage_safe_url, applied to every URL that leaves here. These
# rows deliberately include profiles the validator REJECTS, and a rejected profile
# is exactly where a hand-edited `https://user:pass@host` survives — this output is
# read by agents and lands in logs, so a credential may not travel in it. Same
# authority parse as the shell: it ends at the first /, ? or #, and the userinfo
# ends at the LAST @ in it — a password may contain @, a host may not, so rsplit is
# what keeps `https://conduck:pa@ss@gw.example` from emitting `ss@gw.example`.
def safe_url(value):
    if not isinstance(value, str) or "://" not in value:
        return value
    scheme, _, rest = value.partition("://")
    cut = len(rest)
    for ch in "/?#":
        pos = rest.find(ch)
        if pos != -1:
            cut = min(cut, pos)
    authority, tail = rest[:cut], rest[cut:]
    if "@" not in authority:
        return value
    return "%s://%s%s" % (scheme, authority.rsplit("@", 1)[1], tail)

state_dir = sys.argv[1]
argv = sys.argv[2:]
setups, leftovers = [], []
i = 0
while i < len(argv):
    tag = argv[i]
    if tag == "setup":
        path, gid, readable, problem, unit, state = argv[i + 1:i + 7]
        i += 7
        row = {
            "id": gid, "profile": path, "readable": readable == "true",
            "problem": problem or None,
            "kind": None, "name": None, "url": None, "transport": None,
            "reach": None, "model": None, "auth": None, "tokenStored": False,
            "fileServer": None,
            "service": {"unit": unit, "state": state},
        }
        try:
            with open(path) as fh:
                doc = json.load(fh)
        except Exception:
            doc = None
        if isinstance(doc, dict):
            gw = doc.get("gateway")
            if isinstance(gw, dict):
                for key in ("kind", "name", "url", "transport", "reach", "model", "auth"):
                    value = gw.get(key)
                    row[key] = value if isinstance(value, str) and value else None
                row["url"] = safe_url(row["url"])
            fs = doc.get("fileServer")
            if isinstance(fs, dict):
                row["fileServer"] = {
                    key: (fs.get(key) if isinstance(fs.get(key), str) and fs.get(key) else None)
                    for key in ("url", "localPort", "reach", "folder")
                }
                row["fileServer"]["url"] = safe_url(row["fileServer"]["url"])
        elif row["readable"]:
            # The shell validator passed and the file will not parse — the two
            # disagree only if something rewrote it between the two reads, and a
            # row that claims to be readable while carrying no fields is worse
            # than one that says so.
            row["readable"] = False
            row["problem"] = row["problem"] or "The profile could not be parsed as JSON."
        setups.append(row)
    elif tag == "leftover":
        gid, unit, state = argv[i + 1:i + 4]
        i += 4
        leftovers.append({"id": gid or None, "unit": unit, "state": state})
    else:
        break

print(json.dumps({
    "schemaVersion": 1,
    "stateDir": state_dir,
    "tokenStored": False,
    "setups": setups,
    "leftovers": leftovers,
}, indent=1))
PY
}

# ----------------------------------------------------------------- picker --

# The shared picker. pick_existing_custom_gateway is the pattern, but it globs
# profile-custom-* because its caller is deciding whether to edit or mint a CUSTOM
# gateway id. This one lists every saved setup including openclaw and hermes: they
# have exactly the same profile, the same file-lane unit and the same credential,
# and no inventory surface in this tool has ever shown them.
#
# 0 = an id is in the named variable · 1 = nothing to pick (said so on screen) ·
# 10 = the operator pressed b. Never returns for q: prompt_into raises that in the
# parent, which is the whole reason the choice goes through it.
manage_pick_profile() { # manage_pick_profile <variable-name>
  local __mp_var="$1" __mp_pf __mp_pick __mp_i=1
  local __mp_ids=() __mp_hidden=0
  while IFS= read -r __mp_pf; do
    [ -n "$__mp_pf" ] || continue
    if show_qr_validate_profile "$__mp_pf"; then
      __mp_ids+=("$(manage_profile_id "$__mp_pf")")
    else
      __mp_hidden=$((__mp_hidden+1))
    fi
  done <<EOF
$(manage_saved_profiles)
EOF
  if [ ${#__mp_ids[@]} -eq 0 ]; then
    say ""
    if [ "$__mp_hidden" = "0" ]; then
      note "No saved setups on this machine yet."
      say "  Pair one first:  ${BOLD}bash conduck-connect.sh --setup${RESET}"
    else
      note "This machine has $__mp_hidden saved setup(s) this version ($VERSION) cannot read, so"
      note "there is nothing to pick. Run --list to see what each one says is wrong."
    fi
    return 1
  fi
  # One saved setup is still SHOWN rather than silently assumed. There is nothing
  # to decide, but there is something to recognise: the next screen offers to
  # remove it, and "the only one" is not a good enough answer to "which one?".
  if [ ${#__mp_ids[@]} -eq 1 ]; then
    say ""
    say "  ${BOLD}The one saved setup on this machine:${RESET}"
    manage_print_one "${__mp_ids[0]}"
    printf -v "$__mp_var" '%s' "${__mp_ids[0]}"
    MANAGE_ID="${__mp_ids[0]}"
    return 0
  fi
  say ""
  say "  ${BOLD}Saved setups on this machine:${RESET}"
  for (( __mp_i=0; __mp_i<${#__mp_ids[@]}; __mp_i++ )); do
    say ""
    manage_print_one "${__mp_ids[$__mp_i]}" "$((__mp_i+1))"
  done
  [ "$__mp_hidden" = "0" ] || { say ""; note "($__mp_hidden more can't be read by this version and aren't listed; --list says why.)"; }
  say ""
  while true; do
    # {1,3} length-bounds the answer so the numeric compare cannot overflow bash
    # 3.2's intmax; allow-back is on because every caller of this picker has a
    # screen behind it worth returning to.
    prompt_into __mp_pick require_choice "Which one? Choose 1-${#__mp_ids[@]}" '^[0-9]{1,3}$' explain_manage_pick true \
      || return 10
    { [ "$__mp_pick" -ge 1 ] && [ "$__mp_pick" -le ${#__mp_ids[@]} ]; } 2>/dev/null && break
    warn "Please enter a number between 1 and ${#__mp_ids[@]}."
  done
  printf -v "$__mp_var" '%s' "${__mp_ids[$((__mp_pick-1))]}"
  MANAGE_ID="${__mp_ids[$((__mp_pick-1))]}"
  return 0
}

# ------------------------------------------------------------------- edit --

# Everything write_profile reads, loaded from one saved profile. Assigns into the
# CALLER's locals (bash 3.2 has no `declare -n`, and every name here is already a
# global the rest of the script owns) — so the caller declares them `local` and
# this run's edits cannot leak into a setup run sharing the process.
#
# FS_CRED is the one that matters and the one a reader will not expect. It is the
# WebDAV password, it is NOT in the profile, and write_profile records a fileServer
# block only when FS_URL and FS_CRED are both set — so loading a profile without
# it and saving a changed address would silently drop file transfer from the saved
# setup, and the operator would find out on a phone, days later. Returns 1 when a
# lane is recorded but its password cannot be recovered, because saving is then a
# destructive act dressed as an address change.
manage_load_profile() { # manage_load_profile <id> -> 1 when a recorded file lane cannot be preserved
  local id="$1" pf; pf=$(manage_profile_path "$id")
  GW_ID="$id"
  GW_KIND=$(json_get "$pf" "gateway.kind")
  GW_NAME=$(json_get "$pf" "gateway.name")
  GW_AUTH=$(json_get "$pf" "gateway.auth")
  TRANSPORT=$(json_get "$pf" "gateway.transport")
  SCOPE=$(json_get "$pf" "gateway.reach")
  GW_URL=$(json_get "$pf" "gateway.url")
  GW_LOCAL_PORT=$(json_get "$pf" "gateway.localPort")
  GW_MODEL=$(json_get "$pf" "gateway.model")
  FS_URL=$(json_get "$pf" "fileServer.url")
  FS_LOCAL_PORT=$(json_get "$pf" "fileServer.localPort")
  FS_REACH=$(json_get "$pf" "fileServer.reach")
  FS_FOLDER=$(json_get "$pf" "fileServer.folder")
  FS_CRED=""
  [ -n "$FS_URL" ] || return 0
  # The same three sources, in the same order, that existing_fs_config uses: the
  # 0600 state credential file, then the environment file, then the service unit
  # itself — parsed structurally by fs_unit_field, never text-matched.
  #
  # The unit is included, and the reason is what FS_CRED is FOR here. Nothing on
  # this screen writes it anywhere: write_profile reads it as a BOOLEAN and
  # nothing else — `if e("FS_URL") and e("FS_CRED")` decides whether the record
  # keeps its fileServer block, and the credential itself is never a field of the
  # profile. (Option 4's code emission does need the real value, and gets its own
  # copy from show_qr_recover_file_lane; the value loaded here never reaches a
  # payload.) So a password recovered from a service file is not "written into a
  # record on a guess" — it is evidence that the lane exists, and the unit is the
  # most direct evidence there is.
  #
  # Refusing it is the expensive answer, because the lane whose password lives
  # ONLY in its unit is not an exotic case: it is every lane whose .cred was
  # cleaned up, and on macOS the plist is a first-class home for that password
  # (manage_forget's disclosure says so out loud). Without the third source those
  # setups get an edit screen on which EVERY option refuses to save, including
  # the address repair that is the whole reason this screen exists — so the
  # operator most likely to need it is the one who cannot use it.
  #
  # Id-addressed only, never the legacy unnamed units existing_fs_config also
  # falls back to: a unit carrying no id belongs to no setup this function was
  # asked about (see manage_unit_path), and borrowing its password would decide
  # a neighbour's file lane survives on the strength of a file nothing ties to it.
  local credf envf unit cand
  credf=$(manage_cred_path "$id"); envf=$(manage_env_path "$id")
  unit=$(manage_unit_path "$id")
  if [ -f "$credf" ]; then FS_CRED=$(cat "$credf" 2>/dev/null || true)
  elif [ -f "$envf" ]; then FS_CRED=$(env_get "$envf" "RCLONE_PASS")
  elif [ -f "$unit" ]; then
    for cand in argv_cred env_cred; do
      FS_CRED=$(fs_unit_field "$unit" "$cand" 2>/dev/null || true)
      # credential_value_safe is the same gate existing_fs_config applies before
      # it trusts a recovered value: a credential carrying a control byte cannot
      # ride curl's stdin config or a systemd EnvironmentFile, so a value that
      # fails it is not one this record may claim a working lane on.
      credential_value_safe "$FS_CRED" && break
      FS_CRED=""
    done
  fi
  [ -n "$FS_CRED" ] || return 1
  return 0
}

# Save the caller's GW_*/FS_* back to disk through write_profile — never by
# editing the JSON in place. write_profile is the single encoder for this file: it
# builds the document with a real JSON encoder, writes 0600 under umask 077, and
# renames it into place atomically so an interrupt cannot leave half a profile that
# the picker would offer and --show-code would then reject.
#
# Its three "don't overwrite" guards are all about a run that has NOT proven what
# it is recording, and none of them describes this one — so they are neutralised
# LOCALLY, which is also what stops them leaking into a setup run in the same
# process. $DRY_RUN and $REUSE_ONLY are deliberately left alone: those two mean
# "change nothing", and this is a change.
#
# The id is an ARGUMENT, and it is re-asserted as a local $GW_ID, because $GW_ID is
# the only thing that decides WHICH FILE write_profile writes. The operator picked
# a setup by name on the screen behind this; nothing between that choice and this
# write may redirect it at a neighbour's file, and re-asserting it here costs one
# line and does not depend on every function in between keeping its hands to itself.
manage_save_profile() { # manage_save_profile <id>
  local SHOW_QR=false VERIFY_FAILED=false FS_LANE_DROPPED_BY_CHECK=false
  local GW_ID="$1"
  write_profile
}

# Save, then PROVE the save landed by reading the field back off the disk.
#
# write_profile WARNS and returns 0 on every failure it can hit — a $STATE_DIR it
# cannot create, a python that would not build the document, a temp file it could
# not write or rename. That is right for the wizard, where a pairing is complete
# whether or not the convenience record got saved. It is wrong here, where the save
# IS the action: an edit screen that prints "Saved." over a warning tells the
# operator the address was recorded when the file still holds the old one, and they
# find out days later on a phone. The removal half of this module already refuses
# to report anything it has not re-read (see manage_forget_apply); this is the same
# standard applied to the half that writes.
#
# 0 = the disk agrees · 1 = it does not, and the operator has been told so.
manage_save_and_prove() { # manage_save_and_prove <id> <json-path> <expected-value>
  manage_save_profile "$1"
  local pf; pf=$(manage_profile_path "$1")
  [ "$(json_get "$pf" "$2")" = "$3" ] && return 0
  say ""
  warn "NOT saved. The write did not land, and $pf was not changed."
  warn "A folder or file this account may not write, a full disk, or a file something else"
  warn "is holding are the usual reasons; a line just above may name the real one."
  note "Nothing else on this machine was changed, and nothing here retries on its own."
  return 1
}

# Does the saved address still answer? The check code already exists — the one
# --check-server's first probe uses — so this asks the same question rather than
# inventing a second opinion about what "reachable" means.
#
# Deliberately UNAUTHENTICATED: the profile stores no token, and asking for one
# here would put a hidden secret prompt inside an edit screen whose entire promise
# is that it does not make you re-enter things. That costs nothing real, because
# the four outcomes below are all the operator needs to know whether an address
# change worked — a 401 from the right host is the correct, expected answer from a
# bearer gateway and proves the route as well as a 200 would.
#
# 0 = answered as a gateway · 1 = answered and asked for a token · 2 = answered,
# but not like an OpenAI-compatible gateway · 3 = did not answer at all.
manage_probe_address() { # manage_probe_address <https-url>
  local GW_AUTH="none" GW_TOKEN="" rc=0
  models_is_json "$1" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 0 ;;
    2|3) return 2 ;;                       # HTML, or JSON in the wrong envelope
  esac
  [ "${MODELS_CURL_RC:-0}" = "0" ] || return 3
  case "${MODELS_HTTP_CODE:-}" in
    401|403) return 1 ;;
    '')      return 3 ;;
    *)       return 2 ;;
  esac
}

# Say what the probe found, in one place, so the address prompt and any later
# caller cannot describe the same four outcomes differently.
manage_report_probe() { # manage_report_probe <rc> <url>
  case "$1" in
    0) ok "That address answers, and it answers like a gateway the app can use." ;;
    1) ok "That address answers and asks for a token — which is exactly right for this"
       note "gateway; the token is not saved here, so I cannot go further than that." ;;
    2) warn "That address answers, but not the way an OpenAI-compatible gateway does"
       warn "(HTTP ${MODELS_HTTP_CODE:-?}). Something is listening there — a login page, a"
       warn "different service, or the tunnel's own error page." ;;
    *) warn "Nothing answered at that address. If the tunnel or the gateway behind it is"
       warn "not running yet, that is expected — start it and check again with:"
       say  "    ${BOLD}bash conduck-connect.sh --check-server $2${RESET}" ;;
  esac
}

# The per-setup screen: change ONE field, and re-run only the verification that
# field affects. The pattern is choose_saved_model's — a bounded choice, one
# prompt, one write — repeated for the fields an operator actually comes back for.
#
# The motivating case is this tool's most common real failure and it is worth
# naming: `cloudflared tunnel --url` mints a NEW *.trycloudflare.com hostname every
# time it restarts, so a setup that verified green last night points at a hostname
# that no longer resolves this morning. Re-pointing it is a one-field change, and
# without this screen it costs a full walk through the wizard.
manage_edit() { # manage_edit [<id>]
  # FIRST, before anything is read or printed. Every line of this screen is a
  # question, so there is nothing here for a run with nobody to answer it — and
  # asked any later, the no-id path has already validated every profile on the
  # machine, drawn the whole inventory, and READ an answer off the pipe before
  # refusing. That last part is the one that matters: `printf '1\n' | --edit`
  # consumes the 1, so a driver's transcript shows the picker taking its choice
  # and then exit 4, which reads as a tool that changed its mind rather than one
  # that was never able to run. nobody_can_answer at the dispatcher catches the
  # closed-stdin case; a PIPE gets past it and lands here, which is why this
  # gate exists at all and why it belongs on the first line.
  interactive_terminal || manage_refuse_without_a_terminal "Changing a saved setup"
  local id="${1:-}"
  if [ -z "$id" ]; then
    manage_pick_profile id || return 0     # 1 = nothing saved (said so), 10 = back
  fi
  manage_id_ok "$id" || { warn "\"$(safe_display "${id}" 60)\" is not a saved setup id. Run --list to see them."; return 1; }
  local pf; pf=$(manage_profile_path "$id")
  if ! show_qr_validate_profile "$pf"; then
    say ""
    warn "$PROFILE_VALIDATION_ERROR"
    note "Nothing here can edit a profile it cannot read. --forget $id removes it."
    return 1
  fi

  # Declared HERE, in the scope the whole screen runs in, so every edit and every
  # save works on this one setup's values and the process's own GW_*/FS_* globals —
  # which may belong to a setup run that dispatched us — are untouched on return.
  local GW_ID GW_KIND GW_NAME GW_AUTH TRANSPORT SCOPE GW_URL GW_LOCAL_PORT GW_MODEL
  local FS_URL FS_CRED FS_LOCAL_PORT FS_REACH FS_FOLDER
  local lane_preserved=true
  manage_load_profile "$id" || lane_preserved=false

  local choice
  while true; do
    say ""
    manage_print_one "$id"
    if ! $lane_preserved; then
      say ""
      warn "This setup records a file lane, and its stored password is not in $STATE_DIR."
      warn "Saving any change would rewrite the record WITHOUT file transfer, so nothing on"
      warn "this screen will save until that is resolved. Re-run setup for this gateway to"
      warn "rebuild the lane, or use --forget $id to remove the setup entirely."
    fi
    # The quick-tunnel case gets its own banner because from the app's side it is
    # indistinguishable from a broken gateway, and it is the reason most people
    # open this screen at all.
    if is_quick_tunnel_url "${GW_URL:-}"; then
      say ""
      warn "This setup rides a Cloudflare QUICK TUNNEL. That hostname is reassigned every"
      warn "time the tunnel restarts — a reboot, a crash, a Ctrl-C in its terminal — and"
      warn "nothing on this machine learns the new one. If the app stopped connecting,"
      warn "option 1 is what you came for: paste the address cloudflared prints now."
    fi
    say ""
    say "  ${BOLD}Change one thing${RESET}"
    say "    1) Web address — the https:// address the app calls"
    say "    2) Model"
    say "    3) Shared folder for file transfer"
    say "    4) Show this setup's code again (to pair a device, or after a change)"
    say "    5) Remove this setup from this machine"
    prompt_into choice require_choice "Choose 1-5" '^[1-5]$' explain_manage_edit true || return 0
    case "$choice" in
      1) manage_edit_address "$id" "$lane_preserved" ;;
      2) manage_edit_model "$id" "$lane_preserved" ;;
      3) manage_edit_folder "$id" ;;
      4) manage_show_code "$id" ;;
      5) if manage_forget "$id"; then return 0; fi ;;
    esac
  done
}

# The address change. Re-verifies the ADDRESS and nothing else — the model, the
# transport, the file lane and the token are untouched, so re-running their checks
# would spend the operator's time and possibly their provider's quota on questions
# this edit did not raise.
manage_edit_address() { # manage_edit_address <id> <lane-preserved>
  local id="$1" lane_ok="$2" old="$GW_URL" new rc transport_mismatch=false
  say ""
  say "  ${BOLD}The web address${RESET}"
  say "  Currently: $(safe_display "${old:-?}" 200)"
  note "This is the address the Conduck app calls. Changing it here does not move any"
  note "tunnel or route — it records where the address now is."
  prompt_into new ask_url "  The https:// address that reaches this gateway now" \
    "https://ai.example.com" 0 "" explain_manage_address true || return 0
  if [ "$new" = "$old" ]; then
    note "Same address as before — nothing to save."
    return 0
  fi

  # The one inconsistency this screen can detect on its own. A saved Tailscale
  # setup asserts its live mapping at --show-code time, so an address that is not
  # a tailnet name will be refused there rather than here, and being told that now
  # is much cheaper than being told after the code is printed.
  case "$TRANSPORT" in
    tailscale|funnel)
      case "$(url_host_lc "$new")" in
        *.ts.net) ;;
        *) transport_mismatch=true
           say ""
           warn "This setup is recorded as reached over Tailscale, and that address is not a"
           warn "tailnet name. --show-code asserts the live Tailscale mapping before it prints"
           warn "a code, so it will refuse this. If the gateway has genuinely moved to another"
           warn "route, re-run setup so the transport is recorded with the address." ;;
      esac ;;
  esac

  say ""
  note "Checking whether that address answers (one request; nothing is changed)."
  manage_probe_address "$new"; rc=$?
  manage_report_probe "$rc" "$new"
  # The confirmation gate covers BOTH doubts, and the transport one is the graver
  # of the two. "Nothing answered" is often just a tunnel that is not up yet, and
  # the operator is right to save ahead of it. A tailnet transport with a
  # non-tailnet address is the opposite: it is a mismatch this screen has already
  # PROVEN, and the certain consequence is that the one command which could carry
  # the change to the phone refuses to run. Saving it unasked because the address
  # happened to answer would be the tool acting on the weaker of the two facts it
  # just printed.
  if $transport_mismatch || [ "$rc" = "3" ] || [ "$rc" = "2" ]; then
    say ""
    if $transport_mismatch; then
      warn "Saving this leaves a record no setup code can be printed from, so the paired"
      warn "device keeps the old address with no way to be told the new one."
    fi
    if ! confirm "  Save it anyway?" explain_manage_address; then
      note "Left the saved address as it was."
      return 0
    fi
  fi

  $lane_ok || { say ""; warn "Not saved — see the file-lane warning above."; return 0; }
  mutate_guard "record a new web address for the saved setup $id"
  GW_URL="$new"
  # Not saved until the disk says so — and on a failed write the in-memory value is
  # put back, because everything after this point (the file-lane follow-up, the
  # offer of a code) is built from it and would otherwise carry an address this
  # machine has no record of.
  if ! manage_save_and_prove "$id" "gateway.url" "$new"; then
    GW_URL="$old"
    return 0
  fi
  ok "Saved. $(manage_profile_path "$id") now points at $(safe_display "$new" 200)."

  manage_follow_file_address "$id" "$old" "$new"

  # No code offer for an address this screen has already proven --show-code will
  # refuse. The offer below runs the real pipeline, and its first step on a
  # Tailscale transport asserts the live mapping and DIES when the host is not a
  # tailnet name — so accepting it would answer a friendly question with a fatal
  # error, one screen after the operator was told this exact thing would happen.
  if $transport_mismatch; then
    say ""
    warn "No setup code can be printed from this record while the transport says Tailscale"
    warn "and the address does not. Re-run setup for this gateway — it records the"
    warn "transport and the address together, which is what makes a code printable again."
    return 0
  fi

  # The phone still holds the OLD address, and nothing pushes a change to it. This
  # offer is the whole reason the address edit is worth having: without it the
  # operator saves a correct record and the app stays broken.
  say ""
  say "  The device you already paired still has the old address — a setup code is a"
  say "  snapshot, not a subscription. Scanning a new one updates it."
  if confirm "  Show the new setup code now?" explain_manage_show_code; then
    manage_show_code "$id"
  else
    note "Whenever you want it:  bash conduck-connect.sh --show-code"
  fi
}

# The same URL with a different host, keeping the port and everything after the
# authority. That combination is what a moved address actually looks like on the
# one transport where the file lane shares the gateway's hostname: Tailscale puts
# the file server on the SAME tailnet name and a different HTTPS port, so the port
# is the part that must survive the substitution.
manage_url_with_host() { # manage_url_with_host <https-url> <new-host>
  local rest auth tail port=""
  rest="${1#https://}"
  auth="${rest%%[/?#]*}"
  tail="${rest#"$auth"}"
  case "$auth" in
    \[*\]:*) port=":${auth##*\]:}" ;;
    \[*\])   port="" ;;
    *:*)     port=":${auth##*:}" ;;
  esac
  printf 'https://%s%s%s' "$2" "$port" "$tail"
}

# A moved gateway address usually moves the FILE address with it, and saving one
# without the other is the quiet half-repair this screen exists to prevent: the
# next setup code would carry a working gateway and a file address that answers
# nothing, and the operator would find out when an attachment fails on a phone.
#
# The rule is the hostname. When the file lane sits on the same host as the
# gateway — always true on Tailscale, and true of a quick tunnel that fronts both —
# the new host is the answer and the whole address is shown before anything is
# written. When the hosts differ, the file lane is on a route of its own that this
# edit has no opinion about, so it is named and left alone. Nothing is derived
# silently in either branch.
manage_follow_file_address() { # manage_follow_file_address <id> <old-gateway-url> <new-gateway-url>
  local id="$1" old_host new_host fs_host candidate previous
  [ -n "${FS_URL:-}" ] || return 0
  old_host=$(url_host_lc "$2"); new_host=$(url_host_lc "$3")
  fs_host=$(url_host_lc "$FS_URL")
  say ""
  if [ -z "$fs_host" ] || [ "$fs_host" != "$old_host" ]; then
    note "The file address in this setup is on a different host and is untouched:"
    note "$(manage_safe_url "$FS_URL" 200)"
    note "If that route moved too, re-run setup — it rebuilds the file lane's address."
    return 0
  fi
  candidate=$(manage_url_with_host "$FS_URL" "$new_host")
  warn "The file address in this setup rides the same hostname you just changed, so it"
  warn "now points somewhere that no longer answers:"
  note "$(manage_safe_url "$FS_URL" 200)"
  say "  Moving it to the new hostname, keeping its port and path, gives:"
  say "    ${BOLD}$(safe_display "$candidate" 200)${RESET}"
  if ! confirm "  Update the file address too?" explain_manage_address; then
    warn "Left as it was. Until it is fixed, a setup code from this setup carries a file"
    warn "address that answers nothing — chat still works."
    return 0
  fi
  previous="$FS_URL"
  FS_URL="$candidate"
  if ! manage_save_and_prove "$id" "fileServer.url" "$candidate"; then
    FS_URL="$previous"
    warn "The gateway address above did save; this file address did not. Until it is"
    warn "fixed, a setup code from this setup carries a file address that answers"
    warn "nothing — chat still works."
    return 0
  fi
  ok "Saved. The file address is now $(safe_display "$candidate" 200)."
  note "Nothing was restarted or re-routed — this records where the address is."
}

# The model. choose_saved_model is exactly this edit already — a bounded three-way
# choice over one field — so it is called rather than re-written; the only thing
# added here is the save, which the wizard does at the end of its own run.
#
# It is called under the SAME guard its other caller uses (20-gateway.inc.sh, the
# custom-gateway branch: `if $GW_EDITING && [ -n "$GW_MODEL" ]`), because it is
# written for a gateway that HAS a pinned model and reads as nonsense without one.
# Its first line is "This gateway last used the model: " with the value on the
# end, and its menu offers "1) Keep it" and "3) Clear it — let the server pick";
# on a setup that pins nothing that is a sentence ending in a colon followed by
# two options that do the identical nothing. $GW_EDITING is not tested here — a
# saved setup is by definition one being edited — so the guard is the model.
#
# The un-pinned branch asks the plain question instead. It does NOT copy the
# wizard's probe_single_model shortcut: that probe reads http://127.0.0.1:<port>
# and it needs a token this screen deliberately never loads, so against the bearer
# gateway that is the common case it would send a request nobody was told about
# and come back with nothing to show for it.
manage_edit_model() { # manage_edit_model <id> <lane-preserved>
  local id="$1" lane_ok="$2" old="$GW_MODEL"
  if [ -n "$GW_MODEL" ]; then
    choose_saved_model
  else
    say ""
    say "  ${BOLD}The model${RESET}"
    say "  This setup pins none, so the app asks for whichever model your server picks."
    say "  Some servers (Ollama, vLLM, LiteLLM without a default) need one named in"
    say "  every request instead."
    prompt_into GW_MODEL ask "  Model name" "" "keep letting the server pick" \
      "gateway.custom.model" true || return 0
  fi
  if [ "$GW_MODEL" = "$old" ]; then
    note "Model unchanged — nothing to save."
    return 0
  fi
  $lane_ok || { say ""; warn "Not saved — see the file-lane warning above."; GW_MODEL="$old"; return 0; }
  mutate_guard "record a new model for the saved setup $id"
  # Same proof as the address edit, and the same restore on failure: the screen
  # behind this reprints the setup from these locals, so a model the disk never
  # accepted would be shown as this setup's model for the rest of the session.
  if ! manage_save_and_prove "$id" "gateway.model" "$GW_MODEL"; then
    GW_MODEL="$old"
    return 0
  fi
  if [ -n "$GW_MODEL" ]; then
    ok "Saved. This setup now pins the model $(safe_display "$GW_MODEL" 200)."
  else
    ok "Saved. This setup pins no model — the server picks."
  fi
  say ""
  note "The paired device keeps the old model until it scans a new code:  bash conduck-connect.sh --show-code"
}

# The shared folder. Deliberately NOT edited in place — see the handoff note; the
# short version is on screen because the operator deserves the real reason rather
# than a missing menu item.
manage_edit_folder() { # manage_edit_folder <id>
  local id="$1" unit state folder
  unit=$(manage_unit_path "$id"); state=$(manage_unit_state "$unit")
  folder="$FS_FOLDER"; [ -n "$folder" ] || folder=$(manage_unit_folder "$unit")
  say ""
  say "  ${BOLD}The shared folder${RESET}"
  if [ -n "$folder" ]; then
    say "  Currently: $(safe_display "$folder" 200)"
  else
    say "  This setup has no file transfer — chat only."
  fi
  say ""
  say "  Moving it is not one field. The folder is named in three places that have to"
  say "  agree, or attachments land somewhere the agent never looks:"
  say "    • the file server's own service definition ($(basename "$unit"))"
  say "    • this saved setup, which is what a setup code is built from"
  say "    • your agent's own configuration, which decides where IT reads and writes"
  say ""
  say "  Setup does all three and asks before each one, and it reuses what is already"
  say "  here — the same service, the same port, the same password:"
  say "    ${BOLD}bash conduck-connect.sh --setup${RESET}"
  case "$state" in
    active)   note "The file server for this setup is running now; setup will reuse it." ;;
    inactive) note "The file server for this setup is installed but not running." ;;
    absent)   [ -n "$folder" ] && note "No service file for this setup's file server is present on this machine." ;;
  esac
  return 0
}

# Re-emit this setup's code, for THIS id, with no "which one?" question — the
# operator has already answered that by being on this screen.
#
# It is run_show_qr's pipeline minus its picker and its own opening block. $SHOW_QR
# is set as a LOCAL, which is what makes the whole sequence honest: it is the flag
# write_profile reads to refuse rewriting saved state, and the flag
# run_changes_nothing reads so that a q here says "nothing was changed" instead of
# the wizard's warning about approved edits. As a local it reverts on return, so
# the edit screen behind this can still save.
#
# Every OTHER global this pipeline writes is declared local too, at the value a
# fresh `--show-code` process would start it with — so this runs on its own copy of
# the wizard's state and hands nothing back. That is a correctness requirement, not
# tidiness, because the caller is the edit screen and its GW_*/FS_* locals ARE the
# record about to be saved:
#
#   • show_qr_recover_file_lane clears FS_URL/FS_CRED/FS_FOLDER when it cannot
#     recover the lane's password and the operator accepts a gateway-only code —
#     a correct answer for ONE emission. Landing in the edit screen's frame, it
#     turns the next address change into a permanent deletion of file transfer
#     from the saved setup, reported on screen as a green "Saved."
#   • show_qr_load_profile takes GW_ID from the in-file gateway.id, which nothing
#     requires to equal the id in the filename (see manage_profile_id). Landing in
#     the edit screen's frame, the next save writes profile-<gateway.id>.json —
#     ANOTHER setup's file — while the ok line names the path the operator chose.
#
# Locals rather than a save/restore pair because a restore has to be reached: this
# pipeline dies on a stale mapping, an unrecoverable token or a failed verification,
# and bash unwinds locals on every one of those paths for free.
manage_show_code() { # manage_show_code <id>
  local SHOW_QR=true PROFILE_FILE
  local GW_KIND="" GW_ID="" GW_NAME="" GW_LOCAL_PORT="" GW_HEALTH_PATH=""
  local GW_AUTH="bearer" GW_TOKEN="" GW_MODEL="" GW_URL=""
  local TRANSPORT="" SCOPE="unknown"
  local FS_URL="" FS_CRED="" FS_LOCAL_PORT="" FS_REACH="" FS_UNIT="" FS_FOLDER=""
  local FS_CRED_LEGACY_ARGV=false FS_EXISTING_UNSAFE=false
  local VERIFY_FAILED=false FS_LANE_DROPPED_BY_CHECK=false FS_AGENT_PROOF=""
  PROFILE_FILE=$(manage_profile_path "$1")
  preflight
  say ""
  head_ "The setup code for $1"
  note "(changes no configuration; live gateway checks run, and a configured file lane gets one small PUT → GET → DELETE probe)"
  show_qr_warn_quick_tunnel "$PROFILE_FILE"
  ensure_state_dir
  show_qr_load_profile
  show_qr_recover_gateway_secret
  show_qr_recover_file_lane
  show_qr_check_live
  show_qr_recall_scope
  verify_all
  emit_payload
  show_qr_next_steps
}

# ----------------------------------------------------------------- forget --

# Remove ONE saved setup and everything this script created for it.
#
# rc 0 = removed · 1 = refused or nothing to remove · 3 = the operator backed out.
#
# The order of operations is the safety property. The full disclosure — what goes,
# what stays, and the exact commands — is printed BEFORE the confirmation, so the
# typed answer is consent to a list the operator has read rather than to a word.
# Then the service is stopped before its file is deleted, because on macOS that
# file is the second home of the WebDAV password and an unloaded-but-present plist
# is a secret still on disk while launchd holds the old one in memory.
manage_forget() { # manage_forget <id>
  local id="${1:-}"
  manage_id_ok "$id" || {
    warn "\"$(safe_display "${id:-}" 60)\" is not a saved setup id."
    note "Ids are lowercase letters, digits and hyphens — run --list to see the real ones."
    return 1
  }
  local pf credf envf unit state folder
  pf=$(manage_profile_path "$id")
  credf=$(manage_cred_path "$id")
  envf=$(manage_env_path "$id")
  unit=$(manage_unit_path "$id")
  state=$(manage_unit_state "$unit")
  folder=$(manage_unit_folder "$unit")
  [ -n "$folder" ] || folder=$(json_get "$pf" "fileServer.folder")

  if [ ! -f "$pf" ] && [ ! -f "$unit" ] && [ ! -f "$credf" ] && [ ! -f "$envf" ]; then
    say ""
    note "Nothing on this machine is filed under \"$id\" — no saved setup, no file server,"
    note "no stored password. Run --list to see what is here."
    return 1
  fi
  interactive_terminal || manage_refuse_without_a_terminal "Removing a saved setup"

  say ""
  # An id can reach here with no profile behind it — that is exactly the leftovers
  # case, a file server whose gateway is already gone — and heading that screen
  # "Remove the saved setup" would name something the operator can see is not there.
  if [ -f "$pf" ]; then
    head_ "Remove the saved setup \"$id\""
    say ""; manage_print_one "$id"
  else
    head_ "Remove the leftover file server \"$id\""
    note "There is no saved setup under that id — only what its file server left behind."
  fi

  # The exposure records this setup owns. Field 6 of the v2 record is the gateway
  # id, and it exists for exactly this: without it a record says a gateway was
  # exposed on some HTTPS port but never which gateway, so two setups on one host
  # leave mappings nobody can tell apart. Records belonging to another id, and
  # records whose id is the literal `unknown`, are read and then left completely
  # alone — an exposure that cannot be attributed is not one this command may
  # close on a guess.
  #
  # A record this version cannot READ at all is collected separately and reported.
  # read_exposure_record refuses anything whose format-version is not the current
  # one, and the id field this teardown depends on arrived with the CURRENT version
  # — so every record an older conduck-connect wrote is unreadable here, and every
  # machine set up by one carries them. Skipping them silently is the worst outcome
  # this file can produce: the profile, the unit and the credential go, the address
  # in front of the port stays open — a Funnel is PUBLIC — and nothing left on disk
  # names it. They cannot be torn down either, because a record without a gateway id
  # cannot be shown to belong to this setup, and closing a stranger's public route
  # on a guess is the mistake in the other direction. So they are named, with their
  # paths, and left exactly as they are.
  local live=() files=() backends=() roles=() unattributed=0 unreadable=()
  local pending_seen=false ts_reason="" f
  if [ -n "${STATE_DIR:-}" ]; then
    for f in "$STATE_DIR"/exposure-*.pending; do
      [ -f "$f" ] && { pending_seen=true; break; }
    done
  fi
  # Only asked when there is something to ask about. A gateway behind Cloudflare or
  # a reverse proxy of the operator's own has no record here at all, and telling
  # them Tailscale could not be read would send them to check a program that has
  # nothing to do with their setup.
  if $pending_seen; then
    if ! have tailscale; then
      ts_reason="the 'tailscale' command is not on this shell's PATH"
    else
      ts_targets
      if ! $TS_STATE_KNOWN; then
        ts_reason="'tailscale serve status --json' could not be read"
      else
        for f in "$STATE_DIR"/exposure-*.pending; do
          [ -f "$f" ] || continue
          read_exposure_record "$f" || { unreadable+=("$f"); continue; }
          if [ "$REC_GWID" = "unknown" ]; then unattributed=$((unattributed+1)); continue; fi
          [ "$REC_GWID" = "$id" ] || continue
          exposure_record_is_live || continue
          live+=("$REC_PORT"$'\t'"$REC_AVERB"$'\t'"$REC_PRIOR")
          files+=("$f")
          backends+=("${REC_APROXY#http://127.0.0.1:}")
          [ "$REC_ROLE" = "file" ] && roles+=("your shared folder") || roles+=("your gateway")
        done
      fi
    fi
  fi

  say ""
  say "  ${BOLD}This removes, on this machine:${RESET}"
  [ -f "$pf" ]    && say "    the saved setup        $pf"
  if [ -f "$unit" ]; then
    say "    the file server        $unit"
    case "$state" in
      active)   say "                           ${YELLOW}(running now — it is stopped first)${RESET}" ;;
      inactive) say "                           (not running)" ;;
      *)        say "                           (this shell cannot ask whether it is running)" ;;
    esac
  fi
  [ -f "$credf" ] && say "    its stored password    $credf"
  [ -f "$envf" ]  && say "    its environment file   $envf"
  # The single most important line on this screen. On macOS the LaunchAgent plist
  # carries EnvironmentVariables.RCLONE_PASS — the same WebDAV password as the
  # .cred file, in cleartext — so an operator who deletes the .cred by hand and
  # stops there has left the secret exactly where it was.
  if [ "$OS" != "Linux" ] && [ -f "$unit" ]; then
    say ""
    warn "That service file holds a SECOND cleartext copy of the file-server password."
    warn "Removing the .cred alone would leave it on disk; both go together here."
  fi
  local i entry port rest averb
  for (( i=0; i<${#live[@]}; i++ )); do
    entry="${live[$i]}"
    port="${entry%%$'\t'*}"; rest="${entry#*$'\t'}"; averb="${rest%%$'\t'*}"
    if [ "$averb" = "funnel" ]; then
      say "    a ${BOLD}PUBLIC${RESET} address      port $port → 127.0.0.1:${backends[$i]} (${roles[$i]}), Tailscale Funnel"
    else
      say "    a private address      port $port → 127.0.0.1:${backends[$i]} (${roles[$i]}), Tailscale Serve"
    fi
  done

  say ""
  say "  ${BOLD}This does NOT touch:${RESET}"
  if [ -n "$folder" ]; then
    say "    the shared folder $(safe_display "$folder" 200) or anything in it."
    say "      On OpenClaw and Hermes that folder is the agent's own working directory."
  else
    say "    any folder on this machine, or anything in one."
  fi
  say "    your agent's TOOLS.md, or any gateway configuration this script edited."
  say "    the gateway itself — it keeps running, on the same port, with the same token."
  say "    the pairing already on your phone, tablet or Mac. That device still holds this"
  say "      gateway's address and its token, and nothing here can reach it: remove the"
  say "      connection in the app too. If you are removing this because the token leaked,"
  say "      rotate the token at the gateway — that is the only thing that revokes it."
  if [ "$unattributed" -gt 0 ]; then
    say ""
    note "$unattributed recorded exposure(s) here name no gateway, so I cannot tell whether they"
    note "belong to this setup. They are left exactly as they are; a normal run offers to"
    note "close leftover exposures it can identify."
  fi
  if [ ${#unreadable[@]} -gt 0 ]; then
    say ""
    warn "This machine holds ${#unreadable[@]} recorded exposure(s) in a format this version cannot read —"
    warn "an older conduck-connect wrote them, and they name no gateway at all. So I cannot"
    warn "tell whether one of them is the address in front of THIS gateway, and I will not"
    warn "close a route I cannot prove is yours. They are left exactly as they are:"
    # Filesystem-derived, like every other name this module prints: these paths
    # come out of an `exposure-*.pending` glob, so the middle of each one is
    # whatever a file in $STATE_DIR is called. Same safe_display rule as the
    # inventory — a name is read here, never acted on.
    for f in ${unreadable[@]+"${unreadable[@]}"}; do
      say "    $(safe_display "$f" 400)"
    done
    warn "One of them may be a PUBLIC Tailscale Funnel that outlives this removal. What is"
    warn "actually live is the authority on that, not those files — read it with:"
    printf '    %stailscale serve status%s\n' "$BOLD" "$RESET"
    printf '    %stailscale funnel status%s\n' "$BOLD" "$RESET"
    say "  Anything there you no longer want, closed by hand, per HTTPS port:"
    printf '    %stailscale funnel --https=<port> off%s   # remove a PUBLIC exposure\n' "$BOLD" "$RESET"
    printf '    %stailscale serve --https=<port> off%s\n' "$BOLD" "$RESET"
    note "I did not run those."
  fi
  if [ -n "$ts_reason" ]; then
    say ""
    warn "This machine has recorded Tailscale exposures, and $ts_reason,"
    warn "so I cannot tell whether any of them belongs to this setup. Every one of them is"
    warn "left exactly as it is. Check 'tailscale serve status' and 'tailscale funnel status'."
  fi

  # --reuse-only means "change nothing", and this whole command is a change.
  # Refused before the typed prompt, never after: asking somebody to type an id
  # and then declining to act on it is the worst possible order.
  mutate_guard "remove the saved setup $id, its file server, and its stored password"

  # A TYPED confirmation, not [y/N]. Enter is No at every gate in this program so
  # that pressing it in rhythm is always safe; the one irreversible action must not
  # be reachable by that same reflex. Typing the id also answers a second question
  # the y/N never could — WHICH setup — which is the mistake that matters on a
  # machine with two of them.
  #
  # Typed or not, it is still a prompt, so it keeps the prompt contract: a key is
  # a control here IF AND ONLY IF this suffix advertises it, and the suffix comes
  # from control_suffix — the one renderer every other prompt's suffix comes from,
  # so the two cannot drift apart. Back is not offered and so is not advertised;
  # i is, and it earns its place at this prompt more than at any other in the tool,
  # because this is the only answer that cannot be taken back. q stops the RUN
  # rather than merely cancelling: a key advertised as "stop" that quietly does
  # what Enter already does is exactly the drift the contract exists to prevent.
  #
  # No prompt_echo: manage_forget refused a run without an interactive terminal
  # several screens ago, so `read -r -p` always has a terminal to write its prompt
  # to and the re-emission would be unreachable.
  local reply p
  say ""
  p="  Type ${BOLD}$id${RESET} to remove it ($(control_suffix "cancel")): "
  while true; do
    if ! read -r -p "$p" reply; then
      say ""
      note "No answer — nothing was removed."
      return 3
    fi
    # A one-character id can BE a control key: ids are lowercase letters, digits
    # and hyphens, so "q" is a legal id and this prompt is the one place in the
    # program where the two readings of that keystroke are "stop" and "delete
    # irreversibly". Neither may be chosen silently, so the same primitive every
    # ambiguous free-text prompt uses asks once, with the control as the default.
    case "$reply" in
      [iI]|\?|[qQ])
        if [ "$reply" = "$id" ]; then
          case "$reply" in
            [qQ]) prompt_wants_literal "$reply" "stopping the run" ;;
            *)    prompt_wants_literal "$reply" "showing an explanation" ;;
          esac
          case $? in
            0) break ;;                                    # they meant the id
            2) say ""; note "No answer — nothing was removed."; return 3 ;;
          esac
        fi
        case "$reply" in
          [qQ]) quit_run ;;
          *)    explain_prompt explain_manage_forget ;;
        esac
        continue ;;
    esac
    case "$reply" in
      "$id") break ;;
      '') note "Cancelled — nothing was removed."; return 3 ;;
      *) warn "That is not \"$id\". Type it exactly, press Enter to cancel, or i to read"
         warn "what removal does and does not touch." ;;
    esac
  done

  # Only the record FILES travel across the confirmation, never the entries read
  # from them. The typed prompt can sit on screen for minutes, and an exposure that
  # belonged to this gateway during the disclosure may belong to another one by the
  # time the operator answers — so the mapping to be closed is re-read and
  # re-attributed on the far side of the pause, immediately before it is touched.
  manage_forget_apply "$id" "$pf" "$credf" "$envf" "$unit" "${files[@]+"${files[@]}"}"
}

# The removal itself, after consent. Split out so the disclosure above reads as one
# screen and so a test can drive the destructive half against a fixture directory
# without answering a prompt.
#
# It deletes whatever paths it is HANDED and validates none of them — the id check
# and the path construction both live in manage_forget, which is the only caller
# and the only place an id from outside ever arrives. A second caller would have to
# do the same, and a test that drives this directly proves nothing about the safety
# of the paths it made up.
#
# Everything here is act-then-PROVE: each command may fail for reasons this script
# cannot see (a service manager refusing the domain, a file another account owns),
# so nothing is reported as removed until the state is RE-READ — the service from
# fs_unit_state, the files from a fresh stat, the exposure from a fresh
# `tailscale serve status`. An exit code is never the evidence.
manage_forget_apply() { # manage_forget_apply <id> <pf> <credf> <envf> <unit> [exposure-record-file…]
  local id="$1" pf="$2" credf="$3" envf="$4" unit="$5"; shift 5
  local live=() files=() f
  # Re-read every candidate record from scratch, against a FRESHLY read Tailscale
  # status. The disclosure's list is a disclosure; THIS list is what gets acted on,
  # so it re-checks the version, the owning gateway id and the liveness as they are
  # right now. `exposure_record_is_live` compares against TS_PORTS, so a stale
  # ts_targets would reproduce the very window this re-read exists to close.
  if [ $# -gt 0 ] && have tailscale; then
    ts_targets
    if $TS_STATE_KNOWN; then
      for f in "$@"; do
        [ -f "$f" ] || continue
        read_exposure_record "$f" || continue
        [ "$REC_GWID" = "$id" ] || continue
        exposure_record_is_live || continue
        live+=("$REC_PORT"$'\t'"$REC_AVERB"$'\t'"$REC_PRIOR")
        files+=("$f")
      done
    else
      warn "Tailscale's live state could not be read just now, so no address in front of"
      warn "this gateway is touched. Check 'tailscale serve status' afterwards."
    fi
  fi

  # What was actually here, captured BEFORE anything is touched — the success line
  # names only these. Asked now because after the removal every one of them is
  # indistinguishable from "there was never one".
  local had_profile=false had_unit=false had_cred=false had_env=false
  [ -f "$pf" ]    && had_profile=true
  [ -f "$unit" ]  && had_unit=true
  [ -f "$credf" ] && had_cred=true
  [ -f "$envf" ]  && had_env=true

  local unit_name unit_stopped=true stop_reason=""
  say ""
  # The exposure first: an HTTPS route in front of a file server that is about to
  # stop would otherwise spend a moment answering 502 to the internet, and a public
  # one is the thing on this list with the shortest fuse.
  if [ ${#live[@]} -gt 0 ]; then
    local i
    for (( i=${#live[@]}-1; i>=0; i-- )); do
      undo_exposure_entry "${live[$i]}"
    done
    ts_targets
    local leftover=() entry port want t
    for (( i=0; i<${#live[@]}; i++ )); do
      entry="${live[$i]}"; port="${entry%%$'\t'*}"
      want=$(undo_target_for_entry "$entry")
      t=$(ts_target_for_port "$port")
      if ! $TS_STATE_KNOWN || [ "${t:-}" != "$want" ]; then
        leftover+=("$entry")
      else
        [ "$i" -lt ${#files[@]} ] && rm -f "${files[$i]}" 2>/dev/null || true
        if [ -n "$want" ]; then
          ok "Port $port is back to the private mapping it carried before."
        else
          ok "Port $port is no longer exposed."
        fi
      fi
    done
    if [ ${#leftover[@]} -gt 0 ]; then
      warn "Could not confirm every address in front of this gateway was closed — often"
      warn "missing operator or root rights. To close them by hand:"
      print_undo_hints "${leftover[@]}"
      local rp; rp=$(priv_prefix)
      [ -n "$rp" ] && note "If Tailscale refuses those, prefix each with '$rp'."
      note "I ran the same commands and could not prove they took effect."
    fi
  fi

  # Stop and disable BEFORE deleting. A systemd unit whose file vanishes while it
  # is enabled leaves a `failed` entry that only reset-failed clears, and a loaded
  # LaunchAgent whose plist vanishes keeps running with the password it already
  # read — which would make "the password is gone" false in the one way that
  # matters.
  #
  # The stop command's EXIT CODE is not the evidence, in either direction.
  # `launchctl unload` answers nonzero for a plist that was never loaded (the
  # ordinary case for a stopped service), and it can also answer zero while the job
  # survives in another domain. So the command runs, and then fs_unit_state is
  # asked again: the unit file is deleted only once the supervisor says the service
  # is no longer running. A still-running service keeps its file, and the report
  # says so — deleting it would strand a live WebDAV server holding a password
  # nothing on disk records any more.
  if [ -f "$unit" ]; then
    unit_name=$(basename "$unit")
    if [ "$OS" = "Linux" ]; then
      if have systemctl; then
        systemctl --user disable --now "$unit_name" >/dev/null 2>&1 || true
        systemctl --user reset-failed "$unit_name" >/dev/null 2>&1 || true
      else
        unit_stopped=false; stop_reason="no-supervisor"
      fi
    else
      if have launchctl; then
        launchctl unload "$unit" >/dev/null 2>&1 || true
      else
        unit_stopped=false; stop_reason="no-supervisor"
      fi
    fi
    if $unit_stopped; then
      case "$(manage_unit_state "$unit")" in
        active)  unit_stopped=false; stop_reason="still-running" ;;
        unknown) unit_stopped=false; stop_reason="unprovable" ;;
      esac
    fi
    if $unit_stopped; then
      rm -f "$unit" 2>/dev/null || true
      if [ "$OS" = "Linux" ] && have systemctl; then
        systemctl --user daemon-reload >/dev/null 2>&1 || true
      fi
    fi
  fi

  # A symlink is removed as a LINK — `rm -f` unlinks it and the file it points at
  # survives, while the `[ -f ]` proof below follows the link, finds nothing, and
  # would report the password gone. Nothing this script writes is ever a symlink,
  # so reaching this is somebody's own arrangement; it is named rather than
  # followed, because chasing a link to delete whatever is on the far end is not a
  # thing a removal command may do on its own.
  local l
  for l in "$credf" "$envf"; do
    [ -L "$l" ] || continue
    warn "$l is a symbolic link. I remove the link; the file it points at is not touched,"
    warn "and it still holds the file-server password."
  done

  rm -f "$credf" 2>/dev/null || true
  rm -f "$envf" 2>/dev/null || true
  rm -f "$pf" 2>/dev/null || true

  # PROVE it, file by file. An `rm` that returned nothing still tells us nothing
  # about a file another account owns or a read-only mount, and this command's
  # whole value is that its report can be believed.
  local still=() still_files=()
  [ -f "$pf" ]    && { still+=("$pf");    still_files+=("$pf"); }
  [ -f "$credf" ] && { still+=("$credf"); still_files+=("$credf"); }
  [ -f "$envf" ]  && { still+=("$envf");  still_files+=("$envf"); }
  # The unit goes in `still` but NOT in `still_files`: fs_print_teardown takes it
  # as its first argument and prints the disable/unload block for it, so listing it
  # again among the plain `rm -f` targets would hand the operator the same deletion
  # twice — once correctly sequenced, once not.
  [ -f "$unit" ]  && still+=("$unit")

  if [ ${#still[@]} -eq 0 ]; then
    # Name only what actually existed. "its profile, its file server, and its
    # stored password" is a lie on a chat-only setup, and a removal report that
    # overstates by one clause is one an operator learns to stop reading.
    local removed="" last="" subject="the saved setup"
    $had_profile || subject="the leftover file server"
    $had_profile && last="its profile"
    $had_unit    && { removed="${removed:+$removed, }$last"; last="its file server"; }
    { $had_cred || $had_env; } && { removed="${removed:+$removed, }$last"; last="its stored password"; }
    removed="${removed:+$removed and }$last"
    ok "Removed $subject \"$id\"${removed:+: $removed}."
    # Names the two files it removed rather than claiming "both copies are gone".
    # The absolute claim cannot be made from here: a legacy unnamed unit
    # (conduck-files.service / ai.gigaduck.conduck-fileserver.plist) can hold the
    # same RCLONE_PASS and belongs to no id, so nothing addressed by id can speak
    # for it. manage_leftovers_scan below is what actually looks.
    if [ "$OS" != "Linux" ] && $had_unit && $had_cred; then
      note "That removed both copies this id owned — $(basename "$credf") and the copy inside"
      note "$(basename "$unit")."
    fi
    manage_warn_legacy_password_copy
  else
    say ""
    warn "Some of it is still here. I could not remove:"
    local s
    for s in "${still[@]}"; do say "    $s"; done
    # Three different reasons the service file is still there, and they need three
    # different next moves. Collapsing them into one "could not remove it" is how
    # an operator with a live file server reads their way past the fact.
    case "$stop_reason" in
      no-supervisor)
        if [ "$OS" = "Linux" ]; then
          warn "This shell has no 'systemctl', so I did not stop or disable the service and did"
          warn "not delete its file — deleting an enabled unit leaves systemd in a failed state."
        else
          warn "This shell has no 'launchctl', so I did not unload the service and did not delete"
          warn "its file — the running server would keep the password it already read."
        fi ;;
      still-running)
        warn "I asked the supervisor to stop that file server and it is STILL RUNNING, so I"
        warn "left its file in place: deleting it now would leave a live WebDAV server over"
        warn "your agent's folder with nothing on disk left to describe it. Stop it by hand"
        warn "with the commands below, then re-run --forget $id." ;;
      unprovable)
        warn "I could not get an answer about whether that file server is still running, so I"
        warn "left its file alone rather than delete it on a guess." ;;
    esac
    say ""
    say "  To finish it by hand:"
    fs_print_teardown "$([ -f "$unit" ] && printf '%s' "$unit")" \
      ${still_files[@]+"${still_files[@]}"}
    note "I did not run those commands."
    # The list above is a list of paths; this says what one of them MEANS. A
    # surviving .cred, a surviving .env, or — on macOS — a surviving plist each
    # hold the WebDAV password in cleartext, and "I could not remove three files"
    # is not a sentence an operator reads as "a live password is still here".
    local secret_left=false
    { [ -f "$credf" ] || [ -f "$envf" ]; } && secret_left=true
    { [ "$OS" != "Linux" ] && [ -f "$unit" ]; } && secret_left=true
    if $secret_left; then
      warn "The file-server password is STILL on this disk, in the file(s) listed above — it"
      warn "opens a WebDAV server over your agent's folder. Until they are gone, treat that"
      warn "password as live."
    fi
    return 1
  fi

  # The last word is about the device that is not on this machine and that nothing
  # here can reach. Repeated after the fact, not only before it, because the
  # operator has just typed an id and read a success line — this is the moment the
  # remaining action is actually theirs.
  say ""
  say "  Still to do, on the paired device: remove this gateway's connection in the"
  say "  Conduck app. It holds the address and the token, and nothing on this machine"
  say "  can reach it."
  note "Your configuration folder is $STATE_DIR — run --list to see what is left."
  return 0
}

# A removal addressed by id cannot speak for the two LEGACY unnamed units, which
# carry no id in their names and which an older setup run could have created for
# this very gateway — and on macOS such a plist holds the same cleartext
# RCLONE_PASS as the .cred that was just deleted. So after a clean removal, look,
# and say plainly that a copy may still be there. Silence here is the one way a
# successful-looking removal leaves a live password behind.
manage_warn_legacy_password_copy() {
  local u legacy_unit=""
  if [ "$OS" = "Linux" ]; then
    for u in "${HOME:-}/.config/systemd/user/conduck-files.service" \
             "${HOME:-}/.config/systemd/user/conduck-fileserver.service"; do
      [ -f "$u" ] && legacy_unit="$u"
    done
  else
    for u in "${HOME:-}/Library/LaunchAgents/ai.gigaduck.conduck-files.plist" \
             "${HOME:-}/Library/LaunchAgents/ai.gigaduck.conduck-fileserver.plist"; do
      [ -f "$u" ] && legacy_unit="$u"
    done
  fi
  [ -n "$legacy_unit" ] || return 0
  say ""
  warn "There is also a file server here that carries no gateway id in its name:"
  note "$legacy_unit"
  warn "It may be an older service for this same gateway, and on this system such a file"
  warn "can hold its own cleartext copy of the file-server password. I cannot attribute it"
  warn "to any id, so I did not touch it. Run --list to see its state and its folder."
  return 0
}

# --------------------------------------------------------- terminal refusal --

# Exit 4 is the documented "this action needs an interactive terminal" status.
# refuse_without_a_terminal is not reused: its copy is about setup ending in a QR
# code a person scans, which is true of neither editing nor removing — and the
# scriptable alternative it names is a pair of check commands, when the real answer
# for a machine that wants to know what is saved here is one flag away.
manage_refuse_without_a_terminal() { # manage_refuse_without_a_terminal <subject>
  say ""
  printf '%sError:%s %s\n' "$RED" "$RESET" "$1 needs a person at a terminal." >&2
  say "  It asks which setup, asks what to change, and — for a removal — asks you to"
  say "  type the id back. None of that has a safe unattended answer."
  say ""
  say "  ${BOLD}What runs with no terminal at all:${RESET}"
  say "    bash conduck-connect.sh --list --json"
  note "One JSON object: every saved setup, where they live, and any file server left"
  note "running with no setup behind it. It reads only, and prints no secrets."
  exit 4
}

# ----------------------------------------------------------- explanations --
#
# These live here rather than in the explanation catalogue because explain_prompt
# resolves a FUNCTION name before it consults the catalogue, and a manage screen
# that shipped with catalogue ids nobody had written yet would answer `i` with the
# generic "review the action above" panel — which is exactly the hollow control
# this release exists to remove.

explain_manage_pick() {
  say ""
  say "  ${BOLD}What you are choosing${RESET}"
  say "  One of the setups this machine has already paired. Every finished setup"
  say "  leaves a small record of where that gateway lives and how it is reached —"
  say "  no passwords, just the routing."
  say ""
  say "  ${BOLD}What happens next${RESET}"
  say "  You get a screen for that one setup where you can change a single thing"
  say "  about it, show its code again, or remove it. Picking does nothing by"
  say "  itself, and picking the wrong one costs nothing: b goes back."
  say ""
}

explain_manage_edit() {
  say ""
  say "  ${BOLD}What this screen changes${RESET}"
  say "  One field of one saved setup, and only what that field affects. Changing"
  say "  the address re-checks the address; it does not re-run the gateway setup,"
  say "  touch your tunnel, or restart anything."
  say ""
  say "  ${BOLD}Why the app does not update on its own${RESET}"
  say "  A setup code is a snapshot your device imported once, not a live link. So"
  say "  when you change something here, the paired device keeps the old value"
  say "  until it scans a new code — which is what option 4 prints."
  say ""
  say "  ${BOLD}Honestly unsure?${RESET}"
  say "  If the app simply stopped connecting and nothing on this machine changed,"
  say "  the address is the usual culprit — especially on a Cloudflare quick"
  say "  tunnel, whose hostname is different after every restart."
  say ""
}

# The one prompt in this program whose answer cannot be taken back, so this is the
# one explanation that is read AFTER a disclosure rather than instead of it: the
# screen above already lists the exact files, so this says what those files MEAN,
# what the removal cannot reach, and how to leave without removing anything.
explain_manage_forget() {
  say ""
  say "  ${BOLD}What typing the id does${RESET}"
  say "  Removes the four things listed above, on this machine, and nothing else:"
  say "  the saved setup, its file server, its stored password, and its environment"
  say "  file. Each one is re-read afterwards, and anything still there is reported"
  say "  as still there, with the command to finish it by hand."
  say ""
  say "  ${BOLD}Why you type the id instead of pressing y${RESET}"
  say "  Enter means No at every other question here, so pressing it in rhythm is"
  say "  always safe. This is the only step that cannot be undone, and it must not"
  say "  be reachable by that same reflex — typing the id also says WHICH setup,"
  say "  which is the mistake that matters on a machine with two of them."
  say ""
  say "  ${BOLD}What it cannot reach${RESET}"
  say "  Your shared folder and everything in it. Your gateway, which keeps running"
  say "  with the same token. And the pairing already on your phone or Mac — that"
  say "  device holds this gateway's address and token, and nothing here can talk"
  say "  to it, so remove the connection in the app too. If a token leaked, rotate"
  say "  it at the gateway; that is the only thing that revokes it."
  say ""
  say "  ${BOLD}Honestly unsure?${RESET}"
  say "  Press Enter. Nothing is removed, nothing is written, and the setup is"
  say "  exactly as it was — you can read it again with --list and come back."
  say ""
}

explain_manage_address() {
  say ""
  say "  ${BOLD}What to type${RESET}"
  say "  The https:// address that reaches this gateway from outside this machine —"
  say "  the base address, with no /v1 and no other endpoint on the end. If you run"
  say "  a Cloudflare quick tunnel, it is the *.trycloudflare.com line cloudflared"
  say "  prints when it starts."
  say ""
  say "  ${BOLD}What it does${RESET}"
  say "  Sends one request to that address to see whether anything answers, then"
  say "  saves it. It creates no tunnel and moves no route — it records where the"
  say "  address already is."
  say ""
  say "  ${BOLD}If nothing answers${RESET}"
  say "  You are still offered the save, because setting the address before the"
  say "  tunnel is up is a normal order to work in. The check just cannot vouch"
  say "  for it."
  say ""
  say "  ${BOLD}Honestly unsure?${RESET}"
  say "  Press b. Nothing is saved until you answer this, and the old address keeps"
  say "  working exactly as well or as badly as it did a minute ago."
  say ""
}

explain_manage_show_code() {
  say ""
  say "  ${BOLD}What a setup code is${RESET}"
  say "  A QR square carrying the address, the key and the file settings, so a"
  say "  device imports the lot in one scan. Treat it like a password: anyone who"
  say "  photographs it has everything the app has."
  say ""
  say "  ${BOLD}Why now${RESET}"
  say "  You just changed something the paired device cannot learn on its own."
  say "  Until it scans a new code it keeps using the old value."
  say ""
  say "  ${BOLD}What it costs${RESET}"
  say "  Printing a code re-runs the live checks, which send real requests to your"
  say "  gateway. On a metered model that spends a little quota. Saying no here"
  say "  changes nothing — bash conduck-connect.sh --show-code prints it later."
  say ""
}
