---
description: Run YAML lint checks on staged files before every git commit
trigger: PreToolUse
matcher: Bash(git commit:*)
allowed-tools:
  - Bash
---

When a `git commit` is about to run, lint all staged YAML files.

```bash
staged=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.ya?ml$' | grep -v '/chart/' || true)
if [ -n "$staged" ]; then
  echo "--- pre-commit: yamllint on staged files ---"
  echo "$staged" | xargs yamllint -d relaxed
fi
```

Vendored chart files under `*/chart/` are upstream-owned and excluded from
lint. Also enforced by the `pre-commit` framework via
`.pre-commit-config.yaml` when the user commits directly (not through
Claude).
