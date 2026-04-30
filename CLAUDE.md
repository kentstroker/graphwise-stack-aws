# CLAUDE.md

**Maintainer:** Kent Stroker

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A **Helm-on-KIND** deployment of the Ontotext / Graphwise **PoolParty** ecosystem plus the **GraphRAG** chatbot suite, on a single **AWS EC2** instance (Debian 13, rootless podman, single-node KIND cluster). All ingress is HTTPS via ingress-nginx + cert-manager + Let's Encrypt. It is explicitly a **demo / evaluation** deployment — not production-ready — see the warning block in [DEPLOY.md](DEPLOY.md) for the full list of what would need to change for production use.


**Audience and licensing.** This repo is primarily for **internal use by Graphwise field presales engineers**. It is public (MIT-licensed, AS-IS, no warranty, no support — see [LICENSE](LICENSE)) so that customers, partners, and the semantic-web community can reference it when building their own evaluation environments. External users must supply their own Graphwise license files (PoolParty/GraphDB EE/UnifiedViews — obtained by contacting Graphwise), their own AWS account, and their own domain. The repo ships zero license files and no access to Graphwise's shared presales domain `semantic-proof.com`.

No application source code is in this repo. Only:

- `infra/kind/kind-config.yaml` — single-node KIND cluster definition
- `infra/terraform/` — provisions an EC2 host pre-loaded with kind/kubectl/helm and a running cluster
- `charts/graphwise-stack/` — umbrella Helm chart (PoolParty + GraphDB ×2 + addons + console + Keycloak + supporting graphrag Secrets/Postgres)
- `charts/{poolparty,graphdb,addons,console,poolparty-elasticsearch,keycloak-realms}/` — per-app sub-charts
- `charts/vendor/graphrag*/` — vendored GraphRAG charts (chatbot, conversation, components, workflows) — installed as a separate Helm release
- Helper scripts under `scripts/`: `cluster-bootstrap.sh`, `cluster-resume.sh`, `reset-helm.sh`, `render-values.sh`, `install-licenses.sh`, `extract-poolparty-realm.sh`
- Vendor license files under `files/licenses/` (gitignored)

Changes are usually to a chart's `values.yaml` / `templates/`, the umbrella's `templates/`, or `scripts/render-values.sh`.

Companion docs: [README.md](README.md) (one-page summary + zero-to-deployed checklist), [SETUP.md](SETUP.md) (laptop-zero prerequisites), [DEPLOY.md](DEPLOY.md) (end-to-end deploy walkthrough), [CHEATSHEET.md](CHEATSHEET.md) (URLs / credentials), [infra/README.md](infra/README.md) (Terraform module).

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
| `scripts/cluster-bootstrap.sh` | One-time install of cluster operators: ingress-nginx, cert-manager (+ LE `letsencrypt-prod` ClusterIssuer), CNPG, Keycloak operator, metrics-server. Also creates the `graphwise` image-pull secret in the `graphwise` and `graphrag` namespaces from `~/.ontotext/maven-{user,pass}`. Idempotent. Required env: `LE_EMAIL`. |
| `scripts/cluster-resume.sh` | Restart the KIND cluster after an EC2 stop/start. Finds the cluster's node containers via the `io.x-k8s.kind.cluster=<name>` label, `podman start`s them, and sets `--restart=unless-stopped` so subsequent reboots are a non-event. Polls `/readyz` until the API answers. |
| `scripts/render-values.sh [--umbrella\|--graphrag\|--both] <subdomain> [base_domain]` | Emits Helm values overlays. Default (`--both`) writes two files — `/tmp/values-<sub>.yaml` (umbrella) and `/tmp/values-<sub>-graphrag.yaml` (graphrag). `--umbrella`/`--graphrag` emit just one to stdout. Computes every per-app hostname (`poolparty.<sub>.<base>`, `auth.<sub>.<base>`, `graphrag.<sub>.<base>`, `graphdb.<sub>.<base>`, `graphdb-projects.<sub>.<base>`, `adf.<sub>.<base>`, `semantic-workbench.<sub>.<base>`, `graphviews.<sub>.<base>`, `rdf4j.<sub>.<base>`, `unifiedviews.<sub>.<base>`; console at apex `<sub>.<base>`). |
| `scripts/install-licenses.sh` | kubectl-creates the three license Secrets (`poolparty-license`, `graphdb-license`, `unifiedviews-license`) in the `graphwise` namespace from `files/licenses/*`. Idempotent. |
| `scripts/reset-helm.sh [--yes] <subdomain> [base_domain]` | Wipe and reinstall **both** Helm releases. Uninstalls graphrag first then umbrella, deletes all PVCs in `graphwise` / `keycloak` / `graphrag`, re-renders both values overlays, runs `helm dependency update` on **both** chart paths (`charts/vendor/graphrag` first — its inner subchart tarballs need to land before the outer chart can package them — then `charts/graphwise-stack`), then `helm upgrade --install` umbrella, then graphrag, each with `--timeout 15m`. `--yes` skips the `reset` confirmation prompt; the arg parser accepts `--yes` in any position. Subdomain and base-domain are validated against RFC 1123 before anything destructive runs (so e.g. an `--yes` typo can't end up in the base-domain slot). Does **not** touch operators installed by `cluster-bootstrap.sh`. |

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

DNS needs both `<sub>.<base>` (apex) and `*.<sub>.<base>` (wildcard) A-records to the EIP. The Terraform module's `godaddy_dns_records` output prints both.

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

KIND nodes are podman containers. On EC2 stop/start `podman.service` comes back automatically, but containers without a restart policy stay `Exited` — kubectl then fails with `connection refused on 127.0.0.1:6443`. `scripts/cluster-resume.sh` starts them and sets `--restart=unless-stopped` so the next reboot is a non-event. Run it any time after a fresh boot; it's idempotent.

### Mac → EC2 sync during active troubleshooting

While iterating on the Helm charts, edits land on the developer's Mac and get scp'd to the EC2 host. Git is intentionally not in the loop until the changes settle. After every chart/script edit, sync the affected files before `helm upgrade`:

```bash
scp -i <key.pem> <changed-files> graphwise@<eip>:~/graphwise-stack-aws/<paths>/
```

`helm get manifest graphwise-stack -n graphwise` confirms what was actually applied — useful when an expected change isn't taking effect.

### Currently open issues (Helm path)

- **PoolParty pod stuck `0/1`** — discovery loop against `https://auth.<apex>/realms/poolparty/.well-known/uma2-configuration` keeps failing. After fixing the missing Keycloak Ingress TLS, the next suspected root cause is KIND not reliably hairpin-NAT-ing public IPs back to the host's port mapping. Likely fix: a CoreDNS rewrite (or `hostAliases` on each OIDC-consuming Deployment) mapping `auth.<apex>` to the ingress-nginx-controller Service ClusterIP so the request stays inside the cluster.
- **`unifiedviews` Deployment in `CrashLoopBackOff`** — deferred until the rest of the Helm install runs cleanly end-to-end.
