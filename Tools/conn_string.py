"""ConnectionStrings:DefaultConnection of EMR.Web/appsettings.json for the repo's tools, with ENC: values decrypted.

ENC: values are AES-256-GCM, laid out and keyed exactly as EMR.Shared.Security/ConnectionStringCrypto.cs
(base64 of nonce(12) + tag(16) + ciphertext, built-in key). Keep the two in step.
"""
import base64
import json
import os

PREFIX = "ENC:"
ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

_KEY = bytes([
    0xcb, 0x13, 0xfb, 0x07, 0x3c, 0x9f, 0x48, 0x3d, 0x72, 0x9c, 0x0b, 0x99, 0x69, 0xf6, 0xbf, 0x37,
    0x28, 0xc8, 0x22, 0x22, 0x0b, 0xd1, 0xf4, 0xab, 0x64, 0x03, 0x34, 0x20, 0x1c, 0x2c, 0x19, 0xb8,
])


def decrypt(value):
    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    except ImportError:
        raise SystemExit("The connection string is encrypted (ENC:). Install the decryption package: "
                         "pip3 install -r Tools/datadictionary/requirements.txt")
    raw = base64.b64decode(value[len(PREFIX):].strip())
    nonce, tag, cipher = raw[:12], raw[12:28], raw[28:]
    return AESGCM(_KEY).decrypt(nonce, cipher + tag, None).decode("utf-8")


def default_connection():
    with open(os.path.join(ROOT, "EMR.Web", "appsettings.json"), encoding="utf-8-sig") as f:
        cs = json.load(f)["ConnectionStrings"]["DefaultConnection"]
    return decrypt(cs) if cs.startswith(PREFIX) else cs
