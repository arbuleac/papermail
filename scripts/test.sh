#!/usr/bin/env bash
# Run the whole test suite. Usage: scripts/test.sh [--filter Pattern]
# `swift test` runs every test target, SSAITests included (its recorded fixtures are a resource folder, checked for
# personal data by FixturePrivacyTests). No test reaches the network or a real CLI: stub URLProtocols, fake executables.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# Generated design files must match docs/design/tokens.json before anything is tested against them, and so must the
# app icon and the brand files drawn from it.
swift scripts/tools/quire-tokens.swift --check
swift scripts/tools/app-icon.swift --check
swift scripts/tools/brand-assets.swift --check
swift test "$@"
