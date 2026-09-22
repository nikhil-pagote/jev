---
description: Show health of every component in the jev stack across all namespaces, including Cilium/Hubble
allowed-tools:
  - Bash
---

Check and summarize the status of the full stack.

## Steps

```bash
# Cluster nodes (CNI readiness)
kubectl get nodes -o wide

# Cilium / Hubble
kubectl -n kube-system get pods -l k8s-app=cilium
kubectl -n kube-system get pods -l k8s-app=hubble-relay
kubectl -n kube-system get pods -l k8s-app=hubble-ui

# ArgoCD sync status — root app-of-apps plus every child
kubectl get applications -n argocd -o wide 2>/dev/null || echo "ArgoCD not deployed"

# Traefik
kubectl get pods -n traefik
kubectl get svc -n traefik traefik 2>/dev/null

# Observability namespace
kubectl get pods -n observability -o wide
kubectl get svc -n observability

# IngressRoutes
kubectl get ingressroute --all-namespaces 2>/dev/null

# Any pods not Running
kubectl get pods --all-namespaces | grep -vE "Running|Completed|NAME"
```

## Output format

Report as a table:

| Component | Namespace | Status | Notes |
|---|---|---|---|
| Kind cluster | — | Ready / Error | node count |
| Cilium | kube-system | Running / Error | kube-proxy replacement |
| Hubble Relay/UI | kube-system | Running / Error | |
| ArgoCD `root` | argocd | Synced / OutOfSync | app-of-apps |
| Traefik | traefik | Running / Error | NodePort 30080 |
| Prometheus | observability | Running / Error | |
| Grafana | observability | Running / Error | |
| Jaeger | observability | Running / Error | |
| Loki | observability | Running / Error | |
| OTel Collector | observability | Running / Error | |

List any pods in `CrashLoopBackOff`, `Pending`, or `Error` state with a
brief log snippet.
