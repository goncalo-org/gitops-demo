# K8sGPT — Design

**Date:** 2026-10-14
**Builds on:** `2026-10-12-gitops-homelab-design.md` and `2026-10-12-observability-design.md` (two kind clusters, Argo CD in dev, Alloy shipping logs to Loki, Grafana in dev, develop → release → main)

## Goal

Continuous problem detection in both clusters with K8sGPT. Its analyzers find broken resources, such as crash-looping pods, bad image references, Services without endpoints and failing Ingresses. A local LLM explains each finding in plain English. Findings are visible with kubectl and in Grafana, per cluster.

## Decisions

| Topic | Choice | Why |
|---|---|---|
| Mode | `k8sgpt-operator` in both clusters, through Argo CD | Continuous scanning, GitOps-managed, promoted like the other agents |
| AI backend | Ollama on the Mac (`llama3.2:3b`), already installed | Free and private; pods never reach the internet, so the Zscaler CA doesn't matter; the model's RAM is outside Colima |
| Backend type | `localai` with `baseUrl` pointing at Ollama's OpenAI-compatible `/v1` | The operator's CRD has no `ollama` backend; `localai` speaks the OpenAI API |
| Visibility | `Result` custom resources, plus the operator's result logging → Alloy → Loki → Grafana | The operator's metrics sit behind kube-rbac-proxy (HTTPS and auth), which annotation scraping can't read; logs reuse the existing pipeline and its `cluster` label |

## Architecture

```
Mac: ollama serve (127.0.0.1:11434, model llama3.2:3b)
        ▲  http://192.168.5.2:11434/v1  (Colima/Lima maps 192.168.5.2 to the Mac's loopback)
        │
kind-dev and kind-prod (identical):
  namespace k8sgpt
    k8sgpt-operator ──creates──► k8sgpt server (from the K8sGPT resource)
                                   └─ analyzes the cluster ─► Result CRs (namespace k8sgpt)
    operator logs each Result (enableResultLogging)
         ▼
  Alloy (already tails every namespace except kube-system and observability)
         ▼
  Loki (dev) ─► Grafana: "K8sGPT findings" panel in Homelab overview
```

Traffic path to Ollama: pod → kind node container → Colima VM → `192.168.5.2` → the Mac's `127.0.0.1:11434`. Ollama keeps its default loopback binding, so nothing is exposed on the LAN. The implementation verifies this path from a pod before anything depends on it. If the address doesn't route, the fallback is `host.docker.internal` or the Colima VM's gateway address, recorded in the spec once verified.

## Components

### `argocd/k8sgpt-appset.yaml`
An ApplicationSet with the cluster generator (selector: label `env` exists). It creates `k8sgpt-<env>` in namespace `k8sgpt`, sourced from the branch in the cluster's `branch` annotation (dev → `release`, prod → `main`). It uses the same template conventions as `alloy-appset.yaml`: dot access and `missingkey=error`. Automated sync with prune and selfHeal; `CreateNamespace=true`.

Two sources:
1. **Chart:** `k8sgpt-operator` 0.2.29 from `https://charts.k8sgpt.ai/`, with values `$values/envs/common/k8sgpt-operator.yaml`.
2. **Directory:** `platform/k8sgpt/`, from the same repo and branch.

### `envs/common/k8sgpt-operator.yaml`
```yaml
controllerManager:
  manager:
    enableResultLogging: true
```
The chart's ServiceMonitor and Grafana dashboard stay off: there's no Prometheus Operator, and its metrics aren't scraped.

### `platform/k8sgpt/k8sgpt.yaml`
One `K8sGPT` resource (`core.k8sgpt.ai/v1alpha1`), named `k8sgpt-ollama`:
- `ai.enabled: true`, `ai.backend: localai`, `ai.baseUrl: http://192.168.5.2:11434/v1`, `ai.model: llama3.2:3b`.
- `noCache: true`; no remote cache.
- `version` pinned to an exact K8sGPT release, the latest that works with operator 0.2.29, chosen during implementation.
- Annotation `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true`, so the first sync succeeds before the operator's CRDs exist.

The resource is identical in both clusters, so there are no files per environment. It still moves develop → release → main through the branch-gated source.

### Grafana
`platform/observability/dashboards/homelab-overview.json` gains a logs panel, **"K8sGPT findings"**, querying Loki for `{cluster="$cluster", namespace="k8sgpt"}`. Its exact filter is chosen once the result-log format is seen.

### Bootstrap and README
- README prerequisites: Ollama installed and running, and `ollama pull llama3.2:3b` done.
- `check_prereqs` **warns** (doesn't fail) if `http://127.0.0.1:11434/api/tags` doesn't list the model. Without Ollama, the analyzers still produce Results, just without explanations.
- A README section, "Finding problems with K8sGPT": `kubectl --context kind-<env> -n k8sgpt get results`, `-o yaml` for the explanation, and the Grafana panel.

## Failure handling
- **Ollama down or the model missing:** Results still appear, with empty or failed explanations. The operator retries on its next reconcile.
- **Isolation:** K8sGPT is its own Argo CD app per cluster. A bad config can't break the backends or other apps.
- **Prod first:** prod's resource arrives through `main`, after it has run in dev from `release`.

## Testing
- **`make lint`:** client-side validation of the `K8sGPT` resource needs its CRD, which isn't available offline, so lint asserts with `grep` that `platform/k8sgpt/k8sgpt.yaml` has the `localai` backend, the `baseUrl` and the model.
- **`make test` (`scripts/smoke-test.sh`), end to end in prod:**
  1. Create namespace `k8sgpt-smoke` (not managed by Argo CD) with a pod using a nonexistent image tag.
  2. Within 3 minutes, a Result referring to that pod must appear in namespace `k8sgpt`, with a non-empty `spec.details`. This proves the analyzer and Ollama both worked.
  3. Delete `k8sgpt-smoke`, even on failure, using a trap.
  The check names its failure: "no Result" means the analyzer path failed; "empty details" means Ollama is unreachable.

## Resources
About 200 MB per cluster in Colima: the operator, kube-rbac-proxy and the k8sgpt server. The model runs on the Mac, outside Colima's 9 GB.

## Out of scope (v1)
A Homepage tile (K8sGPT has no UI), metrics and alerting, auto-remediation, sinks such as Slack, cloud LLM backends, and the `customrest` backend.
