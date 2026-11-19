"""Local stand-in for an internal auth service: mints RS256 JWTs and publishes the JWKS.

Dev only. Anyone who can reach POST /mint gets a token for any subject.
"""

import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

ISSUER = os.environ.get("DEV_ISSUER_ISS", "auth-service")
DEFAULT_AUDIENCE = os.environ.get("DEV_ISSUER_AUD", "ai-llm-gateway")
KID = os.environ.get("DEV_ISSUER_KID", "001")
MAX_TTL = 600
KEY_PATH = Path(os.environ.get("DEV_ISSUER_KEY", "/data/key.pem"))


def load_key() -> rsa.RSAPrivateKey:
    if KEY_PATH.exists():
        return serialization.load_pem_private_key(KEY_PATH.read_bytes(), password=None)
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    KEY_PATH.parent.mkdir(parents=True, exist_ok=True)
    KEY_PATH.write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )
    KEY_PATH.chmod(0o600)
    return key


KEY = load_key()
JWKS = {
    "keys": [
        json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(KEY.public_key()))
        | {"kid": KID, "alg": "RS256", "use": "sig"}
    ]
}


def mint(sub: str, aud: str, ttl: int) -> str:
    now = int(time.time())
    claims = {"iss": ISSUER, "sub": sub, "aud": aud, "iat": now, "exp": now + min(ttl, MAX_TTL)}
    return jwt.encode(claims, KEY, algorithm="RS256", headers={"kid": KID})


class Handler(BaseHTTPRequestHandler):
    def _send(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path == "/.well-known/jwks.json":
            self._send(200, JWKS)
        elif self.path == "/health":
            self._send(200, {"status": "ok"})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self) -> None:
        if self.path != "/mint":
            self._send(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length") or 0)
        try:
            req = json.loads(self.rfile.read(length) or b"{}")
            sub = str(req["sub"])
        except (ValueError, KeyError):
            self._send(400, {"error": 'body must be JSON with a "sub"'})
            return
        token = mint(sub, str(req.get("aud", DEFAULT_AUDIENCE)), int(req.get("ttl", MAX_TTL)))
        self._send(200, {"jwt": token})


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
