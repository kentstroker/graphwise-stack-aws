#!/usr/bin/env bash
# pushLastPull.sh -- find the most recent snapshot produced by
# pull-config.sh (under ~/Downloads/graphwise-config-<UTC-timestamp>/)
# and push it back to the EC2 via push-config.sh.
#
# Any extra args are forwarded verbatim to push-config.sh, so flags like
# --skip-cert / --keep-local-encryption-key still work:
#   ./scripts/laptop/pushLastPull.sh --skip-cert
#
# Override the search dir with --download-dir if pull-config.sh used a
# non-default --download-dir:
#   ./scripts/laptop/pushLastPull.sh --download-dir ~/snapshots

set -euo pipefail

if [ -t 1 ]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; BOLD=""; RESET=""
fi

DOWNLOAD_DIR="$HOME/Downloads"
PASSTHROUGH=()
while [ $# -gt 0 ]; do
    case "$1" in
        --download-dir) DOWNLOAD_DIR="$2"; shift 2 ;;
        *) PASSTHROUGH+=("$1"); shift ;;
    esac
done

# Snapshot folder names sort lexically by their UTC timestamp suffix,
# so the last entry is the most recent.
LAST_SNAPSHOT=$(find "$DOWNLOAD_DIR" -maxdepth 1 -type d -name 'graphwise-config-*' 2>/dev/null \
                | sort | tail -n 1)

if [ -z "$LAST_SNAPSHOT" ]; then
    echo "${RED}ERROR:${RESET} no graphwise-config-* snapshot found under $DOWNLOAD_DIR" >&2
    echo "Run ./scripts/laptop/pull-config.sh first." >&2
    exit 2
fi

SECRETS="$LAST_SNAPSHOT/graphwise-secrets.yaml"
LICENSES="$LAST_SNAPSHOT/licenses"

echo "${BOLD}Most recent snapshot:${RESET} $LAST_SNAPSHOT"
[ -f "$SECRETS" ]  && printf '  %s✓%s graphwise-secrets.yaml\n' "$GREEN" "$RESET"
[ -d "$LICENSES" ] && printf '  %s✓%s licenses/ (%d file(s))\n' "$GREEN" "$RESET" \
                          "$(find "$LICENSES" -maxdepth 1 -type f | wc -l | tr -d ' ')"
echo

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/push-config.sh" \
    --secrets-file "$SECRETS" \
    --licenses-dir "$LICENSES" \
    ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
