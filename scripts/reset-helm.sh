#!/usr/bin/env bash
# reset-helm.sh — wipe and reinstall the graphwise-stack Helm release.
#
# Operator workflow during troubleshooting: edit chart values/templates,
# blow the existing release away (including PVCs so we start from blank
# data), re-render the per-subdomain values overlay, and `helm upgrade
# --install` from scratch.
#
# Does NOT touch:
#   - The cluster operators installed by scripts/cluster-bootstrap.sh
#     (ingress-nginx, cert-manager, cnpg, keycloak operator,
#     metrics-server). Those survive a reset and don't need rebuilding.
#   - The KIND cluster itself.
#   - The graphwise image-pull secret in the graphrag/graphwise
#     namespaces (still needed; rebuilt by cluster-bootstrap.sh, not us).
#
# Does delete:
#   - helm release graphwise-stack in namespace graphwise
#   - all PVCs in namespaces graphwise, keycloak, graphrag (data loss)
#   - any leftover Secrets/ConfigMaps from the umbrella's templates/
#
# Usage:
#   ./scripts/reset-helm.sh <subdomain> [base_domain]
#   ./scripts/reset-helm.sh --yes <subdomain> [base_domain]
#
# Without --yes, prompts before the destructive steps. Subdomain is
# required so we can re-render the values overlay; base_domain defaults
# to semantic-proof.com (matching scripts/render-values.sh).
#
# Env overrides:
#   RELEASE_NAME       (default: graphwise-stack)
#   RELEASE_NAMESPACE  (default: graphwise)
#   VALUES_FILE        (default: /tmp/values-<subdomain>.yaml)
#   HELM_TIMEOUT       (default: 15m)
#
# Idempotent. Safe to re-run; uninstalls/deletes use --ignore-not-found
# semantics where possible.

set -euo pipefail

# ---------------------------------------------------------------------
# Argument parsing -- accept --yes anywhere on the command line, then
# positional <subdomain> [base_domain]. Earlier version only honored
# --yes as the first arg, which caused later --yes to silently land in
# the base_domain slot and produce ingress hostnames like
# "<app>.<sub>.--yes".
# ---------------------------------------------------------------------
ASSUME_YES=0
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes)
            ASSUME_YES=1
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--yes] <subdomain> [base_domain]"
            exit 0
            ;;
        --)
            shift
            POSITIONAL+=("$@")
            break
            ;;
        -*)
            echo "ERROR: unknown flag '$1'" >&2
            echo "Usage: $0 [--yes] <subdomain> [base_domain]" >&2
            exit 1
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done
set -- "${POSITIONAL[@]}"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 [--yes] <subdomain> [base_domain]" >&2
    exit 1
fi

SUB="$1"
BASE="${2:-semantic-proof.com}"

# Belt-and-braces: validate the rendered components against RFC 1123
# before we touch anything, so a typo can't get as far as a half-failed
# helm install.
hostname_re='^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$'
if [[ ! "$SUB" =~ $hostname_re ]]; then
    echo "ERROR: subdomain '$SUB' is not a valid RFC 1123 label." >&2
    exit 1
fi
if [[ ! "$BASE" =~ $hostname_re ]]; then
    echo "ERROR: base_domain '$BASE' is not a valid RFC 1123 hostname." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Two Helm releases:
#   - graphwise-stack: umbrella (PoolParty + GraphDB + addons + console
#                      + Keycloak CR + supporting graphrag Secrets/n8n
#                      Postgres in the graphrag namespace).
#   - graphrag:        vendored chatbot/conversation/components/workflows
#                      pods. Lives in the graphrag namespace so it can
#                      mount the supporting Secrets the umbrella
#                      created there.
UMBRELLA_RELEASE="${UMBRELLA_RELEASE:-graphwise-stack}"
UMBRELLA_NAMESPACE="${UMBRELLA_NAMESPACE:-graphwise}"
GRAPHRAG_RELEASE="${GRAPHRAG_RELEASE:-graphrag}"
GRAPHRAG_NAMESPACE="${GRAPHRAG_NAMESPACE:-graphrag}"
HELM_TIMEOUT="${HELM_TIMEOUT:-15m}"

UMBRELLA_VALUES="${UMBRELLA_VALUES:-/tmp/values-${SUB}.yaml}"
GRAPHRAG_VALUES="${GRAPHRAG_VALUES:-/tmp/values-${SUB}-graphrag.yaml}"

# Optional auto-generated secrets overlay written by Terraform's
# cloud-init (~/graphwise-secrets.yaml). Currently holds the n8n
# encryption key (random per deployment, must stay stable across
# resets). Auto-included if present; missing is fine.
SECRETS_OVERLAY="${SECRETS_OVERLAY:-$HOME/graphwise-secrets.yaml}"

UMBRELLA_CHART_DIR="$REPO_ROOT/charts/graphwise-stack"
UMBRELLA_BASE_VALUES="$UMBRELLA_CHART_DIR/values.yaml"
GRAPHRAG_CHART_DIR="$REPO_ROOT/charts/vendor/graphrag"
GRAPHRAG_BASE_VALUES="$GRAPHRAG_CHART_DIR/values-graphwise.yaml"

# Tooling sanity.
for cmd in kubectl helm; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: $cmd not found in PATH." >&2
        exit 1
    fi
done

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "ERROR: kube API not reachable. Run scripts/cluster-resume.sh first?" >&2
    exit 1
fi

# ---------------------------------------------------------------------
# Confirm
# ---------------------------------------------------------------------
echo "About to reset Helm releases for subdomain '$SUB.$BASE':"
echo "  - helm uninstall $GRAPHRAG_RELEASE -n $GRAPHRAG_NAMESPACE  (graphrag pods first)"
echo "  - helm uninstall $UMBRELLA_RELEASE -n $UMBRELLA_NAMESPACE  (umbrella second)"
echo "  - kubectl delete pvc --all in: graphwise, keycloak, graphrag"
echo "  - regenerate $UMBRELLA_VALUES + $GRAPHRAG_VALUES"
echo "  - helm dependency update on both charts"
echo "  - helm upgrade --install $UMBRELLA_RELEASE first, then $GRAPHRAG_RELEASE"
echo "  - timeout per release: $HELM_TIMEOUT"
echo
echo "DATA LOSS: every PVC in those three namespaces will be deleted."
echo

if [[ $ASSUME_YES -ne 1 ]]; then
    read -r -p "Type 'reset' to proceed: " confirm
    if [[ "$confirm" != "reset" ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# ---------------------------------------------------------------------
# 1. Helm uninstall (graphrag first so its pods stop mounting Secrets
#    that the umbrella owns)
# ---------------------------------------------------------------------
if helm status "$GRAPHRAG_RELEASE" -n "$GRAPHRAG_NAMESPACE" >/dev/null 2>&1; then
    echo "Uninstalling graphrag release..."
    helm uninstall "$GRAPHRAG_RELEASE" -n "$GRAPHRAG_NAMESPACE" --wait --timeout 5m || true
else
    echo "graphrag release not present -- skipping."
fi

if helm status "$UMBRELLA_RELEASE" -n "$UMBRELLA_NAMESPACE" >/dev/null 2>&1; then
    echo "Uninstalling umbrella release..."
    helm uninstall "$UMBRELLA_RELEASE" -n "$UMBRELLA_NAMESPACE" --wait --timeout 5m || true
else
    echo "Umbrella release not present -- skipping."
fi

# ---------------------------------------------------------------------
# 2. PVC cleanup
# ---------------------------------------------------------------------
# Helm uninstall deliberately does NOT delete PVCs (StatefulSet behavior).
# For a troubleshooting reset we want a blank slate.
echo "Deleting PVCs in graphwise, keycloak, graphrag namespaces..."
for ns in graphwise keycloak graphrag; do
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        kubectl delete pvc --all -n "$ns" --wait=false --ignore-not-found || true
    fi
done

# Wait briefly for PVCs to actually go. CNPG / Keycloak operators may
# re-create them otherwise once the chart is re-applied -- that's fine,
# the goal here is just to ensure the OLD ones are gone.
echo "Waiting for PVCs to terminate..."
deadline=$(( $(date +%s) + 60 ))
while :; do
    leftover=0
    for ns in graphwise keycloak graphrag; do
        if kubectl get namespace "$ns" >/dev/null 2>&1; then
            count=$(kubectl get pvc -n "$ns" --no-headers 2>/dev/null | wc -l)
            leftover=$(( leftover + count ))
        fi
    done
    if [[ $leftover -eq 0 ]]; then break; fi
    if (( $(date +%s) >= deadline )); then
        echo "WARN: PVCs still terminating after 60s, continuing anyway." >&2
        break
    fi
    sleep 3
done

# ---------------------------------------------------------------------
# 3. Re-render both values overlays
# ---------------------------------------------------------------------
echo "Rendering values overlays..."
"$SCRIPT_DIR/render-values.sh" --umbrella "$SUB" "$BASE" > "$UMBRELLA_VALUES"
"$SCRIPT_DIR/render-values.sh" --graphrag "$SUB" "$BASE" > "$GRAPHRAG_VALUES"
echo "  $UMBRELLA_VALUES"
echo "  $GRAPHRAG_VALUES"

# ---------------------------------------------------------------------
# 4. Helm dep update on BOTH chart paths
# ---------------------------------------------------------------------
# The vendor graphrag chart has its own dependencies (chatbot,
# conversation, components, workflows) that helm dep update on the
# umbrella does NOT recurse into. Skipping this is what produced
# `kubectl get pods -n graphrag` showing only postgres after a
# previous reset -- the chart packaged into the umbrella tarball had
# no inner subchart tarballs.
echo "Updating chart dependencies..."
helm dependency update "$GRAPHRAG_CHART_DIR"
helm dependency update "$UMBRELLA_CHART_DIR"

# ---------------------------------------------------------------------
# 4a. Image-pull secret for maven.ontotext.com (graphrag pods)
# ---------------------------------------------------------------------
# The graphrag release pulls private images from maven.ontotext.com.
# It needs a `graphwise` Secret of type kubernetes.io/dockerconfigjson
# in the graphrag namespace. We also create it in the graphwise
# namespace because the umbrella's global.imagePullSecrets
# references it (most umbrella images are public on Docker Hub so
# the secret existing is a no-op for them, but it keeps the
# imagePullSecrets reference from being an orphan).
#
# Moved here from cluster-bootstrap.sh -- this is the script that
# actually installs the chart that consumes it. If maven creds aren't
# on disk, we WARN and continue: the umbrella installs fine without
# them; only the graphrag release's pods will ImagePullBackOff.
if [[ -f "$HOME/.ontotext/maven-user" && -f "$HOME/.ontotext/maven-pass" ]]; then
    MAVEN_USER=$(tr -d '[:space:]' < "$HOME/.ontotext/maven-user")
    MAVEN_PASS=$(tr -d '[:space:]' < "$HOME/.ontotext/maven-pass")
    for ns in "$UMBRELLA_NAMESPACE" "$GRAPHRAG_NAMESPACE"; do
        kubectl get namespace "$ns" >/dev/null 2>&1 || kubectl create namespace "$ns"
        kubectl -n "$ns" delete secret graphwise --ignore-not-found
        kubectl -n "$ns" create secret docker-registry graphwise \
            --docker-server=maven.ontotext.com \
            --docker-username="$MAVEN_USER" \
            --docker-password="$MAVEN_PASS"
    done
    echo "Created 'graphwise' image-pull secret in: $UMBRELLA_NAMESPACE, $GRAPHRAG_NAMESPACE"
else
    echo "WARNING: ~/.ontotext/maven-user and/or maven-pass not found."
    echo "         Skipping image-pull secret. The umbrella release will"
    echo "         install fine, but graphrag pods (chatbot, conversation,"
    echo "         components, workflows) will ImagePullBackOff until you"
    echo "         drop the maven creds and re-run this script (or run:"
    echo "         kubectl -n $GRAPHRAG_NAMESPACE create secret docker-registry graphwise ...)"
fi

# Build the -f flag list. Auto-include the secrets overlay only if it
# exists (Terraform's cloud-init writes it; manual installs may not
# have one). Built as a bash array so values with spaces survive,
# expanded inline below.
UMBRELLA_F_FLAGS=(-f "$UMBRELLA_BASE_VALUES" -f "$UMBRELLA_VALUES")
GRAPHRAG_F_FLAGS=(-f "$GRAPHRAG_BASE_VALUES" -f "$GRAPHRAG_VALUES")
if [[ -f "$SECRETS_OVERLAY" ]]; then
    echo "Including secrets overlay: $SECRETS_OVERLAY"
    UMBRELLA_F_FLAGS+=(-f "$SECRETS_OVERLAY")
fi

# ---------------------------------------------------------------------
# 5. Install umbrella first (creates Secrets/Postgres in graphrag ns
#    that the graphrag release pods will mount)
# ---------------------------------------------------------------------
echo "Installing umbrella release '$UMBRELLA_RELEASE' (timeout $HELM_TIMEOUT)..."
# Single-line invocation on purpose -- line-continuations in pasted
# commands have bitten us before (bash splitting --timeout 15m).
helm upgrade --install "$UMBRELLA_RELEASE" "$UMBRELLA_CHART_DIR" -n "$UMBRELLA_NAMESPACE" --create-namespace "${UMBRELLA_F_FLAGS[@]}" --timeout "$HELM_TIMEOUT"

# ---------------------------------------------------------------------
# 6. Install graphrag release in its own namespace
# ---------------------------------------------------------------------
echo "Installing graphrag release '$GRAPHRAG_RELEASE' (timeout $HELM_TIMEOUT)..."
helm upgrade --install "$GRAPHRAG_RELEASE" "$GRAPHRAG_CHART_DIR" -n "$GRAPHRAG_NAMESPACE" --create-namespace "${GRAPHRAG_F_FLAGS[@]}" --timeout "$HELM_TIMEOUT"

echo
echo "=== Reset complete ==="
echo "Watch pods come up:"
echo "  kubectl get pods -A -w"
