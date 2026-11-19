#!/usr/bin/env python3
"""Local contract tests for noop_inbox.py: starts it on a free loopback port with a temp inbox."""
import base64, hashlib, json, os, socket, subprocess, sys, tempfile, time, urllib.request, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
TOKEN = "a" * 64

def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p

def post(port, body, token=TOKEN, raw=None):
    data = raw if raw is not None else json.dumps(body).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{port}/inbox", data=data, method="POST",
                                 headers={"Content-Type": "application/json",
                                          **({"Authorization": f"Bearer {token}"} if token else {})})
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code

def entry(**kw):
    d = {"v": 1, "id": str(uuid.uuid4()), "nonceB64": base64.b64encode(os.urandom(12)).decode(),
         "ciphertextB64": base64.b64encode(os.urandom(64)).decode()}
    d.update(kw); return d

with tempfile.TemporaryDirectory() as tmp:
    inbox = os.path.join(tmp, "inbox"); os.makedirs(inbox)
    hfile = os.path.join(tmp, "token.sha256")
    open(hfile, "w").write(hashlib.sha256(TOKEN.encode()).hexdigest())
    port = free_port()
    env = dict(os.environ, NOOP_INBOX_PORT=str(port), NOOP_INBOX_DIR=inbox, NOOP_INBOX_TOKEN_HASH_FILE=hfile)
    proc = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "noop_inbox.py")], env=env,
                            stderr=subprocess.DEVNULL)
    try:
        for _ in range(50):
            try: socket.create_connection(("127.0.0.1", port), 0.1).close(); break
            except OSError: time.sleep(0.1)
        e = entry()
        cases = [
            ("no token -> 401", post(port, entry(), token=None), 401),
            ("wrong token -> 401", post(port, entry(), token="b" * 64), 401),
            ("bad json -> 400", post(port, None, raw=b"{not json"), 400),
            ("extra field -> 400", post(port, entry(extra=1)), 400),
            ("bad uuid -> 400", post(port, entry(id="../../etc/passwd")), 400),
            ("bad nonce len -> 400", post(port, entry(nonceB64=base64.b64encode(b"x" * 8).decode())), 400),
            ("too large -> 413", post(port, entry(ciphertextB64="A" * 20000)), 413),
            ("valid -> 201", post(port, e), 201),
            ("duplicate -> 200", post(port, e), 200),
        ]
        req = urllib.request.Request(f"http://127.0.0.1:{port}/inbox", method="GET")
        try: urllib.request.urlopen(req, timeout=5); code = 200
        except urllib.error.HTTPError as err: code = err.code
        cases.append(("GET -> 405", code, 405))
        files = sorted(os.listdir(inbox))
        cases.append(("exactly one stored file", files, [e["id"] + ".json"]))
        cases.append(("stored file mode 0600", oct(os.stat(os.path.join(inbox, files[0])).st_mode & 0o777) if files else None, "0o600"))
        bad = [(n, got, want) for n, got, want in cases if got != want]
        for n, got, want in cases:
            print(("ok  " if got == want else "FAIL") + f" {n}" + ("" if got == want else f" (got {got!r})"))
        sys.exit(1 if bad else 0)
    finally:
        proc.terminate(); proc.wait()
