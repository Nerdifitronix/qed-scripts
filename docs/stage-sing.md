# Stage "Sing as" on the Mac mini

This re-sings a song in a real singer's voice on the Mac mini, so you can judge the quality before the rented GPU
is in place. The song keeps its melody and key; only the voice changes.

You need two recordings and about 20 minutes per song, mostly waiting.

## 1. Record the singer (the voice to copy)

One file, **20-30 seconds of the singer singing on their own**:

- **What to sing:** anything comfortable in their normal range. Ideally a verse of a song from the show they would
  actually sing. Mix low notes and high notes, with some held notes. Sing it the way they would perform it.
- **No music behind it:** no backing track, piano or click in the recording. Wear headphones if they need a guide.
- **No effects:** no reverb, Auto-Tune or Garage Band presets. A quiet room with soft furnishings, not a bathroom.
- **One voice, no talking:** don't count in or speak before or after. Trim the silence if you can.
- **Equipment:** a USB or studio microphone is best. An iPhone Voice Memo held about 30 cm away is fine for this test.

Format: **WAV or AIFF, 44.1 or 48 kHz, 16- or 24-bit**. An iPhone `.m4a` voice memo or an `.mp3` also works.
Name it after the singer, for example `maya.wav`. The output folders are named from it.

The singer must agree to their voice being used for this, in writing. An email is enough for the test.

## 2. Pick the song (what they will "sing")

One file per song: **a demo of a song from the show**, any length (a 3.5-minute song takes about 16 minutes).

- A full mix (vocal plus instruments) is fine. The script separates the vocal, re-sings it and puts the music back.
- If you have just the vocal (an a cappella stem), even better. Add `--vocal-only` in step 4.
- One lead singer at a time works best. Harmonies and choruses come out muddy.

Best test: also have the singer record that same song themselves. Then you can compare the real thing with Stage's
version side by side.

## 3. Get the script

This Mac already has the Stage setup if it ran the probe. If it didn't, run the probe once first (see
[new-mac.md](new-mac.md)).

```sh
cd ~/qed-scripts
curl -fsSLO https://raw.githubusercontent.com/Nerdifitronix/qed-scripts/v0.1.1/stage/stage_mac_sing.py
```

## 4. Run it

Put the files in `~/qed-scripts`, or drag them from Finder onto the Terminal window to type their paths.

```sh
caffeinate -i python3 stage_mac_sing.py maya.wav "Act 1 - Opening.wav"
```

The singer's recording always comes first, then one or more songs. Useful options:

| Option | What it does |
|---|---|
| `--vocal-only` | The song file is just the vocal: skip separation and the mix. |
| `--steps 10` | About 3x faster, rougher. Good for a quick listen. Default is 30. |
| `--key keep` | Never move the pitch. By default it moves by a whole octave only if the singer sits an octave away (for example a man singing a part written for a woman). Either way the song stays in its key. |
| `--semitones -2` | Transpose by that many semitones (this changes the key), for parts sung in a different key. |

## 5. Listen, then send the report

When it finishes, Finder opens `~/qed-scripts/stage-output/`. There is one folder per song:

- `sung-mix.wav`: the song with the new vocal. Start here.
- `sung-vocal.wav`: the new vocal on its own. Flaws are easiest to hear here.
- `original-vocal.wav`: the vocal it started from.

Send back `stage-sing-YYYY-MM-DD.md` from the same folder, along with your notes on how it sounds. Send the audio too
if you want it reviewed. The report has timings and settings only: no audio, names or Mac details.
