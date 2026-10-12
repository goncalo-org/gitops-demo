# Observability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Metrics, logs and traces from both kind clusters, stored in dev and shown in one Grafana. The smoke test proves that data arrives from prod.

**Architecture:** Prometheus, Loki, Tempo and Grafana run only in dev, deployed by one ApplicationSet that follows `release`. Their write and query ports are exposed as NodePorts on `dev-control-plane`, by a small kustomize folder that also builds the dashboard ConfigMap. Each cluster runs Grafana Alloy (one agent for all three signals) and kube-state-metrics, deployed by cluster-generator ApplicationSets and gated by branch. podinfo and Traefik send OTLP traces to their cluster's Alloy.

**Tech Stack:** Charts `prometheus-community/prometheus` 29.36.1, `prometheus-community/kube-state-metrics` 8.6.0, `grafana/loki` 7.3.0, `grafana/tempo` 1.24.4, `grafana/grafana` 10.5.15, `grafana/alloy` 1.13.1 (Alloy v1.20.1), kustomize (built into Argo CD), bash.

**Spec:** `docs/superpowers/specs/2026-10-12-observability-design.md`

---

## Read this first

- **The lab is already running.** See `README.md` and the original plan, `docs/superpowers/plans/2026-10-12-gitops-homelab.md`. Contexts are `kind-dev` and `kind-prod`, and the node containers `dev-control-plane` and `prod-control-plane` sit on the Docker `kind` network. Argo CD runs in dev.
- **Branches:**
  - Commit on `develop` and push with `git push origin develop`.
  - Deploy through PRs merged with a **merge commit**: `develop → release` deploys to dev, and `release → main` deploys to prod.
  - Never push directly to `release` or `main`.
- **PR commands.** The `GH_TOKEN` prefix pins the right GitHub account; a second, broken `gh` account exists:
  ```bash
  export GH_TOKEN=$(gh auth token --user GONCALO-RAMOS-NTT)
  gh pr create --repo goncalo-org/gitops-demo --base release --head develop --title "<title>" --body "<title>"
  gh pr merge  --repo goncalo-org/gitops-demo develop --merge          # dev
  gh pr create --repo goncalo-org/gitops-demo --base main --head release --title "<title>" --body "<title>"
  gh pr merge  --repo goncalo-org/gitops-demo release --merge          # prod
  unset GH_TOKEN
  ```
- **Refresh all Argo CD apps after a merge.** Argo CD would otherwise poll within about 3 minutes:
  ```bash
  kubectl --context kind-dev -n argocd get applications -o name | xargs -I{} kubectl --context kind-dev -n argocd annotate {} argocd.argoproj.io/refresh=normal --overwrite
  ```
- **Bootstrap command:** always `EXTRA_CA_FILE=$HOME/.config/gitops-demo/extra-ca.pem make up`. This machine sits behind a Zscaler proxy.
- **Tests:** `make test` (`scripts/smoke-test.sh`) and `make lint`. Task 1 writes the new checks first, red. Each later task turns more of them green.
- **Commits:** commit with an explicit pathspec (`git commit -m "..." -- <paths>`) and end every commit message with a `Co-Authored-By:` trailer naming your model.
- **zsh:** quote kubectl `custom-columns` arguments.

## File map

| File | Responsibility |
|---|---|
| `scripts/smoke-test.sh` | Gains a shared `probe` helper, a Grafana health check, and data checks (metrics, logs, traces) |
| `argocd/observability-backends-appset.yaml` | List generator: Prometheus, Loki, Tempo, Grafana in dev (follows `release`) |
| `argocd/observability-platform-app.yaml` | Dev-only app for `platform/observability/` (NodePorts and dashboard) |
| `platform/observability/kustomization.yaml` | Bundles the NodePorts and the dashboard ConfigMap |
| `platform/observability/nodeports.yaml` | NodePort Services 30909, 30310, 30317 and 30320 on dev |
| `platform/observability/dashboards/homelab-overview.json` | The "Homelab overview" Grafana dashboard |
| `envs/dev/{prometheus,loki,tempo,grafana}.yaml` | Backend Helm values |
| `argocd/kube-state-metrics-appset.yaml` | kube-state-metrics in both clusters |
| `argocd/alloy-appset.yaml` | Alloy in both clusters (shared values plus per-env values) |
| `envs/common/alloy.yaml` | The Alloy pipeline, shared by both clusters |
| `envs/{dev,prod}/alloy.yaml` | Only `CLUSTER=<env>` |
| `scripts/bootstrap.sh` | `create_grafana_secret`; Grafana in `print_summary` |
| `envs/dev/homepage.yaml` | Grafana tile |
| `charts/podinfo/**`, `scripts/lint.sh` | OTel env vars and scrape annotations, plus their lint check |
| `envs/{dev,prod}/traefik.yaml` | OTLP tracing, router metrics, scrape annotations |
| `README.md` | 9 GB note, Grafana URL, layout |

---

### Task 1: Smoke test for observability (red)

**Files:**
- Modify: `scripts/smoke-test.sh` (full new content below)

- [ ] **Step 1: Give Colima 9 GB**

Confirm with the user before running this: it restarts Docker and briefly stops the lab.

```bash
colima stop && colima start --cpu 4 --memory 9
docker start dev-control-plane prod-control-plane
kubectl --context kind-dev get nodes && kubectl --context kind-prod get nodes
```
Expected: both nodes are `Ready` within about a minute. `colima list` shows `9GiB`.

- [ ] **Step 2: Replace `scripts/smoke-test.sh` with:**

```bash
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

# probe <name> <curl args...>: runs curl in a throwaway pod inside kind-dev and prints its output.
# (Runs a pod and reads its logs: `kubectl run --rm -i` loses stdout in this environment.)
probe() {
  local pod="probe-$1"; shift
  kubectl --context "$DEV" delete pod "$pod" --ignore-not-found >/dev/null
  kubectl --context "$DEV" run "$pod" --restart=Never --image=curlimages/curl:8.11.1 --command -- \
    sh -c 'curl -s --max-time 10 "$@" || true' curl "$@" >/dev/null
  kubectl --context "$DEV" wait pod "$pod" --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s >/dev/null 2>&1 || true
  kubectl --context "$DEV" logs "$pod" 2>/dev/null || true
  kubectl --context "$DEV" delete pod "$pod" --wait=false >/dev/null || true
}

# check_internal <node>: Traefik API reachable from inside kind-dev, as the portal widgets need.
check_internal() {
  local node=$1 code
  code=$(probe "$node" -o /dev/null -w '%{http_code}' "http://$node:30900/api/overview")
  if [[ "$code" == "200" ]]; then
    echo "ok   in-cluster http://$node:30900/api/overview"
  else
    echo "FAIL in-cluster http://$node:30900/api/overview (got ${code:-nothing})"
    failures=$((failures + 1))
  fi
}

# check_data <name> <url> <regex> [tries]: a backend in dev must return matching data (polled every 10s).
check_data() {
  local name=$1 url=$2 want=$3 tries=${4:-1} i body
  for ((i = 1; i <= tries; i++)); do
    body=$(probe "$name" "$url")
    if grep -qE "$want" <<<"$body"; then echo "ok   $name"; return; fi
    if (( i < tries )); then sleep 10; fi
  done
  echo "FAIL $name: no data from $url (last: ${body:0:120})"
  failures=$((failures + 1))
}

PROM=http://dev-control-plane:30909/api/v1/query
LOKI=http://dev-control-plane:30310/loki/api/v1/query_range
TEMPO=http://dev-control-plane:30320/api/search

wait_for_apps
check portal.dev.localhost   8080 /
check argocd.dev.localhost   8080 /
check grafana.dev.localhost  8080 /api/health
check traefik.dev.localhost  8080 /dashboard/
check traefik.prod.localhost 9080 /dashboard/
check podinfo.dev.localhost  8080 /
check podinfo.prod.localhost 9080 /
check_internal dev-control-plane
check_internal prod-control-plane

# Telemetry must reach dev's backends; the prod checks prove the cross-cluster hop.
for _ in 1 2 3; do
  curl -s -o /dev/null --max-time 5 --resolve podinfo.prod.localhost:9080:127.0.0.1 http://podinfo.prod.localhost:9080/ || true
done
check_data metrics-dev  "$PROM?query=up%7Bcluster%3D%22dev%22%7D"  '"value":\[' 6
check_data metrics-prod "$PROM?query=up%7Bcluster%3D%22prod%22%7D" '"value":\[' 6
check_data logs-prod    "$LOKI?query=%7Bcluster%3D%22prod%22%7D&limit=1&since=10m" '"values":\[\[' 6
check_data traces-prod  "$TEMPO?q=%7Bresource.service.name%3D%22traefik%22%7D%20%3E%3E%20%7Bresource.service.name%3D%22podinfo%22%20%26%26%20resource.k8s.cluster.name%3D%22prod%22%7D&limit=1" '"traceID"' 6

if (( failures > 0 )); then
  echo "$failures check(s) failed"; exit 1
fi
echo "all checks passed"
```

- [ ] **Step 3: Run it and confirm the new checks fail**

Run: `make test`
Expected: everything that passed before still passes, plus exactly these new failures, ending with `5 check(s) failed`:
```
FAIL http://grafana.dev.localhost:8080/api/health (got 404)
FAIL metrics-dev: no data from http://dev-control-plane:30909/...
FAIL metrics-prod: no data from ...
FAIL logs-prod: no data from ...
FAIL traces-prod: no data from ...
```
(The data checks each poll for about a minute before failing. The in-cluster Traefik checks still pass, which proves the refactored `probe` helper works.)

- [ ] **Step 4: Commit**

```bash
git commit -m "test: smoke checks for Grafana and telemetry from both clusters" -m "Co-Authored-By: <your model> <noreply@anthropic.com>" -- scripts/smoke-test.sh
git push origin develop
```

---

### Task 2: Backends (Prometheus, Loki, Tempo) and their NodePorts

**Files:**
- Create: `envs/dev/prometheus.yaml`, `envs/dev/loki.yaml`, `envs/dev/tempo.yaml`
- Create: `argocd/observability-backends-appset.yaml`
- Create: `platform/observability/kustomization.yaml`, `platform/observability/nodeports.yaml`
- Create: `argocd/observability-platform-app.yaml`

- [ ] **Step 1: Confirm nothing listens yet (red)**

Run:
```bash
kubectl --context kind-dev get ns observability
```
Expected: `NotFound`.

- [ ] **Step 2: Write the backend values**

`envs/dev/prometheus.yaml`:
```yaml
alertmanager:
  enabled: false
prometheus-pushgateway:
  enabled: false
prometheus-node-exporter:
  enabled: false
kube-state-metrics:
  enabled: false
configmapReload:
  prometheus:
    enabled: false
server:
  extraFlags:
    - web.enable-remote-write-receiver
  retention: 2d
  persistentVolume:
    size: 2Gi
scrapeConfigs: null
```

`envs/dev/loki.yaml`:
```yaml
deploymentMode: SingleBinary
loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
  schemaConfig:
    configs:
      - from: "2024-01-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: index_
          period: 24h
  limits_config:
    retention_period: 48h
  compactor:
    retention_enabled: true
    delete_request_store: filesystem
singleBinary:
  replicas: 1
  persistence:
    size: 2Gi
read:
  replicas: 0
write:
  replicas: 0
backend:
  replicas: 0
chunksCache:
  enabled: false
resultsCache:
  enabled: false
gateway:
  enabled: false
lokiCanary:
  enabled: false
test:
  enabled: false
```

`envs/dev/tempo.yaml`:
```yaml
tempo:
  retention: 48h
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
persistence:
  enabled: true
  size: 2Gi
```

- [ ] **Step 3: Write the backends ApplicationSet**

The file below has three elements. Task 3 adds Grafana as the fourth, together with its values file.

`argocd/observability-backends-appset.yaml`:
```yaml
# Observability backends: dev only, following the release branch (like Homepage).
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: observability-backends
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - list:
        elements:
          - name: prometheus
            repoURL: https://prometheus-community.github.io/helm-charts
            chart: prometheus
            version: 29.36.1
          - name: loki
            repoURL: https://grafana.github.io/helm-charts
            chart: loki
            version: 7.3.0
          - name: tempo
            repoURL: https://grafana.github.io/helm-charts
            chart: tempo
            version: 1.24.4
  template:
    metadata:
      name: '{{.name}}'
    spec:
      project: default
      sources:
        - repoURL: '{{.repoURL}}'
          chart: '{{.chart}}'
          targetRevision: '{{.version}}'
          helm:
            releaseName: '{{.name}}'
            valueFiles:
              - '$values/envs/dev/{{.name}}.yaml'
        - repoURL: https://github.com/goncalo-org/gitops-demo.git
          targetRevision: release
          ref: values
      destination:
        server: https://kubernetes.default.svc
        namespace: observability
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
```

- [ ] **Step 4: Write the NodePorts (kustomize folder) and its app**

`platform/observability/nodeports.yaml`:
```yaml
# Fixed NodePorts on dev-control-plane so both clusters' agents (and the smoke test) can reach the
# backends over the Docker "kind" network. Not mapped to the host. Unauthenticated: lab only.
apiVersion: v1
kind: Service
metadata:
  name: prometheus-nodeport
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: prometheus
    app.kubernetes.io/instance: prometheus
    app.kubernetes.io/component: server
  ports:
    - name: http
      port: 9090
      targetPort: 9090
      nodePort: 30909
---
apiVersion: v1
kind: Service
metadata:
  name: loki-nodeport
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: loki
    app.kubernetes.io/instance: loki
    app.kubernetes.io/component: single-binary
  ports:
    - name: http
      port: 3100
      targetPort: 3100
      nodePort: 30310
---
apiVersion: v1
kind: Service
metadata:
  name: tempo-nodeport
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: tempo
    app.kubernetes.io/instance: tempo
  ports:
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
      nodePort: 30317
    - name: http
      port: 3200
      targetPort: 3200
      nodePort: 30320
```

`platform/observability/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: observability
resources:
  - nodeports.yaml
```

`argocd/observability-platform-app.yaml`:
```yaml
# Dev-only manifests for observability: backend NodePorts and the Grafana dashboard.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: observability-platform
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/goncalo-org/gitops-demo.git
    targetRevision: release
    path: platform/observability
  destination:
    server: https://kubernetes.default.svc
    namespace: observability
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Check locally that kustomize builds: `kubectl kustomize platform/observability | grep -c 'kind: Service'` should print `3`.

- [ ] **Step 5: Commit, push and deploy to dev**

```bash
git add envs/dev/prometheus.yaml envs/dev/loki.yaml envs/dev/tempo.yaml argocd/observability-backends-appset.yaml argocd/observability-platform-app.yaml platform/observability
git commit -m "feat: Prometheus, Loki and Tempo backends in dev with NodePorts" -m "Co-Authored-By: <your model> <noreply@anthropic.com>" -- envs/dev/prometheus.yaml envs/dev/loki.yaml envs/dev/tempo.yaml argocd/observability-backends-appset.yaml argocd/observability-platform-app.yaml platform/observability
git push origin develop
```
Then open and merge a `develop → release` PR titled "release: observability backends", and refresh all apps (see "Read this first").

- [ ] **Step 6: Verify the backends**

```bash
kubectl --context kind-dev -n argocd get applications 'prometheus' 'loki' 'tempo' 'observability-platform' -o 'custom-columns=APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
kubectl --context kind-dev -n observability get pods,svc
```
Expected: all four apps are Synced/Healthy (Loki can take 1–2 minutes), and the Services `prometheus-nodeport`, `loki-nodeport` and `tempo-nodeport` show NodePorts 30909, 30310, 30317 and 30320.

Then check that each port answers from inside dev, using a throwaway curl pod:
```bash
for u in http://dev-control-plane:30909/-/ready http://dev-control-plane:30310/ready http://dev-control-plane:30320/ready; do
  kubectl --context kind-dev run probe-ready --restart=Never --image=curlimages/curl:8.11.1 --command -- sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 10 $u || true" >/dev/null
  kubectl --context kind-dev wait pod probe-ready --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s >/dev/null
  echo "$u $(kubectl --context kind-dev logs probe-ready)"; kubectl --context kind-dev delete pod probe-ready >/dev/null
done
```
Expected: `200` for all three. Loki may answer `503` for its first minute while it starts; re-run if so.

Run `make test`. Expected: the same 5 failures as Task 1, because no agents are sending yet. All other checks pass.

If an app is Degraded:
- Run `kubectl --context kind-dev -n observability describe pod <pod>` and read its logs.
- Report the exact error.
- Common causes: the chart rejects a value (schema), or a PVC is Pending. kind's `standard` StorageClass should bind automatically.

---

### Task 3: Grafana, the dashboard, and the portal tile

**Files:**
- Create: `envs/dev/grafana.yaml`
- Create: `platform/observability/dashboards/homelab-overview.json`
- Modify: `argocd/observability-backends-appset.yaml` (add the Grafana element)
- Modify: `platform/observability/kustomization.yaml` (add the dashboard ConfigMap)
- Modify: `scripts/bootstrap.sh` (add `create_grafana_secret`, update `print_summary` and `main`)
- Modify: `envs/dev/homepage.yaml` (Grafana tile)

- [ ] **Step 1: Confirm the Grafana check is red**

Run: `make test 2>&1 | grep grafana`
Expected: `FAIL http://grafana.dev.localhost:8080/api/health (got 404)`.

- [ ] **Step 2: Bootstrap creates Grafana's admin Secret**

In `scripts/bootstrap.sh`, add this function above `print_summary()`:
```bash
# Grafana admin credentials, created once (the chart's own random password would change on every Argo CD render).
create_grafana_secret() {
  kubectl --context "$DEV" create namespace observability --dry-run=client -o yaml | kubectl --context "$DEV" apply -f -
  if kubectl --context "$DEV" -n observability get secret grafana-admin >/dev/null 2>&1; then
    echo "grafana admin secret exists, skipping"; return
  fi
  kubectl --context "$DEV" -n observability create secret generic grafana-admin \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
}
```

Replace `print_summary()` with:
```bash
print_summary() {
  cat <<'EOF'

Lab is up. Argo CD syncs everything else from GitHub; run `make test` to wait for it.
  Portal        http://portal.dev.localhost:8080
  Argo CD       http://argocd.dev.localhost:8080   (user: admin)
  Grafana       http://grafana.dev.localhost:8080  (user: admin)
  Traefik dev   http://traefik.dev.localhost:8080/dashboard/
  Traefik prod  http://traefik.prod.localhost:9080/dashboard/
  podinfo dev   http://podinfo.dev.localhost:8080
  podinfo prod  http://podinfo.prod.localhost:9080

Argo CD admin password:
  kubectl --context kind-dev -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
Grafana admin password:
  kubectl --context kind-dev -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
EOF
}
```

Replace `main()` with:
```bash
main() {
  check_prereqs
  create_clusters
  trust_extra_ca
  install_argocd
  register_clusters
  create_portal_token
  create_grafana_secret
  kubectl --context "$DEV" apply -f bootstrap/root-app.yaml
  print_summary
}
```

Run: `bash -n scripts/bootstrap.sh && EXTRA_CA_FILE=$HOME/.config/gitops-demo/extra-ca.pem make up`
Expected: `make up` prints `secret/grafana-admin created`, and its summary lists Grafana. A second run prints `grafana admin secret exists, skipping`.

- [ ] **Step 3: Grafana values and dashboard**

`envs/dev/grafana.yaml`:
```yaml
ingress:
  enabled: true
  ingressClassName: traefik
  hosts:
    - grafana.dev.localhost
persistence:
  enabled: false   # dashboards and data sources are provisioned; nothing to keep
admin:
  existingSecret: grafana-admin   # created by scripts/bootstrap.sh
  userKey: admin-user
  passwordKey: admin-password
testFramework:
  enabled: false
sidecar:
  dashboards:
    enabled: true
    label: grafana_dashboard
    labelValue: "1"
    searchNamespace: observability
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        uid: prometheus
        url: http://prometheus-server.observability.svc
        isDefault: true
      - name: Loki
        type: loki
        uid: loki
        url: http://loki.observability.svc:3100
      - name: Tempo
        type: tempo
        uid: tempo
        url: http://tempo.observability.svc:3200
        jsonData:
          tracesToLogsV2:
            datasourceUid: loki
            spanStartTimeShift: "-1m"
            spanEndTimeShift: "1m"
            tags:
              - key: k8s.cluster.name
                value: cluster
```

`platform/observability/dashboards/homelab-overview.json`:
```json
{
  "title": "Homelab overview",
  "uid": "homelab-overview",
  "schemaVersion": 39,
  "version": 1,
  "time": {
    "from": "now-1h",
    "to": "now"
  },
  "refresh": "30s",
  "tags": [
    "homelab"
  ],
  "templating": {
    "list": [
      {
        "name": "cluster",
        "label": "Cluster",
        "type": "query",
        "datasource": {
          "type": "prometheus",
          "uid": "prometheus"
        },
        "query": {
          "query": "label_values(up, cluster)",
          "refId": "cluster"
        },
        "definition": "label_values(up, cluster)",
        "refresh": 1,
        "current": {}
      }
    ]
  },
  "panels": [
    {
      "id": 1,
      "type": "timeseries",
      "title": "CPU by namespace",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 0,
        "y": 0
      },
      "fieldConfig": {
        "defaults": {
          "unit": "cores"
        },
        "overrides": []
      },
      "targets": [
        {
          "refId": "A",
          "expr": "sum by (namespace) (rate(container_cpu_usage_seconds_total{cluster=\"$cluster\", container!=\"\"}[5m]))",
          "legendFormat": "{{namespace}}"
        }
      ]
    },
    {
      "id": 2,
      "type": "timeseries",
      "title": "Memory by namespace",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 12,
        "y": 0
      },
      "fieldConfig": {
        "defaults": {
          "unit": "bytes"
        },
        "overrides": []
      },
      "targets": [
        {
          "refId": "A",
          "expr": "sum by (namespace) (container_memory_working_set_bytes{cluster=\"$cluster\", container!=\"\"})",
          "legendFormat": "{{namespace}}"
        }
      ]
    },
    {
      "id": 3,
      "type": "timeseries",
      "title": "Pod restarts (1h)",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 0,
        "y": 8
      },
      "fieldConfig": {
        "defaults": {
          "unit": "short"
        },
        "overrides": []
      },
      "targets": [
        {
          "refId": "A",
          "expr": "sum by (namespace, pod) (increase(kube_pod_container_status_restarts_total{cluster=\"$cluster\"}[1h])) > 0",
          "legendFormat": "{{namespace}}/{{pod}}"
        }
      ]
    },
    {
      "id": 4,
      "type": "timeseries",
      "title": "Traefik requests/s by router",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 12,
        "y": 8
      },
      "fieldConfig": {
        "defaults": {
          "unit": "reqps"
        },
        "overrides": []
      },
      "targets": [
        {
          "refId": "A",
          "expr": "sum by (router) (rate(traefik_router_requests_total{cluster=\"$cluster\"}[5m]))",
          "legendFormat": "{{router}}"
        }
      ]
    },
    {
      "id": 5,
      "type": "timeseries",
      "title": "Traefik 5xx/s by router",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 0,
        "y": 16
      },
      "fieldConfig": {
        "defaults": {
          "unit": "reqps"
        },
        "overrides": []
      },
      "targets": [
        {
          "refId": "A",
          "expr": "sum by (router) (rate(traefik_router_requests_total{cluster=\"$cluster\", code=~\"5..\"}[5m]))",
          "legendFormat": "{{router}}"
        }
      ]
    },
    {
      "id": 6,
      "type": "timeseries",
      "title": "podinfo latency p50 / p95",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 12,
        "y": 16
      },
      "fieldConfig": {
        "defaults": {
          "unit": "s"
        },
        "overrides": []
      },
      "targets": [
        {
          "refId": "A",
          "expr": "histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{cluster=\"$cluster\", app=\"podinfo\"}[5m])))",
          "legendFormat": "p95"
        },
        {
          "refId": "B",
          "expr": "histogram_quantile(0.5, sum by (le) (rate(http_request_duration_seconds_bucket{cluster=\"$cluster\", app=\"podinfo\"}[5m])))",
          "legendFormat": "p50"
        }
      ]
    }
  ]
}
```

Replace `platform/observability/kustomization.yaml` with:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: observability
resources:
  - nodeports.yaml
# Grafana's dashboard sidecar loads every ConfigMap labelled grafana_dashboard=1.
configMapGenerator:
  - name: dashboard-homelab-overview
    files:
      - dashboards/homelab-overview.json
    options:
      disableNameSuffixHash: true
      labels:
        grafana_dashboard: "1"
```

Replace `argocd/observability-backends-appset.yaml` with (the Grafana element is added):
```yaml
# Observability backends: dev only, following the release branch (like Homepage).
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: observability-backends
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - list:
        elements:
          - name: prometheus
            repoURL: https://prometheus-community.github.io/helm-charts
            chart: prometheus
            version: 29.36.1
          - name: loki
            repoURL: https://grafana.github.io/helm-charts
            chart: loki
            version: 7.3.0
          - name: tempo
            repoURL: https://grafana.github.io/helm-charts
            chart: tempo
            version: 1.24.4
          - name: grafana
            repoURL: https://grafana.github.io/helm-charts
            chart: grafana
            version: 10.5.15
  template:
    metadata:
      name: '{{.name}}'
    spec:
      project: default
      sources:
        - repoURL: '{{.repoURL}}'
          chart: '{{.chart}}'
          targetRevision: '{{.version}}'
          helm:
            releaseName: '{{.name}}'
            valueFiles:
              - '$values/envs/dev/{{.name}}.yaml'
        - repoURL: https://github.com/goncalo-org/gitops-demo.git
          targetRevision: release
          ref: values
      destination:
        server: https://kubernetes.default.svc
        namespace: observability
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
```

- [ ] **Step 4: Portal tile**

In `envs/dev/homepage.yaml`, add this group to the end of the `config.services` list, after the `Apps` group and at the same indentation:
```yaml
    - Observability:
        - Grafana:
            href: http://grafana.dev.localhost:8080
            description: Metrics, logs and traces for dev and prod
```

- [ ] **Step 5: Commit, push, deploy to dev**

```bash
git add envs/dev/grafana.yaml platform/observability argocd/observability-backends-appset.yaml scripts/bootstrap.sh envs/dev/homepage.yaml
git commit -m "feat: Grafana with data sources, overview dashboard and portal tile" -m "Co-Authored-By: <your model> <noreply@anthropic.com>" -- envs/dev/grafana.yaml platform/observability argocd/observability-backends-appset.yaml scripts/bootstrap.sh envs/dev/homepage.yaml
git push origin develop
```
Merge a `develop → release` PR titled "release: Grafana", then refresh all apps.

- [ ] **Step 6: Verify**

Run: `make test`
Expected: the Grafana check passes, and only the 4 data checks fail.

Run:
```bash
P=$(kubectl --context kind-dev -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)
curl -s -u "admin:$P" --resolve grafana.dev.localhost:8080:127.0.0.1 http://grafana.dev.localhost:8080/api/datasources | grep -o '"name":"[A-Za-z]*"'
curl -s -u "admin:$P" --resolve grafana.dev.localhost:8080:127.0.0.1 "http://grafana.dev.localhost:8080/api/search?query=Homelab" | grep -o '"title":"[^"]*"'
unset P
```
Expected: `"name":"Loki"`, `"name":"Prometheus"` and `"name":"Tempo"`, then `"title":"Homelab overview"`. Never print the password.

---

### Task 4: Agents in both clusters (kube-state-metrics and Alloy)

**Files:**
- Create: `argocd/kube-state-metrics-appset.yaml`
- Create: `argocd/alloy-appset.yaml`
- Create: `envs/common/alloy.yaml`, `envs/dev/alloy.yaml`, `envs/prod/alloy.yaml`

- [ ] **Step 1: Confirm the data checks are red**

Run: `make test 2>&1 | grep -E 'metrics-|logs-|traces-'`
Expected: four `FAIL` lines.

- [ ] **Step 2: kube-state-metrics ApplicationSet**

`argocd/kube-state-metrics-appset.yaml`:
```yaml
# kube-state-metrics in every registered cluster (scraped by that cluster's Alloy via annotations).
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: kube-state-metrics
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - clusters:
        selector:
          matchExpressions:
            - key: env
              operator: Exists
  template:
    metadata:
      name: 'kube-state-metrics-{{.name}}'
    spec:
      project: default
      source:
        repoURL: https://prometheus-community.github.io/helm-charts
        chart: kube-state-metrics
        targetRevision: 8.6.0
        helm:
          releaseName: kube-state-metrics
          valuesObject:
            podAnnotations:
              prometheus.io/scrape: "true"
              prometheus.io/port: "8080"
      destination:
        server: '{{.server}}'
        namespace: observability
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

- [ ] **Step 3: Alloy values (the pipeline is shared; only the cluster name differs)**

`envs/common/alloy.yaml` (the Alloy config was checked with `alloy fmt`, and its traces pipeline was test-run with Alloy v1.20.1):
```yaml
# Shared by every cluster; envs/<env>/alloy.yaml only sets CLUSTER.
alloy:
  configMap:
    content: |
      // One agent per cluster: metrics, logs and traces, all labelled with the cluster name
      // (CLUSTER env var, set per environment) and shipped to the backends in dev.

      discovery.kubernetes "pods" {
        role = "pod"
      }

      discovery.kubernetes "nodes" {
        role = "node"
      }

      // ---------- Metrics ----------

      // Pods that opt in with prometheus.io/scrape + prometheus.io/port annotations.
      discovery.relabel "annotated_pods" {
        targets = discovery.kubernetes.pods.targets

        rule {
          source_labels = ["__meta_kubernetes_pod_annotation_prometheus_io_scrape"]
          regex         = "true"
          action        = "keep"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_phase"]
          regex         = "Running"
          action        = "keep"
        }
        rule {
          source_labels = ["__address__", "__meta_kubernetes_pod_annotation_prometheus_io_port"]
          regex         = "([^:]+)(?::\\d+)?;(\\d+)"
          replacement   = "$1:$2"
          target_label  = "__address__"
        }
        rule {
          source_labels = ["__meta_kubernetes_namespace"]
          target_label  = "namespace"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_name"]
          target_label  = "pod"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
          target_label  = "app"
        }
      }

      prometheus.scrape "pods" {
        targets      = discovery.relabel.annotated_pods.output
        honor_labels = true // keep kube-state-metrics' own namespace/pod labels (not exported_*)
        forward_to   = [prometheus.remote_write.dev.receiver]
      }

      // Container CPU/memory from each kubelet's cAdvisor endpoint.
      prometheus.scrape "cadvisor" {
        targets           = discovery.kubernetes.nodes.targets
        scheme            = "https"
        metrics_path      = "/metrics/cadvisor"
        bearer_token_file = "/var/run/secrets/kubernetes.io/serviceaccount/token"
        tls_config {
          insecure_skip_verify = true // kind's kubelet serves a self-signed certificate
        }
        forward_to = [prometheus.remote_write.dev.receiver]
      }

      prometheus.remote_write "dev" {
        endpoint {
          url = "http://dev-control-plane:30909/api/v1/write"
        }
        external_labels = {
          cluster = sys.env("CLUSTER"),
        }
      }

      // ---------- Logs ----------

      discovery.relabel "pod_logs" {
        targets = discovery.kubernetes.pods.targets

        rule {
          source_labels = ["__meta_kubernetes_namespace"]
          target_label  = "namespace"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_name"]
          target_label  = "pod"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_container_name"]
          target_label  = "container"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
          target_label  = "app"
        }
      }

      loki.source.kubernetes "pods" {
        targets    = discovery.relabel.pod_logs.output
        forward_to = [loki.write.dev.receiver]
      }

      loki.write "dev" {
        endpoint {
          url = "http://dev-control-plane:30310/loki/api/v1/push"
        }
        external_labels = {
          cluster = sys.env("CLUSTER"),
        }
      }

      // ---------- Traces ----------

      otelcol.receiver.otlp "default" {
        grpc {
          endpoint = "0.0.0.0:4317"
        }
        http {
          endpoint = "0.0.0.0:4318"
        }
        output {
          traces = [otelcol.processor.transform.cluster.input]
        }
      }

      otelcol.processor.transform "cluster" {
        error_mode = "ignore"
        trace_statements {
          context    = "resource"
          statements = [string.format("set(resource.attributes[\"k8s.cluster.name\"], %q)", sys.env("CLUSTER"))]
        }
        output {
          traces = [otelcol.processor.batch.default.input]
        }
      }

      otelcol.processor.batch "default" {
        output {
          traces = [otelcol.exporter.otlp.tempo.input]
        }
      }

      otelcol.exporter.otlp "tempo" {
        client {
          endpoint = "dev-control-plane:30317"
          tls {
            insecure = true
          }
        }
      }
  extraPorts:
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
      protocol: TCP
    - name: otlp-http
      port: 4318
      targetPort: 4318
      protocol: TCP
```

`envs/dev/alloy.yaml`:
```yaml
alloy:
  extraEnv:
    - name: CLUSTER
      value: dev
```

`envs/prod/alloy.yaml`:
```yaml
alloy:
  extraEnv:
    - name: CLUSTER
      value: prod
```

- [ ] **Step 4: Alloy ApplicationSet**

`argocd/alloy-appset.yaml`:
```yaml
# Grafana Alloy in every registered cluster: shared pipeline + per-env CLUSTER name, gated by branch.
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: alloy
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - clusters:
        selector:
          matchExpressions:
            - key: env
              operator: Exists
  template:
    metadata:
      name: 'alloy-{{.name}}'
    spec:
      project: default
      sources:
        - repoURL: https://grafana.github.io/helm-charts
          chart: alloy
          targetRevision: 1.13.1
          helm:
            releaseName: alloy
            valueFiles:
              - '$values/envs/common/alloy.yaml'
              - '$values/envs/{{.metadata.labels.env}}/alloy.yaml'
        - repoURL: https://github.com/goncalo-org/gitops-demo.git
          targetRevision: '{{.metadata.annotations.branch}}'
          ref: values
      destination:
        server: '{{.server}}'
        namespace: observability
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

Check that the chart renders with both value files:
```bash
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1; helm repo update grafana >/dev/null
helm template alloy grafana/alloy --version 1.13.1 -n observability -f envs/common/alloy.yaml -f envs/prod/alloy.yaml | grep -E 'name: CLUSTER|value: prod|port: 4317'
```
Expected: lines for `name: CLUSTER`, `value: prod` and `port: 4317`.

- [ ] **Step 5: Commit, push, deploy to dev, then prod**

```bash
git add argocd/kube-state-metrics-appset.yaml argocd/alloy-appset.yaml envs/common/alloy.yaml envs/dev/alloy.yaml envs/prod/alloy.yaml
git commit -m "feat: Alloy and kube-state-metrics agents in dev and prod" -m "Co-Authored-By: <your model> <noreply@anthropic.com>" -- argocd/kube-state-metrics-appset.yaml argocd/alloy-appset.yaml envs/common/alloy.yaml envs/dev/alloy.yaml envs/prod/alloy.yaml
git push origin develop
```
Merge a `develop → release` PR titled "release: telemetry agents" and refresh all apps. Then merge a `release → main` PR titled "promote: telemetry agents" and refresh all apps again.

- [ ] **Step 6: Verify**

```bash
kubectl --context kind-dev -n argocd get applications -o 'custom-columns=APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' | grep -E 'alloy|kube-state'
kubectl --context kind-prod -n observability logs ds/alloy --tail=30 | grep -iE 'level=(error|warn)' | head
```
Expected: `alloy-dev`, `alloy-prod`, `kube-state-metrics-dev` and `kube-state-metrics-prod` are Synced/Healthy, with no repeating errors in prod's Alloy log.

Run: `make test`
Expected: `metrics-dev`, `metrics-prod` and `logs-prod` pass. Only `traces-prod` fails (`1 check(s) failed`), because nothing emits traces yet.

If `metrics-prod` or `logs-prod` fails while dev passes, the prod → dev hop is broken. Check prod Alloy's logs for `dev-control-plane` connection errors. Then confirm the hop from a prod pod, for example: `kubectl --context kind-prod run t --rm --restart=Never --image=curlimages/curl:8.11.1 -- curl -s -o /dev/null -w '%{http_code}' http://dev-control-plane:30909/-/ready`. If `run --rm` prints nothing, use the logs-based pattern from Task 2.

---

### Task 5: Traces from Traefik and podinfo (APM)

**Files:**
- Modify: `scripts/lint.sh` (assert the OTel env vars)
- Modify: `charts/podinfo/values.yaml`, `charts/podinfo/templates/deployment.yaml`
- Modify: `envs/dev/traefik.yaml`, `envs/prod/traefik.yaml`
- Modify: `envs/common/alloy.yaml` (log filter from the Task 4 review)

- [ ] **Step 1: Lint expects instrumentation (red)**

In `scripts/lint.sh`, replace the two `assert` lines at the bottom with:
```bash
assert dev  "replicas: 1" "host: podinfo.dev.localhost"  "ingressClassName: traefik" "value: \"dev\""  "alloy.observability.svc:4317" "prometheus.io/scrape"
assert prod "replicas: 2" "host: podinfo.prod.localhost" "ingressClassName: traefik" "value: \"prod\"" "alloy.observability.svc:4317" "prometheus.io/scrape" "limits:"
```
Run: `make lint`
Expected: `FAIL [dev]: missing 'alloy.observability.svc:4317'`.

- [ ] **Step 2: Instrument the podinfo chart**

Append to `charts/podinfo/values.yaml`:
```yaml

# Traces go to the cluster's Alloy agent (same address in every cluster).
otel:
  serviceName: podinfo
  # http:// = plaintext gRPC (Alloy's OTLP receiver has no TLS); clear it to disable trace export.
  endpoint: http://alloy.observability.svc:4317
```

In `charts/podinfo/templates/deployment.yaml`, give the pod template scrape annotations. Replace:
```yaml
  template:
    metadata:
      labels:
```
with:
```yaml
  template:
    metadata:
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9898"
      labels:
```
In the same file, replace the `env:` block:
```yaml
          env:
            - name: PODINFO_UI_MESSAGE
              value: {{ .Values.message | quote }}
```
with:
```yaml
          env:
            - name: PODINFO_UI_MESSAGE
              value: {{ .Values.message | quote }}
            - name: PODINFO_OTEL_SERVICE_NAME
              value: {{ .Values.otel.serviceName | quote }}
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: {{ .Values.otel.endpoint | quote }}
```

Run: `make lint`
Expected: `ok [dev]` and `ok [prod]`.

- [ ] **Step 3: Traefik tracing and router metrics**

Append to **both** `envs/dev/traefik.yaml` and `envs/prod/traefik.yaml`:
```yaml
# Observability: OTLP traces to this cluster's Alloy; per-router metrics, scraped via annotations.
tracing:
  otlp:
    enabled: true
    grpc:
      enabled: true
      endpoint: alloy.observability.svc:4317
      insecure: true
metrics:
  prometheus:
    addRoutersLabels: true
deployment:
  podAnnotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "9100"
```

Check that the Traefik chart accepts them:
```bash
helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1; helm repo update traefik >/dev/null
helm template traefik traefik/traefik --version 41.7.1 -n traefik -f envs/prod/traefik.yaml | grep -E 'tracing.otlp|addRoutersLabels|prometheus.io/port'
```
Expected: `--tracing.otlp.grpc.endpoint=alloy.observability.svc:4317` (and related flags), `--metrics.prometheus.addRoutersLabels=true`, and `prometheus.io/port: "9100"`.

- [ ] **Step 3b: Stop shipping the observability stack's own logs (Task 4 review)**

In `envs/common/alloy.yaml`, inside `discovery.relabel "pod_logs"`, add this rule as the FIRST rule (before the namespace rule). It avoids the self-logging loop and protects Loki's 2 GiB:
```
        rule {
          source_labels = ["__meta_kubernetes_namespace"]
          regex         = "observability|kube-system"
          action        = "drop"
        }
```
Also replace the file's first comment line in `content:` (`      // One agent per cluster: ...`) with these two lines:
```
      // One agent per cluster: metrics, logs and traces, all labelled with the cluster name
      // (CLUSTER env var, set per environment) and shipped to the backends in dev. Assumes one node per cluster: on more nodes, scope discovery to the agent's node or enable clustering.
```
(Keep the existing second comment line `// (CLUSTER env var, ...)` removed, since the replacement includes it.)

Re-check that the config formats: render with `helm template alloy grafana/alloy --version 1.13.1 -n observability -f envs/common/alloy.yaml -f envs/prod/alloy.yaml`, extract `config.alloy`, and pipe it into `docker run --rm -i --entrypoint sh grafana/alloy:v1.20.1 -c 'cat > /tmp/c.alloy && /bin/alloy fmt /tmp/c.alloy >/dev/null && echo FMT-OK'`.

- [ ] **Step 4: Commit, push, deploy to dev, then prod**

```bash
git commit -m "feat: OTLP traces and scrape annotations for podinfo and Traefik" -m "Co-Authored-By: <your model> <noreply@anthropic.com>" -- scripts/lint.sh charts/podinfo/values.yaml charts/podinfo/templates/deployment.yaml envs/dev/traefik.yaml envs/prod/traefik.yaml envs/common/alloy.yaml
git push origin develop
```
Merge a `develop → release` PR titled "release: tracing" and refresh all apps. Then merge a `release → main` PR titled "promote: tracing" and refresh all apps again.

- [ ] **Step 5: Verify**

Run: `make test`
Expected: `all checks passed`, including `ok   traces-prod`.

If `traces-prod` still fails:
- Check that podinfo prod got the env vars: `kubectl --context kind-prod -n podinfo get deploy podinfo -o yaml | grep -A1 OTEL`.
- Read prod Alloy's logs for otlp errors.
- Query Tempo for any podinfo trace (drop the cluster filter) to tell "no traces at all" apart from "missing cluster attribute".

---

### Task 6: README, clean rebuild, final check

**Files:**
- Modify: `README.md`

- [ ] **Step 1: README edits**

1. In "## Prerequisites", replace the sentence `Docker needs at least 4 CPUs and 6 GB of memory for both clusters (Colima: \`colima start --cpu 4 --memory 6\`).` with:
   `Docker needs at least 4 CPUs and 9 GB of memory for both clusters and the observability stack (Colima: \`colima start --cpu 4 --memory 9\`).`
2. In the URL table, add this row after the Argo CD row:
   `| http://grafana.dev.localhost:8080 | Grafana: metrics, logs and traces for both clusters (user \`admin\`; \`make up\` prints the command to read the password) |`
3. In "## Layout", replace the `envs/<env>/` bullet with these two bullets:
   - `envs/<env>/`: Helm values per environment; `envs/common/` holds values shared by every cluster (the Alloy pipeline)
   - `platform/observability/`: dev-only manifests (backend NodePorts and the Grafana dashboard)

Then commit and push:
```bash
git commit -m "docs: README for observability" -m "Co-Authored-By: <your model> <noreply@anthropic.com>" -- README.md
git push origin develop
```

- [ ] **Step 2: Clean rebuild**

Run: `make down && EXTRA_CA_FILE=$HOME/.config/gitops-demo/extra-ca.pem make up && make test`
Expected: `all checks passed`. Re-run `make test` once if the first run times out while images pull. This proves that bootstrap plus Git recreate everything, including the Grafana secret ordering.

- [ ] **Step 3: Promote the README**

Merge a `develop → release` PR titled "release: observability docs", then a `release → main` PR titled "promote: observability docs". Run `make test` and expect `all checks passed`.
