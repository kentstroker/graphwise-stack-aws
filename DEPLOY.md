# Graphwise Stack — Deploy Walkthrough

**Maintainer:** Kent Stroker

End-to-end walkthrough for deploying a **Helm-on-KIND** Graphwise
stack (PoolParty + GraphRAG) on a single AWS EC2 instance.
Companion to [README.md](README.md) (one-page summary) and
[SETUP.md](SETUP.md) (laptop-zero prerequisites — start there if
this is a fresh laptop).

Public, MIT-licensed, AS-IS, no warranty (see [LICENSE](LICENSE)).

> **Demo-grade.** This stack ships with default passwords, single-replica
> services, and zero hardening. Don't put real customer data in it. The
> [TLS layer](#tls) is the one production-quality piece — public LE certs
> via cert-manager — but everything behind ingress assumes a friendly
> environment.

## What you get

A single-node KIND cluster running on one EC2 host, with two Helm
releases that together bring up:

| Release | Namespace | Apps |
|---|---|---|
| `graphwise-stack` | `graphwise` | PoolParty (Thesaurus / GraphSearch / Extractor), GraphDB ×2 (embedded + projects), Elasticsearch, ADF, Semantic Workbench, GraphViews, RDF4J, UnifiedViews, Console landing page |
| `graphwise-stack` (cont.) | `keycloak` | Keycloak (operator-managed), realm imports for poolparty + graphrag, master-realm admin bootstrap Job, CNPG Postgres |
| `graphwise-stack` (cont.) | `graphrag` | n8n CNPG Postgres + supporting Secrets/ConfigMap for the graphrag release |
| `graphrag` | `graphrag` | GraphRAG chatbot, conversation API, components, workflows (n8n) |

Each app gets its own subdomain — `poolparty.<sub>.<base>`,
`auth.<sub>.<base>`, `graphrag.<sub>.<base>`, `graphdb.<sub>.<base>`,
`graphdb-projects.<sub>.<base>`, `adf.<sub>.<base>`, etc., plus the
console at the apex `<sub>.<base>`. Every Ingress gets its own LE cert
issued by cert-manager.

See [CONSOLE-GUIDE.md](CONSOLE-GUIDE.md) for the full URL + credentials table.

---

## Prerequisites

Detailed, OS-specific walk-through is in **[SETUP.md](SETUP.md)** —
laptop-zero through ready-for-`terraform-apply`. At a glance:

- AWS account + **two IAM users** (don't use root for daily work):
  - **Terraform user** (e.g. `terraform-demo`) with
    `AmazonEC2FullAccess`.
  - **Bedrock user** (e.g. `graphrag-bedrock`) with a narrow inline
    policy granting `bedrock:InvokeModel` on TWO models:
    `cohere.embed-english-v3` (GraphRAG embeddings) and
    `anthropic.claude-sonnet-4-5-20250929-v1:0` (PoolParty "Build
    Your Taxonomy"). SETUP §4b walks the full setup.
  - **Note on actor:** all IAM user/policy creation is performed by
    the **root account user** or an existing **IAM admin user**, NOT
    by `terraform-demo` (which lacks IAM permissions). SETUP §4
    opens with an actor table — read it before clicking through any
    IAM Console step.
- AWS Bedrock available in your region. No per-model access request
  needed — AWS retired the "Modify model access" approval flow.
  Both models are invokable as soon as the IAM policy attached to
  the Bedrock user grants `bedrock:InvokeModel` on their ARNs.
- Terraform 1.5+ and AWS CLI v2 installed and authenticated.
- EC2 key pair downloaded and `chmod 400`'d.
- A subdomain plan (`<sub>.<base>` apex + `*.<sub>.<base>` wildcard
  records) on a domain you control. Graphwise SEs use Kent's
  `semantic-proof.com` zone; everyone else uses their own DNS
  provider (Route 53 (DNS hosting must be in the same AWS account)).
- **Graphwise-issued credentials and license material** — all four
  required for a full deploy; request from Graphwise:
  - Maven registry username + password (pulls private GraphRAG
    container images from `maven.ontotext.com`)
  - PoolParty license file (`poolparty.key`)
  - GraphDB EE license file (`graphdb.license`)
  - UnifiedViews license file (`uv-license.key`)
  - **n8n Enterprise license activation key** (drives the
    graphrag-workflows pod; without it, n8n won't start cleanly)
  - **AWS Bedrock access key** for the `graphrag-bedrock` IAM user
    you created in SETUP §4b (drives graphrag-components embedding
    calls)
  - For an umbrella-only deploy (`reset-helm.sh --skip-graphrag`),
    only the three license files + Maven creds are strictly
    required; the n8n license + Bedrock keys are deferred until
    you re-run without `--skip-graphrag`.

The EC2 instance side (Amazon Linux 2023 ARM64, Docker, KIND,
kubectl, helm) is handled by the Terraform module's cloud-init;
nothing to install there.

> **Where each command runs.** This walkthrough hops between your
> laptop and the EC2 instance. Each code block is prefaced with a
> `# On laptop` or `# On EC2` comment. Quick map:
>
> | Step | Where |
> |---|---|
> | §1 Provision the EC2 instance (`terraform apply`) | Laptop |
> | §1.5 Lock the AMI (`terraform output ...`) | Laptop |
> | §2 Verify DNS (`dig ...`) | Laptop |
> | §3 Connect (`ssh ...`, `scp ...`) — the SSH lands you on EC2 | Laptop → EC2 |
> | §4 Install operators (`./scripts/cluster-bootstrap.sh`) | EC2 |
> | §4a Verify observability (browser) | Either |
> | §5 Extract realm (`./scripts/extract-poolparty-realm.sh`) | EC2 |
> | §6 Install licenses (`./scripts/install-licenses.sh`) | EC2 |
> | §7 Edit `~/graphwise-secrets.yaml` | EC2 |
> | §8 Deploy (`./scripts/reset-helm.sh ...`) | EC2 |
> | §9 Verify URLs (curl + browser) | Either |
>
> **Terraform never runs on the EC2 instance.** The state file lives
> on your laptop; the EC2 is the workload, not the provisioner.

---

## Deploy from zero

### 1. Provision the EC2 instance

> **Fast path prereqs (recommended).** SETUP §6 had you pre-allocate
> an Elastic IP and create the two DNS A records pointing at it.
> If you did that, set `existing_eip_allocation_id` in
> `terraform.tfvars` to your `eipalloc-...` ID, and the EIP +
> DNS are already set-and-forget. **Slow path:** if you skipped
> SETUP §6, leave `existing_eip_allocation_id` empty and Terraform
> allocates a fresh EIP each apply — you'll do DNS in §2 below
> after the apply finishes.

> **⚠️ This is the ONLY time `terraform apply` is safe to run
> unscoped.** After this initial provision, every subsequent apply
> can force-replace the EC2 instance (and destroy all data on it)
> due to the `most_recent = true` AMI lookup. For any post-provision
> edits, see [infra/README.md → Safety: never unscoped apply after
> first provision](infra/README.md#safety-never-unscoped-terraform-apply-after-first-provision).

```bash
# On laptop
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars       # see the field-by-field table below
terraform init
terraform apply
```

#### What to put in `terraform.tfvars`

Four fields **must** be set before `terraform apply` will run.
Everything else has a sensible default — change only if you have a
reason. Full descriptions in
[`infra/terraform/variables.tf`](infra/terraform/variables.tf).

| Field | What | How to fill it |
|---|---|---|
| `subdomain` | Your slot under `base_domain`. All app hostnames live one level deeper (`poolparty.<sub>.<base>`, `auth.<sub>.<base>`, etc.). Lowercase, alphanumerics + hyphens; multi-level (`demo.scott`) supported. | Pick anything that's not already taken. Examples: `scott`, `acme-corp`, `myname-demo`. |
| `key_pair_name` | Name of an **existing** EC2 key pair in the target region. Terraform only references it — does not create it. | EC2 console → Network & Security → Key Pairs. Use the **name** as shown there, no `.pem` suffix. The matching `.pem` must already be on your laptop with `chmod 400`. |
| `admin_cidr` | Source IP allowed to SSH on port 22. Locks the security group down to your laptop. | `curl -4 icanhazip.com` from your laptop, then append `/32`. Example: `"203.0.113.42/32"`. **Never use `0.0.0.0/0`** — that opens SSH to the entire internet, on a box that also hosts Keycloak. |
| `availability_zone` | Single AZ to place the instance in. Must be inside your `region`. | Use any AZ in your region that has `r6g` capacity — e.g. `us-west-2a`, `us-east-1b`. If unsure, AWS Console → EC2 → Instance types → search `r6g.2xlarge` shows which AZs offer it. |

The remaining variables ship with defaults that work; here's when
you'd touch them:

| Field | Default | Override when |
|---|---|---|
| `region` | `us-west-2` | You want the instance closer to you (lower SSH latency) or in a region you already have other AWS resources in. Any region with `r6g` instances works. |
| `base_domain` | `semantic-proof.com` | You've forked this project and own a different parent domain. Graphwise SEs leave the default and email Kent for the A-records. |
| `instance_type` | `r6g.2xlarge` | You want to save money on a slimmer demo. `r6g.xlarge` (4 vCPU / 32 GB) works if you cut the addons — JVM heaps for PoolParty and Elasticsearch get tight. Don't go below that. |
| `root_volume_gb` | `300` | You're pruning the stack; 300 GB gives headroom for the KIND image cache + every PVC + log growth. Can grow later, can't shrink. |
| `github_repo_url` | upstream | You've forked the repo and want cloud-init to clone your fork. |
| `instance_name_prefix` | `graphwise-stack` | You want a different prefix for cost-allocation tags. Final Name tag is `<prefix>-<subdomain>`. |
| `existing_eip_allocation_id` | `""` (allocate fresh — slow path) | **Strongly recommended:** set to the `eipalloc-...` ID you captured in [SETUP §6 → Pre-allocate the Elastic IP](SETUP.md#pre-allocate-the-elastic-ip-strongly-recommended). Makes the EIP survive `terraform destroy`/`apply` cycles so DNS stays valid forever. Leaving empty falls back to fresh-EIP-per-apply, which means re-doing DNS after every rebuild. |
| `extra_tags` | `{}` | Your org needs Owner / Customer / CostCenter tags on AWS resources. Merged with the module's own `Name` / `Subdomain` / `ManagedBy` tags. |

After saving `terraform.tfvars`:

```bash
# On laptop
terraform init       # one-time; downloads the AWS provider plugin
terraform plan       # dry-run; review the plan (~5 resources)
terraform apply
```

Output includes the EIP, an `ssh` command line, and the
`route53_dns_records` block (the two A-records to add). The
cloud-init script takes 2–3 minutes after `apply` returns; tail it
with:

```bash
# On laptop
ssh -i $GRAPHWISE_KEY $GRAPHWISE_USER@$GRAPHWISE_HOST 'sudo tail -f /var/log/bootstrap.log'
```

Wait for `=== Bootstrap complete at <timestamp> ===`. The cluster is
already up at that point — `kind get clusters` shows `graphwise`.

See [infra/README.md](infra/README.md) for the full Terraform module
reference, including the post-apply runbook and teardown.

### 1.5 Lock the AMI (one-time, immediately after first apply)

Capture the AMI the instance was launched with and write it into
`terraform.tfvars` as `ami_override`. This protects the deployment
from being force-replaced the next time AWS publishes a refreshed
AL2023 AMI:

```bash
# On laptop (Terraform never runs on the EC2)
cd infra/terraform
terraform output -raw ami_id              # prints e.g. ami-0123456789abcdef0
$EDITOR terraform.tfvars                  # set: ami_override = "ami-0123456789abcdef0"
terraform plan                            # MUST show "No changes"
```

If `terraform plan` shows anything other than "No changes. Your
infrastructure matches the configuration", **stop and investigate**
before doing anything else — the override value or the captured AMI
ID is wrong.

> **Two layers of protection.** `aws_instance.stack` already has
> `lifecycle.ignore_changes = [ami]` so an unset `ami_override` is
> still safe post-provision. The override variable adds an explicit,
> human-readable pin (so plan output is clean and so AMI upgrades are
> intentional, not accidental). Both belt and braces.

To upgrade the AMI later (e.g. for a security patch):

```bash
# On laptop
aws ec2 describe-images --owners amazon --filters "Name=name,Values=al2023-ami-*-arm64" --query 'sort_by(Images,&CreationDate)[-1].[ImageId,Name,CreationDate]' --output text
# Pick the resulting ami-... ID, snapshot the EBS volume in the AWS
# Console first if you care about the data, then:
$EDITOR terraform.tfvars                  # bump ami_override
terraform plan                            # WILL show aws_instance.stack force-replace
terraform apply                           # destroys + recreates the instance
```

### 2. Verify DNS (or add records, slow path)

**Fast path (you followed SETUP §6):** the two A records already
exist and were created with the pre-allocated EIP. Just confirm
propagation:

```bash
# On laptop
dig +short <sub>.<base> poolparty.<sub>.<base>
```

Both should return your EIP. If they do, skip ahead to §3.

**Slow path (no pre-allocation):** Terraform allocated a fresh EIP
during §1; the `route53_dns_records` output prints the exact host /
value pairs to add. Two records, both pointing at the freshly
allocated EIP:

> - **A record:** `<sub>.<base>` → EIP, TTL 5 min
> - **A record:** `*.<sub>.<base>` → EIP, TTL 5 min

Graphwise field SEs: email Kent the values from the output and he
runs the AWS CLI command from the route53_dns_records output. Self-managed: add them yourself.

Wait for propagation — usually under 5 minutes:

```bash
dig +short <sub>.<base> poolparty.<sub>.<base>
```

Both should return your EIP. Without the wildcard, every per-app
subdomain (poolparty, auth, graphrag, …) returns NXDOMAIN and
nothing works.

### 3. Connect and prepare creds

```bash
# On laptop -- the ssh command lands you on the EC2 as ec2-user
ssh -i $GRAPHWISE_KEY $GRAPHWISE_USER@$GRAPHWISE_HOST
```

(`$GRAPHWISE_KEY`, `$GRAPHWISE_HOST`, `$GRAPHWISE_USER` are the three
exports you set in [SETUP §7](SETUP.md#export-the-deploy-environment-variables-now).)

Or, if you prefer AWS-injected per-session keys (and have the small
inline IAM policy from [SETUP §9 Method 1](SETUP.md#method-1-recommended-aws-cli--aws-ec2-instance-connect-ssh)):

```bash
# On laptop -- alternative login via AWS CLI EC2 Instance Connect
aws ec2-instance-connect ssh --instance-id $(terraform -chdir=infra/terraform output -raw instance_id) --private-key-file $GRAPHWISE_KEY
```

Both land you as `ec2-user`. (EC2 Instance Connect from the AWS Console
does **not** work against this stack's strict `admin_cidr` — see
[SETUP §9](SETUP.md#9-optional-ec2-instance-connect)
for why.)

**Preferred path — symmetric pull/push cycle.** Capture every
operator-supplied artifact on your laptop before `terraform destroy`,
restore it after `terraform apply`. The pair:

```bash
# Before terraform destroy: capture deployment state to a dated snapshot folder
# under ~/Downloads/ (each pull stands alone, no clobber of $HOME).
./scripts/laptop/pull-config.sh

# After terraform apply: restore the most recent snapshot in one shot.
./scripts/laptop/pushLastPull.sh
# (or, to push a specific snapshot:
#   ./scripts/laptop/push-config.sh \
#       --secrets-file ~/Downloads/graphwise-config-<UTC>/graphwise-secrets.yaml \
#       --licenses-dir ~/Downloads/graphwise-config-<UTC>/licenses )
```

What lands in the snapshot (`~/Downloads/graphwise-config-<UTC>/`):
- `payload.tgz` — the tarball as it arrived (kept for archival / re-extract)
- `graphwise-secrets.yaml` — single-file secrets (maven, Bedrock, n8n license, n8n encryption key)
- `chart-values.yaml` + `chart-values.diff` — the EC2's live chart values + diff vs git baseline (pre-overlay-arch deployments stored Bedrock/n8n license here; auto-migrated into the snapshot's `graphwise-secrets.yaml`)
- `dashboard-kubeconfig.yaml` — saves a separate scp post-deploy (NOT pushed back; token is tied to the cluster's signing key)
- `licenses/{poolparty.key, graphdb.license, uv-license.key}` — vendor license files
- `licenses/wildcard-tls.yaml` — the live LE wildcard TLS cert as a Secret YAML

The cert is the headline: `pull-config.sh` extracts it from
`kubectl get secret -n cert-manager wildcard-tls -o yaml`,
`push-config.sh` re-pushes it to `~/wildcard-tls-saved.yaml` on the
new EC2, and `cluster-bootstrap.sh` detects + applies it before
creating the Certificate resource. cert-manager sees a valid cert in
place and **skips the LE issuance call entirely** — saves a per-week
LE rate-limit slot (5 duplicate certs / identifier / 168h). Validation
is built in: SANs must match the new deployment's apex + wildcard,
cert must have >30 days remaining; on any mismatch, cert-manager
issues fresh.

The push helper also splices the FRESH `n8nEncryption.key` from the
new EC2 into your local secrets copy before push (the local one is
from a destroyed n8n DB and useless on the new one). Missing files
are warned + skipped, not fatal.

First time only (you don't yet have a snapshot to pull): edit
`~/graphwise-secrets.yaml` directly on the EC2 (cloud-init pre-creates
it with placeholders) and scp the three license files in. Subsequent
cycles are automatic: `pull-config.sh` before each destroy,
`pushLastPull.sh` after each apply.

**Manual fallback** — if you'd rather edit on the EC2 and scp licenses
ad-hoc, or you don't want the push helper:

```bash
# On EC2 (from the SSH session above)
cd ~/graphwise-stack-aws

# Edit the secrets overlay (cloud-init pre-created it with placeholders).
# Fill in maven.user/maven.pass + the awsCredentials + n8nLicense blocks.
# DO NOT touch n8nEncryption.key.
$EDITOR ~/graphwise-secrets.yaml

# Drop Graphwise license files via scp from your laptop:
mkdir -p files/licenses
# (back on your laptop, in another terminal)
#   scp -i $GRAPHWISE_KEY ~/path/to/poolparty.key $GRAPHWISE_USER@$GRAPHWISE_HOST:~/graphwise-stack-aws/files/licenses/poolparty.key
#   scp -i $GRAPHWISE_KEY ~/path/to/graphdb.license $GRAPHWISE_USER@$GRAPHWISE_HOST:~/graphwise-stack-aws/files/licenses/graphdb.license
#   scp -i $GRAPHWISE_KEY ~/path/to/uv-license.key $GRAPHWISE_USER@$GRAPHWISE_HOST:~/graphwise-stack-aws/files/licenses/uv-license.key
ls files/licenses/
```

**Filename matters.** `scripts/install-licenses.sh` looks for these
exact names — anything else is silently ignored:

| File | Purpose |
|---|---|
| `files/licenses/poolparty.key` | PoolParty (also used by Semantic Workbench) |
| `files/licenses/graphdb.license` | GraphDB EE (used by both GraphDB instances) |
| `files/licenses/uv-license.key` | UnifiedViews |

Graphwise's email/portal will hand you files with vendor-specific
names (e.g. `pp-eval-2026.key`) — **rename them on disk** to the
names above before running `install-licenses.sh`. Example:

```bash
mv ~/Downloads/pp-eval-2026.key       files/licenses/poolparty.key
mv ~/Downloads/graphdb-ee-2026.lic    files/licenses/graphdb.license
mv ~/Downloads/uv-2026.key            files/licenses/uv-license.key
ls -la files/licenses/
```

The license **contents** are vendor-issued binary blobs; we don't
care what's inside, only that the three filenames match. If you
later get fresh licenses (renewals, different customer engagement),
overwrite these three files in place and re-run
`./scripts/install-licenses.sh` followed by a Helm upgrade.

### 3.5 Upload ingest data (optional)

The Terraform cloud-init creates a standardized landing pad for
ingest data — PDFs, source documents, large reference corpora that
GraphRAG / PoolParty pipelines consume. Upload here once; later
chart work mounts this directory into the consuming pods via a
hostPath PV/PVC.

**Standardized path:** `/home/ec2-user/staging-data/` on the EC2.
The directory exists from first boot; you don't need to create it.

#### Upload from your laptop (rsync — recommended for multi-GB)

Use `rsync` instead of `scp` for any sizable upload (multiple GB,
many files, slow links). It compresses on the wire (`-z`), shows
progress (`-P`), and resumes interrupted transfers cleanly.

**Install if missing** (Apple replaced the bundled rsync with
openrsync in macOS Ventura+; brew installs the proper GNU rsync):

```bash
# laptop -- install once
brew install rsync               # macOS
choco install rsync -y           # Windows
```

Then upload:

```bash
# On laptop
rsync -azP -e "ssh -i $GRAPHWISE_KEY" ~/path/to/local-pdfs/ $GRAPHWISE_USER@$GRAPHWISE_HOST:~/staging-data/
```

(Note the trailing `/` on the source. `rsync` is sensitive to this:
`source/` copies the *contents* of `source` into the destination;
`source` (no slash) copies the directory `source` itself into the
destination.)

#### Fallback: `scp` (when you can't / won't install rsync)

`scp` ships with every macOS / Windows / Linux SSH client by
default. Works fine for one-off small uploads, but has no resume
support and no compression — a dropped connection on a 5 GB
transfer means starting over. Use only for small files or as a
last resort on a stable link:

```bash
# On laptop -- single file
scp -i $GRAPHWISE_KEY ~/path/to/file.pdf $GRAPHWISE_USER@$GRAPHWISE_HOST:~/staging-data/
```

```bash
# On laptop -- whole directory (recursive)
scp -r -i $GRAPHWISE_KEY ~/path/to/local-pdfs/ $GRAPHWISE_USER@$GRAPHWISE_HOST:~/staging-data/
```

#### Verify the upload landed

```bash
# On EC2
ls -la ~/staging-data/ && du -sh ~/staging-data/
```

Expected: your files listed, total size matches what you sent.

#### Where the data lives + persistence guarantees

- Stored on the EC2's root EBS volume.
- **Survives** EC2 stop/start, `cluster-resume.sh`, `reset-helm.sh`,
  KIND cluster recreate, helm upgrade.
- **Does NOT survive** `terraform destroy` (the root EBS volume goes
  with the instance). For data you can't re-upload, attach a separate
  EBS volume — out of scope for this default; mention it in an issue
  if you need the pattern documented.

#### Making the data visible inside Kubernetes pods (deferred)

Today the data is on the host disk but not yet inside the cluster.
When you have a real ingest workload, the wiring is:

1. Add a `hostPath` mount to `infra/kind/kind-config.yaml` mapping
   `/home/ec2-user/staging-data` → `/staging-data` (inside the KIND
   container). Requires KIND cluster recreate to take effect.
2. Add a `PersistentVolume` + `PersistentVolumeClaim` per consuming
   namespace (one PV per PVC; all PVs use the same `hostPath:
   /staging-data`).
3. Mount the PVC into the consuming pod's `volumeMounts`.

We'll add a Helm template for steps 2-3 when there's a concrete
consumer (graphrag-workflows, graphrag-components, or wherever the
ingest happens). Ping when you're ready and we'll wire it.

### 4. Install cluster operators

One-time install of ingress-nginx, cert-manager (+ Let's Encrypt
ClusterIssuer), CloudNativePG, Keycloak operator, metrics-server,
**Kubernetes Dashboard**, and **kube-prometheus-stack** (Prometheus
+ Grafana + AlertManager + node-exporter + kube-state-metrics).
Also creates the `graphwise` image-pull secret in the `graphwise` and
`graphrag` namespaces, and provisions per-host Ingresses for the
three observability UIs gated by the same demo basic-auth pattern as
GraphDB / RDF4J.

```bash
# On EC2
export LE_EMAIL=you@example.com
./scripts/cluster-bootstrap.sh
```

Three env vars are required, all auto-exported via
`/etc/profile.d/graphwise.sh` from cloud-init:

| Var | Source | Used by |
|---|---|---|
| `GRAPHWISE_APEX` | cloud-init from `var.subdomain.var.base_domain` | observability Ingress hostnames (dashboard / prometheus / grafana) + the wildcard cert SANs |
| `ROUTE53_ZONE_ID` | cloud-init from `var.route53_zone_id` | cert-manager DNS-01 ClusterIssuer (Route 53 solver writes `_acme-challenge` TXT records into this zone) |
| `AWS_REGION` | cloud-init from `var.region` | cert-manager Route 53 solver's STS endpoint selection |

Plus operator-supplied: `LE_EMAIL` (your Let's Encrypt account email).

> **⚠ Footgun: SSH session pre-dates the EC2 rebuild.**
> If your shell was open BEFORE `terraform apply` finished
> (i.e., you SSH'd in once and your tabs survived the rebuild),
> `/etc/profile.d/graphwise.sh` won't be sourced into your current
> shell — only fresh login shells inherit it. `cluster-bootstrap.sh`
> bombs immediately at the `${ROUTE53_ZONE_ID:?...}` required-env
> check, after installing only ingress-nginx. Symptom in
> `validate-bootstrap.sh`: every namespace except ingress-nginx
> shows "0 pods", `letsencrypt-prod ClusterIssuer NOT Ready (status=missing)`.
>
> **Two recovery paths:**
>
> ```bash
> # On EC2 -- option A: source the profile in your current shell, then re-run.
> source /etc/profile.d/graphwise.sh
> echo "GRAPHWISE_APEX=$GRAPHWISE_APEX ROUTE53_ZONE_ID=$ROUTE53_ZONE_ID AWS_REGION=$AWS_REGION"
> LE_EMAIL=you@example.com ./scripts/cluster-bootstrap.sh
> ```
>
> ```bash
> # On EC2 -- option B: just open a fresh login shell.
> exit
> # then SSH back in -- new shell sources the profile automatically
> ssh -i $GRAPHWISE_KEY $GRAPHWISE_USER@$GRAPHWISE_HOST
> LE_EMAIL=you@example.com ./scripts/cluster-bootstrap.sh
> ```
>
> Either way `cluster-bootstrap.sh` is idempotent — it picks up
> where it left off (ingress-nginx already installed, skips it,
> moves on to cert-manager + reflector + the rest).

Takes ~5–6 minutes the first time (image pulls + helm waits +
LE DNS-01 wildcard cert issuance — though if you pushed a saved
wildcard cert via `scripts/laptop/push-config.sh`,
cluster-bootstrap.sh restores it from `~/wildcard-tls-saved.yaml`
and skips the LE call entirely).

Idempotent — safe to re-run.

#### Confirm cluster-bootstrap.sh finished cleanly

```bash
# On EC2
./scripts/validate-bootstrap.sh
```

One-shot validator. Clears the screen and walks every operator
namespace, the ClusterIssuer, both image-pull secrets, the
dashboard kubeconfig, and a cluster-wide pod sweep. Prints a
color-coded per-check pass/fail (✓/✗/⚠) and an overall verdict.
Read-only against the cluster; safe to re-run any time. Exits 0
on green, 1 on any failure (so it can also gate downstream
automation if you wire one up).

If a check fails, paste the failing line's expected vs actual
output and the tail of `/tmp/cluster-bootstrap-<timestamp>.log`
for diagnosis. The bootstrap script itself is idempotent —
re-running it usually clears transient pod-pending states.

#### 4a. Verify the observability tier

After the script completes, the three observability UIs become
reachable at:

- `https://dashboard.<sub>.<base>/` — Kubernetes Dashboard (cluster
  introspection)
- `https://prometheus.<sub>.<base>/` — Prometheus UI (raw metrics +
  PromQL)
- `https://grafana.<sub>.<base>/` — Grafana with ~30 pre-built K8s
  dashboards

Auth pattern per app:

- **Dashboard** — bearer token only (no basic auth in front; the
  Dashboard's own bearer-token requirement is sufficient and
  basic-auth re-prompted on every tab switch).
- **Grafana** — Grafana's own login only (`admin` /
  `demo-graphwise-2026`); session cookies survive tab switches
  cleanly.
- **Prometheus** — basic auth `demo` / `rdf#rocks` (Prometheus
  has no auth of its own; basic auth is the only gate).

Cert-manager issues per-host LE certs ~30–60s after the Ingress
lands; if the browser shows a cert error, give it another minute
and refresh.

##### Kubernetes Dashboard sign-in flow

The Dashboard login screen offers two options: **Bearer Token**
or **Kubeconfig**. The `dashboard-admin` ServiceAccount +
`cluster-admin` ClusterRoleBinding from `cluster-bootstrap.sh`
work with either, but the **Kubeconfig upload is the recommended
path** — the Token field's paste handler is broken in Chrome and
Safari (silently rejects pasted input). `cluster-bootstrap.sh`
auto-generates the kubeconfig at `~/dashboard-kubeconfig.yaml`
on EC2 with the token embedded.

To get the token:

```bash
kubectl -n kubernetes-dashboard get secret dashboard-admin-token -o jsonpath='{.data.token}' | base64 -d ; echo
```

Copy the entire string that prints (no `Bearer ` prefix needed).
Paste it into the Dashboard's "Enter token" field, click **Sign In**,
land on the cluster overview showing all namespaces.

`cluster-bootstrap.sh` provisions a long-lived `dashboard-admin-token`
Secret of type `kubernetes.io/service-account-token` — same value
every time, never expires, lives until you delete the Secret. Save
it once in your password manager and reuse for the life of the
deployment. To revoke (e.g. team member leaves):

```bash
kubectl -n kubernetes-dashboard delete secret dashboard-admin-token
```

The `kubectl create token` ephemeral form (capped at ~1 year by the
API server's `--service-account-max-token-expiration`) is also
supported if you'd rather rotate periodically — same SA, same
cluster-admin RBAC.

> **The Dashboard's token-field paste handler is broken** (v2.7.0,
> Chrome + Safari + others — silently rejects pasted input, no
> error). **Use the Kubeconfig login option instead — same SA
> token, different upload mechanism.** `cluster-bootstrap.sh`
> auto-generates the kubeconfig at `~/dashboard-kubeconfig.yaml`
> on the EC2 host. Pull it down with one scp:
>
> ```bash
> scp -i $GRAPHWISE_KEY $GRAPHWISE_USER@$GRAPHWISE_HOST:~/dashboard-kubeconfig.yaml ~/Downloads/
> ```
>
> On the Dashboard login screen → switch radio to **Kubeconfig** →
> "Choose kubeconfig file" → select the downloaded file → Sign In.
> Save the kubeconfig wherever you keep deployment artifacts;
> reuse for the life of the token (forever, until you delete the
> underlying `dashboard-admin-token` Secret).

##### Grafana sign-in flow

Single layer: Grafana's own login page — `admin` /
`demo-graphwise-2026`. Session cookies survive tab switches.

The Grafana admin password is set in
`charts/observability/kube-prometheus-stack-values.yaml` →
`grafana.adminPassword`. Rotate there + re-run `cluster-bootstrap.sh`
to roll it.

##### Prometheus

Prometheus has no application-level auth — the basic-auth at the
ingress is the only protection. After signing in, "Status → Targets"
should show kube-state-metrics, node-exporter, kubelet,
prometheus-operator, and the kube-prometheus-stack components all
`UP`. PromQL queries via the "Graph" tab.

### 5. Install the realm-import JSON for PoolParty

```bash
# On EC2
./scripts/extract-poolparty-realm.sh
```

Pulls the realm export out of `ontotext/poolparty-keycloak:latest`
and drops it where the Helm chart expects it. Re-run if you bump the
image tag.

### 6. Install the license Secrets

```bash
# On EC2
./scripts/install-licenses.sh
```

Reads `files/licenses/*` and creates the three K8s Secrets the chart
templates mount.

### 7. Configure GraphRAG runtime credentials

All operator-editable secrets live in **`~/graphwise-secrets.yaml`**
on the EC2 host — created automatically by Terraform cloud-init,
gitignored, never tracked. `reset-helm.sh` auto-includes it via
`-f`, so its values override the chart defaults at install time.

Why this overlay file exists: editing chart `values.yaml` directly
means every `git pull` is a merge conflict against your real
credentials. Keeping the credentials in `~/graphwise-secrets.yaml`
(EC2-local, never in git) makes pulls always-clean fast-forwards.

```bash
# On EC2
$EDITOR ~/graphwise-secrets.yaml
```

Three blocks — fill in the first two:

```yaml
graphrag-secrets:
  # AWS Bedrock credentials for the graphrag-components pod.
  # Use the access key from the graphrag-bedrock IAM user you
  # created in SETUP.md §4b. The region must match the region the
  # IAM policy ARN was scoped to.
  awsCredentials:
    region: "us-west-2"
    accessKeyId: "AKIA<your access key id>"           # ← FILL IN
    secretAccessKey: "<your secret access key>"      # ← FILL IN

  # n8n Enterprise license activation key.
  n8nLicense:
    activationKey: "<your-n8n-license-key>"          # ← FILL IN

  # AUTO-GENERATED by Terraform; DO NOT EDIT.
  n8nEncryption:
    key: "<auto-generated-hex>"
```

> **n8nEncryption.key** is generated once by Terraform's
> `random_id.n8n_encryption_key` and persisted in state. Don't
> touch it — n8n encrypts every stored credential with this key
> on first boot, so changing it makes every saved n8n connection
> unreadable forever (no recovery path). The key only regenerates
> on `terraform destroy` + re-apply (which also wipes the n8n DB,
> so the new key is then fine).

Things that can stay at their shipped values for a demo
(in `charts/graphwise-stack/values.yaml`):

- The `change-me-*` Postgres passwords — internal to the cluster,
  not user-facing.
- `graphragConversationClientSecret` / `conversationKeycloak.clientSecret`
  — must match each other (they do by default), but the value
  itself is internal.
- The `change-me-please` n8n DB credentials — same.

`reset-helm.sh` runs a preflight check on `~/graphwise-secrets.yaml`
when GraphRAG is being installed (i.e., not `--skip-graphrag`) and
warns if any of the three operator-fillable values still look like
placeholders. If you see that warning and proceed anyway, the
chatbot returns `AccessDeniedException` on every prompt (no
Bedrock creds) and n8n refuses to start (invalid license).

For an umbrella-only deploy (`reset-helm.sh --skip-graphrag`),
the placeholders are fine — GraphRAG isn't installed.

### 7.5 Pre-flight check (before reset-helm)

```bash
# On EC2
./scripts/preflight-reset-helm.sh
```

Read-only sanity check across every precondition `reset-helm.sh`
needs: tools available, cluster reachable, operator pods Ready,
`letsencrypt-prod` ClusterIssuer Ready, `poolparty-realm.json`
present + placeholders substituted, license files on disk,
`~/graphwise-secrets.yaml` field completeness, DNS apex + wildcard
resolution, AWS instance role bound (required for cert-manager's
Route53 DNS-01 solver), maven.ontotext.com HTTP basic auth probe
(catches credential typos before ImagePullBackOff), and whether
`~/wildcard-tls-saved.yaml` is present (saves an LE rate-limit
slot if so).

Categorized color-coded output. Exit code `0` = all required checks
pass; `1` = one or more failed; `2` = cluster unreachable (early
abort — skips remaining checks since they would all fail too).

Flags:

- `--skip-graphrag` — skip the maven auth probe + the
  `graphrag-secrets` completeness checks. Use when running
  `reset-helm.sh --skip-graphrag` for an umbrella-only deploy.
- `--strict` — promote warnings to failures. Warnings are
  informational by default (e.g. "no `wildcard-tls-saved.yaml`,
  cluster-bootstrap will issue a fresh LE cert"). In `--strict`
  mode every warning counts as a failure for the exit code.

If anything fails, the per-check output includes a one-line
remediation hint pointing at the exact script or file to fix. Re-run
preflight after the fix; it's idempotent.

### 8. Deploy the stack

**Full deploy** (umbrella + GraphRAG, requires Maven creds + n8n license):

```bash
# On EC2
./scripts/reset-helm.sh --yes <your-subdomain>
```

**Umbrella-only deploy** (skip GraphRAG, useful when you don't yet have
Maven creds / n8n license, or when you only need PoolParty / GraphDB /
addons for testing):

```bash
# On EC2
./scripts/reset-helm.sh --yes --skip-graphrag <your-subdomain>
```

The `--skip-graphrag` flag tells `reset-helm.sh` to:
- skip rendering the graphrag values overlay
- skip `helm dependency update` on the vendored graphrag chart
- skip the `helm upgrade --install graphrag` step

Everything umbrella-side runs identically (PoolParty, GraphDB ×2,
Elasticsearch, addons, Keycloak, console, observability). The n8n
Postgres + supporting Secrets/ConfigMap that the umbrella creates in
the `graphrag` namespace are still rendered — they're cheap and let
you flip the flag later without a values change.

To later add GraphRAG once you have credentials: drop the flag and
re-run (`./scripts/reset-helm.sh --yes <subdomain>`). The umbrella's
existing release is upgraded in place; the graphrag release is
installed fresh.

`reset-helm.sh` (with or without `--skip-graphrag`):
- regenerates per-subdomain values overlay at `/tmp/values-<sub>.yaml`
  (and `/tmp/values-<sub>-graphrag.yaml` unless `--skip-graphrag`),
- runs `helm dependency update` on the umbrella chart path (and on
  `charts/vendor/graphrag` unless `--skip-graphrag`),
- installs the **`graphwise-stack`** umbrella release in `graphwise` ns
  (PoolParty, GraphDB ×2, addons, Keycloak, console, supporting
  graphrag Secrets/Postgres),
- installs the **`graphrag`** release in `graphrag` ns (chatbot,
  conversation, components, workflows pods) **unless** `--skip-graphrag`,
- runs the post-install Job that creates the master-realm
  `poolparty_auth_admin` user the PoolParty chart expects,
- runs the post-install Job that re-imports per-client Authorization
  Services config (the operator-managed RealmImport CR drops it).

First install takes ~10–15 minutes for the full deploy, ~7–10 minutes
for `--skip-graphrag` (no GraphRAG image pulls, no n8n boot wait).
Watch progress in another shell:

```bash
# On EC2 (in another SSH session)
kubectl get pods -A -w
```

### 9. Verify

```bash
# On EC2
./scripts/validate-stack.sh
```

One-shot post-reset-helm validator. Clears the screen and walks
helm releases (umbrella + graphrag), every workload pod across
graphwise / keycloak / graphrag namespaces, license + image-pull
secrets, the GraphDB rename (catches alias-collision regression),
staging-data PVCs, the keycloak post-install Jobs (bootstrap-admin
+ authz-import), every cert-manager Certificate, OIDC issuer match
for all three realms (the historic stack-breaker), and an HTTPS
reachability sweep against every app URL with per-app expected
status codes (e.g. UnifiedViews legitimately 404s at `/` since it
serves at `/UnifiedViews/`).

Color-coded ✓/✗/⚠ per check, total counts, exit 0 (green) or 1
(any failure). Closing "Where to click next" panel prints the
apex URL + key login endpoints with credentials so you know where
to go after the validator passes.

Read-only against the cluster; safe to re-run any time. If a check
fails, paste the failing line + the hint command's output for
diagnosis. Detailed troubleshooting in
[CONSOLE-GUIDE.md](CONSOLE-GUIDE.md) → "If something breaks".

### 10. Optional — Activate PoolParty "Build Your Taxonomy"

The chart wires PoolParty 10.2's pluggable LLM backend at deploy time
(default: AWS Bedrock + Claude Sonnet 4.5, `us-west-2`; configurable
via `poolparty.llm.*` in `charts/poolparty/values.yaml`). The
backend wiring sets the `POOLPARTY_LLM_*` env vars on the pod and
mounts AWS creds from the `poolparty-aws-credentials` Secret (which
the umbrella's `templates/poolparty-aws-credentials.yaml` materializes
from the same `graphrag-secrets.awsCredentials` overlay block that
feeds the GraphRAG components pod). But the feature is gated by an
SMC instance you have to create after deploy.

Sanity-check the backend:

```bash
kubectl -n graphwise exec deploy/graphwise-stack-poolparty -- env | grep -E '^POOLPARTY_LLM|^AWS_'
```

Should show `POOLPARTY_LLM_API=bedrock`,
`POOLPARTY_LLM_MODEL=anthropic.claude-sonnet-4-5-20250929-v1:0`,
`POOLPARTY_LLM_BEDROCK_REGION=us-west-2`, plus the AWS_* triple.

Then activate the SMC Taxonomy Advisor instance (one-time):

1. Request the Taxonomy Advisor API key from your Graphwise contact
   (this key authenticates the feature instance; it is separate from
   the AWS Bedrock credentials, which only authorize the model
   invocation).
2. Log in to PoolParty at `https://poolparty.<sub>.<base>/PoolParty/`
   as `superadmin` / `poolparty`, switch to SMC view.
3. Expand **External Services** → double-click **Taxonomy Advisor**.
4. **Name** = any label (e.g. `bedrock-claude-sonnet-4-5`),
   **API Key** = the key Graphwise sent → **Save**.

A sub-node appears under Taxonomy Advisor confirming the instance is
active. "Build Your Taxonomy" now works in the taxonomy editor.

Troubleshooting + the full credentials/IAM context lives in
[CONSOLE-GUIDE → PoolParty Thesaurus → Build Your Taxonomy](CONSOLE-GUIDE.md#build-your-taxonomy-llm-assisted-optional).

---

## Day-2 lifecycle

```bash
# Politely quiesce app workloads before stopping the EC2 (optional;
# Postgres/GraphDB/ES handle hard stop fine via WAL recovery).
# Prints the AWS CLI command to stop the EC2 itself afterwards.
./scripts/cluster-stop.sh

# After EC2 stop/start, restart the KIND cluster
./scripts/cluster-resume.sh

# Wipe and reinstall both releases (DATA LOSS — every PVC deleted)
./scripts/reset-helm.sh --yes <subdomain>

# Non-destructive upgrade after chart edits — both releases
helm upgrade graphwise-stack ./charts/graphwise-stack -n graphwise \
    -f charts/graphwise-stack/values.yaml -f /tmp/values-<sub>.yaml \
    --timeout 15m
helm upgrade graphrag ./charts/vendor/graphrag -n graphrag \
    -f charts/vendor/graphrag/values-graphwise.yaml \
    -f /tmp/values-<sub>-graphrag.yaml --timeout 15m
```

`cluster-resume.sh` sets `--restart=unless-stopped` on the KIND node
containers, so subsequent reboots are a non-event.

### Overnight shutdown to save cost

Stopping the EC2 between work sessions cuts the bill by ~2/3 (compute
goes from ~$0.34/hr to $0; ~$30/mo for retained EBS + EIP keeps DNS
and data alive across stops).

```bash
# Polite path:
./scripts/cluster-stop.sh                        # quiesces workloads, prints stop command
aws ec2 stop-instances --instance-ids <id>       # run from your laptop after SSH session closes

# Hard-stop path (fine for this stack -- apps recover via WAL):
aws ec2 stop-instances --instance-ids <id>       # from your laptop
```

To bring it back:

```bash
aws ec2 start-instances --instance-ids <id>      # from your laptop
ssh -i $GRAPHWISE_KEY $GRAPHWISE_USER@$GRAPHWISE_HOST    # wait ~60s for boot
./scripts/cluster-resume.sh                      # restart KIND node containers
# If you scaled workloads to 0 with cluster-stop.sh, re-run the
# helm upgrade commands above to restore the chart's declared
# replica counts.
```

---

## Architecture

### Two Helm releases

`graphwise-stack` (umbrella in `graphwise` ns) owns the supporting
Secrets and the n8n Postgres in `graphrag` ns; `graphrag` (vendored,
in `graphrag` ns) owns the chatbot/conversation/components/workflows
pods that mount those Secrets. Pods can only mount Secrets from their
own namespace, which is why graphrag isn't a sub-dependency of the
umbrella — installing it as a separate release lands its pods in
`graphrag` where the supporting state already lives.

Order matters:
- **Install**: umbrella first, then graphrag. The umbrella creates
  the supporting Secrets/Postgres before graphrag's pods try to
  mount them.
- **Uninstall**: graphrag first, then umbrella. Stops the pods
  holding mounts before removing what they mount.

`scripts/reset-helm.sh` enforces both orderings.

### Subdomain-per-app routing

ingress-nginx is the single public entrypoint (host ports 80 and 443
are mapped from the host into the KIND control-plane container by
[infra/kind/kind-config.yaml](infra/kind/kind-config.yaml)). Each
app's Ingress carries its own host + LE cert; cert-manager issues
the wildcard cert via DNS-01 against Route 53.

The wildcard A-record (`*.<sub>.<base>`) is required so every
per-app subdomain resolves to the same EIP without a per-app DNS
change.

### TLS

cert-manager + Let's Encrypt prod ClusterIssuer. Each Ingress with a
`tls.hosts`/`tls.secretName` block gets a Certificate object, which
cert-manager issues the wildcard cert via DNS-01 against Route 53. No
manual certbot, no in-repo `letsencrypt/` state directory, no
nginx-reload deploy hooks.

The one footgun this format hits: the Keycloak operator (v26.x)
auto-generates an Ingress *without* a `tls:` block when
`http.httpEnabled: true` (which we need so it speaks plain HTTP to
ingress-nginx). cert-manager's ingress-shim won't mint a cert without
that block, so the operator's auto-Ingress is disabled and the
chart ships its own at
[charts/graphwise-stack/templates/keycloak-ingress.yaml](charts/graphwise-stack/templates/keycloak-ingress.yaml).
See [CLAUDE.md](CLAUDE.md) §"Keycloak Ingress lesson" for the
debugging story.

### Secrets / external dependencies

Operator-supplied secrets all live in `~/graphwise-secrets.yaml` on
the EC2 host (gitignored, never tracked; reset-helm.sh auto-includes
it via `-f`):

- **AWS Bedrock** for graphrag-components embedding calls —
  `graphrag-secrets.awsCredentials.{region,accessKeyId,secretAccessKey}`.
- **n8n license** — `graphrag-secrets.n8nLicense.activationKey`.
  Without a real key, the workflows pod won't start cleanly.
- **n8n encryption key** — auto-generated by Terraform on first
  apply, written to the same file. Stays constant across re-applies;
  regenerates only on `terraform destroy` + re-apply (which also
  wipes the n8n DB, so a fresh key is fine). Don't edit by hand.

The chart's `charts/graphwise-stack/values.yaml` ships only empty
placeholders for these — the overlay file's values merge over them
at install time. Editing the chart values directly would create
git-pull merge conflicts; the overlay pattern keeps pulls clean.

Postgres passwords (`change-me-*`) are internal to the cluster and
fine to leave at defaults for a demo.

---

## Troubleshooting

See [CONSOLE-GUIDE.md §If something breaks](CONSOLE-GUIDE.md#if-something-breaks-helm-path)
for the runbook. Common starting points:

```bash
# What's not Ready yet?
kubectl get pods -A | grep -vE 'Running|Completed'

# Cert-manager status
kubectl get certificate -A
kubectl describe certificate -A | grep -A3 'Status:|Message:'

# Keycloak issuer match (the #1 cause of OIDC errors)
curl -s https://auth.<sub>.<base>/realms/master/.well-known/openid-configuration | jq -r .issuer
# Must read exactly: https://auth.<sub>.<base>/realms/master
```

---

## Repository layout

```
├── charts/                          # Helm charts
│   ├── graphwise-stack/             # Umbrella (PoolParty, GraphDB ×2, addons, console, Keycloak)
│   ├── poolparty/, graphdb/, addons/, console/, poolparty-elasticsearch/, keycloak-realms/
│   └── vendor/graphrag*/            # Vendored GraphRAG charts
├── infra/
│   ├── kind/kind-config.yaml        # Single-node KIND cluster definition
│   ├── terraform/                   # AWS module (EC2, SG, EIP, cloud-init)
│   └── README.md                    # Terraform module reference
├── scripts/
│   ├── cluster-bootstrap.sh         # One-time install of cluster operators + observability
│   ├── cluster-resume.sh            # Restart KIND nodes after EC2 stop/start
│   ├── cluster-stop.sh              # Quiesce app workloads before EC2 stop
│   ├── render-values.sh             # Generate per-subdomain values overlays
│   ├── reset-helm.sh                # Wipe + reinstall both Helm releases
│   ├── install-licenses.sh          # Load license files as K8s Secrets
│   ├── extract-poolparty-realm.sh   # Pull realm JSON from poolparty-keycloak image
│   ├── validate-bootstrap.sh        # Post-cluster-bootstrap health check
│   ├── validate-stack.sh            # Post-reset-helm health check
│   └── laptop/                      # Laptop-side helpers
│       ├── pull-config.sh           # Pull operator state (secrets + licenses + LE cert) into ~/Downloads/graphwise-config-<UTC>/
│       ├── push-config.sh           # Push operator state back to a fresh EC2
│       ├── pushLastPull.sh          # Convenience wrapper: push the most recent pull-config snapshot
│       ├── push-to-ec2.sh           # (legacy) rsync local edits to the EC2 host
│       └── pull-from-ec2.sh         # (legacy) rsync EC2-side edits back to laptop
├── files/licenses/                  # Vendor license files (gitignored)
├── README.md                        # One-page summary + zero-to-deployed checklist
├── DEPLOY.md                        # This file (full walkthrough)
├── SETUP.md                         # Laptop-zero prerequisites (macOS + Windows)
├── CLAUDE.md                        # Background, invariants, debugging story
└── CONSOLE-GUIDE.md                    # URLs, credentials, runbooks
```

---

## Companion docs

- [README.md](README.md) — one-page summary + zero-to-deployed
  checklist. Read first if you just want the quick orientation.
- [SETUP.md](SETUP.md) — laptop-zero prerequisites guide (macOS +
  Windows): terminal, Homebrew/Chocolatey, AWS CLI, Bedrock IAM,
  Terraform, EC2 key pair, DNS plan, Graphwise creds + licenses.
- [CLAUDE.md](CLAUDE.md) — architecture deep dive, Keycloak hostname
  rule, OIDC issuer-match invariant, two-release model rationale,
  open issues.
- [CONSOLE-GUIDE.md](CONSOLE-GUIDE.md) — every URL, credential, lifecycle
  command, and troubleshooting flow.
- [infra/README.md](infra/README.md) — Terraform module: variables,
  outputs, post-apply runbook, teardown.
