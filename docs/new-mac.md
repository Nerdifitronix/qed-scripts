# Using QED scripts on a new Mac

This guide runs the Stage GPU probe, which checks whether a Mac mini can stand in as Understudy Stage's GPU until
the rented GPU is in place. Other QED scripts follow the same pattern. You need about 45 minutes, mostly waiting.

## Before you start

- **An Apple Silicon Mac** (M1 or later). Check in Terminal: `uname -m` must print `arm64`. An Intel Mac (`x86_64`)
  will run, but on the CPU only, and the verdict will be NO-GO.
- **About 10 GB of free disk** and an internet connection. The first run downloads about 3.5 GB.
- **Plugged in to power**, with Low Power Mode off (System Settings, Battery or Energy), and heavy apps closed.
- A macOS user account. You do not need an administrator password, a GitHub account or Homebrew.

## 1. Open Terminal

Press Cmd-Space, type `Terminal` and press Return.

## 2. Make sure Python 3 is there

```sh
python3 --version
```

On a brand-new Mac this may open a window asking to install the "command line developer tools". Click **Install**,
wait for it to finish (a few minutes), then run the command again. Any version from 3.9 up is fine.

## 3. Download the script

```sh
mkdir -p ~/qed-scripts && cd ~/qed-scripts
curl -fsSLO https://raw.githubusercontent.com/Nerdifitronix/qed-scripts/v0.1.1/stage/stage_mac_probe.py
```

`v0.1.1` pins the exact reviewed version. Optional: compare the file with the checksum on the
[release page](https://github.com/Nerdifitronix/qed-scripts/releases/tag/v0.1.1):

```sh
shasum -a 256 stage_mac_probe.py
```

## 4. Run it

```sh
python3 stage_mac_probe.py
```

It prints progress as it goes: creating its environment, installing PyTorch, downloading models, then timing stem
separation and singing conversion. Leave the Mac awake until it prints `verdict: ...`. To stop the Mac sleeping
while it runs, use `caffeinate -i python3 stage_mac_probe.py` instead.

`python3 stage_mac_probe.py --quick` gives a shorter run with a rougher estimate.

## 5. Send the report

The report is in the same folder: `~/qed-scripts/stage-mac-probe-YYYY-MM-DD.md`. Open it in Finder with
`open ~/qed-scripts`, then send that file to the person who asked you to run it.

It contains the Mac's model, chip, memory, macOS version, timings and any errors. It does not contain your name,
the Mac's name or serial number, network addresses or files from your Mac.

The probe's test clips are in `~/qed-stage-probe/out/`. They copy a short speaking sample at its pitch, so they
are a speed check, not a quality check. Use [stage-sing.md](stage-sing.md) to judge quality.

## Next: try a real singer

Once the probe has run, [stage-sing.md](stage-sing.md) re-sings a song in a real singer's voice on this Mac.

## Running it again

Run step 4 again. It reuses the downloads and overwrites the report.

## Removing everything

```sh
rm -rf ~/qed-stage-probe ~/qed-scripts
```

Nothing else was installed: no system packages, no login items, no background services.

## If something goes wrong

| What you see | What to do |
|---|---|
| `command not found: python3` | Do step 2 and install the command line developer tools. |
| `curl: (6) Could not resolve host` | No internet, or a network filter. Try another network. |
| `install failed` | The report has the last lines of the install log. Send it as it is. |
| The run stops partway, or the Mac slows right down | It probably ran out of memory. Send the report anyway, since it is written after every step. |
| Verdict `INCOMPLETE` | Send the report. The Errors section says what stopped it. |
