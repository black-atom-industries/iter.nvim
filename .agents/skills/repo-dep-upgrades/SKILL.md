---
name: repo-dep-upgrades
description: "Use when upgrading dependencies in iter.nvim (the pinned mini.nvim test dependency, the npm devDependencies), or auditing what is outdated."
metadata:
  argument-hint: "[mini.nvim|package-name|all]"
---

# Dependency Upgrades

Upgrade dependencies with changelog review, verification, and safe commits.

## Arguments

The argument (`$ARGUMENTS` in Claude Code, or `/skill:repo-dep-upgrades` args in Pi): optional dependency name(s) to upgrade. Empty to review all outdated deps.

## Ecosystem

iter has no runtime dependencies. Two kinds of dev dependency exist:

- **mini.nvim**, the test framework (`mini.test`): a commit SHA pinned as `mini_ref` in the `justfile` and cloned into `deps/` by `just deps`.
  - **Outdated command:** `git -C deps/mini.nvim fetch --quiet origin && git -C deps/mini.nvim log --oneline HEAD..origin/main`
  - **Upgrade command:** `just bump-mini [REF]`, which rewrites `mini_ref` (default: the tip of `main`), checks it out and runs `CI=1 just test`
- **npm** for `vite-plus` (`vp fmt`, the Markdown formatter)
  - **Lock file:** `package-lock.json`
  - **Outdated command:** `npm outdated`
  - **Upgrade command:** `npm install -D`
- **Verification:** `CI=1 just checks`
- **Commit prefix:** `build(deps):`

## Workflow

### 1. Survey

Run both outdated commands:

```bash
git -C deps/mini.nvim fetch --quiet origin && git -C deps/mini.nvim log --oneline HEAD..origin/main
npm outdated
```

### 2. Strategy Selection

- **Batch low-risk, majors one-by-one**: patch+minor together, each major separately
- **All one-by-one**: safest, upgrade and verify each individually
- **All at once**: fast, single upgrade + verify pass

mini.nvim tags releases (`v0.x.0`); `just bump-mini <tag>` pins one, `just bump-mini` pins main's tip. Treat a bump as its own upgrade and read the commits between the two refs for changes to `mini.test` (`lua/mini/test.lua`, `CHANGELOG.md`).

### 3. Per-Upgrade Checklist

Research changelog, check usage in project (`grep` for `MiniTest` and `require('mini.test')` in `tests/`, `vp` in the `justfile`), upgrade, verify, report:

```bash
just bump-mini            # mini.nvim
npm install -D <package>@latest
CI=1 just checks
```

A failing screenshot test after a mini.nvim bump is a change in `mini.test`'s screenshot format or child Neovim handling, not a stale reference: find the cause before regenerating any reference.

Commit a green upgrade only after approval, staging the manifest, the lock file, and the code the upgrade required (`justfile` for mini.nvim; `package.json` and `package-lock.json` for npm), as
`build(deps): upgrade <package> from X to Y`.

### 4. Summary

Upgraded list, deprecation warnings, new features, skipped deps.
