#!/usr/bin/env bash
# install-licenses.sh — kubectl-creates the three license Secrets that
# the chart Deployments mount as files.
#
# Run after scripts/cluster-bootstrap.sh and BEFORE installing the
# graphwise-stack umbrella chart. License files are vendor blobs that
# never enter git — copy them from your laptop to the EC2 with scp,
# then run this.
#
# Required files:
#   files/licenses/poolparty.key      → Secret poolparty-license
#   files/licenses/graphdb.license    → Secret graphdb-license
#   files/licenses/uv-license.key     → Secret unifiedviews-license
#
# Idempotent: re-runs replace the Secrets in place. Charts pick up new
# license content on the next pod restart.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LICENSES_DIR="$REPO_ROOT/files/licenses"

NAMESPACE="${NAMESPACE:-graphwise}"

echo "Installing license Secrets into namespace: $NAMESPACE"

# Verify all three files exist before we touch anything. Fail fast if a
# file is missing — better than partial install.
missing=0
for f in poolparty.key graphdb.license uv-license.key; do
    if [[ ! -f "$LICENSES_DIR/$f" ]]; then
        echo "MISSING: $LICENSES_DIR/$f"
        missing=1
    fi
done
if (( missing )); then
    echo
    echo "License files must be copied to $LICENSES_DIR/ before running this script."
    echo "From your laptop:"
    echo "  scp -i <key.pem> poolparty.key graphdb.license uv-license.key \\"
    echo "    ${USER}@<EIP>:$LICENSES_DIR/"
    exit 1
fi

# Verify the namespace exists.
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "ERROR: namespace '$NAMESPACE' does not exist."
    echo "Run scripts/cluster-bootstrap.sh first."
    exit 1
fi

create_or_replace() {
    local ns="$1"
    local secret_name="$2"
    local key_name="$3"
    local file_path="$4"

    kubectl -n "$ns" delete secret "$secret_name" --ignore-not-found
    kubectl -n "$ns" create secret generic "$secret_name" \
        --from-file="$key_name=$file_path"
    echo "  ✓ $ns/$secret_name (key=$key_name)"
}

create_or_replace "$NAMESPACE" poolparty-license    poolparty.key       "$LICENSES_DIR/poolparty.key"
create_or_replace "$NAMESPACE" graphdb-license      graphdb.license     "$LICENSES_DIR/graphdb.license"
create_or_replace "$NAMESPACE" unifiedviews-license uv-license.key      "$LICENSES_DIR/uv-license.key"

# graphdb-projects lives in its own namespace `graphdb` (split out from
# graphwise for logical separation -- see charts/graphwise-stack/values.yaml
# graphdb-projects.namespace). The graphdb-projects pod mounts
# graphdb-license from its own namespace, so we install a second copy
# there. Same license file, two namespaces -- no extra license entitlement
# consumed (Ontotext licenses by hardware, not by Secret count).
if kubectl get namespace graphdb >/dev/null 2>&1; then
    create_or_replace graphdb graphdb-license graphdb.license "$LICENSES_DIR/graphdb.license"
fi

# Third GraphDB instance (AdeptNova, added in RC2) lives in its own
# namespace `graphdb-adeptnova`. Needs the same license file AND an
# admin-credentials Secret consumed by the security-init Helm hook
# (charts/graphdb/templates/security-init-job.yaml). Unlike the other
# two GraphDB instances, this one is publicly reachable on host port
# 17200, so we generate strong credentials instead of using the
# repo's `rdf#rocks` convention:
#
#   - Username: adept-admin-<6 hex chars> (~24 bits of entropy)
#   - Password: 40-char URL-safe base64 (~240 bits of entropy)
#
# Both are persisted in $HOME/graphwise-secrets.yaml under the
# `graphdbAdeptnova` top-level key, so subsequent redeploys reuse the
# same credentials (operators logging into the Workbench don't need
# to chase a new password after every helm upgrade). The
# scripts/laptop/{pull,push}-config.sh pair preserves this block end-
# to-end, so the credentials follow the operator's snapshot.
#
# First-time generation also writes a chmod-0600 copy to
# $HOME/.graphwise-stack/adeptnova-credentials.txt for the operator
# to capture out-of-band -- the stdout banner can scroll off during
# a long reset-helm run.
if kubectl get namespace graphdb-adeptnova >/dev/null 2>&1; then
    create_or_replace graphdb-adeptnova graphdb-license graphdb.license "$LICENSES_DIR/graphdb.license"

    SECRETS_OVERLAY="${SECRETS_OVERLAY:-$HOME/graphwise-secrets.yaml}"
    CREDS_OUT_DIR="${CREDS_OUT_DIR:-$HOME/.graphwise-stack}"
    CREDS_OUT_FILE="$CREDS_OUT_DIR/adeptnova-credentials.txt"

    # Generate or read AdeptNova creds via Python -- yaml manipulation
    # in bash is too fragile. Returns four lines on stdout:
    #   ACTION|generated|reused
    #   USERNAME|<value>
    #   PASSWORD|<value>
    #   OVERLAY|<path>
    creds_out=$(SECRETS_OVERLAY="$SECRETS_OVERLAY" python3 <<'PY'
import os, secrets, string, sys
try:
    import yaml
except ImportError:
    print("ERROR|PyYAML not installed; install with: pip3 install --user pyyaml", file=sys.stderr)
    sys.exit(2)

overlay = os.environ["SECRETS_OVERLAY"]

# Load existing overlay (or start fresh).
data = {}
if os.path.isfile(overlay):
    with open(overlay) as f:
        data = yaml.safe_load(f) or {}

block = data.get("graphdbAdeptnova") or {}
username = (block.get("username") or "").strip()
password = (block.get("password") or "").strip()

action = "reused"
if not username or not password:
    action = "generated"
    if not username:
        # adept-admin-<6 hex>, ~24 bits of entropy in the username alone.
        username = "adept-admin-" + secrets.token_hex(3)
    if not password:
        # 30 bytes = 40 chars URL-safe base64, ~240 bits of entropy.
        # token_urlsafe gives us [A-Za-z0-9_-] -- safe in JSON, YAML,
        # HTTP Basic, and shell quoting.
        password = secrets.token_urlsafe(30)
    data["graphdbAdeptnova"] = {"username": username, "password": password}
    # Write back atomically.
    tmp = overlay + ".tmp"
    with open(tmp, "w") as f:
        yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)
    os.chmod(tmp, 0o600)
    os.replace(tmp, overlay)

print("ACTION|" + action)
print("USERNAME|" + username)
print("PASSWORD|" + password)
print("OVERLAY|" + overlay)
PY
    )
    if [ -z "$creds_out" ]; then
        echo "ERROR: AdeptNova credential generation failed (Python step returned empty)" >&2
        exit 1
    fi

    ADEPTNOVA_ACTION=$(echo "$creds_out" | awk -F'|' '/^ACTION\|/{print $2}')
    ADEPTNOVA_USER=$(echo "$creds_out"   | awk -F'|' '/^USERNAME\|/{print $2}')
    ADEPTNOVA_PW=$(echo "$creds_out"     | awk -F'|' '/^PASSWORD\|/{print $2}')

    # K8s Secret (always recreate; the chart's secretKeyRef reads it on
    # Job startup, so no rolling restart concern here).
    kubectl -n graphdb-adeptnova delete secret graphwise-stack-graphdb-adeptnova-admin --ignore-not-found
    kubectl -n graphdb-adeptnova create secret generic graphwise-stack-graphdb-adeptnova-admin \
        --from-literal=username="$ADEPTNOVA_USER" \
        --from-literal=password="$ADEPTNOVA_PW"
    echo "  ✓ graphdb-adeptnova/graphwise-stack-graphdb-adeptnova-admin (custom admin user)"

    # Surface to the operator. Banner to stdout + dedicated file
    # (chmod 0600) so the value survives a long reset-helm run.
    mkdir -p "$CREDS_OUT_DIR"
    chmod 0700 "$CREDS_OUT_DIR" 2>/dev/null || true
    umask 077
    cat > "$CREDS_OUT_FILE" <<CREDS
# graphdb-adeptnova admin credentials
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Source:    $SECRETS_OVERLAY (graphdbAdeptnova block)
#
# These credentials authenticate against the GraphDB Workbench / API
# on the AdeptNova instance. The default admin/root user is locked out
# by the post-install security-init Job -- only these credentials work.
#
# Use cases:
#   1. Browser admin:  https://graphdb-adeptnova.<apex>/
#                      nginx basic auth: demo / rdf#rocks
#                      GraphDB login:    \$USERNAME / \$PASSWORD  (these values)
#   2. Direct API:     http://<EIP>:17200/
#                      HTTP Basic:       \$USERNAME / \$PASSWORD  (these values)

USERNAME="$ADEPTNOVA_USER"
PASSWORD="$ADEPTNOVA_PW"
CREDS
    chmod 0600 "$CREDS_OUT_FILE"

    if [ "$ADEPTNOVA_ACTION" = "generated" ]; then
        cat <<BANNER

=============================================================================
  graphdb-adeptnova admin credentials -- NEWLY GENERATED -- SAVE THESE
=============================================================================
  Username:  $ADEPTNOVA_USER
  Password:  $ADEPTNOVA_PW

  Persisted in:  $SECRETS_OVERLAY  (graphdbAdeptnova block, chmod 0600)
  Saved copy:    $CREDS_OUT_FILE   (chmod 0600)

  Pull-config from your laptop preserves these across redeploys:
      ./scripts/laptop/pull-config.sh <snapshot-dir>

  After capture you can:    cat $CREDS_OUT_FILE
  Or to forget the file:    shred -u $CREDS_OUT_FILE
=============================================================================
BANNER
    else
        echo "  (re-using existing AdeptNova credentials from $SECRETS_OVERLAY)"
        echo "  ↳ to view them later:  cat $CREDS_OUT_FILE"
    fi
fi

echo
echo "License Secrets installed. Next: helm install the umbrella chart."
