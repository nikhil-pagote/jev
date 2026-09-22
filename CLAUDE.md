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
app-of-apps root (`directory.recurse: true`, `include: "*/app.yaml"` — an
allowlist, since excluding the open-ended vendored `chart/` trees by glob
proved unreliable). Every child (`traefik`, `prometheus`, `grafana`,
`loki`, `jaeger`, `opentelemetry-collector`, `ingress-routes`) follows the
same `<app>/app.yaml` shape, so root's own sync is always just
`Application` objects. Helm-backed apps additionally have `chart/`
(vendored via `helm pull --untar` — see the `helm-vendor` skill) and
`values/values.yaml`; `ingress-routes` is a plain-manifest app instead
(see below).

**Namespace layout:**

| Namespace | Contents |
|---|---|
| `kube-system` | Cilium, Hubble Relay/UI |
| `traefik` | Traefik ingress (sync-wave 0 — deployed first) |
| `argocd` | ArgoCD server + application controller |
| `observability` | Prometheus, Grafana, Jaeger, Loki, OTel Collector |

**Ingress:** plain `NodePort` (no `extraPortMappings`) — reached via the
node's container IP + NodePort `30080`, not `localhost`. Path-based routing
via the `ingress-routes` child Application (`argocd-apps/ingress-routes/`,
Traefik `IngressRoute`s, one per UI, each in its target's own namespace).
It's a **separate** Application from the others on purpose — its
`IngressRoute`/`Middleware` CRs depend on CRDs the `traefik` Application
installs, and folding them into root's own sync made ArgoCD fail resource
discovery for root's entire sync before `traefik` ever got applied. As its
own Application, it simply retries on its own automated-sync cycle until
those CRDs exist.

**Data flow:** Apps → OTel Collector (OTLP :4317/:4318) → Prometheus
(metrics) + Jaeger (traces, OTLP :4317) + Loki (logs, native OTLP at
`/otlp`) → Grafana.

## Key constraints

- Grafana (`serve_from_sub_path: true`), Prometheus (`--web.route-prefix`),
  Jaeger (`base_path: /jaeger`), and ArgoCD (`--rootpath=/argocd`) all
  handle their own subpath — their `IngressRoute`s must NOT strip the
  prefix, or the app issues its own canonical-redirect using a static
  (often wrong, for a dynamic node IP) host. Only Hubble UI (a plain SPA
  with no subpath awareness) needs the prefix stripped (see comments in
  `argocd-apps/ingress-routes/routes.yaml`).
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
