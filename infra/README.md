# Graphwise Stack — Terraform module

**Maintainer:** Kent Stroker

This module provisions the AWS infrastructure for a single-node demo
deployment of the Graphwise Stack: one EC2 instance (r6g.2xlarge,
Debian 13 ARM64, 300 GB encrypted gp3), one Security Group (22 admin /
80 world / 443 world), one Elastic IP, and a cloud-init bootstrap
script that installs podman, creates your Linux user, and clones the
public stack repo.

What this module does **not** do:
- DNS — you email Kent with your subdomain + EIP, he adds the A record
  in GoDaddy (the `semantic-proof.com` zone lives there).
- License file placement — the three Graphwise license binaries are
  scp'd in by hand after the instance is up.
- Let's Encrypt cert issuance — that's a one-command step you run after
  DNS is confirmed (see the top-level README).

The module is intentionally small-scope: everything that can be
automated cleanly is; everything with a human-in-the-loop dependency
stays as a documented manual step.

---

## Prerequisites

One-time, per laptop:

1. **An AWS account.** Each presales SE uses their own. This module
   won't touch any other account.
2. **AWS credentials configured locally.** Run `aws configure` with
   an IAM user's Access Key ID + Secret Access Key that has at least
   `ec2:*` and `elasticloadbalancing:*` (the latter is a historical
   transitive — `ec2:*` is the real requirement). If you use SSO,
   `aws configure sso` works.
   ```bash
   aws configure             # or: aws configure sso
   aws sts get-caller-identity    # verify
   ```
3. **Terraform 1.5+ installed.** Installation instructions are in
   [SETUP.md §3 Install required CLIs](../SETUP.md#3-install-required-clis).
4. **An EC2 Key Pair in the target region.** EC2 Console →
   Network & Security → Key Pairs → Create key pair. Download the
   `.pem`, `chmod 400` it, put it with your other credentials. Note
   the key-pair **name** — you'll pass it to Terraform.

Per-deployment:

1. **Pick a subdomain** under `semantic-proof.com`. Lowercase, no dots,
   hyphens OK. Examples: `scott`, `acme-corp`, `chase-bank`.
2. **Know your current public IP** — Terraform uses it to restrict SSH
   ingress. `curl -4 icanhazip.com` from your laptop.

---

## Usage

```bash
cd infra/terraform

# Copy the example tfvars file and fill in the three required values:
#   subdomain, key_pair_name, admin_cidr.
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars        # edit CHANGEME placeholders

# One-time per checkout: download the AWS provider plugin.
terraform init

# Dry-run — shows exactly what will be created without doing it. Read
# the output. You should see 3 resources added: 1 aws_security_group,
# 1 aws_instance, 1 aws_eip.
terraform plan

# Commit the change. Takes 1-2 minutes for AWS to bring the instance
# up; another 2-3 minutes for cloud-init to finish the bootstrap.
terraform apply
```

When `apply` completes you'll see outputs:

```
Outputs:
elastic_ip          = "54.149.12.34"
ssh_named_user      = "ssh -i <path-to-your-keypair.pem> graphwise@54.149.12.34"
expected_final_url  = "https://scott.semantic-proof.com/"
...
```

Save these. You need the `elastic_ip` for the DNS email to Kent, and
the `ssh_named_user` command for the next step.

---

## What happens on the instance during bootstrap

The cloud-init script (`user-data.sh.tpl`) runs as root on first
boot. It logs to `/var/log/bootstrap.log` on the instance and also
tags syslog with `bootstrap`. Steps, in order:

1. Waits for AWS's own cloud-init modules to finish populating
   `/home/admin/.ssh/authorized_keys`.
2. `apt-get update` + `apt-get upgrade -y`.
3. Installs base packages (curl, git, jq, podman, podman-compose,
   slirp4netns, fuse-overlayfs, uidmap, conntrack, ethtool, socat,
   iproute2, apache2-utils for `htpasswd`).
4. Enables the system `podman.service` (for remote-podman clients).
5. Creates the named Linux user (default `graphwise`), adds them to
   `sudo` with a NOPASSWD sudoers drop-in, and copies the admin's
   authorized_keys so you can SSH in as that user.
6. Sets `net.ipv4.ip_unprivileged_port_start=80` so rootless podman
   can bind to 80 and 443.
7. Creates the user's runtime directory, enables `loginctl linger`
   so systemd user timers survive SSH logout, and appends the
   rootless podman env-var exports to the user's `.bashrc`.
8. Clones this repository into the user's home as
   `~/graphwise-stack-aws`.
9. Installs pinned versions of `kind`, `kubectl`, and `helm` to
   `/usr/local/bin/`.
10. Creates the single-node KIND cluster `graphwise` from
    [infra/kind/kind-config.yaml](kind/kind-config.yaml). Host
    ports 80 and 443 are mapped into the control-plane container so
    ingress-nginx can serve traffic on the EIP.
11. Drops a `~/NEXT_STEPS.txt` file with the post-apply runbook.

The cluster is up at this point but has no operators or app
workloads yet — that's the post-apply runbook below.

---

## Post-apply runbook

From `terraform apply` complete to a working HTTPS stack.

### 1. Watch the bootstrap finish

```bash
# Takes 2-3 minutes after apply. Tail the log to know when it's done.
ssh -i <path-to-your-keypair.pem> admin@<elastic_ip> 'sudo tail -f /var/log/bootstrap.log'
```

Look for `=== Bootstrap complete at <timestamp> ===`. Then Ctrl-C.

### 2. Email Kent for the DNS A records

Template:

> Hi Kent,
>
> Please add **two** A records in the `semantic-proof.com` zone:
>
> - **Name:** `<your-subdomain>.semantic-proof.com` → **Points to:** `<elastic_ip>` (TTL 5 min)
> - **Name:** `*.<your-subdomain>.semantic-proof.com` → **Points to:** `<elastic_ip>` (TTL 5 min)
>
> Thanks.

Both records are required — the wildcard (`*.<sub>.<base>`) is what
makes every per-app subdomain (`poolparty`, `auth`, `graphrag`, …)
resolve. Propagation is usually under 5 minutes.

```bash
# From your laptop, after a few minutes:
dig +short <sub>.semantic-proof.com poolparty.<sub>.semantic-proof.com
# Both lines should print your EIP.
```

### 3. SSH in as your named user

```bash
ssh -i <path-to-your-keypair.pem> graphwise@<elastic_ip>
```

(Or whatever `named_user` you set in `terraform.tfvars`.) The
`~/NEXT_STEPS.txt` file mirrors this runbook.

### 4. Finish the stack setup

Cloud-init left the cluster running with no workloads. The remaining
steps run from `~/graphwise-stack-aws`:

```bash
cd ~/graphwise-stack-aws

# 4a. Maven registry creds for the GraphRAG private images.
mkdir -p ~/.ontotext
echo '<maven-username>' > ~/.ontotext/maven-user
echo '<maven-password>' > ~/.ontotext/maven-pass
chmod 600 ~/.ontotext/*

# 4b. Drop license files (scp from your laptop):
#       files/licenses/poolparty.key
#       files/licenses/graphdb.license
#       files/licenses/uv-license.key

# 4c. Cluster operators (one-time): ingress-nginx, cert-manager,
#     CNPG, Keycloak operator, metrics-server.
export LE_EMAIL=you@example.com
./scripts/cluster-bootstrap.sh

# 4d. Pull realm JSON for PoolParty out of the keycloak image.
./scripts/extract-poolparty-realm.sh

# 4e. License Secrets.
./scripts/install-licenses.sh

# 4f. Install both Helm releases (umbrella + graphrag).
./scripts/reset-helm.sh --yes <your-subdomain>
```

Total time from `terraform apply` to a fully-Ready stack: ~25
minutes, most of which is image pulls and Keycloak's first-boot
realm import.

After it settles: `https://<sub>.semantic-proof.com/` (Console
landing page). See [DEPLOY.md](../DEPLOY.md) for the full app URL
list and [CHEATSHEET.md](../CHEATSHEET.md) for credentials.

---

## Teardown

```bash
cd infra/terraform
terraform destroy
```

Destroys in this order (Terraform figures it out from dependencies):

1. EIP (detached from the instance, then released)
2. EC2 instance (including root EBS volume — **all data is gone**)
3. Security Group

**Before destroying a real demo you care about**, snapshot the EBS
volume via the AWS Console if you want to keep the data. Terraform
does not snapshot on destroy.

The Key Pair is **not** destroyed — Terraform only references it.

Ask Kent to remove the DNS A record afterward so stale subdomains
don't linger.

---

## File map

```
infra/terraform/
├── versions.tf               # Terraform + provider version pins
├── variables.tf              # Input variables (all defined + documented)
├── main.tf                   # VPC lookup, AMI lookup, SG, EC2, EIP
├── outputs.tf                # EIP, SSH command, expected URL, etc.
├── user-data.sh.tpl          # Cloud-init bootstrap script (runs as root on first boot)
├── terraform.tfvars.example  # Sample variables — copy to terraform.tfvars
└── README.md                 # This file
```

---

## Troubleshooting

### `InvalidAMIID.NotFound` during plan or apply

The AMI data source didn't match a current Debian 13 ARM64 image. Usually
means your region doesn't have official Debian AMIs (rare), or Debian
renamed their AMI pattern. Check manually:

```bash
aws ec2 describe-images \
    --owners 136693071363 \
    --filters "Name=name,Values=debian-13-arm64-*" \
    --query 'Images[*].[Name,ImageId]' \
    --output table \
    --region <your-region>
```

If the query returns rows, the module should work — try a fresh
`terraform init`. If it's empty, you're likely in a region without
Debian's official images; pick a different region.

### `UnauthorizedOperation` on `RunInstances`

Your IAM user doesn't have `ec2:RunInstances`. Attach the AWS-managed
`AmazonEC2FullAccess` policy, or a narrower custom policy that permits
the `ec2:*` actions the module uses (RunInstances, AssociateAddress,
AuthorizeSecurityGroupIngress, etc.).

### Bootstrap script fails silently

SSH in as `admin`, read `/var/log/bootstrap.log`. The script runs under
`set -e` so first error is final. Common culprits:

- Transient apt mirror failures — rerun the failing `apt-get install`
  and then manually step through the rest of the script from where it
  stopped. (The script is largely idempotent but was not designed for
  partial-failure recovery.)
- Missing `/home/admin/.ssh/authorized_keys` — the 30-second wait in
  the script should cover propagation, but on very slow boots it may
  need longer. Add a sleep at the top and taint+apply.

### `terraform apply` says it wants to rebuild the instance just because I bumped `named_user`

That's expected — changing `named_user` changes user-data, and
`ignore_changes = [user_data_base64]` prevents drift redeploys but
also means existing user-data changes don't propagate. If you really
need a different named user on an existing instance, either SSH in
and make the change manually, or `terraform taint aws_instance.stack`
+ `terraform apply` (which destroys and re-creates the instance, so
all data is lost).

### I want a second instance for a second customer

Two clean ways:

- Separate checkout of the repo with its own `terraform.tfvars` and
  its own `.terraform/` state directory. Simplest.
- Same checkout, two Terraform workspaces (`terraform workspace new customer-b`)
  with separate `*.tfvars` files per workspace. More ceremony; better
  if you're managing many demos in one day.

---

## What to commit, what to ignore

Commit:
- `.tf` files (source of the module)
- `terraform.tfvars.example` (the template)
- `user-data.sh.tpl` (the bootstrap script)
- `.terraform.lock.hcl` once you've run `terraform init` (pins provider
  versions; keeps teammates and CI in sync)

Never commit:
- `terraform.tfvars` (your real values, including the admin CIDR)
- `.terraform/` (provider plugin binaries — regenerable with `init`)
- `terraform.tfstate` / `*.tfstate.backup` (state files — may contain
  sensitive attributes in future versions even when they don't today)

`.gitignore` at the repo root already covers all of these.
