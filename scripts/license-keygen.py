#!/usr/bin/env python3
"""Generate the Veritas license signing keypair (Ed25519). Run ONCE.

Writes the PRIVATE key to .secrets/license-private.pem (gitignored). Keep it
secret: it mints license keys, and the webhook/CLI need it. Prints the PUBLIC
key (base64) to embed in
FilterCore/Sources/FilterCore/Licensing/Brand.swift as licensePublicKeyBase64.

    python3 scripts/license-keygen.py
"""
import base64
import os

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEC = os.path.join(ROOT, ".secrets")
os.makedirs(SEC, exist_ok=True)
priv_path = os.path.join(SEC, "license-private.pem")

if os.path.exists(priv_path):
    raise SystemExit(
        f"{priv_path} already exists; refusing to overwrite. Delete it to "
        "regenerate (this invalidates every license key already issued)."
    )

priv = Ed25519PrivateKey.generate()
pem = priv.private_bytes(
    serialization.Encoding.PEM,
    serialization.PrivateFormat.PKCS8,
    serialization.NoEncryption(),
)
with open(priv_path, "wb") as f:
    f.write(pem)
os.chmod(priv_path, 0o600)

pub_raw = priv.public_key().public_bytes(
    serialization.Encoding.Raw, serialization.PublicFormat.Raw
)
pub_b64 = base64.b64encode(pub_raw).decode()

print(f"Private key written to {priv_path} (gitignored — keep it secret).")
print()
print("Embed this in FilterCore/Sources/FilterCore/Licensing/Brand.swift:")
print(f'    static let licensePublicKeyBase64 = "{pub_b64}"')
