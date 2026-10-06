"""Super Badger Station Standard API for nixstrata: GET (any path) -> {"<station>": {"<key>": <number>, ...}}.

Stands in for nixllm's badger adapter on the same port while a Strata server runs, with the same stations: the
names come from nixllm's station map (one "NAME=PORT[:GPUINDEX]" per line, 'nixllm badger map ...'), so Super
Badger sees gpu-a / gpu-b / ... whichever backend serves them. A station whose port a running Strata server
serves gets that server's stats; any other mapped station is reported with "up": 0, as nixllm's adapter reports
a station whose server is down. It ends itself once no Strata server is running (systemd then brings nixllm's
adapter back). Each Strata station gathers:
  - its server's GET /metrics (speed, expert cache hits/misses, drafts, totals)
  - its GPU (the map's GPUINDEX), or every GPU for a station without one, from amdgpu sysfs through Strata's own
    reader (serve/telemetry.py), numbered as HIP numbers them
  - system RAM, and its engine process's proportional memory (PSS: the shared expert arena split between the
    engines that map it)
Every value is a number or null. No auth, like the nixllm badger endpoint.

usage: nixstrata-badger.py <listen-port> <state-dir> <strata-share-dir> <engine-exe> <station-map> <server>...
  server: PORT=UNIT:CONFIG   one per Strata server unit
"""
import json
import os
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port, state, share, engine_exe, station_map = (int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4],
                                               sys.argv[5])
servers = {}                                   # port -> {"unit", "config"}
for spec in sys.argv[6:]:
    sport, rest = spec.split("=", 1)
    unit, config = rest.split(":", 1)
    servers[int(sport)] = {"unit": unit, "config": config}


def mapped_stations():
    """nixllm's station map, read on every request so 'nixllm badger map set' applies at once."""
    out = []
    try:
        with open(station_map, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return out
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, rest = line.split("=", 1)
        p, _, g = rest.partition(":")
        try:
            out.append({"name": name, "port": int(p), "gpu": int(g) if g.strip() else None})
        except ValueError:
            continue
    return out
sys.path.insert(0, share)
from serve.telemetry import gpu_reader  # noqa: E402  (Strata's amdgpu sysfs reader, HIP-ordered)

GIB = 1024 ** 3


def r1(x):
    return None if x is None else round(x, 1)


def pct(x):
    return None if x is None else round(x * 100, 1)


def active(unit):
    return subprocess.run(["systemctl", "is-active", "--quiet", unit]).returncode == 0


def strata_metrics(sport):
    req = urllib.request.Request(f"http://127.0.0.1:{sport}/metrics")
    try:
        with open(os.path.join(state, "apikey"), encoding="utf-8") as f:
            key = f.read().strip()
        if key:
            req.add_header("Authorization", f"Bearer {key}")
    except OSError:
        pass
    try:
        with urllib.request.urlopen(req, timeout=2) as r:
            return json.load(r)
    except Exception:
        return None


def read_int(path):
    try:
        with open(path, encoding="utf-8") as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return None


def all_gpus():
    out, i = [], 0
    while True:
        g = gpu_reader(i, amd=True)
        if not g.ok():
            return out
        d = g.read()
        # junction and memory temperatures, which Strata's reader leaves out (temp2 / temp3, m°C)
        junction = memory = None
        if g.hwmon:
            t2, t3 = read_int(os.path.join(g.hwmon, "temp2_input")), read_int(os.path.join(g.hwmon, "temp3_input"))
            junction = t2 / 1000 if t2 is not None else None
            memory = t3 / 1000 if t3 is not None else None
        used, total = d.get("mem_used"), d.get("mem_total")
        out.append({"temp_c": r1(d.get("temp")), "temp_junction_c": r1(junction), "temp_memory_c": r1(memory),
                    "util_pct": d.get("util"), "power_w": r1(d.get("power")),
                    "vram_used_gib": r1(used / GIB) if used is not None else None,
                    "vram_total_gib": r1(total / GIB) if total else None,
                    "vram_used_pct": r1(used * 100 / total) if used is not None and total else None})
        i += 1


def meminfo():
    kb = {}
    with open("/proc/meminfo", encoding="utf-8") as f:
        for line in f:
            k, v = line.split(":", 1)
            kb[k] = int(v.split()[0])
    total, avail = kb["MemTotal"], kb["MemAvailable"]
    return {"ram_used_gib": r1((total - avail) / 1024 ** 2), "ram_total_gib": r1(total / 1024 ** 2),
            "ram_used_pct": r1((total - avail) * 100 / total)}


def engine_pss_gib(config):
    """The memory of the engine this station's server started: the process running engine_exe whose parent's
    command line names this station's config. PSS, so a shared arena is split between the engines mapping it."""
    procs = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                cmd = f.read().split(b"\0")
            with open(f"/proc/{pid}/stat", encoding="utf-8") as f:
                ppid = f.read().rsplit(")", 1)[1].split()[1]
            procs[pid] = (cmd, ppid)
        except OSError:
            continue
    servers = {pid for pid, (cmd, _) in procs.items() if config.encode() in cmd}
    for pid, (_, ppid) in procs.items():
        if ppid not in servers:
            continue
        try:
            if os.readlink(f"/proc/{pid}/exe") != engine_exe:
                continue
            with open(f"/proc/{pid}/smaps_rollup", encoding="utf-8") as f:
                for line in f:
                    if line.startswith("Pss:"):
                        return r1(int(line.split()[1]) / 1024 ** 2)
        except OSError:
            continue
    return None


def gpu_summary(gs, prefix_all):
    s = {}
    if prefix_all:
        for i, g in enumerate(gs):
            for k, v in g.items():
                s[f"gpu{i}_{k}"] = v
    temps = [g["temp_c"] for g in gs if g["temp_c"] is not None]
    juncs = [g["temp_junction_c"] for g in gs if g["temp_junction_c"] is not None]
    mems = [g["temp_memory_c"] for g in gs if g["temp_memory_c"] is not None]
    utils = [g["util_pct"] for g in gs if g["util_pct"] is not None]
    powers = [g["power_w"] for g in gs if g["power_w"] is not None]
    used = [g["vram_used_gib"] for g in gs if g["vram_used_gib"] is not None]
    tot = [g["vram_total_gib"] for g in gs if g["vram_total_gib"]]
    # the hottest card (for "GPU over 85°C" alerts), mean load, total power and VRAM
    s.update({
        "gpu_count": len(gs),
        "gpu_temp_c": max(temps) if temps else None,
        "gpu_temp_junction_c": max(juncs) if juncs else None,
        "gpu_temp_memory_c": max(mems) if mems else None,
        "gpu_util_pct": r1(sum(utils) / len(utils)) if utils else None,
        "gpu_power_w": r1(sum(powers)) if powers else None,
        "vram_used_gib": r1(sum(used)) if used else None,
        "vram_used_pct": r1(sum(used) * 100 / sum(tot)) if used and tot else None,
    })
    return s


def gpu_part(gpus, idx):
    """A station's GPU keys: its own card (gpu_*) when the map names one, else every card (gpuN_* + summary)."""
    if idx is None:
        return gpu_summary(gpus, prefix_all=True)
    mine = gpus[idx:idx + 1]
    s = {f"gpu_{k}": v for k, v in (mine[0] if mine else {}).items()}   # this station's card
    s.update({k: v for k, v in gpu_summary(mine, prefix_all=False).items() if k not in s})
    s["gpu_index"] = idx
    return s


def down_stats(st, gpus, mem):
    """A mapped station no Strata server serves (its nixllm server is stopped while Strata runs)."""
    return {"up": 0, "loaded": 0, "generating": 0, "tokens_per_sec": 0, **mem, **gpu_part(gpus, st["gpu"])}


def station_stats(st, server, gpus, mem):
    m = strata_metrics(st["port"])
    live, eng, totals = (m or {}).get("live") or {}, (m or {}).get("engine") or {}, (m or {}).get("totals") or {}
    last = ((m or {}).get("requests") or [{}])[0]
    state_ = live.get("state")
    generating = state_ == "generating"
    prompt_ms, prompt_read = last.get("prompt_ms"), last.get("prompt_read")
    offered, accepted = last.get("drafts_offered"), last.get("drafts_accepted")
    hit = last.get("hit_rate")
    s = {
        "up": 1 if m is not None else 0,
        "loaded": 1 if state_ not in (None, "unloaded") else 0,
        "generating": 1 if generating else 0,
        "reading_prompt": 1 if state_ == "reading" else 0,
        "queued": live.get("queued"),
        # live speed while generating, else the last request's (what a dashboard wants to show)
        "tokens_per_sec": (live.get("tok_s") if generating else last.get("decode_tok_s")) or 0,
        "tokens_per_sec_mean": live.get("tok_s_mean") if generating else None,
        "prompt_progress_pct": r1(live["prompt_read"] * 100 / live["prompt_total"])
        if state_ == "reading" and live.get("prompt_read") is not None and live.get("prompt_total") else None,
        "last_decode_tok_s": last.get("decode_tok_s"),
        "last_prompt_tok_s": r1(prompt_read / (prompt_ms / 1000)) if prompt_ms and prompt_read else None,
        "last_prompt_tokens": last.get("prompt_tokens"),
        "last_output_tokens": last.get("output_tokens"),
        "last_duration_s": last.get("duration_s"),
        "expert_hit_pct": pct(hit),
        "expert_miss_pct": pct(1 - hit) if hit is not None else None,
        "expert_pcie_pct": pct(last.get("pcie_share")),
        "expert_misses_ram": last.get("ram_blobs"),
        "expert_misses_disk": last.get("file_blobs"),
        "draft_accept_pct": r1(accepted * 100 / offered) if offered and accepted is not None else None,
        "experts_in_vram": eng.get("expert_slots"),
        "context_max": eng.get("max_context"),
        "requests_total": totals.get("requests"),
        "prompt_tokens_total": totals.get("prompt_tokens"),
        "output_tokens_total": totals.get("output_tokens"),
        "engine_pss_gib": engine_pss_gib(server["config"]),
    }
    s.update(mem)
    s.update(gpu_part(gpus, st["gpu"]))
    return s


def stats():
    gpus, mem = all_gpus(), meminfo()
    running = {p for p, sv in servers.items() if active(sv["unit"])}
    out = {}
    for st in mapped_stations():
        if st["port"] in running:
            out[st["name"]] = station_stats(st, servers[st["port"]], gpus, mem)
        else:
            out[st["name"]] = down_stats(st, gpus, mem)
    return out


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            body, code = json.dumps(stats()).encode(), 200
        except Exception as e:   # never take the endpoint down over one bad read
            body, code = json.dumps({"error": str(e)}).encode(), 500
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def exit_when_idle():
    """Each nixstrata service starts this endpoint; it ends itself once none of them is running (checked twice,
    so a single->double switch, which stops one before starting the others, does not end it). A clean exit
    starts nixllm's adapter again (OnSuccess= in nixstrata.nix)."""
    idle = 0
    while True:
        time.sleep(15)
        idle = idle + 1 if not any(active(sv["unit"]) for sv in servers.values()) else 0
        if idle >= 2:
            os._exit(0)


threading.Thread(target=exit_when_idle, daemon=True).start()
ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
