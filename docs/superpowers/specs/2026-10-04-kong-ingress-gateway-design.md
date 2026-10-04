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
  just to gate it would be scope creep. Two representative plugins
  instead: `rate-limiting` on the Prometheus route, and a global
  `prometheus` plugin for gateway metrics.
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

<svg viewBox="0 0 920 620" xmlns="http://www.w3.org/2000/svg" font-family="-apple-system, Helvetica, Arial, sans-serif">
  <defs>
    <marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
      <path d="M0,0 L10,5 L0,10 z" fill="#333"/>
    </marker>
    <marker id="arrow-dashed" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
      <path d="M0,0 L10,5 L0,10 z" fill="#888"/>
    </marker>
  </defs>

  <!-- Client -->
  <rect x="380" y="10" width="160" height="40" rx="6" fill="#eef2ff" stroke="#4453a8"/>
  <text x="460" y="35" text-anchor="middle" font-size="14" fill="#1a1a2e">Client (browser/curl)</text>

  <!-- Kong Gateway pod -->
  <rect x="210" y="90" width="500" height="120" rx="8" fill="#fff7ed" stroke="#c2660f" stroke-width="1.5"/>
  <text x="460" y="112" text-anchor="middle" font-size="13" font-weight="bold" fill="#7a3a0c">Kong Gateway (DB-less, namespace: kong)</text>

  <rect x="230" y="130" width="220" height="60" rx="6" fill="#ffffff" stroke="#c2660f"/>
  <text x="340" y="153" text-anchor="middle" font-size="12" fill="#1a1a2e">proxy :8000</text>
  <text x="340" y="171" text-anchor="middle" font-size="11" fill="#555">NodePort 30080</text>

  <rect x="470" y="130" width="220" height="60" rx="6" fill="#ffffff" stroke="#c2660f"/>
  <text x="580" y="153" text-anchor="middle" font-size="12" fill="#1a1a2e">admin + manager :8002</text>
  <text x="580" y="171" text-anchor="middle" font-size="11" fill="#555">NodePort 30002</text>

  <line x1="460" y1="50" x2="460" y2="90" stroke="#333" stroke-width="1.5" marker-end="url(#arrow)"/>

  <!-- Backends row -->
  <g font-size="12">
    <rect x="30" y="290" width="140" height="56" rx="6" fill="#ecfdf5" stroke="#15803d"/>
    <text x="100" y="313" text-anchor="middle" fill="#14532d">grafana</text>
    <text x="100" y="330" text-anchor="middle" font-size="10" fill="#555">strip-path: false</text>

    <rect x="190" y="290" width="150" height="56" rx="6" fill="#ecfdf5" stroke="#15803d"/>
    <text x="265" y="309" text-anchor="middle" fill="#14532d">prometheus-server</text>
    <text x="265" y="324" text-anchor="middle" font-size="10" fill="#555">strip-path: false</text>
    <text x="265" y="338" text-anchor="middle" font-size="10" fill="#b45309">+ rate-limiting (60/min)</text>

    <rect x="360" y="290" width="130" height="56" rx="6" fill="#ecfdf5" stroke="#15803d"/>
    <text x="425" y="313" text-anchor="middle" fill="#14532d">jaeger</text>
    <text x="425" y="330" text-anchor="middle" font-size="10" fill="#555">strip-path: false</text>

    <rect x="510" y="290" width="130" height="56" rx="6" fill="#eef2ff" stroke="#4453a8"/>
    <text x="575" y="313" text-anchor="middle" fill="#1a1a2e">argocd-server</text>
    <text x="575" y="330" text-anchor="middle" font-size="10" fill="#555">strip-path: false</text>

    <rect x="660" y="290" width="140" height="56" rx="6" fill="#fef2f2" stroke="#b91c1c"/>
    <text x="730" y="313" text-anchor="middle" fill="#7f1d1d">hubble-ui</text>
    <text x="730" y="330" text-anchor="middle" font-size="10" fill="#555">strip-path: true</text>
  </g>

  <!-- arrows proxy -> backends -->
  <line x1="340" y1="190" x2="100" y2="290" stroke="#333" stroke-width="1.3" marker-end="url(#arrow)"/>
  <line x1="340" y1="190" x2="265" y2="290" stroke="#333" stroke-width="1.3" marker-end="url(#arrow)"/>
  <line x1="340" y1="190" x2="425" y2="290" stroke="#333" stroke-width="1.3" marker-end="url(#arrow)"/>
  <line x1="340" y1="190" x2="575" y2="290" stroke="#333" stroke-width="1.3" marker-end="url(#arrow)"/>
  <line x1="340" y1="190" x2="730" y2="290" stroke="#333" stroke-width="1.3" marker-end="url(#arrow)"/>

  <!-- Kong Manager UI -->
  <rect x="490" y="400" width="180" height="50" rx="6" fill="#fff7ed" stroke="#c2660f"/>
  <text x="580" y="422" text-anchor="middle" font-size="12" fill="#7a3a0c">Kong Manager UI</text>
  <text x="580" y="438" text-anchor="middle" font-size="10" fill="#555">read-only (DB-less)</text>
  <line x1="580" y1="190" x2="580" y2="400" stroke="#333" stroke-width="1.3" marker-end="url(#arrow)"/>

  <!-- metrics flow -->
  <rect x="190" y="470" width="150" height="50" rx="6" fill="#ecfdf5" stroke="#15803d" stroke-dasharray="0"/>
  <text x="265" y="500" text-anchor="middle" font-size="12" fill="#14532d">Prometheus</text>
  <path d="M460,210 C460,320 350,400 265,470" fill="none" stroke="#888" stroke-width="1.3" stroke-dasharray="5,4" marker-end="url(#arrow-dashed)"/>
  <text x="330" y="420" font-size="10" fill="#888">prometheus plugin (global, scraped)</text>

  <rect x="30" y="560" width="150" height="50" rx="6" fill="#faf5ff" stroke="#7e22ce"/>
  <text x="105" y="590" text-anchor="middle" font-size="12" fill="#581c87">Grafana</text>
  <path d="M265,520 C265,560 180,560 150,560" fill="none" stroke="#888" stroke-width="1.3" stroke-dasharray="5,4" marker-end="url(#arrow-dashed)"/>
  <text x="140" y="545" font-size="10" fill="#888">Kong traffic dashboard</text>
</svg>

Solid arrows are proxied HTTP requests; dashed arrows are the metrics
scrape/visualization path. Every backend box keeps living in its own
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

## Out of scope

- No new sample API workload (explicit earlier decision stands).
- No TLS/HTTPS termination changes — still plain HTTP on the NodePort,
  matching the existing POC posture.
- No Kong Enterprise features (RBAC, workspaces, vitals) — OSS only.
