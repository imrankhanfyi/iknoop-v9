#!/usr/bin/env python3
"""noop-inbox — append-only drop box for phone-encrypted NOOP lifestyle entries and workout edits.

Runs on Freckleclaw as the unprivileged `noopinbox` user, bound to 127.0.0.1 only; `tailscale serve`
mounts it at https://freckleclaw.<tailnet>:8444/inbox, same origin as the viewer, tailnet-only.

What it can and cannot do, by design:
  * It never sees plaintext. Each entry is AES-256-GCM sealed ON THE PHONE with a key derived from the
    viewer passphrase; only the Mac can open it. Structure is checked, content cannot be.
  * Writes need `Authorization: Bearer <token>`, where the token is also passphrase-derived. The server
    stores only SHA-256(token). Anything without the passphrase — including the Hermes containers —
    gets 401 and nothing is stored.
  * No read endpoint. The Mac pulls over SSH and deletes what it has committed.

Key derivation (must match viewer/app.js and the Mac-side puller byte for byte):
  master    = PBKDF2-HMAC-SHA256(passphrase, salt=b"noop-phone-inbox-v1", iterations=600000, dkLen=32)
  authToken = hex(HMAC-SHA256(master, b"inbox-auth"))
  entryKey  = HMAC-SHA256(master, b"entry-enc")          # AES-256-GCM key

Entry body (JSON, <= 16 KB): {"v": 1, "id": "<uuid4>", "nonceB64": "...", "ciphertextB64": "..."}
"""
import base64
import hashlib
import hmac
import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIND = os.environ.get("NOOP_INBOX_BIND", "127.0.0.1")
PORT = int(os.environ.get("NOOP_INBOX_PORT", "8650"))
INBOX_DIR = os.environ.get("NOOP_INBOX_DIR", "/srv/noop-inbox")
TOKEN_HASH_FILE = os.environ.get("NOOP_INBOX_TOKEN_HASH_FILE", "/etc/noop-inbox/token.sha256")
MAX_BODY = 16 * 1024
MAX_FILES = 5000
RATE_PER_MIN = 120
ACCEPTED_PATHS = {"/", "/inbox", "/inbox/"}
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")


def load_token_hash() -> bytes:
    with open(TOKEN_HASH_FILE, "r", encoding="ascii") as f:
        h = f.read().strip().lower()
    if not re.fullmatch(r"[0-9a-f]{64}", h):
        raise SystemExit(f"{TOKEN_HASH_FILE}: expected 64 hex chars (sha256 of the auth token)")
    return bytes.fromhex(h)


TOKEN_HASH = load_token_hash()
_rate_lock = threading.Lock()
_rate_window = [0.0, 0]  # [window start, count]


def rate_ok() -> bool:
    now = time.monotonic()
    with _rate_lock:
        if now - _rate_window[0] >= 60:
            _rate_window[0], _rate_window[1] = now, 0
        _rate_window[1] += 1
        return _rate_window[1] <= RATE_PER_MIN


def b64_ok(s, min_len, max_len) -> bool:
    if not isinstance(s, str) or not (min_len <= len(s) <= max_len):
        return False
    try:
        base64.b64decode(s, validate=True)
        return True
    except Exception:
        return False


class Handler(BaseHTTPRequestHandler):
    server_version = "noop-inbox"
    sys_version = ""

    def _send(self, code: int, msg: str) -> None:
        body = json.dumps({"status": msg}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):  # status lines only; never bodies or headers
        sys.stderr.write("%s %s\n" % (self.log_date_time_string(), fmt % args))

    def do_GET(self):
        self._send(405, "method not allowed")

    do_PUT = do_DELETE = do_PATCH = do_HEAD = do_GET

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path not in ACCEPTED_PATHS:
            return self._send(404, "not found")
        if not rate_ok():
            return self._send(429, "rate limited")
        auth = self.headers.get("Authorization", "")
        token = auth[7:].strip() if auth.startswith("Bearer ") else ""
        if not hmac.compare_digest(hashlib.sha256(token.encode()).digest(), TOKEN_HASH):
            return self._send(401, "unauthorized")
        try:
            length = int(self.headers.get("Content-Length", "-1"))
        except ValueError:
            length = -1
        if length < 0:
            return self._send(411, "length required")
        if length > MAX_BODY:
            return self._send(413, "too large")
        try:
            doc = json.loads(self.rfile.read(length))
        except Exception:
            return self._send(400, "bad json")
        if not (isinstance(doc, dict) and set(doc) == {"v", "id", "nonceB64", "ciphertextB64"}
                and doc["v"] == 1 and isinstance(doc["id"], str) and UUID_RE.match(doc["id"])
                and b64_ok(doc["nonceB64"], 16, 16) and b64_ok(doc["ciphertextB64"], 24, MAX_BODY)):
            return self._send(400, "bad entry")
        final = os.path.join(INBOX_DIR, doc["id"] + ".json")
        if os.path.exists(final):
            return self._send(200, "duplicate")
        if len(os.listdir(INBOX_DIR)) >= MAX_FILES:
            return self._send(507, "inbox full")
        tmp = os.path.join(INBOX_DIR, "." + doc["id"] + ".tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(doc, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, final)
        return self._send(201, "stored")


if __name__ == "__main__":
    os.makedirs(INBOX_DIR, exist_ok=True)
    ThreadingHTTPServer((BIND, PORT), Handler).serve_forever()
