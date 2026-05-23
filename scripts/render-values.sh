#!/usr/bin/env bash
# render-values.sh — given a teammate's subdomain, emit Helm values
# overlays for the two releases this stack uses:
#
#   1. graphwise-stack    (in graphwise namespace)  -- umbrella overlay
#   2. graphrag           (in graphrag  namespace)  -- chatbot/etc overlay
#
# We emit two separate files because the GraphRAG charts are now a
# separate Helm release (see CLAUDE.md "Two Helm releases" -- the
# vendored chart's resources default to the release namespace, and
# GraphRAG pods need to live in `graphrag` to mount the supporting
# Secrets the umbrella creates there).
#
# ============================================================
#  YOU USUALLY DO NOT RUN THIS SCRIPT MANUALLY.
# ============================================================
# scripts/reset-helm.sh auto-invokes this script twice (once with
# --umbrella, once with --graphrag) before each `helm upgrade --install`,
# writing the rendered overlays to $HOME/.graphwise-stack/values-<sub>.yaml
# and $HOME/.graphwise-stack/values-<sub>-graphrag.yaml. The standard
# deploy flow is just `./scripts/reset-helm.sh --yes <subdomain>` -- no
# need to call this script first.
#
# Run it manually only when you want to:
#   - Inspect the rendered overlay before applying.
#   - Feed it into a non-destructive `helm upgrade` (without the
#     PVC-deleting reset that reset-helm.sh performs).
#   - Pipe the rendered overlay somewhere else (--umbrella / --graphrag
#     write to stdout).
#
# Usage:
#   ./scripts/render-values.sh stroker
#     -> $HOME/.graphwise-stack/values-stroker.yaml          (umbrella overlay)
#     -> $HOME/.graphwise-stack/values-stroker-graphrag.yaml (graphrag overlay)
#
#   ./scripts/render-values.sh stroker semantic-proof.com
#     same, with explicit base domain.
#
#   ./scripts/render-values.sh --umbrella stroker > custom.yaml
#     emit ONLY the umbrella overlay to stdout (legacy behavior).
#
#   ./scripts/render-values.sh --graphrag stroker > custom.yaml
#     emit ONLY the graphrag overlay to stdout.
#
# OUT_DIR overrides the default $HOME/.graphwise-stack location.
# (Persistent across reboots -- earlier versions wrote to /tmp, which
# AL2023's systemd-tmpfiles wipes on every boot.)

set -euo pipefail

MODE=both
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --umbrella) MODE=umbrella; shift ;;
        --graphrag) MODE=graphrag; shift ;;
        --both)     MODE=both;     shift ;;
        -h|--help)
            echo "Usage: $0 [--umbrella|--graphrag|--both] <subdomain> [base_domain]"
            exit 0 ;;
        --) shift; POSITIONAL+=("$@"); break ;;
        -*) echo "ERROR: unknown flag '$1'" >&2; exit 1 ;;
        *)  POSITIONAL+=("$1"); shift ;;
    esac
done
set -- "${POSITIONAL[@]}"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 [--umbrella|--graphrag|--both] <subdomain> [base_domain]" >&2
    exit 1
fi

SUB="$1"
BASE="${2:-semantic-demo.com}"
OUT_DIR="${OUT_DIR:-$HOME/.graphwise-stack}"

# Apex + per-app hostnames.
APEX="${SUB}.${BASE}"
PP_HOST="poolparty.${APEX}"
AUTH_HOST="auth.${APEX}"
GRAPHRAG_HOST="graphrag.${APEX}"
GDB_E_HOST="graphdb.${APEX}"
GDB_P_HOST="graphdb-projects.${APEX}"
GDB_A_HOST="graphdb-adeptnova.${APEX}"
ADF_HOST="adf.${APEX}"
SW_HOST="semantic-workbench.${APEX}"
GV_HOST="graphviews.${APEX}"
RDF4J_HOST="rdf4j.${APEX}"
UV_HOST="unifiedviews.${APEX}"
REFINE_HOST="refine.${APEX}"

# ---------------------------------------------------------------------
# Refine ingress is CIDR-allowlisted using the same CIDR that gates
# SSH/admin in the Terraform layer. tfvars is the single source of
# truth -- read it here so deploy-time changes there propagate without
# manual sync. If tfvars is missing or admin_cidr can't be parsed, the
# stack still deploys; the ingress just isn't restricted (a WARN is
# printed).
# ---------------------------------------------------------------------
TFVARS_PATH="${TFVARS_PATH:-$(cd "$(dirname "$0")/.." && pwd)/infra/terraform/terraform.tfvars}"
if [ -f "$TFVARS_PATH" ]; then
    ADMIN_CIDR=$(grep -E '^[[:space:]]*admin_cidr[[:space:]]*=' "$TFVARS_PATH" \
                  | sed -E 's/#.*//' | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/' | head -n1)
fi
if [ -z "${ADMIN_CIDR:-}" ]; then
    echo "WARN: could not parse admin_cidr from $TFVARS_PATH -- Refine ingress will not be CIDR-restricted" >&2
    ADMIN_CIDR="0.0.0.0/0"
elif ! [[ "$ADMIN_CIDR" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; then
    # Defense in depth: if the sed pipeline produces something that
    # isn't a valid IPv4 CIDR (e.g. tfvars writes admin_cidr unquoted,
    # which is invalid HCL but caught only at apply time), fail loud
    # rather than emit garbage into the ingress annotation.
    echo "WARN: admin_cidr parsed as '$ADMIN_CIDR' which is not a valid IPv4 CIDR -- Refine ingress will not be CIDR-restricted" >&2
    ADMIN_CIDR="0.0.0.0/0"
fi

# ---------------------------------------------------------------------
# Umbrella overlay (graphwise-stack release)
# ---------------------------------------------------------------------
render_umbrella() {
    cat <<EOF
# Generated by scripts/render-values.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# subdomain=${SUB} baseDomain=${BASE}
# For: helm upgrade --install graphwise-stack ./charts/graphwise-stack -n graphwise
# Do not commit this file -- values are derived; regenerate any time.

global:
  subdomain: "${SUB}"
  baseDomain: "${BASE}"

# Pass subdomain + baseDomain explicitly to the keycloak-realms subchart.
# Helm's globals propagation (.Values.global.* in subchart context) is
# unreliable in our render path; explicit subchart-namespace values are
# guaranteed to land. Without these, the graphrag realm import renders
# chatbot-app-client redirectUris with empty subdomain/baseDomain and
# the chatbot login fails with "Invalid parameter: redirect_url".
keycloak-realms:
  subdomain: "${SUB}"
  baseDomain: "${BASE}"

graphdb-embedded:
  externalUrl: "https://${GDB_E_HOST}/"
  ingress:
    host: "${GDB_E_HOST}"

graphdb-projects:
  externalUrl: "https://${GDB_P_HOST}/"
  ingress:
    host: "${GDB_P_HOST}"

graphdb-adeptnova:
  externalUrl: "https://${GDB_A_HOST}/"
  ingress:
    host: "${GDB_A_HOST}"

poolparty:
  externalUrl: "https://${PP_HOST}/"
  keycloak:
    authUrl: "https://${AUTH_HOST}/"
  cors:
    allowedOrigins: "https://${PP_HOST},https://${GRAPHRAG_HOST}"
  urlBase:
    scheme: "https://${PP_HOST}"
    vocabulary: "https://${PP_HOST}"
    user: "https://${PP_HOST}/user"
    context: "https://${PP_HOST}"
  ingress:
    host: "${PP_HOST}"

console:
  ingress:
    host: "${APEX}"

addons:
  adf:
    externalUrl: "https://${ADF_HOST}"
    keycloak:
      url: "https://${AUTH_HOST}/"
  semantic-workbench:
    externalUrl: "https://${SW_HOST}"
    keycloak:
      url: "https://${AUTH_HOST}/"
  graphviews:
    externalUrl: "https://${GV_HOST}"
  rdf4j:
    externalUrl: "https://${RDF4J_HOST}"
  unifiedviews:
    externalUrl: "https://${UV_HOST}"
  refine:
    externalUrl: "https://${REFINE_HOST}"
    allowedCidrs: ["${ADMIN_CIDR}"]
EOF
}

# ---------------------------------------------------------------------
# Graphrag overlay (graphrag release, in graphrag namespace)
# Layered on top of charts/vendor/graphrag/values-graphwise.yaml which
# carries the deployment-agnostic constants (existingProperties,
# in-cluster Keycloak URLs, n8n license/encryption secret refs, etc).
# This file holds only the per-subdomain bits.
# ---------------------------------------------------------------------
render_graphrag() {
    cat <<EOF
# Generated by scripts/render-values.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# subdomain=${SUB} baseDomain=${BASE}
# For: helm upgrade --install graphrag ./charts/vendor/graphrag -n graphrag \\
#        -f charts/vendor/graphrag/values-graphwise.yaml \\
#        -f $(basename "$OUT_DIR/values-${SUB}-graphrag.yaml")
# Do not commit this file -- values are derived; regenerate any time.

chatbot:
  configuration:
    externalUrl: "https://${GRAPHRAG_HOST}/"
    properties:
      GRAPHRAG_BACKEND_URL: "https://${GRAPHRAG_HOST}/conversations"
      GRAPHRAG_KEYCLOAK_URL: "https://${AUTH_HOST}/"
      GRAPHRAG_KEYCLOAK_REALM: graphrag
      GRAPHRAG_KEYCLOAK_CLIENT_ID: chatbot-app-client
  ingress:
    enabled: true
    className: nginx
    host: "${GRAPHRAG_HOST}"
    tls:
      enabled: true
      secretName: wildcard-tls

conversation:
  configuration:
    properties:
      spring.security.oauth2.resourceserver.jwt.issuer-uri: "https://${AUTH_HOST}/realms/graphrag"

workflows:
  ingress:
    enabled: true
    className: nginx
    host: "${GRAPHRAG_HOST}"
    annotations:
      nginx.ingress.kubernetes.io/rewrite-target: /\$2
    tls:
      enabled: true
      secretName: wildcard-tls
  configuration:
    externalUrl: "https://${GRAPHRAG_HOST}/graphrag/workflows/"
EOF
}

# ---------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------
case "$MODE" in
    umbrella)
        render_umbrella ;;
    graphrag)
        render_graphrag ;;
    both)
        mkdir -p "$OUT_DIR"
        UMBRELLA_OUT="$OUT_DIR/values-${SUB}.yaml"
        GRAPHRAG_OUT="$OUT_DIR/values-${SUB}-graphrag.yaml"
        render_umbrella > "$UMBRELLA_OUT"
        render_graphrag > "$GRAPHRAG_OUT"
        echo "Wrote:"
        echo "  $UMBRELLA_OUT"
        echo "  $GRAPHRAG_OUT"
        ;;
esac
