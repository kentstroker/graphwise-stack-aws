# Keycloak — hostname, Ingress, realm import, post-install Jobs

Detail backing the Keycloak rules in `CLAUDE.md`.

## Hostname rule (the #1 cause of stack breakage)

Spring Security's `NimbusJwtDecoder.withIssuerLocation()` does a **strict equality check** between the URL the OIDC client is handed and the `issuer` field in Keycloak's discovery doc. If they don't match exactly, every webapp's `jwtDecoder` bean throws at boot (`IllegalStateException: The Issuer ... did not match`) and the app is dead until you fix the URL and recreate.

Set on the Keycloak CR at `charts/graphwise-stack/templates/keycloak.yaml`:

```yaml
spec:
  hostname:
    hostname: auth.<sub>.<base>     # NO /auth path
    strict: true
```

Issuer claim becomes `https://auth.<sub>.<base>/realms/<realm>`. Every OIDC client (PoolParty, ADF, Semantic Workbench, graphrag-conversation) must point at exactly this URL. Confirm with:

```bash
curl -s https://auth.<sub>.<base>/realms/master/.well-known/openid-configuration | jq -r .issuer
# Must show: https://auth.<sub>.<base>/realms/master
```

## Ingress lesson (the one that bit us)

The Keycloak operator (v26.x) generates an Ingress whose shape is driven by `spec.http.httpEnabled`. With `httpEnabled: true` (our case — TLS terminates at ingress-nginx, the Keycloak pod speaks plain HTTP internally) the operator emits an Ingress with **no `tls:` block**. cert-manager's ingress-shim only mints a Certificate when an Ingress carries a `tls.hosts` + `tls.secretName` pair, so the `cert-manager.io/cluster-issuer` annotation alone produced an HTTP-only Ingress with no LE cert and every `https://auth.<apex>` request from in-cluster clients failed the TLS handshake.

The operator's CR doesn't expose a way to inject `tls:` directly. Fix shipped in this repo:

1. `charts/graphwise-stack/templates/keycloak.yaml` sets `spec.ingress.enabled: false` — operator stops creating its own Ingress.
2. `charts/graphwise-stack/templates/keycloak-ingress.yaml` ships our own Ingress with the TLS block, the cert-manager annotation, and backend `<keycloak-name>-service:8080`.

Don't re-enable the operator-managed Ingress without re-checking that the TLS block lands on the resulting object.

## Realm export `${...}` placeholder substitution

Ontotext's `poolparty-keycloak` image ships a realm JSON with literal `${POOLPARTY_*}` env-var-style placeholders the operator-managed `KeycloakRealmImport` CR doesn't substitute. Without intervention, Keycloak imports the literal strings as the `superadmin` password and `ppt` client secret, breaking every PoolParty login.

`scripts/extract-poolparty-realm.sh` jq-substitutes both at extract time as part of producing the realm JSON the chart ships:

- `(.clients[] | select(.clientId == "ppt") | .secret) = "ohIP3x4XuoCsGDsGlZRvNvO5VN6veFb5"` (PoolParty image's baked-in client secret — image-version coupled; revisit if the image is bumped)
- `(.users[] | select(.username == "superadmin") | .credentials[0].value) = "poolparty"` + `temporary = false`

Image-version coupling is documented in the script's comment block. To check for new placeholders in a future image bump: `grep -oE '\${[A-Z_]+}' charts/keycloak-realms/files/poolparty-realm.json | sort -u`.

## Keycloak authz-import post-install Job

The `KeycloakRealmImport` CR ALSO drops the per-client `.authorizationSettings` block (resources/scopes/policies). PoolParty needs this for its UMA permission ticket flow — without it, the conversation login lands but every authorized request returns `Client does not support permissions`.

`charts/keycloak-realms/templates/keycloak-authz-import-job.yaml` is a Helm `post-install,post-upgrade` Job (`hook-weight: 10`, runs after the umbrella's keycloak-bootstrap-admin Job at weight 5) that:

1. Builds a ConfigMap at chart render time iterating over the realm JSON's clients-with-`authorizationSettings` (currently just `ppt`), emitting one `<clientId>.json` key per client.
2. The Job mounts that ConfigMap, gets an admin token via password grant against the master realm using the existing `poolparty-auth-admin` Secret (which the umbrella's bootstrap-admin Job already created), and for each client: fetches the UUID, PUTs the client representation with `authorizationServicesEnabled = true`, POSTs the authz config to `/admin/realms/<realm>/clients/<uuid>/authz/resource-server/import`.

Idempotent, generic across clients (any future client with `authorizationSettings` is auto-handled). Container is `alpine:3.20` + apk-add `bash curl jq` — same pattern as the bootstrap-admin Job.

## graphrag-realm-patch post-install/upgrade Job

`KeycloakRealmImport` CRs are **import-once-only**. The Keycloak operator marks `status.conditions.Done=True` after the first successful import and never re-imports a given CR — even if the spec changes (e.g., a chart-template fix or a new apex hostname). The first deploy of this stack imported the graphrag realm with `redirectUris` like `https://graphrag../*` (empty subdomain/baseDomain due to a Helm globals-propagation bug); subsequent `helm upgrade`s silently no-op'd, the chatbot login failed with `Invalid parameter: redirect_url`, and the only fix was to manually delete the realm + CR + helm upgrade.

`charts/keycloak-realms/templates/graphrag-realm-patch-job.yaml` is a Helm `post-install,post-upgrade` Job that runs after every helm operation and idempotently PATCHes the graphrag realm via the Keycloak admin REST API:

- `chatbot-app-client.redirectUris` ← computed from the current subdomain/baseDomain
- `chatbot-app-client.webOrigins` ← same
- `conversation-api-client.webOrigins` ← same

Auth flow mirrors `keycloak-bootstrap-admin-job.yaml`: wait for `/realms/graphrag/.well-known/openid-configuration`, get a temp-admin token from master, PUT the client representation. Runs regardless of whether the `KeycloakRealmImport` CR re-ran. Gated by `.Values.graphrag.enabled`.

## bootstrap-admin race fix (cold-cache deploys)

The umbrella's `keycloak-bootstrap-admin-job` (hook-weight 5) used to assume the `<realm>-realm` clients existed in `master` by the time it ran step 6 (wire admin composite roles). Realm imports are NOT Helm hooks — they're regular resources processed asynchronously by the Keycloak operator. On a fresh-cache deploy, the realm-import pods spend ~3 min pulling the 250MB Keycloak image, so the bootstrap-admin race lost on cold caches but won on warm ones.

Bootstrap-admin now reads a space-separated `EXPECTED_REALMS` env var (default `"graphrag poolparty"`, from `.Values.keycloak.bootstrapAdmin.expectedRealms`) and waits up to 5 min on `/realms/<each>/.well-known/openid-configuration` for each before doing step 6. Fixes the race for every Job that depends on the composite chain.
