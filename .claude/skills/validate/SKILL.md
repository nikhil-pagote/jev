---
description: Dry-run all Kubernetes manifests in the repo to catch schema and syntax errors before applying to the cluster
argument-hint: "[--strict]"
allowed-tools:
  - Bash
  - Read
---

Run `kubectl apply --dry-run=client` on every manifest and report errors.

## Steps

```bash
echo "--- bootstrap ---"
kubectl apply --dry-run=client -f bootstrap/root-app.yaml

echo "--- argocd-apps ---"
for f in argocd-apps/*/app.yaml; do
  echo "$f"
  kubectl apply --dry-run=client -f "$f"
done

echo "--- ingress-routes ---"
kubectl apply --dry-run=client -f argocd-apps/ingress-routes/routes.yaml
```

If `--strict` is passed, also lint every YAML file (excluding vendored
charts, which are upstream-owned):
```bash
find . -name "*.yaml" -not -path "./.git/*" -not -path "*/chart/*" \
  | xargs yamllint -d relaxed
```

Report: list each file validated, flag any errors. If all pass, print
"All manifests valid."

Note: `--dry-run=client` validates locally without needing a running
cluster; it does not catch CRD-dependent errors (e.g. `IngressRoute` needs
Traefik's CRDs installed) — those only surface once the cluster is up and
`traefik`'s Application has synced.
