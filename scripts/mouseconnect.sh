# Reconnect / re-pair the Logitech MX Anywhere 3 Mac.
# The mouse often forgets this laptop after suspend. Each re-pair gives it a
# new BLE address (E5:59:F2:7F:0F:xx, last byte +1 each time), so this script
# finds it by name, pairs the new address and removes the stale one.
set -u

NAME="MX Anywhere"
SCAN_SECS=60

mx_paired() { bluetoothctl devices Paired | grep "$NAME" | awk '{print $2}'; }
mx_all()    { bluetoothctl devices        | grep "$NAME" | awk '{print $2}'; }
connected() { bluetoothctl info "$1" 2>/dev/null | grep -q 'Connected: yes'; }

rfkill unblock bluetooth 2>/dev/null
bluetoothctl power on >/dev/null

# 1. Already connected, or does a plain reconnect work?
for a in $(mx_paired); do
  if connected "$a"; then echo "Mouse already connected ($a)."; exit 0; fi
  echo "Trying to reconnect $a..."
  timeout 10 bluetoothctl connect "$a" >/dev/null 2>&1
  sleep 1
  if connected "$a"; then echo "Reconnected ($a)."; exit 0; fi
done

# 2. Bond is lost: re-pair. Clear unpaired leftovers so anything we find is fresh.
old=$(mx_paired)
for a in $(mx_all); do
  grep -qx "$a" <<<"$old" || bluetoothctl remove "$a" >/dev/null 2>&1
done

echo
echo ">>> Put the mouse in pairing mode: hold the Easy-Switch button on the"
echo ">>> bottom ~3 seconds until the light blinks fast. Scanning ${SCAN_SECS}s..."
bluetoothctl --timeout "$SCAN_SECS" scan le >/dev/null 2>&1 &
scan_pid=$!
trap 'kill $scan_pid 2>/dev/null' EXIT

new=""
for _ in $(seq 1 $((SCAN_SECS / 2))); do
  for a in $(mx_all); do
    grep -qx "$a" <<<"$old" || { new=$a; break 2; }
  done
  sleep 2
done
kill $scan_pid 2>/dev/null

if [ -z "$new" ]; then
  echo "Mouse not found. Is it in pairing mode (fast blink)? Run again to retry."
  exit 1
fi
echo "Found mouse at $new; pairing..."

for a in $old; do bluetoothctl remove "$a" >/dev/null 2>&1; done
timeout 30 bluetoothctl pair "$new" >/dev/null 2>&1
bluetoothctl trust "$new" >/dev/null 2>&1
timeout 15 bluetoothctl connect "$new" >/dev/null 2>&1
sleep 1

if connected "$new"; then
  echo "Done: mouse paired and connected at $new."
else
  echo "Pairing $new failed. Current state:"
  bluetoothctl info "$new" | grep -E 'Paired|Bonded|Trusted|Connected'
  exit 1
fi
