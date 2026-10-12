# gitops-demo

Local Kubernetes + GitOps homelab: two kind clusters (`dev`, `prod`) managed by one Argo CD from this repo.

## Prerequisites

Docker (running), `kind`, `kubectl`, `helm`, `curl`, `make`. Optional: `gh`, for the promotion flow.

Behind a TLS-intercepting proxy (e.g. Zscaler), pass its root CA so the kind nodes can pull images:
`EXTRA_CA_FILE=/path/to/proxy-root-ca.pem make up`. Keep that file out of this repo.

## Usage

```bash
make up     # create clusters, install Argo CD, register clusters, apply root app
make test   # wait for apps Synced/Healthy and check every URL
make lint   # lint and render the podinfo chart for dev and prod
make down   # delete both clusters
```

| URL | What |
|---|---|
| http://portal.dev.localhost:8080 | Homepage portal |
| http://argocd.dev.localhost:8080 | Argo CD (user `admin`; password printed by `make up`) |
| http://traefik.dev.localhost:8080/dashboard/ | Traefik dashboard, dev |
| http://traefik.prod.localhost:9080/dashboard/ | Traefik dashboard, prod |
| http://podinfo.dev.localhost:8080 | podinfo, dev |
| http://podinfo.prod.localhost:9080 | podinfo, prod |

## Layout

- `argocd/`: what the root app syncs (ApplicationSets plus the Homepage app)
- `charts/podinfo/`: our app chart
- `envs/<env>/`: Helm values per environment
- `bootstrap/`, `clusters/`, `scripts/`: one-time setup

## Deploying and promoting

| Branch | Deploys to |
|---|---|
| `develop` | nothing (work happens here) |
| `release` | dev cluster |
| `main` | prod cluster |

1. Commit to `develop`. To change the app version, edit `image.tag` in `charts/podinfo/values.yaml`; settings specific to one environment live in `envs/<env>/`.
2. PR `develop → release`: dev syncs. Verify on dev.
3. PR `release → main`: prod syncs.

Merge with a merge commit (not squash) so the branches never diverge. Every app auto-syncs with prune and self-heal.
