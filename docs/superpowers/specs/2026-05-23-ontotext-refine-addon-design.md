# Ontotext Refine v1.2 — Addon (RC3)

**Status:** Design — pending review
**Target release:** `graphwise-stack` chart `1.0.0-rc3`
**Author:** Kent Stroker
**Date:** 2026-05-23

## Problem

The stack ships PoolParty + GraphDB ×3 + a handful of Graphwise/Ontotext add-ons (ADF, Semantic Workbench, GraphViews, RDF4J, UnifiedViews) plus the GraphRAG chatbot suite, but has no first-class data-cleaning / RDFization tool. Ontotext **Refine v1.2** (a GraphDB-adapted fork of OpenRefine) closes that gap: load CSV/JSON/Excel, clean and reshape it in a spreadsheet UI, then push the result into GraphDB as RDF.

Refine ships as a single Docker image (`ontotext/refine:1.2.2`) with no published Helm chart. We will write the chart to match the established sub-chart-under-`addons/` pattern.

## Goals

1. Land Refine as a new toggleable add-on, reachable at `https://refine.<sub>.<base>/`.
2. Restrict ingress access to the admin CIDR (the value already in `infra/terraform/terraform.tfvars` as `admin_cidr`) — Refine has no built-in auth and exposes an open admin UI.
3. Persist Refine project data on a PVC so demo state survives pod restarts.
4. Reuse every existing chart pattern (umbrella → addons → sub-chart, `wildcard-tls` reflector, `render-values.sh` host derivation, console landing card).
5. Cut `1.0.0-rc3` for the change. RC3 contains *only* the Refine addition.

## Non-goals

- License/Keycloak/SSO integration — Refine v1.2 requires no license and has no OIDC support.
- Pre-seeding Refine's UI with a default GraphDB connection — Refine has no env var for this; the connection is set per-project in the UI. We document the internal URL; we do not template a `preferences.json`.
- Replacing or modifying any existing add-on.
- Production-hardening beyond CIDR allowlist (consistent with the rest of this demo stack).
- Cluster recreate. Refine can be added with a plain `helm upgrade` — no `kind-config.yaml` / `extraMounts` / `extraPortMappings` change.

## Architecture

```
Browser (source IP in admin_cidr)
  │
  ▼
EIP : 443
  │
  ▼
ingress-nginx → Ingress host: refine.<sub>.<base>
  │  annotations:
  │    nginx.ingress.kubernetes.io/whitelist-source-range: <admin_cidr>
  │  TLS: wildcard-tls (reflected into graphwise ns)
  ▼
Service graphwise-stack-refine (ClusterIP, 7333 → 7333)
  in namespace graphwise
  │
  ▼
Pod: refine (image: ontotext/refine:1.2.2)
  volume: refine-data PVC (20Gi) → /opt/ontorefine/data

Demo data flow:
  Refine UI → user pastes http://graphwise-stack-graphdb-projects:7200
           → push RDF to graphdb-projects
```

## Components

### New: `charts/addons/charts/refine/`

```
Chart.yaml          # name=refine, version=1.0.0-rc3, appVersion=1.2.2
values.yaml         # image, persistence, service, ingress, allowedCidrs, graphdb.internalUrl (display-only)
templates/
  _helpers.tpl      # refine.fullname, refine.labels, refine.selectorLabels, refine.host
  all.yaml          # PVC + Service + Deployment + Ingress
```

`values.yaml` skeleton:

```yaml
image:
  repository: ontotext/refine
  tag: "1.2.2"
  pullPolicy: IfNotPresent
externalUrl: ""                         # https://refine.<sub>.<base> — filled by render-values.sh
allowedCidrs: []                        # filled by render-values.sh from terraform.tfvars admin_cidr
graphdb:
  # Display-only — surfaced on the console card and in CONSOLE-GUIDE.md.
  # Refine has no env var for default GraphDB URL; users paste this into
  # the Refine UI (Settings → Connect to GraphDB) on first use.
  internalUrl: "http://graphwise-stack-graphdb-projects:7200"
service:
  port: 7333
ingress:
  enabled: true
  className: nginx
resources:
  requests:
    cpu: 200m
    memory: 1Gi
  limits:
    memory: 4Gi
persistence:
  enabled: true
  size: 20Gi
  accessMode: ReadWriteOnce
  storageClass: ""
```

`templates/all.yaml` workload (Deployment-only fragment — PVC/Service/Ingress mirror UV):

```yaml
spec:
  replicas: 1
  strategy: {type: Recreate}            # PVC is ReadWriteOnce
  selector:
    matchLabels: {{- include "refine.selectorLabels" . | nindent 6 }}
  template:
    spec:
      containers:
        - name: refine
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: 7333
          resources: {{- toYaml .Values.resources | nindent 12 }}
          volumeMounts:
            - name: data
              mountPath: /opt/ontorefine/data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: {{ include "refine.fullname" . }}-data
```

Ingress annotation (the one Refine-specific bit worth highlighting):

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/whitelist-source-range: {{ join "," .Values.allowedCidrs }}
```

No init containers, no license mount, no Keycloak client, no JVM heap override. First boot in ≤30s on a warm node.

### Modified: `charts/addons/Chart.yaml`

Add a 6th dependency entry:

```yaml
- name: refine
  version: 1.0.0-rc3
  repository: file://./charts/refine
  condition: refine.enabled
```

Bump addons chart `version: 1.0.0-rc2 → 1.0.0-rc3`.

### Modified: `charts/addons/values.yaml`

Add the `refine:` defaults block (matches the skeleton above, with `enabled: true`).

### Modified: `charts/graphwise-stack/values.yaml`

Add to the `addons:` block:

```yaml
addons:
  refine:
    enabled: true
    externalUrl: ""
    allowedCidrs: []
```

Bump umbrella `version: 1.0.0-rc2 → 1.0.0-rc3`.

### Modified: `scripts/render-values.sh`

Two changes:

1. Add `REFINE_HOST="refine.${APEX}"` alongside the existing per-app host variables.

2. Add a new helper block (early in the script) that extracts `admin_cidr` from `infra/terraform/terraform.tfvars`:

```bash
# Cross-layer read: Refine's ingress is CIDR-allowlisted using the same
# CIDR that gates SSH/admin in the Terraform layer. tfvars is the
# source of truth — keep them in sync by reading it here. If tfvars is
# missing or admin_cidr can't be parsed, fall back to 0.0.0.0/0 with a
# WARN; the stack still deploys, just unrestricted.
TFVARS_PATH="${TFVARS_PATH:-$(dirname "$0")/../infra/terraform/terraform.tfvars}"
if [ -f "$TFVARS_PATH" ]; then
    ADMIN_CIDR=$(grep -E '^[[:space:]]*admin_cidr[[:space:]]*=' "$TFVARS_PATH" \
                  | sed -E 's/.*"([^"]+)".*/\1/' | head -n1)
fi
if [ -z "${ADMIN_CIDR:-}" ]; then
    echo "WARN: could not parse admin_cidr from $TFVARS_PATH — Refine ingress will not be CIDR-restricted" >&2
    ADMIN_CIDR="0.0.0.0/0"
fi
```

3. Emit into the umbrella overlay:

```yaml
addons:
  refine:
    externalUrl: "https://${REFINE_HOST}"
    allowedCidrs: ["${ADMIN_CIDR}"]
```

### Modified: `charts/console/files/index.html`

New card between RDF4J and UnifiedViews:

```html
<a class="card" href="https://refine.{{ $apex }}/">
  <div class="title">Ontotext Refine</div>
  <div class="desc">CSV/JSON → RDF cleaning & mapping (v1.2)</div>
  <div class="auth">access &middot; CIDR-restricted (admin_cidr)</div>
  <div class="hint">GraphDB URL for Settings → Connect:<br>
    <code>http://graphwise-stack-graphdb-projects:7200</code></div>
</a>
```

### Modified: `charts/console/files/bookmarks.html`

Mirror the index card with one `<DT><A …>` entry.

### Modified: `CLAUDE.md`

Add a row between RDF4J and UnifiedViews in the subdomain-per-app table:

```
| Refine | `refine.<sub>.<base>` (CIDR-allowlisted) |
```

No change to the "Critical rules" section — there's no known footgun severe enough to warrant one yet. If a footgun emerges during validation, add it then.

### Modified: `CONSOLE-GUIDE.md`

Add the Refine URL block (no credentials line — CIDR-restricted, no auth).

### Modified: `HOWITWORKS.md`

One-line addition to the addons paragraph.

### Modified: `scripts/validate-stack.sh`

Append one HTTPS reachability probe for `https://refine.<sub>.<base>/`. Expect HTTP 200 (when source IP ∈ admin_cidr) or HTTP 403 (when not) — either is a healthy signal that ingress + cert are wired. Anything else (5xx, timeout, NXDOMAIN) is a failure.

## Data flow & state

| State | Where it lives | Lifetime |
|---|---|---|
| Refine projects, uploads, mappings | PVC `refine-data` → `/opt/ontorefine/data` | Persists across pod restarts; wiped by `reset-helm.sh` |
| TLS cert | `wildcard-tls` (reflected into `graphwise`) | Renewed by cert-manager every 60d |
| CIDR allowlist | Ingress annotation, sourced from tfvars | Re-rendered on each `render-values.sh` run |

Refine writes its own state continuously to `/opt/ontorefine/data`. We never template a file at that path — the PVC is exclusively Refine's territory.

## Error handling

| Failure | Detection | Recovery |
|---|---|---|
| Image pull fails | `kubectl describe pod` → ImagePullBackOff | Verify tag exists on Docker Hub; pin to a known-good tag |
| PVC stuck Pending | `kubectl get pvc -n graphwise` | Check default StorageClass; KIND ships one out of the box |
| Ingress 403 from expected IP | `curl -v https://refine.<sub>.<base>/` from the laptop returns 403 | Confirm `admin_cidr` in tfvars matches the laptop's public IP; re-run `render-values.sh` + `helm upgrade` |
| Ingress 5xx or no cert | `kubectl get ingress -n graphwise refine -o yaml` | Confirm `wildcard-tls` Secret exists in `graphwise` ns (reflector should have copied it); check cert-manager Certificate status |
| OOMKill (large projects) | `kubectl get pod -n graphwise -l app=refine` shows `OOMKilled` | Bump `resources.limits.memory` in `charts/addons/charts/refine/values.yaml` and `helm upgrade` |
| Refine UI loads but cannot reach GraphDB | User error: wrong internal URL pasted | Console card + CONSOLE-GUIDE.md document the exact internal URL |

## Testing

End-to-end demo path that exercises every component:

1. `./scripts/reset-helm.sh stroker semantic-proof.com` — fresh full deploy including Refine.
2. `./scripts/validate-stack.sh stroker semantic-proof.com` — passes, including the new Refine probe.
3. Browser → `https://refine.<sub>.<base>/` from a source IP in `admin_cidr` → Refine UI loads.
4. Browser → same URL from a source IP **not** in `admin_cidr` → HTTP 403 from nginx.
5. In Refine UI: create project from a small CSV, define a column mapping, push to GraphDB at `http://graphwise-stack-graphdb-projects:7200`.
6. In `graphdb-projects` workbench: confirm the new RDF triples are present.
7. Restart the Refine pod (`kubectl delete pod -n graphwise -l app=refine`) → projects survive.

## Risks / open footguns

- **`latest` Docker tag drift.** Ontotext's Docker Hub `latest` has already advanced past 1.2.2. Pinning to `1.2.2` is correct; bump deliberately when re-validating.
- **render-values.sh now reads tfvars.** First time the Helm-render layer reaches into the Terraform layer. The inline comment block (above) explains why. If we ever add a second such cross-layer read, consider extracting a small `scripts/lib/read-tfvars.sh` helper.
- **CIDR allowlist alone might not be enough.** If a future user's `admin_cidr` is a CGNAT/multi-tenant range, anyone in that range can reach Refine. Belt-and-suspenders option: add ingress basic-auth too. Easy follow-on; not in RC3 scope.
- **Refine's own preferences/state file** at `/opt/ontorefine/data/preferences.json` belongs to Refine. We never write there, never mount a ConfigMap over it.

## Rollback

Plain `helm rollback graphwise-stack <prev-rev> -n graphwise` reverts to RC2: Refine sub-chart goes away, its Deployment/Service/Ingress/PVC are removed by Helm. The PVC's PV deletion follows the StorageClass's reclaim policy (KIND default: Delete). No effect on any other workload.

## Out-of-scope future work

- Pre-seeding the GraphDB connection via a `preferences.json` ConfigMap, *if* Ontotext later documents an env-var route or we accept the state-collision risk.
- Refine ↔ Keycloak SSO (would require upstream Refine support; not in v1.2).
- Auto-running a demo "starter project" in Refine on first boot.
- Bumping Refine past 1.2.2 — deliberate, separate change.
