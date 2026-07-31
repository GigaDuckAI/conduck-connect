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
    if confirm "Show a gateway-only code anyway? (your saved profile keeps its file lane)" "verification.gateway_only"; then
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
      elif confirm "Show a gateway-only code anyway? (your saved profile keeps its file lane)" "verification.gateway_only"; then
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
