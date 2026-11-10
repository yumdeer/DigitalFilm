#!/usr/bin/env bash
# DigitalFilm 真机 UI 回归入口：先确保设备在线，再跑灯光/原图相关用例。
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! hdc list targets 2>/dev/null | grep -qE '^[0-9A-Za-z]'; then
  echo "未发现设备，请先连接真机并解锁屏幕"
  exit 2
fi
hdc shell power-shell wakeup >/dev/null 2>&1
hdc shell power-shell timeout -o 600000 >/dev/null 2>&1
python3 tests/ui/light_regression.py "$@"
