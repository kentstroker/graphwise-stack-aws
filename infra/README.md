# Graphwise Stack — Terraform module

**Maintainer:** Kent Stroker

This module provisions the AWS infrastructure for a single-node demo
deployment of the Graphwise Stack: one EC2 instance (r6g.2xlarge,
Amazon Linux 2023 ARM64, 300 GB encrypted gp3), one Security Group
(22 admin / 80 world / 443 world), one Elastic IP, and a cloud-init
bootstrap script that installs Docker + KIND + kubectl + helm,
clones the public stack repo, and brings up a single-node KIND
cluster — all running under the AL2023 default `ec2-user` account.

What this module does **not** do:
- **EIP allocation** — strongly recommended to pre-allocate the EIP
  outside Terraform per [SETUP §6 → Pre-allocate the Elastic IP](../SETUP.md#pre-allocate-the-elastic-ip-strongly-recommended)
  and pass its Allocation ID via `existing_eip_allocation_id`. The
  module then only **associates** the existing EIP, so destroy
  detaches without releasing and DNS stays valid forever. Falling
  back to fresh-EIP-per-apply (leaving the var empty) means re-doing
  DNS after every rebuild.
- **DNS** — when the EIP is pre-allocated, you create the two A
  records up front in SETUP §6 (the IP is already known). Slow
  path: email Kent the EIP from the `terraform apply` outputs after
  the fact and he adds them in GoDaddy.
- License file placement — the three Graphwise license binaries are
  scp'd in by hand after the instance is up.
- Let's Encrypt cert issuance — handled by cert-manager via
  ingress-nginx HTTP-01 challenge during `cluster-bootstrap.sh`.

The module is intentionally small-scope: everything that can be
automated cleanly is; everything with a human-in-the-loop dependency
stays as a documented manual step.

---

## Safety: never unscoped `terraform apply` after first provision

This is the most important single thing to know about operating this
module. Read it before you run `terraform apply` for any reason
other than the initial provision.

**The hazard.** `data "aws_ami" "al2023_arm64"` uses
`most_recent = true` — every plan re-resolves the latest published
AL2023 ARM64 AMI ID. AWS publishes refreshes constantly (security
patches, kernel bumps, package updates). Any time the resolved AMI
ID differs from what's stored in state, Terraform marks the AMI
attribute on `aws_instance.stack` as needing change, and AMI is a
**force-replace** attribute. Force-replace means the EC2 is
**destroyed** (root EBS volume, all PVCs, all data) and a new one is
launched in its place — even if the change you actually wanted was
something tiny like an SG ingress edit or an `extra_tags` tweak.

We have lost a fully-validated demo deployment to this exact bug.
It will happen to you too if you let it.

**The rule.**

1. Never run `terraform apply` without first running `terraform plan`
   and reading the output **character by character**.
2. If the plan shows `aws_instance.stack` with a `# forces
   replacement` annotation on the `ami` line (or any
   force-replacement annotation), **abort**. Don't apply.
3. For narrow changes (SG, tags, etc.), prefer one of the safer
   paths below over an unscoped apply.

**Safer paths for common edits:**

| What you want to change | Safer path |
|---|---|
| `admin_cidr` (SSH source IP) | AWS Console → EC2 → Security Groups → edit the inbound rule directly. Update `terraform.tfvars` for documentation only — the SG ignores `terraform apply` post-provision (see SG ingress note below). |
| Adding the EC2 Instance Connect SG rule | Console-only, manual. See [SETUP §9](../SETUP.md#9-optional-ec2-instance-connect--manual-sg-rule). The rule survives because of the SG's `ignore_changes = [ingress]`. |
| `extra_tags` | AWS Console → EC2 / EIP / SG → Tags tab → edit. Update `terraform.tfvars` to match. |
| `instance_type`, `root_volume_gb` | These force-replace by design. Treat as a destroy/recreate; snapshot EBS first. |
| Anything else | `terraform plan -target=<resource>` to scope, read the output, only then apply. |

**SG ingress is intentionally Terraform-managed only on first apply.**
`aws_security_group.stack` carries `lifecycle { ignore_changes =
[ingress] }`. Terraform creates the three baked-in rules (port 22
from `admin_cidr`, 80 world, 443 world) at provision time, then
stops watching ingress drift. This is what lets the manual EC2
Instance Connect rule (SETUP §9) survive future applies. Trade-off:
edits to the inline `ingress` blocks in `main.tf` won't take effect
on existing deployments — use the Console for any post-provision
SG ingress change.

**`-target` is not a magic shield.** It scopes the apply, but
Terraform's dependency graph can still pull in dependent resources.
Always read the plan.

**Long-term fix (already shipped, two layers).**

1. **Belt:** `aws_instance.stack` carries `lifecycle.ignore_changes
   = [ami]` (see `main.tf`). Once the instance is provisioned,
   Terraform never marks it for replacement on AMI grounds even if
   the data-source lookup resolves a different AMI ID. This protects
   *every* deployment automatically — no operator action required.
2. **Braces:** the `ami_override` variable lets you explicitly pin
   the AMI ID at the lookup site too, which makes `terraform plan`
   output cleaner (no spurious AMI diffs) and turns intentional AMI
   upgrades into an explicit `terraform.tfvars` edit. Strongly
   recommended after first apply:

   ```bash
   cd infra/terraform
   terraform output -raw ami_id              # prints ami-...
   $EDITOR terraform.tfvars                  # set ami_override = "ami-..."
   terraform plan                            # MUST show "No changes"
   ```

   See the post-apply runbook below ("§1.5 Lock the AMI") for the
   walkthrough, and the variable's documentation in `variables.tf`
   for the upgrade flow.

---

## Prerequisites

One-time, per laptop:

1. **An AWS account.** Each presales SE uses their own. This module
   won't touch any other account.
2. **AWS credentials configured locally.** Run `aws configure` with
   the §4a Terraform user's Access Key ID + Secret Access Key
   (`AmazonEC2FullAccess` is the baseline — see
   [SETUP §4a](../SETUP.md#4a-create-the-terraform-iam-user)).
   SSO works too: `aws configure sso`.
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

1. **Pick a subdomain** under your base domain (default
   `semantic-proof.com`). Lowercase, hyphens OK; multi-level
   (`demo.scott`) supported. Examples: `scott`, `acme-corp`.
2. **Pre-allocate an Elastic IP** and capture its Allocation ID
   (`eipalloc-...`) and Public IPv4. Walkthrough in
   [SETUP §6 → Pre-allocate the Elastic IP](../SETUP.md#pre-allocate-the-elastic-ip-strongly-recommended).
3. **Add the two DNS A records** (`<sub>.<base>` apex + `*.<sub>.<base>`
   wildcard) pointing at the pre-allocated IP, so propagation
   happens before `terraform apply` finishes.
4. **Know your current public IP** — Terraform uses it to restrict SSH
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
# the output. Resource counts:
#   - Pre-allocated EIP:  ~5 resources (random_id, cloudinit_config
#     data source, aws_security_group, aws_instance, aws_eip_association).
#   - Fresh EIP:          ~5 resources (aws_eip in place of the association).
terraform plan

# Commit the change. Takes 1-2 minutes for AWS to bring the instance
# up; another 2-3 minutes for cloud-init to finish the bootstrap.
terraform apply
```

When `apply` completes you'll see outputs (abridged):

```
Outputs:
elastic_ip            = "54.149.12.34"
eip_mode              = "existing (allocation_id=eipalloc-0123abc...)"
godaddy_dns_records   = <<-EOT
                          Add these two A records ...
                        EOT
instance_id           = "i-0abcdef0123456789"
instance_public_dns   = "ec2-54-149-12-34.us-west-2.compute.amazonaws.com"
ssh                   = "ssh -i <path-to-your-keypair.pem> ec2-user@54.149.12.34"
expected_urls         = { chatbot = "https://graphrag.<sub>.<base>/" ...}
bootstrap_log_hint    = "ssh ... 'sudo tail -f /var/log/bootstrap.log'"
```

`eip_mode` confirms whether you're on the persistent
(`existing_eip_allocation_id` set) path or the fresh-EIP path. If
DNS was pre-set per SETUP §6, the `godaddy_dns_records` block is
just confirmation; otherwise it's the post-apply checklist of records
to create.

---

## What happens on the instance during bootstrap

The cloud-init script (`user-data.sh.tpl`) runs as root on first
boot. It logs to `/var/log/bootstrap.log` on the instance and also
tags syslog with `bootstrap`. Steps, in order:

1. `dnf upgrade -y --refresh`.
2. Installs base packages (`docker, git, jq, bind-utils,
   conntrack-tools, ethtool, socat, iproute, httpd-tools` for
   `htpasswd`, plus `tar gzip ca-certificates` for the helm
   tarball + cluster-bootstrap script).
3. Drops a `/etc/ssh/sshd_config.d/10-graphwise.conf` lifting
   `MaxStartups` and switching SFTP to `internal-sftp` (sshd hardening
   that survives openssh-server upgrades).
4. Sysctls: `net.ipv4.ip_forward=1` plus elevated
   `fs.inotify.max_user_{watches,instances}` for kubelet's file
   watching.
5. `systemctl enable --now docker` and adds `ec2-user` to the
   `docker` group so KIND/kubectl runs without `sudo`.
6. Installs pinned versions of `kind`, `kubectl`, and `helm` to
   `/usr/local/bin/`.
7. Appends `KUBECONFIG` + a couple of kubectl aliases to
   `~ec2-user/.bashrc`.
8. Clones this repository into the user's home as
   `~/graphwise-stack-aws`.
9. Creates the single-node KIND cluster `graphwise` from
   [infra/kind/kind-config.yaml](kind/kind-config.yaml). Host ports
   80 and 443 are mapped into the control-plane container so
   ingress-nginx can serve traffic on the EIP.
10. Writes `~/graphwise-secrets.yaml` containing the
    Terraform-generated n8n encryption key (consumed automatically
    by `scripts/reset-helm.sh`).
11. Drops a `~/NEXT_STEPS.txt` file with the post-apply runbook.

No separate "named user" is created — Amazon Linux 2023 ships with
`ec2-user` pre-configured with the SSH key (AWS injects it during
launch) and `wheel`-group sudo. Everything runs as `ec2-user`. The
host has SELinux enforcing; container-selinux + Docker's mature
RHEL-family integration handle the labelling without intervention.

The cluster is up at this point but has no operators or app
workloads yet — that's the post-apply runbook below.

---

## Post-apply runbook

From `terraform apply` complete to a working HTTPS stack.

### 1. Watch the bootstrap finish

```bash
# Takes 2-3 minutes after apply. Tail the log to know when it's done.
ssh -i <path-to-your-keypair.pem> ec2-user@<elastic_ip> 'sudo tail -f /var/log/bootstrap.log'
```

Look for `=== Bootstrap complete at <timestamp> ===`. Then Ctrl-C.

### 1.5 Lock the AMI (do this before the next `terraform apply`)

```bash
cd infra/terraform
terraform output -raw ami_id              # prints e.g. ami-0123456789abcdef0
$EDITOR terraform.tfvars                  # set: ami_override = "ami-..."
terraform plan                            # MUST show "No changes"
```

Pins the deployment against future `aws_ami` lookup drift. The
`lifecycle.ignore_changes = [ami]` block on `aws_instance.stack`
already protects against in-place force-replace; setting
`ami_override` additionally cleans up plan output and makes future
AMI upgrades intentional. See the Safety section above for the
full rationale.

### 2. Verify DNS (or add records, slow path)

**Fast path (followed SETUP §6):** the two A records were created
when the EIP was pre-allocated. Just confirm propagation:

```bash
dig +short <sub>.<base> poolparty.<sub>.<base>
# Both lines should print your EIP.
```

If both resolve, skip to §3.

**Slow path (no pre-allocation):** Terraform allocated a fresh EIP
this apply; the `godaddy_dns_records` output prints what to add.
Template for the email to Kent:

> Hi Kent,
>
> Please add **two** A records in the `<base_domain>` zone:
>
> - **Name:** `<your-subdomain>.<base>` → **Points to:** `<elastic_ip>` (TTL 5 min)
> - **Name:** `*.<your-subdomain>.<base>` → **Points to:** `<elastic_ip>` (TTL 5 min)
>
> Thanks.

Both records are required — the wildcard (`*.<sub>.<base>`) is what
makes every per-app subdomain (`poolparty`, `auth`, `graphrag`, …)
resolve. Propagation is usually under 5 minutes.

```bash
dig +short <sub>.<base> poolparty.<sub>.<base>
# Both lines should print your EIP.
```

### 3. SSH in as ec2-user

```bash
ssh -i <path-to-your-keypair.pem> ec2-user@<elastic_ip>
```

The `~/NEXT_STEPS.txt` file mirrors this runbook.

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

After it settles: `https://<sub>.<base>/` (Console landing page).
See [DEPLOY.md](../DEPLOY.md) for the full app URL list and
[CONSOLE-GUIDE.md](../CONSOLE-GUIDE.md) for credentials.

---

## Teardown

```bash
cd infra/terraform
terraform destroy
```

Destroys in this order (Terraform figures it out from dependencies):

1. EIP — behavior depends on mode:
   - **`existing_eip_allocation_id` set:** only the
     `aws_eip_association` is destroyed. The EIP itself is
     **preserved** (it lives outside Terraform's lifecycle), so its
     IP stays stable for the next apply and DNS records remain valid.
   - **Fresh-EIP mode:** the `aws_eip` is destroyed and the IP is
     released back to AWS. Next apply gets a different IP and DNS
     must be updated.
2. EC2 instance (including root EBS volume — **all data is gone**)
3. Security Group

**Before destroying a real demo you care about**, snapshot the EBS
volume via the AWS Console if you want to keep the data. Terraform
does not snapshot on destroy.

The Key Pair is **not** destroyed — Terraform only references it.
Same goes for the pre-allocated EIP when `existing_eip_allocation_id`
is set.

DNS cleanup:
- **Pre-allocated EIP:** leave DNS in place so the next apply lands
  on the same IP without DNS updates.
- **Fresh-EIP mode:** the released IP will eventually go to someone
  else, so ask Kent (or your DNS admin) to remove the A records to
  avoid stale subdomains pointing at someone else's instance.

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

The AMI data source didn't match a current Amazon Linux 2023 ARM64
image. Every standard AWS region carries the official AL2023 ARM64
AMIs; if this fails you're either in a brand-new region without them
yet, or AWS renamed the AMI pattern. Check manually:

```bash
aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=al2023-ami-*-arm64" \
    --query 'Images[*].[Name,ImageId]' \
    --output table \
    --region <your-region>
```

If the query returns rows, the module should work — try a fresh
`terraform init`. If it's empty, pick a different region.

### `UnauthorizedOperation` on `RunInstances`

Your IAM user doesn't have `ec2:RunInstances`. Attach the AWS-managed
`AmazonEC2FullAccess` policy, or a narrower custom policy that permits
the `ec2:*` actions the module uses (RunInstances, AssociateAddress,
AuthorizeSecurityGroupIngress, etc.).

### Bootstrap script fails silently

SSH in as `ec2-user`, read `/var/log/bootstrap.log`. The script runs
under `set -e` so first error is final. Common culprits:

- Transient dnf mirror failures — rerun the failing `dnf install`
  and manually step through the rest of the script from where it
  stopped. (The script is largely idempotent but wasn't designed
  for partial-failure recovery.)
- KIND cluster create fails because the docker-group membership
  for ec2-user wasn't picked up by the bootstrap heredoc. The
  heredoc uses a login shell (`sudo -u ec2-user -i bash <<INNER`)
  to force a fresh group lookup; if that ever drifts, the symptom
  is `Got permission denied while trying to connect to the Docker
  daemon socket`. Re-run the kind step manually as ec2-user after
  the bootstrap, and patch user-data.

### `terraform apply` wants to rebuild the instance after I edit user-data

That's expected — changing user-data changes `user_data_base64`
on the resource, and `ignore_changes = [user_data_base64]`
prevents drift redeploys, but also means user-data changes don't
take effect on an existing instance. If you really need to update
user-data on an existing instance, either SSH in
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

## Don't edit `variables.tf` for customization

`variables.tf` is **module source code** — variable declarations,
validation rules, and safety-net defaults. Every per-deployment knob
(region, base_domain, subdomain, instance_type, EIP allocation ID,
toggles, etc.) belongs in **`terraform.tfvars`**, not in `variables.tf`.

If you find yourself wanting to "just change the default in
variables.tf", set the value in your `terraform.tfvars` instead. The
defaults in `variables.tf` exist only as a safety net for power users
running raw `terraform apply -var ...` without a tfvars file; in the
standard workflow they are never touched. Editing `variables.tf`:

- Couples your deployment to your fork of the module (you can't pull
  upstream updates cleanly).
- Hides the value from anyone reading `terraform.tfvars` — the actual
  source of truth for what's deployed.
- Tends to drift from `terraform.tfvars.example` (the file new
  teammates copy from), so the example becomes a lie.

The shipped `terraform.tfvars.example` already lists the most-edited
variables (`region`, `base_domain`, `subdomain`, `key_pair_name`,
`admin_cidr`, `availability_zone`, `existing_eip_allocation_id`) in
its REQUIRED section so you can't miss them. `variables.tf` stays
static.

---

## What to commit, what to ignore

Commit:
- `.tf` files (source of the module — including `variables.tf`)
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
