# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Container runtime

**Podman** (rootless) — Docker is not used. kind talks to Podman via env vars
in `.envrc`:
```bash
export KIND_EXPERIMENTAL_PROVIDER=podman
export DOCKER_HOST="unix:///run/user/$(id -u)/podman/podman.sock"
```
Source it once per shell (`source .envrc`); verify the socket first:
`systemctl --user status podman.socket`.

## Bootstrap order (strict)

Cilium is the CNI (`kind-config.yaml` sets `disableDefaultCNI: true`,
`kubeProxyMode: none`) — it cannot be one of the ArgoCD-managed apps, since
no pod (including ArgoCD's own) gets an IP without it:

```
make cluster   # kind create cluster — nodes come up NotReady, expected
make cilium    # Cilium CNI + kube-proxy replacement + Hubble
make argocd    # helm install argocd (--insecure --rootpath=/argocd)
make bootstrap # kubectl apply bootstrap/root-app.yaml — one-time, only manual apply
```
`make all` runs all four. After `bootstrap`, ArgoCD watches `argocd-apps/`
continuously — no further manual `kubectl apply` for anything under it.

## Architecture

**GitOps layer** (`argocd-apps/`) — `bootstrap/root-app.yaml` is the
app-of-apps root (`directory.recurse: true`, excluding `**/chart/**` and
`**/values/**`). Each `argocd-apps/<app>/` follows the same pattern:
`app.yaml` (ArgoCD `Application`), `chart/` (vendored via `helm pull
--untar` — see the `helm-vendor` skill), `values/values.yaml`.

**Namespace layout:**

| Namespace | Contents |
|---|---|
| `kube-system` | Cilium, Hubble Relay/UI |
| `traefik` | Traefik ingress (sync-wave 0 — deployed first) |
| `argocd` | ArgoCD server + application controller |
| `observability` | Prometheus, Grafana, Jaeger, Loki, OTel Collector |

**Ingress:** plain `NodePort` (no `extraPortMappings`) — reached via the
node's container IP + NodePort `30080`, not `localhost`. Path-based routing
via `argocd-apps/ingress-routes.yaml` (Traefik `IngressRoute`s, one per UI,
each in its target's own namespace).

**Data flow:** Apps → OTel Collector (OTLP :4317/:4318) → Prometheus
(metrics) + Jaeger (traces, OTLP :4317) + Loki (logs, native OTLP at
`/otlp`) → Grafana.

## Key constraints

- Jaeger (`base_path: /jaeger`) and ArgoCD (`--rootpath=/argocd`) handle
  their own subpath — their `IngressRoute`s must NOT strip the prefix.
  Grafana and Hubble UI need the prefix stripped instead (see comments in
  `argocd-apps/ingress-routes.yaml`).
- OTel Collector uses the **contrib** image (`otelcol-contrib`) — the
  `prometheus` exporter isn't in the core image.
- Loki runs in `SingleBinary` mode with filesystem storage, not
  `SimpleScalable`/`Distributed` (those require object storage).

## Project skills

Skills in `.claude/skills/` (invoke via the Skill tool):

| Skill | Purpose |
|---|---|
| `kind-cluster` | Start, stop, restart, or check status of the cluster |
| `cilium` | Install, check status of, or troubleshoot Cilium/Hubble |
| `deploy` | Guided end-to-end bootstrap with pre-flight checks |
| `validate` | `kubectl --dry-run=client` on all manifests |
| `stack-status` | Component health table across all namespaces |
| `helm-vendor` | Pull or update a vendored chart in `argocd-apps/<app>/chart` |

Subagent: `k8s-troubleshooter` (`.claude/agents/`) for diagnosing pod/ArgoCD
sync/Cilium failures.

Design intent and rationale: `.claude/intent.md`. Full implementation plan:
`.claude/plan.md`.
