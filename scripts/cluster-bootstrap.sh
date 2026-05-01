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
KUBERNETES_DASHBOARD_VERSION="v2.7.0"   # raw-YAML install (see Dashboard block below)
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

# Note: the graphwise image-pull Secret (for maven.ontotext.com) used
# to be created here, but it's only consumed by the GraphRAG release
# pods at install time -- not by anything cluster-bootstrap.sh
# installs. Moved to scripts/reset-helm.sh where it actually matters,
# so this script no longer warns about missing ~/.ontotext/maven-*
# files when you're just running cluster-bootstrap to test
# observability.

# ---------------------------------------------------------------------------
# Kubernetes Dashboard (v2.7.0 -- raw YAML install per kubernetes.io docs)
# ---------------------------------------------------------------------------
# v7.x via Helm is the modern path but the chart's hosting URL has
# moved enough times that we can't pin it reliably. The single-file
# kubectl-apply for v2.7.0 has been stable for years and is what the
# official kubernetes.io Dashboard docs still link to as the
# baseline install:
#   https://kubernetes.io/docs/tasks/access-application-cluster/web-ui-dashboard/
#
# Trade-off: older UI than v7.x. For demo cluster introspection it's
# fine. To upgrade to v7.x later, install the chart from whatever the
# project currently publishes and update the Ingress to target
# `kubernetes-dashboard-kong-proxy:443` instead of
# `kubernetes-dashboard:443`.
#
# RBAC: a `dashboard-admin` ServiceAccount bound to cluster-admin so
# the bearer token actually does something.
kubectl apply -f "https://raw.githubusercontent.com/kubernetes/dashboard/${KUBERNETES_DASHBOARD_VERSION}/aio/deploy/recommended.yaml"

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
---
# Long-lived ServiceAccount token Secret. The controller populates
# .data.token within a few seconds. Doesn't expire (lives until
# someone deletes this Secret). Demo-grade convenience -- avoids
# regenerating tokens every 24h. Same cluster-admin RBAC as the
# ephemeral `kubectl create token` path.
apiVersion: v1
kind: Secret
metadata:
  name: dashboard-admin-token
  namespace: kubernetes-dashboard
  annotations:
    kubernetes.io/service-account.name: dashboard-admin
type: kubernetes.io/service-account-token
EOF

# Wait for the controller to populate the Secret's .data.token
# (typically <5s; loop a few seconds in case of API server slowness).
for i in $(seq 1 20); do
    if [ -n "$(kubectl -n kubernetes-dashboard get secret dashboard-admin-token -o jsonpath='{.data.token}' 2>/dev/null)" ]; then
        echo "dashboard-admin-token Secret populated."
        break
    fi
    [ "$i" = "20" ] && echo "WARN: dashboard-admin-token still empty after 20 attempts -- retrieve manually." >&2
    sleep 1
done

# Write a ready-to-upload kubeconfig file at ~/dashboard-kubeconfig.yaml.
# The Dashboard's "Token" login field has a buggy paste handler in
# Chrome/Safari that silently swallows pasted tokens; the "Kubeconfig"
# login option avoids that path entirely. Operators just need to scp
# this one file and upload it via the Dashboard's Kubeconfig picker.
DASHBOARD_KUBECONFIG="$HOME/dashboard-kubeconfig.yaml"
DASHBOARD_TOKEN=$(kubectl -n kubernetes-dashboard get secret dashboard-admin-token \
    -o jsonpath='{.data.token}' | base64 -d)
if [ -n "$DASHBOARD_TOKEN" ]; then
    cat > "$DASHBOARD_KUBECONFIG" <<EOF
# Auto-generated by scripts/cluster-bootstrap.sh.
# Upload this file via the Kubernetes Dashboard's Kubeconfig login
# option to bypass the v2.7.0 token-field paste handler bug.
# Same dashboard-admin / cluster-admin RBAC as the bearer-token path.
# Regenerate by re-running cluster-bootstrap.sh, or rotate the
# underlying Secret with:
#   kubectl -n kubernetes-dashboard delete secret dashboard-admin-token
#   ./scripts/cluster-bootstrap.sh
apiVersion: v1
kind: Config
clusters:
  - name: graphwise
    cluster:
      server: https://kubernetes.default
      insecure-skip-tls-verify: true
contexts:
  - name: graphwise
    context: { cluster: graphwise, user: dashboard-admin }
current-context: graphwise
users:
  - name: dashboard-admin
    user:
      token: ${DASHBOARD_TOKEN}
EOF
    chmod 600 "$DASHBOARD_KUBECONFIG"
    echo "Wrote Dashboard kubeconfig: $DASHBOARD_KUBECONFIG (mode 600)"
fi

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
                name: kubernetes-dashboard
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
echo "Dashboard sign-in: scp ~/dashboard-kubeconfig.yaml to your laptop"
echo "and upload it via the Dashboard's 'Kubeconfig' login option"
echo "(works around the broken token-field paste handler):"
echo "  scp -i <key.pem> ec2-user@<eip>:~/dashboard-kubeconfig.yaml ~/Downloads/"
echo
echo "Or retrieve the raw token (paste-handler permitting):"
echo "  kubectl -n kubernetes-dashboard get secret dashboard-admin-token -o jsonpath='{.data.token}' | base64 -d ; echo"
echo
echo "Next: install the Graphwise stack umbrella Helm chart (Phase C+)."
