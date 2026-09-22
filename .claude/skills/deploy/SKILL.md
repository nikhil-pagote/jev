---
description: Bootstrap the jev cluster end to end — kind, Cilium, ArgoCD, then the app-of-apps root Application
argument-hint: "[--step <1-4>]"
allowed-tools:
  - Bash
  - Read
---

Deploy flow (strict order — each step depends on the previous one):
1. Create the Kind cluster (CNI + kube-proxy disabled)
2. Install Cilium via Helm (CNI, kube-proxy replacement, Hubble)
3. Install ArgoCD via Helm
4. Apply `bootstrap/root-app.yaml` **once** — after this, ArgoCD watches this
   repo's `argocd-apps/` directory continuously. New commits (new `app.yaml`,
   edited `values.yaml`) are picked up automatically — no further manual
   `kubectl apply` is needed.

Pass `--step N` to run only a specific step.

## Pre-flight

```bash
source .envrc
podman version 2>/dev/null && echo "podman: OK" || echo "podman: NOT FOUND"
kind version 2>/dev/null && echo "kind: OK" || echo "kind: NOT FOUND"
kubectl version --client 2>/dev/null && echo "kubectl: OK" || echo "kubectl: NOT FOUND"
helm version 2>/dev/null && echo "helm: OK" || echo "helm: NOT FOUND"

missing=()
for app in traefik prometheus grafana loki jaeger opentelemetry-collector; do
  [ -f "argocd-apps/$app/chart/Chart.yaml" ] || missing+=("$app")
done
[ ${#missing[@]} -eq 0 ] \
  && echo "charts: OK" \
  || echo "charts: MISSING — run the helm-vendor skill for: ${missing[*]}"
```

## Step 1 — Cluster

Use the `kind-cluster` skill (`start`). Verify: `kubectl get nodes` (expect
`NotReady` — no CNI yet).

## Step 2 — Cilium

Use the `cilium` skill (`install`). Verify: `kubectl get nodes` (expect
`Ready` on all nodes).

## Step 3 — ArgoCD

```bash
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update argo
helm install argocd argo/argo-cd -n argocd --create-namespace \
  --set server.extraArgs="{--insecure,--rootpath=/argocd}" \
  --wait
kubectl get pods -n argocd
```

Retrieve the initial admin password:
```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

## Step 4 — Bootstrap the app-of-apps root

```bash
kubectl apply -f bootstrap/root-app.yaml
kubectl get applications -n argocd
```

This is the **only** manual apply for the GitOps tree. `root` syncs every
child `app.yaml` under `argocd-apps/` (including `ingress-routes/app.yaml`,
which then syncs its own `routes.yaml` independently) and self-heals on
drift.

## Monitor

```bash
kubectl get applications -n argocd -w
kubectl get pods -n observability -w
kubectl get pods -n traefik -w

make urls   # prints the node IP + path map once Traefik is Ready
```
