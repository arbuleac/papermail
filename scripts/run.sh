#!/usr/bin/env bash
# Build, bundle and launch the app. Usage: scripts/run.sh [debug|release]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$("$ROOT/scripts/build-app.sh" "${1:-debug}")"
open "$APP"
