#!/usr/bin/env python3
import json
import mimetypes
import os
import subprocess
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

BASE_DIR = Path.home() / "jobsaf"
WEB_DIR = BASE_DIR / "web"
DATA_DIR = BASE_DIR / "data"
RUN_SCRIPT = BASE_DIR / "run_now.sh"
LOCK_FILE = DATA_DIR / "run.lock"
RUN_MUTEX = threading.Lock()


def lock_active() -> bool:
    if not LOCK_FILE.exists():
        return False
    try:
        contents = LOCK_FILE.read_text(encoding="utf-8").strip()
    except Exception:
        return True
    if not contents:
        return True
    try:
        pid = int(contents.split()[0])
    except ValueError:
        return True
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        try:
            LOCK_FILE.unlink()
        except Exception:
            pass
        return False
    except PermissionError:
        return True


class Handler(BaseHTTPRequestHandler):
    server_version = "JobsAfTracker/1.0"

    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path.startswith("/data/"):
            rel = parsed.path[len("/data/") :]
            if not rel:
                self.send_error(404, "Missing file")
                return
            self.serve_file(DATA_DIR, rel)
            return
        if parsed.path == "/api/run":
            self.send_json({"ok": False, "error": "Use POST /api/run"})
            return
        rel = parsed.path.lstrip("/")
        if rel == "":
            rel = "index.html"
        self.serve_file(WEB_DIR, rel)

    def do_POST(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/api/run":
            self.handle_run()
            return
        self.send_error(404, "Not found")

    def handle_run(self) -> None:
        with RUN_MUTEX:
            if lock_active():
                self.send_json({"ok": True, "status": "busy"})
                return
            if not RUN_SCRIPT.exists():
                self.send_json(
                    {"ok": False, "status": "error", "error": "run_now.sh not found"}
                )
                return
            try:
                proc = subprocess.Popen(["bash", str(RUN_SCRIPT)], cwd=str(BASE_DIR))
            except Exception as exc:
                self.send_json({"ok": False, "status": "error", "error": str(exc)})
                return
            self.send_json({"ok": True, "status": "started", "pid": proc.pid})

    def serve_file(self, root: Path, rel: str) -> None:
        root = root.resolve()
        target = (root / rel).resolve()
        if not str(target).startswith(str(root)):
            self.send_error(403, "Forbidden")
            return
        if not target.exists() or not target.is_file():
            self.send_error(404, "Not found")
            return
        ctype = mimetypes.guess_type(str(target))[0] or "application/octet-stream"
        if ctype.startswith("text/") or ctype == "application/json":
            ctype += "; charset=utf-8"
        try:
            with target.open("rb") as f:
                data = f.read()
        except Exception:
            self.send_error(500, "Failed to read file")
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_json(self, payload: dict) -> None:
        data = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt: str, *args) -> None:
        return


def main() -> None:
    WEB_DIR.mkdir(parents=True, exist_ok=True)
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", 8080), Handler)
    print("Jobs.af Tracker server on http://127.0.0.1:8080/")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
