#!/usr/bin/env bash
# pull-config.sh -- one ssh, one tar pipeline. Pulls every operator-
# supplied artifact + the live LE wildcard cert off the EC2 as a single
# tarball; extracts into a fresh dated folder under ~/Downloads/.
#
# Output layout (after a successful pull):
#   ~/Downloads/graphwise-config-<UTC-timestamp>/
#       payload.tgz                  (the tarball as it arrived; keep
#                                     for re-extract / archival)
#       graphwise-secrets.yaml       (single source of truth for
#                                     operator secrets: maven, Bedrock,
#                                     n8n license, n8n encryption key)
#       chart-values.yaml            (the EC2's actual
#                                     charts/graphwise-stack/values.yaml
#                                     -- captured to detect drift from
#                                     the git baseline)
#       chart-values.diff            (only present if the EC2 file
#                                     differs from the git-tracked
#                                     baseline -- review for any
#                                     operator-supplied overrides
#                                     beyond Bedrock/n8n license,
#                                     which are auto-migrated)
#       dashboard-kubeconfig.yaml    (cluster-bootstrap.sh's auto-
#                                     generated kubeconfig with the
#                                     dashboard-admin token; saves
#                                     a separate scp post-deploy.
#                                     NOT pushed back -- token is
#                                     tied to THIS cluster's signing
#                                     key)
#       licenses/
#         poolparty.key
#         graphdb.license
#         uv-license.key
#         wildcard-tls.yaml          (live LE wildcard cert as a
#                                     Secret YAML, ready for
#                                     push-config.sh to re-apply on
#                                     the next deploy -- cert-manager
#                                     sees a valid Secret in place and
#                                     skips the LE issuance call)
#
# Auto-migration: Bedrock + n8n license values still living in
# chart-values.yaml (pre-overlay-arch deployments) are spliced into
# the snapshot's graphwise-secrets.yaml automatically. The operator's
# subsequent push-config.sh writes the merged overlay to the new
# EC2's ~/graphwise-secrets.yaml -- no manual migration step.
#
# Why one tarball: each scp is a fresh SSH connection (handshake
# latency, partial-failure mode per file). One tarball + one SSH means
# atomic-or-nothing.
#
# Why a dated Downloads folder (vs overwriting canonical paths in $HOME):
# this is your ARCHIVE of the deployment's state at a given moment.
# Each pull stands alone -- no .bak-<timestamp> files cluttering $HOME,
# no risk of clobbering edits you made since the last pull. To use the
# pulled snapshot for the next deploy, point push-config.sh at the
# folder via --licenses-dir + --secrets-file (the script prints the
# exact command).
#
# Required env (or pass via flags):
#   GRAPHWISE_KEY    path to .pem
#   GRAPHWISE_HOST   subdomain or EIP
#   GRAPHWISE_USER   ec2-user (default)
#
# Usage:
#   ./scripts/laptop/pull-config.sh
#   ./scripts/laptop/pull-config.sh --download-dir ~/path/to/somewhere   (default: ~/Downloads)
#   ./scripts/laptop/pull-config.sh --skip-secrets
#   ./scripts/laptop/pull-config.sh --skip-licenses
#   ./scripts/laptop/pull-config.sh --skip-cert
#   ./scripts/laptop/pull-config.sh --skip-chart-values
#   ./scripts/laptop/pull-config.sh --skip-dashboard
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

DOWNLOAD_DIR="$HOME/Downloads"
SKIP_SECRETS=no
SKIP_LICENSES=no
SKIP_CERT=no
SKIP_CHART_VALUES=no
SKIP_DASHBOARD=no
while [ $# -gt 0 ]; do
    case "$1" in
        --download-dir)        DOWNLOAD_DIR="$2"; shift 2 ;;
        --skip-secrets)        SKIP_SECRETS=yes; shift ;;
        --skip-licenses)       SKIP_LICENSES=yes; shift ;;
        --skip-cert)           SKIP_CERT=yes; shift ;;
        --skip-chart-values)   SKIP_CHART_VALUES=yes; shift ;;
        --skip-dashboard)      SKIP_DASHBOARD=yes; shift ;;
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

# PyYAML is required for the auto-migration + cert summary. Fail fast
# with a clear fix rather than letting a python traceback surface mid-run.
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
# Create the dated snapshot folder.
# ---------------------------------------------------------------------
TIMESTAMP=$(date -u +%Y%m%d-%H%M%SZ)
SNAPSHOT_DIR="$DOWNLOAD_DIR/graphwise-config-$TIMESTAMP"
mkdir -p "$SNAPSHOT_DIR"
chmod 700 "$SNAPSHOT_DIR"
echo "${BOLD}Snapshot folder:${RESET} $SNAPSHOT_DIR"
echo

# ---------------------------------------------------------------------
# Build the remote snippet: stage selected files into a temp dir + emit
# tar.gz on stdout. PRESENT/MISSING inventory on stderr.
# ---------------------------------------------------------------------
WANT_SECRETS=$([ "$SKIP_SECRETS" = "yes" ] && echo 0 || echo 1)
WANT_LICENSES=$([ "$SKIP_LICENSES" = "yes" ] && echo 0 || echo 1)
WANT_CERT=$([ "$SKIP_CERT" = "yes" ] && echo 0 || echo 1)
WANT_CHART_VALUES=$([ "$SKIP_CHART_VALUES" = "yes" ] && echo 0 || echo 1)
WANT_DASHBOARD=$([ "$SKIP_DASHBOARD" = "yes" ] && echo 0 || echo 1)

REMOTE_BUILD=$(cat <<REMOTE
set -euo pipefail
RDIR=\$(mktemp -d /tmp/graphwise-pull.XXXXXX)
trap "rm -rf \"\$RDIR\"" EXIT

# Phase 1: secrets overlay (single source of truth, post-refactor)
if [ "$WANT_SECRETS" = "1" ]; then
    if [ -f "\$HOME/graphwise-secrets.yaml" ]; then
        cp -p "\$HOME/graphwise-secrets.yaml" "\$RDIR/graphwise-secrets.yaml"
        echo "PRESENT:~/graphwise-secrets.yaml" >&2
    else
        echo "MISSING:~/graphwise-secrets.yaml" >&2
    fi
fi

# Phase 2: license files (vendor blobs)
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

# Phase 3: live wildcard cert (kubectl get secret -o yaml)
# Lands inside licenses/ so push-config.sh's existing --licenses-dir
# logic picks it up unchanged.
if [ "$WANT_CERT" = "1" ]; then
    mkdir -p "\$RDIR/licenses"
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
" > "\$RDIR/licenses/wildcard-tls.yaml"
        echo "PRESENT:licenses/wildcard-tls.yaml" >&2
    else
        echo "MISSING:licenses/wildcard-tls.yaml (no Secret in cert-manager ns)" >&2
    fi
fi

# Phase 4: chart values.yaml + diff vs git baseline
# Pre-overlay-arch operators kept Bedrock + n8n license in
# charts/graphwise-stack/values.yaml directly. Capture both the
# operator's actual file AND a diff against the git baseline so:
#   (a) auto-migration on the laptop side can splice Bedrock/n8n
#       license into the snapshot's graphwise-secrets.yaml
#   (b) any OTHER operator drift gets surfaced via chart-values.diff
#       for human review.
if [ "$WANT_CHART_VALUES" = "1" ]; then
    if [ -f "\$HOME/graphwise-stack-aws/charts/graphwise-stack/values.yaml" ]; then
        cp -p "\$HOME/graphwise-stack-aws/charts/graphwise-stack/values.yaml" "\$RDIR/chart-values.yaml"
        echo "PRESENT:chart-values.yaml" >&2
        if (cd "\$HOME/graphwise-stack-aws" && git diff --no-color HEAD -- charts/graphwise-stack/values.yaml > "\$RDIR/chart-values.diff" 2>/dev/null); then
            if [ -s "\$RDIR/chart-values.diff" ]; then
                echo "PRESENT:chart-values.diff (operator drift detected)" >&2
            else
                rm -f "\$RDIR/chart-values.diff"
            fi
        fi
    else
        echo "MISSING:chart-values.yaml" >&2
    fi
fi

# Phase 5: dashboard kubeconfig (cluster-bootstrap.sh writes it)
# Captured for convenience -- the bearer token is tied to THIS
# cluster's signing key, so this file is NOT pushed back on a
# fresh deploy. push-config.sh ignores it. Saves a separate scp
# post-deploy when you want the dashboard token in your snapshot
# folder for upload to the K8s Dashboard UI.
if [ "$WANT_DASHBOARD" = "1" ]; then
    if [ -f "\$HOME/dashboard-kubeconfig.yaml" ]; then
        cp -p "\$HOME/dashboard-kubeconfig.yaml" "\$RDIR/dashboard-kubeconfig.yaml"
        echo "PRESENT:dashboard-kubeconfig.yaml" >&2
    else
        echo "MISSING:dashboard-kubeconfig.yaml (cluster-bootstrap.sh hasn't run yet?)" >&2
    fi
fi

tar -czf - -C "\$RDIR" .
REMOTE
)

# ---------------------------------------------------------------------
# One ssh, one tar pipeline. stdout = bytes, stderr = inventory.
# Tarball lands directly in the snapshot folder (no temp file in $TMPDIR).
# ---------------------------------------------------------------------
echo "${BOLD}Pulling tarball from $USR@$HOST in one ssh...${RESET}"

TARBALL="$SNAPSHOT_DIR/payload.tgz"
INVENTORY=$(mktemp -t graphwise-pull-inv.XXXXXX)
trap 'rm -f "$INVENTORY"' EXIT

if ! ssh -i "$KEY" -o StrictHostKeyChecking=accept-new \
        "$USR@$HOST" "bash -s" \
        > "$TARBALL" \
        2> "$INVENTORY" \
        <<<"$REMOTE_BUILD"; then
    echo "${RED}ERROR: remote tar pipeline failed. Inventory so far:${RESET}" >&2
    cat "$INVENTORY" >&2
    rm -f "$TARBALL"
    rmdir "$SNAPSHOT_DIR" 2>/dev/null || true
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
# Extract into the snapshot folder. Layout the operator sees:
#   $SNAPSHOT_DIR/payload.tgz             (kept for archival / re-extract)
#   $SNAPSHOT_DIR/graphwise-secrets.yaml
#   $SNAPSHOT_DIR/licenses/poolparty.key
#   $SNAPSHOT_DIR/licenses/graphdb.license
#   $SNAPSHOT_DIR/licenses/uv-license.key
#   $SNAPSHOT_DIR/licenses/wildcard-tls.yaml
# (Items with --skip-* or missing on host won't appear.)
# ---------------------------------------------------------------------
echo
echo "${BOLD}Extracting into $SNAPSHOT_DIR ...${RESET}"
tar -xzf "$TARBALL" -C "$SNAPSHOT_DIR"

# Tighten perms on extracted files (tar may preserve world-readable bits
# if the source was loose).
find "$SNAPSHOT_DIR" -type f -exec chmod 600 {} +
find "$SNAPSHOT_DIR" -type d -exec chmod 700 {} +

# List what landed.
( cd "$SNAPSHOT_DIR" && find . -type f -not -name payload.tgz | sed 's|^\./|  ✓ |' )

# ---------------------------------------------------------------------
# Auto-migrate Bedrock + n8n license from chart-values.yaml into the
# snapshot's graphwise-secrets.yaml, IF the chart values has them
# filled and the overlay has empty placeholders. Bridges the
# pre-overlay-arch -> post-overlay-arch migration without manual
# operator work. Any OTHER chart-values drift is surfaced via
# chart-values.diff for human review.
# ---------------------------------------------------------------------
chart_values="$SNAPSHOT_DIR/chart-values.yaml"
overlay_file="$SNAPSHOT_DIR/graphwise-secrets.yaml"
if [ -f "$chart_values" ] && [ -f "$overlay_file" ]; then
    echo
    echo "${BOLD}Auto-migration check (chart-values.yaml -> graphwise-secrets.yaml):${RESET}"
    migrated=$(CHART_VALUES="$chart_values" OVERLAY_FILE="$overlay_file" python3 <<'PY'
import os, sys, yaml
chart = yaml.safe_load(open(os.environ['CHART_VALUES'])) or {}
ovl   = yaml.safe_load(open(os.environ['OVERLAY_FILE'])) or {}
chart_gs = (chart.get('graphrag-secrets') or {})
ovl_gs   = ovl.setdefault('graphrag-secrets', {})

migrated = []

# Bedrock awsCredentials.{region,accessKeyId,secretAccessKey}
chart_aws = (chart_gs.get('awsCredentials') or {})
ovl_aws   = ovl_gs.setdefault('awsCredentials', {})
for k in ('region', 'accessKeyId', 'secretAccessKey'):
    chart_v = (chart_aws.get(k) or '').strip() if isinstance(chart_aws.get(k), str) else chart_aws.get(k)
    ovl_v   = (ovl_aws.get(k) or '').strip()   if isinstance(ovl_aws.get(k), str)   else ovl_aws.get(k)
    if chart_v and not ovl_v:
        ovl_aws[k] = chart_v
        migrated.append(f'graphrag-secrets.awsCredentials.{k}')

# n8nLicense.activationKey
chart_n8n = (chart_gs.get('n8nLicense') or {})
ovl_n8n   = ovl_gs.setdefault('n8nLicense', {})
chart_v = (chart_n8n.get('activationKey') or '').strip()
ovl_v   = (ovl_n8n.get('activationKey') or '').strip()
if chart_v and not ovl_v:
    ovl_n8n['activationKey'] = chart_v
    migrated.append('graphrag-secrets.n8nLicense.activationKey')

if migrated:
    with open(os.environ['OVERLAY_FILE'], 'w') as f:
        yaml.safe_dump(ovl, f, default_flow_style=False, sort_keys=False)

print('\n'.join(migrated))
PY
)
    if [ -n "$migrated" ]; then
        printf '  %s✓%s migrated %d field(s) from chart-values.yaml into graphwise-secrets.yaml:\n' \
               "$GREEN" "$RESET" "$(echo "$migrated" | wc -l | tr -d ' ')"
        echo "$migrated" | sed 's|^|       |'
    else
        printf '  %s✓%s no fields needed migration (overlay already has values, or chart-values empty)\n' "$GREEN" "$RESET"
    fi

    # Surface any OTHER chart-values drift the operator should review.
    if [ -s "$SNAPSHOT_DIR/chart-values.diff" ]; then
        diff_lines=$(grep -cE '^[+-][^+-]' "$SNAPSHOT_DIR/chart-values.diff" 2>/dev/null || echo 0)
        printf '  %s⚠%s chart-values.yaml has additional drift vs git baseline (%d changed line(s))\n' \
               "$YELLOW" "$RESET" "$diff_lines"
        echo "      Review: cat \"$SNAPSHOT_DIR/chart-values.diff\""
        echo "      Bedrock + n8n license were auto-migrated above; any OTHER edits"
        echo "      (custom passwords, log levels, etc.) need manual handling."
    fi
fi

# Cert summary (parse from the snapshot copy).
cert_local="$SNAPSHOT_DIR/licenses/wildcard-tls.yaml"
if [ -f "$cert_local" ]; then
    echo
    echo "${BOLD}Wildcard cert summary:${RESET}"
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
        printf '  %sSANs:%s      %s\n' "$DIM" "$RESET" "$sans"
        printf '  %sNot After:%s %s (%s days remaining)\n' "$DIM" "$RESET" "$not_after" "$days_remaining"
    fi
fi

echo
echo "${BOLD}Total snapshot size:${RESET} $(du -sh "$SNAPSHOT_DIR" | cut -f1)"
echo
echo "${BOLD}Next steps:${RESET}"
echo "  Inspect the snapshot:"
echo "    ls -la \"$SNAPSHOT_DIR\""
echo
echo "  After the next ${BOLD}terraform apply${RESET}, push this snapshot back:"
echo "    ./scripts/laptop/push-config.sh \\"
echo "      --secrets-file \"$SNAPSHOT_DIR/graphwise-secrets.yaml\" \\"
echo "      --licenses-dir \"$SNAPSHOT_DIR/licenses\""
