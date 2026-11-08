# QED Mac Health

A read-only health check for any Mac (Intel or Apple silicon, macOS 11 or newer). It uses only tools built
into macOS, needs no password and changes nothing. It never sends anything: it writes a report to
`~/QED-Mac-Health/` and opens it.

## Run it

Open Terminal and paste:

```sh
mkdir -p ~/qed-scripts && cd ~/qed-scripts
curl -fsSLO https://raw.githubusercontent.com/Nerdifitronix/qed-scripts/v0.2.0/mac/qed-mac-health.sh
bash qed-mac-health.sh
```

Takes about a minute (`--quick` skips the slow checks). `bash qed-mac-health.sh --help` lists the options.

## What you get

- An HTML report with a score out of 100 and a plain-language fix for each warning: updates, security
  (FileVault, firewall, Gatekeeper), disk space, memory, battery, backups, network, crashes, startup items.
- Hardware: logic board, Thunderbolt/USB ports and what is plugged in, displays, storage, battery, charger,
  Wi-Fi, Bluetooth, cameras and audio.
- `.txt` and `.json` copies. If the QED help desk asks for it, send them the `.json` yourself.

## What it reads

Model, serial number, macOS version, user name, network addresses, installed-app and remote-access tool names,
and the checks above. Never files, documents, messages, passwords or browsing history. Your home folder is
shown as `~`.

Source: built from the QED Device Health collector (`collectors/mac/build.sh`), which removes all upload code
from this edition.
