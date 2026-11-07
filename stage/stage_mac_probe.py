#!/usr/bin/env python3
"""QED Understudy Stage: Mac mini feasibility probe.

Checks whether this Mac can run the Stage music sidecar (Demucs stem separation + Seed-VC singing
conversion) on its Apple GPU (Metal / MPS) until the rented NVIDIA GPU is in place.

    python3 stage_mac_probe.py              # full run: about 20-45 min plus about 3.5 GB of downloads the first time
    python3 stage_mac_probe.py --quick      # shorter run: one model, one conversion

It needs only the Python 3 that ships with macOS and an internet connection. Everything goes into
~/qed-stage-probe (delete that folder to remove it). Nothing is installed system-wide, nothing runs at
login, and nothing is sent anywhere: the result is a Markdown report written next to this script.
Send that .md file back. Re-running reuses the downloads and overwrites the report.

Pinned to what the Stage sidecar ships: Python 3.11, PyTorch 2.4.0, Demucs 4.0.1, and Seed-VC at commit
51383ef (GPL-3.0; downloaded from github.com/Plachtaa/seed-vc and run only inside this probe folder).
The Stage model code (stage/backends.py) is embedded below exactly as it is on the Understudy
stage-music-qpa branch.
"""
from __future__ import annotations

import argparse
import base64
import datetime as _dt
import hashlib
import io
import json
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import time
import traceback
import urllib.request
import zlib
from pathlib import Path

PROBE_VERSION = "1.1"
SEEDVC_COMMIT = "51383efd921027683c89e5348211d93ff12ac2a8"
PYTHON = "3.11"
REQUIREMENTS = [
    "torch==2.4.0", "torchaudio==2.4.0", "numpy==1.26.4", "scipy==1.13.1", "librosa==0.10.2",
    "soundfile==0.12.1", "huggingface-hub>=0.28.1,<1", "munch==4.0.0", "einops==0.8.0",
    "transformers==4.46.3", "descript-audio-codec==1.0.0", "hydra-core==1.3.2", "pyyaml",
    "python-dotenv", "demucs==4.0.1", "psutil",
]
SOURCE_14 = "TECHNOPOLIS - 2085 [vocals]_[cut_14sec].wav"
SOURCE_28 = "Wiz Khalifa,Charlie Puth - See You Again [vocals]_[cut_28sec].wav"
REFERENCE = "s1p1.wav"
SONG_SECONDS = 210  # a 3.5-minute song, used for the time estimates

# Bar for "usable as the interim Stage GPU for QPA" (a few takes a day, one job at a time).
GO_SONG_MIN = 10.0        # convert a 3.5-min vocal at 30 steps in <= 10 min
MARGINAL_SONG_MIN = 30.0  # <= 30 min is workable for overnight / batch use
MIN_MEL_CORR = 0.8        # melody kept
MIN_RAM_GB = 16

BACKENDS_SHA256 = "0cde40df93628e5590c1c9937861437e10b20f59cb8ddcd6551cc014146a6889"
BACKENDS_B64 = "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"


# ===================================================================== shared: state + report
def now() -> str:
    return _dt.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M %Z")


def home_rel(p) -> str:
    s = str(p)
    h = str(Path.home())
    return "~" + s[len(h):] if s.startswith(h) else s


def load_state(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except Exception:
        return {}


def save_state(path: Path, state: dict) -> None:
    path.write_text(json.dumps(state, indent=1, default=str))


def fmt(v, unit="", nd=1):
    if v is None:
        return "n/a"
    if isinstance(v, float):
        return f"{v:.{nd}f}{unit}"
    return f"{v}{unit}"


def verdict(state: dict):
    m, r = state.get("machine", {}), state.get("results", {})
    reasons = []
    dev = r.get("device")
    conv = r.get("convert", {})
    song_min = conv.get("song_estimate_minutes")
    corr = conv.get("melody_corr")
    sep_ok = r.get("separate_ok")
    errors = state.get("errors", [])
    if not r:
        return "INCOMPLETE", ["The benchmark did not run; see Errors."]
    if dev != "mps":
        reasons.append(f"Ran on {dev}, not the Apple GPU (MPS unavailable: {r.get('mps_reason', 'unknown')}).")
    ram = m.get("ram_gb")
    if ram is not None and ram < MIN_RAM_GB:
        reasons.append(f"Only {ram} GB memory; {MIN_RAM_GB} GB or more is the bar.")
    if not sep_ok:
        reasons.append("Stem separation did not complete.")
    if song_min is None:
        reasons.append("Singing conversion did not complete.")
        return ("NO-GO" if errors else "INCOMPLETE"), reasons
    if corr is not None and corr < MIN_MEL_CORR:
        reasons.append(f"Melody correlation {corr:.2f} is under {MIN_MEL_CORR}.")
    if dev == "mps" and sep_ok and (corr is None or corr >= MIN_MEL_CORR) and (ram is None or ram >= MIN_RAM_GB):
        if song_min <= GO_SONG_MIN:
            return "GO", reasons + [f"About {song_min:.1f} min to convert a 3.5-min vocal at 30 steps."]
        if song_min <= MARGINAL_SONG_MIN:
            return "MARGINAL", reasons + [f"About {song_min:.1f} min per 3.5-min vocal at 30 steps: fine for batch/overnight, slow for live sessions."]
        return "NO-GO", reasons + [f"About {song_min:.1f} min per 3.5-min vocal at 30 steps."]
    return "NO-GO", reasons


def render(state: dict) -> str:
    m, sw, r = state.get("machine", {}), state.get("software", {}), state.get("results", {})
    v, why = verdict(state)
    L = []
    L.append("# QED Stage: Mac mini GPU probe")
    L.append("")
    L.append(f"Probe {PROBE_VERSION}, run {state.get('started', '?')}, finished {state.get('finished', 'not finished')}. "
             f"Mode: {'quick' if state.get('quick') else 'full'}.")
    L.append("")
    L.append(f"## Verdict: {v}")
    L.append("")
    for w in why:
        L.append(f"- {w}")
    L.append(f"- Bar: Apple GPU used, at least {MIN_RAM_GB} GB memory, melody correlation at least {MIN_MEL_CORR}, "
             f"3.5-min vocal at 30 steps in {GO_SONG_MIN:.0f} min or less (GO) or {MARGINAL_SONG_MIN:.0f} min or less (MARGINAL).")
    L.append("")
    L.append("## Machine")
    L.append("")
    L.append("| Item | Value |")
    L.append("|---|---|")
    for k, label in [("model", "Model"), ("chip", "Chip"), ("gpu_cores", "GPU cores"), ("cpu_cores", "CPU cores (perf/eff)"),
                     ("ram_gb", "Memory (GB)"), ("macos", "macOS"), ("arch", "Architecture"), ("rosetta", "Running under Rosetta"),
                     ("disk_free_gb", "Free disk (GB)"), ("power", "Power"), ("low_power_mode", "Low Power Mode"),
                     ("system_python", "System Python")]:
        if k in m:
            L.append(f"| {label} | {m[k]} |")
    L.append("")
    if sw:
        L.append("## Software")
        L.append("")
        L.append("| Item | Value |")
        L.append("|---|---|")
        for k, val in sw.items():
            L.append(f"| {k} | {val} |")
        L.append("")
    if r:
        L.append("## Results")
        L.append("")
        L.append(f"Device used: **{r.get('device')}**. MPS available: {r.get('mps_available')}"
                 + (f" ({r.get('mps_reason')})" if r.get("mps_reason") else "") + ".")
        L.append("")
        mm = r.get("matmul", {})
        if mm:
            L.append("Raw compute, 2048x2048 float32 matmul: " + ", ".join(f"{d} {fmt(g, ' GFLOP/s', 0)}" for d, g in mm.items()) + ".")
            L.append("")
        seps = r.get("separate", [])
        if seps:
            L.append("### Stem separation (Demucs)")
            L.append("")
            L.append("| Model | Device | Clip (s) | Load (s) | First run (s) | Warm run (s) | x real time (warm) | Vocal SDR (dB) |")
            L.append("|---|---|---|---|---|---|---|---|")
            for s in seps:
                L.append(f"| {s.get('model')} | {s.get('device')} | {fmt(s.get('clip_s'))} | {fmt(s.get('load_s'))} | {fmt(s.get('first_s'))} | "
                         f"{fmt(s.get('warm_s'))} | {fmt(s.get('rtf'), '', 2)} | {fmt(s.get('sdr_db'))} |")
            L.append("")
            L.append(f"SDR baseline (the unseparated mix): {fmt(r.get('sdr_baseline_db'))} dB. Higher is better; above 10 dB is clean. "
                     "x real time = seconds of compute per second of audio (under 1 is faster than real time).")
            L.append("")
        convs = r.get("conversions", [])
        if convs:
            L.append("### Singing conversion (Seed-VC, F0-conditioned 44.1 kHz)")
            L.append("")
            L.append("| Clip | Device | Steps | Run | Time (s) | x real time | Melody corr | Voiced overlap | Key shift (st) |")
            L.append("|---|---|---|---|---|---|---|---|---|")
            for c in convs:
                L.append(f"| {fmt(c.get('clip_s'))} s | {c.get('device')} | {c.get('steps')} | {c.get('run')} | {fmt(c.get('seconds'))} | "
                         f"{fmt(c.get('rtf'), '', 2)} | {fmt(c.get('melody_corr'), '', 3)} | {fmt(c.get('voiced_overlap'), '', 3)} | {fmt(c.get('key_shift'), '', 1)} |")
            L.append("")
            if r.get("svc_load_s") is not None:
                L.append(f"Seed-VC model load: {fmt(r.get('svc_load_s'))} s (first run includes downloads).")
                L.append("")
        conv = r.get("convert", {})
        if conv:
            L.append("### Estimate for a 3.5-minute song")
            L.append("")
            L.append(f"- Separate stems: about {fmt(r.get('song_separate_minutes'))} min ({r.get('song_separate_basis', '')}).")
            how = ("measured at 30 steps" if conv.get("basis_steps") == 30
                   else f"scaled from {conv.get('basis_steps')} steps, an upper bound")
            L.append(f"- Sing as (30 steps): about {fmt(conv.get('song_estimate_minutes'))} min (from the {fmt(conv.get('basis_clip_s'))} s clip, warm, {how}).")
            L.append("")
        mem = r.get("memory", {})
        if mem:
            L.append("### Memory")
            L.append("")
            L.append(f"Peak process memory {fmt(mem.get('peak_rss_gb'), ' GB', 2)}; peak Metal driver allocation {fmt(mem.get('peak_mps_driver_gb'), ' GB', 2)}; "
                     f"swap used at end {fmt(mem.get('swap_used_gb'), ' GB', 2)}.")
            L.append("")
        fb = r.get("mps_fallback_ops", [])
        L.append("### Operations that fell back to CPU")
        L.append("")
        if fb:
            for o in fb:
                L.append(f"- `{o}`")
        else:
            L.append("None reported." if r.get("device") == "mps" else "Not applicable (not on MPS).")
        L.append("")
        outs = r.get("outputs", [])
        if outs:
            L.append("### Output audio (listen on the Mac)")
            L.append("")
            for o in outs:
                L.append(f"- `{o}`")
            L.append("")
    errs = state.get("errors", [])
    L.append("## Errors")
    L.append("")
    if errs:
        for e in errs:
            L.append(f"### {e.get('step')}")
            L.append("")
            L.append("```")
            L.append(str(e.get("trace", ""))[-4000:])
            L.append("```")
            L.append("")
    else:
        L.append("None.")
        L.append("")
    if state.get("log_tail"):
        L.append("## Install log (last lines)")
        L.append("")
        L.append("```")
        L.append(state["log_tail"][-3000:])
        L.append("```")
        L.append("")
    L.append("## Raw data")
    L.append("")
    L.append("```json")
    L.append(json.dumps({k: state.get(k) for k in ("machine", "software", "results", "quick", "started", "finished")}, indent=1, default=str))
    L.append("```")
    L.append("")
    return "\n".join(L)


def write_report(state: dict, out: Path) -> None:
    out.write_text(render(state))


def add_error(state: dict, step: str) -> None:
    state.setdefault("errors", []).append({"step": step, "trace": traceback.format_exc()})


# ===================================================================== bootstrap (system Python, stdlib only)
def sh(cmd, timeout=30) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout.strip()
    except Exception:
        return ""


def machine_info(workdir: Path) -> dict:
    m: dict = {"arch": platform.machine(), "system_python": platform.python_version()}
    if sys.platform == "darwin":
        m["macos"] = sh(["sw_vers", "-productVersion"])
        m["model"] = sh(["sysctl", "-n", "hw.model"])
        m["chip"] = sh(["sysctl", "-n", "machdep.cpu.brand_string"])
        try:
            m["ram_gb"] = round(int(sh(["sysctl", "-n", "hw.memsize"])) / 2 ** 30)
        except ValueError:
            pass
        p, e = sh(["sysctl", "-n", "hw.perflevel0.physicalcpu"]), sh(["sysctl", "-n", "hw.perflevel1.physicalcpu"])
        m["cpu_cores"] = f"{sh(['sysctl', '-n', 'hw.ncpu'])} ({p or '?'}/{e or '?'})"
        m["rosetta"] = "yes" if sh(["sysctl", "-n", "sysctl.proc_translated"]) == "1" else "no"
        try:
            d = json.loads(sh(["system_profiler", "SPDisplaysDataType", "-json"], timeout=60) or "{}")
            g = (d.get("SPDisplaysDataType") or [{}])[0]
            m["gpu_cores"] = g.get("sppci_cores", "?")
        except Exception:
            pass
        batt = sh(["pmset", "-g", "batt"]).splitlines()
        m["power"] = batt[0].replace("Now drawing from ", "").strip("'") if batt else "?"
        lp = [ln for ln in sh(["pmset", "-g"]).splitlines() if "lowpowermode" in ln]
        m["low_power_mode"] = ("on" if lp and lp[0].split()[-1] == "1" else "off") if lp else "n/a"
    else:
        m["macos"] = f"not macOS ({platform.platform()})"
        m["chip"] = platform.processor() or platform.machine()
        try:
            kb = int([ln for ln in open("/proc/meminfo") if ln.startswith("MemTotal")][0].split()[1])
            m["ram_gb"] = round(kb / 2 ** 20)
        except Exception:
            pass
        m["cpu_cores"] = str(os.cpu_count())
    workdir.mkdir(parents=True, exist_ok=True)
    m["disk_free_gb"] = round(shutil.disk_usage(workdir).free / 2 ** 30, 1)
    return m


def download(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if shutil.which("curl"):  # macOS curl uses the system keychain; some Python builds lack CA certificates
        if subprocess.run(["curl", "-fsSL", "--retry", "3", "-o", str(dest), url]).returncode == 0:
            return
    req = urllib.request.Request(url, headers={"User-Agent": "qed-stage-probe"})
    with urllib.request.urlopen(req, timeout=120) as r, open(dest, "wb") as f:
        shutil.copyfileobj(r, f)


def get_uv(workdir: Path) -> str:
    found = shutil.which("uv")
    if found:
        return found
    local = workdir / "bin" / "uv"
    if local.exists():
        return str(local)
    if sys.platform == "darwin":
        asset = "uv-aarch64-apple-darwin.tar.gz" if platform.machine() == "arm64" else "uv-x86_64-apple-darwin.tar.gz"
    else:
        asset = "uv-aarch64-unknown-linux-gnu.tar.gz" if platform.machine() == "aarch64" else "uv-x86_64-unknown-linux-gnu.tar.gz"
    print(f"[probe] downloading uv ({asset}) ...", flush=True)
    tgz = workdir / asset
    download(f"https://github.com/astral-sh/uv/releases/latest/download/{asset}", tgz)
    local.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(tgz) as t:
        member = next(x for x in t.getmembers() if x.name.endswith("/uv") or x.name == "uv")
        with t.extractfile(member) as src, open(local, "wb") as dst:
            shutil.copyfileobj(src, dst)
    local.chmod(0o755)
    tgz.unlink()
    return str(local)


def run_logged(cmd, log: Path, env=None) -> None:
    with open(log, "a") as f:
        f.write(f"\n$ {' '.join(map(str, cmd))}\n")
        f.flush()
        p = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, env=env)
    if p.returncode != 0:
        raise RuntimeError(f"command failed ({p.returncode}): {' '.join(map(str, cmd))}; see {log}")


def bootstrap(args) -> int:
    workdir = Path(args.workdir).expanduser().resolve()
    out = Path(args.out).expanduser().resolve()
    state_path = workdir / "state.json"
    workdir.mkdir(parents=True, exist_ok=True)
    state: dict = {"started": now(), "quick": args.quick, "errors": []}
    log = workdir / "install.log"
    print(f"[probe] QED Stage Mac probe {PROBE_VERSION}; working in {workdir}", flush=True)
    state["machine"] = machine_info(workdir)
    save_state(state_path, state)
    write_report(state, out)
    if sys.platform == "darwin" and state["machine"].get("arch") != "arm64":
        print("[probe] this Mac is not Apple Silicon (or Python runs under Rosetta); the Apple GPU path needs arm64.", flush=True)
    try:
        if args.venv:
            py = Path(args.venv) / "bin" / "python"
        else:
            uv = get_uv(workdir)
            # keep uv's cache and its Python inside the probe folder so deleting it removes everything
            uv_env = dict(os.environ, UV_CACHE_DIR=str(workdir / "uv-cache"),
                          UV_PYTHON_INSTALL_DIR=str(workdir / "python"))
            venv = workdir / "venv"
            py = venv / "bin" / "python"
            if not py.exists():
                print(f"[probe] creating Python {PYTHON} environment ...", flush=True)
                run_logged([uv, "venv", "--python", PYTHON, "--python-preference", "only-managed", str(venv)], log, env=uv_env)
            if not args.skip_install:
                print("[probe] installing PyTorch 2.4.0, Demucs and Seed-VC dependencies (about 1.5 GB) ...", flush=True)
                extra = [] if sys.platform == "darwin" else ["--extra-index-url", "https://download.pytorch.org/whl/cpu",
                                                             "--index-strategy", "unsafe-best-match"]
                run_logged([uv, "pip", "install", "--python", str(py), *extra, *REQUIREMENTS], log, env=uv_env)
        seed = Path(args.seedvc).expanduser() if args.seedvc else workdir / "seed-vc"
        if not (seed / "inference.py").exists():
            print(f"[probe] downloading Seed-VC at {SEEDVC_COMMIT[:7]} ...", flush=True)
            tgz = workdir / "seed-vc.tar.gz"
            download(f"https://codeload.github.com/Plachtaa/seed-vc/tar.gz/{SEEDVC_COMMIT}", tgz)
            with tarfile.open(tgz) as t:
                t.extractall(workdir)
            (workdir / f"seed-vc-{SEEDVC_COMMIT}").rename(seed)
            tgz.unlink()
        pkg = workdir / "stage"
        pkg.mkdir(exist_ok=True)
        (pkg / "__init__.py").write_text("")
        code = zlib.decompress(base64.b64decode(BACKENDS_B64))
        assert hashlib.sha256(code).hexdigest() == BACKENDS_SHA256, "embedded stage/backends.py is corrupted"
        (pkg / "backends.py").write_bytes(code)
    except Exception:
        add_error(state, "install")
        try:
            state["log_tail"] = log.read_text()[-3000:]
        except Exception:
            pass
        state["finished"] = now()
        save_state(state_path, state)
        write_report(state, out)
        print(f"[probe] install failed; report written to {out}", flush=True)
        return 1
    save_state(state_path, state)
    env = dict(os.environ, PYTORCH_ENABLE_MPS_FALLBACK="1", TOKENIZERS_PARALLELISM="false",
               HF_HUB_DISABLE_TELEMETRY="1", PYTHONUNBUFFERED="1")
    cmd = [str(py), os.path.abspath(__file__), "--bench", "--workdir", str(workdir), "--out", str(out),
           "--seedvc", str(seed)] + (["--quick"] if args.quick else []) + (["--cpu-compare"] if args.cpu_compare else []) + (["--models", args.models] if args.models else [])
    print("[probe] running the benchmark (progress below; a full run takes 20-45 min) ...", flush=True)
    rc = subprocess.call(cmd, env=env)
    state = load_state(state_path)
    if rc != 0 and not state.get("finished"):
        state.setdefault("errors", []).append({"step": "benchmark process", "trace": f"exited with code {rc} (crash or out of memory?)"})
        state["finished"] = now()
        save_state(state_path, state)
        write_report(state, out)
    print(f"\n[probe] verdict: {verdict(state)[0]}. Report: {out}", flush=True)
    return 0


# ===================================================================== benchmark (inside the venv)
def bench(args) -> int:
    import threading
    import warnings

    workdir = Path(args.workdir)
    out = Path(args.out)
    state_path = workdir / "state.json"
    state = load_state(state_path)
    models = Path(args.models).expanduser() if args.models else workdir / "models"
    models.mkdir(parents=True, exist_ok=True)
    os.environ["STAGE_MODELS_DIR"] = str(models)
    os.environ.setdefault("TORCH_HOME", str(models / "torch"))
    os.environ.setdefault("HF_HOME", str(models / "hf"))
    sys.path.insert(0, str(workdir))
    seed = Path(args.seedvc)
    outdir = workdir / "out"
    outdir.mkdir(exist_ok=True)
    R: dict = {"separate": [], "conversions": [], "outputs": []}
    state["results"] = R
    fallback: list = []

    def flush():
        R["mps_fallback_ops"] = sorted(set(fallback))
        save_state(state_path, state)
        write_report(state, out)

    _orig = warnings.showwarning

    def _show(message, category, filename, lineno, file=None, line=None):
        s = str(message)
        if "MPS" in s or "mps" in s:
            fallback.append(s.split("\n")[0][:200])
        return _orig(message, category, filename, lineno, file, line)

    warnings.showwarning = _show
    warnings.simplefilter("default", UserWarning)  # MPS CPU-fallback notices are UserWarnings
    for cat in (DeprecationWarning, ResourceWarning, FutureWarning):
        warnings.simplefilter("ignore", cat)

    import numpy as np
    import psutil
    import torch

    proc = psutil.Process()
    peak = {"rss": 0, "mps": 0}
    stop = threading.Event()

    def sampler():
        while not stop.is_set():
            try:
                rss = proc.memory_info().rss
                for c in proc.children(recursive=True):
                    rss += c.memory_info().rss
                peak["rss"] = max(peak["rss"], rss)
            except Exception:
                pass
            stop.wait(0.5)

    threading.Thread(target=sampler, daemon=True).start()

    def mps_mem():
        if R.get("device") == "mps":
            try:
                peak["mps"] = max(peak["mps"], torch.mps.driver_allocated_memory())
            except Exception:
                pass
        R["memory"] = {"peak_rss_gb": round(peak["rss"] / 2 ** 30, 2),
                       "peak_mps_driver_gb": round(peak["mps"] / 2 ** 30, 2) if peak["mps"] else None,
                       "swap_used_gb": round(psutil.swap_memory().used / 2 ** 30, 2)}

    def sync(dev):
        if dev == "mps":
            torch.mps.synchronize()

    mps_ok = bool(getattr(torch.backends, "mps", None) and torch.backends.mps.is_available())
    R["mps_available"] = mps_ok
    if not mps_ok:
        R["mps_reason"] = ("PyTorch built without MPS" if not torch.backends.mps.is_built()
                           else "MPS not available on this machine/OS")
    dev = "mps" if mps_ok else "cpu"
    R["device"] = dev
    import librosa
    import soundfile as sf
    state["software"] = {"Python": platform.python_version(), "PyTorch": torch.__version__, "NumPy": np.__version__,
                         "Seed-VC commit": SEEDVC_COMMIT[:7], "stage/backends.py sha256": BACKENDS_SHA256[:12],
                         "PYTORCH_ENABLE_MPS_FALLBACK": os.environ.get("PYTORCH_ENABLE_MPS_FALLBACK", "")}
    flush()

    # --- raw compute
    try:
        R["matmul"] = {}
        for d in (["mps", "cpu"] if mps_ok else ["cpu"]):
            a = torch.randn(2048, 2048, device=d)
            b = torch.randn(2048, 2048, device=d)
            for _ in range(3):
                a @ b
            sync(d)
            t = time.time()
            for _ in range(20):
                a @ b
            sync(d)
            R["matmul"][d] = round(20 * 2 * 2048 ** 3 / (time.time() - t) / 1e9, 0)
    except Exception:
        add_error(state, "matmul")
    flush()

    from stage.backends import SR, DemucsSeparator, SeedVCSinger

    def bed(n):
        t = np.arange(n) / SR
        beat = (t * 2) % 1.0
        kick = np.sin(2 * np.pi * 55 * t) * np.exp(-beat * 18)
        hat = np.random.default_rng(0).standard_normal(n) * np.exp(-((t * 4) % 1.0) * 60) * 0.25
        bass = 0.5 * np.sign(np.sin(2 * np.pi * 73.4 * t)) * 0.3
        chord = sum(np.sin(2 * np.pi * f * t) for f in (293.7, 370.0, 440.0)) * 0.12
        x = 0.6 * kick + hat + bass + chord
        return np.stack([x, x * 0.95], axis=1).astype(np.float32) * 0.4

    def load_vocal(name, seconds):
        v, _ = librosa.load(str(seed / "examples" / "source" / name), sr=SR, mono=True)
        v = v[: SR * seconds].astype(np.float32)
        return v * (0.5 / (np.max(np.abs(v)) + 1e-9))

    def sdr(truth, est):
        return round(float(10 * np.log10(np.sum(truth ** 2) / (np.sum((truth - est) ** 2) + 1e-12))), 2)

    vocal14 = load_vocal(SOURCE_14, 14)
    mix = bed(len(vocal14)) + vocal14[:, None]
    scale = 1 / max(1.0, float(np.max(np.abs(mix))) / 0.95)
    mix = mix * scale
    truth = vocal14 * scale
    R["sdr_baseline_db"] = sdr(truth, mix.mean(1))

    # --- stem separation
    sep_plan = [("htdemucs", dev)]
    if not args.quick:
        sep_plan += [("htdemucs_ft", dev)] + ([("htdemucs", "cpu")] if mps_ok else [])
    song_sep = None
    for model_name, d in sep_plan:
        row = {"model": model_name, "device": d, "clip_s": 14.0}
        R["separate"].append(row)
        try:
            print(f"[probe] Demucs {model_name} on {d} ...", flush=True)
            s = DemucsSeparator(model_name, d)
            t = time.time(); s.load(); row["load_s"] = round(time.time() - t, 1)
            t = time.time(); stems = s(mix); sync(d); row["first_s"] = round(time.time() - t, 1)
            t = time.time(); stems = s(mix); sync(d); row["warm_s"] = round(time.time() - t, 1)
            row["rtf"] = round(row["warm_s"] / 14.0, 3)
            row["sdr_db"] = sdr(truth, stems["vocals"].mean(1)[: len(truth)])
            if model_name == "htdemucs_ft" and d == dev:
                sf.write(str(outdir / "separated_vocals_htdemucs_ft.wav"), stems["vocals"], SR)
                R["outputs"].append(home_rel(outdir / "separated_vocals_htdemucs_ft.wav"))
                if not args.quick:
                    reps = int(np.ceil(SONG_SECONDS / 14))
                    song = np.tile(mix, (reps, 1))[: SR * SONG_SECONDS]
                    print(f"[probe] Demucs {model_name} on {d}, full {SONG_SECONDS // 60}.5-min song ...", flush=True)
                    t = time.time(); s(song); sync(d); song_sep = time.time() - t
                    row["song_s"] = round(song_sep, 1)
                    R["song_separate_minutes"] = round(song_sep / 60, 1)
                    R["song_separate_basis"] = f"measured, {model_name} (Stage default) on {d}"
            del s
            if d == "mps":
                torch.mps.empty_cache()
        except Exception:
            add_error(state, f"separate {model_name} on {d}")
        mps_mem()
        flush()
    R["separate_ok"] = any(r.get("sdr_db") is not None for r in R["separate"])
    if song_sep is None and R["separate_ok"]:
        best = [r for r in R["separate"] if r.get("rtf") is not None and r["device"] == dev]
        if best:
            R["song_separate_minutes"] = round(best[-1]["rtf"] * SONG_SECONDS / 60, 1)
            R["song_separate_basis"] = f"estimated from the 14 s clip, {best[-1]['model']} on {dev}"
    flush()

    # --- singing conversion
    def f0(x):
        f, v, _ = librosa.pyin(librosa.resample(x, orig_sr=SR, target_sr=16000), fmin=70, fmax=1000, sr=16000, frame_length=1024)
        return np.where(v, f, np.nan)

    def melody(src, out_wav):
        a, b = f0(src), f0(out_wav.astype(np.float32))
        n = min(len(a), len(b)); a, b = a[:n], b[:n]
        m = ~np.isnan(a) & ~np.isnan(b)
        if m.sum() <= 20:
            return float(m.mean()), None, None
        sa, sb = 12 * np.log2(a[m]), 12 * np.log2(b[m])
        return float(m.mean()), float(np.corrcoef(sa, sb)[0, 1]), float(np.median(sb - sa))

    ref, _ = librosa.load(str(seed / "examples" / "reference" / REFERENCE), sr=SR, mono=True)
    ref = ref.astype(np.float32)
    plan = [(SOURCE_14, 14, 10, "first (warm-up)"), (SOURCE_14, 14, 10, "warm")]
    if not args.quick:
        plan += [(SOURCE_14, 14, 30, "warm"), (SOURCE_28, 28, 30, "warm")]
    if os.environ.get("PROBE_SELFTEST") == "1":  # sandbox self-test: one short conversion
        plan = [(SOURCE_14, 14, 4, "warm")]
    conv_summary = {}

    def convert_runs(singer, d, runs):
        for name, secs, steps, label in runs:
            row = {"clip_s": float(secs), "device": d, "steps": steps, "run": label}
            R["conversions"].append(row)
            try:
                src = load_vocal(name, secs)
                print(f"[probe] Seed-VC on {d}: {secs} s clip, {steps} steps ({label}) ...", flush=True)
                t = time.time()
                y = singer(src, ref, semitones=0, steps=steps, auto_f0=True)
                sync(d)
                row["seconds"] = round(time.time() - t, 1)
                row["rtf"] = round(row["seconds"] / secs, 3)
                fn = outdir / f"sing_as_{d}_{secs}s_{steps}steps.wav"
                sf.write(str(fn), y, SR)
                if home_rel(fn) not in R["outputs"]:
                    R["outputs"].append(home_rel(fn))
                vo, corr, ks = melody(src, y)
                row["voiced_overlap"] = round(vo, 3)
                row["melody_corr"] = round(corr, 3) if corr is not None else None
                row["key_shift"] = round(ks, 1) if ks is not None else None
            except Exception:
                add_error(state, f"convert {secs}s {steps} steps on {d}")
            mps_mem()
            flush()

    try:
        print(f"[probe] loading Seed-VC on {dev} (first run downloads about 2 GB of weights) ...", flush=True)
        singer = SeedVCSinger(str(seed), str(models), fp16=False, device=dev)
        t = time.time(); singer.load(); R["svc_load_s"] = round(time.time() - t, 1)
        flush()
        convert_runs(singer, dev, plan)
    except Exception:
        add_error(state, f"load Seed-VC on {dev}")
    flush()

    done = [c for c in R["conversions"] if c.get("seconds") is not None and c["device"] == dev and c["run"] == "warm"]
    at30 = [c for c in done if c["steps"] == 30]
    basis = max(at30, key=lambda c: c["clip_s"]) if at30 else (done[-1] if done else None)
    if basis:
        rtf30 = basis["rtf"] * (30 / basis["steps"]) if basis["steps"] != 30 else basis["rtf"]
        # diffusion dominates; scaling from 10 to 30 steps by step count is a conservative (high) estimate
        conv_summary = {"song_estimate_minutes": round(rtf30 * SONG_SECONDS / 60, 1), "basis_clip_s": basis["clip_s"],
                        "basis_steps": basis["steps"],
                        "melody_corr": min(c["melody_corr"] for c in done if c.get("melody_corr") is not None)
                        if any(c.get("melody_corr") is not None for c in done) else None}
        R["convert"] = conv_summary
    flush()

    if args.cpu_compare and mps_ok:
        try:
            del singer
            torch.mps.empty_cache()
            cpu_singer = SeedVCSinger(str(seed), str(models), fp16=False, device="cpu")
            cpu_singer.load()
            convert_runs(cpu_singer, "cpu", [(SOURCE_14, 14, 10, "warm-ish")])
        except Exception:
            add_error(state, "convert on cpu (comparison)")

    stop.set()
    mps_mem()
    state["finished"] = now()
    flush()
    return 0


def main() -> int:
    here = Path(os.path.abspath(__file__)).parent
    ap = argparse.ArgumentParser(description="QED Stage Mac mini GPU probe")
    ap.add_argument("--quick", action="store_true", help="one Demucs model and one short conversion")
    ap.add_argument("--cpu-compare", action="store_true", help="also time one conversion on the CPU (adds several minutes)")
    ap.add_argument("--workdir", default=str(Path.home() / "qed-stage-probe"))
    ap.add_argument("--out", default=str(here / f"stage-mac-probe-{_dt.date.today().isoformat()}.md"))
    ap.add_argument("--bench", action="store_true", help=argparse.SUPPRESS)
    ap.add_argument("--venv", help=argparse.SUPPRESS)
    ap.add_argument("--skip-install", action="store_true", help=argparse.SUPPRESS)
    ap.add_argument("--seedvc", help=argparse.SUPPRESS)
    ap.add_argument("--models", help=argparse.SUPPRESS)
    args = ap.parse_args()
    if args.bench:
        return bench(args)
    return bootstrap(args)


if __name__ == "__main__":
    sys.exit(main())
