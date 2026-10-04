# jev — K8s Observability GitOps POC

A local Kubernetes observability POC: a 3-node **Kind** cluster running
**Cilium** as CNI (full kube-proxy replacement + Hubble), with **ArgoCD**
installed once by hand and then taking over the rest via the **app-of-apps**
pattern. After the one-time bootstrap, any commit to `argocd-apps/` in this
repo is picked up and reconciled automatically — no manual `kubectl apply`
needed again.

## Stack

| Component | Role |
|---|---|
| Kind + Cilium | 3-node cluster (1 control-plane + 2 workers), Cilium CNI with full kube-proxy replacement, Hubble UI/Relay |
| ArgoCD | GitOps reconciler — app-of-apps over `argocd-apps/` |
| Traefik | Ingress, path-based routing on a single NodePort |
| Prometheus | Metrics |
| Grafana | Dashboards (Prometheus + Loki datasources) |
| Loki | Logs (single-binary, filesystem storage) |
| Jaeger | Traces (in-memory storage) |
| OpenTelemetry Collector | OTLP ingestion, fans out to Prometheus/Jaeger/Loki |

### Data flow

<svg viewBox="0 0 560 330" xmlns="http://www.w3.org/2000/svg" font-family="-apple-system, Helvetica, Arial, sans-serif">
  <defs>
    <marker id="df-arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
      <path d="M0,0 L10,5 L0,10 z" fill="#333"/>
    </marker>
  </defs>
  <rect x="170" y="10" width="220" height="36" rx="6" fill="#eef2ff" stroke="#4453a8"/>
  <text x="280" y="33" text-anchor="middle" font-size="13" fill="#1a1a2e">App (OTLP :4317/4318)</text>
  <rect x="150" y="90" width="260" height="36" rx="6" fill="#fff7ed" stroke="#c2660f"/>
  <text x="280" y="113" text-anchor="middle" font-size="13" fill="#7a3a0c">OTel Collector (Deployment)</text>
  <rect x="40" y="180" width="150" height="40" rx="6" fill="#ecfdf5" stroke="#15803d"/>
  <text x="115" y="204" text-anchor="middle" font-size="13" fill="#14532d">Prometheus</text>
  <rect x="205" y="180" width="150" height="40" rx="6" fill="#ecfdf5" stroke="#15803d"/>
  <text x="280" y="204" text-anchor="middle" font-size="13" fill="#14532d">Jaeger</text>
  <rect x="370" y="180" width="150" height="40" rx="6" fill="#ecfdf5" stroke="#15803d"/>
  <text x="445" y="204" text-anchor="middle" font-size="13" fill="#14532d">Loki</text>
  <rect x="205" y="270" width="150" height="40" rx="6" fill="#faf5ff" stroke="#7e22ce"/>
  <text x="280" y="294" text-anchor="middle" font-size="13" fill="#581c87">Grafana</text>
  <line x1="280" y1="46" x2="280" y2="90" stroke="#333" stroke-width="1.5" marker-end="url(#df-arrow)"/>
  <line x1="280" y1="126" x2="115" y2="180" stroke="#333" stroke-width="1.3" marker-end="url(#df-arrow)"/>
  <line x1="280" y1="126" x2="280" y2="180" stroke="#333" stroke-width="1.3" marker-end="url(#df-arrow)"/>
  <line x1="280" y1="126" x2="445" y2="180" stroke="#333" stroke-width="1.3" marker-end="url(#df-arrow)"/>
  <line x1="115" y1="220" x2="280" y2="270" stroke="#333" stroke-width="1.3" marker-end="url(#df-arrow)"/>
  <line x1="280" y1="220" x2="280" y2="270" stroke="#333" stroke-width="1.3" marker-end="url(#df-arrow)"/>
  <line x1="445" y1="220" x2="280" y2="270" stroke="#333" stroke-width="1.3" marker-end="url(#df-arrow)"/>
</svg>

## Why Cilium comes before ArgoCD

Cilium is the CNI — `kind-config.yaml` sets `disableDefaultCNI: true` and
`kubeProxyMode: none`, so nodes stay `NotReady` and no pod (including
ArgoCD's own) gets an IP until it's installed. Bootstrap order is strict:

```
1. kind create cluster   (CNI + kube-proxy disabled)
2. helm install cilium   (pod networking comes up)
3. helm install argocd   (argocd pods can now schedule)
4. kubectl apply bootstrap/root-app.yaml   (one-time; ArgoCD owns the rest)
```

## Quick start

Requires **Podman** (rootless, socket running) — see `.envrc`. Also needs
`kind`, `kubectl`, `helm`, `gh`.

```bash
source .envrc
make all      # cluster -> cilium -> argocd -> bootstrap
make urls     # print the node IP + path map once everything is up
```

Or step by step: `make cluster`, `make cilium`, `make argocd`,
`make bootstrap`. See `.claude/skills/deploy/SKILL.md` for a guided version
with pre-flight checks.

## Access the UIs

Ingress is plain `NodePort` (no `extraPortMappings`) — reached via the
node's container IP, not `localhost`. Run `make urls` for the exact URLs;
they follow this shape:

| UI | Path |
|---|---|
| Grafana | `/grafana` (admin / admin123) |
| Prometheus | `/prometheus` |
| Jaeger | `/jaeger` |
| ArgoCD | `/argocd` (admin / `kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' \| base64 -d`) |
| Traefik dashboard | `/traefik` (redirects to `/dashboard/`) |
| Hubble UI | `/hubble` |

## Repo layout

```
.
├── kind-config.yaml           # 3-node cluster, Cilium CNI, no kube-proxy
├── scripts/cilium-api-endpoint.sh
├── bootstrap/root-app.yaml    # the one manual apply — app-of-apps root
└── argocd-apps/
    ├── traefik/ prometheus/ grafana/ loki/ jaeger/ opentelemetry-collector/
    │   each: app.yaml (ArgoCD Application) + chart/ (vendored Helm chart)
    │   + values/values.yaml
    └── ingress-routes/        # a separate child Application (see CLAUDE.md
        ├── app.yaml           # for why) — Traefik IngressRoute per UI
        └── routes.yaml
```

Every chart under `argocd-apps/<app>/chart/` is vendored locally (`helm
pull --version <v> --untar`) — see `.claude/skills/helm-vendor/SKILL.md` to
add or update one.

## GitOps loop

Once bootstrapped, changes flow with no manual step:

```bash
# e.g. bump a Grafana resource limit
vim argocd-apps/grafana/values/values.yaml
git commit -am "grafana: bump memory limit"
git push
# ArgoCD picks it up on its next poll — no kubectl/argocd command needed
```

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| All nodes `NotReady` right after `make cluster` | Expected — Cilium isn't installed yet |
| Cilium agent `CrashLoopBackOff`, apiserver connection errors | Wrong `k8sServiceHost`/`k8sServicePort` — re-run `scripts/cilium-api-endpoint.sh` |
| Cilium agent `Init:CrashLoopBackOff`, `mount-bpf-fs` logs `permission denied` | Rootless Podman can't do the `mount -t bpf` syscall itself — already worked around via `kind-config.yaml`'s `extraMounts` (bind-mounts the host's bpffs) + `bpf.autoMount.enabled=false` in the `cilium` Makefile target |
| `root` Application shows raw chart files as resources | `bootstrap/root-app.yaml`'s `directory.include` allowlist isn't matching a new file you added |
| `/grafana` 404s or loads with broken CSS | `IngressRoute` not synced yet, or `serve_from_sub_path`/`root_url` mismatch |
| `/jaeger` or `/argocd` broken paths | Their `base_path`/`rootpath` config must match the IngressRoute's un-stripped prefix (see `argocd-apps/ingress-routes/routes.yaml`'s comments) |

For a guided diagnosis, use the `k8s-troubleshooter` subagent
(`.claude/agents/k8s-troubleshooter.md`).

## Production considerations

This is a **POC**, not a production setup:
- Jaeger storage is in-memory — traces are lost on restart
- Loki uses filesystem storage, not object storage
- Prometheus retention is short (6h) with no long-term storage
- No TLS, no NetworkPolicies, single replica everywhere
