"""Write the Strata server's config (strata.json) from nixstrata's settings.

Runs before every start (ExecStartPre), so `nixstrata context` / `gpus` only need a restart. The arguments are the
ones upstream's setup.py builds for a native pack (setup.py, "the start script" step), minus the parts that only
apply to other machines (CUDA, WSL, rotational disks, vision).

usage: nixstrata-config.py <state-dir> <catalog.json> <strata-package> [<instance> <gpu> <port> <arena-dir>]

Without an instance: the single server (strata.json, port 8080, the GPUs from `nixstrata gpus`).
With one (nixstrata double): strata-<instance>.json pinned to <gpu> on <port>, its expert arena in
<arena-dir>/<model>.arena - one MAP_SHARED file both instances use, so the ~50 GB of experts sit in RAM once.
"""
import json
import os
import sys
from pathlib import Path

state, catalog_f, pkg = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
instance = sys.argv[4] if len(sys.argv) > 4 else None
if instance is not None:
    inst_gpu, inst_port, arena_dir = int(sys.argv[5]), int(sys.argv[6]), Path(sys.argv[7])
suffix = f"-{instance}" if instance else ""
share = pkg / "share" / "strata"
sys.path.insert(0, str(share / "tools"))
from gguf_reader import GGUFFile  # noqa: E402  (upstream's reader, the one setup.py uses)


def fail(msg):
    print(f"nixstrata: {msg}", file=sys.stderr)
    sys.exit(1)


def settings(path: Path) -> dict:
    """KEY="VAL" lines, as the nixstrata CLI writes them."""
    out = {}
    if path.exists():
        for line in path.read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip().strip('"')
    return out


def total_ram_gb() -> float:
    for line in Path("/proc/meminfo").read_text().splitlines():
        if line.startswith("MemTotal:"):
            return int(line.split()[1]) * 1024 / 1e9
    return 0.0


def hipblaslt_version() -> int | None:
    """hipBLASLt's version as the engine reads it (1.4.1 -> 100401), from the header of the ROCm the engine links;
    the same check as setup.py's hipblaslt_version."""
    hdr = os.environ.get("NIXSTRATA_HIPBLASLT_HEADER")
    if not hdr or not Path(hdr).exists():
        return None
    v = {}
    for line in Path(hdr).read_text().splitlines():
        p = line.split()
        if len(p) == 3 and p[0] == "#define" and p[1].startswith("HIPBLASLT_VERSION_") and p[2].isdigit():
            v[p[1].rsplit("_", 1)[1]] = int(p[2])
    if not all(k in v for k in ("MAJOR", "MINOR", "PATCH")):
        return None
    return v["MAJOR"] * 100000 + v["MINOR"] * 100 + v["PATCH"]


cfg_in = settings(state / "config")
catalog = json.loads(catalog_f.read_text())
key = cfg_in.get("STRATA_MODEL", "")
if not key:
    fail("no model selected - run 'nixstrata use'")
if key not in catalog:
    fail(f"unknown model '{key}' (catalog: {', '.join(catalog)})")
m = catalog[key]
shards = [Path(m["dir"]) / f for f in m["files"]]
missing = [s.name for s in shards if not s.exists()]
if missing:
    fail(f"{key}: shards missing in {m['dir']}: {', '.join(missing)} - run 'nixstrata pull {key}'")
pack = state / "packs" / key
if not (pack / "native_experts.txt").exists() or not (pack / "tokenizer" / "vocab.json").exists():
    fail(f"{key}: no pack yet - run 'nixstrata use {key}'")
rt = state / "mtp" / "rt"
if not (rt / "experts.bin").exists():
    fail(f"the MTP draft layer is missing ({rt}) - run 'nixstrata use {key}'")

ctx = int(cfg_in.get("STRATA_CTX") or m["context"])
if instance is not None:
    gpus = [inst_gpu]
else:
    gpus = [int(g) for g in (cfg_in.get("STRATA_GPUS") or "0,1").split(",") if g.strip() != ""]

# The PLE table's shard, found by tensor name (shard 1 for the Orca GGUFs, shard 2 for the original model).
ple = next((s for s in shards if any(t.name == "per_layer_token_embd.weight" for t in GGUFFile(s).tensors)), None)
if ple is None:
    fail(f"{key}: no per_layer_token_embd tensor in its shards (is this a Qwen3.8-Flash-Next GGUF?)")

args = ["--pack", str(pack), "--native", str(shards[0]), "--ple-gguf", str(ple),
        "--expert-profile", str(share / "data" / m.get("profile", "expert-profile.bin")),
        "--expert-cache", "auto", "--prefill", str(m.get("prefill", "auto")),
        "--spec", "4", "--spec-min-p", "0.5", "--mtp", str(rt), "--max-context", str(ctx)]
if ctx > 8192:
    args += ["--kv", "int8"]
# KV streaming (setup.py's rule): from 64K the KV cache lives in RAM and the VRAM it frees holds more experts.
kv_ram_gb = ctx * 13 * 1056 / 1e9
if ctx >= 65536 and total_ram_gb() >= m["ram_gb"] + kv_ram_gb + 1:
    args += ["--kv-resident", "32768"]
args += m.get("extra_args", [])
if instance is not None:
    # one MAP_SHARED copy of the expert arena for both instances (engine: Linux, checked against the pack's hash)
    args += ["--shared-expert-arena", str(arena_dir / f"{key}.arena")]

out = {
    "exe": str(pkg / "libexec" / "strata" / "strata"),
    "args": args,
    "cwd": str(state),
    "tokenizer": str(pack / "tokenizer"),
    "model_name": key,
    "log": str(state / f"strata{suffix}.log"),
    "backend": "hip",
    "host": "0.0.0.0",
    "port": inst_port if instance is not None else 8080,
    "open_browser": False,
}
if len(gpus) > 1:
    out["gpu"] = gpus
    out["layer_split"] = "auto"
    out["args"].append("--remote-expert-opt")   # setup.py's recommend_remote_expert_opt for 2+ GPUs
elif gpus:
    out["gpu"] = gpus[0]
out["gpus_asked"] = True
# Qwen's recommended thinking-mode sampling (Qwen3.8-Flash-Next model card, "Best Practices"), as the default for
# any field a request leaves out - without it Strata decodes greedily, which makes reasoning loops more likely.
# A request's own values still win. A catalog entry's "sampling" replaces it.
out["sampling"] = m.get("sampling", {"temperature": 1.0, "top_p": 0.95, "top_k": 20, "min_p": 0.0,
                                     "presence_penalty": 0.0, "repetition_penalty": 1.0})
# /api-monitor: the last 100 API requests' prompts and answers, kept in memory (off unless asked for)
if cfg_in.get("STRATA_API_MONITOR") == "on":
    out["api_monitor"] = True
key_f = state / "apikey"
if key_f.exists() and key_f.read_text().strip():
    out["api_key"] = key_f.read_text().strip()

# The prompt GEMM tuning table, only for this card AND this hipBLASLt (the engine refuses any other).
ver = hipblaslt_version()
table = share / "tools" / "hip" / f"gfx1100-hipblaslt-{ver}.txt"
if ver is not None and table.exists():
    out["env"] = {"STRATA_HIPBLASLT_TUNING": str(table)}
    print(f"nixstrata: hipBLASLt tuning table {table.name}")
else:
    print(f"nixstrata: no gfx1100 hipBLASLt table for version {ver}: plain hipBLAS for prompt GEMMs")

tmp = state / f"strata{suffix}.json.tmp"
tmp.write_text(json.dumps(out, indent=1))
tmp.replace(state / f"strata{suffix}.json")
print(f"nixstrata{suffix}: {key}, context {ctx}, GPUs {gpus}, port {out['port']}, args: {' '.join(args)}")
