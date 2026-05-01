#!/usr/bin/env bash
# cluster-resume.sh — restart the KIND cluster after an EC2 stop/start.
#
# KIND runs each node as a Docker container. docker.service comes back
# automatically on boot, but containers without a restart policy stay
# Exited — so kubectl fails with "connection refused on 127.0.0.1:6443"
# until the node containers are started again.
#
# This script:
#   1. Verifies a KIND cluster named "graphwise" exists.
#   2. Starts every node container belonging to that cluster.
#   3. Sets restart=unless-stopped on each so subsequent reboots are
#      a non-event (idempotent — re-running just re-asserts the policy).
#   4. Waits until the kube API answers, then prints node + pod status.
#
# Run as ec2-user (the same user that created the cluster).
# Idempotent: safe to re-run any time. If the cluster is already
# healthy this script is a no-op aside from re-asserting restart policy.
#
# Usage:
#   ./scripts/cluster-resume.sh
#
# Exits non-zero if the cluster doesn't exist or the API never comes
# back within the timeout (default 180s; override with API_TIMEOUT).

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-graphwise}"
API_TIMEOUT="${API_TIMEOUT:-180}"

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker not found in PATH." >&2
    exit 1
fi
if ! command -v kind >/dev/null 2>&1; then
    echo "ERROR: kind not found in PATH." >&2
    exit 1
fi
if ! command -v kubectl >/dev/null 2>&1; then
    echo "ERROR: kubectl not found in PATH." >&2
    exit 1
fi

if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    echo "ERROR: KIND cluster '$CLUSTER_NAME' does not exist." >&2
    echo "       Create it first with:" >&2
    echo "         kind create cluster --name $CLUSTER_NAME --config infra/kind/kind-config.yaml" >&2
    exit 1
fi

# KIND names node containers "<cluster>-control-plane", "<cluster>-worker",
# "<cluster>-worker2", etc. Match by the io.x-k8s.kind.cluster label so we
# don't accidentally pick up unrelated containers that happen to share a
# prefix.
mapfile -t NODES < <(docker ps -a \
    --filter "label=io.x-k8s.kind.cluster=$CLUSTER_NAME" \
    --format '{{.Names}}')

if [[ ${#NODES[@]} -eq 0 ]]; then
    echo "ERROR: no docker containers found for KIND cluster '$CLUSTER_NAME'." >&2
    echo "       The cluster may have been removed manually. Re-create with:" >&2
    echo "         kind create cluster --name $CLUSTER_NAME --config infra/kind/kind-config.yaml" >&2
    exit 1
fi

echo "Found ${#NODES[@]} node container(s) for cluster '$CLUSTER_NAME':"
printf '  %s\n' "${NODES[@]}"

echo "Starting node containers (no-op if already running)..."
for node in "${NODES[@]}"; do
    docker start "$node" >/dev/null
done

echo "Setting restart=unless-stopped on each node container..."
for node in "${NODES[@]}"; do
    docker update --restart=unless-stopped "$node" >/dev/null
done

# Make sure kubectl points at this cluster — kind create writes the
# context, but a bare resume after a reboot won't, and the user may
# have switched contexts in between.
kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null

echo "Waiting up to ${API_TIMEOUT}s for the kube API to answer..."
deadline=$(( $(date +%s) + API_TIMEOUT ))
until kubectl get --raw=/readyz >/dev/null 2>&1; do
    if (( $(date +%s) >= deadline )); then
        echo "ERROR: kube API did not become ready within ${API_TIMEOUT}s." >&2
        echo "       Check container logs:" >&2
        echo "         docker logs --tail 100 ${NODES[0]}" >&2
        exit 1
    fi
    sleep 3
done

echo
echo "=== Cluster '$CLUSTER_NAME' is back up ==="
kubectl get nodes
echo
kubectl get pods -A
