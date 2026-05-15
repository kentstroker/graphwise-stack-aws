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
#   - all PVCs in namespaces graphwise, graphdb, keycloak, graphrag (data loss)
#   - any leftover Secrets/ConfigMaps from the umbrella's templates/
#
# Side-effect: re-renders the apex landing page ConfigMap
# (charts/console/templates/configmap.yaml) through Helm `tpl`, so the
# console at https://<sub>.<base>/ always reflects the credentials and
# hostnames in values.yaml after this script completes. If you change a
# default in charts/graphwise-stack/values.yaml or
# charts/console/values.yaml, re-running this script (or a plain
# helm upgrade) updates the page automatically. CONSOLE-GUIDE.md is
# the authoritative reference for every credential in the stack.
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
#   VALUES_FILE        (default: $HOME/.graphwise-stack/values-<subdomain>.yaml)
#   HELM_TIMEOUT       (default: 15m)
#
# Idempotent. Safe to re-run; uninstalls/deletes use --ignore-not-found
# semantics where possible.

set -euo pipefail

# Colors (disabled when stdout is not a TTY -- pipes/files stay clean).
# Used by the destructive-confirmation prompt block below.
if [ -t 1 ]; then
    BOLD=$'\033[1m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
    BOLD=""; YELLOW=""; RESET=""
fi

# ---------------------------------------------------------------------
# Argument parsing -- accept --yes anywhere on the command line, then
# positional <subdomain> [base_domain]. Earlier version only honored
# --yes as the first arg, which caused later --yes to silently land in
# the base_domain slot and produce ingress hostnames like
# "<app>.<sub>.--yes".
# ---------------------------------------------------------------------
ASSUME_YES=0
SKIP_GRAPHRAG=0
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes)
            ASSUME_YES=1
            shift
            ;;
        --skip-graphrag)
            # Install / update only the umbrella release. Useful when
            # Maven creds for maven.ontotext.com aren't available yet
            # (graphrag images would otherwise ImagePullBackOff). Also
            # uninstalls any existing graphrag release to keep state
            # consistent.
            SKIP_GRAPHRAG=1
            shift
            ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--yes] [--skip-graphrag] <subdomain> [base_domain]

  --yes            Skip the "type 'reset' to proceed" prompt.
  --skip-graphrag  Install only the umbrella release (PoolParty,
                   GraphDB, Keycloak, addons, console). Skips the
                   graphrag release entirely. Use when you don't
                   yet have Maven creds for maven.ontotext.com.
                   Any existing graphrag release is uninstalled.
EOF
            exit 0
            ;;
        --)
            shift
            POSITIONAL+=("$@")
            break
            ;;
        -*)
            echo "ERROR: unknown flag '$1'" >&2
            echo "Usage: $0 [--yes] [--skip-graphrag] <subdomain> [base_domain]" >&2
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
    echo "Usage: $0 [--yes] [--skip-graphrag] <subdomain> [base_domain]" >&2
    exit 1
fi

SUB="$1"
BASE="${2:-semantic-demo.com}"

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

VALUES_DIR="${VALUES_DIR:-$HOME/.graphwise-stack}"
UMBRELLA_VALUES="${UMBRELLA_VALUES:-$VALUES_DIR/values-${SUB}.yaml}"
GRAPHRAG_VALUES="${GRAPHRAG_VALUES:-$VALUES_DIR/values-${SUB}-graphrag.yaml}"
mkdir -p "$(dirname "$UMBRELLA_VALUES")" "$(dirname "$GRAPHRAG_VALUES")"

# Per-deployment secrets overlay written by Terraform's cloud-init
# (~/graphwise-secrets.yaml). EC2-local; never tracked by git.
# Holds:
#   - awsCredentials (Bedrock IAM keys -- operator fills in)
#   - n8nLicense.activationKey (n8n Enterprise key -- operator fills in)
#   - n8nEncryption.key (random, auto-generated by Terraform; do not edit
#     after first n8n boot)
# Auto-included via -f below; missing is fine but graphrag deploy will
# break without filled-in values (preflight warns).
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
# Pre-flight: license Secrets must exist
# ---------------------------------------------------------------------
# The umbrella's poolparty / graphdb / unifiedviews charts mount
# license Secrets via secretKeyRef. If they're missing, the pods come
# up but immediately fail with "secret not found" -- ~10 minutes
# wasted on a Helm install that crashloops out the gate. Catch it
# before we do anything destructive.
echo "Pre-flight: checking license Secrets..."
missing_licenses=0
# graphwise namespace: poolparty / graphdb-embedded / unifiedviews mount these.
for secret in poolparty-license graphdb-license unifiedviews-license; do
    if ! kubectl -n "$UMBRELLA_NAMESPACE" get secret "$secret" >/dev/null 2>&1; then
        echo "  ERROR: missing Secret '$UMBRELLA_NAMESPACE/$secret'" >&2
        missing_licenses=1
    else
        echo "  OK:    $UMBRELLA_NAMESPACE/$secret"
    fi
done
# graphdb namespace: graphdb-projects mounts a second copy of graphdb-license.
# install-licenses.sh creates it there too if the namespace exists.
if ! kubectl -n graphdb get secret graphdb-license >/dev/null 2>&1; then
    echo "  ERROR: missing Secret 'graphdb/graphdb-license'" >&2
    missing_licenses=1
else
    echo "  OK:    graphdb/graphdb-license"
fi
if [[ $missing_licenses -ne 0 ]]; then
    cat >&2 <<'PREFLIGHT'

Drop your Graphwise license files into files/licenses/ and run:
    ./scripts/install-licenses.sh

Required filenames (rename whatever Graphwise sent to these exactly):
    files/licenses/poolparty.key
    files/licenses/graphdb.license
    files/licenses/uv-license.key

Then re-run this script. Aborting before destructive uninstall.
PREFLIGHT
    exit 1
fi

# ---------------------------------------------------------------------
# Pre-flight: ~/graphwise-secrets.yaml must have real values for full deploy
# ---------------------------------------------------------------------
# Reports OK/MISSING for each operator-supplied secret BEFORE the
# destructive uninstall, so the operator sees status of every input
# next to the license-secrets pre-flight above. If anything is
# missing AND graphrag is in scope, prompt-pause for 5s so Ctrl-C is
# still useful before wipe.
#
# Maven creds are checked here for visibility -- the actual image-pull
# secret is created later (after PVCs are deleted, before helm install).
echo
echo "Pre-flight: checking ~/graphwise-secrets.yaml..."
if [[ ! -f "$SECRETS_OVERLAY" ]]; then
    echo "  NOTE:  $SECRETS_OVERLAY not found (cloud-init didn't run?)"
else
    secrets_status=$(SECRETS_OVERLAY="$SECRETS_OVERLAY" python3 <<'PY'
import os, yaml
with open(os.environ['SECRETS_OVERLAY']) as f:
    d = yaml.safe_load(f) or {}
gs  = d.get('graphrag-secrets') or {}
aws = gs.get('awsCredentials') or {}
n8n = gs.get('n8nLicense') or {}

def filled(v):
    return isinstance(v, str) and v.strip() != ''

# Maven: top-level canonical, falls back to graphrag-secrets.maven
mv = d.get('maven') or {}
mv_user, mv_pass, mv_loc = mv.get('user'), mv.get('pass'), 'top-level'
if not (filled(mv_user) and filled(mv_pass)):
    nm = gs.get('maven') or {}
    if filled(nm.get('user')) and filled(nm.get('pass')):
        mv_user, mv_pass, mv_loc = nm.get('user'), nm.get('pass'), 'graphrag-secrets.maven (legacy)'

if filled(mv_user) and filled(mv_pass):
    print(f'OK|maven creds ({mv_loc})')
else:
    print('MISSING|maven creds (maven.user / maven.pass) -- graphrag pods will ImagePullBackOff')

ak = aws.get('accessKeyId')
sk = aws.get('secretAccessKey')
if filled(ak) and ak.strip().startswith('AKIA') and filled(sk):
    print(f'OK|Bedrock creds (awsCredentials.accessKeyId={ak.strip()[:8]}...)')
else:
    if not filled(ak) or not ak.strip().startswith('AKIA'):
        print('MISSING|Bedrock awsCredentials.accessKeyId (must start with AKIA)')
    if not filled(sk):
        print('MISSING|Bedrock awsCredentials.secretAccessKey')

ek = n8n.get('activationKey')
if filled(ek):
    print('OK|n8n license activation key')
else:
    print('MISSING|n8n license activationKey')
PY
)
    missing_count=0
    while IFS='|' read -r status detail; do
        case "$status" in
            OK)      printf '  OK:    %s\n' "$detail" ;;
            MISSING) printf '  %sMISSING%s: %s\n' "$YELLOW" "$RESET" "$detail"
                     missing_count=$((missing_count + 1)) ;;
        esac
    done <<<"$secrets_status"

    # Pause only if graphrag is in scope AND something is missing --
    # umbrella-only deploys don't need Bedrock/n8n license, and clean
    # files don't need to be warned about.
    if [[ $SKIP_GRAPHRAG -ne 1 && $missing_count -gt 0 ]]; then
        cat >&2 <<PREFLIGHT

${YELLOW}WARNING:${RESET} $missing_count secret(s) missing/placeholder.
graphrag-components / graphrag-workflows / chatbot pods will be
broken (ImagePullBackOff or AccessDeniedException) until you fill
them in. Edit ~/graphwise-secrets.yaml on this host (gitignored /
EC2-local) and re-run.

If you only need the umbrella (PoolParty + GraphDB + addons), pass
--skip-graphrag and these warnings disappear.

Continuing in 5 seconds; Ctrl-C now to abort.
PREFLIGHT
        sleep 5
    fi
fi

# ---------------------------------------------------------------------
# Confirm
# ---------------------------------------------------------------------
# Two layers of confirmation, because reset-helm wipes PVCs and most
# operators run it more aggressively than they need to:
#
#   Layer 1 (NEW, always shown even with --yes): a "do you actually
#   need to reset, or do you want a non-destructive helm upgrade
#   instead?" warning, with the exact upgrade commands to copy/paste
#   if so.
#
#   Layer 2 (existing, suppressed by --yes): "type 'reset' to proceed"
#   to confirm the destructive intent.
#
# What reset-helm DOES wipe: every PVC in graphwise / keycloak /
#   graphrag (Postgres data, Keycloak data, ES indices, GraphDB
#   repos, n8n workflows -- everything stateful in those namespaces).
#
# What reset-helm DOES NOT wipe (and you don't need to fear losing):
#   - The wildcard-tls Certificate + Secret in cert-manager ns
#     (managed by cert-manager, untouched by Helm uninstalls).
#   - The reflected wildcard-tls Secrets in the 5 consuming
#     namespaces (managed by reflector; kubectl delete pvc doesn't
#     touch Secrets).
#   - The 3 license Secrets in graphwise (preserved by uninstall;
#     re-created by install-licenses.sh if missing).
#   - LE rate-limit budget: reset-helm never reissues the wildcard
#     cert. Re-running this is free from LE's perspective.
cat <<WARNING

${BOLD:-}=========================================================================
About to RESET Helm releases for subdomain '$SUB.$BASE'.${RESET:-}

This is DESTRUCTIVE: every PVC in graphwise / graphdb / keycloak / graphrag
will be deleted (Postgres data, Keycloak data, ES indices, GraphDB
repos, n8n workflows). The wildcard TLS cert is NOT affected -- the
cert lives in cert-manager namespace and survives.

${YELLOW:-}If you only want to roll out a chart change (template edit, values
tweak, image bump), you almost certainly want \`helm upgrade\` instead --
it preserves all data and is non-destructive.${RESET:-}

  Non-destructive upgrade (data preserved):

      helm upgrade $UMBRELLA_RELEASE $UMBRELLA_CHART_DIR \\
          -n $UMBRELLA_NAMESPACE -f $UMBRELLA_VALUES \\
          -f $SECRETS_OVERLAY \\
          --timeout $HELM_TIMEOUT

  (The \`-f $SECRETS_OVERLAY\` is mandatory — without it the
  awsCredentials / n8nLicense / n8nEncryption values fall back to
  empty defaults and the resulting Secrets are unusable. K8s does
  not auto-roll pods when only a Secret's contents change, so
  follow up with \`kubectl -n $UMBRELLA_NAMESPACE rollout restart
  deploy\` if you're recovering from a previous upgrade that
  missed this flag.)

WARNING
if [[ $SKIP_GRAPHRAG -ne 1 ]]; then
    cat <<WARNING
      helm upgrade $GRAPHRAG_RELEASE $GRAPHRAG_CHART_DIR \\
          -n $GRAPHRAG_NAMESPACE \\
          -f $GRAPHRAG_CHART_DIR/values-graphwise.yaml \\
          -f $GRAPHRAG_VALUES \\
          -f $SECRETS_OVERLAY \\
          --timeout $HELM_TIMEOUT

WARNING
fi
cat <<WARNING
  When you DO need reset (initial deploy, base_domain change, schema
  migration that needs a clean DB, recovering from a half-broken
  previous deploy):

WARNING

echo "Reset plan:"
echo "  - helm uninstall $GRAPHRAG_RELEASE -n $GRAPHRAG_NAMESPACE  (graphrag pods first)"
echo "  - helm uninstall $UMBRELLA_RELEASE -n $UMBRELLA_NAMESPACE  (umbrella second)"
echo "  - kubectl delete pvc --all in: graphwise, graphdb, keycloak, graphrag"
if [[ $SKIP_GRAPHRAG -eq 1 ]]; then
    echo "  - regenerate $UMBRELLA_VALUES (graphrag overlay skipped)"
    echo "  - helm dependency update on umbrella chart"
    echo "  - helm upgrade --install $UMBRELLA_RELEASE only (--skip-graphrag)"
else
    echo "  - regenerate $UMBRELLA_VALUES + $GRAPHRAG_VALUES"
    echo "  - helm dependency update on both charts"
    echo "  - helm upgrade --install $UMBRELLA_RELEASE first, then $GRAPHRAG_RELEASE"
fi
echo "  - timeout per release: $HELM_TIMEOUT"
echo
echo "${BOLD:-}DATA LOSS: every PVC in those three namespaces will be deleted.${RESET:-}"
echo

# Layer 1: always-on "do you really want this?" question.
if [[ $ASSUME_YES -ne 1 ]]; then
    read -r -p "Reset is destructive. Did you mean 'helm upgrade' instead? [y to abort and use upgrade / N to continue with reset]: " upgrade_instead
    case "$upgrade_instead" in
        y|Y|yes|Yes|YES)
            echo "Aborted. Run the helm upgrade command(s) above instead."
            exit 0
            ;;
    esac
fi

# Layer 2: existing destructive-confirmation gate.
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
echo "Deleting PVCs in graphwise, graphdb, keycloak, graphrag namespaces..."
for ns in graphwise graphdb keycloak graphrag; do
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
    for ns in graphwise graphdb keycloak graphrag; do
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
# 3. Re-render values overlays
# ---------------------------------------------------------------------
echo "Rendering values overlays..."
"$SCRIPT_DIR/render-values.sh" --umbrella "$SUB" "$BASE" > "$UMBRELLA_VALUES"
echo "  $UMBRELLA_VALUES"
if [[ $SKIP_GRAPHRAG -eq 0 ]]; then
    "$SCRIPT_DIR/render-values.sh" --graphrag "$SUB" "$BASE" > "$GRAPHRAG_VALUES"
    echo "  $GRAPHRAG_VALUES"
fi

# ---------------------------------------------------------------------
# 4. Helm dep update
# ---------------------------------------------------------------------
# The vendor graphrag chart has its own dependencies (chatbot,
# conversation, components, workflows) that helm dep update on the
# umbrella does NOT recurse into. Skipping this is what produced
# `kubectl get pods -n graphrag` showing only postgres after a
# previous reset -- the chart packaged into the umbrella tarball had
# no inner subchart tarballs. Skip the graphrag chart entirely under
# --skip-graphrag.
echo "Updating chart dependencies..."
[[ $SKIP_GRAPHRAG -eq 0 ]] && helm dependency update "$GRAPHRAG_CHART_DIR"
helm dependency update "$UMBRELLA_CHART_DIR"

# ---------------------------------------------------------------------
# 4a. Image-pull secret for maven.ontotext.com (graphrag pods)
# ---------------------------------------------------------------------
# The graphrag release pulls private images from maven.ontotext.com.
# It needs a `graphwise` Secret of type kubernetes.io/dockerconfigjson
# in graphrag + graphwise namespaces.
#
# Source-of-truth precedence:
#   1. ~/graphwise-secrets.yaml top-level `maven:` block (preferred --
#      consolidates with Bedrock + n8n creds in one operator-managed
#      file; written by Terraform cloud-init).
#   2. ~/.ontotext/maven-user + maven-pass plain-text files (legacy --
#      kept for backward compat with operators who already have these).
#
# If neither source has values, WARN and continue. The umbrella
# installs fine without the secret; only graphrag pods will
# ImagePullBackOff.
MAVEN_USER=""
MAVEN_PASS=""
if [[ -f "$SECRETS_OVERLAY" ]]; then
    # Parse YAML via Python (always present on AL2023; PyYAML in stdlib
    # via system packages). Empty/missing values -> empty strings.
    # Canonical schema is top-level `maven:`. Fall back to the nested
    # `graphrag-secrets.maven:` form for files that grew that mistake
    # via hand-edits -- still works, but the operator should flatten.
    yaml_creds=$(SECRETS_OVERLAY="$SECRETS_OVERLAY" python3 <<'PY' 2>/dev/null
import os, sys, yaml
try:
    with open(os.environ['SECRETS_OVERLAY']) as f:
        d = yaml.safe_load(f) or {}
    m = d.get('maven') or {}
    user = (m.get('user') or '').strip() if isinstance(m.get('user'), str) else ''
    pw   = (m.get('pass') or '').strip() if isinstance(m.get('pass'), str) else ''
    nested_used = False
    if not user or not pw:
        gs = d.get('graphrag-secrets') or {}
        nm = gs.get('maven') or {}
        nu = (nm.get('user') or '').strip() if isinstance(nm.get('user'), str) else ''
        np = (nm.get('pass') or '').strip() if isinstance(nm.get('pass'), str) else ''
        if nu and np:
            user, pw = nu, np
            nested_used = True
    print(user)
    print(pw)
    print('NESTED' if nested_used else '')
except Exception:
    print(''); print(''); print('')
PY
)
    MAVEN_USER=$(echo "$yaml_creds" | sed -n '1p')
    MAVEN_PASS=$(echo "$yaml_creds" | sed -n '2p')
    MAVEN_NESTED=$(echo "$yaml_creds" | sed -n '3p')
    if [[ "$MAVEN_NESTED" == "NESTED" ]]; then
        echo "NOTE: maven creds found under graphrag-secrets.maven (legacy nested form);"
        echo "      canonical location is top-level 'maven:' in ~/graphwise-secrets.yaml."
    fi
fi
# Fallback to legacy plain-text files if the YAML didn't have them.
if [[ -z "$MAVEN_USER" && -f "$HOME/.ontotext/maven-user" ]]; then
    MAVEN_USER=$(tr -d '[:space:]' < "$HOME/.ontotext/maven-user")
fi
if [[ -z "$MAVEN_PASS" && -f "$HOME/.ontotext/maven-pass" ]]; then
    MAVEN_PASS=$(tr -d '[:space:]' < "$HOME/.ontotext/maven-pass")
fi

if [[ -n "$MAVEN_USER" && -n "$MAVEN_PASS" ]]; then
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
    echo "WARNING: maven creds not found (checked ~/graphwise-secrets.yaml"
    echo "         maven.user/maven.pass and ~/.ontotext/maven-{user,pass})."
    echo "         Skipping image-pull secret. Umbrella installs fine; graphrag"
    echo "         pods (chatbot, conversation, components, workflows) will"
    echo "         ImagePullBackOff until you fill in maven creds + re-run."
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
# 6. Install graphrag release in its own namespace (skipped under --skip-graphrag)
# ---------------------------------------------------------------------
if [[ $SKIP_GRAPHRAG -eq 1 ]]; then
    echo "Skipping graphrag release install (--skip-graphrag)."
    echo "When you have Maven creds, re-run without --skip-graphrag to add it."
else
    echo "Installing graphrag release '$GRAPHRAG_RELEASE' (timeout $HELM_TIMEOUT)..."
    helm upgrade --install "$GRAPHRAG_RELEASE" "$GRAPHRAG_CHART_DIR" -n "$GRAPHRAG_NAMESPACE" --create-namespace "${GRAPHRAG_F_FLAGS[@]}" --timeout "$HELM_TIMEOUT"
fi

echo
echo "=== Reset complete ==="
echo "Watch pods come up:"
echo "  kubectl get pods -A -w"
