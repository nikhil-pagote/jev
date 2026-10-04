# Kong as Ingress + API Gateway — Design

## Context

This repo currently uses Traefik as the sole ingress for every UI
(Grafana, Prometheus, Jaeger, ArgoCD, Hubble UI), routed path-based off a
single `NodePort` (`30080`). The ask: replace Traefik with **Kong** as
both the ingress controller and API gateway, and use the swap as an
opportunity to actually exercise Kong's gateway features (plugins), not
just re-point the same path-based routing at a different controller.

Why now: no functional gap in Traefik drove this — it's a deliberate
technology swap to add API-gateway capabilities (rate limiting, traffic
metrics) that Traefik's OSS tier doesn't emphasize the same way, and to
learn Kong's Kubernetes-native operating model as part of this POC.

## Decisions

- **Full replacement**, not side-by-side. One ingress layer to reason
  about; matches "use Kong as ingress and API gateway" literally.
- **DB-less mode** (`env.database: "off"`) — no Postgres. Matches this
  repo's existing "no extra datastore where avoidable" pattern (Loki
  filesystem, Jaeger in-memory) and keeps Kong's config fully
  Kubernetes-native: it comes from `Ingress`/`KongPlugin`/
  `KongClusterPlugin` objects via the bundled Ingress Controller, not
  Admin API writes.
- **API-gateway demo on existing routes**, not a new workload. This repo
  deliberately has no sample API (platform/stack only); inventing one
  just to gate it would be scope creep. Three representative plugins
  instead: `rate-limiting` on the Prometheus route, a global
  `prometheus` plugin for gateway metrics, and a global `opentelemetry`
  plugin so Kong's own gateway-hop spans flow into Jaeger through the
  same OTel Collector path every other trace already uses — Kong
  doesn't replace Jaeger (gateway vs. trace-storage are different
  jobs), it becomes another span source feeding it.
- **Dashboard: Kong Manager OSS + Grafana**, not Konga. Kong Manager was
  open-sourced and bundled into Kong Gateway 3.4+ (`admin_gui_listen`,
  default port `8002`) — confirmed via Kong's own
  [`kong-manager`](https://github.com/Kong/kong-manager) repo and
  [announcement](https://konghq.com/blog/product-releases/kong-manager-open-source).
  It gives config browsing (services/routes/plugins/consumers); Grafana
  (already running) gives traffic metrics via the `prometheus` plugin.
  Together they cover what Kong Enterprise's dashboard shows in one
  pane. Konga was considered and rejected — unmaintained since ~2021,
  with no real advantage over Kong's own now-free tool.
- **Traefik's `/traefik` dashboard has no replacement.** It goes away
  with nothing standing in for it — Kong Manager replaces its *purpose*
  (inspecting the gateway) but not its route; there's no "Kong dashboard
  behind Kong's own proxy" path being added.
- **The live `traefik` ArgoCD Application gets properly decommissioned**,
  not just deleted from git. It's currently `Synced`/`Healthy` in the
  running cluster; removing its `app.yaml` from git without first
  cascade-deleting it would orphan its rendered resources (Deployment,
  Service, the `traefik` namespace) rather than clean them up.

## Architecture

![Kong ingress + API gateway architecture: client through Kong proxy to each UI backend, Kong Manager for config, Prometheus/Grafana for Kong traffic metrics, and Kong traces flowing through the OTel Collector into Jaeger](docs/diagrams/kong-ingress-architecture.svg)

Solid arrows are proxied HTTP requests; dashed arrows are the telemetry
(metrics/trace) paths. Every backend box keeps living in its own
namespace (`observability`, `argocd`, `kube-system`) — Kong's `Ingress`
objects avoid the cross-namespace-backend restriction the same way the
Traefik `IngressRoute`s did, by being declared alongside their target.

## Routing

`argocd-apps/ingress-routes/routes.yaml` keeps its path and name
(controller-agnostic), but its contents change from Traefik CRDs to:

- One plain `networking.k8s.io/v1 Ingress` per UI, each in its target's
  own namespace, `ingressClassName: kong`.
- `konghq.com/strip-path` annotation per route:
  - `"false"` for Grafana (`serve_from_sub_path`), Prometheus
    (`--web.route-prefix`), Jaeger (`base_path`), ArgoCD (`--rootpath`)
    — they already own their subpath, exactly the same reasoning that
    governed the Traefik `IngressRoute`s.
  - `"true"` for Hubble UI — a plain SPA with no subpath awareness.
- No Kong-equivalent replaces the old `/traefik` dashboard route.

## API-gateway plugins

- `KongPlugin` named `rate-limit-prometheus`, plugin `rate-limiting`,
  `config.minute: 60`, `config.policy: local`, attached to the
  Prometheus `Ingress` via the `konghq.com/plugins` annotation.
- `KongClusterPlugin` named `prometheus`, plugin `prometheus`, no
  `config` overrides needed (defaults expose `/metrics` on the status
  listener `:8100`) — global, applies gateway-wide.
- `KongClusterPlugin` named `opentelemetry`, plugin `opentelemetry`,
  `config.endpoint:
  "http://opentelemetry-collector.observability.svc.cluster.local:4318/v1/traces"`
  (OTLP/HTTP — the plugin doesn't speak gRPC) — global, every request
  through the gateway gets a span. These land in Jaeger through the
  exact same OTel Collector pipeline the (currently nonexistent) sample
  app would use, so there's no new ingestion path to build.
- The existing Prometheus gets a new scrape target for Kong's `:8100`
  metrics endpoint; a community Kong Grafana dashboard gets imported
  for traffic visualization (requests, latency, status codes).

## Kong deployment

- Chart: `kong/kong` (from `https://charts.konghq.com`), vendored into
  `argocd-apps/kong/chart/` via `helm pull --untar`, same pattern as
  every other app in this repo.
- `env.database: "off"`, `ingressController.enabled: true`.
- Proxy `Service`: `type: NodePort`, explicit `nodePort: 30080` on the
  proxy port — unchanged from Traefik, so `make urls` and existing
  muscle memory keep working.
- Admin/Manager exposure: a second explicit `nodePort` (`30002`) on the
  same `Service`, mapped to container port `8002`
  (`admin_gui_listen`/admin API). **Needs verification at implementation
  time**: the `kong/kong` chart's README still documents the pre-OSS,
  enterprise-gated `manager.*`/`enterprise.enabled` values block, which
  may or may not reflect how the *current* chart version exposes the
  now-bundled-in-OSS Kong Manager. The implementation plan should
  include a quick check of the chart's actual `values.yaml` (not just
  its README) before committing to exact key names.
- Namespace `kong` replaces `traefik`.

## Decommissioning Traefik

Before (or as part of) applying the Kong changes:

1. Add the foreground-cascade finalizer to the live `traefik`
   Application so deleting it also deletes what it rendered:
   `kubectl -n argocd patch application traefik --type merge -p '{"metadata":{"finalizers":["resources-finalizer.argocd.argoproj.io"]}}'`
2. `kubectl -n argocd delete application traefik` and confirm the
   `traefik` namespace and its resources are actually gone
   (`kubectl get all -n traefik` → empty/`NotFound`).
3. Remove `argocd-apps/traefik/` from git, replace with
   `argocd-apps/kong/` following the same `app.yaml` +
   `chart/` + `values/values.yaml` pattern as the other Helm-backed apps.

## Testing / verification

1. `kubectl get applications -n argocd` — `kong` and `ingress-routes`
   both `Synced`/`Healthy`; `traefik` no longer listed.
2. `kubectl get nodes` and existing apps (`grafana`, `prometheus`,
   `jaeger`, `loki`, `opentelemetry-collector`) unaffected — this is an
   ingress-layer swap, nothing else should need to change.
3. Every UI path returns `200` through Kong's proxy on `30080`, same as
   the current Traefik verification did (`/grafana/login`,
   `/prometheus/query`, `/jaeger/`, `/argocd/`, `/hubble`).
4. Rate limit visibly triggers: hit `/prometheus` more than 60 times in
   a minute, confirm a `429` with Kong's rate-limit headers
   (`X-RateLimit-*`).
5. Kong Manager reachable on `30002`, shows the `Ingress`-derived
   services/routes/plugins read-only (write attempts should be rejected
   — DB-less).
6. Kong's `/metrics` (`:8100`) scraped by Prometheus; the imported
   Grafana dashboard shows non-zero request counts after generating a
   little traffic.
7. `kubectl get all -n traefik` returns nothing — confirms the live
   decommission actually happened, not just a git change.
8. After generating a little traffic, Jaeger (`/jaeger/`) shows a
   service named after Kong's `opentelemetry` plugin resource attributes
   with spans for the gateway hop — confirms Kong's traces are actually
   reaching Jaeger through the Collector, not just configured.

## Out of scope

- No new sample API workload (explicit earlier decision stands).
- No TLS/HTTPS termination changes — still plain HTTP on the NodePort,
  matching the existing POC posture.
- No Kong Enterprise features (RBAC, workspaces, vitals) — OSS only.
