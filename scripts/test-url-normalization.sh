#!/usr/bin/env bash
# Parity fixtures for normalize_gateway_base_url — each case mirrors an
# assertion in the app's SettingsViewModelGatewayValidationTests.swift.
# Usage: bash test-url-normalization.sh /path/to/conduck-connect.sh
set -u -o pipefail

SCRIPT="${1:-conduck-connect.sh}"   # default: run from the repo root

# Extract just the function under test (the script's main() must not run).
fn=$(sed -n '/^normalize_gateway_base_url()/,/^}/p' "$SCRIPT")
[ -n "$fn" ] || { echo "FATAL: normalize_gateway_base_url not found in $SCRIPT"; exit 2; }
eval "$fn"

fail=0
check() { # check <input> <expected>
  local got; got=$(normalize_gateway_base_url "$1")
  if [ "$got" = "$2" ]; then
    printf 'ok   %s -> %s\n' "$1" "$got"
  else
    printf 'FAIL %s -> %s (expected %s)\n' "$1" "$got" "$2"
    fail=1
  fi
}

# testStripsTerminalChatCompletionsPath
check "https://gw.example.test/v1/chat/completions" "https://gw.example.test"
# testStripsTerminalModelsPath
check "https://gw.example.test/v1/models" "https://gw.example.test"
# testStripsTerminalV1Path
check "https://gw.example.test/v1" "https://gw.example.test"
# testStripsTrailingSlash
check "https://gw.example.test/" "https://gw.example.test"
check "https://gw.example.test/v1/" "https://gw.example.test"
# testPreservesLegitimatePathPrefix
check "https://gw.example.test/openclaw" "https://gw.example.test/openclaw"
# testStripsV1FromBeneathAPathPrefix
check "https://gw.example.test/openclaw/v1" "https://gw.example.test/openclaw"
check "https://gw.example.test/openclaw/v1/chat/completions" "https://gw.example.test/openclaw"
# testPreservesPort
check "https://gw.example.test:18789/v1" "https://gw.example.test:18789"
check "https://gw.example.test:18789" "https://gw.example.test:18789"
# testDoesNotStripNonTerminalOrPartialMatches
check "https://v1.example.test" "https://v1.example.test"
check "https://gw.example.test/v1/models/extra" "https://gw.example.test/v1/models/extra"
check "https://gw.example.test/apiv1" "https://gw.example.test/apiv1"
# testDropsQueryAndFragment
check "https://gw.example.test/v1?key=abc#frag" "https://gw.example.test"
# percent-encoded /v1 — Foundation's URLComponents.path decodes, so the app
# strips it; the script must match (Codex verify finding #2)
check "https://gw.example.test/%76%31" "https://gw.example.test"
check "https://gw.example.test/openclaw/%76%31" "https://gw.example.test/openclaw"
# an encoded segment that survives must keep its original encoding
check "https://gw.example.test/open%20claw/v1" "https://gw.example.test/open%20claw"

exit "$fail"
