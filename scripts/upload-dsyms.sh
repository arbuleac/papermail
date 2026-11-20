#!/usr/bin/env bash
# Upload the last build's debug symbols to Sentry, so its crash reports name functions, files and lines
# (docs/CRASH-REPORTING.md). Usage: scripts/upload-dsyms.sh [extra upload arguments, e.g. --include-sources]
#
# Uses Sentry's `sentry` CLI when it is installed (signed in with `sentry auth login`). Run from the repository, it
# finds the organization and project from the DSN in Resources/SentryDSN. Otherwise the legacy `sentry-cli`, with
# SENTRY_AUTH_TOKEN, SENTRY_ORG and SENTRY_PROJECT in the environment or in ~/.sentryclirc.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DSYM="$ROOT/dist/SuperSparrow.app.dSYM"
if [ ! -d "$DSYM" ]; then
  echo "error: $DSYM is missing; run scripts/build-app.sh first" >&2
  exit 1
fi
dwarfdump --uuid "$DSYM"
if command -v sentry >/dev/null 2>&1; then
  cd "$ROOT"
  sentry debug-files upload --type dsym "$@" "$DSYM"
elif command -v sentry-cli >/dev/null 2>&1; then
  sentry-cli debug-files upload "$@" "$DSYM"
else
  echo "error: neither sentry nor sentry-cli is installed; see docs/CRASH-REPORTING.md" >&2
  exit 1
fi
