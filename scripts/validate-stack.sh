#!/usr/bin/env bash
# validate-stack.sh -- one-shot post-reset-helm health check.
#
# Run on the EC2 after `reset-helm.sh` finishes (with or without
# --skip-graphrag). Walks every workload namespace, helm releases,
# license + image-pull secrets, GraphDB rename, staging-data PVCs,
# keycloak post-install Jobs, every Certificate, OIDC issuer match
# for all three realms, and an HTTPS reachability sweep against
# every app URL. Prints a clean per-check pass/fail summary, an
# overall verdict, and a closing "where to click next" panel.
#
# Idempotent and safe to re-run any time -- it's read-only against
# the cluster (just kubectl gets + curl HEAD-equivalents).
#
# Required env (auto-set by cloud-init's /etc/profile.d/graphwise.sh):
#   GRAPHWISE_APEX   the apex hostname, e.g. "stroker.semantic-proof.com"
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
║          Graphwise Stack -- Post-reset-helm Validation           ║
╚══════════════════════════════════════════════════════════════════╝${RESET}

${DIM}Verifies every workload installed by scripts/reset-helm.sh.
Read-only; safe to re-run anytime.${RESET}

HEADER

# --------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------
check_pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf '  %s %s\n' "$PASS_MARK" "$1"; }
check_fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '  %s %s\n' "$FAIL_MARK" "$1"; [ -n "${2:-}" ] && printf '    %s%s%s\n' "$DIM" "$2" "$RESET"; }
check_warn() { WARN_COUNT=$((WARN_COUNT + 1)); printf '  %s %s\n' "$WARN_MARK" "$1"; [ -n "${2:-}" ] && printf '    %s%s%s\n' "$DIM" "$2" "$RESET"; }
section()    { printf '\n%s%s%s\n' "$BOLD" "$1" "$RESET"; }

# --------------------------------------------------------------------
# 0. Apex hostname (required for URL checks below)
# --------------------------------------------------------------------
section "Deployment apex"
APEX="${GRAPHWISE_APEX:-}"
if [ -z "$APEX" ]; then
    # Fallback: try to derive from any Ingress with host poolparty.*
    APEX=$(kubectl get ingress -n graphwise --no-headers 2>/dev/null | awk '/poolparty/ { for (i=1;i<=NF;i++) if ($i ~ /^poolparty\./) { sub(/^poolparty\./,"",$i); print $i; exit } }')
fi
if [ -z "$APEX" ]; then
    check_fail "GRAPHWISE_APEX not set and could not be derived from Ingresses" \
               "Set: export GRAPHWISE_APEX=<sub>.<base>  -- or source /etc/profile.d/graphwise.sh"
    echo
    echo "${RED}${BOLD}ABORT:${RESET} cannot proceed without an apex hostname; URL/issuer checks would be meaningless."
    exit 1
fi
check_pass "apex hostname: ${BOLD}$APEX${RESET}"

# --------------------------------------------------------------------
# 1. Helm releases
# --------------------------------------------------------------------
section "Helm releases"
GRAPHRAG_INSTALLED=no
UMBRELLA_STATUS=$(helm list -n graphwise -f '^graphwise-stack$' -o json 2>/dev/null | jq -r '.[0].status // empty' 2>/dev/null)
if [ "$UMBRELLA_STATUS" = "deployed" ]; then
    UMBRELLA_REVISION=$(helm list -n graphwise -f '^graphwise-stack$' -o json | jq -r '.[0].revision')
    check_pass "graphwise-stack release deployed (revision $UMBRELLA_REVISION)"
elif [ -z "$UMBRELLA_STATUS" ]; then
    check_fail "graphwise-stack release MISSING in graphwise namespace" "Re-run scripts/reset-helm.sh"
else
    check_fail "graphwise-stack release status=$UMBRELLA_STATUS (expected deployed)" "helm status -n graphwise graphwise-stack"
fi

GRAPHRAG_STATUS=$(helm list -n graphrag -f '^graphrag$' -o json 2>/dev/null | jq -r '.[0].status // empty' 2>/dev/null)
if [ "$GRAPHRAG_STATUS" = "deployed" ]; then
    GRAPHRAG_REVISION=$(helm list -n graphrag -f '^graphrag$' -o json | jq -r '.[0].revision')
    check_pass "graphrag release deployed (revision $GRAPHRAG_REVISION)"
    GRAPHRAG_INSTALLED=yes
elif [ -z "$GRAPHRAG_STATUS" ]; then
    check_warn "graphrag release not present" "umbrella-only deploy (--skip-graphrag); chatbot/conversation/components/workflows pods will not be installed"
else
    check_fail "graphrag release status=$GRAPHRAG_STATUS (expected deployed or absent)" "helm status -n graphrag graphrag"
fi

# --------------------------------------------------------------------
# 2. Workload pod health
# --------------------------------------------------------------------
section "Workload pods (graphwise / graphdb / keycloak / graphrag)"

check_namespace_ready() {
    local ns="$1" label="$2"
    local total ready_count completed_count
    total=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$total" = "0" ]; then
        check_warn "$label  (namespace '$ns' has 0 pods)"
        return
    fi
    # A pod is "good" if Running with all containers Ready, OR Completed (Job).
    ready_count=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | awk '
        { split($2, r, "/"); if ($3 == "Running" && r[1] == r[2]) ready++ }
        END { print ready+0 }')
    completed_count=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | awk '$3 == "Completed" { c++ } END { print c+0 }')
    local good=$((ready_count + completed_count))
    if [ "$good" = "$total" ]; then
        check_pass "$label  ($ready_count Running, $completed_count Completed of $total)"
    else
        local bad=$((total - good))
        check_fail "$label  ($bad pod(s) not Running/Completed)" \
                   "kubectl get pods -n $ns | grep -vE 'Running|Completed'"
    fi
}

check_namespace_ready graphwise "graphwise namespace  (PoolParty / GraphDB embedded / addons / console)"
check_namespace_ready graphdb   "graphdb namespace    (GraphDB projects -- standalone Workbench)"
# AdeptNova GraphDB lives in its own namespace (RC2). Only check it
# if the namespace exists; reset-helm.sh might have been run with the
# AdeptNova alias disabled.
if kubectl get namespace graphdb-adeptnova >/dev/null 2>&1; then
    check_namespace_ready graphdb-adeptnova "graphdb-adeptnova ns (GraphDB AdeptNova -- public :17200)"
fi
check_namespace_ready keycloak  "keycloak namespace   (Keycloak + Postgres + bootstrap Jobs)"
if [ "$GRAPHRAG_INSTALLED" = "yes" ]; then
    check_namespace_ready graphrag "graphrag namespace  (chatbot / conversation / components / workflows)"
else
    # Even with --skip-graphrag, the umbrella creates n8n Postgres in graphrag ns.
    check_namespace_ready graphrag "graphrag namespace  (n8n Postgres only -- graphrag release skipped)"
fi

# --------------------------------------------------------------------
# 3. License Secrets
# --------------------------------------------------------------------
section "License Secrets"
for s in poolparty-license graphdb-license unifiedviews-license; do
    if kubectl get secret -n graphwise "$s" >/dev/null 2>&1; then
        check_pass "graphwise/$s"
    else
        check_fail "graphwise/$s MISSING" "Run scripts/install-licenses.sh; ensure files/licenses/* are populated"
    fi
done
# graphdb-projects mounts a second copy of graphdb-license in its own ns.
if kubectl get secret -n graphdb graphdb-license >/dev/null 2>&1; then
    check_pass "graphdb/graphdb-license  (graphdb-projects mounts this)"
else
    check_fail "graphdb/graphdb-license MISSING" "Run scripts/install-licenses.sh; it auto-installs the second copy when the graphdb namespace exists"
fi
# graphdb-adeptnova: third copy of license + admin credentials Secret
# consumed by the security-init Helm hook.
if kubectl get namespace graphdb-adeptnova >/dev/null 2>&1; then
    if kubectl get secret -n graphdb-adeptnova graphdb-license >/dev/null 2>&1; then
        check_pass "graphdb-adeptnova/graphdb-license  (AdeptNova GraphDB mounts this)"
    else
        check_fail "graphdb-adeptnova/graphdb-license MISSING" \
                   "Run scripts/install-licenses.sh; it auto-installs the third copy when the graphdb-adeptnova namespace exists"
    fi
    if kubectl get secret -n graphdb-adeptnova graphwise-stack-graphdb-adeptnova-admin >/dev/null 2>&1; then
        check_pass "graphdb-adeptnova/graphwise-stack-graphdb-adeptnova-admin  (security-init Job consumes this)"
    else
        check_fail "graphdb-adeptnova/graphwise-stack-graphdb-adeptnova-admin MISSING" \
                   "Run scripts/install-licenses.sh; the AdeptNova admin Secret is created alongside the license"
    fi
fi

# --------------------------------------------------------------------
# 4. Image-pull secret (created by reset-helm.sh, NOT cluster-bootstrap.sh)
# --------------------------------------------------------------------
section "Image-pull secret (private GraphRAG registry)"
for ns in graphwise graphrag; do
    if kubectl get secret -n "$ns" graphwise >/dev/null 2>&1; then
        check_pass "graphwise secret present in '$ns' namespace"
    else
        check_fail "graphwise secret MISSING in '$ns' namespace" \
                   "~/.ontotext/maven-{user,pass} present? Re-run reset-helm.sh"
    fi
done

# --------------------------------------------------------------------
# 5. GraphDB rename validation (catches alias-collision regression)
# --------------------------------------------------------------------
section "GraphDB subchart fullname (alias collision regression test)"
# Embedded lives in graphwise (PoolParty needs in-namespace bare-name
# resolution to it); projects lives in graphdb (logical separation).
for entry in "graphwise:embedded" "graphdb:projects"; do
    ns="${entry%%:*}"; variant="${entry##*:}"
    name="graphwise-stack-graphdb-$variant"
    if kubectl get statefulset -n "$ns" "$name" >/dev/null 2>&1 && \
       kubectl get svc -n "$ns" "$name" >/dev/null 2>&1; then
        check_pass "$ns/$name  (StatefulSet + Service)"
    else
        check_fail "$ns/$name MISSING (StatefulSet or Service)" \
                   "graphdb fullname helper or namespace override may have regressed -- see CLAUDE.md"
    fi
done

# --------------------------------------------------------------------
# 6. Staging-data PVCs
# --------------------------------------------------------------------
section "Staging-data PVCs (universal ingest path)"
for ns in graphwise graphrag; do
    pvc_status=$(kubectl get pvc -n "$ns" staging-data -o jsonpath='{.status.phase}' 2>/dev/null)
    if [ "$pvc_status" = "Bound" ]; then
        check_pass "staging-data PVC Bound in '$ns' namespace"
    elif [ -z "$pvc_status" ]; then
        check_warn "staging-data PVC missing in '$ns' namespace" \
                   "If staging.enabled=true in values.yaml, expected Bound -- check umbrella render"
    else
        check_fail "staging-data PVC status=$pvc_status in '$ns' namespace" \
                   "kubectl describe pvc -n $ns staging-data"
    fi
done

# --------------------------------------------------------------------
# 7. Keycloak post-install Jobs
# --------------------------------------------------------------------
section "Keycloak post-install Jobs"
check_job_completed() {
    local ns="$1" job="$2" label="$3"
    local succeeded
    succeeded=$(kubectl get job -n "$ns" "$job" -o jsonpath='{.status.succeeded}' 2>/dev/null)
    if [ "$succeeded" = "1" ]; then
        check_pass "$label  ($job in $ns ns: 1/1 Completions)"
    elif [ -z "$succeeded" ]; then
        check_warn "$label  ($job in $ns ns: not found)" \
                   "Job may have been cleaned up by hook-delete-policy after success -- harmless if pods are healthy"
    else
        check_fail "$label  ($job in $ns ns: succeeded=$succeeded)" \
                   "kubectl describe job -n $ns $job; kubectl logs -n $ns job/$job"
    fi
}
check_job_completed keycloak keycloak-bootstrap-admin "bootstrap-admin (master realm poolparty_auth_admin user + admin composite)"
check_job_completed keycloak keycloak-authz-import   "authz-import    (per-client authorizationSettings re-import)"

# --------------------------------------------------------------------
# 8. Certificates (cert-manager)
# --------------------------------------------------------------------
section "TLS (wildcard cert + ClusterIssuer + reflection)"

# 8a. letsencrypt-prod ClusterIssuer must be Ready.
status=$(kubectl get clusterissuer letsencrypt-prod -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
if [ "$status" = "True" ]; then
    check_pass "ClusterIssuer ${BOLD}letsencrypt-prod${RESET} Ready=True (DNS-01 via Route 53)"
elif [ -z "$status" ]; then
    check_fail "ClusterIssuer letsencrypt-prod MISSING" "cluster-bootstrap.sh should have created it; re-run it"
else
    check_fail "ClusterIssuer letsencrypt-prod Ready=$status (expected True)" \
               "kubectl describe clusterissuer letsencrypt-prod"
fi

# 8b. The single wildcard Certificate in cert-manager namespace must
# be Ready, and its dnsNames must cover BOTH the apex and the wildcard.
cert_ready=$(kubectl get certificate -n cert-manager wildcard-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
cert_dns=$(kubectl get certificate -n cert-manager wildcard-tls -o jsonpath='{.spec.dnsNames}' 2>/dev/null)
if [ -z "$cert_ready" ]; then
    check_fail "wildcard-tls Certificate MISSING in cert-manager namespace" "cluster-bootstrap.sh should have created it; re-run it"
elif [ "$cert_ready" != "True" ]; then
    check_fail "wildcard-tls Certificate Ready=$cert_ready" "kubectl describe certificate -n cert-manager wildcard-tls"
else
    check_pass "wildcard-tls Certificate Ready=True (SANs: $cert_dns)"
fi
if echo "$cert_dns" | grep -q "\\*\\.$APEX"; then
    check_pass "wildcard SAN *.${APEX} present"
else
    check_fail "wildcard SAN *.${APEX} MISSING from cert" "kubectl get certificate -n cert-manager wildcard-tls -o jsonpath='{.spec.dnsNames}'"
fi
if echo "$cert_dns" | grep -qE "(^|\")${APEX}(\"|$)"; then
    check_pass "apex SAN ${APEX} present"
else
    check_fail "apex SAN ${APEX} MISSING from cert" "kubectl get certificate -n cert-manager wildcard-tls -o jsonpath='{.spec.dnsNames}'"
fi

# 8c. Reflector must have copied the wildcard-tls Secret into every
# consuming namespace (Ingress.spec.tls.secretName resolves
# in-namespace). Without this, Ingress TLS fails with "Secret not
# found" and ingress-nginx serves a self-signed default cert.
section "Wildcard Secret reflection (kubernetes-reflector)"
reflect_targets=(graphwise graphdb graphrag keycloak kubernetes-dashboard monitoring)
for ns in "${reflect_targets[@]}"; do
    if kubectl get secret -n "$ns" wildcard-tls >/dev/null 2>&1; then
        check_pass "wildcard-tls present in '${BOLD}${ns}${RESET}' namespace"
    else
        check_fail "wildcard-tls MISSING in '${ns}' namespace" \
                   "reflector should have mirrored from cert-manager ns; check kubectl get pods -n kube-system -l app.kubernetes.io/name=reflector"
    fi
done

# 8d. Drift check: any per-app Certificate left over from the pre-
# wildcard era? Should be zero -- only wildcard-tls in cert-manager.
extra_certs=$(kubectl get certificate -A --no-headers 2>/dev/null | grep -v '^cert-manager\s\+wildcard-tls\s' | wc -l | tr -d ' ')
if [ "$extra_certs" = "0" ]; then
    check_pass "no leftover per-app Certificates"
else
    check_warn "$extra_certs leftover Certificate(s) detected" \
               "kubectl get certificate -A | grep -v wildcard-tls -- pre-wildcard-era leftovers, safe to delete"
fi

# --------------------------------------------------------------------
# 9. OIDC issuer match (the historic stack-breaker)
# --------------------------------------------------------------------
section "Keycloak OIDC issuer match (Spring Security strict-equality)"
for realm in master poolparty graphrag; do
    issuer=$(curl -sS --max-time 10 "https://auth.$APEX/realms/$realm/.well-known/openid-configuration" 2>/dev/null | jq -r .issuer 2>/dev/null)
    expected="https://auth.$APEX/realms/$realm"
    if [ "$issuer" = "$expected" ]; then
        check_pass "$realm realm: $issuer"
    elif [ -z "$issuer" ] || [ "$issuer" = "null" ]; then
        check_fail "$realm realm: no issuer returned" "curl https://auth.$APEX/realms/$realm/.well-known/openid-configuration"
    else
        check_fail "$realm realm: issuer mismatch" "got: $issuer  --  expected: $expected"
    fi
done

# --------------------------------------------------------------------
# 10. HTTPS reachability sweep
# --------------------------------------------------------------------
section "HTTPS reachability (every app URL)"

# (host-suffix, expected-codes-regex, label)
endpoints=(
    "$APEX:200|301|302:apex (Console landing)"
    "poolparty.$APEX:200|301|302:PoolParty"
    "auth.$APEX:200|302:Keycloak"
    "graphdb.$APEX:401:GraphDB embedded (basic auth)"
    "graphdb-projects.$APEX:401:GraphDB projects (basic auth)"
    "graphdb-adeptnova.$APEX:401:GraphDB AdeptNova (basic auth + GraphDB native auth)"
    "adf.$APEX:200|404:ADF (root 404 OK; lives at /ADF/)"
    "semantic-workbench.$APEX:200|404:Semantic Workbench (root 404 OK; lives at /SemanticWorkbench/)"
    "graphviews.$APEX:200|404:GraphViews (root 404 OK; lives at /GraphViews/)"
    "rdf4j.$APEX:401:RDF4J Workbench (basic auth)"
    "unifiedviews.$APEX:200|404:UnifiedViews (root 404 OK; lives at /UnifiedViews/)"
    "dashboard.$APEX:200|302:Kubernetes Dashboard"
    "prometheus.$APEX:401:Prometheus (basic auth)"
    "grafana.$APEX:200|302:Grafana"
)

if [ "$GRAPHRAG_INSTALLED" = "yes" ]; then
    endpoints+=("graphrag.$APEX:200|301|302:GraphRAG chatbot")
fi

for entry in "${endpoints[@]}"; do
    host="${entry%%:*}"; rest="${entry#*:}"
    expected_re="${rest%%:*}"; label="${rest#*:}"
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://$host/" 2>/dev/null)
    if [[ "$code" =~ ^($expected_re)$ ]]; then
        check_pass "https://$host/  -> $code  $DIM($label)$RESET"
    elif [ "$code" = "000" ]; then
        check_fail "https://$host/  -> connection failed" "DNS / SG / ingress-nginx check"
    elif [[ "$code" =~ ^5 ]]; then
        check_fail "https://$host/  -> $code  ($label)" "5xx -- backend pod errored or crashed"
    else
        check_warn "https://$host/  -> $code  (expected $expected_re; $label)" \
                   "Acceptable for some apps; investigate if persistent"
    fi
done

# --------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------
echo
printf '%s%s%s\n' "$BOLD" "─────────────────────────────────────────────────────────────────" "$RESET"
printf '%s%s%-12s%s passed   %s%-12s%s failed   %s%-12s%s warning\n' \
       "$BOLD" "$GREEN" "$PASS_COUNT" "$RESET" \
       "$RED" "$FAIL_COUNT" "$RESET" \
       "$YELLOW" "$WARN_COUNT" "$RESET"
printf '%s%s%s\n' "$BOLD" "─────────────────────────────────────────────────────────────────" "$RESET"
echo

# --------------------------------------------------------------------
# Where to click next
# --------------------------------------------------------------------
cat <<NEXTSTEPS
${BOLD}${CYAN}Where to click next:${RESET}

  ${BOLD}Console landing page${RESET}      https://$APEX/
  ${BOLD}PoolParty Thesaurus${RESET}       https://poolparty.$APEX/PoolParty/
                              ${DIM}sign in: superadmin / poolparty${RESET}
  ${BOLD}GraphDB embedded${RESET}          https://graphdb.$APEX/
                              ${DIM}basic-auth: demo / rdf#rocks${RESET}
  ${BOLD}GraphDB projects${RESET}          https://graphdb-projects.$APEX/
                              ${DIM}basic-auth: demo / rdf#rocks${RESET}
  ${BOLD}GraphDB AdeptNova${RESET}         https://graphdb-adeptnova.$APEX/
                            (direct :17200 also reachable from allowed CIDRs)
  ${BOLD}Keycloak admin${RESET}            https://auth.$APEX/admin/
                              ${DIM}sign in: poolparty_auth_admin / admin${RESET}
  ${BOLD}Grafana${RESET}                   https://grafana.$APEX/
                              ${DIM}sign in: admin / demo-graphwise-2026${RESET}
  ${BOLD}Kubernetes Dashboard${RESET}      https://dashboard.$APEX/
                              ${DIM}upload ~/dashboard-kubeconfig.yaml${RESET}

${DIM}Full URL + credentials reference: CONSOLE-GUIDE.md${RESET}

NEXTSTEPS

if [ "$FAIL_COUNT" = "0" ]; then
    printf '%s✓ Stack looks healthy. You are good to demo.%s\n\n' "$GREEN$BOLD" "$RESET"
    exit 0
else
    printf '%s✗ %d check(s) failed. Investigate above before demoing.%s\n' "$RED$BOLD" "$FAIL_COUNT" "$RESET"
    printf '%sCONSOLE-GUIDE.md "If something breaks" runbook is the next stop.%s\n\n' "$DIM" "$RESET"
    exit 1
fi
