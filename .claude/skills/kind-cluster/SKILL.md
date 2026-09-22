---
description: Start, stop, or restart the jev Kind cluster (Cilium CNI, Podman runtime)
argument-hint: "<start|stop|restart|status>"
disable-model-invocation: false
allowed-tools:
  - Bash
---

Manage the `jev` Kind cluster. Requires `KIND_EXPERIMENTAL_PROVIDER=podman` and
`DOCKER_HOST` — sourced from `.envrc`. The cluster is created with
`disableDefaultCNI: true` and `kubeProxyMode: none`, so nodes stay `NotReady`
until Cilium is installed — see the `cilium` skill, run right after `start`.

## Start

```bash
source .envrc

if kind get clusters 2>/dev/null | grep -q ^jev$; then
  echo "Cluster already exists — exporting kubeconfig"
  kind export kubeconfig --name jev
else
  echo "Creating cluster..."
  kind create cluster --name jev --config kind-config.yaml
fi

kubectl get nodes
# Expect NotReady here — no CNI yet. Run the cilium skill next.
```

## Stop

```bash
source .envrc
kind delete cluster --name jev
```

## Restart

```bash
source .envrc
kind delete cluster --name jev
kind create cluster --name jev --config kind-config.yaml
kubectl get nodes
```

## Status

```bash
source .envrc
kind get clusters
kubectl get nodes -o wide 2>/dev/null || echo "Cluster not reachable"
```
