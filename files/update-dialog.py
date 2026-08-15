#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class DialogState:
    def __init__(self, args):
        self.token = args.token
        self.version = args.version
        self.wrapper = args.wrapper
        self.test_mode = args.test
        self.html = Path(__file__).with_name("update-dialog.html").read_text()
        self.icon = Path(__file__).with_name("product_logo_128.png")
        self.updating = False
        self.updated = False
        self.lock = threading.Lock()


def compact_output(process):
    output = (process.stdout or "") + "\n" + (process.stderr or "")
    output = output.strip()
    return output[-1600:]


class Handler(BaseHTTPRequestHandler):
    server_version = "ChromeLocalUpdate/1.0"

    @property
    def state(self):
        return self.server.dialog_state

    def authorized(self):
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        return query.get("token", [""])[0] == self.state.token

    def send_json(self, payload, status=200):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def stop_server_later(self):
        time.sleep(0.2)
        self.server.shutdown()

    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        if path in ("/", "/index.html"):
            token = json.dumps(self.state.token)
            version = json.dumps(self.state.version)
            body = self.state.html.replace("__UPDATE_TOKEN__", token)
            body = body.replace("__UPDATE_VERSION__", version).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if path == "/icon.png" and self.state.icon.is_file():
            body = self.state.icon.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if path == "/api/status" and self.authorized():
            self.send_json({"updating": self.state.updating, "updated": self.state.updated})
            return

        self.send_error(404)

    def do_POST(self):
        path = urllib.parse.urlsplit(self.path).path
        if not self.authorized():
            self.send_error(403)
            return

        if path == "/api/update":
            with self.state.lock:
                if self.state.updating:
                    self.send_json({"ok": False, "error": "An update is already running."}, 409)
                    return
                self.state.updating = True

            if self.state.test_mode:
                self.state.updated = True
                self.state.updating = False
                self.send_json({"ok": True, "version": self.state.version, "test": True})
                return

            try:
                environment = os.environ.copy()
                environment["CHROME_LOCAL_SKIP_UPDATE_CHECK"] = "1"
                process = subprocess.run(
                    [self.state.wrapper, "__update-from-dialog"],
                    capture_output=True,
                    text=True,
                    env=environment,
                    timeout=1800,
                    check=False,
                )
                if process.returncode == 0:
                    self.state.updated = True
                    self.send_json({"ok": True, "version": self.state.version})
                else:
                    self.send_json({"ok": False, "error": compact_output(process)}, 500)
            except Exception as error:
                self.send_json({"ok": False, "error": str(error)}, 500)
            finally:
                self.state.updating = False
            return

        if path == "/api/restart":
            self.send_json({"ok": True})

            if self.state.test_mode:
                threading.Thread(target=self.stop_server_later, daemon=True).start()
                return

            def restart_later():
                time.sleep(0.4)
                environment = os.environ.copy()
                environment["CHROME_LOCAL_SKIP_UPDATE_CHECK"] = "1"
                subprocess.Popen(
                    [self.state.wrapper, "__restart"],
                    env=environment,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )

            threading.Thread(target=restart_later, daemon=True).start()
            return

        if path == "/api/later":
            self.send_json({"ok": True})
            threading.Thread(target=self.stop_server_later, daemon=True).start()
            return

        self.send_error(404)

    def log_message(self, _format, *_args):
        return


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--wrapper", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--token", default=None)
    parser.add_argument("--test", action="store_true")
    args = parser.parse_args()

    if args.token is None:
        import secrets

        args.token = secrets.token_urlsafe(24)

    state = DialogState(args)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.dialog_state = state
    port = server.server_address[1]
    url = f"http://127.0.0.1:{port}/?token={urllib.parse.quote(args.token)}"

    environment = os.environ.copy()
    environment["CHROME_LOCAL_SKIP_UPDATE_CHECK"] = "1"
    subprocess.Popen(
        [args.wrapper, f"--app={url}", "--new-window", "--window-size=520,360"],
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )

    threading.Timer(900, server.shutdown).start()
    server.serve_forever()
    server.server_close()


if __name__ == "__main__":
    main()
