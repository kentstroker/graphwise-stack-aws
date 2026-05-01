#!/usr/bin/env bash
# Phase B -- install cluster operators and prerequisites into the
# single-node KIND cluster created by the EC2 cloud-init bootstrap.
#
# Run as the named user, after:
#   1. The KIND cluster is up (cloud-init handles this).
#   2. GoDaddy A records for <subdomain> + *.<subdomain> point at the EIP.
#      Cert-manager will retry HTTP-01 challenges until DNS resolves,
#      so this script does NOT block on DNS -- but no Certificate will
#      go Ready until DNS is correct.
#   3. ~/.ontotext/maven-user and maven-pass exist, with the Graphwise
#      registry credentials. (Optional -- the image-pull secret step is
#      skipped if these files are absent. Charts that need it will fail
#      at install time with ImagePullBackOff until you add them.)
#
# Required env:
#   LE_EMAIL        -- email address for the Let's Encrypt ACME account.
#                      Used for renewal-reminder mail; LE will reject
#                      empty/malformed values.
#   GRAPHWISE_APEX  -- the apex hostname for the deployment, e.g.
#                      "stroker.semantic-proof.com". Cloud-init writes
#                      this to /etc/profile.d/graphwise.sh so login
#                      shells inherit it; only set manually if invoking
#                      from a non-login context. Used to build the
#                      observability ingress hostnames
#                      (dashboard.<apex>, prometheus.<apex>,
#                      grafana.<apex>).
#
# Idempotent: safe to re-run. helm upgrade --install handles
# repeat installs; kubectl create namespace tolerates AlreadyExists.

set -euo pipefail

: "${LE_EMAIL:?LE_EMAIL must be set, e.g. LE_EMAIL=you@example.com $0}"
: "${GRAPHWISE_APEX:?GRAPHWISE_APEX must be set, e.g. GRAPHWISE_APEX=stroker.semantic-proof.com $0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Pinned versions. Bump deliberately and re-test.
INGRESS_NGINX_CHART_VERSION="4.11.3"
CERT_MANAGER_VERSION="v1.16.2"
CNPG_CHART_VERSION="0.22.1"
KEYCLOAK_OPERATOR_VERSION="26.4.2"
METRICS_SERVER_CHART_VERSION="3.12.2"
KUBERNETES_DASHBOARD_VERSION="7.10.0"
KUBE_PROMETHEUS_STACK_VERSION="65.5.0"

# Same demo basic-auth credentials as graphdb / rdf4j: demo / rdf#rocks.
# APR-MD5 hash, regenerable with `htpasswd -nb demo 'rdf#rocks'`.
# Documented in CHEATSHEET.md and SETUP.md.
GRAPHWISE_BASIC_AUTH_HTPASSWD='demo:$apr1$1Ub6kYrD$xxG9zJZXPddeN2WT8E/Ro/'

echo "=== Cluster bootstrap starting at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# ---------------------------------------------------------------------------
# Sanity: KIND cluster reachable
# ---------------------------------------------------------------------------
if ! kubectl cluster-info --context kind-graphwise >/dev/null 2>&1; then
    echo "ERROR: kind-graphwise context not reachable. Is the cluster up?"
    echo "  kind get clusters"
    exit 1
fi
kubectl config use-context kind-graphwise

echo "Waiting for cluster nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s

# ---------------------------------------------------------------------------
# Helm repos
# ---------------------------------------------------------------------------
# `helm repo add` is idempotent in modern Helm (it overwrites the
# existing entry). Don't silence its output; if a repo add fails for
# real (DNS issue, registry outage), we want to see it surface here
# rather than later as "Error: repo X not found" mid-install.
add_repo() {
    local name="$1" url="$2"
    if ! helm repo add "$name" "$url" 2>&1; then
        echo "ERROR: failed to add helm repo '$name' ($url)" >&2
        exit 1
    fi
}
add_repo ingress-nginx        https://kubernetes.github.io/ingress-nginx
add_repo jetstack             https://charts.jetstack.io
add_repo cnpg                 https://cloudnative-pg.github.io/charts
add_repo metrics-server       https://kubernetes-sigs.github.io/metrics-server/
add_repo prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Note: Kubernetes Dashboard 7.x is published as an OCI chart, not via
# a Helm HTTP repo. The old https://kubernetes.github.io/dashboard URL
# was retired with the v7 release. Helm 3.8+ resolves OCI references
# directly at install time, so no `helm repo add` needed.

# ---------------------------------------------------------------------------
# Namespaces
# ---------------------------------------------------------------------------
# - ingress-nginx: ingress controller
# - cert-manager:  ACME / Certificate / Issuer controllers
# - cnpg-system:   CloudNativePG Postgres operator
# - keycloak:      Keycloak operator + Keycloak instance + its Postgres
# - graphwise:     PoolParty, GraphDB, ES, add-ons
# - graphrag:      GraphRAG chatbot/conversation/components/workflows + n8n Postgres
for ns in ingress-nginx cert-manager cnpg-system keycloak graphwise graphrag kubernetes-dashboard monitoring; do
    kubectl get namespace "$ns" >/dev/null 2>&1 || kubectl create namespace "$ns"
done

# ---------------------------------------------------------------------------
# ingress-nginx (KIND-tuned)
# ---------------------------------------------------------------------------
# KIND's recommended pattern: schedule the controller on a node labelled
# ingress-ready=true (set in kind-config.yaml), bind hostPort 80/443
# (KIND port-maps those to the EC2 host), tolerate the control-plane
# taint so single-node clusters work.
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --version "$INGRESS_NGINX_CHART_VERSION" \
    --set controller.hostPort.enabled=true \
    --set controller.hostPort.ports.http=80 \
    --set controller.hostPort.ports.https=443 \
    --set controller.service.type=NodePort \
    --set-string controller.nodeSelector.ingress-ready=true \
    --set-string controller.tolerations[0].key=node-role.kubernetes.io/control-plane \
    --set-string controller.tolerations[0].operator=Equal \
    --set-string controller.tolerations[0].effect=NoSchedule \
    --set-string controller.tolerations[1].key=node-role.kubernetes.io/master \
    --set-string controller.tolerations[1].operator=Equal \
    --set-string controller.tolerations[1].effect=NoSchedule \
    --set controller.publishService.enabled=true \
    --set controller.config.proxy-body-size=100m \
    --set controller.config.proxy-read-timeout=300 \
    --set controller.config.proxy-send-timeout=300 \
    --wait --timeout 5m

# ---------------------------------------------------------------------------
# cert-manager + ClusterIssuer (Let's Encrypt prod, HTTP-01 via ingress-nginx)
# ---------------------------------------------------------------------------
helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --version "$CERT_MANAGER_VERSION" \
    --set crds.enabled=true \
    --wait --timeout 5m

# The ClusterIssuer references ingress-nginx by class name. cert-manager
# polls the ACME server when a Certificate is created (via Ingress
# tls.secretName) and HTTP-01-challenges via a temporary Ingress.
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${LE_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          ingress:
            class: nginx
EOF

# ---------------------------------------------------------------------------
# CNPG (cloud-native Postgres operator)
# ---------------------------------------------------------------------------
helm upgrade --install cnpg cnpg/cloudnative-pg \
    --namespace cnpg-system \
    --version "$CNPG_CHART_VERSION" \
    --wait --timeout 5m

# ---------------------------------------------------------------------------
# Keycloak operator + CRDs
# ---------------------------------------------------------------------------
# CRDs first (cluster-scoped), then the operator into the keycloak ns.
kubectl apply -f "https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${KEYCLOAK_OPERATOR_VERSION}/kubernetes/keycloaks.k8s.keycloak.org-v1.yml"
kubectl apply -f "https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${KEYCLOAK_OPERATOR_VERSION}/kubernetes/keycloakrealmimports.k8s.keycloak.org-v1.yml"
kubectl -n keycloak apply -f "https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${KEYCLOAK_OPERATOR_VERSION}/kubernetes/kubernetes.yml"

# ---------------------------------------------------------------------------
# metrics-server (for HPA + `kubectl top`)
# ---------------------------------------------------------------------------
# --kubelet-insecure-tls is required on KIND because the kubelet's
# serving cert isn't signed by the cluster CA. NOT for production.
helm upgrade --install metrics-server metrics-server/metrics-server \
    --namespace kube-system \
    --version "$METRICS_SERVER_CHART_VERSION" \
    --set 'args[0]=--kubelet-insecure-tls' \
    --wait --timeout 5m

# ---------------------------------------------------------------------------
# Image pull secret -- maven.ontotext.com (Graphwise private registry)
# ---------------------------------------------------------------------------
# The same `graphwise` secret name is referenced by the GraphRAG
# umbrella chart (global.imagePullSecrets) and by every chart we'll
# write that pulls from maven.ontotext.com. Created in both
# graphrag and graphwise namespaces.
if [[ -f "$HOME/.ontotext/maven-user" && -f "$HOME/.ontotext/maven-pass" ]]; then
    MAVEN_USER=$(tr -d '[:space:]' < "$HOME/.ontotext/maven-user")
    MAVEN_PASS=$(tr -d '[:space:]' < "$HOME/.ontotext/maven-pass")
    for ns in graphrag graphwise; do
        kubectl -n "$ns" delete secret graphwise --ignore-not-found
        kubectl -n "$ns" create secret docker-registry graphwise \
            --docker-server=maven.ontotext.com \
            --docker-username="$MAVEN_USER" \
            --docker-password="$MAVEN_PASS"
    done
    echo "Created 'graphwise' image-pull secret in namespaces: graphrag, graphwise"
else
    echo "WARNING: ~/.ontotext/maven-user and/or maven-pass not found."
    echo "         Skipping image-pull secret. Charts that need it will"
    echo "         fail at install time with ImagePullBackOff."
fi

# ---------------------------------------------------------------------------
# Kubernetes Dashboard
# ---------------------------------------------------------------------------
# 7.x ships with a Kong gateway in front of the dashboard pods --
# the Service to expose is `kubernetes-dashboard-kong-proxy` on 443
# (HTTPS internally). ingress-nginx talks to it with
# backend-protocol=HTTPS.
#
# We disable the chart's own Ingress and ship our own (matches every
# other app in this stack). RBAC: a `dashboard-admin` ServiceAccount
# bound to cluster-admin so the bearer token actually does something.
#
# Chart is published as OCI (no `helm repo add`); Helm 3.8+ resolves
# the oci:// reference at install time.
helm upgrade --install kubernetes-dashboard \
    oci://registry.k8s.io/dashboard/kubernetes-dashboard \
    --namespace kubernetes-dashboard \
    --version "$KUBERNETES_DASHBOARD_VERSION" \
    --set 'app.ingress.enabled=false' \
    --wait --timeout 5m

kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dashboard-admin
  namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dashboard-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: dashboard-admin
    namespace: kubernetes-dashboard
EOF

# ---------------------------------------------------------------------------
# kube-prometheus-stack (Prometheus + Grafana + AlertManager +
# node-exporter + kube-state-metrics + 30 default dashboards)
# ---------------------------------------------------------------------------
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --version "$KUBE_PROMETHEUS_STACK_VERSION" \
    -f "$REPO_ROOT/charts/observability/kube-prometheus-stack-values.yaml" \
    --wait --timeout 10m

# ---------------------------------------------------------------------------
# Basic-auth secrets for observability ingresses
# ---------------------------------------------------------------------------
# Same demo creds (demo / rdf#rocks) as graphdb / rdf4j. ingress-nginx
# requires the secret to live in the same namespace as the Ingress.
for ns in kubernetes-dashboard monitoring; do
    kubectl -n "$ns" create secret generic graphwise-basic-auth \
        --from-literal=auth="$GRAPHWISE_BASIC_AUTH_HTPASSWD" \
        --dry-run=client -o yaml | kubectl apply -f -
done

# ---------------------------------------------------------------------------
# Observability Ingresses (dashboard / prometheus / grafana)
# ---------------------------------------------------------------------------
# Each Ingress: cert-manager-issued LE cert per host, basic-auth at
# the proxy, backend service in its own namespace. No app-side
# authentication beyond that for now (Prometheus has none of its own;
# Grafana has its own login but we add basic auth as a coarse outer
# gate; Dashboard requires a bearer token after basic auth).
#
# cluster-bootstrap.sh re-applies these on every run so config drift
# is self-healing.

# --- Kubernetes Dashboard
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kubernetes-dashboard
  namespace: kubernetes-dashboard
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/auth-type: basic
    nginx.ingress.kubernetes.io/auth-secret: graphwise-basic-auth
    nginx.ingress.kubernetes.io/auth-realm: "Graphwise observability"
    nginx.ingress.kubernetes.io/backend-protocol: HTTPS
    nginx.ingress.kubernetes.io/proxy-body-size: 100m
spec:
  ingressClassName: nginx
  tls:
    - hosts: ["dashboard.${GRAPHWISE_APEX}"]
      secretName: dashboard-tls
  rules:
    - host: "dashboard.${GRAPHWISE_APEX}"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kubernetes-dashboard-kong-proxy
                port:
                  number: 443
EOF

# --- Prometheus
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: prometheus
  namespace: monitoring
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/auth-type: basic
    nginx.ingress.kubernetes.io/auth-secret: graphwise-basic-auth
    nginx.ingress.kubernetes.io/auth-realm: "Graphwise observability"
spec:
  ingressClassName: nginx
  tls:
    - hosts: ["prometheus.${GRAPHWISE_APEX}"]
      secretName: prometheus-tls
  rules:
    - host: "prometheus.${GRAPHWISE_APEX}"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kube-prometheus-stack-prometheus
                port:
                  number: 9090
EOF

# --- Grafana
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: monitoring
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/auth-type: basic
    nginx.ingress.kubernetes.io/auth-secret: graphwise-basic-auth
    nginx.ingress.kubernetes.io/auth-realm: "Graphwise observability"
spec:
  ingressClassName: nginx
  tls:
    - hosts: ["grafana.${GRAPHWISE_APEX}"]
      secretName: grafana-tls
  rules:
    - host: "grafana.${GRAPHWISE_APEX}"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kube-prometheus-stack-grafana
                port:
                  number: 80
EOF

echo "=== Cluster bootstrap complete at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo
echo "Verify:"
echo "  kubectl get pods -A"
echo "  kubectl get clusterissuer letsencrypt-prod"
echo "  kubectl get ingress -A"
echo
echo "Observability URLs (after cert-manager issues certs ~30-60s):"
echo "  Dashboard:  https://dashboard.${GRAPHWISE_APEX}/"
echo "  Prometheus: https://prometheus.${GRAPHWISE_APEX}/"
echo "  Grafana:    https://grafana.${GRAPHWISE_APEX}/        (admin / demo-graphwise-2026)"
echo
echo "Get a Dashboard login token (paste into the Dashboard's login screen):"
echo "  kubectl -n kubernetes-dashboard create token dashboard-admin --duration=24h"
echo
echo "Next: install the Graphwise stack umbrella Helm chart (Phase C+)."
