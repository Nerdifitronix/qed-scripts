#!/usr/bin/env python3
"""QED Understudy Stage: "Sing as" on a Mac mini (interim, until the rented GPU is in place).

Takes a singer's recording and one or more songs, and re-sings each song's vocal in that singer's voice
on the Mac's Apple GPU. The song keeps its melody and key; only the voice changes.

    python3 stage_mac_sing.py SINGER_RECORDING SONG [SONG ...]

    SINGER_RECORDING  20-30 s of the singer singing, a cappella (WAV, AIFF, M4A or MP3)
    SONG              a demo of the song: a full mix or just the vocal (WAV, AIFF, M4A or MP3)

Run stage_mac_probe.py once on this Mac first: this script reuses what it installed in ~/qed-stage-probe.
For each song it writes a folder under ./stage-output (next to this script) with:
    sung-vocal.wav       the vocal re-sung in the singer's voice
    sung-mix.wav         that vocal over the song's instruments (skipped with --vocal-only)
    original-vocal.wav   the vocal it started from, for comparison
and a run report stage-sing-YYYY-MM-DD.md you can send back. Nothing is uploaded anywhere.

Options:
    --key octave     (default) move the song by whole octaves only, if the singer sits an octave away;
                     the song stays in its key
    --key keep       never move the pitch
    --semitones N    move the pitch by N semitones on top of that (changes the key; for transposed parts)
    --steps N        quality steps, default 30 (10 is about 3x faster for rough drafts)
    --vocal-only     the song file is already just the vocal: skip separation and the mix
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import re
import shutil
import subprocess
import sys
import time
import traceback
from pathlib import Path

SING_VERSION = "1.0"
SR = 44100
REF_SECONDS = 25  # Seed-VC uses at most 25 s of the singer's recording
AUDIO_NATIVE = {".wav", ".flac", ".aif", ".aiff", ".ogg"}


def slug(p: Path) -> str:
    return re.sub(r"[^A-Za-z0-9._ -]+", "", p.stem).strip()[:60] or "song"


def home_rel(p) -> str:
    s, h = str(p), str(Path.home())
    return "~" + s[len(h):] if s.startswith(h) else s


# ===================================================================== launcher (system python3)
def launch(args) -> int:
    work = Path(args.workdir).expanduser().resolve()
    py = Path(args.venv) / "bin" / "python" if args.venv else work / "venv" / "bin" / "python"
    seed = Path(args.seedvc).expanduser() if args.seedvc else work / "seed-vc"
    backends = work / "stage" / "backends.py"
    missing = [str(p) for p in (py, seed / "inference.py", backends) if not p.exists()]
    if missing:
        print("[sing] The Stage setup is not on this Mac yet. Run the probe once first:\n"
              "         python3 stage_mac_probe.py --quick\n"
              f"       (missing: {', '.join(missing)})", flush=True)
        return 2
    files = [Path(args.singer).expanduser()] + [Path(s).expanduser() for s in args.songs]
    for f in files:
        if not f.is_file():
            print(f"[sing] file not found: {f}", flush=True)
            return 2
    env = dict(os.environ, PYTORCH_ENABLE_MPS_FALLBACK="1", TOKENIZERS_PARALLELISM="false",
               HF_HUB_DISABLE_TELEMETRY="1", PYTHONUNBUFFERED="1")
    cmd = [str(py), os.path.abspath(__file__), "--run", "--workdir", str(work), "--seedvc", str(seed),
           "--out", str(Path(args.out).expanduser().resolve()), "--key", args.key, "--semitones", str(args.semitones),
           "--steps", str(args.steps), "--demucs", args.demucs] + (["--vocal-only"] if args.vocal_only else []) \
        + (["--models", args.models] if args.models else []) + [str(files[0].resolve())] + [str(f.resolve()) for f in files[1:]]
    rc = subprocess.call(cmd, env=env)
    out = Path(args.out).expanduser().resolve()
    if sys.platform == "darwin" and out.exists() and not os.environ.get("SING_NO_OPEN"):
        subprocess.call(["open", str(out)])
    return rc


# ===================================================================== worker (inside the probe venv)
def to_wav(src: Path, tmp: Path) -> Path:
    """Decode M4A/MP3/etc. with macOS's built-in afconvert (or ffmpeg elsewhere)."""
    if src.suffix.lower() in AUDIO_NATIVE:
        return src
    dst = tmp / (slug(src) + ".wav")
    if shutil.which("afconvert"):
        cmd = ["afconvert", "-f", "WAVE", "-d", "LEI16", str(src), str(dst)]
    elif shutil.which("ffmpeg"):
        cmd = ["ffmpeg", "-y", "-loglevel", "error", "-i", str(src), str(dst)]
    else:
        raise RuntimeError(f"cannot decode {src.name}; export it as WAV")
    subprocess.run(cmd, check=True)
    return dst


def octave_shift(src_f0, ref_f0) -> int:
    """Whole octaves (as semitones) that bring the song's median pitch nearest the singer's. Never a partial step."""
    import numpy as np
    a, b = src_f0[src_f0 > 1], ref_f0[ref_f0 > 1]
    if len(a) < 20 or len(b) < 20:
        return 0
    diff = 12 * np.log2(np.median(b) / np.median(a))
    return int(12 * round(diff / 12))


def run(args) -> int:
    import numpy as np
    import librosa
    import soundfile as sf

    work = Path(args.workdir)
    models = Path(args.models).expanduser() if args.models else work / "models"
    os.environ["STAGE_MODELS_DIR"] = str(models)
    os.environ.setdefault("TORCH_HOME", str(models / "torch"))
    os.environ.setdefault("HF_HOME", str(models / "hf"))
    sys.path.insert(0, str(work))
    import torch
    from stage.backends import DemucsSeparator, SeedVCSinger, default_device

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    tmp = out / ".tmp"
    tmp.mkdir(exist_ok=True)
    dev = os.environ.get("STAGE_DEVICE") or default_device()
    report = {"version": SING_VERSION, "started": _dt.datetime.now().isoformat(timespec="seconds"), "device": dev,
              "steps": args.steps, "key": args.key, "semitones": args.semitones, "songs": [], "errors": []}
    report_path = out / f"stage-sing-{_dt.date.today().isoformat()}.md"

    def sync():
        if dev == "mps":
            torch.mps.synchronize()
        elif dev == "cuda":
            torch.cuda.synchronize()

    def f0(x):
        x16 = librosa.resample(x, orig_sr=SR, target_sr=16000)
        f, v, _ = librosa.pyin(x16, fmin=65, fmax=1100, sr=16000, frame_length=2048, hop_length=640)
        return np.where(v, f, 0.0)

    singer_path = Path(args.files[0])
    print(f"[sing] Stage Sing-as {SING_VERSION} on {dev}; singer: {singer_path.name}", flush=True)
    ref, _ = librosa.load(str(to_wav(singer_path, tmp)), sr=SR, mono=True)
    ref, _ = librosa.effects.trim(ref, top_db=40)
    report["singer"] = {"file": singer_path.name, "seconds": round(len(ref) / SR, 1)}
    if len(ref) < 8 * SR:
        print(f"[sing] warning: the singer's recording is only {len(ref) / SR:.0f} s; 20-30 s gives a closer voice.", flush=True)
    ref = ref[: REF_SECONDS * SR].astype(np.float32)
    ref_f0 = f0(ref)
    if (ref_f0 > 1).sum() < 20:
        print("[sing] no sung pitch found in the singer's recording; it needs singing, not speech or silence.", flush=True)
        return 2
    report["singer"]["median_note_hz"] = round(float(np.median(ref_f0[ref_f0 > 1])), 1)

    sep = None if args.vocal_only else DemucsSeparator(args.demucs, dev)
    singer = SeedVCSinger(args.seedvc, str(models), fp16=False, device=dev)
    print("[sing] loading models ...", flush=True)
    singer.load()
    if sep:
        sep.load()

    for song_path in map(Path, args.files[1:]):
        row = {"file": song_path.name}
        report["songs"].append(row)
        folder = out / f"{slug(song_path)} - as {slug(singer_path)}"
        folder.mkdir(parents=True, exist_ok=True)
        try:
            mix, _ = librosa.load(str(to_wav(song_path, tmp)), sr=SR, mono=False)
            mix = np.atleast_2d(mix)
            if mix.shape[0] == 1:
                mix = np.vstack([mix, mix])
            mix = np.ascontiguousarray(mix.T, dtype=np.float32)  # (n, 2)
            row["seconds"] = round(len(mix) / SR, 1)
            inst = None
            if sep:
                print(f"[sing] {song_path.name}: separating the vocal from the instruments ...", flush=True)
                t = time.time()
                stems = sep(mix)
                sync()
                row["separate_s"] = round(time.time() - t, 1)
                vocal_st = stems["vocals"]
                inst = sum(v for k, v in stems.items() if k != "vocals")
            else:
                vocal_st = mix
            vocal = vocal_st.mean(axis=1).astype(np.float32)
            sf.write(str(folder / "original-vocal.wav"), vocal, SR)
            src_f0 = f0(vocal)
            if (src_f0 > 1).sum() < 20:
                raise ValueError("no sung vocal found in this song")
            shift = (octave_shift(src_f0, ref_f0) if args.key == "octave" else 0) + args.semitones
            row["pitch_shift_semitones"] = shift
            print(f"[sing] {song_path.name}: singing it as {singer_path.stem} ({args.steps} steps, "
                  f"pitch {shift:+d} semitones; a {row['seconds'] / 60:.1f}-min song takes roughly "
                  f"{row['seconds'] * 4.7 * args.steps / 30 / 60:.0f} min on a Mac mini) ...", flush=True)
            t = time.time()
            y = singer(vocal, ref, semitones=shift, steps=args.steps, auto_f0=False)
            sync()
            row["convert_s"] = round(time.time() - t, 1)
            n = min(len(y), len(vocal))
            y = y[:n]
            rms_v, rms_y = float(np.sqrt(np.mean(vocal[:n] ** 2))), float(np.sqrt(np.mean(y ** 2)))
            if rms_y > 1e-6:
                y = y * (rms_v / rms_y)  # same loudness as the original vocal
            peak = float(np.abs(y).max())
            if peak > 0.98:
                y = y * (0.98 / peak)
            sf.write(str(folder / "sung-vocal.wav"), y.astype(np.float32), SR)
            outs = ["sung-vocal.wav", "original-vocal.wav"]
            if inst is not None:
                m = inst[:n] + y[:, None]
                peak = float(np.abs(m).max())
                if peak > 0.98:
                    m = m * (0.98 / peak)
                sf.write(str(folder / "sung-mix.wav"), m.astype(np.float32), SR)
                outs.insert(1, "sung-mix.wav")
            row["folder"] = home_rel(folder)
            row["outputs"] = outs
            print(f"[sing] done in {row['convert_s'] / 60:.1f} min -> {folder}", flush=True)
        except Exception:
            row["error"] = traceback.format_exc(limit=6)
            report["errors"].append(song_path.name)
            print(f"[sing] {song_path.name} failed:\n{row['error']}", flush=True)
        if dev == "mps":
            torch.mps.empty_cache()
        write_report(report, report_path)

    report["finished"] = _dt.datetime.now().isoformat(timespec="seconds")
    write_report(report, report_path)
    shutil.rmtree(tmp, ignore_errors=True)
    print(f"\n[sing] finished. Results in {out}\n[sing] report: {report_path}", flush=True)
    return 1 if report["errors"] else 0


def write_report(r: dict, path: Path) -> None:
    L = [f"# Stage Sing-as run, {r['started'][:10]}", "",
         f"- Script {r['version']}; device {r['device']}; {r['steps']} steps; key mode {r['key']}; extra semitones {r['semitones']:+d}",
         f"- Singer recording: {r.get('singer', {}).get('file')} ({r.get('singer', {}).get('seconds')} s used up to {REF_SECONDS} s; "
         f"median note {r.get('singer', {}).get('median_note_hz')} Hz)", "",
         "| Song | Length | Separation | Sing as | Pitch shift | Result |", "|---|---|---|---|---|---|"]
    for s in r["songs"]:
        res = "failed (see below)" if s.get("error") else (s.get("folder") or "running")
        L.append(f"| {s['file']} | {s.get('seconds', '')} s | {s.get('separate_s', '-')} s | "
                 f"{round(s['convert_s'] / 60, 1) if s.get('convert_s') else '-'} min | "
                 f"{s.get('pitch_shift_semitones', '')} | {res} |")
    for s in r["songs"]:
        if s.get("error"):
            L += ["", f"## Error: {s['file']}", "```", s["error"].strip(), "```"]
    L += ["", "```json", json.dumps(r, indent=1), "```", ""]
    path.write_text("\n".join(L))


def main() -> int:
    here = Path(os.path.abspath(__file__)).parent
    ap = argparse.ArgumentParser(description="QED Stage: re-sing a song in a singer's voice on this Mac")
    ap.add_argument("singer", nargs="?", help="20-30 s of the singer singing (WAV, AIFF, M4A, MP3)")
    ap.add_argument("songs", nargs="*", help="song demo(s): full mix, or the vocal with --vocal-only")
    ap.add_argument("--key", choices=("octave", "keep"), default="octave")
    ap.add_argument("--semitones", type=int, default=0)
    ap.add_argument("--steps", type=int, default=30)
    ap.add_argument("--vocal-only", action="store_true")
    ap.add_argument("--out", default=str(here / "stage-output"))
    ap.add_argument("--workdir", default=str(Path.home() / "qed-stage-probe"))
    ap.add_argument("--demucs", default="htdemucs_ft", help=argparse.SUPPRESS)
    ap.add_argument("--run", action="store_true", help=argparse.SUPPRESS)
    ap.add_argument("--venv", help=argparse.SUPPRESS)
    ap.add_argument("--seedvc", help=argparse.SUPPRESS)
    ap.add_argument("--models", help=argparse.SUPPRESS)
    ap.add_argument("files", nargs="*", help=argparse.SUPPRESS)
    args, rest = ap.parse_known_args()
    if args.run:
        args.files = [args.singer] + args.songs
        return run(args)
    if not args.singer or not args.songs:
        ap.print_help()
        return 2
    return launch(args)


if __name__ == "__main__":
    sys.exit(main())
