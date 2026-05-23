# HOWITWORKS — The Graphwise Stack on AWS, Plain English

**Audience:** anyone operating this stack who hasn't worked with Kubernetes, Docker, KIND, Helm, or cert-manager day-to-day. Skip whatever you already know; the sections stand on their own.

**Goal:** by the end you understand what's running, where it lives, how a browser request reaches an app, how TLS happens automatically, and where to look first when something breaks.

For specific commands, see [QUICKSTART.md](QUICKSTART.md). For credentials and per-app URLs, [CONSOLE-GUIDE.md](CONSOLE-GUIDE.md). For incident history and decisions, [CLAUDE.md](CLAUDE.md).

---

## 1. What this stack is

A **single AWS EC2 instance** that hosts the entire Graphwise + GraphRAG demo. Inside that instance, layered like Russian dolls:

- **AWS EC2** — one VM (Amazon Linux 2023 ARM64, `r6g.2xlarge`).
- **Docker** — the container runtime running on the VM.
- **KIND** — "Kubernetes IN Docker". It runs an entire Kubernetes cluster as Docker containers on the host.
- **Kubernetes** — the orchestrator. Hosts every app, database, secret, and network rule.
- **Workloads** — PoolParty, GraphDB (×2), Keycloak, Postgres (×2), GraphRAG (chatbot/conversation/components/workflows), the supporting addons, and observability (Prometheus/Grafana/Dashboard).

Why this stack-of-stacks: a single EC2 stays cheap (~$0.34/hr running, ~$30/mo storage stopped) and entirely self-contained — no managed Kubernetes service, no AWS load balancer, no RDS. Demo-grade by design.

---

## 2. The big picture

```
                Your laptop
                     │
                     │ HTTPS
                     ▼
       ┌──────────────────────────────┐
       │      AWS Elastic IP          │   ◄── pre-allocated;
       │   54.x.x.x  (your stable IP) │       DNS records point here
       └──────────────┬───────────────┘
                      │
                      ▼
       ┌──────────────────────────────┐
       │  EC2 instance (AL2023 ARM64) │   ◄── one VM
       │  ┌────────────────────────┐  │
       │  │  Docker daemon         │  │   ◄── container runtime
       │  │  ┌──────────────────┐  │  │
       │  │  │ KIND control-    │  │  │   ◄── one Docker container
       │  │  │ plane container  │  │  │       running an entire K8s
       │  │  │  ┌────────────┐  │  │  │       control plane + node
       │  │  │  │ Kubernetes │  │  │  │
       │  │  │  │  - pods    │  │  │  │   ◄── PoolParty, GraphDB ×2,
       │  │  │  │  - services│  │  │  │       Keycloak, GraphRAG, etc.
       │  │  │  │  - secrets │  │  │  │
       │  │  │  └────────────┘  │  │  │
       │  │  └──────────────────┘  │  │
       │  └────────────────────────┘  │
       └──────────────────────────────┘
```

**The clever bit:** the host's port 80/443 is mapped *into* the KIND container. Inside that container runs **ingress-nginx**, a single web server that fans every incoming request out to the right app pod based on the URL's hostname. One door, dozens of rooms behind it.

---

## 3. Container layering — three nesting levels

```
host process tree:
   docker  ──►  kind-control-plane container (one Linux box)
                  ├─ kubelet       (the K8s node agent)
                  ├─ containerd    (a SECOND container runtime, inside)
                  │    ├─ pod: ingress-nginx
                  │    ├─ pod: graphwise-stack-graphdb-embedded-0
                  │    ├─ pod: graphwise-stack-poolparty-...
                  │    ├─ pod: graphwise-keycloak-0
                  │    └─ ... ~30 pods total
                  ├─ kube-apiserver, kube-scheduler, etc.
                  └─ /var/run/docker.sock (NOT used; KIND owns its own)
```

**Containers inside containers.** Docker on the EC2 host runs *one* container (the KIND control-plane). Inside that container is `containerd`, a second container runtime, which runs every pod. Pods themselves are groups of one or more containers sharing a network namespace.

You'll see two `docker ps`-able things:
- On the host: one container named `graphwise-control-plane`. That's KIND.
- Inside the cluster (`kubectl get pods -A`): the actual workloads.

`kubectl exec -it <pod> -- bash` drops you all the way through both layers into a workload.

---

## 4. The critical flow — how a browser request reaches a pod

This is the most important diagram in the document. Trace any URL request through it.

```
┌─────────────────────────────────────────────────────────────────────┐
│ Browser:  https://poolparty.stroker.semantic-proof.com/PoolParty/   │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                │ DNS lookup
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│ DNS:  poolparty.stroker.semantic-proof.com  →  54.149.12.34         │
│       (resolved via the wildcard A record  *.<sub>.<base>)          │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                │ TCP 443
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│ AWS Elastic IP  54.149.12.34  (attached to the EC2 instance)        │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│ EC2 host  --  port 443 is forwarded into the KIND container         │
│ (this mapping is set in infra/kind/kind-config.yaml)                │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│ KIND control-plane container  --  port 443 hits the                 │
│ ingress-nginx-controller pod (a single nginx process)               │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                │ TLS handshake
                                │ -- nginx looks up cert by SNI/Host:
                                │    "poolparty.stroker.semantic-proof.com"
                                │    -- finds graphwise-stack-poolparty-tls Secret
                                │    -- presents the LE cert
                                │ Once TLS is up, parses HTTP Host header
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│ ingress-nginx config:  Host=poolparty.<apex>  →                     │
│   Service: graphwise-stack-poolparty (port 8081)                    │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Kubernetes Service  graphwise-stack-poolparty                       │
│   --  cluster-internal load balancer                                │
│   --  picks one pod from `app=poolparty` set                        │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Pod  graphwise-stack-poolparty-<hash>-<hash>  -- the actual         │
│ Spring Boot Java process serving PoolParty                          │
└─────────────────────────────────────────────────────────────────────┘
```

**Five hops.** When something breaks, it's almost always one of these. The "where does it break" runbook in §11 below uses this same chain.

---

## 5. Why every app gets its own subdomain

Each app is reachable at `<app>.<sub>.<base>`:

- `poolparty.stroker.semantic-proof.com`
- `auth.stroker.semantic-proof.com`
- `graphdb.stroker.semantic-proof.com`
- `graphdb-projects.stroker.semantic-proof.com`
- `graphrag.stroker.semantic-proof.com`
- `dashboard.stroker.semantic-proof.com`
- `prometheus.stroker.semantic-proof.com`
- `grafana.stroker.semantic-proof.com`
- ...and so on

**Why?** Three reasons:

1. **One TLS cert per app.** Each app's Ingress carries its own `tls:` block; cert-manager mints a separate Let's Encrypt cert per host. No giant SAN list to manage.
2. **No URL prefix surgery.** Each app serves at its own root, not at `<apex>/poolparty/` or `<apex>/graphrag/`. Apps don't have to know they're behind a reverse proxy.
3. **ingress-nginx routes by Host header (SNI).** The single nginx process looks at the incoming `Host` header (and TLS SNI), looks up its config, sends the request to the matching backend Service. No app has to know about any other app's URL.

**DNS setup is just two records:**
- `<sub>.<base>` → EIP (the apex, for the console landing page)
- `*.<sub>.<base>` → EIP (the wildcard, for every per-app subdomain)

Without the wildcard, every per-app subdomain returns NXDOMAIN and nothing works.

---

## 6. TLS — how Let's Encrypt certs happen automatically

You never run certbot. You never copy `.pem` files anywhere. cert-manager does it all, driven by the Ingress objects in Kubernetes. Here's what's actually happening.

**The cast:**

- **cert-manager** — a controller running in the `cert-manager` namespace. Watches Certificate resources.
- **ClusterIssuer** — a recipe for getting certs. We use **only `letsencrypt-prod` via DNS-01 against Route 53**. One wildcard cert (`<sub>.<base>` + `*.<sub>.<base>`) covers every Ingress in the stack. See [CLAUDE.md → TLS architecture](CLAUDE.md) for rationale.
- **DNS-01 challenge** — Let's Encrypt's way of proving you own the domain: cert-manager writes a `_acme-challenge.<host>` TXT record into the Route 53 hosted zone; LE reads it back to confirm zone ownership. Required for wildcard certs (HTTP-01 can't issue wildcards).
- **kubernetes-reflector** — a tiny operator that watches Secrets carrying `reflector.v1.k8s.emberstack.com/reflection-*` annotations and copies them into target namespaces. We use it to mirror the single `wildcard-tls` Secret from `cert-manager` into every consuming namespace (`graphwise`, `graphrag`, `keycloak`, `kubernetes-dashboard`, `monitoring`).

**The dance, end-to-end** (happens once at `cluster-bootstrap.sh` time, and on cert renewal ~60 days later):

```
1. cluster-bootstrap.sh creates a Certificate resource named
   wildcard-tls in the cert-manager namespace, with two SANs:
   <apex> + *.<apex>
       │
       ▼
2. cert-manager creates an Order with Let's Encrypt for those SANs
       │
       ▼
3. Order produces a Challenge resource per SAN with a token
       │
       ▼
4. cert-manager (via the AWS SDK + EC2 instance metadata + the
   instance role's Route 53 policy) writes a TXT record at
   _acme-challenge.<apex> in the Route 53 hosted zone
       │
       ▼
5. cert-manager tells LE: "ready, please validate"
       │
       ▼
6. LE queries DNS for _acme-challenge.<apex> from its own resolvers
       │   -- Route 53 returns the token cert-manager wrote
       │   -- LE sees the expected token. Zone ownership confirmed.
       ▼
7. LE issues the wildcard cert. cert-manager stores it in the
   wildcard-tls Secret in the cert-manager namespace.
       │
       ▼
8. cert-manager removes the TXT record (cleanup).
       │
       ▼
9. kubernetes-reflector sees the new Secret + its reflection
   annotations, and copies wildcard-tls into all 5 consuming
   namespaces (graphwise / graphrag / keycloak /
   kubernetes-dashboard / monitoring).
       │
       ▼
10. ingress-nginx watches Secrets. Every Ingress with
    tls.secretName: wildcard-tls picks up the cert.
       │
       ▼
11. Browser visits https://poolparty.<apex>/PoolParty/ -- valid
    cert (wildcard SAN matches), handshake succeeds, app loads.
```

The whole chain takes ~60–90 seconds total. The wildcard issues once; every Ingress (poolparty, auth, graphrag, dashboard, ...) is covered by the single Secret reflected into its namespace.

**Port 80 is still open** for ingress-nginx's plain-HTTP→HTTPS redirect, but DNS-01 doesn't use it — Route 53 handles validation entirely off-band. (Pre-wildcard, when we used HTTP-01, port 80 had to be reachable; with DNS-01 it's purely operator-convenience for `http://...` typos that auto-redirect.)

**To check cert status at any time:** `kubectl get certificate -n cert-manager wildcard-tls`. Should be `READY=True`. Anything stuck in `False` means the DNS-01 challenge failed — usually the EC2 instance role can't write to the Route 53 zone (`kubectl describe order -n cert-manager` will surface the AWS error).

**To verify reflection:** `kubectl get secret wildcard-tls -A` should list it in 6 namespaces (cert-manager + the 5 reflected). Missing rows = reflector pod isn't running (`kubectl get pods -n kube-system -l app.kubernetes.io/name=reflector`).

---

## 7. The Keycloak Ingress quirk

This one bit us early and is worth knowing.

**Why:** the Keycloak operator (v26.x) auto-generates an Ingress for the Keycloak instance. When `spec.http.httpEnabled: true` (which we need — TLS terminates at ingress-nginx, Keycloak speaks plain HTTP internally), the operator's auto-Ingress has **no `tls:` block**. cert-manager's ingress-shim only mints a Certificate when an Ingress has both the annotation AND a `tls:` block. So no cert. So no working `https://auth.<apex>/`. So every OIDC-consuming app fails on startup.

**How we fix it:**

- `charts/graphwise-stack/templates/keycloak.yaml` sets `spec.ingress.enabled: false` — operator stops creating its Ingress.
- `charts/graphwise-stack/templates/keycloak-ingress.yaml` ships **our own** Ingress with the right `tls:` block + cert-manager annotation, pointing at the Keycloak operator's Service.

**Symptom if regression:** `kubectl get certificate -n keycloak` shows nothing or a not-Ready entry. Browser at `https://auth.<apex>/` shows a TLS error. Every OIDC-using pod (PoolParty, ADF, Semantic Workbench, GraphRAG conversation API) fails to start.

---

## 8. Helm + the umbrella chart

**Helm is templating + lifecycle for Kubernetes YAML.** A "chart" is a directory of templated YAML files; `helm install` renders them with your values and applies them; `helm upgrade` does the same against an existing release; `helm uninstall` removes everything tagged with that release name.

```
charts/graphwise-stack/         ◄── the umbrella chart
├── Chart.yaml                  ◄── lists subchart dependencies
├── values.yaml                 ◄── shared values cascading to subcharts
├── templates/                  ◄── umbrella's own resources
│   ├── keycloak.yaml           ◄── Keycloak CR (operator-managed)
│   ├── keycloak-ingress.yaml   ◄── the custom Ingress (see §7)
│   ├── keycloak-bootstrap-admin-job.yaml
│   ├── n8n-postgres.yaml       ◄── CNPG cluster for n8n
│   └── graphrag-secrets.yaml   ◄── Secrets the graphrag pods mount
└── charts/                     ◄── subchart tarballs
    ├── poolparty/
    ├── graphdb-embedded/       ◄── (alias of graphdb)
    ├── graphdb-projects/       ◄── (alias of graphdb)
    ├── poolparty-elasticsearch/
    ├── addons/                 ◄── ADF, Semantic Workbench, GraphViews, RDF4J, UnifiedViews, Refine
    ├── console/                ◄── apex landing page
    └── keycloak-realms/        ◄── KeycloakRealmImport CRs
```

**Subchart aliases.** The graphdb subchart is included twice under different aliases (`graphdb-embedded`, `graphdb-projects`) to give two completely independent GraphDB instances — same code, separate state, separate Service names, separate Ingresses.

**Two releases, not one.** GraphRAG (chatbot/conversation/components/workflows) is **NOT** a subchart. It installs as a separate Helm release in the `graphrag` namespace (driven by `scripts/reset-helm.sh`). Why: vendored GraphRAG charts default their resources to the release namespace, and the GraphRAG pods need to live in `graphrag` so they can mount Secrets the umbrella creates there. Pods can only mount Secrets from their own namespace.

**`scripts/reset-helm.sh` enforces both install and uninstall ordering**: umbrella first on install (so it creates the supporting Secrets), graphrag first on uninstall (so pods stop mounting before the Secrets get deleted).

---

## 9. OIDC + the Keycloak issuer-match invariant

PoolParty, ADF, Semantic Workbench, and GraphRAG conversation API all do single sign-on through Keycloak using OpenID Connect (OIDC). The login flow looks like this:

```
1. Browser visits https://poolparty.<apex>/PoolParty/
2. PoolParty redirects browser to Keycloak (https://auth.<apex>/realms/poolparty/...)
3. Browser authenticates with Keycloak (username/password)
4. Keycloak redirects browser back to PoolParty with an auth code
5. PoolParty (server-side) exchanges the code with Keycloak for an access token
6. PoolParty validates the access token (a JWT) -- specifically, checks
   that the `iss` claim equals what it expects
7. If iss matches: session established, app loads
   If iss doesn't match: PoolParty throws, returns the user back to step 2 -> redirect loop
```

**The invariant:** Spring Security's `NimbusJwtDecoder.withIssuerLocation()` does a **strict equality check** on the `iss` claim. The URL it expects must equal the issuer in the token, **byte for byte**.

For us, that means every app's OIDC config must use exactly `https://auth.<sub>.<base>/realms/<realm>` — not `https://auth.<sub>.<base>/auth/realms/<realm>` (legacy Keycloak path), not with a trailing slash, not via a different hostname.

**The Keycloak side has to match too:**

```bash
# Quick check that the issuer is what apps expect:
curl -s https://auth.<sub>.<base>/realms/poolparty/.well-known/openid-configuration | jq -r .issuer
# Must read exactly:  https://auth.<sub>.<base>/realms/poolparty
```

Setting `spec.hostname.hostname: auth.<sub>.<base>` (no `/auth` path) and `strict: true` on the Keycloak CR makes Keycloak emit the issuer claim at the right value.

**Bonus complication: the Ontotext realm export.** It ships with `${POOLPARTY_KEYCLOAK_LOGIN_CLIENTSECRET}` and `${POOLPARTY_SUPER_ADMIN_PASSWORD}` literal placeholders that the operator's KeycloakRealmImport CR doesn't substitute. `scripts/extract-poolparty-realm.sh` rewrites them to real values at extract time. The realm's per-client `authorizationSettings` block (resources, scopes, policies) ALSO gets dropped during the operator's import — `charts/keycloak-realms/templates/keycloak-authz-import-job.yaml` re-imports them via REST as a post-install hook. Both are needed for PoolParty's UMA permission ticket flow to work.

---

## 10. Day-2 lifecycle — what survives what

| Action | What survives | What's lost |
|---|---|---|
| `aws ec2 stop-instances` (then start later) | EBS volume (root disk + all PVCs), EIP, DNS records, Helm releases, K8s state | KIND node container's `Running` state — needs `./scripts/cluster-resume.sh` after `start-instances` |
| `./scripts/cluster-stop.sh` (graceful pre-stop) | Same as above + cleanly drained app workloads | Nothing extra |
| `./scripts/reset-helm.sh --yes <sub>` | KIND cluster + operators (cert-manager, ingress-nginx, CNPG, Keycloak operator), license Secrets | All app PVCs in graphwise/keycloak/graphrag (data wipe), all cert-manager-issued cert Secrets (will re-issue on reinstall) |
| `terraform destroy` (with `existing_eip_allocation_id` set) | EIP, DNS records, key pair | EC2 instance (entire VM), security group, root EBS, KIND, every Helm release, all data |
| `terraform destroy` (without `existing_eip_allocation_id`) | DNS records (now stale), key pair | EVERYTHING above + EIP itself (DNS becomes invalid, you'll redo it) |

**Persistence cheat-sheet:** the EBS volume on the EC2 holds everything important (PVCs, license files, Maven creds, the cloned repo). EC2 stop just pauses it. EC2 terminate (or terraform destroy) wipes it.

---

## 11. Staging data — the universal upload path

For multi-GB ingest data (PDFs, source documents, reference corpora that GraphRAG / PoolParty pipelines consume), there's a standardized landing pad at `~/staging-data/` on the EC2. Cloud-init creates the directory; you `rsync` data into it from your laptop:

```bash
# laptop -- if rsync is missing on macOS, install via `brew install rsync`
# (Apple ships openrsync since Ventura which has compat quirks).
rsync -azP -e "ssh -i $GRAPHWISE_KEY" ~/local-pdfs/ $GRAPHWISE_USER@$GRAPHWISE_HOST:~/staging-data/
```

For one-off small files or stable links where you don't want to install rsync, plain `scp -r` works as a fallback (no resume support, no compression):

```bash
# laptop -- fallback
scp -r -i $GRAPHWISE_KEY ~/local-pdfs/ $GRAPHWISE_USER@$GRAPHWISE_HOST:~/staging-data/
```

Files survive EC2 stop/start, KIND restart, `reset-helm.sh`. They do **NOT** survive `terraform destroy` (the root EBS volume goes with the instance).

### Three layers between EC2 disk and pod filesystem

The data sits on the EC2 disk by default but is invisible to pods until three layers are wired. All three must exist before a pod sees the files:

```
┌───────────────────────────────────────────────────────────┐
│ Layer 1: EC2 host                                         │
│   /home/ec2-user/staging-data/   (real files on EBS)      │
└─────────────────────────┬─────────────────────────────────┘
                          │  Docker bind-mount (Docker -v),
                          │  declared in infra/kind/kind-config.yaml
                          ▼
┌───────────────────────────────────────────────────────────┐
│ Layer 2: KIND control-plane container                     │
│   /staging-data/  (same files, different path inside)     │
└─────────────────────────┬─────────────────────────────────┘
                          │  Kubernetes hostPath PV,
                          │  bound 1:1 to a namespaced PVC
                          ▼
┌───────────────────────────────────────────────────────────┐
│ Layer 3: Pod (e.g. graphrag-workflows-xxx)                │
│   /data/staging/  (volumeMount path the app reads from)   │
└───────────────────────────────────────────────────────────┘
```

### Layer 1 → Layer 2: KIND extraMount

`infra/kind/kind-config.yaml` declares which host paths are visible inside the KIND container. KIND turns this into a Docker `-v` flag at cluster create time:

```yaml
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: /home/ec2-user/staging-data
        containerPath: /staging-data
```

**KIND can't add mounts to a running cluster.** Adding this requires `kind delete cluster` + `kind create cluster` — destructive (wipes all K8s state including PVCs). Schedule with the next planned `reset-helm.sh` cycle, not as a hotfix.

### Layer 2 → Layer 3: PersistentVolume + PersistentVolumeClaim

PVs are cluster-scoped (no namespace); PVCs are namespaced. A PVC binds 1:1 to a PV. Pods in a namespace mount via the PVC.

For pods in `graphrag` namespace:

```yaml
# Cluster-scoped: tells K8s "/staging-data inside the node is a volume"
apiVersion: v1
kind: PersistentVolume
metadata:
  name: staging-data-graphrag-pv
spec:
  capacity:
    storage: 50Gi          # nominal; hostPath doesn't enforce
  accessModes:
    - ReadWriteMany        # multi-pod read+write OK on a single-node KIND
  persistentVolumeReclaimPolicy: Retain   # don't delete files on PVC delete
  storageClassName: hostpath-staging      # sentinel; no provisioner
  hostPath:
    path: /staging-data    # path INSIDE the KIND container
    type: Directory
---
# Namespaced: pods in graphrag bind to this name
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: staging-data
  namespace: graphrag
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 50Gi
  storageClassName: hostpath-staging
  volumeName: staging-data-graphrag-pv    # pin to the specific PV
```

Note `volumeName` — without it, K8s would try to dynamically provision a new volume from the storageClass, fail (no provisioner exists for the sentinel `hostpath-staging`), and the PVC would stay `Pending` forever.

**For multiple namespaces, create one PV+PVC pair per namespace.** PVs are 1:1 with PVCs, so you need a separate PV per claim — but all PVs point at the same `hostPath: /staging-data`. So you'd have:

- `staging-data-graphrag-pv` ↔ PVC `staging-data` in `graphrag`
- `staging-data-graphwise-pv` ↔ PVC `staging-data` in `graphwise`

All look at the same underlying files. Pods across namespaces see identical data.

### Layer 3: Pod-level mount

The PVC is wired into a pod's spec via `volumes` (chart side) and `volumeMounts` (container side):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: graphrag-workflows
  namespace: graphrag
spec:
  template:
    spec:
      containers:
        - name: workflows
          # ...
          volumeMounts:
            - name: staging
              mountPath: /data/staging      # path INSIDE the pod
              readOnly: false               # set true if appropriate
      volumes:
        - name: staging
          persistentVolumeClaim:
            claimName: staging-data
```

Inside the pod, `ls /data/staging/` shows your uploaded files.

### Where this lands in the chart (deferred)

When a concrete consumer is identified:

1. **`infra/kind/kind-config.yaml`** — add the extraMount (one-line change).
2. **`charts/graphwise-stack/templates/staging-data.yaml`** (new) — renders the per-namespace PV+PVC pairs. Gated by `staging.enabled`. Namespace list from `staging.namespaces` (default `[graphwise, graphrag]`). Size from `staging.size` (default `50Gi`).
3. **Consumer subchart's pod spec** — add the `volumes`/`volumeMounts` stanzas referencing PVC `staging-data`. Most vendored charts expose `extraVolumes`/`extraVolumeMounts` values for this exact pattern.

### Checklist when ready to apply

```text
1. Edit infra/kind/kind-config.yaml      (add extraMount)
2. Edit charts/graphwise-stack/values.yaml  (add staging block)
3. Add charts/graphwise-stack/templates/staging-data.yaml  (PV + PVC)
4. Edit consumer subchart values         (volumes + volumeMounts)
5. On EC2:
     kind delete cluster --name graphwise
     kind create cluster --config infra/kind/kind-config.yaml --name graphwise
6. cluster-bootstrap.sh                  (re-install operators)
7. extract-poolparty-realm.sh + install-licenses.sh
8. reset-helm.sh --yes <subdomain>       (re-install workloads with the volume wired)
9. Verify:
     kubectl get pv,pvc -A | grep staging       -> Bound
     kubectl exec -n graphrag <pod> -- ls /data/staging   -> your files
```

Steps 5-8 are the same destructive bring-up as a fresh install. Plan accordingly — schedule when other workloads aren't depended on.

---

## 12. When something breaks — symptom → first command

| Symptom | First command | Why it helps |
|---|---|---|
| Browser shows TLS error on any URL | `kubectl get certificate -n cert-manager wildcard-tls` + `kubectl get secret wildcard-tls -A` | `False` means DNS-01 challenge failed (EC2 instance role can't write to Route 53? rate limit?). Missing reflected Secret = reflector pod not running. |
| Browser hangs on any URL | `dig +short <host>` from your laptop | Confirm DNS resolves to your EIP. If wrong, fix DNS first. |
| `dig` returns the EIP but request times out | `kubectl get pod -n ingress-nginx` | ingress-nginx pod must be Running. If not, KIND is broken. |
| ingress-nginx is up but request times out | `kubectl get ingress -A` | Confirm an Ingress exists for the Host you're hitting. If missing, the chart didn't render that piece. |
| HTTP 502/503 from a specific app | `kubectl get pod -n <ns> -l app.kubernetes.io/name=<app>` | App pod isn't Ready. Check its logs. |
| OIDC redirect loop | `curl -s https://auth.<apex>/realms/<realm>/.well-known/openid-configuration \| jq -r .issuer` | Issuer must equal `https://auth.<apex>/realms/<realm>` exactly. Anything else breaks Spring Security. |
| PoolParty `Internal Error` after Keycloak sign-in | `kubectl get job -n keycloak \| grep authz-import` | The authz-import Job restores per-client authorization settings. If missing or Failed, PoolParty's UMA flow breaks. See CONSOLE-GUIDE runbook §2a. |
| `kubectl` returns `connection refused 127.0.0.1:6443` after EC2 reboot | `./scripts/cluster-resume.sh` | KIND node containers stopped at reboot. Resume restarts them and pins `--restart=unless-stopped` so future reboots don't recur. |
| Pod shows `0/1 Running` for >2 minutes | `kubectl describe pod -n <ns> <pod>` then `kubectl logs ...` | `describe` shows readiness-probe failures and recent events; `logs` shows the app's own complaint. |
| `terraform apply` wants to destroy/replace `aws_instance.stack` | **STOP** | The AMI `most_recent` lookup resolved a newer AMI. Don't apply unscoped. See `infra/README.md` Safety section + ensure `ami_override` is set per DEPLOY §1.5. |

---

## 13. Where to go next

- **Stand up the stack from scratch:** [QUICKSTART.md](QUICKSTART.md). Sequential 0-18 step list, every command marked `# laptop` or `# EC2`.
- **Detail on any prerequisite step:** [SETUP.md](SETUP.md). IAM users, EIP allocation, DNS records, key pair, Bedrock, the EC2 Instance Connect manual SG rule.
- **Detail on the deploy walkthrough:** [DEPLOY.md](DEPLOY.md). Same as QUICKSTART but with rationale and where-each-command-runs callouts.
- **Per-app credentials and URLs:** [CONSOLE-GUIDE.md](CONSOLE-GUIDE.md). Every login the stack ships with, plus a top-level runbook.
- **Architecture deep dive + decision history:** [CLAUDE.md](CLAUDE.md). Why the GraphDB subchart was renamed, why GraphRAG is its own release, why Keycloak needs a custom Ingress, the SSH-after-scp incident, the AMI-lock saga, and other context for anyone modifying the chart.
- **Terraform module reference:** [infra/README.md](infra/README.md). Module variables, outputs, the Safety section for post-provision applies.
