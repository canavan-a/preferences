"""Super Badger front for this box's badger port: nixstrata's commands, plus the station metrics passed through.

Always on, unlike the two metrics adapters, which take turns as Strata starts and stops (nixllm's socat adapter
while it is stopped, strata/nixstrata-badger.py while it runs). Both now listen on a localhost-only port and this
process owns the public one, so Super Badger keeps one URL and one key, and a command that starts or stops Strata
does not cut its own connection when the adapters swap.

  GET  /commands         the command list (super-badger's docs/command-spec.md), built from 'nixstrata state'
  POST /commands/<path>  run one; its output streams back as NDJSON {"log": ...} lines, then {"ok", "message"}
  GET  anything else     passed through to the running metrics adapter (502 while neither is up)

Every command runs the nixstrata CLI with fixed arguments (no shell) and NIXSTRATA_YES=1 to answer its prompts.
One runs at a time (409 for another), and it runs detached from the request: a client that hangs up mid-start
leaves it running, since killing a half-started double would be worse than finishing it.

Auth: when the key file (nixllm's badger key) is non-empty, every request needs "Authorization: Bearer <key>";
the header is passed on to the adapter too.

usage: nixstrata-control.py <listen-port> <adapter-port> <key-file>
"""
import json
import os
import subprocess
import sys
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

listen_port, adapter_port, key_file = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]

CONTEXTS = [("default", "Model default"), ("8192", "8k"), ("16384", "16k"), ("32768", "32k")]
SINGLES = [("single-01", "0,1", "Single · GPUs 0+1"), ("single-0", "0", "Single · GPU 0"),
           ("single-1", "1", "Single · GPU 1")]


def api_key():
    try:
        with open(key_file, encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


def state():
    """{mode: stopped|single|double, model, gpus, context, models: [{key, about, status}]}"""
    out = subprocess.run(["nixstrata", "state"], capture_output=True, text=True, timeout=30, check=True)
    return json.loads(out.stdout)


def restart_steps(st):
    """Re-apply settings to whatever is running (nothing when stopped)."""
    return {"double": [["double", "restart"]], "single": [["restart"]]}.get(st["mode"], [])


def command_list(st):
    mode, gpus, cmds = st["mode"], st["gpus"], []
    single_gpus = {"1,0": "0,1"}.get(gpus, gpus)
    for path, g, label in SINGLES:
        cmds.append({"path": path, "label": label, "group": "Mode",
                     "active": mode == "single" and single_gpus == g})
    cmds.append({"path": "double", "label": "Double · one per GPU", "group": "Mode", "active": mode == "double"})
    if mode != "stopped":
        cmds.append({"path": "restart", "label": "Restart", "group": "Mode"})
        cmds.append({"path": "stop", "label": "Stop", "group": "Mode", "confirm": "Stop the running model?"})

    ready = [m for m in st["models"] if m["status"] == "ready"]
    if ready:
        cmds.append({"path": "model", "label": "Model", "group": "Model",
                     "confirm": "Switch model? Whatever is running restarts on it." if mode != "stopped" else "",
                     "options": [{"value": m["key"], "label": m["key"], "active": m["key"] == st["model"]}
                                 for m in ready]})

    ctx = st["context"] or "default"
    cmds.append({"path": "context", "label": "Context", "group": "Context",
                 "options": [{"value": v, "label": label, "active": v == ctx} for v, label in CONTEXTS]})

    for c in cmds:
        c["url"] = f"/commands/{c['path']}"
    return cmds


def steps_for(path, option, st):
    """The CLI calls a command runs, or (None, error) when path/option isn't valid right now."""
    mode = st["mode"]
    # leaving double for single: 'nixstrata stop' also stops double's sticky proxy, which 'restart' leaves up
    leave_double = [["stop"]] if mode == "double" else []
    for p, g, _ in SINGLES:
        if path == p:
            return leave_double + [["gpus", g], ["restart"]], None
    if path == "double":
        return [["double", "restart"]], None
    if path == "restart" and mode != "stopped":
        return restart_steps(st), None
    if path == "stop" and mode != "stopped":
        return [["stop"]], None
    if path == "model":
        if option not in {m["key"] for m in st["models"] if m["status"] == "ready"}:
            return None, "not a downloaded model"
        return [["use", option]], None   # 'use' restarts whatever runs (its prompt is auto-answered)
    if path == "context":
        if option not in {v for v, _ in CONTEXTS}:
            return None, "not a context option"
        return [["context", option]] + restart_steps(st), None
    return None, "no such command"


class Job:
    """One command run: its output lines and outcome, shared with whichever request is following it."""

    def __init__(self, steps):
        self.steps, self.lines, self.result = steps, [], None
        self.cond = threading.Condition()

    def _emit(self, line):
        with self.cond:
            self.lines.append(line)
            self.cond.notify_all()

    def run(self):
        ok, last = True, ""
        env = {**_env, "NIXSTRATA_YES": "1"}
        for args in self.steps:
            self._emit("$ nixstrata " + " ".join(args))
            try:
                p = subprocess.Popen(["nixstrata", *args], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     stdin=subprocess.DEVNULL, text=True, env=env)
            except OSError as e:
                ok, last = False, str(e)
                break
            for line in p.stdout:
                line = line.rstrip()
                if line:
                    last = line
                    self._emit(line)
            if p.wait() != 0:
                ok = False
                break
        with self.cond:
            self.result = {"ok": ok, "message": last}
            self.cond.notify_all()

    def follow(self):
        """Yield events as they happen, ending with the result."""
        i = 0
        while True:
            with self.cond:
                while i == len(self.lines) and self.result is None:
                    self.cond.wait()
                new, i, result = self.lines[i:], len(self.lines), self.result
            for line in new:
                yield {"log": line}
            if result is not None and i == len(self.lines):
                yield result
                return


_env = dict(os.environ)
_job_lock = threading.Lock()
_job = None


def start_job(steps):
    global _job
    with _job_lock:
        if _job is not None and _job.result is None:
            return None
        _job = Job(steps)
        threading.Thread(target=_job.run, daemon=True).start()
        return _job


class Handler(BaseHTTPRequestHandler):
    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        key = api_key()
        if key and self.headers.get("Authorization", "") != f"Bearer {key}":
            self._json(401, {"error": "unauthorized"})
            return False
        return True

    def do_GET(self):
        if not self._authorized():
            return
        if self.path.split("?", 1)[0] == "/commands":
            try:
                self._json(200, command_list(state()))
            except Exception as e:
                self._json(500, {"error": f"nixstrata state: {e}"})
            return
        self._proxy()

    def _proxy(self):
        req = urllib.request.Request(f"http://127.0.0.1:{adapter_port}{self.path}")
        if self.headers.get("Authorization"):
            req.add_header("Authorization", self.headers["Authorization"])
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                code, ctype, body = r.status, r.headers.get("Content-Type", "application/json"), r.read()
        except urllib.error.HTTPError as e:
            code, ctype, body = e.code, e.headers.get("Content-Type", "application/json"), e.read()
        except Exception as e:
            self._json(502, {"error": f"metrics adapter unreachable: {e}"})
            return
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if not self._authorized():
            return
        prefix = "/commands/"
        if not self.path.startswith(prefix):
            self._json(404, {"error": "not found"})
            return
        path = self.path[len(prefix):]
        option = None
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            try:
                option = json.loads(self.rfile.read(n)).get("option")
            except (ValueError, AttributeError):
                self._json(400, {"error": "body must be JSON"})
                return
        try:
            st = state()
        except Exception as e:
            self._json(500, {"error": f"nixstrata state: {e}"})
            return
        steps, err = steps_for(path, option, st)
        if steps is None:
            self._json(400 if path in {"model", "context"} else 404, {"error": err})
            return
        job = start_job(steps)
        if job is None:
            self._json(409, {"error": "another command is still running"})
            return

        # HTTP/1.0 without Content-Length: the body ends when the connection closes
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        try:
            for ev in job.follow():
                self.wfile.write((json.dumps(ev) + "\n").encode())
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass   # the client left; the job carries on

    def log_message(self, *_):
        pass


ThreadingHTTPServer.daemon_threads = True
ThreadingHTTPServer(("0.0.0.0", listen_port), Handler).serve_forever()
