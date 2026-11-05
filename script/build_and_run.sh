#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
case "$MODE" in run|--debug|--logs|--telemetry|--verify) ;; *) echo "usage: $0 [--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;; esac
if pgrep -x MiPlay >/dev/null; then
  echo "MiPlay 正在运行，请等待当前操作完成并正常退出后再运行此脚本。" >&2
  exit 1
fi
xcodebuild -project MiPlay.xcodeproj -scheme MiPlay -configuration Debug -derivedDataPath build/GameNews build
if pgrep -x MiPlay >/dev/null; then
  echo "构建期间 MiPlay 已启动；请先正常退出，再运行此脚本。" >&2
  exit 1
fi
APP_BUNDLE="$ROOT_DIR/build/GameNews/Build/Products/Debug/MiPlay.app"
case "$MODE" in
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/MiPlay" ;;
  --logs) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "MiPlay"' ;;
  --telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "SteveTan.MiPlay"' ;;
  --verify) /usr/bin/open -n "$APP_BUNDLE"; sleep 2; pgrep -x MiPlay >/dev/null ;;
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
esac
