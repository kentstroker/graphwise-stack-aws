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
    local secret_name="$1"
    local key_name="$2"
    local file_path="$3"

    kubectl -n "$NAMESPACE" delete secret "$secret_name" --ignore-not-found
    kubectl -n "$NAMESPACE" create secret generic "$secret_name" \
        --from-file="$key_name=$file_path"
    echo "  ✓ $secret_name (key=$key_name)"
}

create_or_replace poolparty-license    poolparty.key       "$LICENSES_DIR/poolparty.key"
create_or_replace graphdb-license      graphdb.license     "$LICENSES_DIR/graphdb.license"
create_or_replace unifiedviews-license uv-license.key      "$LICENSES_DIR/uv-license.key"

echo
echo "License Secrets installed. Next: helm install the umbrella chart."
