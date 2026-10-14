#!/usr/bin/env bash
# Lints the podinfo chart and checks what each environment renders.
set -euo pipefail
cd "$(dirname "$0")/.."

chart=charts/podinfo
helm lint "$chart" --quiet

# assert <env> <expected substring>...
assert() {
  local env=$1; shift
  local out
  out=$(helm template "podinfo-$env" "$chart" -f "envs/$env/podinfo.yaml")
  for want in "$@"; do
    grep -qF -- "$want" <<<"$out" || { echo "FAIL [$env]: missing '$want'"; exit 1; }
  done
  echo "ok [$env]"
}

assert dev  "replicas: 1" "host: podinfo.dev.localhost"  "ingressClassName: traefik" "value: \"dev\""  "alloy.observability.svc:4317" "prometheus.io/scrape"
assert prod "replicas: 2" "host: podinfo.prod.localhost" "ingressClassName: traefik" "value: \"prod\"" "alloy.observability.svc:4317" "prometheus.io/scrape" "limits:"

# The K8sGPT resource can't be validated offline (its CRD lives in the cluster), so check its key fields.
k8sgpt=platform/k8sgpt/k8sgpt.yaml
for want in "kind: K8sGPT" "version: v0.4.40" "enabled: false"; do
  grep -qF -- "$want" "$k8sgpt" || { echo "FAIL [k8sgpt]: missing '$want'"; exit 1; }
done
echo "ok [k8sgpt]"
