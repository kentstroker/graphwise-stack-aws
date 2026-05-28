#!/usr/bin/env bash
# build-refine-image.sh -- wrap the platform-independent Refine zip
# in an arm64-compatible JRE container and load it into the KIND
# cluster's containerd. Idempotent: re-running rebuilds and reloads.
#
# Why this exists: ontotext/refine:1.2.x on Docker Hub is amd64-only
# and the canonical deploy is AL2023 Graviton. Graphwise also ships a
# platform-independent ZIP (Java app, no native binaries) which runs
# fine on arm64 under any JRE 11. Operators drop it under
# refine/ontorefine-1.2.1/; this script bakes it into a local image.
#
# Distribution: the Refine zip is gitignored (vendor binary, ~330MB).
# Treat like a license file -- obtain from Graphwise, extract once
# under refine/ in this repo, never commit.
#
# Outputs:
#   - docker image graphwise-refine:local on the host's Docker daemon
#   - same image loaded into the KIND node's containerd so the chart
#     can reference it with imagePullPolicy=IfNotPresent
#
# Idempotency:
#   - missing dist dir -> non-zero exit + clear "drop the zip here"
#     instructions. cluster-bootstrap.sh detects this before calling
#     us and skips silently, so the standard deploy path stays clean
#     for operators who don't need Refine.
#   - existing image: docker build re-uses cached layers; kind load
#     re-publishes (no-op if digest matches what's already in
#     containerd).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${REFINE_IMAGE:-graphwise-refine:local}"
KIND_CLUSTER="${KIND_CLUSTER_NAME:-graphwise}"
DIST_DIR="${REPO_ROOT}/refine/ontorefine-1.2.1"

if [ -t 1 ]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'
    BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; YELLOW=""; BOLD=""; RESET=""
fi

if [ ! -d "$DIST_DIR" ]; then
    cat >&2 <<EOF
${RED}ERROR:${RESET} Refine distribution missing at:
    $DIST_DIR

The extracted Refine 1.2.1 platform-independent dist normally ships
checked in to the repo. If it's missing here, you're probably on a
shallow / partial clone -- re-run \`git clone\` against this repo
without --depth, or \`git checkout\` the refine/ subtree if you're
on a sparse-checkout.

Set REFINE_IMAGE or KIND_CLUSTER_NAME if you need different names.
EOF
    exit 2
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "${RED}ERROR:${RESET} docker not on PATH." >&2
    exit 2
fi

if ! command -v kind >/dev/null 2>&1; then
    echo "${RED}ERROR:${RESET} kind not on PATH." >&2
    exit 2
fi

if ! kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then
    cat >&2 <<EOF
${RED}ERROR:${RESET} KIND cluster '$KIND_CLUSTER' doesn't exist.
Bring up the cluster first (cluster-bootstrap.sh / cluster-resume.sh),
or set KIND_CLUSTER_NAME to the right cluster name.
EOF
    exit 2
fi

echo "${BOLD}Building $IMAGE from $DIST_DIR ...${RESET}"
docker build \
    -t "$IMAGE" \
    -f "${REPO_ROOT}/infra/refine-image/Dockerfile" \
    "$REPO_ROOT"

echo
echo "${BOLD}Loading $IMAGE into kind cluster '$KIND_CLUSTER' ...${RESET}"
kind load docker-image "$IMAGE" --name "$KIND_CLUSTER"

echo
echo "${GREEN}OK${RESET} $IMAGE is now available to the cluster."
echo "Enable Refine in your per-deploy overlay (or via --set) with:"
echo "  addons:"
echo "    refine:"
echo "      enabled: true"
echo "      image:"
echo "        repository: graphwise-refine"
echo "        tag: local"
echo "        pullPolicy: IfNotPresent"
echo
echo "scripts/render-values.sh auto-emits this block when it detects"
echo "the dist directory exists; re-run reset-helm.sh and Refine will"
echo "deploy at https://refine.<sub>.<base>/ (CIDR-allowlisted via"
echo "terraform.tfvars admin_cidr)."
