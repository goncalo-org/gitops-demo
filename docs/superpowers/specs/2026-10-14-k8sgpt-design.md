# K8sGPT — Design

**Date:** 2026-10-14
**Builds on:** `2026-10-12-gitops-homelab-design.md` and `2026-10-12-observability-design.md` (two kind clusters, Argo CD in dev, Alloy shipping logs to Loki, Grafana in dev, develop → release → main)

## Goal

Continuous problem detection in both clusters with K8sGPT. Its analyzers find broken resources, such as crash-looping pods, bad image references, Services without endpoints and failing Ingresses. Findings are visible with kubectl and in Grafana, per cluster.

AI explanations are **off** in v1: NTT DATA's proxy blocks the Ollama model download (`registry.ollama.ai`'s storage returns a "blocked by NTT DATA" page), so no local model is available. The design keeps AI a one-line switch for when an approved model exists (see "Enabling AI later").

## Decisions

| Topic | Choice | Why |
|---|---|---|
| Mode | `k8sgpt-operator` in both clusters, through Argo CD | Continuous scanning, GitOps-managed, promoted like the other agents |
| AI | `ai.enabled: false` for now | The corporate proxy blocks the Ollama model download; a local LLM backend was the plan but no model can be fetched |
| Visibility | `Result` custom resources, plus the operator's result logging → Alloy → Loki → Grafana | The operator's metrics sit behind kube-rbac-proxy (HTTPS and auth), which annotation scraping can't read; logs reuse the existing pipeline and its `cluster` label |

## Architecture

```
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

The in-pod → Mac route to Ollama at `http://192.168.5.2:11434/v1` was confirmed working (a probe pod in both clusters got the model list), so the plumbing is ready; only the model is missing. With AI off, K8sGPT makes no outbound calls at all.

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
One `K8sGPT` resource (`core.k8sgpt.ai/v1alpha1`), named `k8sgpt`:
- `ai.enabled: false`. The analyzers run; nothing is sent to an LLM.
- `noCache: false`: the k8sgpt server's local cache (no remote cache).
- `version: v0.4.40`, the latest K8sGPT image on ghcr.io on 2026-10-14.
- Annotation `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true`, so the first sync succeeds before the operator's CRDs exist.

The resource is identical in both clusters, so there are no files per environment. It still moves develop → release → main through the branch-gated source.

### Grafana
`platform/observability/dashboards/homelab-overview.json` gains a logs panel, **"K8sGPT findings"**, querying Loki for `{cluster="$cluster", namespace="k8sgpt"}`. Its exact filter is chosen once the result-log format is seen.

### README
- A section, "Finding problems with K8sGPT": `kubectl --context kind-<env> -n k8sgpt get results`, `-o yaml` for the detail, and the Grafana panel. It notes that AI explanations are off and how to turn them on. No new prerequisite (nothing to install).

## Enabling AI later
When an approved local model exists (Ollama on a permitted network, or a company LLM endpoint), set in `platform/k8sgpt/k8sgpt.yaml`:
```yaml
ai:
  enabled: true
  backend: localai            # any OpenAI-compatible API (the CRD has no "ollama" backend)
  baseUrl: http://192.168.5.2:11434/v1
  model: llama3.2:3b
```
For a cloud endpoint (e.g. `azureopenai`), the key goes in a Secret referenced by `ai.secret`, and the pods must trust the Zscaler CA. The in-pod route to `192.168.5.2` is already verified.

## Failure handling
- **Analyzer only:** with AI off, every Result is a detection with no `details` explanation. That's expected.
- **Isolation:** K8sGPT is its own Argo CD app per cluster. A bad config can't break the backends or other apps.
- **Prod first:** prod's resource arrives through `main`, after it has run in dev from `release`.

## Testing
- **`make lint`:** client-side validation of the `K8sGPT` resource needs its CRD, which isn't available offline, so lint asserts with `grep` that `platform/k8sgpt/k8sgpt.yaml` has `kind: K8sGPT`, the pinned `version`, and `enabled: false`.
- **`make test` (`scripts/smoke-test.sh`), end to end in prod:**
  1. Create namespace `k8sgpt-smoke` (not managed by Argo CD) with a pod using a nonexistent image tag.
  2. Within 3 minutes, a Result referring to that pod must appear in namespace `k8sgpt`. This proves the analyzers run and report. (`details` isn't checked, since AI is off.)
  3. Delete `k8sgpt-smoke`, even on failure, using a trap.

## Resources
About 200 MB per cluster in Colima: the operator, kube-rbac-proxy and the k8sgpt server.

## Out of scope (v1)
LLM explanations (proxy blocks the model; see "Enabling AI later"), a Homepage tile (K8sGPT has no UI), metrics and alerting, auto-remediation, sinks such as Slack, and the `customrest` backend.
