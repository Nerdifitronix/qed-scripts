#!/bin/bash
# shellcheck disable=SC2034,SC2010,SC2012
#
#  QED Mac Health Snapshot (public edition)  v3.1
#  ---------------------------------------------------------------------------
#  Just run:   bash qed-mac-health.sh
#
#  Full read-only diagnostics + health report for any Mac (Intel or Apple
#  silicon, macOS 11 Big Sur or newer). Built-in macOS tools only. Changes
#  nothing. No sudo, no installs, no flags needed. When it finishes it opens
#  an HTML report and also saves TXT + JSON copies in ~/QED-Mac-Health/.
#
#  Optional flags (never required):
#    --quick      skip the slow checks (updates, speed test, app scan, logs)
#    --no-open    don't open the report at the end
#    --out DIR    save reports somewhere else
#    --no-color   plain terminal output
#    QED-XXXX     help-desk session code (recorded in the report only)
#    --raw-hardware  also save the raw hardware listing (for QED support)
#
#  This edition never sends anything. The .json file is in the shared
#  qed.device-health/v1 format and can be handed in to the help desk.
#
#  Exit code: 0 healthy, 1 warnings, 2 failures.
#  ---------------------------------------------------------------------------

# Re-launch under real bash if started with sh/zsh or bash in POSIX mode.
if [ -z "${BASH_VERSION:-}" ]; then exec /bin/bash "$0" "$@"; fi
case ":${SHELLOPTS:-}:" in *:posix:*) exec /bin/bash "$0" "$@" ;; esac

VERSION="3.1.0"

# ---- QED policy thresholds (edit here if needed) ---------------------------
MIN_MACOS_MAJOR=14          # macOS older than this = WARN
DISK_FREE_WARN_PCT=20       # startup disk free % below this = WARN
DISK_FREE_FAIL_PCT=10       # startup disk free % below this = FAIL
DISK_FREE_FAIL_GB=10        # ...or less than this many GB free = FAIL
BATTERY_WARN_PCT=80         # battery max capacity below this = WARN
UPTIME_WARN_DAYS=30         # longer uptime than this = WARN
BACKUP_WARN_DAYS=7          # last Time Machine backup older than this = WARN
WIFI_RSSI_WARN=-75          # Wi-Fi signal weaker than this (dBm) = WARN
CLOCK_SKEW_WARN_S=5         # clock offset (seconds) above this = WARN
PING_LOSS_WARN_PCT=5        # packet loss above this % = WARN
PING_RTT_WARN_MS=150        # internet latency above this (ms) = WARN
SPEED_DL_WARN_MBPS=25       # download speed below this (Mbps) = WARN
SCREENLOCK_MAX_S=300        # screen lock delay above this (seconds) = WARN
# ---------------------------------------------------------------------------

QUICK=0; OPEN=1; COLOR=1; OUTDIR=""; CODE=""; YES=0; RAWHW=0; SERVER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) QUICK=1 ;;
    --no-open) OPEN=0 ;;
    --no-color) COLOR=0 ;;
    --out) shift; OUTDIR="${1:-}" ;;
    --code) shift; CODE="${1:-}" ;;
    --server) shift; SERVER="${1:-}" ;;
    --yes) YES=1 ;;
    --raw-hardware) RAWHW=1 ;;
    QED-*|qed-*) CODE="$1" ;;
    --version) echo "QED Mac Health Snapshot $VERSION"; exit 0 ;;
    -h|--help) sed -n '3,/^$/p' "$0" | sed 's/^#  \{0,1\}//; s/^#$//'; exit 0 ;;
    *) echo "Ignoring unknown option: $1" >&2 ;;
  esac
  shift
done

CODE=$(printf '%s' "$CODE" | tr '[:lower:]' '[:upper:]')
if [ -n "$CODE" ] && ! printf '%s' "$CODE" | grep -Eq '^QED-[A-HJ-NP-Z2-9]{4}$'; then
  echo "Session code should look like QED-7K3P (got: $CODE)." >&2; exit 64
fi

if [ "$(/usr/bin/uname -s 2>/dev/null)" != "Darwin" ]; then
  echo "This script only runs on macOS." >&2; exit 64
fi

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/libexec:/opt/homebrew/bin:/usr/local/bin:${PATH}"
export LC_ALL=C LANG=C HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1

[ -t 1 ] || COLOR=0
if [ "$COLOR" -eq 1 ]; then
  RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLU=$'\033[36m'; BLD=$'\033[1m'; DIM=$'\033[2m'; RST=$'\033[0m'
else
  RED=""; GRN=""; YEL=""; BLU=""; BLD=""; DIM=""; RST=""
fi

START_TS=$(date +%s)
iso_now() { date '+%Y-%m-%dT%H:%M:%S%z' | sed 's/\([+-][0-9][0-9]\)\([0-9][0-9]\)$/\1:\2/'; }
START_ISO=$(iso_now)

# ============================================================================
#  Helpers
# ============================================================================
have() { command -v "$1" >/dev/null 2>&1; }
HAVE_PERL=0; have perl && HAVE_PERL=1

# tmo SECONDS cmd args...  -> run with a hard timeout (macOS has no timeout(1))
tmo() {
  local s="$1"; shift
  if [ "$HAVE_PERL" -eq 1 ]; then
    perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$s" "$@" </dev/null
  else
    "$@" </dev/null & local p=$!
    ( sleep "$s"; kill -9 "$p" ) >/dev/null 2>&1 & local w=$!
    wait "$p"; local r=$?
    kill "$w" >/dev/null 2>&1
    return $r
  fi
}

field() { sed -n "s|^[[:space:]]*$1:[[:space:]]*||p" | head -n 1; }      # "Key: value" from stdin
hb() { awk -v b="${1:-0}" 'BEGIN{split("B KB MB GB TB PB",u," ");i=1;while(b>=1024&&i<6){b/=1024;i++};printf "%.1f %s",b,u[i]}'; }
fgt() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{exit !(a+0>b+0)}'; }
flt() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{exit !(a+0<b+0)}'; }
isnum() { case "${1:-x}" in ''|-|*[!0-9-]*) return 1 ;; *) return 0 ;; esac; }
trim() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
h() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }
hs() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }
j() { printf '%s' "$1" | awk 'BEGIN{ORS=""} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\t/,"\\t"); gsub(/\r/,""); gsub(/[\001-\037]/,""); if(NR>1) printf "\\n"; print}'; }
appver() { [ -d "$1" ] && /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null; }

# ---- hardware inventory parser (JavaScript for Automation, built into macOS) ----------
# Generated from collectors/mac/lib/inventory.js by collectors/mac/build.sh - edit that file, not this block.
# >>> inventory.js
inventory_js() { cat <<'QED_INVENTORY_JS'
// QED Mac Health - hardware inventory.
// Runs under macOS JavaScript for Automation (osascript -l JavaScript, built into every Mac)
// and under Node for tests. Input: `system_profiler -json <types>` file and an ioreg text file.
// Output: JSON array of components for qed.device-health/v1 "inventory".
'use strict';

const S = (v) => (v === undefined || v === null ? '' : String(v)).trim();
const PFX = /^(spdisplays|sppci|spusb|spnvme|sppower|spairport|spbluetooth|spcamera|coreaudio|spthunderbolt|spcardreader|spethernet|spaudio|attrib|status|vendor|activation_lock|receptacle|device_type)_/i;
const human = (v) => { let s = S(v); for (let i = 0; i < 4 && PFX.test(s); i++) s = s.replace(PFX, ''); return s.replace(/_/g, ' '); };
const yesno = (v) => { const s = S(v); if (/(_yes|^yes)$/i.test(s) || s === 'TRUE') return 'yes'; if (/(_no|^no)$/i.test(s) || s === 'FALSE') return 'no'; return human(s); };

function pick(o, keys) {
  const out = {};
  for (const [k, label] of keys) { const v = o[k]; if (v !== undefined && v !== null && typeof v !== 'object' && S(v) !== '') out[label] = human(v); }
  return out;
}
function comp(kind, name, o) {
  const c = { kind, name: S(name).slice(0, 200) || kind };
  for (const k of ['vendor', 'model', 'serial', 'firmware', 'connection', 'status']) if (o[k]) c[k] = S(o[k]).slice(0, 200);
  const props = {};
  for (const [k, v] of Object.entries(o.props || {})) if (S(v)) props[k.slice(0, 40)] = S(v).slice(0, 200);
  if (Object.keys(props).length) c.props = props;
  return c;
}
function walk(items, fn, depth, parent) {
  for (const it of items || []) { fn(it, depth || 0, parent); if (Array.isArray(it._items)) walk(it._items, fn, (depth || 0) + 1, it); }
}
function ioregData(txt, key) {
  const m = new RegExp('"' + key + '" = <([^>]*)>').exec(txt || '') || new RegExp('"' + key + '" = "([^"]*)"').exec(txt || '');
  if (!m) return '';
  let v = m[1];
  if (/^".*"$/.test(v)) return v.slice(1, -1).replace(/\0/g, '');
  if (/^[0-9a-f]+$/i.test(v) && v.length % 2 === 0) { let s = ''; for (let i = 0; i < v.length; i += 2) { const c = parseInt(v.substr(i, 2), 16); if (c) s += String.fromCharCode(c); } return /^[\x20-\x7e]+$/.test(s) ? s : ''; }
  return v.replace(/"/g, '');
}

function inventory(sp, ioreg, extra) {
  const out = [];
  const add = (c) => { if (out.length < 300) out.push(c); };
  extra = extra || {};

  // Logic board / system
  const hw = (sp.SPHardwareDataType || [])[0] || {};
  add(comp('logic_board', hw.machine_name ? hw.machine_name + ' logic board' : 'Logic board', {
    vendor: 'Apple', model: extra.target || ioregData(ioreg, 'target-type') || ioregData(ioreg, 'board-id'),
    serial: ioregData(ioreg, 'mlb-serial-number') || ioregData(ioreg, 'board-serial-number'),
    firmware: hw.boot_rom_version || hw.os_loader_version,
    props: Object.assign(pick(hw, [['machine_model', 'model_id'], ['model_number', 'model_number'], ['chip_type', 'chip'], ['cpu_type', 'cpu'], ['physical_memory', 'memory'], ['SMC_version_system', 'smc'], ['os_loader_version', 'os_loader'],
      ['activation_lock_status', 'activation_lock']]), { cores: S(hw.number_processors).replace(/^proc (\d+):(\d+):(\d+).*/, '$1 ($2 performance + $3 efficiency)'), board_id: ioregData(ioreg, 'board-id'), region: ioregData(ioreg, 'region-info') }),
  }));

  // Thunderbolt / USB4 ports and what is plugged into them
  walk(sp.SPThunderboltDataType, (it, d, parent) => {
    if (d === 0) {
      const props = pick(it, [['switch_version_key', 'switch_version'], ['route_string_key', 'route']]);
      let status = '', speed = '', recept = '';
      for (const [k, v] of Object.entries(it)) if (/^receptacle_\d+_tag$/.test(k) && v && typeof v === 'object') {
        recept = S(v.receptacle_id_key); status = human(v.receptacle_status_key).replace(/^receptacle /, '');
        speed = human(v.current_speed_key || ''); if (/^0x/i.test(speed)) speed = '';
      }
      add(comp('port', 'Thunderbolt/USB4 port' + (recept ? ' ' + recept : ''), {
        connection: 'thunderbolt', status: status || human(it.device_status_key || ''),
        props: Object.assign(props, { max_speed: human(it.mode_key || it.speed_key || ''), speed, bus: S(it._name) }),
      }));
    } else {
      add(comp('device', it._name || it.device_name_key, {
        vendor: it.vendor_name_key, model: it.device_name_key, firmware: it.fw_version_key || it.device_revision_key,
        connection: 'thunderbolt', status: 'connected',
        props: pick(it, [['mode_key', 'mode'], ['receptacle_upstream_ambiguous_tag', 'upstream'], ['device_id_key', 'device_id'], ['vendor_id_key', 'vendor_id']]),
      }));
    }
  });

  // USB (macOS 15+: SPUSBHostDataType, older: SPUSBDataType)
  const usbSkip = /^(USB\d*(\.\d+)? ?(Bus|Hi-Speed Bus|Super ?Speed Bus)?|USB\d+Bus|.*Host Controller.*|.*Root Hub.*)$/i;
  for (const t of ['SPUSBHostDataType', 'SPUSBDataType']) walk(sp[t], (it, d) => {
    if (d === 0 && usbSkip.test(S(it._name))) return;
    if (usbSkip.test(S(it._name))) return;
    add(comp('device', it._name, {
      vendor: it.manufacturer || it.vendor_id || it.USBDeviceKeyVendorName, model: it._name,
      serial: it.serial_num || it.USBDeviceKeySerialNumber, firmware: it.bcd_device || it.USBDeviceKeyBcdDevice,
      connection: 'usb', status: 'connected',
      props: pick(it, [['product_id', 'product_id'], ['vendor_id', 'vendor_id'], ['device_speed', 'speed'], ['USBDeviceKeyLinkSpeed', 'speed'],
        ['location_id', 'location'], ['USBKeyLocationID', 'location'], ['bus_power', 'power_ma'], ['bus_power_used', 'power_used_ma'], ['Built-in_Device', 'built_in']]),
    }));
  });

  // GPU and displays
  for (const g of sp.SPDisplaysDataType || []) {
    add(comp('gpu', g.sppci_model || g._name, { vendor: S(g.spdisplays_vendor).replace(/^sppci_vendor_/, ''), connection: human(g.sppci_bus),
      props: pick(g, [['sppci_cores', 'cores'], ['spdisplays_mtlgpufamilysupport', 'metal'], ['spdisplays_vram', 'vram'], ['sppci_device_type', 'type']]) }));
    for (const dsp of g.spdisplays_ndrvs || []) {
      const internal = /internal/i.test(S(dsp.spdisplays_connection_type)) || /built-?in/i.test(S(dsp.spdisplays_display_type));
      add(comp('display', dsp._name, {
        vendor: dsp._spdisplays_display_vendor_id || dsp.spdisplays_vendor, serial: dsp._spdisplays_display_serial_number || dsp.spdisplays_display_serial_number,
        connection: internal ? 'internal' : human(dsp.spdisplays_connection_type || 'external'), status: yesno(dsp.spdisplays_online) === 'no' ? 'offline' : 'online',
        props: pick(dsp, [['_spdisplays_resolution', 'resolution'], ['_spdisplays_pixels', 'pixels'], ['spdisplays_resolution', 'resolution'],
          ['spdisplays_display_type', 'type'], ['spdisplays_main', 'main'], ['spdisplays_mirror', 'mirror'], ['_spdisplays_display_year', 'year'],
          ['_spdisplays_displayport_device', 'port']]),
      }));
    }
  }

  // Internal storage
  for (const t of ['SPNVMeDataType', 'SPSerialATADataType']) walk(sp[t], (it, d) => {
    if (d === 0) return;
    add(comp('storage', it._name || it.device_model, {
      model: it.device_model, serial: it.device_serial, firmware: it.device_revision, connection: t === 'SPNVMeDataType' ? 'nvme' : 'sata',
      status: human(it.smart_status),
      props: pick(it, [['size', 'size'], ['spnvme_trim_support', 'trim'], ['spsata_trim_support', 'trim'], ['detachable_drive', 'removable'], ['spnvme_linkwidth', 'link_width'], ['spnvme_linkspeed', 'link_speed']]),
    }));
  });

  // Battery and charger
  for (const p of sp.SPPowerDataType || []) {
    const mi = p.sppower_battery_model_info, hi = p.sppower_battery_health_info, ac = p.sppower_ac_charger_information || (p._name === 'sppower_ac_charger_information' ? p : null);
    if (mi || hi) add(comp('battery', S((mi || {}).sppower_battery_device_name) || 'Battery', {
      serial: (mi || {}).sppower_battery_serial_number, firmware: (mi || {}).sppower_battery_firmware_version, status: human((hi || {}).sppower_battery_health),
      props: Object.assign(pick(mi || {}, [['sppower_battery_hardware_revision', 'hardware_rev'], ['sppower_battery_cell_revision', 'cell_rev']]),
        pick(hi || {}, [['sppower_battery_cycle_count', 'cycles'], ['sppower_battery_health_maximum_capacity', 'max_capacity']])),
    }));
    if (ac) add(comp('charger', S(ac.sppower_ac_charger_name) || 'Power adapter', {
      vendor: ac.sppower_ac_charger_manufacturer, serial: ac.sppower_ac_charger_serial_number, firmware: ac.sppower_ac_charger_firmware_version,
      status: yesno(ac.sppower_battery_charger_connected) === 'no' ? 'disconnected' : 'connected',
      props: pick(ac, [['sppower_ac_charger_watts', 'watts'], ['sppower_ac_charger_family', 'family'], ['sppower_ac_charger_hardware_version', 'hardware_rev'], ['sppower_battery_is_charging', 'charging']]),
    }));
  }

  // Wi-Fi and Bluetooth controllers (no network names, no MAC addresses)
  for (const a of sp.SPAirPortDataType || []) for (const ifc of a.spairport_airport_interfaces || []) {
    if (!ifc.spairport_wireless_card_type) continue;
    add(comp('wifi', 'Wi-Fi ' + S(ifc._name), { model: ifc.spairport_wireless_card_type, firmware: ifc.spairport_wireless_firmware_version,
      status: human(ifc.spairport_status_information), props: pick(ifc, [['spairport_supported_phymodes', 'phy_modes'], ['spairport_wireless_country_code', 'country']]) }));
  }
  for (const b of sp.SPBluetoothDataType || []) {
    const ctl = b.controller_properties || b.local_device_title || {};
    add(comp('bluetooth', 'Bluetooth controller', { model: ctl.controller_chipset, firmware: ctl.controller_firmwareVersion,
      status: human(ctl.controller_state), props: pick(ctl, [['controller_transport', 'transport'], ['controller_vendorID', 'vendor_id'], ['controller_supportedServices', 'services']]) }));
    for (const grp of b.device_connected || []) for (const [nm, dv] of Object.entries(grp)) add(comp('device', nm, {
      connection: 'bluetooth', status: 'connected', firmware: dv.device_firmwareVersion,
      props: pick(dv, [['device_minorType', 'type'], ['device_batteryLevelMain', 'battery'], ['device_batteryLevelLeft', 'battery_left'], ['device_batteryLevelRight', 'battery_right'], ['device_productID', 'product_id'], ['device_vendorID', 'vendor_id']]) }));
  }

  // Cameras and audio
  for (const c of sp.SPCameraDataType || []) add(comp('camera', c._name, { model: c.spcamera_model_id, connection: /iphone|continuity/i.test(S(c.spcamera_model_id)) ? 'continuity' : '',
    props: pick(c, [['spcamera_unique_id', 'unique_id']]) }));
  for (const a of sp.SPAudioDataType || []) for (const dv of a._items || []) {
    const ins = Number(dv.coreaudio_device_input || 0), outs = Number(dv.coreaudio_device_output || 0);
    add(comp('audio', dv._name, { vendor: dv.coreaudio_device_manufacturer, connection: human(dv.coreaudio_device_transport).replace(/^device type /, ''),
      props: { direction: ins && outs ? 'in/out' : ins ? 'input' : outs ? 'output' : '', sample_rate: S(dv.coreaudio_device_srate), default_input: yesno(dv.coreaudio_default_audio_input_device), default_output: yesno(dv.coreaudio_default_audio_output_device) } }));
  }

  // Card reader, wired Ethernet, PCI (Intel Macs, eGPUs, expansion chassis)
  walk(sp.SPCardReaderDataType, (it, d) => add(comp(d === 0 ? 'port' : 'device', d === 0 ? 'SD card reader' : it._name, { connection: 'sd', status: d === 0 ? (it._items ? 'card inserted' : 'empty') : 'inserted',
    props: pick(it, [['spcardreader_revision-id', 'revision'], ['spcardreader_link-speed', 'link_speed'], ['size', 'size']]) })));
  for (const e of sp.SPEthernetDataType || []) add(comp('ethernet', e._name || e.spethernet_device_type, { vendor: e.spethernet_vendor_name || e.spethernet_vendor_id,
    model: e.spethernet_device_type, connection: human(e.spethernet_bus || ''), props: pick(e, [['spethernet_BSD_Name', 'bsd'], ['spethernet_driver', 'driver'], ['spethernet_link-speed', 'link_speed']]) }));
  for (const p of sp.SPPCIDataType || []) add(comp('pci', p._name || p.sppci_name, { vendor: p['sppci_vendor-id'] || p.sppci_vendor, model: p['sppci_device-id'], connection: 'pci',
    props: pick(p, [['sppci_slot_name', 'slot'], ['sppci_link-width', 'link_width'], ['sppci_link-speed', 'link_speed'], ['sppci_device_type', 'type']]) }));

  return out;
}

// Text table for the human report, and numeric facts
function render(inv) {
  const order = ['logic_board', 'port', 'device', 'display', 'gpu', 'storage', 'battery', 'charger', 'wifi', 'bluetooth', 'camera', 'audio', 'ethernet', 'pci'];
  const label = { logic_board: 'Logic board', port: 'Ports', device: 'Connected devices', display: 'Displays', gpu: 'Graphics', storage: 'Internal storage',
    battery: 'Battery', charger: 'Power adapter', wifi: 'Wi-Fi', bluetooth: 'Bluetooth', camera: 'Cameras', audio: 'Audio', ethernet: 'Ethernet', pci: 'PCI' };
  const lines = [];
  for (const k of order) {
    const xs = inv.filter((c) => c.kind === k);
    if (!xs.length) continue;
    lines.push('@' + label[k]);
    for (const c of xs) {
      const bits = [c.vendor, c.model && c.model !== c.name ? c.model : '', c.connection, c.status].filter(Boolean);
      const pr = Object.entries(c.props || {}).filter(([, v]) => v && v !== 'no').map(([a, v]) => a + '=' + v).slice(0, 6);
      lines.push(c.name + (bits.length ? '  [' + bits.join(', ') + ']' : '') + (c.serial ? '  serial ' + c.serial : '') + (c.firmware ? '  fw ' + c.firmware : '') + (pr.length ? '  ' + pr.join(' ') : ''));
    }
  }
  const n = (f) => inv.filter(f).length;
  const watts = inv.filter((c) => c.kind === 'charger').map((c) => parseFloat((c.props || {}).watts)).find((w) => w > 0);
  const facts = {
    'hw.ports_thunderbolt': n((c) => c.kind === 'port' && c.connection === 'thunderbolt'),
    'hw.devices_connected': n((c) => c.kind === 'device' && !/^(yes|true)$/i.test(String((c.props || {}).built_in || ''))),
    'hw.displays_external': n((c) => c.kind === 'display' && c.connection !== 'internal'),
    'hw.components': inv.length,
  };
  if (watts) facts['power.charger_watts'] = watts;
  return { lines, facts };
}

// --- entry points --------------------------------------------------------------------------
function readText(path) {
  if (typeof ObjC !== 'undefined') {
    ObjC.import('Foundation');
    const s = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
    return s.isNil() ? '' : s.js;
  }
  return require('fs').readFileSync(path, 'utf8');
}
function main(argv) {
  let sp = {};
  try { sp = JSON.parse(readText(argv[0]) || '{}'); } catch (e) { sp = {}; }
  let io = ''; try { io = argv[1] ? readText(argv[1]) : ''; } catch (e) { io = ''; }
  const inv = inventory(sp, io, { target: argv[2] || '' });
  const r = render(inv);
  // line 1: inventory JSON; then @@TEXT lines; then @@FACTS "key value" lines (easy to split in bash 3.2)
  return [JSON.stringify(inv), '@@TEXT'].concat(r.lines, ['@@FACTS'], Object.entries(r.facts).map(([k, v]) => k + ' ' + v)).join('\n');
}
// osascript calls run(argv) and prints the returned string
function run(argv) { return main(argv); } // eslint-disable-line no-unused-vars
if (typeof module !== 'undefined' && typeof require === 'function') {
  module.exports = { inventory, ioregData, render };
  if (require.main === module) process.stdout.write(main(process.argv.slice(2)) + '\n');
}
QED_INVENTORY_JS
}
# <<< inventory.js

# ---- working area, single-instance lock, cleanup -----------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/qed-health.XXXXXX") || { echo "Cannot create temp folder" >&2; exit 1; }
LOCK="${TMPDIR:-/tmp}/qed-mac-health.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  OLDPID=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$OLDPID" ] && kill -0 "$OLDPID" 2>/dev/null; then
    echo "Another health snapshot is already running (pid $OLDPID)." >&2; rm -rf "$WORK"; exit 1
  fi
  rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null
fi
echo $$ >"$LOCK/pid"

cleanup() {
  local p
  for p in $(jobs -p 2>/dev/null); do kill "$p" >/dev/null 2>&1; done
  rm -rf "$WORK" "$LOCK"
}
trap cleanup EXIT
trap 'printf "\n%sInterrupted - no report written.%s\n" "$YEL" "$RST" >&2; exit 130' INT TERM HUP

# keep the Mac awake while running
have caffeinate && { caffeinate -i -w $$ >/dev/null 2>&1 & }

# ---- progress ----------------------------------------------------------------
TOTAL_STEPS=17; STEP=0
progress() {
  STEP=$((STEP + 1))
  printf '%s[%2d/%d]%s %s\n' "$BLU" "$STEP" "$TOTAL_STEPS" "$RST" "$1" >&2
}

# ---- report sections (each section -> .txt + .html fragment) ------------------
SEC_N=0; SEC_T=(); CUR_T=/dev/null; CUR_H=/dev/null
sec() {
  SEC_N=$((SEC_N + 1)); SEC_T[$SEC_N]="$1"
  CUR_T="$WORK/s$SEC_N.txt"; CUR_H="$WORK/s$SEC_N.html"; : >"$CUR_T"; : >"$CUR_H"
  progress "$1"
}
# Report text never shows the full home-folder path.
redact() { if [ -n "${REAL_HOME:-}" ]; then sed "s|$REAL_HOME|~|g"; else cat; fi; }
kv() {
  local v="${2:-n/a}"; v=$(printf '%s' "$v" | redact)
  printf '  %-34s %s\n' "$1" "$v" >>"$CUR_T"
  printf '<div class="kv"><span class="k">%s</span><span class="v">%s</span></div>\n' "$(h "$1")" "$(h "$v")" >>"$CUR_H"
}
note() { local t; t=$(printf '%s' "$1" | redact); printf '  %s\n' "$t" >>"$CUR_T"; printf '<h4>%s</h4>\n' "$(h "$t")" >>"$CUR_H"; }
blk() {
  local t; t=$(redact)
  [ -n "$(printf '%s' "$t" | tr -d '[:space:]')" ] || t="(none)"
  printf '%s\n' "$t" | sed 's/^/      /' >>"$CUR_T"
  printf '<pre>%s</pre>\n' "$(printf '%s\n' "$t" | hs)" >>"$CUR_H"
}

# ---- health checks -------------------------------------------------------------
CK_S=(); CK_A=(); CK_M=(); CK_F=(); CK_I=(); WORST=0; NWARN=0; NFAIL=0; NOK=0; NINFO=0; NUNK=0

# Stable check IDs (qed.device-health/v1 catalog). Same ID = same meaning on every OS.
ckid() {
  case "$1" in
    "macOS") echo os.version ;;           "Uptime") echo sys.uptime ;;
    "Boot mode") echo sys.safe_boot ;;    "Secure Boot") echo sec.secure_boot ;;
    "CPU load") echo cpu.load ;;          "Thermal") echo cpu.thermal ;;
    "Processes") echo cpu.zombies ;;
    "Memory") case "$2" in *module*) echo mem.hardware ;; *) echo mem.pressure ;; esac ;;
    "Disk space") echo storage.free_space ;;
    "Disk "*) echo "storage.smart_$(printf '%s' "${1#Disk }" | tr -c 'a-z0-9' '_' | sed 's/_*$//')" ;;
    "SSD wear") echo storage.ssd_wear ;;  "Spotlight") echo storage.spotlight ;;
    "Battery") case "$2" in *apacity*) echo battery.capacity ;; *ycle*) echo battery.cycles ;; *) echo battery.health ;; esac ;;     "Battery temp") echo battery.temperature ;;
    "Network") echo net.connectivity ;;   "Packet loss") echo net.packet_loss ;;
    "Latency") echo net.latency ;;        "Clock") echo net.clock_skew ;;
    "Proxy") echo net.proxy ;;            "Wi-Fi") echo net.wifi_signal ;;
    "Wi-Fi security") echo net.wifi_security ;;
    "FileVault") echo sec.disk_encryption ;; "SIP") echo sec.sip ;;
    "Gatekeeper") echo sec.gatekeeper ;;  "Firewall") echo sec.firewall ;;
    "Auto updates") case "$2" in *XProtect*) echo os.auto_system_data ;; *ecurity*) echo os.auto_security_responses ;; *) echo os.auto_check ;; esac ;;
    "Auto login") echo sec.auto_login ;;  "Guest account") echo sec.guest_account ;;
    "Screen lock") echo sec.screen_lock ;;
    "Remote access") case "$2" in SSH*) echo sec.remote_ssh ;; *VNC*) echo sec.remote_screen_sharing ;; *) echo sec.remote_ard ;; esac ;;
    "Remote tools") echo sec.remote_tools ;; "MDM") echo mgmt.enrollment ;;
    "Admins") echo users.admins ;;        "Updates") echo os.updates_pending ;;
    "Intel apps") echo apps.intel_only ;; "Stability") echo stability.panics ;;
    "App crashes") echo stability.crashes ;; "Out of memory") echo stability.jetsam ;;
    "Sleep/wake") echo stability.sleep_wake ;; "Last shutdown") echo stability.last_shutdown ;;
    "Login jobs") echo startup.login_jobs ;; "Kernel exts") echo startup.kexts ;;
    "Backup") echo backup.recency ;;      "Speed") echo net.speed ;;
    "Hardware") echo hw.inventory ;;
    *) echo "misc.$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_' | sed 's/_*$//; s/^_*//')" ;;
  esac
}

# chk STATUS AREA MESSAGE [FIX]
# Anything we could not read is UNKNOWN, never a failure.
chk() {
  local st="$1"
  if [ "$st" = INFO ]; then
    case "$3" in *unreadable*|*"timed out"*|*"could not"*|*"Could not"*) st=UNKNOWN ;; esac
  fi
  CK_S+=("$st"); CK_A+=("$2"); CK_M+=("$3"); CK_F+=("${4:-}"); CK_I+=("$(ckid "$2" "$3")")
  case "$st" in
    UNKNOWN) NUNK=$((NUNK + 1)) ;;
    OK) NOK=$((NOK + 1)) ;;
    INFO) NINFO=$((NINFO + 1)) ;;
    WARN) NWARN=$((NWARN + 1)); [ "$WORST" -lt 1 ] && WORST=1 ;;
    FAIL) NFAIL=$((NFAIL + 1)); WORST=2 ;;
  esac
}

# ---- background jobs (slow checks run in parallel) ------------------------------
# bgrun NAME TIMEOUT cmd...   -> output in $WORK/bg_NAME.out
bgrun() {
  local n="$1" s="$2"; shift 2
  ( tmo "$s" "$@" >"$WORK/bg_$n.out" 2>&1; echo $? >"$WORK/bg_$n.rc" ) &
  eval "BGPID_$n=$!"
}
# bgwait must run in the main shell (not inside $( ) or a pipe) so wait works
bgwait() { local p; eval "p=\${BGPID_$1:-}"; [ -n "$p" ] && wait "$p" 2>/dev/null; }
bgout() { cat "$WORK/bg_$1.out" 2>/dev/null; }

# ---- who / where -----------------------------------------------------------------
REAL_USER="${SUDO_USER:-$(id -un)}"
REAL_HOME=$(dscl . -read "/Users/$REAL_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
[ -n "$REAL_HOME" ] || REAL_HOME="$HOME"
[ -n "$OUTDIR" ] || OUTDIR="$REAL_HOME/QED-Mac-Health"

printf '\n%sQED Mac Health Snapshot v%s%s  %s(read-only, about %s)%s\n\n' "$BLD" "$VERSION" "$RST" "$DIM" \
  "$( [ "$QUICK" -eq 1 ] && echo '20 seconds' || echo '1-3 minutes')" "$RST" >&2

# ============================================================================
#  1. SYSTEM
# ============================================================================
sec "System overview"
COMPUTER_NAME=$(scutil --get ComputerName 2>/dev/null || hostname)
LOCAL_HOST=$(scutil --get LocalHostName 2>/dev/null)
OS_NAME=$(sw_vers -productName 2>/dev/null)
OS_VER=$(sw_vers -productVersion 2>/dev/null)
OS_BUILD=$(sw_vers -buildVersion 2>/dev/null)
OS_EXTRA=$(sw_vers -productVersionExtra 2>/dev/null)   # Rapid Security Response, e.g. (a)
OS_MAJOR=${OS_VER%%.*}
KERNEL=$(uname -r)
HW=$(tmo 60 system_profiler SPHardwareDataType 2>/dev/null)
MODEL_NAME=$(echo "$HW" | field "Model Name")
MODEL_ID=$(sysctl -n hw.model 2>/dev/null)
MODEL_NUM=$(echo "$HW" | field "Model Number")
SERIAL=$(echo "$HW" | field "Serial Number (system)")
HW_UUID=$(echo "$HW" | field "Hardware UUID")
[ -n "$HW_UUID" ] || HW_UUID=$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | sed -n 's/.*"IOPlatformUUID" = "\(.*\)".*/\1/p' | head -n 1)
PRIMARY_MAC=$(networksetup -listallhardwareports 2>/dev/null | awk '/^Device: en0$/{f=1;next} f&&/^Ethernet Address:/{print tolower($3); exit}')
[ -n "$PRIMARY_MAC" ] || PRIMARY_MAC=$(ifconfig en0 2>/dev/null | awk '/ether /{print tolower($2); exit}')
HW_UUID=$(echo "$HW" | field "Hardware UUID")
PROV_UDID=$(echo "$HW" | field "Provisioning UDID")
FIRMWARE=$(echo "$HW" | field "System Firmware Version"); [ -n "$FIRMWARE" ] || FIRMWARE=$(echo "$HW" | field "Boot ROM Version")
OSLOADER=$(echo "$HW" | field "OS Loader Version")
ACT_LOCK=$(echo "$HW" | field "Activation Lock Status")
MEM_TYPE=$(echo "$HW" | field "Memory")
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ]; then
  APPLE_SILICON=1; PLATFORM="Apple silicon"; CHIP=$(echo "$HW" | field "Chip")
else
  APPLE_SILICON=0; PLATFORM="Intel"; CHIP=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
  T2=$(tmo 30 system_profiler SPiBridgeDataType 2>/dev/null)
  T2_MODEL=$(echo "$T2" | field "Model Name")
  SECURE_BOOT=$(echo "$T2" | field "Secure Boot")
fi
[ -n "$CHIP" ] || CHIP=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
[ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = "1" ] && PLATFORM="$PLATFORM (Terminal running under Rosetta)"
NCPU=$(sysctl -n hw.ncpu 2>/dev/null); isnum "$NCPU" || NCPU=1
PCPU=$(sysctl -n hw.physicalcpu 2>/dev/null)
PERF_CORES=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null)
EFF_CORES=$(sysctl -n hw.perflevel1.physicalcpu 2>/dev/null)
CORES_DESC=$(echo "$HW" | field "Total Number of Cores")
[ -n "$CORES_DESC" ] || CORES_DESC="$PCPU physical / $NCPU logical"
MEM_B=$(sysctl -n hw.memsize 2>/dev/null); isnum "$MEM_B" || MEM_B=0
MEM_GB=$((MEM_B / 1073741824))
BOOT_TS=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ sec = \([0-9]*\),.*/\1/p')
NOW_TS=$(date +%s); isnum "$BOOT_TS" || BOOT_TS=$NOW_TS
UP_S=$((NOW_TS - BOOT_TS)); UP_D=$((UP_S / 86400)); UP_H=$(((UP_S % 86400) / 3600)); UP_M=$(((UP_S % 3600) / 60))
UPTIME_TXT="${UP_D}d ${UP_H}h ${UP_M}m"
BOOT_HUMAN=$(date -r "$BOOT_TS" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
SAFE_BOOT=$(sysctl -n kern.safeboot 2>/dev/null)
TZ_NAME=$(readlink /etc/localtime 2>/dev/null | sed 's|.*zoneinfo/||')
CONSOLE_USER=$(stat -f %Su /dev/console 2>/dev/null)
IS_ADMIN=no; id -Gn "$REAL_USER" 2>/dev/null | tr ' ' '\n' | grep -qx admin && IS_ADMIN=yes
ROSETTA="n/a"
if [ "$APPLE_SILICON" -eq 1 ]; then
  if [ -f /Library/Apple/usr/share/rosetta/rosetta ] || pgrep -q oahd 2>/dev/null; then ROSETTA=installed; else ROSETTA="not installed"; fi
fi
BOOT_ARGS=$(nvram boot-args 2>/dev/null | cut -f2-)

kv "Computer name" "$COMPUTER_NAME"
kv "Local hostname" "${LOCAL_HOST}.local"
kv "Model" "$MODEL_NAME ($MODEL_ID${MODEL_NUM:+, $MODEL_NUM})"
kv "Serial number" "$SERIAL"
kv "Hardware UUID" "$HW_UUID"
[ -n "$PROV_UDID" ] && kv "Provisioning UDID" "$PROV_UDID"
kv "Platform" "$PLATFORM"
kv "Processor / chip" "$CHIP"
kv "CPU cores" "$CORES_DESC"
[ -n "$PERF_CORES" ] && kv "Performance / efficiency" "$PERF_CORES / ${EFF_CORES:-0}"
kv "Memory" "$(hb "$MEM_B")"
kv "macOS" "$OS_NAME $OS_VER${OS_EXTRA:+ $OS_EXTRA} ($OS_BUILD)"
kv "Darwin kernel" "$KERNEL"
kv "System firmware" "$FIRMWARE"
[ -n "$OSLOADER" ] && kv "OS loader" "$OSLOADER"
[ -n "${T2_MODEL:-}" ] && kv "Security chip" "$T2_MODEL"
[ -n "${SECURE_BOOT:-}" ] && kv "Secure Boot" "$SECURE_BOOT"
kv "Activation Lock" "$ACT_LOCK"
kv "Rosetta 2" "$ROSETTA"
kv "Safe mode boot" "$( [ "$SAFE_BOOT" = 1 ] && echo YES || echo no)"
[ -n "$BOOT_ARGS" ] && kv "Boot arguments" "$BOOT_ARGS"
kv "Time zone" "$TZ_NAME"
kv "Last boot" "$BOOT_HUMAN"
kv "Uptime" "$UPTIME_TXT"
kv "Console (logged-in) user" "$CONSOLE_USER"
kv "Report run by" "$REAL_USER (admin: $IS_ADMIN)$( [ "$(id -u)" = 0 ] && echo ', via sudo')"

if isnum "$OS_MAJOR" && [ "$OS_MAJOR" -lt "$MIN_MACOS_MAJOR" ]; then
  chk WARN "macOS" "$OS_VER is older than QED minimum (macOS $MIN_MACOS_MAJOR)" "Upgrade macOS in System Settings > General > Software Update, or replace the Mac if it can't be upgraded."
else
  chk OK "macOS" "$OS_NAME $OS_VER ($OS_BUILD)"
fi
if [ "$UP_D" -gt "$UPTIME_WARN_DAYS" ]; then
  chk WARN "Uptime" "$UP_D days since last restart" "Restart the Mac to apply pending updates and clear memory leaks."
else
  chk OK "Uptime" "$UPTIME_TXT"
fi
[ "$SAFE_BOOT" = 1 ] && chk WARN "Boot mode" "Mac is running in Safe Mode" "Restart normally."
case "${SECURE_BOOT:-}" in ""|*Full*) ;; *) chk WARN "Secure Boot" "T2 Secure Boot: $SECURE_BOOT" "Set Full Security in Startup Security Utility (macOS Recovery)." ;; esac

# ============================================================================
#  2. CPU, LOAD, THERMAL  (sampled before background jobs start)
# ============================================================================
sec "CPU, load and thermal"
LOAD=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2, $3, $4}')
L1=$(echo "$LOAD" | awk '{print $1}'); L15=$(echo "$LOAD" | awk '{print $3}')
LOAD_LIMIT=$(awk -v n="$NCPU" 'BEGIN{print n * 1.5}')
CPU_LINE=$(tmo 15 top -l 2 -s 1 -n 0 2>/dev/null | grep 'CPU usage' | tail -n 1 | sed 's/^CPU usage: *//')
CPU_IDLE=$(echo "$CPU_LINE" | sed -n 's/.* \([0-9.]*\)% idle.*/\1/p')
THERM=$(pmset -g therm 2>/dev/null)
SPEED_LIMIT=$(echo "$THERM" | sed -n 's/.*CPU_Speed_Limit[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' | head -n 1)
THERM_LEVEL=$(sysctl -n machdep.xcpm.cpu_thermal_level 2>/dev/null)
PROC_COUNT=$(ps -A -o pid= 2>/dev/null | wc -l | tr -d ' ')
ZOMBIES=$(ps -A -o stat= 2>/dev/null | grep -c '^Z')

kv "Load average (1/5/15 min)" "$LOAD"
kv "Logical CPUs" "$NCPU"
kv "CPU usage (now)" "$CPU_LINE"
kv "Processes / zombies" "$PROC_COUNT / $ZOMBIES"
kv "CPU speed limit" "${SPEED_LIMIT:+$SPEED_LIMIT%}"
[ -n "$THERM_LEVEL" ] && kv "CPU thermal level" "$THERM_LEVEL"
note "Thermal state (pmset)"
echo "$THERM" | blk
note "Top processes by CPU"
ps -Ao pid,pcpu,pmem,etime,user,ucomm -r 2>/dev/null | head -n 12 | blk

if fgt "$L15" "$LOAD_LIMIT"; then
  chk WARN "CPU load" "15-min load $L15 on $NCPU CPUs" "Check the top CPU processes below; quit or update the offender, or restart."
elif isnum "${CPU_IDLE%%.*}" && [ "${CPU_IDLE%%.*}" -lt 10 ] && fgt "$L1" "$NCPU"; then
  chk WARN "CPU load" "CPU is pegged right now (${CPU_IDLE}% idle)" "See top CPU processes; a runaway process may need to be quit."
else
  chk OK "CPU load" "15-min load ${L15:-?} on $NCPU CPUs${CPU_IDLE:+, ${CPU_IDLE}% idle}"
fi
if isnum "$SPEED_LIMIT" && [ "$SPEED_LIMIT" -lt 100 ]; then
  chk WARN "Thermal" "CPU throttled to ${SPEED_LIMIT}%" "Check vents/fans, clean dust, use a hard flat surface; run Apple Diagnostics if it persists."
elif echo "$THERM" | grep -qiE 'level set to|warning level [1-9]'; then
  chk WARN "Thermal" "Thermal/performance warning recorded" "Check ventilation and fans; run Apple Diagnostics if it repeats."
else
  chk OK "Thermal" "No thermal throttling"
fi
[ "${ZOMBIES:-0}" -gt 20 ] && chk WARN "Processes" "$ZOMBIES zombie processes" "Restart the Mac; identify the parent app if it recurs."

# ============================================================================
#  3. MEMORY
# ============================================================================
sec "Memory"
VM=$(vm_stat 2>/dev/null)
PAGESZ=$(echo "$VM" | sed -n 's/.*page size of \([0-9]*\) bytes.*/\1/p'); isnum "$PAGESZ" || PAGESZ=4096
pg() { echo "$VM" | awk -F: -v k="$1" '$1==k{gsub(/[ .]/,"",$2); print $2}'; }
P_FREE=$(pg "Pages free"); P_ACT=$(pg "Pages active"); P_INACT=$(pg "Pages inactive")
P_SPEC=$(pg "Pages speculative"); P_WIRED=$(pg "Pages wired down"); P_COMP=$(pg "Pages occupied by compressor")
P_PURG=$(pg "Pages purgeable"); P_FILE=$(pg "File-backed pages")
SWAPINS=$(pg "Swapins"); SWAPOUTS=$(pg "Swapouts")
USED_B=$(( (${P_ACT:-0} + ${P_WIRED:-0} + ${P_COMP:-0}) * PAGESZ ))
PRESSURE_LVL=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)
MP_FREE=$(tmo 10 memory_pressure -Q 2>/dev/null | sed -n 's/.*free percentage: *\([0-9]*\)%.*/\1/p')
SWAP=$(sysctl -n vm.swapusage 2>/dev/null)
SWAP_USED_MB=$(echo "$SWAP" | awk '{for(i=1;i<=NF;i++) if($i=="used"){v=$(i+2); m=1; if(v~/G$/)m=1024; sub(/[MG]$/,"",v); printf "%d", v*m}}')
isnum "$SWAP_USED_MB" || SWAP_USED_MB=0
MEM_MB=$((MEM_B / 1048576))
case "$PRESSURE_LVL" in 1) PRESSURE_TXT=normal ;; 2) PRESSURE_TXT=warning ;; 4) PRESSURE_TXT=critical ;; *) PRESSURE_TXT="normal" ;; esac

kv "Installed" "$(hb "$MEM_B")"
kv "In use (app + wired + compressed)" "$(hb "$USED_B")"
kv "Wired" "$(hb $(( ${P_WIRED:-0} * PAGESZ )))"
kv "Compressed" "$(hb $(( ${P_COMP:-0} * PAGESZ )))"
kv "Cached files" "$(hb $(( ${P_FILE:-0} * PAGESZ )))"
kv "Free + inactive + speculative" "$(hb $(( (${P_FREE:-0} + ${P_INACT:-0} + ${P_SPEC:-0}) * PAGESZ )))"
kv "Purgeable" "$(hb $(( ${P_PURG:-0} * PAGESZ )))"
kv "Memory pressure" "$PRESSURE_TXT${MP_FREE:+ (system-wide free: $MP_FREE%)}"
kv "Swap" "$SWAP"
kv "Swap-ins / swap-outs since boot" "${SWAPINS:-0} / ${SWAPOUTS:-0}"
if [ "$APPLE_SILICON" -eq 0 ]; then
  MEMHW=$(tmo 30 system_profiler SPMemoryDataType 2>/dev/null)
  note "Memory modules"
  echo "$MEMHW" | grep -E 'BANK|DIMM|Size:|Type:|Speed:|Status:|Manufacturer:' | trim | blk
  echo "$MEMHW" | grep 'Status:' | grep -vqE 'OK|Empty' && chk FAIL "Memory" "A memory module reports a non-OK status" "Run Apple Diagnostics; reseat or replace RAM."
fi
note "Top processes by memory"
ps -Ao pid,pmem,rss,user,ucomm -m 2>/dev/null | head -n 12 | awk 'NR==1{printf "%7s %5s %9s %-12s %s\n","PID","%MEM","RSS","USER","COMMAND";next}{c=$5; for(i=6;i<=NF;i++)c=c" "$i; printf "%7s %5s %7.0fMB %-12s %s\n",$1,$2,$3/1024,$4,c}' | blk

case "$PRESSURE_LVL" in
  4) chk FAIL "Memory" "Memory pressure CRITICAL" "Quit heavy apps/browser tabs now; this Mac needs more RAM for its workload." ;;
  2) chk WARN "Memory" "Memory pressure elevated, swap $(awk -v m="$SWAP_USED_MB" 'BEGIN{printf "%.1f", m/1024}') GB used on ${MEM_GB} GB RAM" "Quit unused apps and browser tabs; restart if it persists. If it keeps coming back, this Mac needs more memory for its workload." ;;
  *) if [ "$MEM_MB" -gt 0 ] && [ "$SWAP_USED_MB" -gt $((MEM_MB / 2)) ]; then
       chk WARN "Memory" "Heavy swap use (${SWAP_USED_MB} MB on ${MEM_GB} GB RAM)" "Restart; if it returns quickly the Mac is under-specced for its workload."
     else
       chk OK "Memory" "Pressure $PRESSURE_TXT, swap ${SWAP_USED_MB} MB, ${MEM_GB} GB RAM"
     fi ;;
esac

# ---- start slow checks in parallel ------------------------------------------------
if [ "$QUICK" -eq 0 ]; then
  bgrun swupdate 180 softwareupdate -l
  [ "$APPLE_SILICON" -eq 1 ] && bgrun apps 180 system_profiler SPApplicationsDataType
  LS_START=$(date -r "$BOOT_TS" '+%Y-%m-%d %H:%M:%S'); LS_END=$(date -r $((BOOT_TS + 900)) '+%Y-%m-%d %H:%M:%S')
  bgrun shutdown 120 log show --style compact --start "$LS_START" --end "$LS_END" --predicate 'eventMessage CONTAINS "Previous shutdown cause"'
  if have brew && [ "$(id -u)" != 0 ]; then bgrun brew 120 brew outdated --quiet; fi
fi
bgrun sp_disp 60 system_profiler SPDisplaysDataType
bgrun sp_usb 60 system_profiler SPUSBHostDataType SPUSBDataType
bgrun sp_tb 60 system_profiler SPThunderboltDataType
bgrun sp_bt 60 system_profiler SPBluetoothDataType
bgrun sp_cam 60 system_profiler SPCameraDataType
bgrun sp_audio 60 system_profiler SPAudioDataType
HW_TYPES="SPHardwareDataType SPThunderboltDataType SPUSBHostDataType SPUSBDataType SPDisplaysDataType SPNVMeDataType SPSerialATADataType SPPowerDataType SPAirPortDataType SPBluetoothDataType SPCameraDataType SPAudioDataType SPCardReaderDataType SPEthernetDataType SPPCIDataType"
# shellcheck disable=SC2086
( tmo 90 system_profiler -json $HW_TYPES >"$WORK/sp_hw.json" 2>/dev/null ) & BGPID_sphw=$!
bgrun sp_wifi 60 system_profiler SPAirPortDataType

# ============================================================================
#  4. STORAGE
# ============================================================================
sec "Storage"
DATA_VOL=/; [ -d /System/Volumes/Data ] && DATA_VOL=/System/Volumes/Data
read -r D_TOT D_USED D_AVAIL <<<"$(df -Pk "$DATA_VOL" 2>/dev/null | awk 'NR==2{print $2, $3, $4}')"
isnum "$D_TOT" || D_TOT=0; isnum "$D_AVAIL" || D_AVAIL=0
D_FREE_PCT=0; [ "$D_TOT" -gt 0 ] && D_FREE_PCT=$((D_AVAIL * 100 / D_TOT))
D_FREE_GB=$((D_AVAIL / 1048576)); D_TOT_GB=$((D_TOT / 1048576))
ROOT_INFO=$(diskutil info / 2>/dev/null)
CONT_FREE=$(echo "$ROOT_INFO" | field "Container Free Space" | sed 's/ (.*//')
SNAPS=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple')
SPOTLIGHT=$(tmo 10 mdutil -s / 2>/dev/null | tail -n 1 | trim)
CACHE_KB=$(tmo 30 du -sk "$REAL_HOME/Library/Caches" 2>/dev/null | awk '{print $1}')
LOGS_KB=$(tmo 20 du -sk "$REAL_HOME/Library/Logs" 2>/dev/null | awk '{print $1}')

kv "Startup volume" "$(echo "$ROOT_INFO" | field "Volume Name") ($(echo "$ROOT_INFO" | field "File System Personality"))"
kv "Container size" "$(hb $((D_TOT * 1024)))"
kv "Free (excluding purgeable)" "$(hb $((D_AVAIL * 1024))) (${D_FREE_PCT}%)"
[ -n "$CONT_FREE" ] && kv "Container free space" "$CONT_FREE"
kv "Sealed system volume" "$(echo "$ROOT_INFO" | field "Sealed")"
kv "Local APFS snapshots" "$SNAPS"
kv "Spotlight" "$SPOTLIGHT"
kv "User caches (~/Library/Caches)" "$(isnum "$CACHE_KB" && hb $((CACHE_KB * 1024)))"
kv "User logs (~/Library/Logs)" "$(isnum "$LOGS_KB" && hb $((LOGS_KB * 1024)))"
note "Mounted volumes"
df -hl 2>/dev/null | awk 'NR==1{print;next} $1 ~ /^(devfs|map)/ {next} /\/System\/Volumes\// && !/\/System\/Volumes\/Data$/ {next} {print}' | blk
note "Network volumes"
mount 2>/dev/null | grep -E ' \((smbfs|afpfs|nfs|webdav)' | blk

note "Physical disks"
DISKS_TXT=""
for d in $(diskutil list physical 2>/dev/null | awk '/^\/dev\/disk/{print $1}'); do
  DI=$(tmo 20 diskutil info "$d" 2>/dev/null)
  DN=${d#/dev/}
  D_NAME=$(echo "$DI" | field "Device / Media Name")
  D_SIZE=$(echo "$DI" | field "Disk Size" | sed 's/ (.*//')
  D_SSD=$(echo "$DI" | field "Solid State")
  D_PROTO=$(echo "$DI" | field "Protocol")
  D_LOC=$(echo "$DI" | field "Device Location")
  if [ -z "$D_LOC" ]; then [ "$(echo "$DI" | field "Internal")" = "Yes" ] && D_LOC=Internal || D_LOC=External; fi
  D_SMART=$(echo "$DI" | field "SMART Status")
  DISKS_TXT="$DISKS_TXT$(printf '%-8s %-30s %-10s %-12s SSD:%-4s %-9s SMART: %s' "$DN" "${D_NAME:-?}" "${D_SIZE:-?}" "${D_PROTO:-?}" "${D_SSD:-?}" "$D_LOC" "${D_SMART:-n/a}")"$'\n'
  case "$D_SMART" in
    Verified) [ "$D_LOC" = Internal ] && chk OK "Disk $DN" "${D_NAME:-disk} SMART verified" ;;
    *[Ff]ail*) chk FAIL "Disk $DN" "${D_NAME:-disk} SMART FAILING" "Back up immediately and replace the drive (or the Mac for soldered SSDs)." ;;
    ""|*"Not Supported"*) ;;
    *) [ "$D_LOC" = Internal ] && chk INFO "Disk $DN" "${D_NAME:-disk} SMART: $D_SMART" ;;
  esac
done
printf '%s' "$DISKS_TXT" | blk

if have smartctl; then
  SM=$(tmo 30 smartctl -a disk0 2>&1)
  note "SSD health (smartctl)"
  echo "$SM" | grep -E 'SMART overall|Percentage Used|Available Spare:|Media and Data Integrity|Power On Hours|Power Cycles|Unsafe Shutdowns|Data Units Written|Temperature:' | blk
  WEAR=$(echo "$SM" | sed -n 's/^Percentage Used:[[:space:]]*\([0-9]*\)%.*/\1/p' | head -n 1)
  if isnum "$WEAR"; then
    if [ "$WEAR" -ge 90 ]; then chk FAIL "SSD wear" "${WEAR}% of rated endurance used" "Plan SSD/Mac replacement; keep backups current."
    elif [ "$WEAR" -ge 70 ]; then chk WARN "SSD wear" "${WEAR}% of rated endurance used" "Plan replacement within the year; keep backups current."
    else chk OK "SSD wear" "${WEAR}% of rated endurance used"; fi
  fi
fi

if [ "$D_FREE_PCT" -lt "$DISK_FREE_FAIL_PCT" ] || [ "$D_FREE_GB" -lt "$DISK_FREE_FAIL_GB" ]; then
  chk FAIL "Disk space" "Only ${D_FREE_GB} GB (${D_FREE_PCT}%) free of ${D_TOT_GB} GB" "Free space now: empty Trash, clear Downloads, remove old iOS backups/large files (Apple menu > About This Mac > Storage)."
elif [ "$D_FREE_PCT" -lt "$DISK_FREE_WARN_PCT" ]; then
  chk WARN "Disk space" "${D_FREE_GB} GB (${D_FREE_PCT}%) free of ${D_TOT_GB} GB" "Free up space soon; macOS needs ~20% free for updates and swap."
else
  chk OK "Disk space" "${D_FREE_GB} GB (${D_FREE_PCT}%) free of ${D_TOT_GB} GB"
fi
echo "$SPOTLIGHT" | grep -qi 'disabled' && chk INFO "Spotlight" "Indexing disabled on startup disk"

# ============================================================================
#  5. BATTERY AND POWER
# ============================================================================
sec "Battery and power"
BATT=$(pmset -g batt 2>/dev/null)
POWER_SRC=$(echo "$BATT" | sed -n "s/^Now drawing from '\(.*\)'.*/\1/p")
HAS_BATT=0; BATT_SUMMARY="none (desktop)"
kv "Power source" "$POWER_SRC"
if echo "$BATT" | grep -q InternalBattery; then
  HAS_BATT=1
  BLINE=$(echo "$BATT" | grep InternalBattery | head -n 1)
  B_PCT=$(echo "$BLINE" | grep -o '[0-9]\{1,3\}%' | head -n 1)
  B_STATE=$(echo "$BLINE" | awk -F'; ' '{print $2}')
  B_REMAIN=$(echo "$BLINE" | awk -F'; ' '{print $3}' | sed 's/ present.*//')
  PWR=$(tmo 60 system_profiler SPPowerDataType 2>/dev/null)
  CYCLES=$(echo "$PWR" | field "Cycle Count")
  COND=$(echo "$PWR" | field "Condition")
  MAXCAP=$(echo "$PWR" | field "Maximum Capacity" | tr -dc '0-9')
  CHARGER_W=$(echo "$PWR" | field "Wattage (W)")
  CHARGER_NAME=$(echo "$PWR" | field "Name")
  IOB=$(ioreg -rn AppleSmartBattery 2>/dev/null)
  io() { echo "$IOB" | sed -n "s/^[[:space:]]*\"$1\" = \([0-9-]*\)$/\1/p" | head -n 1; }
  DESIGN=$(io DesignCapacity)
  RAWMAX=$(io AppleRawMaxCapacity)
  if [ -z "$RAWMAX" ]; then RAWMAX=$(io MaxCapacity); isnum "$RAWMAX" && [ "$RAWMAX" -le 100 ] && RAWMAX=""; fi
  DESIGN_CYCLES=$(io DesignCycleCount9C); isnum "$DESIGN_CYCLES" || DESIGN_CYCLES=1000
  isnum "$CYCLES" || CYCLES=$(io CycleCount)
  B_TEMP=$(io Temperature); B_VOLT=$(io Voltage)
  B_SERIAL=$(echo "$IOB" | sed -n 's/^[[:space:]]*"Serial" = "\(.*\)"$/\1/p' | head -n 1)
  B_MFG_DATE=$(echo "$IOB" | sed -n 's/^[[:space:]]*"ManufactureDate" = \([0-9]*\)$/\1/p' | head -n 1)
  if [ -z "$MAXCAP" ] && isnum "$RAWMAX" && isnum "$DESIGN" && [ "$DESIGN" -gt 0 ]; then MAXCAP=$((RAWMAX * 100 / DESIGN)); fi
  kv "Charge" "$B_PCT ($B_STATE${B_REMAIN:+, $B_REMAIN})"
  kv "Condition" "$COND"
  kv "Maximum capacity" "${MAXCAP:+$MAXCAP%}"
  kv "Full charge / design (mAh)" "${RAWMAX:-?} / ${DESIGN:-?}"
  kv "Cycle count" "${CYCLES:-?} (rated ~$DESIGN_CYCLES)"
  isnum "$B_TEMP" && kv "Battery temperature" "$(awk -v t="$B_TEMP" 'BEGIN{printf "%.1f C", t/100}')"
  isnum "$B_VOLT" && kv "Voltage" "$(awk -v v="$B_VOLT" 'BEGIN{printf "%.2f V", v/1000}')"
  [ -n "$B_SERIAL" ] && kv "Battery serial" "$B_SERIAL"
  kv "Charger" "${CHARGER_W:+$CHARGER_W W}${CHARGER_NAME:+ ($CHARGER_NAME)}"
  BATT_SUMMARY="${MAXCAP:-?}% health, ${CYCLES:-?} cycles"

  case "$COND" in
    *"Replace Now"*|*"Service Battery"*) chk FAIL "Battery" "Condition: $COND" "Book battery service." ;;
    *Service*|*Replace*|*Check*) chk WARN "Battery" "Condition: $COND" "Book battery service soon." ;;
  esac
  if isnum "$MAXCAP" && [ "$MAXCAP" -lt "$BATTERY_WARN_PCT" ]; then
    chk WARN "Battery" "Maximum capacity ${MAXCAP}% (below ${BATTERY_WARN_PCT}%)" "Battery is worn; schedule a replacement."
  elif isnum "$CYCLES" && [ "$CYCLES" -ge "$DESIGN_CYCLES" ]; then
    chk WARN "Battery" "$CYCLES cycles (rated $DESIGN_CYCLES)" "Battery is past rated life; schedule a replacement."
  else
    chk OK "Battery" "${MAXCAP:-?}% capacity, ${CYCLES:-?} cycles, ${COND:-n/a}"
  fi
  isnum "$B_TEMP" && [ "$B_TEMP" -gt 4500 ] && chk WARN "Battery temp" "Battery at $((B_TEMP / 100)) C" "Let the Mac cool; avoid charging in hot places."
else
  kv "Battery" "None (desktop Mac)"
  if echo "$BATT" | grep -qi ups; then note "UPS"; echo "$BATT" | blk; fi
fi
LOWPOWER=$(pmset -g 2>/dev/null | awk '/lowpowermode|powermode/{print $2; exit}')
kv "Low Power Mode" "$( [ "$LOWPOWER" = 1 ] && echo on || echo off)"
note "Apps preventing sleep"
pmset -g assertions 2>/dev/null | grep -E '^ +pid [0-9]+' | grep -E 'PreventUserIdle(System|Display)Sleep|PreventSystemSleep' | sed 's/^ *//' | head -n 10 | blk
note "Power management settings"
pmset -g 2>/dev/null | sed 1d | blk

# ============================================================================
#  6. NETWORK
# ============================================================================
sec "Network and connectivity"
DEF_ROUTE=$(route -n get default 2>/dev/null)
PRIMARY_IF=$(echo "$DEF_ROUTE" | awk '/interface:/{print $2}')
GATEWAY=$(echo "$DEF_ROUTE" | awk '/gateway:/{print $2}')
PRIMARY_IP=""; [ -n "$PRIMARY_IF" ] && PRIMARY_IP=$(ipconfig getifaddr "$PRIMARY_IF" 2>/dev/null)
DNS_SERVERS=$(scutil --dns 2>/dev/null | awk '/nameserver\[[0-9]+\]/{print $3}' | awk '!s[$0]++' | head -n 6 | tr '\n' ' ')
SEARCH_DOMAINS=$(scutil --dns 2>/dev/null | awk '/search domain\[[0-9]+\]/{print $4}' | awk '!s[$0]++' | head -n 4 | tr '\n' ' ')
PORTS=$(networksetup -listallhardwareports 2>/dev/null)
WIFI_DEV=$(echo "$PORTS" | awk '/Hardware Port: (Wi-Fi|AirPort)/{getline; print $2; exit}')
PRIMARY_PORT=$(echo "$PORTS" | awk -v d="$PRIMARY_IF" '/^Hardware Port:/{sub(/^Hardware Port: /,""); p=$0} /^Device:/ && $2==d {print p; exit}')
PROXY=$(scutil --proxy 2>/dev/null | awk '/(HTTP|HTTPS|SOCKS)Enable : 1|ProxyAutoConfigEnable : 1/{print $1}' | sed 's/Enable$//' | tr '\n' ' ')

kv "Primary connection" "${PRIMARY_PORT:-${PRIMARY_IF:-none}}${PRIMARY_IF:+ ($PRIMARY_IF)}"
kv "IP address" "$PRIMARY_IP"
kv "Default gateway" "$GATEWAY"
kv "DNS servers" "$DNS_SERVERS"
[ -n "$SEARCH_DOMAINS" ] && kv "Search domains" "$SEARCH_DOMAINS"
kv "Proxies enabled" "${PROXY:-none}"
note "Interfaces"
{
  printf '%-26s %-8s %-9s %-16s %-18s %s\n' PORT DEV STATUS IPv4 MAC MEDIA
  echo "$PORTS" | awk '/^Hardware Port:/{sub(/^Hardware Port: /,""); p=$0} /^Device:/{print p "|" $2}' | while IFS='|' read -r port dev; do
    IFC=$(ifconfig "$dev" 2>/dev/null)
    ip=$(ipconfig getifaddr "$dev" 2>/dev/null)
    st=$(echo "$IFC" | awk '/status:/{print $2}')
    mac=$(echo "$IFC" | awk '/ether /{print $2; exit}')
    media=$(echo "$IFC" | sed -n 's/.*media: *//p' | head -n 1)
    printf '%-26s %-8s %-9s %-16s %-18s %s\n' "$port" "$dev" "${st:--}" "${ip:--}" "${mac:--}" "${media:-}"
  done
} | blk

# Tunnels / VPN
UTUN=$(ifconfig 2>/dev/null | awk '/^[a-z0-9]+:/{i=$1; sub(":","",i)} /inet [0-9]/ && i ~ /^(utun|ipsec|ppp|tun|tap)/ {print i, $2}')
TS_BIN=""
for c in tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale; do have "$c" && { TS_BIN="$c"; break; }; done
[ -n "$UTUN" ] && { note "VPN / tunnel interfaces"; echo "$UTUN" | blk; }
if [ -n "$TS_BIN" ]; then
  note "Tailscale / Headscale"
  TS_OUT=$(tmo 10 "$TS_BIN" status 2>&1)
  TS_PEERS=$(echo "$TS_OUT" | awk 'NR>1 && $1 ~ /^100\./' | wc -l | tr -d ' ')
  TS_ACTIVE=$(echo "$TS_OUT" | awk 'NR>1 && $1 ~ /^100\./ && /active/' | wc -l | tr -d ' ')
  if echo "$TS_OUT" | head -n 1 | grep -q '^100\.'; then
    printf 'connected as %s; %s other devices on the network, %s active now\n' "$(echo "$TS_OUT" | head -n 1 | awk '{print $1}')" "$TS_PEERS" "$TS_ACTIVE" | blk
  else
    echo "$TS_OUT" | head -n 2 | blk
  fi
fi

# Connectivity tests (run before the speed test so they aren't skewed)
GW_OK=n/a; GW_RTT=""; NET_LOSS=""; NET_RTT=""; DNS_OK=no; HTTPS_OK=no
if [ -n "$GATEWAY" ]; then
  GWP=$(tmo 10 ping -c 3 -i 0.3 -t 4 "$GATEWAY" 2>/dev/null)
  GW_RX=$(echo "$GWP" | sed -n 's/.* \([0-9]*\) packets received.*/\1/p')
  if isnum "$GW_RX" && [ "$GW_RX" -gt 0 ]; then GW_OK=yes; else GW_OK=no; fi
  GW_RTT=$(echo "$GWP" | sed -n 's|.*= [0-9.]*/\([0-9.]*\)/.*|\1|p')
fi
NP=$(tmo 15 ping -c 10 -i 0.3 -t 8 1.1.1.1 2>/dev/null)
NET_LOSS=$(echo "$NP" | sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p')
NET_RTT=$(echo "$NP" | sed -n 's|.*= [0-9.]*/\([0-9.]*\)/.*|\1|p')
dscacheutil -q host -a name www.apple.com 2>/dev/null | grep -q 'ip_address' && DNS_OK=yes
CURL_T=$(curl -sS -o /dev/null -m 12 -w '%{http_code} %{time_namelookup} %{time_connect} %{time_total}' https://www.apple.com/library/test/success.html 2>/dev/null)
HTTP_CODE=$(echo "$CURL_T" | awk '{print $1}')
[ "$HTTP_CODE" = 200 ] && HTTPS_OK=yes
T_DNS=$(echo "$CURL_T" | awk '{printf "%.0f", $2*1000}'); T_TOT=$(echo "$CURL_T" | awk '{printf "%.0f", $4*1000}')
PUBLIC_IP=""; [ "$HTTPS_OK" = yes ] && PUBLIC_IP=$(curl -s -m 6 https://api.ipify.org 2>/dev/null | tr -dc '0-9a-fA-F.:')
CLOCK_OFF=$(tmo 10 sntp -t 3 time.apple.com 2>/dev/null | awk '/^[+-][0-9]/{print $1}' | tail -n 1)

kv "Gateway reachable" "$GW_OK${GW_RTT:+ (${GW_RTT} ms)}"
kv "Internet ping 1.1.1.1" "${NET_LOSS:-100}% loss${NET_RTT:+, ${NET_RTT} ms avg}"
kv "DNS resolution" "$DNS_OK${T_DNS:+ (${T_DNS} ms lookup)}"
kv "HTTPS to apple.com" "$HTTPS_OK${HTTP_CODE:+ (HTTP $HTTP_CODE, ${T_TOT} ms)}"
kv "Public IP" "$PUBLIC_IP"
kv "Clock offset vs time.apple.com" "${CLOCK_OFF:+$CLOCK_OFF s}"

# start speed test now that latency tests are done
[ "$QUICK" -eq 0 ] && [ "$HTTPS_OK" = yes ] && have networkQuality && bgrun netq 60 networkQuality -c

if [ -z "$PRIMARY_IF" ]; then
  chk FAIL "Network" "No network connection (no default route)" "Connect to Wi-Fi/Ethernet; check cable or Wi-Fi settings."
elif [ "$DNS_OK" = no ] && [ "$HTTPS_OK" = no ]; then
  chk FAIL "Network" "Connected via $PRIMARY_IF but no internet/DNS" "Check router/firewall; renew DHCP lease (System Settings > Network > Details > TCP/IP)."
elif [ "$HTTPS_OK" = no ]; then
  chk WARN "Network" "HTTPS test failing (proxy, firewall or captive portal?)" "Open a browser to check for a sign-in page; check proxy settings."
elif [ "$DNS_OK" = no ]; then
  chk WARN "Network" "DNS lookups failing" "Check DNS servers in network settings."
else
  chk OK "Network" "Online via ${PRIMARY_PORT:-$PRIMARY_IF} ($PRIMARY_IP)"
fi
if isnum "${NET_LOSS%%.*}" && [ "${NET_LOSS%%.*}" -gt "$PING_LOSS_WARN_PCT" ] && [ "${NET_LOSS%%.*}" -lt 100 ]; then
  chk WARN "Packet loss" "${NET_LOSS}% packet loss to internet" "Check Wi-Fi signal/cabling; test another network."
fi
isnum "${NET_RTT%%.*}" && [ "${NET_RTT%%.*}" -gt "$PING_RTT_WARN_MS" ] && chk WARN "Latency" "Internet latency ${NET_RTT} ms" "Check for congestion or a weak Wi-Fi link."
if [ -n "$CLOCK_OFF" ]; then
  ABS_OFF=$(echo "$CLOCK_OFF" | tr -d '+-')
  if fgt "$ABS_OFF" "$CLOCK_SKEW_WARN_S"; then
    chk WARN "Clock" "System clock off by ${CLOCK_OFF}s" "Turn on 'Set time and date automatically' in System Settings > General > Date & Time."
  else
    chk OK "Clock" "In sync (${CLOCK_OFF}s)"
  fi
fi
[ -n "$PROXY" ] && chk INFO "Proxy" "Proxy enabled: $PROXY"

# ============================================================================
#  7. WI-FI
# ============================================================================
sec "Wi-Fi"
WIFI_RSSI=""; WIFI_SUMMARY="n/a"
if [ -n "$WIFI_DEV" ]; then
  bgwait sp_wifi; AIR=$(bgout sp_wifi)
  WIFI_POWER=$(networksetup -getairportpower "$WIFI_DEV" 2>/dev/null | awk -F': ' '{print $2}')
  WIFI_INFO=$(echo "$AIR" | awk '
    /Current Network Information:/ {f=1; getline; gsub(/^[ \t]+|:$/,""); print "Network (SSID): " $0; next}
    f && /Other Local Wi-Fi Networks:/ {exit}
    f && /(PHY Mode|Channel|Country Code|Network Type|Security|Signal \/ Noise|Transmit Rate|MCS Index):/ {gsub(/^[ \t]+/,""); print}')
  WIFI_CARD=$(echo "$AIR" | grep -E 'Card Type:|Firmware Version:|Supported PHY Modes:' | trim | head -n 3)
  kv "Wi-Fi device" "$WIFI_DEV (power ${WIFI_POWER:-?})"
  if [ -n "$WIFI_INFO" ]; then
    echo "$WIFI_INFO" | while IFS= read -r line; do kv "${line%%:*}" "$(echo "${line#*:}" | trim)"; done
  else
    kv "Status" "not connected"
  fi
  [ -n "$WIFI_CARD" ] && { note "Wi-Fi hardware"; echo "$WIFI_CARD" | blk; }
  NEARBY=$(echo "$AIR" | awk '/Other Local Wi-Fi Networks:/{f=1;next} f && /^ {12}[^ ].*:$/{n++} END{print n+0}')
  kv "Nearby networks seen" "$NEARBY"
  WIFI_RSSI=$(echo "$WIFI_INFO" | sed -n 's/^Signal \/ Noise: *\(-[0-9]*\) dBm.*/\1/p' | head -n 1)
  WIFI_NOISE=$(echo "$WIFI_INFO" | sed -n 's|^Signal / Noise: *-[0-9]* dBm / *\(-[0-9]*\) dBm.*|\1|p' | head -n 1)
  WIFI_SUMMARY="${WIFI_RSSI:+$WIFI_RSSI dBm}"
  if isnum "$WIFI_RSSI"; then
    if [ "$WIFI_RSSI" -lt "$WIFI_RSSI_WARN" ]; then
      [ "$PRIMARY_IF" = "$WIFI_DEV" ] && S=WARN || S=INFO
      chk "$S" "Wi-Fi" "Weak signal (${WIFI_RSSI} dBm${WIFI_NOISE:+, noise $WIFI_NOISE})" "Move closer to the access point, use 5/6 GHz, or use Ethernet."
    else
      chk OK "Wi-Fi" "Signal ${WIFI_RSSI} dBm${WIFI_NOISE:+ (noise $WIFI_NOISE)}"
    fi
  fi
  echo "$WIFI_INFO" | grep -qiE 'Security: *(None|WEP|Open)' && chk WARN "Wi-Fi security" "Connected to an open/WEP network" "Use a WPA2/WPA3 network or a VPN."
else
  kv "Wi-Fi" "No Wi-Fi hardware"
fi

# ============================================================================
#  8. SECURITY
# ============================================================================
sec "Security"
FV=$(fdesetup status 2>/dev/null | head -n 1)
FV_PROGRESS=$(fdesetup status 2>/dev/null | sed -n '2,3p' | tr '\n' ' ')
SIP=$(csrutil status 2>/dev/null | head -n 1 | sed 's/^System Integrity Protection status: //')
AUTH_ROOT=$(csrutil authenticated-root status 2>/dev/null | sed 's/.*status: //')
GK=$(spctl --status 2>/dev/null)
FWBIN=/usr/libexec/ApplicationFirewall/socketfilterfw
FW_STATE=$($FWBIN --getglobalstate 2>/dev/null)
FW_STEALTH=$($FWBIN --getstealthmode 2>/dev/null)
FW_BLOCKALL=$($FWBIN --getblockall 2>/dev/null)
XP_PLIST=/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist
[ -f "$XP_PLIST" ] || XP_PLIST=/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist
XPROTECT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$XP_PLIST" 2>/dev/null)
XPR=$(appver /Library/Apple/System/Library/CoreServices/XProtect.app)
SU_PREF=/Library/Preferences/com.apple.SoftwareUpdate
supref() { local v; v=$(defaults read "$SU_PREF" "$1" 2>/dev/null); case "$v" in 1) echo on ;; 0) echo OFF ;; *) echo "on (default)" ;; esac; }
AUTO_CHECK=$(supref AutomaticCheckEnabled); AUTO_DL=$(supref AutomaticDownload)
AUTO_CFG=$(supref ConfigDataInstall); AUTO_CRIT=$(supref CriticalUpdateInstall)
AUTO_OS=$(defaults read /Library/Preferences/com.apple.commerce AutoUpdateRestartRequired 2>/dev/null)
ENROLL=$(tmo 15 profiles status -type enrollment 2>/dev/null)
MDM_ENROLLED=$(echo "$ENROLL" | awk -F': ' '/MDM enrollment/{print $2}')
DEP_ENROLLED=$(echo "$ENROLL" | awk -F': ' '/Enrolled via DEP/{print $2}')
MDM_SERVER=$(echo "$ENROLL" | awk -F': ' '/MDM server/{print $2}')
AUTOLOGIN=$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null)
GUEST=$(defaults read /Library/Preferences/com.apple.loginwindow GuestEnabled 2>/dev/null)
SCREENLOCK=$(tmo 10 sysadminctl -screenLock status 2>&1 | sed -n 's/.*\] *//p' | grep -i screenlock | tail -n 1)
FINDMY=off; nvram fmm-mobileme-token-FMM >/dev/null 2>&1 && FINDMY=on
LISTEN=$(netstat -anv -p tcp 2>/dev/null | awk '/LISTEN/{print $4}')
port_open() { echo "$LISTEN" | grep -qE "[.:]$1\$"; }
SSH_ON=no; port_open 22 && SSH_ON=yes
VNC_ON=no; port_open 5900 && VNC_ON=yes
SMB_ON=no; port_open 445 && SMB_ON=yes
ARD_ON=no; pgrep -q ARDAgent 2>/dev/null && pgrep -qf 'ARDAgent' && ARD_ON=yes
RAE_ON=no; port_open 3031 && RAE_ON=yes

kv "FileVault" "$FV${FV_PROGRESS:+ $FV_PROGRESS}"
kv "System Integrity Protection" "$SIP"
[ -n "$AUTH_ROOT" ] && kv "Authenticated root" "$AUTH_ROOT"
kv "Gatekeeper" "$GK"
kv "Firewall" "$FW_STATE"
kv "Firewall stealth mode" "$FW_STEALTH"
kv "Firewall block all" "$FW_BLOCKALL"
kv "XProtect definitions" "$XPROTECT"
[ -n "$XPR" ] && kv "XProtect Remediator" "$XPR"
kv "Auto check for updates" "$AUTO_CHECK"
kv "Auto download updates" "$AUTO_DL"
kv "Auto install security responses" "$AUTO_CFG"
kv "Auto install system data files" "$AUTO_CRIT"
kv "MDM enrolled" "${MDM_ENROLLED:-unknown}${MDM_SERVER:+ ($MDM_SERVER)}"
kv "Enrolled via Apple Business (DEP)" "${DEP_ENROLLED:-unknown}"
kv "Screen lock" "${SCREENLOCK:-unknown}"
kv "Automatic login" "${AUTOLOGIN:-off}"
kv "Guest account" "$( [ "$GUEST" = 1 ] && echo ON || echo off)"
kv "Find My Mac" "$FINDMY"
kv "Remote Login (SSH)" "$SSH_ON"
kv "Screen Sharing / VNC" "$VNC_ON"
kv "Remote Management (ARD)" "$ARD_ON"
kv "File Sharing (SMB)" "$SMB_ON"
kv "Remote Apple Events" "$RAE_ON"
note "Listening TCP ports"
echo "$LISTEN" | sed 's/.*[.:]//' | sort -n | uniq | tr '\n' ' ' | fold -s -w 70 | blk

case "$FV" in
  *"is On"*) chk OK "FileVault" "Disk encryption on" ;;
  *"is Off"*) chk WARN "FileVault" "Disk encryption is OFF" "Turn on FileVault in System Settings > Privacy & Security > FileVault; escrow the recovery key with IT." ;;
  *"progress"*|*"Encryption"*) chk INFO "FileVault" "$FV" ;;
  *) chk INFO "FileVault" "${FV:-status unreadable}" ;;
esac
case "$SIP" in enabled*) chk OK "SIP" "System Integrity Protection enabled" ;; "") chk INFO "SIP" "Status unreadable" ;; *) chk WARN "SIP" "SIP: $SIP" "Re-enable SIP from macOS Recovery: csrutil enable." ;; esac
case "$GK" in *enabled*) chk OK "Gatekeeper" "Enabled" ;; "") chk INFO "Gatekeeper" "Status unreadable" ;; *) chk WARN "Gatekeeper" "Gatekeeper disabled" "Run: sudo spctl --master-enable" ;; esac
case "$FW_STATE" in
  *enabled*|*"State = 1"*|*"State = 2"*) chk OK "Firewall" "Enabled" ;;
  "") chk INFO "Firewall" "Status unreadable" ;;
  *) chk WARN "Firewall" "Application firewall is OFF" "Turn on in System Settings > Network > Firewall." ;;
esac
[ "$AUTO_CFG" = OFF ] && chk WARN "Auto updates" "Automatic security responses disabled" "Enable in System Settings > General > Software Update > Automatic Updates."
[ "$AUTO_CRIT" = OFF ] && chk WARN "Auto updates" "Automatic XProtect/system data updates disabled" "Enable 'Install Security Responses and system files'."
[ "$AUTO_CHECK" = OFF ] && chk WARN "Auto updates" "Automatic update checks disabled" "Enable automatic update checks."
[ -n "$AUTOLOGIN" ] && chk WARN "Auto login" "Automatic login enabled for $AUTOLOGIN" "Turn off in System Settings > Users & Groups > Automatically log in."
[ "$GUEST" = 1 ] && chk WARN "Guest account" "Guest account enabled" "Turn off in System Settings > Users & Groups > Guest User."
case "$SCREENLOCK" in
  *off*|*disabled*) chk WARN "Screen lock" "No password required after sleep/screensaver" "System Settings > Lock Screen > Require password: Immediately." ;;
  *immediate*) chk OK "Screen lock" "Password required immediately" ;;
  *seconds*) SLD=$(echo "$SCREENLOCK" | grep -o '[0-9]*' | head -n 1)
             if isnum "$SLD" && [ "$SLD" -gt "$SCREENLOCK_MAX_S" ]; then chk WARN "Screen lock" "Password required after ${SLD}s" "Set Require password to 5 minutes or less."
             else chk OK "Screen lock" "Password required after ${SLD}s"; fi ;;
esac
[ "$SSH_ON" = yes ] && chk INFO "Remote access" "SSH (Remote Login) is on"
[ "$VNC_ON" = yes ] && chk INFO "Remote access" "Screen Sharing/VNC is on"
[ "$ARD_ON" = yes ] && chk INFO "Remote access" "Apple Remote Desktop agent running"
[ "$MDM_ENROLLED" = "No" ] && chk INFO "MDM" "Not enrolled in device management"

# ============================================================================
#  9. SECURITY & MANAGEMENT SOFTWARE
# ============================================================================
sec "Security, VPN and remote-access software"
APPDIRS=$(ls -1 /Applications /Applications/Utilities "$REAL_HOME/Applications" 2>/dev/null | grep '\.app$' | sort -u)
SECSW=$(echo "$APPDIRS" | grep -iE 'Falcon|SentinelOne|Defender|Sophos|Malwarebytes|Bitdefender|ESET|Norton|Avast|AVG|Intego|Trend Micro|Webroot|Kaspersky|Carbon Black|Cylance|Huntress|Little Snitch|LuLu|BlockBlock|Objective-See|Jamf|Self Service|Kandji|Mosyle|Addigy|Company Portal|Hexnode|Munki|Managed Software Center')
VPNSW=$(echo "$APPDIRS" | grep -iE 'Tailscale|WireGuard|OpenVPN|Tunnelblick|Viscosity|GlobalProtect|FortiClient|Cisco|AnyConnect|Secure Client|Pulse|Ivanti|NordVPN|ExpressVPN|ProtonVPN|Mullvad|Surfshark|Cloudflare WARP|ZeroTier|Twingate|Zscaler')
REMOTESW=$(echo "$APPDIRS" | grep -iE 'TeamViewer|AnyDesk|Splashtop|ScreenConnect|ConnectWise|LogMeIn|GoTo|RustDesk|Chrome Remote Desktop|Jump Desktop|Parsec|RealVNC|VNC Viewer|VNC Server|Remote Desktop|NoMachine|BeyondTrust|Bomgar|Zoho Assist|Remote Utilities')
[ -x /usr/local/jamf/bin/jamf ] && SECSW="$SECSW"$'\n'"jamf binary (/usr/local/jamf/bin/jamf)"
[ -d /Library/Application\ Support/CrowdStrike ] && SECSW="$SECSW"$'\n'"CrowdStrike support files"
note "Security / endpoint management"
echo "$SECSW" | awk 'NF' | blk
note "VPN clients"
echo "$VPNSW" | awk 'NF' | blk
note "Remote-access tools"
echo "$REMOTESW" | awk 'NF' | blk
RC=$(echo "$REMOTESW" | awk 'NF' | wc -l | tr -d ' ')
[ "$RC" -gt 0 ] && chk INFO "Remote tools" "$RC remote-access app(s): $(echo "$REMOTESW" | awk 'NF' | sed 's/\.app$//' | head -n 3 | tr '\n' ',' | sed 's/,$//; s/,/, /g')" "Confirm each is approved by QED IT; remove any that aren't."
note "System extensions"
tmo 15 systemextensionsctl list 2>/dev/null | grep -E '\[activated|enabled' | sed 's/^[[:space:]]*//' | head -n 20 | blk
note "Configuration profiles (user)"
tmo 15 profiles list 2>/dev/null | grep -i 'attribute: name\|profileIdentifier' | trim | head -n 20 | blk

# ============================================================================
# 10. USERS
# ============================================================================
sec "Users and accounts"
ADMINS=$(dscl . -read /Groups/admin GroupMembership 2>/dev/null | sed 's/GroupMembership: //')
note "Local accounts"
{
  printf '%-18s %-6s %-6s %-14s %s\n' USER UID ADMIN SECURE-TOKEN HOME
  dscl . -list /Users UniqueID 2>/dev/null | awk '$2>=500 && $1 !~ /^_/{print $1, $2}' | while read -r u uid; do
    a=no; echo " $ADMINS " | grep -q " $u " && a=yes
    st=$(tmo 5 sysadminctl -secureTokenStatus "$u" 2>&1 | grep -o 'ENABLED\|DISABLED' | head -n 1)
    hm=$(dscl . -read "/Users/$u" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
    printf '%-18s %-6s %-6s %-14s %s\n' "$u" "$uid" "$a" "${st:-?}" "$hm"
  done
} | blk
ADMIN_N=$(echo "$ADMINS" | tr ' ' '\n' | grep -v '^root$' | awk 'NF' | wc -l | tr -d ' ')
kv "Admin accounts (excluding root)" "$ADMIN_N: $ADMINS"
note "Recent logins"
last 2>/dev/null | head -n 40 | grep -vE '^(reboot|shutdown|wtmp)|^$' | head -n 10 | blk
[ "$ADMIN_N" -gt 3 ] && chk INFO "Admins" "$ADMIN_N admin accounts on this Mac" "Review whether every admin account is still needed."

# ============================================================================
# 11. SOFTWARE UPDATES
# ============================================================================
sec "Software updates"
if [ "$QUICK" -eq 0 ]; then
  bgwait swupdate; SU=$(bgout swupdate)
  if echo "$SU" | grep -qi "No new software available"; then
    kv "Pending updates" "none - up to date"
    chk OK "Updates" "macOS is up to date"
  else
    SU_LIST=$(echo "$SU" | sed -n 's/^[[:space:]]*\* Label: //p')
    [ -n "$SU_LIST" ] || SU_LIST=$(echo "$SU" | sed -n 's/^[[:space:]]*\* //p')
    if [ -n "$SU_LIST" ]; then
      SU_N=$(echo "$SU_LIST" | grep -c .)
      kv "Pending updates" "$SU_N"
      echo "$SU" | grep -E '^\s*(\* Label|Title):' | sed 's/^[[:space:]]*//' | blk
      OS_MAJOR=${OS_VER%%.*}
      SU_TITLES=$(echo "$SU" | sed -n 's/^[[:space:]]*Title: \([^,]*\), Version: \([^,]*\),.*/\1|\2/p')
      SU_SAME=$(echo "$SU_TITLES" | awk -F'|' -v m="$OS_MAJOR" '$1 ~ /^macOS/ { split($2,v,"."); if (v[1]==m) print $1 }' | tail -n 1)
      SU_MAJOR=$(echo "$SU_TITLES" | awk -F'|' -v m="$OS_MAJOR" '$1 ~ /^macOS/ { split($2,v,"."); if (v[1]!=m) print $1 }' | tail -n 1)
      SU_OTHER=$(echo "$SU_TITLES" | awk -F'|' '$1 !~ /^macOS/' | grep -c .)
      if [ -n "$SU_SAME" ]; then
        S=WARN; MSG="$SU_SAME available (this Mac has $OS_VER), restart needed"
      elif [ "$SU_OTHER" -gt 0 ]; then
        S=INFO; MSG="$SU_OTHER app/tool update(s) pending"
      else
        S=INFO; MSG="$SU_N update(s) pending"
      fi
      [ -n "$SU_SAME" ] && [ "$SU_OTHER" -gt 0 ] && MSG="$MSG; plus $SU_OTHER app/tool update(s)"
      [ -n "$SU_MAJOR" ] && MSG="$MSG; upgrade to $SU_MAJOR also offered"
      chk "$S" "Updates" "$MSG" "Install via System Settings > General > Software Update. Security updates first; check with IT before a major upgrade."
    else
      kv "Pending updates" "could not check"
      echo "$SU" | tail -n 4 | blk
      chk INFO "Updates" "Software Update check failed or timed out" "Run Software Update manually."
    fi
  fi
else
  kv "Pending updates" "skipped (--quick)"
fi
note "Recently installed updates"
tmo 30 softwareupdate --history 2>/dev/null | head -n 15 | blk

# ============================================================================
# 12. APPLICATIONS
# ============================================================================
sec "Applications"
APP_COUNT=$(echo "$APPDIRS" | awk 'NF' | wc -l | tr -d ' ')
kv "Apps in /Applications" "$APP_COUNT"
note "Key app versions"
{
  for a in "Safari" "Google Chrome" "Firefox" "Microsoft Edge" "Brave Browser" "Arc" \
           "Microsoft Word" "Microsoft Excel" "Microsoft Outlook" "Microsoft Teams" "zoom.us" "Slack" \
           "1Password" "Callisto Desk" "Tailscale" "Xcode"; do
    v=$(appver "/Applications/$a.app"); [ -n "$v" ] || v=$(appver "$REAL_HOME/Applications/$a.app")
    [ -n "$v" ] && printf '%-22s %s\n' "$a" "$v"
  done
  CLT=$(xcode-select -p 2>/dev/null); [ -n "$CLT" ] && printf '%-22s %s\n' "Developer tools" "$CLT"
  if have brew; then printf '%-22s %s\n' "Homebrew" "$(brew --version 2>/dev/null | head -n 1)"; fi
} | blk
if [ "$QUICK" -eq 0 ] && [ "$APPLE_SILICON" -eq 1 ]; then
  bgwait apps; APPS=$(bgout apps)
  INTEL_APPS=$(echo "$APPS" | awk '
    /^    [^ ].*:$/ {name=$0; sub(/^ +/,"",name); sub(/:$/,"",name); kind=""; loc=""}
    /^      Kind: / {kind=$0; sub(/^ +Kind: /,"",kind)}
    /^      Location: / {loc=$0; sub(/^ +Location: /,"",loc); if (kind=="Intel" && loc !~ /^\/(System|Library\/Apple)/ && (loc !~ /^\/Users\// || loc ~ /^\/Users\/[^\/]+\/Applications\//)) print name " (" loc ")"}' | awk '!s[$0]++')
  UNKNOWN_SRC=$(echo "$APPS" | grep -c 'Obtained from: Unknown')
  INTEL_N=$(echo "$INTEL_APPS" | awk 'NF' | wc -l | tr -d ' ')
  kv "Intel-only apps (need Rosetta)" "$INTEL_N"
  kv "Apps from unidentified developers" "$UNKNOWN_SRC"
  [ "$INTEL_N" -gt 0 ] && { note "Intel-only apps"; echo "$INTEL_APPS" | head -n 30 | blk; }
  [ "$INTEL_N" -gt 0 ] && chk INFO "Intel apps" "$INTEL_N Intel-only app(s) installed (need Rosetta)" "Update to Apple silicon/Universal versions; Rosetta support is being phased out."
fi
if [ "$QUICK" -eq 0 ] && [ -n "${BGPID_brew:-}" ]; then
  bgwait brew; BREW_OUT=$(bgout brew | awk 'NF' | grep -v '^Warning\|^Error')
  BREW_N=$(echo "$BREW_OUT" | awk 'NF' | wc -l | tr -d ' ')
  kv "Outdated Homebrew packages" "$BREW_N"
  [ "$BREW_N" -gt 0 ] && echo "$BREW_OUT" | head -n 25 | tr '\n' ' ' | fold -s -w 70 | blk
fi

# ============================================================================
# 13. STABILITY
# ============================================================================
sec "Stability and crashes"
DR_SYS=/Library/Logs/DiagnosticReports; DR_USR="$REAL_HOME/Library/Logs/DiagnosticReports"
PANICS30=$(find "$DR_SYS" -maxdepth 2 -iname '*panic*' -mtime -30 2>/dev/null | wc -l | tr -d ' ')
PANICS7=$(find "$DR_SYS" -maxdepth 2 -iname '*panic*' -mtime -7 2>/dev/null | wc -l | tr -d ' ')
CRASH_FILES=$(find "$DR_USR" "$DR_SYS" -maxdepth 1 \( -name '*.ips' -o -name '*.crash' -o -name '*.hang' -o -name '*.spin' \) -mtime -7 2>/dev/null | grep -viE 'panic|Jetsam|\.diag|Sleep|Wake|ExcResource|cpu_resource|disk_writes|wakeups')
CRASHES7=$(echo "$CRASH_FILES" | awk 'NF' | wc -l | tr -d ' ')
JETSAM7=$(find "$DR_SYS" "$DR_USR" -maxdepth 1 -iname 'JetsamEvent*' -mtime -7 2>/dev/null | wc -l | tr -d ' ')
SLEEPFAIL7=$(find "$DR_SYS" -maxdepth 1 \( -iname '*Sleep*Wake*' -o -iname '*SleepWakeFailure*' \) -mtime -7 2>/dev/null | wc -l | tr -d ' ')

kv "Kernel panics (7 days / 30 days)" "$PANICS7 / $PANICS30"
kv "App crashes/hangs (7 days)" "$CRASHES7"
kv "Out-of-memory events (7 days)" "$JETSAM7"
kv "Sleep/wake failures (7 days)" "$SLEEPFAIL7"
if [ "$CRASHES7" -gt 0 ]; then
  note "Most frequent crashing apps (7 days)"
  echo "$CRASH_FILES" | awk 'NF' | sed 's|.*/||; s/[-_][0-9]\{4\}-[0-9][0-9]-[0-9][0-9].*//; s/\.\(ips\|crash\|hang\|spin\)$//' | sort | uniq -c | sort -rn | head -n 10 | blk
fi
if [ "$PANICS30" -gt 0 ]; then
  note "Recent panic reports"
  find "$DR_SYS" -maxdepth 2 -iname '*panic*' -mtime -30 2>/dev/null | head -n 5 | blk
  LASTPANIC=$(find "$DR_SYS" -maxdepth 2 -iname '*panic*' -mtime -30 2>/dev/null | head -n 1)
  [ -n "$LASTPANIC" ] && { note "Latest panic (first lines)"; grep -m 6 -oE 'panic\(cpu[^"]{0,200}|"panicString" *: *"[^"]{0,200}' "$LASTPANIC" 2>/dev/null | blk; }
fi

SHUTDOWN_CAUSE=""
if [ "$QUICK" -eq 0 ]; then
  bgwait shutdown; SHUTDOWN_CAUSE=$(bgout shutdown | sed -n 's/.*Previous shutdown cause: *\(-\{0,1\}[0-9]*\).*/\1/p' | tail -n 1)
fi
case "$SHUTDOWN_CAUSE" in
  5) SD_TXT="5 (normal shutdown/restart)" ;;
  3) SD_TXT="3 (hard shutdown - power button held)" ;;
  0) SD_TXT="0 (power loss / power disconnected)" ;;
  -3) SD_TXT="-3 (multiple temperature sensors exceeded limit)" ;;
  -60) SD_TXT="-60 (bad master directory block / disk)" ;;
  -62|-61|-71|-74|-75|-78|-79|-86|-95|-100|-102|-103|-104|-112|-127|-128) SD_TXT="$SHUTDOWN_CAUSE (abnormal: hardware, thermal, power or watchdog)" ;;
  "") SD_TXT="" ;;
  *) SD_TXT="$SHUTDOWN_CAUSE (non-standard)" ;;
esac
kv "Previous shutdown cause" "${SD_TXT:-$( [ "$QUICK" -eq 1 ] && echo 'skipped (--quick)' || echo 'not found in log')}"

FAILED_JOBS=$(launchctl list 2>/dev/null | awk 'NR>1 && $1=="-" && $2!="0" && $2!="-" {print $3 " (exit " $2 ")"}' | grep -v '^com\.apple\.')
FAILED_N=$(echo "$FAILED_JOBS" | awk 'NF' | wc -l | tr -d ' ')
kv "Failing third-party login jobs" "$FAILED_N"
[ "$FAILED_N" -gt 0 ] && echo "$FAILED_JOBS" | head -n 10 | blk
note "Last reboots/shutdowns"
last reboot shutdown 2>/dev/null | grep -E '^(reboot|shutdown)' | head -n 8 | blk

if [ "$PANICS7" -gt 0 ]; then chk FAIL "Stability" "$PANICS7 kernel panic(s) in last 7 days" "Update macOS, remove third-party kernel extensions, then run Apple Diagnostics."
elif [ "$PANICS30" -gt 0 ]; then chk WARN "Stability" "$PANICS30 kernel panic(s) in last 30 days" "Watch for repeats; update macOS and run Apple Diagnostics."
else chk OK "Stability" "No kernel panics in 30 days"; fi
CRASH_TOP=$(echo "$CRASH_FILES" | awk 'NF' | sed 's|.*/||; s/[-_][0-9]\{4\}-[0-9][0-9]-[0-9][0-9].*//; s/\.\(ips\|crash\|hang\|spin\)$//' | sort | uniq -c | sort -rn | head -n 1 | awk '{c=$1; $1=""; sub(/^ /,""); print c "|" $0}')
CRASH_TOP_N=${CRASH_TOP%%|*}; CRASH_TOP_APP=${CRASH_TOP#*|}
if [ "$CRASHES7" -ge 10 ]; then
  if isnum "$CRASH_TOP_N" && [ $((CRASH_TOP_N * 100)) -ge $((CRASHES7 * 60)) ]; then
    chk WARN "App crashes" "$CRASHES7 crash/hang reports in 7 days, $CRASH_TOP_N from $CRASH_TOP_APP" "Mostly one program: update, reinstall or stop $CRASH_TOP_APP. One program crashing repeatedly does not mean the Mac is unstable."
  else
    chk WARN "App crashes" "$CRASHES7 crash/hang reports in 7 days" "Update or reinstall the top crashing apps listed in the report."
  fi
fi
[ "$JETSAM7" -ge 3 ] && chk WARN "Out of memory" "$JETSAM7 out-of-memory events in 7 days" "Workload exceeds RAM; reduce open apps or upgrade."
[ "$SLEEPFAIL7" -ge 2 ] && chk WARN "Sleep/wake" "$SLEEPFAIL7 sleep/wake failures in 7 days" "Disconnect USB hubs/docks to test; reset SMC (Intel) or update macOS."
case "$SHUTDOWN_CAUSE" in ""|5) ;; *) chk WARN "Last shutdown" "Abnormal: $SD_TXT" "If repeated, check power/battery/thermals and run Apple Diagnostics." ;; esac
[ "$FAILED_N" -ge 5 ] && chk INFO "Login jobs" "$FAILED_N third-party background jobs failing" "Remove leftovers of uninstalled apps from ~/Library/LaunchAgents and /Library/Launch*."

# ============================================================================
# 14. BACKUP
# ============================================================================
sec "Backup (Time Machine)"
TM_DEST=$(tmo 20 tmutil destinationinfo 2>/dev/null)
TM_SUMMARY="not configured"
if echo "$TM_DEST" | grep -q '^Name'; then
  echo "$TM_DEST" | grep -E '^(Name|Kind|Mount Point|ID)' | blk
  TM_STATUS=$(tmo 10 tmutil status 2>/dev/null | awk -F' = ' '/Running/{gsub(/;/,"",$2); print ($2==1?"backup in progress":"idle")}')
  kv "Status" "$TM_STATUS"
  TM_LATEST=$(tmo 30 tmutil latestbackup 2>/dev/null | tail -n 1)
  TM_DATE=$(echo "$TM_LATEST" | grep -o '[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]-[0-9]\{6\}' | tail -n 1)
  if [ -n "$TM_DATE" ]; then
    TM_TS=$(date -j -f '%Y-%m-%d-%H%M%S' "$TM_DATE" +%s 2>/dev/null)
    TM_AGE=$(( (NOW_TS - ${TM_TS:-$NOW_TS}) / 86400 ))
    kv "Latest backup" "$TM_DATE ($TM_AGE days ago)"
    TM_SUMMARY="$TM_AGE days ago"
    if [ "$TM_AGE" -gt "$BACKUP_WARN_DAYS" ]; then chk WARN "Backup" "Last Time Machine backup $TM_AGE days ago" "Connect the backup drive / check NAS and run Back Up Now."
    else chk OK "Backup" "Time Machine backed up $TM_AGE day(s) ago"; fi
  else
    kv "Latest backup" "unreadable (destination offline, or Terminal lacks Full Disk Access)"
    TM_SUMMARY="configured"
    chk INFO "Backup" "Time Machine configured; latest backup date unreadable" "Check in System Settings > General > Time Machine."
  fi
else
  kv "Time Machine" "not configured"
  chk INFO "Backup" "Time Machine not configured" "Confirm this Mac is covered by another backup (NAS/cloud)."
fi
kv "Local snapshots" "$SNAPS"

# ============================================================================
# 15. STARTUP ITEMS AND EXTENSIONS
# ============================================================================
sec "Startup items and extensions"
for dir in /Library/LaunchDaemons /Library/LaunchAgents "$REAL_HOME/Library/LaunchAgents"; do
  n=$(ls -1 "$dir" 2>/dev/null | grep -c '\.plist$')
  note "$dir ($n)"
  ls -1 "$dir" 2>/dev/null | grep '\.plist$' | head -n 40 | blk
done
note "Third-party kernel extensions loaded"
if have kmutil; then KX=$(tmo 30 kmutil showloaded --list-only 2>/dev/null | grep -v 'com\.apple\.' | grep -v '^No variant' | awk 'NF')
else KX=$(kextstat -l 2>/dev/null | grep -v 'com\.apple\.'); fi
echo "$KX" | head -n 20 | blk
KX_N=$(echo "$KX" | awk 'NF' | wc -l | tr -d ' ')
[ "$KX_N" -gt 0 ] && chk INFO "Kernel exts" "$KX_N third-party kernel extension(s) loaded" "Legacy kexts are a common cause of panics; replace with system-extension versions where possible."
note "Background/login items (user LaunchAgents listed above; full list: System Settings > General > Login Items)"

# ============================================================================
# 16. HARDWARE AND PERIPHERALS
# ============================================================================
sec "Hardware, ports and peripherals"
INV_JSON=""; INV_FACTS=""; INV_OUT=""
[ -n "${BGPID_sphw:-}" ] && wait "$BGPID_sphw" 2>/dev/null
if have osascript && [ -s "$WORK/sp_hw.json" ]; then
  ioreg -rd1 -c IOPlatformExpertDevice >"$WORK/ioreg_pe.txt" 2>/dev/null
  inventory_js >"$WORK/inventory.js"
  INV_OUT=$(tmo 30 osascript -l JavaScript "$WORK/inventory.js" "$WORK/sp_hw.json" "$WORK/ioreg_pe.txt" "$(sysctl -n hw.target 2>/dev/null)" 2>/dev/null)
  case "$INV_OUT" in "["*) INV_JSON=$(printf '%s\n' "$INV_OUT" | head -n 1) ;; esac
fi
if [ -n "$INV_JSON" ]; then
  INV_FACTS=$(printf '%s\n' "$INV_OUT" | sed -n '/^@@FACTS$/,$p' | sed '1d')
  GRP=""; BUF=""
  while IFS= read -r line; do
    case "$line" in
      @@*) ;;
      @*) [ -n "$GRP" ] && { note "$GRP"; printf '%s\n' "$BUF" | blk; }; GRP="${line#@}"; BUF="" ;;
      *) BUF="${BUF}${BUF:+$'\n'}$line" ;;
    esac
  done <<EOF_INV
$(printf '%s\n' "$INV_OUT" | sed -n '/^@@TEXT$/,/^@@FACTS$/p')
EOF_INV
  [ -n "$GRP" ] && { note "$GRP"; printf '%s\n' "$BUF" | blk; }
  ivf() { printf '%s\n' "$INV_FACTS" | awk -v k="$1" '$1==k{print $2}'; }
  chk OK "Hardware" "$(ivf hw.components) components: $(ivf hw.ports_thunderbolt) Thunderbolt/USB-C ports, $(ivf hw.devices_connected) devices connected, $(ivf hw.displays_external) external display(s)"
else
  chk INFO "Hardware" "Hardware inventory unreadable"
  note "Graphics and displays"
  bgwait sp_disp; bgout sp_disp | grep -E 'Chipset Model|Type:|Bus:|VRAM|Total Number of Cores|Metal|Vendor|Resolution|Display Type|Main Display|Mirror|Online|Connection Type|UI Looks like|^ {8}[A-Za-z0-9].*:$' | trim | head -n 40 | blk
  note "USB devices"
  bgwait sp_usb; bgout sp_usb | grep -E '^ +[^ ].*:$' | sed 's/:$//' | trim | grep -viE '^(USB( [0-9.]+)?( Bus)?|USB[0-9]*Bus|Host Controller.*)$' | awk '!s[$0]++' | head -n 30 | blk
  note "Thunderbolt / USB4"
  bgwait sp_tb; bgout sp_tb | grep -E 'Device Name|Vendor Name|Status|Link Status|Speed|Firmware Version' | trim | head -n 24 | blk
  bgwait sp_bt; BT=$(bgout sp_bt)
  note "Bluetooth"
  {
    echo "State: $(echo "$BT" | field "State")"
    echo "Chipset: $(echo "$BT" | field "Chipset")"
    echo "Connected devices:"
    echo "$BT" | awk '/^ +Connected:$/{f=1;next} /^ +Not Connected:$/{f=0} f && /^ {10}[^ ].*:$/{n=$0; sub(/^ +/,"",n); sub(/:$/,"",n); print "  " n} f && /Battery Level/ {b=$0; sub(/^ +/,"",b); print "      " b}' | head -n 30
  } | blk
  note "Cameras"
  bgwait sp_cam; bgout sp_cam | grep -E '^ {4}[^ ].*:$' | sed 's/:$//' | trim | blk
  note "Audio devices"
  bgwait sp_audio; bgout sp_audio | grep -E '^ {8}[^ ].*:$' | sed 's/:$//' | trim | head -n 15 | blk
fi
note "Printers"
lpstat -p 2>/dev/null | head -n 10 | blk

# ============================================================================
# 17. INTERNET SPEED
# ============================================================================
sec "Internet speed"
if [ -n "${BGPID_netq:-}" ]; then
  bgwait netq; NQ=$(bgout netq)
  jnum() { echo "$NQ" | grep -o "\"$1\" *: *[0-9.]*" | head -n 1 | sed 's/.*: *//'; }
  DL=$(jnum dl_throughput); UL=$(jnum ul_throughput); RPM=$(jnum responsiveness); [ -n "$RPM" ] || RPM=$(jnum dl_responsiveness)
  BRTT=$(jnum base_rtt)
  DL_M=""; UL_M=""
  [ -n "$DL" ] && DL_M=$(awk -v b="$DL" 'BEGIN{printf "%.1f", b/1000000}')
  [ -n "$UL" ] && UL_M=$(awk -v b="$UL" 'BEGIN{printf "%.1f", b/1000000}')
  if [ -z "$DL_M" ]; then
    DL_M=$(echo "$NQ" | sed -n 's/.*[Dd]ownlink capacity: *\([0-9.]*\) Mbps.*/\1/p' | head -n 1)
    UL_M=$(echo "$NQ" | sed -n 's/.*[Uu]plink capacity: *\([0-9.]*\) Mbps.*/\1/p' | head -n 1)
  fi
  kv "Download" "${DL_M:+$DL_M Mbps}"
  kv "Upload" "${UL_M:+$UL_M Mbps}"
  kv "Responsiveness" "${RPM:+$(printf '%.0f' "$RPM") RPM}"
  kv "Idle latency" "${BRTT:+$(printf '%.0f' "$BRTT") ms}"
  SPEED_SUMMARY="${DL_M:-?} down / ${UL_M:-?} up Mbps"
  if [ -n "$DL_M" ]; then
    if flt "$DL_M" "$SPEED_DL_WARN_MBPS"; then chk WARN "Speed" "Download only $DL_M Mbps" "Test on Ethernet; check Wi-Fi signal and ISP/router."
    else chk OK "Speed" "$DL_M Mbps down / ${UL_M:-?} Mbps up"; fi
  else
    kv "Result" "speed test did not complete"
  fi
else
  kv "Speed test" "$( [ "$QUICK" -eq 1 ] && echo 'skipped (--quick)' || echo 'skipped (offline or networkQuality unavailable)')"
  SPEED_SUMMARY="n/a"
fi

# ============================================================================
#  COMPOSE REPORTS (TXT + HTML + JSON)
# ============================================================================
END_TS=$(date +%s); ELAPSED=$((END_TS - START_TS))
case "$WORST" in 0) OVERALL="HEALTHY" ;; 1) OVERALL="ATTENTION NEEDED" ;; *) OVERALL="PROBLEMS FOUND" ;; esac
SCORE=$((100 - NFAIL * 15 - NWARN * 5)); [ "$SCORE" -lt 0 ] && SCORE=0
TAKEN=$(date '+%Y-%m-%d %H:%M:%S %Z'); TAKEN_ISO=$(date '+%Y-%m-%dT%H:%M:%S%z')

SAFE_HOST=$(printf '%s' "$COMPUTER_NAME" | tr -c 'A-Za-z0-9._-' '-' | sed 's/--*/-/g; s/-*$//; s/^-*//')
[ -n "$SAFE_HOST" ] || SAFE_HOST=mac
STAMP=$(date '+%Y-%m-%d_%H%M%S')
mkdir -p "$OUTDIR" 2>/dev/null
if ! ( : >"$OUTDIR/.w" ) 2>/dev/null; then OUTDIR="${TMPDIR:-/tmp}/QED-Mac-Health"; mkdir -p "$OUTDIR"; fi
rm -f "$OUTDIR/.w"
BASE="$OUTDIR/QED-Mac-Health_${SAFE_HOST}_${STAMP}"
[ "$RAWHW" -eq 1 ] && [ -s "$WORK/sp_hw.json" ] && cp "$WORK/sp_hw.json" "$BASE.hardware-raw.json" 2>/dev/null
TXT="$BASE.txt"; HTML="$BASE.html"; JSON="$BASE.json"

# order checks: FAIL, WARN, INFO, OK
ORDER=()
for s in FAIL WARN UNKNOWN INFO OK; do
  for ((i = 0; i < ${#CK_S[@]}; i++)); do [ "${CK_S[$i]}" = "$s" ] && ORDER+=("$i"); done
done

# ---- TXT ---------------------------------------------------------------------------
{
  echo "QED MAC HEALTH SNAPSHOT  v$VERSION"
  echo "=========================================================================="
  echo "  Computer : $COMPUTER_NAME  ($MODEL_NAME, serial $SERIAL)"
  echo "  macOS    : $OS_VER ($OS_BUILD)   Chip: $CHIP   RAM: ${MEM_GB} GB"
  echo "  Taken    : $TAKEN   Mode: $( [ "$QUICK" -eq 1 ] && echo quick || echo full )   Took: ${ELAPSED}s"
  echo
  echo "  OVERALL  : $OVERALL   Score $SCORE/100   ($NFAIL fail, $NWARN warn, $NUNK unknown, $NINFO info, $NOK ok)"
  echo
  echo "== HEALTH SUMMARY ========================================================"
  for i in "${ORDER[@]}"; do printf '  [%-7s] %-16s %s\n' "${CK_S[$i]}" "${CK_A[$i]}" "${CK_M[$i]}"; done
  if [ $((NFAIL + NWARN)) -gt 0 ]; then
    echo
    echo "== WHAT TO DO ============================================================"
    for i in "${ORDER[@]}"; do
      case "${CK_S[$i]}" in FAIL|WARN) [ -n "${CK_F[$i]}" ] && printf '  - %s: %s\n' "${CK_A[$i]}" "${CK_F[$i]}" ;; esac
    done
  fi
  for ((n = 1; n <= SEC_N; n++)); do
    echo
    t="${SEC_T[$n]}"
    printf '== %s ' "$(echo "$t" | tr '[:lower:]' '[:upper:]')"; printf '%*s\n' $((70 - ${#t})) '' | tr ' ' '='
    cat "$WORK/s$n.txt"
  done
  echo
  echo "=========================================================================="
  echo "Read-only report - nothing on this Mac was changed."
  echo "Hardware fault suspected? Run Apple Diagnostics: shut down, then"
  echo "  Apple silicon: hold power until 'Loading startup options', press Cmd-D"
  echo "  Intel: power on and immediately hold D"
  echo "SUMMARY|$COMPUTER_NAME|$SERIAL|$MODEL_ID|$OS_VER|$OVERALL|score=$SCORE|fail=$NFAIL|warn=$NWARN|$TAKEN_ISO"
} >"$TXT"

# ---- JSON (qed.device-health/v1) ------------------------------------------------------
# Numbers go through jn: anything not a clean number becomes null, never 0.
jn() { case "${1:-}" in ''|*[!0-9.-]*|-|.|*.*.*) printf 'null' ;; *) printf '%s' "$1" ;; esac; }
js() { if [ -n "${1:-}" ]; then printf '"%s"' "$(j "$1")"; else printf 'null'; fi; }
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

V_FREE_PCT=""; V_FREE_GB=""; V_TOT_GB=""
if isnum "${D_TOT:-}" && [ "${D_TOT:-0}" -gt 0 ]; then V_FREE_PCT=$D_FREE_PCT; V_FREE_GB=$D_FREE_GB; V_TOT_GB=$D_TOT_GB; fi
V_RAM=""; [ "${MEM_GB:-0}" -gt 0 ] 2>/dev/null && V_RAM=$MEM_GB
V_UP=""; isnum "${BOOT_TS:-}" && [ "${BOOT_TS:-0}" -gt 0 ] && V_UP=$UP_D
V_TM=""; [ -n "${TM_TS:-}" ] && V_TM=${TM_AGE:-}
JOVERALL=ok; case "$WORST" in 1) JOVERALL=warn ;; 2) JOVERALL=fail ;; esac
[ $((NOK + NINFO + NWARN + NFAIL)) -eq 0 ] && [ "$NUNK" -gt 0 ] && JOVERALL=unknown
RUN_ID=$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')
[ -n "$RUN_ID" ] || RUN_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
ELEVATED=false; [ "$(id -u)" = 0 ] && ELEVATED=true

# fact KEY VALUE -> emits ,"key": number   (skipped when not numeric)
FACTS=""
fact() { local v; v=$(jn "$2"); [ "$v" = null ] && return 0; FACTS="${FACTS}${FACTS:+,}
    \"$1\": $v"; }
fact storage.free_pct "$V_FREE_PCT"; fact storage.free_gb "$V_FREE_GB"; fact storage.total_gb "$V_TOT_GB"
fact sys.uptime_days "$V_UP"; fact mem.ram_gb "$V_RAM"
fact battery.max_capacity_pct "${MAXCAP:-}"; fact battery.cycles "${CYCLES:-}"
fact net.download_mbps "${DL_M:-}"; fact net.upload_mbps "${UL_M:-}"; fact net.rtt_ms "${NET_RTT:-}"; fact net.loss_pct "${NET_LOSS:-}"
fact net.wifi_rssi_dbm "${WIFI_RSSI:-}"; fact stability.crashes_7d "${CRASHES7:-}"; fact stability.panics_30d "${PANICS30:-}"
fact backup.age_days "$V_TM"
fact mem.swap_used_gb "$(awk -v m="${SWAP_USED_MB:-}" 'BEGIN{if (m != "") printf "%.1f", m/1024}')"
if [ -n "$INV_FACTS" ]; then
  while read -r fk fv; do [ -n "$fk" ] && fact "$fk" "$fv"; done <<EOF_IF
$INV_FACTS
EOF_IF
fi

write_json() {  # $1 = consent json or empty
{
  printf '{\n  "schema": "qed.device-health/v1",\n'
  printf '  "collector": {"name": "qed-mac-health", "version": "%s", "channel": "mac-script", "os": "macos", "mode": "%s", "elevated": %s},\n' \
    "$VERSION" "$( [ "$QUICK" -eq 1 ] && echo quick || echo full )" "$ELEVATED"
  printf '  "run": {"client_run_id": %s, "started": "%s", "duration_s": %d' "$(js "$RUN_ID")" "$START_ISO" "$ELAPSED"
  [ -n "$CODE" ] && printf ', "session_code": "%s"' "$CODE"
  [ -n "$1" ] && printf ', "consent": %s' "$1"
  printf '},\n'
  printf '  "device": {\n    "fingerprint": {"serial": %s, "hw_uuid": %s, "os_install_id": null, "primary_mac": %s},\n' \
    "$(js "$SERIAL")" "$(js "$HW_UUID")" "$(js "$PRIMARY_MAC")"
  printf '    "hostname": %s, "model": "%s", "model_id": %s, "cpu": %s, "ram_gb": %s, "storage_gb": %s,\n' \
    "$(js "$COMPUTER_NAME")" "$(j "${MODEL_NAME:-Mac}")" "$(js "$MODEL_ID")" "$(js "$CHIP")" "$(jn "$V_RAM")" "$(jn "$V_TOT_GB")"
  printf '    "os": {"family": "macos", "name": "%s", "version": "%s", "build": %s},\n' "$(j "${OS_NAME:-macOS}")" "$(j "${OS_VER:-unknown}")" "$(js "$OS_BUILD")"
  printf '    "console_user": %s\n  },\n' "$(js "$CONSOLE_USER")"
  printf '  "summary": {"overall": "%s", "score": %d, "counts": {"fail": %d, "warn": %d, "info": %d, "ok": %d, "unknown": %d}},\n' \
    "$JOVERALL" "$SCORE" "$NFAIL" "$NWARN" "$NINFO" "$NOK" "$NUNK"
  printf '  "checks": [\n'
  local k=0 i sep seen=" " id
  for i in "${ORDER[@]}"; do
    id="${CK_I[$i]}"
    local base="$id" dup=2
    while :; do case "$seen" in *" $id "*) id="${base}_$dup"; dup=$((dup + 1)) ;; *) break ;; esac; done
    seen="$seen$id "
    [ "$k" -gt 0 ] && printf ',\n'
    k=$((k + 1))
    printf '    {"id": "%s", "status": "%s", "area": "%s", "message": "%s", "fix": %s, "source": "command"}' \
      "$id" "$(lc "${CK_S[$i]}")" "$(j "${CK_A[$i]}")" "$(j "${CK_M[$i]}")" "$(js "${CK_F[$i]}")"
  done
  printf '\n  ],\n  "facts": {%s\n  },\n' "$FACTS"
  [ -n "$INV_JSON" ] && printf '  "inventory": %s,\n' "$INV_JSON"
  printf '  "sections": [\n'
  local n t sid
  for ((n = 1; n <= SEC_N; n++)); do
    t="${SEC_T[$n]}"
    sid=$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_' | sed 's/__*/_/g; s/^_*//; s/_*$//' | cut -c1-40)
    [ "$n" -gt 1 ] && printf ',\n'
    printf '    {"id": "%s", "title": "%s", "blocks": [{"title": "Detail", "text": "%s"}]}' \
      "${sid:-section_$n}" "$(j "$t")" "$(j "$(grep -v '^  Public IP ' "$WORK/s$n.txt" | head -c 19000)")"
  done
  printf '\n  ]\n}\n'
} >"$JSON"
}
write_json ""

# ---- HTML --------------------------------------------------------------------------
case "$WORST" in 0) OCLS=ok ;; 1) OCLS=warn ;; *) OCLS=fail ;; esac
tile() { printf '<div class="tile"><div class="tk">%s</div><div class="tv">%s</div></div>\n' "$(h "$1")" "$(h "${2:-n/a}")"; }
{
cat <<'CSS'
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{--bg:#f6f7f9;--card:#fff;--fg:#1d2330;--mut:#667085;--line:#e4e7ec;--ok:#12805c;--okb:#e7f6ef;--warn:#9a6700;--warnb:#fff6dd;--fail:#c0262d;--failb:#fdecec;--info:#3d5a80;--infob:#eaf0f8}
@media (prefers-color-scheme:dark){:root{--bg:#0f1218;--card:#171b23;--fg:#e6e9ef;--mut:#98a2b3;--line:#2a303b;--ok:#3ccf91;--okb:#123326;--warn:#f0b429;--warnb:#33290f;--fail:#ff6b6b;--failb:#3a1717;--info:#8fb3e0;--infob:#18263a}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",Arial,sans-serif}
.wrap{max-width:1100px;margin:0 auto;padding:28px 20px 60px}
h1{font-size:22px;margin:0 0 4px}.sub{color:var(--mut);margin:0 0 20px}
.banner{display:flex;align-items:center;gap:20px;padding:18px 22px;border-radius:14px;margin-bottom:18px;border:1px solid var(--line);background:var(--card)}
.banner .score{font-size:40px;font-weight:700;min-width:90px;text-align:center}
.banner.ok .score{color:var(--ok)}.banner.warn .score{color:var(--warn)}.banner.fail .score{color:var(--fail)}
.banner .st{font-size:18px;font-weight:700}.banner .ct{color:var(--mut)}
.tiles{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:10px;margin-bottom:22px}
.tile{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px 14px}.tk{color:var(--mut);font-size:12px;text-transform:uppercase;letter-spacing:.04em}.tv{font-weight:600;margin-top:2px;word-break:break-word}
h2{font-size:16px;margin:26px 0 10px}
table{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--line);border-radius:12px;overflow:hidden}
td{padding:9px 12px;border-top:1px solid var(--line);vertical-align:top}tr:first-child td{border-top:0}
.pill{display:inline-block;font-size:11px;font-weight:700;padding:2px 8px;border-radius:999px;min-width:44px;text-align:center}
.OK{color:var(--ok);background:var(--okb)}.WARN{color:var(--warn);background:var(--warnb)}.FAIL{color:var(--fail);background:var(--failb)}.INFO{color:var(--info);background:var(--infob)}.UNKNOWN{color:var(--mut);background:var(--bg);border:1px dashed var(--line)}
.area{font-weight:600;white-space:nowrap}.fix{color:var(--mut);font-size:13px;margin-top:2px}
details{background:var(--card);border:1px solid var(--line);border-radius:12px;margin:10px 0;padding:0 16px}
summary{cursor:pointer;padding:12px 0;font-weight:600;font-size:15px}
.kv{display:grid;grid-template-columns:260px 1fr;gap:12px;padding:5px 0;border-top:1px solid var(--line)}.kv .k{color:var(--mut)}.kv .v{word-break:break-word}
h4{margin:14px 0 6px;font-size:13px;color:var(--mut);text-transform:uppercase;letter-spacing:.04em}
pre{background:var(--bg);border:1px solid var(--line);border-radius:8px;padding:10px;overflow:auto;font:12px/1.45 ui-monospace,Menlo,monospace;margin:0 0 14px;white-space:pre}
.foot{color:var(--mut);font-size:12px;margin-top:30px}
@media (max-width:640px){.kv{grid-template-columns:1fr}.banner{flex-direction:column;align-items:flex-start}}
@media print{details{break-inside:avoid}details:not([open]) > *:not(summary){display:block}}
</style>
CSS
printf '<title>QED Mac Health - %s</title></head><body><div class="wrap">\n' "$(h "$COMPUTER_NAME")"
printf '<h1>QED Mac Health Snapshot</h1><p class="sub">%s &middot; %s &middot; taken %s &middot; %s mode &middot; v%s</p>\n' \
  "$(h "$COMPUTER_NAME")" "$(h "$MODEL_NAME")" "$(h "$TAKEN")" "$( [ "$QUICK" -eq 1 ] && echo quick || echo full )" "$VERSION"
printf '<div class="banner %s"><div class="score">%d</div><div><div class="st">%s</div><div class="ct">%d fail &middot; %d warn &middot; %d unknown &middot; %d info &middot; %d ok &middot; collected in %ds</div></div></div>\n' \
  "$OCLS" "$SCORE" "$OVERALL" "$NFAIL" "$NWARN" "$NUNK" "$NINFO" "$NOK" "$ELAPSED"
printf '<div class="tiles">\n'
tile "Model" "$MODEL_NAME ($MODEL_ID)"
tile "Chip" "$CHIP"
tile "macOS" "$OS_VER ($OS_BUILD)"
tile "Serial" "$SERIAL"
tile "Memory" "${MEM_GB} GB, pressure $PRESSURE_TXT"
tile "Startup disk" "${D_FREE_GB} GB free of ${D_TOT_GB} GB (${D_FREE_PCT}%)"
tile "Battery" "$BATT_SUMMARY"
tile "Uptime" "$UPTIME_TXT"
tile "Network" "${PRIMARY_PORT:-offline} ${PRIMARY_IP}"
tile "Wi-Fi signal" "$WIFI_SUMMARY"
tile "Internet speed" "${SPEED_SUMMARY:-n/a}"
tile "Last backup" "$TM_SUMMARY"
printf '</div>\n<h2>Health checks</h2><table>\n'
for i in "${ORDER[@]}"; do
  printf '<tr><td style="width:70px"><span class="pill %s">%s</span></td><td class="area" style="width:150px">%s</td><td>%s' \
    "${CK_S[$i]}" "${CK_S[$i]}" "$(h "${CK_A[$i]}")" "$(h "${CK_M[$i]}")"
  case "${CK_S[$i]}" in WARN|FAIL|INFO) [ -n "${CK_F[$i]}" ] && printf '<div class="fix">Fix: %s</div>' "$(h "${CK_F[$i]}")" ;; esac
  printf '</td></tr>\n'
done
printf '</table>\n<h2>Details</h2>\n'
for ((n = 1; n <= SEC_N; n++)); do
  op=""; [ "$n" -le 1 ] && op=" open"
  printf '<details%s><summary>%s</summary>\n' "$op" "$(h "${SEC_T[$n]}")"
  cat "$WORK/s$n.html"
  printf '</details>\n'
done
printf '<p class="foot">Read-only report generated by QED Mac Health Snapshot v%s. Nothing on this Mac was changed. Suspected hardware fault? Run Apple Diagnostics (Apple silicon: hold power at startup, then Cmd-D; Intel: hold D at startup). Matching files: %s.txt / .json</p>\n' "$VERSION" "$(h "$(basename "$BASE")")"
printf '</div></body></html>\n'
} >"$HTML"

if [ -n "${SUDO_USER:-}" ]; then chown "$SUDO_USER" "$OUTDIR" "$TXT" "$HTML" "$JSON" 2>/dev/null; fi

# ---- terminal summary -----------------------------------------------------------------
case "$WORST" in 0) OC="$GRN" ;; 1) OC="$YEL" ;; *) OC="$RED" ;; esac
echo
echo "${BLD}$COMPUTER_NAME${RST} - $MODEL_NAME, $CHIP, $OS_NAME $OS_VER"
echo
for i in "${ORDER[@]}"; do
  case "${CK_S[$i]}" in OK) c="$GRN" ;; WARN) c="$YEL" ;; FAIL) c="$RED" ;; *) c="$BLU" ;; esac
  printf '  %s%-7s%s  %-16s %s\n' "$c" "${CK_S[$i]}" "$RST" "${CK_A[$i]}" "${CK_M[$i]}"
done
echo
echo "  ${OC}${BLD}${OVERALL}${RST}  score $SCORE/100  ($NFAIL fail, $NWARN warn, $NUNK unknown, $NINFO info, $NOK ok) in ${ELAPSED}s"
echo
echo "  Report: $HTML"
echo "          ${TXT##*/}, ${JSON##*/}"
echo

if [ "$OPEN" -eq 1 ] && [ -z "${SSH_CONNECTION:-}" ] && [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != root ] && [ "$CONSOLE_USER" != loginwindow ]; then
  if [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ]; then sudo -u "$SUDO_USER" open "$HTML" >/dev/null 2>&1; else open "$HTML" >/dev/null 2>&1; fi
fi

# Public edition: no upload. Hand the .json to the QED help desk.
if [ -n "$CODE" ]; then
  echo "  This edition never sends anything. Give the QED help desk this file: $JSON"
  echo
fi

exit "$WORST"
