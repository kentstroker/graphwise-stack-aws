#!/usr/bin/env bash
# validate-bootstrap.sh -- one-shot post-cluster-bootstrap health check.
#
# Run on the EC2 after `cluster-bootstrap.sh` finishes. Walks every
# operator namespace, the ClusterIssuer, the image-pull secrets, and
# the dashboard kubeconfig file. Prints a clean per-check pass/fail
# summary and an overall verdict.
#
# Idempotent and safe to re-run any time -- it's read-only against
# the cluster.
#
# Exit codes:
#   0 -- all checks passed
#   1 -- one or more checks failed (details in output)

set -uo pipefail

# Colors (disabled when stdout is not a TTY -- pipes / files stay clean).
if [ -t 1 ]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; YELLOW=""; CYAN=""; BOLD=""; DIM=""; RESET=""
fi

PASS_MARK="${GREEN}✓${RESET}"
FAIL_MARK="${RED}✗${RESET}"
WARN_MARK="${YELLOW}⚠${RESET}"

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

clear

cat <<HEADER
${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════╗
║         Graphwise Stack -- Cluster Bootstrap Validation         ║
╚══════════════════════════════════════════════════════════════════╝${RESET}

${DIM}Verifies every piece installed by scripts/cluster-bootstrap.sh.
Read-only; safe to re-run anytime.${RESET}

HEADER

# --------------------------------------------------------------------
# Helper: run a check, accumulate counters, print pass/fail
# --------------------------------------------------------------------
check_pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf '  %s %s\n' "$PASS_MARK" "$1"
}

check_fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '  %s %s\n' "$FAIL_MARK" "$1"
    [ -n "${2:-}" ] && printf '    %s%s%s\n' "$DIM" "$2" "$RESET"
}

check_warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    printf '  %s %s\n' "$WARN_MARK" "$1"
    [ -n "${2:-}" ] && printf '    %s%s%s\n' "$DIM" "$2" "$RESET"
}

section() {
    printf '\n%s%s%s\n' "$BOLD" "$1" "$RESET"
}

# --------------------------------------------------------------------
# 1. Cluster reachability sanity check
# --------------------------------------------------------------------
section "Cluster reachability"
if kubectl get nodes >/dev/null 2>&1; then
    NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    READY_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready"' | wc -l | tr -d ' ')
    if [ "$NODE_COUNT" = "$READY_COUNT" ] && [ "$NODE_COUNT" != "0" ]; then
        check_pass "kubectl reachable, $READY_COUNT/$NODE_COUNT node(s) Ready"
    else
        check_fail "$READY_COUNT/$NODE_COUNT node(s) Ready" "kubectl get nodes"
    fi
else
    check_fail "kubectl unreachable" "Run scripts/cluster-resume.sh after EC2 stop/start"
    echo
    echo "${RED}${BOLD}ABORT:${RESET} cluster API not reachable; remaining checks would all fail."
    exit 1
fi

# --------------------------------------------------------------------
# 2. Per-namespace pod health
# --------------------------------------------------------------------
section "Operator namespaces -- pod health"

check_namespace() {
    local ns="$1" expected_min="$2" label="$3"
    local total ready_count
    total=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$total" = "0" ]; then
        check_fail "$label" "namespace '$ns' has 0 pods (expected >=$expected_min)"
        return
    fi
    # A pod is "ready" if STATUS is Running and READY shows N/N (all containers ready).
    ready_count=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | awk '
        {
            split($2, r, "/");
            if ($3 == "Running" && r[1] == r[2]) ready++
        }
        END { print ready+0 }
    ')
    if [ "$ready_count" -ge "$expected_min" ] && [ "$ready_count" = "$total" ]; then
        check_pass "$label  ($ready_count/$total pods Running, all containers Ready)"
    elif [ "$ready_count" -ge "$expected_min" ]; then
        check_warn "$label  ($ready_count/$total ready -- $((total - ready_count)) pod(s) not Ready)"
    else
        check_fail "$label  ($ready_count/$total ready, expected >=$expected_min)" \
                   "kubectl get pods -n $ns"
    fi
}

check_namespace cert-manager        3  "cert-manager           (controller + cainjector + webhook)"
check_namespace ingress-nginx       1  "ingress-nginx          (controller)"
check_namespace cnpg-system         1  "cnpg-system            (CloudNativePG operator)"
check_namespace monitoring          5  "monitoring             (kube-prometheus-stack)"
check_namespace kubernetes-dashboard 2 "kubernetes-dashboard   (dashboard + metrics-scraper)"

# Keycloak operator pod (its CRD lives in keycloak ns alongside the realms).
KC_OP_READY=$(kubectl get pods -n keycloak -l app.kubernetes.io/name=keycloak-operator --no-headers 2>/dev/null \
    | awk '{split($2,r,"/"); if ($3 == "Running" && r[1] == r[2]) print "yes"}')
if [ "$KC_OP_READY" = "yes" ]; then
    check_pass "keycloak               (keycloak-operator Running)"
else
    check_fail "keycloak               (keycloak-operator NOT Running)" \
               "kubectl get pods -n keycloak -l app.kubernetes.io/name=keycloak-operator"
fi

# metrics-server lives in kube-system.
MS_READY=$(kubectl get pods -n kube-system -l k8s-app=metrics-server --no-headers 2>/dev/null \
    | awk '{split($2,r,"/"); if ($3 == "Running" && r[1] == r[2]) print "yes"}')
if [ "$MS_READY" = "yes" ]; then
    check_pass "kube-system            (metrics-server Running)"
else
    check_fail "kube-system            (metrics-server NOT Running)" \
               "kubectl get pods -n kube-system -l k8s-app=metrics-server"
fi

# --------------------------------------------------------------------
# 3. cert-manager ClusterIssuer
# --------------------------------------------------------------------
section "Cert-manager ClusterIssuer"
ISSUER_READY=$(kubectl get clusterissuer letsencrypt-prod -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
if [ "$ISSUER_READY" = "True" ]; then
    check_pass "letsencrypt-prod ClusterIssuer Ready (registered with Let's Encrypt)"
else
    check_fail "letsencrypt-prod ClusterIssuer NOT Ready (status=${ISSUER_READY:-missing})" \
               "kubectl describe clusterissuer letsencrypt-prod"
fi

# --------------------------------------------------------------------
# 4. Image-pull secrets
# --------------------------------------------------------------------
section "Image-pull secrets (private GraphRAG registry)"
for ns in graphwise graphrag; do
    if kubectl get secret -n "$ns" graphwise >/dev/null 2>&1; then
        check_pass "graphwise secret present in '$ns' namespace"
    else
        check_fail "graphwise secret MISSING in '$ns' namespace" \
                   "kubectl get secret -n $ns graphwise"
    fi
done

# --------------------------------------------------------------------
# 5. Dashboard kubeconfig artifact
# --------------------------------------------------------------------
section "Dashboard sign-in artifact"
KUBECONFIG_FILE="$HOME/dashboard-kubeconfig.yaml"
if [ -f "$KUBECONFIG_FILE" ]; then
    SIZE=$(wc -c < "$KUBECONFIG_FILE" | tr -d ' ')
    check_pass "$KUBECONFIG_FILE present (${SIZE} bytes) -- scp to laptop, upload at Dashboard login"
else
    check_fail "$KUBECONFIG_FILE missing" \
               "Re-run cluster-bootstrap.sh; it auto-generates this file"
fi

# --------------------------------------------------------------------
# 6. Stragglers anywhere in the cluster
# --------------------------------------------------------------------
section "Cluster-wide pod sweep (any pod not Running/Completed)"
STRAGGLERS=$(kubectl get pods -A --no-headers 2>/dev/null \
    | awk '$4 != "Running" && $4 != "Completed" { print "    " $1 "/" $2 " -- " $4 }')
if [ -z "$STRAGGLERS" ]; then
    check_pass "every pod cluster-wide is Running or Completed"
else
    STRAGGLER_COUNT=$(echo "$STRAGGLERS" | wc -l | tr -d ' ')
    check_warn "$STRAGGLER_COUNT non-Running pod(s) -- expected during initial Helm installs, investigate if persistent:"
    echo "$STRAGGLERS"
fi

# --------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------
echo
printf '%s%s' "$BOLD" "─────────────────────────────────────────────────────────────────"
printf '%s\n' "$RESET"
printf '%s%s%-12s%s passed   %s%-12s%s failed   %s%-12s%s warning\n' \
       "$BOLD" "$GREEN" "$PASS_COUNT" "$RESET" \
       "$RED" "$FAIL_COUNT" "$RESET" \
       "$YELLOW" "$WARN_COUNT" "$RESET"
printf '%s%s' "$BOLD" "─────────────────────────────────────────────────────────────────"
printf '%s\n\n' "$RESET"

if [ "$FAIL_COUNT" = "0" ]; then
    printf '%s✓ Bootstrap looks healthy. Continue to DEPLOY §5 (extract-poolparty-realm.sh).%s\n' \
           "$GREEN$BOLD" "$RESET"
    exit 0
else
    printf '%s✗ %d check(s) failed. Investigate above before proceeding.%s\n' \
           "$RED$BOLD" "$FAIL_COUNT" "$RESET"
    printf '%sRe-run cluster-bootstrap.sh -- it is idempotent.%s\n' \
           "$DIM" "$RESET"
    exit 1
fi
