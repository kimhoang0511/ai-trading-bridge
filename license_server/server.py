"""
license_server/server.py — Simple license validation server.
Deploy on any VPS (e.g. DigitalOcean, Heroku, Render.com).

Run: python server.py
     uvicorn server:app --host 0.0.0.0 --port 8000  (production)

Endpoints:
  POST /license/validate  { account, hwid, product } → { valid: bool }
  POST /license/add       { account, note }           → { ok: bool }    (admin)
  GET  /license/list                                  → [ accounts ]   (admin)
"""

import json
import os
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer

# ── License database (JSON file — swap for real DB in production) ─────────────
DB_FILE     = "licenses.json"
ADMIN_TOKEN = os.environ.get("ADMIN_TOKEN", "change-me-secret")


def _load_db() -> dict:
    if os.path.exists(DB_FILE):
        with open(DB_FILE) as f:
            return json.load(f)
    return {"accounts": {}}


def _save_db(db: dict) -> None:
    with open(DB_FILE, "w") as f:
        json.dump(db, f, indent=2)


def is_licensed(account: int) -> bool:
    db = _load_db()
    entry = db["accounts"].get(str(account))
    if not entry:
        return False
    # Check expiry if set
    if entry.get("expires"):
        exp = datetime.fromisoformat(entry["expires"])
        if datetime.utcnow() > exp:
            return False
    return entry.get("active", False)


# ── HTTP handler ──────────────────────────────────────────────────────────────
class Handler(BaseHTTPRequestHandler):

    def _read_json(self):
        length = int(self.headers.get("Content-Length", 0))
        body   = self.rfile.read(length)
        return json.loads(body.decode("utf-8"))

    def _send_json(self, data: dict, code: int = 200):
        out = json.dumps(data).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def do_POST(self):
        try:
            body = self._read_json()
        except Exception:
            self._send_json({"error": "invalid json"}, 400)
            return

        # ── POST /license/validate ────────────────────────────────────────────
        if self.path == "/license/validate":
            account = int(body.get("account", 0))
            valid   = is_licensed(account)
            self._send_json({"valid": valid})
            print(f"[validate] account={account} → valid={valid}")

        # ── POST /license/add (admin) ─────────────────────────────────────────
        elif self.path == "/license/add":
            if self.headers.get("X-Admin-Token") != ADMIN_TOKEN:
                self._send_json({"error": "unauthorized"}, 403)
                return
            account = str(int(body.get("account", 0)))
            db = _load_db()
            db["accounts"][account] = {
                "active":  True,
                "note":    body.get("note", ""),
                "added":   datetime.utcnow().isoformat(),
                "expires": body.get("expires"),   # None = lifetime
            }
            _save_db(db)
            print(f"[add] account={account} licensed")
            self._send_json({"ok": True})

        # ── POST /license/revoke (admin) ──────────────────────────────────────
        elif self.path == "/license/revoke":
            if self.headers.get("X-Admin-Token") != ADMIN_TOKEN:
                self._send_json({"error": "unauthorized"}, 403)
                return
            account = str(int(body.get("account", 0)))
            db = _load_db()
            if account in db["accounts"]:
                db["accounts"][account]["active"] = False
                _save_db(db)
            self._send_json({"ok": True})

        else:
            self._send_json({"error": "not found"}, 404)

    def do_GET(self):
        # ── GET /license/list (admin) ─────────────────────────────────────────
        if self.path == "/license/list":
            if self.headers.get("X-Admin-Token") != ADMIN_TOKEN:
                self._send_json({"error": "unauthorized"}, 403)
                return
            db = _load_db()
            self._send_json(db["accounts"])
        elif self.path == "/health":
            self._send_json({"status": "ok"})
        else:
            self._send_json({"error": "not found"}, 404)

    def log_message(self, fmt, *args):
        pass  # suppress default logs


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8000))
    server = HTTPServer(("0.0.0.0", port), Handler)
    print(f"License server running on port {port}")
    print(f"Admin token: {ADMIN_TOKEN}")
    print()
    print("Add license:   curl -X POST http://localhost:8000/license/add \\")
    print('               -H "X-Admin-Token: change-me-secret" \\')
    print('               -H "Content-Type: application/json" \\')
    print('               -d \'{"account": 12345678, "note": "customer name"}\'')
    server.serve_forever()
