#!/usr/bin/env bash
# Upload the last build's debug symbols to Sentry, so its crash reports name functions, files and lines
# (docs/CRASH-REPORTING.md). Usage: scripts/upload-dsyms.sh [extra sentry-cli arguments, e.g. --include-sources]
#
# Needs sentry-cli (the standalone binary from https://github.com/getsentry/sentry-cli/releases; no npm or Homebrew)
# and SENTRY_AUTH_TOKEN, SENTRY_ORG and SENTRY_PROJECT, in the environment or in ~/.sentryclirc.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DSYM="$ROOT/dist/SuperSparrow.app.dSYM"
if [ ! -d "$DSYM" ]; then
  echo "error: $DSYM is missing; run scripts/build-app.sh first" >&2
  exit 1
fi
if ! command -v sentry-cli >/dev/null 2>&1; then
  echo "error: sentry-cli is not installed; see docs/CRASH-REPORTING.md" >&2
  exit 1
fi
dwarfdump --uuid "$DSYM"
sentry-cli debug-files upload "$@" "$DSYM"
