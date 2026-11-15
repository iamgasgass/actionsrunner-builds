#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# WindowsiOS Universal: launch the app stopped on ANY supported iPhone/iPad
# (A14 / M1 or newer, iOS 17+), attach LLDB, service the TXM JIT traps
# (brk #0x69 probe, brk #0xf00d RX allocation), then detach.
#
#   ./scripts/launch_on_device.sh <DEVICE_UDID> [BUNDLE_ID]
#
# Find the UDID with:  xcrun devicectl list devices
# Without a Mac, enable JIT on the device with StikDebug instead (the app's
# "ENABLE JIT" button opens it with the bundled henge-jit.js script).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UDID="${1:-${WINIOS_DEVICE_UDID:-}}"
BUNDLE_ID="${2:-${WINIOS_BUNDLE_ID:-com.iamgasgass.windowsiosx}}"
PYTHON="${PYTHON:-$(command -v python3)}"
LAUNCH_JSON="$ROOT/work/device_launch.json"

if [ -z "$UDID" ]; then
    echo "usage: $0 <DEVICE_UDID> [BUNDLE_ID]   (or set WINIOS_DEVICE_UDID)" >&2
    echo "devices:" >&2
    xcrun devicectl list devices >&2 || true
    exit 2
fi

mkdir -p "$ROOT/work"
rm -f "$LAUNCH_JSON"

echo "[device] Launching $BUNDLE_ID (--start-stopped) on $UDID..."
for attempt in 1 2 3 4 5; do
    if xcrun devicectl device process launch \
        --start-stopped \
        --terminate-existing \
        --device "$UDID" \
        --json-output "$LAUNCH_JSON" \
        "$BUNDLE_ID" || \
       xcrun devicectl device process launch \
        --no-activate \
        --start-stopped \
        --terminate-existing \
        --device "$UDID" \
        --json-output "$LAUNCH_JSON" \
        "$BUNDLE_ID"; then
        break
    fi
    if [ "$attempt" = 5 ]; then
        echo "[device] devicectl could not launch $BUNDLE_ID" >&2
        exit 1
    fi
    echo "[device] Attempt $attempt failed; retrying in 2s..."
    sleep 2
done

read -r PID CORE_ID < <("$PYTHON" -c "
import json, sys
d = json.load(open(sys.argv[1]))
pid = d['result']['process']['processIdentifier']
cid = d.get('result', {}).get('device', {}).get('identifier') or sys.argv[2]
print(pid, cid)
" "$LAUNCH_JSON" "$UDID")

echo "[device] Attaching LLDB to PID=$PID on CoreDevice=$CORE_ID..."
sleep 1
PYTHONPATH="$ROOT/scripts" xcrun lldb -b \
    -o "script lldb.debugger.SetAsync(False)" \
    -o "device select $CORE_ID" \
    -o "device process attach -p $PID" \
    -o "command script import $ROOT/scripts/_lldb_txm_jit.py" \
    -o "txm_jit_run"
