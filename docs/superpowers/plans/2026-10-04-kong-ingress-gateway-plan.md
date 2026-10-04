# Kong Ingress + API Gateway Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Traefik with Kong as the sole ingress controller + API
gateway for the `jev` cluster, DB-less, with a rate-limiting plugin, a
global metrics plugin feeding Prometheus/Grafana, and a global tracing
plugin feeding Jaeger — matching the approved design spec exactly.

**Architecture:** Kong (`kong/kong` Helm chart, vendored like every other
app in this repo) deploys as its own ArgoCD child Application
(`argocd-apps/kong/`), DB-less, with its Ingress Controller enabled by
default. A separate `ingress-routes` child Application
(`argocd-apps/ingress-routes/`, already exists, unchanged) owns the plain
`networking.k8s.io/v1 Ingress` objects (one per UI) plus `KongPlugin`/
`KongClusterPlugin` CRs — kept separate from `kong` itself because those
CRs depend on CRDs the `kong` Application installs, and ArgoCD validates
an entire sync's manifest set up front (see `CLAUDE.md`).

**Tech Stack:** Kong Gateway 3.9 (OSS, DB-less), Kong Ingress Controller
3.5 (bundled), Helm, ArgoCD, Kubernetes `Ingress`/`KongPlugin`/
`KongClusterPlugin` CRDs.

**Spec:** `docs/superpowers/specs/2026-10-04-kong-ingress-gateway-design.md`

## Global Constraints

- Chart: `kong/kong` version `3.4.1` (app_version `3.9`) from
  `https://charts.konghq.com` — verified via `helm search repo kong/kong`
  on 2026-10-04; re-check with the same command if this plan is executed
  much later, and update the version below if a newer one exists.
- DB-less: `env.database: "off"` — this is the chart's own default, do
  not override it to anything else.
- Proxy NodePort: `30080` (unchanged from the old Traefik setup).
- Kong Manager/Admin NodePorts: `30002` (manager UI), `30001` (Admin API)
  — two separate ports; the chart does not combine them.
- No TLS anywhere (`proxy.tls.enabled`, `admin.tls.enabled`,
  `manager.tls.enabled` all `false`) — matches this POC's existing
  plain-HTTP posture.
- Every backend Service/port used below (`grafana:80`,
  `prometheus-server:80`, `jaeger:16686`, `argocd-server:80`,
  `hubble-ui:80`) was already empirically verified working with these
  exact ports under the previous Traefik setup — not guesses.
- `argocd-apps/ingress-routes/app.yaml` and `bootstrap/root-app.yaml`
  already reference Kong correctly (updated in a previous session) — do
  **not** modify either file as part of this plan.

---

### Task 1: Vendor and configure the Kong Application

**Files:**
- Create: `argocd-apps/kong/chart/` (vendored chart, many files from `helm pull`)
- Create: `argocd-apps/kong/values/values.yaml`
- Create: `argocd-apps/kong/app.yaml`

**Interfaces:**
- Produces: Kong proxy reachable at NodePort `30080` with
  `ingressClassName: kong` honored; Kong Admin API at NodePort `30001`;
  Kong Manager UI at NodePort `30002`; Kong's `/metrics`-equivalent
  status endpoint on container port `8100`, discoverable by Prometheus
  via `prometheus.io/scrape`/`prometheus.io/port` pod annotations (same
  pattern already used for `opentelemetry-collector` in this repo).
- Consumes: nothing from other tasks (this is the foundation).

- [ ] **Step 1: Vendor the chart**

```bash
cd /home/nikhil/Documents/jev
helm repo add kong https://charts.konghq.com --force-update
helm repo update kong
helm search repo kong/kong -o yaml | head -5
# Confirm it reports version: 3.4.1 (app_version "3.9"). If a newer
# version is now available, use that version consistently through the
# rest of this step instead.
mkdir -p argocd-apps/kong/values
helm pull kong/kong --version 3.4.1 --untar --untardir argocd-apps/kong
mv argocd-apps/kong/kong argocd-apps/kong/chart
ls argocd-apps/kong/chart/Chart.yaml argocd-apps/kong/chart/values.yaml
```

- [ ] **Step 2: Write `argocd-apps/kong/values/values.yaml`**

```yaml
# DB-less (env.database: "off" is already this chart's own default —
# listed here only for clarity, not to override anything). Kong's own
# Helm automation for admin_gui_listen is still gated behind the legacy
# `enterprise.enabled` flag even though Kong Gateway 3.9 itself supports
# OSS Kong Manager natively (verified by reading
# templates/_helpers.tpl in the vendored chart) — so it's set directly
# here instead of via enterprise.enabled, which would pull in unrelated
# enterprise-only templating we don't want or have a license for.
env:
  database: "off"
  admin_gui_listen: "0.0.0.0:8002"

ingressController:
  enabled: true

proxy:
  type: NodePort
  http:
    nodePort: 30080
  tls:
    enabled: false

admin:
  enabled: true
  http:
    enabled: true
    nodePort: 30001
  tls:
    enabled: false

manager:
  http:
    nodePort: 30002
  tls:
    enabled: false

# Developer Portal — unused, don't stand up its NodePort Service.
portal:
  enabled: false

# Picked up by the Prometheus chart's default kubernetes-pods scrape
# job (confirmed in argocd-apps/prometheus/chart/values.yaml) — same
# pattern already used for the OTel Collector in this repo. Kong's
# status listener (container port 8100) is always on by default.
podAnnotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8100"
```

- [ ] **Step 3: Write `argocd-apps/kong/app.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kong
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
  labels:
    app.kubernetes.io/part-of: jev-observability-stack
spec:
  project: default
  source:
    repoURL: https://github.com/nikhil-pagote/jev.git
    targetRevision: HEAD
    path: argocd-apps/kong/chart
    helm:
      valueFiles:
        - ../values/values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: kong
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 4: Verify the chart renders cleanly with our values (offline, no cluster needed)**

```bash
helm template kong argocd-apps/kong/chart -f argocd-apps/kong/values/values.yaml -n kong \
  | grep -E "^kind: (Deployment|Service)" | sort | uniq -c
```

Expected: at least one `Deployment` and three `Service` lines (proxy,
admin, manager — portal disabled so no fourth). If this errors, the
values.yaml has a key the chart doesn't recognize — fix before
continuing.

- [ ] **Step 5: Validate YAML syntax of the new files**

```bash
python3 -c "
import yaml
yaml.safe_load(open('argocd-apps/kong/app.yaml'))
yaml.safe_load(open('argocd-apps/kong/values/values.yaml'))
print('OK')
"
```

Expected: `OK`.

- [ ] **Step 6: Commit**

```bash
git add argocd-apps/kong/
git commit -m "Add Kong as the ingress + API gateway Application

DB-less, proxy on NodePort 30080 (unchanged from Traefik), Admin API
on 30001, Kong Manager on 30002. admin_gui_listen set manually since
the chart's own automation for it is still gated behind the legacy
enterprise.enabled flag."
git push
```

---

### Task 2: Write the Kong-routed ingress manifests

**Files:**
- Modify: `argocd-apps/ingress-routes/routes.yaml` (currently deleted —
  this task recreates it)

**Interfaces:**
- Consumes: Kong's `ingressClassName: kong` (from Task 1); backend
  Service names/ports listed in Global Constraints above.
- Produces: `/grafana`, `/prometheus`, `/jaeger`, `/argocd`, `/hubble`
  all routable through Kong; `rate-limit-prometheus` `KongPlugin`
  (60/min) attached to the Prometheus route; global `prometheus` and
  `opentelemetry` `KongClusterPlugin`s applied gateway-wide.

- [ ] **Step 1: Write `argocd-apps/ingress-routes/routes.yaml`**

```yaml
# One plain networking.k8s.io/v1 Ingress per UI, each in its target's
# own namespace — an Ingress's backend Service must live in the same
# namespace as the Ingress object itself, so this avoids any
# cross-namespace question entirely. All routed through Kong's single
# proxy (NodePort 30080, ingressClassName: kong).
#
# konghq.com/strip-path: "false" for apps that already handle their own
# subpath (Grafana serve_from_sub_path, Prometheus --web.route-prefix,
# Jaeger base_path, ArgoCD --rootpath) — stripping would make them
# issue their own canonical-redirect using a statically configured host
# that isn't reachable (see CLAUDE.md "Key constraints"). Only Hubble UI
# (a plain SPA, no subpath awareness) gets "true".
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: observability
  annotations:
    konghq.com/strip-path: "false"
spec:
  ingressClassName: kong
  rules:
    - http:
        paths:
          - path: /grafana
            pathType: Prefix
            backend:
              service:
                name: grafana
                port:
                  number: 80
---
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata:
  name: rate-limit-prometheus
  namespace: observability
plugin: rate-limiting
config:
  minute: 60
  policy: local
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: prometheus
  namespace: observability
  annotations:
    konghq.com/strip-path: "false"
    konghq.com/plugins: rate-limit-prometheus
spec:
  ingressClassName: kong
  rules:
    - http:
        paths:
          - path: /prometheus
            pathType: Prefix
            backend:
              service:
                name: prometheus-server
                port:
                  number: 80
---
# Jaeger Query is configured with its own base_path: /jaeger (see
# argocd-apps/jaeger/values/values.yaml) — do NOT strip the prefix here.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: jaeger
  namespace: observability
  annotations:
    konghq.com/strip-path: "false"
spec:
  ingressClassName: kong
  rules:
    - http:
        paths:
          - path: /jaeger
            pathType: Prefix
            backend:
              service:
                name: jaeger
                port:
                  number: 16686
---
# ArgoCD server is started with --insecure --rootpath=/argocd (see the
# `argocd` Makefile target) — same reasoning as Jaeger: don't strip.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd
  namespace: argocd
  annotations:
    konghq.com/strip-path: "false"
spec:
  ingressClassName: kong
  rules:
    - http:
        paths:
          - path: /argocd
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hubble-ui
  namespace: kube-system
  annotations:
    konghq.com/strip-path: "true"
spec:
  ingressClassName: kong
  rules:
    - http:
        paths:
          - path: /hubble
            pathType: Prefix
            backend:
              service:
                name: hubble-ui
                port:
                  number: 80
---
# Global plugins need BOTH the "global" label AND the ingress-class
# annotation below to actually apply gateway-wide — the label alone is
# not sufficient (verified against Kong's own KongClusterPlugin
# behavior).
apiVersion: configuration.konghq.com/v1
kind: KongClusterPlugin
metadata:
  name: prometheus
  annotations:
    kubernetes.io/ingress.class: kong
  labels:
    global: "true"
plugin: prometheus
---
# Feeds Jaeger through the same OTel Collector pipeline every other
# trace already uses — Kong doesn't replace Jaeger, it becomes another
# span source. OTLP/HTTP only; this plugin doesn't speak gRPC.
apiVersion: configuration.konghq.com/v1
kind: KongClusterPlugin
metadata:
  name: opentelemetry
  annotations:
    kubernetes.io/ingress.class: kong
  labels:
    global: "true"
plugin: opentelemetry
config:
  endpoint: "http://opentelemetry-collector.observability.svc.cluster.local:4318/v1/traces"
```

- [ ] **Step 2: Validate YAML syntax (offline, no cluster needed)**

```bash
cd /home/nikhil/Documents/jev
python3 -c "
import yaml
docs = list(yaml.safe_load_all(open('argocd-apps/ingress-routes/routes.yaml')))
print(len(docs), 'docs')
for d in docs:
    print(d['kind'], d['metadata']['name'])
"
```

Expected: `8 docs`, listing (in order) `Ingress grafana`, `KongPlugin
rate-limit-prometheus`, `Ingress prometheus`, `Ingress jaeger`, `Ingress
argocd`, `Ingress hubble-ui`, `KongClusterPlugin prometheus`,
`KongClusterPlugin opentelemetry`.

- [ ] **Step 3: Commit**

```bash
git add argocd-apps/ingress-routes/routes.yaml
git commit -m "Add Kong Ingress/KongPlugin routing for all five UIs

Replaces the deleted Traefik IngressRoute/Middleware objects. Rate
limiting on Prometheus, global prometheus + opentelemetry plugins for
gateway metrics and tracing."
git push
```

---

### Task 3: Bring up a fresh cluster and verify core routing

**Files:** none (this task runs the stack, no new files)

**Interfaces:**
- Consumes: everything from Tasks 1 and 2.
- Produces: a running cluster to verify against in Task 4.

- [ ] **Step 1: Check for and clean up any stale cluster**

```bash
kind get clusters 2>&1
# If "jev" is listed: sudo KIND_EXPERIMENTAL_PROVIDER=podman kind delete cluster --name jev
```

- [ ] **Step 2: Bring up the full stack**

```bash
cd /home/nikhil/Documents/jev
make cluster   # expect: 3 nodes, NotReady (no CNI yet — expected)
make cilium    # expect: all nodes Ready after this completes
make argocd    # expect: all argocd pods Running
make bootstrap # expect: "application.argoproj.io/root created"
```

If `make cilium` hits any `CrashLoopBackOff` mentioning bpf mount,
memlock, or bpffs permissions: the cluster wasn't created with `sudo`
(rootful Podman) — see `CLAUDE.md`'s "Container runtime" section. This
should not happen since `make cluster` already runs under `sudo`.

- [ ] **Step 3: Wait for all applications to sync, handle the root-app re-apply gotcha**

```bash
sleep 20
kubectl get applications -n argocd
```

Expected eventually: `root`, `kong`, `prometheus`, `grafana`, `loki`,
`jaeger`, `opentelemetry-collector`, `ingress-routes` — 8 Applications,
all `Synced`/`Healthy`. No `traefik`.

If `kong` or `ingress-routes` show `OutOfSync`/stuck retrying a stale
revision, clear it and let selfHeal retry:

```bash
kubectl -n argocd patch application kong --type merge -p '{"operation":null}'
kubectl -n argocd patch application ingress-routes --type merge -p '{"operation":null}'
```

- [ ] **Step 4: Verify the other apps are unaffected**

```bash
kubectl get pods -n observability
```

Expected: `grafana`, `prometheus-server` (and its sidecars),
`jaeger`, `loki-0` (and its sidecars), `opentelemetry-collector` all
`Running`/`2/2` or `1/1` as appropriate — same pods as before this
change, nothing about them should differ.

- [ ] **Step 5: Verify every UI path returns 200 through Kong**

`curl` is not installed on this host — use Python (same pattern used
throughout this project):

```bash
NODE_IP=$(kubectl get nodes jev-control-plane -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
echo "Node IP: $NODE_IP"
python3 - "$NODE_IP" <<'EOF'
import sys, urllib.request
node_ip = sys.argv[1]
paths = ["/grafana/login", "/prometheus/query", "/jaeger/", "/argocd/", "/hubble"]
for p in paths:
    url = f"http://{node_ip}:30080{p}"
    req = urllib.request.Request(url, headers={"Host": f"{node_ip}:30080"})
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            print(f"{p:20s} -> {r.status}")
    except Exception as e:
        print(f"{p:20s} -> ERROR {e}")
EOF
```

Expected: `200` for every path. If any path redirects to
`http://localhost:30080/...`, the Ingress is stripping a prefix for an
app that owns its own subpath — re-check `konghq.com/strip-path` on
that Ingress matches Task 2's content exactly.

- [ ] **Step 6: Verify the rate limit actually triggers**

```bash
python3 - "$NODE_IP" <<'EOF'
import sys, urllib.request
node_ip = sys.argv[1]
url = f"http://{node_ip}:30080/prometheus/query"
codes = []
for i in range(65):
    req = urllib.request.Request(url, headers={"Host": f"{node_ip}:30080"})
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            codes.append(r.status)
    except urllib.error.HTTPError as e:
        codes.append(e.code)
print("last 10 status codes:", codes[-10:])
print("got a 429:", 429 in codes)
EOF
```

Expected: `got a 429: True` (60/minute limit, 65 requests sent). If
`False`, confirm the `rate-limit-prometheus` `KongPlugin` actually
attached: `kubectl get kongplugin rate-limit-prometheus -n observability`
and check the `prometheus` `Ingress`'s `konghq.com/plugins` annotation
matches its name exactly.

- [ ] **Step 7: Commit the verification (no file changes expected, but confirm clean state)**

```bash
git status --short
# Expected: clean (nothing to commit) — this task only ran/verified
# infrastructure, Tasks 1-2 already committed the files.
```

---

### Task 4: Verify the observability integrations and decommission check

**Files:** none

**Interfaces:**
- Consumes: the running cluster from Task 3.

- [ ] **Step 1: Verify Kong Manager is reachable**

```bash
python3 - "$NODE_IP" <<'EOF'
import sys, urllib.request
node_ip = sys.argv[1]
url = f"http://{node_ip}:30002/"
req = urllib.request.Request(url, headers={"Host": f"{node_ip}:30002"})
try:
    with urllib.request.urlopen(req, timeout=5) as r:
        print("Kong Manager:", r.status)
except Exception as e:
    print("Kong Manager: ERROR", e)
EOF
```

Expected: `200`. **This is the one area the spec flagged as needing
verification** — if it fails or the page loads but can't reach the
Admin API (check the browser's network tab if testing manually, or
`kubectl logs -n kong deploy/kong -c proxy` for admin API connection
errors), the fix is to also set `env.admin_gui_api_url:
"http://<NODE_IP>:30001"` in `argocd-apps/kong/values/values.yaml`
(can't be hardcoded in advance — the node IP is dynamic), commit, push,
and let ArgoCD re-sync.

- [ ] **Step 2: Verify Kong's metrics reach Prometheus**

```bash
kubectl get pods -n kong -o jsonpath='{.items[0].metadata.annotations}'
# Confirm prometheus.io/scrape: "true" and prometheus.io/port: "8100" are present
```

Then check Prometheus actually scraped it — port-forward and query:

```bash
kubectl port-forward -n observability svc/prometheus-server 19090:80 &
PF_PID=$!
sleep 3
python3 -c "
import urllib.request, json
with urllib.request.urlopen('http://127.0.0.1:19090/api/v1/query?query=kong_http_requests_total', timeout=5) as r:
    data = json.load(r)
    print('result count:', len(data['data']['result']))
"
kill $PF_PID
```

Expected: `result count:` greater than 0 (generate a little traffic
first via Step 5 of Task 3 if this is 0 — Prometheus needs at least one
scrape interval, and Kong needs at least one proxied request, to have
data).

If you want a visual dashboard: search grafana.com/grafana/dashboards
for an official/community Kong dashboard and import it into Grafana —
don't hardcode a specific dashboard ID here without checking it's
still current.

- [ ] **Step 3: Verify Kong's traces reach Jaeger**

```bash
python3 -c "
import urllib.request, json
with urllib.request.urlopen('http://$NODE_IP:30080/jaeger/api/services', timeout=5, ) as r:
    pass
" 2>&1 || true
```

Use the Jaeger UI (`http://$NODE_IP:30080/jaeger/`) to check the
service dropdown for a Kong-related service name (exact name depends
on the `opentelemetry` plugin's default resource attributes — note
whatever it is here for future reference) and confirm it has traces
with non-zero spans, generated by the traffic from Task 3 Step 5/6.

- [ ] **Step 4: Confirm Traefik is fully gone**

```bash
kubectl get all -n traefik 2>&1
kubectl get application traefik -n argocd 2>&1
```

Expected: both return `NotFound` / no resources — confirms this isn't
just a git-level removal, there's no live leftover state either.

- [ ] **Step 5: Final status snapshot**

```bash
kubectl get applications -n argocd
make urls
```

Expected: all 8 Applications `Synced`/`Healthy`; `make urls` prints the
node IP with all 6 UI paths (5 UIs + Kong Manager).
