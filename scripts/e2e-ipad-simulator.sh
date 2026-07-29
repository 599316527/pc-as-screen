#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
device_name="${PC_AS_SCREEN_E2E_DEVICE_NAME:-iPad (A16)}"
runtime_os="${PC_AS_SCREEN_E2E_OS:-26.4.1}"
port="${PC_AS_SCREEN_E2E_PORT:-6100}"
password="${PC_AS_SCREEN_E2E_PASSWORD:-e2e-pass}"
derived_data="${PC_AS_SCREEN_E2E_DERIVED_DATA:-$(mktemp -d /tmp/pc-as-screen-ipad-e2e-dd.XXXXXX)}"
log_file="${PC_AS_SCREEN_E2E_LOG:-/tmp/pc-as-screen-ipad-e2e.$$.log}"
sender_log_file="${PC_AS_SCREEN_E2E_SENDER_LOG:-/tmp/pc-as-screen-ipad-e2e-sender.$$.log}"
screenshot_file="${PC_AS_SCREEN_E2E_SCREENSHOT:-/tmp/pc-as-screen-ipad-e2e.$$.png}"
sender_mode="${PC_AS_SCREEN_E2E_SENDER:-macos}"
bundle_id="cn.hk1229.pcascreen.IPadReceiverE2E"
export PC_AS_SCREEN_E2E_DEVICE_NAME="$device_name"

echo "[e2e-ipad] build simulator app"
(
  cd "$repo_root/ipad-receiver"
  xcodebuild \
    -project IPadReceiverE2E.xcodeproj \
    -scheme IPadReceiverE2E \
    -destination "platform=iOS Simulator,name=${device_name},OS=${runtime_os}" \
    -derivedDataPath "$derived_data" \
    build
)

app_path="$derived_data/Build/Products/Debug-iphonesimulator/IPadReceiverE2E.app"
if [[ ! -d "$app_path" ]]; then
  echo "[e2e-ipad] app bundle not found: $app_path" >&2
  exit 1
fi

device_id="$(
  xcrun simctl list devices available --json | python3 -c '
import json
import os
import sys

target = os.environ["PC_AS_SCREEN_E2E_DEVICE_NAME"]
data = json.load(sys.stdin)
matches = [
    device
    for devices in data.get("devices", {}).values()
    for device in devices
    if device.get("isAvailable") and device.get("name") == target
]
shutdown = next((device for device in matches if device.get("state") == "Shutdown"), None)
chosen = shutdown or (matches[0] if matches else None)
print(chosen["udid"] if chosen else "")
'
)"
if [[ -z "$device_id" ]]; then
  echo "[e2e-ipad] simulator not found: $device_name" >&2
  exit 1
fi

echo "[e2e-ipad] boot simulator $device_name ($device_id)"
xcrun simctl boot "$device_id" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$device_id" -b

echo "[e2e-ipad] install app"
xcrun simctl terminate "$device_id" "$bundle_id" >/dev/null 2>&1 || true
xcrun simctl uninstall "$device_id" "$bundle_id" >/dev/null 2>&1 || true
xcrun simctl install "$device_id" "$app_path"

rm -f "$log_file" "$sender_log_file"
touch "$log_file" "$sender_log_file"
xcrun simctl spawn "$device_id" log stream \
  --style compact \
  --predicate 'process == "IPadReceiverE2E"' >"$log_file" 2>&1 &
log_pid="$!"
cleanup() {
  kill "$log_pid" >/dev/null 2>&1 || true
  if [[ -n "${first_sender_pid:-}" ]]; then
    kill "$first_sender_pid" >/dev/null 2>&1 || true
  fi
  xcrun simctl terminate "$device_id" "$bundle_id" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[e2e-ipad] launch app"
SIMCTL_CHILD_PC_AS_SCREEN_E2E=1 \
SIMCTL_CHILD_PC_AS_SCREEN_E2E_PORT="$port" \
SIMCTL_CHILD_PC_AS_SCREEN_E2E_PASSWORD="$password" \
  xcrun simctl launch --terminate-running-process "$device_id" "$bundle_id"

send_stream() {
  local hold_after="$1"
  if [[ "$sender_mode" == "macos" ]]; then
    swift run --package-path "$repo_root/macos-sender" PCScreenSender \
      --host 127.0.0.1 \
      --port "$port" \
      --password "$password" \
      --width 640 \
      --height 360 \
      --fps 10 \
      --bitrate 1000000 \
      --hide-cursor false \
      --test-pattern true \
      --duration "$hold_after"
  elif [[ "$sender_mode" == "python" ]]; then
    python3 "$repo_root/scripts/ipad_fake_sender.py" --host 127.0.0.1 --port "$port" --password "$password" --hold-after "$hold_after"
  else
    echo "[e2e-ipad] unknown sender mode: $sender_mode" >&2
    exit 1
  fi
}

echo "[e2e-ipad] wait for listener"
for _ in {1..60}; do
  if grep -q "PC_AS_SCREEN_E2E_LISTENING" "$log_file"; then
    break
  fi
  sleep 0.5
done
if ! grep -q "PC_AS_SCREEN_E2E_LISTENING" "$log_file"; then
  echo "[e2e-ipad] app did not report listening" >&2
  tail -n 80 "$log_file" >&2
  exit 1
fi

echo "[e2e-ipad] send first test stream with $sender_mode sender"
send_stream 6 >"$sender_log_file" 2>&1 &
first_sender_pid="$!"

echo "[e2e-ipad] wait for first connection and cursor event"
for _ in {1..60}; do
  if grep -q "PC_AS_SCREEN_E2E_CONNECTED" "$log_file" && grep -q "PC_AS_SCREEN_E2E_VIDEO_DISPLAYED" "$log_file" && grep -q "PC_AS_SCREEN_E2E_CURSOR" "$log_file"; then
    break
  fi
  sleep 0.5
done
if ! grep -q "PC_AS_SCREEN_E2E_CONNECTED" "$log_file"; then
  echo "[e2e-ipad] app did not report connected" >&2
  tail -n 120 "$log_file" >&2
  exit 1
fi
if ! grep -q "PC_AS_SCREEN_E2E_CURSOR" "$log_file"; then
  echo "[e2e-ipad] app did not receive cursor packet" >&2
  tail -n 120 "$log_file" >&2
  exit 1
fi
if ! grep -q "PC_AS_SCREEN_E2E_VIDEO_DISPLAYED" "$log_file"; then
  echo "[e2e-ipad] display layer did not accept video for display" >&2
  tail -n 120 "$log_file" >&2
  exit 1
fi

echo "[e2e-ipad] wait for receiver mouse click on sender"
for _ in {1..30}; do
  if grep -q "PC_AS_SCREEN_E2E_SENDER_MOUSE_CLICK" "$sender_log_file"; then
    break
  fi
  sleep 0.5
done
if ! grep -q "PC_AS_SCREEN_E2E_MOUSE_CLICK" "$log_file"; then
  echo "[e2e-ipad] app did not send E2E mouse click" >&2
  tail -n 120 "$log_file" >&2
  exit 1
fi
if ! grep -q "PC_AS_SCREEN_E2E_SENDER_MOUSE_CLICK" "$sender_log_file"; then
  echo "[e2e-ipad] sender did not receive mouse click from iPad receiver" >&2
  tail -n 120 "$sender_log_file" >&2
  tail -n 120 "$log_file" >&2
  exit 1
fi

echo "[e2e-ipad] capture simulator screen and verify non-black video pixels"
sleep 1
xcrun simctl io "$device_id" screenshot "$screenshot_file" >/dev/null
python3 - "$screenshot_file" <<'PY'
import os
import struct
import subprocess
import sys
import tempfile

png_path = sys.argv[1]
raw_path = tempfile.mktemp(suffix=".rgba")
try:
    info = subprocess.check_output(
        ["sips", "-g", "pixelWidth", "-g", "pixelHeight", png_path],
        text=True,
        stderr=subprocess.STDOUT,
    )
    width = height = None
    for line in info.splitlines():
        stripped = line.strip()
        if stripped.startswith("pixelWidth:"):
            width = int(stripped.split(":", 1)[1])
        elif stripped.startswith("pixelHeight:"):
            height = int(stripped.split(":", 1)[1])
    if not width or not height:
        raise SystemExit("could not read screenshot dimensions")
    subprocess.check_call(
        ["ffmpeg", "-v", "error", "-i", png_path, "-f", "rawvideo", "-pix_fmt", "rgba", raw_path],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    data = open(raw_path, "rb").read()
    # Inspect the central video area only. The top overlay can contain text even
    # when the video layer is black, so it is deliberately excluded.
    x0, x1 = width // 4, width * 3 // 4
    y0, y1 = height // 4, height * 3 // 4
    stride = width * 4
    checked = 0
    non_black = 0
    colors = set()
    for y in range(y0, y1, 8):
        row = y * stride
        for x in range(x0, x1, 8):
            offset = row + x * 4
            if offset + 3 > len(data):
                continue
            r, g, b = data[offset], data[offset + 1], data[offset + 2]
            checked += 1
            if max(r, g, b) > 24:
                non_black += 1
                if len(colors) < 64:
                    colors.add((r // 16, g // 16, b // 16))
    if checked == 0:
        raise SystemExit("no screenshot pixels sampled")
    ratio = non_black / checked
    if ratio < 0.05 or len(colors) < 3:
        raise SystemExit(
            f"central video area is still black or flat: non_black_ratio={ratio:.4f}, color_bins={len(colors)}"
        )
    center_x = width // 2
    center_y = height // 2
    cursor_white = 0
    cursor_dark = 0
    for y in range(max(0, center_y - 8), min(height, center_y + 58)):
        row = y * stride
        for x in range(max(0, center_x - 8), min(width, center_x + 46)):
            offset = row + x * 4
            if offset + 3 > len(data):
                continue
            r, g, b = data[offset], data[offset + 1], data[offset + 2]
            if r > 235 and g > 235 and b > 235:
                cursor_white += 1
            if r < 18 and g < 18 and b < 18:
                cursor_dark += 1
    if cursor_white < 8 or cursor_dark < 4:
        raise SystemExit(
            f"remote cursor overlay not visible near center: white={cursor_white}, dark={cursor_dark}"
        )
    print(
        f"[e2e-ipad] screenshot non-black check passed ratio={ratio:.4f} "
        f"color_bins={len(colors)} cursor_white={cursor_white} cursor_dark={cursor_dark}"
    )
finally:
    try:
        os.remove(raw_path)
    except OSError:
        pass
PY

wait "$first_sender_pid"
first_sender_pid=""

echo "[e2e-ipad] send second test stream"
send_stream 0.5 >>"$sender_log_file" 2>&1

echo "[e2e-ipad] wait for reconnection and second displayed video"
for _ in {1..60}; do
  connected_count="$(grep -c "PC_AS_SCREEN_E2E_CONNECTED" "$log_file" || true)"
  sample_count="$(grep -c "PC_AS_SCREEN_E2E_VIDEO_SAMPLE" "$log_file" || true)"
  displayed_count="$(grep -c "PC_AS_SCREEN_E2E_VIDEO_DISPLAYED" "$log_file" || true)"
  cursor_count="$(grep -c "PC_AS_SCREEN_E2E_CURSOR" "$log_file" || true)"
  if [[ "$sender_mode" == "macos" ]]; then
    if [[ "$connected_count" -ge 2 && "$sample_count" -ge 2 && "$displayed_count" -ge 2 ]]; then
      break
    fi
  elif [[ "$connected_count" -ge 2 && "$sample_count" -ge 2 && "$displayed_count" -ge 2 && "$cursor_count" -ge 2 ]]; then
    break
  fi
  sleep 0.5
done
connected_count="$(grep -c "PC_AS_SCREEN_E2E_CONNECTED" "$log_file" || true)"
sample_count="$(grep -c "PC_AS_SCREEN_E2E_VIDEO_SAMPLE" "$log_file" || true)"
displayed_count="$(grep -c "PC_AS_SCREEN_E2E_VIDEO_DISPLAYED" "$log_file" || true)"
cursor_count="$(grep -c "PC_AS_SCREEN_E2E_CURSOR" "$log_file" || true)"
if [[ "$connected_count" -lt 2 || "$sample_count" -lt 2 || "$displayed_count" -lt 2 || "$cursor_count" -lt 2 ]]; then
  echo "[e2e-ipad] app did not accept a second stream after disconnect" >&2
  tail -n 160 "$log_file" >&2
  exit 1
fi
if grep -q "PC_AS_SCREEN_E2E_DISPLAY_FAILED" "$log_file"; then
  echo "[e2e-ipad] display layer reported a decode/display failure" >&2
  tail -n 120 "$log_file" >&2
  exit 1
fi
if grep -q "PC_AS_SCREEN_E2E_ERROR" "$log_file"; then
  echo "[e2e-ipad] app reported an error" >&2
  tail -n 120 "$log_file" >&2
  exit 1
fi

echo "[e2e-ipad] passed"
