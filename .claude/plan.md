# K8s Observability GitOps POC (`jev`) — Implementation Plan

> Local copy of the plan approved at
> `~/.claude/plans/i-am-planning-to-cryptic-kettle.md`. See `.claude/intent.md`
> for the why behind each decision.

## Context

`jev` started as an empty, non-git directory. The goal is a self-contained
POC: a local **kind** cluster running **Cilium** as CNI, with **ArgoCD**
installed once by hand and then taking over via the **app-of-apps** pattern —
from that point on, any commit to this repo's `argocd-apps/` tree is picked
up and reconciled automatically, no manual `kubectl apply` needed again. The
stack under GitOps is: Traefik (ingress), Prometheus, Grafana, Loki, Jaeger,
OpenTelemetry Collector.

A sibling project (`github.com/nikhil-pagote/k8s_observebility`) already
implements nearly the same stack and was reviewed as a pattern reference
(Application CRD shape, chart-vendoring layout, sync-wave use, Podman-based
kind setup). This is a **fresh, separate** build — that repo is not cloned
or reused, only its conventions are borrowed where they make sense, and
Cilium (which that repo doesn't have) is designed in from the start.

**Decisions locked in:**
- Container runtime: **Podman** (rootless), not Docker.
- Ingress access: plain **NodePort**, no `extraPortMappings` — reached via
  the node's container IP + an explicit stable NodePort (`30080`).
- Routing style: **path-based** on a single Traefik entrypoint.
- Cilium: **full kube-proxy replacement** + **Hubble UI/Relay**.
- No sample workload — platform/stack only.
- GitHub repo **`jev`**, public, created via `gh` under the authenticated
  account, used as the ArgoCD `repoURL`.
- ArgoCD installed via **Helm** (`argo/argo-cd`).

**Assumptions flagged during planning:**
- "3 node cluster" = 1 control-plane + 2 workers (3 nodes total).
- kind uses its latest default node image (no version pin).

## Why Cilium must be installed *before* ArgoCD

Cilium is the CNI. With `disableDefaultCNI: true`, nodes come up `NotReady`
and no pod gets an IP — including ArgoCD's own pods. So Cilium **cannot** be
one of the GitOps-managed apps; it's a manual bootstrap step, same tier as
kind cluster creation itself:

```
1. kind create cluster        (CNI disabled, kube-proxy disabled)
2. helm install cilium        (pod networking + kube-proxy replacement come up)
3. helm install argocd        (now argocd pods can schedule/network)
4. kubectl apply root-app.yaml (one-time; ArgoCD takes over everything after)
```

## Repo layout

```
jev/
├── .envrc
├── Makefile
├── README.md
├── kind-config.yaml
├── scripts/cilium-api-endpoint.sh
├── bootstrap/root-app.yaml
├── argocd-apps/
│   ├── traefik/       {app.yaml, chart/, values/values.yaml}
│   ├── prometheus/    {app.yaml, chart/, values/values.yaml}
│   ├── grafana/       {app.yaml, chart/, values/values.yaml}
│   ├── loki/          {app.yaml, chart/, values/values.yaml}
│   ├── jaeger/        {app.yaml, chart/, values/values.yaml}
│   ├── opentelemetry-collector/ {app.yaml, chart/, values/values.yaml}
│   └── ingress-routes/ {app.yaml, routes.yaml}
└── .claude/{skills,hooks,agents,intent.md,plan.md,settings.json}
```

Every Helm-backed app under `argocd-apps/<name>/` follows the same
three-file pattern: `app.yaml` (ArgoCD `Application`, `source.path` →
local `chart/`, `helm.valueFiles: [../values/values.yaml]`,
`syncPolicy.automated: {prune: true, selfHeal: true}`, `syncOptions:
[CreateNamespace=true]`; Traefik gets `sync-wave: "0"`), `chart/`
(vendored via `helm pull --untar`), `values/values.yaml`. `ingress-routes`
is a plain-manifest app instead — see below.

`bootstrap/root-app.yaml` is the app-of-apps root: source = `argocd-apps/`
(`directory.recurse: true`, `include: "*/app.yaml"` — an allowlist; a glob
`exclude` for the vendored `chart/` trees proved unreliable in practice),
`syncPolicy.automated` with `selfHeal`. Every child (including
`ingress-routes`) follows the same `<app>/app.yaml` shape, so root's own
sync is always just `Application` objects — never a raw CRD-dependent
resource, which matters (see below).

## Component choices

| App | Chart | Notes |
|---|---|---|
| Traefik | `traefik/traefik` | `NodePort`, explicit `nodePort: 30080`; sync-wave 0 |
| Prometheus | `prometheus-community/prometheus` | server-only |
| Grafana | `grafana/grafana` | `serve_from_sub_path` for `/grafana`; Prometheus + Loki datasources |
| Loki | `grafana/loki` | single-binary, filesystem storage |
| Jaeger | `jaegertracing/jaeger` | all-in-one, in-memory; `--query.base-path=/jaeger` |
| OTel Collector | `open-telemetry/opentelemetry-collector` | Deployment mode, OTLP fan-out |

`argocd-apps/ingress-routes/routes.yaml` holds one Traefik `IngressRoute`
per UI, each declared in its target's own namespace — avoids the
cross-namespace backend restriction a plain `networking.k8s.io/v1 Ingress`
would hit. `ingress-routes` is its **own** child Application, separate
from root's direct manifest inclusion: its CRs depend on CRDs the
`traefik` Application installs, and ArgoCD validates a sync's entire
manifest set up front — bundling them into root's own sync made root fail
resource discovery for the whole operation before `traefik` ever synced.
As an independent Application it just retries on its own automated-sync
cycle until those CRDs exist.

## Cilium bootstrap detail

`kind-config.yaml`: `networking.disableDefaultCNI: true`,
`networking.kubeProxyMode: "none"`.

`scripts/cilium-api-endpoint.sh` resolves the real in-cluster API server
address via `kubectl get endpoints kubernetes -n default` (works before any
CNI is installed).

## Makefile targets

```
make cluster / cilium / argocd / bootstrap / all / urls / destroy
```

## Verification

1. `make cluster` → `kubectl get nodes` shows 3 nodes, `NotReady`.
2. `make cilium` → all `Ready`; `kubectl -n kube-system get ds kube-proxy` → not found.
3. `make argocd` → `kubectl -n argocd get pods` all `Running`.
4. `make bootstrap` → `root` + all six child apps eventually `Synced`/`Healthy`.
5. `make urls`, then curl each path → HTTP 200.
6. GitOps loop: edit a `values.yaml`, push to `main`, confirm auto-sync with
   no manual `kubectl`/`argocd` command.
