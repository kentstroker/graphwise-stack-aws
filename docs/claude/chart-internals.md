# Chart internals — wiring patterns, post-install Jobs, KIND lifecycle

Detail backing the chart-internals references in `CLAUDE.md`. Keycloak-specific Jobs are in `keycloak.md`.

## GraphDB subchart fullname pattern (alias-aware) + namespace split

`charts/graphdb/` is installed twice in the umbrella as subchart aliases (`graphdb-embedded`, `graphdb-projects`) to give two independent GraphDB instances. The fullname helper in `charts/graphdb/templates/_helpers.tpl` uses `printf "%s-%s" .Release.Name .Chart.Name` so the aliases produce distinct resource names:

- `graphwise-stack-graphdb-embedded` (Service, StatefulSet, Ingress, TLS Secret) — lives in `graphwise` namespace.
- `graphwise-stack-graphdb-projects` (same set) — lives in **`graphdb` namespace** (split out for logical separation).

**Namespace split.** `charts/graphdb/values.yaml` exposes a `namespace` value that defaults to empty (falls back to release namespace). Every template's `metadata.namespace` reads `{{ .Values.namespace | default .Release.Namespace }}`. The umbrella sets `graphdb-projects.namespace: graphdb` so its resources land there; the embedded alias leaves it empty so it inherits `graphwise` (the release namespace). Why split: graphdb-embedded MUST stay in `graphwise` because PoolParty's `internalUrl` in `charts/poolparty/values.yaml` uses bare-name service resolution (`http://graphwise-stack-graphdb-embedded:7200`) — bare names only resolve in-namespace. graphdb-projects has no in-cluster client requiring bare-name resolution; user-facing access goes through the public Ingress; PoolParty / UnifiedViews configure it as a remote endpoint at user level (UI-driven), using either the public URL or the cross-namespace Service URL `http://graphwise-stack-graphdb-projects.graphdb:7200`.

The `graphdb` namespace is created by `cluster-bootstrap.sh`. The `graphdb-license` Secret is installed there too by `install-licenses.sh` (one license file → two namespaces; Ontotext licenses by hardware, not Secret count). The wildcard-tls Secret is mirrored into `graphdb` by reflector (annotations on the Cert in `cluster-bootstrap.sh` list `graphdb` as a target).

If you ever change the fullname helper, **don't drop the `.Chart.Name` part** — both aliases share `.Release.Name` (the parent umbrella's release name), so a `.Release.Name`-only fullname collapses both into the same `graphwise-stack` and the second alias silently overwrites the first in the rendered manifest. PoolParty's `internalUrl` in `charts/poolparty/values.yaml` points at the prefixed `http://graphwise-stack-graphdb-embedded:7200`; if you rename the helper output pattern, update PoolParty's URL in lockstep.

## GraphDB JVM heap (set explicitly; not auto-sized to pod limit)

`charts/graphdb/values.yaml` sets `javaOpts: "-Xmx8g"` and `resources.limits.memory: 10Gi` — leaves ~2Gi of pod memory for non-heap (metaspace, threads, off-heap caches, OS overhead). `charts/graphdb/templates/statefulset.yaml` wires the value as the `GDB_JAVA_OPTS` env var; the image's `/opt/graphdb/dist/bin/graphdb` script forwards it as `java <opts>`.

**Why this is set explicitly:** without `-Xmx`, GraphDB's JVM defaults to ~1Gi heap regardless of the pod memory limit. The container has more memory available, but the JVM has no way to know — `cgroups`-aware heap sizing is a Java feature, but GraphDB's launcher script overrides it. Symptom of "JVM doesn't know about the pod limit": queries with `GROUP BY` / `DISTINCT` aggregations fail with `Insufficient free Heap Memory NNNMb for group by and distinct, threshold:250Mb, reached 0Mb` — and `kubectl top pod` shows the container nowhere near its limit. Burned a deploy on this 2026-05-14.

**Rule of thumb:** JVM heap = pod memory limit − 2Gi. Both umbrella aliases (`graphdb-embedded` in `graphwise` ns, `graphdb-projects` in `graphdb` ns) inherit from this subchart default — one edit covers both. To override per-alias, the umbrella's `graphdb-embedded:` / `graphdb-projects:` blocks can set their own `javaOpts:` / `resources:`.

## Staging-data three-layer wiring (universal ingest path)

Multi-GB ingest data (PDFs, source documents, reference corpora the GraphRAG pipeline consumes) lives at the standardized path `/home/ec2-user/staging-data/` on the EC2. Cloud-init creates the directory on first boot. The path is exposed to Kubernetes pods via a three-layer mount chain (full diagram in HOWITWORKS.md §11):

1. **EC2 host:** `/home/ec2-user/staging-data/` (real files on EBS, created by `infra/terraform/user-data.sh.tpl`).
2. **KIND container:** mounted at `/staging-data` via `extraMounts` in `infra/kind/kind-config.yaml`. **Adding this requires `kind delete cluster` + `kind create cluster`** — KIND can't add mounts to a running cluster. Schedule with the next planned `reset-helm.sh` cycle, never as a hotfix.
3. **Pod:** PVC named `staging-data` per consuming namespace. `charts/graphwise-stack/templates/staging-data.yaml` renders one hostPath PV + one PVC per entry in `.Values.staging.namespaces` (default `[graphwise, graphrag]`). PVs use a sentinel `storageClassName: hostpath-staging` (no provisioner) and `claimRef`-pre-bind to their specific PVC; PVCs pin via `volumeName`. Both pre-binding mechanisms are required — without either, PVCs would stay `Pending` while K8s tried (and failed) to dynamically provision against the sentinel storage class.

Operator workflow: `rsync -azP -e "ssh -i $GRAPHWISE_KEY" <local>/ $GRAPHWISE_USER@$GRAPHWISE_HOST:~/staging-data/`. Files survive EC2 stop/start, KIND restart, `reset-helm.sh`. Do NOT survive `terraform destroy` (root EBS goes with the instance).

Pods are not auto-volumeMounted to `staging-data` by default — consuming workloads (graphrag-workflows, graphrag-components, etc.) add `volumes` + `volumeMounts` referencing PVC `staging-data` in their own namespace when ready. Toggle the entire feature off via `staging.enabled: false` in umbrella values.

## Console landing page — Helm `tpl` pattern

`charts/console/files/index.html` is a Helm template (rendered at install time via `tpl` in `charts/console/templates/configmap.yaml`). Apex hostname (`{{ $apex }}` = `<sub>.<base>`) and credential strings (`{{ .Values.credentials.* }}`) substitute at render time, so the deployed landing page always reflects current chart values — change a default in `charts/console/values.yaml` or the umbrella's override, run `helm upgrade`, the page is updated.

Credentials block in `charts/console/values.yaml` documents WHERE each credential is sourced from elsewhere (e.g. Grafana password lives in `charts/observability/kube-prometheus-stack-values.yaml`; basic-auth password is set by `cluster-bootstrap.sh`). Keep these in sync.

A JS hostname-rewrite hook at the bottom of index.html is a safety net: if the page is reached via a different hostname than what was rendered (proxy, internal LB rebrand), every link self-rewrites at page load. Don't rely on it as the primary mechanism — the `tpl` substitution is the authoritative path.

CONSOLE-GUIDE.md is the human-readable canonical reference for credentials (user-facing logins + internal service-to-service secrets + user-supplied secrets). Cross-reference both.

## unifiedviews uv-password-reset post-install/upgrade Job

UV's image bootstraps `admin` + `user` accounts on first boot, but the password triple it lays down doesn't decode against any known default — the literal `admin / admin` printed in UV docs does NOT log you in on a clean deploy. UV has no built-in password reset, so the historical recovery dance was: exec into the rdf4j workbench → find the conf graph + user resource URI → `python3 hashlib.pbkdf2_hmac("sha1", b"admin", salt, 100000, 32)` → format as `100000:salt-hex:dk-hex` → DELETE old + INSERT new in the right named graph (`<.../resource/graph/conf>`, NOT the default graph).

`charts/addons/charts/unifiedviews/templates/uv-password-reset-job.yaml` replaces that. It runs on every install + upgrade and SPARQL-resets the admin/admin + user/user passwords by DELETE+INSERTing the password triple in the `conf` graph of the RDF4J `uv` repository. Talks to the rdf4j Service in-cluster (`http://rdf4j:8080/...`) so it bypasses the nginx ingress + basic-auth (rdf4j-workbench has no container-level auth). Waits for the `uv` repo to exist AND for UV's seed admin user triple to be present before patching. Gated by `.Values.passwordReset.enabled` (default true).

## graphrag-vectors-index post-install/upgrade Job

`graphrag-components`'s startup probe hits `/__gtg`, which runs `ElasticSearchVectorHealthCheck`. That health check verifies the `graphrag-vectors` index exists in Elasticsearch; if it doesn't, the probe returns 503 forever and the pod never goes Ready. Pre-Job, every fresh deploy required a manual `kubectl exec ... curl -XPUT` to create the index.

`charts/graphwise-stack/templates/graphrag-vectors-index-job.yaml` PUTs the index automatically: `embedding: dense_vector, dims=1024` (cohere.embed-english-v3 size), `similarity=cosine`. Idempotent — PUT-ing an existing index returns 400 with `resource_already_exists_exception` which the Job treats as success. `hook-weight: 10` (after Keycloak bootstrap weight=5; ES StatefulSet is up by then). Gated on `graphrag-secrets.enabled` AND `graphrag-secrets.vectorDB.vectorStore == "elasticsearch"`.

## Nested-subchart `.tgz` gitignore (footgun avoidance)

`.gitignore` excludes `charts/*/charts/*.tgz` and `charts/*/Chart.lock` because these are PACKAGED snapshots of subchart-of-subchart directories that Helm prefers over the source dir at render time. Committing them creates the silent-stale-tarball footgun: source edits to `charts/addons/charts/unifiedviews/templates/all.yaml` get masked by a stale `charts/addons/charts/unifiedviews-1.0.0.tgz`, the umbrella's own packaging includes BOTH copies, and operators end up debugging "why isn't my chart change taking effect" without realizing two copies exist.

The umbrella's own bundled tarballs (`charts/graphwise-stack/charts/*.tgz` + `charts/graphwise-stack/Chart.lock`) ARE committed deliberately — those are the umbrella's vendored deps, intentionally pinned so deploys don't need network access. Only nested-subchart-of-subchart tarballs are the footgun.

If you ever see addons resources missing expected fields after an edit to `charts/addons/charts/<addon>/`, suspect this. Fix: `rm charts/addons/charts/*.tgz charts/addons/Chart.lock` (now harmless because gitignored), then `helm dependency update charts/graphwise-stack` to repackage the umbrella's addons tarball from clean source. The unifiedviews initContainer fix saga is the canonical example — see `bug-history.md`.

## KIND lifecycle on EC2

KIND nodes are **Docker** containers (we migrated off podman in late 2026 — see the OS-history note in `CLAUDE.md` §"What this repo is"). On EC2 stop/start `docker.service` comes back automatically, but containers without a restart policy stay `Exited` — kubectl then fails with `connection refused on 127.0.0.1:6443`. `scripts/cluster-resume.sh` starts them and sets `--restart=unless-stopped` so the next reboot is a non-event. Run it any time after a fresh boot; it's idempotent.

## Default password convention: `rdf#rocks`

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
