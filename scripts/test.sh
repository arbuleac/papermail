#!/usr/bin/env bash
# Run the whole test suite. Usage: scripts/test.sh [--filter Pattern]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# Generated design files must match docs/design/tokens.json before anything is tested against them.
swift scripts/tools/quire-tokens.swift --check
swift test "$@"
