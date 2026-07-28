#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[verify] swift test"
swift test --package-path "$repo_root/macos-sender"

echo "[verify] python py_compile"
python3 -m py_compile \
  "$repo_root/windows-receiver/pc_as_screen_receiver/__init__.py" \
  "$repo_root/windows-receiver/pc_as_screen_receiver/protocol.py" \
  "$repo_root/windows-receiver/pc_as_screen_receiver/player.py" \
  "$repo_root/windows-receiver/pc_as_screen_receiver/receiver.py"

echo "[verify] python unittest"
python3 -m unittest discover -s "$repo_root/windows-receiver/tests" -v
