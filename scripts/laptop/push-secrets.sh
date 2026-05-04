#!/usr/bin/env bash
# push-secrets.sh -- copy your locally-saved operator-supplied artifacts
# (secrets YAML + license files) to the EC2 host, in the locations
# reset-helm.sh + install-licenses.sh expect them. Reuse pattern: keep
# canonical copies on your laptop (gitignored), re-push after every
# `terraform destroy && terraform apply` cycle. That preserves all
# operator-supplied material across rebuilds without re-typing or
# re-downloading from Graphwise.
#
# What's pushed:
#
#   1. ~/graphwise-secrets.yaml  (single-file secrets: maven, Bedrock,
#                                  n8n license, n8n encryption key) ->
#                                 EC2:~/graphwise-secrets.yaml
#
#   2. ~/graphwise-licenses/poolparty.key      ->
#      ~/graphwise-licenses/graphdb.license      EC2:~/graphwise-stack-aws/files/licenses/
#      ~/graphwise-licenses/uv-license.key
#
#      Filenames are required (install-licenses.sh looks for these
#      exact names). Missing files are warned + skipped, not fatal --
#      lets operators push partial sets during initial onboarding.
#
#   3. ~/graphwise-licenses/wildcard-tls.yaml  (saved by pull-secrets.sh
#      from a prior deployment's live wildcard cert) ->
#                                 EC2:~/wildcard-tls-saved.yaml
#
#      cluster-bootstrap.sh detects this file and applies the Secret
#      BEFORE creating the wildcard Certificate resource. cert-manager
#      sees a valid cert in place and skips the LE issuance call --
#      saves a per-week LE rate-limit slot. Cert is validated for
#      expiry + SAN match before restore; if it fails, cert-manager
#      issues fresh as normal.
#
#      Optional: if you don't have a saved cert yet (first deploy on
#      this domain), this is just skipped.
#
# Important n8nEncryption note: cloud-init wrote a fresh
# n8nEncryption.key into the EC2's ~/graphwise-secrets.yaml. By default
# this script preserves THAT key (splices it into your local copy
# before push), so the new n8n DB is encryptable with the key it was
# given on first boot. Your local copy's old key is from the
# PREVIOUS deployment and is useless against the new n8n DB.
# Override with --keep-local-encryption-key only if you know you're
# restoring against the same n8n DB the old key encrypted.
#
# Required env (or pass via flags):
#   GRAPHWISE_KEY    path to .pem
#   GRAPHWISE_HOST   subdomain or EIP
#   GRAPHWISE_USER   ec2-user (default)
#
# Usage:
#   ./scripts/laptop/push-secrets.sh
#   ./scripts/laptop/push-secrets.sh --secrets-file ~/path/to/secrets.yaml
#   ./scripts/laptop/push-secrets.sh --licenses-dir ~/path/to/licenses
#   ./scripts/laptop/push-secrets.sh --skip-licenses          (only push the secrets file)
#   ./scripts/laptop/push-secrets.sh --skip-secrets           (only push licenses)
#   ./scripts/laptop/push-secrets.sh --keep-local-encryption-key
#
# Exit codes:
#   0 -- everything pushed (or selectively skipped per flags)
#   1 -- ssh / scp / merge failure
#   2 -- usage / missing local file / missing env

set -euo pipefail

if [ -t 1 ]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; YELLOW=""; BOLD=""; DIM=""; RESET=""
fi

SECRETS_FILE="$HOME/graphwise-secrets.yaml"
LICENSES_DIR="$HOME/graphwise-licenses"
KEEP_LOCAL_ENCRYPTION_KEY=no
SKIP_SECRETS=no
SKIP_LICENSES=no
SKIP_CERT=no
while [ $# -gt 0 ]; do
    case "$1" in
        --secrets-file)              SECRETS_FILE="$2"; shift 2 ;;
        --licenses-dir)              LICENSES_DIR="$2"; shift 2 ;;
        --skip-secrets)              SKIP_SECRETS=yes; shift ;;
        --skip-licenses)             SKIP_LICENSES=yes; shift ;;
        --skip-cert)                 SKIP_CERT=yes; shift ;;
        --keep-local-encryption-key) KEEP_LOCAL_ENCRYPTION_KEY=yes; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) echo "${RED}Unknown flag: $1${RESET}" >&2; exit 2 ;;
        *)  # legacy positional: treat as secrets file path
            SECRETS_FILE="$1"; shift ;;
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

# ---------------------------------------------------------------------
# Phase 1: ~/graphwise-secrets.yaml
# ---------------------------------------------------------------------
if [ "$SKIP_SECRETS" != "yes" ]; then
    if [ ! -f "$SECRETS_FILE" ]; then
        cat >&2 <<USAGE
${RED}ERROR:${RESET} secrets file not found: $SECRETS_FILE

Create one by either:
  (a) Pulling the EC2 copy down first time you push this:
      scp -i \$GRAPHWISE_KEY \$GRAPHWISE_USER@\$GRAPHWISE_HOST:~/graphwise-secrets.yaml ~/
  (b) Copy charts/graphwise-stack/values.yaml's graphrag-secrets block
      into a new file at \$HOME/graphwise-secrets.yaml and add a
      maven: block at the top -- see infra/terraform/user-data.sh.tpl
      for the full template.

Or pass --skip-secrets if you only want to push licenses this run.
USAGE
        exit 2
    fi

    echo "${BOLD}== Secrets ==${RESET}"
    echo "Local file:  $SECRETS_FILE"
    echo "Remote path: $USR@$HOST:~/graphwise-secrets.yaml"

    # n8nEncryption.key handling: splice the fresh remote key into a temp
    # copy of the local file before push, so we don't carry the old key
    # from a destroyed n8n DB onto the new one.
    if [ "$KEEP_LOCAL_ENCRYPTION_KEY" = "no" ]; then
        echo "Reading fresh n8nEncryption.key from remote..."
        REMOTE_KEY=$(ssh -i "$KEY" "$USR@$HOST" 'python3 -c "
import yaml
with open(\"/home/ec2-user/graphwise-secrets.yaml\") as f:
    d = yaml.safe_load(f) or {}
print(((d.get(\"graphrag-secrets\") or {}).get(\"n8nEncryption\") or {}).get(\"key\") or \"\")
"' 2>/dev/null)
        if [ -z "$REMOTE_KEY" ]; then
            echo "${RED}ERROR:${RESET} couldn't read n8nEncryption.key from remote ~/graphwise-secrets.yaml" >&2
            echo "Is the EC2 cloud-init complete? Verify with:" >&2
            echo "  ssh -i \$GRAPHWISE_KEY \$GRAPHWISE_USER@\$GRAPHWISE_HOST 'cat ~/graphwise-secrets.yaml'" >&2
            exit 1
        fi
        printf '%s✓ remote n8nEncryption.key (first 8): %s...%s\n' "$GREEN" "${REMOTE_KEY:0:8}" "$RESET"

        TMP_FILE=$(mktemp -t graphwise-secrets.XXXXXX.yaml)
        trap 'rm -f "$TMP_FILE"' EXIT
        REMOTE_KEY="$REMOTE_KEY" python3 -c "
import os, yaml, sys
with open('$SECRETS_FILE') as f:
    d = yaml.safe_load(f) or {}
gs = d.setdefault('graphrag-secrets', {})
gs.setdefault('n8nEncryption', {})['key'] = os.environ['REMOTE_KEY']
with open('$TMP_FILE', 'w') as f:
    yaml.safe_dump(d, f, default_flow_style=False, sort_keys=False)
"
        PUSH_FILE="$TMP_FILE"
        echo "${DIM}Spliced fresh remote key into temp copy; your local file is unchanged.${RESET}"
    else
        echo "${YELLOW}--keep-local-encryption-key:${RESET} pushing local file as-is."
        PUSH_FILE="$SECRETS_FILE"
    fi

    scp -i "$KEY" "$PUSH_FILE" "$USR@$HOST:~/graphwise-secrets.yaml" >/dev/null
    printf '%s✓ pushed%s ~/graphwise-secrets.yaml\n' "$GREEN" "$RESET"
    echo
fi

# ---------------------------------------------------------------------
# Phase 2: license files -> ~/graphwise-stack-aws/files/licenses/
# ---------------------------------------------------------------------
if [ "$SKIP_LICENSES" != "yes" ]; then
    echo "${BOLD}== License files ==${RESET}"
    if [ ! -d "$LICENSES_DIR" ]; then
        cat >&2 <<USAGE
${YELLOW}WARNING:${RESET} licenses directory not found: $LICENSES_DIR

Skipping license push. To create the directory:
    mkdir -p $LICENSES_DIR
    # then drop your three vendor files into it with these EXACT names:
    #   $LICENSES_DIR/poolparty.key
    #   $LICENSES_DIR/graphdb.license
    #   $LICENSES_DIR/uv-license.key

(Or pass --skip-licenses to suppress this warning.)
USAGE
    else
        echo "Local dir:    $LICENSES_DIR"
        echo "Remote path:  $USR@$HOST:~/graphwise-stack-aws/files/licenses/"

        # Ensure the remote dir exists. graphwise-stack-aws is cloned by
        # cloud-init, so it should already; safeguard against fresh-deploy
        # timing or unusual layouts.
        ssh -i "$KEY" "$USR@$HOST" 'mkdir -p ~/graphwise-stack-aws/files/licenses && chmod 700 ~/graphwise-stack-aws/files/licenses' >/dev/null

        pushed=0
        skipped=()
        for f in poolparty.key graphdb.license uv-license.key; do
            if [ -f "$LICENSES_DIR/$f" ]; then
                scp -i "$KEY" "$LICENSES_DIR/$f" \
                    "$USR@$HOST:~/graphwise-stack-aws/files/licenses/$f" >/dev/null
                printf '  %s✓%s pushed %s\n' "$GREEN" "$RESET" "$f"
                pushed=$((pushed + 1))
            else
                skipped+=("$f")
            fi
        done
        if [ ${#skipped[@]} -gt 0 ]; then
            echo
            printf '  %s⚠%s skipped (not in %s):\n' "$YELLOW" "$RESET" "$LICENSES_DIR"
            for f in "${skipped[@]}"; do
                echo "       $f"
            done
        fi
        echo
        printf '%s✓ pushed %d/%d license file(s)%s\n' "$GREEN" "$pushed" "3" "$RESET"
        echo
    fi
fi

# ---------------------------------------------------------------------
# Phase 3: saved wildcard cert -> EC2:~/wildcard-tls-saved.yaml
# ---------------------------------------------------------------------
if [ "$SKIP_CERT" != "yes" ]; then
    echo "${BOLD}== Wildcard TLS cert (saved from prior deployment) ==${RESET}"
    cert_local="$LICENSES_DIR/wildcard-tls.yaml"
    if [ ! -f "$cert_local" ]; then
        printf '  %s⚠%s no saved cert at %s -- skipping (cluster-bootstrap.sh will let cert-manager issue fresh from LE)\n' "$YELLOW" "$RESET" "$cert_local"
    else
        # Print summary of what we're about to push, including expiry,
        # so the operator sees whether restore will save an LE rate-limit
        # slot or whether cert-manager will renew it shortly anyway.
        cert_pem=$(python3 -c "
import yaml, base64
with open('$cert_local') as f:
    d = yaml.safe_load(f)
print(base64.b64decode(d['data']['tls.crt']).decode())
" 2>/dev/null)
        if [ -z "$cert_pem" ]; then
            printf '  %s⚠%s could not decode cert from %s -- skipping push\n' "$YELLOW" "$RESET" "$cert_local"
        else
            sans=$(echo "$cert_pem" | openssl x509 -noout -ext subjectAltName 2>/dev/null | grep -oE 'DNS:[^,]+' | sed 's/DNS://; s/^ //' | tr '\n' ' ')
            not_after=$(echo "$cert_pem" | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//')
            not_after_epoch=$(date -j -f "%b %d %T %Y %Z" "$not_after" +%s 2>/dev/null || date -d "$not_after" +%s 2>/dev/null || echo 0)
            now_epoch=$(date +%s)
            days_remaining=$(( (not_after_epoch - now_epoch) / 86400 ))
            printf '  %sLocal:%s     %s\n' "$DIM" "$RESET" "$cert_local"
            printf '  %sRemote:%s    %s@%s:~/wildcard-tls-saved.yaml\n' "$DIM" "$RESET" "$USR" "$HOST"
            printf '  %sSANs:%s      %s\n' "$DIM" "$RESET" "$sans"
            printf '  %sNot After:%s %s (%s days remaining)\n' "$DIM" "$RESET" "$not_after" "$days_remaining"
            if [ "$days_remaining" -lt 30 ]; then
                printf '  %s⚠ cert expiring within 30 days -- cluster-bootstrap will restore it but cert-manager will renew shortly%s\n' "$YELLOW" "$RESET"
            fi
            scp -i "$KEY" "$cert_local" "$USR@$HOST:~/wildcard-tls-saved.yaml" >/dev/null
            printf '%s✓ pushed%s wildcard-tls-saved.yaml (cluster-bootstrap will detect + restore before LE issuance)\n' "$GREEN" "$RESET"
        fi
    fi
    echo
fi

# ---------------------------------------------------------------------
# Verify hint
# ---------------------------------------------------------------------
echo "Verify on EC2:"
echo "  ssh -i \$GRAPHWISE_KEY \$GRAPHWISE_USER@\$GRAPHWISE_HOST 'ls -la ~/graphwise-secrets.yaml ~/wildcard-tls-saved.yaml ~/graphwise-stack-aws/files/licenses/ 2>/dev/null'"
echo
echo "Then on EC2 (in this order):"
echo "  ./scripts/cluster-bootstrap.sh   # auto-restores wildcard cert if pushed; saves an LE rate-limit slot"
echo "  ./scripts/install-licenses.sh    # turns license files into K8s Secrets"
echo "  ./scripts/reset-helm.sh stroker  # picks up secrets via -f overlay"
