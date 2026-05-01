#!/usr/bin/env bash
# cluster-stop.sh — politely quiesce the stack before stopping the EC2.
#
# What this script does:
#   1. Scales every Deployment + StatefulSet in the application
#      namespaces (graphwise, graphrag) to 0 replicas, giving Java
#      apps + databases a chance to flush state cleanly.
#   2. Waits for pods to terminate (up to 90s, configurable).
#   3. Prints next-step instructions for stopping the EC2 itself.
#
# What this script does NOT do:
#   - Stop the EC2 instance. That has to come from AWS (Console or
#     `aws ec2 stop-instances`); doing it from inside the instance
#     would just kill the SSH session. We print the command for you.
#   - Touch operator namespaces (cert-manager, ingress-nginx,
#     cnpg-system, keycloak-operator, kube-system, monitoring,
#     kubernetes-dashboard). Those are tiny and tolerate abrupt
#     shutdown fine.
#   - Delete anything. PVCs, Secrets, ConfigMaps -- all preserved.
#
# Run as ec2-user. Idempotent: re-running just re-asserts replicas=0
# (no error if already there). Safe to run when the umbrella isn't
# installed yet (no workloads = no-op).
#
# Usage:
#   ./scripts/cluster-stop.sh
#
# To restart the cluster after `aws ec2 start-instances`:
#   ./scripts/cluster-resume.sh
# Then restore replicas:
#   ./scripts/cluster-start.sh   # (TODO -- doesn't exist yet; for now
#                                #  scale workloads back manually with
#                                #  `helm upgrade` or `kubectl scale`)
#
# Why bother quiescing? Postgres (CNPG), Elasticsearch, GraphDB, and
# Keycloak all use write-ahead logs and recover cleanly from a hard
# stop. The scale-to-zero pass is belt-and-braces; for the demo
# stack you can usually skip straight to `aws ec2 stop-instances`
# and accept the SIGKILL. This script is for when you want to be
# polite, e.g. mid-demo with active sessions.

set -euo pipefail

WAIT_TIMEOUT="${WAIT_TIMEOUT:-90}"
APP_NAMESPACES=(graphwise graphrag)

if ! command -v kubectl >/dev/null 2>&1; then
    echo "ERROR: kubectl not found in PATH." >&2
    exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "ERROR: kube API not reachable. Cluster may already be down." >&2
    echo "       If so, just stop the EC2 from the AWS Console." >&2
    exit 1
fi

echo "=== Quiescing application workloads ==="

scaled_anything=0
for ns in "${APP_NAMESPACES[@]}"; do
    if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
        echo "  namespace '$ns' doesn't exist -- skipping"
        continue
    fi

    deployments=$(kubectl -n "$ns" get deployment --no-headers 2>/dev/null | wc -l | tr -d ' ')
    statefulsets=$(kubectl -n "$ns" get statefulset --no-headers 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$deployments" -eq 0 && "$statefulsets" -eq 0 ]]; then
        echo "  namespace '$ns' has no workloads -- skipping"
        continue
    fi

    echo "  $ns: scaling $deployments deployment(s) + $statefulsets statefulset(s) to 0"
    [[ "$deployments" -gt 0 ]]  && kubectl -n "$ns" scale deployment  --all --replicas=0 >/dev/null
    [[ "$statefulsets" -gt 0 ]] && kubectl -n "$ns" scale statefulset --all --replicas=0 >/dev/null
    scaled_anything=1
done

if [[ "$scaled_anything" -eq 0 ]]; then
    echo
    echo "Nothing to scale (umbrella + graphrag releases not installed yet)."
    echo "Hard EC2 stop is fine in this state -- there's no app data to flush."
else
    echo
    echo "=== Waiting up to ${WAIT_TIMEOUT}s for pods to drain ==="
    deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
    while :; do
        # Count pods that are Running or Terminating in the app namespaces.
        # `Completed` (e.g. realm-import jobs) doesn't count -- those are done.
        running=0
        for ns in "${APP_NAMESPACES[@]}"; do
            if kubectl get namespace "$ns" >/dev/null 2>&1; then
                count=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null \
                    | awk '$3 == "Running" || $3 == "Terminating" {print}' | wc -l | tr -d ' ')
                running=$(( running + count ))
            fi
        done
        if [[ "$running" -eq 0 ]]; then
            echo "  all app pods drained"
            break
        fi
        if (( $(date +%s) >= deadline )); then
            echo "  WARN: ${running} pod(s) still active after ${WAIT_TIMEOUT}s -- proceeding anyway"
            break
        fi
        echo "  ${running} pod(s) still active..."
        sleep 5
    done
fi

echo
echo "=== Stack quiesced ==="
echo
INSTANCE_ID=$(curl -fsS -m 2 -H "X-aws-ec2-metadata-token: $(curl -fsS -m 2 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token 2>/dev/null)" http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "<your-instance-id>")
REGION=$(curl -fsS -m 2 -H "X-aws-ec2-metadata-token: $(curl -fsS -m 2 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token 2>/dev/null)" http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "<your-region>")

cat <<EOF
Now stop the EC2 instance. Two ways:

  AWS Console:
    EC2 -> Instances -> select '$INSTANCE_ID' -> Instance state -> Stop

  AWS CLI (from your laptop):
    aws ec2 stop-instances --instance-ids $INSTANCE_ID --region $REGION

What survives the stop:
  - EBS volume (all your data, KIND cluster's container images, ~/.kube/, etc.)
  - Elastic IP (kept allocated, DNS records still point at it)
  - Security group, key pair, all Terraform-managed resources

What's billed while stopped:
  - Compute: \$0/hr (the win -- ~\$0.34/hr for r6g.2xlarge -> \$0)
  - EBS storage: ~\$25/mo for 300 GB gp3
  - EIP retention: ~\$3.60/mo (allocated but not attached to running instance)

To bring it back:
  1. aws ec2 start-instances --instance-ids $INSTANCE_ID --region $REGION
     (or AWS Console -> Instance state -> Start)
  2. Wait ~60s for the instance to boot, then ssh ec2-user@<eip>
  3. ./scripts/cluster-resume.sh   # restarts KIND node containers
  4. (Optional) scale workloads back up if you scaled them down here:
        helm upgrade graphwise-stack ./charts/graphwise-stack -n graphwise \\
            -f charts/graphwise-stack/values.yaml -f /tmp/values-<sub>.yaml \\
            --timeout 15m
        helm upgrade graphrag ./charts/vendor/graphrag -n graphrag \\
            -f charts/vendor/graphrag/values-graphwise.yaml \\
            -f /tmp/values-<sub>-graphrag.yaml --timeout 15m
     (Helm restores the chart's declared replica counts.)
EOF
