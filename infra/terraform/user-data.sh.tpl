#!/bin/bash
# Graphwise Stack -- EC2 first-boot bootstrap (cloud-init user-data).
#
# Runs ONCE as root, the first time the instance boots, before anyone
# can SSH in. Outcome: an Amazon Linux 2023 ARM64 host with Docker, a
# KIND single-node Kubernetes cluster running under ec2-user, and the
# repo cloned at /home/ec2-user/graphwise-stack-aws.
#
# What this script does NOT do:
#   - install operators (ingress-nginx, cert-manager, CNPG, Keycloak,
#     metrics-server) -- that is scripts/cluster-bootstrap.sh, which
#     the teammate runs manually after SSHing in. Splitting it out
#     makes failures cheap to retry.
#   - issue Let's Encrypt certs -- those happen in cluster-bootstrap.sh
#     once Ingress objects exist and DNS resolves.
#   - install license files -- vendor blobs the teammate scp's in.
#
# Migrated from Debian 13 + rootless podman in late 2026. Debian 13
# had a consistent "ssh fails immediately after scp" failure mode on
# AWS Nitro that nobody could explain; AL2023 doesn't trigger it. We
# also moved from rootless podman to root Docker because (a) KIND's
# primary provider is Docker (podman is still
# KIND_EXPERIMENTAL_PROVIDER even in v0.30) and (b) on AL2023 the
# Docker daemon's SELinux integration is mature, while rootless
# podman would have required disabling SELinux.
#
# This file is a template -- Terraform substitutes $${github_repo_url},
# $${hostname_fqdn}, and $${n8n_encryption_key} at apply time. Any
# other shell-style dollar-brace expression you want to pass through
# to the rendered shell script must be escaped with a double dollar
# sign so Terraform leaves it alone.

set -euo pipefail
# Log everything to /var/log/bootstrap.log AND to syslog under the
# "bootstrap" tag so you can follow progress with either
#   sudo tail -f /var/log/bootstrap.log
#   sudo journalctl -t bootstrap -f
exec > >(tee /var/log/bootstrap.log | logger -t bootstrap) 2>&1

echo "=== Bootstrap starting at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

TARGET_USER="ec2-user"
REPO_URL="${github_repo_url}"
HOSTNAME_FQDN="${hostname_fqdn}"

# Pinned tool versions. Bump deliberately and re-test the whole flow.
KIND_VERSION="v0.30.0"
KUBECTL_VERSION="v1.33.4"
HELM_VERSION="v3.17.0"

# ---------------------------------------------------------------------------
# OS patches + packages
# ---------------------------------------------------------------------------
# AL2023 ships a minimal AMI; we add only what KIND + Docker + the
# helper scripts need.
#   - docker: container runtime, KIND's primary provider.
#   - bind-utils: dig (DNS troubleshooting).
#   - conntrack-tools: kube-proxy needs the conntrack binary.
#   - ethtool / socat / iproute: KIND networking dependencies.
#   - httpd-tools: htpasswd (regenerate basic-auth secrets for
#     GraphDB / RDF4J).
#   - jq: JSON wrangling for cluster-bootstrap and reset-helm scripts.
#   - tar / gzip / curl-minimal / git: helm install + repo clone.
dnf upgrade -y --refresh
dnf install -y \
    docker \
    git \
    jq \
    bind-utils \
    conntrack-tools \
    ethtool \
    socat \
    iproute \
    httpd-tools \
    tar \
    gzip \
    ca-certificates

# ---------------------------------------------------------------------------
# SSH tuning -- raise sshd's queue limits + use internal-sftp.
# Same drop-in we used on Debian; the regex matches AL2023's
# /usr/libexec/openssh/sftp-server path equally well.
# ---------------------------------------------------------------------------
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-graphwise.conf <<'SSHDEOF'
# Managed by graphwise-stack-aws cloud-init. Edits get overwritten on
# instance rebuild; long-term changes belong in user-data.sh.tpl.
Subsystem sftp internal-sftp
LoginGraceTime 30
MaxStartups 100:30:200
SSHDEOF

# Some AL2023 images include a Subsystem line in the main sshd_config;
# sshd takes the first Subsystem definition so comment it out so the
# drop-in actually wins.
sed -i -E 's|^(\s*Subsystem\s+sftp\s+/.*)$|# \1   # disabled by graphwise cloud-init|' \
    /etc/ssh/sshd_config

systemctl restart sshd
echo "sshd: internal-sftp + LoginGraceTime=30s + MaxStartups=100:30:200"

# ---------------------------------------------------------------------------
# Sysctls -- KIND networking
# ---------------------------------------------------------------------------
# - ip_forward=1: container-to-container traffic across Docker bridges.
# - inotify limits: KIND nodes run a lot of file-watching processes
#   (kubelet, kube-apiserver). Default fs.inotify.* values run out
#   well before the cluster is fully populated.
#
# Notes (vs Debian path):
#   - kernel.apparmor_restrict_unprivileged_userns is Debian-specific;
#     AL2023 doesn't ship AppArmor. SELinux stays at default
#     (enforcing); container-selinux from dnf handles Docker labelling.
#   - net.ipv4.ip_unprivileged_port_start=80 is unnecessary because
#     Docker daemon runs as root and binds host ports directly.
cat > /etc/sysctl.d/99-kind.conf <<'SYSCTLEOF'
net.ipv4.ip_forward = 1
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
SYSCTLEOF
sysctl --system

# ---------------------------------------------------------------------------
# Docker -- enable, start, give ec2-user the docker group
# ---------------------------------------------------------------------------
systemctl enable --now docker

# Add ec2-user to the docker group so KIND/kubectl can be run without
# sudo. Member of `docker` group is effectively root on the host -- fine
# for a demo box, document if you want to revisit for production.
usermod -aG docker "$TARGET_USER"

# ---------------------------------------------------------------------------
# Install kind / kubectl / helm (ARM64 binaries, pinned versions)
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Persist KUBECONFIG + convenience aliases for ec2-user shells
# ---------------------------------------------------------------------------
if ! grep -q "KUBECONFIG=" "/home/$TARGET_USER/.bashrc" 2>/dev/null; then
    cat >> "/home/$TARGET_USER/.bashrc" <<'RCEOF'

# kubeconfig from the local KIND cluster
export KUBECONFIG="$HOME/.kube/config"

# Convenience aliases
alias k=kubectl
alias kga='kubectl get all --all-namespaces'
RCEOF
    chown "$TARGET_USER:$TARGET_USER" "/home/$TARGET_USER/.bashrc"
fi

# ---------------------------------------------------------------------------
# Clone the repo and bring up the KIND cluster as ec2-user
# ---------------------------------------------------------------------------
# Using `sudo -u "$TARGET_USER" -i` (login shell) so the docker-group
# membership added above is in effect for `kind create cluster`. Without
# the login shell, the freshly-added group membership isn't visible.
sudo -u "$TARGET_USER" -i bash <<INNER
set -euo pipefail
cd "\$HOME"

# Clone (idempotent -- skip if already present from a previous bootstrap).
if [[ ! -d "graphwise-stack-aws" ]]; then
    git clone "$REPO_URL" graphwise-stack-aws
fi

cd graphwise-stack-aws

# Skip if a cluster named "graphwise" already exists (re-bootstrap path).
if kind get clusters 2>/dev/null | grep -qx graphwise; then
    echo "KIND cluster 'graphwise' already exists, skipping create."
else
    kind create cluster --name graphwise --config infra/kind/kind-config.yaml
fi

# Sanity check.
kubectl cluster-info --context kind-graphwise
kubectl get nodes
INNER

# ---------------------------------------------------------------------------
# Drop a per-deployment Helm overlay holding auto-generated secrets.
# scripts/reset-helm.sh auto-includes this file via `-f` if present, so the
# user doesn't have to remember to fill in the n8n encryption key (the one
# secret the chart needs that genuinely has to be a fresh random string per
# deployment, and that MUST stay constant after first n8n boot).
#
# AWS Bedrock creds, n8n license activation key, etc. still need manual
# editing (in charts/graphwise-stack/values.yaml on this host) -- see
# DEPLOY "Configure GraphRAG runtime credentials". Those are commercial
# secrets Terraform shouldn't generate.
# ---------------------------------------------------------------------------
SECRETS_FILE="/home/$TARGET_USER/graphwise-secrets.yaml"
cat > "$SECRETS_FILE" <<EOF
# Auto-generated overlay for the graphwise-stack umbrella chart.
# Materialized by Terraform's user-data on first boot and consumed by
# scripts/reset-helm.sh via an extra -f flag. Edit only with care --
# changing n8nEncryption.key after first n8n boot makes every stored
# n8n credential unreadable (n8n has no recovery path).
graphrag-secrets:
  n8nEncryption:
    key: "${n8n_encryption_key}"
EOF
chown "$TARGET_USER:$TARGET_USER" "$SECRETS_FILE"
chmod 600 "$SECRETS_FILE"

# Friendly breadcrumb so the first SSH session is immediately oriented.
cat > "/home/$TARGET_USER/NEXT_STEPS.txt" <<EOF
Welcome to your Graphwise stack instance.

Bootstrap finished at $(date -u +%Y-%m-%dT%H:%M:%SZ).
Repo cloned at ~/graphwise-stack-aws.
Single-node KIND cluster 'graphwise' is up. Verify with:

    kubectl get nodes

What's still manual, in order:

    cd ~/graphwise-stack-aws

    # 1. Update GoDaddy DNS for $HOSTNAME_FQDN
    #    Two A records, both pointing at this instance's EIP. The exact
    #    values are in the 'godaddy_dns_records' Terraform output.
    #    Wait 5-30 minutes for propagation:
    #      dig +short $HOSTNAME_FQDN
    #      dig +short poolparty.$HOSTNAME_FQDN

    # 2. Drop your Graphwise registry creds for the image-pull secret:
    #    mkdir -p ~/.ontotext
    #    echo '<maven-username>' > ~/.ontotext/maven-user
    #    echo '<maven-password>' > ~/.ontotext/maven-pass
    #    chmod 600 ~/.ontotext/*

    # 3. Install cluster operators (ingress-nginx, cert-manager,
    #    CNPG, Keycloak operator, metrics-server). LE_EMAIL is used
    #    by cert-manager's ACME account.
    export LE_EMAIL=you@example.com
    ./scripts/cluster-bootstrap.sh

    # 4. Drop your Graphwise license files under files/licenses/:
    #    PoolParty (poolparty.key), GraphDB (graphdb.license),
    #    UnifiedViews (uv-license.key). They become Kubernetes
    #    Secrets in step 6.

    # 5. Edit charts/graphwise-stack/values.yaml -- fill in your
    #    AWS Bedrock access key + n8n license activation key.

    # 6. Install the umbrella + graphrag Helm releases:
    #    ./scripts/reset-helm.sh --yes <your-subdomain>

Endpoints once everything is wired up:
    Chatbot:   https://graphrag.$HOSTNAME_FQDN/
    PoolParty: https://poolparty.$HOSTNAME_FQDN/PoolParty/
    Keycloak:  https://auth.$HOSTNAME_FQDN/
EOF
chown "$TARGET_USER:$TARGET_USER" "/home/$TARGET_USER/NEXT_STEPS.txt"

echo "=== Bootstrap complete at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
