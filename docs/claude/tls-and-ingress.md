# TLS architecture — wildcard cert via Route 53 DNS-01

Detail backing the TLS rule in `CLAUDE.md`.

One LE-prod wildcard cert (`<sub>.<base>` + `*.<sub>.<base>`) covers every Ingress in the stack. The cert lives in the `cert-manager` namespace as a Secret named `wildcard-tls`; [kubernetes-reflector](https://github.com/emberstack/kubernetes-reflector) mirrors it into every consuming namespace (`graphwise`, `graphrag`, `keycloak`, `kubernetes-dashboard`, `monitoring`). Every Ingress's `tls.secretName` is the literal `wildcard-tls` — no per-Ingress Certificate, no cert-manager annotation on app Ingresses.

## Why DNS-01 instead of HTTP-01

LE refuses to issue a wildcard cert via HTTP-01 (HTTP-01 only proves ownership of the exact hostname being challenged). DNS-01 writes a `_acme-challenge.<host>` TXT record that LE reads to prove zone ownership, which works for both apex and wildcard SANs in one Order.

## Why a wildcard

Pre-wildcard, every Ingress had its own Certificate → 15 Orders per deploy → instant rate-limit on iteration. With wildcards, one Order covers the whole stack: 5 wildcard reissues per week per `<sub>.<base>` is effectively unlimited at our pace.

## How cert-manager authenticates to Route 53

No AWS access key Secret in the cluster:

```
cert-manager pod → AWS SDK → IMDSv2 (EC2 metadata)
                → EC2 instance role (graphwise-stack-<sub>-ec2-role)
                → route53:ChangeResourceRecordSets on hostedzone/<route53_zone_id>
```

The role's Route 53 policy is scoped to one hostedzone ARN (Terraform `var.route53_zone_id`), so even a leaked role token can only edit DNS for this one zone. Required: `metadata_options.http_put_response_hop_limit >= 2` on `aws_instance.stack` so pods can reach IMDSv2 through kube-proxy. Set in Terraform.

## Why letsencrypt-prod only (no staging)

We tried staging-as-default and reverted:

- LE staging certs chain to "Pretend Pear X1" — a CA that's not in any default trust store.
- **Browsers** can override an untrusted cert via "Advanced → Proceed". XHR/fetch from the loaded page, however, doesn't honor the click-through in Chrome/Safari — first symptom was the Kubernetes Dashboard hanging on `Http failure response for api/v1/csrftoken/login: 0 Unknown Error`.
- **JVM clients** (PoolParty → Keycloak `uma2-configuration`, graphrag-conversation → Keycloak JWKS) have no override mechanism at all. TLS handshake fails, PoolParty hangs forever in startup-probe loops, the stack doesn't come up.
- The only way to make staging work for in-cluster JVM HTTPS calls would be to inject the LE staging root into every pod's truststore — which we don't control image-side. Dead end.

## Rate-limit math

LE prod limits, by bucket — wildcard collapses most of them:

| Limit | Window | Scope | Wildcard impact |
|---|---|---|---|
| 5 duplicate certs per identifier-set | 168h | Exact set of FQDNs | One identifier-set per `<sub>.<base>`. 5 fresh deploys/week per subdomain. |
| 50 certs per registered domain | 168h | Per Public Suffix List entry | One cert per deploy (not 15). 50 deploys/week per `semantic-demo.com`. |
| 300 New Orders per ACME account | 3h | — | Negligible. |
| 5 Failed Validations per account+hostname | 1h | — | Separate, fast recovery. |

If you ever need more headroom: rotate subdomain (`stroker` → `kent`) for fresh per-identifier-set bucket; rotate `base_domain` in `terraform.tfvars` for fresh everything. Or use `helm upgrade` instead of `reset-helm.sh` — upgrade-in-place doesn't reissue certs.

## Reflector

[emberstack/reflector](https://github.com/emberstack/kubernetes-reflector) installed by `cluster-bootstrap.sh`. The Certificate's `secretTemplate.annotations` lists every target namespace; reflector copies on creation and re-syncs on every cert renewal. If `validate-stack.sh` reports `wildcard-tls MISSING in '<ns>' namespace`, the reflector pod isn't running — `kubectl get pods -n kube-system -l app.kubernetes.io/name=reflector`.

## Saved-cert shortcut

`cluster-bootstrap.sh` detects a saved cert at `~/wildcard-tls-saved.yaml` and applies the Secret BEFORE creating the Certificate resource. cert-manager then skips the LE issuance call → saves a per-week rate-limit slot. The pull/push-config laptop scripts handle saving the live cert into the snapshot.
