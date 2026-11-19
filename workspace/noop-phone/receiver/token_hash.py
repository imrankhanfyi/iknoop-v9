#!/usr/bin/env python3
"""Print SHA-256(authToken) for /etc/noop-inbox/token.sha256 on Freckleclaw. Prints ONLY the hash.

Reads the viewer passphrase from the Mac login keychain (service `noop-publish`), derives the inbox auth
token exactly as noop_inbox.py documents, and prints the hash the server stores. Neither the passphrase
nor the token is ever printed or written. `--selftest` checks the derivation against fixed vectors that
viewer/app.js and the Mac puller must also reproduce.
"""
import getpass, hashlib, hmac, subprocess, sys

SALT = b"noop-phone-inbox-v1"
ITERATIONS = 600_000

def derive(passphrase: str):
    master = hashlib.pbkdf2_hmac("sha256", passphrase.encode("utf-8"), SALT, ITERATIONS, 32)
    token = hmac.new(master, b"inbox-auth", hashlib.sha256).hexdigest()
    entry_key = hmac.new(master, b"entry-enc", hashlib.sha256).digest()
    return token, entry_key

if "--selftest" in sys.argv:
    token, key = derive("phase1-test")
    print("vector passphrase='phase1-test'")
    print("  authToken =", token)
    print("  entryKey  =", key.hex())
    print("  tokenHash =", hashlib.sha256(token.encode()).hexdigest())
    sys.exit(0)

pw = subprocess.run(["security", "find-generic-password", "-w", "-s", "noop-publish", "-a", getpass.getuser()],
                    capture_output=True, text=True, check=True).stdout.strip()
if not pw:
    sys.exit("no passphrase in the keychain (service noop-publish)")
token, _ = derive(pw)
print(hashlib.sha256(token.encode()).hexdigest())
