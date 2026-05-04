#!/usr/bin/env bash
# pull-secrets.sh -- symmetric counterpart to scripts/laptop/push-secrets.sh.
# Pulls every operator-supplied artifact + the live LE wildcard cert
# off the EC2 to canonical paths on your laptop, ready for re-push to a
# fresh deployment after `terraform destroy/apply`.
#
# What's pulled:
#
#   1. EC2:~/graphwise-secrets.yaml              -> ~/graphwise-secrets.yaml
#      (single-file secrets: maven, Bedrock, n8n license, n8n encryption key)
#
#   2. EC2:~/graphwise-stack-aws/files/licenses/{poolparty.key,
#         graphdb.license,uv-license.key}        -> ~/graphwise-licenses/
#
#   3. The cluster's live wildcard TLS cert (kubectl get secret -n
#      cert-manager wildcard-tls -o yaml)        -> ~/graphwise-licenses/wildcard-tls.yaml
#      With kubectl-managed metadata stripped (resourceVersion, uid,
#      creationTimestamp, managedFields, ownerReferences) so a future
#      kubectl apply restores cleanly. push-secrets.sh re-pushes this
#      file to the new EC2; cluster-bootstrap.sh detects + restores
#      it (cert-manager sees a valid cert in place and skips the LE
#      issuance call -- saves a per-week LE rate-limit slot).
#
# Existing local files are backed up to <path>.bak-<UTC-timestamp>
# before being overwritten -- nothing destructive without a trail.
#
# Required env (or pass via flags):
#   GRAPHWISE_KEY    path to .pem
#   GRAPHWISE_HOST   subdomain or EIP
#   GRAPHWISE_USER   ec2-user (default)
#
# Usage:
#   ./scripts/laptop/pull-secrets.sh
#   ./scripts/laptop/pull-secrets.sh --secrets-file ~/path/to/secrets.yaml
#   ./scripts/laptop/pull-secrets.sh --licenses-dir ~/path/to/licenses
#   ./scripts/laptop/pull-secrets.sh --skip-cert            (don't pull the wildcard cert)
#   ./scripts/laptop/pull-secrets.sh --skip-secrets
#   ./scripts/laptop/pull-secrets.sh --skip-licenses
#
# Exit codes:
#   0 -- everything pulled (or selectively skipped per flags)
#   1 -- ssh / scp / kubectl failure
#   2 -- usage / missing env

set -euo pipefail

if [ -t 1 ]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; YELLOW=""; BOLD=""; DIM=""; RESET=""
fi

SECRETS_FILE="$HOME/graphwise-secrets.yaml"
LICENSES_DIR="$HOME/graphwise-licenses"
SKIP_SECRETS=no
SKIP_LICENSES=no
SKIP_CERT=no
while [ $# -gt 0 ]; do
    case "$1" in
        --secrets-file)  SECRETS_FILE="$2"; shift 2 ;;
        --licenses-dir)  LICENSES_DIR="$2"; shift 2 ;;
        --skip-secrets)  SKIP_SECRETS=yes; shift ;;
        --skip-licenses) SKIP_LICENSES=yes; shift ;;
        --skip-cert)     SKIP_CERT=yes; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) echo "${RED}Unknown flag: $1${RESET}" >&2; exit 2 ;;
        *)  echo "${RED}Unknown positional arg: $1${RESET}" >&2; exit 2 ;;
    esac
done

KEY="${GRAPHWISE_KEY:-}"
HOST="${GRAPHWISE_HOST:-}"
USR="${GRAPHWISE_USER:-ec2-user}"

if [ -z "$KEY" ] || [ -z "$HOST" ]; then
    cat >&2 <<USAGE
${RED}ERROR:${RESET} GRAPHWISE_KEY and GRAPHWISE_HOST must be set in the environment.
Set them once (per SETUP §7):
    export GRAPHWISE_KEY=~/.ssh/graphwise-stack.pem
    export GRAPHWISE_HOST=stroker.semantic-demo.com
    export GRAPHWISE_USER=ec2-user
USAGE
    exit 2
fi

mkdir -p "$LICENSES_DIR"

# Helper: back up an existing file before overwrite.
backup_if_exists() {
    local path="$1"
    if [ -f "$path" ]; then
        local ts
        ts=$(date -u +%Y%m%d-%H%M%S)
        cp -p "$path" "$path.bak-$ts"
        printf '  %s↻%s backed up existing %s -> %s.bak-%s\n' "$DIM" "$RESET" "$path" "$path" "$ts"
    fi
}

# ---------------------------------------------------------------------
# Phase 1: ~/graphwise-secrets.yaml
# ---------------------------------------------------------------------
if [ "$SKIP_SECRETS" != "yes" ]; then
    echo "${BOLD}== Secrets ==${RESET}"
    echo "Remote path: $USR@$HOST:~/graphwise-secrets.yaml"
    echo "Local file:  $SECRETS_FILE"
    backup_if_exists "$SECRETS_FILE"
    if scp -i "$KEY" "$USR@$HOST:~/graphwise-secrets.yaml" "$SECRETS_FILE" >/dev/null 2>&1; then
        printf '%s✓ pulled%s ~/graphwise-secrets.yaml\n' "$GREEN" "$RESET"
    else
        echo "${RED}✗ pull failed${RESET} (file missing on host? cloud-init not complete?)" >&2
        exit 1
    fi
    echo
fi

# ---------------------------------------------------------------------
# Phase 2: license files (graphwise-stack-aws/files/licenses/)
# ---------------------------------------------------------------------
if [ "$SKIP_LICENSES" != "yes" ]; then
    echo "${BOLD}== License files ==${RESET}"
    echo "Remote path: $USR@$HOST:~/graphwise-stack-aws/files/licenses/"
    echo "Local dir:   $LICENSES_DIR"
    pulled=0
    skipped=()
    for f in poolparty.key graphdb.license uv-license.key; do
        local_path="$LICENSES_DIR/$f"
        backup_if_exists "$local_path"
        if scp -i "$KEY" "$USR@$HOST:~/graphwise-stack-aws/files/licenses/$f" "$local_path" >/dev/null 2>&1; then
            printf '  %s✓%s pulled %s\n' "$GREEN" "$RESET" "$f"
            pulled=$((pulled + 1))
        else
            # Restore the backup we just made (the scp failed; don't leave a missing file behind)
            ts_glob="$local_path.bak-"*
            for bak in $ts_glob; do
                [ -f "$bak" ] && mv "$bak" "$local_path" && break
            done 2>/dev/null
            skipped+=("$f")
        fi
    done
    if [ ${#skipped[@]} -gt 0 ]; then
        printf '  %s⚠%s skipped (not on host):\n' "$YELLOW" "$RESET"
        for f in "${skipped[@]}"; do
            echo "       $f"
        done
    fi
    printf '%s✓ pulled %d/%d license file(s)%s\n' "$GREEN" "$pulled" "3" "$RESET"
    echo
fi

# ---------------------------------------------------------------------
# Phase 3: wildcard TLS cert (live from the cluster)
# ---------------------------------------------------------------------
if [ "$SKIP_CERT" != "yes" ]; then
    echo "${BOLD}== Wildcard TLS cert ==${RESET}"
    cert_local="$LICENSES_DIR/wildcard-tls.yaml"
    echo "Remote: kubectl get secret -n cert-manager wildcard-tls -o yaml"
    echo "Local:  $cert_local"
    backup_if_exists "$cert_local"

    # Pull as YAML, strip kubectl-managed metadata so re-apply is clean.
    cert_yaml=$(ssh -i "$KEY" "$USR@$HOST" '
kubectl get secret -n cert-manager wildcard-tls -o yaml 2>/dev/null | python3 -c "
import sys, yaml
d = yaml.safe_load(sys.stdin)
if not d:
    sys.exit(2)
m = d.get(\"metadata\", {})
for k in (\"resourceVersion\", \"uid\", \"creationTimestamp\", \"managedFields\", \"ownerReferences\", \"selfLink\", \"generation\"):
    m.pop(k, None)
# Drop the cert-manager-controller-set annotations that re-apply would
# fight with cert-manager over -- it re-adds them on next reconcile.
ann = m.get(\"annotations\", {}) or {}
for k in list(ann.keys()):
    if k.startswith(\"cert-manager.io/\"):
        del ann[k]
if not ann:
    m.pop(\"annotations\", None)
# Drop labels likewise.
lab = m.get(\"labels\", {}) or {}
for k in list(lab.keys()):
    if k.startswith(\"controller.cert-manager.io/\"):
        del lab[k]
print(yaml.safe_dump(d, default_flow_style=False, sort_keys=False))
"
' 2>/dev/null)
    if [ -z "$cert_yaml" ]; then
        echo "${YELLOW}⚠ skipped${RESET} (wildcard-tls Secret not present in cert-manager ns -- has cluster-bootstrap.sh run?)" >&2
        echo
    else
        printf '%s' "$cert_yaml" > "$cert_local"
        # Print cert metadata so the operator sees what they pulled.
        cert_pem=$(python3 -c "
import yaml, base64
with open('$cert_local') as f:
    d = yaml.safe_load(f)
print(base64.b64decode(d['data']['tls.crt']).decode())
")
        sans=$(echo "$cert_pem" | openssl x509 -noout -ext subjectAltName 2>/dev/null | grep -oE 'DNS:[^,]+' | sed 's/DNS://; s/^ //' | tr '\n' ' ')
        issuer=$(echo "$cert_pem" | openssl x509 -noout -issuer 2>/dev/null | sed 's/issuer=//')
        not_after=$(echo "$cert_pem" | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//')
        # Days remaining (cross-platform date math).
        not_after_epoch=$(date -j -f "%b %d %T %Y %Z" "$not_after" +%s 2>/dev/null || date -d "$not_after" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        days_remaining=$(( (not_after_epoch - now_epoch) / 86400 ))
        printf '%s✓ pulled%s wildcard-tls.yaml\n' "$GREEN" "$RESET"
        printf '  %sIssuer:%s    %s\n' "$DIM" "$RESET" "$issuer"
        printf '  %sSANs:%s      %s\n' "$DIM" "$RESET" "$sans"
        printf '  %sNot After:%s %s (%s days remaining)\n' "$DIM" "$RESET" "$not_after" "$days_remaining"
        if [ "$days_remaining" -lt 30 ]; then
            printf '  %s⚠ cert expires within 30 days -- restore on a fresh deploy will let cert-manager renew anyway%s\n' "$YELLOW" "$RESET"
        fi
        echo
    fi
fi

# ---------------------------------------------------------------------
# Verify hint
# ---------------------------------------------------------------------
echo "Verify locally:"
echo "  ls -la $SECRETS_FILE $LICENSES_DIR/"
echo
echo "After next terraform apply, restore everything in one shot via:"
echo "  ./scripts/laptop/push-secrets.sh"
