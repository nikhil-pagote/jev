---
description: Validate all Kubernetes manifests with kubectl dry-run before every git push
trigger: PreToolUse
matcher: Bash(git push:*)
allowed-tools:
  - Bash
---

When a `git push` is about to run, dry-run all manifests. Block if any are
invalid.

```bash
echo "--- pre-push: manifest dry-run ---"
ok=1
for f in argocd-apps/*/app.yaml argocd-apps/ingress-routes.yaml bootstrap/root-app.yaml; do
  [ -f "$f" ] || continue
  kubectl apply --dry-run=client -f "$f" >/dev/null 2>&1 || { echo "INVALID: $f"; ok=0; }
done
[ "$ok" = 1 ] && echo "Manifests OK" || { echo "MANIFEST ERRORS — fix before pushing"; exit 1; }
```

Force pushes (`git push --force`, `git push -f`) are blocked entirely by
the deny list in `settings.json`.
