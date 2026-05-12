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
    listing=$(docker run --rm --entrypoint=sh "$IMAGE" -c \
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
docker run --rm --entrypoint=sh "$IMAGE" -c "cat $found_json" > "$DEST"

# ---------------------------------------------------------------------------
# Substitute Ontotext's ${...} env-var placeholders with concrete values.
# ---------------------------------------------------------------------------
# Ontotext's realm export ships with placeholders like
# ${POOLPARTY_KEYCLOAK_LOGIN_CLIENTSECRET} that were meant to be expanded
# at Keycloak boot time. The operator-managed KeycloakRealmImport CR does
# NOT perform that substitution -- the literal placeholder strings end up
# stored as the password / client secret values in Keycloak, breaking
# every login attempt against Ontotext-baked credentials.
#
# Fix: rewrite the realm export at extract time so the values match what
# PoolParty's image actually sends.
#
# Image-version coupling: POOLPARTY_KEYCLOAK_LOGIN_CLIENTSECRET is read
# from the PoolParty container env. As of poolparty:10.x, the value is
# ohIP3x4XuoCsGDsGlZRvNvO5VN6veFb5. If a future image bumps it, update
# the value below by inspecting `kubectl exec ... env | grep CLIENTSECRET`
# on a running PoolParty pod.
#
# (The companion fix is the post-install authz-import Job in
# charts/keycloak-realms/templates/keycloak-authz-import-job.yaml --
# the operator's RealmImport CR drops the .clients[].authorizationSettings
# block; the Job re-imports it via the Keycloak admin REST API.)
PPT_SECRET="ohIP3x4XuoCsGDsGlZRvNvO5VN6veFb5"
SUPERADMIN_PASSWORD="poolparty"

echo
echo "Substituting Ontotext placeholders..."
TMP=$(mktemp)
jq --arg ppt_secret "$PPT_SECRET" --arg superadmin_pw "$SUPERADMIN_PASSWORD" '
    (.clients[]? | select(.clientId == "ppt") | .secret) = $ppt_secret
    | (.users[]? | select(.username == "superadmin") | .credentials[0].value) = $superadmin_pw
    | (.users[]? | select(.username == "superadmin") | .credentials[0].temporary) = false
' "$DEST" > "$TMP" && mv "$TMP" "$DEST"
echo "  ppt.secret      -> ohIP...eFb5  (matches PoolParty image)"
echo "  superadmin pw   -> poolparty   (temporary=false)"

# Belt-and-braces global sweep for any OTHER occurrence of the same
# placeholders. The targeted jq above hits the load-bearing paths
# (ppt.secret + superadmin password), but the same env-var-style
# placeholders also appear in client attributes / web origins /
# protocolMapper config in some image versions, and the operator-
# managed KeycloakRealmImport CR doesn't expand them. Leftover
# `${POOLPARTY_*}` strings break the realm import silently. Global
# sed is safe -- the placeholder syntax is unambiguous and the value
# is identical wherever it appears.
sed -i "s|\${POOLPARTY_KEYCLOAK_LOGIN_CLIENTSECRET}|$PPT_SECRET|g" "$DEST"
sed -i "s|\${POOLPARTY_SUPER_ADMIN_PASSWORD}|$SUPERADMIN_PASSWORD|g" "$DEST"
remaining=$(grep -oE '\$\{POOLPARTY_[A-Z_]+\}' "$DEST" | sort -u || true)
if [[ -n "$remaining" ]]; then
    echo "  WARNING: leftover \${...} placeholders the script doesn't know how to substitute:"
    echo "$remaining" | sed 's/^/    /'
    echo "  Update extract-poolparty-realm.sh with values for these before running reset-helm.sh."
fi

echo
echo "Sanity check:"
jq -r '"  realm: \(.realm)"' "$DEST" 2>/dev/null || echo "  (jq not installed; skip sanity check)"
jq -r '.clients[]? | "  client: \(.clientId)"' "$DEST" 2>/dev/null || true

echo
echo "Done. The realm JSON is now staged at:"
echo "  charts/keycloak-realms/files/poolparty-realm.json"
echo
echo "keycloak-realms is a subchart of the umbrella (charts/graphwise-stack)"
echo "and consumes this file via .Files.Get at render time. The next umbrella"
echo "install picks it up automatically -- no separate helm command needed."
echo
echo "Next steps in the standard deploy flow:"
echo "  ./scripts/install-licenses.sh"
echo "  ./scripts/reset-helm.sh --yes <subdomain>      # or --skip-graphrag for umbrella-only"
