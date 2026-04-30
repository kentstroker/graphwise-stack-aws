#!/usr/bin/env bash
# extract-poolparty-realm.sh — pull the poolparty realm JSON out of the
# ontotext/poolparty-keycloak image and drop it where the
# keycloak-realms Helm chart expects it.
#
# The JSON contains client secrets and password hashes, so it's
# gitignored under charts/keycloak-realms/files/. Re-run this if you
# bump the poolparty-keycloak image version.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="$REPO_ROOT/charts/keycloak-realms/files/poolparty-realm.json"

IMAGE="${POOLPARTY_KEYCLOAK_IMAGE:-ontotext/poolparty-keycloak:latest}"

echo "Inspecting realm imports inside $IMAGE..."

# Find every JSON file under the standard Keycloak import path.
# Different image versions have used /opt/keycloak/data/import/ and
# /opt/keycloak/import/ — check both.
IMPORT_PATHS=(
  /opt/keycloak/data/import
  /opt/keycloak/import
)

found_json=""
for path in "${IMPORT_PATHS[@]}"; do
    listing=$(podman run --rm --entrypoint=sh "$IMAGE" -c \
        "ls -1 $path/*.json 2>/dev/null || true")
    if [[ -n "$listing" ]]; then
        echo "  Found JSON files under $path:"
        echo "$listing" | sed 's/^/    /'
        # Take the first one. If multiple realms ship in one image,
        # adjust to pick the one whose name contains "poolparty".
        found_json=$(echo "$listing" | grep -i poolparty | head -n1 || \
                     echo "$listing" | head -n1)
        break
    fi
done

if [[ -z "$found_json" ]]; then
    echo "ERROR: no realm JSON found in $IMAGE under any of:"
    printf '  %s\n' "${IMPORT_PATHS[@]}"
    echo "Override the image with POOLPARTY_KEYCLOAK_IMAGE=... and re-run."
    exit 1
fi

echo
echo "Extracting $found_json → $DEST"
mkdir -p "$(dirname "$DEST")"
podman run --rm --entrypoint=sh "$IMAGE" -c "cat $found_json" > "$DEST"

echo
echo "Sanity check:"
jq -r '"  realm: \(.realm)"' "$DEST" 2>/dev/null || echo "  (jq not installed; skip sanity check)"
jq -r '.clients[]? | "  client: \(.clientId)"' "$DEST" 2>/dev/null || true

echo
echo "Done. Now (re-)install the keycloak-realms chart:"
echo "  helm upgrade --install keycloak-realms ./charts/keycloak-realms ..."
