#!/usr/bin/env bash
# Non-GitOps setup for the homelab. Idempotent: safe to re-run after a partial failure.
set -euo pipefail
cd "$(dirname "$0")/.."

DEV=kind-dev
PROD=kind-prod

check_prereqs() {
  for bin in docker kind kubectl helm; do
    command -v "$bin" >/dev/null || { echo "missing prerequisite: $bin"; exit 1; }
  done
  docker info >/dev/null 2>&1 || { echo "docker is not running"; exit 1; }
}

create_clusters() {
  for env in dev prod; do
    if kind get clusters 2>/dev/null | grep -qx "$env"; then
      echo "cluster $env exists, skipping"
    else
      kind create cluster --config "clusters/kind-$env.yaml"
    fi
  done
}

install_argocd() {
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
  helm repo update argo >/dev/null
  helm upgrade --install argocd argo/argo-cd \
    --kube-context "$DEV" \
    --namespace argocd --create-namespace \
    --version 10.10.3 \
    -f bootstrap/argocd-values.yaml \
    --wait --timeout 10m
}

# Registers both clusters as Argo CD cluster Secrets, labelled env=<name>.
# The ApplicationSets select clusters by that label.
register_clusters() {
  kubectl --context "$DEV" apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: cluster-dev
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    env: dev
stringData:
  name: dev
  server: https://kubernetes.default.svc
  config: '{"tlsClientConfig":{"insecure":false}}'
EOF

  # Identity Argo CD uses to manage prod.
  kubectl --context "$PROD" apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-manager
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: argocd-manager
    namespace: kube-system
---
apiVersion: v1
kind: Secret
type: kubernetes.io/service-account-token
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: argocd-manager
EOF

  local token="" ca
  until [[ -n "$token" ]]; do
    token=$(kubectl --context "$PROD" -n kube-system get secret argocd-manager-token -o jsonpath='{.data.token}' | base64 -d)
    [[ -n "$token" ]] || sleep 1
  done
  ca=$(kubectl --context "$PROD" -n kube-system get secret argocd-manager-token -o jsonpath='{.data.ca\.crt}')

  # prod-control-plane resolves on the Docker "kind" network, which kind-dev pods can reach.
  kubectl --context "$DEV" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cluster-prod
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    env: prod
stringData:
  name: prod
  server: https://prod-control-plane:6443
  config: '{"bearerToken":"$token","tlsClientConfig":{"caData":"$ca"}}'
EOF
}

main() {
  check_prereqs
  create_clusters
  install_argocd
  register_clusters
}

main "$@"
