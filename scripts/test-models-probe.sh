#!/usr/bin/env bash
# Functional test of models_is_json's return codes + diagnostics globals.
# Usage: bash test-models-probe.sh /path/to/conduck-connect.sh
set -u -o pipefail
SCRIPT="${1:-conduck-connect.sh}"   # default: run from the repo root

# Mock server: path prefix decides the reply for <prefix>/v1/models.
# The port is OS-assigned (bind to 0) and reported through PORT_FILE, so parallel
# runs and an unrelated listener on the host can never collide with this fixture.
PORT_FILE=$(mktemp "${TMPDIR:-/tmp}/conduck-models-probe.XXXXXX") || exit 2
CONDUCK_PORT_FILE="$PORT_FILE" python3 - <<'PY' &
import http.server, json, os, socketserver

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        cases = {
            "/ok/v1/models":     (200, "application/json", '{"object":"list","data":[{"id":"m","object":"model"}]}'),
            "/accepted/v1/models": (203, "application/json", '{"object":"list","data":[{"id":"m","object":"model"}]}'),
            "/empty/v1/models":  (200, "application/json", '{"object":"list","data":[]}'),
            "/noid/v1/models":   (200, "application/json", '{"object":"list","data":[{"object":"model"}]}'),
            "/bare/v1/models":   (200, "application/json", '["m1","m2"]'),
            "/models/v1/models": (200, "application/json", '{"models":[{"id":"m"}]}'),
            "/html/v1/models":   (200, "text/html", "<!DOCTYPE html><html><body>control ui</body></html>"),
            "/auth/v1/models":   (401, "application/json", '{"error":{"message":"bad token"}}'),
            "/text/v1/models":   (200, "text/plain", "hello there"),
        }
        code, ctype, body = cases.get(self.path, (404, "application/json", '{"error":{"message":"nope"}}'))
        if self.path == "/accept/v1/models" and self.headers.get("Accept") != "application/json":
            code, ctype, body = 406, "application/json", '{"error":{"message":"Accept required"}}'
        elif self.path == "/accept/v1/models":
            code, ctype, body = 200, "application/json", '{"object":"list","data":[]}'
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

class S(http.server.HTTPServer):
    # server_bind() reverse-resolves the bind address (socket.getfqdn), which
    # blocks until the resolver gives up on a CI runner with no reverse zone for
    # 127.0.0.1 — ~20s, before the port file is ever written. server_name is
    # CGI-only and this fixture never reads it.
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]

srv = S(("127.0.0.1", 0), H)
with open(os.environ["CONDUCK_PORT_FILE"], "w") as fh:
    fh.write("%d\n" % srv.server_address[1])
srv.serve_forever()
PY
SRV=$!
# The wait is what keeps the run readable: without it the shell reports the
# killed fixture by echoing the whole heredoc to stderr, burying the results.
trap '{ kill "$SRV"; wait "$SRV"; } 2>/dev/null; rm -f "$PORT_FILE"' EXIT

# Readiness poll instead of a blind sleep: a fixed nap either wastes a second or,
# on a loaded CI runner, starts probing before the socket is listening.
PORT=""
i=0
while [ "$i" -lt 200 ]; do
  if ! kill -0 "$SRV" 2>/dev/null; then
    printf 'FAIL mock server exited before it became ready\n'; exit 2
  fi
  [ -s "$PORT_FILE" ] && PORT=$(tr -dc '0-9' < "$PORT_FILE")
  if [ -n "$PORT" ] && curl -sf -o /dev/null "http://127.0.0.1:$PORT/ok/v1/models"; then
    break
  fi
  PORT=""
  sleep 0.1
  i=$((i + 1))
done
[ -n "$PORT" ] || { printf 'FAIL mock server never answered on 127.0.0.1 (20s)\n'; exit 2; }

# A port nothing listens on, for the connection-refused case: bind 0, read the
# assignment, release it, then confirm curl really gets ECONNREFUSED (rc 7).
CLOSED=""
i=0
while [ "$i" -lt 5 ]; do
  candidate=$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()') || break
  rc=0; curl -s -o /dev/null --max-time 5 "http://127.0.0.1:$candidate" || rc=$?
  if [ "$rc" = 7 ]; then CLOSED="$candidate"; break; fi
  i=$((i + 1))
done
[ -n "$CLOSED" ] || { printf 'FAIL could not find a closed port for the refused-connection case\n'; exit 2; }

# Pull in the functions under test, the helpers they call, and the vars curl_gw
# expects. Each extraction is asserted non-empty: a renamed or relocated helper
# fails the suite here, rather than surfacing as a "command not found" mid-probe
# that leaves a diagnostic global silently empty while the assertions still pass.
for fn in curl_gw models_is_json safe_display; do
  fn_body=$(sed -n "/^$fn()/,/^}/p" "$SCRIPT")
  [ -n "$fn_body" ] || { printf 'FAIL could not extract %s() from the built artifact\n' "$fn"; exit 2; }
  eval "$fn_body"
done
MODELS_CURL_RC=0; MODELS_HTTP_CODE=""; MODELS_DATA_EMPTY=false
MODELS_NO_VALID_ID=false
# MODELS_TIME/DOCTOR/COMPAT are read only inside the eval'd functions — export keeps
# the unused-variable lint quiet (same pattern as the TRANSPORT line below).
export MODELS_TIME="" DOCTOR=false COMPAT=false
# Consumed by the eval'd curl_gw / models_is_json (export: they read, we set).
export TRANSPORT="public" GW_AUTH="none" GW_TOKEN="" GW_CERT_FP=""

fail=0
probe() { # probe <label> <url> <want_rc> <want_empty> <want_http-or-'-'> <want_curl-or-'-'>
  local rc=0; models_is_json "$2" || rc=$?
  local got="rc=$rc empty=$MODELS_DATA_EMPTY http=${MODELS_HTTP_CODE:--} curl=$MODELS_CURL_RC"
  local ok=1
  [ "$rc" = "$3" ] || ok=0
  [ "$MODELS_DATA_EMPTY" = "$4" ] || ok=0
  [ "$5" = "-" ] || [ "${MODELS_HTTP_CODE:--}" = "$5" ] || ok=0
  [ "$6" = "-" ] || [ "$MODELS_CURL_RC" = "$6" ] || ok=0
  if [ "$ok" = 1 ]; then printf 'ok   %-14s %s\n' "$1" "$got"
  else printf 'FAIL %-14s %s (want rc=%s empty=%s http=%s curl=%s)\n' "$1" "$got" "$3" "$4" "$5" "$6"; fail=1; fi
}

B="http://127.0.0.1:$PORT"
probe canonical      "$B/ok"     0 false 200 0
probe accepted-2xx   "$B/accepted" 0 false 203 0
probe accept-header  "$B/accept" 0 true 200 0
# Adapter conformance pins exactly HTTP 200 even though the app accepts any 2xx.
DOCTOR=true
probe adapter-200   "$B/accepted" 1 false 203 0
DOCTOR=false
probe empty-list     "$B/empty"  0 true  200 0
# Structurally valid but no entry carries a usable string id — rc stays 0, the
# MODELS_NO_VALID_ID diagnostic global is the signal (--check-adapter fails on it).
probe no-valid-id    "$B/noid"   0 false 200 0
if [ "$MODELS_NO_VALID_ID" != "true" ]; then
  printf 'FAIL no-valid-id    MODELS_NO_VALID_ID=%s (want true)\n' "$MODELS_NO_VALID_ID"; fail=1
fi
MODELS_NO_VALID_ID=false
probe bare-array     "$B/bare"   3 false 200 0
probe models-shape   "$B/models" 3 false 200 0
probe html-page      "$B/html"   2 false 200 0
probe rejected-401   "$B/auth"   1 false 401 0
probe non-json-200   "$B/text"   1 false 200 0
probe missing-404    "$B/nope"   1 false 404 0
probe conn-refused   "http://127.0.0.1:$CLOSED" 1 false - 7

exit "$fail"
