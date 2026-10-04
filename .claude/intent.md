# Intent

> **Superseded in part** — this is the original design intent and is kept
> as a historical record. Two decisions below have since changed:
> 1. **Ingress**: Traefik → **Kong** (ingress + API gateway). See
>    `docs/superpowers/specs/2026-10-04-kong-ingress-gateway-design.md`
>    for the full rationale.
> 2. **Podman**: rootless → **rootful** (`sudo`) for cluster lifecycle —
>    Cilium's eBPF needs real host capabilities rootless Podman's
>    userns can't grant. See `CLAUDE.md`'s "Container runtime" section.

## What this is

A local POC: a 3-node Kind cluster running Cilium as CNI, with ArgoCD
installed once by hand and then taking over the rest via the **app-of-apps**
pattern — after the one-time bootstrap, any commit to `argocd-apps/` in this
repo is picked up and reconciled automatically. The GitOps-managed stack is
Traefik (ingress), Prometheus, Grafana, Loki, Jaeger, and an OpenTelemetry
Collector.

## Why these choices

- **Podman, not Docker** — matches the established convention from the
  reference project (`k8s_observebility`); kept even though this is a fresh,
  separate build.
- **Plain NodePort, no `extraPortMappings`** — you explicitly rejected the
  MetalLB / hostPort-mapping convenience; access is via the node's container
  IP + a stable explicit NodePort (`30080`), not `localhost`.
- **Path-based routing on one Traefik entrypoint** (`/grafana`,
  `/prometheus`, `/jaeger`, `/argocd`, `/hubble`) rather than per-app
  hostnames — one port to remember, no `/etc/hosts` editing.
- **Cilium with full kube-proxy replacement + Hubble UI/Relay** — you chose
  the deeper setup over the minimal "CNI only, keep kube-proxy" option,
  since this whole POC is about observability and Hubble fits that theme.
- **Cilium is a manual bootstrap step, not an ArgoCD-managed app** — it's
  the CNI; nodes stay `NotReady` and no pod (including ArgoCD's own) gets
  an IP until it's installed. Bootstrap order is strict: cluster → Cilium →
  ArgoCD → one-time `root` Application apply.
- **True app-of-apps (self-managing root Application with
  `directory.recurse`)**, not a manually re-applied Kustomize list — you
  said explicitly that changes committed to the repo should deploy
  automatically, which requires ArgoCD to own the reconciliation of the
  `argocd-apps/` tree itself, not just the workloads inside it.
- **No sample workload** — platform/stack only, tightest scope for this POC.
  (Superseded — see "Planned additions" below: FastAPI/Axum/FastMCP apps
  are coming later.)
- **Charts vendored locally** (`argocd-apps/<app>/chart/`, pulled via
  `helm pull --untar`) rather than ArgoCD pointing at remote chart repos
  directly — mirrors the reference project's proven, reproducible pattern.

## What "done" looks like

See `.claude/plan.md` for the full plan and its verification checklist —
in short: `make all` brings up a working cluster where all six ArgoCD child
apps show `Synced`/`Healthy`, every UI path returns HTTP 200, and editing a
`values.yaml` + pushing to `main` is reflected in the cluster without any
manual `kubectl` command.

## Planned additions (not yet built)

- **Sample apps**: FastAPI, Axum, and FastMCP services, added later —
  this reverses the original "no sample workload" decision above, once
  there's a concrete reason to (gating real APIs through Kong, giving
  Jaeger/Prometheus/Loki real traffic to show, and giving an MCP server
  something to call).
- **Langfuse (full v3)** for LLM-specific observability (prompts,
  completions, token/cost tracking) — complements Jaeger, doesn't
  replace it (see the Langfuse-vs-Jaeger discussion this project had:
  Jaeger is general distributed tracing, Langfuse is LLM-call-specific).
  Decided to go with the real, current, production-shaped architecture
  (Postgres + ClickHouse + Redis + MinIO via the `langfuse/langfuse-k8s`
  Helm chart) rather than the lighter, Postgres-only Langfuse v2 — a
  deliberate exception to this project's usual "avoid extra datastores"
  pattern (DB-less Kong, filesystem Loki, in-memory Jaeger), made
  knowingly given the real resource cost (~7+ CPU / 17+ GiB just for
  Langfuse's backing stores) and extra cluster-wide prerequisites
  (cert-manager + the ClickHouse Kubernetes Operator, installed once,
  before `helm install`).
- **Timing — deliberately deferred**: Langfuse goes in alongside
  whichever of FastAPI/Axum/FastMCP lands first, not before. Same
  reasoning the original "no sample workload" decision used — no point
  standing up an LLM observability backend with nothing yet sending it
  traces.

## Reference project

`github.com/nikhil-pagote/k8s_observebility` implements nearly the same
stack (minus Cilium) and was used as a pattern reference for Application
CRD shape, chart-vendoring layout, and sync-wave use — not cloned or
depended on.
