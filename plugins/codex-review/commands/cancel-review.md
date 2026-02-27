---
description: "Cancel active review loop(s)"
allowed-tools:
  - Bash(ls .claude/codex-review-*.local.md *)
  - Bash(rm -f .claude/codex-review-*.local.md)
  - Bash(cat .claude/codex-review-*.local.md *)
  - Read
---

Check if any review loops are active:

```bash
ls .claude/codex-review-*.local.md 2>/dev/null && echo "ACTIVE" || echo "NONE"
```

If active, read each state file to show phase and review ID.

Then remove all state files:

```bash
rm -f .claude/codex-review-*.local.md
```

Report: "Review loop(s) cancelled" with the phase and review ID of each.

If no review loops were active, report: "No active review loops found."
