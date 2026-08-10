# ---------------------------------------------------------- verification phase --

VERIFY_FAILED=false

# A file lane that a CHECK dropped, not one the operator declined. The service keeps
# running and a saved profile still records it, so write_profile reads this to leave a
# good profile alone rather than turning one transient probe failure into a permanent
# deletion of a working lane.
FS_LANE_DROPPED_BY_CHECK=false

# Did a real agent turn prove the agent can USE the shared folder — read a file
# out of it and write one back? Transport and agent access are two independent
# halves, and only this one is a capability the operator can act on. Three states,
# because "we asked and it failed" and "nobody asked" are both NOT proof but read
# differently: "proved" · "unproved" (a sentinel ran and did not pass) · "" (none
# ran). emit_payload reads it so the final screen cannot show a green capability
# nothing measured.
FS_AGENT_PROOF=""

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

# The loopback address of the SAME endpoint the public URL addresses. A check → setup
# handoff can carry a base path (https://host/api), and a comparison that dropped it
# would probe a DIFFERENT endpoint and then blame the difference on the route.
gw_loopback_base() { # gw_loopback_base -> http://127.0.0.1:<port><base-path>; "" with no port
  [ -n "${GW_LOCAL_PORT:-}" ] || return 0
  printf 'http://127.0.0.1:%s%s' "$GW_LOCAL_PORT" "${CHECKED_PATH_PREFIX:-}"
}

# Does the gateway answer THIS machine successfully, carrying the same credential the
# public request carried? Deliberately stricter than local_health_ok, which counts every
# status below 500 as "up": the only question asked here is "succeeds here, forbidden
# there", and a local 403 counted as "up" would assert the very mismatch it exists to
# disprove. The credential is preserved for the same reason the endpoint and the base
# path are — the route is meant to be the ONLY difference between the two requests, and
# an unauthenticated probe would go blind exactly when the gateway correctly wants a token.
# The bearer rides a stdin curl config, never argv (argv shows in `ps`).
# `Accept: application/json` for the same reason as the credential: models_is_json sends
# it on the public request, and "this very request" is a claim about BOTH of them — a
# front that grades content negotiation would otherwise refuse the public request, wave
# the probe's default `Accept: */*` through, and be handed the all-clear for it.
# `--noproxy '*'` is mandatory, not cosmetic: the target is unconditionally 127.0.0.1 and
# curl has NO loopback exemption, while `-q` suppresses ~/.curlrc but not
# $http_proxy/$ALL_PROXY — without it the token leaves the machine in cleartext to
# whatever host those variables name.
gw_answers_on_loopback() { # gw_answers_on_loopback <base-url> -> 0 when /v1/models answers 2xx
  local code
  if [ "$GW_AUTH" = "bearer" ] && [ -n "${GW_TOKEN:-}" ]; then
    credential_value_safe "$GW_TOKEN" || return 1
    local tok="$GW_TOKEN"; tok="${tok//\\/\\\\}"; tok="${tok//\"/\\\"}"   # curl-config quoting
    code=$(printf 'header = "Authorization: Bearer %s"\n' "$tok" \
      | curl -q -sS --max-time 10 --noproxy '*' --config - \
        -H "Accept: application/json" \
        -o /dev/null -w '%{http_code}' "$1/v1/models" 2>/dev/null) || return 1
  else
    code=$(curl -q -sS --max-time 10 --noproxy '*' \
      -H "Accept: application/json" \
      -o /dev/null -w '%{http_code}' "$1/v1/models" 2>/dev/null) || return 1
  fi
  case "$code" in 2??) return 0 ;; *) return 1 ;; esac
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

# A 403 is a REFUSAL of the request, and on a keyless gateway there is no credential for
# it to be about — so the one message this arm used to print was not merely unhelpful
# there, it was false. The commonest cause on the transports this script offers is the
# `Host` header: Ollama, and other servers meant to be reached only from the machine they
# run on, accept only a local one, while a tunnel forwards the public name it was asked
# for. A tunnel pointed straight at such a server therefore cannot ever succeed, however
# healthy the server is.
# What the probe below proves is NARROWER than that, and is stated as narrowly: the same
# request, with the same credential, on the same endpoint, succeeding on loopback and
# forbidden over HTTPS, isolates the fault to the ROUTE — a Host rewrite, a WAF, an IP
# allowlist and an access layer all live there. Naming the route is what turns a dead end
# into a fix; the `Host` cure is offered as the likely one, never asserted as the verdict.
gw_403_route_note() { # reads GW_AUTH / GW_LOCAL_PORT / MODELS_CURL_RC / MODELS_HTTP_CODE
  [ "$MODELS_CURL_RC" = "0" ] || return 0
  [ "$MODELS_HTTP_CODE" = "403" ] || return 0
  local base; base=$(gw_loopback_base)
  if [ -n "$base" ] && gw_answers_on_loopback "$base"; then
    warn "Your gateway answers this very request on this machine ($base) and forbids it when it"
    # The all-clear is worded per auth mode for the same reason the status line above is:
    # clearing "your credentials" on a run that carries none re-imports the credential
    # framing this whole arm exists to remove, and leaves the reader looking for a token
    # to inspect. The probe carried whatever the public request carried, so a bearer run
    # really has cleared its token and a keyless run has cleared nothing but the server.
    if [ "$GW_AUTH" = "bearer" ]; then
      warn "arrives through your HTTPS address, so the server is up and your token is fine."
    else
      warn "arrives through your HTTPS address, so the server is up and accepting this request."
    fi
    warn "Something on the HTTPS route in front of it is refusing or changing the request."
  else
    note "A 403 means the request arrived and was refused — the address and the network are fine."
    note "I could not prove the gateway accepts it directly on this machine, so the refusal may come"
    note "from the gateway itself or from any HTTPS layer in front of it."
  fi
  note "The likeliest cause is the Host header — the address name every request carries. Ollama and"
  note "servers like it accept only a local name, and an HTTPS front passes on the public one."
  note "Fix it on whatever fronts the gateway. In nginx that is: proxy_set_header Host 127.0.0.1:${GW_LOCAL_PORT:-<gateway port>};"
  # OLLAMA_ORIGINS is named as a DEAD END on purpose: it is the most-cited answer to
  # "Ollama refuses my remote request", and it cannot work here — it sets the browser
  # CORS allow-list, while this 403 comes from a separate Host allow-list that never
  # reads it (ollama server/routes.go: allowedHostsMiddleware → allowedHost, which
  # consults only "localhost", this machine's hostname, and the .localhost/.local/
  # .internal suffixes). Sending the operator to a setting that changes nothing is the
  # same defect as blaming a token they never configured, so it is disarmed by name.
  # The second cure is real for the same source reason: the middleware skips the Host
  # check entirely when the listening address is not loopback.
  note "OLLAMA_ORIGINS does not help here — it sets browser CORS, not this check. Ollama does skip the"
  note "check when it listens on a non-loopback address (OLLAMA_HOST=0.0.0.0), which also opens that port"
  note "to everything that can reach this machine — so rewriting Host on the front is the safer of the two."
}

# A 5xx on a KEYLESS run is not reliably a server fault. Some servers mishandle a MISSING
# credential inside their own error path and answer 5xx where they mean 401 — LiteLLM
# without a database is the one this script meets most often, because its auth-error
# handler imports a module only DB deployments install, so the handler itself raises
# before it can answer. The operator is then sent to read server logs over what is really
# "you told me this gateway is keyless, and it is not".
# The probe is DECISIVE rather than a guess, and it is the same shape as the 403 one:
# resend the request that just failed, changing exactly one thing — an Authorization
# header — and see whether the answer changes. A genuinely broken server answers a
# credentialled request exactly as badly; only a server whose reply DEPENDS on the
# credential can answer differently. Silence when the status is unchanged is therefore
# the honest outcome, not a missed diagnosis.
# `curl_gw` is reused rather than a fresh curl so the probe inherits the same timeout,
# config-file refusal and proxy policy as the request it is compared against — anything
# else and the two would differ by more than the header, which is the whole claim.
# The token is a fixed non-secret literal, so unlike every real credential here it may
# ride argv: there is nothing for `ps` to disclose. It is deliberately self-describing,
# because it lands in the gateway's auth log and the operator reading that log should
# find something that explains itself.
GW_CREDENTIAL_PROBE_TOKEN='conduck-connect-probe-not-a-real-token'
gw_5xx_credential_note() { # reads GW_AUTH / GW_URL / MODELS_CURL_RC / MODELS_HTTP_CODE
  [ "$MODELS_CURL_RC" = "0" ] || return 0
  [ "$GW_AUTH" != "bearer" ] || return 0
  case "$MODELS_HTTP_CODE" in 5??) ;; *) return 0 ;; esac
  local base_again code
  # The CONTROL comes first, and it is what makes this a measurement rather than a guess.
  # A 5xx is the status most likely to be transient — a restarting gateway, a cold model
  # load, a proxy hiccup — and any second request that merely came out different would
  # otherwise be read as proof about the credential. So the unauthenticated request is
  # repeated first: unless the SAME status reproduces, the run is too unstable to
  # conclude anything from and this stays silent. Failing the control also skips sending
  # the probe token at all, which is the cheap path in the common transient case.
  base_again=$(curl_gw -H "Accept: application/json" \
    -o /dev/null -w '%{http_code}' "$GW_URL/v1/models" 2>/dev/null) || return 0
  [ "$base_again" = "$MODELS_HTTP_CODE" ] || return 0
  code=$(curl_gw -H "Accept: application/json" \
    -H "Authorization: Bearer $GW_CREDENTIAL_PROBE_TOKEN" \
    -o /dev/null -w '%{http_code}' "$GW_URL/v1/models" 2>/dev/null) || return 0
  [ -n "$code" ] || return 0
  [ "$code" != "$MODELS_HTTP_CODE" ] || return 0
  warn "This gateway is configured as keyless, but its answer CHANGES when a credential is"
  warn "sent — HTTP $MODELS_HTTP_CODE without one, HTTP $code with one. It wants a token after all."
  note "A server that is simply broken answers both the same way, so this is the credential."
  note "Some servers report a missing one as a 5xx from inside their own error handler rather"
  note "than as 401 — LiteLLM without a database does exactly this."
  note "Re-run setup, say this gateway DOES need a bearer token, and give it the expected one."
}

# What BOTH file-lane gates do when gateway verification has already failed, held
# in one place so the two cannot drift into saying different things about the
# same situation. Every caller runs it BEFORE its request, never after: once any
# gateway check has failed, emit_payload hands out no code at all, so each later
# question is answered into a run that discards it — and this particular one
# would first spend a real, billable, up-to-five-minute agent turn to get there.
# A probe could still have told the operator something on a run whose failure was
# narrow (a local health route down while the public one answers, say), but that
# same proof runs by itself on the re-run they now have to do anyway, so buying
# it here means paying for a turn twice.
# The proof is CLEARED rather than marked "unproved": unproved is what a sentinel
# that ran and fell short earns, and this one never ran.
# No hermes_residual_state_note call — drop_file_lane makes it on the way through,
# and the note self-guards against being said twice.
skip_agent_file_probe_after_failed_gateway() {
  note "The gateway checks above failed, so this run emits no setup code either way — I'm not"
  note "spending an agent turn on the file lane. Fix the gateway, then re-run me."
  FS_AGENT_PROOF=""
  FS_LANE_DROPPED_BY_CHECK=true
  drop_file_lane
}

# What a green sentinel does NOT prove, held in one place because both gates earn
# the identical proof and a second copy is how the two drift into promising
# different things about it. The sentinel is a small text file: passing it shows
# this agent can reach the shared folder in both directions, and nothing about
# whether it can make sense of any particular format once it gets there. Said
# where the proof lands so it reads as the scope of a pass rather than as doubt
# about one — and said on every gateway kind, the two whose tool policy this run
# just wrote included: a policy edit is exactly what makes the unproved half
# easiest to mistake for a proved one.
#
# Three things are named, not one, because a tool the agent HOLDS is not enough:
# measured live, OpenClaw's pdf tool was present and permitted and still failed
# every call, because the model behind it did not resolve. Tools, model, and
# provider each have to be right, and none of them is what this lane carries.
agent_file_proof_scope_note() {
  note "That proves the file lane works. Understanding a PDF or spreadsheet is"
  note "separate — it depends on the gateway's tools, model, and provider."
}

# The custom half of the same gate, answering a different question. For OpenClaw
# and Hermes this wizard configured the agent itself, so a failed sentinel means
# something IT set up is wrong and the lane comes out — the operator can fix the
# named thing and re-run. A custom gateway is any OpenAI-compatible server: a
# plain model server has no file tools at all and cannot pass this, which is a
# fact about that software rather than a fault anyone can repair. So the failure
# is reported without a verdict, and the operator decides — this wizard neither
# ships an unusable exposed lane on its own nor deletes a working one it merely
# failed to measure.
custom_agent_file_lane_gate() {
  # Ahead of the request, never after it — see the helper for why.
  if $VERIFY_FAILED; then
    skip_agent_file_probe_after_failed_gateway
    return 1
  fi

  say "  Asking your agent to copy a randomized sentinel file with whatever file tools it has (up to 5 minutes)…"
  if agent_file_probe; then
    FS_AGENT_PROOF="proved"
    ok "agent file lane: your agent read the sentinel, wrote it back byte-identically, and named it in its reply"
    agent_file_proof_scope_note
    return 0
  fi

  FS_AGENT_PROOF="unproved"
  # Reported with warn, never `bad`: for the most common custom gateway this
  # outcome is the correct answer, and a red ✗ over an expected result teaches the
  # operator to distrust the checks that ARE about their mistakes.
  # The headline names the SENTINEL, not the agent, because the agent is only one
  # of the things that can fail here: a WebDAV refusal and a mktemp that failed on
  # this machine both reach this line, and neither is a finding about anything the
  # operator's agent did.
  warn "The file-lane sentinel did not pass: $AGENT_FILE_PROBE_REASON"
  # Branched on the failure CATEGORY, through the same routine the OpenClaw/Hermes
  # gate uses — a second, flat paragraph here is exactly how the custom path ends
  # up telling an operator whose file server refused the probe that the transport
  # passed and their agent failed, when no agent was ever contacted.
  # Called with NO config hint: this wizard configures nothing agent-side on a
  # gateway it did not set up, so there is no key it applied to point at.
  agent_file_lane_cause_notes "your agent" ""
  # The decisive fact for the choice below, and the operator cannot discover it
  # from anywhere else: the payload carries an address and a credential and has no
  # field for a caveat, so a kept lane arrives in the app looking fully working.
  note "Conduck cannot be told about this: the setup code carries only the address and the"
  note "credential, so the app will show file transfer as enabled either way."
  if confirm "  Include the file server in the setup code anyway?" "file.agent.unproved"; then
    note "Keeping it. This run's screen marks it as unproved; the app cannot."
    return 0
  fi
  # The service and the ROUTE are two different things and drop_file_lane treats
  # them differently: rclone keeps serving, while rollback_fs_exposures undoes the
  # HTTPS exposure this run applied for the lane. Saying only "left exactly as it
  # is" reads as a promise about both, one line before the rollback tears the
  # route down on screen.
  note "Leaving file transfer out of this setup code — chat is unaffected. The file service, its"
  note "folder, and its contents keep running untouched; the only thing undone is an HTTPS route"
  note "this run opened for the lane, which is closed again rather than left reachable."
  FS_LANE_DROPPED_BY_CHECK=true
  drop_file_lane
  return 1
}

# The model is not named anywhere else on this screen, and on the Hermes path it
# is usually not named at all: configure_hermes asks for no model, so the
# gateway's own configured default answers. Naming what actually replied is what
# turns "it may be the model" into something an operator can go and check.
# GW_MODEL is whatever a server or an operator typed, so it goes through
# safe_display like every other foreign string that reaches this terminal.
agent_probe_model_label() { # agent_probe_model_label <agent-name>
  if [ -n "${GW_MODEL:-}" ]; then
    printf 'the model this run asks for, %s' "$(safe_display "$GW_MODEL" 60)"
  else
    printf "%s's own default model — this run names none, exactly as the app does" "$1"
  fi
}

# "What to fix", chosen by the probe's failure CATEGORY. One string for every
# outcome pointed at ~/.hermes/config.yaml even for failures that had nothing to
# do with it — most sharply the one where the agent read the file, wrote a
# byte-identical copy, and only its REPLY fell short, ninety seconds after this
# same run applied and re-checked exactly those keys.
agent_file_lane_fix_hint() { # agent_file_lane_fix_hint <agent-name> <config-hint>
  case "$AGENT_FILE_PROBE_REASON_KIND" in
    reply-naming)    printf '%s' "how $1 answers — its file access already passed" ;;
    visibility)      printf '%s' "the file server, not $1 — it did write the file" ;;
    turn)            printf '%s' "whatever made that request fail" ;;
    transport)       printf '%s' "the file server this run set up" ;;
    harness|cleanup) printf '%s' "this machine's temp-file and file-server access" ;;
    # output-boundary, unsupported, and any kind a later change adds without
    # teaching this function about it: the configuration is the honest default,
    # and it is what the wider note below already frames as a possibility rather
    # than a verdict.
    *)               printf '%s' "$2" ;;
  esac
}

# What that failure does and does not say. The flat version claimed "the WebDAV
# transport worked, but the agent did not complete the file turn" for every
# outcome — false for a transport refusal, false for a staging failure this
# script caused, and misleading for a turn that never got as far as a file.
# <config-hint> is EMPTY on the custom path, and that is a real distinction rather
# than a missing argument: this wizard configures nothing agent-side on a gateway
# it did not set up, so every clause crediting keys "this run applied and
# re-checked" would describe work that never happened. Each branch drops that
# clause rather than printing a sentence with a hole in it.
agent_file_lane_cause_notes() { # agent_file_lane_cause_notes <agent-name> [config-hint]
  local agent="$1" cfg_hint="${2:-}" model
  model=$(agent_probe_model_label "$agent")
  case "$AGENT_FILE_PROBE_REASON_KIND" in
    harness|cleanup)
      note "That is this script's own probe housekeeping on THIS machine, not a finding about"
      note "$agent: nothing was measured about its file tools either way." ;;
    transport)
      note "The file server refused a request, so $agent was never asked to do anything. This is"
      if [ -n "$cfg_hint" ]; then
        note "the WebDAV lane between this script and the shared folder — not the agent, and not"
        note "$cfg_hint."
      else
        note "the WebDAV lane between this script and the shared folder — not the agent, and not"
        note "anything about the file tools it has."
      fi ;;
    turn)
      note "The chat request failed before any file work could be graded, so this says nothing"
      note "about $agent's file tools. The gateway checks above are the ones about the request." ;;
    reply-naming)
      note "The transport worked and so did $agent's file access: it read the sentinel and wrote a"
      note "byte-identical copy. Only the last step is missing — Conduck finds a returned file by"
      note "the filename in the reply TEXT, and this reply did not carry one."
      if [ -n "$cfg_hint" ]; then
        note "So this is about the answer, not about $cfg_hint, which this run already aligned and"
        note "re-checked. Where to look: $model, and the Conduck guidance block that tells the agent"
        note "to state the exact filename in plain text."
      else
        note "So this is about the answer, not about the folder or the file server."
        note "Where to look: $model."
        note "This wizard installs no guidance on a gateway it did not configure, so \"name the"
        note "file you wrote, in plain text\" is a rule you add on your side."
      fi ;;
    visibility)
      note "The transport worked and $agent did finish writing before it replied — the file simply"
      note "never became visible through the file server in time. Look at the file server and the"
      if [ -n "$cfg_hint" ]; then
        note "folder it serves, not at $cfg_hint."
      else
        note "folder it serves, not at the agent."
      fi ;;
    *)
      # output-boundary and anything unclassified. Causes, never a diagnosis: one
      # probe cannot tell these apart, and naming one would send an operator to
      # fix something that was never wrong. The model is LISTED because a
      # tool-less model manufactures exactly this result and is named nowhere
      # else on screen — it is never asserted as the observed cause.
      note "The transport worked, but $agent did not finish the file turn. One failed turn cannot"
      note "say which of these it was:"
      if [ -n "$cfg_hint" ]; then
        note "  - $cfg_hint — this run applied and re-checked it, so it is the less likely half"
        note "  - $model may not call tools at all; a chat-only model behind an agent gateway"
        note "    produces exactly this result"
      else
        # The plain model server leads the list only where nothing was configured:
        # it is the commonest custom gateway by far, and it is the one cause that
        # means nothing on the operator's host is broken at all.
        note "  - a plain model server (Ollama, LiteLLM, vLLM and the like) has no file tools at"
        note "    all and cannot pass this — nothing on your host is wrong"
        note "  - $model may not call tools even where the server has them; a chat-only model"
        note "    behind an agent gateway produces exactly this result"
      fi
      note "  - the agent may write somewhere other than the folder you named, or see a different"
      note "    filesystem than this machine does — a container, another account, another box"
      note "  - what it wrote may not match byte for byte, or may not be a plain file at that name"
      note "  - the turn may simply have failed this once" ;;
  esac
}

agent_file_lane_gate() {
  local agent_name fix_hint config_hint
  case "$GW_KIND" in
    openclaw)
      agent_name="OpenClaw"
      config_hint="OpenClaw's workspace/tool policy" ;;
    hermes)
      agent_name="Hermes"
      config_hint="Hermes's file toolset and terminal.cwd" ;;
    custom) custom_agent_file_lane_gate; return ;;
    *) return 0 ;;
  esac

  # After the case so `custom` keeps its own dispatch and an unrecognised kind
  # keeps its no-op; ahead of the request for the reason the helper carries. The
  # wizard configured the agent itself on these two paths, which is the argument
  # for measuring anyway — and it loses to the same arithmetic: no code comes out
  # of this run regardless, and the re-run the operator now owes has to spend the
  # turn again, so measuring here buys one answer for the price of two.
  if $VERIFY_FAILED; then
    skip_agent_file_probe_after_failed_gateway
    return 1
  fi

  say "  Asking $agent_name to read and copy a randomized sentinel with its file tools (up to 5 minutes)…"
  if agent_file_probe; then
    FS_AGENT_PROOF="proved"
    ok "$agent_name agent file lane: tool read + byte-identical write + reply discovery all green"
    agent_file_proof_scope_note
    return 0
  fi

  FS_AGENT_PROOF="unproved"
  bad "$agent_name agent file lane failed: $AGENT_FILE_PROBE_REASON"
  # Before every branch below, including the --show-code `die`: what to do next is
  # the same question on all of them, and the answer depends on which failure this
  # was rather than on which command is running.
  agent_file_lane_cause_notes "$agent_name" "$config_hint"
  fix_hint=$(agent_file_lane_fix_hint "$agent_name" "$config_hint")
  # A gateway-only code is a real offer only while the GATEWAY itself passed — and
  # by here it did. The entry guard returns on a failed gateway before the probe
  # runs, and nothing between it and this line can set VERIFY_FAILED (only check()
  # and verify_all's own branches do, and neither is reachable from the probe), so
  # the one way to arrive here is a green gateway with a red file lane. That is
  # precisely the case the offer is for.
  if $SHOW_QR; then
    if confirm "Show a gateway-only code anyway? (your saved profile keeps its file lane)" "verification.gateway_only"; then
      FS_LANE_DROPPED_BY_CHECK=true
      drop_file_lane
      return 1
    fi
    die "Stopped before emitting a new code. Any separately approved host edits from this run remain in place; fix $fix_hint, then re-run --show-code."
  fi
  note "Leaving file transfer out of this setup code; fix $fix_hint, then re-run setup."
  hermes_residual_state_note
  FS_LANE_DROPPED_BY_CHECK=true
  drop_file_lane
  return 1
}

# ---- the image gate -----------------------------------------------------------
#
# The last gateway chat turn every pairing verification makes, on every kind and by
# every route in (--setup, both check handoffs, --show-code): one more REAL chat
# turn carrying a picture, so a gateway that answers photos without ever looking
# at them cannot reach the app silently.
#
# Why it exists at all: a photo that vanishes is the one failure the app cannot
# show. A dropped image comes back as an ordinary, confident reply, the pairing
# payload has no field to carry a warning, and nothing on the phone can tell that
# reply from a real sighting. So the only place the operator can ever learn it is
# this screen, before the code exists.
#
# It addresses $GW_URL — the FINAL app-facing address, whatever HTTPS front,
# tunnel or reverse proxy is in it — and carries $GW_MODEL, the model the code is
# about to name. A loopback probe would skip the exact hop most likely to strip a
# multipart content array, and a different model would grade a route the app
# never takes.
#
# Severity keys on the probe's OUTCOME, never on the target's pedigree. A
# purpose-built adapter and a plain Ollama behind a text-only model produce the
# identical silent 200 — behaviour is the evidence, so a 200 that answers as if
# no picture was attached is what gets asked about, and an honest refusal passes
# on every kind. Provenance moves nothing. It is tempting on the --check-adapter
# → setup handoff, where the operator has declared this software was built for
# Conduck and its contract does forbid answering a picture the engine never saw
# — but this probe cannot observe forwarding, only whether the digits came back,
# and the sentences it prints say so. Convicting on that reading because of the
# door the run came through turns an inconclusive measurement into an assertion,
# and it can stop an adapter that forwarded the picture correctly to an engine
# that misread four small digits. The strict grade still lands where a grade
# belongs: --check-adapter --deep reports IMAGE_INPUT red and exits nonzero.
#
# It never fails on the absence of evidence. A transfer that does not complete, a
# body cap, an error nobody can classify — each is reported for what it is and
# none of them withholds a code: the text turn above already passed, and a run
# that cannot measure something must not convict on it.
IMG_PROOF=""     # transcript state for THIS run: "" | verified | declined | too-large
                 # | unmeasured | opaque | ignored | ignored-acked. Not in
                 # the payload and not in the profile — there is nowhere honest to
                 # put it, which is the whole reason this gate is on screen.
IMG_OUTCOME=""   # the last graded turn, set by verify_image_probe_once

# One graded image turn. Prints nothing and decides nothing — it leaves the
# outcome word in IMG_OUTCOME and the app-evaluator state in CCE_*/DCC_* for the
# caller to word. Split out because the ignored case is retried, and a second
# attempt that fails a DIFFERENT way (the tunnel drops, the engine refuses the
# second picture) must be graded on what IT did: a retry folded into the first
# attempt's verdict is exactly how a network fault gets reported to an operator
# as "your gateway drops photos".
verify_image_probe_once() { # verify_image_probe_once [digits-the-retry-must-not-reuse]
  local avoid="${1:-}" redraws=0
  IMG_OUTCOME=""
  # Set explicitly, never inherited: image_probe_gen's python reads the
  # ENVIRONMENT, so a CONDUCK_PROBE_MODEL the operator happens to have exported
  # would quietly grade a different model than the one being paired.
  CONDUCK_PROBE_MODEL="$GW_MODEL" image_probe_gen
  # A retry that happens to redraw the FIRST attempt's digits is not a second
  # look — a cached reply, or the one-in-nine-thousand coincidence the first turn
  # was retried for, would pass on exactly the run where it must not. The digits
  # are drawn locally with no request behind them, so redrawing costs nothing;
  # the bound is there because an unbounded loop on a broken generator is worse
  # than a repeated code.
  while [ -n "$avoid" ] && [ "$IPG_CODE" = "$avoid" ] && [ "$redraws" -lt 8 ]; do
    redraws=$((redraws+1))
    CONDUCK_PROBE_MODEL="$GW_MODEL" image_probe_gen
  done
  # The SAME evaluator the round-trip above used, and the same one the app is
  # mirrored on — a stricter grader here would redden replies the app accepts.
  # That mirroring decides two edges deliberately: EVERY 2xx counts as a reply
  # (a 201 without the digits is the same confident answer on the phone as a 200
  # without them), and a decline the app recognizes counts as recognized at
  # whatever status it arrives on (the app keys on the error code, so a 500
  # carrying "image_unsupported" still shows the user "pictures aren't supported
  # here" rather than a lie about their photo). This gate grades what the person
  # holding the phone will experience, not what the wire ought to look like —
  # --check-adapter --deep is where the wire is held to the stricter bar.
  if app_chat_eval "$IPG_PAYLOAD" "$IPG_CODE"; then
    if [ "$CCE_TOKEN" = "yes" ]; then IMG_OUTCOME="verified"; else IMG_OUTCOME="ignored"; fi
    return 0
  fi
  # A transfer that never completed carries no status to read, so nothing about
  # images was measured. Asked FIRST, before any classification: DCC_CODE is
  # empty in exactly this case, and an empty status falls through every arm below
  # into "opaque" — which would report a dropped connection as a gateway defect.
  if [ "$DCC_CURL_RC" != "0" ]; then IMG_OUTCOME="unmeasured"; return 0; fi
  # The app's own decline classifier, split the way the app splits it: a refusal
  # it can name ("pictures aren't supported here") is a different user experience
  # from a size cap, and both differ from an error it can only show as generic.
  case "$(compat_image_failure_kind)" in
    image_unsupported) IMG_OUTCOME="declined" ;;
    too_large)         IMG_OUTCOME="too_large" ;;
    *)                 IMG_OUTCOME="opaque" ;;
  esac
  return 0
}

# The two ways out of a gateway whose reply does not reflect the picture it was
# sent, said in one place because the refusal arm and the no-terminal arm owe the
# identical advice and a second copy is how they drift.
verify_image_two_fixes() {
  say "    Two ways to fix it, and either one is fine:"
  say "      • send pictures to an engine that can actually see them, or"
  say "      • refuse them: answer HTTP 400 with an error body carrying"
  say "        code \"image_unsupported\". The app then shows its own \"pictures aren't"
  say "        supported here\" message, and text and voice keep working."
}

# A 200 that does not read the picture back, twice. Everything above has passed,
# so this is the only branch that can withhold a code.
verify_image_ignored_gate() {
  bad "photo turn: answered 200 — twice — without reading either test picture's digits back"
  say "    This run could not verify the engine used the picture. It may never have reached the"
  say "    engine, or it may have reached one that could not read it; from out here those are the"
  say "    same answer, so both are worth checking. What is certain is what happens in the app:"
  say "    a photo comes back as a confident reply that does not reflect what you sent, and the"
  say "    app cannot tell that reply from a real one — the pairing code has no field to warn it,"
  say "    and there is no error for it to show."

  # Wording only — it changes no severity and no arm below. An operator who came
  # from --check-adapter is the one person on this screen who can fix the software
  # instead of working around it, so they get the loop that grades it and the rule
  # it grades against. Everyone else is pointed at the two fixes and left alone.
  # ${…:-} because the suites lift this module into runtimes under `set -u` that
  # declare only what they drive; 10-utilities owns the initialisation, and a
  # module may not depend on an earlier one's globals existing in a harness.
  if [ "${SETUP_FROM_CHECK_KIND:-}" = "adapter" ]; then
    say ""
    say "    You reached setup from ${BOLD}--check-adapter${RESET}, so this is software built for Conduck. Its"
    say "    contract allows two answers to a picture in the newest message — forward it to the engine,"
    say "    or refuse the whole request — and a 200 the engine never saw the picture for is neither."
    say "    From out here this run cannot tell that apart from an engine that misread the digits, so"
    say "    it does not stop you on it. The grade that judges the wire is:"
    say "      ${BOLD}bash conduck-connect.sh --check-adapter --deep${RESET}"
    say "      ${BOLD}conduck.com/setup/adapter/v1/${RESET} → Images   (the rule, and the text-only recipe)"
  fi

  # One outcome, one severity, whichever door the run came through. This script
  # cannot know what it is talking to — the custom bucket deliberately holds
  # hand-written adapters and plain model servers alike — and a text-only Ollama
  # behaving exactly like this is not a defect in Ollama. So: report, and offer.
  # Default No, because the answer that may cost someone their photos should not
  # be the one Enter gives.
  warn "Photos are UNVERIFIED here — one may be silently ignored, and the app cannot tell you."

  # --setup only reaches a person (a redirected check exits before it offers the
  # handoff), but --show-code has no such guard and is the path a script uses to
  # re-pair a second device. Asked there, `confirm` reads EOF and answers No —
  # the right ANSWER, printed as a question into a log nobody is reading, which
  # leaves the operator with a missing code and a prompt as the only explanation.
  # Same outcome, said as a statement: this run stops, and here is why and where
  # to decide it. No flag opens it: the code this run would print is a QR for a
  # person holding a phone, so "re-run it where you can answer" is the whole
  # recovery, and a bypass would be permanent public surface bought for a case
  # that starts by not having anyone to show the code to.
  if ! interactive_terminal; then
    IMG_PROOF="ignored"
    VERIFY_FAILED=true
    say "    There is no terminal to ask on in this run, and pairing a gateway whose photos are"
    say "    unverified is not a decision to make on your behalf — so it stops here, with no code."
    say "    Re-run me from a terminal to decide it yourself, or fix it:"
    verify_image_two_fixes
    return 0
  fi

  if confirm "Continue and get the code anyway, knowing a photo here may be silently ignored?" \
             "verification.image_ignored"; then
    IMG_PROOF="ignored-acked"
    note "Continuing. This screen is the only record of it — nothing in the code, the app, or your"
    note "saved profile carries this, so a photo will still look answered either way."
    return 0
  fi
  IMG_PROOF="ignored"
  VERIFY_FAILED=true
  say "    Stopped before emitting a code."
  verify_image_two_fixes
  return 0
}

verify_image_intake() {
  IMG_PROOF=""
  IMG_OUTCOME=""
  # Nothing left to protect on a run that will emit no code: emit_payload already
  # withholds it. Same arithmetic as skip_agent_file_probe_after_failed_gateway —
  # this turn's answer would be discarded, and the re-run they now have to do
  # anyway buys it again for free. Silent: a line about a probe that was skipped
  # is noise under a failure epilogue that already names what to fix.
  $VERIFY_FAILED && return 0

  say "  Then one real photo turn — the same address and model the app will use…"
  verify_image_probe_once
  if [ "$IMG_OUTCOME" = "ignored" ]; then
    # Retry ONCE, and only this outcome, because only this one is about to cost
    # someone their pairing code. A FRESHLY drawn picture on purpose: re-sending
    # the same one lets a cached answer, or the ~1-in-9000 lucky guess, pass on
    # the second look — the retry is there to forgive a flaky turn, not to give
    # a wrong answer two chances to be right.
    # This is the only path that spends a second turn, so a gateway that bills
    # per request is charged twice only when it has already answered once in the
    # single way that would otherwise block it.
    note "That reply didn't contain the picture's digits. Trying once with a new picture before judging…"
    verify_image_probe_once "$IPG_CODE"
  fi

  case "$IMG_OUTCOME" in
    verified)
      IMG_PROOF="verified"
      ok "photo turn: the reply reads the test picture's digits back — pictures reach the engine"
      ;;
    declined)
      IMG_PROOF="declined"
      ok "photo turn: pictures are refused honestly, in a way the app recognizes"
      note "The app shows its own \"pictures aren't supported here\" message; text and voice are"
      note "unaffected. Nothing is lost quietly — a photo fails visibly, with a reason."
      ;;
    too_large)
      IMG_PROOF="too-large"
      warn "The test picture was refused as TOO LARGE (HTTP 413) — and it is a few kilobytes."
      note "Something on this route caps request bodies far below what a photo needs, so in the app"
      note "every picture will fail this way. Raise the limit wherever it lives — a reverse proxy, a"
      note "tunnel, or the gateway itself; the adapter contract's floor is 50 MiB. Not silent: the"
      note "app shows a clear picture-too-large message, so this doesn't hold up your code."
      ;;
    unmeasured)
      IMG_PROOF="unmeasured"
      warn "Image support was NOT measured — the photo turn didn't complete ($CCE_REASON)."
      note "That is a transport fault, not a finding about how this gateway handles pictures. The"
      note "text turn above passed, so your code stands; re-run me if you want the photo answer."
      ;;
    opaque)
      IMG_PROOF="opaque"
      warn "Photo turns fail with an error the app can't classify ($CCE_REASON)."
      note "Sending a picture shows a generic failure instead of \"pictures aren't supported here\"."
      note "Annoying, never deceptive — nothing goes missing quietly, so your code stands."
      ;;
    ignored)
      verify_image_ignored_gate
      ;;
  esac
  return 0
}

verify_all() {
  head_ "Step 5 — verify (real requests, before you touch your phone)"
  # Proof belongs to THIS run's measurements. Cleared here rather than only at
  # declaration so a second verify_all in one process — a re-check, a test, a
  # future menu loop — can never inherit a green claim from an earlier lane.
  FS_AGENT_PROOF=""
  IMG_PROOF=""

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
        # 401 and 403 are different refusals, and only one of them is ever about a
        # credential — so each is also split on $GW_AUTH. A gateway the operator
        # configured KEYLESS carries no token to reject, and naming one there sends them
        # hunting for a secret that does not exist. Same care the 530 arm below is split
        # out with, and the reason 403 keeps its wording route-level: which layer on the
        # route refused is what gw_403_route_note goes and finds out.
        401)
          if [ "$GW_AUTH" = "bearer" ]; then
            why="HTTP 401 — token rejected (or an access layer in front wants a login)"
          else
            why="HTTP 401 — this gateway is keyless, so no token was sent: either the server wants one after all, or an access layer in front of it does"
          fi ;;
        403)
          if [ "$GW_AUTH" = "bearer" ]; then
            why="HTTP 403 — refused: either the token, or the request itself as it arrived over your HTTPS route"
          else
            why="HTTP 403 — this gateway is keyless, so there is no token to reject: the request itself was refused as it arrived over your HTTPS route"
          fi ;;
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
    gw_403_route_note
    gw_5xx_credential_note
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

  # …and the same round trip with a picture on it. Runs AFTER the text turn on
  # purpose: a gateway that cannot answer text at all is not a gateway with an
  # image problem, and the gate returns without spending a turn once anything
  # above has failed.
  verify_image_intake

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

    # Every kind goes through the gate; the gate's own case is the one place that
    # decides which agent proof each kind can offer. A second copy of that routing
    # here is how a newly supported kind ends up silently ungated again.
    if $transport_ok && [ -n "$FS_URL" ] && [ -n "$FS_CRED" ]; then
      agent_file_lane_gate || true
    fi
  fi
}
