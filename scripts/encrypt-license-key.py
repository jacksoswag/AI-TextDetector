#!/usr/bin/env python3
"""Encrypt the existing Pilcrow signing key in place. Run ONCE.

This keeps the SAME keypair: the public key in Brand.swift and every license
already issued stay valid. It only adds a passphrase to the on-disk PEM so a
Time Machine backup or a stray process can't read the raw key-minting bytes.

After running, set LICENSE_KEY_PASSPHRASE in the environment for
scripts/sign-license.py and in the Stripe webhook's config so they can still
sign. The passphrase is never written to disk.

    python3 scripts/encrypt-license-key.py
"""
import getpass
import os

from cryptography.hazmat.primitives import serialization

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PRIV = os.path.join(ROOT, ".secrets", "license-private.pem")

if not os.path.exists(PRIV):
    raise SystemExit("No private key at .secrets/license-private.pem.")

with open(PRIV, "rb") as f:
    data = f.read()

if b"ENCRYPTED" in data.split(b"\n", 1)[0]:
    raise SystemExit("Key is already encrypted; nothing to do.")

priv = serialization.load_pem_private_key(data, password=None)

pw = getpass.getpass("New passphrase for the signing key: ")
if not pw:
    raise SystemExit("Empty passphrase; aborted.")
if pw != getpass.getpass("Confirm passphrase: "):
    raise SystemExit("Passphrases did not match; aborted.")

pem = priv.private_bytes(
    serialization.Encoding.PEM,
    serialization.PrivateFormat.PKCS8,
    serialization.BestAvailableEncryption(pw.encode()),
)
with open(PRIV, "wb") as f:
    f.write(pem)
os.chmod(PRIV, 0o600)

print(f"Encrypted {PRIV} in place (same keypair; issued licenses still valid).")
print("Set LICENSE_KEY_PASSPHRASE for sign-license.py and the Stripe webhook.")
