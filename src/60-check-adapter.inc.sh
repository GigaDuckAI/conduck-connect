# ------------------------------------------------------------- check-adapter --
#
# --check-adapter: a black-box check of an adapter built for Conduck against the
# rules at conduck.com/setup/adapter/v1/ (contract revision 1.7). Built for
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
# open with tool access), that a REJECTED request leaves its connection usable
# for the NEXT one (the rejected body drained, or the connection closed — the
# one fault a by-hand curl structurally cannot find, because every curl command
# opens its own connection), that an ABSENT "model" field is tolerated, that
# unknown request fields are ignored, that a supplied model id really selects
# (or answers 400 + code "model_not_found"), that an image in an EARLIER
# message can never poison the chat (forward it or replace it with the
# contract's disclosure — never reject; one bad photo must not kill every
# later turn), and that "stream": true still gets ONE synchronous JSON answer —
# asked for in the body AND in the Accept header, since an adapter that decides by
# content negotiation is invisible to a probe that only ever asks for JSON.
# CHAT_BASIC owns the absent-model rule, and it owns it alone: the history,
# stream and image probes also omit the field, so on an adapter that REQUIRES a
# model they would every one of them fail for CHAT_BASIC's reason. Once CHAT_BASIC
# has confirmed that requirement — by re-sending its identical request with the
# first advertised id — the later probes carry that id and grade their OWN rule,
# and the missing-model failure is reported once, where it belongs.
# --deep adds the semantic image probe: a locally generated PNG showing 6
# random digits (never named in the prompt or metadata) rides the newest
# message — a reply carrying those digits proves the engine truly SAW the
# image (VERIFIED); an honest HTTP 400 decline with code "image_unsupported"
# also passes (DECLINED); a 200 without them leaves the sighting UNPROVEN
# (UNVERIFIED → exit 1) — from out here that reply cannot be told apart from
# the forbidden silent drop, which is why it fails closed rather than being
# diagnosed as one.
#
# --files adds the file-lane probes (MUTATING — the one adapter-check profile that
# is: it writes + removes small conduck-check-* files and folders in the
# configured shared folder, and asks the selected agent to create one folder
# and copy a file into it). Three meters, graded independently:
# file_transport (this host's WebDAV <-> disk lane, listings included),
# file_access (the selected engine creates the folder the turn names and
# writes a byte-identical file inside it), file_e2e (the combined
# output-delivery path, probed exactly the way the app probes it). It does
# NOT prove public exposure or remote-device reachability — the wizard
# verifies the app-facing lane during setup; the plain adapter check proves
# conformance.
#
# Output contract: every check verdict line carries a stable [CHECK_ID], and
# the LAST line on every exit — pass, fail, or an early die — is the machine
# summary, schema=3 (fixed field order, ASCII enums, no ANSI):
#   CONDUCK_CHECK_ADAPTER schema=3 contract=v1 revision=1.7 harness=<ver>
#     profile=<basic|deep> core=<PASS|FAIL|NOT_RUN>
#     history_image=<PASS|FAIL|NOT_RUN> stream=<PASS|FAIL|NOT_RUN>
#     image_input=<VERIFIED|DECLINED|UNVERIFIED|FAIL|NOT_RUN>
#     file_transport=<…> file_access=<…> file_e2e=<…>
#     checks=<n> failed=<n> exit=<n>
# Every capability meter is a claim about something the run MEASURED, so NOT_RUN
# covers both "a prerequisite stopped this tier" and "the probe failed for a
# cause this run could not tell apart from another rule's failure". A capability
# the run could not measure is never reported as failing it — the run-level
# verdict lives in core=/failed=/exit=, and a red verdict line there is what
# says the adapter is non-conformant.
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
DOCTOR_CONTRACT_REV="1.7"
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
# The status the LAST doctor_auth_route wrong-token probe got. AUTH_CHAT_REJECT_BODY
# grades what a rejection did with the body it rejected, so it only has something
# to grade when the route actually rejected: this is that precondition.
DOCTOR_AUTH_WRONG_CODE=""

# Does this adapter tolerate a request with NO "model" field? Three probes
# deliberately omit it (the contract requires tolerating an absent model), so on
# an adapter that REQUIRES one they would all fail for that single reason — and
# each would be explained as a fault of its own rule, which is how a working
# history-image path gets told it poisons conversations. CHAT_BASIC answers the
# question ONCE and every later chat probe reads the answer here:
#   unknown        — not decided (CHAT_BASIC hasn't run, or failed some other way)
#   tolerated      — a model-less turn answered; later model-less probes are honest
#   required       — CHAT_BASIC failed model-less and the identical request answered
#                    once DOCTOR_MODEL_LANE_ID was supplied. Later probes carry that
#                    id, so they grade the rule they exist to grade.
#   unattributable — CHAT_BASIC failed model-less and this run could not separate
#                    "requires a model" from a fault of its own; later probes of the
#                    same shape report NOT graded rather than inventing a cause.
# ONLY CHAT_BASIC may write these (doctor_chat_check enforces it). Letting a later
# probe decide would let a capability check outside the core= rollup turn its own
# red into a measured green, and IMAGE_INPUT can't flip core= — so a whole run
# could go green on an adapter that violates the absent-model rule.
DOCTOR_MODEL_LANE="unknown"
DOCTOR_MODEL_LANE_ID=""

# The way out of a FAIL that isn't the reader's to fix. This grade holds software
# written FOR Conduck to Conduck-specific rules, and third-party OpenAI-compatible
# software is EXPECTED to fail it — answering a request that asks for SSE with SSE is correct
# OpenAI behaviour, keyless is a legitimate deployment choice, and neither is a
# defect in LiteLLM, Open WebUI or Ollama. Without this, the closing line points
# only at the contract docs, so a user grading someone else's server reads a wall
# of red as "this cannot be used" and stops — when the app pairs with it fine.
# Printed on EVERY --check-adapter failure exit, including the early /v1/models
# abort: the person is equally stranded whichever check stopped the run.
doctor_not_yours_hint() {
  say "  Didn't write this server yourself? Then this red says very little. The grade above"
  say "  holds software built FOR Conduck to Conduck's own rules, and generic servers (Ollama,"
  say "  LiteLLM, Open WebUI) fail rules that are correct for them — their owners did nothing"
  say "  wrong. Ask the question you actually have instead:"
  say "    ${BOLD}bash conduck-connect.sh --check-server${RESET}   — can the app talk to this server?"
  say "    ${BOLD}bash conduck-connect.sh --setup${RESET}          — pair it; a failed grade here doesn't block that"
  # That last line has to stay literally true, and setup carries one gate of its
  # own: it sends a real photo turn before it prints a code. Nothing on THIS grade
  # blocks pairing — but "doesn't block that" reads as a promise that setup asks
  # nothing, and the operator would meet the question anyway.
  say "      (setup runs its own final photo check and asks first)"
  # This hint prints on a scripted FAIL too, and the second command is the one a
  # machine cannot finish. Naming the blocker in that case keeps a build loop from
  # following the line into an exit 1 it would report as a broken pairing. Only
  # the extra sentence is conditional — the two commands stay put for everyone, so
  # a human reader sees exactly what they saw before.
  interactive_terminal \
    || say "  That last one needs a person: it ends in a QR code someone scans with a phone."
}

# What to do with a green check — said differently to the two readers who get one.
# Shared by both check commands, because both used to end a passing run with the
# same unqualified line and both have the same two audiences.
#
# An interactive operator is about to be asked "continue with setup and pairing?"
# and can simply answer yes; the command is here for the one who answers no.
#
# A machine gets the blocker instead of the command. Handed `--setup` unqualified,
# a scripted run follows it — that is what a scripted run is for — and exits 1 on
# a message about stdin, so its transcript reads green check, instruction,
# failure, and it reports a pairing as broken when nothing is. "Run me from a
# terminal" states a fact about stdin, not the reason: setup ENDS in a QR code
# that a person scans with the Conduck app on a phone, and no answer a machine can
# supply finishes that. Naming the real blocker, and naming who to hand the
# command to, is the difference between a dead end and a handover.
check_setup_next_step() {
  if interactive_terminal; then
    say "  To set it up later:  ${BOLD}bash conduck-connect.sh --setup${RESET}"
    return 0
  fi
  say "  ${BOLD}Setup needs a person, not a script.${RESET} It ends by showing a QR code that someone"
  say "  scans with the Conduck app on a phone, so there is no answer a machine can give that"
  say "  finishes it — a scripted run stops at the first question. Hand your operator:"
  say "      ${BOLD}bash conduck-connect.sh --setup${RESET}"
}

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

# Accept an https URL anywhere, or plain http toward an address only the local
# network reaches — the same boundary Apple enforces and the app applies, so the
# wizard cannot accept an address the app will refuse. Testing on the adapter's own
# host, or on the box across the room, before HTTPS exposure is exactly the right
# order, and refusing local http would force people to expose first and test
# second. Echoes the normalized URL (trimmed, trailing slashes stripped, scheme
# lowercased); rc 1 when unacceptable.
doctor_accept_url() { # doctor_accept_url <candidate>
  local reply="$1" rest hostport
  reply="${reply#"${reply%%[![:space:]]*}"}"; reply="${reply%"${reply##*[![:space:]]}"}"
  while [ "${reply%/}" != "$reply" ]; do reply="${reply%/}"; done
  [ -n "$reply" ] || return 1
  # Pure Bash on purpose: validate_cli calls this before runtime preflight, so
  # a missing python3/curl (or any other executable) can never turn a runtime
  # dependency failure into exit-2 command misuse.
  # Userinfo is refused on BOTH schemes, and BEFORE the scheme is graded. The local
  # arm below needs that ordering (see its comment: http://192.168.1.1@evil.com is a
  # REMOTE host, and the private-looking half is the bait); https needs it for the
  # reason --show-code's profile validator already rejects it — this URL is
  # echoed to the terminal, saved to the profile, and paired into the app, and a
  # credential must never ride a routing field.
  url_has_userinfo "$reply" && return 1
  case "$reply" in
    [Hh][Tt][Tt][Pp][Ss]://?*) printf 'https://%s' "${reply#*://}"; return 0 ;;
    [Hh][Tt][Tt][Pp]://?*) rest="${reply#*://}" ;; # maybe-local
    *) return 1 ;;
  esac
  # A prefix glob is NOT enough to prove the destination: "http://192.168.1.1@evil.com"
  # (curl reads the part before @ as a username and connects to evil.com) and
  # "http://192.168.1.1.evil.com" (attacker's wildcard DNS) both start with
  # "http://192.168." — and would carry the REAL bearer token in cleartext to a
  # remote host. Parse out the authority and hand it to the one classifier, which
  # refuses both shapes and every other name that only looks private.
  hostport="${rest%%[/?#]*}"
  url_is_local_host "$hostport" || return 1
  printf 'http://%s' "$rest"; return 0
}

# The address prompt shared by both check commands. It honours the same prompt
# contract as the primitives in 10-utilities (rc 0 = the URL is on stdout, 11 =
# the operator pressed q, 1 = the input ended), because both call sites capture it
# with $(…) and a `q` acted on inside that subshell would kill the subshell only.
# Callers should reach it through prompt_into, which turns 11 into quit_run in the
# parent shell.
#
# The argument is what `i` shows. Both commands pass their own opening block by
# FUNCTION NAME — explain_prompt resolves a function before it consults the
# explanation catalogue — because the block that says what this command wants an
# address for is the same block that opened the command, and someone pressing i
# here has scrolled past it.
#
# Back is not offered: this is the first question either check asks, so there is
# no earlier answer to return to. `b` is still intercepted rather than validated
# as an address — nothing that fails the https test can be a legal answer here, so
# the letter is unambiguous, and the refusal names the keys that do work. That
# mirrors ask_url, whose wording this reuses verbatim.
doctor_ask_url() {  # doctor_ask_url [action-id | help-fn] -> URL on stdout (every human line to stderr)
  local action="${1:-}" reply url p
  say "  Where is the server? Its base address, without any /v1 tail (I strip that myself)." >&2
  say "  Plain http:// is fine toward an address on your own network (an IP like 192.168.1.10," >&2
  say "  or a .local name) — test locally first, expose over HTTPS after." >&2
  p="  URL (e.g. http://127.0.0.1:8080; $(control_suffix "ask again" false)) > "
  while true; do
    prompt_echo "$p"
    read -r -p "$p" reply || return 1   # EOF: the caller reports it
    case "$reply" in
      [iI]) explain_prompt "$action" >&2; continue ;;
      [qQ]) return 11 ;;
      [bB]) warn "Back is not available at this step; type an https:// URL, i for an explanation, or q to stop." >&2
            continue ;;
      # Enter is an advertised no-op here, so it re-asks without being told off:
      # pausing at a question with no default is not a mistake.
      '') note "Nothing entered — the server's address goes on this line." >&2; continue ;;
    esac
    if url=$(doctor_accept_url "$reply"); then
      printf '  %s→ testing %s%s\n' "$DIM" "$url" "$RESET" >&2
      printf '%s' "$url"; return 0
    fi
    if url_has_userinfo "$reply"; then
      warn "$URL_USERINFO_HINT" >&2; continue
    fi
    case "$reply" in
      [Hh][Tt][Tt][Pp]://*) warn "$URL_PLAIN_HTTP_HINT" >&2 ;;
      *) if looks_like_a_secret "$reply"; then warn_answer_looked_like_a_secret; fi
         warn "That has to start with https:// — or http://<address on your own network>:<port> for a local test." >&2 ;;
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

# Does an auth rejection on THIS route poison the connection it answered on?
# An adapter that replies 401 WITHOUT consuming the request body leaves those
# bytes in the socket; on a persistent HTTP/1.1 connection the server then
# reads them as the start of the NEXT request and answers 400 (or 414/431/
# 501/505, depending on its parser) to whatever comes after. RFC 9112 is
# explicit: a rejecting response must still consume the body, or close the
# connection. Three independently built adapters shipped exactly this bug.
#
# The probe: two identical wrong-token requests ride ONE curl invocation joined
# by `--next`, so curl reuses a single connection. Echoes
# "<status-1> <status-2> <new-connections-on-2>". That last field is the
# load-bearing evidence — 0 means curl really did reuse the connection, 1 means
# it opened a fresh one (e.g. because the server correctly answered
# `Connection: close`, or the pooled connection was dead), and a differing
# second status then proves nothing at all. The caller reads all three; this
# function makes no claim.
#
# `--next` RESETS every per-transfer option, so each half repeats its own
# `-sS`/`--http1.1`/`--max-time`/`--noproxy`/headers; only `-q` is global and
# has to stay first. Plain curl, never curl_gw — the REAL token must never ride
# an auth-negative probe; the wrong token is the same fixed harmless literal
# doctor_curl_negauth sends. `--http1.1` is pinned because HTTP/2 frames bodies
# and cannot show this failure at all.
#
# `-H 'Expect:'` deletes curl's `Expect: 100-continue`, and that is load-bearing
# rather than tidiness: with it, a server that answers 401 straight away makes
# curl skip sending the body at ALL, so there is nothing left over and the probe
# would report a clean connection for an adapter that never drains anything.
# curl only adds the header above a ~1 KB body today, so nothing changes now —
# pinning it keeps the probe honest if this body ever grows.
#
# The per-transfer time limit is the caller's, because the two callers want
# different ones: the diagnostic path passes 10 (an explanatory probe fired
# after an already-answered request has no business adding another minute),
# while the counted check passes the same 30 its own precondition already
# proved this route answers within — there, a probe that merely ran out of time
# would otherwise turn into a verdict about the adapter.
doctor_desync_pair() { # doctor_desync_pair <max-seconds> <curl args addressing the route…>
  local t="$1"; shift
  curl -q -sS --http1.1 --max-time "$t" --noproxy '*' \
       -H "Authorization: Bearer conduck-check-wrong-token" -H 'Expect:' \
       -o /dev/null -w '%{http_code} ' "$@" \
    --next -sS --http1.1 --max-time "$t" --noproxy '*' \
       -H "Authorization: Bearer conduck-check-wrong-token" -H 'Expect:' \
       -o /dev/null -w '%{http_code} %{num_connects}' "$@" 2>/dev/null
}

# The statuses an HTTP request PARSER emits when it starts reading in the middle
# of something that is not a request line — the fingerprint of a connection that
# still holds the body of an already-answered request. One list, shared by both
# readers of a desync pair (the counted check and the diagnostic), so the two can
# never drift into disagreeing about what the same evidence means.
doctor_parse_level_status() { # doctor_parse_level_status <http-status>
  case "$1" in 400|414|431|501|505) return 0 ;; esac
  return 1
}

# Busy/overloaded — the two statuses the contract itself lets an adapter answer
# instead of running a turn. The counted check refuses to grade a pair carrying
# one: it fires four rejected requests at a single route inside a second, and an
# adapter that throttles that burst is being careful, not broken. Blaming its
# body handling for a throttle is exactly the false FAIL this check must not emit.
doctor_busy_status() { # doctor_busy_status <http-status>
  case "$1" in 429|503) return 0 ;; esac
  return 1
}

# Split one doctor_desync_pair result into DSP_FIRST/DSP_SECOND/DSP_CONNECTS.
# rc 1 unless it is EXACTLY three fields, both statuses are three digits not
# starting with 0 (so curl's "000" — no answer at all — never reads as a status),
# and the connect count is a plain number. The strictness is the whole point: a
# truncated or empty result must FAIL to parse rather than get reinterpreted, or
# "the probe never ran" quietly becomes a confident verdict about an adapter that
# did nothing wrong. (`"401 400"` really does slice into 401/400/400 otherwise.)
DSP_FIRST=""; DSP_SECOND=""; DSP_CONNECTS=""
doctor_desync_parse() { # doctor_desync_parse <pair-output>
  local raw="$1" f s c
  DSP_FIRST=""; DSP_SECOND=""; DSP_CONNECTS=""
  case "$raw" in *' '*' '*) ;; *) return 1 ;; esac     # at least three fields…
  f="${raw%% *}"; raw="${raw#* }"
  s="${raw%% *}"; c="${raw#* }"
  case "$c" in *' '*) return 1 ;; esac                 # …and no more than three
  case "$f" in [1-9][0-9][0-9]) ;; *) return 1 ;; esac
  case "$s" in [1-9][0-9][0-9]) ;; *) return 1 ;; esac
  case "$c" in ''|*[!0-9]*) return 1 ;; esac
  DSP_FIRST="$f"; DSP_SECOND="$s"; DSP_CONNECTS="$c"
  return 0
}

# The undrained-body reading of a WRONG-token answer that isn't 401. This is
# the single most misread verdict in the whole check: the message ("HTTP 400,
# the contract pins 401") is literally true and causally wrong, and every
# builder who hit it went hunting through a token comparison that was fine.
# Only a route that CARRIES a body can leave bytes behind, so the models GET
# never asks. Diagnostic only — d_say lines under the caller's single d_bad,
# so check counts and the machine summary are untouched.
#
# Three honest outcomes, never one guess: the pair reproduced it on a proven
# reused connection (say so plainly) · the pair's first request answered 401
# where the standalone one answered $code, so the answer is not stable (report
# that, and where to look) · the status repeats (their auth path really does
# answer it — keep the drain theory to one hedged sentence).
doctor_auth_wrong_diagnose() { # doctor_auth_wrong_diagnose <check-id> <status> <curl args…>
  local id="$1" code="$2" a has_body=false desynced=false pair first="" second="" connects=""; shift 2
  for a in "$@"; do
    if [ "$a" = "-d" ]; then has_body=true; break; fi
  done
  $has_body || return 0
  # Parse-level statuses only. A 403/405/429 is plausible middleware, not a
  # desynced request stream, and guessing at those would just relocate the
  # wild-goose chase.
  doctor_parse_level_status "$code" || return 0
  pair=$(doctor_desync_pair 10 "$@") || pair=""
  if doctor_desync_parse "$pair"; then
    first="$DSP_FIRST"; second="$DSP_SECOND"; connects="$DSP_CONNECTS"
  fi
  # A differing second status only counts as evidence when curl proves it did
  # NOT open a new connection (connects=0) and the difference is parse-level.
  if [ "$first" = "401" ] && [ "$connects" = "0" ] && doctor_parse_level_status "$second"; then
    desynced=true
  fi
  if $desynced; then
    d_say "$id" "(a follow-up probe got 401, then HTTP $second for the SAME request on the SAME reused"
    d_say "$id" " connection — that is the signature of an undrained request body, not of a broken key"
    d_say "$id" " check. A response that REJECTS a request must still consume that request's body (read"
    d_say "$id" " the Content-Length bytes, drain the chunked stream) or answer \"Connection: close\" and"
    d_say "$id" " close: whatever is left in the socket gets read as the start of the NEXT request, and"
    d_say "$id" " that is what answered $second. Conduck reuses connections and so does any reverse proxy"
    d_say "$id" " in front of you, so this breaks real turns — not just this check.)"
  elif [ "$first" = "401" ]; then
    d_say "$id" "(the identical probe answered 401 a moment later, so HTTP $code is not a stable answer from"
    d_say "$id" " your auth code — check the path before you check the comparison. The usual cause is a 401"
    d_say "$id" " that answers WITHOUT consuming the request body: those bytes stay in the socket and the"
    d_say "$id" " next request on that kept-alive connection is parsed starting mid-body. A reverse proxy"
    d_say "$id" " pooling upstream connections shows exactly this — which is why it can pass against"
    d_say "$id" " http://127.0.0.1:<port> and fail through your HTTPS front. Compare those two runs.)"
  elif [ -n "$first" ]; then
    d_say "$id" "(HTTP $code repeats on a fresh connection, so this really does look like your auth path"
    d_say "$id" " answering — the contract wants 401 on both the missing and the wrong key. If it turns"
    d_say "$id" " out to reproduce ONLY through your HTTPS front and not against http://127.0.0.1:<port>,"
    d_say "$id" " suspect the other cause instead: a 401 that never consumes the request body leaves those"
    d_say "$id" " bytes to be read as the next request on a pooled connection.)"
  else
    # The pair produced no readable evidence, so every sentence above would be an
    # invention. Say only what is true, and name the run that answers it.
    d_say "$id" "(the follow-up probe that separates a genuine auth answer from an undrained request body"
    d_say "$id" " never completed, so this run can't tell you which it is. Run me ON the adapter's own host"
    d_say "$id" " against http://127.0.0.1:<port> for the reading with nothing in between.)"
  fi
}

# Contract 1.4, normative: a response that REJECTS a request before that
# request's body has been consumed must still read and discard the remainder, or
# send "Connection: close" and close. Skip both and the leftover bytes are read
# as the start of the NEXT request on that connection — a request that was
# itself perfectly fine. Three of five independent from-scratch adapter builds
# shipped exactly this. It cannot be found by hand: every plain curl command
# opens its own connection, so a loopback self-test structurally cannot see it,
# and it surfaces only behind the pooling HTTPS front the adapter is actually
# deployed behind (Cloudflare Tunnel, Tailscale Serve, nginx) as unexplained
# failures on unrelated requests. That is why this is a COUNTED check and not
# only the diagnosis above: the diagnosis fires after some OTHER check already
# went red, so an adapter that never trips that path ships with the bug intact.
#
# Preconditions, both the caller's: bearer auth, and a standalone wrong-token
# probe that already answered 401. Without a real rejection there is no rejected
# body to grade, and the not-401 case belongs to doctor_auth_wrong_diagnose.
#
# What green means here is "no follow-up failure observed", never "internals
# proven". %{num_connects}=0 proves the CLIENT reused its connection; behind a
# reverse proxy that is the connection to the PROXY, and which upstream
# connection the proxy then picked is not knowable from out here. So a failure is
# reported as what was SEEN — identical requests, different answers — and never
# as a cause this vantage point cannot establish.
#
# FAIL needs positive evidence. Everything that merely fails to PRODUCE evidence
# — a probe that never completed, an adapter throttling the burst with 429/503 —
# counts green with a note saying so. A check that reddens a CORRECT adapter is
# worse than no check: it sends its builder auditing code that was never wrong.
doctor_reject_body_check() { # doctor_reject_body_check <curl args addressing the chat POST route…>
  local id="AUTH_CHAT_REJECT_BODY" pair first second connects
  pair=$(doctor_desync_pair 30 "$@") || pair=""
  if ! doctor_desync_parse "$pair"; then
    # One retry, and only for this outcome: an incomplete transfer is the one
    # thing a second attempt can genuinely resolve. A 429 is never retried —
    # repeating the burst makes a throttle more likely, not less.
    pair=$(doctor_desync_pair 30 "$@") || pair=""
  fi
  if ! doctor_desync_parse "$pair"; then
    d_ok "$id" "rejected-request body — the follow-up probe never completed, so nothing was observed"
    d_say "$id" "(two more wrong-key requests down ONE connection would have shown whether a rejected"
    d_say "$id" " request's body is left behind for the next request to trip over; neither finished, so"
    d_say "$id" " this run has no evidence either way and does not hold that against you. For the reading"
    d_say "$id" " with nothing in between, run me ON the adapter's host against http://127.0.0.1:<port>.)"
    return 0
  fi
  first="$DSP_FIRST"; second="$DSP_SECOND"; connects="$DSP_CONNECTS"
  if [ "$first" = "401" ] && [ "$second" = "401" ]; then
    if [ "$connects" = "0" ]; then
      d_ok "$id" "rejected-request body — a second identical request on the SAME connection still → 401"
    else
      # The contract recommends exactly this for a 401 (draining an
      # unauthenticated peer's body does the work the rejection existed to
      # avoid), so it is a first-class pass, not a lucky one.
      d_ok "$id" "rejected-request body — the 401 closed the connection; the identical retry → 401"
    fi
    return 0
  fi
  if [ "$connects" = "0" ] && [ "$second" != "$first" ] && doctor_parse_level_status "$second"; then
    d_bad "$id" "rejected-request body — identical requests → $first then HTTP $second on ONE reused connection"
    d_say "$id" "(that is the signature of a rejection answered WITHOUT consuming the request's body: the"
    d_say "$id" " leftover bytes are read as the start of the next request, and that is what answered"
    d_say "$id" " $second. Contract revision $DOCTOR_CONTRACT_REV: a response that rejects a request must still read and"
    d_say "$id" " discard the rest of that body, or send \"Connection: close\" and close after it. For a 401"
    d_say "$id" " closing is usually the better half — draining an unauthenticated peer performs exactly the"
    d_say "$id" " work the rejection existed to avoid. Conduck reuses connections and so does every reverse"
    d_say "$id" " proxy, so this breaks ordinary turns that are themselves perfectly fine. From out here I"
    d_say "$id" " can only prove MY connection was reused — which upstream connection a front picked isn't"
    d_say "$id" " visible, so confirm it on the adapter's own host against http://127.0.0.1:<port>.)"
    return 1
  fi
  if doctor_busy_status "$first" || doctor_busy_status "$second"; then
    d_ok "$id" "rejected-request body — the route answered $first then $second (busy), so it wasn't graded"
    d_say "$id" "(this probe fires four rejected requests at one route inside a second, and throttling that"
    d_say "$id" " burst is careful rather than broken, so it is not counted against you. It does mean this"
    d_say "$id" " run proves nothing about what happens to a rejected request's body — re-run me when the"
    d_say "$id" " route is idle if you want that answered.)"
    return 0
  fi
  d_bad "$id" "rejected-request body — the wrong key → 401 alone, but $first then $second down one connection"
  d_say "$id" "(the same request got two different-looking answers seconds apart, so something in the path"
  d_say "$id" " is not deciding consistently. The usual cause is a rejection answered without consuming the"
  d_say "$id" " request's body: the leftovers desync whichever pooled connection they land on, so the damage"
  d_say "$id" " shows up on a LATER request rather than this one. Contract revision $DOCTOR_CONTRACT_REV: drain the remainder,"
  d_say "$id" " or answer \"Connection: close\" and close after it. Check the HTTPS front too — it pools"
  d_say "$id" " upstream connections, so one poisoned connection resurfaces on requests that are fine.)"
  return 1
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
      401)     if [ "${GW_AUTH:-}" = "none" ]; then
                 why="HTTP 401 and no key was sent — this run is keyless, so the server is asking for auth you didn't supply (set CONDUCK_TOKEN=<key>)"
               else
                 why="HTTP 401 with the key you gave me — the server rejected it (typo? or an access layer in front wants its own login)"
               fi ;;
      # 403 split from 401 for the same reason as in --check-server: a server that WANTS auth
      # answers 401, while 403 means it read the request and refused it as it arrived. Telling
      # a keyless run to supply a token names the one thing that cannot be the cause.
      403)     if [ "${GW_AUTH:-}" = "none" ]; then
                 why="HTTP 403 and no key was sent — nothing to reject, so the request itself was refused as it arrived (a Host check? servers meant to be reached only from their own machine, Ollama above all, accept only a local name — make whatever fronts this one rewrite Host rather than forward it)"
               else
                 why="HTTP 403 — refused: either the key you gave me, or the request itself as it arrived (typo? an access layer in front? a Host check?)"
               fi ;;
      3??)     why="HTTP $MODELS_HTTP_CODE redirect — use the final server URL directly (the check does not forward your key across redirects)" ;;
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
    d_bad "${idp}_MISSING" "auth ($route): WITHOUT a key — no answer (the with-key request worked, so this looks like per-request trouble)"
  elif [ "$code" = "401" ]; then
    d_ok "${idp}_MISSING" "auth ($route): WITHOUT a key → 401 (enforced)"
    # Soft check only — the status is the load-bearing part; the body shape
    # decides how nice the app's error message can be, not whether auth holds.
    if ! printf '%s' "$body" | doctor_is_openai_error; then
      warn "  [${idp}_MISSING] …its 401 body isn't the OpenAI error shape — send {\"error\": {\"message\": …, \"type\": …}} (both non-empty) so the app can show a real message."
    fi
  elif [ "$code" = "200" ]; then
    d_bad "${idp}_MISSING" "auth ($route): WITHOUT a key → 200 — the server did the work anyway"
    d_say "${idp}_MISSING" "(this is the dangerous one: anyone who can reach this address can drive your AI and"
    d_say "${idp}_MISSING" " its tools. Check the Authorization header BEFORE doing anything else, on every route.)"
  else
    d_bad "${idp}_MISSING" "auth ($route): WITHOUT a key → HTTP $code (the contract pins exactly 401)"
  fi
  code=$(doctor_curl_negauth wrong -o /dev/null -w '%{http_code}' "$@" 2>/dev/null) || code=""
  DOCTOR_AUTH_WRONG_CODE="$code"
  case "$code" in
    401) d_ok "${idp}_WRONG" "auth ($route): WRONG key → 401 (enforced)" ;;
    200) d_bad "${idp}_WRONG" "auth ($route): WRONG key → 200 — the key isn't actually compared"
         d_say "${idp}_WRONG" "(compare byte-for-byte against the key you issued — e.g. hmac.compare_digest in Python)" ;;
    ""|000) d_bad "${idp}_WRONG" "auth ($route): WRONG key — no answer (a wide-open server may instead be running a slow agent turn on the probe — check its logs)" ;;
    *)   d_bad "${idp}_WRONG" "auth ($route): WRONG key → HTTP $code (the contract pins exactly 401)"
         doctor_auth_wrong_diagnose "${idp}_WRONG" "$code" "$@" ;;
  esac
}

# Auth must be ENFORCED, not merely accepted — on EVERY route the app calls.
# Testing only /v1/models would green-light a server that gates its model list
# but leaves the tool-running /v1/chat/completions wide open: the exact hole
# this check exists to catch. So both routes are probed. The chat probe carries
# a minimal body (auth is meant to reject before that body is PROCESSED — the
# bytes must still be consumed off the socket, or the connection closed; see
# doctor_desync_pair for what skipping that costs). If a vulnerable server
# instead RUNS the agent on the unauthenticated request, the probe still fails
# — either 200 (caught) or a >30s timeout reported as a failure (fail-safe,
# never a green pass).
doctor_auth_checks() {
  local body='{"messages":[{"role":"user","content":"conduck-connect auth probe"}],"stream":false}'
  if [ "$GW_AUTH" != "bearer" ]; then
    d_bad AUTH_NOT_ENFORCED "auth enforcement — untestable: you gave me no key, so I must assume the server is keyless"
    d_say AUTH_NOT_ENFORCED "(the contract requires a key on EVERY route — a keyless adapter that can run"
    d_say AUTH_NOT_ENFORCED " tools is wide open to whoever can reach it. Add a key check, then re-run me.)"
    return 0
  fi
  doctor_auth_route AUTH_MODELS "/v1/models" "$GW_URL/v1/models"
  doctor_auth_route AUTH_CHAT "/v1/chat/completions" "$GW_URL/v1/chat/completions" \
    -H "Content-Type: application/json" -d "$body"
  # Only a route that really REJECTED has a rejected body to be graded on, so
  # the counted check runs on the chat POST and only after its own wrong-token
  # probe answered 401. Never on /v1/models: a GET carries no body, so there is
  # nothing that could be left behind. When the 401 didn't happen, the failing
  # AUTH_CHAT_WRONG line already carries doctor_auth_wrong_diagnose's reading —
  # counting a second red for the same fault would just double-bill it.
  if [ "$DOCTOR_AUTH_WRONG_CODE" = "401" ]; then
    doctor_reject_body_check "$GW_URL/v1/chat/completions" \
      -H "Content-Type: application/json" -d "$body"
  fi
  return 0
}

# ---- one real chat turn: transport + grading, shared by every chat probe ----
#
# doctor_chat_request does the POST with the REAL token and lands status /
# content-type / timing / BODY in DCC_* globals (memory only: the body is
# never printed — these probes may run against a live personal agent, and this
# script never logs message content; graders emit verdict words and lengths).
#
# DCC_CURL_RC keeps curl's own exit code when the transfer never completed — a
# dead peer and a slow one are the same "no reply" to a caller that only sees
# rc 1, and that lossy bucket is exactly how an adapter killed mid-turn reads
# as a network fault. It is the WRAPPER's code: curl_gw returns 2 on its own
# credential guard before curl ever runs (preflight makes that unreachable
# here, but the code is not curl's to interpret if it ever fires).
DCC_CODE=""; DCC_CT=""; DCC_TIME=""; DCC_BODY=""; DCC_CURL_RC=0
# The Accept header the NEXT chat probe sends. An input, not a result — which is why
# doctor_chat_request never clears it with the DCC_* results below. Every check but one
# sends what Conduck sends. STREAM_SYNC alone asks for a stream, because the contract's
# "respond with plain JSON regardless of content negotiation" cannot be measured by a
# probe that only ever asks for JSON: an adapter that streams when the HEADER asks is
# invisible to it, and would pass a check it should fail. Whoever changes it restores
# it in the next line — a leaked value silently re-grades every later check.
DCC_ACCEPT="application/json"
doctor_chat_request() { # doctor_chat_request <payload-json> [max-seconds] -> 0 iff transfer completed
  local out tail_ max_time="${2:-300}"
  DCC_CODE=""; DCC_CT=""; DCC_TIME=""; DCC_BODY=""; DCC_CURL_RC=0
  # `out=$(…) || { rc=$?; }` on purpose: inside `if ! out=$(…); then` the `$?`
  # is the NEGATED status (0), and the real code would be lost.
  out=$(curl_gw -w '\n%{http_code} %{time_total} %{content_type}' "$GW_URL/v1/chat/completions" \
        --max-time "$max_time" -H "Accept: $DCC_ACCEPT" \
        -H "Content-Type: application/json" -d "$1" 2>/dev/null) || { DCC_CURL_RC=$?; return 1; }
  tail_="${out##*$'\n'}"; DCC_BODY="${out%$'\n'*}"
  DCC_CODE="${tail_%% *}"; tail_="${tail_#* }"
  DCC_TIME="${tail_%% *}"
  # safe_display here, at the parser's exit — the same rule models_is_json applies
  # to the header it captures. The value is whatever the server chose, curl does
  # not strip control bytes out of a header, and doctor_chat_eval echoes it into
  # the check transcript: a newline forges an extra "[CHECK_ID] …" line (a hostile
  # server printing its own green PASS) and an ANSI escape repaints the FAIL the
  # operator just read. Substring bounds cap length and strip nothing, so the bound
  # at the print site is not the guard. Sanitising the PARSER's output instead of
  # each print site means every later reader of DCC_CT inherits the clean value.
  # A real Content-Type is control-free and far inside the 200-char bound, so
  # ct_is_json's grading is unaffected.
  [ "$tail_" != "${tail_#* }" ] && DCC_CT=$(safe_display "${tail_#* }" 200)
  DCC_TIME=$(printf '%s' "$DCC_TIME" | awk '{printf "%.1f", $1}' 2>/dev/null)
  return 0
}

# What curl's exit code says about a transfer that never completed, in the
# words a builder can act on. Deliberately hedged where curl is: 7 covers a
# refused connection AND routing/firewall dead ends, and 52/56/18 are one story
# told at three moments (peer gone before any reply · connection broken while
# reading · reply cut off mid-body) — which one appears is decided by timing,
# TLS and any proxy, so none of them PROVES a dead process on its own. The
# caller's hint names that case; this line only reports what happened.
doctor_transfer_reason() { # doctor_transfer_reason <curl exit code>
  case "$1" in
    6)  printf 'the hostname did not resolve' ;;
    7)  printf 'could not connect to that address (refused, or blocked on the way)' ;;
    18) printf 'the reply stopped mid-body' ;;
    28) printf 'no complete answer within the time limit' ;;
    35) printf 'the TLS connection failed' ;;
    52) printf 'the server closed the connection without sending a reply' ;;
    55) printf 'the connection broke while the request was still being sent' ;;
    56) printf 'the connection broke while the reply was being read' ;;
    60) printf 'this machine does not trust the server certificate' ;;
    *)  printf 'transfer failed (curl exit %s)' "$1" ;;
  esac
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
DCE_REASON=""; DCE_HINT=""; DCE_LEN=""; DCE_TOKEN=""; DCE_NEAR=""
doctor_chat_eval() { # doctor_chat_eval <payload-json> [expected-digit-code]
  local exp="${2:--}" res verdict detail
  DCE_REASON=""; DCE_HINT=""; DCE_LEN=""; DCE_TOKEN=""; DCE_NEAR=""
  if ! doctor_chat_request "$1"; then
    # DCE_HINT stays exactly "transfer" — the file lane keys on that literal to
    # decide it may not grade the lane. The sub-case lives in DCC_CURL_RC.
    DCE_REASON=$(doctor_transfer_reason "$DCC_CURL_RC"); DCE_HINT="transfer"; return 1
  fi
  # SSE despite a synchronous request is its own diagnosis — a JSON parse
  # error would bury the actual mistake.
  case "$DCC_BODY" in data:*)
    DCE_REASON="the server answered with SSE framing"; DCE_HINT="sse"; return 1 ;;
  esac
  if [ "$DCC_CODE" != "200" ]; then
    case "$DCC_CODE" in
      3??) DCE_REASON="HTTP $DCC_CODE redirect — use the final server URL directly (the check does not forward your key across redirects)" ;;
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
    # Grade SIGHTING, not OCR -- the question is whether the picture reached the
    # engine, not whether the engine reads a 5x7 bitmap perfectly. An engine shown
    # no image says so; it does not land one glyph away from a six-digit code. So
    # one wrong position is forgiven. Exact-match alone called the picture unseen
    # on 31% of honest turns, measured against a proxy that cannot drop one.
    #
    # The CANDIDATE SET is where a tolerance turns dangerous, so it is narrow on
    # purpose. Exactly two things count as a read-back: a standalone run of the
    # right length, or single digits split by spaces or punctuation (7 2 8 4 3 1),
    # which is how some models answer. Digits scattered through a sentence are
    # NEVER stitched together -- otherwise "I cannot see an image, try again in
    # 8 to 2 minutes, ext 7" assembles a code out of unrelated numbers and a
    # refusal grades as a sighting. And a near miss is allowed only when the
    # reply offers exactly ONE distinct candidate: taking the best of many
    # numbers would hand the gateway one draw at the tolerance per number it
    # prints, so the odds below would stop describing anything. An exact hit
    # stands alone -- at six digits it is one in a million.
    #
    # EVERY spaced group is collected, and each one must be MAXIMAL -- no digit
    # and no separator+digit may sit on either side of it. Both halves are load
    # bearing, and neither is a style choice:
    #   * a first-match-only search let "maybe 7 2 8 4 3 0 or 7 2 8 4 3 5 or
    #     1 1 1 1 1 1, I cannot see the image" present ONE candidate, so the
    #     one-distinct-candidate rule passed and a refusal graded as a sighting;
    #   * an unanchored group let a ten-digit spray be windowed down to its
    #     first six, so "digits 1 2 3 4 5 6 7 8 9 0 shown" scored an exact hit.
    # The same rule lives in app_chat_body_eval; change both or neither.
    n = len(exp)
    runs = re.findall(r"\d+", c)
    cands = [r for r in runs if len(r) == n]
    for m in re.finditer(
            r"(?<!\d)(?<![\d][ .,\-])\d(?:[ .,\-]\d){%d}(?![ .,\-]?\d)" % (n - 1), c):
        cands.append(re.sub(r"\D", "", m.group(0)))
    if exp in cands:
        print("token %d" % len(c)); sys.exit(0)
    uniq = set(cands)
    # n >= 4 is not decoration: at n == 1 the threshold degenerates to "zero
    # positions must match", which every reply satisfies, including one with no
    # digits at all. The generator only ever draws NDIGITS, but this grader takes
    # whatever it is handed.
    if n >= 4 and len(uniq) == 1:
        only = uniq.pop()
        if sum(1 for a, b in zip(only, exp) if a == b) >= n - 1:
            print("near %d" % len(c)); sys.exit(0)
    print("notoken %d" % len(c)); sys.exit(0)
print("ok %d" % len(c))' "$exp" 2>/dev/null)
  verdict="${res%% *}"; detail="${res#* }"
  case "$verdict" in
    ok)      DCE_LEN="$detail"; return 0 ;;
    token)   DCE_LEN="$detail"; DCE_TOKEN="yes"; return 0 ;;
    near)    DCE_LEN="$detail"; DCE_TOKEN="yes"; DCE_NEAR="yes"; return 0 ;;  # saw it, misread one glyph
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

# The statuses that MIGHT mean "this request needs a model field". A status in
# here proves NOTHING on its own — it only buys the one controlled retry below the
# right to run, and that retry is the evidence. So this list exists to avoid
# wasting a five-minute turn, not to classify anything.
#
# 413 is deliberately NOT in it, and this list is deliberately NOT the one
# --check-server uses. Two separate reasons:
#   413 — the contract assigns it to a request-size / image-too-large limit, and
#     this check has a real diagnosis for that. Admitting it here would let a
#     genuine size limit be re-reported as "not graded" and bury the true cause.
#   --check-server keeps its own, wider list inline. It answers a different
#     question (can the app talk to this server) at a deliberately laxer bar, and
#     it already ships that behaviour; sharing one list would silently move a
#     verdict in a command this slice was not asked to change. Two questions, two
#     lists, each with its reason written next to it.
# This is also NOT "the set the app's model-required heuristic accepts": the app
# gates on those statuses AND then requires model-required prose in the body
# (RemoteAgentClient), so the status alone was never its rule either.
doctor_model_required_candidate_status() { # <http-status>
  case "$1" in 400|404|422) return 0 ;; esac
  return 1
}

# 0 iff the payload carries a top-level "model" key (absent and null both count
# as absent — the contract's rule is about the field the app didn't send).
doctor_payload_has_model() { # <payload-json>
  printf '%s' "$1" | python3 -c 'import json, sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if isinstance(d, dict) and d.get("model") is not None else 1)' 2>/dev/null
}

# Echo the payload with "model" set. Used to carry the advertised id on the
# probes that come AFTER the absent-model rule has already been graded.
doctor_payload_with_model() { # <payload-json> <model-id>
  printf '%s' "$1" | CONDUCK_CHECK_MODEL="$2" python3 -c 'import json, os, sys
req = json.load(sys.stdin)
req["model"] = os.environ["CONDUCK_CHECK_MODEL"]
print(json.dumps(req))' 2>/dev/null
}

# Did THIS payload only fail for want of a model? Re-sends the identical request
# with the first advertised id and nothing else changed: rc 0 means the model was
# the only thing missing — confirmed for this payload, not deduced from prose.
# Reading the error message instead would be guesswork (every adapter words it
# differently); one controlled retry is the evidence.
#
# The caller's DCC_*/DCE_* evidence is snapshotted and restored, because
# doctor_chat_eval overwrites those globals: without this the caller's own hints
# would describe the RETRY and not the model-less failure they are explaining.
doctor_model_required_probe() { # <payload-json>
  local payload="$1" retried rc=1
  local s_code="$DCC_CODE" s_ct="$DCC_CT" s_time="$DCC_TIME" s_body="$DCC_BODY" s_crc="$DCC_CURL_RC"
  local s_reason="$DCE_REASON" s_hint="$DCE_HINT" s_len="$DCE_LEN" s_token="$DCE_TOKEN" s_near="$DCE_NEAR"
  retried=$(doctor_payload_with_model "$payload" "$MODELS_FIRST_ID")
  if [ -n "$retried" ] && doctor_chat_eval "$retried"; then rc=0; fi
  DCC_CODE="$s_code"; DCC_CT="$s_ct"; DCC_TIME="$s_time"; DCC_BODY="$s_body"; DCC_CURL_RC="$s_crc"
  DCE_REASON="$s_reason"; DCE_HINT="$s_hint"; DCE_LEN="$s_len"; DCE_TOKEN="$s_token"; DCE_NEAR="$s_near"
  return $rc
}

# Every verdict reached on a probe that had to BORROW a model id says so, on the
# verdict itself. Without this the transcript and the machine summary both read as
# though the probe ran under the contract's own model-less conditions, which is
# the condition it could NOT run under — and a green line that quietly relaxed
# what it tested is the same defect as a red line with an invented cause. Cheap
# and unconditional on purpose: the note is skipped only when nothing was
# borrowed, so no verdict can carry a relaxed condition silently.
# $2 is the borrowed thing itself (the rewritten payload, or the id) — EMPTY means
# this probe borrowed nothing and the note must not fire. Gating on
# DOCTOR_MODEL_LANE alone would print it on CHAT_BASIC's own verdict, the one
# probe that really did run model-less and that latched the lane a line earlier.
doctor_carried_model_note() { # doctor_carried_model_note <check-id> <borrowed-or-empty>
  [ -n "$2" ] || return 0
  [ "$DOCTOR_MODEL_LANE" = "required" ] || return 0
  d_say "$1" "(measured with \"model\": \"$(safe_display "$DOCTOR_MODEL_LANE_ID" 60)\" supplied — this adapter"
  d_say "$1" " rejects the model-less request the contract asks for, which [CHAT_BASIC] grades)"
  return 0
}

# 0 iff the failure currently in DCC_*/DCE_* is one this run could NOT attribute:
# a model-less probe rejected the same way CHAT_BASIC was, on a run that could not
# separate "this adapter requires a model" from a fault of the rule being graded.
# Callers add "and this payload really was model-less" themselves.
doctor_unattributable_modelless() {
  [ "$DOCTOR_MODEL_LANE" = "unattributable" ] || return 1
  [ "$DCE_HINT" = "http" ] || return 1
  doctor_model_required_candidate_status "$DCC_CODE"
}

# One graded chat check with its verdict line + failure hints. kind picks the
# failure explanation: plain (the tolerance turn) · history (the
# anti-poisoning turn) · stream ("stream": true).
#
# DCC_VERDICT carries the CAPABILITY verdict for the machine summary, which is
# not always the verdict line: PASS · FAIL · NOT_RUN when the probe failed for a
# cause this run could not attribute to the rule the check exists to grade. A
# capability the run could not measure must never be reported as failing it.
DCC_VERDICT="NOT_RUN"

# The capability meter for the check doctor_chat_check just graded. Fill a
# machine-summary meter from THIS, never from doctor_chat_check's exit status:
# that status answers "did this check go red", which is a different question from
# "what did this run measure". NOT_RUN is the honest answer when the probe failed
# for a cause this run could not tell apart from another rule's failure.
doctor_capability_meter() { printf '%s' "$DCC_VERDICT"; }
doctor_chat_check() { # doctor_chat_check <check-id> <label> <payload-json> <kind>
  local id="$1" label="$2" payload="$3" kind="${4:-plain}" modelless=false carried=""
  DCC_VERDICT="NOT_RUN"
  doctor_payload_has_model "$payload" || modelless=true
  # Once CHAT_BASIC has established that this adapter requires the field, every
  # later model-less probe carries the advertised id. Without it they all fail
  # for CHAT_BASIC's reason and none of them measures anything. This mirrors
  # --check-server, which carries the advertised id on every probe after it
  # learns the server requires one.
  if $modelless && [ "$DOCTOR_MODEL_LANE" = "required" ]; then
    carried=$(doctor_payload_with_model "$payload" "$DOCTOR_MODEL_LANE_ID")
    if [ -n "$carried" ]; then payload="$carried"; modelless=false; fi
  fi
  if doctor_chat_eval "$payload"; then
    DCC_VERDICT="PASS"
    [ "$id" = "CHAT_BASIC" ] && DOCTOR_MODEL_LANE="tolerated"
    d_ok "$id" "$label — one choice, non-empty string content (${DCE_LEN:-?} chars, ${DCC_TIME:-?}s)"
    doctor_carried_model_note "$id" "$carried"
    return 0
  fi
  DCC_VERDICT="FAIL"
  # The absent-model question, decided ONCE, by CHAT_BASIC only (see
  # DOCTOR_MODEL_LANE). A later probe must never latch it.
  if [ "$id" = "CHAT_BASIC" ] && $modelless && [ "$DCE_HINT" = "http" ] \
     && doctor_model_required_candidate_status "$DCC_CODE"; then
    if [ -n "$MODELS_FIRST_ID" ] && doctor_model_required_probe "$payload"; then
      DOCTOR_MODEL_LANE="required"; DOCTOR_MODEL_LANE_ID="$MODELS_FIRST_ID"
    else
      DOCTOR_MODEL_LANE="unattributable"
    fi
  fi
  d_bad "$id" "$label — $DCE_REASON"
  doctor_carried_model_note "$id" "$carried"
  # A model-less probe that failed the same way CHAT_BASIC did, on a run that
  # could not attribute that failure: the honest answer is that this check was
  # not graded — never a story about the rule it happens to be named after.
  if $modelless && [ "$id" != "CHAT_BASIC" ] && doctor_unattributable_modelless; then
    DCC_VERDICT="NOT_RUN"
    d_say "$id" "(this request deliberately carries no \"model\" field, and [CHAT_BASIC] above was"
    d_say "$id" " rejected the same way, so this run can't tell the two rules apart — it is NOT"
    d_say "$id" " grading this one. Fix that failure first, then re-run me.)"
    return 1
  fi
  case "$DCE_HINT" in
    sse)
      case "$kind" in
        stream) d_say "$id" "(this request asked for a stream TWICE — \"stream\": true in the body, and an"
                d_say "$id" " Accept header naming text/event-stream — and both must be ignored. Conduck"
                d_say "$id" " always sends \"stream\": false with Accept: application/json and never decodes"
                d_say "$id" " SSE, so answer ONE complete JSON object however a client asks. Look for a"
                d_say "$id" " branch on either the flag or the Accept header and delete it; if your engine"
                d_say "$id" " streams, consume its stream yourself and send the finished text in one body)" ;;
        *)      d_say "$id" "(when stream is false, answer with ONE complete JSON object — Conduck never accepts SSE)" ;;
      esac ;;
    transfer)
      case "$DCC_CURL_RC" in
        7|18|52|55|56)
          d_say "$id" "(from out here a dead adapter and a broken network look identical — and it is usually"
          d_say "$id" " the adapter: backgrounded from a terminal it dies with that shell or gets reaped"
          d_say "$id" " mid-turn, and every later check then reports transport trouble that has nothing to do"
          d_say "$id" " with the contract. Check it is still running, then keep it under something that"
          d_say "$id" " restarts it — systemd, launchd, pm2, docker restart=always — before re-running me.)" ;;
        28)
          d_say "$id" "(nothing complete came back before the deadline — either the turn genuinely runs longer"
          d_say "$id" " than that, or the adapter is wedged on this request. Its own log holds the request it"
          d_say "$id" " never finished; Conduck gives up too, so a turn this slow fails in the app as well.)" ;;
        35|60)
          d_say "$id" "(the HTTPS front refused the connection, so the adapter behind it was never reached —"
          d_say "$id" " run me ON the server against http://127.0.0.1:<port> to test the adapter itself first)" ;;
      esac ;;
    http)
      # A 5xx from a front-end proxy is about that proxy's UPSTREAM, never about
      # the contract rule this request was testing — so it pre-empts the
      # per-kind hints. Otherwise a dead adapter during the history turn reads
      # as "you rejected the historical image", which is a wild-goose chase.
      case "$DCC_CODE" in
        502|503)
          d_say "$id" "(a $DCC_CODE is the HTTPS front talking, not your adapter: the front is up but got"
          d_say "$id" " nothing usable out of the adapter behind it. Most often that process is gone —"
          d_say "$id" " backgrounded with no supervisor, or crashed on this turn — or it is bound to a"
          d_say "$id" " different port than the front sends to; an overloaded or restarting adapter looks"
          d_say "$id" " the same. Check it is running and supervised, then re-run me.)"
          return 1 ;;
        504)
          d_say "$id" "(a 504 is the HTTPS front giving up on your adapter. Either the turn outruns the"
          d_say "$id" " front's proxy timeout — agent turns are slow, raise it — or the adapter is wedged"
          d_say "$id" " on this request and its own log will say so.)"
          return 1 ;;
        413)
          # The contract spends 413 on a request-size limit, and a server that
          # answers one has STATED its cause. Telling the reader instead that they
          # reject historical images, or refuse the stream flag, is the same defect
          # as any other invented explanation — so the stated cause pre-empts every
          # per-kind story, exactly as the front-end 5xx statuses do above.
          d_say "$id" "(a 413 is a request-size limit answering, not a judgement on this request's shape."
          d_say "$id" " The probe images here are tiny, so the limit is almost always in FRONT of the"
          d_say "$id" " adapter — raise the reverse proxy's max body size (nginx client_max_body_size,"
          d_say "$id" " Caddy request_body). Conduck sends real photos, which are far larger than this.)"
          return 1 ;;
      esac
      # The one cause that would otherwise be told three different ways, none of
      # them true: this adapter requires the field the contract makes optional.
      # A retry confirmed it for this exact payload, so it is said once, plainly,
      # and never dressed up as a history-poisoning or streaming fault.
      if [ "$id" = "CHAT_BASIC" ] && [ "$DOCTOR_MODEL_LANE" = "required" ]; then
        d_say "$id" "(the identical request answered normally as soon as \"model\": \"$(safe_display "$DOCTOR_MODEL_LANE_ID" 60)\" was"
        d_say "$id" " supplied, so this adapter REQUIRES that field — and that is the ONLY fault this request"
        d_say "$id" " shows. The contract makes it optional: with no \"model\", pick your own default and answer."
        d_say "$id" " The remaining chat checks carry that id, so each grades its own rule instead of failing"
        d_say "$id" " again for this one.)"
        return 1
      fi
      case "$kind" in
        history)
          d_say "$id" "(the contract forbids rejecting a request because of an image in an EARLIER message —"
          d_say "$id" " forward it to the engine, or replace it in place with the contract's disclosure text."
          d_say "$id" " A text-only newest message must always get an answer: one rejected photo must never"
          d_say "$id" " poison every later turn of the conversation.)" ;;
        stream)
          d_say "$id" "(neither \"stream\": true nor an Accept header naming text/event-stream may be"
          d_say "$id" " rejected — ignore both and answer one synchronous JSON object, exactly as for"
          d_say "$id" " stream:false. A 406 here is the same defect as an SSE body: the contract says"
          d_say "$id" " answer with plain JSON regardless of content negotiation)" ;;
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

# --deep's semantic image probe. A PNG rendered HERE (stdlib zlib/struct — 6
# random digits as big block glyphs, black on white, ~920×232) rides the
# newest message; the digits are never in the prompt, filename, or metadata,
# so the ONLY way to answer them is to actually see the image. Outcomes:
#   VERIFIED   — 200 and the reply reads the digits back, allowing ONE wrong
#                position: the engine truly sees images (OCR tooling counts —
#                this grades capability, not eyes). The tolerance is not
#                leniency; it is what separates the two questions. An engine
#                shown no picture answers that it cannot see one, it does not
#                land within one glyph of six, so a near miss still proves
#                sighting while exact-match alone failed conforming gateways on
#                31% of honest turns. See the threshold note in doctor_chat_eval.
#   DECLINED   — HTTP 400 + OpenAI error body + code "image_unsupported": a
#                text-only adapter refusing honestly. Allowed, passes.
#   UNVERIFIED — 200 but the digits aren't in the reply: this run could not
#                verify the engine used the image. Two different faults reach
#                this same answer — the image never got to the engine, or it
#                got to one that misread it — and a black-box probe cannot
#                separate them, so it names both and diagnoses neither. Fails
#                the deep profile either way: the app cannot tell this reply
#                from a real sighting, so an unproven one is as unusable as
#                the forbidden silent drop it may or may not be.
# Anything else (wrong/missing decline code, other statuses, bad shape) FAILs:
# clients key on the machine code, so "looks declined" isn't good enough.
# One wrong position is forgiven, so a blind guess passes about 1 in 16,700 —
# stronger than the ~1-in-9,000 the older exact four-digit rule allowed, because
# the code grew to six digits when the tolerance appeared. The reply's content is
# never printed.
# Build the semantic image probe (shared by --deep and --check-server): sets
# IPG_CODE (the digits, NDIGITS of them) and IPG_PAYLOAD (the chat request
# carrying the PNG).
# $CONDUCK_PROBE_MODEL adds a "model" field when it is non-empty. EVERY caller
# sets it explicitly, because the python reads the ENVIRONMENT: a caller that
# merely omits it inherits whatever the operator happened to export, which
# silently changes the request being graded. The compat probe threads the
# advertised id through once it learns the server requires one; the doctor sets
# it EMPTY (contract: an absent model must be tolerated).
image_probe_gen() {
  local gen
  gen=$(python3 -c '
import json, os, zlib, struct, base64, random
# Two glyphs are drawn against convention, and both choices are measured against
# a thin proxy that CANNOT drop an image, so every miss there is the drawing and
# not the gateway. The ZERO carries no slash: the diagonal is a programmer-font
# habit for telling 0 from O, there is no O in a numeric code, and at 5x7 it
# fills the counter so the digit reads as 8, 9, 6, 5 or 2. The THREE has open
# arcs and a full centre bar; the original flat-top 3 was a 7 with a hook and was
# read as 7, 2 and 5. Those two accounted for 10 of 12 misreads over 40 samples.
#
# The 3 is drawn the way it is for a SECOND reason, and this is the trap: the
# obvious replacement — a round-topped 3 — is an 8 with its left side missing.
# It measured well and is still wrong, because it puts 3 and 8 three cells apart
# in a 35-cell grid, with all three differing cells isolated singletons. That is
# the feature scale an image encoder loses first.
#
# The closest pair this table actually keeps is 0/8 at FIVE cells, and the count
# alone is not what makes it safe: those five cells are one contiguous horizontal
# bar — the waist stroke of 8, which 0 omits — not the singletons the 3/8 case
# warns about. A whole stroke is the feature an encoder loses LAST. Contiguity,
# not distance, is the property to preserve; a single 0<->8 misread is also
# exactly what the one-wrong-position tolerance absorbs. probe_font_mirror pins
# both the table and that 5-cell minimum, so a restyle fails loudly rather than
# silently narrowing the gap — but re-measure the recognition rate too, which no
# test can do for you.
FONT = {
    "0": [14, 17, 17, 17, 17, 17, 14], "1": [4, 12, 4, 4, 4, 4, 14],
    "2": [14, 17, 1, 2, 4, 8, 31],     "3": [30, 1, 1, 14, 1, 1, 30],
    "4": [2, 6, 10, 18, 31, 2, 2],     "5": [31, 16, 30, 1, 1, 17, 14],
    "6": [6, 8, 16, 30, 17, 17, 14],   "7": [31, 1, 2, 4, 8, 8, 8],
    "8": [14, 17, 17, 14, 17, 17, 14], "9": [14, 17, 17, 15, 1, 2, 12],
}
SCALE, MARGIN, GAP = 16, 60, 64  # wide GAP is load-bearing: at GAP=24 real
# vision models systematically misread adjacent glyphs (measured 1/6 correct at
# GAP=24 — tight spacing reads as merged segments). Widening it did NOT make the
# probe reliable on its own: at GAP=64 the same font still scored 27/40 exact on
# gpt-5.6-luna, because the remaining errors were single-glyph, not spacing. That
# is what the 0 and 3 above fix; spacing and glyph shape are separate faults and
# each was measured on its own.
GW, GH = 5 * SCALE, 7 * SCALE
# SIX digits, not four, and the count is what pays for the one-glyph tolerance
# below. Four digits with one position forgiven accepts a blind guess at about
# 1 in 250 — weaker than the 1 in 9,000 an exact four-digit match gave, which is
# a real cost for a check that certifies a capability. Six digits with the same
# tolerance is about 1 in 16,700: STRONGER than the exact rule it replaces, while
# the tolerance still absorbs the single-glyph misreads that were failing honest
# gateways. Longer is not free — every extra glyph is another chance to misread,
# and measured over 60 live turns on two models six digits with one forgiven was
# 60/60 while six exact was 51/60. Changing NDIGITS changes the guarantee; the
# odds quoted in the header and to the operator are computed for this value.
NDIGITS = 6
W, H = MARGIN * 2 + NDIGITS * GW + (NDIGITS - 1) * GAP, MARGIN * 2 + GH
code = str(random.randint(1, 9)) + "".join(str(random.randint(0, 9))
                                           for _ in range(NDIGITS - 1))
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
  # Set explicitly, never inherited. $CONDUCK_PROBE_MODEL is internal plumbing for
  # handing a value to python without argv, and the probe's python reads the
  # ENVIRONMENT — so a variable the operator happens to have exported would
  # silently put a "model" field in this request and move the verdict for a reason
  # the adapter author cannot see. It is EMPTY by default, because the contract
  # makes tolerating an absent model a requirement and CHAT_BASIC is what grades
  # that rule. It carries the advertised id only once CHAT_BASIC has established
  # that this adapter requires the field: otherwise this probe fails for CHAT_BASIC's
  # reason and reports a vision fault the run never measured.
  CONDUCK_PROBE_MODEL="$DOCTOR_MODEL_LANE_ID" image_probe_gen
  code="$IPG_CODE"; payload="$IPG_PAYLOAD"
  if doctor_chat_eval "$payload" "$code"; then
    if [ "$DCE_TOKEN" = "yes" ]; then
      DOCTOR_IMAGE_INPUT="VERIFIED"
      if [ "${DCE_NEAR:-}" = "yes" ]; then
        # Say that one glyph was misread rather than quietly rounding it up. The
        # capability is proven either way — an engine shown nothing cannot come
        # within one digit of six — but an adapter author comparing two runs
        # deserves to know which was exact. Every route that grades this probe
        # says so: --check-server and the setup gate print their own version.
        d_ok "$id" "image input — the reply reads the digits back, one glyph misread (VERIFIED, ${DCC_TIME:-?}s)"
      else
        d_ok "$id" "image input — the reply reads the digits back (VERIFIED, ${DCC_TIME:-?}s)"
      fi
      doctor_carried_model_note "$id" "$DOCTOR_MODEL_LANE_ID"
      return 0
    fi
    DOCTOR_IMAGE_INPUT="UNVERIFIED"
    d_bad "$id" "image input — answered 200, but the reply doesn't contain the image's digits (${DCE_LEN:-?} chars)"
    # What this probe can and cannot establish. It proves the ABSENCE of evidence
    # that the engine used the image; it does not observe where the image went.
    # Naming a cause anyway sends the reader to one place: an earlier wording said
    # the image "was silently dropped somewhere", and an adapter that forwarded it
    # faithfully to a model too weak to read the glyphs got that same sentence and
    # audited its forwarding path for a fault that was never there. Two adapters
    # with different internals produced identical verdicts on a live run.
    d_say "$id" "(this run could not verify that the engine used the image — that is all a 200 without the"
    d_say "$id" " digits proves. It may never have reached the engine, or it may have reached one that"
    d_say "$id" " misread it; from out here those are the same answer, so check the forwarding path AND the"
    d_say "$id" " engine's own vision. Unproven still fails: the app cannot tell this reply from a real"
    d_say "$id" " sighting either. Forward images to the engine, or decline honestly with HTTP 400 + an"
    d_say "$id" " error body carrying code \"image_unsupported\" — never answer as if no image was attached.)"
    doctor_carried_model_note "$id" "$DOCTOR_MODEL_LANE_ID"
    return 1
  fi
  if [ "$DCC_CODE" = "400" ] && printf '%s' "$DCC_BODY" | doctor_is_openai_error \
     && printf '%s' "$DCC_BODY" | doctor_error_code "image_unsupported"; then
    DOCTOR_IMAGE_INPUT="DECLINED"
    d_ok "$id" "image input — declined with HTTP 400 + code \"image_unsupported\" (honest refusal, allowed)"
    doctor_carried_model_note "$id" "$DOCTOR_MODEL_LANE_ID"
    return 0
  fi
  # Same rule as the chat probes, and it is asked BEFORE the decline is graded: an
  # adapter that requires a model answers this model-less probe with a 400 and a
  # perfectly well-formed error body, which the branch below would otherwise read
  # as a dishonest image decline — a vision verdict on a run that never reached the
  # engine's eyes at all. Not measured means NOT_RUN.
  if doctor_unattributable_modelless; then
    DOCTOR_IMAGE_INPUT="NOT_RUN"
    d_bad "$id" "image input — $DCE_REASON"
    d_say "$id" "(this request also carries no \"model\" field, and [CHAT_BASIC] above was rejected the same"
    d_say "$id" " way, so this run can't tell the two rules apart — it is NOT grading image input. Fix that"
    d_say "$id" " failure first, then re-run me.)"
    return 1
  fi
  if [ "$DCC_CODE" = "400" ] && printf '%s' "$DCC_BODY" | doctor_is_openai_error; then
    DOCTOR_IMAGE_INPUT="FAIL"
    d_bad "$id" "image input — declined with HTTP 400, but without code \"image_unsupported\""
    d_say "$id" "(the decline itself is allowed — but the app keys on the machine code to explain the"
    d_say "$id" " refusal and offer recovery, so add \"code\": \"image_unsupported\" to the error object)"
    doctor_carried_model_note "$id" "$DOCTOR_MODEL_LANE_ID"
    return 1
  fi
  DOCTOR_IMAGE_INPUT="FAIL"
  d_bad "$id" "image input — $DCE_REASON"
  doctor_carried_model_note "$id" "$DOCTOR_MODEL_LANE_ID"
  return 1
}
