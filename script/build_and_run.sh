#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
case "$MODE" in run|--debug|--logs|--telemetry|--verify) ;; *) echo "usage: $0 [--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;; esac
pkill -x MiPlay >/dev/null 2>&1 || true
xcodebuild -project MiPlay.xcodeproj -scheme MiPlay -configuration Debug -derivedDataPath build/GameNews CODE_SIGNING_ALLOWED=NO build
APP_BUNDLE="$ROOT_DIR/build/GameNews/Build/Products/Debug/MiPlay.app"
case "$MODE" in
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/MiPlay" ;;
  --logs) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "MiPlay"' ;;
  --telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "SteveTan.MiPlay"' ;;
  --verify) /usr/bin/open -n "$APP_BUNDLE"; sleep 2; pgrep -x MiPlay >/dev/null ;;
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
esac
