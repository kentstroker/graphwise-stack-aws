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

See [CHEATSHEET.md](CHEATSHEET.md) for the full URL + credentials table.

---

## Prerequisites

Detailed, OS-specific walk-through is in **[SETUP.md](SETUP.md)** —
laptop-zero through ready-for-`terraform-apply`. At a glance:

- AWS account + IAM user with `AmazonEC2FullAccess` (don't use root).
- AWS Bedrock available in your region (no per-model approval needed
  — AWS grants foundation-model access by default; the
  `cohere.embed-english-v3` model the components pod uses is
  reachable as long as Bedrock is offered there). A least-privilege
  IAM user (`graphrag-bedrock`) carries the runtime
  `bedrock:InvokeModel` permission.
- Terraform 1.5+ and AWS CLI v2 installed and authenticated.
- EC2 key pair downloaded and `chmod 400`'d.
- A subdomain plan (`<sub>.<base>` apex + `*.<sub>.<base>` wildcard
  records) on a domain you control. Graphwise SEs use Kent's
  `semantic-proof.com` zone; everyone else uses their own DNS
  provider (GoDaddy / Route53 / Cloudflare / Namecheap — all fine).
- Graphwise Maven registry credentials and three license files
  (PoolParty, GraphDB, UnifiedViews) — request from Graphwise.

The EC2 instance side (Debian 13 ARM64, rootless podman, KIND,
kubectl, helm) is handled by the Terraform module's cloud-init;
nothing to install there.

---

## Deploy from zero

### 1. Provision the EC2 instance

```bash
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
| `named_user` | `graphwise` | You want `ssh kent@<eip>` instead of `ssh graphwise@<eip>`. Cosmetic. |
| `github_repo_url` | upstream | You've forked the repo and want cloud-init to clone your fork. |
| `instance_name_prefix` | `graphwise-stack` | You want a different prefix for cost-allocation tags. Final Name tag is `<prefix>-<subdomain>`. |
| `existing_eip_allocation_id` | `""` (allocate fresh) | Set this **after** allocating an EIP outside Terraform (Console or `aws ec2 allocate-address`) to make the EIP survive `terraform destroy`/`apply` cycles. Otherwise every rebuild gets a new EIP and you have to update DNS again. Allocation ID format: `eipalloc-0123456789abcdef0`. |
| `extra_tags` | `{}` | Your org needs Owner / Customer / CostCenter tags on AWS resources. Merged with the module's own `Name` / `Subdomain` / `ManagedBy` tags. |

After saving `terraform.tfvars`:

```bash
terraform init       # one-time; downloads the AWS provider plugin
terraform plan       # dry-run; you should see 3 resources to add: SG, EC2, EIP
terraform apply
```

Output includes the EIP, an `ssh_named_user` line, and the
`godaddy_dns_records` block (the two A-records to add). The
cloud-init script takes 2–3 minutes after `apply` returns; tail it
with:

```bash
ssh -i <key.pem> admin@<eip> 'sudo tail -f /var/log/bootstrap.log'
```

Wait for `=== Bootstrap complete at <timestamp> ===`. The cluster is
already up at that point — `kind get clusters` shows `graphwise`.

See [infra/README.md](infra/README.md) for the full Terraform module
reference, including the post-apply runbook and teardown.

### 2. Email Kent for the DNS records

Two records, both pointing at the EIP:

> - **A record:** `<sub>.semantic-proof.com` → EIP, TTL 5 min
> - **A record:** `*.<sub>.semantic-proof.com` → EIP, TTL 5 min

Wait for propagation — usually under 5 minutes:

```bash
dig +short <sub>.semantic-proof.com poolparty.<sub>.semantic-proof.com
```

Both should return your EIP. Without the wildcard, every per-app
subdomain (poolparty, auth, graphrag, …) returns NXDOMAIN and
nothing works.

### 3. SSH in and prepare creds

```bash
ssh -i <key.pem> graphwise@<eip>
cd ~/graphwise-stack-aws

# Maven registry creds for the GraphRAG images
mkdir -p ~/.ontotext
echo '<maven-username>' > ~/.ontotext/maven-user
echo '<maven-password>' > ~/.ontotext/maven-pass
chmod 600 ~/.ontotext/*

# Drop Graphwise license files (scp from your laptop)
mkdir -p files/licenses
# scp: poolparty.key, graphdb.license, uv-license.key
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

### 4. Install cluster operators

One-time install of ingress-nginx, cert-manager (+ Let's Encrypt
ClusterIssuer), CloudNativePG, Keycloak operator, metrics-server.
Also creates the `graphwise` image-pull secret in the `graphwise` and
`graphrag` namespaces.

```bash
export LE_EMAIL=you@example.com
./scripts/cluster-bootstrap.sh
```

Idempotent — safe to re-run.

### 5. Install the realm-import JSON for PoolParty

```bash
./scripts/extract-poolparty-realm.sh
```

Pulls the realm export out of `ontotext/poolparty-keycloak:latest`
and drops it where the Helm chart expects it. Re-run if you bump the
image tag.

### 6. Install the license Secrets

```bash
./scripts/install-licenses.sh
```

Reads `files/licenses/*` and creates the three K8s Secrets the chart
templates mount.

### 7. Configure GraphRAG runtime credentials

The umbrella chart's `values.yaml` ships placeholder strings for
the secrets that have to be unique per deployment. Edit
`charts/graphwise-stack/values.yaml` **on the EC2 host** (not your
laptop — that copy is in git, and your real credentials should never
be committed):

```bash
$EDITOR charts/graphwise-stack/values.yaml
```

Find the `graphrag-secrets:` block and replace the placeholders:

```yaml
graphrag-secrets:
  # ... other keys unchanged ...

  # AWS Bedrock credentials for the graphrag-components pod.
  # Use the access key from the graphrag-bedrock IAM user you
  # created in SETUP.md §6. The region must match the region the
  # IAM policy ARN was scoped to.
  awsCredentials:
    region: "us-west-2"
    accessKeyId: "AKIA<your access key id>"
    secretAccessKey: "<your secret access key>"

  # n8n Enterprise license activation key.
  n8nLicense:
    activationKey: "<your-n8n-license-key>"
```

> **The n8n encryption key is auto-generated** by Terraform's
> cloud-init (`openssl rand -hex 24` equivalent) and dropped at
> `~/graphwise-secrets.yaml` on the EC2 host. `reset-helm.sh`
> auto-includes that file as an extra `-f` overlay if present, so
> you don't need to touch `n8nEncryption.key` here. The Terraform
> state keeps the value stable across re-applies; it only
> regenerates if you `terraform destroy` and re-apply (which also
> wipes the n8n DB, so the new key is fine).

Things that can stay at their shipped values for a demo:

- The `change-me-*` Postgres passwords — internal to the cluster,
  not user-facing.
- `graphragConversationClientSecret` / `conversationKeycloak.clientSecret`
  — must match each other (they do by default), but the value
  itself is internal.
- The `change-me-please` n8n DB credentials — same.

If you forget this step, the install still succeeds, but: the
chatbot returns `AccessDeniedException` on every prompt (no Bedrock
creds), n8n refuses to start (invalid license), and stored n8n
credentials get re-encrypted with whatever placeholder key was in
place last time.

> **Why edit the file directly instead of an overlay?** The umbrella
> chart treats `graphrag-secrets` as a top-level chart-managed
> section, not a subchart with its own values. The simplest path
> is to edit the values file on the EC2 working copy, where it's
> never pushed back to git. If you'd rather pass an overlay, write
> a third file (e.g. `~/graphwise-secrets.yaml`) with the same
> structure and add it to the `helm upgrade` calls — see "Day-2
> lifecycle" below for the full command pattern.

### 8. Deploy the stack

```bash
./scripts/reset-helm.sh --yes <your-subdomain>
```

This:
- regenerates per-subdomain values overlays at `/tmp/values-<sub>.yaml`
  and `/tmp/values-<sub>-graphrag.yaml`,
- runs `helm dependency update` on both chart paths,
- installs the **`graphwise-stack`** umbrella release in `graphwise` ns
  (PoolParty, GraphDB, addons, Keycloak, console, supporting graphrag
  Secrets/Postgres),
- installs the **`graphrag`** release in `graphrag` ns (chatbot,
  conversation, components, workflows pods),
- runs the post-install Job that creates the master-realm
  `poolparty_auth_admin` user the PoolParty chart expects.

First install takes ~10–15 minutes (image pulls, Keycloak realm
imports, Spring init, Lucene index warmup, LE cert issuance). Watch
progress in another shell:

```bash
kubectl get pods -A -w
```

### 9. Verify

```bash
APEX=<your-subdomain>.semantic-proof.com
for h in $APEX poolparty.$APEX auth.$APEX graphdb.$APEX graphrag.$APEX; do
  printf '%-50s ' "$h"
  curl -s -o /dev/null -w 'http=%{http_code}\n' "https://$h/" --max-time 10
done
```

In a browser:
- **`https://poolparty.<sub>.semantic-proof.com/PoolParty/`** —
  PoolParty Thesaurus, login `superadmin / poolparty`.
- **`https://<sub>.semantic-proof.com/`** — Console landing page with
  links to every app.

---

## Day-2 lifecycle

```bash
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
each cert via HTTP-01 against ingress-nginx.

The wildcard A-record (`*.<sub>.<base>`) is required so every
per-app subdomain resolves to the same EIP without a per-app DNS
change.

### TLS

cert-manager + Let's Encrypt prod ClusterIssuer. Each Ingress with a
`tls.hosts`/`tls.secretName` block gets a Certificate object, which
cert-manager issues via HTTP-01 challenge through ingress-nginx. No
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

Several values ship as placeholders that you may need to fill in for
your demo:

- **AWS Bedrock** for graphrag-components embedding calls —
  `graphrag-secrets.awsCredentials.{accessKeyId,secretAccessKey}` in
  `charts/graphwise-stack/values.yaml`.
- **n8n license** — `graphrag-secrets.n8nLicense.activationKey`.
  Without a real key, the workflows pod won't start cleanly.
- **n8n encryption key** — auto-generated by Terraform on first
  apply, written to `~/graphwise-secrets.yaml` on the EC2 host,
  picked up by `reset-helm.sh` automatically. Stays constant across
  re-applies; regenerates only on `terraform destroy` + re-apply
  (which also wipes the n8n DB, so a fresh key is fine).

Postgres passwords (`change-me-*`) are internal to the cluster and
fine to leave at defaults for a demo.

---

## Troubleshooting

See [CHEATSHEET.md §If something breaks](CHEATSHEET.md#if-something-breaks-helm-path)
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
│   ├── cluster-bootstrap.sh         # One-time install of cluster operators
│   ├── cluster-resume.sh            # Restart KIND nodes after EC2 stop/start
│   ├── render-values.sh             # Generate per-subdomain values overlays
│   ├── reset-helm.sh                # Wipe + reinstall both Helm releases
│   ├── install-licenses.sh          # Load license files as K8s Secrets
│   └── extract-poolparty-realm.sh   # Pull realm JSON from poolparty-keycloak image
├── files/licenses/                  # Vendor license files (gitignored)
├── README.md                        # One-page summary + zero-to-deployed checklist
├── DEPLOY.md                        # This file (full walkthrough)
├── SETUP.md                         # Laptop-zero prerequisites (macOS + Windows)
├── CLAUDE.md                        # Background, invariants, debugging story
└── CHEATSHEET.md                    # URLs, credentials, runbooks
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
- [CHEATSHEET.md](CHEATSHEET.md) — every URL, credential, lifecycle
  command, and troubleshooting flow.
- [infra/README.md](infra/README.md) — Terraform module: variables,
  outputs, post-apply runbook, teardown.
