#!/usr/bin/env bash
# Functional test of models_is_json's return codes + diagnostics globals.
# Usage: bash test-models-probe.sh /path/to/conduck-connect.sh
set -u -o pipefail
SCRIPT="${1:-conduck-connect.sh}"   # default: run from the repo root

# Mock server: path prefix decides the reply for <prefix>/v1/models.
python3 - <<'PY' &
import http.server, json

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        cases = {
            "/ok/v1/models":     (200, "application/json", '{"object":"list","data":[{"id":"m","object":"model"}]}'),
            "/empty/v1/models":  (200, "application/json", '{"object":"list","data":[]}'),
            "/noid/v1/models":   (200, "application/json", '{"object":"list","data":[{"object":"model"}]}'),
            "/bare/v1/models":   (200, "application/json", '["m1","m2"]'),
            "/models/v1/models": (200, "application/json", '{"models":[{"id":"m"}]}'),
            "/html/v1/models":   (200, "text/html", "<!DOCTYPE html><html><body>control ui</body></html>"),
            "/auth/v1/models":   (401, "application/json", '{"error":{"message":"bad token"}}'),
            "/text/v1/models":   (200, "text/plain", "hello there"),
        }
        code, ctype, body = cases.get(self.path, (404, "application/json", '{"error":{"message":"nope"}}'))
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

http.server.HTTPServer(("127.0.0.1", 8971), H).serve_forever()
PY
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
sleep 1

# Pull in the functions under test + the vars curl_gw expects.
fn_curl=$(sed -n '/^curl_gw()/,/^}/p' "$SCRIPT")
fn_probe=$(sed -n '/^models_is_json()/,/^}/p' "$SCRIPT")
eval "$fn_curl"; eval "$fn_probe"
MODELS_CURL_RC=0; MODELS_HTTP_CODE=""; MODELS_DATA_EMPTY=false
MODELS_NO_VALID_ID=false
# MODELS_TIME/DOCTOR are read only inside the eval'd functions — export keeps
# the unused-variable lint quiet (same pattern as the TRANSPORT line below).
export MODELS_TIME="" DOCTOR=false
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

B="http://127.0.0.1:8971"
probe canonical      "$B/ok"     0 false 200 0
probe empty-list     "$B/empty"  0 true  200 0
# Structurally valid but no entry carries a usable string id — rc stays 0, the
# MODELS_NO_VALID_ID diagnostic global is the signal (--doctor fails on it).
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
probe conn-refused   "http://127.0.0.1:8972" 1 false - 7

exit "$fail"
