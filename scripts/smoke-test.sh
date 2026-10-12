#!/usr/bin/env bash
# End-to-end check of the running lab. Exits non-zero and names every failure.
set -euo pipefail

DEV=kind-dev
TIMEOUT=${TIMEOUT:-300}
failures=0

wait_for_apps() {
  local deadline=$((SECONDS + TIMEOUT)) apps bad
  echo "waiting up to ${TIMEOUT}s for Argo CD apps to be Synced/Healthy..."
  while :; do
    apps=$(kubectl --context "$DEV" -n argocd get applications.argoproj.io \
      -o jsonpath='{range .items[*]}{.metadata.name} {.status.sync.status} {.status.health.status}{"\n"}{end}')
    bad=$(awk 'NF && ($2 != "Synced" || $3 != "Healthy")' <<<"$apps")
    # More than just `root`: the ApplicationSets must have generated their apps.
    [[ -z "$bad" && $(grep -c . <<<"$apps") -gt 1 ]] && { echo "ok   all apps Synced/Healthy"; return; }
    if (( SECONDS > deadline )); then
      echo "FAIL apps not Synced/Healthy:"; echo "${bad:-only $(grep -c . <<<"$apps") app(s) found}"
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
# (Runs a pod and reads its logs: `kubectl run --rm -i` loses stdout in this environment.)
check_internal() {
  local node=$1 pod="probe-$1" code
  kubectl --context "$DEV" delete pod "$pod" --ignore-not-found >/dev/null
  kubectl --context "$DEV" run "$pod" --restart=Never --image=curlimages/curl:8.11.1 --command -- \
    sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://$node:30900/api/overview || true" >/dev/null
  kubectl --context "$DEV" wait pod "$pod" --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s >/dev/null 2>&1 || true
  code=$(kubectl --context "$DEV" logs "$pod" 2>/dev/null || true)
  kubectl --context "$DEV" delete pod "$pod" --wait=false >/dev/null
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
