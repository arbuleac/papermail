#!/usr/bin/env bash
# Run the whole test suite. Usage: scripts/test.sh [--filter Pattern]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
swift test "$@"
