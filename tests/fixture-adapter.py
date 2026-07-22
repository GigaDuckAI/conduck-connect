#!/usr/bin/env python3
"""fixture-adapter.py — known-good / deliberately-broken adapter for the doctor's
regression suite (run-doctor-suite.sh). stdlib only, loopback only.

This is NOT a production adapter. It exists so every doctor check can be proven
to fail for its intended reason: `--mode good` (and the `single-model` /
`text-only` variants) must pass the deep doctor with exit 0, and every other
mode sabotages one specific behavior so the matching check goes red.

Usage:
    CONDUCK_TOKEN=<token> python3 fixture-adapter.py [--port 8499] [--mode good]

The token comes from $CONDUCK_TOKEN only (never argv). Binds 127.0.0.1 only.
Prints one "READY <port>" line on stdout when listening (the runner waits for
it). No request content is ever logged.

Modes ("good" behavior unless listed):
    good                 fully conformant; advertises TWO models; reads the
                         doctor's digit PNG deterministically (VERIFIED)
    single-model         advertises ONE model and IGNORES an unknown model id
                         (the contract's single-agent leniency branch)
    text-only            declines a CURRENT-turn image with 400 + code
                         "image_unsupported"; replaces EARLIER-message images
                         with the canonical disclosure and still answers
    open                 no auth at all (for the doctor's keyless-run path)
    auth-models-none-ok  /v1/models answers without any Authorization header
    auth-models-any-token /v1/models accepts a wrong bearer token
    auth-chat-none-ok    /v1/chat/completions answers without a token
    auth-chat-any-token  /v1/chat/completions accepts a wrong token
    auth-403             /v1/models answers 403 (not 401) to a missing token
    models-bare-array    /v1/models returns a bare JSON array (no envelope)
    models-empty-data    /v1/models returns {"data": []}
    models-no-id         /v1/models entries carry no usable "id" string
    models-html          /v1/models returns an HTML page
    models-slow          /v1/models answers after 16s (over the app's 15s limit)
    require-model        400 when the request has no "model" field
    reject-unknown-field 400 when the request carries an unknown field
    bogus-model-200      accepts an unknown model id while advertising two
    sse-despite-false    streams SSE when "stream" is false (correct on true)
    reject-stream-true   400 when "stream" is true
    sse-on-stream-true   streams SSE when "stream" is true (correct on false)
    reject-history-image 400 when an EARLIER message contains an image (the
                         clean-room poisoning bug this revision exists to kill)
    silent-drop-image    ignores a current-turn image and answers from text only
    decline-wrong-code   declines a current-turn image with 400 but NO code field
    decline-other-code   declines a current-turn image with 400 + a WRONG code
    error-missing-type   error bodies omit the "type" field
    wrong-content-type   chat 200 responses carry Content-Type: text/plain
    wrong-content-type-models  /v1/models 200 carries Content-Type: text/plain
    empty-content        chat replies with "content": ""
    tool-calls           chat replies carry a tool_calls array
    many-choices         chat replies carry two choices (both fully valid)
    malformed-second-choice  chat replies carry TWO choices — choices[0] is a
                         fully valid {"message":{"content":"<string>"}}, but
                         choices[1] is {"index":1,"message":{"content":null}}
                         (content null). choices[0] alone is usable, yet the
                         Conduck app (Apple) decodes the whole [Choice] array
                         eagerly, so the null-content later choice invalidates
                         the entire reply — this must FAIL the app's decoder
                         (compat chat) even though a lenient reader would pass
    non-string-content   chat replies with parts-form (non-string) content
    bad-json             chat replies 200 with a non-JSON body

File-agent modes (all behave like `good` for the ordinary chat checks; they
diverge only on the doctor's --files turn — a user message carrying the
"[Conduck file transfer]" instruction — and only when $CONDUCK_FILES_DIR is
set, the shared folder the fixture-webdav server also serves):
    files-good           copy the named input file to the requested
                         output-<hex>.txt at the folder ROOT before replying,
                         and name that output file in plain reply text
    files-no-write       reply naming the output file but never write it
    files-late-write     reply first, write the correct output ~LATE (a
                         background thread, $CONDUCK_FILES_LATE_DELAY s) — after
                         the doctor's immediate no-grace probe has already fired
    files-wrong-bytes    write the output but with different (non-identical) bytes
    files-no-reference   write a correct output but reply naming no filename
    files-slow           like files-good, but sleep $CONDUCK_FILES_SLOW_DELAY s
                         BEFORE replying to the file turn (a window for the
                         signal-cleanup case to SIGINT the doctor mid-turn)
"""
import argparse
import base64
import hmac
import json
import os
import re
import struct
import sys
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, HTTPServer

FILE_MODES = {"files-good", "files-no-write", "files-late-write",
              "files-wrong-bytes", "files-no-reference", "files-slow"}
LATE_DELAY = float(os.environ.get("CONDUCK_FILES_LATE_DELAY", "1.5"))
SLOW_DELAY = float(os.environ.get("CONDUCK_FILES_SLOW_DELAY", "6.0"))


def handle_file_turn(mode, files_dir, text):
    """The doctor's --files sentinel turn. Parse the requested output name and
    the stored input key from the golden wire text, act per mode, and return
    the reply string. On any parse failure fall back to a plain reply (the
    doctor's checks then fail honestly rather than the fixture crashing)."""
    m_out = re.search(r"output-[0-9a-f]+\.txt", text)
    m_in = re.search(r"\(saved as (.+?)\)", text)
    if not m_out or not m_in:
        return "I could not find the file details in the request."
    okey = m_out.group(0)
    ikey = m_in.group(1).strip()
    ipath = os.path.join(files_dir, ikey)
    opath = os.path.join(files_dir, okey)
    try:
        data = open(ipath, "rb").read()
    except Exception:
        data = b""

    def write(payload):
        with open(opath, "wb") as fh:
            fh.write(payload)

    named = "Done — I copied the input to %s at the root of the working directory." % okey
    if mode == "files-good" or mode == "files-slow":
        write(data)
        return named
    if mode == "files-no-write":
        return named
    if mode == "files-wrong-bytes":
        write(b"conduck-doctor-TAMPERED\n" + data)
        return named
    if mode == "files-no-reference":
        write(data)
        return "Done — the requested file has been written to the working directory root."
    if mode == "files-late-write":
        threading.Thread(target=lambda: (time.sleep(LATE_DELAY), write(data)),
                         daemon=True).start()
        return named
    return named

# --- digit-PNG decode (mirror of the doctor's generator geometry) ------------
# The doctor renders 4 digits as 5x7 glyph bitmaps at scale 16, margin 40,
# gap 24, 8-bit grayscale, black on white. Geometry is FIXED so this fixture
# can read the digits without OCR: sample each glyph cell's center pixel and
# match the 35-bit pattern against the same font table.
FONT = {
    "0": [0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110],
    "1": [0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110],
    "2": [0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111],
    "3": [0b11111, 0b00010, 0b00100, 0b00010, 0b00001, 0b10001, 0b01110],
    "4": [0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010],
    "5": [0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110],
    "6": [0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110],
    "7": [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000],
    "8": [0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110],
    "9": [0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100],
}
SCALE, MARGIN, GAP = 16, 60, 64
GLYPH_W, GLYPH_H = 5 * SCALE, 7 * SCALE

DISCLOSURE = ("An image was attached in this earlier message, but this adapter "
              "cannot inspect it. Do not infer its contents.")


def decode_digit_png(png):
    """Return the 4-digit string, or None if this isn't the doctor's probe PNG."""
    try:
        if png[:8] != b"\x89PNG\r\n\x1a\n":
            return None
        pos, idat, w, h = 8, b"", None, None
        while pos + 8 <= len(png):
            (ln,) = struct.unpack(">I", png[pos:pos + 4])
            typ = png[pos + 4:pos + 8]
            data = png[pos + 8:pos + 8 + ln]
            pos += 12 + ln
            if typ == b"IHDR":
                w, h = struct.unpack(">II", data[:8])
                if data[8:10] != b"\x08\x00":       # 8-bit grayscale only
                    return None
            elif typ == b"IDAT":
                idat += data
            elif typ == b"IEND":
                break
        if not w or not h or not idat:
            return None
        raw = zlib.decompress(idat)
        stride = w + 1
        if len(raw) < stride * h:
            return None
        rows = []
        prev = bytearray(w)
        for y in range(h):
            f = raw[y * stride]
            line = bytearray(raw[y * stride + 1:(y + 1) * stride])
            if f == 2:                              # Up filter
                for x in range(w):
                    line[x] = (line[x] + prev[x]) & 0xFF
            elif f != 0:                            # generator uses 0; tolerate 2
                return None
            rows.append(line)
            prev = line
        inv = {tuple(v): k for k, v in FONT.items()}
        out = []
        for i in range(4):
            x0 = MARGIN + i * (GLYPH_W + GAP)
            pat = []
            for r in range(7):
                bits = 0
                for c in range(5):
                    x = x0 + c * SCALE + SCALE // 2
                    y = MARGIN + r * SCALE + SCALE // 2
                    if y >= h or x >= w:
                        return None
                    bits = (bits << 1) | (1 if rows[y][x] < 128 else 0)
                pat.append(bits)
            d = inv.get(tuple(pat))
            if d is None:
                return None
            out.append(d)
        return "".join(out)
    except Exception:
        return None


# --- request/engine model ----------------------------------------------------

KNOWN_FIELDS = {"messages", "model", "stream", "temperature", "max_tokens",
                "top_p", "user", "n"}


class Engine:
    """The deterministic 'AI': answers the doctor's prompts exactly."""

    @staticmethod
    def reply(texts, digit_code):
        if digit_code is not None:
            return digit_code
        text = "\n".join(texts).strip()
        m = re.search(r"Reply with exactly:\s*(\S+)", text)
        if m:
            return m.group(1)
        return text or "quack"


def data_url_bytes(url):
    m = re.match(r"data:[^;,]+;base64,(.*)$", url, re.S)
    if not m:
        return None
    try:
        return base64.b64decode(m.group(1))
    except Exception:
        return None


def make_handler(mode, token, models):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "conduck-fixture"

        def log_message(self, fmt, *args):        # no request logging, ever
            pass

        # ---- plumbing ----
        def send_json(self, status, obj, content_type="application/json"):
            body = json.dumps(obj).encode()
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def send_raw(self, status, body, content_type):
            body = body.encode() if isinstance(body, str) else body
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def err(self, status, message, code=None, etype="invalid_request_error"):
            e = {"message": message, "type": etype}
            if mode == "error-missing-type":
                del e["type"]
            if code:
                e["code"] = code
            self.send_json(status, {"error": e})

        def auth_ok(self, route):
            if mode == "open":
                return True
            header = self.headers.get("Authorization", "")
            none_ok = mode == ("auth-models-none-ok" if route == "models"
                               else "auth-chat-none-ok")
            any_ok = mode == ("auth-models-any-token" if route == "models"
                              else "auth-chat-any-token")
            if not header:
                if none_ok:
                    return True
                status = 403 if (mode == "auth-403" and route == "models") else 401
                self.err(status, "Missing bearer token.")
                return False
            supplied = header[7:] if header.startswith("Bearer ") else ""
            if hmac.compare_digest(supplied, token) or any_ok:
                return True
            self.err(401, "Invalid bearer token.")
            return False

        # ---- routes ----
        def do_GET(self):
            if self.path.split("?")[0] != "/v1/models":
                return self.err(404, "Unknown path.")
            if not self.auth_ok("models"):
                return
            if mode == "models-slow":
                time.sleep(16)
            if mode == "models-html":
                return self.send_raw(200, "<html><body>login</body></html>", "text/html")
            if mode == "models-bare-array":
                return self.send_json(200, [{"id": m} for m in models])
            if mode == "models-empty-data":
                return self.send_json(200, {"object": "list", "data": []})
            if mode == "models-no-id":
                return self.send_json(200, {"object": "list", "data": [{"name": "x"}]})
            ct = "text/plain" if mode == "wrong-content-type-models" else "application/json"
            return self.send_json(200, {"object": "list",
                                        "data": [{"id": m, "object": "model"} for m in models]},
                                  content_type=ct)

        def do_POST(self):
            if self.path.split("?")[0] != "/v1/chat/completions":
                return self.err(404, "Unknown path.")
            if not self.auth_ok("chat"):
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                req = json.loads(self.rfile.read(length))
                if not isinstance(req, dict):
                    raise ValueError
            except Exception:
                return self.err(400, "Body is not a JSON object.")

            if mode == "reject-unknown-field":
                unknown = set(req) - KNOWN_FIELDS
                if unknown:
                    return self.err(400, "Unknown request field.")

            msgs = req.get("messages")
            if not isinstance(msgs, list) or not msgs:
                return self.err(400, "messages must be a non-empty array.")
            if not isinstance(msgs[-1], dict) or msgs[-1].get("role") != "user":
                return self.err(400, "Final message must have role user.")

            model = req.get("model")
            if mode == "require-model" and model is None:
                return self.err(400, "model is required.")
            if model is not None and model not in models:
                ignore = (mode == "bogus-model-200"
                          or (mode == "single-model" and len(models) == 1))
                if not ignore:
                    return self.err(400, "Unknown model.", code="model_not_found")
                model = None
            sel = model or models[0]

            stream = bool(req.get("stream", False))
            # Current turn vs history: images are judged by POSITION.
            digit_code = None
            for idx, m in enumerate(msgs):
                content = m.get("content") if isinstance(m, dict) else None
                if not isinstance(content, list):
                    continue
                last = idx == len(msgs) - 1
                for part in content:
                    if not isinstance(part, dict) or part.get("type") != "image_url":
                        continue
                    if last:
                        if mode == "text-only":
                            return self.err(400, "This adapter cannot read images.",
                                            code="image_unsupported")
                        if mode == "decline-wrong-code":
                            return self.err(400, "This adapter cannot read images.")
                        if mode == "decline-other-code":
                            return self.err(400, "This adapter cannot read images.",
                                            code="unsupported_image")
                        if mode != "silent-drop-image":
                            raw = data_url_bytes((part.get("image_url") or {}).get("url", ""))
                            if raw is not None:
                                got = decode_digit_png(raw)
                                if got is not None:
                                    digit_code = got
                    else:
                        if mode == "reject-history-image":
                            return self.err(400, "Image in conversation history.")
                        # good/text-only: earlier image is forwarded (we ARE the
                        # engine, so 'forward' = accept) or disclosed — never fatal.
                        _ = DISCLOSURE  # text-only stand-in for the replacement

            texts = []
            content = msgs[-1].get("content")
            if isinstance(content, str):
                texts.append(content)
            elif isinstance(content, list):
                for part in content:
                    if isinstance(part, dict) and part.get("type") == "text":
                        texts.append(part.get("text") or "")

            files_dir = os.environ.get("CONDUCK_FILES_DIR")
            joined = "\n".join(texts)
            if files_dir and mode in FILE_MODES and "[Conduck file transfer]" in joined:
                if mode == "files-slow":
                    time.sleep(SLOW_DELAY)
                reply = handle_file_turn(mode, files_dir, joined)
            else:
                reply = Engine.reply(texts, digit_code)

            sse = (mode == "sse-despite-false" and not stream) or \
                  (mode == "sse-on-stream-true" and stream)
            if mode == "reject-stream-true" and stream:
                return self.err(400, "stream is not supported.")
            if sse:
                chunk = ("data: " + json.dumps({"choices": [{"delta": {"content": reply}}]})
                         + "\n\ndata: [DONE]\n\n")
                return self.send_raw(200, chunk, "text/event-stream")

            if mode == "bad-json":
                return self.send_raw(200, "not json {", "application/json")

            message = {"role": "assistant", "content": reply}
            if mode == "empty-content":
                message["content"] = ""
            if mode == "non-string-content":
                message["content"] = [{"type": "text", "text": reply}]
            if mode == "tool-calls":
                message["tool_calls"] = [{"id": "call_0", "type": "function",
                                          "function": {"name": "noop", "arguments": "{}"}}]
            choices = [{"index": 0, "message": message, "finish_reason": "stop"}]
            if mode == "many-choices":
                choices.append({"index": 1, "message": dict(message), "finish_reason": "stop"})
            if mode == "malformed-second-choice":
                # choices[0] stays fully valid; a null-content second choice
                # must sink the whole reply for the app's eager array decoder.
                choices.append({"index": 1, "message": {"content": None}})
            resp = {"id": "chatcmpl-fixture", "object": "chat.completion",
                    "created": int(time.time()), "model": sel, "choices": choices}
            ct = "text/plain" if mode == "wrong-content-type" else "application/json"
            return self.send_json(200, resp, content_type=ct)

        def do_PUT(self):
            self.err(405, "Method not allowed.")
        do_DELETE = do_PUT

    return Handler


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=0,
                    help="0 (default) = OS-assigned; READY line reports the real port")
    ap.add_argument("--mode", default="good")
    args = ap.parse_args()

    token = os.environ.get("CONDUCK_TOKEN", "")
    if not token and args.mode != "open":
        print("CONDUCK_TOKEN is required", file=sys.stderr)
        sys.exit(2)

    models = ["fixture-echo"] if args.mode == "single-model" \
        else ["fixture-echo", "fixture-echo-2"]
    server = HTTPServer(("127.0.0.1", args.port),
                        make_handler(args.mode, token, models))
    print("READY %d" % server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
