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

# ---------------------------------------------------------------------------
# Preflight: docker must be on PATH and the current shell must be able to
# reach the daemon.
# ---------------------------------------------------------------------------
# The classic AL2023 gotcha: cloud-init runs `usermod -aG docker ec2-user`,
# but an SSH session opened BEFORE that ran has effective groups frozen at
# login time and can't talk to /var/run/docker.sock. Every `docker run`
# returns "permission denied while trying to connect to the Docker daemon
# socket" until the operator either runs `exec newgrp docker` to promote
# the current shell into the group, or logs out and back in. This script
# previously failed deep inside the first `docker run` with a cryptic
# permission error; the preflight below short-circuits that with a clear
# message naming the fix.
if ! command -v docker >/dev/null 2>&1; then
    cat >&2 <<'EOF'
ERROR: 'docker' not found on PATH.

This script runs `docker run` against the poolparty-keycloak image to
extract the realm JSON.

  AL2023:  sudo dnf install -y docker && sudo systemctl enable --now docker
  macOS:   install Docker Desktop or colima

Then re-run this script.
EOF
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    # Daemon unreachable. Distinguish the "group not in current shell" case
    # from the "not a group member at all" case so we recommend the right fix.
    if getent group docker 2>/dev/null | tr ',' '\n' | grep -qx "$USER"; then
        cat >&2 <<EOF
ERROR: cannot reach the Docker daemon, but '$USER' IS a member of the
'docker' group per /etc/group.

This SSH session was spawned BEFORE the group membership took effect --
the cloud-init 'usermod -aG docker $USER' ran AFTER this shell already
existed, so the shell's effective groups don't include 'docker' and
talking to /var/run/docker.sock returns "permission denied."

Fix it with EITHER:

    exec newgrp docker          # promote this shell into the docker group,
                                # then re-run scripts/extract-poolparty-realm.sh

  -- OR --

    exit                        # log out
    ssh ...                     # log back in (new login picks up the group)

Verify with 'id -nG' before re-running; 'docker' must appear in the output.
EOF
        exit 1
    elif command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then
        cat >&2 <<EOF
ERROR: cannot reach the Docker daemon as '$USER', but 'sudo docker' works.

'$USER' is not in the 'docker' group. Add yourself and re-login:

    sudo usermod -aG docker $USER
    exit && ssh ...             # OR: exec newgrp docker

Verify with 'id -nG' before re-running; 'docker' must appear in the output.
EOF
        exit 1
    else
        cat >&2 <<EOF
ERROR: cannot reach the Docker daemon.

Check that the daemon is running:
    sudo systemctl status docker          # AL2023 / Linux
    open -a Docker                        # macOS Docker Desktop

If it is running, confirm your user can talk to it:
    docker info                           # should print server details

If the issue is group membership (most common on a fresh EC2 boot):
    id -nG                                # must include 'docker'
    sudo usermod -aG docker $USER         # if not, add yourself
    exec newgrp docker                    # then refresh this shell

Re-run this script once 'docker info' succeeds without sudo.
EOF
        exit 1
    fi
fi

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

# ---------------------------------------------------------------------------
# Chain into install-licenses.sh
# ---------------------------------------------------------------------------
# Both this script and install-licenses.sh are "after cluster-bootstrap.sh,
# before reset-helm.sh" prep steps. Running them as a single command means
# operators don't have to remember the second one (which is easy to forget
# now that this script handles two things). Pass through SKIP_LICENSES=1
# to opt out of the chain if you really do want extract-only.
if [ "${SKIP_LICENSES:-0}" = "1" ]; then
    echo "SKIP_LICENSES=1 set; not chaining into install-licenses.sh."
    echo "Next steps in the standard deploy flow:"
    echo "  ./scripts/install-licenses.sh"
    echo "  ./scripts/reset-helm.sh --yes <subdomain>      # or --skip-graphrag for umbrella-only"
    exit 0
fi

echo "============================================================================"
echo "  Chaining into scripts/install-licenses.sh (set SKIP_LICENSES=1 to opt out)"
echo "============================================================================"
exec "$SCRIPT_DIR/install-licenses.sh"
