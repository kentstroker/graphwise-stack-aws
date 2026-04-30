#!/bin/bash
# Graphwise Stack -- EC2 first-boot bootstrap (cloud-init user-data).
#
# Runs ONCE as root, the first time the instance boots, before anyone
# can SSH in. Outcome: a Debian 13 ARM64 host with rootless podman, a
# named user, kind/kubectl/helm installed, and a single-node KIND
# Kubernetes cluster running under the named user.
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
# This file is a template -- Terraform substitutes $${named_user},
# $${github_repo_url}, and $${hostname_fqdn} at apply time. Any other
# shell-style dollar-brace expression you want to pass through to the
# rendered shell script must be escaped with a double dollar sign so
# Terraform leaves it alone.

set -euo pipefail
# Log everything to /var/log/bootstrap.log AND to syslog under the
# "bootstrap" tag so you can follow progress with either
#   sudo tail -f /var/log/bootstrap.log
#   sudo journalctl -t bootstrap -f
exec > >(tee /var/log/bootstrap.log | logger -t bootstrap) 2>&1

echo "=== Bootstrap starting at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

TARGET_USER="${named_user}"
REPO_URL="${github_repo_url}"
HOSTNAME_FQDN="${hostname_fqdn}"

# Pinned tool versions. Bump deliberately and re-test the whole flow.
KIND_VERSION="v0.30.0"
KUBECTL_VERSION="v1.33.4"
HELM_VERSION="v3.17.0"

# ---------------------------------------------------------------------------
# Wait for AWS's own cloud-init modules to populate admin's authorized_keys
# ---------------------------------------------------------------------------
for i in {1..30}; do
    if [[ -s /home/admin/.ssh/authorized_keys ]]; then
        break
    fi
    echo "Waiting for /home/admin/.ssh/authorized_keys ($i/30)..."
    sleep 2
done
if [[ ! -s /home/admin/.ssh/authorized_keys ]]; then
    echo "ERROR: admin authorized_keys never appeared; aborting."
    exit 1
fi

# ---------------------------------------------------------------------------
# OS patches + packages
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

# - podman / podman-compose: container runtime + compose shim (used both
#   by KIND as the cluster provider and by anyone wanting to run an
#   ad-hoc container outside the cluster).
# - crun: the OCI runtime podman uses on rootless cgroups v2; explicit
#   install guards against an apt seed that defaults to runc.
# - slirp4netns / fuse-overlayfs: required pieces of the rootless podman
#   stack on Debian.
# - conntrack / ethtool / socat / iproute2: KIND networking dependencies.
# - uidmap: ensures /etc/subuid and /etc/subgid get newuidmap/newgidmap
#   helpers needed for rootless user namespacing.
# - apache2-utils: provides htpasswd, used to (re)generate the
#   APR1-MD5 hashes in the basic-auth secrets gating GraphDB / RDF4J.
apt-get install -y \
    curl \
    git \
    jq \
    ca-certificates \
    dnsutils \
    podman \
    podman-compose \
    crun \
    slirp4netns \
    fuse-overlayfs \
    uidmap \
    conntrack \
    ethtool \
    socat \
    iproute2 \
    apache2-utils

# ---------------------------------------------------------------------------
# SSH tuning: avoid the "ssh fails immediately after scp, recovers in 2 min"
# trap that hits multiple teammates on AWS EC2.
#
# Symptom:
#   scp completes; the next `ssh` to the same host is refused immediately.
#   Exactly 120 seconds later, ssh works again with no other intervention.
#
# Root cause(s):
#   1. sshd's MaxStartups=10:30:100 slot queue + LoginGraceTime=120 default.
#      Burst scp/ssh activity can leave half-completed unauthenticated
#      connections occupying slots; new connects are refused until
#      LoginGraceTime reaps them en masse.
#   2. The external sftp-server binary forking from sshd has additional
#      edge cases that don't hit the in-process internal-sftp path.
#
# Fixes applied here (drop-in /etc/ssh/sshd_config.d/ takes precedence
# over the main file and survives openssh-server upgrades):
#   - Subsystem sftp internal-sftp  (no external fork)
#   - LoginGraceTime 30             (reap orphan slots in 30s, not 2m)
#   - MaxStartups 100:30:200        (raise the unauthenticated cap so
#                                     legitimate burst activity doesn't
#                                     hit the limit at all)
# ---------------------------------------------------------------------------
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-graphwise.conf <<'SSHDEOF'
# Managed by graphwise-stack-aws cloud-init. Edits get overwritten on
# instance rebuild; long-term changes belong in user-data.sh.tpl.
Subsystem sftp internal-sftp
LoginGraceTime 30
MaxStartups 100:30:200
SSHDEOF

# Debian's main sshd_config also has a Subsystem line that wins over
# any drop-in (sshd takes the FIRST Subsystem definition). Comment it
# out so the drop-in actually takes effect.
sed -i -E 's|^(\s*Subsystem\s+sftp\s+/.*)$|# \1   # disabled by graphwise cloud-init|' \
    /etc/ssh/sshd_config

# Debian's service is `ssh`; some other distros use `sshd`.
systemctl restart ssh 2>/dev/null || systemctl restart sshd
echo "sshd: internal-sftp + LoginGraceTime=30s + MaxStartups=100:30:200"

# Debian's podman ships without a default image registry. Without this,
# any unqualified image name fails with "short-name did not resolve to
# an alias". KIND pulls kindest/node from docker.io.
echo 'unqualified-search-registries = ["docker.io"]' \
    > /etc/containers/registries.conf.d/docker.conf

# Force systemd cgroup manager + crun runtime in containers.conf so KIND
# (which runs as a privileged container under rootless podman) gets the
# right cgroup hierarchy. Without this, KIND nodes fail to start with
# "failed to create kubelet" errors.
mkdir -p /etc/containers
cat > /etc/containers/containers.conf <<'CONFEOF'
[engine]
cgroup_manager = "systemd"
runtime = "crun"
CONFEOF

# Enable the system-level podman socket. Not strictly required for
# rootless KIND, but useful for ad-hoc tooling.
systemctl enable --now podman

# ---------------------------------------------------------------------------
# Sysctls -- rootless podman + KIND networking
# ---------------------------------------------------------------------------
# - ip_unprivileged_port_start=80: lets ingress-nginx (running inside
#   the KIND control-plane container, which itself runs as the rootless
#   named user) bind 80/443 via KIND's hostPort port mappings.
# - apparmor_restrict_unprivileged_userns=0: Debian 13 restricts
#   unprivileged user namespaces by default; KIND requires them.
# - ip_forward=1: container-to-container traffic across podman bridges.
# - inotify limits: KIND nodes run a lot of file-watching processes
#   (kubelet, kube-apiserver). Default fs.inotify.* values run out
#   well before the cluster is fully populated.
cat > /etc/sysctl.d/99-kind.conf <<'SYSCTLEOF'
net.ipv4.ip_unprivileged_port_start = 80
kernel.apparmor_restrict_unprivileged_userns = 0
net.ipv4.ip_forward = 1
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
SYSCTLEOF
sysctl --system

# ---------------------------------------------------------------------------
# Named user -- passwordless sudo + SSH key copied from admin
# ---------------------------------------------------------------------------
if ! id "$TARGET_USER" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "$TARGET_USER"
fi
usermod -aG sudo "$TARGET_USER"

SUDOERS_FILE="/etc/sudoers.d/$TARGET_USER"
echo "$TARGET_USER ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
chmod 0440 "$SUDOERS_FILE"
visudo -cf "$SUDOERS_FILE"

mkdir -p "/home/$TARGET_USER/.ssh"
cp /home/admin/.ssh/authorized_keys "/home/$TARGET_USER/.ssh/"
chown -R "$TARGET_USER:$TARGET_USER" "/home/$TARGET_USER/.ssh"
chmod 700 "/home/$TARGET_USER/.ssh"
chmod 600 "/home/$TARGET_USER/.ssh/authorized_keys"

# Confirm /etc/subuid and /etc/subgid have allocations for the user.
# `adduser` does this on Debian 13, but be defensive.
if ! grep -q "^$TARGET_USER:" /etc/subuid; then
    echo "$TARGET_USER:100000:65536" >> /etc/subuid
fi
if ! grep -q "^$TARGET_USER:" /etc/subgid; then
    echo "$TARGET_USER:100000:65536" >> /etc/subgid
fi

# ---------------------------------------------------------------------------
# Rootless podman runtime -- runtime dir + DBus + linger
# ---------------------------------------------------------------------------
USER_ID=$(id -u "$TARGET_USER")
RUNTIME_DIR="/run/user/$USER_ID"
mkdir -p "$RUNTIME_DIR"
chown "$USER_ID:$USER_ID" "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"

# Linger = keep the user's systemd instance alive between logins.
# Without it, the KIND container's user session ends as soon as you SSH
# out, taking the whole cluster down.
loginctl enable-linger "$TARGET_USER"

# Persist the XDG/DBus env vars + KIND_EXPERIMENTAL_PROVIDER so a fresh
# SSH shell can use kind/podman/kubectl without ceremony.
if ! grep -q "XDG_RUNTIME_DIR" "/home/$TARGET_USER/.bashrc" 2>/dev/null; then
    cat >> "/home/$TARGET_USER/.bashrc" <<'RCEOF'

# Rootless Podman runtime
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"

# KIND uses podman as its provider on this host (no Docker installed).
export KIND_EXPERIMENTAL_PROVIDER=podman

# kubeconfig from the local KIND cluster
export KUBECONFIG="$HOME/.kube/config"

# Convenience aliases
alias k=kubectl
alias kga='kubectl get all --all-namespaces'
RCEOF
    chown "$TARGET_USER:$TARGET_USER" "/home/$TARGET_USER/.bashrc"
fi

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
# Clone the repo and bring up the KIND cluster as the named user
# ---------------------------------------------------------------------------
sudo -u "$TARGET_USER" -i bash <<INNER
set -euo pipefail
cd "\$HOME"

# Clone (idempotent -- skip if already present from a previous bootstrap).
if [[ ! -d "graphwise-stack-aws" ]]; then
    git clone "$REPO_URL" graphwise-stack-aws
fi

cd graphwise-stack-aws

# Bring up the single-node KIND cluster. KIND_EXPERIMENTAL_PROVIDER=podman
# is set in .bashrc but a non-login bash heredoc may not source it.
export KIND_EXPERIMENTAL_PROVIDER=podman
export XDG_RUNTIME_DIR="/run/user/\$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=\$XDG_RUNTIME_DIR/bus"

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
# README "Configure GraphRAG runtime credentials". Those are commercial
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
    #    PoolParty, UnifiedViews, GraphDB. They become Kubernetes
    #    Secrets in step 5.

    # 5. (Coming in next phase) Install the umbrella Helm chart:
    #    helm install graphwise-stack ./charts/graphwise-stack ...

Endpoints once everything is wired up:
    Chatbot:   https://graphrag.$HOSTNAME_FQDN/
    PoolParty: https://poolparty.$HOSTNAME_FQDN/PoolParty/
    Keycloak:  https://auth.$HOSTNAME_FQDN/
EOF
chown "$TARGET_USER:$TARGET_USER" "/home/$TARGET_USER/NEXT_STEPS.txt"

echo "=== Bootstrap complete at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
