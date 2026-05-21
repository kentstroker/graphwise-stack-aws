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
# (charts/graphdb/templates/security-init-job.yaml). Default admin
# password follows the repo's `rdf#rocks` convention (CLAUDE.md
# "Default password convention"). Rotate by editing the Secret and
# bouncing the security-init Job (or letting the next helm upgrade
# re-fire the post-upgrade hook).
if kubectl get namespace graphdb-adeptnova >/dev/null 2>&1; then
    create_or_replace graphdb-adeptnova graphdb-license graphdb.license "$LICENSES_DIR/graphdb.license"

    # Admin Secret. The chart's security-init Job reads this via
    # secretKeyRef to <fullname>-admin =
    # graphwise-stack-graphdb-adeptnova-admin.
    kubectl -n graphdb-adeptnova delete secret graphwise-stack-graphdb-adeptnova-admin --ignore-not-found
    kubectl -n graphdb-adeptnova create secret generic graphwise-stack-graphdb-adeptnova-admin \
        --from-literal=username=admin \
        --from-literal=password='rdf#rocks'
    echo "  ✓ graphdb-adeptnova/graphwise-stack-graphdb-adeptnova-admin (admin user)"
fi

echo
echo "License Secrets installed. Next: helm install the umbrella chart."
