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

# Kong
kubectl get pods -n kong
kubectl get svc -n kong 2>/dev/null

# Observability namespace
kubectl get pods -n observability -o wide
kubectl get svc -n observability

# Kong-managed Ingress/plugins
kubectl get ingress --all-namespaces -o wide 2>/dev/null
kubectl get kongplugins,kongclusterplugins --all-namespaces 2>/dev/null

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
| Kong | kong | Running / Error | proxy NodePort 30080, manager NodePort 30002 |
| Prometheus | observability | Running / Error | |
| Grafana | observability | Running / Error | |
| Jaeger | observability | Running / Error | |
| Loki | observability | Running / Error | |
| OTel Collector | observability | Running / Error | |

List any pods in `CrashLoopBackOff`, `Pending`, or `Error` state with a
brief log snippet.
