"""Super Badger Station Standard API for nixstrata: GET (any path) -> {"<station>": {"<key>": <number>, ...}}.

Runs alongside the nixstrata service (started and stopped with it). Each request gathers:
  - the Strata server's GET /metrics (speed, expert cache hits/misses, drafts, totals)
  - every AMD GPU from amdgpu sysfs, through Strata's own reader (serve/telemetry.py), numbered as HIP numbers
    them - the same gpu0/gpu1 as Strata's layer split
  - system RAM and the engine process's own resident memory
Every value is a number or null. No auth, like the nixllm badger endpoint.

usage: nixstrata-badger.py <listen-port> <strata-port> <station-name> <state-dir> <strata-share-dir> <engine-exe>
"""
import json
import os
import sys
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port, strata_port, station, state, share, engine_exe = (int(sys.argv[1]), int(sys.argv[2]), sys.argv[3],
                                                        sys.argv[4], sys.argv[5], sys.argv[6])
sys.path.insert(0, share)
from serve.telemetry import gpu_reader  # noqa: E402  (Strata's amdgpu sysfs reader, HIP-ordered)

GIB = 1024 ** 3


def r1(x):
    return None if x is None else round(x, 1)


def pct(x):
    return None if x is None else round(x * 100, 1)


def strata_metrics():
    req = urllib.request.Request(f"http://127.0.0.1:{strata_port}/metrics")
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


def gpus():
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


def engine_rss_gib():
    """The Strata engine process's resident memory (its pinned expert arena lives here)."""
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            if os.readlink(f"/proc/{pid}/exe") != engine_exe:
                continue
            with open(f"/proc/{pid}/status", encoding="utf-8") as f:
                for line in f:
                    if line.startswith("VmRSS:"):
                        return r1(int(line.split()[1]) / 1024 ** 2)
        except OSError:
            continue
    return None


def station_stats():
    s = {}
    m = strata_metrics()
    live, eng, totals = (m or {}).get("live") or {}, (m or {}).get("engine") or {}, (m or {}).get("totals") or {}
    last = ((m or {}).get("requests") or [{}])[0]
    state_ = live.get("state")
    generating = state_ == "generating"
    prompt_ms, prompt_read = last.get("prompt_ms"), last.get("prompt_read")
    offered, accepted = last.get("drafts_offered"), last.get("drafts_accepted")
    hit = last.get("hit_rate")
    s.update({
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
        "engine_rss_gib": engine_rss_gib(),
    })
    s.update(meminfo())

    gs = gpus()
    for i, g in enumerate(gs):
        for k, v in g.items():
            s[f"gpu{i}_{k}"] = v
    temps = [g["temp_c"] for g in gs if g["temp_c"] is not None]
    juncs = [g["temp_junction_c"] for g in gs if g["temp_junction_c"] is not None]
    utils = [g["util_pct"] for g in gs if g["util_pct"] is not None]
    powers = [g["power_w"] for g in gs if g["power_w"] is not None]
    used = [g["vram_used_gib"] for g in gs if g["vram_used_gib"] is not None]
    tot = [g["vram_total_gib"] for g in gs if g["vram_total_gib"]]
    # box-wide summaries: the hottest card (for "GPU over 85°C" alerts), mean load, total power and VRAM
    s.update({
        "gpu_count": len(gs),
        "gpu_temp_c": max(temps) if temps else None,
        "gpu_temp_junction_c": max(juncs) if juncs else None,
        "gpu_util_pct": r1(sum(utils) / len(utils)) if utils else None,
        "gpu_power_w": r1(sum(powers)) if powers else None,
        "vram_used_gib": r1(sum(used)) if used else None,
        "vram_used_pct": r1(sum(used) * 100 / sum(tot)) if used and tot else None,
    })
    return {station: s}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            body = json.dumps(station_stats()).encode()
            code = 200
        except Exception as e:   # never take the endpoint down over one bad read
            body, code = json.dumps({"error": str(e)}).encode(), 500
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
