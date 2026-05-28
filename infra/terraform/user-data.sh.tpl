#!/bin/bash
# Graphwise Stack -- EC2 first-boot bootstrap (cloud-init user-data).
# Runs ONCE as root on first boot. Outcome: AL2023 ARM64 host with
# Docker + KIND + kubectl + helm, single-node cluster up, repo cloned,
# ~/graphwise-secrets.yaml seeded with placeholders, /etc/profile.d/
# graphwise.sh exporting GRAPHWISE_APEX/ROUTE53_ZONE_ID/AWS_REGION.
# Operators run scripts/cluster-bootstrap.sh next.
#
# Template substitutions: $${github_repo_url}, $${github_branch},
# $${hostname_fqdn}, $${n8n_encryption_key}, $${route53_zone_id},
# $${aws_region}. Other shell expansions need $$ to survive Terraform.
#
# AWS user-data has a 16KB limit (after base64-encode). Keep this
# file lean -- detailed rationale belongs in CLAUDE.md, not here.

set -euo pipefail
exec > >(tee /var/log/bootstrap.log | logger -t bootstrap) 2>&1

echo "=== Bootstrap starting at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

TARGET_USER="ec2-user"
REPO_URL="${github_repo_url}"
HOSTNAME_FQDN="${hostname_fqdn}"

# Pinned tool versions. Bump deliberately; re-test the whole flow.
KIND_VERSION="v0.30.0"
KUBECTL_VERSION="v1.33.4"
HELM_VERSION="v3.17.0"

# OS patches + packages (Docker, KIND networking deps, helper tools).
dnf upgrade -y --refresh
dnf install -y docker git jq bind-utils conntrack-tools ethtool socat \
    iproute httpd-tools tar gzip ca-certificates rsync

# sshd: bump queue limits + force internal-sftp.
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-graphwise.conf <<'SSHDEOF'
Subsystem sftp internal-sftp
LoginGraceTime 30
MaxStartups 100:30:200
SSHDEOF
sed -i -E 's|^(\s*Subsystem\s+sftp\s+/.*)$|# \1|' /etc/ssh/sshd_config
systemctl restart sshd

# Sysctls for KIND (ip_forward + raised inotify limits).
cat > /etc/sysctl.d/99-kind.conf <<'SYSCTLEOF'
net.ipv4.ip_forward = 1
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
SYSCTLEOF
sysctl --system

# Docker daemon + ec2-user in docker group (KIND/kubectl no-sudo).
systemctl enable --now docker
usermod -aG docker "$TARGET_USER"

# kind / kubectl / helm (ARM64, pinned versions).
ARCH="arm64"
curl -fsSL -o /usr/local/bin/kind \
    "https://kind.sigs.k8s.io/dl/$KIND_VERSION/kind-linux-$ARCH"
chmod +x /usr/local/bin/kind
curl -fsSL -o /usr/local/bin/kubectl \
    "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$ARCH/kubectl"
chmod +x /usr/local/bin/kubectl
curl -fsSL "https://get.helm.sh/helm-$HELM_VERSION-linux-$ARCH.tar.gz" \
    | tar -xz -C /tmp
mv "/tmp/linux-$ARCH/helm" /usr/local/bin/helm
chmod +x /usr/local/bin/helm
rm -rf "/tmp/linux-$ARCH"

# System-wide env vars (apex hostname + Route 53 zone + region +
# LE ACME contact email). All consumed by cluster-bootstrap.sh
# (cert-manager ClusterIssuer needs LE_EMAIL; the DNS-01 solver
# needs ROUTE53_ZONE_ID + AWS_REGION). cluster-bootstrap.sh
# auto-sources this file at the top so operators never have to
# remember the `source /etc/profile.d/graphwise.sh` dance.
cat > /etc/profile.d/graphwise.sh <<EOF
export GRAPHWISE_APEX="${hostname_fqdn}"
export ROUTE53_ZONE_ID="${route53_zone_id}"
export AWS_REGION="${aws_region}"
export LE_EMAIL="${le_email}"
EOF
chmod 644 /etc/profile.d/graphwise.sh

# Login-time hint: cloud-init in progress, or shell missing docker group.
# Sentinel /var/lib/cloud/graphwise-bootstrap-complete is touched at the
# very end of this script. Silent in the steady state.
cat > /etc/profile.d/graphwise-hint.sh <<'PHINT'
[ -t 1 ] || return 0
if [ ! -f /var/lib/cloud/graphwise-bootstrap-complete ]; then
    echo "[graphwise] cloud-init still running -- watch: sudo tail -f /var/log/bootstrap.log"
    echo "[graphwise] Once it finishes, log out + back in (or 'exec newgrp docker')."
elif ! id -nG | grep -qw docker; then
    echo "[graphwise] Shell missing 'docker' group (logged in before cloud-init added it). Run: exec newgrp docker"
fi
PHINT
chmod 644 /etc/profile.d/graphwise-hint.sh

# kubeconfig + aliases for ec2-user shells.
if ! grep -q "KUBECONFIG=" "/home/$TARGET_USER/.bashrc" 2>/dev/null; then
    cat >> "/home/$TARGET_USER/.bashrc" <<'RCEOF'

export KUBECONFIG="$HOME/.kube/config"
alias k=kubectl
alias kga='kubectl get all --all-namespaces'
RCEOF
    chown "$TARGET_USER:$TARGET_USER" "/home/$TARGET_USER/.bashrc"
fi

# Clone the repo + bring up the KIND cluster as ec2-user.
# Login shell so freshly-added docker-group membership is in effect.
sudo -u "$TARGET_USER" -i bash <<INNER
set -euo pipefail
cd "\$HOME"
[[ -d "graphwise-stack-aws" ]] || git clone -b "${github_branch}" "$REPO_URL" graphwise-stack-aws
cd graphwise-stack-aws
if ! kind get clusters 2>/dev/null | grep -qx graphwise; then
    kind create cluster --name graphwise --config infra/kind/kind-config.yaml
fi
kubectl cluster-info --context kind-graphwise
kubectl get nodes
INNER

# Per-deployment secrets overlay -- single source of truth for ALL
# operator-supplied secrets. EC2-local; never tracked in git.
# reset-helm.sh auto-includes via -f and reads top-level maven block.
# Operators fill in maven/awsCredentials/n8nLicense; n8nEncryption.key
# is auto-generated by Terraform random_id (DO NOT EDIT post-boot).
# scripts/laptop/push-config.sh round-trips this across rebuilds.
SECRETS_FILE="/home/$TARGET_USER/graphwise-secrets.yaml"
cat > "$SECRETS_FILE" <<EOF
# All operator-supplied secrets for one graphwise-stack deployment.
# EC2-local; never committed. Push/pull via scripts/laptop/push-config.sh.

maven:
  user: ""                  # FILL IN: Graphwise maven user
  pass: ""                  # FILL IN: Graphwise maven password

graphrag-secrets:
  awsCredentials:           # SETUP step 4b graphrag-bedrock IAM user
    region: "us-west-2"
    accessKeyId: ""         # FILL IN: AKIA...
    secretAccessKey: ""     # FILL IN
  n8nLicense:
    activationKey: ""       # FILL IN: n8n Enterprise key
  n8nEncryption:            # AUTO-GENERATED -- do not edit
    key: "${n8n_encryption_key}"
EOF
chown "$TARGET_USER:$TARGET_USER" "$SECRETS_FILE"
chmod 600 "$SECRETS_FILE"

# Staging-data landing pad for ingest uploads (rsync -> ~/staging-data/).
mkdir -p "/home/$TARGET_USER/staging-data"
chown "$TARGET_USER:$TARGET_USER" "/home/$TARGET_USER/staging-data"
chmod 755 "/home/$TARGET_USER/staging-data"

# Tiny breadcrumb -- full walkthrough is in the cloned repo's DEPLOY.md.
cat > "/home/$TARGET_USER/NEXT_STEPS.txt" <<EOF
Graphwise stack bootstrapped $(date -u +%Y-%m-%dT%H:%M:%SZ).
Apex: $HOSTNAME_FQDN
KIND cluster 'graphwise' is up:  kubectl get nodes

Next: ~/graphwise-stack-aws/DEPLOY.md from step 3
(or scripts/laptop/push-config.sh from your laptop).
EOF
chown "$TARGET_USER:$TARGET_USER" "/home/$TARGET_USER/NEXT_STEPS.txt"

# Sentinel for /etc/profile.d/graphwise-hint.sh (login-time hint silences once present).
touch /var/lib/cloud/graphwise-bootstrap-complete

echo "=== Bootstrap complete at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
