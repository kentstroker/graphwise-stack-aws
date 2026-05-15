#!/usr/bin/env bash
# scripts/laptop/terraform-destroy.sh -- gated `terraform destroy`.
#
# Why this exists: terraform destroy of a Graphwise stack deletes the
# EC2 instance and its root EBS volume, taking with it every PoolParty
# project, GraphDB repository, Keycloak user / realm, n8n workflow,
# Grafana dashboard, ingested document, and chat history. NONE of
# that is backed up automatically. Forgetting a single export costs
# hours (or your demo).
#
# This wrapper is a guard rail, not a vault. Anyone can still run
# `terraform destroy` directly from infra/terraform/ and bypass it.
# The point is to make the recommended path obvious enough that the
# direct path becomes a deliberate choice, not a reflex.
#
# Usage (from repo root or anywhere):
#   ./scripts/laptop/terraform-destroy.sh
#   ./scripts/laptop/terraform-destroy.sh -auto-approve   # passed through
#   ./scripts/laptop/terraform-destroy.sh -target=...     # passed through
#
# Skip the prompt entirely (CI / automation) by setting CONFIRM=DESTROY:
#   CONFIRM=DESTROY ./scripts/laptop/terraform-destroy.sh -auto-approve

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TERRAFORM_DIR="$REPO_ROOT/infra/terraform"

if [ ! -d "$TERRAFORM_DIR" ]; then
    echo "ERROR: terraform dir not found at $TERRAFORM_DIR" >&2
    exit 1
fi

if ! command -v terraform >/dev/null 2>&1; then
    echo "ERROR: terraform not in PATH." >&2
    exit 1
fi

clear

# Block-letter "WARNING" -- ~70 cols, fits in standard terminals.
cat <<'WARN'

   ██╗    ██╗  █████╗  ██████╗  ███╗   ██╗ ██╗ ███╗   ██╗  ██████╗
   ██║    ██║ ██╔══██╗ ██╔══██╗ ████╗  ██║ ██║ ████╗  ██║ ██╔════╝
   ██║ █╗ ██║ ███████║ ██████╔╝ ██╔██╗ ██║ ██║ ██╔██╗ ██║ ██║  ███╗
   ██║███╗██║ ██╔══██║ ██╔══██╗ ██║╚██╗██║ ██║ ██║╚██╗██║ ██║   ██║
   ╚███╔███╔╝ ██║  ██║ ██║  ██║ ██║ ╚████║ ██║ ██║ ╚████║ ╚██████╔╝
    ╚══╝╚══╝  ╚═╝  ╚═╝ ╚═╝  ╚═╝ ╚═╝  ╚═══╝ ╚═╝ ╚═╝  ╚═══╝  ╚═════╝

         ╔═══════════════════════════════════════════════════════╗
         ║                                                       ║
         ║       TERRAFORM DESTROY  =  TOTAL DATA LOSS           ║
         ║                                                       ║
         ║   The EC2 instance and its EBS root volume will be    ║
         ║   destroyed. Everything in the cluster goes with it.  ║
         ║                                                       ║
         ║   Lost permanently (no automatic backups):            ║
         ║                                                       ║
         ║     - PoolParty projects (thesauri, taxonomies,       ║
         ║       custom schemas, history)                        ║
         ║     - GraphDB embedded + projects repositories        ║
         ║     - Keycloak users, realms, configured clients      ║
         ║     - n8n workflows + credentials                     ║
         ║     - Grafana dashboards + alerts                     ║
         ║     - GraphRAG conversation history (DuckDB on PVC)   ║
         ║     - PoolParty Elasticsearch indices                 ║
         ║     - UnifiedViews pipelines                          ║
         ║     - Ingested staging-data documents                 ║
         ║                                                       ║
         ║   Survives destroy:                                   ║
         ║     - Elastic IP  (only if pre-allocated via          ║
         ║       existing_eip_allocation_id -- see CLAUDE.md)    ║
         ║     - Route 53 DNS records                            ║
         ║                                                       ║
         ║   Does NOT survive (despite living in a different     ║
         ║   namespace): the wildcard TLS cert. cert-manager     ║
         ║   itself goes with the cluster, and re-issuance       ║
         ║   counts toward the Let's Encrypt rate limit          ║
         ║   (5 duplicate certs per registered domain per week). ║
         ║                                                       ║
         ║   BEFORE PROCEEDING -- export anything you care       ║
         ║   about. Per-app export instructions:                 ║
         ║                                                       ║
         ║         docs/DATA-EXPORT.md                           ║
         ║                                                       ║
         ╚═══════════════════════════════════════════════════════╝

WARN

if [ "${CONFIRM:-}" = "DESTROY" ]; then
    echo "  CONFIRM=DESTROY in environment -- skipping interactive prompt."
    echo
else
    if [ ! -t 0 ]; then
        echo "ERROR: stdin is not a TTY and CONFIRM=DESTROY is not set." >&2
        echo "       Refusing to destroy non-interactively." >&2
        exit 1
    fi
    read -r -p "  Type 'DESTROY' (exact case) to proceed, anything else cancels: " ANSWER
    echo

    if [ "$ANSWER" != "DESTROY" ]; then
        echo "Cancelled. Nothing was destroyed."
        exit 0
    fi
fi

echo "  Running: terraform destroy $* (in $TERRAFORM_DIR)"
echo
cd "$TERRAFORM_DIR"
exec terraform destroy "$@"
