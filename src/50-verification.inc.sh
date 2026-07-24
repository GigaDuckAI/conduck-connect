# ---------------------------------------------------------- verification phase --

VERIFY_FAILED=false

check() { # check "label" <command...>  (command's exit code decides)
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; VERIFY_FAILED=true; return 1; fi
}

# curl wrapper: normal TLS validation, EXCEPT self-signed which is verified by
# pinning the SPKI (matching what the app pins) instead of disabling checks.
# The bearer token rides a stdin curl config, never argv (argv shows in `ps`).
curl_gw() { # curl_gw <curl args…>
  local extra=()
  if [ "$TRANSPORT" = "selfsigned" ] && [ -n "$GW_CERT_FP" ]; then
    local b64; b64=$(hex_to_b64 "$GW_CERT_FP")     # pin the QR's fingerprint, not a re-fetch
    [ -n "$b64" ] && extra+=(--insecure --pinnedpubkey "sha256//$b64")
  fi
  # `-q` MUST be curl's first arg. Every connector request ignores curl config,
  # so a stray `proxy`/`output`/redirect/include line there can neither reroute
  # a secret nor make curl read/write files absent from our effects manifest.
  # Diagnostics additionally refuse ALL proxy environment variables because
  # they promise "direct to the server you gave me, nothing else".
  if $DOCTOR || $COMPAT; then extra+=(--noproxy '*'); fi
  # ${extra[@]+…} guard: expanding an empty array under `set -u` is an error in bash 3.2.
  if [ "$GW_AUTH" = "bearer" ]; then
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
MODELS_ID_COUNT=0       # how many entries carried a usable string "id" (doctor: model-selection)
MODELS_FIRST_ID=""      # the first usable id ("" when none) — the doctor's selection probe target

models_is_json() { # 1 arg: base URL — /v1/models must answer success + the canonical envelope
                   #   (JSON object with a top-level "data" ARRAY), not the Control-UI HTML.
                   # Return codes: 0 ok · 1 unreachable/rejected/non-JSON · 2 HTML · 3 wrong shape.
                   # Sets MODELS_CURL_RC / MODELS_HTTP_CODE / MODELS_DATA_EMPTY /
                   # MODELS_NO_VALID_ID / MODELS_TIME either way.
  local out statusline body
  MODELS_CURL_RC=0; MODELS_HTTP_CODE=""; MODELS_DATA_EMPTY=false; MODELS_NO_VALID_ID=false
  MODELS_TIME=""; MODELS_CONTENT_TYPE=""; MODELS_ID_COUNT=0; MODELS_FIRST_ID=""
  out=$(curl_gw -w '\n%{http_code} %{time_total} %{content_type}' \
        -H "Accept: application/json" "$1/v1/models" 2>/dev/null) || { MODELS_CURL_RC=$?; return 1; }
  # The -w line is "<code> <seconds> <content-type>"; the body is everything
  # before that last newline (the `-w` prefix `\n` guarantees the split even for
  # an empty body). Content-Type may itself contain spaces ("…; charset=utf-8"),
  # so it's split off LAST and keeps the remainder verbatim.
  statusline="${out##*$'\n'}"; body="${out%$'\n'*}"
  MODELS_HTTP_CODE="${statusline%% *}"; statusline="${statusline#* }"
  MODELS_TIME="${statusline%% *}"
  MODELS_CONTENT_TYPE=""; [ "$statusline" != "${statusline#* }" ] && MODELS_CONTENT_TYPE="${statusline#* }"
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
  # On the envelope-OK paths the classifier also prints "<id-count>\t<first-id>"
  # for the doctor's model-selection probe; the wizard captures and ignores it.
  local pyout prc
  pyout=$(printf '%s' "$body" | python3 -c '
import json, sys
def bad(x): raise ValueError(x)
try:
    d = json.load(sys.stdin, parse_constant=bad)
except Exception:
    sys.exit(1)
if not (isinstance(d, dict) and isinstance(d.get("data"), list)):
    sys.exit(3)
data = d["data"]
ids = [x["id"] for x in data if isinstance(x, dict) and isinstance(x.get("id"), str) and x["id"]]
first = (ids[0] if ids else "").replace("\t", " ").replace("\n", " ").replace("\r", " ")
print("%d\t%s" % (len(ids), first))
if not data:
    sys.exit(4)
sys.exit(0 if ids else 5)' 2>/dev/null)
  prc=$?
  case "$pyout" in
    *$'\t'*) MODELS_ID_COUNT="${pyout%%$'\t'*}"; MODELS_FIRST_ID="${pyout#*$'\t'}" ;;
  esac
  case "$MODELS_ID_COUNT" in ''|*[!0-9]*) MODELS_ID_COUNT=0 ;; esac
  case "$prc" in
    0) return 0 ;;
    4) MODELS_DATA_EMPTY=true; return 0 ;;
    5) MODELS_NO_VALID_ID=true; return 0 ;;
    *) return "$prc" ;;
  esac
}

# A self-signed-aware curl for the FILE lane (its own pin if set, else gateway's).
# The credential rides a stdin curl config, never argv (argv shows in `ps`).
curl_fs() { # curl_fs <curl args…>
  local extra=()
  if [ "$TRANSPORT" = "selfsigned" ]; then
    local fp="$GW_CERT_FP"; [ -n "$FS_CERT_FP" ] && fp="$FS_CERT_FP"   # file's own pin if it has one
    if [ -n "$fp" ]; then local b64; b64=$(hex_to_b64 "$fp"); [ -n "$b64" ] && extra+=(--insecure --pinnedpubkey "sha256//$b64"); fi
  fi
  local cred="$FS_CRED"; cred="${cred//\\/\\\\}"; cred="${cred//\"/\\\"}"   # curl-config quoting
  printf 'user = "conduck:%s"\n' "$cred" \
    | curl -q -sS --max-time 30 --config - ${extra[@]+"${extra[@]}"} "$@"
}

local_health_ok() { # local_health_ok <url> -> 0 when the server answered with < 500
  local code
  code=$(curl -q -sS --max-time 10 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null) || return 1
  case "$code" in ''|000) return 1 ;; 5??) return 1 ;; *) return 0 ;; esac
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
        90)    why="pinned key mismatch — the server's certificate is not the one this run pinned" ;;
        *)     why="transfer failed (curl exit $MODELS_CURL_RC)" ;;
      esac
    else
      case "$MODELS_HTTP_CODE" in
        401|403) why="HTTP $MODELS_HTTP_CODE — token rejected (or an access layer in front wants a login)" ;;
        3??)     why="HTTP $MODELS_HTTP_CODE redirect — enter the final gateway base URL directly (this tool does not forward credentials across redirects)" ;;
        404)     why="HTTP 404 — nothing at that path (wrong base address?)" ;;
        5??)     why="HTTP $MODELS_HTTP_CODE — the server errored" ;;
        2??)     why="answered HTTP $MODELS_HTTP_CODE, but the body isn't strict JSON" ;;
        *)       why="HTTP $MODELS_HTTP_CODE" ;;
      esac
    fi
    bad "$GW_URL/v1/models failed: $why"
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

  # File lane: PUT → GET → DELETE a throwaway.
  if [ -n "$FS_URL" ] && [ -n "$FS_CRED" ]; then
    local probe="conduck-connect-probe-$$.txt" tmp; tmp=$(mktemp); echo "probe" > "$tmp"
    if curl_fs -T "$tmp" "$FS_URL/$probe" >/dev/null 2>&1 \
       && [ "$(curl_fs "$FS_URL/$probe" 2>/dev/null)" = "probe" ]; then
      if curl_fs -X DELETE "$FS_URL/$probe" >/dev/null 2>&1; then
        ok "file lane: write → read → delete all green"
      else
        ok "file lane: write → read green (delete probe left a stray file: $probe)"
      fi
    elif $SHOW_QR; then
      # --show-code never rewrites the saved profile (write_profile guards on $SHOW_QR),
      # so dropping the lane here only affects THIS emission — the saved lane is untouched.
      bad "the saved profile's file lane failed live verification — a transient outage or a real breakage."
      if confirm "Show a gateway-only code anyway? (your saved profile keeps its file lane)"; then
        curl_fs -X DELETE "$FS_URL/$probe" >/dev/null 2>&1 || true   # the PUT may have landed
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
      drop_file_lane
    fi
    rm -f "$tmp"
  fi
}
