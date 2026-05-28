# CLAUDE.md

**Maintainer:** Kent Stroker

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository. It is the spine — the *rules* and live state live here; the *narratives* (rationale, full Job templates, walkthroughs) live under `docs/claude/`.

## What this repo is

A **Helm-on-KIND** deployment of the Ontotext / Graphwise **PoolParty** ecosystem plus the **GraphRAG** chatbot suite, on a single **AWS EC2** instance (Amazon Linux 2023, Docker, single-node KIND cluster). All ingress is HTTPS via ingress-nginx + cert-manager + Let's Encrypt. It is explicitly a **demo / evaluation** deployment — not production-ready — see the warning block in [DEPLOY.md](DEPLOY.md) for the full list of what would need to change for production use.

**Audience and licensing.** Primarily for **internal use by Graphwise field presales engineers**. Public (MIT-licensed, AS-IS, no warranty, no support — see [LICENSE](LICENSE)) so that customers, partners, and the semantic-web community can reference it when building their own evaluation environments. External users must supply their own Graphwise license files (PoolParty/GraphDB EE/UnifiedViews — obtained by contacting Graphwise), their own AWS account, and their own domain. The repo ships zero license files and no access to Graphwise's shared presales domain `semantic-proof.com`.

**OS history.** Previously deployed on Debian 13 with rootless podman. Migrated to AL2023 + Docker in late 2026 after consistent "ssh fails immediately after scp" failures on Debian 13 + AWS Nitro that nobody could explain; AL2023 doesn't trigger the issue. KIND on Docker is also better-supported (KIND-on-podman is still `KIND_EXPERIMENTAL_PROVIDER`).

## Layout

No application source code is in this repo. Only:

- `infra/kind/kind-config.yaml` — single-node KIND cluster definition
- `infra/terraform/` — provisions an EC2 host pre-loaded with kind/kubectl/helm and a running cluster
- `charts/graphwise-stack/` — umbrella Helm chart (PoolParty + GraphDB ×3 + addons + console + Keycloak + supporting graphrag Secrets/Postgres)
- `charts/{poolparty,graphdb,addons,console,poolparty-elasticsearch,keycloak-realms}/` — per-app sub-charts
- `charts/vendor/graphrag*/` — vendored GraphRAG charts (chatbot, conversation, components, workflows) — installed as a separate Helm release
- Helper scripts under `scripts/` and `scripts/laptop/` — see `docs/claude/scripts.md`
- Vendor license files under `files/licenses/` (gitignored)

Changes are usually to a chart's `values.yaml` / `templates/`, the umbrella's `templates/`, or `scripts/render-values.sh`.

**Companion docs:** [README.md](README.md) (one-page summary), [QUICKSTART.md](QUICKSTART.md) (0-18 step deploy), [SETUP.md](SETUP.md) (laptop-zero prereqs), [DEPLOY.md](DEPLOY.md) (walkthrough), [HOWITWORKS.md](HOWITWORKS.md) (layered architecture explainer), [CONSOLE-GUIDE.md](CONSOLE-GUIDE.md) (URLs / credentials), [infra/README.md](infra/README.md) (Terraform module).

## Architecture in one paragraph

The Helm path runs as **two separate releases**: `graphwise-stack` (in `graphwise` ns — PoolParty, GraphDB ×3, ES, console, addons, Keycloak CR + Postgres + realm imports, **plus** the supporting Secrets/ConfigMap/Postgres the GraphRAG pods need, materialized in the `graphrag` namespace) and `graphrag` (in `graphrag` ns — vendored chatbot/conversation/components/workflows pods from `charts/vendor/graphrag/`, installed as its own release because the vendor templates don't set `metadata.namespace` and would otherwise land in `graphwise` where they can't mount the supporting Secrets).

**Order matters.** Install: umbrella first (creates Secrets/Postgres in `graphrag`), then graphrag. Uninstall: graphrag first (so pods release mounts/connections), then umbrella. `scripts/reset-helm.sh` enforces both.

## Subdomain-per-app routing

Each app gets its own subdomain so ingress-nginx can mint a separate cert per app and each app's webapp doesn't need a context-path-prefix story:

| App | Hostname |
|---|---|
| Console (landing) | `<sub>.<base>` (apex) |
| Keycloak | `auth.<sub>.<base>` |
| PoolParty | `poolparty.<sub>.<base>` |
| GraphDB embedded | `graphdb.<sub>.<base>` |
| GraphDB projects | `graphdb-projects.<sub>.<base>` |
| GraphDB AdeptNova (RC2+) | `graphdb-adeptnova.<sub>.<base>` (HTTPS) **plus** direct `:17200` on the EIP, CIDR-allowlisted |
| ADF | `adf.<sub>.<base>` |
| Semantic Workbench | `semantic-workbench.<sub>.<base>` |
| GraphViews | `graphviews.<sub>.<base>` |
| RDF4J | `rdf4j.<sub>.<base>` |
| UnifiedViews | `unifiedviews.<sub>.<base>` |
| Ontotext Refine | `refine.<sub>.<base>` (CIDR-allowlisted via `admin_cidr`) |
| GraphRAG (chatbot + conversation + workflows) | `graphrag.<sub>.<base>` (different paths) |
| Kubernetes Dashboard | `dashboard.<sub>.<base>` |
| Prometheus | `prometheus.<sub>.<base>` |
| Grafana | `grafana.<sub>.<base>` |

DNS needs both `<sub>.<base>` (apex) and `*.<sub>.<base>` (wildcard) A-records to the EIP. The Terraform module's `route53_dns_records` output prints both. **EIP must be pre-allocated** via `existing_eip_allocation_id` in `terraform.tfvars` so it survives `terraform destroy`/`apply` cycles — see `docs/claude/aws-and-terraform.md`.

## Critical rules (the ones that cause stack breakage)

- **Keycloak hostname must be exactly `auth.<sub>.<base>` with `strict: true` on the CR** (NO `/auth` path). Spring Security's `NimbusJwtDecoder.withIssuerLocation()` is strict-equality on the issuer URL; any drift kills every OIDC client at boot. The operator-generated Ingress lacks a `tls:` block when `httpEnabled: true`, so we set `spec.ingress.enabled: false` on the CR and ship our own Ingress with the TLS block. → `docs/claude/keycloak.md`

- **PoolParty `llm.model` is duplicated across TWO chart layers** (`charts/poolparty/values.yaml` and `charts/graphwise-stack/values.yaml`); umbrella wins. Grep `claude\|llama\|nova` across `charts/` before any LLM-config edit. Newer Bedrock chat models (Llama 3.3+, Claude Sonnet 3.5 v2+, Nova, Mistral Large 2) need an **inference profile ID** (`us.` / `eu.` / `apac.` prefix) — bare foundation-model IDs return `InvalidRequestException`. Secret-only updates require a manual `kubectl rollout restart` — `secretKeyRef` env vars are snapshotted at pod start. → `docs/claude/poolparty-llm.md`

- **GraphDB JVM heap is set explicitly** to `-Xmx8g` (memory limit `10Gi`) in `charts/graphdb/values.yaml`. Without `-Xmx`, the JVM defaults to ~1Gi regardless of pod limit and `GROUP BY` / `DISTINCT` queries fail with `Insufficient free Heap Memory`. **Rule of thumb: heap = pod memory limit − 2Gi.**

- **Nested-subchart `.tgz` is gitignored** (`charts/*/charts/*.tgz` + `charts/*/Chart.lock`). Committing them creates the silent-stale-tarball footgun: Helm prefers the tarball over source edits, so chart changes silently no-op. The umbrella's own `charts/graphwise-stack/charts/*.tgz` IS committed (vendored deps, intentional). If you see addons resources missing expected fields after an edit, suspect this — `rm charts/addons/charts/*.tgz charts/addons/Chart.lock` then `helm dependency update`.

- **GraphDB subchart fullname must keep `.Chart.Name`** in the helper (`printf "%s-%s" .Release.Name .Chart.Name`). The umbrella installs `charts/graphdb/` three times as aliases (`graphdb-embedded`, `graphdb-projects`, `graphdb-adeptnova`); dropping `.Chart.Name` collapses them into one manifest and later aliases silently overwrite earlier ones. PoolParty's `internalUrl` (`http://graphwise-stack-graphdb-embedded:7200`) depends on the prefixed name. → `docs/claude/chart-internals.md`

- **AdeptNova GraphDB is the only direct-port-public service.** Host `:17200` → KIND `:31720` → `graphwise-stack-graphdb-adeptnova` NodePort Service. CIDR allowlist lives in `var.adeptnova_cidrs` and provisions a **standalone** `aws_security_group_rule` resource — NOT an inline `ingress {}` block on `aws_security_group.stack` (that SG sets `lifecycle.ignore_changes = [ingress]` to preserve operator-added Console rules). GraphDB-native security is on for this instance (admin password in `graphdb-adeptnova/graphwise-stack-graphdb-adeptnova-admin`). KIND extraPortMappings change is **not hot-applicable** — RC2 upgrade requires a cluster recreate.

- **TLS: one wildcard cert via Route 53 DNS-01**, reflector mirrors it into every consuming namespace. Every Ingress's `tls.secretName: wildcard-tls`. `letsencrypt-prod` only — staging chain isn't trusted by in-cluster JVM clients (PoolParty → Keycloak), TLS handshake fails. → `docs/claude/tls-and-ingress.md`

- **Two-IAM-user actor model** (AWS). `terraform-demo` (laptop, infra provisioning) and `graphrag-bedrock` (runtime, baked into Secret). All IAM creation done by root or IAM-admin, NEVER by `terraform-demo` itself. EIP must be pre-allocated via `existing_eip_allocation_id` (required). AMI is locked via `lifecycle.ignore_changes` + `ami_override` to prevent `terraform apply` from destroying the EC2 when AWS publishes an AL2023 refresh. → `docs/claude/aws-and-terraform.md`

- **Mac → EC2 sync during iteration**: edits land on Mac, `scp` to EC2 before `helm upgrade`. Git is intentionally not in the loop until changes settle. `helm get manifest graphwise-stack -n graphwise` confirms what was actually applied — useful when an expected change isn't taking effect.

- **Default password convention: `rdf#rocks`** for chart-default passwords (Keycloak/n8n/conversation Postgres, ingress basic-auth, conversation Keycloak client secret). Exceptions: `keycloak.bootstrapAdmin.password = "admin"` (PoolParty's chart hard-codes it), `n8nEncryption.key` (auto-generated by Terraform), Grafana `demo-graphwise-2026` (historic).

## Lifecycle scripts (one-liners)

Full descriptions in `docs/claude/scripts.md`.

- `scripts/cluster-bootstrap.sh` — one-time install of cluster operators + observability (ingress-nginx, cert-manager + LE issuer, CNPG, Keycloak operator, metrics-server, Dashboard, kube-prometheus-stack).
- `scripts/cluster-resume.sh` — restart KIND nodes after EC2 stop/start; sets `--restart=unless-stopped`.
- `scripts/cluster-stop.sh` — quiesce app workloads (scale-to-0) before stopping the EC2.
- `scripts/render-values.sh` — emit `$HOME/.graphwise-stack/values-<sub>.yaml` + `$HOME/.graphwise-stack/values-<sub>-graphrag.yaml`. Auto-invoked by `reset-helm.sh`. (Persistent across reboots; AL2023 wipes `/tmp` on boot, so the prior `/tmp` location was a footgun after `cluster-stop.sh` → start.)
- `scripts/install-licenses.sh` — create the three license Secrets in `graphwise` ns from `files/licenses/`.
- `scripts/preflight-reset-helm.sh` — read-only pre-flight gate (tools, cluster, operators, DNS, IMDS, maven auth probe).
- `scripts/validate-bootstrap.sh` — post-bootstrap health check.
- `scripts/validate-stack.sh` — post-reset-helm.sh health check (pods, certs, OIDC issuers, HTTPS reachability).
- `scripts/reset-helm.sh [--yes] [--skip-graphrag] <subdomain> [base_domain]` — wipe and reinstall both releases.
- `scripts/laptop/{pull,push}-config.sh` — symmetric snapshot pair for `~/graphwise-secrets.yaml` + licenses + live wildcard cert.

## Chart internals — pointers

Detail in `docs/claude/chart-internals.md`:

- GraphDB subchart fullname pattern (alias-aware) + namespace split (`graphdb-embedded` in `graphwise`, `graphdb-projects` in `graphdb`).
- GraphDB JVM heap rationale (`-Xmx8g` / limit `10Gi`).
- Staging-data three-layer wiring (`/home/ec2-user/staging-data/` → KIND `extraMounts` → PVC per namespace).
- Console landing page Helm `tpl` pattern.
- UnifiedViews `uv-password-reset` Job (SPARQL-resets admin/admin via RDF4J in-cluster).
- `graphrag-vectors-index` Job (PUTs the Elasticsearch index graphrag-components's health probe requires).
- KIND lifecycle on EC2.
- Default password convention details.

Keycloak-specific Jobs (authz-import, graphrag-realm-patch, bootstrap-admin race fix) are in `docs/claude/keycloak.md`.

## Resolved bug catalog

Patterns to recognize when something looks familiar — full write-ups in `docs/claude/bug-history.md`:

- PoolParty stuck on Keycloak `uma2-configuration` → realm export `${...}` placeholders not substituted.
- `unifiedviews` `CrashLoopBackOff` → stale nested-subchart `.tgz` shadowed the source initContainer fix.
- GraphDB subchart fullname collision under umbrella aliases.
- `graphrag-realm-patch` `BackoffLimitExceeded` on cold-cache → race with realm-import + Keycloak v26 role-model change.

## Currently open issues (Helm path)

- *(Resolved 2026-05-28 via bundled platform-independent dist)* **Refine `ontotext/refine:1.2.2` is amd64-only on Docker Hub** (`manifest.v2`, no manifest-list). On Graviton (arm64) the vendor's image CrashLoopBackOffs with `exec /opt/ontorefine/dist/bin/ontorefine: exec format error`. Workaround: the **extracted platform-independent dist is checked into the repo** at `refine/ontorefine-1.2.1/` (Java only, 180 JARs, no native binaries — `bin/ontorefine` is a bash launcher that `exec`s java). `scripts/build-refine-image.sh` wraps it in `eclipse-temurin:11-jre` (multi-arch, picks up arm64 natively) and `kind load`s it as `graphwise-refine:local`. `cluster-bootstrap.sh` auto-runs the build; `scripts/render-values.sh` auto-emits `addons.refine.enabled: true` + the local-image override in the per-deploy overlay when the dist directory is detected. Chart defaults (`refine.enabled: false` in both `charts/graphwise-stack/values.yaml` and `charts/addons/values.yaml`) are the safety net for sparse-checkout / shallow-clone edge cases. Source `.zip` is gitignored (153 MB single file exceeds GitHub's 100 MB per-file hard limit); the extracted dir's largest JAR is well under. Remove this entry once Graphwise publishes a multi-arch tag of `ontotext/refine` -- at that point flip defaults to `enabled: true`, repository back to `ontotext/refine`, delete the bundled dist, and remove the dist-detection plumbing.

- *(Resolved 2026-05-28, kept here as a note for the next deploy)* **PoolParty Keycloak post-deploy user creation** used to 500 with `skosView is missing` / INTERNAL ERROR because (a) the realm referenced PoolParty's SPI + theme that ship inside `ontotext/poolparty-keycloak` and weren't on stock Keycloak's classpath, and (b) the realm's `default-roles-poolparty` composite didn't include any role that satisfies the `ppt` client's UMA policies for locally-created users. Fixed by: (1) pinning `KEYCLOAK_OPERATOR_VERSION=25.0.6` in `cluster-bootstrap.sh` and pointing the Keycloak CR at `ontotext/poolparty-keycloak:latest` directly (`spec.image` + `startOptimized: false`) via the new `keycloak.image` values knob — KIND pre-loads the vendor image during bootstrap, so the SPI + theme load natively; (2) `charts/keycloak-realms/templates/poolparty-default-roles-patch-job.yaml` — post-install/upgrade Job that composes `PoolPartyUser` into `default-roles-poolparty` so every new user is auto-authorized at creation. Verified end-to-end on a fresh destroy/apply: brand-new Keycloak admin-console user lands in PoolParty's projects list with no manual role granting. If the symptom ever returns, suspect the operator vs server version pin (KC 25 SPI doesn't load in KC 26) or the realm export changing the role hierarchy (a different role might be required — `defaultUserRole` in `keycloak-realms` values is the knob).
