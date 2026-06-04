# Roadmap

Priority tiers: **P0** (must fix — gaps or debt that blocks quality),
**P1** (should do — meaningful UX or DX improvements),
**P2** (nice to have — polish, DX ergonomics),
**P3** (future — explore when the time is right).

---

## P0 — Critical

- [ ] **Untracked file/dir navigation** — untracked directories show up
      as a single entry but can't be expanded or inspected. Need to surface
      individual files inside untracked dirs, and allow opening/previewing
      them. This is a core usability gap.
- [ ] **Config directory restructuring** — the whole `lua/iter/config/`
      tree needs a rethink:
  - Separate `config/types.lua` for all `---@class` type definitions
    (currently inline in defaults.lua).
  - Fix the gap where `IterOptions` is declared but never connected as
    the actual type of the resolved `options` table.
  - Audit every config access site for type safety (LuaLS annotations).
  - Keep the tree clean — flat or minimal nesting, one concept per file.
- [ ] **Remove vendored plenary.nvim** — replace with `mini.test` for
      the test runner. Delete vendored copy (~20MB), update CI, `justfile`,
      and `tests/minimal_init.lua`. Move off a deprecated dependency.

## P1 — UX & workflow

- [ ] **Event-driven auto-refresh** — refresh the status window
      automatically:
  - On internal git ops (commit, push, stage, unstage, discard) — fire
    after each iter action completes.
  - On external changes (commit via terminal, lazygit, another Neovim
    instance) — simplest approach is a polling interval that checks
    `.git/index` or runs a lightweight `git status` on a timer.
    Alternative: watch `.git/` dir with `vim.uv.fs_event` for
    filesystem-level triggers. Mini.git explored for events but ruled
    out — not worth the dependency. Self-hosted is fine.
  - Manual `r` refresh becomes the fallback, not the default.
- [ ] **Rename detection** — `git status --porcelain` already flags
      renames (`R` status), but iter currently shows them as separate
      delete + add entries. Parse the rename pair and surface it as a
      single "renamed" row (like `README.md → ROADMAP.md`).
- [ ] **Iter event system** — once the auto-refresh mechanism works,
      expose `iter.events` so users can hook into `User IterRefresh`,
      `User IterStage`, etc. Keeps the architecture open without depending
      on external event sources.
- [ ] **LazyGit-style action menus** — replace flat keymaps with
      select menus (`vim.ui.select`) for compound actions:
  - `C` → commit options (--amend, --no-edit, --verbose, signoff, etc.)
  - `D` → discard options (discard unstaged, discard all, clean untracked)
  - `B` → branch operations (checkout, create, delete, rename)
  - Prioritise the most frequent actions, avoid polluting keymap space.
- [ ] **Keymap audit & philosophy document** — go through every mapping
      in status, diff_stacked, diff_split, and help windows. Verify each
      works as intended. Establish a keymap philosophy doc that captures
      the conventions (e.g. single-char for primary actions, menus for
      compound actions, no `a`-prefix namespace). This doc becomes the
      reference for all future keymap decisions.
- [ ] **Rename `a`-prefix toggles** — `aw`/`an`/`am`/`al` in diff
      previews feel unnatural after removing the namespacing need. Find
      mnemonic single-key or menu-based alternatives. Evaluate whether
      each toggle is even useful (e.g. line number toggling may not be
      needed). Layout toggle (`l`) is valuable and should stay prominent.

## P2 — DX & code quality

- [ ] **Co-locate tests with source files** — move test files next to
      the modules they test (e.g. `tests/functional/git_spec.lua` →
      `lua/iter/git.spec.lua`). Update the test runner to discover
      co-located specs. Move away from the separate `tests/` tree.
- [ ] **Migrate or replace `docs/CONVENTIONS.md`** — the `docs/` folder
      currently only contains the conventions doc, which is thin. Either
      expand it into real documentation (usage guide, architecture, API
      reference) or merge conventions into a more natural home (e.g.
      `CONTRIBUTING.md` or inline in `AGENTS.md`).
- [ ] **Expand test coverage** — add tests for:
  - Untracked file handling (currently uncovered)
  - Commit and push flows
  - Filtering and search
  - Discard operations (normal + forced)
  - Replace-mode layout
  - Window lifecycle edge cases (BufDelete, BufUnload, etc.)
  - Rethink fragile default-value assertions (e.g. `assert.are.equal(0.3, height)`) —
    prefer behavior-based tests that verify the *effect* of a config value rather
    than asserting specific magic numbers.
- [ ] **Quick-add to `.gitignore`** — keybinding to add the file under
      cursor to the repo's `.gitignore`.
- [ ] **Suppress untracked dir diff notification** — once untracked
      navigation is handled (P0), this may become moot. Otherwise debounce
      or silence the "Diff preview not available for untracked directories"
      warning.
- [ ] **Config** - Configurable `git diff` command (`--detect-renames` e.g.)

## P3 — Polish & exploration

- [ ] **Statusline component** — expose `iter.statusline()` that returns
      branch + dirty file counts for `vim.opt.statusline`. Lightweight,
      no extra polling beyond what git already does.
- [ ] **Inline hunk staging from diff preview** — stage/unstage the
      hunk under cursor from the diff preview, like fugitive's `=` in diff
      view. We have file-level stage/unstage; per-hunk completes the story.
- [ ] **Add screenshots & presentation polish** — add screenshots to
      README showing the status window, diff preview, commit editor, and
      replace-mode layout. Makes the plugin presentable for sharing.
- [ ] **Evaluate base.nvim rebase** — consider adopting the
      [base.nvim](https://github.com/S1M0N38/base.nvim) template for
      structured scaffolding, built-in testing, CI, and docs setup. Weigh
      effort vs benefit.
- [ ] **format** - Add formater for markdown files

---

# Completed

- [x] fix: make `=` toggle diff preview instead of always re-opening
- [x] docs: fix key references in help and README to match actual mappings
- [x] feat: make `o` open entry and close status window
- [x] feat: add `status.layout = 'replace'` option (Oil-like layout)
- [x] feat: use vsplit for commit editor in replace mode
- [x] fix: use bufadd/bufload instead of `:edit` in replace mode
- [x] feat: customizable keybindings (data-driven keymap tables + keymaps
      option in setup)
- [x] chore: rename plugin to iter.nvim (with credit to original)
- [x] test: add test suite (diff parser, diff position, status formatting,
      keymaps survival, CI workflow)
- [x] fix: harden keymap lifecycle (CursorMoved group, BufEnter diff
      remaps, close_diff cleanup)
