---
description: Pull or update a Helm chart vendored locally into argocd-apps/<app>/chart for an ArgoCD Application to source
argument-hint: "<app-name> <repo/chart> <version>"
allowed-tools:
  - Bash
---

Every app under `argocd-apps/` deploys from a chart vendored **into this
repo** (no live dependency on remote chart repos at ArgoCD sync time). Use
this skill to add a new app or bump an existing chart's version.

## Add or update a chart

```bash
app=<app-name>          # e.g. "loki"
chart=<repo/chart>      # e.g. "grafana/loki"
version=<version>       # e.g. "7.3.0"

mkdir -p "argocd-apps/$app/values"
rm -rf "argocd-apps/$app/chart"
helm pull "$chart" --version "$version" --untar --untardir "argocd-apps/$app"
mv "argocd-apps/$app/$(basename "$chart")" "argocd-apps/$app/chart"

ls "argocd-apps/$app/chart"   # sanity check: Chart.yaml, templates/, values.yaml present
```

If this is a **new** app (not just a version bump), also create
`argocd-apps/$app/app.yaml` following the pattern in any existing app (e.g.
`argocd-apps/traefik/app.yaml`): `Application` CRD, `source.path:
argocd-apps/$app/chart`, `helm.valueFiles: [../values/values.yaml]`,
`syncPolicy.automated: {prune: true, selfHeal: true}`, `syncOptions:
[CreateNamespace=true]`. And create `argocd-apps/$app/values/values.yaml`
with the chart's overrides.

No further registration step is needed — the `root` Application
(`bootstrap/root-app.yaml`) recurses over `argocd-apps/` and will pick up
the new `app.yaml` on the next commit.

## Check current chart versions in this repo

```bash
for f in argocd-apps/*/chart/Chart.yaml; do
  echo "$f:"; grep -E '^(name|version|appVersion):' "$f"
done
```
