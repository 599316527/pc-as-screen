#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[verify] swift test"
swift test --package-path "$repo_root/macos-sender"

echo "[verify] ipad receiver swift test"
swift test --package-path "$repo_root/ipad-receiver"

if [[ "${PC_AS_SCREEN_RUN_IPAD_E2E:-0}" == "1" ]]; then
  echo "[verify] ipad receiver simulator e2e"
  bash "$repo_root/scripts/e2e-ipad-simulator.sh"
else
  echo "[verify] skip ipad receiver simulator e2e (set PC_AS_SCREEN_RUN_IPAD_E2E=1 to run)"
fi

echo "[verify] python py_compile"
python3 -m py_compile \
  "$repo_root/windows-receiver/pc_as_screen_receiver/__init__.py" \
  "$repo_root/windows-receiver/pc_as_screen_receiver/protocol.py" \
  "$repo_root/windows-receiver/pc_as_screen_receiver/player.py" \
  "$repo_root/windows-receiver/pc_as_screen_receiver/receiver.py"

echo "[verify] python unittest"
python3 -m unittest discover -s "$repo_root/windows-receiver/tests" -v
