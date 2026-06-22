#!/usr/bin/env python3
"""Sign a Veritas license key with the private key in .secrets/.

    python3 scripts/sign-license.py --name "Jane Roe" --email jane@example.com

Prints the license key string to paste into the app's Enter License field. Use
this to fulfill an order by hand, or to mint your own owner key. The same offline
key format is produced by the Stripe webhook (web/api/stripe-webhook.js).
"""
import argparse
import base64
import datetime
import json
import os

from cryptography.hazmat.primitives import serialization

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PRIV = os.path.join(ROOT, ".secrets", "license-private.pem")


def b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--name", required=True)
    p.add_argument("--email", required=True)
    p.add_argument("--issued", default=None, help="YYYY-MM-DD (default: today)")
    a = p.parse_args()

    if not os.path.exists(PRIV):
        raise SystemExit("No private key. Run scripts/license-keygen.py first.")
    with open(PRIV, "rb") as f:
        priv = serialization.load_pem_private_key(f.read(), password=None)

    payload = {
        "name": a.name,
        "email": a.email,
        "product": "veritas",
        "issued": a.issued or datetime.date.today().isoformat(),
    }
    body = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
    sig = priv.sign(body)
    print(f"{b64url(body)}.{b64url(sig)}")


if __name__ == "__main__":
    main()
