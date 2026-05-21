# AdeptNova GraphDB — Public-Accessible Third Instance (RC2)

**Status:** Design — pending review
**Target release:** `graphwise-stack` chart `1.0.0-rc2`
**Author:** Kent Stroker
**Date:** 2026-05-21

## Problem

The stack currently runs two GraphDB instances (`graphdb-embedded` in `graphwise` ns, `graphdb-projects` in `graphdb` ns). Both are reachable only via the HTTPS reverse proxy with nginx basic auth — direct port `7200` is bound to `127.0.0.1` on the EC2 host per the security model documented in `infra/terraform/main.tf:220-223`.

AdeptNova (and future demos with similar shape) needs a GraphDB endpoint reachable **directly on a TCP port from a restricted set of public IPs**, without going through the basic-auth reverse-proxy path. The two existing instances must not change — they back PoolParty and the projects workbench, both of which are stable.

## Goals

1. Add a third GraphDB instance, isolated from the existing two.
2. Expose it publicly on a fixed TCP port, restricted by AWS Security Group CIDR allowlist.
3. Keep an HTTPS subdomain Ingress for browser admin (mirrors `graphdb-projects` UX).
4. GraphDB-native security enabled (defense-in-depth — SG is outer ring, GraphDB auth is inner ring).
5. Reuse every existing pattern (alias-aware fullname helper, namespaced install, license Secret per namespace, `wildcard-tls` reflector cert, `render-values.sh` host derivation).
6. Land in `1.0.0-rc2` — a cluster recreate is acceptable.

## Non-goals

- Replacing the existing `graphdb-projects` instance.
- Changing the basic-auth model on the two existing instances.
- Production-hardening the AdeptNova instance beyond CIDR allowlist + GraphDB-native auth (this is still a demo stack).
- Replicating any data into AdeptNova — it starts empty; AdeptNova operators load their own.

## Architecture

```
External AdeptNova client (in allowed CIDR)
  │
  ▼
EIP : 17200            ← aws_security_group_rule (cidr_blocks = var.adeptnova_cidrs)
  │
  ▼
EC2 host : 17200       ← Docker → KIND container port mapping
  │
  ▼
KIND node : 31720      ← extraPortMappings in infra/kind/kind-config.yaml
  │
  ▼
Service graphwise-stack-graphdb-adeptnova (NodePort 31720 → 7200)
  in namespace graphdb-adeptnova
  │
  ▼
Pod: graphdb (image: ontotext/graphdb:11.3.3, GraphDB-native security ON)


Browser admin (separate path)
  │
  ▼
EIP : 443
  │
  ▼
ingress-nginx → Ingress host: graphdb-adeptnova.<sub>.<base>
  │  (basic-auth Secret + wildcard-tls)
  ▼
Service graphwise-stack-graphdb-adeptnova : 7200
  │
  ▼
Same pod
```

Two ingress paths, one pod. The direct `:17200` path is auth'd by GraphDB itself (HTTP Basic against GraphDB's user DB). The Ingress path is auth'd by nginx basic-auth *and* GraphDB itself (double prompt; acceptable for the admin path because it's used rarely).

## Components

### 1. Chart wiring

**`charts/graphwise-stack/Chart.yaml`** — third alias of the existing `charts/graphdb/` subchart:

```yaml
- name: graphdb
  alias: graphdb-adeptnova
  version: 1.0.0-rc2
  repository: file://../graphdb
  condition: graphdb-adeptnova.enabled
```

Helm installs the same chart three times under three different alias keys; the chart's `_helpers.tpl` already includes `.Chart.Name` in the fullname (per the rule in `CLAUDE.md` "GraphDB subchart fullname must keep `.Chart.Name`"), so the three release-scoped fullnames are distinct.

**`charts/graphwise-stack/values.yaml`** — new top-level block:

```yaml
graphdb-adeptnova:
  enabled: true
  namespace: graphdb-adeptnova
  externalUrl: ""           # filled by render-values.sh
  ingress:
    host: ""                # filled by render-values.sh — graphdb-adeptnova.<sub>.<base>
  service:
    type: NodePort
    port: 7200
    nodePort: 31720
  security:
    enabled: true
    # admin user/password seeded by a post-install Job, sourced from
    # the per-namespace graphdb-adeptnova-admin Secret (see §3).
```

### 2. Subchart extensions (`charts/graphdb/`)

Two additions, both gated so the existing `graphdb-embedded` / `graphdb-projects` instances remain byte-identical to today's rendered manifests.

**a. `service.type` + `service.nodePort` plumbing**

`charts/graphdb/templates/service.yaml` currently hardcodes `ClusterIP`. Change to:

```yaml
spec:
  type: {{ .Values.service.type | default "ClusterIP" }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: 7200
      protocol: TCP
      name: http
      {{- if and (eq .Values.service.type "NodePort") .Values.service.nodePort }}
      nodePort: {{ .Values.service.nodePort }}
      {{- end }}
```

`charts/graphdb/values.yaml` default stays `type: ClusterIP` (no `nodePort`), so the two existing instances render identically. Verified by `helm template --debug` diff before and after, captured in the implementation plan.

**b. GraphDB-native security init Job**

`charts/graphdb/templates/security-init-job.yaml` (new file, gated on `.Values.security.enabled`):

- Helm hooks: `post-install,post-upgrade`, `hook-weight: 5`, `hook-delete-policy: before-hook-creation,hook-succeeded`.
- Pattern: mirrors `charts/addons/templates/uv-password-reset-job.yaml` (UnifiedViews password reset).
- Steps (exact API sequence to be confirmed against GraphDB 11.3.3 docs during implementation — see "Open questions"):
  1. Wait for the GraphDB Service to answer `/rest/repositories` (curl loop, 90s timeout).
  2. Enable security and seed the admin password from the `graphdb-adeptnova-admin` Secret, using whichever of the two GraphDB 11 patterns is supported:
     - **Pattern A** (security-off-first): create/replace the admin user via `POST /rest/security/users/admin` (no auth required while security is off), then `POST /rest/security` body `true` to flip security on.
     - **Pattern B** (security-on-first): `POST /rest/security` body `true` (creates default `admin/admin`), then `PUT /rest/security/users/admin` authenticated as `admin/admin` to set the password from the Secret.
- The Secret is created by `scripts/install-licenses.sh` (it already creates per-namespace Secrets; one more is trivial). Key names: `username` / `password`. Default password: `rdf#rocks` (per the repo's default-password convention in CLAUDE.md).
- Job is idempotent in either pattern — re-running against an already-secured server with the correct admin credentials is a no-op.

Rationale for an init Job over an initContainer: GraphDB's REST security endpoints require the server to be fully up and the cluster API to be reachable; an initContainer would race the main container's startup probe. The hook pattern is what the existing `uv-password-reset` Job uses for the same reason.

### 3. KIND port mapping

`infra/kind/kind-config.yaml` — append to the existing node's `extraPortMappings`:

```yaml
- containerPort: 31720
  hostPort: 17200
  protocol: TCP
  listenAddress: "0.0.0.0"
```

`listenAddress: "0.0.0.0"` is explicit (vs the default) because the existing `:7200`/`:7201` admin-tunnel pattern binds to `127.0.0.1` — being explicit here documents that this one is intentionally public.

**Cluster recreate required.** KIND can't add port mappings to a live cluster. This is why the change is RC2-scoped — anyone moving to RC2 reruns `cluster-bootstrap.sh` from scratch.

### 4. Security group rule

**`infra/terraform/variables.tf`** — new variable:

```hcl
variable "adeptnova_cidrs" {
  type        = list(string)
  default     = []
  description = "CIDR ranges allowed to reach the AdeptNova GraphDB on host port 17200. Empty list disables the SG rule (instance still listens but is unreachable externally)."
}
```

**`infra/terraform/main.tf`** — standalone resource, not an inline `ingress` block:

```hcl
resource "aws_security_group_rule" "adeptnova_graphdb" {
  count             = length(var.adeptnova_cidrs) > 0 ? 1 : 0
  type              = "ingress"
  from_port         = 17200
  to_port           = 17200
  protocol          = "tcp"
  cidr_blocks       = var.adeptnova_cidrs
  security_group_id = aws_security_group.stack.id
  description       = "AdeptNova GraphDB direct (host :17200 -> KIND :31720)"
}
```

This must be a standalone `aws_security_group_rule` resource, not an inline `ingress {}` block inside `aws_security_group.stack`, because that SG has `lifecycle { ignore_changes = [ingress] }` (set at `infra/terraform/main.tf:274-276` to preserve operator-added Console rules like Instance Connect). Standalone rule resources are managed independently of the SG's inline blocks, so `ignore_changes` doesn't apply to them.

**`infra/terraform/outputs.tf`** — add `graphdb_adeptnova` to the URLs output:

```hcl
graphdb_adeptnova         = "https://graphdb-adeptnova.${var.subdomain}.${var.base_domain}/"
graphdb_adeptnova_direct  = length(var.adeptnova_cidrs) > 0 ? "http://${local.public_ip}:17200/" : "(disabled - var.adeptnova_cidrs is empty)"
```

### 5. HTTPS Ingress on subdomain

No new template work. `charts/graphdb/templates/ingress.yaml` is already in use by both existing instances. With `ingress.host: graphdb-adeptnova.<sub>.<base>` rendered into the values file, it generates an Ingress that:

- Uses the existing `wildcard-tls` Secret (reflector mirrors it into `graphdb-adeptnova` ns automatically — the reflector pattern is documented in `docs/claude/tls-and-ingress.md`).
- Adds nginx basic auth from the chart's auto-generated `graphwise-stack-graphdb-adeptnova-basic-auth` Secret (default `demo:rdf#rocks` from the chart default).
- Routes to the same in-cluster Service the NodePort uses.

**DNS:** the `*.<sub>.<base>` wildcard A-record already in place covers `graphdb-adeptnova.<apex>` — no new DNS work.

### 6. Script changes

**`scripts/cluster-bootstrap.sh`** — alongside the existing `graphdb` namespace creation:

```bash
kubectl create namespace graphdb-adeptnova --dry-run=client -o yaml | kubectl apply -f -
```

Reflector annotation isn't needed on the namespace — the `wildcard-tls` Secret in `cert-manager` ns is annotated to mirror to all namespaces matching the existing pattern.

**`scripts/install-licenses.sh`** — third namespace receives the license Secret, plus a new admin Secret:

```bash
# Third GraphDB instance (AdeptNova)
kubectl -n graphdb-adeptnova create secret generic graphdb-license \
  --from-file=graphdb.license="$LICENSES_DIR/graphdb.license" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n graphdb-adeptnova create secret generic graphdb-adeptnova-admin \
  --from-literal=username=admin \
  --from-literal=password='rdf#rocks' \
  --dry-run=client -o yaml | kubectl apply -f -
```

The admin password is `rdf#rocks` by default (per CLAUDE.md's default-password convention); operators rotate by editing the Secret then bouncing the pod.

**`scripts/render-values.sh`** — emit the `graphdb-adeptnova:` block:

```yaml
graphdb-adeptnova:
  externalUrl: https://graphdb-adeptnova.${APEX}/
  ingress:
    host: graphdb-adeptnova.${APEX}
```

`service.type`, `service.nodePort`, `security.enabled`, `namespace` come from `charts/graphwise-stack/values.yaml` and don't need per-deploy override.

**`scripts/reset-helm.sh`** — add `graphdb-adeptnova` to the namespace wipe list (the `graphwise`, `graphdb`, `graphrag` enumeration around line 196-210).

**`scripts/validate-stack.sh`** — add:
- Pod readiness check in `graphdb-adeptnova` ns.
- HTTPS reachability + cert check for `graphdb-adeptnova.$APEX`.
- License Secret presence check in `graphdb-adeptnova` ns.
- Admin Secret presence check.
- Info-level message that direct `:17200` is SG-gated and won't necessarily be reachable from the validator's vantage point (don't fail on it).

### 7. Order of operations

Install order (extends the existing convention in `scripts/reset-helm.sh`):

1. `cluster-bootstrap.sh` — creates `graphdb-adeptnova` ns alongside the others.
2. `install-licenses.sh` — populates `graphdb-license` + `graphdb-adeptnova-admin` Secrets in the new ns.
3. `helm upgrade --install graphwise-stack …` — chart creates Service (NodePort) + Pod; security-init Job flips `/rest/security` to true after the pod is Ready.
4. `helm upgrade --install graphrag …` — unchanged.

Uninstall order — unchanged. AdeptNova instance lives under the umbrella release, so `helm uninstall graphwise-stack` tears it down with the other two.

## Data flow

**AdeptNova client (allowed CIDR) → triple-store:**

1. Client opens TCP to `<EIP>:17200`.
2. SG rule allows the source CIDR.
3. EC2 NIC delivers to host `:17200`.
4. Docker port-publish forwards to KIND container `:31720`.
5. KIND container's iptables (kube-proxy mode) routes to the NodePort Service.
6. Service load-balances to the single pod's `:7200`.
7. GraphDB challenges with HTTP Basic; client provides admin credentials; request proceeds.

**Browser admin:**

1. Browser opens `https://graphdb-adeptnova.<sub>.<base>/`.
2. nginx-ingress matches the host, presents the wildcard cert from `wildcard-tls`.
3. nginx basic-auth prompt → `demo:rdf#rocks`.
4. Backend Service → pod `:7200`.
5. GraphDB challenges with HTTP Basic → admin login.

## Error handling

- **License Secret missing:** Pod stays in `CreateContainerConfigError`. `validate-stack.sh` catches it with the existing license-presence check.
- **Admin Secret missing:** Pod starts; security-init Job fails on the auth step. The Job has `backoffLimit: 3`; after failure, `helm install` returns non-zero. Run `scripts/install-licenses.sh` to populate, then `helm upgrade` re-triggers the hook.
- **SG rule mis-CIDR'd:** AdeptNova clients can't connect. Diagnose with `aws ec2 describe-security-groups` showing the live rule, then `terraform plan` / `terraform apply` to fix.
- **KIND extraPortMapping forgotten:** Service is up but `:17200` from outside times out (Docker isn't publishing 17200). Symptom: SG check passes, port still unreachable. Fix is to recreate the KIND cluster — `cluster-resume.sh` doesn't help here because the mapping has to be declared at cluster create time.
- **GraphDB-native security flip failed before completion:** Possible if the pod restarts mid-Job. The Job is idempotent — both endpoints are PUT/POST with explicit state, safe to re-run. `helm upgrade` retriggers.

## Testing

After RC2 deploy on a test EIP with `adeptnova_cidrs = ["<my-laptop>/32"]`:

1. **Direct API path (allowed CIDR):**
   `curl -u admin:'rdf#rocks' http://<EIP>:17200/rest/repositories` — returns `200 []` (empty repo list).
2. **Direct API path (no auth):**
   `curl http://<EIP>:17200/rest/repositories` — returns `401 Unauthorized` (GraphDB-native security is on).
3. **Direct API path (non-allowed CIDR):**
   From a host outside the CIDR (e.g. a different laptop on cellular tether), `curl` times out — SG drops.
4. **Browser admin:**
   `https://graphdb-adeptnova.<apex>/` — nginx basic-auth prompt → demo:rdf#rocks → GraphDB login screen → admin:rdf#rocks → workbench.
5. **`validate-stack.sh`** — passes all AdeptNova checks.
6. **Existing instances unchanged:**
   `helm get manifest graphwise-stack -n graphwise` diffed against RC1 output shows no field changes to the embedded/projects Services or Ingresses (only additions for AdeptNova). Captured as a checkpoint in the implementation plan.

## Migration / rollback

- **Migration from RC1:** This is a fresh-cluster change. Operators upgrading from RC1 to RC2 follow the existing "stop cluster, snapshot data, fresh bootstrap" path documented in `DEPLOY.md`. Existing data on the two RC1 instances is preserved via the same PVC backup pattern (out of scope here).
- **Rollback:** Set `graphdb-adeptnova.enabled: false` in values, `helm upgrade`, then `kubectl delete ns graphdb-adeptnova`. SG rule survives — remove it with `terraform apply` after setting `adeptnova_cidrs = []`. KIND port mapping stays in `kind-config.yaml`; harmless if no NodePort is listening on 31720.

## Documentation updates

- `CLAUDE.md` — add `graphdb-adeptnova` to the subdomain table; add a one-liner under "Critical rules" noting that `:17200` is the public direct path and lives behind a CIDR-allowlisted SG rule.
- `docs/claude/chart-internals.md` — extend the GraphDB three-alias section.
- `CONSOLE-GUIDE.md` — new entry for the AdeptNova URL + credentials.
- `infra/README.md` — document `var.adeptnova_cidrs` in the variable table.
- `infra/terraform/terraform.tfvars.example` — show `adeptnova_cidrs = []` with a comment about what to set it to.

## Open questions

1. **GraphDB 11.3.3 security-init API sequence.** Verify against the GraphDB 11 REST API reference whether Pattern A (create user while security is off, then enable) or Pattern B (enable security, then change the default admin password) is supported. Pattern B is more conservative because it doesn't depend on a writable user endpoint when security is off, but it requires the Job to know that the seed password is `admin` before the change. The implementation plan will pick one and code only that path.
