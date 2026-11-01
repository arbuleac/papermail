#!/usr/bin/env bash
# Build, bundle and launch the app.
# Usage: scripts/run.sh [debug|release] [-- app arguments…]
#   scripts/run.sh -- --demo          demo mode
#   scripts/run.sh release -- --reset-demo
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="debug"
if [ $# -gt 0 ] && [ "$1" != "--" ]; then
  CONFIG="$1"
  shift
fi
if [ $# -gt 0 ] && [ "$1" = "--" ]; then
  shift
fi
APP="$("$ROOT/scripts/build-app.sh" "$CONFIG" | tail -n 1)"
if [ $# -gt 0 ]; then
  open "$APP" --args "$@"
else
  open "$APP"
fi
