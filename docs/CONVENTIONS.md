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
- A view renders a document (`iter.diff.document`): sections in order, one per file diff, and for each buffer line
  its section and model row (none on the blank line between two files). One file is a document of one section; the
  review's all-files mode is one section per drawer file, Unstaged then Staged. Callers map lines with `at()` and
  `line_of()`, never with offsets, so a layout other than unified builds its own lines over the same sections.
- A document of several files decorates per viewport: syntax, word emphasis and annotation `virt_lines` for the lines
  in view and two screens around them, again on `WinScrolled`; row highlights, headers and annotation positions cover
  the whole document. A read of all files keeps a file's rows, and so its parse, while its blob ids and worktree stat
  (`git.diff_ids`) stay the same.
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
  The new side follows the worktree file, the old side its `base` (`HEAD` or `index`). `outdated` is set when the anchor
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
- The drawer float sits at the bottom of its pane (`relative = 'win'`, `anchor = 'SW'`) at `drawer.zindex`; the help
  float uses `drawer.zindex + 10`, the annotation float `+ 20`. In the review tab the drawer covers a spacer split
  of its own height, so it never hides the diff.
- In the status drawer the pane above shows the diff view in place of its buffer. The view saves the window-local
  options it changes and restores them on every exit path.
- The drawer's lines come from `iter.ui.layout`: pure functions from a list of column specs and the width to render
  lines, side by side at `drawer.breakpoint` and wider, stacked below it. A stack (`IterLayoutStack`) puts several
  specs as titled sections in one column; the review drawer's columns layout stacks Unstaged above Staged beside the
  Annotations column, and `h` and `l` step between those columns, each keeping its last selection. There
  `layout.split` gives the Annotations column a layout of its own, shown in the float's side window (`IterFloatSide`):
  a focusable window over the right of the float's text rows at `drawer.zindex + 1`, with its own buffer, so the file
  list scrolls alone. The float opens, moves and closes it; the drawer closes when it is closed from outside, and
  focus moves into it only through `h` and `l`, opening the review on the Annotations column, and a resize that splits
  it off while an annotation is selected in the drawer. The drawer holds what the status and review
  drawers share; the review tab plugs in its viewed marks, annotation counts, header, Annotations column, its preview
  and spacer sizing as the drawer's extras (`IterDrawerExtras`). Columns the extras add come after the file columns;
  their items carry a `key`, and `Drawer:selected()` returns files only.
- Viewed marks, annotation counts and the Annotations column show only in the review drawer.
- The ahead and behind counts with the upstream's name, and the Recent commits section, show only in the status
  drawer. They count against the upstream as last fetched; iter never fetches. A poll reads HEAD and the upstream with
  one `git rev-parse`, and reads the counts (`rev-list --left-right`) and the commits (`log`) again only when either
  moved. Commit ages are computed at render from the committer date.
- The Recent commits section is a second, non-focusable float (`IterFloat`'s strip) pinned between the file area and
  the key hint line inside the drawer's footprint; only the file columns scroll. The float owns the strip and closes it
  with itself.
- The status header keeps `HEAD <branch>` whole and sheds from the right when it doesn't fit: the summary shrinks to
  the total, then goes, then the upstream, then the arrows.
- The export and the Annotations column list annotations through `iter.annotations.list`: files in drawer order,
  then other files by name, the review last; by line within a file. An annotation that follows the worktree is outdated
  when its text isn't in the file's lines (the loaded buffer's, else the file's).

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
