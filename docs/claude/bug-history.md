# Resolved bug catalog (recurring footguns to recognize)

The following bugs are now fixed in the chart. Documented for posterity so the next time something looks like one of these we recognize the pattern.

## PoolParty stuck `0/1` looping on Keycloak `uma2-configuration`

Original theory was KIND hairpin-NAT against the public auth URL. Real root cause turned out to be **Ontotext's realm export shipping `${...}` env-var placeholders that the operator-managed KeycloakRealmImport CR doesn't substitute**. The `ppt` client's secret was the literal string `${POOLPARTY_KEYCLOAK_LOGIN_CLIENTSECRET}` so OAuth token exchange failed with `invalid_client`; the `superadmin` user's password was the literal `${POOLPARTY_SUPER_ADMIN_PASSWORD}` so login outright didn't work; and the per-client `.authorizationSettings` block (resources/scopes/policies needed for PoolParty's UMA permission ticket flow) was being silently dropped by the operator's import.

**Fix:** `scripts/extract-poolparty-realm.sh` jq-substitutes the placeholders at extract time + `charts/keycloak-realms/templates/keycloak-authz-import-job.yaml` is a post-install Helm hook that re-imports the authz config via the Keycloak admin REST API (`/admin/realms/<realm>/clients/<uuid>/authz/resource-server/import`). Hairpin-NAT works fine; was never the actual problem.

## `unifiedviews` Deployment in `CrashLoopBackOff`

Entrypoint died with `/__cacert_entrypoint.sh: line 114: /unified-views/run-uv.sh: No such file or directory`. The chart mounts a PVC at `/unified-views` which shadows the image's binaries. The chart already had an `initContainer` named `populate-image-content` that copies the image's `/unified-views/` tree into the PVC, BUT the umbrella's bundled `charts/graphwise-stack/charts/addons-1.0.0.tgz` packaged BOTH the source `charts/addons/charts/unifiedviews/` directory AND a stale pre-packaged `charts/addons/charts/unifiedviews-1.0.0.tgz` tarball. At render time Helm preferred the stale `.tgz`, which predated the initContainer fix, so the deployed Deployment never had the initContainer attached.

**Fix:** delete the inner-subchart tarballs, gitignore `charts/*/charts/*.tgz` and `charts/*/Chart.lock` to prevent recurrence, regenerate the umbrella's bundled tarball from clean source. Lesson: nested-subchart tarballs are a footgun; keep only the source directories in git.

## GraphDB subchart fullname collision under umbrella aliases

The chart's `graphdb.fullname` helper used `.Release.Name` verbatim, which assumed standalone install (`helm install graphdb-embedded ./charts/graphdb`). In umbrella mode with subchart aliases (`graphdb-embedded` and `graphdb-projects` both descending from release `graphwise-stack`), both rendered with the same `metadata.name: graphwise-stack` and silently collided in the merged manifest — only the second alias survived, leaving PoolParty unable to reach `graphdb-embedded:7200`.

**Fix:** helper now produces `<release>-<alias>` form (`graphwise-stack-graphdb-embedded`, `graphwise-stack-graphdb-projects`), and PoolParty's `internalUrl` was updated to match.

## `graphrag-realm-patch` Job `BackoffLimitExceeded` on cold-cache fresh deploys

Surfaced as `Error: failed post-install: 1 error occurred: * job graphrag-realm-patch failed: BackoffLimitExceeded` during `reset-helm.sh`. The patch script's `curl -sf .../clients/<graphrag-realm-uuid>/roles/realm-admin` returned 404, `set -e` aborted the script, and the pod retried 5x before the controller cleaned it up (so no logs survived by the time anyone looked).

Two stacked root causes, BOTH structural:

**(1) Race between `keycloak-bootstrap-admin-job` (hook-weight 5) and the operator-driven `KeycloakRealmImport` CRs.** Realm imports are NOT Helm hooks — they're regular resources processed asynchronously by the Keycloak operator. On a fresh-cache deploy, the realm-import pods spend ~3 min pulling the 250MB Keycloak image before the `<realm>-realm` clients exist in master. Meanwhile bootstrap-admin's "step 6: wire admin composite from `<realm>-realm` master clients" iterates whatever exists *right now* and silently misses any realm whose import hasn't completed. Warm-cache redeploys masked this for months (images already cached → realm imports complete in seconds → race wins → composite gets wired correctly).

**(2) Keycloak v26 removed the composite `realm-admin` role** from the `<realm>-realm` management clients in favor of the granular `manage-realm` / `manage-clients` / `view-*` roles. The patch job's role-binding approach (`POST /users/<id>/role-mappings/clients/<realm-client-id>` with the `realm-admin` role body) was a hidden landmine that only triggered after the bootstrap-admin race made it the load-bearing step.

**Fix:**

- **(A)** bootstrap-admin now reads a space-separated `EXPECTED_REALMS` env var (default `"graphrag poolparty"`, from `.Values.keycloak.bootstrapAdmin.expectedRealms`) and waits up to 5 min on `/realms/<each>/.well-known/openid-configuration` for each before doing step 6 — fixes the race for every Job that depends on the composite chain.
- **(B)** `graphrag-realm-patch-job.yaml` now uses the same composite-wiring approach as bootstrap-admin (scoped to the `graphrag-realm` client) instead of role-binding. Idempotent, race-proof with bootstrap-admin, survives Keycloak's role-model evolution.

Diagnostic shortcut for the next "Job failed but no logs" recurrence:

```bash
helm template g charts/graphwise-stack -f $HOME/.graphwise-stack/values-<sub>.yaml -s charts/keycloak-realms/templates/graphrag-realm-patch-job.yaml > /tmp/j.yaml
sed -i 's|set -euo pipefail|set -euxo pipefail|' /tmp/j.yaml
kubectl -n keycloak delete job graphrag-realm-patch
kubectl apply -f /tmp/j.yaml
```

The `set -x` makes every curl URL + the failing line visible in the pod's logs.
