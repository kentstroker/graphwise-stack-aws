#!/usr/bin/env bash
# push-config.sh -- one ssh, one tar pipeline. Pushes every operator-
# supplied artifact + (optionally) a saved LE wildcard cert to the EC2
# host as a single tarball; a remote bash snippet extracts to canonical
# paths.
#
# Why one tarball: each scp is a fresh SSH connection (handshake
# latency, partial-failure mode per file). One tarball + one SSH means
# atomic-or-nothing: either all files arrive or none do.
#
# What's pushed (canonical local paths):
#
#   1. ~/graphwise-secrets.yaml      -> EC2:~/graphwise-secrets.yaml
#      Single-file secrets: maven, Bedrock, n8n license, n8n encryption.
#
#   2. ~/graphwise-licenses/poolparty.key      ->
#      ~/graphwise-licenses/graphdb.license       EC2:~/graphwise-stack-aws/files/licenses/
#      ~/graphwise-licenses/uv-license.key
#
#   3. ~/graphwise-licenses/wildcard-tls.yaml  -> EC2:~/wildcard-tls-saved.yaml
#      Saved LE wildcard cert from a prior pull-config.sh.
#      cluster-bootstrap.sh detects + restores it (cert-manager sees
#      a valid Secret in place and skips LE issuance -- saves a
#      per-week LE rate-limit slot).
#
# Missing files are warned + skipped, not fatal.
#
# n8nEncryption.key handling: by default we read the FRESH key from
# the EC2's pre-existing ~/graphwise-secrets.yaml (cloud-init wrote it)
# and splice it into a temp copy of your local secrets file before
# tarring. The local file's old key is from a destroyed n8n DB and
# is useless on the new one. --keep-local-encryption-key overrides.
#
# Required env (or pass via flags):
#   GRAPHWISE_KEY    path to .pem
#   GRAPHWISE_HOST   subdomain or EIP
#   GRAPHWISE_USER   ec2-user (default)
#
# Usage:
#   ./scripts/laptop/push-config.sh
#   ./scripts/laptop/push-config.sh --secrets-file ~/path/to/secrets.yaml
#   ./scripts/laptop/push-config.sh --licenses-dir ~/path/to/licenses
#   ./scripts/laptop/push-config.sh --skip-secrets
#   ./scripts/laptop/push-config.sh --skip-licenses
#   ./scripts/laptop/push-config.sh --skip-cert
#   ./scripts/laptop/push-config.sh --keep-local-encryption-key
#
# Exit codes:
#   0 -- all selected items pushed
#   1 -- ssh / tar / merge failure
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
        *)  SECRETS_FILE="$1"; shift ;;   # legacy positional
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

# PyYAML is required for the n8n-encryption-key splice + cert summary.
# Fail fast with a clear fix rather than letting a python traceback
# surface mid-run.
if ! python3 -c "import yaml" >/dev/null 2>&1; then
    cat >&2 <<DEPS
${RED}ERROR:${RESET} python3 module 'yaml' (PyYAML) not found on this laptop.
Install once with:
    pip3 install --user pyyaml
        # or, on Homebrew Python:  /opt/homebrew/bin/pip3 install pyyaml
        # or, on system Python:    sudo pip3 install pyyaml
DEPS
    exit 2
fi

# ---------------------------------------------------------------------
# Stage files locally into a temp dir; the tar gets built from there.
# ---------------------------------------------------------------------
STAGE=$(mktemp -d -t graphwise-push.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT

echo "${BOLD}Staging payload locally...${RESET}"

# Phase 1: secrets file (with optional fresh-encryption-key splice)
if [ "$SKIP_SECRETS" != "yes" ]; then
    if [ ! -f "$SECRETS_FILE" ]; then
        cat >&2 <<USAGE
${RED}ERROR:${RESET} secrets file not found: $SECRETS_FILE
Create one (see DEPLOY step 3) or pass --skip-secrets.
USAGE
        exit 2
    fi
    # Sniff for accidental tarball / gzip / non-text payload. The
    # canonical mistake is passing the snapshot's payload.tgz here
    # instead of the extracted graphwise-secrets.yaml; without this
    # check the script later trips a UnicodeDecodeError deep in
    # PyYAML's reader and the operator burns time tracing it.
    magic=$(head -c 4 "$SECRETS_FILE" 2>/dev/null | od -An -tx1 | tr -d ' \n')
    case "$magic" in
        1f8b*)  # gzip
            cat >&2 <<USAGE
${RED}ERROR:${RESET} --secrets-file points at a gzipped tarball (gzip magic 1f8b detected):
  $SECRETS_FILE

You probably meant the EXTRACTED graphwise-secrets.yaml from the snapshot.
If your snapshot dir is "\$SNAP", try:
  --secrets-file "\$SNAP/graphwise-secrets.yaml"
USAGE
            exit 2 ;;
        *)
            # Quick text-vs-binary heuristic: the first byte should be
            # printable ASCII (yaml file starts with '#' or 'm' or 'g' etc).
            first_byte=$(head -c 1 "$SECRETS_FILE" | od -An -tx1 | tr -d ' \n')
            if [ -n "$first_byte" ] && [ "$first_byte" \< "20" ] && [ "$first_byte" != "0a" ] && [ "$first_byte" != "09" ]; then
                cat >&2 <<USAGE
${RED}ERROR:${RESET} --secrets-file doesn't look like text (first byte: 0x$first_byte):
  $SECRETS_FILE
Expected a YAML file. Did you point at a binary by accident?
USAGE
                exit 2
            fi ;;
    esac
    # Splice strategy (one SSH, two merge rules):
    #   - n8nEncryption.key:  REMOTE wins. The local file's key is from
    #     a prior destroyed n8n DB; the current EC2's cloud-init-
    #     generated key is what the live n8n install will accept.
    #     Override unless --keep-local-encryption-key.
    #   - maven.user/pass:    LOCAL wins if filled; remote fills empties.
    #     Why flipped vs n8n: maven creds are operator-supplied + stable
    #     across rebuilds, and an old snapshot (or one taken before
    #     maven was filled in) would otherwise CLOBBER good creds the
    #     operator already typed into the fresh EC2.
    echo "  reading remote graphwise-secrets.yaml metadata..."
    REMOTE_VALUES=$(ssh -i "$KEY" -o StrictHostKeyChecking=accept-new "$USR@$HOST" 'python3 -c "
import yaml
with open(\"/home/ec2-user/graphwise-secrets.yaml\") as f:
    d = yaml.safe_load(f) or {}
gs = d.get(\"graphrag-secrets\") or {}
mv = d.get(\"maven\") or {}
print(((gs.get(\"n8nEncryption\") or {}).get(\"key\")) or \"\")
print((mv.get(\"user\") or \"\").strip() if isinstance(mv.get(\"user\"), str) else \"\")
print((mv.get(\"pass\") or \"\").strip() if isinstance(mv.get(\"pass\"), str) else \"\")
"' 2>/dev/null) || REMOTE_VALUES=$'\n\n'
    REMOTE_KEY=$(printf '%s' "$REMOTE_VALUES" | sed -n '1p')
    REMOTE_MAVEN_USER=$(printf '%s' "$REMOTE_VALUES" | sed -n '2p')
    REMOTE_MAVEN_PASS=$(printf '%s' "$REMOTE_VALUES" | sed -n '3p')

    if [ "$KEEP_LOCAL_ENCRYPTION_KEY" = "no" ] && [ -z "$REMOTE_KEY" ]; then
        echo "${RED}ERROR:${RESET} couldn't read remote n8nEncryption.key (cloud-init not complete?)" >&2
        exit 1
    fi
    if [ "$KEEP_LOCAL_ENCRYPTION_KEY" = "no" ]; then
        printf '  %s✓%s fresh n8nEncryption.key (first 8): %s...\n' "$GREEN" "$RESET" "${REMOTE_KEY:0:8}"
    fi

    # Single python invocation: merges into $STAGE/graphwise-secrets.yaml
    # and emits status markers on stdout (captured below).
    MERGE_STATUS=$(SRC="$SECRETS_FILE" DST="$STAGE/graphwise-secrets.yaml" \
                   REMOTE_KEY="$REMOTE_KEY" \
                   REMOTE_MAVEN_USER="$REMOTE_MAVEN_USER" \
                   REMOTE_MAVEN_PASS="$REMOTE_MAVEN_PASS" \
                   KEEP_KEY="$KEEP_LOCAL_ENCRYPTION_KEY" \
                   python3 <<'PY'
import os, sys, yaml
with open(os.environ['SRC']) as f:
    d = yaml.safe_load(f) or {}

# n8nEncryption.key: remote wins unless --keep-local-encryption-key.
if os.environ.get('KEEP_KEY') != 'yes':
    gs = d.setdefault('graphrag-secrets', {})
    gs.setdefault('n8nEncryption', {})['key'] = os.environ['REMOTE_KEY']

# maven.user/maven.pass: local wins; remote fills empties only.
def empty(v):
    return not (isinstance(v, str) and v.strip())

mv = d.setdefault('maven', {})
preserved = []
if empty(mv.get('user')) and os.environ.get('REMOTE_MAVEN_USER', '').strip():
    mv['user'] = os.environ['REMOTE_MAVEN_USER'].strip()
    preserved.append('maven.user')
if empty(mv.get('pass')) and os.environ.get('REMOTE_MAVEN_PASS', '').strip():
    mv['pass'] = os.environ['REMOTE_MAVEN_PASS'].strip()
    preserved.append('maven.pass')

with open(os.environ['DST'], 'w') as f:
    yaml.safe_dump(d, f, default_flow_style=False, sort_keys=False)

if preserved:
    print('PRESERVED:' + ','.join(preserved))
if empty(mv.get('user')) or empty(mv.get('pass')):
    print('MAVEN_EMPTY_BOTH_SIDES')
PY
)

    # Surface merge outcome.
    while IFS= read -r line; do
        case "$line" in
            PRESERVED:*)
                printf '  %s✓%s preserved from remote: %s\n' \
                    "$GREEN" "$RESET" "${line#PRESERVED:}"
                ;;
            MAVEN_EMPTY_BOTH_SIDES)
                printf '  %s⚠%s maven.user/pass empty in BOTH local snapshot and remote EC2.\n' \
                    "$YELLOW" "$RESET"
                printf '      graphrag pods will ImagePullBackOff until you fill in\n'
                printf '      ~/graphwise-secrets.yaml on the EC2 and re-run reset-helm.sh.\n'
                ;;
        esac
    done <<< "$MERGE_STATUS"

    chmod 600 "$STAGE/graphwise-secrets.yaml"
    printf '  %s✓%s staged graphwise-secrets.yaml\n' "$GREEN" "$RESET"
fi

# Phase 2: license files
if [ "$SKIP_LICENSES" != "yes" ]; then
    if [ ! -d "$LICENSES_DIR" ]; then
        printf '  %s⚠%s licenses dir missing (%s) -- skipping\n' "$YELLOW" "$RESET" "$LICENSES_DIR"
    else
        mkdir -p "$STAGE/licenses"
        for f in poolparty.key graphdb.license uv-license.key; do
            if [ -f "$LICENSES_DIR/$f" ]; then
                cp "$LICENSES_DIR/$f" "$STAGE/licenses/$f"
                chmod 600 "$STAGE/licenses/$f"
                printf '  %s✓%s staged licenses/%s\n' "$GREEN" "$RESET" "$f"
            else
                printf '  %s⚠%s skipped licenses/%s (not found locally)\n' "$YELLOW" "$RESET" "$f"
            fi
        done
    fi
fi

# Phase 3: saved wildcard cert
if [ "$SKIP_CERT" != "yes" ]; then
    cert_local="$LICENSES_DIR/wildcard-tls.yaml"
    if [ ! -f "$cert_local" ]; then
        printf '  %s⚠%s no saved cert at %s -- skipping (cert-manager will issue fresh)\n' "$YELLOW" "$RESET" "$cert_local"
    else
        # Print expiry summary so the operator sees days remaining.
        cert_pem=$(python3 -c "
import yaml, base64
with open('$cert_local') as f:
    d = yaml.safe_load(f)
print(base64.b64decode(d['data']['tls.crt']).decode())
" 2>/dev/null)
        if [ -z "$cert_pem" ]; then
            printf '  %s⚠%s could not decode saved cert -- skipping\n' "$YELLOW" "$RESET"
        else
            not_after=$(echo "$cert_pem" | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//')
            not_after_epoch=$(date -j -f "%b %d %T %Y %Z" "$not_after" +%s 2>/dev/null || date -d "$not_after" +%s 2>/dev/null || echo 0)
            now_epoch=$(date +%s)
            days_remaining=$(( (not_after_epoch - now_epoch) / 86400 ))
            cp "$cert_local" "$STAGE/wildcard-tls.yaml"
            chmod 600 "$STAGE/wildcard-tls.yaml"
            printf '  %s✓%s staged wildcard-tls.yaml (%s days remaining)\n' "$GREEN" "$RESET" "$days_remaining"
            if [ "$days_remaining" -lt 30 ]; then
                printf '  %s⚠%s cert expiring within 30 days -- cluster-bootstrap will accept it but cert-manager will renew shortly\n' "$YELLOW" "$RESET"
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------
# Stream the tarball through one SSH; remote bash snippet extracts.
# ---------------------------------------------------------------------
staged=$(find "$STAGE" -type f | wc -l | tr -d ' ')
if [ "$staged" = "0" ]; then
    echo "${YELLOW}Nothing to push (everything skipped or missing).${RESET}"
    exit 0
fi

echo
echo "${BOLD}Pushing tarball ($staged file(s)) to $USR@$HOST in one ssh...${RESET}"

# Remote snippet: untar payload, move files to canonical paths,
# chmod tightly, emit per-file 'PLACED:<path>' lines on stderr so
# we can replay them locally.
REMOTE_EXTRACT='
set -euo pipefail
RDIR=$(mktemp -d /tmp/graphwise-push.XXXXXX)
trap "rm -rf \"$RDIR\"" EXIT
tar -xzf - -C "$RDIR"
mkdir -p "$HOME/graphwise-stack-aws/files/licenses"
chmod 700 "$HOME/graphwise-stack-aws/files/licenses"
if [ -f "$RDIR/graphwise-secrets.yaml" ]; then
    install -m 0600 "$RDIR/graphwise-secrets.yaml" "$HOME/graphwise-secrets.yaml"
    echo "PLACED:~/graphwise-secrets.yaml" >&2
fi
if [ -d "$RDIR/licenses" ]; then
    for f in "$RDIR"/licenses/*; do
        [ -f "$f" ] || continue
        name=$(basename "$f")
        install -m 0600 "$f" "$HOME/graphwise-stack-aws/files/licenses/$name"
        echo "PLACED:~/graphwise-stack-aws/files/licenses/$name" >&2
    done
fi
if [ -f "$RDIR/wildcard-tls.yaml" ]; then
    install -m 0600 "$RDIR/wildcard-tls.yaml" "$HOME/wildcard-tls-saved.yaml"
    echo "PLACED:~/wildcard-tls-saved.yaml" >&2
fi
'

INVENTORY=$(mktemp -t graphwise-push-inv.XXXXXX)
trap 'rm -rf "$STAGE" "$INVENTORY"' EXIT

# Pass REMOTE_EXTRACT as the SSH command-line argument (NOT via
# stdin / `bash -s`). Stdin is reserved for the tarball bytes flowing
# from `tar -czf - | ssh ...`; the embedded `tar -xzf -` inside
# REMOTE_EXTRACT reads them. Earlier code piped tar into `bash -s`
# which reads its script from stdin -- so bash tried to interpret
# tarball bytes as commands and we got a flood of `command not found`
# garbage. ssh client quotes the single argument cleanly to the
# remote $SHELL -c.
if ! tar -czf - -C "$STAGE" . | \
     ssh -i "$KEY" -o StrictHostKeyChecking=accept-new "$USR@$HOST" \
         "$REMOTE_EXTRACT" 2> "$INVENTORY"; then
    echo "${RED}ERROR: remote extract failed. Inventory so far:${RESET}" >&2
    cat "$INVENTORY" >&2
    exit 1
fi

# Replay placement inventory.
echo
while IFS= read -r line; do
    case "$line" in
        PLACED:*) printf '  %s✓%s placed %s\n' "$GREEN" "$RESET" "${line#PLACED:}" ;;
        *)        printf '  %s\n' "$line" ;;
    esac
done < "$INVENTORY"

echo
echo "${BOLD}Then on EC2 (in this order):${RESET}"
echo "  ./scripts/cluster-bootstrap.sh        # auto-restores wildcard cert if pushed"
echo "  ./scripts/extract-poolparty-realm.sh  # extracts realm JSON + jq-substitutes \${...} placeholders"
echo "  ./scripts/install-licenses.sh         # turns license files into K8s Secrets"
echo "  ./scripts/reset-helm.sh stroker       # picks up secrets via -f overlay"
