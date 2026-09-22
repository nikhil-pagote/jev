---
description: Install, check status of, or troubleshoot Cilium CNI and Hubble on the jev cluster
argument-hint: "<install|status|uninstall>"
allowed-tools:
  - Bash
---

Cilium is the CNI for this cluster — it must be installed before ArgoCD or
any other workload, since `kind-config.yaml` sets `disableDefaultCNI: true`
and `kubeProxyMode: none`. Nodes stay `NotReady` and no pod gets an IP until
this step completes.

## Install

```bash
source .envrc

helm repo add cilium https://helm.cilium.io --force-update
helm repo update cilium

read API_IP API_PORT < <(./scripts/cilium-api-endpoint.sh)
echo "API endpoint for Cilium: $API_IP:$API_PORT"

helm install cilium cilium/cilium \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="$API_IP" \
  --set k8sServicePort="$API_PORT" \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set bpf.autoMount.enabled=false \
  --wait --timeout 10m

kubectl get nodes
# All nodes should now be Ready
```

## Status

```bash
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
kubectl -n kube-system get pods -l k8s-app=hubble-relay -o wide
kubectl -n kube-system get pods -l k8s-app=hubble-ui -o wide
kubectl -n kube-system get ds kube-proxy 2>&1 || echo "kube-proxy DaemonSet correctly absent (kubeProxyMode: none)"

# If the cilium CLI is installed:
cilium status --wait 2>/dev/null || echo "cilium CLI not installed — pod checks above are sufficient"
```

## Uninstall

```bash
helm uninstall cilium -n kube-system
```

## Common issues

| Symptom | Cause | Fix |
|---|---|---|
| Nodes stuck `NotReady` after install | Cilium agents not Running yet | `kubectl -n kube-system get pods -l k8s-app=cilium`; check logs |
| Cilium agent `CrashLoopBackOff` mentioning apiserver connection | Wrong `k8sServiceHost`/`k8sServicePort` | Re-run `./scripts/cilium-api-endpoint.sh` and re-install with correct values |
| Cilium agent `Init:CrashLoopBackOff`, `mount-bpf-fs` logs `mount: /sys/fs/bpf: permission denied` | Rootless Podman can't perform the `mount -t bpf` syscall itself (no `CAP_SYS_ADMIN` in the host's initial userns, even in a "privileged" container) | Already handled by this repo's `kind-config.yaml` (`extraMounts` bind-mounts the host's bpffs into each node) + `bpf.autoMount.enabled=false` on the Helm install above. If you hit this, you're missing one of those two pieces — check `kind-config.yaml` has the `extraMounts` block and re-create the cluster |
| Pods can't resolve DNS | CoreDNS pods not yet scheduled (needed CNI first) | Wait — CoreDNS pods were `Pending` until Cilium came up; they'll schedule automatically |
