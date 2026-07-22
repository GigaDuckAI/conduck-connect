#!/usr/bin/env python3
"""fixture-webdav.py — a minimal WebDAV-ish file server for the doctor's
regression suite (run-doctor-suite.sh --files cases). stdlib only, loopback
only. NOT a production server: it serves ONE directory over the exact HTTP
verbs the doctor's file lane uses (GET incl. Range: bytes=0-0, PUT, DELETE,
MKCOL) with HTTP Basic auth, and every `--mode` deliberately sabotages one
behavior so the matching file check can be proven to fail (or degrade) for its
intended reason.

Usage:
    WEBDAV_PASS=<pass> python3 fixture-webdav.py --dir <served> \
        [--port 0] [--user conduck] [--mode good] [--stale-seconds 300] \
        [--capture <file>]

The password comes from $WEBDAV_PASS only (never argv), mirroring the chat
fixture's $CONDUCK_TOKEN. Binds 127.0.0.1 only. Prints one "READY <port>"
line on stdout when listening (the runner waits for it). No request content
is logged unless --capture is given (the no-leak case uses it to recover the
doctor's own sentinel nonce and prove the doctor never echoed it).

Modes ("good" behavior unless listed):
    good           full correct WebDAV-ish behavior (auth, write-through, live
                   disk reads, honored ranges, MKCOL, DELETE)
    stale-listing  a file that appears ON DISK out-of-band (not via a PUT
                   through this server) stays 404 over HTTP until its mtime is
                   older than --stale-seconds (default 300) — the rclone
                   dir-cache bug that hides agent-written output from the app.
                   Files written THROUGH a PUT are visible immediately.
    read-only      every write verb (PUT/DELETE/MKCOL) answers 403
    open           no auth required anywhere — 2xx without credentials
    no-range       ignores Range, always answers 200 with the full body
    no-delete      DELETE answers 405 (everything else good)
    no-mkcol       MKCOL answers 405 (everything else good)
"""
import argparse
import base64
import hmac
import os
import shutil
import stat
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote


def make_handler(cfg):
    served = cfg["dir"]
    mode = cfg["mode"]
    user = cfg["user"]
    password = cfg["password"]
    stale_seconds = cfg["stale_seconds"]
    capture = cfg["capture"]
    known = cfg["known"]          # relpaths written via a PUT through this server

    def cap(line):
        if not capture:
            return
        try:
            with open(capture, "a") as fh:
                fh.write(line + "\n")
        except Exception:
            pass

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "conduck-fixture-webdav"

        def log_message(self, fmt, *args):        # no request logging, ever
            pass

        # ---- plumbing ----
        def _send(self, status, body=b"", extra=None):
            if isinstance(body, str):
                body = body.encode()
            self.send_response(status)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            for k, v in (extra or {}):
                self.send_header(k, v)
            self.end_headers()
            self.close_connection = True
            if self.command != "HEAD":
                try:
                    self.wfile.write(body)
                except Exception:
                    pass

        def _auth_ok(self):
            if mode == "open":
                return True
            header = self.headers.get("Authorization", "")
            if not header.startswith("Basic "):
                return False
            try:
                raw = base64.b64decode(header[6:]).decode("utf-8", "replace")
            except Exception:
                return False
            want = "%s:%s" % (user, password)
            return hmac.compare_digest(raw, want)

        def _require_auth(self):
            if self._auth_ok():
                return True
            self._send(401, "Unauthorized",
                       extra=[("WWW-Authenticate", 'Basic realm="conduck"')])
            return False

        # relpath (leading slash stripped, unquoted) or None if it escapes root
        def _relpath(self):
            rel = unquote(self.path.split("?", 1)[0]).lstrip("/")
            if not rel:
                return ""
            full = os.path.realpath(os.path.join(served, rel))
            if not (full == served or full.startswith(served + os.sep)):
                return None
            return rel.rstrip("/")

        def _visible(self, full, rel):
            """False iff stale-listing is hiding an out-of-band on-disk file."""
            if mode != "stale-listing":
                return True
            if rel in known:
                return True
            try:
                age = time.time() - os.stat(full).st_mtime
            except Exception:
                return True
            return age >= stale_seconds

        # ---- verbs ----
        def do_GET(self):
            self._respond_get(head=False)

        def do_HEAD(self):
            self._respond_get(head=True)

        def _respond_get(self, head):
            if not self._require_auth():
                return
            rel = self._relpath()
            if rel is None:
                return self._send(403, "Forbidden")
            full = os.path.join(served, rel)
            if not os.path.isfile(full) or not self._visible(full, rel):
                return self._send(404, "Not Found")
            with open(full, "rb") as fh:
                data = fh.read()
            rng = self.headers.get("Range")
            if rng and mode != "no-range":
                spec = rng.split("=", 1)[-1].split(",")[0].strip()
                try:
                    a, b = spec.split("-", 1)
                    start = int(a) if a else 0
                    end = int(b) if b else len(data) - 1
                except Exception:
                    start, end = 0, len(data) - 1
                if start >= len(data):
                    return self._send(416, "Range Not Satisfiable",
                                      extra=[("Content-Range", "bytes */%d" % len(data))])
                end = min(end, len(data) - 1)
                chunk = data[start:end + 1]
                return self._send(206, b"" if head else chunk,
                                  extra=[("Content-Range",
                                          "bytes %d-%d/%d" % (start, end, len(data))),
                                         ("Accept-Ranges", "bytes")])
            return self._send(200, b"" if head else data,
                              extra=[("Accept-Ranges", "bytes")])

        def do_PUT(self):
            if not self._require_auth():
                return
            if mode == "read-only":
                return self._send(403, "Read-only")
            rel = self._relpath()
            if rel is None:
                return self._send(403, "Forbidden")
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length) if length else b""
            full = os.path.join(served, rel)
            parent = os.path.dirname(full)
            if parent and not os.path.isdir(parent):
                return self._send(409, "Conflict")   # missing collection
            existed = os.path.exists(full)
            try:
                with open(full, "wb") as fh:
                    fh.write(body)
            except Exception:
                return self._send(500, "Write failed")
            known.add(rel)                            # a through-PUT is never stale
            cap("PUT %s body=%s" % (rel, body.decode("utf-8", "replace")))
            return self._send(204 if existed else 201, b"")

        def do_DELETE(self):
            if not self._require_auth():
                return
            if mode == "no-delete":
                return self._send(405, "Method Not Allowed")
            if mode == "read-only":
                return self._send(403, "Read-only")
            rel = self._relpath()
            if rel is None:
                return self._send(403, "Forbidden")
            full = os.path.join(served, rel)
            try:
                st = os.lstat(full)
            except FileNotFoundError:
                return self._send(404, "Not Found")
            try:
                if stat.S_ISDIR(st.st_mode):
                    shutil.rmtree(full)
                else:
                    os.remove(full)
            except Exception:
                return self._send(500, "Delete failed")
            known.discard(rel)
            return self._send(204, b"")

        def do_MKCOL(self):
            if not self._require_auth():
                return
            if mode in ("read-only",):
                return self._send(403, "Read-only")
            if mode == "no-mkcol":
                return self._send(405, "Method Not Allowed")
            rel = self._relpath()
            if rel is None:
                return self._send(403, "Forbidden")
            full = os.path.join(served, rel)
            parent = os.path.dirname(full)
            if parent and not os.path.isdir(parent):
                return self._send(409, "Conflict")
            if os.path.exists(full):
                return self._send(405, "Method Not Allowed")
            try:
                os.mkdir(full)
            except Exception:
                return self._send(500, "MKCOL failed")
            return self._send(201, b"")

    return Handler


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True, help="directory to serve")
    ap.add_argument("--port", type=int, default=0,
                    help="0 (default) = OS-assigned; READY line reports the real port")
    ap.add_argument("--user", default="conduck")
    ap.add_argument("--mode", default="good")
    ap.add_argument("--stale-seconds", type=float, default=300.0)
    ap.add_argument("--capture", default="")
    args = ap.parse_args()

    served = os.path.realpath(args.dir)
    if not os.path.isdir(served):
        print("served dir does not exist: %s" % served, file=sys.stderr)
        sys.exit(2)
    password = os.environ.get("WEBDAV_PASS", "")
    if not password and args.mode != "open":
        print("WEBDAV_PASS is required", file=sys.stderr)
        sys.exit(2)

    cfg = {"dir": served, "mode": args.mode, "user": args.user,
           "password": password, "stale_seconds": args.stale_seconds,
           "capture": args.capture, "known": set()}
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(cfg))
    server.daemon_threads = True
    print("READY %d" % server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
