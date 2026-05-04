# CLAUDE.md

**Maintainer:** Kent Stroker

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A **Helm-on-KIND** deployment of the Ontotext / Graphwise **PoolParty** ecosystem plus the **GraphRAG** chatbot suite, on a single **AWS EC2** instance (Amazon Linux 2023, Docker, single-node KIND cluster). All ingress is HTTPS via ingress-nginx + cert-manager + Let's Encrypt. It is explicitly a **demo / evaluation** deployment — not production-ready — see the warning block in [DEPLOY.md](DEPLOY.md) for the full list of what would need to change for production use.

**OS history:** previously deployed on Debian 13 with rootless podman. Migrated to AL2023 + Docker in late 2026 after consistent "ssh fails immediately after scp" failures on Debian 13 + AWS Nitro that nobody could explain; AL2023 doesn't trigger the issue. KIND on Docker is also better-supported (KIND-on-podman is still `KIND_EXPERIMENTAL_PROVIDER`).


**Audience and licensing.** This repo is primarily for **internal use by Graphwise field presales engineers**. It is public (MIT-licensed, AS-IS, no warranty, no support — see [LICENSE](LICENSE)) so that customers, partners, and the semantic-web community can reference it when building their own evaluation environments. External users must supply their own Graphwise license files (PoolParty/GraphDB EE/UnifiedViews — obtained by contacting Graphwise), their own AWS account, and their own domain. The repo ships zero license files and no access to Graphwise's shared presales domain `semantic-proof.com`.

No application source code is in this repo. Only:

- `infra/kind/kind-config.yaml` — single-node KIND cluster definition
- `infra/terraform/` — provisions an EC2 host pre-loaded with kind/kubectl/helm and a running cluster
- `charts/graphwise-stack/` — umbrella Helm chart (PoolParty + GraphDB ×2 + addons + console + Keycloak + supporting graphrag Secrets/Postgres)
- `charts/{poolparty,graphdb,addons,console,poolparty-elasticsearch,keycloak-realms}/` — per-app sub-charts
- `charts/vendor/graphrag*/` — vendored GraphRAG charts (chatbot, conversation, components, workflows) — installed as a separate Helm release
- Helper scripts under `scripts/`: `cluster-bootstrap.sh`, `cluster-resume.sh`, `cluster-stop.sh`, `reset-helm.sh`, `render-values.sh`, `install-licenses.sh`, `extract-poolparty-realm.sh`, `validate-bootstrap.sh`, `validate-stack.sh`, `switch-cert-issuer.sh`
- Laptop-side helpers under `scripts/laptop/`: `push-to-ec2.sh`, `pull-from-ec2.sh`
- Vendor license files under `files/licenses/` (gitignored)

Changes are usually to a chart's `values.yaml` / `templates/`, the umbrella's `templates/`, or `scripts/render-values.sh`.

Companion docs: [README.md](README.md) (one-page summary + zero-to-deployed checklist), [QUICKSTART.md](QUICKSTART.md) (sequential 0-18 step deploy for experienced operators), [SETUP.md](SETUP.md) (laptop-zero prerequisites), [DEPLOY.md](DEPLOY.md) (end-to-end deploy walkthrough), [HOWITWORKS.md](HOWITWORKS.md) (plain-English layered architecture explainer for K8s-naive operators), [CONSOLE-GUIDE.md](CONSOLE-GUIDE.md) (URLs / credentials), [infra/README.md](infra/README.md) (Terraform module).

## Architecture

### Two Helm releases

The Helm path runs as **two separate releases**, not one umbrella:

1. **`graphwise-stack`** in the `graphwise` namespace — PoolParty, GraphDB (×2), Elasticsearch, console, addons (ADF/Semantic Workbench/GraphViews/RDF4J/UnifiedViews), Keycloak CR + operator-managed Postgres + realm imports, **plus** the Secrets and ConfigMap and the n8n CNPG Postgres that the GraphRAG pods need (these are created in the `graphrag` namespace by the umbrella's own templates so the GraphRAG pods can mount them).
2. **`graphrag`** in the `graphrag` namespace — vendored chatbot/conversation/components/workflows pods. Installed from `charts/vendor/graphrag/` directly, not as a sub-dependency of the umbrella.

Why split: the vendored GraphRAG sub-charts don't set `metadata.namespace` on their resources, so they default to the Helm release namespace. If we kept GraphRAG as a dep of the umbrella (release ns = `graphwise`), the chatbot/conversation/components/workflows pods would land in `graphwise` and couldn't mount the supporting Secrets that need to live in `graphrag` (pods can only mount Secrets from their own namespace, and bare-name Service references resolve in-namespace too — `graphrag-postgres-n8n-rw` from a pod in `graphwise` would fail). Installing GraphRAG as its own release in `graphrag` is the cleanest fix; alternatives (forking vendor templates, or moving every supporting Secret into `graphwise`) all bleed worse.

Install/uninstall order matters:
- **Install**: umbrella first (it creates the supporting Secrets and Postgres in `graphrag`), then graphrag (its pods mount them).
- **Uninstall**: graphrag first (so pods stop holding open volume mounts / DB connections), then umbrella.

`scripts/reset-helm.sh` enforces both orderings.

### Lifecycle scripts

| Script | Purpose |
|---|---|
| `scripts/cluster-bootstrap.sh` | One-time install of cluster operators + observability: ingress-nginx, cert-manager (+ LE `letsencrypt-prod` ClusterIssuer), CNPG, Keycloak operator, metrics-server, **Kubernetes Dashboard** (kubectl apply v2.7.0 + dashboard-admin ServiceAccount + ClusterRoleBinding + permanent `dashboard-admin-token` Secret + auto-generated `~/dashboard-kubeconfig.yaml` for browser sign-in), **kube-prometheus-stack** (Prometheus + Grafana + AlertManager + node-exporter + kube-state-metrics). Provisions per-host Ingresses for the three observability UIs (Dashboard backend-protocol HTTPS; Prometheus basic-auth-gated `demo / rdf#rocks`; Grafana own-login `admin / demo-graphwise-2026`). Also creates the `graphwise` image-pull secret in the `graphwise` and `graphrag` namespaces from `~/.ontotext/maven-{user,pass}`. Idempotent. Required env: `LE_EMAIL`. |
| `scripts/cluster-resume.sh` | Restart the KIND cluster after an EC2 stop/start. Finds the cluster's node containers via the `io.x-k8s.kind.cluster=<name>` label, `docker start`s them, and sets `--restart=unless-stopped` so subsequent reboots are a non-event. Polls `/readyz` until the API answers. |
| `scripts/cluster-stop.sh` | Politely quiesce the application workloads (graphwise + graphrag namespaces) before stopping the EC2. Scales every Deployment + StatefulSet to 0 replicas, waits up to 90s for pods to drain, then prints the AWS CLI / Console commands to stop the EC2. Idempotent. Operator namespaces are left running -- they tolerate hard stop. PVCs and Secrets all preserved. Optional polish over a hard EC2 stop, which apps tolerate via WAL recovery anyway. |
| `scripts/render-values.sh [--umbrella\|--graphrag\|--both] <subdomain> [base_domain]` | Emits Helm values overlays. **Auto-invoked by `reset-helm.sh`** before each `helm upgrade --install` — the standard deploy flow does not call it manually. Default (`--both`) writes two files — `/tmp/values-<sub>.yaml` (umbrella) and `/tmp/values-<sub>-graphrag.yaml` (graphrag). `--umbrella`/`--graphrag` emit just one to stdout. Computes every per-app hostname (`poolparty.<sub>.<base>`, `auth.<sub>.<base>`, `graphrag.<sub>.<base>`, `graphdb.<sub>.<base>`, `graphdb-projects.<sub>.<base>`, `adf.<sub>.<base>`, `semantic-workbench.<sub>.<base>`, `graphviews.<sub>.<base>`, `rdf4j.<sub>.<base>`, `unifiedviews.<sub>.<base>`; console at apex `<sub>.<base>`). Run manually only to inspect the rendered overlay or feed it into a non-destructive `helm upgrade`. |
| `scripts/install-licenses.sh` | kubectl-creates the three license Secrets (`poolparty-license`, `graphdb-license`, `unifiedviews-license`) in the `graphwise` namespace from `files/licenses/*`. Idempotent. |
| `scripts/validate-bootstrap.sh` | One-shot post-cluster-bootstrap health check. Read-only; clears screen and walks every operator namespace (cert-manager, ingress-nginx, cnpg-system, monitoring, kubernetes-dashboard, keycloak operator, kube-system metrics-server), the `letsencrypt-prod` ClusterIssuer, the `~/dashboard-kubeconfig.yaml` artifact, and a cluster-wide non-Running-pod sweep. Prints color-coded pass/fail per check + an overall verdict. Exit 0 on green, 1 on any failure (so it can gate automation). Run any time after `cluster-bootstrap.sh`. Image-pull secret check is intentionally NOT here -- that secret is created by `reset-helm.sh`, not bootstrap; checked in `validate-stack.sh` instead. |
| `scripts/switch-cert-issuer.sh <staging\|prod> [--yes]` | Flip every Ingress cluster-wide between `letsencrypt-staging` and `letsencrypt-prod`. Patches the `cert-manager.io/cluster-issuer` annotation on every Ingress, deletes existing Certificate resources + TLS Secrets so cert-manager re-issues with the new issuer, polls until all certs Ready (10-min timeout). Use `staging` for SE-internal stack iteration (rate-limit-free, browsers warn "Not Secure"); use `prod` right before a customer demo (real browser-trusted certs, but 5/identifier/168h LE rate limit). Aborts if the target ClusterIssuer doesn't exist or isn't Ready. Exit 0 on success, 1 on cert-issuance timeout, 2 on usage error. |
| `scripts/validate-stack.sh` | One-shot post-`reset-helm.sh` health check. Read-only; clears screen and walks the helm releases (umbrella + optional graphrag), every workload pod across `graphwise` / `keycloak` / `graphrag` namespaces, the three license Secrets, the `graphwise` image-pull secret in both consuming namespaces, the GraphDB rename (catches alias-collision regression), `staging-data` PVCs in both namespaces, the two Keycloak post-install Jobs (`keycloak-bootstrap-admin` + `keycloak-authz-import`), every cert-manager Certificate, OIDC issuer match for `master` / `poolparty` / `graphrag` realms (the historic stack-breaker), and an HTTPS reachability sweep against every app URL with per-app expected status codes. Closes with a "Where to click next" panel listing key login URLs + credentials. Reads `GRAPHWISE_APEX` env var (set by cloud-init); falls back to deriving from Ingresses. Exit 0 on green, 1 on any failure. |
| `scripts/reset-helm.sh [--yes] [--skip-graphrag] <subdomain> [base_domain]` | Wipe and reinstall the umbrella (and graphrag unless skipped). Pre-flight: checks the three license Secrets (`poolparty-license`, `graphdb-license`, `unifiedviews-license`) exist in `graphwise` ns; if missing, fails fast with a hint to run `install-licenses.sh` first. Then uninstalls graphrag first (if present) then umbrella, deletes all PVCs in `graphwise` / `keycloak` / `graphrag`, re-renders both values overlays via `render-values.sh`, runs `helm dependency update` on `charts/graphwise-stack` (and on `charts/vendor/graphrag` unless `--skip-graphrag`), then `helm upgrade --install` umbrella, then graphrag (unless skipped), each with `--timeout 15m`. `--yes` skips the destructive-confirmation prompt; `--skip-graphrag` is the umbrella-only path for operators without Maven creds yet (rerun without the flag once they have credentials — umbrella is upgraded in place, graphrag is installed fresh). The arg parser accepts both flags in any position. Subdomain and base-domain are validated against RFC 1123 before anything destructive runs (so e.g. a `--yes` typo can't end up in the base-domain slot). Does **not** touch operators installed by `cluster-bootstrap.sh`. **Side-effect:** re-renders the apex landing page ConfigMap via Helm `tpl` so the console always reflects current values. |

### Subdomain-per-app routing

Each app gets its own subdomain so ingress-nginx can mint a separate LE cert per app and each app's webapp doesn't need a context-path-prefix story:

| App | Hostname |
|---|---|
| Console (landing) | `<sub>.<base>` (apex) |
| Keycloak | `auth.<sub>.<base>` |
| PoolParty | `poolparty.<sub>.<base>` |
| GraphDB embedded | `graphdb.<sub>.<base>` |
| GraphDB projects | `graphdb-projects.<sub>.<base>` |
| ADF | `adf.<sub>.<base>` |
| Semantic Workbench | `semantic-workbench.<sub>.<base>` |
| GraphViews | `graphviews.<sub>.<base>` |
| RDF4J | `rdf4j.<sub>.<base>` |
| UnifiedViews | `unifiedviews.<sub>.<base>` |
| GraphRAG (chatbot + conversation + workflows) | `graphrag.<sub>.<base>` (different paths) |
| Kubernetes Dashboard | `dashboard.<sub>.<base>` |
| Prometheus | `prometheus.<sub>.<base>` |
| Grafana | `grafana.<sub>.<base>` |

DNS needs both `<sub>.<base>` (apex) and `*.<sub>.<base>` (wildcard) A-records to the EIP. The Terraform module's `godaddy_dns_records` output prints both. **EIP must be pre-allocated** outside Terraform and passed via `existing_eip_allocation_id` (see "EIP pre-allocation" section below) so the EIP — and therefore the DNS records — survive `terraform destroy`/`apply` cycles.

### Keycloak hostname rule (the #1 cause of stack breakage)

Spring Security's `NimbusJwtDecoder.withIssuerLocation()` does a **strict equality check** between the URL the OIDC client is handed and the `issuer` field in Keycloak's discovery doc. If they don't match exactly, every webapp's `jwtDecoder` bean throws at boot (`IllegalStateException: The Issuer ... did not match`) and the app is dead until you fix the URL and recreate.

Set on the Keycloak CR at `charts/graphwise-stack/templates/keycloak.yaml`:

```yaml
spec:
  hostname:
    hostname: auth.<sub>.<base>     # NO /auth path
    strict: true
```

Issuer claim becomes `https://auth.<sub>.<base>/realms/<realm>`. Every OIDC client (PoolParty, ADF, Semantic Workbench, graphrag-conversation) must point at exactly this URL. Confirm with:

```bash
curl -s https://auth.<sub>.<base>/realms/master/.well-known/openid-configuration | jq -r .issuer
# Must show: https://auth.<sub>.<base>/realms/master
```

### Keycloak Ingress lesson (the one that bit us)

The Keycloak operator (v26.x) generates an Ingress whose shape is driven by `spec.http.httpEnabled`. With `httpEnabled: true` (our case — TLS terminates at ingress-nginx, the Keycloak pod speaks plain HTTP internally) the operator emits an Ingress with **no `tls:` block**. cert-manager's ingress-shim only mints a Certificate when an Ingress carries a `tls.hosts` + `tls.secretName` pair, so the `cert-manager.io/cluster-issuer` annotation alone produced an HTTP-only Ingress with no LE cert and every `https://auth.<apex>` request from in-cluster clients failed the TLS handshake.

The operator's CR doesn't expose a way to inject `tls:` directly. Fix shipped in this repo:

1. `charts/graphwise-stack/templates/keycloak.yaml` sets `spec.ingress.enabled: false` — operator stops creating its own Ingress.
2. `charts/graphwise-stack/templates/keycloak-ingress.yaml` ships our own Ingress with the TLS block, the cert-manager annotation, and backend `<keycloak-name>-service:8080`.

Don't re-enable the operator-managed Ingress without re-checking that the TLS block lands on the resulting object.

### KIND lifecycle on EC2

KIND nodes are **Docker** containers (we migrated off podman in late 2026 — see the OS-history note in §"What this repo is"). On EC2 stop/start `docker.service` comes back automatically, but containers without a restart policy stay `Exited` — kubectl then fails with `connection refused on 127.0.0.1:6443`. `scripts/cluster-resume.sh` starts them and sets `--restart=unless-stopped` so the next reboot is a non-event. Run it any time after a fresh boot; it's idempotent.

### Mac → EC2 sync during active troubleshooting

While iterating on the Helm charts, edits land on the developer's Mac and get scp'd to the EC2 host. Git is intentionally not in the loop until the changes settle. After every chart/script edit, sync the affected files before `helm upgrade`:

```bash
scp -i $GRAPHWISE_KEY <changed-files> $GRAPHWISE_USER@$GRAPHWISE_HOST:~/graphwise-stack-aws/<paths>/
```

`helm get manifest graphwise-stack -n graphwise` confirms what was actually applied — useful when an expected change isn't taking effect.

### Two-IAM-user actor model (AWS account hygiene)

Two distinct IAM users with different blast radii — never combine into one:

1. **Terraform user** (e.g. `terraform-demo`) with `AmazonEC2FullAccess`. Holds infrastructure-provisioning credentials. Lives only on the operator's laptop. Used by `terraform apply`, `aws configure`'s default profile, `aws ec2-instance-connect ssh`, and every laptop-side AWS CLI invocation.
2. **Bedrock user** (e.g. `graphrag-bedrock`) with a narrow inline policy granting `bedrock:InvokeModel` + `bedrock:InvokeModelWithResponseStream` on `cohere.embed-english-v3` only. Holds runtime credentials baked into a Helm Secret on the EC2 (`graphrag-components-aws-credentials` in `graphrag` ns) and read by the `graphrag-components` pod every embedding call.

**Critical actor rule:** all IAM user/policy/access-key creation in §4 of SETUP.md is performed by the **root user** OR an existing **IAM admin user** (carrying `AdministratorAccess` or `IAMFullAccess`). NEVER by `terraform-demo` itself — `terraform-demo` lacks `iam:*` permissions and attempting to grant itself perms returns `AccessDenied: iam:PutUserPolicy on resource: user terraform-demo`. SETUP §4 opens with an actor table to make this unmistakable; if SSM-style features are added that require additional IAM permissions, those grants are also performed by root/IAM-admin (see SETUP §9 for the EC2 Instance Connect inline-policy attach pattern).

**EC2 Instance Connect special case:** `aws ec2-instance-connect ssh` requires `ec2-instance-connect:SendSSHPublicKey` which is NOT in `AmazonEC2FullAccess`. Operators who use this path attach a small inline policy to `terraform-demo` once (Console-only step, root/IAM-admin performs it). The browser-based "Connect" tab is documented as not working out of the box — its source IP is AWS's service prefix list, blocked by the strict `admin_cidr` SG rule. Manual SG rule add per SETUP §9.

### EIP pre-allocation (required, not optional)

`existing_eip_allocation_id` in `terraform.tfvars` is a **required** field (sits in the REQUIRED block of `terraform.tfvars.example`, not optional). Why: Terraform's default behavior when this is empty is to allocate a fresh EIP each apply AND release it on each `terraform destroy` — so every rebuild gets a different IP and DNS records become stale.

The architecture is: operator allocates the EIP outside Terraform (Console or `aws ec2 allocate-address --domain vpc`), captures the Allocation ID (`eipalloc-...`) AND Public IPv4. The Allocation ID goes in `terraform.tfvars`; the Public IPv4 goes in the two DNS A records (`<sub>.<base>` apex + `*.<sub>.<base>` wildcard). Terraform creates only the `aws_eip_association` (binding the existing EIP to the EC2) — destroy detaches but never releases. EIP + DNS are set-and-forget across destroy/apply cycles.

The Terraform `eip_mode` output reports which path is active (`existing (allocation_id=...)` or `fresh (allocated this apply)`). Walkthrough in SETUP.md §6 (Console + CLI paths to allocate). Lost an entire validated demo deployment to a fresh-EIP rebuild once before promoting this to required; the workflow doesn't recover gracefully when DNS goes stale mid-deployment.

### AMI lock pattern (terraform safety, two layers)

`data "aws_ami" "al2023_arm64"` uses `most_recent = true` because we want fresh deployments to land on the latest AL2023. But every subsequent `terraform plan` re-resolves to a potentially-different AMI ID — and `ami` is a force-replace attribute, so an unscoped `terraform apply` after AWS publishes any AL2023 refresh **destroys the EC2** (root EBS, every PVC) just to "update" the AMI. Lost a fully-validated demo deployment to this exact bug; the rule is now hard-enforced.

Two-layer protection:

1. **Belt — `lifecycle.ignore_changes = [user_data_base64, ami]` on `aws_instance.stack`** (in `infra/terraform/main.tf`). Once provisioned, Terraform never marks the instance for replacement on AMI grounds even if the data-source resolution drifts. Protects every deployment automatically; no operator action required.
2. **Braces — the `ami_override` variable.** After first apply, operator runs `terraform output -raw ami_id` and pastes the resulting `ami-...` into `terraform.tfvars` as `ami_override = "ami-..."`. Re-running `terraform plan` MUST print "No changes." This makes plan output clean (no spurious AMI diffs) and makes intentional AMI upgrades an explicit `terraform.tfvars` edit rather than a side-effect. Documented as DEPLOY.md §1.5 — a required post-first-apply step.

The Safety section in `infra/README.md` is the canonical operator-facing reference. Anything that wants to `terraform apply` after first provision uses scoped `-target=` syntax, and `terraform plan` output is read character-by-character before applying.

### Realm export `${...}` placeholder substitution

Ontotext's `poolparty-keycloak` image ships a realm JSON with literal `${POOLPARTY_*}` env-var-style placeholders the operator-managed `KeycloakRealmImport` CR doesn't substitute. Without intervention, Keycloak imports the literal strings as the `superadmin` password and `ppt` client secret, breaking every PoolParty login.

`scripts/extract-poolparty-realm.sh` jq-substitutes both at extract time as part of producing the realm JSON the chart ships:

- `(.clients[] | select(.clientId == "ppt") | .secret) = "ohIP3x4XuoCsGDsGlZRvNvO5VN6veFb5"` (PoolParty image's baked-in client secret — image-version coupled; revisit if the image is bumped)
- `(.users[] | select(.username == "superadmin") | .credentials[0].value) = "poolparty"` + `temporary = false`

Image-version coupling is documented in the script's comment block. To check for new placeholders in a future image bump: `grep -oE '\${[A-Z_]+}' charts/keycloak-realms/files/poolparty-realm.json | sort -u`.

### Keycloak authz-import post-install Job

The `KeycloakRealmImport` CR ALSO drops the per-client `.authorizationSettings` block (resources/scopes/policies). PoolParty needs this for its UMA permission ticket flow — without it, the conversation login lands but every authorized request returns `Client does not support permissions`.

`charts/keycloak-realms/templates/keycloak-authz-import-job.yaml` is a Helm `post-install,post-upgrade` Job (`hook-weight: 10`, runs after the umbrella's keycloak-bootstrap-admin Job at weight 5) that:

1. Builds a ConfigMap at chart render time iterating over the realm JSON's clients-with-`authorizationSettings` (currently just `ppt`), emitting one `<clientId>.json` key per client.
2. The Job mounts that ConfigMap, gets an admin token via password grant against the master realm using the existing `poolparty-auth-admin` Secret (which the umbrella's bootstrap-admin Job already created), and for each client: fetches the UUID, PUTs the client representation with `authorizationServicesEnabled = true`, POSTs the authz config to `/admin/realms/<realm>/clients/<uuid>/authz/resource-server/import`.

Idempotent, generic across clients (any future client with `authorizationSettings` is auto-handled). Container is `alpine:3.20` + apk-add `bash curl jq` — same pattern as the bootstrap-admin Job.

### GraphDB subchart fullname pattern (alias-aware)

`charts/graphdb/` is installed twice in the umbrella as subchart aliases (`graphdb-embedded`, `graphdb-projects`) to give two independent GraphDB instances. The fullname helper in `charts/graphdb/templates/_helpers.tpl` uses `printf "%s-%s" .Release.Name .Chart.Name` so the aliases produce distinct resource names:

- `graphwise-stack-graphdb-embedded` (Service, StatefulSet, Ingress, TLS Secret)
- `graphwise-stack-graphdb-projects` (same set)

If you ever change the helper, **don't drop the `.Chart.Name` part** — both aliases share `.Release.Name` (the parent umbrella's release name), so a `.Release.Name`-only fullname collapses both into the same `graphwise-stack` and the second alias silently overwrites the first in the rendered manifest. PoolParty's `internalUrl` in `charts/poolparty/values.yaml` points at the prefixed `http://graphwise-stack-graphdb-embedded:7200`; if you rename the helper output pattern, update PoolParty's URL in lockstep.

### Console landing page — Helm `tpl` pattern

`charts/console/files/index.html` is a Helm template (rendered at install time via `tpl` in `charts/console/templates/configmap.yaml`). Apex hostname (`{{ $apex }}` = `<sub>.<base>`) and credential strings (`{{ .Values.credentials.* }}`) substitute at render time, so the deployed landing page always reflects current chart values — change a default in `charts/console/values.yaml` or the umbrella's override, run `helm upgrade`, the page is updated.

Credentials block in `charts/console/values.yaml` documents WHERE each credential is sourced from elsewhere (e.g. Grafana password lives in `charts/observability/kube-prometheus-stack-values.yaml`; basic-auth password is set by `cluster-bootstrap.sh`). Keep these in sync.

A JS hostname-rewrite hook at the bottom of index.html is a safety net: if the page is reached via a different hostname than what was rendered (proxy, internal LB rebrand), every link self-rewrites at page load. Don't rely on it as the primary mechanism — the `tpl` substitution is the authoritative path.

CONSOLE-GUIDE.md is the human-readable canonical reference for credentials (user-facing logins + internal service-to-service secrets + user-supplied secrets). Cross-reference both.

### Default password convention: `rdf#rocks`

Every chart-default password in the demo standardizes on the literal string `rdf#rocks`. Affects:

- Keycloak Postgres super + app passwords
- n8n Postgres super + app passwords
- GraphRAG conversation Postgres app password
- GraphRAG n8n DB credential
- conversation Keycloak client secret + matching realm-side client secret (lines 83 + 122 of umbrella `values.yaml` must stay equal)
- ingress basic-auth (htpasswd in `cluster-bootstrap.sh`) for Prometheus / GraphDB / RDF4J

Exceptions:

- `keycloak.bootstrapAdmin.password = "admin"` (PoolParty's chart hard-codes `poolparty_auth_admin / admin` — don't change without updating PoolParty's chart in lockstep).
- `graphrag-secrets.n8nEncryption.key` is auto-generated by Terraform's `random_id.n8n_encryption_key` and supplied via the `~/graphwise-secrets.yaml` overlay — `rdf#rocks` is too short for n8n's encryption requirement.
- Grafana's app-login password (`demo-graphwise-2026`) lives in `charts/observability/kube-prometheus-stack-values.yaml` — historic; OK to leave as-is or rename to `rdf#rocks` for full convention coverage.

This is demo-grade. Production deployments would per-deployment-randomize via Terraform `random_password` resources or external-secrets.

### Staging-data three-layer wiring (universal ingest path)

Multi-GB ingest data (PDFs, source documents, reference corpora the GraphRAG pipeline consumes) lives at the standardized path `/home/ec2-user/staging-data/` on the EC2. Cloud-init creates the directory on first boot. The path is exposed to Kubernetes pods via a three-layer mount chain (full diagram in HOWITWORKS.md §11):

1. **EC2 host:** `/home/ec2-user/staging-data/` (real files on EBS, created by `infra/terraform/user-data.sh.tpl`).
2. **KIND container:** mounted at `/staging-data` via `extraMounts` in `infra/kind/kind-config.yaml`. **Adding this requires `kind delete cluster` + `kind create cluster`** — KIND can't add mounts to a running cluster. Schedule with the next planned `reset-helm.sh` cycle, never as a hotfix.
3. **Pod:** PVC named `staging-data` per consuming namespace. `charts/graphwise-stack/templates/staging-data.yaml` renders one hostPath PV + one PVC per entry in `.Values.staging.namespaces` (default `[graphwise, graphrag]`). PVs use a sentinel `storageClassName: hostpath-staging` (no provisioner) and `claimRef`-pre-bind to their specific PVC; PVCs pin via `volumeName`. Both pre-binding mechanisms are required — without either, PVCs would stay `Pending` while K8s tried (and failed) to dynamically provision against the sentinel storage class.

Operator workflow: `rsync -azP -e "ssh -i $GRAPHWISE_KEY" <local>/ $GRAPHWISE_USER@$GRAPHWISE_HOST:~/staging-data/`. Files survive EC2 stop/start, KIND restart, `reset-helm.sh`. Do NOT survive `terraform destroy` (root EBS goes with the instance).

Pods are not auto-volumeMounted to `staging-data` by default — consuming workloads (graphrag-workflows, graphrag-components, etc.) add `volumes` + `volumeMounts` referencing PVC `staging-data` in their own namespace when ready. Toggle the entire feature off via `staging.enabled: false` in umbrella values.

### Nested-subchart `.tgz` gitignore (footgun avoidance)

`.gitignore` excludes `charts/*/charts/*.tgz` and `charts/*/Chart.lock` because these are PACKAGED snapshots of subchart-of-subchart directories that Helm prefers over the source dir at render time. Committing them creates the silent-stale-tarball footgun: source edits to `charts/addons/charts/unifiedviews/templates/all.yaml` get masked by a stale `charts/addons/charts/unifiedviews-1.0.0.tgz`, the umbrella's own packaging includes BOTH copies, and operators end up debugging "why isn't my chart change taking effect" without realizing two copies exist.

The umbrella's own bundled tarballs (`charts/graphwise-stack/charts/*.tgz` + `charts/graphwise-stack/Chart.lock`) ARE committed deliberately — those are the umbrella's vendored deps, intentionally pinned so deploys don't need network access. Only nested-subchart-of-subchart tarballs are the footgun.

If you ever see addons resources missing expected fields after an edit to `charts/addons/charts/<addon>/`, suspect this. Fix: `rm charts/addons/charts/*.tgz charts/addons/Chart.lock` (now harmless because gitignored), then `helm dependency update charts/graphwise-stack` to repackage the umbrella's addons tarball from clean source. The unifiedviews initContainer fix saga is the canonical example — see "Resolved bug catalog" below.

### Cert issuer toggle (staging default, prod for customer demos)

Two cert-manager `ClusterIssuer` resources exist in the cluster — both created by `cluster-bootstrap.sh`:

- **`letsencrypt-staging`** — DEFAULT during stack iteration. LE staging server (`https://acme-staging-v02.api.letsencrypt.org/directory`) has 30,000-cert/week limits (effectively unlimited for our pace). Certs aren't trusted by browsers (no ISRG root in trust stores), so URLs show "Not Secure" warnings. Fine for SE-internal validation, NOT fine for putting a prospect in front of the URL.
- **`letsencrypt-prod`** — USE FOR CUSTOMER DEMOS. Real LE prod certs, browsers trust them. Subject to LE rate limits: **5 certs per exact identifier per 168h**. Multiple fresh-deploy cycles in a week WILL hit the cap.

**The chart cascades the choice.** Umbrella `values.yaml` sets `global.clusterIssuer: letsencrypt-staging` as the default. Every Ingress template in every chart reads `{{ .Values.global.clusterIssuer | default .Values.ingress.clusterIssuer | default "letsencrypt-staging" }}`, so the umbrella value flows through to every cert. `cluster-bootstrap.sh`'s observability Ingresses (Dashboard / Prometheus / Grafana) read the same default via the `GRAPHWISE_CLUSTER_ISSUER` env var.

**Operators flip via `scripts/switch-cert-issuer.sh staging|prod`.** The script:
1. Patches every Ingress cluster-wide with the new `cert-manager.io/cluster-issuer` annotation.
2. Deletes every existing `Certificate` resource (their `issuerRef` field doesn't auto-update from an annotation change — they'd otherwise stay tied to the old issuer).
3. Deletes the corresponding `kubernetes.io/tls` Secrets so cert-manager regenerates them rather than serving a stale chain.
4. Polls until all certs Ready (10-min timeout).

A vanilla `helm upgrade --set global.clusterIssuer=...` rewrites annotations but skips steps 2 and 3 — Certificates would stay tied to the old issuer, certs wouldn't actually flip. Always use the script.

**`validate-stack.sh` auto-detects which issuer is in use** by reading `.spec.issuerRef.name` from any Certificate, and adds `-k` to its HTTPS reachability sweep when staging is detected (otherwise the sweep would report TLS-verification failures across the board on a healthy staging stack). A banner in the output explains the skip.

**Operator workflow:**
- **Stack iteration / SE-internal validation:** stay on staging (default). Click through browser warnings.
- **Right before a customer demo:** `./scripts/switch-cert-issuer.sh prod`, wait ~5-10 min for prod certs to issue, refresh browser, certs are now real and trusted.
- **Post-demo, back to iteration:** `./scripts/switch-cert-issuer.sh staging`, instant revert, no rate-limit cost.

**Rate-limit math** (in case prod runs out): LE prod allows 5 certs per exact identifier per 168h. With ~15 unique hostnames in this stack, that's 5 fresh deploys per identifier per week. Practical guideline: switching to prod once per customer-demo session is fine; flipping prod-staging-prod-staging in rapid iteration will exhaust the limit.

### Resolved bug catalog (recurring footguns to recognize)

The following bugs are now fixed in the chart. Documented for posterity so the next time something looks like one of these we recognize the pattern.

- **PoolParty stuck `0/1` looping on Keycloak `uma2-configuration`** — original theory was KIND hairpin-NAT against the public auth URL. Real root cause turned out to be **Ontotext's realm export shipping `${...}` env-var placeholders that the operator-managed KeycloakRealmImport CR doesn't substitute**. The `ppt` client's secret was the literal string `${POOLPARTY_KEYCLOAK_LOGIN_CLIENTSECRET}` so OAuth token exchange failed with `invalid_client`; the `superadmin` user's password was the literal `${POOLPARTY_SUPER_ADMIN_PASSWORD}` so login outright didn't work; and the per-client `.authorizationSettings` block (resources/scopes/policies needed for PoolParty's UMA permission ticket flow) was being silently dropped by the operator's import. **Fix:** `scripts/extract-poolparty-realm.sh` jq-substitutes the placeholders at extract time + `charts/keycloak-realms/templates/keycloak-authz-import-job.yaml` is a post-install Helm hook that re-imports the authz config via the Keycloak admin REST API (`/admin/realms/<realm>/clients/<uuid>/authz/resource-server/import`). Hairpin-NAT works fine; was never the actual problem.
- **`unifiedviews` Deployment in `CrashLoopBackOff`** — entrypoint died with `/__cacert_entrypoint.sh: line 114: /unified-views/run-uv.sh: No such file or directory`. The chart mounts a PVC at `/unified-views` which shadows the image's binaries. The chart already had an `initContainer` named `populate-image-content` that copies the image's `/unified-views/` tree into the PVC, BUT the umbrella's bundled `charts/graphwise-stack/charts/addons-1.0.0.tgz` packaged BOTH the source `charts/addons/charts/unifiedviews/` directory AND a stale pre-packaged `charts/addons/charts/unifiedviews-1.0.0.tgz` tarball. At render time Helm preferred the stale `.tgz`, which predated the initContainer fix, so the deployed Deployment never had the initContainer attached. **Fix:** delete the inner-subchart tarballs, gitignore `charts/*/charts/*.tgz` and `charts/*/Chart.lock` to prevent recurrence, regenerate the umbrella's bundled tarball from clean source. Lesson: nested-subchart tarballs are a footgun; keep only the source directories in git.
- **GraphDB subchart fullname collision under umbrella aliases** — the chart's `graphdb.fullname` helper used `.Release.Name` verbatim, which assumed standalone install (`helm install graphdb-embedded ./charts/graphdb`). In umbrella mode with subchart aliases (`graphdb-embedded` and `graphdb-projects` both descending from release `graphwise-stack`), both rendered with the same `metadata.name: graphwise-stack` and silently collided in the merged manifest — only the second alias survived, leaving PoolParty unable to reach `graphdb-embedded:7200`. **Fix:** helper now produces `<release>-<alias>` form (`graphwise-stack-graphdb-embedded`, `graphwise-stack-graphdb-projects`), and PoolParty's `internalUrl` was updated to match.

### Currently open issues (Helm path)

(none right now — full umbrella deploy validates end-to-end including PoolParty browser login and UnifiedViews. Add new entries here as they appear.)
