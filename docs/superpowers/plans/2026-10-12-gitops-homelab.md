# GitOps Homelab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two local kind clusters (`dev`, `prod`) managed from GitHub by one Argo CD, running Traefik, a Helm-charted podinfo app, and a Homepage portal.

**Architecture:** `scripts/bootstrap.sh` creates the clusters, installs Argo CD into `kind-dev` with Helm, registers both clusters as labelled cluster Secrets, and applies one root Application. From then on everything is reconciled from GitHub: the dev cluster follows the `release` branch and the prod cluster follows `main`. ApplicationSets with a cluster generator create one Traefik and one podinfo app per cluster, reading the branch from each cluster Secret's `branch` annotation and environment-specific values from `envs/<env>/*.yaml`.

**Tech Stack:** kind v0.32, kubectl, Helm v3.18, curl, Argo CD (chart `argo/argo-cd` 10.10.3), Traefik (chart `traefik/traefik` 41.7.1), Homepage (chart `jameswynn/homepage` 2.1.0), podinfo image `ghcr.io/stefanprodan/podinfo`, bash, make.

**Spec:** `docs/superpowers/specs/2026-10-12-gitops-homelab-design.md`

---

## Read this first

- **Branches:** work happens on `develop`. A `develop → release` PR deploys to the **dev** cluster; a `release → main` PR deploys to **prod**. Argo CD only sees GitHub, never local branches, so work in this checkout, not a worktree. During Tasks 5–7, deploy by fast-forwarding all three branches: `git push origin develop develop:release develop:main`. From Task 8 on, `release` and `main` only move through PRs merged with a merge commit (never squash, so the branches don't diverge). The root app and the Homepage app (dev-only) follow `release`. Pushing to the public repo is approved.
- **Promotion carries the image tag:** the podinfo image tag lives in `charts/podinfo/values.yaml` (shared). `envs/<env>/podinfo.yaml` holds only settings specific to each environment, so merging a branch moves the version.
- **Corporate TLS proxy:** this machine's Zscaler proxy intercepts `ghcr.io` and `ecr-public.aws.com`. Run bootstrap as `EXTRA_CA_FILE=$HOME/.config/gitops-demo/extra-ca.pem make up` so the kind nodes trust it (Task 3). That file must never be copied into the repo.
- **"Tests" here** are `scripts/lint.sh` (chart rendering) and `scripts/smoke-test.sh` (the live lab). The smoke test is written in Task 4, before anything it checks exists. Each later task turns more of its checks green.
- **Names:** kind clusters are `dev` and `prod`. kubectl contexts are `kind-dev` and `kind-prod`. Node containers on the Docker `kind` network are `dev-control-plane` and `prod-control-plane`.
- **Ports:** host `127.0.0.1:8080` → dev node `30080`, and host `127.0.0.1:9080` → prod node `30080`. Traefik's API is on nodePort `30900` in both clusters and is **not** mapped to the host.
- **Makefile recipes must be indented with a real TAB.**
- **Commit trailer:** end every commit with `-m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"` as shown.

## File map

| File | Responsibility |
|---|---|
| `Makefile` | `up`, `down`, `lint`, `test` entry points |
| `scripts/lint.sh` | Lint and render the podinfo chart for each environment, assert key fields |
| `scripts/bootstrap.sh` | Non-GitOps setup: clusters, Argo CD, cluster registration, portal token, root app |
| `scripts/smoke-test.sh` | Wait for Argo CD apps to be Synced/Healthy, curl every URL, probe Traefik API from inside `kind-dev` |
| `clusters/kind-{dev,prod}.yaml` | kind cluster configs (port mappings) |
| `bootstrap/argocd-values.yaml` | Argo CD Helm values (insecure server, ingress, readonly `portal` account) |
| `bootstrap/root-app.yaml` | Root Application that syncs `argocd/` |
| `argocd/traefik-appset.yaml` | ApplicationSet → `traefik-dev`, `traefik-prod` |
| `argocd/podinfo-appset.yaml` | ApplicationSet → `podinfo-dev`, `podinfo-prod` |
| `argocd/homepage-app.yaml` | Application → Homepage on `kind-dev` |
| `charts/podinfo/**` | Our podinfo chart |
| `envs/{dev,prod}/{traefik,podinfo}.yaml`, `envs/dev/homepage.yaml` | Values per environment |
| `README.md` | How to use the lab |

---

### Task 1: podinfo Helm chart and lint

**Files:**
- Create: `Makefile`
- Create: `scripts/lint.sh`
- Create: `charts/podinfo/Chart.yaml`, `charts/podinfo/values.yaml`
- Create: `charts/podinfo/templates/deployment.yaml`, `charts/podinfo/templates/service.yaml`, `charts/podinfo/templates/ingress.yaml`
- Create: `envs/dev/podinfo.yaml`, `envs/prod/podinfo.yaml`

- [ ] **Step 1: Write the lint script (the test)**

`scripts/lint.sh`:

```bash
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

assert dev  "replicas: 1" "host: podinfo.dev.localhost"  "ingressClassName: traefik" "value: \"dev\""
assert prod "replicas: 2" "host: podinfo.prod.localhost" "ingressClassName: traefik" "value: \"prod\"" "limits:"
```

`Makefile` (recipe lines start with a TAB):

```makefile
.PHONY: up down lint test

up:
	./scripts/bootstrap.sh

down:
	kind delete cluster --name dev
	kind delete cluster --name prod

lint:
	./scripts/lint.sh

test:
	./scripts/smoke-test.sh
```

Run: `chmod +x scripts/lint.sh`

- [ ] **Step 2: Run lint to verify it fails**

Run: `make lint`
Expected: FAIL. `helm lint` errors because `charts/podinfo` doesn't exist (`Error: unable to check Chart.yaml file in chart`).

- [ ] **Step 3: Write the chart**

`charts/podinfo/Chart.yaml`:

```yaml
apiVersion: v2
name: podinfo
description: Sample web app for the GitOps homelab
type: application
version: 0.1.0
appVersion: "6.9.0"
```

`charts/podinfo/values.yaml`:

```yaml
replicaCount: 1

image:
  repository: ghcr.io/stefanprodan/podinfo
  # Shared by all environments: promotion moves this value between branches.
  tag: "6.9.0"

# Shown on the podinfo UI so you can tell environments apart.
message: ""

ingress:
  host: podinfo.local

resources: {}
```

`charts/podinfo/templates/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
  labels:
    app.kubernetes.io/name: podinfo
    app.kubernetes.io/instance: {{ .Release.Name }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app.kubernetes.io/instance: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: podinfo
        app.kubernetes.io/instance: {{ .Release.Name }}
    spec:
      containers:
        - name: podinfo
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          ports:
            - name: http
              containerPort: 9898
          env:
            - name: PODINFO_UI_MESSAGE
              value: {{ .Values.message | quote }}
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
```

`charts/podinfo/templates/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}
  labels:
    app.kubernetes.io/name: podinfo
    app.kubernetes.io/instance: {{ .Release.Name }}
spec:
  selector:
    app.kubernetes.io/instance: {{ .Release.Name }}
  ports:
    - name: http
      port: 80
      targetPort: http
```

`charts/podinfo/templates/ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .Release.Name }}
  labels:
    app.kubernetes.io/name: podinfo
    app.kubernetes.io/instance: {{ .Release.Name }}
spec:
  ingressClassName: traefik
  rules:
    - host: {{ .Values.ingress.host }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ .Release.Name }}
                port:
                  name: http
```

`envs/dev/podinfo.yaml`:

```yaml
replicaCount: 1
message: "dev"
ingress:
  host: podinfo.dev.localhost
resources:
  requests:
    cpu: 10m
    memory: 32Mi
```

`envs/prod/podinfo.yaml`:

```yaml
replicaCount: 2
message: "prod"
ingress:
  host: podinfo.prod.localhost
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 128Mi
```

- [ ] **Step 4: Run lint to verify it passes**

Run: `make lint`
Expected:
```
ok [dev]
ok [prod]
```

- [ ] **Step 5: Commit**

```bash
git add Makefile scripts/lint.sh charts envs
git commit -m "feat: add podinfo chart with dev/prod values and lint" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: kind clusters

**Files:**
- Create: `clusters/kind-dev.yaml`, `clusters/kind-prod.yaml`
- Create: `scripts/bootstrap.sh`

- [ ] **Step 1: Verify the clusters don't exist yet (red)**

Run: `kubectl --context kind-dev get nodes`
Expected: FAIL with `context "kind-dev" does not exist` (or, if an old cluster exists, run `make down` first and re-check).

- [ ] **Step 2: Write the kind configs**

`clusters/kind-dev.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: dev
nodes:
  - role: control-plane
    extraPortMappings:
      # Traefik "web" nodePort → http://*.dev.localhost:8080 (localhost only)
      - containerPort: 30080
        hostPort: 8080
        listenAddress: "127.0.0.1"
        protocol: TCP
```

`clusters/kind-prod.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: prod
nodes:
  - role: control-plane
    extraPortMappings:
      # Traefik "web" nodePort → http://*.prod.localhost:9080 (localhost only)
      - containerPort: 30080
        hostPort: 9080
        listenAddress: "127.0.0.1"
        protocol: TCP
```

- [ ] **Step 3: Write the bootstrap script (clusters only for now)**

`scripts/bootstrap.sh`:

```bash
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
```

Run: `chmod +x scripts/bootstrap.sh`

- [ ] **Step 4: Run it and verify**

Run: `make up && kubectl --context kind-dev get nodes && kubectl --context kind-prod get nodes`
Expected: each command lists one `Ready` node (`dev-control-plane`, `prod-control-plane`).

Run `make up` a second time.
Expected: `cluster dev exists, skipping` and `cluster prod exists, skipping`, exit 0.

Run: `docker port dev-control-plane`
Expected: includes `30080/tcp -> 127.0.0.1:8080`.

- [ ] **Step 5: Commit**

```bash
git add clusters scripts/bootstrap.sh
git commit -m "feat: create dev and prod kind clusters" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Argo CD and cluster registration

**Files:**
- Create: `bootstrap/argocd-values.yaml`
- Modify: `scripts/bootstrap.sh` (add `install_argocd`, `register_clusters`; update `main`)

- [ ] **Step 1: Verify Argo CD isn't there yet (red)**

Run: `kubectl --context kind-dev -n argocd get secrets -l argocd.argoproj.io/secret-type=cluster`
Expected: `No resources found in argocd namespace.`

- [ ] **Step 2: Write the Argo CD values**

`bootstrap/argocd-values.yaml`:

```yaml
global:
  # Also used as the Ingress hostname.
  domain: argocd.dev.localhost

configs:
  params:
    # Serve plain HTTP; Traefik terminates nothing (no TLS in v1).
    server.insecure: true
  cm:
    # Readonly API account used by the Homepage widget.
    accounts.portal: apiKey
  rbac:
    policy.csv: |
      g, portal, role:readonly

server:
  ingress:
    enabled: true
    ingressClassName: traefik

dex:
  enabled: false

notifications:
  enabled: false
```

- [ ] **Step 3: Add the install and registration functions**

In `scripts/bootstrap.sh`, add these three functions above `main()`:

```bash
# Optional: trust an extra root CA in the kind nodes' containerd (e.g. a TLS-intercepting
# corporate proxy). Usage: EXTRA_CA_FILE=/path/to/ca.pem make up
trust_extra_ca() {
  [[ -n "${EXTRA_CA_FILE:-}" ]] || return 0
  [[ -r "$EXTRA_CA_FILE" ]] || { echo "EXTRA_CA_FILE not readable: $EXTRA_CA_FILE"; exit 1; }
  for node in dev-control-plane prod-control-plane; do
    if docker exec -i "$node" cmp -s /usr/local/share/ca-certificates/extra-ca.crt - <"$EXTRA_CA_FILE"; then
      echo "extra CA already trusted on $node, skipping"; continue
    fi
    docker exec -i "$node" sh -c 'cat > /usr/local/share/ca-certificates/extra-ca.crt && update-ca-certificates >/dev/null && systemctl restart containerd' <"$EXTRA_CA_FILE"
    echo "extra CA trusted on $node"
  done
}

install_argocd() {
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
  helm repo update argo >/dev/null
  helm upgrade --install argocd argo/argo-cd \
    --kube-context "$DEV" \
    --namespace argocd --create-namespace \
    --version 10.10.3 \
    -f bootstrap/argocd-values.yaml \
    --wait --timeout 10m
}

# Registers both clusters as Argo CD cluster Secrets, labelled env=<name>.
# The ApplicationSets select clusters by that label.
register_clusters() {
  kubectl --context "$DEV" apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: cluster-dev
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    env: dev
  annotations:
    branch: release   # dev deploys what is on the release branch
stringData:
  name: dev
  server: https://kubernetes.default.svc
  config: '{"tlsClientConfig":{"insecure":false}}'
EOF

  # Identity Argo CD uses to manage prod.
  kubectl --context "$PROD" apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-manager
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: argocd-manager
    namespace: kube-system
---
apiVersion: v1
kind: Secret
type: kubernetes.io/service-account-token
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: argocd-manager
EOF

  local token="" ca
  until [[ -n "$token" ]]; do
    token=$(kubectl --context "$PROD" -n kube-system get secret argocd-manager-token -o jsonpath='{.data.token}' | base64 -d)
    [[ -n "$token" ]] || sleep 1
  done
  ca=$(kubectl --context "$PROD" -n kube-system get secret argocd-manager-token -o jsonpath='{.data.ca\.crt}')

  # prod-control-plane resolves on the Docker "kind" network, which kind-dev pods can reach.
  kubectl --context "$DEV" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cluster-prod
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    env: prod
  annotations:
    branch: main      # prod deploys what is on main
stringData:
  name: prod
  server: https://prod-control-plane:6443
  config: '{"bearerToken":"$token","tlsClientConfig":{"caData":"$ca"}}'
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
}
```

- [ ] **Step 4: Run it and verify**

Run: `docker exec prod-control-plane crictl pull ghcr.io/stefanprodan/podinfo:6.9.0`
Expected (behind the Zscaler proxy): FAIL with `x509: certificate signed by unknown authority`.

Run: `EXTRA_CA_FILE=$HOME/.config/gitops-demo/extra-ca.pem make up`
Expected: `extra CA trusted on` for both nodes, the Helm release `argocd` is deployed, and exit code is 0. A second run prints `extra CA already trusted on ..., skipping` for both nodes. Without `EXTRA_CA_FILE`, the CA step is a no-op.

Run the `crictl pull` command again.
Expected: the pull succeeds.

Run: `kubectl --context kind-dev -n argocd get secrets -l argocd.argoproj.io/secret-type=cluster -L env`
Expected: two rows, `cluster-dev` (ENV `dev`) and `cluster-prod` (ENV `prod`).

Run: `kubectl --context kind-dev -n argocd get secrets -l argocd.argoproj.io/secret-type=cluster -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.annotations.branch}{"\n"}{end}'`
Expected: `cluster-dev=release` and `cluster-prod=main`.

Run: `kubectl --context kind-dev -n argocd get pods`
Expected: all pods `Running`.

- [ ] **Step 5: Commit**

```bash
git add bootstrap/argocd-values.yaml scripts/bootstrap.sh
git commit -m "feat: install Argo CD in dev and register dev/prod clusters" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Smoke test (written before what it tests)

**Files:**
- Create: `scripts/smoke-test.sh`

- [ ] **Step 1: Write the smoke test**

`scripts/smoke-test.sh`:

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
```

Run: `chmod +x scripts/smoke-test.sh`

- [ ] **Step 2: Run it to verify it fails**

Run: `TIMEOUT=5 make test`
Expected: FAIL. `FAIL apps not Synced/Healthy:` / `only 0 app(s) found` (no apps yet), then a `FAIL` line for each of the 6 URLs (got `000`) and for both in-cluster checks (got `000`), ending with `9 check(s) failed`. This shows the test catches a missing lab.

- [ ] **Step 3: Commit**

```bash
git add scripts/smoke-test.sh
git commit -m "test: add end-to-end smoke test for the lab" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Root app and Traefik in both clusters

**Files:**
- Create: `bootstrap/root-app.yaml`
- Create: `argocd/traefik-appset.yaml`
- Create: `envs/dev/traefik.yaml`, `envs/prod/traefik.yaml`
- Modify: `scripts/bootstrap.sh` (apply the root app; update `main()`)

- [ ] **Step 1: Write the Traefik values per environment**

`envs/dev/traefik.yaml`:

```yaml
service:
  spec:
    type: NodePort
ports:
  web:
    nodePort: 30080      # kind maps this to 127.0.0.1:8080
  traefik:
    expose:
      default: true
    nodePort: 30900      # API for portal widgets; not mapped to the host
# Unauthenticated, read-only API; reachable only inside the Docker kind network (30900 isn't host-mapped).
api:
  insecure: true         # serve the API on the "traefik" entrypoint
ingressRoute:
  dashboard:
    enabled: true
    matchRule: Host(`traefik.dev.localhost`)
    entryPoints: ["web"]
# Write an address into Ingress status so Argo CD reports Ingresses Healthy
# (a NodePort Service has no load balancer address to publish).
additionalArguments:
  - --providers.kubernetesingress.ingressendpoint.ip=127.0.0.1
# The chart's publishedService (default on) copies status from its LoadBalancer-less Service and wins over the ip above.
providers:
  kubernetesIngress:
    publishedService:
      enabled: false
```

`envs/prod/traefik.yaml`:

```yaml
service:
  spec:
    type: NodePort
ports:
  web:
    nodePort: 30080      # kind maps this to 127.0.0.1:9080
  traefik:
    expose:
      default: true
    nodePort: 30900      # API for portal widgets; not mapped to the host
# Unauthenticated, read-only API; reachable only inside the Docker kind network (30900 isn't host-mapped).
api:
  insecure: true         # serve the API on the "traefik" entrypoint
ingressRoute:
  dashboard:
    enabled: true
    matchRule: Host(`traefik.prod.localhost`)
    entryPoints: ["web"]
# Write an address into Ingress status so Argo CD reports Ingresses Healthy
# (a NodePort Service has no load balancer address to publish).
additionalArguments:
  - --providers.kubernetesingress.ingressendpoint.ip=127.0.0.1
# The chart's publishedService (default on) copies status from its LoadBalancer-less Service and wins over the ip above.
providers:
  kubernetesIngress:
    publishedService:
      enabled: false
```

- [ ] **Step 2: Write the ApplicationSet and the root app**

`argocd/traefik-appset.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: traefik
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
      name: 'traefik-{{.name}}'
    spec:
      project: default
      sources:
        - repoURL: https://traefik.github.io/charts
          chart: traefik
          targetRevision: 41.7.1
          helm:
            releaseName: traefik
            valueFiles:
              - '$values/envs/{{.metadata.labels.env}}/traefik.yaml'
        - repoURL: https://github.com/goncalo-org/gitops-demo.git
          targetRevision: '{{.metadata.annotations.branch}}'
          ref: values
      destination:
        server: '{{.server}}'
        namespace: traefik
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true   # Traefik CRDs are too large for client-side apply
```

`bootstrap/root-app.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/goncalo-org/gitops-demo.git
    targetRevision: release
    path: argocd
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- [ ] **Step 3: Apply the root app from bootstrap**

In `scripts/bootstrap.sh`, replace `main()` with:

```bash
main() {
  check_prereqs
  create_clusters
  trust_extra_ca
  install_argocd
  register_clusters
  kubectl --context "$DEV" apply -f bootstrap/root-app.yaml
}
```

- [ ] **Step 4: Commit and push all three branches (Argo CD reads from GitHub)**


```bash
git add bootstrap/root-app.yaml argocd/traefik-appset.yaml envs/dev/traefik.yaml envs/prod/traefik.yaml scripts/bootstrap.sh
git commit -m "feat: root app and Traefik in dev and prod via ApplicationSet" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -u origin develop develop:release develop:main
```

- [ ] **Step 5: Bootstrap and run the smoke test**

Run: `EXTRA_CA_FILE=$HOME/.config/gitops-demo/extra-ca.pem make up && make test`
Expected: still FAIL overall, but now these pass:
```
ok   all apps Synced/Healthy
ok   http://argocd.dev.localhost:8080/
ok   http://traefik.dev.localhost:8080/dashboard/
ok   http://traefik.prod.localhost:9080/dashboard/
ok   in-cluster http://dev-control-plane:30900/api/overview
ok   in-cluster http://prod-control-plane:30900/api/overview
```
and `portal` plus both `podinfo` URLs FAIL (`3 check(s) failed`).

If `traefik-prod` never becomes Healthy, Argo CD can't reach prod. Check with `kubectl --context kind-dev -n argocd logs statefulset/argocd-application-controller | grep -i prod` and `kubectl --context kind-dev -n argocd get secret cluster-prod -o jsonpath='{.data.server}' | base64 -d` (it should print `https://prod-control-plane:6443`).

---

### Task 6: podinfo in both clusters

**Files:**
- Create: `argocd/podinfo-appset.yaml`

- [ ] **Step 1: Confirm the podinfo checks are red**

Run: `make test 2>&1 | grep podinfo`
Expected: `FAIL http://podinfo.dev.localhost:8080/` and `FAIL http://podinfo.prod.localhost:9080/`.

- [ ] **Step 2: Write the ApplicationSet**

`argocd/podinfo-appset.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: podinfo
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
      name: 'podinfo-{{.name}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/goncalo-org/gitops-demo.git
        targetRevision: '{{.metadata.annotations.branch}}'
        path: charts/podinfo
        helm:
          releaseName: podinfo
          valueFiles:
            - '../../envs/{{.metadata.labels.env}}/podinfo.yaml'
      destination:
        server: '{{.server}}'
        namespace: podinfo
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

- [ ] **Step 3: Commit, push, and trigger a refresh**

```bash
git add argocd/podinfo-appset.yaml
git commit -m "feat: deploy podinfo to dev and prod via ApplicationSet" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push origin develop develop:release develop:main
kubectl --context kind-dev -n argocd annotate application root argocd.argoproj.io/refresh=normal --overwrite
```

Without the annotation, Argo CD would pick up the change on its next poll, within about 3 minutes.

- [ ] **Step 4: Run the smoke test**

Run: `make test`
Expected: both `podinfo` URLs now `ok`; only `portal.dev.localhost` FAILs (`1 check(s) failed`).

Run: `kubectl --context kind-prod -n podinfo get deploy podinfo`
Expected: `READY 2/2` (prod has 2 replicas; `kind-dev` shows `1/1`).

---

### Task 7: Homepage portal

**Files:**
- Create: `argocd/homepage-app.yaml`
- Create: `envs/dev/homepage.yaml`
- Modify: `scripts/bootstrap.sh` (add `create_portal_token` and `print_summary`, update `main`)

- [ ] **Step 1: Confirm the portal check is red**

Run: `make test 2>&1 | grep portal`
Expected: `FAIL http://portal.dev.localhost:8080/ (got 404)`. Traefik answers, but nothing routes that host yet.

- [ ] **Step 2: Add the portal token step to bootstrap**

In `scripts/bootstrap.sh`, add these functions above `main()`. The token is created through Argo CD's REST API, not `argocd login`: the CLI's plaintext probe resets the kubectl port-forward.

```bash
# Creates a readonly Argo CD API token for the Homepage widget, stored only in-cluster.
create_portal_token() {
  kubectl --context "$DEV" create namespace homepage --dry-run=client -o yaml | kubectl --context "$DEV" apply -f -
  if kubectl --context "$DEV" -n homepage get secret homepage-argocd-token >/dev/null 2>&1; then
    echo "portal token exists, skipping"; return
  fi

  local pw token
  pw=$(kubectl --context "$DEV" -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
  kubectl --context "$DEV" -n argocd port-forward svc/argocd-server 18080:80 >/dev/null 2>&1 &
  pf=$!   # global so the EXIT trap can still see it
  trap 'kill ${pf:-} 2>/dev/null || true' RETURN EXIT
  until curl -s -o /dev/null http://127.0.0.1:18080/healthz; do sleep 1; done

  # REST instead of `argocd login`: the CLI's plaintext probe resets the kubectl port-forward.
  local jwt
  jwt=$(curl -fsS -H 'Content-Type: application/json' -d "{\"username\":\"admin\",\"password\":\"$pw\"}" \
    http://127.0.0.1:18080/api/v1/session | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
  token=$(curl -fsS -H "Authorization: Bearer $jwt" -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:18080/api/v1/account/portal/token \
    | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
  [ -n "$token" ] || { echo "failed to generate portal token"; return 1; }
  kubectl --context "$DEV" -n homepage create secret generic homepage-argocd-token --from-literal=token="$token"
}

print_summary() {
  cat <<'EOF'

Lab is up. Argo CD syncs everything else from GitHub; run `make test` to wait for it.
  Portal        http://portal.dev.localhost:8080
  Argo CD       http://argocd.dev.localhost:8080   (user: admin)
  Traefik dev   http://traefik.dev.localhost:8080/dashboard/
  Traefik prod  http://traefik.prod.localhost:9080/dashboard/
  podinfo dev   http://podinfo.dev.localhost:8080
  podinfo prod  http://podinfo.prod.localhost:9080

Argo CD admin password:
  kubectl --context kind-dev -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
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
  kubectl --context "$DEV" apply -f bootstrap/root-app.yaml
  print_summary
}
```

- [ ] **Step 3: Write the Homepage values and Application**

`envs/dev/homepage.yaml`:

```yaml
env:
  - name: HOMEPAGE_ALLOWED_HOSTS
    value: portal.dev.localhost:8080
  - name: HOMEPAGE_VAR_ARGOCD_TOKEN
    valueFrom:
      secretKeyRef:
        name: homepage-argocd-token
        key: token

ingress:
  main:
    enabled: true
    ingressClassName: traefik
    hosts:
      - host: portal.dev.localhost
        paths:
          - path: /
            pathType: Prefix

config:
  bookmarks: []
  widgets: []
  # Widget URLs are seen from inside the pod: use in-cluster Services or
  # Docker-network node names, never *.localhost (that is the pod itself).
  services:
    - GitOps:
        - Argo CD:
            href: http://argocd.dev.localhost:8080
            description: Manages dev and prod
            widget:
              type: argocd
              url: http://argocd-server.argocd.svc
              key: "{{HOMEPAGE_VAR_ARGOCD_TOKEN}}"
    - Ingress:
        - Traefik dev:
            href: http://traefik.dev.localhost:8080/dashboard/
            widget:
              type: traefik
              url: http://dev-control-plane:30900
        - Traefik prod:
            href: http://traefik.prod.localhost:9080/dashboard/
            widget:
              type: traefik
              url: http://prod-control-plane:30900
    - Apps:
        - podinfo dev:
            href: http://podinfo.dev.localhost:8080
            description: Sample app, dev
        - podinfo prod:
            href: http://podinfo.prod.localhost:9080
            description: Sample app, prod
  settingsString: |
    title: GitOps Homelab
    headerStyle: boxed
```

`argocd/homepage-app.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: homepage
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: https://jameswynn.github.io/helm-charts
      chart: homepage
      targetRevision: 2.1.0
      helm:
        valueFiles:
          - $values/envs/dev/homepage.yaml
    - repoURL: https://github.com/goncalo-org/gitops-demo.git
      targetRevision: release
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: homepage
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 4: Commit, push, bootstrap (creates the token), and test**

```bash
git add argocd/homepage-app.yaml envs/dev/homepage.yaml scripts/bootstrap.sh
git commit -m "feat: Homepage portal with Argo CD and Traefik widgets" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push origin develop develop:release develop:main
EXTRA_CA_FILE=$HOME/.config/gitops-demo/extra-ca.pem make up
kubectl --context kind-dev -n argocd annotate application root argocd.argoproj.io/refresh=normal --overwrite
make test
```

Expected: `make up` ends with the URL summary, and `make test` ends with `all checks passed`.

- [ ] **Step 5: Check the widgets by eye**

Open `http://portal.dev.localhost:8080`.
Expected: the Argo CD tile shows app counts (not "API Error"), and the Traefik dev and prod tiles both show router and service counts. If Argo CD shows an error, check that the token exists: `kubectl --context kind-dev -n homepage get secret homepage-argocd-token`.

---

### Task 8: Rebuild from scratch, promote, and document

**Files:**
- Create: `README.md`
- Modify: `charts/podinfo/values.yaml` (`image.tag`), `charts/podinfo/Chart.yaml` (`appVersion`)

- [ ] **Step 1: Verify a clean rebuild works**

Run: `make down && EXTRA_CA_FILE=$HOME/.config/gitops-demo/extra-ca.pem make up && make test`
Expected: `all checks passed`. This proves bootstrap and Git alone recreate the lab.

- [ ] **Step 2: Check both versions before promotion (red)**

Run:
```bash
curl -s --resolve podinfo.dev.localhost:8080:127.0.0.1 http://podinfo.dev.localhost:8080/version
curl -s --resolve podinfo.prod.localhost:9080:127.0.0.1 http://podinfo.prod.localhost:9080/version
```
Expected: both JSON responses contain `"version": "6.9.0"`.

- [ ] **Step 3: Bump the version on `develop`**

In `charts/podinfo/values.yaml`, change `tag: "6.9.0"` to `tag: "6.9.2"`. In `charts/podinfo/Chart.yaml`, change `appVersion: "6.9.0"` to `appVersion: "6.9.2"`.

```bash
make lint
git commit -am "chore: bump podinfo to 6.9.2" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push origin develop
```

Pushing `develop` deploys nothing. Re-run the Step 2 commands: both still show `6.9.0`.

- [ ] **Step 4: Deploy to dev with a `develop → release` PR**

```bash
gh pr create --base release --head develop --title "release: podinfo 6.9.2 to dev" --body "Deploy podinfo 6.9.2 to the dev cluster."
gh pr merge --merge
kubectl --context kind-dev -n argocd annotate application podinfo-dev argocd.argoproj.io/refresh=normal --overwrite
```

Run the Step 2 commands again (allow up to a minute for the rollout).
Expected: dev shows `"version": "6.9.2"` and prod still shows `"version": "6.9.0"`.

- [ ] **Step 5: Promote to prod with a `release → main` PR**

```bash
gh pr create --base main --head release --title "promote: podinfo 6.9.2 to prod" --body "Promote podinfo 6.9.2 from dev to prod."
gh pr merge --merge
kubectl --context kind-dev -n argocd annotate application podinfo-prod argocd.argoproj.io/refresh=normal --overwrite
```

Run: `make test && curl -s --resolve podinfo.prod.localhost:9080:127.0.0.1 http://podinfo.prod.localhost:9080/version`
Expected: `all checks passed`, then JSON containing `"version": "6.9.2"`.

- [ ] **Step 6: Write the README**

`README.md`:

````markdown
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
````

- [ ] **Step 7: Commit and push**

```bash
git add README.md
git commit -m "docs: add README" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push origin develop
```

The README doesn't affect the clusters, so it doesn't need a deploy. It reaches `release` and `main` with the next promotion.

