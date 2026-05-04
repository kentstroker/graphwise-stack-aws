# Graphwise Stack — Console Guide

**Maintainer:** Kent Stroker

A guided tour through every component in the running stack. For each
app: where it lives, how to log in, what to try first, and what
"working" looks like.

URLs in this doc use a placeholder apex `<sub>.<base>` (e.g.
`stroker.semantic-proof.com`). Substitute your own subdomain + base
domain. Each app is on its own subdomain (`<app>.<sub>.<base>`); the
Console landing page is at the apex.


---

## Stack Console (landing page)

**URL:** `https://<sub>.<base>/`
**Auth:** none — public landing page

The first thing to load. Provides one-click links to every other
component, computed from the apex you opened it at (the page
auto-rewrites links so the same static HTML works for any
deployment). If this doesn't load, nothing else will — start
troubleshooting here.

**Smoke test:** load the page in a browser, see the cards. Click
"PoolParty Thesaurus" to confirm the link target points at
`poolparty.<your-apex>` and not the placeholder
`stroker.semantic-proof.com`.

**If it doesn't load:**

```bash
curl -s -o /dev/null -w 'http=%{http_code}\n' https://<sub>.<base>/
kubectl -n graphwise get pods -l app.kubernetes.io/name=console
kubectl get certificate -n graphwise graphwise-stack-console-tls
```

---

## Keycloak (auth)

**URLs:**

- Admin console: `https://auth.<sub>.<base>/admin/`
- Account self-service: `https://auth.<sub>.<base>/realms/<realm>/account/`
- OIDC discovery: `https://auth.<sub>.<base>/realms/<realm>/.well-known/openid-configuration`

**Login (master realm — Keycloak admin):** `poolparty_auth_admin` / `admin`

Three realms shipped:

| Realm | Purpose | Imported from |
|---|---|---|
| `master` | Keycloak's own admin realm. The `poolparty_auth_admin` user lives here, created by the Helm post-install Job. | bootstrap Job (`charts/graphwise-stack/templates/keycloak-bootstrap-admin-job.yaml`) |
| `poolparty` | SSO for PoolParty / ADF / Semantic Workbench / GraphSearch / Extractor. Default users + clients defined here. | `charts/keycloak-realms/files/poolparty-realm.json` (extracted from `ontotext/poolparty-keycloak`) |
| `graphrag` | SSO for the GraphRAG chatbot + service-to-service auth for the conversation API. | `charts/keycloak-realms/templates/graphrag-realm.yaml` (inline) |

**Smoke test:**

```bash
curl -s https://auth.<sub>.<base>/realms/master/.well-known/openid-configuration | jq -r .issuer
```

Must read **exactly** `https://auth.<sub>.<base>/realms/master`. If
the issuer is missing the scheme, has a different host, or includes
a path, every OIDC client downstream (PoolParty, ADF, Semantic
Workbench, GraphRAG conversation) will refuse to start. This is the
single highest-leverage check in the stack.

**Bootstrap admin user:** the operator generates a temporary
`temp-admin` in Secret `graphwise-keycloak-initial-admin` on first
boot. The post-install Job uses it once to create
`poolparty_auth_admin / admin` in the master realm. After that, log
in as `poolparty_auth_admin` for everything.

---

## PoolParty Thesaurus

**URL:** `https://poolparty.<sub>.<base>/PoolParty/`
**Login:** Keycloak SSO — `superadmin` / `poolparty` (in the
`poolparty` realm)

> **Path matters.** Hitting `https://poolparty.<sub>.<base>/`
> (without `/PoolParty/`) lands on the LDF webapp, which is
> near-empty on fresh installs. The admin/authoring UI is at
> `/PoolParty/`. When someone says "PoolParty is blank", confirm the
> path first.

The main authoring tool — taxonomies, concepts, projects. Login
redirects through Keycloak and back.

**Smoke test:** log in. You should land in the projects list. New
deployments have no projects — that's expected. Click "Create New
Project" to verify write paths work.

**If login fails:**

- "Invalid username or password" → realm import didn't seed the user
  correctly. Check `kubectl -n keycloak exec graphwise-keycloak-0
  -- /opt/keycloak/bin/kcadm.sh get users -r poolparty
  --fields username,enabled` after configuring credentials.
- Pod stuck `0/1` and never accepts traffic → check
  `kubectl -n graphwise logs -l app.kubernetes.io/name=poolparty
  --tail=80` for the `KeycloakAuthClientConfig` retry loop. If
  present, see the [Keycloak issuer-match invariant](#keycloak-auth)
  above.

## PoolParty GraphSearch

**URL:** `https://poolparty.<sub>.<base>/GraphSearch/`
**Login:** SSO (same `superadmin` / `poolparty`)

Search frontend over PoolParty content. Empty until you've created
projects with concepts.

**Smoke test:** log in, you should see an empty search interface.
The toolbar should show your username top-right.

## PoolParty Extractor

**URL:** `https://poolparty.<sub>.<base>/extractor/`
**Login:** OIDC bearer token — REST-only API, no UI

**Smoke test:**

```bash
curl -i https://poolparty.<sub>.<base>/extractor/
```

Should return 401 (auth required) — that means the path is wired
and the app is up. Anything else (404, 502, connection refused)
means broken routing.

---

## ADF (Advanced Data Fabric)

**URL:** `https://adf.<sub>.<base>/ADF/`
**Login:** SSO (same `superadmin` / `poolparty`, `poolparty` realm)

Data integration / enrichment. Same SSO chain as PoolParty.

**Smoke test:** log in, land on the ADF dashboard. If the page
returns HTTP 404 at `/`, that's normal — only `/ADF/` serves
content.

## Semantic Workbench

**URL:** `https://semantic-workbench.<sub>.<base>/SemanticWorkbench/`
**Login:** SSO (same `superadmin` / `poolparty`)

RDF modeling, ontology editor, SHACL, SPARQL.

## GraphViews

**URL:** `https://graphviews.<sub>.<base>/GraphViews/`
**Login:** Direct PoolParty API — `superadmin` / `poolparty`

Visualization on top of PoolParty projects. **Note:** GraphViews
does **not** use Keycloak SSO — it authenticates directly to the
PoolParty API. If your PoolParty admin password drifts, GraphViews
breaks even though everything else still works.

## UnifiedViews

**URL:** `https://unifiedviews.<sub>.<base>/UnifiedViews/`
**Login:** App-local — try `admin` / `admin` (default; change after
first login)

ETL / pipeline platform. Has its own login system completely
independent of Keycloak.

> **Known issue:** the unifiedviews pod has been seen in
> CrashLoopBackOff in some deployments. If it's down, PoolParty /
> Keycloak / GraphRAG are unaffected. See
> [CLAUDE.md](CLAUDE.md) §"Currently open issues".

---

## GraphDB — embedded (PoolParty's store)

**URL:** `https://graphdb.<sub>.<base>/`
**Login:** HTTP basic auth at the ingress — `demo` / `rdf#rocks`
(GraphDB itself runs with auth disabled)

**This is PoolParty's backing thesaurus store.** Don't load your own
data here — use the `projects` instance below. Reading + browsing is
fine; writes will conflict with PoolParty.

**Smoke test:**

```bash
curl -s -u 'demo:rdf#rocks' https://graphdb.<sub>.<base>/rest/repositories | jq
```

You should see at least one repository (PoolParty creates them on
first project boot).

In a browser, hit the URL with `Accept: text/html` (browsers do
this automatically). You'll get the GraphDB Workbench. Without the
header, GraphDB returns 406 — not a bug, just content negotiation.

## GraphDB — projects (your data)

**URL:** `https://graphdb-projects.<sub>.<base>/`
**Login:** HTTP basic auth — `demo` / `rdf#rocks`

A second, isolated GraphDB instance for your own data. Load
repositories, run SPARQL, do whatever you want. PoolParty does NOT
talk to this one.

**Smoke test:**

```bash
curl -s -u 'demo:rdf#rocks' https://graphdb-projects.<sub>.<base>/rest/repositories | jq
```

Probably an empty array on a fresh deployment. Create a repo via
the workbench and verify it appears.

## RDF4J Workbench

**URL:** `https://rdf4j.<sub>.<base>/rdf4j-workbench/`
**Login:** HTTP basic auth — `demo` / `rdf#rocks`

> **Path matters.** `https://rdf4j.<sub>.<base>/` returns 404 — the
> workbench lives at `/rdf4j-workbench/`. The bare-domain 404 is
> normal.

Standalone RDF workbench. Also serves as the backing store for
UnifiedViews internally.

**Rotating the basic-auth password:**

```bash
htpasswd -nb demo '<new-password>'
```

Replace the `htpasswd:` value in `charts/graphdb/values.yaml` and
`charts/addons/charts/rdf4j/values.yaml`. Then `helm upgrade` both
releases. APR1 hashes are randomly salted, so any teammate can
regenerate — only requirement is that the hash actually verifies
against the documented password (we shipped a stale hash once,
spent some time tracking down the resulting 401s).

---

## GraphRAG — Chatbot

**URL:** `https://graphrag.<sub>.<base>/`
**Login:** SSO via the `graphrag` realm — `alice` / `alice123` (or
`bob` / `bob123`)

Web UI for the conversational agent. Asks questions, gets answers
backed by retrieval over your taxonomy + vector store.

**Smoke test:** log in as `alice`, type a question. The first
response takes a moment because:

1. Conversation API hits the components service for retrieval.
2. Components hits Bedrock (`cohere.embed-english-v3`) for
   embeddings.
3. Components hits Elasticsearch (the vector store) for similarity
   search.
4. Conversation generates the response.

If the chat hangs or returns "Service unavailable":

```bash
kubectl -n graphrag get pods
kubectl -n graphrag logs deployment/graphrag-conversation --tail=30
kubectl -n graphrag logs deployment/graphrag-components --tail=30
```

Common issues:

- Bedrock `AccessDeniedException` → `graphrag-bedrock` IAM user
  policy missing the model. See
  [SETUP.md §4b Create the Bedrock IAM user](SETUP.md#4b-create-the-bedrock-iam-user).
- Empty embeddings response → wrong region in the AWS credentials
  Secret.

## GraphRAG — Conversation API

**URL:** `https://graphrag.<sub>.<base>/conversations/`
**Login:** OIDC bearer token (service-to-service); no UI

Spring backend that the chatbot calls. The API shape lives at
`/conversations/v3/api-docs/swagger-config` (Swagger UI), but you
need a token to hit any endpoint.

**Smoke test:**

```bash
curl -s -o /dev/null -w 'http=%{http_code}\n' https://graphrag.<sub>.<base>/conversations/actuator/health
```

Want `200` (Spring's actuator usually allows public health) or
`401` (auth required, app is up). Anything else means broken.

## GraphRAG — Workflows (n8n)

**URL:** `https://graphrag.<sub>.<base>/graphrag/workflows/`
**Login:** n8n's own login system — set on first boot

n8n hosts the workflow that orchestrates retrieval. **First visitor
becomes the owner** — make sure you set the credentials yourself
and don't let a customer hit the page first.

**Smoke test:** load the URL. You should see the n8n setup wizard
("Set up owner account") on first boot, or the workflow editor
afterwards. If you see "Service Unavailable" or it 502s, check the
workflows pod log — usually a missing or invalid n8n license:

```bash
kubectl -n graphrag logs deployment/graphrag-workflows --tail=50
```

If you see "Invalid activation key", the
`graphrag-secrets.n8nLicense.activationKey` value in the umbrella
chart is still the placeholder `REPLACE_WITH_REAL_N8N_LICENSE_KEY`.

---

---

## Kubernetes Dashboard

**URL:** `https://dashboard.<sub>.<base>/`
**Login:** Bearer token (no basic auth — the bearer-token requirement is the auth).

**Recommended path — kubeconfig upload (paste-handler-bug-proof):**

`cluster-bootstrap.sh` auto-generates `~/dashboard-kubeconfig.yaml` on EC2 with the long-lived token embedded. Pull it down once:

```bash
scp -i $GRAPHWISE_KEY $GRAPHWISE_USER@$GRAPHWISE_HOST:~/dashboard-kubeconfig.yaml ~/Downloads/
```

On the Dashboard login screen → switch radio to **Kubeconfig** → "Choose kubeconfig file" → select `~/Downloads/dashboard-kubeconfig.yaml` → Sign In. Same kubeconfig works forever (until you revoke the underlying token).

**Or paste the raw token** (Chrome and Safari sometimes silently swallow paste — use the kubeconfig path if so):

```bash
kubectl -n kubernetes-dashboard get secret dashboard-admin-token -o jsonpath='{.data.token}' | base64 -d ; echo
```

The `dashboard-admin` ServiceAccount is bound to `cluster-admin` (sees everything). The token is materialized into a long-lived `dashboard-admin-token` Secret of type `kubernetes.io/service-account-token` by `cluster-bootstrap.sh`. To revoke: `kubectl -n kubernetes-dashboard delete secret dashboard-admin-token`. To rotate periodically instead, the ephemeral form `kubectl -n kubernetes-dashboard create token dashboard-admin --duration=8760h` works too (max 1 year per kube-apiserver default).

**Smoke test:** load the URL, basic-auth prompt → enter `demo / rdf#rocks` → Dashboard's bearer-token screen → paste token → land on the cluster overview showing all namespaces.

## Prometheus

**URL:** `https://prometheus.<sub>.<base>/`
**Login:** Basic auth — `demo` / `rdf#rocks` (Prometheus has no auth of its own; the basic-auth gate is the only protection)

Raw Prometheus UI: PromQL query, targets list, alerts. Useful for ad-hoc queries; for dashboards use Grafana.

**Smoke test:** load the URL, log in, click "Status → Targets" — should show kube-state-metrics, node-exporter, kubelet, prometheus-operator, and the kube-prometheus-stack components all `UP`.

## Grafana

**URL:** `https://grafana.<sub>.<base>/`
**Login:** Grafana's own session-cookie auth — `admin` / `demo-graphwise-2026`. No basic auth in front (the session cookie covers tab switches; basic auth on top kept re-prompting).

Ships with ~30 pre-built K8s dashboards from kube-prometheus-stack: cluster compute resources, namespace overview, pod resource consumption, kubelet metrics, etcd, API server. Browse via Dashboards → Browse → "default" folder.

**Smoke test:** log in, Dashboards → Browse → open "Kubernetes / Compute Resources / Cluster" — graphs should populate within ~30s of clicking.

**Rotating the Grafana admin password:** edit `charts/observability/kube-prometheus-stack-values.yaml` → `grafana.adminPassword` and re-run `./scripts/cluster-bootstrap.sh`. Or rotate inside Grafana's user settings (chart re-applies the file's value on the next bootstrap, so do both if you want it durable).

---

## Credentials reference

The complete list of every credential in the deployed stack, grouped
by purpose. Defaults are demo-grade — rotate everything before exposing
to anyone who shouldn't have admin.

### A. User-facing logins

What you'll actually type into a UI or sign-in dialog.

| Where | User | Password | Source |
|---|---|---|---|
| Keycloak master realm (admin console) | `poolparty_auth_admin` | `admin` | `charts/graphwise-stack/values.yaml` → `keycloak.bootstrapAdmin.{username,password}` |
| Keycloak `poolparty` realm (PoolParty / ADF / SW SSO) | `superadmin` | `poolparty` | `charts/keycloak-realms/files/poolparty-realm.json` (baked into Ontotext image) |
| Keycloak `graphrag` realm (chatbot SSO) | `alice` | `alice123` | `charts/keycloak-realms/values.yaml` → `graphrag.users` |
| Keycloak `graphrag` realm | `bob` | `bob123` | same |
| GraphViews (direct, no SSO) | `superadmin` | `poolparty` | uses PoolParty API creds |
| GraphDB embedded / GraphDB projects / RDF4J ingress | `demo` | `rdf#rocks` | `scripts/cluster-bootstrap.sh` (htpasswd) |
| Prometheus ingress (basic auth) | `demo` | `rdf#rocks` | `scripts/cluster-bootstrap.sh` (`GRAPHWISE_BASIC_AUTH_HTPASSWD`) |
| Grafana app login | `admin` | `demo-graphwise-2026` | `charts/observability/kube-prometheus-stack-values.yaml` → `grafana.adminPassword` |
| Kubernetes Dashboard | bearer token / kubeconfig | permanent | `~/dashboard-kubeconfig.yaml` on the EC2; `kubectl -n kubernetes-dashboard get secret dashboard-admin-token -o jsonpath='{.data.token}' \| base64 -d ; echo` |
| UnifiedViews (app-local) | `admin` | `admin` | UnifiedViews image default |
| n8n owner | (set on first visit) | (set on first visit) | n8n's own DB |

### B. Internal service-to-service secrets

Pod-to-pod authentication. You don't type these into anything; they
live in Kubernetes Secrets that pods mount. Listed so you can confirm
what's deployed and rotate cleanly. **All defaults below are
`rdf#rocks` for demo-grade simplicity.**

| Secret | Default | Source |
|---|---|---|
| Keycloak CNPG Postgres — superuser password | `rdf#rocks` | `charts/graphwise-stack/values.yaml` → `keycloak.postgres.superuserPassword` |
| Keycloak CNPG Postgres — app user (`keycloak`) | `rdf#rocks` | `charts/graphwise-stack/values.yaml` → `keycloak.postgres.appPassword` |
| n8n CNPG Postgres — superuser password | `rdf#rocks` | `charts/graphwise-stack/values.yaml` → `n8nPostgres.superuserPassword` |
| n8n CNPG Postgres — app user (`n8n`) | `rdf#rocks` | `charts/graphwise-stack/values.yaml` → `n8nPostgres.appPassword` |
| GraphRAG conversation Postgres app password (`graphrag_conversation`) | `rdf#rocks` | `charts/graphwise-stack/values.yaml` → `graphrag-secrets.conversation.dbPassword` |
| GraphRAG n8n DB credential (consumed by graphrag-workflows) | `rdf#rocks` | `charts/graphwise-stack/values.yaml` → `graphrag-secrets.n8nDatabase.password` |
| Conversation API → Keycloak `conversation-api-client` clientSecret | `rdf#rocks` | `charts/graphwise-stack/values.yaml` → `graphrag-secrets.conversationKeycloak.clientSecret` AND `keycloak-realms.graphragConversationClientSecret` (must match) |
| n8n encryption key (DB-stored credential symmetric key) | auto-generated | Terraform `random_id.n8n_encryption_key` → `~/graphwise-secrets.yaml` overlay; never edit `values.yaml` for this |

The n8n encryption key MUST stay constant after first n8n boot — n8n
encrypts every saved connection with it; rotating breaks every stored
credential. Terraform's empty `keepers = {}` block ensures the value is
stable across re-applies (regenerates only on `terraform destroy` +
re-apply, which also wipes the n8n DB so the new key is fine).

### C. User-supplied secrets (you provide these)

All operator-supplied secrets except license files live in **one
file** on the EC2 host: `~/graphwise-secrets.yaml` (auto-created by
Terraform cloud-init with placeholders, gitignored, never tracked).
`reset-helm.sh` reads it for the maven creds and passes it to Helm
via `-f` for the rest. Keep a copy on your laptop and re-push via
`scripts/laptop/push-secrets.sh` after every `terraform destroy/apply`
cycle so secrets survive rebuilds without re-typing.

| Secret | Placeholder | What you provide | Source |
|---|---|---|---|
| Maven registry username | `""` | from Graphwise registry email | EC2: `~/graphwise-secrets.yaml` → `maven.user` |
| Maven registry password | `""` | same | EC2: `~/graphwise-secrets.yaml` → `maven.pass` |
| AWS Bedrock access key ID | `""` | Access Key ID for the `graphrag-bedrock` IAM user from SETUP §4b | EC2: `~/graphwise-secrets.yaml` → `graphrag-secrets.awsCredentials.accessKeyId` |
| AWS Bedrock secret access key | `""` | matching secret | same → `secretAccessKey` |
| AWS Bedrock region | `us-west-2` | a region with `cohere.embed-english-v3` | same → `region` |
| n8n Enterprise activation key | `""` | from your Graphwise n8n license email | EC2: `~/graphwise-secrets.yaml` → `graphrag-secrets.n8nLicense.activationKey` |
| n8n encryption key | (auto-generated by Terraform) | DO NOT EDIT | EC2: `~/graphwise-secrets.yaml` → `graphrag-secrets.n8nEncryption.key` |
| PoolParty license key | (none) | vendor binary | EC2: `files/licenses/poolparty.key` |
| GraphDB license file | (none) | vendor binary | EC2: `files/licenses/graphdb.license` |
| UnifiedViews license key | (none) | vendor binary | EC2: `files/licenses/uv-license.key` |

### D. Where the rendered console pulls from

The apex landing page (`https://<sub>.<base>/`) shows a subset of the
above for quick reference. Defaults live in
`charts/console/values.yaml` → `credentials:` and are re-rendered on
every `helm upgrade` (so changing a default in `values.yaml` →
running `reset-helm.sh` updates the page automatically). Internal
secrets (group B) are not displayed on the page; consult this guide
for the full list.

> **Demo grade.** Every password ships as a default. Rotate before
> exposing the deployment to anyone who shouldn't have admin.

---

## Connecting to the EC2

```bash
# Plain SSH (default)
ssh -i $GRAPHWISE_KEY $GRAPHWISE_USER@$GRAPHWISE_HOST

# AWS CLI EC2 Instance Connect -- AWS pushes a temp key, then SSH from
# your laptop (no SG change needed). Requires the inline IAM policy
# from SETUP §9 Method 1.
aws ec2-instance-connect ssh --instance-id <i-xxxxxxxxxxxxxxxxx> --private-key-file $GRAPHWISE_KEY
```

The Console "Connect" tab (browser-based Instance Connect) does
**not** work against the default SG — the connection comes from
AWS's `EC2_INSTANCE_CONNECT` service IP range, not your laptop. See
[SETUP §9](SETUP.md#9-optional-ec2-instance-connect) for both
methods (CLI + browser) and the manual SG rule the browser path
needs.

---

## Lifecycle commands

Two Helm releases (`graphwise-stack` in `graphwise` ns;
`graphrag` in `graphrag` ns). See [CLAUDE.md §Two Helm
releases](CLAUDE.md#two-helm-releases) for the rationale.

```bash
# Operators (one-time per cluster)
LE_EMAIL=you@example.com ./scripts/cluster-bootstrap.sh

# Realm JSON for PoolParty (one-time, re-run on image bumps)
./scripts/extract-poolparty-realm.sh

# License Secrets (after dropping files/licenses/*)
./scripts/install-licenses.sh

# Install / reinstall both releases.
# Uninstall order: graphrag, then umbrella.
# Install order:   umbrella, then graphrag.
./scripts/reset-helm.sh <subdomain>          # interactive — type 'reset' to proceed
./scripts/reset-helm.sh --yes <subdomain>    # non-interactive

# Politely shut workloads down before stopping the EC2 (optional;
# prints the AWS CLI command after quiescing)
./scripts/cluster-stop.sh

# After EC2 stop/start, restart the cluster
./scripts/cluster-resume.sh
```

`reset-helm.sh` deletes every PVC in the `graphwise`, `keycloak`,
and `graphrag` namespaces — wipes Keycloak realms, both GraphDB
repos, all PoolParty projects, and all GraphRAG state.

For non-destructive chart edits, upgrade in place:

```bash
# Umbrella only
helm upgrade graphwise-stack ./charts/graphwise-stack -n graphwise -f charts/graphwise-stack/values.yaml -f /tmp/values-<sub>.yaml --timeout 15m

# GraphRAG only
helm upgrade graphrag ./charts/vendor/graphrag -n graphrag -f charts/vendor/graphrag/values-graphwise.yaml -f /tmp/values-<sub>-graphrag.yaml --timeout 15m
```

---

## If something breaks (top-level runbook)

0. **SSH to EC2 fails immediately after `scp` and won't reconnect**
   → corporate endpoint security (Elastic Defend, CrowdStrike, etc.)
   on the laptop is inspecting outbound port-22 and tearing down the
   stream. Workarounds in order of preference: try from a personal
   laptop / phone hotspot to confirm; ask IT to whitelist the EIP;
   investigate `mosh` (UDP, not subject to the same TCP inspection);
   or add the manual EC2 Instance Connect SG rule (one-time Console
   step) and use the Console "Connect" tab — see
   [SETUP.md §9](SETUP.md#9-optional-ec2-instance-connect--manual-sg-rule).

1. **`kubectl` returns `connection refused 127.0.0.1:6443` after a
   reboot** → KIND node containers stopped.
   `./scripts/cluster-resume.sh`.
2. **PoolParty 500 / pod stuck `0/1` looping on Keycloak
   discovery** → first verify
   `kubectl get certificate -n keycloak` shows
   `graphwise-keycloak-tls READY=True`. If no cert exists, the
   umbrella's keycloak Ingress (in
   `templates/keycloak-ingress.yaml`) may not have been applied —
   `helm get manifest graphwise-stack -n graphwise | grep
   keycloak-ingress`. After cert is good, confirm
   `curl -s https://auth.<sub>.<base>/realms/master/.well-known/openid-configuration | jq -r .issuer`
   reads exactly `https://auth.<sub>.<base>/realms/master`.
2a. **PoolParty browser login bounces / shows `Internal Error` after
    Keycloak sign-in** → the per-client Authorization Services config
    didn't import. The Keycloak operator's `KeycloakRealmImport` CR
    silently drops the `.clients[].authorizationSettings` block; the
    umbrella works around this with a post-install Job
    (`charts/keycloak-realms/templates/keycloak-authz-import-job.yaml`)
    that POSTs the authz config back via the admin REST API. Check it
    ran: `kubectl get job -n keycloak | grep authz-import` (should be
    `1/1` Completions). Logs: `kubectl logs -n keycloak job/keycloak-authz-import`.
    If the Job is missing, your chart pre-dates the fix — `git pull`
    on the EC2 + re-run `reset-helm.sh`. If the Job ran but PoolParty
    still loops, manually verify `ppt` client has the resource-server
    config: see "Manual recovery" snippet at the end of this runbook.
3. **PoolParty `Unauthorized HTTP 401` during init
   (RoleServiceFacade)** → master-realm `poolparty_auth_admin` user
   missing or password wrong. The `keycloak-bootstrap-admin` Helm
   hook should create it on every install/upgrade
   (`kubectl -n keycloak get jobs` — it self-deletes on success).
   If the user really is missing, follow [CLAUDE.md](CLAUDE.md)
   §"Bootstrap admin user" to create it manually with `kcadm`.
4. **Wildcard cert stuck `READY=False`** →
   `kubectl describe certificate -n cert-manager wildcard-tls | tail -30`. Usually
   the DNS-01 challenge failed because the EC2 instance role can't write
   to the Route 53 hosted zone (`kubectl describe order -n cert-manager`
   surfaces the AWS error), or LE rate limit hit on rapid reissues.
4a. **App Ingress shows browser TLS error but wildcard cert is Ready** →
   reflector hasn't mirrored the Secret. Check
   `kubectl get secret wildcard-tls -A` (should show 6 namespaces) and
   `kubectl get pods -n kube-system -l app.kubernetes.io/name=reflector`.
5. **`ImagePullBackOff` on graphrag pods** → the `graphwise`
   image-pull secret didn't get created. Check
   maven.user/maven.pass in `~/graphwise-secrets.yaml` then re-run
   `./scripts/cluster-bootstrap.sh`. Also confirm:
   `kubectl -n graphrag get secret graphwise`.
6. **Realm import didn't happen / `auth.<sub>.<base>/realms/poolparty`
   returns 404** → `kubectl get keycloakrealmimport -A`. The CRs
   must be in the `keycloak` namespace (where the operator
   watches), not `graphwise`. If they're in the wrong namespace,
   `helm dependency update ./charts/graphwise-stack` and re-run
   `helm upgrade` (the templates pin namespace to `keycloak`).
7. **GraphRAG chatbot returns nothing on first message** → Bedrock
   IAM problem. Check `kubectl -n graphrag logs
   deployment/graphrag-components --tail=30`. If
   `AccessDeniedException`, the `graphrag-bedrock` IAM user policy
   doesn't include the model used (`cohere.embed-english-v3`).
8. **Background / deeper troubleshooting** → [CLAUDE.md](CLAUDE.md)
   §"Architecture" + §"Currently open issues".
