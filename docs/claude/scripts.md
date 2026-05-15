# Lifecycle scripts — full reference

Detail backing the script summaries in `CLAUDE.md`.

## `scripts/cluster-bootstrap.sh`

One-time install of cluster operators + observability: ingress-nginx, cert-manager (+ LE `letsencrypt-prod` ClusterIssuer), CNPG, Keycloak operator, metrics-server, **Kubernetes Dashboard** (kubectl apply v2.7.0 + dashboard-admin ServiceAccount + ClusterRoleBinding + permanent `dashboard-admin-token` Secret + auto-generated `~/dashboard-kubeconfig.yaml` for browser sign-in), **kube-prometheus-stack** (Prometheus + Grafana + AlertManager + node-exporter + kube-state-metrics). Provisions per-host Ingresses for the three observability UIs (Dashboard backend-protocol HTTPS; Prometheus basic-auth-gated `demo / rdf#rocks`; Grafana own-login `admin / demo-graphwise-2026`). The `graphwise` image-pull secret (for `maven.ontotext.com`) is created by `reset-helm.sh` — it reads `maven.user`/`maven.pass` from `~/graphwise-secrets.yaml` (consolidated single-file source for all operator secrets; legacy `~/.ontotext/maven-{user,pass}` plain-text files still work as fallback). Idempotent. Required env: `LE_EMAIL`.

## `scripts/cluster-resume.sh`

Restart the KIND cluster after an EC2 stop/start. Finds the cluster's node containers via the `io.x-k8s.kind.cluster=<name>` label, `docker start`s them, and sets `--restart=unless-stopped` so subsequent reboots are a non-event. Polls `/readyz` until the API answers.

## `scripts/cluster-stop.sh`

Politely quiesce the application workloads (graphwise + graphrag namespaces) before stopping the EC2. Scales every Deployment + StatefulSet to 0 replicas, waits up to 90s for pods to drain, then prints the AWS CLI / Console commands to stop the EC2. Idempotent. Operator namespaces are left running -- they tolerate hard stop. PVCs and Secrets all preserved. Optional polish over a hard EC2 stop, which apps tolerate via WAL recovery anyway.

## `scripts/render-values.sh [--umbrella|--graphrag|--both] <subdomain> [base_domain]`

Emits Helm values overlays. **Auto-invoked by `reset-helm.sh`** before each `helm upgrade --install` — the standard deploy flow does not call it manually. Default (`--both`) writes two files — `$HOME/.graphwise-stack/values-<sub>.yaml` (umbrella) and `$HOME/.graphwise-stack/values-<sub>-graphrag.yaml` (graphrag). (Persistent across reboots; AL2023 wipes `/tmp` on boot, so the prior `/tmp` location was a footgun after `cluster-stop.sh` → start. Override with `OUT_DIR`.) `--umbrella`/`--graphrag` emit just one to stdout. Computes every per-app hostname (`poolparty.<sub>.<base>`, `auth.<sub>.<base>`, `graphrag.<sub>.<base>`, `graphdb.<sub>.<base>`, `graphdb-projects.<sub>.<base>`, `adf.<sub>.<base>`, `semantic-workbench.<sub>.<base>`, `graphviews.<sub>.<base>`, `rdf4j.<sub>.<base>`, `unifiedviews.<sub>.<base>`; console at apex `<sub>.<base>`). Run manually only to inspect the rendered overlay or feed it into a non-destructive `helm upgrade`.

## `scripts/install-licenses.sh`

kubectl-creates the three license Secrets (`poolparty-license`, `graphdb-license`, `unifiedviews-license`) in the `graphwise` namespace from `files/licenses/*`. Idempotent.

## `scripts/preflight-reset-helm.sh [--skip-graphrag] [--strict]`

Read-only pre-flight gate for `reset-helm.sh`. Verifies every precondition the destructive uninstall + reinstall will need so the operator catches broken-from-the-start cases before Helm spends 10-15 min on doomed pods. Categories: tools (`kubectl`/`helm`/`jq`/`python3`/`curl`/`dig`/`openssl` + PyYAML), cluster reachability (early-aborts with exit 2 if `kubectl get nodes` fails -- no point checking anything else), operator pods Ready (cert-manager / ingress-nginx / cnpg-system / keycloak-operator / reflector), `letsencrypt-prod` ClusterIssuer Ready, repo state (`charts/keycloak-realms/files/poolparty-realm.json` exists AND has no leftover `${POOLPARTY_*}` placeholders), three license files on disk, `~/graphwise-secrets.yaml` field-by-field completeness (parsed via Python+PyYAML), DNS apex + sample-wildcard resolution + match, AWS IMDSv2 reachable + instance role bound (cert-manager DNS-01 needs it), and an actual HTTP basic-auth probe against `https://maven.ontotext.com/v2/` -- catches typo'd creds before ImagePullBackOff. Reports `~/wildcard-tls-saved.yaml` presence as informational (saves an LE rate-limit slot). Color-coded categorized output. Exit 0 = pass; 1 = any required check failed (or any warning in `--strict`); 2 = cluster unreachable. `--skip-graphrag` mirrors `reset-helm.sh`'s flag (skips maven auth + `graphrag-secrets` blocks). Read-only; idempotent; safe to re-run after every fix. Standalone (not wired into reset-helm.sh) -- operator runs it manually as the step between `install-licenses.sh` and `reset-helm.sh`.

## `scripts/validate-bootstrap.sh`

One-shot post-cluster-bootstrap health check. Read-only; clears screen and walks every operator namespace (cert-manager, ingress-nginx, cnpg-system, monitoring, kubernetes-dashboard, keycloak operator, kube-system metrics-server), the `letsencrypt-prod` ClusterIssuer, the `~/dashboard-kubeconfig.yaml` artifact, and a cluster-wide non-Running-pod sweep. Prints color-coded pass/fail per check + an overall verdict. Exit 0 on green, 1 on any failure (so it can gate automation). Run any time after `cluster-bootstrap.sh`. Image-pull secret check is intentionally NOT here -- that secret is created by `reset-helm.sh`, not bootstrap; checked in `validate-stack.sh` instead.

## `scripts/validate-stack.sh`

One-shot post-`reset-helm.sh` health check. Read-only; clears screen and walks the helm releases (umbrella + optional graphrag), every workload pod across `graphwise` / `keycloak` / `graphrag` namespaces, the three license Secrets, the `graphwise` image-pull secret in both consuming namespaces, the GraphDB rename (catches alias-collision regression), `staging-data` PVCs in both namespaces, the two Keycloak post-install Jobs (`keycloak-bootstrap-admin` + `keycloak-authz-import`), every cert-manager Certificate, OIDC issuer match for `master` / `poolparty` / `graphrag` realms (the historic stack-breaker), and an HTTPS reachability sweep against every app URL with per-app expected status codes. Closes with a "Where to click next" panel listing key login URLs + credentials. Reads `GRAPHWISE_APEX` env var (set by cloud-init); falls back to deriving from Ingresses. Exit 0 on green, 1 on any failure.

## `scripts/reset-helm.sh [--yes] [--skip-graphrag] <subdomain> [base_domain]`

Wipe and reinstall the umbrella (and graphrag unless skipped). Pre-flight: checks the three license Secrets (`poolparty-license`, `graphdb-license`, `unifiedviews-license`) exist in `graphwise` ns; if missing, fails fast with a hint to run `install-licenses.sh` first. Then uninstalls graphrag first (if present) then umbrella, deletes all PVCs in `graphwise` / `keycloak` / `graphrag`, re-renders both values overlays via `render-values.sh`, runs `helm dependency update` on `charts/graphwise-stack` (and on `charts/vendor/graphrag` unless `--skip-graphrag`), then `helm upgrade --install` umbrella, then graphrag (unless skipped), each with `--timeout 15m`. `--yes` skips the destructive-confirmation prompt; `--skip-graphrag` is the umbrella-only path for operators without Maven creds yet (rerun without the flag once they have credentials — umbrella is upgraded in place, graphrag is installed fresh). The arg parser accepts both flags in any position. Subdomain and base-domain are validated against RFC 1123 before anything destructive runs (so e.g. a `--yes` typo can't end up in the base-domain slot). Does **not** touch operators installed by `cluster-bootstrap.sh`. **Side-effect:** re-renders the apex landing page ConfigMap via Helm `tpl` so the console always reflects current values.

## Laptop-side helpers (`scripts/laptop/`)

- `push-to-ec2.sh`, `pull-from-ec2.sh` — legacy backup, deprecated.
- `pull-config.sh` / `push-config.sh` — symmetric deployment-state pair. One command pulls/pushes `~/graphwise-secrets.yaml` + the three license files + the live wildcard TLS cert.
  - `pull-config.sh` writes a dated snapshot folder at `~/Downloads/graphwise-config-<UTC-timestamp>/` (each pull stands alone — no clobber of `$HOME`), captures the EC2's live `charts/graphwise-stack/values.yaml` + diff vs the git baseline, and grabs `~/dashboard-kubeconfig.yaml` for convenience (NOT pushed back — the bearer token is tied to that cluster's signing key).
  - `push-config.sh` run with no flags **auto-discovers the most recent snapshot** under `~/Downloads/graphwise-config-*` and pushes its contents to the canonical paths the downstream EC2 scripts read; explicit `--secrets-file` / `--licenses-dir` override the auto-discovery for older snapshots.
- `cluster-bootstrap.sh` detects the saved cert at `~/wildcard-tls-saved.yaml` and applies the Secret BEFORE creating the Certificate resource (cert-manager skips the LE issuance call → saves a per-week rate-limit slot).
