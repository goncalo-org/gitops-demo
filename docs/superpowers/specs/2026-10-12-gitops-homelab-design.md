# GitOps Homelab — Design

**Date:** 2026-10-12
**Repo:** https://github.com/goncalo-org/gitops-demo (public)

## Goal

A local DevOps homelab for learning Kubernetes and GitOps: two kind clusters (`dev`, `prod`) on a Mac, managed from Git by a single Argo CD instance, with apps deployed as Helm charts, values per environment, and a small developer portal.

## Decisions

| Topic | Choice | Why |
|---|---|---|
| Cluster runtime | kind (already installed) | Upstream Kubernetes; ~1 GB/cluster is acceptable |
| Environment isolation | Two clusters: `kind-dev`, `kind-prod` | Realistic cluster-to-cluster promotion |
| GitOps controller | Argo CD, installed in `kind-dev`, manages both clusters | Native multi-cluster, ApplicationSets, UI |
| Ingress controller | Traefik (Helm) | ingress-nginx was retired in March 2026 |
| Developer portal | Homepage (gethomepage.dev), `kind-dev` only | Lightweight; Argo CD and Traefik widgets |
| Git | Public GitHub repo; work on `develop`; `release` deploys to dev, `main` deploys to prod | No repository credentials needed; each deploy is an explicit PR |

## Architecture

```
GitHub: goncalo-org/gitops-demo (public)
        │  Argo CD pulls
        ▼
kind-dev ──────────────────────────────┐
  argocd (manages both clusters)       │ registered via docker network:
  traefik      → 127.0.0.1:8080        │ https://prod-control-plane:6443
  homepage (portal)                    ▼
  podinfo (1 replica)              kind-prod
                                     traefik → 127.0.0.1:9080
                                     podinfo (2 replicas)
```

- kind cluster names are `dev` and `prod`: kubectl contexts `kind-dev`/`kind-prod`, node containers `dev-control-plane`/`prod-control-plane`.
- Each kind cluster maps a host port (`127.0.0.1` only) to node port `30080`: dev → `8080`, prod → `9080`.
- Traefik runs as a `NodePort` Service on `30080` (`web` entrypoint). Apps use standard `Ingress` with `ingressClassName: traefik`.
- Hostnames under `*.localhost` resolve to 127.0.0.1, so no `/etc/hosts` edits.
- Argo CD in `kind-dev` reaches prod through the internal Docker hostname `prod-control-plane:6443`, not the host kubeconfig address.

### URLs

| URL | Service |
|---|---|
| `http://portal.dev.localhost:8080` | Homepage portal |
| `http://argocd.dev.localhost:8080` | Argo CD UI |
| `http://traefik.dev.localhost:8080` | Traefik dashboard (dev) |
| `http://traefik.prod.localhost:9080` | Traefik dashboard (prod) |
| `http://podinfo.dev.localhost:8080` | podinfo (dev) |
| `http://podinfo.prod.localhost:9080` | podinfo (prod) |

## Repository layout

```
gitops-demo/
├── Makefile                  # up | down | lint | test
├── scripts/
│   ├── bootstrap.sh          # create clusters, install Argo CD, register clusters, apply root app
│   └── smoke-test.sh         # wait for apps Synced/Healthy, curl every URL
├── clusters/
│   ├── kind-dev.yaml
│   └── kind-prod.yaml
├── bootstrap/
│   ├── argocd-values.yaml    # Argo CD Helm values (ingress, insecure server, readonly `portal` account)
│   └── root-app.yaml         # the only Application applied by hand; syncs argocd/
├── argocd/
│   ├── traefik-appset.yaml   # cluster generator → traefik-<env>
│   ├── podinfo-appset.yaml   # cluster generator → podinfo-<env>
│   └── homepage-app.yaml     # single Application → kind-dev
├── charts/podinfo/           # our own chart: Deployment, Service, Ingress
└── envs/
    ├── dev/{traefik,podinfo,homepage}.yaml
    └── prod/{traefik,podinfo}.yaml
```

## Components

### Bootstrap (`scripts/bootstrap.sh`, `make up`)
The only step that isn't GitOps. In order:
1. Check prerequisites: docker running; `kind`, `kubectl`, `helm` on PATH.
2. Create `kind-dev` and `kind-prod` from `clusters/*.yaml`, skipping any that already exist.
   - Optional: if `EXTRA_CA_FILE` is set, install that root CA into both nodes and restart containerd. This is for TLS-intercepting proxies such as Zscaler. The file stays outside the repo.
3. `helm upgrade --install` Argo CD into `kind-dev` (namespace `argocd`) with `bootstrap/argocd-values.yaml`.
4. Register clusters as Argo CD cluster Secrets (`argocd.argoproj.io/secret-type: cluster`):
   - `dev`: server `https://kubernetes.default.svc`, label `env: dev`, annotation `branch: release`.
   - `prod`: create a ServiceAccount `argocd-manager` with cluster-admin plus a long-lived token Secret in `kind-prod`; write a cluster Secret in `kind-dev` with server `https://prod-control-plane:6443`, the bearer token and CA data, label `env: prod`, and annotation `branch: main`.
5. Generate a token for the readonly `portal` Argo CD account and store it as Secret `homepage-argocd-token` in namespace `homepage` on `kind-dev`.
6. Apply `bootstrap/root-app.yaml`.
7. Print the URLs and the command to read the Argo CD admin password.

The script uses `set -euo pipefail` and is idempotent, so re-running it resumes after a partial failure.

### Root app and ApplicationSets
- `root-app` syncs the `argocd/` directory from the `release` branch, so new or changed ApplicationSets land via `develop → release`. The Homepage app (dev only) also follows `release`.
- `traefik-appset` and `podinfo-appset` use the **cluster generator** (selector: label `env` exists) and create `<app>-{{name}}` per cluster, reading `envs/{{metadata.labels.env}}/<app>.yaml` from the branch in the cluster's `branch` annotation (dev → `release`, prod → `main`).
- Templates use plain field access (`{{.metadata.annotations.branch}}`, `{{.metadata.labels.env}}`) with `missingkey=error`, so a cluster Secret missing either one fails loudly. It never silently falls back to the default branch.
- Known trade-off (accepted for v1): because `root-app` follows `release`, a change to an ApplicationSet *definition* reaches prod's Applications when it lands on `release`. Examples are the Traefik chart version and the sync policy. Values files and the in-repo podinfo chart are still gated by `main`. To gate definitions as well later, run one root app per cluster.
- Traefik uses a multi-source Application: the upstream chart (`https://traefik.github.io/charts`) plus `$values` from this repo.
- All apps: automated sync with `prune: true`, `selfHeal: true`, and `CreateNamespace=true`.

### podinfo chart (`charts/podinfo`)
A minimal chart using the `ghcr.io/stefanprodan/podinfo` image. Values: `replicaCount`, `image.tag`, `resources`, `ingress.host`. `image.tag` is set once in `charts/podinfo/values.yaml`, shared by both environments, so promoting a branch moves the version. `envs/<env>/podinfo.yaml` holds only settings specific to each environment.

| | dev | prod |
|---|---|---|
| replicaCount | 1 | 2 |
| ingress.host | `podinfo.dev.localhost` | `podinfo.prod.localhost` |
| resources | small requests | requests + limits |

### Traefik
- Service `NodePort`, `web` entrypoint on nodePort `30080`.
- Dashboard enabled and exposed at `traefik.<env>.localhost`.
- The internal `traefik` entrypoint (API, container port 8080) is also exposed on nodePort `30900` in both clusters. It has **no** kind host port mapping, so it's reachable only on the Docker `kind` network, for the portal widgets.

### Argo CD
- Installed by bootstrap (not self-managed in v1).
- `server.insecure: true` with an Ingress at `argocd.dev.localhost`.
- Extra local account `portal` with `apiKey` capability and role `role:readonly`.

### Homepage
- Upstream Homepage Helm chart, deployed to `kind-dev` only, with an Ingress at `portal.dev.localhost`.
- Tiles:
  - Argo CD: widget with app sync and health counts, using `homepage-argocd-token`, via the in-cluster `argocd-server` Service.
  - Traefik dev: widget with routers and services, via `http://dev-control-plane:30900`.
  - Traefik prod: widget with routers and services, via `http://prod-control-plane:30900`.
  - podinfo dev and prod: links.
- Widgets use the Docker-network node hostnames, not `*.localhost`: inside a pod, `localhost` is the pod itself. This is the same name resolution Argo CD uses to reach prod.

## Promotion flow
| Branch | Deploys to |
|---|---|
| `develop` | nothing (integration) |
| `release` | dev cluster |
| `main` | prod cluster |

1. Commit to `develop`, for example bumping `image.tag` in `charts/podinfo/values.yaml`.
2. A `develop → release` PR deploys it to dev. Verify at `podinfo.dev.localhost:8080`.
3. A `release → main` PR promotes it to prod.

PRs merge with a merge commit (not squash), so the branches never diverge.

## Security
- Port mappings bind to `127.0.0.1` only. The Traefik API nodePort `30900` isn't mapped to the host at all.
- No secrets in Git: the Argo CD admin password stays in its generated Secret; the prod cluster token and the portal token are created at bootstrap.
- The portal uses a readonly Argo CD account.

## Testing
- `make lint`: `helm lint charts/podinfo`, plus `helm template` of the chart with each `envs/<env>/podinfo.yaml`.
- `make test` (`scripts/smoke-test.sh`): waits until every Argo CD Application is `Synced`/`Healthy` (timeout 5 min), then curls each URL in the URLs table and expects HTTP 200. Exits non-zero and names the URL that failed.

## Teardown
`make down` deletes both kind clusters.

## Out of scope (v1)
Observability, sealed or external secrets, TLS/cert-manager, Backstage, CI pipelines, Argo CD managing itself.
