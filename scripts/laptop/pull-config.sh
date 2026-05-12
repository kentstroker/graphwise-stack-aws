#!/usr/bin/env bash
# pull-config.sh -- one ssh, one tar pipeline. Pulls every operator-
# supplied artifact + the live LE wildcard cert off the EC2 as a single
# tarball; extracts into a fresh dated folder under ~/Downloads/.
#
# Output layout (after a successful pull):
#   ~/Downloads/graphwise-config-<UTC-timestamp>/
#       payload.tgz                       (tarball as it arrived; kept
#                                          for re-extract / archival)
#       graphwise-secrets.yaml            (single source of truth for
#                                          operator secrets -- BUILT ON
#                                          THE EC2 by reading the live
#                                          KIND Secrets that the running
#                                          pods are actually consuming.
#                                          Push-ready: contents go into
#                                          ~/graphwise-secrets.yaml on
#                                          the next EC2.)
#       graphwise-stack-chart-values.yaml (the EC2's actual
#                                          charts/graphwise-stack/
#                                          values.yaml -- drift detector
#                                          only, NOT used by push-config)
#       graphwise-stack-chart-values.diff (only present if the EC2 file
#                                          differs from the git-tracked
#                                          baseline -- review for any
#                                          non-secret operator drift)
#       dashboard-kubeconfig.yaml         (cluster-bootstrap.sh's auto-
#                                          generated kubeconfig with the
#                                          dashboard-admin token. NOT
#                                          pushed back -- token is tied
#                                          to THIS cluster's signing key)
#       licenses/
#         poolparty.key                   (from Secret poolparty-license
#                                          in ns graphwise; disk fallback)
#         graphdb.license                 (from Secret graphdb-license
#                                          in ns graphwise; disk fallback)
#         uv-license.key                  (from Secret unifiedviews-license
#                                          in ns graphwise; disk fallback)
#         wildcard-tls.yaml               (live LE wildcard cert as a
#                                          Secret YAML, ready for
#                                          push-config.sh to re-apply on
#                                          the next deploy -- cert-manager
#                                          sees a valid Secret in place
#                                          and skips the LE issuance
#                                          call, saving a rate-limit slot)
#
# Source of truth: graphwise-secrets.yaml is REBUILT on the EC2 from the
# live KIND Secrets that the running pods are consuming, NOT copied from
# ~/graphwise-secrets.yaml on disk. This means:
#   - Operators who edited Secrets via kubectl edit get those edits.
#   - Operators who never filled in ~/graphwise-secrets.yaml on EC2 but
#     filled chart-values.yaml directly (pre-overlay-arch) still get
#     correct values -- the Secrets reflect whatever reset-helm.sh
#     materialized.
#   - The snapshot is push-ready: push-config.sh writes the file straight
#     to the new EC2's ~/graphwise-secrets.yaml; reset-helm.sh recreates
#     the same Secrets with the same values.
#
# Mappings (overlay path -> KIND Secret):
#   maven.user / maven.pass
#       Secret 'graphwise' (type docker-registry) in ns graphwise.
#       Field .data.\.dockerconfigjson, JSON path auths."maven.ontotext.com".{username,password}.
#   graphrag-secrets.awsCredentials.{region,accessKeyId,secretAccessKey}
#       Secret 'graphrag-components-aws-credentials' in ns graphrag.
#       Data keys AWS_REGION, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY.
#   graphrag-secrets.n8nLicense.activationKey
#       Secret 'graphrag-n8n-license' in ns graphrag.
#       Data key N8N_LICENSE_ACTIVATION_KEY.
#   graphrag-secrets.n8nEncryption.key
#       Secret 'graphrag-n8n-encryption' in ns graphrag.
#       Data key N8N_ENCRYPTION_KEY.
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

# PyYAML is required laptop-side for the cert summary. Fail fast with a
# clear fix rather than letting a python traceback surface mid-run.
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
#
# Phase 1 BUILDS graphwise-secrets.yaml from live KIND Secrets (the
# running pods' source of truth). Phases 2/3 also prefer KIND Secrets
# (license blobs + LE wildcard cert) over on-disk copies. Phase 4 is
# drift-detection only.
# ---------------------------------------------------------------------
WANT_SECRETS=$([ "$SKIP_SECRETS" = "yes" ] && echo 0 || echo 1)
WANT_LICENSES=$([ "$SKIP_LICENSES" = "yes" ] && echo 0 || echo 1)
WANT_CERT=$([ "$SKIP_CERT" = "yes" ] && echo 0 || echo 1)
WANT_CHART_VALUES=$([ "$SKIP_CHART_VALUES" = "yes" ] && echo 0 || echo 1)
WANT_DASHBOARD=$([ "$SKIP_DASHBOARD" = "yes" ] && echo 0 || echo 1)

REMOTE_BUILD=$(cat <<REMOTE
set -euo pipefail
RDIR=\$(mktemp -d /tmp/graphwise-pull.XXXXXX)
export RDIR
trap "rm -rf \"\$RDIR\"" EXIT

# Phase 1: BUILD graphwise-secrets.yaml from live KIND Secrets.
# Source of truth = what the running pods are mounting RIGHT NOW.
# Anything we can't read stays as empty "" in the YAML so the file
# remains structurally complete (push-ready).
if [ "$WANT_SECRETS" = "1" ]; then
    python3 <<'PY' > "\$RDIR/graphwise-secrets.yaml"
import base64
import json
import subprocess
import sys

import yaml


def get_secret_data(ns, name):
    """Return {key: decoded_str}, or None if Secret missing."""
    try:
        out = subprocess.run(
            ['kubectl', '-n', ns, 'get', 'secret', name, '-o', 'json'],
            capture_output=True, check=True, text=True,
        ).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    raw = json.loads(out).get('data', {}) or {}
    decoded = {}
    for k, v in raw.items():
        try:
            decoded[k] = base64.b64decode(v).decode()
        except Exception:
            decoded[k] = ''
    return decoded


def report(label, ok, secret_path):
    tag = 'PRESENT' if ok else 'MISSING'
    print(f'{tag}:{label} ({secret_path})', file=sys.stderr)


# 1a) Maven creds live in the docker-registry image-pull Secret.
graphwise_secret = get_secret_data('graphwise', 'graphwise')
maven_user = ''
maven_pass = ''
if graphwise_secret and '.dockerconfigjson' in graphwise_secret:
    try:
        dcj = json.loads(graphwise_secret['.dockerconfigjson'])
        auth = (dcj.get('auths') or {}).get('maven.ontotext.com') or {}
        maven_user = auth.get('username', '') or ''
        maven_pass = auth.get('password', '') or ''
    except json.JSONDecodeError:
        pass
report(
    'maven creds (user+pass)',
    bool(maven_user and maven_pass),
    'Secret graphwise/.dockerconfigjson in ns graphwise',
)

# 1b) Bedrock awsCredentials (graphrag-components reads this Secret).
aws = get_secret_data('graphrag', 'graphrag-components-aws-credentials') or {}
report(
    'Bedrock awsCredentials',
    bool(aws.get('AWS_ACCESS_KEY_ID') and aws.get('AWS_SECRET_ACCESS_KEY')),
    'Secret graphrag-components-aws-credentials in ns graphrag',
)

# 1c) n8n license activation key (graphrag-workflows reads this Secret).
n8n_lic = get_secret_data('graphrag', 'graphrag-n8n-license') or {}
report(
    'n8n license activationKey',
    bool(n8n_lic.get('N8N_LICENSE_ACTIVATION_KEY')),
    'Secret graphrag-n8n-license in ns graphrag',
)

# 1d) n8n encryption key (graphrag-workflows mounts this Secret).
n8n_enc = get_secret_data('graphrag', 'graphrag-n8n-encryption') or {}
report(
    'n8n encryption key',
    bool(n8n_enc.get('N8N_ENCRYPTION_KEY')),
    'Secret graphrag-n8n-encryption in ns graphrag',
)

# Assemble the canonical overlay YAML structure. Missing fields are
# emitted as empty "" so the file is push-ready even when partial.
doc = {
    'maven': {
        'user': maven_user,
        'pass': maven_pass,
    },
    'graphrag-secrets': {
        'awsCredentials': {
            'region': aws.get('AWS_REGION', '') or '',
            'accessKeyId': aws.get('AWS_ACCESS_KEY_ID', '') or '',
            'secretAccessKey': aws.get('AWS_SECRET_ACCESS_KEY', '') or '',
        },
        'n8nLicense': {
            'activationKey': n8n_lic.get('N8N_LICENSE_ACTIVATION_KEY', '') or '',
        },
        'n8nEncryption': {
            'key': n8n_enc.get('N8N_ENCRYPTION_KEY', '') or '',
        },
    },
}

print('# All operator-supplied secrets for one graphwise-stack deployment.')
print('# EC2-local; never committed. Built by pull-config.sh from the live')
print('# KIND Secrets that the running pods are consuming.')
print('#')
print('# Push round-trip: scripts/laptop/push-config.sh writes this file to')
print('# the new EC2 host; scripts/reset-helm.sh reads it and materializes')
print('# the same Secrets back into KIND with the same values.')
print()
sys.stdout.write(yaml.safe_dump(doc, default_flow_style=False, sort_keys=False))
PY
    echo "PRESENT:graphwise-secrets.yaml (rebuilt from KIND Secrets)" >&2
fi

# Phase 2: license blobs from KIND Secrets, with on-disk fallback.
# Prefer the Secret -- it's what the running pods mount, so it's
# guaranteed to match what was actually used. Fall back to disk only
# when the Secret is missing (e.g., install-licenses.sh ran but
# reset-helm.sh didn't, or the Secret was deleted).
if [ "$WANT_LICENSES" = "1" ]; then
    mkdir -p "\$RDIR/licenses"
    python3 <<'PY'
import base64
import json
import os
import subprocess
import sys


LICENSES = [
    # (Secret name in ns graphwise, data-key, output filename, disk fallback)
    ('poolparty-license',    'poolparty.key',    'poolparty.key'),
    ('graphdb-license',      'graphdb.license',  'graphdb.license'),
    ('unifiedviews-license', 'uv-license.key',   'uv-license.key'),
]

RDIR = os.environ['RDIR']
HOME = os.environ['HOME']
disk_dir = os.path.join(HOME, 'graphwise-stack-aws', 'files', 'licenses')


def get_secret_data(ns, name):
    try:
        out = subprocess.run(
            ['kubectl', '-n', ns, 'get', 'secret', name, '-o', 'json'],
            capture_output=True, check=True, text=True,
        ).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    return json.loads(out).get('data', {}) or {}


for secret_name, data_key, out_file in LICENSES:
    out_path = os.path.join(RDIR, 'licenses', out_file)
    data = get_secret_data('graphwise', secret_name)
    if data and data.get(data_key):
        with open(out_path, 'wb') as f:
            f.write(base64.b64decode(data[data_key]))
        print(
            f'PRESENT:licenses/{out_file} (from Secret {secret_name} in ns graphwise)',
            file=sys.stderr,
        )
        continue
    disk_path = os.path.join(disk_dir, out_file)
    if os.path.isfile(disk_path):
        with open(disk_path, 'rb') as src, open(out_path, 'wb') as dst:
            dst.write(src.read())
        print(
            f'PRESENT:licenses/{out_file} (disk fallback -- Secret {secret_name} missing)',
            file=sys.stderr,
        )
        continue
    print(
        f'MISSING:licenses/{out_file} (Secret {secret_name} and {disk_path} both empty)',
        file=sys.stderr,
    )
PY
fi

# Phase 3: live wildcard cert (kubectl get secret -o yaml).
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
        echo "PRESENT:licenses/wildcard-tls.yaml (from Secret wildcard-tls in ns cert-manager)" >&2
    else
        echo "MISSING:licenses/wildcard-tls.yaml (no Secret in cert-manager ns)" >&2
    fi
fi

# Phase 4: chart values.yaml + diff vs git baseline (drift detector).
# NOT a credentials source -- those come from Phase 1 KIND Secrets.
# Captured purely so operators can spot non-secret edits to the chart
# on EC2 (custom passwords, log levels, etc.) that need manual review.
if [ "$WANT_CHART_VALUES" = "1" ]; then
    if [ -f "\$HOME/graphwise-stack-aws/charts/graphwise-stack/values.yaml" ]; then
        cp -p "\$HOME/graphwise-stack-aws/charts/graphwise-stack/values.yaml" "\$RDIR/graphwise-stack-chart-values.yaml"
        echo "PRESENT:graphwise-stack-chart-values.yaml (drift detector)" >&2
        if (cd "\$HOME/graphwise-stack-aws" && git diff --no-color HEAD -- charts/graphwise-stack/values.yaml > "\$RDIR/graphwise-stack-chart-values.diff" 2>/dev/null); then
            if [ -s "\$RDIR/graphwise-stack-chart-values.diff" ]; then
                echo "PRESENT:graphwise-stack-chart-values.diff (operator drift detected)" >&2
            else
                rm -f "\$RDIR/graphwise-stack-chart-values.diff"
            fi
        fi
    else
        echo "MISSING:graphwise-stack-chart-values.yaml" >&2
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
#   $SNAPSHOT_DIR/payload.tgz                      (kept for archival)
#   $SNAPSHOT_DIR/graphwise-secrets.yaml
#   $SNAPSHOT_DIR/graphwise-stack-chart-values.yaml
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
# Push-ready summary: per-field check of the snapshot's
# graphwise-secrets.yaml so the operator sees at-a-glance whether every
# slot is filled. Empty slots are not a fatal error -- some deployments
# are umbrella-only and never set the graphrag-secrets fields -- but
# they're worth surfacing before the operator tries to push.
# ---------------------------------------------------------------------
overlay_file="$SNAPSHOT_DIR/graphwise-secrets.yaml"
if [ -f "$overlay_file" ]; then
    echo
    echo "${BOLD}Overlay completeness:${RESET}"
    OVERLAY_FILE="$overlay_file" python3 <<'PY'
import os, sys, yaml

with open(os.environ['OVERLAY_FILE']) as f:
    d = yaml.safe_load(f) or {}

def empty(v):
    return not (isinstance(v, str) and v.strip())

mv = d.get('maven') or {}
gs = d.get('graphrag-secrets') or {}
aws = (gs.get('awsCredentials') or {})
n8n_lic = (gs.get('n8nLicense') or {})
n8n_enc = (gs.get('n8nEncryption') or {})

checks = [
    ('maven.user',                                   mv.get('user')),
    ('maven.pass',                                   mv.get('pass')),
    ('graphrag-secrets.awsCredentials.region',       aws.get('region')),
    ('graphrag-secrets.awsCredentials.accessKeyId',  aws.get('accessKeyId')),
    ('graphrag-secrets.awsCredentials.secretAccessKey', aws.get('secretAccessKey')),
    ('graphrag-secrets.n8nLicense.activationKey',    n8n_lic.get('activationKey')),
    ('graphrag-secrets.n8nEncryption.key',           n8n_enc.get('key')),
]

GREEN = '\033[32m' if sys.stdout.isatty() else ''
YELLOW = '\033[33m' if sys.stdout.isatty() else ''
RESET = '\033[0m' if sys.stdout.isatty() else ''

empty_count = 0
for label, value in checks:
    if empty(value):
        print(f'  {YELLOW}⚠{RESET} empty:   {label}')
        empty_count += 1
    else:
        if 'pass' in label.lower() or 'secret' in label.lower() or 'key' in label.lower():
            preview = (value[:4] + '...') if len(value) > 4 else '***'
        else:
            preview = value
        print(f'  {GREEN}✓{RESET} filled:  {label} = {preview}')

if empty_count:
    print()
    print(f'  {YELLOW}{empty_count} field(s) empty.{RESET} OK for umbrella-only deploys (reset-helm.sh --skip-graphrag);')
    print(f'  graphrag deploys will need these filled in before push-config.sh.')
PY
fi

# ---------------------------------------------------------------------
# Surface chart-values drift the operator should review. Bedrock + n8n
# license used to be auto-migrated from here -- no longer (Phase 1
# pulls them from Secrets), so any drift here is purely non-secret
# operator edits.
# ---------------------------------------------------------------------
if [ -s "$SNAPSHOT_DIR/graphwise-stack-chart-values.diff" ]; then
    echo
    diff_lines=$(grep -cE '^[+-][^+-]' "$SNAPSHOT_DIR/graphwise-stack-chart-values.diff" 2>/dev/null || echo 0)
    printf '%s⚠%s graphwise-stack-chart-values.yaml has drift vs git baseline (%d changed line(s))\n' \
           "$YELLOW" "$RESET" "$diff_lines"
    echo "      Review: cat \"$SNAPSHOT_DIR/graphwise-stack-chart-values.diff\""
    echo "      These are non-secret edits (custom passwords, log levels, etc.)"
    echo "      The chart is sourced from git on the next deploy; if you want"
    echo "      to preserve any of this drift, apply it as a separate -f overlay"
    echo "      or commit it to the chart."
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
