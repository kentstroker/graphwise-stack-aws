# Graphwise Stack — Cheat Sheet

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

**URL:** `https://unifiedviews.<sub>.<base>/`
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
  [SETUP.md §Create the Bedrock IAM user](SETUP.md#6-create-the-bedrock-iam-user-and-verify-access).
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
**Login:** Two layers — first basic auth (`demo` / `rdf#rocks`), then a bearer token.

**Get a token (24-hour validity):**

```bash
kubectl -n kubernetes-dashboard create token dashboard-admin --duration=24h
```

Paste the token into the Dashboard's "Bearer token" login screen.

The `dashboard-admin` ServiceAccount is bound to `cluster-admin` so the token sees everything in the cluster. Tokens expire on the duration you pass; rerun `create token` for a fresh one.

**Smoke test:** load the URL, basic-auth prompt → enter `demo / rdf#rocks` → Dashboard's bearer-token screen → paste token → land on the cluster overview showing all namespaces.

## Prometheus

**URL:** `https://prometheus.<sub>.<base>/`
**Login:** Basic auth — `demo` / `rdf#rocks` (Prometheus has no auth of its own; the basic-auth gate is the only protection)

Raw Prometheus UI: PromQL query, targets list, alerts. Useful for ad-hoc queries; for dashboards use Grafana.

**Smoke test:** load the URL, log in, click "Status → Targets" — should show kube-state-metrics, node-exporter, kubelet, prometheus-operator, and the kube-prometheus-stack components all `UP`.

## Grafana

**URL:** `https://grafana.<sub>.<base>/`
**Login:** Two layers — first basic auth (`demo` / `rdf#rocks`), then Grafana's own login (`admin` / `demo-graphwise-2026`).

Ships with ~30 pre-built K8s dashboards from kube-prometheus-stack: cluster compute resources, namespace overview, pod resource consumption, kubelet metrics, etcd, API server. Browse via Dashboards → Browse → "default" folder.

**Smoke test:** log in, Dashboards → Browse → open "Kubernetes / Compute Resources / Cluster" — graphs should populate within ~30s of clicking.

**Rotating the Grafana admin password:** edit `charts/observability/kube-prometheus-stack-values.yaml` → `grafana.adminPassword` and re-run `./scripts/cluster-bootstrap.sh`. Or rotate inside Grafana's user settings (chart re-applies the file's value on the next bootstrap, so do both if you want it durable).

---

## Credentials reference (quick lookup)

| Where | User | Password | Source |
|---|---|---|---|
| Keycloak master realm (admin console) | `poolparty_auth_admin` | `admin` | `charts/graphwise-stack/values.yaml` → `keycloak.bootstrapAdmin` |
| Keycloak `poolparty` realm (PoolParty / ADF / SW SSO) | `superadmin` | `poolparty` | `charts/keycloak-realms/files/poolparty-realm.json` |
| Keycloak `graphrag` realm (chatbot SSO) | `alice` | `alice123` | `charts/keycloak-realms/values.yaml` → `graphrag.users` |
| Keycloak `graphrag` realm | `bob` | `bob123` | same |
| GraphViews (direct, no SSO) | `superadmin` | `poolparty` | uses PoolParty API creds |
| GraphDB / GraphDB-projects / RDF4J ingress | `demo` | `rdf#rocks` | `charts/graphdb/values.yaml` + `charts/addons/charts/rdf4j/values.yaml` |
| Dashboard / Prometheus / Grafana ingress (basic auth) | `demo` | `rdf#rocks` | `scripts/cluster-bootstrap.sh` (`GRAPHWISE_BASIC_AUTH_HTPASSWD`) |
| Kubernetes Dashboard (after basic auth) | bearer token | (24h) | `kubectl -n kubernetes-dashboard create token dashboard-admin --duration=24h` |
| Grafana app login (after basic auth) | `admin` | `demo-graphwise-2026` | `charts/observability/kube-prometheus-stack-values.yaml` → `grafana.adminPassword` |
| UnifiedViews (app-local) | `admin` | `admin` | UnifiedViews default |
| n8n owner | (set on first visit) | (set on first visit) | n8n's own DB |

> **Demo grade.** Every password ships as a default. Rotate before
> exposing the deployment to anyone who shouldn't have admin.

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
3. **PoolParty `Unauthorized HTTP 401` during init
   (RoleServiceFacade)** → master-realm `poolparty_auth_admin` user
   missing or password wrong. The `keycloak-bootstrap-admin` Helm
   hook should create it on every install/upgrade
   (`kubectl -n keycloak get jobs` — it self-deletes on success).
   If the user really is missing, follow [CLAUDE.md](CLAUDE.md)
   §"Bootstrap admin user" to create it manually with `kcadm`.
4. **Cert stuck `READY=False`** →
   `kubectl describe certificate -A | grep -A3 -E
   'Status:|Message:'`. Usually DNS hasn't propagated to the EIP
   yet, or the HTTP-01 challenge can't reach :80 (security group /
   IP changed).
5. **`ImagePullBackOff` on graphrag pods** → the `graphwise`
   image-pull secret didn't get created. Check
   `~/.ontotext/maven-{user,pass}` then re-run
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
