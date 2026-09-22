# Intent

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
- **Charts vendored locally** (`argocd-apps/<app>/chart/`, pulled via
  `helm pull --untar`) rather than ArgoCD pointing at remote chart repos
  directly — mirrors the reference project's proven, reproducible pattern.

## What "done" looks like

See `.claude/plan.md` for the full plan and its verification checklist —
in short: `make all` brings up a working cluster where all six ArgoCD child
apps show `Synced`/`Healthy`, every UI path returns HTTP 200, and editing a
`values.yaml` + pushing to `main` is reflected in the cluster without any
manual `kubectl` command.

## Reference project

`github.com/nikhil-pagote/k8s_observebility` implements nearly the same
stack (minus Cilium) and was used as a pattern reference for Application
CRD shape, chart-vendoring layout, and sync-wave use — not cloned or
depended on.
