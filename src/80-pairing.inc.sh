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
      # Names the directory for the same reason the success branch below does:
      # this run ends with a working code and no failure, so it is one of the
      # screens where an operator would otherwise never learn their setups exist
      # as files they can read, copy or remove.
      note "Kept the saved pairing profile in $STATE_DIR exactly as it is — --reuse-only changes nothing, and this file counts."
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
      note "Left the saved pairing profile in $STATE_DIR untouched, so the file lane it records survives this run's probe failure."
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
    # Names the directory, because this is the last screen of a successful run and
    # $STATE_DIR otherwise reaches the operator only inside a permissions warning —
    # so somebody who never hits a failure never learns where their setups live.
    note "Saved a non-secret pairing profile (no key) in $STATE_DIR."
    note "Re-show this code — to pair another device, or after something changes — with:  bash conduck-connect.sh --show-code"
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

# ------------------------------------------------------------- --emit-code --
#
# The scriptable minter: the pairing code, built from what it is TOLD, with no
# terminal, no saved state and no network.
#
# Why it exists. Eight independent AI builders, given only the public contract,
# the build brief and --help, each concluded that producing a `conduck-setup:v1`
# code was impossible without their operator — and each was right. --setup is the
# only minter and it ends at a QR a person scans; --show-code re-emits a profile
# that only a completed --setup writes, which a fresh build rig has never had. So
# the last step of "build an adapter and prove it works" had no machine-drivable
# form at all, and every one of them hand-rolled the base64 from PAYLOAD.md. That
# they all got it right says the format spec is good; that they all had to says
# this command was missing.
#
# What it deliberately does NOT do, and each has a reason:
#   * it never writes a profile, so nothing about this host changes and a later
#     --show-code is not quietly taught about a gateway nobody set up here;
#   * it never sends a request, because a builder mints the code BEFORE the
#     exposure exists — a minter that verified would be unusable at the one
#     moment it is wanted, and --check-adapter is the command that verifies;
#   * it prints no QR. A QR is for a person holding a phone; this output is for a
#     pipe, and the text form is the same secret in the same v1 wrapping.
#
# It reuses build_pairing_payload_json and b64_nowrap rather than assembling
# anything of its own, so a code from here and a code from --setup are the same
# bytes for the same inputs, and a change to the payload cannot reach one without
# reaching the other.
#
# The two secrets arrive in the ENVIRONMENT, never on argv, for the reason there
# is no --token flag anywhere in this CLI: argv is readable by every process on
# the host through `ps`.

# Grade one free-form display string EXACTLY as the app grades it on import, and
# hand back the trimmed form the app will actually keep. The app rejects the WHOLE
# payload — not the offending field — when a name or a model id is over its cap or
# carries a scalar that can spoof or corrupt rendered text, so a code minted around
# one of those imports and dies with nothing on screen to explain it. Mirror of the
# app's PairingPayload.sanitizedDisplayText + isDisplayHostile, including the caps.
#
# The trim mirrors Swift's .whitespacesAndNewlines, spelled out rather than left to
# python's str.strip(): str.strip() ALSO eats the C0 file/group/record separators,
# which the app does not trim and then refuses — so borrowing it would accept a name
# the app rejects, the exact failure this function exists to stop.
#
# Echoes "<verdict> <detail>": "ok <trimmed-text>", "long <scalar-count>" or
# "hostile U+XXXX". Echoes NOTHING when python3 is missing, and the caller then
# leaves the value exactly as typed — this runs at validate_cli time, before the
# runtime preflight, so a missing interpreter must never turn into an exit-2 command
# misuse (the same rule doctor_accept_url keeps by staying pure Bash). run_emit_code
# names the missing python3 as an exit-1 runtime failure moments later.
emit_display_text_grade() { # emit_display_text_grade <text> <max-scalars>
  EMIT_DT_TEXT="$1" EMIT_DT_MAX="$2" python3 - <<'PY' 2>/dev/null
import os, sys
text = os.environ["EMIT_DT_TEXT"]
cap = int(os.environ["EMIT_DT_MAX"])
# Swift's CharacterSet.whitespacesAndNewlines: TAB, the newline family (LF VT FF CR,
# NEL, LINE/PARAGRAPH SEPARATOR) and general category Zs.
ws = "".join(chr(c) for c in
             (0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680,
              0x2028, 0x2029, 0x202F, 0x205F, 0x3000)) \
     + "".join(chr(c) for c in range(0x2000, 0x200B))
text = text.strip(ws)
# len() over a str counts code points, which is the app's own unit (unicodeScalars).
if len(text) > cap:
    sys.stdout.write("long %d" % len(text))
    raise SystemExit(0)
for ch in text:
    o = ord(ch)
    if (o <= 0x1F or o == 0x7F or 0x80 <= o <= 0x9F          # C0 + DEL + C1
            or o in (0x200E, 0x200F, 0x2028, 0x2029)         # LRM/RLM, LS/PS
            or 0x202A <= o <= 0x202E or 0x2066 <= o <= 0x2069):  # bidi embed/override/isolate
        sys.stdout.write("hostile U+%04X" % o)
        raise SystemExit(0)
sys.stdout.write("ok " + text)
PY
}

# The two callers of the grader, held in one place so --name and --model cannot
# drift apart. Refuses rather than truncates or strips, for the reason --name on a
# builtin kind is refused: a silently altered label is one the operator read in
# their terminal and will never see in the app. Sets EMIT_GRADED_TEXT to the trimmed
# value; exits 2 on either refusal.
emit_grade_display_text() { # emit_grade_display_text <flag> <field-word> <text> <max>
  local graded verdict detail
  graded=$(emit_display_text_grade "$3" "$4")
  # No python3 to grade with — keep the value as typed and let run_emit_code report
  # the missing interpreter as the runtime failure it is.
  [ -n "$graded" ] || { EMIT_GRADED_TEXT="$3"; return 0; }
  verdict="${graded%% *}"; detail="${graded#* }"
  case "$verdict" in
    long)
      usage_die "$1 is $detail characters long. The app refuses a $2 over $4 characters — and it refuses the WHOLE setup code, not just that field. Shorten it." ;;
    hostile)
      usage_die "$1 contains $detail, which the app refuses in a $2: scalars like that reorder or break the text they are rendered in. It refuses the WHOLE setup code over one, so use plain text." ;;
  esac
  EMIT_GRADED_TEXT="$detail"
}

# argv-shape validation, at validate_cli time so a wrong invocation exits 2
# before anything runs. The two SECRETS are checked in run_emit_code instead:
# a missing environment variable is a runtime condition, and both checks already
# report that one as exit 1 with the instruction attached.
emit_code_validate() {
  local url norm
  # The app's own caps, named where they are used. Both live in PairingPayload.
  local name_max=120 model_max=200
  [ -n "$EMIT_URL" ] || usage_die "--emit-code needs the gateway's address: --url https://your.gateway (try --help)."
  # The SAME admissibility rule --setup applies at its prompt, applied here as a
  # function rather than a prompt. It has to be the same one: this command mints
  # a code the app imports, and a minter that accepted an address the app refuses
  # would hand somebody a code that fails on their phone with nothing to explain it.
  url=$(doctor_accept_url "$EMIT_URL") || {
    # The rejected value may contain a password, so the userinfo case never
    # echoes it back — the same rule the checks' URL guard follows.
    url_has_userinfo "$EMIT_URL" && usage_die "$URL_USERINFO_HINT"
    usage_die "Can't pair '$EMIT_URL' — use https://… (or http:// toward an address only your own network can reach)."
  }
  EMIT_URL="$url"
  # The SAME rewrite every other producer of a gateway URL applies — every one of
  # them reaches apply_gateway_url_normalization, and this command is the only place
  # a URL became a payload without passing through it. PAYLOAD.md promises --emit-code
  # and --setup produce identical bytes for identical inputs, and without this line
  # they do not: --url https://ai.example.com/v1 would mint a base the app appends
  # /v1/… to a second time, and a ?key=… query would ride into the code. Fails OPEN on
  # a python3 hiccup (empty result) for the reason the grader above does — this runs
  # before the runtime preflight.
  norm=$(normalize_gateway_base_url "$EMIT_URL")
  if [ -n "$norm" ] && [ "$norm" != "$EMIT_URL" ]; then
    # stderr, not `note`: stdout belongs to the code and nothing else. Said out loud
    # rather than done quietly, because the address in the code is then not the
    # address on the command line, and the wizard says the same sentence.
    printf 'Using %s — Conduck adds /v1/… itself, so the base address must not already end in it.\n' "$norm" >&2
    EMIT_URL="$norm"
  fi

  case "${EMIT_KIND:=custom}" in
    openclaw|hermes|custom) ;;
    *) usage_die "--kind takes openclaw, hermes or custom (given: '$EMIT_KIND')." ;;
  esac
  # A name is a CUSTOM gateway's field and only a custom gateway's — PAYLOAD.md
  # omits it for the two named kinds, and the app knows what to call those two
  # already. Refusing rather than dropping it: a silently discarded name is a
  # label somebody expects to see in the app and never will.
  if [ "$EMIT_KIND" != "custom" ] && [ -n "$EMIT_NAME" ]; then
    usage_die "--name applies to --kind custom only; the app names an $EMIT_KIND gateway itself."
  fi
  # A model is the same story one field over, and the same refusal for the same
  # reason: the app seeds a model override for a CUSTOM gateway only, so a model on
  # a builtin kind is read, discarded, and never seen again. Somebody who passed
  # --model meant the gateway to answer on that model; dropping it silently is how
  # they find out weeks later, from the wrong model's replies.
  if [ "$EMIT_KIND" != "custom" ] && [ -n "$EMIT_MODEL" ]; then
    usage_die "--model applies to --kind custom only; the app ignores a model on an $EMIT_KIND gateway."
  fi
  # Both free-form fields are graded against the app's OWN import rules before
  # anything is minted, and both are stored back TRIMMED, because the app trims them
  # too — so what this command calls the name is what the app will call it. The trim
  # has to happen before the default below: --name "   " is not a name the app will
  # accept, and left untrimmed it would suppress the default and mint a code the app
  # then refuses whole.
  if [ -n "$EMIT_NAME" ]; then
    emit_grade_display_text "--name" "gateway name" "$EMIT_NAME" "$name_max"
    EMIT_NAME="$EMIT_GRADED_TEXT"
  fi
  if [ -n "$EMIT_MODEL" ]; then
    emit_grade_display_text "--model" "model id" "$EMIT_MODEL" "$model_max"
    EMIT_MODEL="$EMIT_GRADED_TEXT"
  fi
  # The app REJECTS a custom gateway carrying no name, so an empty one here would
  # mint a code that imports and fails. "My gateway" is not invented for this
  # command — it is the default the wizard's own name prompt offers, so pressing
  # Enter there and omitting --name here produce the same code.
  [ "$EMIT_KIND" = "custom" ] && [ -z "$EMIT_NAME" ] && EMIT_NAME="My gateway"

  case "${EMIT_TRANSPORT:=public}" in
    tailscale|funnel|cloudflare|public) ;;
    *) usage_die "--transport takes tailscale, funnel, cloudflare or public (given: '$EMIT_TRANSPORT')." ;;
  esac

  if [ -n "$EMIT_FILES_URL" ]; then
    url=$(doctor_accept_url "$EMIT_FILES_URL") || {
      url_has_userinfo "$EMIT_FILES_URL" && usage_die "$URL_USERINFO_HINT"
      usage_die "Can't use '$EMIT_FILES_URL' as the file server — use https://… (or http:// toward an address only your own network can reach)."
    }
    EMIT_FILES_URL="$url"
  fi
  return 0
}

# Mint it. Exit 1 for anything that is not an argv-shape problem, which by here
# means one of the two secrets.
run_emit_code() {
  # python3 builds the payload and base64 wraps it. Named individually rather
  # than through preflight, which would additionally demand curl and openssl:
  # this command sends no request and mints no credential, and refusing to print
  # a code on a box that lacks the tools for setting one up would be the same
  # dead end --forget's own narrower check exists to avoid.
  need python3 || die "--emit-code builds the pairing payload with python3, and this host doesn't have it."
  need base64  || die "--emit-code needs base64 to wrap the payload, and this host doesn't have it."

  # Fail CLOSED on a merely-absent key. An unset CONDUCK_TOKEN is silence, and
  # reading silence as "this gateway has no key" mints a code that pairs the app
  # to an authenticated gateway with no credential — it fails later, in the app,
  # with nothing on screen to say why. Keyless has to be SAID: --keyless, or the
  # set-but-empty CONDUCK_TOKEN that already means exactly this everywhere else
  # in this tool.
  local token="" auth="none"
  if [ "${CONDUCK_TOKEN+set}" = "set" ]; then
    token="$CONDUCK_TOKEN"
    if [ -n "$token" ]; then
      $EMIT_KEYLESS && usage_die "--keyless says this gateway has no key, but CONDUCK_TOKEN holds one. Drop the flag, or unset the variable."
      # The same gate every other consumer of this variable applies before using it.
      # A control character in a key is never deliberate — it is a newline or a tab
      # picked up by however the key was copied — and minting one produces a code
      # that carries a token the gateway will never recognise. The value is never
      # echoed back: it is the key.
      credential_value_safe "$token" || die "CONDUCK_TOKEN contains a control character, so it cannot go into a setup code. That is almost always a stray newline or tab from copying it — re-copy the key and try again."
      auth="bearer"
    fi
  elif ! $EMIT_KEYLESS; then
    die "No key to put in the code. Set CONDUCK_TOKEN=<key> (never pass it on the command line — argv is world-readable via ps). For a gateway that genuinely has none, say so with --keyless."
  fi

  local files_cred=""
  if [ -n "$EMIT_FILES_URL" ]; then
    [ "${CONDUCK_FILES_PASS+set}" = "set" ] && files_cred="$CONDUCK_FILES_PASS"
    [ -n "$files_cred" ] || die "--files-url names a file server, so its password has to ride the code too: set CONDUCK_FILES_PASS=<password>. Leave both out for a gateway with no file lane."
    credential_value_safe "$files_cred" || die "CONDUCK_FILES_PASS contains a control character, so it cannot go into a setup code. That is almost always a stray newline or tab from copying it — re-copy the password and try again."
    # The payload has NO username field: the app always signs in to the file server
    # as `conduck`. A build rig that graded its lane with CONDUCK_FILES_USER=webdav
    # and then mints from the same environment would otherwise get a code whose lane
    # 401s on the phone, with the variable that caused it still exported two commands
    # up and nothing anywhere saying it was ignored.
    if [ -n "${CONDUCK_FILES_USER:-}" ] && [ "$CONDUCK_FILES_USER" != "conduck" ]; then
      die "CONDUCK_FILES_USER is '$CONDUCK_FILES_USER', but a setup code carries no username — the app always signs in to the file server as 'conduck'. Give the file server a 'conduck' account, or unset the variable before minting."
    fi
  elif [ -n "${CONDUCK_FILES_PASS:-}" ]; then
    # The other half of "both or neither". A password with no address cannot go
    # into the code at all, and dropping it silently is how somebody ships a
    # gateway they believe carries a file lane and it does not.
    die "CONDUCK_FILES_PASS is set but no file server was named. Add --files-url <address>, or unset the password."
  fi

  # The payload builder reads globals, so this is where argv becomes the same
  # variables the wizard fills in — one assignment block, immediately above the
  # call, so nothing between them can be reading a stale value.
  GW_KIND="$EMIT_KIND"
  GW_NAME="$EMIT_NAME"
  GW_URL="$EMIT_URL"
  GW_AUTH="$auth"
  GW_TOKEN="$token"
  GW_MODEL="$EMIT_MODEL"
  FS_URL="$EMIT_FILES_URL"
  FS_CRED="$files_cred"
  TRANSPORT="$EMIT_TRANSPORT"

  local payload encoded
  payload=$(build_pairing_payload_json) || die "Could not build the pairing payload (python3 failed)."
  [ -n "$payload" ] || die "Could not build the pairing payload."
  encoded=$(printf '%s' "$payload" | b64_nowrap) || die "Could not base64-encode the pairing payload."
  [ -n "$encoded" ] || die "Could not base64-encode the pairing payload."

  # STDERR, and one line. Every other path that prints a code says out loud what it
  # carries, and a scripted caller is not a reason to stop saying it — the code is
  # going into a file or a log somewhere. stdout stays exactly the code and nothing
  # else, so `$(…)` around this command captures a usable string.
  #
  # Composed from what this code ACTUALLY carries, because the two secrets are
  # independent and a --keyless gateway with no file lane carries neither. A fixed
  # "this carries the gateway key" over a keyless code is a false warning, and a
  # false warning is how a true one stops being read.
  if [ -n "$token" ]; then
    printf 'This code carries the gateway key%s — treat every copy of it like the key itself.\n' \
      "${files_cred:+ and the file-server password}" >&2
  elif [ -n "$files_cred" ]; then
    printf 'This code carries the file-server password — treat every copy of it like that password.\n' >&2
  else
    printf 'This code names a keyless gateway and carries no secret — but it still names your gateway.\n' >&2
  fi
  printf 'conduck-setup:v%s:%s\n' "$PAYLOAD_VERSION" "$encoded"
  return 0
}

# What this code actually carries, in one place, immediately before it is shown.
# EVERY route that drops the file lane converges here — a confirmed skip at the
# address prompt, a live probe that failed, an agent gate that could not be
# proved — so this states the outcome without depending on WHY, and without the
# operator having to reconstruct it from warnings that have scrolled away.
# It earns its lines because the mistake is expensive and one-directional: the
# code gets scanned, and adding a lane afterwards means re-running setup, since
# --show-code can only re-emit a lane the profile already holds.
# Same condition build_pairing_payload_json uses to attach fileServer, so this
# summary cannot disagree with the code it describes.
#
# The file lane splits into TWO claims because it is two independent things: a
# server that moves bytes, and an agent that can use what arrives. A ✓ is spent
# only when a real agent turn proved the second — read the folder, write a file
# back, name it in the reply. Without that proof the line still says what IS in
# the code, and stops there: the payload has no field for a caveat, so this
# screen is the only place the difference can ever be stated, and a ✓ the
# operator later discovers was a guess is read on the phone, days later, as
# "the tool said it works".
# Its own function so the regression suite can drive all three outcomes; nothing
# here reads anything emit_payload computes.
pairing_capability_summary() {
  say "  ${BOLD}This code carries:${RESET}"
  ok "Chat with your gateway"
  if [ -n "$FS_URL" ] && [ -n "$FS_CRED" ]; then
    if [ "$FS_AGENT_PROOF" = "proved" ]; then
      ok "File transfer — attachments via $FS_URL"
    else
      warn "File server — attachments via $FS_URL, but your agent was NOT proved able to use them."
      note "Uploads reach that folder. Whether the agent reads them, and returns files through it,"
      note "is the half this run could not establish — the app shows file transfer as enabled either way."
    fi
  else
    warn "File transfer is NOT included — attachments stay inline-only."
    note "To add it later, re-run setup and give the file lane an address."
  fi
  # Photos are the third thing the app can send, and the only one whose failure it
  # cannot show: a picture that never reached the engine comes back as an ordinary
  # reply. Step 5 measured that against this exact address and model; this states
  # what the measurement means for the code about to be scanned, for the same
  # reason the lane above earns its lines — the payload has no field for it, and a
  # warning given three prompts ago has scrolled away by the time the code appears.
  # Silent when nothing was measured (a skipped, unmeasured, or not-yet-run gate):
  # a line about an unmeasured capability is the ✓-on-an-unmeasured-half bug again.
  # ${IMG_PROOF:-} because this function is deliberately lifted out of its module
  # by the suite, into a runtime that declares only what it drives.
  case "${IMG_PROOF:-}" in
    verified)
      ok "Photos — pictures you send reach the engine" ;;
    declined)
      note "Photos are refused with a clear \"pictures aren't supported here\" message." ;;
    too-large)
      warn "Photos will FAIL — a size cap on this route refused a few-kilobyte test picture." ;;
    opaque)
      warn "Photos will fail with an error the app can only show as a generic failure." ;;
    ignored-acked)
      warn "Photos are UNVERIFIED — the test picture came back unread, twice, and you paired anyway."
      note "A photo may be silently ignored: the reply looks confident either way, and the app cannot"
      note "tell you which it was." ;;
  esac
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
    # The diagnostic every failed run gets, whatever the gateway is. Which route it
    # addresses is the load-bearing part: the PUBLIC url, because that is the route
    # that just failed and the only one the app ever takes. Aimed at loopback these
    # PASS on every fault that lives in the HTTPS front — the operator then watches
    # the recommended diagnostic go green after a red run and concludes the wizard is
    # broken. A recovery that proves the wrong thing is worse than no recovery.
    # The loopback run is offered SECOND and named as a comparison, because the split
    # between the two is itself the diagnosis. One loopback command, not two: it
    # answers "the server, or the route?", and a second grader beside it would bury
    # that question under four near-identical lines.
    #
    # The app-compatibility grader is offered to EVERY kind. It asks whether the
    # app's own wire protocol survives this route, and an OpenClaw or Hermes user
    # staring at a red verification needs that answer exactly as much as a custom
    # one does — leaving them with "fix those first" and no command to run is the
    # dead end this release is about. Only the adapter grade stays custom-gated: it
    # holds software written FOR Conduck to Conduck's rules, and OpenClaw and Hermes
    # are not that, so a FAIL there would be noise on top of a failure.
    local lb; lb=$(gw_loopback_base)
    say ""
    say "  Check app compatibility on the route that failed:"
    say "    ${BOLD}bash conduck-connect.sh --check-server $GW_URL${RESET}"
    if [ "$GW_KIND" = "custom" ]; then
      say "  Adapter built for Conduck? Grade that same route against the stricter contract:"
      say "    ${BOLD}bash conduck-connect.sh --check-adapter $GW_URL${RESET}"
    fi
    if [ -n "$lb" ]; then
      say "  Then compare it against the server itself, skipping the HTTPS route in front of it:"
      say "    ${BOLD}bash conduck-connect.sh --check-server $lb${RESET}"
      note "Green there and red above means the server is fine and the HTTPS route is refusing or"
      note "changing the request — fix the route, not the server."
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
  pairing_capability_summary
  say ""
  # The file-lane clause must ride the SAME condition build_pairing_payload_json uses to
  # attach fileServer — warning about a shared folder that isn't in this code is a lie the
  # user cannot check, and omitting it when it IS in the code understates what they hold.
  warn "The setup code below CONTAINS YOUR GATEWAY KEY — both the QR and the plain-text string."
  if [ -n "$FS_URL" ] && [ -n "$FS_CRED" ]; then
    warn "It also carries the FILE-SERVER PASSWORD for your shared folder, so whoever holds"
    warn "this code can read and change the files in it."
  fi
  # An unencrypted address in this code is a fact about how the KEY travels, not
  # only about the messages: the app sends the bearer token on every request, so on
  # a plain-http lane anyone else on that network reads it and can then use the
  # gateway as the operator. Said HERE and not only at the prompt that accepted the
  # address, because this is the screen somebody is looking at when they decide to
  # scan it, and that prompt has long scrolled away — the same argument the quick
  # tunnel reminder below makes. --show-code re-emission lands here too.
  # Matched on the scheme alone: by this point the address has already been through
  # the one acceptor, so a plain-http one that got this far is a local one.
  local plain_gw=false plain_fs=false
  case "$GW_URL" in [Hh][Tt][Tt][Pp]://*) plain_gw=true ;; esac
  if [ -n "$FS_URL" ] && [ -n "$FS_CRED" ]; then
    case "$FS_URL" in [Hh][Tt][Tt][Pp]://*) plain_fs=true ;; esac
  fi
  if $plain_gw || $plain_fs; then
    if $plain_gw && $plain_fs; then
      warn "The gateway address AND the file-lane address in this code are plain http:// — NOT ENCRYPTED."
    elif $plain_gw; then
      warn "The gateway address in this code is plain http:// — NOT ENCRYPTED."
    else
      warn "The file-lane address in this code is plain http:// — NOT ENCRYPTED."
    fi
    warn "Everything to and from it crosses your network in the clear, including the secret this"
    warn "code carries for it, so anyone else on that network can read what you send and then use"
    warn "it themselves. It also only works while the device is ON that network — away from it"
    warn "nothing connects, and an Apple Watch used away from your iPhone never reaches it at all."
    note "Put https:// in front of it whenever you want either of those to stop being true, then"
    note "re-run me for a code that points at the new address."
  fi
  # What the code IS, said in the one place every route to a code passes through:
  # setup's own emission and --show-code's re-emission both land here. It states
  # the password rule and the fact behind every "why is it asking me again?" —
  # that nothing secret is written to this machine — and it replaces the two
  # hand-written sentences that used to say the first half twice, once per branch.
  explain_setup_code_secrecy
  warn "Devices sharing one key cannot be cut off one at a time — rotating it at the gateway"
  warn "cuts off every device using that key."
  warn "Note: over SSH, Ctrl-L only clears the visible screen — the code stays in your"
  warn "scroll-back, so close the terminal (or clear scroll-back) when you're done."
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
  # Both lines address the PUBLIC url: it is the route the app takes and the one
  # verification just proved, so a re-check grades what this pairing actually uses. A
  # loopback target would grade a route neither the app nor this script ever takes,
  # and a front that breaks these requests is exactly what the operator needs to hear
  # about.
  #
  # The compatibility line is UNCONDITIONAL. Gating it on a custom gateway meant that
  # OpenClaw and Hermes users — options 1 and 2, the paths the wizard leads with —
  # finished setup having never learned the check commands exist, and so had nothing
  # to reach for on the day the connection stopped working. Nothing about that grade
  # is custom-only: it asks whether the app's wire protocol survives this route, which
  # is as answerable for OpenClaw as for Ollama.
  say "  Is it still working later? Grade this same route any time:"
  say "    ${BOLD}bash conduck-connect.sh --check-server $GW_URL${RESET}"
  note "Real requests, no configuration changes — it costs a little provider quota."
  # The adapter grade stays custom-gated, because it genuinely does not apply: it
  # holds software written FOR Conduck to Conduck's own rules, and OpenClaw and Hermes
  # are not that. Riding a SUCCESS screen it also needs the outcome named with it — a
  # user who runs the strict grader on generic software gets a FAIL that says nothing
  # about the setup they just proved.
  if [ "$GW_KIND" = "custom" ]; then
    say "  Adapter built for Conduck? Grade that same route against its contract:"
    say "    ${BOLD}bash conduck-connect.sh --check-adapter $GW_URL${RESET}"
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
