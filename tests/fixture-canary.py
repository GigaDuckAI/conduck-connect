#!/usr/bin/env python3
"""fixture-canary.py — the delayed-response rail canary. stdlib only, loopback only.

A doctor-conformant adapter (ordinary AND deep doctor exit 0) whose engine can
hold a response SILENTLY for a per-turn delay, then reply deterministically.
Purpose: measure whether an exposure rail (Tailscale Serve/Funnel, nginx,
Cloudflare, ...) kills long silent HTTP responses — the shape of a real agent
turn. It is text-only (declines current-turn images with code
"image_unsupported"; replaces earlier images with the canonical disclosure),
which the deep doctor accepts as an honest DECLINED pass.

Usage:
    CONDUCK_TOKEN=<token> python3 fixture-canary.py [--port 8498] [--version]

The token comes from $CONDUCK_TOKEN only (never argv). Binds 127.0.0.1 only —
exposure is the wizard's job (Serve/Funnel/reverse proxy in front). Prints one
"READY <port>" line on stdout when listening. Never logs message content;
lifecycle lines (codes only) go to stderr for canary-directive turns.

Delay directive — parsed from the NEWEST user message only (plain-string
content or the text parts joined with a newline):
    Conduck canary, wait 180 seconds, nonce ABC123
Rules: the word "canary" must appear (case-insensitive) AND at least one
"wait <N> [s|sec|seconds]" phrase; exactly ONE delay phrase and at most one
"nonce <token>" ([A-Za-z0-9]{4,32}); N must be 1..600 — out-of-range or
ambiguous directives get an IMMEDIATE reply marked INVALID_DIRECTIVE (never a
silent clamp, so a mis-transcribed voice command can't fake a green run).
Messages without the directive answer instantly (pairing and doctor turns are
unaffected). Reply format (nonce last, echoed only when supplied):
    CANARY v1.0.0 turn_id=<hex8> delay_requested=180s elapsed=180.02s nonce=ABC123

Server-side lifecycle lines are CORROBORATION ONLY: a successful local socket
write proves the kernel accepted the bytes, not that the client got them —
the client-side evidence runner is the authoritative verdict.
"""
import argparse
import errno
import hmac
import json
import os
import re
import socket
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CANARY_VERSION = "1.0.0"
MAX_DELAY = 600            # canary ceiling; the campaign itself stays <= 240
                           # (app request timeout is 300s, doctor waits 300s)
MAX_BODY = 64 * 1024 * 1024  # contract floor is 50 MiB — stay above it

MODEL_ID = "conduck-canary"

DISCLOSURE = ("An image was attached in this earlier message, but this adapter "
              "cannot inspect it. Do not infer its contents.")
OMITTED_NOTE = "[An unsupported attachment was omitted at this position.]"

RE_WAIT = re.compile(r"\bwait(?:\s+for)?\s+(\d+)\s*(?:s|secs?|seconds?)?\b",
                     re.IGNORECASE | re.ASCII)
RE_NONCE = re.compile(r"\bnonce\s+([A-Za-z0-9]{4,32})\b",
                      re.IGNORECASE | re.ASCII)
RE_CANARY = re.compile(r"\bcanary\b", re.IGNORECASE | re.ASCII)
RE_EXACT = re.compile(r"Reply with exactly:\s*(\S+)")


def lifecycle(line):
    print(line, file=sys.stderr, flush=True)


def parse_directive(text):
    """Return (delay, nonce, invalid_reason). delay is None when the message
    carries no canary directive at all (normal turn). Doctor echo prompts
    ("Reply with exactly: ...") always win over directive parsing — a future
    doctor prompt that happens to contain both words must never sleep."""
    if RE_EXACT.search(text):
        return None, None, None
    if not RE_CANARY.search(text):
        return None, None, None
    waits = RE_WAIT.findall(text)
    if not waits:
        return None, None, None
    nonces = RE_NONCE.findall(text)
    if len(waits) > 1:
        return 0, None, "multiple_delays"
    if len(nonces) > 1:
        return 0, None, "multiple_nonces"
    delay = int(waits[0])
    if delay < 1 or delay > MAX_DELAY:
        return 0, None, "delay_out_of_range"
    return delay, (nonces[0] if nonces else None), None


def newest_text(msgs):
    """The newest user message's text: plain string, or text parts joined by
    one newline (contract flattening rule). Unknown/image parts contribute
    nothing here — they are policed separately."""
    content = msgs[-1].get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for part in content:
            if isinstance(part, dict) and part.get("type") == "text":
                parts.append(part.get("text") or "")
        return "\n".join(parts)
    return ""


def make_handler(token):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "conduck-canary"

        def log_message(self, fmt, *args):        # no request logging, ever
            pass

        # ---- plumbing (every response closes the connection: a tiny
        # threaded origin must never hold persistent connections open
        # underneath a rail experiment) ----
        def _send(self, status, body, content_type):
            body = body.encode() if isinstance(body, str) else body
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()
            self.close_connection = True

        def send_json(self, status, obj):
            self._send(status, json.dumps(obj), "application/json")

        def err(self, status, message, code=None):
            e = {"message": message, "type": "invalid_request_error"}
            if code:
                e["code"] = code
            self.send_json(status, {"error": e})

        def auth_ok(self):
            header = self.headers.get("Authorization", "")
            supplied = header[7:] if header.startswith("Bearer ") else ""
            if hmac.compare_digest(supplied, token):
                return True
            self.err(401, "Missing or invalid bearer token.")
            return False

        # ---- routes ----
        def do_GET(self):
            path = self.path.split("?")[0]
            if path == "/v1/chat/completions":
                return self.err(405, "Use POST on this route.")
            if path != "/v1/models":
                return self.err(404, "Unknown path.")
            if not self.auth_ok():
                return
            return self.send_json(200, {"object": "list",
                                        "data": [{"id": MODEL_ID,
                                                  "object": "model"}]})

        def do_POST(self):
            path = self.path.split("?")[0]
            if path == "/v1/models":
                return self.err(405, "Use GET on this route.")
            if path != "/v1/chat/completions":
                return self.err(404, "Unknown path.")
            if not self.auth_ok():                 # auth BEFORE body work
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                return self.err(400, "Bad Content-Length.")
            if length > MAX_BODY:
                return self.err(413, "Request body too large.")
            try:
                req = json.loads(self.rfile.read(length))
                if not isinstance(req, dict):
                    raise ValueError
            except Exception:
                return self.err(400, "Body is not a JSON object.")

            msgs = req.get("messages")
            if not isinstance(msgs, list) or not msgs:
                return self.err(400, "messages must be a non-empty array.")
            if not isinstance(msgs[-1], dict) or msgs[-1].get("role") != "user":
                return self.err(400, "Final message must have role user.")

            model = req.get("model")
            if model is not None and model != MODEL_ID:
                return self.err(400, "Unknown model.", code="model_not_found")

            # Image / unknown-part policy: text-only. A CURRENT-turn image is
            # declined honestly; earlier images are replaced by the disclosure
            # (we generate the reply ourselves, so "replace" = never fatal).
            # Unknown part TYPES are replaced in position by an explicit note
            # (the contract forbids silently dropping them).
            for idx, m in enumerate(msgs):
                content = m.get("content") if isinstance(m, dict) else None
                if not isinstance(content, list):
                    continue
                for part in content:
                    if not isinstance(part, dict):
                        continue
                    ptype = part.get("type")
                    if ptype == "text":
                        continue
                    if ptype == "image_url" and idx == len(msgs) - 1:
                        return self.err(400, "This adapter cannot read images.",
                                        code="image_unsupported")
                    _ = DISCLOSURE if ptype == "image_url" else OMITTED_NOTE

            text = newest_text(msgs)
            delay, nonce, invalid = parse_directive(text)
            turn_id = os.urandom(4).hex()
            t0 = time.monotonic()

            if invalid is not None:
                lifecycle("TURN_INVALID turn_id=%s reason=%s" % (turn_id, invalid))
                reply = ("CANARY v%s turn_id=%s INVALID_DIRECTIVE reason=%s "
                         "delay_requested=0s elapsed=0.00s"
                         % (CANARY_VERSION, turn_id, invalid))
            elif delay is not None:
                lifecycle("TURN_START turn_id=%s delay=%d nonce_present=%d"
                          % (turn_id, delay, 1 if nonce else 0))
                time.sleep(delay)                  # silent: no bytes on the wire
                elapsed = time.monotonic() - t0
                reply = ("CANARY v%s turn_id=%s delay_requested=%ds elapsed=%.2fs"
                         % (CANARY_VERSION, turn_id, delay, elapsed))
                if nonce:
                    reply += " nonce=%s" % nonce   # nonce LAST — end-intact proof
            else:
                m = RE_EXACT.search(text)          # the doctor's echo prompts
                reply = m.group(1) if m else (text.strip() or "quack")

            resp = {"id": "chatcmpl-canary", "object": "chat.completion",
                    "created": int(time.time()), "model": MODEL_ID,
                    "choices": [{"index": 0,
                                 "message": {"role": "assistant",
                                             "content": reply},
                                 "finish_reason": "stop"}]}
            if delay is None and invalid is None:
                return self.send_json(200, resp)

            # Canary turns corroborate the emit outcome (codes only — a local
            # write success is NOT end-to-end proof; the client decides).
            try:
                self.send_json(200, resp)
                lifecycle("REPLY_EMIT_ACCEPTED turn_id=%s elapsed=%.2f"
                          % (turn_id, time.monotonic() - t0))
            except OSError as exc:
                eno = exc.errno or 0
                cls = {errno.EPIPE: "broken_pipe",
                       errno.ECONNRESET: "connection_reset",
                       errno.ETIMEDOUT: "timeout"}.get(eno, "other")
                if isinstance(exc, socket.timeout):
                    cls = "timeout"
                lifecycle("REPLY_EMIT_ERROR turn_id=%s class=%s errno=%d "
                          "elapsed=%.2f" % (turn_id, cls, eno,
                                            time.monotonic() - t0))

        def do_PUT(self):
            self.err(405, "Method not allowed.")
        do_DELETE = do_PUT
        do_PATCH = do_PUT

    return Handler


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=0,
                    help="0 (default) = OS-assigned; READY line reports the real port")
    ap.add_argument("--version", action="store_true")
    args = ap.parse_args()
    if args.version:
        print(CANARY_VERSION)
        return

    token = os.environ.get("CONDUCK_TOKEN", "")
    if not token:
        print("CONDUCK_TOKEN is required", file=sys.stderr)
        sys.exit(2)

    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(token))
    server.daemon_threads = True
    print("READY %d" % server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
