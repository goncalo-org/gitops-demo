# Observability (metrics, logs, traces) — Design

**Date:** 2026-10-12
**Builds on:** `2026-10-12-gitops-homelab-design.md` (two kind clusters, Argo CD in dev, Traefik, podinfo, Homepage, develop → release → main)

## Goal

Cluster observability and APM for both environments, viewed in one Grafana. It covers metrics (cluster and app health), logs from every pod, and distributed traces (Traefik → podinfo), all labelled `cluster=dev|prod`.

## Decisions

| Topic | Choice | Why |
|---|---|---|
| Signals | Metrics, logs, traces | Cluster health and APM, plus searchable logs |
| Topology | Backends and Grafana only in `dev`; agents in both clusters | Same hub pattern as Argo CD; one Grafana; lowest RAM |
| Stack | Prometheus, Loki, Tempo, Grafana; Grafana Alloy as the single agent; kube-state-metrics | Lightest complete open-source stack; one agent for all three signals |
| Instrumentation | podinfo's built-in OpenTelemetry, plus Traefik's OTLP tracing | APM with no code changes; traces span ingress → app |
| Storage | kind's local-path volumes, 2-day retention, lost on `make down` | Lab scope |
| Resources | Colima raised to 9 GB (`colima start --memory 9`) | The stack adds about 1.5–2 GB to the ~3 GB already in use |

## Architecture

```
kind-prod                                   kind-dev
┌───────────────────────────┐               ┌──────────────────────────────────────────┐
│ podinfo ──OTLP──┐         │               │ podinfo ──OTLP──┐                         │
│ traefik ──OTLP──┤         │               │ traefik ──OTLP──┤                         │
│                 ▼         │  Docker net   │                 ▼                         │
│ Alloy (agent) ────────────┼──────────────►│ Alloy (agent) ──► Prometheus  (metrics)   │
│                           │ dev-control-  │                 ► Loki        (logs)      │
│                           │ plane:NodePort│                 ► Tempo       (traces)    │
│ kube-state-metrics        │               │ Grafana ◄── all three                    │
│                           │               │ kube-state-metrics                        │
└───────────────────────────┘               └──────────────────────────────────────────┘
```

Write endpoints, exposed as NodePorts on `dev-control-plane`. They are **not** mapped to the host, like Traefik's `30900`:

| Backend | NodePort | Used for |
|---|---|---|
| Prometheus | `30909` | Remote-write ingestion (`/api/v1/write`) and queries |
| Loki | `30310` | Log push and queries |
| Tempo | `30317` | OTLP gRPC trace ingestion |
| Tempo | `30320` | Query API (search), used by the smoke test |

Both agents (dev included) send to `http://dev-control-plane:<port>`, so dev and prod use one code path.

The upstream charts for Loki and Tempo can't pin NodePorts, so all four are defined as plain Services in `platform/observability/nodeports.yaml`. That folder is a kustomize directory, and it also builds the dashboard ConfigMap. It is deployed by one dev-only Argo CD app.

## Components

### Agents (both clusters, ApplicationSets with the cluster generator, gated by branch)
- **Grafana Alloy** (`argocd/alloy-appset.yaml`). The pipeline is shared in `envs/common/alloy.yaml`. `envs/<env>/alloy.yaml` sets only the `CLUSTER` env var:
  - **Metrics:** scrapes kubelet/cAdvisor, kube-state-metrics, and pods annotated `prometheus.io/scrape: "true"` (Traefik and podinfo). It remote-writes to Prometheus and buffers in its write-ahead log while the backend is unreachable.
  - **Logs:** tails all pod logs through the Kubernetes API (`loki.source.kubernetes`, no hostPath) and pushes them to Loki.
  - **Traces:** an OTLP receiver (gRPC 4317, HTTP 4318) on Service `alloy.observability`, exporting to Tempo.
  - **Labels:** adds `cluster=<env>` to every metric and log stream, and the resource attribute `k8s.cluster.name=<env>` to every span.
- **kube-state-metrics** (`argocd/kube-state-metrics-appset.yaml`): upstream chart, with only scrape annotations set inline.
- Namespace: `observability` in both clusters.

### Backends (dev only; one ApplicationSet with a list generator, `argocd/observability-backends-appset.yaml`, following `release` like Homepage)
- **Prometheus** (values `envs/dev/prometheus.yaml`): server only, with the remote-write receiver enabled, its own scraping turned off (Alloy scrapes), and 2-day retention. Alertmanager, Pushgateway and the bundled exporters are disabled.
- **Loki** (values `envs/dev/loki.yaml`): single-binary mode on the filesystem, auth disabled, 48h retention.
- **Tempo** (values `envs/dev/tempo.yaml`): single binary on local storage, with the OTLP receiver and 48h retention. The `grafana/tempo` chart is marked deprecated upstream (in favour of `tempo-distributed`), but it still ships Tempo 2.9 and suits a single-node lab.
- **Grafana** (values `envs/dev/grafana.yaml`):
  - Ingress at `grafana.dev.localhost`.
  - Admin credentials come from Secret `grafana-admin`, which bootstrap creates once with a random password. The chart's own random password would change on every Argo CD render. Anonymous access is off.
  - Provisioned data sources:
    - Prometheus, Loki and Tempo, via their in-cluster Services.
    - Tempo linked to Loki (trace → logs) and to Prometheus.
  - One dashboard from the repo (`platform/observability/dashboards/homelab-overview.json`, loaded by Grafana's dashboard sidecar), **"Homelab overview"**, with a `cluster` variable:
    - CPU and memory by namespace.
    - Pod restarts.
    - Traefik requests per second and the 5xx rate per router.
    - podinfo request latency (p50/p95).

### Instrumentation
- **podinfo chart:** new values for the OTel service name and the OTLP endpoint (`alloy.observability.svc:4317`). The deployment passes them to podinfo's built-in OpenTelemetry support, and the pod gets `prometheus.io/scrape` annotations. The settings are shared across environments, because the Alloy address is the same in both clusters.
- **Traefik values** (`envs/<env>/traefik.yaml`): OTLP tracing to Alloy, plus scrape annotations for its metrics endpoint.

### Portal and bootstrap
- **Homepage:** an "Observability" group with a Grafana tile linking to `http://grafana.dev.localhost:8080`.
- **`print_summary`:** adds the Grafana URL and the command to read its admin password.
- **README:** Docker needs 9 GB; a Grafana row in the URL table.

## Security
- The backend write and query NodePorts are unauthenticated and reachable only on the Docker `kind` network. They are not host-mapped.
- No secrets in Git. Grafana's admin password is generated by bootstrap into Secret `grafana-admin`.

## Testing
`make test` (`scripts/smoke-test.sh`) gains:
- `check grafana.dev.localhost 8080 /api/health`, which expects HTTP 200.
- Data checks from a probe pod in dev (the same run-pod/read-logs pattern as `check_internal`). Each one names its failure:
  - **Metrics:** a Prometheus query on `30909` for `up{cluster="dev"}` and `up{cluster="prod"}` must both return series.
  - **Logs:** a Loki query on `30310` for `{cluster="prod"}` over the last 10 minutes must return at least one line.
  - **Traces:** the test first sends a request to `podinfo.prod.localhost:9080`. A Tempo search on `30320` for `resource.service.name="podinfo"` and `resource.k8s.cluster.name="prod"` must then return a trace within 60s (polled).

`make lint` is unchanged.

## Failure handling
- If dev's backends are unreachable, Alloy keeps retrying. Metrics are buffered in the write-ahead log, and logs and traces retry briefly; gaps are acceptable.
- Agents and backends are separate Argo CD apps. A bad agent config on `main` (prod) can't break the backends, and the reverse is also true.
- Apps can arrive in any order: agents retry until the backends exist.

## Promotion
Agent config (`envs/<env>/alloy.yaml`), Traefik tracing (`envs/<env>/traefik.yaml`) and podinfo instrumentation (the chart) move through `develop → release → main`. The backends and Grafana run only in dev and follow `release`.

## Out of scope (v1)
Alerting and Alertmanager, long retention and object storage, authentication or multi-tenancy on the backends, continuous profiling, SLOs, and community dashboards from grafana.com (the pods don't trust the Zscaler CA).
