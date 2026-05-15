# DATA-EXPORT — manual data export before `terraform destroy`

**Maintainer:** Kent Stroker
**Status:** RC1-blocker — preliminary research notes. The intent is
to convert these into a `scripts/laptop/pull-data.sh` that pulls
everything in one shot. Until then, this is the manual checklist.

---

## Why this exists

The Graphwise stack is a single-EC2 demo deployment. There is no
automated backup. `terraform destroy` deletes the EC2 and its EBS
root volume, and **everything in the cluster goes with it** — every
PoolParty project, GraphDB repository, Keycloak user/realm, n8n
workflow, Grafana dashboard, ingested document, and chat history.

Survives destroy: the Elastic IP (only if pre-allocated via
`existing_eip_allocation_id`) and Route 53 records. **The
wildcard TLS cert does not survive** — cert-manager itself goes
with the cluster, and re-issuance counts toward the Let's Encrypt
rate limit (5 duplicate certs per registered domain per week).

`scripts/laptop/terraform-destroy.sh` displays a warning gate and
points here. Don't bypass it without doing the exports below.

---

## What to export, by app

### 1. PoolParty projects (the most important thing)

**Source of truth.** Every taxonomy / thesaurus / custom schema /
project history lives here. The embedded GraphDB and the PoolParty
Elasticsearch indices are *derived* from projects — re-importing
projects regenerates both. Back up projects, skip those two.

**Manual (UI)**
- Log in at `https://poolparty.<sub>.<base>/PoolParty/`
- For each project: open it → Project Settings → Export → choose
  TriG (recommended; preserves named graphs).

**Programmatic (REST)**
```
# List projects (returns JSON: id, title, ...)
curl -u superadmin:poolparty https://poolparty.<sub>.<base>/PoolParty/api/projects

# Export one project (TriG body returned)
curl -u superadmin:poolparty -H "Accept: application/x-trig" \
    https://poolparty.<sub>.<base>/PoolParty/api/projects/<projectId>/export \
    > <projectId>.trig
```

**Gotchas**
- TriG includes named graphs for concepts, custom schema, history,
  and workflows. RDF/XML and N-Triples flatten this — only use them
  if you specifically need the simpler shape.
- Bedrock-backed AI features (Build Your Taxonomy etc) are
  configuration-time settings, not exported with projects.

---

### 2. GraphDB — `graphdb-projects` namespace (your data)

The "your data" GraphDB instance — anything you `LOAD INTO ...`'d
during a demo lives here. Distinct from the embedded GraphDB which
mirrors PoolParty (#1, skip).

**Per repository, via curl from your laptop**
```
# List repositories
curl -u demo:rdf#rocks https://graphdb-projects.<sub>.<base>/rest/repositories

# Export one repo as TriG (preserves named graphs)
curl -u demo:rdf#rocks -H "Accept: application/x-trig" \
    "https://graphdb-projects.<sub>.<base>/repositories/<repo>/statements?infer=false" \
    > <repo>.trig
```

**Or via UI**
- `https://graphdb-projects.<sub>.<base>/` → repository → Import &
  Export → Export → TriG.

**Gotchas**
- `infer=false` returns only asserted triples (omits inferred). If
  the repo's reasoning ruleset matters to the consumer, document it
  separately — re-import doesn't replay rules until a query asks.
- The `system` repo holds GraphDB's own metadata. Skip it.

---

### 3. Keycloak realms

Realms (`master`, `poolparty`, `graphrag`) are largely deterministic
from the chart's `KeycloakRealmImport` CRs — but **users created at
runtime, password changes, and any UI-edited client tweaks are not in
the chart**. Without an export, those are lost.

**From the Keycloak pod**
```
kubectl -n keycloak exec deploy/graphwise-keycloak -- \
    /opt/keycloak/bin/kc.sh export \
    --dir /tmp/export --realm poolparty \
    --users realm_file
kubectl -n keycloak cp graphwise-keycloak-XXX:/tmp/export ./keycloak-export/
```

**Gotchas**
- `kc.sh export` requires Keycloak to be **stopped** in older
  versions; v26 supports live export. Confirm before running on the
  live demo.
- Passwords export as hashes; you can re-import them but you can't
  read them back as plaintext.
- Run for each realm separately (or omit `--realm` to export all).

---

### 4. n8n workflows + credentials

**From inside the n8n pod**
```
# Workflows
kubectl -n graphrag exec deploy/graphrag-workflows -- \
    n8n export:workflow --backup --output=/tmp/workflows
# Credentials (decrypted -- handle with care)
kubectl -n graphrag exec deploy/graphrag-workflows -- \
    n8n export:credentials --decrypted --output=/tmp/creds.json

# Pull to laptop
kubectl -n graphrag cp graphrag-workflows-XXX:/tmp/workflows ./n8n-workflows/
kubectl -n graphrag cp graphrag-workflows-XXX:/tmp/creds.json ./n8n-creds.json
```

**Gotchas**
- `--decrypted` is needed if you want creds usable in a fresh n8n
  with a different `N8N_ENCRYPTION_KEY`. **The Terraform-generated
  `n8nEncryption.key` is per-deployment** — without `--decrypted`,
  importing into the new EC2 will silently fail because it can't
  decrypt the credential blobs.
- Execution history is in the n8n Postgres (#7), not the workflow
  export.

---

### 5. Grafana dashboards

Most dashboards are pre-baked by kube-prometheus-stack and will
re-appear on a fresh install. Anything you authored or edited needs
exporting.

**Via Grafana API**
```
# List dashboards
curl -u admin:demo-graphwise-2026 \
    https://grafana.<sub>.<base>/api/search?type=dash-db

# Export one dashboard's JSON
curl -u admin:demo-graphwise-2026 \
    https://grafana.<sub>.<base>/api/dashboards/uid/<uid> \
    | jq '.dashboard' > <slug>.json
```

**Or use `grafana-backup-tool`** (`pip install grafana-backup`):
```
GRAFANA_TOKEN=...  GRAFANA_URL=https://grafana.<sub>.<base>  grafana-backup save
```

---

### 6. UnifiedViews pipelines

UnifiedViews stores config in the in-cluster RDF4J repo
`unified-views`. The UV UI also has a per-pipeline Export action.

**Via UV UI** (per pipeline): `https://unifiedviews.<sub>.<base>/UnifiedViews/`
→ Pipelines → select → Export.

**Via RDF4J backend** (catches everything UV stores):
```
curl -u demo:rdf#rocks -H "Accept: application/x-trig" \
    "https://rdf4j.<sub>.<base>/rdf4j-server/repositories/unified-views/statements" \
    > unified-views.trig
```

**Gotchas**
- The RDF4J export captures pipeline definitions but not run
  history. Run history typically isn't worth preserving for a demo.

---

### 7. GraphRAG conversation history (DuckDB) + n8n Postgres

These are different storage backends — handle separately.

**GraphRAG conversation: DuckDB file on a PVC.** The conversation
service is configured via
`charts/vendor/graphrag-conversation/values.yaml`:
`spring.datasource.url=jdbc:duckdb:/var/lib/graphrag/conversation/duckdb.db`.
Just copy the file out:
```
CONV_POD=$(kubectl -n graphrag get pod -l app.kubernetes.io/name=graphrag-conversation -o name | head -1)
kubectl -n graphrag cp ${CONV_POD#pod/}:/var/lib/graphrag/conversation/duckdb.db ./conversation-duckdb.db
```
DuckDB locks the file while open, so on a busy demo the copy may
catch a snapshot mid-write. Briefly scaling the conversation
deployment to 0 before copying gives you a clean dump:
```
kubectl -n graphrag scale deploy/graphrag-conversation --replicas=0
# wait for pod to terminate
kubectl -n graphrag scale deploy/graphrag-conversation --replicas=1
```
(Confirm the deploy name on your cluster — the chart may render it
differently. Vendored chart, naming subject to change.)

**n8n: Postgres (CNPG-managed).** Workflow execution history,
settings, users — `pg_dump` the n8n cluster:
```
N8N_PG=$(kubectl -n graphrag get pods -l cnpg.io/cluster=graphrag-postgres-n8n,role=primary -o name | head -1)
kubectl -n graphrag exec ${N8N_PG#pod/} -- pg_dump -U n8n n8n > n8n.sql
```

**Gotchas**
- CNPG primary pod name suffix changes if the cluster reconciles
  during your dump. The `role=primary` label is the right selector.
- The conversation chart has commented-out support for a Postgres
  backend — if you switch to that later, replace the DuckDB step
  above with a `pg_dump` analogous to n8n's.

---

### 8. Staging-data (files you `rsync`'d in for ingest)

Plain files. Just rsync them back:
```
rsync -av --progress ec2-user@<eip>:/home/ec2-user/staging-data/ ./staging-data/
```

---

### 9. Things you DON'T need to export

- **Embedded GraphDB** (`graphwise-stack-graphdb-embedded`) —
  derived from PoolParty projects. Re-imports automatically.
- **PoolParty Elasticsearch indices** — search index. Re-built when
  projects are imported.
- **Wildcard TLS cert** — cert-manager regenerates against
  Route 53 DNS-01 on the next bootstrap. Watch the LE rate limit.
- **License files** (`files/licenses/`) — already on your Mac,
  gitignored. `scripts/laptop/push-config.sh` re-pushes them.
- **`~/graphwise-secrets.yaml`** — already on your Mac via
  `scripts/laptop/pull-config.sh` (assuming you've kept it
  current). Re-pushed by `push-config.sh`.

---

## Eventual `pull-data.sh` design sketch

When this becomes a script (`scripts/laptop/pull-data.sh`), it
should:

1. Check what's exportable — query the cluster for the list of
   PoolParty projects, GraphDB repos (both instances), realms, n8n
   workflows, Grafana dashboards, UV pipelines.
2. Mirror the layout of `pull-config.sh`: write to a per-deployment
   directory, e.g. `~/graphwise-data/<sub>.<base>/<timestamp>/`.
3. Per app: skip empty (no projects, no extra dashboards) silently;
   warn on partial failures (one project export fails out of N).
4. Emit a summary at the end: counts per category, total bytes, and
   any failures.
5. Exit non-zero if anything failed — useful for CI/cron.

A `push-data.sh` (the reverse) is a separate piece of work — replay
order matters (Keycloak realms before pods that need OIDC, GraphDB
before PoolParty, etc).

---

## Quick checklist (before `terraform destroy`)

- [ ] PoolParty projects exported (`*.trig`)
- [ ] GraphDB-projects repositories exported (`*.trig`)
- [ ] Keycloak realms exported (each `*.json`)
- [ ] n8n workflows + credentials exported (`workflows/`, `creds.json`)
- [ ] Grafana custom dashboards exported (only if you authored any)
- [ ] UnifiedViews pipelines exported (only if you built any)
- [ ] GraphRAG conversation DuckDB copied (only if conversations matter)
- [ ] n8n Postgres dumped (only if execution history matters)
- [ ] `staging-data/` rsync'd back to laptop
- [ ] `~/graphwise-secrets.yaml` pulled via `pull-config.sh` (current)
- [ ] License files in `files/licenses/` on laptop (current)
