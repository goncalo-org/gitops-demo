#!/usr/bin/env bash
# End-to-end check of the running lab. Exits non-zero and names every failure.
set -euo pipefail

DEV=kind-dev
TIMEOUT=${TIMEOUT:-300}
failures=0

wait_for_apps() {
  local deadline=$((SECONDS + TIMEOUT)) bad
  echo "waiting up to ${TIMEOUT}s for Argo CD apps to be Synced/Healthy..."
  while :; do
    bad=$(kubectl --context "$DEV" -n argocd get applications.argoproj.io \
      -o jsonpath='{range .items[*]}{.metadata.name} {.status.sync.status} {.status.health.status}{"\n"}{end}' \
      | awk 'NF && ($2 != "Synced" || $3 != "Healthy")')
    [[ -z "$bad" ]] && { echo "ok   all apps Synced/Healthy"; return; }
    if (( SECONDS > deadline )); then
      echo "FAIL apps not Synced/Healthy:"; echo "$bad"
      failures=$((failures + 1)); return
    fi
    sleep 5
  done
}

# check <host> <port> <path>: expects HTTP 200, the same way a browser would ask.
check() {
  local host=$1 port=$2 path=$3 code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    --resolve "$host:$port:127.0.0.1" "http://$host:$port$path" || true)
  if [[ "$code" == "200" ]]; then
    echo "ok   http://$host:$port$path"
  else
    echo "FAIL http://$host:$port$path (got $code)"
    failures=$((failures + 1))
  fi
}

# check_internal <node>: Traefik API reachable from inside kind-dev, as the portal widgets need.
check_internal() {
  local node=$1 code
  code=$(kubectl --context "$DEV" run "probe-$node-$RANDOM" --rm -i --quiet --restart=Never \
    --image=curlimages/curl:8.11.1 -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$node:30900/api/overview" 2>/dev/null || true)
  if [[ "$code" == "200" ]]; then
    echo "ok   in-cluster http://$node:30900/api/overview"
  else
    echo "FAIL in-cluster http://$node:30900/api/overview (got ${code:-nothing})"
    failures=$((failures + 1))
  fi
}

wait_for_apps
check portal.dev.localhost   8080 /
check argocd.dev.localhost   8080 /
check traefik.dev.localhost  8080 /dashboard/
check traefik.prod.localhost 9080 /dashboard/
check podinfo.dev.localhost  8080 /
check podinfo.prod.localhost 9080 /
check_internal dev-control-plane
check_internal prod-control-plane

if (( failures > 0 )); then
  echo "$failures check(s) failed"; exit 1
fi
echo "all checks passed"
