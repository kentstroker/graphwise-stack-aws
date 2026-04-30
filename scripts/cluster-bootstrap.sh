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
#   LE_EMAIL  -- email address for the Let's Encrypt ACME account.
#                Used for renewal-reminder mail; LE will reject empty/
#                malformed values.
#
# Idempotent: safe to re-run. helm upgrade --install handles
# repeat installs; kubectl create namespace tolerates AlreadyExists.

set -euo pipefail

: "${LE_EMAIL:?LE_EMAIL must be set, e.g. LE_EMAIL=you@example.com $0}"

# Pinned versions. Bump deliberately and re-test.
INGRESS_NGINX_CHART_VERSION="4.11.3"
CERT_MANAGER_VERSION="v1.16.2"
CNPG_CHART_VERSION="0.22.1"
KEYCLOAK_OPERATOR_VERSION="26.4.2"
METRICS_SERVER_CHART_VERSION="3.12.2"

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
helm repo add ingress-nginx  https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo add jetstack       https://charts.jetstack.io                >/dev/null 2>&1 || true
helm repo add cnpg           https://cloudnative-pg.github.io/charts   >/dev/null 2>&1 || true
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
helm repo update

# ---------------------------------------------------------------------------
# Namespaces
# ---------------------------------------------------------------------------
# - ingress-nginx: ingress controller
# - cert-manager:  ACME / Certificate / Issuer controllers
# - cnpg-system:   CloudNativePG Postgres operator
# - keycloak:      Keycloak operator + Keycloak instance + its Postgres
# - graphwise:     PoolParty, GraphDB, ES, add-ons
# - graphrag:      GraphRAG chatbot/conversation/components/workflows + n8n Postgres
for ns in ingress-nginx cert-manager cnpg-system keycloak graphwise graphrag; do
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

echo "=== Cluster bootstrap complete at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo
echo "Verify:"
echo "  kubectl get pods -A"
echo "  kubectl get clusterissuer letsencrypt-prod"
echo
echo "Next: install the Graphwise stack umbrella Helm chart (Phase C+)."
