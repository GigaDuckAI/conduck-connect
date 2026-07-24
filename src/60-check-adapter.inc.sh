# ------------------------------------------------------------- check-adapter --
#
# --check-adapter: a black-box check of an adapter built for Conduck against the
# rules at conduck.com/setup/adapter/v1/ (contract revision 1.3). Built for
# people whose adapter was written for Conduck — by hand or by an AI coding
# tool — around Claude Code, an agent framework, anything. It sends real
# requests and grades the answers strictly; it never touches configs, saved
# state, or the QR flow. (It will run against any OpenAI-compatible server,
# but grading OpenClaw/Hermes with it invites false FAILs — they legitimately
# do things the adapter rules forbid, e.g. keyless mode.)
#
# Why it exists next to verify_all: the wizard's verify step proves the HAPPY
# path (right token, clean request). The adapter check also proves what verify can't
# without pretending to be an attacker or a sloppy client — that auth is
# actually ENFORCED (a missing or wrong token must 401; the adapter that
# forgot its token check passes verify and gets a green QR while sitting wide
# open with tool access), that an ABSENT "model" field is tolerated, that
# unknown request fields are ignored, that a supplied model id really selects
# (or answers 400 + code "model_not_found"), that an image in an EARLIER
# message can never poison the chat (forward it or replace it with the
# contract's disclosure — never reject; one bad photo must not kill every
# later turn), and that "stream": true still gets ONE synchronous JSON answer.
# --deep adds the semantic image probe: a locally generated PNG showing 4
# random digits (never named in the prompt or metadata) rides the newest
# message — a reply carrying those digits proves the engine truly SAW the
# image (VERIFIED); an honest HTTP 400 decline with code "image_unsupported"
# also passes (DECLINED); a 200 that ignores the image is the forbidden
# silent drop (UNVERIFIED → exit 1).
#
# --files adds the file-lane probes (MUTATING — the one adapter-check profile that
# is: it writes + removes small conduck-check-* files in the configured
# shared folder, and asks the selected agent to copy one). Three meters,
# graded independently: file_transport (this host's WebDAV <-> disk lane),
# file_access (the selected engine can read/write the shared folder and
# names its output detectably), file_e2e (the combined output-delivery path,
# probed exactly the way the app probes it). It does NOT prove public
# exposure or remote-device reachability — the wizard verifies the
# app-facing lane during setup; the plain adapter check proves conformance.
#
# Output contract: every check verdict line carries a stable [CHECK_ID], and
# the LAST line on every exit — pass, fail, or an early die — is the machine
# summary, schema=3 (fixed field order, ASCII enums, no ANSI):
#   CONDUCK_CHECK_ADAPTER schema=3 contract=v1 revision=1.3 harness=<ver>
#     profile=<basic|deep> core=<PASS|FAIL|NOT_RUN> history_image=<…>
#     stream=<…> image_input=<VERIFIED|DECLINED|UNVERIFIED|FAIL|NOT_RUN>
#     file_transport=<…> file_access=<…> file_e2e=<…>
#     checks=<n> failed=<n> exit=<n>
# The three file meters share one enum: NOT_REQUESTED (no --files) |
# NOT_RUN (requested, but a prerequisite stopped this tier) | PASS | FAIL |
# ERROR (unsafe config, harness failure, or unproven cleanup). Scripts key
# on that line + the exit code, NEVER on check counts (they change between
# harness versions). Any grammar change bumps schema=. File checks never
# flip core= — the file lane is an optional profile outside the core wire
# contract — but their failures still count in failed= and force exit 1.
#
# Deliberately NOT here (they need a harness inside the adapter process, not
# HTTP probes — they belong in an adapter's own tests): the 285-second
# cancellation kill, concurrency/queue behaviour, and session or permission
# internals.
#
# Exit code: 0 = every check green, 1 = runtime/preflight/check failure,
# 2 = command-line usage error. Loop it from a shell while iterating.
# This repo's tests prove every check fails for its intended reason.

DOCTOR_CHECKS=0
DOCTOR_FAILS=0
DOCTOR_CONTRACT_REV="1.3"
# Machine-summary state. "Core" = every check except the deep image probe:
# IMAGE_INPUT failing still exits 1, but must never flip core=FAIL — it grades
# an optional capability's honesty, not the core wire contract.
DOCTOR_PROFILE="basic"
DOCTOR_CORE_RAN=false
DOCTOR_CORE_FAILS=0
DOCTOR_HISTORY_IMAGE="NOT_RUN"
DOCTOR_STREAM="NOT_RUN"
DOCTOR_IMAGE_INPUT="NOT_RUN"
# The three --files meters (NOT_REQUESTED until --files flips them to NOT_RUN
# at doctor start; the file tiers then grade each independently).
DOCTOR_FILE_TRANSPORT="NOT_REQUESTED"
DOCTOR_FILE_ACCESS="NOT_REQUESTED"
DOCTOR_FILE_E2E="NOT_REQUESTED"

d_core_mark() { # d_core_mark <check-id> <pass|fail> — feed the core= rollup
  # IMAGE_INPUT grades an optional capability's honesty; FILES_*/FILE_* grade
  # the optional file profile. None of them may flip core= (they still count
  # in checks=/failed= and force exit 1 via d_bad).
  case "$1" in IMAGE_INPUT|FILES_*|FILE_*) return 0 ;; esac
  DOCTOR_CORE_RAN=true
  [ "$2" = "fail" ] && DOCTOR_CORE_FAILS=$((DOCTOR_CORE_FAILS+1))
  return 0
}
d_ok()  { local id="$1"; shift; DOCTOR_CHECKS=$((DOCTOR_CHECKS+1)); d_core_mark "$id" pass; ok "[$id] $*"; }
d_bad() { local id="$1"; shift; DOCTOR_CHECKS=$((DOCTOR_CHECKS+1)); DOCTOR_FAILS=$((DOCTOR_FAILS+1)); d_core_mark "$id" fail; bad "[$id] $*"; }
# Explanatory detail under a verdict — same [CHECK_ID] on every line, so a
# grep for one ID collects the whole story, not just the verdict.
d_say() { local id="$1"; shift; say "    [$id] $*"; }

# stdin: a response body -> 0 iff it's the contract's OpenAI error shape,
# {"error": {"message": "<non-empty>", "type": "<non-empty>", …}}. A bare
# {"error":{}} or a message-only body is NOT enough — the contract requires
# both fields. Used by the 401 soft-warn and every decline/reject grader, so
# all judge "is this a real error body?" the same way.
doctor_is_openai_error() {
  python3 -c 'import json,sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(1)
e = d.get("error") if isinstance(d, dict) else None
ok = (isinstance(e, dict)
      and isinstance(e.get("message"), str) and e.get("message")
      and isinstance(e.get("type"), str) and e.get("type"))
sys.exit(0 if ok else 1)' 2>/dev/null
}

# stdin: a response body; $1: a required machine code -> 0 iff error.code is
# EXACTLY that string. The stable codes are what clients key on (prose is
# free-form) — "looks like it declined" is not machine-verifiable, the code is.
doctor_error_code() {
  python3 -c 'import json,sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(1)
e = d.get("error") if isinstance(d, dict) else None
sys.exit(0 if isinstance(e, dict) and e.get("code") == sys.argv[1] else 1)' "$1" 2>/dev/null
}

# 0 iff $1 is application/json — case-insensitive, parameters tolerated
# ("application/json; charset=utf-8" passes; text/plain, text/event-stream,
# and a missing header do not).
ct_is_json() {
  local ct; ct=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  ct="${ct%%;*}"
  ct="${ct#"${ct%%[![:space:]]*}"}"; ct="${ct%"${ct##*[![:space:]]}"}"
  [ "$ct" = "application/json" ]
}

# Accept an https URL anywhere, or plain http toward THIS machine only
# (127.*/localhost/[::1]) — testing on the adapter's own host before HTTPS
# exposure is exactly the right order, and refusing loopback http would force
# people to expose first and test second. Echoes the normalized URL (trimmed,
# trailing slashes stripped, scheme lowercased); rc 1 when unacceptable.
doctor_accept_url() { # doctor_accept_url <candidate>
  local reply="$1" rest hostport host
  reply="${reply#"${reply%%[![:space:]]*}"}"; reply="${reply%"${reply##*[![:space:]]}"}"
  while [ "${reply%/}" != "$reply" ]; do reply="${reply%/}"; done
  [ -n "$reply" ] || return 1
  # Pure Bash on purpose: validate_cli calls this before runtime preflight, so
  # a missing python3/curl (or any other executable) can never turn a runtime
  # dependency failure into exit-2 command misuse.
  case "$reply" in
    [Hh][Tt][Tt][Pp][Ss]://?*) printf 'https://%s' "${reply#*://}"; return 0 ;;
    [Hh][Tt][Tt][Pp]://?*) rest="${reply#*://}" ;; # maybe-loopback
    *) return 1 ;;
  esac
  # A prefix glob is NOT enough to prove loopback: "http://127.0.0.1@evil.com"
  # (curl reads the part before @ as a username and connects to evil.com) and
  # "http://127.0.0.1.evil.com" (attacker's wildcard DNS) both start with
  # "http://127." — and would carry the REAL bearer token in cleartext to a
  # remote host. Parse out the authority and validate it strictly.
  hostport="${rest%%/*}"
  case "$hostport" in *@*|*' '*) return 1 ;; esac    # userinfo/junk → refuse
  case "$hostport" in
    '[::1]'|'[::1]:'*) ;;                            # IPv6 loopback (+ optional port)
    [Ll][Oo][Cc][Aa][Ll][Hh][Oo][Ss][Tt]|[Ll][Oo][Cc][Aa][Ll][Hh][Oo][Ss][Tt]:*) ;;
    127.*) host="${hostport%%:*}"
           case "$host" in *[!0-9.]*) return 1 ;; esac ;;  # 127.x must be a pure dotted quad
    *) return 1 ;;
  esac
  printf 'http://%s' "$rest"; return 0
}

doctor_ask_url() {  # -> echoes the URL ($()-captured: every human line to stderr)
  local reply url
  say "  Where is the server? Its base address, without any /v1 tail (I strip that myself)." >&2
  say "  Plain http:// is fine toward this machine (127.0.0.1/localhost) — test locally first," >&2
  say "  expose over HTTPS after." >&2
  while true; do
    read -r -p "  URL (e.g. http://127.0.0.1:8080) > " reply || return 1   # EOF: caller dies
    if url=$(doctor_accept_url "$reply"); then
      printf '  %s→ testing %s%s\n' "$DIM" "$url" "$RESET" >&2
      printf '%s' "$url"; return 0
    fi
    case "$reply" in
      [Hh][Tt][Tt][Pp]://*) warn "Plain http:// only works toward this machine (127.0.0.1 or localhost). Anywhere else needs https://." >&2 ;;
      *) warn "That has to start with https:// — or http://127.0.0.1:<port> for a local test." >&2 ;;
    esac
  done
}

# The auth-NEGATIVE requests: no Authorization header at all, or a deliberately
# wrong bearer token. Plain curl on purpose — curl_gw would helpfully inject the
# REAL token, which is exactly what these two requests must not carry. The wrong
# token is a fixed harmless literal (nothing secret rides argv).
doctor_curl_negauth() { # doctor_curl_negauth <none|wrong> <curl args…>
  local kind="$1"; shift
  # Same egress isolation as curl_gw's doctor path: `-q` (first arg) ignores
  # ~/.curlrc so it can't inject a proxy/output-file/header, and `--noproxy '*'`
  # refuses every proxy — a proxy answering these probes could otherwise forge a
  # 401 and make the doctor report auth as "enforced" when the server is open.
  if [ "$kind" = "wrong" ]; then
    printf 'header = "Authorization: Bearer conduck-check-wrong-token"\n' \
      | curl -q -sS --max-time 30 --noproxy '*' --config - "$@"
  else
    curl -q -sS --max-time 30 --noproxy '*' "$@"
  fi
}

# Check 1 — GET /v1/models with the REAL token: reachability + the canonical
# envelope, via the same models_is_json the wizard trusts (the script must never
# be laxer than the app it green-lights for). rc 1 = transport/status trouble →
# the caller aborts the remaining checks instead of failing four ways at once.
doctor_models_check() {
  local rc=0 why="" secs over
  models_is_json "$GW_URL" || rc=$?
  # curl's own %{time_total} — the real wire time, with no python-spawn overhead
  # polluting it (formatted to 1 decimal; awk tolerates an odd value).
  secs=$(printf '%s' "${MODELS_TIME:-0}" | awk '{printf "%.1f", $1+0}' 2>/dev/null); [ -n "$secs" ] || secs="?"
  over=$(printf '%s' "${MODELS_TIME:-0}" | awk '{print ($1+0 > 15) ? 1 : 0}' 2>/dev/null)
  if [ "$rc" = "0" ]; then
    if $MODELS_DATA_EMPTY; then
      d_bad MODELS_ENVELOPE "GET /v1/models — canonical envelope, but \"data\" is EMPTY"
      d_say MODELS_ENVELOPE '(the contract requires at least one {"id": …} entry — the app has to offer a model)'
    elif $MODELS_NO_VALID_ID; then
      d_bad MODELS_ENVELOPE "GET /v1/models — \"data\" has entries, but none carry a usable \"id\" string"
      d_say MODELS_ENVELOPE '(each entry must be {"id": "<model-name>"} with a non-empty string — the app names a'
      d_say MODELS_ENVELOPE ' model from this list; an entry with no id can'\''t be selected)'
    elif [ "$over" = "1" ]; then
      # A models answer past 15s is a hard FAIL, not a warning: the app's Test
      # Connection gives up at 15s, so this gateway simply won't connect.
      d_bad MODELS_ENVELOPE "GET /v1/models — answered, but took ${secs}s (over the 15s limit)"
      d_say MODELS_ENVELOPE "(the app's Test Connection gives up after 15s — answer from cache, never cold-start"
      d_say MODELS_ENVELOPE " or lazy-load a model on this route)"
    elif ! ct_is_json "$MODELS_CONTENT_TYPE"; then
      d_bad MODELS_ENVELOPE "GET /v1/models — canonical envelope, but Content-Type is '${MODELS_CONTENT_TYPE:0:60}'"
      d_say MODELS_ENVELOPE "(answer with Content-Type: application/json — parameters like charset are fine;"
      d_say MODELS_ENVELOPE " anything else, or no header at all, is a contract failure)"
    else
      d_ok MODELS_ENVELOPE "GET /v1/models — canonical envelope (${secs}s)"
    fi
    return 0
  elif [ "$rc" = "2" ]; then
    d_bad MODELS_ENVELOPE "GET /v1/models — returned an HTML page instead of JSON (HTTP ${MODELS_HTTP_CODE:-?})"
    d_say MODELS_ENVELOPE "(something else answered — a reverse proxy, a login/access page, or a wrong base address)"
    return 1
  elif [ "$rc" = "3" ]; then
    d_bad MODELS_ENVELOPE "GET /v1/models — answers, but not the canonical envelope"
    d_say MODELS_ENVELOPE '(must be a JSON OBJECT whose top-level "data" is an ARRAY of {"id": …} — not a bare'
    d_say MODELS_ENVELOPE ' array, not {"models": …}. This is the app'\''s Test Connection rule, applied verbatim.)'
    return 1
  fi
  if [ "$MODELS_CURL_RC" != "0" ]; then
    case "$MODELS_CURL_RC" in
      6)  why="DNS lookup failed — that hostname doesn't resolve" ;;
      7)  why="connection refused — nothing is listening there (wrong port? not started?)" ;;
      28) why="timed out — no answer from the host" ;;
      35) why="TLS problem — the HTTPS front rejected the connection" ;;
      60) why="TLS problem — this machine doesn't trust the server's certificate (self-signed? run me ON the server against http://127.0.0.1:<port> instead)" ;;
      *)  why="transfer failed (curl exit $MODELS_CURL_RC)" ;;
    esac
  else
    case "$MODELS_HTTP_CODE" in
      401|403) if [ "${GW_AUTH:-}" = "none" ]; then
                 why="HTTP $MODELS_HTTP_CODE and no token was sent — this run is keyless, so the server is asking for auth you didn't supply (set CONDUCK_TOKEN=<token>)"
               else
                 why="HTTP $MODELS_HTTP_CODE with the token you gave me — the server rejected it (typo? or an access layer in front wants its own login)"
               fi ;;
      3??)     why="HTTP $MODELS_HTTP_CODE redirect — use the final server URL directly (the check does not forward credentials across redirects)" ;;
      404)     why="HTTP 404 — nothing at that path (wrong base address?)" ;;
      5??)     why="HTTP $MODELS_HTTP_CODE — the server errored" ;;
      200)     why="answered 200, but the body isn't strict JSON (NaN/Infinity also count as not-JSON — Conduck's decoder refuses them)" ;;
      *)       why="HTTP $MODELS_HTTP_CODE" ;;
    esac
  fi
  d_bad MODELS_ENVELOPE "GET /v1/models — $why"
  return 1
}

# One route's auth-enforcement pair: a no-token request AND a wrong-token
# request must EACH answer 401. `$@` is the curl args that address the route
# (URL for a GET; URL + `-H Content-Type` + `-d body` for the chat POST). The
# real token never rides these — doctor_curl_negauth sends none, or the fixed
# harmless wrong literal.
doctor_auth_route() { # doctor_auth_route <id-prefix> <route-label> <curl-args…>
  local idp="$1" route="$2"; shift 2
  local out rc code body
  out=$(doctor_curl_negauth none -w '\n%{http_code}' "$@" 2>/dev/null); rc=$?
  code="${out##*$'\n'}"; body="${out%$'\n'*}"
  if [ "$rc" != "0" ] || [ -z "$code" ] || [ "$code" = "000" ]; then
    d_bad "${idp}_MISSING" "auth ($route): WITHOUT a token — no answer (the with-token request worked, so this looks like per-request trouble)"
  elif [ "$code" = "401" ]; then
    d_ok "${idp}_MISSING" "auth ($route): WITHOUT a token → 401 (enforced)"
    # Soft check only — the status is the load-bearing part; the body shape
    # decides how nice the app's error message can be, not whether auth holds.
    if ! printf '%s' "$body" | doctor_is_openai_error; then
      warn "  [${idp}_MISSING] …its 401 body isn't the OpenAI error shape — send {\"error\": {\"message\": …, \"type\": …}} (both non-empty) so the app can show a real message."
    fi
  elif [ "$code" = "200" ]; then
    d_bad "${idp}_MISSING" "auth ($route): WITHOUT a token → 200 — the server did the work anyway"
    d_say "${idp}_MISSING" "(this is the dangerous one: anyone who can reach this address can drive your AI and"
    d_say "${idp}_MISSING" " its tools. Check the Authorization header BEFORE doing anything else, on every route.)"
  else
    d_bad "${idp}_MISSING" "auth ($route): WITHOUT a token → HTTP $code (the contract pins exactly 401)"
  fi
  code=$(doctor_curl_negauth wrong -o /dev/null -w '%{http_code}' "$@" 2>/dev/null) || code=""
  case "$code" in
    401) d_ok "${idp}_WRONG" "auth ($route): WRONG token → 401 (enforced)" ;;
    200) d_bad "${idp}_WRONG" "auth ($route): WRONG token → 200 — the token isn't actually compared"
         d_say "${idp}_WRONG" "(compare byte-for-byte against the token you issued — e.g. hmac.compare_digest in Python)" ;;
    ""|000) d_bad "${idp}_WRONG" "auth ($route): WRONG token — no answer (a wide-open server may instead be running a slow agent turn on the probe — check its logs)" ;;
    *)   d_bad "${idp}_WRONG" "auth ($route): WRONG token → HTTP $code (the contract pins exactly 401)" ;;
  esac
}

# Auth must be ENFORCED, not merely accepted — on EVERY route the app calls.
# Testing only /v1/models would green-light a server that gates its model list
# but leaves the tool-running /v1/chat/completions wide open: the exact hole
# this check exists to catch. So both routes are probed. The chat probe carries
# a minimal body (auth is meant to reject BEFORE the body is read); if a
# vulnerable server instead RUNS the agent on the unauthenticated request, the
# probe still fails — either 200 (caught) or a >30s timeout reported as a
# failure (fail-safe, never a green pass).
doctor_auth_checks() {
  if [ "$GW_AUTH" != "bearer" ]; then
    d_bad AUTH_NOT_ENFORCED "auth enforcement — untestable: you gave me no token, so I must assume the server is keyless"
    d_say AUTH_NOT_ENFORCED "(the contract requires a bearer token on EVERY route — a keyless adapter that can run"
    d_say AUTH_NOT_ENFORCED " tools is wide open to whoever can reach it. Add a token check, then re-run me.)"
    return 0
  fi
  doctor_auth_route AUTH_MODELS "/v1/models" "$GW_URL/v1/models"
  doctor_auth_route AUTH_CHAT "/v1/chat/completions" "$GW_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{"messages":[{"role":"user","content":"conduck-connect auth probe"}],"stream":false}'
}

# ---- one real chat turn: transport + grading, shared by every chat probe ----
#
# doctor_chat_request does the POST with the REAL token and lands status /
# content-type / timing / BODY in DCC_* globals (memory only: the body is
# never printed — these probes may run against a live personal agent, and this
# script never logs message content; graders emit verdict words and lengths).
DCC_CODE=""; DCC_CT=""; DCC_TIME=""; DCC_BODY=""
doctor_chat_request() { # doctor_chat_request <payload-json> -> 0 iff the transfer completed
  local out tail_
  DCC_CODE=""; DCC_CT=""; DCC_TIME=""; DCC_BODY=""
  out=$(curl_gw -w '\n%{http_code} %{time_total} %{content_type}' "$GW_URL/v1/chat/completions" \
        --max-time 300 -H "Accept: application/json" \
        -H "Content-Type: application/json" -d "$1" 2>/dev/null) || return 1
  tail_="${out##*$'\n'}"; DCC_BODY="${out%$'\n'*}"
  DCC_CODE="${tail_%% *}"; tail_="${tail_#* }"
  DCC_TIME="${tail_%% *}"
  [ "$tail_" != "${tail_#* }" ] && DCC_CT="${tail_#* }"
  DCC_TIME=$(printf '%s' "$DCC_TIME" | awk '{printf "%.1f", $1}' 2>/dev/null)
  return 0
}

# doctor_chat_eval grades the reply in DCC_* against the contract's response
# rules (strict JSON, exactly one choice, non-empty STRING content, no
# tool_calls, no SSE, Content-Type application/json). This is STRICTER than
# today's app decoder, which reads choices[0].message.content leniently —
# deliberately: the contract is the forward promise an adapter must meet, so
# the doctor holds that bar. It PRINTS NOTHING (callers own the verdict
# lines): failure lands in DCE_REASON/DCE_HINT, success in DCE_LEN — plus
# DCE_TOKEN when an expected digit code was given (the --deep image probe's
# semantic grading: the code must appear as a standalone digit-run in the
# reply, so "The digits are 4827." passes while "48275" does not).
DCE_REASON=""; DCE_HINT=""; DCE_LEN=""; DCE_TOKEN=""
doctor_chat_eval() { # doctor_chat_eval <payload-json> [expected-digit-code]
  local exp="${2:--}" res verdict detail
  DCE_REASON=""; DCE_HINT=""; DCE_LEN=""; DCE_TOKEN=""
  if ! doctor_chat_request "$1"; then
    DCE_REASON="transfer failed (timed out or the connection dropped)"; DCE_HINT="transfer"; return 1
  fi
  # SSE despite a synchronous request is its own diagnosis — a JSON parse
  # error would bury the actual mistake.
  case "$DCC_BODY" in data:*)
    DCE_REASON="the server answered with SSE framing"; DCE_HINT="sse"; return 1 ;;
  esac
  if [ "$DCC_CODE" != "200" ]; then
    case "$DCC_CODE" in
      3??) DCE_REASON="HTTP $DCC_CODE redirect — use the final server URL directly (the check does not forward credentials across redirects)" ;;
      *)   DCE_REASON="HTTP ${DCC_CODE:-?}" ;;
    esac
    DCE_HINT="http"; return 1
  fi
  if ! ct_is_json "$DCC_CT"; then
    DCE_REASON="HTTP 200, but Content-Type is '${DCC_CT:0:60}' (must be application/json)"; DCE_HINT="ct"; return 1
  fi
  # Strict parse (parse_constant: NaN/Infinity refused, matching the app's
  # decoder) + the contract's one-choice / non-empty-string rules on top.
  res=$(printf '%s' "$DCC_BODY" | python3 -c '
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
if len(ch) != 1:
    print("manychoices %d" % len(ch)); sys.exit(0)
msg = ch[0].get("message") if isinstance(ch[0], dict) else None
if not isinstance(msg, dict):
    print("nochoices -"); sys.exit(0)
if msg.get("tool_calls"):
    print("toolcalls -"); sys.exit(0)
c = msg.get("content")
if not isinstance(c, str):
    print("notstring -"); sys.exit(0)
if not c:
    print("empty -"); sys.exit(0)
if exp != "-":
    print(("token %d" if exp in re.findall(r"\d+", c) else "notoken %d") % len(c)); sys.exit(0)
print("ok %d" % len(c))' "$exp" 2>/dev/null)
  verdict="${res%% *}"; detail="${res#* }"
  case "$verdict" in
    ok)      DCE_LEN="$detail"; return 0 ;;
    token)   DCE_LEN="$detail"; DCE_TOKEN="yes"; return 0 ;;
    notoken) DCE_LEN="$detail"; DCE_TOKEN="no";  return 0 ;;   # shape is fine; the digits aren't there
    badjson)     DCE_REASON="HTTP 200, but the body isn't strict JSON"; DCE_HINT="badjson" ;;
    nochoices)   DCE_REASON="no usable \"choices\" array"; DCE_HINT="nochoices" ;;
    manychoices) DCE_REASON="$detail choices in the reply (the contract pins exactly ONE)" ;;
    toolcalls)   DCE_REASON="the reply carries tool_calls"; DCE_HINT="toolcalls" ;;
    notstring)   DCE_REASON="\"content\" isn't a plain string"; DCE_HINT="notstring" ;;
    empty)       DCE_REASON="\"content\" is an empty string" ;;
    *)           DCE_REASON="could not grade the reply" ;;
  esac
  return 1
}

# One graded chat check with its verdict line + failure hints. kind picks the
# failure explanation: plain (the tolerance turn) · history (the
# anti-poisoning turn) · stream ("stream": true).
doctor_chat_check() { # doctor_chat_check <check-id> <label> <payload-json> <kind>
  local id="$1" label="$2" payload="$3" kind="${4:-plain}"
  if doctor_chat_eval "$payload"; then
    d_ok "$id" "$label — one choice, non-empty string content (${DCE_LEN:-?} chars, ${DCC_TIME:-?}s)"
    return 0
  fi
  d_bad "$id" "$label — $DCE_REASON"
  case "$DCE_HINT" in
    sse)
      case "$kind" in
        stream) d_say "$id" "(even when the request says \"stream\": true, answer ONE complete JSON object —"
                d_say "$id" " Conduck never accepts SSE; it may set the flag, but reads a synchronous reply)" ;;
        *)      d_say "$id" "(when stream is false, answer with ONE complete JSON object — Conduck never accepts SSE)" ;;
      esac ;;
    http)
      case "$kind" in
        history)
          d_say "$id" "(the contract forbids rejecting a request because of an image in an EARLIER message —"
          d_say "$id" " forward it to the engine, or replace it in place with the contract's disclosure text."
          d_say "$id" " A text-only newest message must always get an answer: one rejected photo must never"
          d_say "$id" " poison every later turn of the conversation.)" ;;
        stream)
          d_say "$id" "(\"stream\": true must not be rejected — ignore the flag and answer one synchronous"
          d_say "$id" " JSON object, exactly as for stream:false)" ;;
        *)
          case "$DCC_CODE" in
            4??) d_say "$id" "(a 4xx here usually means the request body was rejected — the contract requires"
                 d_say "$id" " tolerating an ABSENT \"model\" field (pick your own default) and IGNORING unknown fields)" ;;
            5??) d_say "$id" "(the server errored — its own logs have the real story)" ;;
          esac ;;
      esac ;;
    badjson)   d_say "$id" "(one complete JSON object; NaN/Infinity are refused by Conduck's decoder)" ;;
    nochoices) d_say "$id" "(the reply must carry choices[0].message.content — see the contract's response shape)" ;;
    toolcalls) d_say "$id" "(never return tool_calls to Conduck — run your tools SERVER-side and answer with the final text)" ;;
    notstring) d_say "$id" "(in the RESPONSE, content must be a non-empty STRING — null or parts-form content is refused)" ;;
    ct)        d_say "$id" "(answer with Content-Type: application/json — parameters like charset are fine)" ;;
  esac
  return 1
}

# Model selection (one logical check, two requests). The app sends the model
# id the user picked from YOUR /v1/models — so the first advertised id must
# actually select (strict 200). And a made-up id must not silently succeed:
# with 2+ advertised models it MUST answer HTTP 400 + an OpenAI error body
# carrying code "model_not_found" (400, not 404 — the contract pins 404 to
# unknown PATHS); a single-model adapter MAY ignore the field instead (it
# advertises exactly one thing, so nothing is ambiguous).
doctor_model_selection_check() {
  local id="MODEL_SELECTION" payload count happy="skip" happy_reason="" bogus="" bogus_reason=""
  count="${MODELS_ID_COUNT:-0}"
  if [ -n "$MODELS_FIRST_ID" ]; then
    payload=$(CONDUCK_CHECK_MODEL="$MODELS_FIRST_ID" python3 -c 'import json, os
print(json.dumps({"messages": [{"role": "user", "content": "Reply with exactly: pong"}],
                  "model": os.environ["CONDUCK_CHECK_MODEL"], "stream": False}))') \
      || die "Could not build the test request (python3 failed)."
    if doctor_chat_eval "$payload"; then happy="ok"; else happy="fail"; happy_reason="$DCE_REASON"; fi
  fi
  payload=$(python3 -c 'import json
print(json.dumps({"messages": [{"role": "user", "content": "Reply with exactly: pong"}],
                  "model": "conduck-check-no-such-model", "stream": False}))') \
    || die "Could not build the test request (python3 failed)."
  if doctor_chat_eval "$payload"; then
    if [ "$count" -gt 1 ]; then bogus="accepted"; else bogus="ignored"; fi
  elif [ "$DCC_CODE" = "400" ] && printf '%s' "$DCC_BODY" | doctor_is_openai_error \
       && printf '%s' "$DCC_BODY" | doctor_error_code "model_not_found"; then
    bogus="rejected"
  else
    bogus="fail"; bogus_reason="$DCE_REASON"
    [ "$DCC_CODE" = "400" ] && bogus_reason="HTTP 400, but the error body lacks code \"model_not_found\" (or isn't the full OpenAI error shape)"
  fi
  if [ "$happy" != "fail" ] && { [ "$bogus" = "rejected" ] || [ "$bogus" = "ignored" ]; }; then
    local how="unknown id → 400 + \"model_not_found\""
    [ "$bogus" = "ignored" ] && how="unknown id ignored (single-model adapter — allowed)"
    d_ok "$id" "model selection — advertised id selects; $how"
    return 0
  fi
  if [ "$happy" = "fail" ]; then
    d_bad "$id" "model selection — asking for your OWN advertised id ('${MODELS_FIRST_ID:0:40}') failed: $happy_reason"
    d_say "$id" "(the app sends the model id the user picked from your /v1/models list — a supplied"
    d_say "$id" " advertised id must select and answer, exactly like an absent one)"
    return 1
  fi
  case "$bogus" in
    accepted)
      d_bad "$id" "model selection — a made-up model id was ACCEPTED (you advertise $count models)"
      d_say "$id" "(with more than one model advertised, the app can't tell which one answered. Reject an"
      d_say "$id" " unknown id with HTTP 400 + an error body carrying code \"model_not_found\")" ;;
    *)
      d_bad "$id" "model selection — a made-up model id wasn't rejected the contract's way: ${bogus_reason:-HTTP ${DCC_CODE:-?}}"
      d_say "$id" "(reject an unknown model id with HTTP 400 — not 404, that's for unknown paths — plus an"
      d_say "$id" " OpenAI error body {\"error\": {\"message\": …, \"type\": …, \"code\": \"model_not_found\"}})" ;;
  esac
  return 1
}

# --deep's semantic image probe. A PNG rendered HERE (stdlib zlib/struct — 4
# random digits as big block glyphs, black on white, ~632×232) rides the
# newest message; the digits are never in the prompt, filename, or metadata,
# so the ONLY way to answer them is to actually see the image. Outcomes:
#   VERIFIED   — 200 and the reply contains the digits: the engine truly sees
#                images (OCR tooling counts — this grades capability, not eyes).
#   DECLINED   — HTTP 400 + OpenAI error body + code "image_unsupported": a
#                text-only adapter refusing honestly. Allowed, passes.
#   UNVERIFIED — 200 but the digits aren't in the reply: the image was
#                silently dropped or hallucinated over — the one forbidden
#                move. Fails the deep profile.
# Anything else (wrong/missing decline code, other statuses, bad shape) FAILs:
# clients key on the machine code, so "looks declined" isn't good enough.
# ~1-in-9000 guess odds are accepted. The reply's content is never printed.
# Build the semantic image probe (shared by --deep and --check-server): sets
# IPG_CODE (the 4 digits) and IPG_PAYLOAD (the chat request carrying the PNG).
# $CONDUCK_PROBE_MODEL (optional, exported by the caller) adds a "model" field
# — the compat probe threads the advertised id through once it learns the
# server requires one; the doctor never sets it (contract: absent model must
# be tolerated).
image_probe_gen() {
  local gen
  gen=$(python3 -c '
import json, os, zlib, struct, base64, random
FONT = {
    "0": [14, 17, 19, 21, 25, 17, 14], "1": [4, 12, 4, 4, 4, 4, 14],
    "2": [14, 17, 1, 2, 4, 8, 31],     "3": [31, 2, 4, 2, 1, 17, 14],
    "4": [2, 6, 10, 18, 31, 2, 2],     "5": [31, 16, 30, 1, 1, 17, 14],
    "6": [6, 8, 16, 30, 17, 17, 14],   "7": [31, 1, 2, 4, 8, 8, 8],
    "8": [14, 17, 17, 14, 17, 17, 14], "9": [14, 17, 17, 15, 1, 2, 12],
}
SCALE, MARGIN, GAP = 16, 60, 64  # wide GAP is load-bearing: at GAP=24 real
# vision models systematically misread adjacent glyphs (measured 1/6 correct
# vs 8/8 at GAP=64 on gpt-5.6 — tight spacing reads as merged segments)
GW, GH = 5 * SCALE, 7 * SCALE
W, H = MARGIN * 2 + 4 * GW + 3 * GAP, MARGIN * 2 + GH
code = str(random.randint(1, 9)) + "".join(str(random.randint(0, 9)) for _ in range(3))
rows = [bytearray(b"\xff" * W) for _ in range(H)]
for i, ch in enumerate(code):
    x0 = MARGIN + i * (GW + GAP)
    for r, bits in enumerate(FONT[ch]):
        for c in range(5):
            if bits & (1 << (4 - c)):
                for y in range(MARGIN + r * SCALE, MARGIN + (r + 1) * SCALE):
                    for x in range(x0 + c * SCALE, x0 + (c + 1) * SCALE):
                        rows[y][x] = 0
raw = b"".join(b"\x00" + bytes(r) for r in rows)
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 0, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
uri = "data:image/png;base64," + base64.b64encode(png).decode()
print(code)
req = {"messages": [{"role": "user", "content": [
    {"type": "text", "text": "Reply with exactly the digits shown in the image. No other text."},
    {"type": "image_url", "image_url": {"url": uri}}]}], "stream": False}
m = os.environ.get("CONDUCK_PROBE_MODEL", "")
if m:
    req["model"] = m
print(json.dumps(req))') \
    || die "Could not build the image test request (python3 failed)."
  IPG_CODE="${gen%%$'\n'*}"; IPG_PAYLOAD="${gen#*$'\n'}"
}

doctor_image_input_check() {
  local id="IMAGE_INPUT" code payload
  image_probe_gen
  code="$IPG_CODE"; payload="$IPG_PAYLOAD"
  if doctor_chat_eval "$payload" "$code"; then
    if [ "$DCE_TOKEN" = "yes" ]; then
      DOCTOR_IMAGE_INPUT="VERIFIED"
      d_ok "$id" "image input — the reply reads the digits back (VERIFIED, ${DCC_TIME:-?}s)"
      return 0
    fi
    DOCTOR_IMAGE_INPUT="UNVERIFIED"
    d_bad "$id" "image input — answered 200, but the reply doesn't contain the image's digits (${DCE_LEN:-?} chars)"
    d_say "$id" "(the engine never saw the image — it was silently dropped somewhere, the one forbidden"
    d_say "$id" " move. Forward images to the engine, or decline honestly with HTTP 400 + an error body"
    d_say "$id" " carrying code \"image_unsupported\" — never answer as if no image was attached.)"
    return 1
  fi
  if [ "$DCC_CODE" = "400" ] && printf '%s' "$DCC_BODY" | doctor_is_openai_error; then
    if printf '%s' "$DCC_BODY" | doctor_error_code "image_unsupported"; then
      DOCTOR_IMAGE_INPUT="DECLINED"
      d_ok "$id" "image input — declined with HTTP 400 + code \"image_unsupported\" (honest refusal, allowed)"
      return 0
    fi
    DOCTOR_IMAGE_INPUT="FAIL"
    d_bad "$id" "image input — declined with HTTP 400, but without code \"image_unsupported\""
    d_say "$id" "(the decline itself is allowed — but the app keys on the machine code to explain the"
    d_say "$id" " refusal and offer recovery, so add \"code\": \"image_unsupported\" to the error object)"
    return 1
  fi
  DOCTOR_IMAGE_INPUT="FAIL"
  d_bad "$id" "image input — $DCE_REASON"
  return 1
}
