#!/usr/bin/env bash
# switch-cert-issuer.sh -- flip every Ingress's cert-manager
# annotation between letsencrypt-staging (default) and letsencrypt-prod.
#
# Why this script exists: a vanilla `helm upgrade --set
# global.clusterIssuer=letsencrypt-prod ...` rewrites the Ingress
# annotations but the existing Certificate resources still have an
# issuerRef field pointing at the OLD issuer -- cert-manager won't
# auto-recreate them. This script does both jobs:
#   1. Patches every Ingress's cert-manager.io/cluster-issuer
#      annotation cluster-wide (every namespace).
#   2. Deletes every existing Certificate resource so cert-manager's
#      ingress-shim recreates them with the new issuer.
#   3. Watches certs come back Ready (or 10-min timeout).
#
# Operator workflow:
#   - Stack iteration / SE-internal validation: stay on staging
#     (default). Browsers warn "Not Secure" but rate limits are
#     effectively unlimited.
#   - Right before a customer demo: ./scripts/switch-cert-issuer.sh prod
#     waits ~5-10 min for LE prod to issue real certs, then browsers
#     show valid TLS.
#   - Post-demo, back to iteration: ./scripts/switch-cert-issuer.sh staging
#
# LE prod has 5 cert/identifier/168h rate limits. Multiple flips to
# prod in a week WILL hit them; the script aborts with a clear error
# from cert-manager's Order if so. Mitigation: only flip to prod when
# you actually need browser-trusted certs.
#
# Exit codes:
#   0 -- switch completed; all Certificates Ready=True
#   1 -- switch initiated but one or more Certificates failed to issue
#        within the timeout (rate limit, DNS issue, etc.)
#   2 -- usage error (bad arg, missing ClusterIssuer, etc.)

set -euo pipefail

if [ -t 1 ]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; YELLOW=""; CYAN=""; BOLD=""; DIM=""; RESET=""
fi

usage() {
    cat <<EOF
Usage: $0 <staging|prod> [--yes]

  staging  switch every Ingress to letsencrypt-staging (rate-limit-free,
           but browsers warn "Not Secure")
  prod     switch every Ingress to letsencrypt-prod    (real certs;
           5/identifier/168h rate limit -- use sparingly)

  --yes    skip the destructive-confirmation prompt
EOF
    exit 2
}

[ $# -lt 1 ] && usage

TARGET="$1"
SKIP_CONFIRM=no
shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --yes) SKIP_CONFIRM=yes; shift ;;
        *) echo "Unknown flag: $1" >&2; usage ;;
    esac
done

case "$TARGET" in
    staging) ISSUER=letsencrypt-staging ;;
    prod)    ISSUER=letsencrypt-prod ;;
    *)       echo "ERROR: target must be 'staging' or 'prod', got '$TARGET'" >&2; usage ;;
esac

# Sanity: ClusterIssuer must exist + Ready in the cluster.
if ! kubectl get clusterissuer "$ISSUER" >/dev/null 2>&1; then
    echo "${RED}ERROR:${RESET} ClusterIssuer '$ISSUER' not found in cluster." >&2
    echo "Run scripts/cluster-bootstrap.sh first -- it creates both" >&2
    echo "letsencrypt-staging and letsencrypt-prod." >&2
    exit 2
fi
status=$(kubectl get clusterissuer "$ISSUER" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
if [ "$status" != "True" ]; then
    echo "${RED}ERROR:${RESET} ClusterIssuer '$ISSUER' exists but Ready=$status (expected True)." >&2
    echo "kubectl describe clusterissuer $ISSUER" >&2
    exit 2
fi

# Detect what's currently in use.
CURRENT=$(kubectl get certificate -A -o jsonpath='{.items[0].spec.issuerRef.name}' 2>/dev/null || echo "")
if [ -z "$CURRENT" ]; then
    CURRENT="(no Certificates found -- first switch?)"
fi

cat <<HEADER

${BOLD}${CYAN}Cert-issuer switch:${RESET}  ${BOLD}$CURRENT  →  $ISSUER${RESET}

This will:
  ${DIM}1.${RESET} Patch every Ingress cluster-wide to use
      ${BOLD}cert-manager.io/cluster-issuer: $ISSUER${RESET}
  ${DIM}2.${RESET} Delete every existing Certificate resource (cert-manager
      will recreate them with the new issuer).
  ${DIM}3.${RESET} Wait up to 10 minutes for new certs to issue.

HEADER

if [ "$ISSUER" = "letsencrypt-prod" ]; then
    cat <<RATELIMIT
${YELLOW}${BOLD}⚠  letsencrypt-prod rate limits:${RESET}
  ${DIM}5 certs per identical identifier per 168h. Multiple flips to prod
  in a week will hit the cap. Use sparingly -- only when you actually
  need browser-trusted certs (right before a customer demo).${RESET}

RATELIMIT
fi

if [ "$SKIP_CONFIRM" != "yes" ]; then
    printf 'Proceed? [yes/N] '
    read -r reply
    if [ "$reply" != "yes" ]; then
        echo "Aborted."
        exit 0
    fi
fi

echo
echo "${BOLD}Step 1/3:${RESET} patching Ingress annotations..."
INGRESS_COUNT=0
while IFS=$'\t' read -r ns name; do
    [ -z "$ns" ] && continue
    if kubectl annotate ingress -n "$ns" "$name" "cert-manager.io/cluster-issuer=$ISSUER" --overwrite >/dev/null 2>&1; then
        INGRESS_COUNT=$((INGRESS_COUNT + 1))
        printf '  %s%s%s -> %s%s%s/%s%s%s\n' "$GREEN" "✓" "$RESET" "$DIM" "$ns" "$RESET" "$BOLD" "$name" "$RESET"
    else
        printf '  %s%s%s patch failed: %s/%s\n' "$RED" "✗" "$RESET" "$ns" "$name"
    fi
done < <(kubectl get ingress -A --no-headers -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name 2>/dev/null | tr -s ' ' '\t')
echo "  $INGRESS_COUNT Ingress(es) patched."

echo
echo "${BOLD}Step 2/3:${RESET} deleting Certificate resources (cert-manager will recreate)..."
CERT_COUNT=$(kubectl get certificate -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$CERT_COUNT" -gt 0 ]; then
    kubectl delete certificate -A --all >/dev/null 2>&1
    echo "  $CERT_COUNT Certificate(s) deleted."
else
    echo "  No existing Certificates -- cert-manager will create from scratch."
fi

# Also delete the corresponding TLS secrets so cert-manager regens them
# rather than reuses stale ones (LE prod chain != LE staging chain;
# reusing the old Secret would serve the wrong chain).
echo
echo "${BOLD}Step 3/3:${RESET} deleting old TLS Secrets (cert-manager will repopulate)..."
TLS_COUNT=0
while IFS=$'\t' read -r ns name; do
    [ -z "$ns" ] && continue
    if kubectl delete secret -n "$ns" "$name" >/dev/null 2>&1; then
        TLS_COUNT=$((TLS_COUNT + 1))
    fi
done < <(kubectl get secret -A --field-selector type=kubernetes.io/tls --no-headers -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name 2>/dev/null | tr -s ' ' '\t')
echo "  $TLS_COUNT TLS Secret(s) deleted."

echo
echo "${BOLD}Waiting for new Certificates to issue (up to 10 min)...${RESET}"
echo "${DIM}cert-manager's ingress-shim will recreate Certificate resources from the patched Ingress annotations.${RESET}"
echo

# Poll every 15s, max 10 min.
WAITED=0
TIMEOUT=600
while [ $WAITED -lt $TIMEOUT ]; do
    sleep 15
    WAITED=$((WAITED + 15))
    total=$(kubectl get certificate -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
    ready=$(kubectl get certificate -A --no-headers 2>/dev/null | awk '$3 == "True" { c++ } END { print c+0 }')
    printf '  [%3ds] %d/%d Certificates Ready\n' "$WAITED" "$ready" "$total"
    if [ "$total" -gt 0 ] && [ "$ready" = "$total" ]; then
        echo
        printf '%s✓ All %d Certificates issued via %s.%s\n\n' "$GREEN$BOLD" "$total" "$ISSUER" "$RESET"
        if [ "$ISSUER" = "letsencrypt-prod" ]; then
            echo "  Browsers will now show valid TLS (no warnings)."
        else
            echo "  Browsers will show 'Not Secure' warnings (LE staging chain)."
        fi
        echo
        echo "  Run ${BOLD}./scripts/validate-stack.sh${RESET} for full verification."
        exit 0
    fi
done

echo
printf '%s✗ Timed out after %ds with %d/%d Certificates Ready.%s\n' "$RED$BOLD" "$TIMEOUT" "$ready" "$total" "$RESET"
echo
echo "Inspect failures:"
echo "  kubectl get certificate -A | grep -v True"
echo "  kubectl describe certificate -A | grep -B1 -A5 Failed"
if [ "$ISSUER" = "letsencrypt-prod" ]; then
    echo
    echo "${YELLOW}Most likely cause: LE prod rate limit (5 certs / identifier / 168h).${RESET}"
    echo "Check the Order resource for the rate-limit error message:"
    echo "  kubectl get order -A | grep -i errored"
fi
exit 1
