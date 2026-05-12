#!/usr/bin/env bash
# preflight-reset-helm.sh -- read-only sanity check that runs every
# precondition reset-helm.sh needs BEFORE the destructive uninstall.
#
# Run on the EC2 after cluster-bootstrap.sh + install-licenses.sh +
# extract-poolparty-realm.sh + (optionally) editing ~/graphwise-secrets.yaml.
# Goal: catch ImagePullBackOff, "license not found", LE cert failures,
# bad credentials, missing realm JSON, etc. BEFORE Helm spends 10-15
# minutes installing pods that are doomed to crash.
#
# Read-only; safe to run as many times as you want. Idempotent.
#
# Flags:
#   --skip-graphrag   skip maven auth + graphrag-secrets completeness
#                     checks (mirrors reset-helm.sh --skip-graphrag)
#   --strict          warnings become failures (exit 1 on any warn)
#
# Exit codes:
#   0 -- all required checks passed (warnings allowed unless --strict)
#   1 -- one or more required checks failed
#   2 -- usage / cluster unreachable

set -uo pipefail

# --------------------------------------------------------------------
# Args + colors
# --------------------------------------------------------------------
SKIP_GRAPHRAG=0
STRICT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-graphrag) SKIP_GRAPHRAG=1; shift ;;
        --strict)        STRICT=1; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)  echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

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

# Resolve repo root from this script's location.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

clear

cat <<HEADER
${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════╗
║         Graphwise Stack -- reset-helm.sh Pre-flight              ║
╚══════════════════════════════════════════════════════════════════╝${RESET}

${DIM}Read-only sanity check. Verifies every precondition reset-helm.sh
needs so you don't waste 10-15 minutes on a doomed Helm install.${RESET}

HEADER

[ "$SKIP_GRAPHRAG" = "1" ] && printf '  %sMode:%s --skip-graphrag (umbrella-only checks)\n' "$DIM" "$RESET"
[ "$STRICT"        = "1" ] && printf '  %sMode:%s --strict (warnings count as failures)\n' "$DIM" "$RESET"

# --------------------------------------------------------------------
# Helpers
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
# 1. Tools available
# --------------------------------------------------------------------
section "Tools"
for cmd in kubectl helm jq python3 curl dig openssl; do
    if command -v "$cmd" >/dev/null 2>&1; then
        check_pass "$cmd present"
    else
        check_fail "$cmd missing" "install via dnf (AL2023) or per-tool docs"
    fi
done

if python3 -c "import yaml" >/dev/null 2>&1; then
    check_pass "python3 PyYAML available"
else
    check_fail "python3 PyYAML missing" "pip3 install --user pyyaml"
fi

# --------------------------------------------------------------------
# 2. Cluster reachable (early abort if not)
# --------------------------------------------------------------------
section "Cluster"
if ! kubectl get nodes >/dev/null 2>&1; then
    check_fail "kubectl cannot reach cluster" \
               "Run scripts/cluster-resume.sh after EC2 stop/start"
    echo
    echo "${RED}${BOLD}ABORT:${RESET} cluster API not reachable; remaining checks would all fail."
    exit 2
fi
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
READY_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready"' | wc -l | tr -d ' ')
if [ "$NODE_COUNT" = "$READY_COUNT" ] && [ "$NODE_COUNT" != "0" ]; then
    check_pass "kubectl reachable, $READY_COUNT/$NODE_COUNT node(s) Ready"
else
    check_fail "$READY_COUNT/$NODE_COUNT node(s) Ready" "kubectl get nodes"
fi

CTX=$(kubectl config current-context 2>/dev/null || echo "")
if [ "$CTX" = "kind-graphwise" ]; then
    check_pass "kubectl context = kind-graphwise"
else
    check_warn "kubectl context = '$CTX' (expected kind-graphwise)" \
               "kubectl config use-context kind-graphwise"
fi

# --------------------------------------------------------------------
# 3. Cluster operators ready
# --------------------------------------------------------------------
section "Cluster operators"

check_namespace_min_ready() {
    local ns="$1" expected_min="$2" label="$3"
    local total ready_count
    total=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$total" = "0" ]; then
        check_fail "$label" "namespace '$ns' has 0 pods -- run cluster-bootstrap.sh"
        return
    fi
    ready_count=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | awk '
        {
            split($2, r, "/");
            if ($3 == "Running" && r[1] == r[2]) ready++
        }
        END { print ready+0 }
    ')
    if [ "$ready_count" -ge "$expected_min" ] && [ "$ready_count" = "$total" ]; then
        check_pass "$label ($ready_count/$total Ready)"
    else
        check_fail "$label ($ready_count/$total Ready, expected >= $expected_min)" \
                   "kubectl get pods -n $ns"
    fi
}

check_namespace_min_ready cert-manager   3 "cert-manager (controller + cainjector + webhook)"
check_namespace_min_ready ingress-nginx  1 "ingress-nginx (controller)"
check_namespace_min_ready cnpg-system    1 "cnpg-system (CloudNativePG operator)"

KC_OP_READY=$(kubectl get pods -n keycloak -l app.kubernetes.io/name=keycloak-operator --no-headers 2>/dev/null \
    | awk '{split($2,r,"/"); if ($3 == "Running" && r[1] == r[2]) print "yes"}')
if [ "$KC_OP_READY" = "yes" ]; then
    check_pass "keycloak-operator Running"
else
    check_fail "keycloak-operator NOT Running" \
               "kubectl get pods -n keycloak -l app.kubernetes.io/name=keycloak-operator"
fi

# Match reflector pod by name prefix in kube-system. Label keys differ
# across emberstack chart versions (`app=` vs `app.kubernetes.io/name=`
# vs `app.kubernetes.io/name=emberstack-reflector`), but the Deployment
# name `reflector-*` is stable. Same pattern as validate-bootstrap.sh's
# metrics-server check.
REFLECTOR_READY=$(kubectl get pods -n kube-system --no-headers 2>/dev/null \
    | awk '$1 ~ /^reflector-/ {split($2,r,"/"); if ($3 == "Running" && r[1] == r[2]) print "yes"}' | head -1)
if [ "$REFLECTOR_READY" = "yes" ]; then
    check_pass "reflector Running (mirrors wildcard-tls into consuming namespaces)"
else
    check_fail "reflector NOT Running" \
               "Wildcard cert won't mirror into graphwise/graphrag/keycloak namespaces"
fi

CI_STATUS=$(kubectl get clusterissuer letsencrypt-prod -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
if [ "$CI_STATUS" = "True" ]; then
    check_pass "letsencrypt-prod ClusterIssuer Ready"
else
    check_fail "letsencrypt-prod ClusterIssuer NOT Ready (status=${CI_STATUS:-missing})" \
               "kubectl describe clusterissuer letsencrypt-prod"
fi

# --------------------------------------------------------------------
# 4. Repo state -- PoolParty realm JSON
# --------------------------------------------------------------------
section "Repo state"
REALM_JSON="$REPO_ROOT/charts/keycloak-realms/files/poolparty-realm.json"
if [ ! -f "$REALM_JSON" ]; then
    check_fail "poolparty-realm.json missing" \
               "Run scripts/extract-poolparty-realm.sh"
elif grep -qE '\$\{POOLPARTY_[A-Z_]+\}' "$REALM_JSON" 2>/dev/null; then
    LEFT=$(grep -oE '\$\{POOLPARTY_[A-Z_]+\}' "$REALM_JSON" | sort -u | tr '\n' ' ')
    check_fail "poolparty-realm.json has unsubstituted \${...} placeholders" \
               "Left: $LEFT -- re-run scripts/extract-poolparty-realm.sh"
else
    SIZE=$(wc -c < "$REALM_JSON" | tr -d ' ')
    check_pass "poolparty-realm.json present (${SIZE} bytes, placeholders substituted)"
fi

# --------------------------------------------------------------------
# 5. License files on disk
# --------------------------------------------------------------------
section "License files (files/licenses/)"
LIC_DIR="$REPO_ROOT/files/licenses"
for f in poolparty.key graphdb.license uv-license.key; do
    if [ -f "$LIC_DIR/$f" ]; then
        SIZE=$(wc -c < "$LIC_DIR/$f" | tr -d ' ')
        if [ "$SIZE" -lt 50 ]; then
            check_warn "files/licenses/$f present but suspiciously small (${SIZE} bytes)" \
                       "Vendor license blobs are usually >1KB"
        else
            check_pass "files/licenses/$f present (${SIZE} bytes)"
        fi
    else
        check_fail "files/licenses/$f missing" \
                   "scp from laptop -- see DEPLOY §3"
    fi
done

# --------------------------------------------------------------------
# 6. Secrets overlay completeness
# --------------------------------------------------------------------
section "Secrets overlay (~/graphwise-secrets.yaml)"
OVERLAY="$HOME/graphwise-secrets.yaml"

# Stash overlay-derived maven creds for the maven-auth check below.
MAVEN_USER=""
MAVEN_PASS=""

if [ ! -f "$OVERLAY" ]; then
    check_fail "$OVERLAY missing" \
               "Terraform cloud-init seeds this on first boot; was user-data run?"
else
    # Single python invocation: emits one OK|... or MISSING|... line per
    # field + MAVEN_USER=/MAVEN_PASS= for the bash side. Indentation in
    # the YAML structure is the chart's canonical layout.
    OVERLAY_OUTPUT=$(OVERLAY="$OVERLAY" SKIP_GRAPHRAG="$SKIP_GRAPHRAG" python3 <<'PY'
import os, sys, yaml

try:
    with open(os.environ['OVERLAY']) as f:
        d = yaml.safe_load(f) or {}
except Exception as exc:
    print(f'PARSE_ERROR|{exc}')
    sys.exit(0)

def filled(v):
    return isinstance(v, str) and v.strip() != ''

mv  = d.get('maven') or {}
gs  = d.get('graphrag-secrets') or {}
aws = (gs.get('awsCredentials') or {})
n8n_lic = (gs.get('n8nLicense') or {})
n8n_enc = (gs.get('n8nEncryption') or {})

# Maven (canonical top-level)
mu, mp = mv.get('user'), mv.get('pass')
if filled(mu) and filled(mp):
    print(f'OK|maven.user / maven.pass')
    print(f'MAVEN_USER={mu.strip()}')
    print(f'MAVEN_PASS={mp.strip()}')
else:
    print('MISSING|maven.user / maven.pass (image-pull Secret cannot be created)')

skip_graphrag = os.environ.get('SKIP_GRAPHRAG') == '1'

# graphrag-secrets checks -- only when graphrag is in scope.
if not skip_graphrag:
    region = aws.get('region')
    ak     = aws.get('accessKeyId')
    sk     = aws.get('secretAccessKey')
    if filled(region):
        print(f'OK|graphrag-secrets.awsCredentials.region = {region}')
    else:
        print('MISSING|graphrag-secrets.awsCredentials.region')
    if filled(ak) and ak.strip().startswith('AKIA'):
        print(f'OK|graphrag-secrets.awsCredentials.accessKeyId ({ak.strip()[:8]}...)')
    elif filled(ak):
        print(f'WARN|awsCredentials.accessKeyId does not start with AKIA ({ak.strip()[:8]}...)')
    else:
        print('MISSING|graphrag-secrets.awsCredentials.accessKeyId')
    if filled(sk):
        print('OK|graphrag-secrets.awsCredentials.secretAccessKey')
    else:
        print('MISSING|graphrag-secrets.awsCredentials.secretAccessKey')

    lk = n8n_lic.get('activationKey')
    if filled(lk):
        print('OK|graphrag-secrets.n8nLicense.activationKey')
    else:
        print('MISSING|graphrag-secrets.n8nLicense.activationKey')

# n8n encryption key -- auto-generated by Terraform; check non-empty
# always (some charts use it even in umbrella-only deploys).
ek = n8n_enc.get('key')
if filled(ek):
    print(f'OK|graphrag-secrets.n8nEncryption.key (auto-generated, len={len(ek.strip())})')
else:
    print('MISSING|graphrag-secrets.n8nEncryption.key (Terraform random_id should have set this)')
PY
)
    # Parse the structured output. PARSE_ERROR -> immediate fail.
    if echo "$OVERLAY_OUTPUT" | grep -q '^PARSE_ERROR|'; then
        ERR=$(echo "$OVERLAY_OUTPUT" | sed -n 's/^PARSE_ERROR|//p')
        check_fail "$OVERLAY unparseable" "$ERR"
    else
        while IFS='|' read -r status detail; do
            case "$status" in
                OK)      check_pass "$detail" ;;
                MISSING) check_fail "$detail" "Edit $OVERLAY on this host" ;;
                WARN)    check_warn "$detail" ;;
                MAVEN_USER=*) MAVEN_USER="${status#MAVEN_USER=}" ;;
                MAVEN_PASS=*) MAVEN_PASS="${status#MAVEN_PASS=}" ;;
                "") ;;
            esac
        done <<<"$OVERLAY_OUTPUT"
    fi
fi

# --------------------------------------------------------------------
# 7. Networking / DNS
# --------------------------------------------------------------------
section "DNS resolution"
APEX="${GRAPHWISE_APEX:-}"
if [ -z "$APEX" ]; then
    # Last-resort: derive from any Ingress in the cluster.
    APEX=$(kubectl get ingress -A -o jsonpath='{.items[*].spec.rules[*].host}' 2>/dev/null \
           | tr ' ' '\n' | head -1 | sed -E 's/^[^.]+\.//')
fi

if [ -z "$APEX" ]; then
    check_warn "Cannot determine apex hostname; skipping DNS checks" \
               "Set GRAPHWISE_APEX in /etc/profile.d/graphwise.sh"
else
    APEX_IP=$(dig +short +time=3 +tries=2 "$APEX" 2>/dev/null | tail -1)
    if [ -n "$APEX_IP" ]; then
        check_pass "apex $APEX resolves to $APEX_IP"
    else
        check_fail "apex $APEX does not resolve" \
                   "Add A record pointing at your EIP"
    fi
    WILDCARD_IP=$(dig +short +time=3 +tries=2 "poolparty.$APEX" 2>/dev/null | tail -1)
    if [ -n "$WILDCARD_IP" ] && [ "$WILDCARD_IP" = "$APEX_IP" ]; then
        check_pass "wildcard *.$APEX resolves to $WILDCARD_IP (matches apex)"
    elif [ -n "$WILDCARD_IP" ]; then
        check_fail "wildcard *.$APEX -> $WILDCARD_IP, apex -> $APEX_IP" \
                   "Wildcard A record points at the wrong IP"
    else
        check_fail "wildcard *.$APEX does not resolve (probed poolparty.$APEX)" \
                   "Add *.$APEX A record at your DNS provider"
    fi
fi

# --------------------------------------------------------------------
# 8. AWS / IAM (instance role required for cert-manager Route53 DNS-01)
# --------------------------------------------------------------------
section "AWS instance role (for cert-manager Route53 DNS-01)"
IMDS_TOKEN=$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
             -H "X-aws-ec2-metadata-token-ttl-seconds: 60" --max-time 3 2>/dev/null || true)
if [ -z "$IMDS_TOKEN" ]; then
    check_fail "IMDSv2 not reachable from this host" \
               "aws_instance metadata_options.http_put_response_hop_limit must be >= 2"
else
    ROLE=$(curl -fsS -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
           "http://169.254.169.254/latest/meta-data/iam/security-credentials/" \
           --max-time 3 2>/dev/null || true)
    if [ -n "$ROLE" ]; then
        check_pass "Instance role bound: $ROLE"
    else
        check_fail "No IAM role attached to this EC2" \
                   "Terraform aws_iam_instance_profile must attach a role with Route53 perms"
    fi
fi

# --------------------------------------------------------------------
# 9. Maven registry auth (skip when --skip-graphrag, since no graphrag
# images need pulling -- the umbrella's only private images are the
# graphdb / poolparty / addons set, which use the same Secret; if those
# fail to pull, you see it within 1-2 min of helm install rather than
# 15 min in, so it's lower-stakes than the graphrag failure mode).
# --------------------------------------------------------------------
section "Maven registry (maven.ontotext.com)"
if [ -z "$MAVEN_USER" ] || [ -z "$MAVEN_PASS" ]; then
    check_warn "Skipping maven auth test -- maven.user/pass not set in overlay" \
               "Fill them in, then re-run preflight"
else
    # Two probes: with creds and without. The /v2/ endpoint is the
    # Docker Registry HTTP API root, but maven.ontotext.com sits behind
    # a reverse proxy that routes by image-specific paths (/v2/<image>/
    # manifests/<tag>) and returns plain 404 at the registry root --
    # not a Docker error. Comparing the two probes lets us distinguish
    # an actual auth failure (different status with vs without creds)
    # from this structural quirk (same 404 either way).
    HTTP_WITH_AUTH=$(curl -s -o /dev/null -w '%{http_code}' \
                     -u "$MAVEN_USER:$MAVEN_PASS" \
                     "https://maven.ontotext.com/v2/" --max-time 10 2>/dev/null || echo 000)
    HTTP_NO_AUTH=$(curl -s -o /dev/null -w '%{http_code}' \
                   "https://maven.ontotext.com/v2/" --max-time 10 2>/dev/null || echo 000)
    case "$HTTP_WITH_AUTH" in
        200|301|302)
            check_pass "maven.ontotext.com auth OK (HTTP $HTTP_WITH_AUTH)" ;;
        401|403)
            check_fail "maven.ontotext.com rejected credentials (HTTP $HTTP_WITH_AUTH)" \
                       "Wrong maven.user / maven.pass in $OVERLAY" ;;
        000)
            check_fail "maven.ontotext.com unreachable from this host" \
                       "Check egress / DNS / security group" ;;
        404)
            if [ "$HTTP_NO_AUTH" = "404" ]; then
                check_warn "maven.ontotext.com /v2/ returns 404 (registry root not exposed)" \
                           "Reverse-proxy artifact (Nexus/Harbor); image-specific paths still work. Auth test is inconclusive -- real test is first image pull."
            else
                check_fail "maven.ontotext.com /v2/ returns 404 with creds but $HTTP_NO_AUTH without -- routing differs by auth state" \
                           "Investigate registry config; unexpected proxy behavior."
            fi ;;
        *)
            check_warn "maven.ontotext.com unexpected status (HTTP $HTTP_WITH_AUTH)" \
                       "Treat as fail if image pulls subsequently break" ;;
    esac
fi

# --------------------------------------------------------------------
# 10. TLS cert reuse (informational -- saves an LE rate-limit slot)
# --------------------------------------------------------------------
section "TLS cert reuse (LE rate-limit savings)"
SAVED_CERT="$HOME/wildcard-tls-saved.yaml"
if [ -f "$SAVED_CERT" ]; then
    EXPIRY=$(SAVED_CERT="$SAVED_CERT" python3 <<'PY' 2>/dev/null
import os, yaml, base64, subprocess, tempfile
with open(os.environ['SAVED_CERT']) as f:
    d = yaml.safe_load(f) or {}
crt_b64 = ((d.get('data') or {}).get('tls.crt')) or ''
if not crt_b64:
    raise SystemExit(0)
crt = base64.b64decode(crt_b64)
with tempfile.NamedTemporaryFile(suffix='.crt', delete=False) as f:
    f.write(crt)
    path = f.name
res = subprocess.run(
    ['openssl', 'x509', '-enddate', '-noout', '-in', path],
    capture_output=True, text=True,
)
print(res.stdout.strip().replace('notAfter=', ''))
PY
)
    if [ -n "$EXPIRY" ]; then
        check_pass "wildcard-tls-saved.yaml present (expires $EXPIRY) -- cluster-bootstrap will reuse"
    else
        check_warn "wildcard-tls-saved.yaml present but unparseable" \
                   "Check file content with: head $SAVED_CERT"
    fi
else
    check_warn "wildcard-tls-saved.yaml not present" \
               "cluster-bootstrap will issue a fresh LE cert -- uses 1 of 5 weekly slots"
fi

# --------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------
echo
printf '%s%s%s\n' "$BOLD" "─────────────────────────────────────────────────────────────────" "$RESET"
printf '%s%s%-12s%s passed   %s%-12s%s failed   %s%-12s%s warning\n' \
       "$BOLD" "$GREEN" "$PASS_COUNT" "$RESET" \
       "$RED" "$FAIL_COUNT" "$RESET" \
       "$YELLOW" "$WARN_COUNT" "$RESET"
printf '%s%s%s\n\n' "$BOLD" "─────────────────────────────────────────────────────────────────" "$RESET"

EXIT=0
if [ "$FAIL_COUNT" -gt 0 ]; then
    printf '%s✗ %d required check(s) failed. Fix above before running reset-helm.sh.%s\n' \
           "$RED$BOLD" "$FAIL_COUNT" "$RESET"
    EXIT=1
elif [ "$WARN_COUNT" -gt 0 ] && [ "$STRICT" = "1" ]; then
    printf '%s✗ %d warning(s) in --strict mode count as failures.%s\n' \
           "$RED$BOLD" "$WARN_COUNT" "$RESET"
    EXIT=1
elif [ "$WARN_COUNT" -gt 0 ]; then
    printf '%s✓ Required checks pass; %d warning(s) above are informational.%s\n' \
           "$GREEN$BOLD" "$WARN_COUNT" "$RESET"
    printf '%sSafe to run: ./scripts/reset-helm.sh --yes <subdomain>%s\n' "$DIM" "$RESET"
else
    printf '%s✓ All preflight checks passed.%s\n' "$GREEN$BOLD" "$RESET"
    printf '%sSafe to run: ./scripts/reset-helm.sh --yes <subdomain>%s\n' "$DIM" "$RESET"
fi

exit $EXIT
