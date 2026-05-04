#!/usr/bin/env bash
# pull-secrets.sh -- one ssh, one tar pipeline. Pulls every operator-
# supplied artifact + the live LE wildcard cert off the EC2 as a single
# tarball; extracts to canonical paths on your laptop.
#
# Why one tarball: each scp is a fresh SSH connection (handshake
# latency, partial-failure mode per file). One tarball + one SSH means
# atomic-or-nothing: either all files arrive or none do.
#
# What's pulled (canonical local paths):
#
#   1. EC2:~/graphwise-secrets.yaml              -> ~/graphwise-secrets.yaml
#
#   2. EC2:~/graphwise-stack-aws/files/licenses/{poolparty.key,
#         graphdb.license,uv-license.key}        -> ~/graphwise-licenses/
#
#   3. The cluster's live wildcard TLS cert (kubectl get secret -n
#      cert-manager wildcard-tls -o yaml)        -> ~/graphwise-licenses/wildcard-tls.yaml
#      With kubectl-managed metadata stripped (resourceVersion, uid,
#      ownerReferences, controller annotations) so push-secrets.sh's
#      kubectl apply restores cleanly. cluster-bootstrap.sh detects
#      the saved cert on the next deploy and applies the Secret
#      BEFORE creating the Certificate resource -- cert-manager sees
#      a valid cert in place and skips LE issuance entirely (saves
#      a per-week LE rate-limit slot).
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
#   ./scripts/laptop/pull-secrets.sh --skip-secrets
#   ./scripts/laptop/pull-secrets.sh --skip-licenses
#   ./scripts/laptop/pull-secrets.sh --skip-cert
#
# Exit codes:
#   0 -- everything pulled (or selectively skipped per flags)
#   1 -- ssh / tar / kubectl failure
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
# Build the remote snippet: stage selected files into a temp dir + emit
# tar.gz on stdout. PRESENT/MISSING inventory on stderr.
# ---------------------------------------------------------------------
WANT_SECRETS=$([ "$SKIP_SECRETS" = "yes" ] && echo 0 || echo 1)
WANT_LICENSES=$([ "$SKIP_LICENSES" = "yes" ] && echo 0 || echo 1)
WANT_CERT=$([ "$SKIP_CERT" = "yes" ] && echo 0 || echo 1)

REMOTE_BUILD=$(cat <<REMOTE
set -euo pipefail
RDIR=\$(mktemp -d /tmp/graphwise-pull.XXXXXX)
trap "rm -rf \"\$RDIR\"" EXIT

if [ "$WANT_SECRETS" = "1" ]; then
    if [ -f "\$HOME/graphwise-secrets.yaml" ]; then
        cp -p "\$HOME/graphwise-secrets.yaml" "\$RDIR/graphwise-secrets.yaml"
        echo "PRESENT:~/graphwise-secrets.yaml" >&2
    else
        echo "MISSING:~/graphwise-secrets.yaml" >&2
    fi
fi

if [ "$WANT_LICENSES" = "1" ]; then
    mkdir -p "\$RDIR/licenses"
    for f in poolparty.key graphdb.license uv-license.key; do
        if [ -f "\$HOME/graphwise-stack-aws/files/licenses/\$f" ]; then
            cp -p "\$HOME/graphwise-stack-aws/files/licenses/\$f" "\$RDIR/licenses/\$f"
            echo "PRESENT:licenses/\$f" >&2
        else
            echo "MISSING:licenses/\$f" >&2
        fi
    done
fi

if [ "$WANT_CERT" = "1" ]; then
    if kubectl get secret -n cert-manager wildcard-tls >/dev/null 2>&1; then
        kubectl get secret -n cert-manager wildcard-tls -o yaml | python3 -c "
import sys, yaml
d = yaml.safe_load(sys.stdin)
m = d.get('metadata', {})
for k in ('resourceVersion', 'uid', 'creationTimestamp', 'managedFields',
          'ownerReferences', 'selfLink', 'generation'):
    m.pop(k, None)
ann = m.get('annotations', {}) or {}
for k in list(ann.keys()):
    if k.startswith('cert-manager.io/'):
        del ann[k]
if not ann: m.pop('annotations', None)
lab = m.get('labels', {}) or {}
for k in list(lab.keys()):
    if k.startswith('controller.cert-manager.io/'):
        del lab[k]
if not lab: m.pop('labels', None)
print(yaml.safe_dump(d, default_flow_style=False, sort_keys=False))
" > "\$RDIR/wildcard-tls.yaml"
        echo "PRESENT:wildcard-tls.yaml" >&2
    else
        echo "MISSING:wildcard-tls.yaml (no Secret in cert-manager ns)" >&2
    fi
fi

tar -czf - -C "\$RDIR" .
REMOTE
)

# ---------------------------------------------------------------------
# One ssh, one tar pipeline. stdout = bytes, stderr = inventory.
# ---------------------------------------------------------------------
echo "${BOLD}Pulling tarball from $USR@$HOST in one ssh...${RESET}"

TARBALL=$(mktemp -t graphwise-pull.XXXXXX.tgz)
INVENTORY=$(mktemp -t graphwise-pull-inv.XXXXXX)
trap 'rm -f "$TARBALL" "$INVENTORY"' EXIT

if ! ssh -i "$KEY" -o StrictHostKeyChecking=accept-new \
        "$USR@$HOST" "bash -s" \
        > "$TARBALL" \
        2> "$INVENTORY" \
        <<<"$REMOTE_BUILD"; then
    echo "${RED}ERROR: remote tar pipeline failed. Inventory so far:${RESET}" >&2
    cat "$INVENTORY" >&2
    exit 1
fi

# Replay remote inventory.
echo
while IFS= read -r line; do
    case "$line" in
        PRESENT:*) printf '  %s✓%s on host: %s\n' "$GREEN" "$RESET" "${line#PRESENT:}" ;;
        MISSING:*) printf '  %s⚠%s missing:  %s\n' "$YELLOW" "$RESET" "${line#MISSING:}" ;;
        *)         printf '  %s\n' "$line" ;;
    esac
done < "$INVENTORY"

# ---------------------------------------------------------------------
# Extract locally to canonical paths (with backup of existing).
# ---------------------------------------------------------------------
EXTRACT_DIR=$(mktemp -d -t graphwise-pull-extract.XXXXXX)
trap 'rm -f "$TARBALL" "$INVENTORY"; rm -rf "$EXTRACT_DIR"' EXIT
tar -xzf "$TARBALL" -C "$EXTRACT_DIR"

echo
echo "${BOLD}Extracting to canonical local paths...${RESET}"

if [ -f "$EXTRACT_DIR/graphwise-secrets.yaml" ]; then
    backup_if_exists "$SECRETS_FILE"
    install -m 0600 "$EXTRACT_DIR/graphwise-secrets.yaml" "$SECRETS_FILE"
    printf '  %s✓%s wrote %s\n' "$GREEN" "$RESET" "$SECRETS_FILE"
fi

if [ -d "$EXTRACT_DIR/licenses" ]; then
    for f in "$EXTRACT_DIR"/licenses/*; do
        [ -f "$f" ] || continue
        name=$(basename "$f")
        local_path="$LICENSES_DIR/$name"
        backup_if_exists "$local_path"
        install -m 0600 "$f" "$local_path"
        printf '  %s✓%s wrote %s\n' "$GREEN" "$RESET" "$local_path"
    done
fi

if [ -f "$EXTRACT_DIR/wildcard-tls.yaml" ]; then
    cert_local="$LICENSES_DIR/wildcard-tls.yaml"
    backup_if_exists "$cert_local"
    install -m 0600 "$EXTRACT_DIR/wildcard-tls.yaml" "$cert_local"
    printf '  %s✓%s wrote %s\n' "$GREEN" "$RESET" "$cert_local"

    # Cert summary so the operator sees what they captured.
    cert_pem=$(python3 -c "
import yaml, base64
with open('$cert_local') as f:
    d = yaml.safe_load(f)
print(base64.b64decode(d['data']['tls.crt']).decode())
" 2>/dev/null)
    if [ -n "$cert_pem" ]; then
        sans=$(echo "$cert_pem" | openssl x509 -noout -ext subjectAltName 2>/dev/null | grep -oE 'DNS:[^,]+' | sed 's/DNS://; s/^ //' | tr '\n' ' ')
        not_after=$(echo "$cert_pem" | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//')
        not_after_epoch=$(date -j -f "%b %d %T %Y %Z" "$not_after" +%s 2>/dev/null || date -d "$not_after" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        days_remaining=$(( (not_after_epoch - now_epoch) / 86400 ))
        printf '       %sSANs:%s      %s\n' "$DIM" "$RESET" "$sans"
        printf '       %sNot After:%s %s (%s days remaining)\n' "$DIM" "$RESET" "$not_after" "$days_remaining"
    fi
fi

echo
echo "After next ${BOLD}terraform apply${RESET}, restore everything in one shot:"
echo "  ./scripts/laptop/push-secrets.sh"
