#!/usr/bin/env python3
"""Generate the Veritas license signing keypair (Ed25519). Run ONCE.

Writes the PRIVATE key to .secrets/license-private.pem (gitignored). Keep it
secret: it mints license keys, and the webhook/CLI need it. Prints the PUBLIC
key (base64) to embed in
FilterCore/Sources/FilterCore/Licensing/Brand.swift as licensePublicKeyBase64.

    python3 scripts/license-keygen.py
"""
import base64
import getpass
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

# Encrypt the key at rest with a passphrase. sign-license.py and the Stripe
# webhook read it from LICENSE_KEY_PASSPHRASE (or prompt). A blank passphrase
# keeps the old unencrypted behavior, but a passphrase means a backup or stray
# process can't read the raw key-minting bytes.
passphrase = os.environ.get("LICENSE_KEY_PASSPHRASE")
if passphrase is None:
    passphrase = getpass.getpass(
        "Passphrase to encrypt the signing key (blank = unencrypted): "
    )
encryption = (
    serialization.BestAvailableEncryption(passphrase.encode())
    if passphrase
    else serialization.NoEncryption()
)

priv = Ed25519PrivateKey.generate()
pem = priv.private_bytes(
    serialization.Encoding.PEM,
    serialization.PrivateFormat.PKCS8,
    encryption,
)
with open(priv_path, "wb") as f:
    f.write(pem)
os.chmod(priv_path, 0o600)

pub_raw = priv.public_key().public_bytes(
    serialization.Encoding.Raw, serialization.PublicFormat.Raw
)
pub_b64 = base64.b64encode(pub_raw).decode()

print(f"Private key written to {priv_path} (gitignored — keep it secret).")
if passphrase:
    print("Encrypted: set LICENSE_KEY_PASSPHRASE for sign-license.py and the webhook.")
print()
print("Embed this in FilterCore/Sources/FilterCore/Licensing/Brand.swift:")
print(f'    static let licensePublicKeyBase64 = "{pub_b64}"')
