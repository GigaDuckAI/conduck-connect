# -------------------------------------------------------------- --check-server --
#
# App-compatibility probe: does this OpenAI-compatible server speak the core wire
# the current Apple Conduck app needs? It matches request/response acceptance at
# the directly addressed endpoint. It deliberately does not follow redirects:
# forwarding a user credential to a Location target is outside this diagnostic's
# promise, so users must supply the final server URL. This is NOT the
# adapter contract: --check-adapter grades adapters BUILT for Conduck, and generic
# servers fail it on intentional Conduck-specific rules the app itself never
# exercises on the wire (stream:true override, negative-auth enforcement,
# model_not_found status vocabulary). Scoring checks: models envelope (the
# app's probe), chat decode (the app's decoder), advertised-model selection
# (when ids exist), history-image tolerance (the poisoned-chat rule). The
# image-input capability probe INFORMS but never fails — the app can't detect
# a silently-dropped image either. No negative-auth request is ever sent.
# Every verdict describes ONE model path — the operator's
# $CONDUCK_CHECK_SERVER_MODEL, else the first advertised id, else the server's
# model-less default — and the transcript says which, because on a fan-out
# gateway the list order is arbitrary and a per-model capability graded as a
# server property flips the same server between PASS and FAIL.
# Semantic compatibility (client-owned history replay) is INVISIBLE here: a
# stateful server passes this probe and still double-counts context — that
# dimension needs its own test.
COMPAT_RAN=false
COMPAT_CHECKS=0; COMPAT_FAILS=0
COMPAT_MODELS="NOT_RUN"; COMPAT_CHAT="NOT_RUN"; COMPAT_HISTORY_IMAGE="NOT_RUN"
COMPAT_IMAGE_INPUT="NOT_RUN"; COMPAT_MODEL_FIELD="NOT_RUN"

# WHICH model these verdicts describe. A fan-out gateway is one endpoint in
# front of hundreds of upstream models, and /v1/models lists them in an order
# that has nothing to do with capability — so the first advertised id is a
# SAMPLE, and a verdict reached on it is a fact about that route, never a grade
# for the server as a whole. Without this the same server flips PASS↔FAIL purely
# on the order it happens to list its models, which is how a working gateway
# gets told it is broken.
#   $CONDUCK_CHECK_SERVER_MODEL is the operator's override — the ONE public
#   model input; the internal $CONDUCK_CHECK_MODEL/$CONDUCK_PROBE_MODEL names
#   are command-scoped plumbing for handing a value to python without argv, and
#   are deliberately not user knobs.
# COMPAT_MODEL_ID doubles as the pairing answer: a setup handoff must pair
# EXACTLY the model that was proven, and "" (the server_default case) correctly
# means "leave the app's model selection open".
COMPAT_WANTED_MODEL=""   # the operator's $CONDUCK_CHECK_SERVER_MODEL, verbatim
COMPAT_MODEL_ID=""       # the id every model-bearing probe named ("" = none sent)
COMPAT_MODEL_SOURCE="server_default"  # explicit | first_advertised | server_default

c_ok()  { local id="$1"; shift; COMPAT_CHECKS=$((COMPAT_CHECKS+1)); ok "[$id] $*"; }
c_bad() { local id="$1"; shift; COMPAT_CHECKS=$((COMPAT_CHECKS+1)); COMPAT_FAILS=$((COMPAT_FAILS+1)); bad "[$id] $*"; }
c_say() { local id="$1"; shift; say "    [$id] $*"; }

# Grade a chat reply the way the current APP does
# (RemoteAgentClient.decodeReply). This is the single Apple-compatible response
# evaluator used by both normal setup verification and `--check-server`:
# strict JSON (Foundation refuses NaN/Infinity) -> choices must be a non-empty
# array -> EVERY choice must decode as {"message":{"content":"<string>"}} (the
# Swift [Choice] array decodes eagerly, so one malformed later choice
# invalidates the whole reply even when choices[0] is fine) -> the reply is
# choices[0].message.content, and an EMPTY string is a VALID reply. Response
# Content-Type is deliberately NOT checked (the app never reads it) and
# tool_calls/extra fields are tolerated (unknown JSON is ignored). On non-2xx
# the app keys on the error body's "code" field — captured in CCE_WIRE_CODE.
CCE_REASON=""; CCE_LEN=""; CCE_TOKEN=""; CCE_WIRE_CODE=""
app_chat_body_eval() { # app_chat_body_eval <response-body> [expected-digit-code]
  local body="$1" exp="${2:--}" res verdict detail
  CCE_REASON=""; CCE_LEN=""; CCE_TOKEN=""; CCE_WIRE_CODE=""
  case "$body" in data:*)
    CCE_REASON="SSE framing — the app never reads streams, so its JSON decoder fails on this"; return 1 ;;
  esac
  res=$(printf '%s' "$body" | python3 -c '
import json, sys, re
def bad(x): raise ValueError(x)
exp = sys.argv[1] if len(sys.argv) > 1 else "-"
try:
    d = json.load(sys.stdin, parse_constant=bad)
except Exception:
    print("badjson -"); sys.exit(0)
ch = d.get("choices") if isinstance(d, dict) else None
if not isinstance(ch, list) or not ch:
    print("nochoices -"); sys.exit(0)
for c in ch:
    if not (isinstance(c, dict) and isinstance(c.get("message"), dict)
            and isinstance(c["message"].get("content"), str)):
        print("badchoice -"); sys.exit(0)
c = ch[0]["message"]["content"]
if exp != "-":
    print(("token %d" if exp in re.findall(r"\d+", c) else "notoken %d") % len(c)); sys.exit(0)
print("ok %d" % len(c))' "$exp" 2>/dev/null)
  verdict="${res%% *}"; detail="${res#* }"
  case "$verdict" in
    ok)      CCE_LEN="$detail"; return 0 ;;
    token)   CCE_LEN="$detail"; CCE_TOKEN="yes"; return 0 ;;
    notoken) CCE_LEN="$detail"; CCE_TOKEN="no";  return 0 ;;
    badjson)   CCE_REASON="the 2xx body isn't the strict JSON the app's decoder accepts" ;;
    nochoices) CCE_REASON="no usable \"choices\" array (the app reads choices[0].message.content)" ;;
    badchoice) CCE_REASON="a choice doesn't decode as {\"message\":{\"content\":\"<string>\"}} — the app rejects the whole reply" ;;
    *)         CCE_REASON="could not grade the reply" ;;
  esac
  return 1
}

app_chat_loaded_eval() { # app_chat_loaded_eval [expected-digit-code] — grades current DCC_*
  local exp="${1:--}"
  case "$DCC_CODE" in
    2??) ;;
    3??)
      CCE_REASON="HTTP $DCC_CODE redirect — use the final server URL directly (this check does not forward credentials across redirects)"
      return 1
      ;;
    *)
      # error.code is a JSON string the server fully controls, and it is quoted
      # straight into CCE_REASON, which every failure verdict prints. A literal
      # newline in it forges a second "[CHECK_ID] …" line — a hostile gateway
      # writing its own green PASS into the transcript — and an ANSI escape
      # rewrites what the operator sees. C0/DEL out here at the parser; the
      # 64-char cap it already had stays.
      CCE_WIRE_CODE=$(printf '%s' "$DCC_BODY" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
e = d.get("error") if isinstance(d, dict) else None
c = e.get("code") if isinstance(e, dict) else None
if isinstance(c, str) and c:
    print("".join(ch for ch in c if ord(ch) >= 0x20 and ord(ch) != 0x7f)[:64])' 2>/dev/null)
      CCE_REASON="HTTP ${DCC_CODE:-?}${CCE_WIRE_CODE:+ (wire code \"$CCE_WIRE_CODE\")}"
      return 1
      ;;
  esac
  app_chat_body_eval "$DCC_BODY" "$exp"
}

app_chat_eval() { # app_chat_eval <payload-json> [expected-digit-code]
  local exp="${2:--}"
  CCE_REASON=""; CCE_LEN=""; CCE_TOKEN=""; CCE_WIRE_CODE=""
  if ! doctor_chat_request "$1"; then
    # "timed out or the connection dropped" makes the operator guess between a
    # dead host, a refused port, a TLS failure and a slow agent. curl already
    # knows which; doctor_chat_request leaves its exit code in DCC_CURL_RC.
    CCE_REASON=$(doctor_transfer_reason "$DCC_CURL_RC"); return 1
  fi
  app_chat_loaded_eval "$exp"
}

# The app's vision-decline classifier, mirrored: a structured code
# "image_unsupported" at any error status; ANY 413 on an image turn (the app
# maps it to image-too-large unconditionally); or — gated to 400/404 — the
# app's four vision regexes applied to error.message when the OpenAI envelope
# is present (the app deliberately scopes there to dodge metadata false
# matches), else to the whole body.
compat_image_declined_detectable() {
  [ "$CCE_WIRE_CODE" = "image_unsupported" ] && return 0
  [ "$DCC_CODE" = "413" ] && return 0
  case "$DCC_CODE" in 400|404) ;; *) return 1 ;; esac
  compat_image_message_matches
}

# Why did an image-bearing turn fail? The classifier above answers "would the app
# recognize this refusal", which is the right question for the capability probe
# and the wrong one for a history-image failure: it folds EVERY 413 into
# "declined", and 413 means the payload was too big, not that the engine is
# text-only. The two need different advice, so they get separated here.
compat_image_failure_kind() { # -> image_unsupported | too_large | other
  if [ "$CCE_WIRE_CODE" = "image_unsupported" ]; then printf 'image_unsupported\n'; return 0; fi
  if [ "$DCC_CODE" = "413" ]; then printf 'too_large\n'; return 0; fi
  case "$DCC_CODE" in
    400|404) compat_image_message_matches && { printf 'image_unsupported\n'; return 0; } ;;
  esac
  printf 'other\n'
}

# The app's four vision regexes, applied to error.message when the OpenAI
# envelope is present (the app deliberately scopes there to dodge metadata false
# matches), else to the whole body. Callers own the status gating.
compat_image_message_matches() {
  printf '%s' "$DCC_BODY" | python3 -c '
import json, sys, re
body = sys.stdin.read()
text = body
try:
    d = json.loads(body)
    e = d.get("error") if isinstance(d, dict) else None
    m = e.get("message") if isinstance(e, dict) else None
    if isinstance(m, str) and m:
        text = m
except Exception:
    pass
pats = (r"support.*image", r"image.*input", r"unsupported.*content", r"image.*not.*support")
sys.exit(0 if any(re.search(p, text, re.I | re.S) for p in pats) else 1)' 2>/dev/null
}

compat_summary() { # compat_summary <exit-code>
  local rc="${1:-1}" wire="NOT_RUN"
  if $COMPAT_RAN; then
    wire="PASS"; [ "$COMPAT_FAILS" -gt 0 ] && wire="FAIL"
  fi
  printf 'CONDUCK_CHECK_SERVER schema=2 harness=%s wire=%s models=%s chat=%s history_image=%s image_input=%s model=%s model_ids=%s auth=%s checks=%s failed=%s exit=%s\n' \
    "$VERSION" "$wire" "$COMPAT_MODELS" "$COMPAT_CHAT" "$COMPAT_HISTORY_IMAGE" \
    "$COMPAT_IMAGE_INPUT" "$COMPAT_MODEL_FIELD" "${MODELS_ID_COUNT:-0}" \
    "${GW_AUTH:-NOT_RUN}" "$COMPAT_CHECKS" "$COMPAT_FAILS" "$rc"
}

compat_on_exit() {
  local rc=$?
  on_exit
  compat_summary "$rc"
}

run_compat() {
  trap compat_on_exit EXIT
  trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
  # Arm the machine contract before runtime dependency checks. This guarantees
  # missing curl/python3 exits 1 with the summary as the final line.
  preflight

  say "${BOLD}conduck-connect $VERSION — --check-server${RESET}"
  say "Asks ONE question: does this OpenAI-compatible server speak the core wire the"
  say "current Apple Conduck app needs? It changes no host configuration. It sends live"
  say "model/chat/image requests that may consume compute or enter server-side history."
  say "The check matches the app's request/response acceptance at the directly addressed"
  say "endpoint. It does not follow redirects or forward credentials to Location targets;"
  say "use the final server URL directly. This is NOT the adapter contract:"
  say "${BOLD}--check-adapter${RESET} grades adapters built FOR Conduck,"
  say "and generic servers fail it on rules the app never exercises. A pass here does NOT"
  say "make this server a Conduck adapter."
  if interactive_terminal; then
    note "A CONDUCK_CHECK_SERVER machine summary prints before the optional setup handoff."
  else
    note "The last line is always a CONDUCK_CHECK_SERVER machine summary — scripts key on it."
  fi
  note "What this can't see: a server that keeps its OWN chat history will pass and still"
  note "double-count context — Conduck resends the full history every turn (client-owned)."
  note "This grades ONE model path. Set CONDUCK_CHECK_SERVER_MODEL=<id> to grade the model"
  note "you actually plan to use — otherwise a multi-model server is judged on one sample."

  if [ -n "$CHECK_URL" ]; then
    GW_URL=$(doctor_accept_url "$CHECK_URL") \
      || usage_die "Can't test '$CHECK_URL' — use https://… (or http://127.0.0.1:<port> for a local test)."
  else
    say ""
    GW_URL=$(doctor_ask_url) || die "$NO_ANSWER"
  fi
  apply_gateway_url_normalization

  # Token: bearer from $CONDUCK_TOKEN / prompt; a deliberate empty answer means
  # keyless — the app's explicit .none auth scheme (never inferred, and this
  # probe sends NO negative-auth requests either way).
  # CONDUCK_TOKEN set-but-empty is an EXPLICIT keyless declaration for scripted
  # runs; unset means "ask". Never infer keyless from absence.
  if [ -n "${CONDUCK_TOKEN+set}" ] && [ -z "$CONDUCK_TOKEN" ]; then
    GW_AUTH="none"; GW_TOKEN=""
    note "Keyless by explicit \$CONDUCK_TOKEN= — mirroring the app's no-auth scheme."
  elif [ -n "${CONDUCK_TOKEN:-}" ]; then
    GW_AUTH="bearer"; GW_TOKEN="$CONDUCK_TOKEN"
    note "Using the bearer token from \$CONDUCK_TOKEN."
  else
    say ""
    note "Tip: export CONDUCK_TOKEN=<token> to skip this prompt on re-runs."
    GW_TOKEN=$(ask_secret "Bearer token the server expects (Enter for keyless — the app's explicit no-auth mode)") \
      || die "No token given and no answer possible (the input ended). Set CONDUCK_TOKEN=<token> for a scripted run, or set CONDUCK_TOKEN= (empty) to declare keyless deliberately."
    if [ -n "$GW_TOKEN" ]; then GW_AUTH="bearer"; else
      GW_AUTH="none"
      note "Keyless: mirroring the app's explicit no-auth scheme — sensible only on an isolated network."
    fi
  fi
  TRANSPORT=""

  # Snapshot the operator's model choice ONCE, before any request: the graded
  # model must never change mid-run, or the verdicts stop describing a single
  # path and the optional setup handoff can no longer pair what was proven.
  COMPAT_WANTED_MODEL="${CONDUCK_CHECK_SERVER_MODEL:-}"

  head_ "Server check — $GW_URL"
  COMPAT_RAN=true

  # -- models: direct-endpoint acceptance from Test Connection ----------------
  local rc=0 secs over
  models_is_json "$GW_URL" "$COMPAT_WANTED_MODEL" || rc=$?
  secs=$(printf '%s' "${MODELS_TIME:-0}" | awk '{printf "%.1f", $1+0}' 2>/dev/null); [ -n "$secs" ] || secs="?"
  over=$(printf '%s' "${MODELS_TIME:-0}" | awk '{print ($1+0 > 15) ? 1 : 0}' 2>/dev/null)
  if [ "$rc" = "0" ] && [ "$over" != "1" ]; then
    COMPAT_MODELS="PASS"
    c_ok SERVER_MODELS "GET /v1/models — the app's Test Connection passes (${secs}s)"
    # Content-Type is NOT graded: the app parses the bytes and never reads the
    # header (this is a deliberate divergence from the adapter contract).
    if $MODELS_DATA_EMPTY; then
      c_say SERVER_MODELS "(\"data\" is empty — the app reports \"connected, no models yet\"; chat needs the"
      c_say SERVER_MODELS " server to answer without a model field)"
    elif $MODELS_NO_VALID_ID; then
      c_say SERVER_MODELS "(entries carry no usable \"id\" string — the app can't offer a model picker;"
      c_say SERVER_MODELS " fine as long as the server answers without a model field)"
    fi
  else
    COMPAT_MODELS="FAIL"
    if [ "$rc" = "0" ]; then
      c_bad SERVER_MODELS "GET /v1/models — answered, but took ${secs}s (the app's Test Connection gives up at 15s)"
    elif [ "$rc" = "2" ]; then
      c_bad SERVER_MODELS "GET /v1/models — an HTML page (HTTP ${MODELS_HTTP_CODE:-?}), not JSON"
      c_say SERVER_MODELS "(something else answered — a login page, a reverse proxy, or a wrong base address)"
    elif [ "$rc" = "3" ]; then
      c_bad SERVER_MODELS "GET /v1/models — answers, but not the shape the app requires"
      c_say SERVER_MODELS "(the app needs a JSON OBJECT whose top-level \"data\" is an ARRAY — a bare array or"
      c_say SERVER_MODELS " {\"models\": …} fails its Test Connection; some servers have a separate OpenAI-compatible"
      c_say SERVER_MODELS " path that answers correctly — point the app at THAT base URL)"
    else
      local why=""
      if [ "${MODELS_CURL_RC:-0}" != "0" ]; then
        case "$MODELS_CURL_RC" in
          6)  why="DNS lookup failed — that hostname doesn't resolve" ;;
          7)  why="connection refused — nothing is listening there (wrong port? not started?)" ;;
          28) why="timed out — no answer from the host" ;;
          35|60) why="TLS problem — the app requires a certificate this machine would trust too" ;;
          *)  why="transfer failed (curl exit $MODELS_CURL_RC)" ;;
        esac
      else
        case "$MODELS_HTTP_CODE" in
          401|403) if [ "${GW_AUTH:-}" = "none" ]; then
                     why="HTTP $MODELS_HTTP_CODE and no credential was sent — this run is keyless, so the server wants auth you didn't supply (set CONDUCK_TOKEN=<token>)"
                   else
                     why="HTTP $MODELS_HTTP_CODE with the credential you gave me — the app would fail the same way"
                   fi ;;
          3??)     why="HTTP $MODELS_HTTP_CODE redirect — use the final server URL directly (this check does not forward credentials across redirects)" ;;
          404)     why="HTTP 404 — nothing at that path (wrong base address?)" ;;
          5??)     why="HTTP $MODELS_HTTP_CODE — the server errored" ;;
          2??)     why="answered HTTP $MODELS_HTTP_CODE, but the body isn't strict JSON (the app's decoder refuses NaN/Infinity too)" ;;
          *)       why="HTTP ${MODELS_HTTP_CODE:-?}" ;;
        esac
      fi
      c_bad SERVER_MODELS "GET /v1/models — $why"
    fi
    say ""
    bad "Server check: FAIL — the app's Test Connection fails here, so nothing else can work."
    say "  Fix that first, then re-run me. Testing an adapter you BUILT? Use ${BOLD}--check-adapter${RESET}."
    exit 1
  fi

  # An explicit model choice is announced BEFORE the first chat turn, so the
  # verdicts below are read against the right target — and so a typo'd id is
  # visible as the cause of the failures it is about to produce, rather than
  # being discovered several red lines later.
  if [ -n "$COMPAT_WANTED_MODEL" ]; then
    say ""
    note "Grading the model you named: '$(safe_display "$COMPAT_WANTED_MODEL" 60)'."
    if ! $MODELS_WANTED_FOUND; then
      if [ "${MODELS_ID_COUNT:-0}" = "0" ]; then
        note "(this server advertises no model ids at all — naming one is the only way to test it)"
      else
        note "(that id is NOT among the $MODELS_ID_COUNT this server advertises — check the spelling;"
        note " grading it anyway, as you asked)"
      fi
    fi
  fi

  say ""
  say "  Now the chat turns — graded with the app's actual decoder (empty-string replies are"
  say "  VALID, extra fields like tool_calls are tolerated, Content-Type is never read). Agents"
  say "  can be slow; I wait up to 5 minutes per turn…"

  # -- chat, the app's default shape: model OMITTED (dedicated + fresh custom) --
  local payload_a payload_b="" a_ok=false a_reason="" a_code="" b_ok="" b_reason=""
  payload_a=$(python3 -c 'import json
print(json.dumps({"messages": [{"role": "user", "content": "Reply with exactly: pong"}],
                  "stream": False}))') \
    || die "Could not build the test request (python3 failed)."
  if app_chat_eval "$payload_a"; then a_ok=true; else a_reason="$CCE_REASON"; a_code="$DCC_CODE"; fi

  # One turn WITH a NAMED model: the app sends the model the user picked from
  # THIS server's /v1/models, so named selection must work too. Also the rescue
  # path for servers that REQUIRE the field. The operator's explicit choice wins
  # over the first advertised id — on a fan-out gateway the first id is only a
  # sample of the roster, and grading it as though it spoke for the server is
  # what turns a working setup into a FAIL.
  local named_model="$COMPAT_WANTED_MODEL"
  [ -n "$named_model" ] || named_model="$MODELS_FIRST_ID"
  if [ -n "$named_model" ]; then
    payload_b=$(CONDUCK_CHECK_MODEL="$named_model" python3 -c 'import json, os
print(json.dumps({"messages": [{"role": "user", "content": "Reply with exactly: pong"}],
                  "model": os.environ["CONDUCK_CHECK_MODEL"], "stream": False}))') \
      || die "Could not build the test request (python3 failed)."
    if app_chat_eval "$payload_b"; then b_ok=true; else b_ok=false; b_reason="$CCE_REASON"; fi
  fi

  if $a_ok; then
    COMPAT_CHAT="PASS"; COMPAT_MODEL_FIELD="optional"
    c_ok SERVER_CHAT "chat without a \"model\" field — decoded by the app's rules (${CCE_LEN:-?} chars)"
  elif [ "$b_ok" = "true" ]; then
    # Only the statuses the app's own model-required heuristics accept
    # (400/404/413/422) may be read as "needs a model" — a transient 429/5xx
    # that happened to clear by the second turn must not claim that.
    case "$a_code" in
      400|404|413|422)
        COMPAT_CHAT="PASS"; COMPAT_MODEL_FIELD="required"
        c_ok SERVER_CHAT "chat works once a model is set — this server REQUIRES the \"model\" field"
        c_say SERVER_CHAT "(without one it answered: $a_reason. In the app, pick a model in the gateway's"
        c_say SERVER_CHAT " settings — a model-less request only happens when none is configured)" ;;
      *)
        COMPAT_CHAT="FAIL"; COMPAT_MODEL_FIELD="required"
        c_bad SERVER_CHAT "chat without a \"model\" field — $a_reason"
        c_say SERVER_CHAT "(the model-named turn worked, but this failure isn't the missing-model kind —"
        c_say SERVER_CHAT " something else is wrong; the app would hit it too)" ;;
    esac
  else
    COMPAT_CHAT="FAIL"
    [ "$COMPAT_MODEL_FIELD" = "NOT_RUN" ] && [ -z "$MODELS_FIRST_ID" ] && COMPAT_MODEL_FIELD="none_advertised"
    c_bad SERVER_CHAT "chat — $a_reason"
    case "$a_code" in
      401|403) c_say SERVER_CHAT "(auth works on /v1/models but not on chat — two different credential checks?)" ;;
    esac
  fi

  # -- named selection as its own verdict (when a model id exists) -------------
  if [ -n "$named_model" ]; then
    local named_what="the first advertised model id"
    [ -n "$COMPAT_WANTED_MODEL" ] && named_what="the model you named"
    if [ "$b_ok" = "true" ]; then
      c_ok SERVER_MODEL_SELECT "$named_what selects (the app sends what the user picked)"
    else
      c_bad SERVER_MODEL_SELECT "a request naming $named_what fails — $b_reason"
      if [ -n "$COMPAT_WANTED_MODEL" ] && ! $MODELS_WANTED_FOUND; then
        # Don't blame the server's picker for an id the server never offered.
        c_say SERVER_MODEL_SELECT "(that id isn't in this server's /v1/models list, so this may just be a typo —"
        c_say SERVER_MODEL_SELECT " unset CONDUCK_CHECK_SERVER_MODEL to grade the first id the server advertises)"
      else
        c_say SERVER_MODEL_SELECT "(the app's model picker is fed from YOUR /v1/models — a listed id that can't"
        c_say SERVER_MODEL_SELECT " be used breaks every user who picks it)"
      fi
    fi
  fi

  # -- which model the remaining probes grade, said out loud ------------------
  # An explicit choice always wins. Otherwise: once the server is known to
  # REQUIRE a model, every later probe carries the advertised id — the app sends
  # the user's configured model on EVERY turn, so a model-less later probe would
  # fail a server real app traffic works on. A server that accepts a model-less
  # request keeps getting model-less probes, which grade its DEFAULT route.
  local probe_model=""
  if [ -n "$COMPAT_WANTED_MODEL" ]; then
    probe_model="$COMPAT_WANTED_MODEL"; COMPAT_MODEL_SOURCE="explicit"
  elif [ "$COMPAT_MODEL_FIELD" = "required" ]; then
    probe_model="$MODELS_FIRST_ID"; COMPAT_MODEL_SOURCE="first_advertised"
  else
    COMPAT_MODEL_SOURCE="server_default"
  fi
  COMPAT_MODEL_ID="$probe_model"
  # The explicit case already announced itself before the first chat turn.
  case "$COMPAT_MODEL_SOURCE" in
    explicit) ;;
    *) say "" ;;
  esac
  case "$COMPAT_MODEL_SOURCE" in
    explicit) ;;
    first_advertised)
      if [ "${MODELS_ID_COUNT:-0}" -gt 1 ] 2>/dev/null; then
        note "Grading model '$(safe_display "$COMPAT_MODEL_ID" 60)' — the FIRST of $MODELS_ID_COUNT ids this server"
        note "advertises, picked by ITS list order, not by capability. The rest are untested, so a"
        note "failure below is a fact about THIS model's route, not a grade for the whole server."
        note "Re-run with CONDUCK_CHECK_SERVER_MODEL=<id> to grade the model you plan to use."
      else
        note "Grading model '$(safe_display "$COMPAT_MODEL_ID" 60)' — the only id this server advertises."
      fi
      ;;
    *)
      note "The probes below send NO \"model\" field, so they grade whatever this server routes to"
      note "by default — and nothing here proves two model-less requests reach the same model."
      ;;
  esac

  # -- history image: the poisoned-chat rule (a REAL app requirement) ----------
  local payload_h
  payload_h=$(CONDUCK_PROBE_MODEL="$probe_model" python3 -c 'import json, os, zlib, struct, base64
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 0, 0, 0, 0)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(b"\x00\xff")) + chunk(b"IEND", b"")
uri = "data:image/png;base64," + base64.b64encode(png).decode()
req = {"messages": [
    {"role": "user", "content": [
        {"type": "text", "text": "What is in this photo?"},
        {"type": "image_url", "image_url": {"url": uri}}]},
    {"role": "user", "content": "Reply with exactly: pong"}], "stream": False}
m = os.environ.get("CONDUCK_PROBE_MODEL", "")
if m:
    req["model"] = m
print(json.dumps(req))') \
    || die "Could not build the history-image test request (python3 failed)."
  if app_chat_eval "$payload_h"; then
    COMPAT_HISTORY_IMAGE="PASS"
    c_ok SERVER_HISTORY_IMAGE "an image in an EARLIER message doesn't break a text-only turn (${CCE_LEN:-?} chars)"
  else
    COMPAT_HISTORY_IMAGE="FAIL"
    c_bad SERVER_HISTORY_IMAGE "history image — $CCE_REASON"
    c_say SERVER_HISTORY_IMAGE "(Conduck resends the full history, so ONE photo anywhere in a conversation would"
    c_say SERVER_HISTORY_IMAGE " permanently break every later turn of that chat — on the route just graded)"
    # Name WHY, from the server's own answer, while DCC_*/CCE_* still hold it.
    # This explains the failure; it never excuses it. A route that cannot read
    # images is still required to drop or describe an OLD one and answer the new
    # text turn, so this stays a real FAIL either way.
    case "$(compat_image_failure_kind)" in
      image_unsupported)
        c_say SERVER_HISTORY_IMAGE "The server says this engine can't read images at all. That still fails: a route"
        c_say SERVER_HISTORY_IMAGE "that can't see pictures is expected to ignore an OLD one and answer the new text." ;;
      too_large)
        c_say SERVER_HISTORY_IMAGE "HTTP 413 on a 1×1 PNG points at a request-size limit in front of the server, not"
        c_say SERVER_HISTORY_IMAGE "at the engine — check the reverse proxy's max body size." ;;
    esac
    if [ "$COMPAT_MODEL_SOURCE" = "first_advertised" ] && [ "${MODELS_ID_COUNT:-0}" -gt 1 ] 2>/dev/null; then
      c_say SERVER_HISTORY_IMAGE "Only '$(safe_display "$COMPAT_MODEL_ID" 60)' was tested — the first of $MODELS_ID_COUNT advertised ids."
      c_say SERVER_HISTORY_IMAGE "Before judging the server, re-run with CONDUCK_CHECK_SERVER_MODEL=<id> on another."
    fi
  fi

  # -- image input: capability, informational — never fails the wire verdict ---
  say ""
  say "  Last, the image capability probe (informational — the app can't detect a silently"
  say "  dropped image either, so this never changes the verdict)…"
  CONDUCK_PROBE_MODEL="$probe_model" image_probe_gen
  if app_chat_eval "$IPG_PAYLOAD" "$IPG_CODE"; then
    if [ "$CCE_TOKEN" = "yes" ]; then
      COMPAT_IMAGE_INPUT="VERIFIED"
      say "  ${GREEN}•${RESET} image input: VERIFIED — the reply reads the probe image's digits back (${DCC_TIME:-?}s)"
    else
      COMPAT_IMAGE_INPUT="IGNORED"
      warn "image input: IGNORED — answered 200 while ignoring the image. In the app, photos"
      say "    are silently unseen: users get confident answers about images the engine never saw."
    fi
  elif compat_image_declined_detectable; then
    COMPAT_IMAGE_INPUT="DECLINED"
    say "  ${GREEN}•${RESET} image input: DECLINED, detectably — the app recognizes this refusal and shows its"
    if [ "$COMPAT_HISTORY_IMAGE" = "FAIL" ]; then
      # "text chats are unaffected" is the normal case and a lie here: this route
      # already failed the history-image turn, so a photo poisons the whole chat.
      say "    pictures-unsupported message — but see the history-image failure above: on this"
      say "    route a photo also breaks the TEXT turns that follow it in the same chat."
    else
      say "    pictures-unsupported message (text chats are unaffected)"
    fi
  else
    COMPAT_IMAGE_INPUT="OPAQUE"
    warn "image input: image turns fail with an error the app can't classify ($CCE_REASON) —"
    say "    users see a generic failure instead of \"pictures aren't supported here\""
  fi

  # One line naming the graded path, on BOTH verdicts. A PASS that reads as a
  # blanket certificate and a FAIL that reads as a blanket condemnation are the
  # same bug: neither run tested more than one model.
  local graded_scope=""
  case "$COMPAT_MODEL_SOURCE" in
    explicit)         graded_scope="model '$(safe_display "$COMPAT_MODEL_ID" 60)' (the one you named)" ;;
    first_advertised) graded_scope="model '$(safe_display "$COMPAT_MODEL_ID" 60)'"
                      [ "${MODELS_ID_COUNT:-0}" -gt 1 ] 2>/dev/null \
                        && graded_scope="$graded_scope — the first of $MODELS_ID_COUNT advertised, and the only one tested" ;;
    *)                graded_scope="this server's default route (no \"model\" field was sent)" ;;
  esac

  say ""
  if [ "$COMPAT_FAILS" = "0" ]; then
    ok "Server check: PASS — core text-chat compatibility is green ($COMPAT_CHECKS/$COMPAT_CHECKS wire checks)."
    say "  Image input is separate and informational: ${BOLD}$COMPAT_IMAGE_INPUT${RESET}."
    say "  Graded: $graded_scope."
    say "  Three honest limits: this probe can't see STATEFULNESS (a server that keeps its own"
    say "  history will double-count context — Conduck resends the full history every turn),"
    say "  it grades ONE model path and says nothing about any other model this server offers,"
    say "  and a pass here does NOT make this server a Conduck adapter (that's ${BOLD}--check-adapter${RESET})."
    if [ "$COMPAT_MODEL_SOURCE" = "explicit" ]; then
      # The setup handoff pairs $COMPAT_MODEL_ID — the model this run actually
      # graded — so a deliberately-graded model is the one that gets carried.
      note "Continuing into setup? The pairing code carries the model you named here."
    fi
    if ! interactive_terminal; then
      say "  To set it up later:  ${BOLD}bash conduck-connect.sh --setup${RESET}"
    fi
    return 0
  fi
  bad "Server check: FAIL — $COMPAT_FAILS of $COMPAT_CHECKS wire checks failed."
  say "  The app would hit the same walls on $graded_scope."
  if [ "$COMPAT_MODEL_SOURCE" = "first_advertised" ] && [ "${MODELS_ID_COUNT:-0}" -gt 1 ] 2>/dev/null; then
    say "  That is not yet a verdict on the server: CONDUCK_CHECK_SERVER_MODEL=<id> grades another."
  fi
  say "  Building your own adapter instead? ${BOLD}--check-adapter${RESET} grades that:"
  say "  ${BOLD}https://conduck.com/setup/adapter/v1/${RESET}"
  exit 1
}
