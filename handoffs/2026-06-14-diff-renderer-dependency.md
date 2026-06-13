# Diff renderer dependency decision — open discussion

**Date:** 2026-06-14
**Author of this handoff:** current session
**Project:** iter.nvim
**Author of iter.nvim:** Nik (nbr / black-atom-industries)

## TL;DR

iter.nvim currently has a **hard runtime dependency on `barrettruth/diffs.nvim`** for diff rendering (stacked view + split view). Nik is reconsidering that dependency and wants to make a decision in a future session. This document captures everything we established in the 2026-06-14 conversation so a fresh agent can pick up the discussion without re-deriving it.

**Status:** No code changes pending. Decision is open.

---

## Context: how we got here

iter.nvim was forked from [`vieitesss/minifugit.nvim`](https://github.com/vieitesss/minifugit.nvim) (a fork, not a rewrite — the original reason was visual/UX: Nik didn't like the sidebar and wanted his own modifications). At fork time, iter inherited minifugit's **homegrown diff renderer** (~1,200 LOC of Lua across 6 files).

On **2026-06-12**, Nik committed `44ef874`:

> **feat(preview): adopt diffs.nvim for diff rendering**
>
> Replace the home-grown diff renderer and syntax module with diffs.nvim
> as a hard runtime dependency, integrated via its documented host-plugin
> API …

That commit deleted iter's homegrown renderer files (`syntax.lua`, `render.lua`, `split_align.lua`, the intra-line part of `word_diff.lua`) and replaced them with a 41-line adapter at `lua/iter/ui/diff/diffs_nvim.lua`. The adapter requires `diffs.nvim` to be installed — no fallback.

24 hours later, Nik is reconsidering.

## The three layers (key concept for the discussion)

A diff plugin has three distinct concerns that are easy to conflate:

1. **Diff content** — the raw unified diff text. Always comes from `git diff` subprocess. iter, minifugit, and diffs.nvim all do this the same way.
2. **Diff algorithm** — computes which lines/words/characters differ. In the Neovim world, the options are `vim.diff` (C builtin, Neovim 0.10+), `libvscode_diff` (FFI bundle from `esmuellert/codediff.nvim`), or `difftastic` (Rust subprocess). All three implementations we looked at use `vim.diff` for the algorithm.
3. **Diff rendering** — paints the diff in the editor. Treesitter syntax inside hunks, intra-line word highlights, line-number rails, extmark management, split-pane alignment. **This is what iter is currently outsourcing to `diffs.nvim`.**

When someone (me, the docs, anyone) says "native vim diff," they could mean any of:
- `vim.diff` (C function) — just math
- Native nvim windows / extmarks / treesitter — just editor APIs
- Neovim's built-in `:diffthis` + `vim.hl.diff` highlights — the *legacy* diff mode renderer

The third one is what would be "native diff rendering." It is **not** what iter uses in either stacked or split view. Both go through `diffs.nvim`'s own extmark-based renderer.

## Confusion that came up in the conversation (and was resolved)

1. **"iter uses `@pierre/diffs` as a backend"** — false. The `pierre-style` line in `diffs.nvim`'s README is a layout-language reference, not a backend dependency. Pierre Computer Company (`pierrecomputer` on GitHub) and Barrett Ruth (author of `diffs.nvim`) are different people. iter has no relationship to `@pierre/diffs`.

2. **"iter dropped native vim diffing"** — partially wrong framing. The diff *content* (`git diff` subprocess) is still native. The diff *algorithm* (`vim.diff` C function) is still native. What moved is the *renderer* (treesitter extraction, extmark painting, split alignment) — and only because iter replaced homegrown code with the `diffs.nvim` adapter.

3. **"iter's split view uses native vim diff rendering"** — wrong, but plausibly so. iter's `M.open_split_diff()` (in `lua/iter/ui/status/preview.lua:261`) requires `diffs_nvim.is_available()` and calls `vim.cmd('Diff ++layout=split')` — that is `diffs.nvim`'s split command, not Neovim's built-in diff mode. Grepping `diffs.nvim`'s entire `lua/` for `diffthis`, `diffoff`, `&diff`, or `diff_mode` returns zero matches. None of its three layouts (`unified`, `stacked`, `split`) call `:diffthis`. The "another instance" that told Nik about native diffing was probably referring to the C function `vim.diff`, not to Neovim's diff-mode rendering.

4. **"minifugit moved away from native diffing"** — Nik clarified he meant: minifugit had its own renderer (which iter inherited at fork time), and the renderer is homegrown. Minifugit never switched algorithms; the homegrown piece is the renderer, not the algorithm.

## What we measured (concrete numbers)

| Source | LOC | What it is |
|---|---|---|
| iter's current `diffs_nvim.lua` adapter | 41 | Just a call into diffs.nvim |
| **minifugit's full renderer** (excl. parser) | **1,179** | `word_diff.lua` (109) + `syntax.lua` (319) + `render.lua` (187) + `split_align.lua` (143) + `position.lua` (421) |
| diffs.nvim core (stacked + intra-line + parser) | 2,382 | `highlight.lua` (1,004) + `diff.lua` (437) + `parser.lua` (392) + `hunks.lua` (549) |
| diffs.nvim with split | 3,842 | + `split.lua` (1,342) + `split_align.lua` (118) |
| diffs.nvim total `lua/` | 13,852 | Includes commands, config, integrations, review mode, etc. — most of which iter doesn't need |

**The "actual renderer" Nik was asking about is ~1,179 lines of Lua.** That's the minifugit version. diffs.nvim's renderer is 3-4× larger because it has more layouts, more polish, and a public API iter doesn't need.

## Nik's stated preferences

- Cares about the visual quality of diff rendering (likes the Pierre-style polish)
- Does **not** want to implement the diff rendering/algorithm himself
- Was OK with the diffs.nvim dependency initially
- **Now wants to remove the hard dependency** on diffs.nvim
- The fork from minifugit was for visual/UX reasons, not technical — iter has diverged from minifugit

## Current state of the code

- `lua/iter/ui/diff/parser.lua` (248 LOC) — renamed copy of minifugit's parser. **Keep.**
- `lua/iter/ui/diff/diffs_nvim.lua` (41 LOC) — adapter that calls `diffs.nvim`. **Candidate for removal.**
- `lua/iter/ui/diff/position.lua` (421 LOC) — present in the repo from before the 2026-06-12 commit. **Verify still has meaningful content** (the `44ef874` commit may have gutted the renderer-touching parts; the file might be a partial skeleton).
- Other homegrown renderer files (`syntax.lua`, `render.lua`, `split_align.lua`, `word_diff.lua`) — **not present** in iter as of 2026-06-14; deleted in `44ef874`. Would need to be re-imported from minifugit or reconstructed.
- `lua/iter/ui/status/preview.lua` — iter's preview orchestration. Calls `diffs_nvim.attach()` for stacked and `vim.cmd('Diff ++layout=split')` for split. **Will need surgery** to drop the adapter.
- `lua/iter/health.lua` — healthcheck asserts `diffs.nvim` is installed. **Will need to change.**
- `lua/iter/config/defaults.lua` — has keymaps and options that mention "diffs.nvim" by name. **Will need audit.**
- `README.md` — has a "Requirements" section listing `diffs.nvim` as required, plus an integration example showing `vim.pack.add({ diffs.nvim, iter })` with `dependencies`. **Will need rewrite.**

## The decision (open)

Three options Nik is weighing:

### Option A: Revert + restore homegrown renderer from minifugit

- `git revert 44ef874` (or `git reset --hard` to the commit before, salvageable since the commit is 24h old)
- Re-import the deleted renderer files from minifugit (`word_diff.lua`, `syntax.lua`, `render.lua`, `split_align.lua`)
- Delete `diffs_nvim.lua`
- Drop the hard dep from README, healthcheck, defaults
- **Cost:** ~1,179 LOC of renderer code that Nik owns. Maintenance burden returns. But: code was working 24h ago, bounded, and Nik has shipped it before.
- **Gain:** zero third-party rendering dependency, full ownership.

### Option B: Keep `diffs.nvim` as optional enhancement

- Don't revert. Keep the adapter, but make it best-effort.
- Stacked view: write a minimal homegrown renderer (~300-500 LOC) that works without diffs.nvim
- Split view: only available if diffs.nvim is installed (uses `:Diff ++layout=split`)
- Healthcheck: warn if diffs.nvim is missing, don't fail
- README: reframe as "optional, enables polished split view"
- **Cost:** more code than A, less polish than current state. Best of both worlds.
- **Gain:** users without diffs.nvim get a working plugin; users with it get the better split UX.

### Option C: Status quo

- Keep the hard dependency on diffs.nvim
- Nik said this is no longer acceptable. **Likely rejected** but listed for completeness.

## Recommendation from prior session

**Take the renderer back from minifugit (Option A), or do the best-of-both-worlds refactor (Option B).** Do not copy from diffs.nvim — its renderer is 3-4× larger than what iter needs, and most of it is a public API iter doesn't use.

## Specific files for the next session to examine

- `/Users/nbr/repos/black-atom-industries/iter.nvim/lua/iter/ui/diff/diffs_nvim.lua` — the adapter
- `/Users/nbr/repos/black-atom-industries/iter.nvim/lua/iter/ui/diff/parser.lua` — keep this
- `/Users/nbr/repos/black-atom-industries/iter.nvim/lua/iter/ui/diff/position.lua` — check what's still here
- `/Users/nbr/repos/black-atom-industries/iter.nvim/lua/iter/ui/status/preview.lua` — the orchestration to refactor
- `/Users/nbr/repos/black-atom-industries/iter.nvim/lua/iter/health.lua` — healthcheck
- `/Users/nbr/repos/black-atom-industries/iter.nvim/lua/iter/config/defaults.lua` — config/keymaps
- `/Users/nbr/repos/black-atom-industries/iter.nvim/README.md` — user-facing docs
- `/tmp/pi-github-repos/vieitesss/minifugit.nvim/lua/minifugit/ui/diff/` — renderer source for re-import
- `/Users/nbr/repos/github.com/barrettruth/diffs.nvim/lua/diffs/split.lua`, `highlight.lua`, `diff.lua` — for reference if Option A or B is chosen

## Commit reference

- `44ef874` (2026-06-12) — "feat(preview): adopt diffs.nvim for diff rendering" — the commit that introduced the dependency. The revert target if Nik chooses Option A.

## Open questions for the discussion

1. How important is the polished diffs.nvim split view? If it's important, Option B. If iter can ship without a split view (or with a quick `vsplit + :diffthis`), Option A.
2. How comfortable is Nik with owning ~1,200 LOC of renderer code he didn't write? It was working 24h ago, but minifugit will keep evolving and iter will need to either vendor it or re-fork periodically.
3. Is "minimal homegrown stacked renderer" feasible in ~300-500 LOC? Probably yes — stacked is simpler than split, and Pierre-style polish comes mostly from intra-line word highlighting (one `vim.diff` call on word tokens) + treesitter syntax extraction (well-documented Neovim API). The Pierre-quality *gap* is mostly in split layout and the FFI-based `libvscode_diff` engine, both of which iter could skip.
4. Should the healthcheck remain soft or be removed entirely once the hard dep is gone?

## Suggested skills for the next session

- `dev-flow` — to drive the discussion from decision through implementation
- `dev-improve-codebase-architecture` — if the discussion turns into "should we restructure the diff module"
- `dev-nvim` — for any Neovim API verification (extmarks, treesitter, windows)
- `librarian` — if pulling renderer patterns from minifugit/diffs.nvim source
- `ask-user` — for the decision handshake on Option A vs B

## What this handoff is NOT

- Not a plan to implement — Nik explicitly said "I have to think about it"
- Not a code review — no diffs to review
- Not a refactor proposal in concrete form — that comes after the decision

The next session should:
1. Read this handoff
2. Re-read the relevant files in iter
3. Make the A/B/C decision with Nik
4. If A or B, propose a concrete plan and get approval before any code changes
