#!/usr/bin/env python3
"""fixture-webdav.py — a minimal WebDAV-ish file server for the doctor's
regression suite (run-checks-suite.sh --files cases). stdlib only, loopback
only. NOT a production server: it serves ONE directory over the exact HTTP
verbs the file lanes use (GET incl. Range: bytes=0-0, PUT, DELETE, MKCOL, and
PROPFIND at Depth 0 and 1) with HTTP Basic auth, and every `--mode` deliberately
sabotages one behavior so the matching file check can be proven to fail (or
degrade) for its intended reason.

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
    no-final-newline GET removes one trailing newline from otherwise correct bytes
    first-output-404 the first GET of each existing output-*.txt answers 404
    hang-output-get GET of an existing output-*.txt stalls for
                    $WEBDAV_HANG_SECONDS (default 10)
    delete-lies    DELETE answers 204 but deliberately leaves the target behind
    delete-swaps-symlink DELETE replaces a local-service probe with a symlink
                    to unrelated-victim.txt, then answers 204
    delete-dir-lies DELETE removes files normally but answers 204 without
                    removing directories
    propfind-hides-contents
                   PROPFIND answers 207 for a directory that exists but lists
                   only the collection itself, never its children — the shape a
                   file server takes when the agent created that folder and the
                   server cannot read into it (another user, `0700`) or indexes
                   only its own writes. Every other verb, GET included, behaves
                   normally, which is the point: the file is fetchable by exact
                   name and still undeliverable, because the app finds returned
                   files by listing the folder rather than by guessing names.
    no-propfind    PROPFIND answers 405 — the shape of ngx_http_dav_module and
                   stock Caddy file_server. Every other verb is correct, so this
                   isolates the one verb the delivery path is built on.
    propfind-catch-all
                   PROPFIND answers 207 for EVERY path, including collections
                   that do not exist. A lane that cannot say no can neither
                   prove a reply's folder fresh beforehand nor be believed when
                   it lists one afterwards, so its listings are disqualified
                   rather than trusted.
    propfind-catch-all-nested
                   The same catch-all, but ONLY inside a subfolder: a missing
                   collection at the served root answers a clean 404, a missing
                   collection one or more segments down answers 207. Servers
                   route on both the method and the path prefix, and the app
                   mints its negative control as a sibling of the reply's box —
                   one segment down — for exactly this reason. A control that
                   lands at the root passes here and the real listing is
                   disqualified on every turn.
    mkcol-refused-auto-parents
                   MKCOL answers 405, and PUT creates the missing parent
                   collections itself. A real shape (several WebDAV bridges do
                   it), and one the app serves perfectly: it treats the nested
                   PUT plus a byte-echoing GET as the folder verdict and reads
                   MKCOL only as a tiebreaker when that PUT is refused.
    listing-foreign-href
                   PROPFIND 207s carry a correct collection row, and every CHILD
                   href is an absolute URL on ANOTHER origin. The app resolves
                   each href against the URL it requested and refuses the whole
                   body unless every one is a direct child on the same origin,
                   so this lane delivers nothing — while any matcher that reads
                   basenames out of the document sees the file it wanted.
"""
import argparse
import base64
import hmac
import os
import shutil
import socketserver
import stat
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote, unquote


class LoopbackThreadingHTTPServer(ThreadingHTTPServer):
    """ThreadingHTTPServer that does not reverse-resolve its own bind address.

    http.server's server_bind() calls socket.getfqdn(host) — a REVERSE DNS
    lookup — and this fixture prints READY only after that returns. On a CI
    runner with no reverse zone for 127.0.0.1 the lookup blocks until the
    resolver gives up (~20s observed on GitHub's macOS images), the runner stops
    waiting for READY, and every case needing a fixture fails while the process
    is still alive and produces no diagnostic at all.

    server_name is read only by the CGI handlers, which this fixture does not
    use, so setting it to the bind host loses nothing.
    """

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


def make_handler(cfg):
    served = cfg["dir"]
    mode = cfg["mode"]
    user = cfg["user"]
    password = cfg["password"]
    stale_seconds = cfg["stale_seconds"]
    capture = cfg["capture"]
    known = cfg["known"]          # relpaths written via a PUT through this server
    first_output_misses = cfg["first_output_misses"]
    hang_seconds = cfg["hang_seconds"]

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
            if os.path.isdir(full):
                return self._send(200, "directory")
            if not os.path.isfile(full) or not self._visible(full, rel):
                return self._send(404, "Not Found")
            # Matched on the LAST component, not on the whole relative path: the
            # sentinel these two modes exist to sabotage lives inside the folder
            # the agent creates for it, so a path-anchored test silently stops
            # sabotaging anything and the case passes for the wrong reason. The
            # basename form is also right for an output at the served root.
            if mode == "hang-output-get" \
                    and os.path.basename(rel).startswith("output-"):
                time.sleep(hang_seconds)
            if mode == "first-output-404" \
                    and os.path.basename(rel).startswith("output-") \
                    and rel not in first_output_misses:
                first_output_misses.add(rel)
                return self._send(404, "Not Found")
            with open(full, "rb") as fh:
                data = fh.read()
            if mode == "no-final-newline" and data.endswith(b"\n"):
                data = data[:-1]
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

        def do_PROPFIND(self):
            if not self._require_auth():
                return
            if mode == "no-propfind":
                return self._send(405, "Method Not Allowed")
            rel = self._relpath()
            if rel is None:
                return self._send(403, "Forbidden")
            full = os.path.join(served, rel)
            # The catch-all answers 207 for a path it never had, which is the
            # one shape that makes every other listing meaningless: a server
            # that cannot say "not there" can say nothing believable about what
            # IS there. It still emits only the self entry, because there is
            # nothing on disk to enumerate.
            #
            # The -nested variant answers that way ONLY below the served root,
            # so a control probing a root-level name still gets its clean 404.
            catch_all = mode == "propfind-catch-all" or (
                mode == "propfind-catch-all-nested" and "/" in rel)
            if not os.path.exists(full) and not catch_all:
                return self._send(404, "Not Found")
            # A real Depth: 1 emits the collection ITSELF plus its children, and
            # the self entry is why a bare 207 proves nothing: a folder whose
            # contents the server cannot read answers with exactly that one
            # entry, which is what propfind-hides-contents reproduces. Anything
            # grading this response has to look for the entry it wants by name.
            depth = self.headers.get("Depth", "1").strip()
            hrefs = ["/" + quote(rel) + "/" if rel else "/"]
            # The collection's own row stays honest under listing-foreign-href;
            # only the children move. That is the sharper sabotage: the answer
            # looks like a listing of the folder that was asked for, right up to
            # the point where each entry names a resource on another server.
            elsewhere = "http://conduck-listing-elsewhere.invalid" \
                if mode == "listing-foreign-href" else ""
            if os.path.isdir(full) and depth != "0" \
                    and mode != "propfind-hides-contents":
                for child in sorted(os.listdir(full)):
                    child_rel = (rel + "/" + child) if rel else child
                    if not self._visible(os.path.join(full, child), child_rel):
                        continue
                    hrefs.append(elsewhere + "/" + quote(child_rel)
                                 + ("/" if os.path.isdir(os.path.join(full, child))
                                    else ""))
            body = ['<?xml version="1.0" encoding="utf-8"?>',
                    '<d:multistatus xmlns:d="DAV:">']
            for href in hrefs:
                body.append("<d:response><d:href>%s</d:href>"
                            "<d:propstat><d:status>HTTP/1.1 200 OK</d:status>"
                            "</d:propstat></d:response>" % href)
            body.append("</d:multistatus>")
            return self._send(207, "".join(body),
                              extra=[("Content-Type", "application/xml")])

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
                if mode == "mkcol-refused-auto-parents":
                    try:
                        os.makedirs(parent, exist_ok=True)
                    except Exception:
                        return self._send(500, "Write failed")
                else:
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
            if mode == "delete-lies":
                return self._send(204, b"")
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
            if mode == "delete-swaps-symlink" \
                    and rel.startswith("conduck-connect-local-probe-"):
                victim = os.path.join(served, "unrelated-victim.txt")
                try:
                    os.remove(full)
                    os.symlink(victim, full)
                except Exception:
                    return self._send(500, "Symlink swap failed")
                return self._send(204, b"")
            if mode == "delete-dir-lies" and stat.S_ISDIR(st.st_mode):
                return self._send(204, b"")
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
            if mode in ("no-mkcol", "mkcol-refused-auto-parents"):
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
           "capture": args.capture, "known": set(), "first_output_misses": set(),
           "hang_seconds": float(os.environ.get("WEBDAV_HANG_SECONDS", "10"))}
    server = LoopbackThreadingHTTPServer(("127.0.0.1", args.port), make_handler(cfg))
    server.daemon_threads = True
    print("READY %d" % server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
