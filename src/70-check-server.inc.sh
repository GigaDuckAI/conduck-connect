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
# Semantic compatibility (client-owned history replay) is INVISIBLE here: a
# stateful server passes this probe and still double-counts context — that
# dimension needs its own test.
COMPAT_RAN=false
COMPAT_CHECKS=0; COMPAT_FAILS=0
COMPAT_MODELS="NOT_RUN"; COMPAT_CHAT="NOT_RUN"; COMPAT_HISTORY_IMAGE="NOT_RUN"
COMPAT_IMAGE_INPUT="NOT_RUN"; COMPAT_MODEL_FIELD="NOT_RUN"

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
      CCE_WIRE_CODE=$(printf '%s' "$DCC_BODY" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
e = d.get("error") if isinstance(d, dict) else None
c = e.get("code") if isinstance(e, dict) else None
if isinstance(c, str) and c:
    print(c[:64])' 2>/dev/null)
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
    CCE_REASON="transfer failed (timed out or the connection dropped)"; return 1
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
  TRANSPORT=""; GW_CERT_FP=""

  head_ "Server check — $GW_URL"
  COMPAT_RAN=true

  # -- models: direct-endpoint acceptance from Test Connection ----------------
  local rc=0 secs over
  models_is_json "$GW_URL" || rc=$?
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

  # One turn WITH the first advertised id (when one exists): the app sends the
  # model the user picked from THIS server's /v1/models, so named selection
  # must work too. Also the rescue path for servers that REQUIRE the field.
  if [ -n "$MODELS_FIRST_ID" ]; then
    payload_b=$(CONDUCK_CHECK_MODEL="$MODELS_FIRST_ID" python3 -c 'import json, os
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
  if [ -n "$MODELS_FIRST_ID" ]; then
    if [ "$b_ok" = "true" ]; then
      c_ok SERVER_MODEL_SELECT "the first advertised model id selects (the app sends what the user picked)"
    else
      c_bad SERVER_MODEL_SELECT "a request naming the first advertised id fails — $b_reason"
      c_say SERVER_MODEL_SELECT "(the app's model picker is fed from YOUR /v1/models — a listed id that can't"
      c_say SERVER_MODEL_SELECT " be used breaks every user who picks it)"
    fi
  fi

  # -- history image: the poisoned-chat rule (a REAL app requirement) ----------
  # Once the server is known to REQUIRE a model, every later probe carries the
  # advertised id — the app sends the user's configured model on EVERY turn,
  # so a model-less later probe would fail a server real app traffic works on.
  local probe_model=""
  [ "$COMPAT_MODEL_FIELD" = "required" ] && probe_model="$MODELS_FIRST_ID"
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
    c_say SERVER_HISTORY_IMAGE " permanently break every later turn of that chat in the app)"
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
    say "    pictures-unsupported message (text chats are unaffected)"
  else
    COMPAT_IMAGE_INPUT="OPAQUE"
    warn "image input: image turns fail with an error the app can't classify ($CCE_REASON) —"
    say "    users see a generic failure instead of \"pictures aren't supported here\""
  fi

  say ""
  if [ "$COMPAT_FAILS" = "0" ]; then
    ok "Server check: PASS — core text-chat compatibility is green ($COMPAT_CHECKS/$COMPAT_CHECKS wire checks)."
    say "  Image input is separate and informational: ${BOLD}$COMPAT_IMAGE_INPUT${RESET}."
    say "  Two honest limits: this probe can't see STATEFULNESS (a server that keeps its own"
    say "  history will double-count context — Conduck resends the full history every turn),"
    say "  and a pass here does NOT make this server a Conduck adapter (that's ${BOLD}--check-adapter${RESET})."
    if ! interactive_terminal; then
      say "  To set it up later:  ${BOLD}bash conduck-connect.sh --setup${RESET}"
    fi
    return 0
  fi
  bad "Server check: FAIL — $COMPAT_FAILS of $COMPAT_CHECKS wire checks failed."
  say "  The app would hit the same walls. Building your own adapter instead? ${BOLD}--check-adapter${RESET} grades that:"
  say "  ${BOLD}https://conduck.com/setup/adapter/v1/${RESET}"
  exit 1
}
