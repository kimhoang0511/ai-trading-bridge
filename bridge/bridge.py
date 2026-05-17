"""
HTTP server — replaces Named Pipe.
EA sends POST http://127.0.0.1:PORT with JSON body, receives JSON response.
No DLL required — MT4 uses built-in WebRequest.
"""

import json
import logging
from http.server import HTTPServer, BaseHTTPRequestHandler

from config import HTTP_HOST, HTTP_PORT
from strategy import dispatch

log = logging.getLogger("bridge")


class _Handler(BaseHTTPRequestHandler):

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
            body   = self.rfile.read(length)
            data   = json.loads(body.decode("utf-8"))
            response = dispatch(data)
        except json.JSONDecodeError as e:
            log.error(f"JSON parse error: {e}")
            response = {"action": "NONE", "error": "invalid json"}
        except Exception as e:
            log.error(f"Handler error: {e}")
            response = {"action": "NONE", "error": str(e)}

        out = json.dumps(response).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def do_GET(self):
        # Health check — EA can ping before connecting
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"status":"ok"}')

    def log_message(self, fmt, *args):
        pass  # suppress default per-request HTTP logs


def run():
    server = HTTPServer((HTTP_HOST, HTTP_PORT), _Handler)
    log.info(f"HTTP server started → http://{HTTP_HOST}:{HTTP_PORT}")
    log.info("Waiting for EA connection...")
    log.info(f"Add to MT4 WebRequest whitelist: http://{HTTP_HOST}:{HTTP_PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
