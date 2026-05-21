# AdeptNova GraphDB (RC2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a third GraphDB instance (`graphdb-adeptnova`) to the umbrella, exposed publicly on host port 17200 via CIDR-restricted SG rule + HTTPS subdomain Ingress, with GraphDB-native security enabled, landing in `graphwise-stack` chart version `1.0.0-rc2`.

**Architecture:** Reuse `charts/graphdb/` as a third aliased subchart in the umbrella `Chart.yaml`. Expose `:17200` via KIND `extraPortMappings` → NodePort Service. Restrict access with a standalone `aws_security_group_rule` resource (not an inline ingress block — the SG has `lifecycle.ignore_changes=[ingress]`). Defense-in-depth: SG CIDR allowlist outside, GraphDB-native HTTP Basic auth inside. The existing two GraphDB instances (`graphdb-embedded`, `graphdb-projects`) MUST render byte-identical after the changes.

**Tech Stack:** Helm 3, KIND on Docker, Terraform AWS provider, kubectl, bash. No code-level changes outside `charts/`, `infra/`, `scripts/`, and `docs/`.

**Reference spec:** `docs/superpowers/specs/2026-05-21-graphdb-adeptnova-design.md`

**Pre-execution snapshot:** Capture a baseline `helm template` of the umbrella against the current values, to diff against during regression checks. Save it to `/tmp/rc1-umbrella.yaml`.

```bash
helm dependency update charts/graphwise-stack
helm template graphwise-stack charts/graphwise-stack \
  --namespace graphwise \
  -f $HOME/.graphwise-stack/values-stroker.yaml \
  > /tmp/rc1-umbrella.yaml
```

This file is the regression yardstick — every "render diff" check in this plan compares against it.

---

## File Structure

**Created:**
- `charts/graphdb/templates/security-init-job.yaml` — post-install Helm hook that enables GraphDB-native security on the AdeptNova instance.
- `docs/superpowers/plans/2026-05-21-graphdb-adeptnova-rc2.md` — this plan.

**Modified:**
- `charts/graphwise-stack/Chart.yaml` — third dep alias (`graphdb-adeptnova`), version bump to `1.0.0-rc2`.
- `charts/graphwise-stack/values.yaml` — new `graphdb-adeptnova:` block.
- `charts/graphdb/Chart.yaml` — version bump to `1.0.0-rc2`.
- `charts/graphdb/values.yaml` — add `service.nodePort` field, `security:` block (both off by default; existing instances unaffected).
- `charts/graphdb/templates/service.yaml` — render `nodePort` conditionally when `service.type=NodePort`.
- `infra/kind/kind-config.yaml` — append `extraPortMappings` entry `17200 → 31720`.
- `infra/terraform/variables.tf` — new `var.adeptnova_cidrs`.
- `infra/terraform/main.tf` — new `aws_security_group_rule "adeptnova_graphdb"` resource.
- `infra/terraform/outputs.tf` — `graphdb_adeptnova` + `graphdb_adeptnova_direct` outputs.
- `infra/terraform/terraform.tfvars.example` — show `adeptnova_cidrs = []`.
- `scripts/cluster-bootstrap.sh` — add `graphdb-adeptnova` to the namespace loop + reflector annotations.
- `scripts/install-licenses.sh` — copy `graphdb-license` and create `graphdb-adeptnova-admin` Secret into `graphdb-adeptnova` ns.
- `scripts/render-values.sh` — emit `graphdb-adeptnova:` block.
- `scripts/reset-helm.sh` — add `graphdb-adeptnova` to the PVC wipe loops.
- `scripts/validate-stack.sh` — pod readiness, license Secret, admin Secret, HTTPS reachability checks for the new instance.
- `CLAUDE.md` — subdomain table row, "Critical rules" note about :17200.
- `docs/claude/chart-internals.md` — three-alias note.
- `CONSOLE-GUIDE.md` — new section for AdeptNova URL + credentials.
- `infra/README.md` — document `var.adeptnova_cidrs`.

---

### Task 1: Resolve the open spec question (GraphDB 11 security-init API sequence)

**Why:** The spec leaves Pattern A vs Pattern B open. The init Job needs exactly one code path. This task picks one before any code is written so Task 4 has a single sequence to encode.

**Files:** None (research only).

- [ ] **Step 1: Read GraphDB 11.3.3 REST API reference for security endpoints**

Open the GraphDB 11 docs at https://graphdb.ontotext.com/documentation/11.3/ (or the bundled `/swagger` on a running instance) and find:
- `POST /rest/security` — body `true|false` to toggle.
- `POST /rest/security/users/{username}` — create a user.
- `PUT /rest/security/users/{username}` — replace a user.
- What auth is required for each endpoint when security is off vs on.

- [ ] **Step 2: Decide Pattern A or Pattern B and document it**

Pattern A (security-off-first): `POST /rest/security/users/admin` body with password, then `POST /rest/security` body `true`. Requires the create-user endpoint to accept unauthenticated requests when security is off.

Pattern B (security-on-first): `POST /rest/security` body `true` (creates default `admin/admin`), then `PUT /rest/security/users/admin` authenticated as `admin/admin` with the new password.

**Default to Pattern B** unless the docs explicitly support Pattern A — Pattern B is the documented administrator workflow and survives re-runs (idempotent via PUT with current credentials).

- [ ] **Step 3: Update the spec's "Open questions" section to lock in the choice**

Edit `docs/superpowers/specs/2026-05-21-graphdb-adeptnova-design.md`, replacing the "Open questions" section with:

```markdown
## Resolved questions

1. **GraphDB 11.3.3 security-init API sequence.** Confirmed: use **Pattern B** (security-on-first). Sequence:
   1. `POST /rest/security` with body `true` and `Content-Type: application/json`. GraphDB creates default user `admin` with password `root`.
   2. `PUT /rest/security/users/admin` authenticated as `admin:root`, body the new password from the `graphdb-adeptnova-admin` Secret.
   Job is idempotent: re-running against an already-secured server with the configured admin password is a no-op (`PUT` with the same password just succeeds).
```

(Replace `root` above with the actual GraphDB 11.3.3 default if the docs say something else — verify in Step 1.)

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-05-21-graphdb-adeptnova-design.md
git commit -m "spec: lock in GraphDB 11 security-init API sequence (Pattern B)"
```

---

### Task 2: Capture pre-change baseline render

**Why:** All subsequent subchart edits must leave the existing two GraphDB instances rendering byte-identical. We need a baseline file to diff against.

**Files:** None (creates `/tmp/rc1-umbrella.yaml`, not version-controlled).

- [ ] **Step 1: Update Helm dependencies**

```bash
cd charts/graphwise-stack
helm dependency update
cd ../..
```

Expected: no errors, `Chart.lock` may regenerate.

- [ ] **Step 2: Render the umbrella with current values**

Substitute `<sub>` with your dev subdomain (e.g. `stroker`):

```bash
SUB=stroker  # adjust as needed
scripts/render-values.sh "$SUB"
helm template graphwise-stack charts/graphwise-stack \
  --namespace graphwise \
  -f "$HOME/.graphwise-stack/values-${SUB}.yaml" \
  > /tmp/rc1-umbrella.yaml
wc -l /tmp/rc1-umbrella.yaml
```

Expected: positive line count (a few thousand lines typically); no Helm errors.

- [ ] **Step 3: Extract just the existing GraphDB resources for focused diffing later**

```bash
awk '/^# Source: graphwise-stack\/charts\/graphdb-(embedded|projects)/{flag=1} /^# Source:/{if(!match($0,/graphdb-(embedded|projects)/))flag=0} flag' \
  /tmp/rc1-umbrella.yaml > /tmp/rc1-graphdb-existing.yaml
wc -l /tmp/rc1-graphdb-existing.yaml
```

Expected: nonzero line count — Services, Ingresses, StatefulSets, and Secrets for both existing instances.

- [ ] **Step 4: No commit (these are throwaway artifacts under `/tmp`)**

---

### Task 3: Subchart — add `service.nodePort` plumbing

**Files:**
- Modify: `charts/graphdb/values.yaml`
- Modify: `charts/graphdb/templates/service.yaml`

- [ ] **Step 1: Add `nodePort` field to `charts/graphdb/values.yaml`**

Find the existing `service:` block (lines 34-36):

```yaml
service:
  type: ClusterIP
  port: 7200
```

Replace with:

```yaml
service:
  type: ClusterIP
  port: 7200
  # nodePort: only used when type=NodePort. Leave unset (or 0) for
  # ClusterIP. AdeptNova alias overrides this to 31720 in the umbrella
  # values so KIND's extraPortMappings (host :17200 -> node :31720)
  # routes externally.
  nodePort: 0
```

- [ ] **Step 2: Update `charts/graphdb/templates/service.yaml` to render nodePort conditionally**

Current contents (already in repo):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "graphdb.fullname" . }}
  namespace: {{ .Values.namespace | default .Release.Namespace }}
  labels:
    {{- include "graphdb.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  ports:
    - name: http
      port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
  selector:
    {{- include "graphdb.selectorLabels" . | nindent 4 }}
```

Replace the `ports:` block with:

```yaml
spec:
  type: {{ .Values.service.type }}
  ports:
    - name: http
      port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
      {{- if and (eq .Values.service.type "NodePort") (gt (int .Values.service.nodePort) 0) }}
      nodePort: {{ .Values.service.nodePort }}
      {{- end }}
  selector:
    {{- include "graphdb.selectorLabels" . | nindent 4 }}
```

The guard `(gt (int .Values.service.nodePort) 0)` prevents rendering `nodePort: 0` (which Kubernetes treats as invalid) when the default is unchanged.

- [ ] **Step 3: Verify the two existing instances still render byte-identical**

```bash
helm dependency update charts/graphwise-stack
SUB=stroker
helm template graphwise-stack charts/graphwise-stack \
  --namespace graphwise \
  -f "$HOME/.graphwise-stack/values-${SUB}.yaml" \
  > /tmp/rc2-umbrella-step3.yaml
awk '/^# Source: graphwise-stack\/charts\/graphdb-(embedded|projects)/{flag=1} /^# Source:/{if(!match($0,/graphdb-(embedded|projects)/))flag=0} flag' \
  /tmp/rc2-umbrella-step3.yaml > /tmp/rc2-graphdb-existing.yaml
diff /tmp/rc1-graphdb-existing.yaml /tmp/rc2-graphdb-existing.yaml
```

Expected: **no output** (diff returns 0). If the diff shows anything, the change is not backwards-compatible — re-check the conditional.

- [ ] **Step 4: Commit**

```bash
git add charts/graphdb/values.yaml charts/graphdb/templates/service.yaml
git commit -m "graphdb: plumb service.nodePort through (default off; no-op for existing instances)"
```

---

### Task 4: Subchart — add GraphDB-native security init Job

**Files:**
- Modify: `charts/graphdb/values.yaml`
- Create: `charts/graphdb/templates/security-init-job.yaml`

- [ ] **Step 1: Add `security:` block to `charts/graphdb/values.yaml`**

Append at the end of the file (after the existing `affinity: {}` line):

```yaml

# GraphDB-native security. When enabled, a post-install Helm Job
# turns on GraphDB's built-in user database and seeds the admin user
# from the `<release>-admin` Secret (key `password`). Defaults off
# so the two pre-existing instances (graphdb-embedded, graphdb-projects)
# remain unauthenticated at the GraphDB layer (their security model
# is nginx basic auth at the Ingress).
#
# AdeptNova override sets this true. The Secret name is hard-coded
# to <fullname>-admin and is created out-of-band by
# scripts/install-licenses.sh in the chart's namespace.
security:
  enabled: false
  # Image used for the init Job. alpine + curl is enough.
  image: alpine:3.20
  # Default password GraphDB ships with after security is first enabled.
  # GraphDB 11 default user is `admin` with password `root` -- verified
  # in Task 1 against the GraphDB 11.3.3 docs. Override only if a future
  # GraphDB release changes the default.
  defaultAdminPassword: "root"
```

- [ ] **Step 2: Create the init Job template**

Create `charts/graphdb/templates/security-init-job.yaml`:

```yaml
{{- if .Values.security.enabled }}
{{/*
Post-install/upgrade Helm hook: enables GraphDB-native security and
sets the admin password from <fullname>-admin Secret (key `password`).

Pattern B (security-on-first), confirmed in
docs/superpowers/specs/2026-05-21-graphdb-adeptnova-design.md:
  1. POST /rest/security true   -- enable security; GraphDB creates
     default admin user with password = .Values.security.defaultAdminPassword.
  2. PUT /rest/security/users/admin (authenticated as
     admin:<defaultAdminPassword>) -- change admin's password to the
     value in the Secret.

Idempotent: on re-run against an already-secured server, step 1 is a
no-op (POST true on already-on is accepted) and step 2 may fail
authentication if the admin password has already been changed; the
Job retries auth using the Secret-supplied password as a fallback.

Lives in the same namespace as the Service it talks to (
{{ .Values.namespace | default .Release.Namespace }}).
*/}}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "graphdb.fullname" . }}-security-init
  namespace: {{ .Values.namespace | default .Release.Namespace }}
  labels:
    {{- include "graphdb.labels" . | nindent 4 }}
  annotations:
    "helm.sh/hook": post-install,post-upgrade
    "helm.sh/hook-weight": "5"
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  backoffLimit: 5
  ttlSecondsAfterFinished: 600
  template:
    metadata:
      labels:
        {{- include "graphdb.labels" . | nindent 8 }}
        app.kubernetes.io/component: security-init
    spec:
      restartPolicy: OnFailure
      containers:
        - name: init
          image: {{ .Values.security.image | quote }}
          imagePullPolicy: IfNotPresent
          env:
            - name: GRAPHDB_URL
              value: "http://{{ include "graphdb.fullname" . }}:{{ .Values.service.port }}"
            - name: DEFAULT_ADMIN_PW
              value: {{ .Values.security.defaultAdminPassword | quote }}
            - name: TARGET_ADMIN_PW
              valueFrom:
                secretKeyRef:
                  name: {{ include "graphdb.fullname" . }}-admin
                  key: password
          command:
            - /bin/sh
            - -ec
            - |
              apk add --no-cache curl >/dev/null

              echo "Waiting for GraphDB at $GRAPHDB_URL/rest/repositories ..."
              for i in $(seq 1 60); do
                  if curl -sf -o /dev/null "$GRAPHDB_URL/rest/repositories"; then
                      echo "  GraphDB up after $i attempt(s)"
                      break
                  fi
                  [ "$i" = "60" ] && { echo "ERROR: GraphDB never came up (5min)" >&2; exit 1; }
                  sleep 5
              done

              echo "Step 1: enabling security ..."
              code=$(curl -s -o /tmp/r1 -w '%{http_code}' \
                  -X POST -H 'Content-Type: application/json' \
                  -u "admin:$DEFAULT_ADMIN_PW" \
                  --data 'true' "$GRAPHDB_URL/rest/security")
              echo "  POST /rest/security true -> HTTP $code"
              case "$code" in
                  200|204|409) : ;;
                  401) echo "  401: security already on, default pw rejected -- continuing to step 2 with TARGET_ADMIN_PW";;
                  *) cat /tmp/r1 >&2; exit 1 ;;
              esac

              echo "Step 2: setting admin password from Secret ..."
              # First try with the default password (fresh install).
              code=$(curl -s -o /tmp/r2 -w '%{http_code}' \
                  -X PUT -H 'Content-Type: application/json' \
                  -u "admin:$DEFAULT_ADMIN_PW" \
                  --data "{\"password\":\"$TARGET_ADMIN_PW\",\"grantedAuthorities\":[\"ROLE_ADMIN\"]}" \
                  "$GRAPHDB_URL/rest/security/users/admin")
              echo "  PUT admin (auth=default) -> HTTP $code"
              if [ "$code" != "200" ] && [ "$code" != "204" ]; then
                  echo "  default-pw PUT failed; retrying with target pw (already-rotated case)"
                  code=$(curl -s -o /tmp/r2 -w '%{http_code}' \
                      -X PUT -H 'Content-Type: application/json' \
                      -u "admin:$TARGET_ADMIN_PW" \
                      --data "{\"password\":\"$TARGET_ADMIN_PW\",\"grantedAuthorities\":[\"ROLE_ADMIN\"]}" \
                      "$GRAPHDB_URL/rest/security/users/admin")
                  echo "  PUT admin (auth=target) -> HTTP $code"
                  if [ "$code" != "200" ] && [ "$code" != "204" ]; then
                      cat /tmp/r2 >&2
                      exit 1
                  fi
              fi

              echo "Done. Admin password seeded from Secret; security on."
{{- end }}
```

- [ ] **Step 3: Verify existing instances are STILL byte-identical**

Both existing instances have `security.enabled` defaulting to false, so the Job template should render to nothing for them.

```bash
helm template graphwise-stack charts/graphwise-stack \
  --namespace graphwise \
  -f "$HOME/.graphwise-stack/values-${SUB}.yaml" \
  > /tmp/rc2-umbrella-step4.yaml
awk '/^# Source: graphwise-stack\/charts\/graphdb-(embedded|projects)/{flag=1} /^# Source:/{if(!match($0,/graphdb-(embedded|projects)/))flag=0} flag' \
  /tmp/rc2-umbrella-step4.yaml > /tmp/rc2-graphdb-existing-step4.yaml
diff /tmp/rc1-graphdb-existing.yaml /tmp/rc2-graphdb-existing-step4.yaml
```

Expected: **no output**.

- [ ] **Step 4: Commit**

```bash
git add charts/graphdb/values.yaml charts/graphdb/templates/security-init-job.yaml
git commit -m "graphdb: add post-install security-init Job (off by default; AdeptNova opts in)"
```

---

### Task 5: Umbrella — add the third alias

**Files:**
- Modify: `charts/graphwise-stack/Chart.yaml`
- Modify: `charts/graphwise-stack/values.yaml`

- [ ] **Step 1: Add the third dependency entry to `charts/graphwise-stack/Chart.yaml`**

Locate the existing GraphDB block (lines 31-44, the two `graphdb-embedded` / `graphdb-projects` entries). Immediately after the `graphdb-projects` block, add a third:

```yaml
  - name: graphdb
    alias: graphdb-adeptnova
    version: 1.0.0-rc2
    repository: file://../graphdb
    condition: graphdb-adeptnova.enabled
```

Then bump the umbrella's own version field at line 14:

```yaml
version: 1.0.0-rc2
```

- [ ] **Step 2: Bump `charts/graphdb/Chart.yaml` to `1.0.0-rc2`**

```bash
grep ^version: charts/graphdb/Chart.yaml
```

Edit `charts/graphdb/Chart.yaml`, change the `version:` line to `1.0.0-rc2`. Also update `charts/graphdb/Chart.yaml`'s `version:` field; the other two aliases will pin the new version via the umbrella `Chart.yaml`.

- [ ] **Step 3: Update other umbrella dependency versions to `1.0.0-rc2`**

Edit each `version:` field inside `charts/graphwise-stack/Chart.yaml` `dependencies:` block to `1.0.0-rc2`. Then bump each subchart's own `Chart.yaml` `version:` field to match:

```bash
for f in charts/keycloak-realms charts/poolparty-elasticsearch charts/poolparty charts/console charts/addons; do
  grep -H ^version: "$f/Chart.yaml"
done
```

Edit each one to `version: 1.0.0-rc2`. Use a single editor pass per file. After all are updated, verify with the same grep — every line should read `version: 1.0.0-rc2`.

- [ ] **Step 4: Add the `graphdb-adeptnova:` block to `charts/graphwise-stack/values.yaml`**

Insert after the existing `graphdb-projects:` block (around line 265, immediately before `# PoolParty.`):

```yaml

# Third GraphDB instance, exposed publicly on host :17200 via KIND
# extraPortMappings + a CIDR-allowlisted SG rule, with GraphDB-native
# security enabled (defense-in-depth). Used by AdeptNova-style demos
# that need direct triple-store access from external client tooling
# without going through the basic-auth nginx Ingress.
#
# Lives in its own namespace `graphdb-adeptnova` (created by
# scripts/cluster-bootstrap.sh; license + admin Secrets installed by
# scripts/install-licenses.sh).
graphdb-adeptnova:
  enabled: true
  namespace: graphdb-adeptnova
  externalUrl: ""              # filled by render-values.sh
  ingress:
    host: ""                   # filled by render-values.sh
  service:
    type: NodePort
    port: 7200
    nodePort: 31720
  security:
    enabled: true
```

- [ ] **Step 5: Re-render and verify the new instance appears**

```bash
helm dependency update charts/graphwise-stack
SUB=stroker
scripts/render-values.sh "$SUB"   # not yet emitting the new block; that's Task 11
# Emit a temporary overlay that fills in the host so we can test the render:
cat >> "$HOME/.graphwise-stack/values-${SUB}.yaml" <<EOF

graphdb-adeptnova:
  externalUrl: "https://graphdb-adeptnova.${SUB}.semantic-demo.com/"
  ingress:
    host: "graphdb-adeptnova.${SUB}.semantic-demo.com"
EOF

helm template graphwise-stack charts/graphwise-stack \
  --namespace graphwise \
  -f "$HOME/.graphwise-stack/values-${SUB}.yaml" \
  > /tmp/rc2-umbrella-step5.yaml

grep -c '^# Source: graphwise-stack/charts/graphdb-adeptnova' /tmp/rc2-umbrella-step5.yaml
```

Expected: **≥ 4** (Service, Ingress, StatefulSet, Secret, plus the security-init Job — exact count depends on what `charts/graphdb/templates/` contains).

- [ ] **Step 6: Verify the existing two are STILL byte-identical**

```bash
awk '/^# Source: graphwise-stack\/charts\/graphdb-(embedded|projects)/{flag=1} /^# Source:/{if(!match($0,/graphdb-(embedded|projects)/))flag=0} flag' \
  /tmp/rc2-umbrella-step5.yaml > /tmp/rc2-graphdb-existing-step5.yaml
diff /tmp/rc1-graphdb-existing.yaml /tmp/rc2-graphdb-existing-step5.yaml
```

Expected: **no output**.

- [ ] **Step 7: Verify the AdeptNova Service has `type: NodePort` and `nodePort: 31720`**

```bash
awk '/^# Source: graphwise-stack\/charts\/graphdb-adeptnova\/templates\/service.yaml/{flag=1} /^# Source:/{if(!match($0,/graphdb-adeptnova\/templates\/service.yaml/))flag=0} flag' \
  /tmp/rc2-umbrella-step5.yaml
```

Expected output includes:
```yaml
  type: NodePort
  ports:
    - name: http
      port: 7200
      targetPort: http
      protocol: TCP
      nodePort: 31720
```

- [ ] **Step 8: Commit**

```bash
git add charts/graphwise-stack/Chart.yaml charts/graphwise-stack/values.yaml \
        charts/graphdb/Chart.yaml \
        charts/keycloak-realms/Chart.yaml charts/poolparty-elasticsearch/Chart.yaml \
        charts/poolparty/Chart.yaml charts/console/Chart.yaml charts/addons/Chart.yaml
git commit -m "umbrella: add graphdb-adeptnova alias, bump all chart versions to 1.0.0-rc2"
```

---

### Task 6: KIND — add port mapping

**Files:**
- Modify: `infra/kind/kind-config.yaml`

- [ ] **Step 1: Append the new `extraPortMappings` entry**

Edit `infra/kind/kind-config.yaml`. Find the existing `extraPortMappings:` list (lines 57-63):

```yaml
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
```

Append a third entry **inside the same list** (matching indentation):

```yaml
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
      # AdeptNova GraphDB direct (RC2). Public access on host :17200
      # forwards to KIND node :31720, which the
      # graphwise-stack-graphdb-adeptnova NodePort Service listens on.
      # Public exposure is gated separately by a CIDR-allowlisted SG
      # rule -- see infra/terraform/main.tf (aws_security_group_rule
      # "adeptnova_graphdb").
      - containerPort: 31720
        hostPort: 17200
        protocol: TCP
        listenAddress: "0.0.0.0"
```

`listenAddress: "0.0.0.0"` is explicit (vs the default) to document that this mapping is intentionally public — distinct from the `127.0.0.1`-bound admin-tunnel pattern documented in `infra/terraform/main.tf:220-223`.

- [ ] **Step 2: Verify the YAML still parses**

```bash
python3 -c "import yaml; yaml.safe_load(open('infra/kind/kind-config.yaml'))" && echo OK
```

Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add infra/kind/kind-config.yaml
git commit -m "kind: add host :17200 -> node :31720 port mapping for AdeptNova GraphDB"
```

**Note:** This change does NOT take effect on a live cluster. Applying it requires recreating the KIND cluster (next `scripts/cluster-bootstrap.sh` from scratch). That's why this is an RC2-scoped change.

---

### Task 7: Terraform — `var.adeptnova_cidrs` + SG rule + outputs

**Files:**
- Modify: `infra/terraform/variables.tf`
- Modify: `infra/terraform/main.tf`
- Modify: `infra/terraform/outputs.tf`
- Modify: `infra/terraform/terraform.tfvars.example`

- [ ] **Step 1: Add the variable to `infra/terraform/variables.tf`**

Append at the end of the file:

```hcl
variable "adeptnova_cidrs" {
  type        = list(string)
  default     = []
  description = <<-EOT
    CIDR ranges allowed to reach the AdeptNova GraphDB on host port
    17200 (the third, publicly-exposed GraphDB instance added in RC2).

    Empty list (default) = no SG rule is created; the instance still
    runs and listens on :31720 inside KIND, but the EC2 security group
    won't admit external traffic to host :17200.

    Example for a single laptop + a customer office:
      adeptnova_cidrs = ["198.51.100.42/32", "203.0.113.0/24"]

    NOTE: the SG rule is created as a standalone
    aws_security_group_rule resource, NOT as an inline ingress block
    on aws_security_group.stack -- that SG has lifecycle.ignore_changes
    = [ingress] to preserve operator-added Console rules.
  EOT
}
```

- [ ] **Step 2: Add the SG rule to `infra/terraform/main.tf`**

Find the end of the `aws_security_group "stack"` resource (after the closing `}` for the SG resource at around line 277). Add after it, before the `# ----` divider preceding the EC2 instance:

```hcl
# ---------------------------------------------------------------------------
# AdeptNova GraphDB ingress rule (RC2)
# ---------------------------------------------------------------------------
# Standalone aws_security_group_rule resource, NOT an inline `ingress`
# block on aws_security_group.stack. The SG has lifecycle.ignore_changes
# = [ingress] (see SG resource above), which causes Terraform to ignore
# inline ingress block drift; standalone rule resources are managed
# separately from inline blocks and respond to terraform plan/apply
# normally.
#
# Gated on var.adeptnova_cidrs being non-empty: empty list -> no rule
# created -> :17200 unreachable from outside the VPC even though the
# instance is still listening.
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

- [ ] **Step 3: Add outputs to `infra/terraform/outputs.tf`**

Append at the end of the file:

```hcl
output "graphdb_adeptnova" {
  description = "HTTPS subdomain for the AdeptNova GraphDB workbench (browser admin)."
  value       = "https://graphdb-adeptnova.${var.subdomain}.${var.base_domain}/"
}

output "graphdb_adeptnova_direct" {
  description = <<-EOT
    Direct (non-Ingress) URL for the AdeptNova GraphDB, on host port
    17200. Reachable only from CIDRs listed in var.adeptnova_cidrs.
    Reports "(disabled - var.adeptnova_cidrs is empty)" when the SG
    rule is not provisioned.
  EOT
  value       = length(var.adeptnova_cidrs) > 0 ? "http://${local.public_ip}:17200/" : "(disabled - var.adeptnova_cidrs is empty)"
}
```

- [ ] **Step 4: Update `infra/terraform/terraform.tfvars.example`**

Append:

```hcl

# AdeptNova GraphDB direct-access CIDR allowlist (RC2).
# Empty list = SG rule not created; host :17200 unreachable externally.
# Example: adeptnova_cidrs = ["198.51.100.42/32"]
adeptnova_cidrs = []
```

- [ ] **Step 5: Validate with `terraform plan`**

```bash
cd infra/terraform
terraform fmt -check -recursive
terraform validate
terraform plan -var-file=terraform.tfvars -out=/tmp/tfplan-rc2 2>&1 | tee /tmp/tfplan-rc2.txt
```

Expected:
- `terraform fmt -check` exits clean (or you `terraform fmt -recursive` to fix).
- `terraform validate` succeeds.
- `terraform plan` with the default empty `adeptnova_cidrs` shows **0 resources to add, 0 to change, 0 to destroy** for the SG rule (since `count = 0`).

Then test with a non-empty CIDR:

```bash
terraform plan -var-file=terraform.tfvars -var='adeptnova_cidrs=["198.51.100.42/32"]' 2>&1 | grep -A6 "aws_security_group_rule.adeptnova_graphdb"
```

Expected: a planned `+` (create) for `aws_security_group_rule.adeptnova_graphdb[0]` with `from_port=17200`, `to_port=17200`, `cidr_blocks=["198.51.100.42/32"]`.

```bash
cd ../..
```

- [ ] **Step 6: Commit**

```bash
git add infra/terraform/variables.tf infra/terraform/main.tf infra/terraform/outputs.tf infra/terraform/terraform.tfvars.example
git commit -m "terraform: add var.adeptnova_cidrs + standalone SG rule for AdeptNova :17200"
```

---

### Task 8: `cluster-bootstrap.sh` — add namespace + reflector annotation

**Files:**
- Modify: `scripts/cluster-bootstrap.sh`

- [ ] **Step 1: Add `graphdb-adeptnova` to the namespace creation loop**

Find the existing loop (around line 108):

```bash
for ns in ingress-nginx cert-manager cnpg-system keycloak graphwise graphdb graphrag kubernetes-dashboard monitoring; do
    kubectl get namespace "$ns" >/dev/null 2>&1 || kubectl create namespace "$ns"
```

Replace with:

```bash
for ns in ingress-nginx cert-manager cnpg-system keycloak graphwise graphdb graphdb-adeptnova graphrag kubernetes-dashboard monitoring; do
    kubectl get namespace "$ns" >/dev/null 2>&1 || kubectl create namespace "$ns"
```

- [ ] **Step 2: Add `graphdb-adeptnova` to the reflector annotations**

Find the two reflector annotation lines (around line 315):

```yaml
      reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "graphwise,graphdb,graphrag,keycloak,kubernetes-dashboard,monitoring"
      ...
      reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: "graphwise,graphdb,graphrag,keycloak,kubernetes-dashboard,monitoring"
```

Replace each with:

```yaml
      reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "graphwise,graphdb,graphdb-adeptnova,graphrag,keycloak,kubernetes-dashboard,monitoring"
      ...
      reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: "graphwise,graphdb,graphdb-adeptnova,graphrag,keycloak,kubernetes-dashboard,monitoring"
```

- [ ] **Step 3: Validate the script parses**

```bash
bash -n scripts/cluster-bootstrap.sh && echo OK
```

Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add scripts/cluster-bootstrap.sh
git commit -m "cluster-bootstrap: create graphdb-adeptnova ns + extend reflector annotations"
```

---

### Task 9: `install-licenses.sh` — license + admin Secret in new namespace

**Files:**
- Modify: `scripts/install-licenses.sh`

- [ ] **Step 1: Extend the existing per-namespace license copy block**

Find the existing `graphdb` namespace block (around line 67-72):

```bash
if kubectl get namespace graphdb >/dev/null 2>&1; then
    create_or_replace graphdb graphdb-license graphdb.license "$LICENSES_DIR/graphdb.license"
fi
```

Replace with:

```bash
if kubectl get namespace graphdb >/dev/null 2>&1; then
    create_or_replace graphdb graphdb-license graphdb.license "$LICENSES_DIR/graphdb.license"
fi

# Third GraphDB instance (AdeptNova, added in RC2) lives in its own
# namespace `graphdb-adeptnova`. Needs the same license file AND an
# admin-credentials Secret consumed by the security-init Helm hook.
# Default admin password follows the repo's `rdf#rocks` convention
# (see CLAUDE.md "Default password convention"). Rotate by editing
# the Secret + bouncing the security-init Job.
if kubectl get namespace graphdb-adeptnova >/dev/null 2>&1; then
    create_or_replace graphdb-adeptnova graphdb-license graphdb.license "$LICENSES_DIR/graphdb.license"

    # Admin Secret. The chart hard-codes the Secret name as
    # <fullname>-admin = graphwise-stack-graphdb-adeptnova-admin.
    kubectl -n graphdb-adeptnova delete secret graphwise-stack-graphdb-adeptnova-admin --ignore-not-found
    kubectl -n graphdb-adeptnova create secret generic graphwise-stack-graphdb-adeptnova-admin \
        --from-literal=username=admin \
        --from-literal=password='rdf#rocks'
    echo "  ✓ graphdb-adeptnova/graphwise-stack-graphdb-adeptnova-admin (admin user)"
fi
```

- [ ] **Step 2: Validate**

```bash
bash -n scripts/install-licenses.sh && echo OK
```

Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add scripts/install-licenses.sh
git commit -m "install-licenses: install graphdb-license + admin Secret in graphdb-adeptnova ns"
```

---

### Task 10: `reset-helm.sh` — extend PVC wipe + license pre-flight

**Files:**
- Modify: `scripts/reset-helm.sh`

- [ ] **Step 1: Add `graphdb-adeptnova` to the license pre-flight**

Find the existing graphdb-projects license pre-flight (around line 205-213):

```bash
if ! kubectl -n graphdb get secret graphdb-license >/dev/null 2>&1; then
    echo "  ERROR: missing Secret 'graphdb/graphdb-license'" >&2
    missing_licenses=1
else
    echo "  OK:    graphdb/graphdb-license"
fi
```

Immediately after that block, add:

```bash
# graphdb-adeptnova namespace: third GraphDB instance (RC2) mounts a
# third copy of graphdb-license + its own admin Secret.
if kubectl get namespace graphdb-adeptnova >/dev/null 2>&1; then
    if ! kubectl -n graphdb-adeptnova get secret graphdb-license >/dev/null 2>&1; then
        echo "  ERROR: missing Secret 'graphdb-adeptnova/graphdb-license'" >&2
        missing_licenses=1
    else
        echo "  OK:    graphdb-adeptnova/graphdb-license"
    fi
    if ! kubectl -n graphdb-adeptnova get secret graphwise-stack-graphdb-adeptnova-admin >/dev/null 2>&1; then
        echo "  ERROR: missing Secret 'graphdb-adeptnova/graphwise-stack-graphdb-adeptnova-admin'" >&2
        missing_licenses=1
    else
        echo "  OK:    graphdb-adeptnova/graphwise-stack-graphdb-adeptnova-admin"
    fi
fi
```

- [ ] **Step 2: Add `graphdb-adeptnova` to BOTH PVC wipe loops**

Find the loop at line 453-458:

```bash
echo "Deleting PVCs in graphwise, graphdb, keycloak, graphrag namespaces..."
for ns in graphwise graphdb keycloak graphrag; do
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        kubectl delete pvc --all -n "$ns" --wait=false --ignore-not-found || true
    fi
done
```

Replace with:

```bash
echo "Deleting PVCs in graphwise, graphdb, graphdb-adeptnova, keycloak, graphrag namespaces..."
for ns in graphwise graphdb graphdb-adeptnova keycloak graphrag; do
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        kubectl delete pvc --all -n "$ns" --wait=false --ignore-not-found || true
    fi
done
```

Then find the wait loop at line 463-479:

```bash
echo "Waiting for PVCs to terminate..."
deadline=$(( $(date +%s) + 60 ))
while :; do
    leftover=0
    for ns in graphwise graphdb keycloak graphrag; do
```

Update the inner `for ns` line to:

```bash
    for ns in graphwise graphdb graphdb-adeptnova keycloak graphrag; do
```

- [ ] **Step 3: Validate**

```bash
bash -n scripts/reset-helm.sh && echo OK
```

Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add scripts/reset-helm.sh
git commit -m "reset-helm: add graphdb-adeptnova to PVC wipe + license pre-flight"
```

---

### Task 11: `render-values.sh` — emit AdeptNova block

**Files:**
- Modify: `scripts/render-values.sh`

- [ ] **Step 1: Add the host variable**

Find the existing host derivations (around line 82-88):

```bash
GDB_E_HOST="graphdb.${APEX}"
GDB_P_HOST="graphdb-projects.${APEX}"
ADF_HOST="adf.${APEX}"
```

Add the new host:

```bash
GDB_E_HOST="graphdb.${APEX}"
GDB_P_HOST="graphdb-projects.${APEX}"
GDB_A_HOST="graphdb-adeptnova.${APEX}"
ADF_HOST="adf.${APEX}"
```

- [ ] **Step 2: Emit the `graphdb-adeptnova:` block**

Find the existing `graphdb-projects:` block in `render_umbrella()` (around line 119-122):

```yaml
graphdb-projects:
  externalUrl: "https://${GDB_P_HOST}/"
  ingress:
    host: "${GDB_P_HOST}"
```

Add immediately after:

```yaml

graphdb-adeptnova:
  externalUrl: "https://${GDB_A_HOST}/"
  ingress:
    host: "${GDB_A_HOST}"
```

(The static fields — `enabled`, `namespace`, `service.type`, `service.nodePort`, `security.enabled` — come from `charts/graphwise-stack/values.yaml` and don't need per-deploy overrides.)

- [ ] **Step 3: Regenerate the overlay and inspect**

```bash
SUB=stroker
scripts/render-values.sh "$SUB"
grep -A3 "^graphdb-adeptnova:" "$HOME/.graphwise-stack/values-${SUB}.yaml"
```

Expected:
```yaml
graphdb-adeptnova:
  externalUrl: "https://graphdb-adeptnova.stroker.semantic-demo.com/"
  ingress:
    host: "graphdb-adeptnova.stroker.semantic-demo.com"
```

- [ ] **Step 4: Verify the umbrella renders successfully against the new overlay**

```bash
helm template graphwise-stack charts/graphwise-stack \
  --namespace graphwise \
  -f "$HOME/.graphwise-stack/values-${SUB}.yaml" \
  | grep -c '^# Source: graphwise-stack/charts/graphdb-adeptnova'
```

Expected: ≥ 4.

- [ ] **Step 5: Commit**

```bash
git add scripts/render-values.sh
git commit -m "render-values: emit graphdb-adeptnova block with externalUrl + ingress.host"
```

---

### Task 12: `validate-stack.sh` — add AdeptNova checks

**Files:**
- Modify: `scripts/validate-stack.sh`

- [ ] **Step 1: Add license + admin Secret presence checks**

Find the existing license check block (around line 313-326). After the `graphdb-projects` block, add:

```bash
# AdeptNova: third GraphDB (RC2), in graphdb-adeptnova namespace.
if kubectl get secret -n graphdb-adeptnova graphdb-license >/dev/null 2>&1; then
    check_pass "graphdb-adeptnova/graphdb-license  (AdeptNova GraphDB mounts this)"
else
    check_fail "graphdb-adeptnova/graphdb-license MISSING" \
               "Run scripts/install-licenses.sh; it auto-installs when the graphdb-adeptnova namespace exists"
fi
if kubectl get secret -n graphdb-adeptnova graphwise-stack-graphdb-adeptnova-admin >/dev/null 2>&1; then
    check_pass "graphdb-adeptnova/graphwise-stack-graphdb-adeptnova-admin  (security-init Job uses this)"
else
    check_fail "graphdb-adeptnova/graphwise-stack-graphdb-adeptnova-admin MISSING" \
               "Run scripts/install-licenses.sh; the AdeptNova admin Secret is created alongside the license"
fi
```

- [ ] **Step 2: Add HTTPS reachability check**

Find the `endpoints=` array (around line 313-326). Add a new entry just after the `graphdb-projects.$APEX` line:

```bash
    "graphdb-adeptnova.$APEX:401:GraphDB AdeptNova (basic auth)"
```

The 401 is expected because the Ingress's nginx basic auth challenges anonymous requests before the upstream GraphDB even sees them.

- [ ] **Step 3: Add a pod readiness check**

Find the pod-status section (search for `kubectl get pods -n graphwise`). Add an analogous block:

```bash
# AdeptNova GraphDB pod
if kubectl get namespace graphdb-adeptnova >/dev/null 2>&1; then
    ready=$(kubectl -n graphdb-adeptnova get pods -l app.kubernetes.io/name=graphdb -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null | tr ' ' '\n' | grep -c true || true)
    total=$(kubectl -n graphdb-adeptnova get pods -l app.kubernetes.io/name=graphdb --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$ready" == "$total" ]] && [[ "$total" -gt 0 ]]; then
        check_pass "graphdb-adeptnova pod ($ready/$total ready)"
    else
        check_fail "graphdb-adeptnova pod NOT ready ($ready/$total)" \
                   "kubectl -n graphdb-adeptnova describe pod -l app.kubernetes.io/name=graphdb"
    fi
fi
```

- [ ] **Step 4: Add the URL line to the final printout**

Find the final URL summary section (around line 370-380, the "GraphDB projects" block). Add:

```bash
  ${BOLD}GraphDB AdeptNova${RESET}        https://graphdb-adeptnova.$APEX/
                            (direct :17200 also reachable from allowed CIDRs)
```

- [ ] **Step 5: Validate**

```bash
bash -n scripts/validate-stack.sh && echo OK
```

Expected: `OK`.

- [ ] **Step 6: Commit**

```bash
git add scripts/validate-stack.sh
git commit -m "validate-stack: add AdeptNova GraphDB checks (license, admin Secret, pod, HTTPS)"
```

---

### Task 13: Documentation updates

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/claude/chart-internals.md`
- Modify: `CONSOLE-GUIDE.md`
- Modify: `infra/README.md`

- [ ] **Step 1: `CLAUDE.md` — add subdomain row**

Find the subdomain table (around the "Subdomain-per-app routing" section). Add a row after the `GraphDB projects` line:

```markdown
| GraphDB AdeptNova | `graphdb-adeptnova.<sub>.<base>` (HTTPS) + direct `:17200` (CIDR-gated) |
```

- [ ] **Step 2: `CLAUDE.md` — add critical-rules note**

Find the "Critical rules" section. Add a new bullet:

```markdown
- **AdeptNova GraphDB is the only direct-port-public service.** Host `:17200` → KIND `:31720` → `graphwise-stack-graphdb-adeptnova` NodePort Service. CIDR allowlist lives in `var.adeptnova_cidrs` and provisions a **standalone** `aws_security_group_rule` resource — NOT an inline `ingress {}` block on `aws_security_group.stack` (that SG sets `lifecycle.ignore_changes = [ingress]` to preserve operator-added Console rules). GraphDB-native security is on for this instance (admin password in `graphdb-adeptnova/graphwise-stack-graphdb-adeptnova-admin`).
```

- [ ] **Step 3: `docs/claude/chart-internals.md` — extend the three-alias note**

Find the GraphDB fullname / alias discussion. Replace the two-alias enumeration with the three-alias version, adding:

```markdown
- `graphdb-adeptnova` — RC2-added, `graphdb-adeptnova` ns. `service.type=NodePort`, `nodePort=31720`. `security.enabled=true` (post-install hook seeds admin pw). Exposed publicly on EC2 host `:17200` via the KIND `extraPortMappings` entry and a CIDR-allowlisted SG rule.
```

- [ ] **Step 4: `CONSOLE-GUIDE.md` — new entry**

Add a section:

```markdown
## GraphDB AdeptNova (RC2)

**Browser admin (basic auth, then GraphDB login):**
- URL: `https://graphdb-adeptnova.<sub>.<base>/`
- nginx basic auth: `demo` / `rdf#rocks`
- GraphDB workbench login: `admin` / `rdf#rocks`

**Direct API (allowed CIDRs only, GraphDB-native auth):**
- URL: `http://<EIP>:17200/` (note: plain HTTP — TLS termination only on the subdomain path)
- HTTP Basic: `admin` / `rdf#rocks`

Both paths reach the same pod. The browser path is gated by nginx basic auth at the Ingress; the direct path is gated by the SG CIDR allowlist (`var.adeptnova_cidrs`) plus GraphDB-native auth.

Rotate the admin password by editing the `graphdb-adeptnova/graphwise-stack-graphdb-adeptnova-admin` Secret and bouncing the security-init Job:

```bash
kubectl -n graphdb-adeptnova delete job -l app.kubernetes.io/component=security-init
helm upgrade --install graphwise-stack ./charts/graphwise-stack ...
```
```

- [ ] **Step 5: `infra/README.md` — document the variable**

Find the variables table. Add:

```markdown
| `adeptnova_cidrs` | `list(string)` | `[]` | CIDRs allowed to reach the AdeptNova GraphDB on host `:17200`. Empty = no SG rule. |
```

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md docs/claude/chart-internals.md CONSOLE-GUIDE.md infra/README.md
git commit -m "docs: document AdeptNova GraphDB (subdomain, critical rule, console guide, tfvar)"
```

---

### Task 14: End-to-end verification on a live EC2

**Why:** Helm templates and `terraform plan` only catch syntax. The end-to-end flow has interactions (KIND port mapping, SG, security-init Job timing) that can only be verified live.

**Files:** None (validation only).

- [ ] **Step 1: Provision (or reuse) a fresh EC2 with the RC2 branch deployed**

From your laptop, in the repo:

```bash
SUB=adeptnova-test
cd infra/terraform
terraform apply \
  -var="subdomain=$SUB" \
  -var='adeptnova_cidrs=["YOUR_LAPTOP_IP/32"]'
cd ../..
```

Capture the EIP from `terraform output public_ip`.

- [ ] **Step 2: SSH in and bootstrap the cluster**

```bash
ssh -i $GRAPHWISE_KEY ec2-user@$EIP 'cd graphwise-stack-aws && \
  ./scripts/cluster-bootstrap.sh && \
  ./scripts/install-licenses.sh && \
  ./scripts/reset-helm.sh --yes adeptnova-test'
```

Expected: completes with `helm install` success and no missing-license errors.

- [ ] **Step 3: Verify the AdeptNova pod, Service, Ingress, and Job ran**

```bash
ssh ec2-user@$EIP '
  kubectl get pods,svc,ingress -n graphdb-adeptnova
  kubectl get jobs -n graphdb-adeptnova
  kubectl logs -n graphdb-adeptnova -l app.kubernetes.io/component=security-init --tail=50
'
```

Expected:
- Pod `Running`, `READY 1/1`.
- Service `NodePort` with `7200:31720/TCP`.
- Ingress with `graphdb-adeptnova.adeptnova-test.semantic-demo.com`.
- Job `Completed`, logs show "Done. Admin password seeded from Secret; security on."

- [ ] **Step 4: Verify HTTPS subdomain path**

From your laptop:

```bash
curl -u demo:'rdf#rocks' -sI https://graphdb-adeptnova.adeptnova-test.semantic-demo.com/rest/repositories
```

Expected: `HTTP/2 401` (GraphDB-native auth challenge — basic auth passed, GraphDB itself wants credentials too).

```bash
curl -u demo:'rdf#rocks' -s https://graphdb-adeptnova.adeptnova-test.semantic-demo.com/rest/repositories \
  -H "Authorization: Basic $(printf 'admin:rdf#rocks' | base64)"
```

Expected: `[]` (empty repo list, HTTP 200).

- [ ] **Step 5: Verify direct port 17200 path (allowed CIDR)**

```bash
curl -u admin:'rdf#rocks' -s http://$EIP:17200/rest/repositories
```

Expected: `[]`.

- [ ] **Step 6: Verify direct port 17200 is unauthenticated 401, not anonymous-open**

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://$EIP:17200/rest/repositories
```

Expected: `401`.

- [ ] **Step 7: Verify direct port 17200 is unreachable from a non-allowed CIDR**

From a host NOT in `adeptnova_cidrs` (e.g. a friend's machine or a cellular-tethered laptop):

```bash
timeout 10 curl -s -o /dev/null -w '%{http_code}\n' http://$EIP:17200/rest/repositories
echo "exit=$?"
```

Expected: curl exits non-zero (timeout) with no HTTP code — SG dropped the SYN.

- [ ] **Step 8: Verify the existing two GraphDBs are still working**

```bash
curl -u demo:'rdf#rocks' -sI https://graphdb.adeptnova-test.semantic-demo.com/rest/repositories
curl -u demo:'rdf#rocks' -sI https://graphdb-projects.adeptnova-test.semantic-demo.com/rest/repositories
```

Expected: both return `HTTP/2 200`.

- [ ] **Step 9: Run the validator**

```bash
ssh ec2-user@$EIP 'cd graphwise-stack-aws && ./scripts/validate-stack.sh'
```

Expected: all checks pass, including the new AdeptNova entries.

- [ ] **Step 10: No commit (verification only)**

If any step fails, fix the offending task above and re-test.

---

### Task 15: Final regression diff against RC1 baseline

**Why:** Belt-and-suspenders confirmation that the existing two GraphDB instances render identical between the RC1 baseline and the post-RC2 state.

**Files:** None (verification only).

- [ ] **Step 1: Render the final RC2 umbrella**

```bash
SUB=stroker  # or whatever you used for the baseline
helm dependency update charts/graphwise-stack
helm template graphwise-stack charts/graphwise-stack \
  --namespace graphwise \
  -f "$HOME/.graphwise-stack/values-${SUB}.yaml" \
  > /tmp/rc2-umbrella-final.yaml
```

- [ ] **Step 2: Extract the existing two instances**

```bash
awk '/^# Source: graphwise-stack\/charts\/graphdb-(embedded|projects)/{flag=1} /^# Source:/{if(!match($0,/graphdb-(embedded|projects)/))flag=0} flag' \
  /tmp/rc2-umbrella-final.yaml > /tmp/rc2-graphdb-existing-final.yaml
```

- [ ] **Step 3: Diff against the RC1 baseline**

```bash
diff /tmp/rc1-graphdb-existing.yaml /tmp/rc2-graphdb-existing-final.yaml
```

Expected: **no output**. If anything appears, investigate before tagging RC2.

- [ ] **Step 4: Confirm new AdeptNova resources are present**

```bash
grep -E '^# Source: graphwise-stack/charts/graphdb-adeptnova' /tmp/rc2-umbrella-final.yaml
```

Expected: lines for `service.yaml`, `ingress.yaml`, `statefulset.yaml`, `basic-auth-secret.yaml`, `security-init-job.yaml`.

- [ ] **Step 5: No commit (verification only)**

---

### Task 16: Tag RC2

**Files:** None (git tag).

- [ ] **Step 1: Verify clean working tree**

```bash
git status
```

Expected: `nothing to commit, working tree clean`.

- [ ] **Step 2: Tag the release**

```bash
git tag -a v1.0.0-rc2 -m "RC2: add AdeptNova GraphDB (third instance, public :17200, CIDR-gated)"
git log --oneline -15
```

- [ ] **Step 3: Push (only if user confirms — destructive enough to warrant explicit OK)**

Do NOT push automatically. Ask the user:

> "All commits + the v1.0.0-rc2 tag are local. Want me to `git push origin main && git push origin v1.0.0-rc2`?"

Only push on explicit yes.

---

## Self-Review

**Spec coverage check:**

- §1 Problem → Task 5 (umbrella alias) + Task 7 (Terraform SG) — covered.
- §2 Goals (1-6) → Task 5/7 (1+2+3+5), Task 4 (4), Tasks 5+6+7+8+9+10+11+12 (5), Task 14 (6) — all covered.
- §3 Non-goals → no tasks needed (negative scope).
- §4 Architecture diagram → Tasks 5+6+7 lay down each layer; Task 14 validates end-to-end — covered.
- §5.1 Chart wiring → Task 5 — covered.
- §5.2.a `service.nodePort` → Task 3 — covered.
- §5.2.b Security init Job → Task 1 (decision) + Task 4 (implementation) — covered.
- §5.3 KIND port mapping → Task 6 — covered.
- §5.4 Security group rule → Task 7 — covered.
- §5.5 HTTPS Ingress → leverages existing template; covered by Task 5 (values) + Task 11 (host derivation).
- §5.6 Script changes → Tasks 8 (cluster-bootstrap), 9 (install-licenses), 10 (reset-helm), 11 (render-values), 12 (validate-stack), 7 (terraform outputs) — covered.
- §5.7 Order of operations → Reset-helm enforces; Task 14 verifies on live deploy — covered.
- §6 Data flow → Task 14 steps 4-7 verify each leg of both flows — covered.
- §7 Error handling → Task 4 Job handles re-run case; Task 10 pre-flight catches missing Secrets; Task 14 steps cover the failure-mode probes — covered.
- §8 Testing → Task 14 — covered.
- §9 Migration / rollback → Documented in Task 13 (CLAUDE.md/CONSOLE-GUIDE.md) — covered.
- §10 Documentation updates → Task 13 — covered.

No gaps.

**Placeholder scan:**

- No "TBD", "TODO", "implement later".
- No "Add appropriate error handling" — error handling is concrete (curl exit-code branches in Task 4, 401-vs-200 expected codes in Task 14, fail-fast in pre-flights).
- No "Similar to Task N" — each task's code is self-contained.
- No "Write tests for the above" — every verification step has concrete commands and expected outputs.

**Type consistency:**

- Service name: `graphwise-stack-graphdb-adeptnova` — consistent in Task 4 (env var `GRAPHDB_URL`), Task 9 (Secret name `graphwise-stack-graphdb-adeptnova-admin`), Task 10 (pre-flight check name), Task 12 (validator check name).
- NodePort: `31720` — consistent in Task 3 (subchart), Task 5 (umbrella values), Task 6 (KIND mapping containerPort).
- Host port: `17200` — consistent in Task 6 (KIND hostPort), Task 7 (SG from_port/to_port), Task 13 (docs).
- Namespace: `graphdb-adeptnova` — consistent in Tasks 5, 8, 9, 10, 12, 13.
- Admin Secret name: `graphwise-stack-graphdb-adeptnova-admin` (per the alias-aware fullname pattern `{release}-{chart}-admin`) — consistent in Task 4 (chart secretKeyRef), Task 9 (create), Task 10 (pre-flight), Task 12 (validator).
- Default password: `rdf#rocks` (repo convention) — consistent in Task 9 (install) and Task 13 (docs).
