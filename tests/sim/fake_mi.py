"""Minimal stand-in for the MI Management API, driven by the hot-deploy directory:
a JamiiIntegrations_*.car present => CApp ACTIVE (or FAULTY if the file contains 'FAULTY')."""
import glob, json, os, sys, zipfile
from http.server import BaseHTTPRequestHandler, HTTPServer

CAPPS = sys.argv[2]

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, obj):
        b = json.dumps(obj).encode(); self.send_response(200)
        self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        cars = glob.glob(os.path.join(CAPPS, "JamiiIntegrations_*.car"))
        faulty = any(b"FAULTY" in open(c, "rb").read() for c in cars)
        active = bool(cars) and not faulty
        if self.path.endswith("/login"):
            return self.send({"AccessToken": "t"})
        if self.path.endswith("/applications"):
            return self.send({"activeList": [{"name": "JamiiIntegrations", "version": "1.0.0"}] if active else [],
                              "faultyList": [{"name": "JamiiIntegrations"}] if faulty else []})
        if self.path.endswith("/apis"):
            names = []
            if active:
                with zipfile.ZipFile(cars[0]) as z:
                    names = sorted({n.split("_")[0] for n in z.namelist() if n.endswith(".xml") and "API_1" in n and "metadata" not in n})
            return self.send({"count": len(names), "list": [{"name": n} for n in names]})
        if self.path.endswith("/data-services"):
            return self.send({"list": [{"name": "JamiiAccountDataService"}] if active else []})
        self.send_response(404); self.end_headers()

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
