---
description: Pull local changes to skills/commands back into decknix/decknix-config
---

Pull your recent edits to agent guidelines, commands, and settings back into the
Nix repositories so they can be shared and persisted.

**Instructions:**

1. **Dry-run first:** Run `decknix pull-local-changes` (without `--apply`) to see what has changed.
2. **Report findings:** List the files that have diverged.
3. **Ask for confirmation:** Ask if you should proceed with the pull and commit.
4. **Apply if approved:** If I say yes, run `decknix pull-local-changes --apply` and report the result.
