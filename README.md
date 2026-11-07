# QED scripts

Public, read-only scripts that anyone at QED can run from Terminal: no GitHub account, login or Helm access needed.
Every script is pinned by a release tag, so a command you ran keeps meaning the same thing.

| Script | What it does | Run it |
|---|---|---|
| `stage/stage_mac_probe.py` | Checks whether an Apple Silicon Mac can be Understudy Stage's interim GPU. Writes a Markdown report with a GO / MARGINAL / NO-GO verdict. | [docs/new-mac.md](docs/new-mac.md) |
| `stage/stage_mac_sing.py` | Re-sings a song in a singer's voice on that Mac ("Sing as"), keeping the melody and key. Needs the probe run once first. | [docs/stage-sing.md](docs/stage-sing.md) |

Quick start (macOS Terminal):

```sh
mkdir -p ~/qed-scripts && cd ~/qed-scripts
curl -fsSLO https://raw.githubusercontent.com/Nerdifitronix/qed-scripts/v0.1.1/stage/stage_mac_probe.py
python3 stage_mac_probe.py
```

## Rules for this repository

This repository is **public**: anyone on the internet can read it. See [SECURITY.md](SECURITY.md).

- No secrets, tokens, passwords or keys. Scripts ask for them at run time or read them from the user's own keychain.
- No internal hostnames, IP addresses, client data, people's names or email addresses.
- Scripts are stdlib-only Python 3.9+ or POSIX `sh`, install only into a folder under the user's home that they can
  delete, and never send results anywhere. They write a local file that the person chooses to share.
- Changes go through a pull request reviewed by a code owner. `python3 tools/check.py` runs in CI and blocks
  anything that breaks the rules above that it can detect.

## Releasing

Merge to `main`, then tag `vX.Y.Z` and update the commands in the docs to the new tag. Never move or delete a tag.

## Licence

GPL-3.0 (see [LICENSE](LICENSE)). `stage/stage_mac_sing.py` runs the same model code that the probe installs. `stage/stage_mac_probe.py` embeds Understudy's Stage model code, which is adapted
from [Seed-VC](https://github.com/Plachtaa/seed-vc) (GPL-3.0). The copy here comes from the Understudy repository
(`scripts/stage_mac_probe.py`), where a test keeps the embedded code identical to what Stage ships.
