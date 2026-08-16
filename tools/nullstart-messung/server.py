#!/usr/bin/env python3
"""Minimal Audiobookshelf stand-in for the null-start measurement (c59e96e/ac97fb6).

It is NOT a general ABS emulation — it serves exactly the endpoints the app
touches when opening a downloaded book, and it RECORDS every progress write.
The recording is the point: the measurement has to answer "where does it
start" AND "what does it push", because after a null start `lastSyncedTime`
is 0 and the 5-second sync threshold fires within seconds.

Modes (env MOCK_MODE), matching the reviewer's three cases:
  ok      — answers normally (baseline: the reconcile can repair)
  slow    — answers after MOCK_DELAY seconds (past the 1.5s reconcile bound)
  empty   — answers 200 but WITHOUT a progress entry
  down    — refuses connections on the API paths (case 1)
"""
import json, os, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODE = os.environ.get("MOCK_MODE", "ok")
DELAY = float(os.environ.get("MOCK_DELAY", "6"))
# The progress the SERVER holds — the value a working reconcile would restore.
# The declared duration MUST match the real audio: with a 3-second file and
# a declared 7200 s the player hit the end at once and pushed "finished at
# 7200" — a harness artifact that would have read as a data-loss finding.
SERVER_TIME = float(os.environ.get("MOCK_SERVER_TIME", "150"))
DURATION = float(os.environ.get("MOCK_DURATION", "300"))
ITEM_ID = "mock-book-1"
LIB_ID = "mock-lib-1"
WRITES = []            # every progress write the app sends
LOCK = threading.Lock()
AUDIO = b""            # filled at startup


def progress_entry():
    if MODE == "empty":
        return None
    return {"currentTime": SERVER_TIME, "duration": DURATION,
            "progress": SERVER_TIME / DURATION, "isFinished": False,
            "lastUpdate": int(time.time() * 1000)}


def media(with_tracks):
    m = {"metadata": {"title": "Mock Buch", "authorName": "Mock Autor",
                      "narratorName": None, "seriesName": None,
                      "genres": [], "publishedYear": None},
         "duration": DURATION, "chapters": []}
    if with_tracks:
        m["tracks"] = [{"index": 1, "startOffset": 0, "duration": DURATION,
                        "contentUrl": f"/audio/{ITEM_ID}.m4a",
                        "metadata": {"size": len(AUDIO)}}]
    return m


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _maybe_stall(self, path):
        """`slow` and `down` apply to the API only — never to the audio file:
        the book must be downloadable in every case, otherwise the measurement
        would test the download instead of the start position."""
        if path.startswith("/audio/"):
            return False
        if MODE == "down":
            self.send_response(503)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return True
        if MODE == "slow":
            time.sleep(DELAY)
        return False

    def do_POST(self):
        if self._maybe_stall(self.path):
            return
        if self.path.rstrip("/") == "/login":
            self._json({"user": {"token": "mock-token", "username": "mock"}})
            return
        self._json({}, 404)

    def do_PATCH(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        if self.path.startswith("/api/me/progress/"):
            try:
                sent = json.loads(raw)
            except Exception:
                sent = {"_unparsed": raw.decode("utf-8", "replace")}
            with LOCK:
                WRITES.append({"at": time.time(), "path": self.path, "body": sent})
            # Deliberately NOT stalled: a write that never arrives would hide
            # exactly what we want to see.
            self._json({"ok": True})
            return
        if self._maybe_stall(self.path):
            return
        self._json({}, 404)

    def do_GET(self):
        if self.path.startswith("/audio/"):
            self.send_response(200)
            self.send_header("Content-Type", "audio/mp4")
            self.send_header("Content-Length", str(len(AUDIO)))
            self.send_header("Accept-Ranges", "none")
            self.end_headers()
            self.wfile.write(AUDIO)
            return
        if self.path.startswith("/__writes"):     # the harness reads this
            with LOCK:
                self._json({"mode": MODE, "writes": WRITES})
            return
        if self._maybe_stall(self.path):
            return
        p = self.path.split("?")[0].rstrip("/")
        if p == "/api/libraries":
            self._json({"libraries": [{"id": LIB_ID, "name": "Mock",
                                       "mediaType": "book"}]})
        elif p == f"/api/libraries/{LIB_ID}/items":
            self._json({"results": [{"id": ITEM_ID, "media": media(False),
                                     "addedAt": 0}]})
        elif p == f"/api/items/{ITEM_ID}":
            self._json({"id": ITEM_ID, "media": media(True),
                        "userMediaProgress": progress_entry()})
        elif p == "/api/me":
            e = progress_entry()
            self._json({"mediaProgress": ([{"libraryItemId": ITEM_ID, **e}] if e else [])})
        else:
            self._json({}, 404)


def main():
    global AUDIO
    # A tiny but real m4a so the download completes and the book counts as
    # downloaded — the whole measurement hangs on that state.
    src = os.path.join(os.path.dirname(__file__), "tone.m4a")
    with open(src, "rb") as f:
        AUDIO = f.read()
    port = int(os.environ.get("MOCK_PORT", "8770"))
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    # TLS, because ATS only lets MEDIA through in the clear — the API would be
    # blocked. Own CA, added to the simulator trust store by the harness.
    cert = os.environ.get("MOCK_CERT")
    if cert:
        import ssl
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cert)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    print(f"mock ABS on {port}, mode={MODE}, server_time={SERVER_TIME}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
