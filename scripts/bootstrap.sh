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

main() {
  check_prereqs
  create_clusters
}

main "$@"
