#!/usr/bin/env bash
# push-to-ec2.sh -- run from your LAPTOP. Uploads Graphwise license
# files (renaming them to what scripts/install-licenses.sh expects)
# and Maven registry credentials to a deployed EC2 instance.
#
# Why this exists: install-licenses.sh hard-requires three exact
# filenames (poolparty.key, graphdb.license, uv-license.key) but
# Graphwise issues files with vendor-specific names. Without
# renaming, install-licenses.sh fails with "missing license" or
# silently skips the file. This script does the rename inline so you
# can scp from wherever the originals live.
#
# Maven creds (`~/.ontotext/maven-user` + `maven-pass`) similarly
# need to land in a specific place on the EC2 host so
# scripts/cluster-bootstrap.sh can read them when creating the
# image-pull Secret.
#
# Usage:
#   ./scripts/laptop/push-to-ec2.sh \
#       --key ~/.ssh/graphwise-stack.pem --host 54.149.12.34 \
#       --poolparty ~/Downloads/pp-eval.key \
#       --graphdb ~/Downloads/graphdb-ee.lic \
#       --unifiedviews ~/Downloads/uv-eval.key \
#       --maven-user ~/.creds/graphwise/maven-user \
#       --maven-pass ~/.creds/graphwise/maven-pass
#
# Each flag is optional -- omit any you don't need. Pass `-h` for
# the full flag list.
#
# Environment variable defaults:
#   GRAPHWISE_KEY    same as --key  (e.g. ~/.ssh/graphwise-stack.pem)
#   GRAPHWISE_HOST   same as --host (e.g. 54.149.12.34 or
#                    stroker.semantic-proof.com)
#   GRAPHWISE_USER   same as --user (default: ec2-user)
# Set these once in your shell rc and you can drop --key/--host
# from every invocation. CLI flags override env vars.

set -euo pipefail

KEY="${GRAPHWISE_KEY:-}"
HOST="${GRAPHWISE_HOST:-}"
USER_NAME="${GRAPHWISE_USER:-ec2-user}"
PP=""
GDB=""
UV=""
MU=""
MP=""

usage() {
    cat <<EOF
Usage: $0 [--key <key.pem>] [--host <ec2-host>] [options]

Required (CLI flag OR environment variable):
  --key <path.pem>           SSH private key
                             env: GRAPHWISE_KEY
  --host <eip-or-fqdn>       EC2 host (Elastic IP or DNS)
                             env: GRAPHWISE_HOST

Optional (skip whichever you don't need):
  --user <name>              SSH user (default: ec2-user)
                             env: GRAPHWISE_USER
  --poolparty <path>         Local PoolParty license file
  --graphdb <path>           Local GraphDB license file
  --unifiedviews <path>      Local UnifiedViews license file
  --maven-user <path>        File containing the Maven username
  --maven-pass <path>        File containing the Maven password

Files land on the EC2 host as:
  --poolparty    -> ~/graphwise-stack-aws/files/licenses/poolparty.key
  --graphdb      -> ~/graphwise-stack-aws/files/licenses/graphdb.license
  --unifiedviews -> ~/graphwise-stack-aws/files/licenses/uv-license.key
  --maven-user   -> ~/.ontotext/maven-user        (mode 600)
  --maven-pass   -> ~/.ontotext/maven-pass        (mode 600)

Tip: export GRAPHWISE_KEY and GRAPHWISE_HOST in your shell rc so you
can run this without --key/--host every time. Example:

  export GRAPHWISE_KEY=~/.ssh/graphwise-stack.pem
  export GRAPHWISE_HOST=stroker.semantic-proof.com
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --key)         KEY="$2"; shift 2 ;;
        --host)        HOST="$2"; shift 2 ;;
        --user)        USER_NAME="$2"; shift 2 ;;
        --poolparty)   PP="$2"; shift 2 ;;
        --graphdb)     GDB="$2"; shift 2 ;;
        --unifiedviews) UV="$2"; shift 2 ;;
        --maven-user)  MU="$2"; shift 2 ;;
        --maven-pass)  MP="$2"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "ERROR: unknown flag '$1'" >&2; usage; exit 1 ;;
    esac
done

if [[ -z "$KEY" || -z "$HOST" ]]; then
    echo "ERROR: --key and --host are required (or set GRAPHWISE_KEY / GRAPHWISE_HOST)." >&2
    usage
    exit 1
fi

if [[ ! -f "$KEY" ]]; then
    echo "ERROR: SSH key not found: $KEY" >&2
    exit 1
fi

ssh_run()  { ssh -i "$KEY" -o StrictHostKeyChecking=accept-new "$USER_NAME@$HOST" "$@"; }
scp_to()   { scp -i "$KEY" -o StrictHostKeyChecking=accept-new "$1" "$USER_NAME@$HOST:$2"; }

push_file() {
    local label="$1" src="$2" dst="$3"
    if [[ -z "$src" ]]; then
        return 0
    fi
    if [[ ! -f "$src" ]]; then
        echo "ERROR: $label source not found: $src" >&2
        return 1
    fi
    printf '  %-15s %s\n' "$label" "$src -> $dst"
    scp_to "$src" "$dst" >/dev/null
}

echo "Ensuring target directories exist on $USER_NAME@$HOST ..."
ssh_run "mkdir -p graphwise-stack-aws/files/licenses ~/.ontotext"

echo "Pushing license files..."
push_file "PoolParty"     "$PP"  "graphwise-stack-aws/files/licenses/poolparty.key"
push_file "GraphDB"       "$GDB" "graphwise-stack-aws/files/licenses/graphdb.license"
push_file "UnifiedViews"  "$UV"  "graphwise-stack-aws/files/licenses/uv-license.key"

echo "Pushing Maven creds..."
push_file "maven-user"    "$MU"  ".ontotext/maven-user"
push_file "maven-pass"    "$MP"  ".ontotext/maven-pass"

echo "Locking down permissions on Maven creds..."
ssh_run "chmod 600 ~/.ontotext/maven-user ~/.ontotext/maven-pass 2>/dev/null || true"

echo
echo "What landed:"
ssh_run "ls -la graphwise-stack-aws/files/licenses/ ~/.ontotext/"
echo
echo "Done."
