#!/bin/bash
# Sophon server launcher
# Uses compiled binary in Resources (production) or Python source (development).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 1. Try compiled binary in Resources (production)
if [ -x "$SCRIPT_DIR/sophon-server" ]; then
    exec "$SCRIPT_DIR/sophon-server" "$@"
fi

# 2. Try Python source alongside the built Yaagl project (development)
DEV_SOPHON="$SCRIPT_DIR/../../../YAAGL/sophon_server"
if [ -d "$DEV_SOPHON" ]; then
    cd "$DEV_SOPHON"
    exec python3 server.py "$@"
fi

# 3. Try Python source relative to project root fallback
if [ -d "$SCRIPT_DIR/../../../../YAAGL/sophon_server" ]; then
    cd "$SCRIPT_DIR/../../../../YAAGL/sophon_server"
    exec python3 server.py "$@"
fi

echo "ERROR: sophon-server binary and Python source not found." >&2
exit 1
