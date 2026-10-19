# Conventions

These conventions apply to all project changes.

## Scope

iter is a Neovim-native staging and code review tool. It joins a minimal status menu (from
[minifugit.nvim](https://github.com/vieitesss/minifugit.nvim)), [tuicr](https://github.com/agavra/tuicr)'s
one-scroll review with annotations, viewed marks and an export for agents, and
[annotator.nvim](https://github.com/chpeters/annotator.nvim)'s annotations in normal buffers.

Out of scope: pull requests, commits and remote sync (commit, push and pull stay with a Git plugin such as mini.git),
Jujutsu and Mercurial, merge conflict resolution, branch management, stash, a log browser, annotation types, and sending
the review straight to an agent pane.

## Architecture

- Diff flow: git's unified diff → `iter.diff.parser` (hunks) → `iter.diff.model` (rows: header, hunk, context, del,
  add, gap, each with old and new line numbers) → `iter.diff.view` (buffer lines and extmarks). Hunks always come from
  git's diff, so staging applies exactly what git produced. The full old and new file contents are fetched for syntax
  and context; when they don't match the diff text (filters, CRLF), only the hunk text is used.
- The diff buffer holds plain code. Row kinds show through line highlights and line numbers through a `statuscolumn`
  that reads the model, so a yank gives clean code.
- Syntax comes from a treesitter string parser per file version, cached per blob, with captures only for the rows
  shown. Word emphasis pairs changed lines with `vim.text.diff` and skips lines that mostly changed.
- Hidden context is gap rows in the model that expand in batches, not folds.
- The renderer is pure Lua. A binary dependency (such as libvscode-diff) comes in only after Nik decides for it.
- `Iter*` highlight groups derive from the colorscheme on every `ColorScheme` event.
- Annotations are `virt_lines` extmarks: line and range annotations under their last row, deleted-line annotations on
  the del row, file annotations on the header row.
- Anchors resolve with one function: an exact block match at the stored lines first, then the match nearest to them.
  The new side follows the worktree file, the old side its `base` (HEAD or index). `outdated` is set when the anchor
  isn't found and cleared when it is found again. A diff view places annotations against its own version without
  persisting.
- Store: `stdpath('data')/iter/<main worktree basename>-<first 8 hex of sha256 of git-common-dir>/<branch>.json`, so
  linked worktrees share it. The branch name has `%` and `/` percent-encoded; a detached HEAD uses `HEAD.json`.
  Writes go through a temp file renamed into place, after re-reading and merging by annotation id.
  The review drawer and the buffer marks read through one cache per root (`store.cached`), read again when the
  file's stat or HEAD changes.
- Viewed: viewed when the stored `git hash-object` of the worktree file equals the current one, changed when it
  differs, unviewed without a record. Staging doesn't change it.
- Discard never touches the index or ignored files: an unstaged row restores from the index, an untracked row deletes
  only its untracked files, and the confirm names the paths. The Staged column has no discard.
- The drawer float sits at the bottom of its pane (`relative = 'win'`, `anchor = 'SW'`) at `drawer.zindex`; help and
  picker floats use `drawer.zindex + 10`, the annotation float `+ 20`. In the review tab the drawer covers a spacer split
  of its own height, so it never hides the diff.
- In the status drawer the pane above shows the diff view in place of its buffer. The view saves the window-local
  options it changes and restores them on every exit path.
- The drawer's lines come from `iter.ui.layout`: pure functions from a list of column specs and the width to render
  lines, side by side at `drawer.breakpoint` and wider, stacked below it. The drawer holds what the status and review
  drawers share; the review tab plugs in its viewed marks, annotation counts, header summary and spacer sizing as the
  drawer's extras (`IterDrawerExtras`).
- Viewed marks and annotation counts show only in the review drawer.

## Project shape

- Keep the public `iter` entrypoints thin and move behavior into focused modules.
- Separate data collection, formatting, and UI rendering. A good default flow is: Git/process output -> parsed data -> renderable lines -> buffer/window updates.
- Prefer small single-purpose modules over catch-all utility files.
- Model stateful UI pieces as table-based objects with `__index`; keep pure transforms and parsers as local helper functions or stateless modules.

## Lua style

- Follow the repo's Stylua rules: 4 spaces, 80-column width, Unix line endings, always-parenthesized calls, and a preference for single quotes.
- Use LuaLS annotations for non-trivial modules and APIs: `---@class`, `---@field`, `---@alias`, `---@param`, and `---@return`.
- Default to `local` functions and locals; only export what is part of a module API.
- Prefer early returns and explicit `nil` handling over deeply nested conditionals.
- Validate option tables and constructor inputs with `vim.validate`.

## Neovim API usage

- Prefer the Lua Neovim API (`vim.api`, `vim.fn`, `vim.system`) over stringly Vimscript-style code when a Lua API exists.
- Centralize shell/process interactions instead of spawning ad hoc commands from multiple places. Git access should go through shared helpers.
- Keep render steps side-effect free until the final buffer/window apply step.
- Reuse existing editor highlight groups first, then provide sensible fallback colors.

## Good practices

- Keep parsing and formatting logic deterministic and easy to inspect from plain strings/tables.
- Use logging through `iter.log` for plugin-internal diagnostics; reserve direct user-facing output for health checks or truly actionable failures.
- Preserve compatibility assumptions already present in the project: Neovim 0.12+ and a working `git` executable.
- Run lints before committing: `just lint`.
- Run the test suite before submitting changes: `just test`. See README for details.
- For UI or git-status changes, validate against realistic repository states such as modified, untracked, renamed, and conflicted files when relevant.
- When creating commits, match the existing conventional-commit style seen in history (`feat:`, `fix:`, `refactor:`, `style:`, `chore:`).
