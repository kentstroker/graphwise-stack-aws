# Ontotext Refine v1.2 Addon (RC3) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Ontotext Refine v1.2.2 as a new toggleable sub-chart under `charts/addons/`, reachable at `https://refine.<sub>.<base>/` with ingress CIDR-allowlisted from `admin_cidr` in `terraform.tfvars`. Cut RC3.

**Architecture:** New sub-chart `charts/addons/charts/refine/` (PVC + Service + Deployment + Ingress only — no license, no init containers, no Keycloak). `render-values.sh` greps `admin_cidr` out of `infra/terraform/terraform.tfvars` and emits `addons.refine.allowedCidrs`. Console card + docs surface the internal GraphDB URL (`http://graphwise-stack-graphdb-projects:7200`) for users to paste into Refine's UI.

**Tech Stack:** Helm v3 sub-chart, bash render-values.sh, KIND on Docker, ingress-nginx, cert-manager wildcard cert (reflector-mirrored).

**Spec:** `docs/superpowers/specs/2026-05-23-ontotext-refine-addon-design.md`

**Testing note:** This codebase has no automated tests for Helm templates. "Verify" steps use `helm lint`, `helm template … | grep/yq`, and (for the final task) end-to-end `validate-stack.sh` + browser smoke on the EC2 host.

---

## File map

**Created** (4 files, new sub-chart):
- `charts/addons/charts/refine/Chart.yaml`
- `charts/addons/charts/refine/values.yaml`
- `charts/addons/charts/refine/templates/_helpers.tpl`
- `charts/addons/charts/refine/templates/all.yaml`

**Modified** (11 files):
- `charts/addons/Chart.yaml` (add dependency, bump to `1.0.0-rc3`)
- `charts/addons/values.yaml` (add `refine:` block)
- `charts/graphwise-stack/Chart.yaml` (bump dependency versions + own version to `1.0.0-rc3`)
- `charts/graphwise-stack/values.yaml` (add `addons.refine` block)
- `scripts/render-values.sh` (REFINE_HOST + tfvars admin_cidr extraction + emit `addons.refine.*`)
- `scripts/validate-stack.sh` (1 new probe)
- `charts/console/files/index.html` (Refine card)
- `charts/console/files/bookmarks.html` (Refine bookmark)
- `CLAUDE.md` (subdomain table row)
- `CONSOLE-GUIDE.md` (Refine section)
- `HOWITWORKS.md` (one-line addons paragraph update)

---

## Task 1: Create Refine sub-chart `Chart.yaml`

**Files:**
- Create: `charts/addons/charts/refine/Chart.yaml`

- [ ] **Step 1: Write the file**

```yaml
apiVersion: v2
name: refine
description: |
  Ontotext Refine — GraphDB-adapted fork of OpenRefine. CSV/JSON/Excel
  cleaning + RDF mapping. v1.2.x ships as a single Docker image with
  no license, no Keycloak SSO, and no env-var for default GraphDB
  URL (set per-project in the UI). We expose it as a sub-chart of
  addons, gated by `refine.enabled`, on subdomain `refine.<sub>.<base>`
  with the ingress CIDR-allowlisted from terraform.tfvars admin_cidr.
type: application
version: 1.0.0-rc3
appVersion: "1.2.2"
maintainers:
  - name: graphwise-stack-aws
    url: https://github.com/kentstroker/graphwise-stack-aws
```

- [ ] **Step 2: Verify**

Run: `helm lint charts/addons/charts/refine`
Expected: `0 chart(s) failed`. (Will complain "no values.yaml" until Task 3.)

- [ ] **Step 3: Commit**

```bash
git add charts/addons/charts/refine/Chart.yaml
git commit -m "refine: scaffold Chart.yaml (RC3, appVersion 1.2.2)"
```

---

## Task 2: Create `_helpers.tpl`

**Files:**
- Create: `charts/addons/charts/refine/templates/_helpers.tpl`

- [ ] **Step 1: Write the file**

Mirrors the UnifiedViews helper exactly — same label set, same `fullname = .Chart.Name` rule (Helm's `{include "refine.fullname"}` will render `refine`, which the umbrella nests under release-name namespacing the same way UV does).

```gotemplate
{{- define "refine.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end }}
{{- define "refine.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
{{- define "refine.fullname" -}}{{ .Chart.Name }}{{- end }}
{{- define "refine.host" -}}{{ regexReplaceAll "^https?://([^/]+).*$" .Values.externalUrl "$1" }}{{- end }}
```

- [ ] **Step 2: Commit (combined with Task 3 — no useful verification until values.yaml exists)**

Skip a standalone commit; bundle into Task 3's commit so the chart is consistent.

---

## Task 3: Create `values.yaml`

**Files:**
- Create: `charts/addons/charts/refine/values.yaml`

- [ ] **Step 1: Write the file**

```yaml
image:
  repository: ontotext/refine
  tag: "1.2.2"
  pullPolicy: IfNotPresent

# Filled in by the umbrella graphwise-stack values overlay
# (scripts/render-values.sh emits this on every run).
externalUrl: ""                         # https://refine.<sub>.<base>

# CIDR allowlist applied to the Ingress via the nginx annotation
# `whitelist-source-range`. Refine v1.2 ships unauth'd; without this,
# anyone who learns the URL has admin. Sourced from terraform.tfvars
# admin_cidr by scripts/render-values.sh. Empty list → annotation
# omitted → ingress is open (rendered with a WARN by render-values.sh
# if tfvars couldn't be parsed).
allowedCidrs: []

# Display-only metadata surfaced on the console landing page and in
# CONSOLE-GUIDE.md. Refine has no env var for default GraphDB URL —
# the user pastes this into Refine's Settings → Connect to GraphDB
# on first project. We never template a preferences.json over Refine's
# own state file at /opt/ontorefine/data.
graphdb:
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

- [ ] **Step 2: Verify chart lints cleanly**

Run: `helm lint charts/addons/charts/refine`
Expected: `0 chart(s) failed, 0 chart(s) linted, no failures`.

- [ ] **Step 3: Commit Tasks 2 + 3 together**

```bash
git add charts/addons/charts/refine/templates/_helpers.tpl charts/addons/charts/refine/values.yaml
git commit -m "refine: helpers + values (image 1.2.2, port 7333, PVC 20Gi)"
```

---

## Task 4: Create `templates/all.yaml`

**Files:**
- Create: `charts/addons/charts/refine/templates/all.yaml`

- [ ] **Step 1: Write the file**

```yaml
{{- if .Values.persistence.enabled }}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "refine.fullname" . }}-data
  labels: {{- include "refine.labels" . | nindent 4 }}
spec:
  accessModes: [{{ .Values.persistence.accessMode | quote }}]
  {{- if .Values.persistence.storageClass }}
  storageClassName: {{ .Values.persistence.storageClass | quote }}
  {{- end }}
  resources:
    requests:
      storage: {{ .Values.persistence.size }}
---
{{- end }}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "refine.fullname" . }}
  labels: {{- include "refine.labels" . | nindent 4 }}
spec:
  type: ClusterIP
  ports:
    - name: http
      port: {{ .Values.service.port }}
      targetPort: http
  selector: {{- include "refine.selectorLabels" . | nindent 4 }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "refine.fullname" . }}
  labels: {{- include "refine.labels" . | nindent 4 }}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector:
    matchLabels: {{- include "refine.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels: {{- include "refine.labels" . | nindent 8 }}
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
          {{- if .Values.persistence.enabled }}
          persistentVolumeClaim:
            claimName: {{ include "refine.fullname" . }}-data
          {{- else }}
          emptyDir: {}
          {{- end }}
{{- if .Values.ingress.enabled }}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "refine.fullname" . }}
  labels: {{- include "refine.labels" . | nindent 4 }}
  annotations:
    # Refine v1.2 has no built-in auth. Without an allowlist anyone who
    # learns the URL has full admin (project create/delete, SPARQL push
    # to GraphDB, file upload). admin_cidr from terraform.tfvars is the
    # single source of truth; render-values.sh wires it in.
    {{- if .Values.allowedCidrs }}
    nginx.ingress.kubernetes.io/whitelist-source-range: {{ join "," .Values.allowedCidrs | quote }}
    {{- end }}
spec:
  ingressClassName: {{ .Values.ingress.className }}
  tls:
    - hosts: [{{ include "refine.host" . | quote }}]
      secretName: wildcard-tls
  rules:
    - host: {{ include "refine.host" . | quote }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ include "refine.fullname" . }}
                port:
                  number: {{ .Values.service.port }}
{{- end }}
```

- [ ] **Step 2: Verify it renders against a hand-made values overlay**

Run from repo root:

```bash
helm template refine charts/addons/charts/refine \
  --set externalUrl=https://refine.test.example.com \
  --set 'allowedCidrs={203.0.113.42/32}' \
  > /tmp/refine-render.yaml
```

Expected: command exits 0, file is non-empty. Inspect with:

```bash
grep -E 'kind:|whitelist-source-range|claim|secretName' /tmp/refine-render.yaml
```

Expected substrings, in order:
- `kind: PersistentVolumeClaim`
- `kind: Service`
- `kind: Deployment`
- `claimName: refine-data`
- `kind: Ingress`
- `nginx.ingress.kubernetes.io/whitelist-source-range: "203.0.113.42/32"`
- `secretName: wildcard-tls`

- [ ] **Step 3: Verify the open-ingress fallback (empty CIDR list)**

```bash
helm template refine charts/addons/charts/refine \
  --set externalUrl=https://refine.test.example.com \
  > /tmp/refine-render-open.yaml
grep -c 'whitelist-source-range' /tmp/refine-render-open.yaml
```

Expected output: `0` (annotation omitted when allowedCidrs is empty).

- [ ] **Step 4: Commit**

```bash
git add charts/addons/charts/refine/templates/all.yaml
git commit -m "refine: PVC + Service + Deployment + Ingress (whitelist-source-range)"
```

---

## Task 5: Wire Refine into `addons/Chart.yaml`

**Files:**
- Modify: `charts/addons/Chart.yaml`

- [ ] **Step 1: Bump addons chart version and add Refine dependency**

Edit `charts/addons/Chart.yaml`:
- Change `version: 1.0.0-rc2` → `version: 1.0.0-rc3`
- Append a new dependency entry after the `unifiedviews` block:

```yaml
  - name: refine
    version: 1.0.0-rc3
    repository: file://./charts/refine
    condition: refine.enabled
```

Final dependencies block (after edit):

```yaml
dependencies:
  - name: adf
    version: 1.0.0-rc1
    repository: file://./charts/adf
    condition: adf.enabled
  - name: semantic-workbench
    version: 1.0.0-rc1
    repository: file://./charts/semantic-workbench
    condition: semantic-workbench.enabled
  - name: graphviews
    version: 1.0.0-rc1
    repository: file://./charts/graphviews
    condition: graphviews.enabled
  - name: rdf4j
    version: 1.0.0-rc1
    repository: file://./charts/rdf4j
    condition: rdf4j.enabled
  - name: unifiedviews
    version: 1.0.0-rc1
    repository: file://./charts/unifiedviews
    condition: unifiedviews.enabled
  - name: refine
    version: 1.0.0-rc3
    repository: file://./charts/refine
    condition: refine.enabled
```

- [ ] **Step 2: Verify lint**

Run: `helm lint charts/addons`
Expected: `0 chart(s) failed`.

- [ ] **Step 3: Do NOT commit yet** — `helm dependency update` for addons will be batched in Task 8.

---

## Task 6: Add Refine defaults to `addons/values.yaml`

**Files:**
- Modify: `charts/addons/values.yaml`

- [ ] **Step 1: Append new `refine:` block at end of file**

```yaml
refine:
  enabled: true
  image:
    repository: ontotext/refine
    tag: "1.2.2"
  externalUrl: ""           # https://refine.<sub>.<base>
  # CIDR allowlist for the Ingress (terraform.tfvars admin_cidr).
  # Empty -> annotation omitted -> ingress open. render-values.sh
  # populates this on every deploy.
  allowedCidrs: []
  graphdb:
    # Display-only; surfaced on the console card. No env wiring.
    internalUrl: "http://graphwise-stack-graphdb-projects:7200"
```

- [ ] **Step 2: Verify**

Run: `helm lint charts/addons`
Expected: `0 chart(s) failed`.

- [ ] **Step 3: Do NOT commit yet** — bundled into Task 8.

---

## Task 7: Wire `addons.refine` into umbrella `graphwise-stack/values.yaml`

**Files:**
- Modify: `charts/graphwise-stack/values.yaml`

- [ ] **Step 1: Add the umbrella overlay block**

Find the existing `addons:` block. After the `unifiedviews:` entry, add:

```yaml
  refine:
    enabled: true
    externalUrl: ""
    allowedCidrs: []
```

Resulting block (showing tail only):

```yaml
addons:
  enabled: true
  adf:
    enabled: true
    externalUrl: ""
    ...
  unifiedviews:
    enabled: true
    externalUrl: ""
  refine:
    enabled: true
    externalUrl: ""
    allowedCidrs: []
```

- [ ] **Step 2: Do NOT commit yet** — bundled into Task 8.

---

## Task 8: Bump umbrella `Chart.yaml` versions to RC3 + refresh dep tarballs

**Files:**
- Modify: `charts/graphwise-stack/Chart.yaml`

- [ ] **Step 1: Edit umbrella Chart.yaml**

- Change `version: 1.0.0-rc2` → `version: 1.0.0-rc3`
- In the `dependencies:` block, change the `addons` dependency `version: 1.0.0-rc2` → `version: 1.0.0-rc3`
- Leave all other dependency versions untouched (they stay at rc2 — RC3 is scoped to "Refine only" per spec §Goals 5).

- [ ] **Step 2: Rebuild addons dep tarballs**

The Refine sub-chart needs a `.tgz` under `charts/addons/charts/` for the umbrella to pick it up. Run:

```bash
rm -f charts/addons/charts/*.tgz charts/addons/Chart.lock
helm dependency update charts/addons
ls charts/addons/charts/*.tgz
```

Expected output includes `charts/addons/charts/refine-1.0.0-rc3.tgz` alongside the existing `adf-*.tgz`, `unifiedviews-*.tgz`, etc.

> **Note** — `charts/*/charts/*.tgz` is gitignored per CLAUDE.md "Critical rules"; we do not stage these.

- [ ] **Step 3: Rebuild umbrella dep tarballs**

```bash
helm dependency update charts/graphwise-stack
ls charts/graphwise-stack/charts/ | grep -E 'addons|refine'
```

Expected output: `addons-1.0.0-rc3.tgz` (this one IS committed — vendored umbrella deps per CLAUDE.md). No standalone `refine-*.tgz` at umbrella level (it's nested inside addons).

- [ ] **Step 4: Lint umbrella**

```bash
helm lint charts/graphwise-stack
```

Expected: `0 chart(s) failed`.

- [ ] **Step 5: Commit Tasks 5 + 6 + 7 + 8**

```bash
git add charts/addons/Chart.yaml charts/addons/values.yaml \
        charts/graphwise-stack/Chart.yaml charts/graphwise-stack/values.yaml \
        charts/graphwise-stack/charts/addons-1.0.0-rc3.tgz
# Remove the old umbrella-level addons tarball if `git status` shows it
git rm --cached charts/graphwise-stack/charts/addons-1.0.0-rc2.tgz 2>/dev/null || true
git status
git commit -m "refine: wire into addons + umbrella; bump to 1.0.0-rc3"
```

If `git status` shows extra `addons-1.0.0-rc2.tgz` deleted/untracked, `git add` or `git rm` it before commit so the working tree is clean.

---

## Task 9: Teach `render-values.sh` about Refine + admin_cidr

**Files:**
- Modify: `scripts/render-values.sh`

- [ ] **Step 1: Add the per-app host alongside the existing ones**

Find the existing host-derivation block (lines ~79-89). After the `UV_HOST=...` line, add:

```bash
REFINE_HOST="refine.${APEX}"
```

- [ ] **Step 2: Add the admin_cidr extraction block right after the host block**

Just below the host-variable assignments, add:

```bash
# ---------------------------------------------------------------------
# Refine ingress is CIDR-allowlisted using the same CIDR that gates
# SSH/admin in the Terraform layer. tfvars is the single source of
# truth -- read it here so deploy-time changes there propagate without
# manual sync. If tfvars is missing or admin_cidr can't be parsed, the
# stack still deploys; the ingress just isn't restricted (a WARN is
# printed).
# ---------------------------------------------------------------------
TFVARS_PATH="${TFVARS_PATH:-$(cd "$(dirname "$0")/.." && pwd)/infra/terraform/terraform.tfvars}"
if [ -f "$TFVARS_PATH" ]; then
    ADMIN_CIDR=$(grep -E '^[[:space:]]*admin_cidr[[:space:]]*=' "$TFVARS_PATH" \
                  | sed -E 's/.*"([^"]+)".*/\1/' | head -n1)
fi
if [ -z "${ADMIN_CIDR:-}" ]; then
    echo "WARN: could not parse admin_cidr from $TFVARS_PATH -- Refine ingress will not be CIDR-restricted" >&2
    ADMIN_CIDR="0.0.0.0/0"
fi
```

- [ ] **Step 3: Emit the Refine values in `render_umbrella()`**

Find the existing `addons:` heredoc block (around line 148). After the `unifiedviews:` entry, add:

```yaml
  refine:
    externalUrl: "https://${REFINE_HOST}"
    allowedCidrs: ["${ADMIN_CIDR}"]
```

Resulting tail of the heredoc:

```yaml
  rdf4j:
    externalUrl: "https://${RDF4J_HOST}"
  unifiedviews:
    externalUrl: "https://${UV_HOST}"
  refine:
    externalUrl: "https://${REFINE_HOST}"
    allowedCidrs: ["${ADMIN_CIDR}"]
```

- [ ] **Step 4: Smoke-test render**

```bash
./scripts/render-values.sh stroker semantic-proof.com
grep -A2 -E '^  refine:' "$HOME/.graphwise-stack/values-stroker.yaml"
```

Expected output (CIDR will be whatever's in your tfvars):

```yaml
  refine:
    externalUrl: "https://refine.stroker.semantic-proof.com"
    allowedCidrs: ["71.212.218.170/32"]
```

- [ ] **Step 5: Smoke-test the missing-tfvars fallback**

```bash
TFVARS_PATH=/nonexistent ./scripts/render-values.sh stroker semantic-proof.com 2>&1 \
  | grep WARN
grep -A2 -E '^  refine:' "$HOME/.graphwise-stack/values-stroker.yaml"
```

Expected:
- stderr contains `WARN: could not parse admin_cidr from /nonexistent`
- values file shows `allowedCidrs: ["0.0.0.0/0"]`

- [ ] **Step 6: Re-render with real tfvars before continuing** (so the next step uses the real CIDR):

```bash
./scripts/render-values.sh stroker semantic-proof.com
```

- [ ] **Step 7: Commit**

```bash
git add scripts/render-values.sh
git commit -m "render-values: REFINE_HOST + admin_cidr extraction from tfvars"
```

---

## Task 10: End-to-end Helm template check against rendered values

**Files:**
- (no edits; verification step)

- [ ] **Step 1: Render the umbrella with the rendered overlay**

```bash
helm template graphwise-stack charts/graphwise-stack \
  -f "$HOME/.graphwise-stack/values-stroker.yaml" \
  > /tmp/umbrella-render.yaml
```

Expected: command exits 0.

- [ ] **Step 2: Grep for the Refine Ingress + annotation**

```bash
grep -A1 'name: refine' /tmp/umbrella-render.yaml | head -20
grep 'whitelist-source-range' /tmp/umbrella-render.yaml
```

Expected:
- One `kind: Service`, one `kind: Deployment`, one `kind: Ingress`, one `kind: PersistentVolumeClaim` named `refine` / `refine-data`.
- Exactly one `whitelist-source-range` line containing the admin_cidr from tfvars.

- [ ] **Step 3: Grep for the Refine TLS secretName**

```bash
yq eval 'select(.kind=="Ingress" and .metadata.name=="refine") | .spec.tls' /tmp/umbrella-render.yaml
```

Expected output includes `secretName: wildcard-tls` and the host `refine.stroker.semantic-proof.com`.

- [ ] **Step 4: Confirm no regression** — count expected addon Ingresses:

```bash
yq eval 'select(.kind=="Ingress") | .metadata.name' /tmp/umbrella-render.yaml | sort -u
```

Expected names (alphabetical): `adf`, `console-graphwise-stack`, `graphdb-*` (three), `graphviews`, `keycloak`, `poolparty`, `rdf4j`, `refine`, `semantic-workbench`, `unifiedviews`. The new `refine` is the only addition vs RC2.

- [ ] **Step 5: No commit** — verification only.

---

## Task 11: Add Refine card to console `index.html`

**Files:**
- Modify: `charts/console/files/index.html`

- [ ] **Step 1: Insert the Refine card after the UnifiedViews card**

Find lines 144-148 (the UnifiedViews `<a class="card">…</a>` block). Insert immediately after `</a>` and before `</div>` (the closing tag of the addons grid section):

```html
    <a class="card" href="https://refine.{{ $apex }}/">
      <div class="title">Ontotext Refine</div>
      <div class="desc">CSV/JSON/Excel &rarr; RDF cleaning &amp; mapping (v1.2)</div>
      <div class="auth">no auth &middot; CIDR-restricted (admin_cidr)</div>
      <div class="hint">In Refine UI &rarr; Settings &rarr; Connect to GraphDB, paste:<br>
        <code>http://graphwise-stack-graphdb-projects:7200</code></div>
    </a>
```

- [ ] **Step 2: Verify by re-rendering the console ConfigMap**

```bash
helm template graphwise-stack charts/graphwise-stack \
  -f "$HOME/.graphwise-stack/values-stroker.yaml" \
  | grep -A3 'Ontotext Refine'
```

Expected: the three lines above show up unmodified (Helm `tpl` is applied at install; the `{{ $apex }}` token is fine here).

- [ ] **Step 3: Commit**

```bash
git add charts/console/files/index.html
git commit -m "console: add Refine card with internal GraphDB URL hint"
```

---

## Task 12: Add Refine bookmark to `bookmarks.html`

**Files:**
- Modify: `charts/console/files/bookmarks.html`

- [ ] **Step 1: Insert under the "PoolParty Suite" `<DL>` block**

Find line 38 (the `<DT><A HREF="…unifiedviews…">UnifiedViews</A>` entry). Insert immediately after it:

```html
            <DT><A HREF="https://refine.stroker.semantic-proof.com/">Ontotext Refine</A>
```

> **Note** — bookmarks.html uses the literal `stroker.semantic-proof.com` host (Kent's demo URL); it's not Helm-templated. Following the existing convention.

- [ ] **Step 2: Commit**

```bash
git add charts/console/files/bookmarks.html
git commit -m "console: bookmark Refine in PoolParty Suite group"
```

---

## Task 13: Update `CLAUDE.md` subdomain table

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Insert a new row in the subdomain table**

Find the table starting at line 41. After the `UnifiedViews` row (line 53), insert:

```
| Ontotext Refine | `refine.<sub>.<base>` (CIDR-allowlisted via `admin_cidr`) |
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "CLAUDE.md: add Refine row to subdomain table"
```

---

## Task 14: Add Refine section to `CONSOLE-GUIDE.md`

**Files:**
- Modify: `CONSOLE-GUIDE.md`

- [ ] **Step 1: Insert a section after UnifiedViews and before RDF4J**

Find the `## UnifiedViews` section starting at line 248. After its content ends (just before `## RDF4J Workbench` at line 348), add:

```markdown
## Ontotext Refine

**URL:** `https://refine.<sub>.<base>/`
**Login:** none — Refine v1.2 has no built-in auth. The ingress is
CIDR-allowlisted using `admin_cidr` from `infra/terraform/terraform.tfvars`.
If your laptop's public IP isn't in `admin_cidr`, the ingress returns
**HTTP 403** before Refine even sees the request.

Refine is a GraphDB-adapted fork of OpenRefine — load CSV/JSON/Excel,
clean/reshape in a spreadsheet UI, push results to GraphDB as RDF.

**Connecting to GraphDB:** Refine has no env var for default GraphDB
URL. On first project, in the Refine UI go to **Settings → Connect to
GraphDB** and paste:

```
http://graphwise-stack-graphdb-projects:7200
```

(Note: this is the **in-cluster** Service DNS name. Refine runs inside
the cluster and resolves it directly; you don't paste an `https://`
URL or your subdomain.)

**Persistence:** Refine writes project state to a 20Gi PVC at
`/opt/ontorefine/data`. Survives pod restarts; wiped by
`scripts/reset-helm.sh`.

**Widening the CIDR allowlist** (e.g. to demo from a different
network): update `admin_cidr` in `infra/terraform/terraform.tfvars`,
then re-run `scripts/render-values.sh <sub>` + `helm upgrade
graphwise-stack ./charts/graphwise-stack -n graphwise -f
$HOME/.graphwise-stack/values-<sub>.yaml`. The terraform `apply` is
NOT required for this — the Refine annotation pulls from tfvars, not
from the Terraform-managed SG.

```

- [ ] **Step 2: Add credentials-reference row (optional but consistent)**

Find the credentials reference table around line 518. After the
`UnifiedViews (app-local)` row, add:

```
| Ontotext Refine | (none) | — | no built-in auth; ingress CIDR-allowlisted |
```

- [ ] **Step 3: Commit**

```bash
git add CONSOLE-GUIDE.md
git commit -m "CONSOLE-GUIDE: add Refine section + credentials row"
```

---

## Task 15: Update `HOWITWORKS.md` addons line

**Files:**
- Modify: `HOWITWORKS.md`

- [ ] **Step 1: Append Refine to the addons enumeration**

Find line 282:

```
    ├── addons/                 ◄── ADF, Semantic Workbench, GraphViews, RDF4J, UnifiedViews
```

Replace with:

```
    ├── addons/                 ◄── ADF, Semantic Workbench, GraphViews, RDF4J, UnifiedViews, Refine
```

- [ ] **Step 2: Commit**

```bash
git add HOWITWORKS.md
git commit -m "HOWITWORKS: list Refine in addons enumeration"
```

---

## Task 16: Add Refine probe to `validate-stack.sh`

**Files:**
- Modify: `scripts/validate-stack.sh`

- [ ] **Step 1: Insert one new endpoint entry**

Find the `endpoints=(...)` block (around line 336). After the `unifiedviews.$APEX:200|404:...` line, add:

```bash
    "refine.$APEX:200|302|403:Ontotext Refine (403 expected from EC2 since EC2's public IP is not in admin_cidr)"
```

> **Why 200|302|403:**
> - `403` — **expected** when run from EC2. The EC2 host's public IP is not in `admin_cidr` (which is the operator's laptop), so nginx denies before Refine sees the request. 403 from EC2 still proves DNS + TLS + ingress wiring all work — only the allowlist gated the response.
> - `200` / `302` — only seen if you ever run validate-stack from a host whose source IP **is** in `admin_cidr` (e.g. from the laptop directly), or if `admin_cidr` is `0.0.0.0/0`.
>
> All three signals confirm ingress + cert are correctly wired; a `000` or `5xx` is the actual failure mode.

- [ ] **Step 2: Smoke-test the script structure**

```bash
bash -n scripts/validate-stack.sh && echo OK
```

Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add scripts/validate-stack.sh
git commit -m "validate-stack: probe Refine ingress (200|302|403 all healthy)"
```

---

## Task 17: End-to-end on EC2 — deploy and validate

**Files:**
- (no edits; full-stack smoke test)

- [ ] **Step 1: Push to EC2**

From the laptop:

```bash
scripts/laptop/push-config.sh
```

(Or manually `rsync -avz charts/ scripts/ <ec2>:graphwise-stack-aws/` matching your existing iteration flow.)

- [ ] **Step 2: On EC2, reset and reinstall**

```bash
./scripts/reset-helm.sh --yes stroker semantic-proof.com
```

Expected: both `graphwise-stack` and `graphrag` releases install cleanly. Refine pod reaches `Running 1/1` within ~60s.

- [ ] **Step 3: Validate**

```bash
./scripts/validate-stack.sh stroker semantic-proof.com
```

Expected: zero `failed` checks. The new Refine probe shows `https://refine.stroker.semantic-proof.com/  -> 403` from the EC2 host (EC2's public IP isn't in `admin_cidr` — that's the operator laptop). 403 confirms ingress + TLS work; only the allowlist gated the response. The actual UI test happens in Step 5 from the laptop browser.

- [ ] **Step 4: Confirm the rendered manifest in-cluster**

```bash
kubectl -n graphwise get pod,svc,ingress,pvc -l app.kubernetes.io/name=refine
kubectl -n graphwise get ingress refine -o jsonpath='{.metadata.annotations}' | jq
```

Expected:
- 1 Pod, 1 Service (ClusterIP, port 7333), 1 Ingress, 1 PVC (20Gi, Bound).
- Ingress annotation `nginx.ingress.kubernetes.io/whitelist-source-range` shows the tfvars `admin_cidr` value.

- [ ] **Step 5: Browser smoke**

From the laptop browser, open `https://refine.stroker.semantic-proof.com/`. Expected:
- TLS cert valid (wildcard from Let's Encrypt prod).
- Refine UI loads, project list empty.
- Create a project from a small CSV → upload succeeds → preview rows appear.
- Settings → Connect to GraphDB → paste `http://graphwise-stack-graphdb-projects:7200` → click connect → success.
- Browser test from a non-allowlisted network (phone hotspot, VPN to a different country) → ingress returns 403.

- [ ] **Step 6: Pod restart test**

```bash
kubectl -n graphwise rollout restart deployment/refine
kubectl -n graphwise wait --for=condition=available --timeout=120s deployment/refine
```

Browser-refresh Refine — the project created in Step 5 should still be listed (PVC persistence confirmed).

- [ ] **Step 7: Tag the release**

```bash
git tag -a v1.0.0-rc3 -m "RC3: Ontotext Refine v1.2 addon"
git push origin main v1.0.0-rc3
```

(Or follow whatever your release-cut convention is; the spec marks RC3 as Refine-only.)

---

## Self-review notes (post-write)

- **Spec coverage:** Every spec section maps to ≥1 task:
  - §Architecture → Tasks 1-4 (chart) + 5-8 (wiring)
  - §Components → Tasks 1-16 individually
  - §Data flow & state → Task 17 Step 5 (CSV upload + GraphDB push + restart persistence)
  - §Error handling table → addressed by graceful annotation omission (Task 4 Step 3), missing-tfvars fallback (Task 9 Step 5), and validate-stack probe (Task 16)
  - §Testing → Task 17 covers all 7 demo steps
  - §Risks → CIDR fallback (Task 9), tag-pinning is in Task 1 (`1.2.2` not `latest`)
- **Placeholder scan:** No `TBD`, no `// implement later`, every step shows the exact code/command + expected output.
- **Type/name consistency:** `refine.fullname` → `refine` everywhere (Tasks 2, 4); `wildcard-tls` referenced in Task 4 and Task 10 Step 3; `admin_cidr` parsing identical in spec §Components and Task 9 Step 2.
