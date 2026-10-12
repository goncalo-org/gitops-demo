#!/usr/bin/env bash
# Non-GitOps setup for the homelab. Idempotent: safe to re-run after a partial failure.
set -euo pipefail
cd "$(dirname "$0")/.."

DEV=kind-dev
PROD=kind-prod

check_prereqs() {
  for bin in docker kind kubectl helm curl; do
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

# Optional: trust an extra root CA in the kind nodes' containerd (e.g. a TLS-intercepting
# corporate proxy). Usage: EXTRA_CA_FILE=/path/to/ca.pem make up
trust_extra_ca() {
  [[ -n "${EXTRA_CA_FILE:-}" ]] || return 0
  [[ -r "$EXTRA_CA_FILE" ]] || { echo "EXTRA_CA_FILE not readable: $EXTRA_CA_FILE"; exit 1; }
  for node in dev-control-plane prod-control-plane; do
    if docker exec -i "$node" cmp -s /usr/local/share/ca-certificates/extra-ca.crt - <"$EXTRA_CA_FILE"; then
      echo "extra CA already trusted on $node, skipping"; continue
    fi
    docker exec -i "$node" sh -c 'cat > /usr/local/share/ca-certificates/extra-ca.crt && update-ca-certificates >/dev/null && systemctl restart containerd' <"$EXTRA_CA_FILE"
    echo "extra CA trusted on $node"
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
  annotations:
    branch: release   # dev deploys what is on the release branch
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
  annotations:
    branch: main      # prod deploys what is on main
stringData:
  name: prod
  server: https://prod-control-plane:6443
  config: '{"bearerToken":"$token","tlsClientConfig":{"caData":"$ca"}}'
EOF
}

# Creates a readonly Argo CD API token for the Homepage widget, stored only in-cluster.
create_portal_token() {
  kubectl --context "$DEV" create namespace homepage --dry-run=client -o yaml | kubectl --context "$DEV" apply -f -
  if kubectl --context "$DEV" -n homepage get secret homepage-argocd-token >/dev/null 2>&1; then
    echo "portal token exists, skipping"; return
  fi

  local pw token
  pw=$(kubectl --context "$DEV" -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
  kubectl --context "$DEV" -n argocd port-forward svc/argocd-server 18080:80 >/dev/null 2>&1 &
  pf=$!   # global so the EXIT trap can still see it
  trap 'kill ${pf:-} 2>/dev/null || true' RETURN EXIT
  until curl -s -o /dev/null http://127.0.0.1:18080/healthz; do sleep 1; done

  # REST instead of `argocd login`: the CLI's plaintext probe resets the kubectl port-forward.
  local jwt
  jwt=$(curl -fsS -H 'Content-Type: application/json' -d "{\"username\":\"admin\",\"password\":\"$pw\"}" \
    http://127.0.0.1:18080/api/v1/session | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
  token=$(curl -fsS -H "Authorization: Bearer $jwt" -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:18080/api/v1/account/portal/token \
    | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
  [ -n "$token" ] || { echo "failed to generate portal token"; return 1; }
  kubectl --context "$DEV" -n homepage create secret generic homepage-argocd-token --from-literal=token="$token"
}

print_summary() {
  cat <<'EOF'

Lab is up. Argo CD syncs everything else from GitHub; run `make test` to wait for it.
  Portal        http://portal.dev.localhost:8080
  Argo CD       http://argocd.dev.localhost:8080   (user: admin)
  Traefik dev   http://traefik.dev.localhost:8080/dashboard/
  Traefik prod  http://traefik.prod.localhost:9080/dashboard/
  podinfo dev   http://podinfo.dev.localhost:8080
  podinfo prod  http://podinfo.prod.localhost:9080

Argo CD admin password:
  kubectl --context kind-dev -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
EOF
}

main() {
  check_prereqs
  create_clusters
  trust_extra_ca
  install_argocd
  register_clusters
  create_portal_token
  kubectl --context "$DEV" apply -f bootstrap/root-app.yaml
  print_summary
}

main "$@"
